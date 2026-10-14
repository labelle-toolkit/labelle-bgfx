//! Browser (emscripten HTML5) touch input as a state machine the host can
//! test (labelle-bgfx#202).
//!
//! Mirrors the Android NativeActivity glue's single-primary-pointer model: the
//! first touch point maps onto mouse button 0 + the cursor position, so imgui
//! and the engine's mouse-driven hit-testing see touch transparently, and it
//! drives the engine's touch getters (index 0). Two fingers pinch-zoom (#16).
//!
//! `input.zig` registers the emscripten callbacks and hands each event here
//! with the mouse fields it shares with the HTML5 mouse callbacks (`Mouse`).
//! Dear ImGui is reached only through the `Gui` type each call is given
//! (`mousePos`, `mouseButton`, `mouseWheel`), so a test can record what ImGui
//! would have been told.
const std = @import("std");
const gui_pointer = @import("gui_pointer.zig");
// Touch identifiers are opaque bits: iOS Safari reports negative ones (#187).
const touchKey = @import("touch_key.zig").touchKey;

// EmscriptenTouchPoint / EmscriptenTouchEvent (html5.h), byte-faithful.
pub const TouchPoint = extern struct {
    identifier: i32,
    screenX: i32,
    screenY: i32,
    clientX: i32,
    clientY: i32,
    pageX: i32,
    pageY: i32,
    isChanged: bool,
    onTarget: bool,
    targetX: i32,
    targetY: i32,
    canvasX: i32,
    canvasY: i32,
};
pub const TouchEvent = extern struct {
    timestamp: f64,
    numTouches: i32,
    ctrlKey: bool,
    shiftKey: bool,
    altKey: bool,
    metaKey: bool,
    touches: [32]TouchPoint,
};

// Pinch sensitivity: ~1 wheel-unit (one notch) per this many pixels of spread.
const PINCH_PX_PER_WHEEL: f32 = 80.0;

/// The mouse state the touch callbacks share with the HTML5 mouse callbacks:
/// button 0's live level and edge accumulators, the wheel accumulator and the
/// cursor, all latched by `input.newFrame`. `latched_down` is whether the
/// engine has seen button 0 down (`mouse_down[0]`), and `scale_*` maps CSS px
/// to framebuffer px.
pub const Mouse = struct {
    x: *f32,
    y: *f32,
    down: *bool,
    pressed_accum: *bool,
    released_accum: *bool,
    wheel_accum: *f32,
    latched_down: bool,
    scale_x: f32 = 1,
    scale_y: f32 = 1,
};

pub const State = struct {
    /// A primary finger is being tracked (drives `getTouchCount`).
    active: bool = false,
    /// The primary finger's position, framebuffer px (touch index 0).
    x: f32 = 0,
    y: f32 = 0,
    id: u64 = 0,
    // Deferred-press state (pinch-vs-tap disambiguation). The FIRST finger down
    // is recorded as the primary but is NOT yet committed to a button-0 press:
    // no imgui down, no `Mouse.down`, no press edge. This defers the press until
    // we know the gesture is a single tap and not the start of a two-finger
    // pinch. It is promoted to a real press either on the next frame (`promote`:
    // still the lone active touch → hold/drag) or synthesized as a same-frame
    // down+up on touchend (fast tap). If a 2nd finger arrives first,
    // `cancelPrimary` drops the pending primary WITHOUT any imgui down/up → the
    // pinch leaves zero clicks.
    primary_pending: bool = false,
    // Multi-touch pinch-zoom state (#16). When ≥2 fingers are down we compute
    // the distance between the first two touch points and feed its
    // frame-over-frame delta into the wheel (mobile analog of the mouse wheel).
    // `pinch_prev_dist` is reset on entering/leaving pinch mode so the first
    // pinch frame never jumps.
    pinch_active: bool = false,
    pinch_prev_dist: f32 = 0,

    // Single-primary-pointer model (Android-parity): the FIRST finger down
    // becomes the pointer, tracked by its `identifier`; other fingers are
    // ignored until it lifts. This prevents a second finger from emitting an
    // extra button-0 press or a stray finger's `touchend` from releasing an
    // in-progress drag. A second finger instead triggers pinch-zoom (`pinch`),
    // not a click.
    pub fn start(self: *State, comptime Gui: type, e: *const TouchEvent, m: Mouse) void {
        if (e.numTouches <= 0) return;
        if (self.pinch(Gui, e, false, m)) return; // ≥2 fingers → pinch-zoom, not a click
        if (self.active) return; // already tracking a primary finger
        const t = &e.touches[0];
        self.id = touchKey(t.identifier);
        self.setPos(Gui, t, m);
        self.active = true;
        // Deferred press: record the primary but do NOT commit a button-0
        // press yet (see `primary_pending`). A genuine single tap is committed
        // later: promoted to a real held press on the next frame (drag), or
        // synthesized as a same-frame down+up on touchend (fast tap).
        self.primary_pending = true;
    }

    pub fn move(self: *State, comptime Gui: type, e: *const TouchEvent, m: Mouse) void {
        if (self.pinch(Gui, e, false, m)) return; // ≥2 fingers → feed wheel delta, no move
        if (!self.active) return;
        if (findTouch(e, self.id)) |t| self.setPos(Gui, t, m);
    }

    /// touchend and touchcancel.
    pub fn end(self: *State, comptime Gui: type, e: *const TouchEvent, m: Mouse) void {
        // Count only ACTIVE (non-lifted) touches: a touchend still LISTS the
        // lifted finger (isChanged), so `is_end=true` excludes it. Still ≥2
        // active → stay in pinch; dropping below 2 exits pinch + re-seeds the
        // single pointer.
        if (self.pinch(Gui, e, true, m)) return;
        if (!self.active) {
            // Nothing tracked: a pinch whose fingers all lifted together ends
            // here. With no finger left, ImGui must still stop hovering (#202).
            if (gui_pointer.clearsOnTouchEnd(activeCount(e, true))) clearGuiPointer(Gui);
            return;
        }
        // The primary is still down iff it appears in this event as an ACTIVE
        // (not-changed) touch — true whether emscripten includes the ended
        // touch (as `isChanged`) or omits it. If so, a non-primary finger
        // ended: keep the pointer down and just refresh position.
        for (e.touches[0..touchCount(e)]) |*t| {
            if (touchKey(t.identifier) == self.id and !t.isChanged) {
                self.setPos(Gui, t, m);
                return;
            }
        }
        // Primary finger lifted → release the pointer.
        self.active = false;
        if (self.primary_pending) {
            // Fast tap: the finger lifted before any frame promoted the
            // deferred press, and no 2nd finger turned it into a pinch.
            // Synthesize a full down+up at the release point so imgui still
            // registers a click and the engine sees a press+release edge this
            // frame. (`setPos` already forwarded the imgui position on
            // touchstart/touchmove.)
            self.primary_pending = false;
            m.pressed_accum.* = true;
            m.released_accum.* = true;
            Gui.mouseButton(0, true);
            Gui.mouseButton(0, false);
        } else if (m.down.*) {
            // Promoted press (hold/drag) → normal release edge.
            m.down.* = false;
            m.released_accum.* = true;
            Gui.mouseButton(0, false);
        }
        // The finger is gone, so ImGui must stop hovering the lift point
        // (#202). Its trickled event queue applies this only after the button
        // events above, so the tap still clicks where the finger was.
        clearGuiPointer(Gui);
    }

    /// Called at the start of each frame, before the mouse latch. Promote a
    /// deferred single-tap press: if the primary finger is still the lone
    /// active touch one frame after touchdown — i.e. no 2nd finger turned it
    /// into a pinch — commit it to a real button-0 press now so holds/drags
    /// work. A pinch would have cleared `primary_pending` via `cancelPrimary`
    /// before reaching here, so a pinch never promotes → no phantom click.
    pub fn promote(self: *State, comptime Gui: type, m: Mouse) void {
        if (!(self.primary_pending and self.active and !self.pinch_active)) return;
        self.primary_pending = false;
        m.down.* = true;
        m.pressed_accum.* = true;
        Gui.mouseButton(0, true);
    }

    /// Focus loss: drop the tracked pointer, any uncommitted deferred tap and
    /// any pinch, so returning to the tab starts from a clean slate. (The held
    /// mouse buttons are released by the caller, with the keys.)
    pub fn blur(self: *State) void {
        self.active = false;
        self.primary_pending = false;
        self.pinch_active = false;
        self.pinch_prev_dist = 0;
    }

    /// Position (scaled CSS→framebuffer) from the primary touch point.
    fn setPos(self: *State, comptime Gui: type, t: *const TouchPoint, m: Mouse) void {
        m.x.* = @as(f32, @floatFromInt(t.targetX)) * m.scale_x;
        m.y.* = @as(f32, @floatFromInt(t.targetY)) * m.scale_y;
        // Engine touch getters (Android-parity): expose as touch index 0.
        self.x = m.x.*;
        self.y = m.y.*;
        Gui.mousePos(m.x.*, m.y.*);
    }

    // ── Two-finger pinch-zoom (#16) ─────────────────────────────────────
    // Mobile analog of the mouse wheel: with ≥2 fingers down, feed the change
    // in the first-two-fingers distance into the wheel accumulator (+ the
    // imgui wheel), so games that map `getMouseWheelMove()` → camera zoom
    // (e.g. FP's camera_control) get pinch-to-zoom for free. Spreading fingers
    // apart grows the distance → positive wheel (zoom in); pinching in →
    // negative (zoom out).

    /// Drive pinch mode from an incoming touch event (`is_end` true for
    /// touchend/cancel). Returns true when the event is consumed as a pinch
    /// (the caller then skips the single-pointer logic). Entering pinch
    /// cancels the single-finger press so the gesture zooms instead of
    /// dragging; leaving pinch (back to ≤1 active touch) re-seeds the primary
    /// pointer (position only, no press) from the remaining finger so
    /// single-pointer tracking resumes without a phantom click.
    /// `pinch_prev_dist` is reset on both transitions so neither the first nor
    /// a later pinch frame jumps.
    fn pinch(self: *State, comptime Gui: type, e: *const TouchEvent, is_end: bool, m: Mouse) bool {
        const n = activeCount(e, is_end);
        if (n >= 2) {
            const dist = pinchDist(e, is_end, m);
            if (!self.pinch_active) {
                self.pinch_active = true;
                self.pinch_prev_dist = dist; // seed → no jump on the first move
                self.cancelPrimary(Gui, m);
            } else {
                const delta = (dist - self.pinch_prev_dist) / PINCH_PX_PER_WHEEL;
                self.pinch_prev_dist = dist;
                if (delta != 0) {
                    m.wheel_accum.* += delta;
                    Gui.mouseWheel(0, delta);
                }
            }
            return true;
        }
        if (self.pinch_active) {
            self.pinch_active = false;
            self.pinch_prev_dist = 0;
            if (n == 1) {
                // Re-seed from the first ACTIVE touch (index 0 may be the lifted one).
                for (e.touches[0..touchCount(e)]) |*t| {
                    if (isActive(t, is_end)) {
                        self.id = touchKey(t.identifier);
                        self.setPos(Gui, t, m);
                        self.active = true; // resume single-pointer tracking (no press)
                        break;
                    }
                }
            }
        }
        return false;
    }

    /// Cancel any in-progress single-finger primary pointer WITHOUT leaving a
    /// phantom click — called when a 2nd finger promotes the gesture to a
    /// pinch.
    ///
    /// Two cases, keyed on `primary_pending`:
    ///   • Still DEFERRED (the common quick-pinch): no imgui down was ever sent
    ///     and no press edge latched, so we just drop the pending primary — the
    ///     primary never became a press, so the pinch leaks zero clicks.
    ///   • Already PROMOTED (fingers landed >1 frame apart, so the primary
    ///     became a real hold): the imgui down was sent, so balance it with an
    ///     imgui up (else imgui's button sticks). The ENGINE release EDGE is
    ///     only emitted when the press was actually LATCHED
    ///     (`Mouse.latched_down`); otherwise a release would be a phantom, so
    ///     we just drop the still-unlatched press accum.
    fn cancelPrimary(self: *State, comptime Gui: type, m: Mouse) void {
        self.active = false;
        if (self.primary_pending) {
            self.primary_pending = false; // deferred press never committed → nothing to undo
            return;
        }
        m.pressed_accum.* = false; // drop an as-yet-unlatched press
        m.down.* = false;
        if (m.latched_down) m.released_accum.* = true; // only if latched
        Gui.mouseButton(0, false);
    }
};

/// Tell ImGui the touch pointer is gone (`-FLT_MAX`), so it stops hovering
/// the lift point (#202).
fn clearGuiPointer(comptime Gui: type) void {
    Gui.mousePos(gui_pointer.absent, gui_pointer.absent);
}

/// Number of valid entries in the event's touch array (clamped to the fixed 32).
fn touchCount(e: *const TouchEvent) usize {
    if (e.numTouches <= 0) return 0;
    return @min(@as(usize, @intCast(e.numTouches)), e.touches.len);
}

/// The touch point matching `id`, if present in this event.
fn findTouch(e: *const TouchEvent, id: u64) ?*const TouchPoint {
    for (e.touches[0..touchCount(e)]) |*t| {
        if (touchKey(t.identifier) == id) return t;
    }
    return null;
}

// A touch point is ACTIVE (still on the surface after this event) unless this
// is a touchend/cancel AND the point is one of the lifted (`isChanged`) ones.
// emscripten's `touches` array is the UNION of on-surface + changed points, so
// on touchend a lifted finger is still listed (with `isChanged=true`); on
// touchstart the just-placed finger is also `isChanged` but IS active — hence
// the `is_end` gate (a plain skip-`isChanged` would undercount on start).
fn isActive(t: *const TouchPoint, is_end: bool) bool {
    return !(is_end and t.isChanged);
}

/// Count of touches that remain active after this event (drives the pinch gate).
fn activeCount(e: *const TouchEvent, is_end: bool) usize {
    var count: usize = 0;
    for (e.touches[0..touchCount(e)]) |*t| {
        if (isActive(t, is_end)) count += 1;
    }
    return count;
}

/// Framebuffer-pixel distance between the first two ACTIVE touch points (0 if
/// <2). Skips lifted fingers on touchend so a 3→2 finger lift measures the two
/// surviving fingers, never a finger that's leaving.
fn pinchDist(e: *const TouchEvent, is_end: bool, m: Mouse) f32 {
    var pts: [2]*const TouchPoint = undefined;
    var k: usize = 0;
    for (e.touches[0..touchCount(e)]) |*t| {
        if (isActive(t, is_end)) {
            pts[k] = t;
            k += 1;
            if (k == 2) break;
        }
    }
    if (k < 2) return 0;
    const ax = @as(f32, @floatFromInt(pts[0].targetX)) * m.scale_x;
    const ay = @as(f32, @floatFromInt(pts[0].targetY)) * m.scale_y;
    const bx = @as(f32, @floatFromInt(pts[1].targetX)) * m.scale_x;
    const by = @as(f32, @floatFromInt(pts[1].targetY)) * m.scale_y;
    const dx = bx - ax;
    const dy = by - ay;
    return @sqrt(dx * dx + dy * dy);
}

// ── Tests: the callbacks as the browser drives them, ImGui recorded ──────

/// What ImGui was told, in order.
const Call = union(enum) {
    pos: struct { x: f32, y: f32 },
    button: struct { button: i32, down: bool },
    wheel: f32,
};

/// Records ImGui calls (one test at a time; reset with `begin`).
const RecordingGui = struct {
    var calls: [64]Call = undefined;
    var len: usize = 0;

    fn begin() void {
        len = 0;
    }
    fn record(c: Call) void {
        calls[len] = c;
        len += 1;
    }
    fn log() []const Call {
        return calls[0..len];
    }
    fn last() Call {
        return calls[len - 1];
    }

    pub fn mousePos(x: f32, y: f32) void {
        record(.{ .pos = .{ .x = x, .y = y } });
    }
    pub fn mouseButton(button: i32, down: bool) void {
        record(.{ .button = .{ .button = button, .down = down } });
    }
    pub fn mouseWheel(_: f32, y: f32) void {
        record(.{ .wheel = y });
    }
};

/// A test's browser-side mouse fields and touch state.
const Harness = struct {
    state: State = .{},
    x: f32 = 0,
    y: f32 = 0,
    down: bool = false,
    pressed: bool = false,
    released: bool = false,
    wheel: f32 = 0,

    fn mouse(h: *Harness) Mouse {
        return .{ .x = &h.x, .y = &h.y, .down = &h.down, .pressed_accum = &h.pressed, .released_accum = &h.released, .wheel_accum = &h.wheel, .latched_down = h.down };
    }
    fn start(h: *Harness, e: TouchEvent) void {
        h.state.start(RecordingGui, &e, h.mouse());
    }
    fn move(h: *Harness, e: TouchEvent) void {
        h.state.move(RecordingGui, &e, h.mouse());
    }
    fn end(h: *Harness, e: TouchEvent) void {
        h.state.end(RecordingGui, &e, h.mouse());
    }
    fn frame(h: *Harness) void {
        h.state.promote(RecordingGui, h.mouse());
    }
};

const Finger = struct { id: i32, x: i32, y: i32, lifted: bool = false };

/// A touch event listing `fingers` (a lifted one is `isChanged`).
fn event(fingers: []const Finger) TouchEvent {
    var e = std.mem.zeroes(TouchEvent);
    e.numTouches = @intCast(fingers.len);
    for (fingers, 0..) |f, i| {
        e.touches[i].identifier = f.id;
        e.touches[i].targetX = f.x;
        e.touches[i].targetY = f.y;
        e.touches[i].isChanged = f.lifted;
    }
    return e;
}

fn expectPointerGone() !void {
    try std.testing.expectEqual(Call{ .pos = .{ .x = gui_pointer.absent, .y = gui_pointer.absent } }, RecordingGui.last());
}

fn expectNoButtons() !void {
    for (RecordingGui.log()) |c| try std.testing.expect(c != .button);
}

test "a pinch whose fingers lift together stops ImGui hovering (#202)" {
    RecordingGui.begin();
    var h: Harness = .{};
    h.start(event(&.{.{ .id = 1, .x = 40, .y = 50 }}));
    h.start(event(&.{ .{ .id = 1, .x = 40, .y = 50 }, .{ .id = 2, .x = 140, .y = 50 } }));
    h.move(event(&.{ .{ .id = 1, .x = 20, .y = 50 }, .{ .id = 2, .x = 180, .y = 50 } }));
    h.end(event(&.{ .{ .id = 1, .x = 20, .y = 50, .lifted = true }, .{ .id = 2, .x = 180, .y = 50, .lifted = true } }));
    try expectPointerGone();
    try expectNoButtons();
    try std.testing.expect(h.wheel > 0);
    try std.testing.expect(!h.state.active);
}

test "a pinch that leaves one finger down keeps ImGui tracking it" {
    RecordingGui.begin();
    var h: Harness = .{};
    h.start(event(&.{.{ .id = 1, .x = 40, .y = 50 }}));
    h.start(event(&.{ .{ .id = 1, .x = 40, .y = 50 }, .{ .id = 2, .x = 140, .y = 50 } }));
    h.end(event(&.{ .{ .id = 1, .x = 40, .y = 50, .lifted = true }, .{ .id = 2, .x = 140, .y = 50 } }));
    try std.testing.expectEqual(Call{ .pos = .{ .x = 140, .y = 50 } }, RecordingGui.last());
    try std.testing.expect(h.state.active);
    // That finger lifting too ends the touch.
    h.end(event(&.{.{ .id = 2, .x = 140, .y = 50, .lifted = true }}));
    try expectPointerGone();
    try expectNoButtons();
}

test "a fast tap clicks at the lift point, then the pointer goes" {
    RecordingGui.begin();
    var h: Harness = .{};
    h.start(event(&.{.{ .id = 7, .x = 30, .y = 60 }}));
    h.end(event(&.{.{ .id = 7, .x = 30, .y = 60, .lifted = true }}));
    try std.testing.expectEqualSlices(Call, &.{
        .{ .pos = .{ .x = 30, .y = 60 } },
        .{ .button = .{ .button = 0, .down = true } },
        .{ .button = .{ .button = 0, .down = false } },
        .{ .pos = .{ .x = gui_pointer.absent, .y = gui_pointer.absent } },
    }, RecordingGui.log());
    try std.testing.expect(h.pressed and h.released);
}

test "a held touch presses on the next frame and releases on lift" {
    RecordingGui.begin();
    var h: Harness = .{};
    h.start(event(&.{.{ .id = 7, .x = 30, .y = 60 }}));
    h.frame();
    try std.testing.expect(h.down);
    h.move(event(&.{.{ .id = 7, .x = 35, .y = 60 }}));
    h.end(event(&.{.{ .id = 7, .x = 35, .y = 60, .lifted = true }}));
    try std.testing.expectEqualSlices(Call, &.{
        .{ .pos = .{ .x = 30, .y = 60 } },
        .{ .button = .{ .button = 0, .down = true } },
        .{ .pos = .{ .x = 35, .y = 60 } },
        .{ .button = .{ .button = 0, .down = false } },
        .{ .pos = .{ .x = gui_pointer.absent, .y = gui_pointer.absent } },
    }, RecordingGui.log());
    try std.testing.expect(!h.down and h.released);
}

test "a second finger before the next frame pinches without a click" {
    RecordingGui.begin();
    var h: Harness = .{};
    h.start(event(&.{.{ .id = 1, .x = 40, .y = 50 }}));
    h.start(event(&.{ .{ .id = 1, .x = 40, .y = 50 }, .{ .id = 2, .x = 140, .y = 50 } }));
    h.frame();
    try expectNoButtons();
    try std.testing.expect(!h.down and !h.pressed);
}
