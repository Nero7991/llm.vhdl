# Why does subsystem A's HBM ACLK stop at 189.4 MHz, and can the AR throttle be closed without weakening it?

**Date:** 2026-08-28. Branch `fpga`, baseline `bbe5e92`, synthesised in a
detached `git worktree` so that the four tracks editing `rtl/` concurrently
could not contaminate a netlist.
**Tool:** Vivado 2023.2, `synth_design -mode out_of_context`, `-mode batch`,
`sim/ooc_fk33_a.tcl`.
**Part:** `xcvu33p-fsvh2104-2L-e`, `set_operating_conditions -voltage
{VCCINT 0.717}` applied after synthesis (reports read back `-2LV-e`; that is
expected, see `docs/debugging/2026-08-24_fk33-sysmon-vccint-undervolt.md`).
**Geometry:** the FK33 one -- `ROWS_IF=48`, `AXI_DW=256`, `NPORTS_W=24`,
`NPORTS_S=3`, `BLK=32`, `ADDR_W=40`, `MAXB=16`, `MAXOUT=16`, `FIFO_DEPTH=512`,
`MAXCOLS=MAXROWS_BFP=17408`, `DUAL_CLK=true`.

**No hardware was touched.** No `xsdb`, no `hw_server`, no programming, no
bitstream, no `place_design`, no `route_design`. Out-of-context synthesis only.

Predecessor: `docs/debugging/2026-08-28_subsystem-a-ooc-synthesis-at-fk33-geometry.md`,
which measured the problem and named a fix direction in its section 6.4
without attempting it. **That document's section 5.1 attributes the critical
path to the wrong one of two consumers; a CORRECTION is filed in section 8
below.**

Labels: **MEASURED** (a named tool produced the number), **DERIVED**
(arithmetic on measured inputs, shown), **ESTIMATE** (a judgement).

---

## 1. The question

At the FK33 geometry, `axi_rd_port` with `DUAL_CLK=true` closed at
**189.4 MHz** on the HBM AXI clock, against a supply figure every published A
document computes at 300 MHz. Since `27 x 256 bits = 864 B` exactly, the duty
has no efficiency term and reduces to `duty = f_core / f_axi`, so at the
measured clocks 27 ports supplied 163.7 GB/s against a demand of 191.7 GB/s:
**117.1%, and the array could not be fed.**

Can that path be closed to at least the core clock -- which is what the duty
identity actually requires, not 300 MHz -- without making the AR throttle
optimistic? The throttle `f_level + promised + want <= DEPTH` is the only thing
preventing a FIFO overflow, and `async_fifo` fails an assertion on
write-into-full.

## 2. The answer

**Yes, and by a wide margin. MEASURED, 27 masters, `matvec_int4` at the FK33
geometry and 0.717 V: ACLK 189.50 -> 257.33 MHz (+35.8%), core clock
221.83 -> 226.96 MHz. Duty falls from 117.1% to 88.2%, so the array CAN now be
fed with 11.8% margin.** Area went DOWN: 136,674 -> 133,638 LUT (-2.2%).

Three changes, in the order they were made and measured, on `axi_rd_port`
standalone at `DUAL_CLK=true`:

| # | change | Fmax (AXI) | delta | data path | levels |
|---|---|---|---|---|---|
| 0 | baseline, reproduced | 189.39 MHz | -- | 5.115 ns | 16 |
| 1 | range the integers | 194.89 MHz | **+5.50** | 5.004 ns | 17 |
| 2 | + register `w_level` | 192.38 MHz | **-2.51** | 5.039 ns | 16 |
| 3 | + register the FULL flag behind `w_ready` | 316.26 MHz | **+123.88** | 3.035 ns | 10 |
| 4 | + one write-enable term (defect fix, see 6) | 313.19 MHz | -3.07 | 3.066 ns | 10 |

**The whole result is change 3, and change 3 is not what the predecessor
document pointed at.** Ranging the integers -- the change everyone expected to
work, and the one the CARRY8 count implied -- bought 5.5 MHz of a 32 MHz
requirement. Registering `w_level`, which section 6.4 named explicitly, made it
WORSE on its own.

## 3. The procedure, and what each step isolates

One change at a time, each measured before the next was made, all on
`vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs axi_rd_port dual=1`
(45-50 s, 4.8 GB) with `matvec_int4` (6:31, 6.3 GB) at the end to see the
change at 27 masters rather than at one.

| run | isolates |
|---|---|
| `axi_rd_port dual=1` at `bbe5e92` | **reproduce the baseline before touching anything** |
| ranged integers | whether the 32-bit comparator width is the cost |
| + registered `w_level` | whether the level is the live consumer of the subtract |
| + registered full flag | whether `w_ready` is |
| `aperiod=3.0` | **control on the Fmax extrapolation itself** |
| `dual=0` | that the single-clock configuration did not regress |
| `matvec_int4`, `matvec_int4_desc_axi` | the number at 27 and 28 masters, which is the one the bandwidth arithmetic uses |

The baseline reproduced exactly -- WNS -1.947 ns, 5.115 ns, 16 levels,
6 CARRY8, LUT 550 / FF 287, source `g_dc.fifo/rp_g_s2_reg[4]/C`, destination
`g_dc.fsm/this_len_reg[0]/R` -- so the flow is deterministic and the deltas
below are real.

## 4. The evidence

### 4.1 Reading the baseline path properly

The predecessor read the endpoints of the path and inferred the mechanism from
the RTL. Reading the intermediate NODES instead is what found the real cause.
Baseline, verbatim, abridged to the nodes that matter:

```
FDRE                              g_dc.fifo/rp_g_s2_reg[4]/Q      0.154
LUT6 / LUT5                       g_dc.fifo/used_w_carry_i_9,_i_7 0.847   <- gray2bin
CARRY8                            g_dc.fifo/used_w_carry/O[6]     1.190   <- wp - rp_bin_w
LUT6                              g_dc.fifo/rready_INST_0_i_1/O   1.610   <- THE FULL COMPARE
LUT6                              g_dc.fifo/mem_reg_0_i_4/O       1.898
LUT5                              g_dc.fsm/i__carry_i_1/O         2.202
CARRY8                            g_dc.fsm/pr0_.../i__carry/O[4]  2.661   <- pr := pr - 1
LUT6 x2, CARRY8 x2                g_dc.fsm/arv1[9]                3.814   <- f_level + pr + want
LUT1, CARRY8 x2                   g_dc.fsm/arv0                   4.568   <- <= DEPTH
LUT6, LUT2                        g_dc.fsm/this_len[3]_i_1        5.156
```

`rready_INST_0_i_1` is `w_ready`. The chain is therefore

```
rp_g_s2 -> gray2bin -> subtract -> (used_w = DEPTH) -> w_ready -> axi_rd_port's
rready -> beat_f -> the FSM's `beat` -> `pr := pr - 1` -> the throttle compare
```

and NOT, as recorded, the `w_level` path. Both consumers hang off the same
subtract, so both had to go; but `w_level` is the one that was NOT live.

### 4.2 Change 1, range the integers. MEASURED +5.50 MHz.

`rtl/axi_rd_fsm.vhd`: `f_level` becomes `integer range 0 to 2*DEPTH +
LVL_MARGIN` (new generic, default 3), `promised` becomes `0 to DEPTH + MAXB`,
and the process variables `pr`, `os`, `want` are ranged to match.
`rtl/async_fifo.vhd`: `w_level` ranged the same way.
`rtl/axi_rd_port.vhd`: `f_level` ranged, and `LVL_MARGIN` stated once and
passed to both children so the two cannot drift.

Where each bound comes from, DERIVED:

- **`promised <= DEPTH`.** It only grows through `pr := pr + this_len` on
  `arready`, and the guard that allowed that burst was
  `f_level + pr + want <= DEPTH` with `f_level >= 0`, so `pr + this_len <=
  DEPTH` held at the guard. Between the guard and `arready` no second burst can
  issue (`arv` is high, so the `elsif` is not taken) and `pr` can only fall as
  beats retire. `+MAXB` of headroom was added because `-1..DEPTH` and
  `-1..DEPTH+MAXB` are both 11 signed bits at `DEPTH=512`, so it is free.
- **`pr` and `os` reach -1.** `pr := pr - 1` on a beat with no promise
  outstanding is exactly what the existing `if pr < 0 then pr := 0` clamp
  absorbs; the range says so rather than hiding it.
- **`want <= MAXB`** by the `if ar_left > MAXB` branch immediately above it.
- **`f_level <= 2*DEPTH + LVL_MARGIN`, NOT `DEPTH + LVL_MARGIN`.** This one is
  the trap. In steady state the level cannot exceed `DEPTH+3`, but `async_fifo`
  computes it from a pointer pair that is DELIBERATELY inconsistent during the
  four-phase clear: `rtl/async_fifo.vhd` parks `wp` at 0 while `rp_g_s2` is
  still two synchroniser stages behind, so the subtraction wraps and the driven
  value is the full range of an `(AW+1)`-bit unsigned. The FSM never USES it
  there (the AR branch is guarded by `st = S_RUN`, the clear runs in
  `S_CLR`/`S_CLR2`), but **a VHDL range constrains what is DRIVEN, not what is
  read**, and the tight bound kills the simulation on a legal transient. Cost
  of the safe bound: exactly one bit of comparator.

Result: 189.39 -> 194.89 MHz, and LUT 550 -> 464 (-15.6%), FF 287 -> 265. The
area win is real and immediate; the timing win is not, because the path is
route-dominated (57.7% route) and **17 unplaced levels at ~0.22 ns of estimated
net delay each is where the time goes, not comparator width.**

### 4.3 Change 2, register `w_level`. MEASURED -2.51 MHz.

Section 6.4 of the predecessor named this. On its own it moved the number the
wrong way and the path still STARTED at `rp_g_s2_reg[4]`, which is the proof
that `w_level` was not the live consumer.

It is kept anyway, because with `w_ready` fixed it would otherwise become the
critical path in change 3's place. It is `used_w + OUT_MARGIN + 1`, one cycle
behind. **Direction of the error: PESSIMISTIC, and the `+1` is the proof.** At
most one beat is written per `wclk`, so `wp(n+1) <= wp(n) + 1`, and `rp_bin_w`
is a gray-synchronised view of a monotone counter so it never moves backwards.
Hence `used_w(n+1) <= used_w(n) + 1`, and

```
w_level(n+1) = used_w(n) + OUT_MARGIN + 1 >= used_w(n+1) + OUT_MARGIN
```

which is EXACTLY the guarantee the combinational version gave: at least the
true occupancy, plus `OUT_MARGIN`. The staleness is paid for in full. It costs
one beat of 512.

### 4.4 Change 3, register the FULL flag behind `w_ready`. MEASURED +123.88 MHz.

`w_ready` becomes `not (clr or full_r)` where `full_r` is a register.
`clr` stays combinational deliberately: it is already a register in the caller
(`axi_rd_fsm`'s `clr_r`), and delaying it would move `w_ready`'s DEASSERTION
later, which is the unsafe direction for a flush.

`full_r` is not a delayed copy. It is computed one cycle ahead and includes the
write being performed in the cycle it is computed:

```
full_r(n+1) = ( used_w(n) + wr_now(n) >= DEPTH )
```

**Direction of the error: PESSIMISTIC, and here is the proof.** `rp_bin_w` only
ever advances, so
`used_w(n+1) = used_w(n) + wr_now(n) - (beats retired) <= used_w(n) + wr_now(n)`.
Therefore `used_w(n+1) = DEPTH` implies `full_r(n+1) = '1'`: **the flag can
never claim space that does not exist.** The only error is the other way -- it
can hold '1' for one extra cycle after the reader frees a slot, delaying a beat
and never dropping one. That one-cycle stall is unreachable in any case,
because the AR throttle above exists precisely so the FIFO never reaches
`DEPTH`. There is also a stronger consequence: since `wr_now` is gated by
`full_r`, and `full_r = '0'` implies `used_w < DEPTH`, the FIFO can no longer
overflow even if the throttle were wrong.

Result: 194.89 -> 316.26 MHz standalone. Data path 5.004 -> 3.035 ns, levels
17 -> 10, and the path source moves out of the FIFO entirely.

### 4.5 The Fmax extrapolation was verified, not assumed

Change 3 MEETS at `aperiod=3.333` (WNS +0.171), and an Fmax read off a met
slack is an extrapolation from a netlist that was optimised to a constraint it
already satisfied. Re-run at `aperiod=3.0`: WNS -0.162, Fmax **316.26 MHz**,
the same figure to five digits. Change 4 likewise: +0.140 at 3.333 and -0.193
at 3.0, both **313.19 MHz**. The extrapolation holds for this unit, exactly as
the predecessor found for the baseline.

### 4.6 At 27 masters, which is the number that counts

MEASURED, `matvec_int4`, `DUAL_CLK=true`, 0.717 V, all 27 AXI read masters:

| | baseline `bbe5e92` | after | change |
|---|---|---|---|
| ACLK | 189.50 MHz | **257.33 MHz** | **+35.8%** |
| core clock | 221.83 MHz | **226.96 MHz** | +2.3% |
| LUT | 136,674 | **133,638** | -2.2% |
| FF | 61,263 | **60,985** | -0.5% |
| DSP | 1,584 | 1,584 | 0 |
| BRAM36 | 145.5 | 145.5 | 0 |

MEASURED, `matvec_int4_desc_axi`, the same geometry with the 28th master and
the descriptor control plane:

| | baseline `bbe5e92` | after |
|---|---|---|
| ACLK | 190.48 MHz | **257.33 MHz** |
| core clock | 133.94 MHz | **133.94 MHz, unchanged** |
| LUT | 139,141 | **136,051** |
| FF | 64,265 | **63,975** |
| BRAM36 | 192.5 | 192.5 |

The core clock is identical to the digit because it is F2 of the predecessor,
the unconstrained divide-by-48 at `rtl/matvec_core.vhd:858`, which is another
track's file and was deliberately not touched. Nothing here should have moved
it and nothing did.

The standalone port reaches 313.19 MHz and the 27-master build reaches 257.33.
The difference is the bigger netlist: the ACLK net is `fo=6184` there against
`fo=229` standalone, and the estimated route fraction rises. **257.33 is the
honest number**; 313.19 is what one port does with nothing around it.

The new AXI critical path at 27 masters is no longer in the FIFO at all:

```
Source:      streamer/gen_w[21].port_p/g_dc.fsm/st_reg[0]/C
Destination: streamer/gen_w[21].port_p/g_dc.fsm/this_len_reg[0]/CE
Data Path Delay: 3.759ns (logic 1.549ns 41.2% / route 2.210ns 58.8%)
Logic Levels: 12  (CARRY8=4 LUT1=1 LUT2=3 LUT5=1 LUT6=3)
```

The core-clock path is the one the predecessor already identified as the merge
fanout, and it is still 80% route:

```
Source:      streamer/gen_w[22].port_p/g_dc.fifo/ocnt_reg[1]/C
Destination: core/tr_reg[0][0]/DSP_A_B_DATA_INST/CEA2
Data Path Delay: 4.092ns (logic 0.819ns 20.0% / route 3.273ns 80.0%)
Logic Levels: 5  (LUT3=1 LUT6=4)
```

### 4.7 Behaviour is unchanged. MEASURED.

`sim/regress.sh`, full run, both suites, after the final RTL:

```
 suite sim   PASS 54   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 80   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 80 passing, matches the recorded floor of 80
```

and specifically, `tb_matvec_fk33_desc` still reports bit-exact on BOTH paths:

```
CASE  0 clean descriptor  OK -- 100 elements bit-exact on the core bus,
                                100 rows bit-exact through AXI-Lite, y_exp=6
tb_matvec_fk33_desc: 22 cases run, 0 failures
subsystem A is bit-exact with ref/matvec_int4.c through the descriptor control
plane, and every checked mutation is refused
```

Read section 6's defect note before treating this as strong evidence: the
regression also passed on the version with the duplicate-beat defect.

## 5. The bandwidth arithmetic, recomputed

The identity is unchanged: `27 x 256 bits = 6,912 bits = 864 B` consumed per
CORE cycle, 32 B per port per AXI cycle, so `duty = f_core / f_axi` exactly.

| quantity | as published | at `bbe5e92` MEASURED | **after, MEASURED** |
|---|---|---|---|
| ACLK | 300.0 MHz ESTIMATE | 189.50 MHz | **257.33 MHz** |
| supply, 27 ports | 259.2 GB/s | 163.7 GB/s | **222.3 GB/s** |
| core clock | 236.128 MHz | 221.83 MHz | **226.96 MHz** |
| demand | 204.0 GB/s | 191.7 GB/s | **196.1 GB/s** |
| **duty** | 78.7% | **117.1%, does not fit** | **88.2%, fits** |

DERIVED, shown:

```
supply = 27 ports x 32 B x 257.33e6 = 222.33e9 B/s = 222.3 GB/s
demand = 864 B x 226.96e6           = 196.09e9 B/s = 196.1 GB/s
duty   = 196.09 / 222.33 = 0.8820 = 226.96 / 257.33   (the identity, confirmed)
```

**The array can be fed, with 11.8% margin.** The requirement was
`f_axi >= f_core`, i.e. 226.96 MHz; 257.33 MHz clears it by 30.4 MHz.

Against the published figures rather than the previous measurement: supply is
222.3 GB/s where the docs assume 259.2, so **A's weight-read phase is
204.0 / 222.3 = 0.918, i.e. 8.2% SHORTER than the published figure assumes**,
not 24.6% longer. Scaling the published 32.80 tok/s at 236.128 MHz by the
measured core clock gives **31.53 tok/s** (ESTIMATE, since it assumes the whole
engine tracks one clock and that A dominates the token), against 26.32 at the
previous measurement.

## 6. Measured and REJECTED, and one defect I introduced

**Do not retry these.**

- **Ranging the integers alone does not close this path.** MEASURED: +5.50 MHz
  of a 32 MHz requirement. It is worth doing for the 15.6% LUT saving and
  because it is a correctness statement, but the CARRY8 count is a red herring:
  the path is route-dominated and the cost is LEVELS, at roughly 0.22 ns of
  estimated net delay per level, not comparator width.
- **Registering `w_level` alone makes it WORSE.** MEASURED: -2.51 MHz, and the
  path still starts at the same flop. Section 6.4 of the predecessor names this
  as the fix; it is half of one.
- **A registered `full` flag is NOT a delayed `full` flag.** The first version
  written here delayed `used_w = DEPTH` by a cycle and compensated with a
  margin. Including the current cycle's write in the next-state expression is
  strictly better: it needs no margin at all and it makes overflow structurally
  impossible.
- **DEFECT I INTRODUCED AND FIXED, stated because it is the exact failure mode
  this class of change invites.** With `w_ready` registered but the memory
  write still gated on the OLD `used_w /= DEPTH`, the two conditions can
  disagree for one cycle. The FIFO would then WRITE the beat while
  `w_ready = '0'` left the AXI handshake incomplete, so the producer presents
  the same beat again next cycle and it is stored TWICE -- a silent per-port
  stream duplication, which is precisely the class of defect the flush-on-start
  rule exists to prevent. Caught by re-reading the diff, not by simulation:
  **`tb_axi_rd_port`, `tb_matvec_fk33` and `tb_matvec_fk33_desc` ALL PASSED on
  the broken version**, because the AR throttle keeps the FIFO far from full so
  the disagreeing window is never entered. Fix: one `wr_now` term that
  `w_ready`, the memory write and `full_r`'s next state all use. Cost of the
  fix: 3.07 MHz.
- **`-generic DUAL_CLK=1` still does not work** and still points at the
  generic's own declaration line. It must be the literal `true`/`false`. The
  predecessor recorded this; it is repeated because the error message is a
  convincing false bug report.
- **A MET slack is not an Fmax.** Both post-fix configurations were re-run at
  `aperiod=3.0` to confirm; see 4.5.

## 7. What this does NOT establish

- **No placement and no routing.** 58.8% of the remaining AXI path is
  synth_design's route ESTIMATE, and at 27 masters the ACLK fanout is 6,184.
  257.33 MHz is an OOC ceiling, not a prediction; the full build has B, C, D,
  the HBM IP and the XDMA shell competing for the same fabric.
- **`matvec_int4_desc_axi`'s core clock is still governed by the unconstrained
  divide-by-48 at `rtl/matvec_core.vhd:858`** (F2 of the predecessor). That
  file belongs to TRACK RANGE and was deliberately not touched. Nothing here
  changes it.
- **`ar_left`, `p_beats` and the `n_beats` port are still unconstrained
  `integer`s**, and `ar_left` is now visible on the standalone port's critical
  path as 5 CARRY8. Ranging them needs a bound on `n_beats`, which needs a new
  generic on a port that other tracks instantiate. Not done: the number already
  clears the requirement by 30.4 MHz, and the core clock binds above that.
- **HBM read latency is still unmeasured**, and it is what actually sizes
  `MAXOUT` and `FIFO_DEPTH`.
- **The one-cycle-later release of backpressure when genuinely full was not
  exercised in simulation**, because the throttle makes it unreachable. The
  argument that it is safe is the proof in 4.4, not a test.

## 8. CORRECTION to `2026-08-28_subsystem-a-ooc-synthesis-at-fk33-geometry.md`

**Section 5.1 and section 6.4 of that document, WITHDRAWN in part.** They state
that the critical path is

```
rtl/async_fifo.vhd:150-152  ->  rtl/axi_rd_fsm.vhd:181
```

i.e. through `w_level`, and that "registering `w_level` inside `async_fifo`
would remove the gray-decode and subtract (5 of the 16 levels, ~2.0 ns)". The
endpoints quoted there are correct and were reproduced exactly. The MECHANISM
is not: reading the intermediate nodes shows the live path leaves the FIFO
through `w_ready` (`rtl/async_fifo.vhd:153` as committed), not through
`w_level`. MEASURED consequence: registering `w_level` alone moved the clock
from 189.39 to 192.38 MHz, i.e. -2.51 MHz, the wrong way.

The rest of that document stands, including the 6 CARRY8 observation, the
`f_level`/`promised` diagnosis (which is real, worth 5.50 MHz and 15.6% of the
port's LUTs), the area figures and the extrapolation control.

Its section 6.3 duty table is superseded by section 5 above.

## 9. Open, not yet answered

1. What ACLK does A close at **after place and route**, with the HBM IP and the
   shell present? 257.33 MHz is the OOC ceiling.
2. The core clock is now the binding side of the duty (226.96 vs 257.33), and
   80% of that path is route into the DSP array. That is a placement question
   and it is not this track's file.
3. Whether `ar_left`/`n_beats` should carry a `MAXBEATS` generic. Free MHz on
   the standalone port; probably inert at 27 masters.
4. `rtl/matvec_core.vhd:858`, the divide-by-48, unchanged and still owned
   elsewhere.
