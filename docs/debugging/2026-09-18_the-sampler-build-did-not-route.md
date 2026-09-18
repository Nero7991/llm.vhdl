# The sampler build routed "successfully", was not legally routed, and said so only as a warning

## The question, verbatim

> The `FK33_CARD=1` A+B+C+D build with `SMP_EN=true` at 75 MHz ran for 3 h 53 m
> and produced no bitstream. What failed, and was it the sampler?

Date: 2026-09-18. Build started 2026-09-17 20:45, ended 00:42, unit `buildsmp`,
`MemoryHigh=20G`.

## The answer, up front

**Routing congestion. 11,037 signals failed to route and the design ended with
8,867 node overlaps, so `write_bitstream`'s DRC refused it.**

**And the three things a watcher would naturally check ALL SAID IT WAS FINE:**

```
Number of Failed Nets               = 0
Routing Is Done.
route_design completed successfully
```

The actual verdict was a CRITICAL WARNING sitting between them:

```
CRITICAL WARNING: [Route 35-162] 11037 signals failed to route due to routing congestion.
CRITICAL WARNING: [Route 35-2]   Design is not legally routed. There are 8867 node overlaps.
```

The first hard `ERROR` appeared only at bitgen, an hour of reports later:

```
ERROR: [DRC RTSTAT-6] Partial route conflicts: 11037 net(s) have a partial conflict.
ERROR: [Vivado 12-1345] Error(s) found during DRC. Bitgen not run.
```

**Whether the sampler caused it is NOT established**, and the reason is
recorded below rather than papered over.

## This is the project's own recorded trap, in a fourth place

`CLAUDE.md` already says: *"A COMPLETION SIGNAL THAT ALSO FIRES ON FAILURE IS
NOT A COMPLETION SIGNAL"*, with three instances -- `wait_on_run -timeout`
returning 0 on expiry, a waiter firing on a killed unit, and a block-buffered
log. **This is the fourth and it is inside Vivado itself:
`route_design completed successfully` means the router stopped, not that the
design is routed.**

`Number of Failed Nets = 0` makes it worse rather than better, because it is a
DIFFERENT metric that genuinely was zero: a net can be fully routed and still
overlap another net's nodes. **A metric that is true and irrelevant reads
exactly like a metric that is true and relevant.**

**The monitoring rule that follows, and it cost four hours to learn:**
`grep -c '^ERROR'` is not a build health check on a Vivado run. Gate on
`CRITICAL WARNING: \[Route` and on the literal string
`Design is not legally routed` as well, and treat the absence of
`FK33_BUILD_DONE` as failure regardless of what any stage said about itself.
This dispatcher reported "routing cleanly, 0 errors" at 21:59 while `[Route
35-162]` was already inevitable; the grep was correct and the conclusion was
not.

## The evidence

The router made no progress across its two global iterations. Node overlaps
per iteration, in order:

```
iteration 0:  87478 -> 38370 -> 20991 -> 13932 -> 10335
iteration 1: 549404 -> 379459 -> 195959 -> 97572 -> 48623 -> 27793 -> 16647
final:                                                                8867
```

**Iteration 1 STARTS at 549,404, fifty times worse than where iteration 0
ended.** That is the router ripping up and retrying, and it converged to a
worse number than it had before: 8,867 against the 10,335 it already had, for
a whole extra iteration of work.

Initial estimated congestion, which is where it was already visible:

```
| Direction | Global Congestion  | Long Congestion    | Short Congestion   |
|      NORTH|   16x16      2.91% |   32x32      7.73% |   16x16      4.71% |
|      SOUTH|   64x64      8.89% |   64x64     18.46% |   16x16      5.79% |
|       EAST|   32x32      7.54% |   64x64     13.24% |   16x16      9.89% |
|       WEST|   64x64     10.51% |   64x64     15.07% |   32x32     11.88% |
```

`64x64` windows in three of four directions, and **18.46% of tiles in LONG
congestion southbound**. Effective congestion level reached **6** (threshold
0.85).

Where the conflicting nets live, by frequency of the names Vivado printed:

| count | owner |
|---|---|
| 50 | `bd_i/eng/inst/eng/dut/streamer/i_1` |
| 24 | `bd_i/eng/inst/eng/dut/streamer/i_2` |
| 12 | `bd_i/eng/inst/eng/dut/core/ARG__0` |
| 9 | `bd_i/eng/inst/eng/dut/core/y_addr` |
| 7 | `bd_i/eng/inst/eng/dut/core/tr_reg` |

**Every one is in `bd_i/eng` -- subsystem A's weight streamer and matvec core
-- and NOT in `bd_i/card`, which is where the sampler lives.** That is a fact
about which nets Vivado NAMED in a truncated list, not a congestion
attribution, and it is recorded as the former.

## Why "the sampler caused it" is NOT established

**The failed run never wrote a utilization report.** `report_utilization` is at
`build_fk33_pcieep.tcl:2331`, after `write_bitstream`, so the run aborted before
it. There is therefore **no routed utilization for the sampler build at all**,
and the only like-for-like comparison available is post-synthesis:

| post-synthesis | no sampler (16:59) | with sampler | delta |
|---|---|---|---|
| CLB Registers | 310,597 | 313,055 | **+2,458** |
| BRAM tiles | 449.5 | 449.5 | 0 |
| URAM288 | 32 | 32 | 0 |
| DSPs | 2,121 | 2,121 | 0 |

The register delta is same-stage and is real. **The LUT column is not
comparable**: the sampler run's `CLB LUTs*` line was never produced, and the
cell census's `LUT1..LUT6` sum (343,910) is a different quantity from
`CLB LUTs*` because the latter includes LUT-as-memory. Subtracting them would
be the recorded parts-do-not-sum-across-contexts error.

**And 76.49% LUT utilization is not a congestion argument anyway.** The 19:04
build routed at that number with WNS +0.009. Congestion is local wire demand,
not global occupancy, so a small addition placed badly can do this and a large
one placed well may not. **A +2,458 register change turning a routable design
unroutable is plausible and is not evidence.**

## Measured and REJECTED -- do not retry

* **Reading `hw/fk33/.../fk33_pcieep_util.rpt` as this build's utilization.**
  Its mtime is `Sep 17 19:04` -- it belongs to the PREVIOUS build. Checking the
  timestamp before reading it is what stopped a stale table being compared
  against a current one, which is this project's recorded same-tree trap and
  cost a 9.7x wrong number last time it was not checked.
* **Quoting `WNS=0.458 | TNS=0.000` from the log as the routed result.** All
  three `WNS=` lines in the router are labelled **`Intermediate Timing
  Summary`**, and the one that looks best (`+0.458`) was taken with overlaps
  still outstanding. The one that looks worst (`-0.786`, TNS -325) was taken
  mid-iteration with 10,335 overlaps. **None of them is a routed number, and
  the build never produced one** because `FK33_TIMING` is emitted after the
  bitstream.
* **`place_design`'s `+0.375`.** Post-placement, and this project has MEASURED
  that nothing before `route_design` orders two runs correctly on this part,
  with the sign inverting in one recorded case.

## Measurement traps hit, including my own

* **I reported "routing cleanly, 0 errors" while the design was already
  unroutable.** `grep -c '^ERROR'` returned 0 and that was true. The rule
  above -- gate on `CRITICAL WARNING: \[Route` too -- exists because of this.
* **The monitor's own event stream showed `Effective congestion level: 6` and
  I read it as progress noise.** It was the answer, forty minutes early.
* **`route_design completed successfully` was quoted by the monitor as a
  completion event.** It is a completion event. It is not a success event.

## What was done about it

Re-running the whole flow at `FK33_IMPL_STRATEGY=Congestion_SpreadLogic_high`,
Oren's call, 2026-09-18 06:22, unit `buildcong`. The strategy is applied and
confirmed from the build's own anchored sentinel
(`FK33_IMPL_STRATEGY Congestion_SpreadLogic_high`); the default is
`Performance_RefinePlacement`, which gives `place_design -directive
ExtraPostPlacementOpt`.

`gen_pcieep.py:3008-3012` records a MEASURED result against a congestion
directive -- *"switching to `AltSpreadLogic_high` [...] WITHOUT removing
pblock_bd_i moves the core's clock-region distribution by about six points and
does not make the design routable. The constraint was the problem, not the
directive."* **That measurement is on a different design state** (before A fit,
before the `buf` conversion) and is not evidence about this one, which is why
it was not treated as a refusal. If the strategy also fails, that comment is
the next thing to read, and the pblock is the next suspect.

## Open, not yet answered

* **Whether the sampler is the cause.** The clean experiment is one run of the
  19:04 configuration under the SAME strategy: if it also fails to route, the
  sampler is exonerated and the strategy or the pblock is the variable. Nobody
  has run it and it costs another four hours.
* **Where the congestion actually is.** `report_design_analysis -congestion`
  is at `build_fk33_pcieep.tcl:2299`, after the bitstream, so it has never run
  on a failing build. It could be run by hand against
  `bd_wrapper_routed.dcp`, which DOES exist from the failed run. That is the
  cheapest real attribution available and it was not done, because the rebuild
  had the memory.
* **Whether `Congestion_SpreadLogic_high` costs timing.** The 19:04 build had
  WNS +0.009 at 75 MHz, which is 0.009 ns of margin. A congestion strategy
  that spreads logic lengthens nets. **It is entirely possible for the next run
  to route legally and miss timing**, and that would be a different failure
  needing a different lever, not a regression.
