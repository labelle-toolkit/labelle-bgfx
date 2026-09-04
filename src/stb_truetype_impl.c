// stb_truetype implementation TU for the bgfx backend.
//
// Sibling of `stb_image_impl.c`: a single translation unit that defines
// the implementation macro and includes the vendored single-header
// library, so the header can also be `@cInclude`d (declarations only)
// from `gfx/texture.zig`'s `@cImport` without emitting the bodies twice.
//
// This is what gives the bgfx backend TTF/OTF baking (`gfx/font.zig`'s
// `decodeFont`) at parity with the sokol backend. STBTT_STATIC is NOT
// set: `gfx/font.zig` calls these symbols from Zig, so they have to
// keep external linkage.
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
