//! Hot-path video CPU code, isolated into its own module so build.zig can pin
//! it to ReleaseSafe EVEN IN A DEBUG GAME BUILD.
//!
//! Why: the per-frame plane work — `planes.tightenPlane`'s NV12 chroma
//! de-interleave (a scalar gather over ~½ MB/plane at video fps) and `yuv`'s
//! CPU YUV→RGBA convert — is the one genuinely CPU-bound thing in the video
//! path (decode is hardware AMediaCodec; YUV→RGBA is the GPU `fs_yuv` shader on
//! the plane path). Under an unoptimized Debug build that scalar loop floors a
//! mobile GPU's companion CPU and the intro video stutters, while the rest of
//! the game (light per-frame work) still feels fine. An optimized build
//! vectorizes the gather, so the video is smooth — but Debug doesn't optimize.
//!
//! Pinning just this leaf module to ReleaseSafe makes the video smooth
//! regardless of the game's own optimize mode, with no effect on the rest of the
//! build. ReleaseSafe rather than ReleaseFast on purpose: planes/yuv index off
//! decoder-provided dimensions + strides, so the bounds checks and the functions'
//! `std.debug.assert` input guards must stay LIVE (ReleaseFast makes assert a
//! UB-hint and drops bounds checks). The optimizer still vectorizes under
//! ReleaseSafe, which is plenty fast for video.
pub const planes = @import("planes.zig");
pub const yuv = @import("yuv.zig");
