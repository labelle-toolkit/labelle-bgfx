//! Where Dear ImGui should see a touch pointer (labelle-bgfx#202).
//!
//! On touch the pointer only exists while a finger is down. Once it lifts,
//! ImGui must be told the mouse is gone — its convention is a position of
//! `-FLT_MAX` — or it keeps hovering the lift point: tooltips stay open and
//! the last-tapped button stays highlighted until the next touch elsewhere.
//! The frame that carries the release must still report the real position,
//! or ImGui would not register the click on the item under the finger, so the
//! pointer goes away only from the frame after the release.
const std = @import("std");

/// ImGui's "no mouse" coordinate (`-FLT_MAX`).
pub const absent: f32 = -std.math.floatMax(f32);

pub const Pos = struct { x: f32, y: f32 };

/// The position to feed ImGui for a touch pointer at (`x`, `y`) that is
/// `down` this frame and was `down_prev` the frame before.
pub fn touchPos(down: bool, down_prev: bool, x: f32, y: f32) Pos {
    if (!down and !down_prev) return .{ .x = absent, .y = absent };
    return .{ .x = x, .y = y };
}

/// Whether a touch end with `fingers_left` still down removes the pointer.
/// A pinch whose fingers all lift together ends with no tracked pointer, yet
/// the hover must still go; while a finger stays, ImGui keeps tracking it.
pub fn clearsOnTouchEnd(fingers_left: usize) bool {
    return fingers_left == 0;
}

test "a finger on the screen is reported where it is" {
    try std.testing.expectEqual(Pos{ .x = 10, .y = 20 }, touchPos(true, false, 10, 20));
    try std.testing.expectEqual(Pos{ .x = 10, .y = 20 }, touchPos(true, true, 10, 20));
}

test "the release frame keeps the lift point so the tap still clicks" {
    try std.testing.expectEqual(Pos{ .x = 10, .y = 20 }, touchPos(false, true, 10, 20));
}

test "after the release frame the pointer is gone" {
    try std.testing.expectEqual(Pos{ .x = absent, .y = absent }, touchPos(false, false, 10, 20));
}

test "a touch end that leaves no finger down clears the pointer (pinch end)" {
    try std.testing.expect(clearsOnTouchEnd(0));
}

test "a touch end with a finger still down keeps the pointer" {
    try std.testing.expect(!clearsOnTouchEnd(1));
    try std.testing.expect(!clearsOnTouchEnd(2));
}
