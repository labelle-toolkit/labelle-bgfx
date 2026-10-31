#!/bin/bash
# Runs while holding D:/prj/labelle-toolkit/epic-528/.heavy-lock (granted).
# 1. single-threaded FP build through the real hook at LABELLE_WASM_LINK_OPT=O1
# 2. relink of the same objects at the default (-O3)
# 3. fallback + threaded smoke on bundles composed from them
# 4. labelle-assembler full test suite
set -u
B=D:/prj/labelle-toolkit/epic-528/link-opt-bench
G=D:/prj/labelle-toolkit/epic-528/fp-link-opt/.labelle/bgfx_wasm
FP=D:/prj/labelle-toolkit/epic-528/fp-link-opt
trap 'rm -rf D:/prj/labelle-toolkit/epic-528/.heavy-lock; echo lock-released' EXIT
export TEMP=$B/tmp TMP=$B/tmp
export ZIG_LOCAL_CACHE_DIR=C:/Users/User/.labelle/zig-local-cache ZIG_GLOBAL_CACHE_DIR=C:/Users/User/.labelle/zig-global-cache
export EMSDK=C:/Users/User/.labelle/providers/github.com/labelle-toolkit/labelle-web/emsdk/v1/x86_64-windows/4.0.9-3bcf1dcd01f0
export EMSDK_PYTHON=$EMSDK/python/3.9.2-nuget_64bit/python.exe
ZIG=C:/Users/User/.zvm/0.16.0/zig.exe
cd "$G"
s=$(date +%s); LABELLE_WASM_LINK_OPT=O1 $ZIG build -Doptimize=ReleaseSafe -j2 --summary all > $B/st-o1-zig.log 2>&1; rc=$?; e=$(date +%s)
echo "st-o1 build rc=$rc seconds=$((e-s))"
[ $rc -eq 0 ] || exit 1
rm -rf $B/st-O1 && cp -r zig-out/web $B/st-O1
s=$(date +%s); $ZIG build -Doptimize=ReleaseSafe -j2 --summary all > $B/st-o3-zig.log 2>&1; rc=$?; e=$(date +%s)
echo "st-default(O3) relink rc=$rc seconds=$((e-s))"
[ $rc -eq 0 ] && rm -rf $B/st-O3 && cp -r zig-out/web $B/st-O3
ls -l $B/st-O1/game.wasm $B/st-O1/game.js $B/st-O3/game.wasm $B/st-O3/game.js 2>&1
# export-equivalent wasm-opt on the fallback runtimes
W=$EMSDK/upstream/bin/wasm-opt.exe
s=$(date +%s); $W -O1 --strip-debug $B/st-O1/game.wasm -o $B/st-O1/game.opt.wasm > $B/st-o1-wasmopt.log 2>&1; echo "st-o1 wasm-opt -O1 rc=$? seconds=$(( $(date +%s)-s ))"
s=$(date +%s); $W -O3 --strip-debug $B/st-O3/game.wasm -o $B/st-O3/game.opt.wasm > $B/st-o3-wasmopt.log 2>&1; echo "st-o3 wasm-opt -O3 rc=$? seconds=$(( $(date +%s)-s ))"
# compose: threaded/ = bench threaded build of the same level, root = this fallback
for v in o1 o3; do
  L=$(echo $v | tr a-z A-Z)
  d=$B/full-$v; rm -rf $d; cp -r $B/dist-$v $d
  if [ -f $B/st-$L/game.opt.wasm ]; then cp $B/st-$L/game.opt.wasm $d/game.wasm; else cp $B/st-$L/game.wasm $d/game.wasm; fi
  cp $B/st-$L/game.js $d/game.js
  # restage the shell so index.html carries the fallback's size
  st=$B/fullstage-$v; rm -rf $st; mkdir -p $st; cp $d/game.wasm $d/game.js $B/O3/game.html $st/
  (cd D:/prj/labelle-toolkit/epic-528/labelle-web && $ZIG build shell -- $st $FP/web > /dev/null 2>&1) && cp $st/index.html $d/index.html
done
export PLAYWRIGHT_BROWSERS_PATH=$B/ms-playwright
cd $FP
for v in o1 o3; do
  for mode in fallback threaded; do
    if [ $mode = fallback ]; then extra="--expect-threads no"; else extra="--isolated --expect-threads yes"; fi
    timeout 8m $B/smoke-venv/Scripts/python.exe tools/web_smoke/smoke.py --bundle $B/full-$v $extra --output $B/fullsmoke-$v-$mode > $B/fullsmoke-$v-$mode.log 2>&1
    echo "smoke $v $mode rc=$?"
  done
done
cd D:/prj/labelle-toolkit/epic-528/labelle-assembler
s=$(date +%s); $ZIG build test -j2 --summary line > $B/asm-test-rerun.log 2>&1; rc=$?
echo "assembler test rc=$rc seconds=$(( $(date +%s)-s ))"; tail -3 $B/asm-test-rerun.log
