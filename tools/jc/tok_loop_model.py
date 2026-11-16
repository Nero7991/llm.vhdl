"""tools/jc/tok_loop_model.py -- the WRITES run_prompt sends to one die's seam, as ops,
for sim/tb_tok_loop*.vhd (plan docs/superpowers/plans/2026-11-04-jc-on-fabric-loop-and-link.md,
Task 2). The ops are checked against a capture of the real host code (jc_sim_broker --trace)
by tools/jc/gen_tok_loop_vec.py before any vector is written.

Ops: ("W", off, val) one register write at a seam-relative offset; ("D", n, fnv) a run of n
WIN_DATA writes whose 32-bit values hash to fnv (word-wise FNV-1a, basis 2166136261,
prime 16777619). Reads are not modelled (plan D7).
"""
FNV_B, FNV_P, M32 = 2166136261, 16777619, 0xFFFFFFFF
SEAM_BASE = 0xE000                                   # server/fk33_seam.h:227
CTRL, SEQ_POS, N_STEP = 0x14, 0x20, 0x24
X_EXP, WIN_SEL, WIN_ADDR, WIN_DATA = 0x54, 0x58, 0x5C, 0x60


def fnv32(vals):
    h = FNV_B
    for v in vals:
        h = ((h ^ (v & M32)) * FNV_P) & M32
    return h


def synth_row(tok, n):
    """server/pl_backend.c:66-80, pl_embed_synthetic, exactly: (mantissas, exponent)."""
    h = (FNV_B ^ tok) & M32
    out = []
    for i in range(n):
        h ^= i
        h = (h * FNV_P) & M32
        out.append((h >> 16) - 32768)
    return out, -8


def fed_tokens(prompt, gen):
    """The token fed at each position: the prompt, then every generated id but the last."""
    return list(prompt) + list(gen[:-1])


def die_writes(rows, role="single"):
    """rows: per position (mant list, exp). role "A" adds the hop's window-3 seek."""
    ops = [("W", CTRL, 2)]
    for p, (mant, exp) in enumerate(rows):
        ops += [("W", X_EXP, exp & M32), ("W", WIN_SEL, 2), ("W", WIN_ADDR, 0),
                ("D", len(mant), fnv32([m & 0xFFFF for m in mant])),
                ("W", SEQ_POS, p), ("W", N_STEP, 1), ("W", CTRL, 1)]
        if role == "A":
            ops += [("W", WIN_SEL, 3), ("W", WIN_ADDR, 0)]
    return ops


def parse_trace(lines, die):
    """jc_sim_broker --trace lines -> ops for one die, from its first SEQ_RESET write on."""
    ops, run, started = [], None, False
    for ln in lines:
        f = ln.split()
        if len(f) != 4 or f[0] != "W" or f[1] != die:
            continue
        off, val = int(f[2], 16) - SEAM_BASE, int(f[3], 16) & M32
        if not started:
            if off == CTRL and val == 2:
                started = True
            else:
                continue
        if off == WIN_DATA:
            run = [] if run is None else run
            run.append(val)
            continue
        if run is not None:
            ops.append(("D", len(run), fnv32(run)))
            run = None
        ops.append(("W", off, val))
    if run is not None:
        ops.append(("D", len(run), fnv32(run)))
    return ops
