/// bgfx gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
/// Uses bgfx transient vertex buffers for shape rendering, bgfx texture API for sprites.
///
/// This file is the public façade for the bgfx gfx backend. The
/// implementation is split across `gfx/` submodules to keep each
/// concern below the 1000-line ceiling enforced by labelle-assembler#188:
///
///   - `gfx/types.zig`     — value types (Texture, Color, …) + color constants
///   - `gfx/state.zig`     — screen / camera state + coordinate helpers
///   - `gfx/programs.zig`  — shader programs, vertex layout, white texture, submit helpers
///   - `gfx/draw.zig`      — shape primitives (rect / circle / line / triangle / polygon)
///   - `gfx/texture.zig`   — image decode (PNG/JPG/BMP/TGA via stb_image) + texture handle pool + drawTexturePro
///   - `gfx/font.zig`      — embedded 8x8 bitmap font + drawText
///
/// Submodules are private file-system neighbours. The public surface
/// is consumed via `b.dependency("labelle_bgfx", ...).module("gfx")`
/// which still points at this file.
const std = @import("std");
const types = @import("gfx/types.zig");
const state = @import("gfx/state.zig");
const programs = @import("gfx/programs.zig");
const draw = @import("gfx/draw.zig");
const texture = @import("gfx/texture.zig");
const font = @import("gfx/font.zig");
const core = @import("labelle-core");

// Prove this façade satisfies the render contract at compile time — the formal
// gate (names every missing decl) replacing the old "satisfies Backend(Impl)"
// doc claim. Completes bgfx's contract trifecta alongside window.zig's
// `assertWindow` and input.zig's `assertInput` (#386 Phase 3).
comptime {
    core.assertBackend(@This());
}

// Contract-version tags (labelle-assembler#453 item 1). The assembler emits
// directional `@compileError` version asserts in the generated game's main.zig
// comparing these against labelle-core's `*_CONTRACT_VERSION` consts. v1 is the
// initial revision of each contract.
/// Draw contract (shape/sprite/camera primitives) revision this backend targets.
pub const targets_draw_contract: u32 = 1;
/// Loader contract (texture/image decode + upload) revision this backend targets.
pub const targets_loader_contract: u32 = 1;

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = types.Texture;
pub const Color = types.Color;
pub const Rectangle = types.Rectangle;
pub const Vector2 = types.Vector2;
pub const Camera2D = types.Camera2D;

// ── Color constants ────────────────────────────────────────────────────

pub const white = types.white;
pub const black = types.black;
pub const red = types.red;
pub const green = types.green;
pub const blue = types.blue;
pub const transparent = types.transparent;

pub const color = types.color;

// ── State / shader management ──────────────────────────────────────────

pub const setScreenSize = state.setScreenSize;
// Toggle aspect-fit off around `screen_fill` layers so backdrops stretch to
// the full framebuffer (no pillarbox stripes). Mirrors sokol/raylib.
pub const setApplyFit = state.setApplyFit;
// Physical↔design coordinate conversion for HiDPI input mapping. The
// camera's `framebufferToWorld` calls `screenToDesign` (guarded by
// `@hasDecl`) so mouse/touch in framebuffer pixels maps to design space.
pub const screenToDesign = state.screenToDesign;
pub const designToPhysical = state.designToPhysical;
pub const getDesignWidth = state.getDesignWidth;
pub const getDesignHeight = state.getDesignHeight;
pub const shutdownPrograms = programs.shutdownPrograms;
pub const areProgramsReady = programs.areProgramsReady;

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub const drawRectangleRec = draw.drawRectangleRec;
pub const drawCircle = draw.drawCircle;
pub const drawLine = draw.drawLine;
pub const drawTriangle = draw.drawTriangle;
pub const drawPolygon = draw.drawPolygon;

// ── Textured mesh primitive (drawMesh contract, labelle-gfx#290) ───────
// Scratch for repacking a Spine RenderCommand's separate position/uv/color
// arrays into the sprite pipeline's interleaved vertex. Sized to Spine's
// per-command batch cap (indices are u16, so a batch tops out below 65536
// vertices). A global (BSS) buffer keeps drawMesh allocation-free per frame.
const MAX_MESH_VERTS: usize = 65536;
var mesh_vertex_scratch: [MAX_MESH_VERTS]programs.PosTexColorVertex = undefined;

/// Optional textured-mesh primitive — the bgfx impl of labelle-core's `drawMesh`
/// contract (skeletal animation, labelle-gfx#290). REUSES the sprite pipeline
/// (`programs.submitMesh` → same `vertex_layout` + `sprite_program` +
/// `s_tex_uniform`); the only addition over the sprite path is a transient INDEX
/// buffer (Spine meshes are indexed) and per-command blend selection.
///
/// The buffers mirror Spine's `RenderCommand` (see the core contract doc):
///   - `positions`: xy pairs in screen space (caller applied center+scale).
///     `len == 2 * numVerts`. Converted to NDC via the sprite path's `toNdcX/Y`.
///   - `uvs`: normalised uv pairs, `len == 2 * numVerts`.
///   - `colors`: one packed RGBA8 per vertex, `len == numVerts`. Spine packs
///     ARGB (0xAARRGGBB); bgfx's `Color0` (Uint8×4) wants ABGR (0xAABBGGRR),
///     so R and B are swapped here.
///   - `indices`: u16 triangle list, `len == 3 * numTris`.
pub fn drawMesh(
    tex: Texture,
    positions: []const f32,
    uvs: []const f32,
    colors: []const u32,
    indices: []const u16,
    blend: core.BlendMode,
) void {
    const num_verts = colors.len;
    if (num_verts == 0 or indices.len == 0) return;
    if (num_verts > MAX_MESH_VERTS) return;
    if (positions.len < num_verts * 2 or uvs.len < num_verts * 2) return;

    const handle = texture.handleForId(tex.id);

    var i: usize = 0;
    while (i < num_verts) : (i += 1) {
        const argb = colors[i]; // Spine: 0xAARRGGBB
        // Swap R (bits 16..23) and B (bits 0..7) → bgfx 0xAABBGGRR.
        const abgr = (argb & 0xFF00FF00) |
            ((argb >> 16) & 0x000000FF) |
            ((argb & 0x000000FF) << 16);
        mesh_vertex_scratch[i] = .{
            .x = state.toNdcX(positions[i * 2 + 0]),
            .y = state.toNdcY(positions[i * 2 + 1]),
            .u = uvs[i * 2 + 0],
            .v = uvs[i * 2 + 1],
            .abgr = abgr,
        };
    }

    const blend_state: u64 = switch (blend) {
        .normal => programs.STATE_BLEND_PMA_NORMAL,
        .additive => programs.STATE_BLEND_PMA_ADD,
        .multiply => programs.STATE_BLEND_PMA_MULTIPLY,
        .screen => programs.STATE_BLEND_PMA_SCREEN,
    };

    programs.submitMesh(mesh_vertex_scratch[0..num_verts], indices, handle, blend_state);
}

// ── Texture / Sprite rendering ────────────────────────────────────────

pub const DecodedImage = texture.DecodedImage;
pub const loadTexture = texture.loadTexture;
pub const decodeImage = texture.decodeImage;
pub const uploadTexture = texture.uploadTexture;
pub const unloadTexture = texture.unloadTexture;
// Dynamic textures: create-blank + per-frame re-upload. The "display half" of
// in-engine video (#549) — a decoder feeds RGBA frames into `updateTexture`.
pub const createDynamicTexture = texture.createDynamicTexture;
pub const updateTexture = texture.updateTexture;
pub const drawTexturePro = texture.drawTexturePro;
// Material seam (labelle-gfx#305 Slice B). Optional `@hasDecl`-gated contract
// decls: `core.Backend(Impl).drawTextureProMaterial` dispatches here for a
// supported non-`none` effect, and `materialSupported` is the fine-grained gate.
// bgfx implements `flash` + `palette_swap`; other effects degrade to plain sprites.
pub const drawTextureProMaterial = texture.drawTextureProMaterial;
pub const materialSupported = texture.materialSupported;
// GPU-compressed (ASTC) upload — the labelle-gfx `loadTextureFromMemory` seam
// dispatches to these via `@hasDecl` when the blob is compressed (#341).
pub const isCompressed = texture.isCompressed;
pub const uploadCompressed = texture.uploadCompressed;
// Header-only dims for the async asset-catalog adapter (engine#450), which
// splits worker-thread decode from main-thread upload and so can't use the
// synchronous seam — it reads dims here to set DecodedImage before upload.
pub const compressedDims = texture.compressedDims;

// ── Offscreen render targets (labelle-bgfx#36 + transport mirror) ──────
// Render the scene into a texture instead of the screen. Two features build on
// this: the headless offscreen capture (#36, via `window.initHeadless`) and the
// transport mirror. `beginRenderTarget`/`endRenderTarget` retarget every draw
// primitive at a target (the SAME rect/sprite/text calls fill a texture), and
// `drawRenderTarget` composites a finished target back into the current view —
// the mirror.
//
// The public handle is an opaque `u32` id — like a texture handle — never the
// backend struct, so the labelle-gfx/labelle-engine optional-capability seam can
// forward it across the module boundary. `createRenderTarget` returns
// `INVALID_RENDER_TARGET` (0) on failure; every op no-ops on an unknown id.
const render_target = @import("gfx/render_target.zig");
pub const RenderTargetId = u32;
pub const INVALID_RENDER_TARGET = render_target.INVALID_ID;
pub const createRenderTarget = render_target.createId; // (w, h: u16) -> u32
pub const beginRenderTarget = render_target.beginId; // (id: u32)
pub const endRenderTarget = render_target.end; // ()
pub const drawRenderTarget = render_target.drawId; // (id: u32, dest, tint)
pub const destroyRenderTarget = render_target.destroyId; // (id: u32)
// Free + forget all pooled targets before a context teardown (window close /
// Android surface loss) — called by window.teardownSurface. Not for game code.
pub const resetRenderTargets = render_target.reset;

// Post-fx seam (labelle-gfx#305 P2 Slice B). Optional `@hasDecl`-gated contract
// decls on top of the render-target sub-surface: `core.Backend(Impl).applyPostPass`
// renders one full-screen pass (`src`→`dst`) driven by the gfx ping-pong, and
// `postPassSupported` is the fine-grained gate. bgfx implements all four built-in
// passes (bloom / vignette / color_grade / crt).
pub const applyPostPass = render_target.applyPostPass;
pub const postPassSupported = render_target.postPassSupported;
// Reset the per-frame transient post-fx view cursor (labelle-gfx#305). Called
// from `window.beginFrame` at frame start so the transient view band the post-fx
// passes submit into is reused each frame and never exhausts. Zero-cost (a single
// store) and a no-op semantically on frames with no post-fx.
pub const resetPostFxFrame = render_target.resetPostFxFrame;

// ── Per-camera viewport views (N-camera split-screen, labelle-bgfx#51) ──
// The window contract's `setViewport`/`clearViewport` route here: each
// per-camera viewport pass of a frame gets its OWN transient bgfx view
// (rect + scissor), so N active cameras render their screen rects
// simultaneously instead of sharing one view where the last rect won.
// `resetCameraFrame` is called from `window.beginFrame`;
// `setCameraPassFramebuffer` lets `window.initHeadless` retarget the band at
// its offscreen capture framebuffer (INVALID handle = backbuffer default).

/// Apply a per-camera screen viewport authored in DESIGN pixels (the engine's
/// `Camera.viewport` space, #51). Two coupled effects:
///   1. NDC basis: `state.beginViewport` makes the camera's projection fill
///      this viewport (its centre → the middle of the sub-rect) instead of the
///      full design canvas — the split-screen placement fix.
///   2. bgfx view: the design rect is mapped to its PHYSICAL sub-rect
///      (`designViewportToPhysical`, HiDPI + letterbox aware) and routed to a
///      dedicated camera-segment view (rect + scissor), so N cameras compose
///      simultaneously.
///
/// Whole-frame post-fx (v1, DECISION for review #2): while a render-target pass
/// is open (post-fx scene capture / mirror) this is a NO-OP — per-camera
/// viewports COLLAPSE to whole-frame. The scene renders into the design-sized
/// RT with the full-canvas NDC basis (a single fullscreen camera composes
/// correctly; the common post-fx case), and post-fx processes the whole RT.
/// This is coherent + correct for the documented v1: we neither mis-map a
/// physical rect into the RT's design space (review #1) nor reuse one RT view
/// across N camera segments (review #2). Per-camera post-fx is a follow-up.
///
/// Degenerate rect (non-positive w/h, review #3 + r3): a zero-area viewport
/// must output ZERO — it is routed to a dedicated EMPTY-clipped band segment
/// (`applyCameraViewportEmpty`), NOT a full-window fallback (which would draw
/// the degenerate camera over the whole window — the wrong semantic). The NDC
/// basis is reset (no meaningful basis for an empty viewport), and because the
/// draws land in their own clipped view they cannot leak into the previous
/// camera's segment either.
pub fn applyCameraViewport(x: i32, y: i32, w: i32, h: i32) void {
    if (render_target.renderTargetActive()) return; // whole-frame post-fx (v1)
    if (w <= 0 or h <= 0) {
        state.endViewport();
        const fb = physicalFramebuffer();
        render_target.applyCameraViewportEmpty(fb[0], fb[1]);
        return;
    }
    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    state.beginViewport(wf, hf);
    const r = state.designViewportToPhysical(xf, yf, wf, hf);
    render_target.applyCameraViewport(r[0], r[1], r[2], r[3]);
}

/// The current physical framebuffer size (fed each frame via `setScreenSize`)
/// clamped to the u16 bgfx rects use: `@max(0, …)` floors negatives, and
/// `std.math.cast` returns null on overflow, clamped to maxInt.
fn physicalFramebuffer() [2]u16 {
    return .{
        std.math.cast(u16, @max(0, state.physicalWidth())) orelse std.math.maxInt(u16),
        std.math.cast(u16, @max(0, state.physicalHeight())) orelse std.math.maxInt(u16),
    };
}

/// Restore full-window rendering (`full_w`×`full_h` PHYSICAL framebuffer px) —
/// clears the viewport NDC basis (pinned/UI draws return to the full design
/// canvas + letterbox) and opens a full-window camera segment (or, before the
/// band engaged this frame, keeps the legacy primary-view path). No-op mid
/// render-target pass (whole-frame post-fx v1 — see `applyCameraViewport`).
pub fn clearCameraViewport(full_w: u16, full_h: u16) void {
    if (render_target.renderTargetActive()) return; // whole-frame post-fx (v1)
    state.endViewport();
    render_target.clearCameraViewport(full_w, full_h);
}

pub const resetCameraFrame = resetCameraFrameImpl;
fn resetCameraFrameImpl() void {
    state.endViewport();
    render_target.resetCameraFrame();
}
pub const setCameraPassFramebuffer = render_target.setCameraPassFramebuffer;

// ── OPTIONAL viewport hooks the gfx renderer probes on the DRAW backend ──
// The gfx renderer's per-camera `applyViewport` calls `@hasDecl(BackendImpl,
// "setViewport")` / `clearViewport` on ITS BackendImpl — which is THIS gfx
// module (the draw backend, `core.assertBackend(@This())` above), the same
// shape as `core.mock_backend`. (#50 mistakenly put them on the window module,
// where the renderer never saw them, so per-camera viewports never engaged on
// any backend.) `setViewport` takes DESIGN pixels (the engine's
// `Camera.viewport` space); `clearViewport` restores the full physical
// framebuffer, whose size is the per-frame `setScreenSize` value.

/// Scope subsequent draws to a per-camera screen viewport (design px) — see
/// `applyCameraViewport`. The bgfx impl of the renderer's optional
/// `setViewport` hook, enabling N-camera split-screen (#51).
pub fn setViewport(x: i32, y: i32, w: i32, h: i32) void {
    applyCameraViewport(x, y, w, h);
}

/// Restore full-window rendering — the renderer's optional `clearViewport`
/// hook. Uses the current physical framebuffer size (fed each frame via
/// `setScreenSize`).
pub fn clearViewport() void {
    const fb = physicalFramebuffer();
    clearCameraViewport(fb[0], fb[1]);
}
// Re-export the post-fx value types so consumers (and the golden harness) can
// build a `PostPass` without importing labelle-core directly.
pub const PostPass = core.backend_contract.PostPass;
pub const PostPassKind = core.backend_contract.PostPassKind;
pub const PostPassUniforms = core.backend_contract.PostPassUniforms;

// ── In-engine video (#549 Path A) ──────────────────────────────────────
// VideoPlayer wires a decoder → dynamic texture → drawTexturePro. Generic over
// the decoder so the same player drives ffmpeg (desktop) or AMediaCodec
// (Android). The Android decoder is hardware-verified (see video/apk/).
// Video decode is a desktop/Android-only feature: the desktop decoder shells out
// to ffmpeg and the CPU YUV path uses `std.Thread.spawn`, neither of which is
// available (or wanted) on wasm32-emscripten (single-threaded WebGL, no
// subprocesses). Gate the whole video surface off wasm so its `std.Thread` /
// libc-process references are not analyzed for the browser target — WebGL video
// is out of scope for the bgfx-wasm milestone (#8).
const is_wasm = @import("builtin").target.cpu.arch.isWasm();
pub const VideoPlayer = if (is_wasm) struct {} else @import("video/player.zig").Player;
pub const DesktopVideoDecoder = if (is_wasm) struct {} else @import("video/desktop.zig").VideoDecoder;
pub const AndroidVideoDecoder = if (is_wasm) struct {} else @import("video/android.zig").VideoDecoder;
// VideoBackend satisfies core.VideoInterface: a name → player handle pool the
// assembler wires into the engine's VideoImpl slot, so a game plays a clip with
// just its asset name (#549).
pub const VideoBackend = if (is_wasm) struct {} else @import("video/backend.zig").VideoBackend;

// ── Text rendering ─────────────────────────────────────────────────────

pub const drawText = font.drawText;

// ── Utility functions (Backend contract) ──────────────────────────────

pub const beginMode2D = state.beginMode2D;
pub const endMode2D = state.endMode2D;
pub const getScreenWidth = state.getScreenWidth;
pub const getScreenHeight = state.getScreenHeight;
pub const setDesignSize = state.setDesignSize;
pub const screenToWorld = state.screenToWorld;
pub const worldToScreen = state.worldToScreen;

// ── Tests ─────────────────────────────────────────────────────────────
// drawMesh (labelle-gfx#290) touches bgfx transient buffers + submit, which
// need a live device (GPU/window) — not available headless — so its runtime
// behaviour is exercised on-device. What we CAN pin without a device is the
// compile-time conformance: that this façade actually declares the optional
// `drawMesh` capability with the exact signature core's `assertBackend` /
// conformance suite dispatch on. `core.assertBackend(@This())` already runs at
// struct scope (top of file); this test makes the drawMesh contract explicit
// and fails loudly if the decl is dropped or its signature drifts.
test "drawMesh satisfies the optional textured-mesh capability" {
    comptime {
        if (!@hasDecl(@This(), "drawMesh")) {
            @compileError("bgfx backend must declare the optional drawMesh primitive (labelle-gfx#290)");
        }
        // Signature must match core's BlendMode-terminated drawMesh contract so
        // the assembler's `Backend(Impl).drawMesh` wrapper can forward to it.
        const Fn = @TypeOf(drawMesh);
        const info = @typeInfo(Fn).@"fn";
        const params = info.params;
        if (params.len != 6) @compileError("drawMesh must take 6 params");
        if (params[5].type.? != core.BlendMode) {
            @compileError("drawMesh's last param must be core.BlendMode");
        }
    }
}
