/// Pure-data types and color constants for the bgfx backend.
/// State-free, side-effect-free; safe for every other gfx submodule
/// to import without creating cycles.

const core = @import("labelle-core");

/// A texture this backend owns. `id` is THIS BACKEND's identifier — an index
/// into `texture.texture_handles` — and is deliberately NOT the engine-facing
/// `TextureId` that labelle-gfx's registry hands out. Those two numbering
/// spaces are independent, and conflating them (both were `u32`) is how
/// gfx v1.29.0 silently blanked a downstream menu: a game passed an engine
/// handle to `nativeTextureHandle`, which indexes the table below
/// (labelle-gfx#326 / RFC-TEXTURE-ID-TYPING, labelle-gfx#328).
///
/// Resolve an engine handle with `RetainedEngine.nativeTextureId` before
/// calling anything here.
pub const Texture = struct { id: core.BackendTextureId, width: i32, height: i32 };

/// How the GPU samples a game texture between texels (labelle-bgfx#77).
///
/// `.linear` is bgfx's own default (bilinear) and is what every game texture
/// got before this enum existed — it stays the default here so no existing
/// game changes appearance. `.point` (nearest) is what pixel art wants: at
/// 2x zoom a bilinear filter blends in the atlas neighbours of a tightly
/// packed 16px tile, drawing a seam grid across the whole map.
///
/// The font atlas has always been point-sampled (`gfx/font.zig`); this makes
/// the same choice reachable for game textures.
pub const TextureFilter = enum {
    /// bgfx default sampling (bilinear). Emits no filter bits.
    linear,
    /// Nearest-neighbour min+mag sampling — crisp pixel art, no atlas bleed.
    point,
};

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
