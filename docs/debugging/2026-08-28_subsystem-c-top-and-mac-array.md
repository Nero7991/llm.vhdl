# Subsystem C gets a top level, and the multiply array it never had

**Date:** 2026-08-28
**Build:** `llama.vhdl` branch `fpga`. New files only:
`rtl/attn_mac_array.vhd`, `rtl/attn_block.vhd`, `ref/attn_mac_array_vec.c`,
`sim/tb_attn_mac_array.vhd`, `sim/tb_attn_block.vhd`, plus a `BASELINE_PASS`
raise (74 -> 76) in `sim/regress.sh`. **No existing RTL was modified.**
**Tools:** GHDL 1.0.0, **mcode** backend, `--std=08 -frelaxed
--max-stack-alloc=0`. `ghdl -e` produces no binary and exits 0, so
`ghdl -r <entity>` is run directly, always.
**Target:** `xcvu33p-fsvh2104-2L-e` (SQRL FK33), Qwen3.8-27B, N = 2.
**No Vivado was run.** Every number below is a simulation count or a
transcription from a prior measurement with its date named.

## The question, verbatim

> Subsystem C has **eight real leaf units, each with a passing testbench, and
> no top** [...] plus three skeletons that instantiate nothing and are NOT
> implementations. There is no `attn_block.vhd`. A completeness audit recorded
> that C "has no multiply array" and that 6 of 13 spec units are missing.
> **Establish for yourself which spec units exist and which do not** [...]
> **Build `rtl/attn_block.vhd`**, subsystem C's top, following
> `gdn_block.vhd`'s conventions exactly [...] Implement whatever spec units are
> genuinely missing and are needed to make the block produce a result, the
> multiply array included.

Symptom numbers at the moment of asking: 0 lines of subsystem C top level,
8 verified C leaf units, 0 of them instantiating another,
`sim/regress.sh` at 74 PASS / 0 FAIL.

## The answer, up front

**The 6-of-13 figure is still exactly right, and it is now 1 of 13.** Four of
the six missing units (`attn_lane`, `attn_score_tree`, `attn_acc`, `attn_ctrl`)
are implemented here; a fifth (`attn_qk_norm`) needed no new file because
`rtl/rmsnorm_rs.vhd` already is that unit and `attn_block` instantiates it
directly; the sixth (`attn_kv_axi`) is **not written** and the KV cache appears
as a one-cycle memory port instead, which is the same boundary `gdn_block`
draws around the recurrent state. `rtl/attn_block.vhd` runs the whole chain --
QK-norm, IMROPE, the write-side quantizer with the `v_ref` fold, the score MACs,
the online softmax with its rescale passes, the reciprocal, the sigmoid gate and
the BFP pack -- and emits a `y` stream that is **bit-identical across three
consumer handshake configurations** and whose `y_exp` **tracks its source
scale exactly**. The MAC array is bit-exact against a new C reference checked by
six oracles and mutation-tested 8 of 8 killed. **Nothing in C is stubbed**; one
unit is absent and is replaced by a port, and the schedule is the slow
strictly-sequential one, both stated in the RTL headers.

## The unit audit, walked against `rtl/` rather than taken on trust

The C skeleton's section 2 table lists 13 units. Checked file by file on
2026-08-28:

| # | Spec unit | Existed before today | Now |
|---|---|---|---|
| 1 | `attn_qk_norm` | **no `attn_qk_norm.vhd`** -- but the spec's own line for it is "wraps the existing `rmsnorm_rs` at `LANES = 1`", and `rtl/rmsnorm_rs.vhd` exists and is verified bit-exact against `rtl/rmsnorm.vhd` | instantiated directly by `attn_block`; **no wrapper file written**, because a wrapper that only renames ports is a seam with no content |
| 2 | `attn_twiddle` | `rtl/attn_twiddle.vhd` | unchanged, instantiated |
| 3 | `attn_rope` | `rtl/attn_rope.vhd` | unchanged, instantiated |
| 4 | `attn_kv_quant` | `rtl/attn_kv_quant.vhd` | unchanged, instantiated |
| 5 | `attn_kv_axi` | **MISSING** | **STILL MISSING.** Replaced by a memory-port boundary; see below |
| 6 | `attn_lane` | only `rtl/attn_lane_skel.vhd`, a DSP pricing harness that computes an XOR digest | **IMPLEMENTED**, inside `rtl/attn_mac_array.vhd` |
| 7 | `attn_score_tree` | **half of it existed**: `rtl/attn_score_q12.vhd` is the alignment, the s32 sum and the Q12 conversion. The multiply and the per-head adder tree did not | **IMPLEMENTED**, inside `rtl/attn_mac_array.vhd` |
| 8 | `attn_acc` | **MISSING** | **IMPLEMENTED**, inside `rtl/attn_mac_array.vhd` |
| 9 | `attn_softmax` | `rtl/attn_softmax.vhd` | unchanged, instantiated (G copies -- see the deviation) |
| 10 | `attn_recip` | `rtl/attn_recip.vhd` | unchanged, instantiated |
| 11 | `attn_gate` | `rtl/attn_gate.vhd` | unchanged, instantiated |
| 12 | `attn_emit` | `rtl/attn_emit.vhd` | unchanged, instantiated |
| 13 | `attn_ctrl` | only `rtl/attn_c_ports_skel.vhd`, which ties every output off | **IMPLEMENTED** as `attn_block`'s own phase machine |

So the audit's "6 of 13 missing" was accurate and is **not** stale: units
1, 5, 6, 7, 8 and 13 had no implementation. `attn_score_q12` is not in the
13-unit table at all, which is why the table said `attn_score_tree` was missing
while a file with a very similar job existed.

`rtl/attn_rescale_skel.vhd` is the third C skeleton and is also not an
implementation; it is not in the 13-unit list either, and it prices the
*alternative* to putting the rescale mode on the lane. It is untouched.

**Numbers that follow from the audit and were checked, not assumed:** at the
27B/N=2 geometry `attn_mac_array` is `G x KV_BLOCK = 6 x 32 = 192` lanes, which
is exactly C spec 3.0's normative `MACS = 192`, and `ACC_N = HEAD_DIM/KV_BLOCK
= 8`, inside the measured <= 16 limit of C spec 2.6.

## What `attn_block` does, end to end

Per invocation (one attention layer, one token, one card), strictly
sequentially, for each KV head `h` and then over the group's `G = N_QH/N_KVH`
query heads:

1. **K in** -> `rmsnorm_rs` with `attn_k_norm` -> `k_norm_exp[h]` (the norm's
   own `o_exp`, **never** `k_exp`) -> `attn_rope` fed by `attn_twiddle` ->
   `attn_kv_quant` (`is_v = 0`) -> a 272-byte-shaped record: header first, then
   `NBLK` mantissa blocks, written to the cache port at `(K, h, cur_pos)` and
   held in the bypass registers.
2. **V in** -> `attn_kv_quant` (`is_v = 1`, `src_exp = v_exp`, no norm and no
   rope) -> record written and bypassed; `v_ref[h]` folded to the minimum of
   the record's block exponents.
3. **Q heads** -> `rmsnorm_rs` with `attn_q_norm` -> `q_norm_exp[qh]` ->
   `attn_rope` -> a Q register plane.
4. **The sweep**, in the pinned order `[cur_pos, 0, 1, ..., cur_pos-1]`: fetch
   the K record (bypass for `cur_pos`, the cache port otherwise), present its
   header to `G` `attn_score_q12` instances, feed `NBLK` blocks through the
   array in score mode, let each score reach its `attn_softmax`; run one uniform
   rescale pass over all `NBLK` accumulator indices when any head's maximum
   rises (`f = 2^Q` for the heads that did not, which site 5d makes an exact
   identity); fetch the V record, apply the site-3 alignment
   `v_mant asr (e_v[b] - v_ref)`, and feed `NBLK` blocks through the array in PV
   mode.
5. **The output stage**, per query head: `attn_recip` on `s` -> `(p, r)`;
   `attn_gate` over `HEAD_DIM` elements reading the accumulator out of the array
   and the gate word out of A's activation memory (the *second* half of each
   head's `wq` output, per 1.1(a)) -> `y_pre` scratch.
6. **`attn_emit`** over the whole `N_KVH x G x HEAD_DIM` scratch, aligning the
   two per-KV-head grids `v_ref[h] + R_Q - 1` to their minimum and packing to
   int16 with one `y_exp`.

## The procedure, in the order it was run

Deliberately "make the small thing provable first", so a later failure reads as
an integration property rather than as arithmetic.

1. **Read the three contracts before writing a line.** `gdn_block.vhd` and
   `sim/tb_gdn_block.vhd` for the conventions, the C spec's 2.1 numeric
   contract and 3.1/3.2 schedule for what the array must compute, and the eight
   leaf entities for their exact handshakes. The `x_rdata` contract
   (`attn_kv_quant.vhd:103-104`) is the one that had to be read rather than
   guessed: *data holds `mem[addr]` the cycle after an edge at which the enable
   was high, AND is HELD unchanged across any edge at which it was low.* A
   memory model that updated unconditionally would let a unit read at the wrong
   instant and pass.

2. **Write the C reference for the array BEFORE the RTL**, with its oracles and
   its mutation harness, so the RTL had something to be wrong against.

3. **Mutation-test the reference against itself.** Two mutations survived the
   first pass and both were reference defects, not RTL ones. See "Measurement
   traps".

4. **Write the array, check it bit-exactly, then sweep the phase gap.**

5. **Teeth-check the array's guards** against deliberately broken copies -- four
   broken RTL copies and three broken harness copies.

6. **Only then write the block**, and check it with properties that need no
   oracle, because C has no block-level oracle and one written today would be
   derived from the same RTL it checked.

7. **Teeth-check every block property** the same way.

## The evidence

### The C reference agrees with its six oracles, and kills 8 of 8 mutations

```
attn_mac_array_vec: 24 cases, QH=2 DT=8 ACCN=4 NPOS=6 -> attn_mac_array_vec.txt
  rescale passes 44, accumulator saturations 0
  ORACLE 1 (double)      mismatches 0
  ORACLE 2 (int128 rev)  mismatches 0
  ORACLE 3 (width bound) violations 0
  ORACLE 4 (replay/div)  mismatches 0
  ORACLE 5 (f identity)  violations 0
  all oracles agree

  M1 score tree drops last term         KILLED   (O1=956 O2=956 O3=0 O4=0 O5=0)
  M2 rescale rounds half to zero        KILLED   (O1=0 O2=0 O3=0 O4=1397 O5=0)
  M3 rescale rounds half away from zero KILLED   (O1=0 O2=0 O3=0 O4=323 O5=0)
  M4 e read as signed 13-bit            KILLED   (O1=0 O2=0 O3=0 O4=1146 O5=0)
  M5 v read as unsigned                 KILLED   (O1=0 O2=0 O3=0 O4=5628 O5=0)
  M6 rescale after PV, not before       KILLED   (O1=0 O2=0 O3=0 O4=2912 O5=0)
  M7 partials summed across blocks      KILLED   (O1=960 O2=960 O3=0 O4=0 O5=0)
  M8 rescale identity broken at f=2^Q   KILLED   (O1=0 O2=0 O3=0 O4=3646 O5=798)
```

Oracle 3 has never fired on real data. It is a width guard, it is the premise
`attn_score_q12`'s own s32 argument rests on, and it is stated so as an open
item rather than claimed as a proven property.

### The array is bit-exact, at the test shape and at the real one

```
tb_attn_mac_array: PASS -- 24 cases, QH_TILE=2 DIM_TILE=8 ACC_N=4 GAP=2,
                   every partial and every accumulator bit-exact, ovr='0'
tb_attn_mac_array: PASS ... GAP=0
tb_attn_mac_array: PASS ... GAP=1
tb_attn_mac_array: PASS ... GAP=5
tb_attn_mac_array: PASS -- 8 cases, QH_TILE=6 DIM_TILE=32 ACC_N=8 GAP=2,
                   every partial and every accumulator bit-exact, ovr='0'
```

The last line is the **normative `MACS = 192` geometry**: 6 query heads x 32
dims, `ACC_N = 8`.

### The array's guards, against deliberately broken copies

Four broken RTL copies, run against the unbroken bench:

```
MUT-A rescale without the round bias:            killed
    case 2 head 0 elem 1 acc got 5.58986e5 want 5.58987e5
MUT-B p_blk taken from stage 1, not stage 2:     killed
    case 0 pos 0 head 0 block 0 partial got 0 want 8
MUT-C e read as signed 13-bit:                   killed
    case 4 head 0 elem 0 acc got 3.07472e5 want -3.07472e5
MUT-D score tree drops the last term:            killed
    case 0 pos 0 head 0 block 0 partial got 7 want 8
```

Three broken *harness* copies, for the three assertions no value check can
reach (the harness is the deliberately broken thing here because the assertions
police the CALLER, not the unit):

```
rescale the same block index on consecutive cycles:
  attn_mac_array: rescale of a block whose previous write is still in the
  pipeline.  It multiplies the STALE accumulator and then overwrites the
  pending write.                                                       FIRES
two operand modes offered in one cycle:
  attn_mac_array: two operand modes offered in one cycle.  The lane has ONE
  multiplier; one of these operations is being dropped, not queued.    FIRES
p_ready tied low:
  attn_mac_array: a partial was offered while p_ready was low.  This stream has
  no ready in the datapath, so that partial is LOST, not delayed.      FIRES
```

All three are silent in every unbroken run.

### The block passes, at two shapes, across three consumer configurations

```
tb_attn_block: err='0' rope_sat='0' kv_sat='0' y_sat='0' z_sat='0'
               rescale_max=2 stalled beats=126
tb_attn_block: PASS -- 3 consumer configurations, 64 elements each, y stream
               bit-identical across all of them, y_exp tracks vin_exp exactly,
               the current position was never read back, y_exp(run 0) = 15
```

and at a second shape (`HEAD_DIM = 64`, `KV_BLOCK = 8` so `NBLK = 8`,
`N_QH = 6` / `N_KVH = 2` so `G = 3`, `N_ROT = 16`, `cur_pos = 5`):

```
tb_attn_block: err='0' ... rescale_max=1 stalled beats=766
tb_attn_block: PASS -- 3 consumer configurations, 384 elements each, ...
```

and at the `cur_pos` boundaries, which are the cases where the pinned
processing order `[cur_pos, 0, 1, ..., cur_pos-1]` degenerates:

```
JOB_POS=0   PASS, rescale_max=0, y_exp(run 0) = 14   -- bypass ONLY, no cache
                                                        read at all
JOB_POS=1   PASS, rescale_max=1, y_exp(run 0) = 15   -- bypass then one
                                                        cache position
JOB_POS=2   PASS, rescale_max=1, y_exp(run 0) = 15
JOB_POS=3   PASS, rescale_max=2, y_exp(run 0) = 15   -- the default
JOB_POS=5   PASS (at the second shape)
```

`stalled beats` is reported on purpose. A zero back-pressure count is a
question, not a result -- the 2026-08-27 `COL_GAP=3` case went from "0 refused
columns" to "167 refused columns" as the result of a bug **fix**.

### Every block property, against a deliberately broken copy

| Property | Mutation | Result |
|---|---|---|
| P5 exponent contract | `e_grid` a constant instead of `v_ref + R_Q - 1` | **FIRES**: "vin_exp was raised by 3 and y_exp moved from -5 to -5 instead of -2" |
| P7 bypass | `is_byp` forced low, so the sweep reads the cache at `cur_pos` | **FIRES**: "the sweep read the CURRENT position out of the cache" |
| P2 handshake invariance | `rn_w <= kn_mant` (the norm weight read LIVE, not from the latch) | **FIRES**: "run 1 element 0 = -5129 against run 0's -6591" |
| P3 ordering rule | `y_hdr_valid` tied low | **FIRES**: "the first y element was offered before y_hdr_valid ever stood" |
| P1 element count | `attn_emit`'s `m_ready` tied high, ignoring `y_ready` | **FIRES**: "run 1 emitted 22 elements, expected 64" |
| P6 descriptor guard | the `cur_pos >= ctx_len` test disabled | **FIRES**, both halves: "did not raise err" and "did not return to idle after aborting" |
| elaboration guard | `HEAD_DIM = 32` (not an even power of two) | **FIRES**: "kq_scale = 1/sqrt(HEAD_DIM) is irrational and cannot be folded into the exponent" |

**P4's `dbg_ep_lost` half has never fired.** It is a sticky synthesizable
detector for an `e_p` arriving while the previous one is unconsumed, and no
mutation was constructed that produces one. It is therefore an *unproven*
guard and is listed as such in the open items. A property that has never fired
is not a property.

### The regression gate

Full both-suite run, `--jobs 3`, on the final tree, after raising
`BASELINE_PASS` 74 -> 76:

```
PASS       sim:tb_attn_block                      3s
PASS       sim:tb_attn_mac_array                  1s
 suite sim   PASS 50   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 76   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 76 passing, matches the recorded floor of 76
 REGRESSION: PASS
```

Neither new testbench needs a `SLOW_TBS` row and neither is excluded from
`--quick`: 3 s and 1 s respectively.

## Measured and REJECTED -- do not retry

* **An oracle that reads a local temporary instead of the published result.**
  The reference's first version computed each partial into a loop-local
  accumulator, checked THAT against the double and `__int128` oracles, and then
  applied the mutation to the published array. Mutation M7 ("sum the partials
  across blocks", i.e. produce one number per head instead of one per exponent
  block -- the single most consequential thing the array could get wrong, since
  it destroys the per-32 alignment `attn_score_q12` exists to perform)
  **SURVIVED every oracle**. Fixed by making the oracles read the array the
  vector file carries. An oracle that does not read what is published is
  checking a variable, not a result.

* **Random data as a test of a rounding mode.** Mutation M3 ("round half AWAY
  from zero" instead of "round half toward +infinity") also survived, at 0
  oracle hits over 24 cases x 6 positions x 2 heads x 32 elements. The three
  plausible rounding modes agree on everything except EXACT TIES, and random
  operands essentially never produce one. Fixed with a dedicated shape 8 that
  forces the tie by construction (`e = 2^11`, `v = -1`, `f = 1`, so the rescale
  argument is exactly `-2^11`); M3 then dies with 323 oracle-4 hits. **Do not
  conclude a rounding mode is tested because a large random vector set passes.**

* **Building a block-level arithmetic oracle for C today.** It would have to
  model `rmsnorm`, IMROPE, the BFP quantizer, the online softmax, the
  reciprocal-multiply, the Q15 sigmoid and the BFP pack at once, and it would
  be derived from the same RTL it checked. C spec 3.11 item 1 names
  `ref/attn_gated_fx.c` as the deliverable; it does not exist. Written now it
  would be a reference *for this implementation*, which
  `sim/tb_llama_top.vhd`'s header correctly calls worse than no reference
  because it looks like coverage. `sim/tb_attn_block.vhd` checks seven
  properties that need no oracle instead, and says so in its first paragraph.

* **A single constant as the RULE-2 poison value.** The bench poisons every
  latched input (both norm weight vectors and all four exponent ports) from the
  cycle after its latch pulses. With ONE poison value all three runs are
  identically wrong and every property passes. The poison value is therefore
  **run-dependent**, which is what makes a live read show up as a
  cross-configuration difference. This is `gdn_block`'s `W_MOVE`/`SC_MOVE` axis
  and it is the only instrument that catches this class.

* **Comparing a scaled run without resetting the sequence.** P5 raises
  `vin_exp` by 3 and requires the mantissas to be unchanged and `y_exp` to move
  by exactly 3. It failed at first, and the RTL was right: `v_ref` is a
  **per-SEQUENCE** minimum, deliberately not reset per token, so run 0's fold
  survived into run 2 and the scaled run aligned its cache blocks against the
  previous run's reference. The bench now pulses `kv_seq_rst` per run. The
  first reading of this was "the block does not track scale", which was wrong,
  and it is recorded because the correct behaviour and the defect look
  identical from the y stream alone.

* **Scaling only the current token's V exponent in P5.** The cache records for
  positions `0..cur_pos-1` are written by earlier tokens at the same scale in a
  real sequence, so the bench biases the model's stored V headers by the same
  delta. Without it the experiment asks whether `y` is invariant under a scale
  change applied to ONE of the `cur_pos+1` positions, which it is not and
  should not be.

## Measurement traps hit

* **`ghdl -e` on the mcode backend produces no binary and exits 0**, and
  `--max-stack-alloc=0` is a **run-time** option that `ghdl -a` rejects with
  `unknown command option`. Both are documented in this repo and both cost time
  again.

* **VHDL is case-insensitive, so a loop variable `g` HIDES the constant `G`.**
  GHDL reports it as `warning: declaration of "g" hides constant "g"` at seven
  sites and compiles happily. The GQA group size and the loop index would have
  been the same identifier inside every generate body. `rtl/attn_rope.vhd`'s
  own header records the same trap costing a run in `tb_attn_recip`. All loop
  variables renamed to `gg`.

* **Two processes driving one unresolved signal elaborates with no line
  number.** `hdr_seen` and `first_y` were re-armed by the driver and set by the
  collector; GHDL says only `several sources for unresolved signal / error
  during elaboration`. Re-armed inside the collector off `blk_start` instead.
  This is the third time this exact failure is recorded in this repository.

* **A testbench generic and a signal cannot share a name, case-insensitively.**
  `CUR_POS`/`cur_pos` and `CTX_LEN`/`ctx_len` collided; renamed `JOB_POS` and
  `JOB_LEN`.

* **A registered read's output stands for exactly one cycle.** The first
  version of the accumulator-readback loop waited TWO edges after asserting
  `rd_valid` and then asserted `o_valid = '1'`, which reads the idle cycle and
  reports a failure on a perfectly good unit.

* **A combinational operand bus built from a counter that the same edge
  increments presents the NEXT item's data with THIS item's label.** The block's
  first version drove `ar_scq`/`ar_sck` from `blk`, which is incremented in the
  same edge that raises `ar_scv`. Fixed with a registered `opb` assigned
  alongside the valid. This is `gdn_conv`'s `tvalid` shape and `gdn_block`'s
  `cv_seg` shape, found here by inspection before the first run rather than by
  a failing value.

* **`sim/regress.sh`'s `FAIL_RE` is a CASE-SENSITIVE `grep -aqE` carrying six
  literals**: `IS NOT`, `IS WRONG`, `MISMATCH`, `FAILED`, `DIVERGES` and
  `\bFAIL\b`. Every new `report` string here was checked against all six; the
  failure paths say "RESULT bad" and "mismatches" in lower case for that
  reason.

## What is NOT implemented, and what is deliberately different

Stated here rather than only in the RTL headers, because the RTL headers are
not what anyone reads first.

0. **It is announced at time zero.** `attn_block` carries a `report ...
   severity note` process, following `llama_top`'s
   `*** UNIT C IS A STUB ***` convention, naming the absent unit and the four
   things it would have provided. It deliberately does NOT raise `err`: `err`
   is an abort condition D acts on, a flag that every legal job asserts is a
   flag that gets turned off within a week, and an absent AXI master is a
   build-time fact rather than a run-time event.

1. **`attn_kv_axi` does not exist.** The KV cache is a one-cycle memory port
   (a write port and two read ports), which is precisely what `gdn_block` does
   with the recurrent state -- 2 MiB and DDR-resident by B spec 2.4, a port
   there. **This is a boundary and not a stub**: it computes nothing, invents no
   value and fabricates no exponent, and the port contract is the one a BRAM or
   an HBM read stage presents. What it does NOT cover: 4 KB burst splitting, the
   16-byte record-phase realignment C spec 3.0 introduces, drain-then-flush on
   `start`, and **`done` gated on BRESP** (C spec 2.7 requires that, and the
   window it protects is milliseconds wide today, so it would pass every test
   and fail only under a future pipelining change).

2. **`G` exp cones instead of one shared cone, and this costs DSP.** C spec 3.1
   shares ONE pipelined EXP_ROM cone across the group's query heads.
   `attn_softmax` contains its own cone and cannot be time-shared, because it
   holds one head's `m_g` and `s` for the whole sweep. The block therefore
   instantiates `G` of them: at `G = 6` that is 48 DSP against the 8 the spec
   books, so **C's aux row moves 47 -> 87 and C's total 431 -> 471** (DERIVED
   from C skeleton 3.3's own rows; not measured, no Vivado was run). The
   alternative is `QH_TILE = 1`, which costs a factor of `G` in KV read
   bandwidth -- exactly the redundancy the GQA grouping of 2.4 exists to remove.
   Hoisting the cone out of `attn_softmax` fixes it properly and modifies a
   verified unit.

3. **The schedule is the slow one.** No two-position PV lag, no group overlap of
   the QK-norms, no lockstep K and V fetch, and the gate feed walks four cycles
   per element against the spec's one. C spec 3.7's cycle budget assumes all
   four. The values are unaffected: the online softmax's processing order is
   part of the numeric contract and is preserved exactly.

4. **The `qg` gate re-read is one element per cycle**, not the 512-bit block
   port of C spec 3.10. Same values, more cycles.

5. **The block's own `v_ref` fold, not `attn_kv_quant`'s.** That unit has one
   fold register and C spec 2.1.4 needs one per (layer, KV head); with one
   shared instance its own `v_ref` output would mix the heads. The block folds
   per head from the header the unit publishes and leaves the unit's output
   open. `VREF_INIT = 127` is passed through anyway so the leaf's own testbench
   keeps meaning what it meant.

## What I would run for area and timing, and did not

No Vivado, at instruction. The two runs that would make the composite real:

* `sim/ooc_micro.tcl` on `attn_mac_array` at `QH_TILE = 6, DIM_TILE = 32,
  ACC_N = 8` on `xcvu33p-fsvh2104-2L-e` at 3.333 ns, with
  `set_operating_conditions -voltage {VCCINT 0.717}` after `opt_design`, and a
  DSP48E2 census reconciled against the utilisation count. The acceptance is
  **DSP = 384** (2 per lane, the 2026-08-23 measurement confirmed routed at 64
  lanes on 2026-08-24) with `AREG/BREG = 1` on every tile. If it is not 384 the
  array is not the structure C's budget prices.
* The same, place-and-routed, for Fmax at 192 lanes. C spec 3.13 item 2 and the
  C skeleton's item 5 both name this as the largest open risk and both say **do
  not extrapolate** from the routed 339.6 MHz at 64 lanes: broadcast fanout
  grows with lane count and the 64-lane limiter had already moved to the
  DSP-to-DSP cascade. The gate is `routed Fmax >= 237.812 MHz MEASURED at
  VCCINT 0.717 V`, not a 0.85 V figure restated afterwards.

## Open, not yet answered

* **`dbg_ep_lost` has never fired.** No mutation was constructed that produces a
  lost `e_p`. The detector is written and wired and is not yet evidence of
  anything.
* **Oracle 3, the `|partial| < 2^27` width bound, has never fired either.** It
  is the premise `attn_score_q12`'s s32 argument rests on and it is only
  asserted, not exercised.
* **There is no block-level arithmetic oracle**, so nothing here says the block
  computes attention. It says the block sequences ten units, honours every
  handshake, keeps its output invariant under consumer skew, and puts its output
  on a scale derived from its inputs. C spec 3.11 items 1 and 3 (the job-level
  RTL-versus-reference run at `ctx_len` in {1, 2, 31, 32, 33, 255, 256, 2047,
  2048}) remain entirely undone.
* **`attn_block` has never been instantiated by `llama_top`.** The C stub there
  is still the stub; wiring the block in is the next seam and it is not this
  work.
* **No synthesis of anything.** The `G`-cone DSP figure above is arithmetic on
  the skeleton's own rows, not a measurement.
* **`ctx_len` is checked only against `cur_pos`.** C spec 3.9 also requires
  `ctx_len > MAXCTX` and `layer >= MAXLAYERS` checks; `MAXCTX` is not a generic
  of this block (the cache is a port, so the block does not own the allocation)
  and `layer` is already range-constrained by its port subtype.
* **One token only.** `kv_seq_rst` is exercised, and the multi-token behaviour
  of `v_ref` -- which is the whole reason the fold is per sequence -- is
  exercised only in the negative sense that the bench had to reset it per run.
