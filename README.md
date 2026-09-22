# labelle-bgfx

The **bgfx** rendering backend for [labelle](https://github.com/labelle-toolkit),
extracted out-of-tree as a pluggable provider package (labelle-assembler epic #386).

bgfx is the first real backend to leave the assembler monorepo. It is
contract-conformed (`labelle-core`'s `assertBackend` / `assertWindow` /
`assertInput`) and manifest-driven (`backend.manifest.zon`), so the assembler
fetches it into its package cache and drives codegen entirely from the manifest
— no built-in enum branch required.

## Using it

Opt in explicitly via `backend_package`:

```zig
.{
    .name = "my_game",
    .backend_package = .{
        .name = "bgfx",
        .repo = "github.com/labelle-toolkit/labelle-bgfx",
        .version = "0.1.0",
    },
    // ...
}
```

(Once the Phase-5 enum shorthand maps `.bgfx` to this package, `.backend = .bgfx`
will resolve here transparently — that flip is deferred until this package is
validated against real games.)

### Platform requirements

Since the bgfx API 161 vendor (#119):

- **x86 / x86_64 CPUs need SSE4.2.** The vendored bx/bimg/bgfx C libraries are
  compiled with SSE4.2 enabled (bx's SIMD code requires it), whatever `-Dcpu`
  the game uses. A build for a generic x86 target still succeeds, but the
  binary dies with an illegal-instruction fault on a CPU without SSE4.2
  (pre-2008 Intel, pre-2011 AMD). ARM (Android, Apple Silicon) and wasm are
  unaffected.
- **Desktop OpenGL needs 4.3.** This matters only where bgfx picks the GL
  renderer: Linux without Vulkan, or the Windows GL fallback. macOS uses Metal;
  Android and WebGL2 use GLES 3.0 and are unaffected.

## Shared gamepad packages

The desktop/Android gamepad sources are versioned packages this backend depends
on (not vendored): [`labelle-sdl-gamepad`](https://github.com/labelle-toolkit/labelle-sdl-gamepad)
and [`labelle-android-gamepad`](https://github.com/labelle-toolkit/labelle-android-gamepad).

| Path | Role |
|------|------|
| `backend.manifest.zon` | Codegen contract the assembler reads (run-loop style, templates, build fragments). |
| `build_fragments/`, `templates/` | build.zig fragments + main-loop templates spliced at codegen time. |
| `src/` | gfx / window / input / audio modules + the bgfx/glfw/Android glue. |
| `libs/miniaudio/` | desktop audio device backend. |

## Game-owned shader materials

`gfx.createShaderMaterial(core.shader_material.Descriptor)` creates an instance
from game-supplied **fragment** shader binaries. The backend supplies its existing
sprite vertex shader/layout. Assign the returned `Id` to `Material.shader`; a
non-`none` shader takes precedence over the curated effect field.

The renderer selects `glsl`, `essl`, `spv`, or `mtl`. Empty selected variants return
`error.Unsupported`; no other renderer's binary is substituted. Direct3D is not
advertised: this backend has no matching sprite vertex binary for it yet. The
binaries must come from the pinned bgfx shaderc (v12 container, bgfx API 161). Metal uses its
normal source-containing output, not an opaque precompiled metallib.

```zig
const sm = core.shader_material;
const id = try gfx.createShaderMaterial(.{
    .label = "color-mix",
    .shaders = .{ .spv = @embedFile("fs_color_mix.spv.bin") },
    .parameters = &.{
        .{ .name = "u_mix", .kind = .scalar, .defaults = &.{0.5} },
        .{ .name = "u_tint", .kind = .vec4, .defaults = &.{1, 0, 0, 1} },
    },
});
defer gfx.destroyShaderMaterial(id);
try gfx.setShaderParameter(id, "u_mix", &.{0.8});
// Render with Material{ .shader = id }.
```

Descriptor slices are borrowed only during creation. Each instance copies names,
parameter defaults and texture bindings; cached programs own their selected binary.
The label is diagnostic input and is not retained. Program cache identity includes
binary bytes, ordered parameter/texture schema, sampler modes and blend mode;
parameter values and texture IDs remain per-instance. Last-instance destruction
releases the program. All operations, including destruction, run on the render
thread.

Parameter `count` is an array-element count. Values are tightly packed:
`count * channels(kind)` floats. Scalar/vec2/vec3 values are zero-padded into vec4
registers for bgfx; declare corresponding shader uniforms as `vec4` arrays and
read the appropriate channels. Mat4 uses 16 column-major floats per element.
Defaults may be empty (all zeros); updates must have the exact shape and finite
values. Binding names, duplicate names, counts, capacity and reserved bgfx names
are checked by the core contract. There are at most 256 live instances, 16 named
parameters, 4 auxiliary textures, and 64 uniform registers including the automatic
rect. Exhausted generations retire their slot rather than wrapping.

Creation also checks shader metadata and `getShaderUniforms`/`getUniformInfo`.
Every descriptor binding must survive shader compilation with matching type and
count. Misspelled, optimized-out, undeclared and incompatible bindings fail;
incompatible global bgfx uniform names are rejected across instances and against
the remaining curated programs. Do not declare unused parameters in a descriptor.

The shader may use these automatic bindings without listing them in the descriptor:

- `SAMPLER2D(s_tex, 0)` receives the sprite's texture and inherits its filter.
- `uniform vec4 u_material_rect` receives atlas UV bounds `{u0,v0,u1,v1}`.
  It may be absent or optimized out. Source flips retain positive atlas bounds.
- Auxiliary texture descriptors are ordered: entry 0 uses stage 1, entry 1 stage 2,
  and so on. Author `SAMPLER2D` declarations with those ordinals. Vulkan register
  metadata and Metal texture/sampler annotations are checked for agreement;
  reordered descriptors fail instead of silently sampling different images.
  GLSL/ESSL use bgfx's dynamic named sampler mapping. Point and linear modes both
  clamp at texture edges.

Texture IDs are borrowed backend IDs. Unloading a texture invalidates every
material binding to it before its pool slot is reused. Explicitly set a replacement
with `setShaderTexture`; an old binding never starts sampling a new occupant.
A stale material ID or invalidated texture draws the ordinary sprite. A missing
variant or failed synchronous shader/program creation returns an error. bgfx's
asynchronous renderer/driver compilation errors are reported through its callback;
a valid API handle is not a guarantee of successful later driver compilation.

`shutdownPrograms` destroys all instances and invalidates their IDs. Generation
counters survive shutdown, so old IDs cannot alias new instances after context
recreation. The window lifecycle enables `shaderMaterialSupported` only after a
successful context initialization. Hosts managing bgfx directly must call
`shaderMaterialContextStarted` after successful init and `shutdownPrograms` before
bgfx shutdown, then recreate their materials.

### Validation

`zig build test` includes the CPU ownership, validation, caching and lifecycle
suite; `zig build test-shader-material` runs it separately. The GPU-dependent
`zig build shader-material-probe` checks rendered independent instances, named
reflection, texture-unload/reuse fallback, state isolation and context recreation.
CI runs this probe in addition to the remaining curated-effect goldens. Visual
coverage for game-authored effects belongs in the game integration suite.

This branch needs the new core contract. Until a release containing it is pinned
in `build.zig.zon`, pass `-Dcore-source=/path/to/labelle-core/src/root.zig` for local
builds, or supply the generated game's unified core module. On Windows without an
SDL2 SDK, add `-Dgamepad_enabled=false` for renderer-only validation.

## Material seam (curated per-draw effects, labelle-gfx#305)

bgfx implements the whole curated material set — `flash`, `palette_swap`,
`dissolve` and `outline` through the optional `drawTextureProMaterial` /
`materialSupported` contract decls in labelle-core. Every one is authored the same way as the GPU-YUV video one-off: a `.sc`
fragment shader (`src/shaders/fs_flash.sc`, `fs_palette.sc`, `fs_dissolve.sc`,
`fs_outline.sc`) compiled by bgfx `shaderc` to per-renderer
bytecode (Metal / SPIR-V / GLSL / ESSL) embedded in `src/shaders.zig`, built into
a program alongside the sprite program (`src/gfx/programs.zig`). Nothing here is
unimplemented; the only degrade-to-a-plain-sprite path left is a RENDERER-SPECIFIC
program failure (or a missing required input, below), and it degrades ONLY the
affected effect. See `RFC-MATERIAL-POSTFX.md` (labelle-gfx).

- **flash** — mixes the sprite texel toward an rgba colour by `amount`
  (`MaterialUniforms.scalar0`), preserving alpha (the GPU hit-flash).
- **palette_swap** — recolours a shared atlas: the texel's red channel is a
  palette index looked up in a LUT ramp bound from `MaterialUniforms.aux_texture`
  (`aux_count` entries). A zero/dead LUT handle degrades to a plain sprite.
- **dissolve** — threshold-based burn-away. Its noise texture is optional: no
  `aux_texture` (or a dead handle) falls back to built-in procedural noise, so
  this effect never degrades to a plain sprite.
- **outline** — composites a coloured border around the sprite's alpha edge.
### Regenerating the material shaders

The embedded bytecode in `src/shaders.zig` is produced offline (there is no
in-tree shader-compile build step; the sprite/YUV arrays are hand-committed the
same way). Build `shaderc` from the pinned zbgfx, then compile each shader for
`{linux/330, android/300_es, osx/metal, linux/spirv}` (API 161 shaderc rejects GLSL profiles below 330):

```shell
# in the resolved zbgfx package dir:
zig build -Dwith_shaderc=true            # → zig-out/bin/shaderc
shaderc -f src/shaders/fs_flash.sc --type fragment --platform osx -p metal \
        --varyingdef src/shaders/varying.def.sc -i <zbgfx>/shaders -O 3 -o out.bin
# → convert each .bin to a `pub const fs_flash_<variant> = [_]u8{ … };` array.
```

### Headless golden (`zig build material-golden`)

`src/material_golden.zig` renders a fixed scene — a `flash` sprite (amount 0.6
toward red) + a `palette_swap` sprite (a 4-band index atlas recoloured through a
LUT) — **fully surfaceless** (Metal/Vulkan offscreen framebuffer, no window / no
display server, the `initHeadless` path) and captures a TGA. `zig build
material-golden` diffs it against the committed golden
(`test/golden/material_flash_palette.tga`) with a per-channel tolerance; CI runs
it on the macOS runner. After an intentional shader change, regenerate the golden
on a machine with a Metal/Vulkan device:

```shell
zig build material-golden-bless   # overwrites test/golden/material_flash_palette.tga
```

## Texture filtering seam (point/nearest sampling, #77)

Game textures upload with `SamplerFlags_UClamp | SamplerFlags_VClamp` and no
filter bits, which leaves bgfx on its default **bilinear** filter. That is
wrong for pixel art: a 16 px tile drawn at 2x out of a tightly packed atlas
blends its atlas neighbours along every edge, painting a seam grid over the
map. The fix is one flag pair — `SamplerFlags_MinPoint | SamplerFlags_MagPoint`,
the same ones `src/gfx/font.zig` has always used for the font atlas.

`src/gfx.zig` exposes that choice as `TextureFilter` (`.linear` / `.point`),
in two shapes:

| decl | scope |
|------|-------|
| `uploadTextureFiltered(decoded, .point)` | one texture, no global state |
| `setTextureFilter(.point)` / `textureFilter()` | the filter for subsequent unqualified creations — reaches `loadTexture` and `uploadCompressed`, whose signatures core's contract fixes |

**The default is `.linear`**, i.e. byte-identical sampler flags to before this
seam existed, so no existing game changes appearance. Only the two immutable
upload paths (`uploadTexture` / `uploadCompressed`) consult the filter; the
dynamic/YUV plane textures are the video sink and stay bilinear.

Reaching this from game code (`.filter = .point` on an atlas resource) needs a
matching field on labelle-core's texture-load seam — see #77.

## Headless runs (`LABELLE_HEADLESS=1`)

`--headless` (and `--uncapped` / `--ticks`, which imply it) has two
implementations, and the generated loop picks the first that works:

1. **surfaceless** (`window.initHeadless`, #36) — bgfx comes up with `nwh = null`
   and renders into an offscreen framebuffer. No window, **no display server**,
   so it is the one that works on a bare CI box. Needs a Vulkan/Metal device.
2. **invisible window** — an unmapped GLFW window with a real swapchain. Still
   needs a display server; used when (1) is unavailable or declined.

### Env knobs

| variable | effect |
|---|---|
| `LABELLE_HEADLESS_SURFACELESS=0` | Skip the surfaceless attempt and go straight to the invisible window (#61). Also accepts `false` / `no` / `off` / empty. |
| `LABELLE_BGFX_ASSERT=continue` | Log a failed bgfx debug assert and keep running instead of breaking. Default is to log **and** break — bgfx's own behaviour, minus the silence. |
| `LABELLE_BGFX_TRACE=1` | Mirror bgfx's internal trace stream to stderr. Very chatty; off by default. **Debug builds only** — bgfx gates `BX_TRACE` on `BGFX_CONFIG_DEBUG`, so it emits nothing to mirror in ReleaseSafe/ReleaseFast. |
| `LABELLE_BGFX_RENDERER=vulkan\|opengl` | Force the desktop renderer (#30). |

### If a headless run dies with no output

It used to be possible for a bgfx assert to kill the process with
`STATUS_BREAKPOINT` (`0x80000003`, shown by the shell as `-2147483645`) and
**nothing on stdout or stderr**: bgfx's built-in callback routes its diagnostics
through `OutputDebugString`/`syslog` — invisible without a debugger — and then
calls `bx::debugBreak()`. Since #61 this backend installs its own callback
(`src/bgfx_callback.zig`), so the assert's file, line and message land on stderr
as `error(bgfx): FATAL …` first. If you see one, that message names the bug.

### Surfaceless probes

```shell
zig build headless-probe            # bgfx inits + reads back with no window (#36)
zig build mirror-probe              # render target → composite → capture (#36)
zig build screenshot-probe          # captureHeadless writes a valid TGA (#36)
zig build surfaceless-scale-probe   # 512 quads + a view this backend doesn't own (#61)
```

All four run surfaceless and are wired into the display-less CI job.
`surfaceless-scale-probe` is the one that covers **scale** and **third-party
views** (Dear ImGui's overlay submits on its own bgfx view): the other three
render a small fixed scene and were green while a real game crashed two frames
into gameplay.

## Writing tests here: where a `test` block actually runs

**A `test` block in a file that is only ever `@import`ed does not run.** Zig
collects tests from the **root source file** of a test module, so a block
written in, say, `src/gfx/texture.zig` or `src/gfx/font.zig` compiles, is
reported by nothing, and passes forever — including when its assertion is
false. This has already produced dead tests in this repo; `src/gfx.zig`'s
sampler-filter test carries a comment explaining that it lives there, rather
than in `gfx/texture.zig`, precisely to be collected.

So, before writing a test, check `build.zig` for a `b.addTest` whose
`root_source_file` **is the file you are writing in**. If there isn't one:

- **Pure, dependency-free file?** Give it its own test artifact, the way
  `src/gfx/state.zig`, `src/gfx/astc.zig`, `src/video/yuv.zig` and
  `src/video/planes.zig` each have one.
- **File that pulls the module graph (zbgfx, the stb `@cImport`, shaders)?**
  Add a dedicated root file under `src/` that imports it and holds the blocks,
  then wire that as the artifact — `src/font_tests.zig` is the worked example.
  Note it is rooted at `src/`, not `src/gfx/`: a module rooted at
  `src/gfx/<file>.zig` puts the module path at `src/gfx/`, and
  `gfx/programs.zig`'s `@import("../shaders.zig")` then fails with *"import of
  file outside module path"*.

To confirm your tests are collected, put a deliberately failing block in the
file and run `zig build test`. If it passes, your tests are dead.
