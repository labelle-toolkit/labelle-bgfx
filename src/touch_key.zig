//! Browser touch identifiers as tracking keys (labelle-bgfx#187).
//!
//! Emscripten stores `Touch.identifier` in an `i32` (`EmscriptenTouchPoint`).
//! The DOM only promises the identifier is unique per active touch; it says
//! nothing about its sign. iOS Safari hands out large NEGATIVE values
//! (`-690324876`, then `-690324875`, …), so an `@intCast` to an unsigned type
//! traps on every touch in safety-checked builds (the web build is
//! ReleaseSafe). Treat the identifier as opaque bits instead: reinterpret the
//! `i32` as `u32`, then widen to the `u64` the tracked `touch_id` uses. The
//! mapping is injective, so distinct touches keep distinct keys, and
//! non-negative identifiers (desktop browsers, Android Chrome) keep their value.
const std = @import("std");

/// The tracking key for a browser touch identifier. Every place that stores
/// or compares a touch identifier must go through this, so the stored key and
/// the keys of later events for the same finger always match.
pub fn touchKey(identifier: i32) u64 {
    return @as(u32, @bitCast(identifier));
}

test "the identifier iOS Safari reported maps to its u32 bits instead of trapping" {
    try std.testing.expectEqual(@as(u64, 3604642420), touchKey(-690324876));
}

test "edge identifiers map to their u32 bit patterns" {
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF), touchKey(-1));
    try std.testing.expectEqual(@as(u64, 0), touchKey(0));
    try std.testing.expectEqual(@as(u64, 1), touchKey(1));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(i32)), touchKey(std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(u64, 0x8000_0000), touchKey(std.math.minInt(i32)));
}

test "a negative identifier stored on touchstart matches the same finger on move and end" {
    // Mirrors input.zig: touchstart stores `touchKey(id)` in `touch_id`, and
    // touchmove/touchend find the primary by comparing `touchKey(t.identifier)`.
    const start_id: i32 = -690324876;
    const tracked = touchKey(start_id);
    const move_id: i32 = -690324876;
    const end_id: i32 = -690324876;
    try std.testing.expect(touchKey(move_id) == tracked);
    try std.testing.expect(touchKey(end_id) == tracked);
    // The next finger iOS reports (id + 1) is a different touch.
    try std.testing.expect(touchKey(start_id + 1) != tracked);
}

test "no two identifiers share a key" {
    // Negative identifiers land above maxInt(i32), so they never collide with
    // a non-negative one.
    try std.testing.expect(touchKey(-1) != touchKey(std.math.maxInt(i32)));
    try std.testing.expect(touchKey(std.math.minInt(i32)) != touchKey(0));
    try std.testing.expect(touchKey(-690324876) != touchKey(690324876));
}
