# The "elaboration wall" is not in elaboration, and the design is not hung

**Date:** 2026-09-11
**Build:** `fk33_card` OOC at the shipping configuration (`C_REAL=true`,
`NORM_REAL=true`, `C_N_ROT=64`, `C_KV_BLOCK=32`, `C_KV_AXI=true`), Vivado
2023.2 on the workstation, unit `cardooc`, `flatten_hierarchy=none`.

## The question, verbatim

Why do card builds freeze with only two phase lines in the log, and is the
design unsynthesisable at the card boundary?

## The answer, up front

**RTL elaboration COMPLETES. The design is not stuck in elaboration, and it is
not hung at all.** The log's last three lines are `done synthesizing module`
for `attn_block`, then `fk33_llama_top`, then `fk33_card` itself, which is the
top. After that Vivado enters a **silent single-threaded phase that emits no
log output** and burns **101% of one core**. Measured 36 minutes into that
phase with the log byte-frozen the entire time.

So the standing project claim that card builds "stall in `synth_design` RTL
Elaboration" is **WITHDRAWN**. The stall is AFTER the last module is
elaborated and BEFORE the next phase line is printed. What has never been
established is whether that phase terminates, and every prior run was stopped
or abandoned before it could.

## The procedure

Each step isolates one thing. The order matters, because steps 1 and 2 both
look like "it is stuck" and only step 3 separates them.

1. **Read the LAST module named in the log, not the module count.** A count
   invites comparison against other runs and says nothing about depth. The
   name says whether the top was reached.
2. **Test whether the log is still growing**, with a real interval, not by
   eye. `stat -c%s` twice, 60 s apart.
3. **Measure CPU consumption over a wall-clock interval.** This is the step
   that distinguishes a deadlock from a long computation, and nothing else
   does. `awk '{print $14+$15}' /proc/PID/stat` twice, 30 s apart; the delta
   in ticks divided by the interval is percent of one core.
4. **Read `wchan`** as the cross-check on step 3. The process leader shows
   `futex_wait_queue` because it is the worker thread doing the work, so
   `wchan` ALONE would have read as "blocked" and is misleading here.
5. Resolve the pid by `/proc/PID/exe` and `/proc/PID/cwd`, never by matching a
   command line.

## The evidence

Log frozen for 36 minutes, top module elaborated:

```
now: 2026-09-11 19:33:09
today cardooc.stdout: 70798 bytes  mtime=2026-09-11 18:57:25
after 60s:            70798 bytes  mtime=2026-09-11 18:57:25

INFO: [Synth 8-256] done synthesizing module 'attn_block' (0#1)      [rtl/attn_block.vhd:393]
INFO: [Synth 8-256] done synthesizing module 'fk33_llama_top' (0#1)  [rtl/fk33_llama_top.vhd:1027]
INFO: [Synth 8-256] done synthesizing module 'fk33_card' (0#1)       [hw/fk33/rtl/fk33_card.vhd:172]
```

Computing, not blocked:

```
utime+stime ticks: before=[223492 1769] after=[226491 1793]
CPU consumed in 30s: 100.8 ticks/s = 101% of one core
wchan: futex_wait_queue        (process leader; a worker thread holds the CPU)
RSS 9526 MB, cgroup current 9996 MiB, threads 5
```

Depth reached, three runs, same two phase lines in all of them:

| run | date | modules elaborated | log bytes | outcome |
|---|---|---|---|---|
| `cardbb`  | 09-10 | 37 | 24,840 | stopped at 121 min, no DCP |
| `cardooc` | 09-09 | 60 | 61,513 | abandoned |
| `cardooc` | 09-11 | **90, top reached** | 70,798 | running |

## Measured and REJECTED -- do not retry

- **"The card top cannot be elaborated."** REFUTED. `fk33_card` is elaborated
  to completion, by name, in this run's own log.
- **"The build is hung / deadlocked."** REFUTED by the CPU measurement at
  101% of one core. Do not kill a card build on the strength of a frozen log
  again.
- **`wchan` as the liveness test.** It reads `futex_wait_queue` on a process
  that is demonstrably computing, because the leader waits while a worker
  runs. It gives the WRONG answer here on its own.
- **Log size or phase-line count as a progress signal.** Both are flat for the
  entire phase. They cannot distinguish 1 minute of work from 4 hours of it.

## Measurement traps hit

- **I read "90 modules elaborated, and it has entered `attn_block` and
  `gdn_block`" as healthy progress, and reported it as such.** It was not
  progress into those modules, it was completion of them. The count was rising
  toward an end I had not checked for. **A count going up is not evidence of
  the thing continuing; read the last NAME.**
- **I then claimed my own monitor's stop rule was "the single biggest threat"
  to the run.** It is not: the rule only `exit 0`s the observer and never
  touches the job. Reading the script back cost ten seconds and I asserted
  first.
- `awk '{print $3}' /proc/PID/status` prints the third field of every line of
  the whole file, not the process state. The output is a wall of `kB` and is
  easy to skim past as though it said something.

## Open, not yet answered

- **Does this phase terminate?** Unknown. No card build has ever been allowed
  to run it to completion. This is the whole question now.
- **What phase is it?** It is after the last `done synthesizing module` and
  before `Finished Synthesize`. Not identified.
- Whether the block-design composition matters at all. The premise of the
  `cardooc` experiment was that it might, and that premise is untested while
  the OOC run itself is still in this phase.
- `cincard` (A and B stubbed) reached Technology Mapping in 2h35m at 19.19 GB.
  That is the only card-shaped run known to have passed this point, and it was
  much smaller, so it bounds nothing about the full card.
