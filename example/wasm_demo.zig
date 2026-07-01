//! Self-contained bgfx WebGL/wasm smoke example (bgfx-wasm epic labelle-bgfx#8).
//!
//! Proves the wasm build+link chain end-to-end WITHOUT the assembler/engine:
//!   * the wasm/WebGL-capable zbgfx `bgfx` artifact links via emcc,
//!   * `window.zig`'s emscripten init creates a WebGL2 context against the
//!     `#canvas` element (`PlatformData.nwh` = canvas selector),
//!   * the frame is driven by `emscripten_set_main_loop` (the browser owns the
//!     event loop — a blocking `while` would freeze the page),
//!   * `gfx.drawRectangleRec` submits through the sprite program (lazy shader
//!     init) so the whole render seam is exercised.
//!
//! This mirrors the shape of the assembler's `templates/wasm.txt` but uses the
//! backend's own `window` + `gfx` modules directly so it can be built by the
//! backend's `build.zig` (`zig build wasm-example`). RENDER validation needs a
//! real browser (WebGL); node prints "Noop" for the renderer.
const std = @import("std");
const window = @import("window");
const gfx = @import("backend_gfx");

const screen_w: i32 = 800;
const screen_h: i32 = 600;
const title = "labelle-bgfx — wasm/WebGL smoke";

// Hand-rolled extern shim instead of `@cImport(emscripten.h)` — Zig 0.16's
// translate-c rejects recent emsdk headers (translate-c issue #306). emcc
// resolves the symbol at link time. Mirrors templates/wasm.txt.
extern "c" fn emscripten_set_main_loop(
    func: *const fn () callconv(.c) void,
    fps: c_int,
    simulate_infinite_loop: c_int,
) void;
extern "c" fn emscripten_console_log(str: [*:0]const u8) void;

// Route std.log to emscripten's console (bgfx-wasm #8). Zig 0.16.0's DEFAULT log
// handler goes through `std.Io.Threaded`'s debug Io, which — like the default
// panic — drags in child-process wait code that does not compile for
// wasm32-emscripten. `gfx/programs.zig` calls `std.log.info` on shader init, so a
// no-op-safe logFn (formatting into a stack buffer, never `debug_io`) is required
// for the browser build to link. The assembler-generated wasm main installs the
// same override.
pub const std_options: std.Options = .{
    .logFn = wasmLog,
};

fn wasmLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrintZ(&buf, "[" ++ level.asText() ++ "] " ++ format, args) catch return;
    emscripten_console_log(line.ptr);
}

// Minimal panic handler (bgfx-wasm #8). Zig 0.16.0's DEFAULT panic
// (`std.debug.defaultPanic`) reaches `std.Io.Threaded`'s child-process wait code
// (via the debug stack-trace printer), which does not compile for
// wasm32-emscripten (a std regression: `posix.W.STOPSIG` returns `u32` but
// `statusToTerm` expects the SIG enum). Overriding the panic entry with a trap
// severs that reference so the browser build links. The assembler-generated app
// installs the same override in its wasm main (templates/wasm.txt).
pub const panic = std.debug.FullPanic(struct {
    fn handler(msg: []const u8, ret_addr: ?usize) noreturn {
        _ = msg;
        _ = ret_addr;
        @trap();
    }
}.handler);

var t: f32 = 0;

fn frame() callconv(.c) void {
    const dt: f32 = @min(@as(f32, @floatCast(window.frameDuration())), 4.0 / 60.0);
    t += dt;

    // Keep the design canvas mapped onto the live drawing buffer.
    gfx.setScreenSize(window.width(), window.height());
    gfx.setDesignSize(screen_w, screen_h);

    window.beginFrame();
    window.clearBackground(30, 30, 46, 255); // dark slate

    // A rectangle that slides across the canvas so motion is visible in-browser.
    const x = 100.0 + 200.0 * (0.5 + 0.5 * @sin(t));
    gfx.drawRectangleRec(
        .{ .x = x, .y = 240, .width = 200, .height = 120 },
        gfx.color(180, 120, 255, 255),
    );

    window.endFrame();
}

pub fn main() void {
    // c_allocator delegates to emscripten's malloc/free (respects
    // ALLOW_MEMORY_GROWTH); the page_allocator would fight emscripten's memory
    // management. (Kept even though this demo does no heap work, for parity with
    // the generated wasm template.)
    _ = std.heap.c_allocator;

    window.initWindow(screen_w, screen_h, title);
    // No `defer closeWindow()` — emscripten keeps running after main returns;
    // the main-loop callback drives the app.
    emscripten_set_main_loop(&frame, 0, 1);
}
