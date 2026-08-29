# Does subsystem A fit on the xcvu33p at the FK33 geometry, and at what clock?

**Date:** 2026-08-28. Branch `fpga`, synthesised at `61d010d` in a detached
`git worktree` so that three tracks editing `rtl/` concurrently could not
contaminate the netlist.
**Tool:** Vivado 2023.2, `synth_design -mode out_of_context`, `-mode batch`.
**Part:** `xcvu33p-fsvh2104-2L-e`. Reports read back
`xcvu33p-fsvh2104-2LV-e`, speed file `-2LV`, because
`set_operating_conditions -voltage {VCCINT 0.717}` switches the speed file;
that is the same 0.717 V analysis `sim/ooc_core_sweep.tcl` already uses and
the reason is `docs/debugging/2026-08-24_fk33-sysmon-vccint-undervolt.md`.
**Geometry:** `ROWS_IF=48`, `AXI_DW=256`, `NPORTS_W=24`, `NPORTS_S=3`,
`BLK=32`, `ADDR_W=40`, `MAXB=16`, `MAXOUT=16`, `FIFO_DEPTH=512`,
`MAXCOLS=MAXROWS_BFP=17408`, `DUAL_CLK=true`.

**No hardware was touched.** No `xsdb`, no `hw_server`, no programming, no
bitstream, no block design, no `place_design` or `route_design`. Out-of-context
synthesis only. No RTL was modified.

Labels: **MEASURED** (a named tool produced the number), **DERIVED**
(arithmetic on measured inputs, shown), **ESTIMATE** (a judgement).

---

## 1. The question

Four separate subsystem-A tracks on 2026-08-28 each ended their report with
"no synthesis, no timing, resource numbers are estimates". The specific claims
left standing on estimate were:

1. a 6,144-bit `w_data` merge net into `matvec_core`;
2. 27 (or 28) masters' worth of AR logic;
3. `MAXOUT` 2 -> 16 costing "~3 FF per port x 27 ports"
   (`rtl/axi_rd_port.vhd:85-87`);
4. `DEPTH=512` beats at 256 bits being 8 KB per port, x27 = 216 KB, "which is
   a BRAM question" (`docs/2026-08-28_can-27-read-masters-be-served.md:341`);
5. the target clock, where the entire HBM supply figure of **259.2 GB/s** rests
   on **300 MHz** fabric ACLK, and that 300 MHz rests on a 30-port `hbm_tg`
   build closing at WNS +0.101 ns **with no engine in it**
   (`docs/2026-08-28_can-27-read-masters-be-served.md:283-286`, which flags
   this itself).

## 2. The answer

**Subsystem A FITS on the part with room to spare. It does NOT close at either
target clock, and the failure is not marginal.**

| | target | MEASURED (OOC, 0.717 V) | shortfall |
|---|---|---|---|
| HBM fabric ACLK | 300.0 MHz | **189.50 MHz** | **-36.8%** |
| engine core clock | 236.128 MHz | **221.83 MHz** | -6.1% |
| core clock, `matvec_int4_desc_axi` as committed | 236.128 MHz | **133.94 MHz** | -43.3% |

Area is not the problem at all. `matvec_int4_desc_axi`, the whole of subsystem
A including the descriptor control plane and 28 AXI read masters, is 31.65% of
the part's LUTs, 7.31% of its registers, 28.6% of its BRAM and 55.0% of its
DSP.

**Three findings, in order of how much they cost:**

- **F1. The dual-clock AR throttle is the critical path and it is 1.947 ns
  over at 300 MHz.** It is not the 6,144-bit merge net, it is not the master
  count, and it is not `MAXOUT`. It is one combinational chain inside a single
  `axi_rd_port`, present identically in all 27 copies. **Consequence: the
  259.2 GB/s supply figure becomes 163.7 GB/s and A's demand no longer fits
  inside it.** Section 6.
- **F2. `matvec_int4_desc_axi` has an unconstrained combinational path from the
  descriptor word register through a 32-bit divide-by-48 into the core**, which
  drags the core clock to 133.94 MHz. It is a configuration-time path that STA
  has no reason to know is configuration-time. Section 5.3.
- **F3. Two of the four recorded area estimates were wrong, in opposite
  directions, by about 2x each.** LUT was underestimated 2.04x; FF was
  overestimated 2.32x. BRAM and DSP were exactly right. Section 4.

---

## 3. The procedure

Established pattern followed: `sim/ooc_core_sweep.tcl`, which is the OOC script
this project already runs routinely, and specifically its three rules, each of
which exists because an earlier version of that script got it wrong:

- **constrain before `synth_design`, not after.** `sim/ooc_matvec_int4.tcl`
  creates the clock afterwards and therefore reports timing against a design
  that was optimised unconstrained. Here the period is the question.
- **parse `report_utilization`, never `get_cells -filter PRIMITIVE_TYPE`**,
  which is not reliably set on an unplaced netlist. Note the `\*?` in the LUT
  regex: OOC synthesis emits `CLB LUTs*` with a trailing asterisk and the
  un-asterisked pattern silently matches nothing.
- **apply the voltage derate after synthesis**, so the number is the pure
  derate of one netlist rather than two differently-optimised ones.

New script: **`sim/ooc_fk33_a.tcl`**. One unit per invocation, smallest first,
each reported before the next was started:

```
vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs async_fifo   depth=256
vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs async_fifo   depth=512
vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs axi_rd_port  dual=1
vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs axi_rd_port  dual=0
vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs axi_rd_port  dual=1 volt=-1
vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs axi_rd_port  dual=1 maxout=2
vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs axi_rd_port  dual=0 maxout=2
vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs axi_rd_port  dual=1 aperiod=5.3
vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs matvec_int4  dual=1
vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs matvec_int4_desc_axi dual=1
```

What each one isolates:

| run | isolates |
|---|---|
| `async_fifo` at 256 and 512 | the CDC FIFO alone, and whether `DEPTH` moves BRAM at all |
| `axi_rd_port dual=1` vs `dual=0` | the cost and the timing penalty of the CDC, against the same FSM |
| `dual=1 volt=-1` | how much of the timing miss is the 0.717 V undervolt rather than logic depth |
| `maxout=2` at both `dual` | the `MAXOUT` 2 -> 16 claim, with the rest of the design held fixed |
| `aperiod=5.3` | **control for the Fmax extrapolation itself** -- see section 7 |
| `matvec_int4` | 27 masters plus the merge plus the DSP array, in one netlist |
| `matvec_int4_desc_axi` | the 28th master and the descriptor control plane |

Two clocks are created in every run (`coreclk`, `axiclk`) and declared
`set_clock_groups -asynchronous`. Without that group, synth_design times every
CDC path as a real cross-clock path and reports a WNS belonging to a design
nobody built.

---

## 4. The evidence

### 4.1 Per-unit, MEASURED

Vivado 2023.2 `synth_design -mode out_of_context`, `xcvu33p-fsvh2104-2L-e`,
VCCINT 0.717 V, `coreclk` 3.300 ns, `axiclk` 3.333 ns. Raw CSV:
`sim/ooc_fk33a/results.csv`.

| unit | LUT | LUTRAM | FF | DSP | BRAM36 | URAM | core WNS | core Fmax | AXI WNS | AXI Fmax |
|---|---|---|---|---|---|---|---|---|---|---|
| `async_fifo` W=256 DEPTH=256 | 212 | 148 | 80 | 0 | 4 | 0 | +0.733 | 389.6 | +1.484 | 540.8 |
| `async_fifo` W=256 DEPTH=512 | 218 | 148 | 88 | 0 | 4 | 0 | +0.890 | 414.9 | +1.484 | 540.8 |
| `axi_rd_port` DUAL=0 MAXOUT=2 | 526 | 148 | 222 | 0 | 4 | 0 | **-0.006** | 302.5 | n/a | n/a |
| `axi_rd_port` DUAL=0 MAXOUT=16 | 528 | 148 | 225 | 0 | 4 | 0 | **+0.078** | 310.4 | n/a | n/a |
| `axi_rd_port` DUAL=1 MAXOUT=2 | 549 | 148 | 284 | 0 | 4 | 0 | +1.451 | 540.8 | **-1.642** | 201.0 |
| `axi_rd_port` DUAL=1 MAXOUT=16 | 550 | 148 | 287 | 0 | 4 | 0 | +1.451 | 540.8 | **-1.947** | **189.4** |
| `axi_rd_port` DUAL=1 MAXOUT=16, 0.85 V | 550 | 148 | 287 | 0 | 4 | 0 | +1.942 | 736.4 | -0.773 | 243.6 |
| **`matvec_int4`** 27 masters | **136,674** | 5,090 | **61,263** | **1,584** | **145.5** | 0 | **-1.208** | **221.8** | **-1.944** | **189.5** |
| **`matvec_int4_desc_axi`** 28 masters | **139,141** | 5,238 | **64,265** | **1,585** | **192.5** | 0 | **-4.166** | **133.9** | -1.917 | 190.5 |

`matvec_int4` was synthesised twice and produced identical numbers in every
column, so the flow is deterministic on this machine.

### 4.2 `matvec_int4` hierarchy, MEASURED

`report_utilization -hierarchical`, so the streamer can be priced separately
from the array it feeds:

| instance | module | LUT | LUTRAM | SRL | FF | RAMB36 | DSP |
|---|---|---|---|---|---|---|---|
| `matvec_int4` | (top) | 136,674 | 4,292 | 798 | 61,263 | 145 | 1,584 |
| `core` | `matvec_core` | 121,582 | 296 | 798 | 52,789 | 21 | 1,584 |
| **`streamer`** | **`weight_streamer`** | **15,076** | 3,996 | 0 | **8,474** | **108** | **0** |
| `actmem` | `act_mem_striped` | 16 | 0 | 0 | 0 | 16 | 0 |

Per `axi_rd_port` inside the streamer, all 27 within 1% of each other:
554 / 552 / 601 LUT for the three scale ports, 549-554 for the weight ports;
285-287 FF; 4 RAMB36 each. The split inside one port is
`g_dc.fifo` (`async_fifo`) 219 LUT / 88 FF / 4 RAMB36 and
`g_dc.fsm` (`axi_rd_fsm`) 334 LUT / 191 FF / 0 RAMB36.

### 4.3 `matvec_int4_desc_axi` hierarchy, MEASURED

| instance | module | LUT | FF | RAMB36 | DSP |
|---|---|---|---|---|---|
| `matvec_int4_desc_axi` | (top) | 139,141 | 64,265 | 192 | 1,585 |
| `(matvec_int4_desc_axi)` | wrapper's own logic | 272 | 2,730 | **43** | 1 |
| `dfetch` | `axi_rd_port` (28th master) | 528 | 229 | 4 | 0 |
| `dut` | `matvec_int4` | 138,341 | 61,306 | 145 | 1,584 |

The wrapper's own **43 RAMB36** is the result-capture array
`rtl/matvec_int4_desc_axi.vhd:361`,
`array(0 to TILES-1) of std_logic_vector(ROWS_IF*64-1 downto 0)`, with
`TILES = ceil(MAXROWS_BFP/ROWS_IF) = ceil(17408/48) = 363`, i.e.
363 x 48 x 64 = 1,115,136 bits. DERIVED: it scales linearly with
`MAXROWS_BFP` and is the one BRAM number in this whole exercise that a build
parameter can move.

### 4.4 Whole-part occupancy, MEASURED

`matvec_int4_desc_axi`, the largest configuration measured:

| resource | used | available | % |
|---|---|---|---|
| CLB LUTs | 139,141 | 439,680 | 31.65 |
| CLB Registers | 64,265 | 879,360 | 7.31 |
| CARRY8 | 6,856 | 54,960 | 12.47 |
| Block RAM Tile | 192.5 | 672 | 28.65 |
| DSP | 1,585 | 2,880 | 55.03 |
| URAM | 0 | 320 | 0.00 |

---

## 5. The critical paths, verbatim

### 5.1 `axi_rd_port` DUAL_CLK=1, axiclk, WNS -1.947 ns

```
Source:      g_dc.fifo/rp_g_s2_reg[4]/C     (axiclk, period 3.333ns)
Destination: g_dc.fsm/this_len_reg[0]/R     (axiclk)
Data Path Delay: 5.115ns (logic 2.294ns 44.8% / route 2.821ns 55.2%)
Logic Levels: 16  (CARRY8=6 LUT1=1 LUT2=1 LUT5=2 LUT6=6)
```

Identical path, same endpoints, inside `matvec_int4` at 5.112 ns:

```
Source:      streamer/gen_w[0].port_p/g_dc.fifo/rp_g_s2_reg[4]/C
Destination: streamer/gen_w[0].port_p/g_dc.fsm/this_len_reg[0]/R
Logic Levels: 16  (CARRY8=6 LUT1=1 LUT2=1 LUT5=2 LUT6=6)
```

DERIVED from the RTL, by reading the endpoints: this is the AR free-space
throttle, and it is one unbroken combinational chain from the synchronised
gray read pointer to the burst-length register.

```
rtl/async_fifo.vhd:150   rp_bin_w <= gray2bin(rp_g_s2);
rtl/async_fifo.vhd:151   used_w   <= wp - rp_bin_w;
rtl/async_fifo.vhd:152   w_level  <= to_integer(used_w) + OUT_MARGIN;
rtl/axi_rd_fsm.vhd:181   if f_level + pr + want <= DEPTH then
rtl/axi_rd_fsm.vhd:182     this_len <= want;
```

Six CARRY8 is the giveaway: `f_level` (`rtl/axi_rd_fsm.vhd:59`) and `promised`
(`:74`) are **unconstrained `integer`s**, so the compare against `DEPTH` is
built 32 bits wide for values that never exceed 512+16.

The single-clock version of the same FSM, MEASURED, is 11 levels and 3.095 ns:

```
Source:      g_sc.fsm/ar_left_reg[0]/C      (coreclk, period 3.300ns)
Destination: g_sc.fsm/this_len_reg[0]/CE
Logic Levels: 11  (CARRY8=6 LUT1=1 LUT2=1 LUT5=1 LUT6=2)
```

**So the CDC costs 5 logic levels and 2.02 ns**: `stream_fifo` publishes its
level from a registered counter (`rtl/stream_fifo.vhd:67`), whereas
`async_fifo` publishes it through a gray decode and a subtract, in the same
cycle, into a comparator that was already the critical path.

### 5.2 `matvec_int4`, coreclk, WNS -1.208 ns

```
Source:      streamer/gen_w[10].port_p/g_dc.run_s2_reg/C
Destination: core/tr_reg[0][0]/DSP_A_B_DATA_INST/CEA2
Data Path Delay: 4.194ns (logic 0.709ns 16.9% / route 3.485ns 83.1%)
Logic Levels: 6  (LUT3=2 LUT6=4)
```

**83% route.** This is the merge fanout the estimate worried about, and it is
a routing problem, not a logic-depth one -- which also means it is the number
in this document that an OOC run predicts *least* well, in either direction.
`matvec_core` alone at the same geometry and voltage measured **-0.935 ns /
236.128 MHz** (`sim/ooc_sweep/results.csv:8`), so attaching the streamer costs
0.273 ns and 14.3 MHz.

### 5.3 `matvec_int4_desc_axi`, coreclk, WNS -4.166 ns

```
Source:      dw_reg[1][1]/C                 (coreclk, the descriptor word array)
Destination: dut/core/tiles_r_reg[25]/D
Data Path Delay: 7.463ns (logic 3.651ns 48.9% / route 3.812ns 51.1%)
Logic Levels: 30  (CARRY8=18 LUT1=2 LUT2=1 LUT3=3 LUT4=1 LUT5=3 LUT6=2)
```

`rtl/matvec_core.vhd:858`:

```vhdl
tiles_r <= (n_rows + ROWS_IF - 1) / ROWS_IF;
```

A 32-bit divide by 48 -- not a power of two, so a real divider, 18 CARRY8 of
it -- evaluated combinationally from `n_rows`. In `matvec_int4` standalone,
`n_rows` is a top-level **port**, so OOC starts the path at the boundary with
zero source delay and the divider is short. In the descriptor wrapper `n_rows`
comes from a flop in `dw_reg`, and the whole divide has to fit in one core
cycle.

**This is a configuration-time path**: `n_rows` is written once per descriptor
and is required to be stable for the whole job. STA has no way to know that.
There is no `set_multicycle_path` on it anywhere in the repo and no pipeline
register in front of `tiles_r`. Either would remove it. **Not fixed here** --
`rtl/matvec_core.vhd` belongs to another track today, and the timing exception
would have to be written by whoever owns the constraint set for the real build,
not invented in an OOC script.

---

## 6. The clock answer, and the bandwidth arithmetic recomputed

### 6.1 Does A close at 300 MHz ACLK? No.

MEASURED, `matvec_int4` with all 27 masters, 0.717 V: **189.50 MHz**. That is
36.8% short. At the part-default 0.85 V it is 243.55 MHz (MEASURED on one
port), still 18.8% short, so the undervolt explains only part of it: of the
1.947 ns miss, 1.174 ns is the 0.717 V derate and 0.773 ns is logic depth that
misses even at nominal voltage.

`MAXOUT` is not the cause. At `MAXOUT=2` the same path is still -1.642 ns
(201.0 MHz). Raising `MAXOUT` to 16 costs 0.305 ns on top of a path that was
already 1.6 ns over.

### 6.2 Does A close at 236.128 MHz core? Not quite, and worse with the wrapper.

MEASURED: `matvec_int4` 221.83 MHz, `matvec_int4_desc_axi` 133.94 MHz. The
first is a 6.1% miss on the number every published A figure uses. The second is
the unconstrained divider of 5.3 and should be read as a constraint defect
rather than a property of the design.

### 6.3 The recomputed arithmetic

The identity from `docs/2026-08-28_can-27-read-masters-be-served.md:277`:
`27 x 256 bits = 6,912 bits = 864 B` is consumed per **core** cycle and
supplied 32 B per port per **AXI** cycle, so

```
duty = f_core / f_axi          (exactly, no efficiency term)
```

| quantity | as published | recomputed at MEASURED clocks | change |
|---|---|---|---|
| ACLK | 300.0 MHz (ESTIMATE from `hbm_tg`) | **189.50 MHz** MEASURED | -36.8% |
| supply, 27 ports | 259.2 GB/s | **163.7 GB/s** | **-36.8%** |
| core clock | 236.128 MHz | **221.83 MHz** MEASURED | -6.1% |
| demand | 204.0 GB/s | **191.7 GB/s** | -6.1% |
| **duty** | 78.7%, "27.1% margin" | **117.1%** | **does not fit** |

DERIVED, shown:

```
supply = 27 ports x 32 B x 189.50e6 = 163.73e9 B/s = 163.7 GB/s
demand = 864 B x 221.83e6           = 191.66e9 B/s = 191.7 GB/s
duty   = 191.66 / 163.73 = 1.171 = 221.83 / 189.50   (the identity, confirmed)
```

**The design cannot be fed.** The array wants 117.1% of what 27 ports can
deliver at the clock those ports actually close at. The rate is set by the
slower of the two, so A runs at 189.50 MHz effective, and at exactly 100% duty
-- which is the case the source document itself already called "not viable"
because it leaves zero margin for AR gaps, refresh and latency underruns.

Consequence for A's phase of the token, DERIVED and assumption-free (the byte
count is fixed, so the phase duration is inversely proportional to delivered
bandwidth):

```
A matvec phase duration vs every published figure = 204.0 / 163.7 = 1.246
```

**A's weight-read phase is 24.6% longer than every A figure in the repo
assumes.** Separately, if the engine clock is also held to the MEASURED 221.83
MHz rather than the assumed 236.128 MHz, everything that is not A gets 6.1%
slower as well.

Scaling the published `ROWS_IF=48` token rate (32.80 tok/s at 236.128 MHz,
`docs/2026-08-28_can-27-read-masters-be-served.md:292`) by the effective clock
gives, ESTIMATE, since it assumes the whole engine tracks one clock and that A
dominates the token:

| engine clock | tok/s | vs published |
|---|---|---|
| 236.128 MHz (published) | 32.80 | -- |
| 221.83 MHz (A's measured core clock) | 30.81 | -6.1% |
| 189.50 MHz (forced down to ACLK, 100% duty) | 26.32 | -19.8% |
| 133.94 MHz (`desc_axi` as committed) | 18.61 | -43.3% |

### 6.4 What it would take to reach 300 MHz

The AR-throttle path must lose 1.947 ns out of 5.115 ns, i.e. 38%. That is not
a placement or a synthesis-directive question. DERIVED from the path
composition: registering `w_level` inside `async_fifo` would remove the
gray-decode and subtract (5 of the 16 levels, ~2.0 ns by the single-clock
comparison), and constraining `f_level` / `promised` / the `DEPTH` compare to
their real ranges would shorten the remaining CARRY8 chain. **Neither was
attempted here.** Those are `rtl/async_fifo.vhd` and `rtl/axi_rd_fsm.vhd`,
which this track does not own, and the point of the exercise was the
measurement, not a better number.

Note that registering `w_level` adds one cycle of staleness to a level that
`async_fifo`'s header already documents as deliberately conservative with an
`OUT_MARGIN` slack term, so the change is plausible -- but "plausible" is not
"verified", and `sim/tb_matvec_fk33.vhd` would have to be re-run.

---

## 7. Measured and REJECTED / measurement traps hit

**Do not retry these.**

- **`-generic DUAL_CLK=1` does not work.** Vivado hands a 32-bit integer to a
  VHDL `boolean` generic and elaboration dies with
  `[Synth 8-690] width mismatch in assignment; target has 1 bits, source has
  32 bits`, pointing at **the generic's own declaration line**
  (`rtl/axi_rd_port.vhd:95`). That reads exactly like an RTL defect and is not
  one. It must be the literal `true` / `false`. Cost here: one wasted run and a
  false bug report nearly filed against another track's file.
- **`MAXOUT` is not the timing problem.** MEASURED at `MAXOUT=2`: -1.642 ns,
  201.0 MHz. It contributes 0.305 ns to a 1.947 ns miss. Do not go looking for
  a `MAXOUT` fix.
- **`DEPTH` is not a BRAM lever.** MEASURED: `async_fifo` at `DEPTH=256` and
  `DEPTH=512` both use **4 RAMB36**. DERIVED: a 256-bit-wide port needs
  `ceil(256/72) = 4` RAMB36E2 in SDP mode, and 4 x (512 x 72) is 512 deep, so
  every depth up to 512 is free. The BRAM cost is set by `AXI_DW`, not by
  `DEPTH`. Halving `FIFO_DEPTH` to save BRAM would save nothing.
- **URAM is not being used and cannot be swapped in cheaply.** MEASURED: 0
  URAM in every configuration; 320 URAM sit idle on the part. The weight
  streamer design already ruled URAM out for the dual-clock FIFO.
- **The Fmax-from-one-WNS extrapolation was verified, not assumed.**
  `axi_rd_port dual=1` at `aperiod=3.333` extrapolates to 189.39 MHz; re-run at
  `aperiod=5.3` it lands at WNS +0.020, i.e. **189.39 MHz**, the same figure to
  five digits. The linear extrapolation is sound for this unit. It was worth
  checking, because the whole clock answer rests on it.
- **`set_operating_conditions -voltage {VCCINT 0.717}` silently changes the
  reported device string** from `-2L-e` to `-2LV-e` and the speed file to
  `-2LV`. The part on the card did not change. Anyone diffing report headers
  will see this and should not chase it.
- **`matvec_int4` standalone HIDES the divider path of 5.3**, because `n_rows`
  is a top-level port in that build and a flop output in the wrapper. A unit's
  OOC timing is a function of where you cut the hierarchy. This is the concrete
  version of the general caveat and it cost 88 MHz.
- **`report_utilization -hierarchical` was the load-bearing measurement, not
  the flat one.** The flat total cannot separate the streamer from the DSP
  array, and the estimate being checked was specifically about the streamer.

---

## 8. Where the recorded estimates were wrong

Sources: `docs/2026-08-27_die-allocation-at-rows-if-48.md` lines 116, 152, 185,
202; `rtl/axi_rd_port.vhd:85-87`;
`docs/2026-08-28_can-27-read-masters-be-served.md:283-286, 341`.

| claim | recorded | MEASURED | verdict |
|---|---|---|---|
| streamer LUT, 27 lanes | ~7,400 ESTIMATE | **15,076** | **low by 2.04x** (+7,676) |
| streamer FF, 27 lanes | ~19,700 ESTIMATE | **8,474** | **high by 2.32x** (-11,226) |
| streamer BRAM36, 27 lanes | 108 ESTIMATE | **108** | **exact** |
| streamer DSP | 0 DERIVED | **0** | exact |
| `MAXOUT` 2->16 area | "~3 FF per port" | **+3 FF per port** (284->287 dual, 222->225 single), +1 to +2 LUT | **exact on area** |
| `MAXOUT` 2->16 timing | not mentioned | **-0.305 ns** on the AXI critical path | **omission** |
| `DEPTH=512` BRAM cost | "8 KB per port, x27 = 216 KB, a BRAM question" | 4 RAMB36/port = 108 total, and **identical at DEPTH=256** | right total, wrong mechanism |
| ACLK 300 MHz | ESTIMATE from `hbm_tg` with no engine | **189.50 MHz with the engine** | **low by 36.8%** |
| core 236.128 MHz | MEASURED on `matvec_core` alone | **221.83 MHz** with the streamer attached | optimistic by 6.1% |
| 6,144-bit `w_data` merge | flagged as a risk | real, but **83% route** and only 0.273 ns of the core-clock miss | risk real, magnitude smaller than the AR throttle |

The two 2x errors cancel in aggregate almost exactly (+7,676 LUT against
-11,226 FF), which is why no total ever looked wrong. Neither individual figure
should be reused.

---

## 9. Cost of the runs

| run | wall | peak parent RSS |
|---|---|---|
| `async_fifo` (each) | 0:46-0:48 | 4.7 GB |
| `axi_rd_port` (each) | 0:39-0:49 | 3.4-4.8 GB |
| `matvec_int4` | 7:01 | 5.9 GB |
| `matvec_int4_desc_axi` | 6:10 | 6.1 GB |

`/usr/bin/time -v` reports the parent only; system-wide use peaked around
13 GB of 31 GB during `matvec_int4` (parent plus the `parallel_synth` helper),
observed with `free`. `set_param general.maxThreads 4`, one run at a time, no
`place_design`. Nothing came near the 23.8 GB `engine_shared` figure and the
offload box was not needed.

---

## 10. What this does NOT establish

**Out-of-context synthesis is not implementation.** Specifically:

- **No placement and no routing were run.** Every route delay above is
  synth_design's estimate. For 5.1 that matters little (45% logic, and the
  logic-level count is a hard floor). For 5.2 it matters a lot: 83% of that
  path is route, and it can move in either direction with real placement.
- **No other subsystem was present.** B, C and D, the HBM IP, the XDMA shell
  and the 27 SAXI port interfaces all compete for the same fabric. Congestion
  makes timing worse, not better, so 189.50 MHz is an upper bound on what the
  full build will do at this ACLK, not a prediction.
- **No I/O buffers, no board pinout, no clocking resources** were inferred.
- **`opt_design` was not run.** The utilization report's own warning says the
  final LUT count is typically lower.
- **This says nothing about HBM read latency**, which is still unmeasured on
  this card and which is what actually sizes `MAXOUT` and `FIFO_DEPTH`.
- **This says nothing about the drain interlock** of
  `docs/2026-08-27_hbm-port-contention.md` section 6, still the
  highest-severity open item and a data-corruption class.
- **This says nothing about whether A's port windows overlap B's and C's.**
- **`weight_streamer`, `stream_fifo` and `axi_rd_fsm` were not synthesised
  standalone.** They are priced hierarchically inside `matvec_int4`, which is
  the more useful boundary; a standalone number for them would have the same
  boundary artefact as 5.3.
- **No `ROWS_IF` sweep of the AXI front end was run.** One geometry, the FK33
  one.
- **`llama_top`, `engine_shared` and `matvec_int4_ip` were not synthesised.**
- **Bit-exactness was not re-checked.** No RTL changed, so the standing
  simulation result is untouched, but nothing here re-verified it.

---

## 11. Open, not yet answered

1. What ACLK does A close at **after place and route**, with the HBM IP and the
   shell present? 189.50 MHz is the OOC ceiling.
2. Does the `set_multicycle_path` (or a pipeline register) that would fix 5.3
   exist anywhere in a planned constraint set, and who owns it?
3. If ACLK cannot exceed the core clock, is the 100%-duty single-clock
   configuration recoverable by any means other than raising the port count
   above 27 -- which the width identity forbids?
4. HBM read latency on this card. Unmeasured, and `MAXOUT`/`FIFO_DEPTH` both
   scale with it.

---

## 12. Corrections

None yet. Append here with a date; mark superseded claims withdrawn in place
rather than deleting them.
