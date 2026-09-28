//! GPU-YUV colour matrix selection (labelle-bgfx#155).
//!
//! `fs_yuv` used to hard-code the BT.601 limited-range matrix. The Android
//! decoder now reports each stream's colour metadata
//! (`labelle_android.video.ColorSpace`: standard bt709 / bt601, range limited /
//! full), and its CPU path already converts with the matching `yuv.Matrix`. This
//! module turns that same matrix into the two `vec4` uniforms `fs_yuv` reads, so
//! the GPU path agrees with the CPU path for every stream:
//!
//!   u_yuvOffsetGain = (Y offset, Y gain, chroma offset, 0)
//!   u_yuvCoeffs     = (V→R, U→G, V→G, U→B)
//!
//! and in the shader, with y/u/v the sampled [0,1] plane values:
//!
//!   Y = (y − off.x)·off.y;  U = u − off.z;  V = v − off.z
//!   R = Y + c.x·V;  G = Y − c.y·U − c.z·V;  B = Y + c.w·U
//!
//! The gains are the matrix's 8.8 fixed-point values / 256 (so GPU == CPU
//! bit-for-bit in the coefficients), offsets are /255 (plane samples are unorm).
//! Decoders WITHOUT colour metadata (desktop ffmpeg, web) keep BT.601 limited —
//! exactly the constants the shader used before.
//!
//! Pure Zig (only `labelle_android.video`'s host-safe decls): host-tested.

const std = @import("std");
const android_video = @import("labelle_android").video;

pub const Matrix = android_video.yuv.Matrix;
pub const ColorSpace = android_video.ColorSpace;

/// The two `fs_yuv` uniform vec4s: `[0]` = `u_yuvOffsetGain`, `[1]` =
/// `u_yuvCoeffs` (see the module doc for the layout).
pub const Params = [2][4]f32;

/// What `fs_yuv` used before #155 and what every decoder without colour
/// metadata still gets.
pub const default_matrix: Matrix = Matrix.bt601_limited;
pub const default_params: Params = fromMatrix(default_matrix);

/// A `yuv.Matrix` (8.8 fixed point, 8-bit offsets) → the shader uniforms.
pub fn fromMatrix(m: Matrix) Params {
    const g = struct {
        fn gain(v: i32) f32 {
            return @as(f32, @floatFromInt(v)) / 256.0;
        }
    }.gain;
    return .{
        .{ @as(f32, @floatFromInt(m.y_off)) / 255.0, g(m.y_gain), 128.0 / 255.0, 0.0 },
        .{ g(m.rv), g(m.gu), g(m.gv), g(m.bu) },
    };
}

/// A stream's colour metadata → the shader uniforms, resolving unspecified
/// fields exactly like the decoder's CPU path (`ColorSpace.matrix`: unspecified
/// standard is BT.709 at ≥ 720 rows, else BT.601; unspecified range is limited).
pub fn fromColorSpace(cs: ColorSpace, height: u32) Params {
    return fromMatrix(cs.matrix(height));
}

/// The matrix for the frame `decoder` most recently returned: its reported
/// colour space when the decoder exposes `colorSpace()` (Android MediaCodec),
/// else the BT.601-limited default (desktop ffmpeg, web).
pub fn matrixFor(comptime Decoder: type, decoder: *const Decoder, height: u32) Matrix {
    if (comptime @hasDecl(Decoder, "colorSpace")) {
        return decoder.colorSpace().matrix(height);
    }
    return default_matrix;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Reference YCbCr→RGB gains from the standard's Kr/Kb (ITU-R BT.601 /
/// BT.709), computed independently of `yuv.Matrix`'s rounded integers.
fn reference(kr: f64, kb: f64, full: bool) [6]f64 {
    const kg = 1.0 - kr - kb;
    const y_gain: f64 = if (full) 1.0 else 255.0 / 219.0;
    const c_scale: f64 = if (full) 1.0 else 255.0 / 224.0;
    const y_off: f64 = if (full) 0.0 else 16.0 / 255.0;
    return .{
        y_off,
        y_gain,
        2.0 * (1.0 - kr) * c_scale, // V→R
        2.0 * (1.0 - kb) * kb / kg * c_scale, // U→G
        2.0 * (1.0 - kr) * kr / kg * c_scale, // V→G
        2.0 * (1.0 - kb) * c_scale, // U→B
    };
}

fn expectMatches(p: Params, ref: [6]f64) !void {
    // 8.8 fixed point rounds each gain to the nearest 1/256.
    const tol: f32 = 0.5 / 256.0 + 1e-6;
    try testing.expectApproxEqAbs(@as(f32, @floatCast(ref[0])), p[0][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(ref[1])), p[0][1], tol);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), p[0][2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(ref[2])), p[1][0], tol);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(ref[3])), p[1][1], tol);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(ref[4])), p[1][2], tol);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(ref[5])), p[1][3], tol);
}

test "BT.709 limited (the FP intro) selects the HD coefficients" {
    const p = fromColorSpace(.{ .standard = .bt709, .range = .limited }, 1080);
    // Published BT.709 limited-range values: 1.164·(Y−16), 1.793·V,
    // 0.213·U, 0.533·V, 2.112·U.
    try testing.expectApproxEqAbs(@as(f32, 0.0627451), p[0][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.1644), p[0][1], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.7927), p[1][0], 2e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.2132), p[1][1], 2e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.5329), p[1][2], 2e-3);
    try testing.expectApproxEqAbs(@as(f32, 2.1124), p[1][3], 2e-3);
    try expectMatches(p, reference(0.2126, 0.0722, false));
}

test "BT.709 full, BT.601 limited and BT.601 full match their references" {
    try expectMatches(fromColorSpace(.{ .standard = .bt709, .range = .full }, 1080), reference(0.2126, 0.0722, true));
    try expectMatches(fromColorSpace(.{ .standard = .bt601_ntsc, .range = .limited }, 1080), reference(0.299, 0.114, false));
    try expectMatches(fromColorSpace(.{ .standard = .bt601_pal, .range = .full }, 480), reference(0.299, 0.114, true));
}

test "default params are the pre-#155 fs_yuv constants (BT.601 limited)" {
    // The literals fs_yuv hard-coded before the uniform existed.
    const old = Params{
        .{ 0.0627451, 1.1640625, 0.5019608, 0.0 },
        .{ 1.5976562, 0.390625, 0.8125, 2.015625 },
    };
    for (old, default_params) |row_old, row_new| {
        for (row_old, row_new) |a, b| try testing.expectApproxEqAbs(a, b, 1e-6);
    }
}

test "unspecified metadata resolves like the CPU path (height rule, limited range)" {
    const unspecified: ColorSpace = .{};
    try testing.expectEqual(fromMatrix(Matrix.bt709_limited), fromColorSpace(unspecified, 720));
    try testing.expectEqual(fromMatrix(Matrix.bt601_limited), fromColorSpace(unspecified, 480));
    // BT.2020 rides the 709 matrix (as the CPU path does).
    try testing.expectEqual(fromMatrix(Matrix.bt709_full), fromColorSpace(.{ .standard = .bt2020, .range = .full }, 2160));
}

test "matrixFor: decoders without colorSpace() keep BT.601 limited; with it, follow the stream" {
    const Plain = struct {};
    const plain: Plain = .{};
    try testing.expectEqual(Matrix.bt601_limited, matrixFor(Plain, &plain, 1080));

    const Tagged = struct {
        cs: ColorSpace,
        pub fn colorSpace(self: *const @This()) ColorSpace {
            return self.cs;
        }
    };
    const hd: Tagged = .{ .cs = .{ .standard = .bt709, .range = .limited } };
    try testing.expectEqual(Matrix.bt709_limited, matrixFor(Tagged, &hd, 1080));
    const sd_full: Tagged = .{ .cs = .{ .standard = .bt601_ntsc, .range = .full } };
    try testing.expectEqual(Matrix.bt601_full, matrixFor(Tagged, &sd_full, 1080));
}
