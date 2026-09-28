//! The audio module's copy of `gfx/heap.zig` (read that file for why wasm
//! must use libc malloc). The audio module does not depend on gfx, and a
//! file may belong to only one module, so it cannot import that one.
const std = @import("std");
const builtin = @import("builtin");

pub const on_emscripten = builtin.os.tag == .emscripten;

pub const allocator: std.mem.Allocator = if (on_emscripten) std.heap.c_allocator else std.heap.page_allocator;
