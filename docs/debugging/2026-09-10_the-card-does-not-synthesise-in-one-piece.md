# The card does not synthesise in one piece, and it is TIME, not memory

**Date:** 2026-09-10. Part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, workstation.

## The question

After fixing the KV geometry, does the card build complete, and what is the
binding constraint?

## The answer

**No, and the binding constraint is WALL TIME, not memory.** `cardbuild12` ran
**12 h 24 m** with a single synthesis worker, peaked at **22.97 GB against a
24 GB cap it never reached** (`memory.events max 0`), with **PSI 0.00 in every
window throughout** -- and never emitted a phase marker past
`Starting RTL Elaboration` at t=4 s.

Seven attempts across two sessions, roughly 35 hours of Vivado, no synthesis
completion under any configuration:

| run | wall | peak | reached | finished |
|---|---|---|---|---|
| OOC `-rtl`, dissolve 200k | 3 h 30 m | ~14.5 GB | - | no |
| OOC default (`rebuilt`) | 6 h 34 m | 15.52 GB | - | no |
| OOC `flatten none` | 7 h 03 m | 17.40 GB | synth | no |
| cardbuild9 full, stand-in | 155 m | 24.00 GB | elab | no (memory) |
| cardbuild10 full, stand-in | 194 m | 24.00 GB | elab | no (memory) |
| cardbuild11 full, real 9B | 197 m | 23.73 GB | elab | no (memory) |
| **cardbuild12 full, 1 worker** | **744 m** | **22.97 GB** | **elab** | **no (TIME)** |

## WITHDRAWN: "the full build is memory-bound, not time-bound"

Stated earlier this session, as the justification for choosing `maxThreads 1`.
**It was unsupported and is now refuted.**

The reasoning was: the OOC stalled on time, whereas cardbuild11 "was making
progress at 23.73 GB and I stopped it on available memory". But cardbuild11 was
never shown to be making *phase* progress -- only *memory* progress. Runs 9, 10
and 11 were all stopped at 155-197 minutes on a memory rule, which is **before
the point where a time stall could have become visible**. Given room to run,
cardbuild12 revealed the same wall at hour 12.

**RSS growth cannot distinguish progress from a stall, because the runs that
never finish also grow RSS.** The recorded advice from the OOC investigation --
"the only live progress signals were RSS and CPU time" -- is true about
*liveness* and false about *progress*. Both stalled runs showed continuous
CPU and rising RSS for their entire lives. The only signal that separates them
is a **phase marker** or a **file written into the run directory**, and this run
produced neither: nothing was written under `synth_1` in the two hours before
it was stopped.

## Consequence: ADDING RAM WOULD NOT HAVE FIXED THIS

RAM was offered to the user twice as the "definitive" fix, on the belief that
memory was binding. **That advice was wrong.** cardbuild12 never reached its
cap and never stalled the box; more RAM would have bought a higher ceiling for
a job that was not pressing against the ceiling. Do not buy DIMMs to solve
this particular failure.

## Measurement traps hit

**A static Vivado log is NOT proof of a stall here.** Vivado's own message cap
fired -- `[Common 17-14] Message 'Synth 8-6014' appears 100 times and further
instances will be disabled`, likewise `Synth 8-3848` -- so repeated warnings
stop printing. The log freezing is therefore expected and says nothing on its
own. What does carry information is that **phase markers are not capped** and
none appeared, and that **no file was written into the run directory**.

**My swap-based stop rule tripped on a healthy run and I nearly acted on it.**
It fired at swap +518 MB while PSI was 0.00, growth had fallen from 48 MB/min
to 10 MB/min, and `memory.current` was FALLING. Swap drift on a
`vm.swappiness=60` box is the kernel working. Correctly overridden in favour of
a PSI-based rule -- but note the outcome: the run was healthy, and it still
never finished. **A good stop rule keeps the box alive; it does not make a job
viable.**

## Measured and REJECTED -- do not retry

- **Any single-piece synthesis of the card**, OOC or in the full build, at any
  of: `-rtl` + dissolve limit, default `rebuilt`, `flatten_hierarchy none`,
  `maxThreads` 2, `maxThreads` 1. Seven runs, ~35 hours, zero completions.
- **`maxThreads 1` as a fix.** It DID work as a memory lever -- peak fell from
  23.73 to 22.97 GB and the run never hit its cap -- and that bought nothing,
  because memory was not what was stopping it.
- **Buying RAM for this failure.** See above.

## Open, and the only untried structural approach

**Per-subsystem checkpoints.** The card is B + C + D. `gdn_block` and
`attn_block` are units this project synthesises out of context ROUTINELY via
`sim/ooc_compose_bcd.tcl` -- they are known to complete. Synthesising each to
its own DCP and linking them is a fundamentally different job from one flat
synthesis of their union, and it is the only approach not yet tried. It is also
the natural repair of the DCP split, whose run 1 failed only because it was
still a monolith.

The alternative is to make the design smaller, which is now a
*synthesis-tractability* argument rather than an area or memory one.
