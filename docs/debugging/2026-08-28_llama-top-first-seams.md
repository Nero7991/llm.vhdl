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

# PART 4 -- the swiglu model's exponent is fabricated, and correcting it removes the PART 3 headline result

**Date:** 2026-08-28, later the same session.

**STATUS UPDATE, appended rather than rewritten.** This part was first written
as an interrupted work-in-progress note, because the session was stopped for a
reboot with the change stashed and uncommitted. **It is now committed as
`995125e`**, together with the bench default change PART 4 concluded was
needed, and the full regression gate is green at 74 PASS / 0 FAIL. The stash
`wip-dvec-exponents-2026-08-28` is superseded and can be dropped. The original
WIP text is kept below unedited, because what it said while the outcome was
still open is the useful part.

**Independently reproduced before commit.** The matrix below was re-measured
from scratch on a second run, in a workdir built by `sim/regress.sh` itself
(`REGRESS_SCRATCH=... --only llama_top --keep`) rather than by a hand-rolled
import, and it agreed digit for digit: unanchored 5/12/27/56 and anchored
0/0/3/8 at 4/8/16/32 blocks, NRUNS=1.

**The bench default is now `NORM_ANCHOR = true`.** The forcing constraint is
that NO unanchored configuration passes, not even one block, so there was no
option that both keeps P6 enforced and runs the design as it actually is. A
permanently red gate stops being read and then hides the NEXT regression
behind an expected failure. The accepted cost is that the gate runs a
configuration the hardware does not implement; what keeps it honest is that
the unanchored column is measured, is in the bench header, and is repeated in
the PASS line on every run, so a green run cannot be read as "the scales
track". Verified at the new default: `R_X(0) = -12049 hash(R_X) = 86767`.

**A trap found while writing that PASS line.** `sim/regress.sh`'s `FAIL_RE` is
a CASE-SENSITIVE `grep -aqE` carrying six literals, not one: `IS NOT`,
`IS WRONG`, `MISMATCH`, `FAILED`, `DIVERGES` and `\bFAIL\b`. The bench's own
comment warned about only one of them. Any `report` string containing any of
the six is judged red on an otherwise passing run. The comment now lists the
full set.

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

---

# PART 5 -- the real `rmsnorm_rs` on the D-vec norm op: it is scale-free and it still emits ZEROS

**Date:** 2026-08-28, later the same session. Appended in place. This part
IMPLEMENTS the recommendation PART 3 made and PART 4 called more important,
measures it, and reports that it does not work -- for a reason neither part
could have predicted, because the probe that motivated it has no analogue of
the failing mechanism.

**Build:** branch `fpga`. Modified: `rtl/llama_top.vhd` (four new generics,
`NORM_REAL`, `NORM_LANES`, `NORM_Q`, `NORM_W_EXP`, and one new generate branch
holding the adapter and the `rmsnorm_rs` instance) and `sim/tb_llama_top.vhd`
(the `NORM_REAL` generic passed through, plus the measured column in the
header and in the PASS line). Nothing else. `NORM_REAL` defaults FALSE and the
default path is verified bit-identical: `R_X(0) = -12049 hash(R_X) = 86767` at
the bench default, before and after.

**Tools:** GHDL 1.0.0 mcode, `--std=08 -frelaxed --max-stack-alloc=0`. Every
count is at the stated `NRUNS`. No synthesis was run.

## The question, verbatim

> PART 3's recommendation is to put the real `rtl/rmsnorm_rs.vhd` on the D-vec
> norm op. [...] **The success criterion is the one the probe demonstrated:
> degenerate residuals 0 at BLOCKS = 4, 8, 16 AND 32, with the REAL unit
> rather than the probe.** [...] If the real unit does NOT achieve that, this
> is a genuine finding and is worth more than a fix. Report what its output
> exponent actually does over the schedule and why it differs from the probe's
> idealisation. **Do not tune the unit to make the number come out.**

## The answer, up front

**It does not achieve it, and it is the worst of the three configurations.**
At `NRUNS = 1`, real A, real B, `attn_interval` 4:

| BLOCKS | 1 | 2 | 4 | 8 | 16 | 32 |
|---|---|---|---|---|---|---|
| **`NORM_REAL` (real `rmsnorm_rs`)** | **0** | **2** | **6** | **14** | **28** | **59** |
| `NORM_ANCHOR` (the probe) | -- | -- | 0 | 0 | 3 | 8 |
| neither | -- | -- | 5 | 12 | 27 | 56 |

**The unit's exponent bookkeeping is right, and is exactly what the probe
models.** Measured directly at the unit's own port: it publishes `o_exp` of 13
or 14 for input exponents of 3, 10, -1, -5, -6 and -7 alike. Its output
exponent genuinely carries no memory of its input's, which is the property
PART 3 identified as missing from the block loop.

**What kills it is a property the probe has no analogue of.** `rmsnorm_rs`
collapses the reciprocal square root to a Q-format 32-bit integer,
`inv32 ~ 2**Q / rms_real`, and therefore has a HARD INPUT MAGNITUDE WINDOW of
19 octaves, `rms(x_real)` in `[2^-6, 2^12]`, with a **silent all-zeros rail**
above it. That window is not a finding of this part: it was measured
independently on 2026-08-26 and is in
`docs/debugging/2026-08-26_rmsnorm-magnitude-window.md`. What this part adds is
that **the D-vec norm op drives the unit out of that window during the SECOND
block** and never comes back. Measured `log2 rms` of the norm's actual input,
in order: **3.20, 3.36, 15.10, 15.10, 15.10, ...**. From the third norm onward
every output element is zero, R_XN is a zero vector, every matvec below it
produces zero, ER is zero, and the residual stream FREEZES -- the same input
mantissas are read by every subsequent norm.

So the honest one-line statement is: **a real rmsnorm is scale-free in its
exponent and is not scale-free in its arithmetic, and this design leaves the
range where its arithmetic works before the norm has run three times.**

## The procedure, in the order it was run

1. **Reproduce all three published baselines before touching anything**, in a
   workdir built by `sim/regress.sh --only llama_top --keep`. `BLOCKS=32
   NRUNS=1 NORM_ANCHOR=true` -> 8. `NORM_ANCHOR=false` -> 56. The bench
   default -> PASS, `R_X(0) = -12049 hash(R_X) = 86767`. All three agreed
   exactly, so the starting point is the committed one.

2. **Read the unit's contract before writing the adapter**, the same rule
   PART 1 opened with. Three things decided the adapter's shape and each of
   them is a defect if got wrong: `x_mant` is a FLAT `N*16` port so `N` is
   fixed at elaboration and cannot follow `v_n`; `done` is a one-cycle pulse;
   and `x_exp` is sampled once, at `start`, into `xe`.

3. **Put it behind a generic that defaults to the existing behaviour**, so the
   control and the treatment are the same binary and no other instantiation
   changes. `NORM_REAL`, false by default, following `B_SRC_REAL` and
   `NORM_ANCHOR`. Verified bit-identical at the default before measuring
   anything.

4. **Measure the block sweep.** 1, 2, 4, 8, 16, 32, all at `NRUNS = 1`.

5. **When it failed, instrument the UNIT, not the residual.** P6 says a
   residual discarded an operand; it cannot say why. One `report` at the
   adapter's completion instant carrying the input exponent, the published
   output exponent and the first three output mantissas answered it in one
   run: the output mantissas were `0 0 0`.

6. **Quantify the input in the unit's own terms**, because the published
   window is in `rms(x_real)` and the trace was in exponents. A second probe
   folds `log2 rms` of the assembled input vector in `ieee.math_real` -- a
   simulation-only measurement, not RTL.

7. **Test the mechanism by moving the one parameter it depends on.**
   `NORM_Q` is `rmsnorm_rs`'s own generic and it sets where the window sits.
   This is a DIAGNOSTIC and is labelled as one: the committed default is left
   at the unit's own 12, because the task was explicit that tuning the unit to
   move the number is not the point, and because the result below shows it
   would not have been a fix anyway.

8. **Teeth-check every guard relied on**, against deliberately broken copies,
   in a configuration where the unbroken design passes.

## The evidence

### The unit's own ports, at every norm of a 4-block token

`xe` is the input exponent, `oe` the published output exponent, `out0..2` the
first three output mantissas, `in0/in1` the first two input mantissas.

```
NORMRMS log2rms 3.200506407691405
NORMPROBE xe   3 oe 14 out0 -26133 out1 -18575 out2 -10868 in0  -125 in1   -88
NORMRMS log2rms 3.3623114929039053
NORMPROBE xe  10 oe 13 out0  -8279 out1  -3881 out2   6271 in0 -11360 in1 -5274
NORMRMS log2rms 1.5100272275107358e1
NORMPROBE xe  -1 oe 23 out0      0 out1      0 out2      0 in0  -9360 in1 -16877
NORMRMS log2rms 1.5100272275107358e1
NORMPROBE xe  -1 oe 23 out0      0 out1      0 out2      0 in0  -9360 in1 -16877
   ... identical for every remaining norm of the token ...
```

Three things are in that block and each one matters.

* `log2 rms` goes 3.20, 3.36, **15.10**. The published upper rail is `2^14`.
  The stream crosses it between the second and third norm, i.e. inside block 1
  of a 32-block model.
* The output is **identically zero** from the third norm onward, with no error
  flag anywhere. `o_exp = 23` is what `xe + we + Q - st` evaluates to when
  `st = 0`, and `st = 0` because `max|raw| = 0`. The exponent is arithmetically
  correct and describes a zero vector.
* `in0` and `in1` never change again. The stream is frozen: with R_XN zero,
  every matvec below it produces zero, so ER is zero and `X + ER = X`.

### The residual trace, and why `ea` looks bounded

```
NORMPROBE xe  3 oe 14
RESGAP issue 10 ea  3 eb 11 gap  8
NORMPROBE xe 10 oe 13
RESGAP issue 16 ea 10 eb -2 gap 12
NORMPROBE xe -1 oe 23
RESGAP issue 26 ea -1 eb 46 gap 47
NORMPROBE xe -1 oe 23
RESGAP issue 32 ea -1 eb 24 gap 25
NORMPROBE xe -1 oe 23
RESGAP issue 42 ea -1 eb 46 gap 47
```

`ea` -- the residual stream's own exponent -- pins at -1 and stays there for
the rest of the token, which read alone looks like the bounded series PART 3
was after. **It is bounded for the wrong reason: the stream has stopped
moving.** `eb` is then whatever exponent the matvec chain publishes for a
zero input, and the gap is large because nothing constrains it. This is a
measurement trap and it is recorded as one below: a bounded `ea` is necessary
and nowhere near sufficient.

### The `NORM_Q` diagnostic -- the mechanism, and why widening is not the fix

`BLOCKS = 4`, `NRUNS = 1`, everything else identical, `NORM_Q` swept by
rebuilding the design with a different default in a private tree:

| `NORM_Q` | 3rd norm `oe` | 3rd norm output | degenerate residuals |
|---|---|---|---|
| **12 (the unit's own default)** | 23 | **all zero** | **6** |
| 16 | 13 | non-zero | 4 |
| 20 | 14 | non-zero | **0** |
| 24 | 14 | non-zero | **0** |
| 28 | 14 | non-zero | 2 |

That is a causal proof of the mechanism: the only thing that changed is where
`inv32`'s fixed grid sits, and the zeros appear and disappear with it.

**And it is not a fix, it is a delay.** Taking `Q = 20` to depth:

| BLOCKS | 4 | 8 | 16 | 32 |
|---|---|---|---|---|
| `NORM_REAL`, `NORM_Q = 20` | 0 | 0 | **6** | **38** |

At 32 blocks, **39 of the 65 norms are emitting zeros again**, at input
exponent -8: the stream simply drifts on until it re-enters the dead band from
the other side of a wider window. The non-monotonicity at `Q = 28` says the
same thing from the other end -- it is a WINDOW with two rails, not a floor.
This agrees with the 2026-08-26 document's own conclusion, reached from real
model activations rather than from this schedule: "the fix is not a wider `Q`
and not a restructured rsqrt".

### The adapter itself is skew-clean, so the new states are not the defect

`BLOCKS = 2`, `NRUNS = 4`, four descriptor-memory latencies, `NORM_REAL`:

```
schedule mismatches=0 skew differences=0 degenerate residuals=8
```

`8 = 4 x 2`, the `NRUNS = 1` count of 2 counted once per run, which is the
cumulative-counter behaviour PART 3 recorded and is the expected value rather
than a new number. P1, P2 and P3 all hold with the real unit in: the failure is
arithmetic, not a handshake.

### What the real unit does that the probe does not, stated as the difference

| | `NORM_ANCHOR` probe | real `rmsnorm_rs` |
|---|---|---|
| output exponent | constant `NORM_EXP` | `x_exp + w_exp + Q - st`, and `st` cancels the `x_exp` term |
| scale-free in the input? | yes, by fiat | **yes, measured** -- `o_exp` is 13 or 14 for `x_exp` in {3, 10, -1, -5, -6, -7} |
| input magnitude range | **unbounded** -- it folds the max in integer arithmetic with no grid | **19 octaves**, `rms(x_real)` in `[2^-6, 2^12]` |
| behaviour outside that range | n/a | **all-zero output, silently** |
| arithmetic | mean removal, then a renormalising shift | the real three-pass rsqrt datapath |

The probe modelled ONE property and modelled it correctly. The property it did
not model is the one that decides the outcome.

### Teeth checks -- both results, as required

All at `BLOCKS = 1`, `ATTN_INT = 8`, `NRUNS = 4`, `NORM_REAL = true`, which is
a configuration the unbroken design PASSES:

```
control (unbroken)   skew differences=0 degenerate residuals=0 RESULT: PASS
                     R_X(0) = -9360 hash(R_X) = 51735
```

**P6, in this configuration.** A copy with the adapter's published exponent
offset by 20 (`yexp <= to_signed(oe + 20, EXP_W)`):

```
skew differences=0 degenerate residuals=8 RESULT: FAIL
```

**PASS unbroken, FAIL broken.** PART 4 recorded that P6's teeth had not been
re-established since PART 3; they now have been, against this part's
configuration and against a mutation of this part's own code.

**The `n = NN` guard**, which refuses to run a norm whose length is not the
elaborated `N` rather than zero-padding it. A copy with
`NN := SHAPE.hidden/2`:

```
llama_top: the norm op was issued with n = 64, but the rmsnorm_rs instance is
elaborated at N = 32.  A norm of a different length needs its own instance;
padding this one changes the mean square.
(assertion failure)
```

**Fires broken, silent unbroken** -- zero occurrences in every run above.

**The two-edge region read.** A copy consuming at `k-1` instead of `k-2`:

```
skew differences=0 degenerate residuals=0 RESULT: PASS
R_X(0) = -6792 hash(R_X) = 25244        against the control's -9360 / 51735
```

**This one PASSES broken, and that is the result, not a gap in the report.**
The mutation is load-bearing -- it changes the answer -- but no property in the
bench can see it, because this engine owns the region port exclusively for the
whole pass, so the stale value is the previous element of the SAME pass and the
vector merely comes out shifted by one. Its `rms` is almost unchanged, so even
the norm still works. **This is defect 2's family again, for the third time in
this file: a deterministic wrong number that the skew sweep cannot reach.** The
only instrument that catches it is reading the code, and the only defence is
the READ_LATENCY comment the region file already carries.

### The gate

`sim/regress.sh`, full run, with the change in and `NORM_REAL` at its default
FALSE:

```
 suite sim   PASS 49   FAIL 1   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 75   FAIL 1   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5
PASS       sim:tb_llama_top    106s   ... RESULT: PASS -- 64 descriptors, 4 blocks ...
```

75 PASS against the stated floor of 74. The single failure is
`sim:tb_attn_block`, which is another agent's in-flight subsystem C work:
both `rtl/attn_block.vhd` and `sim/tb_attn_block.vhd` are UNTRACKED in git and
`rtl/attn_block.vhd` was rewritten ten minutes into this gate run. Neither
file changed here appears in its closure, and its only mentions of them are in
comments. It is recorded rather than left out, because a gate result with an
unexplained red line in it is not a gate result.

## Measured and REJECTED -- do not retry (Part 5)

* **`rmsnorm_rs` on the D-vec norm op as a fix for defect 8, as built.** It is
  the experiment PART 3 recommended and it is the right experiment; the result
  is 0/2/6/14/28/59 at 1/2/4/8/16/32 blocks, worse than the probe at every
  depth and worse than no norm at all at 32. Do not re-run it hoping for a
  different answer. Re-run it only after something bounds the residual
  stream's MAGNITUDE, not merely its exponent.

* **Raising `NORM_Q`.** Measured: 0/0/6/38 at 4/8/16/32 with `Q = 20`, and 39
  of 65 norms back to emitting zeros at 32 blocks. It moves the window; it
  does not remove the mechanism. `Q = 28` is worse than `Q = 24` at 4 blocks,
  which is the upper rail of the same window showing itself.

* **Zero-padding a short norm to the elaborated `N`.** Padding changes the
  mean square, so it is a wrong number and not a wasted cycle. The adapter
  asserts instead. Every `OP_VEC_NORM` in `llama_sched_pkg` is `s.hidden`, so
  one instance covers the schedule as it stands.

* **Sourcing the norm's gain from an activation region.** Not tried, and
  deliberately: the RMSNorm gain is a learned WEIGHT, its scale does not move
  with the token, and there is no region, descriptor field or packing for it.
  Same rule `B_SRC_REAL` applies to the conv weights and the two learned
  per-head scalars, and PART 3 already recorded what happens when an
  activation region is fed to something that expects a weight.

## Measurement traps hit (Part 5)

* **A bounded `ea` is not evidence that anything is working.** With the real
  unit in, the residual stream's exponent pins at -1 and holds for 30 blocks,
  which is the shape PART 3's anchored run has and looks like success in the
  `RESGAP` series. It is bounded because the stream is FROZEN: R_XN is zero,
  so ER is zero, so `X + ER = X`. The trap is that the instrument PART 3 built
  reports the exponent and not the magnitude, and a dead machine has a very
  stable exponent. **Always read `ea` next to something that says the data
  moved.** P4 does say so, but P4 compares R_X before and after the WHOLE
  token, so two blocks of real movement satisfy it.

* **The unit reports no error when it emits an all-zero vector.** There is no
  flag, no assertion and no saturation count. The only way this was visible at
  all was printing the output mantissas. If a unit has a documented silent
  rail, instrument the rail before instantiating it, not after the count comes
  out wrong.

* **`ghdl -a` on the entity obsoletes the architecture of every instantiator,
  and it is silent until you run.** Re-analysing `rtl/llama_top.vhd` after a
  generic change left `tb_llama_top` reporting `architecture "tb" of
  "tb_llama_top" is obsoleted by entity "llama_top"`, which reads as a broken
  testbench. PART 1 recorded this trap; it cost time again. Re-analyse the
  testbench in the SAME command, every time.

* **A read-latency mutant that indexes off the end of the vector aborts with
  `overflow detected` rather than failing the property.** The first attempt at
  the `k-1` teeth check wrote to slice `(k-1)` at `k = 0`. That is a broken
  mutant and not a result; the useful mutant keeps the guard and moves only
  the destination index.

* **A private snapshot of the closure is still the only way to measure while
  other agents are editing `rtl/`.** Same trap as PARTS 3 and 4. The snapshot
  here was verified to reproduce `R_X(0) = -12049 hash(R_X) = 86767` before
  anything was changed in it.

## Open, not yet answered (Part 5)

* **Nothing bounds the residual stream's MAGNITUDE.** PART 3 established that
  nothing restores the exponent; this part establishes that fixing the
  exponent alone is not enough, because the magnitude leaves every real unit's
  arithmetic window anyway. What would bound it has not been identified, and
  it is now the largest open item in this file.

* **`rtl/rmsnorm_bf.vhd` was NOT measured.** It exists, it has the same port
  list as `rmsnorm_rs` so it would drop into this adapter unchanged, and it
  was written specifically because `rmsnorm_rs` "is WRONG in a region the real
  model occupies". Its `inv32` is still on a `2**-Q` grid, so the reasoning
  above suggests the upper rail is unchanged and only the LOWER end is fixed
  by the epsilon -- but that is an inference from reading, not a measurement,
  and it should be measured before it is believed.

* **Whether the stream would reach `rms 2^15` with REAL weights is unknown.**
  A's weights are still synthetic and every matvec's `ns` is about 10 because
  the accumulator is full-scale by construction. The mechanism does not
  change; the rate, and therefore which block the window is left in, would.

* **The area of the D-vec `rmsnorm_rs` instance is not measured.** No
  synthesis was run, deliberately. What would be run: an out-of-context
  synthesis of `rmsnorm_rs` at `N = SHAPE.hidden`, `LANES = 4`, `Q = 12`,
  part `xczu3eg-sfvc784-1-e`, against the 385 LUT / 18 DSP figure the narrowed
  QK-norm instance measured, which is a floor and not a quote because the
  D-vec instance is a different width.

* **The adapter's cycle cost is not measured either.** It is a read pass of
  `n+2`, the unit's own `3N/LANES` plus roughly 40 fixed cycles, and a write
  pass of `n`, all serialised. Against the behavioural model's `n+2` plus `n`
  that is roughly a doubling of the norm step, and the norm is issued 129
  times per token.

* **`NORM_REAL` was measured at `NRUNS = 1` only**, like everything since
  PART 3, except the teeth checks and the 1-block control, which are at
  `NRUNS = 4`. It is not a skew claim.

## CORRECTION to PART 3

PART 3's costed recommendation said, of putting a real rmsnorm on the D-vec
norm op:

> **This is the one to pick**, because it removes the cause rather than
> raising a threshold, and because the budget already carries it.

**That recommendation is WITHDRAWN as stated.** It was built, and it does not
remove the cause: it removes the exponent half of the cause and leaves the
magnitude half, which then fails harder and more silently than what it
replaced. The reasoning PART 3 gave for it -- that a real rmsnorm's output
exponent is fixed by the weight scale and carries no memory of the input's --
is CORRECT and was confirmed at the unit's own port. What was missing from it
is that `rmsnorm_rs` is scale-free only in its bookkeeping, and its arithmetic
has a 19-octave window that this design leaves in the second block. PART 3's
own open list came close to this in the sentence "it does not prove that
`rmsnorm_rs` as written produces the right scale over this schedule, and it
says nothing at all about `rmsnorm_rs`'s arithmetic". It is the arithmetic.

The claim that the drift is a design property and not a stimulus artefact is
NOT withdrawn and is unaffected.

---

# PART 6 -- the magnitude explosion is the STIMULUS, and with real weights the real `rmsnorm_rs` works

**Date:** 2026-08-28, later the same session. Appended in place. This part
answers the question PART 5 left as the largest open item in this file, and it
**WITHDRAWS PART 5's headline conclusion** and **REINSTATES PART 3's
recommendation**. Both corrections are at the end of this part.

**Build:** branch `fpga`. Modified: `rtl/llama_top.vhd` (four observability
ports `obs_norm_pub` / `obs_norm_exp` / `obs_norm_ssq` / `obs_norm_n`, and the
integer sum-of-squares that feeds them, in BOTH norm branches),
`sim/tb_llama_top.vhd` (a `W_IMAGE` generic that serves subsystem A's five AXI
read slaves from a real packed weight image instead of the arithmetic `wword`,
plus the `NORMMAG` observability line), and one new file
`tools/gen_llama_top_weights.py`. `W_IMAGE` defaults to `""` and the default
path is verified bit-identical: `R_X(0) = -12049 hash(R_X) = 86767`, before and
after.

**Tools:** GHDL 1.0.0 mcode, `--std=08 -frelaxed --max-stack-alloc=0`. Every
count is at `NRUNS = 1` unless stated. No synthesis was run. No hardware was
touched.

## The question, verbatim

> PART 5 established that the real `rtl/rmsnorm_rs.vhd` makes the residual
> WORSE, not better [...] What kills it is the unit's hard 19-octave INPUT
> MAGNITUDE window [...] Measured `log2 rms` of the residual stream, per norm:
> **3.20, 3.36, then 15.10 and stuck**. [...] **Twelve octaves of growth in a
> single block is not obviously physical.** Subsystem A's weights in this bench
> are SYNTHETIC. [...] **Your job: feed REAL weights into the bench and
> re-measure `log2 rms` per block.**
>
> - **(a) The stimulus was never physical.** [...] real weights do not, the
>   stream stays inside the window, and the real `rmsnorm_rs` works after all.
> - **(b) The BFP discipline has an architectural hole.** [...] nothing bounds
>   the stream's magnitude, and the design needs something that does not exist
>   yet.

## The answer, up front

**It is (a) for the RATE and (b) for the MECHANISM, and the two together make
the design work.**

The bench's arithmetic weight image has an rms **row norm** of `2**4.87`; the
real Qwen3.5-9B weights packed into the same geometry have `2**-0.03`. A matvec
multiplies the activation magnitude by its row norm, so the synthetic image
alone is worth about five octaves per matvec. Twelve octaves per block is not
physical.

With real weights fed through the bench and the real `rmsnorm_rs` on the D-vec
norm op, the whole 491-descriptor 32-block token **PASSES**: zero degenerate
residuals, and the norm's input magnitude stays at `log2 rms` **3.20 rising to
5.24** across all 65 norms -- ten octaves clear of the unit's `2^12` rail, with
**65 distinct magnitudes over 65 norms**, so the stream is demonstrably still
moving and not frozen.

But (b) is not an artefact. With real weights and the BEHAVIOURAL mean-removal
norm the stream still explodes, `log2 rms` 3.20 -> 25875 over 32 blocks. Real
weights slow the explosion; they do not stop it. **The only thing in the block
loop that restores the activation scale is a real rmsnorm**, exactly as PART 3
said, and PART 5's failure to demonstrate that was a property of the stimulus.

## The procedure, in the order it was run

1. **Reproduce all three published baselines before touching anything**, in a
   private snapshot of the 33-file closure built by
   `sim/regress.sh --only llama_top --keep`. Bench default -> PASS,
   `R_X(0) = -12049 hash(R_X) = 86767`. `BLOCKS=32 NRUNS=1 NORM_ANCHOR=true`
   -> 8. `NORM_ANCHOR=false` -> 56. All three exact.

2. **Measure the row norms first, in software, before building anything.**
   The whole hypothesis reduces to one number per matrix, and if the real and
   synthetic row norms had been within an octave of each other there would
   have been nothing to build. They are five octaves apart.

3. **Pack real weights into the BENCH's geometry, not the FK33's.** The
   published `.mv4i` set is at `ROWS_IF=48 / AXI_DW=256`; `llama_top`
   instantiates `matvec_int4` at `ROWS_IF=4 / AXI_DW=128 / NPORTS_S=1`. The
   weights are therefore re-quantized and re-packed from the BF16 GGUF through
   `tools/pack_int4.py`'s OWN `pack()`, so the 6.5a byte layout is not written
   a second time.

4. **Prove the packing before believing any number it produces.** Two
   independent readers, then a value-level oracle for the whole chain.

5. **Measure the depth sweep in four configurations**, so that "real weights"
   and "real norm" can be attributed separately: synthetic/real weights times
   behavioural/real norm.

6. **Teeth-check every guard**, against deliberately broken copies, in a
   configuration where the unbroken design passes.

## The evidence

### Step 2 -- the row norms, which is the whole finding in one table

Real weights, read from `/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf`:

```
tensor                                M      K   elem_rms rownorm_rms    log2
output.weight                    248320   4096  1.548e-02      0.9904   -0.01
blk.0.ffn_down.weight              4096  12288  1.097e-02      1.2157    0.28
blk.0.ffn_gate.weight             12288   4096  1.123e-02      0.7184   -0.48
blk.0.ffn_up.weight               12288   4096  1.055e-02      0.6749   -0.57
blk.16.ffn_down.weight             4096  12288  1.106e-02      1.2264    0.29
blk.31.ffn_down.weight             4096  12288  1.143e-02      1.2670    0.34
blk.0.attn_qkv.weight              8192   4096  1.714e-02      1.0969    0.13
blk.3.attn_q.weight                8192   4096  1.851e-02      1.1849    0.24
blk.0.ssm_alpha.weight               32   4096  2.456e-02      1.5720    0.65
blk.0.ssm_beta.weight                32   4096  8.180e-03      0.5235   -0.93
blk.0.attn_gate.weight             4096   4096  1.677e-02      1.0730    0.10
blk.0.ssm_out.weight               4096   4096  1.542e-02      0.9869   -0.02
blk.3.attn_k.weight                1024   4096  1.630e-02      1.0433    0.06
blk.3.attn_output.weight           4096   4096  1.569e-02      1.0038    0.01
blk.3.attn_v.weight                1024   4096  1.618e-02      1.0358    0.05
```

Every tensor kind, first layer, middle layer, last layer, and the lm head: the
rms row norm is **1.0 to within a factor of two**, i.e. `log2` in
`[-0.93, +0.65]`. That is what a trained transformer looks like and it is why a
residual stream does not explode.

The bench's `wword`, reconstructed as a matrix at the geometries its A jobs
actually use, over the same 297 A jobs of a 32-block token:

```
SYNTHETIC   mean log2 row norm  4.867   min 2.316   max 7.689
REAL pooled mean log2 row norm -0.034   min -0.975  max 0.827
REAL sliced mean log2 row norm -3.013   min -3.992  max -2.051
```

**Five octaves per matvec, from the stimulus alone.** The mechanism is not
subtle once it is stated: `wword` draws INT4 nibbles uniformly over the whole
codebook and masks the per-block scale into `[16384, 32767]`, i.e. into the top
octave of the uint15 range, so `|w|` is order `2**2` where a trained weight is
order `2**-6`.

### Step 3 -- the dimension reduction, which is the one modelling choice

`mk_shape_scaled` runs `hidden = 64` against the model's 4096 and `ffn = 128`
against 12288. A real weight matrix cannot be used at that width unchanged, and
the choice of how to shrink it DECIDES the answer, so both were built and both
are reported:

| `--reduce` | what it does | rms row norm |
|---|---|---|
| `slice` | `W[:n_rows, :n_cols]` -- the literal real weights, 1/64 the width | `2**-3.01` |
| `pool` | sum adjacent groups of `K/n_cols` columns | `2**-0.03` |

`slice` is honest and biased LOW by exactly `sqrt(n_cols/K)`, three octaves at
`K=4096`, and its measured -3.013 is that arithmetic and nothing else. `pool`
preserves the l2 row norm of the real layer, which is the quantity that decides
magnitude propagation, and it lands on the real model's own -0.03. **`pool` is
the primary result and `slice` is reported beside it**; neither was chosen to
make a number come out, and the third possibility -- scaling the slice by 8 --
was deliberately NOT used because that IS tuning.

### Step 4 -- the packing, proved twice and then proved again end to end

**(i) Layout, double oracle.** `ref/matvec_int4.c` and `tools/pack_int4.py
--crosscheck` are independent readers of the 6.4/6.5a layout. On a packed real
submatrix:

```
=== C reference ===
M=128 K=64 w_exp=-1 out_shift=3 ns=0 y_exp=-4 mant_sum=4401 sat=0
=== python oracle ===
M=128 K=64 w_exp=-1 out_shift=3 ns=0 y_exp=-4 mant_sum=4401 sat=0
```

**(ii) Quantization.** Dequantizing `(idx, scale, w_exp)` back to float and
comparing against the source submatrix: max relative error 1.19e-1 per element
(int4), **cosine 0.995705**, consistent with the 0.9967 the FK33 pack reported
for the same model at a different geometry.

**(iii) THE CHAIN, end to end, at the value level.** The two checks above say
nothing about the bench's own step/port/beat address decode, which is new code.
So region R_QKV after a 1-block `NORM_ANCHOR=false` token -- 256 elements, the
outputs of the three A jobs that write it -- was recomputed entirely outside
the simulator: `R_XN` from the behavioural norm's definition, then
`mv4i_matvec` from `ref/matvec_int4.c` on the three packed files, then the same
positional hash the bench uses.

```
step 1 rows 64  cols 64 w_exp -1 out_shift 1: y_exp 1 ns 0
step 2 rows 64  cols 64 w_exp  0 out_shift 2: y_exp 1 ns 0
step 3 rows 128 cols 64 w_exp  1 out_shift 3: y_exp 1 ns 0
R_QKV positional hash from ref/matvec_int4.c = 26889

tb_llama_top: region 2 hash 26889
```

**Bit-exact on all 256 values.** The quantizer, the 6.5a layout, the bench's
address decode and `matvec_int4`'s consumption of it all agree. This is the
check that licenses calling the run "real weights" rather than "weights of
about the right size".

### Step 5 -- the depth sweep, all four configurations

Degenerate residuals (P6), `NRUNS = 1`, real A, real B, `attn_interval` 4:

| BLOCKS | synthetic, no real norm | REAL, no real norm | synthetic + `NORM_REAL` | **REAL + `NORM_REAL`** |
|---|---|---|---|---|
| 1  | 1  | 0  | 0  | **0** |
| 2  | 2  | 1  | 2  | **0** |
| 4  | 5  | 3  | 6  | **0** |
| 8  | 12 | 9  | 14 | **0** |
| 16 | 27 | 23 | 28 | **0** |
| 32 | 56 | 51 | 59 | **0** |

Columns 1 and 3 reproduce the published 5/12/27/56 and 0/2/6/14/28/59 exactly,
so the harness did not move.

```
tb_llama_top: schedule mismatches=0 skew differences=0 degenerate residuals=0
tb_llama_top RESULT: PASS -- 491 descriptors, 32 blocks, 1 descriptor-latency
              points, R_X bit-identical across all of them, R_X(0) = -6317
              hash(R_X) = 83458
```

That is the whole 491-descriptor token, 32 blocks, real A, real B, real
`rmsnorm_rs`, real weights, and **no probe of any kind**. It is the first time
this bench has passed at 32 blocks without `NORM_ANCHOR`.

### The magnitude series, which is the deliverable

`log2 rms` of the norm's INPUT, at norms 0, 8, 16, 24, 32, 40, 48, 56, 64 of a
32-block token:

| configuration | 0 | 8 | 16 | 24 | 32 | 40 | 48 | 56 | 64 |
|---|---|---|---|---|---|---|---|---|---|
| synthetic, no real norm | 3.20 | 388.7 | 6495 | 26038 | 26051 | 26063 | 26072 | 26084 | 26099 |
| REAL (pool), no real norm | 3.20 | 51.07 | 808.3 | 12929 | 25860 | 25863 | 25867 | 25871 | 25875 |
| REAL (slice), no real norm | 3.20 | 4.20 | 8.46 | 29.04 | 325.2 | **-inf** | 19591 | 19592 | 19594 |
| synthetic + `NORM_REAL` | 3.20 | **15.10** | 15.10 | 15.10 | 15.10 | 15.10 | 15.10 | 15.10 | 15.10 |
| **REAL (pool) + `NORM_REAL`** | **3.20** | **3.72** | **4.10** | **4.33** | **4.62** | **5.07** | **5.22** | **5.28** | **5.24** |

and the first thirteen of the two extreme rows, per norm rather than per eight,
because the shape matters:

```
REAL + NORM_REAL   3.201 3.201 3.214 3.214 3.214 3.214 3.205 3.716 3.715
                   3.715 3.708 3.708 3.710
synthetic, none    3.201 6.350 27.81 27.81 70.76 ZEROS ZEROS 187.1 388.7
                   388.7 795.1 795.1 1605
```

Read the last row of the table as the answer: **2.04 octaves of growth over 32
blocks, 0.032 per norm.** That is the `sqrt(n)` accumulation a residual stream
is supposed to show (`sqrt(64) = 8` would be 3 octaves), and it sits at
`rms(x_real)` between `2**3.2` and `2**5.3` against a window of
`[2**-6, 2**12]` -- ten octaves of headroom at the top and nine at the bottom.

**The stream is NOT frozen, and this was checked rather than assumed**, because
PART 5's trap is exactly a bounded series produced by a dead machine: the run
reports **65 distinct `log2 rms` values over 65 norms**, zero occurrences of
the all-zeros rail, and P4 passes.

The `-inf` in the `slice` row is the same trap firing in the OTHER direction
and is worth keeping: the sliced weights are three octaves too small, so that
stream drifts DOWN through the window, hits the low rail, and the norm starts
emitting zeros at norm 40 (15 all-zero norms in that run). A weight image that
is too small fails as silently as one that is too large.

### The new instrument, and its oracle

`obs_norm_pub` / `obs_norm_exp` / `obs_norm_ssq` / `obs_norm_n` publish the
norm's input exponent, the integer sum of squares of its input mantissas and
the element count, once per norm op, from BOTH norm branches. The testbench
turns them into `log2 rms`; `ieee.math_real` stays out of `rtl/`.

It has an independent oracle at norm 0, whose input is the token embedding and
therefore known in closed form:

```
numpy over ((i*37) mod 251) - 125, i = 0..63, at x_exp 3 :  3.200506407691405
tb_llama_top: NORMMAG norm 0 run 0 xe 3 log2rms  3.200506407691405
```

### Teeth checks -- both results, as required

All at `BLOCKS = 4`, `NRUNS = 1`, `NORM_ANCHOR=false`, `NORM_REAL=true`, real
weights, a configuration the unbroken design PASSES:

```
control (unbroken)  degenerate residuals=0  RESULT: PASS
                    R_X(0) = -7263 hash(R_X) = 31328
```

| mutation | result |
|---|---|
| the bench's step decode reads `step+1` | **FAIL**, degenerate residuals 1 |
| the beat index computed with `/8` instead of `/16` | **assertion failure: weight read outside the image -- step 3 sub 3 port 3 beat 64** |
| a 1-block image handed to a 4-block run | **assertion failure: the weight image has 6080 words, this shape needs 20480. It was built for a different BLOCKS or ATTN_INT.** |
| the `NORM_REAL` adapter publishes `oe + 20` | **FAIL**, P6 fires: `the residual at step 10 has operand exponents 3 and 57, 54 apart` |

**Every one PASSES unbroken and FAILS broken.** The first is the important one:
it says the step decode is load-bearing, so the run really is fetching a
different matrix per step rather than the same bytes everywhere.

Skew, with the real weights in, `BLOCKS = 4`, `NRUNS = 4`, four
descriptor-memory latencies:

```
schedule mismatches=0 skew differences=0 degenerate residuals=0  RESULT: PASS
R_X(0) = -7263 hash(R_X) = 31328
```

Bit-identical to the single-latency run, so the file-backed slave introduces no
timing dependence.

## Measured and REJECTED -- do not retry (Part 6)

* **Blaming the BFP discipline for the twelve-octave-per-block growth.** It is
  the weight row norm and nothing else: 2**4.87 synthetic against 2**-0.03
  real, measured on both sides at the same geometry. Do not design a bounding
  mechanism for a growth rate that only the stimulus produces.

* **Reading PART 5's `NORM_Q` sweep as a statement about the unit.** 0/0/6/38
  at `Q = 20` was measured against the synthetic stream, which leaves the
  window whatever `Q` is. At the real stream's `log2 rms` of 3.2 to 5.3, `Q`'s
  default 12 has ten octaves of headroom and the sweep is answering a question
  that does not arise. The 2026-08-26 conclusion that a wider `Q` is not the
  fix STANDS for the low rail and for `rmsnorm_bf`; it is simply not what
  PART 5 was hitting.

* **The column SLICE as the dimension reduction, on its own.** It is the
  literal real weights and it is biased low by exactly `sqrt(n_cols/K)`, three
  octaves, which is enough to drive the stream through the LOWER rail by norm
  40 and produce 15 all-zero norms. Reported here, and not used as the primary
  result, for that reason. A reduction that does not preserve the row norm is
  measuring the reduction.

* **Trusting a layout crosscheck as evidence that the weights reached the
  unit.** The C-reference/Python agreement proves the FILE is right and says
  nothing about the bench's address decode, which is where the new code is.
  The R_QKV hash is the check that closes it, and the `step+1` mutant is what
  says that check has teeth.

## Measurement traps hit (Part 6)

* **A 20 MB array in a VHDL FUNCTION LOCAL segfaults GHDL at elaboration with
  no output whatsoever.** The image is `491*5*64` words of 128 bits and GHDL
  stores one `std_logic` per byte, so the first version -- a
  `constant WIMG : wimg_t := load_wimg(...)` -- died instantly at
  `BLOCKS = 32` while working perfectly at `BLOCKS = 4`. It reads as a broken
  testbench. `--max-stack-alloc=0`, which this project already passes, does
  NOT cover it; `ulimit -s unlimited` does, which is how the cause was
  identified, and is not a fix because `sim/regress.sh` does not set it. The
  storage is now a protected type holding an ACCESS-type array allocated with
  `new`, so nothing large is ever on the stack.

* **`to_integer` on the sum of squares OVERFLOWS.** 64 elements of a 16-bit
  mantissa reach `2**36` and VHDL's integer is 32-bit, so the conversion to
  `real` has to go bit by bit. Same class as PART 2's `idx*7919`: a run-time
  abort from inside the stimulus, which reads like broken RTL.

* **The attention layers have no `attn_gate` tensor.** `att_qg = 2*att_q`
  looks like "Q and a gate", i.e. two tensors, and it is ONE: this model's
  `blk.N.attn_q.weight` has 8192 rows against `attn_q_heads*attn_head_dim =
  4096`. Only the 24 GDN layers have `attn_gate`. Assuming the split cost a
  full regeneration of the 32-block image.

* **A private snapshot of the closure is STILL the only way to measure.**
  Same trap as PARTS 3, 4 and 5. The snapshot here was verified to reproduce
  all three published baselines before anything was changed in it.

* **A `pool`-reduced image and a `slice`-reduced image are both "real
  weights", and they disagree by three octaves.** Whichever is quoted, the
  reduction has to be quoted with it. A result stated as "with real weights"
  and no reduction named is not reproducible.

## Open, not yet answered (Part 6)

* **Everything above is at the SCALED shape.** `hidden = 64`, `ffn = 128`, one
  token, `tk0` hardwired. The row norms are the real model's, the values are
  the real model's to `cosine 0.9957`, and the WIDTH is not. Nothing here says
  what the stream does at `hidden = 4096`, where every matvec sums 64 times as
  many terms and `ns` will differ.

* **The `rmsnorm_rs` low rail and the missing epsilon are UNTOUCHED.**
  `docs/debugging/2026-08-26_rmsnorm-magnitude-window.md` measured that the
  real model spends 77.4% of its samples where epsilon IS the normaliser, and
  that `rmsnorm_rs` is wrong by 244x in eps and 14x in gain AT THE MEDIAN. The
  stream measured here sits at `log2 rms` 3.2 to 5.3, comfortably inside the
  clamp-free region, so this schedule never exercises that defect. `NORM_REAL`
  passing at 32 blocks is NOT a statement that `rmsnorm_rs` computes the right
  function -- `rtl/rmsnorm_bf.vhd` exists precisely because it does not, and
  it was not measured here either.

* **There is still no block-level arithmetic oracle.** The R_QKV check is a
  value-level oracle for THREE A jobs of one block. Every property beyond that
  is still a property and not a comparison.

* **The swiglu is still a model with a fixed `MANT_W` shift**, and the FFN
  residual is still the one PART 4 named. It no longer fails at any depth with
  real weights and a real norm, which is a measurement and not a fix.

* **`NRUNS = 1` for the depth sweep.** The 4-block real-weight point was taken
  at `NRUNS = 4` and is skew-clean; the 32-block point is single-latency and
  is not a skew claim.

* **B_SRC_REAL was not re-tested with real weights**, and it is the obvious
  next experiment: PART 3 rejected it because A's synthetic weights made
  R_ALPHA's VALUES physically impossible and `gdn_scalar`'s gate saturated
  shut. That reason has now been removed. PART 3's own rejection note said to
  re-run it "only after subsystem A's weights are real". They are.

## CORRECTION to PART 5

PART 5 concluded:

> **`rmsnorm_rs` on the D-vec norm op as a fix for defect 8, as built.** [...]
> the result is 0/2/6/14/28/59 at 1/2/4/8/16/32 blocks, worse than the probe at
> every depth and worse than no norm at all at 32. Do not re-run it hoping for
> a different answer.

**WITHDRAWN.** With real weights it is 0 at every one of those depths and the
32-block token PASSES. The measurement PART 5 reported is correct and
reproduces exactly; what is withdrawn is its attribution. The 19-octave window
is real, the all-zeros rail is real, and the design does not go near either of
them once the weights are. PART 5's own closing sentence -- "Re-run it only
after something bounds the residual stream's MAGNITUDE" -- named the right
condition and assumed it needed new hardware. It needed a physical stimulus.

PART 5's measurement traps and its teeth checks are NOT withdrawn, and the
first of them is the reason this part checked for a frozen stream before
believing a bounded one.

## CORRECTION to PART 3

PART 3's costed recommendation, that a real rmsnorm on the D-vec norm op is
"the one to pick", was **WITHDRAWN by PART 5**. It is now **REINSTATED**, with
the measurement PART 3 asked for and PART 5 could not obtain: real unit, real
weights, no probe, 0 degenerate residuals at 1, 2, 4, 8, 16 and 32 blocks.

PART 3's mechanism was right throughout and is confirmed independently here:
with real weights and NO real norm the stream still runs away, `log2 rms` 3.20
to 25875 over 32 blocks. Nothing else in the block loop restores the scale.

---

# PART 7 -- `attn_block` wired into `llama_top`, and the whole token with A, B, C, the norm and the weights all real

**Date:** 2026-08-28, later the same session. Appended in place.

**Build:** branch `fpga`. Modified: `rtl/llama_top.vhd` (a `C_REAL` generic and
the generate branch it selects: the `attn_block` instance, three activation
prefetches, a KV-cache memory model and the y sink), `sim/tb_llama_top.vhd`
(the `C_REAL` and `ATTN_HD` generics, and P5 given its second half), and
`rtl/llama_map_pkg.vhd` (one defaulted parameter on `mk_shape_scaled`).
`rtl/attn_block.vhd` and `rtl/attn_mac_array.vhd` were **NOT modified**.
`C_REAL` defaults FALSE and the default path is verified bit-identical:
`R_X(0) = -12049 hash(R_X) = 86767`.

**Tools:** GHDL 1.0.0 mcode, `--std=08 -frelaxed --max-stack-alloc=0`. No
synthesis, no hardware.

## The question, verbatim

> `rtl/attn_block.vhd` and `rtl/attn_mac_array.vhd` now exist (commit
> `1719ae3`, gate 76 PASS). `llama_top` still drives the attention stub [...]
> Replace it, behind a generic that DEFAULTS to the existing stub so the
> default path stays bit-identical [...] **there is no block-level arithmetic
> oracle for C.** [...] Do not let the integration imply otherwise.
>
> Success criterion: the 491-descriptor schedule runs with real A, real B and
> real C, and you report the degenerate-residual counts by depth WITH `NRUNS`
> stated, next to today's numbers.

## The answer, up front

**It runs, and with PART 6's real weights and the real `rmsnorm_rs` alongside
it, the whole 491-descriptor 32-block token PASSES with zero degenerate
residuals.** That is the first configuration in this file in which every
computing unit in the block loop is real RTL and no probe is enabled.

Swapping the stub for the real block changes nothing about P6, which is the
useful negative result: anchored, `NRUNS = 1`, synthetic weights, the counts
are **identical** to the stub's at every depth.

**And it says nothing about whether the block computes attention.** There is
no block-level reference for C; the bench's own PASS line now says so.

## What had to change in the SHAPE, and why it costs nothing

`attn_block` will not elaborate at `mk_shape_scaled`'s attention shape. Three
separate refusals, each read out of the RTL rather than discovered by running:

| constraint | source | the old shape |
|---|---|---|
| `HEAD_DIM` must be an EVEN power of two | `attn_block.vhd:616` -- `kq_scale = 1/sqrt(HEAD_DIM)` is folded into an exponent | 32 = 2**5, **fails** |
| `HEAD_DIM/KV_BLOCK >= 2` | `attn_block.vhd:610` | fine |
| GQA group `N_QH/N_KVH >= 2` | `attn_block.vhd:607`, `attn_mac_array` | 2/1 = 2, fine |
| `NGRP >= 2` | **NOT asserted anywhere.** `attn_emit.vhd:400` assigns `grp <= 1` at S_IDLE with `grp` ranged `0 to NGRP-1` | 1 KV head, **bound check failure** |

The last one is a latent defect in a unit that is verified and is not mine to
edit; it is recorded here and NOT fixed. It is found only at run time, deep
inside the block, as `bound check failure at attn_emit.vhd:400`.

**The fix costs nothing measurable because only the SPLIT moves.**
`mk_shape_scaled` gained one defaulted parameter, `attn_hd`, and derives
`attn_q_heads = 64/attn_hd` and `attn_kv_heads = 32/attn_hd`, so
`att_q = 64`, `att_qg = 128` and `att_kv = 32` at every legal value:

| `attn_hd` | q heads | kv heads | att_q | att_qg | att_kv |
|---|---|---|---|---|---|
| 32 (default) | 2 | 1 | 64 | 128 | 32 |
| 16 (C_REAL)  | 4 | 2 | 64 | 128 | 32 |

Every descriptor, every region size and every published landmark is therefore
unchanged, and the two configurations are directly comparable. Verified: the
bench default still gives `R_X(0) = -12049 hash(R_X) = 86767`.

## What the adapter owns, and the three contracts it had to honour

1. **The activation ports are PREFETCHED, not arbitrated.** `attn_block` is
   the master of three independent one-cycle read ports (`qg`, `kin`, `vin`)
   and may drive any of them in any cycle; the region file has ONE element
   port per client. All three regions are copied into local planes before
   `start`, with the same two-edge discipline every other adapter here uses,
   and the ports are then served with the exact hold contract
   `attn_kv_quant.vhd:103-104` states.

2. **The three source exponents are claimed ONE AT A TIME.** The lock has one
   combinational exponent port, arbitrated on `act_unit`. The prefetch claims
   R_QG, then R_KIN, then R_VIN, and captures each at the end of its own
   phase. Reading all three from one claim is defect 2's family.

3. **The KV cache is a memory, and one token means it is never read.**
   `attn_kv_axi` does not exist. `llama_top` runs ONE token with `tk0`
   hardwired, so `cur_pos = 0` and `ctx_len = 1`: the block takes its bypass
   path, which is `tb_attn_block`'s JOB_POS = 0 case. **The cache read path in
   this file is written and unexercised**, and that is stated in the RTL
   because a wired-looking path nobody runs is worse than an absent one.

## The evidence

### Degenerate residuals by depth, `NRUNS = 1`, next to today's numbers

Synthetic weights, `attn_interval` 4, real A and real B throughout:

| BLOCKS | stub C, anchored | **real C, anchored** | stub C, unanchored | **real C, unanchored** |
|---|---|---|---|---|
| 1  | 0 | **0** | 1  | **1** |
| 2  | 0 | **0** | 2  | **2** |
| 4  | 0 | **0** | 5  | P4 fails, R_X is all zero |
| 8  | 0 | **0** | 12 | P4 fails |
| 16 | 3 | **3** | 27 | P4 fails |
| 32 | 8 | **8** | 56 | P4 fails |

**The anchored column is identical, depth for depth.** Replacing a `-32768 + i`
ramp with ten real units moves P6 by nothing, which is what it should do:
P6 measures the residual's SCALE and PART 2's defect-7 fix already had the stub
publishing its source region's exponent.

The unanchored column is where the real block differs, and it differs by
failing harder: from 4 blocks on, R_X ends as a vector of zeros and P4 -- "the
residual actually moved" -- fires. That is the same mechanism PART 6 measured
from the other side. `attn_block` contains `rmsnorm_rs` instances of its own
for the QK-norm, so it carries the same 19-octave input window, and the
unanchored stream leaves it. **A configuration that was merely wrong is now
visibly dead, which is an improvement in the instrument, not a regression.**

### Everything real: A, B, C, the norm AND the weights

`C_REAL`, `NORM_REAL`, `NORM_ANCHOR=false`, `W_IMAGE` = the PART 6 pooled real
Qwen3.5-9B image, `NRUNS = 1`, `attn_interval` 4:

| BLOCKS | degenerate | verdict | landmark |
|---|---|---|---|
| 1  | 0 | PASS | `R_X(0) = -16525 hash(R_X) = 32918` |
| 2  | 0 | PASS | `R_X(0) = -16058 hash(R_X) = 43635` |
| 4  | 0 | PASS | `R_X(0) = -16339 hash(R_X) = 92903` |
| 8  | 0 | PASS | `R_X(0) = -18752 hash(R_X) = 16447` |
| 16 | 0 | PASS | `R_X(0) = -21515 hash(R_X) = 16209` |
| **32** | **0** | **PASS** | `R_X(0) = -14110 hash(R_X) = 52347` |

```
tb_llama_top: schedule mismatches=0 skew differences=0 degenerate residuals=0
tb_llama_top RESULT: PASS -- 491 descriptors, 32 blocks, 1 descriptor-latency
              points, R_X bit-identical across all of them, R_X(0) = -14110
              hash(R_X) = 52347
```

`log2 rms` of the norm's input over that run, at norms 0, 8, 16, 24, 32, 40,
48, 56, 64:

```
3.20  3.24  3.22  3.22  3.23  3.23  3.30  3.33  3.34
```

**Flat to a third of an octave over 32 blocks**, 65 distinct magnitudes over 65
norms, zero all-zero norms. Flatter than PART 6's stub run (3.20 -> 5.24),
which is the expected direction: the stub was writing a saturated `-32768`
ramp into the stream and the real block is not.

Skew, same configuration at `BLOCKS = 4`, `NRUNS = 4`, four descriptor-memory
latencies: `schedule mismatches=0 skew differences=0 degenerate residuals=0`,
PASS. The three prefetch phases and the y sink are not timing-dependent.

### Teeth checks -- both results, as required

Control: `BLOCKS=4 ATTN_INT=4 NRUNS=1 C_REAL ATTN_HD=16 NORM_REAL` with the
real weights, `PASS`, 0 degenerate, `R_X(0) = -16339 hash(R_X) = 92903`.

| mutation | result |
|---|---|
| the C_REAL branch sets `f_stub` | **FIRES**: "C_REAL is set and the schedule ran 1 attention block(s), but err_unit_stub is HIGH. Some unit still took the stub path." |
| the y sink drops one beat | **FIRES**: "unit C emitted 63 y elements, the job needs 64", then P3's "an un-stallable producer beat was lost" -> assertion failure |
| `C_REAL` with `ATTN_HD = 32` | **FIRES** at elaboration: "HEAD_DIM is not an even power of two" |
| the R_VIN exponent claim pointed at R_X | **PASSES BROKEN.** `R_X(0) = -16565 hash(R_X) = 74876` against the control's `-16339 / 92903` |
| the R_QG prefetch consumes at k-3 instead of k-2 | **PASSES BROKEN.** `R_X(0) = -15999 hash(R_X) = 28361` |

One more guard was added after the first pass and it fires on a REAL
configuration rather than on a mutant. Subsystem C's exponent ports are 8-bit
signed by spec and the residual stream's exponent is 16-bit here, so the
narrowing on the way in would WRAP silently -- the same defect class PART 3
found in subsystem B's ports. Free-running, the check fires **175,313 times**
in the unanchored 32-block real-C run and is silent in every configuration
that passes; it is now sticky, reports once and sets `f_lost`.

The first three have teeth. **The last two do not, and that is the result, not
a gap in the report.** Both mutations are load-bearing -- each changes every
element of the residual -- and no property in this bench can see either,
because both are deterministic wrong numbers that every latency reproduces
identically. **This is defect 2's family for the fourth and fifth time in this
file.** The only instrument that catches them is reading the code.

**The three `exp_rd_valid` asserts on R_QG, R_KIN and R_VIN have NEVER FIRED
and could not be made to.** Every attention block in a legal schedule is
preceded by a GDN block that captures every region, so no reachable
configuration reaches a C job with an uncaptured claim. An all-attention
schedule would, and `BLOCKS=2 ATTN_INT=1` does not elaborate at all -- a
pre-existing bound check inside `matvec_int4`'s declarative elaboration, not
caused by this work and not chased here. **The three asserts are wired and
unproven.**

### The gate

`sim/regress.sh`, full both-suite run on the final tree, with `W_IMAGE` at its
default `""` and `C_REAL` at its default FALSE:

```
 suite sim   PASS 51   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 77   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5
 baseline: 77 passing, matches the recorded floor of 77
 REGRESSION: PASS
```

No bench was added here.  The floor moved 76 -> 77 during this session because
another agent added one and raised it; the run above is against that floor and
matches it.

## Measured and REJECTED -- do not retry (Part 7)

* **One KV head.** `attn_emit.vhd:400` assigns `grp <= 1` with `grp` ranged
  `0 to NGRP-1`, so `N_KVH = 1` is a run-time bound check failure inside a
  verified unit. Do not build a shape with one KV head expecting the block to
  refuse cleanly; it aborts halfway through the first attention block.

* **`attn_head_dim = 32` with the real C.** `2**5` is not an even power of
  two, `kq_scale` cannot be folded, and the block refuses at elaboration. It
  is the DEFAULT of `mk_shape_scaled` and every published landmark in this
  file is at it, which is why the parameter exists rather than the constant
  being changed.

* **Expressions in a port map, on GHDL 1.0 mcode.** `qg_exp => resize(qg_e, 8)`
  as an actual raised `Exception TYPES.INTERNAL_ERROR : trans.adb:553` -- a
  GHDL bug report, not a diagnostic, which reads as a broken design. Every
  actual is now a plain signal or constant and the intermediate assignments
  are concurrent statements.

* **A read-latency mutant that indexes off the end.** `qg_buf(k-1)` at
  `k = QGN+1` aborts with `index (128) out of bounds`, which is a broken
  mutant and not a result. PART 5 recorded this exact trap; it cost time
  again. The useful mutant moves the index the OTHER way, `k-3`, which stays
  in range.

## Measurement traps hit (Part 7)

* **`clog2(1) = 0` makes a port a NULL VECTOR**, and every `to_integer` on it
  prints `NUMERIC_STD.TO_INTEGER: null detected, returning 0`. Thousands of
  them, mixed into the metavalue warnings, and they are harmless and correct.
  They are also the only visible symptom that a shape has one KV head.

* **A `report ... severity error` is not a verdict.** The y-element-count
  check was written as a bare report; the mutant that drops a beat printed it
  and the run still said PASS, because `sim/regress.sh`'s `FAIL_RE` carries
  six specific literals and that string contains none of them. It now sets
  `f_lost`, which P3 reads, so the run FAILS.

* **A mutant that changes nothing is not a passing teeth check.** Pointing the
  R_VIN claim at R_ALPHA left the hash bit-identical -- the two regions happen
  to carry the same captured exponent in that run -- which reads as "the guard
  has no teeth" and is really "the mutation was a no-op". Re-aimed at R_X,
  whose exponent is far away, it changes every element.

* **The regression runner prints its summary TWICE without `--keep`**, and the
  second copy reads a scratch directory it has already deleted, so it reports
  `PASS 0 FAIL 81` under the genuine `REGRESSION: PASS`. Read the FIRST
  summary; it is the one with a baseline line under it.

## Open, not yet answered (Part 7)

* **Nothing establishes that the block computes attention.** This is the
  headline open item and it is unchanged: `ref/attn_gated_fx.c` does not
  exist, `sim/tb_attn_block.vhd` checks seams, and `sim/tb_llama_top.vhd`
  checks the schedule and the scale. The integration replaced a unit that was
  deliberately, visibly wrong with one that is plausibly right and unverified
  at block level.

* **`attn_kv_axi` is still absent**, and one token means the cache read path
  in this file has never executed. Everything the AXI unit would provide --
  4 KB burst splitting, record-phase realignment, drain-then-flush on `start`,
  `done` gated on BRESP -- is still missing, and now it is missing behind a
  port that looks connected.

* **The KV cache write path IS exercised and its contents are never read
  back**, so a wrong record layout would be invisible.

* **One token, `cur_pos = 0`.** `v_ref` is a per-SEQUENCE fold and its
  multi-token behaviour -- the whole reason the fold is per sequence -- is not
  exercised. `kv_seq_rst` is driven as a level held until `seq_rst_taken`, and
  taken once after reset.

* **The QK-norm gains are fixed-scale stand-ins**, like the D-vec norm's and
  B's conv weights, for the same reason: they are learned weights with no
  region and no packing.

* **The unanchored real-C path fails P4 from 4 blocks up** and the mechanism
  is inferred from PART 6 rather than instrumented: `attn_block`'s own
  `rmsnorm_rs` instances presumably hit their zero rail. No probe was put
  inside the block to confirm it.

* **`NRUNS = 1` for the depth sweep.** The 4-block point is skew-clean at
  `NRUNS = 4`; the 32-block point is single-latency.

* **No synthesis.** The `G`-cone DSP cost the subsystem C write-up derived
  (C aux 47 -> 87, C total 431 -> 471) is still arithmetic on a skeleton's
  rows, and now there is an integration to price as well.

---

## CORRECTION, 2026-08-29, appended by TRACK C1: the 32-block landmark moved

The table in "Everything real: A, B, C, the norm AND the weights" ends with

| **32** | **0** | **PASS** | `R_X(0) = -14110 hash(R_X) = 52347` |

**That row is superseded, and the move is a FIX rather than a regression.**
`BLOCKS=32 ATTN_INT=4` is EIGHT attention layers, and until 2026-08-29
`rtl/attn_block.vhd`'s `v_ref` fold had no layer index, so all eight shared one
fold per KV head (defect C1, found by TRACK RY-ORACLE, fixed here). With the
fold given its missing `LAYERS` dimension the same configuration MEASURES

```
tb_llama_top RESULT: PASS -- 491 descriptors, 32 blocks, 1 descriptor-latency
  points, R_X bit-identical across all of them, R_X(0) = -14035
  hash(R_X) = 43861
tb_llama_top: schedule mismatches=0 skew differences=0 degenerate residuals=0
```

The **1, 2 and 4 block rows of that same table are UNCHANGED** -- they have one
attention layer, where a per-layer fold and a shared fold are the same object --
and the 4-block row's whole 63-record seam capture is byte-identical across the
fix. That contrast is the attribution. The 8 and 16 block rows were not re-run.

Full chain, including the R_Y value oracle going 4 of 6 to 6 of 6 and the OOC
resource cost: `docs/debugging/2026-08-29_c1-vref-layer.md`.
