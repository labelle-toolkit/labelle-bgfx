const std = @import("std");
const core = @import("labelle-core");
const sm = core.shader_material;
const Store = @import("gfx/material_store.zig").Store;
const binary = @import("gfx/shader_binary.zig");
const Fake = struct {
    programs: usize = 0,
    uniforms: usize = 0,
    created: usize = 0,
    calls: usize = 0,
    fail_at: usize = std.math.maxInt(usize),
    reject_program: bool = false,
    pub fn validTexture(_: *Fake, id: core.BackendTextureId) bool {
        return id.toInt() == 1 or id.toInt() == 2;
    }
    pub fn validateShader(_: *Fake, _: []const u8, _: sm.Descriptor) sm.Error!void {}
    pub fn program(f: *Fake, _: []const u8) sm.Error!u16 {
        if (f.reject_program) return error.ShaderLinkFailed;
        f.programs += 1;
        f.created += 1;
        return @intCast(f.created);
    }
    pub fn uniform(f: *Fake, _: [:0]const u8, _: ?sm.Kind, _: u16) sm.Error!u16 {
        defer f.calls += 1;
        if (f.calls == f.fail_at) return error.UniformCreationFailed;
        f.uniforms += 1;
        return 1;
    }
    pub fn destroyProgram(f: *Fake, _: u16) void {
        f.programs -= 1;
    }
    pub fn destroyUniform(f: *Fake, _: u16) void {
        f.uniforms -= 1;
    }
};
const desc = sm.Descriptor{ .shaders = .{ .glsl = "compiled" }, .parameters = &.{.{ .name = "u_value", .kind = .vec2, .count = 2, .defaults = &.{ 1, 2, 3, 4 } }}, .textures = &.{.{ .name = "s_aux", .texture = @enumFromInt(1) }} };

test "independent instances own defaults and borrowed bytes; refcounted cache" {
    var gpu = Fake{};
    var store = Store(*Fake){ .allocator = std.testing.allocator, .driver = &gpu };
    defer store.shutdown();
    var bytes = [_]u8{ 1, 2, 3 };
    const a = try store.create(desc, &bytes);
    const b = try store.create(desc, &bytes);
    try std.testing.expectEqual(@as(usize, 1), gpu.created);
    bytes[0] = 99;
    try std.testing.expectEqual(@as(u8, 1), (try store.get(a)).program.bytes[0]);
    try store.setParameter(a, "u_value", &.{ 5, 6, 7, 8 });
    try std.testing.expectEqualSlices(f32, &.{ 5, 6, 0, 0, 7, 8, 0, 0 }, (try store.get(a)).values[0..8]);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 0, 0, 3, 4, 0, 0 }, (try store.get(b)).values[0..8]);
    try store.setTexture(a, "s_aux", @enumFromInt(2));
    try std.testing.expectEqual(@as(u32, 1), (try store.get(b)).textures[0].id.toInt());
    store.destroy(a);
    store.destroy(a);
    try std.testing.expectEqual(@as(usize, 1), gpu.programs);
    store.destroy(b);
    try std.testing.expectEqual(@as(usize, 0), gpu.programs);
    try std.testing.expectEqual(@as(usize, 0), gpu.uniforms);
}
test "stale handles never alias after destroy, shutdown or generation exhaustion" {
    var gpu = Fake{};
    var store = Store(*Fake){ .allocator = std.testing.allocator, .driver = &gpu };
    defer store.shutdown();
    const a = try store.create(desc, "a");
    store.destroy(a);
    const b = try store.create(desc, "a");
    try std.testing.expect(a != b);
    try std.testing.expectError(error.InvalidHandle, store.get(a));
    store.shutdown();
    store.shutdown();
    const c = try store.create(desc, "a");
    try std.testing.expect(c != a and c != b);
    try std.testing.expectError(error.InvalidHandle, store.setParameter(b, "u_value", &.{ 1, 2, 3, 4 }));
    try std.testing.expectError(error.InvalidHandle, store.get(.none));
    store.shutdown();
    store.slots[0].generation = std.math.maxInt(u32);
    const d = try store.create(desc, "a");
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(d) & 0xffffffff);
}
test "typed updates are atomic and reject unknown names, shapes and nonfinite data" {
    var gpu = Fake{};
    var store = Store(*Fake){ .allocator = std.testing.allocator, .driver = &gpu };
    defer store.shutdown();
    const a = try store.create(desc, "a");
    try std.testing.expectError(error.UnknownParameter, store.setParameter(a, "typo", &.{1}));
    try std.testing.expectError(error.ParameterShapeMismatch, store.setParameter(a, "u_value", &.{1}));
    try std.testing.expectError(error.NonFiniteParameter, store.setParameter(a, "u_value", &.{ 1, 2, 3, std.math.nan(f32) }));
    try std.testing.expectEqual(@as(f32, 4), (try store.get(a)).values[5]);
    try std.testing.expectError(error.UnknownTexture, store.setTexture(a, "typo", @enumFromInt(1)));
    try std.testing.expectError(error.InvalidTexture, store.setTexture(a, "s_aux", .none));
}
test "schema and blend partition cache; conflicting global uniform shapes reject" {
    var gpu = Fake{};
    var store = Store(*Fake){ .allocator = std.testing.allocator, .driver = &gpu };
    defer store.shutdown();
    _ = try store.create(desc, "a");
    var second = desc;
    second.blend = .additive;
    _ = try store.create(second, "a");
    second = desc;
    second.textures = &.{.{ .name = "s_aux", .texture = @enumFromInt(1), .sampler = .linear }};
    _ = try store.create(second, "a");
    try std.testing.expectEqual(@as(usize, 3), gpu.created);
    second = desc;
    second.parameters = &.{.{ .name = "u_value", .kind = .mat4 }};
    try std.testing.expectError(error.ParameterShapeMismatch, store.create(second, "a"));
    second.parameters = &.{};
    second.textures = &.{.{ .name = "u_value", .texture = @enumFromInt(1) }};
    try std.testing.expectError(error.ParameterShapeMismatch, store.create(second, "a"));
}
test "every uniform creation failure unwinds program and prior uniforms" {
    for (0..4) |fail| {
        var gpu = Fake{ .fail_at = fail };
        var store = Store(*Fake){ .allocator = std.testing.allocator, .driver = &gpu };
        defer store.shutdown();
        try std.testing.expectError(error.UniformCreationFailed, store.create(desc, "a"));
        try std.testing.expectEqual(@as(usize, 0), gpu.programs);
        try std.testing.expectEqual(@as(usize, 0), gpu.uniforms);
    }
    var gpu = Fake{ .reject_program = true };
    var store = Store(*Fake){ .allocator = std.testing.allocator, .driver = &gpu };
    try std.testing.expectError(error.ShaderLinkFailed, store.create(desc, "a"));
}
fn allocationFailure(allocator: std.mem.Allocator) !void {
    var gpu = Fake{};
    var store = Store(*Fake){ .allocator = allocator, .driver = &gpu };
    defer store.shutdown();
    _ = try store.create(desc, "a");
    _ = try store.create(desc, "a");
}
test "allocation failure has no CPU leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
test "shader reflection detects typos, type/count mismatch and malformed binaries" {
    const bytes = &@import("shaders.zig").fs_flash_glsl;
    const reflection = try binary.read(bytes);
    const good = sm.Descriptor{ .shaders = .{ .glsl = bytes }, .parameters = &.{ .{ .name = "u_material_color" }, .{ .name = "u_material_params" } } };
    try binary.validate(reflection, good);
    var bad = good;
    bad.parameters = &.{.{ .name = "u_typo" }};
    try std.testing.expectError(error.InvalidDescriptor, binary.validate(reflection, bad));
    bad.parameters = &.{ .{ .name = "u_material_color", .kind = .mat4 }, .{ .name = "u_material_params" } };
    try std.testing.expectError(error.ParameterShapeMismatch, binary.validate(reflection, bad));
    // Every strict prefix of this GLSL container is truncated: the final NUL
    // is part of the shaderc container, not optional trailing data.
    for (0..bytes.len) |len| try std.testing.expectError(error.InvalidShader, binary.read(bytes[0..len]));
    try std.testing.expectError(error.InvalidShader, binary.read("garbage"));
    try std.testing.expectError(error.InvalidShader, binary.read(bytes[0..20]));
}
test "all released GLSL binary schemas remain readable" {
    const shaders = @import("shaders.zig");
    inline for (@typeInfo(shaders).@"struct".decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, "fs_") and std.mem.endsWith(u8, decl.name, "_glsl")) _ = try binary.read(&@field(shaders, decl.name));
    }
}

test "texture unload invalidates bindings before a pool slot can be reused" {
    var gpu = Fake{};
    var store = Store(*Fake){ .allocator = std.testing.allocator, .driver = &gpu };
    defer store.shutdown();
    const a = try store.create(desc, "a");
    var other = desc;
    other.textures = &.{.{ .name = "s_aux", .texture = @enumFromInt(2) }};
    const b = try store.create(other, "a");
    store.invalidateTexture(@enumFromInt(1));
    // Fake GPU still accepts slot 1, modeling a replacement upload there.
    try std.testing.expect(gpu.validTexture(@enumFromInt(1)));
    try std.testing.expectEqual(core.BackendTextureId.none, (try store.get(a)).textures[0].id);
    try std.testing.expect(!gpu.validTexture((try store.get(a)).textures[0].id));
    try std.testing.expect(gpu.validTexture((try store.get(b)).textures[0].id));
    try store.setTexture(a, "s_aux", @enumFromInt(1));
    try std.testing.expect(gpu.validTexture((try store.get(a)).textures[0].id));
}
test "capacity exhaustion is recoverable and zero defaults/matrices pack correctly" {
    var gpu = Fake{};
    var store = Store(*Fake){ .allocator = std.testing.allocator, .driver = &gpu };
    defer store.shutdown();
    var ids: [Store(*Fake).capacity]sm.Id = undefined;
    const d = sm.Descriptor{ .shaders = .{ .glsl = "a" }, .parameters = &.{.{ .name = "u_matrix", .kind = .mat4 }} };
    for (&ids) |*id| id.* = try store.create(d, "a");
    try std.testing.expectError(error.CapacityExceeded, store.create(d, "a"));
    try std.testing.expectEqualSlices(f32, &(@as([16]f32, @splat(0))), (try store.get(ids[0])).values[0..16]);
    const matrix = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    try store.setParameter(ids[0], "u_matrix", &matrix);
    try std.testing.expectEqualSlices(f32, &matrix, (try store.get(ids[0])).values[0..16]);
    store.destroy(ids[42]);
    const replacement = try store.create(d, "a");
    try std.testing.expect(replacement != ids[42]);
}
test "all supported compiled variants have usable reflected sampler shapes" {
    const shaders = @import("shaders.zig");
    inline for (@typeInfo(shaders).@"struct".decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, "fs_")) _ = try binary.read(&@field(shaders, decl.name));
    }
}

test "fixed sampler slots reject reordered descriptors on Vulkan and Metal" {
    var reflection = binary.Reflection{ .trailer = &.{ 0, 0, 0 }, .len = 3, .code = "s_tex [[texture(0)]], s_texSampler [[sampler(0)]], s_first [[texture(1)]], s_firstSampler [[sampler(1)]], s_second [[texture(2)]], s_secondSampler [[sampler(2)]]" };
    reflection.bindings[0] = .{ .name = "s_tex", .kind = 0, .count = 1, .register = 2 };
    reflection.bindings[1] = .{ .name = "s_first", .kind = 0, .count = 1, .register = 3 };
    reflection.bindings[2] = .{ .name = "s_second", .kind = 0, .count = 1, .register = 4 };
    var d = sm.Descriptor{ .shaders = .{ .spv = "a" }, .textures = &.{ .{ .name = "s_first" }, .{ .name = "s_second" } } };
    try binary.validateSlots(reflection, d, .spirv);
    try binary.validateSlots(reflection, d, .metal);
    d.textures = &.{ .{ .name = "s_second" }, .{ .name = "s_first" } };
    try std.testing.expectError(error.InvalidDescriptor, binary.validateSlots(reflection, d, .spirv));
    try std.testing.expectError(error.InvalidDescriptor, binary.validateSlots(reflection, d, .metal));
    // GL dynamically assigns named samplers; no fixed register metadata.
    try binary.validateSlots(reflection, d, .named);
}
test "actual shaderc Vulkan and Metal sampler slots and optional auto rect" {
    const shaders = @import("shaders.zig");
    const d = sm.Descriptor{ .shaders = .{ .spv = &shaders.fs_palette_spv }, .parameters = &.{.{ .name = "u_material_params" }}, .textures = &.{.{ .name = "s_lut" }} };
    const vk = try binary.read(&shaders.fs_palette_spv);
    const metal = try binary.read(&shaders.fs_palette_mtl);
    try binary.validate(vk, d);
    try binary.validate(metal, d);
    try binary.validateSlots(vk, d, .spirv);
    try binary.validateSlots(metal, d, .metal);
    var wrong = vk;
    for (wrong.bindings[0..wrong.len]) |*b| if (std.mem.eql(u8, b.name, "s_lut")) {
        b.register += 1;
    };
    try std.testing.expectError(error.InvalidDescriptor, binary.validateSlots(wrong, d, .spirv));
}

test "descriptor names, defaults and bindings are copied before create returns" {
    var gpu = Fake{};
    var store = Store(*Fake){ .allocator = std.testing.allocator, .driver = &gpu };
    defer store.shutdown();
    var name: [7:0]u8 = "u_value".*;
    var values = [_]f32{ 1, 2, 3, 4 };
    var params = [_]sm.Parameter{.{ .name = &name, .defaults = &values }};
    var textures = [_]sm.TextureBinding{.{ .name = "s_aux", .texture = @enumFromInt(1) }};
    const id = try store.create(.{ .shaders = .{ .glsl = "a" }, .parameters = &params, .textures = &textures }, "a");
    @memset(&name, 'x');
    @memset(&values, 99);
    params[0].count = 63;
    textures[0].texture = @enumFromInt(2);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, (try store.get(id)).values[0..4]);
    try std.testing.expectEqual(@as(u32, 1), (try store.get(id)).textures[0].id.toInt());
    try store.setParameter(id, "u_value", &.{ 5, 6, 7, 8 });
}

test "invalid packed indices cannot access or destroy a live material" {
    var gpu = Fake{};
    var store = Store(*Fake){ .allocator = std.testing.allocator, .driver = &gpu };
    defer store.shutdown();
    const live = try store.create(desc, "compiled");
    const generation = @intFromEnum(live) & 0xffffffff00000000;
    for ([_]u64{ 0, Store(*Fake).capacity + 1, 0xffffffff }) |index| {
        const invalid: sm.Id = @enumFromInt(generation | index);
        try std.testing.expectError(error.InvalidHandle, store.get(invalid));
        store.destroy(invalid);
        _ = try store.get(live);
        try std.testing.expectEqual(@as(usize, 1), gpu.programs);
    }
}
