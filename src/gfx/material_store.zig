const std = @import("std");
const core = @import("labelle-core");
const sm = core.shader_material;

/// Render-thread-only store. Driver owns GPU operations; this store owns all
/// retained CPU data. Slots keep their generation even across shutdown.
pub fn Store(comptime Driver: type) type {
    return struct {
        const Self = @This();
        /// Live material instances at once. Games attach one per lit room or
        /// object, so a large colony needs thousands; a slot is 16 bytes and
        /// an instance is only allocated while in use.
        pub const capacity = 4096;
        pub const Parameter = struct {
            name: [sm.MAX_NAME + 1:0]u8 = @splat(0),
            len: usize = 0,
            kind: sm.Kind,
            count: u16,
            offset: usize,
            uniform: u16,
            pub fn nameSlice(p: *const Parameter) [:0]const u8 {
                return p.name[0..p.len :0];
            }
        };
        pub const Texture = struct {
            name: [sm.MAX_NAME + 1:0]u8 = @splat(0),
            len: usize = 0,
            id: core.BackendTextureId,
            sampler: sm.Sampler,
            uniform: u16,
            pub fn nameSlice(t: *const Texture) [:0]const u8 {
                return t.name[0..t.len :0];
            }
        };
        const Program = struct { bytes: []u8, schema: [2048]u8, handle: u16, refs: usize };
        pub const Instance = struct {
            program: *Program,
            parameters: [sm.MAX_PARAMETERS]Parameter = undefined,
            parameter_count: usize = 0,
            textures: [sm.MAX_TEXTURES]Texture = undefined,
            texture_count: usize = 0,
            values: [sm.MAX_REGISTERS * 4]f32 = @splat(0),
            blend: sm.Blend,
            rect: u16,
            sprite: u16,
        };
        const Slot = struct { generation: u32 = 0, instance: ?*Instance = null };
        allocator: std.mem.Allocator,
        driver: Driver,
        slots: [capacity]Slot = @splat(.{}),
        programs: [capacity]?*Program = @splat(null),

        pub fn get(self: *Self, id: sm.Id) sm.Error!*Instance {
            const bits = @intFromEnum(id);
            // Handles pack a u32 slot index below a u32 generation. Keep
            // the index 32-bit so it can index slices on wasm32 too.
            const index: u32 = @truncate(bits);
            if (index == 0 or index > capacity) return error.InvalidHandle;
            const slot = &self.slots[index - 1];
            if (bits >> 32 != slot.generation) return error.InvalidHandle;
            return slot.instance orelse error.InvalidHandle;
        }
        fn sameUniform(a: sm.Kind, b: sm.Kind) bool {
            return (a == .mat4) == (b == .mat4);
        }
        pub fn create(self: *Self, desc: sm.Descriptor, bytes: []const u8) sm.Error!sm.Id {
            try sm.validateDescriptor(desc);
            if (bytes.len == 0) return error.Unsupported;
            // bgfx uniforms are global by name. Reject incompatible live shapes
            // before creating a shader (which itself creates reflected uniforms).
            for (self.slots) |slot| if (slot.instance) |old| {
                for (desc.parameters) |p| {
                    for (old.parameters[0..old.parameter_count]) |*q| if (std.mem.eql(u8, p.name, q.nameSlice())) {
                        if (!sameUniform(p.kind, q.kind) or p.count != q.count) return error.ParameterShapeMismatch;
                    };
                    for (old.textures[0..old.texture_count]) |*t| if (std.mem.eql(u8, p.name, t.nameSlice())) return error.ParameterShapeMismatch;
                }
                for (desc.textures) |t| for (old.parameters[0..old.parameter_count]) |*p| {
                    if (std.mem.eql(u8, t.name, p.nameSlice())) return error.ParameterShapeMismatch;
                };
            };
            for (desc.textures) |t| if (!self.driver.validTexture(t.texture)) return error.InvalidTexture;
            var index: usize = 0;
            while (index < capacity) : (index += 1) {
                if (self.slots[index].instance == null and self.slots[index].generation != std.math.maxInt(u32)) break;
            }
            if (index == capacity) return error.CapacityExceeded;
            const instance = try self.allocator.create(Instance);
            errdefer self.allocator.destroy(instance);
            const program = try self.acquire(bytes, desc);
            errdefer self.release(program);
            instance.* = .{ .program = program, .blend = desc.blend, .rect = 0xffff, .sprite = 0xffff };
            errdefer self.releaseUniforms(instance);
            instance.rect = try self.driver.uniform("u_material_rect", .vec4, 1);
            instance.sprite = try self.driver.uniform("s_tex", null, 1);
            var offset: usize = 0;
            for (desc.parameters) |p| {
                var q = Parameter{ .kind = p.kind, .count = p.count, .offset = offset, .uniform = try self.driver.uniform(p.name, p.kind, p.count), .len = p.name.len };
                @memcpy(q.name[0..p.name.len], p.name);
                instance.parameters[instance.parameter_count] = q;
                instance.parameter_count += 1;
                if (p.defaults.len != 0) pack(instance, &q, p.defaults);
                offset += sm.registers(p) * 4;
            }
            for (desc.textures) |t| {
                var q = Texture{ .id = t.texture, .sampler = t.sampler, .uniform = try self.driver.uniform(t.name, null, 1), .len = t.name.len };
                @memcpy(q.name[0..t.name.len], t.name);
                instance.textures[instance.texture_count] = q;
                instance.texture_count += 1;
            }
            const slot = &self.slots[index];
            slot.generation += 1;
            slot.instance = instance;
            return @enumFromInt((@as(u64, slot.generation) << 32) | (index + 1));
        }
        fn pack(instance: *Instance, p: *const Parameter, values: []const f32) void {
            const channels = sm.channels(p.kind);
            const stride: usize = if (p.kind == .mat4) 16 else 4;
            for (0..p.count) |i| {
                const dest = instance.values[p.offset + i * stride ..][0..stride];
                @memset(dest, 0);
                @memcpy(dest[0..channels], values[i * channels ..][0..channels]);
            }
        }
        pub fn setParameter(self: *Self, id: sm.Id, name: []const u8, values: []const f32) sm.Error!void {
            const instance = try self.get(id);
            for (instance.parameters[0..instance.parameter_count]) |*p| if (std.mem.eql(u8, name, p.nameSlice())) {
                try sm.validateParameter(.{ .name = p.nameSlice(), .kind = p.kind, .count = p.count }, values);
                pack(instance, p, values);
                return;
            };
            return error.UnknownParameter;
        }
        pub fn setTexture(self: *Self, id: sm.Id, name: []const u8, texture: core.BackendTextureId) sm.Error!void {
            const instance = try self.get(id);
            for (instance.textures[0..instance.texture_count]) |*t| if (std.mem.eql(u8, name, t.nameSlice())) {
                if (!self.driver.validTexture(texture)) return error.InvalidTexture;
                t.id = texture;
                return;
            };
            return error.UnknownTexture;
        }
        fn acquire(self: *Self, bytes: []const u8, desc: sm.Descriptor) sm.Error!*Program {
            var schema: [2048]u8 = @splat(0);
            var n: usize = 0;
            schema[n] = @intFromEnum(desc.blend);
            n += 1;
            schema[n] = @intCast(desc.parameters.len);
            n += 1;
            for (desc.parameters) |p| {
                schema[n] = @intCast(p.name.len);
                n += 1;
                @memcpy(schema[n..][0..p.name.len], p.name);
                n += p.name.len;
                schema[n] = @intFromEnum(p.kind);
                n += 1;
                std.mem.writeInt(u16, schema[n..][0..2], p.count, .little);
                n += 2;
            }
            schema[n] = @intCast(desc.textures.len);
            n += 1;
            for (desc.textures) |t| {
                schema[n] = @intCast(t.name.len);
                n += 1;
                @memcpy(schema[n..][0..t.name.len], t.name);
                n += t.name.len;
                schema[n] = @intFromEnum(t.sampler);
                n += 1;
            }
            for (self.programs) |entry| if (entry) |p| {
                if (std.mem.eql(u8, bytes, p.bytes) and std.mem.eql(u8, &schema, &p.schema)) {
                    p.refs += 1;
                    return p;
                }
            };
            for (&self.programs) |*entry| if (entry.* == null) {
                try self.driver.validateShader(bytes, desc);
                const p = try self.allocator.create(Program);
                errdefer self.allocator.destroy(p);
                const owned = try self.allocator.dupe(u8, bytes);
                errdefer self.allocator.free(owned);
                p.* = .{ .bytes = owned, .schema = schema, .handle = try self.driver.program(owned), .refs = 1 };
                entry.* = p;
                return p;
            };
            return error.CapacityExceeded;
        }
        fn release(self: *Self, program: *Program) void {
            program.refs -= 1;
            if (program.refs != 0) return;
            self.driver.destroyProgram(program.handle);
            for (&self.programs) |*entry| if (entry.* == program) {
                entry.* = null;
                break;
            };
            self.allocator.free(program.bytes);
            self.allocator.destroy(program);
        }
        fn releaseUniforms(self: *Self, instance: *Instance) void {
            for (instance.parameters[0..instance.parameter_count]) |p| self.driver.destroyUniform(p.uniform);
            for (instance.textures[0..instance.texture_count]) |t| self.driver.destroyUniform(t.uniform);
            if (instance.rect != 0xffff) self.driver.destroyUniform(instance.rect);
            if (instance.sprite != 0xffff) self.driver.destroyUniform(instance.sprite);
        }
        pub fn destroy(self: *Self, id: sm.Id) void {
            const instance = self.get(id) catch return;
            const index: u32 = @truncate(@intFromEnum(id));
            self.slots[index - 1].instance = null;
            self.releaseUniforms(instance);
            self.release(instance.program);
            self.allocator.destroy(instance);
        }
        /// Texture pool slots are reusable. Clear borrowed bindings before an
        /// unload so reusing a slot cannot silently retarget an old material.
        pub fn invalidateTexture(self: *Self, id: core.BackendTextureId) void {
            for (self.slots) |slot| if (slot.instance) |instance| {
                for (instance.textures[0..instance.texture_count]) |*t| if (t.id == id) {
                    t.id = .none;
                };
            };
        }
        pub fn shutdown(self: *Self) void {
            for (self.slots, 0..) |slot, i| if (slot.instance != null) {
                self.destroy(@enumFromInt((@as(u64, slot.generation) << 32) | (i + 1)));
            };
        }
    };
}
