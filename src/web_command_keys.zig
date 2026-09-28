//! Non-text game shortcuts that must not trigger browser navigation.
const std = @import("std");

/// Modifier state of a browser `KeyboardEvent`.
pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false,

    /// Any modifier at all, Shift included. A modified F5/F8/F9 is a browser
    /// shortcut (hard reload, etc.) and never a game command.
    pub fn any(m: Mods) bool {
        return m.ctrl or m.shift or m.alt or m.meta;
    }

    /// A shortcut-forming modifier. Shift alone is not one for Backspace:
    /// it is routinely still held after typing an uppercase character.
    pub fn shortcut(m: Mods) bool {
        return m.ctrl or m.alt or m.meta;
    }
};

pub fn key(code: []const u8) ?u32 {
    if (std.mem.eql(u8, code, "F5")) return 294;
    if (std.mem.eql(u8, code, "F8")) return 297;
    if (std.mem.eql(u8, code, "F9")) return 298;
    return null;
}

fn slot(code: []const u8) ?usize {
    return switch (key(code) orelse return null) {
        294 => 0,
        297 => 1,
        298 => 2,
        else => unreachable,
    };
}

/// Tracks which command keys had their keydown ACCEPTED as a game command, so
/// the matching keyup is only reported (and forwarded to ImGui) for those. A
/// modified keydown is ignored; its keyup must be ignored too, whatever the
/// modifier state at release time.
pub const Gate = struct {
    accepted: [3]bool = .{ false, false, false },

    /// Whether this keydown reaches engine/ImGui key state. Non-command keys
    /// always do. A fresh command keydown is accepted only when unmodified;
    /// auto-repeats keep the decision of the original press.
    pub fn down(g: *Gate, code: []const u8, mods: Mods, repeat: bool) bool {
        const i = slot(code) orelse return true;
        if (!repeat) g.accepted[i] = !mods.any();
        return g.accepted[i];
    }

    /// Whether this keyup reaches engine/ImGui key state. For a command key it
    /// is true only when its keydown was accepted; consumes that acceptance.
    pub fn up(g: *Gate, code: []const u8) bool {
        const i = slot(code) orelse return true;
        const was = g.accepted[i];
        g.accepted[i] = false;
        return was;
    }

    /// Focus loss: every held key is released without a keyup.
    pub fn reset(g: *Gate) void {
        g.accepted = .{ false, false, false };
    }
};

/// Whether the browser default action is suppressed (`preventDefault`).
/// `accepted` is the command-key gate decision for this event.
pub fn capture(code: []const u8, mods: Mods, accepted: bool) bool {
    // Accepted F5/F8/F9 are game commands; modified ones stay browser shortcuts.
    if (key(code) != null) return accepted;
    // ImGui edits canvas text fields, not DOM inputs. WebKit otherwise treats
    // Backspace as history back (and Shift-Backspace as forward), so capture
    // it regardless of Shift; Ctrl/Alt/Meta combos stay with the browser.
    if (std.mem.eql(u8, code, "Backspace")) return !mods.shortcut();
    return false;
}

test "save, restart and load map to engine keys without consuming text or modified browser shortcuts" {
    try std.testing.expectEqual(@as(?u32, 294), key("F5"));
    try std.testing.expectEqual(@as(?u32, 297), key("F8"));
    try std.testing.expectEqual(@as(?u32, 298), key("F9"));
    try std.testing.expect(capture("F5", .{}, true));
    try std.testing.expect(capture("F9", .{}, true));
    try std.testing.expect(!capture("F5", .{ .ctrl = true }, false));
    try std.testing.expect(!capture("KeyA", .{}, true));
    try std.testing.expect(!capture("F12", .{}, true));
}

test "Backspace is captured with or without Shift, but not with Ctrl/Alt/Meta" {
    try std.testing.expect(capture("Backspace", .{}, true));
    try std.testing.expect(capture("Backspace", .{ .shift = true }, true));
    try std.testing.expect(!capture("Backspace", .{ .ctrl = true }, true));
    try std.testing.expect(!capture("Backspace", .{ .alt = true }, true));
    try std.testing.expect(!capture("Backspace", .{ .meta = true }, true));
    try std.testing.expect(!capture("Backspace", .{ .shift = true, .meta = true }, true));
}

test "a modified command keydown suppresses its keyup even if the modifier is released first" {
    var g: Gate = .{};
    inline for (.{ Mods{ .ctrl = true }, Mods{ .shift = true }, Mods{ .alt = true }, Mods{ .meta = true } }) |m| {
        try std.testing.expect(!g.down("F5", m, false));
        try std.testing.expect(!g.down("F5", .{}, true)); // repeat keeps the rejection
        try std.testing.expect(!g.up("F5"));
        try std.testing.expect(!capture("F5", .{}, false));
    }
}

test "an accepted command keydown reports its keyup exactly once" {
    var g: Gate = .{};
    try std.testing.expect(g.down("F9", .{}, false));
    try std.testing.expect(g.down("F9", .{ .ctrl = true }, true)); // repeat keeps acceptance
    try std.testing.expect(!g.down("F8", .{ .shift = true }, false)); // independent per key
    try std.testing.expect(g.up("F9")); // released with or without modifiers held
    try std.testing.expect(!g.up("F9")); // unmatched keyup
    try std.testing.expect(!g.up("F8"));
    // Non-command keys always pass through, modified or not.
    try std.testing.expect(g.down("KeyA", .{ .ctrl = true }, false));
    try std.testing.expect(g.up("KeyA"));
    // Focus loss forgets acceptance.
    try std.testing.expect(g.down("F5", .{}, false));
    g.reset();
    try std.testing.expect(!g.up("F5"));
}
