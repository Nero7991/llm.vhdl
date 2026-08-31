#!/usr/bin/env python3
"""closure_audit.py -- TRACK GAIN16, 2026-08-31.

THE INVARIANT SEVEN BROKEN CONSUMERS ACROSS FOUR TRACKS WOULD ALL HAVE FAILED.

A script that carries its own `FILES="..."` list of VHDL sources is asserting a
DEPENDENCY CLOSURE.  Nothing checks that assertion, `sim/regress.sh` computes
its own closure and stays green while every private copy rots, and the rot is
silent until somebody runs the script.

The check is pure text and needs no simulator: for every `X.vhd` named in a
list, every `entity work.Y` that X.vhd instantiates must ALSO be in that list.
That is the whole invariant.  It runs in under a second.

NO HARDWARE.  Reads text files.

usage: closure_audit.py [repo-root]
"""
import os, re, sys

FILES_RE = re.compile(r'^FILES="(.*?)"', re.S | re.M)
INST_RE  = re.compile(r'\bentity\s+work\.([A-Za-z_]\w*)', re.I)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    # where a given entity's source lives
    home = {}
    for d in ("rtl", "sim", "tb"):
        p = os.path.join(root, d)
        if not os.path.isdir(p):
            continue
        for f in os.listdir(p):
            if f.endswith(".vhd"):
                home.setdefault(f[:-4], os.path.join(d, f))

    scripts = []
    for d in ("sim", "tools", "tools/ref9b", "hw/fk33"):
        p = os.path.join(root, d)
        if not os.path.isdir(p):
            continue
        for f in sorted(os.listdir(p)):
            if f.endswith(".sh"):
                scripts.append(os.path.join(d, f))

    bad = 0
    checked = 0
    for s in scripts:
        try:
            txt = open(os.path.join(root, s)).read()
        except Exception:
            continue
        m = FILES_RE.search(txt)
        if not m:
            continue
        listed = [x for x in m.group(1).split() if x.endswith(".vhd")]
        if not listed:
            continue
        checked += 1
        have = set(os.path.basename(x)[:-4] for x in listed)
        missing = []
        for rel in listed:
            fp = os.path.join(root, rel)
            if not os.path.exists(fp):
                continue
            for inst in set(INST_RE.findall(open(fp).read())):
                if inst not in have and inst in home:
                    missing.append((rel, inst, home[inst]))
        if missing:
            bad += 1
            print("BROKEN  %s" % s)
            for rel, inst, src in sorted(set(missing)):
                print("          %s instantiates work.%s -- %s is NOT in the list"
                      % (rel, inst, src))
        else:
            print("ok      %s  (%d files)" % (s, len(listed)))
    print()
    print("CLOSURE_AUDIT checked=%d broken=%d" % (checked, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
