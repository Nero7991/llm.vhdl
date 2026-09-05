# The 200 MHz bitstream used the WORST passing strategy: a 299 ps spread

**2026-09-05.** Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`, pcieep (shell + subsystem A).

## The question

> The card bitstream meets 200 MHz by 909 fs. Is that repeatable, or did we get
> lucky once?

## The answer

**Repeatable, and the margin is an artefact of the strategy, not the design.**

- **Run to run: exactly reproducible.** Identical to six decimal places.
- **Machine to machine: payload-identical.** See
  `2026-09-05_cross-machine-bitstream-identity.md`.
- **Across strategies: a 299 ps spread on IDENTICAL RTL**, from **+0.096** to
  **-0.203**. The shipped bitstream sits at **+0.0009**, the WORST of the four
  that pass. A one-string change buys **~100 ps**, i.e. **105x** its margin.

| # | strategy | WNS | TNS | failing | achievable |
|---|---|---|---|---|---|
| 1 | **`Performance_NetDelay_high`** | **+0.095988** | 0 | 0 | **203.9 MHz** |
| 2 | `Performance_ExtraTimingOpt` | +0.032944 | 0 | 0 | 201.3 MHz |
| 3 | `Performance_ExploreWithRemap` | +0.009793 | 0 | 0 | 200.4 MHz |
| 4 | `Performance_ExplorePostRoutePhysOpt` **(shipped)** | +0.000909 | 0 | 0 | 200.0 MHz |
| 5 | `Performance_Explore` | -0.006552 | -0.07 | 20 | 199.7 MHz |
| 6 | `Performance_Retiming` | -0.203225 | -956.90 | 9,213 | 192.2 MHz |
| 7 | `Performance_RefinePlacement` | -0.203225 | -956.90 | 9,213 | 192.2 MHz |
| 8 | `Flow_RunPostRoutePhysOpt` | -0.220588 | -416.45 | 5,194 | 191.5 MHz |

Every passing row is CLEAN: 0 failing endpoints, fully routed, 0 routing errors.

## THE CONTROL REPRODUCED A NUMBER RECORDED WEEKS EARLIER

`Performance_RefinePlacement` was carried as a known-bad control so the sweep
could be shown to discriminate rather than reporting a flat line. It returned
**WNS -0.203225 -> 192.19 MHz**, and `docs/WORKLOG.md:167` independently
records the previously shipped bitstream at **"measured 192.2 MHz"**.

**A control that lands on an independently recorded prior measurement to three
significant figures is the strongest validation available here**, and it cost
one point of an eight-point sweep. Carry the known-bad control.

**CORRECTION to my own annotation.** The sweep script called this control
"the OLD default, measured -0.402". **That -0.402 belongs to the COMPOSED TOP,
not to pcieep**, and the two were conflated when the brief was written. The
correct prior figure for this build is -0.203, which is exactly what it hit.
The annotation was wrong; the control was right.

## ROWS 6 AND 7 ARE THE SAME CONFIGURATION, AND THAT IS NOT A BUG

`Performance_Retiming` and `Performance_RefinePlacement` returned results
identical to six decimal places on WNS, TNS AND the failing-endpoint count.
Two strategies do not agree by chance, so this was treated as a suspected
defect and NOT reported as data until explained. MEASURED, by querying each
strategy's step properties:

```
Performance_Retiming        place=ExtraPostPlacementOpt  phys=AlternateFlowWithRetiming  route=Explore  postroute=0
Performance_RefinePlacement place=ExtraPostPlacementOpt  phys=Explore                    route=Explore  postroute=0
```

**They differ in exactly one setting.** So `AlternateFlowWithRetiming` made no
change to this design -- retiming found nothing to move -- and with identical
effective inputs a deterministic tool returns a bit-identical result. The
sweep therefore tested **7 distinct configurations, not 8**.

The two report files have DIFFERENT md5s (differing timestamps) but identical
size and identical content. **The md5 difference is what proves they are two
real runs rather than one copied twice.**

## POST-ROUTE PHYS_OPT: A PREDICTION MADE, THEN TESTED

Early in the sweep, EPR (+0.001) and Explore (-0.007) differed by 7.5 ps and
the strategy NAMES suggested the post-route phys_opt step bought the margin.
**That was measured and REFUTED**: within the same run, EPR's `routed` and
`postroute_physopted` reports are both `WNS 0.001, 0 failing`. The step
changed nothing.

The stated interpretation was that it is *insurance*: a no-op when slack is
already positive, with work to do only when slack is negative. Row 8 tests it
independently:

| | WNS | TNS | failing |
|---|---|---|---|
| `Flow_RunPostRoutePhysOpt` routed | -0.352 | -701.51 | 6,201 |
| after post-route phys_opt | **-0.221** | **-416.45** | **5,194** |

**+131 ps of WNS, 285 ns of TNS, 1,007 endpoints fixed.** So the step's value
is conditional, and both halves are now measured:

- positive slack -> does nothing (EPR: 0.001 -> 0.001, 0 -> 0)
- negative slack -> does real work (Flow: -0.352 -> -0.221, 6,201 -> 5,194)

**Consequence: whatever becomes the default should RETAIN post-route
phys_opt**, not because it helps today, but because it is what claws back
~130 ps when B's and C's movers eventually push this design negative.

## The 9,213 failing endpoints are a number this project has seen before

Rows 6 and 7 fail on **9,213 endpoints of 672,673**. `docs/WORKLOG.md` carries
an open item: *"A-only endpoint bitstream's 9,213 failing endpoints still
unattributed by hierarchy."* This IS the A-only design. An exact four-digit
match across independent runs is unlikely to be coincidence.

**Stated as a LEAD, not a conclusion.** If it holds, those endpoints are a
structural cluster that surfaces whenever the design is perturbed adversely,
and `sim/ooc_mover_paths.tcl` already exists to census failing endpoints by
hierarchy. That would attribute a standing open item from a run already on
disk.

## Measured and REJECTED -- do not retry

- **A seed sweep.** MEASURED via `help -syntax`: Vivado 2023.2 has **no
  `-seed`** on `place_design`, `phys_opt_design` or `route_design`, only
  `-directive`. The literal request was unanswerable because the mechanism
  does not exist. Do not look for `STEPS.*.ARGS.SEED`.
- **"Post-route phys_opt buys the margin."** Refuted above.
- **Re-synthesising per strategy.** Implementation strategy does not affect
  synthesis, so `synth_1` is reused across all 8 points: **38-45 min each
  instead of ~56 min**, on one Vivado, sequentially.

## Measurement traps hit

- **`grep -A3 "WNS(ns)" | tail -1` reads the WRONG TABLE.** `WNS(ns)` appears
  in several sections; the naive form returned a clock NAME where a number
  belonged. Anchor on `/Design Timing Summary/` first.
- **`STATS.WNS` is the FINAL stage, not the routed one.** For a strategy with
  post-route phys_opt they differ (row 8: -0.221 vs -0.352). Comparing a
  scraped `STATS.WNS` against another strategy's routed report compares
  different stages. This is what exposed row 8's phys_opt gain, so read both.
- **A waiter's exit code is the harness's.** A waiter exited 0 on a gate that
  reported `REGRESSION: FAIL`; a bounded poller exited 0 mid-run; and a
  liveness check reported a healthy remote build "died" because it polled
  during the pre-Vivado host-selftest phase. **Absence-based liveness needs a
  latch**: only believe "gone" after the thing was seen present.

## Open, not yet answered

- **Where the margin actually comes from.** `NetDelay_high` uses
  `place=ExtraNetDelay_high` + `phys=AggressiveExplore` +
  `route=NoTimingRelaxation`. Which of the three carries the ~100 ps is NOT
  attributed, and a 3-point directive sweep would settle it.
- **Whether `NetDelay_high` should become the default.** On this evidence it
  should, but it is a build-time cost and Oren's call.
- **The 9,213 cluster.** Lead only.
