# Generic material GPU probe fixtures

These binaries are exact copies of the existing `fs_flash_*` and `fs_palette_*`
arrays in `src/shaders.zig`. Separate fixture files let the test supply borrowed
`@embedFile` binaries through the public game API without importing backend-private
shader modules into a second Zig module. They are test inputs, not another runtime
shader path.

Because they are exact copies, regenerate them by re-extracting the arrays from
`src/shaders.zig` after that file is regenerated — not by running shaderc twice.
That keeps the "exact copies" invariant true by construction. They are bgfx
binary v12 containers; a v11 fixture fails `shader_binary.read` at the magic.

Regenerate using the corresponding `src/shaders/fs_flash.sc` and `fs_palette.sc`
sources, `src/shaders/varying.def.sc`, and the pinned zbgfx shaderc. Profiles are
`linux/330` (glsl — was `120` until the bgfx API 161 bump, labelle-bgfx#119), `android/300_es` (essl), `linux/spirv` (spv), and `osx/metal` (mtl).
Use the command documented in the root README's shader regeneration section.
