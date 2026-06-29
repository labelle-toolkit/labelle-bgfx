// stb_image implementation TU for the bgfx backend.
//
// Unlike the sokol backend (which only needs PNG and so builds with
// STBI_ONLY_PNG), the bgfx backend's `decodeImage` previously shipped
// hand-rolled BMP + TGA decoders. We replace those with stb_image, so we
// keep PNG/JPG *and* BMP/TGA decode here to stay at parity (and beyond —
// stb also covers GIF/PSD/HDR/PIC/PNM). STBI_NO_STDIO keeps it
// memory-only: the backend always decodes from an in-memory `[]const u8`
// (the file read happens in Zig), so stb never needs <stdio.h>'s FILE API.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#include "stb_image.h"
