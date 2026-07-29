//! Surfaceless SCALE + UNBOUND-VIEW probe (labelle-bgfx#61).
//!
//! Why this exists on top of the three probes that already run surfaceless:
//! `headless-probe` / `mirror-probe` / `screenshot-probe` each render a tiny
//! fixed scene through view 0 and a render target, and all three were green
//! while #61 — a real game dying two frames into gameplay under
//! `window.initHeadless` — was reproducible on demand. The two things they never
//! did are the two things that mattered:
//!
//!   1. **Scale.** A sprite-heavy frame: hundreds of quads through the same
//!      transient vertex/index buffer machinery a real world uses, so a
//!      surfaceless run is exercised at a size CI can actually regress on.
//!
//!   2. **A view this backend does NOT own.** #61's actual root cause. Every one
//!      of bgfx's 256 views defaults to the BACKBUFFER, a surfaceless run has
//!      none, and the Vulkan backend asserts
//!      (`"Rendering to backbuffer in headless mode."`) + `debugBreak()`s the
//!      process the first time such a view receives a draw. The offender was
//!      Dear ImGui's overlay: the labelle-imgui bgfx bridge submits on its own
//!      dedicated view, knows nothing about surfaceless runs, and only draws
//!      once the overlay has content — which is exactly why the crash landed
//!      mid-gameplay and why no fixed-scene probe could see it.
//!
//! Phase 2 deliberately uses the imgui bridge's REAL view id and only public
//! bgfx calls, so it stands in for any third-party view without depending on
//! labelle-imgui. Its assertion is a readback, not merely "we survived": a
//! Release build compiles bgfx's assert out, so "the process didn't die" would
//! silently stop testing anything. Checking that the unbound view's clear
//! actually landed IN the capture framebuffer holds on every optimize mode.
//!
//! Prints a `PROBE_RESULT:` line and sets the exit code:
//!   0 = SURFACELESS_SCALE_OK
//!   2 = HEADLESS_INIT_FAILED    (no Vulkan/Metal device)
//!   3 = READBACK_NOT_READY
//!   4 = SCALE_MISMATCH          (the many-sprite frame didn't land)
//!   5 = UNBOUND_VIEW_MISMATCH   (a view nothing bound missed the capture FB)
//!
//! Run with:  zig build surfaceless-scale-probe

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx");
const window = @import("window");

const W: u16 = 128;
const H: u16 = 128;

/// How many quads the scale phase submits. Chosen to be the same ORDER as the
/// ~500-entity world that exposed #61 while staying trivial for lavapipe (the
/// software Vulkan device CI runs these on) — the point is "many draw calls and
/// a lot of transient buffer traffic", not a benchmark.
const SPRITES: u32 = 512;

/// The bgfx view the labelle-imgui bridge submits its overlay on
/// (`IMGUI_VIEW_ID` in that repo's `bridges/bgfx`). Hard-coded here ON PURPOSE:
/// this probe stands in for a view owned by code OUTSIDE this backend, and
/// using the real id keeps it honest about the actual #61 crash. Nothing in
/// labelle-bgfx binds a framebuffer to it.
const UNBOUND_VIEW: u16 = 200;

/// Blit `src` into a throwaway readback texture and return the RGBA bytes at
/// (`x`, `y`), or `null` if the GPU→CPU copy never became ready. Same recipe as
/// `headless_probe` / `mirror_probe`.
fn readPixel(src: bgfx.TextureHandle, x: u16, y: u16) ?[4]u8 {
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
    while (f < ready and guard < 64) : (guard += 1) f = bgfx.frame(0);
    if (f < ready) return null; // never ready — pixels would be uninitialized
    const off = (@as(usize, y) * @as(usize, W) + @as(usize, x)) * 4;
    return .{ pixels[off], pixels[off + 1], pixels[off + 2], pixels[off + 3] };
}

fn isRedish(p: [4]u8) bool {
    return p[0] > 0x80 and p[1] < 0x40 and p[2] < 0x40;
}

fn isGreenish(p: [4]u8) bool {
    return p[1] > 0x80 and p[0] < 0x40 and p[2] < 0x40;
}

pub fn main() !void {
    if (!window.initHeadless(W, H)) {
        std.debug.print("PROBE_RESULT: HEADLESS_INIT_FAILED\n", .{});
        std.process.exit(2);
    }
    std.debug.print("PROBE: headless init OK — renderer={s}\n", .{@tagName(bgfx.getRendererType())});

    gfx.setScreenSize(W, H);
    gfx.setDesignSize(W, H);

    // ── Phase 1: scale ──────────────────────────────────────────────────
    // A blue clear with SPRITES red quads tiled over it. Each quad is its own
    // submit, so this drives the transient vertex/index buffer path hard — the
    // machinery a real sprite-heavy world uses and the fixed-scene probes never
    // touch. The whole canvas ends up red, so any single pixel proves the batch
    // landed in the capture framebuffer.
    window.clearBackground(0, 0, 255, 255);
    const cols: u32 = 32;
    const cell_w: f32 = @as(f32, @floatFromInt(W)) / @as(f32, @floatFromInt(cols));
    const cell_h: f32 = @as(f32, @floatFromInt(H)) / @as(f32, @floatFromInt(SPRITES / cols));
    var i: u32 = 0;
    while (i < SPRITES) : (i += 1) {
        const col: f32 = @floatFromInt(i % cols);
        const row: f32 = @floatFromInt(i / cols);
        gfx.drawRectangleRec(.{
            .x = col * cell_w,
            .y = row * cell_h,
            // Overlap by a hair so rounding can't leave uncovered seams the
            // sampled pixel might land in.
            .width = cell_w + 1.0,
            .height = cell_h + 1.0,
        }, gfx.red);
    }
    _ = bgfx.frame(0);
    _ = bgfx.frame(0);

    const scale_px = readPixel(window.headlessColorTexture(), W / 2, H / 2) orelse {
        std.debug.print("PROBE_RESULT: READBACK_NOT_READY (scale)\n", .{});
        window.closeWindow();
        std.process.exit(3);
    };
    std.debug.print(
        "PROBE: {d}-sprite frame center pixel = {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n",
        .{ SPRITES, scale_px[0], scale_px[1], scale_px[2], scale_px[3] },
    );
    if (!isRedish(scale_px)) {
        window.closeWindow();
        std.debug.print("PROBE_RESULT: SCALE_MISMATCH\n", .{});
        std.process.exit(4);
    }

    // ── Phase 2: a view this backend does not own (the #61 regression) ──
    // Nothing here binds a framebuffer to `UNBOUND_VIEW`, exactly like the imgui
    // bridge. Before #61 that meant "the backbuffer", which surfaceless does not
    // have: this `touch` asserted inside bgfx and `debugBreak()`d the process.
    // `initHeadless` now substitutes the capture framebuffer across the whole
    // view range, so the GREEN clear must land in the captured image — over the
    // red from phase 1, since bgfx executes views in ascending id order and
    // nothing has re-sequenced them (no render targets exist in this probe).
    bgfx.setViewRect(UNBOUND_VIEW, 0, 0, W, H);
    bgfx.setViewClear(UNBOUND_VIEW, bgfx.ClearFlags_Color | bgfx.ClearFlags_Depth, 0x00ff00ff, 1.0, 0);
    bgfx.touch(UNBOUND_VIEW);
    _ = bgfx.frame(0);
    _ = bgfx.frame(0);

    const unbound_px = readPixel(window.headlessColorTexture(), W / 2, H / 2) orelse {
        std.debug.print("PROBE_RESULT: READBACK_NOT_READY (unbound view)\n", .{});
        window.closeWindow();
        std.process.exit(3);
    };
    std.debug.print(
        "PROBE: unbound view {d} center pixel = {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n",
        .{ UNBOUND_VIEW, unbound_px[0], unbound_px[1], unbound_px[2], unbound_px[3] },
    );
    const ok = isGreenish(unbound_px);

    window.closeWindow();
    std.debug.print("PROBE_RESULT: {s}\n", .{if (ok) "SURFACELESS_SCALE_OK" else "UNBOUND_VIEW_MISMATCH"});
    std.process.exit(if (ok) 0 else 5);
}
