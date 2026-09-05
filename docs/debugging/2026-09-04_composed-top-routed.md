# The composed top ROUTES inside pb_core, and misses 200 MHz by 0.402 ns

**Date:** 2026-09-04
**Build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, `impl_pb`, 53 min, peak RSS 12.05 GB
**Files:** `sim/ooc_compose4_run.sh`, `sim/ooc_compose4_pnr.tcl`,
scratch `/mnt/storage/compose4b4` (shipping config, `RECUR_LANES=4`)

## The question, verbatim

Every timing claim made on 2026-09-04 carried the caveat *"this is synthesis,
not placed-and-routed"*. Cash it: place and route the composed top at the
SHIPPING configuration, inside a `pb_core`-shaped pblock.

## The answer

**It routes completely and it misses timing.**

```
C4_PBLOCK_RANGE  CLOCKREGION_X0Y0:CLOCKREGION_X6Y3
C4_ROUTE_STATUS  nets=3364494 errors=0 unrouted=0 partial=0
C4_TIMING        wns=-0.402  whs=0.009
C4_CLKWNS        core_clk period=5.000 wns=-0.402      ->  185.1 MHz
C4_CLKWNS        hbm_aclk period=4.000 wns=+0.067      ->  meets at 250 MHz
rc=0, 0 errors
```

**The pblock question is settled: it fits.** `pb_core` is
`CLOCKREGION_X0Y0:X6Y3` and `hw/fk33/build_fk33_pcieep.tcl:1749` errors if the
shipping build's range is anything else. This routed inside exactly that range
with **zero unrouted nets out of 3.36 million**, so `impl_dev` on the whole
die was not needed to distinguish a pblock failure from a device failure.

**Hold meets** (`whs +0.009`) and **the HBM clock meets** at 250 MHz. The
entire shortfall is `core_clk`.

## The synthesis number OVERSTATED the design by 0.748 ns

| stage | core_clk WNS |
|---|---|
| synthesis (`2026-09-04_mover-timing-is-a-vehicle-artefact.md`) | **+0.346** |
| routed | **-0.402** |

That is the "synthesis is not routed" caveat quantified. **Any decision taken
on the +0.346 was taken on a number 0.748 ns optimistic**, and one was: this
session told Oren that the pressure to retarget 200 MHz came from the A-only
endpoint bitstream (192.2 MHz) "not from the composed logic". **WITHDRAWN.**
The composed top at 185.1 MHz is the WORSE of the two. A retarget would have
to go to ~185 MHz, not 192.2.

## The failure is BROAD, not one path

Routed census, 2,361 failing endpoints, **complete population** (cap 20,000
not reached, unlike B's synthesis census which hit 5,000):

| hierarchy | failing endpoints | worst slack |
|---|---|---|
| `c_attn` | 990 | -0.401 |
| `b_gdn` | 986 | -0.402 |
| `a_eng` | 319 | -0.338 |
| `d_norm` | 66 | -0.168 |

**Three independent subsystems within 0.064 ns of each other.** This is the
distinction `sim/ooc_mover_paths.tcl` exists to make -- one pathological path
versus many mediocre ones -- and it lands decisively on the latter. **A design
misses 200 MHz here by being uniformly ~0.4 ns short, not by having a bad
path.**

Worst path, which DID carry over from synthesis:

```
Source:      b_gdn/sp_b_e_reg[5]/C
Destination: b_gdn/u_scal/ip_z_reg[24]/R
Logic Levels: 19  (CARRY8=10 LUT2=2 LUT3=1 LUT6=6)
```

Same startpoint and same destination array as the synthesis critical path.
That was NOT assumed -- a 0.748 ns swing is exactly the regime where routing
changes which path is critical, so it was re-measured, and it held.

**But it is now much less useful than it looks.** Pipelining `u_scal` moves
`b_gdn`'s -0.402 and leaves `c_attn` at -0.401. **There is no single fix
here.**

## Congestion, and the leading explanation (DERIVED, not MEASURED)

`report_design_analysis -congestion` on the routed design shows **Level 5 and
6** windows (Vivado's scale runs to 8), concentrated on two owners:

```
North Long 6  LUT 63% RAMB 48% DSP 56%   c_attn/u_arr(90%), a_eng/eng/dut/core(4%)
South Long 5  LUT 64% RAMB 100% DSP 25%  c_attn/u_arr(88%), compose4_top(11%)
East  Short 5 LUT 70% RAMB 83% DSP 66%   c_attn/u_arr(97%)
West  Long 5  LUT 42% RAMB 100% DSP 100% a_eng/eng/dut/core(49%), c_attn/u_arr(28%)
North Global 5 LUT 70% RAMB 100% DSP 100% c_attn/u_arr(85%), rgfile(10%)
```

Inside `pb_core` (`pbutil_c4pb_placed.rpt`):

| resource | used | pblock | % |
|---|---|---|---|
| DSP | 2,065 | 2,700 | **76.48** |
| CLB LUT | 248,755 | 388,800 | 63.98 |
| Block RAM | 306.5 | 576 | 53.21 |
| CLB Registers | 221,856 | 777,600 | 28.53 |
| CARRY8 | 11,130 | 48,600 | 22.90 |

**DERIVED, and labelled as such:** a uniform ~0.4 ns shortfall across three
subsystems, with a 19-level worst path, points at ROUTING rather than logic
depth, and the congestion windows show local DSP and RAMB occupancy at
87-100% around `c_attn/u_arr`. That is consistent with DSP/BRAM column
saturation forcing long detour routes. **This is an inference from
correlation, not a measurement of causation.** It has NOT been tested by, for
example, re-running with a relaxed pblock or a floorplan that spreads
`u_arr`.

## Measured and REJECTED -- do not retry

- **"The composed logic is comfortable and only the endpoint bitstream is
  tight."** REJECTED. That was said this session on the +0.346 synthesis
  number. Routed, the composed top is 185.1 MHz against the endpoint
  bitstream's 192.2 MHz.
- **"Fix the critical path."** The worst path is real and carried over from
  synthesis, but `c_attn` fails within 0.001 ns of `b_gdn`. Fixing one
  subsystem cannot reach 200 MHz.
- **Running `impl_dev` to find out whether it fits the die.** Unnecessary: it
  already routed inside the smaller `pb_core` with 0 unrouted nets.

## Measurement traps hit

- **A census that hits its cap is a ranking, not a population.** B's synthesis
  census returned exactly 5,000 of a 5,000 cap and its bucket ranking below
  the top entry is therefore untrustworthy. This routed census returned 2,361
  of 20,000 and IS a population. The two look identical in the output.
- **The congestion report's section headers match a naive grep for
  "congestion"** and return nothing useful; the table is keyed on
  `Direction|Type|Level`.
- **A synthesis attribution is not a routed attribution.** It happened to
  carry over here. It was still measured rather than assumed, and the 0.748 ns
  swing is why.

## Open, not yet answered

- **Whether congestion CAUSES the shortfall.** Untested. The cheap experiments
  are a relaxed pblock, and a floorplan that spreads `c_attn/u_arr`.
- **Whether 200 MHz is required at all.** Now sharper: the target would have
  to drop to ~185 MHz, and `hw/fk33/gen_pcieep.py:360` derives 200 from
  `duty = f_core/f_axi = 200/250 = 80%`. At 185 MHz that is 74%, still under
  1.0, so the duty argument survives the drop. **Oren's call, unchanged.**
- **The A-only endpoint bitstream's 9,213 failing endpoints** are still
  unattributed by hierarchy; `sim/ooc_mover_paths.tcl`'s census would do it.
- **This is one placement.** No seed sweep, no `-directive` exploration.
  A 0.402 ns gap is within the range implementation strategies sometimes
  close, and none has been tried.
- **Still no token-correctness claim, and nothing has run on the card.**

---

## FOLLOW-UP, same day: directives close 85% of the gap. 197.7 MHz, fully routed.

The "open" item above -- *"one placement, no seed sweep, no `-directive`
exploration, and 0.402 ns is within the range implementation strategies
sometimes close"* -- is now measured. It was closable, mostly.

**`sim/ooc_compose4_pnr.tcl` had no way to pass a directive.** It called
`opt_design`, `place_design`, `phys_opt_design` and `route_design` bare. Four
env knobs were added (`C4_OPT_DIR`, `C4_PLACE_DIR`, `C4_PHYSOPT_DIR`,
`C4_ROUTE_DIR`), **all defaulting to empty**, which invokes each command
exactly as before -- so every measurement taken before the change still
describes what it measured. Verified in `tclsh`, not assumed: empty yields a
zero-length argument list.

| run | core_clk WNS | fmax | failing endpoints |
|---|---|---|---|
| baseline, no directives | -0.402 | 185.1 MHz | 2,361 |
| `ExploreWithRemap` / `ExtraTimingOpt` / `AggressiveExplore` / `Explore` | **-0.110** | 195.7 MHz | -- |
| + POST-ROUTE `phys_opt_design -directive AggressiveExplore`, then `route_design -preserve` | **-0.059** | **197.7 MHz** | **707** |

All three FULLY ROUTED. The final checkpoint, verified with the project's own
classification AND Vivado's `report_route_status`:

```
RS_VERDICT nets=3364687 errors=0 unrouted=0 partial=0
RS_UNROUTED 0  RS_PARTIAL 0  RS_ANTENNAS 0  RS_CONFLICTS 0
report_route_status: # of nets with routing errors : 0
```

Hold: `whs 0.000`, met. **0.402 ns -> 0.059 ns is 85% of the gap closed by
tooling alone, with no RTL change**: from 8.0% short of the period to 1.2%.

**The post-route `phys_opt` lever had never been pulled on this design.** The
script runs `phys_opt_design` BEFORE `route_design` and never after, so the
standard treatment for a small routed residual was structurally unavailable.
It is worth 0.051 ns here.

### A trap this follow-up walked into, and the check that caught it

The post-route run printed `PR_UNROUTED 368454` from a hand-rolled filter of
"every net whose `ROUTE_STATUS` is neither `ROUTED` nor `INTRASITE`". **A
timing number from a design with 368,000 unrouted nets is meaningless, and
closing timing by leaving nets unrouted is the classic way this goes wrong**,
so `-0.059` was NOT reported until the count was resolved.

It was a misclassification, and the arithmetic is exact:

```
HIERPORT   99,166
NOLOADS   269,288
          -------
          368,454   <- exactly the bogus "unrouted" count
```

`ooc_compose4_pnr.tcl:394-401` already documents this for `HIERPORT` --
*"the ordinary status of a net attached to a hierarchical port ... a false
alarm of that size on the single question the composition exists to answer
would have read as a routing failure"* -- and counts only `ANTENNAS` and
`CONFLICTS` as errors. **The existing guard was right and the new one was
wrong.** Use the script's classification, or `report_route_status`, never a
negated filter over an enum whose members you have not enumerated.

## Still open

- **0.059 ns remains.** Untried: a seed sweep (`-directive` is one axis,
  placement seed is another and moves designs of this size by comparable
  amounts), further `phys_opt` iterations, and `route_design -directive
  AggressiveExplore` or `NoTimingRelaxation`.
- **This is one seed.** 197.7 MHz is a point on a distribution, not the
  design's ceiling, and not a guarantee that a rebuild reproduces it.
- **Meeting timing is necessary, not sufficient.** `llama_top:4316` still
  refuses `B_SRC_REAL` past token 0: there is no token-correctness claim for
  B on hardware at any frequency.
- The directive run has NOT been repeated on the `RECUR_LANES=32` variant, so
  the lane-count decision is still open on its own terms.

## FOLLOW-UP 2: phys_opt is EXHAUSTED at -0.041 (198.4 MHz)

Three further `phys_opt_design` directives on the post-route checkpoint, each
followed by `route_design -preserve`, each route-status checked with the
project's classification:

| pass | directive | WNS | gain | route status |
|---|---|---|---|---|
| start | (post-route `AggressiveExplore`) | -0.059 | -- | clean |
| 1 | `AlternateReplication` | -0.047 | **0.012** | errors=0 unrouted=0 partial=0 |
| 2 | `AggressiveFanoutOpt` | -0.045 | **0.002** | errors=0 unrouted=0 partial=0 |
| 3 | `AlternateFlowWithRetiming` | **-0.041** | **0.004** | errors=0 unrouted=0 partial=0 |

**The gains are 0.012, 0.002, 0.004 ns. That is a plateau, not a trend.** The
last two are noise-level against a 5.000 ns period. Different directives were
used rather than repeating `AggressiveExplore`, so this is not the same lever
pulled three times: it is three levers, all spent.

**Full progression, shipping configuration, inside `pb_core`, all fully
routed:**

| stage | WNS | fmax | % of period short |
|---|---|---|---|
| baseline, no directives | -0.402 | 185.1 MHz | 8.0% |
| high-effort directives | -0.110 | 195.7 MHz | 2.2% |
| + post-route phys_opt | -0.059 | 197.7 MHz | 1.2% |
| + three more phys_opt directives | **-0.041** | **198.4 MHz** | **0.8%** |

**90% of the original gap closed by tooling alone, no RTL change.**

### What 0.041 ns actually costs, and why this may be the stopping point

`hw/fk33/gen_pcieep.py:360` derives the 200 MHz target from the duty identity
`duty = f_core / f_axi = 200/250 = 80.0%`. At **198.4 MHz that is 79.4%** --
inside the design point, not a concession that changes the bandwidth argument.
The throughput difference against the target is **0.8%**.

So the engineering question is no longer "can this design run" but "is 0.8%
worth a seed sweep". **That is a judgement, and it is Oren's**, not something
to settle by burning hours of place-and-route.

### Still untried, and it is a DIFFERENT axis

Placement **seed** is the one remaining lever and it is not a local-optimum
escape of the kind `phys_opt` performs -- it changes the starting placement,
so it explores a different basin entirely. Designs of this size commonly move
by more than 0.041 ns across seeds. Nothing about the plateau above predicts
what a seed sweep would find, in either direction.

**Everything else in this file's "still open" list is unchanged**, including
the one that matters most: meeting timing is NECESSARY, NOT SUFFICIENT, and
`llama_top:4316` still refuses `B_SRC_REAL` past token 0.

---

## FOLLOW-UP 3, 2026-09-05: `ExtraNetDelay_high` + `NoTimingRelaxation` LOSES. Do not retry.

**The question**, taken verbatim from this file's own open list at line 224:

> Untried: ... `route_design -directive AggressiveExplore` or
> `NoTimingRelaxation`.

**The answer: it is WORSE than doing nothing.** Fully routed, clean, on a fresh
synthesis from a pinned tree at HEAD:

```
C4_DIRECTIVES opt='' place='ExtraNetDelay_high' physopt='AggressiveExplore' route='NoTimingRelaxation'

placed    wns -0.406   failing   147
physopt   wns  0.006   failing     0
routed    wns -0.422   whs 0.009   TNS -26.000   failing 1066 / 970997
C4_ROUTE_STATUS nets=3535996 errors=0 unrouted=0 partial=0
route_status_c4nd.rpt:  520701 routable, 520701 fully routed, 0 with errors
```

`core_clk` 5.000 ns, WNS -0.422 -> **184.4 MHz**, against the no-directive
baseline's 185.1 MHz and this file's best of **198.4 MHz**. Total wall time
**77.3 minutes** (synth 465 + opt 102 + place 1073 + physopt 1087 + route 1910).

### The pre-route number was optimistic by 0.428 ns

**`phys_opt` finished at +0.006 with ZERO failing endpoints, and routing gave
all of it back and more.** The progression is not monotonic:

| stage | WNS | failing endpoints |
|---|---|---|
| placed | -0.406 | 147 |
| phys_opt | **+0.006** | **0** |
| routed | **-0.422** | 1066 |

A pre-route estimate of "meets timing with zero failing endpoints" preceded a
routed result 0.428 ns short. **Nothing before `route_design` is a timing
result on this design.** This is the same lesson as reading `STATS.WNS` from
the wrong stage, but far more expensive: the intermediate number was not merely
from a different stage, it had the opposite sign.

### METHODOLOGICAL FLAW IN THIS EXPERIMENT, stated because it limits the conclusion

**Three variables were changed at once** against the prior best:

| knob | prior best | this run |
|---|---|---|
| `opt` | `ExploreWithRemap` | (none) |
| `place` | `ExtraTimingOpt` | `ExtraNetDelay_high` |
| `physopt` | `AggressiveExplore` | `AggressiveExplore` |
| `route` | `Explore` | `NoTimingRelaxation` |

So **the loss cannot be attributed to `NoTimingRelaxation`**, which is the knob
the open item actually named. It could be the dropped `opt_design` directive,
the placer, the router, or an interaction. What is established is that this
COMBINATION is worse than both the baseline and the prior best; what is NOT
established is which knob did it.

To attribute, change one at a time from the prior best. That is three more runs
at ~77 min each, and given the result is 0.4 ns in the wrong direction the
honest recommendation is to spend them elsewhere.

## Measured and REJECTED -- do not retry

- **`place=ExtraNetDelay_high` + `route=NoTimingRelaxation` with no
  `opt_design` directive.** -0.422 routed, 184.4 MHz, 77.3 min. Worse than the
  no-directive baseline. The name `NoTimingRelaxation` suggests it should
  protect timing; measured, this combination does not.
- **Reading a `phys_opt` WNS as a result.** +0.006 with 0 failing endpoints
  preceded -0.422 routed in this very run.
- **Reading a PLACED WNS as a predictor either.** -0.406 here against the
  baseline's -0.402, and this run ended phys_opt 0.4 ns better and routed 0.02
  ns worse. Placed WNS ordered the two runs backwards at both later stages.

## Correction to a claim made earlier the same day

**WITHDRAWN: "phys_opt gained 0.412 ns here against 0.012/0.002/0.004 in the
prior chain, so 'phys_opt is EXHAUSTED' was a statement about a placement."**
That comparison is a STAGE MISMATCH and is void. The 0.012/0.002/0.004 gains in
FOLLOW-UP 2 are POST-ROUTE incremental passes on an already-routed checkpoint;
the 0.412 here is the main PRE-route `phys_opt`. They are not comparable
quantities, and the pre-route figure turned out not to survive routing at all.

---

## VOID EXPERIMENT, 2026-09-05: `compose4_top` does not contain `llama_top`

Recorded because it cost 20 minutes of synthesis and would cost the next person
77, and because the null result was about to be reported as a real one.

**The intent** was to measure what commit `32d8c27`'s per-lane conv-tap mux
costs in the composed top. `b_gdn` is this file's critical-path block, the mux
sits inside `gb_real`, so the change looked like a timing risk worth measuring.
A tree was pinned at the new HEAD, the PRIOR BEST directive set was used so
that exactly ONE variable changed, and synthesis was run.

**Every utilization figure came back bit-identical:**

```
pre-tap  (tree_0905,  1d7b87ac)  lut 267202  ff 237905  bram 253.5  dsp 2177
post-tap (tree_0905c, 05addd1)   lut 267202  ff 237905  bram 253.5  dsp 2177
```

An identical result across a real RTL change is a reason to check the harness,
not to publish. `llama_top.vhd` does not appear ANYWHERE in the synthesis log,
and `compose4_top` instantiates:

```
attn_block  fk33_engine  gdn_block  ooc_normadapt
seq_desc_fetch  seq_opdec  seq_region_lock  seq_vec_issue  seq_vec_res
```

**`gdn_block` directly, never `llama_top`.** So `gb_real` -- subsystem B's data
mover, and the whole location of the change -- is not in the composed top at
all. The identical numbers are correct and mean nothing about the tap wiring.

**The error is the one this file's FOLLOW-UP 3 already criticises, in a new
form.** There it was changing three variables at once; here it was failing to
confirm the changed code was inside the device under test before spending an
hour measuring it. *Verify the change is in the DUT before designing the
comparison*, which costs one `grep` for the instantiation list.

**It also explains why the composed top is not an inference design.** The
per-unit data movers are absent by construction: `compose4_top` wires the
COMPUTE blocks together, and `gb_real` is the thing that would feed them. That
is consistent with what `gen_compose4_top.py:928` already says, and it means a
mover measurement has to be done on the extracted block, not here.

The run was stopped rather than finished. Its only remaining value would have
been a reproducibility check of the -0.110 figure, which did not justify
holding the single Vivado lane for another 50 minutes.
