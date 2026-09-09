//! `screen_fill` backdrop coverage at a window WIDER than the design (#42).
//!
//! The report: a `screen_fill` backdrop authored for a 1024x768 design
//! covers only the left ~1024px of a 1280x720 window, leaving the right
//! ~256px uncovered. Invisible at the design size, so it only bites
//! widescreen and fullscreen.
//!
//! Reading the source did not settle it — every piece looked correct:
//! gfx calls `setApplyFit(space != .screen_fill)`, this backend exports
//! `setApplyFit`, and `toNdcX` unfitted maps design `0..design_w` onto
//! NDC `-1..+1`, which IS the full framebuffer. So this probe RENDERS the
//! reported configuration and reads the pixels back, rather than
//! reasoning about it further.
//!
//! Design 1024x768 in a 1280x720 framebuffer, which is the exact aspect
//! pair from the report (4:3 design, 16:9 surface).
//!
//! Prints `PROBE_RESULT:` and sets the exit code:
//!   0 = SCREEN_FILL_COVERS        (unfitted backdrop reaches both edges)
//!   2 = HEADLESS_INIT_FAILED
//!   3 = READBACK_NOT_READY
//!   4 = SCREEN_FILL_GAP           (#42 reproduced: an uncovered edge)
//!   5 = FITTED_CONTROL_WRONG      (the fitted case did not pillarbox —
//!                                  the probe is not measuring what it thinks)
//!
//! Run with:  zig build screen-fill-cover-probe

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx");
const window = @import("window");

/// The framebuffer: 16:9, wider than the design. Small enough for a
/// software device, same ASPECT as the reported 1280x720.
const W: u16 = 256;
const H: u16 = 144;

/// The design canvas: 4:3, the shape FP authors against.
const DESIGN_W: i32 = 192;
const DESIGN_H: i32 = 144;

var pixels: [@as(usize, W) * @as(usize, H) * 4]u8 = undefined;

fn readAll(src: bgfx.TextureHandle) bool {
    const rb = bgfx.createTexture2D(
        W,
        H,
        false,
        1,
        .RGBA8,
        bgfx.TextureFlags_BlitDst | bgfx.TextureFlags_ReadBack,
        null,
        0,
    );
    var done = false;
    defer if (done) bgfx.destroyTexture(rb);

    bgfx.blit(0, rb, 0, 0, 0, 0, src, 0, 0, 0, 0, W, H, 1);
    const ready = bgfx.readTexture(rb, &pixels, 0);
    var f = bgfx.frame(0);
    var guard: u32 = 0;
    while (f < ready and guard < 64) : (guard += 1) f = bgfx.frame(0);
    if (f < ready) return false;
    done = true;
    return true;
}

fn at(x: u16, y: u16) [4]u8 {
    const off = (@as(usize, y) * @as(usize, W) + @as(usize, x)) * 4;
    return .{ pixels[off], pixels[off + 1], pixels[off + 2], pixels[off + 3] };
}

/// The backdrop colour.
fn isBackdrop(p: [4]u8) bool {
    return p[0] > 0x80 and p[1] < 0x40 and p[2] < 0x40;
}

/// A 2x2 opaque-red texture, so the TEXTURED path can be measured too.
/// The real backdrop is a sprite, and `texture.zig` builds its vertices
/// through `makeTexVertex` while shapes go through `draw.zig`'s
/// `makeVertex` — two call sites, so proving one says nothing about the
/// other unless they are checked.
var tex_pixels = [_]u8{
    255, 0, 0, 255, 255, 0, 0, 255,
    255, 0, 0, 255, 255, 0, 0, 255,
};

fn makeBackdropTexture() !gfx.Texture {
    return gfx.uploadTexture(.{ .pixels = &tex_pixels, .width = 2, .height = 2 });
}

/// Draw the backdrop as a textured SPRITE spanning the design canvas.
fn drawBackdropTextured(tex: gfx.Texture, fit: bool) void {
    window.clearBackground(0, 0, 255, 255);
    gfx.setApplyFit(fit);
    defer gfx.setApplyFit(true);
    gfx.drawTexturePro(
        tex,
        .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(DESIGN_W),
            .height = @floatFromInt(DESIGN_H),
        },
        .{ .x = 0, .y = 0 },
        0,
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
    _ = bgfx.frame(0);
    _ = bgfx.frame(0);
}

/// Draw the backdrop exactly as a `screen_fill` layer sprite would be:
/// a quad spanning the whole DESIGN canvas, with the fit disabled.
fn drawBackdrop(fit: bool) void {
    window.clearBackground(0, 0, 255, 255); // blue = uncovered
    gfx.setApplyFit(fit);
    defer gfx.setApplyFit(true);
    gfx.drawRectangleRec(.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(DESIGN_W),
        .height = @floatFromInt(DESIGN_H),
    }, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    // Flush BEFORE the readback, exactly as the sibling probes do: the
    // draw is queued, not executed, until a frame boundary. Without this
    // the capture reads whatever the previous frame left.
    _ = bgfx.frame(0);
    _ = bgfx.frame(0);
}

pub fn main() !void {
    if (!window.initHeadless(W, H)) {
        std.debug.print("PROBE_RESULT: HEADLESS_INIT_FAILED\n", .{});
        std.process.exit(2);
    }
    std.debug.print(
        "PROBE: renderer={s}  framebuffer={d}x{d}  design={d}x{d}\n",
        .{ @tagName(bgfx.getRendererType()), W, H, DESIGN_W, DESIGN_H },
    );

    gfx.setScreenSize(W, H);
    gfx.setDesignSize(DESIGN_W, DESIGN_H);

    const mid_y: u16 = H / 2;
    const left: u16 = 1;
    const right: u16 = W - 2;

    // ── The case under test: screen_fill (fit OFF) ──────────────────────
    drawBackdrop(false);
    if (!readAll(window.headlessColorTexture())) {
        std.debug.print("PROBE_RESULT: READBACK_NOT_READY\n", .{});
        std.process.exit(3);
    }
    const fill_l = at(left, mid_y);
    const fill_r = at(right, mid_y);
    std.debug.print(
        "PROBE: screen_fill  left={x:0>2}{x:0>2}{x:0>2}  right={x:0>2}{x:0>2}{x:0>2}\n",
        .{ fill_l[0], fill_l[1], fill_l[2], fill_r[0], fill_r[1], fill_r[2] },
    );

    // ── Control: a normal fitted layer MUST pillarbox ───────────────────
    // Without this the test above could pass for the wrong reason — e.g. a
    // build where the fit never applies at all would "cover" trivially and
    // tell us nothing about `screen_fill`.
    drawBackdrop(true);
    if (!readAll(window.headlessColorTexture())) {
        std.debug.print("PROBE_RESULT: READBACK_NOT_READY\n", .{});
        std.process.exit(3);
    }
    const fit_l = at(left, mid_y);
    const fit_r = at(right, mid_y);
    std.debug.print(
        "PROBE: fitted       left={x:0>2}{x:0>2}{x:0>2}  right={x:0>2}{x:0>2}{x:0>2}\n",
        .{ fit_l[0], fit_l[1], fit_l[2], fit_r[0], fit_r[1], fit_r[2] },
    );

    if (isBackdrop(fit_l) or isBackdrop(fit_r)) {
        std.debug.print(
            "PROBE_RESULT: FITTED_CONTROL_WRONG (a fitted 4:3 design in a 16:9 " ++
                "surface must leave pillarbox bars; it did not, so this probe is " ++
                "not measuring the fit)\n",
            .{},
        );
        std.process.exit(5);
    }

    if (!isBackdrop(fill_l) or !isBackdrop(fill_r)) {
        std.debug.print(
            "PROBE_RESULT: SCREEN_FILL_GAP (#42 reproduced — an unfitted backdrop " ++
                "left an edge uncovered)\n",
            .{},
        );
        std.process.exit(4);
    }

    // ── The SPRITE path, which is what a real backdrop uses ─────────────
    const tex = makeBackdropTexture() catch {
        std.debug.print("PROBE_RESULT: READBACK_NOT_READY (texture upload failed)\n", .{});
        std.process.exit(3);
    };
    drawBackdropTextured(tex, false);
    if (!readAll(window.headlessColorTexture())) {
        std.debug.print("PROBE_RESULT: READBACK_NOT_READY\n", .{});
        std.process.exit(3);
    }
    const tex_l = at(left, mid_y);
    const tex_r = at(right, mid_y);
    std.debug.print(
        "PROBE: textured     left={x:0>2}{x:0>2}{x:0>2}  right={x:0>2}{x:0>2}{x:0>2}\n",
        .{ tex_l[0], tex_l[1], tex_l[2], tex_r[0], tex_r[1], tex_r[2] },
    );
    if (!isBackdrop(tex_l) or !isBackdrop(tex_r)) {
        std.debug.print(
            "PROBE_RESULT: SCREEN_FILL_GAP (#42 reproduced on the TEXTURED path — " ++
                "an unfitted backdrop sprite left an edge uncovered)\n",
            .{},
        );
        std.process.exit(4);
    }

    std.debug.print("PROBE_RESULT: SCREEN_FILL_COVERS\n", .{});
    bgfx.shutdown();
}
