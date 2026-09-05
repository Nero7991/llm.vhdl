# The composed top's shared 0.885 ns penalty is c_attn/u_arr congestion

**2026-09-05.** `compose4_top`, `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, routed
checkpoint from the `c4nd` run (clean route, 520,701 nets, 0 errors).

## The question

> `gdn_block` alone measures **+0.483 ns (221 MHz)** and inside the composed
> design `b_gdn` measures **-0.402 ns**. That is 0.885 ns of pure context. And
> it is not B's alone: `c_attn` -0.401, `a_eng` -0.338, `d_norm` -0.168 -- four
> independent subsystems within 0.064 ns. What is the shared cause?

## The answer

**Routing congestion at Level 5, and `c_attn/u_arr` owns every congested
window with DSP at 100% inside them.**

```
1. Placer Final Level Congestion Reporting
| Direction | Type   | Lvl | Window                          | LUT | DSP  | Cell Names
| South     | Global |  5  | (CLEL_R_X91Y94,CLEL_R_X107Y125) | 68% | 100% | c_attn/u_arr(65%),a_eng/eng/dut/core(30%)
| North     | Long   |  5  | (CLEL_R_X86Y89,CLEL_R_X102Y120) | 68% | 100% | c_attn/u_arr(69%),a_eng/eng/dut/core(25%)
| South     | Long   |  5  | (CLEL_R_X91Y92,CLEL_R_X107Y123) | 68% | 100% | c_attn/u_arr(67%),a_eng/eng/dut/core(28%)
| East      | Long   |  5  | (CLEL_R_X73Y50,CLEL_R_X88Y81)   | 65% | 100% | c_attn/u_arr(95%)

2. Router Initial Congestion
| South | Global | 5 | ... | 68% | 88% | c_attn/u_arr(85%),a_eng(6%),d_norm/gvr.u_rms(4%)
| South | Global | 5 | ... | 67% | 88% | c_attn/u_arr(86%),a_eng(4%),d_norm/gvr.u_rms(4%)
```

`c_attn/u_arr` -- the attention MAC array -- is **65% to 95% of the cells in
every congested window**, and **DSP occupancy is 100%** in the placer's windows
and 88% in the router's. One block saturates the DSP columns locally; everything
placed near it pays for the routing detours. That is why four independent
subsystems degrade together rather than separately.

## Ruled out

- **SLR crossings.** `report_design_analysis -congestion` section 3:
  *"The current part is not an SSI device"*. `xcvu33p` is monolithic, so there
  are no die crossings to blame. This was worth checking precisely because a
  shared, uniform penalty across four subsystems is the classic signature of an
  SSI part, and here it cannot be.
- **A defect in any one subsystem.** They fail within 0.064 ns of each other,
  and three of the four barely appear in the congested windows at all.

## Why this reframes the work

The composed top's best recorded result is **-0.041 ns (198.4 MHz)** after
high-effort directives plus a post-route `phys_opt` chain -- 0.8% short. The
lever that closed 90% of the original gap was tooling, and the remaining 41 ps
has resisted three further `phys_opt` directives (gains 0.012 / 0.002 / 0.004).

**A congestion diagnosis says why that plateau exists and what is different
about it.** `phys_opt` re-times and replicates; it does not relieve a DSP
column that is 100% occupied. The levers that address THIS are:

- spreading `c_attn/u_arr` (a floorplan `pblock`, or `place_design` congestion
  directives such as `AltSpreadLogic_*`, none of which appear in any recorded
  composed run),
- reducing the array's DSP density so it stops saturating columns locally,
- or accepting 198.4 MHz, which `gen_pcieep.py:360` already notes is inside the
  duty-cycle design point at 79.4% against a nominal 80.0%.

**None of the composed runs on record used a congestion-oriented placer
directive.** Every directive tried -- `ExploreWithRemap`, `ExtraTimingOpt`,
`AggressiveExplore`, `Explore`, `ExtraNetDelay_high`, `NoTimingRelaxation` --
targets timing or net delay, not congestion.

## Measured and REJECTED -- do not retry

- **`place=ExtraNetDelay_high` + `route=NoTimingRelaxation`**: -0.422 routed,
  184.4 MHz, 77 minutes. Worse than the no-directive baseline. Recorded in
  `2026-09-04_composed-top-routed.md` FOLLOW-UP 3.
- **Further `phys_opt` directives**: three tried, gains 0.012 / 0.002 /
  0.004 ns. A plateau, and now explained: phys_opt cannot unsaturate a DSP
  column.

## Open, not yet answered

- **Whether spreading `u_arr` actually recovers the 41 ps.** Not tried. It is
  one `place_design -directive` away and has never been run.
- **What `u_arr`'s DSP count is** and whether the array can be built with
  fewer. Not censused.
- **Whether the congestion is a consequence of the 9B shape** or of this
  particular composed geometry (`LAYERS=8`, `HEAD_DIM=256`), which is NOT the
  9B shape.
