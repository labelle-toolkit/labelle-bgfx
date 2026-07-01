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

/// wasm/WebGL (emscripten) target (bgfx-wasm epic #8). Like Android, zglfw is not
/// in the build graph, so `glfw` resolves to an empty namespace and every zglfw
/// reference below is comptime-gated on `no_glfw`. Input is minimal for the wasm
/// example (no keyboard/mouse/gamepad wiring yet); the getters return the empty
/// state, matching the pre-input Android path.
const is_wasm = builtin.target.cpu.arch.isWasm();

/// True on the two GLFW-less targets (Android + wasm).
const no_glfw = is_android or is_wasm;

const glfw = if (no_glfw) struct {} else @import("zglfw");

// ── wasm/emscripten HTML5 mouse input (#24) ─────────────────────────────
// bgfx has no windowing framework on wasm (no GLFW), so — like the Android
// NativeActivity glue feeds touch — we register emscripten HTML5 mouse
// callbacks on the `#canvas` element and feed the module's mouse state. The
// callbacks fire asynchronously between frames (browser event loop); `newFrame`
// derives this-frame press/release edges and forwards to Dear ImGui, mirroring
// the Android path. Hand-rolled externs (no `@cImport(<html5.h>)`, matching
// window.zig): the `EmscriptenMouseEvent` layout is byte-faithful to emscripten
// 4.x `html5.h`.
const em = if (is_wasm) struct {
    const MouseEvent = extern struct {
        timestamp: f64,
        screenX: i32,
        screenY: i32,
        clientX: i32,
        clientY: i32,
        ctrlKey: bool,
        shiftKey: bool,
        altKey: bool,
        metaKey: bool,
        button: u16,
        buttons: u16,
        movementX: i32,
        movementY: i32,
        targetX: i32,
        targetY: i32,
        canvasX: i32,
        canvasY: i32,
        padding: i32,
    };
    const WheelEvent = extern struct {
        mouse: MouseEvent,
        deltaX: f64,
        deltaY: f64,
        deltaZ: f64,
        deltaMode: u32,
    };
    // EmscriptenTouchPoint / EmscriptenTouchEvent (html5.h), byte-faithful.
    const TouchPoint = extern struct {
        identifier: i32,
        screenX: i32,
        screenY: i32,
        clientX: i32,
        clientY: i32,
        pageX: i32,
        pageY: i32,
        isChanged: bool,
        onTarget: bool,
        targetX: i32,
        targetY: i32,
        canvasX: i32,
        canvasY: i32,
    };
    const TouchEvent = extern struct {
        timestamp: f64,
        numTouches: i32,
        ctrlKey: bool,
        shiftKey: bool,
        altKey: bool,
        metaKey: bool,
        touches: [32]TouchPoint,
    };
    const MouseCb = *const fn (event_type: i32, e: *const MouseEvent, user: ?*anyopaque) callconv(.c) bool;
    const WheelCb = *const fn (event_type: i32, e: *const WheelEvent, user: ?*anyopaque) callconv(.c) bool;
    const TouchCb = *const fn (event_type: i32, e: *const TouchEvent, user: ?*anyopaque) callconv(.c) bool;
    // `EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD` == (pthread_t)0x2 (html5.h).
    const CALLING_THREAD: ?*anyopaque = @ptrFromInt(2);
    extern "c" fn emscripten_set_mousemove_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: bool, cb: MouseCb, thread: ?*anyopaque) c_int;
    extern "c" fn emscripten_set_mousedown_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: bool, cb: MouseCb, thread: ?*anyopaque) c_int;
    extern "c" fn emscripten_set_mouseup_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: bool, cb: MouseCb, thread: ?*anyopaque) c_int;
    extern "c" fn emscripten_set_wheel_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: bool, cb: WheelCb, thread: ?*anyopaque) c_int;
    extern "c" fn emscripten_set_touchstart_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: bool, cb: TouchCb, thread: ?*anyopaque) c_int;
    extern "c" fn emscripten_set_touchend_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: bool, cb: TouchCb, thread: ?*anyopaque) c_int;
    extern "c" fn emscripten_set_touchmove_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: bool, cb: TouchCb, thread: ?*anyopaque) c_int;
    extern "c" fn emscripten_set_touchcancel_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: bool, cb: TouchCb, thread: ?*anyopaque) c_int;
    extern "c" fn emscripten_get_canvas_element_size(target: [*:0]const u8, w: *c_int, h: *c_int) c_int;
    extern "c" fn emscripten_get_element_css_size(target: [*:0]const u8, w: *f64, h: *f64) c_int;
} else struct {};

// wasm mouse state, written by the HTML5 callbacks (async), read/latched in
// `newFrame`. Kept separate from `mouse_down[]` (the frame-latched state) so a
// press+release landing in the same frame is still observed as a click edge.
var wasm_mouse_down: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
// Edge accumulators: a mousedown+mouseup that both land BETWEEN two `newFrame`s
// leaves `wasm_mouse_down` back at its old level, so a level-diff alone would
// miss the click for the engine's polling getters (isMouseButtonPressed/Released).
// The callbacks set these on each edge; `newFrame` ORs them in, then clears them.
var wasm_mouse_pressed_accum: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var wasm_mouse_released_accum: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var wasm_wheel_accum: f32 = 0;

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

var glfw_window: if (no_glfw) ?*anyopaque else ?*glfw.Window = null;

/// Bind to a GLFW window for input polling. Android/wasm have no GLFW window;
/// the type is `*anyopaque` there and `setWindow` is a no-op (Android touch
/// input is wired in phase 3, #302; wasm html5 input is a follow-up).
pub fn setWindow(win: if (no_glfw) *anyopaque else *glfw.Window) void {
    if (no_glfw) {
        glfw_window = win;
        // wasm registers its HTML5 mouse+touch callbacks via `initWasmInput`
        // (called from `window.initWindowWasm`); Android has no setWindow input.
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

// ── wasm/emscripten HTML5 mouse callbacks (#24) ─────────────────────────
// Only analyzed on wasm: referenced solely from `registerWasmMouse`, itself
// reached only under `if (comptime is_wasm)`. `em`/`mouse_*` are the wasm defs.
const wasm_canvas: [:0]const u8 = "#canvas";

/// DOM `MouseEvent.button` (0=left,1=middle,2=right) → the engine/GLFW canonical
/// numbering (0=left,1=right,2=middle) that `mouse_down[]`, the engine getters,
/// and the imgui bridge's forwarded buttons all use. Returns null for others.
fn domToCanonButton(dom: u16) ?u32 {
    return switch (dom) {
        0 => 0, // left
        1 => 2, // DOM middle → canonical middle
        2 => 1, // DOM right  → canonical right
        else => null,
    };
}

/// CSS-pixel → framebuffer-pixel scale. The HTML5 event's `targetX/Y` are CSS
/// pixels relative to the canvas; the bridge renders (and the engine hit-tests)
/// in the canvas drawing-buffer pixels reported by `get_canvas_element_size`.
/// On a devicePixelRatio-1 display these are equal.
fn wasmScale() struct { x: f32, y: f32 } {
    var cw: c_int = 0;
    var ch: c_int = 0;
    var css_w: f64 = 0;
    var css_h: f64 = 0;
    _ = em.emscripten_get_canvas_element_size(wasm_canvas.ptr, &cw, &ch);
    _ = em.emscripten_get_element_css_size(wasm_canvas.ptr, &css_w, &css_h);
    const sx: f32 = if (css_w > 0) @as(f32, @floatFromInt(cw)) / @as(f32, @floatCast(css_w)) else 1;
    const sy: f32 = if (css_h > 0) @as(f32, @floatFromInt(ch)) / @as(f32, @floatCast(css_h)) else 1;
    return .{ .x = sx, .y = sy };
}

fn setWasmPos(e: *const em.MouseEvent) void {
    const s = wasmScale();
    mouse_x = @as(f32, @floatFromInt(e.targetX)) * s.x;
    mouse_y = @as(f32, @floatFromInt(e.targetY)) * s.y;
    // Feed imgui the position immediately (event-driven), so a click landing in
    // the SAME frame as its move still hit-tests at the right spot. imgui buffers
    // events and applies them at the next `NewFrame` (imgui_bridge_begin).
    if (comptime gui_enabled) imgui.imgui_bridge_mouse_pos(mouse_x, mouse_y);
}

fn wasmMouseMove(_: i32, e: *const em.MouseEvent, _: ?*anyopaque) callconv(.c) bool {
    setWasmPos(e);
    return true;
}

fn wasmMouseDown(_: i32, e: *const em.MouseEvent, _: ?*anyopaque) callconv(.c) bool {
    setWasmPos(e);
    if (domToCanonButton(e.button)) |b| {
        wasm_mouse_down[b] = true; // latched state for the engine's polling getters
        wasm_mouse_pressed_accum[b] = true; // press edge, even if released same frame
        // Event-driven for imgui: a mousedown+mouseup between two frames would
        // collapse to "not pressed" if we only forwarded the per-frame latch, so
        // the click would be lost. Forwarding each event lets imgui see the full
        // down→up sequence and register the click.
        if (comptime gui_enabled) imgui.imgui_bridge_mouse_button(@intCast(b), true);
    }
    return true;
}

fn wasmMouseUp(_: i32, e: *const em.MouseEvent, _: ?*anyopaque) callconv(.c) bool {
    setWasmPos(e);
    if (domToCanonButton(e.button)) |b| {
        wasm_mouse_down[b] = false;
        wasm_mouse_released_accum[b] = true; // release edge, even if pressed same frame
        if (comptime gui_enabled) imgui.imgui_bridge_mouse_button(@intCast(b), false);
    }
    return true;
}

fn wasmWheel(_: i32, e: *const em.WheelEvent, _: ?*anyopaque) callconv(.c) bool {
    // Position imgui at the wheel event location first (so it scrolls the widget
    // under the cursor), then forward the delta.
    setWasmPos(&e.mouse);
    // DOM wheel deltaY is +down; GLFW/desktop yoffset is +up → negate. Normalize
    // to imgui's ~1-unit-per-notch by `deltaMode`: 0=pixels (~100/notch), 1=lines
    // (~1/line), 2=pages. Dividing everything by 100 would under-scale line/page.
    const raw: f32 = @floatCast(-e.deltaY);
    const w: f32 = switch (e.deltaMode) {
        0 => raw / 100.0, // DOM_DELTA_PIXEL
        1 => raw, // DOM_DELTA_LINE
        else => raw * 3.0, // DOM_DELTA_PAGE → a few notches
    };
    wasm_wheel_accum += w; // for the engine's per-frame getMouseWheelMove
    if (comptime gui_enabled) imgui.imgui_bridge_mouse_wheel(0, w);
    return true;
}

// ── wasm/emscripten HTML5 touch callbacks (mobile web) ──────────────────
// Mirror the Android NativeActivity glue's single-primary-pointer model: map
// the first touch point onto mouse button 0 + the cursor position, so imgui and
// the engine's mouse-driven hit-testing see touch transparently. Also drive the
// engine's touch getters (getTouchX/Y/Count/Id) for games that read touch
// directly. Multi-touch (pinch) is a follow-up. Desktop fires mouse callbacks;
// mobile fires these — a device just uses whichever it has.

/// Position (scaled CSS→framebuffer) from the primary touch point.
fn setWasmTouchPos(t: *const em.TouchPoint) void {
    const s = wasmScale();
    mouse_x = @as(f32, @floatFromInt(t.targetX)) * s.x;
    mouse_y = @as(f32, @floatFromInt(t.targetY)) * s.y;
    // Engine touch getters (Android-parity): expose as touch index 0.
    touch_x = mouse_x;
    touch_y = mouse_y;
    if (comptime gui_enabled) imgui.imgui_bridge_mouse_pos(mouse_x, mouse_y);
}

/// Number of valid entries in the event's touch array (clamped to the fixed 32).
fn wasmTouchCount(e: *const em.TouchEvent) usize {
    if (e.numTouches <= 0) return 0;
    return @min(@as(usize, @intCast(e.numTouches)), e.touches.len);
}

/// The touch point matching `id`, if present in this event.
fn findWasmTouch(e: *const em.TouchEvent, id: u64) ?*const em.TouchPoint {
    for (e.touches[0..wasmTouchCount(e)]) |*t| {
        if (@as(u64, @intCast(t.identifier)) == id) return t;
    }
    return null;
}

// Single-primary-pointer model (Android-parity): the FIRST finger down becomes
// the pointer, tracked by its `identifier`; other fingers are ignored until it
// lifts. This prevents a second finger from emitting an extra button-0 press or
// a stray finger's `touchend` from releasing an in-progress drag. (Multi-touch /
// pinch is a follow-up.)
fn wasmTouchStart(_: i32, e: *const em.TouchEvent, _: ?*anyopaque) callconv(.c) bool {
    if (e.numTouches <= 0) return true;
    if (touch_active) return true; // already tracking a primary finger
    const t = &e.touches[0];
    touch_id = @intCast(t.identifier);
    setWasmTouchPos(t);
    touch_active = true;
    pointer_down = true;
    wasm_mouse_down[0] = true;
    wasm_mouse_pressed_accum[0] = true;
    if (comptime gui_enabled) imgui.imgui_bridge_mouse_button(0, true);
    return true;
}

fn wasmTouchMove(_: i32, e: *const em.TouchEvent, _: ?*anyopaque) callconv(.c) bool {
    if (!touch_active) return true;
    if (findWasmTouch(e, touch_id)) |t| setWasmTouchPos(t);
    return true;
}

fn wasmTouchEnd(_: i32, e: *const em.TouchEvent, _: ?*anyopaque) callconv(.c) bool {
    if (!touch_active) return true;
    // The primary is still down iff it appears in this event as an ACTIVE
    // (not-changed) touch — true whether emscripten includes the ended touch
    // (as `isChanged`) or omits it. If so, a non-primary finger ended: keep the
    // pointer down and just refresh position.
    for (e.touches[0..wasmTouchCount(e)]) |*t| {
        if (@as(u64, @intCast(t.identifier)) == touch_id and !t.isChanged) {
            setWasmTouchPos(t);
            return true;
        }
    }
    // Primary finger lifted → release the pointer.
    touch_active = false;
    pointer_down = false;
    if (wasm_mouse_down[0]) {
        wasm_mouse_down[0] = false;
        wasm_mouse_released_accum[0] = true;
        if (comptime gui_enabled) imgui.imgui_bridge_mouse_button(0, false);
    }
    return true;
}

/// Register the HTML5 canvas mouse + touch callbacks (wasm only). Called from
/// `window.initWindowWasm` — the wasm analog of the desktop `setWindow` GLFW
/// callback registration. No-op / comptime-eliminated off wasm.
pub fn initWasmInput() void {
    if (comptime is_wasm) registerWasmInput();
}

fn registerWasmInput() void {
    // Mouse (desktop web)
    _ = em.emscripten_set_mousemove_callback_on_thread(wasm_canvas.ptr, null, true, wasmMouseMove, em.CALLING_THREAD);
    _ = em.emscripten_set_mousedown_callback_on_thread(wasm_canvas.ptr, null, true, wasmMouseDown, em.CALLING_THREAD);
    _ = em.emscripten_set_mouseup_callback_on_thread(wasm_canvas.ptr, null, true, wasmMouseUp, em.CALLING_THREAD);
    _ = em.emscripten_set_wheel_callback_on_thread(wasm_canvas.ptr, null, true, wasmWheel, em.CALLING_THREAD);
    // Touch (mobile web) — primary pointer → mouse button 0 + touch getters.
    _ = em.emscripten_set_touchstart_callback_on_thread(wasm_canvas.ptr, null, true, wasmTouchStart, em.CALLING_THREAD);
    _ = em.emscripten_set_touchmove_callback_on_thread(wasm_canvas.ptr, null, true, wasmTouchMove, em.CALLING_THREAD);
    _ = em.emscripten_set_touchend_callback_on_thread(wasm_canvas.ptr, null, true, wasmTouchEnd, em.CALLING_THREAD);
    _ = em.emscripten_set_touchcancel_callback_on_thread(wasm_canvas.ptr, null, true, wasmTouchEnd, em.CALLING_THREAD);
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

    // wasm: the HTML5 mouse callbacks (registerWasmMouse) updated `wasm_mouse_down`
    // + `mouse_x/y` + `wasm_wheel_accum` asynchronously since the last frame. Latch
    // them into the frame state: derive this-frame press/release EDGES (like the
    // Android pointer path), copy the live down-state, drain the wheel, and forward
    // to Dear ImGui. Returning here keeps every zglfw reference comptime-eliminated.
    if (comptime is_wasm) {
        // Latch the async-callback state into this frame's engine getters
        // (isMouseButton{Down,Pressed,Released}, getMouseWheelMove). imgui is fed
        // event-driven directly from the callbacks (see wasmMouse*), so no
        // forwardGuiInput() here — that would double every imgui mouse event.
        for (0..MAX_MOUSE_BUTTONS) |b| {
            const cur = wasm_mouse_down[b];
            // OR the callback-accumulated edges so a click that both pressed and
            // released between frames still registers (level-diff alone misses it).
            if (wasm_mouse_pressed_accum[b] or (cur and !mouse_down[b])) mouse_pressed[b] = true;
            if (wasm_mouse_released_accum[b] or (!cur and mouse_down[b])) mouse_released[b] = true;
            mouse_down[b] = cur;
        }
        wasm_mouse_pressed_accum = [_]bool{false} ** MAX_MOUSE_BUTTONS;
        wasm_mouse_released_accum = [_]bool{false} ** MAX_MOUSE_BUTTONS;
        mouse_wheel = wasm_wheel_accum;
        wasm_wheel_accum = 0;
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
    if (is_android or is_wasm) {
        // Android: the primary pointer → mouse button 0. wasm: the HTML5 mouse
        // callbacks maintain the full `mouse_down[]` (latched in `newFrame`).
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
    if (no_glfw) return false; // no keyboard on Android (phase 3 touch) / wasm (follow-up)
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
    if (comptime is_wasm) return button < MAX_MOUSE_BUTTONS and mouse_down[button];
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
    // Android NativeActivity glue OR wasm HTML5 touch callbacks feed the single
    // primary pointer into `touch_active`/`touch_*`.
    if (is_android or is_wasm) return if (touch_active) 1 else 0;
    return 0; // GLFW desktop: no touch support
}

pub fn getTouchX(index: u32) f32 {
    if ((is_android or is_wasm) and index == 0 and touch_active) return touch_x;
    return 0;
}

pub fn getTouchY(index: u32) f32 {
    if ((is_android or is_wasm) and index == 0 and touch_active) return touch_y;
    return 0;
}

pub fn getTouchId(index: u32) u64 {
    if ((is_android or is_wasm) and index == 0 and touch_active) return touch_id;
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
    if (comptime is_wasm) return false; // no html5 gamepad feed yet
    // Desktop with the SDL source wired (`.gamepad = .auto`): route through
    // SDL's HIDAPI drivers (Switch/8BitDo raw-HID GLFW can't decode). The
    // Source emits the same canonical numbering as the GLFW path.
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isAvailable(gamepad);
    return glfw.joystickPresent(@enumFromInt(gamepad));
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    if (comptime is_android) return agp.buttonDown(gamepad, button);
    if (comptime is_wasm) return false; // no html5 gamepad feed yet
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isButtonDown(gamepad, button);
    if (gamepad >= MAX_GAMEPADS or button >= CANON_BUTTON_COUNT) return false;
    const state = glfw.getGamepadState(@enumFromInt(gamepad)) catch return false;
    return glfwButtonDown(state, button);
}

pub fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
    if (comptime is_android) return agp.buttonPressed(gamepad, button);
    if (comptime is_wasm) return false; // no html5 gamepad feed yet
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isButtonPressed(gamepad, button);
    // Rising edge computed in `newFrame` from the GLFW state snapshot.
    if (gamepad >= MAX_GAMEPADS or button >= CANON_BUTTON_COUNT) return false;
    return gp_pressed[gamepad][button];
}

pub fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
    if (comptime is_android) return agp.axisValue(gamepad, axis);
    if (comptime is_wasm) return 0; // no html5 gamepad feed yet
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
