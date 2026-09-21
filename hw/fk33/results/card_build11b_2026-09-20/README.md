# Build 11b, 2026-09-20: the per-row codebook cost **+44,073 CLB LUTs**, and the netlist got BIGGER, not smaller

TRACK PLACEDIFF. Placed area only. The routed-path attribution is queued
separately and is deliberately not done here.

## The question, verbatim

> Build 11b placed at **WNS -5.136, TNS -236,998**. Build 10 placed at
> **+0.421 / 0.000** and build 9 at **+0.533 / 0.000**. Build 11b carries two
> changes over build 9: `FAST_POP` and the per-row codebook. Three hypotheses
> are live: (1) the codebook change, (2) `FAST_POP`, (3) TRACK CBOOC's, *"the
> placer's response to a netlist 19,344 flops smaller at 99.81% occupancy"*.
> Hypothesis 3 is partly testable right now with no synthesiser.

## The answer, up front

**Hypothesis 3's PREMISE is refuted. Build 11b's netlist is not smaller; it is
44,073 CLB LUTs LARGER, and the growth is the codebook's own geometry.**

MEASURED, `utilization_placed.rpt` of each build, same tool, same device, same
`Design State : Fully Placed`:

| | build 10 | build 11b | delta |
|---|---|---|---|
| CLB LUTs | 361,361 (82.19%) | **405,434 (92.21%)** | **+44,073** |
| F8 Muxes | 6,027 | **18,315** | **+12,288** |
| F7 Muxes | 28,422 | **53,022** | **+24,600** |
| LUT as Distributed RAM | 64,478 | 52,174 | **-12,304** |
| CLB Registers | 308,213 | 296,396 | **-11,817** |

**DERIVED, and the fit is exact on one resource:** `MUXF8 +12,288 = 1,536 x 8`
to the unit, where 1,536 is `CB_COPIES` at the card geometry and 8 is the
codebook data width. `MUXF7 +24,600` against `1,536 x 16 = 24,576`. The
distributed-RAM primitives that vanished split **14 RAMD32 : 2 RAMS32 per
copy**, which is exactly one `RAM32M16` -- the primitive CLAUDE.md already
records `cb[0][0]` mapping to.

**The codebook array `cb` stopped being distributed RAM and became a 16:1
combinational mux tree, 1,536 times over.** That is 4 LUT6 + 2 MUXF7 + 1 MUXF8
per output bit, replacing 1 RAM32M16 per copy.

**Hypothesis 1 is strongly supported on AREA.** L-CB's scope column reads "no
synthesis at all"; this is the first time that RTL met a synthesiser and it
cost 44,073 LUTs.

**CBFANOUT's prediction is falsified by its OWN registered falsifier.**
`docs/WORKLOG.md:19` says *"If LUT moves, the folding argument is wrong."*
LUT moved by +44,073.

---

## Tree identity, asserted rather than inferred

Both reports were read as files, not as filenames:

    build 10  Date: Sun Sep 20 14:39:59 2026   Vivado v.2023.2 Build 4029153
    build 11b Date: Sun Sep 20 20:26:04 2026   Vivado v.2023.2 Build 4029153
    both      Device: xcvu33p-fsvh2104-2L-e  Speed File: -2L
              Design: bd_wrapper  Design State: Fully Placed

Build 11b's copy is byte-identical to its source in the live tree
(md5 `47c4e5e6d1f8bfe7fca22860fa8dc877` at both ends), copied read-only out of
`/mnt/storage/fk33_builds/build11b/root/fk33_pcieep/fk33_pcieep.runs/impl_1/`
and committed BEFORE any analysis, because `BUILD_ROOT` is reused and TRACK
BUILDREPORT MEASURED that nothing has ever copied these out.

Build 11b's source tree is recorded by the build itself:
`FK33_TGROOT /mnt/storage/fk33_builds/wt11`, a worktree at commit **`5dc3ee5`**
with `hw/fk33/build_fk33_pcieep.tcl` and `hw/fk33/build_fk33_i2cprobe.tcl`
modified. Build 10 predates the `FK33_TGROOT` sentinel and **records no source
tree at all**; its commit is not established by this analysis.

---

## What ACTUALLY differs between the two builds, from their own recorded parameters

Not from what either build was for. This matters, and it is not two changes.

### RTL / configuration

| | build 10 | build 11b |
|---|---|---|
| base | build 9 (`card_kvreg`) | build 9 (`card_kvreg`) |
| KV-base seam register | **yes** | no |
| PIPE, WIDE, MAXOUT8, NWIDE on `u_state` | **yes** | no |
| `FAST_POP` | no | **yes** |
| per-row codebook (`CB_RANKS = 48`) | no | **yes** |

**Seven changes, not one.** Going 10 -> 11b REMOVES five things and ADDS two.

### Implementation, and all three directives differ

MEASURED from each build's own log:

| | build 10 | build 11b |
|---|---|---|
| `opt_design` | (no directive) | (no directive) |
| `place_design` | `AltSpreadLogic_high` | `ExtraPostPlacementOpt` |
| `phys_opt_design` | `AggressiveExplore` | `Explore` |
| `route_design` | `AlternateCLBRouting` | `Explore` |
| strategy sentinel | none in the retained tail | `Performance_RefinePlacement` |
| pblock | `FK33_PBLK pb_core CLOCKREGION_X0Y0:CLOCKREGION_X6Y3` | `FK33_PBLK fk33_pblock.xdc added, implementation only`; `pb_core` present |

**This is the build-10 postmortem's own recorded failure, waiting to happen
again**: a pair of runs compared as a one-variable experiment when five
implementation parameters differ. Naming it here so nobody reads the CLB row as
a codebook result.

### Which stage each claim lives at, which is what rescues most of the table

`opt_design` ran bare in both, so **the primitive census is a synthesis result
and the differing placer directive cannot touch it.** Proved directly rather
than argued: build 11b's own **synthesis-stage** report
(`utilization_synth.rpt`, committed here) already carries
**`MUXF8 = 18,315`, identical to the placed 18,315**, with `MUXF7 = 53,029`
and `RAMD32 = 40,326`. The mux tree exists before `opt_design` and before the
placer.

So:

* **ADMISSIBLE as netlist facts**: LUT6, MUXF7, MUXF8, RAMD32, RAMS32, FDRE,
  CARRY8, DSP48E2, RAMB*, URAM288 counts.
* **CONFOUNDED by the directive difference**: the **CLB** row and packing
  density, which are placement results. Read them with that attached.

---

## The full resource table, MEASURED

Source files: `hw/fk33/results/card_build10_FAILED_2026-09-20/utilization_placed.rpt`
and `hw/fk33/results/card_build11b_2026-09-20/utilization_placed.rpt`.
`card_swg` is shown for context ONLY and no delta is taken against it; it is a
different build and that borrowing is what the build-10 postmortem had to
withdraw.

### Site types

| site type | card_swg | build 10 | build 11b | 11b - 10 |
|---|---|---|---|---|
| CLB LUTs | 363,095 | 361,361 | **405,434** | **+44,073** |
| LUT as Logic | 297,323 | 295,786 | **352,163** | **+56,377** |
| LUT as Memory | 65,772 | 65,575 | 53,271 | **-12,304** |
| LUT as Distributed RAM | 64,674 | 64,478 | 52,174 | **-12,304** |
| LUT as Shift Register | 1,098 | 1,097 | 1,097 | **0** |
| CLB Registers (FF) | 308,981 | 308,213 | 296,396 | **-11,817** |
| CARRY8 | 12,592 | 12,597 | 12,572 | -25 |
| F7 Muxes | 28,528 | 28,422 | **53,022** | **+24,600** |
| F8 Muxes | 6,107 | 6,027 | **18,315** | **+12,288** |
| F9 Muxes | 0 | 0 | 0 | 0 |
| **CLB** | 54,854 (99.81%) | 54,751 (99.62%) | **54,822 (99.75%)** | **+71** |
| CLBL / CLBM | | 29,130 / 25,621 | 29,169 / 25,653 | +39 / +32 |
| Block RAM Tile | 567 | 595 | 598 | +3 |
| RAMB36/FIFO | 540 | 512 | 516 | +4 |
| RAMB18 | 54 | 166 | 164 | -2 |
| URAM | 32 | 32 | 32 | **0** |
| DSPs | 2,087 | 2,087 | 2,087 | **0** |
| Global clock buffers | | 24 | 25 | +1 |

### Primitive census (Ref Name), which is the netlist and not the placement

| ref name | build 10 | build 11b | delta |
|---|---|---|---|
| FDRE | 302,373 | 290,566 | -11,807 |
| FDSE | 3,126 | 3,140 | +14 |
| FDCE | 2,355 | 2,333 | -22 |
| FDPE | 359 | 357 | -2 |
| *(all FF)* | *308,213* | *296,396* | ***-11,817*** |
| LUT6 | 130,880 | **186,555** | **+55,675** |
| LUT5 | 52,705 | 52,969 | +264 |
| LUT4 | 42,818 | 42,663 | -155 |
| LUT3 | 50,940 | 50,555 | -385 |
| LUT2 | 60,522 | 60,541 | +19 |
| LUT1 | 9,851 | 9,782 | -69 |
| MUXF7 | 28,422 | **53,022** | **+24,600** |
| MUXF8 | 6,027 | **18,315** | **+12,288** |
| RAMD32 | 61,232 | 39,704 | **-21,528** |
| RAMS32 | 8,236 | 5,156 | **-3,080** |
| RAMD64E | 29,678 | 29,678 | **0** |
| RAMS64E | 36 | 36 | **0** |
| CARRY8 | 12,597 | 12,572 | -25 |
| SRL16E | 1,439 | 1,439 | **0** |
| SRLC32E | 141 | 141 | **0** |
| DSP48E2 | 2,087 | 2,087 | **0** |
| URAM288 | 32 | 32 | **0** |
| HBM_SNGLBLI_INTF_AXI | 32 | 32 | **0** |
| RAMB36E2 / RAMB18E2 | 512 / 166 | 516 / 164 | +4 / -2 |
| BUFGCE | 15 | 16 | +1 |

---

## The control, and it did not move

Nominated **before** the numbers were read (see "registered expectation"): the
hard blocks and fixed infrastructure that neither build's changes touch.

MEASURED, identical to the digit in both reports:

    DSP48E2               2,087  =  2,087
    URAM288                  32  =     32
    HBM_SNGLBLI_INTF_AXI     32  =     32
    RAMD64E              29,678  = 29,678
    RAMS64E                  36  =     36
    SRL16E                1,439  =  1,439
    SRLC32E                 141  =    141
    LUT as Shift Register 1,097  =  1,097
    RAMS64E / IBUF_ANALOG / BUFG_GT / OBUF   all identical

`RAMD64E = 29,678` is the strongest of these: it is the **other**
distributed-RAM family, so a 24,608-primitive collapse in RAMD32/RAMS32 beside
an exactly-unchanged RAMD64E says the change is localised and not a
design-wide RAM-inference shift. (It is also the argument against `card_swg`:
that build reads 30,318, so the control *does* move against `card_swg` and does
*not* move against build 10.)

**One control DID move and I did not predict it: `BUFGCE 15 -> 16`.** A global
clock buffer appeared. That is a clocking-infrastructure difference between the
two builds which nothing in the seven changes above accounts for, and it is
recorded here as unexplained rather than absorbed.

---

## The registered expectation, and the result

Written to `/mnt/storage/fk33_builds/scratch/placediff/REGISTERED_EXPECTATION.txt`
**before** the report was opened, and not adjusted afterwards.

| # | registered | measured | verdict |
|---|---|---|---|
| 1 | FF delta in the band **-17,000 to -22,000**, centred -19,344 | **-11,817** | **WRONG. Outside the band.** |
| 2 | `abs(LUT delta) < 10,000`, sign most likely negative | **+44,073** | **WRONG, and by 4.4x the stated bound, in the opposite sign** |
| 3 | CLB between 53,500 and 54,800; occupancy stays above 97% | **54,822**, 99.75% | occupancy right, count **above** the band |
| 4 | BRAM / DSP / URAM / MUXF7 / MUXF8 / CARRY8 deltas ~0 | DSP 0, URAM 0, CARRY8 -25, BRAM +3, **MUXF7 +24,600, MUXF8 +12,288** | **WRONG on the mux rows, by a very large margin** |
| 5 | "not a one-variable comparison" | confirmed: 7 RTL/config changes + 3 differing directives + a pblock difference | **right, and it was worse than I wrote** |
| 6 | hard-block control does not move | held, except BUFGCE +1 | mostly right |

**I was wrong on the thing the brief asked me to predict, and wrong in the
direction that mattered.** The prediction assumed the codebook change was an
FF-only edit, because every document describing it says so. Nothing in the
tree had ever synthesised it.

---

## Hypothesis 3, tested as far as the data allows

CBOOC's hypothesis: *"the placer's response to a netlist 19,344 flops smaller
at 99.81% occupancy."*

**The premise is REFUTED.** MEASURED:

* the netlist is **11,817 flops smaller**, not 19,344, and
* it is **44,073 CLB LUTs and 36,888 mux primitives LARGER**.

LUT occupancy went **82.19% -> 92.21%**, a ten-point jump on the resource that
was already the design's largest. So the question "why did a smaller netlist
place worse" does not arise in the form asked. The netlist grew.

**What the hypothesis was right about, and this is not a small thing**: it
predicted that the answer would be invisible to every instrument short of an
implementation, and it was. CBOOC's own OOC harness holds `CB_STYLE` constant
and draws `matvec_int4_desc_axi`; this effect is 1,536 copies inside
`matvec_core` and it took a card build to see it.

**Not refuted, and still open**: whether the placer's *response* to the grown
netlist is what produced -5.136, or whether the mux trees are themselves on the
critical path. That is a routed-path question and is not answered here.

---

## The CLB occupancy, which the brief asked for specifically

**MEASURED: build 11b placed at 54,822 CLB of 54,960 = 99.75%, with 138 tiles
free.** Build 10: 54,751 = 99.62%, 209 free.

**The codebook fix freed no CLBs. It consumed 71 more.**

`docs/LEVERBOARD.md` section 4.2 bounded the CLBs freed by `-19,344 FF` at
**lower 0, upper 1,209**. The measured value is **-71 freed**, i.e. outside the
interval on the low side. That bound is not withdrawn as arithmetic -- it was a
correct bound on the FF term. It is that **the FF term was never the whole
change**, and a bound derived from one resource says nothing once a second
resource moves by 44,073.

The `+71` is confounded by the differing placer directive and is the weakest
number in this document. **The 99.75% and the 138 free tiles are not
confounded in the way that matters**: whatever directive placed it, the design
fits the part with 0.25% of its CLBs spare while carrying ten points more LUT
occupancy than build 10 did.

### A correction to the brief's framing, and to LEVERBOARD section 8

The brief says *"Build 9 sat at 99.81%, 106 tiles free of 54,960."*

**That figure is `card_swg`'s, not build 9's.** MEASURED:
`card_swg_2026-09-20/bd_wrapper_utilization_placed.rpt` reads
`CLB 54,854 / 54,960 = 99.81%` (106 free). And build 9 has **no placed report
of any kind**: `ls hw/fk33/results/card_kvreg_2026-09-20/` contains no `.rpt`,
and `grep -c 'CLB LUTs' .../build.stdout` returns **0** -- which is exactly
what the build-10 postmortem's CORRECTION already established and why it had no
control. LEVERBOARD section 8 item 1 states the attribution correctly
("54,854 (card_swg)"); the brief collapsed it onto build 9.

---

## The mechanism, DERIVED, with the arithmetic shown

Per codebook copy at the card geometry: 16 entries x 8 bits, `CB_COPIES = 1,536`.

**Build 10 (as RAM32M16, one per copy):** 14 RAMD32 + 2 RAMS32 = 16 primitives,
occupying 8 LUT sites (2 primitives share one site via O5 and O6).

    predicted removal   1,536 x 14 = 21,504 RAMD32    measured -21,528  (+24)
                        1,536 x  2 =  3,072 RAMS32    measured  -3,080   (+8)
                        total      = 24,576 prims     measured -24,608  (+32)
                        LUT sites  = 12,288           measured -12,304  (+16)

The LUT-site figure is internally exact: the report's
`LUT as Distributed RAM / using O5 and O6` row fell **34,704 -> 22,400 =
-12,304** while `using O6 only` is **29,774 in both builds, unchanged**. Every
removed site was a dual-output one, two primitives each.

**Build 11b (as a 16:1 mux tree, one per output bit):** on UltraScale+ a 16:1
mux is 4 x LUT6 + 2 x MUXF7 + 1 x MUXF8.

    predicted addition  1,536 x 8 x 1 = 12,288 MUXF8   measured +12,288  (EXACT)
                        1,536 x 8 x 2 = 24,576 MUXF7   measured +24,600   (+24)
                        1,536 x 8 x 4 = 49,152 LUT6    measured +55,675 (+6,523)

MUXF8 lands **to the unit**. MUXF7 to 0.1%. LUT6 carries the residual, which is
expected: five other changes also move LUT6, and MUXF7/MUXF8 are the resources
almost nothing else in this design uses at scale.

**Nothing else in the design has the shape `1,536 x 8`.** None of build 10's
five removed levers is in subsystem A's `matvec_core` cone. That fingerprint is
what makes the attribution admissible despite the seven-change confound, and it
is the only reason it is.

### What the FF number does NOT allow

A naive reading -- "`cb` became registers plus a mux" -- is **ruled out by this
report**. Registers would need `1,536 x 16 x 8 = 196,608` flip-flops. FF went
**down** by 11,817. So the 196,608 bits of codebook content are neither in
flip-flops nor in the distributed RAM that vanished.

A reconciliation that fits the numbers, offered as **ESTIMATE and not
established**: the command registers fall by 19,344 as predicted, storage
collapses to a per-rank bank of `48 x 16 x 8 = 6,144` flops, and the net is
`-19,344 + 6,144 = -13,200`, against a measured -11,817 with +1,383 left for
the other six changes. This is the same decomposition
`docs/debugging/2026-08-30_cbinfer-does-cb-infer-lutram.md:323` writes as
`19,344 - 6,144 = +13,200` for lever C, read backwards. **It is arithmetic that
fits, not evidence.** It has one free parameter and one data point, which this
project has already recorded as the shape of a model that cannot be wrong about
its own point and cannot be right about any other.

---

## What this establishes

1. **MEASURED: build 11b's placed netlist is +44,073 CLB LUTs, +24,600 MUXF7,
   +12,288 MUXF8, -12,304 LUT-as-distributed-RAM and -11,817 FF against build
   10**, at 92.21% LUT and 99.75% CLB occupancy with 138 tiles free.
2. **DERIVED, with an exact fit on MUXF8 and a 14:2 RAM32M16 signature: the
   codebook array stopped being distributed RAM.** This is an area result for
   L-CB, which previously had none of any kind.
3. **The growth is a SYNTHESIS result, not a placement one**, proved by build
   11b's own synthesis-stage report carrying the identical `MUXF8 = 18,315`.
   The differing placer directive does not reach it.
4. **CBFANOUT's `delta LUT = 0` is falsified by its own registered falsifier.**
5. **Hypothesis 3's premise is refuted**: the netlist is larger, not smaller.
6. **Hypothesis 1 is supported on area.**
7. **LEVERBOARD's L-CB row must be updated**: `-19,344 FF` is DERIVED and
   remains untested; `LUT delta UNKNOWN, not drawn` is now **known and large**.
   The row's "0 cycles, neither slope nor intercept, HIGH that it is safe"
   assessment was about VALUES and remains untouched by this. Its **cost** was
   never drawn and is not zero.

## What this CANNOT establish

* **It cannot test `-19,344 FF`.** That prediction is against **build 9**, and
  build 9 committed no placed report. This pair differs by seven RTL changes,
  so the measured -11,817 bounds nothing about the codebook's FF term alone.
  CBFANOUT's central number is **neither confirmed nor refuted** by this file.
* **It cannot attribute the CLB `+71` to anything.** Three implementation
  directives differ.
* **It says nothing about `FAST_POP`.** Its OOC figure (+1 LUT, 0 FF) is not
  contradicted here and is not confirmed here. This pair cannot separate it,
  and a +1 LUT term is far below this comparison's resolution.
* **It does not explain WNS -5.136.** That +44,073 LUT is the cause is a
  plausible mechanism and an ESTIMATE, nothing more. Build 10 failed at -5.819
  with 82.19% LUT occupancy, which is itself proof that this design can fail
  timing badly without a LUT explosion.
* **It does not identify the RTL line.** The mechanism above is inferred from
  a primitive census, not from reading the synthesiser's inference decision on
  `cb`. Build 11b's log carries **no RAM-inference message naming `cb` at
  all** (the 101 `[Synth 8-7186]` warnings in it are `qbuf` in
  `rtl/gdn_block.vhd`, subsystem B, and unrelated); build 10's retained log is
  a **3 MB tail** that does not reach the synthesis phase, so that comparison
  is one-sided and was not made.

## Open, not determined

1. **Why `cb` stopped inferring as RAM.** A census is not an inference log.
   The suspect is the write address becoming `cbw_a(cb_rank_of(c))` -- a
   function of the loop variable inside the address expression -- but that is
   an ESTIMATE from reading `rtl/matvec_core.vhd:804-807` and no controlled
   draw was run. **One OOC synthesis of `matvec_core` at `a4828ab` against
   `5dc3ee5`, at the card geometry, settles it and costs minutes.** That is
   TRACK CBOOC's harness and it holds `CB_STYLE` constant, which is the right
   control.
2. **Where the 196,608 bits of codebook content live in build 11b.** Not FFs,
   not the vanished LUTRAM. Unresolved.
3. **Whether the LUT growth is what broke timing**, or whether the codebook's
   new mux tree is itself on the critical path, or neither. Routed question.
4. **Build 9's placed area.** Still unknown, still the control that would
   settle the most, still not recoverable.
5. **`BUFGCE 15 -> 16`.** Unexplained.
6. **Whether removing build 10's five levers had any material area term.**
   Never isolated, in either direction.
7. **`CARRY8 -25`, `BRAM +3`, `RAMB18 -2`.** Small, unattributed, not chased.

## Artefacts committed here

    utilization_placed.rpt    build 11b placed utilization, byte-identical to
                              the build tree (md5 47c4e5e6d1f8bfe7fca22860fa8dc877)
    utilization_synth.rpt     build 11b synthesis-stage utilization, which is
                              what proves the mux tree predates the placer
    README.md                 this file

The registered expectation is at
`/mnt/storage/fk33_builds/scratch/placediff/REGISTERED_EXPECTATION.txt`;
its content is reproduced in the table above and was not edited after the
report was read.
