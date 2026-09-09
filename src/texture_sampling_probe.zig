// Rendered-pixel regression for point sampling, including the material path.
const std = @import("std");
const gfx = @import("gfx");
const window = @import("window");

pub fn main() !void {
    if (!window.initHeadless(128, 128)) return error.HeadlessInitFailed;
    defer window.closeWindow();
    gfx.setScreenSize(128, 128);
    gfx.setDesignSize(128, 128);
    var pixels = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 };
    const decoded = gfx.DecodedImage{ .pixels = &pixels, .width = 2, .height = 1 };
    const point = try gfx.uploadTextureFiltered(decoded, .point);
    defer gfx.unloadTexture(point);
    const linear = try gfx.uploadTextureFiltered(decoded, .linear);
    defer gfx.unloadTexture(linear);
    const src = gfx.Rectangle{ .x = 0, .y = 0, .width = 2, .height = 1 };
    for (0..3) |_| {
        window.clearBackground(255, 0, 255, 255);
        window.beginFrame();
        gfx.drawTexturePro(point, src, .{ .x = 0, .y = 0, .width = 64, .height = 32 }, .{ .x = 0, .y = 0 }, 0, gfx.white);
        gfx.drawTexturePro(linear, src, .{ .x = 64, .y = 0, .width = 64, .height = 32 }, .{ .x = 0, .y = 0 }, 0, gfx.white);
        gfx.drawTextureProMaterial(point, src, .{ .x = 0, .y = 32, .width = 64, .height = 32 }, .{ .x = 0, .y = 0 }, 0, gfx.white, .{ .effect = .flash });
        gfx.drawTextureProMaterial(linear, src, .{ .x = 64, .y = 32, .width = 64, .height = 32 }, .{ .x = 0, .y = 0 }, 0, gfx.white, .{ .effect = .flash });
        const uv = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 1 };
        const colors = [_]u32{ 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff };
        const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
        gfx.drawMesh(point, &.{ 0, 64, 64, 64, 64, 96, 0, 96 }, &uv, &colors, &indices, .normal);
        gfx.drawMesh(linear, &.{ 64, 64, 128, 64, 128, 96, 64, 96 }, &uv, &colors, &indices, .normal);
        const outside = gfx.Rectangle{ .x = -2, .y = 0, .width = 6, .height = 1 };
        gfx.drawTexturePro(point, outside, .{ .x = 0, .y = 96, .width = 64, .height = 32 }, .{ .x = 0, .y = 0 }, 0, gfx.white);
        gfx.drawTexturePro(linear, outside, .{ .x = 64, .y = 96, .width = 64, .height = 32 }, .{ .x = 0, .y = 0 }, 0, gfx.white);
        window.endFrame();
    }
    if (!window.captureHeadless("texture_sampling_probe")) return error.CaptureFailed;
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "texture_sampling_probe.tga", std.heap.page_allocator, .limited(128 * 128 * 8));
    defer std.heap.page_allocator.free(bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "texture_sampling_probe.tga") catch {};
    const image = try gfx.decodeImage(".tga", bytes, std.heap.page_allocator);
    defer std.heap.page_allocator.free(image.pixels);
    if (image.width != 128 or image.height != 128) return error.BadCaptureSize;
    // Both draw paths must show two solid point-sampled halves, and a
    // gradient for linear. Check interiors, excluding rasterized edges.
    for ([_]usize{ 16, 48, 80 }) |y| {
        var point_mixed: usize = 0;
        var linear_mixed: usize = 0;
        for (2..62) |x| {
            const p = image.pixels[(y * 128 + x) * 4];
            const l = image.pixels[(y * 128 + x + 64) * 4];
            if (p > 8 and p < 247) point_mixed += 1;
            if (l > 8 and l < 247) linear_mixed += 1;
        }
        std.debug.print("PROBE: row {d}, point mixed={d}, linear mixed={d}\n", .{ y, point_mixed, linear_mixed });
        if (point_mixed != 0 or linear_mixed < 16) return error.SamplerFlagsOverridden;
        const left = image.pixels[(y * 128 + 8) * 4];
        const right = image.pixels[(y * 128 + 56) * 4];
        if (left > 8 or right < 247) return error.PointTextureNotRendered;
    }
    // Uploads declare clamp wrapping. Inheriting it is intentional: UVs
    // outside the image must extend the edge, not repeat the opposite half.
    for ([_]usize{ 0, 64 }) |x| {
        if (image.pixels[(112 * 128 + x + 14) * 4] > 8 or
            image.pixels[(112 * 128 + x + 50) * 4] < 247)
            return error.TextureClampIgnored;
    }
    std.debug.print("PROBE_RESULT: TEXTURE_SAMPLING_OK\n", .{});
}
