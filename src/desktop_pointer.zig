//! Where the desktop pointer is, and which button events a frame carries
//! (labelle-engine#938).
//!
//! GLFW reports the pointer two ways. Polling (`getCursorPos`) reads the
//! operating system's pointer. Events (the cursor-position callback) carry the
//! position the event itself was sent with. For a person at the mouse the two
//! agree. For input sent to the window by a tool they do not: an automation
//! or accessibility tool, or a remote session, moves no OS pointer, so a
//! click it sends would land wherever the person's real pointer happens to
//! rest. The backend only polled, so such clicks hit the wrong widget, or
//! nothing at all.
//!
//! `Pointer` keeps the OS pointer as the truth whenever it moves over the
//! window, so a person at the mouse sees no change. A position that arrives
//! as an event while the OS pointer is not moving over the window is taken as
//! sent, and held until the OS pointer moves over the window again.
//!
//! `Buttons` keeps the button events of a frame in the order they came, with
//! their edges, so a press and its release that both arrive between two
//! frames are still one click. Polling the button's level alone misses it
//! (the wasm path's accumulators in `input.zig` exist for the same reason).
const std = @import("std");

pub const Pos = struct { x: f64, y: f64 };

/// The pointer's position, in the window's logical coordinates.
pub const Pointer = struct {
    /// The OS pointer as polled last frame; null before the first frame.
    polled: ?Pos = null,
    /// The latest cursor event since the last `settle`.
    event: ?Pos = null,
    /// The position in effect.
    pos: Pos = .{ .x = 0, .y = 0 },
    /// `pos` came from an event and holds until the OS pointer moves over
    /// the window.
    held: bool = false,

    /// A cursor-position event (GLFW's callback).
    pub fn moved(self: *Pointer, x: f64, y: f64) void {
        self.event = .{ .x = x, .y = y };
    }

    /// Once a frame, after the events were pumped: the position in effect,
    /// given the OS pointer `polled` and the window's logical size.
    pub fn settle(self: *Pointer, polled: Pos, width: f64, height: f64) Pos {
        const prev = self.polled;
        const event = self.event;
        self.polled = polled;
        self.event = null;

        const os_moved_over_window = if (prev) |p|
            (p.x != polled.x or p.y != polled.y) and
                (inside(p, width, height) or inside(polled, width, height))
        else
            // The first frame has nothing to compare with: start from the OS.
            true;

        if (os_moved_over_window) {
            self.held = false;
        } else if (event) |e| {
            // Only a position over the window is held. One outside it (a drag
            // that left the window) is the OS pointer's own, which polling
            // follows better once the drag ends.
            self.held = inside(e, width, height);
            if (self.held) self.pos = e;
        }
        if (!self.held) self.pos = polled;
        return self.pos;
    }

    fn inside(p: Pos, width: f64, height: f64) bool {
        return p.x >= 0 and p.y >= 0 and p.x < width and p.y < height;
    }
};

/// The button events of one frame, as GLFW's mouse-button callback sent them.
pub fn Buttons(comptime button_count: usize) type {
    return struct {
        const Self = @This();

        pub const Event = struct { button: u8, down: bool };
        /// More events than this in one frame keep their edges but are not
        /// replayed one by one.
        pub const max_events = 16;

        events: [max_events]Event = undefined,
        count: usize = 0,
        pressed: [button_count]bool = [_]bool{false} ** button_count,
        released: [button_count]bool = [_]bool{false} ** button_count,

        /// A button went down or up.
        pub fn record(self: *Self, button: usize, down: bool) void {
            if (button >= button_count) return;
            if (down) self.pressed[button] = true else self.released[button] = true;
            if (self.count == max_events) return;
            self.events[self.count] = .{ .button = @intCast(button), .down = down };
            self.count += 1;
        }

        /// The events since the last `clear`, in the order they came.
        pub fn ordered(self: *const Self) []const Event {
            return self.events[0..self.count];
        }

        /// The frame took them: start the next one empty.
        pub fn clear(self: *Self) void {
            self.count = 0;
            self.pressed = [_]bool{false} ** button_count;
            self.released = [_]bool{false} ** button_count;
        }
    };
}

/// A button's edges for the frame: what the callback saw since the last
/// frame, or a change of the polled level since then (a release outside the
/// window can arrive with no event).
pub const Edges = struct { pressed: bool, released: bool };

pub fn edges(event_pressed: bool, event_released: bool, down: bool, down_prev: bool) Edges {
    return .{
        .pressed = event_pressed or (down and !down_prev),
        .released = event_released or (!down and down_prev),
    };
}

const W: f64 = 900;
const H: f64 = 768;

test "a person at the mouse: the position follows the OS pointer" {
    var p: Pointer = .{};
    try std.testing.expectEqual(Pos{ .x = 100, .y = 100 }, p.settle(.{ .x = 100, .y = 100 }, W, H));
    // Its own events arrive a little behind the poll: the poll wins.
    p.moved(118, 100);
    try std.testing.expectEqual(Pos{ .x = 120, .y = 100 }, p.settle(.{ .x = 120, .y = 100 }, W, H));
    // Resting, with no event: still the OS pointer.
    try std.testing.expectEqual(Pos{ .x = 120, .y = 100 }, p.settle(.{ .x = 120, .y = 100 }, W, H));
}

test "a position sent to the window is taken while the OS pointer rests" {
    // Measured on macOS (labelle-engine#938): the tool's move said (540,548),
    // the OS pointer rested at (502,558), and the click came 7 frames later.
    var p: Pointer = .{};
    _ = p.settle(.{ .x = 502, .y = 558 }, W, H);
    p.moved(540, 548);
    try std.testing.expectEqual(Pos{ .x = 540, .y = 548 }, p.settle(.{ .x = 502, .y = 558 }, W, H));
    for (0..7) |_| {
        try std.testing.expectEqual(Pos{ .x = 540, .y = 548 }, p.settle(.{ .x = 502, .y = 558 }, W, H));
    }
}

test "a sent position holds while the person works in another window" {
    var p: Pointer = .{};
    _ = p.settle(.{ .x = 1500, .y = 300 }, W, H);
    p.moved(330, 558);
    _ = p.settle(.{ .x = 1500, .y = 300 }, W, H);
    // Their pointer moves about, never over this window.
    try std.testing.expectEqual(Pos{ .x = 330, .y = 558 }, p.settle(.{ .x = 1620, .y = 340 }, W, H));
    try std.testing.expectEqual(Pos{ .x = 330, .y = 558 }, p.settle(.{ .x = -40, .y = 900 }, W, H));
}

test "the OS pointer moving over the window takes the position back" {
    var p: Pointer = .{};
    _ = p.settle(.{ .x = 1500, .y = 300 }, W, H);
    p.moved(330, 558);
    _ = p.settle(.{ .x = 1500, .y = 300 }, W, H);
    // In from outside.
    try std.testing.expectEqual(Pos{ .x = 880, .y = 300 }, p.settle(.{ .x = 880, .y = 300 }, W, H));
    try std.testing.expectEqual(Pos{ .x = 700, .y = 310 }, p.settle(.{ .x = 700, .y = 310 }, W, H));
    // And out again: the position leaves with it, so nothing stays hovered.
    try std.testing.expectEqual(Pos{ .x = 950, .y = 310 }, p.settle(.{ .x = 950, .y = 310 }, W, H));
    try std.testing.expectEqual(Pos{ .x = 1200, .y = 310 }, p.settle(.{ .x = 1200, .y = 310 }, W, H));
}

test "the OS pointer moving over the window wins over a position sent the same frame" {
    var p: Pointer = .{};
    _ = p.settle(.{ .x = 100, .y = 100 }, W, H);
    p.moved(540, 548);
    try std.testing.expectEqual(Pos{ .x = 104, .y = 100 }, p.settle(.{ .x = 104, .y = 100 }, W, H));
}

test "a drag that leaves the window is followed by the OS pointer" {
    var p: Pointer = .{};
    _ = p.settle(.{ .x = 890, .y = 300 }, W, H);
    // Out over the edge: the OS pointer moved from inside.
    p.moved(915, 300);
    try std.testing.expectEqual(Pos{ .x = 920, .y = 300 }, p.settle(.{ .x = 920, .y = 300 }, W, H));
    // Dragging on outside: the events' positions are not held.
    p.moved(955, 300);
    try std.testing.expectEqual(Pos{ .x = 960, .y = 300 }, p.settle(.{ .x = 960, .y = 300 }, W, H));
    // Let go, and moved on with no events: still the OS pointer.
    try std.testing.expectEqual(Pos{ .x = 1300, .y = 500 }, p.settle(.{ .x = 1300, .y = 500 }, W, H));
}

test "a press and its release between two frames are still one click" {
    var b: Buttons(8) = .{};
    b.record(0, true);
    b.record(0, false);
    // The polled level never showed the button down.
    const e = edges(b.pressed[0], b.released[0], false, false);
    try std.testing.expect(e.pressed and e.released);
    try std.testing.expectEqualSlices(Buttons(8).Event, &.{
        .{ .button = 0, .down = true },
        .{ .button = 0, .down = false },
    }, b.ordered());

    b.clear();
    const none = edges(b.pressed[0], b.released[0], false, false);
    try std.testing.expect(!none.pressed and !none.released);
    try std.testing.expectEqual(@as(usize, 0), b.ordered().len);
}

test "a press held over frames is one press edge, then one release edge" {
    var b: Buttons(8) = .{};
    b.record(1, true);
    var e = edges(b.pressed[1], b.released[1], true, false);
    try std.testing.expect(e.pressed and !e.released);
    b.clear();
    // Held: no event, the level unchanged.
    e = edges(b.pressed[1], b.released[1], true, true);
    try std.testing.expect(!e.pressed and !e.released);
    b.record(1, false);
    e = edges(b.pressed[1], b.released[1], false, true);
    try std.testing.expect(!e.pressed and e.released);
}

test "a level change with no event still gives its edge" {
    // The button came up outside the window, with no event for it.
    const e = edges(false, false, false, true);
    try std.testing.expect(!e.pressed and e.released);
}

test "buttons out of range and events past the cap are not replayed" {
    var b: Buttons(8) = .{};
    b.record(8, true);
    try std.testing.expectEqual(@as(usize, 0), b.ordered().len);
    for (0..Buttons(8).max_events + 4) |i| b.record(0, i % 2 == 0);
    try std.testing.expectEqual(Buttons(8).max_events, b.ordered().len);
    // Their edges are kept all the same.
    try std.testing.expect(b.pressed[0] and b.released[0]);
}
