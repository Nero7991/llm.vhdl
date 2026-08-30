# A whole layer's subsystem-A matvecs, in order, against the 9B reference

**Date:** 2026-08-29. Branch `fpga`. **Track LAYERRUN.**
**Deliverables:** `hw/fk33/host/fk33_run_layer.py`,
`hw/fk33/host/mv4i_job_oracle.c`.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/*.sh` or `hw/fk33/tcl/`, and nothing opening `/dev/xdma*` --
MEASURED by `strace -e trace=openat` on every no-card path (section 5.5).

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

> Tonight subsystem A was MEASURED computing bit-exactly on the FK33: 30+ jobs,
> all eight distinct `(M, K)` geometries in the 9B model, 18 row counts across
> every `BLOCK`(32) and `ROWS_IF`(48) boundary including `rows=1`, three
> activation exponents, every mantissa and `y_exp` bit-identical to
> `ref/matvec_int4.c`.
>
> **Every one of those was a SINGLE job, with the host supplying the activation
> vector.** Nothing has ever run a SEQUENCE on this silicon -- no layer, no
> chained jobs, no output of one job feeding the input of the next.
>
> **Your job: drive one whole transformer layer's worth of subsystem-A matvecs
> through the card, in order, and compare the result against the reference.**

---

## 2. The answer, up front

**The tool exists, and everything about it that can be measured without a card
has been measured. Nothing has run on the card, because that is Oren's to run.**

**The tool:** `hw/fk33/host/fk33_run_layer.py` walks one transformer layer's
subsystem-A jobs in program order on ONE open device, with the oracle compiled
once and the manifest parsed once, feeds each job's output where the next one
needs it, and compares every job AND the layer output against `ref/run9b`'s
whole-model 9B stream, mantissa for mantissa.

**What it covers, stated plainly because overclaiming it would be worse than the
result is good:** subsystem A only. `hw/fk33/rtl/fk33_engine.vhd` instantiates
`matvec_int4_desc_axi` and nothing else, so B, C and D have never run on this
silicon. **This is the matvec skeleton of a layer, run in order on the card,
with the non-matvec steps done on the host.** The two RMS norms, the two
residual adds and the SwiGLU run on the host; the Gated DeltaNet block (GDN
layers) or the attention block (attention layers) is a structural gap that no
host step fills, and the chain is re-anchored there, once, by name.

**Five things MEASURED tonight with no hardware:**

1. **The card's packed set and the reference's packed set are the same bytes.**
   `qwen35-9b-mv4i-noembd` (what the loader wrote to HBM) and
   `qwen35-9b-mv4i-qkvpad` (what TRACK REF9B built the reference against) share
   **250 files, every one with an identical `blake2b_128`**, and differ only by
   `token_embd.weight`, which is a gather and is not a matvec. Only
   `hbm_offset` differs. **Nothing had checked this, and the whole comparison
   rests on it**; it is now a refusal in the tool (`--ref-manifest`).
2. **Every job of four layers reproduces the reference on the host, exactly.**
   37 A jobs across layers 0, 1, 2 (Gated DeltaNet) and 3 (attention):
   **0 of 37 differ**, in mantissas or in `y_exp`. That validates the
   step-to-seam mapping, the row window, the qkv segment lookup and the
   exponent plumbing before a card is involved.
3. **Every host non-matvec step reproduces the reference bit-for-bit.**
   5 steps per layer x 4 layers = **20 of 20 PASS**, 0 mantissas differing and
   0 exponent difference. That is what makes chaining legitimate rather than
   self-consistent.
4. **Nine mutations, nine bites.** Three host-arithmetic mutants and six
   run-loop faults, each required to produce a stated verdict. A tenth was
   measured, did NOT bite, and is recorded under its own name with the reason
   (section 6).
5. **A HAZARD IN THE RTL THAT ONLY A SEQUENCE CAN MEET:**
   `rtl/matvec_int4_desc_axi.vhd` clears `done_l` at the next `S_IDLE`
   (`:643`), not on the GO write, so after a GO there are a few core clocks in
   which STATUS still reads the PREVIOUS job's `done`. A single-job tool can
   never hit it; a sequence meets it on every job after the first. It is
   almost certainly closed in practice by PCIe ordering plus AXI-Lite latency,
   but by about 10x and not by construction. The tool detects it through the
   engine's own BEATS counter and reports INCONCLUSIVE. **The fix belongs to
   whoever owns that file** (section 7, DONE-1).

**What is NOT determined:** whether the card computes any of it. Every number
in this write-up is DERIVED. Section 9 is the copy-pasteable command list.

---

## 3. The design, and the one decision that shaped it

### 3.1 The oracle is the whole-model reference, not a per-job re-run

TRACK REF9B's `ref/run9b --acts bfp` writes a `.r9bs` stream of 491 seams per
token in the hardware's own INT4 + int16-BFP format, and its subsystem-A jobs
are bit-exact against `ref/matvec_int4.c`. **A BFP seam is int16 mantissas plus
one shared exponent, which is exactly the card's `x` and `y` format**, so the
comparison is EXACT and not a tolerance.

That is what makes this track worth more than 249 independent jobs: the
expectations come from a stream that already knows what a whole token looks
like, so the layer OUTPUT has something to be compared against.

### 3.2 Two modes, and the second one is the point

| mode | what supplies each job's `x` | what it isolates |
|---|---|---|
| `anchored` | the reference seam, for every job | a divergence is attributable to ONE job; nothing propagates. The CONTROL. |
| `chained` | only the LAYER INPUT is the reference's; every other `x` comes from the CARD's own previous output, through host norm / SwiGLU / residual | the composition. **A column of green jobs and a wrong layer output is exactly the outcome this exists to be able to report.** |

**Chaining makes self-consistency easy and meaningless**, so the comparison is
never against the previous job: always against `ref/run9b`'s stream. And the
layer-output mismatch is a **FAIL**, not a footnote:

```python
elif layer_out is not None and not layer_out["ok"]:
    verdict = J.Verdict.FAIL
    why = ("every job matched and the LAYER OUTPUT did not: ...")
```

### 3.3 The one re-anchor, named

For a Gated DeltaNet layer the dataflow is

```
R_X  --host norm-->  R_XN  --CARD x5-->  R_QKV.q/k/v, R_Z, R_BETA, R_ALPHA
                                              |
                                     [ GAP: subsystem B ]
                                              v
                             R_Y  --CARD-->  R_ER  --host res-->  R_X.attn
   --host norm-->  R_XN.ffn  --CARD x2-->  R_G, R_U  --host swiglu-->  R_H
   --CARD-->  R_ER.ffn  --host res-->  R_X          <-- compared to ref
```

**One gap, in a ten-job layer.** It is not filled, deliberately: re-implementing
the delta-rule recurrence on the host would be a second implementation of the
thing the project is trying to verify, and the write-up would then be measuring
my Python against run9b's C.

### 3.4 Why not one process per job

The dispatcher MEASURED and then WITHDREW a ~150 ms per-job figure: it was
`fk33_run_job.py`'s per-invocation setup, not PCIe. So this tool compiles the
oracle once, parses the 117 KB manifest once, opens the device once and reuses
all three, and it counts and times **every MMIO access by register** through a
`Meter` decorator rather than parsing prose out of another tool's output.

`fk33_run_job.py` itself is **imported, not copied and not edited** -- its
`run_job()` performs the identity checks, the CAPS/ADDR_CAP refusal, the
descriptor round trip, the activation write, the GO, the poll, the Y readback,
the THERM-255 guard and the GO_BLOCKED clear-and-read, once per job.

---

## 4. The procedure, in the order it was run

Each step controls for exactly one thing.

1. **Read `hw/fk33/host/fk33_run_job.py` end to end before writing anything.**
   Controls for: writing a second register protocol. Result: none was written;
   `run_job()` is called per job.
2. **Read `tools/gen_layer_program.py` before writing a program.** Controls for:
   writing a second layer program. Result: none was written -- `build_plan`,
   `layer_slice`, `lmhead_windows`, `place_desc_arena` and `QWEN35_9B` are all
   called. **The brief's guess was right: the program already existed and the
   gap was host-side execution and comparison.**
3. **Compare the card's manifest against the reference's, file by file.**
   Controls for: comparing the card against a reference built on different
   bytes. This is step 3 and not step 8 because everything downstream is
   meaningless if it fails.
4. **Read the seam names out of `ref/run9b.c` itself** (`layer_gdn` `:576-715`,
   `layer_attn` `:730-849`) rather than from the spec. Controls for: a mapping
   that agrees with a document and not with the artefact.
5. **Re-run every job on the host through `ref/matvec_int4.c`** from the
   reference's own source seam, and require the reference's own destination
   seam back. Controls for: THE HOST. If this passes and the card disagrees,
   the disagreement is the card's.
6. **Drive every host non-matvec step from the reference's own input seam and
   require its own output seam back.** Controls for: attributing a host
   arithmetic error to the card. This is the gate on `--mode chained`, and
   `run` refuses chained mode if it fails.
7. **Run the dry run.** Controls for: a tool that has never executed its own
   sequencing. It found two real defects in itself immediately (section 8).
8. **Inject nine faults and require the stated verdict.** Controls for: a
   checker never shown to fail.
9. **`strace` every no-card path.** Controls for: an accidental `/dev/xdma*`
   open, which is the one thing an agent must never do.

---

## 5. The evidence, as raw captured output

### 5.1 The card's bytes ARE the reference's bytes

```
$ python3 -c "... compare the two manifests ..."
noembd 250 qkvpad 251 common 250
only in qkvpad: ['token_embd.weight.mv4i']
only in noembd: []
digest differs on 0 files: []
no digest: 0
```

### 5.2 The layer program, and where each job's numbers come from

```
$ hw/fk33/host/fk33_run_layer.py plan --layer 0 --ref ref_L0_3.r9bs \
      --ref-manifest .../qwen35-9b-mv4i-qkvpad/manifest.json
layer       0 of 32, Gated DeltaNet block
program     16 steps in the layer, 10 of them subsystem-A jobs
arena       0x1FFADD000, 311 slots of 512 bytes, from tools/hbm_map.py

  #   tensor                     rows     cols    reads          writes          row0     ns
  0   attn_qkv.weight            2048     4096    R_XN-0         R_QKV.q-0          0      5
  1   attn_qkv.weight            2048     4096    R_XN-0         R_QKV.k-0       2064      6
  2   attn_qkv.weight            4096     4096    R_XN-0         R_QKV.v-0       4128      6
  3   attn_gate.weight           4096     4096    R_XN-0         R_Z-0              0      4
  4   ssm_beta.weight            32       4096    R_XN-0         R_BETA-0           0      4
  5   ssm_alpha.weight           32       4096    R_XN-0         R_ALPHA-0          0      5
  6   ssm_out.weight             4096     4096    R_Y-0          R_ER-0             0      6
  7   ffn_gate.weight            12288    4096    R_XN.ffn-0     R_G-0              0      4
  8   ffn_up.weight              12288    4096    R_XN.ffn-0     R_U-0              0      6
  9   ffn_down.weight            4096     12288   R_H-0          R_ER.ffn-0         0      4

compute     142848 weight beats over the layer; at the MEASURED 21.6 core cycles per beat
            that is 15.4 ms at 200 MHz -- a LOWER BOUND, matvecs only
```

The qkv `row0` values 0 / 2064 / 4128 are the PADDED starts read out of the
manifest's `segments`; the logical rows are 0 / 2048 / 4096 and
`2048 mod 48 = 32`, so two of the three would be inexpressible without the pad.
The mapping is a lookup, never a re-derivation.

### 5.3 Every job of four layers reproduces the reference, on the host

```
host re-run of every job through ref/matvec_int4.c, from the reference's
own source seam (1.12 s).

  #   tensor                       mant!=    y_exp     ns verdict
  0   attn_qkv.weight                   0       ok      5 ok
  1   attn_qkv.weight                   0       ok      6 ok
  2   attn_qkv.weight                   0       ok      6 ok
  3   attn_gate.weight                  0       ok      4 ok
  4   ssm_beta.weight                   0       ok      4 ok
  5   ssm_alpha.weight                  0       ok      5 ok
  6   ssm_out.weight                    0       ok      6 ok
  7   ffn_gate.weight                   0       ok      4 ok
  8   ffn_up.weight                     0       ok      6 ok
  9   ffn_down.weight                   0       ok      4 ok
  coverage    10 of 10 jobs re-run and compared, 0 differ
```

Across `--layer 0 1 2 3`: `10, 10, 10, 7` jobs, `0 differ` on every one, and
`plan consistent` four times. Layer 3 is an attention block and exercises the
other tensor set (`attn_q` 8192 rows, `attn_k`/`attn_v` 1024, `attn_output`).

### 5.4 Every host non-matvec step reproduces the reference, bit for bit

```
host non-matvec steps, driven from the reference's own inputs:
  kind   produces     verdict      mant!=  d(exp)  detail
  norm   R_XN         PASS              0       0  R_X.embed -> R_XN-0
  gap    R_Y          GAP               -       -  the Gated DeltaNet block -- subsystem B, which is not on this silicon
  res    R_X.attn     PASS              0       0  R_X.embed + R_ER-0 -> R_X.attn-0
  norm   R_XN.ffn     PASS              0       0  R_X.attn-0 -> R_XN.ffn-0
  swg    R_H          PASS              0       0  R_G-0 + R_U-0 -> R_H-0
  res    R_X          PASS              0       0  R_X.attn-0 + R_ER.ffn-0 -> R_X-0
  coverage    5 checked (5 pass, 0 fail), 0 uncovered, 1 structural gaps that no host step can fill
```

**This is the load-bearing result for chained mode.** The steps are a second
implementation of six lines of `ref/run9b.c` in Python floats -- which are C
doubles, summed in the SAME sequential order, because a pairwise sum is a
different number in the last bits and the last bits are the whole comparison.
Two producers agreeing is not evidence, so they are never used on trust: `run`
refuses `--mode chained` unless this check has passed in the same invocation.

### 5.5 No no-card path opens anything under /dev

```
$ strace -f -e trace=openat ... (per command)
plan --layer 0                        -> 0 openat mentioning xdma; 0 opens under /dev
hoststeps --layer 0                   -> 0 openat mentioning xdma; 0 opens under /dev
run --layer 0 --mode chained --dry-run-> 0 openat mentioning xdma; 0 opens under /dev
selfcheck                             -> 0 xdma
```

### 5.6 The chained dry run, end to end, including the layer output

```
mode        CHAINED -- only the layer input comes from the reference; every other x is
            derived on the host from the CARD's own outputs

job 0  attn_qkv.weight              PASS   2048 rows, y_exp=10, 0.012 s
job 1  attn_qkv.weight              PASS   2048 rows, y_exp=9,  0.009 s
job 2  attn_qkv.weight              PASS   4096 rows, y_exp=9,  0.015 s
job 3  attn_gate.weight             PASS   4096 rows, y_exp=11, 0.019 s
job 4  ssm_beta.weight              PASS     32 rows, y_exp=13, 0.003 s
job 5  ssm_alpha.weight             PASS     32 rows, y_exp=11, 0.003 s
job 6  ssm_out.weight               PASS   4096 rows, y_exp=12, 0.016 s
job 7  ffn_gate.weight              PASS  12288 rows, y_exp=14, 0.039 s
job 8  ffn_up.weight                PASS  12288 rows, y_exp=13, 0.038 s
job 9  ffn_down.weight              PASS   4096 rows, y_exp=13, 0.021 s

result      10 of 10 jobs run; 10 PASS, 0 FAIL/REFUSED, 0 INCONCLUSIVE
            45120 result rows compared against ref/run9b's stream, element for element
            anchored from the reference: R_X.embed, R_Y-0
            RE-ANCHORED (the chain was broken here):
              R_Y-0            the Gated DeltaNet block -- subsystem B, which is not on this silicon
            LAYER OUTPUT R_X-0: 0 of 4096 mantissas differ from ref/run9b, exp 12 vs 12

VERDICT     PASS -- every one of the 10 matvecs in layer 0 reproduced ref/run9b's seam bit-exactly, in program order, on one open device
SCOPE       subsystem A only. ... B, C and D are not on this silicon.
            DRY RUN.  This is a statement about this tool, not about any FPGA.
```

**The simulated card REPLAYS the reference, so that PASS is a statement about
this tool's sequencing and nothing else.** It is printed as such.

### 5.7 The PCIe access COUNTS, which are the part that carries over

```
  activation writes  49152 MMIO writes    (layer 0; 36864 for layer 3)
  status polls          30 MMIO reads
  result readback    90240 MMIO reads     (2 per row, plus a Y_IDX write)
  THESE ARE NOT PCIe NUMBERS.  Under --dry-run the transport is a Python
  object ... the COUNTS are the only part that carries over.
```

**DERIVED prediction, stated so the card can refute it:** one GDN layer costs
49,152 posted MMIO writes for the activations and 135,360 MMIO accesses for the
Y readback (90,240 reads + 45,120 index writes), against **15.4 ms** of compute
(142,848 beats x 21.6 cycles / 200 MHz). **ESTIMATE**, assuming 0.3-1 us per
MMIO round trip: the readback alone is 40-135 ms, i.e. **the PCIe register path
dominates the compute by 3-10x**, and the activation write adds 15-50 ms. If
that holds, the case for subsystem D sequencing on the card is not about
saving the 150 ms that was withdrawn -- it is about the Y readback being a
per-row register read. **The card is what settles it.**

### 5.8 Nine mutations, nine bites

```
$ hw/fk33/host/fk33_run_layer.py teeth --layer 0 --ref ref_L0_3.r9bs ...
mutation                           want           got            verdict
------------------------------------------------------------------------------------
host step: norm-eps-outside        FAIL           FAIL           ok
host step: repack-bit15            FAIL           FAIL           ok
host step: swiglu-swapped          FAIL           FAIL           ok
control (clean)                    PASS           PASS           ok
one wrong mantissa in job 3        FAIL           FAIL           ok
wrong y_exp in job 7               FAIL           FAIL           ok
job 4 reports job 3's counters     INCONCLUSIVE   INCONCLUSIVE   ok
a thermal trip during job 2        INCONCLUSIVE   INCONCLUSIVE   ok
compute_halt high at job 0         FAIL           FAIL           ok

teeth       PASS
```

`selfcheck` adds 22 more rows with no model at all: the r9bs reader against
`tools/ref9b/r9bs.py` record for record (62 records, 0 disagree), the host
arithmetic against values computed a second way, the seam-pairing refusals, and
the stale-`done` check.

---

## 6. Measured and REJECTED -- do not retry

**`repack-clamped` as a host mutant. It does NOT bite, and the model was also
wrong.** Written as `if exp < 0: exp = 0` to represent the shipping RTL's
clamped repack rule. It produced `PASS` on layer 0 -- correctly, because that
clamp fires only when `amax >= 2^15` and layer 0's seams peak near 73. **But
the model does not represent the rule either:** the shipping rule is
`sh = max(0, msb_pos(amax) - 14)` on an INT Q-grid, i.e. "never shift LEFT",
and `ref/run9b.c`'s `reg_put` takes a float with no Q-grid, so it has no
analogue at all. The real disagreement is the open worklog issue
**BFP repack rule** (MEASURED elsewhere at 341 of 760 exponents differing on
quiet blocks) and **this table cannot measure it**. Replaced with
`repack-bit15`, a one-character transcription error of `ref/run9b.c:323`, which
does bite. Recorded in the source next to the mutant table rather than deleted.

**Do not write a second layer program.** `tools/gen_layer_program.py` already
emits the job sequencing, the region routing, the D header fields and the
15-window lm_head schedule. The brief said to check this before writing
anything and it was right: nothing about the program needed writing.

**Do not write a second register protocol.** `fk33_run_job.run_job()` is called
per job. Every identity check, the ADDR_CAP refusal, the descriptor round trip,
the THERM-255 guard and the GO_BLOCKED clear-and-read come with it for free,
and a copy would have drifted from it within a day.

**Do not use `numpy` in the reader.** `tools/ref9b/r9bs.py` imports numpy at
module scope; the bench host's only stated requirement so far is python3 and
`cc`. The tool carries a 30-line `struct`-based reader instead, and
`selfcheck` cross-checks the two record for record when numpy IS available, so
the duplication is measured rather than assumed.

**Do not compare against the `qwen35-9b-mv4i` or `-stackfix` sets.** Those pack
`attn_qkv` UNPADDED at `M = 8192` with a different digest
(`108a8f43...` against `760013a2...`), so the three-way qkv split is
inexpressible at `ROWS_IF = 48` and the reference does not describe them.
`--ref-manifest` refuses the mismatch.

---

## 7. Findings for other owners -- reported, not fixed

**DONE-1. Stale `done` across a sequence. `rtl/matvec_int4_desc_axi.vhd`, not
this track's file.** `done_l` is set in `S_DONE` (`:878`) and cleared only when
`S_IDLE` consumes the next GO (`:643`). Between the CTRL write and that clear
there are about three core clocks in which STATUS reports the PREVIOUS job's
completion, and a host that polls immediately would then read the previous
job's Y registers -- a wrong number with no error anywhere.

* **Why nobody has hit it:** every tool before this one ran ONE job.
* **Why it is probably harmless today:** a PCIe read cannot pass a posted write
  to the same device, and the AXI-Lite read completion is realistically >= 100 ns
  against ~15 ns of fabric. **That is an accident of timing with about 10x of
  margin, not a construction.**
* **Host mitigation, in this tool:** `stale_done_check()` requires the engine's
  own `BEATS` (cleared at `S_IDLE` on the same GO) to equal this job's
  `tiles * nblk`; a mismatch makes the job INCONCLUSIVE rather than PASS.
  **It is BLIND when two consecutive jobs have the same shape** -- in a 9B
  layer `ffn_gate` and `ffn_up` are exactly that pair, so the check is blind on
  one adjacency in ten. Stated, not hidden.
* **RTL fix:** clear `done_l` on the CTRL write rather than at the next
  `S_IDLE`. **Host fix if the RTL is not to move:** poll for `busy` to RISE
  before polling for `done`. Either closes it by construction.

**DONE-2. `index.txt` did not exist for the set that is on the card.**
`ref/run9b`'s flat index existed only for `qwen35-9b-mv4i-qkvpad`. Generated
with the standard `tools/ref9b/make_index.py` for
`qwen35-9b-mv4i-noembd` (`249 mv4i, 1 blob, 177 f32 entries`); it is a
generated file next to the manifest and nothing else was touched. Reproduce it
with the command in section 9.

---

## 8. Measurement traps hit, including my own

**I nearly reported a per-job PCIe cost from the dry run.** The `Meter` prints
0.5 us per activation write under `--dry-run`, which is the cost of a Python
method call, not of PCIe. It is now labelled in the output itself, in the
branch that only fires under `--dry-run`, because a caveat that lives in a
write-up is not attached to the number when someone quotes it.

**Two defects the dry run found in this tool that no amount of reading would
have.** Both were caught on its FIRST execution:

1. `_DryBar` keyed the descriptor lookup on the `DESC_PTR_LO` write. The arena
   is at `0x1FFADD000` -- **33 bits** -- so the low half alone matched nothing
   and job 0 came back with all 2048 mantissas wrong. Moved to the HI write.
2. The chained dependency resolver was one level deep. It ran the whole layer
   and then raised `KeyError: 'R_X.attn-0'` three steps from the end, because
   the second residual needs `R_X.attn`, which needs `R_ER`, which the card had
   produced. Made recursive.

**A model artefact that looked like a second defect.** The first `trip:2` run
reported TWO inconclusive jobs, because `_DryBar` was zeroing the simulated trip
counter between jobs, so job 3 saw it go `1 -> 0`. The tool was right (a counter
that moves in EITHER direction across a job invalidates it); the model was
wrong. Fixed in the model, noted in the source, and worth repeating: **when a
teeth row bites harder than expected, suspect the mutant before the checker.**

**`plan` costs 1.2 s and re-runs 244 MMAC.** That is cheap enough that the
no-hardware numeric check is not a luxury; it should be run before every card
run, and section 9 does.

---

## 9. Copy-pasteable commands for the bench

Run these in order. Every one before step 4 is safe for anyone; **steps 4 and 5
open `/dev/xdma*` and are Oren's alone.**

```sh
cd ~/GitHub/llama.vhdl
S=$HOME/layerrun            # any writable scratch dir
mkdir -p $S
```

**Step 0 -- the reference stream (once; ~4 s, ~1.5 GB RSS for 4 layers).**

```sh
gcc -O2 -Wall -I ref -o $S/run9b ref/run9b.c -lm
$S/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad \
         --embed mv4i --tokens 760 --layers 4 --out $S/ref_L0_3.r9bs
```
Expect: `TOKEN 0 id=760  (partial, 4 layers)  3.53 s` and
`wrote ... 62 records`. If it dies on a missing index, run
`python3 tools/ref9b/make_index.py /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad`
first. `--layers 4` covers layers 0-2 (Gated DeltaNet) and 3 (attention);
raise it for a different layer. **`--embed mv4i` is deliberate**: it avoids
loading the 17.9 GB BF16 GGUF and the stream stays self-consistent either way.

**Step 0b -- the flat index for the set that is on the card (once).**

```sh
python3 tools/ref9b/make_index.py /mnt/storage/llama-models/qwen35-9b-mv4i-noembd
```
Expect: `wrote .../index.txt: 249 mv4i, 1 blob, 177 f32 entries`. Already done
tonight; the command is idempotent.

**Step 1 -- prove the checks bite (no card, ~7 s).**

```sh
python3 hw/fk33/host/fk33_run_layer.py teeth --layer 0 \
    --ref $S/ref_L0_3.r9bs \
    --ref-manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json \
    --scratch $S/w
```
Expect the nine-row table of section 5.8 and `teeth PASS`.
**Failure mode:** any `MISMATCH` row means a check in this tool has stopped
working, and no card result should be believed until it is fixed. A row
appearing under `ROWS THAT DO NOT BITE` is a measurement, not a failure -- read
it, do not delete it.

**Step 2 -- validate the whole layer numerically, with no card (~1.2 s).**

```sh
python3 hw/fk33/host/fk33_run_layer.py plan --layer 0 \
    --ref $S/ref_L0_3.r9bs \
    --ref-manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json \
    --scratch $S/w
```
Expect the job table of section 5.2, then
`coverage 10 of 10 jobs re-run and compared, 0 differ`, then
`coverage 5 checked (5 pass, 0 fail), 0 uncovered, 1 structural gaps`, then
`plan consistent`.
**Failure modes:** `the card's packed set and the reference's are not the same
bytes` means step 0 used the wrong packed dir. `seams X -> Y imply ns = -N`
means the seam map is wrong for this layer -- stop, do not run the card.
`N differ` in the host re-run means the mapping or the segment lookup is wrong,
and the card would be compared against the wrong numbers.

**Step 3 -- the dry run, which proves the sequencing without a card (~2 s).**

```sh
python3 hw/fk33/host/fk33_run_layer.py run --layer 0 --mode chained --dry-run \
    --ref $S/ref_L0_3.r9bs \
    --ref-manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json \
    --scratch $S/w
```
Expect ten `PASS` job lines, `LAYER OUTPUT R_X-0: 0 of 4096 mantissas differ`,
`VERDICT PASS`, and the two lines saying it is a statement about the tool and
not about any FPGA. Exit status 0.

**Step 4 -- THE CARD, anchored first. Oren only.**

Clear the thermal counter first, so "it did not move" can be observed:

```sh
sg fk33 -c 'python3 hw/fk33/host/fk33ctl.py thermal --clear'
sg fk33 -c 'python3 hw/fk33/host/fk33_run_layer.py run --layer 0 --mode anchored \
    --ref '"$S"'/ref_L0_3.r9bs \
    --ref-manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json \
    --scratch '"$S"'/w'
```

`sg fk33 -c` is not optional decoration: **group membership is read at login**,
so `id -nG` describes the PROCESS and `getent group fk33` the ACCOUNT, and a
long-lived shell is not in the group even though the account is. Without it the
tool prints that diagnostic rather than an opaque permission error.

Expect, per job, `PASS  <n> rows, y_exp=<e>, <t> s`, then the PCIe table with
the note that setup is amortised so what is left IS the PCIe cost, then
`10 of 10 jobs run; 10 PASS`, `45120 result rows compared`, and
`VERDICT PASS`. Exit status 0.

Failure modes, and what each means:

| what you see | what it means |
|---|---|
| `ADDR_CAP reports ADDR_W = N ... Pass --addr-w N` | the build is not 40-bit; pass what it reports. Do not assume. |
| `CAPS = 0x... decodes to ... the descriptor was built for ...` | the bitstream's geometry is not the one the packed set was packed at. Nothing further is meaningful. |
| `the engine is already in its STICKY error state` | a previous descriptor was rejected; `S_ERR` is left only by RESET. **Reload the bitstream.** |
| `GO_BLOCKED is set` / `compute_halt is asserted RIGHT NOW` | THERM-255 swallowed the GO. The job never started. NOT a subsystem-A result. |
| `INCONCLUSIVE ... the thermal trip counter moved` | THERM-255 fired across the job. Neither the mismatches nor their absence is evidence. Clear, wait, re-run. |
| `INCONCLUSIVE ... the completion may not belong to this job: BEATS=...` | the stale-`done` hazard of section 7, or `BEATS` does not mean `tiles*nblk`. Either way the answer is not attributable. |
| `FAIL ... N of M mantissas differ` | **the real result.** Run step 2 again to confirm the host side still reproduces the reference, then bisect with `--mode anchored --stop-on-fail`. |

**Step 5 -- THE CARD, chained. Oren only. This is the deliverable.**

```sh
sg fk33 -c 'python3 hw/fk33/host/fk33ctl.py thermal --clear'
sg fk33 -c 'python3 hw/fk33/host/fk33_run_layer.py run --layer 0 --mode chained \
    --ref '"$S"'/ref_L0_3.r9bs \
    --ref-manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json \
    --scratch '"$S"'/w'
```

Expect additionally:

```
            anchored from the reference: R_X.embed, R_Y-0
            RE-ANCHORED (the chain was broken here):
              R_Y-0            the Gated DeltaNet block -- subsystem B, which is not on this silicon
            LAYER OUTPUT R_X-0: 0 of 4096 mantissas differ from ref/run9b, exp 12 vs 12
```

**`LAYER OUTPUT ... 0 of 4096 mantissas differ` is the sentence that means the
sequence computed, not merely ran.** If every job says PASS and that line says
otherwise, the verdict is FAIL and the composition is wrong -- which is exactly
the outcome a per-job table cannot show and this tool exists to be able to
report.

**Step 6 -- the attention layer, which is a different tensor set.**

Repeat steps 2-5 with `--layer 3` (7 jobs: `attn_q` 8192 rows, `attn_k` and
`attn_v` 1024, `attn_output`, then the three FFN jobs). Layers 1 and 2 are
further Gated DeltaNet blocks and are also validated on the host.

---

## 10. Open, not yet answered

1. **Nothing has run on the card.** Every claim here is DERIVED.
2. **Whether the card's base-advance windowing agrees with the reference's
   compute-from-row-0-and-slice.** The card expresses a row window by advancing
   every weight and scale base by whole TILES; `ref/run9b` computes
   `row0 + nrows` rows in RAW mode and slices. They agree only if the
   sub-region layout really is tile-major. **The card run is the test of it,
   and the qkv `k` and `v` jobs are where it bites.** The host re-run
   deliberately mimics the reference, so it cannot see this.
3. **The lm_head is out of scope.** It is 15 windows in RAW mode into a sampler
   the top level does not implement (REF9B's defect D1). It is not part of a
   layer and this tool does not run it.
4. **`stale_done_check` is blind on same-shape adjacencies**, i.e. `ffn_gate`
   followed by `ffn_up`. Closing it needs either the RTL fix or a host protocol
   that waits for `busy` to rise.
5. **The per-job PCIe cost is still unmeasured.** Section 5.7 gives the ACCESS
   COUNTS, which are exact, and an ESTIMATE built on an assumed round-trip
   time. The card turns it into a measurement in one command.
6. **One token, one layer, one activation vector.** Coverage of the input space
   is not coverage of the output space: this exercises one `x` per job at one
   set of exponents. It cannot reach a saturation corner, a `sat_event`, an
   `x_exp` the reference never produced, or any row count other than the shapes
   the model happens to have. TRACK AJOBRUN's 18 row counts across the
   `BLOCK`/`ROWS_IF` boundaries remain the coverage argument; this track's
   contribution is ORDER and COMPOSITION, not shape coverage.
7. **Whether a thermal trip is more likely over a layer than over a job.**
   THERM-255 fires in bursts and a layer is a much longer exposure than the
   short jobs of 2026-08-29. The counter is read per job, so the answer falls
   out of the first card run.
