# The top-level RMSNorm gain was fabricated, so nine seams of every token could not be compared. They can now.

**Date:** 2026-08-29. Branch `fpga`. Track NORMW.
**Design under test:** `rtl/llama_top.vhd` at HEAD `80d3a61` plus this track's
change; `sim/tb_llama_top.vhd`'s scaled shape (hidden 64, ffn 128), 4 blocks,
`attn_interval` 4, every computing unit real.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/` was run, nothing opened `/dev/xdma*`.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

From the track brief, which assembled it from two tracks that found the same
thing without knowing of each other:

> **TRACK REF9B (its finding D2):** the top-level RMS norm uses a **synthetic
> ramp**, not any model weight, **so `R_XN` cannot be compared at all**.
>
> **TRACK SPECREC, independently:** `rtl/llama_top.vhd:1615-1626` computes the
> norm weight as `2**NORM_W_EXP + ((i*37) mod 512) - 256` and **`attn_norm`
> appears zero times in the entire file.**
>
> **Part 1 (priority): make the top-level RMS norm use the real model weights,
> so `R_XN` can be compared against the reference.**
>
> **Part 2 (small): a consistency check that does not exist.** TOKIO reports
> `A_ROWS_IF` and `A_MAXROWS_BFP` are now **literals in two files with nothing
> checking they agree.**

---

## 2. The answer, up front

**Part 1. `R_XN` is now compared, and it is CLEAN: 9 of 9 seams bit-exact
against a model built from the real Qwen3.5-9B gains.** MEASURED,
`tools/norm_w_bisect.py` on a capture of the new gate row:

```
# THE REAL GAIN
  R_XN-0         n=64   exp 14 vs 14  MATCH
  R_XN.ffn-0     n=64   exp 14 vs 14  MATCH
  R_XN-1         n=64   exp 14 vs 14  MATCH
  R_XN.ffn-1     n=64   exp 14 vs 14  MATCH
  R_XN-2         n=64   exp 14 vs 14  MATCH
  R_XN.ffn-2     n=64   exp 14 vs 14  MATCH
  R_XN-3         n=64   exp 13 vs 13  MATCH
  R_XN.ffn-3     n=64   exp 14 vs 14  MATCH
  R_XN.final     n=64   exp 13 vs 13  MATCH
# 9 of 9 R_XN seams match the model bit for bit
```

**And the check is shown to discriminate the gain**, which is the half that
makes the first half worth anything. The SAME capture, compared against the old
synthetic ramp:

```
# 0 of 9 R_XN seams match the ramp
```

**The default path did not move.** `tb_llama_top_real` still reports
`R_X(0) = -16339 hash(R_X) = 92903`, re-MEASURED after the change. The new row
`tb_llama_top_normw` has its own landmark, `R_X(0) = -16293 hash(R_X) = 76090`.

**Part 2.** `sim/tb_a_geom.vhd` is a new gate row that checks the pair, and
`tools/check_a_geometry.py` covers the three sites no VHDL elaboration can
reach. All five sites agree today at ROWS_IF 48 / MAXROWS_BFP 17408. Five
mutations of the VHDL pair are killed, five mutations of the source pair are
killed, and the two predicted survivors of each are named in section 6.

**What this is NOT.** It is stimulus, not a design change. There is still no
weight region, no descriptor field and no packing by which a norm gain reaches
`rmsnorm_rs` on the card. Section 8 states that gap and what closing it costs.

---

## 3. The procedure, in the order it was run

Each step says what it isolates.

**P1. Establish the baseline before touching anything.** `regress.sh --only
tb_llama_top_real`. Isolates: "did the landmark already move under
`80d3a61`?" -- TOKIO had just landed and the brief warned the second landmark
may have shifted. MEASURED `R_X(0) = -16339 hash 92903`, unchanged, so the
control is valid.

**P2. Measure the real gains before writing any RTL.** Read
`blk.{0..3}.attn_norm.weight`, `blk.{0..3}.post_attention_norm.weight` and
`output_norm.weight` from the GGUF and print min/max/rms. Isolates: "does a
real gain fit int16 at `NORM_W_EXP = 12`?" A gain above 8.0 would not, and
discovering that after the RTL was written would have looked like an RTL
defect.

**P3. Extend the generator, and prove the A image is unchanged.**
`tools/gen_llama_top_weights.py --norm-out`. Isolates the additive claim: the
committed weight image must still hash `8cd88f10114e3a74a586c8a382d0889c`.

**P4. Wire the gain into `rtl/llama_top.vhd` behind `NORM_W_IMAGE`, default
empty.** Re-run P1's row. Isolates: "does the default path move?"

**P5. Add the row, capture it, and compare.** `sim/tb_llama_top_normw.vhd`,
then `tools/capture_normw.sh`, then `tools/norm_w_bisect.py`. This is the
deliverable.

**P6. Run the SAME comparison with the ramp** (`--also-ramp`). Isolates the
resolution of the check itself: a comparison that passes with either gain is
not checking the gain.

**P7. Re-derive the gains from the GGUF inside the checker** (`--gguf`).
Isolates the IMAGE: without it the image is its own oracle, which is the `m7
mutant` failure this project already has on record.

**P8. Run the whole stepwise oracle on the new capture**
(`tools/ref9b/bisect_scaled.py`). Isolates: "did anything OTHER than the norms
change?" -- and, unexpectedly, produced finding 7.2.

**P9. Mutate the RTL** (`sim/mutate_normw.sh`, 7 rows) and **the generator**
(`tools/mutate_norm_gain_image.sh`, 5 rows), judging both by the oracle rather
than by the bench.

**P10. Part 2.** Write `sim/tb_a_geom.vhd`, mutate it 8 ways
(`sim/mutate_a_geom.sh`); write `tools/check_a_geometry.py`, mutate all five
sites plus a rename.

**P11. Full unfiltered gate.**

---

## 4. The evidence, as captured output

### 4.1 The real gains fit, and the reduction is stated (P2, P3)

MEASURED, the GGUF, before reduction:

```
blk.0.attn_norm.weight               n= 4096 min=+0.93604 max=+1.30273 rms=1.03372
blk.0.post_attention_norm.weight     n= 4096 min=+0.00391 max=+1.07812 rms=0.88891
blk.1.attn_norm.weight               n= 4096 min=+0.44141 max=+1.51562 rms=1.05419
blk.1.post_attention_norm.weight     n= 4096 min=+0.00391 max=+1.15137 rms=0.90900
blk.2.attn_norm.weight               n= 4096 min=+0.40234 max=+1.42773 rms=1.08835
blk.2.post_attention_norm.weight     n= 4096 min=+0.00391 max=+1.16406 rms=0.87753
blk.3.attn_norm.weight               n= 4096 min=+0.75781 max=+1.81250 rms=1.19632
blk.3.post_attention_norm.weight     n= 4096 min=+0.00391 max=+1.11670 rms=0.92955
output_norm.weight                   n= 4096 min=+0.77734 max=+2.99219 rms=2.14449
```

DERIVED: the largest gain in the set is 2.992, and `round(2.992 * 2**12)` is
12,255, inside int16. `NORM_W_EXP` therefore does not have to move, and the
`o_exp = x_exp + w_exp + Q - st` bookkeeping in `rmsnorm_rs` is comparable
against every number published before this change.

**THE REDUCTION IS THE ONE MODELLING CHOICE.** The bench's hidden is 64 and the
model's is 4096. The A image reduces a weight MATRIX by `--reduce pool`, which
sums groups of 64 columns because that is what preserves the l2 row norm. The
GAIN's partner is the MEAN of the same group, not the sum, and the arithmetic
is in `reduce_gain()`:

    real:   out_m = sum_j W[m,j] * xhat_j * g_j        over K = 4096
    scaled: out_m = sum_c Wp[m,c] * xhat_c * gp_c      with Wp = sum over group
    match:  sum_{j in grp} W[m,j] * g_j == (sum_{j in grp} W[m,j]) * gp_c
    so      gp_c = MEAN of g over the group

A copied `sum` here would multiply every scaled activation by 64 -- six octaves
-- and is exactly the class of stimulus error that produced three false alarms
on 2026-08-28. It is mutation row `sum` in section 6.2.

MEASURED, the committed image (`--norm-stats`):

```
norm_op,tensor,min,max,rms,max_abs_mant
0,blk.0.attn_norm.weight,1.02176,1.04321,1.03307,4273
1,blk.0.post_attention_norm.weight,0.85922,0.90050,0.88747,3688
2,blk.1.attn_norm.weight,1.03893,1.06790,1.05251,4374
3,blk.1.post_attention_norm.weight,0.89337,0.91599,0.90850,3752
4,blk.2.attn_norm.weight,1.06337,1.10143,1.08692,4511
5,blk.2.post_attention_norm.weight,0.85292,0.89367,0.87414,3660
6,blk.3.attn_norm.weight,1.17944,1.20804,1.19489,4948
7,blk.3.post_attention_norm.weight,0.90396,0.94698,0.92668,3879
8,output_norm.weight,2.09073,2.17792,2.13991,8921
```

**A KNOWN CONSEQUENCE, recorded here rather than discovered later.** Averaging
64 real gains collapses the element-to-element spread to about 2% of the mean
(DERIVED from the min/max columns above), so the committed image is close to a
per-LAYER SCALAR gain. A bit-exact oracle still resolves a permuted or reversed
gain at that spread -- mutation M2 in 6.1 proves it, 0 of 9 -- but a
tolerance-based check would not. `--norm-reduce slice` keeps the full spread
and is not the committed default because it is not the partner of `pool`.

### 4.2 The A image did not move (P3)

MEASURED:

```
$ md5sum <regenerated> sim/llama_top_w_b4_pool.hex
8cd88f10114e3a74a586c8a382d0889c  <regenerated>
8cd88f10114e3a74a586c8a382d0889c  sim/llama_top_w_b4_pool.hex
```

### 4.3 The default path did not move (P4)

MEASURED, `REGRESS_SCRATCH=... bash sim/regress.sh --only tb_llama_top_real`:

```
llama_top: the D-vec norm gain is the SYNTHETIC RAMP (NORM_W_IMAGE empty).
  R_XN is not comparable against a model-derived reference.
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run,
  2 descriptor-latency points, R_X bit-identical across all of them,
  R_X(0) = -16339 hash(R_X) = 92903
```

### 4.4 The new row, and its own landmark (P5)

MEASURED:

```
llama_top: the D-vec norm gain is REAL, 9 norm ops from llama_top_nw_b4_mean.hex
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run,
  2 descriptor-latency points, R_X bit-identical across all of them,
  R_X(0) = -16293 hash(R_X) = 76090
```

DERIVED: `R_X(0)` moved by 46 counts out of 16,339, i.e. 0.28%, which is what a
gain whose rms is within a few percent of the ramp's 1.0043 should do. A large
move would have been the tell that something other than the gain had changed.

### 4.5 The comparison, and the teeth check (P5, P6, P7)

MEASURED, full output in section 2 for the passing arm. The ramp arm, same
capture, same oracle, same code path:

```
# THE OLD SYNTHETIC RAMP, on the SAME capture.  This is the teeth check:
  R_XN-0      exp 14 vs 14  64 of 64 differ  first at 0: expected -26133, captured -29073
  R_XN.ffn-0  exp 14 vs 14  64 of 64 differ  first at 0: expected -26155, captured -24656
  R_XN-1      exp 14 vs 14  64 of 64 differ  first at 0: expected -26653, captured -30359
  R_XN.ffn-1  exp 14 vs 14  64 of 64 differ  first at 0: expected -26648, captured -25767
  R_XN-2      exp 14 vs 14  64 of 64 differ  first at 0: expected -25973, captured -30424
  R_XN.ffn-2  exp 14 vs 14  64 of 64 differ  first at 0: expected -25968, captured -23845
  R_XN-3      exp 14 vs 13  64 of 64 differ  first at 0: expected -26007, captured -16729
  R_XN.ffn-3  exp 14 vs 14  64 of 64 differ  first at 0: expected -25918, captured -25291
  R_XN.final  exp 14 vs 13  64 of 64 differ  first at 0: expected -25955, captured -29291
# 0 of 9 R_XN seams match the ramp
```

Note the ramp's `o_exp` is 14 at every seam while the real gain's is 13 at two
of them. That is `rmsnorm_rs`'s data-driven `st`, and it is a second,
independent signal that the gain reached the arithmetic rather than merely the
file.

And the IMAGE under test rather than trusted, P7:

```
# IMAGE vs MODEL: 0 of 9 gain vectors differ
```

### 4.6 The rest of the token is unchanged (P8)

MEASURED, `tools/ref9b/bisect_scaled.py` on the new capture:

```
# stepwise oracle, token 0, shape blocks=4 attn_interval=4 attn_hd=16 hidden=64 ffn=128
# 59 seams checked against a model, 4 NOT checked
    NOT CHECKED  R_Y-0    subsystem B has no integration-level model
    NOT CHECKED  R_Y-1    subsystem B has no integration-level model
    NOT CHECKED  R_Y-2    subsystem B has no integration-level model
    NOT CHECKED  LOGITS   destination is R_NONE: the lm_head job discards its result
  R_XN-0      ... 64 of 64 mantissas differ ...
  ... eight R_XN rows ...
```

**Every seam that is not a norm matches.** The nine norm seams diverge because
`bisect_scaled.py --norm real` recomputes with `VO.norm_w_const`, the ramp --
which was the only honest thing it could do while the RTL used the ramp. See
finding 7.1: this is a coordination item for whoever owns `tools/ref9b/**`, not
a defect.

### 4.7 Part 2, the geometry check (P10)

MEASURED, `sim/tb_a_geom.vhd`:

```
tb_a_geom: n_rows = 17408 -> err_code 15 err_info 36
tb_a_geom: n_rows = 17409 -> err_code 3 err_info 1
tb_a_geom RESULT: PASS -- 6 checks, A_ROWS_IF = 48 and A_MAXROWS_BFP = 17408
  agree with the descriptor plane's own generic defaults
```

DERIVED: `err_code 3` is `EC_DESC` and `err_info 1` is descriptor word 1, which
is `matvec_int4_desc_axi.vhd:721-726`'s shape bound -- so 17,409 is above the
plane's `MAXROWS_BFP` and 17,408 is not, which brackets it exactly. The 17,408
descriptor is refused LATER, at word 36 = `EXT0+1` with `EC_SHAPE`, which is
the w_beats/s_beats gate; that is expected and is why the assertion is on the
FAILING WORD INDEX and not on acceptance (see the bench header).

MEASURED, `tools/check_a_geometry.py`:

```
# site                                            ROWS_IF  MAXROWS_BFP
  seq_tbl_pkg (the schedule)                           48        17408
  matvec_int4_desc_axi (entity defaults)               48        17408
  gen_fk33_engine.py (the build script)                48        17408
  fk33_engine.vhd (the GENERATED instantiation)        48        17408
  tb_mv4i_desc_image (bench generics)                  48        17408
# every site agrees: ROWS_IF = 48, MAXROWS_BFP = 17408
```

There are **five** sites, not two. The brief said two; the count is recorded
here because the two the brief named are the two a VHDL check can reach, and
the one that decides what the card carries -- `gen_fk33_engine.py` -- is not
among them.

### 4.8 The full unfiltered gate (P11)

Both new rows, MEASURED inside the full unfiltered run (not `--only`):

```
sim:tb_llama_top_normw   PASS   84 s
sim:tb_a_geom            PASS    2 s
```

The whole-run verdict is taken from the LAST `OVERALL` line of the log and not
the first -- an agent reported a green gate from the first of two report blocks
in one log earlier on 2026-08-29:

 OVERALL     PASS 88   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 88 passing, matches the recorded floor of 88
 REGRESSION: PASS

MEASURED, and there is exactly ONE `OVERALL` line in the log (`grep -c OVERALL`
is 1), so "the last one" and "the only one" agree here. 88 is 86 + this track's
two rows, and it MATCHES the raised floor rather than exceeding it, which is
what says the two rows both ran and nothing else was added or lost.

The box was under real contention throughout: `uptime` reported a load average
of 9 to 11 with at least two other tracks' `ghdl` runs alive, including a
32-block `tb_llama_top`. That inflates every duration above and is the reason
`tb_llama_top_normw` measures 84 s here against 77 s standalone.

---

## 5. What changed, file by file

| file | change | default behaviour |
|---|---|---|
| `rtl/llama_top.vhd` | `NORM_W_IMAGE : string := ""`; the gain table, its loader, and a norm-op selector inside the `gvr` generate | unchanged, bit-identical, MEASURED in 4.3 |
| `sim/tb_llama_top.vhd` | ONE generic (plus its comment block) and ONE line of generic map, both pass-through: 13 lines | unchanged |
| `tools/gen_llama_top_weights.py` | `--norm-out`, `--norm-reduce`, `--norm-w-exp`, `--norm-stats`; the three `OP_NORM` emits gain their real tensor name | `--out` byte-identical, MEASURED in 4.2 |
| `sim/tb_llama_top_normw.vhd` | new gate row | new |
| `sim/llama_top_nw_b4_mean.hex` | new committed artefact, md5 `27bd00db0c2a466c040d4d734ab442bc` | new |
| `sim/tb_a_geom.vhd` | new gate row, Part 2 | new |
| `tools/norm_w_bisect.py`, `tools/capture_normw.sh`, `tools/check_a_geometry.py` | new tools | new |
| `sim/mutate_normw.sh`, `sim/mutate_a_geom.sh`, `tools/mutate_norm_gain_image.sh` | the teeth | new |
| `sim/regress.sh` | two rows documented, `BASELINE_PASS` 86 -> 88, `SLOW_TBS` + `tb_llama_top_normw` | -- |

**`sim/tb_llama_top.vhd` IS NOT THIS TRACK'S FILE** and TRACK RY-ORACLE was
measuring against it. The edit is one generic defaulting to `""` and one line
in the generic map, and it is unavoidable: `llama_top`'s norm gain has no port
and no region, so a generic is the only way in. Saying so loudly is the brief's
own instruction and this row is that.

**THE SELECTOR ADVANCES AT THE COMPLETION, NOT AT THE ACCEPT,** and that was
the one real trap in the RTL. The first version advanced on `v_taken`, which
fires in `S_IDLE` hundreds of cycles before `rmsnorm_rs`'s pass 2 reads
`w_mant`, so norm op k would have been computed with gain k+1 -- every seam
wrong, none of them structurally so. It was caught by reading the state
machine, not by a test, and it is mutation M1 in 6.1 so the next reader does
not have to.

---

## 6. Mutation tables

### 6.1 The RTL gain path, `sim/mutate_normw.sh`

The judge is `tools/norm_w_bisect.py`, not the bench. Both verdicts are printed
because their disagreement is the finding.

```
M0   unmutated                                                bench PASS      R_XN oracle 9/9
M1   gain advances at the ACCEPT, not the completion          bench PASS      R_XN oracle 1/9
M2   the gain image is loaded element-REVERSED                bench PASS      R_XN oracle 0/9
M3   every norm uses gain 0 (the index is ignored)            bench PASS      R_XN oracle 1/9
M4   ONE LSB flipped in every loaded gain element             bench PASS      R_XN oracle 0/9
M5   PREDICTED SURVIVOR: the per-token reset removed          bench PASS      R_XN oracle 9/9
M6   PREDICTED SURVIVOR: W_CONST zeroed (image overwrites it) bench PASS      R_XN oracle 9/9
```

**EVERY ROW LEAVES THE BENCH PASSING.** `R_X(0)`/hash moved on M1 to M4
(`-17267/64224`, `-16330/46843`, `-16346/80500`, `-16309/65732` against the
clean `-16293/76090`) and are identical on M5 and M6 -- but a moved hash is not
a verdict, it is a landmark somebody has to already know. That is the whole
argument for the seam oracle, measured rather than asserted.

**Survivors, named.**

- **M5, the per-token reset removed.** Does not bite because this row is
  `NRUNS=1, NTOK=1`: there is exactly one token, so `go` fires once and
  removing the reset changes nothing. It WOULD bite at `NTOK > 1`, and the
  configuration that has `NTOK = 3` (`tb_llama_top_seq`) cannot carry a gain
  image at all -- see the NOT VERIFIED list. This survivor is the measure of a
  real coverage hole, not of a harmless mutation.
- **M6, `W_CONST` zeroed.** Does not bite because with a non-empty
  `NORM_W_IMAGE` every table entry is overwritten from the file, so `W_CONST`
  is dead in this configuration. It is the DEFAULT configuration's gain, and
  `tb_llama_top_real` is the row that covers it.

**M1 and M3 score 1 of 9, not 0 of 9, and the 1 is not luck**: both leave the
FIRST norm of the token using gain 0, which is the correct gain for it. The
oracle's first divergence is `R_XN.ffn-0`, the second norm. A checker that only
looked at `R_XN-0` would have passed both.

### 6.2 The gain GENERATOR, `tools/mutate_norm_gain_image.sh`

Judged by the `--gguf` arm, which re-derives the gains from the model with a
second implementation of the reduction. MEASURED:

```
base      IMAGE vs MODEL: 0 of 9 differ  |  9 of 9 R_XN seams match
sum       GENERATOR REFUSED: AssertionError: norm gain does not fit int16 at
          w_exp=12: max |q| = 273472.0.  Lower --norm-w-exp.
wrongmap  IMAGE vs MODEL: 4 of 9 differ  |  5 of 9 R_XN seams match
          [(1,'blk.0.post_attention_norm.weight'), (3,'blk.1...'),
           (5,'blk.2...'), (7,'blk.3...')]
revfile   IMAGE vs MODEL: 9 of 9 differ  |  0 of 9 R_XN seams match
wexp13    IMAGE vs MODEL: 0 of 9 differ  |  0 of 9 R_XN seams match
```

**`sum` is killed by the GENERATOR, not by the checker,** and that is worth
more than a checker kill: `quantize_gain`'s int16 bound is exceeded by 8.3x, so
the image is never written at all. A stimulus error of the class that caused
three false alarms on 2026-08-28 cannot leave this tool.

**`wexp13` is the row that reads oddly and it is correct.** Changing
`--norm-w-exp` to 13 produces an image that AGREES with the model at 13, so the
image-vs-model arm is silent -- and the seam arm reports 0 of 9, because the
RTL's `NORM_W_EXP` generic is still 12 and `rmsnorm_rs` folds it into
`o_exp = x_exp + w_exp + Q - st`. **The image's exponent and the DUT's generic
are a pair, and nothing in the file format records which exponent an image was
built at.** That is a real latent trap and it is on the NOT VERIFIED list.

**The `revfile` row above does NOT yet make the case for the `--gguf` arm**,
because that capture came from the CLEAN RTL reading the CORRECT image, so both
arms see a disagreement. The case needs the machine and the image to be
CONSISTENTLY wrong. MEASURED, a separate capture of the clean RTL reading the
REVERSED image:

```
--- the seam arm, capture and image both reversed ---
  R_XN-0      n=64  exp 14 vs 14  MATCH
  R_XN.ffn-0  n=64  exp 14 vs 14  MATCH
  ... all nine ...
# 9 of 9 R_XN seams match the model bit for bit
--- the --gguf arm, same pair ---
# IMAGE vs MODEL: 9 of 9 gain vectors differ
```

**The seam oracle is completely blind to it and the `--gguf` arm kills it.**
That is the `m7 mutant` shape -- a packer plus a decoder that agree with each
other -- reproduced deliberately, and it is the reason the `--gguf` arm exists.
Its bench verdict, for completeness: PASS, `R_X(0) = -16330 hash 46843`.

### 6.3 `sim/tb_a_geom.vhd`, `sim/mutate_a_geom.sh`

```
M0  unmutated                                              PASS  (must be PASS)
M1  seq_tbl_pkg A_ROWS_IF 48 -> 32                         FAIL
M2  seq_tbl_pkg A_MAXROWS_BFP 17408 -> 8192                FAIL
M3  seq_tbl_pkg A_MAXROWS_BFP 17408 -> 32768               FAIL
M4  desc_axi default MAXROWS_BFP 17408 -> 16384            FAIL
M5  desc_axi default ROWS_IF 48 -> 24                      FAIL
M6  desc_axi default MAXCOLS 17408 -> 8192                 PASS  (PREDICTED SURVIVOR)
M7  desc_axi default MAXOUT 16 -> 4                        PASS  (PREDICTED SURVIVOR)
```

**M1 and M5 are killed by the LANGUAGE, not by the checker, and scored under
their own heading.** Both are ROWS_IF mutations and both die as

```
ghdl-mcode:error: bound check failure at .../sim/tb_a_geom.vhd:209
  from: work.tb_a_geom(sim).dut.CMP_ELAB
```

i.e. a port-width mismatch on `y_data`, at ELABORATION. Note it is elaboration
and not analysis: GHDL analyses the bench and the entity separately, so the
width disagreement is only visible when they are bound. The distinction matters
if anyone tries to make this a compile-time-only gate.

**M2, M3, M4 are killed by the checker with a message that names the direction:**

```
M4: CHECK FAILED -- n_rows = A_MAXROWS_BFP (17408) was refused at descriptor
    word 1, so the descriptor plane's MAXROWS_BFP is BELOW what seq_tbl_pkg
    believes.  Every lm_head window the schedule emits is too large for this
    build.
M2: CHECK FAILED -- n_rows = A_MAXROWS_BFP+1 (8193) was NOT refused at
    descriptor word 1 (err_code 15 err_info 36), so the descriptor plane's
    MAXROWS_BFP is ABOVE what seq_tbl_pkg believes and the schedule is
    windowing more than it needs to.
```

**Survivors, named.** M6 (`MAXCOLS`) and M7 (`MAXOUT`) survive by construction:
`seq_tbl_pkg` states neither, so there is no agreement to break; the bench's own
`n_cols` is 4096, well inside the mutated 8192, and no weight traffic ever runs
here so `MAXOUT` is unreachable. They are the resolution floor of this bench:
it polices exactly two numbers and nothing else about the geometry.

### 6.4 `tools/check_a_geometry.py`

Every site mutated in a private copy of the tree:

```
S1 seq_tbl A_ROWS_IF 48 -> 32                 rc=1  DISAGREEMENT on ROWS_IF: [32, 48]
S2 desc_axi MAXROWS_BFP 17408 -> 8192         rc=1  DISAGREEMENT on MAXROWS_BFP: [8192, 17408]
S3 gen_fk33_engine.py MAXROWS_BFP -> 9000     rc=1  DISAGREEMENT on MAXROWS_BFP: [9000, 17408]
S4 fk33_engine.vhd MAXROWS_BFP => 4096        rc=1  DISAGREEMENT on MAXROWS_BFP: [4096, 17408]
S5 tb_mv4i_desc_image RI 48 -> 12             rc=1  DISAGREEMENT on ROWS_IF: [12, 48]
S6 the declaration REFORMATTED                rc=0  DOES NOT BITE -- correct, the patterns are whitespace-tolerant
S7 the constant RENAMED to a symbol           rc=1  MISSING: 0 matches for ROWS_IF ... this check has gone blind
```

S6 and S7 are the two rows that matter on re-reading. A source scrape's
characteristic failure is going silently blind, and S7 measures that the guard
against it works: a pattern that stops matching is an ERROR, never a skip.

---

## 7. Findings that are not this track's defects

### 7.1 `bisect_scaled.py --norm real` now reports every norm seam as divergent

It recomputes with `VO.norm_w_const`, the ramp (`tools/ref9b/bisect_scaled.py`
line 315). On a run with `NORM_W_IMAGE` set, that is nine false divergences,
and the run's FIRST DIVERGENCE line then points at `R_XN-0` -- the most
misleading possible output, because it is a real seam that is really fine.

`tools/ref9b/**` belongs to TRACK RY-ORACLE today, so this track did not touch
it. **The fix is a fourth `--norm` choice** that takes a gain image path, at
which point `tools/norm_w_bisect.py` should be deleted and folded in. Its
`--gguf` arm is worth keeping when it moves.

Until then the rule is: **a capture taken with `NORM_W_IMAGE` set must be given
to `norm_w_bisect.py` for its norm seams and to `bisect_scaled.py` for the
other 50.**

### 7.2 `bisect_scaled.py` prints at most 8 divergences

`diverged[:8]`. Nine norm seams diverge on the run in 4.6 and eight are listed;
`R_XN.final` is missing from the list, not from the comparison. Recorded
because it cost ten minutes chasing a seam that was allegedly clean. Not a
defect -- but "8 lines" is not "8 seams".

### 7.3 The gain has no path from HBM, and that has not changed

`nonmatvec_f32.bin` in the packed model set already carries every one of these
tensors at its real width, with an `hbm_offset` per entry, so the DATA is
staged for the card. What does not exist is anything in the descriptor, the
region map or `seq_vec_issue`'s protocol that would let `rmsnorm_rs` read one.
`NORM_W_IMAGE` does not create that and is not a step toward it: it is an
elaboration-time constant, which is correct for a learned weight in simulation
and impossible on a card whose gains are 4096 elements per layer across 32
layers. Closing it is a design decision (a region, or a small dedicated
descriptor op, or a host write into a reserved region before `go`) and belongs
with Oren.

---

## 8. Measured and REJECTED -- do not retry

**R1. Advancing the gain index at the ACCEPT (`v_taken`).** REJECTED, and it is
the intuitive design. `tk` fires in `S_IDLE`; `rmsnorm_rs` first reads `w_mant`
in its pass 2, after the n+2 region reads, `S_GO`, the sum-of-squares pass and
the whole rsqrt. Every norm would use the NEXT norm's gain. Measured as M1: the
bench PASSes and the oracle reports 1 of 9. Do not "simplify" the selector back
into `nproc`'s `S_IDLE` branch.

**R2. Wrapping the gain index past the end of the table.** REJECTED. It would
serve the tail of a token the gains of its head, silently. The table refuses
instead: `novf` latches and the next ACCEPT is a failure. Note the LAST norm's
completion legitimately tries to advance, so the refusal cannot be at the
increment -- that was the first version and it fired on every clean run.

**R3. `sum` instead of `mean` in `reduce_gain`.** REJECTED by arithmetic before
it was measured, and measured anyway (6.2). It is the same shape as the three
false alarms of 2026-08-28: a stimulus error that moves the residual stream six
octaves and reads as a design defect.

**R4. Committing the `slice` image as the default.** REJECTED. `slice` keeps
the full element-to-element spread, which would make the mutation table look
better, and it is not the partner of the A image's `pool`. Choosing a reduction
because it makes a check look sharper is choosing the answer. It remains
available as `--norm-reduce slice`.

**R5. Making Part 2 a pure elaboration-time constant comparison.** REJECTED,
and the brief suggested it. VHDL cannot read another entity's generic DEFAULTS,
so a bench that "checks" `A_ROWS_IF` against a constant it wrote itself is a
check that cannot fail -- the exact defect TOKIO found in its own work. The
DUT is therefore instantiated with NO generic map, which turns the ROWS_IF half
into a port-width bound check and the MAXROWS_BFP half into a two-point
behavioural bracket.

**R6. Making the 17,408-row descriptor pass S_CHECK outright.** REJECTED. It
would need a valid 17,408-row weight image inside the bench, which tests the
packer and not the bound. The observable that isolates the bound is the FAILING
WORD INDEX, and asserting on that is what makes the bench a second long instead
of a minute.

**R7. Adding `tools/check_a_geometry.py` to the gate.** NOT DONE, not rejected
on merit. `sim/regress.sh`'s only non-VHDL hook builds and runs `ref/<stem>.c`,
and `ref/**` belongs to another track today. Left as an open item rather than
done by editing a file this track does not own.

---

## 9. Measurement traps hit, including my own

**T1. `emit(OP_NORM` is a prefix of `emit(OP_NORM,`.** A guard assertion in the
edit script was `s.count('emit(OP_NORM')==0` after the substitution, which can
never hold. The script aborted before writing, so nothing was lost -- but a
guard written the other way round would have silently passed while doing
nothing. Assertions on substring counts need the terminator.

**T2. A mutation harness with an incomplete file list reports ANALYSIS for
EVERY row, including the unmutated one.** The first two runs of
`sim/mutate_a_geom.sh` printed a full table of `ANALYSIS` and would have read as
"every mutation is killed" to anyone who skipped the M0 row. **M0 is not
decoration; it is the row that says the harness works.** The fix was to take
the file list from `regress.sh`'s own resolved `plan.tsv` rather than typing it.

**T3. `bisect_scaled.py`'s divergence list is capped at 8** (7.2). Ten minutes
were spent looking for why `R_XN.final` was allegedly clean under the ramp when
`norm_w_bisect.py` said it was not.

**T4. `echo "rc=$?"` after a pipeline reports the LAST command's status.** The
first `norm_w_bisect.py` run appeared to exit 0 when what was measured was
`tail`'s exit status. Re-run without the pipe before believing an exit code.

**T5. The `--gguf` arm exists because the image would otherwise be its own
oracle.** Without it, a generator that wrote the wrong tensor, the wrong
reduction, or a reversed vector would be faithfully reproduced by the RTL,
faithfully read back by the checker, and reported as 9 of 9. This is the `m7
mutant` shape and it was one option away from being repeated here.

**T6. The gate row and the capture are two different runs of the same design,
and only one of them is in the gate.** `tools/capture_normw.sh` restates
`tb_llama_top_normw`'s generics. If that wrapper's generics ever change and the
script's do not, the gate and the comparison drift apart silently. There is no
guard against this today; it is on the NOT VERIFIED list.

---

## 10. Explicitly NOT verified

- **The 32-block landmark was NOT re-measured.** The brief names
  `R_X(0) = -14110 hash 52347, 491 descriptors` for "32 blocks, real weights,
  C_REAL". MEASURED: `grep -c "BLOCKS=32" <the gate plan>` is 0 -- there is no
  32-block row in the gate, so that landmark exists only as a manual run.
  DERIVED that this track cannot have moved it: `NORM_W_IMAGE` defaults to `""`
  and the default path is bit-identical, which section 4.3 measures at 4
  blocks. That is a derivation, not a measurement, at 32.
- **Only ONE token, at ONE shape.** `blocks=4`, `attn_interval=4`,
  `attn_hd=16`, `hidden=64`, `NTOK=1`, `NRUNS` 2 in the gate and 1 in the
  capture. Nothing here says anything about the 32-block token, and mutation M5
  is the recorded consequence: the per-token reset is untested because there is
  only one token.
- **`tb_llama_top_seq`, the multi-token KV row, CANNOT carry a gain image.**
  It runs `ATTN_HD = 64`, and the image is indexed by norm op of a schedule
  built at a different shape. The generator refuses `--attn-interval 2`
  outright (`blk.1.attn_q.weight` does not exist in the model), which is the
  same limitation `tb_llama_top_real` already carries.
- **The gains are REDUCED, 4096 elements to 64.** Nothing here is a claim about
  the real 9B norm. The reduction is `mean`, its arithmetic is stated, and its
  measured consequence is a 2% element spread.
- **`R_XN` is compared against a MODEL OF `rmsnorm_rs`, not against
  llama.cpp.** `tools/ref9b/vec_oracle.norm_rs` is a transcription of
  `rtl/rmsnorm_rs.vhd` by another track; it is independent of this track and of
  the RTL's own code path, and it is NOT independent of `rmsnorm_rs`'s DESIGN.
  A defect in the algorithm that both share would pass. The 9B whole-model
  reference cannot close this at the scaled shape -- see
  `docs/debugging/2026-08-29_first-bisect.md` section 2 for why.
- **The `w_exp` is fixed at 12 and the quantisation is round-to-nearest with an
  overflow ASSERT.** No sweep, no error analysis against the f32 gain.
- **NOTHING RECORDS WHICH `w_exp` AN IMAGE WAS BUILT AT.** The file is bare hex
  and `NORM_W_EXP` is a separate generic. An image generated at 13 and served
  to a DUT at 12 is a wrong number with no structural symptom -- MEASURED as
  mutation row `wexp13`, 0 of 9 seams. A header line, or a generic the bench
  asserts against the file, would close it and neither exists.
- **`tools/check_a_geometry.py` is NOT in the gate** (R7), so the three sites it
  alone covers -- including `hw/fk33/gen_fk33_engine.py`, the one that decides
  the build -- are checked only when somebody runs it.
- **`tools/capture_normw.sh` restates the gate row's generics** and nothing
  checks they agree (T6).
- **Nothing here was run on hardware**, and `NORM_W_IMAGE` is not a path that
  could be: see 7.3.
- **The three predicted survivors were predicted, then measured.** M5, M6 in
  6.1 and M6, M7 in 6.3 were named in the harness BEFORE it ran. That is
  recorded as evidence about the harness, not as evidence about the design.

---

## 11. Corrections

None yet. Append here rather than editing above.
