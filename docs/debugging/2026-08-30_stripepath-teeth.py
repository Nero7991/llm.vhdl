#!/usr/bin/env python3
"""TRACK STRIPEPATH -- the teeth, with an attribution control.

Twelve mutations of the SHIPPING lane-striped manifest, one tensor at a time,
against four consumers, in three arms:

  NEW  the working tree: this track's five files taught `pieces`.
  OFF  this track's five files at HEAD (TRACK PIECES landed, this one not).
       THIS IS THE ARM THAT ATTRIBUTES.
  PRE  additionally `gen_mv4i_desc.py`, `hbm_map.py`, `fk33_run_job.py` and
       `fk33_load_weights.py` at 263e0ee^, i.e. before PIECES.  Printed, and
       carrying NO attribution: on this manifest its control row dies too.

A mutant is "killed" by a consumer if that consumer exits non-zero or prints a
refusal.  A row that says `-- SURVIVES --` under NEW is reported under its own
name in the write-up: it measures the resolution floor.

REBUILDING THE ARMS.  Each is a directory of symlinks to the repo with a few
files overridden, so nothing is copied and nothing can be written back:

    SP=/mnt/storage/track-stripepath
    for A in off pre nomap noext; do
      mkdir -p $SP/$A/tools $SP/$A/hw/fk33/host $SP/$A/ref $SP/$A/rtl \
               $SP/$A/server $SP/$A/sim
      for f in tools/* hw/fk33/host/* ref/* rtl/* server/*; do
        ln -sf /home/orencollaco/GitHub/llama.vhdl/$f $SP/$A/$(dirname $f)/
      done
      ln -sf /home/orencollaco/GitHub/llama.vhdl/sim/seq_tbl_pkg.vhd $SP/$A/sim/
    done
    # off:  this track's five files at 3a2d0d0
    # pre:  off, plus gen_mv4i_desc/hbm_map/fk33_run_job/fk33_load_weights
    #       at 263e0ee^
    # nomap: the working tree with gen_lmhead_windows's HM.plan().check() cut
    # noext: the working tree with check_byte_cover's extent rule cut
    # (unlink the target first, then `git show <rev>:<path> > ...`)

The `-- SURVIVES --` cells under NEW and NOMAP are the control; if the CONTROL
row is killed in a column, that column carries NO attribution and must not be
read as one.  That is why OFF and PRE are printed but not credited."""
import json
import os
import shutil
import subprocess
import sys

SP = "/mnt/storage/track-stripepath"
SRC = "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped"
MUT = os.path.join(SP, "mut")
TARGET = os.environ.get("SP_TARGET", "blk.0.ffn_gate.weight.mv4i")
SEG = (8 << 30) // 32

ARMS = {"NEW": "/home/orencollaco/GitHub/llama.vhdl",
        "NOMAP": os.path.join(SP, "nomap"),
        "OFF": os.path.join(SP, "off"),
        "PRE": os.path.join(SP, "pre")}


def link_model():
    if not os.path.isdir(MUT):
        os.makedirs(MUT)
    for n in os.listdir(SRC):
        if n == "manifest.json":
            continue
        d = os.path.join(MUT, n)
        if not os.path.islink(d):
            os.symlink(os.path.join(SRC, n), d)


def load():
    return json.load(open(os.path.join(SRC, "manifest.json")))


def ent(m, name=TARGET):
    for f in m["files"]:
        if f["file"] == name:
            return f
    raise KeyError(name)


# --------------------------------------------------------------- mutations
def m_control(m):
    return "the striped manifest, untouched"


def t1(m):
    e = ent(m); e["pieces"][3]["hbm_offset"] += SEG
    e["pieces"][3]["segment"] = e["pieces"][3]["hbm_offset"] // SEG
    return "one weight piece moved a whole 256 MiB segment up (label kept true)"


def t2(m):
    ent(m)["pieces"][3]["hbm_offset"] += 1
    return "one weight piece misaligned by 1 byte"


def t3(m):
    e = ent(m); e["pieces"][4]["hbm_offset"] = e["pieces"][3]["hbm_offset"]
    e["pieces"][4]["segment"] = e["pieces"][3]["segment"]
    return "two pieces of one tensor given the SAME address"


def t4(m):
    e = ent(m); e["pieces"][3]["segment"] = (e["pieces"][3]["segment"] + 1) % 32
    return "a piece's segment LABEL changed, address untouched"


def t5(m):
    e = ent(m)
    p = e["pieces"][3]
    p["hbm_offset"] = (p["hbm_offset"] // SEG) * SEG + SEG - 0x2000 - p["nbytes"]
    return "a piece moved INSIDE its own segment (NOT expected to bite)"


def t6(m):
    e = ent(m)
    e["pieces"][3]["nbytes"] -= 4096
    return "one piece 4096 B short, the file is no longer tiled"


def t7(m):
    e = ent(m); del e["pieces"][3]
    return "one weight piece deleted from the list"


def t8(m):
    e = ent(m)
    e["pieces"][3]["file_offset"] += 4096
    e["pieces"][3]["nbytes"] -= 4096
    e["pieces"][2]["nbytes"] += 4096
    return "a piece cut 4 KB off the header's own 0x38 table (still tiles)"


def t9(m):
    e = ent(m)
    p = e["pieces"][3]
    p["hbm_offset"] = (4 << 30) - p["nbytes"] // 2
    p["segment"] = p["hbm_offset"] // SEG
    return "a piece straddling the 4 GiB HBM STACK boundary"


def t10(m):
    e = ent(m); e["hbm_offset"] = e["pieces"][5]["hbm_offset"]
    return "object hbm_offset points at piece 5, not the header"


def t11(m):
    e = ent(m); e["pieces"][3]["nbytes"] *= 2
    return "one piece's nbytes doubled"


def t12(m):
    e = ent(m)
    seg0 = e["pieces"][1]["hbm_offset"] // SEG
    a = seg0 * SEG + 0x100000
    for p in e["pieces"][1:]:
        p["hbm_offset"] = a
        p["segment"] = a // SEG
        a += p["nbytes"]
    return "ALL 27 lanes of one tensor put back into ONE pseudo-channel"


MUTANTS = [("control", m_control), ("T1", t1), ("T2", t2), ("T3", t3),
           ("T4", t4), ("T5", t5), ("T6", t6), ("T7", t7), ("T8", t8),
           ("T9", t9), ("T10", t10), ("T11", t11), ("T12", t12)]


# --------------------------------------------------------------- consumers
def run(cmd, env=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    p = subprocess.run(cmd, capture_output=True, text=True, env=e)
    return p.returncode, (p.stdout + p.stderr)


def c_glp(repo, man):
    rc, out = run([sys.executable, os.path.join(repo, "tools",
                                                "gen_layer_program.py"),
                   "--manifest", man, "--token", "--x-exp", "-6", "--print"])
    if rc != 0:
        return True
    return "refused" in out and "0 refused" not in out


def c_lmhead(repo, man):
    rc, out = run([sys.executable, os.path.join(repo, "tools",
                                                "gen_lmhead_windows.py"),
                   "--mv4i", os.path.join(MUT, "output.weight.mv4i"),
                   "--manifest", man, "--x-exp", "-6"])
    return rc != 0


def c_stack(repo, man):
    rc, _ = run([sys.executable, os.path.join(repo, "tools",
                                              "check_hbm_stack.py"), MUT,
                 "--manifest", man])
    return rc != 0


def c_runlayer(repo, man):
    rc, _ = run([sys.executable, os.path.join(SP, "rl_desc_dump.py"), man,
                 os.path.join(SP, "scratch", "teeth_rl.json")],
                env=dict(SP_REPO=repo))
    return rc != 0


CONS = [("glp", c_glp), ("lmhead", c_lmhead), ("stack", c_stack),
        ("runlayer", c_runlayer)]


def main():
    link_model()
    mpath = os.path.join(MUT, "manifest.json")
    print("teeth over %s/manifest.json" % SRC)
    m0 = load()
    print("  format   %r" % m0.get("format"))
    print("  objects  %d, striped %d, target %s"
          % (len(m0["files"]),
             sum(1 for f in m0["files"] if f.get("pieces")), TARGET))
    print()
    print("%-7s %-52s %-26s %-26s %-26s %s"
          % ("mutant", "what it does", "killed by (NEW)",
             "NOMAP (attribution)", "OFF (attribution)",
             "PRE (none)"))
    for name, fn in MUTANTS:
        m = load()
        what = fn(m)
        with open(mpath, "w") as fp:
            json.dump(m, fp)
        cells = []
        for arm in ("NEW", "NOMAP", "OFF", "PRE"):
            hits = [cn for cn, cf in CONS if cf(ARMS[arm], mpath)]
            cells.append(",".join(hits) if hits else "-- SURVIVES --")
        print("%-7s %-52s %-26s %-26s %-26s %s"
              % (name, what[:52], cells[0], cells[1], cells[2], cells[3]))
    os.remove(mpath)
    return 0


if __name__ == "__main__":
    sys.exit(main())
