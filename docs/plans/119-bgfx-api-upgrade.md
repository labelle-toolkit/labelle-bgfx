# Implementation plan: upgrade vendored bgfx

Tracking: https://github.com/labelle-toolkit/labelle-bgfx/issues/119
Branch: `feat/119-bgfx-api-upgrade`
Plan prepared: 2026-09-22. Implementation has not started.
Baseline: `cfca1e5eda677b06a6c16da51cf31eeeaecbf318` (v0.23.1).

## Outcome and constraints

Upgrade the toolkit-owned zbgfx fork and this backend to a precisely pinned
upstream bgfx revision with API >= 161, retaining supported renderers and targets.
The issue reports API 142 at the current zbgfx pin and proposes upstream short SHA
`81d81fb` as a candidate. Resolve full SHAs and verify these API numbers from the
actual headers before choosing the target; do not track upstream master.

PR #118 has merged into the baseline. Preserve its scalar `submitProgram` extern
and regression guard. Do not describe this upgrade as a fix for the old #65 hang.
Do not change gameplay, public backend behavior, or golden images incidentally.

## Deliverables and review boundaries

1. zbgfx PR: upstream revisions, local patch inventory, binding migration, build
   integration, and reproducible shader-tool build. Link it to this issue.
2. labelle-bgfx PR on this branch: reviewed zbgfx pin/hash, regenerated shaders,
   necessary backend adaptations, reproduction instructions, and validation evidence.
3. Evidence directory/report: exact dependency/tool versions, command exit statuses,
   test counts, platform results, before/after images, and device observations.

Keep vendor imports, handwritten fixes, generated bindings, and shader blobs in
separate commits where possible. The backend PR must state the exact zbgfx PR/head
it depends on. Do not merge it against an unreviewed or moving dependency.

## Phase 1 — inventory and establish the baseline

- [ ] Create an isolated zbgfx checkout; inspect its repository instructions and
  build scripts before editing. Record its current revision and submodule/vendor
  SHAs for bgfx, bx, and bimg, plus Zig, NDK, SDK and Emscripten versions.
- [ ] Inventory every downstream patch against its upstream ancestor. Include the
  screenshot callback signature fix at `934372f`, wasm/Emscripten integration,
  Android sysroot wiring, platform defines, and any allocator/callback changes.
  Record file, rationale, upstream status, and a regression check for each patch.
- [ ] Run existing host tests and GPU probes on the unchanged baseline. Capture
  material, post-fx, integration and pixel-water results before updating anything.
- [ ] Capture the current ReleaseFast bloom+crt result on Metal and SM-T505.
  Record renderer, device OS/GPU, physical/design dimensions and orientation.
- [ ] Record existing failures separately. An unavailable device or skipped GPU
  test is missing evidence, not a passing test.

Exit: a reproducible baseline and complete local-patch inventory.

## Phase 2 — select and import a compatible upstream set

- [ ] Resolve candidate bgfx `81d81fb` to a full commit and inspect its API header,
  release notes/API history and integration requirements. Choose that revision or
  document why another fixed revision is needed.
- [ ] Select compatible bx and bimg commits using upstream integration evidence;
  do not independently take the latest heads. Record all three full SHAs.
- [ ] Import vendor sources without unrelated formatting churn. Reconcile build
  source lists, generated headers, platform flags and required libraries.
- [ ] Reapply local patches individually; omit only patches demonstrated to be
  upstream or obsolete. Update the inventory with evidence for each decision.
- [ ] Build the new shaderc against this exact source set and record its version,
  executable hash, build command, host platform and compiler configuration.

Exit: the vendored libraries and shader compiler build from recorded inputs.

## Phase 3 — audit bindings and ABI contracts

- [ ] Walk API changes from 142 through the selected target. Produce a matrix of
  changed function/callback, old/new signature, layout impact, affected binding,
  backend caller and validation case. Inspect IDL and C headers, not just notes.
- [ ] Identify the fork's binding generation process. Regenerate from the selected
  IDL when supported; if generation is unavailable or requires adaptation, document
  the generator gap and review manual changes against the C API systematically.
- [ ] Audit enums/constants, structure sizes/alignment/offsets, pointer qualifiers,
  optional parameters, callback vtables, allocator interfaces and calling conventions.
  Pay special attention to initialization/platform data, screenshot callbacks,
  texture/framebuffer creation and transient buffers.
- [ ] Retain scalar handle externs from #118. Audit other consumed by-value handle
  APIs for stack-temporary exposure; do not reintroduce vulnerable direct calls.
  Verify ABI assumptions per target before adding another scalar declaration.
- [ ] Add focused compile/layout or behavior checks for changed contracts, including
  callback arity and the existing direct-submit prohibition. Keep generated output
  separate from handwritten compatibility shims.

Exit: documented API delta, binding checks passing, and reviewed ABI boundaries.

## Phase 4 — regenerate shaders and update the backend pin

- [ ] Inventory every blob and source in `src/shaders.zig` / `src/shaders/`, including
  sprite, material, post-fx and video programs. Include every existing renderer
  variant, including variants beyond the four recipes below if present.
- [ ] Build a repeatable regeneration command/script using the new shaderc. Preserve
  source defines and vertex/fragment types; use the shared varying definition.
  Starting recipes from #119 (verify against the new compiler):

  | Variant | Platform/profile |
  | --- | --- |
  | GLSL | `--platform linux -p 120` |
  | ESSL | `--platform android -p 300_es` |
  | Metal | `--platform osx -p metal` |
  | SPIR-V | `--platform linux -p spirv` |

  Common options: `-i <zbgfx>/shaders --varyingdef src/shaders/varying.def.sc`.
  Format emitted arrays as 16 bytes per line. Store the complete invocations,
  input/output hashes and compiler provenance; avoid machine-specific paths.
- [ ] Regenerate all blobs, including the older non-reproducible `vs_sprite`
  GLSL/Metal/SPIR-V variants. A second generation must produce no diff.
- [ ] Verify shader stage/interface compatibility, reflection/uniform contracts,
  program creation, and binary versions on each actual renderer.
- [ ] Update `build.zig.zon` to the reviewed immutable zbgfx revision and correct
  package hash. Update other consuming pins only where needed and explain each.
  Remove local overrides before final validation.

Exit: no mixed old/new shader set and reproducible dependency resolution.

## Phase 5 — validation matrix

Use the repository's current workflow as the authoritative command list. Run game
examples through the labelle CLI; do not bypass its dependency/version guards.
Pin/stamp CLI and assembler versions consistently with example locks.

| Target | Required evidence |
| --- | --- |
| macOS/Metal | Native build, unit tests, GPU probes and goldens; Debug and ReleaseFast active post-fx; ReleaseSafe comparison if results differ |
| Linux | Native build/test and available OpenGL/Vulkan runtime probes; explicitly distinguish surfaceless/GPU runs from compile-only results |
| Windows | Native build/test/runtime smoke on available renderer; retain Windows cross-link checks as additional evidence |
| Android | NDK aarch64 build, package/install and physical SM-T505 validation; compilation alone does not satisfy device acceptance |
| wasm | Emscripten build and browser execution of example; shader/program creation and rendered output checked, not merely emitted files |

Existing host entry points to run and preserve include:

```sh
zig build test --summary all
zig build shader-material-probe
zig build texture-sampling-probe
zig build transient-exhaustion-probe
zig build transient-exhaustion-probe-build -Dtarget=x86_64-windows -Dgamepad_enabled=false
zig build headless-probe
zig build surfaceless-scale-probe
zig build screen-fill-cover-probe
zig build material-golden
zig build post-fx-golden
zig build post-fx-integration-golden
zig build post-fx-integration-golden-single
zig build post-fx-integration-golden-triple
zig build test-shader-material-wasm32
```

- [ ] Check current pixel-water harness location/commands and include it in the
  matrix. Preserve the ReleaseFast example smoke added by #118.
- [ ] Verify screenshots/callbacks, transient exhaustion, shader-material fallback
  and ownership, context recreation, texture sampling, and post-fx ordering.
- [ ] Run SM-T505 cold launch, repeated background/resume, and both rotation
  directions; exercise ReleaseFast with bloom+crt actively enabled. Confirm
  correct colors, scale/aspect, framebuffer contents and absence of black output.
- [ ] Inspect failures and image diffs individually. Bless a golden only after
  explaining the rendering change and reviewing before/after captures. Never
  bulk-bless to make CI green or weaken thresholds to hide unexplained changes.
- [ ] Run all CI jobs on the final immutable dependency/head. Document unsupported
  or unavailable test environments explicitly and leave corresponding gates open.

## Completion, release order and rollback

Acceptance requires every #119 criterion, not just successful compilation:
API >= 161 with named commits; patches accounted for; all shaders regenerated;
CI green; desktop/browser evidence; physical tablet lifecycle and ReleaseFast
post-fx evidence; scalar-handle regression protection retained.

1. Review and merge the zbgfx PR; publish a version only when explicitly authorized.
2. Finalize the backend pin to that reviewed revision/version, rerun affected checks
   and have the backend PR reviewed. Link both PRs to #119 without prematurely
   closing the issue on the dependency PR alone.
3. Merge the backend only with passing CI, no material outstanding findings and
   complete device evidence. Close #119 only after all acceptance gates are met.
4. Record release provenance and the known-good previous pin/blobs. If regression
   requires rollback, revert the dependency pin, binding-dependent backend changes
   and shader blobs together; do not mix binary generations.

## Risks and unresolved decisions

- API 161+ is a floor, not evidence that an arbitrary latest revision is compatible.
- Vendor patches and generated bindings can drift independently; review both.
- A compile-only cross-target result does not establish runtime ABI correctness.
- Metal/GL/GLES/Vulkan/WebGL may fail differently; preserve renderer-specific logs.
- Decide native Linux/Windows runners and physical-device availability before
  promising completion. Missing hardware is a validation blocker, not permission
  to silently reduce scope.
- Estimate after the API/patch inventory: the largest uncertainty is validation
  and platform integration, not the dependency-file edit.
