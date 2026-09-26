"""tools/rate/predict.py -- structural fmax from a MEASURED per-part depth table.
Interpolation is in PERIOD (each level adds delay); nothing is extrapolated silently."""
import json, os
import config

def check(t):
    """Strictly falling with depth, except that depths capped at the same primitive ceiling
    are equal (MEASURED 2026-09-26: VU35P -3 depths 1 and 2 both at FDRE's 1818.2 MHz)."""
    ds = sorted(t["lut"])
    capped = {int(d) for d in t.get("ceiling_limited", [])}
    for a, b in zip(ds, ds[1:]):
        if a in capped and b in capped and t["lut"][b] == t["lut"][a]:
            continue
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
    """Deepest calibrated depth that still meets `mhz`; None when `mhz` is below the slowest
    calibrated depth, because the table then cannot bound the depth at all."""
    deepest = max(t["lut"])
    if mhz < t["lut"][deepest]:
        return None
    ok = [d for d, f in t["lut"].items() if f >= mhz]
    return max(ok) if ok else 0
