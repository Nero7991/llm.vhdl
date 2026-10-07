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
  `vec_issue -> wsum` on this evidence. (The "standalone-OOC pessimism"
  MECHANISM named in this bullet is itself superseded -- see CORRECTION
  2026-10-07 below. The bullet's own conclusion, "do not pipeline," still
  stands either way: a dangling debug port is even less of a reason to
  pipeline anything than isolation pessimism was.)
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
- (Added 2026-10-07, fix round 2.) A direct OOC run of `fk33_card` (or the
  Task 10 composition) with `obs_wsum` and its siblings tied off, to turn
  the dangling-debug-port cause from DERIVED into MEASURED. `run_ooc27.sh`/
  `ooc_card_200.tcl` exist as scripts only; no Vivado run from this task.

## CORRECTION, 2026-10-07 (plan Task 10, fix round 1)

**The "isolation pessimism" explanation above for `fk33_card` ALONE's 69.9 MHz
OOC number is WITHDRAWN as the cause.** It is not retracted as a measurement
(69.9 MHz OOC, worst path `seq_vec_issue/j_dst -> wsump.h_reg`, is still what
that run reported) but the EXPLANATION this document gave for it -- "no
engine, no block design, no floorplan," attributed in the body text to
isolation making the composition artificially sparse/pessimistic -- is wrong.

**Fix round 2 correction (2026-10-07): the replacement cause below is
DERIVED, not MEASURED.** No OOC run with `obs_wsum` (and its siblings) tied
off has actually been executed to directly confirm that doing so removes the
69.9 MHz limiter -- Task 10's own `run_ooc27.sh`/`ooc_card_200.tcl` harness
exists only as a script at this point (CLAUDE.md's hardware boundary: no
Vivado run from this task). The DERIVATION rests on three structural facts,
each independently checkable in text, not on a before/after timing
comparison: (1) the worst path's ENDPOINT net name, `wsump.h_reg`, fans out
to `obs_wsum` and nothing else (a text-level fan-out trace, not a timing
run); (2) `jc_card_bd.tcl` never connects `obs_wsum` to anything, confirmed
by grepping its own `connect_bd_net`/`connect_bd_intf_net` calls; (3) build
20's OWN synthesis log reports `port 'obs_wsum' of module 'bd_card_0' is
unconnected`, which is Vivado stating, for the real in-context build, that
it drops the logic feeding a dangling module-reference output. Those three
facts are each MEASURED/grepped; what remains DERIVED (inferred, not
directly measured) is the causal claim that follows: that exporting
`obs_wsum` as a live OOC top-level port (rather than leaving it dangling,
as the real build does) is SPECIFICALLY what pins the 69.9 MHz number. The
real cause, as derived while building Task 10's OOC harness for the
engine+seam+card composition: `wsump.h_reg` is NOT on the path this document
originally assumed. It is the output register of a 60-level, 8-step
multiply-by-31-add DEBUG HASH (`fk33_llama_top.vhd:8243`) that drives
exactly one thing: the card's `obs_wsum` debug/observability output port.

`hw/jc/card/jc_card_bd.tcl` never connects `obs_wsum` to anything -- not to
HBM, not to the host, not to any of the other cells. Build 20's own
synthesis log confirms the real build never pays for this logic at all:
`port 'obs_wsum' of module 'bd_card_0' is unconnected`, and Vivado's
synthesis of a module-reference cell with a dangling output simply drops the
logic feeding it. The OOC harness that produced 69.9 MHz, by contrast, ran
`synth_design -mode out_of_context` directly on `fk33_card` with EVERY port
(including `obs_wsum`) exported as a top-level OOC port -- an OOC top-level
port can never be optimised away, so the 60-level hash stayed alive and its
own 14.28 ns path dominated the routed critical path. The 9B control number
(69.0 MHz, "the identical path") is not independent evidence of isolation
pessimism either: it is the SAME debug hash on the SAME dangling port, run
through the SAME harness, so of course it reproduces almost exactly -- a
hash with no data dependency on the model size reporting the same number at
two model sizes is additional confirmation of THIS cause, not of the
withdrawn one.

**What is NOT withdrawn.** The comparison to the shipped 9B build 20
in-context (core clock 75 MHz, WNS +4.98 ns, worst paths all HBM-controller
IP, `vissue`/`wsum`/`j_dst` nowhere in them) is still good evidence that
`fk33_card` ALONE's OOC number was never a real limiter -- it just was not,
and is not now shown to be, evidence of "isolation" as the mechanism. The
"Open, not yet answered" section's open question (does the real composed
design meet 200 MHz in-context) remains open: this correction identifies one
wrong number's wrong cause, not a new measurement of the real composed fmax.

**Procedure that found it, for the next person who hits a dangling-debug-
port artifact:** build an OOC harness that EXPORTS every port of a module
whose BD wiring you have in text (`jc_card_bd.tcl`), DIFF the exported set
against the BD's own `connect_bd_net`/`connect_bd_intf_net` calls (which
ports does the BD actually drive to something), and read the worst path's
ENDPOINT net name (`wsump.h_reg` fans out to `obs_wsum`, nothing else) against
that diff. A port in the "exported but BD never connects it" set that also
happens to be the worst path's endpoint is the tell; a debug/observability
name (`obs_*`, `smp_*`) on that list should be the first thing checked, not
the last.

**WITHDRAWN, not yet filed as "Measured and REJECTED" (fix round 2
correction, 2026-10-07):** "the composed 27B card's OOC number reflects
isolation-induced placement pessimism" as a mechanism for THIS specific
69.9/69.0 MHz pair. This is a WITHDRAWAL, not a rejection by measurement: it
was never tested directly either way (no OOC run of `fk33_card` with
`obs_wsum` and its siblings tied off has been run, before or since this
document was first written -- see the DERIVED caveat above), so there is no
measured number that killed it the way "Measured and REJECTED" entries
elsewhere in this project's debugging docs are expected to have. It is
superseded, on the strength of the three structural (text-level) facts
above, by the dangling-debug-port explanation -- but it earns a place in
"Measured and REJECTED" only once an actual OOC run with `obs_wsum` tied off
exists to measure against. Until then, both this withdrawal and the
dangling-debug-port replacement are DERIVED, not MEASURED.

See `hw/jc/card/gen_ooc27_top.py`'s own docstring and
`.superpowers/sdd/2026-10-07-jc-engine-composition/task-10-fix-round-1-
report.md` for the fix (tie off every port the BD never connects, rather than
exporting it) and its tests.
