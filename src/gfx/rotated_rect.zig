//! Corners of a rectangle rotated about its centre (labelle-bgfx#98).
//!
//! Pure math, no bgfx, so it runs on the host. `draw.drawRectanglePro`
//! fills the quad these corners describe. The convention MUST match
//! labelle-core's `drawRectanglePro` fallback in `backend_contract.zig`,
//! which outlines the same four points on backends without a fill:
//! centre-anchored, `rotation` in radians, world-space rotation
//!   x' = cx + x*cos - y*sin
//!   y' = cy + x*sin + y*cos
//! applied BEFORE the camera/y-axis transform. An outline from the shim and
//! a fill from here therefore land on the same pixels.
const std = @import("std");

pub const Point = struct { x: f32, y: f32 };

/// Corners in order: (-w/2,-h/2), (w/2,-h/2), (w/2,h/2), (-w/2,h/2), rotated.
pub fn corners(center_x: f32, center_y: f32, width: f32, height: f32, rotation: f32) [4]Point {
    const hw = width * 0.5;
    const hh = height * 0.5;
    const cos_r = @cos(rotation);
    const sin_r = @sin(rotation);
    const local = [4]Point{
        .{ .x = -hw, .y = -hh },
        .{ .x = hw, .y = -hh },
        .{ .x = hw, .y = hh },
        .{ .x = -hw, .y = hh },
    };
    var out: [4]Point = undefined;
    for (local, 0..) |p, i| {
        out[i] = .{
            .x = center_x + p.x * cos_r - p.y * sin_r,
            .y = center_y + p.x * sin_r + p.y * cos_r,
        };
    }
    return out;
}

fn expectPoint(expected: Point, actual: Point) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 1e-4);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 1e-4);
}

test "rotation 0 gives the axis-aligned rectangle" {
    const c = corners(10, 20, 8, 4, 0);
    try expectPoint(.{ .x = 6, .y = 18 }, c[0]);
    try expectPoint(.{ .x = 14, .y = 18 }, c[1]);
    try expectPoint(.{ .x = 14, .y = 22 }, c[2]);
    try expectPoint(.{ .x = 6, .y = 22 }, c[3]);
}

test "a quarter turn maps +x onto +y (the core shim's direction)" {
    // Local (w/2, -h/2) = (4, -2) rotated +90deg: x' = 0 - (-2)(1) = 2,
    // y' = 4(1) + 0 = 4, i.e. the long side now runs along y.
    const c = corners(0, 0, 8, 4, std.math.pi / 2.0);
    try expectPoint(.{ .x = 2, .y = 4 }, c[1]);
    try expectPoint(.{ .x = -2, .y = 4 }, c[2]);
    try expectPoint(.{ .x = -2, .y = -4 }, c[3]);
    try expectPoint(.{ .x = 2, .y = -4 }, c[0]);
}

test "rotation keeps the centre and the side lengths" {
    const c = corners(3, -7, 10, 6, 0.7);
    var sx: f32 = 0;
    var sy: f32 = 0;
    for (c) |p| {
        sx += p.x;
        sy += p.y;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 3), sx / 4, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -7), sy / 4, 1e-4);
    const top = std.math.hypot(c[1].x - c[0].x, c[1].y - c[0].y);
    const side = std.math.hypot(c[2].x - c[1].x, c[2].y - c[1].y);
    try std.testing.expectApproxEqAbs(@as(f32, 10), top, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 6), side, 1e-4);
}
