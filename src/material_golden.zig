//! Headless golden harness for the bgfx material seam (labelle-gfx#305 Slice B,
//! RFC-MATERIAL-POSTFX §6). Renders a FIXED scene covering the FULL curated
//! material set — `flash` (amount 0.6 toward red), `palette_swap` (a 4-entry
//! index atlas recoloured through a LUT ramp), `dissolve` (a solid sprite
//! burned away by the built-in procedural noise at threshold 0.5 with an orange
//! edge glow), and `outline` (an opaque square, an anti-aliased soft disc whose
//! fractional-alpha boundary exercises the over-operator composite, an ATLAS
//! sub-rect frame whose opaque red neighbour must NOT bleed into the outline,
//! and a tint.a=0.5 case whose outline fades with the sprite). An atlas
//! `dissolve` frame guards the sprite-local noise remap too — FULLY headless
//! (surfaceless bgfx,
//! Metal/Vulkan offscreen framebuffer, no window / no display server, the
//! `initHeadless` path proven by `mirror_probe` / `screenshot_probe`), then
//! captures the offscreen framebuffer to an uncompressed 32-bit TGA via
//! `window.captureHeadless`.
//!
//! Two modes (argv[1]):
//!   --bless : write the committed golden (GOLDEN_BASE + ".tga"). Run this on a
//!             machine/CI runner with a Metal/Vulkan device to (re)generate the
//!             golden after an intentional shader change, then commit it.
//!   (check) : the default. Render to a candidate TGA and diff it against the
//!             committed golden with a per-channel tolerance (GPU rasterisation
//!             is not bit-exact across drivers). Exit 0 = match, non-zero = drift
//!             / missing golden. This is the CI gate.
//!
//! Exit codes:
//!   0 = OK              (bless wrote the golden, or check matched)
//!   2 = HEADLESS_INIT_FAILED   (no Metal/Vulkan device — e.g. no GPU in CI)
//!   3 = CAPTURE_FAILED         (render/readback/TGA-write failed)
//!   4 = GOLDEN_MISMATCH        (candidate drifted beyond tolerance)
//!   5 = GOLDEN_MISSING         (check mode, no committed golden — run --bless)
//!
//! Run with:  zig build material-golden        (check)
//!            zig build material-golden-bless   (regenerate)

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx");
const window = @import("window");
// Mode baked at build time (Zig 0.16's arg-iterator needs the Init framework —
// overkill for a probe). `zig build material-golden-bless` compiles the bless
// variant; `zig build material-golden` compiles the check variant.
const options = @import("golden_options");

const W: u16 = 576;
const H: u16 = 96;

const GOLDEN_BASE: [:0]const u8 = "test/golden/material_effects";
const GOLDEN_PATH: [:0]const u8 = "test/golden/material_effects.tga";
const CANDIDATE_BASE: [:0]const u8 = "zig-out/material_effects_candidate";
const CANDIDATE_PATH: [:0]const u8 = "zig-out/material_effects_candidate.tga";

// Diff tolerance: GPU rasterisation is not bit-exact across drivers/refreshes, so
// allow a small per-channel delta and a tiny fraction of outlier pixels. A broken
// shader recolours large areas well past this — the gate still trips.
const CHANNEL_TOL: i32 = 12;
const MAX_OUTLIER_FRAC: f32 = 0.02;

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

/// Create the parent-directory chain of `base` (makePath-style) so
/// `captureHeadless`'s `fopen(.., "wb")` can't fail on a CLEAN checkout where the
/// output dir (e.g. `zig-out/`) does not pre-exist — the CI failure this fixes
/// (locally `zig-out/` survived from prior builds, masking it). Zig 0.16 dropped
/// `std.fs.cwd()` (needs an `Io`) and we already link libc, so mkdir each
/// ancestor prefix via libc; an already-existing dir (EEXIST) is harmless.
fn ensureParentDir(base: [:0]const u8) void {
    const dir = std.fs.path.dirname(base) orelse return;
    var buf: [1024:0]u8 = undefined;
    if (dir.len >= buf.len) return;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i < dir.len and dir[i] != '/') continue;
        @memcpy(buf[0..i], dir[0..i]);
        buf[i] = 0;
        _ = mkdir(&buf, 0o755);
    }
}

fn readFile(path: [:0]const u8) ?[]u8 {
    const file = std.c.fopen(path.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);
    if (fseek(file, 0, SEEK_END) != 0) return null;
    const sz = ftell(file);
    if (sz < 18) return null;
    if (fseek(file, 0, SEEK_SET) != 0) return null;
    const n: usize = @intCast(sz);
    const buf = std.heap.page_allocator.alloc(u8, n) catch return null;
    if (std.c.fread(buf.ptr, 1, n, file) != n) {
        std.heap.page_allocator.free(buf);
        return null;
    }
    return buf;
}

/// Build a solid-colour RGBA sprite (the `flash` subject).
fn makeSolid(w: u32, h: u32, r: u8, g: u8, b: u8) gfx.DecodedImage {
    const px = std.heap.page_allocator.alloc(u8, w * h * 4) catch unreachable;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        px[i] = r;
        px[i + 1] = g;
        px[i + 2] = b;
        px[i + 3] = 255;
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// Build the `palette_swap` INDEX atlas: `w`×`h`, split into `n` vertical bands
/// whose RED channel encodes the palette index (0..n-1). g/b = 0, alpha opaque.
/// The material shader reads `round(red*255)` as the index into the LUT.
fn makeIndexAtlas(w: u32, h: u32, n: u32) gfx.DecodedImage {
    const px = std.heap.page_allocator.alloc(u8, w * h * 4) catch unreachable;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const band = @min(n - 1, x * n / w);
            const o = (y * w + x) * 4;
            px[o] = @intCast(band); // index in the red channel
            px[o + 1] = 0;
            px[o + 2] = 0;
            px[o + 3] = 255;
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// Build the `outline` subject: a `w`×`h` sprite that is fully transparent
/// except a centred opaque square of side `inner` (white). The transparent
/// border is what lets the alpha-dilated silhouette show up INSIDE the quad —
/// an all-opaque sprite would have no transparent texels for the outline to
/// fill. The atlas is clamp-sampled, so outline taps past the sprite edge read
/// the (transparent) border texel, not a neighbouring frame.
fn makeShape(w: u32, h: u32, inner: u32, r: u8, g: u8, b: u8) gfx.DecodedImage {
    const px = std.heap.page_allocator.alloc(u8, w * h * 4) catch unreachable;
    const lo_x = (w - inner) / 2;
    const lo_y = (h - inner) / 2;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const o = (y * w + x) * 4;
            const solid = x >= lo_x and x < lo_x + inner and y >= lo_y and y < lo_y + inner;
            px[o] = if (solid) r else 0;
            px[o + 1] = if (solid) g else 0;
            px[o + 2] = if (solid) b else 0;
            px[o + 3] = if (solid) 255 else 0;
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// Build a SOFT-EDGED `outline` subject: a `w`×`h` transparent field with a
/// centred anti-aliased disc of radius `radius`, its alpha ramping linearly from
/// 1 (interior) to 0 (exterior) over a `feather`-px band. This is the case the
/// opaque square CANNOT cover: along the disc boundary `base.a` is strictly
/// between 0 and 1, so the outline composite's over-operator math is actually
/// exercised — a double-`(1−base.a)` bug reads visibly faint here.
fn makeSoftDisc(w: u32, h: u32, radius: f32, feather: f32, r: u8, g: u8, b: u8) gfx.DecodedImage {
    const px = std.heap.page_allocator.alloc(u8, w * h * 4) catch unreachable;
    const cx = @as(f32, @floatFromInt(w)) / 2.0;
    const cy = @as(f32, @floatFromInt(h)) / 2.0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const dx = (@as(f32, @floatFromInt(x)) + 0.5) - cx;
            const dy = (@as(f32, @floatFromInt(y)) + 0.5) - cy;
            const dist = @sqrt(dx * dx + dy * dy);
            // 1 inside, 0 outside, linear over the feather band straddling the edge.
            const cov = std.math.clamp((radius - dist) / feather + 0.5, 0.0, 1.0);
            const o = (y * w + x) * 4;
            px[o] = r;
            px[o + 1] = g;
            px[o + 2] = b;
            px[o + 3] = @intFromFloat(cov * 255.0 + 0.5);
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// Build the LUT ramp: `n`×1 RGBA, one distinct colour per entry.
fn makeLut(colors: []const [3]u8) gfx.DecodedImage {
    const n: u32 = @intCast(colors.len);
    const px = std.heap.page_allocator.alloc(u8, n * 4) catch unreachable;
    for (colors, 0..) |c, k| {
        px[k * 4] = c[0];
        px[k * 4 + 1] = c[1];
        px[k * 4 + 2] = c[2];
        px[k * 4 + 3] = 255;
    }
    return .{ .pixels = px, .width = n, .height = 1 };
}

/// Build a 2-frame ATLAS (`fw`×`h`, two side-by-side `fw/2`-wide frames):
///   frame 0 (left)  = a small opaque `inner`-px square (colour rgb0) on a
///                     transparent field — the material subject, drawn from the
///                     source sub-rect (0,0,fw/2,h).
///   frame 1 (right) = solid OPAQUE `rgb1` — the "neighbouring frame" whose
///                     content an atlas-unaware outline would bleed. Its opaque
///                     pixels start right at the frame-0/frame-1 seam, so taps
///                     from transparent frame-0 pixels near the seam reach it.
/// The point: with the per-frame tap gate, the outline must NOT show along
/// frame 0's right edge (adjacent to the opaque neighbour); without it, a green
/// outline bleeds there.
fn makeAtlas2(fw: u32, h: u32, inner: u32, r0: u8, g0: u8, b0: u8, r1: u8, g1: u8, b1: u8) gfx.DecodedImage {
    const px = std.heap.page_allocator.alloc(u8, fw * h * 4) catch unreachable;
    const half = fw / 2;
    // Centre the opaque square within frame 0.
    const lo_x = (half - inner) / 2;
    const lo_y = (h - inner) / 2;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < fw) : (x += 1) {
            const o = (y * fw + x) * 4;
            if (x < half) {
                const solid = x >= lo_x and x < lo_x + inner and y >= lo_y and y < lo_y + inner;
                px[o] = if (solid) r0 else 0;
                px[o + 1] = if (solid) g0 else 0;
                px[o + 2] = if (solid) b0 else 0;
                px[o + 3] = if (solid) 255 else 0;
            } else {
                px[o] = r1;
                px[o + 1] = g1;
                px[o + 2] = b1;
                px[o + 3] = 255;
            }
        }
    }
    return .{ .pixels = px, .width = fw, .height = h };
}

fn renderScene() void {
    gfx.setScreenSize(W, H);
    gfx.setDesignSize(W, H);

    // Textures (the harness owns the pixel buffers; bgfx.copy takes its own copy).
    const gray = gfx.uploadTexture(makeSolid(48, 48, 140, 140, 140)) catch unreachable;
    const atlas = gfx.uploadTexture(makeIndexAtlas(48, 48, 4)) catch unreachable;
    const lut = gfx.uploadTexture(makeLut(&.{
        .{ 220, 40, 40 }, // index 0 → red
        .{ 40, 200, 40 }, // index 1 → green
        .{ 40, 90, 230 }, // index 2 → blue
        .{ 230, 210, 40 }, // index 3 → yellow
    })) catch unreachable;
    // dissolve subject: another solid sprite the procedural noise burns away.
    const burn = gfx.uploadTexture(makeSolid(48, 48, 90, 160, 200)) catch unreachable;
    // outline subject: an opaque 24px square on a transparent 48px field.
    const shape = gfx.uploadTexture(makeShape(48, 48, 24, 235, 235, 235)) catch unreachable;
    // outline subject with ANTI-ALIASED edges: a soft disc so base.a is fractional
    // along its boundary (exercises the over-operator composite — see makeSoftDisc).
    const disc = gfx.uploadTexture(makeSoftDisc(48, 48, 15.0, 3.0, 235, 235, 235)) catch unreachable;
    // ATLAS subject: a 96x48 texture, frame 0 = a small opaque square on
    // transparent, frame 1 = solid opaque red. Drawn from frame 0's sub-rect; the
    // opaque red neighbour is what an atlas-unaware outline/dissolve would bleed
    // or mis-scale against. Guards the u_material_rect fixes (#1, #2).
    const atlas2 = gfx.uploadTexture(makeAtlas2(96, 48, 20, 235, 235, 235, 210, 40, 40)) catch unreachable;

    // A couple of begin/draw/end cycles so the offscreen FB holds the scene
    // before captureHeadless blits it (belt-and-braces, matching the probes).
    var frame: u32 = 0;
    while (frame < 2) : (frame += 1) {
        window.clearBackground(20, 20, 30, 255);
        window.beginFrame();

        const src48 = gfx.Rectangle{ .x = 0, .y = 0, .width = 48, .height = 48 };
        const origin = gfx.Vector2{ .x = 0, .y = 0 };

        // Four 48px sprites across the 288px canvas (12px left margin, 24px gaps).
        // Col 1: the GPU hit-flash — gray mixed 0.6 toward red → reddish sprite.
        gfx.drawTextureProMaterial(
            gray,
            src48,
            .{ .x = 12, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .flash, .uniforms = .{ .r = 1, .g = 0, .b = 0, .a = 1, .scalar0 = 0.6 } },
        );

        // Col 2: palette_swap — the 4-band index atlas recoloured via the LUT.
        gfx.drawTextureProMaterial(
            atlas,
            src48,
            .{ .x = 84, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .palette_swap, .uniforms = .{ .aux_texture = lut.id, .aux_count = 4 } },
        );

        // Col 3: dissolve — the solid sprite burned away by the built-in
        // procedural noise at threshold 0.5, an orange glow on the burn front
        // (edge_width 6px). aux_texture = 0 → procedural noise (no bound texture).
        gfx.drawTextureProMaterial(
            burn,
            src48,
            .{ .x = 156, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .dissolve, .uniforms = .{ .r = 1.0, .g = 0.5, .b = 0.1, .scalar0 = 0.5, .scalar1 = 6.0 } },
        );

        // Col 4: outline — the transparent-field OPAQUE square wrapped in a green
        // silhouette (thickness 3px, softness 0.4 feather). base.a ∈ {0,1}.
        gfx.drawTextureProMaterial(
            shape,
            src48,
            .{ .x = 228, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .outline, .uniforms = .{ .r = 0.1, .g = 0.9, .b = 0.2, .a = 1.0, .scalar0 = 3.0, .scalar1 = 0.4 } },
        );

        // Col 5: outline on an ANTI-ALIASED soft disc — the fractional-alpha edge
        // case. Same green outline; the composite math (over-operator) is only
        // exercised here where 0 < base.a < 1, catching a double-attenuation bug.
        gfx.drawTextureProMaterial(
            disc,
            src48,
            .{ .x = 300, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .outline, .uniforms = .{ .r = 0.1, .g = 0.9, .b = 0.2, .a = 1.0, .scalar0 = 3.0, .scalar1 = 0.4 } },
        );

        // Col 6: ATLAS outline — frame 0 of the 96px atlas (sub-rect 0..48) whose
        // neighbour frame 1 (48..96) is solid opaque red. The per-frame tap gate
        // must keep the green outline OFF frame 0's right edge (no red-neighbour
        // bleed). Guards #2.
        const atlas_f0 = gfx.Rectangle{ .x = 0, .y = 0, .width = 48, .height = 48 };
        gfx.drawTextureProMaterial(
            atlas2,
            atlas_f0,
            .{ .x = 372, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .outline, .uniforms = .{ .r = 0.1, .g = 0.9, .b = 0.2, .a = 1.0, .scalar0 = 3.0, .scalar1 = 0.4 } },
        );

        // Col 7: ATLAS dissolve — frame 1 (sub-rect 48..96, solid red) burned by
        // the procedural noise remapped to sprite-LOCAL UV, so the noise cell size
        // is per-frame-consistent (not scaled by the frame's atlas fraction).
        // Guards #1.
        const atlas_f1 = gfx.Rectangle{ .x = 48, .y = 0, .width = 48, .height = 48 };
        gfx.drawTextureProMaterial(
            atlas2,
            atlas_f1,
            .{ .x = 444, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.white,
            .{ .effect = .dissolve, .uniforms = .{ .r = 1.0, .g = 0.5, .b = 0.1, .scalar0 = 0.5, .scalar1 = 6.0 } },
        );

        // Col 8: TINT-FADED outline — the opaque square at tint.a = 0.5. The
        // outline must fade WITH the sprite (outline_a scales by v_color0.a), so
        // it reads ~half-strength vs col 4. Guards #3.
        gfx.drawTextureProMaterial(
            shape,
            src48,
            .{ .x = 516, .y = 24, .width = 48, .height = 48 },
            origin,
            0,
            gfx.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            .{ .effect = .outline, .uniforms = .{ .r = 0.1, .g = 0.9, .b = 0.2, .a = 1.0, .scalar0 = 3.0, .scalar1 = 0.4 } },
        );

        window.endFrame();
    }
}

/// Compare two TGAs (both written by `captureHeadless`: 18-byte header + BGRA
/// body, identical dims). Returns true when within tolerance.
fn withinTolerance(golden: []const u8, candidate: []const u8) bool {
    if (golden.len != candidate.len or golden.len <= 18) return false;
    const body_len = golden.len - 18;
    var outliers: usize = 0;
    var i: usize = 18;
    while (i < golden.len) : (i += 1) {
        const d = @as(i32, golden[i]) - @as(i32, candidate[i]);
        if (@abs(d) > CHANNEL_TOL) outliers += 1;
    }
    const frac = @as(f32, @floatFromInt(outliers)) / @as(f32, @floatFromInt(body_len));
    std.debug.print("GOLDEN: outlier bytes {d}/{d} ({d:.3}%)\n", .{ outliers, body_len, frac * 100 });
    return frac <= MAX_OUTLIER_FRAC;
}

pub fn main() !void {
    const bless = options.bless;

    if (!window.initHeadless(W, H)) {
        std.debug.print("GOLDEN_RESULT: HEADLESS_INIT_FAILED\n", .{});
        std.process.exit(2);
    }
    std.debug.print("GOLDEN: headless init OK — renderer={s}\n", .{@tagName(bgfx.getRendererType())});

    renderScene();

    const out_base = if (bless) GOLDEN_BASE else CANDIDATE_BASE;
    // Guarantee the output dir exists before captureHeadless fopens the TGA —
    // both the candidate (`zig-out/`) and the golden (`test/golden/`) dirnames.
    ensureParentDir(out_base);
    if (!window.captureHeadless(out_base)) {
        std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED\n", .{});
        window.closeWindow();
        std.process.exit(3);
    }
    window.closeWindow();

    if (bless) {
        std.debug.print("GOLDEN_RESULT: BLESSED {s}\n", .{GOLDEN_PATH});
        std.process.exit(0);
    }

    const golden = readFile(GOLDEN_PATH) orelse {
        std.debug.print("GOLDEN_RESULT: GOLDEN_MISSING (run: zig build material-golden-bless)\n", .{});
        std.process.exit(5);
    };
    defer std.heap.page_allocator.free(golden);
    const candidate = readFile(CANDIDATE_PATH) orelse {
        std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED (candidate unreadable)\n", .{});
        std.process.exit(3);
    };
    defer std.heap.page_allocator.free(candidate);

    if (withinTolerance(golden, candidate)) {
        std.debug.print("GOLDEN_RESULT: OK\n", .{});
        std.process.exit(0);
    }
    std.debug.print("GOLDEN_RESULT: GOLDEN_MISMATCH\n", .{});
    std.process.exit(4);
}
