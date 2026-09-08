# The card build gets OOM-killed, and both obvious fixes were wrong

Date: 2026-09-08. Workstation, 31 GB, Vivado 2023.2.
Job: `FK33_CARD=1 bash hw/fk33/pcieep_build.sh` (full build to bitstream).

## The question

A monolithic OOC synthesis of `fk33_card` had just been abandoned after 6 h 34 m
(see `2026-09-08_card-ooc-synthesis-does-not-finish.md`), on the reasoning that
the real build synthesises HIERARCHICALLY and is therefore a different and much
cheaper job. Does the full build with the card in it run?

## The answer

**No, not yet, and neither of the two obvious fixes was right.** Three
launches, three stops, no bitstream. What was learned is all about the
remedies, and one of them was actively dangerous.

1. **`MemoryHigh` throttles; it does NOT stop systemd-oomd.**
2. **`-jobs N` bounds concurrent RUNS, not processes.** `-jobs 2` produced
   **eleven** Vivado processes and 22.04 GB.
3. **`ManagedOOMPreference=avoid` is worse than nothing here**, because it
   redirects the kill onto a bystander.

## The procedure

Each launch was run under `systemd-run --user` with a cap, in the background,
sampling summed Vivado RSS via `/proc/PID/exe` (never argv), system
`MemAvailable`, swap, and the cgroup's `memory.events`.

## The evidence

### Launch 1 -- `MemoryHigh=18G`, `-jobs 4` (the engine-only default)

Cleared the block design (`FK33_CARD SAXI_30 ENABLED`), reached
`launch_runs synth_1 -jobs 4`, and 2.5 minutes later:

```
Sep 08 01:54:22  cardbuild.service: systemd-oomd killed 134 process(es) in this unit.
Sep 08 01:54:22  cardbuild.service: Main process exited, code=killed, status=9/KILL
                 Consumed 20min 40.083s CPU time.
```

**The cgroup never recorded a single `memory.events high`.** The limit was
never reached; the kill came from PRESSURE. `MemoryHigh` makes a cgroup reclaim
rather than fail, and systemd-oomd watches memory PSI across the cgroup and
kills on stall. They are unrelated mechanisms. This is the same distinction
CLAUDE.md already records for `OOMPolicy=continue` (which governs the KERNEL
OOM-killer reaping a child, not oomd killing the whole cgroup), in a new place.

### Launch 2 -- `MemoryHigh=18G`, `ManagedOOMPreference=avoid`, `-jobs 1`... but the generated Tcl said 2

90 s in: 1 process, 2.48 GB. Two minutes in:

```
vivado=11 total=22.04 GB
Mem: used=27504 avail=3847
Swap: used=5528
```

**Eleven processes from `-jobs 2`.** This file already records that "a single
Vivado shows five matches on `bin/unwrapped/lnx64.o/vivado`, because Vivado
forks parallel-synthesis workers that inherit the parent's argv". So the count
is about `jobs x 5 + 1` and halving `-jobs` does not halve anything like
proportionally.

Stopped by hand at 3.8 GB available. Afterwards: 0 Vivado, 22.1 GB available,
`code-server` still `active`.

## Measured and REJECTED -- do not retry

- **`-jobs 4` for a card build.** OOM-killed in 2.5 minutes.
- **`-jobs 2` for a card build.** 22.04 GB, 3.8 GB left, stopped before it
  fired. The default is now **1** when `FK33_CARD` is on
  (`FK33_SYNTH_JOBS` overrides).
- **`ManagedOOMPreference=avoid` on this build. DO NOT DO THIS.** It was added
  on the theory that the first kill was oomd's fault. It reduces no memory
  whatever; it tells systemd-oomd to spare THIS cgroup, so under pressure oomd
  kills a bystander instead. On this machine the bystander is `code-server`,
  which is precisely what the 2026-07-04 incident destroyed -- 275 processes,
  every claude session in that cgroup, because they lived there. **oomd killing
  the offending build is the safety valve, not the bug.** I removed the
  protection that had been working and only luck (a hand-stop two minutes
  later) kept it from being paid for. `MemoryMax` is the correct tool if a hard
  ceiling is wanted: the kernel then kills THIS cgroup and nothing else.
- **Reasoning about the remedy from the symptom.** The first kill said
  `systemd-oomd`, so the fix "obviously" was to exempt the unit from oomd. That
  is treating the alarm as the fault. The actual fault was the footprint.

## Measurement traps hit

**`ls -t */*.runs/synth_1/*.log` tailed a log from 24 August.** The glob
matched the OLD `fk33_i2cprobe` project directory, which is still on disk
beside the `fk33_pcieep` one this build creates, so a perfectly ordinary tail
returned `Exiting Vivado at Mon Aug 24 15:53:21 2026` and read as this build
finishing. Same shape as the recorded scratch-directory trap: **when a result
looks wrong or suspiciously complete, check the date on what you actually
read.** The journal, which cannot be stale, is the authority.

**A stale number in the one comment whose job is to state memory cost.** The
block above `launch_runs` said "`-jobs 8` on SYNTHESIS launches up to 8
concurrent out-of-context IP runs" while the code had already been changed to
4. The count is a variable now so the two cannot drift again.

## Open, not yet answered

- **No card build has completed, and none has reached synthesis proper.** Both
  kills happened within minutes of `launch_runs`, so nothing is known about how
  long a card synthesis takes or whether it fits.
- **Whether `-jobs 1` is enough.** Untested. One run still forks ~5 workers; the
  engine-only build peaked at 10.66 GB and the card is materially larger.
- **The BC-250 second lane.** Its recorded pcieep peak is 11.85 GB of 15.2 GB
  total, with a standing instruction to stay at or below `MemoryHigh=11G` there.
  A card build is bigger than an engine-only one, so it may not fit at all.
