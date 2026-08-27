# Sizing the assembled emit chain: what actually bounds it

**Date:** 2026-08-27
**Part:** `xcvu33p-fsvh2104-2L-e`, OOC, 3.3 ns target clock, Vivado 2023.2.
**DUT:** `gdn_emit_chain` = `gdn_head_emit` -> `rmsnorm_bf` -> `gdn_silu` ->
`gdn_y_emit` plus the sequencer.
**Machines:** workstation and BC-250 in parallel on independent axes. Results
across the two are directly comparable; identical synthesis has been measured
bit-identical to 13 significant figures on this pair.

## The question

Every unit had its own OOC number. Three things were only knowable in the
assembled netlist: what the new per-block weight latch costs, what the chain's
Fmax is when the critical path may run BETWEEN units, and whether four units'
resources simply add across 2048-bit bus boundaries.

## The answer

They do not simply add: `gdn_silu` at the shipped `SILU_LANES=32` dominated
both area and the critical path. Narrowing it to 16 gave **+12.1 MHz, -32 DSP,
-19,131 LUT, -8 BRAM** at once. The chain now closes **300.75 MHz** against B's
299.04 MHz target, and the bound has moved inside `rmsnorm_bf`.

## SILU_LANES, the axis that mattered

`HEADS=24 DIM=128 RMS_LANES=4`. Critical path at 32 lanes was
`si_e_seg_reg -> u_silu/xq_reg`: the gate itself.

| SILU_LANES | SI_BEATS | DSP | LUT | FF | BRAM | Fmax MHz |
|---|---|---|---|---|---|---|
| 8 | 16 | 57 | 23,861 | 13,498 | 11.5 | 295.8 |
| **16** | 8 | **73** | **33,404** | **14,518** | **15.5** | **300.8** |
| 32 | 4 | 105 | 52,535 | 16,478 | 23.5 | 288.7 |
| 64 | 2 | 169 | 91,154 | 20,240 | 39.5 | 266.8 |

32 was simultaneously the most expensive setting and one of only two that miss
the clock target. 8 is cheaper again and was rejected: 295.8 MHz misses
299.04, and a unit that does not close the clock is not a saving.

Cost of the change is in cycles, not area: SI_BEATS 4 -> 8, and S_GATE is
serial with the norm, so +4 cycles per head = 4 x 24 x 48 = **4,608 cycles per
token against a 589,824-cycle sweep, under 0.8%**.

DSP is the number that matters. Whole-die DSP is the binding resource at 90.5%
to 91.9% of 2,880, so 32 DSP recovered is **1.1% of the die**.

## RMS_LANES, where the area sweep gives the wrong answer

At `SILU_LANES=16`:

| RMS_LANES | DSP | LUT | FF | BRAM | Fmax MHz | refused columns |
|---|---|---|---|---|---|---|
| 2 | 61 | 33,651 | 14,252 | 15.5 | 300.75 | **24** |
| **4** | 73 | 33,404 | 14,518 | 15.5 | 300.75 | **0** |
| 6 | 85 | 43,119 | 14,823 | 15.5 | 253.8 | -- |
| 8 | 97 | 37,399 | 15,062 | 15.5 | 194.1 | -- |

2 and 4 close the IDENTICAL frequency and 2 saves a further 12 DSP for 247 more
LUT, so **on synthesis numbers alone, 2 wins.** It is wrong. A narrower norm
takes longer, which pushes the chain's per-head service time past the column
arrival period, and `gdn_recur_pipe` cannot be stalled, so those columns are
DROPPED rather than delayed. Both configurations are bit-exact in simulation;
the only thing that separates them is the refused-column counter.

**In a design whose producer cannot be back-pressured, throughput margin is a
correctness property and it appears in no static report.**

## HEADS: gdn_y_emit's mux stage is free insurance, not load bearing

`gdn_y_emit`'s header justifies giving its HEADS-to-1 exponent lookup its own
pipeline stage on the grounds that a mux in front of a barrel shift is what
held `rmsnorm_rs` at 117.2 MHz. Every measurement to date was at HEADS=24, so
the claim had never been tested against a changing head count.

| HEADS | DSP | LUT | FF | BRAM | Fmax MHz |
|---|---|---|---|---|---|
| 8 | 73 | 33,372 | 14,505 | 11.0 | 300.75187969924815 |
| 16 | 73 | 33,377 | 14,514 | 13.0 | 300.75187969924815 |
| 24 | 73 | 33,404 | 14,518 | 15.5 | 300.75187969924815 |
| 32 | 73 | 33,402 | 14,523 | 16.5 | 300.75187969924815 |

**Fmax is identical to 14 significant figures across a 4x change in HEADS.**
DSP is flat at 73. LUT varies by 32 cells, 0.1%. Only BRAM scales, 11.0 to
16.5, which is expected because y_emit's per-head store scales with heads.

Read honestly: this does NOT prove the mux stage is unnecessary, because the
stage is present in all four builds. It proves the mux is **not the scaling
term** at HEADS <= 32, so the split is cheap insurance rather than a
load-bearing decision, and nobody needs to revisit it when the head count
changes. The header's claim should be softened from "would hold the clock down"
to "was split preemptively; measured flat to HEADS=32".

## What now bounds the chain

Identical in every configuration above, on both machines:

```
  Source:            u_rms/ARG__21/DSP_A_B_DATA_INST/CLK
  Destination:       u_rms/mr_m_reg[60]/D
  Data Path Delay:   3.275 ns  (logic 2.782 ns 84.9%, route 0.493 ns 15.1%)
  slack             -0.025 ns
```

A DSP output into a register inside `rmsnorm_bf`'s mantissa path, **84.9%
logic**, so it is genuine arithmetic depth and not a placement or routing
artifact. That is why Fmax is pinned at exactly 300.75 across every SILU_LANES,
RMS_LANES and HEADS value swept: the bound is inside the norm and independent of
all three.

Margin over B's 299.04 MHz target is **1.7 MHz**. It closes, but thinly. Any
further headroom has to come from splitting that DSP-to-`mr_m` path, not from
resizing anything measured here.

## Functional confirmation at the adopted configuration

```
tb_gdn_emit_chain: PASS -- 6 blocks x 24 heads x 128 bit-exact,
  OVERLAP=true COL_GAP=4 refused-column cycles=0
  SILU_LANES=16 RMS_LANES=4
```

Overlapped blocks, real column arrival rate, `STRICT_PRODUCER` on.

## Cost of the two integration fixes, measured

`gdn_head_emit` re-measured after the done/ack handshake, on the BC-250:

| DIM | DSP | LUT | FF | BRAM | Fmax MHz |
|---|---|---|---|---|---|
| 64 | 0 | 1,262 | 1,307 | 1.0 | 443.3 |
| 128 | 0 | 1,205 | 2,332 | 1.0 | 411.9 |
| 256 | 0 | 3,452 | 4,439 | 1.0 | 363.8 |

Against the pre-handshake figure of 1,204 LUT and 389.4 MHz at DIM=128: **one
LUT more, and 22.5 MHz faster.** Treat the frequency gain as placement variance
rather than a real improvement; the honest claim is that the handshake is free.

## Measured and REJECTED -- do not retry

- **`SILU_LANES=32`.** It was the shipped value and it is dominated on every
  axis by 16. Do not restore it.
- **`SILU_LANES=8`.** Cheapest that still works arithmetically, and it is a
  genuine 9,543 LUT and 16 DSP saving over 16. Rejected on 295.8 MHz, below the
  299.04 MHz target.
- **`RMS_LANES=2`.** Rejected on refused columns, not on synthesis. See above.
- **`RMS_LANES=6` and `8`.** 253.8 and 194.1 MHz. Not close.

## Measurement traps hit

- **A Vivado tcl that derives `rtldir` from `[info script]` silently targets the
  wrong tree when the script is copied elsewhere.** A sweep launched from the
  scratchpad died instantly on `util_pkg.vhd does not exist`, and a `pgrep` for
  it kept matching something else, so it appeared to be running for 50 minutes.
  Run these from the repo.
- **`vivado` is not on PATH by default here.** `nohup vivado ...` fails with
  `No such file or directory` and, if the redirect and the `cd` are in the same
  compound command, the log may not be where you expect. Source
  `/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh` first.
- **Identical Fmax to 14 significant figures across many configurations is a
  signal, not a coincidence.** It means a single path unaffected by every
  generic swept, and finding that path is more informative than any of the
  sweeps that produced it.

## Open, not yet answered

- **The 2048 FF weight latch is still an estimate.** The chain measures 14,518
  FF total at the adopted configuration, but no pre-latch build exists to
  difference against.
- **Nothing here is post-route.** All figures are out-of-context synthesis.
  The 1.7 MHz margin over target is thin enough that place-and-route could
  erase it.
- **The `rmsnorm_bf` DSP-to-`mr_m` path has not been analyzed** beyond knowing
  it is 84.9% logic. Splitting it is the only remaining lever on chain Fmax.
