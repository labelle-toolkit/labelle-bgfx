"""Link the same FP archives with emcc at several -O levels (labelle-bgfx#208).

Usage: python link_bench.py <level> [<level> ...]   e.g. O3 O1 O2

The emcc command is the one emLinkStep builds for a threaded ReleaseSafe
Flying Platform link (captured in link-o1-command.json), with only the -O
flag changed. Inputs are copies of the compiled archives (inputs/,
inputs.sha256), so every level links byte-identical objects. Writes
<level>/game.{html,js,wasm} and results/<level>.json (wall seconds, peak
working set of the emcc process tree, output sizes).
"""
import gzip
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import psutil

HERE = Path(__file__).resolve().parent
EMSDK = 'C:/Users/User/.labelle/providers/github.com/labelle-toolkit/labelle-web/emsdk/v1/x86_64-windows/4.0.9-3bcf1dcd01f0'
PYTHON = EMSDK + '/python/3.9.2-nuget_64bit/python.exe'
EMCC = EMSDK + '/upstream/emscripten/emcc.py'
ARCHIVES = ['35c1d57c-libgame.a', '08b28c25-libbgfx_imgui_bridge.a', '95eb90b1-libbgfx.a',
            'f17b93ba-libcimgui_clib.a', '995ba660-libbx.a', 'e21e13e0-libbimg.a']
# emLinkStep order for ReleaseSafe + threads: -sASSERTIONS=1 <-O> webgl/memory, pthread args.
ARGS = ['-sASSERTIONS=1', None, '-sMIN_WEBGL_VERSION=2', '-sMAX_WEBGL_VERSION=2',
        '-sGL_ENABLE_GET_PROC_ADDRESS=1', '-sALLOW_MEMORY_GROWTH=1', '-sSTACK_SIZE=524288',
        '-pthread', '-sPTHREAD_POOL_SIZE=4', '-sINITIAL_MEMORY=67108864']


def run(level):
    out = HERE / level
    out.mkdir(exist_ok=True)
    tmp = HERE / 'tmp'
    tmp.mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update({'EMSDK': EMSDK, 'EMSDK_PYTHON': PYTHON, 'EM_CONFIG': EMSDK + '/.emscripten',
                'TEMP': str(tmp), 'TMP': str(tmp)})
    argv = [PYTHON, '-E', EMCC] + [('-' + level) if a is None else a for a in ARGS]
    argv += [str(HERE / 'inputs' / a) for a in ARCHIVES] + ['-o', str(out / 'game.html')]
    started = time.time()
    proc = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
    root = psutil.Process(proc.pid)
    peak_sum = 0
    peak_single = 0
    while proc.poll() is None:
        try:
            tree = [root] + root.children(recursive=True)
        except psutil.NoSuchProcess:
            tree = []
        total = 0
        for p in tree:
            try:
                rss = p.memory_info().rss
                total += rss
                peak_single = max(peak_single, rss)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
        peak_sum = max(peak_sum, total)
        time.sleep(0.25)
    output = proc.stdout.read()
    seconds = time.time() - started
    result = {'level': level, 'exit': proc.returncode, 'seconds': round(seconds, 2),
              'peak_tree_rss_bytes': peak_sum, 'peak_process_rss_bytes': peak_single, 'argv': argv,
              'emcc_output_tail': output[-2000:]}
    if proc.returncode == 0:
        for name in ('game.wasm', 'game.js'):
            data = (out / name).read_bytes()
            result[name + '_bytes'] = len(data)
            result[name + '_gzip9_bytes'] = len(gzip.compress(data, 9))
    (HERE / 'results').mkdir(exist_ok=True)
    (HERE / 'results' / (level + '.json')).write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k not in ('argv', 'emcc_output_tail')}), flush=True)
    return proc.returncode


if __name__ == '__main__':
    sys.exit(max(run(level) for level in sys.argv[1:]))
