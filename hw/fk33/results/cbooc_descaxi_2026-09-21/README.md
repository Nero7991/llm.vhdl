# The per-row codebook, out of context: two of three predictions MISSED

TRACK CBOOC's two-arm A/B, run on the workstation 2026-09-21 06:50 to 07:07
(17 minutes, both arms). `CBO_TARGET=matvec_int4_desc_axi`, the card's
geometry, `CB_STYLE=distributed`, `CB_COPIES=1536`, `FAST_POP=true` held
IDENTICAL across arms so build 11b's other change could not float.

`synth_design` + `opt_design` only. No place, no route, no hardware.

## Tree identity, asserted rather than assumed

```
CBOOC_SHA c189722
CBOOC_TREES ok files_differing=1 hunks=4 (matches 0b34200)
CBOOC_TREE_SHA old=ef401b6ff079e055 new=974734a743f73201
```

The `old` arm is `git show 0b34200^:rtl/matvec_core.vhd` verbatim, not an
imitation of the change. Both arms passed a GHDL elaboration gate before any
Vivado started, and the 8G cgroup cap was verified present.

## Registered predictions against measurement

CBOOC registered these BEFORE the run. Two missed.

| registered | measured | verdict |
|---|---|---|
| FF delta -19,344 | **-19,345** | hit, one flop elsewhere |
| LUT delta 0 | **+1,456** | **MISSED** |
| max `cbw_*` fanout 1,537 -> 49 | **1,537 -> 109** | **MISSED** |

The FF figure is structural, not fitted, which is why it landed: the command
registers go from one per COPY to one per RANK, and

```
13 bits x (1536 copies - 48 ranks) = 13 x 1488 = 19,344      (DERIVED)
cbw_ff 19,968 -> 624                                         (MEASURED)
```

`19,968 = 1536 x 13` and `624 = 48 x 13`. A quantity that is structural is a
constant and needs no fit.

The fanout miss is the informative one. The histogram is `109x1 49x12`:
**twelve of the thirteen command nets fell to 49 exactly as predicted, and one
did not**, sitting at 109 pins (108 sinks). The thirteen nets are one valid,
four address and eight data (`cbwv_ff=48 cbwa_ff=192 cbwd_ff=384` in the new
arm, each 48 x its width). Which of the thirteen is the outlier, and why, is
NOT determined here.

## Full delta

```
CBOOC_DELTA  field            old            new          new-old
CBOOC_DELTA  lut                     92259          93715          +1456
CBOOC_DELTA  lut_logic               74733          76189          +1456
CBOOC_DELTA  lut_mem                 17526          17526             +0
CBOOC_DELTA  ff                      77235          57890         -19345
CBOOC_DELTA  bram_tile               192.5          192.5             +0
CBOOC_DELTA  ramb36                    192            192             +0
CBOOC_DELTA  ramb18                      1              1             +0
CBOOC_DELTA  uram                        0              0             +0
CBOOC_DELTA  dsp                      1585           1585             +0
CBOOC_DELTA  carry8                   6380           6475            +95
CBOOC_DELTA  f7                        287            280             -7
CBOOC_DELTA  f8                        103            103             +0
CBOOC_DELTA  cbw_worst_slack old=12.631 | new=12.899
CBOOC_DELTA  timing_per_clk old=s_axi_aclk:8.848 m_aclk:1.173 | new=s_axi_aclk:8.848 m_aclk:1.173
```

DSP, BRAM, URAM and `lut_mem` identical are the controls, and they held. The
change costs **+1,456 LUT** and buys **-19,345 FF** and a 14.1x fanout
reduction on twelve of thirteen nets.

## THE RESULT THAT MATTERS MOST IS A NEGATIVE ONE: THIS OOC CANNOT SEE THE CARD'S MECHANISM

```
CBOOC_DELTA  cb_opt  old=cb_ram=26112 cb_ff=0 cbw_ff=19968 ... | new=cb_ram=26112 cb_ff=0 cbw_ff=624 ...
```

**Out of context, `cb` is distributed RAM in BOTH arms.** `cb_ram=26112` and
`cb_ff=0` identically, `lut_mem` delta +0, `f8` delta +0. No mux tree appears
anywhere in either arm.

On the CARD it is not like that. Placed stage, build 10 against build 11b:

```
LUT as Distributed RAM   64,478 -> 52,174   (-12,304)
F8 Muxes                  6,027 -> 18,315   (+12,288)
```

Nearly equal and opposite, differing by 16, and F8 is 18,315 at SYNTHESIS as
well as placed, so it is a mapping fact and not a placement one. Roughly 12,300
LUTRAM cells became mux logic in the card build, and this OOC reproduces none
of it.

That is consistent with what this project has already recorded: the parts do not
sum across synthesis contexts, and Vivado maps the same RTL to different
primitives depending on what surrounds it (`gdn_block` reports 22 BRAM tiles
alone against 5,472 attributed to one object inside the composed block).
**So no out-of-context experiment on this lever, including a `bcast` arm, can
settle what it does on the card.** The harness's own header said it could not
convict on placement; this is stronger, because the divergence is at synthesis.

TRACK CBCENSUS holds the workstation lane and is censusing the preserved build
11b synthesis checkpoint to establish which primitives `core/cb` actually
became on the card.

## And the circulated mechanism is not in the log

It has been stated that `[Synth 8-5859]` DECLINED `cb` in build 11b. **It did
not, and there is no message either way.** MEASURED, `grep -c '8-5859'` on
`/mnt/storage/fk33_builds/build11b/build.stdout` returns exactly **2**, and both
name `gdn_block.vhd`:

```
INFO: [Synth 8-5859] Recognized 3D RAM gqbuf[0].qbuf_reg. ... [rtl/gdn_block.vhd:749]
INFO: [Synth 8-5859] Recognized 3D RAM gkbuf[0].kbuf_reg. ... [rtl/gdn_block.vhd:760]
```

The absence of a recognition message for `cb` is consistent with `cb` not being
inferred as RAM in the card build, but it is not the explicit refusal that was
reported, and an absence is not a measurement. The census settles it.

## Not determined

- Which of the thirteen command nets sits at 108 sinks instead of 48.
- Where the +1,456 LUT goes. It is 1.6% of the arm's 92,259 and was registered
  as zero.
- Whether the change helps or hurts ON THE CARD. Nothing here bears on that,
  per the section above.
- Whether `cb` is RAM or a mux tree on the card. TRACK CBCENSUS.

## Files

`run.log` is the full driver log including both arms' fanout histograms.
`MANIFEST.txt` records the two arm trees. The per-arm run directories are at
`/mnt/storage/fk33_builds/scratch/cbooc_descaxi_main/run_20260921_065042_1471846/`.
