# A whole token's subsystem-A matvecs, in order, against the 9B reference

**Date:** 2026-08-30. Branch `fpga`. **Track TOKENRUN.**
**Deliverables:** `hw/fk33/host/fk33_run_token.py`,
`hw/fk33/host/lmhead_raw_oracle.c`.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/*.sh` or `hw/fk33/tcl/`, and nothing opening `/dev/xdma*` --
MEASURED by `strace -e trace=openat` on all four no-card paths (section 5.6).

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

> Tonight, for the first time, **whole layers ran in sequence on the card and
> produced bit-exact outputs**: layer 0 (Gated DeltaNet, 10 A jobs) and layer 3
> (attention, 7 A jobs), **88,128 result rows compared element for element,
> zero differ**, in `chained` mode where every activation after the input is the
> card's own output.
>
> **Nothing has run a whole token.** That is the next milestone and it is
> yours.
>
> Extend LAYERRUN's approach from one layer to a full token: all layers plus the
> lm_head, in program order, on one open device, comparing against `ref/run9b`'s
> stream.

---

## 2. The answer, up front

**The tool exists, the whole token runs end to end through a simulated
transport, and everything about it that can be measured without a card has
been measured. Nothing has run on the card, because that is Oren's to run.**

**The tool:** `hw/fk33/host/fk33_run_token.py` walks **all 311 subsystem-A jobs
of one token** -- 24 Gated DeltaNet layers x 10, 8 attention layers x 7, and the
lm_head's 15 raw row windows -- in program order on ONE open device, with the
oracle compiled once, the manifest parsed once and each job's descriptor in its
own slot of the 311-slot arena; feeds each job's output where the next one needs
it **across layer boundaries**; and compares every job, every layer output, and
finally **the argmax over the card's own 248,320 logits** against `ref/run9b`'s
whole-model stream.

It does not reimplement LAYERRUN. It **imports** `fk33_run_layer.py` and calls
its `make_layer`, `bind_reference`, `host_rerun`, `check_host_steps` and
`run_layer` once per layer, and adds only what a token needs that a layer did
not: token-level chaining, the tail, the token, and the failure modes a long run
meets.

**What it covers, stated plainly because overclaiming it would be worse than
the result is good:** subsystem A only. `hw/fk33/rtl/fk33_engine.vhd`
instantiates `matvec_int4_desc_axi` and nothing else, so **B, C and D have never
run on this silicon.** The 64 RMS norms, the final norm, the 64 residual adds
and the 32 SwiGLUs run on the HOST, and the Gated DeltaNet or attention block of
**every one of the 32 layers** is a structural gap that no host step fills.
**This is the MATVEC SKELETON of a token, run in order on the card, with the
non-matvec work on the host.** There are **32 re-anchors**, one per layer,
named and counted in the output, never absorbed.

**Seven things MEASURED tonight with no hardware:**

1. **The 32-layer reference exists and costs what it costs.** `ref/run9b
   --layers 32` on the qkvpad set: **35.14 s wall, 4,450,660 KB (4.24 GiB)
   maximum RSS, 492 records, 5,976,368 B of stream**, and it picks **token
   2614** at logit 12.382477. That answers the brief's question about layer
   count directly: it fits, on a box whose `available` was 17 GiB with
   llama-server holding 18 GiB.
2. **Every one of the 296 layer jobs of a whole token reproduces the reference
   on the host, exactly.** 32 of 32 layers, **296 of 296 jobs re-run through
   `ref/matvec_int4.c` from the reference's own source seam, 0 differ**, in
   36.0 s.
3. **Every host non-matvec step of every layer reproduces the reference bit for
   bit.** 5 checked steps x 32 layers = **160 of 160 PASS, 0 uncovered**, plus
   the final norm: `R_X-31 -> R_XN.final`, **0 of 4,096 mantissas differ,
   exponent delta 0**.
4. **The lm_head reproduces the reference's logits and its token.** The whole
   248,320-row tensor in RAW mode from the reference's own `R_XN.final`:
   **248,320 of 248,320 logits identical to the stream's `LOGITS` record**, and
   the argmax by `sampler_stream`'s first-maximum rule is **2614**, which is the
   stream's `TOKEN` record. 4.2 s.
5. **The lossy direction of that comparison is EMPTY on this token.** `run9b`
   writes `LOGITS` as float32 while the card publishes raw s32, so s32 -> f32 is
   many-to-one above 2^24. MEASURED: **0 of 248,320 values have |s32| >= 2^24**,
   so on this token the comparison is exact and not merely one-directional. On a
   different prompt it need not be, which is why the count is printed every run.
6. **The whole token runs end to end through the simulated transport, in both
   modes.** `--mode chained`: **311 of 311 jobs PASS, 1,675,264 result rows
   compared element for element, 32 re-anchors, card argmax 2614 == reference
   2614**, token wall 12.969 s, 745,480 KB RSS. `--mode anchored`: the same 311
   and the same token, 0 re-anchors.
7. **Nine mutations, nine bites, and thirteen model-free checks.** Every teeth
   row is required to produce a stated verdict, including two THERM-255 rows
   that are deliberately OPPOSITE (section 6).

**What is NOT determined:** whether the card computes any of it. Every number
here is DERIVED. Section 10 is the copy-pasteable command list.

---

## 3. The design, and the four decisions that shaped it

### 3.1 The layer runner is imported, not copied

The brief said to read `fk33_run_layer.py` first and extend or wrap it. That was
right, and the same way it was right for LAYERRUN: the gap was not the layer
program and not the register protocol. `run_layer()` already takes the plan, the
reference, the token index, the registers and the transport, and already returns
the per-job results, the re-anchors, the live region values and the layer output.
Driving it 32 times against one open device, one `Meter` and one compiled oracle
IS the token, provided three things are supplied.

### 3.2 Chaining across a layer boundary, without editing anyone's file

`run_layer` seeds layer L's input from `ref[("R_X-(L-1)", tok)]`. So the whole of
token-level chaining is **two dictionaries instead of one**:

| dict | what it is | who reads it |
|---|---|---|
| `ref` | the PRISTINE stream, never mutated | every EXPECTATION |
| `ref_run` | a copy whose `R_X-(L-1)` record is replaced by the card's own | every INPUT |

After layer L closes, its `live["R_X-L"]` -- which is the card's outputs put
through the host residual -- is wrapped in a `Seam` and substituted into
`ref_run`. Layer L+1 then seeds from the card. **The comparison is never against
the previous layer**, always against `ref/run9b`, because chaining makes
self-consistency easy and meaningless.

If a layer does not close, the next layer is re-anchored to the reference **by
name**, and the run stops by default (`--keep-going` overrides): after a bad
layer everything downstream is unattributable and the bench time is real.

### 3.3 The tail: 15 raw windows, and one whole-tensor expectation

`output.weight` is 248,320 x 4,096 and `MAXROWS_BFP` is 17,408, so the schedule
emits **15 tile-aligned windows at stride 17,376** with a last window of 5,056
(TRACK LMHEAD, `a781326`; `matvec_int4_desc_axi` bounds `n_rows` in EVERY
`out_mode`, so a one-job lm_head is refused `err_code 0x3`). The window list is
NOT written here: it comes from `gen_layer_program.lmhead_windows` and the steps
come from the shipping `build_plan`, and `make_tail` REFUSES if the two disagree.

The expectation is **one whole-tensor RAW run, sliced**. That is legitimate in
raw mode and only in raw mode, and the argument is `tools/lmhead_window_oracle.c`'s:
`ref/matvec_int4.c:396` is `y_data[r] = sat32(round_shift(acc_r, out_shift))` and
`:436` is `y_exp = w_exp + x_exp - out_shift`; neither reads any row but `r`, so
raw has no cross-row term and a row's value cannot depend on how many rows were
asked for. BFP does (`:403-413` takes `ns` from a max over the job's rows), which
is why the schedule issues the lm_head raw and why the new oracle hard-codes
`MV4I_MODE_RAW` rather than offering a choice.

`hw/fk33/host/lmhead_raw_oracle.c` is a **new** file and not a duplicate of
`mv4i_job_oracle.c`: that one emits BFP int16 mantissas, because every job inside
a layer is a BFP job. The lm_head is the one A job in the token issued in RAW
mode, its payload is s32, and no path produced those numbers for a card
comparison.

It is **not** an independent oracle for the arithmetic -- it calls `mv4i_matvec`,
which is what `run9b`'s `lm_head()` calls. What ties it to the reference is a
separate step: `float32(ldexp(s32, -e))` compared **bit for bit** against the
stream's `LOGITS` record. A wrong activation or a wrong exponent shows up there
and nowhere else on the host side.

### 3.4 The token is an integer, and that is why it is the deliverable

`ref/run9b.c:396` writes `TOKEN` as S32 precisely so the one quantity that
decides a token is exactly comparable, where `LOGITS` (f32 against the card's
s32) cannot be. This tool computes the argmax over **the card's own 248,320 s32
values**, by the rule `rtl/sampler_stream.vhd` implements -- seed index 0,
displace only on a strict `>` -- and compares that integer. That single number is
what no per-job table can produce.

**And its coverage is narrow, deliberately stated:** an argmax moves only when a
logit crosses the runner-up, so a `TOKEN` agreement is silent about every smaller
error. It is the `LOGITS` row above it that carries the element-wise claim.

---

## 4. The procedure, in the order it was run

Each step controls for exactly one thing.

1. **Read `fk33_run_layer.py`, `fk33_run_job.py`, `gen_layer_program.py` and
   `gen_mv4i_desc.py` end to end before writing anything.** Controls for: a
   second layer runner, a second register protocol, a second layer program, a
   second descriptor builder. Result: none was written.
2. **Read `ref/run9b.c`'s `main()` and `lm_head()` for the tail's seam names**
   (`:494-511`, `:1066-1074`) rather than a spec. Controls for: a mapping that
   agrees with a document and not with the artefact. It is where the constraint
   "the tail exists only at `--layers 32`" came from.
3. **Read `rtl/matvec_core.vhd:805-832` for what RAW mode publishes.** Controls
   for: assuming the readback format. It is `resize(a32, 64)` -- a
   **sign-extended s32** -- and `:1031` confirms `y_exp = w_exp + x_exp -
   out_shift` with no per-job term. The expectation format was read out of the
   RTL, not guessed from the BFP case.
4. **Generate the 32-layer reference and measure it.** Controls for: asserting
   that a whole token's reference "fits" without knowing its cost.
5. **Re-run all 296 layer jobs and all 160 host steps on the host.** Controls
   for: THE HOST. If this passes and the card disagrees, the disagreement is the
   card's.
6. **Drive the lm_head oracle from the reference's own `R_XN.final` and require
   the reference's own `LOGITS` and `TOKEN` back.** Controls for: an oracle that
   agrees with itself. It also measures the resolution of the f32 comparison.
7. **Run the whole token dry, in both modes.** Controls for: a tool that has
   never executed its own sequencing over 32 layers. It found three real defects
   in itself immediately (section 7).
8. **Inject nine faults and require the stated verdict.** Controls for: a checker
   never shown to fail. Four rows disagreed on the first run and every one was a
   real fault in this file, not in the mutant (section 7).
9. **`strace` every no-card path.** Controls for: an accidental `/dev/xdma*`
   open, which is the one thing an agent must never do.

---

## 5. The evidence, as raw captured output

### 5.1 The 32-layer reference: what a whole token costs to expect

```
$ /usr/bin/time -v ./run9b --packed .../qwen35-9b-mv4i-qkvpad --embed mv4i \
      --tokens 760 --layers 32 --out ref_tok760_full.r9bs
EMBED mv4i  .../token_embd.weight.mv4i  (the PRE-2026-08-29 basis)
TOKEN 0 id=760  argmax=2614 logit=12.382477  35.06 s
  TOP0 id=2614 logit=12.382477
  TOP1 id=7193 logit=10.240387
wrote ref_tok760_full.r9bs: 492 records
        Elapsed (wall clock) time: 0:35.14
        Maximum resident set size (kbytes): 4450660
```

**4.24 GiB RSS and 35 s.** The tensors are `mmap`ed, so that is mapped file
pages and reclaimable, not anonymous. `--embed mv4i` is deliberate: it avoids
loading the 17.9 GB BF16 GGUF. The stream itself is 5,976,368 B.

### 5.2 The whole token's A program, and its DERIVED cost

```
model       Qwen3.5-9B: 32 blocks, 24 Gated DeltaNet + 8 attention, hidden 4096, vocab 248320
program     32 layers selected; 296 subsystem-A jobs in the layers + 15 lm_head windows = 311
arena       0x1FFADD000, 311 slots of 512 bytes, 311 used
lm_head     15 windows at stride 17376, last 5056 rows, covering 248320 of 248320 rows

cost, DERIVED from the MEASURED per-access rates of 2026-08-29 (0.85 us per MMIO
write, 2.88 us per MMIO read).  NOT a prediction of the whole wall time -- it omits
the status polling and every host step:
  activation writes    1536000     1.31 s
  Y index writes       1675264     1.42 s
  Y readback reads     3350528     9.65 s   <-- the term that decides the run
  of which lm_head      496640     1.43 s   (15% of the readback, one tensor)
  weight beats         5187328     0.56 s   at the MEASURED 21.6 core cycles per beat, 200 MHz
  MMIO total           6561792    12.38 s
```

**The arena is exactly full: 311 slots, 311 used.** That is not a coincidence --
`hbm_map` sized it from the FULL token program (`place_desc_arena`), and this
tool assigns every job its own slot instead of restarting the numbering per
layer as `make_layer` does. Nothing is placed outside the region `hbm_map`
checked.

**The readback dominates the compute by 22x** (12.38 s of MMIO against 0.56 s of
weight beats), and the single largest item in it is one tensor. There is no bulk
path to attack: `hw/fk33/host/fk33_regs.h` gives `Y_IDX` / `Y_LO` / `Y_HI` and
nothing else, so a row costs one MMIO write plus two MMIO reads and that is a
property of the register map. What this tool does about it is amortise
everything else -- one process, one open device, one compiled oracle, one parsed
manifest. What it deliberately does NOT do is sample the readback: that would
make the lm_head cheap and the token unfalsifiable.

### 5.3 Every job of every layer reproduces the reference, on the host

```
host re-run of every job through ref/matvec_int4.c, and every host non-matvec
step, from the reference's own seams.

  layer kind   jobs   mant!=    steps    uncov  verdict
  0     gdn      10        0      5/5        0  ok
  1     gdn      10        0      5/5        0  ok
  ...
  31    attn      7        0      5/5        0  ok
  coverage    32 of 32 layers checked, 296 of 296 jobs re-run, 0 differ, 0 host-step faults (36.0 s)
```

**Coverage is stated, not left as a tally to subtract.** `--only-layers` exists
for a fast pre-flight and prints `NOT COVERED n layer(s) were skipped` when it
is used, because a partial check is not a statement about the layers it did not
read.

### 5.4 The tail reproduces the reference, including the token

```
the tail, with no card:
  final norm  R_X-31 -> R_XN.final: 0 of 4096 mantissas differ, exp d=0 -> PASS
  lm_head     248320 rows RAW in 4.2 s, y_exp=15, sat_event=0

the lm_head oracle against the reference's own LOGITS record:
  compared    248320 of 248320 logits, 0 differ
  resolution  0 of 248320 have |s32| >= 2^24, where s32 -> f32 is many-to-one
              and this comparison cannot see a low-bit error
  TOKEN       the oracle's argmax is 2614 and the reference's TOKEN record is 2614 -> PASS

plan        consistent -- every job's seam pairing, every host step and the tail reproduce the reference
```

`resolution 0 of 248320` is the load-bearing line and it is why the comparison is
reported as exact rather than one-directional **on this token**. It is
recomputed every run rather than assumed.

### 5.5 The whole token, dry, chained

```
layer  0  gdn  10/10 jobs PASS   45120 rows   0.243 s  out MATCH
layer  1  gdn  10/10 jobs PASS   45120 rows   0.236 s  out MATCH
...
layer 31  attn  7/ 7 jobs PASS   43008 rows   0.226 s  out MATCH

the tail -- the final norm on the host, then the lm_head as 15 RAW windows on the card
  final norm  R_X-31 -> R_XN.final: 0 of 4096 mantissas differ from the reference, exp d=0
  reference   TOKEN = 2614; the oracle's own argmax over its s32 is 2614
  activation  the R_XN.final this run derived is IDENTICAL to the reference's, so the
              expectation is unchanged (oracle 4.2 s, run once)
  window 0    rows      0.. 17375  PASS         0.059 s
  ...
  window 14   rows 243264..248319  PASS         0.019 s

PCIe register traffic over the whole run, counted per access by Meter:
  MMIO reads     3357992      2.082 s     0.62 us each
  MMIO writes    3212819      1.343 s     0.42 us each
  THESE ARE NOT PCIe NUMBERS.  Under --dry-run the transport is a Python object.

result      32 of 32 layers run; 311 of 311 jobs; 311 PASS, 0 FAIL/REFUSED, 0 INCONCLUSIVE
            1675264 result rows compared against ref/run9b's stream, element for element
            token wall 12.969 s
            RE-ANCHORED 32 times (the chain was broken here):
               24 x  the Gated DeltaNet block -- subsystem B, which is not on this silicon
                8 x  the gated attention block -- subsystem C, which is not on this silicon
            DONE-1 poll witness: 0 of 311 jobs completed on their FIRST STATUS read
            THERM-255 trip counter 0 -> 0
            GUARD       0 refused GO(s) waited out and retried (0.00 s waiting, 0
                        unrecovered); 0 trip(s) across a job that ran, 0 of
                        those left a job that did not PASS
            the tail:
              final norm  reproduces the reference exactly
              lm_head     248320 of 248320 rows read back from the card
              LOGITS      the oracle matched the reference's f32 record on all of them
              TOKEN       card argmax 2614, reference 2614

VERDICT     PASS -- every one of the 311 matvecs in the token reproduced ref/run9b's
            stream bit-exactly, in program order, on one open device, and the argmax
            over the card's OWN 248320 logits is token 2614 -- the same token
            ref/run9b picked
```

**The simulated card REPLAYS the expectation table, so that PASS is a statement
about this tool's sequencing and nothing else.** It is printed as such. The
whole process cost **13.72 s wall and 745,480 KB RSS**, so the tool itself is
not a memory problem at 32 layers.

`--mode anchored` gives the same 311 and the same token in 12.567 s with 0
re-anchors.

### 5.6 No no-card path opens anything under /dev

```
$ strace -f -e trace=openat -o OUT python3 hw/fk33/host/fk33_run_token.py <cmd>
selfcheck  xdma=0  under_dev=0
plan       xdma=0  under_dev=0
teeth      xdma=0  under_dev=0
run --dry-run  xdma=0  under_dev=0
```

### 5.7 Nine mutations, nine bites

```
mutation                                                   want           got            verdict
------------------------------------------------------------------------------------------------
control (clean)                                            PASS           PASS           ok
one wrong mantissa in job 5                                FAIL           FAIL           ok
wrong y_exp in job 9                                       FAIL           FAIL           ok
job 4 reports job 3's counters                             INCONCLUSIVE   INCONCLUSIVE   ok
job 6 completes on its FIRST poll -- the DONE-1 race       INCONCLUSIVE   INCONCLUSIVE   ok
a trip across job 2 whose numbers still match -> PASS      PASS           PASS           ok
job 0's GO swallowed once, then retried -> PASS            PASS           PASS           ok
job 1's halt never clears -> the token aborts              INCONCLUSIVE   INCONCLUSIVE   ok
job 3 never completes -- A7's AR-starved port              FAIL           FAIL           ok

teeth       PASS
```

**The two THERM-255 rows are opposite on purpose**, and that opposition is the
whole content of the 2026-08-30 correction (section 6). `selfcheck` adds 13 more
rows with no model at all: the r9bs tail records, the S32-in-a-v1-file refusal,
the argmax tie rule, the f32 round trip AND its many-to-one blind spot above
2^24, the poll witness firing on `n=1 & done` and NOT on `n=1 & busy`, and the
two `LOGITS` shape refusals.

---

## 6. THERM-255: what the brief said, what it actually is, and what changed here

The brief given to this track said the trip counter tracks "proximity to an HBM
temperature code boundary" and told me to refuse a clean PASS if it moved.
**Mid-track, Oren corrected the model** (`54f45c5`,
`docs/debugging/2026-08-30_therm255-is-two-stacks-not-two-copies.md`). The
advice stood; the model behind it was wrong, and the difference changed the
design. Recording both, because the superseded belief is the part that never
survives otherwise.

**What it actually is.** `hw/fk33/build_fk33_pcieep.tcl:781-782` wires
`DRAM_0_STAT_TEMP` and `DRAM_1_STAT_TEMP` -- **two physically separate HBM
stacks** -- into `hbm_temp0`/`hbm_temp1`. `hw/fk33/rtl/fk33_thermal.vhd` made
their **equality** a validity condition and turned invalidity straight into a
halt. So the guard halted the compute domain whenever the two stacks differed by
one temperature code -- the normal condition for two dies under different load,
and guaranteed transiently at every code crossing because the two accepted values
have independent debounce counters. MEASURED there: **an idle card at code 38
halted compute 255 times against a halt threshold of 85.**

**CORRECTION, appended during this track rather than folded in.** My brief, and
the first draft of this file, said the defect was live in the tree AND in the
bitstream. **The tree was fixed while this track was running**: `a4a564c`
removed the equality term from `hbm_valid`, and `7a7ec6f` corrected the
host-side wording that called the two ports "copies" and bit 30 "a CDC fault".
**The image loaded on the card predates both**, so everything below still
applies to the run in section 10 -- but a future bitstream will not need it, and
a `GUARD` column of zeros after a reload is expected rather than lucky.

**Why a token is exposed where a layer was not.** The failure is an **abort**,
not a slowdown. `fk33_run_job.py:811` REFUSES to start a job while `compute_halt`
is asserted -- it calls `refuse()`, it does not wait -- and `G_MIN_HALT_MS` is
100, so one spurious trip holds the halt for at least 100 ms. A token is 311
sequential jobs.

**The four design consequences, all implemented:**

1. **A halt is waited out and the job is RETRIED**, not treated as fatal.
   `install_halt_retry()` binds a wrapper over `fk33_run_job.run_job` for the
   duration of a run. It is a wrapper and not an edit because `fk33_run_job.py`
   and `fk33_run_layer.py` belong to other tracks and `run_layer` resolves
   `J.run_job` at call time, so this is the only way to get a retry into the loop
   without a second copy of the register protocol.
   **The retry is safe, and that is argued rather than assumed:** `run_job`
   refuses for the guard in exactly two places, before it writes anything
   (ENGX_STAT bit 0, the live halt) and after a swallowed GO (bit 1, the
   GO_BLOCKED sticky). In both the engine never left `S_IDLE`, so no descriptor
   was consumed, no Y register moved and no region was written; the retry
   rewrites the same descriptor bytes and the same activation from host state the
   tool still holds. **Chaining does not make it unsafe**: a value enters the
   chain only after its job PASSED, and a refused job produced none.
2. **A halt is not evidence of a compute fault.** Halts and trips get their own
   `GUARD` column. A trip is allowed to make the token INCONCLUSIVE only where it
   coincides with a job whose numbers actually differ. The tool also retries a
   job the counter moved across, because a clean repeat is worth more than an
   unattributable first attempt -- and `fk33_run_job` calls such a job
   INCONCLUSIVE, which under the old model would have aborted the whole token on
   a two-stack inequality.
3. **The count is printed as a LOWER BOUND.** MEASURED 2026-08-30 by Oren: 400
   `THERM_STATUS` samples taken at job boundaries while compute was active caught
   nothing, and the trip appeared only in an idle read afterwards. This file
   samples at job boundaries too, so a halt that rises and falls inside one job's
   compute is invisible to it. Saying so is the difference between a measurement
   and a measurement trap.
4. **The latched cause is never reported as a diagnosis.** The trip capture is
   gated on `halted`/`halted_d` (`:963`), one cycle after the combinational
   `hbm_hot` rose, and samples cause and both temperatures in that later cycle --
   so a transient inequality records `CAUSE_NONE` with equal, benign
   temperatures. "cause none" does not mean "no cause".

**Detection is by register value, never by another module's wording.** The
wrapper reads `ENGX_STAT` and `THERM_STATUS` itself. A wrapper that matched on
`run_job`'s prose would stop working silently the day the prose changed, and the
thing it detects is the one condition a long run has to survive.

---

## 7. Measured and REJECTED -- do not retry

**Do not write a second layer runner, job runner, layer program, descriptor
builder or HBM map.** `fk33_run_layer.run_layer()` is called once per layer,
`fk33_run_job.run_job()` once per job, `gen_layer_program.build_plan()` and
`lmhead_windows()` for the program, `gen_mv4i_desc.build_descriptor()` for every
descriptor. The brief's guess was right for the second time in two nights: the
gap was host-side sequencing and comparison.

**Do not compare the card's raw s32 against `LOGITS` by converting the f32 to an
s32.** That is the many-to-one direction and it needs a tolerance. Convert the
s32 to f32 and compare bits: equal s32 must give an equal float, so it is exact
in the direction it is used. MEASURED: on token 760 **0 of 248,320** values
exceed 2^24, so the blind spot is empty here -- but that is a property of this
prompt and the count is printed every run rather than assumed.

**Do not run the lm_head oracle in BFP mode over the whole tensor.** BFP's `ns`
is a max over the job's rows, so a whole-tensor BFP run cannot be sliced into
windows at all and the 15 windows would legitimately carry 15 different
exponents. The oracle hard-codes `MV4I_MODE_RAW`, because offering the choice
would only offer a way to be wrong.

**Do not emit the lm_head as one job.** `matvec_int4_desc_axi`'s `S_CHECK`
bounds `n_rows` by `MAXROWS_BFP` in EVERY `out_mode` (TRACK LMHEAD, `a781326`),
so a 248,320-row descriptor is refused `err_code 0x3` in raw and BFP alike.

**Do not key the dry transport on `(layer, job_index)`.** Layer 0's job 3 and
layer 1's job 3 are different jobs, and `--inject NAME:N` has to name one of
them. The key is the **global slot ordinal**, recovered from the descriptor
address in exactly one function (`_gidx`), so both sides compute the same number
because there is only one place it is computed.

**`--upto N --no-lmhead` does NOT produce a PASS by default, and that is
deliberate.** A run that produced no token is not a token result, and a bounded
run's PASS is quotable as "the card ran a token". `--partial-ok` is the explicit
request to be judged on the layers asked for, and its PASS says
`NO TOKEN WAS PRODUCED` in the verdict line itself.

---

## 8. Measurement traps hit, including my own

**Four teeth rows disagreed on the first run and every one was a fault in this
file, not in the mutant.** Worth stating in that form, because the standing
lesson from LAYERRUN was the opposite ("when a teeth row bites harder than
expected, suspect the mutant before the checker") and it did not apply here.

1. **`bad-row`, `wrong-exp` and `never-done` all reported INCONCLUSIVE instead of
   FAIL.** The verdict ladder tested "the run stopped at layer L" **before**
   `nfail`. A run that stopped BECAUSE a job did not reproduce the reference is a
   FAIL, and calling it inconclusive buries the one result the run exists to
   produce. The FAIL branch now comes first, with the reason written next to it.
2. **`halt` (a once-swallowed GO) reported INCONCLUSIVE instead of PASS.** The
   dry transport re-armed the fault on every `DESC_PTR_HI` write, and a retry
   rewrites that register -- so the halt was permanent and the retry was
   untestable. Armed once per fault now.
3. **The poll witness reported 22 jobs for a 20-job run.** `harvest()` is called
   from two places -- `reset()` before each job and explicitly after the last one
   -- and it rescanned entries it had already counted. It now carries a scan
   position, and it does NOT clear the log, because `run_layer` reads `Y_LO`/
   `Y_HI` back out of it after the job.

**A swallowed GO costs one full `--timeout`, and that is a property of
`fk33_run_job`, not of this file.** Its poll loop has no halt check inside it, so
when the guard swallows a GO the loop spins to `--timeout` before the GO_BLOCKED
test that follows it. At the 30 s default that is 30 s per occurrence per
attempt. MEASURED in the dry model, where a manual run with the default timeout
appeared to hang and was in fact modelling this correctly. **Use `--timeout 5` on
the bench** (section 10) and treat a large `--timeout` as a THERM-255 amplifier.

**The reference's tail exists only at `--layers 32`.** `ref/run9b.c:1069` gates
`R_XN.final`, `LOGITS` and `TOKEN` on `nlayer == N_LAYER`, and the stream's
header version is `R9BS_VERSION_S32` only there too. A partial reference cannot
close a token, so the tool REFUSES with the regeneration command rather than
improvising a tail.

**`--table` in `plan` prints the per-layer table before the host re-run**, and I
initially grepped for it in the wrong place and concluded it had not printed. It
had. Noted because the same mis-read would make the coverage line look absent.

---

## 9. Findings for other owners -- reported, not fixed

**T-1. `fk33_run_job.run_job`'s poll loop should test `ENGX_STAT` bit 0.**
`hw/fk33/host/fk33_run_job.py`, not this track's file. The GO_BLOCKED test is
after the loop, so a swallowed GO costs a full `--timeout` before it is
diagnosed. Testing the live halt inside the loop would turn a 30 s stall into a
prompt refusal, and would make the retry in `install_halt_retry` cheap instead of
merely correct. **Reported, not changed**, because that file belongs to another
track and a wrapper cannot reach inside its loop.

**T-2. `fk33_run_job.run_job` calls a job INCONCLUSIVE whenever the trip counter
moved, with 0 mismatches.** That was the right rule while THERM-255 was believed
to be heat. It is a two-stack inequality (`54f45c5`), so a job whose every
mantissa and exponent still matched the reference is not evidence of a compute
fault. This file works around it by retrying and by deducting such jobs at the
token level; **the rule itself belongs to that file's owner.**

**T-3. WITHDRAWN, and fixed by someone else while this track ran.** The draft
of this section reported that `fk33ctl.py:365` prints "the two HBM temperature
copies disagreed (a CDC fault)", inheriting `fk33_thermal.vhd`'s false premise.
`7a7ec6f` corrected both host-side sites, and `a4a564c` removed the equality
term from the RTL. Recorded rather than deleted, because the loaded bitstream
still predates both and anyone reading an older capture will still see the
misleading string.

---

## 10. Copy-pasteable commands for the bench

Run these in order. Every one before step 5 is safe for anyone; **steps 5, 6 and
7 open `/dev/xdma*` and are Oren's alone.**

```sh
cd ~/GitHub/llama.vhdl
S=/mnt/storage/scratch-tokenrun          # any writable dir; needs ~12 MB
mkdir -p $S
```

**Step 0 -- the 32-layer reference (once; MEASURED 35.1 s, 4.24 GiB RSS).**

```sh
gcc -O2 -Wall -I ref -o $S/run9b ref/run9b.c -lm
$S/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad \
         --embed mv4i --tokens 760 --layers 32 --out $S/ref_tok760_full.r9bs
```

Expect `TOKEN 0 id=760  argmax=2614 logit=12.382477  35.06 s` and
`wrote ... 492 records`. **`--layers 32` is not optional**: `R_XN.final`,
`LOGITS` and `TOKEN` exist only on a full-model run, and the tool refuses without
them. If it dies on a missing index, run
`python3 tools/ref9b/make_index.py /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad`
first. `--embed mv4i` avoids loading the 17.9 GB BF16 GGUF.

**Step 0b -- the flat index for the set that is on the card (once, idempotent).**

```sh
python3 tools/ref9b/make_index.py /mnt/storage/llama-models/qwen35-9b-mv4i-noembd
```

**Step 1 -- prove the checks bite, with no model (instant).**

```sh
python3 hw/fk33/host/fk33_run_token.py selfcheck
```
Expect 13 rows and `selfcheck PASS`.

**Step 2 -- prove the checks bite against the real program (~40 s, no card).**

```sh
python3 hw/fk33/host/fk33_run_token.py teeth --upto 2 \
    --ref $S/ref_tok760_full.r9bs \
    --ref-manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json \
    --scratch $S/w
```
Expect the nine-row table of section 5.7 and `teeth PASS`.
**Failure mode:** any `MISMATCH` row means a check in this tool has stopped
working, and no card result should be believed until it is fixed.

**Step 3 -- validate the whole token numerically, with no card (MEASURED 45 s).**

```sh
python3 hw/fk33/host/fk33_run_token.py plan --table \
    --ref $S/ref_tok760_full.r9bs \
    --ref-manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json \
    --scratch $S/w
```
Expect the cost table of section 5.2, then
`coverage 32 of 32 layers checked, 296 of 296 jobs re-run, 0 differ, 0 host-step faults`,
then the tail block of section 5.4 ending `TOKEN ... 2614 ... -> PASS`, then
`plan consistent`. Exit status 0.

Failure modes:

| what you see | what it means |
|---|---|
| `the card's packed set and the reference's are not the same bytes` | step 0 used the wrong packed dir. Nothing downstream is meaningful. |
| `the reference stream carries no R_XN.final` | step 0 did not use `--layers 32`. |
| `seams X -> Y imply ns = -N` | the seam map is wrong for that layer. **Stop; do not run the card.** |
| `N differ` in the host re-run | the mapping or the segment lookup is wrong, and the card would be compared against the wrong numbers. |
| `resolution K of 248320 have \|s32\| >= 2^24` with K > 0 | the LOGITS comparison is many-to-one on K values on this prompt. Not a fault; it bounds what that row can see. |

**Step 4 -- the dry run, which proves the sequencing without a card (~14 s).**

```sh
python3 hw/fk33/host/fk33_run_token.py run --mode chained --dry-run \
    --ref $S/ref_tok760_full.r9bs \
    --ref-manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json \
    --scratch $S/w
```
Expect 32 layer lines all `out MATCH`, 15 window lines, `311 of 311 jobs`,
`TOKEN card argmax 2614, reference 2614`, `VERDICT PASS`, and the line saying it
is a statement about the tool and not about any FPGA.

**Step 5 -- THE CARD, ANCHORED first. Oren only.**

Clear the trip counter first, so "it did not move" can be observed:

```sh
sg fk33 -c 'python3 hw/fk33/host/fk33ctl.py thermal --clear'
sg fk33 -c 'python3 hw/fk33/host/fk33_run_token.py run --mode anchored \
    --timeout 5 --ref '"$S"'/ref_tok760_full.r9bs \
    --ref-manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json \
    --scratch '"$S"'/w'
```

`sg fk33 -c` is not decoration: **group membership is read at login**, so
`id -nG` describes the PROCESS and `getent group fk33` the ACCOUNT, and a
long-lived shell is not in the group even though the account is. Without it the
tool prints that diagnostic rather than an opaque permission error.

**`--timeout 5` is deliberate** (section 8): a GO the THERM-255 guard swallows
costs one full timeout before it is diagnosed, and a token is 311 chances.

DERIVED expectation: **12-20 s of MMIO** plus polling, so a run of well under a
minute if the guard stays quiet. Every job line, then the `GUARD` column, then
`VERDICT`.

**Step 6 -- THE CARD, CHAINED. Oren only. This is the deliverable.**

```sh
sg fk33 -c 'python3 hw/fk33/host/fk33ctl.py thermal --clear'
sg fk33 -c 'python3 hw/fk33/host/fk33_run_token.py run --mode chained \
    --timeout 5 --ref '"$S"'/ref_tok760_full.r9bs \
    --ref-manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json \
    --scratch '"$S"'/w'
```

**`TOKEN  card argmax 2614, reference 2614` is the sentence that means a token
computed**, on a chain in which every activation after the token input is the
card's own output, through 32 layers and 311 jobs. If every job says PASS and
that line disagrees, the verdict is FAIL and the composition is wrong -- which is
exactly the outcome a per-job table cannot show.

**Step 7 -- if step 6 is not clean, localise it. Oren only.**

```sh
# which layer: anchored mode attributes a divergence to one job
sg fk33 -c 'python3 hw/fk33/host/fk33_run_token.py run --mode anchored \
    --timeout 5 --upto 8 --no-lmhead --partial-ok \
    --ref '"$S"'/ref_tok760_full.r9bs --scratch '"$S"'/w'
# then that layer alone, with LAYERRUN's per-job table
sg fk33 -c 'python3 hw/fk33/host/fk33_run_layer.py run --layer N --mode anchored \
    --ref '"$S"'/ref_tok760_full.r9bs --scratch '"$S"'/w'
```

Failure modes on the card, and what each means:

| what you see | what it means |
|---|---|
| `ADDR_CAP reports ADDR_W = N ... Pass --addr-w N` | the build is not 40-bit; pass what it reports. Do not assume. |
| `CAPS = 0x... decodes to ...` | the bitstream's geometry is not the one the packed set was packed at. Nothing further is meaningful. |
| `the engine is already in its STICKY error state` | a previous descriptor was rejected; `S_ERR` is left only by RESET. **Reload the bitstream.** |
| `guard  the guard REFUSED this job ... retrying` | THERM-255, working as designed on this bitstream. Not heat, not a compute fault, and the run continues. Watch the `GUARD` column. |
| `the guard refused this job N times and the halt did not clear` | the two stacks are persistently unequal. Raise `--halt-wait` / `--halt-retries`. The token aborted; nothing computed is invalidated, but the run is partial. |
| `guard  the trip counter moved A -> B ACROSS this job` | a trip crossed a job that RAN. It is retried; if the retry is clean the token still PASSes and the trip shows in the `GUARD` column. |
| `DONE-1 poll witness: K of 311` with K > 0 | a job reported done on its FIRST STATUS read. MEASURED 2026-08-30: 0 in 200 trials, minimum 6 polls. K > 0 would be the first sighting and the token is INCONCLUSIVE. |
| `N job(s) never completed and never errored` | the signature of TRACK A7's outstanding-count underflow in `rtl/axi_rd_fsm.vhd`, live in this bitstream: a port stops issuing AR forever. **Reload before retrying.** |
| `every job matched and the LAYER OUTPUT did not, at layer(s) [...]` | **the real result.** A green per-job table with a wrong composition. |
| `THE TOKEN DISAGREES` | the strongest failure this tool can report. Bisect with step 7. |

---

## 11. Open, not yet answered

1. **Nothing has run on the card.** Every claim here is DERIVED.
2. **Whether the 15 lm_head windows agree ON THE CARD.** The host side proves
   they agree in `ref/matvec_int4.c` (and `tools/lmhead_window_check.py` proved
   the descriptor bases do too). What no host check reaches is whether the
   card's base-advance windowing lands on the same bytes at 27 sub-regions and
   14 window boundaries. **The card run is the test of it**, and windows 1..14
   are where it bites.
3. **Whether all 15 windows report the SAME `y_exp` on the card.** RAW mode's
   `y_exp = w_exp + x_exp - out_shift` has no per-job term, so they must. The
   tool compares each window's `y_exp` against that one value; a disagreement
   would be a finding about `matvec_core`, not about the schedule.
4. **The retry's safety is ARGUED, not measured on hardware.** The argument is
   that a refused GO leaves the engine in `S_IDLE` so nothing advanced. It
   follows from `run_job`'s refusal sites and `fk33_engine`'s CTRL mask; it has
   never been exercised against a real swallowed GO.
5. **The trip count UNDERCOUNTS and cannot be made complete from the host.**
   Sampling at job boundaries misses a halt that rises and falls inside one job.
   Closing that needs either a counter the RTL latches per job or a sampler
   thread, and neither exists.
6. **B, C and D are still not on this silicon.** 32 re-anchors is the honest
   size of the gap: this is the matvec skeleton of a token, and the recurrence,
   the attention and the sequencing are all still host-side or absent.
7. **One token, one position, one prompt.** Coverage of the input space is not
   coverage of the output space. This exercises one activation per job at the
   exponents token 760 happens to produce; it reaches no saturation corner
   (`sat_event = 0` on the lm_head), no `x_exp` the reference never produced,
   and no row count other than the shapes the model has. TRACK AJOBRUN's 18 row
   counts across the `BLOCK`/`ROWS_IF` boundaries remain the shape-coverage
   argument. This track's contribution is LENGTH and COMPOSITION.
8. **The argmax tie rule is unexercised.** The logits on this prompt are
   distinct, so agreement between the card, the oracle and `run9b` says nothing
   about ties -- and all three implement the same first-maximum rule anyway,
   which is agreement by construction, not evidence.
9. **The per-job PCIe cost of a token is still an ESTIMATE.** Section 5.2 gives
   the ACCESS COUNTS, which are exact, and a time built on the MEASURED
   single-layer per-access rates. Whether those rates hold over 311 jobs and
   6.5 M accesses is what step 5 turns into a measurement.
