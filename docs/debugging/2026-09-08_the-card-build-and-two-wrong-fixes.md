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

### Launch 3 -- `MemoryMax=20G`, NO oomd exemption, `-jobs 1`

The corrected recipe, and it made almost no difference:

```
 90 s:  vivado=1   total= 2.53 GB   avail=19957 MB
~4 min: vivado=10  total=23.91 GB   avail= 2512 MB   swap=5873 MB
```

**TEN Vivado processes from `-jobs 1`.** Stopped by hand. Afterwards: 0 Vivado,
22.9 GB available, `code-server` still `active`.

So `-jobs` does not bound this build's footprint at ALL, not merely
disproportionately. Going 4 -> 2 -> 1 gave 134 processes (killed), 11, and 10.
The per-IP out-of-context runs that a block design generates are not what
`-jobs` is throttling here, or they are launched faster than it serialises them.

**`MemoryMax=20G` did not stop it either**, and the reason matters: summed RSS
across processes is NOT the cgroup's charge -- shared pages are counted once by
the cgroup and once per process by the sum. 23.91 GB of summed RSS can sit under
a 20 GB cgroup charge. **The summing idiom this project uses to size a job
OVER-COUNTS a multi-process job, so it is a safety signal and not a cgroup
figure.** Use it to decide when to stop; do not expect a `MemoryMax` set from
it to fire.

### Launches 4-7 -- global synthesis, VHDL 2008, and the knob that actually worked

Four more launches, each fixing exactly what the previous one revealed:

| # | change | result |
|---|---|---|
| 4 | `synth_checkpoint_mode None` | 1 process, peak 3.96 GB, **real synthesis error in 2m50s** |
| 5 | all 50 card sources set VHDL 2008 | `[filemgmt 56-195]` the BD cell top may NOT be 2008 |
| 6 | 48 sources 2008, the two wrapper tops left at 93 | past the BD, but **10 processes / 21.16 GB** |
| 7 | `set_param general.maxThreads 2` | **4 processes / 14.21 GB**, synthesis running |

**Launch 4 is the turning point** and vindicates global mode: one bounded
process that FAILED ON A DIAGNOSABLE ERROR beats ten unbounded ones that take
the machine. The errors it exposed are below.

**THE CARD SOURCES WERE BEING PARSED AS VHDL-93, and no bench can see it.**
`rtl/a_desc_adapter.vhd` reads its own `out` ports (`m_awvalid`:269,
`m_wvalid`:270, `u_done`/`u_ready` in asserts at :318 and :321). That is legal
in 2008 and illegal in 93, and `CARD_RTL_ADD` had copied the engine's plain
`add_files`, which leaves a file at Vivado's default of 93. GHDL runs
`--std=08` throughout, so every one of these files simulates cleanly; the
defect existed only in the synthesis flow.

**AND THE TWO WRAPPER TOPS MUST NOT BE 2008.** Setting all 50 produced
`[filemgmt 56-195] Reference 'fk33_card' contains top file ... of type VHDL
2008. This type is not allowed as the top file in the reference`. The
requirements are OPPOSITE, and each is invisible until the other is fixed --
the same shape as the recorded `IP_Flow 19-734` / `19-627` pair. Resolution: 48
sources at 2008, the two generated wrappers at 93, which costs nothing because
`gen_fk33_card.py` emits them with every width folded to a literal precisely so
they carry no 2008 construct.

**CORRECTION TO THIS DOCUMENT'S OWN CONCLUSION: `-jobs` was never the wrong
knob, it was the wrong LAYER.** After global mode was on, the runs directory
listing showed exactly ONE run and there were still ten processes. They are the
parallel workers Vivado forks INSIDE a run, which `-jobs` has never governed;
`general.maxThreads` does. Setting it to 2 took the count 10 -> 4 and the
footprint 21.16 -> 14.21 GB. The earlier claim that "`-jobs` does not bound this
build at all" is withdrawn: it bounds RUNS, and once global mode left only one
run there was nothing for it to bound. **Both knobs are needed and they act on
different things.**

### What launch 7 measured

With global synthesis, `-jobs 1` and `maxThreads 2`, under `MemoryMax=17G`:

```
cgroup memory.current  15.00 -> 15.38 -> 15.81 -> 16.27 -> 16.66 -> 17.00 GB
memory.events          max 0 ... max 21 ... max 97 ... max 111   (oom_kill 0)
MemAvailable           9663 -> 8461 -> 7691 -> 6353 -> 5495 -> 5361 MB
swap                   4678 -> 4796 MB
```

It reached the ceiling and the kernel RECLAIMED rather than killed -- `oom 0,
oom_kill 0` throughout, 111 `max` events -- while synthesis continued into the
GT wizard IP. Stopped by hand at sustained reclaim with 5.3 GB free and swap
beginning to creep. Afterwards: 0 Vivado, 22.8 GB available, `code-server`
still `active`.

**`MemoryMax` throttles before it kills.** That is a third distinct behaviour
from `MemoryHigh` (reclaim, no kill, invisible to oomd) and systemd-oomd (kills
on PSI). Worth knowing: a `MemoryMax` job that is "at the limit" is not
necessarily about to die.

**The peak is NOT measurable from this run.** `memory.peak` reads 17.00 GB,
which is the cap. All that is established is that the card build's synthesis
wants MORE than 17 GiB.

## The conclusion

**The card build now runs bounded and reaches real synthesis, and it wants more
than 17 GiB.** That is the state after seven launches. The method changes that
got it there -- global synthesis, VHDL 2008 below the wrapper tops, and
`general.maxThreads` -- are all committed and gated on `FK33_CARD`.

What remains is a memory budget question, not a Vivado one. On a 31 GB box
carrying ~9 GB of other usage, a job that wants >17 GiB has no comfortable
room, and every attempt to give it more pushes `MemAvailable` into the range
where systemd-oomd starts hitting bystanders.

## Open, not yet answered

- **No card build has completed, and none has reached synthesis proper.** Both
  kills happened within minutes of `launch_runs`, so nothing is known about how
  long a card synthesis takes or whether it fits.
- **Whether `-jobs 1` is enough.** Untested. One run still forks ~5 workers; the
  engine-only build peaked at 10.66 GB and the card is materially larger.
- **The BC-250 second lane.** Its recorded pcieep peak is 11.85 GB of 15.2 GB
  total, with a standing instruction to stay at or below `MemoryHigh=11G` there.
  A card build is bigger than an engine-only one, so it may not fit at all.
- **GLOBAL synthesis instead of per-IP OOC.** UNTESTED and the most promising
  lever: `set_property synth_checkpoint_mode None [get_files bd.bd]` makes the
  block design synthesise inside the top run instead of generating a separate
  OOC run per IP. That is ONE process whose footprint can actually be capped,
  against ten that cannot. It trades incremental rebuilds for a bounded peak,
  which is the right trade when the current peak is unbounded. The risk is that
  one process then has to hold the whole design: the card cell ALONE peaked at
  15.52 GB as a monolithic OOC, so global synthesis of the whole top could
  exceed what this box has, and that would be a real answer rather than a hang.
- **More RAM.** The workstation has 2 free DIMM slots and a 128 GB maximum;
  filling all four usually forces a speed drop below 6000 MT/s, so 2 x 32 GB
  replacing the current pair is the documented preference. This is the only
  option here that certainly works, and it is Oren's call.
- **Whether the card configuration should be trimmed for a FIRST bitstream.**
  Nothing says the first working card has to be the full 9B geometry. A smaller
  `C_KV_BLOCK`, fewer `A_ROWS_IF`, or B omitted would produce a bitstream that
  proves the three-cell wiring on real hardware, which is worth more than a
  full-size build that cannot be synthesised.
