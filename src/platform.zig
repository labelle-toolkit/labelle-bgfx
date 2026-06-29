//! Platform-window-handle dispatch for the bgfx backend.
//!
//! bgfx's `PlatformData.nwh` / `.ndt` fields must be filled with the
//! right native handles for the build target — Cocoa on macOS, HWND on
//! Windows, X11 or Wayland on Linux/BSD. zglfw exposes accessors for all
//! of them as compile-time-dispatched `pub const`s, but the bgfx backend
//! was unconditionally calling `glfw.getCocoaWindow()`, which returns a
//! stub `null` on non-macOS and leaves bgfx looking at a null handle at
//! runtime (blank/white window or init failure, depending on the
//! platform).
//!
//! This file isolates the *decision* of which source to use so it can
//! be unit-tested without pulling the entire zglfw / zbgfx build graph
//! into the test binary.
const std = @import("std");

/// Which native-window-handle accessor to invoke. The `window.zig`
/// caller holds the actual GLFW `*Window` pointer and calls the
/// matching zglfw function.
pub const WindowHandleSource = enum {
    /// macOS: `getCocoaWindow(win)` → `NSWindow *`. `ndt` is null.
    cocoa,
    /// Windows: `getWin32Window(win)` → `HWND`. `ndt` is null.
    win32,
    /// Linux/BSD X11: `getX11Window(win)` → `u32` (XID, cast to ptr).
    /// `ndt` is `getX11Display()`.
    x11,
    /// Linux/BSD Wayland: `getWaylandWindow(win)` → `*wl_surface`.
    /// `ndt` is `getWaylandDisplay()`. Not yet wired in window.zig —
    /// X11 is the default Linux path for compatibility.
    wayland,
    /// OS the bgfx backend doesn't know how to bind. Should trigger
    /// `@compileError` at the call site.
    unsupported,
};

/// Map a target OS to the window-handle source this backend uses.
pub fn windowHandleSourceFor(os_tag: std.Target.Os.Tag) WindowHandleSource {
    return switch (os_tag) {
        .macos => .cocoa,
        .windows => .win32,
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => .x11,
        else => .unsupported,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "windowHandleSourceFor: macos picks cocoa" {
    try std.testing.expectEqual(WindowHandleSource.cocoa, windowHandleSourceFor(.macos));
}

test "windowHandleSourceFor: windows picks win32" {
    try std.testing.expectEqual(WindowHandleSource.win32, windowHandleSourceFor(.windows));
}

test "windowHandleSourceFor: linux picks x11" {
    try std.testing.expectEqual(WindowHandleSource.x11, windowHandleSourceFor(.linux));
}

test "windowHandleSourceFor: freebsd picks x11" {
    try std.testing.expectEqual(WindowHandleSource.x11, windowHandleSourceFor(.freebsd));
}

test "windowHandleSourceFor: openbsd picks x11" {
    try std.testing.expectEqual(WindowHandleSource.x11, windowHandleSourceFor(.openbsd));
}

test "windowHandleSourceFor: netbsd picks x11" {
    try std.testing.expectEqual(WindowHandleSource.x11, windowHandleSourceFor(.netbsd));
}

test "windowHandleSourceFor: dragonfly picks x11" {
    try std.testing.expectEqual(WindowHandleSource.x11, windowHandleSourceFor(.dragonfly));
}

test "windowHandleSourceFor: wasi is unsupported" {
    try std.testing.expectEqual(WindowHandleSource.unsupported, windowHandleSourceFor(.wasi));
}

test "windowHandleSourceFor: ios is unsupported" {
    // bgfx does support iOS via Metal but this backend doesn't bind
    // it; classify as unsupported so the mistake is caught at compile
    // time rather than running with a bogus handle.
    try std.testing.expectEqual(WindowHandleSource.unsupported, windowHandleSourceFor(.ios));
}
