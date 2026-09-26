"""tools/rate/manifest.py -- the block manifest. Every lever EXPLICIT (build 19: a
dropped patch turned four levers on silently)."""
import json, os
import config

PATH = os.path.join(config.TARGETS, "blocks.json")
LEVERS = os.path.join(config.TARGETS, "levers.json")
TIERS = ("stream", "core", "calib", "anchor")   # calib and anchor rows never gate a build
KEYS = ("top", "tier", "clocks", "generics", "levers", "extra_files", "target_ns")

def validate(d, levers):
    for name, r in d.items():
        miss = [k for k in KEYS if k not in r]
        if miss:
            raise SystemExit("blocks.json %s: missing %s" % (name, ", ".join(miss)))
        if r["tier"] not in TIERS:
            raise SystemExit("blocks.json %s: tier %r not in %s" % (name, r["tier"], TIERS))
        if isinstance(r["target_ns"], dict) and "default" not in r["target_ns"]:
            raise SystemExit("blocks.json %s: a target_ns map needs a \"default\" entry" % name)
        if not r["clocks"]:
            raise SystemExit("blocks.json %s: no clock port named" % name)
        for lv in r["levers"]:
            if lv not in levers:
                raise SystemExit("blocks.json %s: lever %s is not in levers.json" % (name, lv))
            if levers[lv]["top"] != r["top"]:
                raise SystemExit("blocks.json %s: lever %s is declared by %s, not %s"
                                 % (name, lv, levers[lv]["top"], r["top"]))
            if lv not in r["generics"]:
                raise SystemExit("blocks.json %s: lever %s must be set explicitly in generics" % (name, lv))
        for lv, info in levers.items():
            if info["top"] == r["top"] and lv not in r["levers"]:
                raise SystemExit("blocks.json %s: its top %s declares lever %s; the row must list it "
                                 "and set it explicitly" % (name, r["top"], lv))

def target_for(row, device):
    """A row's target on `device`: target_ns is a number (every device) or a map with a
    "default" entry, so tuning one device's constraint cannot re-key another's ratings."""
    t = row["target_ns"]
    if isinstance(t, dict):
        return float(t.get(device, t["default"]))
    return float(t)

def load_levers(path=None):
    with open(path or LEVERS) as f:
        return json.load(f)

def load(path=None, levers_path=None):
    with open(path or PATH) as f:
        d = json.load(f)
    validate(d, load_levers(levers_path))
    return d

def row(name, path=None):
    d = load(path)
    if name not in d:
        raise SystemExit("no manifest row %r" % name)
    return d[name]
