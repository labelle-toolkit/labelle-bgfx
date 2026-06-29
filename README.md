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
