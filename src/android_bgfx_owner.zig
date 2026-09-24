/// Which NativeActivity instance owns the bgfx context (labelle-bgfx#143).
///
/// Android can create a SECOND activity instance inside a process whose first
/// instance is still alive: `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK`,
/// a launcher relaunch of a cached task, "don't keep activities". Each instance
/// gets its own `android_native_app_glue` app thread running `run()`, and the
/// old one is only paused when the new one starts; it is stopped and destroyed
/// (sometimes seconds) later.
///
/// bgfx, though, is one per process and thread-affine: `bgfx.init` makes the
/// calling thread the API thread (a thread-local), and every later call,
/// `bgfx.shutdown` included, must come from that thread. So the new instance
/// can neither use the old instance's context nor create its own until the OLD
/// thread has shut the context down. Before this arbiter the shell kept its
/// state in process globals, so the new thread saw the old instance's
/// "bgfx is up" flag, ticked a frame and hit bgfx's
/// "Must be called from main thread" assert.
///
/// The rules this type enforces:
///   * At most one instance owns bgfx. Only the owner may init, draw or shut
///     it down, and only on its own app thread.
///   * The NEWEST instance wins. A newer claimant asks the owner to yield (the
///     shell then wakes the owner's looper so it tears bgfx down on its own
///     thread); an older claimant just waits, so two instances with windows
///     never hand the context back and forth.
///   * Releasing is always done by the owner itself (`release`/`end`), never
///     by the claimant.
///
/// Pure bookkeeping: no locking (the shell holds its mutex around every
/// call), no Android types, so it runs as an ordinary host test.
const std = @import("std");

/// `Id` identifies one activity instance; the shell uses its `*android_app`.
pub fn Arbiter(comptime Id: type) type {
    return struct {
        const Self = @This();

        /// Instance currently holding the bgfx context, and its generation.
        owner: ?Id = null,
        owner_gen: u64 = 0,
        /// A newer instance is waiting for `owner` to let go.
        yield_requested: bool = false,
        /// The newest instance that asked for bgfx and has not got it yet.
        /// Reserves the context across the gap between the old owner's
        /// release and the claimant's next retry, so the old owner (which
        /// still has a window until it is stopped) cannot grab it back.
        pending: ?Id = null,
        pending_gen: u64 = 0,
        next_gen: u64 = 1,

        pub const Claim = enum {
            /// The caller now owns bgfx and must bring it up.
            granted,
            /// The caller already owned it; nothing to do.
            already_owner,
            /// An older instance holds it and has been asked to yield. The
            /// caller must wake the owner's thread and retry later.
            requested_yield,
            /// A NEWER instance holds it. Wait without asking.
            wait,
        };

        /// An instance's `run()` started. Returns its generation, which the
        /// instance passes to `claim`.
        pub fn begin(self: *Self) u64 {
            const gen = self.next_gen;
            self.next_gen += 1;
            return gen;
        }

        /// An instance's `run()` is returning. The caller must already have
        /// torn bgfx down if it owned it; this only forgets the instance.
        pub fn end(self: *Self, id: Id) void {
            self.withdraw(id);
            self.release(id);
        }

        pub fn claim(self: *Self, id: Id, gen: u64) Claim {
            const owner = self.owner orelse {
                // Free, but reserved for a newer claimant: let it retry.
                if (self.pending) |p| if (p != id and self.pending_gen > gen) return .wait;
                self.owner = id;
                self.owner_gen = gen;
                self.yield_requested = false;
                self.withdraw(id);
                return .granted;
            };
            if (owner == id) return .already_owner;
            if (self.owner_gen > gen) return .wait;
            self.yield_requested = true;
            if (self.pending == null or gen >= self.pending_gen) {
                self.pending = id;
                self.pending_gen = gen;
            }
            return .requested_yield;
        }

        /// `id` no longer wants bgfx (its window went away before the
        /// handoff landed). Drops its reservation; an owner that was already
        /// asked to yield still does, which merely costs it a surface cycle.
        pub fn withdraw(self: *Self, id: Id) void {
            if (self.pending == id) {
                self.pending = null;
                self.pending_gen = 0;
            }
        }

        /// True when `id` owns bgfx and a newer instance is waiting for it.
        pub fn shouldYield(self: *const Self, id: Id) bool {
            return self.owner == id and self.yield_requested;
        }

        /// `id` has shut bgfx down. A no-op for a non-owner, so a stale
        /// instance can never drop someone else's claim.
        pub fn release(self: *Self, id: Id) void {
            if (self.owner != id) return;
            self.owner = null;
            self.owner_gen = 0;
            self.yield_requested = false;
        }

        pub fn isOwner(self: *const Self, id: Id) bool {
            return self.owner == id;
        }
    };
}

// ── Tests ────────────────────────────────────────────────────────────
const testing = std.testing;
const A = Arbiter(u32);

test "a lone instance claims, keeps and releases bgfx" {
    var a: A = .{};
    const g1 = a.begin();
    try testing.expectEqual(A.Claim.granted, a.claim(1, g1));
    try testing.expectEqual(A.Claim.already_owner, a.claim(1, g1));
    try testing.expect(a.isOwner(1));
    try testing.expect(!a.shouldYield(1));
    a.release(1);
    try testing.expect(!a.isOwner(1));
    // A surface cycle (TERM_WINDOW then INIT_WINDOW) re-claims cleanly.
    try testing.expectEqual(A.Claim.granted, a.claim(1, g1));
}

test "a second instance in the same process waits for the first to yield (#143)" {
    var a: A = .{};
    const g_old = a.begin();
    try testing.expectEqual(A.Claim.granted, a.claim(1, g_old));

    // New activity instance starts while the old one still owns bgfx.
    const g_new = a.begin();
    try testing.expect(g_new > g_old);
    try testing.expectEqual(A.Claim.requested_yield, a.claim(2, g_new));
    try testing.expect(!a.isOwner(2));
    try testing.expect(a.shouldYield(1));

    // Retrying before the owner let go still does not grant.
    try testing.expectEqual(A.Claim.requested_yield, a.claim(2, g_new));

    // The old thread tears bgfx down and releases. It still has a window
    // (it is only paused), and its loop retries first: the context is
    // reserved for the newer claimant, so the old one must keep waiting.
    a.release(1);
    try testing.expectEqual(A.Claim.wait, a.claim(1, g_old));
    try testing.expectEqual(A.Claim.granted, a.claim(2, g_new));
    try testing.expect(a.pending == null);
    try testing.expect(!a.shouldYield(2));

    // The old instance, released and later destroyed, must not touch the
    // new owner's claim.
    a.release(1);
    a.end(1);
    try testing.expect(a.isOwner(2));
}

test "an older instance never takes bgfx back from a newer one" {
    var a: A = .{};
    const g_old = a.begin();
    const g_new = a.begin();
    try testing.expectEqual(A.Claim.granted, a.claim(2, g_new));
    // The old instance still has a window (it is only paused): it waits, and
    // does NOT ask the newer owner to yield, so there is no ping-pong.
    try testing.expectEqual(A.Claim.wait, a.claim(1, g_old));
    try testing.expect(!a.shouldYield(2));
    // Once the newer one is gone, the older one may have it.
    a.end(2);
    try testing.expectEqual(A.Claim.granted, a.claim(1, g_old));
}

test "a claimant that loses its window gives up its reservation" {
    var a: A = .{};
    const g_old = a.begin();
    try testing.expectEqual(A.Claim.granted, a.claim(1, g_old));
    const g_new = a.begin();
    try testing.expectEqual(A.Claim.requested_yield, a.claim(2, g_new));
    // The new instance's window goes away before the handoff lands.
    a.withdraw(2);
    a.release(1); // the old owner still yields, as it was asked to
    // Nothing is reserved any more, so the old instance may re-acquire.
    try testing.expectEqual(A.Claim.granted, a.claim(1, g_old));
}

test "end frees the claim, and a later instance starts from scratch" {
    var a: A = .{};
    const g1 = a.begin();
    try testing.expectEqual(A.Claim.granted, a.claim(1, g1));
    a.end(1);
    try testing.expect(a.owner == null);
    // A later instance in the same (cached) process starts from scratch.
    const g2 = a.begin();
    try testing.expect(g2 > g1);
    try testing.expectEqual(A.Claim.granted, a.claim(2, g2));
}
