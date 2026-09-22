# The router said it could not route build 11b at minute nine and the build ran another two and a half hours. Which signal was worth acting on?

Date: 2026-09-21. TRACK CONGABORT. No Vivado was run: every number below comes
from logs already on this box. Hardware untouched; the card is still running
build 9's bitstream.

## The question, verbatim

> Card build 11b ran 4 hours 25 minutes and failed. `write_bitstream` refused
> because 146,948 of 669,216 routable nets were in RESOURCE CONFLICT.
> `[Route 35-447]` is the tool stating outright that it cannot route the design,
> and it fired roughly two and a half hours before the build gave up. Deliver an
> opt-in early abort. Decide and JUSTIFY whether the trigger is `[Route 35-447]`
> alone, or a congestion LEVEL threshold, or both. State the false-positive risk
> explicitly: if you cannot bound it, say so and keep the default off.

## The answer, up front

**`[Route 35-447]` is useless as a trigger and so is every congestion LEVEL.
Build 10 -- which routed legally and failed on timing -- carries `35-447`, and
so do 7 of the 8 card implementation runs on this box that produced a legal
route.** A guard on it would have killed almost every healthy build.

**The signal that works is the continuous one in the same report, and only its
GLOBAL column: the largest per-direction `% Tiles` in the
`[Route 35-449] Initial Estimated Congestion` table.** Over all 12 card
implementation runs available, the 8 that routed legally score 6.96 to 11.95 and
the 4 that did not score 12.78 to 17.36. It is printed at route_design elapsed
**00:07:48**, which on build 11b is **2h26m** before the build gave up.

**The false-positive rate is NOT bounded and cannot be from this evidence.** The
separating gap is 0.83 percentage points wide and 12 observations place one
threshold inside it; the whole interval (11.95, 12.78] fits the data equally
well. Default OFF, opt-in per run, and that is the honest outcome rather than a
hedge.

**A pass/fail routability check at the end of the build is worth nothing and was
not built.** See the attribution control.

## The procedure, in the order it was run, and what each step isolates

1. **Anchored counts of every candidate message in build 11b and build 10.**
   Isolates whether the obvious trigger discriminates at all. It does not:
   build 10 carries `35-447`. This killed the brief's leading candidate in the
   first measurement.
2. **Enumerate every card-build log on the box, not just the two named.**
   `hw/fk33/results/card_*` yields nine directories and twelve implementation
   runs, including a second route failure (`card_seqrst_..._ROUTEFAIL`) and a
   third and fourth inside `card_swg_2026-09-20`. This is the step that turned a
   two-point threshold fit -- which this project records as unable to tell
   scatter from slope -- into a twelve-point one.
3. **Ground truth read FROM each log, line-anchored, never asserted.**
   `^CRITICAL WARNING: \[Route 35-162\]` present means the run did not produce a
   legal route. Controls for labelling a run by what it was launched to be.
4. **Score every discrete candidate.** `35-447`, `[Place 46-14]`, `35-448`
   level, `35-581` level, `Effective congestion level`, post-placement
   `[Place 30-612]` region size, `35-445` presence. All rejected, each for a
   measured reason, tabulated below.
5. **Timestamp each candidate inside route_design.** This is the step that
   separates a correct verdict from a useful one, and it eliminated the only
   discrete signal that separated perfectly: `Effective congestion level`
   appears at elapsed 02:32:18 of 02:34:07.
6. **Score the continuous `% Tiles` figures from `[Route 35-449]`, all three
   columns.** Isolates which column carries the information. Only Global does.
7. **Column mutants as the attribution control.** Global 12/12, Long best 11/12,
   Short best 10/12. The choice of column is measured, not assumed.
8. **Threshold mutants.** Establishes where the check's resolution floor is and
   which thresholds are indistinguishable on this evidence.
9. **Truncation mutants.** Found a real defect (below).
10. **Attribution control on the EXISTING verdict mechanism.** Establishes that
    a new pass/fail check has no value.

## The evidence

### The dataset. Twelve implementation runs, ground truth from each log.

```
LOG                                                  G%Tiles  ROUTE_LEGAL
card_xexp_wdog_seam_2026-09-18/build.stdout             6.96  yes
card_smp_bases_2026-09-18/build.stdout                  8.88  yes
card_swg_2026-09-20/reimpl_extranetdelay.stdout         9.33  yes
card_kvreg_2026-09-20/build.stdout                      9.39  yes
card_maxpos_grant_2026-09-18/build.stdout              10.09  yes
card_seqrst_bfnorm_2026-09-19/build.stdout             10.37  yes
card_bconst_qkn_2026-09-19/build.stdout                10.91  yes
card_build10_FAILED_2026-09-20 (missed timing)         11.95  yes
------------------------------------------------------------ gap: 0.83 points
card_seqrst_2026-09-19_ROUTEFAIL/build.stdout          12.78  NO   9,293 nets
card_swg_2026-09-20/build_synth_and_first_impl.stdout   13.45  NO     209 nets
card_swg_2026-09-20/runme_altclbrouting_FAILED.log     13.45  NO     209 nets
card_build11b_FAILED_2026-09-20                        17.36  NO 146,948 nets
```

### Every discrete candidate, and why each one loses

| candidate | fires on legal routes | misses real failures | when it fires |
|---|---|---|---|
| `WARNING: [Route 35-447]` | **7 of 8** | 0 | route +00:09:51 |
| `WARNING: [Place 46-14]` | **8 of 8** | 0 | end of place_design |
| `[Route 35-448]` level >= 6 | **2 of 8** (smp_bases, maxpos_grant) | **1** (seqrst failed at level 5) | route +00:07:48 |
| `[Route 35-581]` level >= 6 | **6 of 8** | 0 | route +00:07:48 |
| `Effective congestion level` >= 6 | 0 of 8 | 0 | **route +02:32:18 of 02:34:07** |
| `[Route 35-162]`, `RTSTAT-*` | 0 of 8 | 0 | **route +02:32:21** |
| `[Place 30-612]` Global region = 128x128 | 0 of 8 | **3 of 4** | **end of place_design** |
| `[Route 35-445]` present | 0 of 8 | **3 of 4** | route +00:01:01 |
| **`[Route 35-449]` max Global % Tiles** | **0 of 8** | **0 of 4** | **route +00:07:48** |

`[Route 35-448]` is the instructive loser: it is wrong in **both** directions at
once, firing on two builds that routed and missing one that did not. That is the
shape this project has already recorded for a census filter -- a check can be
wrong in either direction and both run clean.

The two zero-false-positive alternatives, `[Place 30-612]` at 128x128 and
`[Route 35-445]`, each catch only build 11b. **They are single observations, not
triggers**, and `[Place 30-612]` is tempting precisely because it is the
earliest signal of all -- it would save phys_opt as well. It is recorded here so
that the next person does not have to rediscover that it has 3 misses in 4.

### Where the time actually goes, from build 11b's own phase timers

```
route_design elapsed
  00:07:48   [Route 35-449] Initial Estimated Congestion   <-- the trigger
  00:09:51   [Route 35-447] Congestion is preventing ...
  01:03:18   Phase 4.2 Global Iteration 1
  02:06:59   Phase 4.3 Global Iteration 2
  02:32:18   Effective congestion level: 7
  02:32:21   [Route 35-162] 146948 signals failed to route
  02:34:07   route_design completed successfully   <-- and it did not
  +00:00:23  write_bitstream failed, [DRC RTSTAT-13]
```

DERIVED: aborting at the trigger saves 02:34:07 - 00:07:48 = **02:26:19** of
route_design, plus the report generation and write_bitstream after it. Aborting
on `Effective congestion level` saves **00:01:49**.

### Threshold mutants

```
threshold=11.90  PASS=11 FAIL=1   FAIL(false-positive) build10 at 11.95
threshold=11.96  PASS=12 FAIL=0   <-- indistinguishable
threshold=12.40  PASS=12 FAIL=0   <-- indistinguishable
threshold=12.50  PASS=12 FAIL=0   <-- shipped default, the gap's midpoint
threshold=12.78  PASS=12 FAIL=0   <-- indistinguishable
threshold=12.79  PASS=11 FAIL=1   FAIL(missed) seqrst_ROUTEFAIL at 12.78
threshold=13.50  PASS= 9 FAIL=3
threshold=18.00  PASS= 8 FAIL=4
```

**The four thresholds from 11.96 to 12.78 are indistinguishable on this
evidence, and that is the check's resolution floor, not a range of good
choices.** The shipped default of 12.5 is the midpoint of an interval, chosen
because nothing in the data prefers a point inside it.

### Column mutants, the attribution control for the choice of column

```
Global % Tiles (field 4), threshold 12.5   PASS=12 FAIL=0
Long   % Tiles (field 6), best of 4 tried  PASS=11 FAIL=1   (at 21.5)
Short  % Tiles (field 8), best of 5 tried  PASS=10 FAIL=2   (at 17.0 and 18.0)
```

Long and Short do not separate: the highest legal Long is 21.00 against build
11b's 20.76, and the highest legal Short is 16.64 against swg_firstimpl's 15.35.
The three columns sit in the same table and only one of them carries the signal.

### The attribution control for the existing verdict mechanism

The brief's instruction was to run this before adding any pass/fail check.

```
LOG                     legal  12-13638  FK33_BUILD_DONE  ^ERROR lines
smp_bases               yes        0            1              0
xexp_wdog_seam          yes        0            1              0
maxpos_grant            yes        0            1              0
bconst_qkn              yes        0            1              0
seqrst_ROUTEFAIL        no         1            0              5
seqrst_bfnorm           yes        0            1              0
swg_firstimpl           no         1            0              5
swg_reimpl              yes        0            0              0
swg_altclb_FAILED       no         0            0              3
kvreg                   yes        0            1              0
build10 (missed timing) yes        0            1              0
build11b                no         1            0              5
```

**A new routability verdict would have been credited with 4 detections. The
existing mechanism already makes all 4 and fires on none of the 8 legal
routes.** It is therefore worth nothing and was not built, exactly as
instructed. Both existing gates are independent: `FK33_BUILD_DONE` is never
printed because Vivado's own `wait_on_run` raises on the failed run, and
`pcieep_build.sh`'s `[[ -f "$BIT" ]] || { echo BITSTREAM_MISSING; exit 1; }`
sees no bitstream.

**CORRECTION to the brief's premise, and it matters to anyone hardening this.**
The brief said `hw/fk33/pcieep_build.sh` "already fails the build by grepping
`^ERROR`". It does not. MEASURED: `grep -nE 'ERROR' hw/fk33/pcieep_build.sh`
returned **no lines at all** before this track's comment edit. The `^ERROR` grep
lives in a per-build watcher generated into the build root
(`/mnt/storage/fk33_builds/build11b/watch.sh`), which is not in the repo and is
written fresh per build. The conclusion is unchanged -- four for four, with the
`^ERROR` column above measured directly from the logs -- but the mechanism is
not where the brief said it was, and a hardening effort aimed at
`pcieep_build.sh`'s nonexistent grep would have hit nothing.

## The defect the teeth test found

The guard polls a log Vivado is still writing, so it can read the `[Route
35-449]` table half-printed. Cut one row in, after `NORTH` only, the first
version of the extractor returned a confident **`OK 4.81`** for build 11b, whose
real figure is **17.36** in `EAST`.

**NORTH is the LOWEST of the four directions in that table, so a partial read is
not merely incomplete, it is biased toward the wrong answer.** The fix requires
all four direction rows before any verdict is issued. Swept across nine cut
points, the verdict is now `NOVERDICT` at every one until the fourth row lands
and `ABORT 17.36` from that line onward:

```
cut@35587 NOVERDICT   cut@35596 NOVERDICT   cut@35600 ABORT 17.36
cut@35590 NOVERDICT   cut@35598 NOVERDICT   cut@35602 ABORT 17.36
cut@35592 NOVERDICT                         cut@35604 ABORT 17.36
cut@35594 NOVERDICT
```

Live this would have self-corrected on the next poll, so it was never going to
kill a healthy build. It would have done the other thing: silently reported
health on a doomed one, which is the failure the guard exists to prevent.

## Mutations that did NOT bite. These are the resolution floor.

Recorded under their own names because this is the most valuable section on
re-reading and the easiest to omit.

- **Thresholds 11.96, 12.40, 12.50 and 12.78 all give 12/12.** No experiment
  available on this box distinguishes them. The shipped 12.5 is not better than
  the other three, it is the midpoint of the interval they span.
- **ANDing `[Route 35-447]` into the trigger flips 0 of 12 verdicts.** It is
  present in all 4 failures and 7 of 8 legal routes, so it adds nothing to a
  Global-%-Tiles test. Decoration, and not shipped. This is the project's rule
  applied to a check that felt authoritative because it is the tool's own
  statement of intent.
- **Anchoring the `35-449` and `35-447` greps changes no verdict on any of the
  12 logs**, because those exact strings are Vivado-only and are not echoed. The
  anchors stay, and the reason is measured elsewhere: build 10's log -- a LEGAL
  route -- contains the line
  `#     error "FK33_PBLK FAIL: ... caused the global congestion level 7 that
  stopped the router."`, so an unanchored `congestion level 7` scores **1 match
  on a healthy build** against **0 anchored**. The hazard is real for a
  plausible alternative trigger even though it does not reach the shipped one.
- **Truncating before the table, and at every cut point up to the third row,
  already yielded `NOVERDICT` in the first version too.** Only the mid-table cut
  after exactly one row bit. A three-row cut would also have been silently
  wrong, and the single-row cut is what exposed it.
- **A log with two `[Route 35-449]` tables was not reachable.** Every card log
  on this box carries exactly one table and exactly four direction rows
  (MEASURED on six logs). The `tail -4` that judges a re-implementation on the
  most recent table is therefore **untested against a real two-table log** and
  is reasoning, not measurement.

## Measured and REJECTED -- do not retry

- **`[Route 35-447]` as a trigger, alone or as the primary condition.** It fires
  on build 10 and on 6 other builds that routed. MEASURED: 7 false positives in
  8 legal routes. The brief's leading candidate, and the first measurement
  killed it.
- **`[Place 46-14]`.** Present in 12 of 12. Zero discrimination.
- **`[Route 35-448]` or `[Route 35-581]` congestion LEVEL, at any threshold.**
  Level 6 global/short occurs in builds that routed legally (smp_bases,
  maxpos_grant, swg_reimpl, kvreg, bconst_qkn) and the seqrst route failure
  happened at level 5. The discrete level is too coarse: it is the same
  underlying quantity as `% Tiles`, rounded to a power of two, and the rounding
  destroys exactly the resolution the decision needs.
- **`Effective congestion level`, and `[Route 35-162]`, and any `RTSTAT-*`.**
  All separate perfectly and all print within 1m49s of route_design finishing.
  **A correct verdict that arrives at 02:32 of 02:34 is not an early abort.**
- **Long or Short `% Tiles`.** Do not separate. 11/12 and 10/12 at their best
  thresholds against Global's 12/12.
- **A pass/fail routability check at the end of the build.** See the attribution
  control: 4 of 4 already caught, 0 of 8 false, by two independent existing
  gates.
- **Reading `build.stdout` for the trigger.** It reaches disk through a pipe into
  `tee` and is block-buffered; CLAUDE.md records a full gate sitting at 0 rows
  for 20 minutes for this reason. `impl_1/runme.log` is written directly by the
  implementation run process. The finished `build.stdout` is fine for the
  self-test, which reads history rather than a live file.

## Measurement traps hit, including my own

- **I nearly fitted a threshold to two logs.** The brief supplied build 11b and
  build 10 and framed the task around them, and a one-parameter threshold placed
  between two points cannot be wrong about those two points and says nothing
  about any other. `ls hw/fk33/results/card_*` cost ten seconds and produced ten
  more runs, two of which (`seqrst_ROUTEFAIL` at 12.78 and `swg_firstimpl` at
  13.45) sit in the gap and are the only reason the threshold has any margin at
  all. **The dataset was four times larger than the brief and nothing was hiding
  it.**
- **The first separating signal I found was the wrong kind of correct.**
  `Effective congestion level` separates 12 of 12 perfectly and I had it
  tabulated before checking when it prints. Timestamping the candidates is the
  step that turned a clean-looking result into a rejection, and a verdict table
  alone would have shipped it.
- **`route_design completed successfully` and `Number of Unrouted Nets = 0` are
  both in build 11b's log and both are false.** Searched `hw/fk33/`, `sim/`,
  `tools/` and `docs/` for consumers: **no script, tcl or waiter keys on either
  string.** The only occurrences are in `docs/debugging/` where they are
  documented as traps, and the two tcl files that do read route status use
  `report_route_status`, which is the authority. Nothing to fix.
- **The `% Tiles` figure does not order severity, only legality.** 13.45
  conflicted 209 nets while 12.78 conflicted 9,293 and 17.36 conflicted 146,948.
  Reading the 0.83-point gap as a steep boundary would be reading scatter as a
  slope.
- **The trigger measures a RUN, not a DESIGN.** `card_swg_2026-09-20`'s first
  implementation scored 13.45 and failed; a re-implementation from the **same
  synthesis checkpoint** with `ExtraNetDelay` scored 9.33 and routed. A trip
  means "this run will not route", never "this design cannot route", and quoting
  it as a property of the RTL would be the cross-configuration borrowing this
  project keeps recording.

## Open, not yet answered

- **A fifth route failure exists and its log is gone.** The SMP build of
  2026-09-17 (`docs/debugging/2026-09-18_the-sampler-build-did-not-route.md`,
  11,037 signals failed, 8,867 node overlaps, unit `buildsmp`) is a real card
  route failure. `grep -rl '11037 signals'` over `/mnt/storage/fk33_builds` and
  `hw/fk33/results` returns **nothing**: only the write-up survives. Its
  `% Tiles` is unknown and **it could fall below 11.95 and destroy the
  separation.** This is the single measurement most likely to overturn this
  document.
- **The false-positive rate.** Not bounded and not boundable from 12 runs. Every
  legal route observed sits at or below 11.95 and every failure at or above
  12.78; nothing establishes that a future healthy build cannot reach 13.
- **Whether `[Place 30-612]` becomes usable with more data.** Zero false
  positives in 8 and it fires before phys_opt, which is worth ~15 further
  minutes. 3 misses in 4 today.
- **Whether the guard's `systemctl --user kill` lets `pcieep_build.sh`'s EXIT
  trap harvest.** Not tested, because testing it means running a build. The
  guard therefore writes its own `FK33_CONGABORT.txt` into `BUILD_ROOT` before
  killing, so the reason is durable either way.
- **The `tail -4` two-table path.** No real two-table log exists to test it.

## Artefacts

| file | what |
|---|---|
| `hw/fk33/congestion_guard.sh` | the guard, with `--check` and `--selftest` |
| `hw/fk33/pcieep_build.sh` | header note only: how to arm it, and why it is not wired in |
| `hw/fk33/results/card_build11b_FAILED_2026-09-20/build.stdout.full.gz` | the MUST-FIRE row, now in the repo rather than only on an unbacked-up volume |

`bash hw/fk33/congestion_guard.sh --selftest` reproduces the twelve-row table
and needs no Vivado, no hardware and no `/mnt/storage`.


## CORRECTION 2026-09-22: the separation is broken, from below

Build 14 (`hw/fk33/results/card_build14_2026-09-22/`, build 12b's design plus
the 17-flop `XEXP_OUT` register, no levers) scored max Global `% Tiles`
**11.73** and FAILED TO ROUTE with 11 nets in resource conflict. That is
inside the band this document called legal (6.96-11.95) and below build 12b's
11.95, which routed. The claim that "every legal route so far had max Global
% Tiles in 6.96-11.95 and every routing failure 12.78-17.36" is WITHDRAWN as a
separation: the two bands now overlap by at least 0.22 points. What still
holds after thirteen runs: nothing at or above 12.78 has routed (build 13 at
13.09 failed, predicted), so a trip above ~12.5 remains a usable abort
trigger; a figure below it is NOT evidence that a run will route. The
false-positive rate was never bounded; the false-negative rate is now
measured at one in the six runs below the threshold.
