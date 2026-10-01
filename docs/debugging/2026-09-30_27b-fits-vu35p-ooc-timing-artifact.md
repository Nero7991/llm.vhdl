# Does the 27B fit and meet 200 MHz on the VU35P (Jungle Cat m2)?

**Date:** 2026-09-30. **Hardware/target:** xcvu35p-fsvh2104-2-e (VU35P, m2,
the Jungle Cat deployment grade). **Model:** Qwen3.8-27B (QWEN38_27B), the
full model, NCARDS=1 (the fabric-worst case). **Tree:** HEAD 006edac (c_kv/
c_attn/v_swg fmax fixes in) with the 27B `fk33_card.vhd` + 27B model_cfg
package overlaid.

## The answer, up front

**FIT: yes, comfortably.** The full 27B card is **402,006 LUT = 46.1% of the
VU35P**, with BRAM 537.5/1344 (40%), DSP 2,025/5,952 (34%), URAM 82/640 (13%).
The VU33P (439,680 LUT) was simply too small (the full 27B measured 400,619 LUT
/ 99.84% CLB there and did not route); the VU35P has 2x the fabric.

**TIMING: the engine meets 200; the "70 MHz" composed number is a
standalone-OOC artifact, not a real limiter.** `fk33_engine` (subsystem A)
routes at **222 MHz** OOC on the VU35P. `fk33_card` (B/C/D + llama_top) routed
at 69.9 MHz OOC, worst path `seq_vec_issue j_dst -> llama_top wsump.h_reg` --
but a **9B control through the identical harness gives 69.0 MHz on the identical
path**, while the shipped 9B card runs that compute at >=120 MHz in-context
(build 20: core clock 75 MHz, WNS +4.98 ns; `vissue`/`wsum`/`j_dst` appear
NOWHERE in its routed worst paths, which are all HBM-controller IP). So OOC
synthesis of `fk33_card` ALONE (no engine, no block design, no floorplan)
routes this path ~2x worse than the real build, identically for 9B and 27B.
**There is nothing to pipeline here.**

**The real composed 200 MHz timing is still open** -- it needs an in-context
build, which on the VU35P means the Jungle Cat block design (PCIe/HBM/pinout),
which does not exist yet. Per-block ratings (all >= 200 on m2) and the engine's
222 MHz are the available timing evidence.

## Procedure

1. Capacities from `hw/targets/devices.json`: VU35P m2 LUT 871,680, BRAM 1344,
   DSP 5952, URAM 640 (2x the VU33P across the board).
2. OOC harness `/mnt/storage/fk33_builds/ooc27_vu35/ooc_card_vu35.tcl`: per top,
   `synth_design -mode out_of_context`, create_clock at the m2 target (4.25 ns),
   `opt/place/phys_opt/route`, report utilization + setup WNS. Driven by
   `run_ooc27.py` reusing the rate tool's GHDL dep solver (`tools/rate/deps.py`)
   for the file list and `tools/rate/vivado.py run_batch` for the capped run.
3. Tree `wt27v35`: a detached HEAD worktree + the 27B `fk33_card.vhd` (from the
   surviving `wt27`) + the 27B `hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd`
   substituted for the committed 9B `rtl/model_cfg_pkg.vhd`.
4. Control: the same OOC flow on the committed 9B `fk33_card` (REPO tree).
5. Cross-check: the shipped build 20 routed timing summary (9B, in-context).

## Evidence (MEASURED, tools/rate OOC on xcvu35p-fsvh2104-2-e)

| top | LUT | BRAM | DSP | URAM | WNS (ns) | MHz | worst path |
|---|---|---|---|---|---|---|---|
| fk33_engine (A) | 133,303 | 192.5 | 1,585 | 0 | -0.253 | 222.0 | xq_rd -> tr DSP (matvec, internal) |
| fk33_card (B/C/D) 27B | 268,703 | 345 | 440 | 50 | -10.05 | 69.9 | u_vissue/j_dst -> wsump.h_reg |
| fk33_card (B/C/D) 9B control | 231,114 | 225.5 | 497 | 32 | -10.24 | 69.0 | u_vissue/j_dst -> wsump.h_reg |

Shipped build 20 (9B, in-context, full BD): core clock 75.000 MHz, Design
Timing Summary WNS +4.98 ns; worst routed paths all in
`bd_i/hbm/.../hbm_apb_arbiter` on the 100 MHz HBM clock
(`hw/fk33/results/card_build20_2026-09-24/bd_wrapper_timing_summary_routed.rpt.gz`).

## Measured and REJECTED -- do not retry

- **"The composed 27B card is a ~70 MHz design that needs composition
  pipelining."** REJECTED. The 9B control gives 69.0 MHz on the identical path,
  and the shipped 9B build runs that compute at >=120 MHz in-context. The number
  is standalone-OOC pessimism (~2x), not a design property. Do not pipeline
  `vec_issue -> wsum` on this evidence.
- **"`vec_issue -> wsum` is a 27B-specific regression."** REJECTED. 9B OOC 69.0
  vs 27B OOC 69.9 MHz -- within noise, the 27B does not regress it.
- **Using OOC-alone `fk33_card` timing as the composed-card fmax.** It is ~2x
  pessimistic vs the in-context build; it is valid for AREA (LUT/BRAM/DSP) and
  for per-top relative comparison, not for an absolute composed fmax.

## Measurement traps hit

- **The rate dep solver only globs `rtl/` and `hw/fk33/rtl/`, never
  `hw/fk33/gen/`.** The 27B config lives in
  `hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd` (package `model_cfg_pkg`, MODEL =>
  QWEN38_27B). Overlaying only `fk33_card.vhd` onto HEAD left the 9B MODEL
  binding, and `fk33_llama_top` elaborated the 27B QKN image against the 9B
  attention-block count -> `[Synth 8-11323] assigned value '-16' out of range`.
  Fix: substitute the gen/ 27B package for the committed 9B one in the file list.
- **`fk33_card` has NO MODEL/NCARDS generic** -- the widths follow the package
  constant `MODEL` in `model_cfg_pkg.vhd`, not a cell generic, so the BD cannot
  set them and the only lever is which package is compiled.
- **card_build27b_1 was NCARDS=1 (the full model on one card), not a 33/31
  half.** The 33/31 split is for HBM capacity; the compute fabric is
  per-layer-sequential, so the full-model fabric (~46% VU35P) is the
  conservative per-card figure.

## Open, not yet answered

- The real composed 200 MHz timing on the VU35P. Needs the Jungle Cat block
  design (PCIe/HBM/pinout), which does not exist. Until then: per-block ratings
  (>= 200 on m2) + engine 222 MHz are the evidence, and there is no measured
  composition limiter below 200.
- Whether the engine's 222 MHz (just above 200) holds in-context with the HBM
  AXI clock and real floorplan.
