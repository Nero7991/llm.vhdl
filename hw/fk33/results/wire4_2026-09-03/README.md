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

## Files

- `util_wire4_synth.rpt`, `util_hier_wire4_synth.rpt`, `timing_wire4_synth.rpt`
- `synth_sentinels.txt` -- the anchored `C4_*` lines, which are what a caller
  must gate on. The log also contains the script's own commented `puts
  "C4_DONE ..."`, so an unanchored grep matches at t=0. That happened twice.
