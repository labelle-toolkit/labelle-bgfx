//! Non-text game shortcuts that must not trigger browser navigation.
const std = @import("std");
pub fn key(code: []const u8) ?u32 {
    if (std.mem.eql(u8, code, "F5")) return 294;
    if (std.mem.eql(u8, code, "F8")) return 297;
    if (std.mem.eql(u8, code, "F9")) return 298;
    return null;
}
pub fn capture(code: []const u8, modified: bool) bool {
    return !modified and key(code) != null;
}
test "save, restart and load map to engine keys without consuming text or modified browser shortcuts" {
    try std.testing.expectEqual(@as(?u32, 294), key("F5"));
    try std.testing.expectEqual(@as(?u32, 297), key("F8"));
    try std.testing.expectEqual(@as(?u32, 298), key("F9"));
    try std.testing.expect(capture("F5", false));
    try std.testing.expect(capture("F9", false));
    try std.testing.expect(!capture("F5", true));
    try std.testing.expect(!capture("KeyA", false));
    try std.testing.expect(!capture("F12", false));
}
