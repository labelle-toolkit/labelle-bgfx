//! Feasibility probe for labelle-bgfx#36 (option B): can bgfx init **headless**
//! — `nwh = null`, forced Vulkan — render into an **offscreen framebuffer**, and
//! read a pixel back, with NO window and no display server?
//!
//! Prints a clear `PROBE_RESULT:` line and sets the exit code:
//!   0 = HEADLESS_OFFSCREEN_READBACK_OK (init + offscreen render + readback work)
//!   2 = HEADLESS_INIT_FAILED (bgfx.init returned false with nwh=null)
//!   3 = READBACK_ALL_ZERO (init/render ran but readback produced no pixels)
//!
//! Run with:  zig build headless-probe
const std = @import("std");
const bgfx = @import("zbgfx").bgfx;

pub fn main() !void {
    const W: u16 = 64;
    const H: u16 = 64;

    var init: bgfx.Init = undefined;
    bgfx.initCtor(&init);
    init.type = .Vulkan; // Vulkan/Metal support headless; OpenGL (Windows fallback) does not
    // Headless has NO backbuffer/swapchain — bgfx REQUIRES resolution 0x0 here
    // (bgfx.cpp: "resolution of non-existing backbuffer can't be larger than
    // 0x0!"). The render size lives on the offscreen framebuffer below, not here.
    init.resolution.width = 0;
    init.resolution.height = 0;
    init.resolution.reset = bgfx.ResetFlags_None;
    // Headless: NO native window handle / display.
    init.platformData.ndt = null;
    init.platformData.nwh = null;
    init.platformData.context = null;
    init.platformData.backBuffer = null;
    init.platformData.backBufferDS = null;

    if (!bgfx.init(&init)) {
        std.debug.print("PROBE_RESULT: HEADLESS_INIT_FAILED (bgfx.init returned false with nwh=null, Vulkan)\n", .{});
        std.process.exit(2);
    }
    std.debug.print("PROBE: headless init OK — renderer={s}\n", .{@tagName(bgfx.getRendererType())});

    // Offscreen render target texture + framebuffer wrapping it.
    const rt = bgfx.createTexture2D(W, H, false, 1, .RGBA8, bgfx.TextureFlags_Rt, null, 0);
    var handles = [_]bgfx.TextureHandle{rt};
    const fb = bgfx.createFrameBufferFromHandles(1, &handles, false);

    bgfx.setViewFrameBuffer(0, fb);
    bgfx.setViewRect(0, 0, 0, W, H);
    // Clear to opaque red (0xRRGGBBAA) — a known, non-zero color.
    bgfx.setViewClear(0, bgfx.ClearFlags_Color | bgfx.ClearFlags_Depth, 0xff0000ff, 1.0, 0);
    bgfx.touch(0);
    _ = bgfx.frame(0); // render the clear into the RT

    // Readback recipe (bgfx#1285): a BLIT_DST|READ_BACK texture, blit the RT
    // into it, then readTexture — which returns the frame number when the CPU
    // copy is ready. Advance frames until then.
    const readback = bgfx.createTexture2D(
        W,
        H,
        false,
        1,
        .RGBA8,
        bgfx.TextureFlags_BlitDst | bgfx.TextureFlags_ReadBack,
        null,
        0,
    );
    bgfx.blit(0, readback, 0, 0, 0, 0, rt, 0, 0, 0, 0, W, H, 1);

    var pixels: [@as(usize, W) * @as(usize, H) * 4]u8 = undefined;
    const ready_frame = bgfx.readTexture(readback, &pixels, 0);
    var f = bgfx.frame(0);
    var guard: u32 = 0;
    while (f < ready_frame and guard < 64) : (guard += 1) f = bgfx.frame(0);

    // Free the offscreen handles BEFORE shutdown so bgfx doesn't report them as
    // leaks (#384). `std.process.exit` below skips `defer`, so destroy here. The
    // framebuffer was created with destroy_texture=false, so `rt` is freed too.
    bgfx.destroyTexture(readback);
    bgfx.destroyFrameBuffer(fb);
    bgfx.destroyTexture(rt);

    if (f < ready_frame) {
        // The GPU→CPU copy never landed within the guard — `pixels` is unready,
        // so reading it would be racy. Fail hard rather than report noise.
        std.debug.print("PROBE_RESULT: READBACK_NOT_READY (waited {d} frames)\n", .{guard});
        bgfx.shutdown();
        std.process.exit(4);
    }

    const p = pixels[0..4];
    std.debug.print("PROBE: first pixel bytes = {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n", .{ p[0], p[1], p[2], p[3] });

    // Any non-zero channel ⇒ the offscreen render + GPU→CPU readback produced
    // real data with no window. (Exact byte order is backend-dependent; the
    // proof is "not all zero", i.e. the clear actually landed and read back.)
    const ok = (@as(u32, p[0]) | p[1] | p[2] | p[3]) != 0;
    std.debug.print("PROBE_RESULT: {s}\n", .{if (ok) "HEADLESS_OFFSCREEN_READBACK_OK" else "READBACK_ALL_ZERO"});

    bgfx.shutdown();
    std.process.exit(if (ok) 0 else 3);
}
