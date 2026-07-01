/// bgfx window backend — windowing lifecycle via GLFW + bgfx frame management.
const std = @import("std");
const builtin = @import("builtin");
const zbgfx = @import("zbgfx");
const bgfx = zbgfx.bgfx;
const gfx = @import("gfx");
const platform = @import("platform.zig");
/// labelle-core, for the comptime window-contract conformance gate below.
const core = @import("labelle-core");

/// Android has no GLFW (zglfw is desktop-only). The Android windowing
/// path is fed an `ANativeWindow*` by the NativeActivity glue at runtime
/// (phase 3, #302) via `setAndroidNativeWindow`; on desktop we keep the
/// full GLFW lifecycle below. Every zglfw reference is comptime-gated on
/// this flag so the module compiles for `aarch64-linux-android` with no
/// zglfw import in the graph.
const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

/// wasm/WebGL (emscripten) target (bgfx-wasm epic #8). Like Android, there is no
/// GLFW: the browser owns the canvas + event loop. bgfx creates a WebGL2 context
/// against an emscripten canvas selector (`#canvas`), fed through
/// `PlatformData.nwh` at init, and the frame is driven per-`emscripten_set_main_loop`
/// callback (see templates/wasm.txt). Every zglfw reference below is comptime-gated
/// on `no_glfw` so the module compiles for wasm32-emscripten with no zglfw import.
const is_wasm = builtin.target.cpu.arch.isWasm();

/// True on the two GLFW-less targets (Android + wasm). Used to gate the zglfw
/// import + every desktop-only GLFW reference so those code paths are
/// comptime-eliminated on the surface-handed-over platforms.
const no_glfw = is_android or is_wasm;

/// zglfw is only imported on desktop targets. On Android/wasm `glfw` resolves
/// to an empty namespace so any accidental desktop-only reference fails
/// at compile time rather than dragging in the zglfw module.
const glfw = if (no_glfw) struct {} else @import("zglfw");

/// bgfx's HTML5 (emscripten) backend takes `PlatformData.nwh` as a
/// `const char*` CSS selector naming the target `<canvas>` element. The default
/// emcc HTML shell ships a `<canvas id="canvas">`, so `#canvas` is the selector
/// bgfx's own entry examples use.
const wasm_canvas_selector: [:0]const u8 = "#canvas";

// Prove this module satisfies labelle-core's canonical window contract (#386
// Phase 3): `width`/`height`/`frameDuration`/`requestQuit` (required) plus the
// loop-model `shouldQuit` and optional display/screenshot toggles. Fails the
// build with a named-decl list if any required method is missing or misnamed —
// the formal replacement for the prior raylib-dialect names. bgfx IS a loop
// backend: it declares `shouldQuit`, so `core.Window(@This()).ownsLoop()` is
// true and the shared run-loop templates gate on it.
comptime {
    core.assertWindow(@This());
}

// Contract-version tag (labelle-assembler#453 item 1). The assembler emits a
// directional `@compileError` version assert in the generated game's main.zig
// comparing this against labelle-core's `WINDOW_CONTRACT_VERSION`. v1 is the
// initial revision of the window contract.
/// Window contract (lifecycle: width/height/frameDuration/shouldQuit) revision this backend targets.
pub const targets_window_contract: u32 = 1;

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

var glfw_window: if (no_glfw) ?*anyopaque else ?*glfw.Window = null;
var target_fps_val: i32 = 60;
var screen_w: i32 = 800;
var screen_h: i32 = 600;
/// Windowed-mode geometry, captured the moment we go fullscreen so
/// `setFullscreen(false)` restores the window to the same place + size
/// (GLFW's `setMonitor` needs explicit windowed coords on the way back).
var windowed_x: i32 = 0;
var windowed_y: i32 = 0;
var windowed_w: i32 = 800;
var windowed_h: i32 = 600;
/// VSYNC reset flag (`BGFX_RESET_VSYNC`) — OR'd into the reset flags when
/// vsync is enabled. `setVsync` toggles it in/out of `current_reset`.
const RESET_VSYNC: u32 = 0x00000080;
/// The reset flags currently in effect, reused by `ensureSurface` and
/// seeded into `init.resolution.reset` at window creation. Starts with
/// vsync ON to match every backend's prior hardcoded behaviour; flipped
/// live by `setVsync`. (Toggling vsync is just adding/removing
/// `RESET_VSYNC` and re-issuing `bgfx.reset` — the standard bgfx
/// mechanism, works on every bgfx platform.)
var current_reset: u32 = RESET_VSYNC;
var window_hidden: bool = false;
var clear_color: u32 = 0x1e1e2eff; // dark background RGBA

/// The current surface dimensions, in PHYSICAL framebuffer pixels.
///
/// On desktop (GLFW) `screen_w/h` are seeded from `getFramebufferSize()` at
/// window creation and reconciled every frame by `ensureSurface()`, so on a
/// HiDPI/Retina display they hold the physical drawable size (e.g. 1600x1200
/// for a logical 800x600 window at 2x) — NOT the logical window size. That is
/// exactly what the engine's `setScreenSize` needs: the gfx renderer maps the
/// design resolution onto the physical framebuffer, so the GPU renders at full
/// Retina sharpness and screen-space NDC stays correct.
///
/// On Android `screen_w/h` are the `ANativeWindow` surface size handed over at
/// `INIT_WINDOW` — already physical — which can differ from the project's
/// configured default (e.g. a 2000x1200 tablet surface vs. an 800x600 config).
/// The generated Android entry reads `height()` post-init so the
/// engine's coordinate mapping matches the actual surface rather than the
/// config.
// Return the LIVE framebuffer size, not the cached `screen_w/h`. The
// generated frame loop calls `setScreenSize(width(), ...)` at the
// top of the frame, before `beginFrame`'s `ensureSurface()` reconciles
// the cache — so reading the cache here would feed gfx the *previous*
// physical size on the frame a resize/DPI/fullscreen change lands, while
// the bgfx viewport already matched the new framebuffer (one-frame
// aspect-fit mismatch). Querying live keeps gfx and the surface in step.
// On Android `framebufferSize()` returns the cached native-surface dims.
pub fn width() i32 {
    return framebufferSize()[0];
}
pub fn height() i32 {
    return framebufferSize()[1];
}

/// The physical framebuffer size of the render surface.
///
/// On Android there's no GLFW; `screen_w/h` already hold the native
/// `ANativeWindow` surface dims (physical), so return those. On desktop query
/// GLFW's framebuffer size — on a Retina/HiDPI display this is larger than the
/// logical window size (e.g. 2x), and it's the size the GPU swapchain must
/// match for crisp rendering.
fn framebufferSize() [2]i32 {
    if (is_wasm) {
        // Query the live drawing-buffer size of the emscripten canvas so a CSS
        // resize (or a canvas sized by the shell) is reflected in the bgfx
        // swapchain via `ensureSurface`. On any failure fall back to the cached
        // dims (seeded from the config at init).
        var w: c_int = screen_w;
        var h: c_int = screen_h;
        if (em.emscripten_get_canvas_element_size(wasm_canvas_selector.ptr, &w, &h) == 0 and w > 0 and h > 0) {
            return .{ @intCast(w), @intCast(h) };
        }
        return .{ screen_w, screen_h };
    }
    if (is_android) return .{ screen_w, screen_h };
    if (glfw_window) |win| {
        const fb = win.getFramebufferSize();
        return .{ @intCast(fb[0]), @intCast(fb[1]) };
    }
    return .{ screen_w, screen_h };
}

/// Hand-rolled emscripten HTML5 externs (bgfx-wasm #8). We avoid
/// `@cImport(<emscripten.h>)` because Zig 0.16's translate-c rejects recent emsdk
/// headers (multi-arg `__attribute__((deprecated))`, translate-c issue #306);
/// emcc resolves these symbols at link time. Only referenced on wasm.
const em = struct {
    extern "c" fn emscripten_get_canvas_element_size(target: [*:0]const u8, width: *c_int, height: *c_int) c_int;
};

/// Reconcile the bgfx backbuffer with the current physical framebuffer size.
///
/// Called once per frame from `beginFrame`. If the framebuffer changed since
/// the last reconcile (a DPI move between monitors, a resize, or a
/// fullscreen/windowed switch) and is non-zero, update the cached `screen_w/h`
/// and `bgfx.reset` the swapchain to the new physical size. The `> 0` guard
/// skips minimized windows (a 0-size reset is invalid). The viewport rect is
/// set by `beginFrame` right after this, so we don't touch `setViewRect` here.
fn ensureSurface() void {
    const fb = framebufferSize();
    if (fb[0] > 0 and fb[1] > 0 and (fb[0] != screen_w or fb[1] != screen_h)) {
        screen_w = fb[0];
        screen_h = fb[1];
        // `.Count` = keep the current backbuffer format (no change).
        bgfx.reset(@intCast(screen_w), @intCast(screen_h), current_reset, .Count);
    }
}

/// The native `ANativeWindow*` surface handed over by the NativeActivity
/// glue. bgfx's `PlatformData.nwh` is a `void*`, so we hold it as an
/// opaque pointer here and pass it straight through at init time. Set by
/// `setAndroidNativeWindow` before `initWindow` runs (phase 3 wires the
/// actual surfaceCreated/surfaceDestroyed lifecycle).
var android_native_window: ?*anyopaque = null;

/// Hand the bgfx backend the native `ANativeWindow*` for the current
/// surface. Called from the NativeActivity glue (phase 3, #302). No-op
/// builds that never call this leave `nwh` null, matching desktop's
/// pre-window-creation state.
pub fn setAndroidNativeWindow(handle: ?*anyopaque) void {
    android_native_window = handle;
}

pub fn setConfigFlags(flags: ConfigFlags) void {
    window_hidden = flags.window_hidden;
}

pub fn initWindow(w: i32, h: i32, title: [:0]const u8) void {
    screen_w = w;
    screen_h = h;

    if (is_wasm) {
        initWindowWasm(w, h);
    } else if (is_android) {
        initWindowAndroid(w, h);
    } else {
        initWindowDesktop(w, h, title);
    }
}

/// wasm/WebGL init path (bgfx-wasm #8): no GLFW. bgfx creates its own WebGL2
/// context against the emscripten canvas named by `wasm_canvas_selector`
/// (`#canvas`), handed over as the `const char*` selector in `PlatformData.nwh`
/// per bgfx's HTML5 backend. The zbgfx wasm build forces BGFX_CONFIG_MULTITHREADED
/// off, so `bgfx.init` + `bgfx.frame` run in-thread and the render frame is driven
/// synchronously from the `emscripten_set_main_loop` callback — no `renderFrame`
/// pump is needed. `RendererType.Count` auto-selects OpenGLES (WebGL) on
/// emscripten.
fn initWindowWasm(w: i32, h: i32) void {
    var init: bgfx.Init = undefined;
    bgfx.initCtor(&init);

    init.type = .Count; // auto-select renderer (OpenGLES/WebGL on emscripten)
    init.resolution.width = @intCast(w);
    init.resolution.height = @intCast(h);
    init.resolution.reset = current_reset;

    // On emscripten `nwh` is a CSS selector C-string for the target canvas; bgfx
    // creates the WebGL context against it. `ndt`/`context`/`queue` are unused.
    init.platformData.ndt = null;
    init.platformData.nwh = @constCast(@ptrCast(wasm_canvas_selector.ptr));
    init.platformData.context = null;
    init.platformData.queue = null;
    init.platformData.backBuffer = null;
    init.platformData.backBufferDS = null;
    init.platformData.type = .Default;

    _ = bgfx.init(&init);

    bgfx.setViewClear(0, 0x0001 | 0x0002, clear_color, 1.0, 0);
    bgfx.setViewRect(0, 0, 0, @intCast(w), @intCast(h));

    // Register the HTML5 canvas mouse callbacks so Dear ImGui (and the engine)
    // receive pointer input on the web (#24). No GLFW window on wasm, so this
    // replaces the desktop `input.setWindow` call.
    const input = @import("input");
    input.initWasmInput();
}

/// Android init path: no GLFW. The `ANativeWindow*` surface must have
/// been handed over via `setAndroidNativeWindow` (phase 3); without it
/// `nwh` is null and bgfx init will fail gracefully — phase 2 only proves
/// the plumbing compiles. bgfx selects the GLES/Vulkan renderer for
/// Android from `RendererType.Count` (auto).
fn initWindowAndroid(w: i32, h: i32) void {
    var init: bgfx.Init = undefined;
    bgfx.initCtor(&init);

    init.type = .Count; // auto-select renderer (GLES/Vulkan on Android)
    init.resolution.width = @intCast(w);
    init.resolution.height = @intCast(h);
    init.resolution.reset = current_reset;

    // On Android the native window handle is the `ANativeWindow*` handed
    // over by the NativeActivity glue. `ndt` is unused (no display
    // connection like X11), and the handle type is the platform default.
    init.platformData.ndt = null;
    init.platformData.nwh = android_native_window;
    init.platformData.context = null;
    init.platformData.queue = null;
    init.platformData.backBuffer = null;
    init.platformData.backBufferDS = null;
    init.platformData.type = .Default;

    _ = bgfx.init(&init);

    bgfx.setViewClear(0, 0x0001 | 0x0002, clear_color, 1.0, 0);
    bgfx.setViewRect(0, 0, 0, @intCast(w), @intCast(h));
}

/// Desktop init path: GLFW window + bgfx, native handle per OS.
fn initWindowDesktop(w: i32, h: i32, title: [:0]const u8) void {
    glfw.init() catch return;

    // Tell GLFW not to create an OpenGL context — bgfx manages its own
    glfw.windowHint(.client_api, .no_api);

    // Headless / `--headless` runs (set via `setConfigFlags`) create the
    // GLFW window UNMAPPED. bgfx still needs a real native surface to init
    // its swapchain and to read the backbuffer back for `--screenshot`, so
    // true surfaceless rendering isn't viable cross-platform here; an
    // invisible window gives the same "no window pops up" CI behaviour while
    // keeping the render + readback path intact. The matching
    // exit-after-N-ticks loop lives in `templates/desktop.txt`.
    if (window_hidden) glfw.windowHint(.visible, false);

    glfw_window = glfw.createWindow(
        @intCast(w),
        @intCast(h),
        title,
        null,
        null,
    ) catch return;

    const win = glfw_window orelse return;

    // The window was requested at the LOGICAL `width/height`, but on a
    // HiDPI/Retina display the backing framebuffer is larger (e.g. 2x). Render
    // bgfx at the PHYSICAL framebuffer size from frame 0 so the drawable is
    // sharp instead of a logical-res image stretched onto a Retina surface.
    const fb = win.getFramebufferSize();
    screen_w = @intCast(fb[0]);
    screen_h = @intCast(fb[1]);

    // Initialize bgfx
    var init: bgfx.Init = undefined;
    bgfx.initCtor(&init);

    init.type = .Count; // auto-select renderer
    init.resolution.width = @intCast(screen_w);
    init.resolution.height = @intCast(screen_h);
    init.resolution.reset = current_reset;

    // Fill in bgfx's native display type (ndt) and native window handle
    // (nwh) for the build target. See src/platform.zig for the source
    // mapping and its unit tests.
    switch (comptime platform.windowHandleSourceFor(builtin.target.os.tag)) {
        .cocoa => {
            init.platformData.ndt = null;
            init.platformData.nwh = glfw.getCocoaWindow(win);
        },
        .win32 => {
            init.platformData.ndt = null;
            init.platformData.nwh = glfw.getWin32Window(win);
        },
        .x11 => {
            init.platformData.ndt = glfw.getX11Display();
            const xid: u32 = glfw.getX11Window(win);
            init.platformData.nwh = @ptrFromInt(@as(usize, xid));
        },
        .wayland => {
            // Not currently selected — Linux/BSD map to .x11 in
            // platform.zig. Kept here so adding Wayland support in a
            // follow-up is a platform.zig change, not a window.zig one.
            init.platformData.ndt = glfw.getWaylandDisplay();
            init.platformData.nwh = glfw.getWaylandWindow(win);
        },
        .unsupported => @compileError("bgfx backend: unsupported OS for window handle"),
    }
    init.platformData.context = null;
    init.platformData.queue = null;
    init.platformData.backBuffer = null;
    init.platformData.backBufferDS = null;
    init.platformData.type = .Default;

    _ = bgfx.init(&init);

    bgfx.setViewClear(0, 0x0001 | 0x0002, clear_color, 1.0, 0);
    bgfx.setViewRect(0, 0, 0, @intCast(screen_w), @intCast(screen_h));

    const input = @import("input");
    input.setWindow(win);
}

/// Tear down the gfx-level bgfx resources, then the bgfx context itself.
///
/// Ordering is LOAD-BEARING: `gfx.shutdownPrograms()` destroys the
/// individual resources (sprite program + shaders, the `s_tex` sampler
/// uniform, the 1x1 white texture, the bitmap font atlas, and every
/// uploaded texture in the `texture_handles[]` pool) BEFORE `bgfx.shutdown()`
/// destroys the context. Reversing this double-frees / asserts inside bgfx —
/// `bgfx.shutdown()` invalidates the handles, so a later `destroyTexture`
/// would operate on freed handles. `shutdownPrograms` ALSO resets the
/// lazy-init flags it owns — `shaders_initialized`, `font_atlas_initialized`
/// (via `font.destroyFontAtlas`), and the white-texture / sampler sentinels —
/// so on an Android surface RESTORE the `ensure*` paths re-create everything
/// against the new context. Without that reset the lazy guards would think
/// the resources still exist and the screen would render black/garbage after
/// `APP_CMD_INIT_WINDOW` re-inits bgfx.
///
/// Used both by `closeWindow()` (final teardown) and the Android
/// surface-lost path (`APP_CMD_TERM_WINDOW`), where the context is torn down
/// but the engine state survives for a later restore.
pub fn teardownSurface() void {
    gfx.shutdownPrograms();
    bgfx.shutdown();
}

pub fn closeWindow() void {
    // Release the sprite program (+ its shaders), the s_tex sampler
    // uniform, the 1x1 white texture, the font atlas, and any uploaded
    // textures BEFORE bgfx tears down — otherwise bgfx reports these live
    // handles as leaks on clean shutdown (#384). `teardownSurface` enforces
    // the shutdownPrograms-then-shutdown order; it is idempotent
    // (valid-handle guarded), so it is a safe no-op if rendering never
    // initialized. Runs on both the desktop and Android paths.
    teardownSurface();
    if (no_glfw) {
        // No GLFW to tear down; the surface lifecycle is owned by the host
        // (Android NativeActivity glue / the browser canvas). Clear the
        // native-window handle so state is consistent after teardown.
        android_native_window = null;
        glfw_window = null;
        return;
    }
    if (glfw_window) |win| win.destroy();
    glfw.terminate();
    glfw_window = null;
}

pub fn shouldQuit() bool {
    if (is_wasm) {
        // The browser owns the event loop (emscripten_set_main_loop); there is
        // no per-frame close flag. Never request close.
        return false;
    }
    if (is_android) {
        // The Android activity lifecycle (onDestroy) drives shutdown, not
        // a per-frame close flag. Phase 3 (#302) wires the real signal;
        // until then never request close — returning a "should close" here
        // (e.g. before the surface is handed over at startup, when the
        // handle is still null) would exit the main loop immediately.
        return false;
    }
    if (glfw_window) |win| return win.shouldClose();
    return true;
}

/// Forwarded from the desktop loop when `game.quit()` flips the engine's
/// `running` flag (e.g. the menu Exit button). Sets GLFW's close flag so the
/// next `shouldQuit()` exits the loop — the engine keeps `quit()`
/// backend-agnostic (it only flips `running`), so without this the bgfx loop
/// only ever exited on the window's own close button and Exit did nothing.
/// Mirrors the sokol backend's `sapp.requestQuit`. Android shutdown is driven
/// by the activity lifecycle, not this flag (see `shouldQuit`).
pub fn requestQuit() void {
    if (no_glfw) return;
    if (glfw_window) |win| win.setShouldClose(true);
}

pub fn setTargetFPS(fps: i32) void {
    target_fps_val = fps;
}

// ── `labelle run` automation knobs (assembler#361) ─────────────────────
// The CLI surfaces `--headless` / `--uncapped` / `--ticks=N` as the env
// vars below (set by labelle-cli; `--uncapped` and `--ticks` both imply
// `--headless`). The generated desktop loop reads these via the helpers
// here to: run the GLFW window unmapped (headless — see `initWindowDesktop`),
// disable vsync so the loop runs flat-out (uncapped), and break after N
// frames (ticks). Mirrors the sokol backend's `runHeadless` knobs, except
// bgfx keeps the real GLFW/bgfx loop (it needs a native surface to render +
// read the backbuffer for `--screenshot`), so "headless" here means an
// invisible window rather than a truly windowless run. libc `getenv` keeps
// the helpers self-contained (Zig 0.16 dropped `std.posix.getenv`); on
// Android these env vars are never set, so all three fold to their defaults.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn envTruthy(name: [*:0]const u8) bool {
    if (is_android) return false;
    if (getenv(name)) |raw| return std.mem.span(raw).len > 0;
    return false;
}

/// True when `labelle run --headless` (or `--uncapped`/`--ticks`, which
/// imply it) was passed. The desktop loop uses this to create the window
/// hidden via `setConfigFlags`.
pub fn isHeadless() bool {
    return envTruthy("LABELLE_HEADLESS");
}

/// True when `--uncapped` was passed (only honoured under `--headless`).
/// The desktop loop turns vsync off so the loop is not display-paced.
pub fn isUncapped() bool {
    return isHeadless() and envTruthy("LABELLE_HEADLESS_UNCAPPED");
}

/// Frame count after which the desktop loop should exit cleanly, or 0 for
/// "run until closed" (the default / non-headless case). Parsed from
/// `LABELLE_HEADLESS_TICKS`; a malformed value degrades to 0 (run forever)
/// rather than crashing the game.
pub fn headlessTicks() u64 {
    if (!isHeadless()) return 0;
    if (is_android) return 0;
    const raw = getenv("LABELLE_HEADLESS_TICKS") orelse return 0;
    return std.fmt.parseInt(u64, std.mem.span(raw), 10) catch 0;
}

// ── Frame timing ───────────────────────────────────────────────────────
// bgfx has no built-in frame timer (unlike sokol's `sapp.frameDuration`),
// so we measure the real frame period with a monotonic clock. The
// generated frame loop derives `dt` from this so the sim is
// frame-rate-INDEPENDENT. Previously the bgfx templates hardcoded
// `dt = 0.016`, which tied game speed to the frame rate — vsync-off at
// e.g. 300 FPS ran the sim ~3x too fast (workers walked too quickly).
// `std.time.nanoTimestamp`/`Instant` were removed in Zig 0.16; libc
// `clock_gettime(CLOCK_MONOTONIC)` is the portable replacement (same
// approach as the engine's `nowNs`).
var last_frame_ns: i128 = 0;
// Cross-platform monotonic clock. Each OS's externs live INSIDE its
// `comptime`-folded `switch` arm so the other platform's symbols are never
// referenced — bare libc `clock_gettime` would otherwise fail to link a
// Windows game exe (Cursor Bugbot flagged this; `std.time.Timer`/`Instant`
// aren't available in Zig 0.16 to replace it).
fn monotonicNs() i128 {
    switch (builtin.os.tag) {
        .windows => {
            const k32 = struct {
                extern "kernel32" fn QueryPerformanceCounter(c: *u64) callconv(.winapi) c_int;
                extern "kernel32" fn QueryPerformanceFrequency(f: *u64) callconv(.winapi) c_int;
            };
            var counter: u64 = 0;
            var freq: u64 = 0;
            _ = k32.QueryPerformanceCounter(&counter);
            _ = k32.QueryPerformanceFrequency(&freq);
            if (freq == 0) return 0;
            return @divTrunc(@as(i128, counter) * std.time.ns_per_s, @as(i128, freq));
        },
        else => {
            const Timespec = extern struct { sec: i64, nsec: i64 };
            const libc = struct {
                extern "c" fn clock_gettime(clk: c_int, tp: *Timespec) c_int;
            };
            const clk_id: c_int = switch (builtin.os.tag) {
                .macos, .ios, .watchos, .tvos => 6, // _CLOCK_MONOTONIC
                else => 1, // CLOCK_MONOTONIC (Linux/Android)
            };
            var ts: Timespec = .{ .sec = 0, .nsec = 0 };
            if (libc.clock_gettime(clk_id, &ts) != 0) return 0;
            return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
        },
    }
}

/// Real elapsed seconds since the previous `frameDuration` call. Returns a
/// sane 1/60 on the first call (no baseline yet). The generated loop
/// clamps this (e.g. `min(dt, 4/target_fps)`) to avoid a post-stall spike.
pub fn frameDuration() f64 {
    const now = monotonicNs();
    // A failed reading (0) must not become the new baseline — keep the last
    // good one so the next frame measures a real delta rather than a giant
    // since-epoch span.
    if (now == 0) return 1.0 / 60.0;
    defer last_frame_ns = now;
    if (last_frame_ns == 0 or now <= last_frame_ns) return 1.0 / 60.0;
    return @as(f64, @floatFromInt(now - last_frame_ns)) / @as(f64, std.time.ns_per_s);
}

/// Query whether the window is currently fullscreen. Android is always
/// fullscreen; desktop asks GLFW whether the window is bound to a monitor.
pub fn isFullscreen() bool {
    if (is_android) return true;
    if (is_wasm) return false; // fullscreen is a browser/DOM concern, not bgfx's
    const win = glfw_window orelse return false;
    return win.getMonitor() != null;
}

/// Switch to fullscreen (`on=true`) or windowed (`on=false`). Desktop
/// only — Android is permanently fullscreen, so this is a no-op there.
/// GLFW has no toggle primitive: going fullscreen binds the window to the
/// primary monitor at its current video mode (saving the windowed
/// geometry first); going windowed restores the saved geometry.
///
/// The saved windowed geometry uses GLFW's LOGICAL screen coordinates
/// (`getSize`/`getPos`), and `setMonitor` takes the monitor's video `mode`
/// dimensions — both correct in GLFW's coordinate space. The resulting
/// PHYSICAL framebuffer change is picked up by `ensureSurface()` on the next
/// `beginFrame` (the frame loop drains this fullscreen request before
/// `beginFrame` in the same frame), which resets the bgfx swapchain to the
/// new framebuffer size — so no resize is done here.
pub fn setFullscreen(on: bool) void {
    if (no_glfw) return; // Android is permanently fullscreen; wasm defers to the DOM
    const win = glfw_window orelse return;
    const already = win.getMonitor() != null;
    if (already == on) return;
    if (on) {
        // Remember where the window was so we can come back to it.
        const pos = win.getPos();
        const size = win.getSize();
        windowed_x = pos[0];
        windowed_y = pos[1];
        windowed_w = size[0];
        windowed_h = size[1];
        const monitor = glfw.getPrimaryMonitor() orelse return;
        const mode = glfw.getVideoMode(monitor) catch return;
        win.setMonitor(monitor, 0, 0, mode.width, mode.height, mode.refresh_rate);
    } else {
        win.setMonitor(null, windowed_x, windowed_y, windowed_w, windowed_h, 0);
    }
}

/// Enable/disable vsync at runtime. The generated frame loop drains the
/// engine's `takeVsyncRequest()` and forwards the value here (mirrors
/// `setFullscreen`). Vsync is just the `BGFX_RESET_VSYNC` bit in the reset
/// flags — flip it and re-issue `bgfx.reset` at the current size. Works on
/// every bgfx platform (desktop Metal/GL/D3D, Android GLES). `.Count`
/// keeps the current backbuffer format.
pub fn setVsync(on: bool) void {
    const want: u32 = if (on) RESET_VSYNC else 0;
    if ((current_reset & RESET_VSYNC) == want) return; // already in that mode
    current_reset = (current_reset & ~RESET_VSYNC) | want;
    if (screen_w > 0 and screen_h > 0) {
        bgfx.reset(@intCast(screen_w), @intCast(screen_h), current_reset, .Count);
    }
}

pub fn beginFrame() void {
    const input = @import("input");
    input.newFrame();
    // Reconcile the swapchain with the current physical framebuffer size
    // (DPI move, resize, fullscreen toggle) before sizing the viewport. This
    // runs every frame uniformly so HiDPI changes are picked up without a
    // dedicated resize callback.
    ensureSurface();
    bgfx.setViewRect(0, 0, 0, @intCast(screen_w), @intCast(screen_h));
    // Touch view 0 so bgfx ALWAYS clears + presents it, even on a frame
    // with zero draw calls. `setViewRect` alone does NOT do this — bgfx
    // only processes a view that has submitted draws or an explicit
    // `touch`. Without this, any frame that submits nothing to view 0
    // (e.g. a scene whose only content is still loading, or an empty
    // scene) is dropped entirely by bgfx: the clear never runs and the
    // back buffer is presented black. This was the real cause of the
    // "atlas blacks the screen" bug (#317) — loading an atlas left a
    // window of draw-less frames, and those frames went black instead of
    // showing the clear color. (The original comment here claimed to
    // touch the view but only set the rect.)
    bgfx.touch(0);
}

const INVALID_HANDLE: u16 = std.math.maxInt(u16);

/// Pending screenshot path, set by `takeScreenshot` and consumed by the
/// next `endFrame`. We COPY the caller's path into this static buffer
/// rather than stash the slice: `endFrame` runs a frame later, so a
/// caller passing a stack/arena-temporary string would otherwise leave a
/// dangling pointer.
var pending_screenshot_buf: [1024:0]u8 = undefined;
var has_pending_screenshot: bool = false;

pub fn endFrame() void {
    // Queue the backbuffer capture (if requested) BEFORE the frame swap so
    // bgfx fulfils it for THIS frame's content — the scene + imgui overlay
    // just submitted. Requesting after `bgfx.frame()` (a separate empty
    // frame) would capture a cleared backbuffer with no draws.
    if (has_pending_screenshot) {
        const invalid_fb = bgfx.FrameBufferHandle{ .idx = INVALID_HANDLE };
        bgfx.requestScreenShot(invalid_fb, &pending_screenshot_buf);
        has_pending_screenshot = false;
    }
    _ = bgfx.frame(0);
}

/// Capture the current backbuffer to a file (labelle-cli#227 screenshot
/// support, mirroring raylib/sokol's `window.takeScreenshot`).
///
/// bgfx has no synchronous readback: `requestScreenShot` queues a capture
/// that bgfx fulfils on the NEXT `bgfx.frame()` by invoking the active
/// callback's `screenShot`. We pass `BGFX_INVALID_HANDLE` (the backbuffer)
/// and rely on bgfx's BUILT-IN default callback (no custom callback is
/// installed at init), which writes the captured pixels to `<path>.tga`
/// via its embedded image writer.
///
/// IMPORTANT: the request must be queued before the frame swap that
/// presents the content. The frame loop calls `takeScreenshot` after
/// `g.render()` + the GUI draw but on the SAME iteration whose `endFrame`
/// then does the swap — so we just stash the path and let `endFrame`
/// issue the request right before `bgfx.frame()`. (Calling
/// `requestScreenShot` here followed by our own `bgfx.frame()` would swap
/// an empty, content-less frame and capture that instead — the cause of
/// the initial blank-screenshot bug.)
///
/// bgfx appends its own `.tga` extension, so a path like `/tmp/shot`
/// yields `/tmp/shot.tga`.
///
/// The path is COPIED into a static buffer (consumed a frame later in
/// `endFrame`), so a caller may pass a temporary string safely.
pub fn takeScreenshot(path: [:0]const u8) void {
    if (path.len >= pending_screenshot_buf.len) {
        std.log.err("bgfx screenshot path too long (max {d} bytes): {s}", .{ pending_screenshot_buf.len - 1, path });
        return;
    }
    // Copy including the null terminator so the buffer is a valid C string.
    @memcpy(pending_screenshot_buf[0 .. path.len + 1], path[0 .. path.len + 1]);
    has_pending_screenshot = true;
}

pub fn clearBackground(r: u8, g: u8, b: u8, a: u8) void {
    clear_color = @as(u32, r) << 24 | @as(u32, g) << 16 | @as(u32, b) << 8 | @as(u32, a);
    bgfx.setViewClear(0, 0x0001 | 0x0002, clear_color, 1.0, 0);
}

pub fn drawText(text: [:0]const u8, x: i32, y: i32, font_size: i32, r: u8, g: u8, b: u8, a: u8) void {
    _ = text;
    _ = x;
    _ = y;
    _ = font_size;
    _ = r;
    _ = g;
    _ = b;
    _ = a;
    // bgfx debug text could be used here but requires setDebug(BGFX_DEBUG_TEXT)
}
