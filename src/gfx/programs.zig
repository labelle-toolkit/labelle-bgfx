/// Shader programs, vertex layout, white-fallback texture, and the
/// `submit*` helpers that every draw path funnels through. All bgfx
/// "engine warmup" state lives here so the draw / texture / font
/// modules don't each carry their own shader-init flags.
const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const shaders_data = @import("../shaders.zig");
const texture_mod = @import("texture.zig");
const font_mod = @import("font.zig");

// Blend helpers matching bgfx C macros.
// BGFX_STATE_BLEND_FUNC_SEPARATE(_srcRGB, _dstRGB, _srcA, _dstA):
//   (_srcRGB | (_dstRGB << 4)) | ((_srcA | (_dstA << 4)) << 8)
fn stateBlendFuncSeparate(src_rgb: u64, dst_rgb: u64, src_a: u64, dst_a: u64) u64 {
    return (src_rgb | (dst_rgb << 4)) | ((src_a | (dst_a << 4)) << 8);
}

pub const STATE_BLEND_ALPHA: u64 = stateBlendFuncSeparate(
    bgfx.StateFlags_BlendSrcAlpha,
    bgfx.StateFlags_BlendInvSrcAlpha,
    bgfx.StateFlags_BlendSrcAlpha,
    bgfx.StateFlags_BlendInvSrcAlpha,
);

// ── Vertex layout ─────────────────────────────────────────────────────

/// Unified 2D vertex: position (x, y) + texcoord (u, v) + ABGR color packed as u32.
/// Matches the v1 sprite shader layout: a_position (vec2), a_texcoord0 (vec2), a_color0 (vec4 normalized).
/// For flat-color rendering, use UV (0,0) with a 1x1 white texture.
pub const PosTexColorVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    abgr: u32,
};

var vertex_layout: bgfx.VertexLayout = undefined;
var layouts_initialized: bool = false;

/// Shader program handle (single program for both flat and textured rendering).
/// The sprite shader samples a texture and multiplies by vertex color.
/// For flat-color rendering, a 1x1 white texture is bound so texture * color = color.
var sprite_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };

/// Sampler uniform handle for texture binding (created via createUniform).
var s_tex_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };

/// u_viewProj uniform handle (4x4 matrix). Set to identity since we compute NDC in Zig.
// u_viewProj is a built-in bgfx uniform set via setViewTransform, not createUniform

/// 1x1 white texture used for flat-color rendering (texture * color = color).
var white_texture: bgfx.TextureHandle = .{ .idx = std.math.maxInt(u16) };

/// Whether embedded shaders have been initialized.
var shaders_initialized: bool = false;

// ── YUV video program (GPU-side YUV→RGBA, perf/gpu-yuv-video) ───────────
// A second program built from `vs_sprite` + `fs_yuv`: it samples three R8 plane
// textures (Y full-res, U/V half-res) bound to `s_texY/U/V` and does the BT.601
// limited-range convert in the fragment stage. Lazy-created like the sprite
// program (see `ensureYuvProgram`) and torn down in `shutdownPrograms`, so it
// re-creates cleanly after an Android surface cycle (Phase-4 reset path).
var yuv_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var s_texY_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var s_texU_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var s_texV_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var yuv_initialized: bool = false;
/// Set when `initYuvProgram` has tried and failed (e.g. `fs_yuv` won't link on
/// this driver). Latches the failure so `ensureYuvProgram` gives up after ONE
/// attempt instead of re-creating + leaking shader handles every frame (which
/// would exhaust bgfx's handle pool and black-screen the whole game). Cleared
/// by `shutdownPrograms` so a fresh Android surface gets one more honest try.
var yuv_failed: bool = false;

/// Returns true if `handle` is a valid bgfx handle (not the sentinel value).
pub fn isValidHandle(idx: u16) bool {
    return idx != std.math.maxInt(u16);
}

/// Returns true if `prog` is a valid bgfx program handle.
pub fn isValidProgram(prog: bgfx.ProgramHandle) bool {
    return isValidHandle(prog.idx);
}

/// View ID used for 2D rendering.
pub const VIEW_ID: u16 = 0;

/// Initialize embedded shaders, uniforms, and the 1x1 white fallback texture.
/// Called lazily from submit functions. Detects the renderer type and selects
/// the appropriate pre-compiled shader variant (Metal, Vulkan, or GLSL).
fn initShaders() void {
    if (shaders_initialized) return;

    // Select shader variant based on active renderer
    const vs_data: []const u8 = switch (bgfx.getRendererType()) {
        .Metal => &shaders_data.vs_sprite_mtl,
        .Vulkan => &shaders_data.vs_sprite_spv,
        else => &shaders_data.vs_sprite_glsl,
    };
    const fs_data: []const u8 = switch (bgfx.getRendererType()) {
        .Metal => &shaders_data.fs_sprite_mtl,
        .Vulkan => &shaders_data.fs_sprite_spv,
        else => &shaders_data.fs_sprite_glsl,
    };

    const vs_handle = bgfx.createShader(bgfx.makeRef(vs_data.ptr, @intCast(vs_data.len)));
    const fs_handle = bgfx.createShader(bgfx.makeRef(fs_data.ptr, @intCast(fs_data.len)));

    if (!isValidHandle(vs_handle.idx) or !isValidHandle(fs_handle.idx)) {
        std.log.err("bgfx: failed to create sprite shaders", .{});
        return;
    }

    // createProgram with destroy_shaders=true so bgfx owns the shader handles
    sprite_program = bgfx.createProgram(vs_handle, fs_handle, true);
    if (!isValidProgram(sprite_program)) {
        std.log.err("bgfx: failed to create sprite shader program", .{});
        return;
    }

    // Create sampler uniform
    s_tex_uniform = bgfx.createUniform("s_tex", .Sampler, 1);

    // Set view transform to identity (we compute NDC positions in Zig)
    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(VIEW_ID, &identity, &identity);

    // Create 1x1 white RGBA8 texture for flat-color rendering
    const white_pixel = [4]u8{ 255, 255, 255, 255 };
    const white_mem = bgfx.copy(&white_pixel, 4);
    white_texture = bgfx.createTexture2D(1, 1, false, 1, .RGBA8, 0, white_mem, 0);

    if (!isValidHandle(white_texture.idx)) {
        std.log.err("bgfx: failed to create 1x1 white texture", .{});
        return;
    }

    shaders_initialized = true;
    std.log.info("bgfx: sprite shaders initialized (renderer: {})", .{bgfx.getRendererType()});
}

/// Ensure shaders are initialized before any rendering. Called from submit paths.
pub fn ensureShadersInitialized() void {
    if (!shaders_initialized) initShaders();
}

/// Lazily build the YUV video program (`vs_sprite` + `fs_yuv`) and its three
/// plane samplers, selecting the renderer-appropriate bytecode. Called from
/// `submitYuvTriangles`; re-runs after `shutdownPrograms` (surface loss) since
/// it resets `yuv_initialized`. Falls back silently (leaves `yuv_program`
/// invalid) on failure — the video path then degrades to the CPU RGBA fallback.
fn initYuvProgram() void {
    if (yuv_initialized) return;

    const vs_data: []const u8 = switch (bgfx.getRendererType()) {
        .Metal => &shaders_data.vs_sprite_mtl,
        .Vulkan => &shaders_data.vs_sprite_spv,
        else => &shaders_data.vs_sprite_glsl,
    };
    const fs_data: []const u8 = switch (bgfx.getRendererType()) {
        .Metal => &shaders_data.fs_yuv_mtl,
        .Vulkan => &shaders_data.fs_yuv_spv,
        else => &shaders_data.fs_yuv_glsl,
    };

    const vs_handle = bgfx.createShader(bgfx.makeRef(vs_data.ptr, @intCast(vs_data.len)));
    const fs_handle = bgfx.createShader(bgfx.makeRef(fs_data.ptr, @intCast(fs_data.len)));
    if (!isValidHandle(vs_handle.idx) or !isValidHandle(fs_handle.idx)) {
        std.log.err("bgfx: failed to create YUV video shaders", .{});
        // Reclaim whichever handle did get created — neither was consumed.
        if (isValidHandle(vs_handle.idx)) bgfx.destroyShader(vs_handle);
        if (isValidHandle(fs_handle.idx)) bgfx.destroyShader(fs_handle);
        yuv_failed = true;
        return;
    }

    yuv_program = bgfx.createProgram(vs_handle, fs_handle, true);
    if (!isValidProgram(yuv_program)) {
        std.log.err("bgfx: failed to create YUV video program (fs_yuv link failed on this renderer); falling back to CPU YUV path", .{});
        // createProgram does NOT consume the shaders when it fails (the
        // `destroy_shaders=true` hand-off only happens on success), so we own
        // them and MUST destroy them here. Leaking ~2 handles every frame
        // exhausts bgfx's handle pool in seconds and black-screens the game.
        bgfx.destroyShader(vs_handle);
        bgfx.destroyShader(fs_handle);
        yuv_failed = true;
        return;
    }

    s_texY_uniform = bgfx.createUniform("s_texY", .Sampler, 1);
    s_texU_uniform = bgfx.createUniform("s_texU", .Sampler, 1);
    s_texV_uniform = bgfx.createUniform("s_texV", .Sampler, 1);
    if (!isValidHandle(s_texY_uniform.idx) or !isValidHandle(s_texU_uniform.idx) or
        !isValidHandle(s_texV_uniform.idx))
    {
        std.log.err("bgfx: failed to create YUV sampler uniforms; falling back to CPU YUV path", .{});
        // Tear down the whole group so we never cache a half-initialized program
        // (and never leak the program / the uniforms that DID create). Latch
        // yuv_failed like the other failure paths so we don't retry every frame.
        if (isValidProgram(yuv_program)) bgfx.destroyProgram(yuv_program);
        yuv_program = .{ .idx = std.math.maxInt(u16) };
        if (isValidHandle(s_texY_uniform.idx)) bgfx.destroyUniform(s_texY_uniform);
        if (isValidHandle(s_texU_uniform.idx)) bgfx.destroyUniform(s_texU_uniform);
        if (isValidHandle(s_texV_uniform.idx)) bgfx.destroyUniform(s_texV_uniform);
        s_texY_uniform = .{ .idx = std.math.maxInt(u16) };
        s_texU_uniform = .{ .idx = std.math.maxInt(u16) };
        s_texV_uniform = .{ .idx = std.math.maxInt(u16) };
        yuv_failed = true;
        return;
    }

    yuv_initialized = true;
    std.log.info("bgfx: GPU-YUV video program initialized (renderer: {})", .{bgfx.getRendererType()});
}

/// Ensure the YUV video program is ready. Returns true when it can be submitted.
/// Tries to create the program at most ONCE: once `yuv_failed` latches we return
/// false immediately (no per-frame re-create / handle leak). The latch is cleared
/// by `shutdownPrograms`, so a post-surface-loss re-init gets a fresh attempt.
pub fn ensureYuvProgram() bool {
    if (!yuv_initialized) {
        if (yuv_failed) return false;
        initYuvProgram();
    }
    return yuv_initialized and isValidProgram(yuv_program) and
        isValidHandle(s_texY_uniform.idx) and isValidHandle(s_texU_uniform.idx) and isValidHandle(s_texV_uniform.idx);
}

/// Destroy shader programs, uniforms, and textures, resetting to invalid sentinels.
pub fn shutdownPrograms() void {
    if (isValidProgram(sprite_program)) {
        bgfx.destroyProgram(sprite_program);
        sprite_program = .{ .idx = std.math.maxInt(u16) };
    }
    if (isValidHandle(s_tex_uniform.idx)) {
        bgfx.destroyUniform(s_tex_uniform);
        s_tex_uniform = .{ .idx = std.math.maxInt(u16) };
    }
    // u_viewProj is a built-in bgfx uniform — nothing to destroy
    if (isValidHandle(white_texture.idx)) {
        bgfx.destroyTexture(white_texture);
        white_texture = .{ .idx = std.math.maxInt(u16) };
    }
    shaders_initialized = false;

    // YUV video program + its plane samplers participate in the same teardown,
    // so an Android surface cycle re-creates them lazily on the next video draw.
    if (isValidProgram(yuv_program)) {
        bgfx.destroyProgram(yuv_program);
        yuv_program = .{ .idx = std.math.maxInt(u16) };
    }
    if (isValidHandle(s_texY_uniform.idx)) {
        bgfx.destroyUniform(s_texY_uniform);
        s_texY_uniform = .{ .idx = std.math.maxInt(u16) };
    }
    if (isValidHandle(s_texU_uniform.idx)) {
        bgfx.destroyUniform(s_texU_uniform);
        s_texU_uniform = .{ .idx = std.math.maxInt(u16) };
    }
    if (isValidHandle(s_texV_uniform.idx)) {
        bgfx.destroyUniform(s_texV_uniform);
        s_texV_uniform = .{ .idx = std.math.maxInt(u16) };
    }
    yuv_initialized = false;
    // Give the program one honest re-create attempt after a surface cycle.
    yuv_failed = false;

    // Hand off to the sibling modules that own their own bgfx
    // handles. Pre-split this loop and the font-atlas teardown lived
    // inline here; now they live next to the state they walk.
    texture_mod.destroyAllTextures();
    font_mod.destroyFontAtlas();
}

/// Returns true when the shader program is valid and ready for use.
pub fn areProgramsReady() bool {
    return shaders_initialized and isValidProgram(sprite_program);
}

pub fn ensureLayouts() void {
    if (layouts_initialized) return;

    // Unified layout matching the v1 sprite shader:
    //   a_position  (vec2)  — 2 floats
    //   a_texcoord0 (vec2)  — 2 floats
    //   a_color0    (vec4)  — 4 Uint8, normalized
    _ = vertex_layout.begin(.Noop);
    _ = vertex_layout.add(.Position, 2, .Float, false, false);
    _ = vertex_layout.add(.TexCoord0, 2, .Float, false, false);
    _ = vertex_layout.add(.Color0, 4, .Uint8, true, false);
    vertex_layout.end();

    layouts_initialized = true;
}

// ── Internal submit helpers ───────────────────────────────────────────

pub fn submitFlatTriangles(vertices: []const PosTexColorVertex) void {
    ensureShadersInitialized();
    if (!isValidProgram(sprite_program)) return;
    ensureLayouts();

    // Set u_viewProj to identity each frame (bgfx clears uniforms after submit)
    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(VIEW_ID, &identity, &identity);

    const num_vertices: usize = vertices.len;
    const num: u32 = @intCast(num_vertices);
    var tvb: bgfx.TransientVertexBuffer = undefined;

    bgfx.allocTransientVertexBuffer(&tvb, num, &vertex_layout);

    const dest: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(dest[0..num_vertices], vertices);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, num);
    // Bind 1x1 white texture so the shader computes: white * vertex_color = vertex_color
    bgfx.setTexture(0, s_tex_uniform, white_texture, 0);
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA | STATE_BLEND_ALPHA, 0);
    bgfx.submit(VIEW_ID, sprite_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
}

pub fn submitTexturedTriangles(vertices: []const PosTexColorVertex, texture_handle: bgfx.TextureHandle) void {
    ensureShadersInitialized();
    if (!isValidProgram(sprite_program)) return;
    if (!isValidHandle(s_tex_uniform.idx)) return;
    ensureLayouts();

    // Set u_viewProj to identity each frame (bgfx clears uniforms after submit)
    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(VIEW_ID, &identity, &identity);

    const num_vertices: usize = vertices.len;
    const num: u32 = @intCast(num_vertices);
    var tvb: bgfx.TransientVertexBuffer = undefined;

    bgfx.allocTransientVertexBuffer(&tvb, num, &vertex_layout);

    const dest_ptr: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(dest_ptr[0..num_vertices], vertices);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, num);
    bgfx.setTexture(0, s_tex_uniform, texture_handle, 0);
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA | STATE_BLEND_ALPHA, 0);
    bgfx.submit(VIEW_ID, sprite_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
}

/// Submit a textured quad converted from three YUV plane textures via the
/// `yuv_program` (GPU YUV→RGBA). Binds Y/U/V to sampler units 0/1/2. Mirrors
/// `submitTexturedTriangles` but with the video program + three samplers; the
/// vertices carry the same NDC positions + UVs (`drawPlanesPro` builds them).
pub fn submitYuvTriangles(
    vertices: []const PosTexColorVertex,
    y_handle: bgfx.TextureHandle,
    u_handle: bgfx.TextureHandle,
    v_handle: bgfx.TextureHandle,
) void {
    if (!ensureYuvProgram()) return;
    ensureLayouts();

    // Set u_viewProj to identity each frame (bgfx clears uniforms after submit)
    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(VIEW_ID, &identity, &identity);

    const num: u32 = @intCast(vertices.len);
    var tvb: bgfx.TransientVertexBuffer = undefined;
    bgfx.allocTransientVertexBuffer(&tvb, num, &vertex_layout);
    const dest_ptr: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(dest_ptr[0..vertices.len], vertices);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, num);
    bgfx.setTexture(0, s_texY_uniform, y_handle, 0);
    bgfx.setTexture(1, s_texU_uniform, u_handle, 0);
    bgfx.setTexture(2, s_texV_uniform, v_handle, 0);
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA | STATE_BLEND_ALPHA, 0);
    bgfx.submit(VIEW_ID, yuv_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
}
