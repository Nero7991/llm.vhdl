# Overnight status, 2026-08-25 into 2026-08-26

Written for someone who was asleep. Two things need a decision; everything else
is measured and committed.

## The two decisions owed

### 1. Amend B §2.1.4, or keep it as pinned

**One amendment, covering two sites, not two amendments.** Both are implemented
behind generics defaulting FALSE, both units are bit-exact in all four
combinations, and the corrected form has been synthesized.

| mode | median | p95 | max | worst tk=0 | first tokens lost entirely |
|---|---|---|---|---|---|
| **pinned (today's spec)** | 0.654 | 4768.00 | 5189.00 | 5189.00 | **3** |
| `D_NORM` alone | 0.602 | 16558.63 | **37413.90** | 37413.90 | 3 |
| `TK0_ED` alone | 0.666 | 9.92 | 1218.04 | 1218.04 | 0 |
| **both** | 0.605 | **1.20** | **3.47** | **1.11** | **0** |

State error in LSB of the unit's own grid, over the physically realizable
columns. **The denominators differ between rows**: the `TK0_ED` rows exclude 12
columns that §2.1.6 flags as exponent errors, so those rows are over 276
columns and the others over 288. The p95 and max are therefore not taken over
the same set; the ranking is unaffected but the exact numbers are not strictly
comparable. Disclosed in
`docs/debugging/2026-08-26_gdn-first-token-dm-grid.md`. "Lost entirely" means the first token's state came out identically
zero against a non-zero oracle.

- **`D_NORM`**: quantize `d` on its own grid instead of inheriting `e_d`.
- **`TK0_ED`**: at `tk = 0`, take `e_d = e_v` instead of `min(e_v, ske)`,
  because `ske` there is `se_j + 17` computed from a state that does not exist.

**Cost of adopting both: nothing.** Synthesized at `LANES = 32`: 129 DSP,
24.5 BRAM, **305.6 MHz** -- identical DSP and BRAM to the pinned form and
slightly better timing, for +81 LUT and +154 FF.

**Do not adopt only the first one.** It is seven times worse than the pinned
recipe: normalizing `d` amplifies the error the phantom grid has already
introduced. That is the reason this is one decision.

What adoption costs elsewhere: `gdn_err.c` re-derivation, §2.10's precision
result re-run, and deleting the `TOL_S_TK0`/`TOL_O_TK0` generics that currently
exist only to hold known defects.

### 2. B's `LANES` for the recurrence sweep

`LANES = 32` and `LANES = 64` are both now measured, not projected:

| `LANES` | DSP | Fmax | II | sweep | BRAM |
|---|---|---|---|---|---|
| 32 | 129 | 302.5 MHz | 4 cyc/col | 1.95 ms (2.18 with the head drain) | 24.5 |
| 64 | 257 | 301.9 MHz | 2 cyc/col | 0.98 ms | 48.5 |

`LANES = 64` works, but +128 DSP takes the die from its ~90.3% floor to roughly
94%. My read is that 32 is the right choice and 64 is not affordable, but the
DSP budget is yours.

## What was built

Five real RTL units. Four are verified two ways -- bit-exact against a C
reference in a different language, AND real-valued against a double-precision
oracle in a different number system. **`l2norm_rs` is the exception and the
blanket claim was false for it:** it has no C reference, and is verified
against a VHDL `math_real` golden plus a mutation campaign. That is a weaker
guarantee, and it is the unit whose recipe was found broken in the first place.

| unit | what | headline | verified by |
|---|---|---|---|
| `rtl/gdn_recur.vhd` | §2.1.4 recurrence, sequential | 4·LANES+1 DSP, 318.9 MHz | C + oracle |
| `rtl/gdn_recur_pipe.vhd` | same, column-pipelined | **II = NB exactly**, same DSP | C + oracle |
| `rtl/gdn_conv.vhd` | §2.1.3 depthwise conv | 4·LANES DSP, 447 MHz, 0 BRAM | C + oracle |
| `rtl/gdn_scalar.vhd` | §2.1.3 scalar path (new) | 7 DSP, 0 BRAM, 327.8 MHz | C + oracle |
| `rtl/l2norm_rs.vhd` | fixed (see below) | 26 DSP, 300.0 MHz | VHDL golden + mutation |

## What was wrong and is now right

- **The L2 norm recipe pinned in `87fc976` was numerically broken** and its
  testbench certified it, because the golden was a second transcription of the
  same recipe. The q path emitted all zeros for `ssq >= 2^33`. Fixed, and the
  testbench rewritten against real arithmetic and mutation-tested.
- **B's schedule looked 14.5x out of reach and is not.** The sequential
  recurrence takes 58 cycles/column against §3.1's assumed 4; the pipelined one
  hits exactly 4. The budget's arithmetic was right all along -- the first unit
  was measuring its own control structure.
- **Three defects in §2.1.4's first-token handling**, of which the spec had
  already found one. See decision 1.
- **B §2.6's BRAM table is dimensioned for Qwen3.5-0.8B, not the 27B** -- every
  `2048` is the 0.8B's `key_dim` and "18 layers" is its layer count, while the
  target has 48 GDN layers and `inner_size = 6144`. Honest figure ~50-60 BRAM36
  per card against the ~18-20 written.
- **"Every term in the 89.5% is measured" was false** and is retracted. With
  tonight's measurements the honest die range is **90.3% to 92.7%** -- the
  FLOOR above the 90% line these specs keep invoking, not at it.
- **That 90% line is folklore for this part.** Every citation traces to AXU3EG
  (360 DSP) incidents, and the flagship one was an uninitialized inferred
  distributed RAM. Marked unvalidated.
- **C's QK-norm row was an 18-DSP skeleton**; the real unit is 22 at N=256, and
  a schedule check (never previously done) confirms 1 lane meets C's budget.

## Open, and honestly open

- The **rate** of the `tk = 0` defects in the real model is unknown. Their size
  is measured; how often `beta` reaches the range that triggers them is not,
  because `beta` is activation-dependent and no weight table settles it.
  Instrumenting llama.cpp's delta-net op to histogram `beta` would close it.
- **The head-boundary drain**, 11.7%, is measured and not eliminated: `k_n`,
  `q_s`, `eg` and `beta` are read off the ports, so a head boundary needs a
  ~60-cycle drain. Double-buffering removes it for ~4 Kbit. That is the 1.95 vs
  2.18 ms difference.
- **`gdn_recur_pipe` is stall-intolerant by construction.** It needs an elastic
  column buffer and a drain interlock in front of it before D's sequencer is
  designed against its port. Nobody has written that piece down.
- **No die-wide BRAM sum exists** the way the DSP sum finally does.
- The FK33 is still at wiper 68 / 0.717 V. Nothing was changed on the hardware.

## Where to read more

- `docs/debugging/2026-08-26_gdn-first-token-dm-grid.md` -- the defect cluster,
  the measurements, and the rejected alternatives.
- `docs/debugging/2026-08-26_gdn-recurrence-column-pipelining.md` -- the 14.5x
  miss, and the GAP-bisect procedure that found the pipelining bugs.
- `docs/debugging/2026-08-25_l2norm-recipe-collapse.md` -- the broken recipe and
  why its testbench could not see it.
