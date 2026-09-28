//! WINDOWED `--screenshot` captures the Dear ImGui overlay (labelle-bgfx#68).
//!
//! #68 reported that `labelle run --screenshot` on the bgfx backend wrote the
//! scene but never the ImGui UI. The overlay is drawn by the labelle-imgui
//! bridge on its OWN bgfx view (200) that this backend never binds, and the
//! windowed capture is bgfx's async `requestScreenShot` on the backbuffer —
//! a different path from the surfaceless `captureHeadless` readback, which
//! `screenshot-probe` covers. Nothing proved that the windowed path's image
//! includes a view other than 0, so this probe drives it the way the generated
//! frame loop does and reads the file back:
//!
//!   frames 1..N-1   view 0 clears BLUE (the "scene"), nothing on view 200
//!   frame  N        view 0 clears BLUE, view 200 clears a GREEN sub-rect (the
//!                   "overlay", unbound like the bridge's), then
//!                   `window.takeScreenshot` → `window.endFrame` — the same
//!                   order the desktop template uses (gui drawn, capture queued,
//!                   swap)
//!   then            plain frames until bgfx's render thread writes the `.tga`
//!
//! The overlay is submitted ONLY on the capture frame, so a GREEN pixel inside
//! its rect proves the capture is of that frame AND includes view 200; a BLUE
//! pixel outside it proves the scene is there too (the overlay didn't just
//! cover everything). The run must also be the windowed path — a surfaceless
//! init would route `--screenshot` through `captureHeadless` instead, so the
//! probe fails rather than silently testing the other path.
//!
//! It opens an INVISIBLE GLFW window (the `--headless` fallback / windowed
//! capture path), so it needs a display server — it runs on the macOS CI job
//! (Metal), not the display-less Linux one.
//!
//! Prints `PROBE_RESULT:` and sets the exit code:
//!   0 = WINDOWED_SCREENSHOT_OVERLAY_OK
//!   2 = WINDOW_INIT_FAILED          (no window / display server)
//!   3 = NOT_WINDOWED_PATH           (init landed surfaceless)
//!   5 = SCREENSHOT_FILE_MISSING     (requestScreenShot never wrote the file)
//!   6 = SCREENSHOT_TGA_INVALID      (header wrong)
//!   7 = OVERLAY_MISSING             (the #68 bug: view 200 not in the capture)
//!   8 = SCENE_MISSING               (view 0 not in the capture)
//!
//! Run with:  zig build windowed-screenshot-probe

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const window = @import("window");

/// Logical window size. On a HiDPI display the backbuffer (and so the
/// capture) is larger; every pixel test below works in fractions of the
/// capture's own dimensions, read from its header.
const W: i32 = 128;
const H: i32 = 128;

/// The bgfx view the labelle-imgui bridge submits its overlay on
/// (`IMGUI_VIEW_ID` in that repo's `bridges/bgfx`). Hard-coded, like
/// `surfaceless_scale_probe`, so the probe stands in for the bridge without
/// depending on labelle-imgui. Nothing in this backend binds it.
const OVERLAY_VIEW: u16 = 200;

const BASE: [:0]const u8 = "windowed_screenshot_probe"; // the callback appends ".tga"
const TGA_PATH: [:0]const u8 = "windowed_screenshot_probe.tga";

/// Frames rendered before the capture frame, so the swapchain is warm.
const WARMUP_FRAMES: u32 = 4;
/// Frames pumped after the capture frame waiting for the async write. The
/// desktop template allows 8; give a CI GPU some slack.
const FLUSH_FRAMES: u32 = 32;

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn remove(path: [*:0]const u8) c_int;

/// Room for a 4x HiDPI capture of the window (512x512x4 + header).
var file_buf: [18 + 512 * 512 * 4]u8 = undefined;

/// Read the whole TGA into `file_buf`, or null if it isn't (fully) there yet.
fn readTga() ?[]const u8 {
    const file = std.c.fopen(TGA_PATH.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);
    if (fseek(file, 0, SEEK_END) != 0) return null;
    const sz = ftell(file);
    if (sz < 18) return null;
    const n: usize = @intCast(sz);
    if (n > file_buf.len) return null;
    if (fseek(file, 0, SEEK_SET) != 0) return null;
    if (std.c.fread(&file_buf, 1, n, file) != n) return null;
    return file_buf[0..n];
}

fn u16le(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

/// B,G,R of the pixel at fractional position (`fx`, `fy`) of a top-down 32 bpp
/// TGA (the layout `bgfx_callback.screenShot` writes).
fn pixelAt(tga: []const u8, w: usize, h: usize, fx: f32, fy: f32) [3]u8 {
    const x: usize = @intFromFloat(@as(f32, @floatFromInt(w)) * fx);
    const y: usize = @intFromFloat(@as(f32, @floatFromInt(h)) * fy);
    const off = 18 + (y * w + x) * 4;
    return .{ tga[off], tga[off + 1], tga[off + 2] };
}

fn isGreen(bgr: [3]u8) bool {
    return bgr[1] > 0x80 and bgr[0] < 0x40 and bgr[2] < 0x40;
}

fn isBlue(bgr: [3]u8) bool {
    return bgr[0] > 0x80 and bgr[1] < 0x40 and bgr[2] < 0x40;
}

fn finish(code: u8, result: []const u8) noreturn {
    window.closeWindow();
    _ = remove(TGA_PATH.ptr);
    std.debug.print("PROBE_RESULT: {s}\n", .{result});
    std.process.exit(code);
}

/// One frame of the "scene": view 0 cleared blue (`beginFrame` touches it).
fn sceneFrame() void {
    window.clearBackground(0, 0, 255, 255);
    window.beginFrame();
}

pub fn main() !void {
    _ = remove(TGA_PATH.ptr); // no stale file from a prior run may pass the test

    window.setConfigFlags(.{ .window_hidden = true });
    window.initWindow(W, H, "windowed_screenshot_probe");
    if (window.shouldQuit()) {
        std.debug.print("PROBE_RESULT: WINDOW_INIT_FAILED\n", .{});
        std.process.exit(2);
    }
    if (window.isSurfaceless()) finish(3, "NOT_WINDOWED_PATH");
    std.debug.print("PROBE: windowed init OK — renderer={s} backbuffer={d}x{d}\n", .{
        @tagName(bgfx.getRendererType()), window.width(), window.height(),
    });

    var i: u32 = 0;
    while (i < WARMUP_FRAMES) : (i += 1) {
        sceneFrame();
        window.endFrame();
    }

    // The capture frame: scene, then the overlay on the unbound view — the
    // top-left quarter of the backbuffer, in PHYSICAL pixels like the bridge's
    // `DisplaySize * FramebufferScale` rect — then queue the capture and swap.
    sceneFrame();
    const bw: u16 = @intCast(window.width());
    const bh: u16 = @intCast(window.height());
    bgfx.setViewRect(OVERLAY_VIEW, 0, 0, bw / 2, bh / 2, 0.0, 1.0);
    bgfx.setViewClear(OVERLAY_VIEW, bgfx.ClearFlags_Color, 0x00ff00ff, 1.0, 0);
    bgfx.touch(OVERLAY_VIEW);
    window.takeScreenshot(BASE);
    window.endFrame();

    // Later frames never touch the overlay view, so bgfx skips it: a green
    // pixel can only come from the capture frame.
    var tga: ?[]const u8 = null;
    i = 0;
    while (i < FLUSH_FRAMES) : (i += 1) {
        sceneFrame();
        window.endFrame();
        tga = readTga();
        if (tga) |t| {
            const w = u16le(t[12..14]);
            const h = u16le(t[14..16]);
            // Wait for the WHOLE file: the render thread may still be writing.
            if (t.len >= 18 + @as(usize, w) * @as(usize, h) * 4) break;
            tga = null;
        }
    }
    const t = tga orelse finish(5, "SCREENSHOT_FILE_MISSING");

    const w: usize = u16le(t[12..14]);
    const h: usize = u16le(t[14..16]);
    std.debug.print("PROBE: tga bytes={d} type={d} dims={d}x{d} bpp={d} desc=0x{x:0>2}\n", .{
        t.len, t[2], w, h, t[16], t[17],
    });
    if (t[2] != 2 or t[16] != 32 or w != bw or h != bh) finish(6, "SCREENSHOT_TGA_INVALID");

    // Sample well inside each region so edge rounding can't matter.
    const overlay = pixelAt(t, w, h, 0.25, 0.25);
    const scene = pixelAt(t, w, h, 0.75, 0.75);
    std.debug.print("PROBE: overlay bgr = {x:0>2} {x:0>2} {x:0>2}, scene bgr = {x:0>2} {x:0>2} {x:0>2}\n", .{
        overlay[0], overlay[1], overlay[2], scene[0], scene[1], scene[2],
    });
    if (!isGreen(overlay)) finish(7, "OVERLAY_MISSING");
    if (!isBlue(scene)) finish(8, "SCENE_MISSING");
    finish(0, "WINDOWED_SCREENSHOT_OVERLAY_OK");
}
