# `gdn_recur_pipe` OOC lane sweep, TRACK BRECUR, 2026-09-20

Raw output of `sim/ooc_gdn_recur_pipe_lanes.tcl`. Analysis and the reason the
sweep exists: `docs/debugging/2026-09-20_the-gdn-recurrence.md`.

One Vivado 2023.2 on the BC-250 under `MemoryHigh=10G`, part
`xcvu33p-fsvh2104-2L-e` (the card's own part), period 3.3 ns, `DIM=128`,
`SLOTS=16`. All four rows are ONE session against ONE tree, which is what makes
the deltas between them like-for-like.

| LANES | DSP | LUT | BRAM | WNS | Fmax |
|---|---|---|---|---|---|
| 4 (shipping, `rtl/llama_top.vhd:816`) | 17 | 9,427 | 3.5 | -0.044 | 299.0 MHz |
| 8 | 33 | 12,549 | 6.5 | -0.044 | 299.0 MHz |
| **16 (proposed, and the ceiling)** | **65** | **17,292** | **12.5** | -0.044 | 299.0 MHz |
| 32 (control only; does not elaborate on the card) | 129 | 27,861 | 24.5 | -0.044 | 299.0 MHz |

## Two things to read before quoting any of this

**The `lut` and `ff` COLUMNS OF THE CSV ARE ZERO AND ARE NOT THE LUT COUNT.**
They are an object census written with `PRIMITIVE_GROUP == LUT` /
`== FLOP_LATCH`, which match NOTHING on this part and return a
`WARNING: [Vivado 12-180]` rather than an error. **Use the `lut_util` column**,
which is `report_utilization`'s CLB LUT row, and which is the only reason the
empty census was noticed at all. The tcl has since been fixed to
`REF_NAME =~ LUT*` / `REF_NAME =~ FD*`; these rows predate that fix, so their
`lut`/`ff` columns stay zero. `sim/ooc_gdn_recur_pipe_dbuf.tcl:31-32` still
carries the broken filter.

**The 32 row is a CONTROL and it half-passed.** Against
`docs/debugging/2026-08-26_gdn-recurrence-column-pipelining.md`'s published
129 DSP / 24,037 LUT: DSP reproduces exactly, LUT does not (27,861, +15.9%).
The published figure comes from a tree of 2026-08-26, before the head-boundary
double buffer landed, and from part `-2-e` at 3.322 ns rather than `-2L-e` at
3.3. Which of the two causes it is has NOT been determined. **Do not quote
24,037 for this unit again without re-deriving it.**
