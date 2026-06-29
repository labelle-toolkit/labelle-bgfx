//! VideoBackend — satisfies labelle-core's VideoInterface (FP#549).
//!
//! A small handle pool over `VideoPlayer`: the engine/game calls `openVideo` by
//! resource name, and this resolves the name to a clip and builds the right
//! per-platform decoder + player. So a project plays a video with *just the
//! asset name* (a `VideoComponent` or `game.openVideo("intro")`), no path or
//! codec knowledge needed.
//!
//! Name resolution (until a generated catalog lands):
//!   - desktop: `assets/<name>` (probed for native size/fps via ffprobe).
//!   - Android: the `<name>` asset in the APK, via the bgfx shell's running
//!     NativeActivity AAssetManager.
//!
//! Audio note: in-engine audio for these players needs the audio *module*'s
//! mixer, which the gfx module must not import (it would fork a second mixer).
//! So this first cut is video-only; audio is wired via an injection seam (the
//! player's AudioHooks, fed by the assembler) in a follow-up. The decode/audio/
//! AAudio path is already proven in the example + bgfx-Android app.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../gfx/types.zig");
const state = @import("../gfx/state.zig");
const fit = @import("fit.zig");
const player_mod = @import("player.zig");
const desktop = @import("desktop.zig");
const android = @import("android.zig");
const android_audio = @import("android_audio.zig");

const is_android = builtin.abi == .android or builtin.abi == .androideabi;
const Decoder = if (is_android) android.VideoDecoder else desktop.VideoDecoder;

// Android asset access: the bgfx Android shell exposes the running
// NativeActivity (C export); its AAssetManager resolves bundled clips by name.
extern fn labelle_bgfx_get_native_activity() ?*anyopaque;
const AAssetManager = opaque {};
const AAsset = opaque {};
extern fn AAssetManager_open(*AAssetManager, [*:0]const u8, c_int) ?*AAsset;
extern fn AAsset_openFileDescriptor64(*AAsset, *i64, *i64) c_int;
extern fn AAsset_close(*AAsset) void;
const AASSET_MODE_STREAMING: c_int = 2;
// Closes the dup'd audio fd from AAsset_openFileDescriptor64 once the track is
// decoded (Android-only; unused/unlinked on desktop).
extern fn close(c_int) c_int;

pub const VideoBackend = struct {
    const Player = player_mod.Player(Decoder);
    const MAX = 8;

    const Slot = struct {
        player: Player = undefined,
        w: u32 = 0,
        h: u32 = 0,
        used: bool = false,
        music_id: u32 = 0, // 0 = no audio track / no audio backend
    };

    var slots: [MAX]Slot = [_]Slot{.{}} ** MAX;
    const alloc = std.heap.page_allocator;

    fn freeSlot() ?usize {
        for (&slots, 0..) |*s, i| if (!s.used) return i;
        return null;
    }
    fn slotPtr(id: u32) ?*Slot {
        if (id == 0 or id > MAX) return null;
        const s = &slots[id - 1];
        return if (s.used) s else null;
    }

    // ── Audio injection seam ───────────────────────────────────────────────
    // The gfx module must not import the audio module (that would fork a second
    // mixer), so the app injects the audio mixer's functions here once at
    // startup (the assembler wires it — both backends are visible there). On
    // openVideo we decode the clip's audio track (ffmpeg desktop / AMediaCodec
    // Android) and feed it to the player's AudioHooks through these, so the
    // audio position is the player's master clock for A/V sync (#306/#549).

    pub const AudioBackend = struct {
        loadPcm: *const fn (samples: []const i16, channels: u16, sample_rate: u32) u32,
        play: *const fn (id: u32) void,
        update: *const fn (id: u32) void,
        stop: *const fn (id: u32) void,
        clock: *const fn (id: u32) f64,
        unload: *const fn (id: u32) void,
    };
    var audio_backend: ?AudioBackend = null;

    pub fn setAudioBackend(ab: AudioBackend) void {
        audio_backend = ab;
    }

    // The player's hooks are shared functions; `ctx` carries the music id (a
    // small int stuffed into the pointer) so they know which track to drive.
    fn midFrom(ctx: ?*anyopaque) u32 {
        return @intCast(@intFromPtr(ctx));
    }
    fn hookStart(ctx: ?*anyopaque) void {
        if (audio_backend) |ab| ab.play(midFrom(ctx));
    }
    fn hookUpdate(ctx: ?*anyopaque) void {
        if (audio_backend) |ab| ab.update(midFrom(ctx));
    }
    fn hookStop(ctx: ?*anyopaque) void {
        if (audio_backend) |ab| ab.stop(midFrom(ctx));
    }
    fn hookClock(ctx: ?*anyopaque) f64 {
        if (audio_backend) |ab| return ab.clock(midFrom(ctx));
        return 0;
    }

    /// Load decoded PCM into the mixer and attach it to the player as the master
    /// clock. Best-effort: no audio backend / empty PCM → the video stays silent.
    fn attachAudio(idx: usize, samples: []const i16) void {
        const ab = audio_backend orelse return;
        if (samples.len == 0) return;
        const mid = ab.loadPcm(samples, 2, 48000);
        if (mid == 0) return;
        slots[idx].music_id = mid;
        slots[idx].player.setAudio(.{
            .ctx = @ptrFromInt(mid),
            .start = hookStart,
            .update = hookUpdate,
            .stop = hookStop,
            .clock = hookClock,
        });
    }

    /// Open a video by resource name. `[]const u8` so a `VideoComponent` path
    /// from a scene/JSON string works directly; null-terminated here for the
    /// Android asset API. Returns a handle (0 = failure).
    pub fn openVideo(name: []const u8) u32 {
        const idx = freeSlot() orelse return 0;
        if (is_android) {
            const act = labelle_bgfx_get_native_activity() orelse return 0;
            // ANativeActivity field 8 is `assetManager` (callbacks, vm, env,
            // clazz, internalDataPath, externalDataPath, sdkVersion, instance,
            // assetManager…).
            const fields: [*]const ?*anyopaque = @ptrCast(@alignCast(act));
            const am: *AAssetManager = @ptrCast(fields[8] orelse return 0);
            var namebuf: [256]u8 = undefined;
            if (name.len >= namebuf.len) return 0;
            @memcpy(namebuf[0..name.len], name);
            namebuf[name.len] = 0;
            const namez: [:0]const u8 = namebuf[0..name.len :0];
            const asset = AAssetManager_open(am, namez.ptr, AASSET_MODE_STREAMING) orelse return 0;
            defer AAsset_close(asset);
            var start: i64 = 0;
            var len: i64 = 0;
            // `AAsset_openFileDescriptor64` returns an independent (dup'd) fd, so
            // closing the AAsset above is fine. Ownership of `fd` transfers to the
            // decoder in `openFd` — it `close()`s it in `deinit` (and on its own
            // error paths). We must NOT close `fd` here (no double close).
            const fd = AAsset_openFileDescriptor64(asset, &start, &len);
            if (fd < 0) return 0;
            const dec = android.VideoDecoder.openFd(alloc, fd, start, len) catch return 0;
            const w = dec.width();
            const h = dec.height();
            // Player.init's errdefer deinits the decoder on failure (it owns the
            // fd), so do NOT deinit here too — that would double-close the fd and
            // double-delete the codec. Matches the desktop branch below.
            const pl = Player.init(alloc, dec, 24.0) catch return 0;
            slots[idx] = .{ .player = pl, .w = w, .h = h, .used = true };
            // Best-effort audio: re-open the asset for a FRESH fd (the video
            // decoder owns the first one), decode the track, load + attach it.
            if (audio_backend != null) {
                if (AAssetManager_open(am, namez.ptr, AASSET_MODE_STREAMING)) |a_asset| {
                    defer AAsset_close(a_asset);
                    var a_start: i64 = 0;
                    var a_len: i64 = 0;
                    const a_fd = AAsset_openFileDescriptor64(a_asset, &a_start, &a_len);
                    if (a_fd >= 0) {
                        defer _ = close(a_fd); // decodeTrack reads it synchronously; we own it
                        if (android_audio.decodeTrack(alloc, a_fd, a_start, a_len)) |pcm| {
                            var p = pcm;
                            defer p.deinit(alloc);
                            attachAudio(idx, p.samples);
                        } else |_| {}
                    }
                }
            }
        } else {
            var pathbuf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&pathbuf, "assets/{s}", .{name}) catch return 0;
            const info = desktop.probe(alloc, path) orelse return 0;
            const dec = desktop.VideoDecoder.open(alloc, path, info.w, info.h, info.fps) catch return 0;
            const pl = Player.init(alloc, dec, info.fps) catch return 0;
            slots[idx] = .{ .player = pl, .w = info.w, .h = info.h, .used = true };
            // Best-effort audio: decode the track to PCM (ffmpeg) + attach.
            if (audio_backend != null) {
                if (desktop.VideoDecoder.decodeAudioPcm(alloc, path)) |samples| {
                    defer alloc.free(samples);
                    attachAudio(idx, samples);
                }
            }
        }
        return @intCast(idx + 1);
    }

    pub fn updateVideo(id: u32, dt: f32) void {
        if (slotPtr(id)) |s| s.player.update(dt);
    }

    pub fn drawVideo(id: u32, x: f32, y: f32, w: f32, h: f32) void {
        if (slotPtr(id)) |s| s.player.draw(.{ .x = x, .y = y, .width = w, .height = h });
    }

    /// Fill the whole framebuffer with the current frame — a background.
    /// `fit_tag` matches core.VideoFit: 0=stretch, 1=cover, 2=contain. Drawn with
    /// the aspect-fit toggle off (edge-to-edge framebuffer, like a `screen_fill`
    /// sprite layer); the toggle is bracketed so other draws are unaffected.
    pub fn drawVideoFullscreen(id: u32, fit_tag: u8) void {
        const s = slotPtr(id) orelse return;
        // Crop/letterbox geometry lives in fit.zig (host-tested). cover
        // center-crops the source; contain letterboxes the dest; stretch fills.
        const r = fit.fitRects(
            fit_tag,
            @floatFromInt(s.w),
            @floatFromInt(s.h),
            @floatFromInt(state.getDesignWidth()),
            @floatFromInt(state.getDesignHeight()),
        );
        // Backdrop: fill the framebuffer edge-to-edge (no aspect pillarbox);
        // bracket the toggle so other draws are unaffected.
        state.setApplyFit(false);
        defer state.setApplyFit(true);
        s.player.drawRegion(
            .{ .x = r.src.x, .y = r.src.y, .width = r.src.width, .height = r.src.height },
            .{ .x = r.dest.x, .y = r.dest.y, .width = r.dest.width, .height = r.dest.height },
        );
    }

    pub fn isVideoPlaying(id: u32) bool {
        if (slotPtr(id)) |s| return !s.player.isEnded();
        return false;
    }

    /// Restart a finished clip from the beginning (engine-driven loop).
    pub fn replayVideo(id: u32) void {
        if (slotPtr(id)) |s| s.player.replay();
    }

    pub fn videoDimensions(id: u32) struct { w: u32, h: u32 } {
        if (slotPtr(id)) |s| return .{ .w = s.w, .h = s.h };
        return .{ .w = 0, .h = 0 };
    }

    pub fn closeVideo(id: u32) void {
        if (slotPtr(id)) |s| {
            s.player.deinit(); // stops the audio via the player's stop hook
            if (s.music_id != 0) {
                if (audio_backend) |ab| ab.unload(s.music_id);
                s.music_id = 0;
            }
            s.used = false;
        }
    }
};
