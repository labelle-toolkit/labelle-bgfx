/// bgfx Android app shell — the NativeActivity glue entry point.
///
/// sokol hides this inside `sokol_app`; the bgfx backend has no equivalent,
/// so this module is the hand-rolled analog. It is built on the NDK's
/// `android_native_app_glue` (compiled into the Android build by
/// `build.zig`, Android-gated). The glue spins up a dedicated thread, sets
/// up an `ALooper`, and calls our `android_main(app)` — from there we drive:
///
///   * the activity lifecycle (`APP_CMD_*`): create/destroy the bgfx
///     surface on `INIT_WINDOW`/`TERM_WINDOW`, reconcile the backbuffer on
///     the in-place geometry commands (`WINDOW_RESIZED`/`CONFIG_CHANGED`/
///     `CONTENT_RECT_CHANGED`, labelle-bgfx#66), honor resume/pause, and
///     translate `app.destroyRequested` into `window.shouldQuit`.
///   * touch input (`AInputEvent`/`AMotionEvent_*`, handled in
///     `android_input_event.zig`): fed into `input.zig` as pointer-down +
///     x/y so the engine sees touch as mouse-like pointer input (mirrors
///     the desktop mouse path).
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
// The `AInputEvent` handler (touch + gamepad) lives in its own file.
const onInputEvent = @import("android_input_event.zig").onInputEvent;
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
    /// `JavaVM* vm` — handed to the JNI helper that reads this process's own
    /// `ApplicationInfo.FLAG_DEBUGGABLE` (see `isDebuggable`).
    vm: ?*anyopaque,
    /// `JNIEnv* env` — the UI thread's env. Deliberately untyped and unused:
    /// `android_main` runs on the glue's own thread, where this env is NOT
    /// valid; the helper attaches its own.
    _env: ?*anyopaque,
    /// `jobject clazz` — the NativeActivity's own Java object, the receiver
    /// for the `getApplicationInfo()` call in `isDebuggable`.
    clazz: ?*anyopaque,
    /// `const char* internalDataPath` — the app's OWN private directory
    /// (`/data/data/<package>/files`). The only filesystem location a
    /// NativeActivity can always write to, and the one `run-as <package> cat`
    /// / `adb pull` can read back on a debuggable build.
    internal_data_path: ?[*:0]const u8,
    /// `const char* externalDataPath` — unused.
    _external_data_path: ?*anyopaque,
    /// `int32_t sdkVersion` plus its padding: one pointer slot on both LP64
    /// and ILP32. Unused.
    _sdk_version: ?*anyopaque,
    /// `void* instance` — native_app_glue stores this activity's
    /// `struct android_app` here. Lets the UI-thread focus hook find its own
    /// activity's window (#143).
    instance: ?*anyopaque,
    /// `assetManager`, `obbPath` — unused.
    _tail: [2]?*anyopaque,
};

comptime {
    // The struct is only ever used through a pointer the framework gives us,
    // so a layout drift would read the wrong field silently. Pin the size to
    // the NDK header's 10 slots, and the one tail field we read. (The size
    // pinned here used to be 12: two phantom tail slots that nothing read,
    // so it never mattered until `instance` was needed.)
    const slot = @sizeOf(?*anyopaque);
    if (@sizeOf(ANativeActivity) != 10 * slot or @offsetOf(ANativeActivity, "instance") != 7 * slot) {
        @compileError("ANativeActivity layout drifted");
    }
}

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

// ── NDK / glue functions we call ────────────────────────────────────
// Declared `extern` so the linker resolves them from the glue
// (`android_app_*`) and libandroid (`ANativeWindow_*`, `ALooper_*`; the
// `AInputEvent_*` ones sit with the handler in `android_input_event.zig`).
// The link of these libs is phase 4 — here we only need them declared so
// the module compiles; the object is produced without a final link.
extern fn ALooper_pollOnce(timeoutMillis: c_int, outFd: ?*c_int, outEvents: ?*c_int, outData: ?*?*anyopaque) c_int;

extern fn ANativeWindow_getWidth(window: *ANativeWindow) i32;
extern fn ANativeWindow_getHeight(window: *ANativeWindow) i32;

// `<android/configuration.h>` — the density bucket in dpi (160, 240, 320,
// 420, 480, 560, 640…). 160 is Android's `dp` baseline, so `density / 160`
// is the normalized UI scale (a 320dpi phone → 2.0, the 213dpi P42 → ~1.33).
// Linked from libandroid, same as the input/window symbols above.
extern fn AConfiguration_getDensity(config: *AConfiguration) i32;
// Two distinct "no usable density" sentinels, and BOTH have to be rejected:
// they are ordinary positive i32 values, so a `> 0` test lets them through
// and `density / 160` then yields ~409, not the 1.0 a caller expects.
const ACONFIGURATION_DENSITY_ANY: i32 = 0xfffe;
const ACONFIGURATION_DENSITY_NONE: i32 = 0xffff;

extern fn ALooper_wake(looper: *ALooper) void;

// ── Shell state (per activity instance) ─────────────────────────────
// One `Shell` per `run()`, i.e. per activity instance, reached from the
// glue callbacks through `app.userData`. It used to be process globals,
// which assumed one activity per process: a second instance started in
// the same process (labelle-bgfx#143) then saw the first one's "bgfx is up"
// and ticked a frame on its own thread, straight into bgfx's
// "Must be called from main thread" assert.
//
// `bgfx_ready` guards the per-frame tick: this instance owns bgfx and it is
// initialized against its surface. `is_resumed` honors the activity
// pause/resume lifecycle — when paused we keep pumping events but skip
// rendering. `waiting_logged` keeps the "waiting for handoff" line to once
// per wait.
const Shell = struct {
    gen: u64,
    bgfx_ready: bool = false,
    is_resumed: bool = false,
    waiting_logged: bool = false,
    /// Blocked until woken by `wakeParkedLocked` rather than polling.
    parked: bool = false,
};

fn shellOf(app: *android_app) *Shell {
    return @ptrCast(@alignCast(app.userData.?));
}

// ── bgfx ownership across activity instances (labelle-bgfx#143) ─────
// bgfx is one per process and thread-affine; see `android_bgfx_owner.zig`
// for the rules. Every arbiter call happens under `owner_mutex`, which is
// taken from the app threads of every live instance and, via `focusHook`,
// the UI thread. It is never held across a bgfx init or teardown.
const Arbiter = @import("android_bgfx_owner.zig").Arbiter(*android_app);
var owner_mutex: std.c.pthread_mutex_t = .{};
var arbiter: Arbiter = .{};

fn lockOwner() void {
    _ = std.c.pthread_mutex_lock(&owner_mutex);
}

fn unlockOwner() void {
    _ = std.c.pthread_mutex_unlock(&owner_mutex);
}

/// While waiting for another instance to hand bgfx over, poll this often (ms)
/// instead of blocking: the handoff is signalled by the other thread's state,
/// not by an event on this looper.
const handoff_poll_ms: c_int = 16;

/// Instances that must wait for a NEWER owner (`Claim.wait`). They block in
/// `ALooper_pollOnce(-1)` instead of polling and are woken when bgfx is
/// released or a reservation is dropped, so a long-lived older activity
/// costs nothing while it waits. Guarded by `owner_mutex`; an instance
/// unparks itself before its `run()` returns, so every looper woken here is
/// alive. More waiters than slots fall back to polling.
var parked: [8]?*android_app = @splat(null);

fn parkLocked(app: *android_app) bool {
    for (&parked) |*slot| if (slot.* == app) return true;
    for (&parked) |*slot| if (slot.* == null) {
        slot.* = app;
        return true;
    };
    return false;
}

fn unparkLocked(app: *android_app) void {
    for (&parked) |*slot| if (slot.* == app) {
        slot.* = null;
    };
}

/// bgfx (or a reservation on it) became free: let every parked instance
/// retry its claim. They re-park if they still have to wait.
fn wakeParkedLocked() void {
    for (&parked) |*slot| if (slot.*) |app| {
        if (app.looper) |looper| ALooper_wake(looper);
        slot.* = null;
    };
}

/// Point the process-wide accessors (`native_activity`, `app_ptr`) at `app`.
/// Every write to them happens under `owner_mutex` (this and the clear at the
/// end of `run`), so an exiting instance's "is it still mine? then clear"
/// cannot interleave with a new owner's adoption and wipe it.
fn adoptAccessorsLocked(app: *android_app) void {
    @atomicStore(?*ANativeActivity, &native_activity, app.activity, .release);
    @atomicStore(?*android_app, &app_ptr, app, .release);
}

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

/// The activity whose focus change `focusHook` is handling, while it runs the
/// immersive callback. Thread-local: only that UI-thread call sees it.
threadlocal var focus_activity: ?*ANativeActivity = null;

/// The NDK glue's original `onWindowFocusChanged`, saved so `focusHook`
/// can forward to it. Set in `run()` before `focusHook` is installed.
var glue_focus_cb: ?*const fn (*ANativeActivity, c_int) callconv(.c) void = null;
/// UI-thread half of the stuck-surface recovery (labelle-bgfx#127):
/// `src/android_window_relayout.c`.
extern "c" fn labelle_bgfx_force_window_relayout(vm: ?*anyopaque, clazz: ?*anyopaque) c_int;

/// Our chained `onWindowFocusChanged`. Runs on the UI thread, so the
/// engine's `WindowInsetsController.hide()` (driven via `immersive_cb`)
/// and the #127 relayout are thread-legal here. Forward to the glue first
/// so its lifecycle bookkeeping is intact, then re-hide on focus gain.
fn focusHook(activity: *ANativeActivity, has_focus: c_int) callconv(.c) void {
    if (glue_focus_cb) |cb| cb(activity, has_focus);
    if (has_focus != 0) {
        // The immersive callback finds its activity through
        // `labelle_bgfx_get_native_activity`, which normally answers the bgfx
        // owner. A newly focused activity may still be waiting for the
        // handoff (#143), so answer with THIS activity for the duration of
        // the callback; it runs synchronously, on this thread.
        focus_activity = activity;
        defer focus_activity = null;
        if (immersive_cb) |cb| cb();
        recoverDegenerateWindow(activity);
    }
}

/// A restored window can come back 1x1 and never receive its resize
/// (labelle-bgfx#127): the game then renders into one pixel stretched over the
/// screen until the next surface cycle. Focus gain follows INIT_WINDOW on
/// resume and runs on the UI thread, the only thread allowed to make the
/// window relayout, so it is where a degenerate surface gets fixed. The
/// resulting APP_CMD_WINDOW_RESIZED is reconciled by the usual path.
///
/// The window checked is THIS activity's own (`activity.instance` is its
/// glue `android_app`), whether or not it owns bgfx yet: with two instances
/// alive (#143) the new one gains focus while it is still waiting for the
/// handoff, and this is its only chance to get the relayout. bgfx is then
/// brought up against the live size when the handoff lands. The window
/// pointer stays valid for this read: the glue writes it on the app thread,
/// but the window is destroyed from the UI thread itself
/// (onNativeWindowDestroyed), the thread we are on.
fn recoverDegenerateWindow(activity: *ANativeActivity) void {
    const instance = activity.instance orelse return;
    const app: *android_app = @ptrCast(@alignCast(instance));
    const w = @atomicLoad(?*ANativeWindow, &app.window, .acquire) orelse return;
    const size = [2]i32{ ANativeWindow_getWidth(w), ANativeWindow_getHeight(w) };
    if (!window.isDegenerateSurface(size)) return;
    const ok = labelle_bgfx_force_window_relayout(activity.vm, activity.clazz) != 0;
    std.log.info("bgfx: restored window is {d}x{d}; forcing a relayout (#127): {s}", .{ size[0], size[1], if (ok) "requested" else "JNI failed" });
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
///
/// With several activity instances alive (#143) these follow the bgfx
/// OWNER (`adoptAccessors`, on grant), since it is the owner's thread that
/// runs the engine. Before any instance owns bgfx they point at the first
/// instance to start, so `isDebuggable`/`internalDataPath` work early.
/// Accessed atomically: the UI thread and other instances read them.
var native_activity: ?*ANativeActivity = null;

// Stashed from `run` so `labelle_bgfx_display_scale` can read the live
// `app.config` (density can change — external display, fold). Same
// C-symbol-bridge shape as `native_activity`, so `window.zig` reaches the
// density without importing this shell module (which would cycle: the shell
// imports `input`, and `window` imports `input`).
var app_ptr: ?*android_app = null;

/// Normalized display scale on Android: the density bucket / 160 (Android's
/// `dp` baseline). Exported as a C symbol so `window.displayScale()` can bind
/// it `extern "c"`. Returns 1.0 before `run` has stashed the app or if the
/// density is unknown, so callers always get a sane factor.
///
/// "Unknown" is TWO sentinels, `DENSITY_ANY` (0xfffe) and `DENSITY_NONE`
/// (0xffff). Guarding only `NONE` let `ANY` through as a real bucket and
/// returned ~409.59 — the consumer's viewport cap hides that on a short
/// screen (it takes the min of density and height/reference), but a tall
/// one would jump straight to the maximum scale.
export fn labelle_bgfx_display_scale() callconv(.c) f32 {
    const app = @atomicLoad(?*android_app, &app_ptr, .acquire) orelse return 1.0;
    const config = app.config orelse return 1.0;
    const density = AConfiguration_getDensity(config);
    if (density <= 0 or density == ACONFIGURATION_DENSITY_ANY or density == ACONFIGURATION_DENSITY_NONE) return 1.0;
    return @as(f32, @floatFromInt(density)) / 160.0;
}

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
///
/// Once per PROCESS, not per activity instance (#143). The generated
/// `main.zig` keeps the game in a process global and never deinits it, so
/// a later activity in the same process — concurrent with the old one, or
/// relaunched into a cached process after the old one was destroyed — finds
/// the engine alive and restores it. This used to be reset on
/// APP_CMD_DESTROY, which made that later activity run `init_fn` again over
/// the live game: a second `AssembledGame.init` over the first, whose asset
/// worker thread was still running, SIGSEGV'd in `SpscRing.tryDequeue` on
/// the overwritten memory.
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

// ── bgfx bring-up / teardown, gated on ownership (#143) ─────────────

/// Bring bgfx up against this instance's window if it may own it. Called on
/// INIT_WINDOW and, while another instance still holds bgfx, retried every
/// loop iteration until the handoff lands. Only ever runs on `app`'s own
/// thread, which becomes bgfx's API thread.
fn acquireBgfx(app: *android_app, shell: *Shell) void {
    if (shell.bgfx_ready) return;
    const w = app.window orelse return;

    lockOwner();
    const claim = arbiter.claim(app, shell.gen);
    // Wake the owner so it notices the request even while it is paused and
    // blocked in `ALooper_pollOnce(-1)`. Under the lock: the owner releases
    // (under the same lock) before its `run()` returns, so its looper is
    // still alive here.
    if (claim == .requested_yield) {
        if (arbiter.owner.?.looper) |looper| ALooper_wake(looper);
    }
    // Waiting on a NEWER owner can take arbitrarily long: park instead of
    // polling. Waiting on an older owner's handoff polls (it is short).
    if (claim == .wait) {
        shell.parked = parkLocked(app);
    } else {
        unparkLocked(app);
        shell.parked = false;
    }
    // The engine runs on the owner's thread: its JNI / density seams follow.
    if (claim == .granted or claim == .already_owner) adoptAccessorsLocked(app);
    unlockOwner();

    switch (claim) {
        // `already_owner` without `bgfx_ready` cannot happen (the two change
        // together); should it ever, bringing bgfx up is still correct.
        .granted, .already_owner => {},
        .requested_yield, .wait => {
            if (!shell.waiting_logged) {
                shell.waiting_logged = true;
                if (claim == .requested_yield)
                    std.log.info("bgfx: an older activity instance still owns bgfx; waiting for it to hand over (#143)", .{})
                else
                    std.log.info("bgfx: a newer activity instance owns bgfx; this one stays dark (#143)", .{});
            }
            return;
        },
    }
    shell.waiting_logged = false;

    // Hand the window module this instance's ANativeWindow and bring bgfx
    // up against it.
    window.setAndroidNativeWindow(@ptrCast(w));
    const width = ANativeWindow_getWidth(w);
    const height = ANativeWindow_getHeight(w);
    const ww: i32 = if (width > 0) width else default_width;
    const wh: i32 = if (height > 0) height else default_height;
    // Always the NEW window's size — never the dims cached before a
    // TERM_WINDOW: a resume can come back in the other orientation,
    // and the fit/projection are derived from `window.width()/
    // height()` every frame, so trusting the old geometry here
    // would stretch the first restored frames (#66).
    window.initWindow(ww, wh, "labelle");
    shell.bgfx_ready = true;
    std.log.info("bgfx: INIT_WINDOW surface {d}x{d}", .{ ww, wh });

    // Cold init vs. surface restore (#386 Phase 4). The very
    // first INIT_WINDOW runs the game's one-shot engine/scene
    // init (`init_fn`) — engine state is built once and survives
    // every later TERM/INIT cycle. A LATER INIT_WINDOW (resume
    // after backgrounding) re-creates the bgfx surface against a
    // brand-new context; the engine must rebuild its GPU catalog
    // (sprites), so we fire `surface_restored_fn` instead.
    // surfaceRestored therefore fires ONLY in the `else` — never
    // on the first window. A later activity instance in the same
    // process (#143) is a restore too: the engine state is
    // process-wide (see `init_done`) and the previous owner fired
    // `surface_lost_fn` when it let go of bgfx.
    if (!init_done) {
        init_done = true;
        if (init_fn) |cb| cb();
        std.log.info("bgfx: first surface (cold init)", .{});
    } else {
        if (surface_restored_fn) |cb| cb();
        std.log.info("bgfx: re-init against new surface (restore)", .{});
    }
}

/// Tear bgfx down on this (owning) instance's thread and give up ownership.
///
/// Ordering is LOAD-BEARING: notify the engine FIRST (`surface_lost_fn`) so
/// it forgets its catalog handles while they're still nominally valid, THEN
/// tear bgfx down (`teardownSurface` = shutdownPrograms-then-shutdown), THEN
/// drop the native handle so a later INIT_WINDOW re-inits cleanly — in this
/// instance or the next one. The engine outlives every activity instance
/// (see `init_done`), so every release is followed by a restore, and the
/// engine is always told.
fn releaseBgfx(app: *android_app, shell: *Shell) void {
    if (!shell.bgfx_ready) return;
    if (surface_lost_fn) |cb| cb();
    window.teardownSurface();
    window.setAndroidNativeWindow(null);
    shell.bgfx_ready = false;
    lockOwner();
    arbiter.release(app);
    wakeParkedLocked();
    unlockOwner();
}

// ── Lifecycle: APP_CMD_* handler ────────────────────────────────────
fn onAppCmd(app: *android_app, cmd: i32) callconv(.c) void {
    const shell = shellOf(app);
    switch (cmd) {
        APP_CMD_INIT_WINDOW => {
            // A new ANativeWindow is ready. Bring bgfx up against it, or,
            // if a previous activity instance in this process still holds
            // bgfx, ask it to hand over; `run` retries until it has (#143).
            acquireBgfx(app, shell);
        },
        APP_CMD_TERM_WINDOW => {
            // The surface is going away — bgfx destroys the GPU context AND
            // every texture/shader (see `releaseBgfx` for the ordering). An
            // instance that does not own bgfx has nothing to tear down and
            // must NOT touch the window module: that state is the owner's.
            if (shell.bgfx_ready) {
                releaseBgfx(app, shell);
                std.log.info("bgfx: shutdownPrograms + bgfx.shutdown (surface lost)", .{});
            }
            // No window, no claim: drop any reservation made while waiting.
            lockOwner();
            arbiter.withdraw(app);
            unparkLocked(app);
            wakeParkedLocked();
            unlockOwner();
            shell.parked = false;
            shell.waiting_logged = false;
        },
        // In-place surface geometry changes (labelle-bgfx#66). A rotation under
        // `sensorLandscape`, a resume that lands in the other orientation, or a
        // multi-window/fold change can resize the ANativeWindow WITHOUT a
        // TERM/INIT pair. Which of these three the framework delivers — and
        // whether `WINDOW_RESIZED` comes at all — varies by OS version, so
        // treat them uniformly: hand the window module the chance to
        // re-read the live size and `bgfx.reset` through its ONE reconcile
        // path (`ensureSurface`, the same one desktop resizes take). Often a
        // no-op because `CONFIG_CHANGED` precedes the actual resize; the
        // per-frame poll in `window.framebufferSize` is the safety net that
        // makes the outcome independent of which command showed up. Only
        // while bgfx is up — with no surface there is nothing to reconcile.
        APP_CMD_WINDOW_RESIZED, APP_CMD_CONFIG_CHANGED, APP_CMD_CONTENT_RECT_CHANGED => {
            if (shell.bgfx_ready) window.reconcileSurface(switch (cmd) {
                APP_CMD_WINDOW_RESIZED => "APP_CMD_WINDOW_RESIZED",
                APP_CMD_CONFIG_CHANGED => "APP_CMD_CONFIG_CHANGED",
                else => "APP_CMD_CONTENT_RECT_CHANGED",
            });
        },
        APP_CMD_GAINED_FOCUS, APP_CMD_RESUME, APP_CMD_START => {
            shell.is_resumed = true;
            // Immersive re-hide is NOT driven from here: it must run on the
            // UI thread, and this handler runs on the glue's app thread. The
            // re-hide is driven by `focusHook` (chained onWindowFocusChanged),
            // which the framework invokes on the UI thread on focus gain.
        },
        APP_CMD_LOST_FOCUS, APP_CMD_PAUSE, APP_CMD_STOP => {
            shell.is_resumed = false;
        },
        APP_CMD_DESTROY => {
            // Surface should already be gone via TERM_WINDOW; be defensive.
            // Same order as the surface-lost path, `surface_lost_fn`
            // included: the engine survives this activity and the next one
            // restores it. `init_done` is deliberately NOT reset here (#143,
            // see its declaration).
            releaseBgfx(app, shell);
            shell.is_resumed = false;
        },
        else => {},
    }
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
    // This instance's shell state lives on this frame for the whole of
    // `run()`; the glue callbacks reach it through `app.userData`.
    lockOwner();
    var shell: Shell = .{ .gen = arbiter.begin() };
    unlockOwner();
    app.userData = &shell;
    app.onAppCmd = onAppCmd;
    app.onInputEvent = onInputEvent;

    // Stash the activity for the backend-seam accessor the engine's
    // immersive-mode helper calls (see `native_activity` above), and the
    // app itself so `labelle_bgfx_display_scale` can read the live
    // `app.config` density. The glue has populated `app.activity` by the
    // time it calls us. Only when unset: an instance that owns bgfx keeps
    // them until it lets go (#143); this one adopts them when it gets bgfx.
    lockOwner();
    if (app_ptr == null) adoptAccessorsLocked(app);
    unlockOwner();

    // Launch-intent extras → env vars (labelle-bgfx#139), BEFORE the loop: the
    // game's first `getenv` of a run option is in `init_fn` (engine + scene
    // init, fired on the first INIT_WINDOW, which only this loop can deliver),
    // so everything read from there on sees the copied values. Needs
    // `native_activity`, stashed just above, for the debuggable gate.
    if (app.activity) |activity| applyLaunchIntentEnv(activity);

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
        //   - waiting for an older instance to hand bgfx over (#143) →
        //     `handoff_poll_ms`, so the retry below runs without an event.
        //     Waiting on a NEWER owner parks instead (-1 until woken).
        // No early break — processing only one event per frame (the prior
        // bug) caps input throughput and adds latency.
        while (ALooper_pollOnce(
            if (shell.bgfx_ready and shell.is_resumed)
                0
            else if (!shell.bgfx_ready and app.window != null and !shell.parked)
                handoff_poll_ms
            else
                -1,
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

        // bgfx handoff between activity instances (#143). A newer instance
        // with a window asked for bgfx: tear it down HERE, on the thread
        // that is bgfx's API thread, and let the engine drop its GPU
        // catalog — the new owner restores it.
        if (shell.bgfx_ready) {
            lockOwner();
            const yield = arbiter.shouldYield(app);
            unlockOwner();
            if (yield) {
                releaseBgfx(app, &shell);
                std.log.info("bgfx: handed bgfx over to a newer activity instance (#143)", .{});
            }
        } else if (app.window != null) {
            // We have a window but no bgfx: an older instance is still
            // handing it over (or we just yielded to a newer one). Retry.
            acquireBgfx(app, &shell);
        }

        // Per-frame tick: only when the surface exists, bgfx is up, and
        // the activity is in the foreground.
        if (shell.bgfx_ready and shell.is_resumed) {
            if (tick_fn) |cb| cb();
        }
    }

    // Activity destroyed — make sure bgfx is torn down (on this thread, the
    // only one allowed to) and forget this instance before its glue state
    // and looper go away.
    releaseBgfx(app, &shell);
    lockOwner();
    arbiter.end(app);
    unparkLocked(app);
    if (app_ptr == app) {
        @atomicStore(?*ANativeActivity, &native_activity, null, .release);
        @atomicStore(?*android_app, &app_ptr, null, .release);
    }
    wakeParkedLocked();
    unlockOwner();
    app.userData = null;
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
    return getNativeActivityC();
}

/// The app's private internal data directory (`/data/data/<package>/files`),
/// or null before the activity exists (labelle-assembler#737).
///
/// Exists so the generated `main.zig` can resolve a RELATIVE
/// `LABELLE_SCREENSHOT_PATH` against a directory the process can actually
/// write. A NativeActivity has no usable cwd and no write access to
/// `/data/local/tmp`, and the Android property that carries the environment
/// (`wrap.<package>`, the only channel into a debuggable app) caps its value
/// at 92 bytes — an absolute path to this directory alone eats two thirds of
/// that. Relative paths keep the knob short and land the capture exactly where
/// `run-as <package> cat files/<name>` can fetch it.
pub fn internalDataPath() ?[*:0]const u8 {
    const activity = @atomicLoad(?*ANativeActivity, &native_activity, .acquire) orelse return null;
    return activity.internal_data_path;
}

/// JNI side of `isDebuggable` — `src/android_debuggable.c`, compiled into this
/// module on Android and an empty TU everywhere else. Declared unconditionally
/// (extern decls are only linked when referenced) so the non-Android path below
/// folds away without a comptime block around the declaration.
extern "c" fn labelle_bgfx_app_is_debuggable(vm: ?*anyopaque, clazz: ?*anyopaque) c_int;

/// Cache: the flag cannot change for the life of the process, and the query is
/// a JNI attach + four lookups. `null` = not asked yet.
var is_debuggable_cached: ?bool = null;

/// Is the RUNNING apk marked `android:debuggable`? (labelle-assembler#737)
///
/// This gates the `labelle_env` knob-file channel. `adb shell run-as
/// <package>` — the only way to CREATE that file — is granted only for a
/// debuggable APK, but `run-as` says nothing about the runtime READ: install a
/// debuggable build, drop a knob file, then update to a release build, and the
/// file is still sitting there and would still be honoured. Asking the process
/// about its own `ApplicationInfo.FLAG_DEBUGGABLE` closes that, so a release
/// build ignores a stale file.
///
/// Fails CLOSED: no activity, no VM, or any JNI failure answers `false`. A
/// verification aid that cannot prove it is allowed must stay off.
pub fn isDebuggable() bool {
    // `comptime` so the extern is not even referenced off Android, where the C
    // TU compiles to an empty object and the symbol does not exist.
    if (comptime !is_android) return false;
    if (is_debuggable_cached) |cached| return cached;
    const activity = @atomicLoad(?*ANativeActivity, &native_activity, .acquire) orelse return false; // not cached: asked too early
    const result = labelle_bgfx_app_is_debuggable(activity.vm, activity.clazz) != 0;
    is_debuggable_cached = result;
    return result;
}

// ── Launch-intent extras → env vars (labelle-bgfx#139) ──────────────
// `labelle run --platform=android --scene=X` launches with `am start ...
// --es LABELLE_SCENE X` (labelle-cli#397); the allow-list and the per-key
// decision live in `android_intent_env.zig` (host-tested), the JNI read in
// `src/android_intent_extras.c`.
const intent_env = @import("android_intent_env.zig");

extern "c" fn labelle_bgfx_read_intent_extras(
    vm: ?*anyopaque,
    clazz: ?*anyopaque,
    keys: [*]const [*:0]const u8,
    count: c_int,
    buf: [*]u8,
    buf_cap: usize,
    lens: [*]c_int,
) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Survives activity relaunches in a cached process, so a plain launch can
/// clear what a previous `--scene` launch set (see `intent_env.action`).
var intent_env_state: intent_env.State = .{};
/// Backing store for the extras' values. setenv copies them, so it is only
/// needed for the duration of `applyLaunchIntentEnv`.
var intent_buf: [4096]u8 = undefined;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const LibcEnv = struct {
    pub fn get(_: LibcEnv, name: [:0]const u8) ?[:0]const u8 {
        return if (getenv(name.ptr)) |v| std.mem.span(v) else null;
    }
    pub fn set(_: LibcEnv, name: [:0]const u8, value: [:0]const u8) bool {
        return setenv(name.ptr, value.ptr, 1) == 0;
    }
    pub fn unset(_: LibcEnv, name: [:0]const u8) void {
        _ = unsetenv(name.ptr);
    }
    pub fn debuggable(_: LibcEnv) bool {
        return isDebuggable();
    }
};

/// Copy the launch intent's allow-listed `LABELLE_*` string extras into the
/// process environment. A launch with no extras (the launcher icon) or any
/// JNI failure changes nothing, except clearing values a previous intent set.
fn applyLaunchIntentEnv(activity: *ANativeActivity) void {
    if (comptime !is_android) return;
    var names: [intent_env.keys.len][*:0]const u8 = undefined;
    for (intent_env.keys, 0..) |k, i| names[i] = k.name.ptr;
    var lens: [intent_env.keys.len]c_int = undefined;
    if (labelle_bgfx_read_intent_extras(activity.vm, activity.clazz, &names, names.len, &intent_buf, intent_buf.len, &lens) == 0) {
        std.log.warn("bgfx: could not read the launch intent; LABELLE_* extras ignored", .{});
        return;
    }
    var extras: [intent_env.keys.len]?[:0]const u8 = @splat(null);
    var off: usize = 0;
    for (lens, 0..) |len, i| {
        if (len == -2) std.log.warn("bgfx: intent extra {s} too long or contains a NUL; ignored", .{intent_env.keys[i].name});
        if (len < 0) continue;
        const n: usize = @intCast(len);
        extras[i] = intent_buf[off .. off + n :0];
        off += n + 1;
    }
    intent_env.apply(&intent_env_state, extras, LibcEnv{});
}

/// C-ABI accessor the bgfx Android backend adapter binds `extern "c"` (see
/// the `native_activity` block above for why this is a C symbol and not a Zig
/// import). Strong export so it survives dead-stripping and resolves the
/// adapter's undefined ref in the final `.so` link. Android-only — emitted in
/// the `comptime` block below.
fn getNativeActivityC() callconv(.c) ?*anyopaque {
    if (focus_activity) |activity| return @ptrCast(activity); // see `focusHook`
    return @ptrCast(@atomicLoad(?*ANativeActivity, &native_activity, .acquire));
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
    _ = applyLaunchIntentEnv;
}

test "android_app module compiles for the host as a no-op namespace" {
    // On the host `is_android` is false, so the export is elided and this
    // is just a smoke test that the module type-checks off-Android.
    const testing = @import("std").testing;
    try testing.expect(!is_android or is_android);
}
