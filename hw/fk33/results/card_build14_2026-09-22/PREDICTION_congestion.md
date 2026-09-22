# Build 14 congestion prediction, written 2026-09-22 01:01 while Phase 4.1 Global Iteration 0 was running

MEASURED from build.stdout `[Route 35-449] Initial Estimated Congestion`:
|      NORTH|     8x8|      3.84|   32x32|      8.50|     8x8|      6.60|
|      SOUTH|   32x32|     10.60| 128x128|     22.04|   16x16|      6.54|
|       EAST|   32x32|      5.22|   32x32|      7.02|   32x32|     12.92|
|       WEST|   32x32|     11.73|   64x64|     17.06|   32x32|     14.40|
max Global `% Tiles` = **11.73 WEST**. `[Route 35-448]` Global/Short level 5 (32x32); `[Route 35-581]` Timing level 7 (128x128).

The CONGABORT calibration: legal routes 6.96-11.95 max Global % Tiles, route failures 12.78-17.36,
threshold 12.5. Build 12b (this design minus the XEXP_OUT register) scored 11.95 and routed legally;
build 13 scored 13.09 and failed with 11,561 conflicts.

PREDICTION, pre-registered: max Global 11.73 WEST is inside the legal band, below every recorded
failure, so build 14 is predicted to ROUTE LEGALLY (0 nets with routing errors in report_route_status).
Timing is NOT predicted from this figure; the pre-launch prediction (COMPOSITION.md) is that it closes at
75 MHz like 12b (+0.046), which was a thin margin and is a bound, not headroom. Timing congestion level 7
(128x128) is higher than 13's level 6; that signal has never separated legal from failed routes here and
is recorded, not used. Placed: CLB 54,884 (99.86%), 76 free tiles; LUT 361,887; BRAM 567; DSP 2,087.
The verdict decides, not this file.
