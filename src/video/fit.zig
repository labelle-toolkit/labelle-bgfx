//! Pure fit-rect geometry for fullscreen video (cover / contain / stretch),
//! extracted from the backend so the crop math is host-testable without bgfx
//! (#549). `fit_tag` matches core.VideoFit: 0=stretch, 1=cover, 2=contain.

const std = @import("std");

/// Plain rect (matches gfx.types.Rectangle field-for-field; kept local so this
/// module has no bgfx/gfx dependency and stays host-testable). The backend maps
/// these onto `types.Rectangle` for `drawRegion`.
pub const Rectangle = struct { x: f32, y: f32, width: f32, height: f32 };

pub const FitRects = struct { src: Rectangle, dest: Rectangle };

/// Source (texture-pixel) + destination (screen) rects for drawing a `vw`×`vh`
/// video over a `sw`×`sh` screen.
///   - stretch: full src → full screen (fills exactly, distorts a mismatch).
///   - cover:   center-crop the src to the screen aspect → full screen (fills,
///              no bars, no distortion — the overflow axis is cropped).
///   - contain: full src → centered/scaled dest (letterbox/pillarbox bars).
pub fn fitRects(fit_tag: u8, vw: f32, vh: f32, sw: f32, sh: f32) FitRects {
    const full_src = Rectangle{ .x = 0, .y = 0, .width = vw, .height = vh };
    const full_dst = Rectangle{ .x = 0, .y = 0, .width = sw, .height = sh };
    if (vw == 0 or vh == 0 or sw == 0 or sh == 0) return .{ .src = full_src, .dest = full_dst };

    const screen_ar = sw / sh;
    const video_ar = vw / vh;
    switch (fit_tag) {
        1 => { // cover
            var cw = vw;
            var ch = vh;
            if (video_ar > screen_ar) {
                cw = vh * screen_ar; // too wide: crop left/right
            } else {
                ch = vw / screen_ar; // too tall: crop top/bottom
            }
            return .{
                .src = .{ .x = (vw - cw) / 2, .y = (vh - ch) / 2, .width = cw, .height = ch },
                .dest = full_dst,
            };
        },
        2 => { // contain
            const scale = @min(sw / vw, sh / vh);
            const dw = vw * scale;
            const dh = vh * scale;
            return .{
                .src = full_src,
                .dest = .{ .x = (sw - dw) / 2, .y = (sh - dh) / 2, .width = dw, .height = dh },
            };
        },
        else => return .{ .src = full_src, .dest = full_dst }, // stretch
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────
// Setup mirrors flying-platform's intro: a 1280×720 (16:9) clip on a 1024×768
// (4:3) window.

test "cover: 16:9 video on 4:3 screen center-crops the left/right edges" {
    const r = fitRects(1, 1280, 720, 1024, 768);
    // Fills the whole screen — no letterbox.
    try std.testing.expectEqual(@as(f32, 0), r.dest.x);
    try std.testing.expectEqual(@as(f32, 0), r.dest.y);
    try std.testing.expectEqual(@as(f32, 1024), r.dest.width);
    try std.testing.expectEqual(@as(f32, 768), r.dest.height);
    // Full height kept; width cropped to the screen aspect (720 * 1024/768 = 960).
    try std.testing.expectEqual(@as(f32, 720), r.src.height);
    try std.testing.expectApproxEqAbs(@as(f32, 960), r.src.width, 0.01);
    // Centered: (1280-960)/2 = 160px cropped off EACH side — i.e. exactly the
    // LEFT-EDGE / RIGHT-EDGE markers get cut.
    try std.testing.expectApproxEqAbs(@as(f32, 160), r.src.x, 0.01);
    try std.testing.expectEqual(@as(f32, 0), r.src.y);
    // No distortion: the cropped src aspect equals the screen aspect.
    try std.testing.expectApproxEqAbs(1024.0 / 768.0, r.src.width / r.src.height, 0.0001);
}

test "cover: tall 9:16 video on 4:3 screen crops top/bottom instead" {
    const r = fitRects(1, 720, 1280, 1024, 768);
    try std.testing.expectEqual(@as(f32, 720), r.src.width); // full width kept
    // crop height = 720 / (1024/768) = 540; (1280-540)/2 = 370 off top+bottom.
    try std.testing.expectApproxEqAbs(@as(f32, 540), r.src.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 370), r.src.y, 0.01);
    try std.testing.expectEqual(@as(f32, 0), r.src.x);
    try std.testing.expectEqual(@as(f32, 1024), r.dest.width); // still fills screen
}

test "contain: 16:9 video on 4:3 screen letterboxes (bars top/bottom)" {
    const r = fitRects(2, 1280, 720, 1024, 768);
    // No crop — the whole frame is shown.
    try std.testing.expectEqual(@as(f32, 1280), r.src.width);
    try std.testing.expectEqual(@as(f32, 720), r.src.height);
    // scale = min(1024/1280, 768/720) = 0.8 → 1024×576, centered with 96px bars.
    try std.testing.expectApproxEqAbs(@as(f32, 1024), r.dest.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 576), r.dest.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.dest.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 96), r.dest.y, 0.01); // letterbox bar
}

test "stretch: fills exactly with full src + full dest (distorts a mismatch)" {
    const r = fitRects(0, 1280, 720, 1024, 768);
    try std.testing.expectEqual(@as(f32, 1280), r.src.width);
    try std.testing.expectEqual(@as(f32, 720), r.src.height);
    try std.testing.expectEqual(@as(f32, 1024), r.dest.width);
    try std.testing.expectEqual(@as(f32, 768), r.dest.height);
}

test "matched aspect: cover/contain/stretch all agree (no crop, no bars)" {
    // 1280×720 on a 1280×720 screen — every fit is a 1:1 full draw.
    for ([_]u8{ 0, 1, 2 }) |tag| {
        const r = fitRects(tag, 1280, 720, 1280, 720);
        try std.testing.expectEqual(@as(f32, 1280), r.src.width);
        try std.testing.expectEqual(@as(f32, 720), r.src.height);
        try std.testing.expectEqual(@as(f32, 1280), r.dest.width);
        try std.testing.expectEqual(@as(f32, 720), r.dest.height);
        try std.testing.expectEqual(@as(f32, 0), r.dest.x);
    }
}
