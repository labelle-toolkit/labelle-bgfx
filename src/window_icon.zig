//! Window-icon frame preparation for `glfwSetWindowIcon` (labelle-cli#359).
//!
//! Pure Zig — no zglfw, no stb, no bgfx — so it EXECUTES on the host under
//! `zig build test` on every target the matrix builds. `window.zig` owns the
//! platform side (decode via the in-tree stb_image, the GLFW call, and the
//! per-target no-op gates); this module owns the two things that are worth
//! testing in isolation:
//!
//!   * the SIZE TABLE — which frames to hand GLFW for a given source, and
//!   * the box DOWNSCALE that produces the smaller frames.
//!
//! ## Why more than one frame
//!
//! GLFW passes the whole array to the window system, which picks the closest
//! size for each use: Windows wants a 32×32 for the title bar and a 16×16 for
//! the taskbar/alt-tab strip (and will otherwise nearest-scale the one image
//! it was given — visibly crunchy from a 512 source); X11 window managers
//! read `_NET_WM_ICON` the same way. So every call ships the source at its
//! native size plus a 32 and a 16, each a proper area-averaged downscale.
//! Sizes at or above the native edge are skipped rather than upscaled — an
//! upscaled icon gains nothing, and the window system scales down from the
//! native frame itself when it has to.

const std = @import("std");

/// The small frames added beside the native image, largest first. Kept as a
/// table (not two literals) so the pair is one edit if a platform ever needs
/// a 48 or a 24 — and so the size-table test pins the contract.
pub const small_sizes = [_]u32{ 32, 16 };

/// Upper bound on the frames one call produces: the native image + every
/// entry of `small_sizes`. Sizes the fixed frame arrays below.
pub const max_frames = 1 + small_sizes.len;

/// The edge sizes to emit for a `native`×`native`-ish source: the native size
/// first, then each `small_sizes` entry strictly SMALLER than `native` (the
/// smaller of the source's two edges — see `buildFrames`). A source that is
/// already 32 or 16 wide yields just itself plus what is smaller; nothing is
/// ever upscaled and no size is emitted twice.
pub fn frameSizes(native: u32, buf: *[max_frames]u32) []const u32 {
    var n: usize = 0;
    buf[n] = native;
    n += 1;
    for (small_sizes) |s| {
        if (s < native) {
            buf[n] = s;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Box (area-average) downscale of tightly packed RGBA8. Each destination
/// pixel averages the whole source footprint it covers — the footprint is
/// `[floor(dx·sw/dw), floor((dx+1)·sw/dw))` and never empty — so a
/// non-integer ratio blends rather than dropping rows, and an integer ratio
/// is the exact block mean. Downscale ONLY: asserts `dw <= sw and dh <= sh`.
/// Caller owns the returned `dw*dh*4` buffer.
pub fn downscaleBox(
    allocator: std.mem.Allocator,
    src: []const u8,
    sw: u32,
    sh: u32,
    dw: u32,
    dh: u32,
) ![]u8 {
    if (sw == 0 or sh == 0 or dw == 0 or dh == 0) return error.InvalidDimensions;
    if (dw > sw or dh > sh) return error.InvalidDimensions;
    const src_len = try std.math.mul(usize, try std.math.mul(usize, sw, sh), 4);
    if (src.len < src_len) return error.InvalidDimensions;

    const out_len = try std.math.mul(usize, try std.math.mul(usize, dw, dh), 4);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        const y0: u32 = @intCast((@as(u64, dy) * sh) / dh);
        const y1: u32 = @max(y0 + 1, @as(u32, @intCast((@as(u64, dy + 1) * sh) / dh)));
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            const x0: u32 = @intCast((@as(u64, dx) * sw) / dw);
            const x1: u32 = @max(x0 + 1, @as(u32, @intCast((@as(u64, dx + 1) * sw) / dw)));
            var acc = [4]u64{ 0, 0, 0, 0 };
            var sy = y0;
            while (sy < y1) : (sy += 1) {
                var sx = x0;
                while (sx < x1) : (sx += 1) {
                    const i = (@as(usize, sy) * sw + sx) * 4;
                    inline for (0..4) |c| acc[c] += src[i + c];
                }
            }
            const count: u64 = @as(u64, y1 - y0) * (x1 - x0);
            const o = (@as(usize, dy) * dw + dx) * 4;
            // Round-to-nearest mean; `count >= 1` by construction.
            inline for (0..4) |c| out[o + c] = @intCast((acc[c] + count / 2) / count);
        }
    }
    return out;
}

/// One GLFW-ready frame: square `size`×`size`, tightly packed RGBA8, owned by
/// the `FrameSet` that produced it.
pub const Frame = struct {
    size: u32,
    pixels: []u8,
};

/// The frames for one `glfwSetWindowIcon` call. `frames[0..count]` are valid;
/// the native frame's `pixels` is a COPY (so the set owns every buffer
/// uniformly and `deinit` needs no special case).
pub const FrameSet = struct {
    frames: [max_frames]Frame = undefined,
    count: usize = 0,
    allocator: std.mem.Allocator,

    pub fn slice(self: *const FrameSet) []const Frame {
        return self.frames[0..self.count];
    }

    pub fn deinit(self: *FrameSet) void {
        for (self.frames[0..self.count]) |f| self.allocator.free(f.pixels);
        self.count = 0;
    }
};

/// Build the frame set for an RGBA8 source: the source itself, then each
/// `frameSizes` entry as a box downscale. A non-square source is reduced to
/// its centred square first (`min(w, h)` edge) so every emitted frame is
/// square — window systems assume square icons and would otherwise stretch.
pub fn buildFrames(allocator: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) !FrameSet {
    if (w == 0 or h == 0) return error.InvalidDimensions;
    const src_len = try std.math.mul(usize, try std.math.mul(usize, w, h), 4);
    if (rgba.len < src_len) return error.InvalidDimensions;

    var set: FrameSet = .{ .allocator = allocator };
    errdefer set.deinit();

    const edge = @min(w, h);
    // Native frame: a straight copy when already square, else the centre crop.
    const native = try allocator.alloc(u8, @as(usize, edge) * edge * 4);
    {
        errdefer allocator.free(native);
        const ox = (w - edge) / 2;
        const oy = (h - edge) / 2;
        var y: u32 = 0;
        while (y < edge) : (y += 1) {
            const src_row = (@as(usize, oy + y) * w + ox) * 4;
            const dst_row = @as(usize, y) * edge * 4;
            @memcpy(native[dst_row .. dst_row + @as(usize, edge) * 4], rgba[src_row .. src_row + @as(usize, edge) * 4]);
        }
    }
    set.frames[0] = .{ .size = edge, .pixels = native };
    set.count = 1;

    var size_buf: [max_frames]u32 = undefined;
    for (frameSizes(edge, &size_buf)[1..]) |s| {
        const px = try downscaleBox(allocator, native, edge, edge, s, s);
        set.frames[set.count] = .{ .size = s, .pixels = px };
        set.count += 1;
    }
    return set;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "frameSizes: native first, then every small size strictly below it" {
    var buf: [max_frames]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 512, 32, 16 }, frameSizes(512, &buf));
    try testing.expectEqualSlices(u32, &.{ 48, 32, 16 }, frameSizes(48, &buf));
    // Exactly 32: no duplicate 32 frame, still gets the 16.
    try testing.expectEqualSlices(u32, &.{ 32, 16 }, frameSizes(32, &buf));
    // Between the two small sizes: only the smaller one is a downscale.
    try testing.expectEqualSlices(u32, &.{ 20, 16 }, frameSizes(20, &buf));
    // At or below the smallest: nothing is ever upscaled.
    try testing.expectEqualSlices(u32, &.{16}, frameSizes(16, &buf));
    try testing.expectEqualSlices(u32, &.{8}, frameSizes(8, &buf));
}

test "downscaleBox: integer ratio is the exact block mean" {
    // 4×4 with four solid 2×2 quadrants → 2×2 of exactly those colours.
    var src: [4 * 4 * 4]u8 = undefined;
    const quad = [4][4]u8{
        .{ 255, 0, 0, 255 }, // top-left red
        .{ 0, 255, 0, 255 }, // top-right green
        .{ 0, 0, 255, 255 }, // bottom-left blue
        .{ 255, 255, 255, 0 }, // bottom-right transparent white
    };
    for (0..4) |y| for (0..4) |x| {
        const q = (y / 2) * 2 + (x / 2);
        @memcpy(src[(y * 4 + x) * 4 ..][0..4], &quad[q]);
    };
    const out = try downscaleBox(testing.allocator, &src, 4, 4, 2, 2);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &quad[0], out[0..4]);
    try testing.expectEqualSlices(u8, &quad[1], out[4..8]);
    try testing.expectEqualSlices(u8, &quad[2], out[8..12]);
    try testing.expectEqualSlices(u8, &quad[3], out[12..16]);
}

test "downscaleBox: averages, never point-samples" {
    // A 2×2 checker of black/white collapses to one mid-grey pixel — a
    // nearest-neighbour pick would return pure black or pure white.
    const src = [_]u8{
        0,   0,   0,   255, 255, 255, 255, 255,
        255, 255, 255, 255, 0,   0,   0,   255,
    };
    const out = try downscaleBox(testing.allocator, &src, 2, 2, 1, 1);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, out);
}

test "downscaleBox: non-integer ratio covers every source pixel once" {
    // 3×1 → 2×1: footprints are [0,1) and [1,3) — the middle pixel is not
    // dropped (as a stride sampler would), it is folded into the second cell.
    const src = [_]u8{
        0, 0, 0, 255, 90, 90, 90, 255, 30, 30, 30, 255,
    };
    const out = try downscaleBox(testing.allocator, &src, 3, 1, 2, 1);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, out[0..4]);
    try testing.expectEqualSlices(u8, &.{ 60, 60, 60, 255 }, out[4..8]);
}

test "downscaleBox: rejects upscales, zero sizes and short buffers" {
    const px = [_]u8{0} ** 16;
    try testing.expectError(error.InvalidDimensions, downscaleBox(testing.allocator, &px, 2, 2, 4, 4));
    try testing.expectError(error.InvalidDimensions, downscaleBox(testing.allocator, &px, 2, 2, 0, 1));
    try testing.expectError(error.InvalidDimensions, downscaleBox(testing.allocator, &px, 0, 2, 1, 1));
    try testing.expectError(error.InvalidDimensions, downscaleBox(testing.allocator, px[0..8], 2, 2, 1, 1));
}

test "buildFrames: a 64-square source yields 64 + 32 + 16 frames" {
    const px = try testing.allocator.alloc(u8, 64 * 64 * 4);
    defer testing.allocator.free(px);
    @memset(px, 200);
    var set = try buildFrames(testing.allocator, px, 64, 64);
    defer set.deinit();
    const frames = set.slice();
    try testing.expectEqual(@as(usize, 3), frames.len);
    try testing.expectEqual(@as(u32, 64), frames[0].size);
    try testing.expectEqual(@as(u32, 32), frames[1].size);
    try testing.expectEqual(@as(u32, 16), frames[2].size);
    for (frames) |f| {
        try testing.expectEqual(@as(usize, f.size) * f.size * 4, f.pixels.len);
        for (f.pixels) |b| try testing.expectEqual(@as(u8, 200), b);
    }
}

test "buildFrames: a non-square source is centre-cropped to a square" {
    // 6 wide × 2 tall: columns 0..1 red, 2..3 green, 4..5 blue. The centred
    // 2×2 crop is the green band, and 2 < 16 so it is the only frame.
    var src: [6 * 2 * 4]u8 = undefined;
    for (0..2) |y| for (0..6) |x| {
        const c: [4]u8 = if (x < 2) .{ 255, 0, 0, 255 } else if (x < 4) .{ 0, 255, 0, 255 } else .{ 0, 0, 255, 255 };
        @memcpy(src[(y * 6 + x) * 4 ..][0..4], &c);
    };
    var set = try buildFrames(testing.allocator, &src, 6, 2);
    defer set.deinit();
    try testing.expectEqual(@as(usize, 1), set.count);
    try testing.expectEqual(@as(u32, 2), set.frames[0].size);
    for (0..4) |i| try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, set.frames[0].pixels[i * 4 ..][0..4]);
}

test "buildFrames: rejects a buffer shorter than w*h*4" {
    const px = [_]u8{0} ** 8;
    try testing.expectError(error.InvalidDimensions, buildFrames(testing.allocator, &px, 4, 4));
    try testing.expectError(error.InvalidDimensions, buildFrames(testing.allocator, &px, 0, 4));
}
