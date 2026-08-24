# What actually sets subsystem C's clock: broadcast fanout, or mux depth?

Date: 2026-08-24
Part: `xcvu33p-fsvh2104-2L-e` (the FK33's real low-power grade), Vivado 2023.2,
OOC, **synth -> opt -> place -> phys_opt -> route**, 3.333 ns target (300 MHz)

## The question

The 2026-08-23 single-lane micro-synthesis measured 328.6 MHz for one C lane and
said explicitly that the number was not subsystem C's, because one lane has no
fanout. C's spec assumes a 300 MHz fabric clock. Subsystem A closed at only
276 MHz on this same part and grade at `ROWS_IF=48`, so there was direct evidence
the device does not hand out 300 MHz merely because a datapath is short.

Does C at `MACS = 64` reach 300 MHz, and if not, what stops it?

## The answer

**Two different things stop it, at different scales, and the dominant one was
fixable for free.**

- With the lane as originally written, C at `MACS = 64` routes at **246 MHz** --
  the spec's 300 MHz assumption **fails**.
- The DSP48E2's own input registers were sitting unused (`AREG=0, BREG=0`)
  because the lane drives the multiplier from combinational muxes and registers
  only the product. Those registers exist in the tile whether used or not.
  Registering the operand muxes moves C to **339.6 MHz** at `MACS = 64`, for
  **the same 128 DSP, 5% FEWER LUT, and 4.6% more FF**, at one cycle of latency.
- **So the 300 MHz assumption is safe, but only conditionally**, and the
  condition is a coding requirement that appears nowhere in the spec.

| LANES | baseline Fmax | pipelined Fmax | gain |
|---|---|---|---|
| 1 (routed control) | 313.2 | -- | |
| 4 | 301.4 | **379.4** | +26% |
| 8 | 294.0 | **379.2** | +29% |
| 16 | 280.4 | **375.4** | +34% |
| 32 | 284.2 | **374.7** | +32% |
| 64 (= real `MACS=64`) | **246.2** | **339.6** | **+38%** |

| at LANES=64 | DSP | LUT | FF |
|---|---|---|---|
| baseline | 128 | 20,860 | 46,684 |
| pipelined | 128 | **19,844** | 48,819 |

## The procedure

1. **Routed single-lane control** (`micro_c_lane_sh`, ACC_N=16). Without it the
   sweep is uninterpretable: it separates "PnR is more honest than synthesis"
   from "fanout costs Fmax". It cost 313.2 vs the 328.6 synthesis-only figure,
   so **PnR alone is worth ~5%** and the rest of any drop is real fanout.
2. **`LANES` sweep 4/8/16/32/64** of `micro_c_array`, with the sharing modelled
   rather than assumed global (see below), `ACC_N` held at 16 so `LANES` is the
   only variable. The 64-lane point is simultaneously the controlled point and
   the real `MACS=64` geometry, since 64 x 16 = 1,024 accumulators exactly.
3. **The same sweep on `micro_c_array_p`**, identical in every respect except
   that the lane registers its operand muxes. This is the controlled comparison
   that separates mux depth from broadcast; the `LANES` sweep alone cannot.
4. **DSP census** to confirm `AREG`/`BREG` really landed in the tile.

**Place and route is not optional here and stopping at synthesis would have
inverted the conclusion.** Post-synthesis timing uses estimated interconnect: a
high-fanout net has no more estimated delay than a point-to-point one, because
nothing is placed and there is no distance to be far apart over. The
synthesis-only run of the 4-lane pipelined array reports **448.4 MHz** against
**379.4 MHz** routed. Run the 64-lane array to synthesis only and "broadcast is
free" would have been an artifact of stopping too early.

**The sharing model is the experiment, not a detail.** Wiring every operand to
every lane would manufacture a fanout problem and then discover it. C organises
its MACs as 4 query heads x DIMS dims, so each operand fans out exactly as far
as that geometry says: `q` private (fanout 1), `k`/`v` per dim (fanout 4), `f`
per head (fanout LANES/4), `mode`/`idx` control (fanout LANES). The prediction
going in was that data nets would not bite and control nets would.

## The evidence

The decomposition is what carries the result. `logic` and `net` are the routed
datapath delays of the critical path.

```
baseline (combinational operand muxes)
  1 lane   Fmax 313.2   logic 2.434   net 0.661
  4        Fmax 301.4   logic 2.437   net 0.788
  8        Fmax 294.0   logic 2.413   net 0.864
  16       Fmax 280.4   logic 2.406   net 0.952
  32       Fmax 284.2   logic 2.445   net 0.848
  64       Fmax 246.2   logic 2.376   net 1.759

pipelined (DSP48E2 AREG/BREG used)
  4        Fmax 379.4   logic 0.430   net 1.846
  8        Fmax 379.2   logic 0.292   net 1.996
  16       Fmax 375.4   logic 0.381   net 1.773
  32       Fmax 374.7   logic 0.465   net 1.810
  64       Fmax 339.6   logic 1.620   net 1.168
```

**Baseline logic delay is FLAT at 2.38-2.45 ns across a 64x range of lane
counts.** It does not move. That is the mux-depth floor and it is completely
independent of fanout. Every bit of the baseline's Fmax loss lives in the net
term, 0.661 -> 1.759 ns. The two effects are cleanly separated by this table:
mux depth sets a ~313 MHz ceiling even with no fanout at all, and broadcast
takes another 21% by 64 lanes.

Baseline critical path, identical in form at 1 lane and at 64 -- accumulator,
through the 16:1 read mux and the 3:1 operand mux, into the DSP's A port:

```
1 lane    acc_reg[14][14]/C            ->  prod_reg/DSP_OUTPUT_INST/ALU_OUT[0]
64 lanes  g_lane[58].u/acc_reg[15][12]/C -> g_lane[58].u/prod_reg/DSP_OUTPUT_INST/ALU_OUT[0]
```

The census, before and after. This is the whole fix:

```
baseline    prod0      MULTIPLY  AREG=0  BREG=0  PREG=0
            prod_reg   MULTIPLY  AREG=0  BREG=0  PREG=1
pipelined   prod0      MULTIPLY  AREG=1  BREG=1  PREG=0      (all 4 lanes)
            prod_reg   MULTIPLY  AREG=1  BREG=1  PREG=1
```

Top fanout net at 64 lanes is the control net, as predicted -- and note Vivado
had already replicated it four times and each replica still drives 278 loads:

```
278   mode_reg[1]_rep__3_n_0
```

## Measured and REJECTED - do not retry

**Do NOT quote a synthesis-only Fmax for anything fanout-sensitive.** 448.4 vs
379.4 MHz on the same 4-lane design, and the gap grows with lane count. This is
the single biggest trap in this experiment.

**Do NOT conclude C misses 300 MHz.** The 246 MHz figure is real but it is a
property of one avoidable coding choice, not of the architecture. Reporting it
as C's Fmax would have triggered a needless `MACS` reduction.

**Do NOT expect the fix to cost fabric.** The intuition that a pipeline stage
costs 52 FF per lane (36-bit A + 16-bit B) is wrong: those registers are inside
the DSP tile. Measured LUT went **down** 5% and FF up only 4.6%, and the FF rise
is entirely the `mode2`/`i_r2`/`rd2` control pipeline that had to be added to
keep the write-back aligned, ~33 FF/lane, not the operands.

## Measurement traps hit

**Vivado MERGED the per-lane index registers.** The 4-lane pipelined critical
path runs from `g_lane[0].u/i_r_reg[1]` into **lane 2's** DSP. Every lane's
`i_r` is driven by the same broadcast `idx` and so they were structurally
identical; synthesis collapsed them to one register, which then had to fan out
to every lane. Vivado replicated `mode` (`mode_reg[1]_rep__3`) but merged `i_r`.
The lesson for the real RTL: a per-lane control register is only per-lane if
something makes it distinguishable, otherwise it becomes a broadcast net that
was never designed as one.

**The trend is not monotonic point-to-point.** LANES=32 (284.2) beats LANES=16
(280.4) in the baseline. Placement noise is a few percent; read the trend across
the sweep, never a single pair.

## Open, not yet answered

- **The new limiter at 64 lanes is the DSP-to-DSP cascade, not the broadcast.**
  The pipelined 64-lane critical path is
  `g_lane[38].u/prod0/DSP_A_B_DATA_INST/CLK -> g_lane[38].u/prod_reg[7]/D`,
  i.e. the cascade between the two DSPs that the 36-bit operand split requires.
  Logic jumped to 1.620 ns while net fell to 1.168. **`MREG` is still unused**
  and would break exactly that path, so there is probably another step
  available. Not attempted.
- **`MACS` = 192 and 288 are not measured.** Only 64 is. The corrected blocking
  geometry may force one of those, and the fanout of `f` (per head, fanout
  LANES/4) grows with it. Do not extrapolate 339.6 MHz to 288 lanes.
- **This is C's lane array only.** Softmax/exp, the score reduction tree,
  alignment barrel shifters, Q BRAM striping and control are absent, and any of
  them could become the critical path in the real subsystem.
- The one-cycle latency the fix costs has not been checked against C's schedule.
