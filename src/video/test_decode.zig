//! On-device test harness for the Android AMediaCodec decoder (FP#549 Half 2).
//!
//! A tiny native CLI binary: opens an H.264 mp4 by path, runs `android.zig`'s
//! `VideoDecoder` (real AMediaExtractor + AMediaCodec), decodes a handful of
//! frames, and prints the dimensions, decoded-frame count, and the first
//! pixel of the first frame. Built for `aarch64-linux-android`, pushed to the
//! emulator, and run via `adb shell` — the real on-device proof the desktop
//! host can't give.
//!
//! Usage on device:  test_decode /data/local/tmp/dectest.mp4

const std = @import("std");
const android = @import("android.zig");

const O_RDONLY: c_int = 0;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn open(path: [*:0]const u8, flags: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;

// On-device finding (emulator, API 34, arm64): AMediaExtractor works fully from
// a bare `adb shell` exec (demux + track + format negotiation all succeed), but
// AMediaCodec_createDecoderByType returns null — logcat shows the codec service
// needs a Binder threadpool AND a JVM/ART context ("NdkJavaVMHelper: Failed to
// get JVM instance"), which only a real app process (APK / NativeActivity)
// provides. So this CLI harness verifies the EXTRACTOR half on-device; full
// codec verification requires packaging the decoder in an APK (converges with
// the Path B Android shell work).

pub fn main(init: std.process.Init.Minimal) void {
    // Path from the first CLI arg if given, else the on-device default. The
    // args iterator yields sentinel-terminated slices, usable as `[*:0]const u8`.
    var path: [*:0]const u8 = "/data/local/tmp/dectest.mp4";
    var args = init.args.iterate();
    _ = args.skip(); // argv[0] (program name)
    if (args.next()) |arg| path = arg.ptr;

    const fd = open(path, O_RDONLY);
    if (fd < 0) {
        std.debug.print("FAIL: cannot open {s}\n", .{path});
        return;
    }
    // No `defer close(fd)`: ownership transfers to VideoDecoder.openFd, which
    // closes it in deinit (success) or via errdefer (failure). Closing here too
    // would double-close.

    const len = lseek(fd, 0, SEEK_END);
    _ = lseek(fd, 0, SEEK_SET);
    std.debug.print("opened fd={d} len={d}\n", .{ fd, len });

    var dec = android.VideoDecoder.openFd(std.heap.page_allocator, fd, 0, len) catch |e| {
        std.debug.print("FAIL: decoder open: {s}\n", .{@errorName(e)});
        return;
    };
    defer dec.deinit();

    const w = dec.width();
    const h = dec.height();
    std.debug.print("decoder ready: {d}x{d}\n", .{ w, h });
    if (w == 0 or h == 0) {
        std.debug.print("FAIL: zero dimensions\n", .{});
        return;
    }

    const buf = std.heap.page_allocator.alloc(u8, @as(usize, w) * h * 4) catch {
        std.debug.print("FAIL: alloc\n", .{});
        return;
    };
    defer std.heap.page_allocator.free(buf);

    var frames: u32 = 0;
    var tries: u32 = 0;
    while (frames < 10 and tries < 2000) : (tries += 1) {
        if (dec.decodeFrame(buf)) |_| {
            frames += 1;
            if (frames == 1) {
                std.debug.print("frame0 px0 = ({d},{d},{d},{d})\n", .{ buf[0], buf[1], buf[2], buf[3] });
            }
        }
    }

    std.debug.print("RESULT: decoded {d} frames in {d} tries\n", .{ frames, tries });
    if (frames > 0) {
        std.debug.print("PASS\n", .{});
    } else {
        std.debug.print("FAIL: no frames\n", .{});
    }
}
