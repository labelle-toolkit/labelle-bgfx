//! Android audio output device via **AAudio** (NDK, API 26+) — closes #306.
//!
//! Implements the same control surface as the desktop `audio_device.zig`
//! (`ensureStarted` / `stop` / `framesMixed`) so `audio.zig`'s pure-Zig mixer
//! drives it unchanged. Opens a PCM_I16 stereo 48 kHz output stream and wires
//! its data callback to the engine mixer, so the audio thread pulls mixed
//! samples on demand — the same model as miniaudio on desktop.
//!
//! Pure C NDK API (no JNI), called via `extern`; links `libaaudio`. If the
//! stream can't open (e.g. no audio HW), `ensureStarted` no-ops gracefully and
//! `framesMixed` stays 0 — same observable behavior as the old NoopDevice, but
//! real output everywhere AAudio is available.

const std = @import("std");

/// Signature of the mixer the device drives on the audio thread — the shared
/// `labelle-audio` device-sink callback (`out: []i16, channels: u8`). The
/// AAudio stream is always stereo, so it passes `channels = 2` and `out.len =
/// frames * 2`. Importing the shared type makes the `DeviceSink` contract
/// enforce the signature at the `Mixer(...)` instantiation site.
pub const MixFn = @import("labelle-audio").MixCallback;

const DEVICE_RATE: i32 = 48000;
const DEVICE_CHANNELS: i32 = 2;

// AAudio C ABI (subset). aaudio_result_t AAUDIO_OK == 0.
const AAudioStreamBuilder = opaque {};
const AAudioStream = opaque {};
const AAUDIO_OK: i32 = 0;
const AAUDIO_FORMAT_PCM_I16: i32 = 1;
const AAUDIO_CALLBACK_RESULT_CONTINUE: i32 = 0;
const DataCallback = *const fn (?*AAudioStream, ?*anyopaque, ?*anyopaque, i32) callconv(.c) i32;

extern fn AAudio_createStreamBuilder(builder: *?*AAudioStreamBuilder) i32;
extern fn AAudioStreamBuilder_setFormat(*AAudioStreamBuilder, format: i32) void;
extern fn AAudioStreamBuilder_setChannelCount(*AAudioStreamBuilder, count: i32) void;
extern fn AAudioStreamBuilder_setSampleRate(*AAudioStreamBuilder, rate: i32) void;
extern fn AAudioStreamBuilder_setDataCallback(*AAudioStreamBuilder, cb: DataCallback, user: ?*anyopaque) void;
extern fn AAudioStreamBuilder_openStream(*AAudioStreamBuilder, stream: *?*AAudioStream) i32;
extern fn AAudioStreamBuilder_delete(*AAudioStreamBuilder) void;
extern fn AAudioStream_requestStart(*AAudioStream) i32;
extern fn AAudioStream_requestStop(*AAudioStream) i32;
extern fn AAudioStream_close(*AAudioStream) i32;

var stream: ?*AAudioStream = null;
var mix_fn: ?MixFn = null;
var frames_mixed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Audio-thread data callback: reinterpret AAudio's buffer as interleaved
/// stereo i16 and let the engine mixer fill it. Runs on a real-time thread —
/// no allocation, no logging, just the mix call (the mixer takes its own lock).
fn dataCallback(_: ?*AAudioStream, _: ?*anyopaque, audio_data: ?*anyopaque, num_frames: i32) callconv(.c) i32 {
    const frames: u32 = @intCast(@max(num_frames, 0));
    const samples: usize = @as(usize, frames) * @as(usize, @intCast(DEVICE_CHANNELS));
    const out: [*]i16 = @ptrCast(@alignCast(audio_data));
    // Shared device-sink contract: stereo device → `channels = 2`, buffer is
    // `frames * 2` interleaved i16; the mixer recovers frames from `out.len`.
    if (mix_fn) |m| m(out[0..samples], 2) else @memset(out[0..samples], 0);
    _ = frames_mixed.fetchAdd(frames, .monotonic);
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

/// Lazily open + start the AAudio output stream, wiring `mix` as the callback.
/// Idempotent; no-ops gracefully if AAudio is unavailable.
pub fn ensureStarted(mix: MixFn) void {
    if (stream != null) return;
    mix_fn = mix;

    var builder: ?*AAudioStreamBuilder = null;
    if (AAudio_createStreamBuilder(&builder) != AAUDIO_OK) return;
    const b = builder orelse return;
    defer AAudioStreamBuilder_delete(b);

    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setChannelCount(b, DEVICE_CHANNELS);
    AAudioStreamBuilder_setSampleRate(b, DEVICE_RATE);
    AAudioStreamBuilder_setDataCallback(b, &dataCallback, null);

    var s: ?*AAudioStream = null;
    if (AAudioStreamBuilder_openStream(b, &s) != AAUDIO_OK) return;
    const opened = s orelse return;
    if (AAudioStream_requestStart(opened) != AAUDIO_OK) {
        _ = AAudioStream_close(opened);
        return;
    }
    stream = opened;
}

pub fn stop() void {
    if (stream) |s| {
        _ = AAudioStream_requestStop(s);
        _ = AAudioStream_close(s);
        stream = null;
    }
}

pub fn framesMixed() u64 {
    return frames_mixed.load(.monotonic);
}
