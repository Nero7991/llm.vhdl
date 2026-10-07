#!/usr/bin/env python3
"""hw/jc/card/gen_ooc27_top.py -- Task 10.  Emits jc_ooc27_top.vhd: ONE OOC
synthesis top carrying fk33_engine (subsystem A), fk33_seam (the host seam)
and fk33_card (subsystems B/C/D, the 27B wrapper) in the SAME placement and
routing context, so hw/jc/card/ooc_card_200.tcl does not reproduce the
standalone-OOC artifact docs/debugging/2026-09-30_27b-fits-vu35p-ooc-timing-
artifact.md measured on fk33_card ALONE: 69.9 MHz, ~2x pessimistic against
the shipped in-context build, with the engine and the real card<->engine
dataflow both absent.

WHY THIS TOP, AND NOT THE OTHER TWO TASK-10 OPTIONS.  "fk33_card alone" IS
that artifact; reusing it would just reproduce known noise.  "jc_card_top's
wrapper without the HBM IP" needs the full BD (create_project, jc_card_bd.tcl,
generate_target, make_wrapper) and a way to exclude the HBM IP's netlist from
an out-of-context run that nothing in this tree already does -- unverified
Tcl surgery on a generated file this task may not hand-edit.  This top adds
back two of the three things that debug note found ABSENT from the artifact
(the engine, and the real nets between it and the card), using only the
entities' own committed RTL and no block design, no HBM, no PCIe, no clk_wiz.

WHAT IS WIRED, AND WHY THOSE SIGNALS AND NO OTHERS.  Every pair below is
transcribed verbatim from hw/jc/card/jc_card_bd.tcl's own connect_bd_net
calls between these three cells (SEAM_CARD: "the host seam, fk33_seam <->
card"; A_SEAM: "the A seam, card <-> eng"), with one exception documented at
AXI_CTRL below.  Transcription is checked, not trusted: every pair is looked
up against the ENTITIES' OWN parsed ports, and a width or direction mismatch
aborts this generator (GENOOC27 ABORT) rather than producing a file that
fails first in Vivado, hours in.

  SEAM_CARD (41 pairs, jc_card_bd.tcl's "the host seam, fk33_seam <-> card")
  A_SEAM    (12 pairs, jc_card_bd.tcl's "the A seam, card <-> eng")
  AXI_CTRL  (10 pairs, NOT a verbatim transcription): the real BD arbitrates
            eng's s_axi AW/W/B/AR/R slave between the host (axil2eng) and the
            card (card/a, a WRITE-ONLY AXI4-Lite master: no AR/R channel at
            all) through a 2:1 smartconnect.  There is no host master in this
            OOC top, so card/a is connected DIRECTLY to eng/s_axi's AW/W/B
            channels, which this generator checks are width- and direction-
            compatible (they are: both are the 12-bit-address, 32-bit-data
            AXI4-Lite the real smartconnect also carries unchanged). eng's
            AR/R channel, which only the host ever drove, is EXPORTED (fix
            round 1, M3), not tied off: the real BD's smartconnect puts the
            host's own master on all of s_axi, AR/R included, so the whole
            channel is BD-connected-outside-scope by bd_connected_ports()'s
            own general rule below, and tying it off was an unnecessary
            special case that happened to remove the register read mux.

WHAT IS EXPORTED, VS. WHAT IS TIED OFF (fix round 1, CRITICAL C1).  Every
remaining port of all three instances is checked against
bd_connected_ports(): does jc_card_bd.tcl connect it to ANYTHING.  If it
does -- the engine's 28 HBM AXI masters, the card's 5 HBM AXI masters, the
card's bst_*/kv_*_* ports (the real BD's grant arbiter, bcgrant, is outside
this task's three-instance scope but still outside-scope-connected), both
AXI4-Lite host-control slaves (eng's s_axix, seam's s_axi) -- it is EXPORTED
to the top level, uniquely prefixed (eng_/seam_/card_), so nothing BD-
connected can be optimised away as dead logic (the same reason
hw/fk33/gen_compose4_top.py exports rather than stimulates its own nine
co-resident instances). If jc_card_bd.tcl does NOT connect it to anything --
card's debug/observability taps (obs_wsum and its siblings, smp_valid/v/idx/
done, bst_busy/done/err, a_jobs_issued), its dead "m_*" HBM read bus, a
scatter of AXI SIZE/BURST/WSTRB/RESP/ID fields across kv/bst/eng's HBM
masters -- it is TIED OFF instead: `open` for an output, a quiescent
constant for an input. The ORIGINAL version of this generator exported
EVERYTHING unwired, including card/obs_wsum -- the exact debug hash (a
60-level, 8-step multiply-by-31-add, fk33_llama_top.vhd:8243) 2026-09-30's
"70 MHz" fk33_card-alone OOC number traced to, and which the real build
never pays for because nothing drives it (build 20's own log: "port
'obs_wsum' of module 'bd_card_0' is unconnected"). Exporting it here kept it
alive the artifact note's own fk33_card-alone measurement never had any
other reason to; test_gen_ooc27_top.py's bd_unconnected_* tests are this
mistake's regression tests.

WHAT THIS DOES NOT ESTABLISH.  That the composed design really meets 200 MHz
in-context.  docs/debugging/2026-09-30_27b-fits-vu35p-ooc-timing-artifact.md
leaves the real composed fmax OPEN, needing the actual Jungle Cat block
design (PCIe-less; PCIe/HBM/pinout for the FK33 case). This top restores two
of that note's three missing-context items (the engine; the real dataflow to
it) with real area and real nets; it still has no floorplan, so a result
from it is OOC evidence towards the open question, not an answer to it.

Usage:
    python3 hw/jc/card/gen_ooc27_top.py <repo_root> [--out PATH]

<repo_root> MUST be the PREPARED TREE's root (run_ooc27.sh's <root>/src,
after the levers patch and the 27B hw/fk33/rtl/fk33_card.vhd regeneration),
not necessarily this repository: fk33_card.vhd's own port WIDTHS change
between models (hw_addr/hr_addr: 14 bits at 9B, 15 at 27B -- docs/debugging/
2026-09-30_27b-fits-vu35p-ooc-timing-artifact.md), so this generator reads
whatever is actually at that path, never a cached width.  Pointed at THIS
repository (the committed 9B fk33_card.vhd) it still runs, as a smoke test:
see test_gen_ooc27_top.py.

Reuses hw/fk33/gen_compose4_top.py's own entity-clause/port/generic parser
(clause, parse_ports, parse_generics, subst) by direct file import -- that
module is not edited or duplicated, only read, so TRACK COMPOSE4's own
mutation-tested parser is the one checking these ports too.
"""
import argparse
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load_compose4(repo_root):
    path = os.path.join(repo_root, "hw", "fk33", "gen_compose4_top.py")
    if not os.path.exists(path):
        sys.exit("GENOOC27 ABORT: no %s (not a real tree root?)" % path)
    spec = importlib.util.spec_from_file_location("gen_compose4_top", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---- the entities this top instantiates, and where to find each one's RTL,
#      relative to <repo_root> --------------------------------------------
ENTITY_FILE = {
    "eng":  ("hw/fk33/rtl/fk33_engine.vhd", "fk33_engine"),
    "seam": ("rtl/fk33_seam.vhd", "fk33_seam"),
    "card": ("hw/fk33/rtl/fk33_card.vhd", "fk33_card"),
}

# ---- generic overrides, matching jc_card_bd.tcl's own CONFIG.* for these
#      two module-reference cells (build 27B-1's shape; fk33_card has none).
# Fix round 1, I1: jc_card_bd.tcl:299 ALSO sets CONFIG.USE_XEXP_PORT {true}
# on eng (the original generator only carried CB_STYLE); test_eng_generics_
# match_the_bd_exactly diffs every eng CONFIG.* the BD sets against this
# dict, so a third one added there and missed here fails loudly, not silently.
ENG_GENERICS = {"CB_STYLE": '"distributed"', "USE_XEXP_PORT": "true"}

# REGMAX/HADDR_W default to build 27B-1's own jc_card_bd.tcl values (CONFIG.REGMAX
# 17408, CONFIG.HADDR_W 15).  fk33_seam's architecture refuses any HADDR_W that is
# not exactly clog2(REGMAX) in both directions (the generic's own comment: "THEY
# CANNOT DRIFT"), and fk33_card's hw_addr/hr_addr port WIDTH changes between models
# (14 bits at 9B, 15 at 27B -- docs/debugging/2026-09-30_27b-fits-vu35p-ooc-timing-
# artifact.md), so a tree whose fk33_card.vhd is not the 27B one needs a different
# --haddr-w/--regmax pair or this generator's own width check aborts it (correctly:
# see test_gen_ooc27_top.py's 9B smoke test, which passes --haddr-w 14 --regmax 16384).
SEAM_GENERICS_FIXED = {
    "CAPS_CTX": "16384", "CAPS_EMBD": "5120", "CAPS_LAYER": "64",
    "CAPS_VOCAB": "248320", "MAXPOS": "16384", "CAP_NORM_HBM": "1",
}

# ---- SEAM_CARD: jc_card_bd.tcl's "the host seam, fk33_seam <-> card" list,
#      transcribed verbatim (seam port, card port) in the Tcl's own order.
SEAM_CARD = [
    ("d_busy", "busy"), ("d_tok_done", "tok_done"), ("d_err", "err"),
    ("d_err_code", "err_code"), ("d_err_step", "err_step"),
    ("d_steps_done", "steps_done"), ("d_raddr", "d_raddr"),
    ("d_ren", "d_ren"), ("hr_data", "hr_data"), ("obs_issue", "obs_issue"),
    ("obs_tok_pos", "obs_tok_pos"), ("smp_token", "smp_token"),
    ("smp_n", "smp_n"), ("smp_exp", "smp_exp"),
    ("d_x_exp_out", "x_exp_out"), ("f_smp_ovf", "err_smp_ovf"),
    ("f_lost_beat", "err_lost_beat"), ("f_gate_drop", "err_gate_drop"),
    ("f_unit_stub", "err_unit_stub"), ("f_e_coll", "err_e_coll"),
    ("f_kv_err", "kv_err"), ("d_go", "go"), ("d_abort", "abort"),
    ("d_tbl_len", "tbl_len"), ("d_host_x_exp", "host_x_exp"),
    ("d_rel_mask", "rel_mask"), ("d_tok_ack", "tok_ack"),
    ("d_rdata", "d_rdata"), ("d_rvalid", "d_rvalid"), ("hw_we", "hw_we"),
    ("hw_reg", "hw_reg"), ("hw_addr", "hw_addr"), ("hw_data", "hw_data"),
    ("hr_reg", "hr_reg"), ("hr_addr", "hr_addr"),
    ("d_a_arena", "a_arena_base"), ("d_bst_base", "bst_state_base"),
    ("d_bcb_base", "bst_const_base"), ("d_seq_rst", "seq_rst"),
    ("d_kv_k_base", "kv_k_base"), ("d_kv_v_base", "kv_v_base"),
]
assert len(SEAM_CARD) == 41, len(SEAM_CARD)

# ---- A_SEAM: jc_card_bd.tcl's "the A seam, card <-> eng" list, verbatim
#      (card port, eng port) in the Tcl's own order.
A_SEAM = [
    ("a_job_index", "job_index"), ("a_x_we", "d_x_we"),
    ("a_x_waddr", "d_x_waddr"), ("a_x_wdata", "d_x_wdata"),
    ("a_x_exp", "d_x_exp"), ("a_y_we", "d_y_we"), ("a_y_addr", "d_y_addr"),
    ("a_y_data", "d_y_data"), ("a_y_mask", "d_y_mask"),
    ("a_y_exp", "d_y_exp"), ("a_job_done", "d_job_done"),
    ("a_job_err", "d_job_err"),
]
assert len(A_SEAM) == 12, len(A_SEAM)

# ---- AXI_CTRL: NOT from jc_card_bd.tcl (see the module docstring): card/a's
#      AW/W/B channels direct onto eng/s_axi's, replacing the real build's
#      2:1 smartconnect because there is no host master here.
AXI_CTRL = [
    ("a_awvalid", "s_axi_awvalid"), ("a_awready", "s_axi_awready"),
    ("a_awaddr", "s_axi_awaddr"), ("a_wvalid", "s_axi_wvalid"),
    ("a_wready", "s_axi_wready"), ("a_wdata", "s_axi_wdata"),
    ("a_wstrb", "s_axi_wstrb"), ("a_bvalid", "s_axi_bvalid"),
    ("a_bready", "s_axi_bready"), ("a_bresp", "s_axi_bresp"),
]
assert len(AXI_CTRL) == 10, len(AXI_CTRL)

# Fix round 1, M3: eng's s_axi AR/R channel used to be tied off here on the
# theory that card/a (the only thing this generator wires onto s_axi) has no
# AR/R to drive it. That is true, but irrelevant: the real BD's smartconnect
# ALSO puts the host's own master onto s_axi (axil2eng, outside the three-
# cell scope), which DOES use AR/R, so s_axi's AR/R channel IS a port the BD
# connects to something outside the three cells and belongs in the general
# bd_connected_ports() export rule below, not a special tie-off. Removed.

# clk/hbm_aclk/compute_halt: shared RAW top-level ports, by (inst, port).
# compute_halt is false-pathed by ooc_card_200.tcl (build_card.tcl:342's own
# treatment: CATTRIP is ruled asynchronous/quasi-static, no synchroniser), so
# it stays a plain top port with no registering needed.
#
# rst/rstn are DELIBERATELY NOT here (fix round 1, I4): the first cut of this
# generator put them straight in SHARED, so the bare top-level `rst` port fed
# every reset input across all three instances directly -- an un-replicated
# single port driving on the order of 2.7e5 flops, not something a real
# design (or a real OOC harness) would ever present to the router. `rst`/
# `rstn` instead feed a 2-flop registered buffer on `clk` (REG_STAGES below),
# and the REGISTERED signal is what actually reaches seam/card/eng.
SHARED = {
    ("eng", "core_clk"): "clk", ("eng", "hbm_aclk"): "clk",
    ("eng", "compute_halt"): "compute_halt",
    ("seam", "clk"): "clk",
    ("card", "clk"): "clk",
}

# fix round 1, I4: the registered reset buffer. `rst`/`rstn` (raw top ports)
# feed stage 1 on `clk`; stage 2's output (`rst_r2`/`rstn_r2`) is what reaches
# seam/card (active-high `rst_r2`) and eng/core_aresetn (active-low `rstn_r2`).
REG_RST = {"seam": "rst_r2", "card": "rst_r2"}
REG_RSTN = {"eng": "rstn_r2"}


# ---- fix round 1, C1: the BD-connectivity audit. A port the BD leaves
# unconnected (nothing in this tree drives/reads it, like card/obs_wsum)
# must never be exported: exporting it makes it an OOC top-level port, which can never
# be optimised away, so any logic feeding a debug tap like obs_wsum (a
# 60-level, 8-step multiply-by-31-add hash, fk33_llama_top.vhd:8243) stays
# alive and dominates the routed critical path -- exactly the artifact
# docs/debugging/2026-09-30_27b-fits-vu35p-ooc-timing-artifact.md measured
# on fk33_card ALONE. The real build never pays for it: build 20's own
# synthesis log reports `port 'obs_wsum' of module 'bd_card_0' is
# unconnected`, and Vivado drops the dead logic behind an unconnected
# module-reference output.
#
# bd_connected_ports() answers "did jc_card_bd.tcl connect this port to
# ANYTHING" by scanning its own connect_bd_net/connect_bd_intf_net calls --
# not a hand-maintained list of names, which is exactly the kind of list
# this project's own house style distrusts (CLAUDE.md: "grep the entity
# declarations for the SHAPE"). A flat `get_bd_pins eng/X` reference marks
# X connected outright; a bus `get_bd_intf_pins eng/m00_axi` reference marks
# every one of eng's OWN ports named `m00_axi_<suffix>` connected, for
# <suffix> a real AXI4/AXI4-Lite channel signal -- not a bare prefix match,
# which would conflate card's `a` AXI4-Lite master (a_awvalid, a_wdata, ...)
# with its UNRELATED `a_job_index`/`a_x_we`/`a_arena_base`-style "A seam"
# ports, all of which also happen to start with `a_`.
# DELIBERATELY NO *id FIELDS (awid/bid/arid/rid) in this set. Fix round 2
# correction: the ORIGINAL comment here claimed "HBM's own AXI3 SAXI
# interface has none" -- that is FALSE. HBM's SAXI_xx interfaces DO carry
# AXI_xx_ARID/AWID/BID/RID (MEASURED: jc_card_bd.tcl's own interface-level
# `connect_bd_intf_net [get_bd_intf_pins eng/m00_axi] [get_bd_intf_pins
# hbm/SAXI_01]` and its 27 siblings wire ALL of eng's m*_axi sub-signals,
# ID fields included, to the matching HBM SAXI port -- there is no separate,
# narrower connection that could omit them). So bd_connected_ports() would
# mark eng's awid/arid/bid/rid CONNECTED too, if *id were in AXI_SUFFIXES.
# The exclusion is deliberate anyway, and is harmless for a different
# reason: eng drives its own m*_axi_awid/arid to a constant '0' internally
# (fk33_engine.vhd:1422 `m00_axi_arid <= (others => '0')`, :1432 the
# matching `m00_axi_awid` line, each repeated per master) and never reads
# back bid/rid at all. Tying these ports off at this OOC top (rather than
# exporting them as live, BD-connected ports) therefore changes nothing
# about what eng actually does: it already ignores the real connection on
# both the read side (bid/rid, never consumed) and effectively on the write
# side (awid/arid, overridden by the constant driver before it ever leaves
# eng). This is also why test_gen_ooc27_top.py checks for the *id suffixes
# by name rather than trusting this set to stay right by inspection: the
# reasoning above is specific to eng's own RTL, not a general BD fact, and
# would need re-checking if eng's own id-driving ever changed.
AXI_SUFFIXES = {
    "awvalid", "awready", "awaddr", "awlen", "awsize", "awburst", "awprot",
    "awcache", "awlock", "awqos", "awregion",
    "wvalid", "wready", "wdata", "wstrb", "wlast",
    "bvalid", "bready", "bresp",
    "arvalid", "arready", "araddr", "arlen", "arsize", "arburst", "arprot",
    "arcache", "arlock", "arqos", "arregion",
    "rvalid", "rready", "rdata", "rlast", "rresp",
}
BD_CELL_NAME = {"eng": "eng", "seam": "fk33_seam_0", "card": "card"}


def bd_connected_ports(bd_text, tag, ports):
    """{port name} this tag's cell is connected to ANYTHING by jc_card_bd.tcl
    -- whether to another of the three cells (seam<->card, card<->eng; this
    generator's own SEAM_CARD/A_SEAM/AXI_CTRL tables are a SUBSET of this)
    or to something outside the three-cell scope (HBM, a host AXI4-Lite
    slave via axil2eng/engctl, bcgrant, a clock, a reset, CATTRIP)."""
    cell = BD_CELL_NAME[tag]
    connected = set()
    for ref in re.findall(r"get_bd_pins\s+([\w./]+)", bd_text):
        if "/" not in ref:
            continue
        c, pin = ref.split("/", 1)
        if c == cell:
            connected.add(pin)
    port_names = {nm for nm, _d, _t in ports}
    for ref in re.findall(r"get_bd_intf_pins\s+([\w./]+)", bd_text):
        if "/" not in ref:
            continue
        c, intf = ref.split("/", 1)
        if c != cell:
            continue
        if intf in port_names:
            connected.add(intf)
        prefix = intf + "_"
        for nm in port_names:
            if nm.startswith(prefix) and nm[len(prefix):] in AXI_SUFFIXES:
                connected.add(nm)
    return connected


def width_of(effective_type):
    """("std_logic"|"std_logic_vector"|"signed"|"unsigned", width:int), from
    a type string with every generic already substituted to a literal
    (gen_compose4_top.subst's job).  Aborts on anything it cannot evaluate,
    rather than guessing: a width this cannot parse is a width this cannot
    check, and an unchecked pair is exactly the risk this generator exists
    to remove."""
    t = effective_type.strip()
    if t == "std_logic":
        return ("std_logic", 1)
    m = re.match(
        r"^(std_logic_vector|signed|unsigned)\s*\(\s*(.+?)\s+downto\s+(.+?)\s*\)$",
        t)
    if not m:
        sys.exit("GENOOC27 ABORT: cannot parse effective type %r" % effective_type)
    base, hi_s, lo_s = m.group(1), m.group(2), m.group(3)
    if not re.match(r"^[0-9+\-*/() ]+$", hi_s) or not re.match(r"^[0-9+\-*/() ]+$", lo_s):
        sys.exit("GENOOC27 ABORT: non-numeric bound in %r (an unbound generic "
                  "survived substitution)" % effective_type)
    hi, lo = eval(hi_s), eval(lo_s)
    return (base, hi - lo + 1)


class Entity:
    def __init__(self, tag, repo_root, c4):
        relpath, name = ENTITY_FILE[tag]
        path = os.path.join(repo_root, relpath)
        if not os.path.exists(path):
            sys.exit("GENOOC27 ABORT: no %s" % path)
        text = open(path).read()
        self.tag = tag
        self.name = name
        glines = c4.clause(text, name, "generic")
        self.generics = c4.parse_generics(glines) if glines else {}
        plines = c4.clause(text, name, "port")
        if not plines:
            sys.exit("GENOOC27 ABORT: entity %s has no port clause" % name)
        self.ports = c4.parse_ports(plines, name)          # [(nm, dir, typ)]
        self.port_by_name = {nm: (d, t) for nm, d, t in self.ports}

    def gmap(self, overrides, c4):
        g = dict(self.generics)
        g.update(overrides)
        return g

    def effective_width(self, portname, overrides, c4):
        if portname not in self.port_by_name:
            sys.exit("GENOOC27 ABORT: entity %s has no port %r" % (self.name, portname))
        direction, typ = self.port_by_name[portname]
        eff = c4.subst(typ, self.gmap(overrides, c4)) if self.generics else typ
        return direction, width_of(eff)


def check_pair(e_a, port_a, e_b, port_b, overrides_a, overrides_b, c4, label):
    dir_a, w_a = e_a.effective_width(port_a, overrides_a, c4)
    dir_b, w_b = e_b.effective_width(port_b, overrides_b, c4)
    if w_a != w_b:
        sys.exit("GENOOC27 ABORT: %s %s.%s %r != %s.%s %r" %
                  (label, e_a.tag, port_a, w_a, e_b.tag, port_b, w_b))
    ok_dirs = {("in", "out"), ("out", "in")}
    if (dir_a, dir_b) not in ok_dirs:
        sys.exit("GENOOC27 ABORT: %s %s.%s dir=%s, %s.%s dir=%s (need one in, one out)" %
                  (label, e_a.tag, port_a, dir_a, e_b.tag, port_b, dir_b))


def vhdl_decl_type(effective_width):
    base, w = effective_width
    if base == "std_logic":
        return "std_logic"
    return "%s(%d downto 0)" % (base, w - 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo_root")
    ap.add_argument("--out", default=None)
    ap.add_argument("--haddr-w", default="15",
                     help="fk33_seam HADDR_W; must match the tree's fk33_card.vhd "
                          "hw_addr/hr_addr port width (15 for the 27B card, build "
                          "27B-1's own value; 14 for the committed 9B one)")
    ap.add_argument("--regmax", default="17408",
                     help="fk33_seam REGMAX; must satisfy clog2(REGMAX) == "
                          "--haddr-w (build 27B-1's own value is 17408 for 15; "
                          "16384 is a valid pairing for --haddr-w 14)")
    a = ap.parse_args()
    repo_root = os.path.normpath(a.repo_root)
    out = a.out or os.path.join(repo_root, "hw", "jc", "card", "jc_ooc27_top.vhd")
    seam_generics = dict(SEAM_GENERICS_FIXED)
    seam_generics["HADDR_W"] = a.haddr_w
    seam_generics["REGMAX"] = a.regmax

    c4 = load_compose4(repo_root)
    eng = Entity("eng", repo_root, c4)
    seam = Entity("seam", repo_root, c4)
    card = Entity("card", repo_root, c4)
    insts = {"eng": eng, "seam": seam, "card": card}
    overrides = {"eng": ENG_GENERICS, "seam": seam_generics, "card": {}}

    bd_tcl_path = os.path.join(repo_root, "hw", "jc", "card", "jc_card_bd.tcl")
    if not os.path.exists(bd_tcl_path):
        sys.exit("GENOOC27 ABORT: no %s (needed for the BD-connectivity audit, "
                  "fix round 1 C1)" % bd_tcl_path)
    bd_text = open(bd_tcl_path).read()
    bd_connected = {tag: bd_connected_ports(bd_text, tag, insts[tag].ports)
                     for tag in insts}

    # ---- resolve every wired pair, net by net, checking width+direction --
    nets = []   # (signal_name, vhdl_type, [(inst, port), (inst, port)])
    wired = {"eng": set(), "seam": set(), "card": set()}

    def add_net(prefix, inst_a, port_a, inst_b, port_b, label):
        e_a, e_b = insts[inst_a], insts[inst_b]
        # a port claimed by two different pairs would otherwise be silently
        # resolved to whichever net's lookup runs first (nets.append order),
        # which is exactly the kind of mis-wiring this generator exists to
        # refuse rather than produce (see test_gen_ooc27_top.py's mutation
        # tests).
        if port_a in wired[inst_a]:
            sys.exit("GENOOC27 ABORT: %s %s.%s is wired more than once" %
                      (label, inst_a, port_a))
        if port_b in wired[inst_b]:
            sys.exit("GENOOC27 ABORT: %s %s.%s is wired more than once" %
                      (label, inst_b, port_b))
        check_pair(e_a, port_a, e_b, port_b,
                   overrides[inst_a], overrides[inst_b], c4, label)
        _, w = e_a.effective_width(port_a, overrides[inst_a], c4)
        sig = "%s_%s_%s" % (prefix, inst_a, port_a)
        nets.append((sig, vhdl_decl_type(w), [(inst_a, port_a), (inst_b, port_b)]))
        wired[inst_a].add(port_a)
        wired[inst_b].add(port_b)

    for sp, cp in SEAM_CARD:
        add_net("net_sc", "seam", sp, "card", cp, "SEAM_CARD")
    for cp, ep in A_SEAM:
        add_net("net_as", "card", cp, "eng", ep, "A_SEAM")
    for cp, ep in AXI_CTRL:
        add_net("net_ax", "card", cp, "eng", ep, "AXI_CTRL")

    # ---- shared clk/hbm_aclk/compute_halt, and the registered rst/rstn:
    #      not ordinary nets (fan to more than one instance / come from the
    #      2-flop buffer, not a wired pair), handled directly in the
    #      port-map pass.
    for (inst, port), _topport in SHARED.items():
        wired[inst].add(port)
    for inst, _sig in list(REG_RST.items()) + list(REG_RSTN.items()):
        port = "rst" if inst != "eng" else "core_aresetn"
        wired[inst].add(port)

    # ---- fix round 1, C1: every remaining port of every instance is
    #      EXPORTED only if jc_card_bd.tcl actually connects it to something
    #      (bd_connected_ports(), which covers both "to one of the other two
    #      cells" -- already handled above as a wired net -- and "to
    #      something outside the three-cell scope", the only case left by
    #      the time we get here). Anything the BD never connects at all is
    #      tied off instead: `open` for an output (so dead logic feeding it,
    #      like card/obs_wsum's debug hash, is eliminated exactly as in the
    #      real build), a quiescent constant for an input (so a tie this
    #      generator must supply is never silently exported as a free,
    #      meaningless control port instead).
    top_ports = []       # (name, dir, vhdl_type)
    exported = {"eng": {}, "seam": {}, "card": {}}   # port -> top name
    tied_off = {"eng": {}, "seam": {}, "card": {}}    # port -> "open" | const
    for tag, e in insts.items():
        for nm, direction, typ in e.ports:
            if nm in wired[tag]:
                continue
            eff_dir, w = e.effective_width(nm, overrides[tag], c4)
            if nm in bd_connected[tag]:
                topname = "%s_%s" % (tag, nm)
                top_ports.append((topname, eff_dir, vhdl_decl_type(w)))
                exported[tag][nm] = topname
            elif eff_dir == "out":
                tied_off[tag][nm] = "open"
            else:
                tied_off[tag][nm] = "(others => '0')" if w[1] > 1 else "'0'"

    # ---- emit -------------------------------------------------------------
    lines = []
    lines.append("-- hw/jc/card/jc_ooc27_top.vhd -- GENERATED by "
                  "hw/jc/card/gen_ooc27_top.py.")
    lines.append("-- DO NOT HAND-EDIT; edit the generator.  Task 10, "
                  "2026-10-07 (fix round 1, 2026-10-07).")
    lines.append("-- Co-residency + real A-seam/host-seam dataflow top for "
                  "fk33_engine + fk33_seam + fk33_card")
    lines.append("-- (the 27B wrapper).  See the generator's own docstring "
                  "for what is wired, what is not,")
    lines.append("-- and what this measurement does and does not establish. "
                  "A port jc_card_bd.tcl never connects")
    lines.append("-- to anything is tied off, never exported (fix round 1, C1).")
    lines.append("library ieee;")
    lines.append("use ieee.std_logic_1164.all;")
    lines.append("use ieee.numeric_std.all;")
    lines.append("")
    lines.append("entity jc_ooc27_top is")
    lines.append("  port(")
    lines.append("    clk          : in  std_logic;")
    lines.append("    rst          : in  std_logic;   -- active-high, registered on clk before use")
    lines.append("    rstn         : in  std_logic;   -- active-low, registered on clk before use")
    lines.append("    compute_halt : in  std_logic;   -- false-pathed (quasi-static, CATTRIP)")
    for nm, direction, typ in top_ports:
        lines.append("    %-28s : %-4s %s;" % (nm, direction, typ))
    # drop the trailing ';' on the very last port
    lines[-1] = lines[-1].rstrip(";")
    lines.append("  );")
    lines.append("end entity;")
    lines.append("")
    lines.append("architecture rtl of jc_ooc27_top is")
    for sig, typ, _ports in nets:
        lines.append("  signal %-28s : %s;" % (sig, typ))
    lines.append("  -- fix round 1, I4: registered reset buffer. A bare top-level port")
    lines.append("  -- fanning out to every reset input across all three instances directly")
    lines.append("  -- (what this generator did before) is not a net any OOC harness, or any")
    lines.append("  -- real design, would present to place/route: on the order of 2.7e5 flops")
    lines.append("  -- from one unregistered, unreplicated port.")
    lines.append("  signal rst_r1, rst_r2     : std_logic := '0';")
    lines.append("  signal rstn_r1, rstn_r2   : std_logic := '1';")
    lines.append("begin")
    lines.append("")
    lines.append("  process(clk)")
    lines.append("  begin")
    lines.append("    if rising_edge(clk) then")
    lines.append("      rst_r1  <= rst;      rst_r2  <= rst_r1;")
    lines.append("      rstn_r1 <= rstn;     rstn_r2 <= rstn_r1;")
    lines.append("    end if;")
    lines.append("  end process;")
    lines.append("")

    def portmap_line(nm, expr, last):
        return "      %-20s => %s%s" % (nm, expr, "" if last else ",")

    def resolve(tag, nm):
        if (tag, nm) in SHARED:
            return SHARED[(tag, nm)]
        if tag in REG_RST and nm == "rst":
            return REG_RST[tag]
        if tag in REG_RSTN and nm == "core_aresetn":
            return REG_RSTN[tag]
        if nm in exported[tag]:
            return exported[tag][nm]
        if nm in tied_off[tag]:
            return tied_off[tag][nm]
        return next(s for s, _t, ports in nets if (tag, nm) in ports)

    # ---- eng ---------------------------------------------------------------
    lines.append("  u_eng : entity work.fk33_engine")
    lines.append('    generic map(CB_STYLE => %s, USE_XEXP_PORT => %s)' %
                  (ENG_GENERICS["CB_STYLE"], ENG_GENERICS["USE_XEXP_PORT"]))
    lines.append("    port map(")
    eng_lines = [(nm, resolve("eng", nm)) for nm, _d, _t in eng.ports]
    for i, (nm, expr) in enumerate(eng_lines):
        lines.append(portmap_line(nm, expr, i == len(eng_lines) - 1))
    lines.append("    );")
    lines.append("")

    # ---- seam ---------------------------------------------------------------
    lines.append("  u_seam : entity work.fk33_seam")
    lines.append("    generic map(")
    seam_gen_items = list(seam_generics.items())
    for i, (g, v) in enumerate(seam_gen_items):
        lines.append("      %s => %s%s" % (g, v, "" if i == len(seam_gen_items) - 1 else ","))
    lines.append("    )")
    lines.append("    port map(")
    seam_lines = [(nm, resolve("seam", nm)) for nm, _d, _t in seam.ports]
    for i, (nm, expr) in enumerate(seam_lines):
        lines.append(portmap_line(nm, expr, i == len(seam_lines) - 1))
    lines.append("    );")
    lines.append("")

    # ---- card ---------------------------------------------------------------
    lines.append("  u_card : entity work.fk33_card")
    lines.append("    port map(")
    card_lines = [(nm, resolve("card", nm)) for nm, _d, _t in card.ports]
    for i, (nm, expr) in enumerate(card_lines):
        lines.append(portmap_line(nm, expr, i == len(card_lines) - 1))
    lines.append("    );")
    lines.append("")
    lines.append("end architecture;")

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    n_tied = sum(len(v) for v in tied_off.values())
    print("GENOOC27_WROTE %s (%d top ports, %d internal nets, %d tied off, "
          "eng=%d seam=%d card=%d ports total)" %
          (out, len(top_ports) + 4, len(nets), n_tied,
           len(eng.ports), len(seam.ports), len(card.ports)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
