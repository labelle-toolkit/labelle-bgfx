# Phase 4 probe: one blob, regenerated (#119)

Run 2026-09-22 before regenerating anything wholesale. Purpose: find out
whether the new shaderc's output is drop-in or a wholesale change, cheaply.

Both compilers built from their own source sets:

| Compiler | Version string |
| --- | --- |
| old (current pin, `934372f`) | `shaderc, bgfx shader compiler tool, version 1.19.142.` |
| new (API 161 vendor) | `shaderc, bgfx shader compiler tool, version 1.19.161.` |

## 1. The recorded recipe is CORRECT — harness validated

Old shaderc, recipe exactly as recorded in #119, against `fs_sprite.sc`:

| Variant | Regenerated | Committed | Result |
| --- | --- | --- | --- |
| glsl (`--platform linux -p 120`) | 189 B | 189 B | **byte-identical** |
| essl (`--platform android -p 300_es`) | 301 B | 301 B | **byte-identical** |
| mtl (`--platform osx -p metal`) | 609 B | 609 B | **byte-identical** |

So the recipe reproduces committed output, and any difference the NEW
compiler shows is attributable to the upgrade rather than to a wrong recipe.

## 2. `vs_sprite`'s non-reproducibility is REAL — the plan's caveat verified

Same old compiler, same recipe, `vs_sprite.sc`:

| Variant | Regenerated | Committed | Result |
| --- | --- | --- | --- |
| glsl | 382 B | 460 B | DIFFERS |
| essl | 439 B | 439 B | byte-identical |
| mtl | 880 B | 903 B | DIFFERS |
| spv | 1225 B | 1293 B | DIFFERS |

The committed blobs are LARGER in every differing case, consistent with an
older compiler emitting extra metadata or optimising less. `essl`
reproducing is the control that makes this a genuine provenance gap rather
than a broken harness — same file, same run, same recipe.

## 3. BLOCKING: the shader binary format version bumped

```
committed blobs : FSH \x0b   (version 11)
new shaderc     : FSH \x0c   (version 12)
```

This turns #119's stated risk ("newer bgfx can reject older shader-binary
versions") into a certainty. Consequences:

* **There is no partial upgrade.** The vendor bump and a COMPLETE blob
  regeneration must land in the same change, or the runtime is handed
  binaries of a version it does not accept.
* **Blob diffing is dead as a review technique.** Old and new differ
  structurally by construction, so "explain every diff" has to be judged on
  RENDERED OUTPUT — the goldens and the device — not on bytes.

## 4. BLOCKING DECISION: the desktop GL floor moves 2.1 -> 3.3

The new shaderc **rejects `-p 120`**. Its GLSL profiles now start at `330`:

```
330  OpenGL Shading Language (GLSL)
400  410  420  430  440
```

This is upstream's API-155 change, "Raised minimum OpenGL version to 4.3.
OpenGLES to 3.0."

Our recipe uses `-p 120` (GLSL 1.20, ~OpenGL 2.1), and the intent is
explicit in `src/gfx/programs.zig:162`:

> Desktop `.OpenGL` (2.1) stays on the `-p 120` glsl `else` arm.

Regenerating at 330 raises the desktop OpenGL requirement from **2.1 to
3.3**. Scope of impact:

| Renderer | Blob | Affected? |
| --- | --- | --- |
| Metal (macOS) | mtl | no |
| Direct3D (Windows) | — | no |
| Vulkan (Linux w/ Vulkan) | spv | no |
| OpenGLES (Android, WebGL2) | essl | no — already `300_es`, still the floor |
| **OpenGL (desktop fallback)** | **glsl** | **yes — 2.1 -> 3.3** |

So the blast radius is desktop Linux without Vulkan, on GPUs supporting
OpenGL 2.1-3.2. Hardware from roughly 2010 onward generally does 3.3, so
this is likely acceptable — but it is a USER-VISIBLE COMPATIBILITY CHANGE
that #119 and the plan do not mention, and it should be decided
deliberately rather than absorbed silently.

Good news: `fs_sprite.sc` compiles cleanly at `-p 330` (234 B emitted), so
the shader SOURCES need no rewrite — bgfx's `bgfx_shader.sh` absorbs the
dialect change.

## 5. What this means for Phase 4

1. Get a decision on the GL floor (§4) before regenerating anything.
2. Record the new recipe as `-p 330` for glsl; the other three are unchanged.
3. Regenerate EVERY blob (§3 — no partial upgrade), `vs_sprite` included,
   which also closes the §2 provenance gap as a side effect.
4. Verify by rendered output only. The goldens and the device pass are the
   gate; byte comparison against the old blobs is meaningless now.
