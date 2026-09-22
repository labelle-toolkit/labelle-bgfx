# RESOLVED: "GLES post-fx regression" was a surface-cycle bug, not the API 161 upgrade (#119)

Found and root-caused 2026-09-22 on an SM-T505 (Adreno 610, OpenGL ES 3.2).
**Not a #119 blocker.** An earlier revision of this note blamed the SPIRV-Cross
GLSL output and then a #118-style ReleaseFast miscompile; both were wrong.

## What actually differed between the captures

The "flat" capture (`evidence-119/device_postfx.png`) was taken after the
device had dozed and been woken, so the app had gone through an Android
surface cycle (`APP_CMD_TERM_WINDOW` → `APP_CMD_INIT_WINDOW`). The
"pre-upgrade works" and "Debug works" captures were both **cold launches**.
Optimize mode and bgfx API version were red herrings.

Proof, on the upgraded ReleaseFast build:

- The binary that rendered flat at 14:15 is byte-identical (`shasum`) to the
  one that renders bloom + CRT correctly on **8/8 cold launches**.
- The same binary, same process: cold launch shows post-fx; HOME → resume
  drops it; it stays dropped through power cycle and rotations.
- After the restore, logcat shows `sprite shaders initialized` again but never
  `post-fx programs initialized`: no post-fx pass is attempted at all.
- Disassembly of `submitPostPass` and its two call sites in `main.gameFrame`
  shows every handle argument (`set_texture`, `set_view_frame_buffer`, `submit`)
  stored or loaded from a real slot. The #118 pattern is absent.

Metal ReleaseFast on the upgrade is byte-identical to the Phase-1 Metal
ReleaseFast capture.

## Root cause (pre-existing; untouched by #119)

1. On surface loss, `window.teardownSurface` calls `gfx.resetRenderTargets()`
   (= `render_target.reset()`, also present on `origin/main`),
   which invalidates the whole render-target pool before `bgfx.shutdown`.
   That's correct, because the handles belong to the dead context.
2. labelle-gfx's `PostFxDriver` (`src/post_fx.zig`) caches `target_a` /
   `target_b` ids and only recreates them in `ensureTargets` when the ids are
   `0` or the canvas size changed. The canvas is the DESIGN size, so it never
   changes across a surface cycle or rotation.
3. After restore the driver keeps using the stale ids. `beginRenderTarget`,
   `applyPostPass` and `drawRenderTarget` all no-op on an unknown id
   (`validId`), so the scene falls through to the backbuffer un-processed.
   Nothing is logged.

`src/gfx/render_target.zig` and gfx `post_fx.zig` are unchanged by this
branch (only the `setViewRect` depth args and i16 casts differ), so API 142
has the same bug by construction. This was established by reading the code; the
API-142 build was NOT re-run through a surface cycle on the device.

## Fix direction (separate ticket, gfx + engine)

The driver must forget its targets on surface loss without destroying them
(the handles are already dead). For example, add a `PostFxDriver.surfaceLost()`
that zeroes `target_a/b` + `targets_w/h`, called from the engine's
`Game.surfaceLost()` path through the retained engine. A backend-side
`renderTargetValid(id)` check in `ensureTargets` would also work, but it puts
the burden on every backend.

Test: a unit test in gfx with a mock backend whose `reset` invalidates ids,
which asserts that `ensureTargets` **re-creates** (asserting the mechanism,
not just that a frame renders).

## Lessons

- Compare like with like across **lifecycle state**, not only optimize mode
  and version: a cold launch is not the same as a resumed launch.
- The "same binary" check (`shasum`) should come first. It would have killed
  both wrong hypotheses immediately.
