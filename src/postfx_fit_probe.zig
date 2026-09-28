//! Post-fx keeps the scene's shape on a surface that isn't the design size
//! (labelle-bgfx#120).
//!
//! Post-fx renders the scene into a DESIGN-sized render target, then
//! composites that target onto the physical framebuffer with the letterbox.
//! The letterbox belongs to the composite only. The bug: the scene pass ALSO
//! applied it, so inside the target every x was scaled by
//! physical-fit (0.8 on the SM-T505's 2000x1200 vs an 800x600 design) and a
//! square came out narrow. Invisible on a desktop window at the design size,
//! where the fit is 1.
//!
//! The probe uses the tablet's ratios scaled down: a 200x120 framebuffer
//! and an 80x60 design (fit 0.8 x 1.0). It draws a square directly, then the
//! same square through a design-sized render target composited like post-fx
//! does, reads both back, and compares the red bounding boxes.
//!
//! Prints `PROBE_RESULT:` and sets the exit code:
//!   0 = POSTFX_FIT_OK
//!   2 = HEADLESS_INIT_FAILED
//!   3 = READBACK_NOT_READY
//!   4 = SQUEEZED           (#120 reproduced: the RT square's box differs)
//!   5 = CONTROL_WRONG      (the direct square is not square: the probe
//!                           is not measuring what it thinks)
//!
//! Run with:  zig build postfx-fit-probe

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx");
const window = @import("window");

const W: u16 = 200;
const H: u16 = 120;
const DESIGN_W: i32 = 80;
const DESIGN_H: i32 = 60;

const red: gfx.Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
const white: gfx.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
/// The square, in design pixels.
const square: gfx.Rectangle = .{ .x = 30, .y = 20, .width = 20, .height = 20 };

var pixels: [@as(usize, W) * @as(usize, H) * 4]u8 = undefined;

fn readAll(src: bgfx.TextureHandle) bool {
    const rb = bgfx.createTexture2D(W, H, false, 1, .RGBA8, bgfx.TextureFlags_BlitDst | bgfx.TextureFlags_ReadBack, null, 0);
    if (rb.idx == std.math.maxInt(u16)) return false;
    // `pixels` is file-scope, so destroying on every path is safe (see
    // screen_fill_cover_probe).
    defer bgfx.destroyTexture(rb);
    var dst_region: bgfx.TextureRegion = undefined;
    dst_region.init(rb, 0, 0, W, H);
    var src_region: bgfx.TextureRegion = undefined;
    src_region.init(src, 0, 0, W, H);
    bgfx.blit(0, &dst_region, &src_region);
    const ready = bgfx.readTexture(&dst_region, &pixels);
    var f = bgfx.frame(0);
    var guard: u32 = 0;
    while (f < ready and guard < 64) : (guard += 1) f = bgfx.frame(0);
    return f >= ready;
}

fn isRed(x: usize, y: usize) bool {
    const off = (y * W + x) * 4;
    return pixels[off] > 0x80 and pixels[off + 1] < 0x40 and pixels[off + 2] < 0x40;
}

const Box = struct { x0: usize, y0: usize, x1: usize, y1: usize };

fn redBox() ?Box {
    var b: Box = .{ .x0 = W, .y0 = H, .x1 = 0, .y1 = 0 };
    var any = false;
    for (0..H) |y| for (0..W) |x| if (isRed(x, y)) {
        any = true;
        b.x0 = @min(b.x0, x);
        b.y0 = @min(b.y0, y);
        b.x1 = @max(b.x1, x);
        b.y1 = @max(b.y1, y);
    };
    return if (any) b else null;
}

fn fail(code: u8, result: []const u8) noreturn {
    std.debug.print("PROBE_RESULT: {s}\n", .{result});
    window.closeWindow();
    std.process.exit(code);
}

fn capture() Box {
    _ = bgfx.frame(0);
    _ = bgfx.frame(0);
    if (!readAll(window.headlessColorTexture())) fail(3, "READBACK_NOT_READY");
    return redBox() orelse fail(3, "READBACK_NOT_READY (no red pixels)");
}

pub fn main() !void {
    if (!window.initHeadless(W, H)) {
        std.debug.print("PROBE_RESULT: HEADLESS_INIT_FAILED\n", .{});
        std.process.exit(2);
    }
    defer window.closeWindow();
    gfx.setScreenSize(W, H);
    gfx.setDesignSize(DESIGN_W, DESIGN_H);
    std.debug.print("PROBE: renderer={s}  framebuffer={d}x{d}  design={d}x{d}\n", .{ @tagName(bgfx.getRendererType()), W, H, DESIGN_W, DESIGN_H });

    // Control: the square drawn straight to the (letterboxed) framebuffer.
    window.clearBackground(0, 0, 255, 255);
    gfx.drawRectangleRec(square, red);
    const direct = capture();

    // Post-fx shape: scene into a design-sized target, then composite it
    // over the design canvas (the letterbox applies here, and only here).
    const rt = gfx.createRenderTarget(@intCast(DESIGN_W), @intCast(DESIGN_H));
    if (rt == gfx.INVALID_RENDER_TARGET) fail(3, "READBACK_NOT_READY (render target creation failed)");
    defer gfx.destroyRenderTarget(rt);
    window.clearBackground(0, 0, 255, 255);
    gfx.beginRenderTarget(rt);
    gfx.drawRectangleRec(square, red);
    gfx.endRenderTarget();
    gfx.drawRenderTarget(rt, .{ .x = 0, .y = 0, .width = @floatFromInt(DESIGN_W), .height = @floatFromInt(DESIGN_H) }, white);
    const via_rt = capture();

    const dw = direct.x1 - direct.x0 + 1;
    const dh = direct.y1 - direct.y0 + 1;
    const rw = via_rt.x1 - via_rt.x0 + 1;
    const rh = via_rt.y1 - via_rt.y0 + 1;
    std.debug.print("PROBE: direct  box x{d}..{d} y{d}..{d} ({d}x{d})\n", .{ direct.x0, direct.x1, direct.y0, direct.y1, dw, dh });
    std.debug.print("PROBE: via RT  box x{d}..{d} y{d}..{d} ({d}x{d})\n", .{ via_rt.x0, via_rt.x1, via_rt.y0, via_rt.y1, rw, rh });

    // The design square scales by 2 into this framebuffer: 40x40 physical.
    if (@abs(@as(i64, @intCast(dw)) - @as(i64, @intCast(dh))) > 1) fail(5, "CONTROL_WRONG (the directly drawn square is not square)");
    const tol: usize = 1; // bilinear edge of the composite
    const close = struct {
        fn f(a: usize, b: usize) bool {
            return (if (a > b) a - b else b - a) <= tol;
        }
    }.f;
    if (!close(direct.x0, via_rt.x0) or !close(direct.x1, via_rt.x1) or
        !close(direct.y0, via_rt.y0) or !close(direct.y1, via_rt.y1))
    {
        fail(4, "SQUEEZED (#120 reproduced: the render-target pass applied the framebuffer letterbox)");
    }
    std.debug.print("PROBE_RESULT: POSTFX_FIT_OK\n", .{});
}
