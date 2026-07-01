/// bgfx input backend — satisfies the engine InputInterface(Impl) contract.
/// Uses GLFW for input on desktop (bgfx doesn't provide input). On
/// Android zglfw isn't available, so the input functions are stubbed
/// (real touch input is phase 3, #302) and `glfw` resolves to an empty
/// namespace — every zglfw reference below is comptime-gated on
/// `is_android` so the module compiles for `aarch64-linux-android`.
const builtin = @import("builtin");

/// labelle-core, for the comptime input-contract conformance gate below.
const core = @import("labelle-core");

// Prove this module satisfies labelle-core's input contract — formerly only a
// duck-typed claim in the doc comment above. The required core is small
// (`isKeyDown` + `isKeyPressed`); the rest of the surface (mouse/touch/gamepad)
// degrades gracefully via the contract's `@hasDecl` fallbacks. Fails the build
// with a named-decl list if a required method is missing or misnamed.
comptime {
    core.assertInput(@This());
}

// Contract-version tag (labelle-assembler#453 item 1). The assembler emits a
// directional `@compileError` version assert in the generated game's main.zig
// comparing this against labelle-core's `INPUT_CONTRACT_VERSION`. v1 is the
// initial revision of the input contract.
/// Input contract (keyboard/mouse/touch/gamepad state) revision this backend targets.
pub const targets_input_contract: u32 = 1;

const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

const glfw = if (is_android) struct {} else @import("zglfw");

// ── Android analog gamepad state (#310 Stage 4 / #250) ──────────────
//
// The shared `android_gamepad` module (`../android_gamepad`, also used by the
// sokol backend) owns the per-device button/axis state: the Android-keycode →
// canonical `GamepadButton`/`GamepadAxis` mapping, the device-name axis-routing
// quirk table, and the mutex-guarded device table. The bgfx NativeActivity
// shell (`android_app.zig`) feeds it raw `AInputEvent` key/motion data; the
// engine's `(gamepad_id, button/axis)` queries below resolve against it, keyed
// by Android device id (the same id the #248 detection registry emits as its
// hotplug `.slot`). All `agp` references are gated behind `is_android`, so off
// Android the gamepad getters fall back to the GLFW desktop path.
//
// The module is imported on every target (its Android-only `extern`/`@export`
// symbols are gated internally), but its state is only read on Android.
const agp = @import("android_gamepad");

// Desktop gamepad source toggle (core#28 slice 5), forwarded from the backend
// build.zig. When true (default, `.gamepad = .auto`) the shared windowless-SDL
// desktop gamepad source is wired in and the DESKTOP gamepad getters below route
// to it: SDL's HIDAPI drivers decode controllers (Switch-mode Nintendo Pro
// Controller / 8BitDo raw-HID) that GLFW — the toolkit bgfx uses for windowing —
// cannot. When false (`.gamepad = .none` opt-out) the `sdl_gamepad` module is
// NOT in the build graph, so we must not `@import` it, and the desktop getters
// fall back to the GLFW path (#315). Mirrors raylib/sokol's input.zig.
const gamepad_enabled = @import("build_options").gamepad_enabled;
// When true, the imgui bridge artifact is linked into the final game exe and
// its `imgui_bridge_mouse_*` externs are defined, so `newFrame` forwards the
// per-frame mouse/touch state to Dear ImGui (see `forwardGuiInput`). OFF by
// default: a non-imgui build must not reference those externs or it fails to
// link with an undefined symbol. The assembler sets `.gui_enabled = true` only
// when the project's gui plugin is imgui (build_files.zig).
const gui_enabled = @import("build_options").gui_enabled;

// labelle-imgui bgfx-bridge input feed. These resolve at the final game-exe
// link against the imgui bridge's exports — only when `gui_enabled` is true
// (the bridge artifact is in the graph). Declared inside the comptime gate so
// a non-imgui build never references the (then-undefined) symbols.
const imgui = if (gui_enabled) struct {
    extern fn imgui_bridge_mouse_pos(x: f32, y: f32) void;
    extern fn imgui_bridge_mouse_button(button: i32, down: bool) void;
    extern fn imgui_bridge_mouse_wheel(wheel_x: f32, wheel_y: f32) void;
    // Keyboard: a typed character (for text fields) and key down/up (for
    // backspace/enter/arrows/modifiers). Without these, imgui text inputs
    // ignore the keyboard on bgfx — only mouse worked. Fed from the GLFW
    // char + key callbacks (event-driven, not polled in `forwardGuiInput`).
    extern fn imgui_bridge_char(codepoint: u32) void;
    extern fn imgui_bridge_key(key: i32, down: bool) void;
} else struct {};
// Opt-in for HIDAPI raw-HID decode in the shared SDL gamepad source; OFF by
// default (HIDAPI's per-connect init stalls the render thread for seconds on
// some platforms). Pushed into the source before its lazy SDL init.
const gamepad_hidapi = @import("build_options").gamepad_hidapi;

// Desktop predicate matching `targetIsDesktop` in build.zig — the build wires
// the `sdl_gamepad` module ONLY when (gamepad_enabled AND desktop AND
// !android), so the `@import` must be gated identically; importing it on a
// target where it isn't in the graph is a compile error. The `@import` lives
// inside the taken comptime branch so it is NOT evaluated when the module is
// absent (opt-out / Android / wasm).
const target_is_desktop = blk: {
    const t = builtin.target;
    if (t.abi == .android or t.abi == .androideabi) break :blk false;
    if (t.cpu.arch.isWasm()) break :blk false;
    break :blk switch (t.os.tag) {
        .macos, .windows, .linux => true,
        else => false,
    };
};

const sdl_gp = if (gamepad_enabled and target_is_desktop) @import("sdl_gamepad") else struct {
    pub const is_desktop = false;
};

/// Desktop (non-Android) with the SDL source wired: gamepad state/hotplug comes
/// from the shared SDL source instead of GLFW. Resolved at comptime so the
/// unused branch (and its SDL or GLFW gamepad refs) is eliminated per target.
/// False whenever opted out, on Android, or off desktop.
const use_sdl_gamepad = gamepad_enabled and sdl_gp.is_desktop;

const MAX_KEYS = 512;
const MAX_MOUSE_BUTTONS = 8;

var keys_pressed: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;
var keys_released: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;

var mouse_down: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var mouse_pressed: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var mouse_released: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;

var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var mouse_wheel: f32 = 0;

// ── Android touch state ─────────────────────────────────────────────
// On Android there is no GLFW mouse — touch is the pointer. The
// NativeActivity glue (src/android_app.zig) feeds these from
// `AMotionEvent_*`. We model a single primary pointer mapped onto
// mouse button 0 + the mouse cursor position, so the engine's existing
// mouse-driven hit-testing/UI sees touch transparently. `touch_active`
// tracks whether a finger is currently on screen (drives `getTouchCount`).
var touch_active: bool = false;
var touch_x: f32 = 0;
var touch_y: f32 = 0;
var touch_id: u64 = 0;
var pointer_down: bool = false;
// Previous-frame down state so `newFrame` can derive press/release edges
// for mouse button 0 from the raw down signal the glue pushes.
var pointer_down_prev: bool = false;

var glfw_window: if (is_android) ?*anyopaque else ?*glfw.Window = null;

/// Bind to a GLFW window for input polling. Android has no GLFW window;
/// the type is `*anyopaque` there and `setWindow` is a no-op (touch
/// input is wired in phase 3, #302).
pub fn setWindow(win: if (is_android) *anyopaque else *glfw.Window) void {
    if (is_android) {
        glfw_window = win;
        return;
    }
    glfw_window = win;
    // `comptime`-gate the desktop-only GLFW callback registration so
    // `setWindow` stays well-typed under any analysis on Android (where
    // `win` is `*anyopaque` and has no `.set*Callback` — relying on the
    // earlier comptime-dead `return` alone is fragile across refactors).
    if (comptime !is_android) {
        _ = win.setScrollCallback(scrollCallback);
        // Keyboard EDGE state (`isKeyPressed`/`isKeyReleased`) is driven by
        // this callback. Without it `keys_pressed[]` was never populated, so
        // every edge-triggered key (e.g. Esc → pause menu) silently did
        // nothing on bgfx — only live-poll `isKeyDown` worked. Mirrors
        // `scrollCallback`.
        _ = win.setKeyCallback(keyCallback);
        // Char callback drives imgui text input (typed characters). Only
        // wired when the imgui bridge is linked — `charCallback` references
        // the (then-defined) `imgui_bridge_char` export.
        if (comptime gui_enabled) _ = win.setCharCallback(charCallback);
    }
}

fn scrollCallback(_: *glfw.Window, _: f64, yoffset: f64) callconv(.c) void {
    mouse_wheel = @floatCast(yoffset);
}

/// GLFW fires this during `glfw.pollEvents()` (called in `newFrame`, AFTER
/// the per-frame edge arrays are cleared), so a key pressed since last frame
/// shows up in `keys_pressed` for exactly this frame. GLFW key codes equal
/// the engine's `KeyboardKey` values (the same convention `isKeyDown` relies
/// on via `@enumFromInt`), so indexing the arrays by the GLFW code is
/// correct. `GLFW_KEY_UNKNOWN` (-1) and any code past the table are ignored.
fn keyCallback(_: *glfw.Window, key: glfw.Key, _: c_int, action: glfw.Action, _: glfw.Mods) callconv(.c) void {
    const code: c_int = @intFromEnum(key);
    // Forward to imgui so text fields see Backspace/Enter/Delete/arrows and
    // the Ctrl/Shift/Super modifiers. The bridge maps GLFW→ImGuiKey. Repeat
    // is skipped: imgui auto-repeats from the held-down state + DeltaTime, so
    // a held Backspace keeps deleting. (No-op / comptime-eliminated unless the
    // imgui bridge is linked.)
    if (comptime gui_enabled) {
        switch (action) {
            .press => imgui.imgui_bridge_key(code, true),
            .release => imgui.imgui_bridge_key(code, false),
            .repeat => {},
        }
    }
    if (code < 0 or code >= MAX_KEYS) return;
    const k: usize = @intCast(code);
    switch (action) {
        .press => keys_pressed[k] = true,
        .release => keys_released[k] = true,
        .repeat => {}, // auto-repeat isn't a fresh press; live held-state is isKeyDown
    }
}

/// GLFW char callback → imgui text input. Only registered when the imgui
/// bridge is linked (`gui_enabled`); the bridge drops control chars.
fn charCallback(_: *glfw.Window, codepoint: u32) callconv(.c) void {
    if (comptime !gui_enabled) return;
    imgui.imgui_bridge_char(codepoint);
}

/// Call at the start of each frame to reset per-frame state and poll GLFW.
/// On Android the GLFW poll is skipped (no zglfw); touch state will be
/// fed by the NativeActivity glue in phase 3.
pub fn newFrame() void {
    keys_pressed = [_]bool{false} ** MAX_KEYS;
    keys_released = [_]bool{false} ** MAX_KEYS;
    mouse_pressed = [_]bool{false} ** MAX_MOUSE_BUTTONS;
    mouse_released = [_]bool{false} ** MAX_MOUSE_BUTTONS;
    mouse_wheel = 0;

    if (is_android) {
        // Map the touch pointer onto mouse button 0 + the mouse cursor.
        // The glue updates `pointer_down`/`touch_*` asynchronously between
        // frames; derive this-frame press/release edges and mirror the
        // pointer position into the mouse fields the engine already reads.
        mouse_x = touch_x;
        mouse_y = touch_y;
        if (pointer_down and !pointer_down_prev) mouse_pressed[0] = true;
        if (!pointer_down and pointer_down_prev) mouse_released[0] = true;
        mouse_down[0] = pointer_down;
        pointer_down_prev = pointer_down;

        // Forward the touch pointer to Dear ImGui as mouse pos + button 0.
        // No-op (comptime-eliminated) unless the imgui bridge is linked.
        forwardGuiInput();

        // Snapshot gamepad button state at the frame boundary so the next
        // frame's `isGamepadButtonPressed` can derive the rising edge (#310
        // Stage 4). The shell feeds live key/motion state into `agp`
        // asynchronously between frames via the `applyGamepad*` entry points.
        agp.newFrame();
        return;
    }

    glfw.pollEvents();

    if (glfw_window) |win| {
        // GLFW's cursor position is in LOGICAL window coordinates, but the
        // engine maps input against the PHYSICAL framebuffer (via
        // `setScreenSize`, which now receives framebuffer pixels). Scale the
        // cursor to framebuffer pixels using the window's own
        // framebuffer/logical ratio so HiDPI hit-testing lands correctly.
        const pos = win.getCursorPos();
        const fb = win.getFramebufferSize();
        const ws = win.getSize();
        const sx: f64 = if (ws[0] > 0) @as(f64, @floatFromInt(fb[0])) / @as(f64, @floatFromInt(ws[0])) else 1.0;
        const sy: f64 = if (ws[1] > 0) @as(f64, @floatFromInt(fb[1])) / @as(f64, @floatFromInt(ws[1])) else 1.0;
        mouse_x = @floatCast(pos[0] * sx);
        mouse_y = @floatCast(pos[1] * sy);

        // Derive this-frame mouse button press/release EDGES. GLFW gives only
        // live down-state, so (mirroring the keyboard `keys_pressed`/`released`
        // and the Android pointer path) compare each button's live state
        // against `mouse_down[]` — the persisted previous-frame state — to set
        // the one-frame `mouse_pressed`/`mouse_released` arrays the engine's
        // `isMouseButtonPressed`/`Released` read. Without this they were always
        // false on desktop; only live-poll `isMouseButtonDown` worked.
        for (0..MAX_MOUSE_BUTTONS) |b| {
            const cur = win.getMouseButton(@enumFromInt(b)) == .press;
            if (cur and !mouse_down[b]) mouse_pressed[b] = true;
            if (!cur and mouse_down[b]) mouse_released[b] = true;
            mouse_down[b] = cur;
        }
    }

    // Snapshot gamepad button edges for this frame's `isGamepadButtonPressed`.
    // When the SDL desktop source is wired (`.gamepad = .auto`), pump it once
    // per frame: `update()` lazily inits SDL, drains hotplug, and refreshes the
    // button snapshot used for the SDL Source's own rising-edge detection — so
    // the GLFW snapshot is skipped (its getters aren't consulted). On
    // `.gamepad = .none` the SDL module is absent and we keep the GLFW snapshot.
    if (comptime use_sdl_gamepad) {
        sdl_gp.hidapi_enabled = gamepad_hidapi;
        sdl_gp.Source.update();
    } else {
        snapshotGamepads();
    }

    // Forward the GLFW mouse (cursor pos already in framebuffer pixels above,
    // buttons read live, wheel accumulated by the scroll callback) to Dear
    // ImGui. No-op (comptime-eliminated) unless the imgui bridge is linked.
    forwardGuiInput();
}

// ── GUI (Dear ImGui) input forwarding ──────────────────────────────────
//
// Pushes this frame's mouse/touch state into the labelle-imgui bgfx bridge so
// imgui widgets are interactive. Entirely comptime-eliminated when the imgui
// bridge isn't linked (`gui_enabled == false`) — the `imgui` namespace is
// empty there and this function body collapses to nothing.
//
// Called from `newFrame` AFTER `mouse_x`/`mouse_y` and the gamepad snapshot
// are settled, on BOTH paths:
//   - Desktop (GLFW): cursor pos is already scaled to framebuffer pixels;
//     button down-state is read live via `glfw.getMouseButton`; the wheel is
//     the `scrollCallback`-accumulated delta for this frame.
//   - Android (NDK): the touch pointer is mirrored onto `mouse_x`/`mouse_y` +
//     `mouse_down[0]`; there is no wheel.
//
// We forward mouse position every frame and the down-state of buttons 0..2
// (left/right/middle) — imgui's `AddMouseButtonEvent` only enqueues an event
// when the state actually changes, so calling it each frame with the current
// state is the standard, cheap backend pattern (no edge tracking needed here).
// The bridge feeds these straight into `ImGuiIO_Add*Event`. Coordinates are in
// the same physical-framebuffer pixel space the bridge renders in.
const GUI_FORWARDED_BUTTONS = 3; // left(0), right(1), middle(2)

fn guiButtonDown(button: u32) bool {
    if (is_android) {
        // Only the primary pointer → mouse button 0 is modelled on Android.
        return button < MAX_MOUSE_BUTTONS and mouse_down[button];
    }
    // Desktop: read the live GLFW button state (same source as the engine's
    // `isMouseButtonDown`), so imgui and the engine agree on this frame.
    if (glfw_window) |win| {
        return win.getMouseButton(@enumFromInt(button)) == .press;
    }
    return false;
}

fn forwardGuiInput() void {
    if (comptime !gui_enabled) return;

    imgui.imgui_bridge_mouse_pos(mouse_x, mouse_y);

    var b: u32 = 0;
    while (b < GUI_FORWARDED_BUTTONS) : (b += 1) {
        imgui.imgui_bridge_mouse_button(@intCast(b), guiButtonDown(b));
    }

    // Vertical wheel only (no horizontal source on either path). Skip the
    // call when there's no scroll this frame to avoid resetting imgui's
    // internal wheel accumulation needlessly.
    if (mouse_wheel != 0) {
        imgui.imgui_bridge_mouse_wheel(0, mouse_wheel);
    }
}

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    if (is_android) return false; // no keyboard on Android (phase 3 touch)
    if (glfw_window) |win| {
        return win.getKey(@enumFromInt(key)) == .press;
    }
    return false;
}

pub fn isKeyPressed(key: u32) bool {
    return if (key < MAX_KEYS) keys_pressed[key] else false;
}

pub fn isKeyReleased(key: u32) bool {
    return if (key < MAX_KEYS) keys_released[key] else false;
}

// ── Mouse ─────────────────────────────────────────────────

pub fn getMouseX() f32 {
    return mouse_x;
}

pub fn getMouseY() f32 {
    return mouse_y;
}

pub fn isMouseButtonDown(button: u32) bool {
    if (is_android) {
        // Touch maps onto mouse button 0 (see the Android touch state).
        return button < MAX_MOUSE_BUTTONS and mouse_down[button];
    }
    if (glfw_window) |win| {
        return win.getMouseButton(@enumFromInt(button)) == .press;
    }
    return false;
}

pub fn isMouseButtonPressed(button: u32) bool {
    return if (button < MAX_MOUSE_BUTTONS) mouse_pressed[button] else false;
}

pub fn isMouseButtonReleased(button: u32) bool {
    return if (button < MAX_MOUSE_BUTTONS) mouse_released[button] else false;
}

pub fn getMouseWheelMove() f32 {
    return mouse_wheel;
}

// ── Touch ─────────────────────────────────────────────────
//
// Desktop (GLFW) has no touch — every getter returns the empty state.
// On Android the NativeActivity glue (src/android_app.zig) feeds the
// single primary pointer via the setters below; the getters then report
// it as touch index 0 (multi-touch is a later phase).

pub fn getTouchCount() u32 {
    if (is_android) return if (touch_active) 1 else 0;
    return 0; // GLFW desktop: no touch support
}

pub fn getTouchX(index: u32) f32 {
    if (is_android and index == 0 and touch_active) return touch_x;
    return 0;
}

pub fn getTouchY(index: u32) f32 {
    if (is_android and index == 0 and touch_active) return touch_y;
    return 0;
}

pub fn getTouchId(index: u32) u64 {
    if (is_android and index == 0 and touch_active) return touch_id;
    return 0;
}

// ── Android touch feed (called by the NativeActivity glue) ──────────
//
// These are the entry points `src/android_app.zig` calls from the glue's
// input callback. They only mutate state — the per-frame edge derivation
// (press/release on mouse button 0, mouse-position mirroring) happens in
// `newFrame`. Off Android they're inert (state is never read) but kept
// un-gated so the symbol is always present for the shell to reference.

/// Update the primary pointer's position + id (motion DOWN / MOVE).
pub fn setTouchPointer(index: u32, x: f32, y: f32, id: i32) void {
    if (index != 0) return; // single primary pointer for now
    touch_x = x;
    touch_y = y;
    touch_id = @intCast(id);
    touch_active = true;
}

/// Set whether a finger is currently down (drives mouse button 0).
pub fn setPointerDown(down: bool) void {
    pointer_down = down;
}

/// Clear the active touch (motion UP / CANCEL). Position is retained for
/// one more frame so a tap's final coordinate is observable; `touch_active`
/// goes false so `getTouchCount` reports 0.
pub fn clearTouch() void {
    touch_active = false;
}

// ── Android gamepad feed (called by the NativeActivity glue) ────────
//
// The bgfx shell (`android_app.zig`) routes gamepad `AInputEvent`s here:
// key events (BUTTON_*/DPAD_*) via `applyGamepadKey`, and joystick/gamepad
// motion events (analog axes + hat) via `applyGamepadMotion`. Both forward
// into the shared `android_gamepad` state module (mapping + quirk + per-device
// table). The per-frame edge snapshot happens in `newFrame` (`agp.newFrame`).
// Off Android these are inert (the shell only calls them on Android) but kept
// un-gated so the symbol is always present for the shell to reference — `agp`'s
// apply* functions are pure-Zig no-op-safe on the host.

/// Number of forwarded analog axes the shell fills before calling
/// `applyGamepadMotion`. Re-exported from the shared state module so the shell
/// sizes its axis buffer correctly (indices are `agp.FA_*`).
pub const GAMEPAD_AXIS_COUNT = agp.FORWARDED_AXIS_COUNT;

/// Feed a gamepad KEY event (down/up) keyed by Android device id. `keycode`
/// is the raw `AKEYCODE_*` from `AKeyEvent_getKeyCode`.
pub fn applyGamepadKey(device_id: i32, keycode: i32, down: bool) void {
    agp.applyKey(device_id, keycode, down);
}

/// Feed a gamepad MOTION (analog axis snapshot) keyed by Android device id.
/// `axes` is indexed by `agp.FA_*` (X, Y, Z, RZ, RX, RY, LTRIGGER, RTRIGGER,
/// GAS, BRAKE, HAT_X, HAT_Y).
pub fn applyGamepadMotion(device_id: i32, axes: [agp.FORWARDED_AXIS_COUNT]f32) void {
    agp.applyMotion(device_id, axes);
}

// ── Gamepad ───────────────────────────────────────────────
//
// DESKTOP (GLFW): a controller is readable as a "gamepad" only when its GUID
// has an SDL gamecontroller mapping (`glfw.getGamepadState`). We translate the
// engine's canonical raylib-compatible numbering — buttons [0,17], axes [0,5]
// (LX, LY, RX, RY, LT, RT), matching `android_gamepad` + the raylib/sdl
// backends — to GLFW's standard layout. The two "trigger-as-button" canonical
// codes (LEFT/RIGHT_TRIGGER_2) are derived from the analog trigger axes.
//
// NOTE: a controller GLFW can't map (e.g. a Switch-mode Nintendo Pro
// Controller — only SDL's HIDAPI decodes those) reports *present*
// (`joystickPresent`) but yields no gamepad state, so its buttons/axes read as
// released/0. Use an X-input/Xbox pad, or the SDL backend, for those. On macOS,
// reading input also needs Input Monitoring permission for the host binary.
const MAX_GAMEPADS = 16; // GLFW joystick slots 0..15
const CANON_BUTTON_COUNT = 18; // canonical GamepadButton range [0,17]
// GLFW analog triggers rest at -1 and reach +1 fully pressed; treat past the
// midpoint as "down" for the digital LEFT/RIGHT_TRIGGER_2 buttons.
const TRIGGER_BUTTON_THRESHOLD: f32 = 0.0;

// Rising-edge bookkeeping for `isGamepadButtonPressed`, snapshotted in
// `newFrame` (mirrors the keyboard/mouse `*_pressed` pattern). Desktop-only;
// the Android path uses `agp`'s own edge state.
var gp_prev_down: [MAX_GAMEPADS][CANON_BUTTON_COUNT]bool =
    [_][CANON_BUTTON_COUNT]bool{[_]bool{false} ** CANON_BUTTON_COUNT} ** MAX_GAMEPADS;
var gp_pressed: [MAX_GAMEPADS][CANON_BUTTON_COUNT]bool =
    [_][CANON_BUTTON_COUNT]bool{[_]bool{false} ** CANON_BUTTON_COUNT} ** MAX_GAMEPADS;

/// Canonical button → GLFW gamepad button, or null when the canonical code is
/// an analog-trigger button (10/12, derived from the axes) or has no GLFW
/// equivalent (0 = UNKNOWN).
fn canonToGlfwButton(button: u32) ?glfw.Gamepad.Button {
    return switch (button) {
        1 => .dpad_up,
        2 => .dpad_right,
        3 => .dpad_down,
        4 => .dpad_left,
        5 => .y, // RIGHT_FACE_UP
        6 => .b, // RIGHT_FACE_RIGHT
        7 => .a, // RIGHT_FACE_DOWN
        8 => .x, // RIGHT_FACE_LEFT
        9 => .left_bumper, // LEFT_TRIGGER_1
        11 => .right_bumper, // RIGHT_TRIGGER_1
        13 => .back, // MIDDLE_LEFT
        14 => .guide, // MIDDLE
        15 => .start, // MIDDLE_RIGHT
        16 => .left_thumb,
        17 => .right_thumb,
        else => null,
    };
}

/// Resolve a canonical button against an already-fetched GLFW gamepad state.
fn glfwButtonDown(state: glfw.Gamepad.State, button: u32) bool {
    if (button == 10) return state.axes[@intFromEnum(glfw.Gamepad.Axis.left_trigger)] > TRIGGER_BUTTON_THRESHOLD;
    if (button == 12) return state.axes[@intFromEnum(glfw.Gamepad.Axis.right_trigger)] > TRIGGER_BUTTON_THRESHOLD;
    const gb = canonToGlfwButton(button) orelse return false;
    return state.buttons[@intFromEnum(gb)] == .press;
}

/// Desktop: snapshot per-gamepad button edges for `isGamepadButtonPressed`.
/// One `getGamepadState` per slot per frame; derives all canonical buttons
/// from that single state. Called from `newFrame` after `glfw.pollEvents`.
fn snapshotGamepads() void {
    var g: u32 = 0;
    while (g < MAX_GAMEPADS) : (g += 1) {
        const state = glfw.getGamepadState(@enumFromInt(g)) catch {
            // Not a mapped gamepad (or disconnected): clear edges + prev.
            gp_pressed[g] = [_]bool{false} ** CANON_BUTTON_COUNT;
            gp_prev_down[g] = [_]bool{false} ** CANON_BUTTON_COUNT;
            continue;
        };
        var b: u32 = 0;
        while (b < CANON_BUTTON_COUNT) : (b += 1) {
            const now = glfwButtonDown(state, b);
            gp_pressed[g][b] = now and !gp_prev_down[g][b];
            gp_prev_down[g][b] = now;
        }
    }
}

pub fn isGamepadAvailable(gamepad: u32) bool {
    // Android (#310 Stage 4): resolve against the shared per-device state,
    // keyed by Android device id. Connection is established by the JNI
    // detection glue (InputManager enumeration) + first input event.
    if (comptime is_android) return agp.connected(gamepad);
    // Desktop with the SDL source wired (`.gamepad = .auto`): route through
    // SDL's HIDAPI drivers (Switch/8BitDo raw-HID GLFW can't decode). The
    // Source emits the same canonical numbering as the GLFW path.
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isAvailable(gamepad);
    return glfw.joystickPresent(@enumFromInt(gamepad));
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    if (comptime is_android) return agp.buttonDown(gamepad, button);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isButtonDown(gamepad, button);
    if (gamepad >= MAX_GAMEPADS or button >= CANON_BUTTON_COUNT) return false;
    const state = glfw.getGamepadState(@enumFromInt(gamepad)) catch return false;
    return glfwButtonDown(state, button);
}

pub fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
    if (comptime is_android) return agp.buttonPressed(gamepad, button);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isButtonPressed(gamepad, button);
    // Rising edge computed in `newFrame` from the GLFW state snapshot.
    if (gamepad >= MAX_GAMEPADS or button >= CANON_BUTTON_COUNT) return false;
    return gp_pressed[gamepad][button];
}

pub fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
    if (comptime is_android) return agp.axisValue(gamepad, axis);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.axisValue(gamepad, axis);
    // Canonical axes 0..5 == GLFW axes 0..5 (LX, LY, RX, RY, LT, RT).
    if (gamepad >= MAX_GAMEPADS or axis >= glfw.Gamepad.Axis.count) return 0;
    const state = glfw.getGamepadState(@enumFromInt(gamepad)) catch return 0;
    return state.axes[axis];
}

/// bgfx Android backend adapter for labelle-core's backend-agnostic JNI seam
/// (labelle-core#310, Stage 4). Exposes `backendContext()`, which the generated
/// bgfx-Android `main.zig` registers with core
/// (`engine.core.registerAndroidBackend(...)`) so core's gamepad source and the
/// engine's immersive mode can reach the running ANativeActivity / InputManager
/// without core/engine linking any backend symbol directly. See `android.zig`.
//
// Android-only: the adapter imports `labelle-core` (for `AndroidBackendContext`)
// and binds the shell's `labelle_bgfx_get_native_activity` C symbol, neither of
// which is wired into the input module on desktop. Gate the re-export so
// `android.zig` is only analyzed on Android (where `build.zig` wires core in);
// on other targets it resolves to an empty namespace and is never compiled.
pub const android = if (is_android)
    @import("android.zig")
else
    struct {};
