# Subsystem D: D-vec's first op, and the numeric contract that did not exist

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. New files only: `ref/seq_vec_res_vec.c`,
`rtl/seq_vec_res.vhd`, `sim/tb_seq_vec_res.vhd`, `sim/run_seq_vec_res.sh`,
`sim/mutate_seq_vec_res.sh`, `sim/mutate_ref_seq_vec_res.sh`. Nothing existing
was edited.
**Tools:** GHDL 1.0.0, **mcode** backend (`ghdl -r` run directly; `ghdl -e`
produces no binary and silently succeeds). gcc for the reference. **No
synthesis was run:** every resource number below is a COUNT FROM THE RTL and is
labelled DERIVED, not a measured utilisation.
**Target:** `MODEL = QWEN35_9B`, `NCARDS = 1`. hidden 4096, so the residual job
is n = 4096 and there are 128 of them per token.
**Predecessors:** `2026-08-27_d-sequencer-first-units.md`,
`2026-08-27_d-sequencer-opcode-decode.md`,
`2026-08-27_d-seq-scalar-ordering-audit.md`.

## The question

Pick the next D unit by DOWNSTREAM REACH -- which unit unblocks the most of the
rest of the sequencer -- and build it to the standard the three shipped units
set: an independent C oracle, mutation of the reference BEFORE any RTL exists,
mutation of the RTL after, at least three handshake configurations of which one
lags longer than the producer's own state count, and bit-exactness with no
tolerance.

## The answer

`rtl/seq_vec_res.vhd` exists and is verified over **12 configurations, all
passing**, bit-exact on every element of 64 cases against `ref/seq_vec_res_vec.c`,
with **15 of 15 reference mutations killed** and **19 of 20 RTL mutations killed
in every configuration** (the twentieth is killed in 3 of 5, correctly). The one
survivor is a proven equivalent mutant.

It is D-vec's **residual accumulate**, opcode `OP_VEC_RES`, and building it
required inventing the thing the skeleton spec lists as open item 9: **D-vec's
numeric contract**, which did not exist in any document. That contract, not the
RTL, is the deliverable.

**One real RTL defect was found, by a counting identity and not by a value
check** (below), and **three coverage holes were found in the testbench and the
vector set, each by a mutation that survived**. Two of the three are the same
masking trap in different clothes and are the most reusable result here.

## Why this unit, of the candidates offered

The remaining D work is: the region banks, the AXI grant mux with `S_GRANT`,
the base-array and codebook load, D-vec, and the E seam.

**D-vec is the only remaining part of D that DOES anything.** A, B, C and E
belong to other subsystems; D's three units so far walk the descriptor table,
translate opcodes to regions and police the locks, and between them they execute
zero of the eight opcodes. Three of the eight -- `OP_VEC_NORM`, `OP_VEC_RES`,
`OP_VEC_SWG` -- are D's own, and they are 5 of the 16 steps of every GDN block.

Within D-vec, the residual was taken first for four reasons, in order of weight:

1. **It is the only D-vec op whose contract is fixed by the block-float rules
   alone.** The norm needs an inverse square root and the swiglu needs a
   sigmoid; each of those is a recipe choice with its own table, its own Q
   format and its own history of collapsing in this project
   (`2026-08-25_l2norm-recipe-collapse.md`). Pinning the two-pass block-float
   skeleton and pinning a transcendental table in the same pass would make it
   impossible to say afterwards which of the two was wrong.
2. **It closes the residual exponent chain**, which every subsequent norm reads.
   Nothing downstream of it can be given a golden until it exists.
3. **It is executed 128 times per token**, twice per block for all 32 blocks --
   against 129 norms and 64 swiglus.
4. **It is the in-place update**, which both predecessor documents recorded as a
   DECISION rather than a derivation, and which is now made safe by a checkable
   invariant instead.

**Deliberately NOT taken, and why:**

- **The region banks.** Their open question -- can a bank deliver an
  unconditional 1-element write and a 1-cycle 512-bit read through a three-way
  source mux at the real clock -- is a SYNTHESIS question, and this pass may not
  run Vivado. Building them here would produce RTL and no answer, which is
  exactly the reasoning the opcode-decode pass used to defer them.
- **The AXI grant mux.** `S_GRANT` is a state INSIDE `seq_desc_fetch`, so a
  grant unit built now would be verified against a stub sequencer -- the
  condition that hid all four findings of the opcode-decode pass. It also
  cannot be given an independent oracle: a golden model of an arbiter that did
  not share the arbitration state machine would be the arbitration state machine
  written twice.
- **The norm and the swiglu**, for reason 1 above. They now have a skeleton to
  slot into: pass 1 forms the value and folds its magnitude, pass 2 requantises
  against a max-driven shift. Only their pass-1 arithmetic differs.
- **The E seam (skeleton spec hazard B7).** At `NCARDS = 1` there is no
  collective at all -- the row-parallel matvec writes ER directly -- so the
  hazard does not exist on the build target. This unit reads ER as an ordinary
  region, which is the spec's exit (iii), and at N = 1 that exit is free because
  there is no landing buffer to add. B7 returns at `NCARDS > 1` and is NOT
  resolved.

## The numeric contract, stated

`out[i] * 2^-oexp ~= x[i] * 2^-ex + e[i] * 2^-ee`, where the exponent is a count
of FRACTIONAL bits (larger exponent = finer scale), matching `rtl/bfp_pack.vhd`.
`MANT_W = 16`, `ACC_W = 32`, `SHMAX = ACC_W - MANT_W - 1 = 15`,
`KEEP = MANT_W - 2 = 14`.

```
q      = max(ex,ee), clamped to min(ex,ee) + SHMAX
sx     = q - ex,  se = q - ee          -- exactly one of them is >= 0
acc[i] = align(x[i],sx) + align(e[i],se)      align = left shift, or right
                                              shift with round half up
p      = msb_pos( OR of |acc[i]| )
sh     = max(0, p - KEEP)
oexp   = q - sh
out[i] = sat16( round_half_up(acc[i], sh) )
```

Five decisions inside that, each stated because each is a decision:

- **The clamp** exists because `q = max(ex,ee)` lets the larger-magnitude
  operand be shifted up without bound. Beyond `SHMAX` the other operand is below
  half an LSB of the kept grid, so rounding it away is the correct answer and
  not an approximation of one.
- **The OR, not a max.** `msb_pos` is monotone and OR preserves the highest set
  bit, so `msb_pos(a or b) = max(msb_pos a, msb_pos b)`: the OR of the
  magnitudes yields the same `p` as the maximum of them. An 8-way 32-bit max is
  three levels of carry chain; an 8-way OR is three levels of independent LUT2s.
- **At `sh = 0` the result is EXACT.** No rounding at all, `out = acc`.
- **At `sh > 0` at most one element saturates, by exactly one LSB**, and only
  when the maximum's rounding crosses 2^15. NEGATIVE saturation is unreachable
  by construction: round-half-toward-+infinity of `-(2^(p+1)-1)` is exactly
  `-2^15`, never below it.
- **Two passes, NO SCRATCH.** The maximum is not known until every element is
  formed. This unit re-reads both sources and recomputes, rather than spilling a
  32-bit intermediate as D's skeleton spec section 2.5 budgets. For THIS op the
  recomputation is one shift and one add and is free, while the scratch would be
  4,096 x 32 bits = 4 RAMB36 buying nothing. **The argument does not carry to
  the swiglu**, whose recomputation is a second LUT read and a second multiply;
  that scratch stays budgeted.

## The procedure, in the order it was run

1. **Write the C reference first, with oracles that share none of the integer
   path**, and make it print COVERAGE on every run rather than on request.
2. **Mutate the reference before any RTL exists.** 15 mutations. A kill requires
   an ORACLE's own message: counting a non-zero exit would score the coverage
   counter and the accumulator-overflow trap as oracles, and both of those are
   real but neither is an oracle.
3. **Write the RTL against the contract, applying the ordering rule at design
   time** (`o_exp` is assigned two FSM states and seven pipeline stages before
   the first write beat it qualifies).
4. **Run one configuration.** It failed immediately, on the write monitor's
   counting identity, and the defect was real (below).
5. **Sweep 12 configurations** -- the ack tied high, lagged 4, lagged 20; start
   held past the accept; in place and out of place; a polite memory and a
   hostile one; and the SAME vector file at 4, 8 and 16 lanes.
6. **Mutate the RTL, then READ every survivor.** Three of the four survivors were
   coverage holes and were closed; the fourth is an equivalence, proven by
   reading and not assumed.

## The evidence

### The reference, 64 cases, six oracles, coverage printed

```
seq_vec_res_vec: 64 cases, 6 oracles clean
  coverage: sh=0 10 | sh>0 54 | saturating clamp 1 | SHMAX clamp 32 |
            negative align shift 32 | n not a multiple of 8 42 |
            all-zero accumulator 3
```

The oracles, none of which restates the recipe:

| | oracle |
|---|---|
| O1 | real-valued error against a derived bound, in long double, from the ORIGINAL inputs. Every quantity is a dyadic rational inside a 64-bit significand, so the bound is checked with `<=` and not with a tolerance |
| O2 | normalisation range as exact integer inequalities: at `sh > 0` the largest output magnitude is in `[2^KEEP, 2^15]`; at `sh = 0` the output IS the accumulator; and no element exceeds 2^15 before the clamp |
| O3 | the sum formed ONCE, exactly, in 64 bits at the unclamped grid, then rounded ONCE. Agreement is a theorem (`round(A*2^k + B, k) = A + round(B, k)`), not a construction |
| O4 | invariance under a common shift of BOTH exponents: mantissas bit-identical, `oexp` moved by exactly k |
| O5 | the clamp pinned from both sides -- exactness where exactness is affordable, and `SHMAX` asserted statically from `MANT_W` and `ACC_W` |
| O6 | the rounding DIRECTION as a two-sided integer inequality with no magnitude bound and no floating point |

### Reference mutations, 15 of 15 killed

| # | mutation | killed by |
|---|---|---|
| R1 | the SHMAX clamp removed | the accumulator-overflow trap (**not an oracle**) |
| R2 | the SHMAX clamp one too generous | the accumulator-overflow trap (**not an oracle**) |
| R3 | output shift one too large | O2 normalisation range |
| R4 | output shift one too small | O1 |
| R5 | output exponent moves the wrong way | O1 |
| R6 | the final requantise truncates | O1 |
| R7 | the ALIGNMENT right shift truncates | O3 |
| R8 | the magnitude fold takes the raw accumulator | O2 |
| R9 | the saturating clamp removed, the cast wraps | O1 |
| R10 | `KEEP = MANT_W-1` | O1 |
| R11 | the operands subtracted rather than added | O1 |
| R12 | O4 shifts only `ex` (**a check of the CHECK**) | O4 |
| R13 | O1's bound widened AND the requantise truncated | O6 |
| R14 | the clamp one too TIGHT: precision lost, nothing overflows | O5 |
| R15 | `SHMAX` moved without `MANT_W`/`ACC_W` | O5 |

### The 12 RTL configurations, all PASS

```
done_ack tied HIGH (degenerate)                       PASS
done_ack lagged 4                                     PASS
done_ack lagged 20 (longer than the unit's 11 states) PASS
start held 3 cycles PAST the accept                   PASS
start held past the accept, ack lagged                PASS
7 idle cycles between jobs                            PASS
polite memory: no 'X' between reads                   PASS
out of place: the source must be untouched            PASS
out of place, ack lagged                              PASS
LANES = 4                                             PASS
LANES = 16                                            PASS
LANES = 4, out of place, ack lagged, start held       PASS
```

### RTL mutations, 19 of 20 killed in every configuration

Configurations: **A** ack tied high, **B** ack lagged 20, **C** out of place +
ack 4, **D** LANES = 4 + ack tied high, **E** start held 3 + ack lagged 20.

| # | mutation | result |
|---|---|---|
| N1 | the two operands' left-shift amounts swapped | killed A B C D E |
| N2 | the alignment round bias dropped | killed A B C D E |
| N3 | the SHMAX clamp one notch too tight | killed A B C D E |
| N4 | the alignment right shift clamped one notch too early | killed A B C D E |
| N5 | the magnitude fold takes the raw accumulator | killed A B C D E |
| N6 | the lane mask ignored in the magnitude fold | killed A B C D E |
| N7 | output shift one too large | killed A B C D E |
| N8 | output shift one too small | killed A B C D E |
| N9 | output exponent moves the wrong way | killed A B C D E |
| N10 | the output round bias dropped | killed A B C D E |
| N11 | the saturating clamp removed | killed A B C D E |
| N12 | the write byte-enable forced to all ones | killed A B C D E |
| N13 | the alignment reads the LIVE exponent ports (class (a)) | killed A B C D E |
| N14 | the group count read from the LIVE `i_n` (class (a)) | killed A B C D E |
| N15 | `done` a bare one-cycle pulse (class (b)) | killed **B C E**, survived A D |
| N16 | `done` raised before the pipeline drains | killed A B C D E |
| N17 | `ready` also high while a completion is held | **SURVIVED, equivalent** |
| N18 | the exponent published in S_DONE, after every beat (class (c)) | killed A B C D E |
| N19 | the pass-1 exit drops the `cptr` term | killed A B C D E |
| N20 | the write address taken one pipeline stage early | killed A B C D E |

**N15's survivor column is the expected one and is why both ack styles ship.**
Configurations A and D tie `done_ack` high, and with a prompt ack a held `done`
and a pulsed `done` are the same waveform. The lagged configurations are the
only ones that can tell them apart, and the tied-high configuration is the only
one that can catch a `done` register cleared inside the ack branch -- the
`gdn_head_emit` defect. Neither is weaker.

**N17 is an equivalent mutant, established by reading and not by the pass.**
`done_r = '1'` implies `state /= S_IDLE` in every reachable state: it is set only
in `S_LAT` (the zero-length path) and in `S_P2`, both of which assign
`state <= S_DONE` on the same edge, and it is cleared only in `S_DONE` with
`state <= S_IDLE` on the same edge and at reset. So the `done_r = '0'` term in
`ready` is redundant TODAY. It is kept because it stops being redundant the
moment any future state raises `done` without entering `S_DONE` -- the same
shape of argument as the M7/M8 equivalence in the first-units document.

### The measured cost

```
MEASURED 2071 cycles accept-to-done at n = 4096, LANES = 4   (2*ceil(n/L) = 2048)
MEASURED 1047 cycles accept-to-done at n = 4096, LANES = 8   (2*ceil(n/L) = 1024)
MEASURED  535 cycles accept-to-done at n = 4096, LANES = 16  (2*ceil(n/L) =  512)
```

**The overhead is exactly 23 cycles and is independent of the lane count**: 5
issue and prepare states, two pipeline drains of 7, two shift states, and the
completion edge. So the cost model is `2*ceil(n/LANES) + 23`, MEASURED at three
lane counts rather than derived.

At the 9B target (`hidden = 4096`, `LANES_V = 8`) one residual step is **1,047
cycles** against the skeleton spec's `2n/LANES_V = 1,024` budget, **+2.2%**.
128 steps per token is **134,016 cycles = 0.447 ms at 300 MHz** (DERIVED from
the measured per-step figure).

### Resource counts -- COUNTS FROM THE RTL, NOT MEASURED UTILISATION

No synthesis was run.

| | `seq_vec_res` at LANES = 8 |
|---|---|
| DSP48E2 | **0** |
| RAMB36 | **0** |
| FF, total | **~2,900** |
| of which, dominant term | **2,304 = 9 pipeline arrays x 8 lanes x 32 bits (79%)** |
| remaining | ~600: the job shadow ~200, the pass control ~100, the write port ~170, the valid/mask/group chain ~114, the FSM and flags ~16 |

The 0-DSP claim is a construction argument: there is no `*` on any datapath, and
the only products in the file are elaboration-time constants (`2**LOG2L`,
`2**(MANT_W-1)`). The 0-RAMB claim is structural: nothing in the unit is
memory-shaped, because the two-pass design deliberately has no scratch and the
regions are external.

**The obvious 224-FF saving was NOT taken:** stage S1's `a_x`/`a_e` are declared
`ACC_W` wide but can only hold `MANT_W + 2` significant bits before the left
shift, so 18 bits would do. It is 8% of the unit and it is left alone because
the width argument for the accumulator is the thing the whole clamp analysis
rests on, and narrowing one stage of it for 224 FF is a good way to break that
argument quietly. Recorded as DERIVED, not done.

Running total for D as built: `seq_desc_fetch` ~1,222 + `seq_region_lock` ~1,036
+ `seq_opdec` ~118 + `seq_vec_res` ~2,900 = **~5,276 FF, 0 DSP, 0 RAMB36**,
against D section 12's ~15-25K FF estimate.

## The defect that was found

**Symptom.** The very first run failed at 235 ns with
`write group 0, expected 1. Beats must be one per group, ascending from 0, none
twice.` -- two write beats for group 0, two cycles apart, on the smallest case
(n = LANES).

**Cause.** The pass-exit condition was "the read pointer has finished AND every
pipeline valid is '0'". But `v1` is assigned by the pipeline block on the SAME
edge the FSM reads it, so at the instant the last group is being latched into
stage 1, every valid still reads '0'. The FSM therefore declared pass 1 finished
one group early, entered pass 2 with that group still in the pipe, and emitted a
write beat carrying PASS 1's magnitude data -- followed by pass 2's own beat for
the same group.

**Fix.** The exit also requires `cptr = j_ng`, where `cptr` counts groups
ACCEPTED into the pipeline and is deliberately distinct from the read pointer,
which saturates during the drain.

**What found it, and what did not.** The value comparison would NOT have found
it on a longer vector: the second, correct beat overwrites the first, so the
region contents end up right. It was found by the write monitor's counting
identity -- one beat per group, ascending, none twice -- which is the assertion
class the `gdn_head_emit` document argues for and which no throughput metric
would have shown. It is preserved as mutation N19.

## Measured and REJECTED -- do not retry

- **"The clamp is exercised, so the alignment rounding is tested."** It is not,
  and this cost two rounds. Cases with `|ex - ee| > SHMAX` DO engage the clamp,
  but in all of them the surviving operand is left-shifted by 15 and sets
  `sh ~ 16`, so the clamped operand's entire rounding difference -- one LSB at
  the accumulator grid -- is shifted straight back out and the output is
  identical whether that rounding is a floor or a round-half-up. RTL mutation N2
  (drop the alignment round bias) SURVIVED every configuration on the first
  vector set. **A rule is only tested where its effect reaches the output.** The
  construction that works is to zero the OTHER operand, so nothing dominates,
  `sh = 0`, and the accumulator IS the output.
- **The same trap again, one level deeper.** With cases 9 and 10 added, mutation
  N4 (clamp the alignment SHIFTER one notch too early) still survived, for the
  identical reason: the deep-clamp cases 4, 11 and 12 all have a dominating
  left-shifted operand. Cases 13 and 14 zero it. **The second occurrence is the
  reason this is a rejected-approach entry and not a footnote: the fix for the
  first instance did not generalise, because it was written as two specific
  cases rather than as the property "the operand under test must be the one that
  sets the shift".**
- **"Clamp the alignment right shift at 31 instead of 17" as a mutation.** It is
  EQUIVALENT and it survived every configuration. For a `MANT_W` mantissa every
  right shift from `MANT_W` upward rounds to zero for both signs, so 17 and 31
  give the same answer. The reachable error is clamping one notch too EARLY, at
  15, where a mantissa at or above 2^14 rounds to 1 where the true answer is 0.
- **"Remove the SHMAX clamp entirely" as an RTL mutation.** `j_c`, `sxl` and
  `sel` are declared `natural range 0 to SHMAX`, so an unclamped value is an
  out-of-bounds assignment and the run dies on a LANGUAGE range check. A
  mutation the language catches has tested nothing about the design. One notch
  too tight stays in bounds, overflows nothing and loses precision silently,
  which is the dangerous direction and the one the reference's O5 exists for.
- **Poisoning the job ports AFTER the `START_TAIL` hold.** Mutation N14 -- the
  group count read from the LIVE `i_n` port rather than the job shadow --
  SURVIVED the `START_TAIL = 3` configuration, because holding `start` high also
  held the data valid for three more cycles and `S_LAT` is one cycle after the
  accept. `start` is a request LEVEL; the DATA is captured at the accept, so a
  producer is entitled to move it on immediately. **This is the polite-testbench
  failure the `gdn_emit_chain` w_mant document warns about, reproduced inside a
  testbench written specifically to catch it.**
- **Widening O1's bound as a standalone reference mutation.** On a correct
  recipe a looser bound cannot fail, so it is a no-op and scores a meaningless
  survivor -- the `attn_recip` N13 trap. It has to be widened WHILE the recipe is
  broken, and doing so showed that O1 was the ONLY oracle pinning the rounding
  direction. That is what O6 was added for.
- **Zeroing the out-of-place destination memory in the testbench.** Mutation N12
  (write byte-enable forced to all ones) survived the out-of-place configuration
  because a lane the DUT wrote that it should have masked reads as a plausible 0
  against a zeroed memory. The destination is POISONED at load in both modes now.

## Measurement traps hit

- **Two processes assigning one unresolved signal.** `n_write` was reset by the
  stimulus and incremented by the monitor. GHDL reports `several sources for
  unresolved signal` with the signal name but no line number, which this project
  has been bitten by before. The counter is reset by the monitor, at the ACCEPT.
- **Reading `i_n` off the PORT to label a measurement.** The cycle monitor
  latched the job length at `i_taken` and every job measured as n = 1 -- because
  the stimulus poisons that port 1 ns after the accept edge, which is inside the
  same clock cycle, so a process sampling on the next edge sees the poison. The
  length is carried on a separate stimulus-driven signal that is never poisoned.
  **The poison worked exactly as designed and the measurement was the casualty.**
- **`wait until rising_edge(clk)` resumes in the SAME delta as the edge**, so a
  `_taken` pulse the DUT assigns on that edge still reads as '0'. Every sample
  is taken 1 ns past the edge. Fourth time in this project.
- **`round_half_up` must NOT copy `floor_shr`'s `(v < 0) ? -1 : 0` shortcut for
  wide shifts.** The half-LSB bias is added BEFORE the floor, so once
  `2^(sh-1)` exceeds `|v|` the result is 0 for BOTH signs. The shortcut would
  return -1 for negative mantissas at wide alignment shifts, and those are
  reachable: the exponent fields are 16-bit signed and nothing bounds their
  difference. Found while designing the RTL's shift clamp, fixed in the C.
- **The reference's own O3 overflows int64 at a large exponent difference.** A
  16-bit mantissa shifted up by 60 is 76 bits. O3 skips those cases and says so;
  widening to `__int128` would only move the wall, and O1 and O5 cover them.
- **`-Wmisleading-indentation` on `for (...) fprintf(...); fputc('\n', f);`.**
  Harmless here, but it is noise at exactly the place a real warning would be
  scrolled past.

## Open, not yet answered

- **The numeric contract is a DECISION, not a derivation, and nothing has
  reviewed it.** In particular: the choice of `SHMAX` trades accumulator width
  against alignment precision, and `KEEP = MANT_W - 2` is inherited from
  `bfp_pack` without being re-argued for a two-operand sum.
- **No synthesis, so no Fmax**, and the claim most worth testing is the seven-
  stage split: each stage was given exactly one item from the project's timing
  list, but nothing has confirmed that an 8-lane 32-bit barrel shift plus its
  register closes at 300 MHz, nor that the 8-way 32-bit OR tree does.
- **The norm and the swiglu do not exist.** They reuse this skeleton -- pass 1
  forms the value and folds its magnitude, pass 2 requantises against a
  max-driven shift -- but each adds a table and a Q format that this pass
  deliberately did not pin.
- **This unit is not connected to `seq_opdec`.** It executes `OP_VEC_RES` but
  nothing issues it from the descriptor table yet, so the seam between D-ctrl's
  `job_*` group and D-vec's `i_*` group has never been exercised. That is the
  same "each unit against a stub of the other" condition the opcode-decode pass
  found four defects in, and it is the strongest candidate for the next pass.
- **The region banks still do not exist**, so the unstallable 1-cycle read and
  1-element write are modelled by a testbench and asserted as obligations.
- **Hazard B7 (E's unstallable stream into residual pass 1) is untouched** and
  returns at `NCARDS > 1`.
