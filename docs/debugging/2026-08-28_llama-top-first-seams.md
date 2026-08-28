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
