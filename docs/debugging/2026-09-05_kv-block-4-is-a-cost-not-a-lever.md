# Is `KV_BLOCK` a lever for the composed top's timing, or only a gap?

Date: 2026-09-05. Part `xcvu33p-fsvh2104-2L-e`. Both runs this week's tree, same
directives (`ExploreWithRemap` / `ExtraTimingOpt` / `AggressiveExplore` /
`Explore`), same stage, differing ONLY in the `KV_BLOCK` generic on the `c_attn`
instance of `compose4_top`.

## The question, verbatim

`compose4_top` instantiates `attn_block` without passing `KV_BLOCK`, so it gets
the entity default of **32**, while `rtl/llama_top.vhd:479` passes **4**. Both
cite spec clause 2.1.1. Recorded as "gap 3" and worth 0.842 ns routed on C
standalone. The question put to the run:

> Does correcting the composed top to `KV_BLOCK = 4` improve the composed
> design, by relieving the `c_attn/u_arr` congestion that owns 65-95% of every
> Level 5 window, or does C's own deepening dominate?

**The prediction was registered in `fa92069` before the run**, including an
explicit refusal to predict the net sign.

## The answer, up front

**`KV_BLOCK = 4` costs 1.120 ns. It is not a lever, it is a cost, and the
composed top's accidental 32 has been flattering every composed number on
record.**

| | `c4nd` (KV=32) | `c4kv4` (KV=4) | delta |
|---|---|---|---|
| **routed WNS** | **-0.422** | **-1.542** | **-1.120** |
| achieved | **184.4 MHz** | **152.9 MHz** | -31.5 MHz |
| routed WHS | +0.009 | +0.009 | 0 |
| `hbm_aclk` WNS | +0.088 | +0.130 | met both |
| LUT | 263,544 | 248,727 | -14,817 |
| FF | 245,425 | 241,575 | -3,850 |
| CARRY8 | 12,505 | 10,601 | -1,904 |
| F7 mux | 20,212 | 19,532 | -680 |
| **F8 mux** | 3,961 | **8,425** | **+4,464 (+113%)** |
| BRAM | 253.5 | 253.5 | 0 |
| URAM | 0 | 0 | 0 |
| **DSP** | 2,177 | **1,953** | **-224** |
| **CLB sites** | 49,620 (90.3%) | **46,706 (85.0%)** | -2,914 |

Both routes clean. `c4kv4`: `C4_ROUTE_STATUS nets=3264259 errors=0 unrouted=0
partial=0`, 0 lines matching `^ERROR:`.

**If `KV_BLOCK = 4` is the correct spec value, the real distance to 200 MHz is
1.542 ns, the worst composed figure on record**, and every previously quoted
composed number described a configuration the design does not use.

## The procedure

1. Copy `hw/fk33/gen_compose4_top.py` into the scratch tree and add exactly one
   entry, `"KV_BLOCK": "4"`, to the `c_attn` INSTANCES dict. The repo generator
   is left untouched.
2. Diff the generated top against the committed `compose4_top.vhd` and confirm
   it differs by **exactly the line `KV_BLOCK => 4,`**. This is the step that
   makes the rest a controlled experiment rather than two builds.
3. Run the full flow with the prior best directives, identical to `c4nd`.
4. Confirm the route is clean **before** reading any WNS.
5. Read the **routed** number only.

**Step 4 and 5 are not ceremony.** This project has two measured cases of
`phys_opt` over-promising by 0.4-0.6 ns, and this run is a third: `c4kv4`
phys_opt reported **-1.004** and routed **-1.542**, giving back **0.538 ns**.
`c4nd` gave back 0.428. Had either been quoted from phys_opt the gap between
the runs would have read as 1.010 rather than 1.120, and `c4nd` would have read
as *meeting* 200 MHz.

## The controls, and they are what make the deltas attributable

Synthesis-stage hierarchy, both runs:

| instance | `c4nd` | `c4kv4` |
|---|---|---|
| `a_eng` LUT | 92,134 | **92,134** |
| `d_norm` LUT | 5,017 | **5,017** |
| `b_gdn` LUT | 75,099 | 75,096 |
| `c_attn` LUT | 88,576 | **74,196** |
| `u_arr` LUT | 57,927 | **39,905** |
| `u_arr` DSP | 256 | **32** |

`a_eng` and `d_norm` are **identical to the digit**; `b_gdn` differs by 3 LUT,
which is synthesis noise. **Every change is inside `c_attn`.** Without these
three unmoving controls the 14,817 LUT and 1.120 ns would not be attributable to
`KV_BLOCK` at all.

## Classifying the registered prediction

The prediction in `fa92069`, item by item, marked against the measurement:

| predicted | outcome |
|---|---|
| `u_arr` DSP 256 -> 32 | **EXACT.** 32. |
| total DSP 2,177 -> ~1,953 | **EXACT.** 1,953. |
| `c_attn` worsens | **CONFIRMED.** -0.422 -> -1.542, path in `c_attn` both times. |
| congestion windows shrink | **REFUTED.** See below. |
| `b_gdn`/`a_eng`/`d_norm` improve | **NOT MEASURED.** The summary timing report carries only four paths; no per-subsystem slack was captured. Making no claim. |
| net WNS sign | deliberately not predicted; landed on the branch stated in advance as "not good news". |

The refuted item is the valuable one.

### The congestion hypothesis is REFUTED, and it was mine

`docs/debugging/2026-09-05_composed-context-penalty-is-cattn-congestion.md`
argued that `c_attn/u_arr`'s DSP density caused the composed context penalty, on
the evidence that `u_arr` occupied 65-95% of every Level 5 window at **100% DSP
occupancy**. The obvious consequence is that cutting its DSP count 8x should
relieve it.

Maximum routed congestion level per direction:

| direction | `c4nd` (KV=32) | `c4kv4` (KV=4) |
|---|---|---|
| South | Level 5 | **Level 6** |
| East | Level 6 | Level 6 |
| North | Level 5 | Level 5 |
| West | Level 5 | Level 5 |

**DSP in `u_arr` fell 8x, CLB occupancy fell 5.3 points, 14,817 LUT left the
design, and congestion got WORSE.** So DSP density was *correlated* with the
congested windows and is not what *causes* the congestion. The earlier document
observed a real co-location and inferred a mechanism from it; the mechanism is
now measured and it is wrong.

This is the project's recorded "not the buffers" failure in its good form: the
inference was written down as a falsifiable prediction *before* the run, so it
could be falsified in one experiment instead of surviving as a plausible story.

### The critical path moved OUT of the array, which explains everything

| run | worst path source | destination |
|---|---|---|
| `c4nd` | `c_attn/u_arr/p_reg_reg[18][0]/C` | `c_attn/u_arr/er_r_reg/D` |
| `c4kv4` | `c_attn/vhdr_reg[498]/C` | `c_attn/vref_r_reg[22][6]/D` |

At `KV_BLOCK = 32` the critical path is **inside** the MAC array. At 4 it is in
`c_attn`'s own header/reference logic, **outside** the array entirely.

That is the same mechanism the area table shows: `u_arr` gives up 18,022 LUT but
`c_attn` as a whole only gives up 14,380, because **~3,642 LUT and ~2,051 FF
reappear around it and F8 muxes more than double (+113%)**. A narrower array
does the same work in more steps, and the sequencing and muxing that serialises
it becomes the new, longer path. **Shrinking the array did not make the design
faster; it moved the bottleneck into logic that is worse.**

## Measured and REJECTED, do not retry

- **Do not "fix" the composed top to `KV_BLOCK = 4` expecting timing to improve.**
  It costs 1.120 ns routed, measured, with clean routes on both sides.
- **Do not treat `u_arr`'s DSP density as the congestion cause.** Cutting it 8x
  made congestion worse. Whatever drives the Level 5/6 windows, it is not that.
- **Do not read this run's phys_opt -1.004 as a result.** Routed is -1.542, a
  0.538 ns give-back, and this is now the third measured case on this part.
- **Do not scale `u_arr`'s LUT by `KV_BLOCK`.** The DSP relationship
  `2 * G * KV_BLOCK` is exact and delivered exactly -224. Applying the same 8x to
  LUT predicts about -50,000 against a measured **-18,022** in `u_arr` and
  **-14,383** net at synthesis: wrong by 3.4x, in the flattering direction.

## Measurement traps hit

1. **The intermediate route iterations report partially-routed nets.** The log
   contains `Number of Partially Routed Nets = 72237` from an early iteration and
   `= 0` at the end. Grepping for the string without taking the final occurrence
   reads a clean route as a broken one. Use the `C4_ROUTE_STATUS` sentinel the
   run writes, which is single-valued.
2. **The congestion report's "Level" appears in the table header and the table
   of contents**, so a bare `grep -oE 'Level [0-9]+'` over the whole file returns
   the wrong thing. Parse the Level column of data rows and take the max per
   direction.
3. **The summary timing report carries only four paths** (worst setup, worst
   hold, and one per clock), so it cannot answer "did B and D improve". A
   distribution needs `report_timing -max_paths`. The honest entry in the
   prediction table is NOT MEASURED, not a guess in either direction.

## The consequence, and the decision it forces

The tradeoff is now measured on both sides and it is stark:

| | `KV_BLOCK = 32` | `KV_BLOCK = 4` |
|---|---|---|
| composed fmax | **184.4 MHz** | 152.9 MHz |
| CLB occupancy (composed alone) | 90.3% | **85.0%** |
| projected total LUT with shell | 314,543 (71.5%) | **299,726 (68.2%)** |
| projected total DSP | 2,177 (75.6%) | **1,953 (67.8%)** |
| required packing to fit | 5.72 LUT/CLB | **5.45 LUT/CLB** |

**`KV_BLOCK = 4` buys 5.3 points of CLB headroom and costs 31.5 MHz.**

So the spec disagreement between `rtl/attn_block.vhd:223` and
`rtl/llama_top.vhd:479`, both citing clause 2.1.1, is no longer cosmetic
bookkeeping. **It is worth 31.5 MHz and 5.3 points of device occupancy, and
nothing in the repository checks that the two agree.** Which value is correct is
a question about the model, not about the tools, and it is Oren's to answer.

## Open, not yet answered

- **Which `KV_BLOCK` the design should use.** Nothing here establishes that. This
  run establishes only what each costs.
- **What actually drives the Level 5/6 congestion**, now that DSP density is
  refuted. No candidate has been measured.
- Whether B and D improved at `KV_BLOCK = 4`. Not captured; needs
  `report_timing -max_paths` on both checkpoints.
- Whether an intermediate value (8 or 16) sits better on the tradeoff. Two points
  do not establish the shape of a curve, and the recorded LEVERC48 result is that
  fitting a trend to two points produces a confident wrong one.
