//! Hot-path video CPU code, isolated into its own module so build.zig can pin
//! it to ReleaseFast EVEN IN A DEBUG GAME BUILD.
//!
//! Why: the per-frame plane work — `planes.tightenPlane`'s NV12 chroma
//! de-interleave (a scalar gather over ~½ MB/plane at video fps) and `yuv`'s
//! CPU YUV→RGBA convert — is the one genuinely CPU-bound thing in the video
//! path (decode is hardware AMediaCodec; YUV→RGBA is the GPU `fs_yuv` shader on
//! the plane path). Under an unoptimized Debug build that scalar loop floors a
//! mobile GPU's companion CPU and the intro video stutters, while the rest of
//! the game (light per-frame work) still feels fine. ReleaseFast vectorizes the
//! gather, so the video is smooth — but only on `--release`.
//!
//! Pinning just this leaf module to ReleaseFast (it's pure Zig, std-only, with
//! host-tested correctness + input asserts) makes the video smooth regardless of
//! the game's own optimize mode, with no effect on the rest of the build.
pub const planes = @import("planes.zig");
pub const yuv = @import("yuv.zig");
