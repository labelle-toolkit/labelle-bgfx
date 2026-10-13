//! Shared desktop/web software cursor. Call last, outside any camera.
const window = @import("window");
const gfx = @import("backend_gfx");
const input = @import("backend_input");
var enabled = true;

pub fn draw() void {
    // GLFW-compatible key C, also mapped by the browser input backend.
    if (input.isKeyPressed(67)) enabled = !enabled;
    const show = enabled and window.isCursorOverWindow();
    if (!window.setCursorVisible(!show) or !show) return;
    // Input is in framebuffer pixels: use a 1:1 screen-space canvas so DPI,
    // letterboxing and scene cameras cannot move the hotspot off the click.
    gfx.setDesignSize(window.width(), window.height());
    const x = input.getMouseX();
    const y = input.getMouseY();
    const size = 20 * window.displayScale();
    const tint = if (input.isMouseButtonDown(0)) gfx.color(255, 100, 100, 255) else gfx.color(255, 230, 100, 255);
    // Tip = click hotspot. A textured quad can replace this triangle; subtract
    // the artwork's scaled hotspot from x/y when positioning the quad.
    gfx.drawTriangle(.{ .x = x, .y = y }, .{ .x = x + size, .y = y + size }, .{ .x = x, .y = y + size }, tint);
}
