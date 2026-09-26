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


def set_target(row, t):
    d = json.load(open(BLOCKS))
    d[row]["target_ns"] = round(t, 3)
    with open(BLOCKS, "w") as f:
        json.dump(d, f, indent=2, sort_keys=True)
        f.write("\n")


def rate_one(device, row, model):
    subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "rate.py"),
                    "run", row, "--device", device, "--model", model], check=True)
    return json.load(open(record.path(device, row, model)))


def main(device, model="CALIB"):
    lut = {}
    for d in DEPTHS:
        row = "calib_lut_d%d" % d
        for attempt in range(ATTEMPTS):
            rec = rate_one(device, row, model)
            if not rec["fmax_is_lower_bound"]:
                break
            t = next_target(rec["target_ns"], rec["route"]["wns"])
            print("CALIB_RETARGET %s met %.3f ns (WNS %.3f) -> %.3f ns" % (row, rec["target_ns"], rec["route"]["wns"], t))
            set_target(row, t)
        else:
            raise SystemExit("%s still met its target after %d attempts" % (row, ATTEMPTS))
        lut[d] = rec["achieved_mhz"]
    out = {"device": device, "lut": lut,
           "evidence": "MEASURED, routed, over-constrained (WNS < 0) or ceiling-limited, one draw per depth"}
    predict.check(out)
    os.makedirs(os.path.join(config.TARGETS, "calib"), exist_ok=True)
    with open(os.path.join(config.TARGETS, "calib", "%s.json" % device), "w") as f:
        json.dump(out, f, indent=2, sort_keys=True)
        f.write("\n")
    print("CALIB_DONE", device, lut)


if __name__ == "__main__":
    main(sys.argv[1])
