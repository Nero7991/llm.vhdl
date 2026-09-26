#!/usr/bin/env python3
"""Rate calib_lut at DEPTH 1,2,3,4,6,8,10,12 on a device and write hw/targets/calib/<device>.json.

Every depth must be OVER-CONSTRAINED (WNS < 0) or limited by the primitive ceiling: a met
target is a lower bound, because Vivado stops optimising once timing is met (MEASURED
2026-09-25: depth 3 met 1.5 ns at 765 MHz, then 1017 MHz at 1.11 ns). A met depth is
retargeted to 85% of its achieved period and re-run, at most ATTEMPTS times."""
import json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config, record, predict

DEPTHS = (1, 2, 3, 4, 6, 8, 10, 12)
ATTEMPTS = 3
BLOCKS = os.path.join(config.TARGETS, "blocks.json")


def next_target(target_ns, wns):
    if wns < 0:
        raise ValueError("run did not meet its target; no retarget needed")
    return 0.85 * (target_ns - wns)


def set_target(row, t, device, path=None):
    """Set `row`'s target on `device` only (manifest.target_for resolves it). Serialised by an
    flock and written by os.replace, because two lanes retarget concurrently and rate.py reads
    the file meanwhile (a torn read and a lost update are both MEASURED without this)."""
    import fcntl
    path = path or BLOCKS
    with open(path + ".lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        d = json.load(open(path))
        cur = d[row]["target_ns"]
        if not isinstance(cur, dict):
            cur = {"default": cur}
        cur[device] = round(t, 3)
        d[row]["target_ns"] = cur
        tmp = path + ".tmp%d" % os.getpid()
        with open(tmp, "w") as f:
            json.dump(d, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp, path)


def rate_one(device, row, model, lane="local"):
    subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "rate.py"),
                    "run", row, "--device", device, "--model", model, "--lane", lane], check=True)
    return json.load(open(record.path(device, row, model)))


def write_table(device, recs):
    """The calibration table from one final record per depth."""
    out = {"device": device, "lut": {d: r["achieved_mhz"] for d, r in recs.items()},
           "ceiling_limited": sorted(d for d, r in recs.items() if r["limited_by"] == "ceiling"),
           "evidence": "MEASURED, routed, over-constrained (WNS < 0) or ceiling-limited, one draw per depth"}
    predict.check(out)
    os.makedirs(os.path.join(config.TARGETS, "calib"), exist_ok=True)
    with open(os.path.join(config.TARGETS, "calib", "%s.json" % device), "w") as f:
        json.dump(out, f, indent=2, sort_keys=True)
        f.write("\n")
    print("CALIB_DONE", device, out["lut"])


def table_only(device, model="CALIB"):
    """Rebuild the table from the committed records, refusing a stale or lower-bound one."""
    import rate, manifest, devices
    recs = {}
    for d in DEPTHS:
        row = "calib_lut_d%d" % d
        r = json.load(open(record.path(device, row, model)))
        mr = manifest.row(row)
        k = rate.current_key(row, mr, devices.row(device)["rating_part"], manifest.target_for(mr, device))[0]
        if r["key"] != k or r["fmax_is_lower_bound"]:
            raise SystemExit("%s on %s is stale or a lower bound: re-run calib" % (row, device))
        recs[d] = r
    write_table(device, recs)


def main(device, model="CALIB", lane="local"):
    recs = {}
    for d in DEPTHS:
        row = "calib_lut_d%d" % d
        for attempt in range(ATTEMPTS):
            rec = rate_one(device, row, model, lane)
            if not rec["fmax_is_lower_bound"]:
                break
            t = next_target(rec["target_ns"], rec["route"]["wns"])
            print("CALIB_RETARGET %s met %.3f ns (WNS %.3f) -> %.3f ns" % (row, rec["target_ns"], rec["route"]["wns"], t))
            set_target(row, t, device)
        else:
            raise SystemExit("%s still met its target after %d attempts" % (row, ATTEMPTS))
        recs[d] = rec
    write_table(device, recs)

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "--table-only":
        table_only(sys.argv[1])
    else:
        main(sys.argv[1], lane=sys.argv[2] if len(sys.argv) > 2 else "local")
