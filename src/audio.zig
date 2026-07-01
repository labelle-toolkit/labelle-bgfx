/// bgfx audio backend — satisfies the engine AudioInterface(Impl) contract.
///
/// Phase 2 of the pluggable-backends RFC: the WAV decode + PCM mixer + slot
/// management that this file used to reimplement (~580 lines) now live in the
/// shared `labelle-audio` package. This file is a thin adapter:
///
///   * It instantiates `labelle_audio.Mixer(device_backend)`, where
///     `device_backend` is bgfx's real OS playback device (miniaudio on
///     desktop, AAudio on Android) selected at comptime. Those device modules
///     satisfy the shared `DeviceSink` contract (`ensureStarted`/`stop`/
///     `framesMixed`), so the shared mixer drives them directly.
///   * Every `pub fn` below forwards to `Audio.*`, preserving bgfx's public
///     audio API names + signatures verbatim (the engine/assembler call them by
///     name).
///   * The only bgfx-specific logic that remains is the libc file-read shim
///     behind the path-based `loadSound`/`loadMusic`: the shared mixer is
///     byte-buffer based (`loadSoundFromMemory`), so we read path→bytes via
///     libc here and hand the bytes to the mixer.
///
/// Thread-safety, the #298 unload/mix UAF fix, the spinlock, mono→stereo
/// duplication, and the device-less Android behaviour are all provided by the
/// shared mixer (see `labelle-audio/src/mixer.zig`); nothing about that
/// behaviour changes here.
///
/// Android (#306): the AAudio device backend is selected by the same comptime
/// `is_android` switch as before, so `miniaudio.h` is never seen on Android and
/// the AAudio externs are never seen on desktop.
const std = @import("std");
const builtin = @import("builtin");
const labelle_audio = @import("labelle-audio");

const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

// Output device, selected per target — the shared `DeviceSink` the mixer
// drives. On Android it's the AAudio device (#306); on desktop it's the
// miniaudio device. Both expose `ensureStarted`/`stop`/`framesMixed`, so they
// satisfy `labelle_audio.DeviceSink`. `if (is_android)` is comptime, so only
// the taken branch is analyzed — the desktop miniaudio `@cImport` is never seen
// on Android, and the AAudio externs are never seen on desktop.
const device_backend = if (is_android)
    @import("audio_device_android.zig")
else
    @import("audio_device.zig");

/// The shared PCM mixer, parameterized by bgfx's OS device as the `DeviceSink`.
/// Owns WAV decode + slot arrays + the spinlock + the full AudioInterface
/// surface; the public fns below forward to it.
const Audio = labelle_audio.Mixer(device_backend);

// Contract-version tags (labelle-assembler#453 item 1). The assembler emits
// directional `@compileError` version asserts in the generated game's main.zig
// comparing these against labelle-core's `AUDIO_PLAYBACK_CONTRACT_VERSION` /
// `AUDIO_LOADER_CONTRACT_VERSION` consts. v1 is the initial revision of each.
/// Audio playback contract (play/stop/volume of sounds + music) revision this backend targets.
pub const targets_audio_playback_contract: u32 = 1;
/// Audio loader contract (load/unload sound + music assets) revision this backend targets.
pub const targets_audio_loader_contract: u32 = 1;

// ── Lifecycle ────────────────────────────────────────────────────────

/// Open the playback device on first use, driving the mixer from its
/// audio-thread callback. Idempotent and cheap to call from every public entry
/// point that can start audio. On Android this is a no-op pump-wise until the
/// AAudio stream opens (no device → mixer state advances only when pumped).
pub fn ensureInit() void {
    Audio.ensureInit();
}

/// Cumulative frames pushed through the output device callback. >0 confirms the
/// device (miniaudio on desktop, AAudio on Android, #306) is live and pulling
/// from the mixer. Used for headless / on-device proof-of-life.
pub fn deviceFramesMixed() u64 {
    return Audio.deviceFramesMixed();
}

/// Stop and close the playback device, then free all loaded PCM. Must be called
/// by the host on shutdown. The shared mixer's `deinit` stops the device (which
/// joins the audio thread on desktop) before freeing the slots.
pub fn deinit() void {
    Audio.deinit();
}

// ── Path-based file-read shim ────────────────────────────────────────
//
// The shared mixer is byte-buffer based (`loadSoundFromMemory`), but bgfx's
// public `loadSound`/`loadMusic` take a file path. Zig 0.16 removed
// `std.fs.cwd()` in favour of `std.Io.Dir.cwd()`, which requires an `Io`
// threaded through the call site. Rather than thread `Io` through the backend
// for a one-shot legacy loader, we read the file via libc `fopen`/`fread`/
// `fclose` — `link_libc = true` is set on the audio module (see
// backends/bgfx/build.zig), so libc is available at no extra cost. The decoded
// bytes are then handed to the shared mixer, which owns decode + ownership.

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

/// Read an entire file into a freshly page-allocated buffer via libc. Returns
/// null on any IO error or short read (a short `fread` can occur on EOF
/// mid-read without setting an error flag, so we compare against the full
/// requested size, see PR #227). Caller owns the returned slice and frees it
/// via `std.heap.page_allocator`.
fn readFileBytes(path: [:0]const u8) ?[]u8 {
    const file = std.c.fopen(path.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return null;
    const file_size_signed = ftell(file);
    if (file_size_signed < 44) return null; // minimum WAV size
    if (fseek(file, 0, SEEK_SET) != 0) return null;
    const file_size: usize = @intCast(file_size_signed);

    const allocator = std.heap.page_allocator;
    const data = allocator.alloc(u8, file_size) catch return null;

    const bytes_read = std.c.fread(data.ptr, 1, file_size, file);
    if (bytes_read != file_size) {
        std.log.warn("audio: short read on {s} ({d}/{d} bytes)", .{ path, bytes_read, file_size });
        allocator.free(data);
        return null;
    }
    return data;
}

// ── Sound effects ────────────────────────────────────────────────────

/// Load a WAV file from `path` and register it as a sound effect. Reads the
/// file via the libc shim, then hands the bytes to the shared mixer (which owns
/// decode + the PCM). Returns the sound id, or 0 on failure.
pub fn loadSound(path: [:0]const u8) u32 {
    const bytes = readFileBytes(path) orelse return 0;
    defer std.heap.page_allocator.free(bytes);
    return Audio.loadSoundFromMemory(bytes);
}

pub fn unloadSound(id: u32) void {
    Audio.unloadSound(id);
}

pub fn playSound(id: u32) void {
    Audio.playSound(id);
}

pub fn stopSound(id: u32) void {
    Audio.stopSound(id);
}

pub fn isSoundPlaying(id: u32) bool {
    return Audio.isSoundPlaying(id);
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    Audio.setSoundVolume(id, volume);
}

// ── Music (streaming) ────────────────────────────────────────────────

/// Load a WAV file from `path` and register it as a looping music stream. Same
/// libc file-read shim as `loadSound`. Returns the music id, or 0 on failure.
pub fn loadMusic(path: [:0]const u8) u32 {
    const bytes = readFileBytes(path) orelse return 0;
    defer std.heap.page_allocator.free(bytes);
    return Audio.loadMusicFromMemory(bytes);
}

/// Register an already-decoded interleaved PCM_16 buffer as a looping music
/// stream. Used by the Android audio-track decoder (`video/android_audio.zig`)
/// to feed decoded video audio into the mixer. `sample_rate` should be the
/// device rate (48000): the mixer does not resample. Public signature keeps the
/// `u16` channels arg bgfx exposed; the shared mixer takes `u8`, so we narrow.
pub fn loadMusicFromPcm(samples: []const i16, channels: u16, sample_rate: u32) u32 {
    if (samples.len == 0 or channels == 0 or channels > 2) return 0;
    return Audio.loadMusicFromPcm(samples, @intCast(channels), sample_rate);
}

pub fn unloadMusic(id: u32) void {
    Audio.unloadMusic(id);
}

pub fn playMusic(id: u32) void {
    Audio.playMusic(id);
}

pub fn stopMusic(id: u32) void {
    Audio.stopMusic(id);
}

pub fn pauseMusic(id: u32) void {
    Audio.pauseMusic(id);
}

pub fn resumeMusic(id: u32) void {
    Audio.resumeMusic(id);
}

pub fn isMusicPlaying(id: u32) bool {
    return Audio.isMusicPlaying(id);
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    Audio.setMusicVolume(id, volume);
}

/// No-op (kept for API compatibility). Music position is advanced exclusively
/// on the audio thread by the mixer's device callback, so advancing here would
/// double-advance / drift.
pub fn updateMusic(id: u32) void {
    Audio.updateMusic(id);
}

/// Current playback position of a music stream in seconds, read off the
/// audio-thread-advanced frame position (the real audio-device clock; master
/// clock for A/V sync, #549). 0 if the id is unloaded or the device hasn't
/// pumped yet (e.g. Android before the AAudio stream opens).
pub fn musicPositionSeconds(id: u32) f64 {
    return Audio.musicPositionSeconds(id);
}

// ── Mixer + global ───────────────────────────────────────────────────

/// Mix all active sounds and music into a stereo i16 output buffer. Called by
/// the device backend's audio-thread callback (desktop). Forwards to the shared
/// mixer with `channels = 2` (bgfx's device is always stereo). The shared mixer
/// recovers the frame count from `output.len`, so the legacy `frames` arg is
/// accepted for signature compatibility but the buffer length is authoritative;
/// we clamp the buffer to the requested frames so a caller passing a larger
/// scratch buffer still only fills `frames` worth.
pub fn mixAudio(output: []i16, frames_requested: u32) void {
    const max_frames: u32 = @intCast(output.len / 2);
    const frames = @min(frames_requested, max_frames);
    Audio.mix(output[0 .. @as(usize, frames) * 2], 2);
}

pub fn setVolume(volume: f32) void {
    Audio.setVolume(volume);
}

// ── Tests ─────────────────────────────────────────────────────────────
//
// The decode/mixer/spinlock/UAF behaviour is now tested in `labelle-audio`
// itself. These thin smoke tests confirm the bgfx adapter wires the shared
// mixer correctly (forwarding + the stereo `mixAudio` shim), exercised
// headlessly via the device backend without opening a real device.

const testing = std.testing;

test "mixAudio clears output when nothing is playing" {
    Audio.resetForTest();
    var buf = [_]i16{ 123, 45, -67, 89 }; // 2 stereo frames
    mixAudio(&buf, 2);
    for (buf) |s| try testing.expectEqual(@as(i16, 0), s);
}

test "loadMusicFromPcm round-trips a stereo buffer and reports position" {
    Audio.resetForTest();
    // 2 stereo frames at 48 kHz.
    const pcm = [_]i16{ 100, 200, 300, 400 };
    const id = loadMusicFromPcm(&pcm, 2, 48000);
    try testing.expect(id != 0);
    defer unloadMusic(id);
    try testing.expectEqual(@as(f64, 0), musicPositionSeconds(id));
}

test "loadMusicFromPcm rejects an out-of-range channel count" {
    Audio.resetForTest();
    const pcm = [_]i16{ 1, 2, 3, 4 };
    try testing.expectEqual(@as(u32, 0), loadMusicFromPcm(&pcm, 3, 48000));
}
