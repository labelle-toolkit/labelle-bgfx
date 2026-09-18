//! Headless golden harness for the bgfx PIXEL-WATER effect (COND-07,
//! labelle-bgfx#100 / RFC-PIXEL-WATER §"BGFX implementation").
//!
//! A DEDICATED capture, separate from `material_golden` on purpose: the water
//! effect must not be able to pass by re-blessing the existing material golden,
//! and the existing material/post-fx goldens must keep passing unchanged.
//!
//! Renders a FIXED-TIME scene (`TIME` below — SIMULATION seconds, never a wall
//! clock, so the capture is deterministic) covering, in order:
//!   A  fill levels + the waves flag ....... level 0 (no water at all) / 0.35
//!      waves OFF / 0.35 waves ON / level 1.0 / no reflection texture
//!   B  ripples ............................ age 0 (start) / mid-life / EXPIRED
//!      (must contribute nothing) / two EDGE impacts at x=0 and x=W-1 / a live
//!      entry parked PAST `ripple_count` (must be ignored, not read)
//!   C  grid + reflection .................. zero amplitude (flat) / a ONE
//!      native-pixel displacement / grid_pixels = 4 / a MASKED-OUT hole /
//!      maximum distortion + reflection
//!   D  scaling + independence ............. the same reservoir at native 1x, 2x
//!      and 4x nearest enlargement, then TWO INDEPENDENT reservoirs (their own
//!      masks, reflections, colours, levels and ripples) drawn back to back
//!   E  ATLAS sub-rect + FULL coverage ..... the same reservoir drawn from a
//!      STANDALONE texture and from an offset frame inside a larger atlas
//!      sheet, so `u_water_rect` is exercised at something other than (0,0,1,1);
//!      then a level-1.0 reservoir whose mask reaches the TOP logical row
//!
//! FIXTURE CAVEAT: every texture below is a small PROCEDURAL STAND-IN, rather
//! than the real COND-07 layered assets — a slab of reservoir "art", a
//! bevelled silhouette mask and a banded reflection. They exercise every code
//! path the real art will, but they are explicitly NOT the condenser. Wiring the
//! real artwork has its own `condenser-demo` and `condenser-capture` targets.
//!
//! Beyond the image diff, the capture is checked for four SEMANTIC invariants
//! that a value-only golden would happily bless away (both run in bless mode
//! too, so a regression can never be blessed in):
//!   * an EXPIRED ripple must render bit-identically to no ripple at all,
//!   * a live entry parked past `ripple_count` must be ignored entirely, and
//!   * an ATLAS sub-rect frame must render bit-identically to the same art in a
//!     standalone texture (the `u_water_rect` remap is a coordinate change, not
//!     a different effect) — the check that actually gives the atlas path teeth,
//!   * a reservoir at level 1.0 must leave NO masked cell dry, including the top
//!     logical row, however the surface wave displaces the surface.
//! Each is a pair of tiles drawn with identical parameters except the thing
//! under test, compared region-for-region in the captured framebuffer.
//!
//! BLESS ORDER: the capture always lands on the CANDIDATE first, in both modes.
//! Bless replaces the committed golden only after every check above has passed,
//! so a violating shader can never leave a bad image on disk.
//!
//! Modes, exit codes and tolerance match `material_golden.zig` exactly, plus one:
//!   0 = OK · 2 = HEADLESS_INIT_FAILED · 3 = CAPTURE_FAILED ·
//!   4 = GOLDEN_MISMATCH · 5 = GOLDEN_MISSING · 6 = SEMANTIC_MISMATCH ·
//!   7 = PIXEL_WATER_UNSUPPORTED (the water program did not link here, so the
//!       scene is the static fallback — captured or blessed, it would be a lie)
//!
//! Run with:  zig build pixel-water-golden        (check)
//!            zig build pixel-water-golden-bless  (regenerate)

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx");
const window = @import("window");
const options = @import("golden_options");

const W: u16 = 720;
const H: u16 = 400;

/// Reservoir size in NATIVE ART PIXELS. Origin top-left, +X right, +Y down.
const LW: u32 = 32;
const LH: u32 = 16;

/// The one fixed simulation timestamp the whole scene is evaluated at.
const TIME: f32 = 2.0;
const RIPPLE_DURATION: f32 = 0.8;

const GOLDEN_BASE: [:0]const u8 = "test/golden/pixel_water";
const GOLDEN_PATH: [:0]const u8 = "test/golden/pixel_water.tga";
const CANDIDATE_BASE: [:0]const u8 = "zig-out/pixel_water_candidate";
const CANDIDATE_PATH: [:0]const u8 = "zig-out/pixel_water_candidate.tga";

const CHANNEL_TOL: i32 = 12;
const MAX_OUTLIER_FRAC: f32 = 0.02;

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

/// Create the parent-directory chain of `base` so `captureHeadless`'s fopen
/// can't fail on a clean checkout (same helper as `material_golden.zig`).
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

/// Write `bytes` to `path`, truncating. Used only by the bless path, to promote
/// a candidate that passed every check into the committed golden.
fn writeFile(path: [:0]const u8, bytes: []const u8) bool {
    const file = std.c.fopen(path.ptr, "wb") orelse return false;
    const wrote = std.c.fwrite(bytes.ptr, 1, bytes.len, file);
    const closed = std.c.fclose(file);
    return wrote == bytes.len and closed == 0;
}

fn alloc(n: usize) []u8 {
    return std.heap.page_allocator.alloc(u8, n) catch unreachable;
}

// ── Procedural stand-in fixtures (NOT the COND-07 art — see the header) ──────

/// The reservoir sprite's own static art: a dark interior inside a lighter
/// 1px frame. This is what shows above the surface, outside the mask, and what
/// the unsupported-renderer fallback draws on its own.
fn makeReservoirArt(w: u32, h: u32) gfx.DecodedImage {
    const px = alloc(w * h * 4);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const o = (y * w + x) * 4;
            const frame = x == 0 or y == 0 or x == w - 1 or y == h - 1;
            px[o] = if (frame) 96 else 30;
            px[o + 1] = if (frame) 104 else 34;
            px[o + 2] = if (frame) 112 else 40;
            px[o + 3] = 255;
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// The reservoir silhouette mask: opaque white interior, inset 1px from the
/// frame, with a 3px bevel cut out of each BOTTOM corner. White-on-transparent
/// (the shader reads alpha x max(rgb), so white-on-black works too). `hole`
/// additionally punches a transparent rectangle in the middle, which is the
/// masked-out coverage case.
fn makeMask(w: u32, h: u32, hole: bool) gfx.DecodedImage {
    const px = alloc(w * h * 4);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const o = (y * w + x) * 4;
            var inside = x >= 1 and y >= 1 and x < w - 1 and y < h - 1;
            // Bevelled bottom corners.
            const from_bottom = h - 1 - y;
            if (from_bottom < 3) {
                const inset = 3 - from_bottom;
                if (x < 1 + inset or x >= w - 1 - inset) inside = false;
            }
            if (hole and x >= w / 2 - 4 and x < w / 2 + 4 and y >= h / 2 - 2 and y < h / 2 + 2) {
                inside = false;
            }
            px[o] = if (inside) 255 else 0;
            px[o + 1] = if (inside) 255 else 0;
            px[o + 2] = if (inside) 255 else 0;
            px[o + 3] = if (inside) 255 else 0;
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// A mask whose interior reaches the TOP logical row (y == 0), unlike
/// `makeMask`, which insets one pixel on every side. Bottom corners keep the
/// same bevel. This is the coverage case a full reservoir has to survive: with
/// the ordinary mask the top row is outside the silhouette anyway, so a surface
/// displaced below the top edge at `level == 1` left no visible hole and the
/// golden could not see the bug (labelle-bgfx#100 review round 2).
fn makeMaskToTop(w: u32, h: u32) gfx.DecodedImage {
    const px = alloc(w * h * 4);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const o = (y * w + x) * 4;
            var inside = x >= 1 and x < w - 1 and y < h - 1;
            const from_bottom = h - 1 - y;
            if (from_bottom < 3) {
                const inset = 3 - from_bottom;
                if (x < 1 + inset or x >= w - 1 - inset) inside = false;
            }
            px[o] = if (inside) 255 else 0;
            px[o + 1] = if (inside) 255 else 0;
            px[o + 2] = if (inside) 255 else 0;
            px[o + 3] = if (inside) 255 else 0;
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// The SUPPLIED reflection: already the desired reflection image, in
/// reservoir-local coordinates. Vertical light bars over a dim ground, so a
/// horizontal distortion is plainly visible. Nothing here is captured from the
/// scene and the shader does not flip it.
fn makeReflectionBars(w: u32, h: u32) gfx.DecodedImage {
    const px = alloc(w * h * 4);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const o = (y * w + x) * 4;
            const bar = (x % 7) < 2;
            px[o] = if (bar) 200 else 40;
            px[o + 1] = if (bar) 220 else 56;
            px[o + 2] = if (bar) 235 else 72;
            px[o + 3] = 255;
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// A SECOND, visibly different reflection for the independence case: warm
/// horizontal bands instead of cool vertical bars.
fn makeReflectionBands(w: u32, h: u32) gfx.DecodedImage {
    const px = alloc(w * h * 4);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const o = (y * w + x) * 4;
            const band = (y % 5) < 2;
            px[o] = if (band) 230 else 60;
            px[o + 1] = if (band) 170 else 36;
            px[o + 2] = if (band) 90 else 28;
            px[o + 3] = 255;
        }
    }
    return .{ .pixels = px, .width = w, .height = h };
}

/// The reservoir art embedded as ONE FRAME inside a larger atlas sheet, at
/// offset (`LW`, `LH`) in a 3x3-frame sheet. Every other frame is filled with a
/// garish magenta so any mis-mapped UV shows up instantly rather than sampling
/// something plausible. Drawn with `atlas_rect` below, this must render exactly
/// like the standalone art — that is what `u_water_rect` is for.
fn makeAtlasSheet(w: u32, h: u32) gfx.DecodedImage {
    const sw = w * 3;
    const sh = h * 3;
    const px = alloc(sw * sh * 4);
    const art = makeReservoirArt(w, h);
    defer std.heap.page_allocator.free(art.pixels);
    var y: u32 = 0;
    while (y < sh) : (y += 1) {
        var x: u32 = 0;
        while (x < sw) : (x += 1) {
            const o = (y * sw + x) * 4;
            if (x >= w and x < w * 2 and y >= h and y < h * 2) {
                const src_o = ((y - h) * w + (x - w)) * 4;
                px[o] = art.pixels[src_o];
                px[o + 1] = art.pixels[src_o + 1];
                px[o + 2] = art.pixels[src_o + 2];
                px[o + 3] = art.pixels[src_o + 3];
            } else {
                px[o] = 255;
                px[o + 1] = 0;
                px[o + 2] = 255;
                px[o + 3] = 255;
            }
        }
    }
    return .{ .pixels = px, .width = sw, .height = sh };
}

// ── Scene ────────────────────────────────────────────────────────────────────

const src_rect = gfx.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(LW), .height = @floatFromInt(LH) };
/// The centre frame of `makeAtlasSheet`'s 3x3 sheet: a NON-trivial source rect,
/// so `u_water_rect` is (1/3, 1/3, 2/3, 2/3) rather than the degenerate
/// (0, 0, 1, 1) every other tile produces.
const atlas_rect = gfx.Rectangle{
    .x = @floatFromInt(LW),
    .y = @floatFromInt(LH),
    .width = @floatFromInt(LW),
    .height = @floatFromInt(LH),
};
const origin = gfx.Vector2{ .x = 0, .y = 0 };

const deep = gfx.PixelWaterRgba{ .r = 0.055, .g = 0.106, .b = 0.129, .a = 1.0 };
const surface = gfx.PixelWaterRgba{ .r = 0.314, .g = 0.482, .b = 0.545, .a = 1.0 };
const highlight = gfx.PixelWaterRgba{ .r = 0.678, .g = 0.792, .b = 0.776, .a = 0.55 };

/// The shared baseline every case below tweaks: 0.35 full, waves on, a 1px wave
/// and a 1px reflection distortion (the RFC's "at most one logical pixel"
/// starting point), 8-slot ripple array all idle.
fn baseWater(mask_id: u32, reflect_id: u32) gfx.PixelWaterDraw {
    return .{
        .mask_texture = mask_id,
        .reflection_texture = reflect_id,
        .logical_width = LW,
        .logical_height = LH,
        .grid_pixels = 1,
        .ripple_count = 0,
        .flags = gfx.PIXEL_WATER_FLAG_WAVES,
        .deep = deep,
        .surface = surface,
        .highlight = highlight,
        .level = 0.35,
        .time = TIME,
        .wave_amplitude_pixels = 1.0,
        .wave_period_seconds = 3.0,
        .distortion_pixels = 1.0,
        .reflection_opacity = 0.25,
        .ripple_duration_seconds = RIPPLE_DURATION,
        .ripple_radius_pixels = 6.0,
        .ripple_strength_pixels = 1.0,
    };
}

fn tile(x: f32, y: f32, scale: f32) gfx.Rectangle {
    return .{
        .x = x,
        .y = y,
        .width = @as(f32, @floatFromInt(LW)) * scale,
        .height = @as(f32, @floatFromInt(LH)) * scale,
    };
}

fn renderScene() void {
    gfx.setScreenSize(W, H);
    gfx.setDesignSize(W, H);

    // Every fixture uploads with POINT filtering: this is pixel art, and the
    // native/2x/4x row is meaningless through a bilinear filter. (The water
    // effect additionally FORCES point+clamp on the mask/reflection units, so
    // those two would be nearest regardless — see programs.zig.)
    const art = gfx.uploadTextureFiltered(makeReservoirArt(LW, LH), .point) catch unreachable;
    const art2 = gfx.uploadTextureFiltered(makeReservoirArt(LW, LH), .point) catch unreachable;
    const mask = gfx.uploadTextureFiltered(makeMask(LW, LH, false), .point) catch unreachable;
    const mask_hole = gfx.uploadTextureFiltered(makeMask(LW, LH, true), .point) catch unreachable;
    const mask_top = gfx.uploadTextureFiltered(makeMaskToTop(LW, LH), .point) catch unreachable;
    const refl = gfx.uploadTextureFiltered(makeReflectionBars(LW, LH), .point) catch unreachable;
    const refl2 = gfx.uploadTextureFiltered(makeReflectionBands(LW, LH), .point) catch unreachable;
    const sheet = gfx.uploadTextureFiltered(makeAtlasSheet(LW, LH), .point) catch unreachable;

    const m = mask.id.toInt();
    const mh = mask_hole.id.toInt();
    const mt = mask_top.id.toInt();
    const r = refl.id.toInt();
    const r2 = refl2.id.toInt();

    const xs = [5]f32{ 8, 152, 296, 440, 584 };

    var frame: u32 = 0;
    while (frame < 2) : (frame += 1) {
        window.clearBackground(20, 20, 30, 255);
        window.beginFrame();

        // ── Row A: fill level and the waves flag ─────────────────────────────
        // A1 — level 0. Renders NO water at all: the tile must be the bare
        // reservoir art, even though waves are on and the mask is valid.
        var w_a1 = baseWater(m, r);
        w_a1.level = 0.0;
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[0], 8, 4), origin, 0, gfx.white, w_a1);

        // A2 — 35% full, waves OFF (flag cleared, amplitude left at 2px). The
        // surface must be dead flat, proving the flag gates without destroying
        // the authored amplitude.
        var w_a2 = baseWater(m, r);
        w_a2.flags = 0;
        w_a2.wave_amplitude_pixels = 2.0;
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[1], 8, 4), origin, 0, gfx.white, w_a2);

        // A3 — the same 2px amplitude with waves ON: the flag is the only
        // difference from A2.
        var w_a3 = baseWater(m, r);
        w_a3.wave_amplitude_pixels = 2.0;
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[2], 8, 4), origin, 0, gfx.white, w_a3);

        // A4 — completely full (level 1.0): the surface sits at the top edge and
        // the whole masked interior is water.
        var w_a4 = baseWater(m, r);
        w_a4.level = 1.0;
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[3], 8, 4), origin, 0, gfx.white, w_a4);

        // A5 — no reflection texture (handle 0). The body colours must render on
        // their own; the reflection sampler is still bound to a valid dummy.
        const w_a5 = baseWater(m, 0);
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[4], 8, 4), origin, 0, gfx.white, w_a5);

        // ── Row B: the eight bounded ripple slots ────────────────────────────
        // B1 — one impact at mid-width, age 0 (the instant it lands).
        var w_b1 = baseWater(m, r);
        w_b1.ripple_count = 1;
        w_b1.ripples[0] = .{ .x = 16, .start_time = TIME, .strength = 1.0 };
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[0], 88, 4), origin, 0, gfx.white, w_b1);

        // B2 — the same impact at HALF its lifetime: still visible, fading.
        var w_b2 = baseWater(m, r);
        w_b2.ripple_count = 1;
        w_b2.ripples[0] = .{ .x = 16, .start_time = TIME - RIPPLE_DURATION * 0.5, .strength = 1.0 };
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[1], 88, 4), origin, 0, gfx.white, w_b2);

        // B3 — EXPIRED (age past the duration). Must contribute NOTHING, i.e.
        // render identically to a no-ripple tile at this level/time.
        var w_b3 = baseWater(m, r);
        w_b3.ripple_count = 1;
        w_b3.ripples[0] = .{ .x = 16, .start_time = TIME - RIPPLE_DURATION * 1.5, .strength = 1.0 };
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[2], 88, 4), origin, 0, gfx.white, w_b3);

        // B4 — impacts at BOTH edges (x = 0 and x = LW-1): the falloff must clip
        // cleanly at the reservoir boundary rather than wrapping or smearing.
        var w_b4 = baseWater(m, r);
        w_b4.ripple_count = 2;
        w_b4.ripples[0] = .{ .x = 0, .start_time = TIME - RIPPLE_DURATION * 0.25, .strength = 1.0 };
        w_b4.ripples[1] = .{ .x = @floatFromInt(LW - 1), .start_time = TIME - RIPPLE_DURATION * 0.25, .strength = 1.0 };
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[3], 88, 4), origin, 0, gfx.white, w_b4);

        // B5 — `ripple_count` is 1, but slot 1 holds a LIVE, full-strength entry.
        // Entries at or past the count are ignored, NOT assumed zeroed: this tile
        // must be pixel-identical to B2.
        var w_b5 = baseWater(m, r);
        w_b5.ripple_count = 1;
        w_b5.ripples[0] = .{ .x = 16, .start_time = TIME - RIPPLE_DURATION * 0.5, .strength = 1.0 };
        w_b5.ripples[1] = .{ .x = 4, .start_time = TIME, .strength = 1.0 };
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[4], 88, 4), origin, 0, gfx.white, w_b5);

        // ── Row C: the effect grid, displacement and reflection ──────────────
        // C1 — ZERO amplitude with waves on: a dead-flat surface (the degenerate
        // case the quantizer must not turn into a 1px jitter).
        var w_c1 = baseWater(m, r);
        w_c1.wave_amplitude_pixels = 0.0;
        w_c1.distortion_pixels = 0.0;
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[0], 168, 4), origin, 0, gfx.white, w_c1);

        // C2 — exactly ONE native pixel of displacement (amplitude 1, grid 1):
        // the smallest motion the effect can express.
        var w_c2 = baseWater(m, r);
        w_c2.wave_amplitude_pixels = 1.0;
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[1], 168, 4), origin, 0, gfx.white, w_c2);

        // C3 — a COARSER effect grid (4 art px per cell) with the same 2px
        // amplitude: sampling and displacement both snap to 4px steps.
        var w_c3 = baseWater(m, r);
        w_c3.grid_pixels = 4;
        w_c3.wave_amplitude_pixels = 2.0;
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[2], 168, 4), origin, 0, gfx.white, w_c3);

        // C4 — a mask with a HOLE punched in the middle: those pixels are outside
        // the silhouette, so no water may be drawn there however full the
        // reservoir is. The bare art shows through.
        var w_c4 = baseWater(mh, r);
        w_c4.level = 1.0;
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[3], 168, 4), origin, 0, gfx.white, w_c4);

        // C5 — maximum supplied reflection: full-opacity mix with a 1px
        // quantized distortion, so the bars visibly shear by whole art pixels.
        var w_c5 = baseWater(m, r);
        w_c5.level = 1.0;
        w_c5.reflection_opacity = 1.0;
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[4], 168, 4), origin, 0, gfx.white, w_c5);

        // ── Row D: integer scaling, then two independent reservoirs ──────────
        // D1/D2/D3 — the SAME reservoir at native 1x, 2x and 4x. With nearest
        // sampling the logical grid must survive enlargement: no filtering blur,
        // no atlas bleed, the cell blocks just get bigger.
        const w_d = baseWater(m, r);
        gfx.drawTextureProPixelWater(art, src_rect, tile(8, 248, 1), origin, 0, gfx.white, w_d);
        gfx.drawTextureProPixelWater(art, src_rect, tile(56, 248, 2), origin, 0, gfx.white, w_d);
        gfx.drawTextureProPixelWater(art, src_rect, tile(136, 248, 4), origin, 0, gfx.white, w_d);

        // D4/D5 — TWO INDEPENDENT reservoirs, drawn back to back in one frame
        // with their own masks, reflections, colours, levels and impacts. Neither
        // may leak state into the other (a per-draw uniform upload, not a shared
        // one), and the second must not inherit the first's ripple.
        var w_d4 = baseWater(m, r);
        w_d4.level = 0.6;
        w_d4.ripple_count = 1;
        w_d4.ripples[0] = .{ .x = 8, .start_time = TIME - RIPPLE_DURATION * 0.3, .strength = 1.0 };
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[3], 248, 4), origin, 0, gfx.white, w_d4);

        var w_d5 = baseWater(mh, r2);
        w_d5.level = 0.25;
        w_d5.flags = 0;
        w_d5.reflection_opacity = 0.7;
        w_d5.deep = .{ .r = 0.15, .g = 0.06, .b = 0.04, .a = 1.0 };
        w_d5.surface = .{ .r = 0.55, .g = 0.30, .b = 0.12, .a = 1.0 };
        w_d5.highlight = .{ .r = 0.90, .g = 0.75, .b = 0.45, .a = 0.5 };
        gfx.drawTextureProPixelWater(art2, src_rect, tile(xs[4], 248, 4), origin, 0, gfx.white, w_d5);

        // ── Row E: the atlas sub-rect (`u_water_rect`) ───────────────────────
        // E1/E2 — the SAME reservoir, first from a standalone LWxLH texture
        // (u_water_rect = (0,0,1,1)) and then from the centre frame of a 3x3
        // atlas sheet (u_water_rect = (1/3,1/3,2/3,2/3)). Everything else — the
        // mask, the reflection, the level, the time, the ripples — is identical,
        // so the remap from atlas UV to reservoir-local art pixels is the ONLY
        // variable. The two tiles must come out bit-identical; `semanticChecksPass`
        // asserts exactly that, in bless mode too. Without this the atlas path
        // would be dead code in the capture: every other tile's source rect is
        // the whole texture.
        const w_e = baseWater(m, r);
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[0], 328, 4), origin, 0, gfx.white, w_e);
        gfx.drawTextureProPixelWater(sheet, atlas_rect, tile(xs[1], 328, 4), origin, 0, gfx.white, w_e);

        // E3 — a COMPLETELY FULL reservoir (level 1.0) whose mask reaches the TOP
        // logical row, with waves on at a 2px amplitude. At level 1 the base
        // surface is the top edge, so a positive quantized displacement used to
        // push it BELOW the top row's cell centre and punch dry holes in a
        // 100%-full reservoir. Row A's A4 could not see that: the ordinary mask
        // insets 1px, so its top row is outside the silhouette either way.
        // `semanticChecksPass` walks this tile's top row against the bare art.
        var w_e3 = baseWater(mt, r);
        w_e3.level = 1.0;
        w_e3.wave_amplitude_pixels = 2.0;
        gfx.drawTextureProPixelWater(art, src_rect, tile(xs[2], 328, 4), origin, 0, gfx.white, w_e3);

        window.endFrame();
    }
}

/// Byte-compare two equal-sized regions of a capture. `captureHeadless` writes a
/// top-down 32-bit TGA (descriptor 0x28) after an 18-byte header, so a pixel at
/// screen (x, y) is at `18 + (y * W + x) * 4`. Both regions come from the SAME
/// frame on the SAME device, so an exact compare is right here: these pairs are
/// not "close enough", they are supposed to be the same pixels.
fn regionsEqual(tga: []const u8, ax: u32, ay: u32, bx: u32, by: u32, rw: u32, rh: u32) bool {
    const stride: usize = @as(usize, W) * 4;
    var row: u32 = 0;
    while (row < rh) : (row += 1) {
        const a = 18 + (@as(usize, ay + row) * stride) + @as(usize, ax) * 4;
        const b = 18 + (@as(usize, by + row) * stride) + @as(usize, bx) * 4;
        const n: usize = @as(usize, rw) * 4;
        if (a + n > tga.len or b + n > tga.len) return false;
        if (!std.mem.eql(u8, tga[a .. a + n], tga[b .. b + n])) return false;
    }
    return true;
}

/// Every pixel of region A must DIFFER from the matching pixel of region B.
/// The "no dry holes" invariant needs this shape rather than `regionsEqual`: a
/// water cell that failed to draw composites to exactly the bare sprite art, so
/// a single pixel EQUAL to the bare-art reference is a hole. Same addressing as
/// `regionsEqual` (top-down 32-bit TGA, 18-byte header).
fn regionAllDiffer(tga: []const u8, ax: u32, ay: u32, bx: u32, by: u32, rw: u32, rh: u32) bool {
    const stride: usize = @as(usize, W) * 4;
    var row: u32 = 0;
    while (row < rh) : (row += 1) {
        var col: u32 = 0;
        while (col < rw) : (col += 1) {
            const a = 18 + (@as(usize, ay + row) * stride) + @as(usize, ax + col) * 4;
            const b = 18 + (@as(usize, by + row) * stride) + @as(usize, bx + col) * 4;
            if (a + 4 > tga.len or b + 4 > tga.len) return false;
            if (std.mem.eql(u8, tga[a .. a + 4], tga[b .. b + 4])) {
                std.debug.print("GOLDEN: first dry pixel at screen ({d}, {d})\n", .{ ax + col, ay + row });
                return false;
            }
        }
    }
    return true;
}

/// The invariants described in the module header. Returns false (and says
/// which one broke) on a violation.
fn semanticChecksPass(tga: []const u8) bool {
    var ok = true;
    // An EXPIRED ripple contributes nothing: B3 (a ripple aged past its
    // duration) must equal D3 (the identical reservoir with no ripples at all).
    if (!regionsEqual(tga, 296, 88, 136, 248, 128, 64)) {
        std.debug.print("GOLDEN: SEMANTIC — an expired ripple changed the output (age outside [0, duration) must contribute nothing)\n", .{});
        ok = false;
    }
    // Entries at or past `ripple_count` are ignored, not assumed zeroed: B5
    // (count 1, a live entry in slot 1) must equal B2 (count 1, slot 1 idle).
    if (!regionsEqual(tga, 584, 88, 152, 88, 128, 64)) {
        std.debug.print("GOLDEN: SEMANTIC — a ripple past `ripple_count` was read (entries past the count must be ignored)\n", .{});
        ok = false;
    }
    // An ATLAS sub-rect is a coordinate change, not a different effect: E2 (the
    // centre frame of a 3x3 sheet) must equal E1 (the same art standalone).
    if (!regionsEqual(tga, 8, 328, 152, 328, 128, 64)) {
        std.debug.print("GOLDEN: SEMANTIC — the atlas sub-rect tile differs from the standalone tile (`u_water_rect` remap is wrong)\n", .{});
        ok = false;
    }
    // A reservoir at level 1.0 is COMPLETELY full: no masked cell may be left
    // dry, whatever the surface displacement does. E3 (296, 328) is level 1 with
    // waves at a 2px amplitude and a mask that reaches the TOP logical row, so
    // every pixel of that row's masked span (logical x 1..LW-2, i.e. 30 cells x
    // 4 screen px) must be water — that is, must DIFFER from the same pixels of
    // A1 (8, 8), which is the identical art drawn at level 0 (no water at all).
    // A dry cell composites to exactly the bare art and is caught here.
    if (!regionAllDiffer(tga, 296 + 4, 328, 8 + 4, 8, 30 * 4, 4)) {
        std.debug.print("GOLDEN: SEMANTIC — a full (level 1.0) reservoir left dry cells in its top masked row (the displaced surface must not sink below the full-level endpoint)\n", .{});
        ok = false;
    }
    return ok;
}

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

    // The whole point of the capture is that the WATER program ran. If it failed
    // to link on this renderer every tile silently degrades to the static art —
    // which is the correct runtime behaviour but a useless golden. The check
    // must run AFTER renderScene(): `materialSupported(.pixel_water)` never
    // forces a program build, so before the first water draw it answers the
    // optimistic "bgfx implements this".
    if (!gfx.materialSupported(.pixel_water)) {
        // FAIL, do not warn: in bless mode a warning would let the static-sprite
        // fallback be written over the committed golden, and because every
        // fallback tile is identical where the semantic checks expect equality,
        // those checks would pass too and the run would report BLESSED.
        std.debug.print("GOLDEN_RESULT: PIXEL_WATER_UNSUPPORTED\n", .{});
        window.closeWindow();
        std.process.exit(7);
    }

    // ALWAYS capture to the candidate, bless mode included. Writing straight to
    // `GOLDEN_BASE` would put the image on disk BEFORE the semantic invariants
    // below get to look at it: a shader violating one of them still exited
    // SEMANTIC_MISMATCH, but the committed baseline had already been overwritten
    // with the bad capture and was sitting there, committable. The golden is
    // replaced further down, once every check has passed.
    ensureParentDir(CANDIDATE_BASE);
    if (!window.captureHeadless(CANDIDATE_BASE)) {
        std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED\n", .{});
        window.closeWindow();
        std.process.exit(3);
    }
    window.closeWindow();

    // The semantic invariants run in BOTH modes, against the candidate that was
    // just written, so a broken build cannot be blessed into the golden.
    const written = readFile(CANDIDATE_PATH) orelse {
        std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED (capture unreadable)\n", .{});
        std.process.exit(3);
    };
    defer std.heap.page_allocator.free(written);
    if (!semanticChecksPass(written)) {
        std.debug.print("GOLDEN_RESULT: SEMANTIC_MISMATCH\n", .{});
        std.process.exit(6);
    }

    if (bless) {
        // Only now — every invariant held — does the candidate become the golden.
        ensureParentDir(GOLDEN_BASE);
        if (!writeFile(GOLDEN_PATH, written)) {
            std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED (could not write {s})\n", .{GOLDEN_PATH});
            std.process.exit(3);
        }
        std.debug.print("GOLDEN_RESULT: BLESSED {s}\n", .{GOLDEN_PATH});
        std.process.exit(0);
    }

    const golden = readFile(GOLDEN_PATH) orelse {
        std.debug.print("GOLDEN_RESULT: GOLDEN_MISSING (run: zig build pixel-water-golden-bless)\n", .{});
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
