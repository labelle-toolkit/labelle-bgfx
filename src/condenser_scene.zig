//! Actual COND-07 layered art, separate mist, falling drops and reactive water.
const std = @import("std");
const gfx = @import("gfx");
pub const sim = @import("condenser_sim.zig");
const allocator = std.heap.page_allocator;
const origin: gfx.Vector2 = .{ .x = 0, .y = 0 };

fn load(comptime name: []const u8, crop: bool) !gfx.Texture {
    const image = try gfx.decodeImage("", @embedFile("../docs/issue-references/condenser-100/layers/" ++ name ++ ".png"), allocator);
    defer allocator.free(image.pixels);
    if (!crop) return gfx.uploadTextureFiltered(image, .point);
    if (image.width != sim.width or image.height != sim.height) return error.InvalidLayerDimensions;
    const pixels = try allocator.alloc(u8, sim.basin_width * sim.basin_height * 4);
    defer allocator.free(pixels);
    for (0..sim.basin_height) |y| {
        const src = ((48 + y) * image.width + 4) * 4;
        const dst = y * sim.basin_width * 4;
        @memcpy(pixels[dst..][0 .. sim.basin_width * 4], image.pixels[src..][0 .. sim.basin_width * 4]);
    }
    return gfx.uploadTextureFiltered(.{ .pixels = pixels, .width = sim.basin_width, .height = sim.basin_height }, .point);
}

pub const Scene = struct {
    interior: gfx.Texture,
    water_art: gfx.Texture,
    mask: gfx.Texture,
    reflection: gfx.Texture,
    mist: gfx.Texture,
    drop: gfx.Texture,
    cooler: gfx.Texture,
    frame: gfx.Texture,

    pub fn init() !Scene {
        const interior = try load("machine_interior", false);
        errdefer gfx.unloadTexture(interior);
        const water_art = try load("reservoir_static", true);
        errdefer gfx.unloadTexture(water_art);
        const mask = try load("reservoir_mask", true);
        errdefer gfx.unloadTexture(mask);
        const reflection = try load("reflection", false);
        errdefer gfx.unloadTexture(reflection);
        const mist = try load("mist", false);
        errdefer gfx.unloadTexture(mist);
        const drop = try load("drop", false);
        errdefer gfx.unloadTexture(drop);
        const cooler = try load("cooler_foreground", false);
        errdefer gfx.unloadTexture(cooler);
        return .{ .interior = interior, .water_art = water_art, .mask = mask, .reflection = reflection, .mist = mist, .drop = drop, .cooler = cooler, .frame = try load("frame_foreground", false) };
    }

    pub fn deinit(self: Scene) void {
        inline for (std.meta.fields(Scene)) |field| gfx.unloadTexture(@field(self, field.name));
    }

    pub fn draw(self: Scene, time: f32, level: f32, fallback: bool) void {
        const frame = sim.sample(time, level);
        drawLayer(self.interior, 0, 0, 255);
        const source: gfx.Rectangle = .{ .x = 0, .y = 0, .width = sim.basin_width, .height = sim.basin_height };
        const dest: gfx.Rectangle = .{ .x = sim.basin_x, .y = sim.basin_y, .width = sim.basin_width, .height = sim.basin_height };
        var water: gfx.PixelWaterDraw = .{
            .mask_texture = self.mask.id.toInt(),
            .reflection_texture = self.reflection.id.toInt(),
            .logical_width = sim.basin_width,
            .logical_height = sim.basin_height,
            .grid_pixels = 1,
            .flags = gfx.PIXEL_WATER_FLAG_WAVES,
            .deep = rgba(0x0F1719, 0.72),
            .surface = rgba(0x7AA5BB, 0.55),
            .highlight = rgba(0xADCAC6, 0.45),
            .level = level,
            .time = time,
            .wave_amplitude_pixels = sim.wave_amplitude,
            .wave_period_seconds = sim.wave_period,
            .distortion_pixels = 0.6,
            .reflection_opacity = 0.14,
            .ripple_duration_seconds = sim.ripple_seconds,
            .ripple_radius_pixels = sim.ripple_radius,
            .ripple_strength_pixels = sim.ripple_strength,
            .ripple_count = @intCast(frame.impact_count),
        };
        for (frame.impacts[0..frame.impact_count], 0..) |impact, i| {
            water.ripples[i] = .{ .x = impact.x, .start_time = impact.start_time, .strength = 1 };
        }
        if (fallback) gfx.drawTexturePro(self.water_art, source, dest, origin, 0, gfx.white) else gfx.drawTextureProPixelWater(self.water_art, source, dest, origin, 0, gfx.white, water);

        // Mist is never sampled by the water material. Its one-cell drift and
        // opacity pulse have a separate period from the surface and drops.
        const drift = @round(@sin(time * 0.7));
        const alpha: u8 = @intFromFloat(225 + 25 * @sin(time * 0.9));
        drawLayer(self.mist, drift, 0, alpha);
        for (frame.drops[0..frame.drop_count]) |drop| {
            gfx.drawTexturePro(self.drop, .{ .x = 0, .y = 0, .width = 1, .height = 5 }, .{ .x = drop.x, .y = @floor(drop.head_y) - 5, .width = 1, .height = 5 }, origin, 0, gfx.white);
        }
        // Small authored impact glints complement the shader's fading ripples.
        // Draw before occluders: emitter A's water contact stays behind cooler.
        if (!fallback) for (frame.impacts[0..frame.impact_count]) |impact| {
            const age = time - impact.start_time;
            if (age < 0.18) {
                const spread = @floor(age * 14) + 1;
                const y = sim.surfaceAt(time, impact.x, level, frame.impacts[0..frame.impact_count]) - 1;
                const color = gfx.color(173, 202, 198, @intFromFloat(180 * (1 - age / 0.18)));
                gfx.drawRectangleRec(.{ .x = sim.basin_x + impact.x - spread, .y = y, .width = 1, .height = 1 }, color);
                gfx.drawRectangleRec(.{ .x = sim.basin_x + impact.x + spread, .y = y, .width = 1, .height = 1 }, color);
            }
        };
        drawLayer(self.cooler, 0, 0, 255);
        drawLayer(self.frame, 0, 0, 255);
    }
};

fn drawLayer(texture: gfx.Texture, x: f32, y: f32, alpha: u8) void {
    gfx.drawTexturePro(texture, .{ .x = 0, .y = 0, .width = sim.width, .height = sim.height }, .{ .x = x, .y = y, .width = sim.width, .height = sim.height }, origin, 0, gfx.color(255, 255, 255, alpha));
}

fn rgba(comptime hex: u24, alpha: f32) gfx.PixelWaterRgba {
    return .{ .r = linear(@intCast(hex >> 16)), .g = linear(@intCast((hex >> 8) & 255)), .b = linear(@intCast(hex & 255)), .a = alpha };
}
fn linear(channel: u8) f32 {
    const c = @as(f32, @floatFromInt(channel)) / 255;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}
