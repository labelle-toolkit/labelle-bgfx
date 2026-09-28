/// NativeActivity input: the `AInputEvent` handler the bgfx Android shell
/// (`android_app.zig`) installs as `app.onInputEvent`. Split out of the shell
/// so the lifecycle file stays readable; it is part of the same `android_app`
/// module, so the `input` named import resolves here too.
const input = @import("input");
const shell = @import("android_app.zig");

const android_app = shell.android_app;
const AInputEvent = shell.AInputEvent;

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
// The lifting pointer's index for a POINTER_UP is packed into the high byte of
// the raw (unmasked) action.
const AMOTION_EVENT_ACTION_POINTER_INDEX_MASK: i32 = 0xff00;
const AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT: u5 = 8;

// ── NDK input functions (libandroid) ────────────────────────────────
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
pub fn onInputEvent(app: *android_app, event: *AInputEvent) callconv(.c) c_int {
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

    // Feed the FULL multi-touch set for the camera's pinch-zoom / two-finger /
    // one-finger-pan gestures (additive to the single-pointer mouse emulation
    // below). On UP/CANCEL every finger is gone; on POINTER_UP the lifting
    // pointer is still present in the event, so exclude it.
    if (action == AMOTION_EVENT_ACTION_UP or action == AMOTION_EVENT_ACTION_CANCEL) {
        input.setAndroidTouches(&.{}, &.{});
    } else {
        const up_index: i32 = if (action == AMOTION_EVENT_ACTION_POINTER_UP)
            (AMotionEvent_getAction(event) & AMOTION_EVENT_ACTION_POINTER_INDEX_MASK) >> AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT
        else
            -1;
        var xs: [10]f32 = undefined;
        var ys: [10]f32 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < count and n < xs.len) : (i += 1) {
            if (@as(i32, @intCast(i)) == up_index) continue; // this finger is lifting
            xs[n] = AMotionEvent_getX(event, i);
            ys[n] = AMotionEvent_getY(event, i);
            n += 1;
        }
        input.setAndroidTouches(xs[0..n], ys[0..n]);
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
