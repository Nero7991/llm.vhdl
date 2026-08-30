# Is the tree green, and what is `BASELINE_PASS` actually?

**Date:** 2026-08-30
**Track:** GATEGREEN
**Box:** the workstation (31 GiB, 24 threads, GHDL 1.0.0 mcode). No hardware touched.

## The question, verbatim

> 32 commits have touched `rtl/` or `sim/` since last night, from eight parallel
> tracks, and NOBODY HAS RUN THE FULL GATE. The last clean full-gate run was
> against `2217778`. [...] `BASELINE_PASS` is still 99 and is now wrong in at
> least two directions [...] Your job: find out whether the tree is green, and
> leave `BASELINE_PASS` correct.

## The answer, up front

**The tree is GREEN at `32a7b472f8d4b010c004426871f70bfae5eb05fc`.** Full,
unfiltered, both-suite run on a clean `git archive`, `--jobs 1`. Nothing red,
nothing without a verdict, nothing timed out, nothing failed to build:

```
 suite sim   PASS 79   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 3
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 105   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4   SKIPPED 6
```

**That 105 is NOT the floor and must not be written into `BASELINE_PASS`.** Four
rows in it ran only because this box happens to hold a `.mv4i` from a GGUF model
set that is not in git. The gate detected that itself and refused to suggest the
raise. The floor is a clean-checkout number and is being re-measured with the
documented `MV4I_FK33_FILE=/nonexistent` recipe; see "The floor" below.

**The gate is GHDL only.** It says nothing about synthesis, timing, placement,
area, power, or the card. See "What this does NOT cover", which is the section
that matters most on a day when several tracks quoted area and timing numbers.

## What was measured, exactly

- **Tree:** `git archive 32a7b472f8d4b010c004426871f70bfae5eb05fc`, extracted to
  `/mnt/storage/track-gategreen/tree`. Not the working tree. At the moment the
  run started, the working tree carried uncommitted hunks in `rtl/llama_top.vhd`,
  `hw/design_mv_generated.tcl`, `hw/fk33/host/fk33_run_layer.py`, four `tools/*.py`
  and one `docs/debugging/*.md` from other tracks, plus a live `ghdl-mcode`
  mutation run from TRACK BASEFAB against `tb_llama_top`. **A floor measured
  against uncommitted work is not a floor**, and neither is a verdict.
- **Runner:** `bash sim/regress.sh --jobs 1`, `REGRESS_SCRATCH` set so the
  evidence survives.
- **Tool:** `GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6) [Dunoon edition]`, mcode backend.
- **Start:** 2026-08-30 08:20:06.
- **Containment:** a transient systemd user unit,
  `systemd-run --user --unit=gategreen-full -p MemoryHigh=8G -p MemoryMax=12G`.

MEASURED, `/sys/fs/cgroup/.../gategreen-full.service/memory.peak`: **2.13 GiB**
peak for the whole run. The `MemoryHigh=8G` soft cap was never approached, so
this is a real peak and not the cap being reported back (the failure mode
recorded in `cc06f35`).

**That is the useful memory result and it corrects an assumption in my own
brief.** CLAUDE.md's `ghdl-mcode` figure of 20.9 GiB is real but it is not this
workload: the full gate at `--jobs 1` costs 2.13 GiB, which is roughly a fifth of
one Vivado. The 20.9 GiB class belongs to elaborating a top level at an
unreduced shape (`sim/regress.sh` records `tb_realshape_9b` once needing ~46 GB
and dying `STORAGE_ERROR` before it was reduced to 2.2 GB). **The full gate is
not the box-killer it was being treated as, and it can safely run beside one
Vivado.** A `place_design` from TRACK TIMING held 7 to 10.6 GiB throughout and
`MemAvailable` never fell below 19 GiB; the low-memory alarm armed at 3 GiB never
fired.

## The rows the 32 commits touched, all green

Every file named in the brief as changed has its row, and every one passed:

```
PASS       sim:tb_attn_block                      2s   (min-fold reassociation)
PASS       sim:tb_matvec_core                     0s   (codebook restructure)
PASS       sim:tb_matvec_cb_contract              0s
PASS       sim:tb_matvec_cb_lockstep              0s
PASS       sim:tb_fk33_seam                      55s   (new, TRACK DSEAM, 9270c7a)
PASS       sim:tb_rmsnorm_rs_mem                  1s   (new, TRACK RMSMUX, ce7b836)
PASS       sim:tb_rmsnorm_rs                      4s
PASS       sim:tb_llama_top                     111s   (gvr / ga_real regions)
PASS       sim:tb_llama_top_real                 77s
PASS       sim:tb_llama_top_normw                76s
PASS       sim:tb_llama_top_seq                 311s
PASS       sim:tb_llama_top_smp                   1s
PASS       sim:tb_llama_top_smp_beh               1s
PASS       sim:tb_axi_rd_port                     1s   (scoping)
PASS       sim:tb_axi_rd_port_dual                0s
PASS       sim:tb_axi_rd_port_stray               0s
PASS       sim:tb_realshape_9b                    3s
```

No bisection was needed, because nothing was red.

## The floor

`BASELINE_PASS` was 99, raised by `912ada7` from a measurement on
`git archive 2217778`. The brief's claim that "nobody has run the full gate" is
**not quite right and the correction matters**: TRACK STRAYROW did run one, on a
clean archive, and its recipe is written out in `sim/regress.sh` at line ~470.
What is stale is not the practice but the number.

**Row-set arithmetic, DERIVED.** `--list` on the clean archive of `32a7b47`
plans **109** RUN rows. At `2217778` it planned 107 (`109 - 2`), of which 4 were
skipped for the absent `.mv4i`, giving the recorded `103 selected, 4 NOCHECK,
99 ceiling`. `git log --name-status 2217778..32a7b47 -- 'sim/tb_*.vhd' 'tb/tb_*.vhd'`
shows exactly two additions and no deletions:

```
A  sim/tb_fk33_seam.vhd        9270c7a  TRACK DSEAM
A  sim/tb_rmsnorm_rs_mem.vhd   ce7b836  TRACK RMSMUX
```

So the predicted floor is `99 + 2 = 101`. **That prediction is written down here
before the measurement precisely so it can be wrong**, which is the lesson of the
`93 -> 98` entry where the same arithmetic predicted 97 and the measurement said
98, and the discrepancy of exactly one was the only thing that found a committed
1076-line bench nobody had counted.

**MEASURED, and it is 101.** Same clean archive of `32a7b47`, same `--jobs 1`,
with the documented `MV4I_FK33_FILE=/nonexistent`:

```
 suite sim   PASS 75   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 3
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4 (1)
 OVERALL     PASS 101   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4   SKIPPED 10
 baseline: 101 passing, above the recorded floor of 99 -- raise BASELINE_PASS in this script
 REGRESSION: PASS
```

The gate printed the **raise suggestion** rather than either refusal, which is
the evidence that its `NOT IN GIT` list and its optional-row list were both
empty. `SKIPPED` went 6 to 10, which is the four FK33 rows correctly skipping.
The prediction of 101 held, and it was still measured rather than assumed.

### And it is still not being applied. `BASELINE_PASS` stays at 99.

`sim/tb_a_wbase.vhd` landed in **`d7a6bf7`** (TRACK BASEFAB) **after** the
archive was taken. MEASURED, `git merge-base --is-ancestor d7a6bf7 32a7b47`:
not an ancestor. So it is a **third** auto-discovered row today, alongside
DSEAM's and RMSMUX's, and my 101 does not include it.

**101 is a correct floor for `32a7b47` and a stale one for HEAD. 102 would be
arithmetic over a row nobody has run.** The box was going down and a fresh full
run was not available, so the number stays at the known-stale 99, which is low
and therefore prints "raise it" on every run rather than blocking anybody. The
measurement is recorded in `sim/regress.sh`'s comment block so the next track
can close it with one run and no re-derivation.

The asymmetry is the whole argument, and this file already contains the
counter-example: **the number 101 was once set above the tree's own ceiling and
every full run for every track reported `BASELINE DROP` until it was corrected.**
A floor that can only ever fire is worth exactly what one that can never fire is
worth. A stale floor fails loudly; a wrong one passes quietly.

**To close it:** one full clean-archive run at a settled HEAD, same recipe, then
set the number it prints. Expect 102 and be ready to be wrong.

## The trap I hit myself

**I ran the first full gate without `MV4I_FK33_FILE=/nonexistent`.** The
prerequisite `/mnt/storage/llama-models/qwen35-9b-mv4i/blk.11.attn_k.weight.mv4i`
has existed on this box since 28 Aug 14:21, so all four `sim:tb_matvec_fk33*`
rows ran and passed, and the headline came out 105 rather than the floor number.

This is worth recording as a **guard passing its teeth-check on me**, not as
wasted time. The gate did not quietly accept a raise to 105. It printed:

```
 baseline: 105 passing, above the floor of 99 -- but this tree has rows a clean
 checkout does not get: sim:tb_matvec_fk33 sim:tb_matvec_fk33_desc
 sim:tb_matvec_fk33_desc_dual sim:tb_matvec_fk33_desc_xexp.  DO NOT raise
 BASELINE_PASS from this run [...]
```

That guard was added after `101` was set from a tree carrying rows nobody else
had. It has now been shown to discriminate on a live operator error, which is
more than most checks in this repository can say.

Note the second-order point: the `NOT IN GIT` section printed nothing, correctly,
because a `git archive` tree has no `.git` and the check is skipped in silence
there. The optional-row refusal is a **separate** mechanism and it is the one
that fired. Had only the `NOT IN GIT` check existed, 105 would have looked
raisable.

## What this does NOT cover

Stated plainly because a green gate is being read today alongside area and
timing claims from several tracks, and it supports none of them.

**The gate is GHDL simulation and a handful of Python self-checks. That is all.**

- **No synthesis.** No LUT, FF, DSP, BRAM, URAM, MUXF7 or CLB number in this
  repository is touched by it. Nothing here contradicts or confirms LEVERC,
  RMSMUX, NORMURAM, TWOCARD, PACKSTRIPE or SCATTER.
- **No timing.** No WNS, no Fmax, no 200 MHz claim. `tb_fk33_seam` passing means
  the RTL simulates correctly at its testbench's clock, not that it closes.
- **No placement, routing, congestion or area.** TRACK TIMING's squeeze is
  invisible to it in both directions.
- **No card.** No bitstream, no PCIe, no HBM hardware, no XDMA, no thermal
  behaviour. The FK33 rows read a packed `.mv4i` file from disk.
- **No power, no VCCINT, no I2C.**
- **Six rows are SKIPPED by design**: the `*_cmp` benches declare `library beh`
  and are post-synthesis netlist-versus-behavioural comparisons needing Vivado
  xsim and UNISIM. **The netlist is never compared to the behavioural model by
  this gate.**
- **Four rows are NOCHECK**: `sim:tb_attn_beh`, `sim:tb_swchain_beh`,
  `sim:tb_gdn_conv_cycles` and `tb:tb_engine_dbg` are not self-checking. They
  prove elaboration and termination, nothing more.
- **Five `rtl/` files are reached by no testbench in either suite**:
  `attn_c_ports_skel.vhd`, `attn_lane_skel.vhd`, `hbm_tg_ip.vhd`,
  `seq_top_skel.vhd`, `tp_collective_skel.vhd`. 5 of 93.
- **Green is a statement about ONE commit.** See the next section.

### And a green row is not the same size as it looks

Two results from other tracks today, both about rows inside this gate, and both
of which shrink what a `PASS` in my table is worth:

- TRACK ATTNTEETH (`5755473`): `sim:tb_attn_block` **passed a broken tree**,
  because the oracle's V stimulus had no block-exponent spread and the fold had
  nothing to fold.
- TRACK BASEFAB's new `sim/tb_a_wbase.vhd` kills 8 of 11 mutants, and **its own
  attribution control denies it credit for seven of the eight.** Only one is a
  detection the pre-existing rows do not already make; the rest fire because a
  recorded numeric landmark happens to be address-sensitive, not because
  anything in the gate checks addresses.

Read together, those say something specific about this suite: **a large part of
its apparent discrimination is incidental.** Rows kill mutants because a number
somewhere downstream happens to move, not because a property is being asserted.
That is the "structure is not values" failure at the level of the gate rather
than the unit, and the only instrument that finds it is a mutation run with the
attribution control, which is not something a full-gate PASS can substitute for.
`OVERALL FAIL 0` means no row noticed anything. It does not mean the rows would
notice.

## The result's expiry date, and it is short

`git rev-parse HEAD` was `8b7eefe` when this track started, `32a7b47` when the
archive was taken, and **`729df43` about ninety minutes later: forty commits
later.** The verdict above is a statement about `32a7b47` and nothing else.

MEASURED, `git log --name-status 32a7b47..729df43 -- rtl/ sim/ tb/`: the only
gate-relevant changes are `rtl/llama_top.vhd` (modified) and
`sim/tb_attn_block.vhd` (modified, TRACK ATTNTEETH). **No `tb_*.vhd` was added
or removed**, so the ROW SET is unchanged and whatever floor is established at
`32a7b47` is still the correct floor at `729df43`.

Two consequences that should not be glossed:

1. **`rtl/llama_top.vhd` changed after the tree I measured.** The six
   `tb_llama_top*` rows were green at `32a7b47` and have not been run since. That
   is the largest uncovered surface in this report.
2. **`sim:tb_attn_block PASS` in my table was measured against the OLD oracle.**
   TRACK ATTNTEETH's `5755473` states that bench "passed a broken tree because
   the ORACLE'S V stimulus had no block-exponent spread, and the fold had nothing
   to fold". So my green on that row is genuine but **weaker evidence than the
   same word would be today**. It is exactly the "structure is not values" case
   CLAUDE.md opens with, caught by somebody else on the same day, and it is a
   good argument against reading any single row's PASS as a strong claim.

## Measured and REJECTED -- do not retry

- **`--jobs 2` for the full gate while a Vivado `place_design` is running.**
  Not retried and not recommended blind, but the reason is now measured rather
  than assumed: `--jobs 1` cost 2.13 GiB peak and about 75 minutes wall. The
  memory argument for `--jobs 1` is weak; the argument that survives is wall
  clock, and `--jobs 2` would roughly halve it at ~4 GiB. **The old note that the
  gate is a memory hazard beside Vivado does not survive measurement.**
- **Deriving `BASELINE_PASS` from `105 - 4 = 101` instead of measuring it.**
  Rejected on the record of this exact file: the `93 -> 98` entry shows the same
  arithmetic off by one, and the miss was invisible except through disagreement
  with a measurement.
- **Using the working tree for either question.** Rejected before starting: at
  08:18 the tree carried eight modified tracked files from at least three other
  tracks and a live `ghdl-mcode` mutation run writing into it.
- **`pgrep`-based process accounting for the Vivado footprint.** Followed
  CLAUDE.md and summed RSS over `unwrapped/lnx64.o/vivado` instead. Confirmed the
  over-report: `pgrep -x vivado` returned two PIDs for one tool, of which one was
  a 3.2 MB bash launcher and the other the 7.1 GiB process.

## Measurement traps hit

1. **Omitted `MV4I_FK33_FILE=/nonexistent`.** See above. Cost one full run.
   The recipe is written out inside `sim/regress.sh`; I read the `BASELINE_PASS`
   value and the summary block before I read the reproduction recipe forty lines
   below it.
2. **`regress.sh` prints its table only at the end**, so `tail`ing the log shows
   a four-line header for over an hour and looks hung. Progress is readable from
   `$REGRESS_SCRATCH/res.*`, one file per finished row, and that is the right
   thing to poll.
3. **HEAD moved between two adjacent commands.** `git rev-parse HEAD` at 08:18
   gave `8b7eefe`; the same command moments later gave `32a7b47`. Capturing the
   SHA as its own step and archiving *that* SHA is not pedantry here, it is the
   difference between a reproducible number and a nonsense one.
4. **`SKIPPED` is not a fixed number.** The baseline recipe records `SKIPPED 10`;
   my first run showed `SKIPPED 6`. Nothing regressed: 6 are static
   (`library beh`) and the other 4 are the optional FK33 rows, which skip or run
   depending on a file **outside the repository**. A count of skips is not a
   property of a commit.

## Open, not yet answered

- **The floor at HEAD.** MEASURED 101 at `32a7b47`. Not measured with
  `sim/tb_a_wbase.vhd` (`d7a6bf7`) in the plan, so the number for a settled HEAD
  is unknown. `BASELINE_PASS` is left at **99** on purpose.
- **Is `729df43` or later green?** Unknown. Only `32a7b47` was measured.
  `rtl/llama_top.vhd` and `sim/tb_attn_block.vhd` changed after it, and
  `sim/tb_a_wbase.vhd` has never been run by a full gate at all.
- **Does `sim:tb_a_wbase` pass in a full run?** BASEFAB ran it under its own
  harness and deliberately did not run a full gate, correctly, because the box
  was contended. Nobody has seen it as a gate row.
- **Do the six `*_cmp` netlist benches pass?** They have never been run by any
  gate. They need Vivado xsim and a regenerated netlist, and no track owns them.
- **What actually costs 20.9 GiB in `ghdl-mcode`?** Not the gate (2.13 GiB
  measured). Probably an unreduced-shape elaboration in somebody's mutation
  harness. Worth pinning, because the whole dispatch budget is currently
  provisioned against that number.
