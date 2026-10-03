/// bgfx audio backend — satisfies the engine AudioInterface(Impl) contract.
///
/// Phase 2 of the pluggable-backends RFC: the WAV decode + PCM mixer + slot
/// management that this file used to reimplement (~580 lines) now live in the
/// shared `labelle-audio` package. This file is a thin adapter:
///
///   * It instantiates `labelle_audio.Mixer(device_backend)`, where
///     `device_backend` is bgfx's real OS playback device (miniaudio on
///     desktop and in the browser, AAudio on Android) selected at comptime. Those device modules
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
const heap = @import("audio_heap.zig");
const builtin = @import("builtin");
const labelle_audio = @import("labelle-audio");

const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

// wasm/Emscripten plays through miniaudio's Web Audio backend (a
// ScriptProcessorNode on the page's AudioContext, resumed on the first
// click/touch), the same `audio_device.zig` desktop uses. `buildWasm` compiles
// miniaudio with only that backend.
const is_wasm = builtin.target.cpu.arch.isWasm();

// Output device, selected per target — the shared `DeviceSink` the mixer
// drives. On Android it's labelle-android's AAudio device (#306, moved there
// in #149 phase 1c); on desktop and wasm it's the miniaudio device. Both expose
// `ensureStarted`/`stop`/`framesMixed`, so they satisfy
// `labelle_audio.DeviceSink`. `if (is_android)` is comptime, so only the taken
// branch is analyzed — the desktop miniaudio `@cImport` is never seen on
// Android, and the `labelle_android` import (and its AAudio externs) is never
// seen on desktop — the same pattern as `zglfw` in `window.zig`.
const device_backend = if (is_android)
    @import("labelle_android").aaudio
else
    @import("audio_device.zig");

// labelle-android declares the device's `MixCallback` structurally (it has no
// labelle-audio dependency). Function-pointer types are structural in Zig, so
// the two are one type — assert it, so a drift in either package is a compile
// error at the `Mixer(...)` instantiation site rather than a silent mismatch.
comptime {
    if (is_android) std.debug.assert(@import("labelle_android").aaudio.MixCallback == labelle_audio.MixCallback);
}

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
    useHeap();
    Audio.ensureInit();
}

// The mixer owns PCM with its own allocator, `page_allocator` unless told
// otherwise. On wasm that grows linear memory behind emscripten's malloc and
// corrupts its heap and stack (`audio_heap.zig`), so hand it bgfx's heap before
// anything is allocated. On desktop and Android that is the same
// page_allocator, so nothing changes there. Setting it is one store, so every
// entry point that can allocate does it.
fn useHeap() void {
    Audio.init(heap.allocator);
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
/// via `heap.allocator`.
fn readFileBytes(path: [:0]const u8) ?[]u8 {
    const file = std.c.fopen(path.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return null;
    const file_size_signed = ftell(file);
    if (file_size_signed < 44) return null; // minimum WAV size
    if (fseek(file, 0, SEEK_SET) != 0) return null;
    const file_size: usize = @intCast(file_size_signed);

    const allocator = heap.allocator;
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
    useHeap();
    const bytes = readFileBytes(path) orelse return 0;
    defer heap.allocator.free(bytes);
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
    useHeap();
    const bytes = readFileBytes(path) orelse return 0;
    defer heap.allocator.free(bytes);
    return Audio.loadMusicFromMemory(bytes);
}

/// Load the bundled asset `name` (e.g. `"music/theme.ogg"`) and register it
/// as a looping music stream. Returns the music id, or 0 on failure.
///
/// On Android the file is opened in the APK by `labelle_android.assets.openFd`
/// and decoded by the platform decoder, `labelle_android.video.decodeTrack`
/// (AMediaExtractor + AMediaCodec, so MP3, OGG Vorbis, AAC and Opus), which
/// also resamples to the mixer's 48 kHz stereo — the path the intro video's
/// audio already takes (`src/video/backend.zig`). The asset must be stored
/// uncompressed in the APK: the NDK refuses an fd for a compressed entry.
///
/// The decode is synchronous and takes seconds for a long track on a slow
/// device (a 2-minute MP3 is ~7 s on the MT6750 P42), long enough for an
/// Android "not responding" dialog. Games should use `loadMusicAssetAsync`.
///
/// On desktop it loads `assets/<name>` with `loadMusic`, so only a WAV at the
/// device rate works there until desktop decodes compressed audio. The browser
/// can't fetch synchronously, so on wasm this returns 0: use
/// `loadMusicAssetAsync`, which fetches and decodes in the browser.
pub fn loadMusicAsset(name: []const u8) u32 {
    if (comptime is_android) return loadMusicAssetAndroid(name);
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "assets/{s}", .{name}) catch return 0;
    return loadMusic(path);
}

/// A music asset being decoded off the calling thread by
/// `loadMusicAssetAsync`. The caller owns it (e.g. a file-scope `var`) and
/// keeps it alive until `poll` returns non-null. Call `wait` before `deinit`
/// if a load may still be running, so the worker can't register its music
/// into (and restart) a mixer that is shutting down.
pub const MusicAssetLoad = struct {
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    result: std.atomic.Value(u32) = .init(pending),
    thread: ?std.Thread = null,
    /// The browser fetch + decode in flight on wasm (`web_audio.c`), 0 if none.
    web_id: c_int = 0,

    const pending: u32 = std.math.maxInt(u32);

    /// `null` while decoding; then the music id, or 0 if the load failed.
    pub fn poll(self: *MusicAssetLoad) ?u32 {
        if (comptime is_wasm) {
            if (self.web_id != 0) webFinish(self);
        }
        const id = self.result.load(.acquire);
        if (id == pending) return null;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        return id;
    }

    /// Block until the decode is done; then the music id, or 0 if the load
    /// failed or was never started. The browser can't block on a fetch, so on
    /// wasm a load still in flight is dropped and reported as 0.
    pub fn wait(self: *MusicAssetLoad) u32 {
        if (comptime is_wasm) {
            if (self.web_id != 0) webFinish(self);
            if (self.web_id != 0) {
                labelle_web_audio_close(self.web_id);
                self.web_id = 0;
                self.result.store(0, .release);
            }
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        const id = self.result.load(.acquire);
        return if (id == pending) 0 else id;
    }
};

/// `loadMusicAsset` on a worker thread, so a long decode doesn't freeze the
/// game. Poll `load.poll()` each frame. Returns false if it couldn't start
/// (name too long, no thread, or `load` is still decoding a previous asset).
/// Single-threaded targets load synchronously, so `poll` is ready at once.
pub fn loadMusicAssetAsync(load: *MusicAssetLoad, name: []const u8) bool {
    // A running worker reads `name_buf`; don't overwrite it under it.
    if (load.thread != null and load.poll() == null) return false;
    if (comptime is_wasm) {
        if (load.web_id != 0) return false;
    }
    // Leave room for the NUL the Android asset path needs.
    if (name.len >= load.name_buf.len) return false;
    @memcpy(load.name_buf[0..name.len], name);
    load.name_len = name.len;
    // Bring the mixer up here, on the caller's thread, not from the worker.
    ensureInit();
    if (comptime is_wasm) return webStart(load, name);
    if (comptime builtin.single_threaded) {
        load.result.store(loadMusicAsset(name), .release);
        return true;
    }
    load.result.store(MusicAssetLoad.pending, .release);
    load.thread = std.Thread.spawn(.{}, loadMusicAssetWorker, .{load}) catch return false;
    return true;
}

fn loadMusicAssetWorker(load: *MusicAssetLoad) void {
    load.result.store(loadMusicAsset(load.name_buf[0..load.name_len]), .release);
}

// The browser half (`web_audio.c`): fetch `assets/<name>`, decode it with the
// browser's decoder at 48 kHz stereo, and hand the i16 samples over on request.
// Only referenced on wasm, so never linked elsewhere.
extern fn labelle_web_audio_open(url: [*:0]const u8) c_int;
extern fn labelle_web_audio_status(id: c_int) c_int;
extern fn labelle_web_audio_copy(id: c_int, ptr: [*]i16, len: c_int) c_int;
extern fn labelle_web_audio_close(id: c_int) void;

fn webStart(load: *MusicAssetLoad, name: []const u8) bool {
    if (load.web_id != 0) return false; // still fetching the previous asset
    var buf: [512]u8 = undefined;
    const url = std.fmt.bufPrintZ(&buf, "assets/{s}", .{name}) catch return false;
    const id = labelle_web_audio_open(url.ptr);
    if (id == 0) return false;
    load.web_id = id;
    load.result.store(MusicAssetLoad.pending, .release);
    return true;
}

// Once the browser has decoded the asset, copy it into the mixer and close the
// browser-side load. Leaves `web_id` set while the fetch is still running.
fn webFinish(load: *MusicAssetLoad) void {
    const frames = labelle_web_audio_status(load.web_id);
    if (frames == 0) return;
    defer {
        labelle_web_audio_close(load.web_id);
        load.web_id = 0;
    }
    if (frames < 0) return load.result.store(0, .release);
    const len: usize = @as(usize, @intCast(frames)) * 2;
    const samples = heap.allocator.alloc(i16, len) catch return load.result.store(0, .release);
    // The mixer copies the samples, so this buffer is freed here.
    defer heap.allocator.free(samples);
    const copied: usize = @intCast(labelle_web_audio_copy(load.web_id, samples.ptr, @intCast(len)));
    if (copied != len) return load.result.store(0, .release);
    std.log.info("[audio] music asset {s}: {d} frames ({d:.2} s at 48 kHz)", .{ load.name_buf[0..load.name_len], frames, @as(f64, @floatFromInt(frames)) / 48000.0 });
    load.result.store(loadMusicFromPcm(samples, 2, 48000), .release);
}

// The bgfx Android shell's export of the running NativeActivity (the same
// symbol `src/android.zig` adapts; the audio module can't import that file).
// Only referenced on Android, so never linked elsewhere.
extern fn labelle_bgfx_get_native_activity() ?*anyopaque;

fn loadMusicAssetAndroid(name: []const u8) u32 {
    const android = @import("labelle_android");
    // labelle-android opens the asset in the APK (it reads the activity's
    // asset manager through the NDK header) and hands back a dup'd fd.
    const asset = android.assets.openFd(labelle_bgfx_get_native_activity(), name) orelse return 0;
    // `decodeTrack` reads the fd synchronously and leaves it open.
    defer asset.close();
    var pcm = android.video.decodeTrack(heap.allocator, asset.fd, asset.start, asset.len) catch return 0;
    defer pcm.deinit(heap.allocator);
    std.log.info("[audio] music asset {s}: {d} frames ({d:.2} s at 48 kHz)", .{ name, pcm.frames, @as(f64, @floatFromInt(pcm.frames)) / 48000.0 });
    // The mixer copies the samples, so the decoded buffer is freed here.
    return loadMusicFromPcm(pcm.samples, 2, 48000);
}

/// Register an already-decoded interleaved PCM_16 buffer as a looping music
/// stream. Used by the Android audio-track decoder (`labelle_android.video.decodeTrack`)
/// to feed decoded video audio into the mixer. `sample_rate` should be the
/// device rate (48000): the mixer does not resample. Public signature keeps the
/// `u16` channels arg bgfx exposed; the shared mixer takes `u8`, so we narrow.
pub fn loadMusicFromPcm(samples: []const i16, channels: u16, sample_rate: u32) u32 {
    useHeap();
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

test "loadMusicAsset returns 0 for an asset that isn't there" {
    try testing.expectEqual(@as(u32, 0), loadMusicAsset("music/does_not_exist.ogg"));
}

test "loadMusicAsset returns 0 for a name too long for its path buffer" {
    const long = "m" ** 600;
    try testing.expectEqual(@as(u32, 0), loadMusicAsset(long));
}

test "loadMusicAssetAsync reports a missing asset as 0 once the worker is done" {
    var load: MusicAssetLoad = .{};
    try testing.expect(loadMusicAssetAsync(&load, "music/does_not_exist.ogg"));
    const id = while (true) {
        if (load.poll()) |v| break v;
        std.Thread.yield() catch {};
    };
    try testing.expectEqual(@as(u32, 0), id);
}

test "loadMusicAssetAsync refuses a name longer than its buffer" {
    var load: MusicAssetLoad = .{};
    try testing.expect(!loadMusicAssetAsync(&load, "m" ** 300));
    // No room left for the NUL terminator.
    try testing.expect(!loadMusicAssetAsync(&load, "m" ** 256));
}

test "MusicAssetLoad.wait joins the worker and returns its result" {
    var load: MusicAssetLoad = .{};
    try testing.expect(loadMusicAssetAsync(&load, "music/does_not_exist.ogg"));
    try testing.expectEqual(@as(u32, 0), load.wait());
    try testing.expect(load.thread == null);
    // The finished load can be reused.
    try testing.expect(loadMusicAssetAsync(&load, "music/does_not_exist.ogg"));
    try testing.expectEqual(@as(u32, 0), load.wait());
}

test "MusicAssetLoad.wait on a load that never started returns 0" {
    var load: MusicAssetLoad = .{};
    try testing.expectEqual(@as(u32, 0), load.wait());
}

test "Android asset music loader is type checked" {
    if (comptime is_android) _ = &loadMusicAssetAndroid;
}
