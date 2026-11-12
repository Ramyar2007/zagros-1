"""python flow/lint.py : verilator --lint-only -Wall on every top module; writes results/lint.json. Fails on errors, reports warnings."""
import json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOPS = {
    'zg_pe': ['rtl/npu/zg_pe.v'],
    'zg_systolic': ['rtl/npu/zg_pe.v', 'rtl/npu/zg_systolic.v'],
    'zg_npu': ['rtl/npu/zg_pe.v', 'rtl/npu/zg_systolic.v', 'rtl/npu/zg_npu.v'],
    'zg_core': ['rtl/core/zg_rvc.v', 'rtl/core/zg_fetch.v', 'rtl/core/zg_div.v', 'rtl/core/zg_core.v'],
    'zg_soc': ['rtl/core/zg_rvc.v', 'rtl/core/zg_fetch.v', 'rtl/core/zg_div.v', 'rtl/core/zg_core.v', 'rtl/npu/zg_pe.v',
               'rtl/npu/zg_systolic.v', 'rtl/npu/zg_npu.v', 'rtl/soc/zg_sram.v', 'rtl/soc/zg_periph.v', 'rtl/soc/zg_soc.v'],
}

out = {'kind': 'lint', 'modules': []}
ok = True
for top, srcs in TOPS.items():
    r = subprocess.run(['verilator', '--lint-only', '-Wall', '--top-module', top, *srcs], cwd=ROOT, capture_output=True, text=True)
    lines = [l for l in r.stderr.splitlines() if l.startswith('%')]
    errs = [l for l in lines if l.startswith('%Error')]
    warns = [l for l in lines if l.startswith('%Warning')]
    ok &= not errs
    out['modules'].append({'top': top, 'errors': errs, 'warnings': warns, 'clean': not errs and not warns})
    print(('OK  ' if not errs else 'ERR '), top, f'{len(errs)} errors, {len(warns)} warnings')
    for l in errs + warns:
        print('   ', l)
(ROOT / 'results').mkdir(exist_ok=True)
(ROOT / 'results' / 'lint.json').write_text(json.dumps(out, indent=1))
sys.exit(0 if ok else 1)
