# A monolithic OOC synthesis of B+C+D does not finish, and is probably the wrong tool

Date: 2026-09-08. Part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, workstation.
Job: `synth_design -mode out_of_context -top fk33_card`.

## The question

The three-cell block design builds as of 2026-09-07 but nothing is synthesised,
so area, fit and timing for the card are unknown. Does `fk33_card` (subsystems
B, C and D together, at the shipping card configuration) synthesise, and what
does it cost?

## The answer

**Unknown, and 6 h 34 m of one Vivado did not settle it.** The run was stopped
deliberately, not by a failure: no error, no OOM, no cgroup throttling. It
simply had not finished, had emitted no phase marker in over six hours, and had
begun to move the machine into swap.

**MEASURED, and this figure IS quotable**: `memory.peak = 15.52 GB` under a
16 GB `MemoryHigh` cap with `memory.events high 0`. The cap was never reached,
so this is a real unthrottled peak rather than the cap reading itself.

**The likely mistake is the tool, not the design.** The bitstream path is
`hw/fk33/pcieep_build.sh`, where Vivado synthesises the block design
hierarchically -- per module reference, in parallel, with its own run
management. This job asked for ONE flat OOC synthesis of the largest cell in
the project. That is not what the build does and there is no result that
requires it.

## The procedure

1. Launch under `systemd-run --user -p MemoryHigh=16G` so the job cannot take
   the machine, with the working directory in the scratchpad.
2. Deliberately do NOT set `dissolveMemorySizeLimit`, to test whether real
   synthesis is cheaper than the elaboration that preceded it.
3. Sample `/proc/PID/exe`-identified Vivado RSS, elapsed time, system swap and
   the cgroup's `memory.events` on a ~2 minute cadence throughout.
4. Stop on the project's documented leading indicator (swap moving), not on
   free RAM and not on a fixed clock.

## The evidence

Memory trajectory, sampled from `/proc/PID/status` (abridged):

```
t=  173s   3.92 GB     t= 8880s  12.00 GB
t=  508s   5.30 GB     t=11784s  13.02 GB
t= 2019s   8.03 GB     t=13877s  13.98 GB
t= 4234s   9.36 GB     t=16088s  15.08 GB
t= 6090s  11.00 GB     t=20003s  15.58 GB
t= 7368s  11.54 GB     t=23659s  15.80 GB   <- stopped
```

Growth is monotone and decelerating, with two genuine dips (t=17249s and
t=23659s) that were phase transitions and not reclaim -- `memory.events high`
stayed 0 throughout, so nothing was ever throttled.

The hypothesis under test WAS confirmed on its own terms. Real synthesis is far
better behaved than the `synth_design -rtl` attempt that preceded it:

| run | dissolve limit | wall | peak | finished |
|---|---|---|---|---|
| `synth_design -rtl` | 200000 | 3 h 30 m | ~14.5 GB | no |
| `synth_design` (this) | unset | 6 h 34 m | 15.52 GB | no |

The `-rtl` run expands inferred memories to individual bits (B's `zb_reg` alone
is 196,608 of them) and reached 14.5 GB in a *quarter* of the elapsed time. Real
synthesis infers BRAM instead and used less memory per unit of work. **Neither
finished, so the comparison says which is cheaper per hour and NOT that either
is viable.**

Stop condition, sampled three times 8 s apart before acting:

```
swap=5532 MB  avail=5857 MB
swap=5532 MB  avail=5865 MB
swap=5532 MB  avail=5857 MB      <- flat, so not yet a runaway
... 2 min later ...
swap=5663 MB                      <- moving, RSS pinned at 15.8-15.9 GB
```

After the stop: 0 Vivado processes, 21.7 GB available, swap back to 4.4 GB.

## Measured and REJECTED -- do not retry

- **A monolithic `synth_design -mode out_of_context -top fk33_card` on this
  workstation.** Twice now, counting the `-rtl` attempt, ~10 hours of one
  Vivado between them, no result either time. Do not launch a third without a
  reason to expect a different outcome.
- **Reading the log for progress.** Vivado hit its own `Common 17-14` message
  cap at ~5 minutes and the file stayed at **469 lines for over six hours**.
  The only live progress signals were RSS and CPU time.
- **Stopping on a clock.** A 3-hour boundary was set and then extended twice on
  evidence (swap flat, `high 0`, memory decelerating). That was right: the
  numbers, not the clock, are what said it was safe to continue and later what
  said it was not.

## Measurement traps hit

**`free -g` rounding made a 1 GB swap "jump" that was really 0.5 GB of drift.**
The reading went 4 -> 5 GB and read as a step change worth acting on. `free -m`
showed 5,532 MB, i.e. it had been drifting up from ~4.5 GB for some time. Three
samples 8 s apart then showed it FLAT, which is what justified continuing for
another half hour. **Sample a trend before acting on a single reading, and read
it at a resolution finer than the change you are looking for.**

**A per-process `VmRSS` and the cgroup's `memory.peak` disagree, and the cgroup
is the one to quote.** The last RSS sample was 15.90 GB; `memory.peak` is
15.52 GB. They count shared pages differently. The cgroup figure is the one
paired with `memory.events`, so it is the one that can be stated as an
unthrottled peak.

## Open, not yet answered

- **Area, fit and timing for the card remain completely unmeasured.** Nothing in
  this run produced a number about the design.
- **Whether a full `pcieep_build.sh` with `FK33_CARD=1` completes.** That is the
  path that matters and it has never been run. It synthesises hierarchically,
  which is a different and probably much cheaper job than the one attempted
  here. It is also the only route that yields a bitstream.
- **Whether the BC-250 second lane could carry it.** It has 15.2 GB total
  against this job's 15.52 GB peak, so a monolithic OOC does NOT fit there. A
  hierarchical build might; the recorded pcieep peaks on that box are 11.85 GB.
