#!/usr/bin/env python3
"""Generate FILE-INITIALIZED BRAM data for the shared PL llama engine.

WHY
---
tools/gen_weights_pkg.py bakes ~227K int16 weight mantissas (+ per-row mult/shift)
and the 32K token embedding into VHDL CONSTANT AGGREGATES.  Vivado constant-folds
those ~300K literals during synthesis of `engine_shared`, peaking ~25 GB and
thrashing a 31 GB box.  This generator emits the SAME values as external hex
`.mem` files (one two's-complement value per line, readmemh-style) so the ROMs can
be loaded into block RAM by a `std.textio`+`hread` impure function at elaboration
(rtl/rom_init_pkg.vhd) instead of a giant aggregate -- light elaboration, real BRAM,
bit-identical data.  Works in BOTH GHDL sim and Vivado synth from one codebase.

OUTPUTS (under mem/rom/)
------------------------
  weights_mant.mem   226560 lines, 4 hex digits  (int16)   WROM = WQ&WK&WV&WO&W1&W3&W2
  weights_mult.mem     3000 lines, 8 hex digits  (int32)   MROM = *_MULT (same order)
  weights_shift.mem    3000 lines, 8 hex digits  (int32)   SROM = *_SHIFT(same order)
  embed_mant.mem      32768 lines, 4 hex digits  (int16)   EMBED token*DIM+i

The concat order WQ,WK,WV,WO,W1,W3,W2 and the per-matrix layer-major layout MATCH
rtl/matmul_rt.vhd's WROM/MROM/SROM (MBASE_W/MBASE_S tables) exactly.

ALSO EMITS  rtl/rms_weights_pkg.vhd
-----------------------------------
A SMALL generated constant package (intarr + ATT_RMS_W/FFN_RMS_W/FINAL_RMS_W and
their exponents) so `engine_shared` no longer has to `use work.weights_pkg.all`
(which drags the 16819-line big-aggregate file into synthesis).  These RMS arrays
are tiny (~715 ints) -- no memory problem -- and stay compile-time constants.

Regenerate:  python3 tools/gen_weight_mem.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.join(ROOT, "mem", "weights")
ROM = os.path.join(ROOT, "mem", "rom")

N_LAYERS = 5
DIM = 64
HIDDEN = 172
KV_DIM = 32
VOCAB = 512

# matrix -> (rows, cols) per layer, in the SAME concat order matmul_rt uses:
#   WROM = WQ & WK & WV & WO & W1 & W3 & W2   (note W3 BEFORE W2)
ORDER = ["wq", "wk", "wv", "wo", "w1", "w3", "w2"]
DIMS = {
    "wq": (DIM,    DIM),      # 64  x 64  = 4096
    "wk": (KV_DIM, DIM),      # 32  x 64  = 2048
    "wv": (KV_DIM, DIM),      # 32  x 64  = 2048
    "wo": (DIM,    DIM),      # 64  x 64  = 4096
    "w1": (HIDDEN, DIM),      # 172 x 64  = 11008
    "w3": (HIDDEN, DIM),      # 172 x 64  = 11008
    "w2": (DIM,    HIDDEN),   # 64  x 172 = 11008
}


def read_mem(path, n=None):
    vals = [int(l) for l in open(path) if l.strip() != ""]
    if n is not None and len(vals) != n:
        raise SystemExit("ERROR: %s has %d values, expected %d" % (path, len(vals), n))
    return vals


def read_int(path):
    return int(open(path).read().strip())


def hx(v, nbits):
    """Two's-complement hex, nbits wide, uppercase, zero-padded (no 0x)."""
    mask = (1 << nbits) - 1
    return format(v & mask, "0%dX" % (nbits // 4))


def write_mem(name, vals, nbits):
    path = os.path.join(ROM, name)
    with open(path, "w") as f:
        f.write("\n".join(hx(v, nbits) for v in vals))
        f.write("\n")
    print("wrote %s  (%d values, %d-bit)" % (path, len(vals), nbits))


def emit_agg(vals, indent="    ", per=16):
    lines = []
    for k in range(0, len(vals), per):
        chunk = vals[k:k + per]
        tail = "," if (k + per) < len(vals) else ""
        lines.append(indent + ", ".join(str(v) for v in chunk) + tail)
    return "\n".join(lines)


def const_arr(out, name, vals):
    out.append("  constant %s : intarr(0 to %d) := (" % (name, len(vals) - 1))
    out.append(emit_agg(vals))
    out.append("  );")


def main():
    os.makedirs(ROM, exist_ok=True)

    # ---- weight mantissa / mult / shift flat ROMs (matmul_rt concat order) ----
    wrom, mrom, srom = [], [], []
    for m in ORDER:
        rows, cols = DIMS[m]
        stride = rows * cols
        for L in range(N_LAYERS):
            wrom += read_mem(os.path.join(W, "L%d" % L, "%s.mem" % m), stride)
        for L in range(N_LAYERS):
            mrom += read_mem(os.path.join(W, "L%d" % L, "%s_mult.mem" % m), rows)
        for L in range(N_LAYERS):
            srom += read_mem(os.path.join(W, "L%d" % L, "%s_shift.mem" % m), rows)

    assert len(wrom) == 226560, len(wrom)
    assert len(mrom) == 3000 and len(srom) == 3000, (len(mrom), len(srom))
    write_mem("weights_mant.mem", wrom, 16)
    write_mem("weights_mult.mem", mrom, 32)
    write_mem("weights_shift.mem", srom, 32)

    # ---- token embedding mantissa ROM ----
    embed = read_mem(os.path.join(W, "embed.mem"), VOCAB * DIM)
    write_mem("embed_mant.mem", embed, 16)

    # ---- small RMS-weight constant package (kept as literals; ~715 ints) ------
    att_w, att_e, ffn_w, ffn_e = [], [], [], []
    for L in range(N_LAYERS):
        att_w += read_mem(os.path.join(W, "L%d" % L, "att_rmsnorm_w.mem"), DIM)
        att_e.append(read_int(os.path.join(W, "L%d" % L, "att_rmsnorm_w_exp.txt")))
        ffn_w += read_mem(os.path.join(W, "L%d" % L, "ffn_rmsnorm_w.mem"), DIM)
        ffn_e.append(read_int(os.path.join(W, "L%d" % L, "ffn_rmsnorm_w_exp.txt")))
    final_w = read_mem(os.path.join(W, "final_rmsnorm_w.mem"), DIM)
    final_e = read_int(os.path.join(W, "final_rmsnorm_w_exp.txt"))

    out = []
    out.append("-- rtl/rms_weights_pkg.vhd  -- AUTO-GENERATED by tools/gen_weight_mem.py")
    out.append("-- DO NOT EDIT BY HAND.  Small RMSNorm-weight constants (~715 ints) for")
    out.append("-- engine_shared, split out of the big weights_pkg so synthesis of the")
    out.append("-- shared engine never has to read the 227K-literal weight aggregate")
    out.append("-- (those now live in mem/rom/*.mem, file-loaded into BRAM by matmul_rt).")
    out.append("-- Values are bit-identical to mem/weights/*rmsnorm_w*.")
    out.append("library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;")
    out.append("")
    out.append("package rms_weights_pkg is")
    out.append("  type intarr is array(natural range <>) of integer;")
    out.append("  constant N_LAYERS : natural := %d;" % N_LAYERS)
    out.append("  constant DIM      : natural := %d;" % DIM)
    const_arr(out, "ATT_RMS_W", att_w)
    const_arr(out, "ATT_RMS_W_EXP", att_e)
    const_arr(out, "FFN_RMS_W", ffn_w)
    const_arr(out, "FFN_RMS_W_EXP", ffn_e)
    const_arr(out, "FINAL_RMS_W", final_w)
    out.append("  constant FINAL_RMS_W_EXP : integer := %d;" % final_e)
    out.append("end package;")
    out.append("")
    dst = os.path.join(ROOT, "rtl", "rms_weights_pkg.vhd")
    with open(dst, "w") as f:
        f.write("\n".join(out))
    print("wrote %s" % dst)


if __name__ == "__main__":
    main()
