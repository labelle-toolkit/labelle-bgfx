/// bgfx Android app shell — the NativeActivity glue entry point.
///
/// sokol hides this inside `sokol_app`; the bgfx backend has no equivalent,
/// so this module is the hand-rolled analog. It is built on the NDK's
/// `android_native_app_glue` (compiled into the Android build by
/// `build.zig`, Android-gated). The glue spins up a dedicated thread, sets
/// up an `ALooper`, and calls our `android_main(app)` — from there we drive:
///
///   * the activity lifecycle (`APP_CMD_*`): create/destroy the bgfx
///     surface on `INIT_WINDOW`/`TERM_WINDOW`, honor resume/pause, and
///     translate `app.destroyRequested` into `window.shouldQuit`.
///   * touch input (`AInputEvent`/`AMotionEvent_*`): fed into `input.zig`
///     as pointer-down + x/y so the engine sees touch as mouse-like
///     pointer input (mirrors the desktop mouse path).
///
/// Compile target: `aarch64-linux-android`. This module is Android-only —
/// on every other target it is a no-op namespace (see the `is_android`
/// guard) so a stray import never breaks desktop builds.
const std = @import("std");
const builtin = @import("builtin");
// `window` / `input` come in as named modules (wired in build.zig) — NOT
// path imports. A `@import("window.zig")` here would make window.zig
// belong to two module roots (its own `window` module and this `root`),
// which Zig 0.16 rejects ("file exists in modules ...").
const window = @import("window");
const input = @import("input");
// `root` is the compilation's root module — the generated game's
// `main.zig` when this backend is consumed by an assembled project. We
// read an optional `labelle_provides_android_main` declaration from it so
// the game can own the `android_main` C entry point (registering its
// init + tick callbacks before handing control to `run`). When that decl
// is absent (e.g. the backend's own Android compile-check, which has no
// game root), this module exports `android_main` itself. See phase 4
// (#303) — the generated game needs to set up the engine/scene on the
// first `INIT_WINDOW`, which it can only do from inside the entry it owns.
const root = @import("root");

const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

/// True when the root (game) module declares it provides its own
/// `android_main` export. The generated `main.zig` sets
/// `pub const labelle_provides_android_main = true;` and exports an
/// `android_main` that registers the init/tick callbacks then calls
/// `run(app)`. When false (backend self-test, or a future shell-owned
/// entry), this module's own `android_main` export is emitted instead.
// Explicit nested form rather than `@hasDecl(...) and root.<decl>`: although
// `and` lazily short-circuits at comptime (so the bare form also compiles),
// the if/else makes the "only read the decl when it exists" intent
// unambiguous and avoids any reader doubt about analyzing a missing decl.
const game_owns_main = if (@hasDecl(root, "labelle_provides_android_main"))
    root.labelle_provides_android_main
else
    false;

// ── Default surface size ────────────────────────────────────────────
// The real width/height come from the `ANativeWindow` once it exists;
// these are the pre-surface defaults handed to `initWindow`. They are
// refreshed from `ANativeWindow_getWidth/Height` on `INIT_WINDOW`.
const default_width: i32 = 800;
const default_height: i32 = 600;

// ── NDK / native_app_glue ABI (hand-declared `extern`) ──────────────
// We declare the slice of the glue/NDK ABI we touch rather than
// `@cImport`-ing the whole header tree (which drags in
// <android/native_activity.h>, JNI, etc.). Layout/order mirror
// `android_native_app_glue.h` and the NDK `android/*.h` headers shipped
// with NDK r27; only the leading fields we read are spelled out, with an
// opaque tail to keep the struct the right size for pointer arithmetic
// done entirely on the C side.

pub const ANativeWindow = opaque {};
pub const AInputQueue = opaque {};
pub const AInputEvent = opaque {};
pub const ALooper = opaque {};
pub const AConfiguration = opaque {};

/// `android/native_activity.h` — `ANativeActivityCallbacks`. The framework
/// invokes every entry on the UI/main thread. Field order is ABI-load-
/// bearing — it must match the NDK header exactly so our chained
/// `onWindowFocusChanged` lands in the right slot. We only name the focus
/// callback we chain (immersive re-hide must run on the UI thread, which
/// is the only thread these fire on); the rest are opaque pointers since
/// the NDK glue owns them and we never call them ourselves.
pub const ANativeActivityCallbacks = extern struct {
    onStart: ?*const anyopaque,
    onResume: ?*const anyopaque,
    onSaveInstanceState: ?*const anyopaque,
    onPause: ?*const anyopaque,
    onStop: ?*const anyopaque,
    onDestroy: ?*const anyopaque,
    // `void (*)(ANativeActivity*, int hasFocus)`. The NDK glue installs its
    // own handler here (it posts APP_CMD_GAINED_FOCUS/LOST_FOCUS). We chain
    // it: save the glue's pointer, install `focusHook`, and forward. The
    // framework fires this on the UI thread — the one thread where the
    // engine's `WindowInsetsController.hide()` is legal.
    onWindowFocusChanged: ?*const fn (*ANativeActivity, c_int) callconv(.c) void,
    onNativeWindowCreated: ?*const anyopaque,
    onNativeWindowResized: ?*const anyopaque,
    onNativeWindowRedrawNeeded: ?*const anyopaque,
    onNativeWindowDestroyed: ?*const anyopaque,
    onInputQueueCreated: ?*const anyopaque,
    onInputQueueDestroyed: ?*const anyopaque,
    onContentRectChanged: ?*const anyopaque,
    onConfigurationChanged: ?*const anyopaque,
    onLowMemory: ?*const anyopaque,
};

/// `android/native_activity.h` — `ANativeActivity`. Only the leading
/// `callbacks` pointer we touch (to chain `onWindowFocusChanged`) is
/// typed; the rest is an opaque tail. The C struct begins with this
/// pointer, so the offset is correct.
pub const ANativeActivity = extern struct {
    callbacks: *ANativeActivityCallbacks,
    _tail: [11]?*anyopaque,
};

/// One poll source returned by `ALooper_pollOnce`. The glue fills
/// `process` with its own `process_cmd` / `process_input`; we just call
/// it, which in turn dispatches to our `onAppCmd` / `onInputEvent`.
pub const android_poll_source = extern struct {
    id: i32,
    app: *android_app,
    process: ?*const fn (app: *android_app, source: *android_poll_source) callconv(.c) void,
};

/// `struct android_app` from `android_native_app_glue.h` (NDK r27).
/// Field order/types must match the C struct exactly — the glue thread
/// writes these and we read them. Everything past `destroyRequested` is
/// glue-private bookkeeping we never touch, so it's collapsed into an
/// opaque tail sized to keep `@sizeOf` and trailing-field offsets
/// irrelevant to us (we only ever hold a `*android_app` the glue gave us).
pub const android_app = extern struct {
    userData: ?*anyopaque,
    onAppCmd: ?*const fn (app: *android_app, cmd: i32) callconv(.c) void,
    onInputEvent: ?*const fn (app: *android_app, event: *AInputEvent) callconv(.c) c_int,
    activity: ?*ANativeActivity,
    config: ?*AConfiguration,
    savedState: ?*anyopaque,
    savedStateSize: usize,
    looper: ?*ALooper,
    inputQueue: ?*AInputQueue,
    window: ?*ANativeWindow,
    contentRect: ARect,
    activityState: c_int,
    destroyRequested: c_int,
    // ── glue-private tail ───────────────────────────────────────────
    // mutex / cond / fds / thread / poll sources / pending* / running /
    // stateSaved / destroyed / redrawNeeded. We never read these from
    // Zig — they're driven entirely by the glue's C thread. Kept opaque
    // so we don't have to mirror pthread_mutex_t/pthread_cond_t layout.
    _glue_private: [256]u8,
};

pub const ARect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

// ── APP_CMD_* (android_native_app_glue.h) ───────────────────────────
const APP_CMD_INPUT_CHANGED: i32 = 0;
const APP_CMD_INIT_WINDOW: i32 = 1;
const APP_CMD_TERM_WINDOW: i32 = 2;
const APP_CMD_WINDOW_RESIZED: i32 = 3;
const APP_CMD_WINDOW_REDRAW_NEEDED: i32 = 4;
const APP_CMD_CONTENT_RECT_CHANGED: i32 = 5;
const APP_CMD_GAINED_FOCUS: i32 = 6;
const APP_CMD_LOST_FOCUS: i32 = 7;
const APP_CMD_CONFIG_CHANGED: i32 = 8;
const APP_CMD_LOW_MEMORY: i32 = 9;
const APP_CMD_START: i32 = 10;
const APP_CMD_RESUME: i32 = 11;
const APP_CMD_SAVE_STATE: i32 = 12;
const APP_CMD_PAUSE: i32 = 13;
const APP_CMD_STOP: i32 = 14;
const APP_CMD_DESTROY: i32 = 15;

// ── ALooper poll results (android/looper.h) ─────────────────────────
const ALOOPER_POLL_WAKE: c_int = -1;
const ALOOPER_POLL_CALLBACK: c_int = -2;
const ALOOPER_POLL_TIMEOUT: c_int = -3;
const ALOOPER_POLL_ERROR: c_int = -4;

// ── AInputEvent types (android/input.h) ─────────────────────────────
const AINPUT_EVENT_TYPE_KEY: i32 = 1;
const AINPUT_EVENT_TYPE_MOTION: i32 = 2;

// ── AKeyEvent actions (android/input.h) ─────────────────────────────
const AKEY_EVENT_ACTION_DOWN: i32 = 0;
const AKEY_EVENT_ACTION_UP: i32 = 1;

// `AKEYCODE_BACK` — many controllers map the B / "circle" / select button to
// the system BACK key. If we leave that unconsumed, Android performs back
// navigation (the activity finishes — the game quits) the moment the player
// presses B. We consume BACK only when it originates from a gamepad source
// (so the real system BACK gesture/button is untouched). Mirrors sokol's
// B->BACK guard (assembler#248).
const AKEYCODE_BACK: i32 = 4;

// ── AInputEvent source classes/sources (android/input.h) ────────────
// A device's source is a bitmask; controllers expose GAMEPAD and/or
// JOYSTICK. We treat a motion event as a gamepad axis report only when its
// source carries JOYSTICK (analog sticks/triggers/hat live there); key
// events from GAMEPAD/JOYSTICK/KEYBOARD-with-buttons carry the BUTTON_*/
// DPAD_* keycodes the shared state module maps. Mirrors the source masks in
// the JNI glue (`is_gamepad_sources`).
const AINPUT_SOURCE_GAMEPAD: i32 = 0x00000401;
const AINPUT_SOURCE_JOYSTICK: i32 = 0x01000010;

// ── AMOTION_EVENT_AXIS_* (android/input.h) ──────────────────────────
// The raw MotionEvent axis ids we sample into the shared state module's
// forwarded-axis buffer (indexed by `input.GAMEPAD_AXIS_COUNT` / `agp.FA_*`).
// Order here mirrors that buffer's FA_* layout.
const AMOTION_EVENT_AXIS_X: i32 = 0;
const AMOTION_EVENT_AXIS_Y: i32 = 1;
const AMOTION_EVENT_AXIS_Z: i32 = 11;
const AMOTION_EVENT_AXIS_RZ: i32 = 14;
const AMOTION_EVENT_AXIS_RX: i32 = 12;
const AMOTION_EVENT_AXIS_RY: i32 = 13;
const AMOTION_EVENT_AXIS_LTRIGGER: i32 = 17;
const AMOTION_EVENT_AXIS_RTRIGGER: i32 = 18;
const AMOTION_EVENT_AXIS_GAS: i32 = 22;
const AMOTION_EVENT_AXIS_BRAKE: i32 = 23;
const AMOTION_EVENT_AXIS_HAT_X: i32 = 15;
const AMOTION_EVENT_AXIS_HAT_Y: i32 = 16;

// ── AMotionEvent actions (android/input.h), masked ──────────────────
const AMOTION_EVENT_ACTION_MASK: i32 = 0xff;
const AMOTION_EVENT_ACTION_DOWN: i32 = 0;
const AMOTION_EVENT_ACTION_UP: i32 = 1;
const AMOTION_EVENT_ACTION_MOVE: i32 = 2;
const AMOTION_EVENT_ACTION_CANCEL: i32 = 3;
const AMOTION_EVENT_ACTION_POINTER_DOWN: i32 = 5;
const AMOTION_EVENT_ACTION_POINTER_UP: i32 = 6;

// ── NDK / glue functions we call ────────────────────────────────────
// Declared `extern` so the linker resolves them from the glue
// (`android_app_*`), libandroid (`ANativeWindow_*`, `AMotionEvent_*`,
// `AInputEvent_*`), and the C runtime (`ALooper_pollOnce`). The link of
// these libs is phase 4 — here we only need them declared so the module
// compiles; the object is produced without a final link.
extern fn ALooper_pollOnce(timeoutMillis: c_int, outFd: ?*c_int, outEvents: ?*c_int, outData: ?*?*anyopaque) c_int;

extern fn ANativeWindow_getWidth(window: *ANativeWindow) i32;
extern fn ANativeWindow_getHeight(window: *ANativeWindow) i32;

extern fn AInputEvent_getType(event: *AInputEvent) i32;
extern fn AInputEvent_getSource(event: *AInputEvent) i32;
extern fn AInputEvent_getDeviceId(event: *AInputEvent) i32;
extern fn AMotionEvent_getAction(event: *AInputEvent) i32;
extern fn AMotionEvent_getX(event: *AInputEvent, pointer_index: usize) f32;
extern fn AMotionEvent_getY(event: *AInputEvent, pointer_index: usize) f32;
extern fn AMotionEvent_getPointerCount(event: *AInputEvent) usize;
extern fn AMotionEvent_getPointerId(event: *AInputEvent, pointer_index: usize) i32;
extern fn AMotionEvent_getAxisValue(event: *AInputEvent, axis: i32, pointer_index: usize) f32;
extern fn AKeyEvent_getAction(event: *AInputEvent) i32;
extern fn AKeyEvent_getKeyCode(event: *AInputEvent) i32;

// ── Shell state ─────────────────────────────────────────────────────
// `bgfx_ready` guards the per-frame tick: we only draw once the surface
// exists and bgfx is initialized (between INIT_WINDOW and TERM_WINDOW).
// `is_resumed` honors the activity pause/resume lifecycle — when paused
// we keep pumping events but skip rendering.
var bgfx_ready: bool = false;
var is_resumed: bool = false;

// ── Immersive-mode UI-thread hook (bgfx-immersive) ──────────────────
// Hiding the system bars (`WindowInsetsController.hide()`) MUST run on the
// Android UI/main thread — Android throws if it runs anywhere else, even
// on a thread attached to the JVM. native_app_glue runs the game (our
// `gameFrame`) on its own APP thread, NOT the UI thread, so the hide can't
// be driven from the frame loop.
//
// The fix: chain `ANativeActivity.callbacks.onWindowFocusChanged`. The
// framework invokes that callback ON THE UI THREAD — at launch (the
// window's first focus gain) and on every focus regain (returning from
// the shade / recents / a notification, exactly when immersive-sticky
// flags get cleared). We install `focusHook`, which forwards to the NDK
// glue's own handler (so its APP_CMD_GAINED_FOCUS/LOST_FOCUS bookkeeping
// is intact) and then, on focus gain, invokes a registered immersive
// callback — the engine's UI-thread JNI hide.
//
// The shell never depends on the engine: it stores a bare
// `*const fn() callconv(.c) void`. The generated `main.zig` (which owns
// both the shell and the engine) registers
// `engine.android.applyImmersiveUiThread` via `setImmersiveCallback`.
pub const ImmersiveCb = *const fn () callconv(.c) void;
var immersive_cb: ?ImmersiveCb = null;

/// Register the immersive re-hide callback. Invoked on the UI thread from
/// `focusHook` on every focus gain (launch + each regain). The generated
/// `main.zig` passes `engine.android.applyImmersiveUiThread`. Call before
/// `run()`. When unset (immersive disabled), `focusHook` just forwards.
pub fn setImmersiveCallback(cb: ImmersiveCb) void {
    immersive_cb = cb;
}

/// The NDK glue's original `onWindowFocusChanged`, saved so `focusHook`
/// can forward to it. Set in `run()` before `focusHook` is installed.
var glue_focus_cb: ?*const fn (*ANativeActivity, c_int) callconv(.c) void = null;

/// Our chained `onWindowFocusChanged`. Runs on the UI thread, so the
/// engine's `WindowInsetsController.hide()` (driven via `immersive_cb`)
/// is thread-legal here. Forward to the glue first so its lifecycle
/// bookkeeping is intact, then re-hide on focus gain.
fn focusHook(activity: *ANativeActivity, has_focus: c_int) callconv(.c) void {
    if (glue_focus_cb) |cb| cb(activity, has_focus);
    if (has_focus != 0) {
        if (immersive_cb) |cb| cb();
    }
}

// ── ANativeActivity accessor (#310 Stage 4) ─────────────────────────
// Core's Android JNI seam (`AndroidBackendContext`, labelle-core#310) needs
// the running `ANativeActivity*` to reach immersive mode + the InputManager
// gamepad enumeration. The bgfx shell owns that pointer — the native_app_glue
// hands it over as `app.activity`. We stash it from `run` and surface it two
// ways:
//   * `getNativeActivity()` — Zig accessor (compile-check / direct callers).
//   * `labelle_bgfx_get_native_activity` — the C-ABI export the bgfx Android
//     backend adapter (`backends/bgfx/src/android.zig`, surfaced as
//     `backend_input.android`) binds `extern "c"` to build the seam's
//     `get_native_activity` vtable entry. A C symbol (not a Zig import)
//     deliberately breaks the would-be module cycle: the shell imports
//     `input`, so `input` can't import the shell back — exactly how the sokol
//     adapter reaches sokol_app's `sapp_android_get_native_activity()`.
var native_activity: ?*ANativeActivity = null;

/// Optional per-frame tick callback, set by the game's entry before it
/// hands control to the shell. Called once per loop iteration while the
/// surface is live and the activity is resumed. Mirrors the desktop
/// `while (!shouldQuit()) { beginFrame(); ...; endFrame(); }`
/// loop, which the game owns on desktop; on Android the shell owns the
/// loop and calls back into the game here.
pub const TickFn = *const fn () callconv(.c) void;
var tick_fn: ?TickFn = null;

/// Register the per-frame tick callback. Call before `android_main` runs
/// (e.g. from a `comptime`/init path), or from inside the game's own
/// `android_main` wrapper before entering `run`.
pub fn setTickCallback(cb: TickFn) void {
    tick_fn = cb;
}

/// Optional one-shot surface-ready callback, set by the game before it
/// hands control to the shell. Fired exactly once — on the FIRST
/// `INIT_WINDOW`, AFTER `window.initWindow()` has brought bgfx up against
/// the surface, and BEFORE the first `tick_fn`. This is where the
/// generated game does engine + scene init: it can only run once bgfx is
/// live (the engine's render pipeline binds bgfx state at init), and it
/// must run before the first frame ticks. The desktop generated `main`
/// has no analog — it owns a linear `init → loop` body — so this hook is
/// Android-only by construction (it's only ever set from the Android
/// entry).
pub const InitFn = *const fn () callconv(.c) void;
var init_fn: ?InitFn = null;

/// Guards the one-shot `init_fn`: a TERM_WINDOW + later INIT_WINDOW
/// (app backgrounded then resumed) re-creates the bgfx surface but must
/// NOT re-run engine/scene init — the engine state persists across the
/// surface teardown. Only the very first surface fires the game's init.
var init_done: bool = false;

/// Register the one-shot surface-ready (engine init) callback. Call from
/// the game's `android_main` wrapper before entering `run`.
pub fn setInitCallback(cb: InitFn) void {
    init_fn = cb;
}

/// GPU-context-loss callbacks (epic #386 Phase 4). On Android,
/// `APP_CMD_TERM_WINDOW` destroys the GPU surface AND every bgfx
/// texture/shader; `APP_CMD_INIT_WINDOW` later recreates the surface. The
/// engine's catalog (sprites) is GPU state that must be forgotten on loss
/// and rebuilt on restore — the engine exposes `Game.surfaceLost()` /
/// `Game.surfaceRestored()` for exactly this. These bare C fn pointers are
/// the shell's engine-agnostic seam (same pattern as `InitFn`/`TickFn`):
/// the generated `main.zig` registers `@hasDecl`-gated trampolines that
/// call the engine methods, so an OLDER engine without those methods still
/// compiles.
///
/// `surface_lost_fn` fires on TERM_WINDOW BEFORE the bgfx teardown (the
/// engine must forget its catalog handles while they're still nominally
/// valid). `surface_restored_fn` fires on a NON-FIRST INIT_WINDOW, AFTER
/// bgfx is back up — never on the first window (that path runs `init_fn`).
pub const SurfaceFn = *const fn () callconv(.c) void;
var surface_lost_fn: ?SurfaceFn = null;
var surface_restored_fn: ?SurfaceFn = null;

/// Register the surface-lost callback (engine `surfaceLost`). Fired on
/// `APP_CMD_TERM_WINDOW` before bgfx is torn down. Call before `run()`.
pub fn setSurfaceLostCallback(cb: SurfaceFn) void {
    surface_lost_fn = cb;
}

/// Register the surface-restored callback (engine `surfaceRestored`). Fired
/// on a re-init `APP_CMD_INIT_WINDOW` (NOT the first), after bgfx is back
/// up. Call before `run()`.
pub fn setSurfaceRestoredCallback(cb: SurfaceFn) void {
    surface_restored_fn = cb;
}

// ── Lifecycle: APP_CMD_* handler ────────────────────────────────────
fn onAppCmd(app: *android_app, cmd: i32) callconv(.c) void {
    switch (cmd) {
        APP_CMD_INIT_WINDOW => {
            // A new ANativeWindow is ready. Hand it to the window module
            // and bring bgfx up against it.
            if (app.window) |w| {
                window.setAndroidNativeWindow(@ptrCast(w));
                const width = ANativeWindow_getWidth(w);
                const height = ANativeWindow_getHeight(w);
                const ww: i32 = if (width > 0) width else default_width;
                const wh: i32 = if (height > 0) height else default_height;
                window.initWindow(ww, wh, "labelle");
                bgfx_ready = true;

                // Cold init vs. surface restore (#386 Phase 4). The very
                // first INIT_WINDOW runs the game's one-shot engine/scene
                // init (`init_fn`) — engine state is built once and survives
                // every later TERM/INIT cycle. A LATER INIT_WINDOW (resume
                // after backgrounding) re-creates the bgfx surface against a
                // brand-new context; the engine must rebuild its GPU catalog
                // (sprites), so we fire `surface_restored_fn` instead.
                // surfaceRestored therefore fires ONLY in the `else` — never
                // on the first window.
                if (!init_done) {
                    init_done = true;
                    if (init_fn) |cb| cb();
                    std.log.info("bgfx: first surface (cold init)", .{});
                } else {
                    if (surface_restored_fn) |cb| cb();
                    std.log.info("bgfx: re-init against new surface (restore)", .{});
                }
            }
        },
        APP_CMD_TERM_WINDOW => {
            // The surface is going away — bgfx destroys the GPU context AND
            // every texture/shader. Ordering is LOAD-BEARING: notify the
            // engine FIRST (`surface_lost_fn`) so it forgets its catalog
            // handles while they're still nominally valid, THEN tear bgfx
            // down (`teardownSurface` = shutdownPrograms-then-shutdown), THEN
            // drop the native handle so a later INIT_WINDOW re-inits cleanly.
            if (bgfx_ready) {
                if (surface_lost_fn) |cb| cb();
                window.teardownSurface();
                bgfx_ready = false;
                window.setAndroidNativeWindow(null);
                std.log.info("bgfx: shutdownPrograms + bgfx.shutdown (surface lost)", .{});
            } else {
                window.setAndroidNativeWindow(null);
            }
        },
        APP_CMD_GAINED_FOCUS, APP_CMD_RESUME, APP_CMD_START => {
            is_resumed = true;
            // Immersive re-hide is NOT driven from here: it must run on the
            // UI thread, and this handler runs on the glue's app thread. The
            // re-hide is driven by `focusHook` (chained onWindowFocusChanged),
            // which the framework invokes on the UI thread on focus gain.
        },
        APP_CMD_LOST_FOCUS, APP_CMD_PAUSE, APP_CMD_STOP => {
            is_resumed = false;
        },
        APP_CMD_DESTROY => {
            // Surface should already be gone via TERM_WINDOW; be defensive.
            // Route through the same shutdownPrograms-then-shutdown order as
            // the surface-lost path (via `closeWindow`, which also drops the
            // native-window handle), but do NOT fire `surface_lost_fn`: the
            // engine is about to deinit, so there's no restore to prepare for
            // and notifying it would race its own teardown.
            if (bgfx_ready) {
                window.closeWindow();
                bgfx_ready = false;
            }
            is_resumed = false;
            // Reset the cold-start guard. `init_done` is module-global, so if
            // Android keeps the process cached after destroying the Activity, a
            // later relaunch's first INIT_WINDOW would otherwise take the RESTORE
            // branch (`surfaceRestored`) against deinitialized/stale engine state
            // instead of a clean cold init (`init_fn`) → crash. Resetting here
            // guarantees the next Activity launch cold-inits. (Gemini + CodeRabbit.)
            init_done = false;
        },
        else => {},
    }
}

// ── Input: AInputEvent handler (touch + gamepad) ────────────────────
// Returns 1 ("handled") for events we consume, 0 otherwise so the glue lets
// the system process them. Two paths:
//
//   * Touch (motion events from a touchscreen / mouse-like source) is mapped
//     to the backend's pointer model: pointer 0's (x, y) becomes the mouse
//     position and down/up drives mouse button 0, exactly how `input.zig`
//     reports the desktop mouse — so the engine's existing mouse-driven
//     UI/hit-testing sees touch with no engine-side changes.
//   * Gamepad (#310 Stage 4): KEY events carry BUTTON_*/DPAD_* keycodes;
//     JOYSTICK-source MOTION events carry analog sticks/triggers/hat. Both
//     route into the shared `android_gamepad` state (via `input.zig`), keyed
//     by `AInputEvent_getDeviceId` (the same id the JNI detection registry
//     emits as its hotplug slot), so the engine's gamepad queries resolve.
fn onInputEvent(app: *android_app, event: *AInputEvent) callconv(.c) c_int {
    _ = app;
    const etype = AInputEvent_getType(event);
    const source = AInputEvent_getSource(event);
    const device_id = AInputEvent_getDeviceId(event);

    if (etype == AINPUT_EVENT_TYPE_KEY) {
        // Controller buttons (BUTTON_A/B/X/Y, L1/R1/L2/R2, thumbs, start/
        // select/mode) and DPAD_* arrive as key events. Forward the raw
        // keycode; the shared state module maps it to a canonical button
        // (and ignores non-gamepad keys).
        const keycode = AKeyEvent_getKeyCode(event);
        const action = AKeyEvent_getAction(event);
        if (action == AKEY_EVENT_ACTION_DOWN) {
            input.applyGamepadKey(device_id, keycode, true);
        } else if (action == AKEY_EVENT_ACTION_UP) {
            input.applyGamepadKey(device_id, keycode, false);
        }
        // Consume BACK when it comes from a gamepad/joystick (controllers map
        // B/select to AKEYCODE_BACK) so it doesn't quit the activity; leave
        // the genuine system BACK (touchscreen/system source) unhandled so it
        // still navigates. Other gamepad keys stay unconsumed (return 0) —
        // the system does nothing useful with BUTTON_*/DPAD_*, and consuming
        // them all would swallow HOME/volume on odd devices.
        const from_pad = (source & AINPUT_SOURCE_GAMEPAD) == AINPUT_SOURCE_GAMEPAD or
            (source & AINPUT_SOURCE_JOYSTICK) == AINPUT_SOURCE_JOYSTICK;
        if (keycode == AKEYCODE_BACK and from_pad) return 1;
        return 0;
    }

    if (etype != AINPUT_EVENT_TYPE_MOTION) return 0;

    // Joystick-source motion = gamepad analog axes (sticks, triggers, hat).
    // Sample the raw MotionEvent axes into the forwarded-axis buffer the
    // shared state module expects (FA_* order) and forward; the state module
    // applies the per-device axis-routing quirk on read.
    if ((source & AINPUT_SOURCE_JOYSTICK) == AINPUT_SOURCE_JOYSTICK) {
        var axes = [_]f32{0} ** input.GAMEPAD_AXIS_COUNT;
        // FA_* layout (android_gamepad_state.zig): X, Y, Z, RZ, RX, RY,
        // LTRIGGER, RTRIGGER, GAS, BRAKE, HAT_X, HAT_Y.
        axes[0] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_X, 0);
        axes[1] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_Y, 0);
        axes[2] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_Z, 0);
        axes[3] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_RZ, 0);
        axes[4] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_RX, 0);
        axes[5] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_RY, 0);
        axes[6] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_LTRIGGER, 0);
        axes[7] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_RTRIGGER, 0);
        axes[8] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_GAS, 0);
        axes[9] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_BRAKE, 0);
        axes[10] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_HAT_X, 0);
        axes[11] = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_HAT_Y, 0);
        input.applyGamepadMotion(device_id, axes);
        return 1;
    }

    const action = AMotionEvent_getAction(event) & AMOTION_EVENT_ACTION_MASK;

    // Primary pointer (index 0) position drives the pointer location.
    const count = AMotionEvent_getPointerCount(event);
    if (count > 0) {
        const x = AMotionEvent_getX(event, 0);
        const y = AMotionEvent_getY(event, 0);
        input.setTouchPointer(0, x, y, AMotionEvent_getPointerId(event, 0));
    }

    // We model a single pointer (finger 0). Only the FIRST finger going
    // down (ACTION_DOWN) and the LAST finger coming up (ACTION_UP) change
    // the down-state. POINTER_DOWN/POINTER_UP are secondary fingers in a
    // multi-touch gesture — the primary is still down, so they must NOT
    // release it; they only refresh the primary's position (done above).
    switch (action) {
        AMOTION_EVENT_ACTION_DOWN => {
            input.setPointerDown(true);
        },
        AMOTION_EVENT_ACTION_UP, AMOTION_EVENT_ACTION_CANCEL => {
            input.setPointerDown(false);
            input.clearTouch();
        },
        // MOVE / POINTER_DOWN / POINTER_UP: position already refreshed
        // above; keep the primary down-state unchanged.
        else => {},
    }
    return 1;
}

/// The NativeActivity glue's entry point. The glue calls this on the app
/// thread after wiring up the looper and activity. We register our cmd /
/// input callbacks and run the event+frame loop until the activity is
/// destroyed.
///
/// Exported with C linkage as `android_main` so the glue's
/// `android_native_app_glue.c` (which declares `extern void
/// android_main(struct android_app*)`) links against it.
pub fn run(app: *android_app) void {
    app.onAppCmd = onAppCmd;
    app.onInputEvent = onInputEvent;

    // Stash the activity for the backend-seam accessor the engine's
    // immersive-mode helper calls (see `native_activity` above). The glue
    // has populated `app.activity` by the time it calls us.
    native_activity = app.activity;

    // Chain `onWindowFocusChanged` so the engine's immersive re-hide runs
    // on the UI thread (the only thread `WindowInsetsController.hide()` is
    // legal on). The NDK glue installed its own handler in
    // `ANativeActivity_onCreate` before spawning this app thread, so by now
    // `app.activity.callbacks.onWindowFocusChanged` is the glue's pointer:
    // save it, then install `focusHook`, which forwards to it and fires the
    // immersive callback on focus gain. No-op when immersive is disabled
    // (`immersive_cb` unset) — the hook just forwards. Done from `run`
    // (app thread) but the slot write is a single pointer store the
    // framework reads later on the UI thread; the glue never rewrites this
    // slot after onCreate, so there is no race.
    if (app.activity) |activity| {
        glue_focus_cb = activity.callbacks.onWindowFocusChanged;
        activity.callbacks.onWindowFocusChanged = &focusHook;
    }

    // Event + frame loop. `ALooper_pollOnce` returns the poll-source id;
    // we call `source.process(...)` which dispatches to our callbacks.
    // When the surface is live and we're resumed, tick a frame. The loop
    // ends when the activity requests destruction.
    while (app.destroyRequested == 0) {
        var fd: c_int = 0;
        var events: c_int = 0;
        var data: ?*anyopaque = null;

        // Drain ALL pending events, then draw. The timeout is recomputed
        // on every `pollOnce` call (the canonical native_app_glue idiom):
        //   - active (surface live + resumed) → 0: returns immediately
        //     once the queue is empty so we fall through and render every
        //     frame.
        //   - idle → -1: blocks until an event arrives, so we don't spin
        //     while backgrounded / before the surface exists.
        // No early break — processing only one event per frame (the prior
        // bug) caps input throughput and adds latency.
        while (ALooper_pollOnce(
            if (bgfx_ready and is_resumed) 0 else -1,
            &fd,
            &events,
            &data,
        ) >= 0) {
            if (data) |d| {
                const source: *android_poll_source = @ptrCast(@alignCast(d));
                if (source.process) |proc| proc(source.app, source);
            }
            if (app.destroyRequested != 0) break;
        }

        if (app.destroyRequested != 0) break;

        // Per-frame tick: only when the surface exists, bgfx is up, and
        // the activity is in the foreground.
        if (bgfx_ready and is_resumed) {
            if (tick_fn) |cb| cb();
        }
    }

    // Activity destroyed — make sure bgfx is torn down.
    if (bgfx_ready) {
        window.closeWindow();
        bgfx_ready = false;
    }
}

// On Android, export the glue entry. The glue's C file declares
// `extern void android_main(struct android_app* app)` and calls it on the
// app thread; this `export` provides that symbol. Off Android the symbol
// is omitted entirely so desktop links are untouched.
//
// Skipped when the game owns `android_main` (`game_owns_main`): the
// generated game's entry registers the init/tick callbacks then calls
// `run(app)`, so emitting a second `android_main` here would be a
// duplicate-symbol link error. The backend's own Android compile-check
// has no game root, so `game_owns_main` is false there and this export
// fires — keeping the existing phase-3 self-test green.
comptime {
    if (is_android and !game_owns_main) {
        @export(&androidMainExport, .{ .name = "android_main", .linkage = .strong });
    }
}

/// Native-activity accessor (#310 Stage 4). Returns the running
/// `ANativeActivity*` the glue handed us (stashed in `run`), or null before
/// it exists. Surfaced both as this Zig accessor and as the C-ABI export
/// below; the bgfx Android backend adapter (`android.zig`) binds the C symbol
/// to populate core's `AndroidBackendContext.get_native_activity`.
pub fn getNativeActivity() ?*anyopaque {
    return @ptrCast(native_activity);
}

/// C-ABI accessor the bgfx Android backend adapter binds `extern "c"` (see
/// the `native_activity` block above for why this is a C symbol and not a Zig
/// import). Strong export so it survives dead-stripping and resolves the
/// adapter's undefined ref in the final `.so` link. Android-only — emitted in
/// the `comptime` block below.
fn getNativeActivityC() callconv(.c) ?*anyopaque {
    return @ptrCast(native_activity);
}

comptime {
    if (is_android) {
        @export(&getNativeActivityC, .{ .name = "labelle_bgfx_get_native_activity", .linkage = .strong });
    }
}

fn androidMainExport(app: *android_app) callconv(.c) void {
    run(app);
}

// ── Compile-check coverage ──────────────────────────────────────────
// Force-reference the entry/handlers so a build that imports this module
// (e.g. the Android object compile-check in build.zig) instantiates them
// and catches ABI/signature breakage even though nothing calls them yet
// (the real caller is the glue at runtime — phase 4).
comptime {
    _ = run;
    _ = onAppCmd;
    _ = onInputEvent;
    _ = setTickCallback;
    _ = setInitCallback;
    _ = setSurfaceLostCallback;
    _ = setSurfaceRestoredCallback;
    _ = getNativeActivity;
    _ = setImmersiveCallback;
    _ = &focusHook;
}

test "android_app module compiles for the host as a no-op namespace" {
    // On the host `is_android` is false, so the export is elided and this
    // is just a smoke test that the module type-checks off-Android.
    const testing = @import("std").testing;
    try testing.expect(!is_android or is_android);
}
