# compose4_top WIRED, synthesis, 2026-09-03

First synthesis of the WIRED composed top. `hw/fk33/gen_compose4_top.py:177`
says "the wired top needs its own place-and-route run"; this is that run's
synthesis stage. The generated top was written to a SCRATCH tree, so the
checked-in unwired `hw/fk33/rtl/compose4_top.vhd` and TRACK ROUTE3's numbers
taken on it are untouched.

## MEASURED

`C4_DONE synth wire4`, `SYNTH_EXIT 0`, `C4_READ 111 files`,
part `xcvu33p-fsvh2104-2L-e`, core period 5.0 ns, HBM period 4.0 ns.

| resource | used | device | % |
|---|---|---|---|
| CLB LUT | 270,125 | 439,680 | **61.44** |
| LUT as logic | 242,283 | 439,680 | 55.10 |
| LUT as memory | 27,842 | 205,440 | 13.55 |
| CLB register | 237,896 | 879,360 | 27.05 |
| F7 mux | 20,315 | 219,840 | 9.24 |
| Block RAM tile | 327.5 | 672 | **48.74** |
| URAM | 0 | 320 | 0.00 |
| DSP | 2,177 | 2,880 | **75.59** |

**SETUP TIMING MEETS: WNS +0.346 ns, TNS 0.000, ZERO failing endpoints of
969,154.** The report's "Timing constraints are not met" line is HOLD
(WHS -0.100, 402,321 endpoints), which is expected before routing and is what
`route_design` fixes. Do not quote the summary line as a setup failure.

**The wired seams are present and are what they claim to be:**

| instance | module | LUT | FF | RAMB36 |
|---|---|---|---|---|
| `rgfile` | `region_mem` | 3,496 | 27 | 100 |
| `seam_a` | `a_desc_adapter` | 45 | 84 | 0 |
| `seam_a_idx` | `a_job_counter` | 21 | **11** | 0 |
| `seam_b` | `u_seam` | 5 | 7 | 0 |
| `seam_c` | `u_seam_0` | 7 | 7 | 0 |

`seam_a_idx` at **11 FF** matches the standalone OOC measurement of
`a_job_counter` exactly (11 FF, 0 CARRY, `e359805`).

## THE CAVEAT THAT MATTERS MOST, AND IT IS NOT SMALL

**This design does NOT contain B's data mover.** `compose4_top` instantiates
`gdn_block` DIRECTLY; `gb_real` -- the 614-line mover, and the only place the
24 MiB `stmem` array lives -- is in `llama_top`, not here. So:

- the 48.74% BRAM figure does **not** include B's recurrent state at all;
- URAM is 0 because the state tier is not in this design either;
- adding B's mover is still ahead, and `docs/debugging/2026-09-03_b-mover-does-
  not-fit.md` measures it alone at 63,905 LUT / 34 BRAM / 32 URAM / 194 DSP
  with `gdn_state_store` substituted.

**DO NOT ADD THOSE TWO COLUMNS TOGETHER.** Vivado maps the same RTL to
different primitives depending on what surrounds it -- MEASURED in that same
document, where `gdn_block` alone reports 22 BRAM tiles and 10,161 LUT-as-memory
while the composed block attributes 5,472 tiles elsewhere and 35,078
LUT-as-memory. A sum across two synthesis contexts is two unrelated
measurements, not a prediction.

What can honestly be said is the SHAPE: the composed design already pays for a
bare `gdn_block`, and the substituted mover measured 63,905 LUT against
`gdn_block` alone at 56,713, so the mover's own share is on the order of 7,000
LUT plus 12 BRAM and 32 URAM. **That is an ESTIMATE by cross-context
subtraction and its assumption is exactly the one the paragraph above says is
unsafe.** The only way to know is to compose them and re-synthesise.

**DSP is the tightest resource at 75.59%** and is the number to watch when the
mover is added, not LUT or BRAM.

## PLACE AND ROUTE, same day: it ROUTES CLEAN and misses 200 MHz by 0.502 ns

`C4_DONE impl wire4`, `IMPL_EXIT 0`. First place-and-route of the wired top.

| | post-route | device | % |
|---|---|---|---|
| CLB LUT | 266,138 | 439,680 | **60.53** |
| LUT as logic | 238,821 | | 54.32 |
| LUT as memory | 27,317 | 205,440 | 13.30 |
| CLB register | 243,161 | 879,360 | 27.65 |
| Block RAM tile | 327.5 | 672 | 48.74 |
| URAM | 0 | 320 | 0.00 |
| DSP | 2,177 | 2,880 | **75.59** |

LUT came in BELOW the synthesis estimate (266,138 against 270,125) because
`opt_design` runs between them. Do not read the drop as an error.

**ROUTING IS CLEAN: 521,388 routable nets, 521,388 fully routed, 0 nets with
routing errors. DRC: 0 errors, 0 critical warnings.**

**TIMING, and the two clocks behave differently:**

| clock | target | WNS | failing endpoints |
|---|---|---|---|
| `hbm_aclk` | 250 MHz (4.0 ns) | **+0.006** | **0** of 12,862 |
| `core_clk` | 200 MHz (5.0 ns) | **-0.502** | 5,287 of 956,041 (0.55%) |

So the HBM domain MEETS and the core domain misses by 0.502 ns, i.e. 5.502 ns
achieved = **181.7 MHz against the 200 MHz target**.

**HOLD IS FIXED BY ROUTING and was never a problem.** Synthesis reported
WHS -0.100 with 402,321 failing endpoints; post-route it is **+0.010 with
ZERO**. The synthesis-stage "Timing constraints are not met" line was hold, and
quoting it as a setup failure would have been wrong.

## THE FAILING-ENDPOINT CENSUS, AND WHY THE WORST PATH MISLEADS

The routed timing report lists **4 paths** for **5,287 failing endpoints**. Its
worst path is `c_attn/u_arr/p_reg_reg[43][3]` -> `c_attn/u_arr/er_r_reg`, and
three of the other reported paths are in `a_eng`. Reading that as "the problem
is C's attention array" is exactly the mistake this project keeps paying for,
so the endpoints were counted instead (`timing_census.tcl`, on the routed DCP):

| bucket | failing endpoints | share | worst slack |
|---|---|---|---|
| **`a_eng`** | **4,024** | **76.1%** | -0.493 |
| `c_attn` | 603 | 11.4% | **-0.502** |
| `b_gdn` | 591 | 11.2% | -0.460 |
| `d_norm` | 69 | 1.3% | -0.439 |

`CENSUS_TOTAL 5287` matches the timing summary's own count exactly, which is
the check that the census is measuring the same population.

**THE WORST PATH IS IN C AND 76% OF THE FAILING ENDPOINTS ARE IN A.** The two
answers point at different subsystems, and only the census points at the work.

**AND THE SPREAD IS THE REAL FINDING: all four buckets lie within 0.063 ns of
each other, -0.439 to -0.502.** A single broken path leaves one bucket far
worse than the rest. Four subsystems all landing within 63 ps is the signature
of a DESIGN-WIDE shortfall against an aggressive target, not a localised
defect. Nobody should go hunting for "the" critical path here.

## THE LEAD ON THE 0.502 ns

DRC reports **2,728 DSP pipelining warnings** on a design with 2,177 DSPs:
1,762 unpipelined inputs (DPIP-2), 632 missing MREG (DPOP-4), 334 missing PREG
(DPOP-3). Bucketed the same way (`dsp_pipelining_by_subsystem.txt`):

| bucket | DSP advisories | failing endpoints |
|---|---|---|
| `a_eng` | 1,592 | 4,024 |
| `c_attn` | 689 | 603 |
| `b_gdn` | 348 | 591 |
| `d_norm` | 99 | 69 |

The two orderings agree that `a_eng` dominates. Registering DSP inputs and
enabling MREG/PREG is the standard recovery for a shortfall of this size, and
0.502 ns on a 5 ns period is 10%.

**THIS IS A LEAD, NOT A DIAGNOSIS.** The correlation is between two rankings
over four buckets, which is far too little to establish cause, and no DSP
advisory has been shown to lie ON a failing path. The cheap discriminator is to
pipeline `a_eng`'s DSPs and re-run impl: if WNS moves, it was that.

**Also unmeasured: whether 200 MHz is required at all.** 181.7 MHz is 91% of
target and no throughput requirement in this repo has been checked against it.
Retiming effort is worth spending only after that question is answered.

## Files

- `util_wire4_synth.rpt`, `util_hier_wire4_synth.rpt`, `timing_wire4_synth.rpt`
- `synth_sentinels.txt` -- the anchored `C4_*` lines, which are what a caller
  must gate on. The log also contains the script's own commented `puts
  "C4_DONE ..."`, so an unanchored grep matches at t=0. That happened twice.
