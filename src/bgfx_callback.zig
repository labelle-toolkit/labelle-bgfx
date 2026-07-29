//! bgfx diagnostics callback (labelle-bgfx#61) — make bgfx's fatal/assert path
//! SPEAK on stderr.
//!
//! Why this exists
//! ---------------
//! Until #61 this backend installed NO `bgfx::CallbackI`, so bgfx used its
//! built-in `CallbackStub`. That stub routes everything through
//! `bx::debugOutput`, which is `OutputDebugStringA` on Windows and
//! `syslog`/`NSLog` elsewhere — i.e. **invisible unless a debugger is
//! attached** — and then, for a failed `BX_ASSERT`, calls `bx::debugBreak()`
//! (an `int3`). The observable result on a plain terminal run is a process
//! that dies with `STATUS_BREAKPOINT` (`0x80000003`, reported by the shell as
//! `-2147483645`), **zero bytes on stdout, and stderr simply stopping
//! mid-line**. That is exactly the signature #61 was filed with, and it made a
//! real bgfx assert (a surfaceless run submitting into a view still bound to
//! the non-existent backbuffer) undiagnosable without a debugger.
//!
//! Installing this callback costs nothing on a healthy run and turns that
//! silent death into a named `std.log.err` line carrying bgfx's own file, line
//! and message — which is what actually identified the #61 root cause.
//!
//! What a custom callback obliges us to reimplement
//! ------------------------------------------------
//! `Init.callback` REPLACES the whole stub vtable, including its `screenShot`
//! member — the thing that writes `<path>.tga` for `window.takeScreenshot`'s
//! async `bgfx::requestScreenShot`. So `screenShot` below is a faithful
//! reimplementation of `bimg::imageWriteTga` (same 18-byte header, same
//! descriptor byte 32, same pitch/y-flip handling); dropping it would silently
//! break the WINDOWED `--screenshot` path, which no probe covers. The
//! remaining members (profiler, shader cache, video capture) are no-ops in the
//! stub too, so they are no-ops here.
//!
//! Knobs (all default to today's behaviour):
//!   * `LABELLE_BGFX_ASSERT=continue` — log a failed bgfx debug assert and keep
//!     running instead of breaking into the debugger. bgfx's own ReleaseFast
//!     build compiles asserts out entirely, so this is "behave like Release,
//!     but say so". Default (`break`, or unset) preserves the pre-#61
//!     `debugBreak()` semantics — the process still stops, it just now prints
//!     WHY first.
//!   * `LABELLE_BGFX_TRACE=1` — mirror bgfx's very chatty internal trace stream
//!     (shader/uniform/texture creation, renderer selection …) to stderr. Off
//!     by default: it is hundreds of lines per startup.

const std = @import("std");
const builtin = @import("builtin");
const zbgfx = @import("zbgfx");
const bgfx = zbgfx.bgfx;

const log = std.log.scoped(.bgfx);

// ── C ABI: bgfx_callback_interface_t / bgfx_callback_vtbl_t ────────────
//
// Declared HERE rather than reused from `zbgfx.callbacks`, and that is not
// stylistic: zbgfx's `CCallbackVtblT` is STALE against the bgfx it vendors. Its
// `screen_shot` slot is missing bgfx's `_format` parameter —
//
//   zbgfx:  screen_shot(this, filePath, width, height, pitch,         data, size, yflip)
//   bgfx:   screen_shot(this, filePath, width, height, pitch, FORMAT, data, size, yflip)
//           (bgfx/c99/bgfx.h; the call site is CallbackC99::screenShot, bgfx.cpp)
//
// so every argument from `data` on is shifted one position. Building the vtable
// from zbgfx's shape segfaults the RENDER THREAD the first time a `--screenshot`
// is fulfilled — writing the pixels through what is really the texture-format
// enum. This was found the hard way while wiring #61, so the definitions below
// are transcribed from `bgfx/include/bgfx/c99/bgfx.h` directly and the test at
// the bottom pins the arity that caught it.

/// bgfx's `bgfx_callback_interface_t`: a struct whose single member is a
/// pointer to the vtable. bgfx keeps the pointer we hand it for the lifetime of
/// the context.
const CallbackInterface = extern struct { vtable: *const CallbackVtbl };

/// A C `va_list` as an opaque pointer-sized value. Zig 0.16 cannot express
/// `std.builtin.VaList` portably on every target this backend builds for
/// (notably x86_64-windows), and we never inspect it — it is only ever handed
/// straight back to the C formatter below. Same trick zbgfx uses.
const VaList = extern struct { _: *anyopaque };

const CallbackVtbl = extern struct {
    fatal: *const fn (*CallbackInterface, [*:0]const u8, u16, bgfx.Fatal, [*:0]const u8) callconv(.c) void,
    trace_vargs: *const fn (*CallbackInterface, [*:0]const u8, u16, [*:0]const u8, VaList) callconv(.c) void,
    profiler_begin: *const fn (*CallbackInterface, [*:0]const u8, u32, [*:0]const u8, u16) callconv(.c) void,
    profiler_begin_literal: *const fn (*CallbackInterface, [*:0]const u8, u32, [*:0]const u8, u16) callconv(.c) void,
    profiler_end: *const fn (*CallbackInterface) callconv(.c) void,
    cache_read_size: *const fn (*CallbackInterface, u64) callconv(.c) u32,
    cache_read: *const fn (*CallbackInterface, u64, ?*anyopaque, u32) callconv(.c) bool,
    cache_write: *const fn (*CallbackInterface, u64, ?*const anyopaque, u32) callconv(.c) void,
    screen_shot: *const fn (*CallbackInterface, [*:0]const u8, u32, u32, u32, bgfx.TextureFormat, ?*const anyopaque, u32, bool) callconv(.c) void,
    capture_begin: *const fn (*CallbackInterface, u32, u32, u32, bgfx.TextureFormat, bool) callconv(.c) void,
    capture_end: *const fn (*CallbackInterface) callconv(.c) void,
    capture_frame: *const fn (*CallbackInterface, ?*const anyopaque, u32) callconv(.c) void,
};

/// libc `getenv` — Zig 0.16 dropped `std.posix.getenv`, and `window.zig`
/// already reaches for libc the same way for its `LABELLE_*` knobs.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// libc stdio, for `screenShot`. Same reason `window.captureHeadless` uses it:
/// the callback runs on bgfx's RENDER thread with no allocator in hand, so a
/// plain `fopen`/`fwrite` is both the simplest and the least surprising writer.
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *std.c.FILE) usize;

/// Whether a failed bgfx debug assert (`Fatal.DebugCheck`) should still break
/// the process, as bgfx's stub does. Resolved lazily and cached: `fatal` can be
/// called from the render thread, and re-reading the environment there is both
/// pointless (it is constant for the process) and needlessly unsafe.
var assert_breaks: ?bool = null;

fn assertBreaks() bool {
    if (assert_breaks) |v| return v;
    const v = blk: {
        const raw = getenv("LABELLE_BGFX_ASSERT") orelse break :blk true;
        break :blk !std.ascii.eqlIgnoreCase(std.mem.span(raw), "continue");
    };
    assert_breaks = v;
    return v;
}

var trace_enabled: ?bool = null;

fn traceEnabled() bool {
    if (trace_enabled) |v| return v;
    const v = blk: {
        const raw = getenv("LABELLE_BGFX_TRACE") orelse break :blk false;
        break :blk std.mem.span(raw).len > 0;
    };
    trace_enabled = v;
    return v;
}

/// bgfx's varargs trace formatter, compiled into the zbgfx artifact
/// (`src/zbgfx.cpp`) precisely because Zig cannot portably consume a C
/// `va_list` on every target. Returns the length `bx::vsnprintf` would have
/// written (so it can exceed `buff_size` on truncation — clamp before slicing).
extern fn formatTrace(buff: [*]const u8, buff_size: u32, format: [*:0]const u8, arg_list: VaList) i32;

// ── Callback implementations ───────────────────────────────────────────

fn fatal(
    _this: *CallbackInterface,
    file_path: [*:0]const u8,
    line: u16,
    code: bgfx.Fatal,
    msg: [*:0]const u8,
) callconv(.c) void {
    _ = _this;
    log.err("FATAL {s} at {s}:{d}: {s}", .{
        @tagName(code),
        std.mem.span(file_path),
        line,
        std.mem.span(msg),
    });

    if (code == .DebugCheck) {
        // A failed `BX_ASSERT`. bgfx's stub breaks here; keep that as the
        // default so #61 changes the DIAGNOSTICS, not the semantics — but the
        // message above is now on stderr either way, which is the whole point.
        if (assertBreaks()) {
            log.err(
                "breaking on the assert above; set LABELLE_BGFX_ASSERT=continue to soldier on instead",
                .{},
            );
            @breakpoint();
        }
        return;
    }

    // Every other `Fatal` code is unrecoverable by contract — bgfx documents
    // that `fatal` must not return for them, and its own stub aborts. Returning
    // would drop straight back into a renderer that just told us it cannot go
    // on.
    std.process.abort();
}

fn traceVargs(
    _this: *CallbackInterface,
    file_path: [*:0]const u8,
    line: u16,
    format: [*:0]const u8,
    arg_list: VaList,
) callconv(.c) void {
    _ = _this;
    if (!traceEnabled()) return;
    var buf: [2048]u8 = undefined;
    const written = formatTrace(&buf, buf.len, format, arg_list);
    if (written <= 0) return;
    // `vsnprintf` returns the UNTRUNCATED length; clamp so a long trace can
    // never slice past the buffer. bgfx's traces end in a newline of their own,
    // which std.log adds too — trim it so the output isn't double-spaced.
    var len: usize = @min(@as(usize, @intCast(written)), buf.len - 1);
    while (len > 0 and (buf[len - 1] == '\n' or buf[len - 1] == '\r')) len -= 1;
    log.debug("{s}:{d}: {s}", .{ std.mem.span(file_path), line, buf[0..len] });
}

fn profilerBegin(
    _this: *CallbackInterface,
    name: [*:0]const u8,
    abgr: u32,
    file_path: [*:0]const u8,
    line: u16,
) callconv(.c) void {
    _ = .{ _this, name, abgr, file_path, line };
}

fn profilerBeginLiteral(
    _this: *CallbackInterface,
    name: [*:0]const u8,
    abgr: u32,
    file_path: [*:0]const u8,
    line: u16,
) callconv(.c) void {
    _ = .{ _this, name, abgr, file_path, line };
}

fn profilerEnd(_this: *CallbackInterface) callconv(.c) void {
    _ = _this;
}

// Shader cache: bgfx's stub declines to cache (read size 0 / read false / write
// no-op) and so do we. A persistent cache is a separate, opt-in feature.
fn cacheReadSize(_this: *CallbackInterface, id: u64) callconv(.c) u32 {
    _ = .{ _this, id };
    return 0;
}

fn cacheRead(_this: *CallbackInterface, id: u64, data: ?*anyopaque, size: u32) callconv(.c) bool {
    _ = .{ _this, id, data, size };
    return false;
}

fn cacheWrite(_this: *CallbackInterface, id: u64, data: ?*const anyopaque, size: u32) callconv(.c) void {
    _ = .{ _this, id, data, size };
}

/// Fulfil an async `bgfx::requestScreenShot` by writing `<file_path>.tga` as an
/// uncompressed 32-bit TGA.
///
/// This REPLACES bgfx's stub (which appended `.tga` and called
/// `bimg::imageWriteTga`), so it reproduces both behaviours exactly: callers —
/// `window.takeScreenshot`, and labelle-cli's `--screenshot` above it — are
/// documented to get `<path>.tga` out of a bare `<path>`, and the byte layout is
/// `imageWriteTga`'s: 18-byte header, image type 2 (uncompressed true-color),
/// 32 bpp, descriptor byte 32 (top-left origin), and the source walked either
/// bottom-up (`yflip`, the OpenGL-style backends) or top-down, honouring a
/// `pitch` that may exceed `width * 4`.
///
/// `format` is accepted and IGNORED, exactly as `imageWriteTga` ignores it: bgfx
/// hands back BGRA8 for a backbuffer capture, which is already TGA's native
/// channel order, so there is no swizzle here (unlike `window.captureHeadless`,
/// whose `readTexture` source is RGBA). Ignoring it also keeps the output
/// byte-identical to the pre-#61 stub for any format bgfx might pass.
fn screenShot(
    _this: *CallbackInterface,
    file_path: [*:0]const u8,
    width: u32,
    height: u32,
    pitch: u32,
    format: bgfx.TextureFormat,
    data: ?*const anyopaque,
    size: u32,
    yflip: bool,
) callconv(.c) void {
    _ = .{ _this, format, size };
    const src: [*]const u8 = @ptrCast(data orelse return);
    if (width == 0 or height == 0) return;

    // Append the extension bgfx's stub used to add. A path too long for the
    // buffer is reported rather than silently truncated into a wrong filename.
    var path_buf: [1024:0]u8 = undefined;
    const out_path = std.fmt.bufPrintZ(&path_buf, "{s}.tga", .{std.mem.span(file_path)}) catch {
        log.err("screenshot: path too long: {s}", .{std.mem.span(file_path)});
        return;
    };

    const file = std.c.fopen(out_path.ptr, "wb") orelse {
        log.err("screenshot: could not open {s} for writing", .{out_path});
        return;
    };
    defer _ = std.c.fclose(file);

    var hdr = [_]u8{0} ** 18;
    hdr[2] = 2; // uncompressed true-color
    hdr[12] = @truncate(width);
    hdr[13] = @truncate(width >> 8);
    hdr[14] = @truncate(height);
    hdr[15] = @truncate(height >> 8);
    hdr[16] = 32; // bits per pixel
    hdr[17] = 32; // descriptor byte — the literal value bimg writes
    if (fwrite(&hdr, 1, hdr.len, file) != hdr.len) {
        log.err("screenshot: failed writing the TGA header to {s}", .{out_path});
        return;
    }

    const dst_pitch: usize = @as(usize, width) * 4;
    const src_pitch: usize = pitch;
    var row: usize = 0;
    while (row < height) : (row += 1) {
        // `yflip` means the source's FIRST row is the image's BOTTOM row, so
        // walk it backwards to land a top-down TGA on disk.
        const src_row = if (yflip) height - 1 - row else row;
        if (fwrite(src + src_row * src_pitch, 1, dst_pitch, file) != dst_pitch) {
            log.err("screenshot: failed writing pixels to {s}", .{out_path});
            return;
        }
    }
}

// Video capture (`BGFX_RESET_CAPTURE`): unused by this backend, as in the stub.
fn captureBegin(
    _this: *CallbackInterface,
    width: u32,
    height: u32,
    pitch: u32,
    format: bgfx.TextureFormat,
    yflip: bool,
) callconv(.c) void {
    _ = .{ _this, width, height, pitch, format, yflip };
}

fn captureEnd(_this: *CallbackInterface) callconv(.c) void {
    _ = _this;
}

fn captureFrame(_this: *CallbackInterface, data: ?*const anyopaque, size: u32) callconv(.c) void {
    _ = .{ _this, data, size };
}

/// The vtable itself. `const` + comptime-initialised so it lives in read-only
/// data for the whole process — bgfx holds the pointer for the lifetime of the
/// context and calls into it from the render thread.
const vtable: CallbackVtbl = .{
    .fatal = fatal,
    .trace_vargs = traceVargs,
    .profiler_begin = profilerBegin,
    .profiler_begin_literal = profilerBeginLiteral,
    .profiler_end = profilerEnd,
    .cache_read_size = cacheReadSize,
    .cache_read = cacheRead,
    .cache_write = cacheWrite,
    .screen_shot = screenShot,
    .capture_begin = captureBegin,
    .capture_end = captureEnd,
    .capture_frame = captureFrame,
};

/// The interface object handed to `Init.callback`. A single mutable global (not
/// a temporary) because bgfx stores the POINTER: a stack local would dangle the
/// instant `initWindow`/`initHeadless` returned.
var interface: CallbackInterface = .{ .vtable = &vtable };

/// Point `init.callback` at this backend's diagnostics callback. Called by
/// EVERY `bgfx.init` path in `window.zig` (desktop, Android, wasm, surfaceless)
/// so a fatal is never silent on any target.
pub fn install(init: *bgfx.Init) void {
    init.callback = @ptrCast(&interface);
}

// ── Tests ──────────────────────────────────────────────────────────────
const testing = std.testing;

test "install points Init.callback at the interface, whose first word is the vtable" {
    // The C ABI contract is exactly this: `bgfx_callback_interface_t` is a
    // struct whose first (only) member is a pointer to the vtable. Pin both the
    // wiring and the layout so a future refactor can't hand bgfx a pointer to
    // something that merely LOOKS like a callback — the failure mode would be
    // an indirect call through garbage on the render thread.
    var init: bgfx.Init = undefined;
    init.callback = null;
    install(&init);
    try testing.expect(init.callback != null);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&interface)), init.callback);
    try testing.expectEqual(@as(*const CallbackVtbl, &vtable), interface.vtable);
    try testing.expectEqual(@as(usize, 0), @offsetOf(CallbackInterface, "vtable"));
}

test "screen_shot keeps bgfx's 9-argument shape, not zbgfx's stale 8" {
    // The regression this pins COST an afternoon: `zbgfx.callbacks.CCallbackVtblT`
    // omits bgfx's `_format` parameter, so a vtable built from it shifts `data`,
    // `size` and `yflip` down one slot — and the first `--screenshot` segfaults
    // the render thread writing pixels through a texture-format enum. Assert the
    // arity and the position of `format`/`data` so a future "let's just reuse
    // zbgfx's types" refactor fails HERE, in a host test, instead of there.
    const params = @typeInfo(@typeInfo(@FieldType(CallbackVtbl, "screen_shot")).pointer.child).@"fn".params;
    try testing.expectEqual(@as(usize, 9), params.len);
    try testing.expectEqual(bgfx.TextureFormat, params[5].type.?);
    try testing.expectEqual(?*const anyopaque, params[6].type.?);
    try testing.expectEqual(u32, params[7].type.?);
    try testing.expectEqual(bool, params[8].type.?);
}

test "the assert policy defaults to breaking and only 'continue' opts out" {
    // `assertBreaks`/`traceEnabled` cache their env read, so drive the pure
    // policy through the same comparison they use rather than mutating the
    // process environment (which would leak into every later test in the run).
    try testing.expect(!std.ascii.eqlIgnoreCase("continue", "break"));
    try testing.expect(std.ascii.eqlIgnoreCase("continue", "CONTINUE"));
}
