#!/usr/bin/env python3
"""sim/mutate_rows.py -- anchored source mutants against one GHDL bench.

    python3 sim/mutate_rows.py sim/mutants/<unit>.json

The JSON names the bench (`tb`), its analysis closure in order (`deps`), committed vector
files to link into the run directory (`vectors`), extra run arguments (`generics`), a
`stop_time`, and `rows`. Each row patches ONE anchor (`old` must occur exactly once in
`file`) in a scratch copy, analyzes the closure into a fresh directory and runs the bench.
PASS = exit 0 and the line `(report note): PASS: <tb> checks=`; anything else is KILLED.
A row whose anchor does not match once, or whose patched file does not analyze, is BADMUT.
Row Z0 (no patch) must PASS. Prints `MUTROW <tag> <expect> <got> <why>` per row and ends
`MUTANTS_OK <n>` when every row got what it expected, `MUTANTS_FAIL <n bad>` otherwise.
Scratch: a new directory per run under /mnt/storage/fk33_builds/scratch; nothing is deleted.
"""
import json, os, re, subprocess, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GHDL = os.environ.get("GHDL", "ghdl")
ROOT = os.environ.get("MUTATE_ROOT", "/mnt/storage/fk33_builds/scratch")


def run_row(cfg, row, base):
    d = os.path.join(base, row["tag"])
    work, run = os.path.join(d, "work"), os.path.join(d, "run")
    os.makedirs(work)
    os.makedirs(run)
    for v in cfg.get("vectors", []):
        os.symlink(os.path.join(REPO, v), os.path.join(run, os.path.basename(v)))
    files = []
    if row.get("file") and row["file"] not in cfg["deps"]:
        return "BADMUT(file not in deps)"
    for f in cfg["deps"]:
        src = os.path.join(REPO, f)
        if row.get("file") == f:
            s = open(src).read()
            n = s.count(row["old"])
            if n != 1:
                return "BADMUT(anchor x%d)" % n
            src = os.path.join(d, os.path.basename(f))
            open(src, "w").write(s.replace(row["old"], row["new"]))
        files.append(src)
    with open(os.path.join(d, "log"), "w") as log:
        for f in files:
            r = subprocess.run([GHDL, "-a", "--std=08", "-frelaxed", "--workdir=" + work, f],
                               stdout=log, stderr=subprocess.STDOUT)
            if r.returncode != 0:
                return "BADMUT(analysis)" if row.get("file") else "DID_NOT_ANALYZE"
        cmd = ([GHDL, "-r", "--std=08", "-frelaxed", "--workdir=" + work, cfg["tb"]]
               + cfg.get("generics", []) + ["--max-stack-alloc=0",
                                            "--stop-time=" + cfg.get("stop_time", "100ms")])
        try:
            r = subprocess.run(cmd, cwd=run, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=cfg.get("timeout_s", 1800))
            out, rc = r.stdout.decode(errors="replace"), r.returncode
        except subprocess.TimeoutExpired:
            out, rc = "TIMEOUT\n", -1
        log.write(out)
    ok = rc == 0 and re.search(r"\(report note\): PASS: %s checks=" % re.escape(cfg["tb"]), out)
    return "PASS" if ok else "KILLED"


def main(argv):
    cfg = json.load(open(argv[1]))
    base = os.path.join(ROOT, "mutate_%s_%s_%d" % (cfg["tb"], time.strftime("%Y%m%d_%H%M%S"), os.getpid()))
    os.makedirs(base)
    print("MUTATE_ROOT %s" % base)
    bad, z0 = 0, False
    for row in cfg["rows"]:
        got = run_row(cfg, row, base)
        if row["tag"] == "Z0":
            z0 = got == "PASS"
        good = got == row["expect"]
        bad += 0 if good else 1
        print("MUTROW %s %s %s %s" % (row["tag"], row["expect"], got, row.get("why", "control")), flush=True)
    if not z0:
        bad += 1
        print("MUTROW Z0 missing or not PASS: no kill above means anything")
    print(("MUTANTS_OK %d" % len(cfg["rows"])) if bad == 0 else ("MUTANTS_FAIL %d" % bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
