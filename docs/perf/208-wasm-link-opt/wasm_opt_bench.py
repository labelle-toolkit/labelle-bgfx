"""Time labelle-web's export `wasm-opt <level> --strip-debug` on the link_bench outputs.

Usage: python wasm_opt_bench.py <link-level>:<wasm-opt-level> ...   e.g. O3:O3 O1:O1 O1:O3
Writes results/wasm-opt-<link>-<opt>.json.
"""
import gzip
import json
from pathlib import Path
import subprocess
import sys
import time

import psutil

HERE = Path(__file__).resolve().parent
WASM_OPT = 'C:/Users/User/.labelle/providers/github.com/labelle-toolkit/labelle-web/emsdk/v1/x86_64-windows/4.0.9-3bcf1dcd01f0/upstream/bin/wasm-opt.exe'


def run(link, opt):
    src = HERE / link / 'game.wasm'
    dst = HERE / 'wasm-opt' / f'{link}-{opt}.wasm'
    dst.parent.mkdir(exist_ok=True)
    argv = [WASM_OPT, '-' + opt, '--strip-debug', str(src), '-o', str(dst)]
    started = time.time()
    log = open(HERE / 'wasm-opt' / f'{link}-{opt}.log', 'w')
    proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
    p = psutil.Process(proc.pid)
    peak = 0
    while proc.poll() is None:
        try:
            peak = max(peak, p.memory_info().rss)
        except psutil.NoSuchProcess:
            pass
        time.sleep(0.25)
    log.close()
    out = (HERE / 'wasm-opt' / f'{link}-{opt}.log').read_text(errors='replace')
    result = {'link': link, 'wasm_opt': opt, 'exit': proc.returncode, 'seconds': round(time.time() - started, 2),
              'peak_rss_bytes': peak, 'output_tail': out[-1000:]}
    if proc.returncode == 0:
        data = dst.read_bytes()
        result['wasm_bytes'] = len(data)
        result['wasm_gzip9_bytes'] = len(gzip.compress(data, 9))
    (HERE / 'results' / f'wasm-opt-{link}-{opt}.json').write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k != 'output_tail'}), flush=True)
    return proc.returncode


if __name__ == '__main__':
    sys.exit(max(run(*pair.split(':')) for pair in sys.argv[1:]))
