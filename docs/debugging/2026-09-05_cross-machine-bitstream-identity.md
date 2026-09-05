# The BC-250 builds a byte-identical pcieep bitstream, and CLAUDE.md says it cannot

**2026-09-05.** Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`, `FK33_IMPL_STRATEGY=Performance_ExplorePostRoutePhysOpt`.

## The question

> The card bitstream meets 200 MHz by 909 fs. Is that reproducible, or did we
> get lucky once?

## The answer

**Two answers, and they are different questions that were being asked as one.**

1. **Run to run, on one machine: exactly reproducible.** Re-running the same
   strategy on the same synthesis gave `WNS=0.000909 TNS=0.000000
   WHS=0.009101` -- identical to six decimal places on every figure.
   **Vivado 2023.2 has no `-seed` on `place_design`, `phys_opt_design` or
   `route_design`** (MEASURED via `help -syntax`), so there is no run-to-run
   variance to sweep in the first place. The literal request was unanswerable
   because the mechanism does not exist.
2. **Machine to machine, whole flow including synthesis: byte-identical
   payload.** A full `pcieep_build.sh` on the BC-250 produced a bitstream of
   **exactly the same size, 21,647,330 bytes**, differing in **35 bytes out of
   21,647,330** -- offsets 28 to 123, entirely header:

   | | workstation | BC-250 |
   |---|---|---|
   | attribute order | `COMPRESS=TRUE;UserID=0XFFFFFFFF` | `UserID=0XFFFFFFFF;COMPRESS=TRUE` |
   | build time | `00:46:12` | `10:18:32` |

   **All 21,647,207 bytes of configuration payload from offset 124 onward are
   identical.** Timing and routing matched exactly too: WNS 0.001, TNS 0.000,
   WHS 0.009, 0 failing endpoints of 672,531, 286,806 of 286,806 routable nets
   routed, 0 routing errors, on both.

So the 909 fs is not luck and not machine-dependent. **What it IS, is thin:**
see the strategy sweep below.

## THE CLAIM THIS OVERTURNS

`CLAUDE.md` states, under what the BC-250 is **NOT** for:

> *"A full `pcieep` build peaks at 25.0 GiB and does not fit."*

**MEASURED: it peaks at 11.85 GB and it fits.** The build ran to a bitstream
with 0 errors. `CLAUDE.md` already carried a CORRECTION that the 25.0 GiB
figure did not reproduce (10.66 GB on the workstation); this is the second
independent measurement against it, on the other machine, and the first that
actually completes the job there.

Lowest free physical during the run: **2,361 MB**. Tight, and it never ran out.

## Procedure

1. `help -syntax place_design` etc. to establish whether a seed exists. It
   does not. **Asked the tool rather than assuming the requested knob was
   real.**
2. Probed `STATS.WNS` on the ALREADY-COMPLETE run before disturbing anything,
   to prove the harvest path returns a known answer. It returned 0.000909
   against a report reading +0.001. **This was the teeth test for the
   scraper**, and skipping it would have spent five hours writing blank
   fields, which is exactly how the strategy knob failed earlier this week.
3. Re-ran the same strategy (determinism control), implementation only,
   reusing the existing synthesis.
4. Ran the full flow on the BC-250 -- synthesis included, so this is the
   stronger test.
5. `cmp -l` the two bitstreams and located every differing byte.

## Evidence

```
lane 1, re-run:  SWEEP_RESULT Performance_ExplorePostRoutePhysOpt
                 WNS=0.000909 TNS=0.000000 WHS=0.009101 THS=0.000000 secs=2288
saved artifact:  WNS 0.000909  TNS 0.000000  WHS 0.009101

lane 2, BC-250:  WNS=0.001 TNS=0.000 failing=0 total=672531 WHS=0.009
                 286806 of 286806 routable nets, 0 routing errors
                 vivado peak 11.85 GB, lowest free physical 2361 MB
                 wall 07:59:51 -> 10:18:32 = 2h18m

cmp -l  ->  35 differing bytes, min offset 28, max offset 123
```

## Measured and REJECTED -- do not retry

- **A seed sweep.** There is no seed. `place_design` accepts `-directive` and
  nothing else. Do not go looking for `STEPS.*.ARGS.SEED`.
- **"Post-route phys_opt buys the margin."** Plausible from the strategy NAME
  and **wrong**. Within the SAME run, EPR's `routed` report and its
  `postroute_physopted` report are both `WNS 0.001, 0 failing endpoints` --
  the step changed nothing, because slack was already positive and it had
  nothing to fix. The margin comes from somewhere in place/route that remains
  **unattributed**. Ruling out phys_opt promotes no other candidate; there
  were never only two.
- **Quoting the BC-250 wall time as a speed ratio.** 2h18m against ~56 min
  looks like 2.5x, close to the documented 2.3x, and it is CONFOUNDED: the job
  was launched under `MemoryHigh=11G` and peaked at 11.85 GB, so it spent part
  of the build throttled into reclaim. **A capped job's wall time is not a
  measurement of the machine.** Re-measure with a cap above the peak if the
  ratio matters.

## Measurement traps hit

- **`grep -A3 "WNS(ns)" | tail -1` returns the WRONG TABLE.** `WNS(ns)` appears
  in several sections of a timing summary; the naive extraction returned a
  clock name where a number belonged. It was obvious garbage and so was caught
  at once, but a subtler mis-parse would have read as data. Anchor on
  `/Design Timing Summary/` first.
- **The waiter exited 0 on a build it had not judged**, and separately a
  bounded poller exited 0 mid-run. Both are facts about the harness. Gate on
  what the work writes.
- **A remote command silently ran in the wrong directory.** `ssh host "bash -c
  'md5sum ...'"` runs in the LOGIN user's home (`/home/labuser`), while the
  sync destination is `/home/orencollaco/GitHub/llama.vhdl`. The verification
  reported "No such file or directory" for files that were present. Worse, the
  same broken command was re-sent four times before the missing `cd` was
  actually added. **Read your own command after the first failure.**

## Open, not yet answered

- **Where the EPR margin actually comes from.** Not phys_opt. Unattributed.
- **Whether `Performance_ExtraTimingOpt` should be the default instead.** It
  measured **WNS +0.033 with 0 failing endpoints and a clean route -- 36x the
  margin of the shipped strategy.** No bitstream exists for it, because the
  sweep runs implementation only.
- **The BC-250's true unthrottled peak and speed ratio for this job.**
