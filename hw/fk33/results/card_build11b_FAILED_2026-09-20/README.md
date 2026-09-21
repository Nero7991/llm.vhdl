# Build 11b: FAILED. It did not miss timing, it failed to ROUTE.

FK33_CARD=1 card build, launched 2026-09-20 19:00, ended 23:25 (4h25m).
`write_bitstream` refused. The card is untouched and still runs build 9's
bitstream at 2.46 tok/s.

Placed-stage area analysis of the same build lives in
`../card_build11b_2026-09-20/` (TRACK PLACEDIFF). This directory holds the
ROUTED outcome and the congestion evidence.

## The answer, up front

**The per-row codebook (`0b34200`) exhausted the interconnect.** Vivado's own
signal-overlap table names the contending nets, and 38 of the 40 named nets are
`bd_i/eng/inst/eng/dut/core/cb[][][]`.

**FAST_POP is not exonerated by this.** It is simply absent from the congestion
evidence, which is a different statement. Build 11b carried both changes and no
single-lever control was run, so this directory convicts one lever and clears
nothing.

## Read this before quoting any number from `timing_summary_routed.rpt`

`route_design` printed **`completed successfully`** and the log contains
**`Number of Unrouted Nets = 0`**. Both are literally true and both mislead: a
net with a resource conflict counts as routed. `report_route_status` is the
authority.

```
   # of logical nets.......................... :     2664048 :
       # of nets not needing routing.......... :     1994832 :
       # of routable nets..................... :      669216 :
           # of fully routed nets............. :      522268 :
       # of nets with routing errors.......... :      146948 :
           # of nets with resource conflicts.. :      146948 :
```

22.0% of routable nets overlap each other, and
`CRITICAL WARNING: [Route 35-162] 146948 signals failed to route due to routing
congestion`.

The routed timing summary reports **WNS -9.762 / TNS -884,687.062 / 495,864
failing endpoints of 1,382,636**, with WHS -0.025 and 50 hold failures. Those
delays are computed over overlapping routes. **They are not a slack measurement
and must not be compared with build 9's +0.061 or build 10's -5.819, which are
legal routes.** The comparable fact is categorical: builds 9 and 10 routed,
build 11b did not. Three intermediate figures tracked during the run (post-place
-5.136 / -236,998, routing iteration 1 -4.491 / -202,959) are likewise
pre-legality numbers and this project already records that nothing before a
clean `route_design` orders two runs correctly.

## Per-clock split, Intra Clock Table

The failure is entirely on the core clock; everything else is noise.

| clock | period | WNS | TNS | failing endpoints | total |
|---|---|---|---|---|---|
| **clk_out3** (core) | 13.333 ns | **-9.762** | **-884,240.500** | **494,527** | 1,147,256 |
| fk33_dmabram_BRAM_PORTA_CLK | | -1.441 | -357.663 | 1,056 | 202,634 |
| sysref_clk | | -1.005 | -85.013 | 261 | 21,624 |
| pipe_clk | | -0.087 | -0.278 | 5 | 2,420 |
| clk_out1 | | +4.330 | 0.000 | 0 | 1,839 |

clk_out3 holds 99.95% of the design's TNS. Note 1,147,256 core-clock endpoints
here; an earlier session quoted 672,531 for "build 9", which is a figure from
the 200 MHz ENGINE-ONLY pcieep build and does not belong to any card build.

## What convicts the codebook

`Phase 8 Verifying routed nets` prints the top ten physical nodes with signal
overlaps and the nets contending for each. Counting every net named across all
ten nodes (`signal_overlaps.txt`):

```
     38 bd_i/eng/inst/eng/dut/core/cb[][][]
      1 bd_i/jtag_axil/inst/jtag_axi_engine_u/cmd_valid_wr_ch
      1 bd_i/eng/inst/eng/dut/core/xq_reg_0_1_84_97/DOE1
```

Verbatim, node 1 of 10:

```
1. (238,181,3) NODE_PINBOUNCE Hist: 6 Tile Name: INT_X43Y64 Node: BOUNCE_E_2_FT1 Overlapping Nets: 4
	CLEL_R_X43Y63
		InstTerms:
		bd_i/eng/inst/eng/dut/core/tr_reg[1][135]_i_37/I0
		bd_i/eng/inst/eng/dut/core/tr_reg[1][135]_i_38/I5
Nets:
bd_i/eng/inst/eng/dut/core/cb[4][3][4]
bd_i/eng/inst/eng/dut/core/cb[4][2][4]
bd_i/eng/inst/eng/dut/core/cb[4][4][4]
bd_i/eng/inst/eng/dut/core/cb[4][10][4]
```

The loads are `core/tr_reg[...]_i_NN` LUTs, which is the mux tree `cb` becomes
when it is not inferred as RAM. Congestion reached **level 6 global/short and
level 7 effective in three of four directions**, where the tool's own threshold
for "can reduce routability" is 5, and
`WARNING: [Route 35-447] Congestion is preventing the router from routing all
nets` fired before routing began in earnest.

This is Vivado naming the object. The project's standing rule is that when a
report names the object, no argument about a total is admissible.

## The worst-path list does NOT agree with that, and here is why it cannot

The ten worst paths on clk_out3 are all one startpoint, and it is not the
codebook:

```
-9.762  u/gcr.gkvaxi.u_kv/GEN_RD[0].r_beat_reg[5]/C -> .../hdr_r_reg[0][47]/D
-9.571  u/gcr.gkvaxi.u_kv/GEN_RD[0].r_beat_reg[5]/C -> .../mbank_reg[0][5][116]/CE
```

`report_timing_summary` samples ten paths per group, so this list describes 65
paths out of 494,527 failing endpoints. **It is not an attribution and it is
not evidence against the congestion table.** In a design with 146,948
conflicted nets the worst single path is wherever the conflict happened to land
hardest, and C's KV AXI reader has an unrelated known structure (one register
fanning to a bank of clock enables). Treating a ten-path sample as the owner of
half a million endpoints is the error this project has recorded as reasoning
from a total instead of a census.

## Area, placed stage, against build 10 -- a MULTI-VARIABLE comparison

| metric | build 10 | build 11b | delta |
|---|---|---|---|
| CLB | 54,751 (99.62%) | 54,822 (**99.75%**) | +71 |
| CLB LUTs | 361,361 | 405,434 | +44,073 |
| LUT as Logic | 295,786 | 352,163 | +56,377 |
| LUT as Memory | 65,575 | 53,271 | -12,304 |
| CLB Registers | 308,213 | 296,396 | -11,817 |
| F7 Muxes | 28,422 | 53,022 | +24,600 |
| **F8 Muxes** | **6,027** | **18,315** | **+12,288** |
| CARRY8 | 12,597 | 12,572 | -25 |
| BRAM tile | 595 | 598 | +3 |
| **DSP** | **2,087** | **2,087** | **0** |
| URAM | 32 | 32 | 0 |

The shape is unmistakable: memory LUTs and flops went DOWN while logic LUTs and
mux primitives went UP. That is an array ceasing to be distributed RAM and
becoming a mux tree.

**MUXF8 +12,288 is exactly TRACK CBRAM's pre-registered prediction of
`MUXF8 0 -> 12,288`.** A pre-registered exact hit is worth more than the delta
itself, and CBRAM registered it before this report existed.

**DO NOT quote +44,073 LUT as the codebook's cost.** Read from the two runs'
own recorded parameters rather than from what they were launched to be:

| | build 10 | build 11b |
|---|---|---|
| commit | `b71a6d9` | `5dc3ee5` (child of `0b34200`) |
| source tree | **the LIVE repo** | detached worktree `wt11` |
| `FAST_POP` | **false** | **true** |
| codebook | old (`0b34200` NOT an ancestor) | per-row |
| RTL files changed between them | 5 (`attn_block.vhd` +556, `attn_score_q12.vhd` +217, `matvec_core.vhd`, `fk33_engine.vhd`, `ooc_gdnadapt_top.vhd`) | |

Two live variables, five changed RTL files, and build 10 read the live tree so
its exact input is not recoverable from a commit. DSP identical to the digit and
URAM identical are genuine controls at this stage and are what make the shape
argument usable at all, but they do not make the magnitude attributable. The
clean per-lever number has to come from the OOC A/B, not from here.

`SWEEP_PIPE` and `SCORE_EARLY` were NOT in build 11b. Checked properly: they
have zero occurrences in `rtl/llama_top.vhd` and `rtl/fk33_llama_top.vhd` in
`wt11`, AND `rtl/attn_block.vhd:259,285` declare both `:= false`, so the
missing override leaves them off rather than taking an unknown default.

## Not determined

- **The codebook's own area and routability cost in isolation.** Every figure
  above is confounded with FAST_POP.
- **FAST_POP's contribution to anything.** Cleared FUNCTIONALLY at three levels
  on 2026-09-20 (POPCOVER, POPPORT, DESCARM); none of those is an area or
  timing result, and it has never been built alone on the card.
- **What share of the 146,948 conflicts belongs to `cb`.** The overlap table is
  the top ten nodes, not a census. 38 of 40 is a consistent sample, not a
  proportion.
- **Whether reverting the codebook is sufficient.** Build 9 routed at +0.061
  with the old codebook and FAST_POP false. Build 12 proposes to add FAST_POP,
  SWEEP_PIPE and SCORE_EARLY on top of a revert, and none of those three has
  ever been placed on this card.
- **Hypothesis (c), the placer's response to a 19,344-flop-smaller netlist at
  99.8% occupancy, is neither confirmed nor refuted.** Flops did fall
  (-11,817 measured, against -19,344 DERIVED for the codebook alone), and
  smaller is not automatically better at this occupancy. Nothing here isolates
  it.

## Memory, for the record

Never the constraint. Swap flat at 13G for the whole run, MemAvailable 11,966
to 13,814 MB, `Memory (MB): peak = 15012.328` at route, lowest free physical
1,586 MB. The `MemoryHigh=24G` cap was never approached and the swap guard
never fired.

## Files

| file | what |
|---|---|
| `route_status.rpt` | the authority on the failure |
| `congestion_report.txt` | levels, hotspots, the 35-447 and 35-448 messages |
| `signal_overlaps.txt` | the top-ten overlap table naming `cb` |
| `timing_summary_routed.rpt.gz` | full routed timing, read the caveat above |
| `utilization_placed.rpt` | placed area |
| `errors_and_critical_warnings.txt` | deduplicated |

Checkpoints (synth, placed, routed) with sha256sums are preserved outside the
repo at `/mnt/storage/fk33_builds/KEEP_build11b_dcp/`.

---

# CORRECTION 2026-09-21: THE CAUSE WAS `CB_STYLE=regs`, NOT `0b34200`. THE CODEBOOK COMMIT WAS A NO-OP IN THIS BUILD.

Appended in place. Nothing above is deleted, because it was committed and
reported.

**WITHDRAWN: the claim at the top of this file that "the per-row codebook
(`0b34200`) exhausted the interconnect."**

**Build 11b was synthesised at `CB_STYLE=regs`. Builds 9 and 10 were at
`distributed`.** MEASURED by two independent instruments across all three
builds (TRACK CBREVERT, `1cc7cbf`):

- the line-anchored `^FK33_CB_STYLE` sentinel: present for 9 and 10, **absent
  for 11b** (1 / 1 / 0)
- Vivado's own `Parameter CB_STYLE bound to`: `distributed` x4, `distributed`
  x4, **`regs` x4**. `build11b/build.stdout:6788` reads
  `Parameter CB_STYLE bound to: regs`, with `:6789`
  `done synthesizing module 'matvec_core'`.

At `regs`, `rtl/matvec_core.vhd`'s own `cb_dt_f`/`cb_rs_f` set
`dont_touch = "true"` and `ram_style = "registers"` on `cb`, so the design
FORBIDS the RAM inference rather than failing to achieve it; and `cb_lpc_f`
makes lanes-per-copy `1*BLK = 32`, so `CB_COPIES` is **48**, not 1,536.
Therefore `CB_RANKS = min(48,48) = 48` and `cb_rank_of(c) = c`:
**`0b34200` is the IDENTITY function in build 11b and changed nothing.**

TRACK CBCENSUS (`e240fbb`) confirmed this from the netlist rather than from the
parameter log, opening the preserved synthesis checkpoint
(sha256 `703b3157...`, verified): `core/cb` is **6,144 FDRE** read through
**24,576 MUXF7 + 12,288 MUXF8** of LUT6 mux tree. DERIVED: 6,144 = 48 x 16 x 8
is the `regs` geometry, and a 16:1 one-bit mux is 4 LUT6 + 2 MUXF7 + 1 MUXF8,
so 1,536 lanes x 8 bits gives exactly 12,288 MUXF8 and 24,576 MUXF7 as measured.
DERIVED: 18,315 - 12,288 = **6,027**, which is build 10's entire-design F8 total
to the digit, so build 10 cannot have contained this mux tree.

## What survives and what does not

**SURVIVES.** The routing failure and its object. 146,948 of 669,216 routable
nets in resource conflict; congestion level 6-7; 38 of the 40 nets named at the
top ten signal-overlap nodes are `core/cb[][][]` with `tr_reg[...]_i_NN` loads.
Vivado named the object and the object was the codebook. The mux tree that
congested is real and CBCENSUS counted it.

**WITHDRAWN.** That the codebook COMMIT caused it. The commit was inert here.
What caused it was a parameter that no one set.

**ALSO WITHDRAWN, and it was mine, from the section above:** the statement that
build 11b's log "carries no `[Synth 8-5859]` message about `cb` at all, in
either direction." The absence is real but the inference drawn from it was not.
Build 10 DOES carry `[Synth 8-5859] Recognized 3D RAM cb_reg
[rtl/matvec_core.vhd:692]`. Build 11b lacks it because at `regs` no inference
was ever ATTEMPTED, not because one was declined and not because the tool was
silent on a question it considered. An absence is not a measurement, and I
reported it as one.

## How this was missed, and it is the recorded trap

The build-10-to-build-11b comparison was labelled multi-variable in this very
file, and the enumeration of what differed was drawn from the two commits and
their RTL diff. **It did not include the LAUNCH ENVIRONMENT.** `CB_STYLE` is
not in any commit; it is in the `systemd-run --setenv` list, and build 11b's
unit did not carry it. `hw/fk33/pcieep_build.sh` never sets it and
`hw/fk33/gen_pcieep.py` defaults it to `regs`, so the omission is silent by
construction.

So the error was not failing to control a variable. It was **not knowing the
variable existed**, while writing a section titled "a MULTI-VARIABLE
comparison" and listing five RTL files. CLAUDE.md already says to enumerate
what differs from the runs' own RECORDED PARAMETERS; the parameters were
recorded, in both builds' logs, under `Parameter CB_STYLE bound to`, and were
not read. TRACK CBGUARD is now censusing every other environment-driven knob
with the same shape.

The `^FK33_CB_STYLE` sentinel that would have caught this ALREADY EXISTED and
already read 0 for this build. **Nothing refused.** A sentinel whose absence
nothing acts on is decoration, which is this project's own standing test for a
guard.

## And the launch omission was mine

Build 11b was launched from this session. The `--setenv=FK33_CB_STYLE=distributed`
line that builds 9 and 10 carried was not in its unit. Build 12 carries it and
verifies the binding from the log rather than trusting `--setenv`.

---

# CORRECTION 2, 2026-09-21: THE PER-CLOCK TABLE'S PERIOD IS WRONG. BUILD 11b RAN AT 200 MHz.

**WITHDRAWN: the Intra Clock Table row giving `clk_out3` a period of 13.333 ns,
and every comparison of this build's WNS or TNS with build 9's or build 10's.**

MEASURED by TRACK CBGUARD (`3e344a2`) from each build's own generated Tcl and its
own routed Clock Summary:

```
build 10   CLKOUT3_REQUESTED_OUT_FREQ {75.000}    Clock Summary: 13.333  75.000
build 11b  CLKOUT3_REQUESTED_OUT_FREQ {200.000}   Clock Summary:  5.000 200.000
```

`FK33_ENG_CORE_MHZ` defaults to `200.000` (`hw/fk33/gen_pcieep.py:515`) and
`pcieep_build.sh` never sets it. The card has never closed above 75 MHz, and 7
of the 7 recorded runs that produced a bitstream were at 75. **Build 11b is the
sole outlier, by a default nobody chose.**

DERIVED: WNS -9.762 against a 5.000 ns requirement puts the path near 14.762 ns,
which against the real 13.333 ns period is roughly **-1.4 ns**, not -9.8.
Approximate, since clock uncertainty is not strictly period-independent, but the
order of magnitude is the point: **this build's timing was an over-constraint,
not a collapse.**

The period in the table above was taken from what this card's clock is supposed
to be, rather than from the run's own Clock Summary sitting in the same report.
The requirement is a recorded parameter like any other.

**The routing failure is now LESS settled, not more.** CORRECTION 1's
`CB_STYLE=regs` mux tree is measured in the netlist and is not in doubt, but a
200 MHz target at 99.75% CLB occupancy is an independent first-order congestion
mechanism, and the two are not separable from the evidence that exists. A 75 MHz
control needs a fresh synthesis; the preserved checkpoint was synthesised at 200.

Also: `CLKOUT2_DIVIDE 16 -> 6`, which CBCENSUS listed as an unexplained fourth
parameter and which three tracks published as ordinary drift, **was this
retarget**. DERIVED: VCO = 250/5 x 24 = 1200, and 1200/16 = 75 against
1200/6 = 200 exactly.
