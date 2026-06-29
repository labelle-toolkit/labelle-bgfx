//! Shared desktop gamepad source (macOS / Windows / Linux native) backed by a
//! **windowless** SDL2 joystick/gamecontroller subsystem.
//!
//! ## Why this lives in the assembler, not labelle-core
//!
//! SDL2 is a third-party C library. labelle-core is meant to stay
//! dependency-free at the OS-source layer (its per-OS files reach the OS HID
//! stack directly: evdev/udev on Linux, JNI on Android, GameController on
//! ios/tvos). A windowless-SDL source therefore does NOT belong in core; it
//! belongs beside the render backends that already link SDL. This module is
//! the relocated counterpart of the old `labelle-core/src/gamepad_source/
//! desktop.zig` (core#28 / core#30 revert), placed exactly where the Android
//! gamepad STATE already lives — in the assembler, consumed through the
//! backend `Impl` seam (see `backends/sokol/src/android_gamepad_state.zig`).
//!
//! Both the raylib AND sokol DESKTOP backends depend on this ONE copy (via a
//! `.path = "../sdl_gamepad"` dependency in their `build.zig.zon`), so the
//! Switch/8BitDo raw-HID handshake that GLFW (raylib) and sokol_app cannot
//! decode is closed once, everywhere. The SDL RENDER backend keeps its OWN
//! SDL event loop and must NOT route through here (two `SDL_PollEvent`
//! consumers on one queue would steal each other's events).
//!
//! ## Why SDL, windowless
//!
//! We init `SDL_INIT_GAMECONTROLLER | SDL_INIT_JOYSTICK` with NO
//! `SDL_INIT_VIDEO` and never create a window. SDL talks straight to the OS
//! HID layer and runs beside whatever the render backend's window is doing.
//! The render backend's frame loop pumps us once per frame via `update()`.
//!
//! ## Contract
//!
//! This module mirrors the optional STATE surface labelle-core's
//! `gamepad_source` defines (`update`/`isAvailable`/`isButtonDown`/
//! `isButtonPressed`/`axisValue`) plus the detection surface
//! (`pollEvents`/`describe`). Slots are dense 0..MAX_GAMEPADS-1 indices
//! assigned on connect (lowest free slot wins) and freed on disconnect,
//! matching the raylib-compatible "gamepad index" model the engine uses.
//!
//! ## Numbering
//!
//! Buttons and axes are reported in the canonical, raylib-compatible numbering
//! (see `sdlButtonToCanonical` / `sdlAxisToCanonical`). The trigger axes also
//! synthesize the analog-trigger buttons (`left_trigger_2`/`right_trigger_2`)
//! when they cross a threshold, so a backend that only reads buttons still
//! sees trigger presses.
//!
//! ## Host / cross-compile note
//!
//! Like `android_gamepad_state.zig` gates its JNI/`extern` symbols behind
//! `comptime is_android`, this file gates every SDL `extern` declaration and
//! call behind `comptime is_desktop`. On non-desktop targets (wasm/android/
//! ios) the file compiles to pure Zig with zero unresolved SDL symbols, so the
//! cross-compile platform-check passes and no SDL is pulled into those builds.
//! The pure mapping helpers (`sdlButtonToCanonical`, `sdlAxisToCanonical`,
//! `normalizeAxis`, `typeHintFromName`) are plain, host-testable Zig and are
//! NOT gated.
//!
//! See labelle-toolkit/labelle-core#28 (and the core revert, core#30).

const std = @import("std");
const builtin = @import("builtin");

// labelle-core supplies the cross-backend gamepad event contract. The
// consuming backend (raylib/sokol) `overrideImport`s its OWN unified
// `labelle-core` module onto this one (under the `"labelle_core"` key — see
// this package's build.zig), so the `GamepadEvent`/`GamepadDescription`
// values produced here are the SAME core types the backend's `input` module
// and the engine see. Without that unification a `[]GamepadEvent` returned
// from `pollEvents` would not type-check across the boundary.
const core = @import("labelle_core");
const GamepadEvent = core.GamepadEvent;
const GamepadDescription = core.GamepadDescription;
const TypeHint = core.GamepadTypeHint;

/// True only on a native desktop target (macOS / Windows / Linux), excluding
/// the mobile/web targets that own their own source. Android is detected via
/// abi (there is no `Os.Tag.android`); iOS/tvOS and wasm are excluded by os
/// tag / cpu arch. All SDL `extern`s are gated on this so non-desktop builds
/// reference no SDL symbols.
pub const is_desktop = blk: {
    const os = builtin.target.os.tag;
    const abi = builtin.target.abi;
    if (abi == .android or abi == .androideabi) break :blk false;
    if (builtin.target.cpu.arch.isWasm()) break :blk false;
    break :blk switch (os) {
        .macos, .windows, .linux => true,
        else => false,
    };
};

/// Max simultaneously-tracked controllers. Matches the raylib backend's
/// 4-pad assumption; slots are dense 0..MAX_GAMEPADS-1.
pub const MAX_GAMEPADS: usize = 4;

// ── Canonical numbering (raylib-compatible) ─────────────────────────────
//
// Buttons (u32): the same values the raylib backend and engine already use.
pub const Button = struct {
    pub const left_face_up: u32 = 1;
    pub const left_face_right: u32 = 2;
    pub const left_face_down: u32 = 3;
    pub const left_face_left: u32 = 4;
    pub const right_face_up: u32 = 5;
    pub const right_face_right: u32 = 6;
    pub const right_face_down: u32 = 7;
    pub const right_face_left: u32 = 8;
    pub const left_trigger_1: u32 = 9;
    pub const left_trigger_2: u32 = 10;
    pub const right_trigger_1: u32 = 11;
    pub const right_trigger_2: u32 = 12;
    pub const middle_left: u32 = 13;
    pub const middle: u32 = 14;
    pub const middle_right: u32 = 15;
    pub const left_thumb: u32 = 16;
    pub const right_thumb: u32 = 17;
};

// Axes (u32).
pub const Axis = struct {
    pub const left_x: u32 = 0;
    pub const left_y: u32 = 1;
    pub const right_x: u32 = 2;
    pub const right_y: u32 = 3;
    pub const left_trigger: u32 = 4;
    pub const right_trigger: u32 = 5;
};

// ── SDL_GameController button/axis enum values (from SDL_gamecontroller.h) ─
const SDL_CONTROLLER_BUTTON_A: c_int = 0;
const SDL_CONTROLLER_BUTTON_B: c_int = 1;
const SDL_CONTROLLER_BUTTON_X: c_int = 2;
const SDL_CONTROLLER_BUTTON_Y: c_int = 3;
const SDL_CONTROLLER_BUTTON_BACK: c_int = 4;
const SDL_CONTROLLER_BUTTON_GUIDE: c_int = 5;
const SDL_CONTROLLER_BUTTON_START: c_int = 6;
const SDL_CONTROLLER_BUTTON_LEFTSTICK: c_int = 7;
const SDL_CONTROLLER_BUTTON_RIGHTSTICK: c_int = 8;
const SDL_CONTROLLER_BUTTON_LEFTSHOULDER: c_int = 9;
const SDL_CONTROLLER_BUTTON_RIGHTSHOULDER: c_int = 10;
const SDL_CONTROLLER_BUTTON_DPAD_UP: c_int = 11;
const SDL_CONTROLLER_BUTTON_DPAD_DOWN: c_int = 12;
const SDL_CONTROLLER_BUTTON_DPAD_LEFT: c_int = 13;
const SDL_CONTROLLER_BUTTON_DPAD_RIGHT: c_int = 14;
const SDL_CONTROLLER_BUTTON_MAX: c_int = 21;

const SDL_CONTROLLER_AXIS_LEFTX: c_int = 0;
const SDL_CONTROLLER_AXIS_LEFTY: c_int = 1;
const SDL_CONTROLLER_AXIS_RIGHTX: c_int = 2;
const SDL_CONTROLLER_AXIS_RIGHTY: c_int = 3;
const SDL_CONTROLLER_AXIS_TRIGGERLEFT: c_int = 4;
const SDL_CONTROLLER_AXIS_TRIGGERRIGHT: c_int = 5;
const SDL_CONTROLLER_AXIS_MAX: c_int = 6;

/// Trigger-axis level (normalized 0..1) at/above which the synthesized
/// analog-trigger button (`left_trigger_2`/`right_trigger_2`) reads pressed.
pub const TRIGGER_BUTTON_THRESHOLD: f32 = 0.5;

// ── Pure mapping helpers (host-testable; NOT gated on is_desktop) ────────

/// Map an SDL_GameController button enum to the canonical button number, using
/// the Google/Xbox PHYSICAL layout (so the physical bottom face button is
/// `right_face_down` regardless of the vendor's A/B labels). Returns null for
/// SDL buttons with no canonical mapping (e.g. touchpad / paddles).
pub fn sdlButtonToCanonical(sdl_button: c_int) ?u32 {
    return switch (sdl_button) {
        SDL_CONTROLLER_BUTTON_A => Button.right_face_down, // physical bottom
        SDL_CONTROLLER_BUTTON_B => Button.right_face_right, // physical right
        SDL_CONTROLLER_BUTTON_X => Button.right_face_left, // physical left
        SDL_CONTROLLER_BUTTON_Y => Button.right_face_up, // physical top
        SDL_CONTROLLER_BUTTON_DPAD_UP => Button.left_face_up,
        SDL_CONTROLLER_BUTTON_DPAD_DOWN => Button.left_face_down,
        SDL_CONTROLLER_BUTTON_DPAD_LEFT => Button.left_face_left,
        SDL_CONTROLLER_BUTTON_DPAD_RIGHT => Button.left_face_right,
        SDL_CONTROLLER_BUTTON_LEFTSHOULDER => Button.left_trigger_1,
        SDL_CONTROLLER_BUTTON_RIGHTSHOULDER => Button.right_trigger_1,
        SDL_CONTROLLER_BUTTON_LEFTSTICK => Button.left_thumb,
        SDL_CONTROLLER_BUTTON_RIGHTSTICK => Button.right_thumb,
        SDL_CONTROLLER_BUTTON_BACK => Button.middle_left,
        SDL_CONTROLLER_BUTTON_GUIDE => Button.middle,
        SDL_CONTROLLER_BUTTON_START => Button.middle_right,
        else => null,
    };
}

/// Inverse of `sdlButtonToCanonical`: map a canonical button to the SDL
/// button enum we must query for it. Returns null for canonical buttons that
/// SDL exposes as an *axis* (the analog triggers `left_trigger_2`/
/// `right_trigger_2`) or that have no SDL source.
pub fn canonicalButtonToSdl(canonical: u32) ?c_int {
    return switch (canonical) {
        Button.right_face_down => SDL_CONTROLLER_BUTTON_A,
        Button.right_face_right => SDL_CONTROLLER_BUTTON_B,
        Button.right_face_left => SDL_CONTROLLER_BUTTON_X,
        Button.right_face_up => SDL_CONTROLLER_BUTTON_Y,
        Button.left_face_up => SDL_CONTROLLER_BUTTON_DPAD_UP,
        Button.left_face_down => SDL_CONTROLLER_BUTTON_DPAD_DOWN,
        Button.left_face_left => SDL_CONTROLLER_BUTTON_DPAD_LEFT,
        Button.left_face_right => SDL_CONTROLLER_BUTTON_DPAD_RIGHT,
        Button.left_trigger_1 => SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
        Button.right_trigger_1 => SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
        Button.left_thumb => SDL_CONTROLLER_BUTTON_LEFTSTICK,
        Button.right_thumb => SDL_CONTROLLER_BUTTON_RIGHTSTICK,
        Button.middle_left => SDL_CONTROLLER_BUTTON_BACK,
        Button.middle => SDL_CONTROLLER_BUTTON_GUIDE,
        Button.middle_right => SDL_CONTROLLER_BUTTON_START,
        else => null, // left_trigger_2 / right_trigger_2 come from axes
    };
}

/// Map an SDL_GameController axis enum to the canonical axis number. Returns
/// null for axes with no canonical mapping.
pub fn sdlAxisToCanonical(sdl_axis: c_int) ?u32 {
    return switch (sdl_axis) {
        SDL_CONTROLLER_AXIS_LEFTX => Axis.left_x,
        SDL_CONTROLLER_AXIS_LEFTY => Axis.left_y,
        SDL_CONTROLLER_AXIS_RIGHTX => Axis.right_x,
        SDL_CONTROLLER_AXIS_RIGHTY => Axis.right_y,
        SDL_CONTROLLER_AXIS_TRIGGERLEFT => Axis.left_trigger,
        SDL_CONTROLLER_AXIS_TRIGGERRIGHT => Axis.right_trigger,
        else => null,
    };
}

/// Inverse of `sdlAxisToCanonical`: which SDL axis backs a canonical axis.
fn canonicalAxisToSdl(canonical: u32) ?c_int {
    return switch (canonical) {
        Axis.left_x => SDL_CONTROLLER_AXIS_LEFTX,
        Axis.left_y => SDL_CONTROLLER_AXIS_LEFTY,
        Axis.right_x => SDL_CONTROLLER_AXIS_RIGHTX,
        Axis.right_y => SDL_CONTROLLER_AXIS_RIGHTY,
        Axis.left_trigger => SDL_CONTROLLER_AXIS_TRIGGERLEFT,
        Axis.right_trigger => SDL_CONTROLLER_AXIS_TRIGGERRIGHT,
        else => null,
    };
}

/// Normalize a raw SDL axis value (i16, [-32768, 32767]) to f32.
///
/// * Sticks (`is_trigger == false`) map to [-1, 1], dividing by the
///   appropriate magnitude per sign so 0 stays exactly 0 and the extremes hit
///   exactly +/-1.
/// * Triggers (`is_trigger == true`) rest at 0 and map to [0, 1]; SDL reports
///   triggers in [0, 32767], so we divide by 32767.
pub fn normalizeAxis(raw: i16, is_trigger: bool) f32 {
    const v: f32 = @floatFromInt(raw);
    if (is_trigger) {
        // Clamp negatives (shouldn't occur for triggers) to 0.
        if (v <= 0) return 0;
        return @min(v / 32767.0, 1.0);
    }
    if (v >= 0) return @min(v / 32767.0, 1.0);
    return @max(v / 32768.0, -1.0);
}

/// True when canonical `axis` is a trigger (rest at 0, range [0,1]).
fn isTriggerAxis(axis: u32) bool {
    return axis == Axis.left_trigger or axis == Axis.right_trigger;
}

/// Best-guess vendor family from an SDL controller name, for glyph/prompt
/// selection. Pure string heuristic so it is host-testable. SDL exposes a
/// richer `SDL_GameControllerGetType`, but a name match is enough for the
/// `TypeHint` the contract carries and avoids one more `extern`.
pub fn typeHintFromName(name: []const u8) TypeHint {
    var buf: [NAME_SCAN_CAP]u8 = undefined;
    const n = @min(name.len, NAME_SCAN_CAP);
    for (0..n) |i| buf[i] = std.ascii.toLower(name[i]);
    const lower = buf[0..n];
    if (containsAny(lower, &.{ "xbox", "xinput" })) return .xbox;
    if (containsAny(lower, &.{ "playstation", "dualshock", "dualsense", "ps3", "ps4", "ps5", "wireless controller" })) return .playstation;
    if (containsAny(lower, &.{ "nintendo", "switch", "joy-con", "joycon", "8bitdo", "pro controller" })) return .nintendo;
    return .generic;
}

const NAME_SCAN_CAP: usize = 64;

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

// ════════════════════════════════════════════════════════════════════════
// Desktop-only SDL layer. All `extern` references live behind `is_desktop`
// so non-desktop targets never reference these symbols.
// ════════════════════════════════════════════════════════════════════════

const sdl = if (is_desktop) struct {
    // Opaque SDL handle types.
    const SDL_GameController = anyopaque;
    const SDL_JoystickID = i32;

    const SDL_INIT_JOYSTICK: u32 = 0x00000200;
    const SDL_INIT_GAMECONTROLLER: u32 = 0x00002000;

    const SDL_HINT_JOYSTICK_HIDAPI = "SDL_JOYSTICK_HIDAPI";

    // SDL_Event is a >= 56-byte union (variable across versions). We only read
    // the leading `type` (u32) plus, for device events, the device index/id
    // which live in a `SDL_ControllerDeviceEvent`. To stay ABI-safe without
    // transcribing the whole union we over-size the buffer and decode the two
    // device-event layouts we care about by offset via a typed view.
    //
    // The real SDL_Event contains 64-bit fields and must be 8-byte aligned;
    // passing an under-aligned pointer to SDL_PollEvent is UB on ARM64. We
    // force 8-byte alignment by sizing the padding in u64 units.
    const SDL_EVENT_SIZE = 64;
    const SDL_Event = extern union {
        type: u32,
        cdevice: SDL_ControllerDeviceEvent,
        padding: [SDL_EVENT_SIZE / 8]u64,
    };

    // SDL_ControllerDeviceEvent { Uint32 type; Uint32 timestamp; Sint32 which; }
    // `which` is a JOYSTICK INDEX for ADDED, a JOYSTICK INSTANCE ID for
    // REMOVED/REMAPPED (per SDL docs).
    const SDL_ControllerDeviceEvent = extern struct {
        type: u32,
        timestamp: u32,
        which: i32,
    };

    const SDL_CONTROLLERDEVICEADDED: u32 = 0x653; // 1619
    const SDL_CONTROLLERDEVICEREMOVED: u32 = 0x654; // 1620

    extern fn SDL_InitSubSystem(flags: u32) c_int;
    extern fn SDL_QuitSubSystem(flags: u32) void;
    extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) c_int;
    extern fn SDL_GameControllerUpdate() void;
    extern fn SDL_PollEvent(event: *SDL_Event) c_int;
    // Count of currently-attached joysticks; used to enumerate controllers
    // already plugged in at startup (SDL does not emit CONTROLLERDEVICEADDED
    // for those). Returns a negative value on error.
    extern fn SDL_NumJoysticks() c_int;
    extern fn SDL_IsGameController(joystick_index: c_int) c_int; // SDL_bool (SDL_TRUE == 1)
    extern fn SDL_GameControllerOpen(joystick_index: c_int) ?*SDL_GameController;
    extern fn SDL_GameControllerClose(gamecontroller: *SDL_GameController) void;
    extern fn SDL_GameControllerName(gamecontroller: *SDL_GameController) ?[*:0]const u8;
    extern fn SDL_GameControllerGetButton(gamecontroller: *SDL_GameController, button: c_int) u8;
    extern fn SDL_GameControllerGetAxis(gamecontroller: *SDL_GameController, axis: c_int) i16;
    // Instance id of an opened controller's underlying joystick.
    extern fn SDL_GameControllerGetJoystick(gamecontroller: *SDL_GameController) ?*anyopaque;
    extern fn SDL_JoystickInstanceID(joystick: *anyopaque) i32;
} else struct {};

// ── Device table + per-frame state snapshot ─────────────────────────────
//
// SDL is pumped from one thread (the render backend's frame loop), so the
// device table and snapshots are touched single-threaded in practice. We
// still guard mutation with a tiny atomic spin lock to match the codebase's
// care (android_gamepad_state.zig) and to stay correct if a future backend
// pumps off-thread.

/// Spin lock (Zig 0.16 removed `std.Thread.Mutex`). Contention is
/// frame-rate at worst, so the spin never meaningfully busy-waits.
const SpinLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

const MAX_CANONICAL_BUTTON: u32 = 17; // highest canonical button id

/// One tracked controller slot.
const Slot = struct {
    /// `null` when the slot is free.
    controller: ?*anyopaque = null,
    /// SDL joystick instance id, used to match REMOVED events to a slot.
    instance_id: i32 = 0,
    /// Edge-detection snapshot of canonical buttons 1..17 from the PREVIOUS
    /// `update()`, for `isButtonPressed`. Index 0 unused.
    prev_buttons: [MAX_CANONICAL_BUTTON + 1]bool = [_]bool{false} ** (MAX_CANONICAL_BUTTON + 1),
    /// Current-frame snapshot of canonical buttons (refreshed each `update()`).
    cur_buttons: [MAX_CANONICAL_BUTTON + 1]bool = [_]bool{false} ** (MAX_CANONICAL_BUTTON + 1),
};

const State = struct {
    initialized: bool = false,
    init_failed: bool = false,
    slots: [MAX_GAMEPADS]Slot = [_]Slot{.{}} ** MAX_GAMEPADS,
    // Pending hotplug events drained by pollEvents (filled in update()).
    events: [RING_CAPACITY]GamepadEvent = undefined,
    events_head: usize = 0,
    events_len: usize = 0,
    lock: SpinLock = .{},

    const RING_CAPACITY = 32;

    fn pushEvent(self: *State, ev: GamepadEvent) void {
        if (self.events_len == RING_CAPACITY) {
            self.events_head = (self.events_head + 1) % RING_CAPACITY;
            self.events_len -= 1;
        }
        const tail = (self.events_head + self.events_len) % RING_CAPACITY;
        self.events[tail] = ev;
        self.events_len += 1;
    }

    fn drainEvents(self: *State, out: []GamepadEvent) usize {
        const n = @min(out.len, self.events_len);
        for (0..n) |i| out[i] = self.events[(self.events_head + i) % RING_CAPACITY];
        self.events_head = (self.events_head + n) % RING_CAPACITY;
        self.events_len -= n;
        return n;
    }

    /// Lowest free slot index, or null if the table is full.
    fn freeSlot(self: *const State) ?usize {
        for (self.slots, 0..) |s, i| {
            if (s.controller == null) return i;
        }
        return null;
    }

    fn slotForInstance(self: *const State, instance_id: i32) ?usize {
        for (self.slots, 0..) |s, i| {
            if (s.controller != null and s.instance_id == instance_id) return i;
        }
        return null;
    }
};

var state: State = .{};

/// Opt-in for SDL's HIDAPI raw-HID driver (Switch/8BitDo decode). OFF by
/// default because HIDAPI's per-connect device init blocks the calling thread
/// for seconds on some platforms. The backend's `input.zig` assigns this from
/// its `build_options.gamepad_hidapi` (a comptime-constant bool) on the render
/// thread before every SDL-source pump — idempotent, so the effective value is
/// fixed; only the FIRST pump's `ensureInit` reads it (later writes are no-ops
/// once SDL is initialized). Left at the default it stays off (native OS
/// driver, no connect hitch). Plain `var` (not atomic): writer and reader are
/// the same render thread.
pub var hidapi_enabled: bool = false;

// ── SDL plumbing (desktop only) ─────────────────────────────────────────

/// Lazily init the SDL joystick/gamecontroller subsystems (no video, no
/// window). Returns false if init failed (state queries then read as empty).
fn ensureInit() bool {
    if (comptime !is_desktop) return false;

    // Guard the whole init under `state.lock`: it flips `initialized`/
    // `init_failed` and (via the startup enumeration below) mutates
    // `state.slots` and the event ring. Without this, a backend that pumps
    // `update()` off-thread could race init against a concurrent query.
    // `ensureInit` is only ever called from `init()` and from the TOP of
    // `update()` *before* it takes its own lock, and `openController` is a
    // caller-holds-lock helper that never re-locks — so this cannot
    // self-deadlock the non-reentrant spin lock.
    state.lock.lock();
    defer state.lock.unlock();

    if (state.initialized) return true;
    if (state.init_failed) return false;

    // HIDAPI decodes Nintendo/8BitDo Switch-mode pads via SDL's raw-HID
    // driver, but its per-connect device init blocks the calling thread for
    // ~2-3s on some platforms (notably macOS Bluetooth Xbox pads), stalling
    // the render loop on every controller connect. It is therefore OFF by
    // default; opt in via the `gamepad_hidapi` build option (set from
    // `.gamepad_hidapi = true` in project.labelle) when Switch-mode raw-HID
    // decode is needed and the connect hitch is acceptable. The flag is
    // pushed in by the backend's `input.zig` from `build_options` before the
    // first `update()` triggers this lazy init.
    _ = sdl.SDL_SetHint(sdl.SDL_HINT_JOYSTICK_HIDAPI, if (hidapi_enabled) "1" else "0");
    const rc = sdl.SDL_InitSubSystem(sdl.SDL_INIT_GAMECONTROLLER | sdl.SDL_INIT_JOYSTICK);
    if (rc != 0) {
        state.init_failed = true;
        return false;
    }
    state.initialized = true;

    // SDL does NOT emit `SDL_CONTROLLERDEVICEADDED` for controllers that were
    // already plugged in before the subsystem came up, so a pad connected at
    // launch would never be tracked. Walk the currently-attached joysticks and
    // open the game controllers via the SAME `openController` path the ADDED
    // event uses, so each emits a `.connected` event that `pollEvents` then
    // drains. This runs exactly once, here, where the init guard flips.
    // `SDL_NumJoysticks` can return negative on error; the `i < n` loop is a
    // no-op in that case.
    const n = sdl.SDL_NumJoysticks();
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        // `openController` re-checks `SDL_IsGameController` itself, but gate
        // here too so we only touch device indices SDL reports as controllers.
        if (sdl.SDL_IsGameController(i) != 0) openController(i);
    }

    return true;
}

/// Open the controller at SDL joystick index `joystick_index`, assign it the
/// lowest free slot, and queue a `.connected` event. No-op if not a game
/// controller, already tracked, or the table is full.
fn openController(joystick_index: c_int) void {
    if (comptime !is_desktop) return;
    if (sdl.SDL_IsGameController(joystick_index) == 0) return;

    const slot_idx = state.freeSlot() orelse return;
    const ctrl = sdl.SDL_GameControllerOpen(joystick_index) orelse return;

    // A null joystick can't yield a usable instance id; defaulting to 0 would
    // collide with a real instance id 0. Close the handle and bail instead.
    const js = sdl.SDL_GameControllerGetJoystick(ctrl) orelse {
        sdl.SDL_GameControllerClose(ctrl);
        return;
    };
    const instance_id: i32 = sdl.SDL_JoystickInstanceID(js);

    // Reject duplicates (SDL can re-emit ADDED on remap); close the extra handle.
    if (state.slotForInstance(instance_id) != null) {
        sdl.SDL_GameControllerClose(ctrl);
        return;
    }

    state.slots[slot_idx] = .{ .controller = ctrl, .instance_id = instance_id };

    const name_ptr = sdl.SDL_GameControllerName(ctrl);
    var ev = GamepadEvent{ .kind = .connected, .slot = @intCast(slot_idx) };
    if (name_ptr) |p| {
        const name = std.mem.span(p);
        ev.setName(name);
        ev.type_hint = typeHintFromName(name);
    }
    ev.source_class = .gamepad;
    state.pushEvent(ev);
}

/// Close the controller whose joystick instance id is `instance_id`, free its
/// slot, and queue a `.disconnected` event.
fn closeController(instance_id: i32) void {
    if (comptime !is_desktop) return;
    const slot_idx = state.slotForInstance(instance_id) orelse return;
    if (state.slots[slot_idx].controller) |ctrl| {
        sdl.SDL_GameControllerClose(@ptrCast(ctrl));
    }
    state.slots[slot_idx] = .{};
    state.pushEvent(GamepadEvent.disconnected(@intCast(slot_idx)));
}

/// Refresh the per-slot button snapshot for edge detection. Reads BOTH the
/// digital buttons (via `SDL_GameControllerGetButton`) and the synthesized
/// analog-trigger buttons (from the trigger axes crossing the threshold).
fn refreshSnapshots() void {
    if (comptime !is_desktop) return;
    for (&state.slots) |*s| {
        const ctrl = s.controller orelse continue;
        s.prev_buttons = s.cur_buttons;
        var cur = [_]bool{false} ** (MAX_CANONICAL_BUTTON + 1);

        var sdl_btn: c_int = 0;
        while (sdl_btn < SDL_CONTROLLER_BUTTON_MAX) : (sdl_btn += 1) {
            if (sdlButtonToCanonical(sdl_btn)) |canon| {
                if (sdl.SDL_GameControllerGetButton(@ptrCast(ctrl), sdl_btn) != 0) {
                    cur[canon] = true;
                }
            }
        }
        // Synthesize analog-trigger buttons from the trigger axes.
        const lt = normalizeAxis(sdl.SDL_GameControllerGetAxis(@ptrCast(ctrl), SDL_CONTROLLER_AXIS_TRIGGERLEFT), true);
        const rt = normalizeAxis(sdl.SDL_GameControllerGetAxis(@ptrCast(ctrl), SDL_CONTROLLER_AXIS_TRIGGERRIGHT), true);
        if (lt >= TRIGGER_BUTTON_THRESHOLD) cur[Button.left_trigger_2] = true;
        if (rt >= TRIGGER_BUTTON_THRESHOLD) cur[Button.right_trigger_2] = true;

        s.cur_buttons = cur;
    }
}

pub const Source = struct {
    /// Lazily inits SDL on first use.
    pub fn init() void {
        if (comptime is_desktop) _ = ensureInit();
    }

    /// Close all controllers and shut down the SDL subsystems.
    pub fn deinit() void {
        // Take `state.lock` for the whole teardown so it can't race a
        // concurrent `update()`/`pollEvents()`/query off another thread,
        // matching this file's locking discipline. The teardown closes SDL
        // controllers INLINE (it does not call `closeController`, which also
        // takes `state.lock`), so holding the lock here cannot self-deadlock
        // the non-reentrant spin lock.
        state.lock.lock();
        defer state.lock.unlock();

        if (comptime is_desktop) {
            if (state.initialized) {
                for (&state.slots) |*s| {
                    if (s.controller) |ctrl| sdl.SDL_GameControllerClose(@ptrCast(ctrl));
                    s.* = .{};
                }
                sdl.SDL_QuitSubSystem(sdl.SDL_INIT_GAMECONTROLLER | sdl.SDL_INIT_JOYSTICK);
            }
        }
        state.events_head = 0;
        state.events_len = 0;
        state.initialized = false;
        state.init_failed = false;
    }

    /// Pump SDL once per frame: process the event queue (hotplug) and refresh
    /// the button snapshots used for `isButtonPressed` edge detection.
    pub fn update() void {
        if (comptime !is_desktop) return;
        if (!ensureInit()) return;

        state.lock.lock();
        defer state.lock.unlock();

        sdl.SDL_GameControllerUpdate();

        var ev: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                sdl.SDL_CONTROLLERDEVICEADDED => openController(ev.cdevice.which),
                sdl.SDL_CONTROLLERDEVICEREMOVED => closeController(ev.cdevice.which),
                else => {},
            }
        }

        refreshSnapshots();
    }

    /// Drain queued hotplug events. Returns the count written to `out`.
    pub fn pollEvents(out: []GamepadEvent) usize {
        if (comptime !is_desktop) return 0;
        state.lock.lock();
        defer state.lock.unlock();
        return state.drainEvents(out);
    }

    /// True if a controller is connected in `slot`.
    pub fn isAvailable(slot: u32) bool {
        if (comptime !is_desktop) return false;
        if (slot >= MAX_GAMEPADS) return false;
        state.lock.lock();
        defer state.lock.unlock();
        return state.slots[slot].controller != null;
    }

    /// True while canonical `button` is held on `slot`.
    pub fn isButtonDown(slot: u32, button: u32) bool {
        if (comptime !is_desktop) return false;
        if (slot >= MAX_GAMEPADS or button == 0 or button > MAX_CANONICAL_BUTTON) return false;
        state.lock.lock();
        defer state.lock.unlock();
        return state.slots[slot].cur_buttons[button];
    }

    /// True on the frame `button` transitions from up to down on `slot`.
    /// Edge is computed from the snapshot taken in the most recent `update()`.
    pub fn isButtonPressed(slot: u32, button: u32) bool {
        if (comptime !is_desktop) return false;
        if (slot >= MAX_GAMEPADS or button == 0 or button > MAX_CANONICAL_BUTTON) return false;
        state.lock.lock();
        defer state.lock.unlock();
        const s = &state.slots[slot];
        return s.cur_buttons[button] and !s.prev_buttons[button];
    }

    /// Normalized value of canonical `axis` on `slot`: sticks in [-1,1],
    /// triggers in [0,1]. Returns 0 for unavailable slots / unknown axes.
    pub fn axisValue(slot: u32, axis: u32) f32 {
        if (comptime !is_desktop) return 0;
        if (slot >= MAX_GAMEPADS) return 0;
        state.lock.lock();
        defer state.lock.unlock();
        const ctrl = state.slots[slot].controller orelse return 0;
        const sdl_axis = canonicalAxisToSdl(axis) orelse return 0;
        const raw = sdl.SDL_GameControllerGetAxis(@ptrCast(ctrl), sdl_axis);
        return normalizeAxis(raw, isTriggerAxis(axis));
    }

    /// Diagnostic enumeration: one entry per slot (0..MAX_GAMEPADS-1), in
    /// slot order, with `connected=false` for free slots — matching the
    /// fixed-slot snapshot the raylib backend's `describeGamepads` documents.
    /// Free slots are emitted with an empty name and default source class.
    pub fn describe(out: []GamepadDescription) usize {
        if (comptime !is_desktop) return 0;
        state.lock.lock();
        defer state.lock.unlock();
        var n: usize = 0;
        for (state.slots, 0..) |s, i| {
            if (n >= out.len) break;
            var d = GamepadDescription{ .slot = @intCast(i), .connected = s.controller != null };
            if (s.controller) |ctrl| {
                if (sdl.SDL_GameControllerName(@ptrCast(ctrl))) |p| {
                    const name = std.mem.span(p);
                    d.setName(name);
                    d.type_hint = typeHintFromName(name);
                }
                d.source_class = .gamepad;
            }
            out[n] = d;
            n += 1;
        }
        return n;
    }
};

// ── Unit tests (host-runnable — exercise the pure mapping, not SDL) ──────

test "every SDL button maps to the canonical (Google/Xbox physical) layout" {
    try std.testing.expectEqual(@as(?u32, Button.right_face_down), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_A));
    try std.testing.expectEqual(@as(?u32, Button.right_face_right), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_B));
    try std.testing.expectEqual(@as(?u32, Button.right_face_left), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_X));
    try std.testing.expectEqual(@as(?u32, Button.right_face_up), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_Y));
    try std.testing.expectEqual(@as(?u32, Button.left_face_up), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_DPAD_UP));
    try std.testing.expectEqual(@as(?u32, Button.left_face_down), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_DPAD_DOWN));
    try std.testing.expectEqual(@as(?u32, Button.left_face_left), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_DPAD_LEFT));
    try std.testing.expectEqual(@as(?u32, Button.left_face_right), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_DPAD_RIGHT));
    try std.testing.expectEqual(@as(?u32, Button.left_trigger_1), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_LEFTSHOULDER));
    try std.testing.expectEqual(@as(?u32, Button.right_trigger_1), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER));
    try std.testing.expectEqual(@as(?u32, Button.left_thumb), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_LEFTSTICK));
    try std.testing.expectEqual(@as(?u32, Button.right_thumb), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_RIGHTSTICK));
    try std.testing.expectEqual(@as(?u32, Button.middle_left), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_BACK));
    try std.testing.expectEqual(@as(?u32, Button.middle), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_GUIDE));
    try std.testing.expectEqual(@as(?u32, Button.middle_right), sdlButtonToCanonical(SDL_CONTROLLER_BUTTON_START));
}

test "unmapped SDL buttons return null" {
    try std.testing.expectEqual(@as(?u32, null), sdlButtonToCanonical(15)); // MISC1
    try std.testing.expectEqual(@as(?u32, null), sdlButtonToCanonical(-1)); // SDL_CONTROLLER_BUTTON_INVALID
    try std.testing.expectEqual(@as(?u32, null), sdlButtonToCanonical(99));
}

test "canonicalButtonToSdl is the inverse for digital buttons" {
    var sdl_btn: c_int = 0;
    while (sdl_btn < SDL_CONTROLLER_BUTTON_DPAD_RIGHT + 1) : (sdl_btn += 1) {
        if (sdlButtonToCanonical(sdl_btn)) |canon| {
            try std.testing.expectEqual(@as(?c_int, sdl_btn), canonicalButtonToSdl(canon));
        }
    }
    // The synthesized analog-trigger buttons have no SDL *button* source.
    try std.testing.expectEqual(@as(?c_int, null), canonicalButtonToSdl(Button.left_trigger_2));
    try std.testing.expectEqual(@as(?c_int, null), canonicalButtonToSdl(Button.right_trigger_2));
}

test "every SDL axis maps to the canonical axis number" {
    try std.testing.expectEqual(@as(?u32, Axis.left_x), sdlAxisToCanonical(SDL_CONTROLLER_AXIS_LEFTX));
    try std.testing.expectEqual(@as(?u32, Axis.left_y), sdlAxisToCanonical(SDL_CONTROLLER_AXIS_LEFTY));
    try std.testing.expectEqual(@as(?u32, Axis.right_x), sdlAxisToCanonical(SDL_CONTROLLER_AXIS_RIGHTX));
    try std.testing.expectEqual(@as(?u32, Axis.right_y), sdlAxisToCanonical(SDL_CONTROLLER_AXIS_RIGHTY));
    try std.testing.expectEqual(@as(?u32, Axis.left_trigger), sdlAxisToCanonical(SDL_CONTROLLER_AXIS_TRIGGERLEFT));
    try std.testing.expectEqual(@as(?u32, Axis.right_trigger), sdlAxisToCanonical(SDL_CONTROLLER_AXIS_TRIGGERRIGHT));
    try std.testing.expectEqual(@as(?u32, null), sdlAxisToCanonical(-1));
    try std.testing.expectEqual(@as(?u32, null), sdlAxisToCanonical(99));
}

test "normalizeAxis: sticks span [-1,1] with exact endpoints and zero" {
    try std.testing.expectEqual(@as(f32, 0), normalizeAxis(0, false));
    try std.testing.expectEqual(@as(f32, 1), normalizeAxis(32767, false));
    try std.testing.expectEqual(@as(f32, -1), normalizeAxis(-32768, false));
    // Half-deflection is roughly +/- 0.5.
    try std.testing.expect(@abs(normalizeAxis(16384, false) - 0.5) < 0.01);
    try std.testing.expect(@abs(normalizeAxis(-16384, false) + 0.5) < 0.01);
}

test "normalizeAxis: triggers rest at 0 and span [0,1]" {
    try std.testing.expectEqual(@as(f32, 0), normalizeAxis(0, true));
    try std.testing.expectEqual(@as(f32, 1), normalizeAxis(32767, true));
    // A negative raw (shouldn't happen for triggers) clamps to 0, never negative.
    try std.testing.expectEqual(@as(f32, 0), normalizeAxis(-5000, true));
    try std.testing.expect(@abs(normalizeAxis(16384, true) - 0.5) < 0.01);
}

test "trigger threshold synthesizes the analog-trigger button at >= 0.5" {
    // Just below threshold → not pressed; at/above → pressed.
    const below = normalizeAxis(16000, true); // ~0.488
    const at = normalizeAxis(16384, true); // ~0.500
    try std.testing.expect(below < TRIGGER_BUTTON_THRESHOLD);
    try std.testing.expect(at >= TRIGGER_BUTTON_THRESHOLD);
}

test "isTriggerAxis classifies only the two triggers" {
    try std.testing.expect(isTriggerAxis(Axis.left_trigger));
    try std.testing.expect(isTriggerAxis(Axis.right_trigger));
    try std.testing.expect(!isTriggerAxis(Axis.left_x));
    try std.testing.expect(!isTriggerAxis(Axis.right_y));
}

test "typeHintFromName recognizes vendor families" {
    try std.testing.expectEqual(TypeHint.xbox, typeHintFromName("Xbox Wireless Controller"));
    try std.testing.expectEqual(TypeHint.playstation, typeHintFromName("DualSense Wireless Controller"));
    try std.testing.expectEqual(TypeHint.nintendo, typeHintFromName("Pro Controller"));
    try std.testing.expectEqual(TypeHint.nintendo, typeHintFromName("8BitDo SN30 Pro"));
    try std.testing.expectEqual(TypeHint.generic, typeHintFromName("Some Generic Pad"));
}

test "state queries are safe (and empty) on the host with no SDL pump" {
    // No `update()` has run / no controllers; every query must be safe.
    try std.testing.expect(!Source.isAvailable(0));
    try std.testing.expect(!Source.isButtonDown(0, Button.right_face_down));
    try std.testing.expect(!Source.isButtonPressed(0, Button.right_face_down));
    try std.testing.expectEqual(@as(f32, 0), Source.axisValue(0, Axis.left_x));
    // Out-of-range slot / button are safe no-ops.
    try std.testing.expect(!Source.isAvailable(99));
    try std.testing.expect(!Source.isButtonDown(0, 0));
    try std.testing.expect(!Source.isButtonDown(0, 9999));
    try std.testing.expectEqual(@as(f32, 0), Source.axisValue(99, 0));
    var ebuf: [4]GamepadEvent = undefined;
    _ = Source.pollEvents(&ebuf);
}
