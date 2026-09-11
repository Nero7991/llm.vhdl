# The build reported failure six hours ago and never stopped running

**Date:** 2026-09-11
**Build:** `cardfull` (`hw/fk33/pcieep_build.sh`, `FK33_CARD=1`), launched
2026-09-10 20:08:12, `systemd-run --user -p MemoryMax=22G`
**Part:** xcvu33p-fsvh2104-2L-e

## The question, verbatim

> Is it done?

## The answer

**No, and it had already reported failure.** At 02:10:47 the parent Vivado hit
the 360-minute `FK33_SYNTH_MAX_MIN` bound, `fk33_assert_run_done` raised, and
that process exited. **The synthesis it had launched kept running.** At 06:00 it
was 9 h 52 m old with 588 CPU-minutes accumulated and 5.0 cores busy.

Two separate findings, one of which refutes a hypothesis I acted on:

1. **`launch_runs` + `wait_on_run -timeout` leaves an orphan.** The run is a
   detached process tree. The parent's `error` stops the parent; it does not
   stop the child, and the child holds the memory.
2. **The 22 GiB cap was causing real pressure but was NOT the constraint.**
   Raising it live to 28 GiB dropped PSI `full avg60` from 0.10 to a flat 0.00
   and moved `memory.current` by **0.10 GiB in 15 minutes**. The job does not
   want more than ~22 GiB. The prediction that it would climb was wrong.

## The procedure

Each step isolates one thing.

1. `systemctl --user show cardfull.service -p ActiveState` -> `active (running)`
   with `Result=success`. **Both are true at once and neither is the answer:**
   `Result` describes the last completed job, `ActiveState` the cgroup.
2. `journalctl --user -u cardfull.service` -> the `FK33_RUNDONE FAIL` traceback
   at 02:10:47 and `Exiting Vivado`. This is what "done" looked like from the
   parent's side.
3. `/proc/PID/exe` census over the cgroup (never `pgrep -f`) -> three live
   Vivados, one at 19.4 GB RSS, `cwd` = `.../fk33_pcieep.runs/synth_1`. That
   `cwd` is what identifies it as the orphaned RUN rather than the parent.
4. **`ls -lat` on the run directory** -> newest file `20:11`, ten hours stale,
   `__synthesis_is_running__` still present. Distinguishes "no output" from
   "no progress".
5. **CPU-tick delta over 5 s**, the control for step 4: 500 ticks = 5.0 cores.
   Without this, ten hours of silence reads as a hang. It was not hung.
6. `memory.current` vs `memory.max` -> 23,620,927,488 against 23,622,320,128,
   a gap of **1.4 MB**. Pinned at the ceiling.
7. `systemctl is-active llama-cpp-server` -> **inactive**. The 18 GB that
   justified a 22 GiB cap was not there any more. The cap outlived its premise.
8. Raise the cap live, then re-measure 2, 5 and 15 minutes later. This is the
   step that falsified the hypothesis.
9. **Verify the fix is in the thing being built, not in the repo.**
   `find` for `fk33_card.vhd` under the build tree -> no copy;
   `grep add_files` -> line 256 reads the repo path directly;
   `create_bd_cell -type module -reference fk33_card` -> module reference, not
   a packaged IP. So `HOST_WINDOW => false` really is being compiled.

## The evidence

```
Sep 11 02:10:47  synth_1 timed out after 360 minutes.
Sep 11 02:10:47  wait_on_runs: elapsed = 06:00:02 . Memory (MB): free physical = 381
Sep 11 02:10:47  FK33_RUNDONE FAIL: run 'synth_1' is at 0% with STATUS 'Running synth_design...'
Sep 11 02:10:48  INFO: [Common 17-206] Exiting Vivado
```

Orphan, ~3 h 50 m after the parent exited:

```
pid=1323708 cpu=588min state=S cwd=.../fk33_pcieep.runs/synth_1  rss=19448176 kB
ticks in 5s: 500                       -> 5.0 cores busy
runme.log  180238 bytes, 2026-09-10 20:11:41    -> 10 h stale
__synthesis_is_running__  present
```

Cap raise, and the measurements that refuted it:

```
BEFORE max=23622320128 current=23621783552      (gap 1.4 MB)
AFTER  max=30064771072 current=23622569984

t=+02m  cgroup=22.00 GiB  psi_full60=0.10
t=+03m  cgroup=22.02 GiB  psi_full60=0.03
t=+15m  cgroup=22.10 GiB  psi_full60=0.00   cores busy 1.0   runme.log still 20:11
```

## Measured and REJECTED -- do not retry

- **"The memory cap is what is holding the card build back."** REJECTED.
  Removing 6 GiB of cap bought 0.10 GiB of growth and zero forward progress.
  PSI fell to 0.00, so the cap was doing *something*, but it was not the wall.
  Do not raise the cap again expecting progress.
- **"No log output for ten hours means it is hung."** REJECTED by the CPU-tick
  control: 5.0 cores busy. A silent Vivado elaboration is silent by design.
- **"`Result=success` means the unit finished successfully."** REJECTED. It
  coexisted with `ActiveState=active` and a six-hour-old failure traceback.
- **Counting Vivado processes.** Three matched here for one logical tool, the
  recorded over-report. Gate on presence via `/proc/PID/exe`, sum `VmRSS`.

## Measurement traps hit

- **A capped job's `memory.peak` is the cap.** `memory.peak` read exactly
  `memory.max` to the byte. It measured the throttle, not the appetite. The
  only honest reading was `memory.current` sitting 1.4 MB below the ceiling.
- **The harness reported a fact about the harness, for the fourth recorded
  time.** `wait_on_run -timeout` returning rc 0 on expiry; a waiter firing on a
  killed unit; a block-buffered log showing 0 rows; and now a parent's error
  exit that says nothing about whether the work stopped. **A build script's
  failure is not evidence that the build stopped.**
- **I set a cap from a snapshot of the box and never revisited it.** 22 GiB was
  correct while `llama-server` held 18 GB. It stopped being correct the moment
  that service went down, and nothing was watching for that. A cap derived from
  another process's footprint needs re-deriving when that process changes.
- **My own teeth test for the unrelated autosave fix supplied `PWD` itself**
  and so could not see that `pcieep_build.sh` `cd`s into the doomed directory
  and never returns. Fixture built from my notion of the environment rather
  than from the script. See `f0bed60`.

## Open, not yet answered

- **Why does the card still not clear elaboration with `HOST_WINDOW => false`?**
  The fix is confirmed compiled. It was necessary and is not sufficient.
- **What phase is the orphan actually in?** Ten hours, no phase boundary
  written, now single-threaded at 1.0 core. Unknown.
- **Whether it will ever finish.** Eleven prior attempts did not.
- Per-subsystem synthesis remains the measured, working alternative:
  `gdn_block` 221.4 MHz and `attn_block` 239.5 MHz, 3-4 minutes each.
