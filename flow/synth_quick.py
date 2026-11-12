"""python flow/synth_quick.py : generic Yosys synthesis per block -> results/synth.json with cell and flip-flop counts.
Sanity gate from past tapeouts: Yosys silently removes logic that does not reach an output, so the flip-flop count
must match the count the RTL implies. Expected counts are computed here from the parameters."""
import json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
N, AW = 8, 32
# systolic: essential = accumulators + a pipes (not last column) + b pipes (not last row) + a/b skew registers.
# Yosys legitimately drops the unused edge outputs and merges identical valid-delay flops (in_valid delayed by
# 1..2N-2 cycles), so valid flops + the 5-bit drain counter add between 5 and N*N + 2N + 5 on top.
SYS_ESS = N * N * AW + 2 * N * (N - 1) * 8 + 2 * 8 * sum(range(N))
BLOCKS = {
    # name: (top, sources, params, (min, max) flip-flops)
    'zg_pe': ('zg_pe', ['rtl/npu/zg_pe.v'], {'AW': AW}, (8 + 8 + 1 + AW, 8 + 8 + 1 + AW)),
    'zg_systolic': ('zg_systolic', ['rtl/npu/zg_pe.v', 'rtl/npu/zg_systolic.v'], {'N': N, 'AW': AW},
                    (SYS_ESS + 5, SYS_ESS + N * N + 2 * N + 5)),
}

out = {'kind': 'synth_quick', 'blocks': []}
ok = True
for name, (top, srcs, params, exp_ff) in BLOCKS.items():
    chp = ' '.join(f'-set {k} {v}' for k, v in params.items())
    js = ROOT / 'results' / f'stat_{name}.json'
    js.parent.mkdir(exist_ok=True)
    script = f"read_verilog -sv {' '.join(srcs)}; chparam {chp} {top}; synth -flatten -top {top}; tee -q -o {js.as_posix()} stat -json"
    r = subprocess.run(['yosys', '-q', '-p', script], cwd=ROOT, capture_output=True, text=True)
    log = r.stdout + r.stderr
    cells, ff, by_type = None, 0, {}
    if r.returncode == 0 and js.exists():
        txt = js.read_text(); st = json.loads(txt[txt.index('{'):txt.rindex('}') + 1])
        mod = st.get('design') or next(iter(st['modules'].values()))
        cells = mod.get('num_cells')
        by_type = mod.get('num_cells_by_type', {})
        ff = sum(n for t, n in by_type.items() if 'DFF' in t.upper())
    blk = {'block': name, 'ok': r.returncode == 0, 'cells': cells, 'by_type': by_type, 'flipflops': ff,
           'expected_flipflops': list(exp_ff), 'ff_match': exp_ff[0] <= ff <= exp_ff[1], 'log_tail': log[-1500:] if r.returncode else ''}
    ok &= blk['ok'] and blk['ff_match']
    out['blocks'].append(blk)
    print(('OK  ' if blk['ok'] and blk['ff_match'] else 'CHECK'), name, 'cells', blk['cells'], 'FF', ff, 'expected', exp_ff)
(ROOT / 'results').mkdir(exist_ok=True)
(ROOT / 'results' / 'synth.json').write_text(json.dumps(out, indent=1))
sys.exit(0 if ok else 1)
