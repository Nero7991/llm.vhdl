"""tools/rate/record.py -- parse a rating log and build its committed record.
No ^RATE_DONE, no record: a killed or failed run must never look like a rating."""
import json, os, re
import config

def _need(pat, text, what):
    m = re.search(pat, text, re.M)
    if not m:
        raise SystemExit("rating log has no %s line" % what)
    return m

def parse_log(text):
    _need(r"^RATE_DONE (route|pregate)\s*$", text, "^RATE_DONE")
    out = {}
    m = _need(r"^RATE_SYNTH_LEVELS (\d+) WNS (-?[\d.]+)\s*$", text, "^RATE_SYNTH_LEVELS")
    out["synth"] = {"levels": int(m.group(1)), "wns": float(m.group(2))}
    if re.search(r"^RATE_DONE route\s*$", text, re.M):
        m = _need(r"^RATE_ROUTE WNS (-?[\d.]+) WHS (-?[\d.]+) LEVELS (\d+) UNROUTED (\d+) START (\S+) END (\S+)\s*$",
                  text, "^RATE_ROUTE")
        out["route"] = {"wns": float(m.group(1)), "whs": float(m.group(2)), "levels": int(m.group(3)),
                        "unrouted": int(m.group(4)), "start": m.group(5), "end": m.group(6)}
        if out["route"]["unrouted"]:
            raise SystemExit("rating has %d unrouted nets: not a rating" % out["route"]["unrouted"])
        m = _need(r"^RATE_UTIL LUT (\S+) FF (\S+) BRAM (\S+) URAM (\S+) DSP (\S+)\s*$", text, "^RATE_UTIL")
        out["util"] = dict(zip(("LUT", "FF", "BRAM", "URAM", "DSP"), (float(x) for x in m.groups())))
        out["util"] = {k: int(v) if v == int(v) else v for k, v in out["util"].items()}
    return out

def parse_pulse_width(text):
    req = [float(m.group(1)) for m in re.finditer(r"^Min Period\s+\S+\s+\S+\s+\S+\s+([\d.]+)\s", text, re.M)]
    if not req:
        raise SystemExit("pulse-width report has no Min Period rows")
    return 1000.0 / max(req)

def fmax_mhz(target_ns, wns):
    return 1000.0 / (target_ns - wns)

def path(device, row, model):
    return os.path.join(config.TARGETS, "ratings", device, "%s.%s.json" % (row, model))

def build(row_name, row, device, rating_part, model, key, deps, target_ns, parsed, mem, ceiling=None):
    r = {"row": row_name, "device": device, "part": rating_part, "model": model, "key": key,
         "deps": sorted(deps), "target_ns": target_ns, "tier": row["tier"], "levers": row["levers"],
         "synth": parsed["synth"], "vivado": config.VIVADO_VERSION, "mem": mem,
         "evidence": "MEASURED, one draw; below the routed noise floor (0.4-0.75 ns) differences are not results"}
    if "route" in parsed:
        r["route"], r["util"] = parsed["route"], parsed["util"]
        r["achieved_mhz"] = fmax_mhz(target_ns, parsed["route"]["wns"])
        r["fmax_is_lower_bound"] = parsed["route"]["wns"] > 0.5    # lax target: Vivado stopped early
        r["ceiling_mhz"] = ceiling
    return r
