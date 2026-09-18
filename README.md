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

## Material seam (curated per-draw effects, labelle-gfx#305)

bgfx implements the whole curated material set — `flash`, `palette_swap`,
`dissolve` and `outline` through the optional `drawTextureProMaterial` /
`materialSupported` contract decls in labelle-core, plus `pixel_water` through
its own `drawTextureProPixelWater` decl and its own program (see "Pixel water"
below). Every one is authored the same way as the GPU-YUV video one-off: a `.sc`
fragment shader (`src/shaders/fs_flash.sc`, `fs_palette.sc`, `fs_dissolve.sc`,
`fs_outline.sc`, `fs_pixel_water.sc`) compiled by bgfx `shaderc` to per-renderer
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
- **pixel_water** — the COND-07 reactive reservoir (#100), its own draw path and
  program; a missing mask, or a renderer that will not link `fs_pixel_water`,
  degrades to the authored static sprite and flips
  `materialSupported(.pixel_water)` to false.

### Regenerating the material shaders

The embedded bytecode in `src/shaders.zig` is produced offline (there is no
in-tree shader-compile build step; the sprite/YUV arrays are hand-committed the
same way). Build `shaderc` from the pinned zbgfx, then compile each shader for
`{linux/120, android/300_es, osx/metal, linux/spirv}`:

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

## Pixel water (COND-07, #100 / RFC-PIXEL-WATER)

`pixel_water` is a fifth curated effect, and the only one whose support is **not**
implied by `drawTextureProMaterial`. Its per-instance payload (three colour ramps,
wave/ripple tuning and eight live impacts) is 8x a `MaterialUniforms` block, so it
rides its own optional contract decl — `drawTextureProPixelWater(texture, source,
dest, origin, rotation, tint, water: PixelWaterDraw)` — taking labelle-core's flat
256-byte `PixelWaterDraw` **by value**. Declaring that decl is what makes
`core.materialCapabilities` advertise `pixel_water`; `materialSupported(.pixel_water)`
additionally goes false once `fs_pixel_water` has failed to link on this renderer.

Units, in one line each:

- Local coordinates are **native art pixels**, origin at the reservoir rectangle's
  top-left, +X right, +Y **down**.
- `level` is the fraction filled from the **bottom**: `surface_y = logical_height *
  (1 - level)`. Level 0 renders no water at all.
- `grid_pixels` is native art pixels per effect cell. Every sample position is the
  logical cell centre and every displacement is quantized to whole grid increments.
  The reference scene's 6 screen pixels per cell is integer *enlargement* of the
  art — not this value, and not an engine constant.
- A ripple's age is `time - start_time`; an age outside
  `[0, ripple_duration_seconds)` contributes nothing, and entries at or past
  `ripple_count` are ignored (they are not guaranteed zeroed). `time` is
  **simulation** seconds, never a wall clock.
- `PIXEL_WATER_FLAG_WAVES` toggles surface waves without destroying the authored
  amplitude.

### Sampler slots and uniform registers

Slots are fixed. Units 1 and 2 are bound with point+clamp sampler flags at draw
time, so nearest/clamped sampling is a property of the effect, not of how the
asset happened to be uploaded.

| slot | uniform | content | colour space |
|------|---------|---------|--------------|
| 0 | `s_tex` | the reservoir sprite's own texture (also the fallback art) | authored, sampled exactly like a plain sprite (x vertex tint) |
| 1 | `s_water_mask` | reservoir silhouette, standalone (never atlased) | coverage **data**: alpha x max(rgb), never gamma-converted. White-on-transparent and white-on-black both read correctly |
| 2 | `s_water_reflect` | the **supplied** reflection, standalone, reservoir-local | authored, used as-is: not flipped, not captured from the scene |

| register | uniform | content |
|----------|---------|---------|
| 0 | `u_water_rect` | `(u0, v0, u1, v1)` — the sprite's source frame in whole-atlas UV space; `(0,0,1,1)` standalone |
| 1–2 | `u_water_head[2]` | `(logical_width, logical_height, grid_pixels, ripple_count)`, then `(waves_enabled, has_mask, has_reflection, raw_flags)`. The u32 header widened to float, with `flags` decoded on the Zig side so the shader never does bitwise arithmetic on a float |
| 3–5 | `u_water_color[3]` | `deep` / `surface` / `highlight`, **linear** 0..1 rgba — already converted out of the authored sRGB by the engine. Nothing converts again |
| 6–8 | `u_water_params[3]` | `(level, time, wave_amplitude_px, wave_period_s)`, `(distortion_px, reflection_opacity, ripple_duration_s, ripple_radius_px)`, `(ripple_strength_px, _, _, _)` |
| 9–16 | `u_water_ripples[8]` | one impact per slot: `(x, start_time, strength, _)` |

The three colour/param/ripple blocks are uploaded straight off the locked
`PixelWaterDraw` layout (colours at byte 32, params at 80, ripples at 128 — exactly
3 + 3 + 8 consecutive `vec4`s); only the integer header is repacked.

`PIXEL_WATER_MAX_RIPPLES` is 8 and **fixed**: the shader's ripple loop needs a
comptime trip count, because a dynamically-bounded loop is a portability hazard on
ESSL 3.00 / WebGL2.

### Program lifetime

The water program and its uniforms are built and destroyed **independently** of the
four material programs (`initWaterProgram` / `waterProgramReady` /
`waterProgramAvailable` / `destroyWaterProgram` in `src/gfx/programs.zig`), following
the same lazy-build + latch-failure pattern. A water link failure degrades only
water — to the authored static reservoir sprite — and leaves flash / palette_swap /
dissolve / outline untouched; the converse also holds. Nothing is created per frame,
and every owned handle is released in `shutdownPrograms` (so an Android surface cycle
gets one more honest attempt).

`fs_pixel_water.sc` is compiled and embedded with the same offline shaderc recipe as
the other material shaders (see above), in all four variants. **ESSL 3.00 is not
optional**: it is what WebGL2 and Android GLES select.

### Headless golden (`zig build pixel-water-golden`)

`src/pixel_water_golden.zig` renders a fixed-simulation-time matrix — fill levels,
the waves flag, ripple start/mid/expired, edge impacts, a live entry parked past
`ripple_count`, masked-out pixels, zero amplitude, a one-native-pixel displacement,
a coarse grid, native/2x/4x nearest scaling, two independent reservoirs, an
ATLAS sub-rect frame and a level-1.0 reservoir masked to its TOP row — into its
**own** golden (`test/golden/pixel_water.tga`), never the material one. It also
asserts four semantic invariants region-for-region (expired ripple == no ripple;
a ripple past the count == ignored; an atlas sub-rect frame == the same art
standalone; a full reservoir leaves no dry cell, top row included) in check
**and** bless mode, so a regression cannot be blessed in. The capture ALWAYS
lands on the candidate first: bless replaces the committed golden only after
every invariant has passed, so a violating shader cannot leave a bad image on
disk for someone to commit. If the water program does not link on the capturing
machine the run exits `7` (`PIXEL_WATER_UNSUPPORTED`) instead of capturing — a
static-fallback scene must never reach the golden, least of all through bless
mode. Regenerate with `zig build pixel-water-golden-bless`.

> **Fixture caveat.** The shader matrix golden uses procedural stand-ins. The
> actual layered COND-07 artwork has a separate runnable scene and capture checks.

Run `zig build condenser-demo` for the actual condenser with bottom water, falling
drops, fading impact ripples and independent mist. `zig build condenser-capture`
writes a deterministic GPU capture. See [the condenser example](example/CONDENSER.md)
for fill, scale, animation captures and verification commands.

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
