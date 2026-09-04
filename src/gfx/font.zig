/// Two font faces live here.
///
///   1. The **built-in** embedded 8x8 bitmap face (printable ASCII
///      32..126, one-row atlas) behind the contract's mandatory
///      `drawText`. Unchanged, and still the fallback whenever no
///      baked font is in play.
///   2. The **TTF/OTF** face (labelle-gfx#258, labelle-engine#448):
///      `decodeFont` bakes glyphs with stb_truetype on a worker
///      thread, `uploadFontAtlas` turns the bake into a bgfx texture
///      on the render thread, `unloadFontAtlas` releases it.
///
/// The decode/upload split mirrors the image path (`texture.zig`):
/// `decodeFont` is pure CPU and touches NO bgfx state — bgfx's API is
/// not safe to call from the asset worker thread, and stb_truetype
/// only writes into its own pack context plus the allocator-owned
/// bitmap, so the bake is free to run off-thread. Everything that
/// creates or destroys a bgfx handle stays in `uploadFontAtlas` /
/// `unloadFontAtlas`, called from the render thread.
///
/// The value types are `extern struct` so the assembler's
/// `writeFontBackendWiring` field-by-field copy into
/// `engine.DecodedFont` lands on a stable memory layout. Their shape
/// is identical to `labelle-core`'s `backend_contract.zig`
/// definitions; declaring them as top-level `pub` in `gfx.zig` is
/// what opts this backend in to the font traits (the contract
/// `@hasDecl`-guards every one of them).
const std = @import("std");
const builtin = @import("builtin");
const bgfx = @import("zbgfx").bgfx;
const types = @import("types.zig");
const state = @import("state.zig");
const programs = @import("programs.zig");
const texture = @import("texture.zig");

// stb_truetype rides the same shimmed `@cImport` as stb_image (see
// `src/stb_shim.h`) — a single translate-c invocation keeps the two
// header sets sharing one translated set of C declarations, so the
// `stbtt_*` symbols are reachable through `texture.stbi`.
const stbtt = texture.stbi;

const Color = types.Color;
const PosTexColorVertex = programs.PosTexColorVertex;

// ── Text rendering (embedded bitmap font) ─────────────────────────────

/// Embedded 8x8 bitmap font covering printable ASCII (32..126).
/// Each character is 8 rows of 8 bits (1 byte per row, MSB = leftmost pixel).
pub const FONT_CHAR_W = 8;
pub const FONT_CHAR_H = 8;
pub const FONT_FIRST_CHAR = 32; // space
pub const FONT_LAST_CHAR = 126; // tilde
pub const FONT_NUM_CHARS = FONT_LAST_CHAR - FONT_FIRST_CHAR + 1;

/// Font atlas texture (created lazily on first drawText call).
var font_texture: bgfx.TextureHandle = .{ .idx = std.math.maxInt(u16) };
var font_atlas_initialized: bool = false;

/// Atlas dimensions: characters laid out in a single row.
pub const FONT_ATLAS_W = FONT_CHAR_W * FONT_NUM_CHARS;
pub const FONT_ATLAS_H = FONT_CHAR_H;

/// 8x8 bitmap font data. Each entry is 8 bytes (rows top-to-bottom).
const font_data: [FONT_NUM_CHARS][8]u8 = generateFontData();

fn generateFontData() [FONT_NUM_CHARS][8]u8 {
    var data: [FONT_NUM_CHARS][8]u8 = [_][8]u8{[_]u8{0} ** 8} ** FONT_NUM_CHARS;

    // ! (33)
    data[33 - 32] = .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 };
    // " (34)
    data[34 - 32] = .{ 0x6C, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // # (35)
    data[35 - 32] = .{ 0x6C, 0xFE, 0x6C, 0x6C, 0xFE, 0x6C, 0x00, 0x00 };
    // $ (36)
    data[36 - 32] = .{ 0x18, 0x7E, 0x58, 0x7E, 0x1A, 0x7E, 0x18, 0x00 };
    // % (37)
    data[37 - 32] = .{ 0x62, 0x64, 0x08, 0x10, 0x26, 0x46, 0x00, 0x00 };
    // & (38)
    data[38 - 32] = .{ 0x38, 0x6C, 0x38, 0x76, 0xDC, 0x76, 0x00, 0x00 };
    // ' (39)
    data[39 - 32] = .{ 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // ( (40)
    data[40 - 32] = .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 };
    // ) (41)
    data[41 - 32] = .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 };
    // * (42)
    data[42 - 32] = .{ 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00 };
    // + (43)
    data[43 - 32] = .{ 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00 };
    // , (44)
    data[44 - 32] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30 };
    // - (45)
    data[45 - 32] = .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 };
    // . (46)
    data[46 - 32] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 };
    // / (47)
    data[47 - 32] = .{ 0x02, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x40, 0x00 };

    // 0-9
    data['0' - 32] = .{ 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00 };
    data['1' - 32] = .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 };
    data['2' - 32] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00 };
    data['3' - 32] = .{ 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 };
    data['4' - 32] = .{ 0x0C, 0x1C, 0x2C, 0x4C, 0x7E, 0x0C, 0x0C, 0x00 };
    data['5' - 32] = .{ 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 };
    data['6' - 32] = .{ 0x3C, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    data['7' - 32] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00 };
    data['8' - 32] = .{ 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 };
    data['9' - 32] = .{ 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x3C, 0x00 };

    // : (58)
    data[58 - 32] = .{ 0x00, 0x00, 0x18, 0x00, 0x00, 0x18, 0x00, 0x00 };
    // ; (59)
    data[59 - 32] = .{ 0x00, 0x00, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30 };
    // < (60)
    data[60 - 32] = .{ 0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00 };
    // = (61)
    data[61 - 32] = .{ 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00 };
    // > (62)
    data[62 - 32] = .{ 0x60, 0x30, 0x18, 0x0C, 0x18, 0x30, 0x60, 0x00 };
    // ? (63)
    data[63 - 32] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x00, 0x18, 0x00 };
    // @ (64)
    data[64 - 32] = .{ 0x3C, 0x66, 0x6E, 0x6A, 0x6E, 0x60, 0x3C, 0x00 };

    // A-Z
    data['A' - 32] = .{ 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 };
    data['B' - 32] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 };
    data['C' - 32] = .{ 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 };
    data['D' - 32] = .{ 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 };
    data['E' - 32] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 };
    data['F' - 32] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 };
    data['G' - 32] = .{ 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3E, 0x00 };
    data['H' - 32] = .{ 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 };
    data['I' - 32] = .{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 };
    data['J' - 32] = .{ 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38, 0x00 };
    data['K' - 32] = .{ 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 };
    data['L' - 32] = .{ 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 };
    data['M' - 32] = .{ 0xC6, 0xEE, 0xFE, 0xD6, 0xC6, 0xC6, 0xC6, 0x00 };
    data['N' - 32] = .{ 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 };
    data['O' - 32] = .{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    data['P' - 32] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 };
    data['Q' - 32] = .{ 0x3C, 0x66, 0x66, 0x66, 0x6A, 0x6C, 0x36, 0x00 };
    data['R' - 32] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00 };
    data['S' - 32] = .{ 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 };
    data['T' - 32] = .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 };
    data['U' - 32] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    data['V' - 32] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 };
    data['W' - 32] = .{ 0xC6, 0xC6, 0xC6, 0xD6, 0xFE, 0xEE, 0xC6, 0x00 };
    data['X' - 32] = .{ 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 };
    data['Y' - 32] = .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 };
    data['Z' - 32] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 };

    // [ (91)
    data[91 - 32] = .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 };
    // \ (92)
    data[92 - 32] = .{ 0x40, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00 };
    // ] (93)
    data[93 - 32] = .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 };
    // ^ (94)
    data[94 - 32] = .{ 0x18, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // _ (95)
    data[95 - 32] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E, 0x00 };
    // ` (96)
    data[96 - 32] = .{ 0x30, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

    // a-z (lowercase)
    data['a' - 32] = .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 };
    data['b' - 32] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 };
    data['c' - 32] = .{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x66, 0x3C, 0x00 };
    data['d' - 32] = .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 };
    data['e' - 32] = .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 };
    data['f' - 32] = .{ 0x1C, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x30, 0x00 };
    data['g' - 32] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x3C };
    data['h' - 32] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 };
    data['i' - 32] = .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 };
    data['j' - 32] = .{ 0x0C, 0x00, 0x1C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38 };
    data['k' - 32] = .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 };
    data['l' - 32] = .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 };
    data['m' - 32] = .{ 0x00, 0x00, 0xEC, 0xFE, 0xD6, 0xC6, 0xC6, 0x00 };
    data['n' - 32] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 };
    data['o' - 32] = .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    data['p' - 32] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 };
    data['q' - 32] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 };
    data['r' - 32] = .{ 0x00, 0x00, 0x7C, 0x66, 0x60, 0x60, 0x60, 0x00 };
    data['s' - 32] = .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 };
    data['t' - 32] = .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x1C, 0x00 };
    data['u' - 32] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 };
    data['v' - 32] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 };
    data['w' - 32] = .{ 0x00, 0x00, 0xC6, 0xD6, 0xFE, 0xEE, 0xC6, 0x00 };
    data['x' - 32] = .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 };
    data['y' - 32] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C };
    data['z' - 32] = .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 };

    // { (123)
    data[123 - 32] = .{ 0x0E, 0x18, 0x18, 0x70, 0x18, 0x18, 0x0E, 0x00 };
    // | (124)
    data[124 - 32] = .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 };
    // } (125)
    data[125 - 32] = .{ 0x70, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x70, 0x00 };
    // ~ (126)
    data[126 - 32] = .{ 0x00, 0x00, 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00 };

    return data;
}

/// Expand the 1-bit-per-pixel `font_data` rows into the RGBA8 atlas
/// bgfx uploads. Split out of `ensureFontAtlas` so the exact bytes of
/// the built-in face can be asserted on the host with no GPU in the
/// picture — the TTF work below must not perturb a single one of them.
pub fn buildBuiltinAtlasPixels() [FONT_ATLAS_W * FONT_ATLAS_H * 4]u8 {
    var pixels: [FONT_ATLAS_W * FONT_ATLAS_H * 4]u8 = [_]u8{0} ** (FONT_ATLAS_W * FONT_ATLAS_H * 4);

    for (0..FONT_NUM_CHARS) |ch| {
        const glyph = font_data[ch];
        for (0..FONT_CHAR_H) |row| {
            const bits = glyph[row];
            for (0..FONT_CHAR_W) |col| {
                const px_x = ch * FONT_CHAR_W + col;
                const px_y = row;
                const idx = (px_y * FONT_ATLAS_W + px_x) * 4;
                const bit: u8 = @intCast((bits >> @intCast(7 - col)) & 1);
                const val: u8 = bit * 255;
                pixels[idx + 0] = val; // R
                pixels[idx + 1] = val; // G
                pixels[idx + 2] = val; // B
                pixels[idx + 3] = val; // A
            }
        }
    }

    return pixels;
}

fn ensureFontAtlas() void {
    if (font_atlas_initialized) return;

    // Build RGBA8 atlas: all chars in a single row
    var pixels = buildBuiltinAtlasPixels();

    const mem = bgfx.copy(&pixels, @intCast(pixels.len));
    font_texture = bgfx.createTexture2D(
        @intCast(FONT_ATLAS_W),
        @intCast(FONT_ATLAS_H),
        false,
        1,
        .RGBA8,
        bgfx.SamplerFlags_MinPoint | bgfx.SamplerFlags_MagPoint,
        mem,
        0,
    );

    // Only mark initialized after successful texture creation
    if (font_texture.idx != std.math.maxInt(u16)) {
        font_atlas_initialized = true;
    }
}

/// Destroy the cached font atlas texture (if any) and clear the init
/// flag. Called from `programs.shutdownPrograms` on backend
/// teardown — pre-split this was inline in `shutdownPrograms`.
pub fn destroyFontAtlas() void {
    // Teardown takes the whole bgfx context with it, so every catalog
    // atlas texture dies here whether or not the catalog unloads its
    // fonts individually. Drop the retained metrics with them, so a
    // re-init (Android surface loss) starts from an empty registry
    // rather than resolving handles onto destroyed textures.
    releaseAllCatalogFonts();
    if (font_texture.idx != std.math.maxInt(u16)) {
        bgfx.destroyTexture(font_texture);
        font_texture = .{ .idx = std.math.maxInt(u16) };
        font_atlas_initialized = false;
    }
}

fn makeTexVertex(px: f32, py: f32, u: f32, v: f32, abgr: u32) PosTexColorVertex {
    return .{
        .x = state.toNdcX(px),
        .y = state.toNdcY(py),
        .u = u,
        .v = v,
        .abgr = abgr,
    };
}

pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    ensureFontAtlas();
    if (font_texture.idx == std.math.maxInt(u16)) return;

    const zoom = state.cameraZoom();
    const scale = size / @as(f32, FONT_CHAR_H) * zoom;
    const char_w = @as(f32, FONT_CHAR_W) * scale;
    const char_h = @as(f32, FONT_CHAR_H) * scale;
    const abgr = tint.toAbgr();

    const atlas_w_f: f32 = @floatFromInt(FONT_ATLAS_W);

    var cursor_x = state.transformX(x);
    const cursor_y = state.transformY(y);

    for (text) |ch| {
        if (ch < FONT_FIRST_CHAR or ch > FONT_LAST_CHAR) {
            cursor_x += char_w;
            continue;
        }

        const glyph_idx: usize = ch - FONT_FIRST_CHAR;
        const uv0 = @as(f32, @floatFromInt(glyph_idx * FONT_CHAR_W)) / atlas_w_f;
        const uv1 = @as(f32, @floatFromInt((glyph_idx + 1) * FONT_CHAR_W)) / atlas_w_f;
        const tv0: f32 = 0.0;
        const tv1: f32 = 1.0;

        const vertices = [6]PosTexColorVertex{
            makeTexVertex(cursor_x, cursor_y, uv0, tv0, abgr),
            makeTexVertex(cursor_x + char_w, cursor_y, uv1, tv0, abgr),
            makeTexVertex(cursor_x + char_w, cursor_y + char_h, uv1, tv1, abgr),
            makeTexVertex(cursor_x, cursor_y, uv0, tv0, abgr),
            makeTexVertex(cursor_x + char_w, cursor_y + char_h, uv1, tv1, abgr),
            makeTexVertex(cursor_x, cursor_y + char_h, uv0, tv1, abgr),
        };
        programs.submitTexturedTriangles(&vertices, font_texture);

        cursor_x += char_w;
    }
}

// ── TTF/OTF font surface (labelle-gfx#258, labelle-engine#448) ─────────
//
// Everything below is the baked-font path. It sits alongside the
// built-in 8x8 face above and never disturbs it: `drawText` keeps its
// exact behaviour, and a caller with no baked font (or an invalid one)
// still gets the embedded face, byte for byte.

/// Codepoint range to bake glyphs for, half-open `[first, last)`.
pub const CodepointRange = extern struct {
    first: u32,
    last: u32,
};

/// One baked glyph. The UV rect is in *pixels* of the atlas (not
/// normalised) — the renderer divides by the atlas size once, at draw
/// time. `xoff`/`yoff` already incorporate the glyph's bearing.
pub const Glyph = extern struct {
    u0: u16,
    v0: u16,
    u1: u16,
    v1: u16,
    xoff: f32,
    yoff: f32,
    advance: f32,
};

/// Sorted (by codepoint) lookup from Unicode codepoint to dense glyph
/// index. `glyphIndexFor` binary-searches this.
pub const CodepointEntry = extern struct {
    codepoint: u32,
    glyph_index: u32,
};

/// One kern pair, in pixels at the baked size.
pub const KernPair = extern struct {
    first: u32,
    second: u32,
    advance: f32,
};

/// Bake-time parameters. The same TTF baked at a different
/// `pixel_height` / range set / atlas size is a DIFFERENT atlas, which
/// is why these ride alongside the source bytes rather than being
/// inferred from the file.
pub const FontBakeParams = struct {
    pixel_height: f32 = 16,
    ranges: []const CodepointRange = &.{.{ .first = 0x20, .last = 0x7F }},
    atlas_width: u32 = 512,
    atlas_height: u32 = 512,
};

/// CPU-decoded font atlas. All four slices are allocator-owned — the
/// caller frees them on BOTH the success and the discard path (same
/// contract as `DecodedImage.pixels`).
pub const DecodedFont = struct {
    /// 8-bit alpha coverage atlas. Length == `width * height`.
    bitmap: []u8,
    width: u32,
    height: u32,

    /// Dense per-glyph metrics, indexed by `CodepointEntry.glyph_index`.
    glyphs: []Glyph,

    /// Codepoint → glyph_index lookup, sorted by codepoint.
    codepoint_index: []const CodepointEntry,

    /// Vertical metrics in pixels at the baked size.
    ascent: f32,
    descent: f32, // negative (below the baseline)
    line_gap: f32,
    line_height: f32, // ascent - descent + line_gap

    kerning: []const KernPair,
};

/// GPU-side font atlas handle.
///
/// bgfx forces one difference from the sokol backend here: the sprite
/// program this backend already owns samples an RGBA texture and
/// multiplies by the vertex colour, so `uploadFontAtlas` expands the
/// R8 coverage bitmap into RGBA8 (white RGB, alpha = coverage) rather
/// than uploading a single-channel image and adding a second program.
/// Tinting still lands exactly right — `rgb = tint.rgb`,
/// `a = tint.a * coverage` — and the built-in 8x8 atlas has always been
/// RGBA8 for the same reason, so this stays inside the backend's own
/// conventions.
///
/// `width`/`height` live next to the handle because bgfx has no way to
/// query a texture's dimensions back, and the draw path needs them to
/// turn a glyph's pixel-space rect into UVs.
///
/// The vertical metrics ride along too: they come out of `decodeFont`
/// and the draw path needs them to place a baseline, and this struct is
/// the only thing the assembler's generated `FontBackendAdapter` keeps
/// per font (it stores the whole value opaquely in its slot table and
/// hands it straight back to `unloadFontAtlas`).
pub const FontAtlas = extern struct {
    texture: bgfx.TextureHandle,
    width: u32,
    height: u32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    line_height: f32,
};

/// Pure CPU bake — runs on the asset worker thread.
///
/// Touches NO bgfx state: bgfx's API is single-threaded (render-thread
/// only) and calling into it from the asset worker is undefined
/// behaviour, so every handle-creating call is deferred to
/// `uploadFontAtlas`. stb_truetype only writes into its own pack
/// context and the allocator-owned bitmap, which makes it safe here.
///
/// Design: `stbtt_PackBegin` + `stbtt_PackFontRange` (one call per
/// `CodepointRange`) + `stbtt_PackEnd`, rather than
/// `stbtt_BakeFontBitmap`, because the pack API:
///   1. Honors multiple non-contiguous codepoint ranges (ASCII +
///      Latin-1 supplement, say) without re-walking the font per range.
///   2. Uses skyline packing — denser than BakeFontBitmap's
///      left-to-right strip pack, which matters as soon as a project
///      bakes more than a couple of ranges into one atlas.
///   3. Supports oversampling via `stbtt_PackSetOversampling` (left at
///      1x for now; a later revision can surface it through
///      `FontBakeParams`).
///
/// All four output slices (`bitmap`, `glyphs`, `codepoint_index`,
/// `kerning`) come from `allocator`, so the caller frees them through
/// the same allocator on both the success and the discard path.
pub fn decodeFont(
    file_type: [:0]const u8,
    data: []const u8,
    params: *const FontBakeParams,
    allocator: std.mem.Allocator,
) !DecodedFont {
    // stb_truetype handles .ttf and .otf transparently — the CFF (OTF)
    // outline path has been upstream for years. We accept both and
    // never dispatch on the extension.
    _ = file_type;

    if (data.len == 0) return error.FontDecodeFailed;
    if (params.atlas_width == 0 or params.atlas_height == 0) return error.FontDecodeFailed;

    // Vertical metrics and kerning come out of `stbtt_fontinfo`, not
    // out of the packer, so initialise the font first. `font_index = 0`
    // — TTC (font collection) support is not in scope.
    var font_info: stbtt.stbtt_fontinfo = undefined;
    const offset = stbtt.stbtt_GetFontOffsetForIndex(@ptrCast(data.ptr), 0);
    if (offset < 0) return error.FontDecodeFailed;
    if (stbtt.stbtt_InitFont(&font_info, @ptrCast(data.ptr), offset) == 0) {
        return error.FontDecodeFailed;
    }

    const atlas_w: usize = params.atlas_width;
    const atlas_h: usize = params.atlas_height;
    // Guard the bitmap-size multiply against `usize` wraparound on
    // 32-bit targets (wasm32 included): a wrap would allocate an
    // undersized buffer that the C packer happily writes past.
    const bitmap_len = std.math.mul(usize, atlas_w, atlas_h) catch return error.FontAtlasTooLarge;
    const bitmap = try allocator.alloc(u8, bitmap_len);
    errdefer allocator.free(bitmap);
    @memset(bitmap, 0);

    var pack_ctx: stbtt.stbtt_pack_context = undefined;
    if (stbtt.stbtt_PackBegin(
        &pack_ctx,
        bitmap.ptr,
        @intCast(atlas_w),
        @intCast(atlas_h),
        0, // stride = 0 → tightly packed
        1, // 1px padding, so bilinear taps can't bleed between glyphs
        null,
    ) == 0) {
        return error.FontDecodeFailed;
    }
    defer stbtt.stbtt_PackEnd(&pack_ctx);

    stbtt.stbtt_PackSetOversampling(&pack_ctx, 1, 1);

    // An empty range slice means "default ASCII printable" per the
    // contract's own default.
    const effective_ranges: []const CodepointRange = if (params.ranges.len == 0)
        &[_]CodepointRange{.{ .first = 0x20, .last = 0x7F }}
    else
        params.ranges;

    // Count the glyphs across all ranges up-front so `glyphs` and
    // `codepoint_index` can be dense, single allocations. Ranges are
    // half-open [first, last).
    var total_glyphs: usize = 0;
    for (effective_ranges) |r| {
        if (r.last <= r.first) continue;
        total_glyphs += @intCast(r.last - r.first);
    }
    if (total_glyphs == 0) return error.FontDecodeFailed;

    const packed_chars = try allocator.alloc(stbtt.stbtt_packedchar, total_glyphs);
    defer allocator.free(packed_chars);

    const glyphs = try allocator.alloc(Glyph, total_glyphs);
    errdefer allocator.free(glyphs);

    const codepoint_index = try allocator.alloc(CodepointEntry, total_glyphs);
    errdefer allocator.free(codepoint_index);

    var write_idx: usize = 0;
    for (effective_ranges) |r| {
        if (r.last <= r.first) continue;
        const count: c_int = @intCast(r.last - r.first);
        const ok = stbtt.stbtt_PackFontRange(
            &pack_ctx,
            @ptrCast(data.ptr),
            0,
            params.pixel_height,
            @intCast(r.first),
            count,
            &packed_chars[write_idx],
        );
        if (ok == 0) {
            // A partial pack failure almost always means "atlas too
            // small". `bitmap`, `glyphs` and `codepoint_index` all
            // carry `errdefer allocator.free(...)` at their allocation
            // sites, so we let those fire — freeing here would be a
            // double free.
            return error.FontAtlasTooSmall;
        }
        write_idx += @intCast(count);
    }

    // Unpack `stbtt_packedchar` → our `Glyph`, building
    // `codepoint_index` in lock-step. Ranges are emitted in the order
    // the caller listed them; the index has to come out sorted by
    // codepoint for the binary search in `glyphIndexFor`, so we assume
    // caller-supplied ranges are already sorted and non-overlapping —
    // which the contract's own defaults are, and re-sorting would be
    // pure waste in the common case.
    var idx: usize = 0;
    for (effective_ranges) |r| {
        if (r.last <= r.first) continue;
        const count: u32 = r.last - r.first;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const pc = packed_chars[idx];
            glyphs[idx] = .{
                .u0 = pc.x0,
                .v0 = pc.y0,
                .u1 = pc.x1,
                .v1 = pc.y1,
                .xoff = pc.xoff,
                .yoff = pc.yoff,
                .advance = pc.xadvance,
            };
            codepoint_index[idx] = .{
                .codepoint = r.first + i,
                .glyph_index = @intCast(idx),
            };
            idx += 1;
        }
    }

    // Vertical metrics: stbtt returns them in font design units, so
    // scale them to pixels at the baked size. Note that
    // `stbtt_ScaleForPixelHeight` normalises so that
    // `ascent - descent == pixel_height` — the draw path relies on that
    // to recover the baked size from the atlas alone.
    var ascent_i: c_int = 0;
    var descent_i: c_int = 0;
    var line_gap_i: c_int = 0;
    stbtt.stbtt_GetFontVMetrics(&font_info, &ascent_i, &descent_i, &line_gap_i);
    const scale: f32 = stbtt.stbtt_ScaleForPixelHeight(&font_info, params.pixel_height);
    const ascent: f32 = @as(f32, @floatFromInt(ascent_i)) * scale;
    const descent: f32 = @as(f32, @floatFromInt(descent_i)) * scale;
    const line_gap: f32 = @as(f32, @floatFromInt(line_gap_i)) * scale;
    const line_height: f32 = ascent - descent + line_gap;

    // Kerning: pull the whole table in one pass with
    // `stbtt_GetKerningTable` — O(N + K) in the baked codepoint count N
    // and the font's stored pair count K, rather than the N² calls a
    // per-pair `stbtt_GetCodepointKernAdvance` loop would cost (~9K
    // calls for plain ASCII, quadratic beyond it).
    //
    // The table stores GLYPH INDICES, not codepoints, so we build a
    // glyph-index → codepoint map over the baked set and drop any pair
    // that references a glyph outside it.
    var kern_list = std.array_list.Aligned(KernPair, null).empty;
    errdefer kern_list.deinit(allocator);

    const pair_count_i = stbtt.stbtt_GetKerningTableLength(&font_info);
    if (pair_count_i > 0) {
        const pair_count: usize = @intCast(pair_count_i);

        const GlyphMapEntry = struct { glyph: i32, codepoint: u32 };
        const map = try allocator.alloc(GlyphMapEntry, codepoint_index.len);
        defer allocator.free(map);
        for (codepoint_index, 0..) |entry, mi| {
            const gi = stbtt.stbtt_FindGlyphIndex(&font_info, @intCast(entry.codepoint));
            map[mi] = .{ .glyph = gi, .codepoint = entry.codepoint };
        }
        std.mem.sort(GlyphMapEntry, map, {}, struct {
            fn lessThan(_: void, a: GlyphMapEntry, b: GlyphMapEntry) bool {
                return a.glyph < b.glyph;
            }
        }.lessThan);

        const lookup = struct {
            fn find(slice: []const GlyphMapEntry, glyph: i32) ?u32 {
                var lo: usize = 0;
                var hi: usize = slice.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (slice[mid].glyph < glyph) {
                        lo = mid + 1;
                    } else if (slice[mid].glyph > glyph) {
                        hi = mid;
                    } else {
                        return slice[mid].codepoint;
                    }
                }
                return null;
            }
        }.find;

        const table = try allocator.alloc(stbtt.stbtt_kerningentry, pair_count);
        defer allocator.free(table);
        const written = stbtt.stbtt_GetKerningTable(&font_info, table.ptr, @intCast(pair_count));
        const written_n: usize = if (written < 0) 0 else @intCast(written);
        for (table[0..written_n]) |entry| {
            if (entry.advance == 0) continue;
            const first_cp = lookup(map, entry.glyph1) orelse continue;
            const second_cp = lookup(map, entry.glyph2) orelse continue;
            try kern_list.append(allocator, .{
                .first = first_cp,
                .second = second_cp,
                .advance = @as(f32, @floatFromInt(entry.advance)) * scale,
            });
        }
    }
    const kerning = try kern_list.toOwnedSlice(allocator);

    return .{
        .bitmap = bitmap,
        .width = params.atlas_width,
        .height = params.atlas_height,
        .glyphs = glyphs,
        .codepoint_index = codepoint_index,
        .ascent = ascent,
        .descent = descent,
        .line_gap = line_gap,
        .line_height = line_height,
        .kerning = kerning,
    };
}

/// Expand an 8-bit coverage atlas into the RGBA8 layout the sprite
/// program samples: white RGB, alpha = coverage. Pure, so the
/// expansion can be asserted on the host without a device.
///
/// `dst.len` must be `src.len * 4`; callers size it from the same
/// dimensions.
pub fn expandCoverageToRgba(src: []const u8, dst: []u8) void {
    std.debug.assert(dst.len == src.len * 4);
    for (src, 0..) |coverage, i| {
        dst[i * 4 + 0] = 255;
        dst[i * 4 + 1] = 255;
        dst[i * 4 + 2] = 255;
        dst[i * 4 + 3] = coverage;
    }
}

/// Render-thread GPU upload. Creates the bgfx texture backing a baked
/// font. Does NOT free any slice in `decoded` — the caller owns them on
/// both the success and the discard path, same contract as
/// `uploadTexture` for `DecodedImage.pixels`.
///
/// The RGBA8 staging buffer comes from `bgfx.alloc` rather than a Zig
/// allocator: bgfx takes ownership of a `Memory` block and frees it
/// once the texture has been created, which is this backend's existing
/// convention for handing pixels to the driver (see
/// `texture.uploadTexture`, which uses the copying `bgfx.copy` because
/// it already has the bytes in the right layout — here we have to
/// build them, so we write straight into bgfx's block and skip a
/// redundant copy).
pub fn uploadFontAtlas(decoded: DecodedFont) !FontAtlas {
    const w: u16 = std.math.cast(u16, decoded.width) orelse return error.FontUploadFailed;
    const h: u16 = std.math.cast(u16, decoded.height) orelse return error.FontUploadFailed;
    if (w == 0 or h == 0) return error.FontUploadFailed;

    const expected = @as(usize, decoded.width) * @as(usize, decoded.height);
    if (decoded.bitmap.len != expected) return error.FontUploadFailed;

    const rgba_len = std.math.mul(usize, expected, 4) catch return error.FontUploadFailed;
    const rgba_len_u32 = std.math.cast(u32, rgba_len) orelse return error.FontUploadFailed;

    const mem = bgfx.alloc(rgba_len_u32);
    if (mem == null) return error.FontUploadFailed;
    expandCoverageToRgba(decoded.bitmap, mem.*.data[0..rgba_len]);

    // Bilinear (the bgfx default sampler flags) — unlike the built-in
    // 8x8 face, which forces point sampling because its glyphs are hard
    // 1-bit stencils that must not blur. A TTF bake is antialiased
    // coverage and wants the filtering.
    const handle = bgfx.createTexture2D(w, h, false, 1, .RGBA8, 0, mem, 0);
    if (handle.idx == std.math.maxInt(u16)) return error.FontUploadFailed;

    const atlas: FontAtlas = .{
        .texture = handle,
        .width = decoded.width,
        .height = decoded.height,
        .ascent = decoded.ascent,
        .descent = decoded.descent,
        .line_gap = decoded.line_gap,
        .line_height = decoded.line_height,
    };

    // Take the backend's own copy of the glyph metrics BEFORE returning:
    // the loader contract has the caller free every `DecodedFont` slice
    // the moment this function comes back, so this is the last instant
    // they are readable. Without the copy a registered handle could
    // resolve an atlas but never a face, and the draw would still fall
    // back to the built-in font (see `retainFontMetrics`).
    retainFontMetrics(atlas, decoded);
    return atlas;
}

/// Counterpart to `uploadFontAtlas`. Idempotent on an invalid handle so
/// the catalog's discard path can call it unconditionally.
///
/// Releases the retained metrics too: `uploadFontAtlas` is where the
/// backend-owned copy is acquired, so its counterpart is where it is
/// freed. Deliberately NOT `unregisterCatalogFont` — that one only
/// drops a *name* for the face (and is never called at all by a caller
/// that does not use the catalog registry, nor on the adapter's discard
/// path), whereas this is called on every atlas that ever reached the
/// GPU. The assembler calls `unregisterCatalogFont` strictly before
/// this, so no draw can resolve a handle to metrics that are about to
/// be freed.
pub fn unloadFontAtlas(atlas: FontAtlas) void {
    releaseFontMetrics(atlas);
    if (atlas.texture.idx != std.math.maxInt(u16)) {
        bgfx.destroyTexture(atlas.texture);
    }
}

// ── Catalog font registry (labelle-bgfx#85, labelle-assembler#703) ────
//
// The link that turns a declared `.font` resource into real glyphs.
//
// Two facts shape this table:
//
//   1. `registerCatalogFont(handle, atlas)` is the ONLY place the
//      backend learns the id a game will draw with — the assembler's
//      generated `FontBackendAdapter` mints it and hands it over right
//      after `uploadFontAtlas` returns. It carries the atlas, and
//      nothing else.
//   2. Laying text out needs the glyph metrics, and those are visible
//      to this backend only inside `uploadFontAtlas`, one call earlier,
//      because the caller frees them immediately afterwards.
//
// So the registry is filled in two steps against ONE table: the upload
// deposits the metric copies keyed by the bgfx texture index (unique
// among live textures, and carried inside the `FontAtlas` the adapter
// hands back), and the registration then stamps the catalog handle onto
// that same entry. `fontFaceForHandle` reads it.
//
// Bounded and allocation-free for the table itself, in the shape
// `texture.zig` already uses for its handle pool: a fixed array of
// optional slots, linear scan. Only the metric copies are allocated.

/// Live catalog fonts this backend can resolve at once. A game with
/// more than this many simultaneously loaded faces gets the built-in
/// face for the overflow — a missing improvement, never wrong glyphs.
pub const MAX_CATALOG_FONTS = 64;

/// Allocator for the retained metric copies. A `var` purely so the
/// tests can substitute a leak-checking allocator; production always
/// uses `page_allocator`, the same one `texture.zig` retains its
/// decoded pixels with.
pub var metrics_allocator: std.mem.Allocator = std.heap.page_allocator;

/// One retained face. `handle` is null between the upload and the
/// registration — and stays null forever for a caller that never
/// registers (a backend driven without the assembler's catalog), which
/// is exactly the pre-#85 behaviour.
const CatalogFontSlot = struct {
    /// Key deposited by `uploadFontAtlas`: the bgfx texture index.
    texture_idx: u16,
    /// The catalog handle, packed index-low / generation-high.
    handle: ?FontHandle,
    atlas: FontAtlas,
    /// Owned copies (`metrics_allocator`) of the decoded metrics.
    glyphs: []Glyph,
    codepoint_index: []CodepointEntry,
    kerning: []KernPair,
};

var catalog_fonts: [MAX_CATALOG_FONTS]?CatalogFontSlot =
    [_]?CatalogFontSlot{null} ** MAX_CATALOG_FONTS;

/// Copy `decoded`'s metrics into a free slot, keyed by the uploaded
/// atlas's texture index.
///
/// Silent no-op when the table is full or a copy cannot be allocated:
/// the font simply stays unresolvable and its text renders in the
/// built-in face, which is the same degradation as an unknown handle.
///
/// `pub` only so `src/font_tests.zig` can drive the registry without a
/// GPU — it touches no bgfx state. Production callers go through
/// `uploadFontAtlas`.
pub fn retainFontMetrics(atlas: FontAtlas, decoded: DecodedFont) void {
    if (atlas.texture.idx == std.math.maxInt(u16)) return;

    // A bgfx texture index is recycled after a destroy. If a previous
    // occupant of this index was never unloaded through
    // `unloadFontAtlas`, its entry would shadow the new one, so drop it.
    releaseSlotAt(findSlotByTexture(atlas.texture.idx));

    const free_idx = findFreeSlot() orelse {
        // Guarded: Zig's test runner attributes log output during a test
        // to that test and fails the step, and the full-table case is
        // deliberately exercised by `src/font_tests.zig`. Same
        // `is_test` guard the toolkit already uses for leaf diagnostics.
        if (!builtin.is_test) {
            std.log.warn("bgfx: catalog font registry full ({d}); font falls back to the built-in face", .{MAX_CATALOG_FONTS});
        }
        return;
    };

    const a = metrics_allocator;
    const glyphs = a.dupe(Glyph, decoded.glyphs) catch return;
    const index = a.dupe(CodepointEntry, decoded.codepoint_index) catch {
        a.free(glyphs);
        return;
    };
    const kerning = a.dupe(KernPair, decoded.kerning) catch {
        a.free(glyphs);
        a.free(index);
        return;
    };

    catalog_fonts[free_idx] = .{
        .texture_idx = atlas.texture.idx,
        .handle = null,
        .atlas = atlas,
        .glyphs = glyphs,
        .codepoint_index = index,
        .kerning = kerning,
    };
}

/// Free the retained metrics for `atlas`, if any, and clear its slot
/// (handle mapping included). Idempotent. `pub` for the same
/// test-without-a-GPU reason as `retainFontMetrics`; production callers
/// go through `unloadFontAtlas`.
pub fn releaseFontMetrics(atlas: FontAtlas) void {
    if (atlas.texture.idx == std.math.maxInt(u16)) return;
    releaseSlotAt(findSlotByTexture(atlas.texture.idx));
}

/// Drop every retained face. Called from `destroyFontAtlas` on backend
/// teardown (including Android surface loss), where the bgfx context —
/// and with it every atlas texture — goes away without the catalog
/// necessarily unloading each font first.
pub fn releaseAllCatalogFonts() void {
    for (0..MAX_CATALOG_FONTS) |i| releaseSlotAt(i);
}

fn releaseSlotAt(maybe_idx: ?usize) void {
    const idx = maybe_idx orelse return;
    const slot = catalog_fonts[idx] orelse return;
    metrics_allocator.free(slot.glyphs);
    metrics_allocator.free(slot.codepoint_index);
    metrics_allocator.free(slot.kerning);
    catalog_fonts[idx] = null;
}

fn findSlotByTexture(texture_idx: u16) ?usize {
    for (catalog_fonts, 0..) |maybe, i| {
        const slot = maybe orelse continue;
        if (slot.texture_idx == texture_idx) return i;
    }
    return null;
}

fn findSlotByHandle(handle: FontHandle) ?usize {
    for (catalog_fonts, 0..) |maybe, i| {
        const slot = maybe orelse continue;
        const h = slot.handle orelse continue;
        if (h == handle) return i;
    }
    return null;
}

fn findFreeSlot() ?usize {
    for (catalog_fonts, 0..) |maybe, i| {
        if (maybe == null) return i;
    }
    return null;
}

/// Bind the catalog's font id to the atlas this backend just uploaded.
///
/// `handle` is the engine's `FontId` packed INDEX-LOW / GENERATION-HIGH
/// (labelle-engine `atlas_mixin.packFontId`) — byte-identical to the
/// `u32` that later arrives at `drawTextWithFont`. The whole 32 bits are
/// the key: the low 16 alone are a slot index the catalog RECYCLES, so
/// two different faces share it across an unload/reload and differ only
/// in the generation. Keying on the truncated index would let a stale
/// draw call resolve its successor's face — silently the wrong glyphs,
/// which is the failure this registry exists to avoid. Keying on the
/// full packed value makes a stale handle simply miss and fall back.
///
/// Paired with `unregisterCatalogFont`; the assembler `@hasDecl`-gates
/// both together, so neither is useful alone.
pub fn registerCatalogFont(handle: FontHandle, atlas: FontAtlas) void {
    // Re-registering a handle that is already bound (the catalog should
    // never do it, but the seam must not corrupt the table if it does):
    // last registration wins, so drop the old binding first. The old
    // slot keeps its metrics — it is still a live atlas, owned by
    // whoever uploaded it, and `unloadFontAtlas` remains its release.
    if (findSlotByHandle(handle)) |stale| {
        if (catalog_fonts[stale]) |*slot| slot.handle = null;
    }

    const idx = findSlotByTexture(atlas.texture.idx) orelse return;
    if (catalog_fonts[idx]) |*slot| {
        slot.handle = handle;
        slot.atlas = atlas;
    }
}

/// Drop the catalog handle's binding. The assembler calls this strictly
/// BEFORE `unloadFontAtlas`, so the face stops resolving before its
/// texture is destroyed and no draw can land on a dead atlas.
///
/// Unknown handles are a no-op: the seam is called unconditionally on
/// the catalog's unload path, including for fonts this backend never
/// managed to retain. Metrics are freed by `unloadFontAtlas`, not here
/// — see its doc comment.
pub fn unregisterCatalogFont(handle: FontHandle) void {
    const idx = findSlotByHandle(handle) orelse return;
    if (catalog_fonts[idx]) |*slot| slot.handle = null;
}

// ── Baked-font drawing ────────────────────────────────────────────────
//
// The public entry point is `drawTextWithFont`, the optional
// `@hasDecl`-gated font-aware draw from labelle-core#75 — re-exported
// at the backend root, which is where `core.hasFontAwareText` probes.

/// A baked face as the draw path needs it: the GPU atlas plus the
/// metric slices from the `DecodedFont` it came from. The slices are
/// borrowed by the face, never owned by it. For a face that came out of
/// `fontFaceForHandle` they point at the catalog registry's own copies,
/// which live until `unloadFontAtlas`; a caller building a face by hand
/// keeps its own slices alive.
pub const FontFace = struct {
    atlas: FontAtlas,
    glyphs: []const Glyph,
    codepoint_index: []const CodepointEntry,
    kerning: []const KernPair = &.{},
};

/// Binary-search the sorted codepoint index. Returns null for a
/// codepoint outside the baked ranges — the caller skips it (and
/// advances by nothing), matching the built-in face's treatment of
/// out-of-range bytes as far as it can.
pub fn glyphIndexFor(index: []const CodepointEntry, codepoint: u32) ?u32 {
    var lo: usize = 0;
    var hi: usize = index.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (index[mid].codepoint < codepoint) {
            lo = mid + 1;
        } else if (index[mid].codepoint > codepoint) {
            hi = mid;
        } else {
            return index[mid].glyph_index;
        }
    }
    return null;
}

/// Kern advance between two codepoints, in baked pixels. Linear over
/// the pair list, which is empty for most fonts and short for the rest.
pub fn kernAdvance(pairs: []const KernPair, first: u32, second: u32) f32 {
    for (pairs) |p| {
        if (p.first == first and p.second == second) return p.advance;
    }
    return 0;
}

/// One positioned glyph quad, in post-transform screen pixels with UVs
/// already normalised against the atlas.
pub const GlyphQuad = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

/// Lay `text` out against `face`, calling `emit` once per visible
/// glyph. Pure: no bgfx, no allocation — which is what lets the layout
/// be asserted on the host.
///
/// `x`/`y` are the pen's start in already-transformed screen pixels and
/// `y` is the TOP of the line (the baseline sits `ascent` below it),
/// matching `drawText`, where `y` is the top of the 8x8 cell.
///
/// `size` is the requested pixel height of the line. The scale factor
/// recovers the baked size from `ascent - descent`, which
/// `stbtt_ScaleForPixelHeight` guarantees equals the `pixel_height`
/// the atlas was baked at.
pub fn layoutText(
    face: FontFace,
    text: []const u8,
    x: f32,
    y: f32,
    size: f32,
    emit: *const fn (ctx: *anyopaque, quad: GlyphQuad) void,
    ctx: *anyopaque,
) void {
    const baked_px = face.atlas.ascent - face.atlas.descent;
    if (!(baked_px > 0)) return;
    const scale = size / baked_px;

    const atlas_w: f32 = @floatFromInt(face.atlas.width);
    const atlas_h: f32 = @floatFromInt(face.atlas.height);
    if (!(atlas_w > 0) or !(atlas_h > 0)) return;

    var pen_x = x;
    const baseline = y + face.atlas.ascent * scale;
    var prev: ?u32 = null;

    for (text) |byte| {
        // ASCII-only for now: the byte IS the codepoint. Full UTF-8
        // decoding lands with the public draw decl, since that is what
        // decides whether the backend or the engine owns the decode.
        const cp: u32 = byte;

        if (prev) |p| pen_x += kernAdvance(face.kerning, p, cp) * scale;
        prev = cp;

        const gi = glyphIndexFor(face.codepoint_index, cp) orelse continue;
        if (gi >= face.glyphs.len) continue;
        const g = face.glyphs[gi];

        // A zero-area rect is a blank glyph (space); it still advances.
        if (g.u1 > g.u0 and g.v1 > g.v0) {
            const gw: f32 = @floatFromInt(g.u1 - g.u0);
            const gh: f32 = @floatFromInt(g.v1 - g.v0);
            const qx0 = pen_x + g.xoff * scale;
            const qy0 = baseline + g.yoff * scale;
            emit(ctx, .{
                .x0 = qx0,
                .y0 = qy0,
                .x1 = qx0 + gw * scale,
                .y1 = qy0 + gh * scale,
                .u0 = @as(f32, @floatFromInt(g.u0)) / atlas_w,
                .v0 = @as(f32, @floatFromInt(g.v0)) / atlas_h,
                .u1 = @as(f32, @floatFromInt(g.u1)) / atlas_w,
                .v1 = @as(f32, @floatFromInt(g.v1)) / atlas_h,
            });
        }

        pen_x += g.advance * scale;
    }
}

/// Total advance width of `text` in `face` at `size`, in pixels.
pub fn measureText(face: FontFace, text: []const u8, size: f32) f32 {
    const baked_px = face.atlas.ascent - face.atlas.descent;
    if (!(baked_px > 0)) return 0;
    const scale = size / baked_px;

    var width: f32 = 0;
    var prev: ?u32 = null;
    for (text) |byte| {
        const cp: u32 = byte;
        if (prev) |p| width += kernAdvance(face.kerning, p, cp) * scale;
        prev = cp;
        const gi = glyphIndexFor(face.codepoint_index, cp) orelse continue;
        if (gi >= face.glyphs.len) continue;
        width += face.glyphs[gi].advance * scale;
    }
    return width;
}

/// Submit `text` through the sprite pipeline using a baked face.
/// Module-internal: `gfx.zig` exports `drawTextWithFont`, not this.
pub fn drawTextFace(face: FontFace, text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    if (face.atlas.texture.idx == std.math.maxInt(u16)) return;

    const Submit = struct {
        handle: bgfx.TextureHandle,
        abgr: u32,

        fn emit(ctx: *anyopaque, q: GlyphQuad) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const vertices = [6]PosTexColorVertex{
                makeTexVertex(q.x0, q.y0, q.u0, q.v0, self.abgr),
                makeTexVertex(q.x1, q.y0, q.u1, q.v0, self.abgr),
                makeTexVertex(q.x1, q.y1, q.u1, q.v1, self.abgr),
                makeTexVertex(q.x0, q.y0, q.u0, q.v0, self.abgr),
                makeTexVertex(q.x1, q.y1, q.u1, q.v1, self.abgr),
                makeTexVertex(q.x0, q.y1, q.u0, q.v1, self.abgr),
            };
            programs.submitTexturedTriangles(&vertices, self.handle);
        }
    };

    var submit = Submit{ .handle = face.atlas.texture, .abgr = tint.toAbgr() };

    // Same camera handling as the built-in `drawText`: world → screen
    // through `state`, then the zoom folded into the glyph scale.
    layoutText(
        face,
        text,
        state.transformX(x),
        state.transformY(y),
        size * state.cameraZoom(),
        &Submit.emit,
        &submit,
    );
}

/// The opaque font handle the draw seam transports (labelle-core#75's
/// `FontHandle`). Spelled `u32` here rather than `core.FontHandle` on
/// purpose: `FontHandle` only exists in core >= the release carrying
/// core#76, and this backend still builds against older pins. The two
/// are the same type, so the decl binds either way.
pub const FontHandle = u32;

/// Resolve a `FontHandle` to the face to draw with, or null to fall
/// back to the built-in 8x8 font.
///
/// Reads the catalog registry above. A handle resolves only if the
/// assembler both registered it (`registerCatalogFont`) and has not
/// unregistered it since — so an unknown, stale, or never-registered
/// handle returns null and the draw degrades to the built-in face,
/// which is what a backend wired without the catalog seam does for
/// every handle. Never wrong glyphs; either the real face or the
/// fallback.
///
/// This backend does NOT mint or guess ids: the numbering space belongs
/// to whoever registered, exactly so the two-`u32`-spaces trap of
/// labelle-gfx#326 cannot reappear here.
pub fn fontFaceForHandle(handle: FontHandle) ?FontFace {
    const idx = findSlotByHandle(handle) orelse return null;
    const slot = catalog_fonts[idx] orelse return null;
    return .{
        .atlas = slot.atlas,
        .glyphs = slot.glyphs,
        .codepoint_index = slot.codepoint_index,
        .kerning = slot.kerning,
    };
}

/// Font-aware text draw — the optional seam from labelle-core#75.
///
/// `null` means "use the built-in font", which is what `Game.fontId`
/// returns while a lazily-declared font is still baking; the contract
/// requires that case to render exactly what `drawText` would, and it
/// does. A non-null handle this backend cannot resolve degrades the
/// same way (see `fontFaceForHandle`).
pub fn drawTextWithFont(
    text: [:0]const u8,
    x: f32,
    y: f32,
    size: f32,
    tint: Color,
    font: ?FontHandle,
) void {
    const handle = font orelse {
        drawText(text, x, y, size, tint);
        return;
    };
    drawTextMaybeFace(fontFaceForHandle(handle), text, x, y, size, tint);
}

/// Does this face resolve to the built-in 8x8 fallback?
///
/// True for a null face — which is what a null font id resolves to —
/// and for a face whose atlas texture never made it onto the GPU,
/// which is what an id pointing at a font that failed to bake or was
/// already unloaded looks like. Split out as a pure predicate so the
/// fallback decision is assertable without a device.
pub fn usesBuiltinFace(face: ?FontFace) bool {
    const f = face orelse return true;
    return f.atlas.texture.idx == std.math.maxInt(u16);
}

/// Font-aware text draw with the built-in face as the fallback. A null
/// or invalid `face` — which is what a null or stale font id resolves
/// to — takes the `drawText` path unchanged, so a game that declared
/// no font (or whose font failed to bake) renders exactly what it did
/// before this file grew a TTF path.
///
/// Module-internal: this is what `drawTextWithFont` forwards to once
/// it has resolved (or failed to resolve) its handle.
pub fn drawTextMaybeFace(face: ?FontFace, text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    if (usesBuiltinFace(face)) {
        drawText(text, x, y, size, tint);
        return;
    }
    drawTextFace(face.?, text, x, y, size, tint);
}
