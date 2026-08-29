# The `R_Y` coverage hole closed, and the `R_ER` exponent question settled

**Date:** 2026-08-29. Branch `fpga`. Track RY-ORACLE.
**Design under test:** repository commit **`c754e39`**, taken as a `git archive HEAD`
snapshot into a scratch tree. TRACK EGRESS is editing `rtl/llama_top.vhd` and
`sim/tb_llama_top_smp*.vhd` concurrently; every number below is against that
snapshot and none against the working tree. The snapshot reproduces
TRACK BISECT's published landmarks exactly (`R_X(0) = -16339 hash(R_X) = 92903`
at the `real` configuration, `-8060 / 28506` at `seq`), so the two documents
compare directly.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/`, nothing opening `/dev/xdma*`.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The questions, verbatim

From `docs/debugging/2026-08-29_first-bisect.md` section 8, and from this
track's brief:

> **PART 1 (PRIORITY): the R_Y coverage hole, measured not argued.**
> Four `R_Y` seams are emitted by the capture and **not compared**. That is the
> hole. **Build the integration-level model for `R_Y` so the value oracle
> reaches subsystem C's output, and show whether R7 then dies on the numbers
> rather than on a characterisation property.** ... **If it is impractical, say
> so plainly and say what partial coverage is honestly achievable.**

> **PART 2: a finding that may be a first-order correctness defect.** BISECT
> reported, DERIVED from captured exponents:
>
> > At the KV configuration, token 2, `R_ER-3` sits at exponent 0 against the
> > residual's -10, and a **7-LSB change in it leaves `R_X.attn-3`
> > bit-identical**. Subsystem C's entire contribution to the residual is
> > quantised away at that position.
>
> **Establish whether it generalises.** ... **So check the stimulus before
> concluding anything about the design**, and say which you established.

---

## 2. The answers, up front

**PART 1. The model is BUILT, it is EXACT, R7 dies on the numbers, and building
it found a defect in the shipping design that nothing in this repository could
previously see.**

`ref/attn_block_cap_vec.c` drives `ref/attn_block_vec.c`'s `attn_token()` from
the machine's own captured `R_QG`, `R_KIN` and `R_VIN`, with the KV cache at
token t reconstructed from what tokens 0..t-1 wrote from THEIR captured records.
It is practical for a reason worth stating plainly: **subsystem C's entire input
at the integration level is three captured regions plus two layer constants.**
Nothing has to be reproduced from inside the block.

Coverage moves, MEASURED by `tools/ref9b/bisect_scaled.py`:

| configuration | before (BISECT) | after | what is still not checked |
|---|---|---|---|
| `real` | 58 of 63 | **59 of 63** | 3 GDN `R_Y`, `LOGITS` |
| `seq`, each of 3 tokens | 55 of 60 | **57 of 60** | 2 GDN `R_Y`, `LOGITS` |
| `stub` | 58 of 63 | 58 of 63 | 3 GDN `R_Y`, `LOGITS`, and `R_Y-3` now
correctly named as the `-32768 + i` STUB rather than as an unmodelled seam |

**DEFECT C1, and it is a real one. `rtl/attn_block.vhd`'s `v_ref` fold has no
LAYER dimension, and the block's own header says it should.** `:422` declares

```vhdl
signal vref_r : e8_arr(0 to N_KVH-1) := (others => to_signed(127, EXP_W));
```

indexed by KV head alone, while `:111-112` states the requirement:

> `attn_kv_quant` folds the write-time minimum internally, but it has ONE fold
> register and **C spec 2.1.4 requires one per (layer, KV head)**. With a single
> shared quantizer instance its own `v_ref` output would mix the heads, so this
> block folds v_ref **PER HEAD** ...

The head mixing was fixed. The layer mixing was not. `rtl/llama_top.vhd`
instantiates ONE `attn_block` time-shared across `C_LAY = n_attn_blocks(SHAPE)`
attention layers, so from the second attention layer onward every layer folds
its `v_ref` into every other layer's. MEASURED, `tools/ref9b/attn_oracle.py` on
the clean `seq` capture:

```
                       spec (perlayer)          the machine (shared)
  v_ref after layer 0 token 0:  0  0            0  0
  v_ref after layer 1 token 0: -1 -1           -1 -1
  v_ref after layer 0 token 1:  0  0           -1 -1     <-- layer 1's minimum
  v_ref after layer 1 token 1: -1 -1           -1 -1
  v_ref after layer 0 token 2:  0  0           -1 -1
  v_ref after layer 1 token 2: -1 -1           -1 -1
```

and the consequence, on the clean design, against the SPEC model:

```
  R_Y-1  tok 1  exp 8 expected vs 8 captured, 82 of 256 mantissas differ,
                first at 12 (expected 9308, captured 9054)
  R_Y-1  tok 2  exp 8 expected vs 8 captured, 105 of 256 mantissas differ,
                first at 17 (expected 8103, captured 8089)
# 4 of 6 R_Y seams match the model bit for bit
```

The `shared` hypothesis, which is what the RTL does, is **bit-exact at 6 of 6**.
The oracle was NOT moved to accommodate the RTL: `perlayer` remains the default
and is what `bisect_scaled.py` reports against. `shared` exists so the report
can say what the design does instead of only that it disagrees, and selecting it
is documented in the tool's own help as hiding C1.

**Reachable at the real shape.** `C_LAY = 1` in the `real` configuration, which
is why it is clean there. At `BLOCKS = 32, ATTN_INT = 4` the model has **8
attention layers**, so C1 is live at the shape the design targets. MEASURED
that no bench could have caught it: `sim/tb_attn_block.vhd:412` hardwires
`layer => 0`, and `ref/attn_block_seq_vec.c` has no layer parameter at all.
`LAYERS` is a generic of `attn_block`, used only for `kv_layer`'s range and the
cache map, and never for `vref_r`.

**R7 IS KILLED ON THE NUMBERS.** MEASURED against the model the clean design
matches at 6 of 6:

```
=== R7 MUTANT, fold=shared ===
  R_Y-1  tok 1  exp 8 expected vs 8 captured, 82 of 256 mantissas differ,
                first at 12 (expected 9054, captured 9308)
# 5 of 6 R_Y seams match the model bit for bit
FIRST DIVERGENCE: R_Y-1 tok 1 at element 12 -- expected 9054, captured 9308
```

Clean scores 6 of 6, R7 scores 5 of 6, and the divergence is at the seam,
token and element the characterisation compare independently named. That is a
value-oracle kill, not a self-comparison. The bench still says
`RESULT: PASS ... R_X(0) = -8060 hash(R_X) = 28506`, byte-identical to clean.

**PART 2. The catastrophic form is a STIMULUS ARTEFACT. A bounded form is real,
and it is not specific to attention.** Both established by measurement.

The `seq` configuration passes **no weight image**, so `rtl/llama_top.vhd`'s
synthetic `wword` generator supplies every weight, and the residual stream runs
away by **1.06e6x in four blocks**. MEASURED, the same seam in three stimuli:

| stimulus | max&#124;R_X&#124; at embed | after block 0 | block 1 | block 2 | block 3 |
|---|---|---|---|---|---|
| `seq`, synthetic `wword` | 15.6 | 5.78e5 | 4.48e6 | 1.66e7 | 1.61e7 |
| `real`, pooled Qwen weights | 15.6 | 16.1 | 16.6 | 16.0 | 17.2 |
| 9B reference, real weights, 32 blocks | 0.351 | 7.68 | 11.5 | 19.8 | 18.1 (rising to ~60 by block 31) |

At the real 9B shape, MEASURED over **all 320 residual steps** (32 layers x 5
tokens x 2 branches) by the new `tools/ref9b/res_headroom.py`:

* **zero cases** where the whole vector is quantised away;
* dead bits **median 4, maximum 8** of 16, on BOTH branches;
* the FFN branch is affected identically to the attention branch (median D 8,
  max 256, on each), so this is a property of block-floating-point residual
  addition and **not** something attention does wrong.

So BISECT's specific claim -- "subsystem C's entire contribution to the residual
is quantised away at that position" -- is **withdrawn as a statement about the
design**. It is true of the `seq` configuration and true only there, and the
cause is the synthetic weight generator, exactly the direction this project was
burned in before (`docs/debugging/2026-08-28_...` PART 4, where a magnitude
blocker turned out to be the stimulus at rms row norm 2^4.87 against real
weights at 2^-0.03).

What survives is smaller and worth keeping: at the real shape the residual add
does discard a **median of 4 and a worst case of 8** of the 16 mantissa bits of
whichever subsystem is being added in. That is a precision floor, it is inherent
to a shared-exponent residual stream, and it applies to subsystem A's FFN output
just as much as to subsystem C's.

---

## 3. The procedure, in the order it was run

Each step controls for exactly one thing.

1. **Reproduce BISECT's two landmarks from a `git archive HEAD` snapshot before
   changing anything.** Controls for: measuring against another track's
   mid-edit, and for the possibility that `c754e39` had already moved the
   numbers away from `0da1912`. Both landmarks reproduced byte for byte.
2. **Answer PART 2 first, because it is pure analysis over captures the
   snapshot already produced.** Controls for: spending the run budget on the
   harder half and reporting the easier one from memory.
3. **Measure the residual's sensitivity rather than deriving it from two
   exponents.** For every `OP_VEC_RES` step, take the machine's own two
   operands and find, per element, the smallest delta to the second operand
   that moves the output. Controls for: `dead = sh - se` being an upper bound
   that round-half-up can undercut -- and it does, see trap T3.
4. **Cross-check the fast per-element scan against the full scalar model.**
   Controls for: the vectorised scan's assumption that `sh` does not move.
   `res_headroom.py --exact` and the fast path agree on every row of the `real`
   capture, differing only in the header line.
5. **Run the same measurement on the 9B whole-model reference.** Controls for:
   concluding anything about the design from a 4-block toy. This is the step
   that settles PART 2, and it is available only because TRACK REF9B built
   `/mnt/storage/ref9b/ref_bfp.r9bs` at the real shape with real weights.
6. **Read `ref/attn_block_vec.c`'s `attn_token()` signature before writing a
   line of driver.** Controls for: building a second oracle. Its inputs turned
   out to be exactly the three captured regions, which is why PART 1 is
   practical at all.
7. **Drive it from the capture, layer-major, with one cache and one `v_ref` per
   attention layer -- the SPEC.** Controls for: writing the model against the
   RTL. This is the step that failed on the clean design, which is the finding.
8. **Do not move the oracle. Form a hypothesis about what the RTL does instead
   and test it as a THIRD mode.** Controls for: a report that says only "they
   disagree". `shared` matching 6 of 6 is what turns a disagreement into a
   diagnosis.
9. **Read `rtl/attn_block.vhd` for `vref_r`'s declaration only after the
   hypothesis was confirmed from the numbers.** Controls for: finding the code
   you went looking for. The declaration and the header comment then confirmed
   the mechanism independently.
10. **Teeth-check three ways**: one LSB injected into the capture's `R_Y`; two
    UPSTREAM mutations that must NOT bite the R_Y model; one new COMPOSITION
    mutation that must. Controls for: a checker never shown to fail.
11. **Score R7 against all three folds.** Controls for: attributing a kill to
    the wrong cause.
12. **Full unfiltered gate.** Controls for: this track having broken something.

---

## 4. The evidence, as raw captured output

### 4.1 The snapshot reproduces BISECT's landmarks

```
$ SCRATCH=... bash tools/ref9b/capture_llama_top.sh real ...
tb_llama_top: seam capture wrote 63 records to cap.txt, capture/dump disagreements=0
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run,
  1 descriptor-latency points, R_X bit-identical across all of them,
  R_X(0) = -16339 hash(R_X) = 92903

$ ... capture_llama_top.sh seq ...
tb_llama_top RESULT: PASS -- 61 descriptors, 4 blocks, 3 tokens per run,
  ... R_X(0) = -8060 hash(R_X) = 28506
```

### 4.2 PART 2, the three stimuli

`tools/ref9b/res_headroom.py`, the `real` configuration (real pooled Qwen
weights), fast scan and `--exact` identical:

```
residual       tok src      e(X) e(ER)    sh  dead      ratio D=1 frac    D med    D max
R_X.attn-0     0   B/C         3    16     5     5      199.3     1/64         24       32
R_X-0          0   A(ffn)     11     6     1    -4      5.381    64/64          1        1
R_X.attn-1     0   B/C        10    16     6     6      398.9     1/64         64       64
R_X-1          0   A(ffn)     10     6     0    -4      8.131    64/64          1        1
R_X.attn-2     0   B/C        10    16     6     6      326.3     3/64         64       64
R_X-2          0   A(ffn)     10     6     0    -4      12.21    64/64          1        1
R_X.attn-3     0   B/C        10    12     2     2      11.58    14/64          4        4
R_X-3          0   A(ffn)     10     6     0    -4      12.75    64/64          1        1
# median-of-medians  B/C branch: 44   A(ffn) branch: 1
```

The `seq` configuration (no weight image, synthetic `wword`), which is where
BISECT's observation was made:

```
R_X.attn-1     0   B/C        -5     1    -5     6     6 5.776e+05 1.316e+04     0/64      64       64
R_X.attn-2     0   B/C        -8     4    -8    12    12 4.478e+06      1299     0/64    2048     4096
R_X.attn-2     1   B/C        -8     5    -8    13    13 6.191e+06     682.5     0/64    4096     8192
R_X.attn-3     2   B/C       -10     0   -10    10    10 2.777e+07 3.192e+04     0/64    1024     1024
```

The last row is BISECT's: `e(X) = -10`, `e(ER) = 0`, and **every one of the 64
elements needs a delta of 1024 before the output moves**, which is why a 7-LSB
change vanished. The claim was right about that configuration.

The residual magnitude, which is the actual cause:

```
== seq   (NO weight image: the synthetic wword generator) tok 0
   R_X.embed    exp=3    max|v|=15.625
   R_X-0        exp=-5   max|v|=577600
   R_X-1        exp=-8   max|v|=4.47821e+06
   R_X-2        exp=-9   max|v|=1.65775e+07
   R_X-3        exp=-9   max|v|=1.60804e+07
== real  (weight image llama_top_w_b4_pool.hex, REAL Qwen weights) tok 0
   R_X.embed    exp=3    max|v|=15.625
   R_X-0        exp=10   max|v|=16.1377
   R_X-1        exp=10   max|v|=16.6084
   R_X-2        exp=10   max|v|=15.9521
   R_X-3        exp=10   max|v|=17.2285
```

1.06e6x in four blocks against 1.10x in four blocks, same RTL, same schedule,
different weights.

### 4.3 PART 2 at the real 9B shape

`res_headroom.py /mnt/storage/ref9b/ref_bfp.r9bs --r9bs`, all 32 layers, all 5
tokens, 320 residual steps:

```
  B/C     n=160  D_med: min=1 median=8 max=256 | dead bits: median=4 max=8
                 | ratio median=11.14 max=183.0 | frac(D=1) median=0.069
     D_med histogram: {1:14, 2:17, 4:31, 8:43, 16:30, 24:1, 32:16, 64:6, 128:1, 256:1}
  A(ffn)  n=160  D_med: min=1 median=8 max=256 | dead bits: median=4 max=8
                 | ratio median=14.70 max=232.3 | frac(D=1) median=0.065
     D_med histogram: {1:11, 2:10, 3:1, 4:35, 8:37, 16:40, 24:3, 32:19, 64:3, 256:1}

total-annihilation cases (every element needs D >= 1024): 0
worst 6 rows:
   R_X.attn-4     tok 0 B/C     dead= 8 ratio=  183.0 D=1 in   16/4096  D_med=256
   R_X-13         tok 0 A(ffn)  dead= 8 ratio=  232.3 D=1 in   16/4096  D_med=256
   R_X.attn-16    tok 0 B/C     dead= 7 ratio=  179.8 D=1 in   35/4096  D_med=128
   R_X-1          tok 3 A(ffn)  dead= 6 ratio=   57.2 D=1 in   54/4096  D_med=64
   R_X.attn-4     tok 3 B/C     dead= 6 ratio=   76.9 D=1 in   74/4096  D_med=64
   R_X.attn-7     tok 3 B/C     dead= 6 ratio=   39.2 D=1 in   62/4096  D_med=64
```

Note the second-worst row is `R_X-13`, an **FFN** residual, at a worse ratio
than any attention row. Whatever this is, it is not about attention.

### 4.4 PART 1, the R_Y model on the clean design

`real` configuration, one attention layer:

```
# shape HEAD_DIM=16 N_QH=4 N_KVH=2 KV_BLOCK=4 N_ROT=8 attention blocks [3],
# 1 token(s), v_ref fold 'perlayer'
  ok           R_Y-3        tok 0
# 1 of 1 R_Y seams match the model bit for bit
```

`seq` configuration, two attention layers, three tokens, the three folds:

```
=== seq, fold=perlayer  (C spec 2.1.4)
  R_Y-1  tok 1  82 of 256 mantissas differ, first at 12 (expected 9308, captured 9054)
  R_Y-1  tok 2  105 of 256 mantissas differ, first at 17 (expected 8103, captured 8089)
# 4 of 6

=== seq, fold=shared    (one v_ref per KV head across every attention layer)
# 6 of 6 R_Y seams match the model bit for bit

=== seq, fold=pertoken  (mutation R7's scope)
  R_Y-1  tok 1  82 of 256 ...
  R_Y-1  tok 2  105 of 256 ...
  R_Y-3  tok 2  exp 9 expected vs 7 captured, 145 of 256 mantissas differ,
                first at 1 (expected 1689, captured -1443)
# 3 of 6
```

### 4.5 The coverage table, after

```
=== real, clean
# 59 seams checked against a model, 4 NOT checked
    NOT CHECKED  R_Y-0          subsystem B has no integration-level model
    NOT CHECKED  R_Y-1          subsystem B has no integration-level model
    NOT CHECKED  R_Y-2          subsystem B has no integration-level model
    NOT CHECKED  LOGITS         destination is R_NONE: the lm_head job discards its result (finding D1)
EVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT, given the machine's own inputs.

=== seq, clean, token 0
# 57 seams checked against a model, 3 NOT checked
    NOT CHECKED  R_Y-0 / R_Y-2 / LOGITS
EVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT

=== seq, clean, token 1        <-- defect C1
# 57 seams checked against a model, 3 NOT checked
  R_Y-1          exp 8 expected vs 8 captured, 82 of 256 mantissas differ,
                 first at 12 (expected 9308, captured 9054)
FIRST DIVERGENCE: R_Y-1 at element 12

=== stub
    NOT CHECKED  R_Y-3   this run elaborated the ATTENTION STUB, not attn_block:
                         R_Y is llama_top:3037's -32768 + i ramp, bit for bit
EVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT
```

### 4.6 The teeth check, four rows

| row | what | bench verdict | 58-seam oracle (before) | R_Y model (new) |
|---|---|---|---|---|
| **P1** | +1 LSB injected into the capture's `R_Y-3` element 7 | n/a | n/a | **KILLED**, `1 of 64 mantissas differ, first at 7 (expected -10589, captured -10588)` |
| **N2** | the real rmsnorm drops its last output element | PASS, hash moves | KILLED at `R_XN-0` element 63 | **DOES NOT BITE -- correct.** `1 of 1 R_Y seams match` |
| **VA1** | subsystem A truncates at spec 7.4 site 2, one LSB | PASS, `R_X(0)` unchanged | KILLED at `R_QKV.q-0` element 1 | **DOES NOT BITE -- correct.** `1 of 1 R_Y seams match` |
| **CY1** (new) | K and V transposed at `attn_block`'s input | **PASS**, `R_X(0) = -16226 hash 1794` | **DOES NOT BITE.** `EVERY MODELLED SEAM MATCHES` | **KILLED**, `R_Y-3 at element 0 -- 64 of 64 mantissas differ, expected 9530, captured 2092` |

N2 and VA1 not biting is the row that says the model takes the machine's own
inputs and therefore reports only seams whose OWN arithmetic is wrong, never the
storm downstream. CY1 is the row that says the model has teeth for exactly the
class `sim/tb_attn_block.vhd`'s seven structural properties cannot reach --
`ref/attn_block_vec.c`'s own header names "K and V transposed" first in its list
of wirings that pass every property while computing the wrong numbers.

**CY1 is a new mutation and it was invisible to everything in the repository
before today.** MEASURED, the full 59-seam bisect on the CY1 capture reports
exactly one divergence, and it is `R_Y-3`.

---

## 5. Measured and REJECTED -- do not retry

**Concluding anything about the design from the `seq` configuration's exponent
relationships.** MEASURED: that configuration has no weight image, its residual
grows 1.06e6x in four blocks, and every "the contribution is quantised away"
number comes from that growth. The same seam at the same RTL with the pooled
Qwen image grows 1.10x. Use `real`, or better the 9B reference, for any claim
about magnitudes. Do not retry the `seq` numbers as evidence about the design.

**Reading `dead = sh - se` as the number of bits actually lost.** MEASURED and
wrong in both directions. At `R_X.attn-0` of the `real` capture `dead = 5` and
yet one element of 64 still moves the output at a delta of 1 (round-half-up lets
a single LSB cross a rounding boundary); at `R_X-0` `dead = -4`, meaning the
second operand is on the COARSER grid and gains bits rather than losing them.
The per-element scan is the measurement; `dead` is a summary.

**Moving the `R_Y` oracle to the `shared` fold so the clean design passes.**
Rejected by discipline, and the discipline earned its keep: `perlayer` is the
default in both `attn_oracle.py` and `bisect_scaled.py`, and `--attn-fold
shared` documents in its own help text that selecting it hides C1. TRACK
C-ORACLE's entire value came from not touching the oracle when 64 of 64
mantissas disagreed.

**Building an integration-level model for subsystem B's `R_Y`.** Not attempted,
and the reason is structural rather than budgetary: `rtl/gdn_block.vhd`'s input
is `R_QKV` plus a RECURRENT STATE, and no region holds that state, so the
capture cannot see it. Subsystem C was reachable precisely because it has no
state outside the KV cache, and the KV cache is reconstructible from earlier
tokens' captured `R_KIN`/`R_VIN`. The same argument does not transfer. Three of
the four `R_Y` seams therefore remain NOT CHECKED at the `real` shape and this
document does not claim otherwise.

**A `bisect_scaled.py` gate row in `sim/regress.sh`.** DECLINED, and for a
sharper reason than BISECT's. BISECT declined because a non-VHDL row in a shared
file with several tracks live is risky. That is still true -- `BASELINE_PASS` has
moved to 85 and moved twice today -- but the decisive reason is now that **the
row would be RED on the day it landed**, because the `seq` configuration has
defect C1 and the row's job is to detect it. A permanently red row stops being
read, which is exactly the failure mode BISECT rejected a committed golden for.
The row becomes worth adding when C1 is resolved; not before.

**Guessing whether a run elaborated the attention stub from a command-line
flag.** Rejected in favour of detecting it from the capture. `--norm` guessed
wrong once and made eight norm seams look defective (BISECT's trap T5); the
stub's `R_Y` is `llama_top:3037`'s `-32768 + (i mod 4096)` exactly, so
`bisect_scaled.py` recognises it and reports it under its own name rather than
comparing attention against a ramp.

---

## 6. Measurement traps hit, including my own

**T1. My own oracle's first result looked like my own bug, and it was not.**
The first `perlayer` run reported `R_Y-1 tok 1 element 12, 82 of 256 mantissas
differ` -- **the identical seam, token, element and count that BISECT's
characterisation compare reports for the R7 MUTANT**. The obvious reading is
that my driver had reproduced R7's behaviour. It had not; the coincidence is
real and has a cause, which is that C1 and R7 both perturb the same `v_ref` in
the same direction at the same first opportunity. What separated them was
running the hypothesis as a third mode: `shared` matches the clean design at
6 of 6, `pertoken` does not match either. **A matching fingerprint between your
own new tool and a known mutant is not proof your tool is the mutant.**

**T2. `pertoken` is NOT a model of R7 and must not be used to score it.** R7
asserts `c_seqrst` on `tok_done_i`, so the reset fires once BETWEEN tokens, not
once per (layer, token). The `pertoken` mode resets before every `attn_token`
call. They differ whenever `NLAY > 1`, and MEASURED they do: the R7 capture
scores 4 of 6 against `pertoken` and 5 of 6 against `shared`. `pertoken` is in
the tool to make the three-way comparison legible, not to score R7.

**T3. A naive "count of clean seams" scorer calls R7 an IMPROVEMENT.** MEASURED
against the SPEC fold: the clean design scores 4 of 6 and the R7 mutant scores
5 of 6, because R7's per-token reset happens to undo C1's cross-layer carry at
token 1. Any mutation harness that ranked by clean-seam count would have scored
this mutant as better than the design. The kill has to be "the mutant differs
from the model the clean design matches", not "the mutant scores worse".

**T4. The fast per-element scan holds `sh` fixed and that is an assumption.**
`res_headroom.py`'s vectorised scan computes the output shift once from the
unperturbed vector. It is exact for any delta too small to move the vector's
maximum, which is every delta that matters here, but it is an assumption and it
is why `--exact` exists. MEASURED: fast and exact agree on every row of the
`real` capture, differing only in the header line.

**T5. `--norm mean` on the `stub` capture makes every norm seam diverge.** Hit
on my first stub run: `R_XN-0 exp 3 expected vs 12 captured, 64 of 64 mantissas
differ`. That is BISECT's trap T5 in a new coat -- the `stub` configuration
elaborates `NORM_ANCHOR`, not the bare mean-removal stand-in. The tell is the
same one BISECT recorded: a whole vector moving together with the exponent is a
parameter mistake, not a defect.

**T6. Not a trap I hit, but the one this document is most exposed to.** The
`shared` fold matching 6 of 6 is strong evidence that C1 is the ONLY thing
separating the RTL from the model, but it is evidence at ONE shape with TWO
attention layers and THREE tokens. A second, independent line supports it -- the
R7 mutant's divergence under `shared` lands at the seam, token and element that
BISECT's characterisation compare found by an entirely different method -- but
neither is a proof about eight attention layers.

---

## 7. NOT verified

* **Subsystem B's three `R_Y` seams.** Still no integration-level model, and
  section 5 states why the approach that worked for C does not transfer.
* **`LOGITS`.** Unchanged. TRACK EGRESS is closing it; nothing here bears on it.
* **The MAGNITUDE of C1 at the real shape.** MEASURED, `v_ref` moves 0 to -1 at
  two attention layers, which is one bit of V precision at one layer. ESTIMATE,
  and it is only that: with 8 attention layers the shared fold takes the
  minimum over 8 layers' V exponents, so the loss could be several bits at every
  layer. Nothing here measures that, because no GHDL configuration in the
  repository runs 8 attention layers.
* **Whether C1 can produce a WRONG answer rather than a less precise one.** The
  invariant `e_v[b] >= v_ref` that the site-3 shift depends on still holds --
  more strongly, since a smaller `v_ref` only makes the right shift larger -- so
  no wrap or sign error is expected. Not proven, only argued.
* **The per-site fixed-point numerics inside subsystem C.** `attn_block_vec.c`'s
  own header declares these shared with the RTL. This model checks the
  COMPOSITION and, new here, the cache across tokens.
* **Anything at the 9B shape in GHDL.** Unchanged from BISECT: about 15 days per
  token, and blocked independently by the region file. The 9B numbers in this
  document come from the software reference, never from a simulation.
* **The `R_ER` question at more than 5 tokens or outside greedy decode.** The
  9B reference covers 5 tokens of one prompt.
* **RoPE.** Unchanged. Nothing here bears on it.
* **Whether the clean numbers are RIGHT at the three unmodelled GDN `R_Y`
  seams.** A wrong value there is still passed forward AS GIVEN, and every
  later comparison still passes. 59 of 63 is a statement about 59 seams.

---

## 8. Files

| file | what |
|---|---|
| `ref/attn_block_cap_vec.c` | subsystem C's block oracle driven from a capture, with the three `v_ref` folds as an explicit choice |
| `tools/ref9b/attn_oracle.py` | the capture reader, the stimulus writer, the `v_ref` trace and the bit-for-bit compare |
| `tools/ref9b/res_headroom.py` | how much of the residual's second operand survives the add, per element, on a GHDL capture or an `.r9bs` stream |
| `tools/ref9b/bisect_scaled.py` | now 59 of 63 (`real`) and 57 of 60 (`seq`), plus stub detection |

---

## 9. Corrections

**2026-08-29, appended to `docs/debugging/2026-08-29_first-bisect.md` section
5.6 by this document.** That section's DERIVED claim --

> `seq_vec_res` aligns to the finer grid ... A change of 7 LSBs in `R_ER-3` is
> therefore right-shifted by 11 and vanishes. **At this position, subsystem C's
> entire contribution to the residual is quantised away.**

-- is **WITHDRAWN as a statement about the design and retained as a statement
about the `seq` configuration.** MEASURED: the effect is caused by that
configuration's synthetic `wword` weights, which grow the residual 1.06e6x in
four blocks; with real weights the same four blocks grow it 1.10x, and at the
real 9B shape over 320 residual steps there are zero total-annihilation cases
and the median loss is 4 of 16 bits. BISECT's arithmetic was correct; its scope
was not, and it labelled the claim DERIVED rather than MEASURED, which is what
made the scope error findable.

**2026-08-29, appended.** BISECT section 8 lists the four `R_Y` seams as "the
largest remaining gap". Two of them (`R_Y-3` at `real`, `R_Y-1` and `R_Y-3` at
`seq`) are now modelled. The remaining gap is subsystem B's, and it is
structurally harder, not merely unbuilt.

---

## 10. CORRECTION, same day, appended: R7's detectability RUNS THROUGH C1

Written after section 2 and not folded into it, because section 2's claim was
already reported and the correction narrows it rather than reversing it.

**What was tested.** A candidate fix for C1 was applied to a SCRATCH copy only
-- `rtl/attn_block.vhd` is not modified in the repository and this track changed
no RTL. The fix gives `vref_r` the missing dimension, five sites:

```vhdl
-- :421 already says "the per-(layer, KV head) write-time min fold (SEAM 2)"
-  signal vref_r : e8_arr(0 to N_KVH-1)        := (others => to_signed(127, EXP_W));
+  signal vref_r : e8_arr(0 to LAYERS*N_KVH-1) := (others => to_signed(127, EXP_W));
   :943   vref_r(kvh)  ->  vref_r(lay_r*N_KVH + kvh)
   :1305  vref_r(kvh)  ->  vref_r(lay_r*N_KVH + kvh)
   :1309  vref_r(kvh)  ->  vref_r(lay_r*N_KVH + kvh)
   :1609  vref_r(h)    ->  vref_r(lay_r*N_KVH + h)
```

**Result 1, and it settles C1.** MEASURED, the fixed design against the SPEC
fold:

```
=== C1-FIXED clean, fold=perlayer
# 6 of 6 R_Y seams match the model bit for bit
EVERY MODELLED R_Y MATCHES ITS MODEL BIT FOR BIT
```

Six of six against the model the unfixed design failed at two. **C1 is the only
divergence between `rtl/attn_block.vhd` and `ref/attn_block_vec.c` at this
shape**, which is a much stronger statement than "the shared fold happens to
match". It also changes the design's published numbers --
`R_X(0) = -8079 hash(R_X) = 41907` against the unfixed `-8060 / 28506` -- so the
fix is a behaviour change and a decision for whoever owns subsystem C, not
something to slip in.

**Result 2, and it corrects section 2.** MEASURED, the R7 mutant applied ON TOP
of the C1 fix:

```
$ cmp cap_seq_C1FIX.txt cap_seq_C1FIX_R7.txt
IDENTICAL
```

**Byte-identical captures. With C1 fixed, R7 is a bit-exact no-op at this
stimulus**, and the R_Y oracle scores it 6 of 6 exactly like the clean design.

The reason is visible in the `v_ref` trace: with a per-layer fold, each layer's
minimum is reached at token 0 and never moves again (layer 0 stays `0 0`, layer
1 stays `-1 -1` across all three tokens), so resetting it per token re-folds to
the same value. R7 only becomes observable because C1's cross-layer carry gives
it something to disturb.

**So the corrected claim is:**

* R7 IS killed on the numbers, by the R_Y value oracle, against the design as it
  stands today (clean 6 of 6, R7 5 of 6, divergence named at `R_Y-1` token 1
  element 12). Section 2 stands as a statement about the current design.
* R7 is **NOT** killed by this oracle on a design with C1 fixed, at this
  stimulus. Killing it there needs a stimulus where some later token's V records
  carry a HIGHER per-block minimum than an earlier token's, so that a per-token
  reset raises `v_ref` where a per-sequence fold would have held it down.
  Nothing in the repository generates such a stimulus today, and
  `sim/tb_llama_top.vhd`'s `seq` row does not.
* The two defects are therefore ENTANGLED, and a fix for C1 that lands without a
  new stimulus would silently return R7 to the unkillable list.

**The measurement trap this is, named.** A mutation that is killed only because
of another defect looks exactly like a mutation that is killed. The tell was
cheap and general: apply the candidate fix and re-run the mutant. That step is
worth making routine, because "the harness now kills X" and "the harness kills X
on a correct design" are different claims and only the second is the one anyone
wants.

---

## 11. Appended: C1's magnitude at the real shape is 4 to 5 bits, not one

Section 7 listed "the MAGNITUDE of C1 at the real shape" as NOT verified, on the
grounds that the only measurement available was `v_ref` moving 0 to -1 across
two attention layers in a toy. A better-anchored number is available from the 9B
reference and it is much larger.

MEASURED, `/mnt/storage/ref9b/ref_bfp.r9bs`, the exponent of `R_VIN` at each of
the **8** attention layers (blocks 3, 7, 11, 15, 19, 23, 27, 31 -- confirmed by
enumerating which blocks emit `R_QG`):

```
  tok 0: L3:12 L7:10 L11:9  L15:9  L19:9  L23:9  L27:8 L31:9    min=8 max=12 spread=4
  tok 1: L3:13 L7:13 L11:12 L15:12 L19:12 L23:11 L27:8 L31:10   min=8 max=13 spread=5
  tok 2: L3:13 L7:12 L11:12 L15:12 L19:11 L23:11 L27:8 L31:10   min=8 max=13 spread=5
  tok 3: L3:12 L7:12 L11:12 L15:12 L19:11 L23:11 L27:8 L31:10   min=8 max=12 spread=4
  tok 4: L3:13 L7:13 L11:12 L15:12 L19:12 L23:11 L27:8 L31:10   min=8 max=13 spread=5
```

**DERIVED.** A shared fold collapses all eight layers onto the global minimum,
which is layer 27's at exponent 8 at every token. Layer 3 sits at 12 or 13. Site
3's alignment is `v_aligned = v_mant asr (e_v[b] - v_ref)`, so the shallow
attention layers would run with a `v_ref` **4 to 5 bits below their own**, and
that is 4 to 5 extra bits of right shift on every V block they read -- of 8, at
`CM_W = 8`.

**The caveat, stated rather than buried.** `v_ref` is the minimum over
`attn_kv_quant`'s per-KV-BLOCK exponents, not over `R_VIN`'s vector exponent, so
the numbers above are a PROXY for the quantity C1 actually collapses. They fix
the order of magnitude and the sign; they are not the fold itself. The toy's one
bit was measured at two layers with a synthetic stimulus, and it is the number
that should be discarded as unrepresentative, not this one.

This moves C1 from "a precision regression of unmeasured size" to "a plausible
loss of half the V mantissa at the shallow attention layers", which is the
difference between a cleanup and a priority. It is still not a proof: no GHDL
configuration in this repository runs eight attention layers, and the
`--attn-fold shared` model would have to be driven at that shape to settle it.

---

## 12. Appended: why C1 cannot be simulated at more than two attention layers

Section 11's number is a proxy because no GHDL configuration runs the eight
attention layers the real shape has. That is not an oversight of this track; it
is a hard stop in the bench, and naming it is more useful than repeating the
caveat.

MEASURED. Running the `seq` row at `BLOCKS = 8, ATTN_INT = 2`, which is four
attention layers rather than two, and changing nothing else:

```
rtl/llama_top.vhd:3409:7:@0ms:(assertion failure):
  llama_top: the K and V KV regions overlap.  Each is 5120 bytes.
/usr/bin/ghdl-mcode:error: simulation failed
in process .tb_llama_top(tb).dut@llama_top(rtl).gcr.gkvaxi.P3
```

`sim/tb_llama_top.vhd:802-803` fixes the two region bases as **constants**, not
generics:

```vhdl
constant KV_K_BASE : natural := 16;
constant KV_V_BASE : natural := 4064;
```

4048 bytes apart, which fits two attention layers at
`C_LAY*C_NKVH*C_MAXPOS*REC_B` and not four. The elaboration assert at
`llama_top.vhd:3409` catches it correctly and loudly, which is the right
behaviour and the reason this took one run to find rather than producing a
plausible wrong answer.

**So the honest position on C1's magnitude is:** the mechanism is proven, the
direction is proven, the cross-layer exponent spread at the real shape is
MEASURED at 4 to 5, and the end-to-end number is not obtainable in this
repository until those two constants become generics. That change belongs to
whoever owns `sim/tb_llama_top.vhd`; this track did not make it, having been
asked not to touch that file.

---

## 13. Appended to section 6: trap T7, and it is worse than T5

**T7. `--kv-block` and `--n-rot` are not recorded in the capture, and a wrong
LEGAL value produces a small wrong answer rather than an error.** MEASURED,
`attn_oracle.py` on the `real` capture, which was elaborated at `KV_BLOCK = 4`:

```
$ ... --attn-hd 32 ...          # wrong head dim
attn_oracle: the oracle refused the stimulus
attn_block_cap_vec: illegal shape HEAD_DIM=32 N_QH=2 N_KVH=1 KV_BLOCK=4 ...

$ ... --kv-block 8 ...          # wrong block, but a LEGAL shape
  R_Y-3  tok 0  exp 14 expected vs 14 captured, 5 of 64 mantissas differ,
                first at 7 (expected -10588, captured -10589)
```

The first is caught, because the element counts stop matching and the shape
assert refuses. **The second is not**, and its signature -- five mantissas of
sixty-four, every delta exactly 1 -- is indistinguishable from a real one-LSB
rounding defect, which is precisely what mutation VA1 looks like.

This is a sharper version of BISECT's T5. There, a wrong `--norm` moved a whole
vector together with its exponent, which is a recognisable parameter-mistake
signature. Here there is no signature at all. The mitigation is procedural and
it is now in the tool's own help text: take `--kv-block` and `--n-rot` from the
run's generics, never from the defaults. `bisect_scaled.py` inherits the same
hazard and the same defaults.
