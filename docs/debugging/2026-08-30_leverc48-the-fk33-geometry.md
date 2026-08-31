# Lever C at the FK33 geometry: what does moving the IQ4_NL codebook to LUTRAM actually cost and save at ROWS_IF=48?

**Date:** 2026-08-30
**Track:** LEVERC48
**Repo state at start:** `3f1235c` ("the ordered plan from here to 9B
inference on the card"), branch `fpga`. `rtl/matvec_core.vhd` md5
`163eab020fb0d5e00a3192344bea9e7f` -- byte-identical to the file TRACK CBINFER
drew ROWS_IF 4/8/16 against, verified against `git show HEAD:` before any tool
ran.
**Machine:** the workstation only. Vivado 2023.2, part
`xcvu33p-fsvh2104-2L-e`, `synth_design -mode out_of_context` and `report_*`
only. GHDL 1.0.0 mcode for everything else. The BC-250 lane was held by TRACK
RMSWIRE and was not touched.
**Hardware:** none. No `xsdb`, no `hw_server`, no programming, no JTAG, no
`hw/fk33/host/*`, nothing opening `/dev/xdma*`. The card was left alone.

---

## The question, verbatim

From the dispatch:

> **Implement lever C in `rtl/matvec_core.vhd` -- move the IQ4_NL codebook from
> registers to LUTRAM -- and draw it at the FK33 geometry `ROWS_IF=48`.** The
> inference question is ANSWERED; the implementation and the real-geometry
> number are not.
>
> **WHAT IS MISSING AND IS YOUR JOB: `ROWS_IF=48`, the FK33 geometry, was NOT
> drawn.** [...] The total saving is currently an **ESTIMATE of 36,000-39,000
> LUT**, because per-lane saving FALLS with lane count (29.11 / 27.71 / 26.05)
> and **two models disagree**.
>
> **Turn the ESTIMATE into a MEASUREMENT.** If the two models still disagree at
> 48, say which one the data supports and by how much, and do not average them.

---

## The answers, up front

**1. MEASURED at ROWS_IF=48: lever C saves 42,633 LUT, and BOTH models were
wrong, in the same direction, by 8.6% and 14.9%.** The quoted ESTIMATE range of
"36,000 to 39,000 LUT" **does not contain the answer**. The linear-in-lanes
model (38,970) is the less wrong of the two by 2,679 LUT; the log2 model
(36,291) is worse. **Do not average them** -- their mean, 37,630, is worse than
the better one alone.

**2. Both models failed for the same reason and it is not a coefficient: the
per-lane LUT saving is NOT monotone in lane count.** Two further geometries were
drawn to characterise it, giving six points:

```
lanes    128     256     512     768    1024    1536
per-lane 29.109  27.707  26.051  25.353  28.391  27.756
```

It falls to a minimum at 768 lanes and then rises. Three points in a row moving
one way is three points, not a trend. Both models assumed the trend; every point
past the three they were fitted to falsifies the functional form of each.

**2a. AND THE FINDING THAT MATTERS MORE: NOT FITTING BEATS FITTING, ON THE SAME
DATA.** A constant per-lane saving -- the arithmetic mean of the same three
points both models were fitted to, 27.622, with no trend and no free parameter
beyond the mean -- predicts `27.622 x 1536 = 42,428` against a MEASURED 42,633.

```
model                                       at 1,536    error     %
linear in lanes         (2 params, 2 points)  38,970    -3,663   -8.59
linear in log2(lanes)   (2 params, 2 points)  36,291    -6,342  -14.88
constant, calibrated at 512 alone             40,014    -2,619   -6.14
constant, mean of the SAME three points       42,428      -205   -0.48
```

The measured spread of the per-lane figure across a 12x range of lane counts is
only +-6.9% about its mean. **Both fitted models turned that scatter into a
trend and extrapolated it, which is exactly how a two-parameter fit to two
points produces a systematic error larger than the noise it was fitted to.**
Part of the 0.48% is luck; the reusable part is not. When a quantity is flat
with scatter, the mean is the estimator and a slope is an artefact.

**3. Every STRUCTURAL per-lane constant survived the 3x extrapolation exactly**,
which is the distinction that matters:

```
LUT as distributed RAM added   12,288 = 1,536 x 8.000   EXACT
MUXF8 removed                  12,288 = 1,536 x 8.000   EXACT
MUXF7 removed                  24,583 = 1,536 x 16.005  (+7 residual)
CLB FF added                  +13,195 against DERIVED +13,200, residual -5
```

and the two new geometries hold them to the same standard: 8.0000 LUTRAM per
lane and 8.0000 MUXF8 per lane EXACTLY at 768 and at 1,024, MUXF7 residuals +6
and -4, and the flip-flop closed form
`(lanes - CB_COPIES_regs) x 13 - CB_COPIES_regs x 128` exact to **zero** at both.

So CBINFER's structural figures extrapolate and its LUT total does not, exactly
as it labelled them. The 12,288-LUTRAM figure the whole lever-C arithmetic rests
on is now MEASURED at the real geometry rather than derived from three smaller
ones.

**4. NEW, and it changes CBINFER's open item 5: WNS moves the WRONG WAY at the
FK33 geometry, by 0.269 ns, and the six points show where it turns.**

```
lanes            128     256     512     768    1024    1536
WNS regs      -0.544  +0.506  +0.499  +0.496  +0.496  +0.242
WNS dist      -0.524  +0.528  +0.543  +0.612  +0.496  -0.027
lever C gains +0.020  +0.022  +0.044  +0.116   0.000  -0.269
```

Lever C's timing advantage GROWS to 768 lanes, vanishes at 1,024, and reverses
hard at 1,536. CBINFER saw only the first three columns and reported
"marginally better WNS at all three geometries"; that is true and does not
extrapolate. Both are still far above target -- 327.0 MHz against 300.6 MHz
OOC, versus a 200 MHz build -- so this is **not a blocker**. It is the first
evidence that the `CB_BCAST` rank named in the RTL is load-bearing at 1,536
copies rather than optional, and it is the sign the 32x command fanout would
predict. **At the real 5.0 ns build period, measured on `matvec_int4` in section
4.7, the cost is only -0.029 ns with 1.18 ns of margin left**, so the 3.3 ns
figure should be read as a sensitive probe rather than as the build's problem.

**5. THE CLB SAVING IS STILL NOT MEASURED, AND NOTHING HERE MEASURES IT.**
Lever C's claim is about CLB PACKING. This is out-of-context synthesis. Only
`place_design` measures packing. What this draw does do is correct one INPUT to
LEVERC's bound: the codebook's LUT footprint at this geometry is **54,921**, not
the 49,152 LEVERC charged it at -- 11.7% more, because ~3.8 LUT per lane of
read-path logic outside the F7/F8 shapes also disappears. Rescaling LEVERC's
bound by that ratio gives **5,329 .. 10,177 CLB** instead of 4,608 .. 8,946.
**Lever C still does not close the 11,534-CLB composed overshoot under either
end.** LEVERC's conclusion is unchanged and this is not a fit-closer.

**6. The implementation gap was not where the brief thought it was, and this is
a correction to the brief.** `rtl/matvec_core.vhd` has carried the full lever-C
implementation since `845ea28` (TRACK LEVERC). What did not exist was any way to
SELECT it: no wrapper between a board top and `matvec_core` declared or
forwarded `CB_STYLE`, so the lever was implemented and **unreachable from any
build**. That is closed here -- `matvec_int4`, `matvec_int4_desc_axi` and
`matvec_int4_axi` now carry and forward the generic, defaulting to `"regs"`.
Taking lever C on the FK33 is now one generic on one instantiation.

**And the threading was MEASURED in SYNTHESIS, not only in simulation** (section
4.7), which is the check the whole implementation rests on and is not the same
mechanism CBINFER tested. With `CB_STYLE` given on the `synth_design` command
line at `matvec_int4` and propagated through two port maps, `cb_reg*` goes from
6,144 flip-flops and no RAM to **26,112 RAM cells and no flip-flops** -- the
identical `1,536 x 17` the `matvec_core`-only draw gives. At that level the
saving is **45,768 LUT**, larger than `matvec_core`'s 42,633, and at the real
5.0 ns build period the timing cost is only **-0.029 ns** with both styles
holding over 1.18 ns of margin.

**7. Two new guards, and the attribution control gives them ONE kill each, not
two.** They catch different things and neither is redundant:

| guard | kills | does NOT kill |
|---|---|---|
| `CHK_CB_STYLE` (out-of-range `natural`) | M2, a typo'd `CB_STYLE` that silently builds the register bank | M1 |
| `p_cb_style_ann` (announcement keyed on `CB_LANES_PER_COPY`) | M1, a wrapper that declares the generic and forgets to forward it | M2 |

**The value oracle catches NEITHER.** Both mutants pass `tb_matvec_fk33_desc`'s
element-exact comparison against `ref/matvec_int4.c` with a clean verdict line,
because both build a design that is correct and is not the one that was asked
for. That is the whole point: a lever that does nothing looks exactly like a
lever that worked.

**8. The write-coherency oracle now runs at the ACTUAL 1,536 replicas**, which
LEVERC could not claim (its table ran at 64). `tb_matvec_cb_contract` passes at
`BLK=32 ROWS_IF=48 CB_STYLE=distributed` in 5.3 s and 303 MB, and five mutants
that model a stale or late replica all KILL there, one of them naming copy 768 --
the upper half, which is the shape a two-level broadcast tree over 1,536 copies
would produce.

**9. `K2b` stays closed.** The full 20-row, 9-column mutation table is identical
under both styles and identical to LEVERC's, no anchor failed, and the
attribution control still credits `P_CB_MODEL` with exactly `K2b` and `K2c`.

---

## 1. What was done

| file | change |
|---|---|
| `rtl/matvec_core.vhd` | `CHK_CB_STYLE`, an out-of-range `natural` that hard-errors on any `CB_STYLE` other than the two legal values; `p_cb_style_ann`, a `translate_off` announcement keyed on `CB_LANES_PER_COPY = 1`; the "UNVERIFIED" block on `cb_dt_f`/`cb_rs_f` replaced with CBINFER's measured answers and the `[Synth 8-7186]` warning; the CLB-arithmetic comment given this draw's numbers |
| `rtl/matvec_int4.vhd` | `CB_STYLE` generic, default `"regs"`, forwarded to `matvec_core` |
| `rtl/matvec_int4_desc_axi.vhd` | same, forwarded to `matvec_int4` |
| `rtl/matvec_int4_axi.vhd` | same |
| `sim/tb_matvec_fk33_desc.vhd` | `CB_STYLE` generic, default `"regs"`, forwarded to BOTH DUTs |
| `sim/leverc48_run.sh` | new: draws a named, FROZEN variant tree, and never rebuilds it |
| `sim/ooc_leverc48_thread.tcl` | new: synthesises `matvec_int4` OOC with `CB_STYLE` on the command line, to answer whether the generic threads in SYNTHESIS and not only in simulation |

`rtl/matvec_int4_ip.vhd` was deliberately NOT touched. It is the packaged IP the
AXU3EG block design reads, its own comment records that the BD takes its
generics from the DEFAULTS, and lever C is an FK33 change. Adding a generic
there would require repackaging the IP for no benefit.

**No new `sim/tb_*.vhd`, so no new gate row.** MEASURED, `sim/regress.sh
--list` at the edited tree: **116 RUN rows**, of which 19 are other tracks'
untracked rows. Rows are discovered from `sim/tb_*.vhd` and `tb/tb_*.vhd`, and
this track adds none -- `sim/leverc48_run.sh` and `sim/ooc_leverc48_thread.tcl`
are not benches -- so the count cannot have moved. `BASELINE_PASS` stays 99.

### 1.1 Why the announcement is keyed on the built shape, not on the string

It was written first as `if CB_STYLE /= "regs"`, and MEASURED itself wrong -- see
section 4.3. `CB_LANES_PER_COPY = 1` is reachable only through the
`"distributed"` branch of `cb_lpc_f` (the other branch returns `rpc*BLK >= 32`),
so the announcement reports a fact about the netlist rather than a fact about a
string.

---

## 2. The procedure, and what each step isolates

1. **Freeze the variant tree BEFORE editing any RTL, and md5 it against
   `git show HEAD:`.** `sim/cbinfer_run.sh` rebuilds its variant directory from
   the live `rtl/` on every invocation, which is right for one sweep and wrong
   for a track that also edits `rtl/`: a second invocation silently replaces the
   sources the first sweep's numbers were drawn against. `sim/leverc48_run.sh`
   exists because of that, and takes an explicit read-only tree.
2. **Draw the ROWS_IF=48 pair first**, `v_regs` then `v_dist`, serially, in one
   session, before touching anything. A control from another session or another
   box is not a control.
3. **Read the utilization table and the primitive census separately and check
   they agree**, then read the object-level `cb` census, then read the
   Distributed RAM Final Mapping Report. Three independent artefacts, because
   the synthesis LOG is known to be wrong in both directions.
4. **Thread the generic**, then re-run the 12 `matvec` gate rows at the default
   to show the shipping path did not move.
5. **Exercise the threaded path with the value oracle** at
   `-gCB_STYLE=distributed`, and confirm `CB_COPIES = 1536` is reported from
   inside `matvec_core`. A bench that passes identically either way proves
   nothing about whether the generic arrived.
6. **Mutate the threading and the guard, and run the attribution control on
   each.** A kill does not settle it.
7. **Run the coherency contract and five coherency mutants at the real
   1,536-replica count**, not at the bench default of 64.
8. **Re-run the full 20-row mutation table in both styles** to show no anchor
   was broken by the RTL edits.
9. **Draw the ROWS_IF=48 pair AGAIN from the edited tree** -- the neutrality
   control, which is what attaches the numbers in step 2 to the file that gets
   committed.
10. **Draw ROWS_IF=24 and 32 from the frozen pre-edit tree** to characterise the
    per-lane curve the two models got wrong.
11. **Synthesise `matvec_int4` with `CB_STYLE` on the command line**, at both
    values, and read the object-level `cb` census. This is the only step that
    tests what the implementation is FOR: that Vivado propagates a string
    generic across two hierarchy boundaries and the attribute functions in the
    child still evaluate against it.

---

## 3. The evidence: the FK33-geometry draw

### 3.1 Provenance

MEASURED, before any tool ran:

```
163eab020fb0d5e00a3192344bea9e7f  vars_pre/v_regs/matvec_core.vhd
b416bb23d40baeacdaa5d3c82ae08df3  vars_pre/v_dist/matvec_core.vhd
163eab020fb0d5e00a3192344bea9e7f  git show HEAD:rtl/matvec_core.vhd
```

Both md5s are identical to the ones CBINFER recorded on the BC-250, so the
ROWS_IF 4/8/16 points and the ROWS_IF=48 point are the same file.

### 3.2 The pair

MEASURED. `synth_design -mode out_of_context -top matvec_core`, `BLK=32`,
`MAXCOLS=MAXROWS_BFP=17408`, clock period 3.3 ns created BEFORE `synth_design`,
`general.maxThreads 4`. `v_regs` 19:22:08-19:29:10, `v_dist` 19:29:10-19:35:22.
Both gated on the `CBINFER_DONE` sentinel and a non-empty report, not on an exit
code.

| | `v_regs_r48` | `v_dist_r48` | delta | per lane (1,536) |
|---|---:|---:|---:|---:|
| CLB LUT | 121,139 | 78,506 | **-42,633** | -27.756 |
| LUT as Logic | 120,013 | 65,092 | -54,921 | -35.756 |
| LUT as Memory | 1,126 | 13,414 | +12,288 | +8.000 |
| LUT as Distributed RAM | 296 | 12,584 | +12,288 | **+8.000 exact** |
| LUT as Shift Register | 830 | 830 | 0 | |
| CLB Registers | 60,268 | 73,463 | **+13,195** | |
| F7 Muxes | 24,583 | 0 | -24,583 | -16.005 |
| F8 Muxes | 12,288 | 0 | -12,288 | **-8.000 exact** |
| Block RAM Tile | 21.5 | 21.5 | 0 | |
| DSPs | 1,584 | 1,584 | 0 | |
| `cb_reg*` RAM cells | 0 | 26,112 | | `= 1,536 x 17` |
| `cb_reg*` FF cells | 6,144 | 0 | | `= 48 x 128` |
| WNS @ 3.3 ns | **+0.242** | **-0.027** | **-0.269** | |

### 3.3 The three cross-checks, which agree

**Utilization table against primitive census** (the census is the authority when
they differ; they do not differ):

```
F7 Muxes table 24,583 == census MUXF7 24,583      F8 12,288 == 12,288   (v_regs)
F7 Muxes table      0 == census MUXF7      0      F8      0 ==      0   (v_dist)
LUT as Distributed RAM 296    == census (RAMD32+RAMS32)/2 = 592/2       (v_regs)
LUT as Distributed RAM 12,584 == census 25,168/2                        (v_dist)
```

**Object-level `cb` census** -- the decisive pair, because the aggregate tables
say how many LUTs became memory and not which SIGNAL:

```
v_regs_r48   CB cells named cb_reg*:  RAM=0      FF=6144
v_dist_r48   CB cells named cb_reg*:  RAM=26112  FF=0
```

DERIVED: `48 copies x 16 entries x 8 bits = 6,144` flip-flops, and
`1,536 x 17 = 26,112` where 17 is the `RAM32M16` macro plus its 16 leaf cells.
Both exact. **The codebook holds no registers at all under lever C, at the real
geometry.**

**Distributed RAM Final Mapping Report**: 1,536 `cb_reg` rows in `v_dist_r48`,
all `User Attribute`, all `16 x 8`, all `RAM32M16 x 1`; zero in `v_regs_r48`.

### 3.4 The trap, reproduced at this geometry

MEASURED, `v_dist_r48`'s log carries **101** `[Synth 8-7186]` lines (100
warnings plus Vivado's own "appears 100 times" cap notice), each saying
`Applying attribute ram_style = "distributed" is ignored, object 'cb[c][e]' is
not inferred as ram due to incorrect usage`. `v_regs_r48` carries zero.

**All 1,536 copies -- including every one those 100 warnings names -- are
`RAM32M16` rows in the same run's Final Mapping Report.** The log is wrong in
exactly the direction CBINFER measured it wrong at 4/8/16 lanes, and a track
that grepped the log and stopped would have reported that lever C does not build
at the FK33 geometry. Raw extract:
`hw/fk33/results/leverc48_2026-08-30/synth_8-7186_vs_mapping_r48.txt`.

---

## 4. The evidence: verification

### 4.1 The shipping path does not move

`REGRESS_SCRATCH=... bash sim/regress.sh --only matvec`, at the edited RTL, all
generics at their defaults:

```
suite sim   PASS 11   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0
suite tb    PASS 1    FAIL 0
OVERALL     PASS 12   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   SKIPPED 0
```

12, which is LEVERC's number for the same filter. `OVERALL PASS 12` is the line
that was read, not `REGRESSION: PASS` -- a `--only` that matches nothing still
prints the latter.

Re-run at the EXACT committed state (`matvec_core.vhd` md5
`b616c7822f93154b08200f9418489012`), over every filter that reaches an edited
file:

```
--only matvec           OVERALL PASS 12  FAIL 0  BUILD-ERROR 0  SKIPPED 0
--only a_geom           OVERALL PASS 1   (A_ROWS_IF = 48, the FK33 shape)
--only weight_streamer  OVERALL PASS 1
--only fk33_seam        OVERALL PASS 1   ("a whole token ran")
--only mv4i_desc_image  OVERALL PASS 1
```

### 4.2 The threaded path, with the value oracle

MEASURED. `tb_matvec_fk33_desc`, which drives `matvec_int4_desc_axi ->
matvec_int4 -> matvec_core` and compares element-exactly against
`ref/matvec_int4.c`:

```
[default, "regs"]        rc=0  LEVER C ACTIVE lines=0  oracle verdict present
[-gCB_STYLE=distributed] rc=0  LEVER C ACTIVE lines=2  oracle verdict present

rtl/matvec_core.vhd:623:@0ms:(report note): matvec_core: LEVER C ACTIVE
  CB_STYLE=distributed  CB_COPIES=1536  CB_LANES_PER_COPY=1  CB_WR_LAT=1

sim/tb_matvec_fk33_desc.vhd:2028:(report note): subsystem A is bit-exact with
  ref/matvec_int4.c through the descriptor control plane, and every checked
  mutation is refused
```

`CB_COPIES = 1536` is one copy per lane at `ROWS_IF=48, BLK=32`, read out of the
elaborated constant inside `matvec_core` rather than asserted from outside. The
second line is the bench's smaller second DUT at `B_RI=4`, reporting 128.

### 4.3 The teeth, and the attribution control on each

**M1 -- `matvec_int4` declares `CB_STYLE` and does not forward it to
`matvec_core`.** The anchor was checked (`cmp` against the real file) before the
run, so a `sed` that matched nothing could not pass as a survivor.

```
M1        rc=0  LEVER C ACTIVE lines=0  oracle verdict PRESENT
restored  rc=0  LEVER C ACTIVE lines=2  oracle verdict PRESENT
```

**The value oracle passes under M1.** It compares the same values, gets the same
answer, and prints the same verdict, because the design M1 builds is the
register bank -- correct, and not the one that was asked for. Only the
announcement discriminates.

**M2 -- `CB_STYLE => "distrbuted"`, one letter wrong.**

```
M2  (guard LIVE)    rc=1
  ghdl:error: bound check failure at rtl/matvec_core.vhd:228
  from: work.matvec_core(rtl).DECL_ELAB at matvec_core.vhd:228
```

Line 228 is `constant CHK_CB_STYLE : natural := cb_style_chk_f(CB_STYLE);`. It
fires during DECLARATION elaboration, before any statement runs.

**M2S -- the attribution control, `CHK_CB_STYLE` deleted outright:**

```
M2S (guard DELETED) rc=0  oracle verdict PRESENT  LEVER C ACTIVE lines=2
  matvec_core: LEVER C ACTIVE  CB_STYLE=distrbuted  CB_COPIES=48
    CB_LANES_PER_COPY=32  CB_WR_LAT=1
```

**This killed the first version of my own announcement.** With the guard gone,
the typo produced a design that is the register bank, a passing oracle, AND a
line saying `LEVER C ACTIVE` -- a guard passing for the wrong reason, which is
the exact defect class `CLAUDE.md` names. The announcement was rewritten to key
on `CB_LANES_PER_COPY = 1`, re-teeth-checked against M1 (still kills) and
re-run on both styles (`lines=0` / `lines=2`, oracle present in both).

**Attribution, stated plainly:** `CHK_CB_STYLE` earns M2 and earns nothing on
M1. `p_cb_style_ann` earns M1 and earns nothing on M2. Neither earns anything
the value oracle already had, because the value oracle catches neither.

### 4.4 The write-coherency surface at 1,536 replicas

This is the 32x surface Oren's standing condition is about, measured at the
count lever C actually ships rather than at the bench default of 64.

MEASURED, `tb_matvec_cb_contract -gBLK=32 -gROWS_IF=48 -gCB_STYLE=distributed`,
run under `MemoryMax=6G` so it would be killed rather than thrash beside the
Vivado lane:

```
rc=0   wall 5.31 s   max RSS 303,456 kB
tb_matvec_cb_contract: PASS -- 9 runs, 0 failures.  Codebook writes outside idle
and under reset are dropped; the table survives reset; the cb_we/start interlock
holds from both sides; an un-loaded codebook decodes to zero; a partial load is
consumed silently (documented, run 8).  CB_ROWS_PER_COPY=1 NB=24
```

**And it has teeth there.** Five mutants taken from the harness's own tree,
anchor-checked against the baseline, re-run at 1,536 replicas:

```
K3a  replica 1 skips a write whenever replica 0 takes one    KILLED  "copy 1 disagrees"
K3b  only replica 0 is ever written                          KILLED  "copy 1 disagrees"
K3c  the upper half writes one cycle late                    KILLED  "copy 768 disagrees"
K9a  one lane decodes one entry one step off                 KILLED  bench FAIL, emitted lane
K2b  a broadcast stage added BELOW the command register      KILLED  "copy 0 disagrees"
```

`K3c` naming **copy 768** is the load-bearing one: that is the shape a two-level
command broadcast tree over 1,536 copies produces, and it is precisely what the
unbuilt `CB_BCAST` mitigation would introduce.

### 4.5 The full mutation table, both styles

`SCRATCH=... bash sim/mutate_matvec_cb.sh` and the same with
`CBSTYLE=distributed`. No `ANCHOR FAILED` in either run, so the RTL edits did
not detach any mutation from the text it targets.

```
kill ratio: 16 KILLED + 0 ABORTED = 16 of 20;  4 SURVIVED     (both styles)
survivors:  K1b K3d K8a K8b                                    (both styles)
ATTRIBUTION CONTROL -- killed in A and NOT in S: K2b K2c       (both styles)
```

A column-by-column `diff` of the two 20-row tables is **empty**: identical in
all 20 rows and all 9 columns, and identical to the table LEVERC recorded. The
four survivors are unchanged and remain the measured resolution floor;
`K8a`/`K8b` still mean no functional bench can test the copy select, so
`P_CB_CHK`'s equality assertion is still not redundant with `P_CB_MODEL`.

### 4.6 Netlist neutrality of the RTL edits

The numbers in section 3.2 were drawn against `163eab02`, which is HEAD, not
against the file this track commits. The control is the same pair drawn again
from the edited tree in the same session.

MEASURED. The same two draws, from `vars_post`
(`matvec_core.vhd` md5 `54ad8bc4f0c083517ede344fca52996d`), in the same
session, with the same script and the same generics:

```
tag                    lut     logic     mem  distRAM  srl      ff  bram   dsp   muxf7  muxf8    cbRAM  cbFF     wns
v_regs_r48          121139    120013    1126      296  830   60268  21.5  1584   24583  12288        0  6144   0.242
vars_post_v_regs_r48 121139   120013    1126      296  830   60268  21.5  1584   24583  12288        0  6144   0.242

v_dist_r48           78506     65092   13414    12584  830   73463  21.5  1584       0      0    26112     0  -0.027
vars_post_v_dist_r48  78506     65092   13414    12584  830   73463  21.5  1584       0      0    26112     0  -0.027
```

**Identical in all sixteen columns, at both styles, WNS to the last digit.**
The RTL edits -- an unused `natural` constant and a process inside
`translate_off`, plus comments -- move nothing. The entity proven bit-exact on
silicon is untouched, and the numbers in section 3.2 attach to the file that is
committed.

**And again against the file that is actually committed.** The comment-only
edit that followed (`b616c7822f93154b08200f9418489012`) was drawn a third time
as `vars_final`:

```
vars_final_v_regs_r48  121139 120013 1126   296 830 60268 21.5 1584 24583 12288     0 6144   0.242
vars_final_v_dist_r48   78506  65092 13414 12584 830 73463 21.5 1584     0     0 26112    0  -0.027
```

Three draws of `v_regs_r48` and three of `v_dist_r48`, from three different
source md5s differing only in comments and in synthesis-invisible declarations,
**all six agreeing in every column**. That is also the determinism control: a
repeat of the same command reproduces itself exactly, so "identical" here is a
demonstrated no-op and not two numbers that happened to match.

### 4.7 The generic threads in SYNTHESIS, not only in simulation

**This is the load-bearing check on the implementation and it was nearly
missed.** Sections 4.2 and 4.3 prove the string reaches `matvec_core` under
GHDL. CBINFER only ever set `CB_STYLE` as the DEFAULT on the TOP entity, by
editing whole copies of the file. Lever C is usable from a board top only if
Vivado propagates a STRING generic across two hierarchy boundaries AND the
attribute functions in the child still evaluate against the propagated value --
a different mechanism from reading a default, and one that fails silently,
because a generic that does not arrive leaves `CB_STYLE` at `"regs"`, which is
legal and builds the shipping design.

MEASURED. `sim/ooc_leverc48_thread.tcl`, top = **`matvec_int4`**, `ROWS_IF=48
BLK=32 NPORTS_W=24 NPORTS_S=3 AXI_DW=256 ADDR_W=40`, period **5.0 ns** (the
200 MHz build target, NOT the 3.3 ns used above), `CB_STYLE` passed on the
`synth_design` command line:

| | `CB_STYLE=regs` | `CB_STYLE=distributed` | delta |
|---|---:|---:|---:|
| CLB LUT | 134,610 | 88,842 | **-45,768** |
| LUT as Logic | 129,520 | 71,464 | -58,056 |
| LUT as Distributed RAM | 4,292 | 16,580 | **+12,288** |
| CLB Registers | 58,298 | 72,015 | +13,717 |
| F7 Muxes | 24,576 | 7 | -24,569 |
| F8 Muxes | 12,288 | 0 | -12,288 |
| Block RAM Tile | 145.5 | 145.5 | 0 |
| DSPs | 1,584 | 1,584 | 0 |
| `cb_reg*` RAM cells | **0** | **26,112** | |
| `cb_reg*` FF cells | **6,144** | **0** | |
| WNS @ 5.0 ns | +1.215 | +1.186 | -0.029 |

`cb_reg*` goes from 6,144 flip-flops and no RAM to 26,112 RAM cells and no
flip-flops -- `1,536 x 17`, the identical figure the `matvec_core`-only draw
gives. **The generic arrives, and the attribute functions evaluate against it,
through two levels of hierarchy from a command-line string.** Lever C is
reachable from a build.

Three things this adds beyond section 3.2:

* **The saving at the entity a board top actually instantiates is LARGER:
  45,768 LUT, against 42,633 for `matvec_core` alone.** The wrapper's own logic
  re-optimises around the change too. Neither figure is a CLB number.
* **At the real build period the timing cost nearly vanishes.** -0.029 ns at
  5.0 ns, against -0.269 ns at 3.3 ns, with both styles holding over 1.18 ns of
  margin (264.2 MHz against 262.2 MHz). The 3.3 ns figure is the more sensitive
  probe and the 5.0 ns figure is the one the build cares about. **Neither is a
  placed number.**
* **One number does NOT close: the FF delta is +13,717 here against the
  codebook's own +13,195 closed form**, 517 flip-flops unexplained. It is
  recorded as unexplained rather than absorbed into the model.

---

## 5. The model verdict

### 5.1 The two models, re-derived exactly as CBINFER published them

```
linear in lanes, through (128, 3726) and (512, 13338):
  slope 25.0312 LUT/lane, intercept 522.00   ->  1,536 lanes: 38,970
linear in log2(lanes), through the per-lane figures 29.109 and 26.051:
  per-lane slope -1.5293                     ->  1,536 lanes: 36,291
```

Both reproduce CBINFER's published values, so what is tested below is its
models and not a re-fit of my own.

### 5.2 Against the measurement

```
MEASURED at 1,536 lanes:            42,633 LUT

  linear-in-lanes    38,970   error  -3,663    -8.59%
  log2               36,291   error  -6,342   -14.88%
  their average      37,630   error  -5,003   -11.73%
```

**The data supports the linear-in-lanes model**, by 2,679 LUT, and it is still
8.6% low. The published range 36,000-39,000 does not contain 42,633. Averaging
is worse than either endpoint of the comparison and was explicitly not done.

### 5.3 Why both failed: the per-lane curve is not monotone

MEASURED, six geometries, `v_regs` against `v_dist` in each case. The 128/256/512
rows are CBINFER's, on the same file; 768, 1,024 and 1,536 are this track's, all
from the frozen `vars_pre` tree:

```
ROWS_IF  lanes    regs      dist     saved   per-lane   BRAM36
   4       128   11,553    7,827     3,726    29.109      18.5
   8       256   21,531   14,438     7,093    27.707      28.5
  16       512   40,367   27,029    13,338    26.051      28.5
  24       768   60,487   41,016    19,471    25.353      21.5
  32     1,024   81,298   52,226    29,072    28.391      28.5
  48     1,536  121,139   78,506    42,633    27.756      21.5
```

Both models encode "the per-lane saving decreases", one linearly in lanes and
one linearly in `log2(lanes)`. **It decreases to 768 lanes, then increases.**
That is not a coefficient error; it falsifies the shape of both.

### 5.3a A constant beats both, and the mean is the estimator

```
model                                       at 1,536    error       %
linear in lanes                               38,970    -3,663    -8.59
linear in log2(lanes)                         36,291    -6,342   -14.88
constant per-lane, calibrated at 512 alone    40,014    -2,619    -6.14
constant per-lane, mean of the SAME 3 points  42,428      -205    -0.48
MEASURED                                      42,633
```

The per-lane figure spans 25.353 .. 29.109 over a 12x range of lane counts:
**+-6.9% about a mean of 27.394, with no direction.** A two-parameter fit to two
points cannot distinguish scatter from slope, so it necessarily reads the
scatter as a slope and then extrapolates it -- which is how both models produced
an error several times larger than the scatter they were fitted to. The mean of
the same three points, with no slope at all, lands within 0.48%.

Part of that 0.48% is luck and it is not offered as a fifth model. The claim
that IS supported: nothing in the data justifies a trend term, and the two
models that assumed one were both worse than not assuming one.

### 5.3b What is NOT determined about the curve

Why the per-lane figure moves at all is **open**. The one visible correlate is
that `BRAM36` is not constant across the sweep (18.5, 28.5, 28.5, 21.5, 28.5,
21.5), which tracks `TILES = ceil(MAXROWS_BFP / ROWS_IF)` landing on different
`ybuf` packings -- but `ybuf` is IDENTICAL between the two styles at every
geometry, so it cancels out of the delta and cannot be the direct cause. The
plausible remaining mechanism is second-order: the tool re-optimises the logic
AROUND the codebook differently depending on how the rest of the design packed.
**That is a hypothesis with no measurement behind it and it is recorded as
one.**

The reusable form of this is CBINFER's own trap #6 one level up. It ran a third
point specifically to test a two-point model and the third point falsified it by
2.3%; it then fitted two new models to three points and labelled them ESTIMATE.
**Labelling a number ESTIMATE discharges honesty, not verification.** The fourth
point falsifies both by 8.6% and 14.9%. What survived every extrapolation is
exactly what CBINFER said would: the per-lane STRUCTURAL constants, which are
counts of primitives per lane and not fits.

---

## 6. What this does and does not say about the fit

**Does not:** measure CLB. This is `synth_design -mode out_of_context` on
`matvec_core` alone. Lever C's claim is that removing the F7/F8 shapes changes
how densely the design PACKS, and packing is a property of a placed design.
Nothing in this document is a fit verdict.

**Does:** correct one input to LEVERC's bound, and it moves the bound UP.

```
                              LEVERC       here
codebook LUT footprint        49,152       54,921   (MEASURED, +11.7%)
                              (= 12,288 MUXF8 x 4 LUT6)
```

DERIVED: the extra 5,769 LUT is 3.76 per lane of codebook read-path logic that
sits OUTSIDE the F7/F8 shapes and also disappears. Rescaling LEVERC section
3.3's bound by that ratio, with its packing bounds unchanged:

```
codebook CLBs today   54,921 / [8.000 .. 4.689]  =  6,865 .. 11,713
LUTRAM replacement    12,288 LUTRAM / 8 per CLB  =  1,536  (EXACT: a RAM32M16
                      is 8 LUTs and CLB-atomic, CBINFER section 2.9)
CLB saving                                       =  5,329 .. 10,177
composed overshoot to be closed                  =  11,534
```

**ESTIMATE**, and the assumption is stated: that the 5,769 non-mux LUT pack at
the same density as the mux region, which is the weakest link and is not
obviously right -- ordinary logic has no reason to pack like an F8 shape. What
would falsify it is a `place_design` on the composed design with `CB_STYLE` at
each value, repeated per TRACK SCATTER. **Under either end of the bound the
overshoot is not closed, so lever C is still one of two levers.**

---

## 7. Measured and REJECTED -- do not retry

**1. Reading the answer out of the synthesis log, at ROWS_IF=48 as well.** 101
`[Synth 8-7186]` lines say the inference did not happen; 1,536 `RAM32M16` rows
in the same log say it did. Reproduced here at 12x the lane count CBINFER
measured it at. Do not grep for it and do not treat its absence as reassurance.

**2. Averaging the two LUT models.** MEASURED: the mean is 11.73% low, worse
than the better model's 8.59%. Two wrong models do not bracket the answer here;
they are wrong in the same direction.

**3. Extrapolating the per-lane LUT saving at all.** Every functional form
fitted to 128/256/512 predicts a per-lane figure BELOW 26.05 at 1,536, and the
measurement is 27.76. Do not fit a fourth model to four points either -- the
structural constants are the ones that extrapolate, and they need no model.

**4. `if CB_STYLE /= "regs"` as the announcement condition.** MEASURED wrong by
its own attribution control: it prints `LEVER C ACTIVE` over a register-bank
design whenever the string is a typo. Key on `CB_LANES_PER_COPY = 1`.

**5. `assert ... severity failure` for the `CB_STYLE` legality check.** Not
retried, and named so it is not: Vivado silently ignores a failing
severity-failure assert in synthesis (on record at `rtl/llama_top.vhd:165`), and
`matvec_core` IS synthesised by `sim/ooc_*.tcl`. The out-of-range `natural` is a
hard error in both tools.

**6. `sim/cbinfer_run.sh` for a second sweep while `rtl/` is being edited.** It
rebuilds its variant directory from the live tree on every invocation. Used
as-is for a second sweep it would have replaced the frozen sources the first
sweep's numbers were drawn against, and the two sets of numbers would have
looked comparable while referring to different files. `sim/leverc48_run.sh`
takes an explicit read-only tree for that reason. This is not a defect in
`cbinfer_run.sh`; it is the wrong tool for a track that edits RTL.

**7. Proving the threading in simulation alone.** GHDL propagating a string
generic and Vivado propagating one are different mechanisms, and the failure
mode is silent in both directions. `sim/ooc_leverc48_thread.tcl` exists because
a simulation-only proof of section 4.2 would have left the implementation's
central claim untested. Do not treat the GHDL announcement as evidence about
synthesis.

**8. Adding `CB_STYLE` to `rtl/matvec_int4_ip.vhd`.** Not done. That is the
packaged IP the AXU3EG block design reads from its DEFAULTS, lever C is an FK33
change, and repackaging an IP for a generic nothing there will set is cost with
no benefit.

---

## 8. Measurement traps hit, including my own

**1. My own announcement was a guard that passed for the wrong reason, and the
attribution control is what caught it.** Keyed on the string, it fired over a
design that was the register bank. Had I run only the M1 mutation -- which it
kills -- I would have shipped it. The control that killed it (M2S: the OTHER
guard deleted, the typo passed in) was run because the brief demands a control
per kill, not because I suspected anything.

**2. `sim/cbinfer_run.sh` would have silently rewritten my frozen sources.** Its
first line rebuilds the variant tree. I noticed only when planning the second
batch, after the first batch's numbers already existed. The fix was to copy the
tree aside and md5 it against `git show HEAD:` -- the copy was made at 19:47, 12
minutes after the numbers it protects.

**3. GHDL obsoletes dependent units, and the first mutation run reported the
mutant and the RESTORE as identical failures.** Re-analysing one file into a
kept library leaves `architecture "rtl" of "matvec_int4_desc_axi" is obsoleted
by entity "matvec_int4"` and the run dies before elaboration. Both the mutant
and the control came back `rc=1, 0 lines`, which reads exactly like "the check
does not discriminate". The fix is to re-analyse the whole dependent chain
(`matvec_core -> matvec_int4 -> matvec_int4_desc_axi -> the bench`) after every
substitution. **A mutation harness that fails to build reports the same verdict
as a mutation that survives, unless something distinguishes them.**

**4. I read the elapsed time of a Vivado run off the wrong clock and concluded
it had been running 25 minutes when it had been running 5.** No consequence,
because the next thing checked was `/proc` RSS and load rather than the guess.
Named because the instinct it produced was to kill the run.

**5. `sim/ooc_matvec_int4.tcl`'s source list is STALE and I copied it.** It omits
`async_fifo.vhd` and `axi_rd_fsm.vhd`, and the first wrapper-threading run died
at elaboration with `[Synth 8-5826] no such design unit 'axi_rd_fsm' in library
'work'`. **The sentinel gate is what caught it** -- the runner reported
`FAIL regs` / `FAIL distributed` because `LEVERC48_THREAD_DONE` was absent,
rather than a silently missing CSV row being read later as "the check was not
needed". The list is now derived from the actual `entity work.*` references
rather than copied. A file list copied from a script that still passes at ITS
geometry is not evidence that it is complete at yours.

**6. `ps ... args=` was not used for the Vivado lane check.** `/proc/PID/exe`
throughout, per `CLAUDE.md`. The summed `VmRSS` is still an UPPER BOUND -- Vivado
forks synthesis workers that share pages with the parent and summing double
counts them -- so the ~10 GB observed should be read as "comfortably inside the
13 GiB cap", not as a footprint.

**7. The capped `memory.peak` was deliberately not quoted as a size.** The runs
were held under `systemd-run --user --scope -p MemoryHigh=13G`. None reached the
cap, but no footprint is claimed from a capped run either way; what is claimed is
that `MemAvailable` never fell below 17.5 GiB with the GHDL work running beside
it.

---

## 9. Open, not yet answered

1. **The CLB saving.** Section 6. Only `place_design` on the composed A+B+C+D
   with `CB_STYLE` at each value, repeated, collapses `5,329 .. 10,177` to a
   number. This is the measurement lever C's entire justification rests on and
   it has never been made.
2. **Whether the 5,769 non-mux LUT pack like the mux region.** Assumed in
   section 6's rescale, and it is the weakest link in it.
3. **The WNS regression at 1,536 lanes.** -0.269 ns, OOC and unplaced, at a
   period 1.7 ns tighter than the build target. Whether it survives placement,
   and whether `CB_BCAST` removes it, are both unmeasured. **`CB_BCAST` is still
   not built**, and its cost is now bounded from below: the +13,195 FF measured
   here is the budget any broadcast rank is added on top of.
4. **SLICEM locality.** 12,288 `RAM32M16` at 8 LUT each want SLICEM sites inside
   subsystem A's existing row clusters; only ~47% of CLB columns are SLICEM.
   Untouched, and no synthesis result speaks to it.
5. **The 12,288-D-input command fanout**, named in the RTL, still not measured
   directly. Section 3.2's WNS is evidence about it but is not a measurement of
   it.
5a. **517 unexplained flip-flops.** At `matvec_int4` the FF delta is +13,717
   against the codebook's own closed form of +13,195, which is exact to within
   5 at three geometries when `matvec_core` is synthesised alone. Something
   outside the codebook gains flops under lever C at the wrapper level and it is
   not accounted for.
5b. **Why the per-lane LUT saving moves at all**, section 5.3b. It has a minimum
   at 768 lanes and no mechanism. `ybuf` is identical between the styles at
   every geometry so it cancels from the delta and is ruled out as a direct
   cause.
6. **The full 99-row gate was not run at this commit.** 12 `matvec` rows were,
   plus 3 `fk33_desc` rows, plus 20 mutation rows x 9 columns x 2 styles, plus
   the contract bench at two geometries. The remainder was left to the
   dispatcher, who is closing `BASELINE_PASS` separately. **No gate row was
   added by this track** -- `--list` reports 116 RUN rows before and after.
7. **Whether lever C should be TAKEN.** Not a question this track answers. The
   generic now makes it a one-line decision at a board top, defaulting to the
   design that is on silicon; nothing selects `"distributed"` anywhere in the
   tree.
8. **The composed design.** All of this is `matvec_core` in isolation. LEVERC's
   correction 1 stands: the codebook is 37.7% of the composed MUXF7, not 97.7%.

---

## 10. Reproducing this

```
# freeze a tree ONCE, and record the md5s
bash sim/cbinfer_variants.sh /mnt/storage/leverc48-scratch/vars_pre

# ONE Vivado on this box, capped
systemd-run --user --scope -p MemoryHigh=13G \
  bash sim/leverc48_run.sh /mnt/storage/leverc48-scratch/vars_pre \
                           /mnt/storage/leverc48-scratch/out 48 v_regs v_dist

# the threaded path, with the value oracle, through the wrappers
REGRESS_SCRATCH=<dir> bash sim/regress.sh --only tb_matvec_fk33_desc --keep
cd <dir>/sim_tb_matvec_fk33_desc/run && ghdl -r --std=08 -frelaxed \
  --workdir=../work tb_matvec_fk33_desc -gCB_STYLE=distributed \
  --stop-time=200ms --stop-delta=1000000

# the coherency contract at the real replica count
ghdl -r --std=08 -frelaxed --workdir=. tb_matvec_cb_contract \
  -gBLK=32 -gROWS_IF=48 -gCB_STYLE=distributed --stop-time=50ms

# does the generic thread in SYNTHESIS, through two wrappers
vivado -mode batch -source sim/ooc_leverc48_thread.tcl \
       -tclargs mv4_distributed style=distributed outdir=<dir>

# the mutation table, both styles
SCRATCH=<dir> bash sim/mutate_matvec_cb.sh
SCRATCH=<dir> CBSTYLE=distributed bash sim/mutate_matvec_cb.sh
```

Artefacts: `hw/fk33/results/leverc48_2026-08-30/`.
