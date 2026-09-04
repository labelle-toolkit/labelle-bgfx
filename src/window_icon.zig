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

/// Round a non-negative channel value to the nearest `u8`, clamped.
fn quantize(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 255.0)));
}

/// Area-average ("box") downscale of tightly packed RGBA8.
///
/// TRUE area average: each destination pixel covers the real-valued source
/// footprint `[dx·sw/dw, (dx+1)·sw/dw)`, and every source pixel it touches is
/// weighted by its FRACTIONAL overlap with that footprint. Flooring both
/// boundaries instead — the obvious integer version — assigns each source
/// pixel wholly to one destination, so a non-integer ratio like the supported
/// 48→32 alternates one- and two-pixel kernels, shifting edges and aliasing
/// detail. Integer ratios are unaffected: every weight is 1 and the result is
/// the exact block mean.
///
/// PREMULTIPLIED alpha: RGB is accumulated weighted by its own alpha and then
/// un-premultiplied, and alpha is averaged on its own. Averaging straight RGBA
/// would fold the (invisible) colour of fully transparent pixels into the
/// result — opaque red beside transparent white becomes translucent pink, a
/// visible halo once the window system composites the icon. Where a
/// destination pixel is FULLY transparent there is no colour to recover, so
/// its RGB is the unweighted average of the source RGB: that keeps a stated
/// colour (e.g. transparent white stays white) instead of collapsing to black,
/// and is invisible either way.
///
/// Downscale ONLY: asserts `dw <= sw and dh <= sh`. Caller owns the returned
/// `dw*dh*4` buffer.
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

    const x_step = @as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(dw));
    const y_step = @as(f64, @floatFromInt(sh)) / @as(f64, @floatFromInt(dh));

    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        const y_lo = @as(f64, @floatFromInt(dy)) * y_step;
        const y_hi = y_lo + y_step;
        const y0: u32 = @intFromFloat(@floor(y_lo));
        const y1: u32 = @min(sh, @as(u32, @intFromFloat(@ceil(y_hi))));
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            const x_lo = @as(f64, @floatFromInt(dx)) * x_step;
            const x_hi = x_lo + x_step;
            const x0: u32 = @intFromFloat(@floor(x_lo));
            const x1: u32 = @min(sw, @as(u32, @intFromFloat(@ceil(x_hi))));

            // Premultiplied RGB (Σ v·a·w), plain RGB (Σ v·w, the all-transparent
            // fallback), alpha (Σ a·w) and the weight total (Σ w).
            var acc_pre = [3]f64{ 0, 0, 0 };
            var acc_flat = [3]f64{ 0, 0, 0 };
            var acc_a: f64 = 0;
            var acc_w: f64 = 0;

            var sy = y0;
            while (sy < y1) : (sy += 1) {
                const wy = @min(y_hi, @as(f64, @floatFromInt(sy + 1))) -
                    @max(y_lo, @as(f64, @floatFromInt(sy)));
                if (wy <= 0) continue;
                var sx = x0;
                while (sx < x1) : (sx += 1) {
                    const wx = @min(x_hi, @as(f64, @floatFromInt(sx + 1))) -
                        @max(x_lo, @as(f64, @floatFromInt(sx)));
                    if (wx <= 0) continue;
                    const w = wx * wy;
                    const i = (@as(usize, sy) * sw + sx) * 4;
                    const a = @as(f64, @floatFromInt(src[i + 3]));
                    acc_w += w;
                    acc_a += a * w;
                    inline for (0..3) |c| {
                        const v = @as(f64, @floatFromInt(src[i + c]));
                        acc_pre[c] += v * a * w;
                        acc_flat[c] += v * w;
                    }
                }
            }

            const o = (@as(usize, dy) * dw + dx) * 4;
            // `acc_w` is > 0 for every destination pixel (the footprint is
            // never empty), but guard rather than divide by zero on a
            // degenerate rounding.
            if (acc_w <= 0) {
                @memset(out[o..][0..4], 0);
                continue;
            }
            out[o + 3] = quantize(acc_a / acc_w);
            if (acc_a > 0) {
                inline for (0..3) |c| out[o + c] = quantize(acc_pre[c] / acc_a);
            } else {
                inline for (0..3) |c| out[o + c] = quantize(acc_flat[c] / acc_w);
            }
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

test "downscaleBox: a non-integer ratio weights fractional coverage" {
    // 3×1 → 2×1, scale 1.5: the footprints are [0,1.5) and [1.5,3), so the
    // MIDDLE pixel is split half-and-half between them.
    //   dst0 = (0·1 + 90·0.5) / 1.5 = 30
    //   dst1 = (90·0.5 + 30·1) / 1.5 = 50
    // The integer-footprint filter this replaces flooded both boundaries —
    // footprints [0,1) and [1,3) — and produced 0 and 60, shifting the edge.
    const src = [_]u8{
        0, 0, 0, 255, 90, 90, 90, 255, 30, 30, 30, 255,
    };
    const out = try downscaleBox(testing.allocator, &src, 3, 1, 2, 1);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 30, 30, 30, 255 }, out[0..4]);
    try testing.expectEqualSlices(u8, &.{ 50, 50, 50, 255 }, out[4..8]);
}

test "downscaleBox: 48→32 keeps a symmetric edge (the supported non-integer case)" {
    // The ratio the icon path actually hits. A vertical black|white edge down
    // the middle of a 48-wide image must stay centred and symmetric after the
    // 1.5× reduction: with fractional weights the two straddling columns get
    // mirrored blends; with floored footprints they did not.
    const w: u32 = 48;
    const px = try testing.allocator.alloc(u8, w * 4 * 4);
    defer testing.allocator.free(px);
    for (0..4) |y| for (0..w) |x| {
        const v: u8 = if (x < w / 2) 0 else 255;
        @memcpy(px[(y * w + x) * 4 ..][0..4], &[_]u8{ v, v, v, 255 });
    };
    const out = try downscaleBox(testing.allocator, px, w, 4, 32, 4);
    defer testing.allocator.free(out);
    // Mirror symmetry across the centre: out[i] + out[31 - i] == 255.
    for (0..32) |i| {
        const l = out[i * 4];
        const r = out[(31 - i) * 4];
        try testing.expectEqual(@as(u16, 255), @as(u16, l) + @as(u16, r));
    }
    // …and the edge is still an edge: fully black left, fully white right.
    try testing.expectEqual(@as(u8, 0), out[0]);
    try testing.expectEqual(@as(u8, 255), out[31 * 4]);
}

test "downscaleBox: premultiplied alpha — a transparent neighbour cannot tint the colour" {
    // One opaque red pixel and three FULLY TRANSPARENT black ones collapse to
    // a quarter-opacity RED. Straight RGBA averaging returns (64, 0, 0, 64) —
    // a dark halo — because it folds the invisible black into the colour.
    const src = [_]u8{
        255, 0, 0, 255, 0, 0, 0, 0,
        0,   0, 0, 0,   0, 0, 0, 0,
    };
    const out = try downscaleBox(testing.allocator, &src, 2, 2, 1, 1);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u8, 255), out[0]); // red survives at full strength
    try testing.expectEqual(@as(u8, 0), out[1]);
    try testing.expectEqual(@as(u8, 0), out[2]);
    try testing.expectEqual(@as(u8, 64), out[3]); // 255/4, rounded
}

test "buildFrames: an antialiased transparent border does not halo the icon" {
    // The real-world shape of the premultiply bug: a 32×32 icon whose art is
    // opaque red inside a 4px FULLY TRANSPARENT border — the way every icon
    // exported with padding looks. Reduced to 16×16, the ring of pixels that
    // straddles the art edge blends art with border. Under straight RGBA
    // averaging those pixels take on the border's (invisible) black and the
    // icon gains a dark fringe; premultiplied, their hue stays pure red and
    // only their alpha drops.
    const edge: u32 = 32;
    // An ODD border, so the art boundary falls INSIDE a 2×2 reduction block
    // and the boundary ring really is a blend (an even border would align the
    // edge to the block grid and never mix the two).
    const border: u32 = 3;
    const px = try testing.allocator.alloc(u8, edge * edge * 4);
    defer testing.allocator.free(px);
    for (0..edge) |y| for (0..edge) |x| {
        const inside = x >= border and x < edge - border and y >= border and y < edge - border;
        const c: [4]u8 = if (inside) .{ 255, 0, 0, 255 } else .{ 0, 0, 0, 0 };
        @memcpy(px[(y * edge + x) * 4 ..][0..4], &c);
    };

    var set = try buildFrames(testing.allocator, px, edge, edge);
    defer set.deinit();
    const small = set.slice()[1].pixels; // the 16×16 frame
    try testing.expectEqual(@as(u32, 16), set.slice()[1].size);

    // Every pixel with ANY opacity is pure red — no channel bleed at all.
    var saw_partial = false;
    for (0..16 * 16) |i| {
        const p = small[i * 4 ..][0..4];
        if (p[3] == 0) continue;
        try testing.expectEqual(@as(u8, 255), p[0]);
        try testing.expectEqual(@as(u8, 0), p[1]);
        try testing.expectEqual(@as(u8, 0), p[2]);
        if (p[3] != 255) saw_partial = true;
    }
    // The reduction really does straddle the edge (2px border at 16 → the
    // boundary ring is partially covered), so the test is exercising the
    // blend it claims to.
    try testing.expect(saw_partial);
}

test "downscaleBox: a fully transparent block keeps its stated colour, not black" {
    // No alpha anywhere means no colour to recover, so RGB falls back to the
    // plain average — transparent white stays white rather than collapsing to
    // black. Invisible either way, but it keeps `buildFrames` round-tripping
    // an all-transparent region unchanged.
    const src = [_]u8{
        255, 255, 255, 0, 255, 255, 255, 0,
        255, 255, 255, 0, 255, 255, 255, 0,
    };
    const out = try downscaleBox(testing.allocator, &src, 2, 2, 1, 1);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, out);
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
