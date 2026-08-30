# TRACK DISTRAM artefacts, 2026-08-29

Everything here supports `docs/debugging/2026-08-29_distram-b-staging-buffers.md`.
Read that first; this file is only the index.

**Pinned tree:** `PINNED_SHA`.
**No hardware was touched.** Synthesis and simulation only.

## What the tags mean

Results live in `/mnt/storage/distram/out` while a run is in flight and the
kept ones are copied here as `result_<tag>.csv` / `census_<tag>.txt` /
`mem_<tag>.txt` / `util_<tag>.rpt` / `timing_<tag>.rpt`.

Every run is `sim/ooc_lutdiet_ports.tcl` through `sim/ooc_lutdiet_run.sh`,
`LUTDIET_NOOPT=1 LUTDIET_FLATTEN=none LUTDIET_CENSUS=1`, part
`xcvu33p-fsvh2104-2L-e`, period 5.0 ns, one Vivado at a time.

| tag | what was synthesised |
|---|---|
| `dr_gdn_base` | `gdn_block` at its defaults on the pinned tree. Reproduces TRACK READCONV's `rc_gdn_after` to the digit |
| `dr_gdn_2a` | lever 2a only: `vbuf` as distributed RAM |
| `dr_gdn_2ab` | levers 2a + 2b: `vbuf`, `knb`, `qsb` |
| `dr_gdn_2abc` | levers 2a + 2b + 2c: all five staging buffers |

## Equivalence and mutation

| file | what it is |
|---|---|
| `rtl/gdn_block_ref.vhd` | `rtl/gdn_block.vhd` at the pinned SHA, byte for byte, with ONLY the entity and architecture names changed. The oracle. Verified by un-renaming and diffing against the pinned archive. **Not a shipping unit; do not move it into `rtl/`** |
| `rtl/tb_distram_gdn.vhd` | the SHADOW-DUT bench. `sim/tb_gdn_block.vhd` with a second instance bound to `gdn_block_ref`, driven from the SAME environment, and a comparator that checks all 37 output ports on every rising edge. **Deliberately NOT in `sim/`**: a new `sim/tb_*.vhd` is auto-discovered into the shared gate, and this bench needs an RTL variant that is not in `rtl/` |
| `scripts/run_equiv.sh` | one equivalence run against one RTL directory |
| `scripts/run_mutants.sh` | the mutation table, including the no-op control |
| `equiv_*.log` | the equivalence runs |
| `mutants.log` | the verdicts, INCLUDING the ones that do not bite |
