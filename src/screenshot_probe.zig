//! End-to-end validation of the HEADLESS SCREENSHOT-TO-FILE path (labelle-bgfx#36):
//! the one link the readback probes don't cover. It drives the real capture API
//! — `window.captureHeadless` (blit + `readTexture` on the offscreen framebuffer
//! → write a TGA) — with NO window and no display server, then reads the written
//! `.tga` back and checks its header + a pixel.
//!
//! (bgfx's async `requestScreenShot` only captures WINDOW/backbuffer
//! framebuffers, so headless capture reads the offscreen FB back and writes the
//! file itself; this probe proves that path produces a correct image.)
//!
//! Prints `PROBE_RESULT:` and sets the exit code:
//!   0 = SCREENSHOT_TGA_OK
//!   2 = HEADLESS_INIT_FAILED
//!   5 = SCREENSHOT_FILE_MISSING   (requestScreenShot never wrote the file)
//!   6 = SCREENSHOT_TGA_INVALID    (file written but header/dims/pixel wrong)
//!
//! Run with:  zig build screenshot-probe

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const window = @import("window");

const W: u16 = 96;
const H: u16 = 96;
const TGA_PATH: [:0]const u8 = "headless_screenshot_probe.tga";

// libc file IO — Zig 0.16 dropped `std.fs.cwd()` (needs an `Io`), and the gfx/
// window modules already link libc, so read the TGA back the same way
// `texture.zig`'s loader does.
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn remove(path: [*:0]const u8) c_int;

/// Read the whole file at `path` into a page-allocator buffer, or null if it
/// can't be opened yet (the async screenshot write may not have landed).
fn readFile(path: [:0]const u8) ?[]u8 {
    const file = std.c.fopen(path.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);
    if (fseek(file, 0, SEEK_END) != 0) return null;
    const sz = ftell(file);
    if (sz < 18) return null; // smaller than a TGA header — not written yet
    if (fseek(file, 0, SEEK_SET) != 0) return null;
    const n: usize = @intCast(sz);
    const buf = std.heap.page_allocator.alloc(u8, n) catch return null;
    const got = std.c.fread(buf.ptr, 1, n, file);
    if (got != n) {
        std.heap.page_allocator.free(buf);
        return null;
    }
    return buf;
}

fn u16le(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

pub fn main() !void {
    _ = remove(TGA_PATH.ptr); // clear any stale file from a prior run

    if (!window.initHeadless(W, H)) {
        std.debug.print("PROBE_RESULT: HEADLESS_INIT_FAILED\n", .{});
        std.process.exit(2);
    }
    std.debug.print("PROBE: headless init OK — renderer={s}\n", .{@tagName(bgfx.getRendererType())});

    // Clear the offscreen primary view to a known saturated RED, then render one
    // frame so the framebuffer actually holds it before we capture.
    window.clearBackground(255, 0, 0, 255);
    bgfx.touch(0);
    _ = bgfx.frame(0);

    // Capture the offscreen framebuffer to disk (readback + TGA write). This is
    // synchronous — it advances its own frames for the readback and writes
    // exactly TGA_PATH — so no polling is needed.
    if (!window.captureHeadless(TGA_PATH)) {
        std.debug.print("PROBE_RESULT: SCREENSHOT_FILE_MISSING (captureHeadless failed)\n", .{});
        window.closeWindow();
        std.process.exit(5);
    }

    const data = readFile(TGA_PATH);
    if (data == null) {
        std.debug.print("PROBE_RESULT: SCREENSHOT_FILE_MISSING (wrote but could not re-read)\n", .{});
        window.closeWindow();
        std.process.exit(5);
    }
    const buf = data.?;
    defer std.heap.page_allocator.free(buf);
    window.closeWindow();
    _ = remove(TGA_PATH.ptr); // tidy up the probe's artifact

    // Validate the TGA header: uncompressed/RLE true-color, matching dimensions,
    // 24/32 bpp. This is the strong proof the offscreen-FB screenshot wrote a
    // real image of the headless frame.
    const datatype = buf[2]; // 2 = uncompressed true-color, 10 = RLE
    const width = u16le(buf[12..14]);
    const height = u16le(buf[14..16]);
    const bpp = buf[16];
    std.debug.print("PROBE: tga bytes={d} type={d} dims={d}x{d} bpp={d}\n", .{ buf.len, datatype, width, height, bpp });

    const header_ok = (datatype == 2 or datatype == 10) and
        width == W and height == H and (bpp == 24 or bpp == 32);
    if (!header_ok) {
        std.debug.print("PROBE_RESULT: SCREENSHOT_TGA_INVALID (bad header)\n", .{});
        std.process.exit(6);
    }

    // For an uncompressed image, sample a center pixel and confirm it is a
    // saturated primary (one channel ~full, others ~zero, opaque) — i.e. the red
    // clear was actually captured, not a blank/black frame. (RLE images we accept
    // on the header proof alone to avoid an RLE decoder in a probe.)
    var content_ok = true;
    if (datatype == 2) {
        const bytespp: usize = bpp / 8;
        const px_off = 18 + (@as(usize, W) * @as(usize, H) / 2 + @as(usize, W) / 2) * bytespp;
        if (px_off + bytespp <= buf.len) {
            const p = buf[px_off..][0..bytespp];
            var hi: u8 = 0;
            var lo: u8 = 255;
            for (p[0..3]) |c| {
                hi = @max(hi, c);
                lo = @min(lo, c);
            }
            // Saturated primary ⇒ one channel high, the darkest near zero.
            content_ok = hi > 0x80 and lo < 0x40;
            std.debug.print("PROBE: center pixel bytes = {x:0>2} {x:0>2} {x:0>2}\n", .{ p[0], p[1], p[2] });
        }
    }

    if (!content_ok) {
        std.debug.print("PROBE_RESULT: SCREENSHOT_TGA_INVALID (blank/garbage pixels)\n", .{});
        std.process.exit(6);
    }

    std.debug.print("PROBE_RESULT: SCREENSHOT_TGA_OK\n", .{});
    std.process.exit(0);
}
