//! bgfx backend build hook (manifest-v2, epic #453 item 3) — the DEDICATED hook
//! file the v2 manifest points at via `.build_hook = "backend.hook.zig"`
//! (design §3/§4). It is NOT bgfx's own `build.zig`: that file carries top-level
//! package-local imports (zbgfx/zglfw and the NDK-wiring helpers) resolvable only
//! inside the labelle_bgfx package build context — absent from the generated ROOT
//! package the assembler imports the hook into. So the hook makes NO package-local
//! import assumptions: it may `@import("std")` (and `@import("builtin")` for the
//! host tag) and take everything else through the hook context.
//!
//! ## Scope — bgfx is DESKTOP + ANDROID + WASM; ANDROID + WASM are hook-bearing
//!
//! DESKTOP has no residual: it is fully declarative (the `bgfx` + `glfw` artifacts
//! are linked by the assembler from the manifest) and `.target = .native` resolves
//! without a hook, so the assembler never invokes this hook on a desktop build.
//! bgfx ships NO ios template, so this hook has NO ios arm.
//!
//! WASM (bgfx-wasm epic labelle-bgfx#8). Its target is the STATIC `.triple`
//! "wasm32-emscripten" (resolved directly in the generated build.zig), so there
//! is NO `resolve_target`. Its `post_wire` .wasm arm supplies the Emscripten
//! `emcc` link step, reconstructed here from ONLY `std.Build` + the emsdk
//! dependency (resolved via `b.dependency("emsdk", .{})`). bgfx creates its own
//! WebGL2 context on the emscripten canvas (the canvas selector is handed to bgfx
//! via `PlatformData.nwh` in src/window.zig), so — unlike raylib — there is no
//! GLFW emulation and no asyncify; the flag set is WebGL2 + the GL proc-address
//! helper + memory-growth/stack. The wasm bgfx artifact is the same
//! `zbgfx.artifact("bgfx")` (the apotema/zbgfx fork compiles it for
//! wasm32-emscripten when handed `-Demsdk_sysroot`), and emcc is given bgfx's full
//! transitive lib set (bgfx + bx + bimg).
//!
//! ANDROID exercises BOTH hook phases:
//!
//!   * `resolve_target` — runs BEFORE any `b.dependency` and produces the android
//!     `ResolvedTarget` from `-Demulator`/`-Dandroid_arch` + host arch,
//!     reproducing the enum path's `header_android` target-resolution block. Names
//!     no backend, so it matches sokol's android resolver exactly (design §4 — the
//!     resolution logic is backend-agnostic).
//!   * `post_wire` — runs AFTER the generic module/artifact/system-lib wiring and
//!     supplies the bgfx-Android NDK residual (design §2 residual (a), the
//!     "non-declarative NDK ordering" the v1 manifest flagged): NDK sysroot
//!     detection + `addLibraryPath(usr/lib/<triple>/<api>)` on the `.so` root +
//!     `libc.txt` generation. Unlike sokol, the bgfx C++ TUs (bgfx/bx/bimg) are
//!     NDK-sysroot-wired by the backend's OWN build.zig, so this hook does NOT
//!     `addSystemIncludePath` on the `bgfx` artifact — the residual is only the
//!     .so's per-API library path + libc.txt. The generic parts —
//!     `linkLibrary(bgfx)`, `linkSystemLibrary(...)`, `link_libc`, root-module
//!     `.pic` — are emitted declaratively by the assembler from the manifest, NOT
//!     here.
//!
//! The generated v2 android build.zig `@import`s this file (as a sibling
//! `backend_build_hook.zig`) and calls both phases; that import is the design's
//! "assembler imports the hook into the generated root package" (§3). `generate`
//! auto-detects the sibling `backend.manifest.v2.zon` and stages this hook (the
//! manifest-v2 Phase A cutover, #472 P2).

const std = @import("std");
const builtin = @import("builtin");

/// Versioned with the hook ABI (design §4). Asserted `== HOOK_ABI_VERSION` by the
/// assembler before the hook is ever called; matches `manifest_v2.HOOK_ABI_VERSION`.
pub const HOOK_ABI_VERSION: u8 = 2;

/// The platform tag the hook branches on. Mirrors `config.Platform` structurally so
/// the hook needs no assembler import. bgfx supports desktop + android + wasm
/// (labelle-bgfx#8 scaffolding); the ios variant exists for `HookContext`
/// shape-compatibility with `manifest_v2` and is never reached (bgfx declares no
/// ios platform entry).
pub const Platform = enum { desktop, ios, android, wasm };

/// Error surface for the pure decision helpers (so they stay unit-testable without a
/// live `*std.Build` and without an uncatchable `@panic`). The `resolve_target` /
/// `post_wire` entry points turn these into a `@panic` at the call site — a
/// misconfiguration is a hard build error, not a recoverable one — but the
/// underlying logic is exercised through the error return in tests.
pub const HookError = error{
    /// `-Dandroid_arch=<v>` was neither arm64/aarch64 nor x86_64/x64.
    InvalidAndroidArch,
    /// `ctx.android_target_sdk` was null on an Android build. The assembler MUST
    /// populate it (from `cfg.android.target_sdk_version`, always a concrete value)
    /// — a null is an assembler bug, and a silent `orelse 34` would emit a wrong
    /// `usr/lib/<triple>/34` path while appearing to honor the user's
    /// `target_sdk_version` (design §4 review-correction #6). Hard error, never a
    /// default.
    AndroidTargetSdkRequired,
};

// ── resolve_target (design §4) — runs BEFORE any b.dependency ──────────────

/// What the pre-dependency `resolve_target` phase returns: the `ResolvedTarget`
/// every subsequent `b.dependency` (backend + plugins) consumes. bgfx has no iOS
/// target, so `ios_sdk_path` is always null (kept for `manifest_v2` shape parity).
pub const ResolvedTargetInfo = struct {
    target: std.Build.ResolvedTarget,
    ios_sdk_path: ?[]const u8 = null,
};

/// Context handed to `resolve_target`. Only the platform is needed today; kept a
/// struct so future fields are additive.
pub const ResolveContext = struct {
    platform: Platform,
};

/// PURE arch selection — the testable core of the android target resolution.
/// `-Dandroid_arch` wins when set (arm64|x86_64); otherwise `-Demulator` picks the
/// host-matching arch (arm64 on Apple Silicon, x86_64 on Intel); otherwise arm64.
/// Backend-agnostic — identical to sokol's.
pub fn selectAndroidArch(
    host_arch: std.Target.Cpu.Arch,
    emulator_mode: bool,
    arch_opt: ?[]const u8,
) HookError!std.Target.Cpu.Arch {
    if (arch_opt) |name| {
        if (std.mem.eql(u8, name, "arm64") or std.mem.eql(u8, name, "aarch64")) return .aarch64;
        if (std.mem.eql(u8, name, "x86_64") or std.mem.eql(u8, name, "x64")) return .x86_64;
        return HookError.InvalidAndroidArch;
    }
    const emulator_arch: std.Target.Cpu.Arch = switch (host_arch) {
        .aarch64 => .aarch64,
        else => .x86_64,
    };
    return if (emulator_mode) emulator_arch else .aarch64;
}

/// PURE NDK triple mapping. The `usr/lib/<triple>/<api>` NDK path is keyed by this.
pub fn ndkArchTriple(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        // resolve_target only ever produces the two arches above; a third would be
        // an assembler bug, not a user error.
        else => "aarch64-linux-android",
    };
}

/// Produce the android `ResolvedTarget`. Reproduces the enum path's `header_android`
/// target-resolution block. Runs before any `b.dependency`, so it constructs no
/// graph nodes. bgfx has no ios/wasm resolved target, so those platforms never
/// reach this.
pub fn resolve_target(b: *std.Build, ctx: ResolveContext) ResolvedTargetInfo {
    switch (ctx.platform) {
        .android => {
            const emulator_mode = b.option(bool, "emulator", "Build for Android emulator (x86_64 on Intel Mac, arm64 on Apple Silicon)") orelse false;
            const android_arch_opt = b.option([]const u8, "android_arch", "Android target arch (arm64|x86_64). Overrides -Demulator when set.");
            const android_arch = selectAndroidArch(b.graph.host.result.cpu.arch, emulator_mode, android_arch_opt) catch {
                std.debug.print("build.zig: unknown -Dandroid_arch value (expected arm64 or x86_64)\n", .{});
                @panic("invalid android_arch");
            };
            return .{ .target = b.resolveTargetQuery(.{
                .cpu_arch = android_arch,
                .os_tag = .linux,
                .abi = .android,
            }) };
        },
        // desktop=.native resolves without a hook; bgfx has no ios/wasm platform.
        else => @panic("resolve_target: bgfx only resolves an android target"),
    }
}

// ── post_wire (design §4) — runs AFTER generic wiring ──────────────────────

/// `post_wire` context (design §4). Every field is valid because `post_wire` runs
/// strictly AFTER `b.dependency` and after the root lib is created. Kept
/// structurally in sync with `manifest_v2.HookContext`.
pub const HookContext = struct {
    manifest_version: u8,
    backend_dep: *std.Build.Dependency,
    root_module: *std.Build.Module,
    root_artifact: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform: Platform,
    ios_sdk_path: ?[]const u8,
    android_target_sdk: ?u32,
};

/// REQUIRED android SDK accessor — the testable enforcement of "no silent 34
/// default" (design §4 review-correction #6). Returns an error on null so the error
/// path is unit-testable; `post_wire` turns it into a `@panic`.
pub fn requireAndroidSdk(ctx: HookContext) HookError!u32 {
    return ctx.android_target_sdk orelse HookError.AndroidTargetSdkRequired;
}

/// PURE libc.txt body builder. Zig does not bundle Android libc, so the generated
/// `.so` build needs a `libc.txt` pointing the compiler at the NDK sysroot. Takes
/// pre-joined paths so it is unit-testable without a `*std.Build`; `post_wire` joins
/// the paths via `b.pathJoin` and calls this. Caller owns the returned slice.
pub fn libcTxt(
    allocator: std.mem.Allocator,
    include_dir: []const u8,
    sys_include_dir: []const u8,
    crt_dir: []const u8,
) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        "include_dir=",     include_dir,     "\n",
        "sys_include_dir=", sys_include_dir, "\n",
        "crt_dir=",         crt_dir,         "\n",
        "msvc_lib_dir=\n",
        "kernel32_lib_dir=\n",
        "gcc_dir=\n",
    });
}

/// A candidate `$ANDROID_HOME/ndk/<name>` dir paired with whether its
/// `toolchains/llvm/prebuilt/<host>/sysroot` actually exists.
const NdkCandidate = struct { name: []const u8, has_sysroot: bool };

/// Pick the lexicographically-greatest NDK version dir that HAS a valid sysroot.
/// Validity is part of the selection (not an after-the-fact check on the greatest
/// dir), so a stray/partial install can't shadow an older valid NDK. Returns a
/// borrowed slice from `candidates` or null when none valid.
fn selectGreatestValidNdk(candidates: []const NdkCandidate) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (candidates) |c| {
        if (!c.has_sysroot) continue;
        if (best) |prev| {
            if (std.mem.order(u8, c.name, prev) == .gt) best = c.name;
        } else {
            best = c.name;
        }
    }
    return best;
}

fn ndkHostTag() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
}

/// Detect the Android NDK sysroot. Copied verbatim from the enum path's
/// `header_android` so the residual behaves identically — env lookups go through
/// `b.graph.environ_map`, FS probes through `std.Io.Dir.cwd().access(io, ...)`
/// (Zig 0.16 removed the older APIs, #144).
fn getAndroidNdkSysroot(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk_home| {
        const sysroot = b.pathJoin(&.{ ndk_home, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
        if (std.Io.Dir.cwd().access(io, sysroot, .{})) |_| {
            return sysroot;
        } else |_| {}
    }
    if (b.graph.environ_map.get("ANDROID_HOME")) |home| {
        const ndk_dir = b.pathJoin(&.{ home, "ndk" });
        var dir = std.Io.Dir.cwd().openDir(io, ndk_dir, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var candidates: std.ArrayList(NdkCandidate) = .empty;
        defer {
            for (candidates.items) |c| b.allocator.free(c.name);
            candidates.deinit(b.allocator);
        }
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = b.allocator.dupe(u8, entry.name) catch continue;
            const sysroot = b.pathJoin(&.{ ndk_dir, name, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
            const has_sysroot = if (std.Io.Dir.cwd().access(io, sysroot, .{})) |_| true else |_| false;
            candidates.append(b.allocator, .{ .name = name, .has_sysroot = has_sysroot }) catch {
                b.allocator.free(name);
                continue;
            };
        }
        if (selectGreatestValidNdk(candidates.items)) |version| {
            return b.pathJoin(&.{ ndk_dir, version, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
        }
    }
    return null;
}

// ── wasm emcc residual — the emLinkStep reconstruction (labelle-bgfx#8) ─────
//
// SCAFFOLDING, mirrors the proven raylib wasm hook. The hook is std-only and
// cannot import the provider package, so — like raylib — the emcc link step is
// reconstructed from ONLY `std.Build` + the emsdk dependency: it locates `emcc`
// under the resolved emsdk (`emTool`) and shells out with the web settings.
//
// The bgfx-specific emcc flag set: WebGL2 (bgfx creates its own context — no GLFW
// emulation, no asyncify) + the GL proc-address helper bgfx needs, plus the
// backend-agnostic memory-growth / stack-size / assertions gating.

/// The C-stack bump the wasm build needs (Emscripten defaults to a 64 KB stack,
/// which the engine's scene-load + atlas-decode path overflows). Mirrors raylib.
pub const wasm_stack_size_arg = "-sSTACK_SIZE=524288";

/// Allow the WASM heap to grow at runtime. Mirrors raylib.
pub const wasm_allow_memory_growth_arg = "-sALLOW_MEMORY_GROWTH=1";

/// bgfx creates its OWN WebGL2 context against the emscripten canvas (the canvas
/// selector is handed to bgfx via `PlatformData.nwh`, see src/window.zig's
/// `initWindowWasm`), so — unlike raylib's web build — there is NO GLFW emulation
/// and NO asyncify: the frame is driven by `emscripten_set_main_loop`. These force
/// a WebGL2 context (bgfx's GL renderer prefers GLES3).
pub const wasm_min_webgl_arg = "-sMIN_WEBGL_VERSION=2";
pub const wasm_max_webgl_arg = "-sMAX_WEBGL_VERSION=2";
/// bgfx loads GL entry points via `emscripten_webgl_get_proc_address`; recent
/// emscripten gates that helper behind this flag (else it is an undefined symbol
/// at link).
pub const wasm_gl_get_proc_address_arg = "-sGL_ENABLE_GET_PROC_ADDRESS=1";

/// Options for `emLinkStep` — the subset of emcc options the wasm residual sets.
/// Uses only `std.Build`/`std.builtin` types so the hook stays provider-free.
pub const EmLinkOptions = struct {
    optimize: std.builtin.OptimizeMode,
    /// The Zig code compiled to a static lib that emcc links into the module.
    lib_main: *std.Build.Step.Compile,
    /// The bgfx C++ archive (`backend_dep.artifact("bgfx")`, compiled for
    /// wasm32-emscripten by the apotema/zbgfx fork). `emLinkStep` walks its
    /// transitive compile-dependency set so emcc also receives bx + bimg.
    lib_backend: *std.Build.Step.Compile,
    /// The emsdk dependency, resolved by the caller via `b.dependency("emsdk", .{})`.
    emsdk: *std.Build.Dependency,
};

/// Path to an emscripten tool (e.g. `emcc`) inside the resolved emsdk dependency.
/// Forward-slash join (NOT `b.pathJoin`) so the emsdk-relative sub-path is
/// portable — mirrors raylib's hook.
fn emTool(b: *std.Build, emsdk: *std.Build.Dependency, tool: []const u8) std.Build.LazyPath {
    return emsdk.path(b.fmt("upstream/emscripten/{s}", .{tool}));
}

/// Reconstruction of the emcc link step using only `std.Build` + the emsdk
/// dependency (mirrors raylib's hook). Builds the `emcc` shell-out that links
/// `lib_main` + the `bgfx` archive into the `.html`/`.wasm`/`.js` module and
/// installs them under `web/`. Returns the install step so the caller can wire it
/// into `b.getInstallStep()` + the run step.
pub fn emLinkStep(b: *std.Build, options: EmLinkOptions) *std.Build.Step.InstallDir {
    // Pass emcc as a LazyPath via addFileArg so the emsdk path resolves lazily at
    // step-execution time — NOT eagerly at build-configuration time. `Run.create`
    // + `addFileArg` is the lazy-safe form; the step name "emcc" also hides the
    // resolved path in the log. Mirrors raylib's hook.
    const emcc = std.Build.Step.Run.create(b, "emcc");
    emcc.addFileArg(emTool(b, options.emsdk, "emcc"));
    if (options.optimize == .Debug) {
        emcc.addArgs(&.{ "-Og", "-sSAFE_HEAP=1", "-sSTACK_OVERFLOW_CHECK=1" });
    } else {
        // Non-Debug: optimize. Emscripten DEFAULTS assertions off (ASSERTIONS=0)
        // in optimized (-O1+) builds, so keeping them for ReleaseSafe (a safety
        // build) requires setting -sASSERTIONS=1 EXPLICITLY — merely omitting
        // -sASSERTIONS=0 would still leave them off. ReleaseFast/ReleaseSmall
        // disable them for the fastest/smallest builds. (Reused verbatim from
        // raylib's hook — the exact ReleaseSafe fix.)
        if (options.optimize == .ReleaseSafe) {
            emcc.addArg("-sASSERTIONS=1");
        } else {
            emcc.addArg("-sASSERTIONS=0");
        }
        if (options.optimize == .ReleaseSmall) {
            emcc.addArg("-Oz");
        } else {
            emcc.addArg("-O3");
        }
    }
    // bgfx-specific web settings: force WebGL2, expose the GL proc-address helper
    // bgfx needs, allow heap growth + bump the C stack (backend-agnostic). No GLFW
    // emulation / no asyncify — bgfx owns its WebGL context and the main loop is
    // emscripten_set_main_loop-driven.
    emcc.addArg(wasm_min_webgl_arg);
    emcc.addArg(wasm_max_webgl_arg);
    emcc.addArg(wasm_gl_get_proc_address_arg);
    emcc.addArg(wasm_allow_memory_growth_arg);
    emcc.addArg(wasm_stack_size_arg);

    // The Zig main lib, then EVERY static lib the bgfx artifact pulls in. zbgfx
    // builds three archives — bgfx, bx, bimg — where bx/bimg are `other_step` link
    // objects of bgfx; `addArtifactArg(bgfx)` alone leaves bx/bimg's symbols
    // (bx::memCopy, bx::vsnprintf, …) undefined at link. Walk the transitive
    // compile-dependency set of the backend artifact and hand emcc every lib in
    // it (the set includes bgfx itself). Mirrors the sokol backend's emLinkStep.
    emcc.addArtifactArg(options.lib_main);
    for (options.lib_backend.getCompileDependencies(false)) |dep| {
        if (dep.kind == .lib) emcc.addArtifactArg(dep);
    }
    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(b.fmt("{s}.html", .{options.lib_main.name}));

    // emcc emits 3 files (.html/.wasm/.js) into out_file's dir → install to web/.
    const install = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    install.step.dependOn(&emcc.step);
    return install;
}

/// Runs AFTER the generic module/artifact/system-lib wiring, to supply the residual
/// the manifest cannot express statically (design §2 residual (a) — the bgfx-Android
/// NDK ordering). DESKTOP is empty (fully declarative — no residual). ANDROID adds
/// the NDK per-API library path + libc.txt on the `.so` root (the generic parts —
/// `linkLibrary`, `linkSystemLibrary`, `link_libc`, root `.pic` — are emitted
/// declaratively by the assembler from the manifest, NOT here). Unlike sokol there
/// is NO `addSystemIncludePath` on the artifact: the bgfx/bx/bimg C++ TUs are
/// NDK-sysroot-wired by the backend's own build.zig. WASM does the Emscripten emcc
/// link step + install/run wiring (labelle-bgfx#8). bgfx has no ios platform, so
/// that arm is unreachable.
pub fn post_wire(b: *std.Build, ctx: HookContext) void {
    switch (ctx.platform) {
        .desktop => {}, // fully declarative — no residual
        .wasm => {
            // The Emscripten emcc link step + install/run wiring. emsdk is resolved
            // via `b.dependency` — declared as a root build dep by the manifest's
            // `.root_build_deps`. The declarative `linkLibrary(bgfx)` is emitted by
            // the assembler BEFORE this call, so the bgfx archive (compiled for
            // wasm32-emscripten by the apotema/zbgfx fork) is reachable via the
            // backend dep; `emLinkStep` walks its transitive libs (bgfx+bx+bimg)
            // and hands them all to emcc.
            const emsdk = b.dependency("emsdk", .{});
            const bgfx_artifact = ctx.backend_dep.artifact("bgfx");
            const install = emLinkStep(b, .{
                .optimize = ctx.optimize,
                .lib_main = ctx.root_artifact,
                .lib_backend = bgfx_artifact,
                .emsdk = emsdk,
            });
            // `post_wire` is void, so it owns the install/run wiring (mirrors
            // raylib's wasm arm).
            b.getInstallStep().dependOn(&install.step);
            const run_step = b.step("run", "Serve WASM build");
            run_step.dependOn(&install.step);
        },
        .android => {
            const sysroot = getAndroidNdkSysroot(b) orelse
                @panic("Could not find Android NDK. Set ANDROID_NDK_HOME or ANDROID_HOME.");
            // REQUIRED — no `orelse 34` fallback (design §4 review-correction #6).
            const api = requireAndroidSdk(ctx) catch
                @panic("android_target_sdk must be populated for Android builds");
            const triple = ndkArchTriple(ctx.target.result.cpu.arch);
            const api_str = b.fmt("{d}", .{api});

            const include_dir = b.pathJoin(&.{ sysroot, "usr/include" });
            const sys_include_dir = b.pathJoin(&.{ sysroot, "usr/include", triple });
            const crt_dir = b.pathJoin(&.{ sysroot, "usr/lib", triple, api_str });

            // Per-API NDK library path + libc.txt on the .so root. The bgfx
            // artifact's C++ TUs are already NDK-wired by the backend build.zig, so
            // — unlike sokol — no `addSystemIncludePath` on the artifact here.
            ctx.root_artifact.root_module.addLibraryPath(.{ .cwd_relative = crt_dir });
            const libc_content = libcTxt(b.allocator, include_dir, sys_include_dir, crt_dir) catch @panic("OOM");
            const android_libc = b.addWriteFiles();
            ctx.root_artifact.setLibCFile(android_libc.add("android-libc.txt", libc_content));
        },
        .ios => @panic("bgfx backend has no ios platform"),
    }
}

// ============================================================================
// Tests — the PURE residual/decision helpers (design §7 "run the hook").
//
// These typecheck `resolve_target`/`post_wire` against the real `std.Build` API — a
// compile-level gate that a residual API call (addLibraryPath/setLibCFile/
// resolveTargetQuery/…) stays valid. The pure helpers below then assert the residual
// DECISIONS (arch selection, NDK triple, required-SDK enforcement, libc.txt body)
// without a live `*std.Build`.
// ============================================================================

const testing = std.testing;

test "HOOK_ABI_VERSION is 2 (matches manifest_v2)" {
    try testing.expectEqual(@as(u8, 2), HOOK_ABI_VERSION);
}

test "selectAndroidArch: explicit -Dandroid_arch wins (both spellings)" {
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.x86_64, false, "arm64"));
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.x86_64, true, "aarch64"));
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, try selectAndroidArch(.aarch64, false, "x86_64"));
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, try selectAndroidArch(.aarch64, true, "x64"));
}

test "selectAndroidArch: emulator picks host arch; default is arm64" {
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.aarch64, true, null));
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, try selectAndroidArch(.x86_64, true, null));
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.aarch64, false, null));
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.x86_64, false, null));
}

test "selectAndroidArch: unknown explicit arch is an error, not a silent default" {
    try testing.expectError(HookError.InvalidAndroidArch, selectAndroidArch(.aarch64, false, "riscv64"));
}

test "ndkArchTriple: the two resolvable arches map to the NDK triples" {
    try testing.expectEqualStrings("aarch64-linux-android", ndkArchTriple(.aarch64));
    try testing.expectEqualStrings("x86_64-linux-android", ndkArchTriple(.x86_64));
}

test "requireAndroidSdk: present value is returned; null is a hard error (no 34 default)" {
    const base: HookContext = .{
        .manifest_version = HOOK_ABI_VERSION,
        .backend_dep = undefined,
        .root_module = undefined,
        .root_artifact = undefined,
        .target = undefined,
        .optimize = .Debug,
        .platform = .android,
        .ios_sdk_path = null,
        .android_target_sdk = 30,
    };
    try testing.expectEqual(@as(u32, 30), try requireAndroidSdk(base));

    var missing = base;
    missing.android_target_sdk = null;
    try testing.expectError(HookError.AndroidTargetSdkRequired, requireAndroidSdk(missing));
}

test "libcTxt: body points the compiler at the NDK sysroot (matches the enum block)" {
    const out = try libcTxt(
        testing.allocator,
        "/ndk/sysroot/usr/include",
        "/ndk/sysroot/usr/include/aarch64-linux-android",
        "/ndk/sysroot/usr/lib/aarch64-linux-android/34",
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "include_dir=/ndk/sysroot/usr/include\n" ++
            "sys_include_dir=/ndk/sysroot/usr/include/aarch64-linux-android\n" ++
            "crt_dir=/ndk/sysroot/usr/lib/aarch64-linux-android/34\n" ++
            "msvc_lib_dir=\n" ++
            "kernel32_lib_dir=\n" ++
            "gcc_dir=\n",
        out,
    );
}

test "wasm emcc args: WebGL2 + proc-address + memory-growth + 512 KB stack (labelle-bgfx#8)" {
    // The bgfx-specific wasm settings are pinned here; `emLinkStep` itself is
    // typechecked against std.Build by compiling this file as a test target. bgfx
    // owns its WebGL2 context (no GLFW emulation / no asyncify), so the flag set is
    // WebGL2 + the GL proc-address helper + the backend-agnostic memory/stack args.
    try testing.expectEqualStrings("-sSTACK_SIZE=524288", wasm_stack_size_arg);
    try testing.expectEqualStrings("-sALLOW_MEMORY_GROWTH=1", wasm_allow_memory_growth_arg);
    try testing.expectEqualStrings("-sMIN_WEBGL_VERSION=2", wasm_min_webgl_arg);
    try testing.expectEqualStrings("-sMAX_WEBGL_VERSION=2", wasm_max_webgl_arg);
    try testing.expectEqualStrings("-sGL_ENABLE_GET_PROC_ADDRESS=1", wasm_gl_get_proc_address_arg);
}

test "selectGreatestValidNdk: a stray dir doesn't shadow a valid older NDK" {
    const c1 = [_]NdkCandidate{
        .{ .name = "25.2.9519653", .has_sysroot = true },
        .{ .name = "26.1.10909125", .has_sysroot = true },
        .{ .name = "27.0.0", .has_sysroot = false },
    };
    try testing.expectEqualStrings("26.1.10909125", selectGreatestValidNdk(&c1).?);
    try testing.expectEqual(@as(?[]const u8, null), selectGreatestValidNdk(&.{}));
}
