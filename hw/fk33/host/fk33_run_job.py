#!/usr/bin/env python3
"""fk33_run_job.py -- run ONE subsystem-A matvec on the card and compare the
result, element by element, against ref/matvec_int4.c.

    fk33_run_job.py plan      --mv4i F.mv4i [--rows N] ...     no card, no /dev
    fk33_run_job.py selfcheck                                  no card, no model
    fk33_run_job.py run       --mv4i F.mv4i [--rows N] ...     THE CARD
    fk33_run_job.py run       --dry-run ...                    no card, no /dev

WHY THIS EXISTS
---------------
Backlog row N1.  As of 2026-08-29 the FK33 design routes, a timing-clean
bitstream is loaded, 4.49 GB of 9B weights are resident in HBM and verified
against a digest the loader did not produce -- and nothing had ever checked
what any of it COMPUTES, because no tool in this repository could start an
operation on the card.  MEASURED by TRACK BOARDAUDIT: the engine's register map
is at ENG_CTL_BASE = 0x00012000 and `grep -rn '0x12000\\|ENG_CTL' hw/fk33/host/
server/ tools/` returned nothing.  This is the tool that starts a job.

WHAT WAS ALREADY THERE, AND IS NOT REWRITTEN HERE
-------------------------------------------------
The descriptor bytes were NOT the gap.  Two things existed and both are used
verbatim rather than re-derived, because a third implementation of either would
be a third thing to keep in step:

  tools/gen_mv4i_desc.py   builds the 312-byte descriptor for one packed tensor
                           and computes every base TWICE, by the file's own
                           offset table and by spec 6.5a's layout rule, and
                           refuses to emit if the two disagree.
  ref/mv_fk33_tr.c         reads the SAME .mv4i and emits the activation vector
                           and the expected y mantissas, y_exp and sat_event
                           from mv4i_matvec() -- the oracle sim/tb_matvec_fk33
                           already passes against.

The gap was the register-level start/status path, and that is what this file
adds.

THE DELIVERABLE IS A NUMBER, NOT A STATUS BIT
---------------------------------------------
A job that finishes is not a job that computed.  The verdict here is a per-row
comparison of Y_LO/Y_HI against the oracle's YMANT plus Y_EXP against YEXP, and
the summary line states its own COVERAGE -- how many rows were read and how many
were compared -- because a checker that skips an object can still print PASS
(measured in this repository on 2026-08-29: 250 objects in, 249 checked, PASS).

THE ORACLE IS NOT A ROUND TRIP.  ref/mv_fk33_tr reaches the weight bytes
through get_widx()/get_scale() in C on the host; the card reaches them through
27 AXI masters into HBM.  Nothing is compared against itself.  The one place a
round trip DOES appear is the descriptor read-back after the DMA write, and it
is labelled as such: it proves the DMA moved bytes, not that the bytes are
right.

WHAT THIS TOOL CANNOT SEE
-------------------------
A base that is well-formed but aimed at the WRONG sub-region.  Nothing in the
descriptor says what a sub-region should contain, so the card computes a wrong
answer and reports success (spec 5.1; sim/tb_matvec_fk33_desc case 19).  Here
that is covered on the HOST side only, by gen_mv4i_desc.py's two-rule base
agreement, and it is covered before the descriptor is ever written.

OPEN ISSUE THERM-255 -- READ THIS BEFORE BELIEVING ANY RESULT
--------------------------------------------------------------
docs/debugging/2026-08-29_thermal-guard-255-trips.md: the thermal trip counter
was cleared and read back 255 (the SATURATING maximum) fourteen hours later --
roughly one trip every three minutes -- with every temperature cool and
trip_cause = 0.  What was set is the HBM-copies-disagree CDC sticky.  EACH TRIP
HALTS THE COMPUTE DOMAIN, and rtl/fk33_engine.vhd masks CTRL bit 0 while the
halt is high.

So this tool reads the trip counter and the CDC sticky IMMEDIATELY BEFORE and
IMMEDIATELY AFTER the job, and if either moved it reports INCONCLUSIVE.  It
will not print PASS or FAIL across a trip, because a stall or a wrong answer
with a non-zero trip count is not evidence about subsystem A.

That write-up's own measurement trap is worth repeating: twelve consecutive
clean five-second samples proved nothing at a three-minute mean interval.  A
quiet window is not evidence of absence.  Note also that the trips were seen on
fk33_pcieep_therm.bit and the engine build is a DIFFERENT bitstream, so whether
the same guard behaves this way here is itself unmeasured.

TRANSPORTS
----------
  --dry-run    a simulated register plane plus a file-backed HBM.  Opens
               nothing under /dev.  It proves this tool runs end to end and
               that its checks bite when mutated.  IT PROVES NOTHING ABOUT THE
               CARD: the simulated engine replays the oracle, so a dry-run PASS
               is a statement about the plumbing and is printed as such.
  (default)    /dev/xdma0_user for MMIO and /dev/xdma0_{h2c,c2h}_0 for HBM.
               Override with FK33_USER / FK33_H2C / FK33_C2H, which is the same
               escape hatch fk33_load_weights.py uses.

NO AGENT MAY RUN THE DEFAULT PATH.  The hardware boundary in CLAUDE.md is
absolute and this tool does not weaken it: an agent writes and exercises it
through `plan`, `selfcheck` and `run --dry-run`, and the run against the card
belongs to whoever is at the bench.
"""

import argparse
import json
import os
import re
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
REGS_H = os.path.join(HERE, "fk33_regs.h")

sys.path.insert(0, os.path.join(REPO, "tools"))

DEFAULT_MANIFEST = "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json"


class RunError(Exception):
    pass


# --------------------------------------------------------------- the reg map
def load_regs(path=REGS_H):
    """Scrape hw/fk33/host/fk33_regs.h.

    NOT a second copy of the map.  That header is GENERATED by
    hw/fk33/gen_fk33_regs.py from gen_pcieep.py (which configures the block
    design), gen_fk33_engine.py (which generates the RTL) and
    rtl/matvec_int4_desc_pkg.vhd.  Scraping it is what makes those the source
    for this tool too; typing the numbers here would recreate exactly the
    divergence that header exists to prevent, and `gen_fk33_regs.py --check`
    would not see it.

    A missing name RAISES.  There is no default: a host that guesses a register
    address reads a plausible value from the wrong peripheral."""
    if not os.path.exists(path):
        raise RunError("%s does not exist.  Regenerate it with\n"
                       "  python3 hw/fk33/gen_fk33_regs.py" % path)
    txt = open(path).read()
    out = {}
    simple = re.compile(r'^#define\s+(FK33_\w+)\s+(0x[0-9A-Fa-f]+[uUlL]*|\d+)\s*'
                        r'(?:/\*.*)?$', re.M)
    for name, val in simple.findall(txt):
        out[name] = int(val.rstrip("uUlL"), 0)
    based = re.compile(r'^#define\s+(FK33_\w+)\s+\((FK33_\w+)\s*\+\s*'
                       r'(0x[0-9A-Fa-f]+[uUlL]*)\)', re.M)
    for name, base, off in based.findall(txt):
        if base in out:
            out[name] = out[base] + int(off.rstrip("uUlL"), 0)
    need = ["FK33_ID_MAGIC_OFF", "FK33_ID_MAGIC",
            "FK33_ENG_CTL_BASE", "FK33_ENG_DESC_PTR_LO", "FK33_ENG_DESC_PTR_HI",
            "FK33_ENG_CTRL", "FK33_ENG_STATUS", "FK33_ENG_ERR_INFO",
            "FK33_ENG_ID", "FK33_ENG_ADDR_CAP", "FK33_ENG_CAPS",
            "FK33_ENG_DESC_WORDS", "FK33_ENG_Y_IDX", "FK33_ENG_Y_LO",
            "FK33_ENG_Y_HI", "FK33_ENG_Y_EXP", "FK33_ENG_CYCLES",
            "FK33_ENG_BEATS", "FK33_ENG_STARVED", "FK33_ENG_ID_MAGIC",
            "FK33_ENG_ROWS_IF", "FK33_ENG_BLK", "FK33_ENG_NPORTS_W",
            "FK33_ENG_NPORTS_S", "FK33_ENG_AXI_DW", "FK33_ENG_ADDR_W",
            "FK33_ENG_MAXCOLS", "FK33_ENG_MAXROWS_BFP", "FK33_ENG_DESC_ALIGN",
            "FK33_ENG_DESC_WORDS_EXPECT", "FK33_ENG_HBM_ADDR_W",
            "FK33_ENGX_BASE", "FK33_ENGX_X_ADDR", "FK33_ENGX_X_DATA",
            "FK33_ENGX_STAT", "FK33_ENGX_ID", "FK33_ENGX_ID_MAGIC",
            "FK33_THERM_STATUS", "FK33_THERM_TEMPS", "FK33_THERM_PEAK",
            "FK33_THERM_TRIP", "FK33_HBM_TOP"]
    missing = [n for n in need if n not in out]
    if missing:
        raise RunError("%s carries no %s.  The engine block is added by\n"
                       "  python3 hw/fk33/gen_fk33_regs.py\n"
                       "and a host that defaulted these would address the "
                       "wrong peripheral." % (path, ", ".join(missing)))
    return out


EC_NAME = {0x0: "EC_NONE", 0x3: "EC_DESC", 0x4: "EC_WDOG", 0x9: "EC_GEOM",
           0xA: "EC_MAGIC", 0xB: "EC_VER", 0xC: "EC_ALIGN", 0xD: "EC_ADDR",
           0xE: "EC_CORE", 0xF: "EC_SHAPE"}
EC_WHY = {
    0x3: "descriptor-class malformation (opcode, a pad, out_mode, n_rows, "
         "n_cols, w_beats/s_beats zero, or cb_load=0 with no codebook loaded)",
    0x4: "the descriptor FETCH did not complete within WDOG_LIMIT",
    0x9: "nsub_w/nsub_s disagree with the build's NPORTS_W/NPORTS_S",
    0xA: "ext_magic is not MV4I -- the extension landed at the wrong offset, "
         "which means the generator and the build disagree about the geometry",
    0xB: "ext_version is not 1",
    0xC: "DESC_PTR is not 512-byte aligned, or a base has [11:0] nonzero",
    0xD: "DESC_PTR or a base has a bit set at or above ADDR_W",
    0xE: "matvec_int4 raised err AFTER a clean descriptor",
    0xF: "w_beats or s_beats does not match the shape in n_rows/n_cols",
}


# ---- ERR_INFO is TWO fields, and the sub-case names live in the RTL --------
#
# OI-9 (Oren's decision, 2026-08-29): subsystem A's 4-bit error space was FULL,
# and the route chosen was to subdivide it via ERR_INFO rather than widen the
# code field, because the descriptor's byte layout is pinned.  So ERR_INFO now
# carries [10:0] the failing descriptor word index and [15:11] a sub-case that
# is NAMESPACED PER err_code -- the same sub-case number under two codes means
# two different things.
#
# WHY THIS PARSES THE RTL INSTEAD OF CARRYING A TABLE.  TRACK ERRINFO's handoff
# proposed a hand-copied dict of 18 constants here.  This project has already
# recorded what that costs: two producers agreeing is not evidence, and a
# wrong constant (`nsub_w=29`) survived precisely because two places restated
# it and matched.  rtl/matvec_int4_desc_pkg.vhd declares the code in its
# section header ("-- EC_DESC (0x3)") and each arm as
# `constant ED_x : natural := n;  -- description`, so the number, the name, the
# description AND the code mapping all come from one file that the gateware is
# built from.  If the parse finds nothing we say so and degrade; we never
# invent a name.
_EC_SEC = re.compile(r"^\s*--\s*(EC_[A-Z]+)\s*\((0x[0-9A-Fa-f]+)\)")
_EC_SUB = re.compile(
    r"^\s*constant\s+([A-Z]{2}_[A-Z0-9_]+)\s*:\s*natural\s*:=\s*(\d+)\s*;"
    r"\s*--\s*(.*?)\s*$")


def load_err_subcases(pkg="rtl/matvec_int4_desc_pkg.vhd"):
    """{code: {sub: (NAME, description)}} parsed from the RTL, or {} if absent."""
    try:
        lines = open(pkg, encoding="utf-8").read().splitlines()
    except OSError:
        return {}
    out, code = {}, None
    for ln in lines:
        m = _EC_SEC.match(ln)
        if m:
            code = int(m.group(2), 16)
            out.setdefault(code, {})
            continue
        if code is None:
            continue
        m = _EC_SUB.match(ln)
        if m:
            out[code][int(m.group(2))] = (m.group(1), m.group(3))
        elif ln.strip() and not ln.strip().startswith("--"):
            code = None          # left the sub-case block
    return {c: v for c, v in out.items() if v}


EI_SUB_PTR = 31


def ei_str(code, info, subs):
    """Name the PAIR (err_code, sub-case).  Never guess."""
    sub, word = (info >> 11) & 0x1F, info & 0x7FF
    if sub == EI_SUB_PTR or info == 0xFFFF:
        return "the pointer itself, not a descriptor word"
    if sub == 0:
        return "descriptor word %d" % word
    if not subs:
        return ("descriptor word %d, sub-case %d -- rtl/matvec_int4_desc_pkg.vhd "
                "could not be read, so this host cannot name it" % (word, sub))
    if code not in subs:
        # NOT the same thing as an unknown sub-case, and saying so matters.
        # A code with no sub-cases declared (EC_CORE, EC_MAGIC, ...) reporting
        # a nonzero sub-case means the SITE is wrong, not that this checkout is
        # stale -- blaming the checkout would send the reader to the wrong file,
        # which is the exact failure this function was written to remove.
        return ("descriptor word %d, sub-case %d -- but err_code 0x%X declares "
                "NO sub-cases in rtl/matvec_int4_desc_pkg.vhd, so the raising "
                "site is wrong, not this host" % (word, sub, code))
    hit = subs[code].get(sub)
    if hit is None:
        # THE ARM THAT MATTERS.  Before this existed the code printed
        # "descriptor word index" for the whole 16-bit value, so an opcode
        # refusal (ERR_INFO=0x1000) was reported as descriptor word 4096 -- a
        # wrong diagnosis stated confidently, which is worse than the
        # ambiguity it replaced.
        return ("descriptor word %d, sub-case %d -- UNKNOWN to this host, so "
                "the gateware is newer than this checkout of "
                "rtl/matvec_int4_desc_pkg.vhd" % (word, sub))
    return "descriptor word %d: %s (%s)" % (word, hit[1], hit[0])



# ------------------------------------------------------------- the oracle
def build_oracle(mv4i, n_rows, x_exp, scratch, seed=None, xamp=None, cc="cc"):
    """Compile and run ref/mv_fk33_tr, then parse its trace.

    ref/mv_fk33_tr.c reads the .mv4i and produces the activation vector AND the
    expected y through mv4i_matvec().  That is a different code path from the
    27-master AXI read the card performs, which is what makes it an oracle
    rather than a mirror."""
    src = os.path.join(REPO, "ref", "mv_fk33_tr.c")
    exe = os.path.join(scratch, "mv_fk33_tr")
    if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(src):
        # No -DNDEBUG: ref/matvec_int4.c #errors under it on purpose, because
        # every width bound of spec 7.4 is enforced by assert() alone.
        cmd = [cc, "-O2", "-w", "-I", os.path.join(REPO, "ref"),
               "-o", exe, src, "-lm"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            raise RunError("could not build the oracle:\n  %s\n%s"
                           % (" ".join(cmd), r.stderr))
    trace = os.path.join(scratch, "oracle.txt")
    cmd = [exe, trace, mv4i, str(n_rows), str(x_exp)]
    if seed is not None:
        cmd.append(str(seed))
        if xamp is not None:
            cmd.append(str(xamp))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise RunError("ref/mv_fk33_tr failed (rc=%d):\n%s" % (r.returncode, r.stderr))
    return parse_trace(trace), trace, r.stdout.strip()


def parse_trace(path):
    o = dict(x=[], cb=[None] * 16, wsub={}, ssub={}, ymant={})
    saw_end = False
    for line in open(path):
        f = line.split()
        if not f or f[0].startswith("#"):
            continue
        t = f[0]
        if t == "GEOM":
            (o["rows_if"], o["nports_w"], o["nports_s"], o["axi_dw"],
             o["block"], o["grp"]) = [int(v) for v in f[1:7]]
        elif t == "DIMS":
            (o["n_rows"], o["n_cols"], o["nb"], o["out_shift"],
             o["w_exp"], o["x_exp"]) = [int(v) for v in f[1:7]]
        elif t == "CB":
            o["cb"][int(f[1])] = int(f[2])
        elif t == "X":
            i = int(f[1])
            if i != len(o["x"]):
                raise RunError("oracle trace: X index %d out of order" % i)
            o["x"].append(int(f[2], 16))
        elif t == "WSUB":
            o["wsub"][int(f[1])] = int(f[2])
        elif t == "SSUB":
            o["ssub"][int(f[1])] = int(f[2])
        elif t == "WBEATS":
            o["w_beats"] = int(f[1])
        elif t == "SBEATS":
            o["s_beats"] = int(f[1])
        elif t == "YEXP":
            o["y_exp"] = int(f[1])
        elif t == "YMANT":
            o["ymant"][int(f[1])] = int(f[2], 16)
        elif t == "SATEV":
            o["sat_event"] = int(f[1])
        elif t == "END":
            saw_end = True
    if not saw_end:
        raise RunError("oracle trace %s has no END line -- it is truncated, "
                       "and a truncated trace silently shrinks the comparison"
                       % path)
    for k in ("n_rows", "n_cols", "y_exp", "w_beats", "s_beats"):
        if k not in o:
            raise RunError("oracle trace %s carries no %s" % (path, k))
    if len(o["ymant"]) != o["n_rows"]:
        raise RunError("oracle trace has %d YMANT rows for n_rows=%d"
                       % (len(o["ymant"]), o["n_rows"]))
    if len(o["x"]) != o["n_cols"]:
        raise RunError("oracle trace has %d X elements for n_cols=%d"
                       % (len(o["x"]), o["n_cols"]))
    return o


# ------------------------------------------------------- the plan, no card
def make_plan(a, scratch):
    """Descriptor + oracle + the cross-check between them.  No card, no /dev.

    THE CROSS-CHECK IS THE POINT.  gen_mv4i_desc.py parses the .mv4i header in
    Python; ref/mv_fk33_tr parses it in C through mv4i_parse().  Requiring the
    bases, the beat counts, the codebook and the numeric fields to agree
    compares two independent readings of spec 6.4, and a base is the
    highest-risk field in the whole descriptor: a well-formed base aimed at the
    wrong sub-region computes wrong data and reports success."""
    import gen_mv4i_desc as G
    import hbm_map

    h = G.Mv4iHeader(a.mv4i)
    n_rows = a.rows if a.rows else h.M
    if n_rows > h.M:
        raise RunError("--rows %d exceeds the tensor's M = %d" % (n_rows, h.M))

    mani = json.load(open(a.manifest))
    try:
        arena_base, arena_bytes, _ = hbm_map.manifest_arena(mani)
    except hbm_map.NoRegionBlock as e:
        raise RunError(str(e))
    stride = int(mani["hbm"].get("desc_arena_stride", 512))
    n_jobs = int(mani["hbm"].get("desc_arena_jobs", arena_bytes // stride))
    if not 0 <= a.slot < n_jobs:
        raise RunError("--slot %d is outside the arena's %d slots"
                       % (a.slot, n_jobs))
    desc_addr = arena_base + a.slot * stride

    hbm_base, entry, _ = G.hbm_base_for(a.mv4i, a.manifest)

    # THE ONE CHECK THAT CAN SEE A BASE POINTING AT THE WRONG BYTES.  The
    # gateware cannot: nothing in the descriptor says what a sub-region should
    # CONTAIN, so a well-formed base aimed at the wrong sub-region computes
    # wrong data and reports success (spec 5.1).  Requiring the FILE this tool
    # is describing to be the file the manifest says was written to HBM is the
    # only available substitute, and it is not the same thing: it checks the
    # file, not what is resident.  Confirm residency with
    # `fk33_load_weights.py verify`, which reads HBM back.
    got, want, ok = G.verify_image(a.mv4i, entry)
    if not ok:
        raise RunError("%s hashes to %s and the manifest says the image loaded "
                       "into HBM at 0x%X hashes to %s.  The descriptor would "
                       "point the engine at bytes this host has never seen."
                       % (a.mv4i, got, hbm_base, want))

    build = dict(G.FK33)
    build["addr_w"] = a.addr_w
    d = G.build_descriptor(h, hbm_base, n_rows, a.x_exp, out_mode=a.out_mode,
                           cb_load=not a.no_cb_load, addr_w=a.addr_w)
    bad = G.rtl_would_reject(d, build=build, desc_addr=desc_addr)
    if bad:
        raise RunError("the descriptor this tool built would be REFUSED by the "
                       "gateware:\n  "
                       + "\n  ".join("%s %s" % ("0x%X" % c if c is not None
                                                else "----", n)
                                     for c, n in bad))

    orc, trace_path, orc_line = build_oracle(a.mv4i, n_rows, a.x_exp, scratch,
                                             a.seed, a.xamp, a.cc)

    f = d.fields
    xchecks = []

    def xc(name, want, got):
        xchecks.append((name, want, got, want == got))

    xc("n_rows", f["n_rows"], orc["n_rows"])
    xc("n_cols", f["n_cols"], orc["n_cols"])
    xc("nb", f["nb"], orc["nb"])
    xc("w_exp", f["w_exp"], orc["w_exp"])
    xc("out_shift", f["out_shift"], orc["out_shift"])
    xc("x_exp", f["x_exp"], orc["x_exp"])
    xc("rows_if", f["rows_if"], orc["rows_if"])
    xc("axi_dw", f["axi_dw"], orc["axi_dw"])
    xc("block", f["block"], orc["block"])
    xc("grp", f["grp"], orc["grp"])
    xc("nsub_w", f["nsub_w"], orc["nports_w"])
    xc("nsub_s", f["nsub_s"], orc["nports_s"])
    xc("w_beats", f["w_beats"], orc["w_beats"])
    xc("s_beats", f["s_beats"], orc["s_beats"])
    xc("codebook", list(f["codebook"]), list(orc["cb"]))
    for p in range(f["nsub_w"]):
        xc("w_base[%d]" % p, f["w_base"][p], hbm_base + orc["wsub"][p])
    for q in range(f["nsub_s"]):
        xc("s_base[%d]" % q, f["s_base"][q], hbm_base + orc["ssub"][q])

    return dict(desc=d, fields=f, oracle=orc, desc_addr=desc_addr,
                arena_base=arena_base, arena_bytes=arena_bytes, stride=stride,
                hbm_base=hbm_base, n_rows=n_rows, trace=trace_path,
                oracle_line=orc_line, xchecks=xchecks, manifest=mani,
                digest=got, digest_declared=want)


def print_plan(p, regs, out=sys.stdout):
    f = p["fields"]
    w = out.write
    w("tensor      %s\n" % f["tensor"])
    w("shape       M=%d K=%d   job n_rows=%d n_cols=%d  tiles=%d nb=%d\n"
      % (f["M"], f["K"], f["n_rows"], f["n_cols"], f["tiles"], f["nb"]))
    w("geometry    ROWS_IF=%d AXI_DW=%d BLOCK=%d GRP=%d nsub_w=%d nsub_s=%d\n"
      % (f["rows_if"], f["axi_dw"], f["block"], f["grp"], f["nsub_w"], f["nsub_s"]))
    w("numeric     w_exp=%d out_shift=%d x_exp=%d out_mode=%d cb_load=%s\n"
      % (f["w_exp"], f["out_shift"], f["x_exp"], f["out_mode"], f["cb_load"]))
    w("beats       w_beats=%d s_beats=%d\n" % (f["w_beats"], f["s_beats"]))
    w("weights     hbm_base=0x%X  w_base[0]=0x%X  s_base[0]=0x%X\n"
      % (p["hbm_base"], f["w_base"][0], f["s_base"][0]))
    w("descriptor  %d words / %d bytes -> HBM 0x%X (arena 0x%X + %d B, slot stride %d)\n"
      % (f["desc_words"], f["desc_bytes"], p["desc_addr"], p["arena_base"],
         p["arena_bytes"], p["stride"]))
    w("image       blake2b_128 %s %s the manifest's\n"
      % (p["digest"],
         "matches" if p["digest"] == p["digest_declared"]
         else "(manifest declares none) --" if p["digest_declared"] is None
         else "DIFFERS from"))
    w("oracle      %s\n" % p["oracle_line"])
    w("            y_exp=%d sat_event=%d, %d expected mantissas\n"
      % (p["oracle"]["y_exp"], p["oracle"]["sat_event"], len(p["oracle"]["ymant"])))
    nb = [c for c in p["xchecks"] if not c[3]]
    w("cross-check %d of %d fields agree between tools/gen_mv4i_desc.py "
      "(Python) and ref/mv_fk33_tr (C)\n"
      % (len(p["xchecks"]) - len(nb), len(p["xchecks"])))
    for name, want, got, ok in nb:
        w("  DISAGREE %-14s python=%r  c=%r\n" % (name, want, got))
    for n in f["notes"]:
        w("note        %s\n" % n)
    return not nb


# ------------------------------------------------------------------ transport
class DevBar(object):
    """The AXI-Lite BAR.  /dev/xdma0_user, 4 bytes per access."""

    def __init__(self, path):
        self.path = path
        try:
            self.fd = os.open(path, os.O_RDWR | os.O_SYNC)
        except FileNotFoundError:
            raise RunError("%s does not exist.  The xdma driver is not loaded "
                           "or did not bind; hw/fk33/host/fk33_pcie_check.sh "
                           "will say which." % path)
        except PermissionError:
            raise RunError(
                "%s: permission denied.\n"
                "  GROUP MEMBERSHIP IS READ AT LOGIN, so `id -nG` describes "
                "THIS PROCESS and\n"
                "  `getent group fk33` describes the ACCOUNT.  A shell that "
                "predates the udev\n"
                "  rule is not in the group even though the account is.  "
                "Bridge it with\n"
                "      sg fk33 -c '<the command>'\n"
                "  or start a new login shell.  Check both:\n"
                "      id -nG ; getent group fk33" % path)

    def rd(self, off):
        return struct.unpack("<I", os.pread(self.fd, 4, off))[0]

    def wr(self, off, val):
        os.pwrite(self.fd, struct.pack("<I", val & 0xFFFFFFFF), off)

    def close(self):
        os.close(self.fd)


class DevHbm(object):
    """HBM through the XDMA engines.  The file offset IS the AXI address."""

    def __init__(self, h2c, c2h, top):
        self.h2c_path, self.c2h_path, self.top = h2c, c2h, top
        self.wfd = os.open(h2c, os.O_WRONLY)
        self.rfd = os.open(c2h, os.O_RDONLY)

    def _bound(self, addr, n):
        if addr < 0 or addr + n > self.top:
            raise RunError("HBM access 0x%X + %d runs past 0x%X"
                           % (addr, n, self.top))

    def write(self, addr, data):
        self._bound(addr, len(data))
        k = 0
        while k < len(data):
            k += os.pwrite(self.wfd, data[k:], addr + k)

    def read(self, addr, n):
        self._bound(addr, n)
        out = b""
        while len(out) < n:
            chunk = os.pread(self.rfd, n - len(out), addr + len(out))
            if not chunk:
                raise RunError("short read from %s at 0x%X" % (self.c2h_path, addr))
            out += chunk
        return out

    def close(self):
        os.close(self.wfd)
        os.close(self.rfd)


class FileHbm(object):
    """A sparse file standing in for HBM.  Used only by --dry-run and
    selfcheck; it opens nothing under /dev."""

    def __init__(self, path, top):
        self.path, self.top = path, top
        self.fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        self.store = {}

    def write(self, addr, data):
        if addr < 0 or addr + len(data) > self.top:
            raise RunError("HBM access 0x%X + %d runs past 0x%X"
                           % (addr, len(data), self.top))
        # A sparse file at a 8 GB offset is legal but pointless here; keep the
        # written blocks in memory and mirror them to the file so the operator
        # has something to look at.
        self.store[addr] = bytes(data)
        os.pwrite(self.fd, bytes(data), 0)

    def read(self, addr, n):
        d = self.store.get(addr)
        if d is None:
            return b"\x00" * n
        return (d + b"\x00" * n)[:n]

    def close(self):
        os.close(self.fd)


class SimBar(object):
    """A MODEL of the two AXI-Lite slaves, for --dry-run and selfcheck.

    READ THIS BEFORE TRUSTING ANYTHING IT PRINTS.  This model REPLAYS the
    oracle's y values.  A dry-run PASS therefore says that this tool's
    sequencing, its parsing and its checks work; it says NOTHING about whether
    the card computes anything, because the numbers never went near an engine.
    Every claim it supports is at best DERIVED.

    Its real job is the opposite one: `faults` makes it misbehave, so the
    checks in run_job() can be shown to FAIL.  A checker never shown to fail
    has not been shown to work."""

    def __init__(self, regs, oracle=None, faults=None):
        self.r = regs
        self.o = oracle or {}
        self.f = dict(faults or {})
        self.x = []
        self.x_idx = 0
        self.dptr = 0
        self.y_idx = 0
        self.status = 0
        self.err_addr = 0
        self.trip = self.f.get("trip0", 0)
        self.therm = self.f.get("therm0", 1 << 31)
        self.go_blocked = 0
        self.polls = 0
        self.started = False
        self.writes = []

    # -- helpers
    def _caps(self):
        return ((self.r["FK33_ENG_NPORTS_W"] & 0xFF)
                | ((self.r["FK33_ENG_NPORTS_S"] & 0xFF) << 8)
                | ((self.r["FK33_ENG_ROWS_IF"] & 0xFF) << 16)
                | (((self.r["FK33_ENG_AXI_DW"] // 8) & 0xFF) << 24))

    def _therm_word(self):
        return (self.therm & ~(0xFF << 16)) | ((min(self.trip, 255) & 0xFF) << 16)

    def rd(self, off):
        r = self.r
        if off == r["FK33_ID_MAGIC_OFF"]:
            return self.f.get("id_magic", r["FK33_ID_MAGIC"])
        if off == r["FK33_ENG_ID"]:
            return self.f.get("eng_id", r["FK33_ENG_ID_MAGIC"])
        if off == r["FK33_ENG_CAPS"]:
            return self.f.get("caps", self._caps())
        if off == r["FK33_ENG_ADDR_CAP"]:
            return self.f.get("addr_cap", r["FK33_ENG_ADDR_W"])
        if off == r["FK33_ENG_DESC_WORDS"]:
            return self.f.get("desc_words", r["FK33_ENG_DESC_WORDS_EXPECT"])
        if off == r["FK33_ENG_DESC_PTR_LO"]:
            return self.dptr & 0xFFFFFFFF
        if off == r["FK33_ENG_DESC_PTR_HI"]:
            return (self.dptr >> 32) & 0xFFFFFFFF
        if off == r["FK33_ENG_STATUS"]:
            return self._status()
        if off == r["FK33_ENG_ERR_INFO"]:
            return self.f.get("err_info", 0)
        if off == r["FK33_ENG_Y_EXP"]:
            return self.f.get("y_exp", self.o.get("y_exp", 0)) & 0xFFFFFFFF
        if off == r["FK33_ENG_Y_LO"]:
            return self._y() & 0xFFFFFFFF
        if off == r["FK33_ENG_Y_HI"]:
            return (self._y() >> 32) & 0xFFFFFFFF
        if off == r["FK33_ENG_CYCLES"]:
            return self.f.get("cycles", 4096)
        if off == r["FK33_ENG_BEATS"]:
            return self.f.get("beats", self.o.get("w_beats", 0))
        if off == r["FK33_ENG_STARVED"]:
            return self.f.get("starved", 0)
        if off == r["FK33_ENGX_ID"]:
            return self.f.get("engx_id", r["FK33_ENGX_ID_MAGIC"])
        if off == r["FK33_ENGX_X_ADDR"]:
            return self.f.get("x_addr", self.x_idx) & 0xFFFF
        if off == r["FK33_ENGX_STAT"]:
            return (self.f.get("halt", 0) & 1) | (self.go_blocked << 1)
        if off == r["FK33_THERM_STATUS"]:
            return self._therm_word()
        if off == r["FK33_THERM_TRIP"]:
            return self.trip
        if off in (r["FK33_THERM_TEMPS"], r["FK33_THERM_PEAK"]):
            return 0x00230023
        return 0

    def _status(self):
        st = self.err_addr << 4
        if not self.started:
            return st
        self.polls += 1
        ec = self.f.get("err_code", 0)
        if ec:
            return st | (1 << 2) | (ec << 8)
        if self.f.get("never_done"):
            return st | (1 << 1)
        if self.polls < self.f.get("busy_polls", 1):
            return st | (1 << 1)
        # A trip DURING the job: the guard halts the compute domain and the
        # counter moves.  This is the THERM-255 shape.
        if self.f.get("trip_during") and self.trip == self.f.get("trip0", 0):
            self.trip += self.f["trip_during"]
        return st | 1

    def _y(self):
        y = self.o.get("ymant", {}).get(self.y_idx, 0)
        bad = self.f.get("bad_row")
        if bad is not None and self.y_idx == bad:
            y ^= 1
        return y & 0xFFFFFFFFFFFFFFFF

    def wr(self, off, val):
        r = self.r
        self.writes.append((off, val))
        if off == r["FK33_ENG_DESC_PTR_LO"]:
            self.dptr = (self.dptr & ~0xFFFFFFFF) | val
        elif off == r["FK33_ENG_DESC_PTR_HI"]:
            self.dptr = (self.dptr & 0xFFFFFFFF) | (val << 32)
            for i in range(32):
                if 32 + i >= r["FK33_ENG_ADDR_W"] and (val >> i) & 1:
                    self.err_addr = 1
        elif off == r["FK33_ENG_CTRL"]:
            if val & 1:
                if self.f.get("halt"):
                    self.go_blocked = 1     # exactly what rtl/fk33_engine.vhd does
                else:
                    self.started = True
                    self.polls = 0
        elif off == r["FK33_ENG_Y_IDX"]:
            self.y_idx = val & 0xFFFF
        elif off == r["FK33_ENGX_X_ADDR"]:
            self.x_idx = val & 0xFFFF
        elif off == r["FK33_ENGX_X_DATA"]:
            self.x.append(val & 0xFFFF)
            if not self.f.get("x_stuck"):
                self.x_idx = (self.x_idx + 1) & 0xFFFF
        elif off == r["FK33_ENGX_STAT"]:
            if val & 2:
                self.go_blocked = 0

    def close(self):
        pass


# ------------------------------------------------------------------- the run
class Verdict(object):
    PASS, FAIL, INCONCLUSIVE, REFUSED = "PASS", "FAIL", "INCONCLUSIVE", "REFUSED"


def run_job(p, regs, bar, hbm, a, out=sys.stdout):
    """Program, start, wait, read back, compare.  Returns (verdict, detail)."""
    w = out.write
    f = p["fields"]
    o = p["oracle"]
    R = regs

    def refuse(msg):
        raise RunError(msg)

    # ---------------------------------------------------------------- identity
    # SELECTION BY WHAT A THING ANSWERS, NOT BY ORDINAL.  Every one of these is
    # a constant the fabric drives; a wrong BAR reads 0xFFFFFFFF and a fabric in
    # reset reads 0x00000000, so both plausible wrong answers are named.
    idm = bar.rd(R["FK33_ID_MAGIC_OFF"])
    if idm != R["FK33_ID_MAGIC"]:
        refuse("identity register reads 0x%08X, not 0x%08X.  %s"
               % (idm, R["FK33_ID_MAGIC"],
                  "The BAR is mapped with nothing answering."
                  if idm == 0xFFFFFFFF else
                  "The fabric is held in reset." if idm == 0 else
                  "This is not the FK33 engine bitstream."))
    engid = bar.rd(R["FK33_ENG_ID"])
    if engid != R["FK33_ENG_ID_MAGIC"]:
        refuse("the engine's ID register at 0x%05X reads 0x%08X, not 0x%08X "
               "(\"MV4I\").  This bitstream does not carry "
               "matvec_int4_desc_axi at that base."
               % (R["FK33_ENG_ID"], engid, R["FK33_ENG_ID_MAGIC"]))
    xid = bar.rd(R["FK33_ENGX_ID"])
    if xid != R["FK33_ENGX_ID_MAGIC"]:
        refuse("the activation writer's ID at 0x%05X reads 0x%08X, not 0x%08X "
               "(\"ENG1\").  Without it there is no path for x, and the only "
               "thing the card can compute is a matvec against an all-zero "
               "vector." % (R["FK33_ENGX_ID"], xid, R["FK33_ENGX_ID_MAGIC"]))

    caps = bar.rd(R["FK33_ENG_CAPS"])
    got = dict(nports_w=caps & 0xFF, nports_s=(caps >> 8) & 0xFF,
               rows_if=(caps >> 16) & 0xFF, axi_b=(caps >> 24) & 0xFF)
    want = dict(nports_w=f["nsub_w"], nports_s=f["nsub_s"],
                rows_if=f["rows_if"], axi_b=f["axi_dw"] // 8)
    if got != want:
        refuse("CAPS = 0x%08X decodes to %r, and the descriptor was built for "
               "%r.  The gateware would answer this with EC_GEOM; refusing "
               "before writing it." % (caps, got, want))
    addr_cap = bar.rd(R["FK33_ENG_ADDR_CAP"])
    if addr_cap != a.addr_w:
        refuse("ADDR_CAP reports ADDR_W = %d and the descriptor was built for "
               "%d.  Pass --addr-w %d." % (addr_cap, a.addr_w, addr_cap))
    dwords = bar.rd(R["FK33_ENG_DESC_WORDS"])
    if dwords != f["desc_words"]:
        refuse("DESC_WORDS reports %d and this descriptor is %d words long."
               % (dwords, f["desc_words"]))
    w("identity    FK33 0x%08X | MV4I 0x%08X | ENG1 0x%08X\n" % (idm, engid, xid))
    w("caps        NPORTS_W=%d NPORTS_S=%d ROWS_IF=%d AXI_DW=%d ADDR_W=%d "
      "DESC_WORDS=%d  (all read from the card)\n"
      % (got["nports_w"], got["nports_s"], got["rows_if"], got["axi_b"] * 8,
         addr_cap, dwords))

    # ------------------------------------------------------ pre-run condition
    st0 = bar.rd(R["FK33_ENG_STATUS"])
    if st0 & (1 << 2):
        refuse("the engine is already in its STICKY error state (STATUS=0x%08X,"
               " err_code=%s).  rtl/matvec_int4_desc_axi.vhd's S_ERR is left "
               "only by RESET -- a further GO cannot re-arm it, deliberately, "
               "so that a driver ignoring STATUS cannot run descriptors past a "
               "rejected one.  Reload the bitstream before retrying."
               % (st0, EC_NAME.get((st0 >> 8) & 0xF, "?")))
    if st0 & (1 << 1):
        refuse("the engine reports BUSY before anything was started "
               "(STATUS=0x%08X).  Another job is in flight, or the core "
               "stalled on a previous one." % st0)
    if st0 & (1 << 4):
        w("warn        ERR_ADDR was ALREADY sticky before this run (0x%08X); "
          "a previous DESC_PTR_HI carried a bit at or above ADDR_W\n" % st0)

    xstat0 = bar.rd(R["FK33_ENGX_STAT"])
    if xstat0 & 1:
        refuse("compute_halt is asserted RIGHT NOW (ENGX_STAT=0x%08X).  "
               "rtl/fk33_engine.vhd masks CTRL bit 0 while it is high, so a GO "
               "would be swallowed.  See open issue THERM-255." % xstat0)
    if xstat0 & 2:
        w("note        GO_BLOCKED was already set; clearing it so that reading "
          "it after GO means something\n")
    bar.wr(R["FK33_ENGX_STAT"], 2)              # write 1 to clear the sticky

    therm0 = bar.rd(R["FK33_THERM_STATUS"])
    trip0 = (therm0 >> 16) & 0xFF
    temps0 = bar.rd(R["FK33_THERM_TEMPS"])
    w("thermal     STATUS=0x%08X trips=%d%s cause=%d trip_cause=%d temps=0x%08X\n"
      % (therm0, trip0, " (SATURATED)" if trip0 == 255 else "",
         (therm0 >> 8) & 0xF, (therm0 >> 12) & 0xF, temps0))
    if not (therm0 & (1 << 31)):
        w("warn        THERM_STATUS bit 31 is 0: this bitstream carries NO "
          "thermal guard, so the halt cannot mask a GO -- and nothing is "
          "protecting the card either\n")
    if therm0 & (1 << 30):
        w("warn        THERM_STATUS bit 30 is SET: the two HBM stacks "
          "disagreed and stayed disagreeing.  They are two SEPARATE DIES "
          "(build_fk33_pcieep.tcl:781-782), not two copies of one reading, so "
          "this is a stuck or torn stack sensor or a real load gradient -- NOT "
          "a CDC fault.  It is DIAGNOSTIC: since the THERMFIX change it cannot "
          "halt the card, and a bitstream predating that change halts on a "
          "5 ns transient at every code crossing (open issue THERM-255)\n")
    if trip0 == 255:
        w("warn        the trip counter is at its 8-bit SATURATING maximum, so "
          "'it did not move' cannot be observed on this run.  Clear it first: "
          "fk33ctl.py thermal --clear\n")

    # ------------------------------------------------- descriptor into memory
    img = p["desc"].to_bytes()
    slot = bytearray(p["stride"])
    slot[:len(img)] = img
    hbm.write(p["desc_addr"], bytes(slot))
    back = hbm.read(p["desc_addr"], p["stride"])
    if back != bytes(slot):
        n = sum(1 for i in range(len(slot)) if back[i] != slot[i])
        refuse("the descriptor did not survive the DMA round trip: %d of %d "
               "bytes differ at 0x%X" % (n, len(slot), p["desc_addr"]))
    w("descriptor  %d bytes written to 0x%X and read back identical\n"
      % (len(img), p["desc_addr"]))
    w("            (a ROUND TRIP through one path -- it proves the DMA moved "
      "bytes, NOT that the bytes are the right descriptor.  What checks the "
      "bytes is the Python/C cross-check above and the gateware's own "
      "S_CHECK.)\n")

    # ------------------------------------------------------ the activation x
    t0 = time.time()
    bar.wr(R["FK33_ENGX_X_ADDR"], 0)
    xd = R["FK33_ENGX_X_DATA"]
    for v in o["x"]:
        bar.wr(xd, v)
    xa = bar.rd(R["FK33_ENGX_X_ADDR"]) & 0xFFFF
    want_xa = len(o["x"]) & 0xFFFF
    if xa != want_xa:
        refuse("after writing %d activation elements the engine's own X_ADDR "
               "counter reads %d, not %d.  The writes did not all land, so the "
               "vector the array will use is not the vector the oracle used."
               % (len(o["x"]), xa, want_xa))
    w("activations %d elements written in %.2f s; the engine's own X_ADDR "
      "counter agrees (%d)\n" % (len(o["x"]), time.time() - t0, xa))

    # --------------------------------------------------------- point and GO
    bar.wr(R["FK33_ENG_DESC_PTR_LO"], p["desc_addr"] & 0xFFFFFFFF)
    bar.wr(R["FK33_ENG_DESC_PTR_HI"], (p["desc_addr"] >> 32) & 0xFFFFFFFF)
    st = bar.rd(R["FK33_ENG_STATUS"])
    if st & (1 << 4) and not (st0 & (1 << 4)):
        refuse("ERR_ADDR latched at DESC_PTR_HI WRITE time: 0x%X has a bit at "
               "or above ADDR_W = %d.  This is the map's one write-time check "
               "and it fired before anything ran." % (p["desc_addr"], addr_cap))

    t0 = time.time()
    bar.wr(R["FK33_ENG_CTRL"], 1)
    polls = 0
    st = 0
    while True:
        st = bar.rd(R["FK33_ENG_STATUS"])
        polls += 1
        if st & 0b101:                       # done or err
            break
        if time.time() - t0 > a.timeout:
            break
    elapsed = time.time() - t0

    xstat = bar.rd(R["FK33_ENGX_STAT"])
    if xstat & 2:
        refuse("GO_BLOCKED is set: the thermal guard REFUSED the GO because "
               "compute_halt was high at the write (ENGX_STAT=0x%08X).  The "
               "job never started.  This is NOT a subsystem-A result -- see "
               "open issue THERM-255." % xstat)

    done, busy, err = bool(st & 1), bool(st & 2), bool(st & 4)
    ec = (st >> 8) & 0xF
    w("job         STATUS=0x%08X done=%d busy=%d err=%d err_code=0x%X (%s) "
      "after %d polls / %.3f s\n"
      % (st, done, busy, err, ec, EC_NAME.get(ec, "?"), polls, elapsed))

    therm1 = bar.rd(R["FK33_THERM_STATUS"])
    trip1 = (therm1 >> 16) & 0xFF
    moved = trip1 != trip0
    w("thermal     STATUS=0x%08X trips=%d (was %d)%s\n"
      % (therm1, trip1, trip0, "  <-- MOVED" if moved else ""))

    if err:
        _ei = bar.rd(R["FK33_ENG_ERR_INFO"])
        detail = ("the gateware REFUSED or failed the descriptor: err_code=0x%X "
                  "%s -- %s.  ERR_INFO=0x%04X (%s)."
                  % (ec, EC_NAME.get(ec, "?"), EC_WHY.get(ec, "unassigned code"),
                     _ei, ei_str(ec, _ei, load_err_subcases())))
        if moved:
            return Verdict.INCONCLUSIVE, detail + ("  AND the trip counter "
                "moved %d -> %d during the job, so this error is not evidence "
                "about subsystem A." % (trip0, trip1))
        return Verdict.FAIL, detail
    if not done:
        detail = ("the job never completed: %d polls over %.1f s with "
                  "STATUS=0x%08X (busy=%d).  A descriptor that starves the "
                  "array neither completes nor errors, and WDOG_LIMIT covers "
                  "the descriptor FETCH only." % (polls, elapsed, st, busy))
        if moved:
            return Verdict.INCONCLUSIVE, detail + ("  The trip counter moved "
                "%d -> %d, and EACH TRIP HALTS THE COMPUTE DOMAIN, so this "
                "stall is not evidence about subsystem A." % (trip0, trip1))
        return Verdict.FAIL, detail

    # ------------------------------------------------------------- the result
    y_exp = bar.rd(R["FK33_ENG_Y_EXP"])
    if y_exp >= 1 << 31:
        y_exp -= 1 << 32
    cycles = bar.rd(R["FK33_ENG_CYCLES"])
    beats = bar.rd(R["FK33_ENG_BEATS"])
    starved = bar.rd(R["FK33_ENG_STARVED"])
    w("counters    CYCLES=%d BEATS=%d STARVED=%d  (expected BEATS = "
      "tiles*nblk = %d)\n" % (cycles, beats, starved, f["w_beats"]))
    if beats != f["w_beats"]:
        w("warn        BEATS disagrees with tiles*nblk.  Reported, not fatal: "
          "the register's contract is 'weight words the array consumed' and "
          "this tool has not independently verified that counter's semantics "
          "against the RTL.\n")

    read_rows, cmp_rows, bad = 0, 0, []
    for r in range(f["n_rows"]):
        bar.wr(R["FK33_ENG_Y_IDX"], r)
        lo = bar.rd(R["FK33_ENG_Y_LO"])
        hi = bar.rd(R["FK33_ENG_Y_HI"])
        read_rows += 1
        got = (hi << 32) | lo
        if r not in o["ymant"]:
            continue                      # cannot happen: parse_trace requires it
        cmp_rows += 1
        if got != o["ymant"][r]:
            bad.append((r, got, o["ymant"][r]))

    # STATE COVERAGE EXPLICITLY.  Never a tally the reader has to subtract.
    w("result      read %d of %d rows, compared %d of %d against "
      "ref/matvec_int4.c, %d differ\n"
      % (read_rows, f["n_rows"], cmp_rows, f["n_rows"], len(bad)))
    w("            y_exp card=%d oracle=%d\n" % (y_exp, o["y_exp"]))
    for r, g, e in bad[:a.show]:
        w("  ROW %-6d card=0x%016X  oracle=0x%016X  (%d vs %d)\n"
          % (r, g, e, sx64(g), sx64(e)))
    if len(bad) > a.show:
        w("  ... and %d more\n" % (len(bad) - a.show))

    if cmp_rows != f["n_rows"]:
        return Verdict.INCONCLUSIVE, ("only %d of %d rows were compared; a "
                                      "verdict over a partial set is not a "
                                      "verdict" % (cmp_rows, f["n_rows"]))
    if moved:
        return Verdict.INCONCLUSIVE, (
            "the thermal trip counter moved %d -> %d ACROSS the job.  Each trip "
            "halts the compute domain, so neither the %d mismatches nor their "
            "absence is evidence about subsystem A.  Clear the counter "
            "(fk33ctl.py thermal --clear), confirm it stays 0 for longer "
            "than the job, and re-run.  See open issue THERM-255."
            % (trip0, trip1, len(bad)))
    if bad or y_exp != o["y_exp"]:
        return Verdict.FAIL, ("%d of %d mantissas differ from "
                              "ref/matvec_int4.c%s"
                              % (len(bad), cmp_rows,
                                 "" if y_exp == o["y_exp"]
                                 else "; y_exp %d != %d" % (y_exp, o["y_exp"])))
    return Verdict.PASS, ("%d of %d mantissas and y_exp are bit-identical to "
                          "ref/matvec_int4.c" % (cmp_rows, f["n_rows"]))


def sx64(v):
    return v - (1 << 64) if v >> 63 else v


# ------------------------------------------------------------------ selfcheck
def synth_mv4i(scratch, M, K, cc="cc"):
    """A packed tensor with no model set and no GGUF, from ref/matvec_int4.c's
    own --emit mode.  Using the C packer rather than a Python one keeps the
    selfcheck free of a second layout implementation."""
    exe = os.path.join(scratch, "mv4i_emit")
    src = os.path.join(REPO, "ref", "matvec_int4.c")
    if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(src):
        r = subprocess.run([cc, "-O2", "-w", "-I", os.path.join(REPO, "ref"),
                            "-o", exe, src, "-lm"], capture_output=True, text=True)
        if r.returncode:
            raise RunError("could not build ref/matvec_int4.c:\n" + r.stderr)
    path = os.path.join(scratch, "synth.mv4i")
    r = subprocess.run([exe, "--emit", path, str(M), str(K), "48", "256"],
                       capture_output=True, text=True)
    if r.returncode:
        raise RunError("--emit failed:\n" + r.stderr + r.stdout)
    return path


def synth_manifest(scratch, mv4i, hbm_base):
    """A one-object manifest carrying the SAME hbm region block shape the real
    one does, so plan() exercises hbm_map.manifest_arena() rather than a
    special case."""
    mani = dict(format="fk33_run_job selfcheck",
                geometry=dict(rows_if=48, axi_dw=256, block=32,
                              nports_w=24, n_scale_sub=3),
                hbm=dict(size=0x2_0000_0000,
                         desc_arena_base=0x1FFADD000, desc_arena_bytes=159744,
                         desc_arena_jobs=311, desc_arena_stride=512,
                         host_max_chunk=512),
                files=[dict(file=os.path.basename(mv4i), kind="mv4i",
                            tensor="selfcheck", M=0, K=0,
                            nbytes=os.path.getsize(mv4i),
                            hbm_offset=hbm_base, stack=0)])
    path = os.path.join(scratch, "manifest.json")
    json.dump(mani, open(path, "w"), indent=1)
    return path


def cmd_selfcheck(a):
    """Prove the checks can FAIL.  No card, no model, nothing under /dev.

    Every row here mutates the SIMULATED card and requires this tool to refuse.
    Rows that do NOT bite are printed under their own names, because they
    measure the resolution floor of the checking and are the most valuable
    lines in the table."""
    scratch = a.scratch or os.path.join(os.environ.get(
        "TMPDIR", "/tmp"), "fk33_run_job_selfcheck")
    os.makedirs(scratch, exist_ok=True)
    regs = load_regs()

    print("scratch     %s" % scratch)
    mv4i = synth_mv4i(scratch, a.sc_m, a.sc_k, a.cc)
    hbm_base = 0x1000000
    mani = synth_manifest(scratch, mv4i, hbm_base)
    print("synthetic   %s (%d bytes), M=%d K=%d, one-object manifest"
          % (os.path.basename(mv4i), os.path.getsize(mv4i), a.sc_m, a.sc_k))

    class P:
        pass
    pa = P()
    pa.mv4i, pa.manifest, pa.rows, pa.x_exp = mv4i, mani, a.sc_m, 5
    pa.slot, pa.out_mode, pa.no_cb_load, pa.addr_w = 0, 0, False, 40
    pa.seed, pa.xamp, pa.cc = None, None, a.cc
    pa.timeout, pa.show = 5.0, 4

    devnull = open(os.devnull, "w")
    plan = make_plan(pa, scratch)
    if not print_plan(plan, regs, devnull):
        print("FATAL: the clean plan's own cross-check disagrees; the harness "
              "cannot measure anything from here")
        return 1

    hbm_path = os.path.join(scratch, "hbm.bin")

    def attempt(faults):
        hbm = FileHbm(hbm_path, regs["FK33_HBM_TOP"])
        bar = SimBar(regs, plan["oracle"], faults)
        try:
            v, d = run_job(plan, regs, bar, hbm, pa, devnull)
            return v, d
        except RunError as e:
            return Verdict.REFUSED, str(e).splitlines()[0]
        finally:
            hbm.close()

    rows = [
        # (name, faults, the verdict this MUST produce)
        ("control (clean)",            {},                          Verdict.PASS),
        ("BAR unmapped (all ones)",    dict(id_magic=0xFFFFFFFF),   Verdict.REFUSED),
        ("fabric in reset (all zero)", dict(id_magic=0),            Verdict.REFUSED),
        ("wrong engine ID",            dict(eng_id=0xDEADBEEF),     Verdict.REFUSED),
        ("no activation writer",       dict(engx_id=0),             Verdict.REFUSED),
        ("CAPS ROWS_IF 48 -> 4",       dict(caps=(4 << 16) | (32 << 24) | (3 << 8) | 24),
                                                                    Verdict.REFUSED),
        ("CAPS NPORTS_W 24 -> 4",      dict(caps=(48 << 16) | (32 << 24) | (3 << 8) | 4),
                                                                    Verdict.REFUSED),
        ("ADDR_CAP 40 -> 33",          dict(addr_cap=33),           Verdict.REFUSED),
        ("DESC_WORDS 39 -> 17",        dict(desc_words=17),         Verdict.REFUSED),
        ("engine already in S_ERR",    dict(err_code=0x3),          Verdict.FAIL),
        ("EC_SHAPE from the gateware", dict(err_code=0xF),          Verdict.FAIL),
        ("compute_halt high at GO",    dict(halt=1),                Verdict.REFUSED),
        ("X_ADDR does not advance",    dict(x_stuck=True),          Verdict.REFUSED),
        ("job never completes",        dict(never_done=True),       Verdict.FAIL),
        ("one wrong mantissa",         dict(bad_row=0),             Verdict.FAIL),
        ("wrong y_exp",                dict(y_exp=99),              Verdict.FAIL),
        ("trip counter moves in-job",  dict(trip_during=1),         Verdict.INCONCLUSIVE),
        ("wrong answer AND a trip",    dict(bad_row=0, trip_during=1),
                                                                    Verdict.INCONCLUSIVE),
        ("busy for several polls",     dict(busy_polls=5),          Verdict.PASS),
        ("BEATS wrong (warn only)",    dict(beats=1),               Verdict.PASS),
        ("STARVED nonzero (warn)",     dict(starved=77),            Verdict.PASS),
    ]

    print("\n%-30s %-14s %-14s %s" % ("mutation", "want", "got", "verdict"))
    print("-" * 88)
    nfail, nbite, nnot = 0, 0, 0
    notbiting = []
    for name, faults, want in rows:
        got, detail = attempt(faults)
        ok = got == want
        if not ok:
            nfail += 1
        # A row whose EXPECTED verdict is PASS is a control, not a tooth.
        if want == Verdict.PASS and faults:
            if got == Verdict.PASS:
                nnot += 1
                notbiting.append((name, detail))
        elif want != Verdict.PASS:
            if ok:
                nbite += 1
            else:
                notbiting.append((name, "wanted %s, got %s: %s" % (want, got, detail)))
        print("%-30s %-14s %-14s %s" % (name, want, got, "ok" if ok else "MISMATCH"))

    print("\nDESCRIPTOR-SIDE checks, run without a card at all:")
    dsc = descriptor_teeth(pa, scratch, regs)
    for name, got, want, ok in dsc:
        print("%-30s %-14s %-14s %s" % (name, want, got, "ok" if ok else "MISMATCH"))
        if not ok:
            nfail += 1

    print("\nOPEN DEFECT PROBE (measured, not asserted on):")
    try:
        h, w1, s1, w2, s2, agree = layout_rule_probe(scratch, a.cc)
        print("  M=%d K=%d nb=%d tiles=%d port_b=%d -> sub_bytes()=%d, "
              "4 KB-aligned=%s"
              % (h.M, h.K, h.nb, h.tiles(h.M), h.port_b, h.sub_bytes(),
                 h.sub_bytes() % 4096 == 0))
        print("  rule 1 (file offset table) w[0:2]=%r  rule 2 (layout) w[0:2]=%r"
              % (w1[:2], w2[:2]))
        print("  the two base rules %s"
              % ("AGREE -- the defect below appears to have been fixed"
                 if agree else
                 "DISAGREE.  gen_mv4i_desc.py's rule 2 omits the align4k() "
                 "that\n    ref/matvec_int4.c:474 and tools/pack_int4.py:477 "
                 "both apply, so its\n    two-rule base check agrees by "
                 "coincidence on the 9B set (K in {4096,\n    12288} makes "
                 "sub_bytes() a multiple of 4096) and falsely refuses "
                 "anything\n    else.  NOT FIXED HERE: that file is not this "
                 "track's."))
    except Exception as exc:                       # noqa: BLE001
        print("  probe could not run: %s" % exc)

    print("\nROWS THAT DO NOT BITE -- the resolution floor of this checking:")
    if not notbiting:
        print("  (none)")
    for name, why in notbiting:
        print("  %-28s %s" % (name, why))
    print("""
  Read those as measurements, not as failures.  A BEATS or STARVED value that
  disagrees with the shape is REPORTED and does not change the verdict, on
  purpose: this tool has not verified those counters' semantics against the
  RTL, and a check whose meaning is unverified must not be allowed to turn a
  correct numeric result into a FAIL.""")

    print("\nselfcheck   %d mutations, %d expected-refusal rows bit, "
          "%d rows disagreed with their expected verdict"
          % (len(rows) + len(dsc), nbite, nfail))
    print("""
WHAT THIS DOES AND DOES NOT ESTABLISH.  The simulated card REPLAYS the oracle,
so the control row's PASS is a statement about this tool's sequencing and
parsing.  It is NOT evidence that any FPGA computes anything.  Everything above
is DERIVED; the only MEASURED statement about subsystem A comes from
`run` against the card.""")
    devnull.close()
    return 1 if nfail else 0


def descriptor_teeth(pa, scratch, regs):
    """Checks that need no card and no simulated card: the ones that refuse a
    descriptor before a byte is written."""
    import copy
    out = []

    def row(name, want, fn):
        try:
            fn()
            got = "accepted"
        except (RunError, Exception) as e:      # noqa: BLE001 - any refusal counts
            got = "refused"
            del e
        out.append((name, got, want, got == want))

    def with_arg(**kw):
        b = copy.copy(pa)
        for k, v in kw.items():
            setattr(b, k, v)
        return lambda: make_plan(b, scratch)

    row("control: the real plan", "accepted", with_arg())
    row("--rows past M", "refused", with_arg(rows=pa.rows + 48))
    row("--slot outside the arena", "refused", with_arg(slot=100000))
    # --addr-w 33 is a NON-BITE and is expected to be, which is why it is
    # here: every address in this plan (the arena at 0x1FFADD000 and the
    # weight bases) fits under 2^33, so narrowing ADDR_W to 33 is not an
    # error and refusing it would be a false positive.  The row below is the
    # one with teeth.  On the CARD this is caught separately: run_job()
    # refuses unless ADDR_CAP reports the same ADDR_W the descriptor was
    # built for.
    row("--addr-w 33 (still fits)", "accepted", with_arg(addr_w=33))
    row("--addr-w 24 (arena needs 33)", "refused", with_arg(addr_w=24))
    row("--out-mode 3 (> 2)", "refused", with_arg(out_mode=3))

    # A manifest with no region block: hbm_map.manifest_arena must RAISE rather
    # than default, because a default is a second allocator at a second address.
    noblk = os.path.join(scratch, "manifest_noblock.json")
    m = json.load(open(pa.manifest))
    m["hbm"].pop("desc_arena_base")
    json.dump(m, open(noblk, "w"))
    row("manifest with no arena block", "refused", with_arg(manifest=noblk))

    # A descriptor whose pointer is not 512-aligned.
    badstride = os.path.join(scratch, "manifest_misaligned.json")
    m2 = json.load(open(pa.manifest))
    m2["hbm"]["desc_arena_base"] += 8
    json.dump(m2, open(badstride, "w"))
    row("arena base off by 8 (alignment)", "refused", with_arg(manifest=badstride))

    # A base above ADDR_W.
    hi = os.path.join(scratch, "manifest_highbase.json")
    m3 = json.load(open(pa.manifest))
    m3["files"][0]["hbm_offset"] = 1 << 41
    json.dump(m3, open(hi, "w"))
    row("weight base above ADDR_W", "refused", with_arg(manifest=hi))

    # The image digest.  This is the ONLY host-side check that can see the
    # descriptor being pointed at bytes other than the ones it was built from,
    # so it must not be able to pass by being absent.
    import hashlib
    real = hashlib.blake2b(open(pa.mv4i, "rb").read(), digest_size=16).hexdigest()
    dg = os.path.join(scratch, "manifest_baddigest.json")
    m4 = json.load(open(pa.manifest))
    m4["files"][0]["blake2b_128"] = ("0" * 31 + "1") if real != "0" * 31 + "1" else "f" * 32
    json.dump(m4, open(dg, "w"))
    row("manifest digest disagrees", "refused", with_arg(manifest=dg))

    ok = os.path.join(scratch, "manifest_gooddigest.json")
    m5 = json.load(open(pa.manifest))
    m5["files"][0]["blake2b_128"] = real
    json.dump(m5, open(ok, "w"))
    row("manifest digest agrees", "accepted", with_arg(manifest=ok))
    return out


def layout_rule_probe(scratch, cc="cc"):
    """OPEN DEFECT, MEASURED 2026-08-29 by TRACK AJOBRUN, NOT FIXED HERE.

    tools/gen_mv4i_desc.py's headline safety property is that it computes every
    base TWICE and refuses to emit if the two rules disagree -- because a base
    aimed at the wrong sub-region is the one corruption the gateware cannot
    see.  Rule 1 is the file's own offset table at 0x38; rule 2 is
    sub_offsets_from_layout(), which strides by `h.sub_bytes()` =
    tiles*nb*port_b.

    BOTH PACKERS PAD EVERY SUB-REGION TO 4 KB and rule 2 does not:
    ref/matvec_int4.c:474 `sub_pad = align4k(tiles*NB*port_b)` and
    tools/pack_int4.py:477 `sub_sz = align4k(tiles*NB*port_b)`.
    pack_int4.py:482 further gives the SCALE sub-regions their own
    `scl_sub_sz = align4k(nsuper*port_b)`, which differs from the weight stride
    whenever GRP != 1; rule 2 uses one stride for both.

    Why nobody has hit it: at the FK33 geometry GRP = 1, and every tensor in
    the 9B set has K in {4096, 12288}, so nb is 128 or 384 and
    tiles*nb*port_b is always an exact multiple of 4096.  Rule 2 therefore
    AGREES WITH RULE 1 BY COINCIDENCE OF GEOMETRY on every file it has ever
    been run on.

    Consequence, and it is the point: on this tensor set the two-rule check is
    not an independent check at all, and on a tensor where the sizes do not
    already align it REFUSES A CORRECT FILE.  This probe measures the fact
    rather than asserting on it, because the fix belongs to whoever owns
    tools/gen_mv4i_desc.py.  Its verdict flips when that is fixed, so it is
    printed and never counted as a failure."""
    import gen_mv4i_desc as G
    path = synth_mv4i(scratch, 96, 128, cc)          # sub_sz = 2*4*32 = 256 B
    h = G.Mv4iHeader(path)
    w1, s1 = G.sub_offsets_from_header(h)
    w2, s2 = G.sub_offsets_from_layout(h)
    return h, w1, s1, w2, s2, (w1 == w2 and s1 == s2)


# ----------------------------------------------------------------------- main
def open_transport(a, regs, scratch, plan):
    if a.dry_run:
        path = os.path.join(scratch, "hbm.bin")
        return (SimBar(regs, plan["oracle"]),
                FileHbm(path, regs["FK33_HBM_TOP"]), True)
    user = os.environ.get("FK33_USER", "/dev/xdma0_user")
    h2c = os.environ.get("FK33_H2C", "/dev/xdma0_h2c_0")
    c2h = os.environ.get("FK33_C2H", "/dev/xdma0_c2h_0")
    return DevBar(user), DevHbm(h2c, c2h, regs["FK33_HBM_TOP"]), False


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def job_args(s):
        s.add_argument("--mv4i", required=True, help="the packed tensor")
        s.add_argument("--manifest", default=DEFAULT_MANIFEST)
        s.add_argument("--rows", type=int, default=None,
                       help="n_rows for this job (default: the tensor's M)")
        s.add_argument("--x-exp", type=int, default=5, dest="x_exp")
        s.add_argument("--slot", type=int, default=0,
                       help="descriptor arena slot")
        s.add_argument("--out-mode", type=int, default=0, dest="out_mode")
        s.add_argument("--no-cb-load", action="store_true")
        s.add_argument("--addr-w", type=int, default=40, dest="addr_w")
        s.add_argument("--seed", type=int, default=None,
                       help="oracle activation seed (ref/mv_fk33_tr default "
                            "20260828)")
        s.add_argument("--xamp", type=int, default=None,
                       help="oracle activation amplitude (default 8000)")
        s.add_argument("--scratch", default=None)
        s.add_argument("--cc", default="cc")
        s.add_argument("--show", type=int, default=8,
                       help="mismatching rows to print")

    s = sub.add_parser("plan", help="build and cross-check; no card, no /dev")
    job_args(s)
    s.set_defaults(fn=cmd_plan)

    s = sub.add_parser("run", help="run it (see --dry-run)")
    job_args(s)
    s.add_argument("--dry-run", action="store_true",
                   help="simulated register plane and file-backed HBM; opens "
                        "nothing under /dev.  Proves the plumbing, NOT the card")
    s.add_argument("--timeout", type=float, default=30.0)
    s.set_defaults(fn=cmd_run)

    s = sub.add_parser("selfcheck",
                       help="prove the checks can fail; no card, no model")
    s.add_argument("--scratch", default=None)
    s.add_argument("--cc", default="cc")
    # K = 4096 is NOT a free choice.  See the OPEN DEFECT note on
    # sub_offsets_from_layout() in descriptor_teeth(): at K = 128 the two base
    # rules disagree and NOTHING can be emitted, so a smaller synthetic image
    # would make the selfcheck untestable rather than stricter.
    s.add_argument("--sc-m", type=int, default=96, dest="sc_m")
    s.add_argument("--sc-k", type=int, default=4096, dest="sc_k")
    s.set_defaults(fn=cmd_selfcheck)

    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except RunError as e:
        print("fk33_run_job: " + str(e), file=sys.stderr)
        return 2


def _scratch(a):
    d = a.scratch or os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                  "fk33_run_job")
    os.makedirs(d, exist_ok=True)
    return d


def cmd_plan(a):
    regs = load_regs()
    p = make_plan(a, _scratch(a))
    ok = print_plan(p, regs)
    print("plan        %s" % ("consistent" if ok else "INCONSISTENT"))
    return 0 if ok else 1


def cmd_run(a):
    regs = load_regs()
    scratch = _scratch(a)
    p = make_plan(a, scratch)
    if not print_plan(p, regs):
        print("refusing to run: the two independent readings of the .mv4i "
              "header disagree", file=sys.stderr)
        return 2
    bar, hbm, sim = open_transport(a, regs, scratch, p)
    if sim:
        print("transport   SIMULATED.  Nothing under /dev is opened, and the "
              "model REPLAYS the oracle.")
    else:
        print("transport   %s + %s/%s"
              % (os.environ.get("FK33_USER", "/dev/xdma0_user"),
                 os.environ.get("FK33_H2C", "/dev/xdma0_h2c_0"),
                 os.environ.get("FK33_C2H", "/dev/xdma0_c2h_0")))
    try:
        verdict, detail = run_job(p, regs, bar, hbm, a)
    finally:
        bar.close()
        hbm.close()
    print("\nVERDICT     %s -- %s" % (verdict, detail))
    if sim:
        print("            DRY RUN.  This is a statement about this tool, not "
              "about any FPGA.")
    return {Verdict.PASS: 0, Verdict.FAIL: 1,
            Verdict.INCONCLUSIVE: 3, Verdict.REFUSED: 2}[verdict]


if __name__ == "__main__":
    sys.exit(main())
