# The three fmax limiters: bit-exact pipelining to 200 MHz on VU35P -2

Date 2026-09-26. Follows the block ratings (`docs/superpowers/specs/2026-09-25-block-ratings-design.md`,
commits caf373c..6f6eaf5).

## 1. Why

The ratings put three blocks below every other block on every rated part and grade (MEASURED,
routed, over-constrained, one draw each, MHz):

| row | top | VU33P -2LV | VU35P -2LV | VU35P -1 | VU35P -2 | VU35P -3 | critical path |
|---|---|---|---|---|---|---|---|
| v_swg | swiglu_mem | 83.4 | 84.5 | 93.0 | **111.6** | 124.5 | `a_vq` -> sigmoid index -> SIG_ROM -> 64-bit multiply -> shift, 32 levels |
| c_kv | attn_kv_axi | 114.9 | 114.3 | 131.9 | **151.1** | 147.3 | `GEN_RD c_max` -> issue arithmetic -> `alen`, 28 levels |
| c_attn | attn_block | 142.0 | 130.6 | 140.2 | **173.7** | 162.4 | `u_arr p_reg` (DSP out) -> score tree + overflow compare -> `er_r`, 14 levels |

The next-slowest blocks on VU35P -2 are b_gdn 254.3 and a_engine 264.0, so after these three
the card's core tier is bounded by blocks already above 250 MHz on that grade.

## 2. Goal and success criteria

- Each of v_swg, c_kv, c_attn rates **>= 200 MHz on `vu35p_jc_m2`** (`rate.py run <row>
  --device vu35p_jc_m2`), routed, over-constrained (WNS < 0 at the target), FRESH. This is
  the deployment goal's clock (27B on Jungle Cats at 200 MHz, 0.85 V).
- The same rows are re-rated on `vu33p_fk33` and recorded; the VU33P numbers do not gate.
- Every fix is **bit-exact**: each block's outputs, and the cycle-independent sequence of
  what it writes, are unchanged. Latency may grow only where the consumer is driven by a
  valid flag and nothing counts cycles across the change (section 4.3 is the one case that
  must be verified rather than assumed).
- One routed draw is not a result below the noise floor (0.4-0.75 ns): a row counts as
  meeting 200 MHz only if its achieved period is at least 0.4 ns inside 5.0 ns (>= 217 MHz),
  or two draws both reach 200 MHz. ESTIMATE of the margin; it is the recorded floor.

Out of scope: any value change (a different sigmoid approximation, different rounding),
area optimisation beyond what the splits cost, the levers (SWEEP_PIPE/SCORE_EARLY stay off),
and any card build before all three rate.

## 3. Approach

Hand-pipelining with valid-tag propagation, one block at a time, smallest first: c_attn,
c_kv, v_swg. The project's own timing rule governs the splits: never two of {barrel shift,
wide add, wide compare, bus mux, multiply} in series within one stage
(`rtl/attn_mac_array.vhd:64`). Each split lands as its own commit with before/after ratings.

Rejected: Vivado retiming (tool-run dependent, which defeats a stable per-block rating, and
it cannot cut c_kv's issue feedback loop); changing the arithmetic (needs new oracles).

## 4. The three changes

### 4.1 c_attn: `attn_mac_array` S2 score path

Today S2 (M_SCORE) sums DIM_TILE products into `t` and compares `t` against the P_W range
for `er_r` in the same cycle (`rtl/attn_mac_array.vhd:441-455`): a wide add tree and a wide
compare in series.

Change: S2a registers per-head partial sums (the tree split at its midpoint); S2b adds the
halves, performs the range compare into `er_r`, and registers `pd_r`/`pv_r`/`pb_r`. The M_PV
and M_RS read-modify-write paths are not touched (they are not on the critical path and their
accumulator write order must not move). `mode2`/`blk2` gain a third copy for S2b.

Consequence: `p_valid`/`p_data`/`p_blk` leave the array one cycle later. See 4.3.

### 4.2 c_kv: `attn_kv_axi` read-master issue

Today one cycle computes `lim_rec := c_max + RBUF - 2`, clamps it against
`cpos_r - 1 - run_p0`, forms `lim_beat := (ph_ch + (lim_rec+1)*CPR + BEAT_CH - 1)/BEAT_CH`,
`left := lim_beat - f_beat`, and `burst_len(ar_addr, left)` into `alen`
(`rtl/attn_kv_axi.vhd:901-910`), on unconstrained `integer` signals.

Change: register `lim_beat` one cycle ahead from `c_max`, `cpos_r`, `run_p0`, `ph_ch`; the
issue cycle computes only `left` and `burst_len`. Constrain the integer ranges of `c_max`,
`lim_rec`, `lim_beat`, `f_beat` to what they can hold (natural ranges derived from MAXCTX,
CPR, RBUF), so synthesis stops building 32-bit arithmetic.

Why a one-cycle-old limit is safe: `c_max` only grows within a run (it is reset only on run
start, `:754`, `:859`, `:868`, `:884`), and `cpos_r`/`run_p0` are fixed within a run, so a
limit computed from the previous cycle's `c_max` is never larger than the true one. The
change can delay an issue by one cycle, never permit an early one. The resets must clear the
registered `lim_beat` in the same cycle as `c_max`, or the first issue of a new run would use
the last run's limit: that is the case the new bench row must pin.

### 4.3 The c_attn latency change: verify, do not assume

`attn_score_q12` consumes `p_valid` by the flag with its own `p_ready`, but the array has
no back-pressure and runs on a fixed per-position slot (`attn_mac_array.vhd` header,
"BACK-PRESSURE"), and `attn_block` has drain/busy logic around it. Before the RTL change,
the implementation plan must establish from the RTL, and then by the benches, that:

1. no logic in `attn_block` counts cycles from `sc_valid` to the score's arrival;
2. every busy/drain condition that waits for the array to empty includes the new S2b stage;
3. the slot still absorbs the extra cycle at the card's KV beat rate.

If any of the three fails, the fix is re-designed before implementation (e.g. absorbing the
cycle elsewhere), and the change is not landed on the strength of a green bench alone.

### 4.4 v_swg: `swiglu_mem` stage B

Today stage B computes `sigmoid_q(a_vq, Q)` (`rtl/fixed_pkg.vhd:187`) in one cycle:
saturation compares, index, two SIG_ROM reads, a 64-bit subtract and multiply, shift, add and
round.

Change: stage B becomes three stages inside `swiglu_mem`, each one listed operation:
- B1: saturation flags, `k` (clamped), `frac`; operands `vq`/`hq` carried.
- B2: `lo = SIG_ROM(k)`, `hi = SIG_ROM(k+1)` registered (ROM as `rom_style = "block"` or
  distributed per the census, not assumed).
- B3: `(hi - lo) * frac`, shift, add, round, saturation select -> `b_sig`.

`fixed_pkg.sigmoid_q` is unchanged and remains the reference. Stages C (`b_vq * b_sig`) and D
(`c_silu * c_hq`) are each a 32x32 multiply plus shift in one stage; each is split into
multiply / shift-resize if the rating after B still misses 200 MHz on VU35P -2, and not
otherwise. The valid chain (`vf, va, vb, vc, vd`) gains one flag per added stage, and
`drained` includes every one of them.

`rtl/attn_gate.vhd` already stages SIG_ROM interpolation for C and is the pattern to follow,
including its warning that the offset `z + 16*2^Q` needs one more signed bit than it looks
(two MEASURED resize defects in this subsystem, `docs/debugging/2026-08-27_*`). Its output
stage (Q15, clamped to 32767) is deliberately not `sigmoid_q`'s, so it is not reused as is.

## 5. Verification

Per block, in order, each a gate for the next step:

1. **Oracle first.** The value benches must pass before and after, unchanged:
   `tb_attn_mac_array`, the attention benches in `sim/regress.sh`, `tb_attn_kv_axi`,
   `tb_csweep_rate`, `tb_swiglu_mem` (identity bench at LANES 1, 2, 4). A green bench across
   a real change proves only that it did not break what the bench checks (CLAUDE.md): each
   change also gets one case that DISTINGUISHES the old and new timing and is run against the
   old RTL too:
   - c_attn: `p_valid` arrives one cycle later, and back-to-back scores at the slot's
     minimum spacing are all delivered in order.
   - c_kv: a run restart while the previous run's `c_max` was at the buffer limit; the first
     issue of the new run must use the new run's limit (fails if `lim_beat` is not cleared).
   - v_swg: a sigmoid sweep over every SIG_ROM interval, both saturation edges and z = 0,
     comparing the staged sigmoid with `fixed_pkg.sigmoid_q` element by element; plus a
     back-to-back vector with `vf` gaps to exercise `drained`.
2. **Mutation teeth.** For each distinguishing case, a mutant that removes the new register
   (or, for c_kv, the reset of `lim_beat`) must fail it.
3. **Rating.** `rate.py run <row> --device vu35p_jc_m2` and `--device vu33p_fk33`; the new
   records are committed with the change. The row's `target_ns` for `vu35p_jc_m2` is set to
   4.25 ns (0.85 x 5.0) so a 200 MHz result is over-constrained rather than a lower bound.
4. **Status.** `rate.py status --check` FRESH for every changed row on both devices;
   `sim:ratestale` green.

After all three: `rate.py preflight --device vu35p_jc_m2 --model QWEN35_9B --levers
FAST_POP=false,NWIDE=false,SWEEP_PIPE=false,SCORE_EARLY=false` needs a VU35P k, which does
not exist until a VU35P card build (spec 2026-09-25, section 4); until then the result is the
three ratings, not a predicted card clock.

A card build carrying these changes is a separate decision, and when it happens the N=500
ctxtest runs twice on it (CLAUDE.md standing rule), because C is where the build 19/21 hang
lives.

## 6. Risks

- **c_attn latency (4.3)** is the one change whose safety is structural rather than local.
  Mitigation: the three checks above, before the RTL change.
- **v_swg may need C/D split too**, a further cycle each; still internal to the valid chain.
- **ROM inference**: SIG_ROM as block RAM adds its own register; the census, not the
  inference log, decides what was built (CLAUDE.md).
- **Noise floor**: a 200 MHz single draw can be 0.4-0.75 ns lucky; criterion 2 in section 2
  handles it.

## CORRECTION 2026-09-26 (while planning): "two draws" means two targets

Section 2's "or two draws both reach 200 MHz" cannot mean re-running the same job: Vivado is
deterministic for identical inputs (MEASURED bit-identical, 2026-09-05 and the 2026-09-25
cross-lane check), so a re-run reproduces the number and is not a second sample of the noise.
A second draw is the same row rated at a different `target_ns` (4.0 ns), which changes placement.
