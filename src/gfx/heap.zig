//! The allocator the backend uses for its own retained and scratch memory.
//!
//! On wasm it MUST be libc `malloc` (`std.heap.c_allocator`), never
//! `std.heap.page_allocator`. Under emscripten, page_allocator grows linear
//! memory with `memory.grow` directly, behind emscripten's `sbrk`. The malloc
//! heap does not know those pages are taken: its next growth hands them out
//! again, and two owners write the same bytes. On Flying Platform's web build
//! that showed up as string literals zeroed out ("#canvas" read back as an
//! empty selector), empty log lines, and finally `Aborted(Assertion failed)`
//! from emscripten's stack-cookie check, the moment the first shader
//! material was created (the material registry allocated here). A bigger
//! `STACK_SIZE` does not help: it is heap corruption, not a stack overflow.
//!
//! Native targets keep page_allocator, which is what they always used.
//! `heap_guard_test.zig` fails the build if a production file goes back to
//! naming page_allocator directly. Re-exported as `gfx.heap` for the window
//! module; the audio module (no gfx dependency) mirrors it in
//! `src/audio_heap.zig`. A file may belong to only one module, so the two
//! cannot share one file.
const std = @import("std");
const builtin = @import("builtin");

pub const on_emscripten = builtin.os.tag == .emscripten;

pub const allocator: std.mem.Allocator = if (on_emscripten) std.heap.c_allocator else std.heap.page_allocator;
