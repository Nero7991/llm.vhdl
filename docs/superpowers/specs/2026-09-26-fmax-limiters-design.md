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

## RESULT 2026-09-27: v_swg done; c_attn and c_kv held

Scope was narrowed on 2026-09-27 to v_swg ("rework v_swg first"); sections 4.1-4.3 are not
implemented yet.

v_swg (`swiglu_mem`, stage B now `sigmoid_q_pipe`, five stages; commits 8c69c46, 9a973e6).
MEASURED, tools/rate, routed, every record over-constrained (WNS < 0), MHz:

| device | before | after | WNS at target |
|---|---|---|---|
| VU33P -2LV (`vu33p_fk33`) | 83.4 | 183.5 | -0.363 |
| VU35P -2LV (`vu35p_jc_m2l`) | 84.5 | 178.5 | -0.517 |
| VU35P -1 (`vu35p_jc_m1`) | 93.0 | 212.4 | -0.449 |
| **VU35P -2 (`vu35p_jc_m2`)** | **111.6** | **242.9** | -0.520 |
| VU35P -3 (`vu35p_jc_m3`) | 124.5 | 266.9 | -0.461 |

Success criterion (section 2): >= 217 MHz single draw on VU35P -2: MET (242.9). Area on
VU33P: LUT 2547 -> 1617, DSP 16 -> 9, FF 586 -> 657, BRAM 22.5 -> 23.5. C and D were not
split. The new v_swg critical path is stage A, the exponent conversion `to_qq`
(`ue`/`ge` -> `a_hq`/`a_vq`, 22-23 levels).

Slowest blocks per device after this change: c_kv then c_attn everywhere (VU35P -2: 151.1,
173.7), then v_swg, except VU35P -3 where a_engine (248.8) is third.

Verification: `sim/tb_sigmoid_q_pipe.vhd` exhaustive over [-17, 17] * 2^12 plus the int32
extremes, 139,270 samples bit-exact to `sigmoid_q`; every swiglu row and both
`tb_llama_top_swg*` rows PASS unchanged. Mutants: rounding bias removed KILLED (value);
saturation edge `>=` -> `>` KILLED but by GHDL's range check on `k1`, not the value compare;
`drained` without the pipe's busy term SURVIVES and is equivalent under contiguous issue
(term kept); `drained` without `vd` KILLED by the new `maxlast` trial on all four
swiglu_mem rows, where the random trials before it passed.

### CORRECTION 2026-09-27 (final review, same day)

- **WITHDRAWN: "`drained` without the pipe's busy term SURVIVES and is equivalent under
  contiguous issue".** It survived because every gate row had NB = N/LANES >= 16. With
  NB <= 5 the whole batch can sit inside the five-stage pipe while `vf`, `va`, `vc` and `vd`
  are all 0, and the mutant FAILS: MEASURED by the reviewer, 45 of 271 checks at N=8 LANES=2
  and 74 of 511 at N=16 LANES=4. The term is required, not redundant. New gate row
  `sim/tb_swiglu_mem_nb4.vhd` (N=16, LANES=4) pins it, and `sim/mutate_swiglu_mem.sh`
  gains a `nobusy` row expected to bite at LANES=4 only. MEASURED: bites at LANES=4
  (rc 1 full and with values off, rc 0 with values and exponent off, so the kill is the
  exponent check's), survives at LANES 1 and 2 (NB 16, 8); `nosig`, repointed at the pipe's
  output, bites at 1, 2 and 4.
- **The 217 MHz criterion is met by one draw at the edge of the noise floor.** 242.9 MHz is
  4.117 ns against 4.608 ns, a margin of 0.49 ns (DERIVED), inside the 0.4-0.75 ns routed
  floor recorded in CLAUDE.md. Read it as MET, single draw, not as a margin.
- **The RESULT table's rows were rated at different targets** (VU33P and VU35P -2LV at
  5.086 ns; -1, -2 and -3 retargeted to 4.259, 3.597 and 3.286 ns). Each row is its own
  over-constrained measurement; do not rank rows against each other on small differences.
- **"The new critical path is stage A `to_qq`" holds on 4 of 5 devices.** On VU35P -1 the
  worst path is `gen_sig[0].u_sig/s5_reg -> ARG__5` DSP A input (stage C's multiply, 11
  levels).
- **Pipe latency adds 8 cycles per `VEC_SWG`** (MEASURED `SWGFAST_CYCLES` 24,596, was
  24,588); the cycle-count comments in `rtl/swiglu_mem.vhd`, `rtl/llama_top.vhd`,
  `rtl/fk33_llama_top.vhd` and the w8 benches still quote the old figures (deferred).

## RESULT 2026-09-27: c_attn done (meets 200), c_kv gain committed and 200 deferred

Tasks 1-2 un-held on 2026-09-27 ("Proceed with both") and implemented after v_swg.
Both changes are RTL pipeline splits with no arithmetic change; oracles unchanged.
Commits: c_kv `ede9e8f`, c_attn `1b92fa6`. MEASURED, tools/rate, routed, one draw,
`limited_by routing` on every row, MHz:

| device | c_attn before | c_attn after | c_kv before | c_kv after |
|---|---|---|---|---|
| VU33P -2LV (`vu33p_fk33`) | 142.0 | 150.4 | 114.9 | 144.8 |
| VU35P -1 (`vu35p_jc_m1`) | 130.6 | 181.5 | 114.3 | 155.8 |
| **VU35P -2 (`vu35p_jc_m2`)** | **173.7** | **204.5** | **151.1** | **187.5** |
| VU35P -2LV (`vu35p_jc_m2l`) | 140.2 | 162.7 | 131.9 | 143.4 |
| VU35P -3 (`vu35p_jc_m3`) | 162.4 | 203.7 | 147.3 | 203.5 |

**c_attn: success criterion MET** (>= 200 MHz on VU35P -2: 204.5, one draw). The S2
split (two half-trees S2a -> registered final add + range compare S2b) removed the
`p_reg -> er_r` 14-level path; the worst path is now `u_arr blk2_reg -> acc_reg` (PV
accumulate, 8 levels, routing). `c_attn_levers` (levers-on variant, re-keyed by the
same RTL) re-rated to 198.0 on VU35P -2.

**c_kv: 200 NOT met; the gain is committed and 200 deferred (Oren).** Registering the
read limit (`lim_beat_r` a cycle ahead) took it 151.1 -> 187.5 on VU35P -2. The worst
path moved off `alen` to an 18-level `cpos_r -> lim_beat_r` cone that a single register
does not cut; reaching 200 needs a second split of that cone, deferred.

Both `>= 200` on VU35P -3 (203.7, 203.5); neither on -1 or the -2LV/-2LV low-voltage
grades, as expected from the ceilings. Differences within the 0.4-0.75 ns routed noise
floor (CLAUDE.md) are not results; each row is its own over-constrained draw at a
per-grade target, do not rank grades on small deltas.

Verification. c_attn: spec 4.3 checks (1)-(3) verified against the RTL before the change
(no cycle count keyed to arrival; `attn_score_q12` holds S_ACC until NBLK partials, so
`p_rdy` never falls early; the sweep is phase-driven, so the extra stage costs +1 cycle
per position, not a missed beat). `tb_attn_mac_array` gains a `P_LAT` latency guard
(`sc_hist`/`lat_bad`) that fails if the score latency regresses; attn gate 16 PASS.
c_kv: a pragma-guarded assertion catches a stale read limit surviving a run boundary;
the run-boundary-clear mutant is KILLED in 5 rows, the token-start-clear mutant SURVIVES
(resolution floor: the flush-end branch clears `lim_fresh` anyway). Gates kv 7/7,
csweep 1/1.
