//! Generic game-owned fragment shaders. All calls run on the render thread.
const std = @import("std");
const core = @import("labelle-core");
const sm = core.shader_material;
const bgfx = @import("zbgfx").bgfx;
const embedded = @import("../shaders.zig");
const texture = @import("texture.zig");
const binary = @import("shader_binary.zig");
const Registry = @import("material_store.zig").Store(Driver);
var registry = Registry{ .allocator = std.heap.page_allocator, .driver = .{} };
var context_active = false;

pub fn contextStarted() void {
    context_active = true;
}
pub fn shutdown() void {
    registry.shutdown();
    context_active = false;
}
pub fn supported() bool {
    if (!context_active) return false;
    return switch (bgfx.getRendererType()) {
        .OpenGL, .OpenGLES, .Vulkan, .Metal => true,
        else => false,
    };
}
fn vertexBytes() []const u8 {
    return switch (bgfx.getRendererType()) {
        .OpenGL => &embedded.vs_sprite_glsl,
        .OpenGLES => &embedded.vs_sprite_essl,
        .Vulkan => &embedded.vs_sprite_spv,
        .Metal => &embedded.vs_sprite_mtl,
        else => &.{},
    };
}
pub fn create(desc: sm.Descriptor) sm.Error!sm.Id {
    if (!supported()) return error.Unsupported;
    const bytes = switch (bgfx.getRendererType()) {
        .OpenGL => desc.shaders.glsl,
        .OpenGLES => desc.shaders.essl,
        .Vulkan => desc.shaders.spv,
        .Metal => desc.shaders.mtl,
        else => return error.Unsupported,
    };
    return registry.create(desc, bytes);
}
pub fn setParameter(id: sm.Id, name: []const u8, values: []const f32) sm.Error!void {
    return registry.setParameter(id, name, values);
}
pub fn setTexture(id: sm.Id, name: []const u8, value: core.BackendTextureId) sm.Error!void {
    return registry.setTexture(id, name, value);
}
pub fn destroy(id: sm.Id) void {
    registry.destroy(id);
}

/// Resolve everything before touching draw state. Missing textures and stale
/// instances select the caller's ordinary-sprite fallback.
pub fn resolve(id: sm.Id) ?*Registry.Instance {
    if (!context_active) return null;
    const instance = registry.get(id) catch return null;
    for (instance.textures[0..instance.texture_count]) |t| if (!registry.driver.validTexture(t.id)) return null;
    return instance;
}
pub fn bind(instance: *const Registry.Instance, sprite: bgfx.TextureHandle, rect: [4]f32) void {
    bgfx.setUniform(.{ .idx = instance.rect }, &rect, 1);
    bgfx.setTexture(0, .{ .idx = instance.sprite }, sprite, std.math.maxInt(u32));
    for (instance.parameters[0..instance.parameter_count]) |p| {
        bgfx.setUniform(.{ .idx = p.uniform }, @ptrCast(instance.values[p.offset..].ptr), p.count);
    }
    for (instance.textures[0..instance.texture_count], 1..) |t, stage| {
        const flags: u32 = @intCast(bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp |
            (if (t.sampler == .point) bgfx.SamplerFlags_MinPoint | bgfx.SamplerFlags_MagPoint else 0));
        bgfx.setTexture(@intCast(stage), .{ .idx = t.uniform }, texture.handleForId(t.id), flags);
    }
}
const Driver = struct {
    pub fn validTexture(_: Driver, id: core.BackendTextureId) bool {
        return id != .none and texture.handleForId(id).idx != 0xffff;
    }
    pub fn validateShader(_: Driver, bytes: []const u8, desc: sm.Descriptor) sm.Error!void {
        const reflection = try binary.read(bytes);
        try binary.validate(reflection, desc);
        try binary.validateSlots(reflection, desc, switch (bgfx.getRendererType()) {
            .Vulkan => .spirv,
            .Metal => .metal,
            else => .named,
        });
        // Guard collisions with released programs even if their lazy creation
        // happens AFTER this material. Derive their schemas from embedded data.
        inline for (@typeInfo(embedded).@"struct".decls) |decl| {
            if (comptime std.mem.startsWith(u8, decl.name, "fs_") and std.mem.endsWith(u8, decl.name, "_glsl")) {
                const legacy = try binary.read(&@field(embedded, decl.name));
                for (legacy.bindings[0..legacy.len]) |a| for (reflection.bindings[0..reflection.len]) |b| {
                    if (std.mem.eql(u8, a.name, b.name) and (a.kind != b.kind or a.count != b.count)) return error.ParameterShapeMismatch;
                };
            }
        }
        const shader = try makeShader(bytes);
        defer bgfx.destroyShader(shader);
        var handles: [128]bgfx.UniformHandle = undefined;
        const count = bgfx.getShaderUniforms(shader, &handles, handles.len);
        if (count > handles.len) return error.InvalidShader;
        var actual = binary.Reflection{};
        var names: [128][256]u8 = undefined;
        for (handles[0..count], 0..) |handle, i| {
            var info: bgfx.UniformInfo = undefined;
            bgfx.getUniformInfo(handle, &info);
            names[i] = info.name;
            actual.bindings[i] = .{ .name = std.mem.sliceTo(&names[i], 0), .kind = @intCast(@intFromEnum(info.type)), .count = info.num };
            actual.len += 1;
        }
        try binary.validate(actual, desc);
    }
    fn makeShader(bytes: []const u8) sm.Error!bgfx.ShaderHandle {
        const mem = bgfx.copy(bytes.ptr, @intCast(bytes.len));
        if (mem == null) return error.OutOfMemory;
        const handle = bgfx.createShader(mem);
        if (handle.idx == 0xffff) return error.InvalidShader;
        return handle;
    }
    pub fn program(_: Driver, bytes: []const u8) sm.Error!u16 {
        const vs = try makeShader(vertexBytes());
        defer bgfx.destroyShader(vs);
        const fs = try makeShader(bytes);
        defer bgfx.destroyShader(fs);
        // Explicit shader release on both success/failure; program retains its
        // own refs when destroyShaders=false.
        const handle = bgfx.createProgram(vs, fs, false);
        if (handle.idx == 0xffff) return error.ShaderLinkFailed;
        return handle.idx;
    }
    pub fn uniform(_: Driver, name: [:0]const u8, kind: ?sm.Kind, count: u16) sm.Error!u16 {
        const handle = bgfx.createUniform(name.ptr, @enumFromInt(binary.kindOf(kind)), count);
        if (handle.idx == 0xffff) return error.UniformCreationFailed;
        return handle.idx;
    }
    pub fn destroyProgram(_: Driver, handle: u16) void {
        bgfx.destroyProgram(.{ .idx = handle });
    }
    pub fn destroyUniform(_: Driver, handle: u16) void {
        bgfx.destroyUniform(.{ .idx = handle });
    }
};

pub fn invalidateTexture(id: core.BackendTextureId) void {
    registry.invalidateTexture(id);
}
