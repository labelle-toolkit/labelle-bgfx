//! Minimal NativeActivity native lib that verifies the Android AMediaCodec
//! decoder *inside a real app process* (FP#549 Half 2).
//!
//! The bare `adb shell` harness (`video/test_decode.zig`) proved AMediaExtractor
//! works on-device but couldn't create the codec — a CLI process lacks the
//! Binder threadpool + JVM/ART context the codec service needs. A NativeActivity
//! runs in a normal app process (forked from zygote, with ART + binder), so
//! AMediaCodec should succeed here. This is the on-device proof the CLI can't
//! give — and the same shell shape the real intro (Path B) would use.
//!
//! Flow: `ANativeActivity_onCreate` → open the bundled `dectest.mp4` asset via
//! AAssetManager → fd → `android.VideoDecoder` → decode frames → `__android_log`
//! the result (read back with `adb logcat`).

const std = @import("std");
const android = @import("android");
const android_audio = @import("android_audio");
const audio = @import("audio");

extern "c" fn usleep(usec: u32) c_int;

const c = @cImport({
    @cInclude("decode_shim.h");
});

const TAG = "DECTEST";

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    _ = c.__android_log_print(c.ANDROID_LOG_INFO, TAG, "%s", s.ptr);
}

/// NativeActivity entry point. The framework loads `libdecodetest.so` (named in
/// the manifest's `android.app.lib_name`) and calls this. We run the decode
/// test synchronously — it's fast (a handful of frames) so it won't ANR.
export fn ANativeActivity_onCreate(activity: *c.ANativeActivity, saved: ?*anyopaque, saved_size: usize) void {
    _ = saved;
    _ = saved_size;
    log("ANativeActivity_onCreate: running AMediaCodec decode test", .{});
    runTest(activity);
}

fn runTest(activity: *c.ANativeActivity) void {
    const am = activity.assetManager;
    if (am == null) {
        log("FAIL: no assetManager", .{});
        return;
    }

    const asset = c.AAssetManager_open(am, "dectest.mp4", c.AASSET_MODE_STREAMING);
    if (asset == null) {
        log("FAIL: asset open (dectest.mp4)", .{});
        return;
    }
    defer _ = c.AAsset_close(asset);

    // openFileDescriptor only works if the asset is stored UNCOMPRESSED in the
    // APK (packaged with aapt2 `-0 mp4`).
    var start: c.off64_t = 0;
    var length: c.off64_t = 0;
    const fd = c.AAsset_openFileDescriptor64(asset, &start, &length);
    if (fd < 0) {
        log("FAIL: openFileDescriptor (asset compressed?)", .{});
        return;
    }
    log("asset fd={d} start={d} len={d}", .{ fd, start, length });

    var dec = android.VideoDecoder.openFd(std.heap.page_allocator, fd, start, length) catch |e| {
        log("FAIL: decoder open: {s}", .{@errorName(e)});
        return;
    };
    defer dec.deinit();

    const w = dec.width();
    const h = dec.height();
    log("decoder ready: {d}x{d}", .{ w, h });
    if (w == 0 or h == 0) {
        log("FAIL: zero dimensions", .{});
        return;
    }

    const buf = std.heap.page_allocator.alloc(u8, @as(usize, w) * h * 4) catch {
        log("FAIL: alloc", .{});
        return;
    };
    defer std.heap.page_allocator.free(buf);

    var frames: u32 = 0;
    var tries: u32 = 0;
    while (frames < 10 and tries < 2000) : (tries += 1) {
        if (dec.decodeFrame(buf)) |_| {
            frames += 1;
            if (frames == 1) {
                log("frame0 px0 = ({d},{d},{d},{d})", .{ buf[0], buf[1], buf[2], buf[3] });
            }
        }
    }

    if (frames > 0) {
        log("RESULT PASS: decoded {d} frames in {d} tries", .{ frames, tries });
    } else {
        log("RESULT FAIL: no frames in {d} tries", .{tries});
    }

    // -- Android audio-track decode (FP#549) + AAudio playback (#306).
    // Re-open the asset for a fresh fd, decode the audio track to 48k stereo,
    // hand it to the mixer, play it, and confirm the AAudio device pulled it.
    const a2 = c.AAssetManager_open(am, "dectest.mp4", c.AASSET_MODE_STREAMING);
    if (a2 == null) {
        log("AUDIO: re-open asset FAILED", .{});
        return;
    }
    defer _ = c.AAsset_close(a2);
    var s2: c.off64_t = 0;
    var l2: c.off64_t = 0;
    const fd2 = c.AAsset_openFileDescriptor64(a2, &s2, &l2);
    if (fd2 < 0) {
        log("AUDIO: asset fd FAILED", .{});
        return;
    }

    var apcm = android_audio.decodeTrack(std.heap.page_allocator, fd2, s2, l2) catch |e| {
        log("AUDIO decode FAILED: {s}", .{@errorName(e)});
        return;
    };
    defer apcm.deinit(std.heap.page_allocator);
    const first: i16 = if (apcm.samples.len > 0) apcm.samples[0] else 0;
    log("AUDIO decoded {d} frames @48k stereo (sample[0]={d})", .{ apcm.frames, first });

    const mid = audio.loadMusicFromPcm(apcm.samples, 2, 48000);
    if (mid != 0) audio.playMusic(mid);
    audio.ensureInit();
    _ = usleep(500_000); // let the audio thread run ~0.5s
    const mixed = audio.deviceFramesMixed();
    log("AAUDIO frames mixed in ~0.5s = {d}", .{mixed});
    if (apcm.frames > 0 and mid != 0 and mixed > 0) {
        log("AUDIO PASS: decoded audio track played via AAudio (#306/#549)", .{});
    } else {
        log("AUDIO FAIL", .{});
    }
    audio.deinit();
}
