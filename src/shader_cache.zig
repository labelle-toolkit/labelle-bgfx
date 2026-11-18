//! Persistent shader cache behind bgfx's `cacheReadSize` / `cacheRead` /
//! `cacheWrite` callbacks (labelle-bgfx#217).
//!
//! bgfx asks these callbacks for a linked GL/GLES program's binary
//! (`glGetProgramBinary`, keyed by an id that folds in the GL vendor, renderer
//! and version strings) and, on Vulkan, for each pipeline's cache data (keyed
//! by the pipeline state hash, written right after the pipeline is created, so
//! it survives an app that is killed rather than shut down). With
//! the callbacks declining (bgfx's stub default, and this backend's until
//! #217), every program compiled and linked from source on every run, which
//! on a slow mobile driver is a visible hitch the first time each effect
//! appears. With them backed by files, only a program's first ever use pays.
//!
//! One file per id, `<dir>/<id as 16 hex digits>.bin`:
//!
//!     "LBSC" | format version u32 | payload size u32 | payload CRC-32 u32 | payload
//!
//! all little-endian. The header is there because bgfx trusts the cache
//! completely: on GL, once `cacheReadSize` reports a size it hands the bytes
//! to `glProgramBinary` and never falls back to compiling, so a truncated
//! file (the process killed mid-write, which Android does freely) would
//! leave that material broken for good. So `readSize` validates the WHOLE
//! file (magic, version, length and checksum) before reporting a size, and
//! anything it doesn't like reads as a miss, so bgfx compiles and overwrites
//! it. Writes go to a temporary file renamed into place, so a reader never
//! sees a half-written entry.
//!
//! The same trust is why the Android directory is keyed by the build
//! fingerprint (`ro.build.fingerprint`): an OS update can change the driver
//! without changing the GL version string bgfx keys on, and a binary the new
//! driver rejects would never be recompiled. A new fingerprint is a new,
//! empty directory.
//!
//! Measured on a Samsung SM-T505 (Adreno 610, Vulkan, Flying Platform's
//! `debug/turbine_bomb`): the first drone explosion of every launch cost a
//! 133-134 ms frame, a pipeline created on first draw. With the cache warm
//! (second launch) that frame is gone: 60 fps, worst frame 17 ms.
//!
//! Off until `configure` gives it a directory, so desktop and web behave as
//! before (Metal and WebGL never call these callbacks anyway).
//! `LABELLE_BGFX_SHADER_CACHE=<dir>` turns it on anywhere; `=off` turns the
//! Android default off.
//!
//! All I/O is plain libc, as in the screenshot writer: the callbacks run on
//! bgfx's render thread with no allocator in hand, so nothing here
//! allocates. A write goes to a temp file unique to that write (pid and a
//! counter), created exclusively without following links, then renamed into
//! place, so two processes sharing a directory can't write through one temp
//! file and a planted link can't be truncated.
//!
//! POSIX only (Android, Linux, macOS): Windows' CRT `rename` refuses to
//! replace an existing file, so a rejected entry could never be healed. On
//! Windows the cache stays off; it was opt-in there anyway.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this platform can host the cache (see the header).
pub const supported = builtin.os.tag != .windows;

const log = std.log.scoped(.bgfx_shader_cache);

const magic = "LBSC";
const format_version: u32 = 1;
const header_len = 16;
/// Larger payloads are neither written nor trusted on read. Program binaries
/// are kilobytes; a Vulkan pipeline cache can reach a few megabytes.
pub const max_payload: u32 = 32 * 1024 * 1024;

/// Longest directory accepted. Paths are built in fixed stack buffers.
pub const max_dir = 900;

var dir_buf: [max_dir + 1:0]u8 = undefined;
var dir_len: usize = 0;

/// Counters, for logs and tests. Render thread only.
pub const Stats = struct { hits: u32 = 0, misses: u32 = 0, rejected: u32 = 0, writes: u32 = 0, write_failures: u32 = 0 };
pub var stats: Stats = .{};

pub fn enabled() bool {
    return dir_len != 0;
}

/// Use `dir` (created if missing, parents included) for the cache, or turn it
/// off with null. Call before `bgfx.init`: bgfx's threads start there, which
/// orders this write before every callback's read.
pub fn configure(dir: ?[]const u8) void {
    dir_len = 0;
    const d = dir orelse return;
    if (comptime !supported) {
        log.warn("shader cache: not supported on this platform; off", .{});
        return;
    }
    const trimmed = std.mem.trimEnd(u8, d, "/");
    if (trimmed.len == 0 or trimmed.len > max_dir) {
        log.warn("shader cache disabled: directory path is empty or longer than {d} bytes", .{max_dir});
        return;
    }
    @memcpy(dir_buf[0..trimmed.len], trimmed);
    dir_buf[trimmed.len] = 0;
    if (!makePath(dir_buf[0..trimmed.len :0])) {
        log.warn("shader cache disabled: could not create {s}", .{trimmed});
        return;
    }
    dir_len = trimmed.len;
    stats = .{};
    log.info("shader cache: {s}", .{trimmed});
}

/// The configured directory, or null when the cache is off.
pub fn directory() ?[]const u8 {
    return if (dir_len == 0) null else dir_buf[0..dir_len];
}

/// `mkdir -p`. True when `path` is a directory afterwards: an existing
/// regular file of that name (`EEXIST` from `mkdir`) is not.
fn makePath(path: [:0]u8) bool {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        const saved = path[i];
        path[i] = 0;
        defer path[i] = saved;
        if (std.c.mkdir(path[0..i :0].ptr, 0o700) != 0 and std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return false;
    }
    const dir = std.c.opendir(path.ptr) orelse return false;
    _ = std.c.closedir(dir);
    return true;
}

/// `<dir>/<id>.bin`.
fn entryPath(buf: *[max_dir + 64:0]u8, id: u64, suffix: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{x:0>16}{s}", .{ dir_buf[0..dir_len], id, suffix }) catch unreachable;
}

/// Temp names are unique per write: this process's id and a counter.
var tmp_counter: u32 = 0;

fn processId() u64 {
    if (comptime !supported) return 0;
    return @intCast(std.c.getpid());
}

/// `<dir>/<id>.<pid>.<n>.tmp`, for one write in progress.
fn tempPath(buf: *[max_dir + 64:0]u8, id: u64) [:0]const u8 {
    tmp_counter +%= 1;
    return std.fmt.bufPrintZ(buf, "{s}/{x:0>16}.{d}.{d}.tmp", .{ dir_buf[0..dir_len], id, processId(), tmp_counter }) catch unreachable;
}

/// The header bgfx's payload of `size` bytes and checksum `crc` is stored under.
pub fn header(size: u32, crc: u32) [header_len]u8 {
    var h: [header_len]u8 = undefined;
    @memcpy(h[0..4], magic);
    std.mem.writeInt(u32, h[4..8], format_version, .little);
    std.mem.writeInt(u32, h[8..12], size, .little);
    std.mem.writeInt(u32, h[12..16], crc, .little);
    return h;
}

/// The payload size a header promises, or null when it isn't one of ours.
pub fn parseHeader(h: *const [header_len]u8) ?struct { size: u32, crc: u32 } {
    if (!std.mem.eql(u8, h[0..4], magic)) return null;
    if (std.mem.readInt(u32, h[4..8], .little) != format_version) return null;
    const size = std.mem.readInt(u32, h[8..12], .little);
    if (size == 0 or size > max_payload) return null;
    return .{ .size = size, .crc = std.mem.readInt(u32, h[12..16], .little) };
}

/// Checks an entry end to end (magic, version, length, checksum) and
/// returns its payload size, or null for a missing or bad entry.
fn validSize(id: u64) ?u32 {
    var path_buf: [max_dir + 64:0]u8 = undefined;
    const file = std.c.fopen(entryPath(&path_buf, id, ".bin").ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);
    var h: [header_len]u8 = undefined;
    if (std.c.fread(&h, 1, h.len, file) != h.len) return null;
    const meta = parseHeader(&h) orelse return null;
    var crc = std.hash.Crc32.init();
    var chunk: [16 * 1024]u8 = undefined;
    var left: usize = meta.size;
    while (left > 0) {
        const n = std.c.fread(&chunk, 1, @min(chunk.len, left), file);
        if (n == 0) return null;
        crc.update(chunk[0..n]);
        left -= n;
    }
    if (std.c.fread(&chunk, 1, 1, file) != 0) return null; // trailing bytes
    if (crc.final() != meta.crc) return null;
    return meta.size;
}

/// bgfx `cacheReadSize`: the payload size of a VALID entry, else 0 (a miss,
/// which makes bgfx compile and then `write`).
pub fn readSize(id: u64) u32 {
    if (!enabled()) return 0;
    return validSize(id) orelse {
        if (exists(id)) {
            stats.rejected += 1;
            log.warn("shader cache: entry {x:0>16} is damaged or stale; recompiling", .{id});
        } else stats.misses += 1;
        return 0;
    };
}

fn exists(id: u64) bool {
    var path_buf: [max_dir + 64:0]u8 = undefined;
    const file = std.c.fopen(entryPath(&path_buf, id, ".bin").ptr, "rb") orelse return false;
    _ = std.c.fclose(file);
    return true;
}

/// bgfx `cacheRead`: fill `out` with the entry's payload. bgfx calls it with
/// the size `readSize` just reported. Checked again on the one stream it is
/// read from (header, size, checksum, nothing after), not trusted from
/// `readSize`: the file could have been replaced in between.
pub fn read(id: u64, out: []u8) bool {
    if (!enabled()) return false;
    var path_buf: [max_dir + 64:0]u8 = undefined;
    const file = std.c.fopen(entryPath(&path_buf, id, ".bin").ptr, "rb") orelse return false;
    defer _ = std.c.fclose(file);
    var h: [header_len]u8 = undefined;
    if (std.c.fread(&h, 1, h.len, file) != h.len) return false;
    const meta = parseHeader(&h) orelse return false;
    if (meta.size != out.len) return false;
    if (std.c.fread(out.ptr, 1, out.len, file) != out.len) return false;
    var extra: [1]u8 = undefined;
    if (std.c.fread(&extra, 1, 1, file) != 0) return false;
    if (std.hash.Crc32.hash(out) != meta.crc) return false;
    stats.hits += 1;
    return true;
}

/// bgfx `cacheWrite`: store `data` under `id`, atomically.
pub fn write(id: u64, data: []const u8) void {
    if (!enabled() or data.len == 0) return;
    if (data.len > max_payload) {
        log.warn("shader cache: entry {x:0>16} ({d} bytes) is too large to store", .{ id, data.len });
        return;
    }
    var tmp_buf: [max_dir + 64:0]u8 = undefined;
    var bin_buf: [max_dir + 64:0]u8 = undefined;
    const tmp = tempPath(&tmp_buf, id);
    const bin = entryPath(&bin_buf, id, ".bin");
    const written = writeFile(tmp, data);
    if (written != .ok) {
        // Only a temp this write created is ours to remove.
        if (written == .failed) _ = std.c.unlink(tmp.ptr);
        stats.write_failures += 1;
        log.warn("shader cache: could not write {s}", .{tmp});
        return;
    }
    if (std.c.rename(tmp.ptr, bin.ptr) != 0) {
        _ = std.c.unlink(tmp.ptr);
        stats.write_failures += 1;
        log.warn("shader cache: could not move {s} into place", .{tmp});
        return;
    }
    stats.writes += 1;
    log.debug("shader cache: stored {x:0>16} ({d} bytes)", .{ id, data.len });
}

const Written = enum { ok, failed, not_created };

/// Writes header and payload to a NEW file at `path`: created exclusively,
/// without following a link, readable by this user only.
fn writeFile(path: [:0]const u8, data: []const u8) Written {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return .not_created;
    var ok = true;
    const h = header(@intCast(data.len), std.hash.Crc32.hash(data));
    if (!writeAll(fd, &h)) ok = false;
    if (ok and !writeAll(fd, data)) ok = false;
    if (std.c.close(fd) != 0) ok = false;
    return if (ok) .ok else .failed;
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// The Android cache directory under the app's private files dir, keyed by
/// the build fingerprint (see the file header). Empty when either is unknown.
pub fn androidDir(buf: []u8, files_dir: []const u8, fingerprint: []const u8) []const u8 {
    if (files_dir.len == 0 or fingerprint.len == 0) return buf[0..0];
    const key = std.hash.Wyhash.hash(0, fingerprint);
    return std.fmt.bufPrint(buf, "{s}/bgfx_shader_cache/{x:0>16}", .{ std.mem.trimEnd(u8, files_dir, "/"), key }) catch buf[0..0];
}

// ── Platform default ───────────────────────────────────────────────────

const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

/// The activity's files dir, exported by `android_app.zig` (a C symbol, so
/// this module doesn't import the shell). Only referenced on Android.
extern fn labelle_bgfx_internal_data_path() ?[*:0]const u8;
/// bionic's property API. Not `__system_property_get`: for a read-only
/// property longer than 91 bytes it returns a fixed diagnostic string, so two
/// builds with long fingerprints would hash alike (CodeRabbit on #219).
const PropInfo = opaque {};
extern "c" fn __system_property_find(name: [*:0]const u8) ?*const PropInfo;
extern "c" fn __system_property_read_callback(
    pi: *const PropInfo,
    callback: *const fn (cookie: ?*anyopaque, name: [*:0]const u8, value: [*:0]const u8, serial: u32) callconv(.c) void,
    cookie: ?*anyopaque,
) void;

const Fingerprint = struct { buf: [512]u8 = undefined, len: usize = 0 };

fn onProperty(cookie: ?*anyopaque, _: [*:0]const u8, value: [*:0]const u8, _: u32) callconv(.c) void {
    const out: *Fingerprint = @ptrCast(@alignCast(cookie.?));
    const v = std.mem.span(value);
    out.len = @min(v.len, out.buf.len);
    @memcpy(out.buf[0..out.len], v[0..out.len]);
}

pub const env_name = "LABELLE_BGFX_SHADER_CACHE";

/// What `env_name` asks for: off, a directory, or nothing (the default).
pub const Knob = union(enum) { default, off, dir: []const u8 };

pub fn parseKnob(raw: ?[]const u8) Knob {
    const v = std.mem.trim(u8, raw orelse return .default, " \t");
    if (v.len == 0) return .default;
    inline for (.{ "off", "0", "false", "no" }) |word| {
        if (std.ascii.eqlIgnoreCase(v, word)) return .off;
    }
    return .{ .dir = v };
}

/// Set the cache up for this platform. Called before every `bgfx.init`
/// (`bgfx_callback.install`): `LABELLE_BGFX_SHADER_CACHE` first, then the
/// Android default, else off.
pub fn configureForPlatform() void {
    switch (parseKnob(if (std.c.getenv(env_name)) |v| std.mem.span(v) else null)) {
        .off => return configure(null),
        .dir => |d| return configure(d),
        .default => {},
    }
    if (comptime !is_android) return configure(null);
    const files = labelle_bgfx_internal_data_path() orelse return configure(null);
    // No fingerprint, no default cache (a stale driver binary is the risk).
    const info = __system_property_find("ro.build.fingerprint") orelse return configure(null);
    var fp: Fingerprint = .{};
    __system_property_read_callback(info, &onProperty, &fp);
    var buf: [max_dir]u8 = undefined;
    const dir = androidDir(&buf, std.mem.span(files), fp.buf[0..fp.len]);
    configure(if (dir.len == 0) null else dir);
}

// ── Tests ──────────────────────────────────────────────────────────────
const testing = std.testing;

fn testDir(buf: []u8, name: []const u8) []const u8 {
    const base = std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp");
    return std.fmt.bufPrint(buf, "{s}/labelle_bgfx_shader_cache_test_{s}_{d}", .{ std.mem.trimEnd(u8, base, "/"), name, processId() }) catch unreachable;
}

fn removeEntry(id: u64) void {
    var b: [max_dir + 64:0]u8 = undefined;
    _ = std.c.unlink(entryPath(&b, id, ".bin").ptr);
}

test "off by default: every read misses and writes are dropped" {
    configure(null);
    try testing.expect(!enabled());
    try testing.expectEqual(@as(u32, 0), readSize(1));
    var out: [4]u8 = undefined;
    try testing.expect(!read(1, &out));
    write(1, "data");
}

test "a stored entry reads back whole; a missing one misses" {
    if (comptime !supported) return error.SkipZigTest;
    var dbuf: [256]u8 = undefined;
    configure(testDir(&dbuf, "roundtrip"));
    defer configure(null);
    try testing.expect(enabled());
    const id: u64 = 0x0123_4567_89ab_cdef;
    defer removeEntry(id);
    try testing.expectEqual(@as(u32, 0), readSize(id));
    write(id, "program binary bytes");
    try testing.expectEqual(@as(u32, 20), readSize(id));
    var out: [20]u8 = undefined;
    try testing.expect(read(id, &out));
    try testing.expectEqualStrings("program binary bytes", &out);
    var wrong: [19]u8 = undefined;
    try testing.expect(!read(id, &wrong));
    try testing.expectEqual(@as(u32, 1), stats.writes);
    try testing.expectEqual(@as(u32, 1), stats.hits);
    try testing.expectEqual(@as(u32, 1), stats.misses);
}

test "a truncated, corrupted or foreign entry reads as a miss, never as a size (bgfx trusts the size)" {
    if (comptime !supported) return error.SkipZigTest;
    // Its "damaged or stale" warnings are expected here.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var dbuf: [256]u8 = undefined;
    configure(testDir(&dbuf, "damaged"));
    defer configure(null);
    const id: u64 = 42;
    defer removeEntry(id);
    var pbuf: [max_dir + 64:0]u8 = undefined;
    const path = entryPath(&pbuf, id, ".bin");

    // Truncated: header promises more than the file holds.
    write(id, "0123456789");
    {
        const f = std.c.fopen(path.ptr, "wb").?;
        const h = header(10, std.hash.Crc32.hash("0123456789"));
        _ = std.c.fwrite(&h, 1, h.len, f);
        _ = std.c.fwrite("01234", 1, 5, f);
        _ = std.c.fclose(f);
    }
    try testing.expectEqual(@as(u32, 0), readSize(id));
    // Corrupted: right length, wrong bytes.
    {
        const f = std.c.fopen(path.ptr, "wb").?;
        const h = header(10, std.hash.Crc32.hash("0123456789"));
        _ = std.c.fwrite(&h, 1, h.len, f);
        _ = std.c.fwrite("0123456780", 1, 10, f);
        _ = std.c.fclose(f);
    }
    try testing.expectEqual(@as(u32, 0), readSize(id));
    // Foreign: not our header at all.
    {
        const f = std.c.fopen(path.ptr, "wb").?;
        _ = std.c.fwrite("garbage that is long enough", 1, 27, f);
        _ = std.c.fclose(f);
    }
    try testing.expectEqual(@as(u32, 0), readSize(id));
    try testing.expectEqual(@as(u32, 3), stats.rejected);
    // A rewrite heals it.
    write(id, "0123456789");
    try testing.expectEqual(@as(u32, 10), readSize(id));
}

test "configure creates missing parents" {
    if (comptime !supported) return error.SkipZigTest;
    var dbuf: [256]u8 = undefined;
    const base = testDir(&dbuf, "nested");
    var nbuf: [300]u8 = undefined;
    const nested = try std.fmt.bufPrint(&nbuf, "{s}/a/b/", .{base});
    configure(nested);
    defer configure(null);
    try testing.expect(enabled());
    try testing.expect(std.mem.endsWith(u8, directory().?, "/a/b"));
}

test "a path that is a regular file leaves the cache off" {
    if (comptime !supported) return error.SkipZigTest;
    var dbuf: [256]u8 = undefined;
    const dir = testDir(&dbuf, "notadir");
    var zbuf: [300]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&zbuf, "{s}", .{dir});
    const f = std.c.fopen(path.ptr, "wb").?;
    _ = std.c.fclose(f);
    defer _ = std.c.unlink(path.ptr);
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    configure(dir);
    try testing.expect(!enabled());
}

test "a rewrite replaces the published entry and leaves no temp file behind" {
    if (comptime !supported) return error.SkipZigTest;
    var dbuf: [256]u8 = undefined;
    configure(testDir(&dbuf, "rewrite"));
    defer configure(null);
    const id: u64 = 7;
    defer removeEntry(id);
    write(id, "first");
    write(id, "second!");
    try testing.expectEqual(@as(u32, 7), readSize(id));
    var out: [7]u8 = undefined;
    try testing.expect(read(id, &out));
    try testing.expectEqualStrings("second!", &out);
    // Only the published entry is left in the directory.
    var zbuf: [300]u8 = undefined;
    const d = std.c.opendir((try std.fmt.bufPrintZ(&zbuf, "{s}", .{directory().?})).ptr).?;
    defer _ = std.c.closedir(d);
    var names: usize = 0;
    while (std.c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        try testing.expect(std.mem.endsWith(u8, name, ".bin"));
        names += 1;
    }
    try testing.expectEqual(@as(usize, 1), names);
}

test "header round-trips and rejects other versions, empty and oversized payloads" {
    const h = header(123, 0xdead_beef);
    const meta = parseHeader(&h).?;
    try testing.expectEqual(@as(u32, 123), meta.size);
    try testing.expectEqual(@as(u32, 0xdead_beef), meta.crc);
    var other = h;
    other[4] = 2;
    try testing.expect(parseHeader(&other) == null);
    try testing.expect(parseHeader(&header(0, 0)) == null);
    try testing.expect(parseHeader(&header(max_payload + 1, 0)) == null);
}

test "the knob turns the cache off, points it at a directory, or leaves the default" {
    try testing.expect(parseKnob(null) == .default);
    try testing.expect(parseKnob("  ") == .default);
    try testing.expect(parseKnob("off") == .off);
    try testing.expect(parseKnob("FALSE") == .off);
    try testing.expect(parseKnob("0") == .off);
    try testing.expectEqualStrings("/tmp/cache", parseKnob(" /tmp/cache ").dir);
}

test "the Android directory is keyed by the build fingerprint" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const one = androidDir(&a, "/data/user/0/com.example/files/", "samsung/gta4l/12:user/release-keys");
    const two = androidDir(&b, "/data/user/0/com.example/files", "samsung/gta4l/13:user/release-keys");
    try testing.expect(std.mem.startsWith(u8, one, "/data/user/0/com.example/files/bgfx_shader_cache/"));
    try testing.expect(!std.mem.eql(u8, one, two));
    try testing.expectEqual(@as(usize, 0), androidDir(&a, "", "x").len);
    try testing.expectEqual(@as(usize, 0), androidDir(&a, "/files", "").len);
}
