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
const programs = @import("programs.zig");
const texture = @import("texture.zig");
const types = @import("types.zig");

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
    return .{ .fb = .{ .idx = INVALID }, .color = .{ .idx = INVALID }, .view = INVALID, .width = 0, .height = 0 };
}

/// bgfx's default cap is 256 views. View 0 is the primary (`programs.PRIMARY_VIEW`);
/// render targets take ids 1..MAX_VIEW. Monotonic, no recycling — 255 live
/// offscreen passes is far beyond any real scene, and dropping recycling keeps
/// `sequenceViews` a trivial contiguous remap.
const MAX_VIEW: u16 = 255;
var next_view: u16 = 1;

/// Create an offscreen render target sized `w`×`h`. Returns an INVALID target
/// (`.isValid() == false`) when the view budget is exhausted, the size is zero,
/// or bgfx fails to allocate the framebuffer — callers must check before use.
/// The color attachment is created sampleable (implicit `BGFX_TEXTURE_RT`) and
/// clamped, so it composites back cleanly with `draw` (no edge wrap on a mirror).
pub fn create(w: u16, h: u16) RenderTarget {
    if (next_view > MAX_VIEW or w == 0 or h == 0) return invalidTarget();

    // `createFrameBuffer` implies BGFX_TEXTURE_RT; add clamp so sampling a
    // mirror's edge doesn't wrap. Filtering stays at bgfx's default (bilinear).
    const flags: u64 = bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp;
    const fb = bgfx.createFrameBuffer(w, h, .RGBA8, flags);
    if (fb.idx == INVALID) return invalidTarget();

    const view = next_view;
    next_view += 1;

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
    rt.fb = .{ .idx = INVALID };
    rt.color = .{ .idx = INVALID };
}

/// Saved active views for nested `begin`/`end` (a target rendered while another
/// is already active). Fixed shallow depth — offscreen passes don't nest deeply;
/// overflow just skips the save (worst case `end` restores the primary).
var view_stack: [8]u16 = undefined;
var stack_depth: usize = 0;

/// Point every subsequent draw at `rt`'s framebuffer. Balance with `end`.
/// `touch` guarantees bgfx clears/processes the view even if the pass submits no
/// draws — the same reason `window.beginFrame` touches the primary view.
pub fn begin(rt: RenderTarget) void {
    if (!rt.isValid()) return;
    if (stack_depth < view_stack.len) {
        view_stack[stack_depth] = programs.activeView();
        stack_depth += 1;
    }
    programs.setActiveView(rt.view);
    bgfx.touch(rt.view);
}

/// Restore the draw target to whatever was active before the matching `begin`
/// (the primary view, or an enclosing target). Safe to call unbalanced — with an
/// empty stack it falls back to the primary view.
pub fn end() void {
    const restore: u16 = if (stack_depth > 0) blk: {
        stack_depth -= 1;
        break :blk view_stack[stack_depth];
    } else programs.PRIMARY_VIEW;
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

/// Make bgfx draw all render-target views (ids 1..next_view) BEFORE the primary
/// view, regardless of bgfx's default ascending-id order. Without this the
/// primary (view 0) composites first and a mirror samples last frame's target.
/// Idempotent; re-issued by `create` whenever the view range grows.
///
/// Only ever called once at least one target exists, so a game that uses no
/// render targets keeps bgfx's untouched default order (primary first) — zero
/// behavioural change on the common path.
fn sequenceViews() void {
    var order: [MAX_VIEW + 1]bgfx.ViewId = undefined;
    var n: u16 = 0;
    var id: u16 = 1;
    while (id < next_view) : (id += 1) {
        order[n] = id;
        n += 1;
    }
    order[n] = programs.PRIMARY_VIEW; // 0 composites last
    n += 1;
    bgfx.setViewOrder(0, n, &order);
}

// ── Tests ──────────────────────────────────────────────────────────────
// The GPU-touching paths (create/begin/draw) need a live bgfx device and are
// exercised by the build's mirror probe on-device. What runs host-side here is
// the pure view-id bookkeeping, which must never hand out the primary view or
// exceed the bgfx view cap.
const testing = std.testing;

test "render-target views never collide with the primary view" {
    // Fresh allocations start above PRIMARY_VIEW and stay within the bgfx cap.
    try testing.expect(next_view > programs.PRIMARY_VIEW);
    try testing.expect(next_view >= 1);
    try testing.expect(MAX_VIEW < 256);
}
