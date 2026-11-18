//! Per-material diagnostics for game-owned shader materials (labelle-bgfx#217).
//!
//! A procedural fragment shader's cost is its per-pixel work times the pixels
//! it covers, and on a mobile GPU the second factor decides. Nothing showed
//! either: `--profile` times scripts on the CPU. Finding that Flying
//! Platform's drone blast (~1,300 sin/cos per pixel over a big quad) held a
//! tablet at ~13 fps took a hand-built on-device A/B. Two knobs make that a
//! knob flip instead, both opt-in and read once when bgfx starts
//! (`device_knobs`: environment, or a debuggable Android APK's knob file):
//!
//!   * `LABELLE_BGFX_MATERIAL_STATS=<frames>`: every that many frames, log one
//!     line per material drawn: draws and screen pixels covered per frame
//!     (average and worst frame). Logged at `err` level so a ReleaseFast
//!     build, which drops lower levels, still shows it; it is off unless
//!     asked for.
//!   * `LABELLE_BGFX_MATERIAL_SKIP=<label>[,<label>...]`: draw nothing for
//!     those materials, so a device run shows what the game costs without
//!     them, with no game change.
//!
//! Pixels are each draw's screen-space area (its normalized-device quad,
//! clipped to the screen, times the physical backbuffer size). A draw into a
//! smaller render target is counted at backbuffer scale: a cost estimate,
//! not a measurement.

const std = @import("std");
const knobs = @import("device_knobs.zig");

const log = std.log.scoped(.material_stats);

pub const stats_knob = "LABELLE_BGFX_MATERIAL_STATS";
pub const skip_knob = "LABELLE_BGFX_MATERIAL_SKIP";

/// Most distinct materials tracked; later ones are counted under "(other)".
const max_tracked = 64;
const max_label = 32;

const Entry = struct {
    program: u16,
    label: [max_label]u8 = undefined,
    label_len: usize = 0,
    draws: u64 = 0,
    pixels: f64 = 0,
    frame_pixels: f64 = 0,
    worst_frame_pixels: f64 = 0,
};

var period: u32 = 0;
var skip_buf: [256]u8 = undefined;
var skip_list: []const u8 = &.{};
var entries: [max_tracked]Entry = undefined;
var entry_count: usize = 0;
var other: Entry = .{ .program = 0xffff };
var frames: u32 = 0;

/// Read both knobs. Called when a bgfx context starts.
pub fn configure() void {
    knobs.load();
    period = if (knobs.get(stats_knob)) |v| std.fmt.parseInt(u32, v, 10) catch 0 else 0;
    const skip = knobs.get(skip_knob) orelse "";
    const n = @min(skip.len, skip_buf.len);
    @memcpy(skip_buf[0..n], skip[0..n]);
    skip_list = skip_buf[0..n];
    reset();
    if (period != 0) log.err("material stats every {d} frames", .{period});
    if (skip_list.len != 0) log.err("materials skipped: {s}", .{skip_list});
}

fn reset() void {
    entry_count = 0;
    other = .{ .program = 0xffff };
    frames = 0;
}

pub fn enabled() bool {
    return period != 0;
}

/// Is `label` on the skip list? Decided once per program.
pub fn skipped(label: []const u8) bool {
    return listed(skip_list, label);
}

pub fn listed(list: []const u8, label: []const u8) bool {
    if (label.len == 0) return false;
    var it = std.mem.tokenizeAny(u8, list, ", ");
    while (it.next()) |name| if (std.mem.eql(u8, name, label)) return true;
    return false;
}

/// Screen-space pixels covered by `ndc` triangles (x, y pairs, three per
/// triangle), each vertex clamped to the screen, on a `w` x `h` backbuffer.
pub fn pixelArea(ndc: []const [2]f32, w: f32, h: f32) f64 {
    var area: f64 = 0;
    var i: usize = 0;
    while (i + 2 < ndc.len) : (i += 3) {
        const a = clamp(ndc[i]);
        const b = clamp(ndc[i + 1]);
        const c = clamp(ndc[i + 2]);
        area += @abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])) / 2.0;
    }
    // NDC spans 2 units on each axis.
    return area * (w / 2.0) * (h / 2.0);
}

fn clamp(p: [2]f32) [2]f64 {
    return .{ std.math.clamp(p[0], -1, 1), std.math.clamp(p[1], -1, 1) };
}

/// Count one draw of `program` (`label`) covering `pixels`.
pub fn record(program: u16, label: []const u8, pixels: f64) void {
    if (period == 0) return;
    const e = find(program, label);
    e.draws += 1;
    e.pixels += pixels;
    e.frame_pixels += pixels;
}

fn find(program: u16, label: []const u8) *Entry {
    for (entries[0..entry_count]) |*e| if (e.program == program) return e;
    if (entry_count == max_tracked) return &other;
    const e = &entries[entry_count];
    entry_count += 1;
    e.* = .{ .program = program };
    e.label_len = @min(label.len, max_label);
    @memcpy(e.label[0..e.label_len], label[0..e.label_len]);
    return e;
}

/// End of a presented frame: close the frame's totals, and report and reset
/// every `period` frames.
pub fn frameEnd() void {
    if (period == 0) return;
    for (entries[0..entry_count]) |*e| closeFrame(e);
    closeFrame(&other);
    frames += 1;
    if (frames < period) return;
    const n: f64 = @floatFromInt(frames);
    log.err("material stats over {d} frames:", .{frames});
    for (entries[0..entry_count]) |*e| report(e.label[0..e.label_len], e, n);
    if (other.draws != 0) report("(other)", &other, n);
    reset();
}

fn closeFrame(e: *Entry) void {
    e.worst_frame_pixels = @max(e.worst_frame_pixels, e.frame_pixels);
    e.frame_pixels = 0;
}

fn report(label: []const u8, e: *const Entry, n: f64) void {
    const draws: f64 = @floatFromInt(e.draws);
    log.err("  {s}: {d:.1} draws/frame, {d:.2} Mpx/frame (worst frame {d:.2} Mpx)", .{
        if (label.len == 0) "<unlabelled>" else label,
        draws / n,
        e.pixels / n / 1e6,
        e.worst_frame_pixels / 1e6,
    });
}

const testing = std.testing;

test "pixel area of a full-screen quad is the backbuffer, clipped beyond it" {
    const full = [_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    try testing.expectApproxEqAbs(@as(f64, 2000 * 1200), pixelArea(&full, 2000, 1200), 0.5);
    const big = [_][2]f32{ .{ -3, -3 }, .{ 3, -3 }, .{ 3, 3 }, .{ -3, -3 }, .{ 3, 3 }, .{ -3, 3 } };
    try testing.expectApproxEqAbs(@as(f64, 2000 * 1200), pixelArea(&big, 2000, 1200), 0.5);
    const quarter = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    try testing.expectApproxEqAbs(@as(f64, 1000 * 600), pixelArea(&quarter, 2000, 1200), 0.5);
}

test "the skip list matches whole labels, comma or space separated" {
    try testing.expect(listed("turbine_burn,turbine_fire", "turbine_fire"));
    try testing.expect(listed(" turbine_burn  room_lamp ", "room_lamp"));
    try testing.expect(!listed("turbine_burn", "turbine"));
    try testing.expect(!listed("", "x"));
    try testing.expect(!listed("a", ""));
}

test "stats count per program and report every period" {
    period = 2;
    defer period = 0;
    reset();
    record(5, "smoke", 100);
    record(5, "smoke", 50);
    record(6, "fire", 10);
    frameEnd();
    try testing.expectEqual(@as(usize, 2), entry_count);
    try testing.expectEqual(@as(u64, 2), entries[0].draws);
    try testing.expectEqual(@as(f64, 150), entries[0].worst_frame_pixels);
    try testing.expectEqual(@as(f64, 10), entries[1].worst_frame_pixels);
}
