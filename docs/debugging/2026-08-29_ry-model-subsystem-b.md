# Subsystem B's `R_Y` has a model, the seam gate reaches 64 of 64, and the thing it still cannot see is named

**Date:** 2026-08-29. Branch `fpga`. Track RY-MODEL.
**Design under test:** repository commit **`9ad4c14`**, taken as a `git archive`
snapshot into `/mnt/storage/rymodel2`. Every number below is against that
snapshot and none against the working tree. HEAD moved several times during
this track; the provenance trap that caused is recorded in section 7.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/`, nothing opening `/dev/xdma*`.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

From this track's brief:

> **Your job: model `R_Y` so the seam comparison covers subsystem B.**
>
> - TRACK CAPTURE injected a `gdn_silu` truncation (`m3`) that **moved six
>   seams and survived**, because `R_Y` has no model AND the residual's
>   alignment discards exactly the bits it moved [...]
> - TRACK OI3B later killed that same mutation with a new `EXP_STEPH`
>   landmark, but a landmark is a change detector, not an oracle: it says a
>   number moved, not which seam is wrong.
>
> **Teeth-check by construction.** The specific target: CAPTURE's `m3` /
> SEAMGATE's `S4`, the `gdn_silu` EMIT truncation that the seam gate currently
> CANNOT see. If your `R_Y` model is right, that mutation should fail the seam
> comparison and name the seam.

---

## 2. The answers, up front

**The model is BUILT, it is BIT-EXACT on the first run at all three gate
configurations, and S4 now dies on the numbers and names the seam.**

MEASURED, `bash tools/ref9b/mutate_seamgate.sh S4` on the mutated tree:

```
SEAMGATE FAIL (DIVERGENCE) -- real token 0: a modelled seam does not
    FIRST DIVERGENCE: R_Y-0 at element 0 -- expected -8, captured -6 (exponent 18 vs 18, 60 of 128 mantissas differ)
```

against that same row's previous verdict of `SEAMGATE PASS`. The landmark row
also fails it, and the difference is the point: `EXP_STEPH` says a number moved,
this says **`R_Y-0`, element 0, 60 of 128**.

**The seam gate's floors rise from 61/60/59 to 64/63/61**, and on `real` and
`seq` there is now **no unmodelled seam at all**. MEASURED,
`bash tools/ref9b/seamgate.sh <cfg>`:

| cfg | tokens | seams present | checked before | checked now | still not checked |
|---|---|---|---|---|---|
| `real` | 1 | 64 | 61 | **64** | -- nothing -- |
| `stub` | 1 | 64 | 60 | **63** | `R_Y-3`, the attention ramp stub |
| `seq` | 3 | 61/tok | 59 | **61** | -- nothing -- |

**WHY IT WAS POSSIBLE, AND THIS IS THE WHOLE FINDING.** Two documents in this
repository state that subsystem B is unreachable from a capture:

> Subsystem B's is not reachable the same way: its input includes a recurrent
> state no region holds. -- `tools/ref9b/bisect_scaled.py`, header
> `R_Y-0`, `R_Y-1`, `R_Y-2` at a GDN block come from `rtl/gdn_block.vhd`, whose
> input is `R_QKV` plus a RECURRENT STATE that no region holds and the capture
> cannot see. -- `tools/ref9b/attn_oracle.py`, header

That is true of **subsystem B** and false of **this top level**. MEASURED by
reading `rtl/llama_top.vhd` at `9ad4c14`:

* `:3270` -- `b_tk0 <= '1';   -- one token only; there is no token loop yet`.
  Driven unconditionally, at every token. `rtl/gdn_recur_pipe.vhd`'s TK0_ED
  masks the state read at `tk0`, so the recurrent state is **written and never
  read** and cannot influence `R_Y`.
* `:4048` -- `b_seq_rst <= '1'` once per TOKEN, which resets every
  `gdn_exp_capture` counter (`rtl/gdn_exp_capture.vhd:176`). Exactly one
  capture per (layer, segment) has happened by the time B starts, so `tvalid`
  marks **only tap `KCONV-1`** valid. The conv has no history either.

So `R_Y` at a GDN block is a pure function of one token's inputs, and every one
of those inputs is either a captured region or a deterministic function of an
index. **The obstacle was never subsystem B; it was a sentence about subsystem
B that nobody re-checked against the top level that instantiates it.**

**AND THAT IS ALSO THE HONEST LIMIT, so read the next number before the
previous one.** MEASURED with two purpose-built mutations (S10, S11): the
entire recurrent-state path is invisible to this gate, because the top level
discards that state every token. **No model can fix that. Only a top level that
drives `tk0` low can.** Section 5 states it as a defect candidate.

---

## 3. The procedure, in the order it was run

Each step is named with what it isolates.

1. **Read the seam framework before writing anything** --
   `tools/ref9b/{seam_map,scaled_plan,bisect_scaled,ref_stream_scaled,seamgate}`
   and `tools/ref9b/attn_oracle.py` + `ref/attn_block_cap_vec.c`, which are the
   working precedent on the C side. *Isolates: whether the cheap path exists.
   It did -- subsystem C's driver is a template, and the split it uses (bench
   constants in Python, arithmetic in C) is the one to copy.*
2. **Read `rtl/llama_top.vhd`'s unit-B adapter, not the spec.** `gb_real` at
   `:2764-3300`. *Isolates: what subsystem B is actually fed at the top level,
   as opposed to what subsystem B takes. This is the step that produced the
   whole finding; every prior document had reasoned from B's own port list.*
3. **Enumerate every input and classify it** as captured region, captured
   exponent, or bench constant. Result in section 4. *Isolates: how much of
   `R_Y` a comparison can actually be coupled to -- which is the number section
   6 measures rather than assumes.*
4. **Guard `ref/gdn_block_vec.c`'s `main` and INCLUDE it**, rather than
   transcribing `gdn_block_token()`. *Isolates: the `m7 mutant` failure mode.
   Two copies of an oracle drift and the drift is invisible because they are
   never compared. `ref/attn_block_cap_vec.c` set this precedent and states the
   same reason.*
5. **Write `tools/ref9b/gdn_oracle.py` with the `m12` transcription in it**, and
   `ref/gdn_block_cap_vec.c` with no RTL constant at all. *Isolates: a bench
   constant changing under the model. Same split as `attn_oracle.qkn_const`.*
6. **Run it against a fresh capture before wiring it into anything.** Bit-exact,
   3 of 3, first run. *Isolates: whether the transcription is right. It is a
   JOINT check -- a wrong `m12`, a wrong `B_CONV_LANES`, a wrong `cw_exp`, a
   wrong scalar order, or the wrong key-head map would each have produced a
   divergence, and section 6's negative controls show what each looks like.*
7. **Wire into `bisect_scaled.py` and `ref_stream_scaled.py`, raise the floors
   in `seamgate.sh`.**
8. **Teeth: run the named target S4, then five new B-side mutations** designed
   so that two of them are **expected to survive**. *Isolates: the gate's
   resolution floor. A table with no survivors has not measured its floor, it
   has only listed its successes.*
9. **Coverage of the INPUT space, measured rather than argued** (section 6):
   perturb each captured input in the capture file and count how many `R_Y`
   mantissas move.

---

## 4. What subsystem B is fed at the top level

MEASURED by reading `rtl/llama_top.vhd` at `9ad4c14`. Line numbers are that
file's.

| input | source | comes from the capture? |
|---|---|---|
| `z_mant`, `z_exp` | region `R_Z` (`:3231-3248`) | **YES**, mantissas and exponent |
| `cap_exp` per segment | `qkv_exp(seg)` (`:3102`, set at `:4061`) | **YES**, the three `R_QKV` exponents |
| conv taps `cv_x` | `m12(seg*104729 + grp*31, t*17 + ln)` (`:3016`) | no, unless `B_SRC_REAL` |
| conv weights `cv_w` | `m12(seg*65537 + grp*13, t*101 + ln + 5)` (`:2985`) | no, learned weight |
| `cv_cw_exp` | `12 + cv_seg` (`:3044`) | no |
| `sc_al_m`, `sc_b_m` | `m12(h*31+1, 2)`, `m12(h*31+4, 5)` (`:3075`) | no, unless `B_SRC_REAL` |
| `sc_dt_m`, `sc_a_m` | `m12(h*31+2, 3)`, `-abs(m12(h*31+3, 4))` (`:3062`) | no, learned weight |
| `w_mant` (ssm_norm) | `m12(4242, j)` (`:3088`) | no, learned weight |
| `tk0` | hardwired `'1'` (`:3270`) | no |
| `tvalid` | one capture per token, so only tap `KCONV-1` | no |
| recurrent state | per-layer memory, **never read** at `tk0` | not needed |

`B_SRC_REAL` defaults **false** (`:248`) and **none of the three
`capture_llama_top.sh` configurations sets it** -- MEASURED by reading the `G`
strings in that script. So the mantissas of `R_QKV`, `R_ALPHA` and `R_BETA`
reach subsystem B in **no** gate configuration today.

---

## 5. Defect candidate B-TOP-1: the top level is not a recurrence, and its own comment's premise has expired

`rtl/llama_top.vhd:3270` reads:

```vhdl
              b_tk0   <= '1';   -- one token only; there is no token loop yet
```

and `:2757-2761` justifies the conv side the same way: "so at `tk0` -- which is
all this file has, **there being no token loop** -- only tap KCONV-1 is ever
summed."

**There is a token loop.** `sim/tb_llama_top_seq.vhd` runs `NTOK=3`, it is a
gate row (`sim:seamgate_seq`, `sim:tb_llama_top_seq`), and it ran three tokens
in this track's own measurements. So at tokens 1 and 2 the design computes
subsystem B **as if it were token 0**: the state is discarded and the conv
history is masked away.

The behaviour is *declared* at both sites, which is why this is a defect
candidate and not a defect: it is a stated stand-in. What has expired is the
**reason** given for it, and a stand-in whose justification is false is one
nobody will re-examine.

**The size of it, MEASURED.** `tools/ref9b/gdn_oracle.py --tk0 seq` models B
spec 2.1.4's recurrence (state carried across tokens) instead of what the RTL
does, on the same `seq` capture:

```
  R_Y-0        tok 1  exp 10 expected vs 10 captured, 75 of 128 mantissas differ, first at 0 (expected -226, captured -229)
  R_Y-2        tok 1  exp 9 expected vs 9 captured, 62 of 128 mantissas differ, first at 0 (expected -8521, captured -8077)
  R_Y-0        tok 2  exp 10 expected vs 10 captured, 75 of 128 mantissas differ, first at 0 (expected -3572, captured -3345)
  R_Y-2        tok 2  exp 8 expected vs 8 captured, 60 of 128 mantissas differ, first at 4 (expected -6890, captured -6955)
# 2 of 6 R_Y seams match the model bit for bit
```

Token 0 matches under both; tokens 1 and 2 move **60 to 75 of 128 mantissas per
seam**. That is what the missing recurrence costs at the scaled shape.

**The default is `--tk0 top`, which models the RTL and not the spec, and that
choice is named rather than hidden.** It is the same shape as
`attn_oracle.py`'s `--fold shared` and carries the same warning: a model that
only implemented the spec could say the RTL disagrees and could not say what the
RTL does instead.

---

## 6. The evidence

### 6.1 The model, unmutated, at all three configurations

MEASURED, `python3 tools/ref9b/bisect_scaled.py <cap> $(LIST_BISECT=1 ...)`:

```
# stepwise oracle, token 0, shape blocks=4 attn_interval=4 attn_hd=16 hidden=64 ffn=128
# 64 seams checked against a model, 0 NOT checked
EVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT, given the machine's own inputs.

# stepwise oracle, token 0, shape blocks=4 attn_interval=4 attn_hd=32 hidden=64 ffn=128
# 63 seams checked against a model, 1 NOT checked
    NOT CHECKED  R_Y-3          this run elaborated the ATTENTION STUB, not attn_block: R_Y is llama_top:3037's -32768 + i ramp, bit for bit

# stepwise oracle, token 0/1/2, shape blocks=4 attn_interval=2 attn_hd=64 hidden=64 ffn=128
# 61 seams checked against a model, 0 NOT checked      (all three tokens)
```

and the gate itself, `bash tools/ref9b/seamgate.sh {real,stub,seq}`, all
`SEAMGATE PASS` at floors 64 / 63 / 61.

`tools/ref9b/ref_stream_scaled.py` now emits the B seams too: **64 seams
modelled, 1 omitted** (`R_X.embed`, the bench's own input), and
`seam_bisect.py --mode exact` against the capture reports `64 seams identical,
0 differ`.

### 6.2 The mutation table

MEASURED, `bash tools/ref9b/mutate_seamgate.sh <row>` at `9ad4c14` plus this
track's changes. Rows S8-S12 are new.

| row | mutation | expected | MEASURED |
|---|---|---|---|
| S1 | `seq_vec_res` rounding bias deleted | FAIL | **FAIL (DIVERGENCE)** |
| S2 | `seq_vec_res` shift floor 0 -> 1 | FAIL | **FAIL (DIVERGENCE)** |
| S3 | argmax inverted | FAIL at TOKEN | **FAIL** |
| S4 | **`gdn_silu` emit truncates** | previously SURVIVED | **FAIL, `R_Y-0` elem 0, 60/128** |
| S5 | `--no-a` / `--no-b`, coverage teeth | below the floor | **`--no-a` 25 of 64, `--no-b` 61 of 64, both fire** |
| S6 | `--blocks 8`, plan drift | rc 2 | **rc 2** |
| S7 | S1 with the landmarks re-pinned | landmark PASS, gate FAIL | **landmark PASS (0 moved), gate FAIL** |
| S8 | key-head map back to `h/(VH/KH)` (**defect B-BLK-1 restored**) | FAIL | **FAIL, `R_Y-0` elem 32, 64/128** |
| S9 | `gdn_conv` segment requantizer truncates | FAIL | **FAIL, `R_Y-0` elem 4, 33/128** |
| S10 | `gdn_recur_pipe` decay rounding bias deleted | **SURVIVE** | **PASS, 64 seams, 0 not checked** |
| S11 | layer term dropped from `llama_top`'s B state address (**the 2d10f76 defect restored**) | **SURVIVE** | **PASS, 64 seams, 0 not checked** |
| S12 | `gdn_recur_pipe` stage-4 `k*delta` shift +1 | FAIL | **FAIL, `R_Y-0` elem 2, 100/128, exp 18 vs 19** |

Raw, S4 and S8:

```
===================== S4 =====================
-- the landmark row on this mutant:
    tb_llama_top: P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL => 91622, EXP_STEPH => 34846   (1 of the pinned landmarks moved)
    tb_llama_top RESULT: FAIL
-- the seam gate on this mutant:
SEAMGATE FAIL (DIVERGENCE) -- real token 0: a modelled seam does not
    FIRST DIVERGENCE: R_Y-0 at element 0 -- expected -8, captured -6 (exponent 18 vs 18, 60 of 128 mantissas differ)
  [gate rc=1]

===================== S8 =====================
SEAMGATE FAIL (DIVERGENCE) -- real token 0: a modelled seam does not
    FIRST DIVERGENCE: R_Y-0 at element 32 -- expected -191, captured 208 (exponent 18 vs 18, 64 of 128 mantissas differ)
  [gate rc=1]
```

**S8 is the important one after S4.** Defect B-BLK-1 -- value head `h` fed by
key head `h/(VAL_HEADS/KEY_HEADS)` instead of `h mod KEY_HEADS` -- was found by
a unit-level oracle (`ref/gdn_block_vec.c`) and fixed at `a77d181`. Restoring it
now fails the **integration** gate, at exactly `64 of 128` mantissas, which is
DERIVED: at `KEY_HEADS=2, VAL_HEADS=4`, `mod` gives `0,1,0,1` and `div` gives
`0,0,1,1`, so heads 1 and 2 differ, `2 * 32 = 64` elements.

**S5's `--no-b` is the narrowest coverage test the floor has to survive.** It
stops comparing subsystem B's three `R_Y` seams and nothing else, leaving
**61** -- which is exactly the OLD floor. A floor left at 61 would have accepted
the loss of the very seams this track added. That is why the floor was raised in
the same change and not left for later.

**S7 still stands after this landing**, MEASURED: with S1's mutant and the four
landmarks re-pinned to the values that mutant itself prints, the landmark row
reports `0 of the pinned landmarks moved` and the seam gate still reports
`SEAMGATE FAIL (DIVERGENCE)`.

### 6.3 The two mutations that do NOT bite, which are the resolution floor

**S10 and S11 both survive, and they are the same blind spot measured from two
sides.** S10 deletes the rounding bias in the recurrence's decay stage; S11
deletes the per-layer term from `llama_top`'s B state memory address -- the
defect that `2d10f76` fixed today. Both are invisible for one reason:

`rtl/llama_top.vhd:3270` drives `tk0` high at every token, so
`rtl/gdn_recur_pipe.vhd`'s TK0_ED masks the previous state to **zero**. S10's
mutated expression is then `(0 + bias) >> 13 = 0` against `0 >> 13 = 0`, DERIVED
and identical. S11's memory is written and never read.

**No oracle can close this. It is not a modelling gap, it is a design that does
not exercise the path.** Two independent mutations were used rather than one
because a single survivor reads like a fluke.

S12 is the control that keeps the statement precise: the stage-4 `k*delta` term
**is** live at `tk0` -- it is the only thing the state update has when the
previous state is masked away -- and it fails loudly. So the correct statement is
not "the recurrence is unchecked" but "**the state-carrying half of the
recurrence is unchecked; the half that runs at `tk0` is checked bit-exactly**".

### 6.4 Coverage of the INPUT space, measured

Every seam having a model does not make the model's stimulus rich. MEASURED, by
perturbing one captured input at a time in the `real` capture and re-running the
model:

```
input perturbation                       effect on R_Y-0 (128 elements)
---------------------------------------- ---------------------------------
baseline (no change)                       exp 18->18,   0/128
R_Z-0 element 0 += 1                       exp 18->18,   0/128   (sub-LSB)
R_Z-0 element 0 += 16                      exp 18->18,   1/128
R_Z-0 element 0 += 4096                    exp 18->18,   1/128
R_Z-0 all mantissas negated                exp 18->18, 128/128
R_Z-0 all mantissas zeroed                 exp 18->30, 128/128
R_Z-0 exponent += 1                        exp 18->19, 123/128
R_QKV.q-0 exponent += 1                    exp 18->18, 122/128
R_QKV.k-0 exponent += 1                    exp 18->18,  99/128
R_QKV.v-0 exponent += 1                    exp 18->19,  91/128
R_QKV.q-0 ALL 64 mantissas zeroed          exp 18->18,   0/128
z mantissas that move R_Y-0 at +1024       127 of 128
```

Read that table as the bound on what the row can catch:

* **`R_Z`'s mantissas are elementwise-coupled and well covered.** 127 of 128
  perturbations move `R_Y`, and each moves exactly its own element, which is
  what an elementwise gate should do. A `+1` is genuinely sub-LSB: the
  whole-token renormalisation shift discards it.
* **The three `R_QKV` exponents are strongly coupled** -- 91 to 122 of 128
  elements each -- because they become the conv's `e_ref`.
* **`R_QKV`'s MANTISSAS have exactly zero influence.** Zeroing all 64 of the q
  segment's mantissas changes nothing, because `B_SRC_REAL` is false. Any
  defect that only manifests on activation-derived conv taps is **out of reach
  of this row** until something runs `B_SRC_REAL`.
* Perturbing block 0's inputs moves only `R_Y-0`, never `R_Y-1` or `R_Y-2`,
  which is the expected per-block independence and a check that the driver is
  not accidentally sharing state between layers.

**What the stimulus cannot reach, enumerated:**

1. Activation-derived conv taps (`B_SRC_REAL`). Not exercised at all.
2. Activation-derived `alpha` and `beta` (`B_SRC_REAL`). The `m12` stand-ins are
   used, so `gdn_scalar`'s response to real projection values is unchecked here.
   `rtl/llama_top.vhd:52-58` records that `B_SRC_REAL` true makes `R_ALPHA`
   physically impossible and saturates the gate shut, so turning it on is not a
   free change.
3. Anything downstream of the recurrent state (S10, S11).
4. Any conv tap other than `KCONV-1`. The masked taps are never summed, so the
   tap-history alignment is unchecked at the integration level.
5. `LAYERS > 1` state separation. Real at the RTL, inert at `tk0`.
6. The four approximation kernels' own numerics -- `rmsnorm_bf`, `gdn_silu`,
   `gdn_scalar`, `l2norm_rs` are INCLUDED by `ref/gdn_block_vec.c` rather than
   independently transcribed, which is that file's stated and deliberate limit.
   What this model checks is the **composition**.

### 6.5 Negative controls on the model's own parameters

Three of subsystem B's parameters are NOT in the capture, so a wrong value is a
legal shape and a wrong answer -- the same hazard `attn_oracle.py` documents for
`--kv-block`. Each was measured so the failure signature is on record:

```
--kmap div        R_Y-{0,1,2} 64/64/63 of 128 differ, first at element 32
--conv-lanes 8    R_Y-{0,1,2} 128/128/127 of 128 differ, first at element 0
--b-src-real      R_Y-0 exp 17 vs 18, 128/128 differ, first at element 0
```

`--conv-lanes` and `--b-src-real` fail catastrophically and are unmistakable.
`--kmap` fails at exactly half the elements starting at element 32, which is
also the signature of defect B-BLK-1 -- so **a `--kmap` mistake and a real
key-map defect look identical**, and the parameter must be taken from the RTL
rather than from a default. It is documented in the flag's own help.

---

## 7. Measured and REJECTED -- do not retry

**Do not model `R_Y` by reconstructing a recurrent state from the capture.**
Not measured as a failure, measured as unnecessary: the state is masked at
`tk0`, and building a carry would have added a wrong-looking degree of freedom
to a model that needs none. `ref/gdn_block_cap_vec.c` allocates the state and
**refuses** a `tk0 = 0` at token 0 rather than substituting a zero state, which
would be a plausible wrong answer.

**Do not read `bisect_scaled.py`'s and `attn_oracle.py`'s headers as a statement
about what is reachable.** Both said subsystem B was out of reach because of a
recurrent state. MEASURED: the top level never reads that state. Those sentences
were correct about subsystem B and wrong about the question being asked. Both
have been corrected in place.

**Do not transcribe `gdn_block_token()` into the capture driver.** Not retried,
because the project has the `m7 mutant` on record and `ref/attn_block_cap_vec.c`
already rejected it in writing. The `main` in `ref/gdn_block_vec.c` is guarded
and the file is `#include`d.

**Do not put `m12` in the C oracle.** It is a bench constant, not arithmetic.
Putting it in C would have made `ref/gdn_block_cap_vec.c` contain a copy of an
RTL constant, which is the thing `attn_oracle.qkn_const` exists to avoid.

**Do not add a `sim/regress.sh` row for this.** Not needed: the floors live in
`tools/ref9b/seamgate.sh` and the three `sim:seamgate_*` rows already run it.
Adding a row would have risked the shared gate for no coverage.

**Do not raise the `stub` floor to 64.** MEASURED: `stub` has 63, and the
64th is `R_Y-3`, the `-32768 + i` ramp `rtl/llama_top.vhd:3037` writes when
`C_REAL` is false. That is not attention and there is nothing to model. A floor
of 64 there would be a permanently red row.

---

## 8. Measurement traps hit

**T1. `git archive HEAD` in a repository four other tracks are committing to
gives you an ARBITRARY tree.** `git rev-parse HEAD` and `git archive HEAD` were
issued in the same shell command; HEAD moved between them, and the extracted
tree was `a77d181` -- an **ancestor**, dated 15:00, missing
`tools/ref9b/seamgate.sh`, `ref_stream_scaled.py` and every `mutate_*.sh`,
i.e. all of TRACK SEAMGATE's work. The whole first round of development and its
"bit-exact on the first run" result were against a tree that could not run the
gate they were for. **Nothing was wrong with the result; it just was not
evidence about HEAD.** It was caught only because `git ls-files` and `ls` on the
extracted tree disagreed by eleven files. Everything in this document was
re-measured on `git archive 9ad4c14`, extracted by an explicit sha.
*The rule: `SHA=$(git rev-parse HEAD)` as its own step, then
`git archive "$SHA"`, and print the sha into the report.*

**T2. `git log --oneline -N` printed a commit that `git rev-parse HEAD` did not
agree with, seconds apart.** Same cause as T1 -- another track committed between
the two calls. A history that looks impossible in a shared repository is
concurrency, not corruption. Check `git merge-base --is-ancestor` before
concluding anything about the DAG.

**T3. `bisect_scaled.py` does NOT read `$MV_STEP_ORACLE`.** `seamgate.sh` builds
the subsystem A oracle into its scratch and exports that variable, but
`run_a_oracle()` resolves `os.path.join(HERE, "mv_step_oracle")` and raises
"build it first" if it is absent. The export is inert. This is not a defect in
this track's work and it is not fixed here, but a reader who trusts the export
will lose time; build the binary into `tools/ref9b/`.

**T4. `regress.sh --only` and this row's floor are two numbers in two files.**
`sim/regress.sh:439` and `:939` both carry the sentence "MEASURED: 61 seams for
real, 60 for stub, 59" as a COMMENT. Those comments are now stale. They are not
functional -- the floors that gate are in `tools/ref9b/seamgate.sh` -- and they
were deliberately **not** edited here, because three other tracks were editing
concurrently and this project has already lost six documents to a shared-index
race today. **They should be corrected to 64/63/61 in a quiet moment.**

**T5. `--kmap div` and defect B-BLK-1 produce the same signature.** Half the
elements, first at element 32. A model parameter guessed wrong is
indistinguishable from the defect it was invented to describe. Take it from the
RTL.

**T6. A `+1` perturbation of an input measured as "no coupling".** `R_Z`
element 0 `+= 1` moved nothing, which initially read as "the z gate is
disconnected". It is not: the whole-token renormalisation shift discards
sub-LSB changes, and `+= 16` moves exactly one element. **A single-LSB probe is
not a coupling test on a block-floating-point output.** Sweep magnitudes.

---

## 9. Open, not yet answered

1. **`B_SRC_REAL` has never been run through this gate.** Until it is, subsystem
   B's conv taps, alpha and beta are stand-ins and section 6.4's exclusions 1
   and 2 stand. `rtl/llama_top.vhd:52-58` says turning it on raises the
   degenerate-residual count, so this needs its own track.
2. **Defect candidate B-TOP-1 (section 5) is unresolved.** The size is measured
   (60-75 of 128 mantissas at tokens 1-2); whether the fix is `tk0` alone or
   `tk0` plus the conv tap history is not established. The `gdn_exp_capture`
   counters are reset per token, so at minimum both `b_seq_rst` and `b_tk0`
   have to move together, and the tap memory would have to start holding a
   history it does not hold today (`:3006-3012` writes zero into every tap but
   the newest).
3. **Whether `qkv_exp(seg)` and the captured `R_QKV.{q,k,v}` exponents are the
   same object was assumed, not proved.** The model matches bit-exactly at nine
   independent (layer, token) points, which is strong evidence, but the direct
   proof would be reading `cmp_y_exp` at the same instant the capture snapshots
   the region exponent.
4. **The `stub` configuration's `R_Y-3`** remains the one unmodelled seam
   anywhere, and correctly so.
5. **Wall time.** The three gate rows were not re-timed under a quiet machine; a
   Vivado synthesis was running throughout. The B model adds one `gcc` and one
   sub-second process per token, so the cost is ESTIMATE < 2 s per row -- but
   that is an estimate, not a measurement.
