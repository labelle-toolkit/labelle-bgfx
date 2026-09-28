//! Guard for `gfx/heap.zig`: production code must allocate through
//! `heap.allocator`, never `std.heap.page_allocator` directly, because on
//! wasm page_allocator corrupts emscripten's malloc heap (see gfx/heap.zig).
//!
//! Walks every `.zig` file under `src/` at test time, so a NEW file that
//! reaches for page_allocator fails here too, not only the files fixed in
//! the original change. The run step sets the working directory to the
//! repository root (build.zig).
const std = @import("std");
const heap = @import("gfx/heap.zig");
const audio_heap = @import("audio_heap.zig");

/// Files allowed to name page_allocator: the two allocator files, and host-only
/// tools that never build for wasm (goldens, probes). The standalone Android
/// decode harness (`video/apk/native.zig`, `video/test_decode.zig`) was retired
/// with the decoder's move to labelle-android (#149 phase 1d, cli#405).
const allowed = [_][]const u8{
    "gfx/heap.zig",
    "audio_heap.zig",
    "heap_guard_test.zig",
    "material_golden.zig",
    "post_fx_golden.zig",
    "post_fx_integration_golden.zig",
    "screenshot_probe.zig",
    "shader_material_probe.zig",
    "texture_sampling_probe.zig",
};

/// `path` as the walker returns it: native separators, so `\\` on Windows.
fn isAllowed(path: []const u8) bool {
    for (allowed) |a| {
        if (a.len != path.len) continue;
        const same = for (a, path) |x, y| {
            const yy: u8 = if (y == '\\') '/' else y;
            if (x != yy) break false;
        } else true;
        if (same) return true;
    }
    return false;
}

test "the allowlist matches Windows-style walker paths" {
    try std.testing.expect(isAllowed("gfx/heap.zig"));
    try std.testing.expect(isAllowed("gfx\\heap.zig"));
    // The retired Android harness must NOT be allowlisted any more (#149 1d).
    try std.testing.expect(!isAllowed("video\\apk\\native.zig"));
    try std.testing.expect(!isAllowed("gfx\\texture.zig"));
}

test "no production file names std.heap.page_allocator" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var src = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(gpa);
    defer walker.deinit();

    var offenders: std.ArrayList([]const u8) = .empty;
    defer {
        for (offenders.items) |o| gpa.free(o);
        offenders.deinit(gpa);
    }
    var scanned: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        scanned += 1;
        if (isAllowed(entry.path)) continue;
        const bytes = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 << 20));
        defer gpa.free(bytes);
        if (std.mem.indexOf(u8, bytes, "std.heap.page_allocator") != null) {
            try offenders.append(gpa, try gpa.dupe(u8, entry.path));
        }
    }
    for (offenders.items) |o| std.debug.print("src/{s} names std.heap.page_allocator; use heap.allocator (src/gfx/heap.zig)\n", .{o});
    // The walk really covered the tree (a wrong cwd would scan nothing and pass).
    // Floor lowered 50 → 40 as the Android services move out to
    // labelle-android (#149); still far above an empty or wrong-cwd walk.
    try std.testing.expect(scanned > 40);
    try std.testing.expectEqual(@as(usize, 0), offenders.items.len);
}

test "the host build keeps page_allocator; only emscripten switches to malloc" {
    try std.testing.expect(!heap.on_emscripten);
    try std.testing.expectEqual(std.heap.page_allocator.vtable, heap.allocator.vtable);
    // The audio module's mirror must pick the same allocator.
    try std.testing.expectEqual(heap.on_emscripten, audio_heap.on_emscripten);
    try std.testing.expectEqual(heap.allocator.vtable, audio_heap.allocator.vtable);
}
