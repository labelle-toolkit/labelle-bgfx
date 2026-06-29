const std = @import("std");
const builtin = @import("builtin");

/// Shared windowless-SDL desktop gamepad source (core#28 relocation).
///
/// Exposes ONE `sdl_gamepad` module that BOTH the raylib and sokol desktop
/// backends depend on (each via `.path = "../sdl_gamepad"` in its
/// `build.zig.zon`). The module imports labelle-core under the `"labelle_core"`
/// key for the `GamepadEvent`/`GamepadDescription` contract; the consuming
/// backend `overrideImport`s its OWN unified core onto this module so the
/// event types unify across the engine↔backend boundary (mirrors the
/// `overrideImport(backend_input, ...)` discipline in the generated build).
///
/// Standalone (`cd backends/sdl_gamepad && zig build test`): the host test
/// links SDL2 so the gated `extern fn SDL_*` symbols resolve, and resolves
/// labelle-core via this package's own pin.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL2 install prefix. On Linux/Windows SDL2 lives in system search paths;
    // on macOS it is under Homebrew (`/opt/homebrew` Apple Silicon,
    // `/usr/local` Intel) which Zig does not search by default. Auto-detect on
    // a native macOS host; override with `-Dsdl-prefix=...`.
    const sdl_prefix: []const u8 = b.option(
        []const u8,
        "sdl-prefix",
        "SDL2 install prefix (auto-detected on macOS Homebrew, unused on Linux/Windows)",
    ) orelse detectSdlPrefix(target.result.os.tag, builtin.target.os.tag);

    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

    // ── The shared module consumed by raylib + sokol backends ───────────
    const mod = b.addModule("sdl_gamepad", .{
        .root_source_file = b.path("src/sdl_gamepad.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("labelle_core", core_mod);

    // True when the *target* is a native desktop OS (matches the source's
    // comptime `is_desktop`): only then are the SDL `extern`s referenced and
    // only then must the test binary link SDL2. Cross-compiling the tests to a
    // non-desktop target (android/wasm) must pull in NO SDL.
    const target_is_desktop = switch (target.result.os.tag) {
        .macos, .windows, .linux => target.result.abi != .android and
            target.result.abi != .androideabi and
            !target.result.cpu.arch.isWasm(),
        else => false,
    };

    // ── Host tests ──────────────────────────────────────────────────────
    // Exercise the pure mapping helpers + the call-safety of the state
    // queries. The state queries reference (but, with no controllers, never
    // call) the SDL externs, so the test binary must link SDL2 on a desktop
    // target. No live controller is required — headless reads zero.
    const test_step = b.step("test", "Run sdl_gamepad unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdl_gamepad.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle_core", .module = core_mod },
            },
        }),
    });
    if (target_is_desktop) {
        if (sdl_prefix.len != 0) {
            tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdl_prefix, "lib" }) });
        }
        tests.root_module.linkSystemLibrary("SDL2", .{});
        tests.root_module.link_libc = true;
    }
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // ── Cross-compile gating object (no SDL link) ───────────────────────
    // Emits the module as an object for the requested target WITHOUT linking
    // SDL. On a non-desktop target the source's `is_desktop` is false, so the
    // emitted object must contain NO undefined `SDL_*` symbols. Verify with:
    //   zig build gating-obj -Dtarget=aarch64-linux-android
    //   nm -u zig-out/lib/libsdl_gamepad_gating.a | grep -i sdl   # empty
    const gating_obj = b.addObject(.{
        .name = "sdl_gamepad_gating",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdl_gamepad.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle_core", .module = core_mod },
            },
        }),
    });
    const gating_step = b.step("gating-obj", "Emit the module as an object (no SDL link) for cross-compile symbol gating");
    const install_obj = b.addInstallBinFile(gating_obj.getEmittedBin(), "sdl_gamepad_gating.o");
    gating_step.dependOn(&install_obj.step);
}

/// Best-effort SDL2 prefix detection for a NATIVE macOS host build only.
/// Returns "" when cross-compiling or on Linux/Windows (system search). No
/// `@cImport`/include path is needed — the source uses `extern fn`, so only
/// the library path matters for the link.
fn detectSdlPrefix(target_os: std.Target.Os.Tag, host_os: std.Target.Os.Tag) []const u8 {
    if (target_os != .macos or host_os != .macos) return "";
    if (dirExists("/opt/homebrew/lib")) return "/opt/homebrew";
    if (dirExists("/usr/local/lib")) return "/usr/local";
    return "";
}

fn dirExists(path: []const u8) bool {
    // std.fs.cwd() was removed in 0.16; the build runner doesn't link libc.
    // Use an ad-hoc Io.Threaded to probe the absolute path.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}
