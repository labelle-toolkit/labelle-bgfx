//! Generic bgfx renderer selection + init diagnostics (labelle-bgfx#176,
//! RFC labelle-bgfx#172 D1/D4).
//!
//! `LABELLE_BGFX_RENDERER` is read on EVERY platform before `bgfx.init`. This
//! file holds only the pure policy — the value → renderer table and the
//! requested/actual verdict — so it runs as a plain host test with no GPU and
//! no bgfx library linked (only the `RendererType` enum is referenced). The
//! `getenv` call and the `bgfx.init` sequencing live in `window.zig`.
//!
//! The windowed-desktop platform policy (which renderer each OS uses when the
//! variable is unset, and which renderer it retries after an init failure) is
//! here too, as a pure function of the OS tag so every row is host-testable
//! from any machine. `window.zig` calls it with `builtin.target.os.tag`.
const std = @import("std");
const bgfx = @import("zbgfx").bgfx;

pub const RendererType = bgfx.RendererType;

/// The environment variable read before every `bgfx.init`.
pub const env_name = "LABELLE_BGFX_RENDERER";

/// Result of parsing the variable's value, before any logging.
pub const Parsed = union(enum) {
    /// Unset or empty: keep the platform default.
    unset,
    /// Not in the table: warn (naming it) and keep the platform default.
    invalid: []const u8,
    /// An explicit renderer request.
    renderer: RendererType,
};

/// The fixed interface table (labelle-bgfx#176). Case-insensitive, no trimming.
const table = [_]struct { name: []const u8, renderer: RendererType }{
    .{ .name = "vulkan", .renderer = .Vulkan },
    .{ .name = "vk", .renderer = .Vulkan },
    .{ .name = "gles", .renderer = .OpenGLES },
    .{ .name = "opengles", .renderer = .OpenGLES },
    .{ .name = "opengl", .renderer = .OpenGL },
    .{ .name = "gl", .renderer = .OpenGL },
    .{ .name = "metal", .renderer = .Metal },
};

/// Pure parse of `LABELLE_BGFX_RENDERER`'s value (`null` = unset).
pub fn parse(value: ?[]const u8) Parsed {
    const raw = value orelse return .unset;
    if (raw.len == 0) return .unset;
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(raw, row.name)) return .{ .renderer = row.renderer };
    }
    return .{ .invalid = raw };
}

/// The renderer `value` explicitly requests, or `null` to keep the platform
/// default. An unknown value logs a warning naming it, then returns `null`.
pub fn rendererFromEnv(value: ?[]const u8) ?RendererType {
    return switch (parse(value)) {
        .unset => null,
        .invalid => |raw| blk: {
            std.log.warn(
                "bgfx: ignoring unknown " ++ env_name ++ "='{s}' (expected vulkan|vk, gles|opengles, opengl|gl or metal); using the platform default",
                .{raw},
            );
            break :blk null;
        },
        .renderer => |r| r,
    };
}

/// Printable renderer name for the D4 log line. `.Count` is bgfx's auto-select.
pub fn rendererName(r: RendererType) []const u8 {
    return if (r == .Count) "auto" else @tagName(r);
}

/// Whether this backend ships shader variants for `r`: the renderers
/// `gfx/programs.zig` has embedded arms for (Metal `mtl`, Vulkan `spv`,
/// OpenGLES `essl`, OpenGL `glsl`). Any other renderer would be handed GLSL
/// bytecode it cannot load: invalid programs, imgui off, and a crash at the
/// first sprite (labelle-bgfx#30, labelle-engine#683). The switch is
/// exhaustive on purpose, so a renderer added to bgfx's enum is a compile
/// error here rather than a silent "supported".
pub fn hasShaderVariants(r: RendererType) bool {
    return switch (r) {
        .Metal, .Vulkan, .OpenGLES, .OpenGL => true,
        .Noop, .Agc, .Direct3D11, .Direct3D12, .Gnm, .Nvn, .WebGPU, .Count => false,
    };
}

/// D4 verdict on a `bgfx.init` that returned true.
pub const InitVerdict = enum {
    /// Got what was asked for (or `auto` picked a real renderer).
    ok,
    /// bgfx's fallback started a different renderer than the explicit request
    /// (one we ship shaders for, so it is kept).
    fallback,
    /// bgfx came up on `Noop`: nothing renders. Treated as an init failure.
    noop,
    /// bgfx came up on a renderer this backend ships no shader variants for
    /// (e.g. Direct3D11 after bgfx's internal fallback on Windows, PR #194).
    /// Treated as an init failure, so the caller's retry path runs.
    unsupported,
};

pub fn classify(requested: RendererType, actual: RendererType) InitVerdict {
    if (actual == .Noop) return .noop;
    if (!hasShaderVariants(actual)) return .unsupported;
    if (requested == .Count or requested == actual) return .ok;
    return .fallback;
}

/// Whether a verdict keeps the context (`ok`/`fallback`) or turns the init
/// into a failure (`noop`/`unsupported`: shutdown + the caller's failure path).
pub fn accepted(verdict: InitVerdict) bool {
    return switch (verdict) {
        .ok, .fallback => true,
        .noop, .unsupported => false,
    };
}

/// One `bgfx.init` attempt, end to end: `init_returned` is what `bgfx.init`
/// returned, `actual` is `bgfx.getRendererType()` after it. `true` = keep the
/// context; `false` = the attempt failed (the caller shuts a live context down
/// and consults `initRetryRenderer`).
pub fn attemptAccepted(requested: RendererType, init_returned: bool, actual: RendererType) bool {
    return init_returned and accepted(classify(requested, actual));
}

/// Log the D4 line for a successful `bgfx.init` and return the verdict. The
/// caller turns `.noop` into an init failure (shutdown + its failure path).
pub fn reportInit(requested: RendererType, actual: RendererType) InitVerdict {
    const verdict = classify(requested, actual);
    std.log.info("bgfx: renderer requested={s} actual={s}", .{ rendererName(requested), rendererName(actual) });
    switch (verdict) {
        .ok => {},
        .fallback => std.log.warn(
            "bgfx: renderer fallback: requested {s} but bgfx started {s}",
            .{ rendererName(requested), rendererName(actual) },
        ),
        .noop => std.log.err(
            "bgfx: renderer requested={s} came up as Noop (nothing would render); treating as an init failure",
            .{rendererName(requested)},
        ),
        .unsupported => std.log.err(
            "bgfx: renderer requested={s} came up as {s}, which this backend ships no shader variants for; treating as an init failure",
            .{ rendererName(requested), rendererName(actual) },
        ),
    }
    return verdict;
}

/// Windowed-desktop renderer policy for one OS (labelle-bgfx#30, #193).
pub const DesktopPolicy = struct {
    /// Renderer requested when `LABELLE_BGFX_RENDERER` is unset/invalid.
    /// `.Count` = bgfx auto-select.
    default: RendererType,
    /// Renderer retried ONCE when `bgfx.init` with the requested renderer fails
    /// (or comes up `Noop`). `null` = no retry: the init fails outright.
    init_fallback: ?RendererType,
};

/// The windowed-desktop policy for `os`.
///
/// - **Windows → Vulkan, OpenGL retry.** bgfx's auto-select picks Direct3D11
///   there, and this backend ships no Direct3D shader variants
///   (`gfx/programs.zig` has only Metal/Vulkan/GLES/GLSL arms), so auto would
///   hand D3D GLSL bytecode and crash at the first sprite (labelle-bgfx#30,
///   labelle-engine#683).
/// - **Linux → Vulkan, OpenGL retry.** Owner decision (2026-10-01, RFC #172,
///   labelle-bgfx#193): Vulkan is the default whenever bgfx is used. The
///   OpenGL retry keeps a box without a working Vulkan driver starting.
/// - **macOS → auto (Metal), no retry.** Metal is the deliberate macOS choice
///   (owner decision, 2026-10-01: the best renderer there), not a missing
///   Vulkan feature. Do NOT switch macOS to Vulkan. `.Count` resolves to
///   Metal; the build also has no MoltenVK.
/// - **Everything else → auto, no retry:** bgfx's own choice.
pub fn desktopPolicy(os: std.Target.Os.Tag) DesktopPolicy {
    return switch (os) {
        .windows, .linux => .{ .default = .Vulkan, .init_fallback = .OpenGL },
        else => .{ .default = .Count, .init_fallback = null },
    };
}

/// Which `bgfx.init` attempt of the windowed-desktop sequence.
pub const Attempt = enum { initial, retry };

/// The value for `bgfx.Init.fallback` on `attempt`.
///
/// bgfx's `Init::Init` defaults `fallback = true`, and `rendererCreate` then
/// walks its per-platform score list when the requested renderer fails to
/// create. On Windows that list puts Direct3D11/12 first, so a failed Vulkan
/// init "succeeds" on Direct3D11 (reproduced by Codex on PR #194 with
/// `VK_ICD_FILENAMES` pointed at a bogus ICD), and our OpenGL retry never runs.
///
/// So: where the policy owns a retry (`init_fallback != null`: Windows and
/// Linux) the internal fallback is OFF on every attempt, so a failed request
/// returns `false` and the policy decides what comes next. The retry itself is
/// always OFF too: a failed OpenGL retry must fail, never land on Direct3D.
/// Policies with no retry of their own (macOS, other OSes) keep bgfx's
/// default: macOS behaviour is unchanged (auto → Metal). `classify` still
/// rejects an unsupported actual renderer on every path as a second guard.
pub fn bgfxFallback(policy: DesktopPolicy, attempt: Attempt) bool {
    return switch (attempt) {
        .initial => policy.init_fallback == null,
        .retry => false,
    };
}

/// The renderer to retry with after `failed` did not init, or `null` for no
/// retry. Keyed on the platform (`policy.init_fallback`), not on whether the
/// request came from `LABELLE_BGFX_RENDERER`: an explicit `vulkan` that fails
/// on Windows/Linux still retries OpenGL (Windows' behaviour since #30). A
/// failed OpenGL request has nothing left to retry.
pub fn initRetryRenderer(policy: DesktopPolicy, failed: RendererType) ?RendererType {
    const fallback = policy.init_fallback orelse return null;
    return if (failed == fallback) null else fallback;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "rendererFromEnv: vulkan, vk -> Vulkan (any case)" {
    for ([_][]const u8{ "vulkan", "vk", "VULKAN", "Vk", "VuLkAn" }) |v|
        try testing.expectEqual(@as(?RendererType, .Vulkan), rendererFromEnv(v));
}

test "rendererFromEnv: gles, opengles -> OpenGLES (any case)" {
    for ([_][]const u8{ "gles", "opengles", "GLES", "OpenGLES" }) |v|
        try testing.expectEqual(@as(?RendererType, .OpenGLES), rendererFromEnv(v));
}

test "rendererFromEnv: opengl, gl -> OpenGL (any case)" {
    for ([_][]const u8{ "opengl", "gl", "OpenGL", "GL" }) |v|
        try testing.expectEqual(@as(?RendererType, .OpenGL), rendererFromEnv(v));
}

test "rendererFromEnv: metal -> Metal (any case)" {
    for ([_][]const u8{ "metal", "METAL", "Metal" }) |v|
        try testing.expectEqual(@as(?RendererType, .Metal), rendererFromEnv(v));
}

test "rendererFromEnv: unset or empty keeps the platform default" {
    try testing.expectEqual(@as(?RendererType, null), rendererFromEnv(null));
    try testing.expectEqual(@as(?RendererType, null), rendererFromEnv(""));
    try testing.expectEqual(Parsed.unset, parse(null));
    try testing.expectEqual(Parsed.unset, parse(""));
}

test "rendererFromEnv: anything else is invalid (named) and keeps the default" {
    // Assert the MECHANISM (the invalid arm, carrying the value for the
    // warning), not only the null result an unset value would also give.
    for ([_][]const u8{ "d3d11", "auto", " vulkan", "vulkan ", "vulkan1", "opengl es", "noop" }) |v| {
        switch (parse(v)) {
            .invalid => |raw| try testing.expectEqualStrings(v, raw),
            else => return error.TestExpectedInvalid,
        }
    }
    // One end-to-end call through the warning arm. Silence the (expected)
    // warning so the test output stays clean; the test runner resets
    // `log_level` before each test anyway.
    testing.log_level = .err;
    defer testing.log_level = .warn;
    try testing.expectEqual(@as(?RendererType, null), rendererFromEnv("d3d11"));
}

test "classify: auto and exact matches are ok" {
    try testing.expectEqual(InitVerdict.ok, classify(.Count, .Metal));
    try testing.expectEqual(InitVerdict.ok, classify(.Count, .OpenGLES));
    try testing.expectEqual(InitVerdict.ok, classify(.Vulkan, .Vulkan));
    try testing.expectEqual(InitVerdict.ok, classify(.Metal, .Metal));
}

test "classify: a different actual renderer is a fallback" {
    try testing.expectEqual(InitVerdict.fallback, classify(.Vulkan, .OpenGLES));
    try testing.expectEqual(InitVerdict.fallback, classify(.Vulkan, .OpenGL));
    try testing.expectEqual(InitVerdict.fallback, classify(.Metal, .Vulkan));
}

test "classify: Noop is always a failure, requested or auto" {
    try testing.expectEqual(InitVerdict.noop, classify(.Count, .Noop));
    try testing.expectEqual(InitVerdict.noop, classify(.Vulkan, .Noop));
    try testing.expectEqual(InitVerdict.noop, classify(.OpenGL, .Noop));
}

test "rendererName: auto for Count, tag name otherwise" {
    try testing.expectEqualStrings("auto", rendererName(.Count));
    try testing.expectEqualStrings("Vulkan", rendererName(.Vulkan));
    try testing.expectEqualStrings("OpenGLES", rendererName(.OpenGLES));
}

test "desktopPolicy: Windows and Linux default to Vulkan with an OpenGL retry" {
    for ([_]std.Target.Os.Tag{ .windows, .linux }) |os| {
        const p = desktopPolicy(os);
        try testing.expectEqual(RendererType.Vulkan, p.default);
        try testing.expectEqual(@as(?RendererType, .OpenGL), p.init_fallback);
    }
}

test "desktopPolicy: macOS stays on auto (Metal), never Vulkan, no retry" {
    // Owner decision (2026-10-01): Metal is the macOS renderer. `.Count` is
    // bgfx auto-select, which resolves to Metal on macOS.
    const p = desktopPolicy(.macos);
    try testing.expectEqual(RendererType.Count, p.default);
    try testing.expect(p.default != .Vulkan);
    try testing.expectEqual(@as(?RendererType, null), p.init_fallback);
}

test "desktopPolicy: other OSes keep auto-select with no retry" {
    for ([_]std.Target.Os.Tag{ .freebsd, .openbsd, .netbsd }) |os| {
        const p = desktopPolicy(os);
        try testing.expectEqual(RendererType.Count, p.default);
        try testing.expectEqual(@as(?RendererType, null), p.init_fallback);
    }
}

test "initRetryRenderer: a failed Vulkan default retries OpenGL on Windows and Linux" {
    for ([_]std.Target.Os.Tag{ .windows, .linux }) |os| {
        const p = desktopPolicy(os);
        try testing.expectEqual(@as(?RendererType, .OpenGL), initRetryRenderer(p, p.default));
    }
}

test "initRetryRenderer: explicit non-GL requests retry OpenGL; a failed OpenGL does not" {
    const p = desktopPolicy(.linux);
    // Explicit LABELLE_BGFX_RENDERER requests go through the same retry.
    try testing.expectEqual(@as(?RendererType, .OpenGL), initRetryRenderer(p, .Vulkan));
    try testing.expectEqual(@as(?RendererType, .OpenGL), initRetryRenderer(p, .OpenGLES));
    // OpenGL already failed: nothing left, no infinite retry.
    try testing.expectEqual(@as(?RendererType, null), initRetryRenderer(p, .OpenGL));
}

test "initRetryRenderer: no retry on macOS, whatever was requested" {
    const p = desktopPolicy(.macos);
    for ([_]RendererType{ .Count, .Metal, .Vulkan, .OpenGL }) |r|
        try testing.expectEqual(@as(?RendererType, null), initRetryRenderer(p, r));
}

test "hasShaderVariants: exactly the shipped set (mtl/spv/essl/glsl)" {
    // Every RendererType, so a new bgfx renderer can't slip past this table.
    inline for (@typeInfo(RendererType).@"enum".fields) |f| {
        const r: RendererType = @enumFromInt(f.value);
        const expected = switch (r) {
            .Metal, .Vulkan, .OpenGLES, .OpenGL => true,
            else => false,
        };
        try testing.expectEqual(expected, hasShaderVariants(r));
    }
    for ([_]RendererType{ .Noop, .Agc, .Direct3D11, .Direct3D12, .Gnm, .Nvn, .WebGPU, .Count }) |r|
        try testing.expect(!hasShaderVariants(r));
}

test "classify: an actual renderer with no shader variants is unsupported" {
    // The PR #194 Windows repro: Vulkan requested, bgfx's internal fallback
    // started Direct3D11. Not a kept `.fallback` any more.
    try testing.expectEqual(InitVerdict.unsupported, classify(.Vulkan, .Direct3D11));
    try testing.expectEqual(InitVerdict.unsupported, classify(.OpenGL, .Direct3D11));
    try testing.expectEqual(InitVerdict.unsupported, classify(.Count, .Direct3D11));
    for ([_]RendererType{ .Agc, .Direct3D12, .Gnm, .Nvn, .WebGPU }) |r|
        try testing.expectEqual(InitVerdict.unsupported, classify(.Vulkan, r));
    // Noop keeps its own verdict (checked first).
    try testing.expectEqual(InitVerdict.noop, classify(.Vulkan, .Noop));
}

test "accepted: ok and fallback keep the context; noop and unsupported fail" {
    try testing.expect(accepted(.ok));
    try testing.expect(accepted(.fallback));
    try testing.expect(!accepted(.noop));
    try testing.expect(!accepted(.unsupported));
}

test "bgfxFallback: Windows and Linux disable bgfx's internal fallback on both attempts" {
    for ([_]std.Target.Os.Tag{ .windows, .linux }) |os| {
        const p = desktopPolicy(os);
        try testing.expectEqual(false, bgfxFallback(p, .initial));
        try testing.expectEqual(false, bgfxFallback(p, .retry));
    }
}

test "bgfxFallback: macOS and other OSes keep bgfx's default on the initial attempt" {
    // No policy-owned retry there, so bgfx's own fallback is unchanged
    // (macOS: auto -> Metal, owner decision). A retry never happens on these
    // policies, but if it did it would still be fallback=false.
    for ([_]std.Target.Os.Tag{ .macos, .freebsd, .openbsd, .netbsd }) |os| {
        const p = desktopPolicy(os);
        try testing.expectEqual(true, bgfxFallback(p, .initial));
        try testing.expectEqual(false, bgfxFallback(p, .retry));
        try testing.expectEqual(@as(?RendererType, null), initRetryRenderer(p, p.default));
    }
}

test "init sequence: Vulkan 'succeeding' on Direct3D11 is rejected and retries OpenGL" {
    // PR #194 repro, end to end through the pure policy: bgfx.init returned
    // true but the actual renderer is Direct3D11.
    for ([_]std.Target.Os.Tag{ .windows, .linux }) |os| {
        const p = desktopPolicy(os);
        const requested = p.default;
        // The mechanism: the attempt is rejected because of the verdict,
        // not because init returned false.
        try testing.expectEqual(InitVerdict.unsupported, classify(requested, .Direct3D11));
        try testing.expect(!attemptAccepted(requested, true, .Direct3D11));
        const retry = initRetryRenderer(p, requested) orelse return error.TestExpectedRetry;
        try testing.expectEqual(RendererType.OpenGL, retry);
        try testing.expectEqual(false, bgfxFallback(p, .retry));
        // The retry is accepted on OpenGL, rejected on Direct3D (defensive:
        // fallback=false should make that impossible), and never retries again.
        try testing.expect(attemptAccepted(retry, true, .OpenGL));
        try testing.expect(!attemptAccepted(retry, true, .Direct3D11));
        try testing.expect(!attemptAccepted(retry, false, .OpenGL));
        try testing.expectEqual(@as(?RendererType, null), initRetryRenderer(p, retry));
    }
}

test "attemptAccepted: a false init or Noop fails; a real shipped renderer passes" {
    try testing.expect(!attemptAccepted(.Vulkan, false, .Vulkan));
    try testing.expect(!attemptAccepted(.Vulkan, true, .Noop));
    try testing.expect(attemptAccepted(.Vulkan, true, .Vulkan));
    try testing.expect(attemptAccepted(.Count, true, .Metal));
    try testing.expect(attemptAccepted(.Count, true, .OpenGLES));
}
