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

bgfx implements the P1 curated material effects `flash` and `palette_swap` (the
optional `drawTextureProMaterial` / `materialSupported` contract decls in
labelle-core). Both are authored the same way as the GPU-YUV video one-off: a
`.sc` fragment shader (`src/shaders/fs_flash.sc`, `fs_palette.sc`) compiled by
bgfx `shaderc` to per-renderer bytecode (Metal / SPIR-V / GLSL / ESSL) embedded
in `src/shaders.zig`, built into a program alongside the sprite program
(`src/gfx/programs.zig`). Effects the backend does not implement (`dissolve`,
`outline`) degrade to a plain sprite. See `RFC-MATERIAL-POSTFX.md` (labelle-gfx).

- **flash** — mixes the sprite texel toward an rgba colour by `amount`
  (`MaterialUniforms.scalar0`), preserving alpha (the GPU hit-flash).
- **palette_swap** — recolours a shared atlas: the texel's red channel is a
  palette index looked up in a LUT ramp bound from `MaterialUniforms.aux_texture`
  (`aux_count` entries). A zero/dead LUT handle degrades to a plain sprite.

### Regenerating the material shaders

The embedded bytecode in `src/shaders.zig` is produced offline (there is no
in-tree shader-compile build step; the sprite/YUV arrays are hand-committed the
same way). Build `shaderc` from the pinned zbgfx, then compile each shader for
`{linux/120, android/300_es, osx/metal, linux/spirv}`:

```
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

```
zig build material-golden-bless   # overwrites test/golden/material_flash_palette.tga
```

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
| `LABELLE_BGFX_TRACE=1` | Mirror bgfx's internal trace stream to stderr. Very chatty; off by default. |
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

```
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
