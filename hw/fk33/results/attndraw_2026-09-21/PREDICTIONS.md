# TRACK ATTNDRAW -- predictions registered BEFORE the first Vivado started

Written 2026-09-21, before launch. Tree `3e344a2`, manifest sha256
`188ea744beb0389ac510113543795feaad77c635bfed42ff395796fb14a668e7`,
119 files, verified byte-identical on both boxes.

Arms, all three from the SAME staged tree through the SAME driver
(`sim/run_attndraw.sh`, a copy of the committed `sim/ooc_scorehdr_run.sh`
differing only in three `arm_gen` lines, the `ROOT` default and a
`memory.high` readback -- the diff is in this directory):

| arm | `SWEEP_PIPE` | `SCORE_EARLY` | what it is |
|---|---|---|---|
| `coff` | false | false | the baseline. What every card build to date synthesised, and what build 12 is synthesising now. |
| `con`  | **true** | **true** | HEAD's setting (`rtl/llama_top.vhd:6997`, `rtl/fk33_llama_top.vhd:7621`). |
| `spon` | true | false | the decomposition point, so the pair's cost splits between the two levers IN ONE TREE. |

`con` is generic-identical to HDRCOST's `early` and `spon` to HDRCOST's
`base`, both drawn on tree `cc5f92f`. Those are cross-tree controls, not the
measurement.

## What must differ in the netlist before any delta is admissible

`SWEEP_PIPE` has 27 functional occurrences in `rtl/attn_block.vhd` and
restructures the phase FSM (`:1456`, `:1487`, `:1508`, `:1529`, `:1886`,
`:2036`) and the K/V capture indices (`:989`, `:997`, `:1000`, `:1001`).
`SCORE_EARLY` adds a hand-over process run outside the phase machine
(`:2234`, `:2261`) plus `se_rdy`/`se_sent` state (`:1947`, `:1948`).
**If `coff` and `con` come back with an identical register count the two arms
are the same netlist and nothing below is a result** -- two arms that were
secretly one netlist have been measured twice in this project in the last two
days.

## The predictions, each under its own name

* **P1 SYNTHESIS.** Both levers synthesise. 0 `^ERROR` in either arm.
  Basis: `SCORE_EARLY=true` synthesised in HDRCOST's `early`; `SWEEP_PIPE=false`
  is the default and LEVERCOST drew it. The PAIR has never been drawn from a
  tree containing `e1d5898`.
* **P2 FLIP-FLOPS, the falsifiable one.** `con - coff` CLB Registers = **+25
  exactly**. DERIVED: LEVERCOST's `SWEEP_PIPE` +23 plus HDRCOST's
  `SCORE_EARLY` +2. **The assumption is additivity across two harnesses**, and
  it is the assumption most likely to be wrong, because the +23 and the +2 were
  measured on different trees with the clock read at different points.
* **P3 LUT.** `con - coff` CLB LUT sites = **+69, ESTIMATE, LOW confidence.**
  Same sum, but LEVERBOARD CORRECTION 1 MEASURED the cross-harness gap on the
  SAME configuration at **167 LUT, 2.6x the +64 addend**, so the sum's own
  uncertainty exceeds one of its terms. A result anywhere in +0 to +200 does
  not surprise me. I am not predicting a sign for the F7/F8 mux columns.
* **P4 THE CONTROLS THAT MUST NOT MOVE.** `DSP48E2`, `Block RAM Tile`,
  `RAMB36E2`, `RAMB18E2`, `URAM288` deltas **all exactly 0** across all three
  arms. Neither lever touches the score array or any memory. If one moves, the
  arms differ in something unrecorded and the LUT/FF deltas are void.
* **P5 THE CROSS-TREE CHECK.** `con` reproduces HDRCOST's `early` exactly
  (86,896 LUT sites, 101,244 CLB Registers) and `spon` reproduces `base`
  (86,891 / 101,242). Basis: the only `rtl/` change from `cc5f92f` to HEAD is
  `e1d5898`'s 29 lines in `rtl/attn_score_q12.vhd`, inside the `HDR_TREE` path,
  which is off at `SCORE_HDR_TREE=0`. **If this misses, the cross-tree
  comparison is void and the same-tree deltas below are the only numbers** --
  which is why all three arms are being drawn rather than two.
* **P6 ROUTED TIMING.** Both arms route with 0 failing endpoints and 0 routing
  errors, and **`con - coff` routed WNS lands BELOW this harness's measured
  ~0.4 ns noise floor, i.e. is not a result.** Basis: 0 of the top 200 routed
  paths lie in the score cone in all three HDRCOST arms, and LEVERCOST found 0
  of 200 in the sweep FSM. **I am predicting that I will not be able to measure
  a timing effect, and the useful output is therefore the pair's ABSOLUTE
  routed WNS on a 13.333 ns clock, not the delta.**
* **P7 MEMORY.** Synthesis reaches the 11G cap in every arm (`at_cap=YES`), so
  no synthesis peak here is an appetite. Place-and-route does NOT reach it and
  those figures ARE appetites, near 6,800 MB. Basis: HDRCOST measured exactly
  this on this box.

## What this cannot answer, stated before the numbers arrive

An OOC `attn_block` draw cannot answer a PLACEMENT question about the card.
A card-top OOC has never once cleared RTL elaboration here (0 of 12 attempts,
two machines). So no number from this track licenses putting these levers on a
card build; it can only remove "no synthesiser has ever drawn this RTL" as an
objection.
