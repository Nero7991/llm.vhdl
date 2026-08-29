#!/usr/bin/env python3
"""tools/verify_mv4i_desc.py -- check tools/gen_mv4i_desc.py against things
that are not tools/gen_mv4i_desc.py.

A generator checked by its own decoder proves nothing.  This project has the m7
mutant on record: a self-consistent packer plus a reversed decoder passed an
entire self-test suite.  So every check below is against an INDEPENDENT code
path, and each one says which:

  --cross    the field values, against ref/mv_fk33_tr's trace for the same
             tensor.  That is C, it reaches the header through
             ref/matvec_int4.c's own mv4i_parse(), and it computes w_beats and
             s_beats with its own arithmetic.  The Python shares no code with
             it.  Covers: the 24+3 sub-region offsets, w_beats, s_beats, the
             16-byte codebook, n_cols, w_exp, out_shift.

  --bytes    the 312-byte image, byte for byte, against tools/mv4i_desc_ref.c
             -- the document's section 7 builder, written out in C.  Covers the
             ENCODING: field packing, bit positions, endianness, the pads.

  --rtl      the image, fed to rtl/matvec_int4_desc_axi.vhd through
             sim/tb_mv4i_desc_image.vhd.  The gateware is the judge.  Covers
             acceptance, and every mutation's error code and ERR_INFO.

  --teeth    the mutation table.  Corrupt one field, confirm the RTL refuses it
             with the documented code -- and, for the mutations the RTL cannot
             see, confirm it ACCEPTS them and say so.  A generator that can
             produce a descriptor the RTL accepts and which computes wrong data
             is worth more as a finding than as a tool.

Run everything:  tools/verify_mv4i_desc.py --all
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import gen_mv4i_desc as G                                    # noqa: E402

MODEL = "/mnt/storage/llama-models/qwen35-9b-mv4i"
MANIFEST = os.path.join(MODEL, "manifest.json")
DEFAULT_TENSOR = os.path.join(MODEL, "blk.11.attn_k.weight.mv4i")

# rtl closure of sim/tb_mv4i_desc_image.vhd, in analysis order.
RTL_FILES = [
    "rtl/util_pkg.vhd", "rtl/async_fifo.vhd", "rtl/axi_rd_fsm.vhd",
    "rtl/stream_fifo.vhd", "rtl/axi_rd_port.vhd", "rtl/act_mem_striped.vhd",
    "rtl/mv4i_arith_pkg.vhd", "rtl/matvec_core.vhd", "rtl/weight_streamer.vhd",
    "rtl/matvec_int4.vhd", "rtl/matvec_int4_desc_pkg.vhd",
    "rtl/matvec_int4_desc_axi.vhd", "sim/tb_mv4i_desc_image.vhd",
]

ACCEPT = -1


def say(ok, what, detail=""):
    print("%-4s %-46s %s" % ("PASS" if ok else "FAIL", what, detail))
    return ok


# --------------------------------------------------------------- --cross
def run_mv_fk33_tr(work, mv4i, rows, x_exp):
    exe = os.path.join(work, "mv_fk33_tr")
    if not os.path.exists(exe):
        cmd = ["cc", "-O2", "-w", "-I", os.path.join(REPO, "ref"),
               "-o", exe, os.path.join(REPO, "ref", "mv_fk33_tr.c"), "-lm"]
        subprocess.check_call(cmd)
    out = os.path.join(work, "tr.txt")
    subprocess.check_call([exe, out, mv4i, str(rows), str(x_exp)], cwd=work)
    tr = dict(WSUB={}, SSUB={}, CB={})
    with open(out) as fp:
        for ln in fp:
            f = ln.split()
            if not f or f[0].startswith("#"):
                continue
            if f[0] == "GEOM":
                tr["GEOM"] = [int(v) for v in f[1:7]]
            elif f[0] == "DIMS":
                tr["DIMS"] = [int(v) for v in f[1:7]]
            elif f[0] == "CB":
                tr["CB"][int(f[1])] = int(f[2])
            elif f[0] == "WSUB":
                tr["WSUB"][int(f[1])] = int(f[2])
            elif f[0] == "SSUB":
                tr["SSUB"][int(f[1])] = int(f[2])
            elif f[0] == "WBEATS":
                tr["WBEATS"] = int(f[1])
            elif f[0] == "SBEATS":
                tr["SBEATS"] = int(f[1])
            elif f[0] == "YEXP":
                tr["YEXP"] = int(f[1])
    return tr


def check_cross(work, mv4i, rows, x_exp):
    print("\n== --cross: field values vs ref/mv_fk33_tr (C, ref/matvec_int4.c "
          "parse) ==")
    tr = run_mv_fk33_tr(work, mv4i, rows, x_exp)
    h = G.Mv4iHeader(mv4i)
    d = G.build_descriptor(h, 0, rows, x_exp)          # file-relative bases
    f = d.fields
    ok = True
    gri, gnpw, gnps, gdw, gblk, ggrp = tr["GEOM"]
    ok &= say([f["rows_if"], f["nsub_w"], f["nsub_s"], f["axi_dw"], f["block"],
               f["grp"]] == [gri, gnpw, gnps, gdw, gblk, ggrp],
              "geometry", "RI=%d NPW=%d NPS=%d DW=%d BLK=%d GRP=%d" % tuple(tr["GEOM"]))
    m, k, nb, osh, wev, xev = tr["DIMS"]
    ok &= say(f["n_rows"] == m and f["n_cols"] == k and f["nb"] == nb,
              "shape", "n_rows=%d n_cols=%d nb=%d" % (m, k, nb))
    ok &= say(f["out_shift"] == osh and f["w_exp"] == wev and f["x_exp"] == xev,
              "numeric", "out_shift=%d w_exp=%d x_exp=%d" % (osh, wev, xev))
    ok &= say(f["codebook"] == [tr["CB"][i] for i in range(16)],
              "codebook, all 16 entries")
    ok &= say(f["w_sub_offset"] == [tr["WSUB"][i] for i in range(gnpw)],
              "weight sub-region offsets", "%d of them" % gnpw)
    ok &= say(f["s_sub_offset"] == [tr["SSUB"][i] for i in range(gnps)],
              "scale sub-region offsets", "%d of them" % gnps)
    ok &= say(f["w_beats"] == tr["WBEATS"],
              "w_beats", "%d" % tr["WBEATS"])
    ok &= say(f["s_beats"] == tr["SBEATS"],
              "s_beats", "%d" % tr["SBEATS"])
    return ok


# --------------------------------------------------------------- --bytes
def build_c_ref(work):
    exe = os.path.join(work, "mv4i_desc_ref")
    if not os.path.exists(exe):
        subprocess.check_call(
            ["cc", "-O2", "-Wall", "-Wextra", "-I", os.path.join(REPO, "ref"),
             "-o", exe, os.path.join(HERE, "mv4i_desc_ref.c")])
    return exe


def check_bytes(work, sweep):
    print("\n== --bytes: 312-byte image vs tools/mv4i_desc_ref.c (spec s7, in "
          "C) ==")
    exe = build_c_ref(work)
    ok = True
    n = 0
    for mv4i, rows, x_exp, base, mode, rstart in sweep:
        h = G.Mv4iHeader(mv4i)
        d = G.build_descriptor(h, base, rows, x_exp, out_mode=mode,
                               row_start=rstart)
        mine = d.hexlines()
        theirs = subprocess.check_output(
            [exe, mv4i, str(rows), str(x_exp), str(base), str(mode),
             str(rstart)]).decode().split()
        n += 1
        if mine != theirs:
            ok = False
            bad = [i for i in range(max(len(mine), len(theirs)))
                   if (mine[i:i + 1] or [None]) != (theirs[i:i + 1] or [None])]
            say(False, "%s rows=%d start=%d"
                % (os.path.basename(mv4i), rows, rstart),
                "words differ: %r" % bad[:8])
    return say(ok, "%d images byte-identical to the C builder" % n)


# ----------------------------------------------------------------- --rtl
def ghdl_prepare(work):
    wd = os.path.join(work, "ghdlwork")
    if os.path.isdir(wd):
        return wd
    os.makedirs(wd)
    for f in RTL_FILES:
        subprocess.check_call(
            ["ghdl", "-a", "--std=08", "-frelaxed", "--workdir=" + wd,
             os.path.join(REPO, f)])
    return wd


RESULT_RE = re.compile(r"RESULT (accept|reject: err_code 0x(\d+) err_info (\d+)"
                       r"|timeout)")


def ghdl_judge(work, wd, hexpath, desc_addr, desc_addr_hi):
    """Run the RTL on one image.  Returns (code, info): code is ACCEPT (-1) for
    accepted, an err_code otherwise, None on timeout."""
    run = os.path.join(work, "run")
    if not os.path.isdir(run):
        os.makedirs(run)
    shutil.copy(hexpath, os.path.join(run, "desc.hex"))
    p = subprocess.run(
        ["ghdl", "-r", "--std=08", "-frelaxed", "--workdir=" + wd,
         "tb_mv4i_desc_image", "-gDESC=desc.hex", "-gEXPECT=-99",
         "-gDESC_ADDR=%d" % desc_addr, "-gDESC_ADDR_HI=%d" % desc_addr_hi,
         "--stop-time=50ms", "--max-stack-alloc=0"],
        cwd=run, capture_output=True, timeout=900)
    txt = (p.stdout + p.stderr).decode(errors="replace")
    m = RESULT_RE.search(txt)
    if not m:
        return None, None, txt
    if m.group(1) == "accept":
        return ACCEPT, None, txt
    if m.group(1) == "timeout":
        return None, None, txt
    return int(m.group(2)), int(m.group(3)), txt


# --------------------------------------------------------------- mutations
def mut_none(w, f):
    pass


def make_mutations(f):
    """(name, mutate, expect_code, expect_info, note, alt).  expect_code ACCEPT
    means the gateware is EXPECTED not to see it; those rows are the honest
    part.

    `alt` is a second outcome that is also accepted, with the reason it exists.
    It carries exactly one row today: at commit a4f7e17 a w_beats inconsistent
    with the shape is UNDETECTABLE and documented as such (spec section 5.1),
    and TRACK A-SHAPE's in-flight edit to rtl/matvec_int4_desc_axi.vhd closes it
    with a new EC_SHAPE = 0xF.  Both were MEASURED here on 2026-08-28.  Listing
    both is not a loosened check: the row still fails on any THIRD outcome, and
    the report says which of the two RTLs it is talking to."""
    e = f["ext0"]
    npw = f["nsub_w"]
    M = []

    def add(name, fn, code, info, note="", alt=None):
        M.append((name, fn, code, info, note, alt))

    add("clean", mut_none, ACCEPT, None, "the real descriptor")

    add("ext_magic off by one",
        lambda w, f: w.__setitem__(e, (w[e] & ~0xFFFFFFFF) | 0x4D563448),
        0xA, e)
    add("ext_version = 2",
        lambda w, f: w.__setitem__(e, (w[e] & ~(0xFFFF << 32)) | (2 << 32)),
        0xB, e)
    add("ext_flags nonzero",
        lambda w, f: w.__setitem__(e, w[e] | (1 << 48)), 0x3, e)
    add("nsub_w = 23 (build has 24)",
        lambda w, f: w.__setitem__(3, (w[3] & ~(0xFFFF << 16)) | (23 << 16)),
        0x9, 3)
    add("nsub_s = 2 (build has 3)",
        lambda w, f: w.__setitem__(3, (w[3] & ~(0xFFFF << 32)) | (2 << 32)),
        0x9, 3)
    add("opcode = 4 (not OP_A_JOB)",
        lambda w, f: w.__setitem__(0, (w[0] & ~0xFF) | 4), 0x3, 0)
    add("word 3 pad byte nonzero",
        lambda w, f: w.__setitem__(3, w[3] | (1 << 56)), 0x3, 3)
    add("word 7 (D reserved) nonzero",
        lambda w, f: w.__setitem__(7, 1), 0x3, 7)
    add("ext word 2 pad half nonzero",
        lambda w, f: w.__setitem__(e + 2, w[e + 2] | (1 << 32)), 0x3, e + 2)
    add("ext word 3 nonzero",
        lambda w, f: w.__setitem__(e + 3, 1), 0x3, e + 2)
    add("out_mode = 3",
        lambda w, f: w.__setitem__(3, (w[3] & ~0xFF) | 3), 0x3, 3)
    add("n_rows = 0",
        lambda w, f: w.__setitem__(1, w[1] & ~0xFFFFFFFF), 0x3, 1)
    add("n_rows = MAXROWS_BFP+1",
        lambda w, f: w.__setitem__(1, (w[1] & ~0xFFFFFFFF) | 17409), 0x3, 1)
    add("n_cols = MAXCOLS+1",
        lambda w, f: w.__setitem__(1, (w[1] & 0xFFFFFFFF) | (17409 << 32)),
        0x3, 1)
    add("w_beats = 0",
        lambda w, f: w.__setitem__(e + 1, w[e + 1] & ~0xFFFFFFFF), 0x3, e + 1)
    add("s_beats = 0",
        lambda w, f: w.__setitem__(e + 1, w[e + 1] & 0xFFFFFFFF), 0x3, e + 1)
    add("w_base[7] misaligned by 64 B",
        lambda w, f: w.__setitem__(8 + 7, w[8 + 7] + 64), 0xC, 8 + 7)
    add("s_base[1] bit at ADDR_W",
        lambda w, f: w.__setitem__(8 + npw + 1, w[8 + npw + 1] | (1 << 40)),
        0xD, 8 + npw + 1)
    add("cb_load clear, none ever loaded",
        lambda w, f: w.__setitem__(0, w[0] & ~(1 << 10)), 0x3, 0)

    # --- the ones the gateware is EXPECTED not to see.
    add("w_base[7] aims at sub-region 8",
        lambda w, f: w.__setitem__(8 + 7, w[8 + 8]), ACCEPT, None,
        "UNDETECTABLE by design; tb_matvec_fk33_desc case 19 MEASURED 4 of 100 "
        "elements wrong")
    add("w_beats halved",
        lambda w, f: w.__setitem__(
            e + 1, (w[e + 1] & ~0xFFFFFFFF) | ((w[e + 1] & 0xFFFFFFFF) // 2)),
        ACCEPT, None,
        "undetectable AT a4f7e17 (spec 5.1); starves the array, "
        "tb_matvec_fk33_desc case 20 MEASURED a hang",
        alt=(0xF, e + 1, "TRACK A-SHAPE's in-flight EC_SHAPE check"))
    add("codebook byte 3 changed",
        lambda w, f: w.__setitem__(5, w[5] ^ (0xFF << 24)), ACCEPT, None,
        "UNDETECTABLE: nothing binds the descriptor's codebook to the file's")
    add("x_exp off by one",
        lambda w, f: w.__setitem__(e + 2, (w[e + 2] + 1) & 0xFFFFFFFF),
        ACCEPT, None,
        "UNDETECTABLE: MEASURED, y_exp 6 -> 7 with identical mantissas, i.e. "
        "every result doubled")
    add("w_exp off by one",
        lambda w, f: w.__setitem__(2, (w[2] & ~0xFFFFFFFF)
                                   | ((w[2] + 1) & 0xFFFFFFFF)),
        ACCEPT, None,
        "UNDETECTABLE: same term of ref/matvec_int4.c:426 as x_exp, so the "
        "same doubling")
    add("every base +4096 (wrong hbm_offset)",
        lambda w, f: [w.__setitem__(8 + i, w[8 + i] + 4096)
                      for i in range(f["nsub_w"] + f["nsub_s"])] and None,
        ACCEPT, None,
        "UNDETECTABLE: still 4 KB aligned and inside ADDR_W; only the weight "
        "store's own hash can see it")
    return M


def check_rtl(work, mv4i, rows, x_exp, desc_addr, teeth=True):
    print("\n== --rtl / --teeth: rtl/matvec_int4_desc_axi.vhd is the judge ==")
    # WHICH RTL.  This bench runs the WORKING TREE, and on 2026-08-28 the
    # working tree carried an uncommitted EC_SHAPE check that HEAD does not.  A
    # mutation table read without knowing which of the two answered it is a
    # table that can be argued with either way.
    try:
        dirty = subprocess.check_output(
            ["git", "status", "--porcelain", "--"] +
            [os.path.join(REPO, f) for f in RTL_FILES],
            cwd=REPO).decode().strip()
        head = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=REPO).decode().strip()
        print("RTL under test: HEAD %s%s"
              % (head, (" PLUS uncommitted edits:\n  " + dirty.replace("\n", "\n  "))
                 if dirty else " (clean working tree)"))
    except Exception as exc:                                  # noqa: BLE001
        print("RTL under test: could not determine (%s)" % exc)
    wd = ghdl_prepare(work)
    h = G.Mv4iHeader(mv4i)
    hbm, entry, _ = G.hbm_base_for(mv4i, MANIFEST)
    clean = G.build_descriptor(h, hbm, rows, x_exp)
    muts = make_mutations(clean.fields) if teeth else make_mutations(clean.fields)[:1]

    ok = True
    silent = []
    for i, (name, fn, code, info, note, alt) in enumerate(muts):
        d = G.build_descriptor(h, hbm, rows, x_exp, mutate=lambda w, f: fn(w, f))
        hp = os.path.join(work, "m%02d.hex" % i)
        with open(hp, "w") as fp:
            for ln in d.hexlines():
                fp.write(ln + "\n")
        got, ginfo, txt = ghdl_judge(work, wd, hp, desc_addr, 0)
        good = (got == code) and (info is None or ginfo == info)
        via = ""
        if not good and alt is not None and got == alt[0] and ginfo == alt[1]:
            good = True
            via = " [via %s]" % alt[2]
        ok &= good
        gs = "accept" if got == ACCEPT else (
            "timeout" if got is None else "0x%X info %s" % (got, ginfo))
        es = "accept" if code == ACCEPT else "0x%X info %s" % (code, info)
        print("%-4s %2d %-38s RTL: %-16s expected %s%s%s"
              % ("PASS" if good else "FAIL", i, name[:38], gs, es, via,
                 ("  -- " + note) if note else ""))
        if got == ACCEPT and i > 0:
            silent.append(name)

    # The two pointer checks, which live outside the image.
    for name, addr, hi, code in (
            ("DESC_PTR misaligned by 8 B", desc_addr + 8, 0, 0xC),
            ("DESC_PTR_HI bit at ADDR_W", desc_addr, 1 << 8, 0xD)):
        hp = os.path.join(work, "m00.hex")
        got, ginfo, txt = ghdl_judge(work, wd, hp, addr, hi)
        good = (got == code and ginfo == G.__dict__.get("EI_PTR", 0xFFFF))
        ok &= good
        print("%-4s %2s %-38s RTL: %-16s expected 0x%X info 65535"
              % ("PASS" if good else "FAIL", "P", name[:38],
                 "0x%X info %s" % (got, ginfo) if got not in (None, ACCEPT)
                 else str(got), code))

    print("\nSILENT PASSES (%d): the gateware accepts these and they are wrong."
          % len(silent))
    for s in silent:
        print("   %s" % s)
    return ok


# ---------------------------------------------------------------- --gate
# sim/tb_matvec_fk33_desc.vhd builds its descriptor in VHDL from the trace's
# GEOM / DIMS / CB / WSUB / SSUB / WBEATS / SBEATS lines.  Rewriting exactly
# those lines from this generator makes the bench build MY field values and
# then prove the answer bit-exact against ref/matvec_int4.c -- which is the one
# route by which the arithmetic bench can be an oracle for a host tool without
# editing it.  The lines it does NOT touch (X, IMG, YMANT, YEXP, SATEV) stay
# ref/mv_fk33_tr's, so the expected answer is not derived from anything here.
GATE_FILES = [
    "rtl/util_pkg.vhd", "rtl/async_fifo.vhd", "rtl/axi_rd_fsm.vhd",
    "rtl/stream_fifo.vhd", "rtl/axi_rd_port.vhd", "rtl/act_mem_striped.vhd",
    "rtl/mv4i_arith_pkg.vhd", "rtl/matvec_core.vhd", "rtl/weight_streamer.vhd",
    "rtl/matvec_int4.vhd", "rtl/matvec_int4_desc_pkg.vhd",
    "rtl/matvec_int4_desc_axi.vhd", "sim/tb_matvec_fk33_desc.vhd",
]

SUBST = ("GEOM", "DIMS", "CB", "WSUB", "SSUB", "WBEATS", "SBEATS")


def check_gate(work, mv4i, rows, x_exp):
    print("\n== --gate: my fields, substituted into sim/tb_matvec_fk33_desc's "
          "trace ==")
    run_mv_fk33_tr(work, mv4i, rows, x_exp)
    src = os.path.join(work, "tr.txt")
    h = G.Mv4iHeader(mv4i)
    f = G.build_descriptor(h, 0, rows, x_exp).fields
    mine = ["GEOM %d %d %d %d %d %d" % (f["rows_if"], f["nsub_w"], f["nsub_s"],
                                        f["axi_dw"], f["block"], f["grp"]),
            "DIMS %d %d %d %d %d %d" % (f["n_rows"], f["n_cols"], f["nb"],
                                        f["out_shift"], f["w_exp"], f["x_exp"])]
    mine += ["CB %d %d" % (i, f["codebook"][i]) for i in range(16)]
    mine += ["WSUB %d %d" % (p, o) for p, o in enumerate(f["w_sub_offset"])]
    mine += ["SSUB %d %d" % (q, o) for q, o in enumerate(f["s_sub_offset"])]
    mine += ["WBEATS %d" % f["w_beats"], "SBEATS %d" % f["s_beats"]]

    orig, kept = [], []
    for ln in open(src):
        t = ln.split()
        if t and t[0] in SUBST:
            orig.append(ln.rstrip("\n"))
        else:
            kept.append(ln.rstrip("\n"))
    dst = os.path.join(work, "tr_mine.txt")
    with open(dst, "w") as fp:
        fp.write("# descriptor-bearing lines REWRITTEN by "
                 "tools/gen_mv4i_desc.py\n")
        for ln in mine:
            fp.write(ln + "\n")
        for ln in kept:
            fp.write(ln + "\n")
    say(sorted(orig) == sorted(mine),
        "%d substituted lines identical to mv_fk33_tr's" % len(mine))

    wd = os.path.join(work, "gatework")
    if not os.path.isdir(wd):
        os.makedirs(wd)
        for g in GATE_FILES:
            subprocess.check_call(
                ["ghdl", "-a", "--std=08", "-frelaxed", "--workdir=" + wd,
                 os.path.join(REPO, g)])
    rd = os.path.join(work, "gaterun")
    if not os.path.isdir(rd):
        os.makedirs(rd)
    shutil.copy(dst, os.path.join(rd, "tr_mine.txt"))
    p = subprocess.run(
        ["ghdl", "-r", "--std=08", "-frelaxed", "--workdir=" + wd,
         "tb_matvec_fk33_desc", "-gTRACE=tr_mine.txt", "--stop-time=200ms",
         "--stop-delta=1000000", "--max-stack-alloc=0"],
        cwd=rd, capture_output=True, timeout=7200)
    txt = (p.stdout + p.stderr).decode(errors="replace")
    with open(os.path.join(work, "gate.log"), "w") as fp:
        fp.write(txt)
    for ln in txt.splitlines():
        if "bit-exact" in ln or "mutation" in ln or "FAIL" in ln:
            print("   %s" % ln.strip()[-160:])
    return say("every checked mutation is refused" in txt,
               "tb_matvec_fk33_desc on my fields",
               "log at %s" % os.path.join(work, "gate.log"))


# ----------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mv4i", default=DEFAULT_TENSOR)
    ap.add_argument("--rows", type=int, default=100)
    ap.add_argument("--x-exp", type=int, default=5)
    ap.add_argument("--desc-addr", type=G.parse_int, default=0x300000)
    ap.add_argument("--work", default=None)
    ap.add_argument("--cross", action="store_true")
    ap.add_argument("--bytes", action="store_true")
    ap.add_argument("--rtl", action="store_true")
    ap.add_argument("--teeth", action="store_true")
    ap.add_argument("--gate", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--sweep", type=int, default=24,
                    help="tensors in the --bytes sweep (0 = all)")
    a = ap.parse_args()
    if a.all:
        a.cross = a.bytes = a.rtl = a.teeth = a.gate = True
    if not (a.cross or a.bytes or a.rtl or a.teeth or a.gate):
        a.cross = a.bytes = True

    work = a.work or tempfile.mkdtemp(prefix="mv4idesc-")
    if not os.path.isdir(work):
        os.makedirs(work)
    print("work dir %s" % work)

    ok = True
    if a.cross:
        ok &= check_cross(work, a.mv4i, a.rows, a.x_exp)
    if a.bytes:
        _, by_file = G.load_manifest(MANIFEST)
        names = sorted(n for n, f in by_file.items() if f.get("kind") == "mv4i")
        if a.sweep:
            step = max(1, len(names) // a.sweep)
            names = names[::step]
        sweep = []
        for n in names:
            p = os.path.join(MODEL, n)
            h = G.Mv4iHeader(p)
            base = int(by_file[n]["hbm_offset"])
            rows = min(h.M, 17408)
            sweep.append((p, rows, 5, base, 0, 0))
            sweep.append((p, min(h.M, h.rows_if), -3, base, 2, 0))
            if h.M >= 2 * h.rows_if:
                sweep.append((p, h.rows_if, 7, base, 1, h.rows_if))
        ok &= check_bytes(work, sweep)
    if a.rtl or a.teeth:
        ok &= check_rtl(work, a.mv4i, a.rows, a.x_exp, a.desc_addr,
                        teeth=a.teeth)
    if a.gate:
        ok &= check_gate(work, a.mv4i, a.rows, a.x_exp)

    print("\n%s" % ("VERIFY: PASS" if ok else "VERIFY: FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
