#!/usr/bin/env bash
# sim/mutate_llama_top_normuram.sh -- RETIRED 2026-09-20 by TRACK REANCHOR.
#
# THIS HARNESS DOES NOT RUN.  It is kept as a tombstone rather than deleted so
# that the per-row map below survives, and so that anyone who follows a
# reference to it from docs/debugging/2026-08-30_normuram-gain-store-out-of-luts.md
# is told what happened instead of running nine rows that measure nothing.
# The full body is in git history at 00d92f1.
#
# ---------------------------------------------------------------------------
# WHY IT WAS RETIRED
# ---------------------------------------------------------------------------
# It was TEETH FOR A STORE THAT WAS REPLACED THREE TIMES.  TRACK NORMURAM
# (c479ae8) moved the norm gain out of LUT fabric into `nwrom`, a GW-elements-
# per-word ROM read into a `wreg` shift register, and this harness is written
# against exactly that structure.  Since then:
#
#   47c9d9c  TRACK RMSWIRE   `rmsnorm_bf_mem` replaced `rmsnorm_rs`; `wreg`
#                            was deleted and the sink became one ELEMENT per
#                            cycle on a bank port (`wel`, `wel_d`, `nw_wa`).
#   c094867  TRACK GAIN16    the value ROM became an INDEX ROM plus a 1,567-
#                            entry codebook (`ixrom` + `cbrom`).
#   21db25b  TRACK GWTWO     `gw_pick` became `return 1;`, so GW = 1 and there
#                            is no sub-word at all.
#
# NINE of its ten rows had a dead anchor when TRACK REANCHOR measured it
# (MEASURED 2026-09-20 by anchor replay at 00d92f1): U1 U2 U3 U4 U6 U6x U6b
# U6bx U7.  Only U0 (the control) and U5 still matched.  They did not lie --
# `mut`/`sub` fail and the `&&` chain skips the row -- they VANISHED, which
# reads as a shorter report rather than as a failure.
#
# AND `sim/mutate_rmswire.sh` IS ALREADY THE SUCCESSOR.  It was written by
# TRACK RMSWIRE against the replacement, reads the SAME `FILES` closure from
# `sim/mutate_llama_top_kv.sh`, runs the SAME `tb_llama_top` wrapper with the
# byte-identical `G_NORMW` generics and `LAND_NORMW` landmarks, and carries
# FOUR attribution columns (FULL / noWACT / noASRT / onlyWA) where this file
# had one three-way verdict.  Its R9 says so in its own row description:
# "TRACK NORMURAM's U5 re-asked of the rewritten loader."
#
# Re-anchoring these nine rows would have produced a second harness mutating
# the same lines of the same file against the same landmarks.
#
# ---------------------------------------------------------------------------
# THE PER-ROW MAP.  Every row, and what covers its property now.
# ---------------------------------------------------------------------------
#   U0  control, clean tree                -> sim/mutate_rmswire.sh R0
#   U1  gain vector rotated by one word    -> R5   (bank write address +1; at
#                                                   GW = 1 a word IS an element)
#   U2  m7 packer half, intra-word rotate  -> GONE.  There is no sub-word at
#                                             GW = 1 and c094867 deleted the
#                                             mux.  rtl/llama_top.vhd's
#                                             `wsubsel` comment says so, and
#                                             TRACK GWTWO reported under its
#                                             own name that the mirror mutant
#                                             does not bite at GW = 1.
#                                             sim/mutate_rmswire.sh R4 was the
#                                             same row and is retired with it.
#   U3  m7 unpacker half, words reversed   -> R5b, ADDED by TRACK REANCHOR for
#                                             exactly this reason: the
#                                             reversal re-expressed on the
#                                             bank write address (NN-1-wel_d),
#                                             which is where element order
#                                             lives on the form that ships.
#   U4  every op served norm op 0's gain   -> R9   (the load never restarts,
#                                                   same observable)
#   U5  the load never restarts            -> R9   (named there explicitly)
#   U6/U6b   load 8x / 64x slower          -> R2   (4x slower, gate INTACT,
#                                                   expected survivor)
#                                             and R3 (4x slower, gate REMOVED,
#                                                   must be killed).  The
#                                             property MOVED as well as the
#                                             anchor: 47c9d9c made `nproc`
#                                             gate `r_go` on `wbusy`, so a
#                                             slow load is now a stall and not
#                                             a wrong number, and the
#                                             assertion U6 was aimed at became
#                                             a PERFORMANCE check.  R2/R3 are
#                                             that pair, correctly stated.
#   U6x/U6bx attribution control, wbusy off-> the noASRT column, which
#                                             neutralises the same assertion
#                                             on EVERY row rather than on two.
#   U7  GW forced to 1, must survive       -> GONE.  GW = 1 IS the shipping
#                                             value since 21db25b, so the
#                                             mutation is the identity and the
#                                             row is a second copy of R0.
#                                             sim/mutate_rmswire.sh R11 was
#                                             the same row and is retired too.
#
# ---------------------------------------------------------------------------
# WHAT IS STILL NOT COVERED, and it is not this file's fault
# ---------------------------------------------------------------------------
# NO mutation harness in the tree touches `cbrom`, `CBMAP`, `CBMARK` or
# `ixrom` (MEASURED 2026-09-20: `grep -l` over all 62 `sim/mutate_*.sh`
# returns nothing).  TRACK GAIN16's codebook is a packer/unpacker pair of
# exactly the class U2 and U3 existed to attack, and it has no teeth at all.
# Retiring this file does not create that hole -- the hole arrived with
# c094867 -- but it is the moment it became visible.  See
# docs/debugging/2026-09-20_why-mutation-anchors-die.md.
# ---------------------------------------------------------------------------

cat >&2 <<'EOF'
sim/mutate_llama_top_normuram.sh is RETIRED (2026-09-20, TRACK REANCHOR).

The gain store it tests was replaced by 47c9d9c, c094867 and 21db25b, and
nine of its ten rows had a dead anchor.  Run sim/mutate_rmswire.sh instead:
it is the same wrapper, the same generics and the same landmarks, against
the store that actually ships, with four attribution columns.

The per-row map is in the header of this file.
EOF
exit 2
