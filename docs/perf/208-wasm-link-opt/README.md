# #208: emcc -O1 vs -O3 on identical Flying Platform archives

Local Windows run, 2026-10-30, emsdk 4.0.9 (the labelle-web managed one), one
heavy job at a time. Flying Platform `efc8b1a`, threaded ReleaseSafe build.
The six archives emcc links (`libgame.a`, bgfx/bx/bimg, the imgui bridge and
cimgui) were compiled once and copied aside (`inputs.sha256`), so every level
links byte-identical objects. Only the `-O` flag differs; the rest of the
argv is what `emLinkStep` passes for a threaded ReleaseSafe link
(`-sASSERTIONS=1`, WebGL2, memory growth, 512 KiB stack, `-pthread
-sPTHREAD_POOL_SIZE=4 -sINITIAL_MEMORY=67108864`).

| | emcc link | peak RSS | game.wasm | gzip -9 | game.js |
|---|---:|---:|---:|---:|---:|
| `-O3` (production) | 194.8 s | 617 MB | 35,954,722 | 5,705,063 | 251,256 |
| `-O2` | 21.7 s | 402 MB | 36,040,602 | 5,693,473 | 251,256 |
| `-O1` | 7.8 s* | 92 MB | 37,033,628 | 5,760,621 | 420,476 |

\* First run after copying the inputs; the evidence run of the same command
took 2.05 s.

labelle-web's export `wasm-opt <level> --strip-debug`:

| link | wasm-opt | time | game.wasm | gzip -9 |
|---|---|---:|---:|---:|
| `-O1` | `-O1` (this change) | 4.1 s | 36,363,847 | 5,700,089 |
| `-O1` | `-O3` (labelle-web 0.4.0) | 211.9 s | 36,210,118 | 5,706,920 |
| `-O2`/`-O3` | same level | fails in 0.5 s (validation) | - | - |

At `-O2`/`-O3` emcc drops the target-features section, and `wasm-opt`
without feature flags rejects the threads/bulk-memory/nontrapping ops, so the
best-effort pass is skipped and production exports ship emcc's output. That
is pre-existing and unchanged here. With a `-O1` link the section survives,
so the old fixed `-O3` would run and add 212 s, which is why the export now
follows the link level.

Chromium smoke (`tools/web_smoke/smoke.py --isolated --expect-threads yes`,
headless shell 156, SwiftShader), two runs each, all passed with no errors:

| | main menu active | game started | welcome after game |
|---|---:|---:|---:|
| `-O1` link + wasm-opt `-O1` | 3.31 s / 1.47 s | 5.75 s / 4.27 s | 13.5 s / 11.1 s |
| `-O3` link | 1.33 s / 1.33 s | 3.95 s / 4.03 s | 13.3 s / 13.3 s |

The first `-O1` run was the first browser launch after install (cold disk
cache). The second is within noise of `-O3`.

## Through the real hook: single-threaded build and both bundle variants

`locked_run.sh` ran a single-threaded generation of the same FP commit
(`providers/web.json` `"threads": false`, local override to this branch, so
the staged `backend.hook.zig` is this PR's) with `zig build
-Doptimize=ReleaseSafe -j2` in `.labelle/bgfx_wasm`:

| | step | time |
|---|---|---:|
| `LABELLE_WASM_LINK_OPT=O1` | `compile lib game` (8 GiB MaxRSS), then emcc | 3 min, then **8 s** emcc (319 s total) |
| unset (default) on the same tree | game cached, only emcc reruns | **2 min** emcc (170 s total) |

Single-threaded outputs: `-O1` game.wasm 36,925,191 (after export wasm-opt
`-O1` (3 s): 36,139,334) vs default `-O3` 35,880,746 (wasm-opt `-O3` fails
validation as above). `results/hook-build/` has the zig build summaries.

The bundles were then composed with the fallback at the root and the threaded
build of the same level in `threaded/`, and smoked in both modes. All four
runs **passed**, with no errors:

| | mode | main menu | game started | welcome after game | wasm memory | workers |
|---|---|---:|---:|---:|---:|---:|
| `-O1` | fallback (`--expect-threads no`) | 3.22 s | 5.70 s | 13.4 s | 122,683,392 | 0 |
| `-O1` | threaded (`--isolated`) | 1.33 s | 3.97 s | 13.4 s | 200,474,624 | 3 |
| `-O3` | fallback | 1.17 s | 3.59 s | 13.4 s | 122,683,392 | 0 |
| `-O3` | threaded | 1.36 s | 4.08 s | 13.3 s | 200,474,624 | 3 |

The first run of each sequence (here the `-O1` fallback) is consistently
slower, so read that 3.22 s as a cold browser start, not a link-level effect.

## Not measured

- Frame time and memory during gameplay, save/load, audio and settings. The
  smoke covers startup through the guided opening only (wasm heap size at
  that point is identical between levels).
- A `labelle bundle` run end to end. The fallback above comes from a
  `"threads": false` generation, not from `-Dwasm_threads=false` on a threaded
  one, and the export step was reproduced by `compose_dist.sh`/`wasm-opt`.

## Files

- `link_bench.py <level>...`: links `inputs/` at each level, writes
  `results/<level>.json`.
- `wasm_opt_bench.py <link>:<opt>...`: runs the export's wasm-opt step.
- `compose_dist.sh <name> <wasm> <js>`: lays out a bundle like labelle-web
  0.4 plus `tools/ci/prepare-web-dist.sh` for the smoke.
- `results/`: raw JSON, and `smoke/` with each run's `result.json` and
  `console.json`.

Paths in the scripts are the machine's; adjust `EMSDK`, the FP checkout and
the inputs directory to rerun.
