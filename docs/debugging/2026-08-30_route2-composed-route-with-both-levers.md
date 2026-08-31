# Does the composed A+B+C+D design ROUTE on this part with both area levers enabled?

**TRACK ROUTE2, 2026-08-30.** Part `xcvu33p-fsvh2104-2L-e`, SQRL FK33.
Vivado 2023.2 on the workstation. Tree pinned at `3b2003c`, work committed at
`bff9265`. Scratch `/mnt/storage/route2_2026-08-30`.

**IN PROGRESS -- this file is written as the run proceeds, not after it.**

## The question, verbatim

> **Does the composed A+B+C+D design ROUTE on this part with both area levers
> enabled?** Everything downstream -- the card top, the seam, inference itself
> -- is unfalsifiable until this is answered.

## The answer

**YES. It routes, inside the card's real `pb_core`, with 0 nets with routing
errors and 0 DRC errors. It does NOT close 200 MHz: post-route WNS is
-0.575 ns on `core_clk`, which is Fmax 179.4 MHz.**

**But see the CORRECTION in Result 8: the same-session `CB_STYLE = "regs"`
control ROUTES TOO. Routability was already bought by the norm lever alone.
What lever C buys is FIT -- the control overflows `pb_core` at 100.74% CLB --
and 0.593 ns of WNS, which is the difference between `hbm_aclk` meeting and
missing.** Hold is met with margin to
spare (WHS +0.010, 0 failing endpoints) and `hbm_aclk` meets 250 MHz at +0.080.

Vivado's own count, `out/route_status_c4lev.rpt`:

```
   # of logical nets.......................... :     2434587
       # of nets not needing routing.......... :     1918031
       # of routable nets..................... :      516556
           # of fully routed nets............. :      516556
       # of nets with routing errors.......... :           0
```

The router converged rather than thrashed. Its overlap count, which is the
number that RAN AWAY in the failing attempt (69,858 -> 183,525 -> 111,513):

```
96 -> 63 -> 26 -> 12 -> 11 -> 2 -> 2 -> 1 -> 2 -> 3 -> 1 -> 0
```

`C4_ROUTE_SECONDS 1597` (26 min 37 s) against the previous attempt's 56 m 35 s
for a single unfinished iteration.

**The binding resource has changed identity: it is now DSP at 80.63% of
`pb_core`, and every congested window in both the placed and the routed
congestion reports is DSP-saturated at 62-100% while LUT sits at 45-70%.**
Neither area lever touches a DSP, and nothing in the backlog does.

**The remaining timing gap is 0.575 ns and it is NOT the same problem as
before.** Failing endpoints went 33,767 (pre-lever, after placement) to 268
after placement here, 82 after `phys_opt_design`, and 9,056 of 971,406 after
routing. That last number is 0.93% of endpoints and TNS is -876.045 ns.

## RETRACTION, 2026-08-30, and it is the first thing anyone should read

**`166cbd4`'s commit body says "The router CONVERGED where the pre-lever
attempt thrashed" and that sentence has been reported upward as "the levers are
what made it route". THAT CLAIM IS WITHDRAWN. It is not supported by my data.**

What is withdrawn, and what is not:

| claim in `166cbd4` | status |
|---|---|
| the composed A+B+C+D design routes in `pb_core`, 0 nets with routing errors, 0 DRC errors | **STANDS.** MEASURED |
| `STEP 2`'s "done when" is met | **STANDS** |
| the binding resource is now DSP at 80.63% of `pb_core` | **STANDS.** MEASURED |
| BRAM is 253.5, +119.0 headroom without the gain image, -52.0 with it | **STANDS.** MEASURED |
| post-route WNS -0.575 on `core_clk`, Fmax 179.4 MHz | **STANDS.** MEASURED |
| **"the router converged where the pre-lever attempt thrashed"** | **WITHDRAWN** |
| **credit to TRACK TIMING for "the 33,511 endpoints ... root cause is area"** | **WITHDRAWN as unsupported by this track's data** |

### 1. What exactly routed in the control -- the configuration, named

Three tops were synthesised and implemented, all from ONE `git archive` of
`3b2003c` and all through the identical `sim/ooc_compose4_pnr.tcl`:

| top | `a_eng` `CB_STYLE` | `d_norm` entity | binds | levers in |
|---|---|---|---|---|
| `compose4_top` | `"distributed"` | `ooc_normadapt` | `rmsnorm_rs_mem` | **both** |
| `compose4_ctl_top` | **`"regs"`** | `ooc_normadapt` | `rmsnorm_rs_mem` | **norm lever ONLY** |
| `compose4_null_top` | **`"regs"`** | **`ooc_normadapt_flat`** | **`rmsnorm_rs`** | **neither** |

**The control that routed is `compose4_ctl_top`: `CB_STYLE = "regs"`, and the
NEW `d_norm`. Only lever C was reverted. The norm lever was still in.** That
is the answer to "which lever was in", and it is why the result is narrower
than a full retraction: nobody has yet drawn the no-levers configuration under
this constraint. `compose4_null_top` exists to close exactly that hole and its
result is below.

### 2. The numbers, side by side

All three from the same session, same tree, same `pb_core`
(`CLOCKREGION_X0Y0:CLOCKREGION_X6Y3`), same script:

| | **levered** (both) | **control** (norm only) | delta |
|---|---:|---:|---|
| routed CLB | **46,733** | **48,963** | control +2,230 |
| CLB in `pb_core` at placement | 46,713 / 48,600 = **96.12%** | 48,960 / 48,600 = **100.74%** | **control OVERFLOWS the region** |
| routed CLB LUT | 261,539 | 306,007 | control +44,468 |
| LUT in `pb_core` | 67.27% | 78.70% | |
| **DSP** | **2,177 (80.63%)** | **2,177 (80.63%)** | **identical, neither lever touches DSP** |
| **BRAM** | **253.5 (44.01%)** | **253.5 (44.01%)** | **identical** |
| placed WNS | **-0.216** | **-0.672** | |
| placed failing endpoints | **268** | **1,932** | **7.2x** |
| after `phys_opt_design` | **-0.061**, **82** | **-0.546**, **1,707** | **20.8x** |
| `[Route 35-447]` | **absent** | **FIRES** | |
| router overlaps, first value | **96** | **501,118** | **5 orders of magnitude** |
| overlap curve | `96 -> 63 -> 26 -> 12 -> 11 -> 2 -> 2 -> 1 -> 2 -> 3 -> 1 -> 0` | `501,118 -> 162,120 -> 58,308 -> 21,191 -> 7,971 -> ... -> 0` (4 global iterations) | |
| `route_design` seconds | **1,597** | **1,920** | |
| routing errors | **0** | **0** | **BOTH ROUTE** |
| post-route `core_clk` WNS | **-0.575** (179.4 MHz) | **-1.168** (162.1 MHz) | **+0.593 ns** |
| post-route `hbm_aclk` WNS | **+0.080 MEETS** | **-0.064 FAILS** | lever C closes the HBM domain |
| TNS | **-876.045** | **-19,758.709** | **22.6x** |
| post-route failing endpoints | **9,056 / 971,406 = 0.93%** | **57,342 / 830,211 = 6.91%** | **7.4x by fraction** |
| WHS | +0.010 | +0.009 | both meet |

**Both route. So what lever C bought, precisely: FIT (the control overflows
`pb_core` by 360 CLB), 0.593 ns of WNS, the `hbm_aclk` domain going from
failing to meeting, 22.6x on TNS, and 323 seconds of router time.** It bought
nothing on DSP and nothing on BRAM, which are identical to the last tile.

For comparison, the original overlap curve, from the WORKLOG:

```
iteration 0  494,506 -> 150,615 -> 65,271 -> 35,976 -> 23,310 -> 16,757  (56m35s)
iteration 1   69,858 -> 183,525 -> 111,513   (RISING -- the router is thrashing)
```

**The control's iteration-0 curve looks like the original's** -- both start
around half a million overlaps and fall by two orders of magnitude. The
difference is what happens next: the control kept descending through four
global iterations to 0, and the original rose on iteration 1 and was killed.

### 3. So what killed the original attempt, if not the levers?

**TWO variables changed between the original run and my control, not one, and
the second one has never been named in any document on this track:**

1. **Area.** The original was `compose4_top` with NEITHER lever, at 350,283 LUT.
   My control has the norm lever in, at 310,180 LUT. That is **-40,103 LUT**
   already removed before lever C is even considered.
2. **THE CONSTRAINT, and this is the one nobody noticed.** The original's
   killed route is `c4dev_physopt.dcp`. **`c4dev` is the DEVICE run --
   `C4_PBLOCK=0`, the whole die, UNCONSTRAINED.** That is confirmed by its own
   headline number: 54,866 of **54,960** CLB, and 54,960 is the DEVICE CLB
   count. `pb_core` holds 48,600. A pblocked run cannot report 54,866.

   `sim/ooc_compose4_run.sh` defines both `impl_pb` (`C4_PBLOCK=1`, line 113)
   and `impl_dev` (`C4_PBLOCK=0`, line 117), and the 2026-08-29 write-up plans
   them as steps 6 and 7 with the explicit purpose *"Isolates: whether a
   failure in step 6 is a REGION failure or a DEVICE failure."*

   **`hw/fk33/results/compose4_2026-08-29/` contains NO implementation
   artefacts at all** -- only `util_c4_synth.rpt`, `timing_c4_synth.rpt`,
   `elab.stdout.tail` and the BUFG probe. There is no `route_status`, no
   `pbutil`, no placed or routed utilization. **So no pblocked compose4 route
   attempt has ever been recorded, and every "the composed design does not
   route" statement in this project traces to a single UNCONSTRAINED die-wide
   run that was killed rather than allowed to finish.**

**That means "the levers made it route" and "the pblock made it route" were
never separated, and my `166cbd4` asserted the first without excluding the
second.** The experiment that separates them is `compose4_null_top` --
neither lever, same `pb_core`, same session -- and it is running.

## What had to be built before the question could even be asked

**Neither lever was reachable from `compose4_top`, and they were unreachable
for two different reasons.**

### Lever C was unreachable from every top that builds

`matvec_core.vhd` has carried the implementation since `845ea28` and
LEVERC48 (`a4828ab`) forwarded `CB_STYLE` through `matvec_int4_desc_axi`,
`matvec_int4` and `matvec_int4_axi`. **But `hw/fk33/rtl/fk33_engine.vhd` is
the entity that BINDS `matvec_int4_desc_axi` for the card and for
`compose4_top`, and it had no generic clause at all.** So after LEVERC48 the
lever was selectable from an out-of-context synthesis of `matvec_core` and
from **no top the card or the composition actually builds**.

`synth_design -generic` does not rescue this: it reaches the top's generics
only, never a deep instance.

Fixed in `hw/fk33/gen_fk33_engine.py` (the file is GENERATED). MEASURED first
that the generator reproduces HEAD byte-identically
(`md5 bf6aee7939e59415eaf34510060c8418`), so the diff after the edit is
attributable. The regenerated file differs from HEAD by **exactly** the
generic clause and one `CB_STYLE => CB_STYLE` line, and the default is
`"regs"`, so the shipping bitstream is unchanged.

### The norm lever is not a generic and arrives only by re-extraction

`compose4_top`'s `d_norm` is `ooc_normadapt`, which is GENERATED by
`sim/ooc_normadapt_extract.py` from `rtl/llama_top.vhd`'s `gvr` generate
block. HEAD's `gvr` binds `rmsnorm_rs_mem` unconditionally
(`rtl/llama_top.vhd:2190`), so **the lever arrives by re-extracting against
HEAD and by nothing else**, and `rtl/ooc_normadapt_top.vhd` is not in the repo
at all -- it is generated into the build tree each time.

**A stale extraction is completely silent.** It parses, elaborates,
synthesises and reports an area the design does not have. So the generator now
ABORTS on an extraction that does not bind `rmsnorm_rs_mem`.

**TEETH-CHECKED, and this is the attribution control for the guard itself:**
extracted from `012d28d~1`'s `llama_top` (the last tree before RMSWIRE landed)
the guard FIRES; extracted from HEAD it passes.

```
COMPOSE4 ABORT: .../rtl/ooc_normadapt_top.vhd does not instantiate rmsnorm_rs_mem.
  This is a STALE extraction: rtl/llama_top.vhd's `gvr`
  block has bound rmsnorm_rs_mem since TRACK RMSWIRE (`47c9d9c`).
```

It is keyed on the **instantiation**, not on a substring of the file: HEAD's
extraction mentions `rmsnorm_rs_mem` in a comment at line 312 and binds it at
line 485, so a whole-file substring test would have passed over an extraction
that binds the flat unit. That is the "guard that passes for the wrong reason"
class, avoided deliberately.

## CORRECTION to the dispatcher's brief

> "TRACK RMSWIRE reports that this extractor now **ABORTS against HEAD**
> (`--shift` finds no `xw`) ... So you must either fix the extractor for the
> new `llama_top`, or instantiate the real thing."

**Withdrawn. Only `--shift` aborts, which is what RMSWIRE actually reported.**
The plain extraction path runs cleanly against HEAD and needs no fix:

```
EXTRACT OK rtl/llama_top.vhd lines 1818..2767 (950 lines) -> .../ooc_normadapt_top.vhd
```

`--shift` is a probe deliberately not in `rtl/`; its loss costs NORMADAPT's
`na_shift` number and nothing this track needs. **No extractor fix was made
and none was required.** What was required was the staleness guard, which is a
different problem that the brief did not name: the extractor working is not
the same as the extraction being current.

## The procedure, in the order it was run

Each step names what it isolates.

| # | step | what it controls for |
|---|---|---|
| 1 | `python3 hw/fk33/gen_fk33_engine.py` against an UNMODIFIED generator, `md5` the output against HEAD | that the generator is LIVE, not stale. A stale generator would make every later diff unattributable. RMSWIRE found three mutation harnesses reading a hand-maintained closure that had gone stale silently; this is the same class, checked before relying on it |
| 2 | edit the generator, regenerate, `git diff` the generated file | that the change is EXACTLY the additive generic. 22 inserted lines, 0 deleted |
| 3 | `tools/check_a_geometry.py` | that subsystem A's four-site geometry agreement survived an edit to its wrapper generator. `sim/tb_a_geom.vhd:75` cites `gen_fk33_engine.py:85,91` by LINE NUMBER, and an insertion above those lines would have silently invalidated the citation. The edits are at 252 and 519, so the citation still holds |
| 4 | extract `ooc_normadapt` from `012d28d~1`'s `llama_top`, run the generator | the staleness guard FIRES. Without this the guard is decoration |
| 5 | extract from HEAD, run the generator | the guard PASSES on the real input, and `entity work.rmsnorm_rs_mem` appears exactly once |
| 6 | generate BOTH tops, `--cb-style distributed` and `--cb-style regs`, and diff them with the entity name normalised | the two configurations differ by the CB_STYLE literal and NOTHING else, so any later difference is attributable to the lever |
| 7 | `C4_STAGE=elab` | every binding, width and visibility error, in minutes rather than after an hour of synthesis |
| 8 | `C4_STAGE=synth` | composed area with both levers, at the real shape |
| 9 | `C4_STAGE=census` on the synth checkpoint | the lever-C verdict from `get_cells`, NOT from the log |
| 10 | `C4_STAGE=impl C4_PBLOCK=1` | placement, congestion, and the routing verdict inside the card's real `pb_core` region |

Step 6's output, which is the whole attribution basis:

```
< --   a_eng    fk33_engine      854 ports, 851 exported   CB_STYLE="distributed"
> --   a_eng    fk33_engine      854 ports, 851 exported   CB_STYLE="regs"
<       CB_STYLE => "distributed"
>       CB_STYLE => "regs"
```

Step 7 confirmed the generic reaches the leaf. This is a PARAMETER BINDING from
the elaborator, not an inference claim:

```
Parameter CB_STYLE bound to: distributed - type: string      (x8 sites)
C4_READ 98 files
C4_ELAB_CELLS 429778
C4_ELAB_PORTS 36529
C4_DONE elab c4lev
```
## Measured and REJECTED -- do not retry

**1. `synth_design -generic CB_STYLE=distributed` to reach the codebook.**
`-generic` binds the TOP's generics only. `compose4_top` has one generic
(`CLK_BUFG`) and `matvec_core` is four levels down. There is no Vivado
mechanism to set a generic on a deep instance from the command line; the
generic has to be declared and forwarded by every entity on the path, and
`fk33_engine` was the one that did not. Do not look for a synthesis-option
shortcut, there isn't one.

**2. Fixing `sim/ooc_normadapt_extract.py` for the new `llama_top`.** The
dispatcher's brief said the extractor aborts against HEAD. It does not; only
`--shift` does. Running the plain path costs one second and settles it. **Do
not spend time repairing an extractor that works.** The real problem is
adjacent and was not named: an extraction that is stale rather than an
extractor that is broken.

**3. A whole-file substring test as the staleness guard.** Rejected before it
was written. HEAD's extraction contains the string `rmsnorm_rs_mem` in a
comment 173 lines before it binds the entity, so `if "rmsnorm_rs_mem" in text`
passes on an extraction that binds the flat unit. The guard is keyed on
`entity\s+work\.rmsnorm_rs_mem\b`.

**4. A bare `route_design` in the batch script.** `[Route 35-447]` is an
ERROR, and in a bare script it aborts before any report is written. The
previous composed attempt left nothing but a log. Wrapped in `catch`.

## Measurement traps hit, including my own

**The generated file is not the generator.** Both `fk33_engine.vhd` and
`compose4_top.vhd` say "DO NOT HAND-EDIT". The first thing done here was to
prove `gen_fk33_engine.py` still reproduces its output byte-identically
(`md5 bf6aee79...`) BEFORE editing it. If it had not, the edit would have
carried along an unknown quantity of drift and nothing after it would have been
attributable. This costs one command and is not optional.

**A line-number citation in another file is a dependency.**
`sim/tb_a_geom.vhd:75` cites `gen_fk33_engine.py:85,91`. Inserting 22 lines
into that generator would have silently invalidated the citation had the
insertion been above line 85. It was at 252 and 519. `tools/check_a_geometry.py`
was run afterwards and reports every site agreeing.

**MY OWN: I nearly reported a guard as working because it aborted.** The first
run of the staleness guard printed
`COMPOSE4 ABORT: missing .../tree/hw/rtl/gdn_block.vhd`, which is an abort but
NOT the guard's abort. It was the generator's default `--rtl` resolving to a
directory that does not exist. Had I read "it aborted" as "the guard fired" the
guard would have been shipped never having been exercised. The tell was reading
the abort's text rather than its exit code.

That accident found a real defect: **`gen_compose4_top.py`'s default `--rtl`
has never resolved**, in this tree or any other. `REPO` was
`os.path.dirname(HERE)` with `HERE = <repo>/hw/fk33`, giving `<repo>/hw/rtl`.
Fixed in `7477f23`, and neutrality-checked: with no arguments the generator now
reproduces the committed `compose4_top.vhd` byte-identically.

**`[Synth 8-7186]` reproduced, again.** 100 lines of
`Applying attribute ram_style = "distributed" is ignored, object 'cb[6][2]' is
not inferred as ram due to incorrect usage`. This is the third recorded
appearance. It is not evidence about anything; the census is.
## CORRECTION to my own pre-registration, made before the result was read

`/mnt/storage/route2_2026-08-30/PREREGISTERED.txt` predicts
`LUT as Memory 1,126 + 12,288 = 13,414`. **The 1,126 is `matvec_core`'s
STANDALONE figure from LEVERC48, and the composition's baseline is 15,580**
(`hw/fk33/results/compose4_2026-08-29/synth.c4lines.txt`, `lut_mem 15580`),
because the 28 HBM read ports' async FIFOs are LUTRAM too and no `matvec_core`
draw contains them. The corrected prediction is **15,580 + 12,288 = 27,868**.

This is the same mistake in miniature that the whole track exists to avoid: a
number measured on a unit quoted as if it were a number about the composition.
It is recorded rather than silently fixed because the original file is
timestamped before the measurement and the correction is not.
## Result 1 -- composed synthesis, both levers, MEASURED

`vivado 2023.2 synth_design -mode out_of_context`, `xcvu33p-fsvh2104-2L-e`,
core 5.000 ns / hbm 4.000 ns, `C4_SYNTH_SECONDS 456`, `C4_BUFG 2`,
`out/util_c4lev_synth.rpt`.

| | baseline, NO levers | **both levers** | delta | predicted | miss |
|---|---:|---:|---:|---:|---:|
| CLB LUT | 350,283 (79.67%) | **265,658 (60.42%)** | **-84,625** | 245,597 | **+8.2%** |
| LUT as Logic | 334,703 | 237,816 | -96,887 | -- | -- |
| LUT as Memory | 15,580 | **27,842** | +12,262 | 27,868 | **-0.09%** |
| CLB Registers | 355,468 | **237,832** | -117,636 | 179,148 | **+32.8%** |
| CARRY8 | 12,147 | 12,174 | +27 | -- | -- |
| F7 Muxes | 65,108 | **20,225** | -44,883 | 13,789 | **+46.7%** |
| F8 Muxes | 25,788 | **3,970** | -21,818 | 204 | **x19.5** |
| Block RAM Tile | 246.5 | **253.5** (37.72%) | +7 | 252.5 | **+0.4%** |
| URAM | 0 | 0 | 0 | 0 | ok |
| DSPs | 2,177 (75.59%) | **2,177 (75.59%)** | **0** | 2,177 | **exact** |

Baseline row is `hw/fk33/results/compose4_2026-08-29/util_c4_synth.rpt` at
`56cebe8`, the same top and the same generics with neither lever.

Synthesis also got cheaper: **456 s against the baseline's 677 s**, and Vivado's
own `Memory (MB): peak = 6340.238` against the baseline's summed-RSS 16.7 GB.
(Three different memory figures exist and are not interchangeable; the 6,340 MB
is Vivado's *reported allocation peak* for its optimisation phase, not a cgroup
`memory.peak` and not a summed `/proc` RSS.)

### PREDICTION 1 IS FALSIFIED, and the pattern in HOW it failed is the finding

Pre-registered at `/mnt/storage/route2_2026-08-30/PREREGISTERED.txt` before the
run, with "falsified by any of the above off by more than 5%".

**The predictions that held are exactly the ones with a STRUCTURAL closed
form**, and the ones that failed are exactly the ones taken as a difference of
two independently measured designs:

- `DSP 2,177` -- exact. Neither lever touches an arithmetic unit.
- `LUT as Memory 27,868` vs 27,842, **-0.09%**. Lever C's `+12,288` is
  `8.000/lane x 1,536 lanes` EXACT, an architectural identity, not a fit.
- `BRAM 252.5` vs 253.5, **+0.4%**, one tile out.
- `CLB LUT` **+8.2%**, `CLB FF` **+32.8%**, `F7` **+46.7%**, `F8` **x19.5**.

**The two levers do not add.** `-84,625` LUT against `-104,686` predicted: the
composition keeps **20,061 LUT** that the sum of the separate measurements says
it should not have. The register miss is larger still, and in the same
direction: 58,684 more flip-flops survive than the difference of the two draws
predicts.

The most likely mechanism, and it is an ESTIMATE: **RMSWIRE's -62,053 / -189,515
was measured on `llama_top`'s `gvr` region, and `compose4_top`'s `d_norm` is an
EXTRACTION of that region into a standalone entity with the surrounding scope
turned into ports.** A port cannot be optimised away, so structures that
`llama_top` folds into its neighbours survive here. **What would falsify it:**
a same-session `--cb-style regs` control synthesis, which isolates lever C's
own composed delta and leaves the norm lever's as the residue. That control has
not been run yet.

**Nothing in the falsification is bad news for the fit.** 60.42% LUT against
79.67% is the largest single area move this composition has seen, F8 is down
85%, and the levers have not made BRAM or DSP worse.
## Result 2 -- the lever-C census, and my discriminator was wrong

`C4_STAGE=census` on `c4lev_synth.dcp`. This is an object-level `get_cells`
census, run because `[Synth 8-7186]` printed its 100 lines in this very run
saying `cb[*]` was not inferred as RAM.

```
C4_CENSUS ref RAM32M     41       C4_CENSUS ref RAMB18E2    43
C4_CENSUS ref RAM32M16 3134       C4_CENSUS ref RAMB36E2   232
C4_CENSUS ref RAM32X1D   24       C4_CENSUS ref RAMD32   44170
C4_CENSUS ref RAM32X1S   32       C4_CENSUS ref RAMD64E   1354
C4_CENSUS ref RAM64M8   165       C4_CENSUS ref RAMS32    6382
C4_CENSUS ref RAM64X1D   17
C4_CENSUS ram_cells_total 55594
C4_CENSUS cb_reg_ff    3
C4_CENSUS cb_reg_ram   26112
C4_CENSUS rmsmem_cells 23222
C4_LEVERC AMBIGUOUS  cb_reg_ff=3 cb_reg_ram=26112
```

**LEVER C IS ACTIVE. The `AMBIGUOUS` verdict is my checker's fault, not the
design's**, and it is worth writing down because it is the shape of a bad
discriminator.

`cb_reg_ram = 26112` is **exactly** LEVERC48's measured figure for the
levered configuration (`cb_reg*` goes `6,144 FF / 0 RAM` to `0 FF / 26,112
RAM`). An exact match on a five-digit number is strong evidence. But I had
written the ACTIVE branch as `cb_reg_ff == 0 && cb_reg_ram > 0`, so three stray
flip-flops matched by the loose wildcard `NAME =~ *cb_reg*` -- against the
**6,144** the unlevered configuration carries -- were enough to collapse a
clean verdict to `AMBIGUOUS`.

**The right discriminator was the number that was already pinned, and I used a
weaker one.** Corrected in `sim/ooc_compose4_pnr.tcl`: the test is now equality
against 26,112, the `INACTIVE` branch requires `>= 6144` registers, and any
stray `cb_reg*` flip-flops are **printed by name** rather than left as an
unexplained residue. An unexplained residue is precisely what turns a
measurement into an ambiguity.

Two independent confirmations that the lever really is in:

- **LUT as Memory rose 15,580 to 27,842, `+12,262`**, against a DERIVED
  `+12,288` that is `8.000 LUTRAM/lane x 1,536 lanes` exactly. **-0.09%.**
- **F8 Muxes fell 25,788 to 3,970.** Lever C's structural claim is that the
  codebook's MUXF8 tree disappears entirely.

So this is the third recorded case of `[Synth 8-7186]` denying an inference
that the census shows happened. **The log is not evidence in either direction.**

`rmsmem_cells 23222` confirms the norm lever's unit is present in the
composition, which is the other half of the configuration under test.

### Still open from the census

**What the 3 stray `cb_reg*` flip-flops are.** They are not codebook
registers -- 3 against 6,144 settles that -- but they have not been named. The
corrected census prints the names, so the next run resolves it for free. Not
resolved here because doing so needs a second Vivado and the implementation had
the lane.
## Result 3 -- the fit inside the card's real `pb_core`, before placement

`C4_PBLOCK=1` reproduces `hw/fk33/fk33_pblock.xdc:92`'s region and the script
errors if the range comes back anything else:

```
C4_PBLOCK_RANGE CLOCKREGION_X0Y0:CLOCKREGION_X6Y3
```

`out/pbutil_c4lev_preplace.rpt`, the composition against the REGION's supply
rather than the device's:

| resource | used | available in `pb_core` | % |
|---|---:|---:|---:|
| CLB LUTs | 265,658 | 388,800 | **68.33** |
| CLB Registers | 237,832 | 777,600 | 30.59 |
| Block RAM Tile | 253.5 | 576 | 44.01 |
| **DSPs** | **2,177** | **2,700** | **80.63** |
| URAM | 0 | 320 | 0.00 |

**DSP is now the tightest resource in the region at 80.63%**, ahead of LUT at
68.33%. Neither lever moves DSP, and nothing in this project is holding a DSP
budget. That is a change of which resource binds and it is stated here because
it did not exist as a question before the levers landed.

**The BRAM sum, stated explicitly as the brief requires.** The 576 above is the
region's whole supply and does NOT subtract the shell cells physically inside
it. `hw/fk33/results/build_e2e_2026-08-29/e2e_pblock_util_routed.rpt` measures
those at **203.5**, so our logic has **372.5**:

| term | tiles |
|---|---:|
| composed A+B+C+D, both levers, `NORM_W_IMAGE = ""` | **253.5** MEASURED |
| available inside `pb_core` | 372.5 MEASURED |
| **headroom without the gain image** | **+119.0** |
| + the norm gain image (NORMURAM, MEASURED standalone) | 171 |
| **total with the image** | **424.5** |
| **shortfall with the image** | **-52.0** |

So the levers did NOT fix BRAM and were never going to: **the composition is
comfortable at 253.5 and the gain image alone is what does not fit.** The
dispatcher's DERIVED shortfall of 51 tiles is confirmed at 52 with a real
composed measurement rather than a sum. That is TRACK GWTWO's `GW` curve to
close, not this track's.
### A trap I set for myself and then walked into, caught before it cost anything

`chain2.sh`, which queues the attribution control behind the implementation,
gated on `log/drv_impl_c4lev.txt`. **That file is never written.** The driver's
own stdout goes wherever the caller redirects it, and the chain redirects it to
`chain.txt`; only the Vivado log is named after the stage. So the control would
have waited forever while the lane sat empty after the implementation finished,
and nothing would have reported an error -- **a gate on a file that is never
written looks exactly like a job that has not finished yet.**

This is the same shape as the completion-signal trap CLAUDE.md records, one
level down: I gated on a sentinel rather than on a waiter, which was right, but
never checked that the sentinel's FILE exists. Repointed at
`^CHAIN: impl rc=` in `chain.txt`, which is a line the chain itself writes and
which was verified present in the running file's format before relaunching.

**The general rule this suggests: after writing a gate, `ls` the thing it
watches.** It costs one command and the failure mode is silent.
## Result 4 -- IT PLACES, and the placed design is a different design

`place_design` inside `pb_core`, `C4_PLACE_SECONDS 906` (15 min).

```
C4_UTIL c4lev placed lut 261539 lut_logic 234222 lut_mem 27317 ff 240120
                     carry8 12174 f7 20225 f8 3970 bram 253.5 uram 0
                     dsp 2177 clb 46713
C4_PLACED placed clb_sites_used        46713
C4_PLACED placed wns                  -0.216
C4_PLACED placed failing_endpoints_max   268
```

**Against the composition that failed to route** (MEASURED by TRACK TIMING on
the same top with neither lever):

| | no levers | **both levers** | |
|---|---:|---:|---|
| placed CLB | 54,866 of 54,960 device = **99.83%** | 46,713 of 48,600 in `pb_core` = **96.12%** | |
| placed WNS | **-3.056** free die / **-3.658** squeezed | **-0.216** | **14.2x / 16.9x better** |
| failing endpoints after placement | **33,767** | **268** | **126x fewer** |
| congestion level | **7** | **6** (one window; the rest are 5) | |
| route | `[Route 35-447]`, killed | pending at the time of writing | |

**268 failing endpoints is the same order as the 256 TRACK TIMING closed by
hand in subsystem C**, on a design where the previous count was 33,767. TIMING's
diagnosis was that the 33,511 beyond its 256 were "net-delay, not logic ... root
cause is area, at 54,866 of 54,960 CLB". **This run is the confirmation of that
diagnosis: the levers removed the area and the net-delay failures went with
it.** That was a prediction TIMING made and could not test, and it is now
MEASURED.

### Where the congestion still is, and it is DSP, not LUT

`out/congestion_c4lev_placed.rpt`, all five reported windows:

```
Direction Type  Level Window                            LUT LUTRAM Flop MUXF RAMB  DSP CARRY  Cell Names
North     Long      5 (CLEM_X17Y75,CLEM_X33Y106)        68%     0%  20%  11%   0%  85%   40%  c_attn/u_arr(97%)
East      Long      5 (CLEL_R_X12Y186,CLEL_R_X28Y217)   66%     5%  33%   2%  83%  64%   16%  a_eng/eng/dut/core(51%),c_attn(23%),c_attn/u_norm(21%)
West      Long      5 (CLEM_X36Y127,CLEL_R_X51Y158)     45%    22%  31%   2%  16% 100%   31%  a_eng/eng/dut/core(63%),c_attn(20%),c_attn/u_quant(8%)
West      Long      6 (CLEL_R_X29Y121,LAG_LAG_X60Y184)  47%    21%  30%   4%  54% 100%   27%  a_eng/eng/dut/core(56%),c_attn(16%),c_attn/u_arr(11%)
East      Short     5 (CLEL_R_X10Y185,CLEL_R_X26Y216)   66%     5%  34%   2%  85%  62%   16%  a_eng/eng/dut/core(49%),c_attn(23%),c_attn/u_norm(23%)
```

**Every congested window is DSP-saturated: 85%, 100%, 100%, 64%, 62%**, against
LUT at 45-68%. This agrees with the pre-placement region fit, where DSP was
80.63% and LUT 68.33%. **The binding resource has changed identity.** Neither
lever touches a DSP and no third lever in the backlog does either.

The named cells are `a_eng/eng/dut/core` (subsystem A's matvec array) and
`c_attn/u_arr` (subsystem C's attention array), which are the two DSP consumers.

### The placed shape is odd and worth naming

**96.12% of the CLBs are occupied while only 67.27% of the LUTs are used**, a
density of 5.599 LUT/CLB. The placer spread into almost every CLB and filled
each about two-thirds. That is much looser than the 6.324 measured on the free
die without levers and the 7.029 the pblock squeeze forced. **Density is
elastic and this is a third point on that curve**, at a pressure where the
placer had a choice. Do not read 96.12% as "nearly full": at this density there
is a large amount of LUT capacity left inside the occupied CLBs.
## Result 5 -- the routing verdict, as raw output

```
C4_PHYSOPT_SECONDS 323
C4_PLACED physopt clb_sites_used 46733
C4_PLACED physopt wns -0.061
C4_PLACED physopt failing_endpoints_max 82
C4_ROUTE_SECONDS 1597
C4_ROUTE_RC 0
C4_UTIL c4lev routed lut 261539 lut_logic 234222 lut_mem 27317 ff 242696
                     carry8 12174 f7 20225 f8 3970 bram 253.5 uram 0
                     dsp 2177 clb 46733
C4_ROUTE_STATUS nets=3525162 errors=93489 unrouted=0 partial=0
C4_TIMING wns=-0.575 whs=0.010
C4_CLKWNS core_clk period=5.000 wns=-0.575
C4_CLKWNS hbm_aclk period=4.000 wns=0.080
C4_DONE impl c4lev
```

Post-route timing summary, `out/timing_c4lev_routed.rpt`:

```
 WNS(ns)   TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints   WHS(ns)  THS Failing  WPWS(ns)  TPWS Failing
  -0.575  -876.045                   9056               971406     0.010            0     1.458             0
```

`report_drc`, `out/drc_c4lev.rpt`: **0 Errors, 0 Critical Warnings.** All 2,771
violations are Warning or Advisory:

```
| Rule      | Severity | Description             | Violations |
| DPIP-2    | Warning  | Input pipelining        | 1772       |
| DPOP-3    | Warning  | PREG Output pipelining  | 319        |
| DPOP-4    | Warning  | MREG Output pipelining  | 632        |
| RTSTAT-10 | Warning  | No routable loads       | 1          |
| CHECK-2   | Advisory | Report rule not checked | 47         |
```

The three DP\* rules are DSP register-stage advisories, which is the same
finding as the congestion report arriving by a different route.

### `errors=93489` IS A FALSE ALARM OF MY OWN MAKING, and it nearly buried the answer

My `C4_ROUTE_STATUS` line counts `ANTENNAS || CONFLICTS || **HIERPORT**` as
errors. **`HIERPORT` is the ordinary status of a net attached to a hierarchical
port, and this top has 1,184 of them by design.** Vivado's own
`report_route_status` in the same run says `# of nets with routing errors : 0`
with all 516,556 routable nets fully routed.

DERIVED: `ANTENNAS` and `CONFLICTS` genuinely ARE routing errors, and Vivado
reports zero routing errors, so both are zero and **all 93,489 are HIERPORT**.

**A false alarm of that size, on the single question the composition exists to
answer, would have read as a routing failure.** The script's own header warned
about exactly this class -- "reporting 0 nets with routing errors from a report
that also lists thousands of unrouted port nets would be the kind of
silent-success claim this project keeps finding" -- and then put HIERPORT on
the wrong side of the line. Corrected: `HIERPORT` is now counted and printed
separately as `C4_ROUTE_HIERPORT`, and `errors` is `ANTENNAS || CONFLICTS`
alone.

**The lesson is not "be careful". It is that a checker written to avoid a false
PASS produced a false FAIL, and only the tool's own independent count caught
it.** Cross-check against `report_route_status` and never trust a hand-rolled
`get_nets` filter alone.

## Result 6 -- where the congestion is, post-route

`out/congestion_c4lev_routed.rpt`, max level **6**, against **7** on the
attempt that failed:

```
Direction Type   Level Window                          LUT LUTRAM Flop MUXF RAMB  DSP CARRY  Cell Names
East      Global     5 (CLEL_L_X16Y190,CLEM_X31Y221)   66%     6%  32%   3%  71%  62%   17%  a_eng/eng/dut/core(50%),c_attn(23%)
North     Long       6 (CLEM_X9Y56,CLEM_X72Y119)       64%     6%  29%  14%  41%  94%   28%  c_attn/u_arr(73%),a_eng/eng/dut/core
North     Long       6 (CLEM_X9Y72,CLEM_X72Y103)       64%     6%  28%  14%  42%  94%   27%  c_attn/u_arr(77%),a_eng/eng/dut/core
South     Long       5 (CLEM_X54Y149,CLEM_X77Y196)     70%    37%  42%   1%  92% 100%   26%  a_eng/eng/dut/core(56%)
East      Long       5 (CLEL_R_X10Y177,LAG_LAG_X40Y224) 67%    5%  31%   3%  76%  75%   20%  a_eng/eng/dut/core(49%),c_attn(22%)
East      Long       5 (CLEL_R_X10Y193,LAG_LAG_X40Y224) 68%    5%  31%   3%  83%  69%   20%  a_eng/eng/dut/core(50%),c_attn(21%)
West      Long       6 (CLEM_X32Y99,CLEM_X95Y194)      60%    23%  32%   4%  67%  99%   27%  a_eng/eng/dut/core(48%),c_attn(27%)
West      Long       6 (CLEM_X32Y115,CLEM_X79Y178)     57%    23%  31%   3%  56% 100%   26%  a_eng/eng/dut/core(49%),c_attn(28%)
```

**DSP is 94-100% in every level-6 window** and 62-75% in the level-5 ones,
while LUT never exceeds 70%. The two named cells are the only two DSP consumers
in the composition: `a_eng/eng/dut/core`, subsystem A's matvec array, and
`c_attn/u_arr`, subsystem C's attention array.

**So the next lever is a DSP lever, and there is not one.** This is a genuinely
new question that did not exist before tonight, because LUT was the binding
resource in every previous measurement.
## What this does and does not license

**Does:** STEP 2 of `docs/PLAN_TO_FIRST_INFERENCE.md` is answered. Its own
"done when" was *"`compose4_top` with both levers reaches `route_design` with 0
nets with routing errors and a reported WNS"*. Both conditions are met. The
schedule below it is no longer unfalsifiable, and the two-card split is not
forced by routability.

**Does not:**

- **It is not 200 MHz.** -0.575 ns is a real miss and the card's shell runs
  `core_clk` at 5.000 ns. Either the composition gets 0.575 ns faster or the
  engine clock comes down to ~179 MHz, which is a throughput decision nobody
  has taken.
- **It is not the card top.** `compose4_top`'s subsystems are not wired to each
  other and it has 1,184 out-of-context ports. The real top adds inter-subsystem
  nets the router has never seen and removes 1,184 ports it has. **Both
  directions, and neither is estimated.**
- **It is not the shell.** No XDMA, no HBM controller, no clk_wiz, no thermal
  block, no AXI interconnect. Their cells inside `pb_core` are accounted for
  only in the BRAM arithmetic, by subtraction, and not in the LUT or DSP
  arithmetic at all.
- **It is not the gain image.** `NORM_W_IMAGE = ""`. With the real image the
  BRAM sum is 424.5 against 372.5 available and does not fit.
- **It is not arithmetic.** A routed design is not a correct one, and
  subsystems B and C have never run on this silicon.

## Open, not yet answered

1. **The 0.575 ns.** Which paths, and whether they are logic or net. TRACK
   TIMING's method on subsystem C -- find the one structure behind the whole
   failing population -- is the obvious approach, and 9,056 endpoints of
   971,406 is a much easier target than the 33,767 it faced.
2. **DSP is now the binding resource** at 80.63% of `pb_core`, and every
   congested window is DSP-saturated at 62-100%. There is no DSP lever in the
   backlog and nobody is holding a DSP budget. **This question did not exist
   before tonight.**
3. **Why the two levers do not add**: -84,625 LUT measured against -104,686
   predicted, and -117,636 FF against -176,320. The attribution control
   (`--cb-style regs`, same tree, same session) was queued and its result is
   not in this document.
4. **What the 3 stray `cb_reg*` flip-flops are.** Not codebook registers (3
   against 6,144), but unnamed. The corrected census prints the names.
5. **Whether the extracted `ooc_normadapt` is a fair stand-in for `llama_top`'s
   `gvr` in place.** The 8.2% miss is the first evidence the difference is not
   small, and nobody has measured it directly.
6. **The gain image's 171 tiles.** TRACK GWTWO's `GW` curve.
7. **The 96.12% CLB occupancy at 5.599 LUT/CLB** is a third point on the
   density curve, at a pressure where the placer had a choice. It has not been
   reconciled with the free-die 6.324 or the squeeze's 7.029, and CLAUDE.md
   already records what happens when a one-point density model is extrapolated.
## Result 7 -- the attribution control, and the whole miss belongs to ONE lever

`--cb-style regs`, **same tree, same session, same Vivado**, generated from the
same generator into `compose4_ctl_top` which differs from `compose4_top` by the
`CB_STYLE` literal and nothing else (step 6 above). `C4_SYNTH_SECONDS 480`.

```
C4_UTIL c4ctl synth lut 310180 lut_logic 294600 lut_mem 15580 ff 224400
                    carry8 12153 f7 45611 f8 16268 bram 253.5 uram 0 dsp 2177
```

Three points now exist, and they apportion the 8.2% miss exactly.

### Lever C in the composition reproduces its unit measurement

`c4ctl -> c4lev`, the only difference being the generic:

| | control | levered | delta | LEVERC48 standalone | miss |
|---|---:|---:|---:|---:|---:|
| CLB LUT | 310,180 | 265,658 | **-44,522** | -42,633 | **-4.43%** |
| LUT as Memory | 15,580 | 27,842 | **+12,262** | +12,288 | **-0.21%** |
| CLB FF | 224,400 | 237,832 | **+13,432** | +13,195 | **+1.80%** |
| F7 Muxes | 45,611 | 20,225 | **-25,386** | -24,583 | **-3.27%** |
| F8 Muxes | 16,268 | 3,970 | **-12,298** | -12,288 | **-0.08%** |
| BRAM | 253.5 | 253.5 | **0** | -- | -- |
| DSP | 2,177 | 2,177 | **0** | -- | -- |

**Every column within 4.5%, and the two with an exact structural closed form
within 0.21%.** A lever measured on `matvec_core` alone transfers to a
nine-instance composition essentially unchanged. That is a real and reusable
finding: it is not what this project usually observes.

### The norm lever delivers about 70% of what was measured in `llama_top`

`2026-08-29 baseline -> c4ctl`. **Cross-day and cross-SHA** (baseline at
`56cebe8`), which is the weaker of the two comparisons and is labelled so:

| | baseline | control | delta | RMSWIRE in `llama_top` | miss |
|---|---:|---:|---:|---:|---:|
| CLB LUT | 350,283 | 310,180 | **-40,103** | -62,053 | **+35.4%** |
| CLB FF | 355,468 | 224,400 | **-131,068** | -189,515 | **+30.8%** |
| F7 Muxes | 65,108 | 45,611 | **-19,497** | -26,736 | **+27.1%** |
| F8 Muxes | 25,788 | 16,268 | **-9,520** | -13,296 | **+28.4%** |
| BRAM | 246.5 | 253.5 | **+7.0** | +6 | +16.7% |
| LUT as Memory | 15,580 | 15,580 | **0** | -- | exact |

Every column short by **27 to 35%, all in the same direction**, which is the
signature of a proportional effect rather than one missing structure.

**So the entire 8.2% miss on the composed prediction belongs to the norm lever,
and none of it to lever C.** That is MEASURED. The MECHANISM remains an
ESTIMATE: RMSWIRE measured the region in place inside `llama_top`, while
`compose4_top`'s `d_norm` is that region extracted into a standalone entity
with the enclosing scope turned into ports, and a port cannot be optimised
away. **What would falsify it:** extracting `gvr` from the PRE-RMSWIRE
`llama_top` and drawing it beside this one, which measures the extraction's own
overhead directly instead of inferring it. Not run.

`LUT as Memory 15,580 -> 15,580` between the baseline and the control is worth
noting on its own: **exactly unchanged across a cross-day, cross-SHA
comparison.** That is a neutrality check the comparison was not designed to
provide, and it supports treating the 2026-08-29 baseline as comparable.

### The consequence for how these numbers get quoted

**A lever measured on a UNIT transferred at 0.2-4.4%. A lever measured on a
COMPOSITION transferred at 27-35% short.** That is the opposite of the ordering
anyone would guess, and the reason is not the levers -- it is that the norm
lever's "composed" measurement was composed inside a DIFFERENT top from the one
that has to fit. **"Measured composed" is not a property of a number; it names
which composition, and two compositions are two different measurements.**
### The control census closes the stray-flip-flop question for free

```
C4_CENSUS cb_reg_ff  6147
C4_CENSUS cb_reg_ram    0
C4_LEVERC INACTIVE  cb_reg_ff=6147 cb_reg_ram=0
```

**6,147 = 6,144 + 3.** The register configuration carries LEVERC48's exact
6,144 codebook registers **plus the same three strays** that appeared in the
levered run. So the three belong to some other signal whose name merely
contains `cb_reg`, they are present in BOTH configurations, and they are not
codebook registers. Open item 4 is closed without a separate run.

**And this is the census's own teeth-check.** The discriminator has now been
shown to fire on the configuration it must fire on:

| | `cb_reg_ff` | `cb_reg_ram` | verdict |
|---|---:|---:|---|
| `CB_STYLE = "distributed"` | 3 | **26,112** | ACTIVE |
| `CB_STYLE = "regs"` | **6,147** | 0 | INACTIVE |

A checker never shown to fail has not been shown to work. This one has now been
shown to discriminate, on the two configurations it exists to tell apart, in the
same session.
## Result 8 -- the control IMPLEMENTATION, and `[Route 35-447]` fires on it

The area control above answers "how much did each lever save". It does not
answer "did the levers cause the route to succeed", because the only routing
failure on record was a **different day, a different SHA, and the FREE DIE
rather than `pb_core`**. So the control was taken through the same
implementation: same tree, same session, same `pb_core`, same script.

### Placement

| | control, `CB_STYLE="regs"` | levered, both | |
|---|---:|---:|---|
| LUT in `pb_core` | 306,003 = **78.70%** | 261,539 = **67.27%** | |
| placed CLB in `pb_core` | 48,960 = **100.74%** | 46,713 = **96.12%** | control OVERFLOWS the region |
| density | 6.250 LUT/CLB | 5.599 LUT/CLB | |
| placed WNS | **-0.672** | **-0.216** | |
| failing endpoints after place | **1,932** | **268** | **7.2x** |
| after `phys_opt_design` | **-0.546**, **1,707** | **-0.061**, **82** | **20.8x** |
| congested windows reported | **11** | **5** | |
| congestion level | 6 | 6 | |

**The control's placement does not fit inside `pb_core`: 48,960 CLB against
48,600 available, 100.74%.** The placer put cells outside the region. The
levered design fits at 96.12%.

Note the control still carries the norm lever, so it is **not** the 2026-08-29
configuration: its 1,932 failing endpoints are already far better than that
run's 33,767. **This isolates lever C alone.**

### And the router says it, unprompted

```
WARNING: [Route 35-447] Congestion is preventing the router from routing all
nets. The router will prioritize the successful completion of routing all nets
over timing optimizations.
```

**That message appears in the control's log and appears NOWHERE in the levered
design's log.** Same session, same tree, same region, same script, one generic
different.

The overlap trajectories are the mechanism, side by side:

```
levered  96 -> 63 -> 26 -> 12 -> 11 -> 2 -> 2 -> 1 -> 2 -> 3 -> 1 -> 0
control  501,118 -> 162,120 -> 58,308 -> 21,191 -> 7,971 -> ... (iteration 1)
```

**The levered router begins with 96 overlaps. The control begins with 501,118**
-- five orders of magnitude apart on the same netlist minus one generic. Every
congested window in the control is `DSP 100%` with LUT at 70-79%, against the
levered design's 45-70% LUT.
### CORRECTION, appended in place: THE CONTROL ROUTES TOO

**I expected the control to fail and it did not.** Recorded here rather than by
editing the section above, because the expectation is the part worth keeping.

```
C4_ROUTE_SECONDS 1920
C4_ROUTE_RC 0
C4_ROUTE_STATUS nets=3479112 errors=93489 unrouted=0 partial=0
C4_TIMING wns=-1.168 whs=0.009
C4_CLKWNS core_clk period=5.000 wns=-1.168
C4_CLKWNS hbm_aclk period=4.000 wns=-0.064

   # of routable nets..................... :      502627
       # of fully routed nets............. :      502627
   # of nets with routing errors.......... :           0
```

`[Route 35-447]` is a **WARNING** here, not an error: it says the router will
prioritise completing the routing over timing optimisation, and it did. Four
global iterations instead of converging in the first, and overlaps that started
five orders of magnitude higher, but it finished.

**So lever C is NOT what makes the composition routable. It is what makes it
FIT and what makes it close to timing.**

| | control (`regs`) | levered (`distributed`) | |
|---|---:|---:|---|
| routes | **yes**, 0 errors | **yes**, 0 errors | |
| fits inside `pb_core` | **NO, 48,960 of 48,600 CLB = 100.74%** | **yes, 96.12%** | the real difference |
| `[Route 35-447]` | **fires** | absent | |
| router overlaps at start | 501,118 | 96 | |
| route time | 1,920 s, 4 global iterations | 1,597 s | |
| `core_clk` WNS | **-1.168** (Fmax 162.1 MHz) | **-0.575** (Fmax 179.4 MHz) | **+0.593 ns** |
| `hbm_aclk` WNS | **-0.064, FAILS** | **+0.080, MEETS** | lever C closes the HBM domain |
| TNS | **-19,758.709** | **-876.045** | **22.6x** |
| failing endpoints | **57,342 of 830,211 = 6.91%** | **9,056 of 971,406 = 0.93%** | **7.4x by fraction** |
| WHS | +0.009 | +0.010 | both meet |

**The corrected claim, and it is narrower than the one I set out to make:**
routability was already achieved by the norm lever alone; lever C converts a
design that overflows its region and misses both clocks into one that fits and
misses one clock by 0.575 ns.

**And a claim nobody should now make in either direction: no composed
`route_design` has ever been observed to FAIL to completion in this project.**
The 2026-08-29 attempt was **killed as a decision while thrashing**, which is
strong evidence and is not an observation of failure. Both configurations
measured tonight route. That is worth stating because the whole framing of
STEP 2 -- "the router already failed at a looser density" -- rests on a run
that was stopped, not one that finished.
## Result 9 -- does TRACK TIMING's diagnosis survive?

`166cbd4` credited TIMING with having predicted this: that the 33,511 failing
endpoints beyond the 256 it fixed by hand were net-delay whose *"root cause is
area, at 54,866 of 54,960 CLB"*.

**That credit is withdrawn. My data does not support it and does not refute it.**

What my data DOES support, from two same-session points that differ in area and
in nothing else:

| | LUT | placed CLB | placed failing endpoints |
|---|---:|---:|---:|
| control (norm lever only) | 306,003 | 48,960 | **1,932** |
| levered (both) | 261,539 | 46,713 | **268** |

**-44,464 LUT removes 1,664 failing endpoints, a 7.2x reduction, with nothing
else changed.** So failing-endpoint count IS steeply area-sensitive in this
composition, which is the direction TIMING's argument needs.

**But that is not the same claim.** TIMING's number is 33,767, mine are 1,932
and 268, and between the original run and mine BOTH the area AND the placement
constraint changed. **A relationship demonstrated between 306,003 and 261,539
LUT under a pblock says nothing rigorous about a die-wide run at 350,283.**
Extrapolating it would be the exact error CLAUDE.md records twice: a model
fitted where it was measured, quoted about a point it never saw.

**The honest status: TIMING's diagnosis is PLAUSIBLE and CONSISTENT with two
new points, and remains unproven at the point it was made about.**

## Measured and REJECTED -- do not retry

**1. `synth_design -generic CB_STYLE=distributed` to reach the codebook.**
`-generic` binds the TOP's generics only; `matvec_core` is four levels down.
No Vivado mechanism sets a generic on a deep instance from the command line.
The generic must be declared and forwarded by every entity on the path, and
`fk33_engine` was the one that did not.

**2. Fixing `sim/ooc_normadapt_extract.py` for the new `llama_top`.** The brief
said it aborts against HEAD. Only `--shift` does. The plain path costs one
second and settles it. **No extractor fix was made and none was required.**

**3. A whole-file substring test as the staleness guard.** HEAD's extraction
contains `rmsnorm_rs_mem` in a comment 173 lines before it binds the entity, so
`if "rmsnorm_rs_mem" in text` passes on a file that binds the flat unit.

**4. A bare `route_design` in the batch script.** `[Route 35-447]` can be an
ERROR and would abort before any report is written. Wrapped in `catch`.
**Note it was a WARNING in both runs here, so the wrapper was not what saved
them** -- it is insurance, and it has not yet been shown to earn its keep.

**5. `cb_reg_ff == 0` as the lever-C discriminator.** Too strict: the wildcard
`NAME =~ *cb_reg*` over-matches by exactly 3 cells in BOTH configurations.
The discriminator is the RAM count against LEVERC48's pinned 26,112.

**6. Treating `[Synth 8-7186]` as evidence.** It printed 100 lines saying `cb[*]`
was not inferred as RAM, in a run whose census shows 26,112 RAM cells under
those exact names. Third recorded instance.

## Measurement traps hit, including my own

**MY OWN, the worst one: `C4_ROUTE_STATUS errors=93489` was a FALSE FAIL.**
My filter counted `HIERPORT` as a routing error, and this out-of-context top has
1,184 hierarchical ports by design. Vivado's own `report_route_status` in the
same run says `# of nets with routing errors : 0`. **A checker written to avoid
a false PASS produced a false FAIL on the single question the composition exists
to answer**, and only the tool's independent count caught it. The script's own
header had warned about this exact class and then put `HIERPORT` on the wrong
side of the line. Corrected; `HIERPORT` is now counted and printed separately.

**MY OWN: I nearly shipped an untested guard because an abort was an abort.**
The staleness guard's first run printed
`COMPOSE4 ABORT: missing .../hw/rtl/gdn_block.vhd`, which is not the guard's
abort at all -- it is the generator's default `--rtl` resolving to a directory
that has never existed. **Reading the abort's TEXT rather than its exit code is
what caught it.** That accident found the real defect, fixed in `7477f23`.

**MY OWN: a gate on a file nothing writes.** `chain2.sh` waited on
`log/drv_impl_c4ctl.txt`, which the driver never creates. The queued control
would have waited forever with the lane empty and no error anywhere. **A gate
on a file that is never written is indistinguishable from a job still
running.** After writing a gate, `ls` the thing it watches.

**MY OWN, and it is the reason the retraction above exists: I compared against
a run that differed in TWO variables and asserted one of them.** The original
failure was die-wide and unconstrained; mine is pblocked. Nothing in any
document on this track said so, because `c4dev` reads as a tag rather than as
`C4_PBLOCK=0`. **The tell was on the face of the number the whole time: 54,960
is the DEVICE CLB count and `pb_core` holds 48,600.**

**An rc read off a pipeline is the pipeline's rc.** Hit again while
teeth-checking the inverted guard: `python3 ... | head -6; echo rc=$?` printed
`rc=0` over an abort. The abort TEXT was the evidence, not the code.

**A generated file is not its generator.** `gen_fk33_engine.py` was MEASURED to
reproduce HEAD byte-identically (`md5 bf6aee7939e59415eaf34510060c8418`) before
being edited, so the 22-line diff afterwards is attributable.

**A line-number citation in another file is a dependency.**
`sim/tb_a_geom.vhd:75` cites `gen_fk33_engine.py:85,91`. The edits went in at
252 and 519; `tools/check_a_geometry.py` re-run afterwards, all sites agree.
