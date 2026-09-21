# Registered 2026-09-21 ~10:05, BEFORE build 12b's routing outcome is known

First live application of `hw/fk33/congestion_guard.sh`'s measured trigger
(TRACK CONGABORT, commit 20d3aab). Written before `route_design` finished so the
verdict can be SCORED rather than retrofitted.

## The measurement

Build 12b, `[Route 35-449] Initial Estimated Congestion`, Global `% Tiles`:

    NORTH 3.42   SOUTH 9.81   EAST 6.31   WEST 10.74      max = 10.74

CONGABORT's separation over twelve card implementation runs, ground truth read
from each log's anchored `[Route 35-162]`:

    8 legal routes    6.96 - 11.95
    4 route failures 12.78 - 17.36
    shipped threshold 12.5, default OFF

## PREDICTION

**Build 12b ROUTES LEGALLY** -- `report_route_status` will show
`nets with routing errors = 0`. 10.74 is inside the legal band and 2.04 points
below the lowest observed failure.

This says NOTHING about whether it MEETS TIMING. Build 10 routed legally at
75 MHz and missed by -5.819 ns.

## What would falsify the trigger rather than the build

If build 12b routes, the trigger is consistent. If build 12b FAILS to route at
10.74, the separation is broken and the guard must not be armed: a failure below
11.95 would put a measured failure inside the legal band.

## Caveats, all CONGABORT's own and all stated in advance

- **The gap is 0.83 points wide** (11.95 to 12.78) and the false-positive rate
  is NOT bounded from twelve runs. Thresholds 11.96 / 12.40 / 12.50 / 12.78 are
  indistinguishable on the data.
- **The trigger measures a RUN, not a DESIGN.** `card_swg`'s first
  implementation scored 13.45 and failed; a re-implementation from the SAME
  synthesis checkpoint with `ExtraNetDelay` scored 9.33 and routed.
- **`% Tiles` does not order severity.** 13.45 gave 209 conflicted nets while
  12.78 gave 9,293.
- **A fifth route failure's log is gone** (the SMP build of 2026-09-17, 11,037
  signals). Its `% Tiles` could fall below 11.95 and destroy the separation.
  This is the single measurement most likely to overturn the trigger.

## The two signals that carry NO information here, recorded so they are not misread

- `[Route 35-447]` "Congestion is preventing the router from routing all nets"
  FIRED on build 12b. MEASURED by CONGABORT: it fires on **7 of the 8 legal
  routes**, build 10 included. It is not a failure signal.
- `[Route 35-448]` / `[Route 35-581]` both report **level 6** here. MEASURED:
  level >= 6 is wrong in BOTH directions, with 2 false positives on legal routes
  and 1 miss (a failure at level 5). Builds 10 and 11b were both level 6 and
  build 10 routed.
- `[Place 46-14]` is present. It fires on 12 of 12.
