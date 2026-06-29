/// Pure-data types and color constants for the bgfx backend.
/// State-free, side-effect-free; safe for every other gfx submodule
/// to import without creating cycles.

pub const Texture = struct { id: u32, width: i32, height: i32 };

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn toAbgr(c: Color) u32 {
        return @as(u32, c.a) << 24 | @as(u32, c.b) << 16 | @as(u32, c.g) << 8 | @as(u32, c.r);
    }
};

pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Vector2 = struct {
    x: f32,
    y: f32,
};

pub const Camera2D = struct {
    offset: Vector2 = .{ .x = 0, .y = 0 },
    target: Vector2 = .{ .x = 0, .y = 0 },
    rotation: f32 = 0,
    zoom: f32 = 1,
};

// ── Color constants ────────────────────────────────────────────────────

pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
pub const red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
pub const green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
pub const blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
