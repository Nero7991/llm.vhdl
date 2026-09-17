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

---

## BOTH `ram_style = "block"` ATTRIBUTES WERE REFUSED, AND ONE OF THEM IS MINE

MEASURED 2026-09-16, build 3. After moving the seam's `desc_ram` to block RAM,
the synthesis utilization report came back **bit-identical to build 2**:
`CLB LUTs 438219 (99.67%)`, `LUT as Memory 60386`, `Block RAM Tile 436.5`.
Nothing moved.

The log says why, and it names two RAMs, not one:

```
WARNING: [Synth 8-6850] RAM (desc_ram_reg) has partial Byte Wide Write Enable
  pattern with ram_style = "block", however no output register found in fanout
  of RAM.  Recommended to use supported Byte Wide Write Enable template.
WARNING: [Synth 8-6849] Infeasible attribute ram_style = "block" set for RAM
  "fk33_seam_0/inst/desc_ram_reg", trying to implement using LUTRAM

WARNING: [Synth 8-6849] Infeasible attribute ram_style = "block" set for RAM
  "fk33_llama_top__GCB14/ga_desc.ybw_reg", trying to implement using LUTRAM
```

### `ga_desc.ybw` is LUTRAM, and that is my own unverified claim

`6a2d282` replaced `ga_desc.ap`'s 48-write-port y store with a beat-wide word
array carrying `attribute ram_style of ybw : signal is "block"`. **The
elaboration fix was real and necessary** -- it took the card top from a
25-minute silent hang to 3:54 -- but **the storage never became block RAM.**
196,608 bits went into distributed RAM instead.

The commit message asserted the `region_mem` precedent (one write site, one
read site, therefore inferrable) and **never checked the utilization report to
see whether the attribute was honoured.** This file already records, twice,
that `8-6849` is a WARNING and falls back silently, and that only the mapping
report and an object census are authoritative. The elaboration result was
decisive enough that the storage question was not asked at all.

**Why it is refused** is visible in the RTL: the read is a DYNAMIC BIT-SLICE of
a 768-bit word --
`signed(ybw(rword)((rlane+1)*MANT_W-1 downto rlane*MANT_W))` -- so the lane mux
sits after the memory, and a 768-bit-wide port is not a BRAM shape.

**The structure that would infer** is `A_ROWS_IF` SEPARATE memories, one per
lane, each `A_YWORDS` deep by `MANT_W` wide: the write becomes one port per
lane memory (which is what the beat already provides, one element per lane),
and the read becomes `ybw_lane(rlane)(rword)` -- a word-select plus a mux over
narrow outputs. 48 memories of 256 x 16 is about 24 RAMB36 equivalent against
235 spare tiles. NOT YET DONE.

### `desc_ram` is refused for a different reason

`8-6850` is specific: a **partial byte-wide write enable** pattern (the host
writes 32 bits at a time into a 64-bit word, `desc_ram(idx/2)(31 downto 0)`)
**combined with no output register in the fanout**. The descriptor-fetch read at
`:524` does register into `dq_data`; the host READBACK at `:837/:839` reads into
a variable, and that is the path Vivado cannot see a register on.

Neither fix is free:
- Registering the readback adds a cycle to the AXI-Lite read and changes the
  host contract in `server/fk33_seam.h`.
- Making the write full-width means buffering the low half until the high half
  arrives, which changes WHEN a half-written word becomes visible -- fine if the
  host always writes low-then-high, a silent corruption if it ever does not.

**Do not apply either without reading the host side first.**

## Measurement traps hit, added to the list

- **An attribute is a REQUEST.** This file already said that about block-design
  `CONFIG.*` properties and about URAM; it is equally true of `ram_style`, and
  this dispatcher wrote a commit message reasoning from a precedent instead of
  reading the report. **The utilization report is the only thing that says
  whether storage moved.** A bench passing says nothing -- GHDL ignores
  `ram_style` entirely, so `sim:tb_fk33_seam` PASSED both before and after a
  change that did nothing.
- **`ExploreWithRemap` made packing WORSE while making LUTs fewer.** -3,638 LUT
  recovered only 51 CLBs: it cut the LUT minimum by 455 CLBs and grew packing
  overhead by about 434. Do not assume a LUT reduction converts to CLBs at 8:1
  on this design.

---

## `desc_ram` IS block RAM now, and the fix was the output register, not the attribute

MEASURED 2026-09-16, OOC synthesis of `fk33_seam` alone (two minutes, against
an hour for a full build):

```
8-7030] Implemented Non-Cascaded Block Ram (cascade_height = 1) for RAM "fk33_seam/desc_ram_reg"
SEAMOOC_AREA lut=722 ramb36=12 ramb18=2 distram=294
```

No `8-6849`. The 9,468 LUTRAM are gone, paid for in about 13 BRAM tiles
against 235 spare.

**What actually fixed it was the OUTPUT REGISTER, not the attribute.** The
attribute had been there for a whole build cycle doing nothing. Vivado's
`8-6850` named the real requirement -- *"partial Byte Wide Write Enable pattern
... however no output register found in fanout of RAM"* -- and the host readback
read into a VARIABLE, which is not a register it can see. The descriptor-fetch
read at `:524` already registered into `dq_data`; only the readback path was
unregistered.

**It cost no AXI latency**, because the read channel already spent an idle
cycle: `rd_wait` walks 0 -> 1 -> 2 -> 3 and state 1 only advanced the counter.
The word is captured there and consumed in state 2.

**THE AUTO-INCREMENT HAZARD WAS CHECKED, NOT ASSUMED.** `WIN_ADDR`
auto-increments on every WIN_DATA access **including reads**, which would make a
one-state-early capture read against a moving address. It does not: the
read-path increment is at `:922`, inside the `rd_wait = 2` block. It is close
enough that P5 exists to catch it if that ordering ever changes.

### The cheap-verification pattern that made this tractable

An OOC synthesis of ONE entity answered "did the storage move?" in two minutes.
The previous attempt burned a full hour-long build to learn the same class of
fact. **When the question is about inference rather than about the system,
synthesise the entity, not the design.**

### Still outstanding

`ga_desc.ybw` is still LUTRAM -- `8-6849`, refused because the read is a
dynamic bit-slice of a 768-bit word. The shape that works is proved in the same
design: `gb_real.ybs` (4,096 x 16, one element per read) IS block RAM, 2 tiles,
`8-7030 Implemented Non-Cascaded Block Ram`. The fix is `A_ROWS_IF` separate
narrow memories rather than one wide one. **Not attempted yet**: `desc_ram`
alone is about 9,468 LUT against a 443 CLB shortfall (~3,544 LUT at 8:1), so it
is worth measuring before spending more.

**And the 8:1 exchange rate is not trustworthy on this design** -- MEASURED
earlier today, `ExploreWithRemap` cut 3,638 LUT and recovered only 51 CLBs. The
build now running is the measurement.

---

## THE WALL MOVES AGAIN: it places, it meets timing, and it will not ROUTE

MEASURED 2026-09-16, full `FK33_CARD=1` build at **75 MHz** with
`CB_STYLE=distributed` and `desc_ram` in block RAM.

**Synthesis:**

| | 200 MHz, desc_ram in LUTRAM | 75 MHz, desc_ram in BRAM | delta |
|---|---|---|---|
| CLB LUTs | 438,219 (99.67%) | **426,882 (97.09%)** | **-11,337** |
| LUT as Memory | 60,386 | 51,170 | -9,216 |
| Block RAM Tile | 436.5 | 449.5 | +13 |
| CLB Registers | 507,624 | 507,319 | -305 |

**Attribution, and it is not what the clock change was sold as.** The
`desc_ram` move accounts for **-9,216** of the -11,337; the drop from 200 MHz
to 75 MHz contributed only about **-2,100 LUT**. Relaxing the clock did help,
by removing timing-driven replication, but it was the SMALLER of the two
effects by a factor of four.

**PLACEMENT SUCCEEDED.** `Phase 3 Detail Placement` completed, where the
99.67% run had died inside Phase 3 at "Commit Most Macros" with
`[Place 30-487] ... 36345 CLBs required, 35902 available`. The CLB packing
wall is gone.

**TIMING IS COMFORTABLE.**

```
INFO: [Place 30-746] Post Placement Timing Summary WNS=0.051
INFO: [Route 35-416] Intermediate Timing Summary | WNS=0.222 | TNS=0.000 | WHS=-0.473 | THS=-782.452
```

Positive setup slack with zero total negative slack at 75 MHz. The clock
compromise did its job. (Hold is negative and is what routing normally fixes.)

**AND ROUTING FAILED ON CONGESTION.**

```
ERROR: [Route 35-3] Design is not routable as its global congestion level is 7.
ERROR: [Route 35-4445] route_design is terminated due to errors/critical
  warnings issued before and during initial routing.  The issues reported
  cannot be resolved later in route_design.
```

Congestion level 7 of 8. The congestion report shows the maximum region size,
**128x128, in all four directions** -- North, South, East and West -- which is
device-wide uniform density rather than a hotspot. That is what 97.09% LUT
looks like to a router.

### The unit has changed THREE times and that is the story of this file

| failure | unit | number |
|---|---|---|
| utilization DRC | LUTs | 479,919 of 439,680 (109.15%) |
| detail placement | CLBs | 36,345 of 35,902 (short 443) |
| initial routing | congestion level | 7 of 8, 128x128 all directions |

Each fix moved the failure to a different resource with a different metric, and
**none of the three is predictable from the one before it.** A LUT percentage
did not predict CLB packing; CLB packing did not predict routability. This is
the same lesson as `phys_opt` WNS not predicting routed WNS, one level up:
**every stage of this flow is its own measurement.**

### Do NOT retry

- **"It fits, so it will place."** Refuted: 99.67% LUT passed the DRC and
  failed detail placement.
- **"It places, so it will route."** Refuted here: placement completed, setup
  timing passed with margin, and initial routing refused the design outright.

### Open

- Whether congestion-directed implementation (`place_design -directive
  AltSpreadLogic_high`, `route_design -directive Explore`) closes a level-7
  global congestion. Running now, from the existing checkpoint. **Directives
  cannot manufacture routing resources**, so if uniform density is the whole
  story this will not be enough.
- `ga_desc.ybw` is still LUTRAM (`8-6849`, refused: the read is a dynamic
  bit-slice of a 768-bit word). Worth roughly 3-4k LUT. The working shape is
  proven in the same design -- `gb_real.ybs` IS block RAM at 2 tiles because it
  reads one narrow element.
- Beyond that, reducing this design below roughly 90% LUT needs a real
  architectural saving, not a lever.

---

## Congestion is NOT directive-addressable at this density

MEASURED 2026-09-16, re-implementation from the same 75 MHz checkpoint with
`place_design -directive AltSpreadLogic_high` and `route_design -directive
Explore`:

```
SPREAD_OPT_DONE
SPREAD_PLACED                      <- AltSpreadLogic_high placed successfully
ERROR: [Route 35-3] Design is not routable as its global congestion level is 7.
```

**The identical congestion level as the default directives.** Placement
succeeded both times; routing refused both times at level 7 of 8. Spreading
logic cannot manufacture routing resources, and the congestion report's
128x128 regions in all four directions said the density was uniform rather
than a hotspot -- so there was nothing for a directive to spread it INTO.

**Do not retry implementation directives for this failure.** The levers that
remain are area, and only area.

## What routing actually requires, arithmetically

Device: 439,680 CLB LUTs. Current: **426,882 (97.09%)**.

| target | LUTs | must remove |
|---|---|---|
| 92% | 404,505 | **22,377** |
| 90% | 395,712 | **31,170** |
| 88% | 386,918 | 39,964 |
| 85% | 373,728 | 53,154 |

**Everything in hand is an order of magnitude short.** `ga_desc.ybw` to block
RAM is worth roughly 3,500 LUT and is the last cheap item; `CB_STYLE`, the
clock, `desc_ram`, `ExploreWithRemap` and `AltSpreadLogic_high` are all spent.

### Where the LUTs are, for whoever picks this up

| cell | LUT | share |
|---|---|---|
| `card` (B, C, D) | 288,877 | 65.9% |
| -- `(u)` llama_top's own logic | 107,288 | |
| -- `gcr.u_attn` (C) | 84,879 (of which `u_arr` 50,591) | |
| -- `gb_real.u_gdn` (B) | 54,404 | |
| -- `gcr.gkvaxi.u_kv` | 23,986 | |
| `eng` (A) | 90,874 | 20.7% |
| infrastructure (xdma, PCIe bridges, seam, aux) | ~48,000 | 11% |

**Two parameters that LOOK like levers and are not**, both checked in the RTL
rather than assumed:
- `KV_BLOCK` is the KV cache's exponent-block FORMAT (one exponent per 32
  elements, C spec 2.1.1), not a throughput knob. `attn_mac_array.vhd:46`:
  *"ONE BLOCK PER CYCLE IS THE CACHE'S STRUCTURE, NOT A TUNING KNOB."*
- `QH_TILE` is already correct: `attn_block` passes `QH_TILE => G` where
  `G = N_QH/N_KVH`, and `model_cfg_pkg.vhd:85` selects `QWEN35_9B` (16 q / 4
  kv), so G is 4 and no lanes idle.
- `A_ROWS_IF = 48` is the A seam width, not a tuning choice
  (`gen_fk33_card.py:220`).

**A 22,000-to-31,000 LUT saving is an architectural change, not a knob.** That
is a design decision and it is where this stops being a debugging exercise.

---

## APPENDED 2026-09-16 22:57 -- THE REDUCED-SCOPE ROUTE, AND WHAT GATING SUBSYSTEM A ACTUALLY COSTS

### The question

Can a bitstream be produced at all, given the 109.15% above, by building the
card WITHOUT subsystem A? `eng` is 90,874 of the 426,882 LUT, so dropping it
should leave roughly 336,000 (about 76%).

### The answer

Yes as far as block-design validation: `FK33_ENG=0` validates with 0 errors
(`FK33_BD_VALIDATE OK`, 22:57:22). Whether it ROUTES is a separate question and
is being measured now; nothing below claims it.

**But the gate does not fall where the name suggests.** Two things that live
inside `_eng_block()` are not owned by subsystem A:

- **`core_reset`** (a `proc_sys_reset`) resets the CARD as well as the engine.
- **`axil2eng`** is the only AXI-Lite path into the core clock domain, and the
  HOST SEAM hangs off it whether or not there is an engine.

Skipping the block wholesale therefore removed subsystem D's host interface
along with subsystem A, and the first attempt died at:

```
WARNING: [BD 5-230] No cells matched 'get_bd_cells axil2eng'
ERROR:   [Common 17-55] 'get_property' expects at least one object.
```

### The procedure

1. `--bd-only` with `FK33_ENG=0`. Three minutes, ~3.3 GB. Found the error above.
   It is the cheap probe and it is the only one that runs before synthesis.
2. `grep -nE "^[^#]*\beng\b"` over the EMITTED script rather than over the
   generator, which is what found the three remaining sites. Searching the
   generator would have missed them: the emitted text is what Vivado reads.
3. `grep -n eng fk33_pcieep.xdc` separately, because the XDC is a second emitted
   artifact read at a different STAGE.
4. Byte-compare the `FK33_ENG=1` output against `git show HEAD:...`'s output, to
   prove the shipping configuration was not disturbed.
5. `--selftest` under BOTH settings, to prove the teeth still discriminate.

### Four sites, and only one of them fails early

| site | stage it fires at | what it would have done |
|---|---|---|
| `axil2eng` in `SEAM_BLOCK` | BD | the `17-55` above |
| `card/a` -> `eng/s_axi/reg0` | BD | assign_bd_address onto an absent segment |
| `set_clock_groups` in the XDC | **implementation** | `get_clocks -of_objects` on an empty object, AFTER `place_design` |
| `FK33_ENGI` clock and area checks | post-route | three checks failing on a design that is correct for its configuration |

**The XDC one is the expensive member.** Constraints are read during
implementation, so it would have aborted roughly an hour in, long after a
three-minute `--bd-only` had said the design was fine. This is the same shape
as the `--bd-only`-finds-what-no-bench-can entry in CLAUDE.md, one stage later:
**a cheap check at stage N says nothing about stage N+1, and the configuration
flag has to be honoured at every stage it reaches.**

### The trap this nearly repeated: a flag-keyed check is a vacuous check

`check_reset_topology` was gated `if not ENG_ON: return`. That is defensible --
the hazard it guards (STRAY-NEXTJOB) only exists when the engine exists -- and
it is also exactly how its ten teeth rows become **vacuous** under
`FK33_ENG=0`: every mutation accepted, table still printing GREEN.

It now decides from the SCRIPT TEXT (`create_bd_cell -type module -reference
fk33_engine`), which is the definition of the engine being present and cannot
be confused with the wiring the check tests -- deleting a `connect_bd_net`
leaves the creation line in place. MEASURED under both settings:

```
T1..T7  REFUSED     (the seven real hazards)
T8, T9  accepted    (the two deliberately-safe topologies)
T0      accepted    (the unmutated control)
```

Similarly, the 28 SAXI ports are now checked against `false` with no engine
rather than skipped: **an enabled port with no master is not inert** -- its
ACLK and ARESET_N reach HDL generation undriven and fail with `41-758`.

### Evidence

```
FK33_ENG present=0 card=1
FK33_ENG portcheck bad=0 (must be 0)
FK33_ENG absent: no masters, no compute_halt consumer, no thermal throttle path
FK33_CARD card/a maps nothing: unit A is absent and every A job hangs
FK33_SEAM CAPS_VOCAB = 0 / CAPS_EMBD = 0 / CAPS_LAYER = 0 / CAPS_CTX = 0
FK33_BD_VALIDATE OK
FK33_BD_ONLY_DONE
errors: 0
```

The pins Vivado ties to 0, which is the honest statement of what is missing:

| build | tied-off inputs |
|---|---|
| card + engine | `bst_state_base`, `a_arena_base` |
| card, no engine | those two, plus `a_y_we`, `a_y_addr`, `a_y_data`, `a_y_mask`, `a_y_exp`, `a_job_done`, `a_job_err` |

`a_job_done` tied low is the concrete form of "an A job never completes".
**`bst_state_base` and `a_arena_base` were ALREADY tied to 0 in the engine-on
build** -- a pre-existing gap, not something this configuration introduced, and
worth its own look.

Critical warnings, with the engine-on card build as the control:

| class | card + engine (validated, placed, met 75 MHz) | card, no engine |
|---|---|---|
| `41-1377` HBM address aliasing | 32 | 32 |
| `41-1356` unassigned slave segment | 128 | 64 |

Both pre-existing. The `41-1356` halving is what dropping 28 master address
spaces should do.

### Measurement traps hit

- **`grep -o 'FK33_BD_VALIDATE[A-Z ]*'` reported FAIL on runs that PASSED.**
  The log contains the script that writes it, so the first match was the
  emitter's own `puts "FK33_BD_VALIDATE FAIL: $verr"` line. This is the
  line-anchored-sentinel rule in CLAUDE.md, hit for the fourth recorded time.
  Anchored (`^FK33_BD_VALIDATE`), both earlier card runs printed OK.
- **Indentation leaked into the emitted Tcl** on the first attempt at gating
  `ENGINE_ADDR`, because the payload was indented inside an `if`. Moving it to
  a module-level constant restored byte-identity. A generator's Python
  structure is not free: it shows up in the artifact.

### Measured and REJECTED -- do not retry

- **Gating `_eng_block()` as a unit.** It takes `core_reset` and `axil2eng`
  with it and breaks subsystem D's host interface. Split at the boundary of
  what subsystem A actually owns.
- **Leaving the 28 SAXI ports enabled with no engine.** `41-758` at HDL
  generation; the ports must go back to disabled, which is why the
  `SAXI0_OLD`/`SAXI1_OLD` substitutions become identities rather than being
  skipped.
- **Keying `check_reset_topology` on `ENG_ON`.** Vacuous teeth, green table.

### Open, not yet answered

- **Whether it routes.** 336,000 LUT is an ESTIMATE by subtraction; the real
  post-synthesis number is not in hand, and the failure unit has changed three
  times already in this investigation (LUT, then CLB, then congestion level).
- `ga_desc.ybw` is still LUTRAM, worth roughly 3,500 LUT, and is unaffected by
  any of this.
- Subsystem A's own gaps are untouched: `ga_desc` has no value coverage, and
  the `x_exp` divergence between the two A arms is unexplained.
