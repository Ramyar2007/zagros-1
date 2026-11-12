"""python tb/run.py [suite ...] : build + run cocotb suites with Verilator (in CI). Writes results/<suite>/results.xml,
results/<suite>/dump.fst (waves) and results/summary.json (what the WAFER app reads)."""
import json, os, sys, time, glob, shutil
import xml.etree.ElementTree as ET
from pathlib import Path
from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / 'rtl'

SUITES = {
    # name: (toplevel, test module dir, test module, sources, parameters)
    'pe':       ('zg_pe',       'tb/npu', 'test_pe',       ['npu/zg_pe.v'], {}),
    'systolic': ('zg_systolic', 'tb/npu', 'test_systolic', ['npu/zg_pe.v', 'npu/zg_systolic.v'], {'N': 8, 'AW': 32}),
    'npu':      ('zg_npu',      'tb/npu', 'test_npu',      ['npu/zg_pe.v', 'npu/zg_systolic.v', 'npu/zg_npu.v'], {}),
    'core':     ('zg_core',     'tb/core', 'test_core',    ['core/zg_rvc.v', 'core/zg_fetch.v', 'core/zg_div.v', 'core/zg_core.v'], {}),
}


def run_suite(name):
    top, tdir, mod, srcs, params = SUITES[name]
    out = ROOT / 'results' / name
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    runner = get_runner('verilator')
    t0 = time.time()
    runner.build(sources=[RTL / s for s in srcs], hdl_toplevel=top, parameters=params, waves=True,
                 build_dir=out / 'build', build_args=['--trace-fst', '--trace-structs', '-Wno-fatal'], always=True)
    xml = out / 'results.xml'
    runner.test(hdl_toplevel=top, test_module=mod, test_dir=ROOT / tdir, waves=True, build_dir=out / 'build',
                results_xml=str(xml), extra_env={'PYTHONPATH': str(ROOT / tdir)})
    for f in glob.glob(str(out / 'build' / '*.fst')) + glob.glob(str(ROOT / tdir / '*.fst')) + glob.glob(str(ROOT / '*.fst')):
        shutil.move(f, out / 'dump.fst')
    shutil.rmtree(out / 'build', ignore_errors=True)   # keep artifacts small: results + waves only
    tests = []
    for tc in ET.parse(xml).getroot().iter('testcase'):
        fail = tc.find('failure') is not None or tc.find('error') is not None
        msg = ''
        for tag in ('failure', 'error'):
            e = tc.find(tag)
            if e is not None:
                msg = (e.get('message') or e.text or '')[:500]
        tests.append({'name': tc.get('name'), 'passed': not fail, 'time_s': float(tc.get('time') or 0),
                      'sim_ns': float(tc.get('sim_time_ns') or tc.get('sim_time') or 0), 'message': msg})
    return {'suite': name, 'toplevel': top, 'passed': all(t['passed'] for t in tests) and len(tests) > 0,
            'tests': tests, 'wall_s': round(time.time() - t0, 1),
            'waves': f'results/{name}/dump.fst' if (out / 'dump.fst').exists() else None}


if __name__ == '__main__':
    names = sys.argv[1:] or list(SUITES)
    summary = {'design': 'zagros-1', 'kind': 'sim', 'sha': os.environ.get('GITHUB_SHA', ''), 'suites': []}
    for n in names:
        try:
            summary['suites'].append(run_suite(n))
        except Exception as e:  # build errors etc. are results too
            summary['suites'].append({'suite': n, 'passed': False, 'tests': [], 'error': str(e)[:2000]})
    summary['passed'] = all(s['passed'] for s in summary['suites'])
    (ROOT / 'results').mkdir(exist_ok=True)
    (ROOT / 'results' / 'summary.json').write_text(json.dumps(summary, indent=1))
    for s in summary['suites']:
        print(('PASS' if s['passed'] else 'FAIL'), s['suite'], f"{sum(t['passed'] for t in s['tests'])}/{len(s['tests'])}", s.get('error', '')[:300])
    sys.exit(0 if summary['passed'] else 1)
