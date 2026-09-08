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
//! ## What the chunk loop actually buys — and what it does not
//!
//! It submits the largest whole-triangle PREFIX that currently fits, then drops
//! and reports the rest. It does **not** recover capacity by submitting:
//! bgfx's transient buffer is a single per-frame arena reclaimed at `bgfx.frame`,
//! and `submit` does not give any of it back. So a second round sees LESS
//! headroom than the first, never more, and a starved batch converges on the
//! drop path rather than draining. The loop shape is what makes the partial
//! submission safe and terminating; it is not a way to fit more geometry into a
//! full frame. To actually fit more, raise the transient VB size at init or
//! submit less per frame — which is what the drop warning says.
//!
//! Chunking is a prefix split, and that is deliberate: **triangle order is
//! preserved**. Alpha-blended geometry is order-dependent — painter's-algorithm
//! output changes if triangles are reordered or interleaved — so chunks are cut
//! at ascending offsets and submitted in sequence, and a dropped remainder is
//! always a suffix. What must NOT happen is splitting *inside* a triangle:
//! every chunk is rounded down to a multiple of three vertices.
//!
//! ## The two invariants worth stating
//!
//! 1. **Progress.** `nextTriangleChunk` returns either `null` or a value `>= 3`.
//!    A caller looping `while (offset < total)` therefore advances by at least
//!    one triangle per iteration and cannot spin — including when the budget
//!    shrinks to nothing, which is the realistic case.
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

test "nextTriangleChunk: a drain loop terminates when the budget never replenishes" {
    // The realistic exhaustion shape. bgfx's transient arena is per-FRAME:
    // `submit` returns none of it, so each round sees strictly less headroom.
    // Modelling `avail` as a fixed number would quietly assert the opposite —
    // a ring that refills — and would pass even if the guard could spin.
    //
    // Here the budget is consumed by what we submit, so the loop must submit a
    // prefix and then hit the drop path, never loop forever and never advance
    // past `total`.
    for ([_]u32{ 0, 2, 3, 7, 99, 150, 300, 4096 }) |initial_budget| {
        const total: u32 = 300;
        var budget = initial_budget;
        var offset: u32 = 0;
        var rounds: u32 = 0;
        var dropped: u32 = 0;

        while (offset < total) {
            const remaining = total - offset;
            const chunk = nextTriangleChunk(remaining, budget) orelse {
                dropped = remaining;
                break;
            };
            try testing.expect(chunk > 0); // strict progress
            try testing.expect(chunk <= budget); // never over-draws the arena
            offset += chunk;
            budget -= chunk; // submit does NOT give it back
            rounds += 1;
            try testing.expect(rounds <= 128);
        }

        // Everything is accounted for: submitted + dropped == total.
        try testing.expectEqual(total, offset + dropped);
        // And we never submitted more than the arena ever held.
        try testing.expect(offset <= initial_budget);
        // A budget that cannot seat one triangle submits nothing at all.
        if (initial_budget < VERTS_PER_TRI) try testing.expectEqual(@as(u32, 0), offset);
        // One round is the common case: the first chunk takes the whole prefix.
        if (initial_budget >= total) try testing.expectEqual(@as(u32, 1), rounds);
    }
}

test "nextTriangleChunk: the dropped remainder is always a suffix (order preserved)" {
    // Alpha-blended triangles are order-dependent, so a partial submission has
    // to be a PREFIX — dropping from the middle would reorder what survives.
    const total: u32 = 30;
    var budget: u32 = 13; // seats 4 triangles (12 verts), not 5
    var offset: u32 = 0;
    while (offset < total) {
        const chunk = nextTriangleChunk(total - offset, budget) orelse break;
        offset += chunk;
        budget -= chunk;
    }
    try testing.expectEqual(@as(u32, 12), offset); // 4 whole triangles, in order
    // The survivors are vertices [0, 12) — a prefix — and [12, 30) is dropped.
    try testing.expect(offset % VERTS_PER_TRI == 0);
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
