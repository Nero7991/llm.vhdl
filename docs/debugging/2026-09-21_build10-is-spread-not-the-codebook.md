# 2026-09-21 -- Why card build 10 missed timing by 5.819 ns at 75 MHz

TRACK B10WHY. No Vivado was started on either box. Every number below comes
from reports and logs that already existed on disk.

## The question, verbatim

> **Why did card build 10 miss timing by 5.819 ns at 75 MHz, and what in it is
> responsible?**
>
> Build 10 is now the ONLY unexplained card failure, and it is the one that
> matters most, because it sits directly between the control now building and
> any future lever.

Hardware/build: `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, `FK33_CARD=1`,
build root `/mnt/storage/fk33_builds/build10`, recorded HEAD
`b71a6d98212ee9ebc6fdde6d5a3802154dabd232`, built 2026-09-20 13:27:45 to
18:29. Symptom: routed `WNS -5.819 ns, TNS -14,030.521, 17,248 failing
endpoints of 1,523,409` design-wide; on the 75 MHz core clock
`WNS -5.819, TNS -14,026.255, 17,194 failing of 1,287,987`.

---

## The answer, up front

**Build 10 did not fail because of one structure. At least three independent
structures, in three different subsystems and two different clock domains,
degraded at once -- and each of them did so while its own endpoint count was
unchanged.** The codebook command net owns the WNS; it is not the whole
failure, and it is almost certainly not the cause.

MEASURED, against the two other card builds that routed and closed:

| structure | clock | seqrst (closed) | card_swg (closed) | build 10 |
|---|---|---|---|---|
| A, `eng/dut/core/cb_addr[2]` -> `cbw_a_reg[*][2]` | clk_out3 75 MHz | not in the 10 worst (so > +0.452) | not in the 10 worst (so > +0.299) | **-5.819** |
| C, `gcr.gkvaxi.u_kv/GEN_RD[*]` -> `mbank_reg[*]/CE` | clk_out3 75 MHz | **+0.452** (the WNS owner) | **+0.299** (the WNS owner) | **worse than -1.000 on >=1000 endpoints, worst -2.131** |
| XDMA DMA-BRAM domain | fk33_dmabram 250 MHz | **+0.054** | **+0.049** | **-0.109**, 54 endpoints |

The third row is the cleanest fact in this file. That clock's endpoint count is
**202,652 in build 10 against 202,657 and 202,658** in the two builds that
closed -- a difference of five endpoints in 202,658, 0.003% -- and its WNS
still moved 0.158 ns negative. **Nothing inside that domain changed; the device
around it did.** A single-structure explanation cannot produce that.

**What the -5.819 ns itself is, MEASURED and unambiguous:** one net, no logic.

    Source:            bd_i/eng/inst/eng/cb_addr_reg[2]/C          SLICE_X177Y27
    Destination:       bd_i/eng/inst/eng/dut/core/cbw_a_reg[894][2]/D  SLICE_X114Y204  (pb_core)
    Requirement:       13.333ns
    Data Path Delay:   18.938ns  (logic 0.081ns (0.428%)  route 18.857ns (99.572%))
    Logic Levels:      0
    net (fo=1536, routed)   18.857

All ten violated clk_out3 paths in the report share that one source pin, all
have `fo=1536`, all have 0 logic levels, and all have route delay
18.583-18.947 ns. **DERIVED: the net alone consumes 141.4% of the period
(18.857 / 13.333).**

**And that net is not new, and build 10 is not bigger.** Build 9 --
`card_kvreg_2026-09-20`, the bitstream on the card at 2.46 tok/s -- has the
identical codebook RTL (`rtl/matvec_core.vhd` is byte-unchanged between the two
trees), the identical 1,536 replicas, the identical place/phys_opt/route
directives, and it closed at **+0.061**. Build 10 placed **smaller** than both
builds that closed in every logic resource (CLB 54,751 against 54,854 and
54,839; CLB LUTs 361,361 against 363,095 and 367,685; FF 308,213 against
308,981 and 308,140) and larger only in BRAM (595 tiles against 567 and 547.5).
**So the codebook is where build 10 broke worst, not why it broke, and the area
hypothesis is refuted in the direction it was stated.**

**Attribution to any individual lever is not possible from what exists.** Build
9 and build 10 differ by **nineteen commits changing nineteen `.vhd` files**,
not by four levers -- including six files in subsystem A itself. "Build 10 =
build 9 + NWIDE" and "build 10 = build 9 + four levers" are both wrong.

---

## The procedure, in the order run, and what each step isolates

1. **Inventory the artefacts and assert tree identity before reading any
   number.** `md5sum` of the committed `timing_summary_routed.rpt.gz` against
   the build root's `bd_wrapper_timing_summary_routed.rpt`, and of the
   committed `build.stdout.full.gz` against `build10/build.stdout`. *Isolates:
   whether the committed evidence is the run's own, rather than a plausible
   filename.* Both matched exactly.
2. **Discover that the whole build tree survived, routed DCP and bitstream
   included.** *Isolates: what a later lane could do. The brief and
   `KEEP_build10_dcp/README.txt` both state there is no routed DCP; there is.*
3. **Read the requirement from the run's own Clock Summary before reading any
   WNS.** *Isolates: the 13.333 ns / 5.000 ns confusion that survived a commit
   once already.*
4. **Count the violated paths the report actually contains, against 17,194.**
   *Isolates: whether the summary's sample can support an attribution at all --
   the exact trap that nearly produced a wrong answer on build 11b.*
5. **Extract every violated path's source, destination, fanout, route delay and
   logic levels.** *Isolates: whether the WNS is a logic-depth problem or a net
   problem.*
6. **Diff the `FK33_*` sentinel sets between build 9 and build 10.** *Isolates:
   the configuration, which is not in the commit. Two silent generator defaults
   have each cost a build.*
7. **Extract the `place_design` / `phys_opt_design` / `route_design` directives
   from each build's own log.** *Isolates: the five-variable confound that
   invalidated a day of build-11b attribution.*
8. **Compare the routed reports of the two card builds that CLOSED.**
   *Isolates: whether the failure is a size effect. Endpoint counts and placed
   utilization are the controls that should not move.*
9. **Read `report_methodology`'s TIMING-16 list -- an independent 1,000-path
   sample of the SAME routed design.** *Isolates: concentrated versus spread,
   at 5.8% of the failing endpoints instead of 0.058%.*
10. **Read the per-clock Intra Clock Table for all three builds.** *Isolates:
    whether a second clock domain, whose contents did not change, also moved.*
11. **Enumerate what differs between the two trees from git, not from intent.**
    *Isolates: whether "four levers" is the real variable list.*
12. **Test the pblock-escape hypothesis by arithmetic on the pblock's own site
    count.** *Isolates: whether the driver landed in the excluded column X7.*

---

## The evidence, as raw output

### Tree identity (step 1)

```
$ zcat hw/fk33/results/card_build10_FAILED_2026-09-20/timing_summary_routed.rpt.gz | md5sum
2c4dc654904dac26f338ed0f7bba92fe  -
$ md5sum /mnt/storage/fk33_builds/build10/root/.../bd_wrapper_timing_summary_routed.rpt
2c4dc654904dac26f338ed0f7bba92fe

$ md5sum /mnt/storage/fk33_builds/build10/build.stdout        # == build.stdout.full.gz
e938341e8ee6c5dbb932a18ead4996ca
$ md5sum .../impl_1/bd_wrapper.bit                            # == committed FK33_AUTOSAVE md5
8e032106c137ce6771b09da5994cce21
```

### The build tree survived, and it holds a routed DCP (step 2)

```
390439623  /mnt/storage/fk33_builds/build10/root/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper_routed.dcp
315265074  .../bd_wrapper_physopt.dcp
201062671  .../bd_wrapper_opt.dcp
 25750038  .../bd_wrapper.bit
  7496861  .../bd_wrapper_timing_summary_routed.rpt
   996095  .../bd_wrapper_drc_routed.rpt
   600649  .../bd_wrapper_methodology_drc_routed.rpt
 12039622  .../bd_wrapper_control_sets_placed.rpt
    15873  /mnt/storage/fk33_builds/build10/root/fk33_pcieep_congestion.rpt
    18068  /mnt/storage/fk33_builds/build10/root/fk33_pcieep_pblock_util.rpt
```

The routed DCP has been copied to
`/mnt/storage/fk33_builds/KEEP_build10_dcp/build10_routed_bd_wrapper.dcp`
(sha256 `fb54d3ec9243387ade8c9d5d116332e5da53502b15a30d6d603159782aa29fda`,
appended to that directory's `SHA256SUMS`), because the build root is not a
preserved location and build 9's tree was already lost once.

### The requirement, from the run's own Clock Summary (step 3)

```
  clk_out3_bd_clk_wiz_0_0    {0.000 6.667}   13.333   75.000
```

And the route was legal -- this is a timing failure, not a routing failure:

```
Design Route Status
   # of routable nets..................... :      681039
       # of fully routed nets............. :      681039
       # of nets with routing errors...... :           0
```

### The report contains 20 violated paths, not 17,194 (step 4)

```
$ zcat <report> | grep -c '^Slack (VIOLATED)'
20
$ zcat <report> | grep -m1 '^| Command'
| Command : report_timing_summary -max_paths 10 -report_unconstrained ...
```

Ten on `clk_out3` and ten on `fk33_dmabram_BRAM_PORTA_CLK`. **Ten paths against
17,194 failing endpoints is 0.058%.** On build 11b the identical extraction
gave 65 paths against 494,527 failing endpoints and pointed at a module that
had nothing to do with the failure. That sample is not, on its own, an
attribution here either.

DERIVED, and the README missed it: `TNS -14,026.255 / 17,194 = -0.8158 ns mean
violation`, against a worst of -5.819. **The 17,194 are not 17,194 paths at
-5.8; they are a long tail whose mean is 0.82 ns.** Had they all been near the
worst, TNS would have been about -100,000.

### The WNS is one net with no logic in it (step 5)

```
-5.819  src=SLICE_X177Y27  dst=SLICE_X114Y204  fo=1536  route=18.857  dpd=18.938ns
-5.817  src=SLICE_X177Y27  dst=SLICE_X33Y183   fo=1536  route=18.848  dpd=18.929ns
-5.791  src=SLICE_X177Y27  dst=SLICE_X31Y183   fo=1536  route=18.893  dpd=18.974ns
-5.790  src=SLICE_X177Y27  dst=SLICE_X113Y207  fo=1536  route=18.667  dpd=18.748ns
-5.779  src=SLICE_X177Y27  dst=SLICE_X34Y174   fo=1536  route=18.794  dpd=18.875ns
-5.775  src=SLICE_X177Y27  dst=SLICE_X114Y197  fo=1536  route=18.583  dpd=18.664ns
-5.755  src=SLICE_X177Y27  dst=SLICE_X57Y155   fo=1536  route=18.947  dpd=19.028ns
-5.742  src=SLICE_X177Y27  dst=SLICE_X34Y181   fo=1536  route=18.735  dpd=18.816ns
-5.735  src=SLICE_X177Y27  dst=SLICE_X56Y157   fo=1536  route=18.823  dpd=18.904ns
-5.730  src=SLICE_X177Y27  dst=SLICE_X35Y182   fo=1536  route=18.722  dpd=18.803ns
```

One driver at (X177, Y27); the ten worst sinks at (X31-X114, Y155-Y207).
DERIVED Manhattan span, worst case (X31Y183): `|177-31| + |183-27| = 302` CLB
units.

The `fo=1536` is confirmed by the RTL rather than inferred from it.
`rtl/matvec_core.vhd`:

```
 82:    cb_addr   : in  std_logic_vector(3 downto 0);
 83:    cb_data   : in  std_logic_vector(7 downto 0);
260:  constant CB_COPIES : positive :=
261:    (ROWS_IF*BLK + CB_LANES_PER_COPY - 1) / CB_LANES_PER_COPY;
700:        cbw_a(c) <= cb_addr;
701:        cbw_d(c) <= cb_data;
356:  attribute dont_touch of cbw_a : signal is "true";
357:  attribute dont_touch of cbw_d : signal is "true";
```

DERIVED: 4 + 8 + 1 = 13 command bits, each to `CB_COPIES = 1536` flop
D-inputs, so **19,968 sink pins in the family**, which is greater than 17,194
and therefore *sufficient* to account for the failing count -- but see step 9,
which shows the family is not the only violator.

### The configuration is identical to build 9's (step 6)

`FK33_*` sentinel sets, 67 lines each, differ in exactly four places:

```
< FK33_AUTOSAVE ...card_kvreg_20260920_105609.bit (25745854 bytes, md5 96a35ba0...)
> FK33_AUTOSAVE ...card_bmover_20260920_182916.bit (25750038 bytes, md5 8e032106...)
< FK33_BITSTREAM ... (25745854 bytes)
> FK33_BITSTREAM ... (25750038 bytes)
< FK33_CFGTIME   -15%    108.4 MHz ->   475.1 ms
> FK33_CFGTIME   -15%    108.4 MHz ->   475.2 ms
< FK33_TIMING WNS=0.061 ns  WHS=0.009 ns
> FK33_TIMING WNS=-5.819 ns  WHS=0.000 ns
```

Everything else is bit-for-bit the same sentinel: `FK33_ENGI clock
clk_out3_bd_clk_wiz_0_0 period 13.333 ns (75.00 MHz)`, `FK33_PBLK pb_core
CLOCKREGION_X0Y0:CLOCKREGION_X6Y3`, `FK33_UNCONNECTED count=0`, `FK33_SEAM
CAPS_*`, `FK33_PCIE_IDS`, `FK33_SEAMMAP`. **Build 10 was at the right frequency
in the right floorplan.** (Build 11b's failure was a configuration difference;
build 10's is not.)

### The directives are identical too (step 7)

```
build 9  (kvreg):   place_design -directive AltSpreadLogic_high
                    phys_opt_design -directive AggressiveExplore
                    route_design -directive AlternateCLBRouting
build 10:           place_design -directive AltSpreadLogic_high
                    phys_opt_design -directive AggressiveExplore
                    route_design -directive AlternateCLBRouting
seqrst (closed):    place_design -directive AltSpreadLogic_high
                    phys_opt_design -directive AggressiveExplore
                    route_design -directive AlternateCLBRouting

build 11b:          place_design -directive ExtraPostPlacementOpt
                    phys_opt_design -directive Explore
                    route_design -directive Explore
```

**Build 9 against build 10 is a directive-controlled comparison.** Build 11b
against either is not, and never was.

### The builds that closed are BIGGER (step 8)

```
                       seqrst(+0.452)  card_swg(+0.299)  build10(-5.819)
CLB LUTs                   367,685         363,095          361,361
CLB Registers              308,140         308,981          308,213
CLB tiles            54,839 (99.78%)  54,854 (99.81%)  54,751 (99.62%)
LUT as Logic               294,234         297,323          295,786
LUT as Memory               73,451          65,772           65,575
F7 Muxes                    28,760          28,528           28,422
F8 Muxes                     6,276           6,107            6,027
Block RAM Tile               547.5             567              595
URAM                            32              32               32
DSPs                         2,072           2,087            2,087

clk_out3 total endpoints 1,345,699       1,288,772        1,287,987
clk_out3 WNS                +0.452          +0.299           -5.819
```

Build 10 is the smallest in every logic resource and the only one that failed.
Its clk_out3 endpoint count is within **0.06%** of card_swg's and **4.3% below**
seqrst's. **The only resource in which build 10 leads is BRAM, +28 tiles over
card_swg, 88.54% of 672** -- which is exactly what `fee5e6e` predicted for
NWIDE ("+28 BRAM tiles and -368 LUT").

The router's own view, anchored, both builds:

```
build 9:   35-448 Estimated Global/Short routing congestion is level 5 (32x32)
           35-581 Estimated Timing congestion is level 5 (32x32)
           35-416 WNS=+0.533 (post-place) -> -0.818 -> -0.383 -> -0.012 -> +0.061
           route_design elapsed 01:51:56

build 10:  35-448 Estimated Global/Short routing congestion is level 5 (32x32)
           35-581 Estimated Timing congestion is level 6 (64x64)
           35-416 WNS=+0.421 (post-place) -> -1.372 -> -10.110 -> -7.614 -> -7.262
           route_design elapsed 03:30:27
```

MEASURED: **one congestion level higher on the timing metric, at double the
window size, and 1.88x the routing time.**

### The independent 1,000-path sample names a different module entirely (step 9)

`bd_wrapper_methodology_drc_routed.rpt`, written 18:17:54 from the same
`Design State : Fully Routed` design, 2 minutes before the timing summary:

```
TIMING-16  Warning  Large setup violation  1000
```

All 1,000 entries, extracted and tabulated:

```
$ cut -f2 timing16.tsv | sort -u | wc -l
1
$ cut -f2 timing16.tsv | sort | uniq -c
   1000 bd_i/card/inst/u/gcr.gkvaxi.u_kv/GEN_RD[1].ph_ch_reg[0]/C
$ cut -f3 timing16.tsv | awk -F/ '{print $1"/"$2"/"$3"/"$4"/"$5}' | sort | uniq -c
   1000 bd_i/card/inst/u/gcr.gkvaxi.u_kv
$ grep -c 'cbw_a\|cb_addr' bd_wrapper_methodology_drc_routed.rpt
0
```

**Not one codebook path appears.** Slack range -1.000 to -2.131, and the list
is sorted ascending from the -1.000 ns threshold:

```
-1.000 -1.000 -1.001 -1.003 -1.004 -1.006 -1.006 -1.009 -1.009 -1.009 ...
```

So the 1,000 is a **sorted-ascending list truncated at the cap**, which means
it discards the worst violations and keeps the mildest. That is why -5.819 is
absent, and it is also why this sample cannot be scaled: it is biased toward
the threshold, exactly opposite to the timing summary's bias.

The same module is the WNS owner in **both** builds that closed, and its path
is a genuine long combinational path rather than a fanout problem
(`card_seqrst_bfnorm`):

```
Slack (MET) : 0.483ns
  Source:      .../gcr.gkvaxi.u_kv/GEN_RD[1].ph_ch_reg[0]/C
  Destination: .../gcr.gkvaxi.u_kv/GEN_RD[1].mbank_reg[1][11][121]/CE
  Data Path Delay: 12.801ns  (logic 3.428ns  route 9.141ns)
  Logic Levels:    34  (CARRY8=17 LUT1=3 LUT2=2 LUT3=4 LUT4=3 LUT5=3 LUT6=2)
```

**A 34-level path with a 17-deep CARRY8 chain, closing with 0.299-0.452 ns of a
13.333 ns period, i.e. 2.2%-3.4% margin.** In build 10 the same source pin is
worse than -1.000 ns on at least 1,000 endpoints. That is a second, physically
unrelated failure: nothing about a carry chain is fixed by shrinking a fanout.

The routed congestion report names the owners of the pressure, and it is
neither of them:

```
| East | Short | 7 | (CLEL_R_X18Y5,DSP_X82Y130) | ... | bd_i/card/inst/u/gcr.u_attn/u_arr(31%),
                                                          bd_i/eng/inst/eng/dut/core(20%),
                                                          bd_i/card/inst/u/gcr.u_attn(15%)
| South | Long | 6 | (CLEL_R_X10Y26,CLEL_R_X42Y89) | ... RAMB 100% ... u_arr(72%)
| East | Short | 6 | (CLEL_R_X81Y6,CLEL_R_X113Y69) | ... gkvaxi.u_kv(29%), eng/dut/core(21%)
```

Subsystem C's attention array `gcr.u_attn/u_arr` is 31-74% of the cells in
every level-5/6/7 window, with `RAMB 100%` saturated in the global and long
windows.

### A second clock domain moved, with its contents unchanged (step 10)

Intra Clock Table, WNS / TNS / failing / total:

```
                              seqrst            card_swg          build10
clk_out1   100 MHz      +4.927  0  1,839   +4.492  0  1,839   +4.574  0  1,839
clk_out3    75 MHz      +0.452  0 1,345,699 +0.299 0 1,288,772  -5.819 17,194 1,287,987
fk33_dmabram 250 MHz    +0.054  0  202,657  +0.049 0  202,658  -0.109     54   202,652
```

**202,652 against 202,657 and 202,658.** The XDMA DMA-BRAM domain is the same
design in all three builds to within five endpoints, and it went 0.158 ns
negative in build 10 only.

### Nineteen commits and nineteen RTL files, not four levers (step 11)

Build 9 started 2026-09-20 07:37:34 and read the LIVE tree
(832 source paths under `/home/orencollaco/GitHub/llama.vhdl`, zero under any
worktree). The newest commit at that instant was `3180646` (07:33:23).
`b71a6d9` is a descendant of it; `0b34200` is NOT an ancestor of `b71a6d9`,
confirming the codebook "fix" is not in build 10.

```
$ git diff --name-only 3180646 b71a6d9 -- 'rtl/*.vhd' 'hw/fk33/rtl/*.vhd' | wc -l
19
hw/fk33/rtl/fk33_engine.vhd   rtl/async_fifo.vhd        rtl/axi_rd_port.vhd
rtl/fk33_eng_cdc.vhd          rtl/fk33_llama_top.vhd    rtl/gdn_conv_tap_mem.vhd
rtl/gdn_conv_w_mem.vhd        rtl/gdn_exp_mem.vhd        rtl/gdn_state_axi.vhd
rtl/gdn_state_mem.vhd         rtl/gdn_state_store.vhd    rtl/llama_top.vhd
rtl/matvec_int4.vhd           rtl/matvec_int4_desc_axi.vhd rtl/ooc_gdnadapt_top.vhd
rtl/region_drain.vhd          rtl/stream_fifo.vhd        rtl/swiglu_mem.vhd
rtl/weight_streamer.vhd
```

`rtl/matvec_core.vhd` is the one A file that did NOT change (`git diff --stat`
is empty), which is the part of build 10's README that survives. But **six
other subsystem-A files did change**, and not all of it is behind a
default-off generic. `rtl/matvec_int4.vhd` gains an unconditional new output:

```
+    dbg_sstarve : out std_logic    -- weights present, the scale group was not
+  dbg_sstarve <= wv and not sv;
```

and `rtl/async_fifo.vhd` / `rtl/stream_fifo.vhd` restructure the pop condition
around a new `after_e` signal. `FAST_POP` is `false` at `b71a6d9`, so those
arms should constant-fold, but **A's netlist is not established to be identical
and the README's implication that A was untouched is too strong.**

### The driver did not escape the pblock (step 12)

```
fk33_pblock.xdc:91  add_cells_to_pblock [get_pblocks pb_core] \
                      [get_cells bd_i/eng/inst/eng/dut/core]
pb_core:  CLB 48,396 used of 48,600 sites (99.58%),  device 54,960
report: "The current part is not an SSI device"   (single SLR)
```

DERIVED: the device is 54,960 CLB over 240 rows = 229 columns; pb_core is
48,600 / 240 = 202.5 columns, so pb_core covers roughly SLICE_X 0-202 and the
excluded clock-region column X7 covers X203-228. **SLICE_X177 is inside
pb_core.** The blank `PBlock` column against the source in the timing path
reports *cell* membership (`cb_addr_reg` lives one level above `dut/core`, so
it is in no pblock), not a site outside the region.

---

## Best-supported attribution, with confidence

**MEASURED, high confidence:**
1. The failure is real, at the correct 75 MHz, on a legally routed design with
   zero nets in error.
2. The -5.819 ns belongs to one net class -- A's codebook command net, fanout
   1,536, zero logic levels, 18.857 ns of pure route delay -- whose driver was
   placed about 240-300 CLB units from its worst sinks.
3. At least two further structures failed independently: C's `u_kv` 34-level
   carry chain (>=1,000 endpoints worse than -1.000 ns) and the 250 MHz
   `fk33_dmabram` domain (-0.109 ns, 54 endpoints, contents unchanged).
   **The failure is SPREAD, not concentrated.**
4. It is not an area effect. Two builds that are larger in CLB, CLB LUTs and
   LUT-as-Logic closed at +0.299 and +0.452 with the same directives and the
   same clock.
5. It is not a configuration effect. The sentinel sets and all three
   implementation directives are identical to build 9's.

**DERIVED, medium confidence:** the common upstream factor is placement and
routing pressure rather than any one structure. The router's own timing
congestion went from level 5 (32x32) in build 9 to level 6 (64x64) in build 10,
routing time went 1.88x, and the intermediate WNS collapsed from -1.372 to
-10.110 in a single global iteration instead of recovering monotonically as
build 9's did. Three unrelated structures degrading together, one of them in a
domain whose own contents did not change, is what pressure looks like and is
not what a single bad net looks like.

**ESTIMATE, low confidence, stated as a hypothesis and not a finding:** the
mechanism by which build 10 acquired that pressure while being *smaller* is the
BRAM growth. BRAM is the only resource in which build 10 leads (+28 tiles,
88.54% of 672), BRAM sites are column-constrained, `RAMB` reads 100% in every
level-5/6 global and long congestion window, and at 99.62% CLB occupancy there
is no room to relieve a BRAM-anchored cluster. **Assumption: that BRAM column
pressure propagates into CLB placement quality. This has not been tested and no
control exists for it.** It is registered here so that it can be falsified,
with the sign of any effect on the codebook net left unpredicted.

**NOT determined, and I will not guess:**
- Which of the nineteen commits, or which lever, produced the pressure. No
  single-variable control exists and none can be built from the artefacts.
- How the 17,194 failing endpoints divide between A's codebook family (19,968
  candidate pins) and C's `u_kv`. Both available samples are biased, in
  opposite directions, and neither can be scaled.
- Why the placer put a 1,536-fanout driver in the corner of the pblock.
- Whether fixing the codebook fanout would let build 10 close. Given that
  `u_kv`'s carry chain is independently negative, the honest expectation is
  that it moves the WNS rather than closing the design.

**Build 9's exact input is not recoverable, and neither is build 10's.** Both
read the live working tree. `3180646` is the best identification of build 9 --
DERIVED from a commit timestamp four minutes before the build's first Vivado
line, not recorded anywhere -- and any uncommitted edit present at 07:37:34 on
2026-09-20 is gone. The same caveat applies to `b71a6d9`, which *is* recorded
in `build10/HEAD` but still only names the commit, not the tree that was read.

---

## Measured and REJECTED -- do not retry

- **"The levers grew the card block and displaced A's codebook net."**
  REJECTED. Build 10 placed 54,751 CLB / 361,361 CLB LUTs / 308,213 FF against
  `card_swg`'s 54,854 / 363,095 / 308,981 and `seqrst`'s 54,839 / 367,685 /
  308,140, both of which closed. Already withdrawn at `a3cb844`; this adds the
  second control and makes the refutation two-sided.
- **"The failure IS the codebook command net."** REJECTED as a complete
  account. An independent 1,000-path sample of the same routed design names
  only `gcr.gkvaxi.u_kv` and zero codebook paths, and a third clock domain
  failed as well.
- **"Build 10 = build 9 + NWIDE", and "= build 9 + four levers".** REJECTED.
  Nineteen commits, nineteen `.vhd` files, six of them in subsystem A.
- **"The endpoint count doubled."** Already withdrawn in build 10's README; now
  refuted with same-clock controls. clk_out3 is 1,287,987 in build 10 against
  1,288,772 (card_swg) and 1,345,699 (seqrst).
- **"The driver escaped pb_core into the Tandem-reserved column X7."**
  REJECTED by arithmetic on the pblock's own site count: pb_core is 48,600 of
  54,960 CLB sites, about 202 of 229 columns, so SLICE_X177 is inside it.
- **"phys_opt failed to replicate the driver because there was no room."** NOT
  SUPPORTED, and do not quote the Very-High-Fanout delta as evidence. Build 9
  added 56 cells over 5 nets and build 10 added 49 over 4, but that pass's
  threshold is far above 1,536 and neither build's log names `cb_addr` in it.
  Build 10's 40 mentions of `cbw_a` are all `[Physopt 32-952]` lines from the
  post-route pass, i.e. the consequence, not the cause.
- **"A route or phys_opt directive will fix this."** REJECTED, still. Build 10's
  own `[Physopt 32-745]` says the negative slack is too large to improve, its
  advice threshold is -0.5 ns against -5.819, and the directives were already
  the same ones build 9 closed with.
- **"-7.262 is the routed WNS."** It is the router's own `[Route 35-20] Post
  Routing Timing Summary`, before Phase 14 physical synthesis in the router
  brought it to -5.819. Both are post-route; -5.819 is the final report. Note
  `KEEP_build10_dcp/README.txt` still carries -7.262 and should be corrected.

---

## Measurement traps hit, including my own

- **I grepped the Report Methodology table as `^\| TIMING-16` and got zero hits
  from all four builds.** That table has no leading pipe in
  `report_timing_summary`'s embedded copy, while `report_methodology`'s own file
  does. A wrong anchor returned "absent from every build", which reads exactly
  like a real negative result. The correct extraction showed TIMING-16 present
  at 1000 in both failing builds and **absent from both passing builds**, which
  is a clean control and I nearly discarded it.
- **I read the 1,000-entry TIMING-16 list as an unbiased sample and started to
  conclude the codebook was not involved at all.** It is sorted ascending from
  its -1.000 ns threshold and truncated at the cap, so it systematically
  discards the worst paths. Reading the first fifteen slacks in file order was
  what caught it. **A capped list is only a sample once you know its ordering**,
  and here the two available samples are biased in opposite directions, which is
  why neither can apportion the 17,194.
- **My first `awk` on the Intra Clock Table mis-aligned the columns** and
  printed hold-slack figures as setup, because the clock names are up to 400
  characters wide and `$1`-relative field counting silently shifted. Anchoring
  on the last twelve fields with the header printed alongside fixed it. A
  mis-aligned table looks like data.
- **The brief, `KEEP_build10_dcp/README.txt` and my own initial plan all said
  there is no routed DCP for build 10.** The entire build tree survived,
  including the routed DCP, the bitstream, the congestion report and a
  7.5 MB uncompressed timing summary. That assumption would have made me
  recommend a re-route from the placed checkpoint that is not needed.
- **Vivado reports the PBlock column in a timing path by CELL membership, not by
  SITE location.** The blank against `SLICE_X177Y27` looked like "the driver is
  outside the pblock region" and is really "this cell was never added to any
  pblock". I formed the escape hypothesis from it and had to kill it with
  arithmetic.
- **17,248 and 17,194 are both correct** and describe different things:
  design-wide failing endpoints and the clk_out3 group's. Build 10's README and
  this brief quote one each; neither is wrong.
- **The mean violation is 0.816 ns, not 5.819.** Dividing TNS by the failing
  count takes ten seconds and reframes the whole problem; nobody had done it,
  and the shape of the fix depends on it.

---

## If a lane is scheduled: exactly what to run, and what it costs

A lane is **not** needed to answer the question asked. It is needed to answer
the two things that remain open, and the artefacts to do it cheaply now exist.

**Job 1 -- apportion the 17,194 (ESTIMATE 10 minutes, ~8 GB, read-only).**
Open the preserved routed checkpoint and ask the timer directly, no
re-implementation:

```tcl
open_checkpoint /mnt/storage/fk33_builds/KEEP_build10_dcp/build10_routed_bd_wrapper.dcp
report_timing -setup -max_paths 20000 -slack_lesser_than 0 \
  -group clk_out3_bd_clk_wiz_0_0 -no_header -file b10_all_violated.rpt
report_timing_summary -max_paths 200 -file b10_summary_200.rpt
# and the two censuses, each anchored against a report_utilization CELL row
get_cells -hier -filter {NAME =~ *core/cbw_a_reg*}
get_property LOC [get_cells bd_i/eng/inst/eng/cb_addr_reg[2]]
```

This settles concentrated-versus-spread with every violated path rather than
two biased samples, and it is the only cheap measurement that does.

**Job 2 -- the one-variable RTL control (ESTIMATE 4-5 h, 18-47 GB, and it needs
the box to itself).** A `FK33_CARD=1` build at `3180646` plus *only*
`14fa888` + `b71a6d9` (the four levers), same three directives, same 75 MHz.
That is the experiment nobody has run: it isolates the levers from the other
fifteen commits. **Do not run it beside anything**; budget swap, and put the
guard on `memory.swap.current` as well as `memory.current`.

**A cheaper thing to try before either, costing no lane at all:** the codebook
command net has no fanout constraint, and this tree already uses the idiom in
`rtl/hbm_tg.vhd` and `rtl/gdn_silu.vhd`. A `MAX_FANOUT` attribute on `cb_addr`
and `cb_data` in `rtl/matvec_int4_desc_axi.vhd` replicates the driver in
synthesis at a cost of a few dozen flops, against `0b34200`'s measured
+44,073 LUT for the per-row rewrite that was reverted at `1cc7cbf`. It is a
one-line change per signal and it rides the next card build rather than needing
its own. Note it will not touch `u_kv`'s carry chain or the `fk33_dmabram`
domain, so on the evidence here it should be expected to move the WNS, not to
close the design.

**What no lane can recover:** build 9's and build 10's exact input trees.

---

## Open, not yet answered

- How the 17,194 divide between A and C. Job 1 settles it.
- Which commit or lever produced the pressure. Job 2 is the only clean test.
- Whether the BRAM hypothesis is right, or has the sign backwards.
- Why the placer put the 1,536-fanout driver at (X177, Y27).
- Build 9's placed utilization, which still does not exist and is still the
  baseline everything is quoted against. `952e70a` fixes this going forward.
- Nothing here is a silicon measurement. The card was serving build 9 at
  2.46 tok/s throughout and was not touched.
