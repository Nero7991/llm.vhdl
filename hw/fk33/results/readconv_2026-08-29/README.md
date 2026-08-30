# TRACK READCONV artefacts, 2026-08-29

Everything here supports `docs/debugging/2026-08-29_readconv-b-read-side.md`.
Read that first; this file is only the index.

**Pinned tree:** `PINNED_SHA`.
**No hardware was touched.** Synthesis and simulation only.

## What the tags mean

Results live in `/mnt/storage/readconv/out` while a run is in flight and the
kept ones are copied here as `result_<tag>.csv` / `census_<tag>.txt` /
`mem_<tag>.txt` / `util_<tag>.rpt`.

| tag | what was synthesised |
|---|---|
| `rc_l2_base` / `rc_l2_after` | `l2norm_rs`, N=128 LANES=4, pinned RTL vs the changed one. The base reproduces TRACK LUTDIET's `l2_ctrl` |
| `rc_gdn_base` / `rc_gdn_after` | `gdn_block` at its defaults. The base reproduces TRACK WRITEDEC's `wd_gdn_after` |
| `pr_flat_sel128` / `pr_flat_sel4` / `pr_flat_sel1` | `readconv_flat`, 2,048 x 16b store, IDENTICAL write decode, read port 128 / 4 / 1 words wide. The read-port-width experiment |
| `pr_dram_w4` | `readconv_dram`, the same store as LUT-based distributed RAM, streamed 4 words per beat |
| `pr_flat_v_sel1` / `pr_dram_v_w4` | the same pair at `vbuf`'s size, 4,096 x 16b |

## Equivalence and mutation

| file | what it is |
|---|---|
| `rtl/l2norm_rs_ref.vhd` | the PRE-change `rtl/l2norm_rs.vhd`, byte for byte, with only the entity and architecture names changed. The oracle. **Not a shipping unit; do not move it into `rtl/`** |
| `rtl/tb_readconv_l2.vhd` | runs the post-change unit and `l2norm_rs_ref` side by side off identical stimulus. 16 classes, 8 shapes, a hard non-triviality assertion on every trial, and a `done`-cycle equality check. **Deliberately NOT in `sim/`**: a new `sim/tb_*.vhd` is auto-discovered into the shared gate and this bench needs an RTL variant that is not in `rtl/` |
| `rtl/readconv_probe.vhd` | the read-port-width probe. Not a shipping unit |
| `scripts/run_equiv.sh` | one equivalence run at one shape |
| `scripts/run_mutants_l2.sh` | 14 mutations of the new decode and of the hoisted `sat16` |
| `mutants_l2.log` | the verdicts, INCLUDING the five that do not bite |
| `equiv_l2.log` | the eight-shape equivalence sweep |
