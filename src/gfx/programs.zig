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
const PostPassKind = core.backend_contract.PostPassKind;
const PostPassUniforms = core.backend_contract.PostPassUniforms;

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

// ── Material programs (curated per-draw effects, labelle-gfx#305) ──────────────
// Four programs built from `vs_sprite` + a material fragment shader, following the
// exact YUV-path pattern above: per-renderer bytecode selected by
// `bgfx.getRendererType()`, lazily `createProgram`d, degrading to the plain sprite
// path (the material draw degrades — no crash). Built PER-EFFECT: a link failure
// in one effect leaves the others valid, and only the failed effect degrades
// (gated by `materialProgramReady` at the draw site) — never the whole seam. One
// program per effect:
//   `flash_program`   ← fs_flash   (mix sprite→flash colour by amount)
//   `palette_program` ← fs_palette (recolour by red-channel index via `s_lut`)
// All four share two `vec4` uniforms (`u_material_color`/`u_material_params`)
// mapping the flat `MaterialUniforms`; palette + dissolve additionally bind an
// aux sampler at unit 1 (`s_lut` — the LUT ramp for palette, the optional noise
// texture for dissolve); outline additionally reads `u_material_texel` (the
// sprite texture's pixel size) to turn a px thickness into a UV offset.
//   `flash_program`    ← fs_flash    (mix sprite→flash colour by amount)
//   `palette_program`  ← fs_palette  (recolour by red-channel index via `s_lut`)
//   `dissolve_program` ← fs_dissolve (noise-gated burn-away + edge glow)
//   `outline_program`  ← fs_outline  (8-tap alpha-dilated silhouette)
var flash_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var palette_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var dissolve_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var outline_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var s_lut_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var u_material_color_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var u_material_params_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var u_material_texel_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
// The sprite's source frame in whole-atlas UV space (u0, v0, u1, v1). dissolve
// remaps the atlas UV to sprite-local for a per-frame-consistent noise scale;
// outline gates its neighbour taps to this rect so it can't dilate an adjacent
// atlas frame's content. (0,0,1,1) for a standalone texture.
var u_material_rect_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
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

/// The material program backing `effect` (invalid sentinel for `none`/unbuilt).
fn programForEffect(effect: MaterialEffect) bgfx.ProgramHandle {
    return switch (effect) {
        .flash => flash_program,
        .palette_swap => palette_program,
        .dissolve => dissolve_program,
        .outline => outline_program,
        else => .{ .idx = std.math.maxInt(u16) },
    };
}

/// Lazily build the four material programs (PER-EFFECT) + their shared uniforms.
/// Each program is built INDEPENDENTLY: a link failure in one effect (e.g. a
/// driver that rejects `fs_outline`) leaves the OTHER three valid — only the
/// failed effect degrades to a plain sprite (gated by `materialProgramReady` at
/// the draw site), never the whole material seam. The shared uniforms are the
/// one hard, latched failure: they feed every material shader, so if they can't
/// be created NO material can run — tear the group down and latch `material_failed`.
fn initMaterialPrograms() void {
    if (material_initialized) return;

    // Build each program on its own; keep whichever succeed. `buildMaterialProgram`
    // already reclaims its shaders on failure, so an invalid handle here is a
    // clean "this effect is unavailable", not a leak.
    flash_program = buildMaterialProgram(materialFsData("fs_flash"));
    palette_program = buildMaterialProgram(materialFsData("fs_palette"));
    dissolve_program = buildMaterialProgram(materialFsData("fs_dissolve"));
    outline_program = buildMaterialProgram(materialFsData("fs_outline"));

    s_lut_uniform = bgfx.createUniform("s_lut", .Sampler, 1);
    u_material_color_uniform = bgfx.createUniform("u_material_color", .Vec4, 1);
    u_material_params_uniform = bgfx.createUniform("u_material_params", .Vec4, 1);
    u_material_texel_uniform = bgfx.createUniform("u_material_texel", .Vec4, 1);
    u_material_rect_uniform = bgfx.createUniform("u_material_rect", .Vec4, 1);
    if (!isValidHandle(s_lut_uniform.idx) or !isValidHandle(u_material_color_uniform.idx) or
        !isValidHandle(u_material_params_uniform.idx) or !isValidHandle(u_material_texel_uniform.idx) or
        !isValidHandle(u_material_rect_uniform.idx))
    {
        std.log.err("bgfx: failed to create material uniforms; ALL materials degrade to plain sprites", .{});
        destroyMaterialPrograms(); // also clears any programs that DID build
        material_failed = true;
        return;
    }

    // A per-effect link failure is a warning (that effect degrades), not fatal.
    if (!isValidProgram(flash_program) or !isValidProgram(palette_program) or
        !isValidProgram(dissolve_program) or !isValidProgram(outline_program))
    {
        std.log.warn("bgfx: some material programs failed to link; those effects degrade to plain sprites (flash={} palette_swap={} dissolve={} outline={})", .{
            isValidProgram(flash_program),   isValidProgram(palette_program),
            isValidProgram(dissolve_program), isValidProgram(outline_program),
        });
    }

    material_initialized = true;
    std.log.info("bgfx: material programs initialized (renderer: {})", .{bgfx.getRendererType()});
}

/// Ensure the material SHARED INFRA (uniforms) is ready. Tries to build at most
/// once (latches `material_failed`); cleared by `shutdownPrograms`. Returns true
/// when the shared uniforms exist — per-EFFECT program availability is checked
/// separately by `materialProgramReady` (one effect failing to link does not
/// disable the others).
pub fn ensureMaterialPrograms() bool {
    if (!material_initialized) {
        if (material_failed) return false;
        initMaterialPrograms();
    }
    return material_initialized;
}

/// True when the material program for `effect` built + linked on this renderer
/// (and the shared uniforms exist). Per-effect: consulted by the draw site so a
/// single failed effect degrades to a plain sprite while the others keep working.
pub fn materialProgramReady(effect: MaterialEffect) bool {
    if (!ensureMaterialPrograms()) return false; // shared uniforms dead → all degrade
    return isValidProgram(programForEffect(effect));
}

fn destroyMaterialPrograms() void {
    inline for (.{ &flash_program, &palette_program, &dissolve_program, &outline_program }) |p| {
        if (isValidProgram(p.*)) bgfx.destroyProgram(p.*);
        p.* = .{ .idx = std.math.maxInt(u16) };
    }
    inline for (.{ &s_lut_uniform, &u_material_color_uniform, &u_material_params_uniform, &u_material_texel_uniform, &u_material_rect_uniform }) |u| {
        if (isValidHandle(u.*.idx)) bgfx.destroyUniform(u.*);
        u.* = .{ .idx = std.math.maxInt(u16) };
    }
    material_initialized = false;
}

/// Submit a material-shaded textured quad — the bgfx impl of labelle-core's
/// optional `drawTextureProMaterial` contract. Mirrors `submitTexturedTriangles`
/// but selects the effect's program, uploads the flat `MaterialUniforms` as two
/// `vec4`s, and (for `palette_swap`) binds the LUT ramp at sampler unit 1.
/// `lut_handle` is the aux texture bound at unit 1 (sampler `s_lut`): the LUT
/// ramp for `palette_swap`, the noise texture for `dissolve`. It is ignored for
/// `flash`/`outline`; the caller guarantees it is valid whenever it is sampled
/// (`palette_swap` with a zero LUT degrades to the plain path upstream; the
/// `dissolve` procedural path binds the sprite's own texture as a harmless dummy
/// so unit 1 is never an unbound-sampler read). `tex_w`/`tex_h` are the sprite
/// texture's pixel dimensions, used to build `u_material_texel` for `outline`
/// (px thickness → UV offset). `rect` is the sprite's source frame in whole-atlas
/// UV space (u0, v0, u1, v1) → `u_material_rect`, driving dissolve's sprite-local
/// noise remap and outline's per-frame tap gating ((0,0,1,1) for a standalone
/// texture). No-ops (leaving the sprite undrawn) only if the programs failed to
/// build; the draw site never falls back here, so the caller must have gated on
/// `ensureMaterialPrograms`/`materialSupported` — see `texture.drawTextureProMaterial`.
pub fn submitMaterialTriangles(
    vertices: []const PosTexColorVertex,
    texture_handle: bgfx.TextureHandle,
    effect: MaterialEffect,
    uniforms: MaterialUniforms,
    lut_handle: bgfx.TextureHandle,
    tex_w: u32,
    tex_h: u32,
    rect: [4]f32,
) void {
    // The material programs reuse the sprite path's `s_tex_uniform`, so the
    // sprite shaders must be up first (they may not be if a material sprite is
    // the very first draw). `ensureShadersInitialized` is idempotent.
    ensureShadersInitialized();
    if (!isValidHandle(s_tex_uniform.idx)) return;
    if (!ensureMaterialPrograms()) return;
    // Per-effect: this specific program may have failed to link even though the
    // shared infra + other effects are fine. The caller gates on
    // `materialProgramReady` and falls back to a plain sprite, so reaching here
    // with a dead program is defensive — no-op rather than submit a null program.
    const program = programForEffect(effect);
    if (!isValidProgram(program)) return;
    ensureLayouts();

    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(active_view, &identity, &identity);

    // Flat MaterialUniforms → the vec4s the shaders read (see the fs_* sources).
    // params.w carries the `dissolve` use-noise-texture flag (1 when a real noise
    // texture is bound at s_lut, 0 for the built-in procedural noise); it is 0
    // for every other effect. params.z is `palette_swap`'s ramp entry count.
    const color = [4]f32{ uniforms.r, uniforms.g, uniforms.b, uniforms.a };
    const use_noise: f32 = if (effect == .dissolve and uniforms.aux_texture != 0) 1.0 else 0.0;
    const params = [4]f32{ uniforms.scalar0, uniforms.scalar1, @floatFromInt(uniforms.aux_count), use_noise };
    bgfx.setUniform(u_material_color_uniform, &color, 1);
    bgfx.setUniform(u_material_params_uniform, &params, 1);
    // Texel size (1/w, 1/h, w, h) for `outline`'s px→UV thickness. Harmless to
    // set for the other programs (they don't declare it).
    const w_f: f32 = @floatFromInt(@max(tex_w, 1));
    const h_f: f32 = @floatFromInt(@max(tex_h, 1));
    const texel = [4]f32{ 1.0 / w_f, 1.0 / h_f, w_f, h_f };
    bgfx.setUniform(u_material_texel_uniform, &texel, 1);
    // Source frame UV bounds (u0, v0, u1, v1) for dissolve's local-UV noise remap
    // + outline's per-frame tap gate. Harmless for flash/palette (unused there).
    bgfx.setUniform(u_material_rect_uniform, &rect, 1);

    const num: u32 = @intCast(vertices.len);
    var tvb: bgfx.TransientVertexBuffer = undefined;
    bgfx.allocTransientVertexBuffer(&tvb, num, &vertex_layout);
    const dest_ptr: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(dest_ptr[0..vertices.len], vertices);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, num);
    bgfx.setTexture(0, s_tex_uniform, texture_handle, 0);
    // palette_swap + dissolve sample the aux texture at unit 1 (`s_lut`).
    if (effect == .palette_swap or effect == .dissolve) bgfx.setTexture(1, s_lut_uniform, lut_handle, 0);
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA | STATE_BLEND_ALPHA, 0);
    bgfx.submit(active_view, program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
}

// ── Post-fx programs (full-screen passes, labelle-gfx#305 P2 Slice B) ──────────
// Four programs — one per `PostPassKind` — each `vs_sprite` + a post-fx fragment
// shader (fs_bloom / fs_vignette / fs_color_grade / fs_crt), following the SAME
// lazy-build + latch-fail pattern as the material programs. Where a material draw
// shades a sprite quad, a post pass shades a FULL-SCREEN NDC quad that samples one
// render target's colour texture (`src`) and writes another (`dst`) — the gfx
// ping-pong driver (RFC §2.4) sequences those src→dst hops; the backend only owns
// this single primitive. Three shared `vec4` uniforms carry the flat
// `PostPassUniforms`; `color_grade` additionally binds its LUT strip at unit 1.
//   u_postfx_params = (scalar0, scalar1, scalar2, scalar3)
//   u_postfx_color  = (r, g, b, 0)                       — vignette tint
//   u_postfx_texel  = (1/w, 1/h, w, h)                   — src/dst pixel size
var bloom_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var vignette_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var color_grade_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var crt_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };
var s_postfx_lut_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var u_postfx_params_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var u_postfx_color_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var u_postfx_texel_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };
var postfx_initialized: bool = false;
/// Latches a build/link failure so `ensurePostFxPrograms` retries at most once
/// (mirrors `material_failed` / `yuv_failed`). Cleared by `shutdownPrograms`.
var postfx_failed: bool = false;

/// Lazily build all four post-fx programs + their shared uniforms. On any failure
/// tears the whole group down and latches `postfx_failed`, so the post-fx stack
/// degrades to a no-op (the gfx driver then renders straight to the backbuffer)
/// rather than crashing or leaking a handle per frame.
fn initPostFxPrograms() void {
    if (postfx_initialized) return;

    bloom_program = buildMaterialProgram(materialFsData("fs_bloom"));
    vignette_program = buildMaterialProgram(materialFsData("fs_vignette"));
    color_grade_program = buildMaterialProgram(materialFsData("fs_color_grade"));
    crt_program = buildMaterialProgram(materialFsData("fs_crt"));
    if (!isValidProgram(bloom_program) or !isValidProgram(vignette_program) or
        !isValidProgram(color_grade_program) or !isValidProgram(crt_program))
    {
        std.log.err("bgfx: failed to build post-fx programs (link failed on this renderer); post-fx stack degrades to a no-op", .{});
        destroyPostFxPrograms();
        postfx_failed = true;
        return;
    }

    s_postfx_lut_uniform = bgfx.createUniform("s_lut", .Sampler, 1);
    u_postfx_params_uniform = bgfx.createUniform("u_postfx_params", .Vec4, 1);
    u_postfx_color_uniform = bgfx.createUniform("u_postfx_color", .Vec4, 1);
    u_postfx_texel_uniform = bgfx.createUniform("u_postfx_texel", .Vec4, 1);
    if (!isValidHandle(s_postfx_lut_uniform.idx) or !isValidHandle(u_postfx_params_uniform.idx) or
        !isValidHandle(u_postfx_color_uniform.idx) or !isValidHandle(u_postfx_texel_uniform.idx))
    {
        std.log.err("bgfx: failed to create post-fx uniforms; post-fx stack degrades to a no-op", .{});
        destroyPostFxPrograms();
        postfx_failed = true;
        return;
    }

    postfx_initialized = true;
    std.log.info("bgfx: post-fx programs initialized (renderer: {})", .{bgfx.getRendererType()});
}

/// Ensure the post-fx programs are ready. Tries to build at most once (latches
/// `postfx_failed`); cleared by `shutdownPrograms`. Returns true when all four
/// programs + every uniform are valid.
pub fn ensurePostFxPrograms() bool {
    if (!postfx_initialized) {
        if (postfx_failed) return false;
        initPostFxPrograms();
    }
    return postfx_initialized;
}

fn destroyPostFxPrograms() void {
    inline for (.{ &bloom_program, &vignette_program, &color_grade_program, &crt_program }) |p| {
        if (isValidProgram(p.*)) bgfx.destroyProgram(p.*);
        p.* = .{ .idx = std.math.maxInt(u16) };
    }
    inline for (.{ &s_postfx_lut_uniform, &u_postfx_params_uniform, &u_postfx_color_uniform, &u_postfx_texel_uniform }) |u| {
        if (isValidHandle(u.*.idx)) bgfx.destroyUniform(u.*);
        u.* = .{ .idx = std.math.maxInt(u16) };
    }
    postfx_initialized = false;
}

/// True when this renderer stores render-target textures BOTTOM-LEFT origin
/// (OpenGL / OpenGLES). On such backends the full-screen post-fx quad must
/// v-flip its sampled UVs — exactly as `render_target.draw` compensates with a
/// negative-height source rect — otherwise an ODD number of passes writes an
/// upside-down intermediate target. Metal / Vulkan / D3D are top-left origin, so
/// this returns false and the quad samples straight (Metal golden UNCHANGED).
fn postFxFlipV() bool {
    const caps = bgfx.getCaps();
    return caps != null and caps.*.originBottomLeft;
}

/// The two triangles of a full-screen quad in NDC (top = +1, matching
/// `state.toNdcY`) with UV 0..1 (top-left = 0,0, matching `drawTexturePro`'s
/// source→dest mapping) so a plain sample of `src` writes an upright, pixel-
/// aligned copy into `dst`. `flip_v` inverts the sampled V so the copy stays
/// upright on a BOTTOM-LEFT-origin backend (GL/GLES) too — pass `postFxFlipV()`.
/// On a top-left backend (`flip_v == false`) this is the identity copy. Vertex
/// colour is white — the post-fx shaders ignore `v_color0`.
fn fullscreenQuad(flip_v: bool) [6]PosTexColorVertex {
    const white: u32 = 0xFFFFFFFF;
    const vt: f32 = if (flip_v) 1.0 else 0.0; // V at NDC top (+1)
    const vb: f32 = if (flip_v) 0.0 else 1.0; // V at NDC bottom (-1)
    return .{
        .{ .x = -1.0, .y = 1.0, .u = 0.0, .v = vt, .abgr = white }, // top-left
        .{ .x = 1.0, .y = 1.0, .u = 1.0, .v = vt, .abgr = white }, // top-right
        .{ .x = 1.0, .y = -1.0, .u = 1.0, .v = vb, .abgr = white }, // bottom-right
        .{ .x = -1.0, .y = 1.0, .u = 0.0, .v = vt, .abgr = white }, // top-left
        .{ .x = 1.0, .y = -1.0, .u = 1.0, .v = vb, .abgr = white }, // bottom-right
        .{ .x = -1.0, .y = -1.0, .u = 0.0, .v = vb, .abgr = white }, // bottom-left
    };
}

// Pure host-side check of the GL/GLES origin fix (labelle-gfx#305 P2 review):
// the flipped quad must invert V at every vertex while leaving position and U
// untouched, so a bottom-left-origin backend (GL/GLES, `postFxFlipV() == true`)
// samples an intermediate target upright — matching `render_target.draw`'s
// negative-height flip. Compile-checked in the `gfx_mod` test graph. (Only the
// Metal, top-left, `flip_v == false` path is golden-covered on CI — there is no
// display-GL runner — so this pins the flip's INTENT alongside the code comment.)
test "fullscreenQuad flip inverts V, preserving position and U" {
    const straight = fullscreenQuad(false);
    const flipped = fullscreenQuad(true);
    for (straight, flipped) |s, f| {
        try std.testing.expectEqual(s.x, f.x);
        try std.testing.expectEqual(s.y, f.y);
        try std.testing.expectEqual(s.u, f.u);
        try std.testing.expectEqual(@as(f32, 1.0) - s.v, f.v); // V mirrored
    }
}

/// Submit a full-screen post-fx pass into the ACTIVE view (the `dst` render
/// target — `render_target.applyPostPass` has already `begin`d it): sample
/// `src_color` through the pass's program with the flat `PostPassUniforms`
/// marshalled to the three shared `vec4`s, writing a full-screen quad whose RGB
/// carries the effect and whose ALPHA is passed through from `src` (transparent
/// scene regions stay transparent — see the shaders' `src.a` output).
/// `dst_w`/`dst_h` size the texel uniform (src and dst share the design canvas,
/// so they double as the src sample size). `lut_handle` is bound at unit 1 for
/// `color_grade` only (its caller guarantees a valid handle; a zero/dead LUT is
/// blitted straight through upstream). If the programs failed to build/link this
/// degrades to a passthrough `src`→`dst` blit (NOT a no-op) so the ping-pong
/// chain keeps the correct image instead of leaving `dst` stale.
pub fn submitPostPass(
    kind: PostPassKind,
    uniforms: PostPassUniforms,
    src_color: bgfx.TextureHandle,
    dst_w: u16,
    dst_h: u16,
    lut_handle: bgfx.TextureHandle,
) void {
    // Post programs reuse the sprite path's `s_tex_uniform`; make sure it exists
    // even if a post pass is somehow the very first submit of the frame.
    ensureShadersInitialized();
    if (!isValidHandle(s_tex_uniform.idx)) return;
    // If the post-fx programs/uniforms failed to build/link on this renderer,
    // `applyPostPass` has ALREADY begin'd (bound) the `dst` view — returning here
    // would leave `dst` stale/undefined and break the rest of the ping-pong chain.
    // Degrade to a passthrough blit of `src`→`dst` (same fallback as a dead LUT)
    // so the chain continues with the correct image instead of a broken frame.
    if (!ensurePostFxPrograms()) return submitFullscreenBlit(src_color);
    const program = switch (kind) {
        .bloom => bloom_program,
        .vignette => vignette_program,
        .color_grade => color_grade_program,
        .crt => crt_program,
    };
    if (!isValidProgram(program)) return submitFullscreenBlit(src_color);
    ensureLayouts();

    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(active_view, &identity, &identity);

    const params = [4]f32{ uniforms.scalar0, uniforms.scalar1, uniforms.scalar2, uniforms.scalar3 };
    const color = [4]f32{ uniforms.r, uniforms.g, uniforms.b, 0.0 };
    const w_f: f32 = @floatFromInt(@max(dst_w, 1));
    const h_f: f32 = @floatFromInt(@max(dst_h, 1));
    const texel = [4]f32{ 1.0 / w_f, 1.0 / h_f, w_f, h_f };
    bgfx.setUniform(u_postfx_params_uniform, &params, 1);
    bgfx.setUniform(u_postfx_color_uniform, &color, 1);
    bgfx.setUniform(u_postfx_texel_uniform, &texel, 1);

    const verts = fullscreenQuad(postFxFlipV());
    var tvb: bgfx.TransientVertexBuffer = undefined;
    bgfx.allocTransientVertexBuffer(&tvb, verts.len, &vertex_layout);
    const dest_ptr: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(dest_ptr[0..verts.len], &verts);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, @intCast(verts.len));
    bgfx.setTexture(0, s_tex_uniform, src_color, 0);
    if (kind == .color_grade) bgfx.setTexture(1, s_postfx_lut_uniform, lut_handle, 0);
    // Opaque full-screen replace (no blend) — the pass owns every dst texel.
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA, 0);
    bgfx.submit(active_view, program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
}

/// Blit `src_color` full-screen into the ACTIVE view (the already-`begin`d `dst`
/// target) through the plain sprite program — the identity copy the post-fx
/// driver uses to propagate `src`→`dst` when a pass degrades (e.g. `color_grade`
/// with no LUT) so the ping-pong chain stays contiguous instead of black-holing.
pub fn submitFullscreenBlit(src_color: bgfx.TextureHandle) void {
    ensureShadersInitialized();
    if (!isValidProgram(sprite_program)) return;
    if (!isValidHandle(s_tex_uniform.idx)) return;
    ensureLayouts();

    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(active_view, &identity, &identity);

    const verts = fullscreenQuad(postFxFlipV());
    var tvb: bgfx.TransientVertexBuffer = undefined;
    bgfx.allocTransientVertexBuffer(&tvb, verts.len, &vertex_layout);
    const dest_ptr: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(dest_ptr[0..verts.len], &verts);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, @intCast(verts.len));
    bgfx.setTexture(0, s_tex_uniform, src_color, 0);
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA, 0);
    bgfx.submit(active_view, sprite_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
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

    // Post-fx programs (labelle-gfx#305 P2) share the same teardown so an Android
    // surface cycle re-creates them lazily on the next post-fx pass.
    destroyPostFxPrograms();
    postfx_failed = false;

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
