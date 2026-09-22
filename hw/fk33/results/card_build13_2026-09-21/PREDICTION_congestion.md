# Build 13 congestion prediction, written 2026-09-21 20:50 while Phase 4 was running

MEASURED from impl_1/runme.log `[Route 35-449] Initial Estimated Congestion`:
max Global `% Tiles` = **13.09** (WEST, 32x32); SOUTH 10.65, EAST 5.57, NORTH 3.14.
Long: SOUTH 19.72, WEST 16.42. Short: WEST 17.81, EAST 14.56. `[Route 35-448]` level 5.

The CONGABORT calibration (hw/fk33/results, 2026-09-21): every legal route so far
had max Global % Tiles in 6.96-11.95 and every routing failure 12.78-17.36,
threshold 12.5. Build 12b was 11.95 and routed legally.

PREDICTION, pre-registered: 13.09 is above every legal route recorded and inside
the failure band, so build 13 is predicted NOT to route legally (nets with
routing errors > 0 in report_route_status), or to route with a large negative
WNS. This is the first out-of-sample test of the 12.5 threshold. CONGABORT is
OFF, so the build runs to its own verdict; the verdict decides, not this file.
Placed: CLB 54,802 (99.71%), 158 free tiles; BRAM 595 (+28 vs 12b).
