//! Offscreen render targets for the bgfx backend — the shared basis of two
//! features that both need "render the scene into a texture instead of the
//! screen":
//!
//!   * Headless offscreen capture (labelle-bgfx#36): render the whole frame into
//!     a texture with NO window and no display server, then read it back (see
//!     `window.initHeadless`). Proven viable by `src/headless_probe.zig`.
//!   * The transport mirror: render a scene (e.g. the player) into a texture and
//!     sample it back onto the screen somewhere else.
//!
//! A `RenderTarget` wraps a bgfx framebuffer (one RGBA8 color attachment) bound
//! to its own bgfx view. `begin`/`end` retarget every draw primitive
//! (`gfx.drawRectangleRec`, sprites, text, meshes …) at that framebuffer by
//! flipping `programs`' active view — so the SAME draw code fills a texture
//! instead of the screen. `draw` composites a finished target back into the
//! current view (the mirror).
//!
//! View ordering: render-target views are drawn BEFORE the primary view (see
//! `sequenceViews`) so a target that feeds the screen — a mirror — is resolved
//! in the same frame it is displayed, not one frame stale.

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const core = @import("labelle-core");
const programs = @import("programs.zig");
const texture = @import("texture.zig");
const types = @import("types.zig");

const PostPass = core.backend_contract.PostPass;
const PostPassKind = core.backend_contract.PostPassKind;
/// Opaque render-target handle shape (matches the contract + `gfx.RenderTargetId`).
const RenderTargetId = core.backend_contract.RenderTargetId;

const INVALID: u16 = std.math.maxInt(u16);

/// Fresh targets clear to transparent black, so an unwritten mirror texel
/// composites as nothing rather than an opaque block.
const DEFAULT_CLEAR: u32 = 0x00000000;

/// A handle to an offscreen framebuffer + its sampleable color texture.
pub const RenderTarget = struct {
    fb: bgfx.FrameBufferHandle,
    /// The framebuffer's color attachment — sample it (mirror) or read it back (#36).
    color: bgfx.TextureHandle,
    /// The bgfx view whose draws land in `fb` (allocated 1..MAX_VIEW).
    view: u16,
    width: u16,
    height: u16,

    pub fn isValid(self: RenderTarget) bool {
        return self.fb.idx != INVALID;
    }
};

fn invalidTarget() RenderTarget {
    return invalid_rt;
}

/// bgfx's default cap is 256 views. View 0 is the primary (`programs.PRIMARY_VIEW`);
/// persistent render targets take ids 1..RT_VIEW_MAX. Occupancy is tracked so ids
/// RECYCLE on `destroy` — the cap is CONCURRENT, not lifetime, so a game that
/// churns targets across level loads / resizes never permanently exhausts it.
const MAX_VIEW: u16 = 255;

/// The TOP of the view range is reserved for PER-FRAME TRANSIENT post-fx views
/// (`allocPostFxView`). A post-fx pass submits into a transient view whose id
/// increases with pass order, so bgfx's ascending-view-id execution == the
/// driver's SUBMISSION order regardless of which physical target is the pass's
/// `dst`. This is the fix for labelle-gfx#305: the gfx `PostFxDriver`'s two-buffer
/// ping-pong (scene→a, bloom a→b, crt b→a) mis-orders on an EVEN stack when a
/// pass's submit view id is tied to its dst's IDENTITY (crt writes `a`, the LOWER
/// id, so bgfx runs it before bloom writes `b`). Decoupling the submit view id
/// from dst identity — a monotonic transient band — makes v1.28.0's efficient
/// 2-buffer model correct on bgfx with NO driver change.
const POSTFX_VIEW_BASE: u16 = 224;
/// PER-FRAME TRANSIENT CAMERA-SEGMENT views (labelle-bgfx#51): the band right
/// below the post-fx band. Each per-camera viewport pass of a frame (a
/// `setViewport` scope from the gfx renderer's layer×camera loop) submits into
/// its own view here, so N cameras render their own screen rects SIMULTANEOUSLY
/// — with a single shared view, the last camera's rect won. See the
/// "Per-camera viewport views" section below.
const CAMERA_VIEW_BASE: u16 = 192;
const CAMERA_VIEW_MAX: u16 = POSTFX_VIEW_BASE - 1; // 32 segment views per frame
/// Persistent render-target views live BELOW the camera band.
const RT_VIEW_MAX: u16 = CAMERA_VIEW_BASE - 1; // 191 concurrent RTs — ample
var view_in_use = [_]bool{false} ** (MAX_VIEW + 1);

/// First free render-target view id (1..RT_VIEW_MAX), or null when all are taken.
/// Never returns `PRIMARY_VIEW` (0) or a post-fx-band id. Split out so the
/// bookkeeping is unit-testable without a live bgfx device.
fn allocView() ?u16 {
    var id: u16 = 1;
    while (id <= RT_VIEW_MAX) : (id += 1) {
        if (!view_in_use[id]) return id;
    }
    return null;
}

/// Per-frame cursor for transient post-fx view ids (POSTFX_VIEW_BASE..MAX_VIEW).
/// Reset every frame by `resetPostFxFrame` (called from `window.beginFrame`) so
/// the small band is reused frame-to-frame and never exhausts across frames.
var postfx_next_view: u16 = POSTFX_VIEW_BASE;

/// Reset the transient post-fx view cursor to the base of the band. Called once
/// per frame at frame start; zero-cost (a single store) and harmless on frames
/// with no post-fx. Keeping the reset at the frame boundary — not inside the
/// pass chain — is what bounds the band to `#passes` ids per frame.
pub fn resetPostFxFrame() void {
    postfx_next_view = POSTFX_VIEW_BASE;
}

/// Hand out the next transient post-fx view id for THIS frame. Monotonic within a
/// frame (so submit order == bgfx execution order), reset each frame. Clamps at
/// the top of the band: an absurdly long stack (> band size) reuses the last id
/// (a degraded pixel, never an out-of-range view or an RT-band collision) rather
/// than wrapping into the persistent RT range.
fn allocPostFxView() u16 {
    const v = postfx_next_view;
    if (postfx_next_view < MAX_VIEW) postfx_next_view += 1;
    return v;
}

// ── Per-camera viewport views (N-camera split-screen, labelle-bgfx#51) ──
// bgfx view state (rect/scissor) is PER-VIEW, not per-draw, and a view's rect
// is whatever was set LAST when the frame executes. All gfx draws used to share
// the primary view, so with N active cameras (the gfx renderer's layer-outer /
// camera-inner loop calling `setViewport` once per camera pass) only the LAST
// camera's rect survived — every camera's sprites rendered into one rect.
//
// Fix: each viewport SEGMENT of a frame — a maximal run of draws under one
// `setViewport` rect (or one full-window `clearViewport` stretch after the
// band is engaged) — gets its OWN transient view from this band, carrying its
// own rect + scissor. Segments are handed out monotonically, so bgfx's
// ascending-id execution == submission order and the frame composites exactly
// as the renderer emitted it (world halves, then pinned UI on top, then imgui).
// Consecutive requests with the SAME state collapse into the current segment,
// so a single-camera letterboxed frame costs exactly one band view.
//
// The band engages LAZILY: until the first real `applyCameraViewport` of a
// frame, `clearCameraViewport` keeps the legacy behaviour (rect + scissor-off
// on the PRIMARY view) — a game with no authored viewports (every golden/probe)
// takes the primary-only path, byte-identical to the pre-#51 renderer.
//
// Ordering vs the other bands: with no live render target bgfx's default
// ascending order runs PRIMARY (0, the frame clear) first, then the camera
// band — clear first, segments over it, correct. With live targets
// `sequenceViews` pins the same relative order explicitly (scene RT views →
// post-fx band → primary → camera band).
//
// Post-fx interaction (v1, documented): when a render-target pass is open
// (`stack_depth > 0` — the post-fx driver renders the whole scene into its
// ping-pong target) the band is NOT engaged; a viewport request scopes the
// ACTIVE RT view's rect + scissor instead. Post-fx therefore stays WHOLE-FRAME:
// a single camera's viewport composes correctly under post-fx, while N-camera
// split-screen under an active post-fx stack keeps the pre-#51 last-rect-wins
// degradation (per-camera band views bound to the RT framebuffer — and
// re-ordering them before the post-fx band — is the deliberate follow-up).

/// Per-frame cursor for transient camera-segment views. Reset each frame by
/// `resetCameraFrame` (called from `window.beginFrame`).
var camera_next_view: u16 = CAMERA_VIEW_BASE;
/// Whether any real viewport rect engaged the band THIS frame. Until then the
/// full-window path stays on the primary view (legacy, golden-identical).
var camera_band_engaged: bool = false;
/// The current segment's state, for collapsing identical consecutive requests:
/// rect (x, y, w, h) and whether it is scissored (false = full-window segment).
var camera_seg_rect: [4]u16 = .{ 0, 0, 0, 0 };
var camera_seg_scissored: bool = false;
/// Warn once per process when a frame overflows the 32-segment band (the
/// overflow segments share the last view — degraded rects, never a crash).
var camera_band_overflow_warned: bool = false;

/// The framebuffer camera-segment views render into: INVALID = the backbuffer
/// (the windowed default). `window.initHeadless` points this at its offscreen
/// capture framebuffer so a surfaceless run composites camera segments into
/// the SAME image the capture reads back; cleared on teardown.
var camera_primary_fb: bgfx.FrameBufferHandle = .{ .idx = INVALID };

/// Point the camera band (and nothing else) at `fb` instead of the backbuffer.
/// Pass an INVALID handle to restore the backbuffer default.
pub fn setCameraPassFramebuffer(fb: bgfx.FrameBufferHandle) void {
    camera_primary_fb = fb;
}

/// Reset the per-frame camera-segment cursor and drop back to the primary view.
/// Called once per frame from `window.beginFrame` (alongside `resetPostFxFrame`)
/// so the band is reused frame-to-frame; also restores the active view when the
/// previous frame ended inside a band segment (e.g. imgui drew into the last
/// full-window segment).
pub fn resetCameraFrame() void {
    if (camera_band_engaged and programs.activeView() >= CAMERA_VIEW_BASE and
        programs.activeView() <= CAMERA_VIEW_MAX)
    {
        programs.setActiveView(programs.PRIMARY_VIEW);
    }
    camera_next_view = CAMERA_VIEW_BASE;
    camera_band_engaged = false;
    camera_seg_scissored = false;
    camera_seg_rect = .{ 0, 0, 0, 0 };
}

/// Hand out the next transient camera-segment view id for THIS frame.
/// Monotonic within a frame (submit order == bgfx execution order); clamps at
/// the band top — an absurd segment count reuses the last id (degraded rects
/// for the overflow, never an out-of-band view id).
fn nextCameraView() u16 {
    const v = camera_next_view;
    if (camera_next_view < CAMERA_VIEW_MAX) {
        camera_next_view += 1;
    } else if (!camera_band_overflow_warned) {
        camera_band_overflow_warned = true;
        std.log.warn(
            "bgfx: >{d} viewport segments in one frame — overflow segments share the last view (labelle-bgfx#51)",
            .{CAMERA_VIEW_MAX - CAMERA_VIEW_BASE + 1},
        );
    }
    return v;
}

/// Open (or reuse) a band segment with the given rect/scissor state and route
/// subsequent draws at it. Shared tail of `applyCameraViewport` /
/// `clearCameraViewport`; `scissored` selects rect-scissor vs scissor-off.
fn openCameraSegment(x: u16, y: u16, w: u16, h: u16, scissored: bool) void {
    if (camera_band_engaged and camera_seg_scissored == scissored and
        camera_seg_rect[0] == x and camera_seg_rect[1] == y and
        camera_seg_rect[2] == w and camera_seg_rect[3] == h)
    {
        return; // identical consecutive request — stay in the current segment
    }
    const v = nextCameraView();
    // Segments composite over the primary's frame clear — never clear here.
    bgfx.setViewFrameBuffer(v, camera_primary_fb);
    bgfx.setViewClear(v, bgfx.ClearFlags_None, 0, 1.0, 0);
    bgfx.setViewRect(v, x, y, w, h);
    if (scissored) {
        bgfx.setViewScissor(v, x, y, w, h);
    } else {
        bgfx.setViewScissor(v, 0, 0, 0, 0); // bgfx's "scissor off" sentinel
    }
    programs.setActiveView(v);
    camera_band_engaged = true;
    camera_seg_scissored = scissored;
    camera_seg_rect = .{ x, y, w, h };
}

/// Apply a per-camera screen viewport (the backend half of the gfx renderer's
/// `applyViewport`, labelle-bgfx#51). Routes subsequent draws into a band
/// segment carrying this rect + scissor, so each camera of a split-screen frame
/// renders into its own screen region simultaneously.
///
/// Inside an open render-target pass (post-fx scene capture / mirror) the band
/// is not engaged; the rect + scissor scope the ACTIVE RT view instead — see
/// the section comment (post-fx stays whole-frame in v1).
pub fn applyCameraViewport(x: u16, y: u16, w: u16, h: u16) void {
    if (stack_depth > 0) {
        const v = programs.activeView();
        bgfx.setViewRect(v, x, y, w, h);
        bgfx.setViewScissor(v, x, y, w, h);
        return;
    }
    openCameraSegment(x, y, w, h, true);
}

/// Restore full-window rendering (`full_w`×`full_h` = the framebuffer size) —
/// the backend half of the gfx renderer's `clearViewport`. Before any camera
/// rect engaged the band this frame, this keeps the LEGACY primary-view path
/// (rect + scissor-off on view 0) so viewport-less games are byte-identical to
/// the pre-#51 renderer; after engagement it opens a full-window band segment
/// so pinned/UI passes keep executing in submission order over the camera rects.
pub fn clearCameraViewport(full_w: u16, full_h: u16) void {
    if (stack_depth > 0) {
        // Restore the active RT view to its full rect, scissor off.
        const v = programs.activeView();
        if (v >= 1 and v <= RT_VIEW_MAX and targets[v].isValid()) {
            bgfx.setViewRect(v, 0, 0, targets[v].width, targets[v].height);
        } else {
            bgfx.setViewRect(v, 0, 0, full_w, full_h);
        }
        bgfx.setViewScissor(v, 0, 0, 0, 0);
        return;
    }
    if (!camera_band_engaged) {
        bgfx.setViewRect(programs.PRIMARY_VIEW, 0, 0, full_w, full_h);
        bgfx.setViewScissor(programs.PRIMARY_VIEW, 0, 0, 0, 0);
        return;
    }
    openCameraSegment(0, 0, full_w, full_h, false);
}

/// Create an offscreen render target sized `w`×`h`. Returns an INVALID target
/// (`.isValid() == false`) when the view budget is exhausted, the size is zero,
/// or bgfx fails to allocate the framebuffer — callers must check before use.
/// The color attachment is created sampleable (implicit `BGFX_TEXTURE_RT`) and
/// clamped, so it composites back cleanly with `draw` (no edge wrap on a mirror).
pub fn create(w: u16, h: u16) RenderTarget {
    if (w == 0 or h == 0) {
        std.log.warn("bgfx: render target needs positive dimensions (got {d}x{d})", .{ w, h });
        return invalidTarget();
    }
    const view = allocView() orelse {
        std.log.warn("bgfx: render-target view budget exhausted (>{d} live) — offscreen/mirror create failed", .{MAX_VIEW});
        return invalidTarget();
    };

    // `createFrameBuffer` implies BGFX_TEXTURE_RT; add clamp so sampling a
    // mirror's edge doesn't wrap. Filtering stays at bgfx's default (bilinear).
    const flags: u64 = bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp;
    const fb = bgfx.createFrameBuffer(w, h, .RGBA8, flags);
    if (fb.idx == INVALID) {
        // Leave the view free (no leak) and say why — a mirror silently going
        // blank is otherwise painful to diagnose.
        std.log.warn("bgfx: render-target framebuffer creation failed ({d}x{d})", .{ w, h });
        return invalidTarget();
    }

    view_in_use[view] = true;

    bgfx.setViewFrameBuffer(view, fb);
    bgfx.setViewRect(view, 0, 0, w, h);
    bgfx.setViewClear(view, bgfx.ClearFlags_Color | bgfx.ClearFlags_Depth, DEFAULT_CLEAR, 1.0, 0);
    // A new target extends the view range, so re-assert "primary composites
    // last". No-op-cheap and keeps mirror ordering correct as targets appear.
    sequenceViews();

    return .{
        .fb = fb,
        .color = bgfx.getTexture(fb, 0),
        .view = view,
        .width = w,
        .height = h,
    };
}

/// Free a render target's GPU resources and invalidate the handle. Because
/// `createFrameBuffer` owns its color texture, destroying the framebuffer frees
/// the texture too. The view's framebuffer binding is cleared first so a stale
/// view id can never draw into freed memory.
pub fn destroy(rt: *RenderTarget) void {
    if (!rt.isValid()) return;
    bgfx.setViewFrameBuffer(rt.view, .{ .idx = INVALID });
    bgfx.destroyFrameBuffer(rt.fb);
    if (rt.view <= MAX_VIEW) view_in_use[rt.view] = false; // recycle the id
    // Re-sequence so the freed view drops out of the "render targets before
    // primary" order (harmless if it was the last one — becomes the default).
    sequenceViews();
    rt.fb = .{ .idx = INVALID };
    rt.color = .{ .idx = INVALID };
    rt.view = INVALID;
}

/// Saved active views for nested `begin`/`end` (a target rendered while another
/// is already active). Fixed shallow depth — offscreen passes don't nest deeply.
var view_stack: [8]u16 = undefined;
/// Count of open `begin`s. Incremented on EVERY `begin` (even past the stack
/// capacity) so `begin`/`end` always balance: the saved view is only stored for
/// the first `view_stack.len` levels; deeper levels restore to the primary
/// (acceptable degradation for absurd nesting) but never desync the counter.
var stack_depth: usize = 0;

/// Point every subsequent draw at `rt`'s framebuffer. Balance with `end`.
/// `touch` guarantees bgfx clears/processes the view even if the pass submits no
/// draws — the same reason `window.beginFrame` touches the primary view.
pub fn begin(rt: RenderTarget) void {
    if (!rt.isValid()) return;
    if (stack_depth < view_stack.len) view_stack[stack_depth] = programs.activeView();
    stack_depth += 1; // always, so `end` stays balanced even past capacity
    programs.setActiveView(rt.view);
    bgfx.touch(rt.view);
}

/// Restore the draw target to whatever was active before the matching `begin`
/// (the primary view, or an enclosing target). Safe to call unbalanced — with no
/// open `begin` it falls back to the primary view.
pub fn end() void {
    if (stack_depth == 0) {
        programs.setActiveView(programs.PRIMARY_VIEW);
        return;
    }
    stack_depth -= 1;
    const restore: u16 = if (stack_depth < view_stack.len)
        view_stack[stack_depth]
    else
        programs.PRIMARY_VIEW; // beyond the saved depth — best-effort
    programs.setActiveView(restore);
}

/// Composite a finished render target into the CURRENT view (call this OUTSIDE
/// the target's own `begin`/`end`) at `dest`, modulated by `tint` — the mirror.
///
/// Handles the backend Y convention: OpenGL render-target textures are
/// bottom-left origin, so the source is v-flipped there (via `buildQuadVertices`'
/// negative-height flip convention) to keep the mirrored image upright. Vulkan /
/// Metal / D3D are top-left origin and sample straight.
pub fn draw(rt: RenderTarget, dest: types.Rectangle, tint: types.Color) void {
    if (!rt.isValid()) return;

    const caps = bgfx.getCaps();
    const flip = caps != null and caps.*.originBottomLeft;
    const w_f: f32 = @floatFromInt(rt.width);
    const h_f: f32 = @floatFromInt(rt.height);
    const source: types.Rectangle = .{
        .x = 0,
        .y = 0,
        .width = w_f,
        .height = if (flip) -h_f else h_f, // negative height ⇒ flip_y
    };
    texture.drawExternalTexture(rt.color, rt.width, rt.height, source, dest, .{ .x = 0, .y = 0 }, 0, tint);
}

// ── Opaque u32-handle API (engine / game facing) ───────────────────────
// The engine and game code only ever see a `u32` id — never the `RenderTarget`
// struct or any bgfx handle — exactly like a texture handle (`texture_id`). This
// is what the labelle-gfx/labelle-engine optional-capability seam forwards to.
//
// The id IS the target's bgfx view (1..MAX_VIEW). View 0 is the primary, so it
// can never be a target — which makes `0` a natural INVALID sentinel.

/// Returned by `createId` on failure; never a valid target id.
pub const INVALID_ID: u32 = 0;

/// id → live target, indexed by the target's view id. Initialised to invalid so
/// a stale/never-allocated id is rejected by `validId` without reading garbage.
const invalid_rt: RenderTarget = .{ .fb = .{ .idx = INVALID }, .color = .{ .idx = INVALID }, .view = INVALID, .width = 0, .height = 0 };
var targets: [MAX_VIEW + 1]RenderTarget = [_]RenderTarget{invalid_rt} ** (MAX_VIEW + 1);

fn validId(id: u32) bool {
    return id >= 1 and id <= MAX_VIEW and targets[id].isValid() and targets[id].view == id;
}

/// Create an offscreen target `w`×`h`, returning an opaque id, or `INVALID_ID`
/// on failure (view budget exhausted / bad size / framebuffer failure — each
/// logged by `create`). The engine hands this id straight back to `beginId` /
/// `drawId` / `destroyId`.
pub fn createId(w: u16, h: u16) u32 {
    const rt = create(w, h);
    if (!rt.isValid()) return INVALID_ID;
    targets[rt.view] = rt;
    return rt.view;
}

/// Point subsequent draws at target `id` (no-op on an unknown id). Balance with
/// `end` — the same `end` the struct API uses, since the active-view stack is
/// shared.
pub fn beginId(id: u32) void {
    if (!validId(id)) return;
    begin(targets[id]);
}

/// Composite finished target `id` into the current view at `dest` (the mirror).
pub fn drawId(id: u32, dest: types.Rectangle, tint: types.Color) void {
    if (!validId(id)) return;
    draw(targets[id], dest, tint);
}

/// Free target `id` and invalidate it (no-op on an unknown id). The id (its view)
/// recycles for a future `createId`.
pub fn destroyId(id: u32) void {
    if (!validId(id)) return;
    destroy(&targets[id]);
}

/// Free + forget EVERY pooled render target. Called from the window teardown
/// path (`window.teardownSurface`) BEFORE `bgfx.shutdown`, on both clean shutdown
/// and Android surface loss (`APP_CMD_TERM_WINDOW`, where engine state survives a
/// context teardown). Two jobs:
///   1. destroy the framebuffers while the context is still alive, so bgfx
///      doesn't report them as leaks (#384); and
///   2. invalidate the pool + view occupancy, so no stale id survives as
///      `validId` into a RESTORED context — otherwise a resumed game could
///      `beginRenderTarget`/`drawRenderTarget` with handles from the dead context.
pub fn reset() void {
    var id: u16 = 1;
    while (id <= RT_VIEW_MAX) : (id += 1) {
        if (view_in_use[id] and targets[id].fb.idx != INVALID) {
            bgfx.setViewFrameBuffer(id, .{ .idx = INVALID });
            bgfx.destroyFrameBuffer(targets[id].fb);
        }
        view_in_use[id] = false;
        targets[id] = invalid_rt;
    }
    // Unbind the transient post-fx band too: `applyPostPass` binds a destroyed
    // target's framebuffer to a band view for a single submit, and though a band
    // view never draws until rebound, dropping the binding here keeps no stale
    // framebuffer handle referenced into a torn-down (Android surface-loss) context.
    id = POSTFX_VIEW_BASE;
    while (id <= MAX_VIEW) : (id += 1) {
        bgfx.setViewFrameBuffer(id, .{ .idx = INVALID });
    }
    postfx_next_view = POSTFX_VIEW_BASE;
    // And the camera band (#51): drop any headless-capture framebuffer binding
    // (`setCameraPassFramebuffer`) so no stale handle survives into a restored
    // context, and reset the per-frame segment state.
    id = CAMERA_VIEW_BASE;
    while (id <= CAMERA_VIEW_MAX) : (id += 1) {
        bgfx.setViewFrameBuffer(id, .{ .idx = INVALID });
    }
    camera_primary_fb = .{ .idx = INVALID };
    resetCameraFrame();
}

// ── Post-fx sub-surface (full-screen pass stack, labelle-gfx#305 P2 Slice B) ──
// The backend half of the post-fx seam: `applyPostPass` renders ONE full-screen
// pass reading render target `src` and writing render target `dst`; the gfx
// `PostFxDriver` (RFC §2.4) allocates the two ping-pong targets (via the opaque
// `createId` above) and sequences the src→dst hops. `postPassSupported` advertises
// which curated passes bgfx implements — all four, here. Both are optional,
// `@hasDecl`-gated contract decls; forwarded out through `gfx.zig`.

/// Which curated post-fx passes this bgfx backend implements (labelle-gfx#305).
/// bgfx does all four built-ins (fs_bloom / fs_vignette / fs_color_grade /
/// fs_crt). The gfx driver consults this before every pass; a `false` here would
/// make the driver skip that pass (warn-once) and run the rest.
pub fn postPassSupported(kind: PostPassKind) bool {
    return switch (kind) {
        .bloom, .vignette, .color_grade, .crt => true,
    };
}

/// Apply ONE full-screen post-fx pass: sample render target `src`, write render
/// target `dst`, under `pass`. No-ops on an unknown/identical id pair (the driver
/// never passes those, but a stale id must not scribble). `color_grade` with a
/// zero/dead LUT handle degrades to a straight `src`→`dst` blit (RFC §3) so the
/// ping-pong chain stays contiguous — never a black frame.
///
/// Ordering (labelle-gfx#305 fix): the pass does NOT submit into `dst`'s OWN view
/// (whose id is tied to `dst`'s identity — the source of the ping-pong mis-order
/// on an even stack). It submits into a fresh MONOTONIC transient post-fx view
/// (`allocPostFxView`) bound to `dst`'s framebuffer for this submit. bgfx executes
/// views in ascending id order and `sequenceViews` sorts the whole post-fx band
/// AFTER the scene's RT views and BEFORE the primary, so submit order == execution
/// order and every pass reads a target only after the earlier pass has written it.
pub fn applyPostPass(pass: PostPass, src: RenderTargetId, dst: RenderTargetId) void {
    if (!validId(src) or !validId(dst) or src == dst) return;
    const s = targets[src];
    const d = targets[dst];

    // Bind dst's framebuffer to a fresh transient view for THIS submit. The view
    // id — not dst's identity — drives execution order. A full-screen opaque
    // replace owns every dst texel, so no clear is needed (ClearFlags_None).
    const view = allocPostFxView();
    bgfx.setViewFrameBuffer(view, d.fb);
    bgfx.setViewRect(view, 0, 0, d.width, d.height);
    bgfx.setViewClear(view, bgfx.ClearFlags_None, 0, 1.0, 0);

    const saved = programs.activeView();
    programs.setActiveView(view);
    defer programs.setActiveView(saved);

    // Resolve the LUT strip for color_grade (a plain texture-pool handle). A
    // zero/dead handle degrades to a passthrough blit rather than a black quad.
    if (pass.kind == .color_grade) {
        const lut_id = pass.uniforms.aux_texture;
        const lut = texture.handleForId(lut_id);
        if (lut_id == 0 or lut.idx == INVALID) {
            programs.submitFullscreenBlit(s.color);
            return;
        }
        programs.submitPostPass(pass.kind, pass.uniforms, s.color, d.width, d.height, lut);
        return;
    }

    programs.submitPostPass(pass.kind, pass.uniforms, s.color, d.width, d.height, .{ .idx = INVALID });
}

/// Make bgfx draw the scene's render-target views, THEN the transient post-fx
/// band, THEN the primary — regardless of bgfx's default ascending-id order.
/// Without this the primary (view 0) composites first and a mirror / post-fx
/// resolve samples last frame's target. Idempotent; re-issued by `create`
/// whenever the view range grows.
///
/// Order emitted (covers the full [0, MAX_VIEW] range exactly once):
///   1. live persistent RT views (1..RT_VIEW_MAX), ascending — the scene targets;
///      they feed both mirrors and the post-fx passes, so they run first;
///   2. the ENTIRE post-fx band (POSTFX_VIEW_BASE..MAX_VIEW), ascending — a pass
///      submits into a monotonic transient view here (`applyPostPass`), so this
///      band runs AFTER the scene targets and BEFORE the primary, and within it
///      pass order == id order == execution order (the #305 fix);
///   3. the PRIMARY (0) — the frame clear + any pre-viewport draws;
///   4. the CAMERA band (CAMERA_VIEW_BASE..CAMERA_VIEW_MAX), ascending — the
///      per-camera viewport segments (#51) composite OVER the primary's clear
///      into the backbuffer, in submission order (matching bgfx's default
///      ascending order on the no-render-target path);
///   5. the free RT-band ids — inert (no draws), slot position irrelevant.
///
/// Only ever called once at least one target exists, so a game that uses no
/// render targets keeps bgfx's untouched default order (primary first, camera
/// band after by ascending id) — zero behavioural change on the common path.
fn sequenceViews() void {
    var order: [MAX_VIEW + 1]bgfx.ViewId = undefined;
    var n: u16 = 0;
    // 1. live persistent RT views (scene targets), ascending.
    var id: u16 = 1;
    while (id <= RT_VIEW_MAX) : (id += 1) {
        if (view_in_use[id]) {
            order[n] = id;
            n += 1;
        }
    }
    // 2. the whole post-fx transient band, ascending — after the scene targets,
    //    before the primary. Included unconditionally: an unused band view carries
    //    no draws, so its slot is harmless, and this keeps the relative order fixed.
    id = POSTFX_VIEW_BASE;
    while (id <= MAX_VIEW) : (id += 1) {
        order[n] = id;
        n += 1;
    }
    // 3. PRIMARY: the frame clear + pre-viewport draws.
    order[n] = programs.PRIMARY_VIEW; // 0
    n += 1;
    // 4. the camera-segment band (#51), ascending — composites over the primary.
    id = CAMERA_VIEW_BASE;
    while (id <= CAMERA_VIEW_MAX) : (id += 1) {
        order[n] = id;
        n += 1;
    }
    // 5. free RT-band ids (inert).
    id = 1;
    while (id <= RT_VIEW_MAX) : (id += 1) {
        if (!view_in_use[id]) {
            order[n] = id;
            n += 1;
        }
    }
    bgfx.setViewOrder(0, n, &order);
}

// ── Tests ──────────────────────────────────────────────────────────────
// The GPU-touching paths (create/begin/draw) need a live bgfx device and are
// exercised by the build's mirror probe on-device. What runs host-side here is
// the pure view-id bookkeeping, which must never hand out the primary view or
// exceed the bgfx view cap.
const testing = std.testing;

test "view-id allocation recycles, skips the primary, and reports exhaustion" {
    const saved = view_in_use;
    defer view_in_use = saved;
    view_in_use = [_]bool{false} ** (MAX_VIEW + 1);

    // First alloc is a valid RT id — never the primary — and within the cap.
    const a = allocView().?;
    try testing.expect(a != programs.PRIMARY_VIEW);
    try testing.expect(a >= 1 and a <= MAX_VIEW);
    view_in_use[a] = true;

    // A second alloc is distinct.
    const b = allocView().?;
    try testing.expect(b != a);
    view_in_use[b] = true;

    // Freeing `a` RECYCLES it (lowest free id) — the whole point of the fix.
    view_in_use[a] = false;
    try testing.expectEqual(a, allocView().?);

    // Fully occupied ⇒ exhaustion is reported, not a collision.
    view_in_use = [_]bool{true} ** (MAX_VIEW + 1);
    try testing.expect(allocView() == null);
}

test "persistent RT views never collide with the camera or post-fx bands" {
    // The three bands partition [0, MAX_VIEW]: primary (0), persistent RTs
    // (1..RT_VIEW_MAX), camera segments (CAMERA_VIEW_BASE..CAMERA_VIEW_MAX,
    // #51), post-fx passes (POSTFX_VIEW_BASE..MAX_VIEW). Pin the boundaries so
    // a future band resize can't silently overlap them.
    try testing.expect(RT_VIEW_MAX < CAMERA_VIEW_BASE);
    try testing.expect(CAMERA_VIEW_MAX < POSTFX_VIEW_BASE);
    try testing.expect(POSTFX_VIEW_BASE <= MAX_VIEW);

    const saved = view_in_use;
    defer view_in_use = saved;
    view_in_use = [_]bool{false} ** (MAX_VIEW + 1);
    // Even with every RT slot taken, allocView must stop BELOW the camera band.
    var id: u16 = 1;
    while (id <= RT_VIEW_MAX) : (id += 1) view_in_use[id] = true;
    try testing.expect(allocView() == null);
}

test "camera-segment views are monotonic per frame, clamp at the band top, and reset (#51)" {
    const saved_cursor = camera_next_view;
    const saved_engaged = camera_band_engaged;
    const saved_warned = camera_band_overflow_warned;
    defer {
        camera_next_view = saved_cursor;
        camera_band_engaged = saved_engaged;
        camera_band_overflow_warned = saved_warned;
    }
    camera_next_view = CAMERA_VIEW_BASE;
    camera_band_engaged = false;
    camera_band_overflow_warned = true; // silence the overflow warn in the test

    // Monotonic within a frame — segment order == bgfx execution order.
    const a = nextCameraView();
    const b = nextCameraView();
    try testing.expectEqual(CAMERA_VIEW_BASE, a);
    try testing.expectEqual(CAMERA_VIEW_BASE + 1, b);

    // Clamps at the band top: never a post-fx or RT id.
    camera_next_view = CAMERA_VIEW_MAX;
    try testing.expectEqual(CAMERA_VIEW_MAX, nextCameraView());
    try testing.expectEqual(CAMERA_VIEW_MAX, nextCameraView()); // reuse, no overflow

    // Frame reset returns the cursor to the base and disengages the band.
    camera_band_engaged = true;
    resetCameraFrame();
    try testing.expectEqual(CAMERA_VIEW_BASE, camera_next_view);
    try testing.expect(!camera_band_engaged);
}
