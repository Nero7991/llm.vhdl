# Build 15 congestion figure, written 2026-09-22 09:46 during Global Iteration 0 (re-implementation, rescue recipe)

MEASURED `[Route 35-449]`:
|      NORTH|     8x8|      3.56|   32x32|      8.63|     8x8|      5.88|
|      SOUTH|   64x64|     11.75| 128x128|     23.49|   16x16|      7.35|
|       EAST|   32x32|      7.68|   32x32|      9.84|   32x32|     14.97|
|       WEST|   32x32|     10.34|   64x64|     14.10|   32x32|     15.24|
max Global `% Tiles` = **11.75 SOUTH**. Build 14's rescue draw on the netlist without the shadow: 10.37.
After build 14 (11.73, failed) the figure below ~12.5 predicts nothing; recorded as a figure. Placed CLB 54,640
(build 14 rescue: 54,607), BRAM 569 (+2 = the shadow, as predicted in COMPOSITION.md). The verdict decides.

## Draw 2 (AltSpreadLogic_high placer), written 2026-09-22 12:19 during Global Iteration 0
|      NORTH|     8x8|      2.64|     8x8|      5.57|   16x16|      6.06|
|      SOUTH|   32x32|     11.00|   64x64|     21.45|   32x32|      9.18|
|       EAST|   16x16|      5.80|     8x8|      5.99|   64x64|     16.56|
|       WEST|   64x64|     11.92|   64x64|     14.23|   32x32|     17.86|
max Global `% Tiles` = **11.92 WEST** (draw 1: 11.75, failed; build 14 rescue: 10.37, routed). Placed CLB 54,584. A figure, not a verdict.
