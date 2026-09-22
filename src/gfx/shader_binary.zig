//! Checked reader for the shaderc v12 container used by the pinned bgfx.
//! Validate metadata before createShader: bgfx creates global uniforms while
//! reading the container, so checking only after creation is too late.
const std = @import("std");
const sm = @import("labelle-core").shader_material;
pub const Binding = struct { name: []const u8, kind: u8, count: u16, register: u16 = 0 };
pub const Reflection = struct { bindings: [128]Binding = undefined, len: usize = 0, code: []const u8 = &.{}, trailer: []const u8 = &.{} };
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    fn take(r: *Reader, n: usize) sm.Error![]const u8 {
        if (n > r.bytes.len - r.pos) return error.InvalidShader;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }
    fn int(r: *Reader, comptime T: type) sm.Error!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};
pub fn read(bytes: []const u8) sm.Error!Reflection {
    if (bytes.len > 16 * 1024 * 1024) return error.InvalidShader;
    var r = Reader{ .bytes = bytes };
    const magic = try r.take(4);
    if (!std.mem.eql(u8, magic, "FSH\x0c")) return error.InvalidShader;
    _ = try r.take(8); // input/output varying hashes
    // v12 inserted two u32 raw-binding masks (srv, uav) between the varying
    // hashes and the uniform count — bgfx_p.h `readRawBindings`, called from
    // `createShader` for every container at version >= 12. Reading v12 with
    // the v11 layout does not fail loudly; it silently reads the srv mask as
    // the uniform count, which for these shaders is 0, yielding an empty
    // reflection and a zero code size. Skipped rather than surfaced because
    // nothing in this backend consumes the masks (they are D3D11-only).
    _ = try r.take(8); // rawSrvMask, rawUavMask
    const count = try r.int(u16);
    var result = Reflection{};
    if (count > result.bindings.len) return error.InvalidShader;
    for (0..count) |_| {
        const name = try r.take(try r.int(u8));
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidShader;
        const kind = (try r.int(u8)) & 0x0f;
        const num = try r.int(u8);
        if (kind > 4 or (num == 0 and kind != 0 and kind != 1)) return error.InvalidShader;
        const register = try r.int(u16);
        _ = try r.take(6); // register count, texture info/format
        if (kind == 1) {
            if (register != 0xffff) return error.InvalidShader; // no storage buffers/images
            continue; // Metal texture/sampler internals (UniformType.End)
        }
        for (result.bindings[0..result.len]) |b| if (std.mem.eql(u8, name, b.name)) return error.InvalidShader;
        result.bindings[result.len] = .{ .name = name, .kind = kind, .count = @max(1, num), .register = register };
        result.len += 1;
    }
    const size = try r.int(u32);
    if (size == 0) return error.InvalidShader;
    result.code = try r.take(size);
    if (try r.int(u8) != 0) return error.InvalidShader;
    result.trailer = bytes[r.pos..];
    return result;
}
pub fn kindOf(kind: ?sm.Kind) u8 {
    return if (kind) |k| (if (k == .mat4) 4 else 2) else 0;
}

pub fn validate(reflection: Reflection, desc: sm.Descriptor) sm.Error!void {
    // No unbound custom uniforms: otherwise previous draw state can leak in.
    for (reflection.bindings[0..reflection.len]) |b| {
        if (std.mem.eql(u8, b.name, "s_tex")) {
            if (b.kind != 0 or b.count != 1) return error.ParameterShapeMismatch;
            continue;
        }
        if (std.mem.eql(u8, b.name, "u_material_rect")) {
            if (b.kind != 2 or b.count != 1) return error.ParameterShapeMismatch;
            continue;
        }
        var found = false;
        for (desc.parameters) |p| if (std.mem.eql(u8, b.name, p.name)) {
            found = true;
        };
        for (desc.textures) |t| if (std.mem.eql(u8, b.name, t.name)) {
            found = true;
        };
        if (!found) return error.InvalidDescriptor;
    }
    for (desc.parameters) |p| try require(reflection, p.name, kindOf(p.kind), p.count, error.UnknownParameter);
    for (desc.textures) |t| try require(reflection, t.name, 0, 1, error.UnknownTexture);
}
fn require(r: Reflection, name: []const u8, kind: u8, count: u16, missing: sm.Error) sm.Error!void {
    for (r.bindings[0..r.len]) |b| if (std.mem.eql(u8, name, b.name)) {
        if (b.kind != kind or b.count != count) return error.ParameterShapeMismatch;
        return;
    };
    return missing;
}

/// Vulkan and Metal bind by fixed stage; OpenGL/GLES bind by uniform name.
/// shaderc v11 SPIR-V reserves bindings 0/1 for vertex/fragment uniforms.
pub fn validateSlots(reflection: Reflection, desc: sm.Descriptor, format: enum { spirv, metal, named }) sm.Error!void {
    if (format == .named) return;
    // Vulkan/Metal readers consume an attribute list and constant-buffer size
    // after the code. Reject truncated trailers before native bgfx reads them.
    if (reflection.code.len != 0 and reflection.trailer.len < 3) return error.InvalidShader;
    if (reflection.trailer.len != 0) {
        const tail_size = 1 + @as(usize, reflection.trailer[0]) * 2 + 2;
        if (reflection.trailer.len < tail_size) return error.InvalidShader;
    }
    for (reflection.bindings[0..reflection.len]) |b| {
        if (b.kind != 0) continue;
        const expected: usize = if (std.mem.eql(u8, b.name, "s_tex")) 0 else blk: {
            for (desc.textures, 1..) |t, stage| if (std.mem.eql(u8, b.name, t.name)) break :blk stage;
            return error.UnknownTexture;
        };
        if (format == .spirv) {
            if (b.register != expected + 2) return error.InvalidDescriptor;
        } else {
            if (try metalSlot(reflection.code, b.name, "texture") != expected) return error.InvalidDescriptor;
            var name: [sm.MAX_NAME + 8]u8 = undefined;
            if (b.name.len + 7 > name.len) return error.InvalidShader;
            @memcpy(name[0..b.name.len], b.name);
            @memcpy(name[b.name.len..][0..7], "Sampler");
            if (try metalSlot(reflection.code, name[0 .. b.name.len + 7], "sampler") != expected) return error.InvalidDescriptor;
        }
    }
}
fn metalSlot(code: []const u8, name: []const u8, attribute: []const u8) sm.Error!usize {
    // Match a whole identifier followed immediately by shaderc's binding
    // annotation, never a use site or a longer identifier sharing a prefix.
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, code, pos, name)) |start| {
        pos = start + name.len;
        if (start != 0 and (std.ascii.isAlphanumeric(code[start - 1]) or code[start - 1] == '_')) continue;
        var rest = std.mem.trimStart(u8, code[pos..], " \t\r\n");
        if (!std.mem.startsWith(u8, rest, "[[")) continue;
        rest = rest[2..];
        if (!std.mem.startsWith(u8, rest, attribute)) continue;
        rest = rest[attribute.len..];
        if (!std.mem.startsWith(u8, rest, "(")) continue;
        rest = rest[1..];
        const end = std.mem.indexOf(u8, rest, ")]]") orelse return error.InvalidShader;
        return std.fmt.parseInt(usize, rest[0..end], 10) catch error.InvalidShader;
    }
    // Opaque metallib containers do not expose slots here; do not guess.
    return error.InvalidShader;
}
