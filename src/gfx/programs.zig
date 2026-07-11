/// Shader programs, vertex layout, white-fallback texture, and the
/// `submit*` helpers that every draw path funnels through. All bgfx
/// "engine warmup" state lives here so the draw / texture / font
/// modules don't each carry their own shader-init flags.
const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const core = @import("labelle-core");
const shaders_data = @import("../shaders.zig");
const texture_mod = @import("texture.zig");
const font_mod = @import("font.zig");

const MaterialEffect = core.backend_contract.MaterialEffect;
const MaterialUniforms = core.backend_contract.MaterialUniforms;

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

// ── Premultiplied-alpha blend states for `drawMesh` (labelle-gfx#290) ──
// Spine's default export uses a premultiplied-alpha (PMA) atlas, so the four
// Spine blend modes map to PMA blend funcs (src factor is ONE / DST_COLOR, not
// SRC_ALPHA). These mirror the spine-glfw reference renderer's blend table.
/// PMA "normal": ONE, INV_SRC_ALPHA.
pub const STATE_BLEND_PMA_NORMAL: u64 = stateBlendFuncSeparate(
    bgfx.StateFlags_BlendOne,
    bgfx.StateFlags_BlendInvSrcAlpha,
    bgfx.StateFlags_BlendOne,
    bgfx.StateFlags_BlendInvSrcAlpha,
);
/// PMA additive: ONE, ONE.
pub const STATE_BLEND_PMA_ADD: u64 = stateBlendFuncSeparate(
    bgfx.StateFlags_BlendOne,
    bgfx.StateFlags_BlendOne,
    bgfx.StateFlags_BlendOne,
    bgfx.StateFlags_BlendOne,
);
/// PMA multiply: DST_COLOR, INV_SRC_ALPHA.
pub const STATE_BLEND_PMA_MULTIPLY: u64 = stateBlendFuncSeparate(
    bgfx.StateFlags_BlendDstColor,
    bgfx.StateFlags_BlendInvSrcAlpha,
    bgfx.StateFlags_BlendDstColor,
    bgfx.StateFlags_BlendInvSrcAlpha,
);
/// PMA screen: ONE, INV_SRC_COLOR.
pub const STATE_BLEND_PMA_SCREEN: u64 = stateBlendFuncSeparate(
    bgfx.StateFlags_BlendOne,
    bgfx.StateFlags_BlendInvSrcColor,
    bgfx.StateFlags_BlendOne,
    bgfx.StateFlags_BlendInvSrcColor,
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

/// The primary bgfx view — the backbuffer on a windowed run, or the offscreen
/// capture framebuffer under `window.initHeadless` (labelle-bgfx#36). It is
/// always drawn LAST (see `render_target.sequenceViews`) so any render-target
/// passes that feed it — e.g. a transport mirror sampling an offscreen texture —
/// are already resolved by the time the screen is composited.
pub const PRIMARY_VIEW: u16 = 0;

/// The bgfx view every `submit*` helper below renders into. Defaults to
/// `PRIMARY_VIEW`; `render_target.begin`/`end` retarget it at an offscreen
/// framebuffer's view, so the *same* draw primitives (rects, sprites, text,
/// meshes) fill a texture instead of the screen — the shared basis of both the
/// headless offscreen capture (#36) and the mirror.
var active_view: u16 = PRIMARY_VIEW;

/// The view `submit*` currently targets. `render_target` reads this to save +
/// restore the previous target around a (possibly nested) offscreen pass.
pub fn activeView() u16 {
    return active_view;
}

/// Point every subsequent draw at `id` — a render-target's view, or
/// `PRIMARY_VIEW` to return to the screen. `render_target` owns the begin/end
/// bracketing; callers should not poke this directly.
pub fn setActiveView(id: u16) void {
    active_view = id;
}

/// Initialize embedded shaders, uniforms, and the 1x1 white fallback texture.
/// Called lazily from submit functions. Detects the renderer type and selects
/// the appropriate pre-compiled shader variant (Metal, Vulkan, or GLSL).
fn initShaders() void {
    if (shaders_initialized) return;

    // Select shader variant based on active renderer
    // `.OpenGLES` = WebGL2 (emscripten) / GLES; it needs the essl `#version
    // 300 es` variants — the desktop GLSL arrays are `-p 120` and render blank
    // on WebGL2. Desktop `.OpenGL` (2.1) stays on the `-p 120` glsl `else` arm.
    const vs_data: []const u8 = switch (bgfx.getRendererType()) {
        .Metal => &shaders_data.vs_sprite_mtl,
        .Vulkan => &shaders_data.vs_sprite_spv,
        .OpenGLES => &shaders_data.vs_sprite_essl,
        else => &shaders_data.vs_sprite_glsl,
    };
    const fs_data: []const u8 = switch (bgfx.getRendererType()) {
        .Metal => &shaders_data.fs_sprite_mtl,
        .Vulkan => &shaders_data.fs_sprite_spv,
        .OpenGLES => &shaders_data.fs_sprite_essl,
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
    bgfx.setViewTransform(active_view, &identity, &identity);

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
        .OpenGLES => &shaders_data.vs_sprite_essl,
        else => &shaders_data.vs_sprite_glsl,
    };
    const fs_data: []const u8 = switch (bgfx.getRendererType()) {
        .Metal => &shaders_data.fs_yuv_mtl,
        .Vulkan => &shaders_data.fs_yuv_spv,
        .OpenGLES => &shaders_data.fs_yuv_essl,
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

// ── Material programs (curated per-draw effects, labelle-gfx#305 Slice B) ──────
// Two programs built from `vs_sprite` + a material fragment shader, following the
// exact YUV-path pattern above: per-renderer bytecode selected by
// `bgfx.getRendererType()`, lazily `createProgram`d, latch-failing to the plain
// sprite path (the material draw degrades — no crash). One program per effect:
//   `flash_program`   ← fs_flash   (mix sprite→flash colour by amount)
//   `palette_program` ← fs_palette (recolour by red-channel index via `s_lut`)
// Both share two `vec4` uniforms (`u_material_color`/`u_material_params`) mapping
// the flat `MaterialUniforms`; palette additionally binds a LUT sampler at unit 1.
var flash_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var palette_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var s_lut_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var u_material_color_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var u_material_params_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var material_initialized: bool = false;
/// Latches a build/link failure so `ensureMaterialPrograms` retries at most once
/// (mirrors `yuv_failed`) — a per-frame re-create would leak + exhaust the handle
/// pool. Cleared by `shutdownPrograms` for a fresh post-surface-loss attempt.
var material_failed: bool = false;

/// Select the renderer-appropriate fragment bytecode for a material shader.
fn materialFsData(comptime base: []const u8) []const u8 {
    return switch (bgfx.getRendererType()) {
        .Metal => &@field(shaders_data, base ++ "_mtl"),
        .Vulkan => &@field(shaders_data, base ++ "_spv"),
        .OpenGLES => &@field(shaders_data, base ++ "_essl"),
        else => &@field(shaders_data, base ++ "_glsl"),
    };
}

/// Build ONE material program from a fresh `vs_sprite` handle + the given fragment
/// bytecode. Returns an invalid handle (and reclaims any created shader) on
/// failure. Each program gets its OWN vs handle because `createProgram` with
/// `destroy_shaders=true` consumes the handles it is given.
fn buildMaterialProgram(fs_data: []const u8) bgfx.ProgramHandle {
    const invalid = bgfx.ProgramHandle{ .idx = std.math.maxInt(u16) };
    const vs_data: []const u8 = switch (bgfx.getRendererType()) {
        .Metal => &shaders_data.vs_sprite_mtl,
        .Vulkan => &shaders_data.vs_sprite_spv,
        .OpenGLES => &shaders_data.vs_sprite_essl,
        else => &shaders_data.vs_sprite_glsl,
    };
    const vs_handle = bgfx.createShader(bgfx.makeRef(vs_data.ptr, @intCast(vs_data.len)));
    const fs_handle = bgfx.createShader(bgfx.makeRef(fs_data.ptr, @intCast(fs_data.len)));
    if (!isValidHandle(vs_handle.idx) or !isValidHandle(fs_handle.idx)) {
        if (isValidHandle(vs_handle.idx)) bgfx.destroyShader(vs_handle);
        if (isValidHandle(fs_handle.idx)) bgfx.destroyShader(fs_handle);
        return invalid;
    }
    const prog = bgfx.createProgram(vs_handle, fs_handle, true);
    if (!isValidProgram(prog)) {
        // createProgram does NOT consume the shaders on failure — destroy them
        // here or leak two handles per attempt (exhausts the pool; see YUV path).
        bgfx.destroyShader(vs_handle);
        bgfx.destroyShader(fs_handle);
        return invalid;
    }
    return prog;
}

/// Lazily build BOTH material programs + their shared uniforms. On any failure,
/// tears the whole group down and latches `material_failed` so the material draw
/// degrades to the plain sprite path (via `submitMaterialTriangles` returning
/// false) rather than crashing or leaking every frame.
fn initMaterialPrograms() void {
    if (material_initialized) return;

    flash_program = buildMaterialProgram(materialFsData("fs_flash"));
    palette_program = buildMaterialProgram(materialFsData("fs_palette"));
    if (!isValidProgram(flash_program) or !isValidProgram(palette_program)) {
        std.log.err("bgfx: failed to build material programs (link failed on this renderer); materials degrade to plain sprites", .{});
        if (isValidProgram(flash_program)) bgfx.destroyProgram(flash_program);
        if (isValidProgram(palette_program)) bgfx.destroyProgram(palette_program);
        flash_program = .{ .idx = std.math.maxInt(u16) };
        palette_program = .{ .idx = std.math.maxInt(u16) };
        material_failed = true;
        return;
    }

    s_lut_uniform = bgfx.createUniform("s_lut", .Sampler, 1);
    u_material_color_uniform = bgfx.createUniform("u_material_color", .Vec4, 1);
    u_material_params_uniform = bgfx.createUniform("u_material_params", .Vec4, 1);
    if (!isValidHandle(s_lut_uniform.idx) or !isValidHandle(u_material_color_uniform.idx) or
        !isValidHandle(u_material_params_uniform.idx))
    {
        std.log.err("bgfx: failed to create material uniforms; materials degrade to plain sprites", .{});
        destroyMaterialPrograms();
        material_failed = true;
        return;
    }

    material_initialized = true;
    std.log.info("bgfx: material programs initialized (renderer: {})", .{bgfx.getRendererType()});
}

/// Ensure the material programs are ready. Tries to build at most once (latches
/// `material_failed`); cleared by `shutdownPrograms`. Returns true when both
/// programs + all uniforms are valid.
pub fn ensureMaterialPrograms() bool {
    if (!material_initialized) {
        if (material_failed) return false;
        initMaterialPrograms();
    }
    return material_initialized;
}

fn destroyMaterialPrograms() void {
    if (isValidProgram(flash_program)) bgfx.destroyProgram(flash_program);
    if (isValidProgram(palette_program)) bgfx.destroyProgram(palette_program);
    flash_program = .{ .idx = std.math.maxInt(u16) };
    palette_program = .{ .idx = std.math.maxInt(u16) };
    if (isValidHandle(s_lut_uniform.idx)) bgfx.destroyUniform(s_lut_uniform);
    if (isValidHandle(u_material_color_uniform.idx)) bgfx.destroyUniform(u_material_color_uniform);
    if (isValidHandle(u_material_params_uniform.idx)) bgfx.destroyUniform(u_material_params_uniform);
    s_lut_uniform = .{ .idx = std.math.maxInt(u16) };
    u_material_color_uniform = .{ .idx = std.math.maxInt(u16) };
    u_material_params_uniform = .{ .idx = std.math.maxInt(u16) };
    material_initialized = false;
}

/// Submit a material-shaded textured quad — the bgfx impl of labelle-core's
/// optional `drawTextureProMaterial` contract. Mirrors `submitTexturedTriangles`
/// but selects the effect's program, uploads the flat `MaterialUniforms` as two
/// `vec4`s, and (for `palette_swap`) binds the LUT ramp at sampler unit 1.
/// `lut_handle` is ignored for `flash`; the caller guarantees it is valid when
/// `effect == .palette_swap` (a zero LUT degrades to the plain path upstream).
/// No-ops (leaving the sprite undrawn) only if the programs failed to build; the
/// draw site never falls back here, so the caller must have gated on
/// `ensureMaterialPrograms`/`materialSupported` — see `texture.drawTextureProMaterial`.
pub fn submitMaterialTriangles(
    vertices: []const PosTexColorVertex,
    texture_handle: bgfx.TextureHandle,
    effect: MaterialEffect,
    uniforms: MaterialUniforms,
    lut_handle: bgfx.TextureHandle,
) void {
    // The material programs reuse the sprite path's `s_tex_uniform`, so the
    // sprite shaders must be up first (they may not be if a material sprite is
    // the very first draw). `ensureShadersInitialized` is idempotent.
    ensureShadersInitialized();
    if (!isValidHandle(s_tex_uniform.idx)) return;
    if (!ensureMaterialPrograms()) return;
    const program = switch (effect) {
        .flash => flash_program,
        .palette_swap => palette_program,
        else => return, // dissolve/outline/none are not implemented by bgfx
    };
    if (!isValidProgram(program)) return;
    ensureLayouts();

    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(active_view, &identity, &identity);

    // Flat MaterialUniforms → two vec4s the shaders read (see fs_flash/fs_palette).
    const color = [4]f32{ uniforms.r, uniforms.g, uniforms.b, uniforms.a };
    const params = [4]f32{ uniforms.scalar0, uniforms.scalar1, @floatFromInt(uniforms.aux_count), 0.0 };
    bgfx.setUniform(u_material_color_uniform, &color, 1);
    bgfx.setUniform(u_material_params_uniform, &params, 1);

    const num: u32 = @intCast(vertices.len);
    var tvb: bgfx.TransientVertexBuffer = undefined;
    bgfx.allocTransientVertexBuffer(&tvb, num, &vertex_layout);
    const dest_ptr: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(dest_ptr[0..vertices.len], vertices);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, num);
    bgfx.setTexture(0, s_tex_uniform, texture_handle, 0);
    if (effect == .palette_swap) bgfx.setTexture(1, s_lut_uniform, lut_handle, 0);
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA | STATE_BLEND_ALPHA, 0);
    bgfx.submit(active_view, program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
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

    // Material programs (labelle-gfx#305) participate in the same teardown so an
    // Android surface cycle re-creates them lazily on the next material draw.
    destroyMaterialPrograms();
    material_failed = false;

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
    bgfx.setViewTransform(active_view, &identity, &identity);

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
    bgfx.submit(active_view, sprite_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
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
    bgfx.setViewTransform(active_view, &identity, &identity);

    const num_vertices: usize = vertices.len;
    const num: u32 = @intCast(num_vertices);
    var tvb: bgfx.TransientVertexBuffer = undefined;

    bgfx.allocTransientVertexBuffer(&tvb, num, &vertex_layout);

    const dest_ptr: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(dest_ptr[0..num_vertices], vertices);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, num);
    bgfx.setTexture(0, s_tex_uniform, texture_handle, 0);
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA | STATE_BLEND_ALPHA, 0);
    bgfx.submit(active_view, sprite_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
}

/// Submit an INDEXED textured triangle mesh through the sprite program — the
/// bgfx impl of labelle-core's optional `drawMesh` contract (skeletal animation,
/// labelle-gfx#290). Reuses the exact sprite pipeline (same `vertex_layout`,
/// `sprite_program`, `s_tex_uniform`) as `submitTexturedTriangles`, but adds a
/// transient INDEX buffer (Spine meshes are indexed) and takes an explicit
/// `blend_state` (Spine attachments request per-command blend modes). The
/// vertices are expected already in NDC (`gfx.drawMesh` applies `toNdcX/Y`).
pub fn submitMesh(
    vertices: []const PosTexColorVertex,
    indices: []const u16,
    texture_handle: bgfx.TextureHandle,
    blend_state: u64,
) void {
    ensureShadersInitialized();
    if (!isValidProgram(sprite_program)) return;
    if (!isValidHandle(s_tex_uniform.idx)) return;
    if (vertices.len == 0 or indices.len == 0) return;
    ensureLayouts();

    // Identity viewProj — vertices are already in NDC (parity with the sprite path).
    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(active_view, &identity, &identity);

    const num_v: u32 = @intCast(vertices.len);
    const num_i: u32 = @intCast(indices.len);

    var tvb: bgfx.TransientVertexBuffer = undefined;
    var tib: bgfx.TransientIndexBuffer = undefined;

    // Guard against over-allocating the transient ring (bgfx would assert).
    if (bgfx.getAvailTransientVertexBuffer(num_v, &vertex_layout) < num_v) return;
    if (bgfx.getAvailTransientIndexBuffer(num_i, false) < num_i) return;

    bgfx.allocTransientVertexBuffer(&tvb, num_v, &vertex_layout);
    bgfx.allocTransientIndexBuffer(&tib, num_i, false); // 16-bit indices

    const vdest: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(vdest[0..vertices.len], vertices);
    const idest: [*]u16 = @ptrCast(@alignCast(tib.data));
    @memcpy(idest[0..indices.len], indices);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, num_v);
    bgfx.setTransientIndexBuffer(&tib, 0, num_i);
    bgfx.setTexture(0, s_tex_uniform, texture_handle, 0);
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA | blend_state, 0);
    bgfx.submit(active_view, sprite_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
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
    bgfx.setViewTransform(active_view, &identity, &identity);

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
    bgfx.submit(active_view, yuv_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
}
