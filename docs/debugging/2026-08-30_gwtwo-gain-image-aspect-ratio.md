# TRACK GWTWO: what does reshaping the norm gain image cost, and does it close the 51-tile BRAM gap?

**Date:** 2026-08-30. **Tree:** `8ff90105f03cb29d52bba11455db1d8ad5bc9208`.
**Hardware:** synthesis on `cachyos-bc250` (BC-250), Vivado 2023.2,
`xcvu33p-fsvh2104-2L-e`, licence `~/.Xilinx/Xilinx-4.lic`. Simulation on the
workstation, GHDL 1.0.0 mcode. **No hardware was touched by this track.**

---

## 1. The question, verbatim

> **A `GW = 2` draw of the gain image, with a same-session `GW = 4` control**,
> reporting **BRAM, LUT, FF and WNS together**. ... **Sweep it properly if 2 is
> not enough.** `GW = 1, 2, 4, 8` ... **The question is not "is 2 better" but
> "what is the BRAM/LUT curve", because we need to buy at least 45 tiles and we
> do not yet know what that costs in LUT.** ... **State the exchange rate
> explicitly:** tiles saved per LUT added, at each point. ... **Say whether it
> CLOSES the 51-tile gap or merely narrows it.**

Symptom numbers it starts from, all MEASURED elsewhere and re-checked here:
composed A+B+C+D 246.5 tiles, `rmsnorm_rs_mem` vectors 6 tiles, gain image 171
tiles, total 423.5 against 372.5 available inside `pb_core`. Short by 51.

---

## 2. The answer, up front

**`GW` is a real BRAM lever, it is monotone, and it is FREE -- it costs no LUT
at all, it saves LUT. And it does NOT close the gap.**

MEASURED, four points, one session, one Vivado at a time on the BC-250:

| GW | ROM shape | CLB LUT | CLB FF | RAMB36 | RAMB18 | **BRAM tile** | WNS @ 5.0 ns |
|---:|---|---:|---:|---:|---:|---:|---:|
| **1 (landed)** | 266,240 x 16 | **5,073** | 3,511 | 135 | 12 | **141** | +0.971 |
| 2 | 133,120 x 32 | 5,229 | 3,465 | 145 | 12 | 151 | +0.971 |
| **4 (shipping)** | 66,560 x 64 | 5,265 | 2,149 | 171 | 12 | 177 | +0.971 |
| 8 | 33,280 x 128 | 5,277 | 2,133 | 226 | 12 | 232 | +0.971 |

The 12 RAMB18 (6 tiles) are `rmsnorm_rs_mem`'s vector banks and do not move.
Every tile that moves is the gain image.

**The gap, recomputed at each point** (DERIVED: 246.5 composed + 6 vectors +
the image, against 372.5 available inside `pb_core`):

| GW | image | total needed | **short by** |
|---:|---:|---:|---:|
| 8 | 226 | 478.5 | 106.0 |
| 4 | 171 | 423.5 | **51.0** |
| 2 | 145 | 397.5 | 25.0 |
| 1 | 135 | 387.5 | **15.0** |

**No `GW` closes it. `GW = 1` narrows it from 51 tiles to 15, which is 70.6% of
the way, and stops.** That is the headline and it is stated early because, as
the brief said, it forces the question upstream: **the remaining 15 tiles have
to come from somewhere other than the aspect ratio.**

**The exchange rate is not a trade.** Against the shipping `GW = 4`:

| move | tiles saved | LUT delta | FF delta | LUT per tile bought | FF per tile bought |
|---|---:|---:|---:|---:|---:|
| 4 -> 2 | +26 | **-36** | +1,316 | **-1.4 (LUT is SAVED)** | +50.6 |
| 4 -> 1 | +36 | **-192** | +1,362 | **-5.3 (LUT is SAVED)** | +37.8 |
| 2 -> 1 | +10 | -156 | +46 | -15.6 | +4.6 |
| 4 -> 8 | **-55** | +12 | -16 | -- | -- |

The only resource that gets worse going down is FF, by 1,362 registers.
MEASURED device total is 879,360 CLB Registers, so that is **0.155% of the
device**, against 5.4% of the BRAM budget bought with it. **There is no
"exchange rate" to negotiate: smaller `GW` is better on LUT, better on BRAM,
identical on WNS, and the FF price is noise.**

WNS is **+0.971 ns at all four points**, byte-identical, so nothing here is
paid for in timing.

---

## 3. The procedure, in the order it was run, and what each step isolates

**Step 0 -- register the prediction before drawing anything.**
`hw/fk33/results/gwtwo_2026-08-30/PREDICTION.txt`, written before the first
Vivado invocation, with explicit falsification criteria. **It was wrong.** See
section 6.

**Step 1 -- correct the brief's rate arithmetic (section 5).** The brief's
central constraint, "at `GW = 2` the margin halves to 2.0x, at `GW = 1` it is
1.0x, i.e. NO MARGIN", describes the pre-`RMSWIRE` tree. Establishing that
first is what made `GW = 1` and `GW = 8` legal points to draw at all.

**Step 2 -- generate the four sources mechanically, never by hand.** A python
one-liner rewrites exactly one line of `rtl/llama_top.vhd`:

```
if n mod <GW> = 0 then return <GW>; else return 1; end if;
```

**The `GW = 4` file is byte-identical to `rtl/llama_top.vhd` at HEAD**
(md5 `6f0aa7fdd349f76724c19090303b619c` both), which is what makes the control a
control rather than a re-implementation. `sim/ooc_normadapt_extract.py` then
pulls the `gvr` block out of each verbatim, so the four synthesis inputs differ
by exactly one line plus a provenance comment. Isolates: everything except `GW`.

**Step 3 -- draw all four on the BC-250, GW = 4 FIRST.** Drawing the control
first is deliberate: if it had not reproduced TRACK RMSWIRE's `mem_bank`, the
harness would not have been on RMSWIRE's scale and every delta would have been
meaningless. It reproduced it field for field (section 4). Isolates: harness
drift, and cross-machine reproducibility.

**Step 4 -- functional check at every `GW`: `sim:tb_llama_top_normw`.**
Isolates: the packing order. Reshaping the ROM changes which bits of `NW_TBL`
land in which word and which sub-word the mux picks, and getting that backwards
permutes the gain in groups of `GW` **with no structural symptom at all**.

**Step 5 -- teeth for step 4.** Three mutants of the packing path, run through
the same row. **A PASS at a new `GW` means nothing until this table exists.**
Isolates: whether the bench can see a `GW`-dependent error at all.

**Step 6 -- the rate question at the REAL shape, `NN = 4096`.**
`sim/tb_llama_top_normw` runs at `hidden = 64`, and the brief is explicit that a
small-shape pass is not evidence. A scratch-only probe
(`gwtwo_rateprobe.vhd`, deliberately **not** in `sim/` and **not** named `tb_*`)
instantiates the extracted `gvr` block at the real 9B shape and measures the
cycle count from `i_v_start` to the first region write-back. Isolates: whether
the gain load's duration depends on `GW`.

**Step 7 -- teeth for step 6.** A `slowload` mutant that advances the load
pointer on alternate cycles only. **A negative measurement is decoration until
something is shown to move it.** Isolates: the probe's own resolution.

**Step 8 -- object-level BRAM census** (`sim/ooc_gwtwo_bramcensus.tcl`),
because CLAUDE.md's rule is that `report_utilization` is cross-checked against
`get_cells` and the census wins on disagreement. Isolates: whether the tile
counts above are real, and which RTL object owns them.

---

## 4. Evidence, as raw captured output

### 4.1 The control reproduces TRACK RMSWIRE field for field

TRACK RMSWIRE `mem_bank` (`hw/fk33/results/rmswire_2026-08-30/result_mem_bank.csv`):

```
ooc_normadapt,"NORM_W_IMAGE=...",41,5265,5265,0,2149,171,12,177,0,279,0,0,0.971,248.2005460412013,425,-1,5265,2149,41,177
```

TRACK GWTWO `gw4` (`hw/fk33/results/gwtwo_2026-08-30/result_gw4.csv`):

```
ooc_normadapt,"NORM_W_IMAGE=...",41,5265,5265,0,2149,171,12,177,0,279,0,0,0.971,248.2005460412013,431,-1,5265,2149,41,177
```

**Every field identical except `synth_s` (425 vs 431 seconds).** dsp, lut,
lut_logic, lut_mem, ff, ramb36, ramb18, bram_tile, uram, carry8, f7, f8, wns and
fmax all match, fmax to 13 significant figures.

### 4.2 The four points

`hw/fk33/results/gwtwo_2026-08-30/summarise.sh`:

```
GW          LUT       FF   RAMB36  RAMB18    TILE   URAM    DSP      WNS      FMAX
gw1        5073     3511      135      12     141      0     41    0.971     248.2
gw2        5229     3465      145      12     151      0     41    0.971     248.2
gw4        5265     2149      171      12     177      0     41    0.971     248.2
gw8        5277     2133      226      12     232      0     41    0.971     248.2
```

Hierarchical attribution, `synthutil_hier_gw1.rpt`, showing the moving tiles are
the ROM in the top and not the unit:

```
| Instance          | Module         | Total LUTs | ... |  FFs | RAMB36 | RAMB18 |
| ooc_normadapt     |          (top) |       5073 | ... | 3511 |    135 |     12 |
|   (ooc_normadapt) |          (top) |        278 | ... | 1945 |    135 |      0 |
|   gvr.u_rms       | rmsnorm_rs_mem |       4795 | ... | 1566 |      0 |     12 |
```

Peak memory, from `ooc_lutdiet_run.sh`'s own sampler (summed `/proc` RSS over
the whole descendant tree, **not** a cgroup figure, because the runs were capped
at `MemoryHigh=11G` and a capped `memory.peak` is the cap):

```
tag=gw4 peak_rss_kib=12023812 peak_rss_gib=11.47 exit=0
tag=gw2 peak_rss_kib=12056868 peak_rss_gib=11.50 exit=0
tag=gw1 peak_rss_kib=12151768 peak_rss_gib=11.59 exit=0
tag=gw8 peak_rss_kib=12095912 peak_rss_gib=11.54 exit=0
```

All four sentinels present (`SENTINEL OK: LUTDIET_DONE ooc_normadapt`).

### 4.3 Functional: every `GW` passes, and the bench has teeth

```
GW=1  sim:tb_llama_top_normw  PASS  73s
GW=2  sim:tb_llama_top_normw  PASS  72s
GW=4  sim:tb_llama_top_normw  PASS  73s
GW=8  sim:tb_llama_top_normw  PASS  75s
```

Mutation table. `M1` mirrors the sub-word select (`(wel_d mod GW) = GW-1-s`
instead of `= s`); `M2` drops the vector-select term from the ROM address
(`0*NWORD` instead of `nidx*NWORD`).

| mutant | GW | verdict | what killed it |
|---|---:|---|---|
| `gw1_M1` | 1 | **PASS -- DOES NOT BITE** | nothing; see below |
| `gw2_M1` | 2 | FAIL | `P14 -- R_X(0) is -16346` |
| `gw4_M1` | 4 | FAIL | `P14 -- R_X(0) is -16308` |
| `gw2_M2` | 2 | FAIL | `P14 -- hash(R_X) over the last token is 90069` |

**`gw1_M1` is reported under its own name and it earns nothing.** At `GW = 1`
the mutation is a semantic no-op: the loop is `for s in 0 to 0`, so
`(wel_d mod 1) = (1-1-0)` and `(wel_d mod 1) = 0` are the same condition. It is
a textual change with no behavioural content, and it is exactly the row that
measures this harness's resolution floor: **a `GW = 1` design cannot have a
sub-word ordering bug because it has no sub-word.**

**ATTRIBUTION CONTROL: this track adds NO new assertion, so it earns ZERO
kills.** Every kill above belongs to `tb_llama_top`'s pre-existing `P14`
landmark (`R_X(0)` and `hash(R_X)`), which existed before this track and would
have caught all three without it. Stated plainly rather than counted as a win.

### 4.4 The rate is `GW`-invariant at the REAL shape, and the probe has teeth

`gwtwo_rateprobe`, `NN = 4096`, worst case (the norm op is issued the cycle
after the load restarts, so the load has zero head start):

```
GW=1      GWTWO_RATEPROBE NN=4096 first_ur_en=3 first_uw_en=7230  done=11326
GW=2      GWTWO_RATEPROBE NN=4096 first_ur_en=3 first_uw_en=7230  done=11326
GW=4      GWTWO_RATEPROBE NN=4096 first_ur_en=3 first_uw_en=7230  done=11326
GW=8      GWTWO_RATEPROBE NN=4096 first_ur_en=3 first_uw_en=7230  done=11326
slowload  GWTWO_RATEPROBE NN=4096 first_ur_en=3 first_uw_en=11322 done=15418
```

**Identical to the cycle at all four `GW`. The `slowload` teeth mutant moves it
by +4,092 cycles**, which is `NN - 4`, i.e. exactly the stall `nproc`'s `wbusy`
gate imposes when the load runs `2*NN + 2` against a budget of `NN + 4`. So the
probe can see a load-rate change of this size and `GW` does not cause one.

Both of `llama_top`'s deadline assertions -- the `w_active` check at
`rtl/llama_top.vhd:2224` (`assert not (rst='0' and r_wact='1' and wbusy='1')`,
TRACK RMSWIRE's `wact_chk`) and the `loadassert` at `:2577` -- are **silent at
every `GW`** in `tb_llama_top_normw`. That is a real-deadline pass, at
`hidden = 64`; the `NN = 4096` statement is the probe above.

### 4.5 The object-level census agrees with `report_utilization` at every point

`sim/ooc_gwtwo_bramcensus.tcl`, a separate `synth_design` per point, counting
`get_cells -hier -filter {REF_NAME == RAMB36E2}` and `RAMB18E2` rather than
reading a report row:

```
GWTWO_CENSUS tag=gw1 ramb36_cells=135  ramb18_cells=12  rpt_ramb36=135 rpt_ramb18=12 rpt_tile=141
GWTWO_CENSUS tag=gw2 ramb36_cells=145  ramb18_cells=12  rpt_ramb36=145 rpt_ramb18=12 rpt_tile=151
GWTWO_CENSUS tag=gw4 ramb36_cells=171  ramb18_cells=12  rpt_ramb36=171 rpt_ramb18=12 rpt_tile=177
GWTWO_CENSUS tag=gw8 ramb36_cells=226  ramb18_cells=12  rpt_ramb36=226 rpt_ramb18=12 rpt_tile=232
```

**Exact agreement at all four points**, so this is the case where the two do not
disagree and the report row can be quoted. The census also attributes them,
which the report row cannot (`bramcensus_gw1.txt`):

```
== RAMB36E2  count = 135
  (top)                                                           135
== RAMB18E2  count = 12
  gvr.u_rms/gbank.uo                                                4
  gvr.u_rms/gbank.uw                                                4
  gvr.u_rms/gbank.ux                                                4
```

**Every moving tile is the gain ROM in the top; the 12 RAMB18 that never move
are `rmsnorm_rs_mem`'s three vector banks.** That is the attribution the whole
"45 of the 51 tiles are the gain image" claim rests on, and it had never been
taken at the object level before.

**LIMITATION, stated rather than glossed:** the census also dumps
`RAM_MODE`/`READ_WIDTH_*`/`CASCADE_ORDER_A` hoping to show the mechanism, and on
a POST-SYNTHESIS netlist those properties are not yet configured -- every
RAMB36E2 reports `READ_WIDTH_A=1` at every `GW`, which is a default and not a
geometry. **The geometry columns in `bramcensus_*.txt` carry no information and
must not be quoted.** Getting real port geometry needs `opt_design` or a placed
checkpoint, which these draws deliberately do not run (`LUTDIET_NOOPT=1`, to
stay on the scale every other draw in this series used).

### 4.6 The LANDED tree reproduces the sweep point

`GW = 1` is landed in `rtl/llama_top.vhd` with a `gw_pick` body that reads
`return 1;` rather than the sweep variant's
`if n mod 1 = 0 then return 1; else return 1; end if;`. Semantically identical,
textually not -- so the landed file was extracted and drawn again as `gw1land`:

```
gw1      ... 41,5073,5073,0,3511,135,12,141,0,276,0,0,0.971,248.2005460412013,421,...
gw1land  ... 41,5073,5073,0,3511,135,12,141,0,276,0,0,0.971,248.2005460412013,425,...
GWTWO_CENSUS tag=gw1land ramb36_cells=135  ramb18_cells=12  rpt_ramb36=135 rpt_ramb18=12 rpt_tile=141
```

**Every field identical except `synth_s`.** The number quoted for the shipping
design belongs to the shipping design, not to a variant that resembles it.

### 4.7 A pre-existing gate failure found on the way, and fixed

**MEASURED: `sim:seamgate_real`, `sim:seamgate_stub` and `sim:seamgate_seq`
were FAILING at HEAD `8ff9010` before this track changed anything.** A full
both-suite run came back `OVERALL PASS 108 FAIL 3`, and the same three rows fail
identically on a pristine `git archive HEAD` tree with no GWTWO change in it
(`seamgate_pre_existing_control.log`):

```
FAIL       sim:seamgate_real   SEAMGATE FAIL -- the capture produced no seam records (rc=2).
FAIL       sim:seamgate_stub   SEAMGATE FAIL -- the capture produced no seam records (rc=2).
FAIL       sim:seamgate_seq    SEAMGATE FAIL -- the capture produced no seam records (rc=2).
```

The cause, from the row's own log:

```
DID NOT ANALYZE: rtl/llama_top.vhd
rtl/llama_top.vhd:2190:27: unit "rmsnorm_rs_mem" not found in library "work"
SEAMGATE_EXIT=2
```

`tools/ref9b/capture_llama_top.sh` carries a **HAND-MAINTAINED** `FILES` list
and it never gained `rtl/vec_mem.vhd` or `rtl/rmsnorm_rs_mem.vhd` when TRACK
RMSWIRE wired the unit into `llama_top` at `47c9d9c`. **This is the FOURTH
consumer of a hand-maintained closure to break the same way** -- RMSWIRE found
and fixed three (`sim/mutate_llama_top_*.sh`) and recorded the lesson, then
missed this one, **which is the only one of the four that is a gate row.**
`regress.sh` cannot catch it either: it delegates to `seamgate.sh`, which
delegates to that list, so its own closure logic never sees those files.

Fixed by adding the two files in dependency order. **This is outside this
track's stated ownership and is flagged as such in the file itself**, because
the alternative was to leave the shared gate red at HEAD where the next track
cannot tell that failure apart from its own. After the fix:

```
PASS       sim:seamgate_real                     38s  SEAMGATE PASS -- real: 1 token(s), at least 64 seams per token
PASS       sim:seamgate_stub                     28s  SEAMGATE PASS -- stub: 1 token(s), at least 63 seams per token
PASS       sim:seamgate_seq                     157s  SEAMGATE PASS -- seq: 3 token(s), at least 61 seams per token
```

**Those three rows are additional functional evidence for `GW = 1` that this
track did not plan for**: they capture real seam records from `llama_top` at
three configurations, and they now pass with the landed `GW = 1`, having been
incapable of running at all beforehand.

---

## 5. Correction to this track's brief, raised before any measurement

Full text in `hw/fk33/results/gwtwo_2026-08-30/CORRECTION_TO_BRIEF.txt`.

**The brief said:** "budget to `r_go` is `NN+4`, load is `NN/GW+1`, so the
margin is `GW` ... **At `GW = 2` the margin halves to 2.0x. At `GW = 1` it is
1.0x, i.e. NO MARGIN.**"

**That is the PRE-RMSWIRE tree.** `load = NN/GW + 1` was true while the ROM's
`GW`-wide word was shifted into a 65,536-flop staging register one WORD per
cycle. TRACK RMSWIRE deleted that register: `rmsnorm_rs_mem`'s bank port takes
ONE element per cycle, so `wload` advances `wel` by one every cycle
(`rtl/llama_top.vhd`, `elsif wav = '1' then ... wel <= wel + 1`) and the ROM
address is `wel / GW`, re-reading the same word `GW` cycles running.

**On this tree the load is `NN + 2` cycles at every `GW`, the margin is 3 cycles
at every `GW`, and residency is structural via the `wbusy` gate rather than
arithmetic.** `GW` is a pure aspect-ratio parameter with no rate consequence.
Section 4.4 is the measurement, not the argument.

**The direction of the error matters.** The stale arithmetic was conservative:
obeying the brief literally would have ruled `GW = 1` out for a reason that no
longer exists, and `GW = 1` is the best point on the curve.

---

## 6. Measured and REJECTED -- do not retry

**1. My own main prediction, `BRAM is GW-invariant`. FALSIFIED, by my own
registered criterion.** `PREDICTION.txt` said every point would land within
+/- 20% of 171 and named "more than 34 tiles" as the falsifier. `GW = 1` came in
36 tiles below. The reasoning was: total bits are fixed at 4,259,840, a RAMB36
natively supports 32Kx1 through 512x72, all four candidate widths (16/32/64/128)
sit on a native width with the same 8/9 padding loss, and the depth divides
evenly in every case, so there is no pathological aspect ratio in the set and no
reason for the count to move. **Every clause of that is true and the conclusion
is still wrong**, because it silently assumed Vivado packs to the primitive's
capability. It does not: efficiency against the 32,768-bit data capacity is
**96.3% at GW=1, 89.6% at GW=2, 76.0% at GW=4 and 57.5% at GW=8**, i.e. it
degrades monotonically as the word gets wider. **The lesson is the recurring
one: an argument from what the hardware CAN do is not a measurement of what the
tool DOES do.**

**2. `GW = 8` and anything wider. Do not retry.** 226 RAMB36, **55 tiles WORSE**
than shipping, for 12 more LUT. The curve is monotone; there is nothing above
`GW = 4`.

**3. `tb_rmswire_loadrace` as a `GW` check. It cannot be one -- do not use it
for this.** It PASSES at `GW = 1, 2, 4, 8` with byte-identical output and an
identical `@862225ns` end time, and **that result is vacuous**: the bench
instantiates `work.rmsnorm_rs` and `work.rmsnorm_rs_mem` DIRECTLY
(`sim/tb_rmswire_loadrace.vhd:309` and `:316`) and never elaborates
`llama_top`'s `gvr` block, so `GW` does not appear in it at all. Its own header
says so at line 160. **I ran it at all four points before checking what it
instantiates, and for a while had four identical PASSes that proved nothing.**

**4. URAM for this table. Already rejected by TRACK NWROM, re-confirmed by not
re-testing it.** `[Synth 8-10226]`: this device's URAM288 cannot hold a non-zero
initialisation. All four draws here report `uram=0`.

**5. Deduplicating the gain vectors. Measured, there is nothing there.** All 65
vectors in `norm_w_9b.hex` are distinct (blake2b over each 4,096-line block, 65
distinct of 65). Do not build a dedup pass.

---

## 7. What the remaining 15 tiles could come from -- MEASURED properties of the image, not a proposal

`GW = 1` leaves the design 15 tiles short. These are measured facts about
`norm_w_9b.hex` (md5 `69f614a1515e1160f5dc9e8a9e72fdc3`, 266,240 lines) that
bound what a follow-on lever could buy. **None of them has been drawn.**

| property | MEASURED value | what it bounds |
|---|---:|---|
| distinct 16-bit values in the whole table | **1,567** | an 11-bit codebook index |
| maximum value | 0x2FE0 = 12,256 | **14 bits suffice, not 16** |
| bits 15 and 14 | always zero (`OR` over all values = 0x3FFF) | as above |
| empirical entropy | **9.956 bits/element** | the information-theoretic floor |
| distinct vectors | 65 of 65 | dedup buys nothing |

DERIVED from those, at `GW = 1`'s measured 96.3% packing efficiency:

- **14-bit storage:** 266,240 x 14 = 3,727,360 bits -> ~118 tiles, **saving 17
  from 135**. That alone would close the remaining 15.
- **11-bit codebook index + a 1,567 x 14 codebook:** 2,928,640 + 21,938 bits ->
  ~93 tiles, **saving 42**.

**Both are ESTIMATES and the assumption is stated: that Vivado's packing
efficiency at those widths matches the 96.3% measured at 16 bits.** Prediction 1
of this very track died of exactly that kind of assumption, so **neither number
should be quoted as a result until it is drawn.** The falsifier is a draw at
14-bit width reporting more than about 125 tiles.

**And the caveat that matters more:** the 14-bit bound is a property of THIS
image, produced by the current packer at `NORM_W_EXP = 12`. It is not a property
of the format and a different model or a repack could use the full 16 bits.
A 14-bit store would need a pack-time assertion, not a comment.

---

## 8. Measurement traps hit, including my own

**1. An rc read off a PIPELINE is the pipeline's rc, and it hid a SIGSEGV.**
`ghdl -r ... | head -20; echo "RC=$?"` reported `RC=0` for a run that was
segfaulting on elaboration. The run "completed in 1.2 s with no output", which
reads like a design that finishes instantly rather than one that died. Only
running it without the pipe surfaced `139`. **This trap is named in my own
brief and I hit it anyway.** Every rc in `probe_run.sh` is now taken off a
subshell.

**2. `ghdl -m` returns 0 and produces no binary on the mcode backend.** Chasing
"where is the executable" cost a cycle; `ghdl -r` is the only thing that runs.

**3. GHDL-mcode needs BOTH `ulimit -s unlimited` AND `--max-stack-alloc=0`** to
elaborate the `gvr` block at `NN = 4096`. With neither:
`declaration of a too large object (4160 > --max-stack-alloc=128 KB) from
work.ooc_normadapt(rtl).gvr.B1.nw_load`. With only the flag, it segfaults.

**4. A bench passing identically at every point is a WARNING SIGN, not a
result** -- see the rejected item 3. The tell was that the simulation end time
was identical to the picosecond, which for a design whose ROM aspect ratio had
changed should have been suspicious immediately.

**5. The `LUTDIET_CENSUS` census file has no BRAM column.** It tallies
`RAMB18E2`/`RAMB36E2` into its `kinds` array but only ever prints the LUT,
MUXF7, MUXF8, FF and CARRY8 columns. Grepping it for `RAMB` returns nothing,
which looks like "no BRAM in this design" and is really "this report does not
have that column". That is why `sim/ooc_gwtwo_bramcensus.tcl` exists.

**6. A gate row can be red for a reason that is nothing to do with you, and it
looks exactly like your fault.** The full gate came back `FAIL 3` on the tree
carrying this track's `llama_top` edit. The rows were `seamgate_*`, which
capture from `llama_top`, so the coincidence was perfect. **Running the same
three rows against a pristine `git archive HEAD` tree took under two minutes
and settled it.** CLAUDE.md's advice for this ("re-run on a quiet box") does
not cover the case, because the box was quiet and the failure was real; the
control that works is a pristine-tree re-run, not a quieter one.

**7. The BC-250 is on EDT and the workstation on MDT.** A remote job that
"started 23 minutes ago" had started two. Compare `date -Is` on both, or
compare nothing.

**8. `ssh ... 'bash -c "md5sum rtl/..."'` runs in `/home/labuser`, not in the
repo.** The BC-250's repo is at `/home/orencollaco/GitHub/llama.vhdl` because
two `sim/*.tcl` hardcode that path, and the login user is `labuser`. Eight
`No such file or directory` lines look exactly like a failed sync.

---

## 9. Open, not yet answered

- **The remaining 15 tiles.** Nothing in this track closes them. Section 7 says
  what the image's own statistics permit and explicitly does not claim it.
- **Whether the composed BRAM sum is additive at all.** 423.5 and 387.5 are both
  DERIVED by adding separately-measured units, which is the assumption this
  project keeps getting burned by. **A composed draw could still come in under
  372.5 at `GW = 4` and make this whole track unnecessary, or over 372.5 at
  `GW = 1` and make it insufficient.** It has not been run.
- **Why efficiency degrades with width.** The census in section 8 note 5 will
  give the configured port geometry, but the *reason* Vivado leaves 42.5% of the
  capacity unused at `GW = 8` and 3.7% at `GW = 1` is not established here.
- **Whether `GW = 1` survives place-and-route.** Every number here is a
  synthesis estimate with `-flatten_hierarchy none` and `LUTDIET_NOOPT=1`. Fit
  by tile count is not the claim that it routes.
- **The `NORM_LANES` interaction.** All draws are at the shipping
  `NORM_LANES = 4`. `GW` and `NORM_LANES` are independent in the current
  design but that has only been checked at one point.

---

## 10. CORRECTION, appended 2026-08-30 after TRACK ROUTE2 landed `166cbd4`

**Appended, not edited in.** Nothing above is withdrawn; one number is
sharpened and one open item is closed.

TRACK ROUTE2 ROUTED `compose4_top` with both levers inside the card's real
`pb_core`, `0` nets with routing errors, and MEASURED its BRAM directly instead
of deriving it:

> **BRAM, stated explicitly: 253.5 used, 372.5 available for our logic, so
> +119.0 headroom WITHOUT the gain image and -52.0 with its 171 tiles.**

**That CLOSES this write-up's second open item** -- "whether the composed BRAM
sum is additive at all". It very nearly is: my DERIVED base was
`246.5 + 6 = 252.5` against ROUTE2's MEASURED `253.5`, one tile apart, and the
shortfall my brief carried as 51 is 52 on the composed, routed design.

**Recomputed against the MEASURED base rather than the derived one:**

| GW | image | total | vs 372.5 | |
|---:|---:|---:|---:|---|
| 4 (was shipping) | 171 | 424.5 | **short 52.0** | ROUTE2's own figure |
| 2 | 145 | 398.5 | short 26.0 | |
| **1 (landed)** | **135** | **388.5** | **short 16.0** | |

So the answer in section 2 stands with one changed digit: **`GW = 1` narrows the
gap from 52 tiles to 16, which is 69.2% of the way, and does not close it.**

**AND THE BINDING RESOURCE HAS MOVED.** ROUTE2 also measured that the routed
composition is **DSP-bound**, at 2,177 of 2,700 = 80.63% of `pb_core` against
LUT's 68.33%, with every congested window DSP-saturated. **That does not make
the 16 tiles go away** -- the gain image still has to live somewhere and there
is still not room for it -- but it does mean the follow-on levers in section 7
buy BRAM in a design whose critical resource is now DSP. **Whoever picks up
those 16 tiles should check the DSP question first**, because a BRAM lever that
costs DSP is now a net loss and none of section 7's options has been costed
that way.
