# The first three seams of `rtl/llama_top.vhd`, and what a skew sweep did and did not catch

**Date:** 2026-08-28
**Build:** `llama.vhdl` branch `fpga`. New files only:
`rtl/llama_map_pkg.vhd`, `rtl/llama_top.vhd`, `sim/llama_sched_pkg.vhd`,
`sim/tb_llama_top.vhd`. Nothing existing was modified.
**Tools:** GHDL 1.0.0, **mcode** backend. `ghdl -e` produces no binary and
exits 0, so `ghdl -r <entity>` is run directly. `--std=08 -frelaxed
--max-stack-alloc=0`.
**Target:** `MODEL = QWEN35_9B`, `NCARDS = 1`, from `rtl/model_cfg_pkg.vhd`.
No synthesis was run. Every number below is a simulation count.

## The question, verbatim

> Build `rtl/llama_top.vhd`, a top level that wires together everything that
> exists, with explicit and clearly-marked stubs for everything that does not.
> Then exercise it. [...] The D-to-A seam and the D-to-B seam [...] have never
> existed. Expect defects, and expect them to be of the two classes this
> project keeps hitting: an input read unlatched across a long operation, and a
> completion signalled as a one-cycle pulse with no handshake.

Symptom numbers at the moment of asking: 0 lines of integration top level, 4
subsystems verified in isolation, 0 seams between them, `sim/regress.sh` at
72 PASS / 0 FAIL.

## The answer, up front

A top level exists and runs the **whole 491-descriptor Qwen3.5-9B token
schedule** -- 32 blocks, 24 GDN and 8 attention at `full_attention_interval =
4` -- to completion, at a scaled datapath, with the residual stream
**bit-identical across descriptor-memory latencies 1 and 2** and a schedule
that matched the plan on all 490 startable steps.

Three seam defects were found. **The skew sweep caught exactly one of them.**
That ratio is the most useful thing in this document:

| # | defect | class | found by | caught by the skew sweep? |
|---|---|---|---|---|
| 1 | `u_start` leads `job_issue` by one cycle and `job_*` is not valid during `u_start` | (a) unlatched read | reading `seq_desc_fetch.vhd` before writing the adapter | **never reached** -- prevented, not hit |
| 2 | unit A read the lock's single exponent port without owning it | (a) unlatched read | reading the code | **NO.** Measured: it is a *deterministic* wrong number |
| 3 | region-file read latency is two edges, not one; adapters consumed at k-1 | (a) unlatched read | the skew sweep, via the write-hash trace | **YES**, at completion 1 of 19 |

Defect 2 is the one worth remembering. It changes the answer -- `R_X(0)` is
`10239` with the defect and `10177` without it -- and **both values are stable
across the skew sweep**. A determinism property cannot see it. Only reading
the code did.

Neither of the two anticipated *completion-pulse* defects (class (b)) was hit,
because both real units' pulse behaviour was read out of their sources first
and converted in the adapter before anything ran. That is stated as a
prevention, not as a clean bill of health: an untested guard is not evidence.

## The procedure, in the order it was run

Each step isolates one thing. The order is deliberately "make the weak
configuration pass first", so that a later failure reads as a concurrency
property rather than as arithmetic.

1. **Read the three unit contracts before writing a line of the top level.**
   Subsystem D's handshake and descriptor format out of `seq_desc_fetch.vhd`,
   subsystem A's out of `matvec_core.vhd`, subsystem B's out of
   `gdn_block.vhd` and `tb_gdn_block.vhd`. This is where defects 1 and 2 were
   found, and neither would have been found later: both produce plausible
   numbers.

2. **Do not use `seq_top_skel`.** `grep -n "entity work\.\|component "` over
   `rtl/seq_top_skel.vhd` returns nothing: it instantiates none of the five
   real D units, has never been simulated, and its own header says so. The
   authoritative integration reference is the port map in
   `sim/tb_seq_vec_seam.vhd:510-627`, which is the only place
   `seq_desc_fetch` + `seq_opdec` + `seq_region_lock` + `seq_vec_issue` +
   `seq_vec_res` had ever been connected. `llama_top` lifts it.

3. **Build the schedule from the model config, not from prose.**
   `sim/llama_sched_pkg.vhd` emits the same step sequence as
   `sim/seq_tbl_pkg.build_table` from an arbitrary `shape_t`, encoding every
   descriptor with `seq_tbl_pkg.mk_desc` so the wire format cannot diverge.
   At the real 9B shape it emits 491 descriptors, matching the shipped table.

4. **Run one GDN block at two descriptor-memory latencies.** Latency is the
   skew axis because subsystem D prefetches: a fast memory gets the prefetch
   ahead of the units, which is the configuration that makes class (a)
   reachable by construction, and a slow memory starves the walker and
   exercises the held `start` instead.

5. **When it differed, separate the exponent path from the data path before
   looking at either.** Two observability outputs were added:
   `obs_cmp_exp`, the exponent the lock captured at each completion, and
   `obs_wsum`, a running hash over every element write. The bench records both
   per completion and reports the FIRST divergence in each. This is the step
   that turned a wall of differing values into one line.

6. **Fix, re-run, and then put the fix back to see whether it was
   load-bearing.** Step 6 is what produced the honest version of defect 2.

## The evidence

### Before any fix -- one GDN block, 19 descriptors, latencies 1 and 2

```
tb_llama_top: shape blocks=1 attn_interval=8 hidden=64 ffn=128
              -> 19 descriptors, 1 GDN blocks, 0 attention blocks
tb_llama_top: run 0 descriptor latency 1: 18 jobs issued, 19 completions
tb_llama_top: run 1 descriptor latency 2: 18 jobs issued, 19 completions
tb_llama_top: SKEW DIFFERENCE.  run 1 R_X(0) = 16321, run 0 = -16446.
tb_llama_top: SKEW DIFFERENCE.  run 1 R_X(3) = -16391, run 0 = -8198.
tb_llama_top: SKEW DIFFERENCE.  run 1 R_X(4) = -16372, run 0 = 16395.
tb_llama_top: schedule mismatches=0 skew differences=22
tb_llama_top RESULT: FAIL
```

Note `schedule mismatches=0` throughout. The sequencing was right from the
first run; only the data was wrong. A bench that checked only the schedule
would have reported success.

### The trace that localised it

```
tb_llama_top: FIRST WRITE-HASH DIVERGENCE at completion 1
              (step opcode 0, unit 0, dst 2)
```

and **no exponent divergence line at all**. Completion 1 is the first
`OP_A_JOB` of the token, `R_XN -> R_QKV` at offset 0, i.e. the q projection.
So: the data path of unit A, on its very first job, and not the exponent path.

### Defect 3, the cause

`rtl/llama_top.vhd`'s region file is a registered-read memory. An adapter
drives `ur_addr` from a clocked process, so the address is registered once
there, and the memory registers the data again. An element whose address is
issued at edge *k* is therefore readable at edge ***k+2***, not *k+1*. All
three adapters consumed at *k+1*:

```vhdl
if k >= 1 then xb(k-1) := el_rdata; end if;     -- WRONG
if k = j_cols then k := 0; st := S_EXP; else k := k + 1; end if;
```

`el_rdata` at that instant still holds whatever the port produced for the
**previous unit's last access**, which is a function of when that unit
happened to finish -- i.e. of timing. Fixed by consuming at *k-2* and running
the loop to *n+1* so the pipeline drains:

```vhdl
if k >= 2 then xb(k-2) := el_rdata; end if;
if k = j_cols+1 then k := 0; st := S_EXP; else k := k + 1; end if;
```

After the fix, same command:

```
tb_llama_top: schedule mismatches=0 skew differences=0
tb_llama_top RESULT: PASS -- 19 descriptors, 1 blocks, 2 descriptor-latency
              points, R_X bit-identical across all of them, R_X(0) = 10177
```

### Defect 2, and the measurement that made it honest

`seq_region_lock` has exactly ONE exponent read port, and it is combinational
(`seq_region_lock.vhd:378-383`). `seq_vec_issue` drives it for the D-vec ops.
Unit A needs it too: A's `y_exp` is `w_exp + x_exp - out_shift`, and `x_exp`
is the SOURCE region's captured exponent, which lives in the lock because
hazard A3's fix made the exponent part of the locked object.

The first version wired `seq_vec_issue` straight to the port and let A read
whatever it happened to be pointing at. Fixed by arbitrating the port on
`act_unit`, which is latched at `job_issue` and held for the whole job, and by
having A claim the port for its own source region at the same instant it
latches its descriptor.

**The control run.** A copy of the fixed `llama_top` with ONLY the arbitration
reverted, everything else current:

```
tb_llama_top: schedule mismatches=0 skew differences=0
tb_llama_top RESULT: PASS -- 19 descriptors, 1 blocks, 2 descriptor-latency
              points, R_X bit-identical across all of them, R_X(0) = 10239
```

`PASS`, with `R_X(0) = 10239` against the correct `10177`. **The defect
survives the determinism property intact.** It is a stable, plausible, wrong
number -- the expensive kind this repository's own `model_cfg_pkg` header
warns about in its first paragraph.

### Defect 1, prevented rather than hit

`seq_desc_fetch` drives `u_start` combinationally from `state = S_ISSUE`
(`:962`) but sets `issue_r`, `live_bank` and `jvalid_r` in the **registered**
body of S_ISSUE (`:788-794`). So `u_start` is high one cycle BEFORE
`job_issue`, and during that cycle the `job_*` outputs still decode the
PREVIOUS live bank. An adapter that latches its descriptor on `u_start`
latches the previous job's shape.

This matters most for subsystem A, which reads `n_rows`, `n_cols`, `w_exp`,
`x_exp` and `out_mode` **live** for the whole of a multi-thousand-cycle job
(`matvec_core.vhd:639, :771, :912, :932-934`). Only `out_shift` is latched
inside A, by a fix that cites this same defect class. So the register that
holds A's descriptor has to live in the adapter.

Every adapter in `llama_top` latches at `job_issue` and reads from the latch
thereafter. No run ever exercised the wrong version, so this is a design
decision supported by reading, not a measurement.

### The milestone run -- the real 9B block schedule

```
tb_llama_top: shape blocks=32 attn_interval=4 hidden=64 ffn=128
              -> 491 descriptors, 24 GDN blocks, 8 attention blocks
llama_top: *** UNIT C IS A STUB.  ATTENTION WAS NOT COMPUTED. ***
tb_llama_top: run 0 descriptor latency 1: 490 jobs issued, 491 completions,
              87944 cycles elapsed
tb_llama_top: run 1 descriptor latency 2: 490 jobs issued, 491 completions,
              175641 cycles elapsed
tb_llama_top: schedule mismatches=0 skew differences=0
tb_llama_top RESULT: PASS -- 491 descriptors, 32 blocks, 2
              descriptor-latency points, R_X bit-identical across all of them,
              R_X(0) = -4063
```

491 is the same count `sim/seq_tbl_pkg.vhd` derives for the real token, and it
is derived here independently from `llama_map_pkg.n_steps`, with an assertion
that the two agree. 490 startable steps: END_TOKEN starts nobody.

**`R_X(0) = -4063` IS NOT AN INFERENCE RESULT.** Attention is a stub, the
norm and swiglu engines are behavioural, and unit A's weights are synthetic.
The claim is exactly and only the one asked for: the machine sequenced 32
blocks and produced a value.

## Measured and REJECTED -- do not retry

* **`rtl/seq_top_skel.vhd` as the sequencer.** It instantiates nothing
  (`grep` for `entity work.` / `component ` returns zero hits), has no
  testbench, has never been simulated, and its unit interface is five scalar
  `a_start`/`b_start`/... ports rather than the `u_start(NUNIT-1 downto 0)`
  vector every real D unit uses. It compiles, and that is all it does. Do not
  wire a top level against it.

* **Latching a unit's descriptor at `u_start`.** See defect 1. `u_start` is a
  cycle early and `job_*` is stale there.

* **Consuming a region read one cycle after issuing the address.** See defect
  3. Two edges, always, because the adapter registers the address and the
  memory registers the data.

* **Relying on the skew sweep to find shared-resource defects.** See defect 2
  and its control run. A resource read by the wrong owner can be perfectly
  deterministic.

* **A block-level arithmetic oracle, today.** It would have to model Gated
  DeltaNet, gated attention, rmsnorm, swiglu and the BFP exponent discipline
  at once, and two of those five have no RTL to compare against. Written now
  it would be a reference *for the stubs*, which is worse than no reference
  because it would look like coverage. `sim/tb_llama_top.vhd` says so in its
  header and checks five properties that need no oracle instead.

## Measurement traps hit

* **`ghdl -e` on the mcode backend produces no binary and exits 0.** Known
  and documented in this repo; restating it because it cost time again.
  `ghdl -r <entity>` directly, always.

* **An entity edit silently obsoletes an already-analysed architecture.**
  After adding ports to `llama_top`, `ghdl -r tb_llama_top` failed with
  `architecture "tb" of "tb_llama_top" is obsoleted by entity "llama_top"`
  -- which reads like a broken testbench and is actually a stale analysis.
  Re-analyse the testbench after every entity change.

* **`unsigned * integer` in `numeric_std` returns a DOUBLE-WIDTH result.**
  `h := h * 31;` with `h : unsigned(31 downto 0)` produced a run-time
  `bound check failure`, not an analysis error, so it appeared as a
  simulation crash mid-run. `resize(h * 31, 32)`.

* **Two record generics are fine in GHDL 1.0** -- checked before relying on
  it, because VHDL-2008 support in 1.0 is uneven and a shape passed as twelve
  separate generics would have been much worse to read.

* **The first fix appearing not to work does not mean it was wrong.** Fixing
  defect 2 changed every value and left the run failing, because defect 3 was
  still live. The temptation at that point is to revert. What resolved it was
  adding the exponent-versus-data trace, not more fixes.

## Open, not yet answered

* Subsystem A is still `A_BEHAV`: the real `matvec_int4` is not yet
  instantiated. The D-to-A seam that exists today is the seam to a
  *behavioural* A.
* Subsystem B is still `B_BEHAV`: the real `gdn_block` is not yet
  instantiated, and the six behavioural memories it needs (recurrent state,
  state exponents, conv taps, conv weights, scalars, gate) are not written.
* The per-layer `gdn_exp_capture` obligation is not implemented. Before
  `gdn_block` may be started for a layer, the sequencer must issue exactly one
  `cap_req` per q/k/v segment carrying A's `y_exp` for that job. Nothing in
  `llama_top` does this yet, and no descriptor field carries it.
* Attention has no lane array, so there is no path from Q, K and V to an
  attention output anywhere in this repository.
* The descriptor base array past the 64-byte header is not fetched
  (`seq_desc_fetch.vhd:113-115`), so no real weight addresses reach A.
* `err_lost_beat` is declared and wired out but nothing sets it yet; the
  un-stallable producers it is meant to police (`y_we` in A, `y_valid` in B)
  only exist once the real units are instantiated.
* The region file is one flat array with one element port. That is correct
  *today* only because `seq_desc_fetch`'s `cur_unit` is a scalar and D cannot
  overlap two units. When D grows overlap it becomes a real arbiter.
  **CORRECTED in Part 2:** "one port per UNIT" was already too coarse before
  any overlap existed. Unit V is an ADAPTER in front of `NVOP` engines, and
  two of those engines driving one port slot is two drivers on one signal --
  which GHDL reported as `several sources for unresolved signal` at
  elaboration, the one member of this defect family that does stop a build.
  The port array is indexed by CLIENT (`NUNIT + NVOP` slots), not by unit.

---

# PART 2 -- the real matvec_int4 and the real gdn_block, same day

**Date:** 2026-08-28, later the same session. Appended in place rather than
filed separately, because two of the four new findings are corrections to the
"open, not yet answered" list above and one of them REVERSES a claim made in
Part 1's summary table.

## The answer, up front

Both real units are now instantiated. `matvec_int4` streams weights over five
AXI4 read masters brought out of the top level; `gdn_block` runs with the six
memories its port contract requires, at three different latencies. The whole
491-descriptor token runs with both.

Four more defects, and the pattern from Part 1 held: **two of the four were
invisible to the skew sweep and one was invisible to every property the bench
had until a new one was written for it.**

| # | defect | found by | caught by the skew sweep? |
|---|---|---|---|
| 4 | two generates driving one shared exponent-claim signal | the `exp_rd_valid` assertion added for defect 2 | **NO** -- 'X' resolves deterministically |
| 5 | `out_shift` must be 0..40 or `matvec_core` refuses the job | the run stopping with ERR_UNIT | n/a, it is a hard error |
| 6 | the residual add was discarding one whole operand on exponent grounds | swapping B's implementation and diffing per-region fingerprints | **NO** |
| 7 | the attention stub fabricated an exponent and so caused defect 6 in every attention block | the property written for defect 6 | **NO** |

## Defect 4 -- one claim signal, two drivers, and 'X' that behaves itself

Unit A and unit B both need a source exponent out of `seq_region_lock`, which
has ONE combinational exponent read port. The first version had both generates
driving one `ux_exp_region` signal.

`unsigned` is built on `std_logic`, which is a RESOLVED type. Two drivers is
therefore not an elaboration error and not a simulation error: the bits resolve
to `'X'`, `to_integer` reports a metavalue and returns 0, and unit A reads
region 0's exponent for every job. Deterministically. **The skew sweep passed.**

What caught it was the `assert exp_rd_valid = '1'` added when defect 2 was
fixed:

```
llama_top.vhd:1289:(assertion error): llama_top: unit A read region 0's
exponent before anything captured it.
```

Fixed with one claim signal per claimant (`a_exp_region`, `b_exp_region`,
`c_exp_region`) and a mux on `act_unit`, which is latched at `job_issue` and
held for the whole job.

**This is the second time a shared-resource defect survived a determinism
property in this file.** Defect 2 was the first. Treat "two things can drive
this" as a class that determinism testing does not cover, and put an assertion
on the resource instead.

## Defect 5 -- a descriptor field that is legal to WALK and illegal to EXECUTE

`matvec_core.vhd:850-867` rejects `out_shift < 0` or `out_shift > 40` at
`start`, raises `err`, and goes straight to `S_DONE`. `sim/seq_tbl_pkg.vhd`
emits `(p mod 23) - 11`, which is negative for eleven steps in every
twenty-three.

That is not a bug in `seq_tbl_pkg`: its table is walked by testbenches that
never start a real matvec, so any bit pattern is as good as another. It becomes
a bug the moment a top level executes the table. `sim/llama_sched_pkg.vhd` now
emits a legal shift.

**Not clamped in the adapter.** Clamping a descriptor field in gateware is how
a schedule and a build come to disagree silently, which is the failure mode
`seq_opdec`'s own header spends three findings on.

## Defect 6 -- the residual was ignoring half its input, and nothing could see it

**Symptom.** With subsystem B swapped between its real and behavioural
implementations, region R_Y's fingerprint changed and region R_X's did not.
Every other property passed: schedule identity, skew invariance across four
descriptor-memory latencies, no dropped writes, no lock violations.

**Cause.** The residual is a BFP add. `seq_vec_res` aligns X and ER by
exponent, so if the two exponents differ by more than the mantissa width the
smaller operand shifts out ENTIRELY. The per-step exponent trace:

```
step 0  opcode 4 dst 1  captured y_exp 3      <- the residual stream, X
...
step 7  opcode 1 dst 9  captured y_exp 14     <- subsystem B's output
step 8  opcode 0 dst 13 captured y_exp 19     <- A's projection of it, into ER
step 9  opcode 5 dst 0  captured y_exp 42     <- the residual X + ER -> X
```

X at 3 and ER at 19 is sixteen binary places apart against a 16-bit mantissa.
The whole of A's and B's contribution vanished into the alignment shift. The
machine sequenced the token perfectly and computed with one operand.

**The cause is the STIMULUS, not the RTL.** `w_exp` came from the same
step-index formula `seq_tbl_pkg` uses, `((p*7) mod 61) - 30`, which spans sixty
binary places. Narrowed to `(p mod 5) - 2`. The cost is stated in the source:
a stale `w_exp` capture is now wrong by at most 4 instead of by up to 60, so
this stimulus is a weaker mutation detector than `seq_tbl_pkg`'s. That is the
right trade for a table that is EXECUTED rather than walked.

**After the fix, R_X's fingerprint changes when B's implementation changes**
(38682 vs 52685 at one GDN block), which is the property that says the GDN path
carries data end to end.

**A NEW PROPERTY, because the roundabout instrument that found it is not one
anybody will re-run.** P6 in `sim/tb_llama_top.vhd` watches the residual's two
operand exponents at every `v_taken`, and fails the run if they are more than
`MANT_W-2` apart. Verified to FIRE on the original stimulus, which is the only
way to know a property is load-bearing:

```
tb_llama_top: the residual at step 10 has operand exponents 3 and 42, 39 apart
against a 16-bit mantissa.  One operand shifts out ENTIRELY: this add ignores
half its input.
```

## Defect 7 -- a stub with a fabricated scale is two failures, not one

With P6 in place and both real units in, four residuals were still degenerate,
all in attention blocks: `operand exponents -31 and -6, 25 apart`.

The attention stub wrote `y_exp = 0` by fiat. Its VALUES are meant to be
obviously wrong -- that is the point of the stub -- but a fabricated EXPONENT
puts its output on a scale nothing else in the token shares, so the next
residual discards one of its two operands. That is a second, invisible failure
layered on top of the intended, visible one, and it contaminates the numeric
behaviour of every later block for reasons that have nothing to do with
attention being missing.

Fixed: the stub reports its SOURCE region's exponent, read from the lock like
any other unit. Its values remain the deliberately impossible `-32768 + i`
ramp. Degenerate residuals went 4 -> 0.

**Rule worth keeping: a stub must be wrong in its VALUES and correct in its
CONTRACT.** Scale is part of the contract.

## What subsystem B needed that nothing had ever provided

Three things, none of which any descriptor field expresses:

1. **Six memories at three different latencies.** `st_*` is a registered-read
   BRAM; `se_*` is **combinational**, address to data in one cycle; `cv_*` is
   registered ADDRESS with combinational DATA. Building `se_*` as a one-cycle
   BRAM by analogy with `st_*` is the obvious mistake and `gdn_block`'s own
   port comment warns about it.
2. **The exponent-capture obligation.** Before B may be started for a layer,
   exactly one `cap_req` per q/k/v segment must have been issued carrying
   subsystem A's `y_exp` for that projection. This is a contract between A and
   B that the descriptor format has no field for; `llama_top` records the
   three exponents at `cmp_valid` and replays them into `gdn_exp_capture`
   before `start`, using the segment inferred from `dst_off` against the same
   two boundaries `seq_opdec`'s MSEG mechanism uses.
3. **Completion is `busy` falling, not `done`.** `gdn_block`'s `done` is a
   one-cycle pulse with no ack. `busy` is a level that falls one cycle later,
   and `tb_gdn_block.vhd:618-621` polls `busy` for exactly this reason. The
   adapter also has to wait for `busy` to RISE first: waiting for it to fall
   without that completes instantly.

## Measured and REJECTED -- do not retry (Part 2)

* **A SUM as a region fingerprint.** The behavioural norm removes the mean, so
  every post-norm region sums to nearly zero BY CONSTRUCTION and two completely
  different vectors give the same total. Region R_XN summed to -45 in both
  configurations under test while its contents differed. Use a positional hash
  (`h := h*31 + v`), not a sum. This directly produced a wrong intermediate
  conclusion during defect 6.
* **Element 0 as a fingerprint.** `R_X(0)` was identical (-24349) between two
  configurations that differed across the region. It is fine in the PASS line
  as a human-readable landmark; it is useless as the thing you compare.
* **Clamping `out_shift` in the adapter.** See defect 5.
* **Giving a stub a fabricated exponent.** See defect 7.

## Measurement traps hit (Part 2)

* **`unsigned` is a resolved type, so two drivers is silent.** No elaboration
  error, no simulation error, just `'X'` and a metavalue warning buried in
  thousands of identical `numeric_std` warnings.
* **VHDL's universal integer is 32-bit and overflows at run time, not at
  analysis.** `idx*7919` in the AXI slave model with a 24-bit word index
  aborted the 491-step run with `overflow detected` pointing INSIDE the
  stimulus function, which reads like a broken AXI slave. Reduce the index
  before the multiply.
* **A string in a report can fail a regression run.** `sim/regress.sh`'s
  `FAIL_RE` includes the literal `IS NOT`, and the banner said "THIS IS NOT AN
  INFERENCE ENGINE YET". The testbench passed and the runner called it FAIL.
  Check new report text against `FAIL_RE` before adding it.
* **A property that has never fired is not evidence.** P6 was deliberately
  re-run against the original wide-exponent stimulus to confirm it fires, with
  the expected numbers, before being trusted.

## CORRECTION to Part 1

Part 1's table said defect 2 was the only one the skew sweep could not see.
That was true of the three defects known at the time and is **withdrawn as a
general statement**: of the seven defects now found in this file, **four**
(2, 4, 6, 7) were invisible to it. The skew sweep catches lost beats and stale
pipeline reads. It does not catch anything that is wrong in the same way on
every run -- shared resources, fabricated scales, and operands that shift out.

## Defect 8 -- the scales do not track across blocks, and it only shows up at scale

> **PARTLY WITHDRAWN 2026-08-28, see PART 3 and its CORRECTION.** The
> OBSERVATION below stands. The EXPLANATION below -- that subsystem B's
> fixed-scale stand-in inputs are the cause -- was a hypothesis, it was
> tested, and it is wrong. So is the claim that the missing token loop blocks
> the experiment. Read PART 3 before acting on anything in this section.

**Found after the Part 2 fixes were already in, by running more blocks.**
Real A, real B, `attn_interval` 4, P6 counting residual adds whose two operand
exponents are more than a mantissa width apart:

```
BLOCKS =  4   degenerate residuals = 0    PASS
BLOCKS =  8   degenerate residuals = 3    FAIL
BLOCKS = 32   degenerate residuals = 46   FAIL   (of 64 residual steps)
```

**The trend is the finding, not the failure.** Subsystem B's output exponent
is anchored to ITS OWN inputs, and its conv taps, conv weights and scalars are
stand-ins at a fixed scale rather than regions subsystem A produced. The
residual stream's exponent moves as the token progresses. The two drift apart,
and once they are more than a mantissa width apart the residual silently
discards one operand.

**Nothing in the design makes the block-to-block SCALE track**, and nothing was
ever going to notice that except a whole-token integration run: every unit is
internally consistent, every handshake is honoured, and the failure is a
property of the composition over many blocks.

It is NOT established whether this is an artefact of the stand-in stimulus or a
real hole in the BFP discipline. Both are plausible and the experiment that
separates them -- sourcing B's conv taps and scalars from R_QKV, R_BETA and
R_ALPHA -- has not been run. **Do not assume it is only the stimulus.**

The bench's default is `BLOCKS = 4` because that is the largest configuration
whose numeric behaviour is currently defensible. That is stated in the bench
header, in its PASS line, and here, so that a green regression run cannot be
read as a claim about a 32-block token.

## Open, not yet answered (updated)

* The CONTENTS of B's conv taps, conv weights, four scalars and ssm_norm
  weight are still deterministic stand-ins, NOT sourced from R_QKV, R_BETA and
  R_ALPHA. Only `z`, the output gate, is read from a real region (R_Z). Wiring
  the rest is what remains before the GDN path carries real numbers, and the
  conv tap memory in particular is a per-token HISTORY `KCONV` deep, which
  needs a token loop this file does not have.
* A's weights are synthetic: the descriptor base array past the 64-byte header
  is still not fetched (`seq_desc_fetch.vhd:113-115`).
* Attention still has no lane array.
* The norm and swiglu D-vec engines are still behavioural. Real `rmsnorm_rs`
  and `swiglu` exist in rtl/ and neither has a `seq_vec_issue` adapter.
* There is still no block-level arithmetic oracle, and there cannot be one
  until the two stubbed engines and attention are real.
* One token only. `tk0` is hardwired to '1' and there is no token loop, so B's
  recurrent state is exercised for a first token and never for a continuation.
* **The block-to-block scale, defect 8.** This is the largest open item: at 8
  blocks the machine already discards an operand in 3 residual adds, and at 32
  it does so in 46 of 64. Until it is resolved, "the machine sequenced 32
  blocks and produced a value" is true and "the value means anything" is not,
  for a second reason on top of attention being stubbed.

---

# PART 3 -- defect 8 resolved: it is the design, not B's stimulus

**Date:** 2026-08-28, later the same session. Appended in place. This part
answers the question Part 2 left open and **WITHDRAWS the explanation Part 2
gave for defect 8**; the correction is at the end of this part.

**Build:** branch `fpga`. Modified: `rtl/llama_top.vhd` (two new generics,
`B_SRC_REAL` and `NORM_ANCHOR`, both default FALSE, plus the prefetch states
and the two exponent asserts they need) and `sim/tb_llama_top.vhd` (the two
generics passed through, and one `RESGAP` observability line behind
`VERBOSE`). Nothing else. **Tools:** GHDL 1.0.0 mcode, `--std=08 -frelaxed
--max-stack-alloc=0`; Vivado 2023.2 for the one synthesis number, part
`xczu3eg-sfvc784-1-e`.

**Every simulation number below is at `NRUNS = 1`.** P6's counter is
cumulative across runs and is NOT reset between them, so a count is only
comparable against another count taken at the same `NRUNS`. See the traps
section.

## The question, verbatim

> `rtl/llama_top.vhd` runs the 491-descriptor Qwen3.5-9B token schedule with
> the real `matvec_int4` (subsystem A) and the real `gdn_block` (subsystem B).
> Property P6 counts residual additions whose two operand exponents are more
> than a mantissa width apart, so that one operand is silently shifted out
> entirely. Measured, `attn_interval` 4:
>
>     BLOCKS =  4   degenerate residuals =  0   PASS
>     BLOCKS =  8   degenerate residuals =  3   FAIL
>     BLOCKS = 32   degenerate residuals = 46   FAIL   (of 64 residual steps)
>
> Subsystem B's output exponent is anchored to its OWN inputs. Four of B's six
> memories are stand-ins at a fixed scale rather than regions subsystem A
> produced: only `z` (the gate) comes from a real region, R_Z. The residual
> stream's exponent moves as the token progresses. The two drift apart.
>
> **Your job is to determine which of these is true, and to prove it rather
> than argue it:**
>
> - **(a) Stimulus artefact.** B's inputs are fixed-scale stand-ins, so its
>   output exponent cannot track. Source them for real and the drift
>   disappears.
> - **(b) A real hole in the BFP discipline.** Nothing in the design makes the
>   block-to-block scale track, and no per-unit property can see it because
>   every unit is internally consistent and every handshake is honoured. It
>   only appears in composition over many blocks.

## The answer, up front

**It is (b).** Sourcing subsystem B's activations from the real regions makes
the count slightly WORSE, not better (0/3/10/23 -> 3/5/11/24 at 4/8/16/32
blocks), and the drift is present in the FFN residual, which contains no
subsystem B at all. The hole is that **nothing in the block loop ever restores
the activation scale**: a matvec's output exponent is its source's, minus
`(out_shift - w_exp)`, minus its own data-driven normalisation shift `ns`
(`matvec_core.vhd:876, :932-934`), so it only ever FALLS, and the one unit
whose output is scale-free by construction -- rmsnorm -- is a behavioural
model here that passes its input exponent straight through. Give the norm
model rmsnorm's scale property and nothing else, and the degenerate count is
**0 at 4, 8, 16 AND 32 blocks**, with the residual stream exponent bounded in
[-4, +8] instead of marching to -387.

## The procedure, in the order it was run

Each step isolates one thing, and each has a control measured in the same
session against the same GHDL library.

1. **Reproduce the reported numbers before changing anything.** At `NRUNS = 1`:
   4 -> 0, 8 -> 3, 16 -> 10, 32 -> 23. The 16-block point is new; the 32-block
   point is 23 and not 46, which is the `NRUNS` accumulation trap, not a
   disagreement (46 = 2 x 23).

2. **Add ONE observability line, not a property.** `RESGAP`, behind `VERBOSE`:
   the residual's two operand exponents and their difference at EVERY
   `v_taken`, not only at the ones that fail. P6 says a residual discarded an
   operand; the whole series says whether the gap is a step, a random walk or a
   trend, and that distinction is the whole question.

3. **Run the experiment the question names.** Source B's conv taps from R_QKV,
   alpha from R_ALPHA and beta from R_BETA, each carrying that region's
   captured exponent, under a generic `B_SRC_REAL` so the control and the
   treatment are the same binary.

   **The conv-tap history did NOT block this**, contrary to the warning in
   Part 2's open list. `gdn_exp_capture` masks every tap older than the number
   of captures, and `gdn_conv` ZEROES a masked tap rather than skipping it
   (`gdn_conv.vhd:310-315`), so at `tk0` -- which is all this file has -- only
   tap `KCONV-1` is ever summed. Tap `KCONV-1` is R_QKV and the older taps are
   zero, which is what the first token of a sequence actually IS. Nothing was
   faked.

   The conv WEIGHTS, `ssm_dt_bias`, `ssm_a` and the `ssm_norm` weight were
   deliberately LEFT at a fixed exponent. They are learned constants, they have
   no region, and a fixed scale is what a weight has. Sourcing a weight from an
   activation region would have answered a different question and would have
   made the result uninterpretable.

4. **When the treatment did not fix it, attribute it.** A mutant with the taps
   sourced for real and alpha/beta left as stand-ins, to separate the two.

5. **Then test the mechanism the trace pointed at, not the one the earlier
   text asserted.** The `RESGAP` series showed the FFN residual -- which never
   touches B -- drifting at the same rate as the mixer residual. That rules B
   out entirely and points at the residual stream itself. `NORM_ANCHOR` is the
   probe: it gives the norm model rmsnorm's ONE scale property (mantissas
   renormalised to full scale, output exponent a constant, scale-free in the
   input) and nothing else about rmsnorm.

6. **Teeth-check every property relied on**, against a deliberately broken copy
   of the design, in a configuration where the unbroken design passes.

## The evidence

### The control, and the treatment the question asked for

Degenerate residuals, real A and real B, `attn_interval` 4, `NRUNS = 1`:

| BLOCKS | control (B stand-ins) | `B_SRC_REAL` (taps + alpha + beta) | taps only |
|---|---|---|---|
| 1 | -- | 1 | 0 |
| 2 | -- | 2 | -- |
| 4 | **0** | **3** | -- |
| 8 | **3** | **5** | 2 |
| 16 | **10** | **11** | 8 |
| 32 | **23** | **24** | 21 |

**The treatment does not fix it. It makes it worse.** Hypothesis (a) is
refuted by its own experiment.

`B_SRC_REAL` is skew-clean, so the new prefetch states are not themselves a
defect: at `BLOCKS = 2`, `NRUNS = 4`, four descriptor-memory latencies,
`schedule mismatches=0 skew differences=0`.

### The trace that killed subsystem B as the cause

The residual stream's own exponent, `ea`, at every residual step, 32 blocks:

```
control       ea:  3, 7, -2, -9, -21, -21, -31, -40, -50, -63, -63, -83, ...
                   ..., -352, -352, -361, -361, -372, -387
B_SRC_REAL    ea:  3, 11, 1, 1, -11, -11, -20, -28, -38, -42, -51, -71, ...
                   ..., -335, -335, -344, -344, -355, -370
NORM_ANCHOR   ea:  3, 8, 3, 3, 0, 0, 0, 0, 0, 0, -1, -1, -1, -1, -2, -2, ...
                   ..., -4, -4, -4, -4, -4, -4
```

Control: **linear, -6.19 per residual step, -12.4 per block, 3 -> -387 over 32
blocks, unbounded.** `B_SRC_REAL`: -5.92 per step, 3 -> -370. Same slope, same
shape. Anchored: converges to -4 and stays there for the remaining 25 blocks.

Split by which residual it is (32 blocks, control), the gap between the two
operands:

```
FFN residual   gaps: 9,12,10,10,2,2,2,12,11,9,12,10,7,11,9,8,11,9,11,11 ...
                     max 12 over all 32 blocks, ZERO degenerate
mixer residual gaps: 4,7,0,9,28,35,203,7,188,180,173,15,137,130,120,12,89, ...
                     max 448, ALL 23 degenerate residuals are here
```

**The FFN residual contains no subsystem B and it drifts too.** Its `ea` is the
same series. That is what rules B out; the treatment merely confirms it.

Within the mixer residuals, every fourth one has a small gap -- 9, 7, 15, 12,
11, 8, 11, 15 for the eight of them -- and those are exactly the ATTENTION
blocks at `attn_interval = 4`. The attention stub reports its SOURCE region's
exponent, Part 2's defect-7 fix, so it very nearly tracks: two of the eight
still land at 15 against a threshold of 14, so 2 of the 23 degenerate
residuals are attention mixers and the other 21 are GDN mixers. Every gap
above 20 is a GDN block.

### The probe, and what it establishes

`NORM_ANCHOR`, degenerate residuals, `NRUNS = 1`:

| BLOCKS | control | NORM_ANCHOR | NORM_ANCHOR + taps only | NORM_ANCHOR + full `B_SRC_REAL` |
|---|---|---|---|---|
| 4 | 0 | **0** | -- | -- |
| 8 | 3 | **0** | -- | 5 |
| 16 | 10 | **0** | -- | -- |
| 32 | 23 | **0** | **0** | 5 |

```
tb_llama_top: schedule mismatches=0 skew differences=0 degenerate residuals=0
tb_llama_top RESULT: PASS -- 491 descriptors, 32 blocks, 1 descriptor-latency
              points, R_X bit-identical across all of them, R_X(0) = 29261
              hash(R_X) = 90742
```

That is the whole 491-descriptor token, 32 blocks, real A and real B, with
every residual add having both operands inside a mantissa width. The last four
residuals of that run:

```
RESGAP issue 469 ea -4 eb  6 gap 10
RESGAP issue 475 ea -4 eb  1 gap  5
RESGAP issue 482 ea -4 eb -3 gap  1
RESGAP issue 488 ea -4 eb  1 gap  5
```

against the control's

```
RESGAP issue 469 ea -361 eb   71 gap 432
RESGAP issue 482 ea -372 eb -387 gap  15
```

**With the norm anchored AND B's conv taps sourced from R_QKV, 32 blocks is
also clean (0).** The only configuration that still fails with the anchor in is
the one that also sources alpha and beta, and that is an artefact of the
experiment, not of the design -- see the next section.

### Why sourcing alpha and beta made it worse -- an experiment limitation

With the norm anchored, the GDN mixer residual is a CONSTANT ~88 binary places
off, at every block, with no drift at all:

```
NORM_ANCHOR + B_SRC_REAL, 8 blocks:
RESGAP issue  10 ea 3 eb 91 gap 88     <- GDN mixer
RESGAP issue  16 ea 11 eb 2 gap 9      <- FFN
RESGAP issue  26 ea 2 eb 88 gap 86     <- GDN mixer
RESGAP issue  32 ea 2 eb 0 gap 2       <- FFN
```

A constant offset is not a drift, and the cause is a VALUE, not an exponent.
`gdn_scalar` computes `arg = Q(alpha) + Q(dt)`, `sp = softplus(arg)`,
`g = min(0, sp*a)` clamped at -16, `eg = exp(g)`. R_ALPHA here is subsystem A's
output through SYNTHETIC weights, so its value is order 2^15 rather than order
1; softplus is the identity in the positive tail by deliberate design
(`gdn_scalar.vhd`, defect 2 of its header), so `g` slams into the -16 clamp,
`eg` goes to nearly zero, the recurrence decays to nothing, and B's internal
rmsnorm renormalises the tiny result to a very fine exponent. The attribution
mutant confirms it: taps alone, alpha and beta left as stand-ins, gives 0
degenerate at 1 block against the full treatment's 1, and 21 at 32 blocks
against the control's 23.

**So `B_SRC_REAL` defaults FALSE, and the reason is not conservatism.** Until
subsystem A's weights are real, R_ALPHA does not contain a physically possible
alpha, and feeding it to a saturating nonlinearity produces a second failure
that has nothing to do with the question.

### The 8-bit exponent wrap, found on the way

The very large gaps -- 203, 188, 327, 448 -- are not a bigger version of the
small ones. **Subsystem B's exponent ports are 8-bit signed**
(`gdn_block.vhd:266, 281, 331, 339`: `cap_exp`, `cv_cw_exp`, `z_exp`, `y_exp`),
so once the token's scale passes -128 they WRAP. Every large gap is exactly
256 off:

```
block 12: ea  -83  eb  120   gap 203     eb-256 = -136
block 16: ea  -87  eb  101   gap 188     eb-256 = -155
block 24: ea -144  eb   -7   gap 137     eb-256 = -263
block 56: ea -343  eb  105   gap 448     eb-256 = -151  (two wraps)
```

Unwrapped, the GDN mixer gap grows roughly linearly -- 4, 7, 0, 9, 28, 35, 53,
68, 76, 83, ..., 119 -- and crosses the 14-bit threshold at block 4. So the
wrap is a real second defect, it is silent, and it is NOT what makes the design
fail: the gap has already crossed the threshold before the first wrap.

### Teeth checks -- both results, as required

**P6.** A copy of `llama_top` with ONE change, the norm model's published
exponent offset by 20 (`yexp <= v_exp_a + to_signed(vi + 20, EXP_W)`), run at
`BLOCKS = 4` where the unbroken design gives ZERO degenerate residuals:

```
tb_llama_top: the residual at step 10 has operand exponents 3 and 38, 35 apart
against a 16-bit mantissa.  One operand shifts out ENTIRELY: this add ignores
half its input.
tb_llama_top: the residual at step 16 has operand exponents 11 and 41, 30 apart
...  (fires on every residual)
```

**PASS unbroken, FAIL broken.** P6 has teeth in exactly the configuration this
part relies on.

**The two new `exp_rd_valid` asserts** (unit B reading R_BETA's and R_ALPHA's
captured exponent). A copy with the R_ALPHA claim pointed at R_KIN, which no
GDN block ever writes, run with `B_SRC_REAL`:

```
llama_top: unit B read R_ALPHA's exponent before anything captured it.
llama_top: unit B read R_ALPHA's exponent before anything captured it.
llama_top: unit B read R_ALPHA's exponent before anything captured it.
tb_llama_top RESULT: FAIL
```

and zero occurrences of that string in all four unbroken `B_SRC_REAL` runs
(4, 8, 16, 32 blocks). **Fires broken, silent unbroken.**

`RESGAP` is an observability line and not a property; it needs no teeth check,
and it was cross-checked against P6 -- every `RESGAP` line with `gap > 14` has a
matching P6 report and there are no others.

## What the design would need, costed

Four candidates. One is cheap and already planned, one is necessary but not
sufficient, two are measured and rejected.

### 1. A REAL rmsnorm on the D-vec norm op. RECOMMENDED.

This is not a new architectural element. `rtl/rmsnorm_rs.vhd` exists,
`OP_VEC_NORM` exists in the schedule and is issued 129 times per token, and the
only missing piece is a `seq_vec_issue` adapter -- already on Part 2's open
list as remaining work for a completely different reason. A real rmsnorm is
scale-free in its input by construction (`out = (x/rms(x)) * w`), so its output
exponent is fixed by the WEIGHT scale and carries no memory of the input's.
That is the entire fix.

Measured effect of the probe that models exactly that one property: degenerate
residuals 23 -> 0 at 32 blocks, stream exponent -387 -> -4.

Cost: `rmsnorm_rs` is measured at **385 LUT and 18 DSP** for the narrowed
QK-norm instance (`docs/debugging/2026-08-25_lut-budget-measured.md` line 37,
`docs/debugging/2026-08-25_b-lane-dsp-measured.md` line 24). **Treat that as a
floor, not a quote**: the D-vec instance is a different width and a different
lane count, and it was measured for subsystem C. Cycles: the norm is already in
the schedule and already costs a pass over the vector, so the marginal cycle
cost against the model it replaces is the rsqrt latency, not a new pass. **This
is the one to pick**, because it removes the cause rather than raising a
threshold, and because the budget already carries it.

### 2. Widen subsystem B's exponent ports from 8 bits to 16. NECESSARY, NOT SUFFICIENT.

Removes the wrap. Does not remove the gap: unwrapped, the gap crosses the
14-bit threshold at block 4, before the first wrap at block 12. Do it anyway --
a wrap is a silent wrong number of exactly the class this file has now paid for
four times.

**NOT MEASURED, estimated and labelled as such.** `gdn_exp_capture`'s store is
`LAYERS*SEGS*K*8` = 4,608 bits at 48 GDN layers, going to 9,216 bits; that is
under one RAMB18 either way. The rest of B's exponent path is a handful of
8-bit adds, compares and a min-tree in `gdn_conv`'s `S_PREP`, so the LUT delta
should be low hundreds. The exponent width is hardcoded and not a generic, so
this is a multi-file edit rather than a sweep, which is why it was not measured.

### 3. Widen the residual accumulator. MEASURED AND REJECTED.

`seq_vec_res` clamps the alignment grid at `min(ex,ee) + SHMAX` with
`SHMAX = ACC_W - MANT_W - 1`, so widening `ACC_W` buys alignment range
directly. Synthesised out of context, `xczu3eg-sfvc784-1-e`, `LANES=8`,
`MANT_W=16`, `EXP_W=16`, `ADDR_W=13`:

| ACC_W | SHMAX | CLB LUT | CLB FF | CARRY8 | DSP | BRAM |
|---|---|---|---|---|---|---|
| 32 (today) | 15 | 4,820 | 2,854 | 217 | 0 | 0 |
| 48 | 31 | 7,423 | 3,833 | 297 | 0 | 0 |
| 64 | 47 | 10,020 | 4,894 | 361 | 0 | 0 |

No clock constraint was applied, so these are AREA numbers only and say
nothing about whether the wider shifters still close timing -- which, on a
unit whose own header says the pipeline exists because a barrel shift and a
wide add must not be in series, is the question a real evaluation would have
to answer next.

**+5,200 LUT to double `ACC_W`, and it buys about 2.6 blocks.** The drift is
6.19 exponent per residual step and 12.4 per block, and it is linear and
unbounded, so 32 extra binary places is two and a half blocks of headroom on a
32-block model, and the 27B target is 64 blocks. Any finite accumulator loses
this race. Rejected.

### 4. A global exponent broadcast. REJECTED ON THE EVIDENCE, NOT COSTED.

The units do not disagree about the exponent. Every exponent in the trace is
correct: A's `y_exp` is exactly `w_exp + x_exp - out_shift - ns`, the lock
captures it, the residual reads it, and the arithmetic is right. What has gone
wrong is the MAGNITUDE, and broadcasting a number everybody already agrees on
changes nothing. There is nothing to cost.

## Measured and REJECTED -- do not retry (Part 3)

* **Sourcing subsystem B's activations from R_QKV / R_ALPHA / R_BETA as a fix
  for defect 8.** It is the experiment the question named and it is the right
  experiment; the result is that it does NOT fix it. 0/3/10/23 -> 3/5/11/24 at
  4/8/16/32 blocks. Do not re-run it hoping for a different answer; re-run it
  only after subsystem A's weights are real, because until then R_ALPHA's
  VALUES are the limiting factor and not its scale.

* **Sourcing alpha and beta from R_ALPHA and R_BETA while A's weights are
  synthetic.** A constant ~88-place offset in B's output exponent at every GDN
  block, because `gdn_scalar`'s softplus tail and -16 clamp turn an
  order-2^15 alpha into a shut gate. Taps alone are neutral (0 at 1 block, 21
  at 32 against the control's 23); alpha and beta are the whole difference.

* **Widening `seq_vec_res`'s `ACC_W`.** +54% LUT for 16 more places, +108% for
  32. Buys 2.6 blocks against an unbounded linear drift. Numbers in the table
  above.

* **A global exponent broadcast.** The exponents are already correct and
  already agreed. Nothing to broadcast.

* **Blaming the missing token loop for the conv taps.** The tap history is
  masked by `tvalid` and zeroed inside `gdn_conv`, so at `tk0` only the newest
  tap is summed and the missing loop is not an obstacle to sourcing it. Part
  2's open list said it was. It is not.

## Measurement traps hit (Part 3)

* **P6's counter is CUMULATIVE ACROSS `NRUNS` and is never reset.** `n_bad_res`
  is only initialised at declaration, so a 4-latency sweep reports four times
  the per-run count. That is why Part 2's 32-block figure is 46 and this
  part's is 23. 46 = 2 x 23, which the accumulation explains exactly, but the
  `NRUNS` of that earlier run was not recorded, so this is an inference and
  not a reconstruction. **A degenerate count is
  meaningless without its `NRUNS`.** Every number in this part is at
  `NRUNS = 1`. Fixing the reset was deliberately NOT done, because the P6
  counts already published would then mean something different again; stating
  the `NRUNS` is the cheaper and more honest fix.

* **`obs_cmp_exp`'s per-step trace is offset by one against `PLAN(i)`.** The
  trace is indexed by COMPLETION and the plan by ISSUE, and there is one more
  completion than issue (END_TOKEN starts nobody), so reading
  `tr_exp(i)` as step `i`'s exponent is off by one throughout. Two attempts to
  reconstruct the exponent chain from that trace produced arithmetic that did
  not close before the offset was noticed. The `RESGAP` line was added
  precisely so nothing has to be reconstructed.

* **A negative exponent here means a LARGER value, not a smaller one.** The
  convention is `value = mantissa * 2^-exponent`, stated in
  `seq_vec_res.vhd:13-15` and `gdn_scalar.vhd:80`. The stream marching from +3
  to -387 is the activation magnitude EXPLODING by 2^390, not decaying. Getting
  this backwards inverts the entire diagnosis, and it inverts which operand
  the residual discards.

* **Another agent re-analysed `rtl/weight_streamer.vhd` mid-session**, which
  invalidated the GHDL library and made every run die with
  `has changed and must be reanalysed` -- eight parallel runs all failed
  instantly and looked like a broken edit. Re-analyse and re-take the CONTROL,
  not just the treatment: a control measured against a different library is not
  a control. All the numbers in this part were re-measured after that point.

* **A `for` loop over `REGMAX` inside a clocked process is fine in simulation
  and is not RTL.** The `NORM_ANCHOR` probe folds the magnitude of the whole
  vector in one cycle. It is a probe, in a behavioural model, guarded by a
  generic that defaults false, and it is labelled as such in the source. It is
  not a proposal for how to build the unit.

## CORRECTION to Part 2

Part 2's defect-8 section, and the header of `sim/tb_llama_top.vhd` that
repeated it, said:

> Subsystem B's output exponent is anchored to ITS OWN inputs, and its conv
> taps, conv weights and scalars are stand-ins at a fixed scale rather than
> regions subsystem A produced. [...] The two drift apart

**That explanation is WITHDRAWN.** It named subsystem B as the cause. It is
not: the FFN residual, which never touches B, drifts at the same rate, and
sourcing B's activations for real makes the count slightly worse. The
observation that the scales do not track was right and the mechanism was wrong.

Part 2 also said "the conv tap memory in particular is a per-token HISTORY,
KCONV deep, which needs a token loop this file does not have", as a reason the
experiment might not be runnable. **Also withdrawn**: masked taps are zeroed
inside `gdn_conv`, so at `tk0` the history is not needed and the experiment ran
in full.

Part 2's statement that the bench default of 4 blocks is "the largest
configuration whose numeric behaviour is currently defensible" **stands, but
only for the DEFAULT configuration**. With B's activations sourced for real it
is smaller: `BLOCKS = 1` already has one degenerate residual. That is the
honest reading of why the default is what it is.

## Open, not yet answered (Part 3)

* **The recommendation is not implemented.** No `seq_vec_issue` adapter for
  `rmsnorm_rs` was written. `NORM_ANCHOR` is a probe in a behavioural model and
  proves only that anchoring the norm's SCALE bounds the drift. It does not
  prove that `rmsnorm_rs` as written produces the right scale over this
  schedule, and it says nothing at all about `rmsnorm_rs`'s arithmetic.

* **The swiglu model's exponent is still fabricated.** It publishes
  `v_exp_a + 2` while computing `(a*b)/64`, and in this Q-format a product's
  exponent is the SUM of the operands', not one of them plus a constant. That
  is defect 7's class -- a stub correct in its values-are-wrong intent and
  wrong in its contract -- in the one place Part 2 did not look. It did not
  show up here because the FFN residual's gap stays at 7 to 12, but 12 against
  a threshold of 14 is not margin, and a real swiglu will move it.

* **The 8-bit exponent wrap is diagnosed and NOT fixed.** No port was widened.

* **The unwrapped GDN mixer gap growth rate is estimated, not measured.** The
  series 4, 7, 0, 9, 28, 35, 53, 68, ... is reconstructed by adding 256 to the
  wrapped values. That reconstruction is arithmetically forced but it was not
  taken from an unwrapped run, because no such run exists until the ports are
  widened.

* **Whether the drift is bounded once A's weights are real is unknown.** With
  synthetic weights every matvec's `ns` is about 10 because the accumulator is
  full-scale by construction. Real INT4 weights against real activations will
  give a different `ns`, and it could be smaller. The mechanism does not change
  -- there is still nothing that restores the scale -- but the RATE would.

* **`NRUNS = 1` throughout.** Every number in this part is one
  descriptor-memory latency. P2 was checked separately at `NRUNS = 4` for
  `B_SRC_REAL` and passed, but the 32-block anchored PASS is a single-latency
  result and is not a skew claim.

* **No synthesis of anything but `seq_vec_res`.** The `NORM_ANCHOR` probe and
  the `B_SRC_REAL` prefetch are simulation-only constructs and were never
  synthesised. The prefetch adds `qkv_dim + 2*val_heads + 4` region reads per
  GDN block ahead of `start`, about 270 cycles at the scaled shape and 8,260
  at the real 9B shape (`qkv_dim` 8,192 + 2 x 32 + 4), which is a real
  serialisation cost that nobody has priced.

---

# PART 4 (WIP, INTERRUPTED) -- the swiglu model's exponent is fabricated, and correcting it removes the PART 3 headline result

**Date:** 2026-08-28, later the same session. **This part is an interrupted
work-in-progress note, written because the session was stopped for a reboot.
The code change it describes is NOT committed.** It is stashed on branch
`fpga` as `git stash` message `wip-dvec-exponents-2026-08-28`, touching
`rtl/llama_top.vhd` only. Nothing in the working tree carries it.

**Tools:** GHDL 1.0.0 mcode, `--std=08 -frelaxed --max-stack-alloc=0`. Every
number below is a simulation count at the stated `NRUNS`, taken against a
private snapshot of the 32-file `tb_llama_top` closure (copied out of the repo
into a scratch tree and analysed into its own library) so that another agent's
concurrent edits to `rtl/matvec_int4*.vhd` could not invalidate the library
mid-run. The snapshot was verified to reproduce the committed baseline exactly
before anything was changed.

## The question, verbatim

> `rtl/llama_top.vhd:1031`, in the behavioural D-vec engine's S_DONE state:
> `yexp <= v_exp_a + to_signed(vi, EXP_W);`
> Every D-vec op takes its output exponent as the input exponent plus `vi`,
> the OP INDEX. [...] For the swiglu op this is wrong in a way that matters.
> Swiglu computes a PRODUCT, and in this block-floating-point format a
> product's exponent is the SUM of its operands' exponents, so it should be
> `v_exp_a + v_exp_b`. [...] Go through EVERY D-vec op, not just swiglu, and
> state for each whether its modelled exponent is contractually right.

## The answer, up front

Of the three D-vec ops, one is real RTL, one (`V_NORM`) was accidentally right
because its op index is 0, and one (`V_SWG`) was wrong: it published
`v_exp_a + 2` for a product. Correcting it to `v_exp_a + v_exp_b - MANT_W`
**removes PART 3's headline result**: with the correct swiglu exponent,
`NORM_ANCHOR` no longer gives 0 degenerate residuals at 32 blocks, it gives 8,
and the DEFAULT path fails at every block count including 1. The fabricated
`+2` was masking roughly half the FFN-side scale excursion.

## The audit, op by op

| op | model | published exponent, before | contractually right? | after |
|---|---|---|---|---|
| `V_NORM` (vi=0) | `out(i) = in(i) - mean(in)` | `v_exp_a + 0` | **YES, by accident.** A difference of two quantities already on the input grid is on the input grid, so the constant genuinely is zero. It is right for the MODEL and wrong for the OP: a real rmsnorm is scale-free and publishes the WEIGHT scale. | `v_exp_a`, unchanged in value, with the reasoning written down |
| `V_RES` (vi=1) | real `seq_vec_res` | `o_exp` from the unit | not fabricated, out of scope | unchanged |
| `V_SWG` (vi=2) | `out(i) = (a(i)*b(i))/64` | `v_exp_a + 2` | **NO.** A product's exponent is the SUM of its operands', and a right shift of the mantissa by s subtracts s. `v_exp_b` was already read by `seq_vec_issue` and wired in, and was simply discarded. | `v_exp_a + v_exp_b - MANT_W` |

Convention confirmed against `seq_vec_res.vhd:13-15` (`value = mantissa *
2^-exponent`, a larger exponent is a FINER scale) and independently against
`matvec_core`'s `y_exp = w_exp + x_exp - out_shift - ns`, which is a real unit
publishing the same two rules.

## A second, measured defect in the same stub: it saturated 128 of 128 outputs

The `/64` shift was also wrong, and measurably so. Two MANT_W-wide mantissas
multiply to up to `2**(2*MANT_W-2)`, so a 6-place right shift cannot hold the
product. Instrumented copy, `BLOCKS=1`:

```
SWGSAT sat=128 unsat=0
```

Every element of every swiglu output saturated, so R_H was a CONSTANT vector
and the FFN carried no information from R_G or R_U. A saturated mantissa also
makes the published exponent false regardless of the formula. The stashed
change therefore uses `/(2**MANT_W)`, the smallest fixed shift under which the
product cannot saturate.

**Measured and it does NOT matter for P6.** A mutant with the shift at
`MANT_W` and one at `/64`, both with the corrected exponent, give **identical**
degenerate counts (1 / 5 / 12 / 27 / 56 at 1 / 4 / 8 / 16 / 32 blocks). The
downstream matvec's data-driven `ns` absorbs the shift exactly. The shift
change is for the VALUES being input-dependent again, not for the scale.

## The evidence

All at `NRUNS = 1` unless stated. Real A, real B, `attn_interval` 4.

Degenerate residuals, DEFAULT path (`NORM_ANCHOR` false):

| BLOCKS | 1 | 4 | 8 | 16 | 32 |
|---|---|---|---|---|---|
| committed (`v_exp_a + vi`) | -- | **0** | **3** | **10** | **23** |
| stashed (`v_exp_a + v_exp_b - MANT_W`) | **1** | **5** | **12** | **27** | **56** |

Degenerate residuals, `NORM_ANCHOR = true`:

| BLOCKS | 4 | 8 | 16 | 32 |
|---|---|---|---|---|
| committed | **0** | **0** | **0** | **0** |
| stashed | **0** | **0** | **3** | **8** |

Landmarks: committed, `BLOCKS=32 NRUNS=1 NORM_ANCHOR=true` gives
`R_X(0) = 29261 hash(R_X) = 90742` (reproduced exactly, twice, before any
edit). Stashed, the same command gives 8 degenerate and FAILs; stashed
`BLOCKS=4 NRUNS=4 NORM_ANCHOR=true` PASSes with
`R_X(0) = -12049 hash(R_X) = 86767`; stashed `BLOCKS=8 NRUNS=1
NORM_ANCHOR=true` PASSes with `R_X(0) = -10475 hash(R_X) = 52433`.

The anchored 32-block `RESGAP` series with the correction in shows why: `ea`
is bounded at -9 exactly as PART 3 reported, but the FFN operand `eb` now
swings to +7 and +8, so the gap reaches 16 and 17 against a threshold of 14.
The eight failures are all FFN residuals, which is the residual the swiglu
feeds.

```
RESGAP issue 164 ea -9 eb  7 gap 16
RESGAP issue 209 ea -9 eb  7 gap 16
RESGAP issue 225 ea -9 eb  8 gap 17
RESGAP issue 270 ea -9 eb  8 gap 17
```

## CORRECTION to PART 3

PART 3 said, of the `NORM_ANCHOR` probe:

> the degenerate count is **0 at 4, 8, 16 AND 32 blocks**

**That is WITHDRAWN as stated.** It is 0 at 4, 8, 16 and 32 only while the
swiglu model publishes a fabricated exponent that understates the FFN-side
excursion by roughly half. With the swiglu's contract corrected it is
0 / 0 / 3 / 8. The mechanism PART 3 identified -- nothing in the block loop
restores the activation scale, and the norm is the unit that should -- is NOT
withdrawn and is unaffected: `ea` is still bounded at -9 with the anchor and
still marches to -387 without it. What is withdrawn is the claim that
anchoring the norm ALONE is sufficient at 32 blocks. PART 3's own open list
anticipated this in as many words ("a real swiglu will move it"); it moves it
further than that sentence implies.

## The bench gate, and why nothing was committed

The bench default is `BLOCKS = 4, NRUNS = 4` with `NORM_ANCHOR` false, and
with the correction in it FAILS with 20 degenerate residuals (5 per run,
cumulative). **No unanchored block count passes any more, including
`BLOCKS = 1`**, measured: 4 degenerate at `NRUNS = 4`. So the correction
cannot be committed without also moving the bench's defensible default, and
choosing that default is the decision the session was interrupted before
taking. `sim/regress.sh`'s floor of 74 PASS would otherwise drop to 73.

## Measured and REJECTED -- do not retry (Part 4)

* **Lowering the bench's default `BLOCKS` to keep the gate green with the
  corrected swiglu exponent.** There is no such value: 1 block already has one
  degenerate residual per run. Numbers above.
* **Changing the swiglu model's normalisation shift as a way to move the
  degenerate count.** `/64` and `/(2**MANT_W)` give bit-identical degenerate
  counts at every block count measured. The downstream matvec's data-driven
  `ns` cancels it exactly. Do it for the saturation, not for the scale.

## Measurement traps hit (Part 4)

* **The regression library points at the REPO files by path and hash**, so a
  concurrent agent editing `rtl/matvec_int4*.vhd` invalidates it mid-run. This
  bit PART 3 too. The fix used here is a private snapshot of the 32-file
  closure (`grep -o '"/home/.*"' work-obj08.cf` lists it) analysed into its own
  library, verified to reproduce the committed baseline before use.
* **A degenerate count is still meaningless without its `NRUNS`.** The
  cumulative counter is unchanged. Every count above states it.

## Open, not yet answered (Part 4)

* **Task 2 was never started.** No `seq_vec_issue` adapter for `rmsnorm_rs`
  was written, and nothing is known about whether the real unit reaches 0
  degenerate residuals over this schedule. The PART 3 recommendation stands
  and is now MORE important, not less: with the swiglu corrected, anchoring
  the norm alone is measurably not enough at 16 and 32 blocks.
* **What the FFN residual needs is not established.** The eight remaining
  anchored failures are all FFN residuals and all driven by the swiglu's
  output scale. Whether a real `swiglu` unit with a data-driven normalisation
  bounds `eb` is untested.
* **The teeth check for the corrected exponent was not run.** P6's teeth were
  re-established in PART 3 against a different mutation and were not re-run
  here.
* **`B_BEHAV`'s output exponent is fabricated in the same way** and was NOT
  changed: it publishes `j_wexp + j_ord`, which depends on no source region's
  captured exponent at all. It is a bisection stand-in, default false, so it
  never affects the default path, but it is defect 7's class and it is
  unfixed. `A_BEHAV` (`j_wexp + xexp - j_shift`) and the unit C stub
  (`exp_rd_data`, its source region's exponent) were audited and are both
  contractually right.
