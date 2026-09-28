//! Rotated filled rectangles really FILL (labelle-bgfx#98).
//!
//! Without a backend `drawRectanglePro`, labelle-core's shim outlines any
//! rectangle whose rotation is not 0, so a spinning filled square showed
//! as a spinning outline. This probe renders through the real bgfx path
//! and reads the pixels back:
//!
//!   1. A 45deg square is red at its CENTRE. The outline fallback leaves the
//!      centre background, so this is the check that tells fill from outline.
//!   2. The unrotated square's corner is background: the rotation happened.
//!   3. Direction matches the shim. A long thin bar at +30deg covers the world
//!      point along +30deg and NOT its mirror at -30deg. Both points are
//!      located by first drawing a marker there with `drawRectangleRec`, so
//!      the check holds whichever way the y axis points.
//!   4. Rotation 0 is pixel-identical to `drawRectangleRec`.
//!
//! Prints `PROBE_RESULT:` and sets the exit code:
//!   0 = ROTATED_RECT_FILLED
//!   2 = HEADLESS_INIT_FAILED
//!   3 = READBACK_NOT_READY
//!   4 = NOT_FILLED            (#98 reproduced: the centre is background)
//!   5 = NOT_ROTATED           (the axis-aligned corner is covered)
//!   6 = WRONG_DIRECTION       (the bar covers the mirrored point)
//!   7 = ROTATION_ZERO_DIFFERS (rotation 0 is not drawRectangleRec's pixels)
//!   8 = MARKER_NOT_FOUND      (the probe could not locate its own marker,
//!                              so it is not measuring what it thinks)
//!
//! Run with:  zig build rotated-rect-probe

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx");
const window = @import("window");

const W: u16 = 128;
const H: u16 = 128;
const CX: f32 = 64;
const CY: f32 = 64;

const red: gfx.Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
const green: gfx.Color = .{ .r = 0, .g = 255, .b = 0, .a = 255 };

var pixels: [@as(usize, W) * @as(usize, H) * 4]u8 = undefined;
var snapshot: [@as(usize, W) * @as(usize, H) * 4]u8 = undefined;

fn readAll(src: bgfx.TextureHandle) bool {
    const rb = bgfx.createTexture2D(W, H, false, 1, .RGBA8, bgfx.TextureFlags_BlitDst | bgfx.TextureFlags_ReadBack, null, 0);
    if (rb.idx == std.math.maxInt(u16)) {
        std.debug.print("PROBE: readback texture allocation failed\n", .{});
        return false;
    }
    // Same lifetime reasoning as screen_fill_cover_probe: `pixels` is
    // file-scope, so destroying on every path is safe.
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

fn at(x: usize, y: usize) [4]u8 {
    const off = (y * W + x) * 4;
    return .{ pixels[off], pixels[off + 1], pixels[off + 2], pixels[off + 3] };
}

fn isRed(p: [4]u8) bool {
    return p[0] > 0x80 and p[1] < 0x40 and p[2] < 0x40;
}

fn isGreen(p: [4]u8) bool {
    return p[1] > 0x80 and p[0] < 0x40 and p[2] < 0x40;
}

/// Clear to blue, run `draw`, flush, read back. Exits on a failed readback.
fn render(comptime draw: fn () void) void {
    window.clearBackground(0, 0, 255, 255);
    draw();
    _ = bgfx.frame(0);
    _ = bgfx.frame(0);
    if (!readAll(window.headlessColorTexture())) fail(3, "READBACK_NOT_READY", "");
}

fn fail(code: u8, result: []const u8, why: []const u8) noreturn {
    std.debug.print("PROBE_RESULT: {s} {s}\n", .{ result, why });
    window.closeWindow();
    std.process.exit(code);
}

const Pixel = struct { x: usize, y: usize };

/// Centroid of the green pixels in the last readback.
fn greenCentroid() ?Pixel {
    var sx: usize = 0;
    var sy: usize = 0;
    var n: usize = 0;
    for (0..H) |y| for (0..W) |x| if (isGreen(at(x, y))) {
        sx += x;
        sy += y;
        n += 1;
    };
    if (n == 0) return null;
    return .{ .x = sx / n, .y = sy / n };
}

// The bar test's world points: 30 units from the centre along +30deg and -30deg.
const bar_angle: f32 = std.math.pi / 6.0;
const probe_dist: f32 = 30;
const plus = .{ .x = CX + probe_dist * @cos(bar_angle), .y = CY + probe_dist * @sin(bar_angle) };
const minus = .{ .x = CX + probe_dist * @cos(bar_angle), .y = CY - probe_dist * @sin(bar_angle) };

fn drawDiamond() void {
    gfx.drawRectanglePro(CX, CY, 60, 60, std.math.pi / 4.0, red);
}
fn drawMarkerPlus() void {
    gfx.drawRectangleRec(.{ .x = plus.x - 1, .y = plus.y - 1, .width = 3, .height = 3 }, green);
}
fn drawMarkerMinus() void {
    gfx.drawRectangleRec(.{ .x = minus.x - 1, .y = minus.y - 1, .width = 3, .height = 3 }, green);
}
fn drawBar() void {
    gfx.drawRectanglePro(CX, CY, 90, 10, bar_angle, red);
}
fn drawZeroPro() void {
    gfx.drawRectanglePro(CX, CY, 50, 30, 0, red);
}
fn drawZeroRec() void {
    gfx.drawRectangleRec(.{ .x = CX - 25, .y = CY - 15, .width = 50, .height = 30 }, red);
}

pub fn main() !void {
    if (!window.initHeadless(W, H)) {
        std.debug.print("PROBE_RESULT: HEADLESS_INIT_FAILED\n", .{});
        std.process.exit(2);
    }
    defer window.closeWindow();
    gfx.setScreenSize(W, H);
    gfx.setDesignSize(W, H);
    std.debug.print("PROBE: renderer={s}  {d}x{d}\n", .{ @tagName(bgfx.getRendererType()), W, H });

    // 1 + 2: fill, and rotation applied. The 60x60 square at 45deg is a
    // diamond reaching ~42 px from the centre along the axes; its unrotated
    // corner (+28, +28) is 56 px away in L1 distance, so outside.
    render(drawDiamond);
    const centre = at(64, 64);
    const on_axis = at(64, 64 - 34); // inside the diamond, off the centre
    const old_corner = at(64 + 28, 64 + 28);
    std.debug.print("PROBE: diamond centre={x:0>2}{x:0>2}{x:0>2} axis={x:0>2}{x:0>2}{x:0>2} old_corner={x:0>2}{x:0>2}{x:0>2}\n", .{
        centre[0], centre[1], centre[2], on_axis[0], on_axis[1], on_axis[2], old_corner[0], old_corner[1], old_corner[2],
    });
    if (!isRed(centre) or !isRed(on_axis)) fail(4, "NOT_FILLED", "(#98 reproduced: the rotated square's inside is background)");
    if (isRed(old_corner)) fail(5, "NOT_ROTATED", "(the axis-aligned corner is covered)");

    // 3: direction. Locate both world points on screen, then draw the bar.
    render(drawMarkerPlus);
    const p_plus = greenCentroid() orelse fail(8, "MARKER_NOT_FOUND", "(+30deg marker)");
    render(drawMarkerMinus);
    const p_minus = greenCentroid() orelse fail(8, "MARKER_NOT_FOUND", "(-30deg marker)");
    render(drawBar);
    const bar_plus = at(p_plus.x, p_plus.y);
    const bar_minus = at(p_minus.x, p_minus.y);
    std.debug.print("PROBE: bar +30deg at ({d},{d})={x:0>2}{x:0>2}{x:0>2}  mirror at ({d},{d})={x:0>2}{x:0>2}{x:0>2}\n", .{
        p_plus.x, p_plus.y, bar_plus[0], bar_plus[1], bar_plus[2], p_minus.x, p_minus.y, bar_minus[0], bar_minus[1], bar_minus[2],
    });
    if (!isRed(bar_plus) or isRed(bar_minus)) fail(6, "WRONG_DIRECTION", "(the bar does not run along +rotation as labelle-core's shim does)");

    // 4: rotation 0 is drawRectangleRec, pixel for pixel.
    render(drawZeroRec);
    @memcpy(&snapshot, &pixels);
    render(drawZeroPro);
    if (!std.mem.eql(u8, &snapshot, &pixels)) fail(7, "ROTATION_ZERO_DIFFERS", "");

    std.debug.print("PROBE_RESULT: ROTATED_RECT_FILLED\n", .{});
}
