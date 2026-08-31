#!/usr/bin/env python3
"""gen_compose4_top.py -- TRACK COMPOSE4, 2026-08-29.

Emit `hw/fk33/rtl/compose4_top.vhd`: ONE synthesis top that carries subsystems
A, B, C and D together, at the real Qwen3.5-9B shape, so the composition can be
taken through `place_design` and `route_design` instead of being a sum of
independent out-of-context synthesis runs.

WHAT PROBLEM THIS SOLVES
------------------------
Board row N3: no RTL top composes A+B+C+D for the card.  `hw/fk33/rtl/
fk33_engine.vhd` carries subsystem A alone.  `rtl/llama_top.vhd` carries all
four but is a SIMULATION top -- it binds `matvec_int4`, which has no descriptor
plane, and `C_REAL`/`C_KV_AXI`/`NORM_REAL`/`B_SRC_REAL` all default false.

TRACK DISTRAM's 217,381 CLB LUT for B+C+D is the SUM of seven independent
`synth_design -mode out_of_context -flatten_hierarchy none` runs, with
`opt_design` deliberately not run, across FOUR different pinned trees, none of
them placed and none routed.  Nothing in this project has ever placed or routed
`gdn_block`, `attn_block` or any `seq_*` unit.

WHAT THIS TOP IS, STATED PLAINLY, AND WHAT IT IS NOT
----------------------------------------------------
It is a CO-RESIDENCY top.  The nine instances share `core_clk` and `core_rst`
(and `fk33_engine` additionally takes `hbm_aclk`, the second domain the card
runs); every other port of every instance is brought out to the top level.

So this top MEASURES:
  * the composed synthesis area with cross-boundary optimisation ALLOWED,
    which the four booked rows forbade (`-flatten_hierarchy none`);
  * whether the composition PLACES inside a `pb_core`-shaped region;
  * whether it ROUTES;
  * the post-route WNS on the real 5.0 ns core clock, on the real part.

It does NOT measure:
  * anything about arithmetic.  A routed design is not a correct one, and
    subsystems B and C have never run on this silicon at all.
  * inter-subsystem nets.  The subsystems are not wired to each other, because
    HOW they are wired is board row N2 -- the host-seam contract -- and N2 is a
    decision reserved for Oren.  Wiring them would be picking it.
  * the FK33 shell (XDMA, the HBM controller, clk_wiz, the thermal block, the
    AXI interconnect).  The shell's own cells inside `pb_core` are accounted
    for by CONSTRAINING the pblock to the free region, not by instantiating it.

WHY EVERY OTHER PORT GOES TO THE TOP LEVEL RATHER THAN TO A STIMULUS HARNESS
----------------------------------------------------------------------------
A harness that drives the wide inputs from an LFSR and XOR-reduces the wide
outputs would add its own LUTs and FFs to the very number this exists to
measure, and would have to be measured and subtracted -- a second measurement
with its own error.  An out-of-context port costs nothing and cannot be
optimised away, so the cell count is the subsystems' own.  The price is that
`report_route_status` will report the port nets as unrouted; the caller's
script counts those separately and reports them separately.  See
`sim/ooc_compose4_pnr.tcl`.

GENERIC PROVENANCE -- these are the BOOKING's generics, not new ones
--------------------------------------------------------------------
Every generic below is exactly what the corresponding row of TRACK DISTRAM's
217,381 booking was synthesised with, so the composed number is comparable to
it without adjustment:

    B  gdn_block      all defaults          (distram result_dr_gdn_2abc_f.csv)
    C  attn_block     HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8
                                            (writedec result_wd_attn_after.csv)
    D  seq_*  x5      all defaults          (writedec result_wd_seq_*.csv)
    D  ooc_normadapt  all defaults          (normadapt result_na_after.csv)

TWO CONSEQUENCES OF THAT CHOICE, both recorded because they are real gaps:

 1. `seq_vec_res` at its DEFAULT `ADDR_W = 13`, and `rtl/llama_top.vhd` passes
    16.  `seq_desc_fetch` at its default `WDOG_LIMIT = 4096`, and llama_top
    passes 200000.  Matching the booking was chosen over matching llama_top
    because a number that cannot be compared to the booking answers nothing.
    Both units are small (4,820 and 702 LUT).

 2. `ooc_normadapt` carries `NORM_W_IMAGE = ""`, so the norm gain table is the
    synthetic ramp and NOT a real image.  TRACK NWROM MEASURED that a real
    image costs +32,943 LUT, and TRACK NWFIX is fixing the elaboration blocker
    (Vivado's 65,536 per-loop limit against 266,240 lines).  So NO number this
    top produces includes the gain image, and 32,943 must be added before
    comparing against a pb_core budget.  The generated file says so too.

`fk33_engine` has NO generics at all -- it is the shipping subsystem A,
byte-for-byte the entity in the bitstream on card 1.

NO HARDWARE.  This script reads and writes text files and nothing else.

usage:  python3 hw/fk33/gen_compose4_top.py [--rtl <dir>] [--fk33-rtl <dir>]
                                            [--out <file>]
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# THE REPO ROOT IS TWO LEVELS UP FROM hw/fk33, NOT ONE.  MEASURED 2026-08-30 by
# TRACK ROUTE2: this was `os.path.dirname(HERE)`, which is `<repo>/hw`, so the
# default `--rtl` resolved to `<repo>/hw/rtl` -- a directory that has never
# existed in this tree.  Every invocation since the generator was written has
# therefore had to pass `--rtl` explicitly, and running it without one aborts
# with `COMPOSE4 ABORT: missing <repo>/hw/rtl/gdn_block.vhd`.  That abort is
# loud, which is the only reason this was harmless rather than silent.
REPO = os.path.dirname(os.path.dirname(HERE))

# ---------------------------------------------------------------------------
# The composition.  (instance, entity, source file, generic overrides)
#
# The order is A, B, C, then D's five control leaves, then D's vector
# arithmetic.  `ooc_normadapt` is GENERATED by sim/ooc_normadapt_extract.py
# from rtl/llama_top.vhd and is expected to already be in the RTL directory.
# ---------------------------------------------------------------------------
#
# THE TWO AREA LEVERS, ADDED 2026-08-30 BY TRACK ROUTE2.  Both were MEASURED
# elsewhere and neither was reachable from this top until now:
#
#  * LEVER C, the IQ4_NL codebook to LUTRAM (TRACK LEVERC48, `a4828ab`).
#    Selected by `CB_STYLE` on `a_eng`, defaulting to "distributed" here and
#    settable with --cb-style for the attribution control.  It only became
#    reachable when `fk33_engine` gained a CB_STYLE generic to forward; before
#    that the lever lived in `matvec_core` and no top the card or this
#    composition builds could ask for it.
#
#  * THE NORM LEVER, `rmsnorm_rs_mem` (TRACK RMSWIRE, `47c9d9c`).  NOT a
#    generic here.  `d_norm` is `ooc_normadapt`, which is GENERATED by
#    sim/ooc_normadapt_extract.py from `rtl/llama_top.vhd`'s `gvr` block, and
#    HEAD's `gvr` instantiates `rmsnorm_rs_mem` unconditionally (llama_top.vhd
#    :2190).  So the lever arrives by RE-EXTRACTING against HEAD and by
#    nothing else, and a `rtl/ooc_normadapt_top.vhd` left over from an older
#    tree silently draws the pre-lever design.  The extractor MUST be re-run
#    immediately before this generator.
#
INSTANCES = [
    ("a_eng",   "fk33_engine",     "FK33", {}),
    ("b_gdn",   "gdn_block",       "RTL",  {}),
    ("c_attn",  "attn_block",      "RTL",  {"HEAD_DIM": "256", "N_QH": "16",
                                            "N_KVH": "4", "LAYERS": "8"}),
    ("d_fetch", "seq_desc_fetch",  "RTL",  {}),
    ("d_opdec", "seq_opdec",       "RTL",  {}),
    ("d_lock",  "seq_region_lock", "RTL",  {}),
    ("d_viss",  "seq_vec_issue",   "RTL",  {}),
    ("d_vres",  "seq_vec_res",     "RTL",  {}),
    ("d_norm",  "ooc_normadapt",   "RTL",  {}),
]

# Ports that are SHARED rather than exported, per instance-entity.
# Everything else becomes a top-level port.
#
# THE CLOCKS ARE THE BUFG OUTPUTS, not the ports.  MEASURED 2026-08-29 on this
# part with a four-flop probe: `synth_design -mode out_of_context` inserts NO
# clock buffer (0 BUFG cells, and the clock net's TYPE comes back
# `LOCAL_CLOCK`), and an out-of-context XDC carrying
# `set_property CLOCK_BUFFER_TYPE BUFG [get_ports clk]` does not insert one
# either -- also 0.  A 300,000-load clock on local routing would make every
# placement, routing and timing number below meaningless, so the buffers are
# instantiated here.
SHARED = {
    "fk33_engine": {"core_clk": "core_clk_i", "hbm_aclk": "hbm_aclk_i",
                    "core_aresetn": "core_aresetn"},
    "_default":    {"clk": "core_clk_i", "rst": "core_rst"},
}

SRC_FILE = {
    "fk33_engine":     ("FK33", "fk33_engine.vhd"),
    "gdn_block":       ("RTL",  "gdn_block.vhd"),
    "attn_block":      ("RTL",  "attn_block.vhd"),
    "seq_desc_fetch":  ("RTL",  "seq_desc_fetch.vhd"),
    "seq_opdec":       ("RTL",  "seq_opdec.vhd"),
    "seq_region_lock": ("RTL",  "seq_region_lock.vhd"),
    "seq_vec_issue":   ("RTL",  "seq_vec_issue.vhd"),
    "seq_vec_res":     ("RTL",  "seq_vec_res.vhd"),
    "ooc_normadapt":   ("RTL",  "ooc_normadapt_top.vhd"),
}

# A port declaration line.  Deliberately strict: anything in an entity's port
# clause that does NOT match is a parse failure and aborts, rather than being
# silently dropped.  A dropped port is a dangling input tied to its default,
# which is exactly the plausible-wrong-number failure this project keeps
# finding.
PORT_RE = re.compile(
    r"^\s*([A-Za-z][A-Za-z0-9_]*)\s*:\s*(in|out|inout)\s+(.*?)\s*$")
GEN_RE = re.compile(
    r"^\s*([A-Za-z][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_ ]*"
    r"(?:\s+range\s+[^:]*?)?)\s*:=\s*(.*?)\s*$")


def strip_comment(line):
    # No VHDL string literal in any entity header here contains "--", and the
    # parser asserts on anything it cannot read, so a naive split is safe.
    i = line.find("--")
    return line if i < 0 else line[:i]


def clause(text, entity, kw):
    """Return the raw lines of `entity`'s generic/port clause, comments gone."""
    m = re.search(r"^entity\s+%s\s+is\s*$" % re.escape(entity), text,
                  re.M | re.I)
    if not m:
        sys.exit("COMPOSE4 ABORT: no entity %s" % entity)
    body = text[m.end():]
    e = re.search(r"^\s*end\s+(entity|%s)\b" % re.escape(entity), body,
                  re.M | re.I)
    if not e:
        sys.exit("COMPOSE4 ABORT: no end of entity %s" % entity)
    body = body[:e.start()]

    k = re.search(r"^\s*%s\s*\(\s*$" % kw, body, re.M | re.I)
    if not k:
        return []
    rest = body[k.end():]
    # Walk to the matching close paren at depth 0.
    depth, out, cur = 1, [], ""
    for ch in rest:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                break
        cur += ch
    for ln in cur.split("\n"):
        ln = strip_comment(ln).rstrip()
        if ln.strip():
            out.append(ln.strip())
    # A declaration may span several lines (`seq_region_lock`'s REG_SIZE
    # integer_vector does).  Rejoin on DEPTH-0 semicolons so each element of
    # the returned list is exactly one declaration.  Splitting on newlines
    # instead is what made the first run of this script abort on
    # '8192, 1024, 1024, 4096,'.
    joined = " ".join(out)
    decls, depth, cur2 = [], 0, ""
    for ch in joined:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == ";" and depth == 0:
            decls.append(cur2.strip())
            cur2 = ""
        else:
            cur2 += ch
    if cur2.strip():
        decls.append(cur2.strip())
    return [d for d in decls if d]


def parse_generics(lines):
    """name -> default expression.  A generic with no default is an error."""
    g = {}
    for ln in lines:
        ln = ln.strip().rstrip(";")
        if not ln:
            continue
        m = GEN_RE.match(ln)
        if not m:
            sys.exit("COMPOSE4 ABORT: unparsed generic %r" % ln)
        g[m.group(1)] = m.group(3).strip()
    return g


def parse_ports(lines, entity):
    """[(name, dir, type)] with the trailing `:= default` removed."""
    ports = []
    for ln in lines:
        s = ln.strip().rstrip(";").strip()
        if not s:
            continue
        m = PORT_RE.match(s)
        if not m:
            sys.exit("COMPOSE4 ABORT: %s: unparsed port line %r" % (entity, s))
        name, direction, typ = m.group(1), m.group(2), m.group(3)
        # Strip a port default.  `:=` cannot appear inside a type mark here.
        typ = typ.split(":=")[0].strip().rstrip(")").strip() \
            if typ.strip().endswith(")") and ":=" in typ else typ
        if ":=" in typ:
            typ = typ.split(":=")[0].strip()
        typ = typ.rstrip(";").strip()
        ports.append((name, direction, typ))
    return ports


def subst(expr, gmap):
    """Replace generic identifiers by their effective literal expressions.

    Iterated to a fixed point because a default may name another generic.  An
    expression that still names a generic after the cap is an abort, not a
    silently wrong width.
    """
    if not gmap:
        return expr
    # `REG_SIZE'length` must become a NUMBER, not `(4096, 4096, ...)'length`:
    # an aggregate literal has no 'length attribute and Vivado would reject it.
    # Counted from the depth-0 commas of the aggregate, so it tracks the file.
    for g, v in gmap.items():
        v = v.strip()
        if not (v.startswith("(") and v.endswith(")")):
            continue
        depth, n = 0, 1
        for ch in v[1:-1]:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "," and depth == 0:
                n += 1
        expr = re.sub(r"\b%s'length\b" % re.escape(g), str(n), expr,
                      flags=re.I)
    pat = re.compile(r"\b(%s)\b" % "|".join(
        sorted(map(re.escape, gmap), key=len, reverse=True)))
    prev = None
    cur = expr
    for _ in range(8):
        if cur == prev:
            break
        prev = cur
        cur = pat.sub(lambda m: "(%s)" % gmap[m.group(1)], cur)
    if pat.search(cur):
        sys.exit("COMPOSE4 ABORT: generic substitution did not converge on %r"
                 % expr)
    return cur


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", default=os.path.join(REPO, "rtl"))
    ap.add_argument("--fk33-rtl", default=os.path.join(HERE, "rtl"))
    ap.add_argument("--out", default=os.path.join(HERE, "rtl",
                                                  "compose4_top.vhd"))
    # A SUBSET top, for the case where the full composition will not fit in the
    # box's memory or the night's hours.  `--instances b_gdn,c_attn,d_*` gives
    # a B+C+D-only top that is directly comparable to the 217,381 booking, and
    # `--entity` names it so it cannot be confused with the full one.
    ap.add_argument("--instances", default="",
                    help="comma-separated instance names to keep; default all")
    ap.add_argument("--entity", default="compose4_top")
    # LEVER C.  "distributed" is the configuration STEP 2 is asking about;
    # "regs" reproduces the pre-lever composition and is the attribution
    # control.  Anything else is rejected here rather than silently meaning
    # "regs" three levels down in matvec_core.
    ap.add_argument("--cb-style", default="distributed",
                    choices=["distributed", "regs"])
    # THE NORM LEVER'S CONTROL.  There is no generic for it: `d_norm` is an
    # extraction of llama_top's `gvr` block, so the ONLY way to draw the
    # pre-lever configuration is to point this at an extraction taken from a
    # pre-RMSWIRE llama_top.  Kept as an explicit, named, loud option rather
    # than as a way to disable the staleness guard, because the guard exists to
    # catch an ACCIDENTALLY stale file and this is a DELIBERATE one.  The guard
    # is not bypassed here, it is INVERTED: with --norm-entity naming the flat
    # variant, the generator aborts if the file DOES bind rmsnorm_rs_mem.
    ap.add_argument("--norm-entity", default="ooc_normadapt",
                    choices=["ooc_normadapt", "ooc_normadapt_flat"])
    ap.add_argument("--norm-file", default="")
    # THE GAIN IMAGE, TRACK ROUTE3, 2026-08-31.  Every composed draw before
    # this option carried NORM_W_IMAGE = "" (the synthetic ramp), so the
    # composed BRAM figure never included the gain store.  GAIN16 replaced
    # that store with an 11-bit codebook index (99 RAMB36, MEASURED OOC) plus
    # a 1,567-entry table, and the question ROUTE3 answers is whether the
    # composition still ROUTES with it in.  The path is BAKED INTO the
    # generated file's d_norm generic map, exactly as CB_STYLE is, because
    # the PnR Tcl passes no generics on its synth_design line.  Default ""
    # preserves every existing number.
    ap.add_argument("--norm-w-image", default="")
    a = ap.parse_args()

    global INSTANCES
    INSTANCES = [(i[0], i[1], i[2],
                  (dict(i[3], CB_STYLE='"%s"' % a.cb_style)
                   if i[0] == "a_eng" else i[3]))
                 for i in INSTANCES]
    if a.norm_w_image:
        INSTANCES = [(i[0], i[1], i[2],
                      (dict(i[3], NORM_W_IMAGE='"%s"' % a.norm_w_image)
                       if i[0] == "d_norm" else i[3]))
                     for i in INSTANCES]
    if a.norm_entity != "ooc_normadapt":
        INSTANCES = [(i[0], a.norm_entity, i[2], i[3]) if i[0] == "d_norm"
                     else i for i in INSTANCES]
        SRC_FILE[a.norm_entity] = (
            "RTL", a.norm_file or ("%s_top.vhd" % a.norm_entity))
    if a.instances:
        keep = set(x.strip() for x in a.instances.split(",") if x.strip())
        unknown = keep - set(i[0] for i in INSTANCES)
        if unknown:
            sys.exit("COMPOSE4 ABORT: unknown instance(s) %s"
                     % ",".join(sorted(unknown)))
        INSTANCES = [i for i in INSTANCES if i[0] in keep]

    roots = {"RTL": a.rtl, "FK33": a.fk33_rtl}

    top_ports = []          # (name, dir, type)
    inst_blocks = []
    summary = []

    for inst, ent, _which, over in INSTANCES:
        which, fname = SRC_FILE[ent]
        path = os.path.join(roots[which], fname)
        if not os.path.exists(path):
            sys.exit("COMPOSE4 ABORT: missing %s" % path)
        text = open(path).read()

        # THE STALE-EXTRACTION GUARD, and it has teeth: it FAILS on the
        # ooc_normadapt_top.vhd every run of this generator before 2026-08-30
        # consumed, because that one instantiated the flat `rmsnorm_rs`.  A
        # stale extraction is otherwise silent -- it parses, elaborates,
        # synthesises, and reports 62,053 CLB LUT that the design does not
        # have.  Keyed on the INSTANTIATION, not on a comment: HEAD's
        # extracted file mentions `rmsnorm_rs_mem` in prose at line 312 while
        # the binding is at line 485, so a substring test on the whole file
        # would pass over an extraction that binds the flat unit.
        if ent == "ooc_normadapt_flat":
            # THE GUARD, INVERTED.  This entity exists ONLY to draw the
            # pre-lever configuration, so a file that DOES bind the
            # memory-backed unit here is just as wrong as a stale one is in the
            # other direction -- and it would silently report the levered area
            # under the control's name, which is the worse of the two errors.
            if re.search(r"entity\s+work\.rmsnorm_rs_mem\b", text):
                sys.exit(
                    "COMPOSE4 ABORT: %s binds rmsnorm_rs_mem, but it was asked\n"
                    "  for as the FLAT pre-lever control.  Extract it from a\n"
                    "  llama_top from BEFORE TRACK RMSWIRE (`47c9d9c`), e.g.\n"
                    "    git show 012d28d~1:rtl/llama_top.vhd > /tmp/pre.vhd\n"
                    "    python3 sim/ooc_normadapt_extract.py /tmp/pre.vhd \\\n"
                    "            %s ooc_normadapt_flat" % (path, path))
            if not re.search(r"entity\s+work\.rmsnorm_rs\b", text):
                sys.exit("COMPOSE4 ABORT: %s binds neither rmsnorm_rs nor "
                         "rmsnorm_rs_mem." % path)
        if ent == "ooc_normadapt":
            if not re.search(r"entity\s+work\.rmsnorm_rs_mem\b", text):
                sys.exit(
                    "COMPOSE4 ABORT: %s does not instantiate rmsnorm_rs_mem.\n"
                    "  This is a STALE extraction: rtl/llama_top.vhd's `gvr`\n"
                    "  block has bound rmsnorm_rs_mem since TRACK RMSWIRE\n"
                    "  (`47c9d9c`).  Re-run:\n"
                    "    python3 sim/ooc_normadapt_extract.py \\\n"
                    "        rtl/llama_top.vhd %s ooc_normadapt" % (path, path))

        gdefs = parse_generics(clause(text, ent, "generic"))
        for k in over:
            if k not in gdefs:
                sys.exit("COMPOSE4 ABORT: %s has no generic %s" % (ent, k))
        gmap = dict(gdefs)
        gmap.update(over)

        ports = parse_ports(clause(text, ent, "port"), ent)
        shared = SHARED.get(ent, SHARED["_default"])

        maps = []
        nbits_exported = 0
        for name, direction, typ in ports:
            if name in shared:
                maps.append("      %s => %s" % (name, shared[name]))
                continue
            tp = subst(typ, gmap)
            pn = "%s_%s" % (inst, name)
            top_ports.append((pn, direction, tp))
            maps.append("      %s => %s" % (name, pn))
            nbits_exported += 1

        gl = ""
        if over:
            gl = ("    generic map(\n"
                  + ",\n".join("      %s => %s" % (k, v)
                               for k, v in sorted(over.items()))
                  + "\n    )\n")
        inst_blocks.append(
            "  -- %s : %s%s\n  %s : entity work.%s\n%s    port map(\n%s\n    );\n"
            % (inst, ent,
               ("  " + " ".join("%s=%s" % (k, v) for k, v in sorted(over.items()))
                if over else "  (all generics at their file defaults)"),
               inst, ent, gl, ",\n".join(maps)))
        summary.append((inst, ent, len(ports), nbits_exported,
                        " ".join("%s=%s" % (k, v) for k, v in sorted(over.items()))
                        or "(defaults)"))

    hdr = [
        "-- hw/fk33/rtl/compose4_top.vhd -- GENERATED by hw/fk33/gen_compose4_top.py.",
        "-- DO NOT HAND-EDIT; edit the generator.  TRACK COMPOSE4, 2026-08-29.",
        "--",
        "-- ONE synthesis top carrying subsystems A, B, C and D together at the real",
        "-- Qwen3.5-9B shape, so the composition can be PLACED and ROUTED rather than",
        "-- summed from independent out-of-context synthesis runs.",
        "--",
        "-- WHAT THIS ESTABLISHES: fit, placement, routability and post-route timing.",
        "-- WHAT IT DOES NOT ESTABLISH: arithmetic.  A routed design is not a correct",
        "-- one, and subsystems B and C have never run on this silicon at all.",
        "--",
        "-- THE SUBSYSTEMS ARE NOT WIRED TO EACH OTHER.  How they are wired is board",
        "-- row N2 -- the host-seam contract -- and that is a decision reserved for",
        "-- Oren.  They share `core_clk` and `core_rst`; `fk33_engine` additionally",
        "-- takes `hbm_aclk`, the second domain the card runs.  Both domains are",
        "-- 5.000 ns / 200.000 MHz in the routed shell build",
        "-- (hw/fk33/results/build_e2e_2026-08-29/e2e_timing_routed_summary.rpt).",
        "--",
        "-- BOTH AREA LEVERS ARE IN THIS FILE as of 2026-08-30 (TRACK ROUTE2):",
        "--   * lever C, `a_eng`'s CB_STYLE generic, printed in the instance list below;",
        "--   * the norm lever, which is NOT a generic -- `d_norm` is an extraction of",
        "--     rtl/llama_top.vhd's `gvr` block and HEAD's `gvr` binds rmsnorm_rs_mem.",
        "-- The generator ABORTS if the extraction it is handed binds the flat unit.",
        "--",
    ]
    if a.norm_w_image:
        hdr += [
            "-- NORM_W_IMAGE IS REAL HERE (TRACK ROUTE3): %s" % a.norm_w_image,
            "-- The gain store is GAIN16's 11-bit codebook index plus a",
            "-- 1,567-entry table, 99 RAMB36 MEASURED OOC, so this top's BRAM",
            "-- total INCLUDES the gain image and no addition is needed before",
            "-- comparing it to a pb_core budget.",
        ]
    else:
        hdr += [
            "-- NORM_W_IMAGE IS EMPTY HERE, as it was in every row of the booking this",
            "-- is compared against.  TRACK NWROM MEASURED that a real gain image costs",
            "-- +32,943 CLB LUT, so that must be ADDED to any number this top produces",
            "-- before comparing it to a pb_core budget.",
        ]
    hdr += [
        "--",
        "-- Instances, and the generics each carries:",
    ]
    for inst, ent, np, ne, gs in summary:
        hdr.append("--   %-8s %-16s %3d ports, %3d exported   %s"
                   % (inst, ent, np, ne, gs))
    hdr += [
        "--",
        "-- Regenerate with:  python3 hw/fk33/gen_compose4_top.py",
        "",
        "-- NOTE: this file is SYNTHESIS ONLY.  It instantiates BUFGCE from",
        "-- UNISIM, so GHDL cannot analyse it without -P<unisim>.  That is not a",
        "-- loss: it is not simulable in any useful sense either, because the nine",
        "-- instances are not wired to each other.",
        "",
        "library ieee;",
        "use ieee.std_logic_1164.all;",
        "use ieee.numeric_std.all;",
        "use work.util_pkg.all;      -- clog2, used by attn_block's port widths",
        "library unisim;",
        "use unisim.vcomponents.all; -- BUFGCE",
        "",
        "entity %s is" % a.entity,
        "  generic(",
        "    -- FALSE leaves the clocks on local routing.  Only ever useful for",
        "    -- reproducing the measurement that made the buffers necessary.",
        "    CLK_BUFG : boolean := true",
        "  );",
        "  port(",
        "    -- the two clocks the card runs, both 5.000 ns",
        "    core_clk     : in  std_logic;",
        "    core_rst     : in  std_logic;",
        "    core_aresetn : in  std_logic;",
        "    hbm_aclk     : in  std_logic;",
        "",
    ]

    w = max(len(p[0]) for p in top_ports)
    body = []
    last_inst = None
    for pn, direction, tp in top_ports:
        pref = pn.split("_")[0] + "_" + pn.split("_")[1]
        if pref != last_inst:
            body.append("")
            last_inst = pref
        body.append("    %-*s : %-5s %s;" % (w, pn, direction, tp))
    # The final port declaration must not carry a semicolon.
    for i in range(len(body) - 1, -1, -1):
        if body[i].strip():
            body[i] = body[i].rstrip(";")
            break

    out = hdr + body + [
        "  );",
        "end entity;",
        "",
        "architecture rtl of %s is" % a.entity,
        "  signal core_clk_i : std_logic;",
        "  signal hbm_aclk_i : std_logic;",
        "begin",
        "",
        "  gbufg : if CLK_BUFG generate",
        "    u_bufg_core : BUFGCE port map(I => core_clk, CE => '1', O => core_clk_i);",
        "    u_bufg_hbm  : BUFGCE port map(I => hbm_aclk, CE => '1', O => hbm_aclk_i);",
        "  end generate;",
        "  gnobufg : if not CLK_BUFG generate",
        "    core_clk_i <= core_clk;",
        "    hbm_aclk_i <= hbm_aclk;",
        "  end generate;",
        "",
    ] + inst_blocks + [
        "end architecture;",
        "",
    ]

    with open(a.out, "w") as fh:
        fh.write("\n".join(out))

    print("COMPOSE4_GEN wrote %s : %d instances, %d top-level ports"
          % (a.out, len(INSTANCES), len(top_ports) + 4))
    for inst, ent, np, ne, gs in summary:
        print("COMPOSE4_GEN   %-8s %-16s ports=%d exported=%d  %s"
              % (inst, ent, np, ne, gs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
