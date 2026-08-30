# TRACK WRITEDEC artefacts, 2026-08-29

Everything here supports `docs/debugging/2026-08-29_writedec-applied-to-the-real-modules.md`.
Read that first; this file is only the index.

**Pinned tree:** `PINNED_SHA` (`c64f47ba018724a61ea1caa8dd2d49b7160a2df5`).
**No hardware was touched.** Synthesis and simulation only.

## What the tags mean

| tag | what was synthesised |
|---|---|
| `wd_rms_before_n4096` / `wd_rms_after_n4096` | `rmsnorm_rs`, N=4096 LANES=4, pinned RTL vs the changed one |
| `wd_gdn_before` / `wd_gdn_after` | `gdn_block` at its defaults (Qwen3.5-9B, one card) |
| `wd_attn_before` / `wd_attn_after` | `attn_block` at HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8 |
| `wd_attn_rmsonly` | **the same PRE-change `attn_block`, with only the changed `rmsnorm_rs` under it.** This run exists because it was made by mistake -- the changed `attn_block.vhd` had not been copied into the synthesis tree -- and it is kept because it is the only measurement that isolates what the `rmsnorm_rs` fix alone buys inside C. See the traps section of the write-up |
| `wd_seq_*` | D's five sequencer leaves, unchanged by this track, measured here so the composition is summed from this track's own numbers |
| `wd_rmsflat_before` / `wd_rmsflat_after` | `lutdiet_rms_flat`, TRACK LUTDIET's artefact wrapper that gives `rmsnorm_rs` the flat vector storage `rtl/llama_top.vhd`'s D-vec norm adapter supplies. This is D's norm AS THE TOP LEVEL INSTANTIATES IT, which is LUTDIET's correction to COMPOSE |

Per tag: `result_<tag>.csv` (one row, all columns), `census_<tag>.txt` (LUT
primitives grouped by the RTL signal root Vivado named them after),
`mem_<tag>.txt` (peak RSS over the full descendant tree),
`synthutil_*` / `util_*` / `timing_*` reports.

## Equivalence and mutation

| file | what it is |
|---|---|
| `rtl/rmsnorm_rs_ref.vhd` | the PRE-change `rtl/rmsnorm_rs.vhd`, byte for byte, with only the entity and architecture names changed. The oracle. **Not a shipping unit; do not move it into `rtl/`** |
| `rtl/tb_writedec_rms.vhd` | runs the post-change unit and `rmsnorm_rs_ref` side by side off identical stimulus. 11 classes, six shapes, hard non-triviality assertion on every trial, and a `done`-cycle equality check. **Deliberately NOT in `sim/`**, because a new `sim/tb_*.vhd` is auto-discovered into the shared gate and this bench needs an RTL variant that is not in `rtl/` |
| `rtl/tb_survey.vhd` | the same bench with the non-triviality assertion demoted to a note, used ONLY to find input classes that are off the all-zeros rail. It is not evidence of anything |
| `run_final_n*.log` | the equivalence runs quoted in the write-up |
| `scripts/run_mutants_rms.sh` | 7 mutations of `rmsnorm_rs`'s new decode |
| `scripts/run_mutants_gdn.sh` | 5 mutations of `gdn_block`'s |
| `scripts/run_mutants_attn.sh` | 5 mutations of `attn_block`'s |
| `scripts/vcdcmp.py` | compares two GHDL VCD dumps SIGNAL BY SIGNAL BY NAME. A plain `diff` of two VCDs is not an equivalence test: adding one signal renumbers every identifier code after it |
| `mutants_rms.log`, `mutants_gdn.log`, `mutants_attn.log` | the verdicts, including the mutations that do NOT bite |

## Three things that will bite the next person

1. **A per-word generate whose slice bounds contain a for-loop variable creates
   a driver over the WHOLE signal in every generated process**, so all of them
   resolve against each other and the signal simulates as `X`. It synthesises
   cleanly. Only simulation catches it. Every slice target in the landed RTL is
   static in the generate index alone.
2. **A teeth-check that scores a mutant CAUGHT because the compiler failed is
   worse than no teeth-check.** `run_mutants_rms.sh`'s first version did exactly
   that on all seven mutants. Analysis failure is now VOID, never CAUGHT.
3. **`diff <(a) <(b) && echo IDENTICAL` is true when both sides are empty.** It
   reported IDENTICAL over two VCDs that did not exist. Every comparison here
   refuses to score unless both inputs exist and are non-empty.
