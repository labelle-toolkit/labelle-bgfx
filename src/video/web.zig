//! WebVideoDecoder — the wasm decoder behind `video/player.zig`.
//!
//! The browser decodes the clip in a hidden, muted `<video>` element (see
//! `web_video.c` for the JS half and why); this side satisfies the `Player`
//! decoder contract (`width`/`height`/`decodeFrame`/`eof`/`replay`/`deinit`) by
//! copying the element's newest frame as RGBA into the player's buffer. The
//! player's CPU RGBA path then uploads and draws it like any native frame.
//!
//! The element owns timing: `clock` exposes its `currentTime` so the player
//! paces by it (`Player.setAudio(.{ .clock = … })`) instead of the frame `dt`.

const std = @import("std");
const fit = @import("fit.zig");

/// Fixed RGBA frame size. The player sizes its texture when the clip is opened,
/// before the browser knows the clip's dimensions, so frames are drawn
/// "contain" into this buffer. MUST match `FRAME_W`/`FRAME_H` in `web_video.c`.
pub const FRAME_W: u32 = 1280;
pub const FRAME_H: u32 = 720;

extern "c" fn labelle_web_video_open(url: [*:0]const u8) c_int;
extern "c" fn labelle_web_video_frame(id: c_int, ptr: [*]u8, len: c_int) f64;
extern "c" fn labelle_web_video_time(id: c_int) f64;
extern "c" fn labelle_web_video_done(id: c_int) c_int;
extern "c" fn labelle_web_video_restart(id: c_int) void;
extern "c" fn labelle_web_video_close(id: c_int) void;

pub const VideoDecoder = struct {
    id: c_int,

    /// Start loading and (muted) playing `url`. Returns immediately: frames
    /// arrive as the browser downloads and decodes. Null only when the page has
    /// no DOM to create a `<video>` in.
    pub fn open(url: [*:0]const u8) ?VideoDecoder {
        const id = labelle_web_video_open(url);
        if (id <= 0) return null;
        return .{ .id = id };
    }

    pub fn width(_: *const VideoDecoder) u32 {
        return FRAME_W;
    }

    pub fn height(_: *const VideoDecoder) u32 {
        return FRAME_H;
    }

    /// Copy the newest frame into `rgba` (FRAME_W*FRAME_H*4 bytes) and return
    /// its presentation time in seconds, or null when no newer frame exists yet.
    pub fn decodeFrame(self: *VideoDecoder, rgba: []u8) ?f64 {
        const t = labelle_web_video_frame(self.id, rgba.ptr, @intCast(rgba.len));
        return if (t < 0) null else t;
    }

    /// True once the clip is over: played to the end, or failed in a bounded way
    /// (load/decode error, autoplay refused, stalled) — never a hang.
    pub fn eof(self: *const VideoDecoder) bool {
        return labelle_web_video_done(self.id) != 0;
    }

    pub fn replay(self: *VideoDecoder, _: std.mem.Allocator) void {
        labelle_web_video_restart(self.id);
    }

    pub fn deinit(self: *VideoDecoder) void {
        labelle_web_video_close(self.id);
    }

    /// `AudioHooks.clock` for this decoder: the element's playback position.
    /// `ctx` carries the decoder id.
    pub fn clock(ctx: ?*anyopaque) f64 {
        return labelle_web_video_time(@intCast(@intFromPtr(ctx)));
    }

    pub fn clockCtx(self: *const VideoDecoder) ?*anyopaque {
        return @ptrFromInt(@as(usize, @intCast(self.id)));
    }
};

// ── Tests (host) ───────────────────────────────────────────────────────────
// The JS draws the clip into the fixed buffer with the same "contain" geometry
// as `fit.fitRects(2, …)`. These pin that geometry for the shapes that matter.

test {
    _ = fit;
}

test "web frame buffer is 16:9, so FP's 1920x1080 intro fills it with no bars" {
    const r = fit.fitRects(2, 1920, 1080, FRAME_W, FRAME_H);
    try std.testing.expectEqual(@as(f32, 0), r.dest.x);
    try std.testing.expectEqual(@as(f32, 0), r.dest.y);
    try std.testing.expectApproxEqAbs(@as(f32, 1280), r.dest.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 720), r.dest.height, 0.01);
}

test "a 4:3 clip is pillarboxed inside the web frame buffer, not stretched" {
    const r = fit.fitRects(2, 640, 480, FRAME_W, FRAME_H);
    // scale = min(1280/640, 720/480) = 1.5 → 960x720, 160 px bars each side.
    try std.testing.expectApproxEqAbs(@as(f32, 960), r.dest.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 720), r.dest.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 160), r.dest.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.dest.y, 0.01);
}
