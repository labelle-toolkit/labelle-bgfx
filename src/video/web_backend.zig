//! VideoBackend for the wasm build — satisfies labelle-core's VideoInterface
//! with the browser's own decoder (see `web.zig` / `web_video.c`).
//!
//! Same handle pool and public decls as `video/backend.zig`, which can't be
//! used here: it imports the desktop (ffmpeg subprocess) and Android decoders,
//! whose CPU YUV path spawns threads. Clips resolve to the URL `assets/<name>`
//! relative to the page, matching the desktop `assets/<name>` path, so a game
//! deploys the file next to `index.html` under `assets/`.
//!
//! Playback is MUTED (browser autoplay policy), so there is no audio track and
//! deliberately no `setAudioBackend`: the engine only injects one when this decl
//! exists, and the wasm mixer has no output to sync against. The `<video>`
//! element's clock drives pacing instead.

const std = @import("std");
const state = @import("../gfx/state.zig");
const fit = @import("fit.zig");
const player_mod = @import("player.zig");
const web = @import("web.zig");

pub const VideoBackend = struct {
    const Player = player_mod.Player(web.VideoDecoder);
    const MAX = 8;

    const Slot = struct {
        player: Player = undefined,
        used: bool = false,
    };

    var slots: [MAX]Slot = [_]Slot{.{}} ** MAX;
    const alloc = std.heap.c_allocator;

    fn freeSlot() ?usize {
        for (&slots, 0..) |*s, i| if (!s.used) return i;
        return null;
    }
    fn slotPtr(id: u32) ?*Slot {
        if (id == 0 or id > MAX) return null;
        const s = &slots[id - 1];
        return if (s.used) s else null;
    }

    /// Open a clip by asset name (`assets/<name>` relative to the page). Returns
    /// a handle immediately; the browser loads and decodes in the background,
    /// and a clip that can't play ends on its own (`isVideoPlaying` → false).
    pub fn openVideo(name: []const u8) u32 {
        const idx = freeSlot() orelse return 0;
        var urlbuf: [512]u8 = undefined;
        const url = std.fmt.bufPrintSentinel(&urlbuf, "assets/{s}", .{name}, 0) catch return 0;
        const dec = web.VideoDecoder.open(url.ptr) orelse return 0;
        const ctx = dec.clockCtx();
        var pl = Player.init(alloc, dec, 0) catch return 0;
        pl.setAudio(.{ .ctx = ctx, .clock = web.VideoDecoder.clock });
        slots[idx] = .{ .player = pl, .used = true };
        return @intCast(idx + 1);
    }

    pub fn updateVideo(id: u32, dt: f32) void {
        if (slotPtr(id)) |s| s.player.update(dt);
    }

    pub fn drawVideo(id: u32, x: f32, y: f32, w: f32, h: f32) void {
        if (slotPtr(id)) |s| s.player.draw(.{ .x = x, .y = y, .width = w, .height = h });
    }

    /// Fill the whole framebuffer with the current frame. `fit_tag` matches
    /// core.VideoFit: 0=stretch, 1=cover, 2=contain. Same bracketing of the
    /// aspect-fit toggle as the native backend.
    pub fn drawVideoFullscreen(id: u32, fit_tag: u8) void {
        const s = slotPtr(id) orelse return;
        const r = fit.fitRects(
            fit_tag,
            @floatFromInt(web.FRAME_W),
            @floatFromInt(web.FRAME_H),
            @floatFromInt(state.getDesignWidth()),
            @floatFromInt(state.getDesignHeight()),
        );
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

    pub fn replayVideo(id: u32) void {
        if (slotPtr(id)) |s| s.player.replay();
    }

    pub fn videoDimensions(id: u32) struct { w: u32, h: u32 } {
        if (slotPtr(id) != null) return .{ .w = web.FRAME_W, .h = web.FRAME_H };
        return .{ .w = 0, .h = 0 };
    }

    pub fn closeVideo(id: u32) void {
        if (slotPtr(id)) |s| {
            s.player.deinit();
            s.used = false;
        }
    }
};
