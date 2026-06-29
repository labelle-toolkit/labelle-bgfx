// Shim for @cImport of the NDK app/asset/log headers from Zig.
// Macro-strips clang nullability qualifiers that Zig 0.16 translate-c rejects
// on some Bionic array-parameter declarations (same trick as the bgfx
// stb_shim.h, see flying-platform-labelle#450).
#define _Nonnull
#define _Nullable

#include <android/native_activity.h>
#include <android/asset_manager.h>
#include <android/log.h>
