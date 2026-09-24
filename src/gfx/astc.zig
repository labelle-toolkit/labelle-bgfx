//! ASTC container parsing (the astcenc `.astc` file format).
//!
//! An `.astc` file is a 16-byte header followed by the raw compressed blocks:
//!   bytes 0..3   magic 0x5CA1AB13 (little-endian on disk: 13 ab a1 5c)
//!   byte  4      block dim X (e.g. 8)
//!   byte  5      block dim Y
//!   byte  6      block dim Z (1 for 2D)
//!   bytes 7..9   image X size  (24-bit little-endian)
//!   bytes 10..12 image Y size  (24-bit little-endian)
//!   bytes 13..15 image Z size  (24-bit little-endian)
//!   bytes 16..   compressed ASTC blocks (uploaded to the GPU verbatim)
//!
//! This module is pure byte-parsing — NO bgfx/GPU dependency — so the format
//! handling is host-testable. The backend maps `block_x`/`block_y` to a bgfx
//! `TextureFormat` and uploads `blocks` directly (zero CPU decode). The bgfx
//! backend ships no PNG decoder, so for a 4K atlas this is the only zero-cost
//! upload path (see labelle-gfx#269 / #341).

const std = @import("std");

/// On-disk magic, little-endian bytes.
pub const MAGIC = [4]u8{ 0x13, 0xab, 0xa1, 0x5c };

pub const Header = struct {
    block_x: u8,
    block_y: u8,
    block_z: u8,
    width: u32,
    height: u32,
    depth: u32,
    /// The compressed block payload (everything after the 16-byte header).
    blocks: []const u8,
};

/// True if `data` begins with the ASTC magic and is long enough for a header.
pub fn isAstc(data: []const u8) bool {
    return data.len >= 16 and std.mem.eql(u8, data[0..4], &MAGIC);
}

/// Parse an `.astc` blob. Returns null when the data isn't ASTC, is truncated
/// (header present but no/short block payload for the stated dimensions), or
/// has degenerate (zero) dimensions.
pub fn parse(data: []const u8) ?Header {
    if (!isAstc(data)) return null;
    const bx = data[4];
    const by = data[5];
    const bz = data[6];
    if (bx == 0 or by == 0 or bz == 0) return null;

    const w: u32 = std.mem.readInt(u24, data[7..10], .little);
    const h: u32 = std.mem.readInt(u24, data[10..13], .little);
    const d: u32 = std.mem.readInt(u24, data[13..16], .little);
    if (w == 0 or h == 0 or d == 0) return null;

    // Expected block payload = ceil(w/bx) * ceil(h/by) * ceil(d/bz) * 16 bytes.
    const blocks_x = (w + bx - 1) / bx;
    const blocks_y = (h + by - 1) / by;
    const blocks_z = (d + bz - 1) / bz;
    const expected = std.math.mul(usize, std.math.mul(usize, std.math.mul(usize, blocks_x, blocks_y) catch return null, blocks_z) catch return null, 16) catch return null;
    if (data.len - 16 < expected) return null; // truncated

    return .{
        .block_x = bx,
        .block_y = by,
        .block_z = bz,
        .width = w,
        .height = h,
        .depth = d,
        .blocks = data[16 .. 16 + expected],
    };
}

// ── Runtime support (labelle-bgfx#76) ─────────────────────────────────────
// Parsing says what a blob IS; this says whether the running GPU can SAMPLE
// it. The flags are bgfx's `caps.formats[fmt]` bits, passed in so the
// decision stays host-testable (texture.zig asserts they match bgfx's).

/// `BGFX_CAPS_FORMAT_TEXTURE_2D`: the GPU samples the format natively.
pub const caps_texture_2d: u32 = 0x1;
/// `BGFX_CAPS_FORMAT_TEXTURE_2D_EMULATED`: bgfx would convert it to RGBA8 on
/// the CPU at upload.
pub const caps_texture_2d_emulated: u32 = 0x4;

pub const Support = enum {
    /// Upload the blocks as-is.
    native,
    /// Only bgfx's CPU conversion could take it. That path is broken in our
    /// builds: bimg's astcenc fails to initialise, so it draws a checkerboard
    /// on native GPUs and writes out of bounds on wasm. Treat as unsupported.
    emulated_only,
    none,
};

pub fn support(format_caps: u32) Support {
    if (format_caps & caps_texture_2d != 0) return .native;
    if (format_caps & caps_texture_2d_emulated != 0) return .emulated_only;
    return .none;
}

// ── Tests (pure; no bgfx) ───────────────────────────────────────────────────

fn makeHeader(buf: *[16]u8, bx: u8, by: u8, w: u24, h: u24) void {
    @memcpy(buf[0..4], &MAGIC);
    buf[4] = bx;
    buf[5] = by;
    buf[6] = 1;
    std.mem.writeInt(u24, buf[7..10], w, .little);
    std.mem.writeInt(u24, buf[10..13], h, .little);
    std.mem.writeInt(u24, buf[13..16], 1, .little);
}

test "isAstc detects the magic" {
    var h: [16]u8 = undefined;
    makeHeader(&h, 8, 8, 64, 64);
    try std.testing.expect(isAstc(&h));
    try std.testing.expect(!isAstc("not an astc file at all"));
    try std.testing.expect(!isAstc(&[_]u8{ 0x13, 0xab })); // too short
}

test "parse reads block + image dims for 8x8" {
    // 64x64 @ 8x8 = 8*8 blocks * 16 bytes = 1024 block bytes.
    var buf = [_]u8{0} ** (16 + 1024);
    makeHeader(buf[0..16], 8, 8, 64, 64);
    const hdr = parse(&buf) orelse return error.TestUnexpected;
    try std.testing.expectEqual(@as(u8, 8), hdr.block_x);
    try std.testing.expectEqual(@as(u8, 8), hdr.block_y);
    try std.testing.expectEqual(@as(u32, 64), hdr.width);
    try std.testing.expectEqual(@as(u32, 64), hdr.height);
    try std.testing.expectEqual(@as(usize, 1024), hdr.blocks.len);
}

test "parse honors non-multiple dims (ceil to block grid)" {
    // 100x100 @ 8x8 => ceil(100/8)=13 blocks each way => 13*13*16 = 2704.
    var buf = [_]u8{0} ** (16 + 2704);
    makeHeader(buf[0..16], 8, 8, 100, 100);
    const hdr = parse(&buf) orelse return error.TestUnexpected;
    try std.testing.expectEqual(@as(usize, 2704), hdr.blocks.len);
}

test "parse rejects truncated block payload" {
    // Header says 64x64 @ 8x8 (needs 1024 block bytes) but only 500 provided.
    var buf = [_]u8{0} ** (16 + 500);
    makeHeader(buf[0..16], 8, 8, 64, 64);
    try std.testing.expect(parse(&buf) == null);
}

test "parse rejects non-astc / degenerate dims" {
    try std.testing.expect(parse("totally not astc, no magic here!!") == null);
    var buf = [_]u8{0} ** 64;
    makeHeader(buf[0..16], 8, 8, 0, 64); // zero width
    try std.testing.expect(parse(&buf) == null);
    makeHeader(buf[0..16], 0, 8, 64, 64); // zero block dim
    try std.testing.expect(parse(&buf) == null);
}

test "support: only a natively sampled format uploads" {
    try std.testing.expectEqual(Support.native, support(caps_texture_2d));
    // Native wins even when bgfx also reports the emulated bit.
    try std.testing.expectEqual(Support.native, support(caps_texture_2d | caps_texture_2d_emulated));
    // The #76 case: bgfx would only convert on the CPU, which draws garbage.
    try std.testing.expectEqual(Support.emulated_only, support(caps_texture_2d_emulated));
    try std.testing.expectEqual(Support.none, support(0));
    // Other bits (sRGB, 3D, cube...) don't make a 2D texture sampleable.
    try std.testing.expectEqual(Support.none, support(0x2 | 0x8 | 0x40));
}
