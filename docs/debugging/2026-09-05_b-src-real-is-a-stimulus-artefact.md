# B_SRC_REAL's recorded blocker is a SYNTHETIC-WEIGHT artefact at 4, 8 and 16 blocks

**Date:** 2026-09-05
**Build:** GHDL 1.0.0 mcode, `sim/tb_llama_top.vhd`, token 0, `NRUNS=1`
**Files:** `rtl/llama_top.vhd`, `tools/gen_llama_top_weights.py`

## The question, verbatim

`rtl/llama_top.vhd:52-58` says of `B_SRC_REAL`: *"defaults FALSE and the reason
is measured, not conservatism: with it TRUE the degenerate-residual count
RISES, 0/3/10/23 -> 3/5/11/24 at 4/8/16/32 blocks, because A's synthetic
weights make R_ALPHA's VALUES physically impossible and gdn_scalar's gate
saturates shut."* Is that reason a property of the FEATURE or of the STIMULUS?

## The answer

**Of the stimulus.** MEASURED, `tb_llama_top`, token 0, one run per cell:

| blocks | `B_SRC_REAL` | weights | verdict |
|---|---|---|---|
| 4 | false | synthetic | PASS |
| 4 | false | REAL | PASS |
| 4 | **true** | **synthetic** | **FAIL** |
| 4 | **true** | **REAL** | **PASS** |
| 8 | false | synthetic | PASS |
| 8 | false | REAL | PASS |
| 8 | **true** | **synthetic** | **FAIL** |
| 8 | **true** | **REAL** | **PASS** |
| 16 | **true** | **synthetic** | **FAIL** |
| 16 | **true** | **REAL** | **PASS** |
| 16 | false | REAL | PASS |

**Three depths, same direction, no exceptions.** The recorded objection
reproduces exactly -- `B_SRC_REAL` with synthetic weights FAILS at every depth
-- and then dissolves when the ONLY thing changed is the weight image.

The mechanism is already written down in the same file, two hundred lines
away, at `llama_top.vhd:328-341`: the synthetic image has an rms row norm of
`2**4.87` against the real weights' `2**-0.03`, so it *"drives the stream up
about five octaves per matvec and out of rmsnorm_rs's window in the second
block"*. That is what makes `R_ALPHA`'s values impossible; `B_SRC_REAL` merely
sources alpha from `R_ALPHA` and so is the first thing to notice.

The generated images carry that signature: mean log2 row norm **-0.001** at 8
blocks and **-0.027** at 16, against synthetic's 4.87.

## The procedure

1. `--only tb_llama_top --keep` to build a per-row GHDL library, then
   `ghdl -r --std=08 -frelaxed --workdir=<row>/work` against it with generics.
   **`--std=08` is required** or GHDL looks for `work-obj93.cf` and reports
   `cannot find entity`, which reads as a missing design rather than a wrong
   standard.
2. The A/B at 4 blocks with the COMMITTED `sim/llama_top_w_b4_pool.hex`.
3. **Real images generated per depth** with `tools/gen_llama_top_weights.py`
   from `/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf`, because
   the committed image is 4-block only.
4. Repeat at 8 and 16.

Step 3 exists because a single depth proves nothing about the others: this
project's own record is that a model fitted to one point cannot be wrong about
that point and cannot be right about any other.

## What this does NOT establish, and it is most of it

- **NOT a token-correctness claim.** The bench says of itself: *"there is no
  value oracle for a whole token, so nothing here says the numbers are
  attention."* PASS means this bench's property set holds. It does not mean B
  computes the right numbers.
- **Token 0 ONLY.** `llama_top.vhd:4645` still refuses `B_SRC_REAL` past
  `tok_pos > 0`, and that refusal is UNTOUCHED by this result. It is the conv
  TAP HISTORY blocker: `cvdata_p` writes zero into every tap but the newest,
  and from token 1 `tvalid` marks those slots valid, so the conv would sum
  zeros at a real exponent.
- **So `B_SRC_REAL` still cannot run a multi-token sequence.** What changed is
  that it had TWO blockers and now has ONE. The remaining one is sized and
  concrete: a `(KCONV-1) x qkv_dim` buffer, 3 x 8,192 words at the 9B shape.
- **32 blocks untested.** The recorded table goes to 32; this goes to 16.
- **`NORM_REAL` was left at its default (false).** These runs use the
  `NORM_ANCHOR` probe, not the real `rmsnorm_rs`. The file's own table shows
  the two differ, so this says nothing about the real norm unit.
- **One run per cell.** No latency sweep (`NRUNS=1`), no seed variation.

## Measured and REJECTED -- do not retry

- **"`B_SRC_REAL` is blocked because R_ALPHA's values are physically
  impossible."** REJECTED as stated. They are impossible under A's SYNTHETIC
  weights. With real weights the same configuration passes at 4, 8 and 16
  blocks.
- **Running `B_SRC_REAL` at 8+ blocks with the committed image.** The bench
  refuses, correctly and by name: *"the weight image ... has 20480 words, this
  shape needs 40000. It was built for a different BLOCKS or ATTN_INT."*
  Generate the image for the depth.

## Measurement traps hit

- **`-gW_IMAGE=` PASSED EMPTY CRASHES GHDL**: `unhandled exception`, rc=1, no
  verdict. The flag must be OMITTED for the synthetic arm, not passed with an
  empty value. MEASURED: the first version of this experiment passed it empty
  and **every synthetic-weight cell reported `rc=1 NO-VERDICT`**, which looks
  exactly like the feature failing. **The tell was that the CONTROL failed** --
  `B_SRC_REAL=false` with synthetic weights is the default configuration and
  passes as a gate row every day. A control that fails is a broken harness,
  not a discovery.
- **`ghdl -r` without `--std=08`** against a `work-obj08.cf` library reports
  `cannot find entity or configuration`, which reads as a missing entity.
- **The 8-block rows of the FIRST matrix were not a result.** Both real-weight
  cells failed identically with `B_SRC_REAL` true and false, which is the
  control saying the failure is not attributable to the variable. It was the
  wrong-sized image.

## Open, not yet answered

- **The conv tap-history buffer.** Sized above, not written, and it is now the
  ONLY thing between `B_SRC_REAL` and a multi-token run.
- **32 blocks**, and `NORM_REAL=true` with real weights.
- **Whether `B_SRC_REAL` should default true.** It cannot until the tap
  history exists, so the default is still correct today.
- **Nothing here runs on hardware**, and `B_SRC_REAL` is a bench switch with
  no meaning on the card (`llama_top.vhd:4642`).

---

## FOLLOW-UP: the remaining blocker is NOT "a new buffer". It is two connections.

`llama_top.vhd:4636` sizes the remaining work as *"Holding the history is a new
(KCONV-1) x qkv_dim buffer -- 3 x 8,192 words at the 9B shape"*. **That
buffer is not new. It already exists, is correctly sized, is instantiated, and
its WRITE path is already connected.**

`rtl/gdn_state_store.vhd:45-47` carries it as one of three per-layer segments:

```
-- A GDN layer's state is the recurrent MANTISSAS (1,048,576 B), the state
-- EXPONENTS (4,096 B) and the CONV TAP HISTORY (49,152 B) -- `(conv_kernel-1)
-- x qkv_dim` 16-bit elements, the previous KCONV-1 columns of the whole qkv
-- stream that `gdn_conv`'s causal kernel needs.
```

49,152 B is exactly `(KC-1) * qkv_dim * 2` = `BST_CONV_B` at `llama_top:4066`,
and `llama_top:4232` instantiates `gdn_state_store` with `CONV_BYTES =>
BST_CONV_B` inside `LAYER_STRIDE`.

**A per-layer rotation is NOT needed, and the design says why** -- which
answers the obvious objection that conv state is per layer and 24 layers would
mean 24x the storage (`gdn_state_store.vhd:139-142`):

```
-- ONE pulse per TOKEN, after every layer has read and written.  Not per
-- layer: every GDN layer is visited once per token so all of them rotate in
-- lockstep, which is why the rotation needs no per-layer state and therefore
-- no HBM storage.
```

### What is actually missing

`gdn_state_store.vhd:51-56` named it when the tier was written: *"nothing here
FEEDS the conv tap write port ... and nothing pulses `tok_adv` ... Both are
the job sequencer's, and until it exists this tier is complete and unused."*

**The job sequencer now exists.** `llama_top:4258` connects the write side:

```vhdl
cvw_en => js_cvw_en, cvw_seg => js_cvw_seg, cvw_grp => js_cvw_grp,
cvw_data => js_cvw_data, tok_adv => '0',
cv_seg => 0, cv_grp => 0, cv_x => open,
```

So of the two things that comment says are missing, **one is done**. What
remains, and `llama_top:4252-4256` states it outright -- *"`gdn_job_seq` still
refills the store's taps so the arm is complete and one change lifts the
token-1 refusal later"*:

1. **`tok_adv` is tied to `'0'`**, so the rotation never advances.
2. **`cv_x` is left `open`**, so the stored taps reach nothing.

### The real constraint, which is NOT storage

`llama_top:4252` records why the read side was left open, and it is a genuine
design problem rather than an oversight:

> *"memory 3 below supplies the taps AND `cv_w`/`cv_cw_exp`, which the store
> does not carry, so the two cannot be swapped wholesale."*

`cvdata_p` produces `cv_x`, `cv_w` (conv WEIGHTS, learned constants) and
`cv_cw_exp` together. `gdn_state_store` carries only the taps. So wiring
`cv_x` from the store means splitting one producer into two, keeping the
weights from memory 3 and taking the taps from the store.

**It also couples `B_SRC_REAL` to `B_STATE_AXI`**, because the store exists
only in that tier. Two generics that are independent today would stop being
independent.

### So the corrected cost

| | recorded | measured |
|---|---|---|
| storage to add | "a new 3 x 8,192 word buffer" | **none; it exists and is instantiated** |
| conv tap write path | missing | **already connected to `gdn_job_seq`** |
| remaining | -- | drive `tok_adv`; split `cvdata_p` so taps come from `cv_x` |
| new coupling | not stated | `B_SRC_REAL` would require `B_STATE_AXI` |

**This is not a recommendation to make the change.** Splitting a producer that
three signals share, and coupling two generics, is a design decision with a
real blast radius, and the existing refusal is correct behaviour until it is
made. It is a correction to the COST, which is what a decision would be taken
on.

**And it is still not a correctness claim.** Nothing here says B computes the
right numbers at token 1; it says what stands between the design and being
able to try.
