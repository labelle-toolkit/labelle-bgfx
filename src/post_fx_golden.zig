//! Headless golden harness for the bgfx post-fx seam (labelle-gfx#305 P2 Slice B,
//! RFC-MATERIAL-POSTFX §2.4 / §6). Renders a FIXED scene into a render target,
//! runs a `bloom` → `crt` post-fx stack through `applyPostPass` via the render-
//! target ping-pong, composites the final target onto the primary, and captures
//! the primary FULLY headless (surfaceless bgfx, Metal/Vulkan offscreen FB, no
//! window / no display server — the `initHeadless` path proven by `mirror_probe`
//! / `screenshot_probe`), dumping an uncompressed 32-bit TGA via
//! `window.captureHeadless`.
//!
//! Ping-pong ordering note: this harness allocates a FRESH target per pass output
//! (scene→t0, bloom t0→t1, crt t1→t2), so every pass's write is a distinct target
//! read only by the NEXT pass — a correct, contiguous chain independent of how
//! `applyPostPass` sequences its bgfx views. It therefore does NOT exercise the
//! real gfx `PostFxDriver`'s TWO-buffer ping-pong (which reuses two targets and,
//! on an even stack, would read a target before an earlier pass wrote it under
//! bgfx's ascending-view execution). That driver↔bgfx ordering is proven by
//! `src/post_fx_integration_golden.zig`, which drives the real driver end-to-end;
//! the fix that makes it correct is the monotonic transient post-fx view band in
//! `gfx/render_target.zig` (labelle-gfx#305). Keep BOTH: this pins the shaders,
//! the integration golden pins the driver seam.
//!
//! Two modes (baked at build time, like material_golden):
//!   --bless (material-golden-bless-style step) : write the committed golden.
//!   (check) : render a candidate TGA + diff it against the committed golden with
//!             a per-channel tolerance (GPU rasterisation is not bit-exact). The
//!             CI gate.
//!
//! Exit codes:
//!   0 = OK / BLESSED
//!   2 = HEADLESS_INIT_FAILED   (no Metal/Vulkan device — e.g. no GPU in CI)
//!   3 = CAPTURE_FAILED / RT_CREATE_FAILED
//!   4 = GOLDEN_MISMATCH
//!   5 = GOLDEN_MISSING         (check mode, no committed golden — run --bless)
//!
//! Run with:  zig build post-fx-golden        (check)
//!            zig build post-fx-golden-bless   (regenerate)

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx");
const window = @import("window");
const options = @import("golden_options");

const W: u16 = 192;
const H: u16 = 128;

const GOLDEN_BASE: [:0]const u8 = "test/golden/post_fx_bloom_crt";
const GOLDEN_PATH: [:0]const u8 = "test/golden/post_fx_bloom_crt.tga";
const CANDIDATE_BASE: [:0]const u8 = "zig-out/post_fx_bloom_crt_candidate";
const CANDIDATE_PATH: [:0]const u8 = "zig-out/post_fx_bloom_crt_candidate.tga";

// GPU rasterisation is not bit-exact across drivers/refreshes; allow a small
// per-channel delta and a tiny outlier fraction. A broken pass moves large areas
// well past this, so the gate still trips.
const CHANNEL_TOL: i32 = 14;
const MAX_OUTLIER_FRAC: f32 = 0.03;

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

/// makePath-style: create the parent-directory chain of `base` so
/// `captureHeadless`'s `fopen(.., "wb")` can't fail on a CLEAN checkout where the
/// output dir (`zig-out/` / `test/golden/`) does not pre-exist — the P1 CI bug we
/// don't repeat. Zig 0.16 dropped `std.fs.cwd()` and we already link libc, so
/// mkdir each ancestor prefix; an already-existing dir (EEXIST) is harmless.
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

fn rect(x: f32, y: f32, w: f32, h: f32) gfx.Rectangle {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

/// Draw the fixed source scene into the currently-active render target: a dark
/// backdrop, a BRIGHT central block (the bloom's bright-pass subject), and a few
/// saturated bars (edge colour for the CRT's chromatic aberration + shadow mask).
fn drawScene() void {
    const full = rect(0, 0, @floatFromInt(W), @floatFromInt(H));
    gfx.drawRectangleRec(full, gfx.Color{ .r = 18, .g = 20, .b = 30, .a = 255 });

    // Bright warm block — well above the bloom threshold, so it blooms.
    gfx.drawRectangleRec(rect(76, 44, 40, 40), gfx.Color{ .r = 255, .g = 244, .b = 210, .a = 255 });

    // Saturated side bars for aberration/mask contrast.
    gfx.drawRectangleRec(rect(20, 30, 18, 68), gfx.Color{ .r = 235, .g = 40, .b = 40, .a = 255 });
    gfx.drawRectangleRec(rect(154, 30, 18, 68), gfx.Color{ .r = 40, .g = 90, .b = 235, .a = 255 });
    gfx.drawRectangleRec(rect(70, 96, 52, 12), gfx.Color{ .r = 40, .g = 210, .b = 90, .a = 255 });
}

/// Compare two TGAs (both written by `captureHeadless`: 18-byte header + BGRA
/// body, identical dims). True when within tolerance.
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

    gfx.setScreenSize(W, H);
    gfx.setDesignSize(W, H);

    // One target per pass output (see the ping-pong ordering note above): the
    // scene lands in t0, bloom writes t1, crt writes t2 — strictly increasing
    // views, so every read resolves before its consumer runs.
    const t0 = gfx.createRenderTarget(W, H);
    const t1 = gfx.createRenderTarget(W, H);
    const t2 = gfx.createRenderTarget(W, H);
    if (t0 == gfx.INVALID_RENDER_TARGET or t1 == gfx.INVALID_RENDER_TARGET or t2 == gfx.INVALID_RENDER_TARGET) {
        std.debug.print("GOLDEN_RESULT: RT_CREATE_FAILED\n", .{});
        window.closeWindow();
        std.process.exit(3);
    }

    const bloom = gfx.PostPass{ .kind = .bloom, .uniforms = .{ .scalar0 = 0.62, .scalar1 = 0.85, .scalar2 = 2.0 } };
    const crt = gfx.PostPass{ .kind = .crt, .uniforms = .{ .scalar0 = 0.18, .scalar1 = 0.40, .scalar2 = 0.30, .scalar3 = 0.004 } };

    // Two belt-and-braces frames (matching material_golden / mirror_probe): the
    // render-target views sequence before the primary, so one frame already
    // resolves the whole chain; the second guards against any first-frame warmup.
    var frame: u32 = 0;
    while (frame < 2) : (frame += 1) {
        window.clearBackground(18, 20, 30, 255);
        window.beginFrame();

        // Scene → t0.
        gfx.beginRenderTarget(t0);
        drawScene();
        gfx.endRenderTarget();

        // bloom t0 → t1, then crt t1 → t2.
        gfx.applyPostPass(bloom, t0, t1);
        gfx.applyPostPass(crt, t1, t2);

        // Composite the final target onto the primary (the same forwarder the
        // transport mirror uses); captureHeadless reads the primary FB.
        gfx.drawRenderTarget(t2, rect(0, 0, @floatFromInt(W), @floatFromInt(H)), gfx.white);

        window.endFrame();
    }

    const out_base = if (bless) GOLDEN_BASE else CANDIDATE_BASE;
    ensureParentDir(out_base);
    if (!window.captureHeadless(out_base)) {
        std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED\n", .{});
        gfx.destroyRenderTarget(t0);
        gfx.destroyRenderTarget(t1);
        gfx.destroyRenderTarget(t2);
        window.closeWindow();
        std.process.exit(3);
    }
    gfx.destroyRenderTarget(t0);
    gfx.destroyRenderTarget(t1);
    gfx.destroyRenderTarget(t2);
    window.closeWindow();

    if (bless) {
        std.debug.print("GOLDEN_RESULT: BLESSED {s}\n", .{GOLDEN_PATH});
        std.process.exit(0);
    }

    const golden = readFile(GOLDEN_PATH) orelse {
        std.debug.print("GOLDEN_RESULT: GOLDEN_MISSING (run: zig build post-fx-golden-bless)\n", .{});
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
