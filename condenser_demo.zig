//! Run with `zig build condenser-demo`; deterministic GPU capture with
//! `zig build condenser-capture -Dcondenser-time=1.4`.
const std = @import("std");
const window = @import("window");
const gfx = @import("gfx");
const bgfx = @import("zbgfx").bgfx;
const options = @import("condenser_options");
const condenser = @import("src/condenser_scene.zig");
pub const std_options: std.Options = .{ .log_level = .debug };

pub fn main(init: std.process.Init) !void {
    const w = condenser.sim.width * options.scale;
    const h = condenser.sim.height * options.scale;
    if (options.capture) {
        if (!window.initHeadless(w, h)) return error.HeadlessInitFailed;
    } else window.initWindow(w, h, "COND-07 — reservoir and rain");
    defer window.closeWindow();
    const scene = try condenser.Scene.init();
    defer scene.deinit();
    gfx.setTextureFilter(.point);
    var time: f32 = 0;
    if (options.capture) {
        try std.Io.Dir.cwd().createDirPath(init.io, "zig-out/condenser-frames");
        for (0..options.frames) |i| {
            time = options.time + @as(f32, @floatFromInt(i)) / 30;
            for (0..3) |_| draw(scene, time);
            if (!options.fallback and !gfx.materialSupported(.pixel_water)) return error.PixelWaterUnsupported;
            var path_buf: [128]u8 = undefined;
            const path: [:0]const u8 = if (options.frames == 1) "zig-out/condenser" else try std.fmt.bufPrintZ(&path_buf, "zig-out/condenser-frames/{d:0>3}", .{i});
            if (!window.captureHeadless(path)) return error.CaptureFailed;
        }
        std.debug.print("CONDENSER_CAPTURE: renderer={s}, time={d}, level={d}, fallback={}, frames={d}\n", .{ @tagName(bgfx.getRendererType()), options.time, options.level, options.fallback, options.frames });
    } else while (!window.shouldQuit()) {
        time += @min(@as(f32, @floatCast(window.frameDuration())), 0.05);
        draw(scene, time);
    }
}

fn draw(scene: condenser.Scene, time: f32) void {
    gfx.setScreenSize(window.width(), window.height());
    gfx.setDesignSize(condenser.sim.width, condenser.sim.height);
    window.beginFrame();
    window.clearBackground(15, 21, 22, 255);
    // Submission order must survive differing sprite/water programs.
    bgfx.setViewMode(0, .Sequential);
    scene.draw(time, options.level, options.fallback);
    window.endFrame();
}
