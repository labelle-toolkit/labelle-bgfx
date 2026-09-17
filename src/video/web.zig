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
extern "c" fn labelle_web_video_width(id: c_int) c_int;
extern "c" fn labelle_web_video_height(id: c_int) c_int;

/// Where a `vw`×`vh` clip sits inside the fixed frame buffer, in buffer pixels:
/// drawn "contain", exactly as `web_video.c` draws it. Unknown size (metadata
/// not loaded yet) is treated as filling the buffer.
pub fn contentRect(vw: u32, vh: u32) fit.Rectangle {
    if (vw == 0 or vh == 0) return .{ .x = 0, .y = 0, .width = @floatFromInt(FRAME_W), .height = @floatFromInt(FRAME_H) };
    return fit.fitRects(2, @floatFromInt(vw), @floatFromInt(vh), @floatFromInt(FRAME_W), @floatFromInt(FRAME_H)).dest;
}

/// `fit.fitRects` for a web clip on an `sw`×`sh` screen. The fit applies to the
/// clip's own content, not the padded buffer, so `cover`/`stretch` never show
/// the bars baked in around a non-16:9 clip. The returned `src` is in buffer
/// pixels (offset into the content rectangle), ready for `Player.drawRegion`.
pub fn fullscreenRects(fit_tag: u8, vw: u32, vh: u32, sw: f32, sh: f32) fit.FitRects {
    const c = contentRect(vw, vh);
    var r = fit.fitRects(fit_tag, c.width, c.height, sw, sh);
    r.src.x += c.x;
    r.src.y += c.y;
    return r;
}

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

    /// The clip's intrinsic size, or null until the browser has its metadata.
    pub fn intrinsicSize(self: *const VideoDecoder) ?struct { w: u32, h: u32 } {
        const w = labelle_web_video_width(self.id);
        const h = labelle_web_video_height(self.id);
        if (w <= 0 or h <= 0) return null;
        return .{ .w = @intCast(w), .h = @intCast(h) };
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

test "content rect: a 4:3 clip occupies the pillarboxed middle of the buffer" {
    const c = contentRect(640, 480);
    try std.testing.expectApproxEqAbs(@as(f32, 160), c.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), c.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 960), c.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 720), c.height, 0.01);
}

test "content rect: unknown size (no metadata yet) is the whole buffer" {
    const c = contentRect(0, 0);
    try std.testing.expectEqual(@as(f32, 0), c.x);
    try std.testing.expectEqual(@as(f32, 1280), c.width);
    try std.testing.expectEqual(@as(f32, 720), c.height);
}

test "fullscreen cover: a 4:3 clip on a 16:9 screen crops the clip, never the baked bars" {
    const r = fullscreenRects(1, 640, 480, 1280, 720);
    // Fills the screen.
    try std.testing.expectEqual(@as(f32, 1280), r.dest.width);
    try std.testing.expectEqual(@as(f32, 720), r.dest.height);
    // The source stays inside the content rect [160, 1120] x [0, 720]: full
    // content width, height cropped to the screen aspect (960 / (16/9) = 540).
    try std.testing.expectApproxEqAbs(@as(f32, 160), r.src.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 960), r.src.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 540), r.src.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), r.src.y, 0.01);
}

test "fullscreen stretch: a 4:3 clip stretches its content, not the padded buffer" {
    const r = fullscreenRects(0, 640, 480, 1280, 720);
    try std.testing.expectApproxEqAbs(@as(f32, 160), r.src.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 960), r.src.width, 0.01);
    try std.testing.expectEqual(@as(f32, 1280), r.dest.width);
}

test "fullscreen: a 16:9 clip matches the plain buffer fit (FP's intro)" {
    for ([_]u8{ 0, 1, 2 }) |tag| {
        const web_r = fullscreenRects(tag, 1920, 1080, 1024, 768);
        const buf_r = fit.fitRects(tag, 1280, 720, 1024, 768);
        try std.testing.expectApproxEqAbs(buf_r.src.x, web_r.src.x, 0.01);
        try std.testing.expectApproxEqAbs(buf_r.src.width, web_r.src.width, 0.01);
        try std.testing.expectApproxEqAbs(buf_r.dest.y, web_r.dest.y, 0.01);
        try std.testing.expectApproxEqAbs(buf_r.dest.height, web_r.dest.height, 0.01);
    }
}
