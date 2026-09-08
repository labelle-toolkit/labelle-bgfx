//! Transient-buffer budgeting for the triangle submit paths (labelle-assembler#648).
//!
//! bgfx's transient vertex buffer is a per-frame ring. `allocTransientVertexBuffer`
//! does NOT fail gracefully when the ring is short: it asserts in Debug and hands
//! back a truncated/garbage buffer in release, which is how a heavy frame turns
//! into silently missing geometry. The documented bgfx pattern is to ask
//! `getAvailTransientVertexBuffer` FIRST and submit only what fits.
//!
//! This module is the pure arithmetic half of that pattern, kept free of any
//! `zbgfx` import so it EXECUTES on the host under `zig build test` — the same
//! split `src/gfx/state.zig` uses for the coordinate math. `programs.zig` owns
//! the bgfx calls; everything here is decidable from two integers.
//!
//! ## Why chunking rather than dropping
//!
//! A triangle list is order-independent across triangles, so a batch that does
//! not fit whole can be submitted in pieces across several `alloc`+`submit`
//! rounds. What must NOT happen is splitting *inside* a triangle: every chunk is
//! rounded down to a multiple of three vertices, so a chunk is always a whole
//! number of triangles.
//!
//! ## The two invariants worth stating
//!
//! 1. **Progress.** `nextTriangleChunk` returns either `null` or a value `>= 3`.
//!    A caller looping `while (offset < total)` therefore advances by at least
//!    one triangle per iteration and cannot spin. This is the property that
//!    turns "guard the alloc" into "guard the alloc without inventing a hang".
//! 2. **Containment.** The returned count never exceeds `remaining`, so
//!    `vertices[offset..][0..chunk]` is always in bounds.

const std = @import("std");

/// Vertices per triangle in a non-indexed triangle list.
pub const VERTS_PER_TRI: u32 = 3;

/// Largest whole-triangle chunk that can be submitted right now.
///
/// `remaining` — vertices still unsubmitted in this batch.
/// `avail`     — what `bgfx.getAvailTransientVertexBuffer` reports.
///
/// Returns `null` when not even one triangle fits, which is the caller's signal
/// to drop the remainder and report it. Any non-null result is a multiple of
/// `VERTS_PER_TRI`, at least `VERTS_PER_TRI`, and at most `remaining`.
pub fn nextTriangleChunk(remaining: u32, avail: u32) ?u32 {
    const usable = @min(remaining, avail);
    const whole = usable - (usable % VERTS_PER_TRI);
    if (whole == 0) return null;
    return whole;
}

/// Whole-batch guard for submissions that cannot be split — a full-screen quad,
/// a YUV triangle pair, an indexed mesh. Either all of it fits or none is drawn.
pub fn fits(need: u32, avail: u32) bool {
    return avail >= need;
}

/// Warn-once bookkeeping for dropped geometry.
///
/// The failure this ticket is about is *silence*, so the point of this type is
/// that the first drop is loud. It is also deliberately rate-limited to once
/// per instance: a starved frame drops geometry in a loop, and a log line per
/// dropped batch would bury the signal it exists to provide. The running totals
/// stay accurate regardless of whether a line was printed.
pub const DropLog = struct {
    warned: bool = false,
    /// Vertices dropped since process start (saturating).
    dropped_vertices: u64 = 0,
    /// Distinct drop events since process start (saturating).
    drop_events: u64 = 0,

    /// Record a drop of `count` vertices. Returns true exactly once — on the
    /// first drop — so the caller can log without repeating itself.
    pub fn note(self: *DropLog, count: u32) bool {
        self.dropped_vertices +|= count;
        self.drop_events +|= 1;
        if (self.warned) return false;
        self.warned = true;
        return true;
    }

    /// Test/diagnostic helper: forget that we warned.
    pub fn reset(self: *DropLog) void {
        self.* = .{};
    }
};

// ── Tests ─────────────────────────────────────────────────────────────
// These are the regression tests for #648. They encode the two invariants
// above, because those are what keep the fix from trading a silent drop for a
// hang or an out-of-bounds copy.

const testing = std.testing;

test "nextTriangleChunk: whole batch fits when avail is generous" {
    try testing.expectEqual(@as(?u32, 300), nextTriangleChunk(300, 4096));
    try testing.expectEqual(@as(?u32, 3), nextTriangleChunk(3, 3));
}

test "nextTriangleChunk: short ring yields a whole-triangle chunk" {
    // 100 vertices available => 33 triangles => 99 vertices, not 100.
    try testing.expectEqual(@as(?u32, 99), nextTriangleChunk(300, 100));
    try testing.expectEqual(@as(?u32, 3), nextTriangleChunk(300, 5));
}

test "nextTriangleChunk: returns null when not even one triangle fits" {
    try testing.expectEqual(@as(?u32, null), nextTriangleChunk(300, 0));
    try testing.expectEqual(@as(?u32, null), nextTriangleChunk(300, 1));
    try testing.expectEqual(@as(?u32, null), nextTriangleChunk(300, 2));
    try testing.expectEqual(@as(?u32, null), nextTriangleChunk(0, 4096));
}

test "nextTriangleChunk: never exceeds remaining (no out-of-bounds copy)" {
    var remaining: u32 = 0;
    while (remaining <= 64) : (remaining += 1) {
        var avail: u32 = 0;
        while (avail <= 64) : (avail += 1) {
            if (nextTriangleChunk(remaining, avail)) |chunk| {
                try testing.expect(chunk <= remaining);
                try testing.expect(chunk <= avail);
                try testing.expectEqual(@as(u32, 0), chunk % VERTS_PER_TRI);
                try testing.expect(chunk >= VERTS_PER_TRI);
            }
        }
    }
}

test "nextTriangleChunk: a drain loop always terminates (no infinite chunking)" {
    // The property that matters: every non-null chunk advances the cursor, so
    // a fixed `avail` cannot make the caller spin. Iteration cap is a tripwire,
    // not an expectation — 300 verts at 3/chunk needs 100 rounds.
    for ([_]u32{ 3, 4, 5, 6, 7, 99, 100, 4096 }) |avail| {
        const total: u32 = 300;
        var offset: u32 = 0;
        var rounds: u32 = 0;
        while (offset < total) {
            const chunk = nextTriangleChunk(total - offset, avail) orelse break;
            try testing.expect(chunk > 0); // strict progress
            offset += chunk;
            rounds += 1;
            try testing.expect(rounds <= 128);
        }
        try testing.expectEqual(total, offset); // fully drained, nothing lost
    }
}

test "nextTriangleChunk: a non-multiple-of-3 batch drops only the ragged tail" {
    // A malformed batch (not a whole triangle list) must not wedge the loop:
    // it drains the whole triangles and reports the 2-vertex remainder.
    const total: u32 = 11; // 3 triangles + 2 stray vertices
    var offset: u32 = 0;
    var rounds: u32 = 0;
    while (offset < total) {
        const chunk = nextTriangleChunk(total - offset, 4096) orelse break;
        offset += chunk;
        rounds += 1;
        try testing.expect(rounds <= 8);
    }
    try testing.expectEqual(@as(u32, 9), offset);
    try testing.expectEqual(@as(u32, 2), total - offset);
}

test "fits: exact capacity counts as fitting" {
    try testing.expect(fits(6, 6));
    try testing.expect(fits(6, 7));
    try testing.expect(!fits(6, 5));
    try testing.expect(!fits(6, 0));
    try testing.expect(fits(0, 0));
}

test "DropLog: warns exactly once but keeps counting" {
    var log: DropLog = .{};
    try testing.expect(log.note(30));
    try testing.expect(!log.note(12));
    try testing.expect(!log.note(3));
    try testing.expectEqual(@as(u64, 45), log.dropped_vertices);
    try testing.expectEqual(@as(u64, 3), log.drop_events);

    log.reset();
    try testing.expectEqual(@as(u64, 0), log.dropped_vertices);
    try testing.expect(log.note(1)); // warns again after a reset
}

test "DropLog: totals saturate rather than wrap" {
    var log: DropLog = .{};
    log.dropped_vertices = std.math.maxInt(u64) - 1;
    log.drop_events = std.math.maxInt(u64);
    _ = log.note(std.math.maxInt(u32));
    try testing.expectEqual(std.math.maxInt(u64), log.dropped_vertices);
    try testing.expectEqual(std.math.maxInt(u64), log.drop_events);
}
