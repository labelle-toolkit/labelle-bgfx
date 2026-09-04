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

test "the module-internal draw paths are analyzed" {
    // `drawTextFace` / `drawTextMaybeFace` are reached only through
    // `drawTextWithFont`'s non-null arm, which nothing exercises until
    // a handle can be resolved. Reference them so a type error in
    // either one fails the build rather than waiting for that.
    _ = &font.drawTextFace;
    _ = &font.drawTextMaybeFace;
}

// ── The font-aware draw seam (labelle-core#75) ────────────────────────

const gfx = @import("gfx.zig");
const core = @import("labelle-core");

test "the backend root binds core's font-aware text draw" {
    // THE POINT OF THIS TEST: the seam is `@hasDecl`-gated, so a
    // misspelled name or a wrong arity does not fail to compile — it
    // fails to BIND, silently, and every text draw quietly keeps going
    // through the plain `drawText` while the code reads as though the
    // font arrived. Pin the decl on the root namespace the contract
    // actually probes (`gfx.zig`, i.e. `BackendGfx`), not on
    // `gfx/font.zig`.
    try testing.expect(@hasDecl(gfx, "drawTextWithFont"));

    // Pin the exact shape: `fn ([:0]const u8, f32, f32, f32, Color,
    // ?FontHandle) void`. An arity or type drift here is the same
    // silent-unbind failure as a rename.
    const info = @typeInfo(@TypeOf(gfx.drawTextWithFont)).@"fn";
    try testing.expectEqual(@as(usize, 6), info.params.len);
    try testing.expectEqual([:0]const u8, info.params[0].type.?);
    try testing.expectEqual(f32, info.params[1].type.?);
    try testing.expectEqual(f32, info.params[2].type.?);
    try testing.expectEqual(f32, info.params[3].type.?);
    try testing.expectEqual(?u32, info.params[5].type.?);
    try testing.expectEqual(void, info.return_type.?);

    // `FontHandle` is core#75's plain `u32` straight-through handle.
    try testing.expectEqual(u32, gfx.FontHandle);

    // And the capability gate itself, when the pinned core is new
    // enough to have it. Guarded because this backend still builds
    // against core pins that predate core#76 — the decl above binds
    // either way, since `FontHandle` is just `u32`.
    if (@hasDecl(core.backend_contract, "hasFontAwareText")) {
        try testing.expect(core.backend_contract.hasFontAwareText(gfx));
    }
}

test "an unregistered handle degrades to the built-in face" {
    // The registry (labelle-bgfx#85) resolves only handles the catalog
    // actually registered. Everything else — a never-registered id, a
    // stale one, `FontId.invalid` — misses, and the draw falls back to
    // the built-in font. A missing improvement, never wrong glyphs.
    resetRegistry();

    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(1));
    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(0));
    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(std.math.maxInt(u32)));

    // …and a null face is exactly what routes to the built-in font.
    try testing.expect(font.usesBuiltinFace(font.fontFaceForHandle(1)));
}

// ── The catalog font registry (labelle-bgfx#85, assembler#703) ────────
//
// The final link: the assembler's `FontBackendAdapter` mints a
// `FontId`, packs it index-low / generation-high, and hands it here with
// the `FontAtlas` this backend returned from `uploadFontAtlas`. Without
// this table `drawTextWithFont` can only ever draw the built-in 8x8
// face, however correct everything upstream is.
//
// These tests drive `retainFontMetrics` / `registerCatalogFont` /
// `unregisterCatalogFont` / `releaseFontMetrics` directly, which is the
// same call order `uploadFontAtlas` → register → unregister →
// `unloadFontAtlas` produces, minus the bgfx calls those two wrap. They
// run `testing.allocator` through `font.metrics_allocator`, so a
// retained copy that is never released fails the test as a leak.

/// The engine's `atlas_mixin.packFontId`, transcribed. THE contract:
/// registering under any other arithmetic keys the table on a number
/// the draw call never produces, and the failure is silent.
fn packFontId(index: u16, generation: u16) u32 {
    return @as(u32, index) | (@as(u32, generation) << 16);
}

fn resetRegistry() void {
    font.metrics_allocator = testing.allocator;
    font.releaseAllCatalogFonts();
}

/// A decoded font whose metrics are distinguishable per `advance`, so a
/// resolved face can be told apart from another registration's.
fn fakeDecoded(advance: f32) font.DecodedFont {
    const S = struct {
        var bitmap = [_]u8{0} ** 4;
        var glyphs: [2]font.Glyph = undefined;
        const index = [_]font.CodepointEntry{
            .{ .codepoint = ' ', .glyph_index = 0 },
            .{ .codepoint = 'A', .glyph_index = 1 },
        };
        const kerning = [_]font.KernPair{.{ .first = 'A', .second = 'A', .advance = -1 }};
    };
    S.glyphs = .{
        .{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0, .xoff = 0, .yoff = 0, .advance = 8 },
        .{ .u0 = 0, .v0 = 0, .u1 = 10, .v1 = 10, .xoff = 1, .yoff = -10, .advance = advance },
    };
    return .{
        .bitmap = &S.bitmap,
        .width = 2,
        .height = 2,
        .glyphs = &S.glyphs,
        .codepoint_index = &S.index,
        .ascent = 16,
        .descent = -4,
        .line_gap = 0,
        .line_height = 20,
        .kerning = &S.kerning,
    };
}

fn fakeAtlas(texture_idx: u16) font.FontAtlas {
    return .{
        .texture = .{ .idx = texture_idx },
        .width = 100,
        .height = 50,
        .ascent = 16,
        .descent = -4,
        .line_gap = 0,
        .line_height = 20,
    };
}

test "a registered handle resolves to its real face" {
    resetRegistry();

    const atlas = fakeAtlas(7);
    font.retainFontMetrics(atlas, fakeDecoded(12));
    defer font.releaseFontMetrics(atlas);

    const handle = packFontId(0, 1); // the catalog's first font
    font.registerCatalogFont(handle, atlas);

    const face = font.fontFaceForHandle(handle) orelse return error.TestUnexpectedResult;
    // The atlas came back intact…
    try testing.expectEqual(@as(u16, 7), face.atlas.texture.idx);
    try testing.expectEqual(@as(u32, 100), face.atlas.width);
    // …and so did the metrics, which is the half that would otherwise
    // have been freed by the caller the moment `uploadFontAtlas`
    // returned. They are a COPY, not the caller's slices.
    try testing.expectEqual(@as(usize, 2), face.glyphs.len);
    try testing.expectEqual(@as(f32, 12), face.glyphs[1].advance);
    try testing.expectEqual(@as(usize, 1), face.kerning.len);
    try testing.expectEqual(@as(?u32, 1), font.glyphIndexFor(face.codepoint_index, 'A'));
    try testing.expect(face.glyphs.ptr != fakeDecoded(12).glyphs.ptr);

    // And this face draws as itself, not as the 8x8 fallback.
    try testing.expect(!font.usesBuiltinFace(face));

    // It lays out: 'A' advances 12 at scale 1 (ascent - descent == 20).
    try testing.expectApproxEqAbs(@as(f32, 12), font.measureText(face, "A", 20), 0.001);
}

test "the FULL packed handle is the key, not the truncated slot index" {
    // The catalog RECYCLES its slot index across an unload/reload, so
    // two different faces differ only in the generation. Keying on
    // `@truncate(handle)` would let a stale draw resolve its
    // successor's face — silently the wrong glyphs, exactly what this
    // registry exists to prevent.
    resetRegistry();

    const first = fakeAtlas(7);
    font.retainFontMetrics(first, fakeDecoded(12));
    const h1 = packFontId(0, 1);
    font.registerCatalogFont(h1, first);

    // The bare index is NOT a key: 0 is `FontId.invalid`'s packing.
    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(0));
    try testing.expect(font.fontFaceForHandle(h1) != null);

    // Reload: unregister-then-unload (the assembler's order), then the
    // same slot index comes back at generation 2.
    font.unregisterCatalogFont(h1);
    font.releaseFontMetrics(first);

    const second = fakeAtlas(9);
    font.retainFontMetrics(second, fakeDecoded(20));
    defer font.releaseFontMetrics(second);
    const h2 = packFontId(0, 2);
    font.registerCatalogFont(h2, second);

    // The stale handle misses; the live one resolves the NEW face.
    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(h1));
    const face = font.fontFaceForHandle(h2) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 9), face.atlas.texture.idx);
    try testing.expectEqual(@as(f32, 20), face.glyphs[1].advance);
}

test "unregisterCatalogFont stops resolution before the atlas is destroyed" {
    // The assembler calls unregister STRICTLY BEFORE `unloadFontAtlas`,
    // so there is no window in which a draw resolves a handle to an
    // atlas whose texture is already gone.
    resetRegistry();

    const atlas = fakeAtlas(3);
    font.retainFontMetrics(atlas, fakeDecoded(12));
    const handle = packFontId(2, 1);
    font.registerCatalogFont(handle, atlas);
    try testing.expect(font.fontFaceForHandle(handle) != null);

    font.unregisterCatalogFont(handle);
    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(handle));
    try testing.expect(font.usesBuiltinFace(font.fontFaceForHandle(handle)));

    // The metrics outlive the unregister — they belong to the atlas,
    // and `unloadFontAtlas` (here its bgfx-free half) is what frees
    // them. `testing.allocator` fails this test if they do not.
    font.releaseFontMetrics(atlas);
}

test "unregistering an unknown handle is a no-op" {
    resetRegistry();

    const atlas = fakeAtlas(4);
    font.retainFontMetrics(atlas, fakeDecoded(12));
    defer font.releaseFontMetrics(atlas);
    const handle = packFontId(1, 1);
    font.registerCatalogFont(handle, atlas);

    // Never registered, already unregistered, and `FontId.invalid` —
    // all reachable, since the catalog's unload path calls this
    // unconditionally, including for fonts this backend never retained.
    font.unregisterCatalogFont(packFontId(9, 9));
    font.unregisterCatalogFont(0);
    font.unregisterCatalogFont(std.math.maxInt(u32));

    // The live registration is untouched.
    try testing.expect(font.fontFaceForHandle(handle) != null);

    font.unregisterCatalogFont(handle);
    font.unregisterCatalogFont(handle); // twice is fine too
    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(handle));
}

test "registering over an occupied handle rebinds it, last one wins" {
    // The catalog should never reuse a live handle for a second atlas,
    // but the seam must not end up with two entries answering to one
    // key — an ambiguous lookup is exactly the silent-wrong-glyphs
    // failure mode.
    resetRegistry();

    const old = fakeAtlas(11);
    const new = fakeAtlas(12);
    font.retainFontMetrics(old, fakeDecoded(12));
    font.retainFontMetrics(new, fakeDecoded(20));
    defer font.releaseFontMetrics(old);
    defer font.releaseFontMetrics(new);

    const handle = packFontId(5, 1);
    font.registerCatalogFont(handle, old);
    font.registerCatalogFont(handle, new);

    const face = font.fontFaceForHandle(handle) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 12), face.atlas.texture.idx);
    try testing.expectEqual(@as(f32, 20), face.glyphs[1].advance);

    // One unregister clears the key completely — the displaced entry
    // did not stay bound underneath it.
    font.unregisterCatalogFont(handle);
    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(handle));
}

test "registering an atlas whose metrics were never retained is a no-op" {
    // What a full table (or a failed metrics copy) looks like from the
    // register side: no entry to stamp, so the handle stays
    // unresolvable and the text renders in the built-in face.
    resetRegistry();

    const handle = packFontId(6, 1);
    font.registerCatalogFont(handle, fakeAtlas(20));
    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(handle));

    // An invalid atlas handle (a failed upload) retains nothing either.
    const dead = fakeAtlas(std.math.maxInt(u16));
    font.retainFontMetrics(dead, fakeDecoded(12));
    font.registerCatalogFont(handle, dead);
    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(handle));
}

test "a full registry declines the overflow and keeps the rest resolvable" {
    resetRegistry();
    defer font.releaseAllCatalogFonts();

    for (0..font.MAX_CATALOG_FONTS) |i| {
        const idx: u16 = @intCast(i);
        const atlas = fakeAtlas(idx);
        font.retainFontMetrics(atlas, fakeDecoded(12));
        font.registerCatalogFont(packFontId(idx, 1), atlas);
    }
    // Every one of them resolves.
    for (0..font.MAX_CATALOG_FONTS) |i| {
        const idx: u16 = @intCast(i);
        try testing.expect(font.fontFaceForHandle(packFontId(idx, 1)) != null);
    }

    // One more than the table holds: retained nothing, so it is not
    // registrable — and, crucially, it evicts nothing.
    const overflow = fakeAtlas(font.MAX_CATALOG_FONTS);
    font.retainFontMetrics(overflow, fakeDecoded(20));
    const overflow_handle = packFontId(font.MAX_CATALOG_FONTS, 1);
    font.registerCatalogFont(overflow_handle, overflow);

    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(overflow_handle));
    try testing.expect(font.usesBuiltinFace(font.fontFaceForHandle(overflow_handle)));
    try testing.expect(font.fontFaceForHandle(packFontId(0, 1)) != null);
    try testing.expect(font.fontFaceForHandle(packFontId(font.MAX_CATALOG_FONTS - 1, 1)) != null);

    // A slot freed by an unload makes room again.
    font.unregisterCatalogFont(packFontId(0, 1));
    font.releaseFontMetrics(fakeAtlas(0));
    font.retainFontMetrics(overflow, fakeDecoded(20));
    font.registerCatalogFont(overflow_handle, overflow);
    try testing.expect(font.fontFaceForHandle(overflow_handle) != null);
}

test "releaseAllCatalogFonts empties the registry on teardown" {
    // `destroyFontAtlas` (backend teardown, Android surface loss) takes
    // the bgfx context with it, so every registered atlas texture dies
    // whether or not the catalog unloaded its fonts one by one. The
    // registry must not survive that pointing at destroyed textures —
    // and must not leak the retained metrics either.
    resetRegistry();

    const atlas = fakeAtlas(31);
    font.retainFontMetrics(atlas, fakeDecoded(12));
    const handle = packFontId(4, 1);
    font.registerCatalogFont(handle, atlas);
    try testing.expect(font.fontFaceForHandle(handle) != null);

    font.releaseAllCatalogFonts();
    try testing.expectEqual(@as(?font.FontFace, null), font.fontFaceForHandle(handle));

    // Idempotent: a second teardown (or an `unloadFontAtlas` arriving
    // after one) must not double-free.
    font.releaseAllCatalogFonts();
    font.releaseFontMetrics(atlas);
}

test "the register/unregister seam is bound on the backend root" {
    // THE POINT OF THIS TEST: the assembler `@hasDecl`-gates
    // `registerCatalogFont` and `unregisterCatalogFont` TOGETHER on the
    // backend root (labelle-assembler#703). A rename, a wrong arity, or
    // declaring only one of them does not fail to compile — the seam
    // just goes comptime-false and every font silently renders in the
    // 8x8 face, which is precisely the bug being closed here.
    try testing.expect(@hasDecl(gfx, "registerCatalogFont"));
    try testing.expect(@hasDecl(gfx, "unregisterCatalogFont"));

    const reg = @typeInfo(@TypeOf(gfx.registerCatalogFont)).@"fn";
    try testing.expectEqual(@as(usize, 2), reg.params.len);
    try testing.expectEqual(u32, reg.params[0].type.?);
    try testing.expectEqual(gfx.FontAtlas, reg.params[1].type.?);
    try testing.expectEqual(void, reg.return_type.?);

    const unreg = @typeInfo(@TypeOf(gfx.unregisterCatalogFont)).@"fn";
    try testing.expectEqual(@as(usize, 1), unreg.params.len);
    try testing.expectEqual(u32, unreg.params[0].type.?);
    try testing.expectEqual(void, unreg.return_type.?);
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
