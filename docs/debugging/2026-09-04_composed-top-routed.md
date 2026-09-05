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
