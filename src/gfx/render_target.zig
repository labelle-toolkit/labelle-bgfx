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
/// render targets take ids 1..MAX_VIEW. Occupancy is tracked so ids RECYCLE on
/// `destroy` — the cap is CONCURRENT, not lifetime, so a game that churns targets
/// across level loads / resizes never permanently exhausts it.
const MAX_VIEW: u16 = 255;
var view_in_use = [_]bool{false} ** (MAX_VIEW + 1);

/// First free render-target view id (1..MAX_VIEW), or null when all are taken.
/// Never returns `PRIMARY_VIEW` (0). Split out so the bookkeeping is unit-testable
/// without a live bgfx device.
fn allocView() ?u16 {
    var id: u16 = 1;
    while (id <= MAX_VIEW) : (id += 1) {
        if (!view_in_use[id]) return id;
    }
    return null;
}

/// Create an offscreen render target sized `w`×`h`. Returns an INVALID target
/// (`.isValid() == false`) when the view budget is exhausted, the size is zero,
/// or bgfx fails to allocate the framebuffer — callers must check before use.
/// The color attachment is created sampleable (implicit `BGFX_TEXTURE_RT`) and
/// clamped, so it composites back cleanly with `draw` (no edge wrap on a mirror).
pub fn create(w: u16, h: u16) RenderTarget {
    if (w == 0 or h == 0) return invalidTarget();
    const view = allocView() orelse return invalidTarget();

    // `createFrameBuffer` implies BGFX_TEXTURE_RT; add clamp so sampling a
    // mirror's edge doesn't wrap. Filtering stays at bgfx's default (bilinear).
    const flags: u64 = bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp;
    const fb = bgfx.createFrameBuffer(w, h, .RGBA8, flags);
    if (fb.idx == INVALID) return invalidTarget(); // leave the view free — no leak

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

/// Make bgfx draw all render-target views (ids 1..next_view) BEFORE the primary
/// view, regardless of bgfx's default ascending-id order. Without this the
/// primary (view 0) composites first and a mirror samples last frame's target.
/// Idempotent; re-issued by `create` whenever the view range grows.
///
/// Only ever called once at least one target exists, so a game that uses no
/// render targets keeps bgfx's untouched default order (primary first) — zero
/// behavioural change on the common path.
fn sequenceViews() void {
    // Remap the WHOLE view range so the order is correct regardless of how
    // sparse the live ids are (recycling leaves gaps): live render-target views
    // first (they feed the primary), then PRIMARY, then the free ids (inert —
    // they carry no draws, so their slot position is irrelevant). Covering the
    // full [0, MAX_VIEW] range is what makes a live RT with a high id still sort
    // before the primary.
    var order: [MAX_VIEW + 1]bgfx.ViewId = undefined;
    var n: u16 = 0;
    var id: u16 = 1;
    while (id <= MAX_VIEW) : (id += 1) {
        if (view_in_use[id]) {
            order[n] = id;
            n += 1;
        }
    }
    order[n] = programs.PRIMARY_VIEW; // 0 composites last
    n += 1;
    id = 1;
    while (id <= MAX_VIEW) : (id += 1) {
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
