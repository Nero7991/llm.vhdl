"""tools/rate/predict.py -- structural fmax from a MEASURED per-part depth table.
Interpolation is in PERIOD (each level adds delay); nothing is extrapolated silently."""
import json, os
import config

def check(t):
    ds = sorted(t["lut"])
    for a, b in zip(ds, ds[1:]):
        if t["lut"][b] >= t["lut"][a]:
            raise SystemExit("calibration table is not monotone at depth %d -> %d" % (a, b))

def load_table(device):
    with open(os.path.join(config.TARGETS, "calib", "%s.json" % device)) as f:
        t = json.load(f)
    t["lut"] = {int(k): float(v) for k, v in t["lut"].items()}
    check(t)
    return t

def structural_mhz(levels, t):
    lut = t["lut"]; ds = sorted(lut)
    if levels in lut:
        return lut[levels], "measured"
    if levels < ds[0] or levels > ds[-1]:
        near = ds[0] if levels < ds[0] else ds[-1]
        return lut[near], "beyond-calibration"
    lo = max(d for d in ds if d < levels); hi = min(d for d in ds if d > levels)
    p = 1000/lut[lo] + (1000/lut[hi] - 1000/lut[lo]) * (levels - lo) / (hi - lo)
    return 1000.0 / p, "measured"

def max_levels(mhz, t):
    ok = [d for d, f in t["lut"].items() if f >= mhz]
    return max(ok) if ok else 0
