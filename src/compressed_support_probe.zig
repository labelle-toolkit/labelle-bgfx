//! `compressedSupported` agrees with `uploadCompressed` (labelle-bgfx#134).
//!
//! Generated web code picks an atlas's `.astc` when `compressedSupported`
//! says yes and its `.png` otherwise. If the two ever disagreed, the pick
//! would choose an ASTC blob the upload then refuses, and the atlas would be
//! missing (the #76 guard), or it would ship the PNG to a GPU that could
//! have taken the ASTC. So on whatever renderer runs this, for each blob:
//! `compressedSupported(b)` must equal "`uploadCompressed(b)` succeeded".
//! Which blocks are supported depends on the GPU (Apple/Metal: all ASTC;
//! lavapipe: likely none), so only agreement is asserted, plus: non-ASTC
//! bytes are never supported.
//!
//! Prints `PROBE_RESULT:` and sets the exit code:
//!   0 = COMPRESSED_SUPPORT_AGREES
//!   2 = HEADLESS_INIT_FAILED
//!   4 = DISAGREES
//!   5 = NON_ASTC_SUPPORTED
//!
//! Run with:  zig build compressed-support-probe

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx");
const window = @import("window");

fn blobLen(comptime block: u8) usize {
    const per_side: usize = 16 / @as(usize, block);
    return 16 + per_side * per_side * 16;
}

/// A 16x16 ASTC blob of all-zero blocks. Zero blocks decode to the error
/// colour, which is fine: this probe checks acceptance, not pixels.
fn blob(comptime block: u8) [blobLen(block)]u8 {
    var b = [_]u8{0} ** blobLen(block);
    b[0..4].* = .{ 0x13, 0xab, 0xa1, 0x5c };
    b[4] = block;
    b[5] = block;
    b[6] = 1;
    std.mem.writeInt(u24, b[7..10], 16, .little);
    std.mem.writeInt(u24, b[10..13], 16, .little);
    std.mem.writeInt(u24, b[13..16], 1, .little);
    return b;
}

fn fail(code: u8, result: []const u8) noreturn {
    std.debug.print("PROBE_RESULT: {s}\n", .{result});
    window.closeWindow();
    std.process.exit(code);
}

fn check(name: []const u8, data: []const u8) void {
    const supported = gfx.compressedSupported(data);
    const uploaded = if (gfx.uploadCompressed(data)) |tex| blk: {
        gfx.unloadTexture(tex);
        break :blk true;
    } else |_| false;
    std.debug.print("PROBE: {s}: compressedSupported={} upload={}\n", .{ name, supported, uploaded });
    if (supported != uploaded) fail(4, "DISAGREES");
}

pub fn main() !void {
    if (!window.initHeadless(64, 64)) {
        std.debug.print("PROBE_RESULT: HEADLESS_INIT_FAILED\n", .{});
        std.process.exit(2);
    }
    defer window.closeWindow();
    std.debug.print("PROBE: renderer={s}\n", .{@tagName(bgfx.getRendererType())});

    const b4 = blob(4);
    const b8 = blob(8);
    check("ASTC 4x4", &b4);
    check("ASTC 8x8", &b8);

    const png_magic = "\x89PNG\r\n\x1a\n" ++ [_]u8{0} ** 24;
    if (gfx.compressedSupported(png_magic)) fail(5, "NON_ASTC_SUPPORTED");
    std.debug.print("PROBE: non-ASTC bytes: compressedSupported=false\n", .{});

    std.debug.print("PROBE_RESULT: COMPRESSED_SUPPORT_AGREES\n", .{});
}
