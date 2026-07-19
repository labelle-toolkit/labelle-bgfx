/// Screen + camera state for the bgfx backend, plus the coordinate
/// helpers (`transformX`, `transformY`, `toNdcX`, `toNdcY`) every
/// draw primitive needs. Owns the mutable globals so all the other
/// submodules can stay state-free.
const std = @import("std");
const types = @import("types.zig");

const Vector2 = types.Vector2;
const Camera2D = types.Camera2D;

// ── State ──────────────────────────────────────────────────────────────

// Physical framebuffer size (the real surface — desktop window or Android
// ANativeWindow). Set per-frame by the generated main via `setScreenSize`.
var screen_w: i32 = 800;
var screen_h: i32 = 600;
// Design (logical) canvas the game authors in (project.labelle width/height).
// Set by the generated main via `setDesignSize`. NDC is computed against
// THIS, then aspect-fit into the physical framebuffer — so an 800x600 game
// renders correctly (letterboxed) on any device surface, not just one that
// happens to equal 800x600. Previously absent, which is why bgfx content
// mis-mapped on every non-800x600 surface (all Android devices). Mirrors
// the sokol backend's state.zig.
var design_w: i32 = 800;
var design_h: i32 = 600;
// Aspect-preserving design→physical fit, recomputed on any size change.
var fit_scale_x: f32 = 1.0;
var fit_scale_y: f32 = 1.0;
// When false, `toNdcX/toNdcY` skip the fit so the design canvas stretches
// to fill the whole framebuffer. The renderer toggles this off around
// `screen_fill` layers (backdrops) so they cover the pillarbox bars instead
// of leaving white stripes, and back on for world/UI layers. Mirrors sokol.
var fit_active: bool = true;
var active_camera: ?Camera2D = null;

// ── Per-camera viewport NDC basis (N-camera split-screen, labelle-bgfx#51) ──
// A split-screen camera renders into a SUB-RECT of the framebuffer (a bgfx
// view rect, set by the camera-segment path). The gfx camera authors its
// projection in that viewport's OWN design pixels — its `offset` is
// `viewport_dims/2`, so a world point at the camera centre lands at
// design (vp_w/2, vp_h/2). For that centre to map to the MIDDLE of the
// sub-rect, NDC must normalize against the VIEWPORT dims, not the full design
// canvas — otherwise the content lands at a fraction of the sub-rect and the
// split looks wrong. When `active_vp` is set (bracketed by
// `beginViewport`/`endViewport` around each camera pass) `toNdc`/`screenWidth`/
// `fitScale*` switch to viewport-relative fill: NDC [-1,1] fills the sub-rect
// (bgfx's `setViewRect` already positions + scales the square to the rect, whose
// physical aspect equals the design viewport's — see `designViewportToPhysical`
// — so no extra letterbox is applied inside it). `null` (the default, and the
// only state on a viewport-less frame — every golden/probe) is byte-identical
// to the pre-#51 full-canvas mapping.
const ViewportBasis = struct { w: f32, h: f32 };
var active_vp: ?ViewportBasis = null;

/// Begin a per-camera viewport pass: NDC now fills a `w`×`h` (DESIGN-pixel)
/// viewport. Bracketed by `endViewport`; nestless (each camera pass reopens).
pub fn beginViewport(w: f32, h: f32) void {
    if (w <= 0 or h <= 0) return;
    active_vp = .{ .w = w, .h = h };
}

/// End a per-camera viewport pass — NDC returns to the full design canvas with
/// its letterbox fit. Called by `clearViewport` and at frame start.
pub fn endViewport() void {
    active_vp = null;
}

/// Map a DESIGN-space viewport rect to the PHYSICAL framebuffer sub-rect bgfx's
/// `setViewRect`/`setViewScissor` need (top-left origin, u16). Routes both
/// corners through `designToPhysical` so the sub-rect sits inside the same
/// letterboxed region the full canvas maps to — on HiDPI/Retina the design rect
/// is scaled up (e.g. design 400 → physical 800), and under a pillarbox it is
/// inset by the bars. Returns `.{ x, y, w, h }` clamped to u16.
pub fn designViewportToPhysical(x: f32, y: f32, w: f32, h: f32) [4]u16 {
    const tl = designToPhysical(.{ .x = x, .y = y });
    const br = designToPhysical(.{ .x = x + w, .y = y + h });
    const px0 = @min(tl.x, br.x);
    const py0 = @min(tl.y, br.y);
    const pw = @abs(br.x - tl.x);
    const ph = @abs(br.y - tl.y);
    return .{ toU16(px0), toU16(py0), toU16(pw), toU16(ph) };
}

fn toU16(v: f32) u16 {
    if (v <= 0) return 0;
    if (v >= @as(f32, std.math.maxInt(u16))) return std.math.maxInt(u16);
    return @intFromFloat(v);
}

/// Toggle the aspect-fit. `false` for `screen_fill` layers (stretch to the
/// full framebuffer), `true` for normal fitted layers. Backends that don't
/// implement this make the gfx renderer fall back to treating `screen_fill`
/// as a normal pillarboxed layer (the bug this fixes).
pub fn setApplyFit(active: bool) void {
    fit_active = active;
}

fn recomputeFitScale() void {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        fit_scale_x = 1.0;
        fit_scale_y = 1.0;
        return;
    }
    const s = @min(sw / dw, sh / dh);
    fit_scale_x = s * dw / sw;
    fit_scale_y = s * dh / sh;
}

/// Physical framebuffer size (real surface). Recomputes the fit scale.
pub fn setScreenSize(w: i32, h: i32) void {
    screen_w = @max(1, w);
    screen_h = @max(1, h);
    recomputeFitScale();
}

/// Convert a physical-pixel screen coordinate (a GLFW mouse / touch event
/// in framebuffer pixels) to a design-pixel coordinate inside the
/// pillarboxed/letterboxed canvas.
///
/// Input events arrive in raw framebuffer pixels (the bgfx `input` backend
/// scales GLFW's logical cursor by the framebuffer/window ratio), but
/// game-level math (`cam.screenToWorld`, sprite positions) works in design
/// pixels. The camera's `framebufferToWorld` calls this (guarded by
/// `@hasDecl`) so clicks land correctly on HiDPI/Retina; without it the
/// camera treats framebuffer pixels as design pixels and is off by the
/// pillarbox bars + the design→physical scale. Mirrors the sokol backend.
pub fn screenToDesign(px: f32, py: f32) Vector2 {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        return .{ .x = px, .y = py };
    }
    // Exact inverse of toNdc: physical framebuffer px → NDC (full-
    // framebuffer viewport) → design. The fitted content spans NDC
    // [-fit,+fit] = fit_scale*screen_w physical pixels (NOT design_w*fit),
    // so the inverse must go through NDC, not a design-space bar. (#331:
    // the old design-space bar was wrong whenever screen != design — i.e.
    // on HiDPI/Retina — clicks drifted toward the edges.)
    const ndc_x = (px / sw) * 2.0 - 1.0;
    const ndc_y = 1.0 - (py / sh) * 2.0;
    return .{
        .x = ((ndc_x / fit_scale_x) + 1.0) * 0.5 * dw,
        .y = (1.0 - ndc_y / fit_scale_y) * 0.5 * dh,
    };
}

/// Inverse of `screenToDesign`: design-pixel → physical-pixel inside the
/// fitted canvas. Kept for parity with the sokol backend (used by the iOS
/// soft-keyboard bridge there; harmless to expose here).
pub fn designToPhysical(pos: Vector2) Vector2 {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        return pos;
    }
    // Forward of toNdc: design → NDC → physical framebuffer px. Exact
    // inverse of screenToDesign (#331).
    const ndc_x = ((pos.x / dw) * 2.0 - 1.0) * fit_scale_x;
    const ndc_y = (1.0 - (pos.y / dh) * 2.0) * fit_scale_y;
    return .{
        .x = (ndc_x + 1.0) * 0.5 * sw,
        .y = (1.0 - ndc_y) * 0.5 * sh,
    };
}

// ── Camera coordinate transform ────────────────────────────────────────

pub fn transformX(x: f32) f32 {
    if (active_camera) |cam| {
        return (x - cam.target.x) * cam.zoom + cam.offset.x;
    }
    return x;
}

pub fn transformY(y: f32) f32 {
    if (active_camera) |cam| {
        return (y - cam.target.y) * cam.zoom + cam.offset.y;
    }
    return y;
}

/// Convert a (camera-transformed) design-pixel X to NDC, then apply the
/// aspect-fit so the design canvas letterboxes into the physical surface.
/// When `fit_active` is false (the renderer toggles it off around
/// `screen_fill` layers, via `setApplyFit`), the fit is skipped so the
/// design canvas STRETCHES to fill the whole framebuffer — backdrops cover
/// the pillarbox bars instead of leaving them as stripes. Mirrors sokol.
pub fn toNdcX(px: f32) f32 {
    // Split-screen viewport pass (#51): fill the sub-rect, normalizing by the
    // viewport's own width so the camera's centre (design vp_w/2) → NDC 0.
    if (active_vp) |vp| return (px / vp.w) * 2.0 - 1.0;
    const raw = (px / @as(f32, @floatFromInt(design_w))) * 2.0 - 1.0;
    return if (fit_active) raw * fit_scale_x else raw;
}

pub fn toNdcY(py: f32) f32 {
    // Flip Y: screen top=0 maps to NDC +1
    if (active_vp) |vp| return 1.0 - (py / vp.h) * 2.0;
    const raw = 1.0 - (py / @as(f32, @floatFromInt(design_h))) * 2.0;
    return if (fit_active) raw * fit_scale_y else raw;
}

// Respect `fit_active` (like toNdcX/toNdcY): callers that scale sizes by the
// fit (e.g. drawCircle radius, line thickness) must use 1.0 on `screen_fill`
// layers, else shapes are mis-sized relative to their stretched positions. In a
// viewport pass (#51) NDC fills the sub-rect, so the fit is 1.0 there too.
pub fn fitScaleX() f32 {
    if (active_vp != null) return 1.0;
    return if (fit_active) fit_scale_x else 1.0;
}

pub fn fitScaleY() f32 {
    if (active_vp != null) return 1.0;
    return if (fit_active) fit_scale_y else 1.0;
}

// ── Camera queries (used by drawCircle / drawLine / drawTexturePro) ──

/// Returns the active camera's zoom factor, or 1.0 if no camera is
/// active. Used by the shape draw paths to scale radii and line
/// thickness with the camera so visual size matches what game code
/// expects.
pub fn cameraZoom() f32 {
    return if (active_camera) |cam| cam.zoom else @as(f32, 1.0);
}

// Design-space dimensions — the denominators toNdc maps against. drawCircle
// reads these for its per-axis NDC radius (then multiplies by fitScale*). In a
// viewport pass (#51) these are the viewport's own dims so a circle's radius
// scales to the sub-rect the same way toNdc places its centre.
pub fn screenWidth() i32 {
    if (active_vp) |vp| return @intFromFloat(vp.w);
    return design_w;
}

pub fn screenHeight() i32 {
    if (active_vp) |vp| return @intFromFloat(vp.h);
    return design_h;
}

// ── Public camera control / Backend-contract utilities ───────────────

pub fn beginMode2D(camera: Camera2D) void {
    active_camera = camera;
}

pub fn endMode2D() void {
    active_camera = null;
}

// Backend contract: return the DESIGN canvas so engine/camera math stays
// resolution-independent (matches the sokol backend). Physical size lives
// in screen_w/h and is used only for the fit scale.
pub fn getScreenWidth() i32 {
    return design_w;
}

pub fn getScreenHeight() i32 {
    return design_h;
}

/// Set the design (logical) canvas size — the resolution game code operates
/// in (project.labelle width/height). Recomputes the design→physical fit.
pub fn setDesignSize(w: i32, h: i32) void {
    design_w = @max(1, w);
    design_h = @max(1, h);
    recomputeFitScale();
}

/// Physical framebuffer dimensions (the real surface size fed by
/// `setScreenSize` each frame). Used by the viewport seam (`clearViewport`,
/// labelle-bgfx#51) to restore a full-window rect in framebuffer pixels.
pub fn physicalWidth() i32 {
    return screen_w;
}

pub fn physicalHeight() i32 {
    return screen_h;
}

/// Design (logical) canvas dimensions — parity with the sokol backend's
/// public surface.
pub fn getDesignWidth() i32 {
    return design_w;
}

pub fn getDesignHeight() i32 {
    return design_h;
}

pub fn screenToWorld(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.offset.x) / camera.zoom + camera.target.x,
        .y = (pos.y - camera.offset.y) / camera.zoom + camera.target.y,
    };
}

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.target.x) * camera.zoom + camera.offset.x,
        .y = (pos.y - camera.target.y) * camera.zoom + camera.offset.y,
    };
}

// ── Coordinate-math tests (#331) ────────────────────────────────────────
// `screenToDesign` / `designToPhysical` must be exact inverses of `toNdc`
// (and of each other). The old design-space-bar formula was correct only
// when screen == design; these lock the HiDPI case (screen 2x design) and
// a letterboxed case. Run via the `state_run` test in build.zig.

test "screenToDesign maps physical edges to design edges on HiDPI" {
    const t = std.testing;
    setDesignSize(800, 600);
    setScreenSize(1600, 1200); // 2x Retina: fit == 1, design fills the surface
    const tl = screenToDesign(0, 0);
    try t.expectApproxEqAbs(@as(f32, 0), tl.x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 0), tl.y, 1e-3);
    const br = screenToDesign(1600, 1200);
    try t.expectApproxEqAbs(@as(f32, 800), br.x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 600), br.y, 1e-3);
    const c = screenToDesign(800, 600);
    try t.expectApproxEqAbs(@as(f32, 400), c.x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 300), c.y, 1e-3);
}

test "viewport NDC basis fills the sub-rect: camera centre → NDC 0 (#51)" {
    const t = std.testing;
    setDesignSize(800, 600);
    setScreenSize(800, 600);
    defer endViewport();

    // Full-canvas mapping (no viewport): design centre 400 → NDC 0.
    endViewport();
    try t.expectApproxEqAbs(@as(f32, 0), toNdcX(400), 1e-4);

    // A right-half viewport (design 400 wide). The gfx camera authors its
    // projection so a camera-centred world point lands at design vp_w/2 = 200.
    // With the viewport basis active that must map to NDC 0 — the middle of the
    // sub-rect bgfx's setViewRect positions on screen — NOT NDC -0.5 (which the
    // full-canvas 800-wide denominator would give, the split-screen bug).
    beginViewport(400, 600);
    try t.expectApproxEqAbs(@as(f32, 0), toNdcX(200), 1e-4); // centre → 0
    try t.expectApproxEqAbs(@as(f32, -1), toNdcX(0), 1e-4); // left edge → -1
    try t.expectApproxEqAbs(@as(f32, 1), toNdcX(400), 1e-4); // right edge → +1
    // Y fills the viewport height too (top → +1, bottom → -1).
    try t.expectApproxEqAbs(@as(f32, 1), toNdcY(0), 1e-4);
    try t.expectApproxEqAbs(@as(f32, -1), toNdcY(600), 1e-4);
    // The viewport basis fills (no letterbox shrink) — fit is 1.0.
    try t.expectApproxEqAbs(@as(f32, 1), fitScaleX(), 1e-4);
    try t.expectApproxEqAbs(@as(f32, 1), fitScaleY(), 1e-4);

    // endViewport restores the full-canvas mapping exactly.
    endViewport();
    try t.expectApproxEqAbs(@as(f32, 0), toNdcX(400), 1e-4);
}

test "designViewportToPhysical scales a design viewport into the framebuffer (#51)" {
    const t = std.testing;
    // Non-HiDPI, matching surface: a design viewport maps 1:1 to physical.
    setDesignSize(800, 600);
    setScreenSize(800, 600);
    const r = designViewportToPhysical(400, 0, 400, 600);
    try t.expectEqual(@as(u16, 400), r[0]);
    try t.expectEqual(@as(u16, 0), r[1]);
    try t.expectEqual(@as(u16, 400), r[2]);
    try t.expectEqual(@as(u16, 600), r[3]);

    // HiDPI/Retina (2x, same aspect ⇒ no letterbox): the design viewport is
    // scaled up to physical pixels, so the right-half design rect (400..800)
    // becomes the right-half physical rect (800..1600).
    setScreenSize(1600, 1200);
    const r2 = designViewportToPhysical(400, 0, 400, 600);
    try t.expectEqual(@as(u16, 800), r2[0]);
    try t.expectEqual(@as(u16, 0), r2[1]);
    try t.expectEqual(@as(u16, 800), r2[2]);
    try t.expectEqual(@as(u16, 1200), r2[3]);
}

test "screenToDesign and designToPhysical round-trip (incl. letterbox)" {
    const t = std.testing;
    setDesignSize(800, 600);
    setScreenSize(2000, 1000); // wider -> pillarbox; fit_x != fit_y; screen != design
    const samples = [_][2]f32{ .{ 0, 0 }, .{ 2000, 1000 }, .{ 1000, 500 }, .{ 500, 250 }, .{ 1750, 800 } };
    for (samples) |s| {
        const d = screenToDesign(s[0], s[1]);
        const p = designToPhysical(.{ .x = d.x, .y = d.y });
        try t.expectApproxEqAbs(s[0], p.x, 1e-2);
        try t.expectApproxEqAbs(s[1], p.y, 1e-2);
    }
}
