//! On-device validation for labelle-bgfx#36 (headless offscreen capture) + the
//! transport mirror. Runs FULLY headless — no window, no display server — so it
//! works in CI on any Vulkan/Metal box:
//!
//!   1. `window.initHeadless` — surfaceless bgfx, primary view → offscreen FB.
//!   2. Render a known RED rect into a `RenderTarget` (render-to-texture), read
//!      it back, assert it landed → proves offscreen rendering (#36 core + the
//!      mirror's source pass).
//!   3. Composite that target onto the primary via `drawRenderTarget` (the
//!      mirror) over a BLUE clear, read the PRIMARY framebuffer back, assert the
//!      pixel is red not blue → proves the mirror + the headless capture surface.
//!
//! Prints a `PROBE_RESULT:` line and sets the exit code:
//!   0 = HEADLESS_MIRROR_OK
//!   2 = HEADLESS_INIT_FAILED   (no Vulkan/Metal device)
//!   3 = RT_CREATE_FAILED
//!   4 = MIRROR_MISMATCH        (readback didn't match the drawn colors)
//!
//! Run with:  zig build mirror-probe

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx");
const window = @import("window");

const W: u16 = 128;
const H: u16 = 128;

/// Blit `src` into a throwaway readback texture and return its top-left RGBA
/// bytes. Same recipe as `headless_probe` (bgfx#1285): a BLIT_DST|READ_BACK
/// texture, `blit`, `readTexture` (returns the frame the CPU copy is ready), then
/// advance frames until then. Readback byte order is RGBA on the tested backends.
fn readPixel(src: bgfx.TextureHandle) [4]u8 {
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
    defer bgfx.destroyTexture(rb);

    bgfx.blit(0, rb, 0, 0, 0, 0, src, 0, 0, 0, 0, W, H, 1);
    var pixels: [@as(usize, W) * @as(usize, H) * 4]u8 = undefined;
    const ready = bgfx.readTexture(rb, &pixels, 0);
    var f = bgfx.frame(0);
    var guard: u32 = 0;
    while (f < ready and guard < 16) : (guard += 1) f = bgfx.frame(0);
    return .{ pixels[0], pixels[1], pixels[2], pixels[3] };
}

/// Red-dominant: strong red channel, weak blue. Order-tolerant "the red landed".
fn isRedish(p: [4]u8) bool {
    return p[0] > 0x80 and p[2] < 0x40;
}

pub fn main() !void {
    if (!window.initHeadless(W, H)) {
        std.debug.print("PROBE_RESULT: HEADLESS_INIT_FAILED\n", .{});
        std.process.exit(2);
    }
    std.debug.print("PROBE: headless init OK — renderer={s}\n", .{@tagName(bgfx.getRendererType())});

    // Map design space to the framebuffer so a (0,0,W,H) rect covers the view.
    gfx.setScreenSize(W, H);
    gfx.setDesignSize(W, H);

    // 1) Render a RED rect into an offscreen render target.
    var rt = gfx.createRenderTarget(W, H);
    if (!rt.isValid()) {
        std.debug.print("PROBE_RESULT: RT_CREATE_FAILED\n", .{});
        std.process.exit(3);
    }
    gfx.beginRenderTarget(rt);
    gfx.drawRectangleRec(.{ .x = 0, .y = 0, .width = @floatFromInt(W), .height = @floatFromInt(H) }, gfx.red);
    gfx.endRenderTarget();

    // 2) Composite the target onto the primary (the mirror), over a BLUE clear.
    window.clearBackground(0, 0, 255, 255);
    gfx.drawRenderTarget(rt, .{ .x = 0, .y = 0, .width = @floatFromInt(W), .height = @floatFromInt(H) }, gfx.white);

    // Flush. `sequenceViews` orders the RT view before the primary, so a single
    // frame resolves the RT then composites it; a second frame is belt-and-braces.
    _ = bgfx.frame(0);
    _ = bgfx.frame(0);

    // 3a) Read the render target back — proves render-to-texture (#36 core).
    const rt_px = readPixel(rt.color);
    std.debug.print("PROBE: render-target pixel = {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n", .{ rt_px[0], rt_px[1], rt_px[2], rt_px[3] });
    const rt_ok = isRedish(rt_px);

    // 3b) Read the primary headless framebuffer back — proves the mirror
    // composite (red RT drawn over the blue clear ⇒ the pixel is red) AND the
    // headless capture surface itself.
    const prim_px = readPixel(window.headlessColorTexture());
    std.debug.print("PROBE: primary(mirror) pixel = {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n", .{ prim_px[0], prim_px[1], prim_px[2], prim_px[3] });
    const mirror_ok = isRedish(prim_px);

    gfx.destroyRenderTarget(&rt);
    window.closeWindow();

    const ok = rt_ok and mirror_ok;
    std.debug.print("PROBE_RESULT: {s}\n", .{if (ok) "HEADLESS_MIRROR_OK" else "MIRROR_MISMATCH"});
    std.process.exit(if (ok) 0 else 4);
}
