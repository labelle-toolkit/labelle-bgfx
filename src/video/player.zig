//! VideoPlayer — wires a video decoder to a bgfx dynamic texture
//! (FP#549 Path A: Half 2 decode → Half 1 display).
//!
//! Generic over the decoder so the same wiring drives either backend decoder:
//!   - desktop: `video/desktop.zig` (ffmpeg)
//!   - Android: `video/android.zig` (AMediaCodec)
//! A decoder just needs `width()`, `height()`, `decodeFrame([]u8) ?f64`, and
//! `deinit()`. `decodeFrame` fills the RGBA8 buffer and returns the decoded
//! frame's presentation timestamp in seconds (the PTS, used for A/V sync), or
//! `null` when no frame was produced / the stream ended. A decoder MAY also
//! expose optional `eof()` and `replay(allocator)` decls, which the player uses
//! via `@hasDecl` for end-of-stream detection and engine-driven looping. The
//! player owns the dynamic texture (`gfx/texture.zig`): it
//! creates one sized to the video, paces decoded frames to the clip fps, uploads
//! each via `updateTexture`, and draws it with `drawTexturePro`.

const std = @import("std");
const texture = @import("../gfx/texture.zig");
const types = @import("../gfx/types.zig");
const planes = @import("planes.zig");

/// Comptime kill-switch for the GPU-side YUV→RGBA path (perf/gpu-yuv-video).
/// When true (default) the player uploads raw Y/U/V planes to three R8 textures
/// and converts them in the `fs_yuv` shader during the draw, removing the CPU
/// convert + 8.3 MB/frame RGBA upload that spike the render thread on 1080p. The
/// path is only taken when the decoder exposes `decodeFramePlanes` AND the plane
/// textures create successfully; otherwise it degrades to the CPU RGBA fallback.
/// Flip to `false` to force the CPU path everywhere (debug / shader bring-up).
pub const enable_gpu_yuv = true;

/// Audio lifecycle injected by the game/example so the player can drive an audio
/// track (started with the video, ticked each frame, stopped on teardown)
/// WITHOUT `gfx` depending on the `audio` module. The caller wires these to
/// labelle's audio API (`playMusic`/`updateMusic`/`stopMusic`). Leave null for a
/// silent clip.
///
/// `clock` returns the audio device's current playback position in seconds — the
/// **master clock** for PTS-accurate A/V sync (wire it to
/// `audio.musicPositionSeconds`). When null, the player falls back to wall-clock
/// pacing off the per-frame `dt`.
pub const AudioHooks = struct {
    ctx: ?*anyopaque = null,
    start: ?*const fn (ctx: ?*anyopaque) void = null,
    update: ?*const fn (ctx: ?*anyopaque) void = null,
    stop: ?*const fn (ctx: ?*anyopaque) void = null,
    clock: ?*const fn (ctx: ?*anyopaque) f64 = null,
};

/// Cap on frames decoded-and-dropped in one `update` while catching up, so a
/// long stall can't trigger a decode spiral that stalls the render thread.
const MAX_CATCHUP_FRAMES = 4;

pub fn Player(comptime Decoder: type) type {
    return struct {
        const Self = @This();

        /// GPU-YUV state: the three R8 plane textures + their reusable tight
        /// upload buffers (Y = w*h, U/V = cw*ch). Present only when the GPU path
        /// is active; null means the CPU RGBA fallback (`tex` / `pixels`) is used.
        const GpuState = struct {
            tex: texture.PlaneTextures,
            y: []u8,
            u: []u8,
            v: []u8,
        };

        decoder: Decoder,
        // CPU-fallback frame sink (unused when `gpu` is set: `tex.id` is invalid
        // and `pixels` is empty).
        tex: types.Texture,
        pixels: []u8,
        gpu: ?GpuState,
        allocator: std.mem.Allocator,
        audio: AudioHooks = .{},
        started: bool = false,
        // PTS-accurate sync state (all in seconds):
        play_time: f64 = 0, // master clock — driven by the audio device, or dt
        last_clock: f64 = 0, // previous audio-clock reading (for the delta)
        cur_pts: f64 = -1, // PTS of the frame currently on the texture
        ended: bool = false, // stream drained (set when the decoder reports eof)

        /// Try to stand up the GPU-YUV state (plane textures + tight buffers) for
        /// a `w`×`h` video. Returns null on ANY failure (texture create or alloc),
        /// cleaning up whatever was created, so the caller cleanly falls back to
        /// the CPU path. The buffers are allocated once and reused every frame.
        fn initGpu(allocator: std.mem.Allocator, w: u32, h: u32) ?GpuState {
            const pt = texture.createPlaneTextures(w, h) catch return null;
            const cw = planes.chromaWidth(w);
            const ch = planes.chromaHeight(h);
            const y = allocator.alloc(u8, @as(usize, w) * h) catch {
                texture.unloadPlaneTextures(pt);
                return null;
            };
            const u = allocator.alloc(u8, @as(usize, cw) * ch) catch {
                allocator.free(y);
                texture.unloadPlaneTextures(pt);
                return null;
            };
            const v = allocator.alloc(u8, @as(usize, cw) * ch) catch {
                allocator.free(u);
                allocator.free(y);
                texture.unloadPlaneTextures(pt);
                return null;
            };
            return .{ .tex = pt, .y = y, .u = u, .v = v };
        }

        /// Decode the next frame into the active sink (plane buffers or RGBA),
        /// WITHOUT uploading. Returns the frame PTS or null (no frame / EOS).
        fn decodeNext(self: *Self) ?f64 {
            if (self.gpu) |*g| {
                if (comptime @hasDecl(Decoder, "decodeFramePlanes")) {
                    return self.decoder.decodeFramePlanes(g.y, g.u, g.v);
                }
            }
            return self.decoder.decodeFrame(self.pixels);
        }

        /// Upload the most recently decoded frame to its texture(s).
        fn uploadCurrent(self: *Self) void {
            if (self.gpu) |*g| {
                texture.updatePlaneTextures(g.tex, g.y, g.u, g.v);
            } else {
                texture.updateTexture(self.tex, self.pixels);
            }
        }

        /// Take an already-opened decoder (opening is platform-specific), create
        /// the frame texture(s) sized to it, decode the first frame, and upload
        /// it. Defaults to the GPU-YUV path, degrading to the CPU RGBA path when
        /// unavailable (logged either way so on-device fps/visual tests are clear).
        pub fn init(allocator: std.mem.Allocator, decoder: Decoder, fps: f32) !Self {
            _ = fps; // pacing is now driven by frame PTS, not a fixed rate
            var dec = decoder;
            // `decoder` was moved into `dec`; if a fallible call below fails we'd
            // otherwise leak it (the caller hands ownership in). Release it on any
            // error path. Cancelled on success — the returned struct owns it and
            // `deinit` calls `decoder.deinit()`.
            errdefer dec.deinit();
            const w = dec.width();
            const h = dec.height();

            // Prefer the GPU-YUV path: decoder must expose plane output AND the
            // plane textures must create. Otherwise fall back to CPU RGBA.
            var gpu: ?GpuState = if (enable_gpu_yuv and @hasDecl(Decoder, "decodeFramePlanes"))
                initGpu(allocator, w, h)
            else
                null;
            // The plane textures created, but the GPU draw also needs the
            // `fs_yuv` shader program. If it can't be created (e.g. it won't
            // link on this driver), `submitYuvTriangles` would early-return and
            // draw nothing (black video). Detect that here and release the plane
            // state so this clip permanently uses the CPU RGBA path below.
            if (gpu) |g| {
                if (!texture.yuvProgramReady()) {
                    std.log.warn("video: GPU-YUV shader program unavailable on this renderer; using CPU YUV->RGBA fallback for this clip", .{});
                    texture.unloadPlaneTextures(g.tex);
                    allocator.free(g.y);
                    allocator.free(g.u);
                    allocator.free(g.v);
                    gpu = null;
                }
            }
            errdefer if (gpu) |g| {
                texture.unloadPlaneTextures(g.tex);
                allocator.free(g.y);
                allocator.free(g.u);
                allocator.free(g.v);
            };

            var tex: types.Texture = .{ .id = std.math.maxInt(u32), .width = @intCast(w), .height = @intCast(h) };
            var pixels: []u8 = &.{};
            if (gpu == null) {
                tex = try texture.createDynamicTexture(w, h);
                pixels = try allocator.alloc(u8, @as(usize, w) * h * 4);
            }
            errdefer if (gpu == null) {
                texture.unloadTexture(tex);
                allocator.free(pixels);
            };

            if (gpu != null) {
                std.log.info("video: GPU-YUV path active ({d}x{d}, R8 planes + fs_yuv shader)", .{ w, h });
            } else {
                std.log.info("video: CPU YUV→RGBA fallback active ({d}x{d}, full RGBA upload)", .{ w, h });
            }

            var self: Self = .{ .decoder = dec, .tex = tex, .pixels = pixels, .gpu = gpu, .allocator = allocator };
            if (self.decodeNext()) |pts| {
                self.cur_pts = pts;
                self.uploadCurrent();
            }
            return self;
        }

        /// Attach an audio track (started/ticked/stopped with the video).
        pub fn setAudio(self: *Self, hooks: AudioHooks) void {
            self.audio = hooks;
        }

        /// PTS-accurate A/V sync. The audio device is the master clock: we
        /// advance `play_time` by the *audio clock's* elapsed delta (loop-safe —
        /// a negative delta at a loop boundary contributes zero), then present
        /// the video frame whose PTS the master clock has reached — decoding past
        /// (dropping) frames that are late and holding the current one when the
        /// next is still in the future. Without an audio clock it falls back to
        /// `dt` pacing, still selecting frames by PTS (so VFR is handled).
        pub fn update(self: *Self, dt: f32) void {
            if (!self.started) {
                self.started = true;
                if (self.audio.start) |f| f(self.audio.ctx);
                if (self.audio.clock) |c| self.last_clock = c(self.audio.ctx);
            }
            if (self.audio.update) |f| f(self.audio.ctx);

            // Advance the master clock.
            if (self.audio.clock) |c| {
                const now = c(self.audio.ctx);
                const delta = now - self.last_clock;
                self.last_clock = now;
                self.play_time += if (delta > 0) delta else 0; // skip loop-wrap/pause
            } else {
                self.play_time += dt;
            }

            // Present the frame the master clock has reached; drop late frames.
            var uploaded = false;
            var caught: u32 = 0;
            while (self.cur_pts < self.play_time and caught < MAX_CATCHUP_FRAMES) : (caught += 1) {
                const pts = self.decodeNext() orelse break;
                self.cur_pts = pts;
                uploaded = true;
                // Caught up: this freshly decoded frame's PTS has reached (or
                // overshot) the clock. Upload it (it's the best available next
                // frame) but stop here — don't keep decoding into the future.
                if (pts >= self.play_time) break;
            }
            if (uploaded) self.uploadCurrent();

            // End-of-stream: the decoder drained (only meaningful for decoders
            // that report it; looping/never-ending sources never set it).
            if (comptime @hasDecl(Decoder, "eof")) {
                if (self.decoder.eof()) self.ended = true;
            }
        }

        /// True once the stream has played to the end (play-once clips). Loops are
        /// restarted by the engine via `replay` before this is observed.
        pub fn isEnded(self: *const Self) bool {
            return self.ended;
        }

        /// Restart playback from the beginning (engine-driven loop / replay).
        pub fn replay(self: *Self) void {
            if (comptime @hasDecl(Decoder, "replay")) self.decoder.replay(self.allocator);
            self.play_time = 0;
            self.last_clock = 0;
            self.cur_pts = -1;
            self.ended = false;
            self.started = false; // re-arm the audio start on the next update
            if (self.decodeNext()) |pts| {
                self.cur_pts = pts;
                self.uploadCurrent();
            }
        }

        /// Frame dimensions (luma res for the GPU path = the RGBA tex dims).
        fn frameWidth(self: *const Self) u32 {
            return if (self.gpu) |g| g.tex.width else @intCast(self.tex.width);
        }
        fn frameHeight(self: *const Self) u32 {
            return if (self.gpu) |g| g.tex.height else @intCast(self.tex.height);
        }

        /// Draw the current video frame into `dest` (screen or world space, per
        /// the active camera mode).
        pub fn draw(self: *const Self, dest: types.Rectangle) void {
            const src = types.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(self.frameWidth()),
                .height = @floatFromInt(self.frameHeight()),
            };
            self.drawRegion(src, dest);
        }

        /// Draw a sub-region `src` (in luma/frame pixels) of the current frame
        /// into `dest` — the seam for cover/contain fits (center-crop the source,
        /// or letterbox the dest). Routes to the YUV plane program when the GPU
        /// path is active, else the sprite program with the RGBA texture.
        pub fn drawRegion(self: *const Self, src: types.Rectangle, dest: types.Rectangle) void {
            if (self.gpu) |g| {
                texture.drawPlanesPro(g.tex, src, dest, .{ .x = 0, .y = 0 }, 0, types.white);
            } else {
                texture.drawTexturePro(self.tex, src, dest, .{ .x = 0, .y = 0 }, 0, types.white);
            }
        }

        pub fn deinit(self: *Self) void {
            if (self.audio.stop) |f| f(self.audio.ctx);
            self.decoder.deinit();
            if (self.gpu) |g| {
                texture.unloadPlaneTextures(g.tex);
                self.allocator.free(g.y);
                self.allocator.free(g.u);
                self.allocator.free(g.v);
            } else {
                texture.unloadTexture(self.tex);
                self.allocator.free(self.pixels);
            }
        }
    };
}
