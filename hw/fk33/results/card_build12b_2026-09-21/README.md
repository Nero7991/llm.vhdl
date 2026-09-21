# Build 12b: CLOSED. The new control, and HEAD is not broken.

FK33_CARD=1 card build, worktree `/mnt/storage/fk33_builds/wt12b` at `3e344a2`,
launched 2026-09-21 08:44, `FK33_BUILD_DONE` with a bitstream written 12:47.
Roughly 4h03m.

**This is the first card build to close since build 9**, and the first ever whose
two silent generator defaults were both stated explicitly rather than taken.

## The verdict, from the authority rather than from a completion line

```
# of routable nets..................... :      686882 :
    # of fully routed nets............. :      686882 :
# of nets with routing errors.......... :           0 :
```

```
 WNS(ns)   TNS(ns)   TNS Failing Endpoints   TNS Total Endpoints    WHS(ns)   THS(ns)   THS Failing
   0.046     0.000                       0               1528772      0.009     0.000             0
```

**Positive setup slack, zero failing endpoints, zero hold failures, zero routing
errors, on a legal route.** `clk_out3_bd_clk_wiz_0_0` requirement read from the
Intra Clock Table: **13.333 ns / 75.000 MHz** -- so the 0.046 is against the
clock the card actually runs, not a retarget.

Note `route_design completed successfully` and `Number of Unrouted Nets = 0` both
appear in this log, and both appeared in build 11b's while 146,948 nets were in
resource conflict. They are not why this build is judged to have closed; the
route-status table and a clean Phase 8 are. **Build 11b's Phase 8 fired
`[Route 35-162] 146948 signals failed to route` immediately after its opening
line; build 12b's Phase 8 opens and closes with nothing between.**

## Composition, every value verified from Vivado's own output

| lever | build 12b | evidence |
|---|---|---|
| per-row codebook `0b34200` | REVERTED | `rtl/matvec_core.vhd` md5 `b616c7822f93154b08200f9418489012`, the file builds 9 and 10 used |
| **`CB_STYLE`** | **`distributed`** | `Parameter CB_STYLE bound to: distributed` x4, `regs` count **0**; `CONFIG.CB_STYLE` emitted 3 times |
| **`ENG_CORE_MHZ`** | **75.000** | `CLKOUT3_REQUESTED_OUT_FREQ {75.000}`; sentinel `FK33_CORE_MHZ 75.000`; routed Clock Summary 13.333 / 75.000 |
| `NWIDE` | false | `Parameter NWIDE bound to: 0` |
| `FAST_POP` | false | `Parameter FAST_POP bound to: 0` x8 |
| `SWEEP_PIPE` | false | `Parameter SWEEP_PIPE bound to: 0` |
| `SCORE_EARLY` | false | `Parameter SCORE_EARLY bound to: 0` |

`build12_levers_off.patch` (in `../card_build12_2026-09-21/`) is the exact 6-line
diff, applied in the worktree so HEAD keeps every track's levers.

## Area, placed, against the two failures

| metric | build 10 | build 11b | **build 12b** |
|---|---|---|---|
| CLB | 54,751 (99.62%) | 54,822 (99.75%) | **54,451 (99.07%)** |
| CLB free tiles | 209 | 138 | **509** |
| CLB LUTs | 361,361 | 405,434 | 367,495 |
| CLB Registers | 308,213 | 296,396 | 310,570 |
| F7 Muxes | 28,422 | 53,022 | 28,125 |
| **F8 Muxes** | 6,027 | **18,315** | **5,979** |
| CARRY8 | 12,597 | 12,572 | 12,596 |

**The 12,288-MUXF8 tree is absent at synthesis AND placed.** Synthesis-stage
figures: F8 18,315 -> 5,979 (**-12,336**) and LUT-as-Distributed-RAM
54,650 -> 67,286 (**+12,636**), DSP identical at 2,087 in both. Two halves of one
swap, which is the third independent confirmation that `CB_STYLE=regs` -- not
`0b34200` -- produced build 11b's mux tree.

## The registered congestion prediction: HIT

`PREDICTION_congestion.md` was written at **10:10:49, before routing finished**.
It recorded max Global `% Tiles` = **10.74** (N 3.42, S 9.81, E 6.31, W 10.74)
against TRACK CONGABORT's measured separation -- legal routes 6.96-11.95, route
failures 12.78-17.36 -- and predicted a LEGAL ROUTE. **Correct.** First live use
of that trigger.

The caveats registered with it still stand and are not softened by one hit: the
separating gap is only 0.83 points wide, the false-positive rate is not bounded
from twelve runs, the trigger measures a RUN and not a DESIGN (`card_swg` scored
13.45 and failed, then re-implemented from the SAME checkpoint at 9.33 and
routed), `% Tiles` does not order severity, and a fifth route failure's log is
lost whose value could fall inside the legal band.

**Three signals fired and carried no information, as recorded in advance:**
`[Route 35-447]` (fires on 7 of 8 legal routes), `[Route 35-448]`/`[35-581]`
level 6 (both build 10 and build 11b were level 6 and build 10 routed), and
`[Place 46-14]` (fires on 12 of 12).

## Memory

Never the binding constraint. Swap peaked **25G** in synthesis against the
guard's 30G kill threshold, then sat at **8G** for the whole of placement and
routing; MemAvailable never below ~11.9 GB; two Vivado processes at 14.21 GB
summed. The `MemoryHigh=24G` cap was verified by reading the cgroup back
(`memory.high=25769803776`). The swap guard never fired. **The BC-250 lane ran
the build-10 apportionment concurrently**, which is one Vivado per box and within
the rule.

## What this build establishes, and what it does not

**ESTABLISHES:** current HEAD, with the codebook reverted and both generator
defaults stated, routes and closes at 75 MHz with +0.046 ns. Every later lever
build now has an attributable same-tree control, which build 10 never had.

**DOES NOT ESTABLISH:** anything about any lever, since it carries none. In
particular +0.046 is a thin margin -- build 9 closed at +0.061 -- so it is a
control, not headroom. Nothing here bears on build 10's -5.819, which had NWIDE
on and is separately apportioned in
`../build10_apportionment_2026-09-21/` (98.08% of its failing endpoints are in
subsystem C).

**NOT MEASURED:** tokens/s. This bitstream has not been loaded and the card still
runs build 9's image at 2.46 tok/s. With every lever off, build 12b should be
performance-equivalent to build 9, so a load is a correctness and throughput
CONTROL rather than an improvement.

## Files

`bd_wrapper.bit` (25,639,230 bytes) with `BITSTREAM.sha256`; route status; placed
and synth utilization; gzipped routed timing summary; the congestion report; the
pre-registered prediction; deduplicated sentinels and warnings; gzipped build log.
Synth, placed and routed DCPs plus the bitstream are preserved at
`/mnt/storage/fk33_builds/KEEP_build12b_dcp/` with `SHA256SUMS`.
