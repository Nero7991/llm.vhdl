# The first bisect of the machine: a seam capture out of the simulator, and what it can and cannot compare against

**Date:** 2026-08-29. Branch `fpga`. Track BISECT.
**Design under test:** `rtl/llama_top.vhd` and its subsystems at repository
commit `0da1912` (a HEAD snapshot; see measurement trap T1 for why the working
tree was not used).
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/`, nothing opening `/dev/xdma*`.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

From TRACK REF9B's closing statement, `docs/debugging/2026-08-29_9b-whole-model-reference.md`:

> No GHDL or hardware capture exists yet. `capture_to_r9bs.py` removes the
> format as an obstacle, but emitting that text from `sim/tb_llama_top*` is not
> done -- that file belonged to another track, and **it is the only remaining
> step between this reference and an actual bisect of the machine.**

And, as the task:

> **Make the simulator emit a capture stream the reference can bisect, and then
> run the first real bisect.** ... **THE PRIZE: two mutations that nothing could
> kill** -- R7, the `v_ref` sequence reset issued per token rather than per
> sequence, and N2, the real rmsnorm dropping its last output element. Both
> survive `sim/mutate_llama_top_kv.sh` because "there is no value oracle at
> integration".

---

## 2. The answer, up front

**The capture exists, and the format was never the obstacle. The SHAPE is.**

`sim/tb_llama_top.vhd` now has a `CAPTURE` generic that writes every seam of
every token in the exact text `tools/ref9b/capture_to_r9bs.py` parses, with
`tools/ref9b/seam_map.py`'s own seam names, derived from the schedule rather
than typed in. It costs nothing when off, and the run reproduces its published
landmark exactly.

**But the 9B reference cannot bisect a GHDL run and never will.** MEASURED:

```
# exact compare, token 0: 0 seams identical, 63 differ
FIRST DIVERGENCE: R_X.embed at element -1 -- length 4096 vs 64
```

The bench runs `mk_shape_scaled` -- hidden 64 against the model's 4096, ffn 128
against 12288 -- and DERIVED below, a 9B token is about **35,600x** the
arithmetic of a scaled one, which at the measured 35.7 s per scaled token is
**about 15 days per token** before the 5 GB of weights are considered. The
whole-model reference is an oracle for a CARD. It is not an oracle for a
simulation, and no amount of format plumbing changes that.

**So the bisect that exists today is a STEPWISE one, and it is built and
measured here.** `tools/ref9b/bisect_scaled.py` takes the machine's own captured
inputs for each step, recomputes that step's output with an INDEPENDENT model,
and compares bit for bit:

| what | model | seams |
|---|---|---|
| the 37 subsystem A jobs | `ref/matvec_int4.c`, on the bench's own weight bytes | 37 |
| the 9 norms | a bit-exact `rmsnorm_rs` model, new in `tools/ref9b/vec_oracle.py` | 9 |
| the 8 residuals | `ref/seq_vec_res_vec.c`'s recipe (REAL RTL on the other side) | 8 |
| the 4 swiglu ops | the behavioural stand-in's own arithmetic | 4 |
| **not covered** | `R_Y` (3 GDN, 1 attention) and `LOGITS` | **5** |

37 + 9 + 8 + 4 = 58, and 58 + 5 = 63, which is the 62 steps with a real
destination plus the lm_head step; `R_X.embed` is the stimulus and is the
capture's 63rd record rather than a checked seam.

**58 of 63 seams, and the healthy run is CLEAN in all three gate
configurations.** MEASURED, `tools/ref9b/bisect_scaled.py`:

```
# stepwise oracle, token 0, shape blocks=4 attn_interval=4 attn_hd=16 hidden=64 ffn=128
# 58 seams checked against a model, 5 NOT checked
EVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT, given the machine's own inputs.
```

Same for the KV-cache configuration at all three tokens (55 of 60), and for the
default stub configuration (58 of 63).

**N2 IS KILLED, on the numbers, by an independent oracle.** MEASURED:

```
FIRST DIVERGENCE: R_XN-0 at element 63 -- expected -11897, captured 0
                  (exponent 14 vs 14, 1 of 64 mantissas differ)
```

Element 63 of a 64-element norm, at the first norm of the token, with every
other element correct. That is the defect read straight off the report.

**R7 IS KILLED, and only by the characterisation half.** MEASURED, mutant
against a clean run of the same configuration:

```
tok 0:  60 identical, 0 differ            <-- correct: at cur_pos 0 the reset cannot matter
tok 1:  21 identical, 39 differ
        FIRST DIVERGENCE: R_Y-1 tok 1 at element 12 -- 82 of 256 mantissas differ
tok 2:  58 identical, 2 differ
        FIRST DIVERGENCE: R_Y-3 tok 2 at element 64 -- 65 of 256 mantissas differ
```

The stepwise VALUE oracle reports R7 **clean at every token**, because `R_Y` is
subsystem C's output and has no integration-level model. **That is not a
contradiction; it is the coverage hole, measured.** The bisect names the seam
where a defect first shows, whether or not it has a model for that seam -- and
that is worth having, because the seam it named is exactly the one a person
would then go and read.

**A third mutation was added and it is the sharpest of the three.** VA1 makes
subsystem A truncate instead of rounding at spec 7.4 site 2 -- one LSB. The
bench scores it PASS and **leaves `R_X(0)` bit-identical at -16339**; only the
hash moves. The value oracle:

```
FIRST DIVERGENCE: R_QKV.q-0 at element 1 -- expected 7066, captured 7065
```

**One more thing found, and it is about the design rather than the harness.**
DERIVED from the captured exponents: at the KV configuration, token 2, block 3,
`R_ER-3` carries exponent 0 while the residual `R_X-2` carries -10. R7 moves
`R_ER-3` by up to 7 mantissa LSBs and `R_X.attn-3` is **bit-identical**. The
residual aligns to the finer grid, shifts `R_X` left by 10, and then renormalises
with `sh = msb - 14 ~ 11`, so subsystem C's entire change is quantised away.
The attention block's contribution to the residual does not survive the BFP add
at that position.

---

## 3. What the capture can and cannot emit, named from the RTL

The capture fires on `obs_cmp` (which is `cmp_valid`, `rtl/seq_opdec.vhd:664`)
and reads the destination region through `hr_reg`/`hr_addr`/`hr_data`
(`rtl/llama_top.vhd:483-485`, combinational at `:1005`).

**Emitted, 63 records per token at the 4-block shape:**

* `R_X.embed`, at `go`, with the driver's `host_x_exp`.
* every step whose plan destination is a real region: 16 seams per GDN block,
  13 per attention block, then `R_XN.final`.

**NOT emitted, and each for a stated reason:**

| seam | why not |
|---|---|
| `LOGITS` | `sim/seq_tbl_pkg.vhd:341` routes lm_head with `FLG_TO_SMP` and `dst => R_NONE`; there is no region to read. This is REF9B's finding D1, confirmed from the capture side: the design cannot produce this seam. |
| anything inside a block | the capture reads REGIONS, and a region is the finest thing `hr_*` can address. The conv tap, the recurrence state, the attention score matrix are not regions. |
| the second and later runs | only run 0 is captured. `r9bs.index` keys on (name, token) and REFUSES a duplicate, so a second run at the same token indices would make the file unreadable. |

**Emitted but NOT compared against a model:** the four `R_Y` seams. Subsystem B
(`gdn_block`) and subsystem C (`attn_block`) have block-level oracles --
`ref/gdn_*` and `ref/attn_block_seq_vec.c` -- and neither is reachable from the
integration without reproducing the whole of that block's input state. That is
the largest remaining gap and it is listed in section 8.

**A name the map does not know is possible and is guarded.** `seam_map.py` fixes
the attention interval at 4, because that is the real model's. The KV gate row
runs `ATTN_INT = 2`, so its attention blocks are at indices 1 and 3 and it emits
`R_QG-1`, which seam_map has no entry for. `capture_to_r9bs.py --check-names`
refuses it, correctly:

```
line 111: seam name 'R_QG-1' is not in seam_map.SEAMS, so the bisect would
silently never compare it
```

---

## 4. The procedure, in the order it was run

Each step controls for exactly one thing.

1. **Read `capture_to_r9bs.py` before writing a line of VHDL.** Controls for:
   inventing a format. The format is not mine; the exponent convention
   (`value = mant * 2^-exp`) is `tools/pack_int4.py`'s, `ref/fx.h:88`'s and
   `rtl/seq_vec_res.vhd:11`'s, and getting its sign backwards produces a stream
   wrong by `2^(2*exp)` that looks structurally perfect.
2. **Derive the seam names from the plan, not from a table.** Controls for: a
   name table drifting from the schedule. `seam_of` walks the same block
   structure `llama_sched_pkg.build_plan` emits.
3. **Snapshot the region in ZERO simulation time.** Controls for: a torn
   capture. Region writes land on rising edges; a snapshot taken 0.4 ns after
   one, in delta cycles only, cannot straddle the next.
4. **Check the capture against the driver's own `dump()`.** Controls for: the
   capture mechanism itself. Two different disciplines, two different instants,
   and no step between them writes `R_X`. Reported as
   `capture/dump disagreements=0` on every run in this document.
5. **Run the 9B reference against the capture.** Controls for: assuming the
   shape problem away. It is the first thing that had to be measured rather
   than argued.
6. **Build the stepwise oracle op by op**, A first because it is 26 of the 63
   seams. Controls for: a "clean" verdict that is clean because nothing is
   checked. The coverage table is printed above the verdict for this reason.
7. **Perturb the CAPTURE by one LSB and re-run both comparators.** Controls
   for: a comparator that cannot fail. Cheap, and it prices the tools before
   any RTL is mutated.
8. **Mutate the RTL: N2, R7, and a new A-side one-LSB rounding change.**
   Controls for: the oracle agreeing with the machine because it is derived
   from it.
9. **Full unfiltered gate.** Controls for: this track having broken something.

---

## 5. The evidence, as raw captured output

### 5.1 The capture, and the landmark it reproduces

```
tb_llama_top: seam capture wrote 63 records to cap_real.txt, capture/dump disagreements=0
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run,
  1 descriptor-latency points, R_X bit-identical across all of them,
  R_X(0) = -16339 hash(R_X) = 92903
```

`R_X(0) = -16339 hash(R_X) = 92903` is `sim/tb_llama_top_real.vhd`'s published
control landmark, unchanged. 35.7 s wall.

The first records, and the exponent discipline they carry:

```
# sim/tb_llama_top.vhd seam capture, run 0.  value = mant * 2^-exp.
# blocks=4 attn_interval=4 hidden=64 ffn=128  -- A SCALED SHAPE, not the 9B one.
SEAM R_X.embed 0 -1 bfp16 3 64
-125 -88 -51 -14 23 60 97 -117 -80 -43 -6 31 68 105 -109 -72
...
SEAM R_XN-0 0 0 bfp16 14 64
```

Through the converter and the reader:

```
wrote cap_real.r9bs: 63 records
R_X.embed   tok=0 layer=-1  n=64  bfp16 e=3   min=-15.625  max=+15.5    rms=9.19281
R_XN-0      tok=0 layer=0   n=64  bfp16 e=14  min=-1.65161 max=+1.73981 rms=1.00186
R_QKV.q-0   tok=0 layer=0   n=64  bfp16 e=12  min=-2.14258 max=+4.46216 rms=1.22104
...
R_X-3       tok=0 layer=3   n=64  bfp16 e=10  min=-17.2285 max=+16.9766 rms=9.42217
R_XN.final  tok=0 layer=4   n=64  bfp16 e=14  min=-1.83105 max=+1.79059 rms=0.997902
```

`rms(R_XN) = 1.002` and `0.998` is what an RMS norm is supposed to produce, and
it is the first time anyone has looked at that number at the integration level.

### 5.2 The 9B reference against it

```
$ python3 seam_bisect.py /mnt/storage/ref9b/ref_bfp.r9bs cap_real.r9bs --mode exact --tok 0
# exact compare, token 0: 0 seams identical, 63 differ
FIRST DIVERGENCE: R_X.embed at element -1 -- length 4096 vs 64
```

**DERIVED, the cost of closing that gap in GHDL.** A 9B token is 7.94e9 MAC
(REF9B section 5.2). The scaled token is, summing the plan: 3 GDN blocks at
57,856 MAC, one attention block at 40,960, one lm_head at 8,192 = **222,720
MAC**. Ratio **35,650x**. At the measured 35.7 s that is **1.27e6 s = 14.7
days** for one token, ignoring that the weights are 5 GB and that
`rtl/llama_top.vhd`'s region file is a flat `NREGION*REGMAX` array which the
real `ffn = 12288` does not fit (`v_n` is `VN_W = 13` bits, max 8191).

### 5.3 The healthy run, three configurations

```
real   # 58 seams checked against a model, 5 NOT checked
       EVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT

seq    tok 0  # 55 seams checked, 5 NOT checked   EVERY MODELLED SEAM MATCHES
       tok 1  # 55 seams checked, 5 NOT checked   EVERY MODELLED SEAM MATCHES
       tok 2  # 55 seams checked, 5 NOT checked   EVERY MODELLED SEAM MATCHES

stub   # 58 seams checked against a model, 5 NOT checked
       EVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT
```

The five not checked, every time:

```
    NOT CHECKED  R_Y-0          subsystem B has no integration-level model
    NOT CHECKED  R_Y-1          subsystem B has no integration-level model
    NOT CHECKED  R_Y-2          subsystem B has no integration-level model
    NOT CHECKED  R_Y-3          subsystem C has no integration-level model
    NOT CHECKED  LOGITS         destination is R_NONE: the lm_head job discards its result (finding D1)
```

**This is a real result and it is the first of its kind here.** 37 A jobs
against `ref/matvec_int4.c` on the bench's own weight bytes, 9 norms against a
bit-exact `rmsnorm_rs` model, 8 residuals against `ref/seq_vec_res_vec.c`'s
recipe -- all bit-identical, in the configuration with the real
`matvec_int4`, the real `gdn_block`, the real `attn_block`, the real
`rmsnorm_rs` and real Qwen3.5-9B weights. Before this, nothing in the repository
compared any integration-level number against anything.

### 5.4 One LSB, injected into the capture

Perturb `R_H-2` element 77 from 14 to 15 and run both comparators:

```
# stepwise oracle
  R_H-2          exp 8 expected vs 8 captured, 1 of 128 mantissas differ,
                 first at 77 (expected 14, captured 15)
  R_ER.ffn-2     exp 6 expected vs 6 captured, 2 of 64 mantissas differ, first at 23
FIRST DIVERGENCE: R_H-2 at element 77 -- expected 14, captured 15

# characterisation compare
  R_H-2  tok 0  first differing element 77 -- exp 8 vs 8, 1 of 128 mantissas differ, max |delta| 1
FIRST DIVERGENCE: R_H-2 tok 0 at element 77
```

One LSB in 128 values, located to the element index, through this capture path
and not through REF9B's own test data. The second row is the correct behaviour
and not noise: `R_ER.ffn-2` reads `R_H-2`, so its model output moves too.

### 5.5 N2 -- the real rmsnorm drops its last output element

The bench's own verdict, unchanged from TRACK TOP-KV's:

```
tb_llama_top RESULT: PASS -- ... R_X(0) = -16215 hash(R_X) = 52824
```

The value oracle:

```
  R_XN-0         exp 14 vs 14, 1 of 64 mantissas differ, first at 63 (expected -11897, captured 0)
  R_XN.ffn-0     exp 14 vs 14, 1 of 64 mantissas differ, first at 63 (expected -11869, captured 0)
  R_XN-1         exp 14 vs 14, 1 of 64 mantissas differ, first at 63 (expected  -9955, captured 0)
  R_XN.ffn-1     exp 14 vs 14, 1 of 64 mantissas differ, first at 63 (expected  -9957, captured 0)
  R_XN-2         exp 14 vs 14, 1 of 64 mantissas differ, first at 63 (expected -11013, captured 0)
  R_XN.ffn-2     exp 14 vs 14, 1 of 64 mantissas differ, first at 63 (expected -11005, captured 0)
  R_XN-3         exp 14 vs 14, 1 of 64 mantissas differ, first at 63 (expected -12787, captured 0)
  R_XN.ffn-3     exp 14 vs 14, 1 of 64 mantissas differ, first at 63 (expected -11846, captured 0)

FIRST DIVERGENCE: R_XN-0 at element 63 -- expected -11897, captured 0
```

Eight norms, one element each, always the last, always the same signature. The
report does not merely say the run is wrong; it says what is wrong with it.

**N2 IS KILLED, by a value oracle, and the report diagnoses it.**

The characterisation compare kills it too, at the same seam and element, and
then shows the storm downstream (`R_QKV.k-0` 56 of 64 mantissas, max delta
1029). The value oracle is the more useful of the two here precisely because it
does NOT show the storm: every seam it flags is a seam whose own arithmetic is
wrong, not a seam that inherited a wrong input.

### 5.6 R7 -- the `v_ref` sequence reset issued per token

```
tb_llama_top RESULT: PASS -- ... R_X(0) = -8060 hash(R_X) = 28506
```

**Identical to the clean run's `R_X(0)` and hash.** The bench's flagship
fingerprint does not move at all.

Characterisation compare against a clean run of the same configuration:

```
tok 0   60 identical, 0 differ
tok 1   21 identical, 39 differ
        FIRST DIVERGENCE: R_Y-1 tok 1 at element 12 -- exp 8 vs 8, 82 of 256 differ, max |delta| 256
tok 2   58 identical, 2 differ
        FIRST DIVERGENCE: R_Y-3 tok 2 at element 64 -- exp 7 vs 7, 65 of 256 differ, max |delta| 19
```

Value oracle: **clean at every token.**

**R7 IS KILLED by the characterisation half and INVISIBLE to the value half**,
and the reason is exactly the one that made it survive before: `R_Y` is where
subsystem C's answer appears and there is no model for it here. What is new is
that the harness now says *where*, and the where is right: token 0 is
bit-identical because at `cur_pos = 0` `attn_block` bypasses the cache and the
sequence reset cannot matter; the first divergence at token 1 is the FIRST
attention block of that token.

**And an observation about the design, DERIVED from the captured exponents.** At
token 2 only two records move, `R_Y-3` and `R_ER-3`, and `R_X.attn-3` is
bit-identical. The capture gives the exponents:

```
SEAM R_X-2 2 2 bfp16 -10 64        <- the residual coming in
SEAM R_ER-3 2 3 bfp16 0 64         <- subsystem C's projected output
SEAM R_X.attn-3 2 3 bfp16 -10 64   <- the sum
```

`seq_vec_res` aligns to the finer grid: `q = max(-10, 0) = 0`, so `R_X` is
shifted LEFT by 10 and then the output shift is chosen from the maximum,
`sh = msb - 14`, which is about 11. A change of 7 LSBs in `R_ER-3` is therefore
right-shifted by 11 and vanishes. **At this position, subsystem C's entire
contribution to the residual is quantised away.** That is the hazard
`sim/tb_llama_top.vhd`'s header already warns about in the abstract; this is the
first time it has been measured at a seam.

### 5.7 VA1 -- one LSB inside subsystem A

`rtl/matvec_core.vhd:799`, `round_shift` to `floor_shr` at spec 7.4 site 2.

```
tb_llama_top RESULT: PASS -- ... R_X(0) = -16339 hash(R_X) = 28310
```

**`R_X(0)` is bit-identical to the clean run.** Only the hash moves, which is
the whole argument for the hash existing.

```
  R_QKV.q-0      exp 12 vs 12, 31 of 64 mantissas differ, first at 1 (expected 7066, captured 7065)
  R_QKV.k-0      exp 12 vs 12, 35 of 64 mantissas differ, first at 2 (expected 3138, captured 3137)
  R_QKV.v-0      exp 12 vs 12, 69 of 128 mantissas differ, first at 0 (expected 874, captured 873)
  R_Z-0          exp 12 vs 12, 63 of 128 mantissas differ, first at 1 (expected -1754, captured -1755)
  R_ALPHA-0      exp 12 vs 12, 2 of 4 mantissas differ, first at 2 (expected -527, captured -528)
  R_ER-0         exp 16 vs 16, 28 of 64 mantissas differ, first at 4 (expected -2207, captured -2208)

FIRST DIVERGENCE: R_QKV.q-0 at element 1 -- expected 7066, captured 7065
```

Every difference is exactly one LSB in the right direction, at the first A job
of the token. This is the row that says the A-side oracle has teeth, and it is
the only one of the three mutants the value oracle catches *first*.

### 5.8 `seam_bisect.py --mode exact` silently skips seams

MEASURED, on the KV-configuration capture compared against itself:

```
$ python3 seam_bisect.py cap_seq.r9bs cap_seq.r9bs --mode exact --tok 0
# exact compare, token 0: 57 seams identical, 0 differ
EVERY COMPARED SEAM IS BIT-IDENTICAL.

$ python3 seam_diff.py cap_seq.r9bs cap_seq.r9bs --tok 0
# exact set compare: 60 records in ..., 60 in ...
# 60 identical, 0 differ, 0 only in the golden, 0 only in the suspect
```

57 against 60. `seam_bisect.exact` walks `seam_map.SEAMS` and does
`if k not in A or k not in B: continue`, so the three seams the map does not
know (`R_QG-1`, `R_KIN-1`, `R_VIN-1`, which exist because this configuration has
`ATTN_INT = 2`) are never compared and never mentioned. The summary line counts
only what it looked at. `tools/ref9b/seam_diff.py` compares the SET and reports
records present in only one file as a difference.

---

## 6. Measured and REJECTED -- do not retry

**Running the 9B shape in GHDL to make the whole-model reference apply.**
DERIVED at 35,650x the arithmetic of the scaled token, i.e. about 15 days per
token at the measured rate, and blocked independently by the region file: `v_n`
is 13 bits and cannot express `ffn = 12288`, and `REGMAX` defaults to 4096.
Do not retry. The whole-model reference is for the card.

**Fixing `LOGITS` so the last seam exists.** Out of scope by instruction, and
correctly so: `FLG_TO_SMP` appears nowhere in `rtl/llama_top.vhd` and the fix is
a design decision (backlog item 4), not a testbench change. Confirmed from this
side: the lm_head step's plan destination is `R_NONE`, so there is no region for
a capture to read, and the tool reports it as NOT CHECKED with that reason
rather than omitting it.

**Comparing `R_XN` against the 9B reference.** REF9B's finding D2 stands:
`rtl/llama_top.vhd:1494`'s `W_CONST` is a synthetic ramp, so those seams have no
counterpart in the model. What DOES work, and is the inversion worth recording,
is that the ramp is known exactly at the toy shape, so the STEPWISE oracle
checks the very seam the whole-model reference cannot -- and that is what killed
N2.

**Using `seam_bisect.py --mode exact` as the capture comparator.** It skips any
seam not in `seam_map.SEAMS`, silently. Measured at 57 of 60 on the KV
configuration. Use `tools/ref9b/seam_diff.py`.

**A committed golden capture as a gate row.** Rejected by design, not by
measurement. Any track that legitimately changes a number turns that row red for
a reason unrelated to it, and a permanently red row stops being read. The
mutation script generates its own clean baseline per configuration instead.
`tools/ref9b/golden/llama_top_real.txt` is committed as a dated landmark and is
explicitly not gated.

**Supplying a fixed 64 beats of weights to the A oracle.** MEASURED and wrong:
at `ATTN_HD = 64`, `R_QG` is 512 rows = 256 beats, so the oracle read zero
weights past row 128 and reported "384 of 512 mantissas differ, first at 128" --
a perfectly plausible, entirely self-inflicted divergence. The committed image
really does hold only 64 beats (`A_WBEATS`), and
`tools/gen_llama_top_weights.py` asserts `tiles*NB <= 64` and refuses a shape
needing more; the synthetic `wword` has no such bound and the shapes that need
more are exactly the ones that run without an image.

---

## 7. Measurement traps hit, including my own

**T1. `rtl/llama_top.vhd` was being edited by another agent during this work.**
MEASURED: the file grew by 254 lines between two `ghdl -a` invocations, and
`ghdl -r` refused with "rtl/llama_top.vhd has changed and must be reanalysed".
Later the mutation script stopped analysing the working tree at all --
`rtl/llama_top.vhd:3963:25: unit "sampler_stream" not found in library "work"`
-- because that track's edit instantiates `rtl/sampler_stream.vhd`, which is a
tracked file from July that the script's `FILES` list did not name.
`rtl/sampler_stream.vhd` has been added to `FILES` and the working tree
analyses again (MEASURED).

**Every measurement in this document was nevertheless taken against a
`git show HEAD:` snapshot of `rtl/` and `sim/*_pkg.vhd` at commit `0da1912`,
with only `sim/tb_llama_top.vhd` taken from the working tree.** Deliberately:
a landmark taken against another track's uncommitted mid-edit is a landmark
nobody can reproduce. Anyone re-running these numbers should snapshot HEAD the
same way if the tree is dirty.

**T2. A completion pulse is not always a job.** `rtl/seq_opdec.vhd:664` is
`cmp_valid <= '1' when tstate = T_PUB else job_cmp`, so the token-start
publication of `host_x_exp` into `R_X`'s exponent raises the same pulse with no
job behind it. Without a guard the capture emitted a spurious all-zero `R_XN-0`
at the leftover step index, and `r9bs.index` then refused the whole file as a
duplicate `(name, token)`. **That refusal is the only reason it was noticed**;
had the reader taken last-wins, the file would have been silently wrong. The
capture now requires a preceding `obs_issue`.

**T3. `R_X(0)` is not a fingerprint and two of three mutants prove it.** VA1
leaves `R_X(0) = -16339` bit-identical to the clean run; R7 leaves both
`R_X(0) = -8060` AND `hash(R_X) = 28506` identical. Anyone eyeballing the PASS
line would have called both equivalent.

**T4. VHDL `/` truncates toward zero; an arithmetic right shift floors.** The
residual and `rmsnorm_rs` use shifts; the behavioural norm and swiglu use `/`.
Getting this backwards is off by one on every negative element and reads exactly
like a real defect. Stated in `tools/ref9b/vec_oracle.py` at the one function
that implements it.

**T5. The oracle's own default made every norm seam "diverge".**
`rtl/llama_top.vhd:220` has `NORM_EXP : integer := 12` and the tool's
`--norm-exp` defaulted to 3, so the first KV run reported eight norm seams with
"exp 3 expected vs 12 captured, 0 of 64 mantissas differ". Zero mantissas
differing and only the exponent moving is the signature of a parameter mistake
rather than a defect, and it is worth learning to read: a real arithmetic defect
moves mantissas.

**T6. A second integer path is weak evidence and the rmsnorm oracle is one.**
It is transcribed from `rtl/rmsnorm_rs.vhd` for `S_INV` and the `rq_d = rq_p - Q`
fold, and LIFTED from `ref/rmsnorm_bf_vec.c` -- a different unit, written
against a double-precision oracle of its own -- for everything from the rsqrt
seed onward. It also returns the double-precision ideal
(`rel_rms_vs_ideal`, 0.0064 on a random 64-vector) so an internally consistent
and numerically absurd recipe is visible. That number is REPORTED, never gated
on: the unit has a documented 244x epsilon floor
(`docs/debugging/2026-08-26_rmsnorm-magnitude-window.md`) and gating on the ideal
would flag known behaviour as a defect.

**T7. The evidence chain behind `rmsnorm_rs` is weaker than its own headers
say.** `sim/tb_rmsnorm_rs.vhd`'s header states rmsnorm.vhd "is asserted
bit-exact against `rmsnorm_fx()` in `ref/run_fx.c`". `tb/tb_rmsnorm.vhd:128`
asserts `dev <= 2`, i.e. +-2 int16 LSB, on one N=64 vector. The A/B itself runs
only at the testbench's default `N = 128`, because `sim/regress.sh` passes no
generics. So before this track there was no bit-exact independent oracle for
that unit at `llama_top`'s generics at all. Where a document and the RTL
disagree, the RTL wins.

---

## 8. NOT verified

* **The `R_Y` seams.** Four per token, subsystems B and C, no integration-level
  model. A wrong `R_Y` is fed forward AS GIVEN and every later comparison still
  passes. This is the largest remaining gap and it is what makes R7 invisible to
  the value oracle.
* **`LOGITS`.** The design cannot produce it. Nothing here changes that.
* **The swiglu ARITHMETIC.** `rtl/llama_top.vhd:903` prints "swiglu is
  behavioural in every configuration" at time zero and `rtl/swiglu.vhd` is not
  instantiated. The four `R_H` seams are checked against the stand-in's own
  recipe, which verifies sequencing, addressing and the product exponent, and
  says nothing about SwiGLU.
* **The norm ARITHMETIC in two of the three configurations.** `stub` and `seq`
  run the behavioural mean-removal model with the `NORM_ANCHOR` probe; only the
  `real` configuration elaborates `rmsnorm_rs`.
* **Anything at the 9B shape.** Every number here is at `mk_shape_scaled`:
  hidden 64, ffn 128, 4 blocks. A green run says nothing about 32 blocks, and
  `sim/tb_llama_top.vhd`'s own header already records that 8 anchored blocks is
  the deepest defensible configuration.
* **RoPE.** REF9B measured that a wrong RoPE pairing is nearly invisible at
  short context over 21 tokens. Nothing in a 3-token run at `N_ROT = 16` bears
  on it, and this track makes no claim about it.
* **The capture on hardware.** The text format is the one the FK33 host driver
  would emit, and nothing here has emitted it from a card. There is no
  bitstream.
* **`tools/gen_layer_program.py`'s weight base pointers.** REF9B's D3 left this
  open and it stays open: the A oracle here derives the weight bytes from the
  BENCH's address map, not from that generator.
* **Whether the clean numbers are RIGHT at the five unmodelled seams.** The
  three configurations agree with their models at 58, 55 and 58 seams
  respectively. That is a statement about those seams and about nothing else.

---

## 9. Files

| file | what |
|---|---|
| `sim/tb_llama_top.vhd` | the `CAPTURE` generic, `seam_of`, the zero-time snapshot, and P13 (capture against the driver's own dump) |
| `tools/ref9b/capture_llama_top.sh` | one command per configuration, so a golden has a recipe |
| `tools/ref9b/seam_diff.py` | set-complete exact comparison of two same-format streams |
| `tools/ref9b/scaled_plan.py` | the step plan and seam names in Python, checked against the capture before any comparison |
| `tools/ref9b/vec_oracle.py` | independent models of the residual, the swiglu stand-in, the two norm stand-ins and `rmsnorm_rs` |
| `tools/ref9b/mv_step_oracle.c` | one A job through `ref/matvec_int4.c` on the bench's own weight bytes |
| `tools/ref9b/bisect_scaled.py` | the stepwise bisect and its coverage table |
| `tools/ref9b/golden/llama_top_real.txt` | a dated characterisation landmark, NOT gated |
| `sim/mutate_llama_top_kv.sh` | the `V` rows, scored on the numbers, plus an explicit ABORT verdict |

---

## 10. Corrections

**2026-08-29, same day. The A-job count was 26 in the first draft and in commit
`ecfd178`'s message. It is 37.** MEASURED by
`python3 -c "import scaled_plan; Counter(...)"` on the 4-block ATTN_INT=4
plan: `A 37, NORM 9, RES 8, SWG 4, B 3, C 1`, total 62 steps with a
destination. 26 was a hand count that missed the FFN's three A jobs per block.
Every other number in this document is unaffected -- the tool always reported
"58 seams checked", which is 37+9+8+4, and that is the figure the verdicts rest
on. Recorded rather than silently fixed because the wrong number is in a commit
message and cannot be withdrawn from there.

**2026-08-29, appended. `sim/mutate_llama_top_kv.sh`'s V rows, run end to end.**
MEASURED, against the HEAD snapshot:

```
V0r  SURVIVED   -- CONTROL: the clean design, real-path configuration
        CAPTURE clean
        ORACLE  clean
V0s  SURVIVED   -- CONTROL: the clean design, KV-cache configuration
        CAPTURE clean
        ORACLE  clean
VN2  KILLED     -- N2 again: the real rmsnorm's writeback drops its last element
        CAPTURE tok 0: FIRST DIVERGENCE: R_XN-0 tok 0 at element 63 -- exp 14 vs 14,
                       1 of 64 mantissas differ, max |delta| 11897
        ORACLE  tok 0: FIRST DIVERGENCE: R_XN-0 at element 63 -- expected -11897,
                       captured 0 (exponent 14 vs 14, 1 of 64 mantissas differ)
VR7  KILLED     -- R7 again: the v_ref sequence reset is issued per TOKEN
        CAPTURE tok 1: FIRST DIVERGENCE: R_Y-1 tok 1 at element 12 -- exp 8 vs 8,
                       82 of 256 mantissas differ, max |delta| 256
        ORACLE  clean
VA1  KILLED     -- subsystem A's spec 7.4 site 2 truncates instead of rounding
        CAPTURE tok 0: FIRST DIVERGENCE: R_QKV.q-0 tok 0 at element 1 -- exp 12 vs 12,
                       31 of 64 mantissas differ, max |delta| 1
        ORACLE  tok 0: FIRST DIVERGENCE: R_QKV.q-0 at element 1 -- expected 7066,
                       captured 7065 (exponent 12 vs 12, 31 of 64 mantissas differ)
```

Both controls clean on both scorers, which is the row that says a kill is a
detection and not a permanently red harness.

**2026-08-29, appended. T8: editing this script during its own run broke the
run, and it is the hazard `sim/regress.sh` already guards against.** MEASURED:
one filename was added to `FILES` while an instance was executing, and bash --
which reads a script by BYTE OFFSET -- resumed mid-token and died with
`syntax error near unexpected token '('` at a line that is perfectly valid.
Two cases had already reported cleanly, so it read as a defect in the third.
`sim/mutate_llama_top_kv.sh` now takes a private copy of itself, syntax-checks
it and re-execs it, exactly as `sim/regress.sh:287` does, and resolves the repo
root before the re-exec so `$0` moving to `/tmp` does not move the working
directory with it.

**2026-08-29, appended. A concurrent track is closing finding D1 while this was
written.** `sim/tb_llama_top_smp.vhd` and `sim/tb_llama_top_smp_beh.vhd` are new
in the working tree, `rtl/llama_top.vhd` now instantiates `rtl/sampler_stream.vhd`
behind an `SMP_EN` generic, and `BASELINE_PASS` has moved 83 -> 85. So the
statement "the design cannot produce `LOGITS`" is true of commit `0da1912` and
is about to stop being true. **When that lands, the capture should learn to emit
`LOGITS`**: the sampler route carries RAW s32 rows rather than a region, so it
needs a producer of its own in `sim/tb_llama_top.vhd`'s capture process rather
than the `hr_*` read every other seam uses. That is the one remaining seam
between this harness and a whole-token comparison on hardware.

