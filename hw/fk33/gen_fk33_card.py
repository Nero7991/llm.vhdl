#!/usr/bin/env python3
"""Emit hw/fk33/rtl/fk33_card.vhd -- the board-facing face of subsystems B, C
and D, so the block designer can instantiate them.

THE CARD IS A TWO-CELL BLOCK DESIGN.  Subsystem A is its own cell,
`hw/fk33/rtl/fk33_engine.vhd`, wrapping `matvec_int4_desc_axi` and its 28
masters.  This is the OTHER cell: `rtl/fk33_llama_top.vhd` at `A_DESC = true`,
which carries B, C and D and DRIVES A's descriptor plane over a 23-port `a_*`
seam.  `ga_desc` there instantiates `a_job_counter` and `a_desc_adapter` only
-- the control plane -- and deliberately contains no A compute unit.

WHY A GENERATED WRAPPER RATHER THAN THE ENTITY ITSELF.  Three packager rules,
none of which any bench can see, because they belong to the IP packager and not
to VHDL:

  * `[IP_Flow 19-734]`  `natural` is not a port type.  The card top has four,
    all of them the host region-file window.
  * `[IP_Flow 19-627]`  a port width is an XPath expression over the generics
    and may not call a function.
  * A FLATTENED VECTOR IS NOT AN INTERFACE.  `gen_fk33_engine.py` says it
    plainly: "Vivado's block designer cannot see a flattened vector as AXI at
    all, so it cannot be connected to `hbm/SAXI_nn`, which is an interface
    pin."  On this top exactly two masters have that shape -- C's reads.

The wrapper also declares NO GENERICS.  That is deliberate: it gives the
packager a cell with nothing to infer, and it puts the CONFIGURATION in this
file, where it is reviewable, rather than in a block-design property.

THE CONFIGURATION, and each entry is a decision:

  B_STATE_AXI = true   B's recurrent state behind an AXI master (`bst_*`).
                       Default false, and every composed measurement before
                       2026-09-07 was taken with it off.
  C_KV_AXI    = true   C's KV cache behind three masters (`kv_*`).  Same.
  C_KV_BLOCK  = 32     REQUIRED.  `attn_kv_axi` asserts `KV_BLOCK >= 16` (its
                       record is a byte layout on a 16-byte granule at the
                       mandatory CM_W = 8), and the generic's default here is
                       4.  So `C_KV_AXI = true` at the default is not a legal
                       configuration, and 32 is the composed shape's value.

The `--const` values are read FROM THE VHDL, not from a comment: `NREGION` and
`region_max(mk_shape(MODEL, NCARDS))` come from a GHDL probe, and `A_NPORTS`
is `rtl/llama_map_pkg.vhd:69`.  Note `A_NPORTS = 5` is the SIMULATION path's A
(`matvec_int4`, 4 weight ports plus 1 scale); the card's A is the 28-master
descriptor unit in the other cell, so those five ports are not the card's.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(HERE, "rtl", "fk33_card.vhd")
SRC = os.path.join(REPO, "rtl", "fk33_llama_top.vhd")

# ---- the THIRD cell: the B/C grant ---------------------------------------
# A takes 28 HBM masters, B needs 2 and C needs 3, which is 33 against the 30
# the host leaves free.  `rtl/bc_port_grant.vhd` closes B-versus-C to 3 SHARED
# ports with a drain interlock, and it belongs in the block design between the
# card cell and hbm/SAXI_nn rather than inside the card top -- putting it
# inside would mean hand-writing a 141-port RTL level around a generated one.
#
# It is already packager-legal (63 ports, 0 refusals); it only needs its
# flattened groups cut into named interfaces: C's TWO reads on the requester
# side, and the THREE shared masters on the pool side.
GRANT_OUT = os.path.join(HERE, "rtl", "fk33_bc_grant.vhd")
GRANT_SRC = os.path.join(REPO, "rtl", "bc_port_grant.vhd")

GRANT_C2 = ",".join([
    "c_arvalid", "c_arready", "c_araddr", "c_arlen",
    "c_rvalid", "c_rdata", "c_rlast", "c_rready",
])
GRANT_M3 = ",".join([
    "m_arvalid", "m_araddr", "m_arlen", "m_arready",
    "m_rvalid", "m_rdata", "m_rlast", "m_rready",
    "m_awvalid", "m_awaddr", "m_awlen", "m_awready",
    "m_wvalid", "m_wdata", "m_wlast", "m_wready",
    "m_bvalid", "m_bready",
])

GRANT_ARGS = [
    "--src", GRANT_SRC,
    "--entity", "bc_port_grant",
    "--wrapper", "fk33_bc_grant",
    "--split", "2:" + GRANT_C2,
    "--split", "3:" + GRANT_M3,
]

# C's two read masters, carried flattened on the card top.  EXPLICIT, because a
# width being divisible by 2 does not make a port two masters: `kv_awaddr` is
# 16 bits and is one, and inferring here would cut a working interface in half.
KV_READ = ",".join([
    "kv_arvalid", "kv_arready", "kv_araddr", "kv_arlen", "kv_arsize",
    "kv_arburst", "kv_rvalid", "kv_rready", "kv_rdata", "kv_rlast", "kv_rresp",
])

ARGS = [
    "--src", SRC,
    "--entity", "fk33_llama_top",
    "--wrapper", "fk33_card",
    "--const", "NREGION=14",
    "--const", "REGMAX=12288",
    "--const", "A_NPORTS=5",
    # A_DESC = true IS THE WHOLE POINT OF THIS CELL and it was missing from
    # the first version of this list, which is worth recording because nothing
    # complained about the omission directly.  With A_DESC false the `ga_real`
    # generate is instantiated, bringing `matvec_int4` -- the SIMULATION path's
    # A, five masters at ROWS_IF 4 -- into a cell whose entire purpose is to
    # drive the OTHER cell's A over the `a_*` seam.
    #
    # The symptom was not "A_DESC is false".  It was
    #   [Synth 8-549] port width mismatch for port 'm_arvalid':
    #                 port width = 49, actual width = 5
    # because A_ROWS_IF = 48 asks `matvec_int4` for 49 masters while
    # `A_NPORTS` is a package CONSTANT of 5 (llama_map_pkg.vhd:69, pinned
    # because `weight_streamer.vhd` fixes NPORTS_W = ROWS_IF = 4 at BLK 32 /
    # AXI_DW 128).  That reads as "A_ROWS_IF = 48 is illegal here", which is
    # true of `ga_real` and irrelevant to this cell -- the path should not
    # exist at all.
    "--generic", "A_DESC=true",
    "--generic", "B_STATE_AXI=true",
    "--generic", "C_KV_AXI=true",
    "--generic", "C_KV_BLOCK=32",
    # A_ROWS_IF = 48 IS NOT A TUNING CHOICE, IT IS THE SEAM WIDTH.
    # `hw/fk33/gen_fk33_engine.py` pins `ROWS_IF = 48` (TRACK LEVERC48 measured
    # "distributed" at 48 as -42,633 CLB LUT), so the engine cell's
    # `d_y_data` is 48*64 = 3072 bits and `d_y_mask` is 48.  The card top's
    # `A_ROWS_IF` DEFAULTS TO 4, which makes `a_y_data` 256 bits and `a_y_mask`
    # 4 -- a 12x mismatch on the seam that joins the two cells.
    #
    # Found by comparing the two entities' port lists rather than by a tool:
    # nothing in either file references the other, and each is internally
    # consistent, so the disagreement is invisible until they are connected.
    # This is also what makes `--generic` drive width folding load-bearing
    # rather than defensive -- a pin that did not reach the folding would leave
    # the wrapper's port 256 bits wide over a 3072-bit instance.
    "--generic", "A_ROWS_IF=48",
    # A_JOB_STRIDE = 0x40000 (262,144) EXISTS ONLY TO SATISFY A GUARD THAT IS
    # OVER-BROAD IN THIS CONFIGURATION, and saying so is the point of this note.
    #
    # `fk33_llama_top.vhd:1092` is
    #     CHK_A_BLOCK : natural := A_JOB_STRIDE - (A_ROWS_IF + 1) * A_SUB_BYTES
    # which is the project's out-of-range-natural idiom for a compile-time
    # assertion, because Vivado silently ignores `assert ... severity failure`
    # in synthesis.  At A_ROWS_IF = 48 it evaluates to
    # 32,768 - 49*4,096 = -167,936 and Vivado refuses with
    # `[Synth 8-11323] assigned value '-167936' out of range`.
    #
    # The guard is CORRECT arithmetic and its own comment says what it guards:
    # "the run-time half of this bound is A_SUB_BEATS / A_SCL_BEATS in the
    # `ga_real` generate; this is the half a synthesis run can see."  But
    # `ga_real` is `if not A_BEHAV and not A_DESC generate`, so at A_DESC = true
    # it is NOT INSTANTIATED, and MEASURED by grep, A_JOB_STRIDE appears
    # nowhere else outside that generate.  The constant is declared in the
    # architecture's declarative region, so it is evaluated regardless of
    # whether the path it describes exists.
    #
    # So the guard fires over a memory map this configuration does not build:
    # in the card, A's weight sub-regions belong to the OTHER cell,
    # `fk33_engine`, and A_ROWS_IF here only sizes the `a_y_*` seam.  262,144
    # is 49*4,096 rounded up to a power of two; nothing reads it.
    #
    # The cleaner fix is to make CHK_A_BLOCK conditional on `not A_DESC` in
    # rtl/llama_top.vhd and regenerate.  Deliberately NOT done here: that edits
    # a guard, and a guard weakened by someone who only wanted their own build
    # to pass is how guards stop working.
    "--generic", "A_JOB_STRIDE=16#40000#",
    "--split", "2:" + KV_READ,
]


def render(dest, args=None):
    cmd = [sys.executable, os.path.join(REPO, "tools", "gen_bd_wrapper.py"),
           "--out", dest] + (ARGS if args is None else args)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        return None
    return open(dest).read()


def one(out, args, label, source):
    check = "--check" in sys.argv
    tmp = out + (".check" if check else "")
    text = render(tmp, args)
    if text is None:
        print("FK33_CARD_CHECK: GENERATOR FAILED for %s" % label)
        return 1
    if check:
        try:
            cur = open(out).read()
        except IOError:
            os.remove(tmp)
            print("FK33_CARD_CHECK: MISSING %s -- run "
                  "hw/fk33/gen_fk33_card.py" % out)
            return 1
        os.remove(tmp)
        if cur != text:
            print("FK33_CARD_CHECK: STALE %s -- %s or the configuration "
                  "changed and this file was not regenerated. Run "
                  "hw/fk33/gen_fk33_card.py." % (out, source))
            return 1
        print("FK33_CARD_CHECK: OK %s (%d bytes)"
              % (os.path.basename(out), len(text)))
        return 0
    print("wrote %s (%d bytes)" % (out, len(text)))
    return 0


def main():
    rc = one(OUT, ARGS, "fk33_card", "rtl/fk33_llama_top.vhd")
    rc |= one(GRANT_OUT, GRANT_ARGS, "fk33_bc_grant", "rtl/bc_port_grant.vhd")
    return rc


if __name__ == "__main__":
    sys.exit(main())
