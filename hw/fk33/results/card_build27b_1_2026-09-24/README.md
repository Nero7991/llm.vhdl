# Card build 27B-1 (Qwen3.8-27B generics, KV_BLOCK 16): does NOT route (2026-09-24)

Worktree `/mnt/storage/fk33_builds/wt27` at `02cfdcd`, env `FK33_MODEL=QWEN38_27B
FK33_C_MAXPOS=16384 FK33_C_KV_BLOCK=16`, launched 02:51, NORM_HBM on.

MEASURED, all three implementation attempts failed:

| attempt | result |
|---|---|
| default impl | `[Route 35-3] Design is not routable as its global congestion level is 6` (05:28) |
| re-implementation, `Congestion_SpreadLogic_high`, route `AlternateCLBRouting` | significant portion unrouted, no bitstream |
| stage-2 reroute of the rescue DCP, `AggressiveExplore` (08:02-10:11) | conflicts 1,681,285 -> 1,698,125, `RR_TIMING WNS=-7.434 WHS=-0.034`, `RR_FAIL` |

Placed utilization (`bd_wrapper_utilization_placed.rpt`): CLB LUTs 400,619 of
439,680 (**91.12%**), **CLB 54,871 of 54,960 (99.84%)**, BRAM 608.5 of 672
(90.55%), DSP 2,030 of 2,880 (70.49%), URAM 50 of 320. Synthesis peak 15.0 GB.

The 9B card already sits at 99.75% CLB; the 27B generics add to it, so a
directive search on this die is not expected to close it. This is the
fabric-ceiling case the Jungle Cat (2x VU35P, 2x the fabric per die) was
reopened for; see `docs/2026-09-24_jungle-cat-performance-estimate.md`.
