"""python flow/harden/summarize.py RUN_DIR OUT_JSON : pull the sign-off numbers out of a LibreLane run (area, cells,
utilisation, worst setup/hold slack over all corners, DRC/LVS/antenna counts, power) into one small JSON for the app."""
import json, sys, glob, os
run, out = sys.argv[1], sys.argv[2]
m = {}
for p in [os.path.join(run, 'final', 'metrics.json')] + glob.glob(os.path.join(run, 'final', '*.json')):
    if os.path.exists(p) and p.endswith('metrics.json'):
        m = json.load(open(p)); break
def g(*keys):
    for k in keys:
        if k in m: return m[k]
    return None
pick = lambda pre: {k: v for k, v in m.items() if k.startswith(pre)}
s = {
  'design': os.path.basename(run.rstrip('/')),
  'die_area_um2': g('design__die__area'), 'core_area_um2': g('design__core__area'),
  'instances': g('design__instance__count'), 'stdcell_area_um2': g('design__instance__area__stdcell', 'design__instance__area'),
  'utilization': g('design__instance__utilization'),
  'setup_ws_ns': g('timing__setup__ws'), 'hold_ws_ns': g('timing__hold__ws'),
  'setup_violations': g('timing__setup_vio__count'), 'hold_violations': g('timing__hold_vio__count'),
  'max_slew_violations': g('design__max_slew_violation__count'), 'max_cap_violations': g('design__max_cap_violation__count'),
  'drc_errors': g('route__drc_errors', 'magic__drc_error__count', 'klayout__drc_error__count'),
  'lvs_errors': g('design__lvs_error__count'), 'antenna_violations': g('route__antenna_violation__count', 'antenna__violating__nets'),
  'power_total_w': g('power__total'), 'wire_length_um': g('route__wirelength'),
  'corners_setup_ws': {k.split('__corner:')[1]: v for k, v in pick('timing__setup__ws__corner:').items()},
  'corners_hold_ws': {k.split('__corner:')[1]: v for k, v in pick('timing__hold__ws__corner:').items()},
}
json.dump({'summary': s, 'metrics': m}, open(out, 'w'), indent=1)
print(json.dumps(s, indent=1))
