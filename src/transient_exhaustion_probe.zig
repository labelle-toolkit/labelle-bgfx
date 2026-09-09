//! Transient-buffer EXHAUSTION probe (labelle-assembler#648).
//!
//! The unit tests in `gfx/transient_budget.zig` prove the arithmetic. They
//! cannot prove the thing the ticket is actually about, because the defect only
//! exists where the numbers meet bgfx: `allocTransientVertexBuffer` asserting
//! (Debug) or truncating (release) when the per-frame arena is short. A test
//! that models `getAvailTransientVertexBuffer` cannot tell you that the real one
//! agrees.
//!
//! So this probe deliberately over-subscribes a real bgfx device and asserts on
//! the outcome:
//!
//!   1. **A short allocation really happens.** It asks bgfx how much transient
//!      vertex space exists, then submits meaningfully MORE than that through
//!      the production `submitFlatTriangles` path. If bgfx reports capacity we
//!      cannot exceed, the probe says so and fails rather than passing vacuously
//!      — a green run that never exhausted anything would be worthless.
//!   2. **The process survives.** Pre-fix, this is where a Debug build trapped.
//!   3. **The drop is recorded, exactly once.** `drop_events` counts every
//!      dropped batch while `warned` latches after the first, which is the
//!      warn-once contract the fix promises. Both halves are checked, because
//!      "logged once" and "counted every time" are different claims and a
//!      regression could break either.
//!   4. **The submitted prefix is bounded by real capacity** — we never claim to
//!      have drawn more than the arena could hold.
//!
//! Run with:  zig build transient-exhaustion-probe
//!
//! Prints a `PROBE_RESULT:` line and sets the exit code:
//!   0 = TRANSIENT_EXHAUSTION_OK
//!   2 = HEADLESS_INIT_FAILED      (no Vulkan/Metal device)
//!   3 = NO_EXHAUSTION             (could not out-run the arena — probe is vacuous)
//!   4 = DROP_NOT_RECORDED         (geometry vanished without being counted)
//!   5 = WARN_NOT_ONCE_ONLY        (warn-once contract broken)

const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const gfx = @import("gfx");
const Material = @import("labelle-core").backend_contract.Material;

const W: u16 = 64;
const H: u16 = 64;

/// How far past the reported capacity to over-subscribe. Enough that the
/// shortfall is unambiguous rather than a rounding difference.
const OVERSHOOT_FACTOR: usize = 2;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var init: bgfx.Init = undefined;
    bgfx.initCtor(&init);
    init.type = if (@import("builtin").os.tag == .macos) .Metal else .Vulkan; // Vulkan/Metal support headless; OpenGL does not
    init.resolution.width = 0;
    init.resolution.height = 0;
    init.resolution.reset = bgfx.ResetFlags_None;
    init.platformData.ndt = null;
    init.platformData.nwh = null;
    init.platformData.context = null;
    init.platformData.backBuffer = null;
    init.platformData.backBufferDS = null;

    if (!bgfx.init(&init)) {
        std.debug.print("PROBE_RESULT: HEADLESS_INIT_FAILED\n", .{});
        std.process.exit(2);
    }
    std.debug.print("PROBE: headless init OK — renderer={s}\n", .{@tagName(bgfx.getRendererType())});

    const rt = bgfx.createTexture2D(W, H, false, 1, .RGBA8, bgfx.TextureFlags_Rt, null, 0);
    var handles = [_]bgfx.TextureHandle{rt};
    const fb = bgfx.createFrameBufferFromHandles(1, &handles, false);
    bgfx.setViewFrameBuffer(0, fb);
    bgfx.setViewRect(0, 0, 0, W, H);
    bgfx.setViewClear(0, bgfx.ClearFlags_Color | bgfx.ClearFlags_Depth, 0x000000ff, 1.0, 0);
    bgfx.touch(0);
    _ = bgfx.frame(0);

    // Warm the shader/layout state up on a trivial batch so the exhaustion
    // frame measures the arena and not first-use initialization.
    gfx.submitFlatTriangles(&triangle(0.0));
    _ = bgfx.frame(0);

    // Ask the device what the transient vertex arena actually holds. Requesting
    // an absurd count returns the true remaining capacity rather than that count.
    const probe_request: u32 = std.math.maxInt(u32) / 64;
    const capacity = gfx.availTransientVertices(probe_request);
    std.debug.print("PROBE: transient vertex capacity this frame = {d}\n", .{capacity});

    if (capacity == 0 or capacity >= probe_request) {
        std.debug.print(
            "PROBE_RESULT: NO_EXHAUSTION (capacity {d} is unusable as a bound — cannot over-subscribe)\n",
            .{capacity},
        );
        std.process.exit(3);
    }

    // Build a batch comfortably larger than the arena, rounded to whole triangles.
    const want_raw = @as(usize, capacity) * OVERSHOOT_FACTOR;
    const want = want_raw - (want_raw % 3);
    const verts = try allocator.alloc(@TypeOf(triangle(0.0)[0]), want);
    defer allocator.free(verts);
    for (0..want / 3) |t| {
        const tri = triangle(@as(f32, @floatFromInt(t % 32)) * 0.01);
        verts[t * 3 + 0] = tri[0];
        verts[t * 3 + 1] = tri[1];
        verts[t * 3 + 2] = tri[2];
    }
    std.debug.print("PROBE: submitting {d} vertices into a {d}-vertex arena\n", .{ want, capacity });

    // THE MOMENT UNDER TEST. Pre-fix this called allocTransientVertexBuffer with
    // `want` and bgfx asserted here in Debug.
    gfx.submitFlatTriangles(verts);
    _ = bgfx.frame(0);
    std.debug.print("PROBE: survived the over-subscribed submit (no assert)\n", .{});

    const stats = gfx.transientDropStats();
    std.debug.print(
        "PROBE: drop_events={d} dropped_vertices={d} warned={}\n",
        .{ stats.drop_events, stats.dropped_vertices, stats.warned },
    );

    const expected_drop = want - (capacity - capacity % 3);
    // Exact prefix accounting catches both skipped rendering and over-allocation.
    if (stats.drop_events != 1 or stats.dropped_vertices != expected_drop) {
        std.debug.print("PROBE_RESULT: DROP_NOT_RECORDED (geometry went missing uncounted)\n", .{});
        std.process.exit(4);
    }
    // Never report dropping more than we submitted.
    if (stats.dropped_vertices > want) {
        std.debug.print(
            "PROBE_RESULT: DROP_NOT_RECORDED (dropped {d} > submitted {d})\n",
            .{ stats.dropped_vertices, want },
        );
        std.process.exit(4);
    }

    // Warn-once: a second starved submit must add an event without re-warning.
    const events_before = stats.drop_events;
    const white = [4]u8{ 255, 255, 255, 255 };
    const texture = bgfx.createTexture2D(1, 1, false, 1, .RGBA8, 0, bgfx.copy(&white, 4), 0);
    // Exercise the textured production path against the same full-frame limit.
    gfx.submitTexturedTriangles(verts, texture);
    _ = bgfx.frame(0);
    const after = gfx.transientDropStats();
    if (!after.warned or after.drop_events != events_before + 1 or after.dropped_vertices != 2 * expected_drop) {
        std.debug.print(
            "PROBE_RESULT: WARN_NOT_ONCE_ONLY (warned={} events {d} -> {d})\n",
            .{ after.warned, events_before, after.drop_events },
        );
        std.process.exit(5);
    }

    // Exercise the public material dispatch, including a valid LUT so
    // palette_swap cannot silently fall back to the textured path.
    const pixels = try allocator.dupe(u8, &white);
    defer allocator.free(pixels);
    const sprite = try gfx.uploadTexture(.{ .pixels = pixels, .width = 1, .height = 1 });

    inline for (.{ .flash, .palette_swap, .dissolve, .outline }) |effect| {
        const material: Material = .{ .effect = effect, .uniforms = .{
            .aux_texture = sprite.id.toInt(),
            .aux_count = 1,
        } };
        const rect = gfx.Rectangle{ .x = 0, .y = 0, .width = 1, .height = 1 };
        const origin = gfx.Vector2{ .x = 0, .y = 0 };
        const room = gfx.availTransientVertices(probe_request);
        const before_material = gfx.transientDropStats();
        gfx.drawTextureProMaterial(sprite, rect, rect, origin, 0, gfx.white, material);
        if (gfx.availTransientVertices(probe_request) != room - 6 or
            gfx.transientDropStats().drop_events != before_material.drop_events)
            return error.MaterialDidNotRender;
        // Fill the remainder, leaving fewer than one triangle. A fixed
        // material quad must be rejected and account for all six vertices.
        const remaining_room = gfx.availTransientVertices(probe_request);
        gfx.submitFlatTriangles(verts[0 .. remaining_room - remaining_room % 3]);
        const before_drop = gfx.transientDropStats();
        gfx.drawTextureProMaterial(sprite, rect, rect, origin, 0, gfx.white, material);
        const dropped = gfx.transientDropStats();
        if (dropped.drop_events != before_drop.drop_events + 1 or
            dropped.dropped_vertices != before_drop.dropped_vertices + 6)
            return error.MaterialDropNotRecorded;
        _ = bgfx.frame(0);
        // The next frame must recover: the guard cannot latch rendering off.
        const recovered_room = gfx.availTransientVertices(probe_request);
        gfx.drawTextureProMaterial(sprite, rect, rect, origin, 0, gfx.white, material);
        if (gfx.availTransientVertices(probe_request) != recovered_room - 6 or
            gfx.transientDropStats().drop_events != dropped.drop_events)
            return error.MaterialDidNotRecover;
        _ = bgfx.frame(0);
        std.debug.print("PROBE: {s} rendered, dropped exactly 6, recovered next frame\n", .{@tagName(effect)});
    }

    std.debug.print("PROBE_RESULT: TRANSIENT_EXHAUSTION_OK\n", .{});
    bgfx.destroyTexture(texture);
    gfx.unloadTexture(sprite);
    gfx.shutdownPrograms();
    bgfx.destroyFrameBuffer(fb);
    bgfx.destroyTexture(rt);
    _ = bgfx.frame(0);
    bgfx.shutdown();
}

/// One screen-space triangle in NDC, nudged by `off` so successive triangles
/// are not bit-identical (nothing here depends on where they land).
fn triangle(off: f32) [3]gfx.PosTexColorVertex {
    return .{
        .{ .x = -0.5 + off, .y = -0.5, .u = 0, .v = 0, .abgr = 0xff0000ff },
        .{ .x = 0.5 + off, .y = -0.5, .u = 1, .v = 0, .abgr = 0xff00ff00 },
        .{ .x = 0.0 + off, .y = 0.5, .u = 0.5, .v = 1, .abgr = 0xffff0000 },
    };
}
