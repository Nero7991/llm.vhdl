#!/usr/bin/env python3
"""tools/rate/rate.py -- rate a manifest row on a device.  See docs/superpowers/specs/2026-09-25-block-ratings-design.md"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config, devices, manifest, deps, key, shell, record, vivado

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = [os.path.join(HERE, "rate_block.tcl"), os.path.join(HERE, "shell.py")]

def entity_text(tree, row):
    cands = [os.path.join(tree, p) for p in row["extra_files"]] + \
            [os.path.join(tree, d, row["top"] + ".vhd") for d in config.RTL_DIRS]
    for p in cands:
        if os.path.exists(p) and ("entity %s is" % row["top"]) in open(p).read().lower():
            return open(p).read()
    raise SystemExit("cannot find the file declaring entity %s" % row["top"])

def current_key(row_name, row, part, tree=config.REPO):
    """(key, shell text, GHDL order, probe shell path) for `row` on `part` against `tree`."""
    text = shell.gen_shell(row, entity_text(tree, row))
    probe = os.path.join(config.WORK_ROOT, row_name, part, "_probe")
    os.makedirs(probe, exist_ok=True)
    sp0 = os.path.join(probe, "rate_shell.vhd"); open(sp0, "w").write(text)
    extra = [os.path.join(tree, p) for p in row["extra_files"]]
    order = deps.elab_order(tree, "rate_shell", extra + [sp0], os.path.join(probe, "ghdl"))
    k = key.rating_key(tree, [p for p in order if p != sp0], text, row, part, row["target_ns"], HARNESS)
    return k, text, order, sp0

def cmd_run(a):
    row = manifest.row(a.row)
    dev = devices.row(a.device)
    part = dev["rating_part"] if a.part_kind == "rating" else dev["build_part"]
    tree = os.path.abspath(a.tree)
    k, text, order, sp0 = current_key(a.row, row, part, tree)
    wd = os.path.join(config.WORK_ROOT, a.row, part, k[:12])
    os.makedirs(wd, exist_ok=True)
    sp = os.path.join(wd, "rate_shell.vhd"); open(sp, "w").write(text)
    fl = os.path.join(wd, "files.txt")
    open(fl, "w").write("\n".join((p if os.path.isabs(p) else os.path.join(tree, p)).replace(sp0, sp)
                                  for p in order) + "\n")
    out = vivado.run_batch(HARNESS[0], [part, wd, str(row["target_ns"]), ",".join(row["clocks"]), fl, a.mode],
                           wd, a.mem, "rate-%s" % a.row)
    parsed = record.parse_log(out["log"])
    ceiling = None
    if a.mode == "route":
        ceiling = record.parse_pulse_width(open(os.path.join(wd, "pulse_width.rpt")).read())
    rec = record.build(a.row, row, a.device, part, a.model, k, [p for p in order if p != sp0],
                       row["target_ns"], parsed, {"peak": out["mem_peak"], "swap_peak": out["swap_peak"],
                                                  "cap": a.mem}, ceiling)
    if a.mode == "pregate":
        print("RATE_PREGATE %s %s levels %d" % (a.row, part, parsed["synth"]["levels"]))
        return
    dst = record.path(a.device if a.part_kind == "rating" else a.device + "_build", a.row, a.model)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    json.dump(rec, open(dst, "w"), indent=2, sort_keys=True)
    print("RATE_RECORD %s achieved %.1f MHz ceiling %.1f MHz -> %s" % (a.row, rec["achieved_mhz"], ceiling, dst))

def cmd_status(a):
    """Records under <device>_build/ are sign-off-part evidence, not current ratings: not checked."""
    import glob
    rows = manifest.load(); devs = devices.load()
    n = {"FRESH": 0, "STALE": 0, "UNRATED": 0}
    for dname, dev in sorted(devs.items()):
        for rname, row in sorted(rows.items()):
            recs = sorted(glob.glob(record.path(dname, rname, "*")))
            if not recs:
                n["UNRATED"] += 1
                print("RATESTATUS %s %s - UNRATED" % (dname, rname))
                continue
            k = current_key(rname, row, dev["rating_part"])[0]
            for rp in recs:
                rec = json.load(open(rp))
                st = "FRESH" if rec["key"] == k else "STALE"
                n[st] += 1
                print("RATESTATUS %s %s %s %s" % (dname, rname, rec["model"], st))
    print("RATESTALE_SUMMARY fresh %d stale %d unrated %d" % (n["FRESH"], n["STALE"], n["UNRATED"]))
    if a.check and n["STALE"]:
        sys.exit(1)

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("row"); r.add_argument("--device", required=True); r.add_argument("--model", required=True)
    r.add_argument("--mode", choices=("route", "pregate"), default="route")
    r.add_argument("--tree", default=config.REPO); r.add_argument("--mem", default="24G")
    r.add_argument("--part-kind", choices=("rating", "build"), default="rating")
    st = sub.add_parser("status"); st.add_argument("--check", action="store_true")
    a = ap.parse_args()
    {"run": cmd_run, "status": cmd_status}[a.cmd](a)

if __name__ == "__main__":
    main()
