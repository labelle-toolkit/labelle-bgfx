//! Android key events → what an imgui text field needs: the GLFW keycode
//! (the bridge's `imgui_bridge_key` speaks GLFW, as desktop does) and the
//! typed character for `imgui_bridge_char`.
//!
//! The on-screen keyboard's text arrives through labelle-android's
//! `LabelleActivity` (`text_input.poll`, accents included). What still comes
//! as plain `AKeyEvent`s is mapped here: a hardware keyboard, and the keys an
//! on-screen keyboard sends as keys (Backspace, Enter/Done, arrows). The NDK
//! can't ask the framework for a key's character (`KeyEvent.getUnicodeChar`
//! is Java-only), so letters, digits and the common punctuation are mapped on
//! a US layout.
//!
//! Pure (no NDK symbols), so it is unit-tested on the host.

const std = @import("std");

/// `AMETA_SHIFT_ON` and `AMETA_CAPS_LOCK_ON` (android/input.h).
pub const META_SHIFT_ON: i32 = 0x01;
pub const META_CAPS_LOCK_ON: i32 = 0x100000;

pub const Mapped = struct {
    /// GLFW keycode, for imgui's key events (Backspace, Enter, arrows…).
    key: i32,
    /// The typed character, 0 for a key that types nothing.
    char: u21 = 0,
};

// GLFW keycodes (glfw3.h) for the non-printable keys.
const GLFW_ENTER = 257;
const GLFW_TAB = 258;
pub const GLFW_BACKSPACE = 259;
const GLFW_DELETE = 261;
const GLFW_RIGHT = 262;
const GLFW_LEFT = 263;
const GLFW_DOWN = 264;
const GLFW_UP = 265;
const GLFW_HOME = 268;
const GLFW_END = 269;
const GLFW_KP_ENTER = 335;

// AKEYCODE_* (android/keycodes.h).
const AKEYCODE_0 = 7;
const AKEYCODE_9 = 16;
const AKEYCODE_A = 29;
const AKEYCODE_Z = 54;

/// The text-field meaning of `keycode` under `meta`, or null for a key a
/// text field doesn't use (volume, BACK, gamepad buttons…), which then
/// keeps its usual path.
pub fn map(keycode: i32, meta: i32) ?Mapped {
    const shift = (meta & META_SHIFT_ON) != 0;
    if (keycode >= AKEYCODE_A and keycode <= AKEYCODE_Z) {
        const i: u21 = @intCast(keycode - AKEYCODE_A);
        const upper = shift != ((meta & META_CAPS_LOCK_ON) != 0);
        const base: u21 = if (upper) 'A' else 'a';
        return .{ .key = 'A' + @as(i32, i), .char = base + i };
    }
    if (keycode >= AKEYCODE_0 and keycode <= AKEYCODE_9) {
        const i: usize = @intCast(keycode - AKEYCODE_0);
        return .{ .key = '0' + @as(i32, @intCast(i)), .char = if (shift) ")!@#$%^&*("[i] else '0' + @as(u21, @intCast(i)) };
    }
    return switch (keycode) {
        62 => .{ .key = ' ', .char = ' ' }, // SPACE
        55 => .{ .key = ',', .char = if (shift) '<' else ',' }, // COMMA
        56 => .{ .key = '.', .char = if (shift) '>' else '.' }, // PERIOD
        69 => .{ .key = '-', .char = if (shift) '_' else '-' }, // MINUS
        70 => .{ .key = '=', .char = if (shift) '+' else '=' }, // EQUALS
        71 => .{ .key = '[', .char = if (shift) '{' else '[' }, // LEFT_BRACKET
        72 => .{ .key = ']', .char = if (shift) '}' else ']' }, // RIGHT_BRACKET
        73 => .{ .key = '\\', .char = if (shift) '|' else '\\' }, // BACKSLASH
        74 => .{ .key = ';', .char = if (shift) ':' else ';' }, // SEMICOLON
        75 => .{ .key = '\'', .char = if (shift) '"' else '\'' }, // APOSTROPHE
        76 => .{ .key = '/', .char = if (shift) '?' else '/' }, // SLASH
        68 => .{ .key = '`', .char = if (shift) '~' else '`' }, // GRAVE
        77 => .{ .key = '2', .char = '@' }, // AT
        81 => .{ .key = '=', .char = '+' }, // PLUS
        17 => .{ .key = '8', .char = '*' }, // STAR
        18 => .{ .key = '3', .char = '#' }, // POUND
        67 => .{ .key = GLFW_BACKSPACE }, // DEL (backspace)
        112 => .{ .key = GLFW_DELETE }, // FORWARD_DEL
        66 => .{ .key = GLFW_ENTER }, // ENTER (the keyboard's Done too)
        160 => .{ .key = GLFW_KP_ENTER }, // NUMPAD_ENTER
        61 => .{ .key = GLFW_TAB }, // TAB
        21 => .{ .key = GLFW_LEFT }, // DPAD_LEFT
        22 => .{ .key = GLFW_RIGHT }, // DPAD_RIGHT
        19 => .{ .key = GLFW_UP }, // DPAD_UP
        20 => .{ .key = GLFW_DOWN }, // DPAD_DOWN
        122 => .{ .key = GLFW_HOME }, // MOVE_HOME
        123 => .{ .key = GLFW_END }, // MOVE_END
        else => null,
    };
}

test "letters follow shift and caps lock" {
    try std.testing.expectEqual(Mapped{ .key = 'A', .char = 'a' }, map(29, 0).?);
    try std.testing.expectEqual(Mapped{ .key = 'Z', .char = 'Z' }, map(54, META_SHIFT_ON).?);
    try std.testing.expectEqual(Mapped{ .key = 'Q', .char = 'Q' }, map(45, META_CAPS_LOCK_ON).?);
    try std.testing.expectEqual(Mapped{ .key = 'Q', .char = 'q' }, map(45, META_CAPS_LOCK_ON | META_SHIFT_ON).?);
}

test "digits and their shifted symbols" {
    try std.testing.expectEqual(Mapped{ .key = '0', .char = '0' }, map(7, 0).?);
    try std.testing.expectEqual(Mapped{ .key = '9', .char = '9' }, map(16, 0).?);
    try std.testing.expectEqual(Mapped{ .key = '1', .char = '!' }, map(8, META_SHIFT_ON).?);
    try std.testing.expectEqual(Mapped{ .key = '0', .char = ')' }, map(7, META_SHIFT_ON).?);
}

test "editing keys type nothing" {
    try std.testing.expectEqual(Mapped{ .key = GLFW_BACKSPACE }, map(67, 0).?);
    try std.testing.expectEqual(Mapped{ .key = GLFW_ENTER }, map(66, 0).?);
    try std.testing.expectEqual(Mapped{ .key = ' ', .char = ' ' }, map(62, 0).?);
}

test "keys a text field doesn't use stay unmapped" {
    try std.testing.expect(map(4, 0) == null); // BACK
    try std.testing.expect(map(24, 0) == null); // VOLUME_UP
    try std.testing.expect(map(96, 0) == null); // BUTTON_A
}
