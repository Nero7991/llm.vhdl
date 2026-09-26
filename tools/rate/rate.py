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

def current_key(row_name, row, part, target_ns, tree=config.REPO):
    """(key, shell text, GHDL order, probe shell path) for `row` on `part` against `tree`."""
    text = shell.gen_shell(row, entity_text(tree, row))
    declared = {n for (n, _, _) in shell.parse_entity(entity_text(tree, row), row["top"])["generics"]}
    extra_g = sorted(set(row["generics"]) - declared)
    if extra_g:
        # gen_shell would drop them silently and rate the block at its defaults (a renamed
        # lever would be rated ON while the manifest says off).
        raise SystemExit("row %s sets generic(s) %s that %s does not declare"
                         % (row_name, ", ".join(extra_g), row["top"]))
    # A private probe per call: status/ratestale and a lane rating the same row run
    # concurrently, and a shared GHDL work library is shared mutable state.
    import tempfile
    base = os.path.join(config.WORK_ROOT, row_name, part, "_probe")
    os.makedirs(base, exist_ok=True)
    probe = tempfile.mkdtemp(prefix="p%d_" % os.getpid(), dir=base)
    sp0 = os.path.join(probe, "rate_shell.vhd"); open(sp0, "w").write(text)
    extra = [os.path.join(tree, p) for p in row["extra_files"]]
    import shutil
    try:
        order = deps.elab_order(tree, "rate_shell", extra + [sp0], os.path.join(probe, "ghdl"))
    finally:
        shutil.rmtree(probe)       # callers use sp0 only as a name; cmd_run writes its own copy
    k = key.rating_key(tree, [p for p in order if p != sp0], text, row, part, target_ns, HARNESS)
    return k, text, order, sp0

def cmd_run(a):
    row = manifest.row(a.row)
    dev = devices.row(a.device)
    part = dev["rating_part"] if a.part_kind == "rating" else dev["build_part"]
    tree = os.path.abspath(a.tree)
    if a.lane == "bc250" and tree != os.path.abspath(config.REPO):
        raise SystemExit("REFUSED: --lane bc250 rates the repo tree only; only the repo is synced")
    mem = a.mem or ("11G" if a.lane == "bc250" else "24G")
    tns = manifest.target_for(row, a.device)
    k, text, order, sp0 = current_key(a.row, row, part, tns, tree)
    wd = os.path.join(config.WORK_ROOT, a.row, part, k[:12])
    os.makedirs(wd, exist_ok=True)
    sp = os.path.join(wd, "rate_shell.vhd"); open(sp, "w").write(text)
    fl = os.path.join(wd, "files.txt")
    open(fl, "w").write("\n".join((p if os.path.isabs(p) else os.path.join(tree, p)).replace(sp0, sp)
                                  for p in order) + "\n")
    runner = vivado.run_batch_bc250 if a.lane == "bc250" else vivado.run_batch
    out = runner(HARNESS[0], [part, wd, str(tns), ",".join(row["clocks"]), fl, a.mode],
                 wd, mem, "rate-%s" % a.row)
    parsed = record.parse_log(out["log"])
    ceiling = None
    if a.mode == "route":
        ceiling = record.parse_pulse_width(open(os.path.join(wd, "pulse_width.rpt")).read())
    rec = record.build(a.row, row, a.device, part, a.model, k, [p for p in order if p != sp0],
                       tns, parsed, {"peak": out["mem_peak"], "swap_peak": out["swap_peak"],
                                                  "cap": mem, "lane": a.lane}, ceiling)
    if a.mode == "pregate":
        print("RATE_PREGATE %s %s levels %d" % (a.row, part, parsed["synth"]["levels"]))
        return
    dst = record.path(a.device if a.part_kind == "rating" else a.device + "_build", a.row, a.model)
    if a.record_dir:           # tree-calibration ratings (k) never overwrite current-tree ratings
        dst = os.path.join(a.record_dir, "%s.%s.json" % (a.row, a.model))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    json.dump(rec, open(dst, "w"), indent=2, sort_keys=True)
    print("RATE_RECORD %s achieved %.1f MHz ceiling %.1f MHz -> %s" % (a.row, rec["achieved_mhz"], ceiling, dst))

def lever_gate(levers_set, lever_table, proving=()):
    for name, val in levers_set.items():
        if val == "true" and lever_table[name]["silicon"] != "proven" and name not in proving:
            raise SystemExit("PREFLIGHT_REFUSED lever %s is on but not silicon-proven (%s)"
                             % (name, lever_table[name]["evidence"]))

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
            k = current_key(rname, row, dev["rating_part"], manifest.target_for(row, dname))[0]
            for rp in recs:
                rec = json.load(open(rp))
                st = "FRESH" if rec["key"] == k else "STALE"
                n[st] += 1
                print("RATESTATUS %s %s %s %s" % (dname, rname, rec["model"], st))
    print("RATESTALE_SUMMARY fresh %d stale %d unrated %d" % (n["FRESH"], n["STALE"], n["UNRATED"]))
    if a.check and n["STALE"]:
        sys.exit(1)

def rows_for(rows, levers):
    """The rows a build with these lever values contains: a row with levers is included only
    when every lever it lists has that value; a lever the build does not name refuses."""
    out = {}
    for rname, row in rows.items():
        miss = [lv for lv in row["levers"] if lv not in levers]
        if miss:
            raise SystemExit("PREFLIGHT_REFUSED the build does not name lever(s) %s (row %s)"
                             % (", ".join(miss), rname))
        if all(row["generics"][lv] == levers[lv] for lv in row["levers"]):
            out[rname] = row
    return out

def parse_levers(text, table):
    """NAME=true|false,...; an unknown name or any other value refuses (a misspelt value
    would otherwise silently drop that lever's rows from rows_for)."""
    out = {}
    for x in (t for t in text.split(",") if t):
        name, _, val = x.partition("=")
        if name not in table:
            raise SystemExit("PREFLIGHT_REFUSED unknown lever %s (levers.json)" % name)
        if val not in ("true", "false"):
            raise SystemExit("PREFLIGHT_REFUSED lever %s=%s: the value must be true or false" % (name, val))
        out[name] = val
    return out

def tree_records(device, model, tier, tree, rdir, levers):
    """FRESH records of `tier` rated on `tree`, from `rdir`; a stale or missing one refuses."""
    rows = rows_for(manifest.load(), levers); dev = devices.row(device); out, bad = [], []
    for rname, row in sorted(rows.items()):
        if row["tier"] != tier:
            continue
        k = current_key(rname, row, dev["rating_part"], manifest.target_for(row, device), tree)[0]
        # A rating made on this tree, or failing that the current-tree rating when its key is
        # the same: the key covers every file the block reads, so an equal key is the same job.
        cands = [os.path.join(rdir, "%s.%s.json" % (rname, model)), record.path(device, rname, model)]
        recs = [json.load(open(p)) for p in cands if os.path.exists(p)]
        hit = [r for r in recs if r["key"] == k]
        if not hit:
            bad.append(rname + (" stale" if recs else " unrated")); continue
        out.append(hit[0])
    if bad:
        raise SystemExit("k: tier %s on %s is not fully rated: %s" % (tier, tree, ", ".join(bad)))
    return out

def cmd_k(a):
    import tiers
    tree = os.path.abspath(a.tree)
    rdir = os.path.join(config.TARGETS, "ratings", a.device, "tree_build%s" % a.build)
    recs = tree_records(a.device, a.model, a.tier, tree, rdir, parse_levers(a.levers, manifest.load_levers()))
    mhz, row = tiers.tier_min(recs, a.tier)
    k = tiers.k_from_build(a.card_period, a.card_wns, mhz)
    k.update({"build": a.build, "clb_util": a.clb_util, "levers": a.levers, "tier_min_row": row, "tier_min_mhz": mhz,
              "card_clock": a.card_clock, "card_period_ns": a.card_period, "card_wns": a.card_wns})
    kp = os.path.join(config.TARGETS, "k", "%s.json" % a.device)
    kf = json.load(open(kp)) if os.path.exists(kp) else {}
    kf.setdefault(a.tier, [])
    kf[a.tier] = [e for e in kf[a.tier] if e["build"] != a.build] + [k]
    os.makedirs(os.path.dirname(kp), exist_ok=True)
    with open(kp, "w") as f:
        json.dump(kf, f, indent=2, sort_keys=True); f.write("\n")
    print("RATE_K %s %s build %s k %.4f%s (card %.1f MHz / %s %.1f MHz)" % (
        a.device, a.tier, a.build, k["k"], " LOWER-BOUND" if k["lower_bound"] else "",
        1000.0 / (a.card_period - a.card_wns), row, mhz))

def cmd_preflight(a):
    import glob, math, predict, tiers
    lv = parse_levers(a.levers, manifest.load_levers())
    rows = rows_for(manifest.load(), lv); dev = devices.row(a.device)
    bad, recs = [], []
    for rname, row in sorted(rows.items()):
        if row["tier"] in ("calib", "anchor"):
            continue
        rp = record.path(a.device, rname, a.model)
        if not os.path.exists(rp):
            bad.append(rname + " unrated"); continue
        rec = json.load(open(rp))
        if rec["key"] != current_key(rname, row, dev["rating_part"], manifest.target_for(row, a.device))[0]:
            bad.append(rname + " stale"); continue
        recs.append(rec)
    if bad:
        raise SystemExit("PREFLIGHT_REFUSED stale/unrated: " + ", ".join(bad))
    kp = os.path.join(config.TARGETS, "k", "%s.json" % a.device)
    try:
        pred = tiers.predict(recs, json.load(open(kp)) if os.path.exists(kp) else {})
    except SystemExit as e:
        raise SystemExit("PREFLIGHT_REFUSED %s" % e)
    table = predict.load_table(a.device)
    for rec in recs:
        lim = predict.max_levels(pred[rec["tier"]], table)
        if lim is None:
            print("PREFLIGHT_DEPTH_UNBOUNDED %s: %.1f MHz is below the deepest calibrated depth"
                  % (rec["row"], pred[rec["tier"]]))
        elif rec["synth"]["levels"] > lim:
            raise SystemExit("PREFLIGHT_REFUSED %s has %d synthesised levels; %.1f MHz allows %d"
                             % (rec["row"], rec["synth"]["levels"], pred[rec["tier"]], lim))
    lever_gate(lv, manifest.load_levers(), tuple(a.proving))
    print("PREFLIGHT_OK %s %s %s" % (a.device, a.model, " ".join("%s=%.1f" % t for t in sorted(pred.items()))))
    print("FK33_ENG_CORE_MHZ=%d" % math.floor(pred["core"]))
    if "stream" in pred:
        print("FK33_ENG_FAST_MHZ=%d" % math.floor(pred["stream"]))

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("row"); r.add_argument("--device", required=True); r.add_argument("--model", required=True)
    r.add_argument("--mode", choices=("route", "pregate"), default="route")
    r.add_argument("--tree", default=config.REPO); r.add_argument("--mem", default=None)
    r.add_argument("--lane", choices=("local", "bc250"), default="local")
    r.add_argument("--record-dir", default=None)
    kk = sub.add_parser("k")
    for x in ("--device", "--model", "--tier", "--build", "--tree", "--card-clock"):
        kk.add_argument(x, required=True)
    kk.add_argument("--card-period", type=float, required=True)
    kk.add_argument("--card-wns", type=float, required=True)
    kk.add_argument("--clb-util", type=float, default=None)
    kk.add_argument("--levers", required=True)
    pf = sub.add_parser("preflight")
    pf.add_argument("--device", required=True); pf.add_argument("--model", required=True)
    pf.add_argument("--levers", default=""); pf.add_argument("--proving", action="append", default=[])
    r.add_argument("--part-kind", choices=("rating", "build"), default="rating")
    st = sub.add_parser("status"); st.add_argument("--check", action="store_true")
    a = ap.parse_args()
    {"run": cmd_run, "status": cmd_status, "k": cmd_k, "preflight": cmd_preflight}[a.cmd](a)

if __name__ == "__main__":
    main()
