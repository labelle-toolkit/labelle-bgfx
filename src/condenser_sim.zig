//! Deterministic drop/impact timing for the COND-07 example (+Y down).
const std = @import("std");

pub const width = 103;
pub const height = 55;
pub const basin_x: f32 = 4;
pub const basin_y: f32 = 48;
pub const basin_width = 93;
pub const basin_height = 6;
pub const emitter_x = [_]f32{ 25, 32, 47, 55, 69 };
pub const period: f32 = 2.4;
pub const fall_seconds: f32 = 0.95;
pub const ripple_seconds: f32 = 1.3;
pub const wave_amplitude: f32 = 0.6;
pub const wave_period: f32 = 3.8;
pub const ripple_radius: f32 = 9;
pub const ripple_strength: f32 = 1.2;

pub const Drop = struct { x: f32, head_y: f32 };
pub const Impact = struct { x: f32, start_time: f32 };
pub const Frame = struct {
    drops: [5]Drop = undefined,
    drop_count: usize = 0,
    impacts: [5]Impact = undefined,
    impact_count: usize = 0,
};

pub fn surfaceY(level: f32) f32 {
    return basin_y + basin_height * (1 - std.math.clamp(level, 0, 1));
}

/// Each emitter has its own staggered clock. The same fall endpoint creates
/// the impact; sampling a late frame cannot lose contacts or create duplicates.
pub fn sample(time: f32, level: f32) Frame {
    var frame: Frame = .{};
    for (emitter_x, 0..) |x, i| {
        const offset = @as(f32, @floatFromInt(i)) * 0.37;
        const local = time - offset;
        if (local < 0) continue;
        const cycle = @floor(local / period);
        const release = offset + cycle * period;
        // During the next fall the previous cycle's ripple may still be alive.
        var impact_time = release + fall_seconds;
        if (impact_time > time) impact_time -= period;
        if (impact_time >= offset and time - impact_time < ripple_seconds and level > 0) {
            frame.impacts[frame.impact_count] = .{ .x = x - basin_x, .start_time = impact_time };
            frame.impact_count += 1;
        }
    }
    for (emitter_x, 0..) |x, i| {
        const local = time - @as(f32, @floatFromInt(i)) * 0.37;
        if (local < 0) continue;
        const age = local - @floor(local / period) * period;
        if (age >= fall_seconds) continue;
        const progress = age / fall_seconds;
        const contact_y = surfaceAt(time, x - basin_x, level, frame.impacts[0..frame.impact_count]);
        frame.drops[frame.drop_count] = .{ .x = x, .head_y = 5 + (contact_y - 5) * progress * progress };
        frame.drop_count += 1;
    }
    return frame;
}

/// Mirrors the shipped shader's grid-1 displacement and cell-centre coverage.
/// Drops and splash glints meet the visible surface, including existing ripples.
pub fn surfaceAt(time: f32, x: f32, level: f32, impacts: []const Impact) f32 {
    const cell_x = @floor(x) + 0.5;
    const tau = 2 * std.math.pi;
    var displacement = wave_amplitude * @sin(tau * (time / wave_period + cell_x / 16));
    for (impacts) |impact| {
        const age = time - impact.start_time;
        if (age < 0 or age >= ripple_seconds) continue;
        const distance = @abs(cell_x - impact.x);
        const falloff = @max(0, 1 - distance / ripple_radius);
        displacement += ripple_strength * falloff * (1 - age / ripple_seconds) *
            @sin(tau * (distance / ripple_radius - age / ripple_seconds));
    }
    var offset = @floor(displacement + 0.5);
    if (level >= 1 - 0.000001) offset = @min(offset, 0);
    return std.math.clamp(@ceil(surfaceY(level) + offset - 0.5), basin_y, basin_y + basin_height);
}

test "drop endpoint and ripple share the measured emitter and contact time" {
    const before = sample(fall_seconds - 0.0001, 0.8);
    try std.testing.expectApproxEqAbs(surfaceAt(fall_seconds - 0.0001, 21, 0.8, &.{}), before.drops[0].head_y, 0.02);
    const at = sample(fall_seconds, 0.8);
    try std.testing.expectEqual(@as(usize, 1), at.impact_count);
    try std.testing.expectEqual(@as(f32, 21), at.impacts[0].x);
    try std.testing.expectEqual(fall_seconds, at.impacts[0].start_time);
    for (at.drops[0..at.drop_count]) |drop| try std.testing.expect(drop.x != emitter_x[0]);
}

test "skipping frames preserves bounded impacts and expiry" {
    const late = sample(240.96, 0.8);
    try std.testing.expect(late.impact_count > 0);
    try std.testing.expect(late.impact_count <= emitter_x.len);
    for (late.impacts[0..late.impact_count]) |impact| {
        try std.testing.expect(impact.x >= 0 and impact.x < basin_width);
        try std.testing.expect(240.96 - impact.start_time < ripple_seconds);
    }
    const expired = sample(fall_seconds + ripple_seconds + 0.01, 0.8);
    for (expired.impacts[0..expired.impact_count]) |impact| try std.testing.expect(impact.start_time != fall_seconds);
    try std.testing.expectEqual(@as(usize, 0), sample(1.0, 0).impact_count);
}

test "fill changes the drop contact plane independently of release timing" {
    const low = sample(0.5, 0.3);
    const high = sample(0.5, 0.9);
    try std.testing.expect(low.drops[0].head_y > high.drops[0].head_y);
    try std.testing.expectEqual(sample(1, 0.3).impacts[0].start_time, sample(1, 0.9).impacts[0].start_time);
}
