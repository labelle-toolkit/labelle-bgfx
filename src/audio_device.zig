/// Desktop miniaudio playback device for the bgfx audio backend (#297).
///
/// This is the device half of the audio backend, extracted from
/// `audio.zig` so the pure-Zig mixer/decoder can compile for Android
/// without dragging in miniaudio's C TU or a real output device (#306).
///
/// `audio.zig` selects this module on desktop and a `NoopDevice` stub on
/// Android (`const device_backend = if (is_android) NoopDevice else
/// @import("audio_device.zig");`). Both expose the same control surface:
///
///   * `ensureStarted(mix: MixFn) void` — lazily open + start the playback
///     device, wiring `mix` as the audio-thread fill callback. Idempotent.
///   * `stop() void` — uninit the device (joins the audio thread) if it was
///     started.
///   * `framesMixed() u64` — cumulative frames pushed through the callback,
///     for a one-line proof-of-life log.
///
/// A single shared `ma_device` runs in playback mode (s16 / 2ch / 48 kHz);
/// its data callback reinterprets miniaudio's raw output buffer as
/// interleaved-stereo i16 and hands it to the mixer supplied by `audio.zig`.
const std = @import("std");

const ma = @cImport({
    @cInclude("miniaudio.h");
});

/// Signature of the mixer the device drives on the audio thread — the shared
/// `labelle-audio` device-sink callback (`out: []i16, channels: u8`). The
/// device is always stereo, so it passes `channels = 2` and `out.len =
/// frames * 2`; the mixer derives the frame count from `out.len`. Importing the
/// shared type (rather than redeclaring it) makes the `DeviceSink` contract
/// enforce the signature at the `Mixer(...)` instantiation site.
pub const MixFn = @import("labelle-audio").MixCallback;

const DEVICE_SAMPLE_RATE: u32 = 48000;
const DEVICE_CHANNELS: u32 = 2;

var device: ma.ma_device = undefined;
// `ensureStarted` / `stop` are called from the game thread only (the
// AudioInterface control surface is single-threaded; only the mixer runs
// on the audio callback thread, and it never reads this). It's atomic
// anyway for safe publication of the device's initialized state.
var device_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// The mixer supplied by `audio.zig`, published before the device starts
// and read on the audio thread. Stored as a nullable so a stray callback
// (shouldn't happen — set before start) degrades to silence, not a crash.
var mix_fn: ?MixFn = null;

/// Cumulative frames pushed through the device callback. Read once at
/// `stop` (and via `framesMixed`) to print a single proof-of-life line;
/// not used for control flow. Atomic because it's written from the audio
/// thread.
var frames_mixed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Audio-thread data callback. miniaudio hands us a frame budget and a
/// raw output buffer for `ma_format_s16` / 2 channels; we reinterpret it
/// as interleaved-stereo i16 and let the supplied mixer fill it. The
/// mixer takes its own slot lock internally, so this is safe against
/// concurrent load/unload on the game thread (#298).
fn deviceDataCallback(
    p_device: ?*ma.ma_device,
    p_output: ?*anyopaque,
    p_input: ?*const anyopaque,
    frame_count: ma.ma_uint32,
) callconv(.c) void {
    _ = p_device;
    _ = p_input; // playback-only device: no capture input
    const out_ptr = p_output orelse return;
    const out: [*]i16 = @ptrCast(@alignCast(out_ptr));
    const frames: u32 = @intCast(frame_count);
    const sample_count: usize = @as(usize, frames) * DEVICE_CHANNELS;

    // Cheap proof-of-life so headless runs can confirm the callback is
    // actually firing (audibility can't be asserted without a speaker).
    // Log exactly once on the first invocation; thereafter just count.
    const prev = frames_mixed.fetchAdd(frames, .monotonic);
    if (prev == 0) {
        std.log.info("audio: device callback firing (first {d} frames mixed)", .{frames});
    }

    // Shared device-sink contract: the device knows it's stereo, so it passes
    // `channels = 2` and a buffer of `frames * 2` interleaved i16 samples; the
    // mixer recovers the frame count from `out.len`.
    if (mix_fn) |mix| {
        mix(out[0..sample_count], 2);
    } else {
        // No mixer wired yet — emit silence, not whatever stale samples the
        // device buffer happens to hold (matches the AAudio backend's @memset).
        @memset(out[0..sample_count], 0);
    }
}

/// Open + start the playback device on first use, wiring `mix` as the
/// audio-thread fill callback. Idempotent and cheap to call from every
/// public entry point that can start audio. If the device fails to open
/// (e.g. no audio hardware in CI) we log once and leave it uninitialized
/// — the rest of the backend keeps working as a silent state machine.
pub fn ensureStarted(mix: MixFn) void {
    if (device_initialized.load(.acquire)) return;

    // Publish the mixer before the device starts so the audio thread never
    // observes a null `mix_fn`.
    mix_fn = mix;

    var config = ma.ma_device_config_init(ma.ma_device_type_playback);
    config.playback.format = ma.ma_format_s16;
    config.playback.channels = DEVICE_CHANNELS;
    config.sampleRate = DEVICE_SAMPLE_RATE;
    config.dataCallback = deviceDataCallback;

    if (ma.ma_device_init(null, &config, &device) != ma.MA_SUCCESS) {
        std.log.warn("audio: failed to initialize miniaudio playback device", .{});
        return;
    }

    if (ma.ma_device_start(&device) != ma.MA_SUCCESS) {
        std.log.warn("audio: failed to start miniaudio playback device", .{});
        ma.ma_device_uninit(&device);
        return;
    }

    device_initialized.store(true, .release);
    std.log.info(
        "audio: miniaudio playback device started: {d}Hz {d}ch s16",
        .{ device.sampleRate, DEVICE_CHANNELS },
    );
}

/// Stop and close the playback device if it was started. `ma_device_uninit`
/// joins the audio thread before returning, so after it the mixer is no
/// longer called and the caller can free PCM without taking its slot lock.
pub fn stop() void {
    if (device_initialized.load(.acquire)) {
        // Joins the audio callback thread — no more mixing after this.
        ma.ma_device_uninit(&device);
        device_initialized.store(false, .release);
        std.log.info(
            "audio: miniaudio device stopped ({d} frames mixed)",
            .{frames_mixed.load(.monotonic)},
        );
    }
}

/// Cumulative frames pushed through the device callback so far.
pub fn framesMixed() u64 {
    return frames_mixed.load(.monotonic);
}
