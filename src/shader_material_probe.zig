//! Real GPU regression: per-instance values, named reflection, texture ABA,
//! fallback and context recreation through the production entry points.
const std = @import("std");
const gfx = @import("gfx");
const window = @import("window");
const core = @import("labelle-core");

const sm = core.shader_material;
fn descriptor() sm.Descriptor {
    return .{ .shaders = .{ .glsl = @embedFile("fixtures/shader_material/fs_flash_glsl.bin"), .essl = @embedFile("fixtures/shader_material/fs_flash_essl.bin"), .spv = @embedFile("fixtures/shader_material/fs_flash_spv.bin"), .mtl = @embedFile("fixtures/shader_material/fs_flash_mtl.bin") }, .parameters = &.{ .{ .name = "u_material_color", .defaults = &.{ 1, 0, 0, 1 } }, .{ .name = "u_material_params", .defaults = &.{ 1, 0, 0, 0 } } } };
}
fn expectError(comptime expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |err| if (err != expected) return err;
}
fn draw(texture: gfx.Texture, x: f32, y: f32, id: sm.Id) void {
    gfx.drawTextureProMaterial(texture, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ .x = x, .y = y, .width = 32, .height = 32 }, .{ .x = 0, .y = 0 }, 0, gfx.white, .{ .shader = id });
}
fn pixel(image: gfx.DecodedImage, x: usize, y: usize, expected: [3]u8) !void {
    const actual = image.pixels[(y * 128 + x) * 4 ..][0..3];
    for (actual, expected) |a, e| if (@abs(@as(i32, a) - @as(i32, e)) > 4) {
        std.debug.print("pixel ({d},{d}): got {any}, expected {any}\n", .{ x, y, actual, expected });
        return error.PixelMismatch;
    };
}
pub fn main() !void {
    try std.testing.expect(!gfx.shaderMaterialSupported());
    if (!window.initHeadless(128, 64)) return error.HeadlessInitFailed;
    var active = true;
    defer if (active) window.closeWindow();
    gfx.setScreenSize(128, 64);
    gfx.setDesignSize(128, 64);
    try std.testing.expect(gfx.shaderMaterialSupported());
    var pixels = [_]u8{ 255, 255, 255, 255 };
    const decoded = gfx.DecodedImage{ .pixels = &pixels, .width = 1, .height = 1 };
    const texture = try gfx.uploadTextureFiltered(decoded, .point);
    const a = try gfx.createShaderMaterial(descriptor());
    const b = try gfx.createShaderMaterial(descriptor());
    try gfx.setShaderParameter(b, "u_material_color", &.{ 0, 1, 0, 1 });
    var bad = descriptor();
    bad.parameters = &.{ .{ .name = "u_typo" }, .{ .name = "u_material_params" } };
    try expectError(error.InvalidDescriptor, gfx.createShaderMaterial(bad));
    bad = descriptor();
    bad.parameters = &.{ .{ .name = "u_material_color", .kind = .mat4 }, .{ .name = "u_material_params" } };
    try expectError(error.ParameterShapeMismatch, gfx.createShaderMaterial(bad));
    const dead = try gfx.createShaderMaterial(descriptor());
    gfx.destroyShaderMaterial(dead);
    const lut_a = try gfx.uploadTextureFiltered(decoded, .point);
    const palette = try gfx.createShaderMaterial(.{
        .shaders = .{ .glsl = @embedFile("fixtures/shader_material/fs_palette_glsl.bin"), .essl = @embedFile("fixtures/shader_material/fs_palette_essl.bin"), .spv = @embedFile("fixtures/shader_material/fs_palette_spv.bin"), .mtl = @embedFile("fixtures/shader_material/fs_palette_mtl.bin") },
        .parameters = &.{.{ .name = "u_material_params", .defaults = &.{ 0, 0, 1, 0 } }},
        .textures = &.{.{ .name = "s_lut", .texture = lut_a.id }},
    });
    gfx.unloadTexture(lut_a);
    var blue = [_]u8{ 0, 0, 255, 255 };
    const lut_b = try gfx.uploadTextureFiltered(.{ .pixels = &blue, .width = 1, .height = 1 }, .point);
    try std.testing.expectEqual(lut_a.id, lut_b.id);
    for (0..3) |_| {
        window.clearBackground(0, 0, 0, 255);
        window.beginFrame();
        draw(texture, 0, 0, a);
        draw(texture, 32, 0, b);
        draw(texture, 64, 0, dead);
        draw(texture, 96, 0, .none);
        draw(texture, 0, 32, palette); // invalidated LUT must fallback white, not blue
        draw(texture, 32, 32, b); // unrelated material survives texture unload
        window.endFrame();
    }
    if (!window.captureHeadless("shader_material_probe")) return error.CaptureFailed;
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "shader_material_probe.tga", std.heap.page_allocator, .limited(128 * 64 * 8));
    defer std.heap.page_allocator.free(bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "shader_material_probe.tga") catch {};
    const image = try gfx.decodeImage(".tga", bytes, std.heap.page_allocator);
    defer std.heap.page_allocator.free(image.pixels);
    try pixel(image, 16, 16, .{ 255, 0, 0 });
    try pixel(image, 48, 16, .{ 0, 255, 0 });
    try pixel(image, 80, 16, .{ 255, 255, 255 });
    try pixel(image, 112, 16, .{ 255, 255, 255 });
    try pixel(image, 16, 48, .{ 255, 255, 255 });
    try pixel(image, 48, 48, .{ 0, 255, 0 });
    window.closeWindow();
    active = false;
    try std.testing.expect(!gfx.shaderMaterialSupported());
    try expectError(error.InvalidHandle, gfx.setShaderParameter(a, "u_material_color", &.{ 1, 1, 1, 1 }));
    if (!window.initHeadless(128, 64)) return error.HeadlessInitFailed;
    active = true;
    const replacement = try gfx.createShaderMaterial(descriptor());
    try std.testing.expect(replacement != a and replacement != b);
    gfx.destroyShaderMaterial(a); // stale destroy cannot kill replacement
    try gfx.setShaderParameter(replacement, "u_material_color", &.{ 0, 0, 1, 1 });
    std.debug.print("PROBE_RESULT: SHADER_MATERIAL_OK\n", .{});
}
