# The `llama_top` capture in `.r9bs`, and what it can and cannot be diffed against

**Date:** 2026-08-29
**Track:** CAPTURE
**Repository HEAD:** `ed1ffe2` when the track started, `2d10f76` when it
finished -- four commits landed underneath it. **Every measurement below was
re-verified to correspond to a pristine `git archive 2d10f76` tree**; see 5.1
and 7.1, which is where this track got something wrong and had to correct it.
**Tools:** GHDL (mcode backend), Python 3, `ref/matvec_int4.c` via
`tools/ref9b/mv_step_oracle`

---

## 1. The question, verbatim

> TRACK REF9B then reported the gap that blocks it being used: **there is no
> `llama_top` capture in `.r9bs`.** Its words: "the four units on the path were
> read, not run" and "no `llama_top` capture in `.r9bs` exists; that remains the
> missing artefact item 12 named."
>
> Without that capture the reference cannot be diffed against anything the
> design actually produces, which is the entire point of building it. Produce
> it.

Plus a precondition the brief required be handled rather than discovered late:
`ref/run9b.c`'s `reg_put` always normalises while every shipping unit clamps,
so `--mode exact` against a real capture was expected to report a false first
divergence before reaching any real defect.

---

## 2. The answer, up front

**The capture exists now, in `.r9bs`, for all three configurations
`sim/tb_llama_top.vhd` supports, and `seam_bisect.py --mode exact` runs against
it end to end with 59, 58 and 54-per-token seams bit-identical. MEASURED.**

**But the brief's premise is wrong, and this is the more important half.**
Producing the capture does NOT let the whole-model 9B reference be diffed
against it, and no amount of format work will. MEASURED by running it:

```
$ python3 seam_bisect.py /mnt/storage/ref9b/ref_bfp.r9bs \
      /mnt/storage/ref9b-capture/llama_top_real_HEAD.r9bs --mode exact --tok 0
# exact compare, token 0: 0 seams identical, 63 differ

FIRST DIVERGENCE: R_X.embed at element -1 -- length 4096 vs 64
```

Zero of 63 seams agree and every one of them fails on LENGTH, at the very first
seam, for a reason that is not about the design: `sim/tb_llama_top.vhd` runs
`mk_shape_scaled` at hidden 64 and the model is hidden 4096. The missing
artefact item 12 named was never blocked on format. It is blocked on SHAPE, and
the only producer that can ever be on the other side of `ref/run9b`'s stream is
a CARD.

**So the `.r9bs` capture was made useful a different way: by building the
reference side at the shape the simulation actually runs**
(`tools/ref9b/ref_stream_scaled.py`, new). It emits the same independent
stepwise models `bisect_scaled.py` compares against, as a `.r9bs` stream
instead of as a verdict, so `--mode exact` has a counterpart.

**On the BFP repack precondition: it does not bite here, and the reason says
which route is needed.** The divergence REF9B measured is between
`ref/run9b.c`'s always-normalise `reg_put` and the RTL's clamped rule. Neither
side of the comparison delivered here is `reg_put`: the capture is the RTL and
the reference models the RTL. So `--mode exact` is clean. The divergence is
live ONLY for a card capture at the real shape against `ref/run9b`, which is
the comparison that does not exist yet. **What this track's numbers add is the
size of the problem on real `llama_top` output rather than on `bfp_pack`'s
synthetic grid: 39 of 63 BFP records (61.9%) in one token are under-normalised**
-- higher than the 39.4% REF9B derived for the reference stream. Section 6.

---

## 3. The procedure, in the order it was run, and what each step isolates

| # | probe | what it isolates |
|---|---|---|
| 1 | Re-run `capture_llama_top.sh real` at HEAD and diff against the committed golden | whether the committed artefact is still valid. It is NOT. |
| 2 | `bisect_scaled.py` on the fresh capture | whether the capture is RIGHT, by the existing independent stepwise models, before any new code is written |
| 3 | `capture_to_r9bs.py --check-names` on all three configurations | whether the seam NAMES survive the format. For `seq` they do not. |
| 4 | `seam_bisect.py --mode exact` against `ref/run9b`'s 9B stream | the shape question, MEASURED rather than quoted from another track |
| 5 | New `ref_stream_scaled.py`, then `--mode exact` against the capture | whether the exact path works end to end on real `llama_top` data |
| 6 | A normalisation census of the capture's BFP records | which seams sit on the clamped rule and by how much, on real output |
| 7 | `mutate_capture.sh`: four mutations, one of them expected to survive | whether the whole chain has teeth, and where its floor is |
| 8 | `--attn-fold shared` against `--attn-fold perlayer` on the 3-token `seq` capture | a firing negative control, and independent corroboration of defect C1's fix |
| 9 | Re-capture from a pristine `git archive HEAD` tree | whether a concurrent track's uncommitted `rtl/` edits contaminated any of the above |

Step 9 exists because step 1 was run against the WORKING TREE, which is what
`capture_llama_top.sh` reads, and three other tracks are editing `rtl/`. Doing
it as an afterthought is the trap; doing it at all is the point.

---

## 4. The artefacts

All streams are under `/mnt/storage/ref9b-capture/` (592 KB total), deliberately
not in the repository.

| file | what it is | records |
|---|---|---|
| `llama_top_real_HEAD.{txt,r9bs}` | the REAL path: real A, B, C, `rmsnorm_rs`, committed 9B weight image, 1 token | 63 |
| `llama_top_stub_HEAD.{txt,r9bs}` | `tb_llama_top` defaults: attention is the ramp stub, `NORM_ANCHOR` | 63 |
| `llama_top_seq_HEAD.{txt,r9bs}` | the KV cache: `ATTN_INT=2`, `ATTN_HD=64`, `KV_AXI`, **3 tokens** | 180 (60/token) |
| `ref_scaled_real_HEAD.r9bs` | the reference side for `real` | 59 modelled, 4 omitted |
| `ref_scaled_stub_HEAD.r9bs` | the reference side for `stub` | 58 modelled, 6 omitted |
| `ref_scaled_seq_HEAD.r9bs` | the reference side for `seq`, all 3 tokens | 171 modelled, 12 omitted |
| `ref_seq_FOLDSHARED.r9bs` | the same with `--attn-fold shared`: the negative control | 171 |
| `cap_m{0,1,2,3}.{txt,r9bs}`, `ref_m{0,1,2,3}.r9bs` | the mutation table's captures and their references | -- |
| `llama_top_real_CLEANHEAD.{txt,r9bs}`, `ref_CLEANHEAD.r9bs` | the same capture from a pristine `git archive 0af42c7` tree (section 5.1) | 63 |
| `llama_top_real_HEAD2d10f76.txt`, `llama_top_real_a77d181.txt` | pristine-tree captures pinning which commit moved the landmark | 63 |

Each reference stream has a `.coverage` sidecar naming every OMITTED seam and
why. **An omitted seam is absent from the stream, so `seam_bisect.exact()`
skips it; a clean compare says nothing whatever about those seams.** They are
omitted rather than copied from the capture on purpose: copying would make the
comparison report agreement it has not established, which is the `m7` mutant
this project already has on record.

New code, both files owned by this track:

- `tools/ref9b/ref_stream_scaled.py` -- the reference side at the scaled shape.
- `tools/ref9b/mutate_capture.sh` -- the teeth-check. Copies the tree to
  scratch and mutates the COPY; it never touches `rtl/`.

Nothing else in the repository is touched. `tools/ref9b/golden/llama_top_real.txt`
was regenerated and then REVERTED; see 5.1 for why that was the right call.

---

## 5. The evidence, as raw captured output

### 5.1 The committed golden, and a wrong conclusion this track drew and then killed

First measurement: re-run the capture and diff against the committed golden.

```
$ bash tools/ref9b/capture_llama_top.sh real ...
tb_llama_top RESULT: PASS -- ... R_X(0) = -16364 hash(R_X) = 91622

$ diff <(grep -v '^#' tools/ref9b/golden/llama_top_real.txt) \
       <(grep -v '^#' /mnt/storage/ref9b-capture/llama_top_real_HEAD.txt) | wc -l
670
```

The golden carries `R_X(0) = -16339 hash(R_X) = 92903`. **I concluded the
golden was stale, attributed it to `b75d7a1`, and regenerated the file. That
conclusion was WRONG and the regeneration was reverted with
`git checkout --`.** `capture_llama_top.sh` reads the WORKING TREE, and at that
moment `rtl/llama_top.vhd` and `rtl/gdn_block.vhd` carried a concurrent track's
uncommitted edits. The 670 lines were that track's work, not staleness.

Killed by capturing from a pristine tree, which touches nothing another track
can see:

```
$ git archive HEAD | tar -x -C $CLEAN          # extracted 0af42c7
$ cd $CLEAN && bash tools/ref9b/capture_llama_top.sh real ...
tb_llama_top RESULT: PASS -- ... R_X(0) = -16339 hash(R_X) = 92903

$ diff <(grep -v '^#' tools/ref9b/golden/llama_top_real.txt) \
       <(grep -v '^#' .../llama_top_real_CLEANHEAD.txt)
[no output]
BYTE-IDENTICAL: the committed golden is NOT stale; the 670-line diff was the
DIRTY WORKING TREE
```

**Then the tree moved again while this was being written**, and the picture
changed a third time. Four commits landed during the track
(`f0645b8`, `0af42c7`, `a77d181`, `2d10f76`). Captures from pristine
`git archive` trees at three of them:

| tree | `R_X(0)` | `hash(R_X)` | note |
|---|---|---|---|
| `0af42c7` | -16339 | 92903 | **byte-identical to the committed golden** |
| `a77d181` | -16364 | 91622 | B-BLK-1's key-head mapping fix moved it |
| `2d10f76` (HEAD) | -16364 | 91622 | unchanged |

So the golden **is** stale now, as of `a77d181`, which landed roughly an hour
into this track. And the fact that `2d10f76` does not move it further is
independent corroboration of that commit's own claim that the B state memory's
missing layer dimension was LATENT rather than live: giving it the dimension
changes no captured seam.

**The golden is deliberately NOT regenerated here.** It is another track's
artefact, it goes stale on every `rtl/` commit that touches the real path, and
this track already got the diagnosis wrong once by assuming. What it needs is
an owner and possibly a generated-not-committed treatment, which is a decision,
not an edit. Section 8.

**`sim/tb_llama_top_real.vhd:16` carries `R_X(0) = -16339 hash 92903` in a
comment and is now also behind.** Not fixed here: that file belongs to another
track.

Every other measurement in this document was checked against a pristine
`git archive 2d10f76` tree and is byte-identical to it:

```
$ diff -q <(grep -v '^#' .../llama_top_real_HEAD2d10f76.txt) \
          <(grep -v '^#' .../llama_top_real_HEAD.txt)
IDENTICAL: every measurement in this track corresponds to pristine HEAD 2d10f76
```

### 5.2 The fresh capture is right, by the models that already existed

```
$ python3 bisect_scaled.py .../llama_top_real_HEAD.txt \
      --blocks 4 --attn-int 4 --attn-hd 16 --norm real \
      --w-image ../../sim/llama_top_w_b4_pool.hex
# stepwise oracle, token 0, shape blocks=4 attn_interval=4 attn_hd=16 hidden=64 ffn=128
# 59 seams checked against a model, 4 NOT checked
    NOT CHECKED  R_Y-0          subsystem B has no integration-level model
    NOT CHECKED  R_Y-1          subsystem B has no integration-level model
    NOT CHECKED  R_Y-2          subsystem B has no integration-level model
    NOT CHECKED  LOGITS         destination is R_NONE: the lm_head job discards its result

EVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT, given the machine's own inputs.
```

### 5.3 The `--mode exact` path, end to end, for the first time

```
$ python3 ref_stream_scaled.py .../llama_top_real_HEAD.txt \
      -o .../ref_scaled_real_HEAD.r9bs --blocks 4 --attn-int 4 --attn-hd 16 \
      --norm real --w-image ../../sim/llama_top_w_b4_pool.hex
wrote .../ref_scaled_real_HEAD.r9bs: 59 seams modelled, 5 omitted
  OMITTED R_Y-0          subsystem B has no integration-level model
  OMITTED R_Y-1          subsystem B has no integration-level model
  OMITTED R_Y-2          subsystem B has no integration-level model
  OMITTED LOGITS         destination is R_NONE: the lm_head job discards its result
  OMITTED R_X.embed      the bench writes it; it is an INPUT to the model, not an output of one

$ python3 seam_bisect.py .../ref_scaled_real_HEAD.r9bs \
      .../llama_top_real_HEAD.r9bs --mode exact --tok 0
# exact compare, token 0: 59 seams identical, 0 differ

EVERY COMPARED SEAM IS BIT-IDENTICAL.
```

`stub`: 58 identical, 0 differ. `seq`: 54 identical, 0 differ, on each of
tokens 0, 1 and 2 -- see 5.5 for why 54 and not 57.

### 5.4 The whole-model 9B reference cannot be the counterpart

```
$ python3 seam_bisect.py /mnt/storage/ref9b/ref_bfp.r9bs \
      .../llama_top_real_HEAD.r9bs --mode exact --tok 0 -v
# exact compare, token 0: 0 seams identical, 63 differ

FIRST DIVERGENCE: R_X.embed at element -1 -- length 4096 vs 64
```

This confirms `bisect_scaled.py`'s docstring claim by running it, rather than
by quoting it.

### 5.5 THREE SEAMS OF THE `seq` CAPTURE ARE SKIPPED SILENTLY

`--check-names` refused the `seq` conversion:

```
$ python3 capture_to_r9bs.py .../llama_top_seq_HEAD.txt -o ... --check-names
line 111: seam name 'R_QG-1' is not in seam_map.SEAMS, so the bisect would
silently never compare it
```

Quantified:

```
real   63 records, 63 distinct seams,  0 NOT in seam_map: []
stub   63 records, 63 distinct seams,  0 NOT in seam_map: []
seq   180 records, 60 distinct seams,  3 NOT in seam_map: ['R_KIN-1', 'R_QG-1', 'R_VIN-1']

layers seam_map gives R_QG to: [3, 7, 11, 15, 19, 23, 27, 31]

reference records: 171  capture records: 180
present in BOTH: 171
of those, NOT in seam_map so never visited by exact(): ['R_KIN-1', 'R_QG-1', 'R_VIN-1']
per token: modelled 57  compared 54
```

**`seam_map.SEAMS` hardcodes the 9B interleave -- attention at every fourth
layer.** The `seq` configuration runs `ATTN_INT=2`, so layer 1 is an attention
layer and its three attention-input seams have no entry.
`seam_bisect.exact()` iterates `order = [s[0] for s in SEAMS]`, so a seam
absent from the map is never visited. **Three seams per token are present in
BOTH streams, are modelled, and are dropped with no warning, while the summary
line reads `54 seams identical, 0 differ` as though that were full coverage.**
`--check-names` is opt-in and is the only thing that catches it.

Not fixed here. `seam_map.py` is a pre-existing shared file in a directory a
concurrent track also claims, and the fix is a decision about whether the map
should be generated from a shape rather than pinned to the 9B one. Section 8.

### 5.6 The teeth, and the mutation that does NOT bite

`bash tools/ref9b/mutate_capture.sh all`. Every RTL mutation is applied to a
COPY of the tree in scratch; `rtl/` is never touched.

| mut | what it breaks | verdict | first divergence |
|---|---|---|---|
| control | nothing | -- | 59 identical, 0 differ |
| **m0** | one mantissa of `R_XN-0` in the CAPTURE, +1 LSB | **KILLED** | `R_XN-0` at element 0 -- exp 14 vs 14, **1 of 64** mantissas differ |
| **m1** | `seq_vec_res`: output rounding bias deleted, residual truncates | **KILLED** | `R_X.attn-0` at element 0 -- exp 11 vs 11, 32 of 64 differ |
| **m2** | `seq_vec_res`: shift floor 0 -> 1, every residual under-normalised by one bit | **KILLED** | `R_X-1` at element 0 -- **exp 10 vs 9**, 64 of 64 differ |
| **m3** | `gdn_silu`: SiLU emit truncates instead of rounding | **SURVIVED** | none: 59 identical, 0 differ |

Raw:

```
===================== m0 =====================
m0: R_XN-0 element 0 moved by +1 LSB
# exact compare, token 0: 54 seams identical, 5 differ
FIRST DIVERGENCE: R_XN-0 at element 0 -- exp 14 vs 14, 1 of 64 mantissas differ

===================== m1 =====================
tb_llama_top RESULT: PASS -- ... R_X(0) = -16366 hash(R_X) = 48408
# exact compare, token 0: 54 seams identical, 5 differ
FIRST DIVERGENCE: R_X.attn-0 at element 0 -- exp 11 vs 11, 32 of 64 mantissas differ

===================== m2 =====================
tb_llama_top RESULT: PASS -- ... R_X(0) = -8182 hash(R_X) = 83742
# exact compare, token 0: 56 seams identical, 3 differ
FIRST DIVERGENCE: R_X-1 at element 0 -- exp 10 vs 9, 64 of 64 mantissas differ

===================== m3 =====================
tb_llama_top RESULT: PASS -- ... R_X(0) = -16364 hash(R_X) = 91622
# exact compare, token 0: 59 seams identical, 0 differ
EVERY COMPARED SEAM IS BIT-IDENTICAL.
```

**m0 fixes the resolution floor at ONE LSB in ONE element of ONE seam**, and
the report names the element index, not just the seam.

**m1 and m2 land at different seams and that is the useful part.** m1 changes
rounding, so it bites at the first residual, `R_X.attn-0`. m2 raises the shift
floor, which only does anything where the clamped rule would have chosen shift
0; the first such residual is `R_X-1`, two seams later, and it moves the
EXPONENT (10 vs 9) rather than only the mantissas. m2 is deliberately in the
same family as the `reg_put` divergence -- an exponent rule that disagrees --
and it demonstrates that `--mode exact` catches that family at the exponent.

**m3 SURVIVED, and it is the most valuable row.** It is not inert:

```
seams that moved in the capture, m3 vs clean:
   R_Y-0  exp 18 18  ndiff 60 of 128
   R_ER-0 exp 16 16  ndiff 32 of 64
   R_Y-1  exp 18 18  ndiff 56 of 128
   R_ER-1 exp 16 16  ndiff 22 of 64
   R_Y-2  exp 18 18  ndiff 68 of 128
   R_ER-2 exp 16 16  ndiff 34 of 64
```

Six seams moved and the comparison still reported 0 differences, for **two
independent reasons that must not be conflated**:

1. **The structural one.** `R_Y` at a GDN block has no integration-level model,
   so the reference OMITS it. `R_ER-0` does have one, but it is an A job whose
   INPUT is `R_Y-0`, and the reference recomputes it from the MUTANT's own
   `R_Y-0` -- so it agrees. This is the stepwise oracle's blind spot, stated
   in `bisect_scaled.py`'s docstring, now measured with numbers.
2. **A stimulus one, which is separate and was not expected.** Every seam AFTER
   `R_ER-2` is bit-identical in the capture as well, so the bench's own
   `R_X(0) = -16364 hash 91622` landmark is unchanged by a live subsystem-B
   defect. The residual absorbs it: `R_ER-0` sits at exp 16 while `R_X.embed`
   sits at exp 3, so the alignment shift discards exactly the bits m3 moved.
   **`tb_llama_top`'s R_X hash cannot see this defect either.** That is the
   OI-3 family, a sixth instance.

### 5.7 The one comparison regime that DOES catch m3, and what it costs

Comparing the mutant capture against the CLEAN reference instead of against a
reference rebuilt from its own inputs:

```
$ python3 seam_bisect.py .../ref_scaled_real_HEAD.r9bs .../cap_m3.r9bs --mode exact
# exact compare, token 0: 56 seams identical, 3 differ
FIRST DIVERGENCE: R_ER-0 at element 4 -- exp 16 vs 16, 32 of 64 mantissas differ

$ python3 seam_bisect.py .../ref_scaled_real_HEAD.r9bs .../cap_m1.r9bs --mode exact
# exact compare, token 0: 10 seams identical, 49 differ
FIRST DIVERGENCE: R_X.attn-0 at element 0 -- 32 of 64 mantissas differ
```

**The two regimes have complementary teeth and neither dominates.** A frozen
clean reference catches m3, which the self-rebuilt one structurally cannot --
but it flags 49 of 59 seams on m1, because every downstream seam legitimately
moved, so it localises nothing. The self-rebuilt reference localises precisely
and is blind wherever a model is missing. **Run both. The frozen one answers
"did anything change"; the self-rebuilt one answers "which step is wrong".**

### 5.8 A firing negative control, and independent corroboration of defect C1

The `seq` capture is 3 tokens with the KV cache live and TWO attention layers.
Subsystem C's model takes a `--attn-fold` argument: `perlayer` is C spec 2.1.4,
`shared` is what one time-shared `attn_block` did before `b75d7a1`.

```
--attn-fold perlayer (the spec):
tok 0: 54 seams identical, 0 differ    EVERY COMPARED SEAM IS BIT-IDENTICAL.
tok 1: 54 seams identical, 0 differ    EVERY COMPARED SEAM IS BIT-IDENTICAL.
tok 2: 54 seams identical, 0 differ    EVERY COMPARED SEAM IS BIT-IDENTICAL.

--attn-fold shared (the pre-b75d7a1 behaviour):
tok 0: 54 seams identical, 0 differ    EVERY COMPARED SEAM IS BIT-IDENTICAL.
tok 1: 53 identical, 1 differ  FIRST DIVERGENCE: R_Y-1 at element 12 -- 92 of 256 differ
tok 2: 53 identical, 1 differ  FIRST DIVERGENCE: R_Y-1 at element 16 -- 126 of 256 differ
```

**Token 0 is identical under BOTH folds and tokens 1 and 2 are not**, which is
exactly right: at token 0 there is no earlier `v_ref` to fold, so the two rules
coincide, and they can only separate once the cache holds an earlier token's
records. This is a control that fires where it should and stays silent where it
should.

It is also integration-level evidence, at the seam and over a multi-token KV
sequence, that `rtl/attn_block.vhd` at HEAD implements the per-layer fold the
spec requires. Note the limit: it discriminates the two folds, it does not
independently re-derive the spec.

---

## 6. The BFP repack precondition: measured, and it does not bite here

REF9B's claims, checked against the RTL at HEAD rather than taken on trust:

| claim | verdict |
|---|---|
| `bfp_pack` computes `sh = max(0, msb_pos(amax) - 14)` | **CONFIRMED**, `rtl/bfp_pack.vhd:135-136`: `p_msb := msb_pos_u(mx_u); sh := p_msb - 14; if sh < 0 then sh := 0; end if;` |
| `reg_put` computes `exp = 14 - floor(log2(amax))` with no clamp | **CONFIRMED**, `ref/run9b.c`: `int e = (int)floor(log2(amax)); r->exp = 14 - e;` |
| `bfp_pack` appears zero times in `rtl/llama_top.vhd` | **CONFIRMED**, `grep -c` returns 0 |
| the four on-path units clamp identically | **CONFIRMED in substance, three of four line numbers are off** -- see below |
| the clamp is into a signal that cannot hold a negative | **CONFIRMED and sharpened**: `rtl/seq_vec_res.vhd:255` declares `sh_r : natural range 0 to 63`, so removing the clamp there is a bound violation, not a different computation |

Line-number corrections, all measured by reading the files at HEAD:

| REF9B said | actually at HEAD |
|---|---|
| `rmsnorm_rs:519` | the clamp is at **`:526`** (`if msb_p - 14 < 0 then st := 0; else st := msb_p - 14; end if;`). `:519` is `msb_p <= p;`, the priority encode. |
| `seq_vec_res:598` | `:598` is `when S_SHIFT2 =>`; the clamp is at **`:599-600`**. |
| `gdn_y_emit:373` | **exact.** |
| `attn_emit:551` | `:551` is the subtract; the clamp is at **`:554`**. |

**One thing REF9B missed: `attn_emit` clamps at BOTH ends.** `rtl/attn_emit.vhd:555`
adds `if sh_v > SHP_MAX then sh_v := SHP_MAX; end if;`, which no other unit on
the path has. So `attn_emit` can be under-normalised at the top of the range as
well as the bottom, and a comparison written to expect only the lower clamp
would be wrong about that unit.

### 6.1 The size of the problem on real output

REF9B measured `bfp_pack` on a synthetic grid: 341 of 760 cases (44.9%),
and DERIVED 193 of 490 records per token (39.4%) for the reference stream. The
equivalent measurement on the hardware's own output, over the 63 BFP records of
one real-path token:

```
bfp16 records: 63
  msb==14 (normalised):                                    24
  msb <14 (UNDER-normalised, the two rules DIFFER here):   39   (61.9%)
  msb >14 :                                                 0
```

**61.9%, against the 39.4% derived for the reference stream.** The shortfall by
seam family, worst first:

| family | shortfall below bit 14 |
|---|---|
| `R_ER.ffn-{0,1,2,3}` | 7, 8, 8, 8 bits |
| `R_H-{0,1,2,3}` (the SwiGLU stub) | 5, 5, 6, 6 bits |
| `R_ER-{0,1,2,3}` | 3, 3, 3, 2 bits |
| `R_G`, `R_U`, `R_ALPHA`, `R_BETA` | 1 to 4 bits |
| `R_QKV.*`, `R_Z`, `R_QG`, `R_KIN`, `R_VIN`, `R_X-2` | 1 bit |

`R_H` being systematically among the worst is consistent with REF9B's separate
claim that it uses a fixed shift of `MANT_W` with no maximum scan. `R_X.embed`
is 8 bits short but is not evidence about any packer: the bench writes it.

### 6.2 Which route the capture work says is needed

REF9B scoped three routes and correctly left the choice to Oren. This track did
not pick one and did not touch `ref/run9b.c`. What the capture work adds is
evidence about WHEN the choice has to be made:

- **It is not needed for any simulation comparison, now or later.** Both sides
  of every comparison delivered here are the RTL's rule. Adding a
  `--mode exact` capture did not surface the divergence even once.
- **It is needed before the first card capture is compared, and not before.**
  That comparison is the only one with `reg_put` on one side.
- **The evidence favours a route that makes the reference match the RTL rather
  than the reverse**, on two measurements: the shortfall is not a fixed
  1 bit but ranges 1 to 8 bits and is worst at `R_ER.ffn` and `R_H`, so no
  single constant correction exists; and m2 shows `--mode exact` reports this
  family as an EXPONENT difference, which is precisely the signal a bring-up
  engineer needs and which a normalising reference would erase at every seam.
- **`attn_emit`'s upper clamp (6, above) means a corrected reference needs
  BOTH clamps, not one.** Any route that models "the RTL clamps at zero" and
  stops there will be wrong on subsystem C's output.

---

## 7. Measurement traps hit, including my own

### 7.1 "At HEAD" was a claim about the WORKING TREE, and it was false

The worst trap of the track, and it produced a confident wrong finding that was
already written into a document and into a regenerated artefact before it was
caught.

`capture_llama_top.sh` reads the working tree, not HEAD. Three other tracks
were editing `rtl/`. So the first capture was of HEAD plus one track's
uncommitted `rtl/llama_top.vhd` and `rtl/gdn_block.vhd`, and the 670-line diff
against the committed golden read exactly like staleness. I attributed it to a
plausible commit (`b75d7a1`, whose message even says "three landmarks move"),
regenerated the golden, and wrote a header asserting "with a CLEAN rtl/ tree".
**Every word of that was wrong, and none of it was reckless -- the story was
coherent, the commit existed, and the numbers were real.**

Three lessons, in increasing order of usefulness:

1. **`git archive <rev> | tar -x -C <scratch>` is the cheap probe** and it is
   the right one: it touches nothing under `.git` and cannot disturb another
   track, which `git stash` would. It cost 100 seconds and killed the finding.
2. **A plausible commit in the log is not evidence.** `b75d7a1` was in HEAD's
   history and its message advertised moved landmarks. It was innocent. The
   guilty commit (`a77d181`) had not been written when I formed the hypothesis.
3. **On a repository with concurrent tracks, "at HEAD" is a MEASUREMENT, not a
   context.** Record the rev you actually ran against, and re-check it at the
   end: HEAD moved four commits under this track and the answer changed twice.

### 7.2 A generic scratch directory name collided with another track, again

`MUTBASE` defaulted into the session scratchpad under the name `mut`, which
already contained another track's mutation sweep (`M1_beh`, `M10_real`,
`C0_real`, ... 70-odd directories). My names are lowercase `m1`/`m2`/`m3` and
the other track's are uppercase `M1_*`, so `rm -rf "$BASE/$m"` destroyed
nothing -- **by luck, not by design.** This is the second recorded instance
(`c30e827` is the first). The scratchpad is shared between agents in a session;
treat a bare `mut`, `work` or `run` as already taken.

### 7.3 An empty capture compares equal to an empty capture

`capture_llama_top.sh` already guards this and `mutate_capture.sh` repeats the
guard, scoring a run that produced no file as ABORT rather than as a survival.
Without it a mutation whose sed failed, or whose run died, reads as
"EVERY COMPARED SEAM IS BIT-IDENTICAL" -- a perfect score for a run that never
happened. `mutate_capture.sh` also verifies each sed actually matched, and
reports a non-matching sed as a harness failure rather than a survival.

### 7.4 "59 seams modelled" and "59 seams compared" are different numbers

On `real` they coincide, which is exactly why the `seq` case is worth stating:
57 modelled, 54 compared, and nothing in the output says so. A count printed by
the producer is not a count of what the consumer looked at.

### 7.5 A survivor that changed nothing would have proved nothing

m3's `R_X` landmark is bit-identical to the clean run, which at first reading
says the mutation was inert and therefore worthless as a blind-spot
measurement. It was not: the capture diff shows six seams moved. **Check
whether a surviving mutant is live before reporting it as a resolution floor;
an inert mutation and a genuine blind spot look identical in the verdict.**

---

## 8. Measured and REJECTED -- do not retry

- **Do not try to diff `ref/run9b`'s stream against a GHDL `llama_top`
  capture.** MEASURED: `0 seams identical, 63 differ`, first failure
  `R_X.embed length 4096 vs 64`. It is a shape mismatch, not a format or
  plumbing problem, and `bisect_scaled.py`'s docstring already said so. The
  only producer that can be on the other side of `ref/run9b`'s stream is a
  card.

- **Do not expect the `reg_put` / clamp divergence to appear in any simulation
  comparison.** MEASURED across three configurations, four mutations and 5
  tokens' worth of streams: it appeared zero times, because neither side of
  those comparisons is `reg_put`.

- **Do not remove the clamp in `rtl/seq_vec_res.vhd` to make it match
  `reg_put`.** `:255` declares `sh_r : natural range 0 to 63`; the result is a
  bound violation, not an always-normalising unit. The legal mutation in that
  family is a raised floor (m2), which is what was used.

- **Do not use a frozen clean reference to LOCALISE a defect.** MEASURED on m1:
  49 of 59 seams differ, because every downstream seam legitimately moved. It
  answers "did anything change" and nothing more. Use it alongside the
  self-rebuilt reference, not instead of it.

- **Do not copy an unmodelled seam from the capture into the reference stream
  to raise the coverage count.** It converts a comparison into a round trip
  while leaving the verdict line unchanged, which is the failure mode this
  project has on record as the `m7` mutant.

- **Do not read `54 seams identical, 0 differ` on a `seq` capture as full
  coverage.** Three seams per token are silently absent from the walk.

- **Do not diff a fresh capture against a committed golden and conclude
  "stale".** MEASURED: the 670-line diff that says staleness says
  "another track has uncommitted `rtl/` edits" just as loudly, and on this
  repository the second is the likelier reading. `git archive <rev>` into
  scratch separates them in 100 seconds. Do that BEFORE forming a hypothesis
  about which commit is responsible, not after -- the commit that looked
  guilty (`b75d7a1`) was innocent, and the guilty one (`a77d181`) did not exist
  yet when the hypothesis was formed.

- **Do not treat "the comparison is clean at two different RTL revisions" as
  robustness.** Section 8.1: with the change entering at an unmodelled seam it
  is guaranteed by construction, not earned.

---

### 8.1 A result that looks like robustness and is not

The reference-versus-capture comparison is clean at BOTH `0af42c7` and
`2d10f76`, two trees whose captures differ in dozens of seams. That reads like
evidence that `ref_stream_scaled.py` tracks an RTL change correctly. **It is
not.** `a77d181` changed a subsystem-B key-head mapping, so the change enters
at `R_Y`, which has no model and is omitted -- and every modelled seam
downstream is recomputed from each capture's OWN inputs, so both agree by
construction. It is the m3 blind spot again, wearing a different hat. Nothing
in this track establishes that the harness would notice an RTL change at a
modelled op that it was not itself built against; m1 and m2 establish only that
it notices one introduced deliberately.

---

## 9. What was NOT determined

- **Who owns `tools/ref9b/golden/llama_top_real.txt`, and whether it should be
  committed at all.** It is stale at HEAD as of `a77d181` (5.1), it goes stale
  on every `rtl/` commit that touches the real path, nothing gates on it, and
  its own header says it is a characterisation landmark rather than a claim.
  A committed artefact that silently rots is a trap laid for the next reader --
  it cost this track an hour and a wrong finding. The options are: regenerate
  it on a schedule, generate it in the gate rather than committing it, or
  delete it and keep only the landmark line. All three are decisions.

- **Whether `seam_map.SEAMS` should be generated from a shape.** The silent
  skip in 5.5 is real and measured; the fix is a design decision about a
  pre-existing shared file in a directory a concurrent track also claims, and
  it was left alone. Until it is fixed, ALWAYS pass `--check-names` to
  `capture_to_r9bs.py`.

- **Whether the three skipped `seq` seams are correct.** They are modelled by
  `ref_stream_scaled.py` and present in both streams; nothing compared them.

- **Anything about subsystem B's `R_Y` at integration level.** Three seams per
  token in `real` and `stub`, two in `seq`. m3 shows a live defect there is
  invisible to this harness AND to `tb_llama_top`'s own landmark.

- **Anything about `LOGITS`.** The lm_head job's destination is `R_NONE`, so
  the reference omits it in every configuration. The seam that decides a token
  is the one seam with no model on either side.

- **Whether the card's capture path works.** No hardware was touched and none
  could be. `capture_to_r9bs.py`'s text format is what a host driver would
  emit; nothing has emitted it yet.

- **Whether `--mode cross` behaves on these streams.** Only `--mode exact` was
  exercised; `cross` needs a float anchor at the scaled shape, which does not
  exist.

---

## 10. Reproducing all of it

```sh
# the three captures
for c in real stub seq; do
  bash tools/ref9b/capture_llama_top.sh $c /mnt/storage/ref9b-capture/llama_top_${c}_HEAD.txt
done

cd tools/ref9b
# ALWAYS --check-names.  It is the only thing that catches the seq silent skip.
python3 capture_to_r9bs.py /mnt/storage/ref9b-capture/llama_top_real_HEAD.txt \
    -o /mnt/storage/ref9b-capture/llama_top_real_HEAD.r9bs --check-names

# the reference side, at the shape the simulation runs
python3 ref_stream_scaled.py /mnt/storage/ref9b-capture/llama_top_real_HEAD.txt \
    -o /mnt/storage/ref9b-capture/ref_scaled_real_HEAD.r9bs \
    --blocks 4 --attn-int 4 --attn-hd 16 --norm real \
    --w-image ../../sim/llama_top_w_b4_pool.hex

python3 seam_bisect.py /mnt/storage/ref9b-capture/ref_scaled_real_HEAD.r9bs \
    /mnt/storage/ref9b-capture/llama_top_real_HEAD.r9bs --mode exact --tok 0

# the seq configuration, all three tokens, and the firing negative control
python3 ref_stream_scaled.py /mnt/storage/ref9b-capture/llama_top_seq_HEAD.txt \
    -o /mnt/storage/ref9b-capture/ref_scaled_seq_HEAD.r9bs --tok all \
    --blocks 4 --attn-int 2 --attn-hd 64 --kv-block 16 --n-rot 16 --norm anchor
# ... and again with --attn-fold shared, which must diverge at R_Y-1 on tok 1,2

# the teeth
MUTBASE=<a name nobody else is using> bash tools/ref9b/mutate_capture.sh all
```

The generics for each configuration are NOT free choices; they are copied from
the wrappers by `capture_llama_top.sh`, and `--norm` must match what the run
elaborated (`real` uses `NORM_REAL=true`; `stub` and `seq` take
`tb_llama_top`'s default `NORM_ANCHOR=true`). Guessing `--norm` wrong makes
every norm seam diverge, which looks exactly like a defect.
