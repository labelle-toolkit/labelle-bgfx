//! Desktop video decoder for the in-engine video path (FP#549 Path A Half 2).
//!
//! Spawns `ffmpeg` (via libc `popen`) to decode an H.264 mp4 into a stream of
//! raw RGBA8 frames. Same decoder *interface* as the Android `AMediaCodec`
//! decoder (`width`/`height`/`decodeFrame`/`deinit`) so the platform-agnostic
//! `VideoPlayer` (`player.zig`) can drive either — ffmpeg here, MediaCodec on
//! Android — feeding frames into the same bgfx dynamic texture.
//!
//! ffmpeg runs without `-re` (decodes ahead; the OS pipe provides backpressure),
//! so the caller paces reads with its own fps timer and the render loop never
//! blocks on the pipe. ffmpeg emits raw **I420** (`-pix_fmt yuv420p`): the GPU
//! path (`decodeFramePlanes`) uploads those Y/U/V planes straight to the plane
//! textures (shader does the convert), while the CPU fallback (`decodeFrame`)
//! converts I420 → RGBA8 via `yuv.zig` — the same colour math the Android path
//! and the `fs_yuv` shader use, so all three paths match.

const std = @import("std");
const yuv = @import("yuv.zig");
const planes = @import("planes.zig");

extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn system(command: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

/// Single-quote a path for safe interpolation into a `/bin/sh` command, so paths
/// with spaces (or shell metacharacters) work and can't be an injection surface.
/// Wraps the whole path in `'…'` and escapes any embedded single quote as the
/// standard `'\''` sequence (close-quote, escaped quote, re-open-quote). Caller
/// owns the returned buffer.
fn shellQuote(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '\'');
    for (path) |c| {
        if (c == '\'') {
            try buf.appendSlice(allocator, "'\\''");
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, '\'');
    return buf.toOwnedSlice(allocator);
}

/// Probe a clip's native pixel dimensions + frame rate via `ffprobe`, so the
/// VideoBackend can open a video by name without the caller specifying a size.
/// Returns null if ffprobe is unavailable or the output can't be parsed.
pub const Info = struct { w: u32, h: u32, fps: f32 };
pub fn probe(allocator: std.mem.Allocator, path: []const u8) ?Info {
    const qpath = shellQuote(allocator, path) catch return null;
    defer allocator.free(qpath);
    const cmd = std.fmt.allocPrintSentinel(allocator,
        "ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate " ++
        "-of csv=p=0:s=x {s}",
        .{qpath}, 0) catch return null;
    defer allocator.free(cmd);
    const stream = popen(cmd.ptr, "r") orelse return null;
    defer _ = pclose(stream);
    var buf: [128]u8 = undefined;
    const n = fread(&buf, 1, buf.len - 1, stream);
    if (n == 0) return null;
    // Output like "1920x1080x24/1"
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, buf[0..n], " \n\r\t"), 'x');
    const w = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const rate = it.next() orelse return null; // "num/den"
    var rit = std.mem.splitScalar(u8, rate, '/');
    const num = std.fmt.parseFloat(f32, rit.next() orelse "24") catch 24;
    const den = std.fmt.parseFloat(f32, rit.next() orelse "1") catch 1;
    const fps = if (den > 0) num / den else 24;
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h, .fps = if (fps > 0) fps else 24 };
}

pub const VideoDecoder = struct {
    stream: *anyopaque, // libc FILE*
    w: u32,
    h: u32,
    cw: u32, // chroma plane width  (ceil(w/2))
    ch: u32, // chroma plane height (ceil(h/2))
    frame_bytes: usize, // RGBA out size = w*h*4 (decodeFrame guard)
    frame_bytes_yuv: usize, // I420 frame from ffmpeg = w*h + 2*cw*ch
    yuv: []u8, // reusable scratch for one raw I420 frame (no per-frame alloc)
    allocator: std.mem.Allocator,
    fps: f32,
    frame_index: u64 = 0, // for the nominal CFR presentation timestamp
    eof_flag: bool = false, // set once the pipe drains (stream end)
    path_buf: [512]u8 = undefined, // stored for replay() (re-spawn)
    path_len: usize = 0,

    /// Generate a self-contained H.264 test clip *with an audio track* (a 440 Hz
    /// sine), so demos need no bundled asset and can exercise the audio path.
    pub fn generateTestClip(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32) !void {
        const qpath = try shellQuote(allocator, path);
        defer allocator.free(qpath);
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -y " ++
            "-f lavfi -i testsrc2=duration=6:size={d}x{d}:rate=24 " ++
            "-f lavfi -i sine=frequency=440:duration=6 " ++
            "-c:v libx264 -pix_fmt yuv420p -c:a aac -shortest {s}",
            .{ w, h, qpath }, 0);
        defer allocator.free(cmd);
        if (system(cmd.ptr) != 0) return error.FfmpegEncodeFailed;
    }

    /// Extract the clip's audio track to a 48 kHz stereo s16 WAV — the format
    /// labelle's `audio.loadMusic` decodes. Returns error if the clip has no
    /// audio or ffmpeg fails. (Android's AMediaCodec path would decode the audio
    /// track in-process instead; see the #549 / #306 notes.)
    pub fn extractAudioWav(allocator: std.mem.Allocator, clip_path: []const u8, wav_path: []const u8) !void {
        const qclip = try shellQuote(allocator, clip_path);
        defer allocator.free(qclip);
        const qwav = try shellQuote(allocator, wav_path);
        defer allocator.free(qwav);
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -y -i {s} " ++
            "-vn -ar 48000 -ac 2 -c:a pcm_s16le {s}",
            .{ qclip, qwav }, 0);
        defer allocator.free(cmd);
        if (system(cmd.ptr) != 0) return error.FfmpegAudioExtractFailed;
    }

    /// Decode the clip's audio track to in-memory 48 kHz stereo s16 PCM
    /// (interleaved) via ffmpeg — the format `audio.loadMusicFromPcm` wants.
    /// Returns null if the clip has no audio track or ffmpeg fails. Caller owns
    /// the returned slice. (Android decodes the track in-process with
    /// AMediaCodec instead — see video/android_audio.zig.)
    pub fn decodeAudioPcm(allocator: std.mem.Allocator, path: []const u8) ?[]i16 {
        const qpath = shellQuote(allocator, path) catch return null;
        defer allocator.free(qpath);
        const cmd = std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -i {s} -vn -f s16le -ar 48000 -ac 2 pipe:1",
            .{qpath}, 0) catch return null;
        defer allocator.free(cmd);
        const stream = popen(cmd.ptr, "r") orelse return null;
        defer _ = pclose(stream);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = fread(&buf, 1, buf.len, stream);
            if (n == 0) break;
            bytes.appendSlice(allocator, buf[0..n]) catch return null;
        }
        if (bytes.items.len < 2) return null; // no audio track decoded
        const n_samples = bytes.items.len / 2;
        const out = allocator.alloc(i16, n_samples) catch return null;
        @memcpy(std.mem.sliceAsBytes(out), bytes.items[0 .. n_samples * 2]);
        return out;
    }

    /// Decode `path` into a play-once RGBA8 frame stream at `w`×`h`. `fps` is the
    /// clip's frame rate, used to derive each frame's presentation timestamp.
    /// Plays once and reports end-of-stream (`eof`) so the engine can drive loop
    /// (via `replay`) or fire the finished event — rather than ffmpeg looping
    /// internally, which would hide the stream end.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32, fps: f32) !VideoDecoder {
        const stream = try spawn(allocator, path, w, h);
        errdefer _ = pclose(stream);
        const cw = planes.chromaWidth(w);
        const ch = planes.chromaHeight(h);
        const frame_bytes_yuv = @as(usize, w) * h + 2 * @as(usize, cw) * ch;
        const scratch = try allocator.alloc(u8, frame_bytes_yuv);
        var dec = VideoDecoder{
            .stream = stream,
            .w = w,
            .h = h,
            .cw = cw,
            .ch = ch,
            .frame_bytes = @as(usize, w) * h * 4,
            .frame_bytes_yuv = frame_bytes_yuv,
            .yuv = scratch,
            .allocator = allocator,
            .fps = fps,
        };
        const n = @min(path.len, dec.path_buf.len);
        @memcpy(dec.path_buf[0..n], path[0..n]);
        dec.path_len = n;
        return dec;
    }

    fn spawn(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32) !*anyopaque {
        const qpath = try shellQuote(allocator, path);
        defer allocator.free(qpath);
        // Raw I420 (planar YUV 4:2:0): Y plane (w*h) then U then V (each cw*ch).
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -i {s} " ++
            "-f rawvideo -pix_fmt yuv420p -s {d}x{d} pipe:1",
            .{ qpath, w, h }, 0);
        defer allocator.free(cmd);
        return popen(cmd.ptr, "r") orelse error.PopenFailed;
    }

    /// Read exactly one raw I420 frame into `self.yuv`. Returns false (and sets
    /// `eof_flag`) when the pipe drains mid/at frame.
    fn readFrame(self: *VideoDecoder) bool {
        var off: usize = 0;
        while (off < self.frame_bytes_yuv) {
            const n = fread(self.yuv.ptr + off, 1, self.frame_bytes_yuv - off, self.stream);
            if (n == 0) {
                self.eof_flag = true;
                return false;
            }
            off += n;
        }
        return true;
    }

    /// Slices of `self.yuv` for the Y, U, and V planes (tightly packed I420).
    fn planeSlices(self: *VideoDecoder) struct { y: []const u8, u: []const u8, v: []const u8 } {
        const y_len = @as(usize, self.w) * self.h;
        const c_len = @as(usize, self.cw) * self.ch;
        return .{
            .y = self.yuv[0..y_len],
            .u = self.yuv[y_len .. y_len + c_len],
            .v = self.yuv[y_len + c_len .. y_len + 2 * c_len],
        };
    }

    fn nextPts(self: *VideoDecoder) f64 {
        const pts = @as(f64, @floatFromInt(self.frame_index)) / @as(f64, self.fps);
        self.frame_index += 1;
        return pts;
    }

    pub fn eof(self: *const VideoDecoder) bool {
        return self.eof_flag;
    }

    /// Restart from the beginning by re-spawning ffmpeg (for engine-driven loop).
    pub fn replay(self: *VideoDecoder, allocator: std.mem.Allocator) void {
        const stream = spawn(allocator, self.path_buf[0..self.path_len], self.w, self.h) catch return;
        _ = pclose(self.stream);
        self.stream = stream;
        self.frame_index = 0;
        self.eof_flag = false;
    }

    pub fn width(self: *const VideoDecoder) u32 {
        return self.w;
    }
    pub fn height(self: *const VideoDecoder) u32 {
        return self.h;
    }

    /// CPU fallback: read one I420 frame and convert it to RGBA8 into `buf`
    /// (width*height*4 bytes) via `yuv.i420ToRgba` (the same BT.601 math the
    /// Android path + `fs_yuv` shader use). Returns the frame's presentation
    /// timestamp in seconds (nominal CFR: frame_index/fps), or null on stream
    /// end. The A/V sync runs off the audio master clock regardless.
    pub fn decodeFrame(self: *VideoDecoder, buf: []u8) ?f64 {
        if (buf.len != self.frame_bytes) return null;
        if (!self.readFrame()) return null;
        const p = self.planeSlices();
        yuv.i420ToRgba(p.y, p.u, p.v, self.w, self.h, self.w, self.cw, buf);
        return self.nextPts();
    }

    /// GPU path: read one I420 frame and copy its Y/U/V planes into the caller's
    /// tight plane buffers (`y` is w*h, `u`/`v` are cw*ch). ffmpeg's yuv420p is
    /// already tightly packed, so this is a straight copy — no de-interleave. The
    /// shader does the YUV→RGB convert.
    pub fn decodeFramePlanes(self: *VideoDecoder, y: []u8, u: []u8, v: []u8) ?f64 {
        const c_len = @as(usize, self.cw) * self.ch;
        if (y.len != @as(usize, self.w) * self.h or u.len != c_len or v.len != c_len) return null;
        if (!self.readFrame()) return null;
        const p = self.planeSlices();
        @memcpy(y, p.y);
        @memcpy(u, p.u);
        @memcpy(v, p.v);
        return self.nextPts();
    }

    pub fn deinit(self: *VideoDecoder) void {
        _ = pclose(self.stream);
        self.allocator.free(self.yuv);
    }
};

test "decodeAudioPcm: decodes a clip's audio track to 48k stereo PCM" {
    const alloc = std.testing.allocator;
    // `/tmp` is fine: this backend (and its tests) only build on POSIX hosts
    // (Linux/macOS) — bgfx here has no Windows target. Cleaned up after.
    const clip = "/tmp/labelle_audio_decode_test.mp4";
    // generateTestClip writes a 6 s clip with a 440 Hz sine audio track.
    try VideoDecoder.generateTestClip(alloc, clip, 320, 240);
    defer _ = unlink(clip);

    const pcm = VideoDecoder.decodeAudioPcm(alloc, clip) orelse return error.NoAudioDecoded;
    defer alloc.free(pcm);

    // ~6 s × 48000 × 2ch ≈ 576k samples — assert we got a substantial, even
    // (stereo-interleaved) buffer, not a stub/empty.
    try std.testing.expect(pcm.len > 48000);
    try std.testing.expectEqual(@as(usize, 0), pcm.len % 2);
    // The sine carries energy — it must not be all-silence.
    var nonzero: usize = 0;
    for (pcm) |s| {
        if (s != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > pcm.len / 4);
}
