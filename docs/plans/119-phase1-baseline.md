# Phase 1 evidence: baseline and local-patch inventory (#119)

Recorded 2026-09-22 against `feat/119-bgfx-api-upgrade` at `7fe8665`
(labelle-bgfx v0.23.1, which carries the #118 scalar-handle fix).

Nothing in this document changes the renderer. It establishes the baseline the
upgrade will be judged against.

## 1. Environment provenance

| Item | Value |
| --- | --- |
| Host | Darwin 25.6.0 arm64, macOS 26.6.2 |
| Zig | 0.16.0 |
| Android NDKs available | 26.1.10909125, 26.3.11579264, 27.0.12077973, 28.2.13676358 |
| Emscripten | provisioned under `~/.labelle/emsdk` (CLI-managed) |
| Physical device | **SM-T505 connected and reachable** (`R9XR6009TJN`) — Android 12, Adreno 610, OpenGL ES 3.2 `V@0502.0` |

The plan lists physical-device availability as a completion risk. It is
resolved: the tablet is attached and responding to `adb`. Device evidence is
obtainable, so a missing device cannot later be used to narrow scope.

## 2. Dependency pins at baseline

| Package | Pin |
| --- | --- |
| zbgfx | `934372f13b92e651c9e43613af6dff96d231e782` (package `zbgfx-0.12.0`) |
| vendored bgfx API | **142** (`libs/bgfx/include/bgfx/defines.h:18`) |

zbgfx vendors bgfx/bx/bimg as **plain source trees** — no submodules, and
`build.zig.zon` declares `.dependencies = .{}`. Upstream ancestry is therefore
not recoverable from git; it is recorded only in zbgfx's `README.md`.

### Recorded upstream ancestors — all three verified to exist

| Tree | Ancestor | Date |
| --- | --- | --- |
| bgfx | `8532b2c45d2f4332a9ac9734b85c2ea2253cb8d5` | 2026-03-26 |
| bx | `cac72f6cfa0893393ea12692ebfacb4495f8c826` | 2026-03-15 |
| bimg | `9114b47f532ce59cd0c6c9f8932df2c48888d4c1` | 2026-03-23 |

`bgfx@8532b2c` carries `BGFX_API_VERSION 142`, matching the vendored tree
exactly. The ancestor record is trustworthy.

## 3. The vendor is NOT a uniform snapshot

This is the most consequential finding for scoping the upgrade.

Diffing each vendored tree against its recorded ancestor:

| Tree | Pruned from vendor | Added in vendor | Content differs |
| --- | --- | --- | --- |
| bgfx | 98 | 38 | 5 |
| bx | 6 | 0 | **0** |
| bimg | 5 | 0 | **0** |

- **bgfx core (`src/`, `include/`) matches `8532b2c` exactly.** The five content
  differences are `CONTRIBUTING.md`, `LICENSE`, `README.md` and the two
  `examples/common/imgui/imgui.{cpp,h}` files — none compiled into this backend.
- **bx and bimg carry zero source patches.** The only differences are docs and
  pruned build/test/tooling directories.
- **The 38 "added" bgfx files are a stale `3rdparty/` subtree.** Spot-checked
  `3rdparty/spirv-tools/source/opt/instrument_pass.cpp`: present in our vendor,
  **absent at `8532b2c`**, and last touched upstream **2024-10-19**. Upstream
  deleted it well before our ancestor; our copy predates that removal.

So the vendored core is ~6 months old while parts of `3rdparty/` are ~2 years
old. A wholesale re-vendor pulls roughly two years of spirv-tools / glslang /
dawn-tint churn — and those are precisely the components that build **shaderc**,
which the plan already identifies as the risky half. The change surface is
larger than the API delta alone suggests. Phase 2 should decide deliberately
whether `3rdparty/` is re-vendored wholesale or held.

## 4. Local-patch inventory — complete

The fork's entire delta against upstream `cyberegoorg/zbgfx` is **two commits**.
All local work is in the Zig layer; the vendored C++ is unpatched.

| Commit | Date | Files | Rationale | Upstream status | Regression check |
| --- | --- | --- | --- | --- | --- |
| `0b229b7` | 2026-07-01 | `build.zig` (+94/−7), `src/em_astcenc_stub.cpp` (+67) | wasm32-emscripten arm: `-Demsdk_sysroot`, forces single-threaded, drops the ASTC encoder's `std::thread` path, aliases bx version macros, hosts shaderc. Native builds byte-for-byte unchanged (every change guarded by `os.tag == .emscripten`). | Submitted upstream; **see caveat below** | `zig build test-shader-material-wasm32`; wasm example build + browser run |
| `934372f` | 2026-07-29 | `src/callbacks.zig` (+3/−2) | `CCallbackVtblT` was missing bgfx's `_format` parameter on `screen_shot`, shifting every later argument and segfaulting the render thread on first `--screenshot` (#61). `src/bgfx_callback.zig` consumes the vtable directly, so the fix must be IN the pinned commit. | Fork-local | Any `--screenshot` run; the screenshot/callback checks in the Phase 5 matrix |

**Caveat on the upstream PR reference.** #119 and `build.zig.zon` both say the
wasm work was "submitted upstream as PR cyberegoorg/zbgfx#9". Upstream zbgfx is
hosted on **Codeberg** (fork commits carry
`Reviewed-on: https://codeberg.org/cyberegoorg/zbgfx/pulls/...`), and GitHub's
`cyberegoorg/zbgfx#9` is an unrelated "Upgrade BGFX" PR. The reference is to
Codeberg numbering. Its status is **unverified** — resolve it in Phase 2 before
claiming the patch is or is not upstream.

## 5. Host baseline — every entry point, exit codes recorded separately

All 14 steps from the plan's Phase 5 host list, run unchanged on this baseline.
Exit status captured per step rather than inferred from output text.

| Step | Exit |
| --- | --- |
| `zig build test --summary all` | 0 — **247/247 tests, 46/46 steps** |
| `shader-material-probe` | 0 |
| `texture-sampling-probe` | 0 |
| `transient-exhaustion-probe` | 0 |
| `transient-exhaustion-probe-build -Dtarget=x86_64-windows` | 0 |
| `headless-probe` | 0 |
| `surfaceless-scale-probe` | 0 |
| `screen-fill-cover-probe` | 0 |
| `material-golden` | 0 |
| `post-fx-golden` | 0 |
| `post-fx-integration-golden` | 0 |
| `post-fx-integration-golden-single` | 0 |
| `post-fx-integration-golden-triple` | 0 |
| `test-shader-material-wasm32` | 0 |

**No pre-existing host failures.** Any failure after the upgrade is caused by
the upgrade, which is the property this baseline exists to establish.

Note the Windows row is a **cross-link check, not a runtime result** — it proves
the target links, not that it behaves. The plan already treats Windows runtime
as a separate gate; this baseline does not close it.

## 6. Corrections to #119

1. **"~2 months of renderer and driver fixes" understates it.** API 142 was
   introduced by `a73c12db8f50` (2026-03-09) and superseded by `f3ad0e91af4d`
   (2026-04-13); our tree is `8532b2c` (2026-03-26). Upstream master
   `81d81fba72c4` (2026-09-19) is API 161. The delta is ~**6 months**, not two.
   The "19 API revisions" count is correct.
2. The `cyberegoorg/zbgfx#9` reference points at Codeberg, not GitHub — see §4.

## 7. Phase 1 exit status

- [x] Isolated zbgfx checkout; revision and vendor ancestry recorded
- [x] Toolchain versions recorded (Zig, NDK, Emscripten, host)
- [x] Complete local-patch inventory with rationale and regression checks
- [x] Host tests and GPU probes run on the unchanged baseline
- [x] Pre-existing failures recorded — there are none on the host matrix
- [ ] **Remaining: ReleaseFast bloom+crt capture on Metal and SM-T505.**
      The device is connected and the host goldens are green; this needs the
      `examples/bgfx-android` APK build/install/run cycle, which CI does not
      perform (CI cross-builds `libgame.so` and runs a host scene-load smoke
      only). Until captured, there is no device before-image to diff against,
      and no Android acceptance gate can be claimed.

Exit criterion "a reproducible baseline and complete local-patch inventory" is
met for the host and the inventory. The device half is open and is the first
thing Phase 2 should not proceed without.
