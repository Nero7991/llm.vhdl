# Does Vivado infer distributed RAM from `cb`'s array-of-array-of-`signed`?

**Date:** 2026-08-30
**Track:** CBINFER
**Repo state at start:** `d31ab02` on entry, `a8053ca` when the results dir was
cut; branch `fpga`. The RTL under test is `rtl/matvec_core.vhd` md5
`163eab020fb0d5e00a3192344bea9e7f`, unmodified in the working tree.
**Machine:** BC-250 (`cachyos-bc250`, 192.0.2.200) only. The workstation ran
no Vivado for this track. Vivado 2023.2, part `xcvu33p-fsvh2104-2L-e` -- the
same part CONGEST and TIMING drew their MUXF7/MUXF8 census on.
**Hardware:** none touched. `synth_design` and `report_*` only. No place, no
route, no programming, no JTAG.

---

## The question, verbatim

From `docs/debugging/2026-08-30_leverc-codebook-lutram.md` section 7, item 1:

> **Whether Vivado infers LUTRAM here at all.** `cb` is an array-of-array-of-
> `signed`. Vivado's own note in this file (`[Synth 8-11357]`, "RAM from
> Record/Structs") records that a nested type does not infer BRAM. Whether it
> infers DISTRIBUTED RAM from this shape is unknown. **If it does not, lever C
> produces a register bank with 1,536 copies -- strictly worse than today. This
> must be the first thing a Vivado lane checks, before any area number.**

and items 2 and 3 of the same list:

> 2. **Whether Vivado accepts `attribute ram_style of cb : signal is CB_RS`**
>    where `CB_RS` is a constant returned by a function of a generic.
> 3. **Whether adding `ram_style = "registers"` changes today's shipping build.**

---

## The answers, up front

**1. YES. `cb` infers distributed RAM.** MEASURED at three geometries. At
`CB_STYLE = "distributed"` every codebook copy becomes one `RAM32M16`, and the
16:1 mux per lane disappears completely. The object-level census is the
cleanest single line of it, at ROWS_IF=8:

```
v_regs_r8   CB cells named cb_reg*:  RAM=0     FF=1024
v_dist_r8   CB cells named cb_reg*:  RAM=4352  FF=0
```

**Lever C is not dead. It builds what LEVERC assumed it builds**, and its
12,288-LUTRAM figure for the FK33 geometry is confirmed exactly by a per-lane
constant that is 8.000 at all three measured points.

**2. YES, Vivado accepts the function-of-generic attribute value** -- it names
the resulting mapping `User Attribute` in its own report. **But the attribution
control denies the attribute any credit: it earns nothing here.** With
`ram_style` and `dont_touch` deleted outright the design is byte-identical in
every reported figure, and the mapping report simply relabels the inference
`Implied`. **No sibling-architecture fallback is needed.** The attribute is a
statement of intent that the tool would have reached on its own.

**3. NO. `ram_style = "registers"` does not change today's shipping build.**
Deleting it leaves LUT, LUT-as-logic, LUT-as-memory, distributed RAM, SRL, FF,
BRAM, DSP, MUXF7, MUXF8 and WNS identical to the last digit, and a repeat draw
of the baseline reproduces itself exactly, so "identical" is a demonstrated
no-op rather than two numbers that happened to match.

**THE TRAP, AND IT WOULD HAVE PRODUCED THE OPPOSITE ANSWER.** Vivado's log says
one hundred times that it did NOT do this:

```
WARNING: [Synth 8-7186] Applying attribute ram_style = "distributed" is ignored,
object 'cb[0][0]' is not inferred as ram due to incorrect usage
[.../matvec_core.vhd:214]
```

Every copy named in those warnings **is** in the Distributed RAM Final Mapping
Report as a `RAM32M16`, and `report_utilization` and the primitive census both
agree with the mapping, not with the warning. This is the mirror image of the
`[Synth 8-10226]` URAM trap TRACK NORMURAM hit the same day: there the log
claimed a resource the design never got, here it denies a resource the design
did get. **In both directions the log is not the answer. The census is.**

### What this does NOT cover

* **This is OOC synthesis, not placement.** Lever C's claim is about CLB
  PACKING, and only a place run measures that. LEVERC's `3,072 .. 8,946` CLB
  bound is narrowed at one end below but is not settled here.
* **The FK33 geometry itself (ROWS_IF=48, 1,536 lanes) was NOT synthesised.**
  ROWS_IF=16 already peaked at **14.38 GB** summed Vivado RSS on a 14 GB box.
  Everything at 1,536 lanes below is labelled DERIVED or ESTIMATE.
* **`matvec_core` alone**, not `matvec_int4` and not the composed A+B+C+D.
* **No functional verification was re-run.** LEVERC's value oracle and mutation
  table stand on their own; this track measured area and inference only.
* **SLICEM locality is untouched.** 12,288 `RAM32M16` all want SLICEM sites
  inside subsystem A's existing cluster, and no synthesis result speaks to that.

---

## 1. The procedure, and what each step isolates

The failure this design had to avoid is that "no LUTRAM" has **two** causes that
look identical in the utilization table: the SHAPE does not infer, or the
ATTRIBUTE never reached the tool. A single `CB_STYLE=distributed` run cannot
tell them apart, and a "no" from the wrong cause would have retired lever C for
the wrong reason.

So each variant is a whole edited copy of the three RTL files
(`sim/cbinfer_variants.sh`), and the synthesis script is told which directory to
read (`sim/ooc_cbinfer.tcl`). The variant build hard-fails if any `sed` matched
nothing and hard-fails unless all six variants have distinct md5s -- a variant
that is secretly a duplicate of the baseline would make the comparison read "no
change", which is the flattering answer this exercise must not produce by
accident.

| variant | what it is | what it isolates |
|---|---|---|
| `v_regs` | the shipping file, byte for byte | the baseline every number is read against |
| `v_regs_noattr` | `ram_style of cb` line DELETED, `dont_touch` kept | **question 3**: what `ram_style = "registers"` costs the current design |
| `v_dist` | `CB_STYLE` default -> `"distributed"`, attributes still functions of the generic | **question 1**, lever C exactly as LEVERC wrote it |
| `v_distlit` | as `v_dist` but attribute values are string LITERALS | **question 2**: separates "shape will not infer" from "attribute reader refused a non-literal" |
| `v_dist_noattr` | distributed, `ram_style` AND `dont_touch` on `cb` both deleted | the **attribution control**: does the attribute earn anything |
| `v_distlit_nodt` | distributed, literal `ram_style`, `dont_touch` REMOVED rather than set `"false"` | whether a `dont_touch` blocks inference by its PRESENCE rather than its value |

Order of work:

1. Sync the BC-250 and **md5 the load-bearing files against the local tree**
   before any tool runs. A number drawn against a stale tree is
   indistinguishable from a real one.
2. Build the six variants, verify six distinct md5s, and `ghdl -a` all six --
   catches a `sed` that produced illegal VHDL before four minutes of Vivado does.
3. Synthesise all six at ROWS_IF=4 (128 lanes), serially.
4. Read the **utilization table and the primitive census separately** and check
   they agree. If they disagree the census wins.
5. Read the **Distributed RAM Final Mapping Report** for the `Inference` column,
   which is the only artefact that says WHICH signal the memory came from and
   WHY the tool built it.
6. Repeat the baseline under a different tag: the determinism control, without
   which question 3's "identical" is an anecdote.
7. Two further geometries, ROWS_IF=8 and 16, so the per-lane figures are three
   measured points and not a model fitted to one.

---

## 2. The evidence

### 2.1 The tree the numbers were drawn against

`bash ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh`, then md5 both sides. MEASURED,
identical on both boxes:

```
163eab020fb0d5e00a3192344bea9e7f  rtl/matvec_core.vhd
07fb67e0161ac6f42c758288147bcadd  rtl/util_pkg.vhd
835e3be3a7624efd795ce96167320a49  rtl/mv4i_arith_pkg.vhd
8b2d2ee04a164866feb092a3281e505e  sim/ooc_fk33_a.tcl
dfbfef2f6fd007e111d2b7e9666fd287  sim/ooc_matvec_int4.tcl
```

and the six variant md5s, identical on both boxes:

```
v_regs           163eab020fb0d5e00a3192344bea9e7f   (== the repo file)
v_regs_noattr    c2dbdbcff9911933d556b0f98945fce0
v_dist           b416bb23d40baeacdaa5d3c82ae08df3
v_distlit        7516a82acaaad3fed54623f69f8e919d
v_distlit_nodt   a48ae53eb22b434813700f85f9ff8fbc
v_dist_noattr    79be328faf511bbd8c6477ef76f439cf
```

### 2.2 The six-variant table, ROWS_IF=4, BLK=32, 128 lanes

MEASURED, `report_utilization` after `synth_design -mode out_of_context`:

| variant | LUT | as logic | as mem | distRAM | SRL | FF | MUXF7 | MUXF8 | BRAM36 | DSP | WNS ns |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `v_regs` | 11553 | 11129 | 424 | 296 | 128 | 5765 | 2051 | 1024 | 18.5 | 132 | -0.544 |
| `v_regs_rep` (repeat) | 11553 | 11129 | 424 | 296 | 128 | 5765 | 2051 | 1024 | 18.5 | 132 | -0.544 |
| `v_regs_noattr` | 11553 | 11129 | 424 | 296 | 128 | 5765 | 2051 | 1024 | 18.5 | 132 | -0.544 |
| `v_dist` | 7827 | 6379 | 1448 | 1320 | 128 | 6865 | 0 | 0 | 18.5 | 132 | -0.524 |
| `v_distlit` | 7827 | 6379 | 1448 | 1320 | 128 | 6865 | 0 | 0 | 18.5 | 132 | -0.524 |
| `v_dist_noattr` | 7827 | 6379 | 1448 | 1320 | 128 | 6865 | 0 | 0 | 18.5 | 132 | -0.524 |
| `v_distlit_nodt` | 7827 | 6379 | 1448 | 1320 | 128 | 6865 | 0 | 0 | 18.5 | 132 | -0.524 |

Three exact groups. The three `regs` rows are identical to each other and the
four `dist` rows are identical to each other, in every column.

### 2.3 The cross-check: primitive census against the utilization table

MEASURED, the `8. Primitives` section of the same reports. The two must agree or
the census wins; they agree.

```
v_regs_r4   FDRE 5765  MUXF7 2051  MUXF8 1024  RAMD32 518  RAMS32  74  SRL16E 128
v_dist_r4   FDRE 6841  MUXF7    0  MUXF8    0  RAMD32 2310 RAMS32 330  SRL16E 128
```

* MUXF7 2051 census == `F7 Muxes` 2051 table; MUXF8 1024 == 1024. Agree.
* `(518 + 74) / 2 = 296` == `LUT as Distributed RAM` 296. Agree.
  (`(2310 + 330) / 2 = 1320` == 1320 for `v_dist`. Agree. Two `RAMD32`/`RAMS32`
  cells share one LUT6.)

### 2.4 The object-level census -- the decisive pair

The aggregate tables say how many LUTs became memory. They do not say which
SIGNAL. MEASURED at ROWS_IF=8 with `get_cells -hier`:

```
v_regs_r8   CB cells named cb_reg*:  RAM=0     FF=1024
v_dist_r8   CB cells named cb_reg*:  RAM=4352  FF=0
```

DERIVED: `v_regs` at ROWS_IF=8 has `CB_COPIES = 8`, so `8 * 16 * 8 = 1024` flip
flops -- exactly the FF count, and zero RAM cells. `v_dist` has
`CB_COPIES = 256`, and `256 * 17 = 4352` where 17 is the `RAM32M16` macro plus
its 16 leaf `RAMD32`/`RAMS32` cells; zero flip flops. **The codebook holds no
registers at all under lever C.**

### 2.5 Where the memory came from, and why -- the Inference column

MEASURED, `Distributed RAM: Final Mapping Report` in each run's log:

| variant | cb rows in the report | Inference | size | primitives |
|---|---:|---|---|---|
| `v_regs` | 0 | -- | -- | -- |
| `v_regs_noattr` | 0 | -- | -- | -- |
| `v_dist` | 128 | **User Attribute** | 16 x 8 | RAM32M16 x 1 each |
| `v_distlit` | 128 | **User Attribute** | 16 x 8 | RAM32M16 x 1 each |
| `v_distlit_nodt` | 128 | **User Attribute** | 16 x 8 | RAM32M16 x 1 each |
| `v_dist_noattr` | 128 | **Implied** | 16 x 8 | RAM32M16 x 1 each |
| all six | 1 | Implied | 2 x 512 | `xq_reg`, RAM32M16 x 37 |

Raw:

```
|Module Name | RTL Object      | Inference      | Size (Depth x Width) | Primitives     |
|matvec_core | cb_reg[31][11]  | User Attribute | 16 x 8               | RAM32M16 x 1   |
|matvec_core | cb_reg[30][11]  | User Attribute | 16 x 8               | RAM32M16 x 1   |
|matvec_core | xq_reg          | Implied        | 2 x 512              | RAM32M16 x 37  |
```

At ROWS_IF=16 the same report carries **512** `cb_reg` rows, one per copy.

**This is the whole of the answer to question 2.** `CB_RS` is
`cb_rs_f(CB_STYLE)`, a constant returned by a function of a generic; Vivado read
its value (it quotes it back as `ram_style = "distributed"` in the 8-7186
warning) and attributed the mapping to it. **And the attribution control shows
the attribute earned nothing**: `v_dist_noattr`, with no `ram_style` and no
`dont_touch` on `cb` at all, produces the same 128 copies, the same `RAM32M16`
each, and every identical number in section 2.2 -- it merely labels the
inference `Implied`. LEVERC's named fallback of two sibling architectures is
**not required**, and would buy nothing if it were built.

### 2.6 The log line that says the opposite, one hundred times

MEASURED, `v_dist` / `v_distlit` / `v_distlit_nodt` logs (and, correctly, zero
times in the two `regs` logs and zero in `v_dist_noattr`, which carries no
attribute to ignore):

```
WARNING: [Synth 8-7186] Applying attribute ram_style = "distributed" is ignored,
object 'cb[0][0]' is not inferred as ram due to incorrect usage
[/home/orencollaco/cbinfer-scratch/vars/v_dist/matvec_core.vhd:214]
...
WARNING: [Synth 8-7186] Applying attribute ram_style = "distributed" is ignored,
object 'cb[6][3]' is not inferred as ram due to incorrect usage
[/home/orencollaco/cbinfer-scratch/vars/v_dist/matvec_core.vhd:214]
INFO: [Common 17-14] Message 'Synth 8-7186' appears 100 times and further
instances of the messages will be disabled.
```

The warnings are emitted against per-ELEMENT objects `cb[c][e]` and stop at
Vivado's own 100-message cap, so they cover copies 0..6 only. **All seven of
those copies appear in the Final Mapping Report as `User Attribute` RAM32M16**:

```
|matvec_core | cb_reg[0][11]   | User Attribute | 16 x 8 | RAM32M16 x 1 |
|matvec_core | cb_reg[1][11]   | User Attribute | 16 x 8 | RAM32M16 x 1 |
... through cb_reg[6][11]
```

A track that grepped its log for `ram_style` and stopped would have reported
"NO, and Vivado says so in as many words", retired lever C, and been wrong.

### 2.7 Three geometries: the per-lane figures are measured, not fitted

MEASURED. `v_regs` versus `v_dist` at ROWS_IF = 4, 8, 16 (128, 256, 512 lanes):

| | 128 lanes | 256 lanes | 512 lanes |
|---|---:|---:|---:|
| LUT regs / dist | 11553 / 7827 | 21531 / 14438 | 40367 / 27029 |
| LUT as distributed RAM regs / dist | 296 / 1320 | 296 / 2344 | 296 / 4392 |
| **distributed RAM added** | **1024** | **2048** | **4096** |
| **per lane** | **8.000** | **8.000** | **8.000** |
| MUXF7 regs / dist | 2051 / 0 | 4097 / 5 | 8196 / 0 |
| **MUXF7 removed, per lane** | **16.02** | **15.98** | **16.01** |
| MUXF8 regs / dist | 1024 / 0 | 2048 / 0 | 4096 / 0 |
| **MUXF8 removed, per lane** | **8.000** | **8.000** | **8.000** |
| FF regs / dist | 5765 / 6865 | 10709 / 12907 | 20627 / 25031 |
| FF change | +1100 | +2198 | +4404 |
| BRAM36 (both) | 18.5 | 28.5 | 28.5 |
| DSP (both) | 132 | 264 | 528 |
| WNS ns regs / dist @3.3 ns | -0.544 / -0.524 | +0.506 / +0.528 | +0.499 / +0.543 |

**8.000 LUTRAM per lane and 8.000 MUXF8 per lane at all three points, exactly.**
MUXF7 carries a residual of 0 to 5 cells that belongs to logic outside the
codebook and jitters between draws; the codebook's own contribution is 16.00
per lane to within 0.02.

**This reproduces CONGEST's shell-build per-lane census exactly** (16.0 MUXF7,
8.0 MUXF8 per lane), now at three geometries on the composed part rather than
one, and **confirms LEVERC's LUTRAM assumption of 8 per lane**, which had been
an assumption.

The FF change has an exact closed form. DERIVED: lever C removes
`CB_COPIES_regs * 128` codebook flops and adds `(lanes - CB_COPIES_regs) * 13`
command-register flops (1 valid + 4 address + 8 data per copy):

```
128 lanes:  (128-4)*13  - 4*128  = +1100   MEASURED +1100   delta  0
256 lanes:  (256-8)*13  - 8*128  = +2200   MEASURED +2198   delta -2
512 lanes:  (512-16)*13 - 16*128 = +4400   MEASURED +4404   delta +4
```

**DERIVED at the FK33 geometry** (ROWS_IF=48, 1,536 lanes,
`CB_COPIES_regs = 48`): `(1536-48)*13 - 48*128 = 19,344 - 6,144 = +13,200 FF`.
That is 1.5% of the part's 879,360 and, as `matvec_core.vhd` already argues, FF
is the currency with room.

### 2.8 What DERIVES cleanly to 1,536 lanes, and what does not

**DERIVED (exact per-lane constants, three points each):**

```
distributed RAM added    1,536 * 8.000  =  12,288 LUT as memory
MUXF7 removed            1,536 * 16.00  =  24,576
MUXF8 removed            1,536 *  8.000 =  12,288
codebook flip-flops                     =  0 (was 48 * 128 = 6,144)
```

All three match LEVERC section 3.1 exactly. **The 12,288 LUTRAM figure the whole
lever-C arithmetic rests on is now MEASURED per-lane rather than assumed.**

**ESTIMATE, and the weak one: total LUT saving.** The per-lane LUT saving is NOT
constant -- it FALLS with lane count: 29.11, 27.71, 26.05 at 128, 256, 512. Two
projections to 1,536 disagree:

| model | fitted on | at 1,536 lanes |
|---|---|---|
| linear in lanes, fitted on the two extremes | (128, 3726), (512, 13338) | 38,970 LUT saved |
| linear in log2(lanes) | the same two per-lane figures | 36,291 LUT saved |

The first mispredicts the MEASURED middle point by -163 LUT (-2.3%). **Neither
is evidence about 1,536 lanes**, which is three times the largest point drawn;
both are labelled ESTIMATE and both would be falsified or confirmed by a single
ROWS_IF=48 draw, which is the open item. Quote **36,000 to 39,000 LUT** with the
range, never a point value. The assumption in both is that the non-codebook part
of `matvec_core` scales the same way in the two styles; what would falsify it is
that ROWS_IF=48 draw.

### 2.9 One number this tightens for LEVERC

LEVERC section 3.3 costs the LUTRAM replacement at

```
LUTRAM replacement   12,288 LUTRAM, 8 per SLICEM CLB when they
                     share WCLK/WE (they do, per row)  =  1,536
                     if only 4 per CLB (fragmented)    =  3,072
```

MEASURED here: each copy is **one `RAM32M16` macro occupying 8 LUTs**
(1024 LUT-as-memory / 128 copies at ROWS_IF=4, and 4096 / 512 at ROWS_IF=16 --
8.000 both times). DERIVED: an UltraScale+ CLB holds 8 LUT6, so a `RAM32M16` is
CLB-atomic and **cannot be placed 4-to-a-CLB**. The fragmented bound is not
reachable by this netlist, so LEVERC's CLB saving narrows at its pessimistic end:

```
                                LEVERC          with this measurement
LUTRAM CLBs                 1,536 .. 3,072      1,536 exactly
CLB saving                  3,072 .. 8,946      4,608 .. 8,946
```

**This is a synthesis fact about the macro, not a placement result**, and the
upper end still depends entirely on how loosely the mux region packs today,
which only a place run answers. **The lever still does not close the fit under
either bound**, exactly as LEVERC concluded.

---

## 3. Measured and REJECTED -- do not retry

**1. Reading the answer out of the synthesis log.** `[Synth 8-7186]` says
`ram_style = "distributed" is ignored, object 'cb[c][e]' is not inferred as ram
due to incorrect usage`, one hundred times, and it is WRONG: every object it
names is a `RAM32M16` in the same run's Final Mapping Report. Do not grep for
it, do not act on it, and do not treat its absence as reassurance either --
`v_dist_noattr` has zero of them and infers exactly the same RAM.

**2. Two sibling architectures as the attribute fallback.** LEVERC named this as
the fix if Vivado rejected a non-literal attribute value. Vivado does not reject
it: the mapping report attributes 128 of 128 copies to `User Attribute`. And the
attribution control goes further -- with no attribute at all the result is
byte-identical. **There is nothing for a second architecture to fix.**

**3. `dont_touch = "false"` as a suspected inference blocker.** The hypothesis
was that a signal carrying ANY `dont_touch` might be excluded from RAM inference
by the attribute's presence rather than its value. MEASURED: `v_distlit`
(`dont_touch = "false"`) and `v_distlit_nodt` (attribute deleted) are identical
in all twelve reported columns. Not a factor.

**4. Passing `CB_STYLE` as a `-generic` on the `synth_design` line.** Not
attempted, deliberately, and it should not be attempted for THIS question: it
cannot express the literal-attribute variant, which is the only thing that
separates "the shape will not infer" from "the attribute reader refused a
non-literal". It is fine for drawing area points once inference is settled.

**5. ROWS_IF=48 on the BC-250.** MEASURED peak summed Vivado RSS:
`ROWS_IF=4` 3.62-4.34 GB, `ROWS_IF=8` 3.87 GB, **`ROWS_IF=16` 14.38 GB** on a
14 GB box -- it survived only on swap. ROWS_IF=48 is 3x the lanes again. **Do
not send it there.** If the FK33-geometry draw is wanted it belongs on the
workstation, alone.

---

## 4. Measurement traps hit, including my own

**1. My own primitive-census parser silently produced a table of zeros.** The
`8. Primitives` section is THREE columns (`Ref Name | Used | Functional
Category`), not the four-column shape every other table in `report_utilization`
uses. The first parser required a fourth numeric field, matched nothing, and
wrote `muxf7=0 muxf8=0 fdre=0 ram_cells=0` into the CSV **beside a utilization
table full of real numbers** -- for six consecutive runs. A census of zeros is
indistinguishable from a design with no primitives, and it is exactly the
cross-check that was supposed to catch the utilization table lying. The parser
now takes the section by its heading and **hard-errors if it parses zero rows**;
the first six rows of `results_r4_r16.csv` still carry the zeros and are
superseded by `results_r8_objcensus.csv` and by the tables above, which were
read out of the reports by hand.

**2. I nearly reported "NO" off the log.** The first grep of the `v_dist` log
returned a wall of `ram_style ... is ignored ... not inferred as ram`. That is
the answer the brief warned might come back, in the tool's own words, and it
took reading the Final Mapping Report and the primitive census to see that it is
false. **The coordinator's mid-track correction about `[Synth 8-10226]` is the
same defect in the other direction and arrived while this was on screen.**

**3. `ps -eo args | grep unwrapped/lnx64.o/vivado` is not a Vivado detector.**
Corrected mid-track by the coordinator after TRACK NORMURAM lost eleven minutes
to it. The sampler used here walks `/proc/PID/exe`, which a command line cannot
spoof. **Its summed RSS is still an UPPER BOUND, not a footprint**: Vivado forks
parallel-synthesis workers that share pages with the parent, and summing VmRSS
double-counts them. The 14.38 GB figure should be read as "too close to 14 GB to
go further", not as a precise 14.38.

**4. `ssh <fish host> "cd X; cmd"` silently ran in the wrong directory.** The
BC-250's login shell is fish and `bash -c` wrapping mangled the `cd` on this
path; `md5sum` then reported `No such file or directory` for files that existed.
**Use absolute paths in every remote command.** A quieter version of this would
have md5'd nothing and been read as a match.

**5. `/usr/bin/time` does not exist on CachyOS.** Three runs "started" and
"failed" within the same second before this was noticed. The sentinel gate
caught it correctly -- the runner reported FAIL because `CBINFER_DONE` was
absent -- which is the reason the gate is on a sentinel and not on an exit code.

**6. A model fitted to two points was nearly quoted as a measurement.** The
per-lane LUT saving looked constant at two points and is not: 29.11, 27.71,
26.05. The third point (ROWS_IF=8) was run specifically to test the model rather
than extend it, and it falsified the linear form by 2.3%. The structural
figures -- LUTRAM, MUXF7, MUXF8 per lane -- survived the same test exactly, and
those are the ones the lever-C arithmetic actually needs.

---

## 5. Open, not yet answered

1. **The FK33 geometry itself.** ROWS_IF=48, 1,536 lanes, `v_regs` versus
   `v_dist`. Everything in section 2.8 marked ESTIMATE collapses to a
   measurement with that one pair of draws. It does not fit on the BC-250 and
   needs a quiet workstation.
2. **The CLB saving, which is the number lever C is actually about.** Section
   2.9 narrows LEVERC's bound to 4,608 .. 8,946 CLB using a synthesis fact about
   macro atomicity. Only `place_design` on the composed A+B+C+D with `CB_STYLE`
   at each value collapses it, and per TRACK SCATTER it needs repeats.
3. **SLICEM locality.** 12,288 LUTRAM is 6.0% of the part's 205,440 LUT-as-
   memory sites, so capacity is not the issue, but only ~47% of CLB columns are
   SLICEM and the copies want to sit inside subsystem A's existing row clusters.
   A placement question no synthesis result answers.
4. **The 12,288-D-input write fanout**, still named and not measured. What IS
   now measured is its flop cost: **+13,200 FF** at the FK33 geometry (section
   2.7), which is the budget any `CB_BCAST` rank would be added on top of.
5. **Timing.** `v_dist` has a marginally better WNS than `v_regs` at all three
   geometries (+0.020, +0.022, +0.044 ns), but these are OOC and unplaced, the
   fanout that motivated the whole replica design is 32x larger under lever C,
   and the codebook was the critical path only AFTER routing. **Nothing here
   should be read as a timing result.**
6. **Whether removing the mux shapes helps ROUTING even where it does not help
   density** -- LEVERC's item 7. Untouched.
7. **The composed design.** All of this is `matvec_core` in isolation. LEVERC's
   correction 1 stands: the codebook is 37.7% of the composed MUXF7, not 97.7%.

---

## 6. Reproducing this

```
bash ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh
# then, on the BC-250, ONE Vivado at a time:
bash sim/cbinfer_run.sh <scratchroot> 4
# a single point:
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
vivado -mode batch -source sim/ooc_cbinfer.tcl \
       -tclargs <tag> <scratchroot>/vars/v_dist rows=8 outdir=<scratchroot>/out
```

Artefacts: `hw/fk33/results/cbinfer_2026-08-30/` -- the eleven
`report_utilization` files, both results CSVs, the Final Mapping Report extract
per variant, the 8-7186 warning extract beside the mapping rows that contradict
it, and the object-level `cb` census.
