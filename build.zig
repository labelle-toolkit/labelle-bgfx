const std = @import("std");
const builtin = @import("builtin");

/// True when `t` is a native desktop OS (matches the shared sdl_gamepad source's
/// comptime `is_desktop`): only there are the SDL `extern`s referenced and SDL
/// must be linked. Android/iOS/wasm are excluded. Mirrors `targetIsDesktop` in
/// the raylib/sokol backend build.zig.
fn targetIsDesktop(t: std.Target) bool {
    if (t.abi == .android or t.abi == .androideabi) return false;
    if (t.cpu.arch.isWasm()) return false;
    return switch (t.os.tag) {
        .macos, .windows, .linux => true,
        else => false,
    };
}

/// macOS Homebrew SDL2 library path for a NATIVE macOS host build (Zig does
/// not search Homebrew by default). Returns null when cross-compiling or on
/// Linux/Windows (system search resolves SDL2). No include path is needed —
/// sdl_gamepad uses `extern fn`. Mirrors raylib/sokol's `sdlLibPath`.
fn sdlLibPath(io: std.Io, target_os: std.Target.Os.Tag, host_os: std.Target.Os.Tag) ?[]const u8 {
    if (target_os != .macos or host_os != .macos) return null;
    if (dirExists(io, "/opt/homebrew/lib")) return "/opt/homebrew/lib";
    if (dirExists(io, "/usr/local/lib")) return "/usr/local/lib";
    return null;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    // Reuse the build graph's `Io` rather than spinning up a fresh
    // `std.Io.Threaded` (thread pool) per probe.
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_android = target.result.os.tag == .linux and
        (target.result.abi == .android or target.result.abi == .androideabi);

    // ── WASM (Emscripten) — SKELETON, spike-blocked (bgfx-wasm epic
    // labelle-bgfx#8) ────────────────────────────────────────────────────────
    // Self-contained early branch so the DESKTOP + ANDROID graph below is
    // byte-unchanged (they never reach `buildWasm`; `is_wasm` is false for
    // them). `buildWasm` mirrors the `is_android` carve-outs (no zglfw, no
    // sdl_gamepad — both desktop-only — emsdk sysroot for the C compile) but
    // hard-fails at the load-bearing seam: HOW zbgfx exposes an
    // emscripten/WebGL-built bgfx artifact is exactly what the parallel
    // zbgfx-wasm-build spike is determining, so it is stubbed rather than
    // guessed. Desktop/android are unaffected.
    const is_wasm = target.result.cpu.arch.isWasm();
    if (is_wasm) {
        buildWasm(b, target, optimize);
        return;
    }

    // Desktop gamepad source toggle (core#28 slice 5), mirroring raylib/sokol.
    // When true (default, `.gamepad = .auto`), the shared windowless-SDL desktop
    // gamepad source is wired into `input` and SDL2 is linked on desktop, so the
    // input getters route through SDL's HIDAPI drivers (which decode Switch-mode
    // Nintendo pads GLFW can't). When false (`.gamepad = .none`), the
    // `sdl_gamepad` import is absent, no SDL2 is linked, and input.zig falls back
    // to the GLFW desktop path (#315). The assembler forwards this from the
    // generated build.zig via `b.dependency(..., .{ .gamepad_enabled = ... })`.
    const gamepad_enabled = b.option(bool, "gamepad_enabled", "Wire the shared SDL desktop gamepad source + link SDL2 (default true; false = opt out, GLFW fallback)") orelse true;
    const gamepad_hidapi = b.option(bool, "gamepad_hidapi", "Opt the SDL gamepad source into HIDAPI raw-HID decode (Switch/8BitDo); default false — HIDAPI per-connect init stalls the render thread for seconds on some platforms") orelse false;
    // When true, `input.zig` forwards the per-frame mouse/touch state to the
    // labelle-imgui bgfx bridge's `imgui_bridge_mouse_*` externs so Dear ImGui
    // widgets are interactive. OFF by default: those externs are only defined
    // when the imgui bridge artifact is linked into the final game exe, so a
    // non-imgui build must NOT reference them (it would fail to link with an
    // undefined symbol). The assembler forwards `.gui_enabled = true` from the
    // generated build.zig only when the project's gui plugin is imgui.
    const gui_enabled = b.option(bool, "gui_enabled", "Forward mouse/touch input to the imgui bridge (default false; true only when the imgui bridge is linked)") orelse false;

    const zbgfx_dep = b.dependency("zbgfx", .{ .target = target, .optimize = optimize });
    const zbgfx_mod = zbgfx_dep.module("zbgfx");
    const bgfx_artifact = zbgfx_dep.artifact("bgfx");

    // Shared audio engine (pluggable-backends RFC, Phase 2). `src/audio.zig`
    // now forwards to `labelle_audio.Mixer(device_backend)`; the device modules
    // (`audio_device.zig` / `audio_device_android.zig`) satisfy its `DeviceSink`
    // contract. Wired into the `audio` module (and the host audio test module)
    // under the `labelle-audio` import key. Resolved on every target — the
    // mixer/decoder are pure Zig and compile for Android unchanged.
    const labelle_audio_dep = b.dependency("labelle_audio", .{ .target = target, .optimize = optimize });
    const labelle_audio_mod = labelle_audio_dep.module("labelle-audio");

    // zglfw is desktop-only — it doesn't build for Android. Only fetch
    // the zglfw dependency (and its artifact) off the Android path so the
    // Android build graph never pulls it in. The window/input modules are
    // wired without the `zglfw` import for Android (they comptime-gate it
    // out; see src/window.zig + src/input.zig).
    const zglfw_dep = if (is_android) null else b.dependency("zglfw", .{ .target = target, .optimize = optimize });
    const zglfw_mod = if (zglfw_dep) |d| d.module("root") else null;
    const glfw_artifact = if (zglfw_dep) |d| d.artifact("glfw") else null;

    // ── Android: feed bgfx's C/C++ the NDK sysroot headers ──────────
    // Zig's bundled libc++ `stdlib.h` pulls in `ldiv_t`/`lldiv` from the
    // *system* C `stdlib.h`, which lives in the Android NDK sysroot — not
    // in Zig's tree. Without these include paths bx/bgfx/bimg fail to
    // compile for Android (`unknown type name 'ldiv_t'`). Mirror the
    // sokol-Android plumbing in `src/templates/build_zig.txt`. Gated on
    // the Android ABI so desktop/cross builds are untouched.
    //
    // The same `usr/include` path also exposes `android/native_window.h`
    // (for `ANativeWindow`) — phase 3 will compile the NativeActivity
    // glue against it. Phase 2 only needs the Zig modules to compile, and
    // they hand the surface across as an opaque `*anyopaque` (see
    // src/window.zig), so no C header is pulled in yet.
    //
    // `ndk` is non-null only for Android; the resolved sysroot include
    // paths are reused below to wire the Android gfx/window/input modules.
    const ndk: ?NdkPaths = if (is_android) resolveNdkPaths(b, target) else null;
    if (ndk) |n| {
        // zbgfx builds three separate static libs — `bx`, `bimg`, and
        // `bgfx` — each its own `*Compile` with its own `root_module`.
        // The consumer can only fetch the top-level `bgfx` artifact, but
        // bx/bimg are linked into it as `other_step` link objects. Walk
        // bgfx's link_objects to reach them, then apply the NDK sysroot
        // paths to every C/C++ module so all three find the Bionic
        // headers. (Include paths don't propagate across linkLibrary.)
        applyNdkSysroot(bgfx_artifact.root_module, n.inc_common, n.inc_arch, n.lib_path, n.android_api);
        for (bgfx_artifact.root_module.link_objects.items) |lo| {
            if (lo == .other_step) {
                applyNdkSysroot(lo.other_step.root_module, n.inc_common, n.inc_arch, n.lib_path, n.android_api);
            }
        }
    }

    // ── Gfx backend module ──────────────────────────────────────────
    // `link_libc = true` is required by `src/gfx/texture.zig`'s
    // libc-based file loader (post-0.16 swap from `std.fs.cwd()`) AND by
    // stb_image (malloc/free/memcpy), which is compiled in below for PNG/
    // JPG/BMP/TGA decode.
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gfx_mod.addImport("zbgfx", zbgfx_mod);
    // `@cInclude("stb_shim.h")` in gfx/texture.zig needs src/ on the
    // include path to find stb_shim.h → stb_image.h.
    gfx_mod.addIncludePath(b.path("src"));

    // Android: stb_image_impl.c (and the translate-c `@cImport` of
    // stb_shim.h in gfx/texture.zig) need the NDK sysroot system-includes
    // to find Bionic's <stdlib.h>/<string.h> etc., exactly like the
    // bgfx/bx/bimg C++ compile above. Apply the SAME `applyNdkSysroot`
    // helper. This MUST run BEFORE `addCSourceFile` so the include paths
    // are attached when the consuming Compile step collects translation
    // units (mirrors the ordering in the sokol backend's build.zig). On
    // desktop the system libc headers resolve without extra wiring.
    // (bgfx is desktop + Android only — no wasm/emsdk path, unlike sokol.)
    if (ndk) |n| applyNdkSysroot(gfx_mod, n.inc_common, n.inc_arch, n.lib_path, n.android_api);

    // stb_image implementation TU — defines STB_IMAGE_IMPLEMENTATION +
    // STBI_NO_STDIO and includes stb_image.h. This is what gives the bgfx
    // backend PNG decoding at parity with the sokol/raylib backends.
    gfx_mod.addCSourceFile(.{ .file = b.path("src/stb_image_impl.c"), .flags = &.{} });

    // Shared windowless-SDL desktop gamepad source (core#28). One copy lives
    // in `backends/sdl_gamepad/`; the raylib, sokol AND bgfx desktop backends
    // route their gamepad state/hotplug through it so the Switch/8BitDo raw-HID
    // handshake GLFW can't decode is handled once. Imported under the
    // `sdl_gamepad` key by `input.zig`. We unify labelle-core onto it (it
    // imports core under the `labelle_core` key) so the `GamepadEvent` types it
    // returns are the SAME instance `input.zig` and the engine see — without
    // this the `[]GamepadEvent` crossing the seam would not type-check.
    // Gated on `gamepad_enabled` AND a desktop target: when opted out OR on a
    // non-desktop target (Android/iOS/wasm), the sub-package is not resolved as
    // a dependency, so nothing pulls SDL into the graph and we don't require
    // `labelle_sdl_gamepad` to be staged where it's never used. (Unlike
    // raylib/sokol, bgfx routes Linux desktop through SDL too — it has no
    // labelle-core udev/evdev route wired into `input`; the GLFW path is the
    // only non-SDL fallback, used on `.gamepad = .none`.)
    const sdl_gp_mod: ?*std.Build.Module = if (gamepad_enabled and !is_android and targetIsDesktop(target.result)) blk: {
        const sdl_gp_dep = b.dependency("labelle_sdl_gamepad", .{ .target = target, .optimize = optimize });
        const m = sdl_gp_dep.module("sdl_gamepad");
        // Standalone the backend's own core pin unifies; the generated build
        // overrideImports the app's unified core onto this module (see the
        // `.backend_bgfx` template section).
        const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
        m.addImport("labelle_core", core_dep.module("labelle-core"));
        break :blk m;
    } else null;

    // `build_options` carried into `input.zig` so its comptime gamepad routing
    // knows whether `sdl_gamepad` was wired. When false, input.zig does NOT
    // `@import("sdl_gamepad")` (the module is absent) and uses the GLFW path.
    // Mirrored on the host test module below.
    const input_opts = b.addOptions();
    input_opts.addOption(bool, "gamepad_enabled", gamepad_enabled);
    input_opts.addOption(bool, "gamepad_hidapi", gamepad_hidapi);
    input_opts.addOption(bool, "gui_enabled", gui_enabled);

    // ── Input backend module ────────────────────────────────────────
    // Desktop wires the `zglfw` import for GLFW polling; Android omits it
    // (zglfw is desktop-only) and `src/input.zig` comptime-gates every
    // zglfw reference behind `is_android`.
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (zglfw_mod) |m| input_mod.addImport("zglfw", m);
    input_mod.addImport("build_options", input_opts.createModule());
    if (sdl_gp_mod) |m| input_mod.addImport("sdl_gamepad", m);

    // Link SDL2 for the shared desktop gamepad source — DESKTOP targets only,
    // and only when the gamepad source is wired (`gamepad_enabled`). The source
    // gates every SDL `extern` behind a comptime desktop check, so
    // Android/iOS/wasm builds reference no SDL symbols and pull no SDL. No
    // `@cImport`/include path is needed (the source uses `extern fn`); only the
    // link + (on macOS Homebrew) the library path matters. Mirrors raylib/sokol.
    if (sdl_gp_mod != null) {
        input_mod.link_libc = true;
        if (sdlLibPath(b.graph.io, target.result.os.tag, builtin.target.os.tag)) |p| {
            input_mod.addLibraryPath(.{ .cwd_relative = p });
        }
        // Windows: Zig has no default SDL2 search path for the MinGW
        // (`windows-gnu`) toolchain, so honor `LABELLE_SDL2_LIB` — the dir
        // holding the import lib (`libSDL2.dll.a`). `SDL2.dll` must be on PATH
        // (or beside the exe) at runtime. Gated on the TARGET os only, so it
        // also applies when cross-compiling to Windows from a non-Windows host.
        if (target.result.os.tag == .windows) {
            if (b.graph.environ_map.get("LABELLE_SDL2_LIB")) |p| {
                input_mod.addLibraryPath(.{ .cwd_relative = p });
            }
        }
        input_mod.linkSystemLibrary("SDL2", .{});
    }

    // Shared Android gamepad source (#310 Stage 4): the per-device STATE
    // machine (`android_gamepad_state.zig`, #250) and the InputManager JNI
    // DETECTION glue (`android_gamepad_jni.c`, #248), shared with the sokol
    // backend via the `../android_gamepad` sub-package. `input.zig` imports the
    // state module under `android_gamepad` (mapping + quirk + per-device button/
    // axis state) on every target — its Android-only `extern`/`@export` symbols
    // are gated internally, so off Android nothing is referenced. On Android we
    // also compile the JNI glue into THIS module (where the NDK sysroot/libc is
    // wired by `applyNdkSysroot` below). The .c is `#ifdef __ANDROID__`-gated,
    // so it emits an empty object off Android. We pull its source via
    // `dep.path(...)` because cross-package `b.path("..")` is rejected by Zig
    // 0.16.
    const android_gp_dep = b.dependency("labelle_android_gamepad", .{ .target = target, .optimize = optimize });
    input_mod.addImport("android_gamepad", android_gp_dep.module("android_gamepad"));

    // labelle-core, imported on EVERY target so `src/input.zig` can prove it
    // satisfies the engine input contract at comptime (`core.assertInput`) and
    // `src/window.zig` the window contract (`core.assertWindow`, #386 Phase 3).
    // Both asserts are comptime-only — no core type crosses the engine seam
    // through these modules on desktop — so the backend's own pin resolves them
    // standalone and the generated build needs no extra unification beyond the
    // existing Android `input` override (which exists for `AndroidBackendContext`,
    // a real type-crossing case). The single `core_mod` is shared by `input_mod`
    // and `window_mod` so they reference one module instance.
    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");
    input_mod.addImport("labelle-core", core_mod);
    // gfx.zig asserts the render contract (`core.assertBackend`) at comptime.
    gfx_mod.addImport("labelle-core", core_mod);
    if (is_android) {
        // The Android seam adapter (`src/android.zig`, surfaced as
        // `input.android`) also uses labelle-core for the `AndroidBackendContext`
        // type the generated bgfx-Android main registers with core. That import
        // is wired unconditionally above (shared `core_mod`); the generated build
        // unifies the app's core onto it (guarded overrideImport in the build_zig
        // `backend_bgfx_android` section) so the registered vtable's type matches
        // the engine's `engine.core.AndroidBackendContext`.
        input_mod.link_libc = true;
        // NDK sysroot for the JNI glue's jni.h / android/*.h. Reuse the same
        // sysroot wiring bgfx/bx/bimg use; safe because `ndk` is non-null on
        // Android. Must precede the C source add (see applyNdkSysroot).
        if (ndk) |n| applyNdkSysroot(input_mod, n.inc_common, n.inc_arch, n.lib_path, n.android_api);
        input_mod.addCSourceFile(.{
            .file = android_gp_dep.path("src/android_gamepad_jni.c"),
            .flags = &.{},
        });
    }

    // ── Audio backend module ────────────────────────────────────────
    // `link_libc = true` is required by `src/audio.zig`'s libc-based
    // WAV file loader (post-0.16 swap from `std.fs.cwd()`) AND, on
    // desktop, by miniaudio (its CoreAudio/ALSA/WASAPI backends are C and
    // need the C runtime).
    //
    // The audio module is registered on EVERY target — the backend's
    // module contract must hold for Android consumers (#306):
    // `backend_dep.module("audio")` is fetched by the generated
    // `backend_bgfx_android` build (phase 4, #303). On Android it's a
    // *device-less* mixer: `src/audio.zig` comptime-selects a no-op
    // device backend (`is_android`), so NO miniaudio C TU and NO audio
    // frameworks are compiled in. On desktop we additionally compile
    // miniaudio + its per-OS system libs via `wireMiniaudio`; the real
    // playback device (in `src/audio_device.zig`) drives the PCM mixer
    // from its data callback. Those links propagate to any consumer that
    // imports the `audio` module (e.g. the example exe).
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Shared WAV decode + PCM mixer (Phase 2). `audio.zig` instantiates
    // `labelle_audio.Mixer(device_backend)` and forwards every public fn to it.
    audio_mod.addImport("labelle-audio", labelle_audio_mod);
    if (!is_android) {
        // ── miniaudio playback device (#297) — desktop only ─────────
        wireMiniaudio(b, audio_mod, target.result.os.tag);
    } else if (ndk) |n| {
        // On Android the mixer is AAudio-backed (`audio_device_android.zig`,
        // #306), which links `libaaudio`. The module's Zig source is pure
        // `extern fn` (no `@cInclude`), so the device-less compile-check below
        // emits its object without sysroot headers — but apply the SAME NDK
        // sysroot the other Android modules use so the lib path / API level /
        // PIC are wired for any consumer that actually *links* it (e.g. the
        // libgame.so app link). Desktop never reaches this branch.
        applyNdkSysroot(audio_mod, n.inc_common, n.inc_arch, n.lib_path, n.android_api);
        audio_mod.linkSystemLibrary("aaudio", .{});
    }

    // ── Window backend module ───────────────────────────────────────
    // Desktop gets the `zglfw` import (GLFW lifecycle + native handle).
    // Android omits it: `src/window.zig` comptime-gates the GLFW path out
    // and instead reads an `ANativeWindow*` (handed over via
    // `setAndroidNativeWindow`) into `PlatformData.nwh` at bgfx init.
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (zglfw_mod) |m| window_mod.addImport("zglfw", m);
    window_mod.addImport("zbgfx", zbgfx_mod);
    window_mod.addImport("input", input_mod);
    // labelle-core for the comptime `core.assertWindow(@This())` conformance
    // gate in `src/window.zig` (#386 Phase 3). Comptime-only, so the backend's
    // own pin (shared `core_mod`) resolves it on every target; no core type
    // crosses the engine seam through the window module.
    window_mod.addImport("labelle-core", core_mod);
    // closeWindow() calls gfx.shutdownPrograms() to release the sprite
    // program/uniform/textures before bgfx.shutdown() (#384).
    window_mod.addImport("gfx", gfx_mod);

    // ── Re-export native artifacts so consumers can link them ───────
    // bgfx is always re-exported. glfw is desktop-only (Android has no
    // zglfw artifact), so only install it off the Android path.
    b.installArtifact(bgfx_artifact);
    if (glfw_artifact) |a| b.installArtifact(a);

    // ── Unit tests for the platform-dispatch helper ─────────────────
    // Always build + run on the host — platform.zig is pure Zig with
    // no native deps, and pinning to the host keeps the tests
    // executable under `-Dtarget=...` cross-compilation of the rest
    // of the backend.
    const host_target = b.resolveTargetQuery(.{});
    const platform_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run bgfx backend unit tests");
    test_step.dependOn(&b.addRunArtifact(platform_tests).step);

    // Run the gfx coordinate-math tests (#331). `gfx/state.zig` imports only
    // `types.zig` (pure), so it runs on the host independent of zbgfx — and
    // unlike the compile-only `gfx_tests` below, this EXECUTES the
    // screenToDesign/designToPhysical inverse + round-trip assertions.
    const state_run = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gfx/state.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(state_run).step);

    // Run the ASTC container-parsing tests (#341). `gfx/astc.zig` is pure byte
    // parsing with no zbgfx dependency, so it EXECUTES on the host (magic
    // detection, block/image dims, ceil-to-block payload sizing, truncation).
    const astc_run = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gfx/astc.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(astc_run).step);

    // Run the video colour-conversion + plane-prep tests on the host. Both
    // `video/yuv.zig` (CPU YUV→RGBA, BT.601) and `video/planes.zig` (row-tighten
    // + NV12 de-interleave for the GPU plane-upload path, perf/gpu-yuv-video) are
    // pure Zig with no zbgfx/NDK dependency, so they EXECUTE on the host — the
    // verifiable core of the otherwise device-only video decode path.
    const yuv_run = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/video/yuv.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(yuv_run).step);

    const planes_run = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/video/planes.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(planes_run).step);

    // ── Compile-check window.zig (+ input.zig via its import) ───────
    // window.zig does the real comptime dispatch on builtin.target — both
    // the per-OS desktop branches and the Android `is_android` path — so
    // compiling it with `-Dtarget=<os>` is the only way to catch branches
    // that don't build for a given target. Forcing a test binary off
    // window_mod pulls the full module graph (zbgfx + input, plus zglfw on
    // desktop) into the build and errors on any per-target breakage. For
    // `-Dtarget=aarch64-linux-android` this is the vehicle that proves
    // window/input compile with NO zglfw in the graph.
    //
    // Depend on the *compile* step, not a run step — we want this to
    // work under cross-compilation (`-Dtarget=x86_64-windows-gnu`,
    // `-Dtarget=aarch64-linux-android`, etc.) where the host can't
    // execute the produced binary.
    const window_tests = b.addTest(.{ .root_module = window_mod });
    test_step.dependOn(&window_tests.step);

    // ── Compile-check gfx.zig for the build target ──────────────────
    // gfx.zig imports only zbgfx (no zglfw), so it already compiled for
    // Android in phase 1 implicitly — but nothing in the test graph
    // forced it. Add an explicit compile-check so `zig build test
    // -Dtarget=aarch64-linux-android` covers all three Android modules
    // (gfx/window/input) as required by phase 2.
    const gfx_tests = b.addTest(.{ .root_module = gfx_mod });
    test_step.dependOn(&gfx_tests.step);

    // ── Compile-check audio.zig for the build target (Android) ──────
    // On the host, the audio tests below RUN against the real miniaudio
    // device backend (pinned to `host_target`). That run-test can't cover
    // `-Dtarget=aarch64-linux-android`: the host can't execute a foreign
    // binary, and the device-less Android path selects a different
    // `device_backend`. So for Android we add an explicit compile-check
    // off `audio_mod` (the build-target module, no miniaudio wired) that
    // emits objects for aarch64-linux-android — proving the device-less
    // mixer (#306) compiles for the target the generated
    // `backend_bgfx_android` build will fetch. Depend on the *compile*
    // step, never a run step (same reasoning as window/input above).
    if (is_android) {
        const audio_android_tests = b.addTest(.{ .root_module = audio_mod });
        test_step.dependOn(&audio_android_tests.step);
    }

    // ── Android app-shell module (NativeActivity glue) ──────────────
    // Phase 3 (#302): the hand-rolled NativeActivity entry that sokol
    // hides inside sokol_app. Built ONLY for Android — it's the runtime
    // glue that drives the ANativeWindow surface (phases 1–2 plumbed) and
    // feeds touch into `input`. It compiles the NDK's
    // `android_native_app_glue.c` (which provides the app thread + looper
    // + `ANativeActivity_onCreate`) and exports our `android_main`.
    //
    // We build it as its OWN object compile-check rather than wiring it
    // into the gfx/window/input modules: the full `.so` link (EGL /
    // GLESv3 / libandroid / liblog) is phase 4 (#303), so here we only
    // prove the module + glue + touch wiring COMPILE for
    // aarch64-linux-android. The android libs the shell references
    // (`android`, `log`) are declared on the module so they're recorded
    // for the eventual link, but we depend on the *compile* step (object
    // emission), never a run/link step that would demand those libs be
    // present on the host.
    if (ndk) |n| {
        const android_app_mod = b.addModule("android_app", .{
            .root_source_file = b.path("src/android_app.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // android_app drives window + input directly.
        android_app_mod.addImport("window", window_mod);
        android_app_mod.addImport("input", input_mod);
        android_app_mod.addImport("zbgfx", zbgfx_mod);

        // Vendor the NDK's native_app_glue: its include dir (for
        // <android_native_app_glue.h>) and its single C TU. The glue needs
        // the Bionic headers (android/native_window.h, looper.h, input.h),
        // which the NDK sysroot supplies — apply the same sysroot wiring
        // bgfx/bx/bimg use.
        applyNdkSysroot(android_app_mod, n.inc_common, n.inc_arch, n.lib_path, n.android_api);
        const glue_dir = androidNativeAppGlueDir(b) orelse
            @panic("Could not find native_app_glue in the NDK (sources/android/native_app_glue).");
        android_app_mod.addIncludePath(.{ .cwd_relative = glue_dir });
        android_app_mod.addCSourceFile(.{
            .file = .{ .cwd_relative = b.pathJoin(&.{ glue_dir, "android_native_app_glue.c" }) },
            .flags = &.{ "-std=c11", "-Wall" },
        });

        // Declare the android libs the shell references for the eventual
        // (phase-4) link. These are recorded on the module's link inputs;
        // the compile-check below depends only on object emission, so a
        // missing lib on the host can't break the build here.
        android_app_mod.linkSystemLibrary("android", .{});
        android_app_mod.linkSystemLibrary("log", .{});

        // Compile-check: a test binary off the android_app module pulls
        // the full graph (android_app + native_app_glue C + window/input,
        // no zglfw) and emits objects for aarch64-linux-android. We depend
        // on the *compile* step (`&t.step`), NOT a run step — the host
        // can't execute an aarch64-linux-android binary, and we explicitly
        // avoid a link that would need EGL/GLESv3 (phase 4).
        const android_app_tests = b.addTest(.{ .root_module = android_app_mod });
        test_step.dependOn(&android_app_tests.step);

        // ── Phase 4 (#303): full Android app link → libgame.so ──────────
        // Standalone bgfx-Android video demo (FP#549) proving the VideoPlayer
        // draws through bgfx on-device. Reuses the compile-verified module graph
        // and adds the EGL / GLESv3 link the compile-checks above deferred.
        const app_mod = b.createModule(.{
            .root_source_file = b.path("example/android_video.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // Android audio-track decoder module (FP#549 audio): decodes the
        // mp4's AAC track via AMediaExtractor/AMediaCodec → 48k stereo PCM.
        // Needs the NDK sysroot (Bionic headers) and links mediandk, same as
        // the rest of the Android media path.
        const android_audio_mod = b.addModule("android_audio", .{
            .root_source_file = b.path("src/video/android_audio.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        applyNdkSysroot(android_audio_mod, n.inc_common, n.inc_arch, n.lib_path, n.android_api);
        android_audio_mod.linkSystemLibrary("mediandk", .{});

        app_mod.addImport("backend_app", android_app_mod);
        app_mod.addImport("backend_gfx", gfx_mod);
        app_mod.addImport("window", window_mod);
        app_mod.addImport("audio", audio_mod);
        app_mod.addImport("android_audio", android_audio_mod);
        applyNdkSysroot(app_mod, n.inc_common, n.inc_arch, n.lib_path, n.android_api);
        app_mod.linkSystemLibrary("android", .{});
        app_mod.linkSystemLibrary("log", .{});
        app_mod.linkSystemLibrary("mediandk", .{});
        app_mod.linkSystemLibrary("aaudio", .{});
        app_mod.linkSystemLibrary("EGL", .{});
        app_mod.linkSystemLibrary("GLESv3", .{});

        app_mod.linkLibrary(bgfx_artifact);
        const app_lib = b.addLibrary(.{
            .name = "game",
            .linkage = .dynamic,
            .root_module = app_mod,
        });
        // Zig won't self-provide bionic libc — point the link at the NDK's
        // libc (headers + crt objects) via a generated libc paths file.
        // include_dir + sys_include_dir carry the TWO NDK header roots
        // (usr/include and usr/include/<triple>) so zig's bundled libc++ build
        // finds both <linux/types.h> and the arch <asm/types.h>.
        const libc_conf = b.fmt(
            "include_dir={s}\nsys_include_dir={s}\ncrt_dir={s}\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n",
            .{ n.inc_arch, n.inc_common, n.lib_path },
        );
        const libc_wf = b.addWriteFiles();
        app_lib.setLibCFile(libc_wf.add("android-libc.txt", libc_conf));

        const app_step = b.step("android-app", "Link the bgfx-Android video demo (libgame.so)");
        app_step.dependOn(&b.addInstallArtifact(app_lib, .{}).step);
    }

    // ── Audio backend tests ─────────────────────────────────────────
    // Build + run the audio module's unit tests (spinlock, mixer, WAV
    // decode, unload ordering). These RUN (they exercise the spinlock /
    // mixer logic), so the test module is pinned to `host_target` rather
    // than the build's `-Dtarget` — otherwise `zig build test
    // -Dtarget=<foreign>` would try to execute a foreign binary and fail
    // (same reasoning as `platform_tests`). It carries the same miniaudio
    // C source + host system libs so it links the real device backend,
    // even though the tests never open a device.
    const audio_test_mod = b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Wire the shared mixer into the host test module too (resolved for the
    // host target so the run-test executes natively).
    const labelle_audio_host_dep = b.dependency("labelle_audio", .{ .target = host_target, .optimize = optimize });
    audio_test_mod.addImport("labelle-audio", labelle_audio_host_dep.module("labelle-audio"));
    wireMiniaudio(b, audio_test_mod, host_target.result.os.tag);
    const audio_tests = b.addTest(.{ .root_module = audio_test_mod });
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);
}

/// WASM (Emscripten) build — SKELETON, spike-blocked (bgfx-wasm epic
/// labelle-bgfx#8).
///
/// Mirrors the PROVEN sokol/raylib wasm pattern for the pieces that DON'T depend
/// on the parallel zbgfx-wasm-build spike:
///   * emsdk sysroot plumbed into the C compile so `stb_image_impl.c` finds
///     `<stdlib.h>`/`<stdio.h>` — Zig ships no libc headers for
///     wasm32-emscripten; they live in emsdk's sysroot (mirrors labelle-sokol's
///     build.zig). Fetched lazily so a desktop/android build never pulls emsdk.
///   * no zglfw and no sdl_gamepad (both desktop-only), matching the is_android
///     carve-outs in `build()`.
///
/// The load-bearing seam — resolving the zbgfx wasm/WebGL bgfx artifact + the
/// bgfx WebGL context init — is what the spike determines, so it is a
/// TODO(#8 spike) rather than a guess. Until then this hard-fails so a
/// `zig build -Dtarget=wasm32-emscripten` errors LOUDLY + clearly instead of
/// silently linking a desktop artifact.
///
/// NOTE: a literal top-level `@compileError` cannot serve as the guard — the
/// wasm target is a RUNTIME value from `-Dtarget`, so a `@compileError` would be
/// analyzed (and fire) for the desktop/android builds too and break their
/// `zig build`. This build-configuration `@panic`, reachable ONLY when
/// `is_wasm` is true, is the loud-fail equivalent that keeps desktop/android
/// byte-unchanged.
fn buildWasm(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // ── emscripten sysroot ───────────────────────────────────────────
    // bgfx/bx/bimg (C++) and stb_image (C) need emscripten's libc/libc++/EGL/GLES
    // headers, which the Zig toolchain does NOT ship for wasm32-emscripten. The
    // proven spike recipe threads a `-Demsdk_sysroot` path into zbgfx (which
    // `addSystemIncludePath`s it onto bx/bimg/bgfx) and reuses it for our own
    // stb C compile. Default to the Homebrew emscripten sysroot (matching the
    // `emcc` on PATH used for the link below); override with `-Demsdk_sysroot`.
    const emsdk_sysroot = b.option(
        []const u8,
        "emsdk_sysroot",
        "Path to the emscripten sysroot 'include' dir for the wasm C/C++ compiles",
    ) orelse "/opt/homebrew/Cellar/emscripten/4.0.23/libexec/cache/sysroot/include";

    // ── wasm/WebGL-capable zbgfx (apotema/zbgfx fork, #8) ────────────
    // Force `with_shaderc = false` (the host codegen tool can't build for wasm)
    // and thread the sysroot so bx/bimg/bgfx find emscripten's headers. The fork
    // also force-disables BGFX_CONFIG_MULTITHREADED for emscripten, so bgfx runs
    // single-threaded and `bgfx.frame` renders in-thread from the main-loop cb.
    const zbgfx_dep = b.dependency("zbgfx", .{
        .target = target,
        .optimize = optimize,
        .with_shaderc = false,
        .emsdk_sysroot = emsdk_sysroot,
    });
    const zbgfx_mod = zbgfx_dep.module("zbgfx");
    const bgfx_artifact = zbgfx_dep.artifact("bgfx");

    // labelle-core — comptime contract conformance for gfx/window/input (same as
    // desktop/android). No core type crosses the engine seam through these
    // modules, so the backend's own pin resolves it.
    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

    // ── Gfx backend module ──────────────────────────────────────────
    // `link_libc = true` for stb_image (malloc/free/memcpy) + gfx/texture.zig's
    // libc file loader. The emscripten sysroot MUST be attached BEFORE
    // `addCSourceFile` so the C TU finds <stdlib.h>/<stdio.h> (mirrors the sokol
    // backend's ordering — setting it after made emcc bail with 'stdio.h' not
    // found).
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gfx_mod.addImport("zbgfx", zbgfx_mod);
    gfx_mod.addImport("labelle-core", core_mod);
    gfx_mod.addIncludePath(b.path("src"));
    gfx_mod.addSystemIncludePath(.{ .cwd_relative = emsdk_sysroot });
    gfx_mod.addCSourceFile(.{ .file = b.path("src/stb_image_impl.c"), .flags = &.{} });

    // ── Input backend module ────────────────────────────────────────
    // No zglfw / no sdl_gamepad (both desktop-only) — src/input.zig comptime-gates
    // every zglfw reference behind `no_glfw` (Android OR wasm) and stubs the
    // getters, so the wasm example needs no input wiring. `android_gamepad` is
    // imported on every target (its Android symbols are internally gated).
    const input_opts = b.addOptions();
    input_opts.addOption(bool, "gamepad_enabled", false);
    input_opts.addOption(bool, "gamepad_hidapi", false);
    input_opts.addOption(bool, "gui_enabled", false);
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("build_options", input_opts.createModule());
    input_mod.addImport("labelle-core", core_mod);
    const android_gp_dep = b.dependency("labelle_android_gamepad", .{ .target = target, .optimize = optimize });
    input_mod.addImport("android_gamepad", android_gp_dep.module("android_gamepad"));

    // ── Window backend module ───────────────────────────────────────
    // No zglfw; src/window.zig comptime-selects `initWindowWasm`, which hands
    // bgfx the `#canvas` selector via `PlatformData.nwh`.
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("zbgfx", zbgfx_mod);
    window_mod.addImport("input", input_mod);
    window_mod.addImport("labelle-core", core_mod);
    window_mod.addImport("gfx", gfx_mod);

    // ── Self-contained wasm/WebGL example → static lib → emcc link ───
    // Built directly by the backend (no assembler/engine) so the whole wasm
    // build+link chain is verifiable in-repo (`zig build wasm-example`). The
    // assembler-generated app takes the same shape via templates/wasm.txt +
    // backend.hook.zig's emcc arm.
    const example_mod = b.createModule(.{
        .root_source_file = b.path("example/wasm_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport("window", window_mod);
    example_mod.addImport("backend_gfx", gfx_mod);

    // Compile the Zig side to a static lib; emcc links it + the bgfx C++ archive
    // into the final .wasm/.js/.html.
    const example_lib = b.addLibrary(.{
        .name = "wasm_demo",
        .linkage = .static,
        .root_module = example_mod,
    });

    // Re-export the bgfx artifact (parity with the desktop/android installs).
    b.installArtifact(bgfx_artifact);

    // emcc link step. Use the `emcc` on PATH (the sysroot above matches it), so
    // the build works without an installed emsdk dependency. bgfx creates its own
    // WebGL2 context on `#canvas`, so — unlike raylib — there is NO GLFW emulation
    // and NO asyncify; the frame is driven by emscripten_set_main_loop.
    const emcc = b.addSystemCommand(&.{"emcc"});
    if (optimize == .Debug) {
        emcc.addArgs(&.{ "-Og", "-sSAFE_HEAP=1", "-sSTACK_OVERFLOW_CHECK=1", "-sASSERTIONS=1" });
    } else if (optimize == .ReleaseSmall) {
        emcc.addArgs(&.{ "-Oz", "-sASSERTIONS=0" });
    } else if (optimize == .ReleaseSafe) {
        emcc.addArgs(&.{ "-O3", "-sASSERTIONS=1" });
    } else {
        emcc.addArgs(&.{ "-O3", "-sASSERTIONS=0" });
    }
    emcc.addArgs(&.{
        "-sMIN_WEBGL_VERSION=2",
        "-sMAX_WEBGL_VERSION=2",
        // bgfx loads GL entry points via emscripten_webgl_get_proc_address; recent
        // emscripten gates that helper behind this flag (else it's a link error).
        "-sGL_ENABLE_GET_PROC_ADDRESS=1",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sSTACK_SIZE=524288",
    });
    emcc.addArtifactArg(example_lib);
    // zbgfx builds THREE static libs — bgfx, bx, bimg — where bx/bimg are linked
    // into bgfx as `other_step` link objects. `addArtifactArg(bgfx)` alone only
    // hands emcc `libbgfx.a`, leaving bx/bimg's symbols undefined at link. Walk
    // bgfx's transitive compile dependencies and hand emcc every static lib
    // (bgfx + bx + bimg), mirroring the sokol backend's emLinkStep. The set
    // includes bgfx itself, so we don't add it separately.
    for (bgfx_artifact.getCompileDependencies(false)) |dep| {
        if (dep.kind == .lib) emcc.addArtifactArg(dep);
    }
    emcc.addArg("-o");
    const html = emcc.addOutputFileArg("wasm_demo.html");

    // emcc emits wasm_demo.{html,js,wasm} into html's dir → install to web/.
    const install_web = b.addInstallDirectory(.{
        .source_dir = html.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    b.getInstallStep().dependOn(&install_web.step);

    const wasm_step = b.step("wasm-example", "Build the bgfx WebGL/wasm smoke example (emcc → zig-out/web/wasm_demo.html)");
    wasm_step.dependOn(&install_web.step);

    // A `test` step is expected by CI even on wasm; wire a no-op so `zig build
    // test -Dtarget=wasm32-emscripten` succeeds (the real unit tests run on the
    // host target in the desktop/android graph).
    _ = b.step("test", "(wasm target: unit tests run on the host graph)");
}

/// Attach miniaudio's implementation TU + include path, and link the
/// per-OS system libraries its native backends need, to `mod`. Gated on
/// `os_tag` so the backend still builds for Linux / Windows (and
/// cross-compiles) instead of hard-linking macOS-only frameworks.
fn wireMiniaudio(b: *std.Build, mod: *std.Build.Module, os_tag: std.Target.Os.Tag) void {
    mod.addIncludePath(b.path("libs/miniaudio"));
    mod.addCSourceFile(.{
        .file = b.path("libs/miniaudio/miniaudio.c"),
        .flags = &.{"-std=c99"},
    });
    switch (os_tag) {
        .macos => {
            mod.linkFramework("CoreAudio", .{});
            mod.linkFramework("AudioToolbox", .{});
            mod.linkFramework("CoreFoundation", .{});
        },
        .linux => {
            // miniaudio dlopen()s the ALSA/PulseAudio shared libs at
            // runtime, so only libdl/pthread/m are needed at link time.
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("m", .{});
        },
        .windows => {
            // WASAPI/DirectSound are reached via Ole32 + the standard
            // Win32 libs; miniaudio loads the rest at runtime.
            mod.linkSystemLibrary("ole32", .{});
            mod.linkSystemLibrary("user32", .{});
        },
        else => {},
    }
}

/// Add the Android NDK sysroot system-include paths, the arch/API
/// library path, and `__ANDROID_API__` to a single C/C++ module so its
/// translation units resolve the Bionic `<stdlib.h>` etc. that Zig's
/// bundled libc++ headers pull from the global namespace.
fn applyNdkSysroot(
    mod: *std.Build.Module,
    inc_common: []const u8,
    inc_arch: []const u8,
    lib_path: []const u8,
    android_api: []const u8,
) void {
    mod.addSystemIncludePath(.{ .cwd_relative = inc_common });
    mod.addSystemIncludePath(.{ .cwd_relative = inc_arch });
    mod.addLibraryPath(.{ .cwd_relative = lib_path });
    // bgfx + Bionic both gate Android-version behavior on __ANDROID_API__.
    mod.addCMacro("__ANDROID_API__", android_api);
    // Android .so consumers need PIC in every archived .o (see #147).
    mod.pic = true;
}

/// Resolved Android NDK sysroot include/library paths + API level for a
/// given target. Computed once in `build()` and threaded through
/// `applyNdkSysroot` for each C/C++ module that needs the Bionic headers.
const NdkPaths = struct {
    inc_common: []const u8,
    inc_arch: []const u8,
    lib_path: []const u8,
    android_api: []const u8,
};

/// Resolve the NDK sysroot paths for an Android `target`. Panics with an
/// actionable message if the NDK can't be found or the arch is
/// unsupported — the caller only invokes this when `is_android` is true.
fn resolveNdkPaths(b: *std.Build, target: std.Build.ResolvedTarget) NdkPaths {
    const ndk_sysroot = getAndroidNdkSysroot(b) orelse
        @panic("Could not find Android NDK. Set ANDROID_NDK_HOME or ANDROID_HOME.");
    const ndk_arch_triple: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm, .thumb => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => @panic("unsupported Android arch for bgfx"),
    };
    // Match the toolkit's default Android min_sdk (28, see
    // `src/config.zig`). Must be >= 23: bx's `file.cpp` references
    // `stdout`/`stderr`, which Bionic exposes as real symbols only from
    // API 23 (below that they alias `__sF[]`, marked `__REMOVED_IN(23)`
    // and rejected by clang availability).
    const android_api = "28";
    return .{
        .inc_common = b.pathJoin(&.{ ndk_sysroot, "usr/include" }),
        .inc_arch = b.pathJoin(&.{ ndk_sysroot, "usr/include", ndk_arch_triple }),
        .lib_path = b.pathJoin(&.{ ndk_sysroot, "usr/lib", ndk_arch_triple, android_api }),
        .android_api = android_api,
    };
}

/// Locate the Android NDK sysroot, mirroring the sokol-Android path in
/// `src/templates/build_zig.txt`. Checks `ANDROID_NDK_HOME` first, then
/// `ANDROID_HOME/ndk/<latest>`. Returns null if neither resolves to an
/// existing sysroot.
///
/// Env lookups go through `b.graph.environ_map.get` and filesystem
/// checks through `std.Io.Dir.cwd().access(io, ...)` — Zig 0.16 removed
/// `std.process.getEnvVarOwned`, `std.posix.getenv`, and `std.fs.cwd()`.
fn getAndroidNdkSysroot(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    // 1. ANDROID_NDK_HOME env var
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk_home| {
        const sysroot = b.pathJoin(&.{ ndk_home, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
        if (std.Io.Dir.cwd().access(io, sysroot, .{})) |_| {
            return sysroot;
        } else |_| {}
    }
    // 2. ANDROID_HOME/ndk/<latest>/
    if (b.graph.environ_map.get("ANDROID_HOME")) |home| {
        const ndk_dir = b.pathJoin(&.{ home, "ndk" });
        var dir = std.Io.Dir.cwd().openDir(io, ndk_dir, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var latest: ?[]const u8 = null;
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .directory) {
                if (latest) |prev| {
                    if (std.mem.order(u8, entry.name, prev) == .gt) {
                        b.allocator.free(prev);
                        latest = b.allocator.dupe(u8, entry.name) catch null;
                    }
                } else {
                    latest = b.allocator.dupe(u8, entry.name) catch null;
                }
            }
        }
        if (latest) |version| {
            defer b.allocator.free(version);
            const sysroot = b.pathJoin(&.{ ndk_dir, version, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
            if (std.Io.Dir.cwd().access(io, sysroot, .{})) |_| {
                return sysroot;
            } else |_| {}
        }
    }
    return null;
}

/// Locate the NDK's `android_native_app_glue` source directory
/// (`<ndk>/sources/android/native_app_glue`), which ships
/// `android_native_app_glue.c` + `.h`. Resolves the NDK root the same way
/// `getAndroidNdkSysroot` does (ANDROID_NDK_HOME, then
/// ANDROID_HOME/ndk/<latest>) but returns the glue dir rather than the
/// sysroot. Returns null if it can't be found.
fn androidNativeAppGlueDir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const rel = &.{ "sources", "android", "native_app_glue" };

    // 1. ANDROID_NDK_HOME
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk_home| {
        const dir = b.pathJoin(&.{ ndk_home, rel[0], rel[1], rel[2] });
        if (std.Io.Dir.cwd().access(io, dir, .{})) |_| return dir else |_| {}
    }

    // 2. ANDROID_HOME/ndk/<latest>
    if (b.graph.environ_map.get("ANDROID_HOME")) |home| {
        const ndk_dir = b.pathJoin(&.{ home, "ndk" });
        var dir = std.Io.Dir.cwd().openDir(io, ndk_dir, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var latest: ?[]const u8 = null;
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .directory) {
                if (latest) |prev| {
                    if (std.mem.order(u8, entry.name, prev) == .gt) {
                        b.allocator.free(prev);
                        latest = b.allocator.dupe(u8, entry.name) catch null;
                    }
                } else {
                    latest = b.allocator.dupe(u8, entry.name) catch null;
                }
            }
        }
        if (latest) |version| {
            defer b.allocator.free(version);
            const glue = b.pathJoin(&.{ ndk_dir, version, rel[0], rel[1], rel[2] });
            if (std.Io.Dir.cwd().access(io, glue, .{})) |_| return glue else |_| {}
        }
    }
    return null;
}

fn ndkHostTag() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
}
