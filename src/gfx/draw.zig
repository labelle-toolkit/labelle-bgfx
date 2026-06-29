/// Shape draw primitives (rect / circle / line / triangle / polygon)
/// for the bgfx backend. Each function builds a small CPU-side vertex
/// buffer and hands it to `programs.submitFlatTriangles`. State-free
/// at the module level — camera + screen state live in `state.zig`.
const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const programs = @import("programs.zig");

const Color = types.Color;
const Rectangle = types.Rectangle;
const Vector2 = types.Vector2;
const PosTexColorVertex = programs.PosTexColorVertex;

/// Create a flat-color vertex (UV 0,0 for use with the 1x1 white texture).
fn makeVertex(px: f32, py: f32, abgr: u32) PosTexColorVertex {
    return .{
        .x = state.toNdcX(px),
        .y = state.toNdcY(py),
        .u = 0.0,
        .v = 0.0,
        .abgr = abgr,
    };
}

// ── Draw primitives (Backend contract) ─────────────────────────────────

/// Draw a filled rectangle.
pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    const x0 = state.transformX(rec.x);
    const y0 = state.transformY(rec.y);
    const x1 = state.transformX(rec.x + rec.width);
    const y1 = state.transformY(rec.y + rec.height);
    const abgr = tint.toAbgr();

    // Two triangles forming a quad
    const vertices = [6]PosTexColorVertex{
        makeVertex(x0, y0, abgr), makeVertex(x1, y0, abgr), makeVertex(x1, y1, abgr),
        makeVertex(x0, y0, abgr), makeVertex(x1, y1, abgr), makeVertex(x0, y1, abgr),
    };
    programs.submitFlatTriangles(&vertices);
}

/// Draw a filled circle approximated with triangles (fan from center).
/// Vertices are computed directly in NDC space with aspect ratio correction
/// so the circle remains round on non-square windows.
pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    const SEGMENTS = 32;
    const cx = state.transformX(center_x);
    const cy = state.transformY(center_y);
    const scaled_radius = radius * state.cameraZoom();
    const abgr = tint.toAbgr();

    // Convert center to NDC once
    const ndc_cx = state.toNdcX(cx);
    const ndc_cy = state.toNdcY(cy);

    // Convert radius to NDC space separately for X and Y to preserve circularity.
    // toNdcX/Y map pixels to [-1,1] with different denominators (screen_w vs screen_h),
    // so a pixel radius maps to different NDC spans on each axis.
    const sw: f32 = @floatFromInt(state.screenWidth());
    const sh: f32 = @floatFromInt(state.screenHeight());
    // screenWidth/Height are the design canvas; apply the same design→physical
    // fit toNdc uses so the circle stays round (and matching size) when the
    // design is letterboxed into a differently-shaped surface.
    const ndc_rx = scaled_radius * 2.0 / sw * state.fitScaleX();
    const ndc_ry = scaled_radius * 2.0 / sh * state.fitScaleY();

    var vertices: [SEGMENTS * 3]PosTexColorVertex = undefined;

    for (0..SEGMENTS) |i| {
        const angle0 = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f32, SEGMENTS));
        const angle1 = @as(f32, @floatFromInt(i + 1)) * (2.0 * std.math.pi / @as(f32, SEGMENTS));

        vertices[i * 3 + 0] = .{ .x = ndc_cx, .y = ndc_cy, .u = 0.0, .v = 0.0, .abgr = abgr };
        vertices[i * 3 + 1] = .{ .x = ndc_cx + ndc_rx * @cos(angle0), .y = ndc_cy + ndc_ry * @sin(angle0), .u = 0.0, .v = 0.0, .abgr = abgr };
        vertices[i * 3 + 2] = .{ .x = ndc_cx + ndc_rx * @cos(angle1), .y = ndc_cy + ndc_ry * @sin(angle1), .u = 0.0, .v = 0.0, .abgr = abgr };
    }

    programs.submitFlatTriangles(&vertices);
}

/// Draw a line with thickness using a quad (two triangles).
pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, tint: Color) void {
    const sx = state.transformX(start_x);
    const sy = state.transformY(start_y);
    const ex = state.transformX(end_x);
    const ey = state.transformY(end_y);
    const abgr = tint.toAbgr();

    // Compute perpendicular direction for thickness
    const dx = ex - sx;
    const dy = ey - sy;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.0001) return;

    const scaled_thickness = thickness * state.cameraZoom();
    const half = scaled_thickness * 0.5;
    const nx = -dy / len * half; // perpendicular x
    const ny = dx / len * half; // perpendicular y

    const vertices = [6]PosTexColorVertex{
        makeVertex(sx + nx, sy + ny, abgr), makeVertex(sx - nx, sy - ny, abgr), makeVertex(ex - nx, ey - ny, abgr),
        makeVertex(sx + nx, sy + ny, abgr), makeVertex(ex - nx, ey - ny, abgr), makeVertex(ex + nx, ey + ny, abgr),
    };
    programs.submitFlatTriangles(&vertices);
}

/// Draw a filled triangle.
pub fn drawTriangle(v1: Vector2, v2: Vector2, v3: Vector2, tint: Color) void {
    const abgr = tint.toAbgr();
    const vertices = [3]PosTexColorVertex{
        makeVertex(state.transformX(v1.x), state.transformY(v1.y), abgr),
        makeVertex(state.transformX(v2.x), state.transformY(v2.y), abgr),
        makeVertex(state.transformX(v3.x), state.transformY(v3.y), abgr),
    };
    programs.submitFlatTriangles(&vertices);
}

/// Draw a filled convex polygon using a triangle fan.
/// `points` must have at least 3 vertices and the polygon must be convex.
pub fn drawPolygon(points: []const Vector2, tint: Color) void {
    if (points.len < 3) return;

    const abgr = tint.toAbgr();
    const num_triangles = points.len - 2;
    const num_verts = num_triangles * 3;

    // Stack buffer for small polygons, skip very large ones.
    const MAX_POLYGON_VERTS = 128 * 3;
    if (num_verts > MAX_POLYGON_VERTS) return;

    var vertices: [MAX_POLYGON_VERTS]PosTexColorVertex = undefined;
    const p0 = makeVertex(state.transformX(points[0].x), state.transformY(points[0].y), abgr);

    for (0..num_triangles) |i| {
        vertices[i * 3 + 0] = p0;
        vertices[i * 3 + 1] = makeVertex(state.transformX(points[i + 1].x), state.transformY(points[i + 1].y), abgr);
        vertices[i * 3 + 2] = makeVertex(state.transformX(points[i + 2].x), state.transformY(points[i + 2].y), abgr);
    }

    programs.submitFlatTriangles(vertices[0..num_verts]);
}
