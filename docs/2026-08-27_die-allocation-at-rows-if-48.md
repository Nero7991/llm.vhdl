# The die allocation, re-run at the forced `ROWS_IF = 48`

**Date:** 2026-08-27. Branch `fpga`, at `c09a8c8`.
**Part:** `xcvu33p-fsvh2104-2L-e` / `-2LV-e`, SQRL FK33, VCCINT 0.717 V MEASURED.
**Model:** Qwen3.5-9B, N=1 (`rtl/model_cfg_pkg.vhd:64-79`). 27B N=4 checked where it differs.

**Status: ANALYSIS ONLY. No Vivado was run and no RTL was modified.** A
place-and-route job was already in flight with three more queued, so every
figure here is either read out of a committed report, derived arithmetically
from one, or labelled ESTIMATE with its assumption stated.

**Labelling discipline**, following the port-count, residency and budget
documents: **MEASURED** (a tool was run, the file is named), **DERIVED**
(arithmetic shown here from MEASURED or RTL-normative inputs), **ESTIMATE** (a
judgement, assumption stated).

**Why this document exists.** `docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`
showed that `ROWS_IF = 58` is unbuildable, that `NPORT = ROWS_IF x 9/16` is an
exact integer identity, and that `ROWS_IF = 48` is therefore forced. That
returns 330 DSP, 11.5% of the die.
`docs/2026-08-27_budgets-at-the-measured-clock.md` section 7.0c closes with the
sentence this document answers: "**No document in the project has yet re-run
the `ROWS_IF` versus `MACS` allocation at 48**, and A section 15.4c, which owns
that trade, chose 58 by an optimisation whose per-term breakdown is printed
nowhere."

---

## 0. Question 2 answered first: what the 330 returned DSP should be spent on

**Spend 24 of them, on `LANES_V` 8 to 16 in D-vec. Bank the other 306. There is
nothing else on the die that converts DSP into tokens per second, because the
two things that used to convert it have both been closed by constraints that
are not DSP constraints.**

Ranked by tokens per second per DSP, at `ROWS_IF = 48`, 9B N=1, ctx 2048,
236.128 MHz. All rows DERIVED; the arithmetic is in section 2.

| rank | candidate | DSP | tok/s gained | **tok/s per DSP** | verdict |
|---|---|---|---|---|---|
| **1** | **D-vec `LANES_V` 8 -> 16** | **+24** | **+0.53** | **+0.0222** | **TAKE**, subject to one measurement |
| 2 | do nothing, hold 712 DSP spare | 0 | 0 | n/a (infinite margin per DSP) | **TAKE for the remaining 306** |
| 3 | D-vec `LANES_V` 16 -> 32 | +48 | +0.27 | +0.0057 | marginal, do not take yet |
| 4 | C `MACS` 128 -> 256 | +256 | +2.58 | +0.0101 | **ILLEGAL on ports.** 212% port duty, 2 ports per stream, 3 ports exist |
| 5 | B `RECUR_LANES` 32 -> 64 | +128 | **0.00** | **0.0000** | **REJECT.** B is emit-bound, not sweep-bound |
| 6 | B `SILU_LANES` 8 -> 16 | +16 | 0.00 | 0.0000 | REJECT for throughput; it buys 5 cycles of deadline margin, not time |
| 7 | more A rows (`ROWS_IF` > 48) | +330 per 10 rows | n/a | n/a | **ILLEGAL on ports.** The identity has no clock in it |

**The single most important fact in this table is that rows 4 and 7 are the
only two large converters and both are illegal for the same reason.** A spec
section 15.4c chose `ROWS_IF = 58` by minimising `T_A + T_C` over exactly those
two axes, on the argument that "DSP spent on C buys ~10x what DSP spent on A
rows buys". At 9B on one card **neither axis has any legal steps left**:

- **A rows are capped by HBM port width.** `NPORT = ROWS_IF x 9/16` and only 30
  ports exist, so 48 is the largest legal value. No quantity of DSP moves it.
- **C rungs are capped by the GQA group.** `MACS = QH_TILE x DIM_TILE`,
  `QH_TILE` must divide `G`, and at 9B N=1 `G = 4`, so `QH_TILE` is 1, 2 or 4.
  With `DIM_TILE = 32` forced by the 256-bit AXI beat, the ladder is
  {32, 64, 128} and **128 is already the top rung**. The next rung needs
  `DIM_TILE = 64`, which needs two HBM ports per stream, and A has taken 27 of
  30.

**So section 15.4c's optimisation has an empty feasible set at 9B, and the 330
DSP it would have spent on C cannot be spent there.** The allocation does not
change because there is almost nothing legal to change it to. That is a
legitimate outcome and it is this document's main result.

**Holding 306 DSP spare is not a failure to allocate, it is the highest-value
thing available at 75% occupancy.** Three independent records in this repo
document congestion-induced nondeterminism on this device family above roughly
90% (`rtl/rmsnorm.vhd:296`, `rtl/bfp_pack.vhd`'s header, the `attention_ml`
debug history), and C skeleton 3.7 restates it as "DSP fitting is necessary, not
sufficient". At `ROWS_IF = 58` the die was at 90.6% and every one of those
warnings was live. At 48 with nothing respent it is at **75.3%**, and the whole
design has never been placed and routed at any scale. Spending the margin back
down to 90% before a single whole-die build exists would throw away the only
thing the port correction actually bought.

**What the 330 DSP does NOT buy: it does not buy back the 21.6% A regression.**
That regression is a port-width consequence, not a DSP one. A at
`ROWS_IF = 48` is slower than A at 58 because it reads 6,912 bits per core
cycle instead of 8,352, and the missing bits are missing because the ports do
not exist. Adding multipliers to a datapath that is starved of operands changes
nothing. Section 4 quantifies this: of the 13.0% token-rate loss, **at most
1.6 points can be bought back**, all of it from D-vec, and none of it from A.

---

## 1. Question 1: the die budget at `ROWS_IF = 48`

### 1.0 Device totals, MEASURED

Read out of the "Available" column of a real Vivado report rather than from a
datasheet, `sim/ooc_sweep/util_R48_v0.717.rpt`:

| resource | available |
|---|---|
| DSP48E2 | **2,880** |
| CLB LUT | **439,680** |
| CLB Register (FF) | **879,360** |
| Block RAM Tile | **672** |
| URAM | **320** |
| CARRY8 | 54,960 |
| **HBM SAXI ports, usable** | **30** of 32 (`jtag_hbm` and `xdma` hold two) |

Note for anyone quoting the streamer design document: its section 7.1 prices
108 BRAM36 as "16.9% of 640". The device has **672** tiles, so it is 16.1%.
Harmless, but it is the wrong denominator.

### 1.1 DSP

| subsystem | DSP | label | basis |
|---|---|---|---|
| **A**, `matvec_core` at `ROWS_IF = 48` | **1,584** | MEASURED | `sim/ooc_sweep/results.csv:8`, `util_R48_v0.717.rpt` ARITHMETIC table. Exactly `33 x 48` |
| A, HBM weight streamer | 0 | DERIVED | no multipliers in an AR generator or a FIFO |
| **B**, `gdn_block` as instantiated | **253** | DERIVED from MEASURED parts | section 1.5 |
| **C**, `MACS = 128` | **303** | DERIVED | `2 x MACS + 47`, C skeleton 3.2 and 3.3; lane cost 2 DSP MEASURED and place-and-routed at 64 lanes |
| **D**, `LANES_V = 8`, shared | **28** | MEASURED | `docs/debugging/2026-08-25_d-vec-dsp-measured.md:22`; 24 in the lanes plus 4 in the shared rsqrt |
| **E** | **0** | by construction | absent entirely at N=1 |
| **total, 9B N=1** | **2,168** | | **75.3% of 2,880** |
| same with D unshared (52) | 2,192 | | 76.1% |
| **free** | **712** | | **24.7%** |

For the end goal, 27B N=4, same datapath widths, `MACS = 192` (there `G = 6`):
A 1,584 + B 253 + C 431 + D 28 + E 0 = **2,296 = 79.7%**, leaving 584 free.
Both configurations are comfortably under the congestion line that
`ROWS_IF = 58` sat on.

**Cross-check against the published sums, and where they disagree.** Every
published whole-die DSP total for this design is now low, and not only because
of the A row:

| source | A | B | C | D | total | die % |
|---|---|---|---|---|---|---|
| D spec 12 | 1,914 | 434 (as C) | -- | 28 | 2,524 | 87.6% |
| C skeleton 3.5, pre-correction | 1,914 | 226 | 438 | 28 | 2,606 | 90.5% |
| C skeleton 3.5, corrected for A only | 1,584 | 226 | 438 | 28 | 2,276 | 79.0% |
| `gdn-block-top-level.md:65` | 1,914 | 234 | 434 | 28 | 2,610 | 90.6% |
| **this document, 9B, from the RTL** | **1,584** | **253** | **303** | **28** | **2,168** | **75.3%** |
| **this document, 27B N=4, from the RTL** | **1,584** | **253** | **431** | **28** | **2,296** | **79.7%** |

The B column is the disagreement and section 1.5 settles it.

### 1.2 LUT

This is the number that has had no attention and it deserves some.

| subsystem | LUT | label | basis |
|---|---|---|---|
| **A**, `matvec_core` at 48 | **112,712** | MEASURED | `sim/ooc_sweep/results.csv:8`. Synthesis, and the report's own warning says the post-implementation count is typically lower |
| A, HBM weight streamer, 27 lanes | ~7,400 | ESTIMATE | streamer design 7.1, per-lane AR/credit/drain at ~180 plus gray pointers at ~90 |
| **B**, `gdn_block` as instantiated | **79,309** | DERIVED from MEASURED parts | section 1.5 |
| **C** array, 128 lanes | ~41,720 | ESTIMATE | linear in lanes from `micro_c_array_LANES64` at 20,860 LUT post-route, `sim/ooc_micro/pnr_results.csv:6`. See the caveat below |
| **C** aux | ~17,400 | ESTIMATE | C spec 3.8's ~80K total at `MACS = 192` minus `3 x 20,860` for that array |
| **D-vec** at `LANES_V = 8` | 320 | MEASURED | `sim/ooc_micro/util_micro_d_vec_LANES_V8_SHARE1.rpt` |
| **D-ctrl** | ~3,000 | ESTIMATE | no measurement of any kind exists; a sequencer FSM with ~1,100 descriptor steps |
| **shell** (XDMA, HBM IP, smartconnect, `jtag_hbm`) | 8,366 floor, 25,000 likely | MEASURED floor / ESTIMATE | `hw/fk33/fk33_i2cprobe/.../bd_wrapper_utilization_placed.rpt` is a REAL placed VU33P shell, but with 2 HBM ports and no DMA engine |
| **total** | **~286,900** | | **~65% of 439,680** |
| **free** | **~152,800** | | **~35%** |

**LUT is not binding, but it is closer than DSP-first thinking suggested and
its error bars are far wider.** DSP sits at 75.3% with 24.7% free, LUT at ~65%
with ~35% free, so DSP is still the tighter resource on the central estimate.
But every LUT figure above outside A and B is an ESTIMATE, two of them
(C's array extrapolation and the real shell) could each move by 20,000, and the
A figure is a synthesis count that has never survived implementation. **The
honest statement is that DSP is measured and LUT is not, so DSP looks tighter
partly because it is the only one anybody has counted.**

Two specific reasons to distrust the C array row. First, it extrapolates 2x
beyond the largest measured point, and the one time this project extrapolated a
mux structure past its measured range it went non-linear: C spec 2.6 measured
543 LUT per lane at `ACC_N = 32` against a linear prediction of 478, because a
32:1 mux exhausts the F7/F8 chain. Second, C skeleton 3.7 prices the same array
from a different model, `158 + 10.0 x ACC_N` per lane, which gives 128 x 238 =
**30,464**, not 41,720. The two models disagree by 37% and nobody has measured
a 128-lane array. Both are recorded here rather than picking one.

### 1.3 FF

| subsystem | FF | label | basis |
|---|---|---|---|
| **A**, `matvec_core` at 48 | **53,193** | MEASURED | `sim/ooc_sweep/results.csv:8` |
| A, streamer skid buffers and credit | ~19,700 | ESTIMATE | streamer 7.1: 512 FF of skid plus ~220 of AR per lane, x27 |
| **B** | **44,475** | DERIVED from MEASURED parts | section 1.5 |
| **C** array, 128 lanes | ~93,400 | ESTIMATE | linear from `micro_c_array_LANES64` at 46,684 FF |
| **C** aux | ~7,000 | ESTIMATE | no measurement |
| **D** | 576 | MEASURED | `util_micro_d_vec_LANES_V8_SHARE1.rpt` |
| **shell** | 15,031 floor | MEASURED floor | i2cprobe placed shell |
| **total** | **~233,400** | | **~26.5% of 879,360** |

**FF is nowhere near binding and is the one resource with a real safety
margin.** Note that C's accumulator files dominate it: 93,400 of 233,000 is
one subsystem's array, and it is the term that would grow if `MACS` ever moved.

### 1.4 BRAM

| subsystem | BRAM36 tiles | label | basis |
|---|---|---|---|
| **A**, `matvec_core` at 48 | **21.5** | MEASURED | `util_R48_v0.717.rpt` BLOCKRAM table |
| A, 27 dual-clock lane FIFOs, 256 b x 512 | **108** | ESTIMATE | streamer 7.1, 4 tiles per lane. This is the single largest BRAM consumer on the die and it has never been built |
| **B** | **38.0** | DERIVED from MEASURED parts | section 1.5 |
| **C** | ~13 | ESTIMATE | C skeleton 3.7 |
| **D** | 0 | MEASURED | |
| **shell** | 10.5 | MEASURED floor | i2cprobe placed shell |
| **total** | **~191** | | **~28% of 672** |
| **URAM** | **0** | | **0% of 320, entirely unused** |

**BRAM is not binding and URAM is completely untouched.** That matters more
than it looks: the streamer design explicitly rules URAM out for the dual-clock
stage (URAM288E2 has one shared clock and cannot implement an async FIFO), but
it also names the escalation path if `DEPTH` has to grow past 1,024 beats,
which is a shallow LUTRAM async FIFO in front of a deep synchronous URAM FIFO.
**320 URAM blocks, 90 Mb, are sitting idle and they are the reserve that pays
for HBM latency jitter if it turns out to be worse than assumed.** No document
had noticed that this reserve exists.

Note the non-monotonic BRAM column in `sim/ooc_sweep/results.csv`: 28.5 at
`ROWS_IF` 32, 26 at 58, 21.5 at 48. That is the synthesiser choosing between
BRAM, LUTRAM and registers for the same buffers at different widths, not a real
trend, and no BRAM figure from that sweep should be extrapolated.

### 1.5 Subsystem B, assembled from the RTL rather than from any spec

**The method requirement says believe the RTL over the documents, and here they
disagree by up to 51 DSP.** `rtl/gdn_block.vhd` is the only file that says how
many of each unit a B layer contains. It instantiates seven, at these generics
(`rtl/gdn_block.vhd:189-221`): `VAL_HEADS = 32`, `DIM = 128`, `LAYERS = 24`,
`CONV_LANES = 4`, `RECUR_LANES = 32`, `RECUR_SLOTS = 16`, **`L2_LANES = 4`**,
**`SILU_LANES = 8`**, `RMS_LANES = 4`.

| instance | unit and generics | DSP | LUT | FF | BRAM | source |
|---|---|---|---|---|---|---|
| `u_exp` | `gdn_exp_capture`, SEGS 3, K 4 | 0 | 1,090 | 548 | 0 | `sim/gdn_exp_capture.csv`, LAYERS=48 row |
| `u_conv` | `gdn_conv`, LANES 4 | 16 | 3,421 | 1,506 | 0 | `sim/ooc_micro/util_gdn_conv_CH256_LANES4.rpt` |
| `u_silu_conv` | `gdn_silu`, LANES 4 | 8 | 4,818 | 419 | 2.0 | `sim/gdn_silu_sweep.csv` |
| `u_l2` | `l2norm_rs`, N 128, **LANES 4** | **36** | 16,497 | 4,796 | 0 | `sim/ooc_micro/util_l2norm_rs_LANES4.rpt`, `volt_verdicts_0717.csv` |
| `u_scal` | `gdn_scalar`, SP_Q 18 | 7 | 5,585 | 495 | 0 | `sim/b_budget.csv` |
| `u_recur` | `gdn_recur_pipe`, LANES 32, SLOTS 16 | 129 | 24,037 | 23,213 | 24.5 | `sim/ooc_micro/util_gdn_recur_pipe_LANES32_SLOTS16.rpt` |
| `u_emit` | `gdn_emit_chain`, **SILU_LANES 8**, RMS_LANES 4 | **57** | 23,861 | 13,498 | 11.5 | `sim/gdn_emit_chain_silu.csv` |
| **total** | | **253** | **79,309** | **44,475** | **38.0** | |

Every row is MEASURED; the sum is DERIVED. The internal consistency check
passes exactly: `gdn_emit_chain` at `SILU_LANES = 16` measures 73 DSP and
decomposes as `gdn_head_emit` 0 + `rmsnorm_bf` 40 + `gdn_silu` at 16 lanes 32 +
`gdn_y_emit` 1 = 73, and at 8 lanes as 0 + 40 + 16 + 1 = **57**, which is what
the CSV reports. The 2-DSP-per-lane silu law holds across the whole sweep.

**Where the four published B rows went wrong:**

| published | value | what it missed |
|---|---|---|
| C skeleton 3.5 | 226 | the emit chain entirely; prices `rmsnorm_rs` + a single silu |
| `gdn-spec-audit.md:511-525` | 227 | same, plus `l2norm_rs` at `LANES = 2` |
| B spec's own row | 202 | the emit chain and the gate silu |
| `gdn-block-top-level.md:65` | 234 | corrects the silu double-count but keeps `l2norm_rs` at `LANES = 2` |
| **RTL, this document** | **253** | |

**Two independent corrections, and only one of them was known.** The silu
double-count was found today and is worth +32 at `SILU_LANES = 16`, +16 at 8.
The second is new here: **`l2norm_rs` is instantiated at `LANES = 4`, not 2**
(`rtl/gdn_block.vhd:209`, `u_l2` at line 601), which is 36 DSP and not 26, so
every published B row is a further **10 DSP** low. It also costs 7,684 more LUT
than the `LANES = 2` figure those rows carry.

**`SILU_LANES` 16 to 8 is worth exactly what today's measurement said**, and it
is visible in this table: 253 against 269, so -16 DSP, and 79,309 LUT against
88,852, so -9,543 LUT. The RTL header comment at `rtl/gdn_emit_chain.vhd:110`
records the LUT saving as 9,763. The two differ by 220 because they come from
different synthesis runs (`gdn_emit_chain_silu.csv` at the part default versus
`gdn_emit_chain_silu_volt.csv`, which reports 23,910 and 33,673). Both are
right, neither is a discrepancy worth chasing, but quote one source, not both.

**Three caveats on B's LUT, FF and BRAM columns, all of which push the numbers
up rather than down:**

1. **`gdn_conv` was measured at `CH_MAX = 256` and the design needs 4,096.**
   `rtl/gdn_block.vhd:362-363` sets `CH_MAX := VAL_HEADS * DIM = 4096`, and
   `gdn_conv`'s storage bound is `NB = CH_MAX / LANES`, so at LANES 4 that is
   1,024 slots against the measured 64. The DSP count is `4 x LANES` and does
   not move, but the LUT, FF and BRAM columns for that row are measured at
   1/16 of the real width. **UNKNOWN, and it is the largest single gap in
   B's fabric numbers.**
2. **`gdn_exp_capture` is priced at LAYERS = 48**, the 27B value. At 9B it is
   24 and the row should be smaller, so that one is conservative.
3. **`gdn_emit_chain` was measured at HEADS = 24**, the 27B per-card value; 9B
   is 32. DSP, LUT and Fmax are MEASURED flat across HEADS 8/16/24/32
   (`gdn-emit-chain-sizing.md:78-81`), but **BRAM is not**: `gdn_y_emit` reads
   1.0 / 4.0 / 6.5 tiles at HEADS 8 / 24 / 48, so the 11.5 above is roughly
   1 tile low at HEADS = 32.

### 1.6 The resource that is actually binding, and it is not DSP

**HBM SAXI ports. A takes 27 of the 30 usable ports and the rest of the die
wants 7.**

| claimant | ports wanted | source |
|---|---|---|
| A weight streamer, `ROWS_IF = 48` | **27** | identity `48 x 9/16`, `docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md` |
| B, recurrent state and conv history | 4 masters | `docs/2026-08-27_hbm-residency-map.md:165-167` |
| C, KV cache | 2 read + 1 write | same |
| D, activations and descriptors | not yet priced | UNKNOWN |
| **total wanted** | **34+** | |
| **available** | **30** | |

The residency map states this in one sentence and does not resolve it: "B wants
4 masters and C wants 2 reads plus 1 write, and only 3 engine ports remain.
That is a real conflict."

**It is resolvable, and the resolution costs LUT rather than DSP, which is
exactly the resource the correction freed.** The token is a serial chain: D O13
and A spec `:1993` both state that A, B and C are never simultaneously active.
So A's 27 ports are **idle for the whole of B's and C's phases**. Putting a 2:1
AXI4 read mux in front of four of A's lanes, switched by the sequencer's phase,
gives B and C the seven masters they want without a 28th port. The costs are a
few thousand LUT for four 256-bit AXI muxes, one more timing path on the
300 MHz ACLK domain, and a stack-placement constraint (a muxed port can only
reach its own stack's 4 GiB half, so B's state and C's KV stripes must be
placed on the right side).

**This is the one place in the whole allocation where the freed budget has an
obvious use, and it is not a DSP use.** It is also the item that decides
whether `ROWS_IF = 48` is buildable at all; see section 5.

---

## 2. Question 2, worked: every candidate and its arithmetic

Common inputs, all recomputed rather than quoted.

Non-A cycles per token at 9B N=1, ctx 2048, from
`docs/2026-08-27_budgets-at-the-measured-clock.md` section 2.2:

```
B, emit-bound      552,096      (ESTIMATE; measured only at HEADS=24)
C, MACS = 128    1,217,484
D-vec              230,400
D-ctrl              12,275
E                        0      (N=1)
                 ---------
non-A            2,012,255 cycles
```

A at `ROWS_IF = 48`: **5,187,328** cycles. Independently reconstructed here
from `rtl/model_cfg_pkg.vhd`'s shapes with
`cycles = ceil(M/ROWS_IF) x ceil(K/32)` summed over the tensor list, and it
reproduces the published figure **exactly**, along with 15,499,264 at
`ROWS_IF = 16`, 7,749,632 at 32, 4,293,888 at 58 and 3,877,888 at 64. That is a
five-point validation of the model before any new number is taken from it.

One detail the reconstruction pins that no document states: **the published
list fuses the attention `k_proj` and `v_proj` into one 2,048-row job.** Split
into two 1,024-row jobs the total is 5,188,352 rather than 5,187,328, because
`ceil(1024/48) x 2 = 44` against `ceil(2048/48) = 43`. The difference is 0.02%
and invisible at `ROWS_IF = 58` (both give 36), which is why it was never
noticed. It is a real RTL question for D's descriptor list, not an arithmetic
error, and it is recorded rather than resolved.

### 2.1 Rank 1: D-vec `LANES_V` 8 to 16, +24 DSP, +0.53 tok/s

D-vec's cost is exactly linear in `LANES_V` at 3 DSP per lane shared, with zero
intercept, MEASURED at four points
(`docs/debugging/2026-08-25_d-vec-dsp-measured.md:83-90`): 6 / 12 / 24 / 48 DSP
at `LANES_V` 2 / 4 / 8 / 16. With the shared rsqrt the subsystem is 28 at 8 and
**52 at 16, so +24 DSP.**

D-vec's cycle count is element-count over `LANES_V`
(`budgets-at-the-measured-clock.md:236`: 230,400 = `32 x 7,168 + 1,024`, with
the per-block 7,168 being `1024 + 1024 + 1024 + 3072 + 1024` at `LANES_V = 8`),
so doubling the lanes halves it to **115,200**.

```
token at LANES_V = 8   (5,187,328 + 2,012,255) / 236.128e6 = 30.490 ms = 32.80 tok/s
token at LANES_V = 16  (5,187,328 + 1,897,055) / 236.128e6 = 30.002 ms = 33.33 tok/s
gain                                                        +0.533 tok/s for 24 DSP
                                                            = +0.0222 tok/s per DSP
```

**Timing is neutral, MEASURED.** `micro_d_vec` reports the same WNS of
1.084 ns at `LANES_V` 2, 4, 8 and 16 (`d-vec-dsp-measured.md:83-86`), so the
lane replication does not touch the critical path at 0.85 V. **What has not
been measured is the 0.717 V behaviour**, and D-vec's binding path at the real
voltage will almost certainly be the shared Newton rsqrt, exactly as it is in
every other norm unit on this die (verdicts document, finding 4). If so, lane
width is again irrelevant to the clock and the change is free. **That is the
one measurement this recommendation is conditional on**, and it is cheap: one
OOC synthesis of `micro_d_vec` at `LANES_V = 16` with
`set_operating_conditions -voltage {VCCINT 0.717}`.

`LANES_V = 32` is priced in rank 3: +48 more DSP for +0.27 tok/s, 0.0057 per
DSP, a quarter of the return. Not worth taking before there is a whole-die
build to measure against.

### 2.2 Rank 2: spend nothing

At `ROWS_IF = 58` the die was 2,610 of 2,880 DSP, 90.6%, and every congestion
warning in the repo applied. At 48 with nothing respent it is **2,168, 75.3%**,
and at 27B N=4 **2,296, 79.7%**. The design has never been placed and routed at
any scale, no two units have ever been synthesised together, and the one
whole-die risk that is documented repeatedly is congestion, not capacity.

The value of the margin is not hypothetical. Three of today's findings each
consumed part of it after the fact and none was predicted: the silu
double-count cost +32, the `l2norm_rs` lane count costs +10, and the `mr_m2`
register level's area effect is still unmeasured. **A budget that was exactly
full would have been wrong three times today.**

### 2.3 Rank 4: C `MACS` 128 to 256 is worth 2.58 tok/s and is illegal

The arithmetic is worth stating because it is the largest number in the table
and it is the one that will keep being proposed.

At 9B, `G = 4`, so `QH_TILE` in {1, 2, 4}. `MACS = 256` is `QH_TILE = 4` with
`DIM_TILE = 64`. C's KV sweep at `MACS = 128` is 1,048,576 cycles
(9B envelope `:274`); at 256 it halves to 524,288.

```
token at MACS = 128  30.490 ms = 32.80 tok/s
token at MACS = 256  28.270 ms = 35.37 tok/s
gain                 +2.576 tok/s for 512 - 256 = 256 DSP = +0.0101 tok/s per DSP
```

DSP is not the problem: 303 to 559 leaves 456 free. **Ports are.**
`DIM_TILE = 64` needs two 256-bit beats per KV block, therefore two HBM ports
per stream, and the 9B envelope prices its port duty at **212.5%**
(`9b-single-card-resource-envelope.md:490`). C already wants 3 ports at
`MACS = 128` and would want 6. Three exist. Even `MACS = 128` with
`DIM_TILE = 64` (the `QH_TILE = 2` route to the same width) is 106.2%.

**This is the 9B instance of the same rejection the C skeleton records for
`MACS = 384` at 27B, and it fails for the same reason and not the DSP one.**

### 2.4 Rank 5: B `RECUR_LANES` 32 to 64 buys precisely zero, and this is not obvious

`gdn_recur_pipe` at `LANES = 64, SLOTS = 32` MEASURED at 257 DSP, 50,422 LUT,
44,849 FF, 48.5 BRAM (`sim/ooc_micro/util_gdn_recur_pipe_LANES64_SLOTS32.rpt`),
against 129 / 24,037 / 23,213 / 24.5 at `LANES = 32`. So the move costs
**+128 DSP, +26,385 LUT, +21,636 FF, +24 BRAM**, and it does halve the state
sweep: `gdn_sweep_cycles` in `rtl/model_cfg_pkg.vhd:141-149` gives
`(128 x 128 x 32) / lanes x 24 layers` = 393,216 at 32 lanes and 196,608 at 64.

**And B's time does not move at all, because B is emit-bound and not
sweep-bound.** B's row is 552,096 cycles, which is the emit chain's
`24 layers x 32 heads x 718.875 cycles per head`, against a sweep floor of
393,216. The sweep is already 29% faster than the emit chain that consumes its
output. Halving it takes the floor to 196,608 and leaves the binding term
untouched at 552,096.

**It is worse than neutral.** The emit chain's per-head deadline is a function
of the column arrival period, and the arrival period is `DIM / RECUR_LANES`
cycles per column. Doubling `RECUR_LANES` halves the arrival period, which is
the axis the deadline was just measured against: 374 dropped / 375 passing at
`SILU_LANES = 8`, margin +137 cycles, 26.8%. **Halving the arrival period spends
that margin and the RTL header at `rtl/gdn_emit_chain.vhd:81-84` records that
dropped columns are silent, invisible to synthesis and invisible to a value
check.** 128 DSP to buy zero time and lose a measured safety margin.

**What would move B is latency in the emit chain, not width**, and the largest
component of that latency is the Q30 Newton rsqrt, which just got 6 cycles
longer from the `mr_m2` fix. Reducing it is a pipelining and buffering problem,
not a multiplier problem, so it consumes LUT and FF, both of which are free.
**The decomposition of the 718.875 cycles per head is not published anywhere and
is UNKNOWN**; without it the size of this opportunity cannot be stated.

### 2.5 Rank 6: `SILU_LANES` back to 16

+16 DSP, +9,543 LUT, +1,005 FF, +4.0 BRAM, and it buys **5 cycles** of per-head
deadline margin, taking the emit chain from 374 dropped / 375 passing to
369 / 370, so 27.8% margin instead of 26.8%. MEASURED by bisection today. At
0.717 V the two settings measure **the same Fmax to 17 significant figures**,
227.63487366264513 MHz, with the identical critical path at 4.354 ns, so there
is no clock argument on either side.

**It buys no time and should not be taken now, but it is the correct thing to
spend 16 of the banked DSP on if the post-route deadline measurement comes back
worse than the synthesis one.** That is exactly the sort of contingency the
306 spare DSP exist to cover, and it is the concrete example of why banking
beats spending.

### 2.6 One lever that is now clearly not worth taking, and it points the other way

C skeleton 3.6 prices moving the rescale multiplier off the lane: at `R = 48`
it saves **96 DSP for +0.163 ms**, with an unmeasured LUT and timing penalty
from a 32-entry accumulator mux that C spec 2.6 already measured going
non-linear. At `ROWS_IF = 58` and 90.6% occupancy that trade was at least
arguable. At 75.3% it is not: 96 DSP is 3.3% of a die with 24.7% free, and
0.163 ms is 0.5% of the token.

**Recommendation: close C skeleton 3.6 as not worth measuring.** The
`RESCALE_ON_LANE` generic in `rtl/attn_lane_skel.vhd` should still be
synthesised once, because C skeleton calls it "the single highest-value
measurement available on C's budget" and a two-mode lane that does not
reproduce 2 DSP would mean the skeleton is pricing the wrong thing. But the
saving it exists to unlock is no longer wanted.

---

## 3. Question 3: what becomes newly feasible

Each rejection is quoted with what it actually rested on, then re-tested at 48.

| rejected item | what the rejection rested on | status at `ROWS_IF = 48` |
|---|---|---|
| **C `MACS = 384`** (27B) | "815 DSP against 688-712 available ... exceeds the die by itself", **and** 106% port duty | **DSP objection VOID** (815 of 1,018-1,042 fits, die 92.1-93.0%). **Port objection stands and is stronger**: it needs 2 ports per stream, A holds 27 of 30 |
| **C `MACS = 256`** (9B) | 212.5% port duty (9B envelope `:490`) | **unchanged. Never a DSP rejection**, so nothing to void. Section 2.3 |
| **C `MACS = 128` with `DIM_TILE = 64`** (9B) | 106.2% port duty | unchanged, ports |
| **C rescale off-lane, `R = 48`** | not rejected; offered as a 96-DSP saving for +0.13 ms on a 90-92% die | **the reason to want it is void.** Section 2.6 |
| **C QK-norm at `rmsnorm_rs LANES = 4`** | "40 DSP **and only 281.8 MHz** ... a timing failure, not a budget option" | **unchanged, and worse.** At 0.717 V `LANES` 1, 2 and 4 all miss, at 224.57 / 211.46 / 211.46, and the cause is the shared Newton hop, not the lane count. Never a DSP rejection |
| **B `RECUR_LANES = 64`** | B spec 7.1 item 3 records an HBM feed margin argument at 6-7 ports; DSP was never the objection | **feasible on DSP, worthless on time.** Section 2.4 |
| **B `RMS_LANES = 6 or 8`** | 253.8 and 194.1 MHz at 0.85 V (`sim/gdn_emit_chain_sl16.csv`) | **unchanged, clock.** Never DSP |
| **A `ROWS_IF` above 48** | previously bandwidth; now the port width identity | **unchanged and absolute.** No DSP quantity moves it |
| **A row-count DSP packing** (two int4 MACs per DSP48E2) | never proposed | **would work and would buy nothing.** A is starved of operands, not of multipliers. More MACs per cycle needs more weight bits per cycle needs more ports |

**Looking wider, as instructed, the one genuinely new option is not a DSP
option at all.** It is the AXI port mux of section 1.6: the freed budget lets
B and C get their seven HBM masters out of A's 27 idle ports, at a cost of a
few thousand LUT and one extra ACLK-domain path. That was not previously
proposed because at `ROWS_IF = 58` there was nothing to mux (33 ports of 30 is
not a scheduling problem, it is an impossibility) and the die had no LUT or FF
margin to spend on infrastructure.

**And one option that becomes arithmetically interesting and should be
recorded, not taken.** The port identity has one lever in it: `K = floor(f_ACLK
/ f_core)` lanes per port. At `K = 2`, `NPORT = ROWS_IF x 9/32`, so
`ROWS_IF = 64` needs **18 ports** rather than 36, and A drops from 5,187,328 to
**3,877,888** cycles, a 25.2% cut on the term that is 72% of the token. It
costs 2,112 DSP for A, which is +528, and **this is the only place on the die
where a large DSP spend converts into a large time saving.** Feasibility check:

- `f_ACLK >= 2 x f_core`. `hbmbw` closed **300 MHz with 30 masters, WNS +0.101 ns**,
  MEASURED on the card at 0.717 V, so `f_core <= 150 MHz` reaches `K = 2` today.
  **At 150 MHz the whole plan loses**: A at `ROWS_IF = 64` is 25.9 ms and the
  non-A terms inflate to 13.4 ms, for a 39.3 ms token against 30.5. The port
  note already rejected this, and the reconstruction here agrees.
- The version that wins needs **`f_ACLK` at 400 to 450 MHz against a 200 to
  225 MHz core**. The HBM IP is rated to 450 MHz and the device paper figure of
  460.8 GB/s assumes it. At 225 MHz core, A is 17.24 ms and the token is
  **~26.2 ms, ~38.2 tok/s**, which recovers the entire `ROWS_IF = 58` figure
  and then some, on a legal port count. DSP would then be 2,112 + 253 + 303 +
  28 = **2,696, 93.6%**, back over the congestion line, which is what the freed
  budget would be paying for.
- **This is ESTIMATE and it is entirely gated on one unmeasured quantity: does
  the HBM SAXI interface close at 400 to 450 MHz on this design?** The only
  data point is `hbmbw` at 300 MHz with +0.101 ns of slack, which says nothing
  about 2.22 ns. It is listed in section 7 as the highest-value measurement on
  the whole allocation.

---

## 4. Question 4: token time at `ROWS_IF = 48`, at the measured clock

### 4.1 The comparison, recomputed

All figures DERIVED from the cycle counts above at the MEASURED per-configuration
0.717 V clocks in `sim/ooc_sweep/results.csv`.

| | `ROWS_IF = 58` (unbuildable) | **`ROWS_IF = 48` (forced)** |
|---|---|---|
| clock, MEASURED synthesis at 0.717 V | 237.812 MHz (`results.csv:7`) | **236.128 MHz** (`results.csv:8`) |
| A cycles | 4,293,888 | **5,187,328** |
| A, array-limited | 18.056 ms | **21.968 ms** |
| A, HBM floor (clock-invariant) | 15.565 ms | 15.562 ms |
| **A = max** | **18.056 ms** | **21.968 ms** |
| B, emit-bound | 2.322 ms | 2.338 ms |
| C, `MACS = 128` | 5.120 ms | 5.156 ms |
| D-vec | 0.969 ms | 0.976 ms |
| D-ctrl | 0.052 ms | 0.052 ms |
| E | 0 | 0 |
| **token** | **26.517 ms** | **30.490 ms** |
| **tok/s** | **37.71** | **32.80** |
| delta | | **+3.973 ms, +15.0%, -13.0% tok/s** |

**Correction to a figure published today.** The port-count note section 4.5
gives 30.43 ms and 32.9 tok/s, a -12.7% loss. That evaluates A at the
`ROWS_IF = 48` clock but leaves the non-A terms at the `ROWS_IF = 58` clock of
237.812 MHz. There is one die and one core clock, so both terms must be
evaluated at the same one. Recomputed consistently the answer is
**30.490 ms, 32.80 tok/s, -13.03%**. The difference is 0.06 ms and it changes
nothing, but the method matters: the same mixed-clock slip is what produced
several of the figures section 7 of the budgets document had to withdraw.

### 4.2 How much of the loss can be bought back: 1.6 points of 13.0

| | ms | tok/s |
|---|---|---|
| `ROWS_IF = 58`, unbuildable reference | 26.517 | 37.71 |
| **`ROWS_IF = 48`, as allocated today** | **30.490** | **32.80** |
| 48 + D-vec `LANES_V = 16` (+24 DSP) | 30.002 | 33.33 |
| 48 + `LANES_V = 32` (+72 DSP total) | 29.758 | 33.60 |
| 48 + `LANES_V = 16` + C `MACS = 256` (illegal on ports) | 27.782 | 36.00 |

**Of the 4.91 tok/s lost, respending DSP recovers 0.53 legally, or 0.80 if
`LANES_V = 32` is taken as well. That is 11% of the loss for 24 DSP, or 16% for
72.** The remaining 84 to 89% is not purchasable with DSP at any price, because
it is A's row count and A's row count is a port-width quantity.

### 4.3 The clock these numbers are stated at is optimistic, and by how much is unknown

236.128 MHz is `matvec_core` alone, **out of context, at synthesis, with no
placement, no streamer, no 6,912-bit merge and no HBM IP in the same device.**
Nothing else on the die has been measured clearing it. The full 0.717 V picture:

| unit | Fmax at 0.717 V | kind |
|---|---|---|
| `matvec_core` `ROWS_IF = 48` | 236.128 | synthesis |
| `matvec_core` `ROWS_IF = 58` | 237.812 | synthesis |
| `gdn_emit_chain`, after today's three fixes | **232.16** | **POST-ROUTE** |
| `gdn_emit_chain`, `SILU_LANES` 8 / 16 / 32 | 227.635 | synthesis, pre-fix |
| `l2norm_rs` N=128 `LANES = 4` | 214.179 | synthesis, pre-`mr_m2` |
| `rmsnorm_rs` N=256 `LANES = 2` and `4` | 211.461 | synthesis, pre-`mr_m2` |
| `micro_rmsn_lanes` `LANES = 4` | 200.803 | synthesis, pre-`mr_m2` |

The token at three of those clocks, DERIVED:

| clock | token | tok/s |
|---|---|---|
| 236.128, A's own synthesis figure | 30.490 ms | 32.80 |
| 232.16, B's post-route figure | 31.011 ms | 32.25 |
| 211.46, the lowest measured non-fixed unit | 34.047 ms | 29.37 |

**Do not scale any of these against each other with a derate.** The derate is
MEASURED at 16.5% to 28.0% across unit classes and 16.5% to 24.4% within
`matvec_core` alone, against a measurement spread of exactly zero, because at
0.717 V a single shared structure binds every unit and the ratio is really the
logic/route mix of whatever unrelated path bound it at 0.85 V.

---

## 5. Question 5: is 48 optimal among {16, 32, 48}?

**Yes, decisively, on time. And it is the only one of the three that is at risk
of being unbuildable, for a reason that has nothing to do with DSP.**

### 5.1 On time, the three legal points are not close

DERIVED, at each configuration's own MEASURED 0.717 V clock, with all non-A
terms held:

| `ROWS_IF` | ports | A DSP | A cycles | clock | A ms | token ms | **tok/s** | free DSP | free ports |
|---|---|---|---|---|---|---|---|---|---|
| 16 | 9 | 528 | 15,499,264 | 236.295 (est) | 65.593 | 74.109 | **13.49** | 1,768 | 21 |
| 32 | 18 | 1,056 | 7,749,632 | 236.295 | 32.796 | 41.312 | **24.21** | 1,240 | 12 |
| **48** | **27** | **1,584** | **5,187,328** | **236.128** | **21.968** | **30.490** | **32.80** | **712** | **3** |

The `ROWS_IF = 16` clock is ESTIMATE: 8, 32, 40 and 48 all measure 236.1 to
240.6 MHz at 0.717 V, so 16 is taken at 236.295. It does not matter; 16 is
2.4x slower than 48 and no clock assumption rescues it.

### 5.2 The smaller-A hypothesis, tested rather than assumed

The question is fair: a smaller A frees both DSP and ports, and ports are the
binding resource. Does the freed capacity buy back more than A loses?

**Test it at its strongest.** `ROWS_IF = 32` frees 528 DSP and 12 ports, which
is enough for **every** blocked item at once: C to `MACS = 256` at
`DIM_TILE = 64` (needs 6 ports, 512 DSP array), D-vec to `LANES_V = 16`, B its
4 masters, C its write port, and 2 ports still spare.

```
A at ROWS_IF = 32                                  7,749,632 cycles
B emit-bound                                         552,096
C at MACS = 256 (sweep halved)                       693,196
D-vec at LANES_V = 16                                115,200
D-ctrl                                                12,275
                                                   ---------
                                                   9,122,399 cycles / 236.295e6
                                                   = 38.606 ms = 25.90 tok/s
```

DSP: 1,056 + 253 + 559 + 52 = 1,920, **66.7% of the die**, with 960 free.

**Against `ROWS_IF = 48` with nothing spent at all, 30.490 ms and 32.80 tok/s.**
The maximally respent `ROWS_IF = 32` configuration is **26.6% slower** than the
unmodified `ROWS_IF = 48` one, while using 4 times as much of the freed budget.

**The reason is structural and it generalises: A is 72.0% of the token at
`ROWS_IF = 48`, and everything the freed capacity can buy lives in the other
28%.** Halving A's row count adds 10.83 ms to a term you cannot compensate,
against a maximum available saving of 2.71 ms in the terms you can. There is no
allocation of DSP that wins that trade, and there is no smaller `ROWS_IF` for
which the arithmetic changes sign. **48 is not merely the maximum; it is the
argmax, and the margin is 6.9 tok/s.**

### 5.3 The condition under which 48 fails, and it is not a DSP condition

`ROWS_IF = 48` leaves **3 HBM ports** for a die that wants **7 or more**
(section 1.6). If that cannot be resolved, `ROWS_IF = 48` is unbuildable for the
same class of reason `ROWS_IF = 58` is, and the fallback is `ROWS_IF = 32` at
18 ports, 12 spare, and **24.21 tok/s against 32.80**, a 26% throughput cliff.

**So the phase-multiplexed AXI mux of section 1.6 is not an optimisation. It is
the thing that decides whether the recommended configuration exists.** It rests
on one normative claim, that A, B and C are never simultaneously active
(D O13, A spec `:1993`), which is stated in two specs and has never been
verified against a schedule. **Verifying it is a higher priority than any
resource question in this document**, and it is a simulation question, not a
Vivado one.

If the claim fails, the ordered fallbacks are: give B fewer than 4 masters
(its state traffic is 26.4 MiB total and it is not bandwidth-bound); place B's
state and C's KV so they share ports across stacks; and only then drop to
`ROWS_IF = 32`.

---

## 6. Where the RTL disagrees with the documents

Recorded as findings, per the method requirement.

1. **`l2norm_rs` is instantiated at `LANES = 4`, not 2.**
   `rtl/gdn_block.vhd:209` sets `L2_LANES := 4` and `:601-604` passes it. That
   is **36 DSP** (MEASURED, `volt_verdicts_0717.csv`), not the 26 that the C
   skeleton's 226, the GDN audit's 227 and `gdn-block-top-level.md`'s 234 all
   carry. Every published B row is 10 DSP and 7,684 LUT low for this reason
   alone, on top of the silu double-count.
2. **B's honest DSP row is 253, not 202, 226, 227, 234 or 251.** Assembled in
   section 1.5 from the seven units `rtl/gdn_block.vhd` actually instantiates,
   at the generics it actually passes, using only MEASURED per-unit figures.
   The internal check that `gdn_emit_chain` decomposes to `0 + 40 + 2 x
   SILU_LANES + 1` holds exactly at both 8 and 16 lanes.
3. **`gdn_conv`'s `CH_MAX` is 4,096 in the design and 256 in every
   measurement.** `rtl/gdn_block.vhd:362-363` computes
   `CH_MAX := VAL_HEADS * DIM`. `gdn_conv.vhd:103` makes the storage bound
   `NB = CH_MAX / LANES`, so the committed measurement covers 1/16 of the real
   width. DSP is unaffected; LUT, FF and BRAM are unquantified.
4. **The published A tensor list fuses attention `k_proj` and `v_proj`.**
   Reconstructing the cycle model from `rtl/model_cfg_pkg.vhd` reproduces the
   published totals at `ROWS_IF` 16, 32, 48, 58 and 64 only if k and v are one
   2,048-row job. Split, the `ROWS_IF = 48` total is 5,188,352 rather than
   5,187,328. Invisible at 58, 0.02% at 48, and it is a real question for D's
   descriptor list.
5. **`SILU_LANES = 8` is already the RTL default in both files**
   (`gdn_emit_chain.vhd:125`, `gdn_block.vhd:216`), and `gdn_block.vhd:210-211`
   still carries the superseded comment "16, not 32 and not 8" immediately
   above the corrected one. Cosmetic, but it is the exact shape of stale
   comment that this project has been bitten by.
6. **The LUT saving from `SILU_LANES` 16 to 8 is 9,543 or 9,763 depending on
   which run is quoted**, from `gdn_emit_chain_silu.csv` and
   `gdn_emit_chain_silu_volt.csv` respectively. `rtl/gdn_emit_chain.vhd:110`
   quotes the second. Both are real synthesis runs of the same design.

---

## 7. What is UNKNOWN, and what must be measured before this allocation is committed to

Ordered by how much of the allocation each one can overturn.

| # | question | what it decides | instrument | cost |
|---|---|---|---|---|
| 1 | **Are A, B and C genuinely never simultaneously active?** | whether A's 27 ports can be phase-multiplexed, therefore whether `ROWS_IF = 48` is buildable at all, therefore 32.80 versus 24.21 tok/s | simulation of D's schedule; no Vivado | low |
| 2 | **Does the HBM SAXI interface close at 400 to 450 MHz?** | whether `K = 2` is reachable, therefore whether `ROWS_IF = 64` at 18 ports exists. This is the only lever that converts a large DSP spend into a large time saving | rebuild `hbmbw` at 400 and 450 MHz ACLK | one build, on the card |
| 3 | **Does `ROWS_IF = 48` survive place and route at 27 lanes with the streamer and the 6,912-bit merge?** | every clock figure in section 4 | the whole-die build; queued | days |
| 4 | **What is `gdn_emit_chain`'s post-route Fmax and per-head deadline at `SILU_LANES = 8`?** | whether the 16 DSP saved must be given back. The RTL header notes that per-lane replication in `gdn_silu` already moved a post-route path by 2.3 ns that synthesis did not predict | one place-and-route of the emit chain | hours |
| 5 | **What does `mr_m2` do to Fmax at 0.717 V?** | whether 211.46 MHz is still the die floor. Every norm figure in section 4.3 is pre-`mr_m2` | one OOC synthesis pair per norm unit | minutes |
| 6 | **`micro_d_vec` at `LANES_V = 16`, at 0.717 V** | whether rank 1, the only recommendation in this document, is free | one OOC synthesis | minutes |
| 7 | **A 128-lane C array's real LUT and FF** | whether LUT is closer to binding than section 1.2 says. The two available models disagree by 37% | one OOC synthesis of `micro_c_array` at LANES 128 | minutes |
| 8 | **`gdn_conv` at `CH_MAX = 4096`** | B's real LUT, FF and BRAM | one OOC synthesis | minutes |
| 9 | **The real FK33 shell with XDMA and 27 HBM masters** | the 25,000-LUT estimate in section 1.2, and the 108-BRAM streamer estimate | comes free with item 3 | -- |
| 10 | **B's 718.875 cycles per head, decomposed** | the size of the only remaining opportunity in B | simulation | low |
| 11 | **D-ctrl's fabric cost** | ~3,000 LUT is a pure guess with no measurement behind it of any kind | OOC synthesis once D exists | -- |
| 12 | **D's HBM port requirement** | the port budget in section 1.6 is incomplete without it | D spec work | -- |

**What this document does NOT claim.** Every LUT, FF and BRAM total in
section 1 outside subsystems A and B is built on at least one ESTIMATE, and two
of them (the C array and the shell) could each move by 20,000 LUT. The DSP
column is the only one where every row is MEASURED or derived directly from a
measurement, and the fact that DSP looks like the binding resource is partly an
artefact of it being the only resource anybody has counted. Items 7, 8, 9 and
11 above would settle that, and they are cheap.

---

## 8. Corrections

None yet. Append here with a date; mark superseded claims withdrawn in place
rather than deleting them.
