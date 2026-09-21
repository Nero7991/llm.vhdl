// TRACK CBCENSUS, 2026-09-21

# In card build 11b, is `core/cb` RAM primitives, or LUTs plus MUXF7/MUXF8?

## The question, verbatim

> In card build 11b, is `core/cb` implemented as RAM primitives, or as LUTs and
> MUXF7/MUXF8?

Asked because two measurements disagreed. Out of context, an A/B on
`matvec_int4_desc_axi` at the card's stated geometry (`CB_STYLE=distributed`,
`CB_COPIES=1536`, `FAST_POP=true`, log
`/mnt/storage/fk33_builds/scratch/cbooc_descaxi_main/run.log`, 2026-09-21
07:07) reported `cb_ram=26112 cb_ff=0` in BOTH arms and no mux tree. On the
card, build 10 to build 11b moved LUT-as-Distributed-RAM 64,478 -> 52,174
(-12,304) and F8 Muxes 6,027 -> 18,315 (+12,288).

Hardware: `xcvu33p-fsvh2104-2L-e`, FK33. Build 11b is worktree
`/mnt/storage/fk33_builds/wt11` at `5dc3ee5`; build 10 is `b71a6d9` from the
live tree.

## The answer, up front

**`core/cb` in build 11b is 6,144 FDRE flip-flops read through a mux tree of
LUT6 + 24,576 MUXF7 + 12,288 MUXF8. It is NOT RAM. Zero RAM primitives under
`core` have anything to do with `cb`.**

**The reason is not an inference failure. Build 11b bound the generic
`CB_STYLE` to `regs`; build 10 bound it to `distributed`.** Under `regs`,
`rtl/matvec_core.vhd`'s own `cb_dt_f`/`cb_rs_f` set `dont_touch = "true"` and
`ram_style = "registers"` on `cb`, and `cb_lpc_f` sets lanes-per-copy to
`1*BLK = 32`, so `CB_COPIES` is 48 rather than 1,536. The out-of-context
experiment was run at `distributed` and therefore measured a configuration the
card build did not contain. That is why it disagreed.

**The previously circulated mechanism, that `[Synth 8-5859]` DECLINED `cb`, is
withdrawn, and so is this dispatcher's replacement claim that the log says
nothing either way.** Build 10's log carries
`[Synth 8-5859] Recognized 3D RAM cb_reg` outright. Build 11b's does not,
because with `ram_style = "registers"` and `dont_touch = "true"` no RAM
inference was ever attempted. The absence is the lever being off, not a
refusal.

## The procedure

1. Lane check by `/proc/PID/exe` (never `pgrep -f`). No Vivado present.
2. `sha256sum` the preserved post-synthesis checkpoint BEFORE opening it.
   Used `/mnt/storage/fk33_builds/KEEP_build11b_dcp/build11b_synth_bd_wrapper.dcp`,
   `703b3157757d2b45c1e64294c78300b1b4729131b6830c705ef168f75436add6`, matching
   `SHA256SUMS`. Synthesis is the stage that answers a mapping question; the
   placed and routed checkpoints were not opened.
3. `open_checkpoint` under `systemd-run --user -p MemoryHigh=20G
   -p MemoryMax=22G`, scratch under `/mnt/storage/fk33_builds/scratch/cbcensus_20260921/`,
   never `/tmp`. Cap confirmed by reading the cgroup file, not the exit status.
4. `report_utilization` whole-design AND `report_utilization -cells
   [get_cells bd_i/eng/inst/eng/dut/core]` from the SAME checkpoint, to give
   every census an anchor at the same stage and the same scope.
5. Confirm the instance path exists before relying on it
   (`get_cells bd_i/eng/inst/eng/dut/core` -> 1 object, `REF_NAME matvec_core`).
6. Census by `REF_NAME` of every `IS_PRIMITIVE` cell under that scope, then
   validate each filter against the row of `report_utilization` that measures
   the same thing. **Only then quote it.**
7. Ask what `cb` IS structurally rather than what it is named: take the nets
   `core/cb[*][*][*]` (the ones `signal_overlaps.txt` names), get their OUTPUT
   leaf pins, and census the driving cells. The driver's primitive type is the
   answer; a name is not.
8. Locate the design's MUXF8 by hierarchy prefix and by leaf-name shape, to
   answer "are the +12,288 in `core` or elsewhere" as a measurement rather than
   as an assumption.
9. Only after the netlist was measured, diff the two builds' recorded
   `Parameter ... bound to:` lines. This is the step that explained it, and it
   is deliberately last: had it been first, the census would have been used to
   confirm a theory instead of to replace one.

## The evidence, raw

### Filter validation, same checkpoint, same scope

Census left, `report_utilization` right. Agreement to the digit is the evidence
that licenses the census; a clean ratio or a zero would have been the filter.

| quantity | census (`get_cells -hier -filter`) | `report_utilization` | verdict |
|---|---|---|---|
| MUXF8, whole design | `REF_NAME == MUXF8` -> **18,315** | F8 Muxes **18,315** | exact |
| MUXF7, whole design | `REF_NAME == MUXF7` -> **53,029** | F7 Muxes **53,029** | exact |
| MUXF8, under `core` | **12,288** | `-cells core` F8 **12,288** | exact |
| MUXF7, under `core` | **24,576** | `-cells core` F7 **24,576** | exact |
| FDRE, under `core` | **52,760** | `-cells core` CLB Registers **52,760** | exact |
| SRL16E, under `core` | **798** | `-cells core` LUT as Shift Register **798** | exact |
| DSP48E2, under `core` | **1,584** | `-cells core` DSPs **1,584** | exact |
| distributed RAM, under `core` | 37 RAM32M16 macros, 37 x 8 = **296** LUT | `-cells core` LUT as Distributed RAM **296** | exact (DERIVED) |

### Two filters that would have been wrong, MEASURED on this checkpoint

**`REF_NAME =~ DSP*` over-counts by exactly 9x here**, reproducing the factor
CLAUDE.md already records from a DSP58 part. Nine `REF_NAME` classes under
`core` begin with `DSP`, each at 1,584: `DSP48E2` itself plus `DSP_ALU`,
`DSP_A_B_DATA`, `DSP_C_DATA`, `DSP_MULTIPLIER`, `DSP_M_DATA`, `DSP_OUTPUT`,
`DSP_PREADD`, `DSP_PREADD_DATA`. MEASURED sum **14,256**, ratio to the true
1,584 exactly **9.000**. The reproduction is welcome but incidental: the census
was anchored against the DSPs row regardless, which is the only reason the
factor is known rather than assumed.

**`REF_NAME =~ RAM*` over-counts by 17.6x under `core` AND mixes two different
resources.** It returns 651:

```
CBC_CORE_RAM RAM32M16   37     <- the real distributed-RAM macros
CBC_CORE_RAM RAMD32    518     <- their children
CBC_CORE_RAM RAMS32     74     <- their children
CBC_CORE_RAM RAMB18E2    1     <- BLOCK RAM, not distributed at all
CBC_CORE_RAM RAMB36E2   21     <- BLOCK RAM, not distributed at all
CBC_CORE_RAM_TOTAL     651
```

DERIVED: `518 + 74 = 592 = 37 * 16`, so every `RAMD32`/`RAMS32` under `core` is
a child of a `RAM32M16` and none is a standalone memory. The leaf names confirm
it, 37 of each of the sixteen `RAM32M16` sub-cell positions:

```
CBC_CORERAMLEAF 37 RAMA
CBC_CORERAMLEAF 37 RAMA_D1
CBC_CORERAMLEAF 37 RAMB
...
CBC_CORERAMLEAF 37 RAMH
```

CLAUDE.md lists `REF_NAME =~ RAM*` as the working idiom and notes it had never
been validated. **It is now validated and it is wrong in the over-counting
direction, for the same reason the DSP filter is: the macro decomposes and every
piece carries the prefix.** It additionally sweeps in `RAMB*` block RAM, which
is not the resource the question is about.

**The LUT rows are SITE counts and cannot anchor a cell census.** Census LUT1-6
under `core` sums to `1007 + 28493 + 12179 + 2257 + 11770 + 68632 = 124,338`
against `LUT as Logic 118,975`. DERIVED difference 5,363, which is LUT
combining (two LUT5-or-smaller sharing one LUT6 site). Not an error in either
number, but do not treat the LUT row as a primitive count.

### `core` primitive census, build 11b post-synthesis

```
CARRY8            5873     LUT1              1007     RAM32M16    37
DSP48E2           1584     LUT2             28493     RAMB18E2     1
(9 x DSP sub    1584 ea)   LUT3             12179     RAMB36E2    21
FDRE             52760     LUT4              2257     RAMD32     518
GND                  2     LUT5             11770     RAMS32      74
VCC                  2     LUT6             68632     SRL16E     798
MUXF7            24576
MUXF8            12288
CBC_CORE_REF_TOTAL 235544
```

### What `cb` actually is: the drivers of the `cb` nets

```
CBC_CBNETS             6144
CBC_CBNET_OUTPINS      6144
CBC_CBNET_DRIVERS      6144
CBC_CBDRV_REF FDRE     6136
CBC_CBDRV_REF MUXF8       8
CBC_CBDRV_REF_TOTAL    6144
CBC_CBDRV_SAMPLE  bd_i/eng/inst/eng/dut/core/cb_reg[0][10][0] ... cb_reg[0][11][1]
```

DERIVED: `6,144 = 48 copies x 16 entries x 8 bits`. That is `CB_COPIES = 48`,
i.e. the `regs` geometry. At `CB_STYLE = distributed` it would be 1,536 copies
and 196,608 nets. **The net count alone falsifies "the card was built at
`distributed`", before any parameter log is consulted.**

The loads of those nets are the mux tree:

```
CBC_CBNET_INPINS        202506
CBC_CBNET_LOADCELLS      55289
CBC_CBLOAD_REF LUT6      55288
CBC_CBLOAD_REF DSP_A_B_DATA   1
```

And cells under `core` whose name contains `cb`, none of them a RAM:

```
CBC_CBNAME_REF FDRE      6768     (6,144 cb_reg + 624 = 48 x 13 of cbw_v/cbw_a/cbw_d)
CBC_CBNAME_REF LUT6      6144
CBC_CBNAME_REF LUT2         1
```

### Where the MUXF8 live. This was the crux and the answer is: in `core`.

```
CBC_MUXLOC MUXF8 d6 12288 bd_i/eng/inst/eng/dut/core
CBC_MUXLOC MUXF8 d6  2448 bd_i/card/inst/u/gcr.u_attn/u_arr
CBC_MUXLOC MUXF8 d6  1104 bd_i/card/inst/u
CBC_MUXLOC MUXF8 d6   488 bd_i/card/inst/u/gb_real.u_gdn/u_emit
CBC_MUXLOC MUXF8 d6   420 bd_i/card/inst/u/gcr.u_attn/u_norm
CBC_MUXLOC MUXF8 d6   256 bd_i/card/inst/u/gcr.gkvaxi.u_kv
CBC_MUXLOC MUXF8 d6   128 bd_i/card/inst/u/u_regmem
...
CBC_MUXLEAF MUXF8 12288 tr_reg[][]_i_N
CBC_MUXLEAF MUXF7 24576 tr_reg[][]_i_N
```

Every one of `core`'s 12,288 MUXF8 and 24,576 MUXF7 has leaf-name shape
`tr_reg[..][..]_i_N`, which is exactly the load name `signal_overlaps.txt`
prints against the overlapping `cb` nets
(`bd_i/eng/inst/eng/dut/core/tr_reg[1][135]_i_37/I0`). Independent corroboration
from a file written by `route_design` months of analysis ago.

DERIVED, the mux-tree shape: a 16:1 mux of one bit is 4 LUT6 (4:1 each) + 2
MUXF7 + 1 MUXF8. At 1,536 lanes x 8 bits = **12,288** such muxes, that is
**12,288 MUXF8 and 24,576 MUXF7**, both exactly as measured, and 49,152 LUT6 of
`core`'s 68,632.

DERIVED: `18,315 - 12,288 = 6,027`, which is build 10's ENTIRE-DESIGN F8 total
to the digit. Since 6,027 < 12,288, **build 10 cannot have contained this mux
tree**, whatever else differs between the builds.

### The parameter diff, which is what explains it

All `Parameter ... bound to:` lines from each build's own `build.stdout.full.gz`,
sorted and counted. 517 lines in build 10, 518 in build 11b. The complete diff
is four entries:

```
80c80
<       4 Parameter CB_STYLE bound to: distributed - type: string
---
>       4 Parameter CB_STYLE bound to: regs - type: string
172c172
<       1 Parameter CLKOUT2_DIVIDE bound to: 16 - type: integer
---
>       1 Parameter CLKOUT2_DIVIDE bound to: 6 - type: integer
284c284
<       8 Parameter FAST_POP bound to: 0 - type: bool
---
>       8 Parameter FAST_POP bound to: 1 - type: bool
313a314
>       1 Parameter HDR_TREE bound to: 0 - type: integer
```

And the inference messages:

```
build 10:
INFO: [Synth 8-5859] Recognized 3D RAM gqbuf[0].qbuf_reg ... [rtl/gdn_block.vhd:749]
INFO: [Synth 8-5859] Recognized 3D RAM gkbuf[0].kbuf_reg ... [rtl/gdn_block.vhd:760]
INFO: [Synth 8-5859] Recognized 3D RAM cb_reg ...          [rtl/matvec_core.vhd:692]

build 11b:
INFO: [Synth 8-5859] Recognized 3D RAM gqbuf[0].qbuf_reg ... [wt11/rtl/gdn_block.vhd:749]
INFO: [Synth 8-5859] Recognized 3D RAM gkbuf[0].kbuf_reg ... [wt11/rtl/gdn_block.vhd:760]
```

No `8-10226` in build 11b.

### Resource footprint of the run

Vivado's own `Memory (MB): peak = 7891.266`, well under `MemoryHigh=20G`, so per
the standing rule this is an honest peak and not the cap. Cap readback from the
cgroup: `memory.high = 21474836480`, `memory.max = 23622320128`.

## Measured and REJECTED. Do not retry.

- **"`cb` is distributed RAM on the card, because the OOC A/B says so."**
  REJECTED. The OOC A/B bound `CB_STYLE=distributed`; the card build bound
  `regs`. The two measured different designs. **An out-of-context result is
  quotable for the card only when the card's own recorded parameter bindings
  match it**, and this project's own bit-identity findings say nothing about
  parameter agreement.
- **"`[Synth 8-5859]` declined `cb` on the card."** REJECTED. No 8-5859 message
  declines anything; the message only ever announces a recognition. Build 10
  has one for `cb_reg` and build 11b has none.
- **"Build 11b's log says nothing either way about `cb`'s inference."**
  REJECTED, and this was this dispatcher's own replacement claim. The log says
  plenty: the 8-5859 that build 10 has and build 11b lacks is the signal, and
  the `Parameter CB_STYLE bound to:` lines state the cause outright. **An
  absence in one log is only readable next to the presence in a comparable
  one.**
- **`REF_NAME =~ RAM*` as an authoritative memory census.** REJECTED for this
  purpose. 17.6x over-count under `core` plus block RAM contamination, shown
  above.
- **Reasoning about the F8 delta from the whole-design total.** Would have been
  ambiguous: 18,315 is compatible with the muxes being anywhere. The
  instance-scoped `report_utilization -cells` plus the leaf-name shape is what
  localises them, and it cost one extra command.

## Measurement traps hit

- **The scope-restricted `report_utilization -cells` is the thing that makes a
  census checkable.** Without it there is no same-stage, same-scope row to
  anchor against, and every number in the table above would have been an
  assertion. It also caught the LUT site-vs-cell distinction for free.
- **`REF_NAME` prefix filters are wrong in the over-counting direction whenever
  the primitive is a macro that decomposes.** Two instances in one checkpoint
  (`DSP*` at 10x, `RAM*` at 17.6x). The recorded 9x for `DSP*` did NOT
  reproduce here; it is 10x on this part. A remembered factor is not a
  correction.
- **The F7 rows differ between stages by 7.** Synthesis checkpoint 53,029,
  build 11b's placed report 53,022. F8 is 18,315 in both. Small, but it means a
  cross-stage comparison of an F7 number is not exact. Every anchor in the
  table above is same-checkpoint for this reason.
- **The net-name index arity was a free, cheap discriminator that went unused
  for a day.** `cb[4][3][4]` with 6,144 nets is `48 x 16 x 8` and could only be
  the `regs` geometry. It was sitting in `signal_overlaps.txt`, already
  committed, the whole time.
- **`ram_style` and `dont_touch` on `cb` are computed from a generic by a
  function**, so grepping the RTL for `"distributed"` finds the string and says
  nothing about what was built. The binding is a property of the BUILD and lives
  only in the build log.

## Open, not yet determined

- **What CAUSED the -12,304 LUT-as-DRAM / +12,288 F8 delta is NOT settled
  here, and this file does not claim it.** DERIVED arithmetic is consistent
  with `cb`: at `distributed`, 1,536 copies x 8 bits = 12,288 LUTs of
  distributed RAM, against a measured -12,304 (a residue of 16). But four
  parameters differ (`CB_STYLE`, `CLKOUT2_DIVIDE`, `FAST_POP`, `HDR_TREE`) and
  five RTL files differ by +896 lines including `attn_block.vhd` +556. **Two
  builds differing in nine known ways cannot attribute a delta to one of them.**
  What IS established without attribution: `cb` is a mux tree in 11b, and
  build 10's whole-design F8 of 6,027 is too small to contain that mux tree.
- **Why build 11b bound `CB_STYLE=regs` at all** -- whether the environment
  variable was not exported, or the generated build Tcl did not carry it -- was
  not investigated. `hw/fk33/rtl/fk33_engine.vhd:72` declares the default as
  `"regs"`, so any path that fails to pass the value silently lands here. This
  is the recorded `CB_STYLE IS A STRING` hazard in `rtl/matvec_core.vhd:238-240`
  firing through the build harness rather than through a typo.
- **The 8 `cb` nets driven by MUXF8 rather than FDRE** (8 of 6,144, 0.13%) were
  not chased. Most likely one entry's read path retimed or a driver duplicated;
  it does not change any count above.
- **Nothing here bears on the ROUTING failure.** Build 11b's 146,948 nets in
  resource conflict, and the 38-of-40 `core/cb` nets at the top ten overlap
  nodes, stand on their own evidence. This file measured mapping only. That the
  mux tree exists does not establish that it caused the congestion, and the
  census neither strengthens nor weakens that separate finding.
- **No claim is made about which mapping is BETTER**, for area, timing or
  routability. That needs a controlled re-synthesis and was out of scope.

## Reproduce

```
sha256sum /mnt/storage/fk33_builds/KEEP_build11b_dcp/build11b_synth_bd_wrapper.dcp
# 703b3157757d2b45c1e64294c78300b1b4729131b6830c705ef168f75436add6
systemd-run --user --unit=cbcensus1 --collect -p MemoryHigh=20G -p MemoryMax=22G \
  -- /bin/bash /mnt/storage/fk33_builds/scratch/cbcensus_20260921/run.sh
# script: /mnt/storage/fk33_builds/scratch/cbcensus_20260921/cbcensus.tcl
# log:    /mnt/storage/fk33_builds/scratch/cbcensus_20260921/vivado.log
# reports: util_full.rpt, util_core.rpt, core_ref_census.txt, cb_driver_names.txt

cd hw/fk33/results
zgrep -ah 'bound to:' card_build10_FAILED_2026-09-20/build.stdout.full.gz  | sed 's/^[ \t]*//' | sort | uniq -c | sort -k2 > b10_params.txt
zgrep -ah 'bound to:' card_build11b_FAILED_2026-09-20/build.stdout.full.gz | sed 's/^[ \t]*//' | sort | uniq -c | sort -k2 > b11b_params.txt
diff b10_params.txt b11b_params.txt
zgrep -a '8-5859' card_build10_FAILED_2026-09-20/build.stdout.full.gz
zgrep -a '8-5859' card_build11b_FAILED_2026-09-20/build.stdout.full.gz
```
