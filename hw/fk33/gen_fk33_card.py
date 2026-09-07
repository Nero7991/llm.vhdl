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
    "--generic", "B_STATE_AXI=true",
    "--generic", "C_KV_AXI=true",
    "--generic", "C_KV_BLOCK=32",
    "--split", "2:" + KV_READ,
]


def render(dest):
    cmd = [sys.executable, os.path.join(REPO, "tools", "gen_bd_wrapper.py"),
           "--out", dest] + ARGS
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        return None
    return open(dest).read()


def main():
    check = "--check" in sys.argv
    tmp = OUT + (".check" if check else "")
    text = render(tmp)
    if text is None:
        print("FK33_CARD_CHECK: GENERATOR FAILED")
        return 1
    if check:
        try:
            cur = open(OUT).read()
        except IOError:
            os.remove(tmp)
            print("FK33_CARD_CHECK: MISSING %s -- run "
                  "hw/fk33/gen_fk33_card.py" % OUT)
            return 1
        os.remove(tmp)
        if cur != text:
            print("FK33_CARD_CHECK: STALE %s -- rtl/fk33_llama_top.vhd or the "
                  "configuration changed and this file was not regenerated. "
                  "Run hw/fk33/gen_fk33_card.py." % OUT)
            return 1
        print("FK33_CARD_CHECK: OK (%d bytes)" % len(text))
        return 0
    print("wrote %s (%d bytes)" % (OUT, len(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
