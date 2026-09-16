# The first full card build synthesises clean and the placer refuses it: 109.15% LUT

## 1. The question

2026-09-16, continuing the goal *"continue toward the full bitstream build"*.
Hardware: SQRL FK33, `xcvu33p-fsvh2104-2L-e`. Build:
`FK33_CARD=1 hw/fk33/pcieep_build.sh`, i.e. the three-cell block design --
`eng` (subsystem A), `card` (B, C and D via `fk33_llama_top`) and `bcgrant`.
This is the first such build ever attempted; every previous FK33 bitstream was
the engine-only configuration.

Does it produce a bitstream?

## 2. The answer

**No. It synthesises with zero errors and the PLACER REFUSES TO START.**

```
ERROR: [DRC UTLZ-1] Resource utilization: Slice LUTs over-utilized in Top Level
Design (This design requires more Slice LUTs cells than are available in the
target device. This design requires 477022 of such cell types but only 439680
compatible sites are available in the target device...)
ERROR: [Vivado_Tcl 4-23] Error(s) found during DRC. Placer not run.
ERROR: [Common 17-39] 'place_design' failed due to earlier errors.
```

**It is purely LUT-bound.** Every other resource has headroom.

## 3. The evidence

`bd_wrapper_utilization_synth.rpt`, Design State: Synthesized:

| Site Type | Used | Available | Util% |
|---|---|---|---|
| **CLB LUTs** | **479,919** | 439,680 | **109.15** |
| LUT as Logic | 431,821 | 439,680 | 98.21 |
| LUT as Memory | 48,098 | 205,440 | 23.41 |
| -- as Distributed RAM | 46,506 | | |
| -- as Shift Register | 1,592 | | |
| CLB Registers | 494,420 | 879,360 | 56.22 |
| CARRY8 | 12,207 | 54,960 | 22.21 |
| F7 Muxes | 80,750 | 219,840 | 36.73 |
| F8 Muxes | 32,776 | 109,920 | 29.82 |

The DRC quotes 477,022 and the synthesis report 479,919; the difference is
post-synthesis optimisation and does not change the verdict. **Overage is
about 40,239 LUT.**

Subsystem B+C+D alone, measured separately the same day by
`hw/fk33/ooc_card_dcp.tcl` (745 s, 0 errors, 61 MB DCP):

| resource | used | available | % |
|---|---|---|---|
| CLB LUT | 292,383 | 439,680 | 66.5 |
| DSP48E2 | 538 | 2,880 | 18.7 |
| Block RAM | 197 | 672 | 29.3 |
| URAM | 32 | 320 | 10.0 |

## 4. The procedure that got here

Everything upstream had to pass first, and all of it did, today:

1. RTL elaboration of the card configuration: **3:54, 0 errors** -- previously
   a silent hang of over 25 minutes. See
   `2026-09-14_the-wall-is-a-3d-ram-vivado-warned-about.md`.
2. `fk33_card` full OOC synthesis: **745 s, 0 errors**, checkpoint written.
3. `FK33_CARD=1 --bd-only`: `FK33_BD_VALIDATE OK`, `FK33_BD_ONLY_DONE`, 0
   errors, `FK33_ENG portcheck bad=0`, zero address-overlap warnings.
4. Full build: synthesis clean, `place_design` refused.

## 5. Measured and REJECTED -- do not retry

- **`dsp=4842`, i.e. "the card does not fit on DSP" (168%).** WRONG, and it was
  this dispatcher's own census that said so. `get_cells -hier -filter
  {REF_NAME =~ DSP*}` matches each `DSP48E2` PLUS its eight internal
  primitives, and the log says so: *"DSP48E2 => DSP48E2 (DSP_ALU,
  DSP_A_B_DATA, DSP_C_DATA, DSP_MULTIPLIER, DSP_M_DATA, DSP_OUTPUT, DSP_PREADD,
  DSP_PREADD_DATA): 538 instances"*. 538 * 9 = 4842. **The real figure is 538,
  18.7%.** Fixed in `4b1d58f` by anchoring to `REF_NAME == DSP48E2`. Do not
  re-derive a DSP count with a glob.
- **Budgeting the card build at 10.66 GB.** That figure is the ENGINE-ONLY
  build. MEASURED: the card build hit `memory.peak` 18.00 GB -- its `MemoryHigh`
  cap, so the true peak is unknown and at least that -- within 28 minutes and
  still inside synthesis, taking swap from 2 GB to 15 GB. Corrected in
  `CLAUDE.md`. **The two builds are different jobs; their budgets are not
  interchangeable.**

## 6. Measurement traps hit

- **A capped job's `memory.peak` is the cap.** `cardbuild` reported exactly
  18.00 GB against `MemoryHigh=18G`. That is the throttle holding it there, not
  the appetite, exactly as `CLAUDE.md` already records.
- **The over-utilisation number appears in two places and they differ** (DRC
  477,022 against report 479,919). Quote which one you mean.

## 7. The lever, and what is NOT being claimed about it

`fk33_engine` has a `CB_STYLE` generic, forwarded to `matvec_int4_desc_axi` and
on to `matvec_core`, choosing whether the IQ4_NL codebook lives in registers or
LUTRAM. TRACK LEVERC48 measured `"distributed"` at **-42,633 CLB LUT, MUXF7
24,583 -> 0, MUXF8 12,288 -> 0**, costing +13,195 FF and +12,288 LUTRAM -- and
FF is at 56% and LUT-as-memory at 23%, so both costs have room.

**That figure is 264 commits old and is NOT being quoted as a prediction.**
`docs/WORKLOG.md` already flagged it as needing re-measurement, and three of
A's files have changed since. The lever has been made settable
(`FK33_CB_STYLE`, default `"regs"` so the shipping configuration is unchanged)
**in order to measure it on the current tree**, not because -42,633 is believed.

`fk33_engine.vhd:67` is why it is a block-design CONFIG property and not a
`-generic`: *"-generic reaches the TOP's generics only, never a deep
instance"*. The emitted Tcl reads the property back and errors if it did not
take, because a `set_property` whose target did not match is silently ignored
and a lever that was never applied looks exactly like a lever that did not work.

## 8. Open, not yet answered

- **Whether the lever closes a 40,239 LUT gap on the current tree.** Being
  measured now.
- **What to do if it does not.** Not yet investigated. The LUT-as-Logic figure
  alone is 431,821 of 439,680 (98.21%), so even with all of LUT-as-Memory
  removed the design would be marginal; a second lever may be needed.
- **Timing.** Unknown and unmeasurable until the placer runs. Nothing before
  `route_design` orders two runs correctly on this part.
- **Values on subsystem A's card binding.** `ga_desc` still has no behavioural
  coverage at all, and the `x_exp` divergence remains open. A bitstream does
  not change either.

---

## MEASURED, same day: lever C fits the design, at 99.67%

`FK33_CB_STYLE=distributed`, full `FK33_CARD=1` build, synthesis complete:

```
| CLB LUTs*                  | 438219 |  0 |  0 | 439680 | 99.67 |
|   LUT as Logic             | 377833 |  0 |  0 | 439680 | 85.93 |
|   LUT as Memory            |  60386 |  0 |  0 | 205440 | 29.39 |
| CLB Registers              | 507624 |  0 |  0 | 879360 | 57.73 |
| F7 Muxes                   |  56174 |  0 |  0 | 219840 | 25.55 |
| F8 Muxes                   |  20488 |  0 |  0 | 109920 | 18.64 |
Starting Placer Task
```

**Under the limit by 1,461 LUT**, and `place_design` now runs where it
previously refused to start.

### The 264-commit-old figures held, and the STRUCTURAL ones held EXACTLY

TRACK LEVERC48's numbers were deliberately NOT quoted as a prediction here --
`docs/WORKLOG.md` flagged them as stale and three of A's files had changed. The
lever was made settable in order to MEASURE it. Having measured it, the
comparison is worth recording:

| quantity | LEVERC48, 2026-08-30 | measured 2026-09-16 | error |
|---|---|---|---|
| CLB LUT | -42,633 | **-41,700** | 2.2% |
| CLB FF | +13,195 | **+13,204** | 9 |
| MUXF7 | -24,583 | **-24,576** | 7 |
| MUXF8 | -12,288 | **-12,288** | **0** |
| LUTRAM | +12,288 | **+12,288** | **0** |

This is `CLAUDE.md`'s own distinction confirmed on a fresh case: **a quantity
that is structural is a constant, and a quantity that scatters is a mean.**
LUTRAM and MUXF8 are exactly `12,288` -- `ROWS_IF * 256` at the card shape --
and came back to the unit across 264 commits. FF and MUXF7 moved by single
digits. Only the aggregate LUT total, which absorbs every downstream
optimisation, scattered, and it scattered by 2.2%.

**This does NOT retroactively justify quoting the stale figure.** The reason
to measure was that nothing in the number itself said which of its components
were structural and which were not; that is visible only afterwards. Had A's
codebook path changed, the same table would have shown it.

### The margin is thin and placement is not yet a result

**1,461 LUT of 439,680 is 0.33%.** Vivado commonly struggles to place above
roughly 90% LUT, so `Starting Placer Task` is not the same as a placed design,
and congestion is the live risk. Per this project's own record, nothing before
`route_design` orders two runs correctly on this part -- a `phys_opt` WNS has
over-promised by 0.4 to 0.6 ns here, twice, with enough margin to invert a
verdict.

**Open:** whether it places, whether it routes, and what the routed WNS is.

---

## AND IT STILL DOES NOT PLACE: short by 494 CLBs, which is NOT the same as short of LUTs

```
ERROR: [Place 30-487] The packing of instances into the device could not be
obeyed.  There are a total of 54960 CLBs in the device, of which 35872 CLBs are
available, however, the unplaced instances require 36366 CLBs.  Please analyze
your design to determine if the number of LUTs, FFs, and/or control sets can be
reduced.
ERROR: [Place 30-99] Placer failed with error: 'Detail Placement failed'
```

Placement ran for ~46 minutes, reached `Phase 3.2 Commit Most Macros`, and
failed. **36,366 CLBs required against 35,872 available: short by 494**, or
1.4%.

**THE UNIT CHANGED AND THAT IS THE POINT.** The previous failure was counted in
LUTs (109.15% of 439,680) and this one is counted in **CLBs**, which is a
PACKING result rather than a resource count. At 99.67% LUT the design passes
the DRC and still cannot be packed, because a CLB holds 8 LUTs and 16 FFs only
when the logic in it shares a control set -- and Vivado names
**"LUTs, FFs, and/or control sets"** in that order for a reason. **0.33% LUT
headroom was not headroom.**

This is also why the `CLB = F7/4 + (LUT - 2*F7)/D` closed form already recorded
in `CLAUDE.md` exists: CLB count is not `LUT/8`, and it cannot be predicted
from a LUT total alone.

### What is being done about it, and in which order

**The census FIRST, not a second lever guess.** `CLAUDE.md` records the exact
failure of doing this the other way round -- forming a theory and then using a
census to check it, which produced a confidently wrong attribution that an
already-written document had to retract. So: `report_utilization -hierarchical`
and `report_control_sets -verbose` on the EXISTING post-synthesis checkpoint,
which needs no re-synthesis because the netlist already holds the answer.

**Control sets are the half nobody looks at.** They are named by the placer's
own message, they fragment CLB packing directly, and unlike LUT count they can
often be reduced without changing arithmetic at all -- a shared reset or a
removed clock-enable costs nothing functionally.

### Do NOT retry

- **"It fits, so it will place."** MEASURED false today, twice over: 99.67% LUT
  passed the utilization DRC and failed detail placement 46 minutes later.
  A LUT percentage is not a placement prediction.

### Open

- Which block-design cell owns the packing pressure. Being measured.
- Whether control-set reduction alone closes 494 CLBs.
- Timing, still entirely unknown -- the placer has never completed.

---

## The census, read BEFORE choosing a second lever

`report_utilization -hierarchical` and `report_control_sets -verbose` on the
existing post-synthesis checkpoint. Two minutes, no re-synthesis.

### Where the LUTs are

| cell | Total LUT | Logic LUT | LUTRAM | FF |
|---|---|---|---|---|
| `card` (B, C, D) | **288,877** (65.9%) | 263,166 | 25,366 | 357,311 |
| `eng` (A) | **90,874** (20.7%) | 73,348 | 16,728 | 76,923 |
| `xdma` | 16,494 | 14,617 | 1,864 | 20,402 |
| `fk33_seam_0` | 11,083 | 1,615 | 9,468 | 888 |
| `pcie2axil` | 10,783 | 8,767 | 1,768 | 12,537 |
| `pcie2hbm` | 9,534 | 7,141 | 2,268 | 15,024 |
| **top** | **438,219** | 377,833 | 58,794 | 507,624 |

The card cell is two-thirds of the design. Infrastructure (xdma, the two PCIe
bridges, the seam and the aux GPIOs) is about 48,000 LUT and is not a lever --
it is the host interface.

### Control sets, and why they are NOT the answer here

```
Total control sets                                       | 21278
   Minimum number of control sets                        | 21278
   Addition due to synthesis replication                 |     0
Unused register locations in slices containing registers |  6292
Histogram: >= 0 to < 4 : 1801     >= 4 to < 6 : 586     >= 6 to < 8 : 322
```

21,278 control sets, none of them from replication, and 1,801 with fanout below
4. Vivado's own footnote points at `opt_design -control_set_merge`, and it is
genuinely attractive because it changes **no RTL and no arithmetic**.

**But the arithmetic says it cannot be sufficient.** 438,219 LUTs at 8 per CLB
require **54,777 of the device's 54,960 CLBs for the LUTs ALONE** -- 183 CLBs
of slack, 0.33%. Control-set merging improves FF packing density; **the full
dimension is LUTs.** Merging control sets in a design whose LUT count already
consumes 99.67% of the CLB array cannot recover 494 CLBs, because those CLBs
are not being wasted on FFs, they are being spent on LUTs.

**This is worth stating because it is exactly the lever a plausible-sounding
argument would have reached for**: the placer's message names control sets, the
report shows 1,801 bad ones, and the fix is free. All true, and still the wrong
dimension. **The message names what CAN be reduced, not what IS binding.**

### What follows

The card cell is where any real saving has to come from, and the search is now
aimed rather than hopeful. A depth-6 census is running to attribute the
card's 288,877 LUT across B, C and D.

Recorded candidate, NOT yet re-measured on this tree: `KV_BLOCK`, measured
2026-09-05 at **-18,022 LUT in `u_arr` and -14,383 net**, with the warning
attached that an exact relationship for one resource (DSP) did not license
scaling a different resource (LUT) by the same factor. 14,383 LUT is about
1,798 CLBs against a 494 CLB shortfall, so it would clear it with margin --
IF it still holds, and if the behavioural cost is acceptable.

### Do NOT retry

- **Control-set merging as the fix for this failure.** Reason above. It may
  still be worth enabling as a cheap density gain ALONGSIDE a LUT reduction,
  but on its own it addresses a dimension that is not full.
