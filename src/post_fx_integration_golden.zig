//! End-to-end gfx×bgfx integration golden for the post-fx ping-pong stack
//! (labelle-gfx#305 P2). Where `post_fx_golden.zig` drives `applyPostPass`
//! DIRECTLY (one fresh target per pass output, so it sidesteps the driver's
//! two-buffer ping-pong ordering), THIS harness drives the REAL gfx
//! `PostFxDriver` — the exact composition logic the engine runs — over the REAL
//! bgfx backend, surfaceless-headless (`window.initHeadless`, the #36 path).
//!
//! It is the missing integration proof: the gfx driver's two-buffer ping-pong
//! assumes `applyPostPass` calls execute in SUBMISSION order, but bgfx executes
//! views in ascending view-id order. On an EVEN-length stack (bloom→crt) the
//! driver reads `target_b` (via a later-issued pass on a LOWER view id) before
//! the earlier pass has written it — wrong output — unless `applyPostPass`
//! sequences its submits through a monotonic transient view band (the fix).
//!
//! Variants (build option `variant`, 1/2/3 = pass count):
//!   2 (bloom_crt) — the canonical EVEN stack; the bug-exposing case. Diffed
//!       against the independently-produced reference golden
//!       `post_fx_bloom_crt.tga` (blessed by the one-target-per-pass
//!       `post_fx_golden` harness, which is correct by construction). A correct
//!       driver reproduces that reference exactly; the buggy driver does not.
//!   1 (single)  — ODD length-1 stack (bloom only); no-regression.
//!   3 (triple)  — ODD length-3 stack (bloom→vignette→crt); no-regression.
//!
//! Modes (build option `bless`): --bless writes the committed golden; check
//! renders a candidate and diffs it with a per-channel tolerance (the CI gate).
//!
//! Exit codes match post_fx_golden.zig:
//!   0 OK/BLESSED · 2 HEADLESS_INIT_FAILED · 3 CAPTURE/RT_CREATE_FAILED ·
//!   4 GOLDEN_MISMATCH · 5 GOLDEN_MISSING

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx"); // the bgfx backend impl (draw helpers + Backend(Impl) contract)
const gfx_lib = @import("labelle-gfx"); // the REAL gfx library — PostFxDriver + PostPass
const window = @import("window");
const options = @import("golden_options");

const W: u16 = 192;
const H: u16 = 128;

/// The driver instantiated over the bgfx backend — precisely what the engine's
/// `RetainedEngineWith` holds. This is the whole point: exercise gfx's
/// composition logic against the real backend seam.
const Driver = gfx_lib.PostFxDriver(gfx);

// GPU rasterisation is not bit-exact across drivers/refreshes; allow a small
// per-channel delta and a tiny outlier fraction (identical to post_fx_golden).
const CHANNEL_TOL: i32 = 14;
const MAX_OUTLIER_FRAC: f32 = 0.03;

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

fn goldenBase() [:0]const u8 {
    return switch (options.variant) {
        1 => "test/golden/post_fx_driver_single",
        3 => "test/golden/post_fx_driver_triple",
        // The 2-pass driver output must match the one-target-per-pass reference.
        else => "test/golden/post_fx_bloom_crt",
    };
}

fn goldenPath() [:0]const u8 {
    return switch (options.variant) {
        1 => "test/golden/post_fx_driver_single.tga",
        3 => "test/golden/post_fx_driver_triple.tga",
        else => "test/golden/post_fx_bloom_crt.tga",
    };
}

fn candidateBase() [:0]const u8 {
    return switch (options.variant) {
        1 => "zig-out/post_fx_driver_single_candidate",
        3 => "zig-out/post_fx_driver_triple_candidate",
        else => "zig-out/post_fx_driver_bloom_crt_candidate",
    };
}

fn candidatePath() [:0]const u8 {
    return switch (options.variant) {
        1 => "zig-out/post_fx_driver_single_candidate.tga",
        3 => "zig-out/post_fx_driver_triple_candidate.tga",
        else => "zig-out/post_fx_driver_bloom_crt_candidate.tga",
    };
}

/// The pass stack for this variant. Uniforms MATCH post_fx_golden.zig's bloom
/// and crt so the 2-pass driver output is pixel-comparable to that reference.
fn stack() []const gfx_lib.PostPass {
    const bloom = gfx_lib.PostPass{ .kind = .bloom, .uniforms = .{ .scalar0 = 0.62, .scalar1 = 0.85, .scalar2 = 2.0 } };
    const crt = gfx_lib.PostPass{ .kind = .crt, .uniforms = .{ .scalar0 = 0.18, .scalar1 = 0.40, .scalar2 = 0.30, .scalar3 = 0.004 } };
    const vignette = gfx_lib.PostPass{ .kind = .vignette, .uniforms = .{ .scalar0 = 0.55, .scalar1 = 0.35 } };
    const S = struct {
        var single = [_]gfx_lib.PostPass{undefined} ** 1;
        var pair = [_]gfx_lib.PostPass{undefined} ** 2;
        var triple = [_]gfx_lib.PostPass{undefined} ** 3;
    };
    return switch (options.variant) {
        1 => blk: {
            S.single = .{bloom};
            break :blk &S.single;
        },
        3 => blk: {
            S.triple = .{ bloom, vignette, crt };
            break :blk &S.triple;
        },
        else => blk: {
            S.pair = .{ bloom, crt };
            break :blk &S.pair;
        },
    };
}

/// makePath-style parent-dir creation (the P1 CI bug we don't repeat), copied
/// verbatim from post_fx_golden.zig.
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

/// The fixed source scene — byte-identical to post_fx_golden.zig's so the 2-pass
/// driver output can be diffed against that harness's reference golden.
fn drawScene() void {
    const full = rect(0, 0, @floatFromInt(W), @floatFromInt(H));
    gfx.drawRectangleRec(full, gfx.Color{ .r = 18, .g = 20, .b = 30, .a = 255 });
    gfx.drawRectangleRec(rect(76, 44, 40, 40), gfx.Color{ .r = 255, .g = 244, .b = 210, .a = 255 });
    gfx.drawRectangleRec(rect(20, 30, 18, 68), gfx.Color{ .r = 235, .g = 40, .b = 40, .a = 255 });
    gfx.drawRectangleRec(rect(154, 30, 18, 68), gfx.Color{ .r = 40, .g = 90, .b = 235, .a = 255 });
    gfx.drawRectangleRec(rect(70, 96, 52, 12), gfx.Color{ .r = 40, .g = 210, .b = 90, .a = 255 });
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
    std.debug.print("GOLDEN: headless init OK — renderer={s} variant={d}\n", .{ @tagName(bgfx.getRendererType()), options.variant });

    gfx.setScreenSize(W, H);
    gfx.setDesignSize(W, H);

    // The real driver: seed its ordered stack, then let IT own the ping-pong
    // targets + the src→dst hop sequencing across frames.
    var driver: Driver = .{};
    driver.setPostFx(stack());

    // Two belt-and-braces frames (matching post_fx_golden / mirror_probe): the
    // render-target views sequence before the primary, so one frame already
    // resolves the whole chain; the second guards first-frame warmup.
    var frame: u32 = 0;
    while (frame < 2) : (frame += 1) {
        window.clearBackground(18, 20, 30, 255);
        window.beginFrame();

        // Driver redirects the scene into target_a (offscreen)…
        const redirected = driver.begin(W, H);
        if (!redirected) {
            std.debug.print("GOLDEN_RESULT: RT_CREATE_FAILED (driver did not redirect — backend seam missing?)\n", .{});
            driver.deinit();
            window.closeWindow();
            std.process.exit(3);
        }
        drawScene();
        // …then runs the ping-pong pass chain and composites to the backbuffer.
        driver.resolve(W, H);

        window.endFrame();
    }

    const out_base = if (bless) goldenBase() else candidateBase();
    ensureParentDir(out_base);
    if (!window.captureHeadless(out_base)) {
        std.debug.print("GOLDEN_RESULT: CAPTURE_FAILED\n", .{});
        driver.deinit();
        window.closeWindow();
        std.process.exit(3);
    }
    driver.deinit();
    window.closeWindow();

    if (bless) {
        std.debug.print("GOLDEN_RESULT: BLESSED {s}\n", .{goldenPath()});
        std.process.exit(0);
    }

    const golden = readFile(goldenPath()) orelse {
        std.debug.print("GOLDEN_RESULT: GOLDEN_MISSING (run the -bless step)\n", .{});
        std.process.exit(5);
    };
    defer std.heap.page_allocator.free(golden);
    const candidate = readFile(candidatePath()) orelse {
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
