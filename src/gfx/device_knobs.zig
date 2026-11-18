//! `LABELLE_*` knobs the backend reads for itself (labelle-bgfx#217): the
//! process environment first, then, on Android, the debuggable APK's
//! `files/labelle_env` knob file.
//!
//! The generated Android main reads that file too, but only forwards the
//! knobs it knows (fixed dt, screenshot). Diagnostics knobs such as
//! `LABELLE_BGFX_MATERIAL_STATS` would need a template change per knob, so
//! the backend reads the file itself, with the main's gate: the RUNNING apk
//! must be debuggable (`android_app.isDebuggable`), so a file left behind by a
//! debuggable build is ignored by a release build installed over it.
//!
//!     adb shell run-as <package> sh -c \
//!       'printf "LABELLE_BGFX_MATERIAL_STATS=120\n" > files/labelle_env'

const std = @import("std");
const builtin = @import("builtin");

const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
/// Exported by `android_app.zig` (C symbols, so the gfx module doesn't import
/// the shell). Only referenced on Android.
extern fn labelle_bgfx_internal_data_path() ?[*:0]const u8;
extern fn labelle_bgfx_is_debuggable() bool;

var file_buf: [4096]u8 = undefined;
var file_text: []const u8 = &.{};
var file_loaded = false;

/// Read the knob file once (Android, debuggable only). Call from the thread
/// that inits bgfx, before the knobs are read anywhere else.
pub fn load() void {
    if (file_loaded) return;
    file_loaded = true;
    if (comptime !is_android) return;
    if (!labelle_bgfx_is_debuggable()) return;
    const dir = labelle_bgfx_internal_data_path() orelse return;
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/labelle_env", .{std.mem.span(dir)}) catch return;
    const file = std.c.fopen(path.ptr, "rb") orelse return;
    defer _ = std.c.fclose(file);
    const n = std.c.fread(&file_buf, 1, file_buf.len, file);
    file_text = file_buf[0..n];
}

/// The knob's value, or null when unset or empty.
pub fn get(name: [*:0]const u8) ?[]const u8 {
    if (getenv(name)) |raw| {
        const v = std.mem.trim(u8, std.mem.span(raw), " \t");
        if (v.len != 0) return v;
    }
    return fromText(file_text, std.mem.span(name));
}

/// `KEY=VALUE` lines, `#` comments, first match wins (as `window.knobFromText`).
pub fn fromText(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), name)) continue;
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        return if (v.len == 0) null else v;
    }
    return null;
}

test "the knob file parse: first match, comments, blanks and empty values" {
    const text = "# c\n\nLABELLE_BGFX_MATERIAL_STATS = 120\nLABELLE_BGFX_MATERIAL_STATS=5\nLABELLE_BGFX_MATERIAL_SKIP=\n";
    try std.testing.expectEqualStrings("120", fromText(text, "LABELLE_BGFX_MATERIAL_STATS").?);
    try std.testing.expect(fromText(text, "LABELLE_BGFX_MATERIAL_SKIP") == null);
    try std.testing.expect(fromText(text, "LABELLE_BGFX_MATERIAL") == null);
}
