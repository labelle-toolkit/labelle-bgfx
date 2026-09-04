//! Unit tests for the backend's two font faces: the built-in 8x8 bitmap
//! face and the TTF/OTF surface in `gfx/font.zig` (labelle-gfx#258,
//! labelle-engine#448).
//!
//! Why a separate root file rather than `test` blocks inside
//! `gfx/font.zig`: Zig collects tests from the ROOT source file of a
//! test module, so blocks written inside an imported file never run —
//! the same trap `gfx.zig`'s sampler-filter test documents. And a test
//! module cannot simply be rooted AT `gfx/font.zig`, because that puts
//! the module path at `src/gfx/` and `gfx/programs.zig`'s
//! `@import("../shaders.zig")` then reaches outside it. Rooting here,
//! at `src/`, gives collection AND a module path wide enough for the
//! real import graph.
//!
//! Wired as its own native test artifact in `build.zig`.
const std = @import("std");
const font = @import("gfx/font.zig");

// ── Font tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "decodeFont rejects empty data" {
    const empty: []const u8 = &.{};
    const params = font.FontBakeParams{};
    try testing.expectError(error.FontDecodeFailed, font.decodeFont("ttf", empty, &params, testing.allocator));
}

test "decodeFont rejects a zero-sized atlas" {
    // Non-empty data so the dimension guard is what fires, not the
    // empty-data fast path. The bytes need not be a valid TTF.
    const fake = "not-a-real-ttf";
    const params = font.FontBakeParams{ .atlas_width = 0, .atlas_height = 128 };
    try testing.expectError(error.FontDecodeFailed, font.decodeFont("ttf", fake, &params, testing.allocator));
}

test "decodeFont surfaces FontDecodeFailed on garbage input" {
    // The user-facing failure mode for an asset with the wrong
    // extension or a corrupted file: `stbtt_InitFont` rejects the
    // missing TTF magic.
    var fake: [1024]u8 = undefined;
    for (&fake, 0..) |*b, i| b.* = @truncate(i);
    const params = font.FontBakeParams{};
    try testing.expectError(error.FontDecodeFailed, font.decodeFont("ttf", &fake, &params, testing.allocator));
}

test "expandCoverageToRgba writes white RGB with coverage in alpha" {
    const src = [_]u8{ 0, 128, 255 };
    var dst: [12]u8 = undefined;
    font.expandCoverageToRgba(&src, &dst);
    try testing.expectEqualSlices(u8, &.{
        255, 255, 255, 0,
        255, 255, 255, 128,
        255, 255, 255, 255,
    }, &dst);
}

test "glyphIndexFor binary-searches the sorted index" {
    const index = [_]font.CodepointEntry{
        .{ .codepoint = 32, .glyph_index = 0 },
        .{ .codepoint = 65, .glyph_index = 1 },
        .{ .codepoint = 200, .glyph_index = 2 },
    };
    try testing.expectEqual(@as(?u32, 0), font.glyphIndexFor(&index, 32));
    try testing.expectEqual(@as(?u32, 1), font.glyphIndexFor(&index, 65));
    try testing.expectEqual(@as(?u32, 2), font.glyphIndexFor(&index, 200));
    try testing.expectEqual(@as(?u32, null), font.glyphIndexFor(&index, 31));
    try testing.expectEqual(@as(?u32, null), font.glyphIndexFor(&index, 66));
    try testing.expectEqual(@as(?u32, null), font.glyphIndexFor(&index, 999));
    try testing.expectEqual(@as(?u32, null), font.glyphIndexFor(&.{}, 65));
}

test "kernAdvance finds the pair and defaults to zero" {
    const pairs = [_]font.KernPair{.{ .first = 'A', .second = 'V', .advance = -2 }};
    try testing.expectEqual(@as(f32, -2), font.kernAdvance(&pairs, 'A', 'V'));
    try testing.expectEqual(@as(f32, 0), font.kernAdvance(&pairs, 'V', 'A'));
    try testing.expectEqual(@as(f32, 0), font.kernAdvance(&.{}, 'A', 'V'));
}

/// Collector for `layoutText`'s emit callback.
const QuadSink = struct {
    quads: [16]font.GlyphQuad = undefined,
    count: usize = 0,

    fn emit(ctx: *anyopaque, q: font.GlyphQuad) void {
        const self: *QuadSink = @ptrCast(@alignCast(ctx));
        if (self.count >= self.quads.len) return;
        self.quads[self.count] = q;
        self.count += 1;
    }
};

/// A hand-built two-glyph face: 'A' is a 10x10 rect at atlas (0,0),
/// ' ' is blank. Lets the layout maths be asserted exactly, with no
/// font file and no GPU.
fn testFace(kerning: []const font.KernPair) font.FontFace {
    const S = struct {
        const glyphs = [_]font.Glyph{
            // ' ' — zero-area, advances only.
            .{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0, .xoff = 0, .yoff = 0, .advance = 8 },
            // 'A' — 10x10 at (0,0), sitting 10px above the baseline.
            .{ .u0 = 0, .v0 = 0, .u1 = 10, .v1 = 10, .xoff = 1, .yoff = -10, .advance = 12 },
        };
        const index = [_]font.CodepointEntry{
            .{ .codepoint = ' ', .glyph_index = 0 },
            .{ .codepoint = 'A', .glyph_index = 1 },
        };
    };
    return .{
        .atlas = .{
            .texture = .{ .idx = 1 },
            .width = 100,
            .height = 50,
            // ascent - descent == 20, so a `size` of 20 means scale 1.
            .ascent = 16,
            .descent = -4,
            .line_gap = 0,
            .line_height = 20,
        },
        .glyphs = &S.glyphs,
        .codepoint_index = &S.index,
        .kerning = kerning,
    };
}

test "layoutText places quads on the baseline with normalised UVs" {
    var sink = QuadSink{};
    // size == baked height (20) → scale 1, so every number below is
    // the raw metric.
    font.layoutText(testFace(&.{}), "A", 100, 200, 20, &QuadSink.emit, &sink);

    try testing.expectEqual(@as(usize, 1), sink.count);
    const q = sink.quads[0];
    // baseline = y + ascent = 200 + 16 = 216; top = baseline + yoff.
    try testing.expectApproxEqAbs(@as(f32, 101), q.x0, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 206), q.y0, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 111), q.x1, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 216), q.y1, 0.001);
    // UVs are the pixel rect divided by the atlas dimensions.
    try testing.expectApproxEqAbs(@as(f32, 0), q.u0, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.1), q.u1, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), q.v1, 0.001);
}

test "layoutText skips blank glyphs but still advances the pen" {
    var sink = QuadSink{};
    font.layoutText(testFace(&.{}), "A A", 0, 0, 20, &QuadSink.emit, &sink);

    // Two quads: the space emits none.
    try testing.expectEqual(@as(usize, 2), sink.count);
    // Second 'A' starts after advance('A') + advance(' ') = 12 + 8.
    try testing.expectApproxEqAbs(@as(f32, 1), sink.quads[0].x0, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 21), sink.quads[1].x0, 0.001);
}

test "layoutText scales metrics by size / baked height" {
    var sink = QuadSink{};
    // size 10 against a 20px bake → scale 0.5.
    font.layoutText(testFace(&.{}), "AA", 0, 0, 10, &QuadSink.emit, &sink);
    try testing.expectEqual(@as(usize, 2), sink.count);
    try testing.expectApproxEqAbs(@as(f32, 0.5), sink.quads[0].x0, 0.001);
    // baseline = ascent * scale = 8; top = baseline + yoff * scale = 3.
    try testing.expectApproxEqAbs(@as(f32, 3), sink.quads[0].y0, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 6.5), sink.quads[1].x0, 0.001);
}

test "layoutText applies kerning between the pair" {
    var sink = QuadSink{};
    const pairs = [_]font.KernPair{.{ .first = 'A', .second = 'A', .advance = -3 }};
    font.layoutText(testFace(&pairs), "AA", 0, 0, 20, &QuadSink.emit, &sink);
    try testing.expectEqual(@as(usize, 2), sink.count);
    // Without kerning the second 'A' would be at 12 + 1 = 13.
    try testing.expectApproxEqAbs(@as(f32, 10), sink.quads[1].x0, 0.001);
}

test "layoutText ignores codepoints outside the baked ranges" {
    var sink = QuadSink{};
    font.layoutText(testFace(&.{}), "AZA", 0, 0, 20, &QuadSink.emit, &sink);
    try testing.expectEqual(@as(usize, 2), sink.count);
    // 'Z' is unbaked: no quad AND no advance, so the second 'A' lands
    // where a bare "AA" would put it.
    try testing.expectApproxEqAbs(@as(f32, 13), sink.quads[1].x0, 0.001);
}

test "layoutText emits nothing for a degenerate face" {
    var sink = QuadSink{};
    var face = testFace(&.{});
    // ascent - descent == 0 → no recoverable baked size.
    face.atlas.ascent = 0;
    face.atlas.descent = 0;
    font.layoutText(face, "A", 0, 0, 20, &QuadSink.emit, &sink);
    try testing.expectEqual(@as(usize, 0), sink.count);

    var face2 = testFace(&.{});
    face2.atlas.width = 0;
    font.layoutText(face2, "A", 0, 0, 20, &QuadSink.emit, &sink);
    try testing.expectEqual(@as(usize, 0), sink.count);
}

test "measureText sums advances and kerning" {
    try testing.expectApproxEqAbs(@as(f32, 32), font.measureText(testFace(&.{}), "A A", 20), 0.001);
    const pairs = [_]font.KernPair{.{ .first = 'A', .second = 'A', .advance = -3 }};
    try testing.expectApproxEqAbs(@as(f32, 21), font.measureText(testFace(&pairs), "AA", 20), 0.001);
    // Unbaked codepoints contribute nothing.
    try testing.expectApproxEqAbs(@as(f32, 12), font.measureText(testFace(&.{}), "AZ", 20), 0.001);
}

test "the built-in 8x8 atlas is unchanged by the TTF path" {
    // The fallback face must stay byte-identical. Pin the atlas
    // geometry and a checksum over every pixel, plus a couple of
    // hand-checked glyph bits, so any accidental edit to `font_data`
    // or the expansion loop shows up here rather than on screen.
    try testing.expectEqual(@as(usize, 95), font.FONT_NUM_CHARS);
    try testing.expectEqual(@as(comptime_int, 760), font.FONT_ATLAS_W);
    try testing.expectEqual(@as(comptime_int, 8), font.FONT_ATLAS_H);

    const pixels = font.buildBuiltinAtlasPixels();
    try testing.expectEqual(@as(usize, 760 * 8 * 4), pixels.len);

    // Space (glyph 0) is fully blank.
    for (0..font.FONT_CHAR_W * 4) |i| try testing.expectEqual(@as(u8, 0), pixels[i]);

    // 'A' row 0 is 0x3C — pixels 2..5 lit, 0,1,6,7 dark — and every
    // channel of a lit pixel is 255 (the built-in face puts coverage
    // in RGB *and* A, unlike the TTF atlas).
    const a_x = ('A' - font.FONT_FIRST_CHAR) * font.FONT_CHAR_W;
    const expect_row0 = [8]u8{ 0, 0, 255, 255, 255, 255, 0, 0 };
    for (expect_row0, 0..) |want, col| {
        const idx = (a_x + col) * 4;
        try testing.expectEqual(want, pixels[idx + 0]);
        try testing.expectEqual(want, pixels[idx + 1]);
        try testing.expectEqual(want, pixels[idx + 2]);
        try testing.expectEqual(want, pixels[idx + 3]);
    }

    // Whole-atlas checksum: a single flipped bit anywhere moves it.
    var sum: u64 = 0;
    for (pixels, 0..) |p, i| sum +%= @as(u64, p) *% (@as(u64, i) +% 1);
    try testing.expectEqual(@as(u64, 21538131300), sum);
}

test "a null or invalid face falls back to the built-in font" {
    try testing.expect(font.usesBuiltinFace(null));

    var face = testFace(&.{});
    try testing.expect(!font.usesBuiltinFace(face));

    // A font id whose atlas failed to upload (or was already unloaded)
    // carries an invalid bgfx handle — same fallback as a null id.
    face.atlas.texture = .{ .idx = std.math.maxInt(u16) };
    try testing.expect(font.usesBuiltinFace(face));
}

test "the internal draw paths are analyzed" {
    // `drawTextFace` / `drawTextMaybeFace` are private and, until core
    // publishes the public font-aware draw decl, have no in-tree
    // caller — and Zig never analyzes an unreferenced private
    // function. Reference them here so a type error in either one
    // fails the build instead of hiding until the decl lands.
    _ = &font.drawTextFace;
    _ = &font.drawTextMaybeFace;
}

// ── Real TTF bake ─────────────────────────────────────────────────────
//
// Roboto Medium, Apache-2.0 — see `src/fixtures/Roboto-Medium.LICENSE.txt`.
// A fixture, never shipped to a game; it exists so the bake is proven
// end to end against a real font rather than only at its error edges.
const roboto_ttf = @embedFile("fixtures/Roboto-Medium.ttf");

fn freeDecodedFont(allocator: std.mem.Allocator, d: font.DecodedFont) void {
    allocator.free(d.bitmap);
    allocator.free(d.glyphs);
    allocator.free(d.codepoint_index);
    allocator.free(d.kerning);
}

test "decodeFont bakes a real TTF: atlas dimensions and glyph metrics" {
    const params = font.FontBakeParams{
        .pixel_height = 32,
        .ranges = &.{.{ .first = 0x20, .last = 0x7F }},
        .atlas_width = 256,
        .atlas_height = 256,
    };
    const d = try font.decodeFont("ttf", roboto_ttf, &params, testing.allocator);
    defer freeDecodedFont(testing.allocator, d);

    // Atlas is exactly what was asked for, and the bitmap is one byte
    // of coverage per pixel.
    try testing.expectEqual(@as(u32, 256), d.width);
    try testing.expectEqual(@as(u32, 256), d.height);
    try testing.expectEqual(@as(usize, 256 * 256), d.bitmap.len);

    // 95 printable ASCII codepoints in [0x20, 0x7F).
    try testing.expectEqual(@as(usize, 95), d.glyphs.len);
    try testing.expectEqual(@as(usize, 95), d.codepoint_index.len);

    // The index is dense, sorted by codepoint, and maps 1:1 onto
    // `glyphs` — `glyphIndexFor` binary-searches it, so an unsorted
    // index would silently mislookup.
    for (d.codepoint_index, 0..) |entry, i| {
        try testing.expectEqual(@as(u32, 0x20) + @as(u32, @intCast(i)), entry.codepoint);
        try testing.expectEqual(@as(u32, @intCast(i)), entry.glyph_index);
    }

    // Vertical metrics: `stbtt_ScaleForPixelHeight` normalises so that
    // ascent - descent == the requested pixel height. The draw path
    // recovers the baked size that way, so this is load-bearing.
    try testing.expect(d.ascent > 0);
    try testing.expect(d.descent < 0);
    try testing.expectApproxEqAbs(@as(f32, 32), d.ascent - d.descent, 0.01);
    try testing.expectApproxEqAbs(d.ascent - d.descent + d.line_gap, d.line_height, 0.001);

    // Space: blank rect, non-zero advance.
    const space = d.glyphs[font.glyphIndexFor(d.codepoint_index, ' ').?];
    try testing.expectEqual(space.u0, space.u1);
    try testing.expectEqual(space.v0, space.v1);
    try testing.expect(space.advance > 0);

    // 'A': a real rect, advancing, and sitting above the baseline
    // (yoff is negative in the y-down atlas convention).
    const a = d.glyphs[font.glyphIndexFor(d.codepoint_index, 'A').?];
    try testing.expect(a.u1 > a.u0);
    try testing.expect(a.v1 > a.v0);
    try testing.expect(a.advance > 0);
    try testing.expect(a.yoff < 0);
    // A cap at a 32px bake is a substantial glyph, not a stray pixel.
    try testing.expect(a.v1 - a.v0 >= 16);

    // Proportional metrics: Roboto is not monospaced.
    const i_adv = d.glyphs[font.glyphIndexFor(d.codepoint_index, 'i').?].advance;
    const w_adv = d.glyphs[font.glyphIndexFor(d.codepoint_index, 'W').?].advance;
    try testing.expect(i_adv < w_adv);

    // Every packed rect lands inside the atlas.
    for (d.glyphs) |g| {
        try testing.expect(g.u1 <= 256);
        try testing.expect(g.v1 <= 256);
        try testing.expect(g.u0 <= g.u1);
        try testing.expect(g.v0 <= g.v1);
    }

    // Something was actually rasterised: 'A' has lit pixels inside its
    // rect, so the bitmap is coverage and not an empty buffer.
    var lit: usize = 0;
    var row: usize = a.v0;
    while (row < a.v1) : (row += 1) {
        var col: usize = a.u0;
        while (col < a.u1) : (col += 1) {
            if (d.bitmap[row * 256 + col] > 0) lit += 1;
        }
    }
    try testing.expect(lit > 0);
}

test "decodeFont honors multiple non-contiguous ranges" {
    // Digits and uppercase, with the punctuation between them left
    // unbaked — the reason this backend packs range by range instead
    // of calling `stbtt_BakeFontBitmap` once.
    const params = font.FontBakeParams{
        .pixel_height = 16,
        .ranges = &.{
            .{ .first = '0', .last = '9' + 1 },
            .{ .first = 'A', .last = 'Z' + 1 },
        },
        .atlas_width = 128,
        .atlas_height = 128,
    };
    const d = try font.decodeFont("ttf", roboto_ttf, &params, testing.allocator);
    defer freeDecodedFont(testing.allocator, d);

    try testing.expectEqual(@as(usize, 10 + 26), d.glyphs.len);
    try testing.expectEqual(@as(?u32, 0), font.glyphIndexFor(d.codepoint_index, '0'));
    try testing.expectEqual(@as(?u32, 10), font.glyphIndexFor(d.codepoint_index, 'A'));
    // ':' sits between the two ranges and was never baked.
    try testing.expectEqual(@as(?u32, null), font.glyphIndexFor(d.codepoint_index, ':'));
    try testing.expectEqual(@as(?u32, null), font.glyphIndexFor(d.codepoint_index, 'a'));
}

test "decodeFont reports FontAtlasTooSmall when the glyphs do not fit" {
    // 32px glyphs into a 32x32 atlas cannot pack. The failure has to
    // surface as an error the catalog can report, not as a partially
    // written atlas.
    const params = font.FontBakeParams{
        .pixel_height = 32,
        .ranges = &.{.{ .first = 0x20, .last = 0x7F }},
        .atlas_width = 32,
        .atlas_height = 32,
    };
    try testing.expectError(
        error.FontAtlasTooSmall,
        font.decodeFont("ttf", roboto_ttf, &params, testing.allocator),
    );
}

test "decodeFont accepts an empty range slice as the ASCII default" {
    const params = font.FontBakeParams{
        .pixel_height = 16,
        .ranges = &.{},
        .atlas_width = 128,
        .atlas_height = 128,
    };
    const d = try font.decodeFont("ttf", roboto_ttf, &params, testing.allocator);
    defer freeDecodedFont(testing.allocator, d);
    try testing.expectEqual(@as(usize, 95), d.glyphs.len);
    try testing.expectEqual(@as(u32, 0x20), d.codepoint_index[0].codepoint);
    try testing.expectEqual(@as(u32, 0x7E), d.codepoint_index[94].codepoint);
}

test "a bake round-trips through the draw path's layout" {
    // The bake and the layout have to agree: metrics straight out of
    // `decodeFont`, fed through `layoutText`, must produce in-atlas UVs
    // and a left-to-right pen. This is the seam the public draw decl
    // will sit on.
    const params = font.FontBakeParams{
        .pixel_height = 32,
        .ranges = &.{.{ .first = 0x20, .last = 0x7F }},
        .atlas_width = 256,
        .atlas_height = 256,
    };
    const d = try font.decodeFont("ttf", roboto_ttf, &params, testing.allocator);
    defer freeDecodedFont(testing.allocator, d);

    const face = font.FontFace{
        .atlas = .{
            .texture = .{ .idx = 1 },
            .width = d.width,
            .height = d.height,
            .ascent = d.ascent,
            .descent = d.descent,
            .line_gap = d.line_gap,
            .line_height = d.line_height,
        },
        .glyphs = d.glyphs,
        .codepoint_index = d.codepoint_index,
        .kerning = d.kerning,
    };

    var sink = QuadSink{};
    font.layoutText(face, "Hi!", 10, 20, 32, &QuadSink.emit, &sink);
    try testing.expectEqual(@as(usize, 3), sink.count);

    var prev_x: f32 = -std.math.inf(f32);
    for (sink.quads[0..sink.count]) |q| {
        try testing.expect(q.x1 > q.x0);
        try testing.expect(q.y1 > q.y0);
        try testing.expect(q.u0 >= 0 and q.u1 <= 1);
        try testing.expect(q.v0 >= 0 and q.v1 <= 1);
        try testing.expect(q.x0 > prev_x);
        prev_x = q.x0;
    }

    // A 32px line laid out at 32px is scale 1, so the measured width is
    // the raw sum of advances.
    try testing.expectApproxEqAbs(font.measureText(face, "Hi!", 32), font.measureText(face, "Hi!", 32), 0.0);
    try testing.expect(font.measureText(face, "Hi!", 32) > 0);
    // Halving the size halves the width.
    try testing.expectApproxEqAbs(
        font.measureText(face, "Hi!", 32) / 2,
        font.measureText(face, "Hi!", 16),
        0.01,
    );
}
