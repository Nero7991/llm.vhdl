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
            AR/R channel, which only the host ever drove, is tied off here
            (arvalid/araddr/arprot to a quiescent constant, rready high,
            the four outputs left open) rather than wired to anything.

WHAT IS NOT WIRED.  Every other port of all three instances is brought to
the top level, uniquely prefixed (eng_/seam_/card_) -- the engine's 28 HBM
AXI masters, the card's 5 HBM AXI masters, the card's bst_*/kv_*_* ports
(the real BD's grant arbiter, bcgrant, is outside this task's three-instance
scope), and both AXI4-Lite host-control slaves (eng's s_axix, seam's s_axi).
No port is dropped, so nothing here can be optimised away as dead logic --
the same reason hw/fk33/gen_compose4_top.py exports rather than stimulates
its own nine co-resident instances.

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
ENG_GENERICS = {"CB_STYLE": '"distributed"'}

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

# eng's s_axi AR/R channel: tied off, not wired (card/a has no AR/R to drive
# it; see AXI_CTRL above). (port, "in"-tie-value or None for an output left
# open).
ENG_SAXI_TIEOFF = {
    "s_axi_arvalid": "'0'",
    "s_axi_araddr": None,     # others => '0', filled in from its own width
    "s_axi_arprot": None,     # others => '0'
    "s_axi_rready": "'1'",
    "s_axi_arready": "OPEN",
    "s_axi_rvalid": "OPEN",
    "s_axi_rdata": "OPEN",
    "s_axi_rresp": "OPEN",
}

# clk/rst/hbm_aclk/compute_halt: shared top-level ports, by (inst, port).
SHARED = {
    ("eng", "core_clk"): "clk", ("eng", "hbm_aclk"): "clk",
    ("eng", "core_aresetn"): "rstn", ("eng", "compute_halt"): "compute_halt",
    ("seam", "clk"): "clk", ("seam", "rst"): "rst",
    ("card", "clk"): "clk", ("card", "rst"): "rst",
}


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

    # ---- shared clk/rst/hbm_aclk/compute_halt: not ordinary nets (fan to
    #      more than one instance), handled directly in the port-map pass.
    for (inst, port), _topport in SHARED.items():
        wired[inst].add(port)
    for port in ENG_SAXI_TIEOFF:
        wired["eng"].add(port)

    # ---- every remaining port of every instance becomes a uniquely
    #      prefixed top-level port, in the entity's own declaration order.
    top_ports = []       # (name, dir, vhdl_type)
    exported = {"eng": {}, "seam": {}, "card": {}}   # port -> top name
    for tag, e in insts.items():
        for nm, direction, typ in e.ports:
            if nm in wired[tag]:
                continue
            eff_dir, w = e.effective_width(nm, overrides[tag], c4)
            topname = "%s_%s" % (tag, nm)
            top_ports.append((topname, eff_dir, vhdl_decl_type(w)))
            exported[tag][nm] = topname

    # ---- emit -------------------------------------------------------------
    lines = []
    lines.append("-- hw/jc/card/jc_ooc27_top.vhd -- GENERATED by "
                  "hw/jc/card/gen_ooc27_top.py.")
    lines.append("-- DO NOT HAND-EDIT; edit the generator.  Task 10, "
                  "2026-10-07.")
    lines.append("-- Co-residency + real A-seam/host-seam dataflow top for "
                  "fk33_engine + fk33_seam + fk33_card")
    lines.append("-- (the 27B wrapper).  See the generator's own docstring "
                  "for what is wired, what is not,")
    lines.append("-- and what this measurement does and does not establish.")
    lines.append("library ieee;")
    lines.append("use ieee.std_logic_1164.all;")
    lines.append("use ieee.numeric_std.all;")
    lines.append("")
    lines.append("entity jc_ooc27_top is")
    lines.append("  port(")
    lines.append("    clk          : in  std_logic;")
    lines.append("    rst          : in  std_logic;   -- active-high: seam, card")
    lines.append("    rstn         : in  std_logic;   -- active-low: eng/core_aresetn")
    lines.append("    compute_halt : in  std_logic;")
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
    lines.append("begin")
    lines.append("")

    def portmap_line(nm, expr, last):
        return "      %-20s => %s%s" % (nm, expr, "" if last else ",")

    # ---- eng ---------------------------------------------------------------
    lines.append("  u_eng : entity work.fk33_engine")
    lines.append('    generic map(CB_STYLE => "distributed")')
    lines.append("    port map(")
    eng_lines = []
    for nm, direction, typ in eng.ports:
        if (eng.tag, nm) in SHARED:
            expr = SHARED[("eng", nm)]
        elif nm in exported["eng"]:
            expr = exported["eng"][nm]
        elif nm in ENG_SAXI_TIEOFF:
            tie = ENG_SAXI_TIEOFF[nm]
            if tie == "OPEN":
                expr = "open"
            elif tie is None:
                _, w = eng.effective_width(nm, overrides["eng"], c4)
                expr = "(others => '0')" if w[1] > 1 else "'0'"
            else:
                expr = tie
        else:
            net = next(s for s, _t, ports in nets if ("eng", nm) in ports)
            expr = net
        eng_lines.append((nm, expr))
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
    seam_lines = []
    for nm, direction, typ in seam.ports:
        if ("seam", nm) in SHARED:
            expr = SHARED[("seam", nm)]
        elif nm in exported["seam"]:
            expr = exported["seam"][nm]
        else:
            net = next(s for s, _t, ports in nets if ("seam", nm) in ports)
            expr = net
        seam_lines.append((nm, expr))
    for i, (nm, expr) in enumerate(seam_lines):
        lines.append(portmap_line(nm, expr, i == len(seam_lines) - 1))
    lines.append("    );")
    lines.append("")

    # ---- card ---------------------------------------------------------------
    lines.append("  u_card : entity work.fk33_card")
    lines.append("    port map(")
    card_lines = []
    for nm, direction, typ in card.ports:
        if ("card", nm) in SHARED:
            expr = SHARED[("card", nm)]
        elif nm in exported["card"]:
            expr = exported["card"][nm]
        else:
            net = next(s for s, _t, ports in nets if ("card", nm) in ports)
            expr = net
        card_lines.append((nm, expr))
    for i, (nm, expr) in enumerate(card_lines):
        lines.append(portmap_line(nm, expr, i == len(card_lines) - 1))
    lines.append("    );")
    lines.append("")
    lines.append("end architecture;")

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("GENOOC27_WROTE %s (%d top ports, %d internal nets, "
          "eng=%d seam=%d card=%d ports total)" %
          (out, len(top_ports) + 4, len(nets),
           len(eng.ports), len(seam.ports), len(card.ports)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
