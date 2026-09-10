# The units synthesise in minutes; only their union does not

**Date:** 2026-09-10. Part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, workstation.

## The question

Seven attempts and ~35 hours of Vivado failed to synthesise the card in one
piece (`docs/debugging/2026-09-10_the-card-does-not-synthesise-in-one-piece.md`).
Is the per-subsystem route -- the one untried structural approach -- viable?

## The answer

**Yes, decisively, for subsystem B.** `gdn_block` synthesised to completion in
**3 minutes wall, 115 seconds of `synth_design`**, 0 errors, with the runner's
own sentinel `COMPOSE_DONE gdn_block` recorded as the last action:

```
COMPOSE_RESULT target=gdn_block dsp=253 lut=75246 lut_logic=65057
  lut_mem=10189 ff=52203 ramb36=36 ramb18=14 bram=43 uram=0
  carry8=2897 f7=3953 f8=831 wns=0.483 fmax=221.3858755811379
  synth_s=115 opt_s=27
```

**It also MEETS 200 MHz**, at `wns=0.483` / 221.4 MHz.

## The contrast, which is the whole point

| job | wall | reached | finished |
|---|---|---|---|
| card, 7 attempts | 3 h 30 m .. 12 h 24 m | RTL elaboration | **no** |
| **`gdn_block` alone** | **3 min** | **all phases** | **yes** |

The card never emitted a phase marker past `Starting RTL Elaboration` in twelve
hours. `gdn_block` moved through `RTL Component Statistics`, `Part Resource
Summary` and `Cross Boundary and Area Optimization` inside the first minute.

**So the difficulty is not the RTL, the part, the tool version, the machine, or
the memory. It is specifically the size of the flat elaboration/optimisation
problem when B, C and D are presented as one unit.** That is a strong claim and
it is now supported by a positive control rather than only by seven negatives.

## Procedure

`sim/ooc_compose_run.sh <target> <outdir> <rtldir>`, one target per Vivado
invocation, under `systemd-run -p MemoryMax=16G`. The runner already refuses
unless `COMPOSE_DONE <target>` is the recorded LAST action, which is the right
gate -- a Vivado run can print full success and then die on a Tcl error.

**Progress was read from PHASE MARKERS, not RSS.** That is the correction this
project earned the hard way the same day: RSS growth and CPU accumulation are
liveness signals and are present in runs that never finish, so they cannot
distinguish progress from a stall. `Start`/`Finished` pairs can.

## Measurement traps hit

**The watcher exited 1 on a successful run**, twice over: `memory.peak` was read
after the unit had already gone, so the cgroup directory no longer existed
(`No such file or directory`, and `peak=GB` with an empty number), and the
trailing `grep -c` returned 1 for zero errors. **The exit code is the harness's,
not the job's** -- the load-bearing evidence is the `COMPOSE_DONE` sentinel.
Sample a cgroup's `memory.peak` while the unit is still alive, or accept that it
is gone.

## Open

- C (`attn_block`) and D are not yet measured; B alone does not establish the
  approach for the others, only that the approach is not dead.
- Even with all three synthesising, **linking three DCPs into the block design
  is a flow that does not exist yet** and is the real work. Per-unit success is
  necessary, not sufficient.
- The union may still be intractable at `link_design`/`opt_design` rather than
  at synthesis. Nothing here speaks to that.

---

## THE APPROACH DOES NOT RESCUE THE CARD (same day, later)

**Black-boxing B and C is NOT sufficient.** The card top with both stubbed hit a
120-minute ceiling with no sentinel, no `.dcp`, and 0 errors -- still grinding.

| job | wall | reached | finished |
|---|---|---|---|
| `gdn_block` (B) alone | 3 min | all phases | **yes**, 221.4 MHz |
| `attn_block` (C) alone | 4 min | all phases | **yes**, 239.5 MHz |
| card, B+C black-boxed | **>121 min** | optimisation | no |
| card, whole | >12 h | RTL elaboration | no |

So removing B and C **moves the wall from elaboration into optimisation rather
than removing it**. B and C are not what makes the card intractable. The one
untried structural approach is now tried, and it does not work as framed.

Note the stall here is NOT explained by the message cap, unlike every earlier
run: `[Common 17-14]` appears **0** times in this log, and nothing was written
to the run directory for the last 30 minutes while RSS climbed 6.04 -> 10.02 GB
on 1.23 h of CPU.

## Two traps hit, one of which nearly produced a false root cause

**I ran the first black-box test against the WRONG TOP.** The compose harness's
target is `llama_top`; the card builds `fk33_llama_top`. Those are different
files: `tools/gen_cardtop.py`'s D3 transform replaces `llama_top`'s flat
`NREGION*REGMAX` array with a `region_mem` instance, so the card top has **0**
occurrences of that array and `llama_top` has **1**.

Against `llama_top` the run failed in 6 minutes with what looked exactly like
the answer:

```
ERROR: [Synth 8-3391] Unable to infer a block/distributed RAM for 'mem_reg'
because the memory pattern used is not supported.  Failed to dissolve the
memory into bits because the number of bits (2752512) is too large.
```

**That error is real for `llama_top` and IRRELEVANT to the card**, and it would
have been written up as the root cause of a 35-hour wall. The check that caught
it was asking which top the harness actually targets before believing the
result. Same shape as the recorded stale-table failure: an artifact whose name
looked right, never asserted to be the one that ships.

`REGMAX=12288` in `gen_fk33_card.py` is also correct -- `REGMAX := region_max(SHAPE)`
for the 9B shape -- and pre-dates this session by at least six commits, so the
seam `REGMAX` change made earlier today is not implicated either.

**VHDL DOES NOT INFER BLACK BOXES.** Removing a unit's source gives
`ERROR: [Synth 8-5826] no such design unit 'gdn_block' in library 'work'`,
because `entity work.gdn_block` is a DIRECT BINDING. Inferring a black box from
a missing module is Verilog behaviour. A stub entity is required, carrying the
port list verbatim plus an architecture with
`attribute black_box of <arch> : architecture is "yes"`. Worth knowing before
designing any DCP flow around VHDL sources.

## Open, and now narrower

The suspect is the card top itself -- D, the glue, the A-seam adapters, and
`region_mem`. **`region_mem` could not be probed**: it has an unconstrained
array generic `SZ` (the per-region size table) and an array aggregate cannot be
passed as `-generic`, so it needs a sizing wrapper. That wrapper is the cheapest
next measurement, at minutes rather than the two hours every card-level test
costs.
