//! zig build cursor-example. C toggles the custom pointer; click turns it red.
const window = @import("window");
const gfx = @import("backend_gfx");
const cursor = @import("cursor_overlay.zig");

pub fn main() void {
    window.initWindow(800, 600, "Custom cursor: C restores default, click changes color");
    defer window.closeWindow();
    window.setTargetFPS(60);
    while (!window.shouldQuit()) {
        window.beginFrame();
        gfx.setScreenSize(window.width(), window.height());
        gfx.setDesignSize(window.width(), window.height());
        window.clearBackground(30, 30, 46, 255);
        gfx.drawRectangleRec(.{ .x = 100, .y = 100, .width = 200, .height = 100 }, gfx.color(80, 120, 180, 255));
        cursor.draw();
        window.endFrame();
    }
}
