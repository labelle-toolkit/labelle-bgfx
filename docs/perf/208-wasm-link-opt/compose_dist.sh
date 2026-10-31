#!/bin/bash
# compose_dist.sh <variant-name> <game.wasm> <game.js>
# Builds dist-<variant>/ the way labelle-web 0.4 + tools/ci/prepare-web-dist.sh
# lay out a threaded bundle: shell staged by labelle-web's `shell` tool, the
# threaded runtime in threaded/ with its marker, FP's manifest/icons/intro/
# music. Only the THREADED build is real: the root runtime is the same
# threaded pair as a placeholder, because no single-threaded fallback archives
# exist for this commit (see the PR). Smoke it only with --isolated
# --expect-threads yes.
set -euo pipefail
B=D:/prj/labelle-toolkit/epic-528/link-opt-bench
FP=D:/prj/labelle-toolkit/epic-528/fp-link-opt
WEB=D:/prj/labelle-toolkit/epic-528/labelle-web
name=$1; wasm=$2; js=$3
stage=$B/stage-$name
dist=$B/dist-$name
rm -rf "$stage" "$dist"
mkdir -p "$stage"
cp "$wasm" "$stage/game.wasm"
cp "$js" "$stage/game.js"
cp "$B/O3/game.html" "$stage/game.html"
(cd "$WEB" && zig build shell -- "$stage" "$FP/web")
cp -r "$stage" "$dist"
mkdir -p "$dist/threaded"
cp "$stage/game.js" "$stage/game.wasm" "$dist/threaded/"
printf '{"labelle_threads":1}\n' > "$dist/threaded/labelle-threads.json"
cp "$FP/web/manifest.json" "$dist/"
mkdir -p "$dist/icons" "$dist/assets/music"
cp "$FP"/web/icons/*.png "$dist/icons/"
cp "$FP/assets/intro.mp4" "$dist/assets/intro.mp4"
cp "$FP"/assets/music/*.mp3 "$dist/assets/music/"
if grep -q '__WASM_BYTES__' "$dist/index.html"; then echo "placeholder not stamped" >&2; exit 1; fi
echo "composed $dist"
