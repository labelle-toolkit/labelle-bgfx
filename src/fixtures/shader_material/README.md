# Generic material GPU probe fixtures

These binaries are exact copies of the existing `fs_flash_*` and `fs_palette_*`
arrays in `src/shaders.zig`. Separate fixture files let the test supply borrowed
`@embedFile` binaries through the public game API without importing backend-private
shader modules into a second Zig module. They are test inputs, not another runtime
shader path.

Regenerate using the corresponding `src/shaders/fs_flash.sc` and `fs_palette.sc`
sources, `src/shaders/varying.def.sc`, and the pinned zbgfx shaderc. Profiles are
`linux/120` (glsl), `android/300_es` (essl), `linux/spirv` (spv), and `osx/metal` (mtl).
Use the command documented in the root README's shader regeneration section.
