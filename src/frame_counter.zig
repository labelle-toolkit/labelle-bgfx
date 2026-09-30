//! Presented-frame counter (labelle-bgfx#182, RFC #172 D11).
//!
//! Counts the frames submitted via `bgfx.frame()` since the last successful
//! `bgfx.init`. `window.zig` calls `reset()` whenever a bgfx context comes up
//! (every init path, including Android surface-restore re-inits) or goes down
//! (`bgfx.shutdown`), and `presented()` after each per-frame `bgfx.frame()`.
//!
//! The value is exported over the C ABI as `labelle_bgfx_frames_presented` on
//! every platform. A host (e.g. labelle-android's crash guard) resolves it at
//! runtime with `dlsym(RTLD_DEFAULT, "labelle_bgfx_frames_presented")` and
//! reads it from its own thread — hence the atomic. Monotonic ordering is
//! enough: readers only need an eventually-visible count, not ordering against
//! other memory.
//!
//! Only `window.zig` may import this file: it owns a process-wide global and
//! an exported symbol, so it must be compiled into exactly one module.
const std = @import("std");

/// A counter instance. The process-wide one is `global`; tests use their own.
pub const Counter = struct {
    value: std.atomic.Value(u64) = .init(0),

    /// A frame was submitted via `bgfx.frame()`.
    pub fn presented(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// A bgfx context came up (successful `bgfx.init`) or went down
    /// (`bgfx.shutdown`): start counting from zero again.
    pub fn reset(self: *Counter) void {
        self.value.store(0, .monotonic);
    }

    pub fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }
};

/// The process-wide counter behind `labelle_bgfx_frames_presented`.
pub var global: Counter = .{};

/// Number of frames submitted via `bgfx.frame()` since the last successful
/// `bgfx.init` (reset to 0 on every init, including surface-restore re-inits,
/// and after `bgfx.shutdown`). C ABI, exported on every platform; safe to call
/// from any thread.
export fn labelle_bgfx_frames_presented() callconv(.c) u64 {
    return global.get();
}

test "starts at zero" {
    var c: Counter = .{};
    try std.testing.expectEqual(@as(u64, 0), c.get());
}

test "presented increments by one per frame" {
    var c: Counter = .{};
    c.presented();
    try std.testing.expectEqual(@as(u64, 1), c.get());
    for (0..119) |_| c.presented();
    try std.testing.expectEqual(@as(u64, 120), c.get());
}

test "reset (init / shutdown) returns the count to zero and counting resumes" {
    var c: Counter = .{};
    for (0..42) |_| c.presented();
    c.reset(); // e.g. surface-restore re-init
    try std.testing.expectEqual(@as(u64, 0), c.get());
    c.presented();
    try std.testing.expectEqual(@as(u64, 1), c.get());
}

test "exported symbol reads the global counter" {
    global.reset();
    defer global.reset();
    global.presented();
    global.presented();
    try std.testing.expectEqual(@as(u64, 2), labelle_bgfx_frames_presented());
    global.reset();
    try std.testing.expectEqual(@as(u64, 0), labelle_bgfx_frames_presented());
}
