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
