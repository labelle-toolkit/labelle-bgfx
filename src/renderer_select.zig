//! Generic bgfx renderer selection + init diagnostics (labelle-bgfx#176,
//! RFC labelle-bgfx#172 D1/D4).
//!
//! `LABELLE_BGFX_RENDERER` is read on EVERY platform before `bgfx.init`. This
//! file holds only the pure policy — the value → renderer table and the
//! requested/actual verdict — so it runs as a plain host test with no GPU and
//! no bgfx library linked (only the `RendererType` enum is referenced). The
//! `getenv` call and the `bgfx.init` sequencing live in `window.zig`.
//!
//! Platform policy (which renderer a platform USES when the variable is unset)
//! also stays in `window.zig`; nothing here is platform-specific.
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

/// D4 verdict on a `bgfx.init` that returned true.
pub const InitVerdict = enum {
    /// Got what was asked for (or `auto` picked a real renderer).
    ok,
    /// bgfx's fallback started a different renderer than the explicit request.
    fallback,
    /// bgfx came up on `Noop`: nothing renders. Treated as an init failure.
    noop,
};

pub fn classify(requested: RendererType, actual: RendererType) InitVerdict {
    if (actual == .Noop) return .noop;
    if (requested == .Count or requested == actual) return .ok;
    return .fallback;
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
    }
    return verdict;
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
    try testing.expectEqual(InitVerdict.fallback, classify(.Vulkan, .Direct3D11));
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
