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

---

## KV_BLOCK CAUSES THE CONGESTION TOO. Prediction registered before the result.

`rtl/attn_mac_array.vhd:224`:

```vhdl
constant LANES : integer := QH_TILE*DIM_TILE;
```

and `attn_block.vhd:898-901` instantiates it as
`QH_TILE => G, DIM_TILE => KV_BLOCK, ACC_N => NBLK`, with
`G = N_QH/N_KVH = 16/4 = 4` (`:396`). The file's own header says the rescale
operand *"makes the lane 2 DSP rather than 1 and is 89% of C's whole DSP
budget"*.

**So `KV_BLOCK` sets `u_arr`'s DSP count directly:**

```
DSPs(u_arr) = 2 x G x KV_BLOCK
  KV_BLOCK = 32  (compose4_top)  =  256
  KV_BLOCK =  4  (llama_top)     =   32      -- 224 fewer, 8x
```

The composed design totals 2,177 DSPs, so `u_arr` is ~12% of them concentrated
in one region. **That is the mechanism behind DSP = 100% in every Level 5
window.**

**`KV_BLOCK` therefore has TWO OPPOSING EFFECTS and I had only seen one:**

| | `NBLK = HEAD_DIM/KV_BLOCK`, C's path depth | `LANES = G x KV_BLOCK`, DSP density |
|---|---|---|
| 32 (composed) | 8 -- shorter tree, **easier timing** | 256 DSP -- **worse congestion** |
| 4 (llama_top) | 64 -- deeper tree, harder timing | 32 DSP -- **much less congestion** |

The composed top is simultaneously EASIER on C's own critical path and HARDER
on the congestion that penalises all four subsystems.

### Registered prediction for the `c4kv4` run (composed top at KV_BLOCK=4)

Written before the result, so the answer only has to be classified.

| quantity | prediction | basis |
|---|---|---|
| `u_arr` DSP | 256 -> **32** | DERIVED, `2 x G x KV_BLOCK` |
| design total DSP | 2,177 -> **~1,953** | DERIVED, minus 224 |
| Level 5 windows owned by `c_attn/u_arr` | shrink or vanish | the 100% DSP row is `u_arr` |
| `b_gdn` / `a_eng` / `d_norm` slack | **improve** | they pay for `u_arr`'s congestion |
| `c_attn`'s own worst path | **get worse** | `NBLK` 8 -> 64, three more tree levels |
| **net composed WNS** | **UNKNOWN, sign not predicted** | two opposing effects |

**I am not predicting the net.** If the congestion relief exceeds C's own
deepening, the composed design improves on -0.041 and KV_BLOCK is a lever
rather than only a gap. If not, the composed number gets worse and the true
distance to 200 MHz is larger than any figure on record. Both are useful; only
one is good news, and saying so in advance is what stops the result being
argued into the shape I would prefer.

---

# CORRECTION 2026-09-05, same day: THE MECHANISM IN THIS DOCUMENT IS REFUTED

**The central claim of this document -- that `c_attn/u_arr`'s DSP density causes
the composed context penalty -- is WITHDRAWN. It was tested and it is wrong.**

The claim rested on a real observation: `u_arr` occupies 65-95% of every Level 5
congestion window at **100% DSP occupancy**. That observation stands. The
inference drawn from it, that relieving the DSP density would relieve the
congestion, does not.

`c4kv4` cut `KV_BLOCK` on `c_attn` from 32 to 4, which by the exact RTL relation
`DSPs(u_arr) = 2 * G * KV_BLOCK` cuts `u_arr`'s DSPs **256 -> 32, an 8x
reduction**, confirmed in the report. It also removed 14,817 LUT from the design
and dropped CLB occupancy from 90.3% to 85.0%.

**Maximum routed congestion level went UP:**

| direction | KV=32 | KV=4 |
|---|---|---|
| South | Level 5 | **Level 6** |
| East | Level 6 | Level 6 |
| North | Level 5 | Level 5 |
| West | Level 5 | Level 5 |

And routed WNS went **-0.422 -> -1.542**, 1.120 ns worse, 184.4 -> 152.9 MHz.
Both routes clean.

**So DSP density was CORRELATED with the congested windows, not causal.**
`u_arr` is where the congestion is; its DSP occupancy is not why.

Full measurement, controls and the classified prediction:
`docs/debugging/2026-09-05_kv-block-4-is-a-cost-not-a-lever.md`.

## What survives

- The congestion is real, it is Level 5 and 6, and `u_arr` sits in it.
- SLR crossing is still ruled out; `xcvu33p` is monolithic, not SSI.
- The composed context penalty is real.

## What does not

- That DSP density explains any of it.
- Any expectation that shrinking `u_arr` improves the composed design. It does
  the opposite, because the critical path moves out of the array and into the
  deeper muxing that a narrower array requires (F8 muxes +113%).

## The lesson, and it is the good version

The mechanism was written down as a **falsifiable prediction before the run**
(`fa92069`), including an explicit refusal to predict the net WNS sign. That is
why one experiment settled it. Had it been asserted rather than registered, the
co-location of `u_arr` with the congested windows would have gone on reading as
an explanation indefinitely, and every subsequent effort aimed at DSP density
would have been aimed at nothing.

**What actually drives the Level 5/6 windows is now OPEN, with no candidate
measured.** That is a worse position than this document claimed to be in, and it
is the true one.
