//! bgfx Android backend adapter for labelle-core's backend-agnostic JNI seam
//! (labelle-core#310, Stage 4).
//!
//! ## Why this exists
//!
//! Core's Android gamepad source (`gamepad_source/android.zig`) and the
//! engine's `enableImmersiveMode()` route their Android JNI calls through an
//! `AndroidBackendContext` vtable that the active backend **registers at
//! startup** (`labelle-core/src/android_backend.zig`, Stage 1). Whichever
//! backend is live must register one, or core does nothing on Android (no
//! immersive mode, no gamepad detection).
//!
//! This is the bgfx-side adapter — the exact analog of
//! `backends/sokol/src/android.zig`. It builds the `AndroidBackendContext`
//! literal from the bgfx Android backend's own symbols:
//!
//!   * `get_native_activity` → a `callconv(.c)` accessor for the running
//!     `ANativeActivity*`. The bgfx NativeActivity shell
//!     (`android_app.zig`) owns that pointer (the native_app_glue hands it
//!     over as `app.activity`); the shell `@export`s it as the C symbol
//!     `labelle_bgfx_get_native_activity`, which this adapter declares
//!     `extern "c"`. A C symbol (rather than a Zig import of `android_app`)
//!     deliberately avoids a module cycle: the shell module imports `input`
//!     (this module's package), so `input` cannot import the shell back.
//!     This mirrors how the sokol adapter reaches sokol_app's
//!     `sapp_android_get_native_activity()` across a C-ABI boundary.
//!   * `gamepad_init` / `gamepad_shutdown` → the backend-agnostic JNI glue
//!     (`android_gamepad_jni.c`, in the shared `../android_gamepad`
//!     sub-package), declared `extern "c"` here and compiled into this
//!     (`input`) module's graph by `build.zig`. No-op off Android.
//!
//! ## Wiring
//!
//! The generated bgfx-Android `main.zig` calls
//! `engine.core.registerAndroidBackend(@import("backend_input").android.backendContext())`
//! ONCE at startup, from inside the shell's `init` callback — before the
//! gamepad source first polls (assembler codegen, `lifecycle/callback.zig`).
//!
//! ## Gating
//!
//! Everything is gated behind `is_android`; the re-export from `input.zig` is
//! Android-only, so non-Android bgfx builds never construct this and reference
//! no Android symbol.

const builtin = @import("builtin");
const core = @import("labelle-core");

/// True on Android. Mirrors `input.zig`'s `is_android` and the shared
/// `android_gamepad` state module's check.
pub const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

// JNI detection glue (shared `../android_gamepad/src/android_gamepad_jni.c`).
// The C signatures are:
//   void labelle_android_gamepad_init(const void *activity_ptr);
//   void labelle_android_gamepad_shutdown(void);
// Defined as no-ops off Android, so declaring them is safe everywhere — but we
// only ever wire them into a registered context on Android. `extern "c"`
// already implies the C calling convention.
extern "c" fn labelle_android_gamepad_init(activity: ?*anyopaque) void;
extern "c" fn labelle_android_gamepad_shutdown() void;

// The bgfx NativeActivity shell (`android_app.zig`) exports this C symbol; it
// returns the running `ANativeActivity*` the native_app_glue stashed (or null
// before the activity exists). Declared `extern "c"` to dodge a module cycle
// (the shell imports `input`, so `input` can't import the shell).
extern "c" fn labelle_bgfx_get_native_activity() ?*anyopaque;

/// `callconv(.c)` adapter for the seam's `get_native_activity`. Returns the
/// shell's stored activity. Core only hands this pointer straight back into
/// `gamepad_init` (which re-`const`s it on the C side) and the engine's
/// immersive helper, so it is sound. Returns `null` before the glue has handed
/// the shell a running activity (core treats `null` as "nothing to bind").
fn getNativeActivity() callconv(.c) ?*anyopaque {
    return labelle_bgfx_get_native_activity();
}

/// Build the `AndroidBackendContext` the bgfx backend hands to core. Referenced
/// only from the generated bgfx-Android `main.zig` (via
/// `@import("backend_input").android.backendContext()`); core then routes its
/// Android JNI calls (immersive-mode activity lookup + gamepad enumeration)
/// through these pointers. See the module header for the lifecycle contract.
pub fn backendContext() core.AndroidBackendContext {
    return .{
        .get_native_activity = &getNativeActivity,
        .gamepad_init = &labelle_android_gamepad_init,
        .gamepad_shutdown = &labelle_android_gamepad_shutdown,
    };
}
