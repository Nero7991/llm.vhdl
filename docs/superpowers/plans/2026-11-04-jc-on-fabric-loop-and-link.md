# JC On-Fabric Token Loop and Die-to-Die Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run decode on the Jungle Cat with the host only starting and polling: a `tok_loop` drives each die's seam as a second master, rows come from an HBM gather, a host buffer or a die-to-die Aurora 64B/66B link, and every unit is checked bit-exact against the host code it replaces.

**Architecture:** `tok_loop` (control slave + seam master FSM) sits behind an exclusive ownership mux in front of the unchanged `fk33_seam`. A pluggable row source feeds the FSM: `embed_gather` (third master on `hbm_sc`), a host-written row buffer, or `jc_link_rx`. Die A frames its residual R_X with `jc_link_tx` into an Aurora TX/RX-simplex core on GTYE4_CHANNEL_X0Y0; die B deframes it. Same bitstream on both dies; the role is a register. The host relays the generated token back to die A (phase 1).

**Tech Stack:** VHDL-2008 (GHDL 6 mcode gate via `sim/regress.sh`), Vivado 2023.2 (Aurora 64B66B v12.0 IP, xsim for UNISIM/IP sims, the existing `hw/jc/card` build), C (server/, jc_sim_broker), Python 3 (generators, host tool, pytest).

**Spec:** `docs/superpowers/specs/2026-11-04-jc-on-fabric-loop-and-link-design.md` (read it with this plan; section numbers below are the spec's).

## Pre-flight amendments (2026-11-05)

Applied from `.superpowers/sdd/2026-11-04-jc-on-fabric-loop-and-link/preflight.md` (18 findings)
before Task 1. One line each: finding, task touched, what changed.

1. T7 Step 5: `-tclargs` used `1 0` instead of the literal word `bd_only`, so the "subagent-safe"
   step started a full card build. Now passes `bd_only` so `build_card.tcl` stops after the BD.
2. T7 Step 4: `jc_link_timing.tcl` and the build hook used unescaped `[0]`/`[*]` inside
   double-quoted Tcl patterns (command substitution, then a glob character class). Patterns now
   use `*_reg*` (no brackets); added an OOC-synth teeth check of `jc_tok_top` before any card build.
3. T5 Step 4/T7 Step 2: no MMCM LOC or `CLOCK_DEDICATED_ROUTE BACKBONE` for the GTG MMCM. Added
   both to `render_xdc` (f), plus a generator test.
4. T4 Step 3/T6: `jc_link_tx` dropped a RESEND that arrived while busy. Now latches it and serves
   it at `T_IDLE`; added bench case C11 and mutant L6; noted the dependency in T6's P3 case.
5. T1 Step 1 bench: `refused_n = 2` was read one delta before the counter process updated it.
   Added a `wait until rising_edge(clk)` before the check.
6. T5 Step 7: `run_aurora_sim.sh`, and the Step 3/Step 7 generated `run_ip.sh`/`run_sims.sh`,
   hardcoded the main checkout's path, not the worktree's. Now derive the repo root at runtime.
7. T3 Step 1 bench: `get_row`'s corrupted-magic case read `err`/`err_code` one delta too early.
   Added a `wait until rising_edge(clk)` after `req <= '0'` inside `get_row`.
8. Duplicate of 5 (same bench, same fix): `refused_n` check.
9. T6 Step 5: `tok_loop_pair.json` mutant deps omitted `rtl/util_pkg.vhd`, which
   `rtl/async_fifo.vhd` uses. Inserted before it; mutation run no longer DID_NOT_ANALYZE.
10. T7 Step 7: `jc_loop.py`'s `Broker.call` retried every op, including non-idempotent writes, on
    WindowUnknown. Now retries only `rd32`; `setup`/`send_row` re-seek the ADDR register and
    resend the whole buffer; NEXT_TOKEN/CTRL/OUT_ACK fail hard with `JCLOOP_FAIL`. Added a test.
11. Global Constraints / T7 Step 10 / D13: the constraint line said clk_core 200 MHz while the
    card build (and D13's own cycle math) uses the measured 125 MHz. Restated the constraint;
    corrected D13's trailing 200 MHz remark and the jc_link_tx header's microsecond estimate.
12. T2 Step 1: "16 passed" undercounted `test_run_prompt_jc.py`'s parametrized cases. Restated as
    "all pass (16 functions, about 30 cases)".
13. T6 FSM: `F_TXW`/`F_TXB2` had no ABORT exit while waiting on `tx_busy`, so die A was
    unabortable while its TX lane was down. Added `elsif abort_l = '1' then stop(R_ABORT);`.
14. T2 `tok_loop_regs`: LINK_CREDIT was not cleared at START, so a rerun without the host
    rewriting it could let A outrun B. Cleared alongside `out_ack`/`next_tok_v`.
15. T7 Step 7 fault mode: the `FAULT_PAUSED=%d ` prefix broke `main()`'s
    `line.startswith("JCLOOP_DONE")` exit-status check. Changed to `"JCLOOP_DONE" in line`.
16. Spec deviations: added D18 documenting that the gather's dequant scale takes the whole row's
    max (matching `pl_embed_mv4i`), not spec 1.3's "block max" (RTL and the tree win).
17. Stale cites: `fk33_seam.vhd:1094-1098` -> `:1101-1105` (T2); `jc_sim_broker.c` anchors
    `:72` -> `:80`, `:126-262` -> `:131-262`, `:284-311` -> `:277-311` (T2).
18. T7 Step 1: the refclk-pick/readback logic was written inline in T5 Step 3 and only shared out
    in T7, forcing an extra IP regeneration. Moved `jc_aurora_refclk`/`jc_aurora_check` into T5's
    `aurora_cfg.tcl` from the start; T7 Step 1 now just confirms they are already shared.

## Global Constraints

- **Subagents get NO hardware access.** No `xsdb`, `hw_server`, `vivado ... program`, `sqrl_bridge`, XVC, CoE (`tools/jc/coe.py`, `coe_load.py`, `coe_soak.py`), no `tools/jc/jc_broker.py serve` against a BMC, no `hw/jc/host/jc_ctxtest.sh` or `jc_bc_lane.sh` real runs, nothing under `/dev/xdma*`, nothing that opens the Jungle Cat JTAG. Task 8 is main-session only. Put this line in every brief.
- **One Vivado per box.** Gate on presence by `/proc/PID/exe` (the CLAUDE.md snippet), never `pgrep -f`/`pkill -f`. Two on one box is what does damage.
- **Card build budget:** a JC card build is the FK33_CARD shape, ~47 GB including swap; run it alone through `hw/jc/card/run_card.sh` (MemoryHigh=24G, 30 GiB swap guard, `hw/jc/card/run_card.sh:151-152`). Stopping `llama-server` is Oren's call. State resident / peak / left before dispatch.
- **Nothing expensive under /tmp** (including the session scratchpad). Bench and generator scratch: `~/regress_scratch/<run>` or `/mnt/storage/fk33_builds/scratch/<run>`. Build roots: `/mnt/storage/fk33_builds/<tag>/`.
- **HBM is AXI3:** ARLEN <= 15 (16 beats), 32-byte beats, ARSIZE `101`, ARBURST `01`, no burst crosses 4 KB (`sim/jc_axi3_mem.vhd` checks all four).
- **Same bitstream on both dies** (`sqrl_bridge` loads the first file of a comma list on both, `docs/boards/jungle-cat/README.md:102,118`). TX/RX role and A/B half are runtime registers, never generics.
- **Part `xcvu35p-fsvh2104-2L-e`.** `clk_core` defaults to 200 MHz (`hw/jc/card/README.md`,
  `build_card.tcl:20-24`), but this plan's card build (Task 7 Step 10) runs at the jccard10-measured
  125 MHz via `--clk-mhz 125`, and every timeout and cycle-count derived here (D13) uses 125 MHz,
  not the 200 MHz default (finding 11, 2026-11-05).
- **Link facts (MEASURED 2026-11-04):** die 0 GTYE4_CHANNEL_X0Y0 TX -> die 1 X0Y0 RX, TX polarity 0, RX polarity 0, 10.3125 Gb/s, 156.25 MHz refclk from an MMCM on GTGREFCLK0 (MMCME4 DIVCLK 4, MULT 25.000, CLKOUT0 8.000 from the 200 MHz BC26 sysclk; `/mnt/storage/fk33_builds/jc_ibert/G/SUMMARY.md`). Fallback line rate 1.25 Gb/s.
- **GHDL gate:** `REGRESS_SCRATCH=~/regress_scratch/<run> bash sim/regress.sh --only <substr> --keep`; `--only` is a SUBSTRING; read `OVERALL PASS n` and require n >= 1 (`PASS 0` means nothing ran). A new `sim/tb_*.vhd` is a gate row the moment it exists: commit its vectors in the same commit. UNISIM/IP benches live under `hw/jc/link/sim/`, never `sim/tb_*`.
- **Bench verdict lines:** every GHDL bench ends with `report "PASS: <tb> checks=<n>" severity note;` then `std.env.finish;`, or `report "FAIL: <tb> errors=<n>" severity failure;`. Checks are counted in VARIABLES. No other report line may contain the words FAIL, MISMATCH or FAILED unless it is a failure (`sim/regress.sh:2801`).
- **Generated files:** check line 2 of any file before editing. `hw/jc/card/jc_card_bd.tcl`, `jc_card.xdc`, `jc_card_top.vhd` are GENERATED by `hw/jc/card/gen_jc_card.py`: edit the generator, regenerate with `python3 hw/jc/card/gen_jc_card.py`, confirm `python3 hw/jc/card/gen_jc_card.py --check` prints `JCCARD_CHECK: PASS`. `sim/tok_loop_vec.txt` and `sim/embed_gather_k*_vec.txt` are generated by the Task 2/3 generators.
- **Loader and ctl files are used, never edited:** `rtl/jc_loader_pkg.vhd` (its `crc32_word` is reused), `rtl/async_fifo.vhd`.
- **Git:** `git add <explicit paths>` then `git commit -m ... -- <same paths>` for files this track owns exclusively; never `git add -A`/`git add .`; no Co-Authored-By line; no emojis; no em-dashes.
- **Verification discipline:** every value check compares against an independent implementation (run_prompt over jc_sim_broker, `pl_embed_mv4i`, zlib); every new check gets a mutant in `sim/mutants/<unit>.json` that must be KILLED, plus the unmutated control Z0 that must PASS.

## Review Focus

1. **Config registers written mid-run** (PROMPT_LEN, MAX_NEW, ROLE, ROW_SRC): a reasonable person expects the running sequence to keep the values latched at START. Pinned by Task 6 case F12.
2. **START while running:** expected to be ignored (no second SEQ_RESET, no position jump). Pinned by Task 6 case F13.
3. **The host never drains OUT (OUT_COUNT - OUT_ACK reaches OUT_DEPTH):** expected stall with OUT_FULL, no id lost, resume on OUT_ACK. Pinned by Task 6 case F11 (OUT_DEPTH 4).
4. **ABORT while waiting** on NEED_ROW, NEED_TOKEN, a paused link or OUT_FULL: expected a prompt stop with reason ABORT and the seam released so host accesses work. Pinned by Task 6 cases F4/F5.
5. **A second run after a stopped run** without reconfiguration: expected identical ids for the identical prompt (SEQ_RESET re-zeros the seam position and the sim history). Pinned by Task 2 (cases run back-to-back on one seam model) and Task 6 case F14.

## Spec deviations (the RTL and the tree win)

- **D1. The JC card generator is 27B-only.** `hw/jc/card/gen_jc_card.py:769-771` refuses any model but QWEN38_27B, so "9B on a single die" (spec Goal, 1.4) is not buildable as a card here. This plan validates `embed_gather` in GHDL at the 9B geometry (K 4096) AND the 27B geometry (K 5120), integrates it into the 27B card behind `HAS_GATHER`, and runs silicon on the 27B two-die split. The 9B JC card variant and the packer change of spec 1.4 are OPEN (not in this plan).
- **D2. The frame header carries the exponent and is 8 words.** Die B needs X_EXP: the host hop reads `XEXP_OUT` after R_X (`server/pl_backend.c:1523-1543`) and pushes it with the row (`pl_decode_row`, `pl_backend.c:1560-1569`). Header = magic, seq, pos, nwords, xexp, 3 zero words (8 words keeps the payload beat-aligned for 1, 2 and 4 lanes).
- **D3. Flow control for prefill.** Die A's prompt positions do not depend on die B (spec section 2 step 1), so A can out-run B, overwrite the one frame it keeps for RESEND, and leave B waiting for a frame nobody holds. Added: die A reads position p's R_X into its TX buffer only once `LINK_CREDIT >= p`, where the host relays die B's `LINK_CONSUMED` (frames B has popped) into die A's `LINK_CREDIT` (phase-1 host relay, like NEXT_TOKEN). The frame A holds is then always the one B waits for. A's GO for p still overlaps B's GO for p-1 (B pops a frame at the start of its position). RX keeps `RXDEPTH = 2` slots of slack. STATUS bit 18 LINK_WAIT shows die B waiting for a frame.
- **D4. Role is a host-written ROLE register only.** No DNA compare in RTL: `jc_dies.json` is outside the repo (`docs/WORKLOG.md` "Die record outside the repo (--dies)"), and baking die identity into the bitstream contradicts one-bitstream. `rtl/jc_dna_reader.vhd` exists but is not used here.
- **D5. RX polarity is not a runtime control of the Aurora 64B66B core.** The IP exposes `gt_txpolarity` (input) and `rxpolarity_out`/`rx_polarity_out` (outputs, automatic RX polarity) in `/tools/Xilinx/2023.2/Vivado/2023.2/data/ip/xilinx/aurora_64b66b_v12_0/component.xml`. The lane table carries TX polarity as a runtime control (LINK_CTRL bit 2 XOR the table) and RX polarity as an expectation only. Silicon step 4 flips die A's TX polarity instead of die B's RX polarity.
- **D6. The seam never answers SLVERR/DECERR:** `rtl/fk33_seam.vhd:763` and `:771` tie BRESP/RRESP to "00". SEAM_ERR can come only from the mux, the interconnect, or the loop's own per-transaction timeout (added, `TMO_SEAM` 65536 cycles, the ctl executor's default `rtl/jc_ctl_core.vhd:67`).
- **D7. The transaction-trace oracle compares WRITES only.** STATUS poll counts depend on timing, and the host also reads LOGIT_EXP (`pl_backend.c:1410-1411`), which the loop has no use for. Prefill positions before the last read no ARGMAX on the host (`pl_prefill` passes NULL except on the last chunk, `pl_backend.c:1588-1591`); the loop matches that.
- **D8. run_prompt has one stop id** (`server/tests/run_prompt.c:385,422`). STOP_ID[0] carries it; STOP_ID[1..7] reset to 0xFFFFFFFF (never an id, n_vocab 248,320). STOP_ID[7] is exercised by Task 6 case F15.
- **D9. MAXPOS:** at the context limit `pl_decode` returns -1 (`pl_backend.c:1604`) and run_prompt fails; the loop stops cleanly with reason MAXPOS after position KV_MAXPOS-1. Vectors avoid the limit; Task 6 case F10 tests it against the first ids of a reference run.
- **D10. OUT_FIFO and the prompt buffer are fixed-address windows** (OUT_ADDR/OUT_DATA, PROMPT_ADDR/PROMPT_DATA, auto-increment), read non-destructively with an OUT_ACK count. `server/fk33_transport_jc.c:21-32` coalesces only one fixed offset per die and `server/tests/jc_sim_broker.c:165-166` accepts `wrn` only with `"fix":true`; a destructive pop would lose ids on the broker's WindowUnknown retries (`pl_backend.c:84-93`).
- **D11. The pin-refclk select is a generator input, not a VHDL generic.** The Aurora core has no GTGREFCLK port (as IBERT, `G/SUMMARY.md` "What was changed"), so GTGREFCLK0 is wired by a netlist ECO before `opt_design`. `JC_LINK_REFCLK=gtg|pin` (stamped by `gen_jc_card.py`) selects ECO or pin. Task 5 Step 3 may find the shared-logic RTL exposes the ports; then it becomes a generic and the ECO is dropped.
- **D12. Gather time:** the gather dequantizes one element per cycle: ~4096 + 2 x 128 beats + header, about 22 us at 200 MHz for the 9B (ESTIMATE), not the spec's ~10 us.
- **D13. Engine timeout default** = 4 x 0.36 s x 125 MHz = 180,000,000 cycles (DERIVED from spec section 2's MEASURED 0.36 s at the card's standing 125 MHz `clk_core`, the jccard10 configuration; see the Global Constraints amendment, finding 11). The register is a cycle count, so it carries over unchanged if a future build moves to a different `clk_core`; only the real-time duration would change.
- **D14. The xsim test is this plan's own bench around the IP, not the IP's example simulation.** Spec section 4 names "Aurora example simulation"; the example design checks the IP's own frame generator, not `jc_link_tx`/`jc_link_rx`. `hw/jc/link/sim/tb_jc_aurora_link.vhd` runs two cores of the generated IP (with `C_EXAMPLE_SIMULATION` true) carrying real frames, at NLANES 1 and 4, with the lane-map mutant.
- **D15. Both directions are one core.** Spec 1b.6 "Both Aurora directions are instantiated, one enabled at runtime" is met by `dataflow_config = TX/RX_Simplex` (one core, independent TX and RX simplex channels on the same GT lanes, `component.xml` choice list line 53648); the role picks which half `tok_loop` uses. Two separate cores cannot share GTYE4_CHANNEL_X0Y0.
- **D16. llama.cpp agreement is recorded, not gated, in silicon step 3.** Spec section 4 step 3 asks loop ids = run_prompt ids = llama.cpp. The card's host-path argmax already differs from llama.cpp's on the 23-id prompt (jccard10: 1206 vs 7732, `hw/jc/card/results/jc27b_jccard10_2026-11-04/README.md`), independent of the loop. Task 8 gates loop = host path (bit-exact ids, the oracle for what the loop changed) and records the llama.cpp id beside it.
- **D17. Hop transparency is checked on die B's output residual.** Spec section 4 step 2 asks that die B's X window after the hop be bit-identical to die A's R_X. On the 27B card windows 2 and 3 are the same region (`hw/jc/card/jccard_const_allow.tcl`: `card/hw_reg` and `card/hr_reg` tied to R_X), so B's input is overwritten by its GO. Task 8 Step 6 compares both dies' `--dump-xout` residuals between the host hop and the loop hop for the same prefix; with a deterministic engine equal outputs imply equal inputs (DERIVED).
- **D18. The gather's dequant scale takes the whole row's amax, not a per-block max.** Spec 1.3 says embed_gather "takes the block max"; the RTL (and the oracle it is checked against, `pl_embed_mv4i`, `server/embed_mv4i.c:497-501`) take one amax over the whole row. The RTL and the tree win: `embed_gather.vhd` matches `pl_embed_mv4i` as this plan validates it, not spec 1.3's wording (finding 16, 2026-11-05).

## Not grounded in the tree (decided at execution, with a stop condition)

- No committed 27B llama.cpp reference ids for the DC-DC prompt (only the 9B `hw/fk33/results/goal_dcdc_2026-09-17/reference_tokens.txt`). Task 8 Step 3 makes one with `docs/superpowers/plans/2026-10-09-jc-silicon-runbook.md` section 4.2.
- Aurora IP behaviours not readable from `component.xml`: the dynamic choice strings of `C_REFCLK_SOURCE`/`C_START_LANE`/`C_GT_LOC_*`, the generated XDC's GT LOC format and the `C_GT_LOC_<row+1> = <lane+1>` convention (both checked against the lane table by Task 5 Step 2's LOC readback), whether the core drives QPLL0REFCLKSEL from constants (Task 5 Step 5), whether `gt_txpolarity` is reachable as a BD pin, and whether TX/RX-simplex RX comes up after its TX is already up. Task 5 records each as MEASURED and stops on the listed conditions.
- `jc_dies.json` (spec 1b.6): not in the tree.
- The HBM address of a 27B embedding image for the gather on silicon: no manifest places one, so Task 8 runs host rows (`PackedTensor.row_bfp`, bit-equal to `pl_embed_mv4i` per Task 2's generator check) and the gather is validated in GHDL only.
- The BD port names the Aurora's GT interfaces get once made external (`gt_tx_txp` ...): Task 7 Step 5 refuses the BD if they differ and says how to fix the table.
- The bitstream file name in `run_card.sh`'s results directory: `build_card.tcl:518` writes `jc_card.bit`; Task 8 assumes the harvest keeps the name.

---

## File structure

| File | Task | Responsibility |
|---|---|---|
| `rtl/jc_seam_mux.vhd` | 1 | exclusive 2:1 owner switch in front of the seam's AXI-Lite slave |
| `sim/axil_bfm_pkg.vhd` | 1 | AXI-Lite master procedures for benches |
| `sim/mutate_rows.py` | 1 | generic anchored-mutant runner (`sim/mutants/<unit>.json`) |
| `sim/tb_jc_seam_mux.vhd`, `sim/mutants/jc_seam_mux.json` | 1 | mux bench and mutants |
| `rtl/tok_loop_pkg.vhd` | 2 | offsets (seam and loop), reasons, cfg/stat/lnk records |
| `rtl/tok_loop_regs.vhd` | 2 | control slave: registers, prompt RAM, OUT ring, host row RAM |
| `rtl/tok_loop_axm.vhd` | 2 | one-at-a-time AXI-Lite master with timeout |
| `rtl/tok_loop_fsm.vhd` | 2 | the host sequence replayed on the seam |
| `sim/seam_beh_model.vhd` | 2 | behavioural seam = `server/fk33_sim.c` arithmetic, write events, faults |
| `sim/row_synth_src.vhd` | 2 | row source = `pl_embed_synthetic` |
| `sim/tok_loop_tb_pkg.vhd`, `sim/seam_trace_chk.vhd` | 2 | vector loader, FNV, trace checker |
| `sim/tb_tok_loop.vhd`, `sim/tok_loop_vec.txt`, `sim/mutants/tok_loop.json` | 2 | loop bench, vectors, mutants |
| `tools/jc/tok_loop_model.py`, `tools/jc/gen_tok_loop_vec.py`, `tools/jc/test_tok_loop_model.py` | 2 | Python model of run_prompt's writes, generator, its tests |
| `server/tests/jc_sim_broker.c` (modify) | 2, 7 | `--trace` (2); `--loop` C model hook (7) |
| `rtl/embed_gather.vhd` | 3 | HBM row gather + dequant + BFP pack, = `pl_embed_mv4i` |
| `tools/jc/gen_embed_gather_vec.py` | 3 | synthetic .mv4i + `embed_dump` oracle -> vectors |
| `sim/embed_gather_tc.vhd`, `sim/tb_embed_gather.vhd`, `sim/tb_embed_gather_27b.vhd`, `sim/embed_gather_k4096_vec.txt`, `sim/embed_gather_k5120_vec.txt`, `sim/mutants/embed_gather.json` | 3 | gather test body, two gate rows, vectors, mutants |
| `rtl/jc_link_pkg.vhd`, `rtl/jc_link_tx.vhd`, `rtl/jc_link_rx.vhd` | 4 | frame format + CRC, framer with resend/cap, deframer with checks/counters |
| `sim/jc_link_chan_model.vhd`, `sim/tb_jc_link.vhd`, `sim/mutants/jc_link.json` | 4 | AXIS channel model with faults, bench, mutants |
| `hw/jc/link/aurora_ties.py`, `hw/jc/link/gen_aurora_wrap.py`, `hw/jc/link/test_gen_aurora_wrap.py`, `hw/jc/link/gen_aurora_ip.tcl`, `hw/jc/link/aurora_cfg.tcl`, `hw/jc/link/eco_aurora_gtg.tcl`, `hw/jc/link/eco_check.tcl`, `hw/jc/link/rtl/jc_gtg_clk.vhd`, `hw/jc/link/rtl/jc_aurora_wrap_l{1,4}.vhd` (generated), `hw/jc/link/sim/tb_jc_aurora_link.vhd`, `hw/jc/link/run_aurora_sim.sh`, `hw/jc/link/README.md` | 5 | Aurora config and tie table, GTG refclk MMCM + ECO, xsim test |
| `rtl/tok_loop.vhd`, `rtl/jc_tok_top.vhd` | 6 | loop composition with row-source mux; card module-reference top (gather, link, CDC) |
| `sim/tb_tok_loop_top.vhd`, `sim/tb_tok_loop_pair.vhd`, `sim/tb_tok_loop_faults.vhd`, `sim/mutants/tok_loop_top.json`, `sim/mutants/tok_loop_pair.json`, `sim/mutants/tok_loop_faults.json` | 6 | single-die (host row, gather), two-die, fault benches and their mutants |
| `hw/jc/card/gen_jc_card.py`, `hw/jc/card/test_gen_jc_card.py`, `hw/jc/card/build_card.tcl`, `hw/jc/card/jccard_const_allow.tcl` (modify); generated outputs | 7 | BD: `tok`, `gtgclk`, `aur`, hbm_sc NUM_SI 3, address map, GT ports, ECO hook |
| `server/tests/jc_sim_loop.c`, `server/tests/jc_sim_loop.h`, `server/Makefile` (modify) | 7 | C model of tok_loop inside the fake broker |
| `hw/jc/link/jc_link_timing.tcl` | 7 | CDC bounds and audit for `jc_tok_top` |
| `tools/jc/jc_loop.py`, `tools/jc/test_jc_loop.py`, `hw/jc/host/jc_ctxtest.sh`, `hw/jc/host/test_jc_ctxtest.py` (modify) | 7, 8 | host tool: start/poll/drain/relay, dumps, fault; tests; loop-mode context test |
| `tools/jc/jc_link_soak.py` | 8 | 10-minute frame soak with closed accounting |
| `docs/debugging/<date>_jc-loop-silicon.md` | 8 | silicon record (main session) |

Tasks run in this order; Tasks 1, 3, 4 and 5 are independent of each other; 2 needs 1's BFM; 6 needs 1-4; 7 needs 5 and 6; 8 needs 7.

---
### Task 1: Seam ownership mux

**Files:**
- Create: `rtl/jc_seam_mux.vhd`, `sim/axil_bfm_pkg.vhd`, `sim/mutate_rows.py`, `sim/tb_jc_seam_mux.vhd`, `sim/mutants/jc_seam_mux.json`

**Interfaces:**
- Consumes: the seam's AXI-Lite slave shape, 12-bit address, no AxPROT, `s_axi_wstrb` present (`rtl/fk33_seam.vhd:229-247`); `sim/axil_slave_model.vhd:19-56` as the stand-in seam (log, SLVERR_ADDR, `mute_r`, random stalls, protocol `errors`).
- Produces: entity `jc_seam_mux` (generic `AW`; ports `loop_own`, `owner`, `host_refused`, `s_h_*`, `s_l_*`, `m_*` as below); package `axil_bfm_pkg` (`axil_m2s_t`, `axil_s2m_t`, `AXIL_M2S_IDLE`, `axil_wr`, `axil_rd`, `u32`, `s32`); runner `python3 sim/mutate_rows.py sim/mutants/<unit>.json` printing `MUTROW <tag> <expect> <got>` per row and a final `^MUTANTS_OK <n>` or `^MUTANTS_FAIL`.

Behaviour contract: one transaction at a time, store-and-forward. In IDLE the owner's write (both AW and W valid) is taken first, then the owner's read, then the other side's write, then its read. A non-owner transaction completes locally with SLVERR ("10"), RDATA 0, never reaches `m_*`, and pulses `host_refused` when it was the host's. `own` follows `loop_own` only in IDLE, so ownership never changes with a transaction in flight; `owner` reports `own`.

- [ ] **Step 1: Write the BFM package**

`sim/axil_bfm_pkg.vhd`:

```vhdl
-- sim/axil_bfm_pkg.vhd -- AXI4-Lite master procedures for GHDL benches (plan
-- 2026-11-04-jc-on-fabric-loop-and-link, Task 1). VALID is raised without waiting
-- for READY, as AXI requires; a slave that never answers fails the bench.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package axil_bfm_pkg is
  type axil_m2s_t is record
    awaddr  : std_logic_vector(31 downto 0);
    awvalid : std_logic;
    wdata   : std_logic_vector(31 downto 0);
    wstrb   : std_logic_vector(3 downto 0);
    wvalid  : std_logic;
    bready  : std_logic;
    araddr  : std_logic_vector(31 downto 0);
    arvalid : std_logic;
    rready  : std_logic;
  end record;
  type axil_s2m_t is record
    awready : std_logic;
    wready  : std_logic;
    bresp   : std_logic_vector(1 downto 0);
    bvalid  : std_logic;
    arready : std_logic;
    rdata   : std_logic_vector(31 downto 0);
    rresp   : std_logic_vector(1 downto 0);
    rvalid  : std_logic;
  end record;
  constant AXIL_M2S_IDLE : axil_m2s_t :=
    (awaddr => (others => '0'), awvalid => '0', wdata => (others => '0'), wstrb => "1111",
     wvalid => '0', bready => '0', araddr => (others => '0'), arvalid => '0', rready => '0');
  constant AXIL_TMO : natural := 200000;

  function u32(n : natural) return std_logic_vector;
  function s32(n : integer) return std_logic_vector;
  procedure axil_wr(signal clk : in std_logic; signal m : out axil_m2s_t;
                    signal s : in axil_s2m_t; addr : in natural;
                    data : in std_logic_vector(31 downto 0);
                    resp : out std_logic_vector(1 downto 0); w_delay : in natural := 0);
  procedure axil_rd(signal clk : in std_logic; signal m : out axil_m2s_t;
                    signal s : in axil_s2m_t; addr : in natural;
                    data : out std_logic_vector(31 downto 0);
                    resp : out std_logic_vector(1 downto 0));
end package;

package body axil_bfm_pkg is
  function u32(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n, 32));
  end function;

  function s32(n : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(n, 32));
  end function;

  procedure axil_wr(signal clk : in std_logic; signal m : out axil_m2s_t;
                    signal s : in axil_s2m_t; addr : in natural;
                    data : in std_logic_vector(31 downto 0);
                    resp : out std_logic_vector(1 downto 0); w_delay : in natural := 0) is
    variable v : axil_m2s_t := AXIL_M2S_IDLE;
    variable aw_done, w_done : boolean := false;
    variable n : natural := 0;
  begin
    v.awaddr := u32(addr); v.awvalid := '1';
    v.wdata := data; v.wstrb := "1111";
    if w_delay = 0 then v.wvalid := '1'; end if;
    v.bready := '1';
    m <= v;
    loop
      wait until rising_edge(clk);
      if v.awvalid = '1' and s.awready = '1' then aw_done := true; v.awvalid := '0'; end if;
      if v.wvalid = '1' and s.wready = '1' then w_done := true; v.wvalid := '0'; end if;
      if s.bvalid = '1' then
        resp := s.bresp;
        assert aw_done and w_done report "axil_wr: B before AW and W" severity error;
        exit;
      end if;
      n := n + 1;
      if not w_done and v.wvalid = '0' and n >= w_delay then v.wvalid := '1'; end if;
      assert n < AXIL_TMO report "axil_wr: no response at " & integer'image(addr) severity failure;
      m <= v;
    end loop;
    m <= AXIL_M2S_IDLE;
  end procedure;

  procedure axil_rd(signal clk : in std_logic; signal m : out axil_m2s_t;
                    signal s : in axil_s2m_t; addr : in natural;
                    data : out std_logic_vector(31 downto 0);
                    resp : out std_logic_vector(1 downto 0)) is
    variable v : axil_m2s_t := AXIL_M2S_IDLE;
    variable n : natural := 0;
  begin
    v.araddr := u32(addr); v.arvalid := '1'; v.rready := '1';
    m <= v;
    loop
      wait until rising_edge(clk);
      if v.arvalid = '1' and s.arready = '1' then v.arvalid := '0'; end if;
      if s.rvalid = '1' then
        data := s.rdata; resp := s.rresp;
        exit;
      end if;
      n := n + 1;
      assert n < AXIL_TMO report "axil_rd: no response at " & integer'image(addr) severity failure;
      m <= v;
    end loop;
    m <= AXIL_M2S_IDLE;
  end procedure;
end package body;
```

- [ ] **Step 2: Write the failing bench**

`sim/tb_jc_seam_mux.vhd`:

```vhdl
-- sim/tb_jc_seam_mux.vhd -- rtl/jc_seam_mux.vhd against sim/axil_slave_model.vhd as the
-- seam (plan 2026-11-04 Task 1). Oracle: the model's own transaction log (what reached
-- the seam) and the response each source saw.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axil_bfm_pkg.all;

entity tb_jc_seam_mux is
end entity;

architecture sim of tb_jc_seam_mux is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal hm, lm : axil_m2s_t := AXIL_M2S_IDLE;
  signal hs, ls : axil_s2m_t;
  signal loop_own, owner, host_refused : std_logic := '0';
  signal m_awaddr, m_araddr : std_logic_vector(11 downto 0);
  signal m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready : std_logic;
  signal m_arvalid, m_arready, m_rvalid, m_rready : std_logic;
  signal m_wdata, m_rdata : std_logic_vector(31 downto 0);
  signal m_wstrb : std_logic_vector(3 downto 0);
  signal m_bresp, m_rresp : std_logic_vector(1 downto 0);
  signal sl_aw, sl_ar : std_logic_vector(31 downto 0);
  signal log_count, log_kind, model_errs : natural := 0;
  signal log_idx : natural := 0;
  signal log_addr, log_data, reg_data : std_logic_vector(31 downto 0);
  signal log_resp : std_logic_vector(1 downto 0);
  signal mute_r : std_logic := '0';
  signal refused_n : natural := 0;
  signal phase : natural := 0;
  signal l_done : natural := 0;
  signal l_errs, l_checks : natural := 0;
begin
  clk <= not clk after 2.5 ns;

  dut : entity work.jc_seam_mux
    generic map(AW => 12)
    port map(clk => clk, rst => rst, loop_own => loop_own, owner => owner,
             host_refused => host_refused,
             s_h_awaddr => hm.awaddr(11 downto 0), s_h_awvalid => hm.awvalid,
             s_h_awready => hs.awready, s_h_wdata => hm.wdata, s_h_wstrb => hm.wstrb,
             s_h_wvalid => hm.wvalid, s_h_wready => hs.wready, s_h_bresp => hs.bresp,
             s_h_bvalid => hs.bvalid, s_h_bready => hm.bready,
             s_h_araddr => hm.araddr(11 downto 0), s_h_arvalid => hm.arvalid,
             s_h_arready => hs.arready, s_h_rdata => hs.rdata, s_h_rresp => hs.rresp,
             s_h_rvalid => hs.rvalid, s_h_rready => hm.rready,
             s_l_awaddr => lm.awaddr(11 downto 0), s_l_awvalid => lm.awvalid,
             s_l_awready => ls.awready, s_l_wdata => lm.wdata, s_l_wstrb => lm.wstrb,
             s_l_wvalid => lm.wvalid, s_l_wready => ls.wready, s_l_bresp => ls.bresp,
             s_l_bvalid => ls.bvalid, s_l_bready => lm.bready,
             s_l_araddr => lm.araddr(11 downto 0), s_l_arvalid => lm.arvalid,
             s_l_arready => ls.arready, s_l_rdata => ls.rdata, s_l_rresp => ls.rresp,
             s_l_rvalid => ls.rvalid, s_l_rready => lm.rready,
             m_awaddr => m_awaddr, m_awvalid => m_awvalid, m_awready => m_awready,
             m_wdata => m_wdata, m_wstrb => m_wstrb, m_wvalid => m_wvalid,
             m_wready => m_wready, m_bresp => m_bresp, m_bvalid => m_bvalid,
             m_bready => m_bready, m_araddr => m_araddr, m_arvalid => m_arvalid,
             m_arready => m_arready, m_rdata => m_rdata, m_rresp => m_rresp,
             m_rvalid => m_rvalid, m_rready => m_rready);

  sl_aw <= x"00000" & m_awaddr;
  sl_ar <= x"00000" & m_araddr;
  seam : entity work.axil_slave_model
    generic map(SLVERR_ADDR => x"0000_0F00", CNT_ADDR => x"0000_0F10", LOG_N => 4096,
                SEED => x"5EA1")
    port map(clk => clk, awaddr => sl_aw, awvalid => m_awvalid, awready => m_awready,
             wdata => m_wdata, wstrb => m_wstrb, wvalid => m_wvalid, wready => m_wready,
             bresp => m_bresp, bvalid => m_bvalid, bready => m_bready,
             araddr => sl_ar, arvalid => m_arvalid, arready => m_arready,
             rdata => m_rdata, rresp => m_rresp, rvalid => m_rvalid, rready => m_rready,
             log_count => log_count, log_idx => log_idx, log_kind => log_kind,
             log_addr => log_addr, log_data => log_data, log_resp => log_resp,
             reg_addr => x"00000000", reg_data => reg_data, errors => model_errs,
             mute_b => '0', mute_r => mute_r);

  process(clk)
  begin
    if rising_edge(clk) then
      if host_refused = '1' then refused_n <= refused_n + 1; end if;
    end if;
  end process;

  -- the loop-side master: phases 3, 4, 6, 7 (it may run concurrently with the host)
  lp : process
    variable resp : std_logic_vector(1 downto 0);
    variable d : std_logic_vector(31 downto 0);
    variable e, c : natural := 0;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "loop side: " & msg severity error; end if;
    end procedure;
  begin
    wait until phase = 3;
    axil_wr(clk, lm, ls, 16#108#, x"00001234", resp); chk(resp = "00", "owned write OKAY");
    axil_rd(clk, lm, ls, 16#108#, d, resp);
    chk(resp = "00" and d = x"00001234", "owned read returns the write");
    l_done <= 3;
    wait until phase = 4;
    axil_wr(clk, lm, ls, 16#10C#, x"0000BEEF", resp); chk(resp = "10", "non-owner loop write SLVERR");
    l_done <= 4;
    wait until phase = 6;
    for i in 0 to 19 loop
      axil_wr(clk, lm, ls, 16#200# + 4 * i, u32(i), resp); chk(resp = "00", "phase 6 loop write");
    end loop;
    l_done <= 6;
    wait until phase = 7;
    for i in 0 to 19 loop
      axil_wr(clk, lm, ls, 16#500# + 4 * i, u32(i), resp); chk(resp = "10", "phase 7 loop write refused");
    end loop;
    l_errs <= e; l_checks <= c;
    l_done <= 7;
    wait;
  end process;

  main : process
    variable resp : std_logic_vector(1 downto 0);
    variable d : std_logic_vector(31 downto 0);
    variable e, c, n0, n : natural := 0;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "host side: " & msg severity error; end if;
    end procedure;
    procedure peek(k : natural) is
    begin
      log_idx <= k; wait for 1 ps;
    end procedure;
  begin
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);
    -- 1: host owns by default
    axil_wr(clk, hm, hs, 16#100#, x"A5A50001", resp); chk(resp = "00", "host write OKAY");
    chk(log_count = 1, "host write reached the seam");
    peek(0); chk(log_kind = 0 and log_addr = x"00000100" and log_data = x"A5A50001", "logged write");
    axil_rd(clk, hm, hs, 16#100#, d, resp); chk(resp = "00" and d = x"A5A50001", "host read back");
    -- 2: the loop takes the seam; host accesses are refused and never reach it
    loop_own <= '1';
    n := 0;
    while owner = '0' loop wait until rising_edge(clk); n := n + 1; exit when n > 8; end loop;
    chk(owner = '1', "owner follows loop_own when idle");
    n0 := log_count;
    axil_wr(clk, hm, hs, 16#104#, x"DEAD0002", resp); chk(resp = "10", "refused host write SLVERR");
    axil_rd(clk, hm, hs, 16#100#, d, resp);
    chk(resp = "10" and d = x"00000000", "refused host read SLVERR, RDATA 0");
    chk(log_count = n0, "refused host accesses did not reach the seam");
    wait until rising_edge(clk);   -- let the counter process register both refusals (finding 5)
    chk(refused_n = 2, "host_refused pulsed once per refusal");
    -- 3: owned loop accesses pass
    phase <= 3; wait until l_done = 3;
    -- 4: the host owns again; the loop is refused
    loop_own <= '0';
    n := 0;
    while owner = '1' loop wait until rising_edge(clk); n := n + 1; exit when n > 8; end loop;
    n0 := log_count;
    phase <= 4; wait until l_done = 4;
    chk(log_count = n0, "refused loop write did not reach the seam");
    -- 5: ownership never changes with a transaction in flight
    mute_r <= '1';
    hm.araddr <= x"00000100"; hm.arvalid <= '1'; hm.rready <= '1';
    wait until rising_edge(clk) and hs.arready = '1';
    hm.arvalid <= '0';
    loop_own <= '1';
    for i in 1 to 20 loop
      wait until rising_edge(clk);
      chk(owner = '0', "owner held while a host read is in flight");
    end loop;
    mute_r <= '0';
    wait until rising_edge(clk) and hs.rvalid = '1';
    chk(hs.rresp = "00" and hs.rdata = x"A5A50001", "in-flight read completes OKAY");
    hm <= AXIL_M2S_IDLE;
    n := 0;
    while owner = '0' loop wait until rising_edge(clk); n := n + 1; exit when n > 8; end loop;
    chk(owner = '1', "owner switches after the read");
    -- 6: concurrent: loop owns; host 20 refused, loop 20 logged in order
    n0 := log_count;
    phase <= 6;
    for i in 0 to 19 loop
      axil_wr(clk, hm, hs, 16#300# + 4 * i, u32(i), resp); chk(resp = "10", "phase 6 host refused");
    end loop;
    wait until l_done = 6;
    chk(log_count = n0 + 20, "exactly the loop's 20 writes reached the seam");
    for i in 0 to 19 loop
      peek(n0 + i);
      chk(log_addr = u32(16#200# + 4 * i) and log_data = u32(i), "loop write " & integer'image(i) & " in order");
    end loop;
    -- 7: host owns; the reverse
    loop_own <= '0';
    n := 0;
    while owner = '1' loop wait until rising_edge(clk); n := n + 1; exit when n > 8; end loop;
    n0 := log_count;
    phase <= 7;
    for i in 0 to 19 loop
      axil_wr(clk, hm, hs, 16#400# + 4 * i, u32(i), resp); chk(resp = "00", "phase 7 host write");
    end loop;
    wait until l_done = 7;
    chk(log_count = n0 + 20, "exactly the host's 20 writes reached the seam");
    for i in 0 to 19 loop
      peek(n0 + i);
      chk(log_addr = u32(16#400# + 4 * i) and log_data = u32(i), "host write " & integer'image(i) & " in order");
    end loop;
    -- 8: a seam SLVERR passes through to the owner (and IS logged: it reached the seam)
    n0 := log_count;
    axil_wr(clk, hm, hs, 16#F00#, x"00000001", resp); chk(resp = "10", "seam SLVERR on write passes through");
    axil_rd(clk, hm, hs, 16#F00#, d, resp); chk(resp = "10", "seam SLVERR on read passes through");
    chk(log_count = n0 + 2, "the two SLVERR accesses reached the seam");
    chk(model_errs = 0, "no AXI protocol violation at the seam");
    e := e + l_errs; c := c + l_checks;
    if e = 0 then
      report "PASS: tb_jc_seam_mux checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_jc_seam_mux errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
```

- [ ] **Step 3: Run it to see it fail**

Run: `REGRESS_SCRATCH=~/regress_scratch/t1-a bash sim/regress.sh --only tb_jc_seam_mux --keep`
Expected: the row is BUILD-ERROR/FAIL (`jc_seam_mux` not found).

- [ ] **Step 4: Write the mux**

`rtl/jc_seam_mux.vhd`:

```vhdl
-- rtl/jc_seam_mux.vhd -- exclusive 2:1 owner switch in front of rtl/fk33_seam.vhd's
-- AXI-Lite slave (spec 2026-11-04 section 1.2). NOT an arbiter: one source owns the
-- seam; the other source's transactions complete here with SLVERR and never reach it.
-- One transaction at a time, store-and-forward, so a write and the read after it keep
-- their order (the WIN_ADDR-then-WIN_DATA pattern depends on it). Ownership follows
-- loop_own only in S_IDLE: it never changes with a transaction in flight.
library ieee;
use ieee.std_logic_1164.all;

entity jc_seam_mux is
  generic(AW : positive := 12);
  port(
    clk          : in  std_logic;
    rst          : in  std_logic;
    loop_own     : in  std_logic;
    owner        : out std_logic;
    host_refused : out std_logic;
    s_h_awaddr   : in  std_logic_vector(AW-1 downto 0);
    s_h_awvalid  : in  std_logic;
    s_h_awready  : out std_logic;
    s_h_wdata    : in  std_logic_vector(31 downto 0);
    s_h_wstrb    : in  std_logic_vector(3 downto 0);
    s_h_wvalid   : in  std_logic;
    s_h_wready   : out std_logic;
    s_h_bresp    : out std_logic_vector(1 downto 0);
    s_h_bvalid   : out std_logic;
    s_h_bready   : in  std_logic;
    s_h_araddr   : in  std_logic_vector(AW-1 downto 0);
    s_h_arvalid  : in  std_logic;
    s_h_arready  : out std_logic;
    s_h_rdata    : out std_logic_vector(31 downto 0);
    s_h_rresp    : out std_logic_vector(1 downto 0);
    s_h_rvalid   : out std_logic;
    s_h_rready   : in  std_logic;
    s_l_awaddr   : in  std_logic_vector(AW-1 downto 0);
    s_l_awvalid  : in  std_logic;
    s_l_awready  : out std_logic;
    s_l_wdata    : in  std_logic_vector(31 downto 0);
    s_l_wstrb    : in  std_logic_vector(3 downto 0);
    s_l_wvalid   : in  std_logic;
    s_l_wready   : out std_logic;
    s_l_bresp    : out std_logic_vector(1 downto 0);
    s_l_bvalid   : out std_logic;
    s_l_bready   : in  std_logic;
    s_l_araddr   : in  std_logic_vector(AW-1 downto 0);
    s_l_arvalid  : in  std_logic;
    s_l_arready  : out std_logic;
    s_l_rdata    : out std_logic_vector(31 downto 0);
    s_l_rresp    : out std_logic_vector(1 downto 0);
    s_l_rvalid   : out std_logic;
    s_l_rready   : in  std_logic;
    m_awaddr     : out std_logic_vector(AW-1 downto 0);
    m_awvalid    : out std_logic;
    m_awready    : in  std_logic;
    m_wdata      : out std_logic_vector(31 downto 0);
    m_wstrb      : out std_logic_vector(3 downto 0);
    m_wvalid     : out std_logic;
    m_wready     : in  std_logic;
    m_bresp      : in  std_logic_vector(1 downto 0);
    m_bvalid     : in  std_logic;
    m_bready     : out std_logic;
    m_araddr     : out std_logic_vector(AW-1 downto 0);
    m_arvalid    : out std_logic;
    m_arready    : in  std_logic;
    m_rdata      : in  std_logic_vector(31 downto 0);
    m_rresp      : in  std_logic_vector(1 downto 0);
    m_rvalid     : in  std_logic;
    m_rready     : out std_logic);
end entity;

architecture rtl of jc_seam_mux is
  type st_t is (S_IDLE, S_MW, S_MB, S_MA, S_MR, S_SB, S_SR);
  signal st     : st_t := S_IDLE;
  signal own    : std_logic := '0';
  signal src    : std_logic := '0';                 -- '0' host, '1' loop
  signal a_r    : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal d_r    : std_logic_vector(31 downto 0) := (others => '0');
  signal s_r    : std_logic_vector(3 downto 0) := (others => '0');
  signal resp_r : std_logic_vector(1 downto 0) := "00";
  signal rd_r   : std_logic_vector(31 downto 0) := (others => '0');
  signal aw_ok, w_ok : std_logic := '0';
  signal hw_go, hr_go, lw_go, lr_go : std_logic;
begin
  -- the one decision, in S_IDLE only: owner's write, owner's read, other's write, other's read
  process(all)
    variable hw, hr, lw, lr : std_logic;
  begin
    hw := s_h_awvalid and s_h_wvalid;  hr := s_h_arvalid;
    lw := s_l_awvalid and s_l_wvalid;  lr := s_l_arvalid;
    hw_go <= '0'; hr_go <= '0'; lw_go <= '0'; lr_go <= '0';
    if st = S_IDLE then
      if own = '1' then
        if lw = '1' then lw_go <= '1';
        elsif lr = '1' then lr_go <= '1';
        elsif hw = '1' then hw_go <= '1';
        elsif hr = '1' then hr_go <= '1';
        end if;
      else
        if hw = '1' then hw_go <= '1';
        elsif hr = '1' then hr_go <= '1';
        elsif lw = '1' then lw_go <= '1';
        elsif lr = '1' then lr_go <= '1';
        end if;
      end if;
    end if;
  end process;

  s_h_awready <= hw_go;  s_h_wready <= hw_go;  s_h_arready <= hr_go;
  s_l_awready <= lw_go;  s_l_wready <= lw_go;  s_l_arready <= lr_go;
  s_h_bvalid <= '1' when st = S_SB and src = '0' else '0';
  s_l_bvalid <= '1' when st = S_SB and src = '1' else '0';
  s_h_rvalid <= '1' when st = S_SR and src = '0' else '0';
  s_l_rvalid <= '1' when st = S_SR and src = '1' else '0';
  s_h_bresp <= resp_r;  s_l_bresp <= resp_r;
  s_h_rresp <= resp_r;  s_l_rresp <= resp_r;
  s_h_rdata <= rd_r;    s_l_rdata <= rd_r;
  m_awaddr  <= a_r;  m_araddr <= a_r;  m_wdata <= d_r;  m_wstrb <= s_r;
  m_awvalid <= '1' when st = S_MW and aw_ok = '0' else '0';
  m_wvalid  <= '1' when st = S_MW and w_ok = '0' else '0';
  m_bready  <= '1' when st = S_MB else '0';
  m_arvalid <= '1' when st = S_MA else '0';
  m_rready  <= '1' when st = S_MR else '0';
  owner <= own;

  process(clk)
    variable refuse : boolean;
  begin
    if rising_edge(clk) then
      host_refused <= '0';
      if rst = '1' then
        st <= S_IDLE; own <= '0'; src <= '0'; aw_ok <= '0'; w_ok <= '0'; resp_r <= "00";
      else
        case st is
          when S_IDLE =>
            own <= loop_own;
            if hw_go = '1' or lw_go = '1' then
              if hw_go = '1' then
                src <= '0'; a_r <= s_h_awaddr; d_r <= s_h_wdata; s_r <= s_h_wstrb;
              else
                src <= '1'; a_r <= s_l_awaddr; d_r <= s_l_wdata; s_r <= s_l_wstrb;
              end if;
              refuse := (hw_go = '1' and own = '1') or (lw_go = '1' and own = '0');
              if refuse then
                resp_r <= "10"; st <= S_SB;
                if hw_go = '1' then host_refused <= '1'; end if;
              else
                aw_ok <= '0'; w_ok <= '0'; st <= S_MW;
              end if;
            elsif hr_go = '1' or lr_go = '1' then
              if hr_go = '1' then src <= '0'; a_r <= s_h_araddr;
              else src <= '1'; a_r <= s_l_araddr; end if;
              refuse := (hr_go = '1' and own = '1') or (lr_go = '1' and own = '0');
              if refuse then
                resp_r <= "10"; rd_r <= (others => '0'); st <= S_SR;
                if hr_go = '1' then host_refused <= '1'; end if;
              else
                st <= S_MA;
              end if;
            end if;
          when S_MW =>
            if (aw_ok = '1' or m_awready = '1') and (w_ok = '1' or m_wready = '1') then
              st <= S_MB;
            end if;
            if m_awready = '1' then aw_ok <= '1'; end if;
            if m_wready = '1' then w_ok <= '1'; end if;
          when S_MB =>
            if m_bvalid = '1' then resp_r <= m_bresp; st <= S_SB; end if;
          when S_MA =>
            if m_arready = '1' then st <= S_MR; end if;
          when S_MR =>
            if m_rvalid = '1' then rd_r <= m_rdata; resp_r <= m_rresp; st <= S_SR; end if;
          when S_SB =>
            if (src = '0' and s_h_bready = '1') or (src = '1' and s_l_bready = '1') then
              st <= S_IDLE;
            end if;
          when S_SR =>
            if (src = '0' and s_h_rready = '1') or (src = '1' and s_l_rready = '1') then
              st <= S_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
```

- [ ] **Step 5: Run the bench to see it pass**

Run: `REGRESS_SCRATCH=~/regress_scratch/t1-b bash sim/regress.sh --only tb_jc_seam_mux --keep`
Expected: `OVERALL PASS 1`, and the row's log ends `PASS: tb_jc_seam_mux checks=` with n >= 110.

- [ ] **Step 6: Write the mutant runner**

`sim/mutate_rows.py`:

```python
#!/usr/bin/env python3
"""sim/mutate_rows.py -- anchored source mutants against one GHDL bench.

    python3 sim/mutate_rows.py sim/mutants/<unit>.json

The JSON names the bench (`tb`), its analysis closure in order (`deps`), committed vector
files to link into the run directory (`vectors`), extra run arguments (`generics`), a
`stop_time`, and `rows`. Each row patches ONE anchor (`old` must occur exactly once in
`file`) in a scratch copy, analyzes the closure into a fresh directory and runs the bench.
PASS = exit 0 and the line `(report note): PASS: <tb> checks=`; anything else is KILLED.
A row whose anchor does not match once, or whose patched file does not analyze, is BADMUT.
Row Z0 (no patch) must PASS. Prints `MUTROW <tag> <expect> <got> <why>` per row and ends
`MUTANTS_OK <n>` when every row got what it expected, `MUTANTS_FAIL <n bad>` otherwise.
Scratch: a new directory per run under /mnt/storage/fk33_builds/scratch; nothing is deleted.
"""
import json, os, re, subprocess, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GHDL = os.environ.get("GHDL", "ghdl")
ROOT = os.environ.get("MUTATE_ROOT", "/mnt/storage/fk33_builds/scratch")


def run_row(cfg, row, base):
    d = os.path.join(base, row["tag"])
    work, run = os.path.join(d, "work"), os.path.join(d, "run")
    os.makedirs(work)
    os.makedirs(run)
    for v in cfg.get("vectors", []):
        os.symlink(os.path.join(REPO, v), os.path.join(run, os.path.basename(v)))
    files = []
    if row.get("file") and row["file"] not in cfg["deps"]:
        return "BADMUT(file not in deps)"
    for f in cfg["deps"]:
        src = os.path.join(REPO, f)
        if row.get("file") == f:
            s = open(src).read()
            n = s.count(row["old"])
            if n != 1:
                return "BADMUT(anchor x%d)" % n
            src = os.path.join(d, os.path.basename(f))
            open(src, "w").write(s.replace(row["old"], row["new"]))
        files.append(src)
    with open(os.path.join(d, "log"), "w") as log:
        for f in files:
            r = subprocess.run([GHDL, "-a", "--std=08", "-frelaxed", "--workdir=" + work, f],
                               stdout=log, stderr=subprocess.STDOUT)
            if r.returncode != 0:
                return "BADMUT(analysis)" if row.get("file") else "DID_NOT_ANALYZE"
        cmd = ([GHDL, "-r", "--std=08", "-frelaxed", "--workdir=" + work, cfg["tb"]]
               + cfg.get("generics", []) + ["--max-stack-alloc=0",
                                            "--stop-time=" + cfg.get("stop_time", "100ms")])
        try:
            r = subprocess.run(cmd, cwd=run, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=cfg.get("timeout_s", 1800))
            out, rc = r.stdout.decode(errors="replace"), r.returncode
        except subprocess.TimeoutExpired:
            out, rc = "TIMEOUT\n", -1
        log.write(out)
    ok = rc == 0 and re.search(r"\(report note\): PASS: %s checks=" % re.escape(cfg["tb"]), out)
    return "PASS" if ok else "KILLED"


def main(argv):
    cfg = json.load(open(argv[1]))
    base = os.path.join(ROOT, "mutate_%s_%s_%d" % (cfg["tb"], time.strftime("%Y%m%d_%H%M%S"), os.getpid()))
    os.makedirs(base)
    print("MUTATE_ROOT %s" % base)
    bad, z0 = 0, False
    for row in cfg["rows"]:
        got = run_row(cfg, row, base)
        if row["tag"] == "Z0":
            z0 = got == "PASS"
        good = got == row["expect"]
        bad += 0 if good else 1
        print("MUTROW %s %s %s %s" % (row["tag"], row["expect"], got, row.get("why", "control")), flush=True)
    if not z0:
        bad += 1
        print("MUTROW Z0 missing or not PASS: no kill above means anything")
    print(("MUTANTS_OK %d" % len(cfg["rows"])) if bad == 0 else ("MUTANTS_FAIL %d" % bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 7: Write the mux mutants**

`sim/mutants/jc_seam_mux.json`:

```json
{
  "tb": "tb_jc_seam_mux",
  "deps": ["sim/axil_bfm_pkg.vhd", "sim/axil_slave_model.vhd", "rtl/jc_seam_mux.vhd",
           "sim/tb_jc_seam_mux.vhd"],
  "stop_time": "20ms",
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "M1", "expect": "KILLED", "file": "rtl/jc_seam_mux.vhd",
     "why": "a host write while the loop owns reaches the seam",
     "old": "refuse := (hw_go = '1' and own = '1') or (lw_go = '1' and own = '0');",
     "new": "refuse := (lw_go = '1' and own = '0');"},
    {"tag": "M2", "expect": "KILLED", "file": "rtl/jc_seam_mux.vhd",
     "why": "ownership changes with a transaction in flight",
     "old": "        case st is\n          when S_IDLE =>\n            own <= loop_own;",
     "new": "        own <= loop_own;\n        case st is\n          when S_IDLE =>"},
    {"tag": "M3", "expect": "KILLED", "file": "rtl/jc_seam_mux.vhd",
     "why": "a refused write answers OKAY",
     "old": "resp_r <= \"10\"; st <= S_SB;",
     "new": "resp_r <= \"00\"; st <= S_SB;"},
    {"tag": "M4", "expect": "KILLED", "file": "rtl/jc_seam_mux.vhd",
     "why": "the seam's read response is dropped",
     "old": "rd_r <= m_rdata; resp_r <= m_rresp;",
     "new": "rd_r <= m_rdata; resp_r <= \"00\";"}
  ]
}
```

- [ ] **Step 8: Run the mutants**

Run: `python3 sim/mutate_rows.py sim/mutants/jc_seam_mux.json`
Expected: `MUTROW Z0 PASS PASS`, M1..M4 `KILLED KILLED`, last line `MUTANTS_OK 5`. If any row SURVIVES, the bench misses that defect: add the distinguishing check to the bench, rerun Step 5 and this step, and record the mutant that survived by name in the commit message.

- [ ] **Step 9: Commit**

```bash
git add rtl/jc_seam_mux.vhd sim/axil_bfm_pkg.vhd sim/mutate_rows.py sim/tb_jc_seam_mux.vhd sim/mutants/jc_seam_mux.json
git commit -m "jc loop T1: seam ownership mux, AXI-Lite BFM, mutant runner" -- rtl/jc_seam_mux.vhd sim/axil_bfm_pkg.vhd sim/mutate_rows.py sim/tb_jc_seam_mux.vhd sim/mutants/jc_seam_mux.json
```

---
### Task 2: tok_loop control slave and seam-master FSM

**Files:**
- Create: `rtl/tok_loop_pkg.vhd`, `rtl/tok_loop_regs.vhd`, `rtl/tok_loop_axm.vhd`, `rtl/tok_loop_fsm.vhd`
- Create: `sim/seam_beh_model.vhd`, `sim/row_synth_src.vhd`, `sim/tok_loop_tb_pkg.vhd`, `sim/seam_trace_chk.vhd`, `sim/tb_tok_loop.vhd`, `sim/tok_loop_vec.txt` (generated), `sim/mutants/tok_loop.json`
- Create: `tools/jc/tok_loop_model.py`, `tools/jc/gen_tok_loop_vec.py`, `tools/jc/test_tok_loop_model.py`
- Modify: `server/tests/jc_sim_broker.c` (add `--trace FILE`; handler at `:131-262`, option loop at `:277-311`)

**Interfaces:**
- Consumes: Task 1 `axil_bfm_pkg`; seam register offsets `server/fk33_seam.h:238-377` = `rtl/fk33_seam.vhd:365-479` (CTRL 0x14, STATUS 0x18, ERR_INFO 0x1C, SEQ_POS 0x20, N_STEP 0x24, ARGMAX 0x44, LOGIT_EXP 0x48, X_EXP 0x54, WIN_SEL 0x58, WIN_ADDR 0x5C, WIN_DATA 0x60, TOK_POS 0x8C, KV_MAXPOS 0xA0, XEXP_OUT 0xA4; STATUS bit0 DONE, bit1 BUSY, bit2 ERR, [11:8] code, `rtl/fk33_seam.vhd:1101-1105`); CTRL GO = 1, SEQ_RESET = 2 (`fk33_seam.h:461-462`); WIN_XIN 2, WIN_XOUT 3 (`fk33_seam.h:383-384`). The host sequence it replays: `pl_seq_reset` (`server/pl_backend.c:1252-1297`: W CTRL 2, R STATUS, R TOK_POS, R SEQ_POS, both 0), `push_x_inner` v2 path (`:1331-1349`: W X_EXP, W WIN_SEL 2, W WIN_ADDR 0, n_embd x W WIN_DATA), `go_issue` (`:1367-1389`: W SEQ_POS p, W N_STEP 1, W CTRL 1), `seam_wait` (`:173-243`: poll STATUS for DONE|ERR, on ERR wait BUSY low, R ERR_INFO), `go_finish` (`:1391-1415`: R ARGMAX). The token stream and stop rule of `server/tests/run_prompt.c:776-860` (the prefill's argmax is the first generated id; each id is pushed before the stop check; loop while `!stopped && n_got < max_new`). The sim's argmax (`server/fk33_sim.c:123-171`): `fx = FNV-1a(x_mant as uint16)`, `hist = FNV(hist, 0, pos, fx)`, `pick = (hist*31 + pos*7 + fx) mod n_vocab`, `hist` = 2166136261 after SEQ_RESET (`:568`) and 0 at open; XEXP_OUT echoes X_EXP and window 3 reads back window 2 (the hop model, `:418-430`).
- Produces (names later tasks use):
  - package `tok_loop_pkg`: constants `SM_*`, `TL_*` (map below), `R_*` reasons, `ROLE_SINGLE/A/B`, `SRC_GATHER/HOST/LINK`, `LS_*` LINK_STATUS bits; records `tl_cfg_t`, `tl_stat_t`, `tl_lnk_t`; constants `TL_CFG_RESET`, `TL_LNK_ZERO`; function `tl_u32(n)`.
  - entity `tok_loop_regs` (generics `N_EMBD, PROMPT_MAX, OUT_DEPTH, CAPS`; AXI-Lite slave `s_*` 16-bit; `cfg : out tl_cfg_t`; `st : in tl_stat_t`; `lnk : in tl_lnk_t`; prompt read `pr_addr/pr_data`; OUT ring write `out_we/out_waddr/out_wdata`; host-row read `hr_addr/hr_data`).
  - entity `tok_loop_fsm` (generics `N_EMBD, PROMPT_MAX, OUT_DEPTH, HAS_GATHER, HAS_LINK, SEAM_TMO`; ports in Step 9).
  - entity `tok_loop_axm` (one AXI-Lite transaction at a time, timeout).
  - sim entities `seam_beh_model`, `row_synth_src`, `seam_trace_chk`; package `tok_loop_tb_pkg` (`vec_t`, `load_vec`, `fnv_step`, `FNV_BASIS`, `row16_arr`, `synth_row`).
  - vector format (one line each; `#` comments): `C plen max_new stop n_ids pair` / `P ids...` / `I ids...` / `W die off(3 hex) val(8 hex)` / `D die count fnv(8 hex)` / `E`.

Loop register map (byte offsets inside the loop's 64 KB window; Task 7 places it at `0x00020000` in the ctl map):

| Off | Name | Access | Meaning |
|---|---|---|---|
| 0x000 | ID | R | 0x544C5031 "TLP1" |
| 0x004 | VERSION | R | 1 |
| 0x008 | CAPS | R | [15:0] N_EMBD, [16] HAS_GATHER, [17] HAS_LINK, [23:20] NLANES, [31:24] RXDEPTH |
| 0x00C | CTRL | W | [0] START [1] ABORT [2] RESEND [3] ROW_READY [4] CLEAR (pulses) |
| 0x010 | STATUS | R | [1:0] state 0 idle 1 run 2 stopped, [2] NEED_ROW, [3] NEED_TOKEN, [4] PAUSED, [5] LINK_BAD, [6] LINK_DOWN, [7] OUT_FULL, [15:8] reason, [16] OWNS_SEAM, [17] TX_WAIT_CREDIT (role A waits for LINK_CREDIT >= POS), [18] LINK_WAIT (role B waits for a frame) |
| 0x014 | POS | R | position in progress; after a stop, the final position (ERR_POS) |
| 0x018 | N_GEN | R | ids generated this run (= OUT_COUNT) |
| 0x01C | PROMPT_LEN | RW | 1..4096, latched at START |
| 0x020 | MAX_NEW | RW | >= 1, latched at START |
| 0x024 | ROW_SRC | RW | 0 gather, 1 host, 2 link, latched at START |
| 0x028 | ROLE | RW | 0 single, 1 A, 2 B, latched at START |
| 0x02C | TMO_ENGINE | RW | cycles from GO, default 180,000,000 (D13) |
| 0x030 | TMO_LINK | RW | cycles waiting for a frame while not paused, default 180,000,000 |
| 0x034 | RESEND_CAP | RW | default 3 |
| 0x038 | ERR_ADDR | R | seam offset of the failed transaction (SEAM_ERR) |
| 0x03C | ERR_STATUS | R | seam STATUS latched at ENGINE_ERR / ENGINE_TIMEOUT / SEQ_RESET_FAIL |
| 0x040 | ERR_INFO | R | seam ERR_INFO latched at ENGINE_ERR |
| 0x044 | ROW_TOK | R | token whose row is wanted (NEED_ROW) |
| 0x048 | NEXT_TOKEN | RW | role A: the relayed token; a write sets "valid" |
| 0x04C | ROW_EXP | RW | host row exponent |
| 0x050 | ROW_ADDR | RW | host row index |
| 0x054 | ROW_DATA | W | host row mantissa [15:0]; ROW_ADDR += 1 |
| 0x058 | PROMPT_ADDR | RW | prompt index |
| 0x05C | PROMPT_DATA | RW | prompt id; PROMPT_ADDR += 1 on read or write |
| 0x060 | OUT_COUNT | R | = N_GEN |
| 0x064 | OUT_ACK | RW | ids the host has consumed; reset to 0 at START |
| 0x068 | OUT_ADDR | RW | absolute id index |
| 0x06C | OUT_DATA | R | id at OUT_ADDR mod OUT_DEPTH; OUT_ADDR += 1 |
| 0x070 | LAST_ARGMAX | R | last ARGMAX read from the seam |
| 0x074 | LINK_CREDIT | RW | role A: frames die B has consumed (host relay, D3) |
| 0x078 | LINK_CONSUMED | R | role B: frames popped |
| 0x07C | LINK_CTRL | RW | [0] Aurora reset_pb, [1] pma_init, [2] TX polarity invert |
| 0x080 | LINK_STATUS | R | [0] tx_channel_up [1] rx_channel_up [2] GTG MMCM locked [3] gt_pll_lock [8] paused [9] bad [10] down [11] tx exhausted [12] rx FIFO overflow |
| 0x084..0x09C | FRAMES_SENT, FRAMES_GOOD, CRC_FAILS, SEQPOS_BAD, LINK_DOWNS, RESENDS, OVERRUNS | R | per-run counters |
| 0x0A0 / 0x0A4 | EMB_BASE_LO / HI | RW | gather: HBM byte address of the .mv4i image (HI bit 0 = address bit 32) |
| 0x0A8 | POS_CYCLES | R | cycles of the last position |
| 0x0AC | KVMAX | R | the seam's KV_MAXPOS read at START |
| 0x0C0..0x0DC | STOP_ID[0..7] | RW | default 0xFFFFFFFF |

Stop reasons: 0 none, 1 MAX_NEW, 2 STOP_ID, 3 MAXPOS, 4 ABORT, 5 ENGINE_ERR, 6 ENGINE_TIMEOUT, 7 SEAM_ERR, 8 LINK_TIMEOUT, 9 LINK_RETRY_EXHAUSTED, 10 BAD_CONFIG, 11 SEQ_RESET_FAIL, 12 GATHER_ERR.

FSM states (one transaction issued per state through `F_TXN`; `op_ret` names the state that consumes the result): `F_IDLE, F_CHECK, F_TAKE, F_TXN, F_RS1..F_RS5` (SEQ_RESET and its read-backs, KV_MAXPOS), `F_TOP` (abort / exhausted / MAXPOS / choose token), `F_TOK1, F_TOK2` (prompt RAM latency), `F_ROWREQ, F_ROWW, F_ROWEXP` (row request, error settle, exponent or link timeout), `F_WS, F_WA, F_DATA, F_DNEXT` (window 2 fill), `F_NS, F_GO, F_POLL, F_PCHK, F_EWAIT, F_EINFO` (GO and its verdict), `F_DONE, F_XW, F_XA, F_XD, F_XD2, F_XE` (role A: wait for LINK_CREDIT >= p, then R_X and XEXP_OUT into the TX buffer), `F_TXW, F_TXB1, F_TXB2` (send), `F_GEN, F_TOKW, F_ARG, F_PUSH, F_SCHK` (token, OUT ring, stop rules), `F_STOP, F_STOPPED`.

- [ ] **Step 1: Add `--trace` to the fake broker**

In `server/tests/jc_sim_broker.c`, after `static int g_failn_ran = -1;` (`:80`) add:

```c
static FILE *g_trace;                /* --trace: every register value, for tools/jc/gen_tok_loop_vec.py */
```

In `handle()`, in the `rd32` branch after `rc = g_t[d]->reg_read32(...)` succeeds and before the reply, add:

```c
        if (g_trace) fprintf(g_trace, "R %s 0x%llx 0x%x\n", g_name[d], off, v);
```

In the `wr32` branch, before `reply(...)`, add:

```c
        if (g_trace) fprintf(g_trace, "W %s 0x%llx 0x%llx\n", g_name[d], off, val);
```

In the `wrn` branch, inside the value loop right after `if (!rc) rc = g_t[d]->reg_write32(...);` add:

```c
            if (g_trace) fprintf(g_trace, "W %s 0x%llx 0x%llx\n", g_name[d], off, v);
```

In the `rdn` branch, just before `k = (size_t)sprintf(h, "{\"ok\":true,\"vals\":[");` add:

```c
        if (g_trace) for (i = 0; i < n; i++) fprintf(g_trace, "R %s 0x%llx 0x%x\n", g_name[d], off, vals[i]);
```

At the end of `handle()` (next to `fflush(g_log);`) add `if (g_trace) fflush(g_trace);`. In `main()`'s option loop add a branch:

```c
        else if (!strcmp(argv[i], "--trace")) {
            g_trace = fopen(argv[i + 1], "w");
            if (!g_trace) { perror(argv[i + 1]); return 2; }
        }
```

and add `[--trace FILE]` to the usage string and the header comment ("--trace FILE: one line per register value, `W|R <die> 0x<off> 0x<val>`; wrn and rdn items one line each"). Before `fclose(g_log);` add `if (g_trace) fclose(g_trace);`.

Run: `make -C server jc_sim_broker test_run_prompt_jc`
Expected: builds; all pass (16 test functions, about 30 cases once parametrize expands two of
them; the existing tests do not pass `--trace`).

- [ ] **Step 2: Write the Python model of run_prompt's writes**

`tools/jc/tok_loop_model.py`:

```python
"""tools/jc/tok_loop_model.py -- the WRITES run_prompt sends to one die's seam, as ops,
for sim/tb_tok_loop*.vhd (plan docs/superpowers/plans/2026-11-04-jc-on-fabric-loop-and-link.md,
Task 2). The ops are checked against a capture of the real host code (jc_sim_broker --trace)
by tools/jc/gen_tok_loop_vec.py before any vector is written.

Ops: ("W", off, val) one register write at a seam-relative offset; ("D", n, fnv) a run of n
WIN_DATA writes whose 32-bit values hash to fnv (word-wise FNV-1a, basis 2166136261,
prime 16777619). Reads are not modelled (plan D7).
"""
FNV_B, FNV_P, M32 = 2166136261, 16777619, 0xFFFFFFFF
SEAM_BASE = 0xE000                                   # server/fk33_seam.h:227
CTRL, SEQ_POS, N_STEP = 0x14, 0x20, 0x24
X_EXP, WIN_SEL, WIN_ADDR, WIN_DATA = 0x54, 0x58, 0x5C, 0x60


def fnv32(vals):
    h = FNV_B
    for v in vals:
        h = ((h ^ (v & M32)) * FNV_P) & M32
    return h


def synth_row(tok, n):
    """server/pl_backend.c:66-80, pl_embed_synthetic, exactly: (mantissas, exponent)."""
    h = (FNV_B ^ tok) & M32
    out = []
    for i in range(n):
        h ^= i
        h = (h * FNV_P) & M32
        out.append((h >> 16) - 32768)
    return out, -8


def fed_tokens(prompt, gen):
    """The token fed at each position: the prompt, then every generated id but the last."""
    return list(prompt) + list(gen[:-1])


def die_writes(rows, role="single"):
    """rows: per position (mant list, exp). role "A" adds the hop's window-3 seek."""
    ops = [("W", CTRL, 2)]
    for p, (mant, exp) in enumerate(rows):
        ops += [("W", X_EXP, exp & M32), ("W", WIN_SEL, 2), ("W", WIN_ADDR, 0),
                ("D", len(mant), fnv32([m & 0xFFFF for m in mant])),
                ("W", SEQ_POS, p), ("W", N_STEP, 1), ("W", CTRL, 1)]
        if role == "A":
            ops += [("W", WIN_SEL, 3), ("W", WIN_ADDR, 0)]
    return ops


def parse_trace(lines, die):
    """jc_sim_broker --trace lines -> ops for one die, from its first SEQ_RESET write on."""
    ops, run, started = [], None, False
    for ln in lines:
        f = ln.split()
        if len(f) != 4 or f[0] != "W" or f[1] != die:
            continue
        off, val = int(f[2], 16) - SEAM_BASE, int(f[3], 16) & M32
        if not started:
            if off == CTRL and val == 2:
                started = True
            else:
                continue
        if off == WIN_DATA:
            run = [] if run is None else run
            run.append(val)
            continue
        if run is not None:
            ops.append(("D", len(run), fnv32(run)))
            run = None
        ops.append(("W", off, val))
    if run is not None:
        ops.append(("D", len(run), fnv32(run)))
    return ops
```

- [ ] **Step 3: Write the vector generator**

`tools/jc/gen_tok_loop_vec.py`:

```python
#!/usr/bin/env python3
"""tools/jc/gen_tok_loop_vec.py -- sim/tok_loop_vec.txt from run_prompt's own host sequence.

    python3 tools/jc/gen_tok_loop_vec.py [--out sim/tok_loop_vec.txt] [--check]

Each case starts server/jc_sim_broker --trace and runs server/run_prompt --jc over it, as
server/tests/test_run_prompt_jc.py does, so the ids and the seam writes are the HOST's
(pl_backend.c, pl_pipeline.c). tok_loop_model.py's prediction must equal the capture or
nothing is written (GEN_TOKLOOP_MODEL_DISAGREES). --check regenerates into scratch and
compares with the committed file (GEN_TOKLOOP_CHECK OK|STALE). Scratch: ~/regress_scratch.
NO HARDWARE.
"""
import argparse, os, signal, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "tools"))
import tok_loop_model as M  # noqa: E402

SERVER = os.path.join(REPO, "server")
RUN_PROMPT = os.path.join(SERVER, "run_prompt")
BROKER = os.path.join(SERVER, "jc_sim_broker")
MAN_A = os.path.join(SERVER, "tests", "fixtures", "jc27b_die_a_hbm.json")
MAN_B = os.path.join(SERVER, "tests", "fixtures", "jc27b_die_b_hbm.json")
N_EMBD = 4096            # server/fk33_sim.c:183 (jc_sim_broker opens every die with the defaults)
OUT = os.path.join(REPO, "sim", "tok_loop_vec.txt")

# (name, prompt, max_new, stop, pair, mv4i): stop None = "the first id of case a, at
# index >= 1, that has not occurred before it" (a stop that ends the run early).
CASES = [
    ("a", [1, 2, 3], 5, -1, False, None),
    ("b", [1, 2, 3], 5, None, False, None),
    ("c", [7], 1, -1, False, None),
    ("d", [5, 6, 7, 8, 9, 10, 11, 12], 3, -1, False, None),
]


def write_programs(work):
    """The same descriptor programs as server/tests/test_run_prompt_jc.py's fixture."""
    with open(os.path.join(work, "a.dtbl"), "w") as f:
        for k in range(4):
            for w in range(8):
                f.write("%016x\n" % (0x1000 * k + w + 1))
    with open(os.path.join(work, "a.rel"), "w") as f:
        for k in range(4):
            f.write(format(k + 1, "032b") + "\n")
    with open(os.path.join(work, "b.dtbl"), "w") as f:
        for k in range(3):
            for w in range(8):
                f.write("%016x\n" % (0x2000 * k + w + 7))
    with open(os.path.join(work, "b.rel"), "w") as f:
        for k in range(3):
            f.write(format(k + 9, "032b") + "\n")


def run_case(work, prompt, max_new, stop, pair, mv4i):
    sock = os.path.join(work, "b.sock")
    trace = os.path.join(work, "trace.txt")
    b = subprocess.Popen([BROKER, sock, os.path.join(work, "broker.log"), "--kv-maxpos", "16384",
                          "--dies", "A,B", "--trace", trace],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = b.stdout.readline()
    if not line.startswith("JCSIMBROKER_READY"):
        sys.exit("GEN_TOKLOOP_FAIL broker: %s %s" % (line, b.stderr.read()))
    with open(os.path.join(work, "p.txt"), "w") as f:
        f.write(" ".join(str(x) for x in prompt) + "\n")
    args = [RUN_PROMPT, "--jc", sock, "--jc-die", "A", "--prompt", "p.txt", "--v2", "--seq-reset",
            "--dtbl", "a.dtbl", "--rel", "a.rel", "--manifest", MAN_A,
            "--max-new", str(max_new), "--stop", str(stop), "--ids-out", "ids.txt"]
    if pair:
        args += ["--jc-die2", "B", "--dtbl2", "b.dtbl", "--rel2", "b.rel", "--manifest2", MAN_B]
    if mv4i:
        args += ["--mv4i", mv4i]
    r = subprocess.run(args, cwd=work, capture_output=True, text=True, timeout=900)
    b.send_signal(signal.SIGTERM)
    b.wait(timeout=10)
    if r.returncode != 0:
        sys.exit("GEN_TOKLOOP_FAIL run_prompt rc=%d\n%s%s" % (r.returncode, r.stdout, r.stderr))
    ids = [int(l) for l in open(os.path.join(work, "ids.txt")) if l.strip() and not l.startswith("#")]
    return ids, open(trace).read().splitlines()


def row_fn_for(mv4i):
    if not mv4i:
        return lambda tok: M.synth_row(tok, N_EMBD)
    import embed_gather as EG
    pt = EG.PackedTensor(mv4i)
    return lambda tok: pt.row_bfp(tok, recipe=EG.RECIPE_WIDE)


def first_diff(a, b):
    for k in range(max(len(a), len(b))):
        x = a[k] if k < len(a) else None
        y = b[k] if k < len(b) else None
        if x != y:
            return k, x, y
    return None


def generate(path):
    base = os.path.expanduser("~/regress_scratch")
    os.makedirs(base, exist_ok=True)
    out = ["# sim/tok_loop_vec.txt -- GENERATED by tools/jc/gen_tok_loop_vec.py; do not hand-edit.",
           "# C plen max_new stop n_ids pair / P prompt / I ids / W die off val / D die n fnv / E",
           "# ids and writes are run_prompt's over server/jc_sim_broker (the fk33_sim seam)."]
    ids_a = None
    for name, prompt, max_new, stop, pair, mv4i in CASES:
        if stop is None:
            k = next(k for k in range(1, len(ids_a)) if ids_a[k] not in ids_a[:k])
            stop = ids_a[k]
        work = tempfile.mkdtemp(prefix="tlv_%s_" % name, dir=base)
        write_programs(work)
        ids, lines = run_case(work, prompt, max_new, stop, pair, mv4i)
        if name == "a":
            ids_a = ids
        row = row_fn_for(mv4i)
        rows = [row(t) for t in M.fed_tokens(prompt, ids)]
        got = {"A": M.parse_trace(lines, "A")}
        want = {"A": M.die_writes(rows, role="A" if pair else "single")}
        if pair:
            got["B"] = M.parse_trace(lines, "B")
            want["B"] = M.die_writes(rows)       # the sim hop is the identity (fk33_sim.c:418-430)
        for die in got:
            dif = first_diff(got[die], want[die])
            if dif is not None:
                sys.exit("GEN_TOKLOOP_MODEL_DISAGREES case %s die %s op %d: capture %r model %r"
                         % (name, die, dif[0], dif[1], dif[2]))
        out.append("C %d %d %d %d %d" % (len(prompt), max_new, stop, len(ids), 1 if pair else 0))
        out.append("P " + " ".join(str(x) for x in prompt))
        out.append("I " + " ".join(str(x) for x in ids))
        for dn, die in enumerate(sorted(got)):
            for op in got[die]:
                if op[0] == "W":
                    out.append("W %d %03X %08X" % (dn, op[1], op[2]))
                else:
                    out.append("D %d %d %08X" % (dn, op[1], op[2]))
        out.append("E")
        print("GEN_TOKLOOP case %s: %d prompt, %d ids, %s ops" %
              (name, len(prompt), len(ids), "+".join(str(len(got[d])) for d in sorted(got))))
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    r = subprocess.run(["make", "-C", SERVER, "run_prompt", "jc_sim_broker"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("GEN_TOKLOOP_FAIL make\n" + r.stdout + r.stderr)
    if a.check:
        tmp = os.path.join(tempfile.mkdtemp(prefix="tlv_check_", dir=os.path.expanduser("~/regress_scratch")),
                           "tok_loop_vec.txt")
        generate(tmp)
        same = open(tmp).read() == open(a.out).read()
        print("GEN_TOKLOOP_CHECK %s" % ("OK" if same else "STALE"))
        return 0 if same else 1
    generate(a.out)
    print("GEN_TOKLOOP_DONE %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Write the model's own tests (the model is checked against the host, and the check has teeth)**

`tools/jc/test_tok_loop_model.py`:

```python
"""tools/jc/tok_loop_model.py against a capture of run_prompt (plan 2026-11-04 Task 2).
    python3 -m pytest -q tools/jc/test_tok_loop_model.py
NO HARDWARE: server/jc_sim_broker over the fk33_sim seam."""
import os, subprocess, sys, tempfile
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tok_loop_model as M          # noqa: E402
import gen_tok_loop_vec as G        # noqa: E402


@pytest.fixture(scope="module")
def capture():
    r = subprocess.run(["make", "-C", G.SERVER, "run_prompt", "jc_sim_broker"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    base = os.path.expanduser("~/regress_scratch")
    os.makedirs(base, exist_ok=True)
    work = tempfile.mkdtemp(prefix="tlm_", dir=base)
    G.write_programs(work)
    ids, lines = G.run_case(work, [1, 2, 3], 4, -1, False, None)
    return ids, lines


def rows(prompt, ids):
    return [M.synth_row(t, G.N_EMBD) for t in M.fed_tokens(prompt, ids)]


def test_model_equals_the_host_capture(capture):
    ids, lines = capture
    assert len(ids) == 4
    assert M.parse_trace(lines, "A") == M.die_writes(rows([1, 2, 3], ids))


def test_teeth_prompt_index_off_by_one(capture):
    ids, lines = capture
    shifted = [M.synth_row(t, G.N_EMBD) for t in ([2, 3] + ids[:1] + ids[:-1])][:len(rows([1, 2, 3], ids))]
    assert M.parse_trace(lines, "A") != M.die_writes(shifted)


def test_teeth_no_seq_reset(capture):
    ids, lines = capture
    assert M.parse_trace(lines, "A") != M.die_writes(rows([1, 2, 3], ids))[1:]


def test_teeth_synth_row_exponent(capture):
    ids, lines = capture
    bad = [(m, e + 1) for m, e in rows([1, 2, 3], ids)]
    assert M.parse_trace(lines, "A") != M.die_writes(bad)
```

Run: `python3 -m pytest -q tools/jc/test_tok_loop_model.py`
Expected: `4 passed`. (If `test_model_equals_the_host_capture` fails, the model is wrong about the host; fix the model, never the capture.)

- [ ] **Step 5: Generate and commit-ready the vectors**

Run: `python3 tools/jc/gen_tok_loop_vec.py`
Expected: four `GEN_TOKLOOP case` lines (a: 3 prompt, 5 ids; b: 3 prompt, k+1 ids ending in its stop; c: 1 prompt, 1 id; d: 8 prompt, 3 ids) and `GEN_TOKLOOP_DONE`. Then `python3 tools/jc/gen_tok_loop_vec.py --check` prints `GEN_TOKLOOP_CHECK OK`.

- [ ] **Step 6: Write the package**

`rtl/tok_loop_pkg.vhd`:

```vhdl
-- rtl/tok_loop_pkg.vhd -- offsets, reasons and records for the on-fabric token loop
-- (plan 2026-11-04-jc-on-fabric-loop-and-link, Task 2). Seam offsets are
-- server/fk33_seam.h:238-377 = rtl/fk33_seam.vhd:365-479; the loop map is the plan's table.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package tok_loop_pkg is
  -- the seam (12-bit offsets)
  constant SM_CTRL      : natural := 16#14#;
  constant SM_STATUS    : natural := 16#18#;
  constant SM_ERR_INFO  : natural := 16#1C#;
  constant SM_SEQ_POS   : natural := 16#20#;
  constant SM_N_STEP    : natural := 16#24#;
  constant SM_ARGMAX    : natural := 16#44#;
  constant SM_X_EXP     : natural := 16#54#;
  constant SM_WIN_SEL   : natural := 16#58#;
  constant SM_WIN_ADDR  : natural := 16#5C#;
  constant SM_WIN_DATA  : natural := 16#60#;
  constant SM_TOK_POS   : natural := 16#8C#;
  constant SM_KV_MAXPOS : natural := 16#A0#;
  constant SM_XEXP_OUT  : natural := 16#A4#;
  constant CTRL_GO        : natural := 1;
  constant CTRL_SEQ_RESET : natural := 2;
  constant WIN_XIN        : natural := 2;
  constant WIN_XOUT       : natural := 3;

  -- the loop (16-bit offsets)
  constant TL_ID           : natural := 16#000#;
  constant TL_VERSION      : natural := 16#004#;
  constant TL_CAPS         : natural := 16#008#;
  constant TL_CTRL         : natural := 16#00C#;
  constant TL_STATUS       : natural := 16#010#;
  constant TL_POS          : natural := 16#014#;
  constant TL_N_GEN        : natural := 16#018#;
  constant TL_PROMPT_LEN   : natural := 16#01C#;
  constant TL_MAX_NEW      : natural := 16#020#;
  constant TL_ROW_SRC      : natural := 16#024#;
  constant TL_ROLE         : natural := 16#028#;
  constant TL_TMO_ENGINE   : natural := 16#02C#;
  constant TL_TMO_LINK     : natural := 16#030#;
  constant TL_RESEND_CAP   : natural := 16#034#;
  constant TL_ERR_ADDR     : natural := 16#038#;
  constant TL_ERR_STATUS   : natural := 16#03C#;
  constant TL_ERR_INFO     : natural := 16#040#;
  constant TL_ROW_TOK      : natural := 16#044#;
  constant TL_NEXT_TOKEN   : natural := 16#048#;
  constant TL_ROW_EXP      : natural := 16#04C#;
  constant TL_ROW_ADDR     : natural := 16#050#;
  constant TL_ROW_DATA     : natural := 16#054#;
  constant TL_PROMPT_ADDR  : natural := 16#058#;
  constant TL_PROMPT_DATA  : natural := 16#05C#;
  constant TL_OUT_COUNT    : natural := 16#060#;
  constant TL_OUT_ACK      : natural := 16#064#;
  constant TL_OUT_ADDR     : natural := 16#068#;
  constant TL_OUT_DATA     : natural := 16#06C#;
  constant TL_LAST_ARGMAX  : natural := 16#070#;
  constant TL_LINK_CREDIT  : natural := 16#074#;
  constant TL_LINK_CONSUMED: natural := 16#078#;
  constant TL_LINK_CTRL    : natural := 16#07C#;
  constant TL_LINK_STATUS  : natural := 16#080#;
  constant TL_FRAMES_SENT  : natural := 16#084#;
  constant TL_FRAMES_GOOD  : natural := 16#088#;
  constant TL_CRC_FAILS    : natural := 16#08C#;
  constant TL_SEQPOS_BAD   : natural := 16#090#;
  constant TL_LINK_DOWNS   : natural := 16#094#;
  constant TL_RESENDS      : natural := 16#098#;
  constant TL_OVERRUNS     : natural := 16#09C#;
  constant TL_EMB_BASE_LO  : natural := 16#0A0#;
  constant TL_EMB_BASE_HI  : natural := 16#0A4#;
  constant TL_POS_CYCLES   : natural := 16#0A8#;
  constant TL_KVMAX        : natural := 16#0AC#;
  constant TL_STOP_ID0     : natural := 16#0C0#;
  constant TL_ID_MAGIC     : std_logic_vector(31 downto 0) := x"544C5031";

  constant R_NONE : natural := 0;            constant R_MAX_NEW : natural := 1;
  constant R_STOP_ID : natural := 2;         constant R_MAXPOS : natural := 3;
  constant R_ABORT : natural := 4;           constant R_ENGINE_ERR : natural := 5;
  constant R_ENGINE_TIMEOUT : natural := 6;  constant R_SEAM_ERR : natural := 7;
  constant R_LINK_TIMEOUT : natural := 8;    constant R_LINK_RETRY_EXHAUSTED : natural := 9;
  constant R_BAD_CONFIG : natural := 10;     constant R_SEQ_RESET_FAIL : natural := 11;
  constant R_GATHER_ERR : natural := 12;

  constant ROLE_SINGLE : natural := 0;  constant ROLE_A : natural := 1;  constant ROLE_B : natural := 2;
  constant SRC_GATHER  : natural := 0;  constant SRC_HOST : natural := 1; constant SRC_LINK : natural := 2;

  constant LS_TX_UP : natural := 0;   constant LS_RX_UP : natural := 1;
  constant LS_GTG_LOCK : natural := 2; constant LS_PLL_LOCK : natural := 3;
  constant LS_PAUSED : natural := 8;  constant LS_BAD : natural := 9;
  constant LS_DOWN : natural := 10;   constant LS_TX_EXH : natural := 11;
  constant LS_RX_OVF : natural := 12;

  constant TMO_DEFAULT : natural := 180000000;   -- plan D13

  type slv32_arr8 is array (0 to 7) of std_logic_vector(31 downto 0);
  type tl_cfg_t is record
    prompt_len, max_new : unsigned(31 downto 0);
    row_src, role       : unsigned(1 downto 0);
    tmo_engine, tmo_link, resend_cap : unsigned(31 downto 0);
    stop_id             : slv32_arr8;
    start, abort, resend, row_ready, clear : std_logic;
    next_tok            : unsigned(31 downto 0);
    next_tok_v          : std_logic;
    row_exp             : std_logic_vector(31 downto 0);
    out_ack, link_credit : unsigned(31 downto 0);
    link_ctrl           : std_logic_vector(31 downto 0);
    emb_base            : unsigned(32 downto 0);
  end record;
  type tl_stat_t is record
    state               : unsigned(1 downto 0);
    reason              : unsigned(7 downto 0);
    pos, n_gen          : unsigned(31 downto 0);
    need_row, need_token, out_full, owns, tx_wait, link_wait, tok_take : std_logic;
    err_addr, err_status, err_info, last_argmax : std_logic_vector(31 downto 0);
    row_tok, pos_cycles, kvmax : unsigned(31 downto 0);
    row_src, role       : unsigned(1 downto 0);
  end record;
  type tl_lnk_t is record
    frames_sent, frames_good, crc_fails, seqpos_bad : unsigned(31 downto 0);
    link_downs, resends, overruns, consumed : unsigned(31 downto 0);
    status              : std_logic_vector(31 downto 0);
  end record;

  constant TL_CFG_RESET : tl_cfg_t := (
    prompt_len => (others => '0'), max_new => (others => '0'),
    row_src => "00", role => "00",
    tmo_engine => to_unsigned(TMO_DEFAULT, 32), tmo_link => to_unsigned(TMO_DEFAULT, 32),
    resend_cap => to_unsigned(3, 32),
    stop_id => (others => x"FFFFFFFF"),
    start => '0', abort => '0', resend => '0', row_ready => '0', clear => '0',
    next_tok => (others => '0'), next_tok_v => '0', row_exp => (others => '0'),
    out_ack => (others => '0'), link_credit => (others => '0'),
    link_ctrl => (others => '0'), emb_base => (others => '0'));
  constant TL_LNK_ZERO : tl_lnk_t := (
    frames_sent => (others => '0'), frames_good => (others => '0'),
    crc_fails => (others => '0'), seqpos_bad => (others => '0'),
    link_downs => (others => '0'), resends => (others => '0'),
    overruns => (others => '0'), consumed => (others => '0'), status => (others => '0'));

  function tl_u32(n : natural) return std_logic_vector;
end package;

package body tok_loop_pkg is
  function tl_u32(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n, 32));
  end function;
end package body;
```

- [ ] **Step 7: Write the AXI-Lite master**

`rtl/tok_loop_axm.vhd`:

```vhdl
-- rtl/tok_loop_axm.vhd -- one AXI-Lite transaction at a time for tok_loop_fsm, with a
-- timeout (plan D6: the seam itself never answers SLVERR, so a hung slave is the case to
-- catch). A timeout ends the transaction with resp "11" and timed_out; the bus may then be
-- inconsistent, and the loop stops with SEAM_ERR (recovery is a reset).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tok_loop_axm is
  generic(AW : positive := 12);
  port(
    clk, rst  : in  std_logic;
    req       : in  std_logic;
    req_wr    : in  std_logic;
    req_addr  : in  unsigned(AW-1 downto 0);
    req_data  : in  std_logic_vector(31 downto 0);
    tmo_cyc   : in  unsigned(31 downto 0);
    done      : out std_logic;
    rdata     : out std_logic_vector(31 downto 0);
    resp      : out std_logic_vector(1 downto 0);
    timed_out : out std_logic;
    m_awaddr  : out std_logic_vector(AW-1 downto 0);
    m_awvalid : out std_logic;
    m_awready : in  std_logic;
    m_wdata   : out std_logic_vector(31 downto 0);
    m_wstrb   : out std_logic_vector(3 downto 0);
    m_wvalid  : out std_logic;
    m_wready  : in  std_logic;
    m_bresp   : in  std_logic_vector(1 downto 0);
    m_bvalid  : in  std_logic;
    m_bready  : out std_logic;
    m_araddr  : out std_logic_vector(AW-1 downto 0);
    m_arvalid : out std_logic;
    m_arready : in  std_logic;
    m_rdata   : in  std_logic_vector(31 downto 0);
    m_rresp   : in  std_logic_vector(1 downto 0);
    m_rvalid  : in  std_logic;
    m_rready  : out std_logic);
end entity;

architecture rtl of tok_loop_axm is
  type as_t is (A_IDLE, A_W, A_B, A_AR, A_R);
  signal s : as_t := A_IDLE;
  signal a_r : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal d_r : std_logic_vector(31 downto 0) := (others => '0');
  signal aw_ok, w_ok : std_logic := '0';
  signal cnt : unsigned(31 downto 0) := (others => '0');
begin
  m_awaddr <= a_r;  m_araddr <= a_r;  m_wdata <= d_r;  m_wstrb <= "1111";
  m_awvalid <= '1' when s = A_W and aw_ok = '0' else '0';
  m_wvalid  <= '1' when s = A_W and w_ok = '0' else '0';
  m_bready  <= '1' when s = A_B else '0';
  m_arvalid <= '1' when s = A_AR else '0';
  m_rready  <= '1' when s = A_R else '0';

  process(clk)
  begin
    if rising_edge(clk) then
      done <= '0'; timed_out <= '0';
      if rst = '1' then
        s <= A_IDLE; aw_ok <= '0'; w_ok <= '0'; cnt <= (others => '0');
        resp <= "00"; rdata <= (others => '0');
      else
        if s /= A_IDLE then cnt <= cnt + 1; end if;
        case s is
          when A_IDLE =>
            cnt <= (others => '0');
            if req = '1' then
              a_r <= std_logic_vector(req_addr); d_r <= req_data; aw_ok <= '0'; w_ok <= '0';
              if req_wr = '1' then s <= A_W; else s <= A_AR; end if;
            end if;
          when A_W =>
            if m_awready = '1' then aw_ok <= '1'; end if;
            if m_wready = '1' then w_ok <= '1'; end if;
            if (aw_ok = '1' or m_awready = '1') and (w_ok = '1' or m_wready = '1') then s <= A_B; end if;
          when A_B =>
            if m_bvalid = '1' then resp <= m_bresp; rdata <= (others => '0'); done <= '1'; s <= A_IDLE; end if;
          when A_AR =>
            if m_arready = '1' then s <= A_R; end if;
          when A_R =>
            if m_rvalid = '1' then resp <= m_rresp; rdata <= m_rdata; done <= '1'; s <= A_IDLE; end if;
        end case;
        if s /= A_IDLE and cnt >= tmo_cyc then
          resp <= "11"; done <= '1'; timed_out <= '1'; s <= A_IDLE;
        end if;
      end if;
    end if;
  end process;
end architecture;
```

- [ ] **Step 8: Write the control slave**

`rtl/tok_loop_regs.vhd`:

```vhdl
-- rtl/tok_loop_regs.vhd -- the loop's AXI-Lite control slave (plan 2026-11-04 Task 2):
-- registers, the prompt RAM (PROMPT_ADDR/PROMPT_DATA), the OUT ring (OUT_ADDR/OUT_DATA,
-- read non-destructively, plan D10) and the host row RAM (ROW_ADDR/ROW_DATA). Config is
-- presented live on `cfg`; tok_loop_fsm latches what it must at START.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.tok_loop_pkg.all;

entity tok_loop_regs is
  generic(N_EMBD : positive := 4096; PROMPT_MAX : positive := 4096;
          OUT_DEPTH : positive := 1024; CAPS : std_logic_vector(31 downto 0) := x"00000000");
  port(
    clk, rst  : in  std_logic;
    s_awaddr  : in  std_logic_vector(15 downto 0);
    s_awvalid : in  std_logic;
    s_awready : out std_logic;
    s_wdata   : in  std_logic_vector(31 downto 0);
    s_wstrb   : in  std_logic_vector(3 downto 0);
    s_wvalid  : in  std_logic;
    s_wready  : out std_logic;
    s_bresp   : out std_logic_vector(1 downto 0);
    s_bvalid  : out std_logic;
    s_bready  : in  std_logic;
    s_araddr  : in  std_logic_vector(15 downto 0);
    s_arvalid : in  std_logic;
    s_arready : out std_logic;
    s_rdata   : out std_logic_vector(31 downto 0);
    s_rresp   : out std_logic_vector(1 downto 0);
    s_rvalid  : out std_logic;
    s_rready  : in  std_logic;
    cfg       : out tl_cfg_t;
    st        : in  tl_stat_t;
    lnk       : in  tl_lnk_t;
    pr_addr   : in  unsigned(11 downto 0);
    pr_data   : out unsigned(31 downto 0);
    out_we    : in  std_logic;
    out_waddr : in  unsigned(15 downto 0);
    out_wdata : in  std_logic_vector(31 downto 0);
    hr_addr   : in  unsigned(12 downto 0);
    hr_data   : out std_logic_vector(15 downto 0));
end entity;

architecture rtl of tok_loop_regs is
  type pram_t is array (0 to PROMPT_MAX-1) of std_logic_vector(31 downto 0);
  type oram_t is array (0 to OUT_DEPTH-1) of std_logic_vector(31 downto 0);
  type hram_t is array (0 to N_EMBD-1) of std_logic_vector(15 downto 0);
  signal pram : pram_t;
  signal oram : oram_t;
  signal hram : hram_t;
  signal c : tl_cfg_t := TL_CFG_RESET;
  signal paddr, raddr : unsigned(12 downto 0) := (others => '0');
  signal oaddr : unsigned(31 downto 0) := (others => '0');
  signal bv, rv, rph : std_logic := '0';
  signal ra : natural range 0 to 65535 := 0;
  signal p_q, o_q, rdata_r : std_logic_vector(31 downto 0) := (others => '0');
  signal w_go : std_logic;
begin
  cfg <= c;
  w_go <= s_awvalid and s_wvalid and not bv;
  s_awready <= w_go;  s_wready <= w_go;
  s_bvalid <= bv;     s_bresp <= "00";
  s_arready <= '1' when rph = '0' and rv = '0' else '0';
  s_rvalid <= rv;     s_rresp <= "00";  s_rdata <= rdata_r;

  -- the FSM's ports into the three RAMs (registered read: one cycle)
  fsm_side : process(clk)
  begin
    if rising_edge(clk) then
      pr_data <= unsigned(pram(to_integer(pr_addr) mod PROMPT_MAX));
      hr_data <= hram(to_integer(hr_addr) mod N_EMBD);
      if out_we = '1' then oram(to_integer(out_waddr) mod OUT_DEPTH) <= out_wdata; end if;
    end if;
  end process;

  bus_side : process(clk)
    variable a : natural;
    variable d, rvv : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      c.start <= '0'; c.abort <= '0'; c.resend <= '0'; c.row_ready <= '0'; c.clear <= '0';
      if st.tok_take = '1' then c.next_tok_v <= '0'; end if;
      if bv = '1' and s_bready = '1' then bv <= '0'; end if;
      if rv = '1' and s_rready = '1' then rv <= '0'; end if;
      if rst = '1' then
        c <= TL_CFG_RESET; bv <= '0'; rv <= '0'; rph <= '0';
        paddr <= (others => '0'); raddr <= (others => '0'); oaddr <= (others => '0');
      else
        -- ---- writes ----
        if w_go = '1' then
          bv <= '1';
          a := to_integer(unsigned(s_awaddr(15 downto 2))) * 4;
          d := s_wdata;
          case a is
            when TL_CTRL =>
              c.start <= d(0); c.abort <= d(1); c.resend <= d(2); c.row_ready <= d(3); c.clear <= d(4);
              if d(0) = '1' and st.state /= 1 then
                -- finding 14: link_credit cleared alongside out_ack/next_tok_v, or a rerun
                -- without the host rewriting it could let A outrun B (Review Focus 5)
                c.out_ack <= (others => '0'); c.next_tok_v <= '0'; c.link_credit <= (others => '0');
              end if;
            when TL_PROMPT_LEN   => c.prompt_len <= unsigned(d);
            when TL_MAX_NEW      => c.max_new <= unsigned(d);
            when TL_ROW_SRC      => c.row_src <= unsigned(d(1 downto 0));
            when TL_ROLE         => c.role <= unsigned(d(1 downto 0));
            when TL_TMO_ENGINE   => c.tmo_engine <= unsigned(d);
            when TL_TMO_LINK     => c.tmo_link <= unsigned(d);
            when TL_RESEND_CAP   => c.resend_cap <= unsigned(d);
            when TL_NEXT_TOKEN   => c.next_tok <= unsigned(d); c.next_tok_v <= '1';
            when TL_ROW_EXP      => c.row_exp <= d;
            when TL_ROW_ADDR     => raddr <= unsigned(d(12 downto 0));
            when TL_ROW_DATA     =>
              hram(to_integer(raddr) mod N_EMBD) <= d(15 downto 0); raddr <= raddr + 1;
            when TL_PROMPT_ADDR  => paddr <= unsigned(d(12 downto 0));
            when TL_PROMPT_DATA  =>
              pram(to_integer(paddr) mod PROMPT_MAX) <= d; paddr <= paddr + 1;
            when TL_OUT_ACK      => c.out_ack <= unsigned(d);
            when TL_OUT_ADDR     => oaddr <= unsigned(d);
            when TL_LINK_CREDIT  => c.link_credit <= unsigned(d);
            when TL_LINK_CTRL    => c.link_ctrl <= d;
            when TL_EMB_BASE_LO  => c.emb_base(31 downto 0) <= unsigned(d);
            when TL_EMB_BASE_HI  => c.emb_base(32) <= d(0);
            when others =>
              if a >= TL_STOP_ID0 and a < TL_STOP_ID0 + 32 then
                c.stop_id((a - TL_STOP_ID0) / 4) <= d;
              end if;
          end case;
        end if;
        -- ---- reads: accept, then answer one cycle later (RAM latency) ----
        if rph = '0' then
          if s_arvalid = '1' and rv = '0' then
            ra  <= to_integer(unsigned(s_araddr(15 downto 2))) * 4;
            p_q <= pram(to_integer(paddr) mod PROMPT_MAX);
            o_q <= oram(to_integer(oaddr(15 downto 0)) mod OUT_DEPTH);
            rph <= '1';
          end if;
        else
          rvv := (others => '0');
          case ra is
            when TL_ID          => rvv := TL_ID_MAGIC;
            when TL_VERSION     => rvv := x"00000001";
            when TL_CAPS        => rvv := CAPS;
            when TL_STATUS      =>
              rvv(1 downto 0) := std_logic_vector(st.state);
              rvv(2) := st.need_row;  rvv(3) := st.need_token;
              rvv(4) := lnk.status(LS_PAUSED);  rvv(5) := lnk.status(LS_BAD);
              rvv(6) := lnk.status(LS_DOWN);    rvv(7) := st.out_full;
              rvv(15 downto 8) := std_logic_vector(st.reason);
              rvv(16) := st.owns;  rvv(17) := st.tx_wait;  rvv(18) := st.link_wait;
            when TL_POS          => rvv := std_logic_vector(st.pos);
            when TL_N_GEN | TL_OUT_COUNT => rvv := std_logic_vector(st.n_gen);
            when TL_PROMPT_LEN   => rvv := std_logic_vector(c.prompt_len);
            when TL_MAX_NEW      => rvv := std_logic_vector(c.max_new);
            when TL_ROW_SRC      => rvv(1 downto 0) := std_logic_vector(c.row_src);
            when TL_ROLE         => rvv(1 downto 0) := std_logic_vector(c.role);
            when TL_TMO_ENGINE   => rvv := std_logic_vector(c.tmo_engine);
            when TL_TMO_LINK     => rvv := std_logic_vector(c.tmo_link);
            when TL_RESEND_CAP   => rvv := std_logic_vector(c.resend_cap);
            when TL_ERR_ADDR     => rvv := st.err_addr;
            when TL_ERR_STATUS   => rvv := st.err_status;
            when TL_ERR_INFO     => rvv := st.err_info;
            when TL_ROW_TOK      => rvv := std_logic_vector(st.row_tok);
            when TL_NEXT_TOKEN   => rvv := std_logic_vector(c.next_tok);
            when TL_ROW_EXP      => rvv := c.row_exp;
            when TL_ROW_ADDR     => rvv(12 downto 0) := std_logic_vector(raddr);
            when TL_PROMPT_ADDR  => rvv(12 downto 0) := std_logic_vector(paddr);
            when TL_PROMPT_DATA  => rvv := p_q; paddr <= paddr + 1;
            when TL_OUT_ACK      => rvv := std_logic_vector(c.out_ack);
            when TL_OUT_ADDR     => rvv := std_logic_vector(oaddr);
            when TL_OUT_DATA     => rvv := o_q; oaddr <= oaddr + 1;
            when TL_LAST_ARGMAX  => rvv := st.last_argmax;
            when TL_LINK_CREDIT  => rvv := std_logic_vector(c.link_credit);
            when TL_LINK_CONSUMED=> rvv := std_logic_vector(lnk.consumed);
            when TL_LINK_CTRL    => rvv := c.link_ctrl;
            when TL_LINK_STATUS  => rvv := lnk.status;
            when TL_FRAMES_SENT  => rvv := std_logic_vector(lnk.frames_sent);
            when TL_FRAMES_GOOD  => rvv := std_logic_vector(lnk.frames_good);
            when TL_CRC_FAILS    => rvv := std_logic_vector(lnk.crc_fails);
            when TL_SEQPOS_BAD   => rvv := std_logic_vector(lnk.seqpos_bad);
            when TL_LINK_DOWNS   => rvv := std_logic_vector(lnk.link_downs);
            when TL_RESENDS      => rvv := std_logic_vector(lnk.resends);
            when TL_OVERRUNS     => rvv := std_logic_vector(lnk.overruns);
            when TL_EMB_BASE_LO  => rvv := std_logic_vector(c.emb_base(31 downto 0));
            when TL_EMB_BASE_HI  => rvv(0) := c.emb_base(32);
            when TL_POS_CYCLES   => rvv := std_logic_vector(st.pos_cycles);
            when TL_KVMAX        => rvv := std_logic_vector(st.kvmax);
            when others =>
              if ra >= TL_STOP_ID0 and ra < TL_STOP_ID0 + 32 then
                rvv := c.stop_id((ra - TL_STOP_ID0) / 4);
              end if;
          end case;
          rdata_r <= rvv; rv <= '1'; rph <= '0';
        end if;
      end if;
    end if;
  end process;
end architecture;
```

- [ ] **Step 9: Write the FSM**

`rtl/tok_loop_fsm.vhd`:

```vhdl
-- rtl/tok_loop_fsm.vhd -- the host's per-position seam sequence, on the fabric (spec
-- 2026-11-04 sections 1.1, 2, 3; plan Task 2). Every value it writes, in order, is what
-- run_prompt writes over the same seam (server/pl_backend.c:1252-1415): SEQ_RESET and its
-- read-backs, then per position X_EXP, WIN_SEL 2, WIN_ADDR 0, n_embd WIN_DATA, SEQ_POS,
-- N_STEP 1, GO, poll STATUS for DONE|ERR, and from the last prompt position on, ARGMAX.
-- Role A also reads R_X (window 3) and XEXP_OUT into jc_link_tx, once the host has relayed
-- LINK_CREDIT >= p (plan D3), and sends it; its generated token comes from NEXT_TOKEN.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.tok_loop_pkg.all;

entity tok_loop_fsm is
  generic(N_EMBD : positive := 4096; PROMPT_MAX : positive := 4096; OUT_DEPTH : positive := 1024;
          HAS_GATHER : boolean := true; HAS_LINK : boolean := true; SEAM_TMO : positive := 65536);
  port(
    clk, rst     : in  std_logic;
    cfg          : in  tl_cfg_t;
    st           : out tl_stat_t;
    run_start    : out std_logic;
    pr_addr      : out unsigned(11 downto 0);
    pr_data      : in  unsigned(31 downto 0);
    out_we       : out std_logic;
    out_waddr    : out unsigned(15 downto 0);
    out_wdata    : out std_logic_vector(31 downto 0);
    loop_own     : out std_logic;
    owner        : in  std_logic;
    rs_req       : out std_logic;
    rs_tok       : out unsigned(31 downto 0);
    rs_exp_valid : in  std_logic;
    rs_exp       : in  std_logic_vector(31 downto 0);
    rs_err       : in  std_logic;
    rs_m_valid   : in  std_logic;
    rs_m_data    : in  std_logic_vector(15 downto 0);
    rs_m_ready   : out std_logic;
    rs_paused    : in  std_logic;
    tx_wr        : out std_logic;
    tx_widx      : out unsigned(11 downto 0);
    tx_wdata     : out std_logic_vector(31 downto 0);
    tx_send      : out std_logic;
    tx_pos       : out unsigned(31 downto 0);
    tx_exp       : out std_logic_vector(31 downto 0);
    tx_busy      : in  std_logic;
    tx_exhausted : in  std_logic;
    m_awaddr     : out std_logic_vector(11 downto 0);
    m_awvalid    : out std_logic;
    m_awready    : in  std_logic;
    m_wdata      : out std_logic_vector(31 downto 0);
    m_wstrb      : out std_logic_vector(3 downto 0);
    m_wvalid     : out std_logic;
    m_wready     : in  std_logic;
    m_bresp      : in  std_logic_vector(1 downto 0);
    m_bvalid     : in  std_logic;
    m_bready     : out std_logic;
    m_araddr     : out std_logic_vector(11 downto 0);
    m_arvalid    : out std_logic;
    m_arready    : in  std_logic;
    m_rdata      : in  std_logic_vector(31 downto 0);
    m_rresp      : in  std_logic_vector(1 downto 0);
    m_rvalid     : in  std_logic;
    m_rready     : out std_logic);
end entity;

architecture rtl of tok_loop_fsm is
  type fs_t is (F_IDLE, F_CHECK, F_TAKE, F_TXN, F_RS1, F_RS2, F_RS3, F_RS4, F_RS5,
                F_TOP, F_TOK1, F_TOK2, F_ROWREQ, F_ROWW, F_ROWEXP, F_WS, F_WA, F_DATA, F_DNEXT,
                F_NS, F_GO, F_POLL, F_PCHK, F_EWAIT, F_EINFO, F_DONE, F_XW, F_XA, F_XD, F_XD2, F_XE,
                F_TXW, F_TXB1, F_TXB2, F_GEN, F_TOKW, F_ARG, F_PUSH, F_SCHK, F_STOP, F_STOPPED);
  constant Z32 : std_logic_vector(31 downto 0) := (others => '0');
  signal fs, op_ret : fs_t := F_IDLE;
  signal op_wr : std_logic := '0';
  signal op_addr : natural range 0 to 4095 := 0;
  signal op_data, rd_r, tp_r, xexp_r, ax_rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal ax_req, ax_done, ax_tmo, sent : std_logic := '0';
  signal ax_resp : std_logic_vector(1 downto 0);
  signal p, plen, maxn, kvmax, n_gen, tok, g, ecnt, lcnt, pcyc : unsigned(31 downto 0) := (others => '0');
  signal role_l, src_l, state2 : unsigned(1 downto 0) := "00";
  signal i : natural range 0 to N_EMBD := 0;
  signal lo16 : std_logic_vector(15 downto 0) := (others => '0');
  signal eng_run, abort_l, own_r, tok_take : std_logic := '0';
  signal reason : unsigned(7 downto 0) := (others => '0');
  signal err_addr, err_status, err_info, last_arg : std_logic_vector(31 downto 0) := (others => '0');
  signal row_tok, pos_cycles : unsigned(31 downto 0) := (others => '0');
begin
  axm : entity work.tok_loop_axm
    generic map(AW => 12)
    port map(clk => clk, rst => rst, req => ax_req, req_wr => op_wr,
             req_addr => to_unsigned(op_addr, 12), req_data => op_data,
             tmo_cyc => to_unsigned(SEAM_TMO, 32), done => ax_done, rdata => ax_rdata,
             resp => ax_resp, timed_out => ax_tmo,
             m_awaddr => m_awaddr, m_awvalid => m_awvalid, m_awready => m_awready,
             m_wdata => m_wdata, m_wstrb => m_wstrb, m_wvalid => m_wvalid, m_wready => m_wready,
             m_bresp => m_bresp, m_bvalid => m_bvalid, m_bready => m_bready,
             m_araddr => m_araddr, m_arvalid => m_arvalid, m_arready => m_arready,
             m_rdata => m_rdata, m_rresp => m_rresp, m_rvalid => m_rvalid, m_rready => m_rready);

  loop_own <= own_r;
  st.state <= state2;          st.reason <= reason;
  st.pos <= p;                 st.n_gen <= n_gen;
  st.need_row <= '1' when fs = F_ROWEXP and src_l = SRC_HOST else '0';
  st.need_token <= '1' when fs = F_TOKW else '0';
  st.out_full <= '1' when fs = F_PUSH and n_gen - cfg.out_ack >= OUT_DEPTH else '0';
  st.owns <= owner;
  st.tx_wait <= '1' when fs = F_XW else '0';
  st.link_wait <= '1' when fs = F_ROWEXP and src_l = SRC_LINK else '0';
  st.tok_take <= tok_take;
  st.err_addr <= err_addr;     st.err_status <= err_status;
  st.err_info <= err_info;     st.last_argmax <= last_arg;
  st.row_tok <= row_tok;       st.pos_cycles <= pos_cycles;
  st.kvmax <= kvmax;           st.row_src <= src_l;
  st.role <= role_l;

  process(clk)
    procedure txn(wr : std_logic; a : natural; d : std_logic_vector(31 downto 0); ret : fs_t) is
    begin
      op_wr <= wr; op_addr <= a; op_data <= d; op_ret <= ret; fs <= F_TXN;
    end procedure;
    procedure stop(r : natural) is
    begin
      reason <= to_unsigned(r, 8); fs <= F_STOP;
    end procedure;
    impure function is_stop(v : unsigned(31 downto 0)) return boolean is
    begin
      for k in 0 to 7 loop
        if cfg.stop_id(k) = std_logic_vector(v) then return true; end if;
      end loop;
      return false;
    end function;
  begin
    if rising_edge(clk) then
      ax_req <= '0'; rs_req <= '0'; rs_m_ready <= '0'; out_we <= '0';
      tx_wr <= '0'; tx_send <= '0'; run_start <= '0'; tok_take <= '0';
      if eng_run = '1' then ecnt <= ecnt + 1; end if;
      if state2 = 1 then pcyc <= pcyc + 1; end if;
      if cfg.abort = '1' and state2 = 1 then abort_l <= '1'; end if;
      if rst = '1' then
        fs <= F_IDLE; own_r <= '0'; state2 <= "00"; reason <= (others => '0');
        eng_run <= '0'; abort_l <= '0'; sent <= '0';
      else
        case fs is
          when F_IDLE | F_STOPPED =>
            if cfg.clear = '1' then reason <= (others => '0'); state2 <= "00"; fs <= F_IDLE; end if;
            if cfg.start = '1' then fs <= F_CHECK; end if;
          when F_CHECK =>
            plen <= cfg.prompt_len; maxn <= cfg.max_new; role_l <= cfg.role; src_l <= cfg.row_src;
            p <= (others => '0'); n_gen <= (others => '0'); abort_l <= '0';
            err_addr <= Z32; err_status <= Z32; err_info <= Z32;
            reason <= (others => '0'); state2 <= "01"; run_start <= '1';
            if cfg.prompt_len = 0 or cfg.prompt_len > PROMPT_MAX or cfg.max_new = 0
               or cfg.role = 3 or cfg.row_src = 3
               or ((cfg.row_src = SRC_LINK) /= (cfg.role = ROLE_B))
               or (cfg.row_src = SRC_GATHER and not HAS_GATHER)
               or (cfg.role /= ROLE_SINGLE and not HAS_LINK) then
              stop(R_BAD_CONFIG);
            else
              fs <= F_TAKE;
            end if;
          when F_TAKE =>
            own_r <= '1';
            if owner = '1' then
              txn('1', SM_CTRL, tl_u32(CTRL_SEQ_RESET), F_RS1);
            end if;
          when F_TXN =>
            if sent = '0' then
              ax_req <= '1'; sent <= '1';
            elsif ax_done = '1' then
              sent <= '0';
              if ax_resp /= "00" then
                err_addr <= tl_u32(op_addr); stop(R_SEAM_ERR);
              else
                rd_r <= ax_rdata; fs <= op_ret;
              end if;
            end if;
          when F_RS1 => txn('0', SM_STATUS, Z32, F_RS2);
          when F_RS2 =>
            if rd_r(2) = '1' then err_status <= rd_r; stop(R_SEQ_RESET_FAIL);
            else txn('0', SM_TOK_POS, Z32, F_RS3); end if;
          when F_RS3 => tp_r <= rd_r; txn('0', SM_SEQ_POS, Z32, F_RS4);
          when F_RS4 =>
            if unsigned(tp_r) /= 0 or unsigned(rd_r) /= 0 then stop(R_SEQ_RESET_FAIL);
            else txn('0', SM_KV_MAXPOS, Z32, F_RS5); end if;
          when F_RS5 => kvmax <= unsigned(rd_r); fs <= F_TOP;
          when F_TOP =>
            pcyc <= (others => '0');
            if abort_l = '1' then stop(R_ABORT);
            elsif tx_exhausted = '1' and role_l = ROLE_A then stop(R_LINK_RETRY_EXHAUSTED);
            elsif p >= kvmax then stop(R_MAXPOS);
            elsif p < plen then
              pr_addr <= p(11 downto 0); fs <= F_TOK1;
            else
              tok <= g; fs <= F_ROWREQ;
            end if;
          when F_TOK1 => fs <= F_TOK2;
          when F_TOK2 => tok <= pr_data; fs <= F_ROWREQ;
          when F_ROWREQ =>
            rs_req <= '1'; rs_tok <= tok; row_tok <= tok; lcnt <= (others => '0'); fs <= F_ROWW;
          when F_ROWW => fs <= F_ROWEXP;      -- the source clears a previous error on req
          when F_ROWEXP =>
            if rs_err = '1' then stop(R_GATHER_ERR);
            elsif rs_exp_valid = '1' then
              txn('1', SM_X_EXP, rs_exp, F_WS);
            elsif abort_l = '1' then stop(R_ABORT);
            elsif src_l = SRC_LINK then
              if rs_paused = '0' then lcnt <= lcnt + 1; end if;
              if lcnt >= cfg.tmo_link then stop(R_LINK_TIMEOUT); end if;
            end if;
          when F_WS => txn('1', SM_WIN_SEL, tl_u32(WIN_XIN), F_WA);
          when F_WA => i <= 0; txn('1', SM_WIN_ADDR, Z32, F_DATA);
          when F_DATA =>
            if rs_m_valid = '1' then
              rs_m_ready <= '1';
              txn('1', SM_WIN_DATA, x"0000" & rs_m_data, F_DNEXT);
            end if;
          when F_DNEXT =>
            if i = N_EMBD - 1 then
              txn('1', SM_SEQ_POS, std_logic_vector(p), F_NS);
            else
              i <= i + 1; fs <= F_DATA;
            end if;
          when F_NS => txn('1', SM_N_STEP, tl_u32(1), F_GO);
          when F_GO =>
            ecnt <= (others => '0'); eng_run <= '1';
            txn('1', SM_CTRL, tl_u32(CTRL_GO), F_POLL);
          when F_POLL => txn('0', SM_STATUS, Z32, F_PCHK);
          when F_PCHK =>
            if rd_r(0) = '1' then
              eng_run <= '0'; pos_cycles <= pcyc; fs <= F_DONE;
            elsif rd_r(2) = '1' then
              err_status <= rd_r; fs <= F_EWAIT;
            elsif ecnt >= cfg.tmo_engine then
              err_status <= rd_r; eng_run <= '0'; stop(R_ENGINE_TIMEOUT);
            else
              fs <= F_POLL;
            end if;
          when F_EWAIT =>
            if rd_r(1) = '0' then eng_run <= '0'; txn('0', SM_ERR_INFO, Z32, F_EINFO);
            elsif ecnt >= cfg.tmo_engine then eng_run <= '0'; stop(R_ENGINE_TIMEOUT);
            else txn('0', SM_STATUS, Z32, F_EWAIT); end if;
          when F_EINFO => err_info <= rd_r; stop(R_ENGINE_ERR);
          when F_DONE =>
            if role_l = ROLE_A then fs <= F_XW; else fs <= F_GEN; end if;
          when F_XW =>                                    -- plan D3: B has popped every frame before p
            if tx_exhausted = '1' then stop(R_LINK_RETRY_EXHAUSTED);
            elsif abort_l = '1' then stop(R_ABORT);
            elsif cfg.link_credit >= p then txn('1', SM_WIN_SEL, tl_u32(WIN_XOUT), F_XA);
            end if;
          when F_XA => i <= 0; txn('1', SM_WIN_ADDR, Z32, F_XD);
          when F_XD => txn('0', SM_WIN_DATA, Z32, F_XD2);
          when F_XD2 =>
            if (i mod 2) = 0 then
              lo16 <= rd_r(15 downto 0);
            else
              tx_wr <= '1'; tx_widx <= to_unsigned(i / 2, 12); tx_wdata <= rd_r(15 downto 0) & lo16;
            end if;
            if i = N_EMBD - 1 then txn('0', SM_XEXP_OUT, Z32, F_XE);
            else i <= i + 1; fs <= F_XD; end if;
          when F_XE => xexp_r <= rd_r; fs <= F_TXW;
          when F_TXW =>
            if tx_busy = '0' then
              tx_send <= '1'; tx_pos <= p; tx_exp <= xexp_r; fs <= F_TXB1;
            elsif abort_l = '1' then stop(R_ABORT);
            end if;
          when F_TXB1 => fs <= F_TXB2;
          when F_TXB2 =>
            if tx_busy = '0' then fs <= F_GEN;
            elsif abort_l = '1' then stop(R_ABORT);
            end if;
          when F_GEN =>
            if p + 1 < plen then p <= p + 1; fs <= F_TOP;
            elsif role_l = ROLE_A then fs <= F_TOKW;
            else txn('0', SM_ARGMAX, Z32, F_ARG); end if;
          when F_TOKW =>
            if cfg.next_tok_v = '1' then
              g <= cfg.next_tok; tok_take <= '1'; fs <= F_PUSH;
            elsif tx_exhausted = '1' then stop(R_LINK_RETRY_EXHAUSTED);
            elsif abort_l = '1' then stop(R_ABORT);
            end if;
          when F_ARG => g <= unsigned(rd_r); last_arg <= rd_r; fs <= F_PUSH;
          when F_PUSH =>
            if n_gen - cfg.out_ack >= OUT_DEPTH then
              if abort_l = '1' then stop(R_ABORT); end if;
            else
              out_we <= '1'; out_waddr <= n_gen(15 downto 0); out_wdata <= std_logic_vector(g);
              n_gen <= n_gen + 1; fs <= F_SCHK;
            end if;
          when F_SCHK =>
            if is_stop(g) then stop(R_STOP_ID);
            elsif n_gen >= maxn then stop(R_MAX_NEW);
            else p <= p + 1; fs <= F_TOP; end if;
          when F_STOP =>
            own_r <= '0'; eng_run <= '0'; state2 <= "10"; fs <= F_STOPPED;
        end case;
      end if;
    end if;
  end process;
end architecture;
```

- [ ] **Step 10: Write the behavioural seam, the synthetic row source, the bench package and the trace checker**

`sim/seam_beh_model.vhd`:

```vhdl
-- sim/seam_beh_model.vhd -- a behavioural rtl/fk33_seam.vhd for the loop benches (plan
-- 2026-11-04 Task 2): the registers the loop touches, the v2 GO-time checks in the RTL's
-- order (fk33_seam.vhd:943-977: N_STEP, SEQ, POS, busy), and server/fk33_sim.c's argmax
-- arithmetic (fk33_sim.c:123-171) so its ids equal run_prompt's over jc_sim_broker. Window
-- 3 reads back window 2 and XEXP_OUT echoes X_EXP (the sim's hop model, fk33_sim.c:418-430).
-- Every completed write is published on wr_ev for sim/seam_trace_chk.vhd. Fault inputs:
-- f_err_pos (GO at that position ends in ERR code 6), f_hang_pos (never completes),
-- f_slverr_off (SLVERR at that offset; the real seam never does this, plan D6),
-- f_tokpos_stuck (TOK_POS reads cur_pos + 1).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity seam_beh_model is
  generic(N_EMBD : positive := 4096; NV : positive := 248320; SEED : std_logic_vector(15 downto 0) := x"ACE1");
  port(
    clk, rst       : in  std_logic;
    awaddr         : in  std_logic_vector(11 downto 0);
    awvalid        : in  std_logic;
    awready        : out std_logic := '0';
    wdata          : in  std_logic_vector(31 downto 0);
    wvalid         : in  std_logic;
    wready         : out std_logic := '0';
    bresp          : out std_logic_vector(1 downto 0) := "00";
    bvalid         : out std_logic := '0';
    bready         : in  std_logic;
    araddr         : in  std_logic_vector(11 downto 0);
    arvalid        : in  std_logic;
    arready        : out std_logic := '0';
    rdata          : out std_logic_vector(31 downto 0) := (others => '0');
    rresp          : out std_logic_vector(1 downto 0) := "00";
    rvalid         : out std_logic := '0';
    rready         : in  std_logic;
    wr_ev          : out std_logic := '0';
    wr_addr        : out std_logic_vector(11 downto 0) := (others => '0');
    wr_data        : out std_logic_vector(31 downto 0) := (others => '0');
    maxpos         : in  natural := 16384;
    go_lat         : in  natural := 40;
    f_err_pos      : in  integer := -1;
    f_hang_pos     : in  integer := -1;
    f_slverr_off   : in  integer := -1;
    f_tokpos_stuck : in  std_logic := '0';
    cur_pos_o      : out natural := 0;
    n_go_o         : out natural := 0);
end entity;

architecture sim of seam_beh_model is
  constant FNV_B : unsigned(31 downto 0) := x"811C9DC5";
  constant FNV_P : unsigned(31 downto 0) := x"01000193";
  type xin_t is array (0 to N_EMBD-1) of std_logic_vector(15 downto 0);
  function fnv(h, v : unsigned(31 downto 0)) return unsigned is
  begin
    return resize((h xor v) * FNV_P, 32);
  end function;
begin
  process(clk)
    variable xin : xin_t := (others => (others => '0'));
    variable seq_pos, n_step, x_exp, win_sel, win_addr, argmax, lexp, err_info : unsigned(31 downto 0) := (others => '0');
    variable st_done, st_err : std_logic := '0';
    variable code : unsigned(3 downto 0) := (others => '0');
    variable cur_pos, ngo : natural := 0;
    variable hist : unsigned(31 downto 0) := (others => '0');
    variable busy_left : integer := -1;          -- -1 idle, >= 0 cycles left, -2 hung
    variable go_err : boolean := false;
    variable aw_have, w_have, b_pend, r_pend : boolean := false;
    variable aw_a, ar_a : natural := 0;
    variable w_d, rv : std_logic_vector(31 downto 0) := (others => '0');
    variable lfsr : std_logic_vector(15 downto 0) := SEED;
    variable fx, pick : unsigned(31 downto 0);
    impure function stall return boolean is
    begin
      lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      return (lfsr(0) and lfsr(3)) = '1';
    end function;
  begin
    if rising_edge(clk) then
      wr_ev <= '0';
      if rst = '1' then
        busy_left := -1; st_done := '0'; st_err := '0'; aw_have := false; w_have := false;
        b_pend := false; r_pend := false; bvalid <= '0'; rvalid <= '0';
        awready <= '0'; wready <= '0'; arready <= '0';
      else
        -- a GO in flight
        if busy_left > 0 then
          busy_left := busy_left - 1;
        elsif busy_left = 0 then
          busy_left := -1;
          if go_err then
            st_err := '1'; code := to_unsigned(6, 4); err_info := x"0000DEAD";
          else
            fx := FNV_B;
            for k in 0 to N_EMBD - 1 loop fx := fnv(fx, resize(unsigned(xin(k)), 32)); end loop;
            hist := fnv(hist, to_unsigned(0, 32));          -- v2: no token id (fk33_sim.c:338-346)
            hist := fnv(hist, to_unsigned(cur_pos, 32));
            hist := fnv(hist, fx);
            pick := resize(hist * 31, 32) + resize(to_unsigned(cur_pos, 32) * 7, 32) + fx;
            argmax := pick mod to_unsigned(NV, 32);
            lexp := x_exp - 3;
            st_done := '1'; cur_pos := cur_pos + 1;
          end if;
        end if;
        -- handshakes
        if awvalid = '1' and awready = '1' then aw_have := true; aw_a := to_integer(unsigned(awaddr(11 downto 2))) * 4; end if;
        if wvalid = '1' and wready = '1' then w_have := true; w_d := wdata; end if;
        if bvalid = '1' and bready = '1' then bvalid <= '0'; b_pend := false; end if;
        if rvalid = '1' and rready = '1' then rvalid <= '0'; r_pend := false; end if;
        if aw_have and w_have and not b_pend then
          aw_have := false; w_have := false; b_pend := true;
          if aw_a = f_slverr_off then
            bresp <= "10";
          else
            bresp <= "00";
            wr_ev <= '1'; wr_addr <= std_logic_vector(to_unsigned(aw_a, 12)); wr_data <= w_d;
            case aw_a is
              when 16#14# =>
                if w_d(1) = '1' and busy_left = -1 then
                  cur_pos := 0; seq_pos := (others => '0'); hist := FNV_B;
                end if;
                if w_d(0) = '1' then
                  st_done := '0'; st_err := '0'; code := (others => '0');
                  if n_step /= 1 then st_err := '1'; code := to_unsigned(2, 4);
                  elsif seq_pos /= cur_pos then st_err := '1'; code := to_unsigned(8, 4);
                  elsif cur_pos >= maxpos then st_err := '1'; code := to_unsigned(1, 4);
                  elsif busy_left /= -1 then st_err := '1'; code := to_unsigned(8, 4);
                  else
                    ngo := ngo + 1; go_err := (cur_pos = f_err_pos);
                    if cur_pos = f_hang_pos then busy_left := -2; else busy_left := go_lat; end if;
                  end if;
                end if;
              when 16#20# => seq_pos := unsigned(w_d);
              when 16#24# => n_step := unsigned(w_d);
              when 16#54# => x_exp := unsigned(w_d);
              when 16#58# => win_sel := unsigned(w_d);
              when 16#5C# => win_addr := unsigned(w_d);
              when 16#60# =>
                if win_sel = 2 and win_addr < N_EMBD then xin(to_integer(win_addr)) := w_d(15 downto 0); end if;
                win_addr := win_addr + 1;
              when others => null;
            end case;
          end if;
        end if;
        if arvalid = '1' and arready = '1' then
          ar_a := to_integer(unsigned(araddr(11 downto 2))) * 4; r_pend := true;
          rv := (others => '0');
          case ar_a is
            when 16#18# =>
              rv(0) := st_done; rv(2) := st_err; rv(11 downto 8) := std_logic_vector(code);
              if busy_left /= -1 then rv(1) := '1'; end if;
            when 16#1C# => rv := std_logic_vector(err_info);
            when 16#20# => rv := std_logic_vector(seq_pos);
            when 16#44# => rv := std_logic_vector(argmax);
            when 16#48# => rv := std_logic_vector(lexp);
            when 16#54# | 16#A4# => rv := std_logic_vector(x_exp);
            when 16#58# => rv := std_logic_vector(win_sel);
            when 16#5C# => rv := std_logic_vector(win_addr);
            when 16#60# =>
              if win_sel = 3 and win_addr < N_EMBD then rv(15 downto 0) := xin(to_integer(win_addr)); end if;
              win_addr := win_addr + 1;
            when 16#8C# =>
              if f_tokpos_stuck = '1' then rv := std_logic_vector(to_unsigned(cur_pos + 1, 32));
              else rv := std_logic_vector(to_unsigned(cur_pos, 32)); end if;
            when 16#A0# => rv := std_logic_vector(to_unsigned(maxpos, 32));
            when others => null;
          end case;
          rdata <= rv;
          if ar_a = f_slverr_off then rresp <= "10"; else rresp <= "00"; end if;
        end if;
        if b_pend and bvalid = '0' and not stall then bvalid <= '1'; end if;
        if r_pend and rvalid = '0' and not stall then rvalid <= '1'; end if;
        awready <= '0'; wready <= '0'; arready <= '0';
        if not aw_have and not b_pend and awvalid = '1' and awready = '0' and not stall then awready <= '1'; end if;
        if not w_have and not b_pend and wvalid = '1' and wready = '0' and not stall then wready <= '1'; end if;
        if not r_pend and arvalid = '1' and arready = '0' and not stall then arready <= '1'; end if;
        cur_pos_o <= cur_pos; n_go_o <= ngo;
      end if;
    end if;
  end process;
end architecture;
```

`sim/row_synth_src.vhd`:

```vhdl
-- sim/row_synth_src.vhd -- a row source that returns server/pl_backend.c:66-80's
-- pl_embed_synthetic row (the host's default embedding under jc_sim_broker), after LAT
-- cycles, one mantissa per m_ready (plan 2026-11-04 Task 2).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity row_synth_src is
  generic(N_EMBD : positive := 4096; LAT : natural := 12);
  port(
    clk, rst  : in  std_logic;
    req       : in  std_logic;
    tok       : in  unsigned(31 downto 0);
    exp_valid : out std_logic := '0';
    exp_val   : out std_logic_vector(31 downto 0) := (others => '0');
    m_valid   : out std_logic := '0';
    m_data    : out std_logic_vector(15 downto 0) := (others => '0');
    m_ready   : in  std_logic);
end entity;

architecture sim of row_synth_src is
  type row_t is array (0 to N_EMBD-1) of std_logic_vector(15 downto 0);
begin
  process(clk)
    variable row : row_t;
    variable h : unsigned(31 downto 0);
    variable wait_n : integer := -1;
    variable idx : natural := 0;
    variable active : boolean := false;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        exp_valid <= '0'; m_valid <= '0'; active := false; wait_n := -1;
      elsif req = '1' then
        h := x"811C9DC5" xor tok;
        for k in 0 to N_EMBD - 1 loop
          h := h xor to_unsigned(k, 32);
          h := resize(h * x"01000193", 32);
          row(k) := std_logic_vector(h(31 downto 16)) xor x"8000";   -- (h >> 16) - 32768
        end loop;
        wait_n := LAT; idx := 0; active := false; exp_valid <= '0'; m_valid <= '0';
      elsif wait_n > 0 then
        wait_n := wait_n - 1;
      elsif wait_n = 0 then
        wait_n := -1; active := true; exp_valid <= '1'; exp_val <= x"FFFFFFF8";
        m_valid <= '1'; m_data <= row(0);
      elsif active and m_ready = '1' then
        if idx = N_EMBD - 1 then
          active := false; m_valid <= '0'; exp_valid <= '0';
        else
          idx := idx + 1; m_data <= row(idx); m_valid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
```

`sim/tok_loop_tb_pkg.vhd`:

```vhdl
-- sim/tok_loop_tb_pkg.vhd -- the loop benches' vector loader and helpers (plan 2026-11-04
-- Task 2). Vector format: tools/jc/gen_tok_loop_vec.py's header.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

package tok_loop_tb_pkg is
  constant MAX_CASES : natural := 16;
  constant MAX_OPS   : natural := 4096;
  constant MAX_INTS  : natural := 2048;
  type op_t is record
    kind : character;
    die, off, cnt : natural;
    val : std_logic_vector(31 downto 0);
  end record;
  type op_arr is array (0 to MAX_OPS-1) of op_t;
  type int_arr is array (0 to MAX_INTS-1) of integer;
  type case_t is record
    plen, max_new, n_ids, p0, i0, op0, op1 : natural;
    stop : integer;
    pair : boolean;
  end record;
  type case_arr is array (0 to MAX_CASES-1) of case_t;
  type vec_t is record
    n_cases, n_ops, n_ints : natural;
    cs : case_arr;
    ops : op_arr;
    ints : int_arr;
  end record;
  type row16_arr is array (natural range <>) of std_logic_vector(15 downto 0);
  constant FNV_BASIS : std_logic_vector(31 downto 0) := x"811C9DC5";
  impure function load_vec(fname : string) return vec_t;
  function fnv_step(h, v : std_logic_vector(31 downto 0)) return std_logic_vector;
  procedure synth_row(tok : natural; row : out row16_arr; xexp : out std_logic_vector(31 downto 0));
end package;

package body tok_loop_tb_pkg is
  function fnv_step(h, v : std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    return std_logic_vector(resize((unsigned(h) xor unsigned(v)) * unsigned'(x"01000193"), 32));
  end function;

  procedure synth_row(tok : natural; row : out row16_arr; xexp : out std_logic_vector(31 downto 0)) is
    variable h : unsigned(31 downto 0) := x"811C9DC5" xor to_unsigned(tok, 32);
  begin
    for k in row'range loop
      h := h xor to_unsigned(k - row'low, 32);
      h := resize(h * x"01000193", 32);
      row(k) := std_logic_vector(h(31 downto 16)) xor x"8000";
    end loop;
    xexp := x"FFFFFFF8";
  end procedure;

  impure function load_vec(fname : string) return vec_t is
    file f : text open read_mode is fname;
    variable l : line;
    variable ch : character;
    variable v : vec_t;
    variable n : integer;
    variable cur : natural := 0;
    variable h12 : std_logic_vector(11 downto 0);
    variable h32 : std_logic_vector(31 downto 0);
  begin
    v.n_cases := 0; v.n_ops := 0; v.n_ints := 0;
    while not endfile(f) loop
      readline(f, l);
      if l'length > 0 then
        read(l, ch);
        case ch is
          when 'C' =>
            cur := v.n_cases; v.n_cases := v.n_cases + 1;
            read(l, n); v.cs(cur).plen := n;
            read(l, n); v.cs(cur).max_new := n;
            read(l, n); v.cs(cur).stop := n;
            read(l, n); v.cs(cur).n_ids := n;
            read(l, n); v.cs(cur).pair := (n = 1);
            v.cs(cur).op0 := v.n_ops; v.cs(cur).op1 := v.n_ops;
          when 'P' =>
            v.cs(cur).p0 := v.n_ints;
            for j in 1 to v.cs(cur).plen loop
              read(l, n); v.ints(v.n_ints) := n; v.n_ints := v.n_ints + 1;
            end loop;
          when 'I' =>
            v.cs(cur).i0 := v.n_ints;
            for j in 1 to v.cs(cur).n_ids loop
              read(l, n); v.ints(v.n_ints) := n; v.n_ints := v.n_ints + 1;
            end loop;
          when 'W' =>
            read(l, n); v.ops(v.n_ops).die := n; v.ops(v.n_ops).kind := 'W';
            hread(l, h12); v.ops(v.n_ops).off := to_integer(unsigned(h12));
            hread(l, h32); v.ops(v.n_ops).val := h32; v.ops(v.n_ops).cnt := 1;
            v.n_ops := v.n_ops + 1; v.cs(cur).op1 := v.n_ops;
          when 'D' =>
            read(l, n); v.ops(v.n_ops).die := n; v.ops(v.n_ops).kind := 'D';
            read(l, n); v.ops(v.n_ops).cnt := n; v.ops(v.n_ops).off := 16#60#;
            hread(l, h32); v.ops(v.n_ops).val := h32;
            v.n_ops := v.n_ops + 1; v.cs(cur).op1 := v.n_ops;
          when others => null;
        end case;
      end if;
      deallocate(l);
    end loop;
    return v;
  end function;
end package body;
```

`sim/seam_trace_chk.vhd`:

```vhdl
-- sim/seam_trace_chk.vhd -- compares one die's seam writes with the vector file's ops for
-- the armed case (plan 2026-11-04 Task 2). The ops are run_prompt's own writes captured over
-- jc_sim_broker (tools/jc/gen_tok_loop_vec.py), so this is the host as oracle.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.tok_loop_tb_pkg.all;

entity seam_trace_chk is
  generic(VEC : string := "tok_loop_vec.txt"; DIE : natural := 0);
  port(
    clk      : in  std_logic;
    arm      : in  std_logic;
    case_sel : in  natural;
    wr_ev    : in  std_logic;
    wr_addr  : in  std_logic_vector(11 downto 0);
    wr_data  : in  std_logic_vector(31 downto 0);
    errs     : out natural := 0;
    at_end   : out boolean := false;
    n_writes : out natural := 0);
end entity;

architecture sim of seam_trace_chk is
begin
  process(clk)
    variable V : vec_t := load_vec(VEC);
    variable j, last, run_n, e, nw : natural := 0;
    variable h : std_logic_vector(31 downto 0) := FNV_BASIS;
    procedure skip is
    begin
      while j < last and V.ops(j).die /= DIE loop j := j + 1; end loop;
    end procedure;
  begin
    if rising_edge(clk) then
      if arm = '1' then
        j := V.cs(case_sel).op0; last := V.cs(case_sel).op1; run_n := 0; h := FNV_BASIS; skip;
      elsif wr_ev = '1' then
        nw := nw + 1;
        if j >= last then
          e := e + 1; report "trace: write past the case's end, off " & to_hstring(wr_addr) severity error;
        elsif V.ops(j).kind = 'W' then
          if to_integer(unsigned(wr_addr)) /= V.ops(j).off or wr_data /= V.ops(j).val then
            e := e + 1;
            report "trace MISMATCH op " & integer'image(j) & ": got " & to_hstring(wr_addr) & "=" &
                   to_hstring(wr_data) & ", host wrote " & integer'image(V.ops(j).off) & "=" &
                   to_hstring(V.ops(j).val) severity error;
          end if;
          j := j + 1; skip;
        elsif to_integer(unsigned(wr_addr)) /= 16#60# then
          e := e + 1;
          report "trace MISMATCH op " & integer'image(j) & ": a WIN_DATA run ended early at " &
                 integer'image(run_n) severity error;
          run_n := 0; h := FNV_BASIS; j := j + 1; skip;
        else
          h := fnv_step(h, wr_data); run_n := run_n + 1;
          if run_n = V.ops(j).cnt then
            if h /= V.ops(j).val then
              e := e + 1; report "trace MISMATCH op " & integer'image(j) & ": WIN_DATA row hash" severity error;
            end if;
            run_n := 0; h := FNV_BASIS; j := j + 1; skip;
          end if;
        end if;
      end if;
      errs <= e; at_end <= (j >= last); n_writes <= nw;
    end if;
  end process;
end architecture;
```

- [ ] **Step 11: Write the loop bench**

`sim/tb_tok_loop.vhd`:

```vhdl
-- sim/tb_tok_loop.vhd -- tok_loop_regs + tok_loop_fsm against the behavioural seam (plan
-- 2026-11-04 Task 2). Oracles: (1) every seam write equals run_prompt's capture for the same
-- case (sim/seam_trace_chk.vhd); (2) the ids in OUT equal run_prompt's ids file; (3) the stop
-- reason is the one run_prompt printed (stop token vs --max-new). Cases run back to back on
-- one seam model, so each START's SEQ_RESET is exercised against a dirty seam.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axil_bfm_pkg.all;
use work.tok_loop_pkg.all;
use work.tok_loop_tb_pkg.all;

entity tb_tok_loop is
  generic(VEC : string := "tok_loop_vec.txt");
end entity;

architecture sim of tb_tok_loop is
  constant N : positive := 4096;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal cm : axil_m2s_t := AXIL_M2S_IDLE;
  signal cs : axil_s2m_t;
  signal cfg : tl_cfg_t;
  signal st : tl_stat_t;
  signal pr_addr : unsigned(11 downto 0);
  signal pr_data : unsigned(31 downto 0);
  signal out_we : std_logic;
  signal out_waddr : unsigned(15 downto 0);
  signal out_wdata : std_logic_vector(31 downto 0);
  signal hr_data : std_logic_vector(15 downto 0);
  signal loop_own, run_start : std_logic;
  signal rs_req, rs_ev, rs_mv, rs_mr : std_logic;
  signal rs_tok : unsigned(31 downto 0);
  signal rs_exp : std_logic_vector(31 downto 0);
  signal rs_md : std_logic_vector(15 downto 0);
  signal tx_wr, tx_send : std_logic;
  signal tx_widx : unsigned(11 downto 0);
  signal tx_wdata, tx_exp : std_logic_vector(31 downto 0);
  signal tx_pos : unsigned(31 downto 0);
  signal s_awaddr, s_araddr : std_logic_vector(11 downto 0);
  signal s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready : std_logic;
  signal s_arvalid, s_arready, s_rvalid, s_rready : std_logic;
  signal s_wdata, s_rdata : std_logic_vector(31 downto 0);
  signal s_wstrb : std_logic_vector(3 downto 0);
  signal s_bresp, s_rresp : std_logic_vector(1 downto 0);
  signal wr_ev : std_logic;
  signal wr_addr : std_logic_vector(11 downto 0);
  signal wr_data : std_logic_vector(31 downto 0);
  signal arm : std_logic := '0';
  signal case_sel : natural := 0;
  signal chk_errs, chk_nw : natural;
  signal chk_end : boolean;
begin
  clk <= not clk after 2.5 ns;

  regs : entity work.tok_loop_regs
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst,
             s_awaddr => cm.awaddr(15 downto 0), s_awvalid => cm.awvalid, s_awready => cs.awready,
             s_wdata => cm.wdata, s_wstrb => cm.wstrb, s_wvalid => cm.wvalid, s_wready => cs.wready,
             s_bresp => cs.bresp, s_bvalid => cs.bvalid, s_bready => cm.bready,
             s_araddr => cm.araddr(15 downto 0), s_arvalid => cm.arvalid, s_arready => cs.arready,
             s_rdata => cs.rdata, s_rresp => cs.rresp, s_rvalid => cs.rvalid, s_rready => cm.rready,
             cfg => cfg, st => st, lnk => TL_LNK_ZERO, pr_addr => pr_addr, pr_data => pr_data,
             out_we => out_we, out_waddr => out_waddr, out_wdata => out_wdata,
             hr_addr => (others => '0'), hr_data => hr_data);

  fsm : entity work.tok_loop_fsm
    generic map(N_EMBD => N, HAS_GATHER => true, HAS_LINK => false)
    port map(clk => clk, rst => rst, cfg => cfg, st => st, run_start => run_start,
             pr_addr => pr_addr, pr_data => pr_data,
             out_we => out_we, out_waddr => out_waddr, out_wdata => out_wdata,
             loop_own => loop_own, owner => loop_own,
             rs_req => rs_req, rs_tok => rs_tok, rs_exp_valid => rs_ev, rs_exp => rs_exp,
             rs_err => '0', rs_m_valid => rs_mv, rs_m_data => rs_md, rs_m_ready => rs_mr,
             rs_paused => '0',
             tx_wr => tx_wr, tx_widx => tx_widx, tx_wdata => tx_wdata, tx_send => tx_send,
             tx_pos => tx_pos, tx_exp => tx_exp, tx_busy => '0', tx_exhausted => '0',
             m_awaddr => s_awaddr, m_awvalid => s_awvalid, m_awready => s_awready,
             m_wdata => s_wdata, m_wstrb => s_wstrb, m_wvalid => s_wvalid, m_wready => s_wready,
             m_bresp => s_bresp, m_bvalid => s_bvalid, m_bready => s_bready,
             m_araddr => s_araddr, m_arvalid => s_arvalid, m_arready => s_arready,
             m_rdata => s_rdata, m_rresp => s_rresp, m_rvalid => s_rvalid, m_rready => s_rready);

  src : entity work.row_synth_src
    generic map(N_EMBD => N, LAT => 12)
    port map(clk => clk, rst => rst, req => rs_req, tok => rs_tok, exp_valid => rs_ev,
             exp_val => rs_exp, m_valid => rs_mv, m_data => rs_md, m_ready => rs_mr);

  seam : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst, awaddr => s_awaddr, awvalid => s_awvalid, awready => s_awready,
             wdata => s_wdata, wvalid => s_wvalid, wready => s_wready, bresp => s_bresp,
             bvalid => s_bvalid, bready => s_bready, araddr => s_araddr, arvalid => s_arvalid,
             arready => s_arready, rdata => s_rdata, rresp => s_rresp, rvalid => s_rvalid,
             rready => s_rready, wr_ev => wr_ev, wr_addr => wr_addr, wr_data => wr_data);

  chk : entity work.seam_trace_chk
    generic map(VEC => VEC, DIE => 0)
    port map(clk => clk, arm => arm, case_sel => case_sel, wr_ev => wr_ev, wr_addr => wr_addr,
             wr_data => wr_data, errs => chk_errs, at_end => chk_end, n_writes => chk_nw);

  host : process
    variable V : vec_t := load_vec(VEC);
    variable resp : std_logic_vector(1 downto 0);
    variable d : std_logic_vector(31 downto 0);
    variable e, c, n, ncase, want_reason : natural := 0;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_tok_loop: " & msg severity error; end if;
    end procedure;
    procedure wr(a : natural; x : std_logic_vector(31 downto 0)) is
    begin
      axil_wr(clk, cm, cs, a, x, resp);
      chk(resp = "00", "control write OKAY");
    end procedure;
    procedure rd(a : natural; x : out std_logic_vector(31 downto 0)) is
    begin
      axil_rd(clk, cm, cs, a, x, resp);
    end procedure;
  begin
    for k in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);
    rd(TL_ID, d); chk(d = TL_ID_MAGIC, "ID reads TLP1");
    for k in 0 to V.n_cases - 1 loop
      next when V.cs(k).pair;
      ncase := ncase + 1;
      case_sel <= k; arm <= '1'; wait until rising_edge(clk); arm <= '0';
      wr(TL_PROMPT_LEN, u32(V.cs(k).plen));
      wr(TL_MAX_NEW, u32(V.cs(k).max_new));
      if V.cs(k).stop >= 0 then wr(TL_STOP_ID0, u32(V.cs(k).stop)); else wr(TL_STOP_ID0, x"FFFFFFFF"); end if;
      wr(TL_ROW_SRC, u32(SRC_GATHER));
      wr(TL_ROLE, u32(ROLE_SINGLE));
      wr(TL_PROMPT_ADDR, u32(0));
      for j in 0 to V.cs(k).plen - 1 loop wr(TL_PROMPT_DATA, u32(V.ints(V.cs(k).p0 + j))); end loop;
      wr(TL_CTRL, u32(1));
      n := 0;
      loop
        rd(TL_STATUS, d);
        exit when d(1 downto 0) = "10";
        n := n + 1;
        assert n < 2000000 report "tb_tok_loop: case never stopped" severity failure;
      end loop;
      want_reason := R_MAX_NEW;
      if V.cs(k).stop >= 0 and V.ints(V.cs(k).i0 + V.cs(k).n_ids - 1) = V.cs(k).stop then
        want_reason := R_STOP_ID;
      end if;
      chk(to_integer(unsigned(d(15 downto 8))) = want_reason, "case " & integer'image(k) & " stop reason");
      chk(d(16) = '0', "seam released after the stop");
      rd(TL_N_GEN, d);
      chk(to_integer(unsigned(d)) = V.cs(k).n_ids, "case " & integer'image(k) & " id count");
      wr(TL_OUT_ADDR, u32(0));
      for j in 0 to V.cs(k).n_ids - 1 loop
        rd(TL_OUT_DATA, d);
        chk(to_integer(unsigned(d)) = V.ints(V.cs(k).i0 + j),
            "case " & integer'image(k) & " id " & integer'image(j) & " equals run_prompt's");
      end loop;
      wait until rising_edge(clk);
      chk(chk_end, "case " & integer'image(k) & ": every host write was replayed");
    end loop;
    chk(ncase >= 4, "at least four single-die cases ran");
    chk(chk_errs = 0, "no seam write differed from the host's");
    e := e + chk_errs;
    if e = 0 then
      report "PASS: tb_tok_loop checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_tok_loop errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
```

- [ ] **Step 12: Run the bench**

Run: `REGRESS_SCRATCH=~/regress_scratch/t2-a bash sim/regress.sh --only tb_tok_loop --keep`
Expected: the substring also matches no other row today; `OVERALL PASS 1`, log ends `PASS: tb_tok_loop checks=` with n >= 30. A trace MISMATCH line names the op index and both values: compare against `sim/tok_loop_vec.txt` line by line and fix the RTL (never the vectors).

- [ ] **Step 13: Write and run the mutants**

`sim/mutants/tok_loop.json`:

```json
{
  "tb": "tb_tok_loop",
  "deps": ["sim/axil_bfm_pkg.vhd", "rtl/tok_loop_pkg.vhd", "sim/tok_loop_tb_pkg.vhd",
           "rtl/tok_loop_regs.vhd", "rtl/tok_loop_axm.vhd", "rtl/tok_loop_fsm.vhd",
           "sim/row_synth_src.vhd", "sim/seam_beh_model.vhd", "sim/seam_trace_chk.vhd",
           "sim/tb_tok_loop.vhd"],
  "vectors": ["sim/tok_loop_vec.txt"],
  "stop_time": "2000ms",
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "T1", "expect": "KILLED", "file": "rtl/tok_loop_fsm.vhd",
     "why": "no SEQ_RESET (spec 4)",
     "old": "txn('1', SM_CTRL, tl_u32(CTRL_SEQ_RESET), F_RS1);",
     "new": "fs <= F_RS1;"},
    {"tag": "T2", "expect": "KILLED", "file": "rtl/tok_loop_fsm.vhd",
     "why": "prompt index off by one (spec 4)",
     "old": "pr_addr <= p(11 downto 0); fs <= F_TOK1;",
     "new": "pr_addr <= p(11 downto 0) + 1; fs <= F_TOK1;"},
    {"tag": "T3", "expect": "KILLED", "file": "rtl/tok_loop_fsm.vhd",
     "why": "stop id not pushed, against run_prompt's ids file (spec 4)",
     "old": "            if n_gen - cfg.out_ack >= OUT_DEPTH then",
     "new": "            if is_stop(g) then stop(R_STOP_ID);\n            elsif n_gen - cfg.out_ack >= OUT_DEPTH then"},
    {"tag": "T4", "expect": "KILLED", "file": "rtl/tok_loop_fsm.vhd",
     "why": "max_new off by one (spec 4)",
     "old": "elsif n_gen >= maxn then stop(R_MAX_NEW);",
     "new": "elsif n_gen > maxn then stop(R_MAX_NEW);"},
    {"tag": "T5", "expect": "KILLED", "file": "rtl/tok_loop_fsm.vhd",
     "why": "the row exponent is never written (X_EXP skipped)",
     "old": "txn('1', SM_X_EXP, rs_exp, F_WS);",
     "new": "fs <= F_WS;"}
  ]
}
```

Run: `python3 sim/mutate_rows.py sim/mutants/tok_loop.json`
Expected: `MUTANTS_OK 6`.

- [ ] **Step 14: Commit**

```bash
git add rtl/tok_loop_pkg.vhd rtl/tok_loop_regs.vhd rtl/tok_loop_axm.vhd rtl/tok_loop_fsm.vhd \
  sim/seam_beh_model.vhd sim/row_synth_src.vhd sim/tok_loop_tb_pkg.vhd sim/seam_trace_chk.vhd \
  sim/tb_tok_loop.vhd sim/tok_loop_vec.txt sim/mutants/tok_loop.json \
  tools/jc/tok_loop_model.py tools/jc/gen_tok_loop_vec.py tools/jc/test_tok_loop_model.py \
  server/tests/jc_sim_broker.c
git commit -m "jc loop T2: tok_loop regs + seam-master FSM, checked against run_prompt's captured writes" -- \
  rtl/tok_loop_pkg.vhd rtl/tok_loop_regs.vhd rtl/tok_loop_axm.vhd rtl/tok_loop_fsm.vhd \
  sim/seam_beh_model.vhd sim/row_synth_src.vhd sim/tok_loop_tb_pkg.vhd sim/seam_trace_chk.vhd \
  sim/tb_tok_loop.vhd sim/tok_loop_vec.txt sim/mutants/tok_loop.json \
  tools/jc/tok_loop_model.py tools/jc/gen_tok_loop_vec.py tools/jc/test_tok_loop_model.py \
  server/tests/jc_sim_broker.c
```

---
### Task 3: embed_gather, bit-exact against pl_embed_mv4i

**Files:**
- Create: `rtl/embed_gather.vhd`, `tools/jc/gen_embed_gather_vec.py`, `sim/embed_gather_tc.vhd`, `sim/tb_embed_gather.vhd`, `sim/tb_embed_gather_27b.vhd`, `sim/embed_gather_k4096_vec.txt` and `sim/embed_gather_k5120_vec.txt` (generated), `sim/mutants/embed_gather.json`

**Interfaces:**
- Consumes: the `.mv4i` header and addressing of `server/embed_mv4i.c` (header fields `:189-209`, geometry and refusals `:211-312`, `addr_of` `:350-378`, row `:400-476`, BFP pack `:478-516`: `amax` over the WHOLE row of `cb[idx]*scale`, `sh = msb_pos(amax) - 14` unclamped, `mant = sat16(floor((v + 2^(sh-1)) / 2^sh))`, `exp = (w_exp + 15) - sh`, an all-zero row keeps `w_exp + 15`); its C front end `server/tests/embed_dump.c` (output `TOK <id> EXP <x_exp> ...` then `MANT ...`, `:11-16`); `tools/embed_gather.py` `PackedTensor.row_bfp(tok, recipe=RECIPE_WIDE)` returning `(mant list, x_exp)` (`:294-296`, `:159-176`) as the second, independent decoder; `sim/jc_axi3_mem.vhd` (AXI3 rules and `poke_*`, `:9-60`).
- Produces: entity `embed_gather` (generics `N_EMBD` (a multiple of 512), `ADDR_W` 33; ports below). The read port has the ctl core's `m_axi` shape (`rtl/jc_ctl_core.vhd:99-109`) so Task 7 wires it to `hbm_sc/S02_AXI` like `ctl/m_axi` on S01. Row-source protocol (shared by all sources): `req` pulse with `tok`; `exp_valid` level with `exp_val` from when the exponent is known until the last mantissa is taken; `m_valid`/`m_data` one mantissa, advanced by a one-cycle `m_ready`; `err` level with `err_code` (1 header, 2 token range, 3 RRESP) cleared by the next `req`.

The HBM layout it reads (the packer change of spec 1.4 must produce exactly this; D1): the whole `.mv4i` file, header included, at `EMB_BASE` (4 KB aligned), so HBM address = EMB_BASE + file offset. The gather reads 9 beats of header once per run (`invalidate` at START), checks MAGIC "MV4I", K = N_EMBD, ROWS_IF 48, NPORTS_W 24, BLOCK 32, AXI_DW 256, n_scale_sub 3, 0 < M < 2^18, every sub-region offset < 2^33 and 512-byte aligned. Per row: t = tok / 48 (18-cycle restoring division), rr = tok mod 48, weight sub-region rr/2, half rr mod 2, scale sub-region rr/16, index rr mod 16, both reads at `offset + t * NB * 32`, NB = N_EMBD/32 beats each in NB/16 bursts of 16 (AXI3), scales first.

Datapath states: `G_IDLE, G_HAR, G_HR, G_HCHK, G_DIV, G_ADDR, G_AR, G_R, G_DEQ, G_EXP, G_EM1, G_EM2, G_EMIT, G_ERR`.

- [ ] **Step 1: Write the vector generator**

`tools/jc/gen_embed_gather_vec.py`:

```python
#!/usr/bin/env python3
"""tools/jc/gen_embed_gather_vec.py -- vectors for sim/tb_embed_gather*.vhd (plan 2026-11-04
Task 3): a synthetic .mv4i with the shipped geometry (ROWS_IF 48, AXI_DW 256, BLOCK 32,
NPORTS_W 24, n_scale_sub 3), K 4096 (9B) or 5120 (27B), M 96, and the rows the HOST's
pl_embed_mv4i returns for chosen ids (server/tests/embed_dump.c, built here).

    python3 tools/jc/gen_embed_gather_vec.py --k 4096 [--out PATH] [--mv4i PATH] [--check]

tools/embed_gather.py's PackedTensor (numpy, a different addressing expression) must agree
with the C on every row, or nothing is written (GEN_GATHER_ORACLES_DISAGREE): that is what
shows the synthetic file is well formed. --mv4i also keeps the binary (Task 6 feeds it to
run_prompt). Scratch: ~/regress_scratch. NO HARDWARE.
"""
import argparse, os, random, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools"))
import embed_gather as EG  # noqa: E402

M, ROWS_IF, AXI_DW, BLOCK, NPW, NSS = 96, 48, 256, 32, 24, 3
CODEBOOK = [-120, -96, -72, -56, -40, -28, -16, -6, 6, 16, 28, 40, 56, 72, 85, 120]
W_EXP = -20
EMB_BASE = 0x123400000            # 512 KB aligned: sim/jc_axi3_mem IDX_W 14 indexes bits [18:5]
SEED = 20261104


def geometry(k):
    nb = k // BLOCK
    tiles = (M + ROWS_IF - 1) // ROWS_IF
    sub = tiles * nb * (AXI_DW // 8)
    sub_al = (sub + 4095) // 4096 * 4096
    w_off = [4096 + i * sub_al for i in range(NPW)]
    s_off = [4096 + (NPW + j) * sub_al for j in range(NSS)]
    return nb, sub, w_off, s_off, 4096 + (NPW + NSS) * sub_al


def row_bytes(k, tok):
    """(weight byte offsets per block, scale byte offset per block) of one row, embed_mv4i.c:350-378."""
    nb, _, w_off, s_off, _ = geometry(k)
    t, rr = divmod(tok, ROWS_IF)
    p, half, q, kk = rr // 2, rr % 2, rr // 16, rr % 16
    wb = [w_off[p] + (t * nb + b) * 32 + half * 16 for b in range(nb)]
    sb = [s_off[q] + (t * nb + b) * 32 + 2 * kk for b in range(nb)]
    return wb, sb


def build(k):
    nb, sub, w_off, s_off, size = geometry(k)
    img = bytearray(size)
    img[0x00:0x20] = struct.pack("<IHHIIiiHHHH", 0x4D563449, 1, 0, M, k, W_EXP, 0,
                                 ROWS_IF, NPW, BLOCK, AXI_DW)
    img[0x20:0x30] = bytes(c & 0xFF for c in CODEBOOK)
    img[0x30:0x38] = struct.pack("<II", 0, NSS)
    for i, o in enumerate(w_off + s_off):
        img[0x38 + 8 * i:0x40 + 8 * i] = struct.pack("<Q", o)
    rng = random.Random(SEED + k)
    for o in w_off + s_off:
        img[o:o + sub] = bytes(rng.getrandbits(8) for _ in range(sub))
    # tok 50: block 3 all-negative (nibbles 1 and 3 -> -96, -56)
    wb, sb = row_bytes(k, 50)
    img[wb[3]:wb[3] + 16] = bytes([0x31] * 16)
    # tok 51: every scale 0 -> the all-zero row (exp stays w_exp + 15)
    wb, sb = row_bytes(k, 51)
    for o in sb:
        img[o:o + 2] = b"\x00\x00"
    # tok 61: one element 85 * 771 = 65535 -> msb 15, sh 1, rounds to 32768, saturates to 32767
    wb, sb = row_bytes(k, 61)
    img[wb[0]:wb[0] + 16] = bytes([0x8E] + [0x88] * 15)   # element 0 nibble 14 (85), the rest 8 (6)
    img[sb[0]:sb[0] + 2] = struct.pack("<H", 771)
    for o in sb[1:]:
        img[o:o + 2] = struct.pack("<H", 1)
    return bytes(img)


def toks():
    rng = random.Random(SEED)
    return [0, 1, 2, 47, 48, 49, 50, 51, 61, 95] + sorted(rng.sample(range(3, 95), 6))


def c_rows(path, ids, scratch):
    exe = os.path.join(scratch, "embed_dump")
    r = subprocess.run(["cc", "-O2", "-I", os.path.join(REPO, "server"), "-o", exe,
                        os.path.join(REPO, "server", "tests", "embed_dump.c"),
                        os.path.join(REPO, "server", "embed_mv4i.c")], capture_output=True, text=True)
    if r.returncode:
        sys.exit("GEN_GATHER_FAIL cc\n" + r.stderr)
    r = subprocess.run([exe, "--mv4i", path, "--tokens", ",".join(str(t) for t in ids), "--recipe", "wide"],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit("GEN_GATHER_FAIL embed_dump rc=%d\n%s" % (r.returncode, r.stderr))
    out, cur = {}, None
    for ln in r.stdout.splitlines():
        f = ln.split()
        if f and f[0] == "TOK":
            cur = int(f[1]); out[cur] = [int(f[3]), None]
        elif f and f[0] == "MANT":
            out[cur][1] = [int(x) for x in f[1:]]
    return out


def generate(k, out_path, keep_mv4i):
    scratch = tempfile.mkdtemp(prefix="egv_", dir=os.path.expanduser("~/regress_scratch"))
    img = build(k)
    path = keep_mv4i or os.path.join(scratch, "synth_k%d.mv4i" % k)
    with open(path, "wb") as f:
        f.write(img)
    ids = toks()
    crow = c_rows(path, ids, scratch)
    pt = EG.PackedTensor(path)
    for t in ids:
        mant, xexp = pt.row_bfp(t, recipe=EG.RECIPE_WIDE)
        if [xexp, list(mant)] != crow[t]:
            sys.exit("GEN_GATHER_ORACLES_DISAGREE tok %d" % t)
    assert 32767 in crow[61][1], "tok 61 must hit the saturation"
    assert not any(crow[51][1]), "tok 51 must be the all-zero row"
    lines = ["# sim/embed_gather_k%d_vec.txt -- GENERATED by tools/jc/gen_embed_gather_vec.py --k %d; do not hand-edit." % (k, k),
             "# H emb_base nbeats M / B addr data(32 bytes, byte 31 first) / T tok exp / M mantissas",
             "# rows are server/embed_mv4i.c's pl_embed_mv4i (recipe wide), cross-checked by tools/embed_gather.py",
             "H %09X %d %d" % (EMB_BASE, len(img) // 32, M)]
    for a in range(0, len(img), 32):
        lines.append("B %09X %s" % (EMB_BASE + a, img[a:a + 32][::-1].hex().upper()))
    for t in ids:
        lines.append("T %d %d" % (t, crow[t][0]))
        lines.append("M " + " ".join(str(m) for m in crow[t][1]))
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("GEN_GATHER k=%d ids=%d beats=%d -> %s" % (k, len(ids), len(img) // 32, out_path))


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--k", type=int, choices=(4096, 5120), required=True)
    ap.add_argument("--out")
    ap.add_argument("--mv4i")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    out = a.out or os.path.join(REPO, "sim", "embed_gather_k%d_vec.txt" % a.k)
    if a.check:
        tmp = os.path.join(tempfile.mkdtemp(prefix="egv_chk_", dir=os.path.expanduser("~/regress_scratch")), "v.txt")
        generate(a.k, tmp, None)
        same = open(tmp).read() == open(out).read()
        print("GEN_GATHER_CHECK %s" % ("OK" if same else "STALE"))
        return 0 if same else 1
    generate(a.k, out, a.mv4i)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Run: `mkdir -p ~/regress_scratch && python3 tools/jc/gen_embed_gather_vec.py --k 4096 && python3 tools/jc/gen_embed_gather_vec.py --k 5120`
Expected: two `GEN_GATHER k=... ids=16` lines, no `GEN_GATHER_ORACLES_DISAGREE`. If `EG.PackedTensor` refuses the synthetic header, the message names the field: fix `build()` to match `tools/embed_gather.py`'s `Mv4iHeader`, never the reader.

- [ ] **Step 2: Write the test body and the two gate rows**

`sim/embed_gather_tc.vhd`:

```vhdl
-- sim/embed_gather_tc.vhd -- the embed_gather test body (plan 2026-11-04 Task 3), shared by
-- sim/tb_embed_gather.vhd (K 4096, the 9B) and sim/tb_embed_gather_27b.vhd (K 5120). Oracle:
-- the host's pl_embed_mv4i rows in the vector file. The HBM image is poked into
-- sim/jc_axi3_mem, which also enforces the AXI3 rules on every burst.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity embed_gather_tc is
  generic(N_EMBD : positive := 4096; VEC : string := "embed_gather_k4096_vec.txt";
          TB_NAME : string := "tb_embed_gather");
end entity;

architecture sim of embed_gather_tc is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal emb_base : unsigned(32 downto 0) := (others => '0');
  signal inval, req, exp_valid, err, m_valid, m_ready : std_logic := '0';
  signal tok : unsigned(31 downto 0) := (others => '0');
  signal exp_val : std_logic_vector(31 downto 0);
  signal err_code : std_logic_vector(3 downto 0);
  signal m_data : std_logic_vector(15 downto 0);
  signal araddr : std_logic_vector(32 downto 0);
  signal arlen : std_logic_vector(7 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst : std_logic_vector(1 downto 0);
  signal arvalid, arready, rlast, rvalid, rready : std_logic;
  signal rdata : std_logic_vector(255 downto 0);
  signal rresp : std_logic_vector(1 downto 0);
  signal poke_en : std_logic := '0';
  signal poke_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal poke_data : std_logic_vector(255 downto 0) := (others => '0');
  signal mem_errs : natural;
  signal arlen_hi_seen : natural := 0;
begin
  clk <= not clk after 2.5 ns;

  dut : entity work.embed_gather
    generic map(N_EMBD => N_EMBD, ADDR_W => 33)
    port map(clk => clk, rst => rst, emb_base => emb_base, invalidate => inval, req => req,
             tok => tok, exp_valid => exp_valid, exp_val => exp_val, err => err,
             err_code => err_code, m_valid => m_valid, m_data => m_data, m_ready => m_ready,
             m_axi_araddr => araddr, m_axi_arlen => arlen, m_axi_arsize => arsize,
             m_axi_arburst => arburst, m_axi_arvalid => arvalid, m_axi_arready => arready,
             m_axi_rdata => rdata, m_axi_rresp => rresp, m_axi_rlast => rlast,
             m_axi_rvalid => rvalid, m_axi_rready => rready);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 14, STALL => true)
    port map(clk => clk, awaddr => (others => '0'), awlen => "0000", awsize => "101",
             awburst => "01", awvalid => '0', awready => open, wdata => (others => '0'),
             wstrb => (others => '0'), wlast => '0', wvalid => '0', wready => open,
             bresp => open, bvalid => open, bready => '1',
             araddr => araddr, arlen => arlen(3 downto 0), arsize => arsize, arburst => arburst,
             arvalid => arvalid, arready => arready, rdata => rdata, rresp => rresp,
             rlast => rlast, rvalid => rvalid, rready => rready,
             poke_en => poke_en, poke_addr => poke_addr, poke_data => poke_data,
             peek_addr => (others => '0'), peek_data => open, peek_hit => open, errors => mem_errs);

  process(clk)
  begin
    if rising_edge(clk) then
      if arvalid = '1' and arlen(7 downto 4) /= "0000" then arlen_hi_seen <= arlen_hi_seen + 1; end if;
    end if;
  end process;

  main : process
    file f : text open read_mode is VEC;
    variable l : line;
    variable ch : character;
    variable a9 : std_logic_vector(35 downto 0);
    variable b256 : std_logic_vector(255 downto 0);
    variable n, nbeats, mcount, t, want_exp, m, bad : integer;
    variable e, c : natural := 0;
    variable lfsr : std_logic_vector(15 downto 0) := x"B00F";
    variable hdr0 : std_logic_vector(255 downto 0);
    type iv_t is array (0 to N_EMBD-1) of integer;
    variable want : iv_t;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report TB_NAME & ": " & msg severity error; end if;
    end procedure;
    procedure get_row(tk : natural; ok_exp : out boolean) is
    begin
      tok <= to_unsigned(tk, 32); req <= '1'; wait until rising_edge(clk); req <= '0';
      wait until rising_edge(clk);   -- let a stale err/err_code from the prior call clear (finding 7)
      n := 0;
      while exp_valid = '0' and err = '0' loop
        wait until rising_edge(clk); n := n + 1;
        assert n < 400000 report TB_NAME & ": no exponent" severity failure;
      end loop;
      ok_exp := exp_valid = '1';
    end procedure;
    variable okx : boolean;
  begin
    -- the image
    readline(f, l); while l(1) = '#' loop readline(f, l); end loop;
    read(l, ch); hread(l, a9); read(l, nbeats); read(l, mcount);
    emb_base <= unsigned(a9(32 downto 0));
    for k in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for k in 0 to nbeats - 1 loop
      readline(f, l); read(l, ch); hread(l, a9); hread(l, b256);
      if k = 0 then hdr0 := b256; end if;
      poke_en <= '1'; poke_addr <= "0000" & a9; poke_data <= b256;
      wait until rising_edge(clk);
    end loop;
    poke_en <= '0';
    wait until rising_edge(clk);
    inval <= '1'; wait until rising_edge(clk); inval <= '0';
    -- the rows
    while not endfile(f) loop
      readline(f, l); read(l, ch); read(l, t); read(l, want_exp);
      readline(f, l); read(l, ch);
      for k in 0 to N_EMBD - 1 loop read(l, m); want(k) := m; end loop;
      get_row(t, okx);
      chk(okx, "tok " & integer'image(t) & " no error");
      chk(to_integer(signed(exp_val)) = want_exp, "tok " & integer'image(t) & " exponent equals pl_embed_mv4i's");
      bad := 0;
      for k in 0 to N_EMBD - 1 loop
        while m_valid = '0' loop wait until rising_edge(clk); end loop;
        if to_integer(signed(m_data)) /= want(k) then
          if bad < 4 then
            report TB_NAME & ": tok " & integer'image(t) & " element " & integer'image(k) & " got " &
                   integer'image(to_integer(signed(m_data))) & " want " & integer'image(want(k)) severity error;
          end if;
          bad := bad + 1;
        end if;
        lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
        if lfsr(0) = '1' then wait until rising_edge(clk); end if;   -- consumer stalls
        m_ready <= '1'; wait until rising_edge(clk); m_ready <= '0';
        wait until rising_edge(clk);
      end loop;
      chk(bad = 0, "tok " & integer'image(t) & ": every mantissa equals pl_embed_mv4i's");
      wait until rising_edge(clk);
      chk(exp_valid = '0', "exp_valid drops after the last mantissa");
    end loop;
    -- token out of range: err code 2
    get_row(mcount, okx);
    chk(not okx and err_code = "0010", "token = M is refused with code 2");
    -- corrupted magic: err code 1 after invalidate
    poke_en <= '1'; poke_addr <= "0000000" & std_logic_vector(emb_base);
    poke_data <= hdr0(255 downto 32) & x"00000000";
    wait until rising_edge(clk); poke_en <= '0';
    inval <= '1'; wait until rising_edge(clk); inval <= '0';
    get_row(0, okx);
    chk(not okx and err_code = "0001", "a header without MV4I is refused with code 1");
    chk(mem_errs = 0, "every burst obeyed the AXI3 rules (jc_axi3_mem)");
    chk(arlen_hi_seen = 0, "ARLEN never above 15");
    if e = 0 then
      report "PASS: " & TB_NAME & " checks=" & integer'image(c) severity note;
    else
      report "FAIL: " & TB_NAME & " errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
```

`sim/tb_embed_gather.vhd`:

```vhdl
-- sim/tb_embed_gather.vhd -- gate row: embed_gather at the 9B geometry (K 4096), plan Task 3.
entity tb_embed_gather is
end entity;
architecture sim of tb_embed_gather is
begin
  tc : entity work.embed_gather_tc
    generic map(N_EMBD => 4096, VEC => "embed_gather_k4096_vec.txt", TB_NAME => "tb_embed_gather");
end architecture;
```

`sim/tb_embed_gather_27b.vhd`:

```vhdl
-- sim/tb_embed_gather_27b.vhd -- gate row: embed_gather at the 27B geometry (K 5120), plan Task 3.
entity tb_embed_gather_27b is
end entity;
architecture sim of tb_embed_gather_27b is
begin
  tc : entity work.embed_gather_tc
    generic map(N_EMBD => 5120, VEC => "embed_gather_k5120_vec.txt", TB_NAME => "tb_embed_gather_27b");
end architecture;
```

- [ ] **Step 3: Run to see them fail**

Run: `REGRESS_SCRATCH=~/regress_scratch/t3-a bash sim/regress.sh --only tb_embed_gather --keep`
Expected: two rows (`tb_embed_gather`, `tb_embed_gather_27b`), both BUILD-ERROR (no `embed_gather` entity).

- [ ] **Step 4: Write the gather**

`rtl/embed_gather.vhd`:

```vhdl
-- rtl/embed_gather.vhd -- one embedding row from the packed .mv4i table in HBM, dequantized
-- and BFP-packed exactly as server/embed_mv4i.c's pl_embed_mv4i (recipe wide). Plan
-- 2026-11-04 Task 3; the layout read is the plan's (whole file at EMB_BASE). AXI3: 16-beat
-- bursts, 32-byte beats, 512-byte aligned (no 4 KB crossing).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity embed_gather is
  generic(N_EMBD : positive := 4096; ADDR_W : positive := 33);
  port(
    clk, rst      : in  std_logic;
    emb_base      : in  unsigned(ADDR_W-1 downto 0);
    invalidate    : in  std_logic;
    req           : in  std_logic;
    tok           : in  unsigned(31 downto 0);
    exp_valid     : out std_logic;
    exp_val       : out std_logic_vector(31 downto 0);
    err           : out std_logic;
    err_code      : out std_logic_vector(3 downto 0);
    m_valid       : out std_logic;
    m_data        : out std_logic_vector(15 downto 0);
    m_ready       : in  std_logic;
    m_axi_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m_axi_arlen   : out std_logic_vector(7 downto 0);
    m_axi_arsize  : out std_logic_vector(2 downto 0);
    m_axi_arburst : out std_logic_vector(1 downto 0);
    m_axi_arvalid : out std_logic;
    m_axi_arready : in  std_logic;
    m_axi_rdata   : in  std_logic_vector(255 downto 0);
    m_axi_rresp   : in  std_logic_vector(1 downto 0);
    m_axi_rlast   : in  std_logic;
    m_axi_rvalid  : in  std_logic;
    m_axi_rready  : out std_logic);
end entity;

architecture rtl of embed_gather is
  constant NB   : natural := N_EMBD / 32;
  constant NBUR : natural := NB / 16;
  constant ROWB : natural := NB * 32;
  constant CHK  : natural range 0 to 0 := N_EMBD mod 512;    -- whole 16-beat bursts
  constant MAGIC : std_logic_vector(31 downto 0) := x"4D563449";
  type hdr_t is array (0 to 8) of std_logic_vector(255 downto 0);
  type off_t is array (0 to 26) of unsigned(32 downto 0);
  type cb_t  is array (0 to 15) of signed(7 downto 0);
  type sc_t  is array (0 to NB-1) of std_logic_vector(15 downto 0);
  type wb_t  is array (0 to NB-1) of std_logic_vector(127 downto 0);
  type val_t is array (0 to N_EMBD-1) of std_logic_vector(24 downto 0);
  type gs_t is (G_IDLE, G_HAR, G_HR, G_HCHK, G_DIV, G_ADDR, G_AR, G_R, G_DEQ, G_EXP,
                G_EM1, G_EM2, G_EMIT, G_ERR);
  signal gs : gs_t := G_IDLE;
  signal hdr : hdr_t := (others => (others => '0'));
  signal offs : off_t := (others => (others => '0'));
  signal cb : cb_t := (others => (others => '0'));
  signal sc : sc_t;
  signal wb : wb_t;
  signal vals : val_t;
  signal m_cnt : unsigned(31 downto 0) := (others => '0');
  signal w_exp : signed(31 downto 0) := (others => '0');
  signal hdr_ok, rerr, phase_w, va : std_logic := '0';
  signal tok_r : unsigned(17 downto 0) := (others => '0');
  signal tok32 : unsigned(31 downto 0) := (others => '0');
  signal q_r : unsigned(17 downto 0) := (others => '0');
  signal rem_r : unsigned(5 downto 0) := (others => '0');
  signal dbit : natural range 0 to 17 := 17;
  signal half : natural range 0 to 1 := 0;
  signal kk : natural range 0 to 15 := 0;
  signal w_addr, s_addr : unsigned(32 downto 0) := (others => '0');
  signal bur : natural range 0 to 63 := 0;
  signal bi : natural range 0 to 15 := 0;
  signal hcnt : natural range 0 to 8 := 0;
  signal ea, eb, ee : natural range 0 to N_EMBD := 0;
  signal ja : natural range 0 to 31 := 0;
  signal wq : std_logic_vector(127 downto 0) := (others => '0');
  signal scq : std_logic_vector(15 downto 0) := (others => '0');
  signal amax : unsigned(24 downto 0) := (others => '0');
  signal sh_r : integer range -14 to 10 := 0;
  signal vq : std_logic_vector(24 downto 0) := (others => '0');
  signal araddr_r : unsigned(32 downto 0) := (others => '0');
  signal arlen_r : std_logic_vector(7 downto 0) := (others => '0');
  signal arv : std_logic := '0';

  impure function hb(i : natural) return std_logic_vector is
  begin
    return hdr(i / 32)(8 * (i mod 32) + 7 downto 8 * (i mod 32));
  end function;
  impure function h16(i : natural) return unsigned is
  begin
    return unsigned(std_logic_vector'(hb(i + 1) & hb(i)));
  end function;
  impure function h32(i : natural) return unsigned is
  begin
    return unsigned(std_logic_vector'(hb(i + 3) & hb(i + 2) & hb(i + 1) & hb(i)));
  end function;
  function abs_u(v : signed(24 downto 0)) return unsigned is
  begin
    return unsigned(abs(v));
  end function;
begin
  m_axi_araddr  <= std_logic_vector(araddr_r(ADDR_W-1 downto 0));
  m_axi_arlen   <= arlen_r;
  m_axi_arsize  <= "101";
  m_axi_arburst <= "01";
  m_axi_arvalid <= arv;
  m_axi_rready  <= '1' when gs = G_HR or gs = G_R else '0';

  process(clk)
    variable ok : boolean;
    variable o : natural;
    variable r : unsigned(6 downto 0);
    variable rr : natural range 0 to 47;
    variable b : natural range 0 to NB - 1;
    variable byte : std_logic_vector(7 downto 0);
    variable nib : std_logic_vector(3 downto 0);
    variable prod : signed(24 downto 0);
    variable a : unsigned(24 downto 0);
    variable msb : natural range 0 to 24;
    variable t26, m26 : signed(25 downto 0);
  begin
    if rising_edge(clk) then
      if invalidate = '1' then hdr_ok <= '0'; end if;
      if rst = '1' then
        gs <= G_IDLE; arv <= '0'; exp_valid <= '0'; m_valid <= '0'; err <= '0'; hdr_ok <= '0';
      else
        case gs is
          when G_IDLE =>
            if req = '1' then
              err <= '0'; err_code <= "0000"; rerr <= '0';
              tok_r <= tok(17 downto 0); tok32 <= tok;
              if hdr_ok = '0' or invalidate = '1' then
                if emb_base(11 downto 0) /= 0 then
                  err_code <= "0001"; gs <= G_ERR;
                else
                  araddr_r <= resize(emb_base, 33); arlen_r <= x"08"; arv <= '1'; hcnt <= 0; gs <= G_HAR;
                end if;
              elsif tok >= m_cnt then
                err_code <= "0010"; gs <= G_ERR;
              else
                rem_r <= (others => '0'); dbit <= 17; gs <= G_DIV;
              end if;
            end if;
          when G_HAR =>
            if m_axi_arready = '1' then arv <= '0'; gs <= G_HR; end if;
          when G_HR =>
            if m_axi_rvalid = '1' then
              hdr(hcnt) <= m_axi_rdata;
              if m_axi_rresp /= "00" then rerr <= '1'; end if;
              if m_axi_rlast = '1' then gs <= G_HCHK; else hcnt <= hcnt + 1; end if;
            end if;
          when G_HCHK =>
            ok := rerr = '0' and h32(0) = unsigned(MAGIC) and h32(16#0C#) = N_EMBD
                  and h16(16#18#) = 48 and h16(16#1A#) = 24 and h16(16#1C#) = 32
                  and h16(16#1E#) = 256 and h32(16#34#) = 3
                  and h32(16#08#) /= 0 and h32(16#08#) < 262144;
            for k in 0 to 26 loop
              o := 16#38# + 8 * k;
              ok := ok and h32(o + 4)(31 downto 1) = 0 and h32(o)(8 downto 0) = 0;
              offs(k) <= h32(o + 4)(0) & h32(o);
            end loop;
            for k in 0 to 15 loop cb(k) <= signed(hb(16#20# + k)); end loop;
            m_cnt <= h32(16#08#);
            w_exp <= signed(h32(16#10#));
            if not ok then
              err_code <= "0001"; gs <= G_ERR;
            elsif tok32 >= h32(16#08#) then
              hdr_ok <= '1'; err_code <= "0010"; gs <= G_ERR;
            else
              hdr_ok <= '1'; rem_r <= (others => '0'); dbit <= 17; gs <= G_DIV;
            end if;
          when G_DIV =>                                  -- tok / 48, MSB first
            r := rem_r & tok_r(dbit);
            if r >= 48 then r := r - 48; q_r(dbit) <= '1'; else q_r(dbit) <= '0'; end if;
            rem_r <= r(5 downto 0);
            if dbit = 0 then gs <= G_ADDR; else dbit <= dbit - 1; end if;
          when G_ADDR =>
            rr := to_integer(rem_r);
            half <= rr mod 2; kk <= rr mod 16;
            w_addr <= resize(emb_base, 33) + offs(rr / 2) + resize(q_r * to_unsigned(ROWB, 15), 33);
            s_addr <= resize(emb_base, 33) + offs(24 + rr / 16) + resize(q_r * to_unsigned(ROWB, 15), 33);
            phase_w <= '0'; bur <= 0; gs <= G_AR;
          when G_AR =>
            if arv = '0' then
              if phase_w = '0' then araddr_r <= s_addr + to_unsigned(bur * 512, 33);
              else araddr_r <= w_addr + to_unsigned(bur * 512, 33); end if;
              arlen_r <= x"0F"; arv <= '1';
            elsif m_axi_arready = '1' then
              arv <= '0'; bi <= 0; gs <= G_R;
            end if;
          when G_R =>
            if m_axi_rvalid = '1' then
              b := bur * 16 + bi;
              if m_axi_rresp /= "00" then rerr <= '1'; end if;
              if phase_w = '0' then sc(b) <= m_axi_rdata(16 * kk + 15 downto 16 * kk);
              else wb(b) <= m_axi_rdata(128 * half + 127 downto 128 * half); end if;
              if m_axi_rlast = '1' then
                if bur = NBUR - 1 then
                  if phase_w = '0' then
                    phase_w <= '1'; bur <= 0; gs <= G_AR;
                  elsif rerr = '1' or m_axi_rresp /= "00" then
                    err_code <= "0011"; gs <= G_ERR;
                  else
                    ea <= 0; eb <= 0; va <= '0'; amax <= (others => '0'); gs <= G_DEQ;
                  end if;
                else
                  bur <= bur + 1; gs <= G_AR;
                end if;
              else
                bi <= bi + 1;
              end if;
            end if;
          when G_DEQ =>                                   -- one element per cycle, two stages
            if ea < N_EMBD then
              wq <= wb(ea / 32); scq <= sc(ea / 32); ja <= ea mod 32; va <= '1'; ea <= ea + 1;
            else
              va <= '0';
            end if;
            if va = '1' then
              byte := wq(8 * (ja / 2) + 7 downto 8 * (ja / 2));
              if ja mod 2 = 1 then nib := byte(7 downto 4); else nib := byte(3 downto 0); end if;
              prod := resize(cb(to_integer(unsigned(nib))) * signed('0' & scq), 25);
              vals(eb) <= std_logic_vector(prod);
              a := abs_u(prod);
              if a > amax then amax <= a; end if;
              if eb = N_EMBD - 1 then gs <= G_EXP; else eb <= eb + 1; end if;
            end if;
          when G_EXP =>
            msb := 0;
            for k in 24 downto 0 loop
              if amax(k) = '1' then msb := k; exit; end if;
            end loop;
            sh_r <= msb - 14;
            if amax = 0 then exp_val <= std_logic_vector(w_exp + 15);
            else exp_val <= std_logic_vector(w_exp + 15 - (msb - 14)); end if;
            exp_valid <= '1'; ee <= 0; gs <= G_EM1;
          when G_EM1 =>
            vq <= vals(ee); gs <= G_EM2;
          when G_EM2 =>
            if sh_r > 0 then
              t26 := resize(signed(vq), 26) + shift_left(to_signed(1, 26), sh_r - 1);
              m26 := shift_right(t26, sh_r);
            elsif sh_r < 0 then
              m26 := shift_left(resize(signed(vq), 26), -sh_r);
            else
              m26 := resize(signed(vq), 26);
            end if;
            if m26 > 32767 then m_data <= x"7FFF";
            elsif m26 < -32768 then m_data <= x"8000";
            else m_data <= std_logic_vector(m26(15 downto 0)); end if;
            m_valid <= '1'; gs <= G_EMIT;
          when G_EMIT =>
            if m_ready = '1' then
              m_valid <= '0';
              if ee = N_EMBD - 1 then exp_valid <= '0'; gs <= G_IDLE;
              else ee <= ee + 1; gs <= G_EM1; end if;
            end if;
          when G_ERR =>
            err <= '1'; gs <= G_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
```

- [ ] **Step 5: Run the two rows to see them pass**

Run: `REGRESS_SCRATCH=~/regress_scratch/t3-b bash sim/regress.sh --only tb_embed_gather --keep`
Expected: `OVERALL PASS 2`; each log ends `PASS: tb_embed_gather checks=` / `PASS: tb_embed_gather_27b checks=` with n >= 36 (16 ids x 2 + 4).

- [ ] **Step 6: Write and run the mutants**

`sim/mutants/embed_gather.json`:

```json
{
  "tb": "tb_embed_gather",
  "deps": ["sim/jc_axi3_mem.vhd", "rtl/embed_gather.vhd", "sim/embed_gather_tc.vhd", "sim/tb_embed_gather.vhd"],
  "vectors": ["sim/embed_gather_k4096_vec.txt"],
  "stop_time": "200ms",
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "G1", "expect": "KILLED", "file": "rtl/embed_gather.vhd",
     "why": "codebook index swapped (spec 4)",
     "old": "if ja mod 2 = 1 then nib := byte(7 downto 4); else nib := byte(3 downto 0); end if;",
     "new": "if ja mod 2 = 1 then nib := byte(3 downto 0); else nib := byte(7 downto 4); end if;"},
    {"tag": "G2", "expect": "KILLED", "file": "rtl/embed_gather.vhd",
     "why": "block max taken before the scale (spec 4)",
     "old": "a := abs_u(prod);",
     "new": "a := abs_u(resize(cb(to_integer(unsigned(nib))), 25));"},
    {"tag": "G3", "expect": "KILLED", "file": "rtl/embed_gather.vhd",
     "why": "saturation removed (tok 61 rounds to 32768)",
     "old": "if m26 > 32767 then m_data <= x\"7FFF\";",
     "new": "if false then m_data <= x\"7FFF\";"},
    {"tag": "G4", "expect": "KILLED", "file": "rtl/embed_gather.vhd",
     "why": "header magic not checked",
     "old": "ok := rerr = '0' and h32(0) = unsigned(MAGIC) and h32(16#0C#) = N_EMBD",
     "new": "ok := rerr = '0' and h32(16#0C#) = N_EMBD"},
    {"tag": "G5", "expect": "KILLED", "file": "rtl/embed_gather.vhd",
     "why": "scale index within the beat + 1 (embed_mv4i.h mutant c6)",
     "old": "half <= rr mod 2; kk <= rr mod 16;",
     "new": "half <= rr mod 2; kk <= (rr + 1) mod 16;"}
  ]
}
```

Run: `python3 sim/mutate_rows.py sim/mutants/embed_gather.json`
Expected: `MUTANTS_OK 6`.

- [ ] **Step 7: Commit**

```bash
git add rtl/embed_gather.vhd tools/jc/gen_embed_gather_vec.py sim/embed_gather_tc.vhd sim/tb_embed_gather.vhd \
  sim/tb_embed_gather_27b.vhd sim/embed_gather_k4096_vec.txt sim/embed_gather_k5120_vec.txt sim/mutants/embed_gather.json
git commit -m "jc loop T3: embed_gather, bit-exact against pl_embed_mv4i at K 4096 and 5120" -- \
  rtl/embed_gather.vhd tools/jc/gen_embed_gather_vec.py sim/embed_gather_tc.vhd sim/tb_embed_gather.vhd \
  sim/tb_embed_gather_27b.vhd sim/embed_gather_k4096_vec.txt sim/embed_gather_k5120_vec.txt sim/mutants/embed_gather.json
```

---
### Task 4: Link frame format, jc_link_tx and jc_link_rx

**Files:**
- Create: `rtl/jc_link_pkg.vhd`, `rtl/jc_link_tx.vhd`, `rtl/jc_link_rx.vhd`, `sim/jc_link_chan_model.vhd`, `sim/tb_jc_link.vhd`, `sim/mutants/jc_link.json`

**Interfaces:**
- Consumes: `crc32_word` from `rtl/jc_loader_pkg.vhd:27-53` (reflected CRC-32, zlib polynomial, bit 0 first = little-endian bytes; init and final XOR all ones, as `rtl/jc_hbm_crc.vhd:84,112` use it). Used, not edited.
- Produces:
  - Frame (32-bit words, W = 2 x NLANES words per AXIS beat, word j of a beat at bits [32j+31:32j]): w0 `LK_MAGIC` 0x4A4C4B31 "JLK1", w1 seq (frames sent this run, a resend keeps it), w2 position, w3 payload words (= N_EMBD/2), w4 X exponent (plan D2), w5..w7 zero, then N_EMBD/2 payload words (`mant[2k] | mant[2k+1] << 16`), then the CRC-32 of w0..w(7+N_EMBD/2) as word 0 of a last beat whose other words are zero, `tlast` on that beat. Header and payload are whole beats for NLANES 1, 2, 4.
  - `jc_link_pkg`: `LK_MAGIC`, `LK_HDR_WORDS` (8), `LK_CRC_INIT`, `lk_pw(n_embd)`, `lk_beats(n_embd, w)`, `lk_crc_beat(crc, beat, w)`, `lk_crc_final(crc)`.
  - `jc_link_tx` (generics `N_EMBD, W`): fill port (`fill_we, fill_idx(11:0), fill_data(31:0)`; any fill drops the held frame), `send` with `send_pos, send_exp`, `resend` (resends the held frame with the same seq; at `resends >= resend_cap` it sets sticky `exhausted` instead), `run_start`, `busy`, `exhausted`, `frames_sent`, `resends`, AXIS master `m_tdata/m_tkeep/m_tlast/m_tvalid/m_tready`.
  - `jc_link_rx` (generics `N_EMBD, W, DEPTH`): AXIS slave without ready (Aurora RX has none: `m_axi_rx_*` in the IP's port list has no tready), `chan_up`, `run_start`; head-of-queue `head_valid, head_pos, head_exp`, word read `rd_idx(11:0) -> rd_data` (one cycle), `pop`; flags `bad` (cleared by the next good frame), `down` (set on a chan_up fall, cleared by the next good frame); counters `frames_good, crc_fails, seqpos_bad, link_downs, overruns, consumed`. Verdict order: malformed or CRC -> crc_fails; magic/nwords -> seqpos_bad; seq or position not the expected next -> seqpos_bad; no free slot -> overruns; else commit.

- [ ] **Step 1: Write the bench and the channel model**

`sim/jc_link_chan_model.vhd`:

```vhdl
-- sim/jc_link_chan_model.vhd -- an AXIS channel standing in for Aurora in the GHDL link
-- benches (plan 2026-11-04 Task 4): fixed latency, no RX backpressure (Aurora RX has no
-- tready), a bit flip on one numbered beat, a dropped beat, and link-down (TX stalls,
-- beats in flight are lost, chan_up low). Injected beats let a bench send crafted frames.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jc_link_chan_model is
  generic(W : positive := 2; LAT : positive := 8);
  port(
    clk       : in  std_logic;
    s_tdata   : in  std_logic_vector(32*W-1 downto 0);
    s_tlast   : in  std_logic;
    s_tvalid  : in  std_logic;
    s_tready  : out std_logic;
    m_tdata   : out std_logic_vector(32*W-1 downto 0) := (others => '0');
    m_tlast   : out std_logic := '0';
    m_tvalid  : out std_logic := '0';
    chan_up   : out std_logic := '1';
    down      : in  std_logic := '0';
    flip_beat : in  integer := -1;
    flip_bit  : in  natural := 0;
    drop_beat : in  integer := -1;
    inj_valid : in  std_logic := '0';
    inj_data  : in  std_logic_vector(32*W-1 downto 0) := (others => '0');
    inj_last  : in  std_logic := '0';
    nbeats    : out natural := 0);
end entity;

architecture sim of jc_link_chan_model is
  type d_t is array (0 to LAT-1) of std_logic_vector(32*W-1 downto 0);
begin
  s_tready <= not down;
  process(clk)
    variable dd : d_t := (others => (others => '0'));
    variable dv, dl : std_logic_vector(0 to LAT-1) := (others => '0');
    variable n : natural := 0;
    variable b : std_logic_vector(32*W-1 downto 0);
    variable v, lst : std_logic;
  begin
    if rising_edge(clk) then
      m_tdata <= dd(LAT-1); m_tvalid <= dv(LAT-1) and not down; m_tlast <= dl(LAT-1);
      for k in LAT-1 downto 1 loop dd(k) := dd(k-1); dv(k) := dv(k-1); dl(k) := dl(k-1); end loop;
      v := '0'; b := (others => '0'); lst := '0';
      if s_tvalid = '1' and down = '0' then
        b := s_tdata; lst := s_tlast; v := '1';
        if n = flip_beat then b(flip_bit) := not b(flip_bit); end if;
        if n = drop_beat then v := '0'; end if;
        n := n + 1;
      elsif inj_valid = '1' then
        b := inj_data; lst := inj_last; v := '1';
      end if;
      dd(0) := b; dv(0) := v; dl(0) := lst;
      if down = '1' then dv := (others => '0'); end if;
      chan_up <= not down; nbeats <= n;
    end if;
  end process;
end architecture;
```

`sim/tb_jc_link.vhd`:

```vhdl
-- sim/tb_jc_link.vhd -- jc_link_tx -> channel model -> jc_link_rx (plan 2026-11-04 Task 4).
-- Oracle: the received payload equals the words the bench filled, word for word, or the
-- right fault counter moves and nothing reaches the head of the queue. The CRC is checked
-- against zlib's crc32 of a fixed frame (Python: zlib.crc32 of the 10 little-endian words
-- below = 0x1FA2586E).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_link_pkg.all;

entity tb_jc_link is
end entity;

architecture sim of tb_jc_link is
  constant N : positive := 64;            -- 32 payload words: 4 header + 16 payload + 1 CRC beat
  constant W : positive := 2;
  constant PW : natural := N / 2;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal run_start, fill_we, send, resend, pop : std_logic := '0';
  signal fill_idx, rd_idx : unsigned(11 downto 0) := (others => '0');
  signal fill_data, send_exp, rd_data, head_exp : std_logic_vector(31 downto 0) := (others => '0');
  signal send_pos, head_pos : unsigned(31 downto 0) := (others => '0');
  signal resend_cap : unsigned(31 downto 0) := to_unsigned(100, 32);
  signal busy, exhausted, head_valid, bad, down_f : std_logic;
  signal frames_sent, resends, frames_good, crc_fails, seqpos_bad, link_downs, overruns, consumed : unsigned(31 downto 0);
  signal t_data, r_data, inj_data : std_logic_vector(32*W-1 downto 0) := (others => '0');
  signal t_last, t_valid, t_ready, r_last, r_valid, chan_up, inj_valid, inj_last : std_logic := '0';
  signal down : std_logic := '0';
  signal flip_beat, drop_beat : integer := -1;
  signal flip_bit : natural := 0;
  signal nbeats : natural;
  type words_t is array (0 to PW-1) of std_logic_vector(31 downto 0);
begin
  clk <= not clk after 2.5 ns;

  tx : entity work.jc_link_tx
    generic map(N_EMBD => N, W => W)
    port map(clk => clk, rst => rst, run_start => run_start, fill_we => fill_we,
             fill_idx => fill_idx, fill_data => fill_data, send => send, send_pos => send_pos,
             send_exp => send_exp, resend => resend, resend_cap => resend_cap, busy => busy,
             exhausted => exhausted, frames_sent => frames_sent, resends => resends,
             m_tdata => t_data, m_tkeep => open, m_tlast => t_last, m_tvalid => t_valid,
             m_tready => t_ready);
  ch : entity work.jc_link_chan_model
    generic map(W => W, LAT => 8)
    port map(clk => clk, s_tdata => t_data, s_tlast => t_last, s_tvalid => t_valid,
             s_tready => t_ready, m_tdata => r_data, m_tlast => r_last, m_tvalid => r_valid,
             chan_up => chan_up, down => down, flip_beat => flip_beat, flip_bit => flip_bit,
             drop_beat => drop_beat, inj_valid => inj_valid, inj_data => inj_data,
             inj_last => inj_last, nbeats => nbeats);
  rx : entity work.jc_link_rx
    generic map(N_EMBD => N, W => W, DEPTH => 2)
    port map(clk => clk, rst => rst, run_start => run_start, chan_up => chan_up,
             s_tdata => r_data, s_tlast => r_last, s_tvalid => r_valid,
             head_valid => head_valid, head_pos => head_pos, head_exp => head_exp,
             rd_idx => rd_idx, rd_data => rd_data, pop => pop, bad => bad, down => down_f,
             frames_good => frames_good, crc_fails => crc_fails, seqpos_bad => seqpos_bad,
             link_downs => link_downs, overruns => overruns, consumed => consumed);

  main : process
    variable e, c : natural := 0;
    variable sent : words_t;
    variable lfsr : std_logic_vector(31 downto 0) := x"1234ABCD";
    variable crc : std_logic_vector(31 downto 0);
    variable n0 : natural;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_jc_link: " & msg severity error; end if;
    end procedure;
    procedure tick(n : natural) is
    begin
      for k in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;
    procedure pulse(signal s : out std_logic) is
    begin
      s <= '1'; wait until rising_edge(clk); s <= '0';
    end procedure;
    procedure fill is
    begin
      for k in 0 to PW - 1 loop
        lfsr := lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
        sent(k) := lfsr;
        fill_we <= '1'; fill_idx <= to_unsigned(k, 12); fill_data <= lfsr;
        wait until rising_edge(clk);
      end loop;
      fill_we <= '0';
    end procedure;
    procedure tx_idle is
    begin
      tick(2);
      while busy = '1' loop wait until rising_edge(clk); end loop;
      tick(16);                                   -- the channel latency drains
    end procedure;
    procedure do_send(p : natural; x : integer) is
    begin
      send_pos <= to_unsigned(p, 32); send_exp <= std_logic_vector(to_signed(x, 32));
      pulse(send); tx_idle;
    end procedure;
    procedure expect_head(p : natural; x : integer; msg : string) is
      variable bad_w : natural := 0;
    begin
      chk(head_valid = '1', msg & ": a frame is at the head");
      if head_valid = '1' then
        chk(head_pos = p, msg & ": head position");
        chk(head_exp = std_logic_vector(to_signed(x, 32)), msg & ": head exponent");
        for k in 0 to PW - 1 loop
          rd_idx <= to_unsigned(k, 12); tick(2);
          if rd_data /= sent(k) then bad_w := bad_w + 1; end if;
        end loop;
        chk(bad_w = 0, msg & ": every payload word equals what was filled");
        pulse(pop); tick(1);
      end if;
    end procedure;
    procedure inject(seq, p : natural) is
      type fw_t is array (0 to 8 + PW + 1) of std_logic_vector(31 downto 0);
      variable fw : fw_t := (others => (others => '0'));
      variable cr : std_logic_vector(31 downto 0) := LK_CRC_INIT;
    begin
      fw(0) := LK_MAGIC; fw(1) := std_logic_vector(to_unsigned(seq, 32));
      fw(2) := std_logic_vector(to_unsigned(p, 32)); fw(3) := std_logic_vector(to_unsigned(PW, 32));
      fw(4) := x"FFFFFFF8";
      for k in 0 to PW - 1 loop fw(8 + k) := sent(k); end loop;
      for k in 0 to 8 + PW - 1 loop cr := lk_crc_beat(cr, fw(k), 1); end loop;
      fw(8 + PW) := lk_crc_final(cr);
      for b in 0 to (8 + PW) / W loop
        inj_data <= fw(W * b + 1) & fw(W * b);
        inj_last <= '1' when b = (8 + PW) / W else '0';
        inj_valid <= '1'; wait until rising_edge(clk);
      end loop;
      inj_valid <= '0'; inj_last <= '0'; tick(16);
    end procedure;
  begin
    -- C10 first: the CRC against zlib
    crc := LK_CRC_INIT;
    crc := lk_crc_beat(crc, x"00000000" & x"4A4C4B31", 2);
    crc := lk_crc_beat(crc, x"00000002" & x"00000000", 2);
    crc := lk_crc_beat(crc, x"00000000" & x"FFFFFFF8", 2);
    crc := lk_crc_beat(crc, x"00000000" & x"00000000", 2);
    crc := lk_crc_beat(crc, x"00040003" & x"00020001", 2);
    chk(lk_crc_final(crc) = x"1FA2586E", "frame CRC equals zlib.crc32 (0x1FA2586E)");
    tick(5); rst <= '0'; tick(2);
    pulse(run_start); tick(2);
    -- C1 clean
    fill; do_send(0, -8);
    expect_head(0, -8, "C1 clean");
    chk(frames_good = 1 and crc_fails = 0 and bad = '0', "C1 counters");
    -- C2 payload bit flip, then resend
    fill; flip_beat <= nbeats + 6; flip_bit <= 5; do_send(1, 3);
    chk(head_valid = '0', "C2 a corrupted frame never reaches the head");
    chk(crc_fails = 1 and bad = '1', "C2 CRC failure counted, LINK_BAD");
    flip_beat <= -1; pulse(resend); tx_idle;
    expect_head(1, 3, "C2 resend");
    chk(bad = '0' and resends = 1, "C2 bad cleared by the good frame");
    -- C3 header bit flip (seq word): the CRC covers the header
    fill; flip_beat <= nbeats + 0; flip_bit <= 33; do_send(2, 0);
    chk(head_valid = '0' and crc_fails = 2, "C3 header corruption is a CRC failure");
    flip_beat <= -1; pulse(resend); tx_idle;
    expect_head(2, 0, "C3 resend");
    -- C4 a dropped beat: the frame is short, tlast comes early
    fill; drop_beat <= nbeats + 10; do_send(3, 1);
    chk(head_valid = '0' and crc_fails = 3, "C4 a short frame is refused");
    drop_beat <= -1; pulse(resend); tx_idle;
    expect_head(3, 1, "C4 resend");
    -- C5 link down mid-frame
    fill; n0 := to_integer(link_downs);
    send_pos <= to_unsigned(4, 32); send_exp <= x"00000002"; pulse(send);
    tick(8); down <= '1'; tick(50); down <= '0'; tx_idle;
    chk(link_downs = n0 + 1 and down_f = '1', "C5 link-down counted, LINK_DOWN");
    chk(head_valid = '0', "C5 the cut frame never reaches the head");
    pulse(resend); tx_idle;
    expect_head(4, 2, "C5 resend");
    chk(down_f = '0', "C5 LINK_DOWN cleared by the good frame");
    chk(crc_fails = 3, "C5 the resumed tail of the cut frame is discarded, not counted");
    -- C6 stale frame: right seq, old position
    inject(5, 3);
    chk(head_valid = '0' and seqpos_bad = 1 and bad = '1', "C6 a stale position is refused");
    -- C7 wrong seq, right position
    inject(99, 5);
    chk(head_valid = '0' and seqpos_bad = 2, "C7 a wrong sequence number is refused");
    fill; do_send(5, 7);
    expect_head(5, 7, "C7 the next real frame is taken");
    -- C8 the resend cap
    pulse(run_start); tick(2); resend_cap <= to_unsigned(2, 32);
    fill; do_send(0, 0); expect_head(0, 0, "C8 first frame");
    pulse(resend); tx_idle; pulse(resend); tx_idle;
    chk(resends = 2 and exhausted = '0', "C8 two resends under a cap of 2");
    n0 := to_integer(frames_sent);
    pulse(resend); tx_idle;
    chk(exhausted = '1' and resends = 2 and frames_sent = n0, "C8 the third resend is refused: exhausted");
    -- C9 overrun: three frames, two slots
    pulse(run_start); tick(2); resend_cap <= to_unsigned(100, 32);
    fill; do_send(0, 0); fill; do_send(1, 0); fill; do_send(2, 0);
    chk(overruns = 1 and bad = '1', "C9 the third frame overruns a full queue");
    chk(head_valid = '1' and head_pos = 0, "C9 the queue holds frames 0 and 1");
    pulse(pop); tick(2);
    chk(head_valid = '1' and head_pos = 1 and consumed = 2 - 1, "C9 pop advances the head");
    -- C11 a RESEND that arrives while busy is latched and served at T_IDLE, not dropped (finding 4)
    pulse(run_start); tick(2); resend_cap <= to_unsigned(100, 32);
    fill; n0 := to_integer(frames_sent);
    send_pos <= to_unsigned(10, 32); send_exp <= x"00000005"; pulse(send);
    tick(3); pulse(resend);     -- busy = '1' here: the old RTL drops this pulse on the floor
    tx_idle; tx_idle;
    chk(to_integer(frames_sent) = n0 + 2 and to_integer(resends) = 1,
        "C11 the busy RESEND was latched and served: one extra frame, one resend counted");
    expect_head(10, 5, "C11 the sent frame");
    pulse(pop); tick(2);
    expect_head(10, 5, "C11 the latched resend, same content, reaches the head too");
    if e = 0 then
      report "PASS: tb_jc_link checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_jc_link errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
```

- [ ] **Step 2: Run to see it fail**

Run: `REGRESS_SCRATCH=~/regress_scratch/t4-a bash sim/regress.sh --only tb_jc_link --keep`
Expected: BUILD-ERROR (no `jc_link_pkg`).

- [ ] **Step 3: Write the package, the framer and the deframer**

`rtl/jc_link_pkg.vhd`:

```vhdl
-- rtl/jc_link_pkg.vhd -- the die-to-die frame (spec 2026-11-04 section 1b.1; plan Task 4,
-- deviation D2: the header carries the X exponent and is 8 words). CRC-32 is
-- rtl/jc_loader_pkg.vhd's crc32_word (zlib polynomial, little-endian bytes), used unchanged.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;

package jc_link_pkg is
  constant LK_MAGIC     : std_logic_vector(31 downto 0) := x"4A4C4B31";   -- "JLK1"
  constant LK_HDR_WORDS : natural := 8;
  constant LK_CRC_INIT  : std_logic_vector(31 downto 0) := x"FFFFFFFF";
  function lk_pw(n_embd : positive) return natural;
  function lk_beats(n_embd : positive; w : positive) return natural;
  function lk_crc_beat(crc : std_logic_vector(31 downto 0); beat : std_logic_vector;
                       w : positive) return std_logic_vector;
  function lk_crc_final(crc : std_logic_vector(31 downto 0)) return std_logic_vector;
end package;

package body jc_link_pkg is
  function lk_pw(n_embd : positive) return natural is
  begin
    return n_embd / 2;
  end function;

  function lk_beats(n_embd : positive; w : positive) return natural is
  begin
    return (LK_HDR_WORDS + n_embd / 2) / w + 1;
  end function;

  function lk_crc_beat(crc : std_logic_vector(31 downto 0); beat : std_logic_vector;
                       w : positive) return std_logic_vector is
    variable b : std_logic_vector(beat'length - 1 downto 0) := beat;
    variable c : std_logic_vector(31 downto 0) := crc;
  begin
    for k in 0 to w - 1 loop
      c := crc32_word(c, b(32 * k + 31 downto 32 * k));
    end loop;
    return c;
  end function;

  function lk_crc_final(crc : std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    return crc xor x"FFFFFFFF";
  end function;
end package body;
```

`rtl/jc_link_tx.vhd`:

```vhdl
-- rtl/jc_link_tx.vhd -- die A's framer (spec 1b.1, 3; plan Task 4). tok_loop_fsm fills the
-- payload buffer with R_X (two mantissas per word), then pulses send. The frame is kept for
-- RESEND until the next fill begins (plan D3 guarantees that frame is the one die B waits
-- for); a resend at resends >= resend_cap sets the sticky `exhausted` instead (spec 3).
-- A RESEND that arrives while busy is latched (`resend_pend`) and served the next time the
-- framer reaches T_IDLE with a frame still held; it is not dropped (finding 4, 2026-11-05:
-- the host's recovery write can land mid-transmission, e.g. tb_tok_loop_pair's P3).
-- One word per cycle at most (payload words every 3 cycles): 2,568 words for the 27B,
-- about 62 us at the card's 125 MHz clk_core (ESTIMATE; the link carries it in ~8 us).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;
use work.jc_link_pkg.all;

entity jc_link_tx is
  generic(N_EMBD : positive := 5120; W : positive := 2);
  port(
    clk, rst    : in  std_logic;
    run_start   : in  std_logic;
    fill_we     : in  std_logic;
    fill_idx    : in  unsigned(11 downto 0);
    fill_data   : in  std_logic_vector(31 downto 0);
    send        : in  std_logic;
    send_pos    : in  unsigned(31 downto 0);
    send_exp    : in  std_logic_vector(31 downto 0);
    resend      : in  std_logic;
    resend_cap  : in  unsigned(31 downto 0);
    busy        : out std_logic;
    exhausted   : out std_logic;
    frames_sent : out unsigned(31 downto 0);
    resends     : out unsigned(31 downto 0);
    m_tdata     : out std_logic_vector(32*W-1 downto 0);
    m_tkeep     : out std_logic_vector(4*W-1 downto 0);
    m_tlast     : out std_logic;
    m_tvalid    : out std_logic;
    m_tready    : in  std_logic);
end entity;

architecture rtl of jc_link_tx is
  constant PW  : natural := N_EMBD / 2;
  constant FW  : natural := LK_HDR_WORDS + PW;
  constant CHK : natural range 0 to 0 := (FW mod W) + (N_EMBD mod 2);
  type buf_t is array (0 to PW-1) of std_logic_vector(31 downto 0);
  type words_t is array (0 to W-1) of std_logic_vector(31 downto 0);
  type ts_t is (T_IDLE, T_GEN, T_RD, T_RD2);
  signal buf : buf_t;
  signal ts : ts_t := T_IDLE;
  signal asm : words_t := (others => (others => '0'));
  signal nw : natural range 0 to W := 0;
  signal asm_last, bv, olast, held, exh : std_logic := '0';
  signal resend_pend : std_logic := '0';   -- a RESEND that arrived while busy (finding 4)
  signal obeat : std_logic_vector(32*W-1 downto 0) := (others => '0');
  signal k : natural range 0 to FW := 0;
  signal crc : std_logic_vector(31 downto 0) := LK_CRC_INIT;
  signal rd_a : natural range 0 to PW-1 := 0;
  signal rq : std_logic_vector(31 downto 0) := (others => '0');
  signal seq_next, seq_r, nsent, nres, pos_r : unsigned(31 downto 0) := (others => '0');
  signal exp_r : std_logic_vector(31 downto 0) := (others => '0');
begin
  m_tdata <= obeat;  m_tkeep <= (others => '1');  m_tlast <= olast;  m_tvalid <= bv;
  busy <= '0' when ts = T_IDLE and nw = 0 and bv = '0' else '1';
  exhausted <= exh;  frames_sent <= nsent;  resends <= nres;

  ram : process(clk)
  begin
    if rising_edge(clk) then
      if fill_we = '1' then buf(to_integer(fill_idx) mod PW) <= fill_data; end if;
      rq <= buf(rd_a);
    end if;
  end process;

  main : process(clk)
    variable wd : std_logic_vector(31 downto 0);
    procedure push(x : std_logic_vector(31 downto 0)) is
    begin
      asm(nw) <= x; nw <= nw + 1; crc <= crc32_word(crc, x);
    end procedure;
  begin
    if rising_edge(clk) then
      if bv = '1' and m_tready = '1' then bv <= '0'; end if;
      if nw = W and (bv = '0' or m_tready = '1') then
        for j in 0 to W - 1 loop obeat(32 * j + 31 downto 32 * j) <= asm(j); end loop;
        olast <= asm_last; bv <= '1'; nw <= 0; asm_last <= '0';
      end if;
      if fill_we = '1' then held <= '0'; end if;
      if rst = '1' then
        ts <= T_IDLE; bv <= '0'; nw <= 0; held <= '0'; exh <= '0'; resend_pend <= '0';
        seq_next <= (others => '0'); nsent <= (others => '0'); nres <= (others => '0');
      else
        if run_start = '1' then
          seq_next <= (others => '0'); held <= '0'; exh <= '0'; resend_pend <= '0';
          nsent <= (others => '0'); nres <= (others => '0');
        end if;
        if resend = '1' and held = '1' then resend_pend <= '1'; end if;
        if fill_we = '1' then resend_pend <= '0'; end if;   -- a new fill retires the old RESEND
        case ts is
          when T_IDLE =>
            if send = '1' then
              pos_r <= send_pos; exp_r <= send_exp; seq_r <= seq_next; seq_next <= seq_next + 1;
              held <= '1'; nsent <= nsent + 1; k <= 0; crc <= LK_CRC_INIT; ts <= T_GEN;
            elsif (resend = '1' or resend_pend = '1') and held = '1' then
              resend_pend <= '0';
              if nres >= resend_cap then
                exh <= '1';
              else
                nres <= nres + 1; nsent <= nsent + 1; k <= 0; crc <= LK_CRC_INIT; ts <= T_GEN;
              end if;
            end if;
          when T_GEN =>
            if nw < W then
              if k < LK_HDR_WORDS then
                case k is
                  when 0 => wd := LK_MAGIC;
                  when 1 => wd := std_logic_vector(seq_r);
                  when 2 => wd := std_logic_vector(pos_r);
                  when 3 => wd := std_logic_vector(to_unsigned(PW, 32));
                  when 4 => wd := exp_r;
                  when others => wd := (others => '0');
                end case;
                push(wd); k <= k + 1;
              elsif k < FW then
                rd_a <= k - LK_HDR_WORDS; ts <= T_RD;
              else
                asm(0) <= lk_crc_final(crc);
                for j in 1 to W - 1 loop asm(j) <= (others => '0'); end loop;
                nw <= W; asm_last <= '1'; ts <= T_IDLE;
              end if;
            end if;
          when T_RD  => ts <= T_RD2;
          when T_RD2 => push(rq); k <= k + 1; ts <= T_GEN;
        end case;
      end if;
    end if;
  end process;
end architecture;
```

`rtl/jc_link_rx.vhd`:

```vhdl
-- rtl/jc_link_rx.vhd -- die B's deframer (spec 1b.3, 3; plan Task 4). Takes a beat every
-- cycle it is offered one (Aurora RX has no backpressure). A frame is committed to a slot
-- only if it is well formed, its CRC matches, its magic and word count are right, and its
-- seq and position are the next expected; anything else is dropped and counted, and sets
-- `bad` (die B pauses, spec 3). A chan_up fall counts a link-down, sets `down`, and
-- discards up to the next tlast: the framer stalls on tready and resumes the cut frame when
-- the channel returns, so its tail must not parse as a header. If the link fell between
-- frames this also eats the next frame; die B stays paused and the host's RESEND recovers it
-- (spec 3). The next good frame clears both flags.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_link_pkg.all;

entity jc_link_rx is
  generic(N_EMBD : positive := 5120; W : positive := 2; DEPTH : positive := 2);
  port(
    clk, rst    : in  std_logic;
    run_start   : in  std_logic;
    chan_up     : in  std_logic;
    s_tdata     : in  std_logic_vector(32*W-1 downto 0);
    s_tlast     : in  std_logic;
    s_tvalid    : in  std_logic;
    head_valid  : out std_logic;
    head_pos    : out unsigned(31 downto 0);
    head_exp    : out std_logic_vector(31 downto 0);
    rd_idx      : in  unsigned(11 downto 0);
    rd_data     : out std_logic_vector(31 downto 0);
    pop         : in  std_logic;
    bad, down   : out std_logic;
    frames_good, crc_fails, seqpos_bad, link_downs, overruns, consumed : out unsigned(31 downto 0));
end entity;

architecture rtl of jc_link_rx is
  constant PW  : natural := N_EMBD / 2;
  constant HB  : natural := LK_HDR_WORDS / W;
  constant PB  : natural := PW / W;
  constant CHK : natural range 0 to 0 := (LK_HDR_WORDS mod W) + (PW mod W);
  type ram_t is array (0 to DEPTH * PB - 1) of std_logic_vector(32*W-1 downto 0);
  type hdr_t is array (0 to LK_HDR_WORDS - 1) of std_logic_vector(31 downto 0);
  type u32_arr is array (0 to DEPTH - 1) of unsigned(31 downto 0);
  type s32_arr is array (0 to DEPTH - 1) of std_logic_vector(31 downto 0);
  type rs_t is (R_HDR, R_PAY, R_CRC, R_DISC);
  signal ram : ram_t;
  signal rs : rs_t := R_HDR;
  signal hdr : hdr_t := (others => (others => '0'));
  signal crc : std_logic_vector(31 downto 0) := LK_CRC_INIT;
  signal bi : natural range 0 to HB + PB := 0;
  signal wslot, hslot : natural range 0 to DEPTH - 1 := 0;
  signal occ : natural range 0 to DEPTH := 0;
  signal spos : u32_arr := (others => (others => '0'));
  signal sexp : s32_arr := (others => (others => '0'));
  signal exp_seq, exp_pos : unsigned(31 downto 0) := (others => '0');
  signal c_good, c_crc, c_sp, c_down, c_ovr, c_cons : unsigned(31 downto 0) := (others => '0');
  signal bad_r, down_r, up_d, store : std_logic := '0';
  signal rq : std_logic_vector(32*W-1 downto 0) := (others => '0');
  signal rsel : natural range 0 to W - 1 := 0;
begin
  head_valid <= '1' when occ > 0 else '0';
  head_pos <= spos(hslot);  head_exp <= sexp(hslot);
  bad <= bad_r;  down <= down_r;
  frames_good <= c_good;  crc_fails <= c_crc;  seqpos_bad <= c_sp;
  link_downs <= c_down;  overruns <= c_ovr;  consumed <= c_cons;
  rd_data <= rq(32 * rsel + 31 downto 32 * rsel);

  process(clk)
    variable commit : boolean;
    variable occ_n : natural range 0 to DEPTH;
    procedure restart is
    begin
      rs <= R_HDR; bi <= 0; crc <= LK_CRC_INIT;
    end procedure;
  begin
    if rising_edge(clk) then
      rq <= ram(hslot * PB + to_integer(rd_idx) / W);
      rsel <= to_integer(rd_idx) mod W;
      commit := false;
      up_d <= chan_up;
      if rst = '1' then
        restart; occ <= 0; wslot <= 0; hslot <= 0; bad_r <= '0'; down_r <= '0';
        exp_seq <= (others => '0'); exp_pos <= (others => '0');
      elsif run_start = '1' then
        if rs /= R_HDR or bi /= 0 then rs <= R_DISC; bi <= 0; crc <= LK_CRC_INIT; end if;
        occ <= 0; wslot <= 0; hslot <= 0; bad_r <= '0'; down_r <= '0';
        exp_seq <= (others => '0'); exp_pos <= (others => '0');
        c_good <= (others => '0'); c_crc <= (others => '0'); c_sp <= (others => '0');
        c_down <= (others => '0'); c_ovr <= (others => '0'); c_cons <= (others => '0');
      else
        if up_d = '1' and chan_up = '0' then
          c_down <= c_down + 1; down_r <= '1';
          rs <= R_DISC; bi <= 0; crc <= LK_CRC_INIT;
        elsif s_tvalid = '1' and chan_up = '1' then
          case rs is
            when R_HDR =>
              for j in 0 to W - 1 loop hdr(bi * W + j) <= s_tdata(32 * j + 31 downto 32 * j); end loop;
              crc <= lk_crc_beat(crc, s_tdata, W);
              if s_tlast = '1' then
                c_crc <= c_crc + 1; bad_r <= '1'; restart;
              elsif bi = HB - 1 then
                rs <= R_PAY; bi <= bi + 1; store <= '1' when occ < DEPTH else '0';
              else
                bi <= bi + 1;
              end if;
            when R_PAY =>
              if store = '1' then ram(wslot * PB + bi - HB) <= s_tdata; end if;
              crc <= lk_crc_beat(crc, s_tdata, W);
              if s_tlast = '1' then
                c_crc <= c_crc + 1; bad_r <= '1'; restart;
              elsif bi = HB + PB - 1 then
                rs <= R_CRC;
              else
                bi <= bi + 1;
              end if;
            when R_CRC =>
              if s_tlast = '0' then
                c_crc <= c_crc + 1; bad_r <= '1'; rs <= R_DISC; bi <= 0; crc <= LK_CRC_INIT;
              else
                if lk_crc_final(crc) /= s_tdata(31 downto 0) then
                  c_crc <= c_crc + 1; bad_r <= '1';
                elsif hdr(0) /= LK_MAGIC or unsigned(hdr(3)) /= PW then
                  c_sp <= c_sp + 1; bad_r <= '1';
                elsif unsigned(hdr(1)) /= exp_seq or unsigned(hdr(2)) /= exp_pos then
                  c_sp <= c_sp + 1; bad_r <= '1';
                elsif store = '0' then
                  c_ovr <= c_ovr + 1; bad_r <= '1';
                else
                  commit := true;
                  spos(wslot) <= unsigned(hdr(2)); sexp(wslot) <= hdr(4);
                  wslot <= (wslot + 1) mod DEPTH;
                  exp_seq <= exp_seq + 1; exp_pos <= exp_pos + 1; c_good <= c_good + 1;
                  bad_r <= '0'; down_r <= '0';
                end if;
                restart;
              end if;
            when R_DISC =>
              if s_tlast = '1' then restart; end if;
          end case;
        end if;
        occ_n := occ;
        if commit then occ_n := occ_n + 1; end if;
        if pop = '1' and occ > 0 then
          occ_n := occ_n - 1; hslot <= (hslot + 1) mod DEPTH; c_cons <= c_cons + 1;
        end if;
        occ <= occ_n;
      end if;
    end if;
  end process;
end architecture;
```

- [ ] **Step 4: Run the bench to see it pass**

Run: `REGRESS_SCRATCH=~/regress_scratch/t4-b bash sim/regress.sh --only tb_jc_link --keep`
Expected: `OVERALL PASS 1`; the log ends `PASS: tb_jc_link checks=` with n >= 54 (C11 adds about 9).

- [ ] **Step 5: Write and run the mutants**

`sim/mutants/jc_link.json`:

```json
{
  "tb": "tb_jc_link",
  "deps": ["rtl/jc_loader_pkg.vhd", "rtl/jc_link_pkg.vhd", "rtl/jc_link_tx.vhd", "rtl/jc_link_rx.vhd",
           "sim/jc_link_chan_model.vhd", "sim/tb_jc_link.vhd"],
  "stop_time": "50ms",
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "L1", "expect": "KILLED", "file": "rtl/jc_link_rx.vhd",
     "why": "CRC check off (spec 4: fails the bit-flip case)",
     "old": "if lk_crc_final(crc) /= s_tdata(31 downto 0) then",
     "new": "if false then"},
    {"tag": "L2", "expect": "KILLED", "file": "rtl/jc_link_rx.vhd",
     "why": "position check off (spec 4: fails the stale-frame case)",
     "old": "elsif unsigned(hdr(1)) /= exp_seq or unsigned(hdr(2)) /= exp_pos then",
     "new": "elsif unsigned(hdr(1)) /= exp_seq then"},
    {"tag": "L3", "expect": "KILLED", "file": "rtl/jc_link_tx.vhd",
     "why": "resend cap ignored (spec 4)",
     "old": "if nres >= resend_cap then",
     "new": "if false then"},
    {"tag": "L4", "expect": "KILLED", "file": "rtl/jc_link_rx.vhd",
     "why": "sequence check off",
     "old": "elsif unsigned(hdr(1)) /= exp_seq or unsigned(hdr(2)) /= exp_pos then",
     "new": "elsif unsigned(hdr(2)) /= exp_pos then"},
    {"tag": "L5", "expect": "KILLED", "file": "rtl/jc_link_rx.vhd",
     "why": "a cut frame is not discarded after link-down",
     "old": "          rs <= R_DISC; bi <= 0; crc <= LK_CRC_INIT;\n        elsif",
     "new": "        elsif"},
    {"tag": "L6", "expect": "KILLED", "file": "rtl/jc_link_tx.vhd",
     "why": "a RESEND that arrives while busy is dropped again (finding 4): C11 sees no second frame",
     "old": "elsif (resend = '1' or resend_pend = '1') and held = '1' then",
     "new": "elsif resend = '1' and held = '1' then"}
  ]
}
```

Run: `python3 sim/mutate_rows.py sim/mutants/jc_link.json`
Expected: `MUTANTS_OK 7`. (L5: without the discard the cut frame's tail, which the framer resumes when the channel comes back, is parsed as a new header and counted as a CRC failure; C5's `crc_fails = 3` check kills it. L6: reverting to the un-latched check leaves `frames_sent = n0 + 1` and `resends = 0`, failing C11's count and its second `expect_head`.)

- [ ] **Step 6: Commit**

```bash
git add rtl/jc_link_pkg.vhd rtl/jc_link_tx.vhd rtl/jc_link_rx.vhd sim/jc_link_chan_model.vhd sim/tb_jc_link.vhd sim/mutants/jc_link.json
git commit -m "jc loop T4: die-to-die frame, framer with resend cap, deframer with CRC/seq/pos checks" -- \
  rtl/jc_link_pkg.vhd rtl/jc_link_tx.vhd rtl/jc_link_rx.vhd sim/jc_link_chan_model.vhd sim/tb_jc_link.vhd sim/mutants/jc_link.json
```

---
### Task 5: Aurora 64B/66B TX/RX-simplex core, GTG refclk, xsim link test

**Files:**
- Create: `hw/jc/link/aurora_ties.py`, `hw/jc/link/gen_aurora_wrap.py`, `hw/jc/link/test_gen_aurora_wrap.py`, `hw/jc/link/aurora_cfg.tcl`, `hw/jc/link/gen_aurora_ip.tcl`, `hw/jc/link/rtl/jc_gtg_clk.vhd`, `hw/jc/link/eco_aurora_gtg.tcl`, `hw/jc/link/eco_check.tcl`, `hw/jc/link/sim/tb_jc_aurora_link.vhd`, `hw/jc/link/run_aurora_sim.sh`, `hw/jc/link/README.md`
- Generated (committed): `hw/jc/link/rtl/jc_aurora_wrap_l1.vhd`, `hw/jc/link/rtl/jc_aurora_wrap_l4.vhd`

**Interfaces:**
- Consumes (grounded): Aurora 64B66B v12.0 `component.xml` (`/tools/Xilinx/2023.2/Vivado/2023.2/data/ip/xilinx/aurora_64b66b_v12_0/component.xml`): user parameter `dataflow_config` with choice `TX/RX_Simplex` (choice list `choice_pairs_7eb2deb3`, line 53648: one core, independent TX simplex and RX simplex on the same GT channels, separate `tx_channel_up`/`rx_channel_up` and `tx_sys_reset_out`/`rx_sys_reset_out`, outputs `reset2fc`/`reset2fg`); `C_LINE_RATE` range 0.6 to 12.5 (line 54771); `C_REFCLK_FREQUENCY` default 156.250; `C_INIT_CLK` 50 to 200; `C_EXAMPLE_SIMULATION`; `gt_txpolarity` input of width `C_AURORA_LANES` enabled only with `TransceiverControl` true (line 48795); `m_axi_rx_*` has no tready. Input defaults are all 0 in `component.xml`, including `gt_txdiffctrl`: an IP cell left at its defaults drives the minimum TX swing (trap, see Step 1).
- Consumes (grounded): the measured IBERT TX settings `C_TXDIFFCTRL_1 11000`, `C_TXPOSTCURSOR_1 00000`, `C_TXPRECURSOR_1 00000` (`/mnt/storage/fk33_builds/jc_ibert/G/prj/jc_ibert_g.gen/sources_1/ip/jc_ibert_g/synth/ibert_ultrascale_gty_default_port_values.vh:146-150`) and RX_EQ_MODE AUTO, insertion loss 20 dB (`/mnt/storage/fk33_builds/jc_ibert/SUMMARY.md:121`), under which the lane was measured.
- Consumes (grounded): IBERT G's MMCM (`/mnt/storage/fk33_builds/jc_ibert/G/SUMMARY.md` "What was changed": BUFG of the sysclk IBUFDS, MMCME4_BASE CLKIN1_PERIOD 5.000 DIVCLK 4 MULT 25.000 DIV0 8.000, BUFG out, LOC MMCM_X0Y2, `CLOCK_DEDICATED_ROUTE BACKBONE` on the BUFG-to-MMCM net) and its ECO (`G/src/eco_gtg.tcl`, run as `STEPS.OPT_DESIGN.TCL.PRE`; dead ends in that SUMMARY's "Build history": DONT_TOUCH must be lifted for the edit).
- Produces:
  - `aurora_ties.py`: `TIES` (input name -> per-lane bit string), `MAPPED` (input ports the wrapper exposes), `ZERO_OK` (inputs grounded as 0 in `component.xml`), `tie_value(name, width, nlanes)`.
  - `jc_aurora_wrap` (generated per NLANES from the IP's own stub): ports `init_clk, reset_pb, pma_init, refclk_p, refclk_n, tx_polarity(N-1:0), s_tx_tdata(64N-1:0), s_tx_tkeep(8N-1:0), s_tx_tlast, s_tx_tvalid, s_tx_tready, m_rx_tdata, m_rx_tkeep, m_rx_tlast, m_rx_tvalid, txp, txn, rxp, rxn (N-1:0), tx_channel_up, rx_channel_up, user_clk, tx_sys_reset, rx_sys_reset, gt_pll_lock`.
  - `jc_gtg_clk`: `sys_i` (IBUFDS output) -> `sclk` (BUFG, 200 MHz, also `init_clk`), `gtg_clk` (156.25 MHz), `locked`.
  - `eco_aurora_gtg.tcl`: GTGREFCLK0 of the Aurora's GTYE4_COMMON(s) to `gtg_clk`, QPLL0REFCLKSEL to 111; prints `ECOA_DONE` or errors `ECOA_FAIL`.
  - Sentinels: `^AURORA_IP_OK`, `^AURORA_CFG_FAIL`, `^AURORA_WRAP_OK`, `^AURORA_WRAP_FAIL`, `^ECOA_DONE`, `^AURSIM_PASS`, `^AURSIM_FAIL`.

**Stop conditions (task brief: raw GTYE4 is out of scope).** If Step 3 prints `AURORA_CFG_FAIL` for anything other than the deliberate mutant (the IP will not take `TX/RX_Simplex`, the line rate, the refclk on quad X0Y2 refclk1, or the lane sites in batch mode), or Step 6's NLANES 1 simulation never raises `rx_channel_up`, stop the task, record the failing parameter and the IP's own message in `hw/jc/link/README.md`, and report. Tasks 6 and 7 then proceed with `HAS_LINK => false`, and Task 8 runs steps 0 and 3 only.

- [ ] **Step 1: Write the tie table, the wrapper generator and its test**

`hw/jc/link/aurora_ties.py`:

```python
"""hw/jc/link/aurora_ties.py -- every input of the Aurora 64B66B core that tok_loop does not
drive, and the value it is tied to (plan 2026-11-04 Task 5). Read by gen_aurora_wrap.py (the
xsim wrapper) and by hw/jc/card/gen_jc_card.py (the card's xlconstant cells), so the bench and
the card cannot tie differently.

TRAP: component.xml gives every one of these a default of 0, including gt_txdiffctrl. A core
left at its defaults transmits at the minimum swing. The three TX values below are the IBERT
defaults the lane was measured with (jc_ibert/G/.../ibert_ultrascale_gty_default_port_values.vh
:146-150); the rest are component.xml's own defaults.
"""

# inputs the wrapper exposes as ports (and the card connects to real nets)
MAPPED = {
    "init_clk": "init_clk", "reset_pb": "reset_pb", "pma_init": "pma_init",
    "gt_refclk1_p": "refclk_p", "gt_refclk1_n": "refclk_n",
    "gt_txpolarity": "tx_polarity",
    "s_axi_tx_tdata": "s_tx_tdata", "s_axi_tx_tkeep": "s_tx_tkeep",
    "s_axi_tx_tlast": "s_tx_tlast", "s_axi_tx_tvalid": "s_tx_tvalid",
    "rxp": "rxp", "rxn": "rxn",
}
# outputs the wrapper exposes; every other output is left open
MAPPED_OUT = {
    "s_axi_tx_tready": "s_tx_tready",
    "m_axi_rx_tdata": "m_rx_tdata", "m_axi_rx_tkeep": "m_rx_tkeep",
    "m_axi_rx_tlast": "m_rx_tlast", "m_axi_rx_tvalid": "m_rx_tvalid",
    "txp": "txp", "txn": "txn",
    "tx_channel_up": "tx_channel_up", "rx_channel_up": "rx_channel_up",
    "user_clk_out": "user_clk", "tx_sys_reset_out": "tx_sys_reset",
    "rx_sys_reset_out": "rx_sys_reset", "gt_pll_lock": "gt_pll_lock",
}
# per-lane TX settings the lane was measured with (IBERT defaults), 5 bits per lane
TIES = {
    "gt_txdiffctrl": "11000",
    "gt_txpostcursor": "00000",
    "gt_txprecursor": "00000",
}
# inputs whose component.xml default is 0 and whose 0 is the intended value
ZERO_OK = {
    "gt_eyescanreset", "gt_eyescantrigger", "gt_pcsrsvdin", "gt_rxbufreset",
    "gt_rxcdrhold", "gt_rxdfelpmreset", "gt_rxlpmen", "gt_rxpcsreset",
    "gt_rxpmareset", "gt_rxprbscntreset", "gt_rxprbssel", "gt_rxrate",
    "gt_txinhibit", "gt_txpcsreset", "gt_txpmareset", "gt_txprbsforceerr",
    "gt_txprbssel", "power_down", "gt_rxcdrovrden_in",
}


def tie_value(name, width, nlanes):
    """The tie for input `name` of `width` bits, as a bit string MSB first, or None if the
    port is not in the table (the caller refuses)."""
    if name in TIES:
        per = TIES[name]
        if width != len(per) * nlanes:
            raise ValueError("%s is %d bits, the table expects %d x %d"
                             % (name, width, len(per), nlanes))
        return per * nlanes
    if name in ZERO_OK:
        return "0" * width
    return None
```

`hw/jc/link/gen_aurora_wrap.py`:

```python
#!/usr/bin/env python3
"""hw/jc/link/gen_aurora_wrap.py -- write jc_aurora_wrap_l<N>.vhd from the Aurora IP's own
VHDL stub (plan 2026-11-04 Task 5). Every input of the stub is either MAPPED to a wrapper port
or tied from aurora_ties.py; an input in neither refuses (AURORA_WRAP_FAIL, exit 2) and leaves
the output untouched, so a new IP port can never be tied by accident.

usage: gen_aurora_wrap.py <stub.vhdl> <nlanes> <out.vhd> [--check]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, HERE)
import genstamp  # noqa: E402
import aurora_ties as T  # noqa: E402

PORT_RE = re.compile(r"^\s*(\w+)\s*:\s*(in|out)\s+STD_LOGIC(?:_VECTOR\s*\(\s*(\d+)\s+(downto|to)\s+(\d+)\s*\))?",
                     re.IGNORECASE)


def parse_stub(text):
    """[(name, dir, width, rng)] in stub order; rng is the VHDL range text or None."""
    ports = []
    for line in text.splitlines():
        m = PORT_RE.match(line)
        if not m:
            continue
        name, d = m.group(1), m.group(2).lower()
        if m.group(3) is None:
            ports.append((name, d, 1, None))
        else:
            a, b = int(m.group(3)), int(m.group(5))
            ports.append((name, d, abs(a - b) + 1, "%d %s %d" % (a, m.group(4).lower(), b)))
    return ports


def render(ports, nlanes, stub_rel):
    errs = []
    for (n, d, w, _) in ports:
        if d == "in" and n not in T.MAPPED and T.tie_value(n, w, nlanes) is None:
            errs.append(n)
    if errs:
        raise SystemExit("AURORA_WRAP_FAIL inputs not in aurora_ties.py: " + " ".join(errs))
    have = {n for (n, _, _, _) in ports}
    missing = [n for n in list(T.MAPPED) + list(T.MAPPED_OUT) if n not in have]
    if missing:
        raise SystemExit("AURORA_WRAP_FAIL stub lacks mapped ports: " + " ".join(missing))
    cmd = ["python3", "hw/jc/link/gen_aurora_wrap.py", stub_rel, str(nlanes),
           "hw/jc/link/rtl/jc_aurora_wrap_l%d.vhd" % nlanes]
    out = ["-- hw/jc/link/rtl/jc_aurora_wrap_l%d.vhd" % nlanes,
           "-- GENERATED by hw/jc/link/gen_aurora_wrap.py from the Aurora IP stub; do not edit.",
           "-- Every unmapped input is tied from hw/jc/link/aurora_ties.py (plan 2026-11-04 Task 5)."]
    out.append(genstamp.stamp(cmd, [("argv", "stub", stub_rel), ("argv", "nlanes", str(nlanes))]).rstrip("\n"))
    out += ["library ieee;", "use ieee.std_logic_1164.all;", "",
            "entity jc_aurora_wrap is", "  port("]
    ent = []
    by = {n: (d, w, r) for (n, d, w, r) in ports}
    for src, dst in list(T.MAPPED.items()) + list(T.MAPPED_OUT.items()):
        d, w, _ = by[src]
        r = by[src][2]
        typ = "std_logic" if r is None else "std_logic_vector(%d downto 0)" % (w - 1)
        ent.append("    %s : %s %s" % (dst, d, typ))
    out.append(";\n".join(ent) + ");")
    out += ["end entity;", "", "architecture wrap of jc_aurora_wrap is", "  component jc_aurora", "    port("]
    comp = []
    for (n, d, w, r) in ports:
        comp.append("      %s : %s %s" % (n, d, "std_logic" if r is None else "std_logic_vector(%s)" % r))
    out.append(";\n".join(comp) + ");")
    out += ["  end component;", "begin", "  u_core : jc_aurora", "    port map("]
    pm = []
    for (n, d, w, r) in ports:
        if n in T.MAPPED or n in T.MAPPED_OUT:
            pm.append("      %s => %s" % (n, T.MAPPED.get(n) or T.MAPPED_OUT[n]))
        elif d == "in":
            v = T.tie_value(n, w, nlanes)
            pm.append("      %s => %s" % (n, "'%s'" % v if r is None else '"%s"' % v))
        else:
            pm.append("      %s => open" % n)
    out.append(",\n".join(pm) + ");")
    out += ["end architecture;", ""]
    return "\n".join(out)


def main(argv):
    check = "--check" in argv
    args = [a for a in argv if a != "--check"]
    if len(args) != 3:
        raise SystemExit(__doc__)
    stub, nlanes, dst = args[0], int(args[1]), args[2]
    ports = parse_stub(open(stub).read())
    if not ports:
        raise SystemExit("AURORA_WRAP_FAIL no ports parsed from " + stub)
    text = render(ports, nlanes, os.path.relpath(stub, REPO))
    if check:
        same = os.path.exists(dst) and open(dst).read() == text
        print("AURORA_WRAP_OK check" if same else "AURORA_WRAP_FAIL check: %s differs" % dst)
        return 0 if same else 1
    open(dst, "w").write(text)
    print("AURORA_WRAP_OK %s ports=%d" % (dst, len(ports)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

A stub port declared as a vector (even `( 0 to 0 )`) stays a vector in the wrapper, declared `(w-1 downto 0)`; the association is whole-array, so an ascending stub range (`0 to 63`, the Aurora convention) maps wrapper bit 63 to stub bit 0. Both ends of the link use the same wrapper, so the order is transparent end to end.

`hw/jc/link/test_gen_aurora_wrap.py`:

```python
"""pytest for gen_aurora_wrap.py: a fixture stub in the format Vivado writes."""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_aurora_wrap as G  # noqa: E402

STUB = """entity jc_aurora is
  Port (
    s_axi_tx_tdata : in STD_LOGIC_VECTOR ( 0 to 63 );
    s_axi_tx_tkeep : in STD_LOGIC_VECTOR ( 0 to 7 );
    s_axi_tx_tlast : in STD_LOGIC;
    s_axi_tx_tvalid : in STD_LOGIC;
    s_axi_tx_tready : out STD_LOGIC;
    m_axi_rx_tdata : out STD_LOGIC_VECTOR ( 0 to 63 );
    m_axi_rx_tkeep : out STD_LOGIC_VECTOR ( 0 to 7 );
    m_axi_rx_tlast : out STD_LOGIC;
    m_axi_rx_tvalid : out STD_LOGIC;
    rxp : in STD_LOGIC_VECTOR ( 0 to 0 );
    rxn : in STD_LOGIC_VECTOR ( 0 to 0 );
    txp : out STD_LOGIC_VECTOR ( 0 to 0 );
    txn : out STD_LOGIC_VECTOR ( 0 to 0 );
    gt_refclk1_p : in STD_LOGIC;
    gt_refclk1_n : in STD_LOGIC;
    init_clk : in STD_LOGIC;
    reset_pb : in STD_LOGIC;
    pma_init : in STD_LOGIC;
    power_down : in STD_LOGIC;
    gt_txpolarity : in STD_LOGIC_VECTOR ( 0 to 0 );
    gt_txdiffctrl : in STD_LOGIC_VECTOR ( 4 downto 0 );
    gt_txpostcursor : in STD_LOGIC_VECTOR ( 4 downto 0 );
    gt_txprecursor : in STD_LOGIC_VECTOR ( 4 downto 0 );
    gt_rxlpmen : in STD_LOGIC_VECTOR ( 0 to 0 );
    tx_channel_up : out STD_LOGIC;
    rx_channel_up : out STD_LOGIC;
    user_clk_out : out STD_LOGIC;
    tx_sys_reset_out : out STD_LOGIC;
    rx_sys_reset_out : out STD_LOGIC;
    gt_pll_lock : out STD_LOGIC;
    reset2fc : out STD_LOGIC
  );
end jc_aurora;
"""


def test_parse_and_ties():
    ports = G.parse_stub(STUB)
    assert len(ports) == 31
    text = G.render(ports, 1, "x/stub.vhdl")
    assert 'gt_txdiffctrl => "11000"' in text          # the measured swing, not the 0 default
    assert 'gt_rxlpmen => "0"' in text
    assert "power_down => '0'" in text
    assert "reset2fc => open" in text
    assert "s_axi_tx_tdata => s_tx_tdata" in text


def test_unknown_input_refuses(tmp_path):
    bad = STUB.replace("    reset2fc : out STD_LOGIC\n", "    reset2fc : out STD_LOGIC;\n    gt_mystery : in STD_LOGIC\n")
    stub = tmp_path / "s.vhdl"
    stub.write_text(bad)
    dst = tmp_path / "w.vhd"
    r = subprocess.run([sys.executable, os.path.join(HERE, "gen_aurora_wrap.py"), str(stub), "1", str(dst)],
                       capture_output=True, text=True)
    assert r.returncode != 0 and "AURORA_WRAP_FAIL" in (r.stderr + r.stdout) and "gt_mystery" in (r.stderr + r.stdout)
    assert not dst.exists()


def test_diffctrl_width_checked():
    ports = [p if p[0] != "gt_txdiffctrl" else ("gt_txdiffctrl", "in", 4, "3 downto 0") for p in G.parse_stub(STUB)]
    try:
        G.render(ports, 1, "x")
    except ValueError as e:
        assert "gt_txdiffctrl" in str(e)
    else:
        raise AssertionError("a 4-bit diffctrl was accepted")
```

Run: `python3 -m pytest -q hw/jc/link/test_gen_aurora_wrap.py`
Expected: `3 passed`. Mutant (teeth): set `TIES["gt_txdiffctrl"] = "00000"` and rerun: `test_parse_and_ties` must fail; restore.

- [ ] **Step 2: Write the IP configuration and generator**

`hw/jc/link/aurora_cfg.tcl`:

```tcl
# hw/jc/link/aurora_cfg.tcl -- the lane table and the Aurora 64B66B configuration
# (spec 2026-11-04 section 1b.2; plan Task 5). Sourced by gen_aurora_ip.tcl and by the card
# build's BD script (gen_jc_card.py emits a `source` of this file).
#
# Lane table: lane -> {site txpol rxpol}. Lane 0 is MEASURED (IBERT, die 0 X0Y0 TX -> die 1
# X0Y0 RX, polarity 0/0 after the AC caps were fitted). Lanes 1-3 are for the NLANES 4
# simulation only: their caps are not fitted (spec "Open") and their polarities are unmeasured.
# txpol is XORed with LINK_CTRL bit 2 at runtime; rxpol is an expectation (plan D5).
set JC_LANES {
  0 {GTYE4_CHANNEL_X0Y0 0 0}
  1 {GTYE4_CHANNEL_X0Y1 0 0}
  2 {GTYE4_CHANNEL_X0Y2 0 0}
  3 {GTYE4_CHANNEL_X0Y3 0 0}
}

# jc_aurora_config nlanes rate mode -> list of CONFIG.* name/value pairs.
# rate: 10.3125 (first build) or 1.25 (fallback). mode: card | sim (sim shortens the IP's
# internal timers through C_EXAMPLE_SIMULATION).
proc jc_aurora_config {nlanes rate mode} {
  global JC_LANES
  if {$nlanes < 1 || $nlanes > 4} { error "AURORA_CFG_FAIL nlanes $nlanes" }
  if {$rate ne "10.3125" && $rate ne "1.25"} { error "AURORA_CFG_FAIL rate $rate" }
  set first [lindex [dict get $JC_LANES 0] 0]
  if {![regexp {X(\d+)Y(\d+)$} $first -> x0 y0]} { error "AURORA_CFG_FAIL site $first" }
  set cfg [list \
    CONFIG.dataflow_config      {TX/RX_Simplex} \
    CONFIG.interface_mode       {Framing} \
    CONFIG.crc_mode             {false} \
    CONFIG.flow_mode            {None} \
    CONFIG.C_AURORA_LANES       $nlanes \
    CONFIG.C_LINE_RATE          $rate \
    CONFIG.C_REFCLK_FREQUENCY   {156.250} \
    CONFIG.C_INIT_CLK           {200.0} \
    CONFIG.SupportLevel         {1} \
    CONFIG.TransceiverControl   {true} \
    CONFIG.RX_EQ_MODE           {AUTO} \
    CONFIG.INS_LOSS_NYQ         {20} \
    CONFIG.C_START_QUAD         "Quad_X${x0}Y[expr {$y0 / 4}]" \
    CONFIG.C_START_LANE         "X${x0}Y${y0}" \
    CONFIG.C_EXAMPLE_SIMULATION [expr {$mode eq "sim" ? "true" : "false"}]]
  # C_GT_LOC_<row+1> = <lane+1> for each lane's site row; every other row stays X (the IP default)
  for {set l 0} {$l < $nlanes} {incr l} {
    set s [lindex [dict get $JC_LANES $l] 0]
    regexp {Y(\d+)$} $s -> y
    lappend cfg CONFIG.C_GT_LOC_[expr {$y + 1}] [expr {$l + 1}]
  }
  return $cfg
}

# jc_lane_txpol nlanes -> bit string, lane nlanes-1 first (MSB), for the gt_txpolarity XOR
proc jc_lane_txpol {nlanes} {
  global JC_LANES
  set s ""
  for {set l [expr {$nlanes - 1}]} {$l >= 0} {incr l -1} { append s [lindex [dict get $JC_LANES $l] 1] }
  return $s
}

# jc_aurora_refclk obj -> the C_REFCLK_SOURCE choice naming refclk1 of quad X0Y2
# (MGTREFCLK1 of bank 126, pin AC36). obj is an IP (get_ips) or a BD cell (get_bd_cells).
# Shared from the start (finding 18) so the card build (Task 7) never duplicates this pick.
proc jc_aurora_refclk {obj} {
  set choices [list_property_value CONFIG.C_REFCLK_SOURCE $obj]
  puts "AURORA_REFCLK_CHOICES $choices"
  foreach c $choices { if {[regexp -nocase {REFCLK1.*X0Y2} $c]} { return $c } }
  error "AURORA_CFG_FAIL refclk: no choice names REFCLK1 of quad X0Y2 in {$choices}"
}

# jc_aurora_check obj cfg: every CONFIG the object was given reads back (numbers compared
# as numbers: the IP may print 200.0 as 200.0000). Errors AURORA_CFG_FAIL readback.
proc jc_aurora_check {obj cfg} {
  set bad {}
  foreach {k v} $cfg {
    set got [get_property $k $obj]
    if {$got ne $v && !([string is double -strict $got] && [string is double -strict $v] && $got == $v)} {
      lappend bad "$k=$got (asked $v)"
    }
    puts "AURORA_CFG $k=$got"
  }
  if {[llength $bad]} { error "AURORA_CFG_FAIL readback: $bad" }
}
```

`hw/jc/link/gen_aurora_ip.tcl`:

```tcl
# hw/jc/link/gen_aurora_ip.tcl -- create the Aurora 64B66B IP in batch mode, read back every
# CONFIG it was given, check the generated GT LOCs against the lane table, and write the stub
# (plan 2026-11-04 Task 5). No hardware: Vivado project mode, synth only.
#
# usage: vivado -mode batch -source hw/jc/link/gen_aurora_ip.tcl -tclargs <out_dir> <nlanes> <rate> <card|sim>
# env:   JC_AUR_MUTATE=permute  (Step 3 teeth check: set the IP's lane map from a rotated table)
# prints ^AURORA_IP_OK or errors ^AURORA_CFG_FAIL <what>
set here [file dirname [file normalize [info script]]]
source [file join $here aurora_cfg.tcl]
lassign $argv out nlanes rate mode
set part xcvu35p-fsvh2104-2L-e
file mkdir $out
create_project -force aur $out/prj -part $part
set cfg [jc_aurora_config $nlanes $rate $mode]
if {[info exists ::env(JC_AUR_MUTATE)] && $::env(JC_AUR_MUTATE) eq "permute"} {
  set rot {}
  foreach {k v} $cfg {
    if {[string match CONFIG.C_GT_LOC_* $k]} { set v [expr {$v % $nlanes + 1}] }
    lappend rot $k $v
  }
  set cfg $rot
  puts "AURORA_MUTANT permute"
}
create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -module_name jc_aurora
set ip [get_ips jc_aurora]

# finding 18: the refclk pick and the readback are jc_aurora_refclk/jc_aurora_check, shared
# from aurora_cfg.tcl (sourced above) since Task 5, never duplicated for Task 7 to extract.
lappend cfg CONFIG.C_REFCLK_SOURCE [jc_aurora_refclk $ip]
if {[catch {set_property -dict $cfg $ip} msg]} { error "AURORA_CFG_FAIL set_property: $msg" }
jc_aurora_check $ip $cfg
set pick [get_property CONFIG.C_REFCLK_SOURCE $ip]

generate_target all $ip
synth_ip $ip
set ipdir [get_property IP_DIR $ip]

# GT LOCs as the IP wrote them, against the lane table (the configured map, not the intent)
set locs {}
foreach f [glob -nocomplain $ipdir/*.xdc $ipdir/*/*.xdc] {
  set fh [open $f]; set t [read $fh]; close $fh
  foreach {all site cell} [regexp -all -inline {set_property LOC (GTYE4_CHANNEL_X\d+Y\d+) \[get_cells [^\]]*?(gen_channel_container\[\d+\][^\]]*?gen_gtye4_channel_inst\[\d+\])} $t] {
    lappend locs $site $cell
  }
}
puts "AURORA_LOCS $locs"
if {[llength $locs] / 2 != $nlanes} { error "AURORA_CFG_FAIL locs: [expr {[llength $locs]/2}] channel LOCs for $nlanes lanes" }
# lane l is the l-th channel of the core's channel order; the IP orders channels by lane
set sites {}
foreach {s c} $locs { lappend sites $s }
for {set l 0} {$l < $nlanes} {incr l} {
  set want [lindex [dict get $JC_LANES $l] 0]
  if {[lindex $sites $l] ne $want} { error "AURORA_CFG_FAIL lane map: lane $l at [lindex $sites $l], table says $want" }
}

# the stub the wrapper generator reads, and the sources the ECO question needs
set stub [lindex [glob $ipdir/jc_aurora_stub.vhdl] 0]
file copy -force $stub $out/jc_aurora_stub.vhdl
set gtg [exec sh -c "grep -rln -e GTGREFCLK0 -e QPLL0REFCLKSEL $ipdir || true"]
puts "AURORA_GTG_SOURCES $gtg"
puts "AURORA_IP_OK nlanes=$nlanes rate=$rate mode=$mode refclk=$pick out=$out"
```

The LOC regexp is a first guess at the IP's generated XDC format (not readable before generation: see "Not grounded"). If it matches nothing, print the IP's XDC lines containing `GTYE4_CHANNEL` (`grep -rn GTYE4_CHANNEL $ipdir`), fix the regexp to the format seen, and record the format in `hw/jc/link/README.md`. Never weaken the check to a count.

- [ ] **Step 3: Generate the IPs and run the configuration teeth check**

Memory budget, stated before running: one Vivado on this box at a time (check presence with the `/proc/PID/exe` loop in CLAUDE.md first; none may be running). An IP generate + `synth_ip` is far below the engine-only build's 10.66 GB (ESTIMATE: a single small IP; cap it anyway).

```bash
B=/mnt/storage/fk33_builds/jc_link_ip
mkdir -p $B
R=$(git rev-parse --show-toplevel)   # finding 6: this worktree, never a hardcoded checkout
cat > $B/run_ip.sh <<'SH'
#!/bin/bash
set -u
cd "$R"
for spec in "l1 1 10.3125 sim" "l4 4 10.3125 sim" "l1card 1 10.3125 card" "l1slow 1 1.25 card"; do
  set -- $spec
  vivado -mode batch -nojournal -log /mnt/storage/fk33_builds/jc_link_ip/$1.log \
    -source hw/jc/link/gen_aurora_ip.tcl -tclargs /mnt/storage/fk33_builds/jc_link_ip/$1 $2 $3 $4
done
JC_AUR_MUTATE=permute vivado -mode batch -nojournal -log /mnt/storage/fk33_builds/jc_link_ip/l4perm.log \
  -source hw/jc/link/gen_aurora_ip.tcl -tclargs /mnt/storage/fk33_builds/jc_link_ip/l4perm 4 10.3125 sim
echo RUN_IP_DONE
SH
chmod +x $B/run_ip.sh
systemd-run --user --scope --setenv=R="$R" -p MemoryHigh=8G -p MemoryMax=10G $B/run_ip.sh > $B/run_ip.out 2>&1
grep -E '^(AURORA_IP_OK|AURORA_CFG_FAIL)' $B/l1.log $B/l4.log $B/l1card.log $B/l1slow.log $B/l4perm.log
```

Expected: `AURORA_IP_OK` in `l1.log`, `l4.log`, `l1card.log`, `l1slow.log`; `AURORA_CFG_FAIL lane map: lane 0 at ...` in `l4perm.log` (the mutant: the IP's lane map rotated against the table is refused). Any other `AURORA_CFG_FAIL` is a stop condition. Record in `hw/jc/link/README.md` (MEASURED, quote the log lines): `AURORA_REFCLK_CHOICES`, the chosen refclk, every `AURORA_CFG` line of `l1card.log`, `AURORA_LOCS`, and `AURORA_GTG_SOURCES`.

Then generate the wrappers:

```bash
python3 hw/jc/link/gen_aurora_wrap.py /mnt/storage/fk33_builds/jc_link_ip/l1/jc_aurora_stub.vhdl 1 hw/jc/link/rtl/jc_aurora_wrap_l1.vhd
python3 hw/jc/link/gen_aurora_wrap.py /mnt/storage/fk33_builds/jc_link_ip/l4/jc_aurora_stub.vhdl 4 hw/jc/link/rtl/jc_aurora_wrap_l4.vhd
```

Expected: `AURORA_WRAP_OK` twice. On `AURORA_WRAP_FAIL inputs not in aurora_ties.py: <names>`, read each named port's `defaultValue` in `component.xml` (the awk in this plan's Interfaces note) and its PG074 description; add it to `ZERO_OK` only if 0 is the intended value, otherwise to `TIES` with a cited source; never add a port to make the generator pass without that reading.

- [ ] **Step 4: Write the GTG refclk MMCM and the ECO**

`hw/jc/link/rtl/jc_gtg_clk.vhd`:

```vhdl
-- hw/jc/link/rtl/jc_gtg_clk.vhd -- 156.25 MHz for the Aurora QPLL's GTGREFCLK0, from the
-- 200 MHz board clock (spec 2026-11-04 section 1b.2: the IBERT G path, which locked on both
-- dies). Parameters copied from jc_qpll_census.vhd u_mmcm (b4) as IBERT G did: BUFG of the
-- IBUFDS output, MMCME4_BASE 200 * 25 / 4 / 8 = 156.25 (1250 MHz VCO), feedback through a
-- BUFG, output BUFG. RST is a power-on reset of 2**POR_LOG2 sclk cycles (census POR_LOG2 8;
-- IBERT G counted CFGMCLK, which the card's STARTUPE3 owner does not export). The XDC puts
-- the MMCM at MMCM_X0Y2 and CLOCK_DEDICATED_ROUTE BACKBONE on the BUFG -> MMCM net.
-- DONT_TOUCH keeps the load-less gtg_clk BUFG until the ECO connects it (IBERT G item 1).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library unisim;
use unisim.vcomponents.all;

entity jc_gtg_clk is
  generic(POR_LOG2 : positive := 8);
  port(
    sys_i   : in  std_logic;     -- the board clock's IBUFDS output (200 MHz)
    sclk    : out std_logic;     -- BUFG of sys_i: init_clk of the Aurora core
    gtg_clk : out std_logic;     -- 156.25 MHz, to GTGREFCLK0 by the ECO
    locked  : out std_logic);
end entity;

architecture rtl of jc_gtg_clk is
  signal sclk_i, fb, fbg, o0, gclk : std_logic;
  signal por_cnt : unsigned(POR_LOG2 downto 0) := (others => '0');
  signal por : std_logic := '1';
  attribute DONT_TOUCH : string;
  attribute DONT_TOUCH of u_sbg, u_mmcm, u_gbg : label is "TRUE";
  attribute DONT_TOUCH of gclk : signal is "TRUE";
begin
  u_sbg : BUFG port map(I => sys_i, O => sclk_i);
  sclk <= sclk_i;
  u_mmcm : MMCME4_BASE
    generic map(CLKIN1_PERIOD => 5.000, DIVCLK_DIVIDE => 4,
                CLKFBOUT_MULT_F => 25.000, CLKOUT0_DIVIDE_F => 8.000)
    port map(CLKIN1 => sclk_i, CLKFBIN => fbg, CLKFBOUT => fb, CLKFBOUTB => open,
             CLKOUT0 => o0, CLKOUT0B => open, CLKOUT1 => open, CLKOUT1B => open,
             CLKOUT2 => open, CLKOUT2B => open, CLKOUT3 => open, CLKOUT3B => open,
             CLKOUT4 => open, CLKOUT5 => open, CLKOUT6 => open,
             LOCKED => locked, PWRDWN => '0', RST => por);
  u_fbg : BUFG port map(I => fb, O => fbg);
  u_gbg : BUFG port map(I => o0, O => gclk);
  gtg_clk <= gclk;
  process(sclk_i)
  begin
    if rising_edge(sclk_i) then
      if por_cnt(POR_LOG2) = '0' then por_cnt <= por_cnt + 1; end if;
      por <= not por_cnt(POR_LOG2);
    end if;
  end process;
end architecture;
```

`hw/jc/link/eco_aurora_gtg.tcl`:

```tcl
# hw/jc/link/eco_aurora_gtg.tcl -- netlist ECO for JC_LINK_REFCLK=gtg (plan D11), run as
# STEPS.OPT_DESIGN.TCL.PRE or before opt_design in a non-project flow: after link_design.
# Shape: IBERT G's src/eco_gtg.tcl. The Aurora core has no GTGREFCLK port, so:
#  1. each GTYE4_COMMON under the Aurora cell: GTGREFCLK0 from <const0> to the gtg_clk net;
#  2. QPLL0REFCLKSEL[2:0] to VCC (111 = GTGREFCLK0) when the IP drives them from constants.
#     If the IP drives them from flops or logic, refuse: that select is runtime state and an
#     ECO on it is not the power-up value.
# Inputs: ::JC_AUR_CELL (hier name of the Aurora cell), ::JC_GTG_PIN (the gtg BUFG output pin).
# Prints ^ECOA_DONE, errors ^ECOA_FAIL.
set gnet [get_nets -of_objects [get_pins $::JC_GTG_PIN]]
if {$gnet eq ""} { error "ECOA_FAIL no net on $::JC_GTG_PIN" }
set commons [lsort [get_cells -hier -filter "REF_NAME == GTYE4_COMMON && NAME =~ $::JC_AUR_CELL/*"]]
if {[llength $commons] < 1} { error "ECOA_FAIL no GTYE4_COMMON under $::JC_AUR_CELL" }
puts "ECOA_DT before=[get_property DONT_TOUCH $gnet]"
set_property DONT_TOUCH false $gnet
set vcc [get_nets -hier -filter {TYPE == POWER} -quiet]
if {$vcc eq ""} {
  create_cell -reference VCC eco_aur_vcc
  create_net eco_aur_vcc_net
  connect_net -net eco_aur_vcc_net -objects [get_pins eco_aur_vcc/P]
  set vcc [get_nets eco_aur_vcc_net]
} else {
  set vcc [lindex $vcc 0]
}
foreach c $commons {
  set p [get_pins $c/GTGREFCLK0]
  set old [get_nets -of_objects $p]
  if {[get_property TYPE $old] ne "GROUND"} { error "ECOA_FAIL $p was on $old ([get_property TYPE $old])" }
  disconnect_net -objects $p
  connect_net -hier -net $gnet -objects $p
  puts "ECOA_CONN $p old=$old new=[get_nets -of_objects $p]"
  foreach k {0 1 2} {
    set sp [get_pins "$c/QPLL0REFCLKSEL\[$k\]"]
    set n [get_nets -of_objects $sp]
    set t [get_property TYPE $n]
    if {$t ne "GROUND" && $t ne "POWER"} {
      error "ECOA_FAIL $sp is driven by $n (TYPE $t): a runtime select; use the IP's port instead"
    }
    if {$t eq "GROUND"} {
      disconnect_net -objects $sp
      connect_net -hier -net $vcc -objects $sp
    }
    puts "ECOA_SEL $c b$k was $t now [get_property TYPE [get_nets -of_objects $sp]]"
  }
}
set_property DONT_TOUCH true $gnet
puts "ECOA_DONE commons=[llength $commons] loads=[llength [get_pins -leaf -of_objects $gnet -filter {DIRECTION == IN}]]"
```

`hw/jc/link/eco_check.tcl` (exercises the ECO on a synthesized netlist of the real core, no implementation):

```tcl
# hw/jc/link/eco_check.tcl -- run eco_aurora_gtg.tcl on a linked netlist of the card-mode core
# plus jc_gtg_clk, and check the result (plan 2026-11-04 Task 5 Step 5). Synth + link only.
# usage: vivado -mode batch -source hw/jc/link/eco_check.tcl -tclargs <ip_out_dir (l1card)> <work_dir>
lassign $argv ipout work
set here [file dirname [file normalize [info script]]]
set part xcvu35p-fsvh2104-2L-e
file mkdir $work
set xci [lindex [glob $ipout/prj/aur.srcs/sources_1/ip/jc_aurora/jc_aurora.xci] 0]
read_ip $xci
read_vhdl -vhdl2008 [list $here/rtl/jc_gtg_clk.vhd $here/rtl/jc_aurora_wrap_l1.vhd]
set fh [open $work/eco_top.vhd w]
puts $fh {library ieee; use ieee.std_logic_1164.all;
entity eco_top is port(sys_i : in std_logic; refclk_p, refclk_n : in std_logic;
  rxp, rxn : in std_logic_vector(0 downto 0); txp, txn : out std_logic_vector(0 downto 0);
  up : out std_logic); end entity;
architecture a of eco_top is
  signal sclk, gclk, lk, uclk, tr, txu, rxu : std_logic;
  signal rd : std_logic_vector(63 downto 0);
begin
  u_gtg : entity work.jc_gtg_clk port map(sys_i => sys_i, sclk => sclk, gtg_clk => gclk, locked => lk);
  u_aur : entity work.jc_aurora_wrap port map(init_clk => sclk, reset_pb => '0', pma_init => not lk,
    refclk_p => refclk_p, refclk_n => refclk_n, tx_polarity => "0",
    s_tx_tdata => (others => '0'), s_tx_tkeep => (others => '1'), s_tx_tlast => '0', s_tx_tvalid => '0',
    s_tx_tready => tr, m_rx_tdata => rd, m_rx_tkeep => open, m_rx_tlast => open, m_rx_tvalid => open,
    txp => txp, txn => txn, rxp => rxp, rxn => rxn, tx_channel_up => txu, rx_channel_up => rxu,
    user_clk => uclk, tx_sys_reset => open, rx_sys_reset => open, gt_pll_lock => open);
  up <= txu and rxu and rd(0);
end architecture;}
close $fh
read_vhdl -vhdl2008 $work/eco_top.vhd
synth_design -top eco_top -part $part -mode out_of_context
set ::JC_AUR_CELL u_aur/u_core
set ::JC_GTG_PIN u_gtg/u_gbg/O
source $here/eco_aurora_gtg.tcl
foreach c [get_cells -hier -filter {REF_NAME == GTYE4_COMMON}] {
  set d [get_cells -of_objects [get_pins -leaf -of_objects [get_nets -of_objects [get_pins $c/GTGREFCLK0]] -filter {DIRECTION == OUT}]]
  puts "ECOCHK $c GTGREFCLK0 <- $d ([get_property REF_NAME $d])"
  if {[get_property REF_NAME $d] ne "BUFGCE" && [get_property REF_NAME $d] ne "BUFG"} { error "ECOCHK_FAIL $c" }
  foreach k {0 1 2} {
    if {[get_property TYPE [get_nets -of_objects [get_pins "$c/QPLL0REFCLKSEL\[$k\]"]]] ne "POWER"} { error "ECOCHK_FAIL $c sel $k" }
  }
}
opt_design
puts "ECOCHK_OK"
```

- [ ] **Step 5: Run the ECO check**

Same budget statement as Step 3 (one Vivado; an OOC synth of one GT core, capped at 8G).

```bash
B=/mnt/storage/fk33_builds/jc_link_ip
systemd-run --user --scope -p MemoryHigh=8G -p MemoryMax=10G \
  vivado -mode batch -nojournal -log $B/eco_check.log -source hw/jc/link/eco_check.tcl -tclargs $B/l1card $B/eco_check
grep -E '^(ECOA_DONE|ECOA_FAIL|ECOCHK_OK|ECOCHK_FAIL)' $B/eco_check.log
```

Expected: `ECOA_DONE commons=1 ...` then `ECOCHK_OK`. If `ECOA_FAIL ... a runtime select`: the core drives QPLL0REFCLKSEL from logic. Read `AURORA_GTG_SOURCES` from Step 3: if the core's shared-logic GT common wrapper is unencrypted RTL with a QPLL0REFCLKSEL port or parameter, record the file and line, and set `JC_LINK_REFCLK=pin` as the only supported value until a follow-up plan (do not patch generated IP sources). Record the outcome in `hw/jc/link/README.md`.

- [ ] **Step 6: Write the xsim link bench and its runner**

`hw/jc/link/sim/tb_jc_aurora_link.vhd`:

```vhdl
-- hw/jc/link/sim/tb_jc_aurora_link.vhd -- xsim, UNISIM + the Aurora IP (not a GHDL row: it
-- lives outside sim/). Two TX/RX-simplex cores, die A's TX lanes wired to die B's RX lanes
-- through the lane map PERM; jc_link_tx on A's user clock, jc_link_rx on B's (plan 2026-11-04
-- Task 5). Oracle: the payload B receives equals what A filled, frame by frame, with zero
-- CRC failures; then B's core alone is reset while A keeps transmitting and B must come back
-- up and receive again (the simplex RX-after-TX question, spec 1b.2 / plan "Not grounded").
-- PERM = 1 rotates the lane wiring: the mutant that must fail at NLANES 4.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_link_pkg.all;

entity tb_jc_aurora_link is
  generic(NLANES : positive := 1; PERM : natural := 0; N_EMBD : positive := 64;
          NFRAMES : positive := 6; UP_TMO_US : positive := 2000);
end entity;

architecture sim of tb_jc_aurora_link is
  constant W  : positive := 2 * NLANES;
  constant PW : natural := N_EMBD / 2;
  signal refclk, sysclk : std_logic := '0';
  signal pma_a, pma_b, rpb_a, rpb_b : std_logic := '1';
  signal a_txp, a_txn, b_txp, b_txn, a_rxp, a_rxn, b_rxp, b_rxn : std_logic_vector(NLANES-1 downto 0);
  signal ua, ub, a_txu, a_rxu, b_txu, b_rxu, a_lk, b_lk : std_logic;
  signal a_tdata, b_rdata, b_tdata_unused : std_logic_vector(64*NLANES-1 downto 0);
  signal a_tkeep : std_logic_vector(8*NLANES-1 downto 0);
  signal a_tlast, a_tvalid, a_tready, b_rlast, b_rvalid : std_logic;
  signal run_a, run_b, fill_we, send, do_resend : std_logic := '0';
  signal fill_idx, rd_idx : unsigned(11 downto 0) := (others => '0');
  signal fill_data, rd_data, hexp : std_logic_vector(31 downto 0) := (others => '0');
  signal send_pos, hpos : unsigned(31 downto 0) := (others => '0');
  signal busy, exh, hval, rbad, rdown, pop : std_logic := '0';
  signal fs, rs, fg, cf, sp, ld, ov, cn : unsigned(31 downto 0);
  type words_t is array (0 to PW-1) of std_logic_vector(31 downto 0);
  function lane_of(i : natural) return natural is
  begin
    if PERM = 0 then return i; else return (i + 1) mod NLANES; end if;
  end function;
begin
  refclk <= not refclk after 3.2 ns;        -- 156.25 MHz
  sysclk <= not sysclk after 2.5 ns;        -- 200 MHz init_clk

  g_wire : for i in 0 to NLANES - 1 generate
    b_rxp(lane_of(i)) <= a_txp(i);  b_rxn(lane_of(i)) <= a_txn(i);
  end generate;
  a_rxp <= (others => '0');  a_rxn <= (others => '1');   -- the reverse pair is not fitted

  u_a : entity work.jc_aurora_wrap
    port map(init_clk => sysclk, reset_pb => rpb_a, pma_init => pma_a,
             refclk_p => refclk, refclk_n => not refclk, tx_polarity => (others => '0'),
             s_tx_tdata => a_tdata, s_tx_tkeep => a_tkeep, s_tx_tlast => a_tlast,
             s_tx_tvalid => a_tvalid, s_tx_tready => a_tready,
             m_rx_tdata => open, m_rx_tkeep => open, m_rx_tlast => open, m_rx_tvalid => open,
             txp => a_txp, txn => a_txn, rxp => a_rxp, rxn => a_rxn,
             tx_channel_up => a_txu, rx_channel_up => a_rxu, user_clk => ua,
             tx_sys_reset => open, rx_sys_reset => open, gt_pll_lock => a_lk);
  u_b : entity work.jc_aurora_wrap
    port map(init_clk => sysclk, reset_pb => rpb_b, pma_init => pma_b,
             refclk_p => refclk, refclk_n => not refclk, tx_polarity => (others => '0'),
             s_tx_tdata => (others => '0'), s_tx_tkeep => (others => '1'), s_tx_tlast => '0',
             s_tx_tvalid => '0', s_tx_tready => open,
             m_rx_tdata => b_rdata, m_rx_tkeep => open, m_rx_tlast => b_rlast, m_rx_tvalid => b_rvalid,
             txp => b_txp, txn => b_txn, rxp => b_rxp, rxn => b_rxn,
             tx_channel_up => b_txu, rx_channel_up => b_rxu, user_clk => ub,
             tx_sys_reset => open, rx_sys_reset => open, gt_pll_lock => b_lk);

  u_tx : entity work.jc_link_tx
    generic map(N_EMBD => N_EMBD, W => W)
    port map(clk => ua, rst => '0', run_start => run_a, fill_we => fill_we, fill_idx => fill_idx,
             fill_data => fill_data, send => send, send_pos => send_pos, send_exp => x"FFFFFFF8",
             resend => do_resend, resend_cap => to_unsigned(3, 32), busy => busy, exhausted => exh,
             frames_sent => fs, resends => rs, m_tdata => a_tdata, m_tkeep => a_tkeep,
             m_tlast => a_tlast, m_tvalid => a_tvalid, m_tready => a_tready);
  u_rx : entity work.jc_link_rx
    generic map(N_EMBD => N_EMBD, W => W, DEPTH => 2)
    port map(clk => ub, rst => '0', run_start => run_b, chan_up => b_rxu,
             s_tdata => b_rdata, s_tlast => b_rlast, s_tvalid => b_rvalid,
             head_valid => hval, head_pos => hpos, head_exp => hexp, rd_idx => rd_idx,
             rd_data => rd_data, pop => pop, bad => rbad, down => rdown,
             frames_good => fg, crc_fails => cf, seqpos_bad => sp, link_downs => ld,
             overruns => ov, consumed => cn);

  main : process
    variable e, c : natural := 0;
    variable sent : words_t;
    variable lfsr : std_logic_vector(31 downto 0) := x"C0FFEE11";
    variable t0 : time;
    variable bad_w : natural;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_jc_aurora_link: " & msg severity error; end if;
    end procedure;
    procedure wait_up(signal s : std_logic; msg : string) is
    begin
      t0 := now;
      while s /= '1' and now - t0 < UP_TMO_US * 1 us loop wait for 100 ns; end loop;
      chk(s = '1', msg);
    end procedure;
    procedure one_frame(p : natural; msg : string) is
    begin
      wait until rising_edge(ua);
      for k in 0 to PW - 1 loop
        lfsr := lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
        sent(k) := lfsr;
        fill_we <= '1'; fill_idx <= to_unsigned(k, 12); fill_data <= lfsr;
        wait until rising_edge(ua);
      end loop;
      fill_we <= '0'; send_pos <= to_unsigned(p, 32); send <= '1';
      wait until rising_edge(ua); send <= '0';
      t0 := now;
      while hval /= '1' and now - t0 < 50 us loop wait until rising_edge(ub); end loop;
      chk(hval = '1', msg & ": frame arrived");
      if hval = '1' then
        chk(hpos = p, msg & ": position");
        bad_w := 0;
        for k in 0 to PW - 1 loop
          rd_idx <= to_unsigned(k, 12);
          wait until rising_edge(ub); wait until rising_edge(ub);
          if rd_data /= sent(k) then bad_w := bad_w + 1; end if;
        end loop;
        chk(bad_w = 0, msg & ": payload equal");
        pop <= '1'; wait until rising_edge(ub); pop <= '0'; wait until rising_edge(ub);
      end if;
    end procedure;
    -- finding 5: jc_link_rx resyncs on the first tlast after a chan_up fall (rtl/jc_link_rx.vhd
    -- header): the first frame sent after a reset is swallowed even though A never cut it. The
    -- held frame's RESEND is what actually lands; retry once with resend if the plain send times out.
    procedure frame_after_reset(p : natural; msg : string) is
      variable bad_w : natural := 0;
    begin
      wait until rising_edge(ua);
      for k in 0 to PW - 1 loop
        lfsr := lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
        sent(k) := lfsr;
        fill_we <= '1'; fill_idx <= to_unsigned(k, 12); fill_data <= lfsr;
        wait until rising_edge(ua);
      end loop;
      fill_we <= '0'; send_pos <= to_unsigned(p, 32); send <= '1';
      wait until rising_edge(ua); send <= '0';
      t0 := now;
      while hval /= '1' and now - t0 < 50 us loop wait until rising_edge(ub); end loop;
      if hval = '0' then
        wait until rising_edge(ua); do_resend <= '1'; wait until rising_edge(ua); do_resend <= '0';
        t0 := now;
        while hval /= '1' and now - t0 < 50 us loop wait until rising_edge(ub); end loop;
      end if;
      chk(hval = '1', msg & ": frame arrived (resent once if the first send was eaten by the reset resync)");
      if hval = '1' then
        chk(hpos = p, msg & ": position");
        for k in 0 to PW - 1 loop
          rd_idx <= to_unsigned(k, 12);
          wait until rising_edge(ub); wait until rising_edge(ub);
          if rd_data /= sent(k) then bad_w := bad_w + 1; end if;
        end loop;
        chk(bad_w = 0, msg & ": payload equal");
        pop <= '1'; wait until rising_edge(ub); pop <= '0'; wait until rising_edge(ub);
      end if;
    end procedure;
  begin
    -- PG074 reset order: pma_init and reset_pb high, pma_init low, then reset_pb low
    wait for 2 us; pma_a <= '0'; pma_b <= '0';
    wait for 2 us; rpb_a <= '0'; rpb_b <= '0';
    wait_up(a_txu, "A tx_channel_up");
    wait_up(b_rxu, "B rx_channel_up");
    wait until rising_edge(ua); run_a <= '1'; wait until rising_edge(ua); run_a <= '0';
    wait until rising_edge(ub); run_b <= '1'; wait until rising_edge(ub); run_b <= '0';
    for f in 0 to NFRAMES - 1 loop
      one_frame(f, "frame " & integer'image(f));
      exit when e > 0;
    end loop;
    chk(cf = 0 and sp = 0 and ov = 0, "no CRC, seq/pos or overrun faults");
    -- B's core alone is reset while A's TX stays up
    rpb_b <= '1'; wait for 2 us; rpb_b <= '0';
    wait_up(b_rxu, "B rx_channel_up again with A already up");
    chk(ld >= 1, "the B reset was counted as a link-down");
    frame_after_reset(NFRAMES, "frame after B reset");
    chk(a_txu = '1', "A tx_channel_up stayed up");
    if e = 0 then
      report "AURSIM_PASS tb_jc_aurora_link NLANES=" & integer'image(NLANES) &
             " PERM=" & integer'image(PERM) & " checks=" & integer'image(c) severity note;
    else
      report "AURSIM_FAIL tb_jc_aurora_link NLANES=" & integer'image(NLANES) &
             " PERM=" & integer'image(PERM) & " errors=" & integer'image(e) severity note;
    end if;
    std.env.finish;
  end process;
end architecture;
```

`hw/jc/link/run_aurora_sim.sh`:

```bash
#!/bin/bash
# hw/jc/link/run_aurora_sim.sh -- xsim of tb_jc_aurora_link through a Vivado project
# (plan 2026-11-04 Task 5 Step 7). No hardware. One Vivado per box: the caller checks presence.
# usage: run_aurora_sim.sh <ip_out_dir (l1|l4, sim mode)> <nlanes> <perm> <work_dir>
# prints ^AURSIM_PASS or ^AURSIM_FAIL (the bench's own line, or the harness's when it never ran)
set -u
IPOUT=$1; NL=$2; PERM=$3; WORK=$4
R=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)   # finding 6: this worktree
mkdir -p "$WORK"
cat > "$WORK/sim.tcl" <<TCL
create_project -force s $WORK/prj -part xcvu35p-fsvh2104-2L-e
add_files [glob $IPOUT/prj/aur.srcs/sources_1/ip/jc_aurora/jc_aurora.xci]
add_files -fileset sim_1 [list $R/rtl/jc_loader_pkg.vhd $R/rtl/jc_link_pkg.vhd $R/rtl/jc_link_tx.vhd \
  $R/rtl/jc_link_rx.vhd $R/hw/jc/link/rtl/jc_aurora_wrap_l$NL.vhd $R/hw/jc/link/sim/tb_jc_aurora_link.vhd]
set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sim_1] *.vhd]
set_property top tb_jc_aurora_link [get_filesets sim_1]
set_property generic "NLANES=$NL PERM=$PERM" [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
close_sim
TCL
vivado -mode batch -nojournal -log "$WORK/vivado.log" -source "$WORK/sim.tcl" > "$WORK/vivado.out" 2>&1
L=$(find "$WORK/prj" -name simulate.log | head -1)
if [ -n "$L" ] && grep -qE '^(Note: )?AURSIM_(PASS|FAIL)' "$L"; then
  grep -E '^(Note: )?AURSIM_(PASS|FAIL)' "$L" | sed 's/^Note: //'
else
  echo "AURSIM_FAIL harness: no bench verdict (see $WORK/vivado.log)"
fi
```

- [ ] **Step 7: Run the link simulations and the lane-map mutant**

Budget: one Vivado on the box (xsim of 2 to 8 GT channel models, ESTIMATE under 6 GB; capped). Run sequentially, never two at once.

```bash
B=/mnt/storage/fk33_builds/jc_link_ip
R=$(git rev-parse --show-toplevel)   # finding 6: this worktree, never a hardcoded checkout
cat > $B/run_sims.sh <<'SH'
#!/bin/bash
S="$R/hw/jc/link/run_aurora_sim.sh"
B=/mnt/storage/fk33_builds/jc_link_ip
bash "$S" $B/l1 1 0 $B/sim_l1   > $B/sim_l1.out
bash "$S" $B/l4 4 0 $B/sim_l4   > $B/sim_l4.out
bash "$S" $B/l4 4 1 $B/sim_l4p  > $B/sim_l4p.out
echo RUN_SIMS_DONE
SH
chmod +x $B/run_sims.sh
systemd-run --user --scope --setenv=R="$R" -p MemoryHigh=8G -p MemoryMax=10G $B/run_sims.sh
cat $B/sim_l1.out $B/sim_l4.out $B/sim_l4p.out
```

Expected:
```
AURSIM_PASS tb_jc_aurora_link NLANES=1 PERM=0 checks=...
AURSIM_PASS tb_jc_aurora_link NLANES=4 PERM=0 checks=...
AURSIM_FAIL tb_jc_aurora_link NLANES=4 PERM=1 errors=...
```
The third line is the spec section 4 mutant ("lane map permuted against the generic"); a `harness:` FAIL there does not count as killed (rerun until the bench itself reports). If `PERM=1` PASSES, the bench cannot see lane order: stop and report it as a surviving mutant. If NLANES 1 fails on "B rx_channel_up again with A already up" only, record it MEASURED in `README.md` as the answer to the simplex RX-after-TX question; Task 6's link bring-up then resets both dies' cores together (LINK_CTRL bit 0 on A and B) and Task 8 step 1 uses that order. Any other NLANES 1 failure is a stop condition.

- [ ] **Step 8: Write the README and commit**

`hw/jc/link/README.md` holds, in this order: what the directory is (two lines); the commands of Steps 3, 5 and 7; the MEASURED records (refclk choices and pick, `AURORA_CFG` lines of `l1card`, `AURORA_LOCS`, `AURORA_GTG_SOURCES`, the ECO check lines, the three AURSIM lines with their log paths); the answer to the RX-after-TX question; and the stub path each committed wrapper was generated from.

```bash
git add hw/jc/link/aurora_ties.py hw/jc/link/gen_aurora_wrap.py hw/jc/link/test_gen_aurora_wrap.py \
  hw/jc/link/aurora_cfg.tcl hw/jc/link/gen_aurora_ip.tcl hw/jc/link/rtl/jc_gtg_clk.vhd \
  hw/jc/link/eco_aurora_gtg.tcl hw/jc/link/eco_check.tcl hw/jc/link/sim/tb_jc_aurora_link.vhd \
  hw/jc/link/run_aurora_sim.sh hw/jc/link/README.md \
  hw/jc/link/rtl/jc_aurora_wrap_l1.vhd hw/jc/link/rtl/jc_aurora_wrap_l4.vhd
git commit -m "jc loop T5: Aurora 64B66B TX/RX simplex config, GTG refclk MMCM and ECO, xsim link test" -- \
  hw/jc/link/aurora_ties.py hw/jc/link/gen_aurora_wrap.py hw/jc/link/test_gen_aurora_wrap.py \
  hw/jc/link/aurora_cfg.tcl hw/jc/link/gen_aurora_ip.tcl hw/jc/link/rtl/jc_gtg_clk.vhd \
  hw/jc/link/eco_aurora_gtg.tcl hw/jc/link/eco_check.tcl hw/jc/link/sim/tb_jc_aurora_link.vhd \
  hw/jc/link/run_aurora_sim.sh hw/jc/link/README.md \
  hw/jc/link/rtl/jc_aurora_wrap_l1.vhd hw/jc/link/rtl/jc_aurora_wrap_l4.vhd
```

---
### Task 6: tok_loop composition, row sources, link integration, card top, benches

**Files:**
- Create: `rtl/tok_loop.vhd`, `rtl/jc_tok_top.vhd`, `sim/tb_tok_loop_top.vhd`, `sim/tb_tok_loop_pair.vhd`, `sim/tb_tok_loop_faults.vhd`, `sim/mutants/tok_loop_top.json`, `sim/mutants/tok_loop_pair.json`, `sim/mutants/tok_loop_faults.json`
- Modify: `tools/jc/gen_tok_loop_vec.py` (cases `pa` and `e`), `sim/tok_loop_vec.txt` (regenerated), `sim/tok_loop_tb_pkg.vhd` (`gather` field), `sim/tb_tok_loop.vhd` (skip gather cases)

**Interfaces:**
- Consumes: Task 1 `jc_seam_mux` (`owner` out, `loop_own` in), Task 2 `tok_loop_regs`/`tok_loop_fsm` and records (row-source protocol: `rs_req` pulse with `rs_tok`; the source raises `rs_exp_valid` with `rs_exp`, then offers `rs_m_valid`/`rs_m_data` one mantissa at a time, each consumed by a one-cycle `rs_m_ready`; `rs_exp_valid` drops after the last; `rs_paused` stops the link timeout), Task 3 `embed_gather`, Task 4 `jc_link_tx`/`jc_link_rx`, `rtl/async_fifo.vhd` (entity at `rtl/async_fifo.vhd`, `FAST_POP => true` sustains one beat per rclk: needed because Aurora RX has no backpressure), the seam's `s_axi` (12-bit address, no PROT, `rtl/fk33_seam.vhd:233,243`), `jc_ctl_core`'s port naming for a read-only AXI4 HBM master (`rtl/jc_ctl_core.vhd`, `m_axi_ar*`/`m_axi_r*`, 33-bit address, 256-bit data).
- Produces:
  - `tok_loop` (generics `N_EMBD, PROMPT_MAX, OUT_DEPTH, HAS_GATHER, HAS_LINK, NLANES, RXDEPTH, SEAM_TMO`): single clock. `s_ctl_*` (16-bit AXI-Lite slave), `s_host_*` (12-bit, the host's seam path), `m_seam_*` (12-bit, to `fk33_seam`), `host_refused`, `m_hbm_*` (read-only AXI4), link AXIS in the core clock (`ltx_*` master, `lrx_*` slave without ready), `lnk_tx_up, lnk_rx_up, lnk_gtg_lock, lnk_pll_lock, lnk_rx_ovf` (already synchronised), `link_ctrl` out.
  - `jc_tok_top` (generics `N_EMBD, NLANES, HAS_GATHER, TXPOL_MASK`): the BD module reference. `aclk, arst` (active high), `s_host_*`, `m_seam_*`, `s_ctl_*`, `m_hbm_*`, `user_clk`, `m_axis_tx_*` and `s_axis_rx_*` (Aurora user clock), `tx_channel_up, rx_channel_up, gt_pll_lock, gtg_locked` (asynchronous inputs), `init_clk`, `aur_reset_pb, aur_pma_init` (init_clk domain), `aur_tx_polarity(NLANES-1:0)` (user clock domain).
  - Vector file: column 6 of a `C` line is 0 single, 1 pair, 2 single die with gather rows.

**Bench plan (the Review Focus cases are F11 to F15):**

| Bench | Configuration | Cases |
|---|---|---|
| `tb_tok_loop_top` | `tok_loop`, N_EMBD 4096, HAS_GATHER, no link | every single-die vector case through the HOST row source (bench writes `pl_embed_synthetic` rows); case `e` through GATHER from the Task 3 image; trace and ids against the vectors; host seam access while idle is OKAY |
| `tb_tok_loop_pair` | two `jc_tok_top`, N_EMBD 4096, NLANES 1, channel model on a 6.2 ns user clock | P1 case `pa`: both dies' traces and B's ids against the vectors, zero CRC fails, overruns and resends; P2 payload flip in frame 2 with the RESEND delayed past TMO_LINK: B pauses, no LINK_TIMEOUT, same ids; P3 link down mid-frame 4: LINK_DOWN, RESEND, same ids; P4 RESEND_CAP 2 with every resend corrupted: A stops LINK_RETRY_EXHAUSTED, RESENDS = 2 |
| `tb_tok_loop_faults` | `tok_loop`, N_EMBD 64, HAS_LINK, host rows, OUT_DEPTH 4 | F0 reference run; F1 ENGINE_ERR; F2 ENGINE_TIMEOUT; F3 SEAM_ERR with ERR_ADDR; F4 ABORT on NEED_ROW; F5 ABORT on OUT_FULL; F6 host seam access mid-run refused, ids unchanged; F7 SEQ_RESET_FAIL; F8 BAD_CONFIG (two forms); F9 LINK_TIMEOUT; F10 MAXPOS; F11 OUT never drained; F12 config written mid-run; F13 START while running; F14 second run identical; F15 STOP_ID[7]; F16 role A waits for LINK_CREDIT |

- [ ] **Step 1: Extend the vectors**

In `tools/jc/gen_tok_loop_vec.py`, replace the `CASES` list with:

```python
# (name, prompt, max_new, stop, pair, mv4i): stop None = "the first id of case a, at
# index >= 1, that has not occurred before it" (a stop that ends the run early).
# mv4i "SYN4096" = the Task 3 synthetic image (tools/jc/gen_embed_gather_vec.py --k 4096),
# prompt ids below its M = 96 and max_new 1, so no generated id is ever gathered.
CASES = [
    ("a", [1, 2, 3], 5, -1, False, None),
    ("b", [1, 2, 3], 5, None, False, None),
    ("c", [7], 1, -1, False, None),
    ("d", [5, 6, 7, 8, 9, 10, 11, 12], 3, -1, False, None),
    ("pa", [1, 2, 3], 5, -1, True, None),
    ("e", [0, 47, 95, 50, 51, 61], 1, -1, False, "SYN4096"),
]
GATHER_VEC = os.path.join(REPO, "sim", "embed_gather_k4096_vec.txt")


def syn_mv4i(base):
    """Rebuild the Task 3 image; refuse unless its vectors equal the committed ones, which is
    what makes tb_tok_loop_top's poked image the image these ids were computed from."""
    d = tempfile.mkdtemp(prefix="tlv_mv4i_", dir=base)
    img, vec = os.path.join(d, "syn.mv4i"), os.path.join(d, "eg.txt")
    r = subprocess.run([sys.executable, os.path.join(HERE, "gen_embed_gather_vec.py"), "--k", "4096",
                        "--out", vec, "--mv4i", img], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("GEN_TOKLOOP_FAIL gather image\n" + r.stdout + r.stderr)
    if open(vec).read() != open(GATHER_VEC).read():
        sys.exit("GEN_TOKLOOP_FAIL the synthetic image differs from %s: regenerate Task 3 first" % GATHER_VEC)
    return img
```

In `generate()`, after `ids_a = None` add `syn = None`, and replace the loop head and the `C` line:

```python
    for name, prompt, max_new, stop, pair, mv4i in CASES:
        if mv4i == "SYN4096":
            syn = syn or syn_mv4i(base)
            mv4i = syn
```

```python
        kind = 1 if pair else (2 if mv4i else 0)
        out.append("C %d %d %d %d %d" % (len(prompt), max_new, stop, len(ids), kind))
```

Update the header comment line to `# C plen max_new stop n_ids kind(0 single 1 pair 2 gather) / P prompt / I ids / W die off val / D die n fnv / E`.

In `sim/tok_loop_tb_pkg.vhd`: add `gather : boolean;` to `case_t` after `pair : boolean;`, and replace `read(l, n); v.cs(cur).pair := (n = 1);` with:

```vhdl
            read(l, n); v.cs(cur).pair := (n = 1); v.cs(cur).gather := (n = 2);
```

In `sim/tb_tok_loop.vhd` replace `next when V.cs(k).pair;` with `next when V.cs(k).pair or V.cs(k).gather;`.

Run: `python3 tools/jc/gen_tok_loop_vec.py && python3 tools/jc/gen_tok_loop_vec.py --check`
Expected: six `GEN_TOKLOOP case` lines (`pa` with two op counts), then `GEN_TOKLOOP_CHECK OK`.
Run: `REGRESS_SCRATCH=~/regress_scratch/t6-a bash sim/regress.sh --only tb_tok_loop --keep`
Expected: `OVERALL PASS 1` (only `tb_tok_loop` exists yet; the gather case is skipped there).

- [ ] **Step 2: Write `rtl/tok_loop.vhd`**

```vhdl
-- rtl/tok_loop.vhd -- the on-fabric token loop of one die (spec 2026-11-04 sections 1, 1b, 3;
-- plan Task 6): control slave + seam-master FSM + seam ownership mux + the three row
-- sources (HBM gather, host row buffer, die-to-die link) + the link framer and deframer.
-- Single clock: the Aurora clock crossing is jc_tok_top's.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.tok_loop_pkg.all;

entity tok_loop is
  generic(N_EMBD : positive := 5120; PROMPT_MAX : positive := 4096; OUT_DEPTH : positive := 1024;
          HAS_GATHER : boolean := true; HAS_LINK : boolean := true; NLANES : positive := 1;
          RXDEPTH : positive := 2; SEAM_TMO : positive := 65536);
  port(
    clk, rst       : in  std_logic;
    s_ctl_awaddr   : in  std_logic_vector(15 downto 0);
    s_ctl_awvalid  : in  std_logic;
    s_ctl_awready  : out std_logic;
    s_ctl_wdata    : in  std_logic_vector(31 downto 0);
    s_ctl_wstrb    : in  std_logic_vector(3 downto 0);
    s_ctl_wvalid   : in  std_logic;
    s_ctl_wready   : out std_logic;
    s_ctl_bresp    : out std_logic_vector(1 downto 0);
    s_ctl_bvalid   : out std_logic;
    s_ctl_bready   : in  std_logic;
    s_ctl_araddr   : in  std_logic_vector(15 downto 0);
    s_ctl_arvalid  : in  std_logic;
    s_ctl_arready  : out std_logic;
    s_ctl_rdata    : out std_logic_vector(31 downto 0);
    s_ctl_rresp    : out std_logic_vector(1 downto 0);
    s_ctl_rvalid   : out std_logic;
    s_ctl_rready   : in  std_logic;
    s_host_awaddr  : in  std_logic_vector(11 downto 0);
    s_host_awvalid : in  std_logic;
    s_host_awready : out std_logic;
    s_host_wdata   : in  std_logic_vector(31 downto 0);
    s_host_wstrb   : in  std_logic_vector(3 downto 0);
    s_host_wvalid  : in  std_logic;
    s_host_wready  : out std_logic;
    s_host_bresp   : out std_logic_vector(1 downto 0);
    s_host_bvalid  : out std_logic;
    s_host_bready  : in  std_logic;
    s_host_araddr  : in  std_logic_vector(11 downto 0);
    s_host_arvalid : in  std_logic;
    s_host_arready : out std_logic;
    s_host_rdata   : out std_logic_vector(31 downto 0);
    s_host_rresp   : out std_logic_vector(1 downto 0);
    s_host_rvalid  : out std_logic;
    s_host_rready  : in  std_logic;
    m_seam_awaddr  : out std_logic_vector(11 downto 0);
    m_seam_awvalid : out std_logic;
    m_seam_awready : in  std_logic;
    m_seam_wdata   : out std_logic_vector(31 downto 0);
    m_seam_wstrb   : out std_logic_vector(3 downto 0);
    m_seam_wvalid  : out std_logic;
    m_seam_wready  : in  std_logic;
    m_seam_bresp   : in  std_logic_vector(1 downto 0);
    m_seam_bvalid  : in  std_logic;
    m_seam_bready  : out std_logic;
    m_seam_araddr  : out std_logic_vector(11 downto 0);
    m_seam_arvalid : out std_logic;
    m_seam_arready : in  std_logic;
    m_seam_rdata   : in  std_logic_vector(31 downto 0);
    m_seam_rresp   : in  std_logic_vector(1 downto 0);
    m_seam_rvalid  : in  std_logic;
    m_seam_rready  : out std_logic;
    host_refused   : out std_logic;
    m_hbm_araddr   : out std_logic_vector(32 downto 0);
    m_hbm_arlen    : out std_logic_vector(7 downto 0);
    m_hbm_arsize   : out std_logic_vector(2 downto 0);
    m_hbm_arburst  : out std_logic_vector(1 downto 0);
    m_hbm_arvalid  : out std_logic;
    m_hbm_arready  : in  std_logic;
    m_hbm_rdata    : in  std_logic_vector(255 downto 0);
    m_hbm_rresp    : in  std_logic_vector(1 downto 0);
    m_hbm_rlast    : in  std_logic;
    m_hbm_rvalid   : in  std_logic;
    m_hbm_rready   : out std_logic;
    ltx_tdata      : out std_logic_vector(64*NLANES-1 downto 0);
    ltx_tkeep      : out std_logic_vector(8*NLANES-1 downto 0);
    ltx_tlast      : out std_logic;
    ltx_tvalid     : out std_logic;
    ltx_tready     : in  std_logic;
    lrx_tdata      : in  std_logic_vector(64*NLANES-1 downto 0);
    lrx_tlast      : in  std_logic;
    lrx_tvalid     : in  std_logic;
    lnk_tx_up, lnk_rx_up, lnk_gtg_lock, lnk_pll_lock, lnk_rx_ovf : in std_logic;
    link_ctrl      : out std_logic_vector(31 downto 0));
end entity;

architecture rtl of tok_loop is
  constant W : positive := 2 * NLANES;
  function b2s(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;
  constant CAPS : std_logic_vector(31 downto 0) :=
    std_logic_vector(to_unsigned(RXDEPTH, 8)) & std_logic_vector(to_unsigned(NLANES, 4)) &
    "00" & b2s(HAS_LINK) & b2s(HAS_GATHER) & std_logic_vector(to_unsigned(N_EMBD, 16));
  signal cfg : tl_cfg_t;
  signal st : tl_stat_t;
  signal lnk : tl_lnk_t := TL_LNK_ZERO;
  signal run_start, loop_own, owner : std_logic;
  signal pr_addr : unsigned(11 downto 0);
  signal pr_data : unsigned(31 downto 0);
  signal out_we : std_logic;
  signal out_waddr : unsigned(15 downto 0);
  signal out_wdata : std_logic_vector(31 downto 0);
  signal hr_addr : unsigned(12 downto 0) := (others => '0');
  signal hr_data : std_logic_vector(15 downto 0);
  -- the FSM's seam master
  signal l_awaddr, l_araddr : std_logic_vector(11 downto 0);
  signal l_awvalid, l_awready, l_wvalid, l_wready, l_bvalid, l_bready : std_logic;
  signal l_arvalid, l_arready, l_rvalid, l_rready : std_logic;
  signal l_wdata, l_rdata : std_logic_vector(31 downto 0);
  signal l_wstrb : std_logic_vector(3 downto 0);
  signal l_bresp, l_rresp : std_logic_vector(1 downto 0);
  -- the row-source bus as the FSM sees it, and each source's copy
  signal rs_req, rs_ev, rs_err, rs_mv, rs_mr, rs_paused : std_logic;
  signal rs_tok : unsigned(31 downto 0);
  signal rs_exp : std_logic_vector(31 downto 0);
  signal rs_md : std_logic_vector(15 downto 0);
  signal g_ev, g_err, g_mv : std_logic := '0';
  signal g_exp : std_logic_vector(31 downto 0) := (others => '0');
  signal g_md : std_logic_vector(15 downto 0) := (others => '0');
  signal h_ev, h_mv : std_logic := '0';
  signal h_exp : std_logic_vector(31 downto 0) := (others => '0');
  signal h_md : std_logic_vector(15 downto 0) := (others => '0');
  signal k_ev, k_mv : std_logic := '0';
  signal k_exp : std_logic_vector(31 downto 0) := (others => '0');
  signal k_md : std_logic_vector(15 downto 0) := (others => '0');
  type hs_t is (H_IDLE, H_ARM, H_RD1, H_RD2, H_PRES);
  type ks_t is (K_IDLE, K_WAIT, K_RD1, K_RD2, K_PRES);
  signal hs : hs_t := H_IDLE;
  signal ks : ks_t := K_IDLE;
  signal h_idx, k_idx : natural range 0 to N_EMBD - 1 := 0;
  -- link
  signal tx_wr, tx_send, tx_busy, tx_exh : std_logic := '0';
  signal tx_widx : unsigned(11 downto 0);
  signal tx_wdata, tx_exp : std_logic_vector(31 downto 0);
  signal tx_pos : unsigned(31 downto 0);
  signal rx_hval, rx_bad, rx_down, rx_pop : std_logic := '0';
  signal rx_hpos : unsigned(31 downto 0);
  signal rx_hexp, rx_rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal rx_idx : unsigned(11 downto 0) := (others => '0');
  signal f_sent, f_res, f_good, f_crc, f_sp, f_ld, f_ov, f_cons : unsigned(31 downto 0) := (others => '0');
begin
  regs : entity work.tok_loop_regs
    generic map(N_EMBD => N_EMBD, PROMPT_MAX => PROMPT_MAX, OUT_DEPTH => OUT_DEPTH, CAPS => CAPS)
    port map(clk => clk, rst => rst,
             s_awaddr => s_ctl_awaddr, s_awvalid => s_ctl_awvalid, s_awready => s_ctl_awready,
             s_wdata => s_ctl_wdata, s_wstrb => s_ctl_wstrb, s_wvalid => s_ctl_wvalid,
             s_wready => s_ctl_wready, s_bresp => s_ctl_bresp, s_bvalid => s_ctl_bvalid,
             s_bready => s_ctl_bready, s_araddr => s_ctl_araddr, s_arvalid => s_ctl_arvalid,
             s_arready => s_ctl_arready, s_rdata => s_ctl_rdata, s_rresp => s_ctl_rresp,
             s_rvalid => s_ctl_rvalid, s_rready => s_ctl_rready,
             cfg => cfg, st => st, lnk => lnk, pr_addr => pr_addr, pr_data => pr_data,
             out_we => out_we, out_waddr => out_waddr, out_wdata => out_wdata,
             hr_addr => hr_addr, hr_data => hr_data);

  fsm : entity work.tok_loop_fsm
    generic map(N_EMBD => N_EMBD, PROMPT_MAX => PROMPT_MAX, OUT_DEPTH => OUT_DEPTH,
                HAS_GATHER => HAS_GATHER, HAS_LINK => HAS_LINK, SEAM_TMO => SEAM_TMO)
    port map(clk => clk, rst => rst, cfg => cfg, st => st, run_start => run_start,
             pr_addr => pr_addr, pr_data => pr_data,
             out_we => out_we, out_waddr => out_waddr, out_wdata => out_wdata,
             loop_own => loop_own, owner => owner,
             rs_req => rs_req, rs_tok => rs_tok, rs_exp_valid => rs_ev, rs_exp => rs_exp,
             rs_err => rs_err, rs_m_valid => rs_mv, rs_m_data => rs_md, rs_m_ready => rs_mr,
             rs_paused => rs_paused,
             tx_wr => tx_wr, tx_widx => tx_widx, tx_wdata => tx_wdata, tx_send => tx_send,
             tx_pos => tx_pos, tx_exp => tx_exp, tx_busy => tx_busy, tx_exhausted => tx_exh,
             m_awaddr => l_awaddr, m_awvalid => l_awvalid, m_awready => l_awready,
             m_wdata => l_wdata, m_wstrb => l_wstrb, m_wvalid => l_wvalid, m_wready => l_wready,
             m_bresp => l_bresp, m_bvalid => l_bvalid, m_bready => l_bready,
             m_araddr => l_araddr, m_arvalid => l_arvalid, m_arready => l_arready,
             m_rdata => l_rdata, m_rresp => l_rresp, m_rvalid => l_rvalid, m_rready => l_rready);

  mux : entity work.jc_seam_mux
    generic map(AW => 12)
    port map(clk => clk, rst => rst, loop_own => loop_own, owner => owner, host_refused => host_refused,
             s_h_awaddr => s_host_awaddr, s_h_awvalid => s_host_awvalid, s_h_awready => s_host_awready,
             s_h_wdata => s_host_wdata, s_h_wstrb => s_host_wstrb, s_h_wvalid => s_host_wvalid,
             s_h_wready => s_host_wready, s_h_bresp => s_host_bresp, s_h_bvalid => s_host_bvalid,
             s_h_bready => s_host_bready, s_h_araddr => s_host_araddr, s_h_arvalid => s_host_arvalid,
             s_h_arready => s_host_arready, s_h_rdata => s_host_rdata, s_h_rresp => s_host_rresp,
             s_h_rvalid => s_host_rvalid, s_h_rready => s_host_rready,
             s_l_awaddr => l_awaddr, s_l_awvalid => l_awvalid, s_l_awready => l_awready,
             s_l_wdata => l_wdata, s_l_wstrb => l_wstrb, s_l_wvalid => l_wvalid, s_l_wready => l_wready,
             s_l_bresp => l_bresp, s_l_bvalid => l_bvalid, s_l_bready => l_bready,
             s_l_araddr => l_araddr, s_l_arvalid => l_arvalid, s_l_arready => l_arready,
             s_l_rdata => l_rdata, s_l_rresp => l_rresp, s_l_rvalid => l_rvalid, s_l_rready => l_rready,
             m_awaddr => m_seam_awaddr, m_awvalid => m_seam_awvalid, m_awready => m_seam_awready,
             m_wdata => m_seam_wdata, m_wstrb => m_seam_wstrb, m_wvalid => m_seam_wvalid,
             m_wready => m_seam_wready, m_bresp => m_seam_bresp, m_bvalid => m_seam_bvalid,
             m_bready => m_seam_bready, m_araddr => m_seam_araddr, m_arvalid => m_seam_arvalid,
             m_arready => m_seam_arready, m_rdata => m_seam_rdata, m_rresp => m_seam_rresp,
             m_rvalid => m_seam_rvalid, m_rready => m_seam_rready);

  -- ---- the row-source mux: the FSM's latched ROW_SRC picks one source ----------------
  rs_ev <= g_ev when st.row_src = SRC_GATHER else h_ev when st.row_src = SRC_HOST else k_ev;
  rs_exp <= g_exp when st.row_src = SRC_GATHER else h_exp when st.row_src = SRC_HOST else k_exp;
  rs_mv <= g_mv when st.row_src = SRC_GATHER else h_mv when st.row_src = SRC_HOST else k_mv;
  rs_md <= g_md when st.row_src = SRC_GATHER else h_md when st.row_src = SRC_HOST else k_md;
  rs_err <= g_err when st.row_src = SRC_GATHER else '0';
  rs_paused <= (rx_bad or rx_down) when st.row_src = SRC_LINK else '0';

  -- ---- gather (spec 1.4) ---------------------------------------------------------------
  g_gather : if HAS_GATHER generate
    signal g_req : std_logic;
  begin
    g_req <= rs_req when st.row_src = SRC_GATHER else '0';
    gat : entity work.embed_gather
      generic map(N_EMBD => N_EMBD, ADDR_W => 33)
      port map(clk => clk, rst => rst, emb_base => cfg.emb_base, invalidate => run_start,
               req => g_req, tok => rs_tok, exp_valid => g_ev, exp_val => g_exp, err => g_err,
               err_code => open, m_valid => g_mv, m_data => g_md,
               m_ready => rs_mr and b2s(st.row_src = SRC_GATHER),
               m_axi_araddr => m_hbm_araddr, m_axi_arlen => m_hbm_arlen, m_axi_arsize => m_hbm_arsize,
               m_axi_arburst => m_hbm_arburst, m_axi_arvalid => m_hbm_arvalid,
               m_axi_arready => m_hbm_arready, m_axi_rdata => m_hbm_rdata, m_axi_rresp => m_hbm_rresp,
               m_axi_rlast => m_hbm_rlast, m_axi_rvalid => m_hbm_rvalid, m_axi_rready => m_hbm_rready);
  end generate;
  g_nogather : if not HAS_GATHER generate
    m_hbm_araddr <= (others => '0'); m_hbm_arlen <= (others => '0'); m_hbm_arsize <= "101";
    m_hbm_arburst <= "01"; m_hbm_arvalid <= '0'; m_hbm_rready <= '1';
  end generate;

  -- ---- host row buffer (NEED_ROW / ROW_READY, spec 1.3 "host" source) ---------------------
  host_src : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or run_start = '1' then
        hs <= H_IDLE; h_ev <= '0'; h_mv <= '0';
      else
        case hs is
          when H_IDLE =>
            if rs_req = '1' and st.row_src = SRC_HOST then hs <= H_ARM; end if;
          when H_ARM =>
            if cfg.row_ready = '1' then
              h_exp <= cfg.row_exp; h_ev <= '1'; h_idx <= 0; hr_addr <= (others => '0'); hs <= H_RD1;
            end if;
          when H_RD1 => hs <= H_RD2;
          when H_RD2 => h_md <= hr_data; h_mv <= '1'; hs <= H_PRES;
          when H_PRES =>
            if rs_mr = '1' then
              h_mv <= '0';
              if h_idx = N_EMBD - 1 then
                h_ev <= '0'; hs <= H_IDLE;
              else
                h_idx <= h_idx + 1; hr_addr <= to_unsigned(h_idx + 1, 13); hs <= H_RD1;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;

  -- ---- the link (spec 1b) ----------------------------------------------------------------
  g_link : if HAS_LINK generate
  begin
    tx : entity work.jc_link_tx
      generic map(N_EMBD => N_EMBD, W => W)
      port map(clk => clk, rst => rst, run_start => run_start, fill_we => tx_wr, fill_idx => tx_widx,
               fill_data => tx_wdata, send => tx_send, send_pos => tx_pos, send_exp => tx_exp,
               resend => cfg.resend, resend_cap => cfg.resend_cap, busy => tx_busy, exhausted => tx_exh,
               frames_sent => f_sent, resends => f_res, m_tdata => ltx_tdata, m_tkeep => ltx_tkeep,
               m_tlast => ltx_tlast, m_tvalid => ltx_tvalid, m_tready => ltx_tready);
    rx : entity work.jc_link_rx
      generic map(N_EMBD => N_EMBD, W => W, DEPTH => RXDEPTH)
      port map(clk => clk, rst => rst, run_start => run_start, chan_up => lnk_rx_up,
               s_tdata => lrx_tdata, s_tlast => lrx_tlast, s_tvalid => lrx_tvalid,
               head_valid => rx_hval, head_pos => rx_hpos, head_exp => rx_hexp,
               rd_idx => rx_idx, rd_data => rx_rdata, pop => rx_pop, bad => rx_bad, down => rx_down,
               frames_good => f_good, crc_fails => f_crc, seqpos_bad => f_sp, link_downs => f_ld,
               overruns => f_ov, consumed => f_cons);

    link_src : process(clk)
    begin
      if rising_edge(clk) then
        rx_pop <= '0';
        if rst = '1' or run_start = '1' then
          ks <= K_IDLE; k_ev <= '0'; k_mv <= '0';
        else
          case ks is
            when K_IDLE =>
              if rs_req = '1' and st.row_src = SRC_LINK then ks <= K_WAIT; end if;
            when K_WAIT =>
              if rx_hval = '1' then
                k_exp <= rx_hexp; k_ev <= '1'; k_idx <= 0; rx_idx <= (others => '0'); ks <= K_RD1;
              end if;
            when K_RD1 => ks <= K_RD2;
            when K_RD2 =>
              if (k_idx mod 2) = 0 then k_md <= rx_rdata(15 downto 0); else k_md <= rx_rdata(31 downto 16); end if;
              k_mv <= '1'; ks <= K_PRES;
            when K_PRES =>
              if rs_mr = '1' then
                k_mv <= '0';
                if k_idx = N_EMBD - 1 then
                  k_ev <= '0'; rx_pop <= '1'; ks <= K_IDLE;
                else
                  k_idx <= k_idx + 1; rx_idx <= to_unsigned((k_idx + 1) / 2, 12); ks <= K_RD1;
                end if;
              end if;
          end case;
        end if;
      end if;
    end process;
  end generate;
  g_nolink : if not HAS_LINK generate
    ltx_tdata <= (others => '0'); ltx_tkeep <= (others => '0'); ltx_tlast <= '0'; ltx_tvalid <= '0';
  end generate;

  lnk.frames_sent <= f_sent;  lnk.resends <= f_res;     lnk.frames_good <= f_good;
  lnk.crc_fails <= f_crc;     lnk.seqpos_bad <= f_sp;   lnk.link_downs <= f_ld;
  lnk.overruns <= f_ov;       lnk.consumed <= f_cons;
  lnk.status <= (LS_TX_UP => lnk_tx_up, LS_RX_UP => lnk_rx_up, LS_GTG_LOCK => lnk_gtg_lock,
                 LS_PLL_LOCK => lnk_pll_lock, LS_PAUSED => rs_paused, LS_BAD => rx_bad,
                 LS_DOWN => rx_down, LS_TX_EXH => tx_exh, LS_RX_OVF => lnk_rx_ovf, others => '0');
  link_ctrl <= cfg.link_ctrl;
end architecture;
```

- [ ] **Step 3: Write `rtl/jc_tok_top.vhd`**

```vhdl
-- rtl/jc_tok_top.vhd -- the card's module reference for the token loop (plan 2026-11-04
-- Tasks 6 and 7): tok_loop in the core clock (aclk = clk_core) plus the crossings to the
-- Aurora core's user clock and init clock. Port names follow jc_ctl_core's so the BD infers
-- s_host, m_seam, s_ctl (AXI-Lite), m_hbm (read-only AXI4) and the two AXIS interfaces.
-- TXPOL_MASK is the lane table's TX polarity (hw/jc/link/aurora_cfg.tcl), XORed with
-- LINK_CTRL bit 2 (plan D5). Same bitstream on both dies: nothing here is per-die.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jc_tok_top is
  generic(N_EMBD : positive := 5120; NLANES : positive := 1; HAS_GATHER : boolean := true;
          TXPOL_MASK : natural := 0);
  port(
    aclk, arst         : in  std_logic;
    s_host_awaddr      : in  std_logic_vector(11 downto 0);
    s_host_awvalid     : in  std_logic;
    s_host_awready     : out std_logic;
    s_host_wdata       : in  std_logic_vector(31 downto 0);
    s_host_wstrb       : in  std_logic_vector(3 downto 0);
    s_host_wvalid      : in  std_logic;
    s_host_wready      : out std_logic;
    s_host_bresp       : out std_logic_vector(1 downto 0);
    s_host_bvalid      : out std_logic;
    s_host_bready      : in  std_logic;
    s_host_araddr      : in  std_logic_vector(11 downto 0);
    s_host_arvalid     : in  std_logic;
    s_host_arready     : out std_logic;
    s_host_rdata       : out std_logic_vector(31 downto 0);
    s_host_rresp       : out std_logic_vector(1 downto 0);
    s_host_rvalid      : out std_logic;
    s_host_rready      : in  std_logic;
    m_seam_awaddr      : out std_logic_vector(11 downto 0);
    m_seam_awvalid     : out std_logic;
    m_seam_awready     : in  std_logic;
    m_seam_wdata       : out std_logic_vector(31 downto 0);
    m_seam_wstrb       : out std_logic_vector(3 downto 0);
    m_seam_wvalid      : out std_logic;
    m_seam_wready      : in  std_logic;
    m_seam_bresp       : in  std_logic_vector(1 downto 0);
    m_seam_bvalid      : in  std_logic;
    m_seam_bready      : out std_logic;
    m_seam_araddr      : out std_logic_vector(11 downto 0);
    m_seam_arvalid     : out std_logic;
    m_seam_arready     : in  std_logic;
    m_seam_rdata       : in  std_logic_vector(31 downto 0);
    m_seam_rresp       : in  std_logic_vector(1 downto 0);
    m_seam_rvalid      : in  std_logic;
    m_seam_rready      : out std_logic;
    s_ctl_awaddr       : in  std_logic_vector(15 downto 0);
    s_ctl_awvalid      : in  std_logic;
    s_ctl_awready      : out std_logic;
    s_ctl_wdata        : in  std_logic_vector(31 downto 0);
    s_ctl_wstrb        : in  std_logic_vector(3 downto 0);
    s_ctl_wvalid       : in  std_logic;
    s_ctl_wready       : out std_logic;
    s_ctl_bresp        : out std_logic_vector(1 downto 0);
    s_ctl_bvalid       : out std_logic;
    s_ctl_bready       : in  std_logic;
    s_ctl_araddr       : in  std_logic_vector(15 downto 0);
    s_ctl_arvalid      : in  std_logic;
    s_ctl_arready      : out std_logic;
    s_ctl_rdata        : out std_logic_vector(31 downto 0);
    s_ctl_rresp        : out std_logic_vector(1 downto 0);
    s_ctl_rvalid       : out std_logic;
    s_ctl_rready       : in  std_logic;
    m_hbm_araddr       : out std_logic_vector(32 downto 0);
    m_hbm_arlen        : out std_logic_vector(7 downto 0);
    m_hbm_arsize       : out std_logic_vector(2 downto 0);
    m_hbm_arburst      : out std_logic_vector(1 downto 0);
    m_hbm_arvalid      : out std_logic;
    m_hbm_arready      : in  std_logic;
    m_hbm_rdata        : in  std_logic_vector(255 downto 0);
    m_hbm_rresp        : in  std_logic_vector(1 downto 0);
    m_hbm_rlast        : in  std_logic;
    m_hbm_rvalid       : in  std_logic;
    m_hbm_rready       : out std_logic;
    user_clk           : in  std_logic;
    m_axis_tx_tdata    : out std_logic_vector(64*NLANES-1 downto 0);
    m_axis_tx_tkeep    : out std_logic_vector(8*NLANES-1 downto 0);
    m_axis_tx_tlast    : out std_logic;
    m_axis_tx_tvalid   : out std_logic;
    m_axis_tx_tready   : in  std_logic;
    s_axis_rx_tdata    : in  std_logic_vector(64*NLANES-1 downto 0);
    s_axis_rx_tkeep    : in  std_logic_vector(8*NLANES-1 downto 0);
    s_axis_rx_tlast    : in  std_logic;
    s_axis_rx_tvalid   : in  std_logic;
    tx_channel_up      : in  std_logic;
    rx_channel_up      : in  std_logic;
    gt_pll_lock        : in  std_logic;
    gtg_locked         : in  std_logic;
    init_clk           : in  std_logic;
    aur_reset_pb       : out std_logic;
    aur_pma_init       : out std_logic;
    aur_tx_polarity    : out std_logic_vector(NLANES-1 downto 0));
end entity;

architecture rtl of jc_tok_top is
  constant DW : positive := 64 * NLANES;
  signal ltx_d, lrx_d : std_logic_vector(DW-1 downto 0);
  signal ltx_l, ltx_v, ltx_r, lrx_l, lrx_v : std_logic;
  signal txq, rxq, txw, rxw : std_logic_vector(DW downto 0);
  signal txq_v, rxw_r : std_logic;
  signal link_ctrl : std_logic_vector(31 downto 0);
  signal s_tx, s_rx, s_pll, s_gtg, s_ovf : std_logic_vector(1 downto 0) := "00";
  signal u_rst_s : std_logic_vector(1 downto 0) := "11";
  signal u_rst, ovf_u : std_logic := '0';
  signal i_rpb, i_pma : std_logic_vector(1 downto 0) := "00";
  signal u_pol : std_logic_vector(2*NLANES-1 downto 0) := (others => '0');
  signal pol_mask : std_logic_vector(NLANES-1 downto 0);
  -- the synchroniser first stages; hw/jc/link/jc_link_timing.tcl names each one
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of s_tx, s_rx, s_pll, s_gtg, s_ovf, u_rst_s, i_rpb, i_pma, u_pol : signal is "TRUE";
begin
  core : entity work.tok_loop
    generic map(N_EMBD => N_EMBD, HAS_GATHER => HAS_GATHER, HAS_LINK => true, NLANES => NLANES)
    port map(clk => aclk, rst => arst,
             s_ctl_awaddr => s_ctl_awaddr, s_ctl_awvalid => s_ctl_awvalid, s_ctl_awready => s_ctl_awready,
             s_ctl_wdata => s_ctl_wdata, s_ctl_wstrb => s_ctl_wstrb, s_ctl_wvalid => s_ctl_wvalid,
             s_ctl_wready => s_ctl_wready, s_ctl_bresp => s_ctl_bresp, s_ctl_bvalid => s_ctl_bvalid,
             s_ctl_bready => s_ctl_bready, s_ctl_araddr => s_ctl_araddr, s_ctl_arvalid => s_ctl_arvalid,
             s_ctl_arready => s_ctl_arready, s_ctl_rdata => s_ctl_rdata, s_ctl_rresp => s_ctl_rresp,
             s_ctl_rvalid => s_ctl_rvalid, s_ctl_rready => s_ctl_rready,
             s_host_awaddr => s_host_awaddr, s_host_awvalid => s_host_awvalid, s_host_awready => s_host_awready,
             s_host_wdata => s_host_wdata, s_host_wstrb => s_host_wstrb, s_host_wvalid => s_host_wvalid,
             s_host_wready => s_host_wready, s_host_bresp => s_host_bresp, s_host_bvalid => s_host_bvalid,
             s_host_bready => s_host_bready, s_host_araddr => s_host_araddr, s_host_arvalid => s_host_arvalid,
             s_host_arready => s_host_arready, s_host_rdata => s_host_rdata, s_host_rresp => s_host_rresp,
             s_host_rvalid => s_host_rvalid, s_host_rready => s_host_rready,
             m_seam_awaddr => m_seam_awaddr, m_seam_awvalid => m_seam_awvalid, m_seam_awready => m_seam_awready,
             m_seam_wdata => m_seam_wdata, m_seam_wstrb => m_seam_wstrb, m_seam_wvalid => m_seam_wvalid,
             m_seam_wready => m_seam_wready, m_seam_bresp => m_seam_bresp, m_seam_bvalid => m_seam_bvalid,
             m_seam_bready => m_seam_bready, m_seam_araddr => m_seam_araddr, m_seam_arvalid => m_seam_arvalid,
             m_seam_arready => m_seam_arready, m_seam_rdata => m_seam_rdata, m_seam_rresp => m_seam_rresp,
             m_seam_rvalid => m_seam_rvalid, m_seam_rready => m_seam_rready,
             host_refused => open,
             m_hbm_araddr => m_hbm_araddr, m_hbm_arlen => m_hbm_arlen, m_hbm_arsize => m_hbm_arsize,
             m_hbm_arburst => m_hbm_arburst, m_hbm_arvalid => m_hbm_arvalid, m_hbm_arready => m_hbm_arready,
             m_hbm_rdata => m_hbm_rdata, m_hbm_rresp => m_hbm_rresp, m_hbm_rlast => m_hbm_rlast,
             m_hbm_rvalid => m_hbm_rvalid, m_hbm_rready => m_hbm_rready,
             ltx_tdata => ltx_d, ltx_tkeep => open, ltx_tlast => ltx_l, ltx_tvalid => ltx_v, ltx_tready => ltx_r,
             lrx_tdata => lrx_d, lrx_tlast => lrx_l, lrx_tvalid => lrx_v,
             lnk_tx_up => s_tx(1), lnk_rx_up => s_rx(1), lnk_gtg_lock => s_gtg(1),
             lnk_pll_lock => s_pll(1), lnk_rx_ovf => s_ovf(1), link_ctrl => link_ctrl);

  -- TX: core clock -> user clock
  txw <= ltx_l & ltx_d;
  txf : entity work.async_fifo
    generic map(W => DW + 1, DEPTH => 64, FAST_POP => true)
    port map(wclk => aclk, wrst => arst, w_valid => ltx_v, w_data => txw, w_ready => ltx_r,
             w_level => open, clr => '0', clr_done => open,
             rclk => user_clk, rrst => u_rst, q_valid => txq_v, q_data => txq, q_ready => m_axis_tx_tready);
  m_axis_tx_tdata <= txq(DW-1 downto 0);  m_axis_tx_tlast <= txq(DW);
  m_axis_tx_tvalid <= txq_v;              m_axis_tx_tkeep <= (others => '1');

  -- RX: user clock -> core clock; no backpressure, so an overflow is counted, never stalled
  rxw <= s_axis_rx_tlast & s_axis_rx_tdata;
  rxf : entity work.async_fifo
    generic map(W => DW + 1, DEPTH => 64, FAST_POP => true)
    port map(wclk => user_clk, wrst => u_rst, w_valid => s_axis_rx_tvalid, w_data => rxw, w_ready => rxw_r,
             w_level => open, clr => '0', clr_done => open,
             rclk => aclk, rrst => arst, q_valid => lrx_v, q_data => rxq, q_ready => '1');
  lrx_d <= rxq(DW-1 downto 0);  lrx_l <= rxq(DW);

  -- user clock domain: reset, overflow flag, TX polarity
  pol_mask <= std_logic_vector(to_unsigned(TXPOL_MASK, NLANES));
  process(user_clk)
  begin
    if rising_edge(user_clk) then
      u_rst_s <= u_rst_s(0) & arst;  u_rst <= u_rst_s(1);
      if u_rst = '1' then ovf_u <= '0';
      elsif s_axis_rx_tvalid = '1' and rxw_r = '0' then ovf_u <= '1'; end if;
      for i in 0 to NLANES - 1 loop
        u_pol(2*i+1) <= u_pol(2*i);  u_pol(2*i) <= link_ctrl(2) xor pol_mask(i);
        aur_tx_polarity(i) <= u_pol(2*i+1);
      end loop;
    end if;
  end process;

  -- core clock domain: status synchronisers
  process(aclk)
  begin
    if rising_edge(aclk) then
      s_tx <= s_tx(0) & tx_channel_up;  s_rx <= s_rx(0) & rx_channel_up;
      s_pll <= s_pll(0) & gt_pll_lock;  s_gtg <= s_gtg(0) & gtg_locked;
      s_ovf <= s_ovf(0) & ovf_u;
    end if;
  end process;

  -- init clock domain: the Aurora resets (PG074: reset_pb and pma_init are init_clk inputs)
  process(init_clk)
  begin
    if rising_edge(init_clk) then
      i_rpb <= i_rpb(0) & link_ctrl(0);  i_pma <= i_pma(0) & link_ctrl(1);
    end if;
  end process;
  aur_reset_pb <= i_rpb(1);
  aur_pma_init <= i_pma(1);
end architecture;
```

The status bits crossing into aclk are levels read by the host and the FSM, never counted, so 2-FF synchronisers are sufficient; `hw/jc/link/jc_link_timing.tcl` (Task 7) bounds every crossing by name and audits for unnamed ones.

- [ ] **Step 4: Write the single-die bench**

`sim/tb_tok_loop_top.vhd`:

```vhdl
-- sim/tb_tok_loop_top.vhd -- tok_loop (regs + FSM + mux + row sources) on one die against
-- the behavioural seam (plan 2026-11-04 Task 6). Oracles as tb_tok_loop: run_prompt's
-- captured seam writes and ids. Single-die cases are fed through the HOST row source (the
-- bench answers NEED_ROW with pl_embed_synthetic rows); case e through the GATHER source
-- from the Task 3 image poked into sim/jc_axi3_mem, so its trace is pl_embed_mv4i's rows.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.axil_bfm_pkg.all;
use work.tok_loop_pkg.all;
use work.tok_loop_tb_pkg.all;

entity tb_tok_loop_top is
  generic(VEC : string := "tok_loop_vec.txt"; GVEC : string := "embed_gather_k4096_vec.txt");
end entity;

architecture sim of tb_tok_loop_top is
  constant N : positive := 4096;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal cm, hm : axil_m2s_t := AXIL_M2S_IDLE;
  signal cs, hs : axil_s2m_t;
  signal s_awaddr, s_araddr : std_logic_vector(11 downto 0);
  signal s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready : std_logic;
  signal s_arvalid, s_arready, s_rvalid, s_rready : std_logic;
  signal s_wdata, s_rdata : std_logic_vector(31 downto 0);
  signal s_wstrb : std_logic_vector(3 downto 0);
  signal s_bresp, s_rresp : std_logic_vector(1 downto 0);
  signal araddr : std_logic_vector(32 downto 0);
  signal arlen : std_logic_vector(7 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst : std_logic_vector(1 downto 0);
  signal arvalid, arready, rlast, rvalid, rready : std_logic;
  signal rdata : std_logic_vector(255 downto 0);
  signal rresp : std_logic_vector(1 downto 0);
  signal poke_en : std_logic := '0';
  signal poke_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal poke_data : std_logic_vector(255 downto 0) := (others => '0');
  signal mem_errs : natural;
  signal wr_ev : std_logic;
  signal wr_addr : std_logic_vector(11 downto 0);
  signal wr_data : std_logic_vector(31 downto 0);
  signal arm : std_logic := '0';
  signal case_sel : natural := 0;
  signal chk_errs, chk_nw : natural;
  signal chk_end : boolean;
begin
  clk <= not clk after 2.5 ns;

  dut : entity work.tok_loop
    generic map(N_EMBD => N, HAS_GATHER => true, HAS_LINK => false)
    port map(clk => clk, rst => rst,
             s_ctl_awaddr => cm.awaddr(15 downto 0), s_ctl_awvalid => cm.awvalid, s_ctl_awready => cs.awready,
             s_ctl_wdata => cm.wdata, s_ctl_wstrb => cm.wstrb, s_ctl_wvalid => cm.wvalid, s_ctl_wready => cs.wready,
             s_ctl_bresp => cs.bresp, s_ctl_bvalid => cs.bvalid, s_ctl_bready => cm.bready,
             s_ctl_araddr => cm.araddr(15 downto 0), s_ctl_arvalid => cm.arvalid, s_ctl_arready => cs.arready,
             s_ctl_rdata => cs.rdata, s_ctl_rresp => cs.rresp, s_ctl_rvalid => cs.rvalid, s_ctl_rready => cm.rready,
             s_host_awaddr => hm.awaddr(11 downto 0), s_host_awvalid => hm.awvalid, s_host_awready => hs.awready,
             s_host_wdata => hm.wdata, s_host_wstrb => hm.wstrb, s_host_wvalid => hm.wvalid, s_host_wready => hs.wready,
             s_host_bresp => hs.bresp, s_host_bvalid => hs.bvalid, s_host_bready => hm.bready,
             s_host_araddr => hm.araddr(11 downto 0), s_host_arvalid => hm.arvalid, s_host_arready => hs.arready,
             s_host_rdata => hs.rdata, s_host_rresp => hs.rresp, s_host_rvalid => hs.rvalid, s_host_rready => hm.rready,
             m_seam_awaddr => s_awaddr, m_seam_awvalid => s_awvalid, m_seam_awready => s_awready,
             m_seam_wdata => s_wdata, m_seam_wstrb => s_wstrb, m_seam_wvalid => s_wvalid, m_seam_wready => s_wready,
             m_seam_bresp => s_bresp, m_seam_bvalid => s_bvalid, m_seam_bready => s_bready,
             m_seam_araddr => s_araddr, m_seam_arvalid => s_arvalid, m_seam_arready => s_arready,
             m_seam_rdata => s_rdata, m_seam_rresp => s_rresp, m_seam_rvalid => s_rvalid, m_seam_rready => s_rready,
             host_refused => open,
             m_hbm_araddr => araddr, m_hbm_arlen => arlen, m_hbm_arsize => arsize, m_hbm_arburst => arburst,
             m_hbm_arvalid => arvalid, m_hbm_arready => arready, m_hbm_rdata => rdata, m_hbm_rresp => rresp,
             m_hbm_rlast => rlast, m_hbm_rvalid => rvalid, m_hbm_rready => rready,
             ltx_tdata => open, ltx_tkeep => open, ltx_tlast => open, ltx_tvalid => open, ltx_tready => '1',
             lrx_tdata => (others => '0'), lrx_tlast => '0', lrx_tvalid => '0',
             lnk_tx_up => '0', lnk_rx_up => '0', lnk_gtg_lock => '0', lnk_pll_lock => '0', lnk_rx_ovf => '0',
             link_ctrl => open);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 14, STALL => true)
    port map(clk => clk, awaddr => (others => '0'), awlen => "0000", awsize => "101",
             awburst => "01", awvalid => '0', awready => open, wdata => (others => '0'),
             wstrb => (others => '0'), wlast => '0', wvalid => '0', wready => open,
             bresp => open, bvalid => open, bready => '1',
             araddr => araddr, arlen => arlen(3 downto 0), arsize => arsize, arburst => arburst,
             arvalid => arvalid, arready => arready, rdata => rdata, rresp => rresp,
             rlast => rlast, rvalid => rvalid, rready => rready,
             poke_en => poke_en, poke_addr => poke_addr, poke_data => poke_data,
             peek_addr => (others => '0'), peek_data => open, peek_hit => open, errors => mem_errs);

  seam : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst, awaddr => s_awaddr, awvalid => s_awvalid, awready => s_awready,
             wdata => s_wdata, wvalid => s_wvalid, wready => s_wready, bresp => s_bresp,
             bvalid => s_bvalid, bready => s_bready, araddr => s_araddr, arvalid => s_arvalid,
             arready => s_arready, rdata => s_rdata, rresp => s_rresp, rvalid => s_rvalid,
             rready => s_rready, wr_ev => wr_ev, wr_addr => wr_addr, wr_data => wr_data);

  chk : entity work.seam_trace_chk
    generic map(VEC => VEC, DIE => 0)
    port map(clk => clk, arm => arm, case_sel => case_sel, wr_ev => wr_ev, wr_addr => wr_addr,
             wr_data => wr_data, errs => chk_errs, at_end => chk_end, n_writes => chk_nw);

  host : process
    variable V : vec_t := load_vec(VEC);
    file gf : text open read_mode is GVEC;
    variable l : line;
    variable ch : character;
    variable a9 : std_logic_vector(35 downto 0);
    variable b256 : std_logic_vector(255 downto 0);
    variable nbeats, mcount : integer;
    variable emb : std_logic_vector(35 downto 0);
    variable resp : std_logic_vector(1 downto 0);
    variable d, xexp : std_logic_vector(31 downto 0);
    variable row : row16_arr(0 to N - 1);
    variable e, c, n, nsingle, ngather, want_reason : natural := 0;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_tok_loop_top: " & msg severity error; end if;
    end procedure;
    procedure wr(a : natural; x : std_logic_vector(31 downto 0)) is
    begin
      axil_wr(clk, cm, cs, a, x, resp);
      chk(resp = "00", "control write OKAY");
    end procedure;
    procedure rd(a : natural; x : out std_logic_vector(31 downto 0)) is
    begin
      axil_rd(clk, cm, cs, a, x, resp);
    end procedure;
    procedure serve_row is
      variable t : std_logic_vector(31 downto 0);
    begin
      rd(TL_ROW_TOK, t);
      synth_row(to_integer(unsigned(t)), row, xexp);
      wr(TL_ROW_EXP, xexp);
      wr(TL_ROW_ADDR, u32(0));
      for j in 0 to N - 1 loop wr(TL_ROW_DATA, x"0000" & row(j)); end loop;
      wr(TL_CTRL, u32(8));                                   -- ROW_READY
    end procedure;
  begin
    -- the Task 3 image
    readline(gf, l); while l(1) = '#' loop readline(gf, l); end loop;
    read(l, ch); hread(l, emb); read(l, nbeats); read(l, mcount);
    for k in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for k in 0 to nbeats - 1 loop
      readline(gf, l); read(l, ch); hread(l, a9); hread(l, b256);
      poke_en <= '1'; poke_addr <= "0000" & a9; poke_data <= b256;
      wait until rising_edge(clk);
    end loop;
    poke_en <= '0';
    wait until rising_edge(clk);
    rd(TL_ID, d); chk(d = TL_ID_MAGIC, "ID reads TLP1");
    rd(TL_CAPS, d); chk(unsigned(d(15 downto 0)) = N and d(16) = '1' and d(17) = '0', "CAPS: N_EMBD, gather, no link");
    axil_rd(clk, hm, hs, 16#8C#, d, resp); chk(resp = "00", "host seam read OKAY while the loop is idle");
    for k in 0 to V.n_cases - 1 loop
      next when V.cs(k).pair;
      case_sel <= k; arm <= '1'; wait until rising_edge(clk); arm <= '0';
      wr(TL_PROMPT_LEN, u32(V.cs(k).plen));
      wr(TL_MAX_NEW, u32(V.cs(k).max_new));
      if V.cs(k).stop >= 0 then wr(TL_STOP_ID0, u32(V.cs(k).stop)); else wr(TL_STOP_ID0, x"FFFFFFFF"); end if;
      wr(TL_ROLE, u32(ROLE_SINGLE));
      if V.cs(k).gather then
        ngather := ngather + 1;
        wr(TL_ROW_SRC, u32(SRC_GATHER));
        wr(TL_EMB_BASE_LO, emb(31 downto 0));
        wr(TL_EMB_BASE_HI, x"0000000" & "000" & emb(32));
      else
        nsingle := nsingle + 1;
        wr(TL_ROW_SRC, u32(SRC_HOST));
      end if;
      wr(TL_PROMPT_ADDR, u32(0));
      for j in 0 to V.cs(k).plen - 1 loop wr(TL_PROMPT_DATA, u32(V.ints(V.cs(k).p0 + j))); end loop;
      wr(TL_CTRL, u32(1));
      n := 0;
      loop
        rd(TL_STATUS, d);
        exit when d(1 downto 0) = "10";
        if d(2) = '1' then serve_row; end if;
        n := n + 1;
        assert n < 4000000 report "tb_tok_loop_top: case never stopped" severity failure;
      end loop;
      want_reason := R_MAX_NEW;
      if V.cs(k).stop >= 0 and V.ints(V.cs(k).i0 + V.cs(k).n_ids - 1) = V.cs(k).stop then
        want_reason := R_STOP_ID;
      end if;
      chk(to_integer(unsigned(d(15 downto 8))) = want_reason, "case " & integer'image(k) & " stop reason");
      rd(TL_N_GEN, d);
      chk(to_integer(unsigned(d)) = V.cs(k).n_ids, "case " & integer'image(k) & " id count");
      wr(TL_OUT_ADDR, u32(0));
      for j in 0 to V.cs(k).n_ids - 1 loop
        rd(TL_OUT_DATA, d);
        chk(to_integer(unsigned(d)) = V.ints(V.cs(k).i0 + j),
            "case " & integer'image(k) & " id " & integer'image(j) & " equals run_prompt's");
      end loop;
      wait until rising_edge(clk);
      chk(chk_end, "case " & integer'image(k) & ": every host write was replayed");
      axil_rd(clk, hm, hs, 16#8C#, d, resp); chk(resp = "00", "host seam read OKAY after the stop");
    end loop;
    chk(nsingle >= 4 and ngather >= 1, "four host-row cases and one gather case ran");
    chk(chk_errs = 0, "no seam write differed from the host's");
    chk(mem_errs = 0, "every HBM burst obeyed AXI3");
    e := e + chk_errs;
    if e = 0 then
      report "PASS: tb_tok_loop_top checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_tok_loop_top errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
```

Run: `REGRESS_SCRATCH=~/regress_scratch/t6-b bash sim/regress.sh --only tb_tok_loop_top --keep`
Expected: `OVERALL PASS 1`, log `PASS: tb_tok_loop_top checks=` with n >= 40. The two vector files must be visible to the bench in its run directory: `sim/regress.sh` links `sim/*.txt` vectors into each row's run directory (as for `tb_tok_loop` and `tb_embed_gather`); if it does not, stop and report rather than hard-coding a path.

- [ ] **Step 5: Write the two-die bench**

`sim/tb_tok_loop_pair.vhd`:

```vhdl
-- sim/tb_tok_loop_pair.vhd -- two jc_tok_top (die A role A with host rows, die B role B with
-- link rows) joined by sim/jc_link_chan_model on a separate user clock, so the async FIFOs
-- and synchronisers are in the path (plan 2026-11-04 Task 6). The bench is the host relay of
-- spec 1b.5 phase 1: B's ids to A's NEXT_TOKEN, B's LINK_CONSUMED to A's LINK_CREDIT (plan
-- D3), and RESEND on B's pause. Oracles: both dies' seam writes equal run_prompt's pair
-- capture (case pa), B's ids equal run_prompt's; under P2/P3 faults, the same writes and ids.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axil_bfm_pkg.all;
use work.tok_loop_pkg.all;
use work.tok_loop_tb_pkg.all;
use work.jc_link_pkg.all;

entity tb_tok_loop_pair is
  generic(VEC : string := "tok_loop_vec.txt");
end entity;

architecture sim of tb_tok_loop_pair is
  constant N : positive := 4096;
  constant FB : natural := lk_beats(N, 2);           -- beats per frame, NLANES 1
  signal clk, uclk : std_logic := '0';
  signal rst : std_logic := '1';
  signal ma, mb : axil_m2s_t := AXIL_M2S_IDLE;
  signal sa, sb : axil_s2m_t;
  type seam_bus is record
    awaddr, araddr : std_logic_vector(11 downto 0);
    awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready : std_logic;
    wdata, rdata : std_logic_vector(31 downto 0);
    wstrb : std_logic_vector(3 downto 0);
    bresp, rresp : std_logic_vector(1 downto 0);
  end record;
  signal qa, qb : seam_bus;
  signal a_tx, b_rx : std_logic_vector(63 downto 0);
  signal a_txl, a_txv, a_txr, b_rxl, b_rxv, chan_up : std_logic;
  signal down : std_logic := '0';
  signal flip_beat, drop_beat : integer := -1;
  signal nbeats : natural;
  signal ev_a, ev_b : std_logic;
  signal ad_a, ad_b : std_logic_vector(11 downto 0);
  signal dd_a, dd_b : std_logic_vector(31 downto 0);
  signal arm : std_logic := '0';
  signal case_sel : natural := 0;
  signal ea, eb, nwa, nwb : natural;
  signal enda, endb : boolean;
begin
  clk <= not clk after 2.5 ns;        -- clk_core 200 MHz
  uclk <= not uclk after 3.1 ns;      -- Aurora user clock, 161.3 MHz at 10.3125 Gb/s x 1 lane

  top_a : entity work.jc_tok_top
    generic map(N_EMBD => N, NLANES => 1, HAS_GATHER => false, TXPOL_MASK => 0)
    port map(aclk => clk, arst => rst,
             s_host_awaddr => (others => '0'), s_host_awvalid => '0', s_host_awready => open,
             s_host_wdata => (others => '0'), s_host_wstrb => "1111", s_host_wvalid => '0', s_host_wready => open,
             s_host_bresp => open, s_host_bvalid => open, s_host_bready => '1',
             s_host_araddr => (others => '0'), s_host_arvalid => '0', s_host_arready => open,
             s_host_rdata => open, s_host_rresp => open, s_host_rvalid => open, s_host_rready => '1',
             m_seam_awaddr => qa.awaddr, m_seam_awvalid => qa.awvalid, m_seam_awready => qa.awready,
             m_seam_wdata => qa.wdata, m_seam_wstrb => qa.wstrb, m_seam_wvalid => qa.wvalid, m_seam_wready => qa.wready,
             m_seam_bresp => qa.bresp, m_seam_bvalid => qa.bvalid, m_seam_bready => qa.bready,
             m_seam_araddr => qa.araddr, m_seam_arvalid => qa.arvalid, m_seam_arready => qa.arready,
             m_seam_rdata => qa.rdata, m_seam_rresp => qa.rresp, m_seam_rvalid => qa.rvalid, m_seam_rready => qa.rready,
             s_ctl_awaddr => ma.awaddr(15 downto 0), s_ctl_awvalid => ma.awvalid, s_ctl_awready => sa.awready,
             s_ctl_wdata => ma.wdata, s_ctl_wstrb => ma.wstrb, s_ctl_wvalid => ma.wvalid, s_ctl_wready => sa.wready,
             s_ctl_bresp => sa.bresp, s_ctl_bvalid => sa.bvalid, s_ctl_bready => ma.bready,
             s_ctl_araddr => ma.araddr(15 downto 0), s_ctl_arvalid => ma.arvalid, s_ctl_arready => sa.arready,
             s_ctl_rdata => sa.rdata, s_ctl_rresp => sa.rresp, s_ctl_rvalid => sa.rvalid, s_ctl_rready => ma.rready,
             m_hbm_araddr => open, m_hbm_arlen => open, m_hbm_arsize => open, m_hbm_arburst => open,
             m_hbm_arvalid => open, m_hbm_arready => '0', m_hbm_rdata => (others => '0'), m_hbm_rresp => "00",
             m_hbm_rlast => '0', m_hbm_rvalid => '0', m_hbm_rready => open,
             user_clk => uclk, m_axis_tx_tdata => a_tx, m_axis_tx_tkeep => open, m_axis_tx_tlast => a_txl,
             m_axis_tx_tvalid => a_txv, m_axis_tx_tready => a_txr,
             s_axis_rx_tdata => (others => '0'), s_axis_rx_tkeep => (others => '1'), s_axis_rx_tlast => '0',
             s_axis_rx_tvalid => '0', tx_channel_up => '1', rx_channel_up => '0', gt_pll_lock => '1',
             gtg_locked => '1', init_clk => clk, aur_reset_pb => open, aur_pma_init => open,
             aur_tx_polarity => open);
  seam_a : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst, awaddr => qa.awaddr, awvalid => qa.awvalid, awready => qa.awready,
             wdata => qa.wdata, wvalid => qa.wvalid, wready => qa.wready, bresp => qa.bresp,
             bvalid => qa.bvalid, bready => qa.bready, araddr => qa.araddr, arvalid => qa.arvalid,
             arready => qa.arready, rdata => qa.rdata, rresp => qa.rresp, rvalid => qa.rvalid,
             rready => qa.rready, wr_ev => ev_a, wr_addr => ad_a, wr_data => dd_a);

  top_b : entity work.jc_tok_top
    generic map(N_EMBD => N, NLANES => 1, HAS_GATHER => false, TXPOL_MASK => 0)
    port map(aclk => clk, arst => rst,
             s_host_awaddr => (others => '0'), s_host_awvalid => '0', s_host_awready => open,
             s_host_wdata => (others => '0'), s_host_wstrb => "1111", s_host_wvalid => '0', s_host_wready => open,
             s_host_bresp => open, s_host_bvalid => open, s_host_bready => '1',
             s_host_araddr => (others => '0'), s_host_arvalid => '0', s_host_arready => open,
             s_host_rdata => open, s_host_rresp => open, s_host_rvalid => open, s_host_rready => '1',
             m_seam_awaddr => qb.awaddr, m_seam_awvalid => qb.awvalid, m_seam_awready => qb.awready,
             m_seam_wdata => qb.wdata, m_seam_wstrb => qb.wstrb, m_seam_wvalid => qb.wvalid, m_seam_wready => qb.wready,
             m_seam_bresp => qb.bresp, m_seam_bvalid => qb.bvalid, m_seam_bready => qb.bready,
             m_seam_araddr => qb.araddr, m_seam_arvalid => qb.arvalid, m_seam_arready => qb.arready,
             m_seam_rdata => qb.rdata, m_seam_rresp => qb.rresp, m_seam_rvalid => qb.rvalid, m_seam_rready => qb.rready,
             s_ctl_awaddr => mb.awaddr(15 downto 0), s_ctl_awvalid => mb.awvalid, s_ctl_awready => sb.awready,
             s_ctl_wdata => mb.wdata, s_ctl_wstrb => mb.wstrb, s_ctl_wvalid => mb.wvalid, s_ctl_wready => sb.wready,
             s_ctl_bresp => sb.bresp, s_ctl_bvalid => sb.bvalid, s_ctl_bready => mb.bready,
             s_ctl_araddr => mb.araddr(15 downto 0), s_ctl_arvalid => mb.arvalid, s_ctl_arready => sb.arready,
             s_ctl_rdata => sb.rdata, s_ctl_rresp => sb.rresp, s_ctl_rvalid => sb.rvalid, s_ctl_rready => mb.rready,
             m_hbm_araddr => open, m_hbm_arlen => open, m_hbm_arsize => open, m_hbm_arburst => open,
             m_hbm_arvalid => open, m_hbm_arready => '0', m_hbm_rdata => (others => '0'), m_hbm_rresp => "00",
             m_hbm_rlast => '0', m_hbm_rvalid => '0', m_hbm_rready => open,
             user_clk => uclk, m_axis_tx_tdata => open, m_axis_tx_tkeep => open, m_axis_tx_tlast => open,
             m_axis_tx_tvalid => open, m_axis_tx_tready => '1',
             s_axis_rx_tdata => b_rx, s_axis_rx_tkeep => (others => '1'), s_axis_rx_tlast => b_rxl,
             s_axis_rx_tvalid => b_rxv, tx_channel_up => '1', rx_channel_up => chan_up, gt_pll_lock => '1',
             gtg_locked => '1', init_clk => clk, aur_reset_pb => open, aur_pma_init => open,
             aur_tx_polarity => open);
  seam_b : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst, awaddr => qb.awaddr, awvalid => qb.awvalid, awready => qb.awready,
             wdata => qb.wdata, wvalid => qb.wvalid, wready => qb.wready, bresp => qb.bresp,
             bvalid => qb.bvalid, bready => qb.bready, araddr => qb.araddr, arvalid => qb.arvalid,
             arready => qb.arready, rdata => qb.rdata, rresp => qb.rresp, rvalid => qb.rvalid,
             rready => qb.rready, wr_ev => ev_b, wr_addr => ad_b, wr_data => dd_b);

  chan : entity work.jc_link_chan_model
    generic map(W => 2, LAT => 8)
    port map(clk => uclk, s_tdata => a_tx, s_tlast => a_txl, s_tvalid => a_txv, s_tready => a_txr,
             m_tdata => b_rx, m_tlast => b_rxl, m_tvalid => b_rxv, chan_up => chan_up, down => down,
             flip_beat => flip_beat, flip_bit => 3, drop_beat => drop_beat, nbeats => nbeats);

  chk_a : entity work.seam_trace_chk
    generic map(VEC => VEC, DIE => 0)
    port map(clk => clk, arm => arm, case_sel => case_sel, wr_ev => ev_a, wr_addr => ad_a,
             wr_data => dd_a, errs => ea, at_end => enda, n_writes => nwa);
  chk_b : entity work.seam_trace_chk
    generic map(VEC => VEC, DIE => 1)
    port map(clk => clk, arm => arm, case_sel => case_sel, wr_ev => ev_b, wr_addr => ad_b,
             wr_data => dd_b, errs => eb, at_end => endb, n_writes => nwb);

  host : process
    variable V : vec_t := load_vec(VEC);
    variable resp : std_logic_vector(1 downto 0);
    variable d, da, db, xexp : std_logic_vector(31 downto 0);
    variable row : row16_arr(0 to N - 1);
    variable e, c, kp, polls, credit, relayed, handled, nb0, t_pause : natural := 0;
    variable fault : natural;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_tok_loop_pair: " & msg severity error; end if;
    end procedure;
    procedure wa(a : natural; x : std_logic_vector(31 downto 0)) is
    begin
      axil_wr(clk, ma, sa, a, x, resp); chk(resp = "00", "die A write OKAY");
    end procedure;
    procedure wb(a : natural; x : std_logic_vector(31 downto 0)) is
    begin
      axil_wr(clk, mb, sb, a, x, resp); chk(resp = "00", "die B write OKAY");
    end procedure;
    procedure ra(a : natural; x : out std_logic_vector(31 downto 0)) is
    begin
      axil_rd(clk, ma, sa, a, x, resp);
    end procedure;
    procedure rb(a : natural; x : out std_logic_vector(31 downto 0)) is
    begin
      axil_rd(clk, mb, sb, a, x, resp);
    end procedure;
    procedure setup(cap : natural; tmo_link : natural) is
    begin
      for die in 0 to 1 loop
        if die = 0 then
          wa(TL_PROMPT_LEN, u32(V.cs(kp).plen)); wa(TL_MAX_NEW, u32(V.cs(kp).max_new));
          wa(TL_STOP_ID0, x"FFFFFFFF"); wa(TL_ROLE, u32(ROLE_A)); wa(TL_ROW_SRC, u32(SRC_HOST));
          wa(TL_RESEND_CAP, u32(cap)); wa(TL_LINK_CREDIT, u32(0)); wa(TL_PROMPT_ADDR, u32(0));
          for j in 0 to V.cs(kp).plen - 1 loop wa(TL_PROMPT_DATA, u32(V.ints(V.cs(kp).p0 + j))); end loop;
        else
          wb(TL_PROMPT_LEN, u32(V.cs(kp).plen)); wb(TL_MAX_NEW, u32(V.cs(kp).max_new));
          wb(TL_STOP_ID0, x"FFFFFFFF"); wb(TL_ROLE, u32(ROLE_B)); wb(TL_ROW_SRC, u32(SRC_LINK));
          wb(TL_TMO_LINK, u32(tmo_link)); wb(TL_PROMPT_ADDR, u32(0));
          for j in 0 to V.cs(kp).plen - 1 loop wb(TL_PROMPT_DATA, u32(V.ints(V.cs(kp).p0 + j))); end loop;
        end if;
      end loop;
    end procedure;
    -- one run; fault 0 clean, 2 payload flip in frame 2 with a delayed RESEND, 3 link down in
    -- frame 4, 4 every frame from frame 1 on corrupted with RESEND_CAP 2
    procedure run(f : natural) is
      variable fails : natural;
    begin
      case_sel <= kp; arm <= '1'; wait until rising_edge(clk); arm <= '0';
      nb0 := nbeats; credit := 0; relayed := 0; handled := 0; polls := 0; t_pause := 0;
      flip_beat <= -1; drop_beat <= -1; down <= '0';
      if f = 2 then flip_beat <= nb0 + 2 * FB + 6; end if;
      if f = 4 then flip_beat <= nb0 + 1 * FB + 6; end if;
      wb(TL_CTRL, u32(1)); wa(TL_CTRL, u32(1));
      loop
        ra(TL_STATUS, da); rb(TL_STATUS, db);
        exit when da(1 downto 0) = "10" and db(1 downto 0) = "10";
        if f = 4 and da(1 downto 0) = "10" and db(1 downto 0) = "01" then
          wb(TL_CTRL, u32(2));                                    -- ABORT B: A gave up
        end if;
        if da(2) = '1' then                                       -- A: NEED_ROW
          ra(TL_ROW_TOK, d); synth_row(to_integer(unsigned(d)), row, xexp);
          wa(TL_ROW_EXP, xexp); wa(TL_ROW_ADDR, u32(0));
          for j in 0 to N - 1 loop wa(TL_ROW_DATA, x"0000" & row(j)); end loop;
          wa(TL_CTRL, u32(8));
        end if;
        rb(TL_LINK_CONSUMED, d);                                  -- credit relay (plan D3)
        if to_integer(unsigned(d)) /= credit then credit := to_integer(unsigned(d)); wa(TL_LINK_CREDIT, d); end if;
        rb(TL_OUT_COUNT, d);                                      -- token relay (spec 1b.5)
        while relayed < to_integer(unsigned(d)) loop
          wb(TL_OUT_ADDR, u32(relayed)); rb(TL_OUT_DATA, xexp);
          wa(TL_NEXT_TOKEN, xexp); relayed := relayed + 1;
        end loop;
        if f = 3 and down = '0' and t_pause = 0 and nbeats >= nb0 + 4 * FB + 100 then
          down <= '1'; for j in 1 to 400 loop wait until rising_edge(uclk); end loop; down <= '0';
          t_pause := 1;
        end if;
        if db(4) = '1' then                                       -- B paused: LINK_BAD or LINK_DOWN
          rb(TL_CRC_FAILS, d); fails := to_integer(unsigned(d));
          rb(TL_LINK_DOWNS, d); fails := fails + to_integer(unsigned(d));
          if fails > handled then
            if f = 2 then
              for j in 1 to 600000 loop wait until rising_edge(clk); end loop;   -- past TMO_LINK
              rb(TL_STATUS, db);
              chk(db(1 downto 0) = "01" and db(4) = '1', "P2: B still paused, not timed out, after 600k cycles");
            end if;
            if f = 4 then flip_beat <= nbeats + 6; end if;        -- the resend is corrupted too
            handled := fails;
            wa(TL_CTRL, u32(4));                                  -- RESEND (P3: A is still busy
                                                                   -- sending the cut frame's tail
                                                                   -- here; jc_link_tx latches this
                                                                   -- and serves it at T_IDLE, finding 4)
          end if;
        end if;
        polls := polls + 1;
        assert polls < 3000000 report "tb_tok_loop_pair: run never ended" severity failure;
      end loop;
    end procedure;
    procedure check_ids(tag : string) is
    begin
      rb(TL_N_GEN, d);
      chk(to_integer(unsigned(d)) = V.cs(kp).n_ids, tag & ": B id count");
      wb(TL_OUT_ADDR, u32(0));
      for j in 0 to V.cs(kp).n_ids - 1 loop
        rb(TL_OUT_DATA, d);
        chk(to_integer(unsigned(d)) = V.ints(V.cs(kp).i0 + j), tag & ": B id " & integer'image(j) & " equals run_prompt's");
      end loop;
      wa(TL_OUT_ADDR, u32(0));
      for j in 0 to V.cs(kp).n_ids - 1 loop
        ra(TL_OUT_DATA, d);
        chk(to_integer(unsigned(d)) = V.ints(V.cs(kp).i0 + j), tag & ": A received id " & integer'image(j));
      end loop;
      wait until rising_edge(clk);
      chk(enda and endb, tag & ": both dies replayed every host write");
    end procedure;
  begin
    for k in 0 to V.n_cases - 1 loop if V.cs(k).pair then kp := k; end if; end loop;
    chk(V.cs(kp).pair, "the vectors carry a pair case");
    for k in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for k in 1 to 20 loop wait until rising_edge(clk); end loop;
    -- P1: clean
    setup(3, 400000); run(0);
    ra(TL_STATUS, da); rb(TL_STATUS, db);
    chk(unsigned(da(15 downto 8)) = R_MAX_NEW and unsigned(db(15 downto 8)) = R_MAX_NEW, "P1: both stop on MAX_NEW");
    check_ids("P1");
    ra(TL_RESENDS, d); chk(unsigned(d) = 0, "P1: no resend");
    ra(TL_FRAMES_SENT, d); chk(to_integer(unsigned(d)) = V.cs(kp).plen + V.cs(kp).n_ids - 1, "P1: one frame per position");
    rb(TL_FRAMES_GOOD, d); chk(to_integer(unsigned(d)) = V.cs(kp).plen + V.cs(kp).n_ids - 1, "P1: every frame good");
    rb(TL_CRC_FAILS, d); chk(unsigned(d) = 0, "P1: no CRC failure");
    rb(TL_OVERRUNS, d); chk(unsigned(d) = 0, "P1: no overrun");
    -- P2: payload flip, RESEND held back past TMO_LINK
    setup(3, 400000); run(2);
    rb(TL_STATUS, db); chk(unsigned(db(15 downto 8)) = R_MAX_NEW, "P2: B stops on MAX_NEW, not LINK_TIMEOUT");
    check_ids("P2");
    rb(TL_CRC_FAILS, d); chk(unsigned(d) = 1, "P2: one CRC failure counted");
    ra(TL_RESENDS, d); chk(unsigned(d) = 1, "P2: one resend");
    -- P3: link down mid-frame 4
    setup(3, 400000); run(3);
    check_ids("P3");
    rb(TL_LINK_DOWNS, d); chk(unsigned(d) = 1, "P3: one link-down counted");
    ra(TL_RESENDS, d); chk(unsigned(d) = 1, "P3: one resend");
    -- P4: every frame corrupted from frame 1, RESEND_CAP 2
    setup(2, 400000); run(4);
    ra(TL_STATUS, da); rb(TL_STATUS, db);
    chk(unsigned(da(15 downto 8)) = R_LINK_RETRY_EXHAUSTED, "P4: A stops LINK_RETRY_EXHAUSTED");
    chk(unsigned(db(15 downto 8)) = R_ABORT, "P4: B stopped by the host's ABORT");
    ra(TL_RESENDS, d); chk(unsigned(d) = 2, "P4: exactly RESEND_CAP resends");
    ra(TL_LINK_STATUS, d); chk(d(LS_TX_EXH) = '1', "P4: LINK_STATUS shows the exhausted framer");
    e := e + ea + eb;
    if e = 0 then
      report "PASS: tb_tok_loop_pair checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_tok_loop_pair errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
```

In P4 the dies' traces are prefixes of `pa`'s, so `enda`/`endb` are not checked there and `ea`/`eb` still must be 0.

Run: `REGRESS_SCRATCH=~/regress_scratch/t6-c bash sim/regress.sh --only tb_tok_loop_pair --keep`
Expected: `OVERALL PASS 1`, `PASS: tb_tok_loop_pair checks=` with n >= 60.

- [ ] **Step 6: Write the fault bench**

The value oracle for these cases is F0, a clean run in the same bench; F0 itself is pinned to run_prompt by the two benches above, which share every RTL file with this one.

`sim/tb_tok_loop_faults.vhd`:

```vhdl
-- sim/tb_tok_loop_faults.vhd -- tok_loop error, stop and timeout behaviour (spec 2026-11-04
-- section 3; plan Task 6 and the Review Focus list). N_EMBD 64 and OUT_DEPTH 4 keep it fast;
-- host rows are pl_embed_synthetic's. F0 is a clean reference run; every later case either
-- stops with the named reason or must reproduce F0's ids exactly.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axil_bfm_pkg.all;
use work.tok_loop_pkg.all;
use work.tok_loop_tb_pkg.all;

entity tb_tok_loop_faults is
end entity;

architecture sim of tb_tok_loop_faults is
  constant N : positive := 64;
  constant NREF : positive := 8;
  signal clk : std_logic := '0';
  signal rst, seam_rst, srst : std_logic := '1';
  signal cm, hm : axil_m2s_t := AXIL_M2S_IDLE;
  signal cs, hs : axil_s2m_t;
  signal s_awaddr, s_araddr : std_logic_vector(11 downto 0);
  signal s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready : std_logic;
  signal s_arvalid, s_arready, s_rvalid, s_rready : std_logic;
  signal s_wdata, s_rdata : std_logic_vector(31 downto 0);
  signal s_wstrb : std_logic_vector(3 downto 0);
  signal s_bresp, s_rresp : std_logic_vector(1 downto 0);
  signal wr_ev, refused : std_logic;
  signal wr_addr : std_logic_vector(11 downto 0);
  signal wr_data : std_logic_vector(31 downto 0);
  signal maxpos : natural := 16384;
  signal f_err_pos, f_hang_pos, f_slverr_off : integer := -1;
  signal f_tokpos_stuck : std_logic := '0';
  signal seq_resets, n_refused : natural := 0;
  signal ltx_v : std_logic;
begin
  clk <= not clk after 2.5 ns;
  srst <= rst or seam_rst;

  dut : entity work.tok_loop
    generic map(N_EMBD => N, OUT_DEPTH => 4, HAS_GATHER => false, HAS_LINK => true)
    port map(clk => clk, rst => rst,
             s_ctl_awaddr => cm.awaddr(15 downto 0), s_ctl_awvalid => cm.awvalid, s_ctl_awready => cs.awready,
             s_ctl_wdata => cm.wdata, s_ctl_wstrb => cm.wstrb, s_ctl_wvalid => cm.wvalid, s_ctl_wready => cs.wready,
             s_ctl_bresp => cs.bresp, s_ctl_bvalid => cs.bvalid, s_ctl_bready => cm.bready,
             s_ctl_araddr => cm.araddr(15 downto 0), s_ctl_arvalid => cm.arvalid, s_ctl_arready => cs.arready,
             s_ctl_rdata => cs.rdata, s_ctl_rresp => cs.rresp, s_ctl_rvalid => cs.rvalid, s_ctl_rready => cm.rready,
             s_host_awaddr => hm.awaddr(11 downto 0), s_host_awvalid => hm.awvalid, s_host_awready => hs.awready,
             s_host_wdata => hm.wdata, s_host_wstrb => hm.wstrb, s_host_wvalid => hm.wvalid, s_host_wready => hs.wready,
             s_host_bresp => hs.bresp, s_host_bvalid => hs.bvalid, s_host_bready => hm.bready,
             s_host_araddr => hm.araddr(11 downto 0), s_host_arvalid => hm.arvalid, s_host_arready => hs.arready,
             s_host_rdata => hs.rdata, s_host_rresp => hs.rresp, s_host_rvalid => hs.rvalid, s_host_rready => hm.rready,
             m_seam_awaddr => s_awaddr, m_seam_awvalid => s_awvalid, m_seam_awready => s_awready,
             m_seam_wdata => s_wdata, m_seam_wstrb => s_wstrb, m_seam_wvalid => s_wvalid, m_seam_wready => s_wready,
             m_seam_bresp => s_bresp, m_seam_bvalid => s_bvalid, m_seam_bready => s_bready,
             m_seam_araddr => s_araddr, m_seam_arvalid => s_arvalid, m_seam_arready => s_arready,
             m_seam_rdata => s_rdata, m_seam_rresp => s_rresp, m_seam_rvalid => s_rvalid, m_seam_rready => s_rready,
             host_refused => refused,
             m_hbm_araddr => open, m_hbm_arlen => open, m_hbm_arsize => open, m_hbm_arburst => open,
             m_hbm_arvalid => open, m_hbm_arready => '0', m_hbm_rdata => (others => '0'), m_hbm_rresp => "00",
             m_hbm_rlast => '0', m_hbm_rvalid => '0', m_hbm_rready => open,
             ltx_tdata => open, ltx_tkeep => open, ltx_tlast => open, ltx_tvalid => ltx_v, ltx_tready => '1',
             lrx_tdata => (others => '0'), lrx_tlast => '0', lrx_tvalid => '0',
             lnk_tx_up => '1', lnk_rx_up => '1', lnk_gtg_lock => '1', lnk_pll_lock => '1', lnk_rx_ovf => '0',
             link_ctrl => open);

  seam : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => srst, awaddr => s_awaddr, awvalid => s_awvalid, awready => s_awready,
             wdata => s_wdata, wvalid => s_wvalid, wready => s_wready, bresp => s_bresp,
             bvalid => s_bvalid, bready => s_bready, araddr => s_araddr, arvalid => s_arvalid,
             arready => s_arready, rdata => s_rdata, rresp => s_rresp, rvalid => s_rvalid,
             rready => s_rready, wr_ev => wr_ev, wr_addr => wr_addr, wr_data => wr_data,
             maxpos => maxpos, f_err_pos => f_err_pos, f_hang_pos => f_hang_pos,
             f_slverr_off => f_slverr_off, f_tokpos_stuck => f_tokpos_stuck);

  count : process(clk)
  begin
    if rising_edge(clk) then
      if wr_ev = '1' and wr_addr = x"014" and wr_data = x"00000002" then seq_resets <= seq_resets + 1; end if;
      if refused = '1' then n_refused <= n_refused + 1; end if;
    end if;
  end process;

  host : process
    type ids_t is array (0 to NREF - 1) of natural;
    variable ref, got : ids_t := (others => 0);
    variable resp : std_logic_vector(1 downto 0);
    variable d, st, xexp : std_logic_vector(31 downto 0);
    variable row : row16_arr(0 to N - 1);
    variable e, c, acked, polls, sr0, j1 : natural := 0;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_tok_loop_faults: " & msg severity error; end if;
    end procedure;
    procedure wr(a : natural; x : std_logic_vector(31 downto 0)) is
    begin
      axil_wr(clk, cm, cs, a, x, resp); chk(resp = "00", "control write OKAY");
    end procedure;
    procedure rd(a : natural; x : out std_logic_vector(31 downto 0)) is
    begin
      axil_rd(clk, cm, cs, a, x, resp);
    end procedure;
    procedure tick(n : natural) is
    begin
      for k in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;
    procedure reset_seam is
    begin
      seam_rst <= '1'; tick(3); seam_rst <= '0'; tick(3);
    end procedure;
    procedure setup(max_new : natural; role, src : natural) is
    begin
      wr(TL_PROMPT_LEN, u32(3)); wr(TL_MAX_NEW, u32(max_new));
      wr(TL_ROLE, u32(role)); wr(TL_ROW_SRC, u32(src));
      wr(TL_PROMPT_ADDR, u32(0));
      wr(TL_PROMPT_DATA, u32(1)); wr(TL_PROMPT_DATA, u32(2)); wr(TL_PROMPT_DATA, u32(3));
      acked := 0; got := (others => 0);
    end procedure;
    procedure serve_row is
    begin
      rd(TL_ROW_TOK, d); synth_row(to_integer(unsigned(d)), row, xexp);
      wr(TL_ROW_EXP, xexp); wr(TL_ROW_ADDR, u32(0));
      for j in 0 to N - 1 loop wr(TL_ROW_DATA, x"0000" & row(j)); end loop;
      wr(TL_CTRL, u32(8));
    end procedure;
    procedure drain is                       -- read new ids out of the 4-deep ring, then ack them
      variable n : natural;
    begin
      rd(TL_OUT_COUNT, d); n := to_integer(unsigned(d));
      while acked < n loop
        wr(TL_OUT_ADDR, u32(acked)); rd(TL_OUT_DATA, d);
        if acked < NREF then got(acked) := to_integer(unsigned(d)); end if;
        acked := acked + 1;
      end loop;
      wr(TL_OUT_ACK, u32(acked));
    end procedure;
    -- one pass of the host loop; mode 0 serve+drain, 1 serve only, 2 ABORT on NEED_ROW
    procedure step(mode : natural) is
    begin
      rd(TL_STATUS, st);
      if st(1 downto 0) /= "10" then
        if st(2) = '1' then
          if mode = 2 then wr(TL_CTRL, u32(2)); else serve_row; end if;
        end if;
        if mode = 0 then drain; end if;
      end if;
      polls := polls + 1;
      assert polls < 2000000 report "tb_tok_loop_faults: a case never stopped" severity failure;
    end procedure;
    procedure finish_run(mode : natural) is
    begin
      polls := 0;
      loop
        step(mode);
        exit when st(1 downto 0) = "10";
      end loop;
      if mode = 0 then drain; end if;
    end procedure;
    procedure expect(r : natural; tag : string) is
    begin
      rd(TL_STATUS, st);
      chk(st(1 downto 0) = "10", tag & ": stopped");
      chk(to_integer(unsigned(st(15 downto 8))) = r, tag & ": reason " & integer'image(r) &
          " (got " & integer'image(to_integer(unsigned(st(15 downto 8)))) & ")");
      chk(st(16) = '0', tag & ": seam released");
      axil_rd(clk, hm, hs, 16#8C#, d, resp);
      chk(resp = "00", tag & ": host seam access works after the stop");
    end procedure;
    procedure expect_ref(n : natural; tag : string) is
    begin
      rd(TL_N_GEN, d); chk(to_integer(unsigned(d)) = n, tag & ": N_GEN");
      for j in 0 to n - 1 loop chk(got(j) = ref(j), tag & ": id " & integer'image(j) & " equals F0's"); end loop;
    end procedure;
  begin
    tick(5); rst <= '0'; tick(5); seam_rst <= '0'; tick(2);
    -- F0: the reference
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_MAX_NEW, "F0");
    ref := got;
    rd(TL_N_GEN, d); chk(to_integer(unsigned(d)) = NREF, "F0: N_GEN");
    -- F1: ENGINE_ERR at position 2
    f_err_pos <= 2; setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_ENGINE_ERR, "F1");
    rd(TL_POS, d); chk(unsigned(d) = 2, "F1: POS latches the failing position");
    rd(TL_ERR_STATUS, d); chk(d(2) = '1', "F1: ERR_STATUS holds the seam's err bit");
    f_err_pos <= -1; reset_seam;
    -- F2: ENGINE_TIMEOUT at position 1
    f_hang_pos <= 1; wr(TL_TMO_ENGINE, u32(3000));
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_ENGINE_TIMEOUT, "F2");
    rd(TL_POS, d); chk(unsigned(d) = 1, "F2: POS");
    f_hang_pos <= -1; wr(TL_TMO_ENGINE, u32(TMO_DEFAULT)); reset_seam;
    -- F3: SEAM_ERR on N_STEP
    f_slverr_off <= 16#24#; setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_SEAM_ERR, "F3");
    rd(TL_ERR_ADDR, d); chk(unsigned(d) = 16#24#, "F3: ERR_ADDR names N_STEP");
    f_slverr_off <= -1; reset_seam;
    -- F4: ABORT while NEED_ROW
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(2);
    expect(R_ABORT, "F4");
    -- F5: ABORT while OUT_FULL
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(1); exit when st(7) = '1' or st(1 downto 0) = "10"; end loop;
    chk(st(7) = '1', "F5: OUT_FULL raised with nothing acked");
    wr(TL_CTRL, u32(2)); finish_run(1);
    expect(R_ABORT, "F5");
    rd(TL_N_GEN, d); chk(unsigned(d) = 4, "F5: N_GEN stopped at OUT_DEPTH");
    -- F6: the host touches the seam mid-run: refused, the loop is undisturbed
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(0); rd(TL_POS, d); exit when unsigned(d) >= 1; end loop;
    axil_rd(clk, hm, hs, 16#8C#, d, resp); chk(resp = "10", "F6: host read mid-run gets SLVERR");
    axil_wr(clk, hm, hs, 16#20#, x"00000005", resp); chk(resp = "10", "F6: host write mid-run gets SLVERR");
    finish_run(0); expect(R_MAX_NEW, "F6"); expect_ref(NREF, "F6");
    chk(n_refused >= 2, "F6: both host accesses were counted as refused");
    -- F7: SEQ_RESET does not take
    f_tokpos_stuck <= '1'; setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_SEQ_RESET_FAIL, "F7");
    f_tokpos_stuck <= '0'; reset_seam;
    -- F8: BAD_CONFIG
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_PROMPT_LEN, u32(0)); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_BAD_CONFIG, "F8a prompt_len 0");
    setup(NREF, ROLE_SINGLE, SRC_LINK); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_BAD_CONFIG, "F8b link rows on a single die");
    -- F9: LINK_TIMEOUT (role B, nothing arrives)
    wr(TL_TMO_LINK, u32(5000)); setup(NREF, ROLE_B, SRC_LINK); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_LINK_TIMEOUT, "F9");
    rd(TL_POS, d); chk(unsigned(d) = 0, "F9: timed out waiting for position 0");
    wr(TL_TMO_LINK, u32(TMO_DEFAULT));
    -- F10: KV_MAXPOS 4 ends the run cleanly (plan D9)
    maxpos <= 4; reset_seam;
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_MAXPOS, "F10"); expect_ref(2, "F10");
    rd(TL_KVMAX, d); chk(unsigned(d) = 4, "F10: KVMAX read at START");
    maxpos <= 16384; reset_seam;
    -- F11 (Review Focus 3): OUT never drained stalls, loses nothing, resumes on OUT_ACK
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(1); exit when st(7) = '1'; end loop;
    tick(3000);
    rd(TL_N_GEN, d); chk(unsigned(d) = 4, "F11: stalled at OUT_DEPTH ids");
    rd(TL_STATUS, st); chk(st(7) = '1' and st(1 downto 0) = "01", "F11: still running, OUT_FULL");
    finish_run(0); expect(R_MAX_NEW, "F11"); expect_ref(NREF, "F11");
    -- F12 (Review Focus 1): config written mid-run is not used until the next START
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(0); rd(TL_POS, d); exit when unsigned(d) >= 1; end loop;
    wr(TL_PROMPT_LEN, u32(1)); wr(TL_MAX_NEW, u32(2)); wr(TL_ROLE, u32(ROLE_A)); wr(TL_ROW_SRC, u32(SRC_GATHER));
    finish_run(0); expect(R_MAX_NEW, "F12"); expect_ref(NREF, "F12");
    -- F13 (Review Focus 2): START while running is ignored
    setup(NREF, ROLE_SINGLE, SRC_HOST); sr0 := seq_resets; wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(0); rd(TL_POS, d); exit when unsigned(d) >= 2; end loop;
    wr(TL_CTRL, u32(1));
    finish_run(0); expect(R_MAX_NEW, "F13"); expect_ref(NREF, "F13");
    chk(seq_resets = sr0 + 1, "F13: one SEQ_RESET for the run, none for the second START");
    -- F14 (Review Focus 5): a second START with no reconfiguration repeats the ids
    acked := 0; got := (others => 0); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_MAX_NEW, "F14"); expect_ref(NREF, "F14");
    -- F15: the last STOP_ID slot works (plan D8)
    j1 := 0;                                 -- the first id that has not occurred before it
    for j in 1 to NREF - 1 loop
      if j1 = 0 then
        j1 := j;
        for q in 0 to j - 1 loop
          if ref(q) = ref(j) then j1 := 0; end if;
        end loop;
      end if;
    end loop;
    chk(j1 > 0, "F15: F0 has an id that does not repeat an earlier one");
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_STOP_ID0 + 28, u32(ref(j1))); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_STOP_ID, "F15"); expect_ref(j1 + 1, "F15");
    wr(TL_STOP_ID0 + 28, x"FFFFFFFF");
    -- F16: role A sends frame p only when LINK_CREDIT >= p (plan D3)
    setup(1, ROLE_A, SRC_HOST); wr(TL_LINK_CREDIT, u32(0)); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(1); exit when st(17) = '1'; end loop;
    tick(3000);
    rd(TL_FRAMES_SENT, d); chk(unsigned(d) = 1, "F16: one frame sent, then waiting for credit");
    rd(TL_STATUS, st); chk(st(17) = '1', "F16: TX_WAIT_CREDIT shown");
    wr(TL_LINK_CREDIT, u32(1));
    polls := 0;
    loop step(1); rd(TL_FRAMES_SENT, d); exit when unsigned(d) = 2 and st(17) = '1'; end loop;
    wr(TL_LINK_CREDIT, u32(2));
    polls := 0;
    loop step(1); exit when st(3) = '1'; end loop;
    rd(TL_FRAMES_SENT, d); chk(unsigned(d) = 3, "F16: a frame for every prompt position");
    wr(TL_NEXT_TOKEN, u32(77)); finish_run(0);
    expect(R_MAX_NEW, "F16");
    chk(got(0) = 77, "F16: the relayed token is the generated id");
    if e = 0 then
      report "PASS: tb_tok_loop_faults checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_tok_loop_faults errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
```

F1 assumes the seam model's `f_err_pos` and `f_hang_pos` are positions as seen by GO (the seam's SEQ_POS at GO), as written in Task 2 Step 10. F10's expected count is DERIVED: positions 0..2 are the prompt, position 2's GO yields id 0, position 3's GO yields id 1, position 4 >= KV_MAXPOS 4 stops: N_GEN 2.

Run: `REGRESS_SCRATCH=~/regress_scratch/t6-d bash sim/regress.sh --only tb_tok_loop_faults --keep`
Expected: `OVERALL PASS 1`, `PASS: tb_tok_loop_faults checks=` with n >= 90.

- [ ] **Step 7: Write and run the mutants**

`sim/mutants/tok_loop_top.json`:

```json
{
  "tb": "tb_tok_loop_top",
  "deps": ["sim/axil_bfm_pkg.vhd", "rtl/tok_loop_pkg.vhd", "sim/tok_loop_tb_pkg.vhd",
           "rtl/tok_loop_regs.vhd", "rtl/tok_loop_axm.vhd", "rtl/tok_loop_fsm.vhd", "rtl/jc_seam_mux.vhd",
           "rtl/embed_gather.vhd", "rtl/jc_loader_pkg.vhd", "rtl/jc_link_pkg.vhd", "rtl/jc_link_tx.vhd",
           "rtl/jc_link_rx.vhd", "rtl/tok_loop.vhd", "sim/jc_axi3_mem.vhd", "sim/seam_beh_model.vhd",
           "sim/seam_trace_chk.vhd", "sim/tb_tok_loop_top.vhd"],
  "vectors": ["sim/tok_loop_vec.txt", "sim/embed_gather_k4096_vec.txt"],
  "stop_time": "4000ms",
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "K6", "expect": "KILLED", "file": "rtl/tok_loop.vhd",
     "why": "host row source ignores ROW_EXP",
     "old": "h_exp <= cfg.row_exp; h_ev <= '1';",
     "new": "h_exp <= (others => '0'); h_ev <= '1';"},
    {"tag": "K7", "expect": "KILLED", "file": "rtl/tok_loop.vhd",
     "why": "the gather is fed the wrong token (row-source plumbing)",
     "old": "req => g_req, tok => rs_tok,",
     "new": "req => g_req, tok => rs_tok + 1,"}
  ]
}
```

`sim/mutants/tok_loop_pair.json`:

```json
{
  "tb": "tb_tok_loop_pair",
  "deps": ["sim/axil_bfm_pkg.vhd", "rtl/tok_loop_pkg.vhd", "sim/tok_loop_tb_pkg.vhd",
           "rtl/tok_loop_regs.vhd", "rtl/tok_loop_axm.vhd", "rtl/tok_loop_fsm.vhd", "rtl/jc_seam_mux.vhd",
           "rtl/embed_gather.vhd", "rtl/jc_loader_pkg.vhd", "rtl/jc_link_pkg.vhd", "rtl/jc_link_tx.vhd",
           "rtl/jc_link_rx.vhd", "rtl/tok_loop.vhd", "rtl/util_pkg.vhd", "rtl/async_fifo.vhd",
           "rtl/jc_tok_top.vhd",
           "sim/jc_link_chan_model.vhd", "sim/seam_beh_model.vhd", "sim/seam_trace_chk.vhd",
           "sim/tb_tok_loop_pair.vhd"],
  "vectors": ["sim/tok_loop_vec.txt"],
  "stop_time": "8000ms",
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "K2", "expect": "KILLED", "file": "rtl/tok_loop.vhd",
     "why": "a paused link still counts toward LINK_TIMEOUT (spec 3: pause, not stop)",
     "old": "rs_paused <= (rx_bad or rx_down) when st.row_src = SRC_LINK else '0';",
     "new": "rs_paused <= '0';"},
    {"tag": "K3", "expect": "KILLED", "file": "rtl/tok_loop.vhd",
     "why": "link row source swaps the mantissa halves",
     "old": "if (k_idx mod 2) = 0 then k_md <= rx_rdata(15 downto 0); else k_md <= rx_rdata(31 downto 16); end if;",
     "new": "if (k_idx mod 2) = 1 then k_md <= rx_rdata(15 downto 0); else k_md <= rx_rdata(31 downto 16); end if;"},
    {"tag": "K4", "expect": "KILLED", "file": "rtl/tok_loop_fsm.vhd",
     "why": "an exhausted framer is not a stop while credit is missing",
     "old": "            if tx_exhausted = '1' then stop(R_LINK_RETRY_EXHAUSTED);\n            elsif abort_l = '1' then stop(R_ABORT);\n            elsif cfg.link_credit >= p",
     "new": "            if false then stop(R_LINK_RETRY_EXHAUSTED);\n            elsif abort_l = '1' then stop(R_ABORT);\n            elsif cfg.link_credit >= p"},
    {"tag": "K5", "expect": "KILLED", "file": "rtl/tok_loop.vhd",
     "why": "the link row source never pops: LINK_CONSUMED stays 0 and A starves",
     "old": "k_ev <= '0'; rx_pop <= '1'; ks <= K_IDLE;",
     "new": "k_ev <= '0'; ks <= K_IDLE;"}
  ]
}
```

`sim/mutants/tok_loop_faults.json`:

```json
{
  "tb": "tb_tok_loop_faults",
  "deps": ["sim/axil_bfm_pkg.vhd", "rtl/tok_loop_pkg.vhd", "sim/tok_loop_tb_pkg.vhd",
           "rtl/tok_loop_regs.vhd", "rtl/tok_loop_axm.vhd", "rtl/tok_loop_fsm.vhd", "rtl/jc_seam_mux.vhd",
           "rtl/embed_gather.vhd", "rtl/jc_loader_pkg.vhd", "rtl/jc_link_pkg.vhd", "rtl/jc_link_tx.vhd",
           "rtl/jc_link_rx.vhd", "rtl/tok_loop.vhd", "sim/seam_beh_model.vhd", "sim/tb_tok_loop_faults.vhd"],
  "stop_time": "2000ms",
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "K1", "expect": "KILLED", "file": "rtl/tok_loop_fsm.vhd",
     "why": "credit gate removed (plan D3): A overwrites a frame B has not consumed",
     "old": "elsif cfg.link_credit >= p then",
     "new": "elsif true then"},
    {"tag": "K8", "expect": "KILLED", "file": "rtl/tok_loop_fsm.vhd",
     "why": "ROLE latched live instead of at START (Review Focus 1)",
     "old": "if role_l = ROLE_A then fs <= F_XW; else fs <= F_GEN; end if;",
     "new": "if cfg.role = ROLE_A then fs <= F_XW; else fs <= F_GEN; end if;"},
    {"tag": "K9", "expect": "KILLED", "file": "rtl/tok_loop_fsm.vhd",
     "why": "OUT_FULL ignored: ids overwrite unread ring slots (Review Focus 3)",
     "old": "            if n_gen - cfg.out_ack >= OUT_DEPTH then\n              if abort_l",
     "new": "            if false then\n              if abort_l"}
  ]
}
```

K4's anchor is the three-line head of `F_XW` (the same `if tx_exhausted` line also opens other states, so the anchor includes the `link_credit` line to occur once). K9's anchor likewise includes the next line.

Run:
```bash
python3 sim/mutate_rows.py sim/mutants/tok_loop_top.json
python3 sim/mutate_rows.py sim/mutants/tok_loop_pair.json
python3 sim/mutate_rows.py sim/mutants/tok_loop_faults.json
```
Expected: `MUTANTS_OK 3`, `MUTANTS_OK 5`, `MUTANTS_OK 4`. A SURVIVED row is reported under its tag with the bench that should have killed it; do not delete the row.

- [ ] **Step 8: Re-run the earlier gate rows and commit**

Run: `REGRESS_SCRATCH=~/regress_scratch/t6-e bash sim/regress.sh --only tok_loop --keep`
Expected: `OVERALL PASS 4` (`tb_tok_loop`, `tb_tok_loop_top`, `tb_tok_loop_pair`, `tb_tok_loop_faults`).

```bash
git add rtl/tok_loop.vhd rtl/jc_tok_top.vhd sim/tb_tok_loop_top.vhd sim/tb_tok_loop_pair.vhd \
  sim/tb_tok_loop_faults.vhd sim/mutants/tok_loop_top.json sim/mutants/tok_loop_pair.json \
  sim/mutants/tok_loop_faults.json tools/jc/gen_tok_loop_vec.py sim/tok_loop_vec.txt \
  sim/tok_loop_tb_pkg.vhd sim/tb_tok_loop.vhd
git commit -m "jc loop T6: tok_loop with gather/host/link row sources, card top with CDC, single/pair/fault benches" -- \
  rtl/tok_loop.vhd rtl/jc_tok_top.vhd sim/tb_tok_loop_top.vhd sim/tb_tok_loop_pair.vhd \
  sim/tb_tok_loop_faults.vhd sim/mutants/tok_loop_top.json sim/mutants/tok_loop_pair.json \
  sim/mutants/tok_loop_faults.json tools/jc/gen_tok_loop_vec.py sim/tok_loop_vec.txt \
  sim/tok_loop_tb_pkg.vhd sim/tb_tok_loop.vhd
```

---
### Task 7: Card integration, host tool, loop model in the fake broker, card build command

**Files:**
- Modify: `hw/jc/card/gen_jc_card.py`, `hw/jc/card/test_gen_jc_card.py`, `hw/jc/card/build_card.tcl`, `hw/jc/card/jccard_const_allow.tcl` (only if the build names new constant bits), generated `hw/jc/card/jc_card_bd.tcl`, `jc_card.xdc`, `jc_card_top.vhd`, `server/tests/jc_sim_broker.c`, `server/Makefile`, `hw/jc/host/jc_ctxtest.sh` (`hw/jc/link/aurora_cfg.tcl` and `gen_aurora_ip.tcl` already carry the shared refclk/readback procs from Task 5 Step 3, finding 18; Step 1 here only confirms it)
- Create: `hw/jc/link/jc_link_timing.tcl`, `server/tests/jc_sim_loop.c`, `server/tests/jc_sim_loop.h`, `tools/jc/jc_loop.py`, `tools/jc/test_jc_loop.py`

**Interfaces:**
- Consumes (grounded): `gen_jc_card.py` sections `jtag_hbm_lines` (hbm_sc `NUM_SI {2}`, `:371`), `ctl_lines` (the ASSOCIATED_BUSIF pattern, `:387-428`), `render_tcl` order (`:645-664`: `P._seam_block` emitted after `eng_lines`), the seam block's connect (`jc_card_bd.tcl:466-469`: `NUM_MI + 1`, `axil2eng/M<n>_AXI` to `fk33_seam_0/s_axi`), `addr_lines` (`:571-602`: SEAM_BASE 0xE000 4K in `ctl/m_axil`; the 32-segment loop; the segment-count check `ctl/m_axil 3`), `check_lines` (`N_MODULE_REFS`, `:612`), `stamp_inputs` (`:123-125`), `render_top` (`:690-725`), `test_top_ports_match_xdc` (`test_gen_jc_card.py:330-339`); gen_pcieep's `UNCONNECTED_PIN_CHECK` (`hw/fk33/gen_pcieep.py:2968`: an unconnected module-reference input fails the BD; an IP input does NOT, so every Aurora input is tied explicitly); `build_card.tcl` `EXPECT_CELLS` (`:272`), `opt_design` (`:427-431`), timing sources (`:348-349`), `write_bitstream` (`:518`); `run_card.sh` (MemoryHigh 24G, 30 GiB swap guard, nonce sentinel); bank 126 refclk1 pin AC36 (`hw/jc/census/jc_qpll_census.xdc:11`, `refclk_p[5]`; `docs/debugging/2026-11-03_jc-gty-slr1-unpowered-qpll-control.md:107-116`); broker JSON ops and `--jc` run_prompt options (`server/tests/run_prompt.c:407-436`, `--open-only` `:434`); `jc_ctxtest.sh` `rp_cmd` and the `timing N GOs` check (`hw/jc/host/jc_ctxtest.sh:188-221`).
- Produces: BD cells `tok` (module `jc_tok_top`), `gtgclk` (module `jc_gtg_clk`), `aur` (IP), tie cells `tie_<port>`; ctl map `tok/s_host` at 0xE000 (4K; the seam is behind it), `tok/s_ctl` at 0x00020000 (64K); `tok/m_seam` space: `fk33_seam_0/s_axi` at 0; `tok/m_hbm` space: the 32 HBM segments through `hbm_sc/S02_AXI`; top ports `gt_tx_txp/n(0:0)`, `gt_rx_rxp/n(0:0)`, `gt_refclk_clk_p/n`; GENSTAMP inputs `JC_LINK_RATE` (10.3125 | 1.25) and `JC_LINK_REFCLK` (gtg | pin). `jc_sim_broker --loop` (every die gets a C model of `tok_loop` at 0x20000; `--loop-pair A,B`; `--loop-drop N`). `tools/jc/jc_loop.py` sentinels `^JCLOOP_DONE`, `^JCLOOP_FAIL`, and a `timing <n> GOs` line in run_prompt's format.

- [ ] **Step 1: Confirm the Aurora refclk choice and readback are already shared (finding 18)**

`jc_aurora_refclk`/`jc_aurora_check` were added to `hw/jc/link/aurora_cfg.tcl` in Task 5 Step 3,
and `gen_aurora_ip.tcl` has called them (not an inline duplicate) since that same step: there is
nothing to extract here, and no IP regeneration this step needs to force. Confirm:

```bash
grep -c '^proc jc_aurora_refclk' hw/jc/link/aurora_cfg.tcl
grep -c '^proc jc_aurora_check' hw/jc/link/aurora_cfg.tcl
grep -c 'AURORA_CFG_FAIL refclk:' hw/jc/link/gen_aurora_ip.tcl
```

Expected: `1`, `1`, `0` (the refclk-pick error text lives only inside the `aurora_cfg.tcl` proc,
not inline in `gen_aurora_ip.tcl`). If any of these fail, Task 5 Step 3 was not applied as
amended; fix it there, not here.

Re-run Task 5 Step 3's `l1card` line alone and confirm `AURORA_IP_OK` and the same `AURORA_CFG` lines as recorded in `hw/jc/link/README.md`.

- [ ] **Step 2: Write the failing generator tests**

Append to `hw/jc/card/test_gen_jc_card.py`:

```python
# ---- the token loop and the link (plan 2026-11-04 Task 7) -------------------------------
def test_link_cells(tcl):
    for kind, ref, cell in (("module -reference", G.TOK_MODULE, G.TOK_CELL),
                            ("module -reference", G.GTG_MODULE, G.GTG_CELL),
                            ("ip -vlnv", G.AUR_VLNV, G.AUR_CELL)):
        n = len(re.findall(r"^create_bd_cell -type %s %s %s$" % (kind, re.escape(ref), cell), tcl, re.M))
        assert n == 1, (ref, cell, n)


def test_seam_sits_behind_the_loop(tcl):
    nets = _intf_nets(tcl)
    flat = [set(n) for n in nets]
    assert {"%s/m_seam" % G.TOK_CELL, "%s/s_axi" % P.SEAM_CELL} in flat
    assert not any("%s/s_axi" % P.SEAM_CELL in n and any(e.startswith("axil2eng/") for e in n) for n in flat)
    assert re.search(r"\[get_bd_intf_pins %s/s_host\]" % G.TOK_CELL, tcl)


def test_loop_ctl_and_hbm_ports(tcl):
    flat = [set(n) for n in _intf_nets(tcl)]
    assert {"%s/m_hbm" % G.TOK_CELL, "%s/S02_AXI" % G.HBM_SC_CELL} in flat
    assert any("%s/s_ctl" % G.TOK_CELL in n and any(e.startswith("axil2eng/M") for e in n) for n in flat)
    assert re.search(r"CONFIG\.NUM_SI \{3\} CONFIG\.NUM_MI \{1\} CONFIG\.NUM_CLKS \{1\}\] \[get_bd_cells %s\]"
                     % G.HBM_SC_CELL, tcl)
    assert {"%s/m_axis_tx" % G.TOK_CELL, "%s/USER_DATA_S_AXIS_TX" % G.AUR_CELL} in flat
    assert {"%s/USER_DATA_M_AXIS_RX" % G.AUR_CELL, "%s/s_axis_rx" % G.TOK_CELL} in flat


def test_loop_address_map(tcl):
    assert re.search(r"assign_bd_address -offset 0x0000E000 -range 4K .*\{%s/s_host/reg0\}" % G.TOK_CELL, tcl)
    assert re.search(r"assign_bd_address -offset 0x00020000 -range 64K .*\{%s/s_ctl/reg0\}" % G.TOK_CELL, tcl)
    assert re.search(r"get_bd_addr_spaces %s/m_seam\] \[get_bd_addr_segs \{%s/s_axi/reg0\}\]"
                     % (G.TOK_CELL, P.SEAM_CELL), tcl)
    assert "%s/m_hbm 16" % G.TOK_CELL in tcl
    for sp, n in (("%s/%s" % (G.CTL_CELL, G.CTL_AXIL_INTF), 4), ("%s/m_hbm" % G.TOK_CELL, 32),
                  ("%s/m_seam" % G.TOK_CELL, 1)):
        assert "%s %d" % (sp, n) in tcl, (sp, n)


def test_every_aurora_input_is_driven(tcl):
    import aurora_ties as T
    flat = _nets(tcl)
    for name, d, w in G.aurora_core_ports():
        if d != "in" or name in T.MAPPED:
            continue
        v = T.tie_value(name, w or 1, G.LINK_NLANES)
        assert v is not None, name
        cell = "tie_%s" % name
        m = re.search(r"CONFIG.CONST_WIDTH \{%d\} CONFIG.CONST_VAL \{0x([0-9A-F]+)\}\] \[get_bd_cells %s\]"
                      % (w or 1, cell), tcl)
        assert m and int(m.group(1), 16) == int(v, 2), (name, v)
        assert "%s/%s" % (G.AUR_CELL, name) in _net_of(flat, "%s/dout" % cell), name


def test_diffctrl_is_the_measured_swing(tcl):
    m = re.search(r"CONFIG.CONST_VAL \{0x([0-9A-F]+)\}\] \[get_bd_cells tie_gt_txdiffctrl\]", tcl)
    assert m and int(m.group(1), 16) == 0b11000


def test_module_ref_count_includes_link(tcl):
    assert "if {$_nmr != %d}" % G.N_MODULE_REFS in tcl and G.N_MODULE_REFS == 8


def test_link_stamp_and_refusals(monkeypatch):
    assert G.link_refclk({}) == "gtg" and G.link_rate({}) == "10.3125"
    for bad in ({"JC_LINK_REFCLK": "mmcm"}, {"JC_LINK_RATE": "5.0"}):
        with pytest.raises(SystemExit):
            G.link_refclk(bad); G.link_rate(bad)
    names = {n for _, n, _ in G.stamp_inputs({})}
    assert {"JC_LINK_REFCLK", "JC_LINK_RATE"} <= names


def test_gt_ports_in_top_and_refclk_pin():
    top = _strip_vhdl_comments(_read(TOP))
    for n, d, w in G.GT_TOP_PORTS:
        want = r"%s\s*:\s*%s\s+std_logic%s" % (n, d, r"_vector\(0 downto 0\)" if w else r"\b")
        assert re.search(want, top), n
    xdc = _read(XDC)
    assert re.search(r"^set_property PACKAGE_PIN AC36 \[get_ports gt_refclk_clk_p\]$", xdc, re.M)
    assert re.search(r"^create_clock -name gt_refclk -period 6.400 \[get_ports gt_refclk_clk_p\]$", xdc, re.M)


def test_gtg_mmcm_has_a_site_and_a_dedicated_route():
    """finding 3: no MMCM LOC or CLOCK_DEDICATED_ROUTE BACKBONE left the GTG refclk's MMCM to
    place_design's own choice, which IBERT G needed a fixed site and route to avoid."""
    xdc = _read(XDC)
    assert re.search(r"^set_property LOC MMCM_X0Y2 \[get_cells -hier -filter "
                      r"\{NAME =~ \*gtgclk/u_mmcm\}\]$", xdc, re.M)
    assert re.search(r"^set_property CLOCK_DEDICATED_ROUTE BACKBONE \[get_pins -hier -filter "
                      r"\{NAME =~ \*gtgclk/u_mmcm/CLKIN1\}\]$", xdc, re.M)
```

and change `test_top_ports_match_xdc`'s last line to exclude the GT pins the GT site places:

```python
    gt_free = {n for n, _, _ in G.GT_TOP_PORTS if n != "gt_refclk_clk_p"}
    assert ports - gt_free == xp, (ports, xp)
```

Add `sys.path.insert(0, os.path.join(REPO, "hw", "jc", "link"))` next to the file's other path setup so `aurora_ties` imports.

Run: `python3 -m pytest -q hw/jc/card/test_gen_jc_card.py -k "link or loop or aurora or diffctrl or gt_ports or module_ref"`
Expected: FAIL (`G.TOK_MODULE` missing).

- [ ] **Step 3: Implement the generator changes**

In `hw/jc/card/gen_jc_card.py`:

(a) After `N_MODULE_REFS = 6 ...` replace that line with `N_MODULE_REFS = 8     # loader, ctl, eng, fk33_seam_0, card, bcgrant, tok, gtgclk` and add:

```python
# ==== the token loop and the die-to-die link (plan 2026-11-04 Task 7) ===================
TOK_MODULE, TOK_CELL = "jc_tok_top", "tok"
GTG_MODULE, GTG_CELL = "jc_gtg_clk", "gtgclk"
AUR_VLNV, AUR_CELL = "xilinx.com:ip:aurora_64b66b:12.0", "aur"
TOK_CTL_BASE = 0x00020000
LINK_NLANES = 1                                   # spec 1b.2: first build, GTYE4_CHANNEL_X0Y0
LINK_RATE_ENV, LINK_REFCLK_ENV = "JC_LINK_RATE", "JC_LINK_REFCLK"
AUR_WRAP = os.path.join(REPO, "hw", "jc", "link", "rtl", "jc_aurora_wrap_l1.vhd")
GT_TOP_PORTS = [("gt_tx_txp", "out", 1), ("gt_tx_txn", "out", 1),
                ("gt_rx_rxp", "in", 1), ("gt_rx_rxn", "in", 1),
                ("gt_refclk_clk_p", "in", None), ("gt_refclk_clk_n", "in", None)]
REFCLK_PIN = "AC36"     # MGTREFCLK1 of bank 126: hw/jc/census/jc_qpll_census.xdc:11
sys.path.insert(0, os.path.join(REPO, "hw", "jc", "link"))
import aurora_ties  # noqa: E402


def link_rate(env=None):
    env = os.environ if env is None else env
    v = env.get(LINK_RATE_ENV) or "10.3125"
    if v not in ("10.3125", "1.25"):
        sys.exit("ABORT: %s=%s; the built rates are 10.3125 and 1.25 (spec 1b.2)" % (LINK_RATE_ENV, v))
    return v


def link_refclk(env=None):
    env = os.environ if env is None else env
    v = env.get(LINK_REFCLK_ENV) or "gtg"
    if v not in ("gtg", "pin"):
        sys.exit("ABORT: %s=%s; gtg (the MMCM on GTGREFCLK0, the ECO) or pin (AC36)" % (LINK_REFCLK_ENV, v))
    return v


def aurora_core_ports():
    """[(name, dir, width or None)] of the Aurora core, from the committed wrapper's component
    (generated from the IP's own stub by hw/jc/link/gen_aurora_wrap.py)."""
    t = open(AUR_WRAP).read()
    comp = t[t.index("component jc_aurora"):t.index("end component")]
    out = []
    for m in re.finditer(r"^\s*(\w+)\s*:\s*(in|out)\s+std_logic(?:_vector\((\d+) (?:downto|to) (\d+)\))?", comp, re.M):
        w = None if m.group(3) is None else abs(int(m.group(3)) - int(m.group(4))) + 1
        out.append((m.group(1), m.group(2), w))
    if not out:
        sys.exit("ABORT: no ports parsed from %s" % AUR_WRAP)
    return out


def link_lines():
    """tok, gtgclk, aur and the ties. Emitted BEFORE the seam block, which then connects
    axil2eng's new MI to tok/s_host instead of fk33_seam_0/s_axi (render_tcl)."""
    rate, T = link_rate(), aurora_ties
    L = [
        "",
        "# ---- the token loop (jc_tok_top) and the die-to-die link (plan 2026-11-04) ---------",
        "create_bd_cell -type module -reference %s %s" % (TOK_MODULE, TOK_CELL),
        "set_property -dict [list CONFIG.N_EMBD {5120} CONFIG.NLANES {%d} CONFIG.HAS_GATHER {true} "
        "CONFIG.TXPOL_MASK {0}] [get_bd_cells %s]" % (LINK_NLANES, TOK_CELL),
        "foreach i {s_host m_seam s_ctl m_hbm m_axis_tx s_axis_rx} {",
        "  if {[llength [get_bd_intf_pins -quiet %s/$i]] != 1} {" % TOK_CELL,
        "    error \"JCCARD_BD FAIL: no inferred interface %s/$i\"" % TOK_CELL,
        "  }",
        "}",
    ]
    for clk, intfs in (("aclk", "s_host:m_seam:s_ctl:m_hbm"), ("user_clk", "m_axis_tx:s_axis_rx")):
        L += [
            "set _ab [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins %s/%s]]" % (TOK_CELL, clk),
            "if {$_ab ne \"%s\"} { set_property CONFIG.ASSOCIATED_BUSIF {%s} [get_bd_pins %s/%s] }"
            % (intfs, intfs, TOK_CELL, clk),
            "puts \"JCCARD_BD %s/%s ASSOCIATED_BUSIF [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins %s/%s]]\""
            % (TOK_CELL, clk, TOK_CELL, clk),
        ]
    L += [
        _c(CORE_CLK, "%s/aclk" % TOK_CELL),
        "if {[get_property TYPE [get_bd_pins %s/arst]] eq \"rst\"} {" % TOK_CELL,
        "  set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_pins %s/arst]" % TOK_CELL,
        "}",
        _c(CORE_RST, "%s/arst" % TOK_CELL),
        "connect_bd_intf_net [get_bd_intf_pins %s/m_hbm] [get_bd_intf_pins %s/S02_AXI]" % (TOK_CELL, HBM_SC_CELL),
        "create_bd_cell -type module -reference %s %s" % (GTG_MODULE, GTG_CELL),
        _c("sysclk_buf/IBUF_OUT", "%s/sys_i" % GTG_CELL),
        "source [file join $repo hw jc link aurora_cfg.tcl]",
        "create_bd_cell -type ip -vlnv %s %s" % (AUR_VLNV, AUR_CELL),
        "set _acfg [jc_aurora_config %d %s card]" % (LINK_NLANES, rate),
        "set_property -dict $_acfg [get_bd_cells %s]" % AUR_CELL,
        "lappend _acfg CONFIG.C_REFCLK_SOURCE [jc_aurora_refclk [get_bd_cells %s]]" % AUR_CELL,
        "set_property -dict $_acfg [get_bd_cells %s]" % AUR_CELL,
        "jc_aurora_check [get_bd_cells %s] $_acfg" % AUR_CELL,
        "make_bd_intf_pins_external [get_bd_intf_pins %s/GT_DIFF_REFCLK1]" % AUR_CELL,
        "set_property name gt_refclk [get_bd_intf_ports GT_DIFF_REFCLK1_0]",
        "set_property CONFIG.FREQ_HZ 156250000 [get_bd_intf_ports gt_refclk]",
        "make_bd_intf_pins_external [get_bd_intf_pins %s/GT_SERIAL_TX]" % AUR_CELL,
        "set_property name gt_tx [get_bd_intf_ports GT_SERIAL_TX_0]",
        "make_bd_intf_pins_external [get_bd_intf_pins %s/GT_SERIAL_RX]" % AUR_CELL,
        "set_property name gt_rx [get_bd_intf_ports GT_SERIAL_RX_0]",
        "foreach p {%s} {" % " ".join(n for n, _, _ in GT_TOP_PORTS),
        "  if {[llength [get_bd_ports -quiet $p]] != 1} { error \"JCCARD_BD FAIL: no BD port $p (GT port naming)\" }",
        "}",
        "connect_bd_intf_net [get_bd_intf_pins %s/m_axis_tx] [get_bd_intf_pins %s/USER_DATA_S_AXIS_TX]" % (TOK_CELL, AUR_CELL),
        "connect_bd_intf_net [get_bd_intf_pins %s/USER_DATA_M_AXIS_RX] [get_bd_intf_pins %s/s_axis_rx]" % (AUR_CELL, TOK_CELL),
        _c("%s/sclk" % GTG_CELL, "%s/init_clk" % AUR_CELL),
        _c("%s/sclk" % GTG_CELL, "%s/init_clk" % TOK_CELL),
        _c("%s/user_clk_out" % AUR_CELL, "%s/user_clk" % TOK_CELL),
        _c("%s/tx_channel_up" % AUR_CELL, "%s/tx_channel_up" % TOK_CELL),
        _c("%s/rx_channel_up" % AUR_CELL, "%s/rx_channel_up" % TOK_CELL),
        _c("%s/gt_pll_lock" % AUR_CELL, "%s/gt_pll_lock" % TOK_CELL),
        _c("%s/locked" % GTG_CELL, "%s/gtg_locked" % TOK_CELL),
        _c("%s/aur_reset_pb" % TOK_CELL, "%s/reset_pb" % AUR_CELL),
        _c("%s/aur_pma_init" % TOK_CELL, "%s/pma_init" % AUR_CELL),
        _c("%s/aur_tx_polarity" % TOK_CELL, "%s/gt_txpolarity" % AUR_CELL),
        "# Every other Aurora input, tied from hw/jc/link/aurora_ties.py.  An IP input left",
        "# open takes component.xml's default, 0 for all of these, and validate_bd_design does",
        "# not warn: gt_txdiffctrl = 0 is the minimum TX swing (Task 5 trap).",
    ]
    axis = {"s_axi_tx_tdata", "s_axi_tx_tkeep", "s_axi_tx_tlast", "s_axi_tx_tvalid",
            "gt_refclk1_p", "gt_refclk1_n", "rxp", "rxn"}
    for name, d, w in aurora_core_ports():
        if d != "in" or name in T.MAPPED or name in axis:
            continue
        v = T.tie_value(name, w or 1, LINK_NLANES)
        if v is None:
            sys.exit("ABORT: Aurora input %s is not in hw/jc/link/aurora_ties.py" % name)
        cell = "tie_%s" % name
        L += [
            "create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 %s" % cell,
            "set_property -dict [list CONFIG.CONST_WIDTH {%d} CONFIG.CONST_VAL {0x%X}] [get_bd_cells %s]"
            % (w or 1, int(v, 2), cell),
            _c("%s/dout" % cell, "%s/%s" % (AUR_CELL, name)),
        ]
    return L


def link_ctl_lines(P):
    """After the seam block: tok/m_seam -> the seam, and one more axil2eng MI for tok/s_ctl."""
    return [
        "connect_bd_intf_net [get_bd_intf_pins %s/m_seam] [get_bd_intf_pins %s/s_axi]" % (TOK_CELL, P.SEAM_CELL),
        "set n [get_property CONFIG.NUM_MI [get_bd_cells axil2eng]]",
        "set_property CONFIG.NUM_MI [expr {$n + 1}] [get_bd_cells axil2eng]",
        "connect_bd_intf_net [get_bd_intf_pins axil2eng/[format M%%02d_AXI $n]] [get_bd_intf_pins %s/s_ctl]" % TOK_CELL,
        "",
    ]
```

(b) In `stamp_inputs` return `[("env", CLK_CORE_ENV, env.get(CLK_CORE_ENV) or None), ("env", LINK_RATE_ENV, env.get(LINK_RATE_ENV) or None), ("env", LINK_REFCLK_ENV, env.get(LINK_REFCLK_ENV) or None)]`, and call `link_rate(env); link_refclk(env)` at its top so a bad value refuses before anything is written.

(c) In `jtag_hbm_lines`, `CONFIG.NUM_SI {2}` becomes `CONFIG.NUM_SI {3}` (S00 jtag_hbm, S01 ctl, S02 tok).

(d) In `render_tcl`, replace `body += P._seam_block(one_clock=True).split("\n")` with:

```python
    body += link_lines()
    seam = P._seam_block(one_clock=True)
    hook = "                    [get_bd_intf_pins %s/s_axi]" % P.SEAM_CELL
    if seam.count(hook) != 1:
        sys.exit("ABORT: gen_pcieep's seam block no longer connects axil2eng to %s/s_axi in the "
                 "shape gen_jc_card.py rewires (found %d)" % (P.SEAM_CELL, seam.count(hook)))
    body += seam.replace(hook, "                    [get_bd_intf_pins %s/s_host]" % TOK_CELL).split("\n")
    body += link_ctl_lines(P)
```

(e) In `addr_lines`: the seam entry of the 4K loop becomes `(P.SEAM_BASE, "%s/s_host/reg0" % TOK_CELL)`; after the loop append

```python
    L.append("assign_bd_address -offset 0x%08X -range 64K -target_address_space "
             "[get_bd_addr_spaces %s] [get_bd_addr_segs {%s/s_ctl/reg0}]" % (TOK_CTL_BASE, sp, TOK_CELL))
    L.append("assign_bd_address -offset 0x00000000 -range 4K -target_address_space "
             "[get_bd_addr_spaces %s/m_seam] [get_bd_addr_segs {%s/s_axi/reg0}]" % (TOK_CELL, P.SEAM_CELL))
```

the HBM `foreach {sp sx}` list gains `%s/m_hbm 16` (TOK_CELL), and the count check list becomes `{... %s/%s 32 %s 4 %s/m_hbm 32 %s/m_seam 1}` (ctl/m_axil 4: engine control, activation writer, tok/s_host, tok/s_ctl).

(f) In `render_xdc`, append after `code`:

```python
    code += [
        "# the Aurora refclk (plan 2026-11-04 Task 7): bank 126 MGTREFCLK1, the pin IBERT and the",
        "# census measured (hw/jc/census/jc_qpll_census.xdc:11). Used when JC_LINK_REFCLK=pin; with",
        "# gtg the ECO reselects the QPLL to GTGREFCLK0 and this pin only satisfies the IP's port.",
        "set_property PACKAGE_PIN %s [get_ports gt_refclk_clk_p]" % REFCLK_PIN,
        "create_clock -name gt_refclk -period 6.400 [get_ports gt_refclk_clk_p]",
        "# the GTG MMCM (hw/jc/link/rtl/jc_gtg_clk.vhd, instance %s/u_mmcm): IBERT G needed an" % GTG_CELL,
        "# explicit site and a dedicated route for the BUFG -> MMCM net (G/SUMMARY.md); without",
        "# both, place_design is free to miss the backbone and leave the clock unrouted (finding 3).",
        "set_property LOC MMCM_X0Y2 [get_cells -hier -filter {NAME =~ *%s/u_mmcm}]" % GTG_CELL,
        "set_property CLOCK_DEDICATED_ROUTE BACKBONE "
        "[get_pins -hier -filter {NAME =~ *%s/u_mmcm/CLKIN1}]" % GTG_CELL,
    ]
```

(g) In `render_top`, ports and component ports both gain the GT ports: after building `ports` from `TOP_PORTS`, extend with `["    %-*s : %-3s %s" % (w, n, d, "std_logic_vector(0 downto 0)" if wd else "std_logic") for n, d, wd in GT_TOP_PORTS]` (same for `cports` with 6 spaces) and `bmaps` with `["%s => %s" % (n, n) for n, _, _ in GT_TOP_PORTS]`; compute `w` over these names too.

Run: `python3 hw/jc/card/gen_jc_card.py && python3 hw/jc/card/gen_jc_card.py --check && python3 -m pytest -q hw/jc/card/`
Expected: `JCCARD_CHECK: PASS` and every test passes (the new ones and the existing ones, including `test_genstamp_present_and_clean` with the two new stamp inputs shown as `(unset)`).

- [ ] **Step 4: Write the link timing and the build hooks**

`hw/jc/link/jc_link_timing.tcl`:

```tcl
# hw/jc/link/jc_link_timing.tcl -- the CDC constraints of rtl/jc_tok_top.vhd (plan
# 2026-11-04 Task 7), in jc_ctl_timing.tcl's shape: every crossing bounded by name,
# every query must match (JCLINK_CONSTRAINT_EMPTY), no set_clock_groups (it would outrank
# the bounds), and an audit counts crossings nobody named.
# Crossings (prefix = the tok cell's hierarchy, e.g. "*tok/inst/"):
#   txf/wp_g -> txf/wp_g_s1 (aclk -> user_clk) and txf/rp_g -> txf/rp_g_s1 (user -> aclk)
#   rxf/wp_g -> rxf/wp_g_s1 (user -> aclk) and rxf/rp_g -> rxf/rp_g_s1 (aclk -> user)
#   s_tx/s_rx/s_pll/s_gtg_reg[0] (Aurora / MMCM levels -> aclk), s_ovf_reg[0] (user -> aclk)
#   u_rst_s_reg[0], u_pol_reg[*] (aclk -> user_clk); i_rpb_reg[0], i_pma_reg[0] (aclk -> init_clk)
proc jlk_cells {pat} {
  set c [get_cells -quiet -hierarchical -filter "NAME =~ \"$pat\""]
  if {[llength $c] == 0} { error "JCLINK_CONSTRAINT_EMPTY cells $pat" }
  puts "JCLINK_CONSTRAINT_MATCH cells [llength $c] $pat"
  return $c
}
proc jlk_clock_of_pin {pat} {
  set p [get_pins -quiet -hierarchical -filter "NAME =~ \"$pat\""]
  if {[llength $p] == 0} { error "JCLINK_CONSTRAINT_EMPTY pins $pat" }
  set c [get_clocks -quiet -of_objects [lindex $p 0]]
  if {[llength $c] == 0} { error "JCLINK_CONSTRAINT_EMPTY clock on $pat" }
  puts "JCLINK_CLOCK $pat [get_property NAME $c] [get_property PERIOD $c]"
  return $c
}
proc jlk_cdc {pre clk_a clk_u clk_i} {
  set pa [get_property PERIOD $clk_a]
  set pu [get_property PERIOD $clk_u]
  set pi [get_property PERIOD $clk_i]
  set g [expr {min($pa, $pu)}]
  foreach {f src dst} [list txf $clk_a $clk_u rxf $clk_u $clk_a] {
    set w [jlk_cells "${pre}${f}/wp_g_s1_reg*"]
    set r [jlk_cells "${pre}${f}/rp_g_s1_reg*"]
    set_max_delay -datapath_only $g -from $src -to $w
    set_max_delay -datapath_only $g -from $dst -to $r
    set_bus_skew $g -from [jctl_src $w $src] -to $w
    set_bus_skew $g -from [jctl_src $r $dst] -to $r
    set ca [get_cells -quiet -hierarchical -filter "NAME =~ \"${pre}${f}/clr_*_s1_reg\""]
    if {[llength $ca]} { set_max_delay -datapath_only $g -to $ca }
  }
  foreach s {s_tx s_rx s_pll s_gtg s_ovf} {
    set_max_delay -datapath_only $pa -to [jlk_cells "${pre}${s}_reg*"]
  }
  set_max_delay -datapath_only $pu -from $clk_a -to [jlk_cells "${pre}u_rst_s_reg*"]
  set_max_delay -datapath_only $pu -from $clk_a -to [jlk_cells "${pre}u_pol_reg*"]
  set_max_delay -datapath_only $pi -from $clk_a -to [jlk_cells "${pre}i_rpb_reg*"]
  set_max_delay -datapath_only $pi -from $clk_a -to [jlk_cells "${pre}i_pma_reg*"]
}
# endpoints crossing aclk <-> user_clk that are none of the above; returns the count.
# finding 2: a literal [0]/[*] inside a double-quoted Tcl pattern is command-substituted at
# parse time ("invalid command name \"0\""), and even escaped (\[0\]) it still reaches
# string match/=~ as a one-character glob class, not a literal bracket pair. Every pattern
# here is bracket-free, as hw/jc/ctl/jc_ctl_timing.tcl's own patterns are.
proc jlk_cdc_audit {pre clk_a clk_u} {
  set ok [list "${pre}txf/*_s1_reg*" "${pre}rxf/*_s1_reg*" "${pre}s_*_reg*" \
               "${pre}u_rst_s_reg*" "${pre}u_pol_reg*"]
  set bad 0
  foreach {from to} [list $clk_a $clk_u $clk_u $clk_a] {
    foreach p [get_timing_paths -quiet -setup -from $from -to $to -max_paths 20000 -nworst 1] {
      set c [get_property PARENT_CELL [get_property ENDPOINT_PIN $p]]
      set hit 0
      foreach k $ok { if {[string match $k [get_property NAME $c]]} { set hit 1 } }
      if {!$hit} { incr bad; puts "JCLINK_CDC_UNEXPECTED [get_property NAME $c]" }
    }
  }
  return $bad
}
```

`jlk_cdc` uses `jctl_src` from `hw/jc/ctl/jc_ctl_timing.tcl`, which `build_card.tcl` sources first (`:349`).

In `hw/jc/card/build_card.tcl`:
- `set EXPECT_CELLS {loader ctl eng fk33_seam_0 card bcgrant}` (`:272`) becomes `set EXPECT_CELLS {loader ctl eng fk33_seam_0 card bcgrant tok gtgclk}`; the RTL source lists gain `rtl/tok_loop_pkg.vhd rtl/tok_loop_regs.vhd rtl/tok_loop_axm.vhd rtl/tok_loop_fsm.vhd rtl/jc_seam_mux.vhd rtl/embed_gather.vhd rtl/jc_link_pkg.vhd rtl/jc_link_tx.vhd rtl/jc_link_rx.vhd rtl/tok_loop.vhd` in a new `set LINK_2008 {...}` added to `VHDL2008`, plus `rtl/jc_tok_top.vhd` and `hw/jc/link/rtl/jc_gtg_clk.vhd` (module-reference tops, default standard like `jc_ctl_core.vhd`). `rtl/jc_loader_pkg.vhd` and `rtl/async_fifo.vhd` are already in the project (loader and engine lists); do not add them twice.
- After `source $repo/hw/jc/ctl/jc_ctl_timing.tcl` (`:349`), add `source $repo/hw/jc/link/jc_link_timing.tcl`, and inside the existing `catch` block after the ctl constraints:

```tcl
  set clk_u [jlk_clock_of_pin "*tok/inst/*rxf/wp_g_reg*/C"]
  set clk_i [jlk_clock_of_pin "*tok/inst/*i_rpb_reg*/C"]
  jlk_cdc "*tok/inst/*" $aclk_clk $clk_u $clk_i
  set lk_bad [jlk_cdc_audit "*tok/inst/*" $aclk_clk $clk_u]
  puts "JCCARD_LINK_CDC_UNEXPECTED $lk_bad"
  if {$lk_bad != 0} { jcc_fail "link cdc audit: $lk_bad unexpected crossing(s)" }
```

Teeth (finding 2): before trusting the patterns above inside a multi-hour card build, source
them against a standalone OOC synth of `jc_tok_top` alone, so a Tcl bracket defect
(`invalid command name "0"`, or a `[0]`/`[*]` reaching `string match`/`=~` as a one-character
glob class instead of a literal) is caught in minutes:

```bash
W=/mnt/storage/fk33_builds/jc_link_timing_ooc
mkdir -p $W
cat > $W/ooc.tcl <<'TCL'
set repo [lindex $argv 0]
read_vhdl -vhdl2008 [list $repo/rtl/jc_loader_pkg.vhd $repo/rtl/async_fifo.vhd \
  $repo/rtl/tok_loop_pkg.vhd $repo/rtl/tok_loop_regs.vhd $repo/rtl/tok_loop_axm.vhd \
  $repo/rtl/tok_loop_fsm.vhd $repo/rtl/jc_seam_mux.vhd $repo/rtl/embed_gather.vhd \
  $repo/rtl/jc_link_pkg.vhd $repo/rtl/jc_link_tx.vhd $repo/rtl/jc_link_rx.vhd \
  $repo/rtl/tok_loop.vhd $repo/rtl/jc_tok_top.vhd]
synth_design -top jc_tok_top -part xcvu35p-fsvh2104-2L-e -mode out_of_context
source $repo/hw/jc/link/jc_link_timing.tcl
set clk_a [get_clocks -of_objects [get_pins aclk]]
set clk_u [jlk_clock_of_pin "*rxf/wp_g_reg*/C"]
set clk_i [jlk_clock_of_pin "*i_rpb_reg*/C"]
jlk_cdc "" $clk_a $clk_u $clk_i
set lk_bad [jlk_cdc_audit "" $clk_a $clk_u]
puts "JCCARD_LINK_CDC_UNEXPECTED $lk_bad"
TCL
vivado -mode batch -nojournal -log $W/ooc.log -source $W/ooc.tcl -tclargs "$(git rev-parse --show-toplevel)"
grep -E '^(JCLINK_CONSTRAINT_MATCH|JCLINK_CLOCK|JCCARD_LINK_CDC_UNEXPECTED|ERROR:)' $W/ooc.log
```

Expected: every `JCLINK_CONSTRAINT_MATCH` present, no `ERROR:`, `JCCARD_LINK_CDC_UNEXPECTED 0`.
A Tcl error here is a stop condition for Step 5 and for any card build: fix the pattern, rerun,
before proceeding. (Budget: one Vivado, an OOC synth of one small module, far under 8G; capped.)

- Immediately before the `if {$impl eq "congestion"} { opt_design ...` block (`:427`):

```tcl
# the GTG refclk ECO (plan D11): JC_LINK_REFCLK is stamped into jc_card_bd.tcl's GENSTAMP
set _lr [expr {[info exists ::env(JC_LINK_REFCLK)] ? $::env(JC_LINK_REFCLK) : "gtg"}]
if {$_lr eq "gtg"} {
  set ::JC_AUR_CELL [get_property NAME [lindex [get_cells -hier -filter {NAME =~ *aur/inst && IS_PRIMITIVE == 0}] 0]]
  set ::JC_GTG_PIN [get_property NAME [lindex [get_pins -hier -filter {NAME =~ *gtgclk/*u_gbg/O}] 0]]
  if {[catch {source $repo/hw/jc/link/eco_aurora_gtg.tcl} err]} { jcc_fail "gtg eco: $err" }
} else {
  puts "JCCARD_LINK_REFCLK pin: no ECO, the QPLL uses AC36"
}
```

- After `place_design` (both branches), add the GT site check:

```tcl
set _gts [get_cells -hier -filter {REF_NAME == GTYE4_CHANNEL}]
if {[llength $_gts] != 1 || [get_property LOC $_gts] ne "GTYE4_CHANNEL_X0Y0"} {
  jcc_fail "GT placement: [llength $_gts] channel(s) at [get_property LOC $_gts], want one at GTYE4_CHANNEL_X0Y0"
}
puts "JCCARD_GT_LOC [get_property LOC $_gts]"
```

`run_card.sh` must export `JC_LINK_REFCLK` to Vivado unchanged (it already passes the environment through `run_capped.sh`; confirm with `--dry-run` that the variable appears in the printed environment, else add it to the printed bindings).

- [ ] **Step 5: Run the BD-only build (subagent-safe: no hardware, one Vivado)**

Budget: one Vivado on the box (presence check first); a `bd_only` run stops after the BD (`build_card.tcl` `bdonly` exit), far below the card build's 47 GB (ESTIMATE; capped at 16G anyway).

```bash
R=/mnt/storage/fk33_builds/jcloop_bd1
mkdir -p $R
systemd-run --user --scope -p MemoryHigh=16G -p MemoryMax=18G \
  vivado -mode batch -nojournal -log $R/bd.log -source hw/jc/card/build_card.tcl \
  -tclargs $R xcvu35p-fsvh2104-2L-e bd_only -nonce jcloop-bd1
grep -E '^(JCCARD_BD_DONE|JCCARD_BD FAIL|JCCARD_ADDR|AURORA_CFG_FAIL|FK33_BD_VALIDATE FAIL|ERROR:)' $R/bd.log
```

Expected: `JCCARD_ADDR ctl/m_axil maps 4 segments`, `JCCARD_ADDR tok/m_hbm maps 32 segments`, `JCCARD_ADDR tok/m_seam maps 1 segments`, `JCCARD_BD module_ref_cells=8`, `JCCARD_BD_DONE`, and no `FAIL`/`ERROR:` line. A `JCCARD_BD FAIL: no BD port gt_tx_txp` means the GT interface port naming differs: read the actual names (`get_bd_ports`), update `GT_TOP_PORTS` and the test, regenerate, rerun.

- [ ] **Step 6: Write the loop model inside the fake broker**

`server/tests/jc_sim_loop.h`:

```c
/* server/tests/jc_sim_loop.h -- a C model of rtl/tok_loop.vhd's host-visible behaviour, for
 * jc_sim_broker --loop (plan 2026-11-04 Task 7). It drives the simulated seam through the
 * same transport the broker serves, with the write sequence of tok_loop_fsm (which Task 2
 * pinned to run_prompt's), so tools/jc/jc_loop.py can be tested against run_prompt's ids
 * without hardware. Not an oracle for the RTL: the GHDL benches are. NO HARDWARE. */
#ifndef JC_SIM_LOOP_H
#define JC_SIM_LOOP_H
#include <stdint.h>
#include "../fk33_transport.h"

#define JC_LOOP_BASE 0x20000u
#define JC_LOOP_SPAN 0x10000u

typedef struct jc_loop jc_loop;
jc_loop *jc_loop_new(fk33_transport *t, unsigned n_embd);
int  jc_loop_rd(jc_loop *L, uint32_t off, uint32_t *v);    /* off inside the loop window */
int  jc_loop_wr(jc_loop *L, uint32_t off, uint32_t v);
int  jc_loop_owns_seam(const jc_loop *L);                   /* host seam access is refused */
void jc_loop_tick(jc_loop *L);                              /* run until blocked */
void jc_loop_pair(jc_loop *a, jc_loop *b);                  /* a's frames go to b */
void jc_loop_drop(jc_loop *a, unsigned long nth);           /* corrupt a's nth frame (1-based) */
#endif
```

`server/tests/jc_sim_loop.c`:

```c
/* server/tests/jc_sim_loop.c -- see jc_sim_loop.h. Register offsets and reasons are
 * rtl/tok_loop_pkg.vhd's; the per-position sequence is tok_loop_fsm's state list. */
#include <stdlib.h>
#include <string.h>
#include "jc_sim_loop.h"
#include "../fk33_seam.h"

enum { S_IDLE, S_RUN, S_STOPPED };
enum { W_NONE, W_ROW, W_LINK, W_CREDIT, W_TOKEN, W_OUT };
enum { R_NONE, R_MAX_NEW, R_STOP_ID, R_MAXPOS, R_ABORT, R_ENGINE_ERR, R_ENGINE_TIMEOUT,
       R_SEAM_ERR, R_LINK_TIMEOUT, R_RETRY_EXH, R_BAD_CONFIG, R_SEQ_RESET_FAIL, R_GATHER_ERR };
#define SB FK33_SEAM_BASE          /* 0xE000, server/fk33_seam.h:227 */
#define OUT_DEPTH 1024u
#define MAXP 4096u

typedef struct { uint32_t pos, exp, seq; int bad; uint16_t *m; } frame;
struct jc_loop {
  fk33_transport *t;
  unsigned n;
  int state, wait, owns;
  uint32_t reason, pos, n_gen, plen, max_new, row_src, role, resend_cap, stop[8];
  uint32_t next_tok, next_v, row_exp, row_addr, prompt_addr, out_ack, out_addr, credit;
  uint32_t kvmax, g, row_ready, consumed, frames_sent, frames_good, crc_fails, resends, cleared;
  uint32_t seqpos_bad, overruns;
  uint32_t prompt[MAXP], out[OUT_DEPTH];
  uint16_t *hrow;
  jc_loop *peer;                   /* a -> b */
  frame q[2]; int qn;              /* RXDEPTH 2 */
  frame held; int has_held;
  unsigned long drop_nth, sent_total;
};

static int sw(jc_loop *L, uint32_t off, uint32_t v) { return L->t->reg_write32(L->t->ctx, SB + off, v); }
static int sr(jc_loop *L, uint32_t off, uint32_t *v) { return L->t->reg_read32(L->t->ctx, SB + off, v); }
static void stop_(jc_loop *L, uint32_t r) { L->reason = r; L->state = S_STOPPED; L->owns = 0; L->wait = W_NONE; }

jc_loop *jc_loop_new(fk33_transport *t, unsigned n_embd)
{
  jc_loop *L = calloc(1, sizeof *L);
  int k;
  if (!L) return NULL;
  L->t = t; L->n = n_embd; L->resend_cap = 3;
  for (k = 0; k < 8; k++) L->stop[k] = 0xFFFFFFFFu;
  L->hrow = calloc(n_embd, sizeof *L->hrow);
  L->held.m = calloc(n_embd, sizeof(uint16_t));
  for (k = 0; k < 2; k++) L->q[k].m = calloc(n_embd, sizeof(uint16_t));
  return L;
}
void jc_loop_pair(jc_loop *a, jc_loop *b) { a->peer = b; }
void jc_loop_drop(jc_loop *a, unsigned long nth) { a->drop_nth = nth; }
int jc_loop_owns_seam(const jc_loop *L) { return L->owns; }

static void deliver(jc_loop *a, const frame *f)
{
  jc_loop *b = a->peer;
  a->frames_sent++; a->sent_total++;
  if (!b) return;
  if (a->drop_nth && a->sent_total == a->drop_nth) { b->crc_fails++; return; }   /* corrupted */
  if (f->pos != b->consumed + (uint32_t)b->qn) { b->seqpos_bad++; return; }     /* stale (rx verdict order) */
  if (b->qn >= 2) { b->overruns++; return; }
  b->q[b->qn].pos = f->pos; b->q[b->qn].exp = f->exp;
  memcpy(b->q[b->qn].m, f->m, b->n * sizeof(uint16_t));
  b->qn++; b->frames_good++;
}

static int start(jc_loop *L)
{
  uint32_t st, tp, sp;
  L->pos = 0; L->n_gen = 0; L->reason = 0; L->out_ack = 0; L->next_v = 0; L->qn = 0;
  L->has_held = 0; L->consumed = 0; L->frames_sent = L->frames_good = L->crc_fails = L->resends = 0;
  L->cleared = 0; L->seqpos_bad = 0; L->overruns = 0;
  L->sent_total = 0; L->state = S_RUN;
  if (!L->plen || L->plen > MAXP || !L->max_new || L->role > 2 || L->row_src > 2
      || ((L->row_src == 2) != (L->role == 2)) || L->row_src == 0) { stop_(L, R_BAD_CONFIG); return 0; }
  L->owns = 1;
  if (sw(L, FK33_SEAM_CTRL, 2) || sr(L, FK33_SEAM_STATUS, &st)) { stop_(L, R_SEAM_ERR); return 0; }
  if (st & 4) { stop_(L, R_SEQ_RESET_FAIL); return 0; }
  if (sr(L, FK33_SEAM_TOK_POS, &tp) || sr(L, FK33_SEAM_SEQ_POS, &sp) || tp || sp) { stop_(L, R_SEQ_RESET_FAIL); return 0; }
  if (sr(L, FK33_SEAM_KV_MAXPOS, &L->kvmax)) { stop_(L, R_SEAM_ERR); return 0; }
  return 0;
}

/* one position from row-in-hand to token; returns 1 when it blocked */
static int position(jc_loop *L, const uint16_t *row, uint32_t exp)
{
  uint32_t st, v, k;
  sw(L, FK33_SEAM_X_EXP, exp); sw(L, FK33_SEAM_WIN_SEL, 2); sw(L, FK33_SEAM_WIN_ADDR, 0);
  for (k = 0; k < L->n; k++) sw(L, FK33_SEAM_WIN_DATA, row[k]);
  sw(L, FK33_SEAM_SEQ_POS, L->pos); sw(L, FK33_SEAM_N_STEP, 1); sw(L, FK33_SEAM_CTRL, 1);
  do { if (sr(L, FK33_SEAM_STATUS, &st)) { stop_(L, R_SEAM_ERR); return 1; } } while (!(st & 5));
  if (st & 4) { stop_(L, R_ENGINE_ERR); return 1; }
  if (L->role == 1) {
    sw(L, FK33_SEAM_WIN_SEL, 3); sw(L, FK33_SEAM_WIN_ADDR, 0);
    for (k = 0; k < L->n; k++) { sr(L, FK33_SEAM_WIN_DATA, &v); L->held.m[k] = (uint16_t)v; }
    sr(L, FK33_SEAM_XEXP_OUT, &L->held.exp);
    L->held.pos = L->pos; L->has_held = 1;
    deliver(L, &L->held);
  }
  return 0;
}

void jc_loop_tick(jc_loop *L)
{
  int guard;
  for (guard = 0; guard < 4 && L->state == S_RUN; guard++) {
    uint32_t k;
    if (L->wait == W_OUT) { if (L->n_gen - L->out_ack >= OUT_DEPTH) return; L->wait = W_NONE; goto push; }
    if (L->wait == W_TOKEN) { if (!L->next_v) return; L->g = L->next_tok; L->next_v = 0; L->wait = W_NONE; goto push; }
    if (L->wait == W_CREDIT) { if (L->credit < L->pos) return; L->wait = W_NONE; }
    if (L->pos >= L->kvmax) { stop_(L, R_MAXPOS); return; }
    /* plan D3. The RTL waits after GO, before reading R_X; waiting before the position
     * delivers the same frames in the same order, which is all the host can observe. */
    if (L->role == 1 && L->credit < L->pos) { L->wait = W_CREDIT; return; }
    if (L->row_src == 1) {
      if (!L->row_ready) { L->wait = W_ROW; return; }
      L->row_ready = 0; L->wait = W_NONE;
      if (position(L, L->hrow, L->row_exp)) return;
    } else {
      if (!L->qn) { L->wait = W_LINK; return; }
      L->wait = W_NONE;
      if (position(L, L->q[0].m, L->q[0].exp)) return;
      { uint16_t *m0 = L->q[0].m; L->q[0] = L->q[1]; L->q[1].m = m0; }
      L->qn--; L->consumed++;
    }
    if (L->pos + 1 < L->plen) { L->pos++; continue; }
    if (L->role == 1) { L->wait = W_TOKEN; return; }
    sr(L, FK33_SEAM_ARGMAX, &L->g);
push:
    if (L->n_gen - L->out_ack >= OUT_DEPTH) { L->wait = W_OUT; return; }
    L->out[L->n_gen % OUT_DEPTH] = L->g; L->n_gen++;
    for (k = 0; k < 8; k++) if (L->stop[k] == L->g) { stop_(L, R_STOP_ID); return; }
    if (L->n_gen >= L->max_new) { stop_(L, R_MAX_NEW); return; }
    L->pos++;
  }
}

int jc_loop_rd(jc_loop *L, uint32_t off, uint32_t *v)
{
  uint32_t s;
  switch (off) {
  case 0x000: *v = 0x544C5031u; break;
  case 0x004: *v = 1; break;
  case 0x008: *v = (2u << 24) | (1u << 20) | (1u << 17) | (L->n & 0xFFFF); break;
  case 0x010:
    s = (uint32_t)L->state | (L->reason << 8) | ((uint32_t)L->owns << 16);
    if (L->wait == W_ROW) s |= 1u << 2;
    if (L->wait == W_TOKEN) s |= 1u << 3;
    if (L->crc_fails > L->cleared && L->wait == W_LINK) s |= (1u << 4) | (1u << 5);
    if (L->wait == W_OUT) s |= 1u << 7;
    if (L->wait == W_CREDIT) s |= 1u << 17;
    if (L->wait == W_LINK) s |= 1u << 18;
    *v = s; break;
  case 0x014: *v = L->pos; break;
  case 0x018: case 0x060: *v = L->n_gen; break;
  case 0x01C: *v = L->plen; break;
  case 0x020: *v = L->max_new; break;
  case 0x024: *v = L->row_src; break;
  case 0x028: *v = L->role; break;
  case 0x034: *v = L->resend_cap; break;
  case 0x044: *v = L->pos < L->plen ? L->prompt[L->pos] : L->g; break;
  case 0x048: *v = L->next_tok; break;
  case 0x064: *v = L->out_ack; break;
  case 0x068: *v = L->out_addr; break;
  case 0x06C: *v = L->out[L->out_addr % OUT_DEPTH]; L->out_addr++; break;
  case 0x074: *v = L->credit; break;
  case 0x078: *v = L->consumed; break;
  case 0x080: *v = 3u | (1u << 2) | (1u << 3); break;
  case 0x084: *v = L->frames_sent; break;
  case 0x088: *v = L->frames_good; break;
  case 0x08C: *v = L->crc_fails; break;
  case 0x090: *v = L->seqpos_bad; break;
  case 0x09C: *v = L->overruns; break;
  case 0x098: *v = L->resends; break;
  case 0x0AC: *v = L->kvmax; break;
  default:
    if (off >= 0x0C0 && off <= 0x0DC) { *v = L->stop[(off - 0x0C0) / 4]; break; }
    *v = 0;
  }
  return 0;
}

int jc_loop_wr(jc_loop *L, uint32_t off, uint32_t v)
{
  switch (off) {
  case 0x00C:
    if ((v & 1) && L->state != S_RUN) start(L);
    if ((v & 2) && L->state == S_RUN) stop_(L, R_ABORT);
    if ((v & 4) && L->has_held) {
      if (L->resends >= L->resend_cap) { stop_(L, R_RETRY_EXH); break; }
      L->resends++; L->sent_total = 0; L->drop_nth = 0; deliver(L, &L->held);
      if (L->peer) L->peer->cleared = L->peer->crc_fails;   /* B's pause clears on the good frame */
    }
    if ((v & 8) && L->wait == W_ROW) L->row_ready = 1;
    break;
  case 0x01C: L->plen = v; break;
  case 0x020: L->max_new = v; break;
  case 0x024: L->row_src = v & 3; break;
  case 0x028: L->role = v & 3; break;
  case 0x034: L->resend_cap = v; break;
  case 0x048: L->next_tok = v; L->next_v = 1; break;
  case 0x04C: L->row_exp = v; break;
  case 0x050: L->row_addr = v; break;
  case 0x054: if (L->row_addr < L->n) L->hrow[L->row_addr] = (uint16_t)v; L->row_addr++; break;
  case 0x058: L->prompt_addr = v; break;
  case 0x05C: if (L->prompt_addr < MAXP) L->prompt[L->prompt_addr] = v; L->prompt_addr++; break;
  case 0x064: L->out_ack = v; break;
  case 0x068: L->out_addr = v; break;
  case 0x074: L->credit = v; break;
  default:
    if (off >= 0x0C0 && off <= 0x0DC) L->stop[(off - 0x0C0) / 4] = v;
  }
  return 0;
}
```

The model's PAUSED flag on die B is `crc_fails > cleared`, set by `deliver` and cleared when die A's RESEND re-delivers the held frame; LINK_BAD and PAUSED share it (the model has no link-down). The queue swap keeps each slot's buffer owned by one slot.

In `server/tests/jc_sim_broker.c`:
- `#include "jc_sim_loop.h"` after `#include "../fk33_seam.h"`; add `static jc_loop *g_loop[MAX_DIES];` after `g_t`.
- In `handle()`, after the die lookup, add:

```c
    if (g_loop[d]) {
        unsigned long long o = 0, vv = 0;
        int is_rd = has_op(line, "rd32"), is_wr = has_op(line, "wr32");
        if ((is_rd || is_wr) && !get_num(line, "off", &o) && o >= JC_LOOP_BASE && o < JC_LOOP_BASE + JC_LOOP_SPAN) {
            uint32_t v = 0;
            if (is_rd) { jc_loop_rd(g_loop[d], (uint32_t)(o - JC_LOOP_BASE), &v); snprintf(buf, sizeof buf, "{\"ok\":true,\"val\":%u}\n", v); }
            else { get_num(line, "val", &vv); jc_loop_wr(g_loop[d], (uint32_t)(o - JC_LOOP_BASE), (uint32_t)vv); snprintf(buf, sizeof buf, "{\"ok\":true}\n"); }
            fprintf(g_log, "%s loop %s 0x%llx\n", g_name[d], is_rd ? "rd32" : "wr32", o);
            for (int k = 0; k < g_ndies; k++) if (g_loop[k]) jc_loop_tick(g_loop[k]);
            for (int k = 0; k < g_ndies; k++) if (g_loop[k]) jc_loop_tick(g_loop[k]);
            reply(fd, buf); fflush(g_log); return;
        }
        if (jc_loop_owns_seam(g_loop[d]) && !get_num(line, "off", &o) && o >= 0xE000 && o < 0xF000) {
            fprintf(g_log, "%s refused seam 0x%llx (loop owns it)\n", g_name[d], o);
            reply(fd, "{\"ok\":false,\"err\":\"AxiError: SLVERR (tok_loop owns the seam)\"}\n");
            return;
        }
    }
```

- In the `wrn` branch, replace the write line inside the value loop with

```c
            if (!rc) rc = (g_loop[d] && off >= JC_LOOP_BASE && off < JC_LOOP_BASE + JC_LOOP_SPAN)
                          ? jc_loop_wr(g_loop[d], (uint32_t)(off - JC_LOOP_BASE), (uint32_t)v)
                          : g_t[d]->reg_write32(g_t[d]->ctx, (uint32_t)off, (uint32_t)v);
```

  and before its `reply(...)` add `for (int k = 0; k < g_ndies; k++) if (g_loop[k]) jc_loop_tick(g_loop[k]);`.
- In `main`, before the option loop (`--loop` takes no value; the loop reads pairs):

```c
    int loop_on = 0;
    const char *loop_pair = NULL;
    unsigned long loop_drop = 0;
    for (i = 3; i < argc; i++)
        if (!strcmp(argv[i], "--loop")) {
            loop_on = 1;
            memmove(&argv[i], &argv[i + 1], (size_t)(argc - i - 1) * sizeof *argv);
            argc--; i--;
        }
```

  in the option loop, before the final `else`:

```c
        else if (!strcmp(argv[i], "--loop-pair")) loop_pair = argv[i + 1];
        else if (!strcmp(argv[i], "--loop-drop")) loop_drop = strtoul(argv[i + 1], NULL, 10);
```

  and after the dies are opened:

```c
    if (loop_on) {
        for (i = 0; i < g_ndies; i++) g_loop[i] = jc_loop_new(g_t[i], 4096);   /* fk33_sim.c:183 n_embd */
        if (loop_pair) {
            char pa[16] = "", pb[16] = "";
            int ia = -1, ib = -1, k;
            if (sscanf(loop_pair, "%15[^,],%15s", pa, pb) != 2) {
                fprintf(stderr, "jc_sim_broker: --loop-pair A,B\n"); return 2;
            }
            for (k = 0; k < g_ndies; k++) {
                if (!strcmp(g_name[k], pa)) ia = k;
                if (!strcmp(g_name[k], pb)) ib = k;
            }
            if (ia < 0 || ib < 0) { fprintf(stderr, "jc_sim_broker: --loop-pair names an unknown die\n"); return 2; }
            jc_loop_pair(g_loop[ia], g_loop[ib]);
            if (loop_drop) jc_loop_drop(g_loop[ia], loop_drop);
        }
    }
```

- Update the usage string and the header comment with the three options.

In `server/Makefile`, the `jc_sim_broker:` rule (`:179-180`) gains `tests/jc_sim_loop.c tests/jc_sim_loop.h` as prerequisites and `tests/jc_sim_loop.c` in its compile line.

Run: `make -C server jc_sim_broker run_prompt && python3 -m pytest -q server/tests/test_run_prompt_jc.py`
Expected: builds; the existing broker tests still pass (`--loop` is off by default).

- [ ] **Step 7: Write the host tool and its test**

`tools/jc/jc_loop.py`:

```python
#!/usr/bin/env python3
"""tools/jc/jc_loop.py -- run decode on the Jungle Cat's on-fabric token loop (spec 2026-11-04,
plan Task 7). The host only starts, answers NEED_ROW (host rows), relays tokens and credits
between the dies (spec 1b.5 phase 1, plan D3), resends on a paused link, and drains OUT.

    jc_loop.py --sock S --die A [--die2 B] --prompt FILE --max-new N --stop ID
               (--mv4i PATH | --synthetic) --ids-out FILE [--base 0x20000] [--timeout-s 3600]

Run `run_prompt --jc S --jc-die A [--jc-die2 B] ... --open-only` first: it streams the
programs; this tool never touches them. One broker client at a time.
Prints `timing <n> GOs` (run_prompt's line, so jc_ctxtest.sh's check applies) and ends with
^JCLOOP_DONE ids=<n> reason=<r> or ^JCLOOP_FAIL <why>. NO direct hardware access: it is a
broker client, and a real run is the main session's or Oren's (CLAUDE.md).

A WindowUnknown write (NEXT_TOKEN, CTRL, OUT_ACK and the rest outside send_row/setup's own
re-seek-and-resend loops) is never retried (finding 10): it propagates out of run() as a
RuntimeError and main() reports JCLOOP_FAIL rather than risk a double-applied write.
"""
import argparse, json, os, socket, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))

REG = dict(ID=0x000, CAPS=0x008, CTRL=0x00C, STATUS=0x010, POS=0x014, N_GEN=0x018,
           PROMPT_LEN=0x01C, MAX_NEW=0x020, ROW_SRC=0x024, ROLE=0x028, RESEND_CAP=0x034,
           ROW_TOK=0x044, NEXT_TOKEN=0x048, ROW_EXP=0x04C, ROW_ADDR=0x050, ROW_DATA=0x054,
           PROMPT_ADDR=0x058, PROMPT_DATA=0x05C, OUT_COUNT=0x060, OUT_ACK=0x064, OUT_ADDR=0x068,
           OUT_DATA=0x06C, LINK_CREDIT=0x074, LINK_CONSUMED=0x078, CRC_FAILS=0x08C,
           LINK_DOWNS=0x094, RESENDS=0x098, STOP_ID0=0x0C0)
REASONS = ["none", "MAX_NEW", "STOP_ID", "MAXPOS", "ABORT", "ENGINE_ERR", "ENGINE_TIMEOUT",
           "SEAM_ERR", "LINK_TIMEOUT", "LINK_RETRY_EXHAUSTED", "BAD_CONFIG", "SEQ_RESET_FAIL",
           "GATHER_ERR"]
ID_MAGIC = 0x544C5031


class Broker:
    def __init__(s, path):
        s.k = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.k.connect(path)
        s.f = s.k.makefile("rwb")

    def _send(s, req):
        s.f.write((json.dumps(req) + "\n").encode()); s.f.flush()
        return json.loads(s.f.readline())

    def call(s, req, retries=5):
        """finding 10: a WindowUnknown retry is safe only for rd32 -- re-reading changes
        nothing. A write (wr32, wrn) gets exactly one attempt here; it may already have
        landed, so the caller decides what a failure means (re-seek and resend the whole
        buffer for ROW_DATA/PROMPT_DATA, or JCLOOP_FAIL for everything else), never a blind
        retry of a write that could double-apply (a shifted row, a re-armed NEXT_TOKEN)."""
        idempotent = req.get("op") == "rd32"
        for i in range(retries):
            r = s._send(req)
            if r.get("ok"):
                return r
            if not idempotent or "WindowUnknown" not in r.get("err", "") or i == retries - 1:
                raise RuntimeError("broker: %s -> %s" % (req, r.get("err")))
            time.sleep(0.2)


class Die:
    def __init__(s, br, name, base):
        s.br, s.name, s.base = br, name, base

    def rd(s, reg):
        return s.br.call({"die": s.name, "op": "rd32", "off": s.base + REG[reg]})["val"]

    def wr(s, reg, val):
        s.br.call({"die": s.name, "op": "wr32", "off": s.base + REG[reg], "val": val & 0xFFFFFFFF})

    def wrn_fix(s, reg, vals):
        s.br.call({"die": s.name, "op": "wrn", "off": s.base + REG[reg], "fix": True,
                   "vals": [v & 0xFFFFFFFF for v in vals]})


def row_source(a):
    if a.synthetic:
        import tok_loop_model as M
        return lambda tok, n: M.synth_row(tok, n)
    import embed_gather as EG
    pt = EG.PackedTensor(a.mv4i)
    return lambda tok, n: pt.row_bfp(tok, recipe=EG.RECIPE_WIDE)


def send_row(d, row_of, n):
    """Answer NEED_ROW. ROW_DATA auto-increments, so a failed bulk write is redone from
    ROW_ADDR 0; ROW_READY is re-sent only while the same position still needs its row.
    finding 10: this re-seek-and-resend loop is the only retry ROW_DATA gets -- Broker.call
    itself no longer retries a write silently underneath it."""
    pos, tok = d.rd("POS"), d.rd("ROW_TOK")
    mant, exp = row_of(tok, n)
    for attempt in range(3):
        try:
            d.wr("ROW_EXP", exp); d.wr("ROW_ADDR", 0)
            d.wrn_fix("ROW_DATA", [m & 0xFFFF for m in mant])
            break
        except RuntimeError:
            if attempt == 2:
                raise
    st = d.rd("STATUS")
    if st & 4 and d.rd("POS") == pos:
        d.wr("CTRL", 8)


def setup(d, prompt, max_new, stop, role, src, cap):
    if d.rd("ID") != ID_MAGIC:
        raise RuntimeError("die %s: no tok_loop at %#x (ID %#x)" % (d.name, d.base, d.rd("ID")))
    d.wr("PROMPT_LEN", len(prompt)); d.wr("MAX_NEW", max_new)
    d.wr("STOP_ID0", stop if stop >= 0 else 0xFFFFFFFF)
    d.wr("ROLE", role); d.wr("ROW_SRC", src); d.wr("RESEND_CAP", cap)
    if role == 1:
        d.wr("LINK_CREDIT", 0)
    for attempt in range(3):   # finding 10: re-seek PROMPT_ADDR and resend the whole prompt,
        try:                   # never a blind retry of a bulk write that may have partly landed
            d.wr("PROMPT_ADDR", 0)
            d.wrn_fix("PROMPT_DATA", prompt)
            break
        except RuntimeError:
            if attempt == 2:
                raise


def drain(d, got):
    n = d.rd("OUT_COUNT")
    while len(got) < n:
        d.wr("OUT_ADDR", len(got))
        got.append(d.rd("OUT_DATA"))
    d.wr("OUT_ACK", len(got))


def run(a, br):
    prompt = [int(x) for x in open(a.prompt).read().split()]
    A = Die(br, a.die, a.base)
    B = Die(br, a.die2, a.base) if a.die2 else None
    n = A.rd("CAPS") & 0xFFFF
    row_of = row_source(a)
    if B:
        setup(A, prompt, a.max_new, a.stop, 1, 1, a.resend_max)
        setup(B, prompt, a.max_new, a.stop, 2, 2, a.resend_max)
        B.wr("CTRL", 1)
    else:
        setup(A, prompt, a.max_new, a.stop, 0, 1, a.resend_max)
    A.wr("CTRL", 1)
    out, ids = (B or A), []
    relayed = credit = handled = 0
    t0 = time.time()
    while True:
        sa = A.rd("STATUS")
        sb = B.rd("STATUS") if B else sa
        if sa & 4:
            send_row(A, row_of, n)
        drain(out, ids)
        if B:
            c = B.rd("LINK_CONSUMED")
            if c != credit:
                credit = c; A.wr("LINK_CREDIT", c)
            while relayed < len(ids):
                A.wr("NEXT_TOKEN", ids[relayed]); relayed += 1
            A.wr("OUT_ACK", A.rd("OUT_COUNT"))       # A's ring holds the relayed ids: keep it drained
            if sb & 0x10:
                fails = B.rd("CRC_FAILS") + B.rd("LINK_DOWNS")
                if fails > handled:
                    handled = fails
                    A.wr("CTRL", 4)
                    print("jc_loop: die %s paused at position %d, RESEND on %s" % (B.name, B.rd("POS"), A.name))
            if (sa & 3) == 2 and (sb & 3) == 1:
                B.wr("CTRL", 2)
        if (sa & 3) == 2 and (sb & 3) == 2:
            break
        if time.time() - t0 > a.timeout_s:
            raise RuntimeError("timeout after %d s at position %d" % (a.timeout_s, A.rd("POS")))
    drain(out, ids)
    ra, rb = (sa >> 8) & 0xFF, (sb >> 8) & 0xFF
    with open(a.ids_out, "w") as f:
        f.write("".join("%d\n" % t for t in ids))
    print("timing %d GOs" % (len(prompt) + len(ids) - 1 if ids else len(prompt)))
    ok = {1, 2}
    if ra not in ok or rb not in ok:
        return "JCLOOP_FAIL reason A=%s B=%s ids=%d" % (REASONS[ra], REASONS[rb] if B else "-", len(ids))
    return "JCLOOP_DONE ids=%d reason=%s" % (len(ids), REASONS[rb if B else ra])


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sock", required=True)
    ap.add_argument("--die", required=True)
    ap.add_argument("--die2")
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--max-new", type=int, required=True)
    ap.add_argument("--stop", type=int, default=-1)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--mv4i")
    g.add_argument("--synthetic", action="store_true")
    ap.add_argument("--ids-out", required=True)
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x20000)
    ap.add_argument("--resend-max", type=int, default=3)
    ap.add_argument("--timeout-s", type=int, default=3600)
    a = ap.parse_args(argv)
    try:
        line = run(a, Broker(a.sock))
    except (RuntimeError, OSError, ValueError) as e:
        line = "JCLOOP_FAIL %s" % e
    print(line)
    return 0 if "JCLOOP_DONE" in line else 1   # finding 15: a FAULT_PAUSED= prefix moves this off startswith


if __name__ == "__main__":
    sys.exit(main())
```

The `timing` line counts positions run, which equals GOs: `len(prompt) + len(ids) - 1` (the last id is never fed). With a real stop id this matches run_prompt's count only when the stop id ends the run; `jc_ctxtest.sh` always runs with `--stop -1`.

`tools/jc/test_jc_loop.py`:

```python
"""tools/jc/test_jc_loop.py -- jc_loop.py over jc_sim_broker --loop against run_prompt over the
same broker without --loop: the ids must be identical (plan 2026-11-04 Task 7). NO HARDWARE."""
import os, signal, subprocess, sys, tempfile
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import gen_tok_loop_vec as GV  # noqa: E402
import jc_loop as L  # noqa: E402

SERVER = os.path.join(REPO, "server")


@pytest.fixture(scope="module", autouse=True)
def build():
    r = subprocess.run(["make", "-C", SERVER, "run_prompt", "jc_sim_broker"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def broker(work, extra):
    sock = os.path.join(work, "s.sock")
    b = subprocess.Popen([GV.BROKER, sock, os.path.join(work, "b.log"), "--kv-maxpos", "16384",
                          "--dies", "A,B"] + extra, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert b.stdout.readline().startswith("JCSIMBROKER_READY")
    return b, sock


def ref_ids(prompt, max_new, pair):
    work = tempfile.mkdtemp(dir=os.path.expanduser("~/regress_scratch"))
    GV.write_programs(work)
    ids, _ = GV.run_case(work, prompt, max_new, -1, pair, None)
    return ids


def loop_ids(prompt, max_new, pair, extra=()):
    work = tempfile.mkdtemp(dir=os.path.expanduser("~/regress_scratch"))
    GV.write_programs(work)
    b, sock = broker(work, ["--loop"] + (["--loop-pair", "A,B"] if pair else []) + list(extra))
    try:
        with open(os.path.join(work, "p.txt"), "w") as f:
            f.write(" ".join(map(str, prompt)) + "\n")
        args = [GV.RUN_PROMPT, "--jc", sock, "--jc-die", "A", "--prompt", "p.txt", "--v2", "--seq-reset",
                "--dtbl", "a.dtbl", "--rel", "a.rel", "--manifest", GV.MAN_A, "--max-new", "1",
                "--stop", "-1", "--ids-out", "open.txt", "--open-only"]
        if pair:
            args += ["--jc-die2", "B", "--dtbl2", "b.dtbl", "--rel2", "b.rel", "--manifest2", GV.MAN_B]
        r = subprocess.run(args, cwd=work, capture_output=True, text=True, timeout=300)
        assert r.returncode == 0, r.stdout + r.stderr
        cmd = [sys.executable, os.path.join(HERE, "jc_loop.py"), "--sock", sock, "--die", "A",
               "--prompt", os.path.join(work, "p.txt"), "--max-new", str(max_new), "--synthetic",
               "--ids-out", os.path.join(work, "ids.txt"), "--timeout-s", "300"]
        if pair:
            cmd += ["--die2", "B"]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        last = r.stdout.strip().splitlines()[-1]
        return last, [int(x) for x in open(os.path.join(work, "ids.txt")).read().split()], r.stdout
    finally:
        b.send_signal(signal.SIGTERM); b.wait(timeout=10)


def test_single_die_ids_equal_run_prompt():
    want = ref_ids([1, 2, 3], 5, False)
    last, got, _ = loop_ids([1, 2, 3], 5, False)
    assert last.startswith("JCLOOP_DONE") and got == want


def test_pair_ids_equal_run_prompt():
    want = ref_ids([1, 2, 3], 5, True)
    last, got, _ = loop_ids([1, 2, 3], 5, True)
    assert last.startswith("JCLOOP_DONE") and got == want


def test_pair_with_a_corrupted_frame_resends_and_matches():
    want = ref_ids([1, 2, 3], 5, True)
    last, got, out = loop_ids([1, 2, 3], 5, True, ["--loop-drop", "3"])
    assert last.startswith("JCLOOP_DONE") and got == want
    assert "RESEND" in out


def test_timing_line_counts_positions():
    _, got, out = loop_ids([1, 2, 3], 5, False)
    assert "timing %d GOs" % (3 + len(got) - 1) in out


def test_broker_call_does_not_retry_a_write(monkeypatch):
    """finding 10: a WindowUnknown retry is safe only for rd32. A write (wr32, wrn) gets one
    attempt through Broker.call and raises immediately, never a blind retry that could
    double-apply (a shifted ROW_DATA/PROMPT_DATA window, a re-armed NEXT_TOKEN)."""
    b = L.Broker.__new__(L.Broker)
    calls = []

    def fake_send(req):
        calls.append(req["op"])
        if req["op"] == "rd32" and len(calls) == 1:
            return {"ok": False, "err": "WindowUnknown"}
        if req["op"] == "wr32":
            return {"ok": False, "err": "WindowUnknown"}
        return {"ok": True, "val": 0}

    monkeypatch.setattr(b, "_send", fake_send)
    r = b.call({"op": "rd32", "off": 0})
    assert r["ok"] and calls.count("rd32") == 2   # a read retried past one WindowUnknown
    calls.clear()
    with pytest.raises(RuntimeError):
        b.call({"op": "wr32", "off": 0, "val": 1})
    assert calls == ["wr32"]   # a write got exactly one attempt, then raised
```

Teeth: (1) in `jc_loop.py`, drop the `A.wr("LINK_CREDIT", c)` relay: `test_pair_ids_equal_run_prompt` must fail (A waits for credit, timeout); (2) drop the RESEND write: `test_pair_with_a_corrupted_frame_resends_and_matches` must fail; (3) in `Broker.call`, revert `idempotent = req.get("op") == "rd32"` to always retry (the old behaviour): `test_broker_call_does_not_retry_a_write` must fail (`calls == ["wr32", "wr32"]`, more than one attempt). Restore all three.

Run: `python3 -m pytest -q tools/jc/test_jc_loop.py`
Expected: `5 passed`; the three teeth checks each produce exactly one failing test.

- [ ] **Step 8: Add the loop mode to the context test**

In `hw/jc/host/jc_ctxtest.sh`: document `JC_LOOP=1` in the ENVIRONMENT block ("run the generation on the fabric loop: run_prompt --open-only streams the programs, then tools/jc/jc_loop.py drives the run; the GO count is jc_loop.py's `timing` line"). In `rp_cmd`, when `JC_LOOP=1`, end the run_prompt array with `--open-only` (keeping every other option), and define a second array:

```bash
  if [[ ${JC_LOOP:-0} == 1 ]]; then
    RP+=(--open-only)
    LP=(python3 "$REPO/tools/jc/jc_loop.py" --sock "$SOCK" --die "${DIE[0]}")
    if [[ $MODE == pair ]]; then LP+=(--die2 "${DIE[1]}"); fi
    LP+=(--prompt "$OUT/prompt_$1.txt" --max-new "$2" --stop -1 --mv4i "$EMB" --ids-out "$OUT/$3.ids")
  fi
```

and after `ex "$OUT/$tag.out" "$OUT/$tag.err" "${RP[@]}"; rc=$?` add:

```bash
    if [[ ${JC_LOOP:-0} == 1 && $rc -eq 0 ]]; then
      ex "$OUT/$tag.loop.out" "$OUT/$tag.loop.err" "${LP[@]}"; rc=$?
      [[ $DRY == 1 ]] || cat "$OUT/$tag.loop.out" >> "$OUT/$tag.out"
      [[ $DRY == 1 ]] || grep -qE '^JCLOOP_DONE' "$OUT/$tag.loop.out" || rc=1
    fi
```

The existing `timing ... GOs` parse then reads jc_loop.py's line (the last one in `$tag.out`). Extend `hw/jc/host/test_jc_ctxtest.py` with a `--dry-run` case under `JC_LOOP=1` asserting both `DRYRUN` commands appear, `--open-only` on the run_prompt one, and `jc_loop.py ... --stop -1` on the second.

Run: `python3 -m pytest -q hw/jc/host/test_jc_ctxtest.py`
Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add hw/jc/link/jc_link_timing.tcl \
  hw/jc/card/gen_jc_card.py hw/jc/card/test_gen_jc_card.py hw/jc/card/build_card.tcl \
  hw/jc/card/jc_card_bd.tcl hw/jc/card/jc_card.xdc hw/jc/card/jc_card_top.vhd \
  server/tests/jc_sim_loop.c server/tests/jc_sim_loop.h server/tests/jc_sim_broker.c server/Makefile \
  tools/jc/jc_loop.py tools/jc/test_jc_loop.py hw/jc/host/jc_ctxtest.sh hw/jc/host/test_jc_ctxtest.py
git commit -m "jc loop T7: tok/gtgclk/aur in the card BD, link CDC timing and ECO hook, jc_loop.py with a broker loop model" -- \
  hw/jc/link/jc_link_timing.tcl \
  hw/jc/card/gen_jc_card.py hw/jc/card/test_gen_jc_card.py hw/jc/card/build_card.tcl \
  hw/jc/card/jc_card_bd.tcl hw/jc/card/jc_card.xdc hw/jc/card/jc_card_top.vhd \
  server/tests/jc_sim_loop.c server/tests/jc_sim_loop.h server/tests/jc_sim_broker.c server/Makefile \
  tools/jc/jc_loop.py tools/jc/test_jc_loop.py hw/jc/host/jc_ctxtest.sh hw/jc/host/test_jc_ctxtest.py
```

(`hw/jc/card/jccard_const_allow.tcl` joins the commit only if Step 10's build named new constant bits.)

- [ ] **Step 10: The card build (MAIN SESSION ONLY, never a subagent)**

The full card build is the FK33_CARD-class job: ~47 GB including swap. State the budget before starting: `free -g` (resident now), the job's peak (47 GB incl. swap, capped at MemoryHigh 24G with the 30 GiB swap guard), and what is left; ONE Vivado on the box (presence check by `/proc/PID/exe`); `llama-server` stopped (Oren's call: it is user-visible). Nothing under `/tmp`.

```bash
bash hw/jc/card/run_card.sh --dry-run --clk-mhz 125 /mnt/storage/fk33_builds/jccard_loop1
JC_LINK_REFCLK=gtg JC_LINK_RATE=10.3125 \
  bash hw/jc/card/run_card.sh --clk-mhz 125 /mnt/storage/fk33_builds/jccard_loop1
grep -E '^JCCARD_(DONE|FAIL)' /mnt/storage/fk33_builds/jccard_loop1/results/SENTINEL* \
  /mnt/storage/fk33_builds/jccard_loop1/*.log | tail -3
```

`--clk-mhz 125`: the jccard10 build's core clock (spec section 2's measured position time is at 125 MHz); change it only with the record of the build it follows. Gate on `^JCCARD_DONE`; also require in the build log `^ECOA_DONE commons=1`, `^JCCARD_GT_LOC GTYE4_CHANNEL_X0Y0`, `^JCCARD_LINK_CDC_UNEXPECTED 0`. The full watch list is Task 8 amendment A9. On `JCCARD_FAIL ... const` naming `tok/` or `gtgclk/` bits, add each to `jccard_const_allow.tcl` only with a reason citing the RTL line that makes it constant, and rebuild. Copy the bitstream and logs into the repo results directory (`hw/jc/card/results/jccard_loop1_<date>/`) as soon as the sentinel appears.

---
### Task 8: Silicon gates (spec section 4), MAIN SESSION ONLY

Steps 1 and 2 are host code a subagent may write and test against `jc_sim_broker --loop` (no hardware). Steps 3 to 9 touch the board (`sqrl_bridge`, the broker, the BMC): the main session or Oren runs them, never a subagent.

#### AMENDMENT 2026-11-11 (final fix pass; final review I4). Where this block and a step below disagree, this block wins.

**A1. Images: the -ownpc manifests, and everything that hangs off them.** The dies carry the own-PC
layout (`5e0b8618`, `056cc683`): card 0 (die A) `/mnt/storage/llama-models/qwen38-27b-card0-b0-32-ownpc/manifest.json`,
card 1 (die B) `/mnt/storage/llama-models/qwen38-27b-card1-b33-63-ownpc/manifest.json`, with the
BC-250 copies under `~/jc_models/` (`JC_BC_MAN0='~/jc_models/qwen38-27b-card0-b0-32-ownpc/manifest.json'`,
`JC_BC_MAN1='~/jc_models/qwen38-27b-card1-b33-63-ownpc/manifest.json'`). `$MAN0`/`$MAN1` in `RB` are
these two. The token programs (`token.dtbl`/`token.rel`, runbook 3.1), the side images
(`side_gdn.json`, `gdn_zero.bin`, `imglock.bin`, runbook 3.2) and the broker's image fences
(`jc_bc_lane.sh start` reads `JC_BC_MAN0/1`) are all generated FROM these manifests into the new
`$W/card0` and `$W/card1`. Never reuse a program or side image built from the old layouts
(`jc27b_silicon_2026-11-04/card1` is the OLD die-B layout).

**A2. Host-path k1 regression anchor, BEFORE any loop run.** After Step 3's loads and before Step 4:

```bash
$REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B "${RB[@]}" \
  --prompt /mnt/storage/fk33_builds/jc27b_silicon_2026-11-04/prompt_k1.txt --max-new 1 --stop -1 \
  --ids-out $W/k1.ids --dump-xout $W/xout_A_k1.txt --dump-xout2 $W/xout_B_k1.txt
tail -1 $W/k1.ids                                                          # want 8678
cmp $W/xout_A_k1.txt /mnt/storage/fk33_builds/jc27b_ownpc_2026-11-11/xout_A_k1.txt && \
cmp $W/xout_B_k1.txt /mnt/storage/fk33_builds/jc27b_ownpc_2026-11-11/xout_B_k1.txt && echo K1_ANCHOR_OK
```

Gate: argmax 8678 and `K1_ANCHOR_OK`. The anchor is the own-PC pair's MEASURED host-path result
(`hw/jc/card/results/jc27b_ownpc_b_2026-11-11_silicon/measure_token.log` on branch `jc-card`:
`first argmax 8678`, `X_OUT die A/B identical to .../jc27b_ownpc_2026-11-11/xout_{A,B}_k1.txt`).
A mismatch means the new bitstream changed the engine or an image is wrong: stop before the loop.

**A3. No 1.25 Gb/s fallback.** Step 3's "rebuild with `JC_LINK_RATE=1.25`" is WITHDRAWN: the 1.25
core has no GTYE4_COMMON for the gtg ECO and its quad has no board refclk (Task 5 ruling;
`gen_jc_card.py` refuses it, and refuses `JC_LINK_REFCLK=pin` since 2026-11-11 because AK38/AK39 are
undriven). If rx_channel_up never rises after A4's reset pulse: stop, record LINK_STATUS on both
dies, and open a debugging file; there is no other rate to fall back to.

**A4. The explicit Aurora reset pulse at bring-up, kept as a defence.** The I5 fix holds `pma_init`
and `reset_pb` high until the GTG MMCM locks, but a pulse after the dies are configured is still
the first link action of Step 3, on both dies, TX side (A) first, then RX side (B): LINK_CTRL 1
(reset_pb), then 3 (reset_pb + pma_init), hold 1 s, then 1 (pma_init low), then 0 (reset_pb low);
then read LINK_STATUS. Checked against PG074 (v13.0 guide, local copy
`/mnt/storage/docs/xilinx/pg074-aurora-64b66b-en-us-13.0.pdf`, 2026-11-11), "Reset Sequencing" and
"Aurora 64B/66B Simplex Normal Operation Reset Sequence": assert reset_pb at least 128 user_clk
periods before pma_init; hold pma_init at least six init_clk periods (1 s for a hot-plug event the
remote detects); deassert pma_init; then deassert tx_reset_pb/rx_reset_pb (they may go together).
The pulse above follows that order. PG074 also states that when an MMCM generates init_clk,
pma_init must be applied until the MMCM locks, and that GT_REFCLK must be stable when pma_init
deasserts: the I5 hold satisfies both (gtg_clk and init_clk come from the same MMCM). One gap the
pulse covers: on lock the RTL releases pma_init and reset_pb in the same init_clk edge, not
pma_init first, so the explicit pulse is the guide-conforming sequence. PG074 simplex rule: send
data only after the partner's rx_channel_up (at least 45 ms after tx_channel_up); die A cannot see
B's rx_channel_up, so the host must read B's LINK_STATUS bit 1 before START on A. The generated
core's `jc_aurora_support_reset_logic.v` debounces `pma_init` in `init_clk` and delays the GT reset
release by ~19 `init_clk` cycles. Record which order brought rx_channel_up.

**A5. The socket forward follows `JC_BCW`.** `jc_bc_lane.sh start` serves the broker socket under
`$JC_BCW` on the BC-250; whenever `JC_BCW` changes (a new work dir for new programs), re-point the
workstation's ssh forward at `$JC_BCW/broker.sock` before any `run_prompt`/`jc_loop.py`: a forward
left on an old `JC_BCW` gives `ConnectionResetError` (MEASURED 2026-11-11, `measure_token.log`).

**A6. After ANY power loss (or a reprogram): reload the weights AND the side images, then
`coe_load.py verify`.** HBM contents do not survive; a die that answers ID/CAPS after a power cycle
holds no image. Runbook 3.3 for both images on both dies, then `coe_load.py verify` for each
(`^JCVERIFY_PASS`), then A2's anchor again. VCCINT returns to wiper 128 on a power cycle (CLAUDE.md);
set it back to 68 only by the standing procedure.

**A7. Soak accounting (Step 5).** With no link-down, `|resends - (crc_fails + seqpos_bad)| <= crc_fails`
(a framing corruption can merge two frames into one verdict, or split one into two; each costs at
most one verdict per CRC failure). `jc_link_soak.py` implements exactly this (`accounting_ok`);
`SOAK_FAIL accounting` means a gap wider than `crc_fails`.

**A8. jc_loop.py behaviour the steps rely on (final fix pass).** Before setup it ABORTs a die still
running from an earlier client; it ends the run as soon as either die stops for a reason other than
MAX_NEW/STOP_ID or reads IDLE after START; every unclean exit ABORTs both dies; die B's TMO_LINK is
written 0xFFFFFFFF (also its reset value now); absolute-value writes are retried on WindowUnknown,
CTRL pulses are not (read-back verified), NEXT_TOKEN is not (JCLOOP_FAIL).

**A9. Watch list for Task 7 Step 10 (the build log) and Task 8 (bring-up).** Each line must appear
as stated; anything else is a stop:
- `JCCARD_LINK_ENV JC_LINK_REFCLK=gtg ...` (or `(unset)`) and `JCCARD_LINK_REFCLK gtg`;
- `JCCARD_BD aur inputs=35 open=0`;
- `JCLINK_CLOCK` lines with periods 6.206 ns (user_clk, 10.3125/64 Gb/s) and 8.000 ns (init_clk,
  jc_gtg_clk CLKOUT1 at INIT_DIV 10);
- `JCCARD_LINK_CDC_UNEXPECTED 0`, AND after route `report_clock_interaction` shows no
  `Timed (unsafe)` between aclk, user_clk and init_clk (the audit sees only named crossings);
- `JCCARD_GTG_MMCM ... LOC=MMCM_X0Y2 ... CDR=BACKBONE`;
- exactly one `ECOA_PD` line whose type is not POWER (the powered QPLL, QPLL1 on the card) and three
  `ECOA_SEL ... now POWER` lines (QPLL<q>REFCLKSEL = 111);
- `ECOA_DONE commons=1 loads=1`;
- `JCCARD_GT_LOC GTYE4_CHANNEL_X0Y0`;
- LINK_STATUS (0x080) bit meanings: 0 tx_channel_up, 1 rx_channel_up, 2 GTG MMCM locked, 3 gt_pll_lock,
  8 paused, 9 bad, 10 down, 11 TX retry exhausted, 12 RX FIFO overflow (`rtl/tok_loop_pkg.vhd` LS_*);
- `LOOP_ID <die> id=0x544c5031` on both dies.

**A10. Steps 1 and 2 are DONE** in the final fix pass (2026-11-11): `jc_loop.py --dump-xout/--dump-xout2/
--fault-polarity-at` and `tools/jc/jc_link_soak.py`, tested in `tools/jc/test_jc_loop.py`
(`test_dump_xout_equals_run_prompts`, `test_soak_accounting_on_the_model`,
`test_soak_accounting_slack_is_bounded_by_crc_fails`; `--fault-polarity-at` is silicon-only, the
model has no polarity). The code blocks in Steps 1 and 2 below are the original brief; the committed
files supersede them (CTRL writes there go through `Die.ctrl`, and the soak ABORTs both dies on exit).

**Files:**
- Modify: `tools/jc/jc_loop.py` (`--dump-xout`, `--dump-xout2`, `--fault-polarity-at`), `tools/jc/test_jc_loop.py`
- Create: `tools/jc/jc_link_soak.py`, `docs/debugging/<date>_jc-loop-silicon.md` (written by the main session at the moment a result is in, CLAUDE.md format)

**Interfaces:**
- Consumes (grounded): runbook `docs/superpowers/plans/2026-10-09-jc-silicon-runbook.md` sections 1 (variables: `$BMC`, `$SOCK`, `$W`, `$REPO`, `$PROMPT` = the 23-id DC-DC prompt), 2 (preconditions), 3.3 (image loads, broker NOT running), 3.4 (broker start, `^JCLANE_DONE start`, `FWD_OK`), 3.5 (seam ID/CAPS), 4.2 (llama.cpp CPU reference, `^REF_ARGMAX`); `sqrl_bridge C<bmc-ip> design.bit,design.bit skip` (`docs/boards/jungle-cat/README.md:88-118`: only the first file is used, on both dies); `run_prompt --dump-xout/--dump-xout2` file format `exp E` then n_embd int16 lines (`server/tests/run_prompt.c:319-341`); `jc_bc_lane.sh rezero` (GDN re-zero, `hw/jc/host/jc_ctxtest.sh:29-35`); the measured card state: jccard10 first argmax 1206 at k=23 against llama.cpp's 7732 (`hw/jc/card/results/jc27b_jccard10_2026-11-04/README.md`).
- Produces: sentinels `^LOOP_ID`, `^SOAK_PASS`/`^SOAK_FER`/`^SOAK_FAIL`, `^HOP_SAME`/`^HOP_DIFF`, `^IDS_SAME`/`^IDS_DIFF`, `^FAULT_PASS`/`^FAULT_FAIL`.

- [ ] **Step 1: Add the dump and fault options to `jc_loop.py` (subagent-safe)**

Add to `tools/jc/jc_loop.py`:

```python
SEAM = 0xE000                       # server/fk33_seam.h:227
S_WIN_SEL, S_WIN_ADDR, S_WIN_DATA, S_XEXP_OUT = 0x58, 0x5C, 0x60, 0xA4


def dump_xout(br, die, n, path):
    """run_prompt --dump-xout's file (server/tests/run_prompt.c:319-341) from the seam's
    window 3 after the loop stopped and released it."""
    br.call({"die": die, "op": "wr32", "off": SEAM + S_WIN_SEL, "val": 3})
    br.call({"die": die, "op": "wr32", "off": SEAM + S_WIN_ADDR, "val": 0})
    vals = br.call({"die": die, "op": "rdn", "off": SEAM + S_WIN_DATA, "fix": True, "n": n})["vals"]
    e = br.call({"die": die, "op": "rd32", "off": SEAM + S_XEXP_OUT})["val"]
    e = e - (1 << 32) if e >= (1 << 31) else e
    with open(path, "w") as f:
        f.write("exp %d\n" % e)
        f.write("".join("%d\n" % ((v & 0xFFFF) - 0x10000 if v & 0x8000 else v & 0xFFFF) for v in vals))
```

In `run()`: (a) a polarity fault, when `a.fault_polarity_at` is set and the pair has produced that many ids: write A `LINK_CTRL` 4 (TX polarity invert, plan D5), suspend the RESEND handler, wait up to 10 s for B's STATUS bit 4 (PAUSED) and print `jc_loop: fault: B paused` with B's CRC_FAILS and LINK_DOWNS, write A `LINK_CTRL` 0, wait up to 10 s for B's LINK_STATUS bit 1 (rx_channel_up), set `handled` to B's current CRC_FAILS + LINK_DOWNS minus one so the handler issues exactly one RESEND, and resume. Concretely, add `REG.update(LINK_CTRL=0x07C, LINK_STATUS=0x080, SEQPOS_BAD=0x090, FRAMES_SENT=0x084, FRAMES_GOOD=0x088)` and, inside the `if B:` block before `if sb & 0x10:`:

```python
            if a.fault_polarity_at and not fault_done and len(ids) >= a.fault_polarity_at:
                A.wr("LINK_CTRL", 4)
                t1 = time.time()
                while not (B.rd("STATUS") & 0x10) and time.time() - t1 < 10:
                    pass
                paused = bool(B.rd("STATUS") & 0x10)
                print("jc_loop: fault: TX polarity inverted on %s; %s paused=%d crc_fails=%d link_downs=%d"
                      % (A.name, B.name, paused, B.rd("CRC_FAILS"), B.rd("LINK_DOWNS")))
                A.wr("LINK_CTRL", 0)
                t1 = time.time()
                while not (B.rd("LINK_STATUS") & 2) and time.time() - t1 < 10:
                    pass
                handled = B.rd("CRC_FAILS") + B.rd("LINK_DOWNS") - 1
                fault_done, fault_paused = True, paused
```

with `fault_done = fault_paused = False` initialised next to `handled = 0`, and at the end of `run()`, when `a.fault_polarity_at` is set, the return line is prefixed `FAULT_PAUSED=%d ` % fault_paused. (b) After the final `drain`, `if a.dump_xout: dump_xout(br, A.name, n, a.dump_xout)` and `if a.dump_xout2 and B: dump_xout(br, B.name, n, a.dump_xout2)`. Arguments: `--dump-xout PATH`, `--dump-xout2 PATH`, `--fault-polarity-at N` (int, default 0). Change the ok set check to also require, when `a.fault_polarity_at`, that `fault_done` is true.

Add to `tools/jc/test_jc_loop.py`:

```python
def test_dump_xout_equals_run_prompts():
    work = tempfile.mkdtemp(dir=os.path.expanduser("~/regress_scratch"))
    GV.write_programs(work)
    with open(os.path.join(work, "p.txt"), "w") as f:
        f.write("1 2 3 4\n")
    b, sock = broker(work, [])
    try:
        r = subprocess.run([GV.RUN_PROMPT, "--jc", sock, "--jc-die", "A", "--prompt", "p.txt", "--v2",
                            "--seq-reset", "--dtbl", "a.dtbl", "--rel", "a.rel", "--manifest", GV.MAN_A,
                            "--max-new", "1", "--stop", "-1", "--ids-out", "ref.ids",
                            "--dump-xout", "ref.xout"], cwd=work, capture_output=True, text=True, timeout=300)
        assert r.returncode == 0, r.stderr
    finally:
        b.send_signal(signal.SIGTERM); b.wait(timeout=10)
    last, got, out = loop_ids([1, 2, 3, 4], 1, False, (), dump=os.path.join(work, "loop.xout"))
    assert last.startswith("JCLOOP_DONE")
    assert open(os.path.join(work, "loop.xout")).read() == open(os.path.join(work, "ref.xout")).read()
```

and give `loop_ids` a `dump=None` keyword that appends `["--dump-xout", dump]` to the jc_loop.py command. (The broker model has no link-down and no polarity, so `--fault-polarity-at` is exercised on silicon only; its code path is covered by `--dry` review, not by a test: say so in the test file's header.)

Run: `python3 -m pytest -q tools/jc/test_jc_loop.py`
Expected: `5 passed`.

- [ ] **Step 2: Write the link soak tool (subagent-safe)**

`tools/jc/jc_link_soak.py`:

```python
#!/usr/bin/env python3
"""tools/jc/jc_link_soak.py -- spec 2026-11-04 section 4, silicon step 1: frames over the fitted
lane for SECONDS, counted by die B's deframer (plan Task 8).

    jc_link_soak.py --sock S --a A --b B [--seconds 600] [--base 0x20000]

Die A runs one position (role A, host row, prompt [1]) and then holds frame 0 while it waits
for a token; the tool RESENDs that frame for SECONDS with RESEND_CAP at its maximum. Die B
(role B) consumed frame 0, so every resent frame that arrives intact is a STALE frame
(SEQPOS_BAD) and every corrupted one a CRC failure (jc_link_rx checks the CRC first). The
accounting must close: resends = crc_fails + seqpos_bad when no link-down was seen.
Ends ^SOAK_PASS (0 CRC failures), ^SOAK_FER <rate> (failures measured), or ^SOAK_FAIL <why>.
A real run is the main session's or Oren's (a broker client on the board)."""
import argparse, sys, time
import jc_loop as L


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sock", required=True)
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--seconds", type=int, default=600)
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x20000)
    a = ap.parse_args(argv)
    br = L.Broker(a.sock)
    A, B = L.Die(br, a.a, a.base), L.Die(br, a.b, a.base)
    n = A.rd("CAPS") & 0xFFFF
    L.setup(A, [1], 1, -1, 1, 1, 0xFFFFFFFF)
    L.setup(B, [1], 1, -1, 2, 2, 3)
    B.wr("CTRL", 1); A.wr("CTRL", 1)
    t0 = time.time()
    while not (A.rd("STATUS") & 8):                      # A: NEED_TOKEN, frame 0 sent and held
        if A.rd("STATUS") & 4:
            L.send_row(A, L.row_source(argparse.Namespace(synthetic=True, mv4i=None)), n)
        if time.time() - t0 > 60:
            print("SOAK_FAIL die %s never reached NEED_TOKEN" % A.name); return 1
    if B.rd("FRAMES_GOOD") != 1:
        print("SOAK_FAIL die %s did not take frame 0 (FRAMES_GOOD %d, CRC_FAILS %d)"
              % (B.name, B.rd("FRAMES_GOOD"), B.rd("CRC_FAILS"))); return 1
    t0, k = time.time(), 0
    while time.time() - t0 < a.seconds:
        A.wr("CTRL", 4)
        k += 1
        if k % 1000 == 0:
            print("soak: %d s, %d resends, crc_fails %d" % (time.time() - t0, A.rd("RESENDS"), B.rd("CRC_FAILS")))
    time.sleep(0.5)
    res, crc, sp, dn = A.rd("RESENDS"), B.rd("CRC_FAILS"), B.rd("SEQPOS_BAD"), B.rd("LINK_DOWNS")
    A.wr("CTRL", 2)
    print("soak: resends %d crc_fails %d seqpos_bad %d link_downs %d over %d s" % (res, crc, sp, dn, a.seconds))
    if dn == 0 and res != crc + sp:
        print("SOAK_FAIL accounting: resends %d != crc_fails %d + seqpos_bad %d" % (res, crc, sp)); return 1
    if crc == 0 and dn == 0:
        print("SOAK_PASS frames=%d crc_fails=0 link_downs=0" % res); return 0
    print("SOAK_FER %.3g frames=%d crc_fails=%d link_downs=%d" % (crc / max(res, 1), res, crc, dn))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Add to `tools/jc/test_jc_loop.py`:

```python
def test_soak_accounting_on_the_model():
    work = tempfile.mkdtemp(dir=os.path.expanduser("~/regress_scratch"))
    GV.write_programs(work)
    b, sock = broker(work, ["--loop", "--loop-pair", "A,B"])
    try:
        r = subprocess.run([sys.executable, os.path.join(HERE, "jc_link_soak.py"), "--sock", sock,
                            "--a", "A", "--b", "B", "--seconds", "3"], capture_output=True, text=True, timeout=120)
    finally:
        b.send_signal(signal.SIGTERM); b.wait(timeout=10)
    assert r.stdout.strip().splitlines()[-1].startswith("SOAK_PASS"), r.stdout
```

Run: `python3 -m pytest -q tools/jc/test_jc_loop.py`
Expected: `6 passed`. Commit:

```bash
git add tools/jc/jc_loop.py tools/jc/test_jc_loop.py tools/jc/jc_link_soak.py
git commit -m "jc loop T8 prep: jc_loop dump/fault options, link soak tool" -- \
  tools/jc/jc_loop.py tools/jc/test_jc_loop.py tools/jc/jc_link_soak.py
```

- [ ] **Step 3: Load the card and bring the dies up (MAIN SESSION)**

Preconditions (runbook section 2): nothing else holds the BMC (identify by `/proc/PID/exe`, never `pgrep -f`); `jccard_loop1` ended `^JCCARD_DONE`. Set the runbook section 1 variables in the shell, then override the work directory and define the host-path option set every later step uses (runbook 4.1's command, `--prompt`/`--max-new`/`--ids-out` left to each step):

```bash
export W=/mnt/storage/fk33_builds/jccard_loop1/silicon; mkdir -p $W/card0 $W/card1
RB=(--seq-reset --v2 --dtbl $W/card0/token.dtbl --rel $W/card0/token.rel
    --dtbl2 $W/card1/token.dtbl --rel2 $W/card1/token.rel
    --manifest $MAN0 --manifest2 $MAN1 --qtk $QTK --mv4i $EMB)
```

```bash
BIT=/mnt/storage/fk33_builds/jccard_loop1/results/jc_card.bit     # build_card.tcl:518 writes jc_card.bit
sha256sum $BIT | tee $W/bit.sha
sqrl_bridge C$BMC $BIT,$BIT skip 2>&1 | tee $W/load.log
grep -c 'Using Bitstream' $W/load.log        # want 2: device 0 and device 1, the same file
```

Then runbook 3.1 and 3.2 (token programs and side images, host only, into the new `$W`, FROM the -ownpc manifests, amendment A1), 3.3 (side images and weight images, one die at a time, broker not running), 3.4 (broker; gate `LANE_OK` and `FWD_OK`; the forward re-pointed at the current `JC_BCW`, A5) and 3.5 (seam ID, CAPS, image record on both dies). Then A2's host-path k1 anchor, A4's Aurora reset pulse, and the loop and the link:

```bash
cd $REPO && python3 - "$SOCK" <<'PY' | tee $W/loop_id.txt
import sys; sys.path.insert(0, "tools/jc"); import jc_loop as L
b = L.Broker(sys.argv[1])
for d in ("A", "B"):
    D = L.Die(b, d, 0x20000)
    print("LOOP_ID %s id=%#x caps=%#x link_status=%#x" % (d, D.rd("ID"), D.rd("CAPS"), D.br.call(
        {"die": d, "op": "rd32", "off": 0x20080})["val"]))
PY
```

Gate: both lines `id=0x544c5031`, CAPS `[15:0]` = 5120 with bits 16 and 17 set; die A link_status bit 0 (tx_channel_up), die B bit 1 (rx_channel_up), both bits 2 (GTG MMCM locked) and 3 (gt_pll_lock). If die B's rx_channel_up is 0: pulse `pma_init` on B then A (LINK_CTRL bit 1 high for 1 s, then low) and re-read; record the order that works (Task 5 Step 7's RX-after-TX answer predicts it). If it never rises: stop and record LINK_STATUS on both dies. (The `JC_LINK_RATE=1.25` rebuild that stood here is WITHDRAWN, amendment A3; do A4's reset pulse first.)

- [ ] **Step 4: GDN state at START (spec 1.5)**

Does SEQ_RESET's token-0 masking make stale GDN state harmless? Host path, so the answer is about the engine, not the loop:

```bash
P5=$W/p5.txt; tr -s ' \n' '\n' < $PROMPT | head -5 | tr '\n' ' ' > $P5
bash $REPO/hw/jc/host/jc_bc_lane.sh rezero | tee $W/rez1.log
$REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B "${RB[@]}" \
  --prompt $P5 --max-new 1 --stop -1 --ids-out $W/gdn_clean.ids --dump-xout2 $W/gdn_clean.xout
$REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B "${RB[@]}" \
  --prompt $PROMPT --max-new 1 --stop -1 --ids-out $W/gdn_dirty_pre.ids
$REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B "${RB[@]}" \
  --prompt $P5 --max-new 1 --stop -1 --ids-out $W/gdn_stale.ids --dump-xout2 $W/gdn_stale.xout
cmp $W/gdn_clean.xout $W/gdn_stale.xout && echo GDN_MASK_OK || echo GDN_MASK_STALE
```

`GDN_MASK_OK` (bit-identical die-B residual after a dirty 23-position run): no fill engine is needed, and the loop runs without re-zero. `GDN_MASK_STALE`: every later step re-zeroes before each run (`jc_bc_lane.sh rezero`), and a zero-fill on the gather's port is a follow-up plan (spec 1.5). Record the answer in the debugging file now.

- [ ] **Step 5: Link soak, 10 minutes (spec 4 step 1)**

```bash
cd $REPO/tools/jc && python3 jc_link_soak.py --sock $SOCK --a A --b B --seconds 600 | tee $W/soak.log
grep -E '^SOAK_(PASS|FER|FAIL)' $W/soak.log
```

Gate (accounting per amendment A7): `SOAK_PASS`, or `SOAK_FER <rate>` recorded as the measured frame error rate (the IBERT measurement was BER 1.7e-8 at 10.3125 Gb/s untuned: about 1.4e-3 frames of 82 kbit, DERIVED; a higher rate is a finding). `SOAK_FAIL accounting` is a defect in the deframer or the tool: stop.

- [ ] **Step 6: Hop transparency at positions 0, 3, 22 (spec 4 step 2)**

On the 27B card the seam's windows 2 and 3 are the same region, R_X (`hw/jc/card/jccard_const_allow.tcl`: `card/hw_reg` and `card/hr_reg` tied to R_X), so die B's input cannot be read back after its GO. The check compares die B's OUTPUT residual after the loop's hop with die B's output after the host's hop, for the same prompt prefix; the engine is deterministic (the context test's repeats), so equal outputs mean equal inputs (DERIVED; plan D17).

```bash
for k in 1 4 23; do
  tr -s ' \n' '\n' < $PROMPT | head -$k | tr '\n' ' ' > $W/hop_p$k.txt
  [[ -n "$REZERO" ]] && bash $REPO/hw/jc/host/jc_bc_lane.sh rezero > $W/hop_rez_h$k.log
  $REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B "${RB[@]}" \
    --prompt $W/hop_p$k.txt --max-new 1 --stop -1 --ids-out $W/hop_h$k.ids \
    --dump-xout $W/hop_h$k.a --dump-xout2 $W/hop_h$k.b
  [[ -n "$REZERO" ]] && bash $REPO/hw/jc/host/jc_bc_lane.sh rezero > $W/hop_rez_l$k.log
  $REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B "${RB[@]}" \
    --prompt $W/hop_p$k.txt --max-new 1 --stop -1 --ids-out $W/hop_open$k.ids --open-only
  python3 $REPO/tools/jc/jc_loop.py --sock $SOCK --die A --die2 B --prompt $W/hop_p$k.txt --max-new 1 \
    --stop -1 --mv4i $EMB --ids-out $W/hop_l$k.ids --dump-xout $W/hop_l$k.a --dump-xout2 $W/hop_l$k.b \
    | tee $W/hop_l$k.out
  cmp $W/hop_h$k.a $W/hop_l$k.a && cmp $W/hop_h$k.b $W/hop_l$k.b && echo "HOP_SAME k=$k" || echo "HOP_DIFF k=$k"
done | tee $W/hop.log
```

`REZERO=1` when Step 4 said `GDN_MASK_STALE`; `$EMB` is the runbook's mv4i path (`jc_ctxtest.sh`'s `JC_EMBED` default). Gate: three `HOP_SAME` lines. A `HOP_DIFF` with equal `.a` files and different `.b` files is the hop; with different `.a` files it is the row path (host rows from `PackedTensor.row_bfp` against `pl_embed_mv4i`): stop and root-cause either way.

- [ ] **Step 7: Tokens (spec 4 step 3) and the 500-token context test**

```bash
$REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B "${RB[@]}" \
  --prompt $PROMPT --max-new 16 --stop -1 --ids-out $W/tok_host.ids | tee $W/tok_host.out
$REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B "${RB[@]}" \
  --prompt $PROMPT --max-new 1 --stop -1 --ids-out $W/tok_open.ids --open-only
python3 $REPO/tools/jc/jc_loop.py --sock $SOCK --die A --die2 B --prompt $PROMPT --max-new 16 --stop -1 \
  --mv4i $EMB --ids-out $W/tok_loop.ids | tee $W/tok_loop.out
cmp $W/tok_host.ids $W/tok_loop.ids && echo IDS_SAME || echo IDS_DIFF
```

(re-zero between runs if Step 4 said so). Gate: `IDS_SAME` and `^JCLOOP_DONE ids=16`. Then the llama.cpp reference (runbook 4.2, `^REF_ARGMAX`): record the reference's first id next to the loop's first id. It is NOT a gate of this plan (plan D16): the card's own host-path argmax already differs from llama.cpp's (jccard10: 1206 vs 7732), and the loop is required to equal the host path, which is the oracle for what the loop changed. Write the wall time of `tok_loop.out` against `tok_host.out` (the per-token cost the loop removes, spec section 2) into the debugging file.

Then the standing post-build test (CLAUDE.md), host path and loop path:

```bash
hw/jc/host/jc_ctxtest.sh pair   /mnt/storage/fk33_builds/jccard_loop1/ctxtest/n500 500
hw/jc/host/jc_ctxtest.sh single /mnt/storage/fk33_builds/jccard_loop1/ctxtest/n500 500
JC_LOOP=1 hw/jc/host/jc_ctxtest.sh pair   /mnt/storage/fk33_builds/jccard_loop1/ctxtest/n500_loop 500
JC_LOOP=1 hw/jc/host/jc_ctxtest.sh single /mnt/storage/fk33_builds/jccard_loop1/ctxtest/n500_loop 500
grep -hE '^CTXTEST_(PASS|FAIL)' /mnt/storage/fk33_builds/jccard_loop1/ctxtest/*/ctxtest.log
```

(with the script's `JC_SOCK`, `JC_RUN0/1`, `JC_MAN0/1` environment as for every JC build). Gate: four `^CTXTEST_PASS` lines, and the loop runs' ids equal the host runs' ids (`cmp` the `*_r1.ids` files of each pair of directories).

- [ ] **Step 8: Fault injection (spec 4 step 4)**

```bash
$REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B "${RB[@]}" \
  --prompt $PROMPT --max-new 1 --stop -1 --ids-out $W/flt_open.ids --open-only
python3 $REPO/tools/jc/jc_loop.py --sock $SOCK --die A --die2 B --prompt $PROMPT --max-new 16 --stop -1 \
  --mv4i $EMB --ids-out $W/flt_loop.ids --fault-polarity-at 4 | tee $W/flt_loop.out
grep -E '^FAULT_PAUSED=1 JCLOOP_DONE' $W/flt_loop.out && cmp $W/tok_loop.ids $W/flt_loop.ids \
  && echo FAULT_PASS || echo FAULT_FAIL
```

Spec deviation D5: the fault is die A's TX polarity (the core has no runtime RX polarity), which die B sees as the same thing, a corrupted lane. Gate: `FAULT_PASS` (B paused, the RESEND after the fix resumed it, same 16 ids as Step 7). Record B's CRC_FAILS, LINK_DOWNS and A's RESENDS from `flt_loop.out`.

- [ ] **Step 9: Write the debugging record and commit it**

`docs/debugging/<date>_jc-loop-silicon.md`, in CLAUDE.md's order: the question (spec section 4's four steps, verbatim, with the date, `jccard_loop1`'s sha256, both dies, `JC_LINK_RATE`/`JC_LINK_REFCLK`); the answers up front (Step 4's GDN answer, soak result, HOP lines, IDS line, CTXTEST lines, FAULT line); the procedure (Steps 3-8 as run, each with what it isolates: Step 4 isolates the engine's GDN masking with the loop absent; Step 6 isolates the hop because both paths use the same rows and seam; Step 7's host run is the control for the loop run); the raw evidence (`$W/*.log`, `*.out` excerpts verbatim); Measured and REJECTED (do not retry); measurement traps; and an explicit open list (gather on silicon: the HBM address of the 27B embedding image is not grounded, so the silicon runs use host rows; phase 2 return link; lanes beyond 0; the board refclk on die 1; llama.cpp agreement, owned by the card numerics work).

```bash
git add docs/debugging/<date>_jc-loop-silicon.md
git commit -m "jc debugging: on-fabric loop and die-to-die link on silicon" -- docs/debugging/<date>_jc-loop-silicon.md
```

---

## Self-review record

- Spec coverage: section 1 (loop, seam master, ownership, row sources) Tasks 1, 2, 6; 1.4 gather Task 3 (9B card open, D1); 1.5 GDN Task 8 Step 4; 1b.1-1b.6 Tasks 4, 5, 6, 7 (phase 2 return link out of scope per spec); section 2 timing recorded in Task 8 Step 7; section 3 every row of the fault table is a Task 6 case (engine ERR F1, hang F2, seam error F3, ABORT F4/F5, host mid-run F6, CRC P2, seq/pos `tb_jc_link` C6/C7, link down P3, never arrives F9) and the recovery rules (hold, pause, RESEND, cap) are P2-P4 and F16; section 4 every unit row has its oracle and its named mutants (`tok_loop.json` T1-T4 for the four tok_loop mutants, `embed_gather.json` G1/G2, `jc_link.json` L1-L3, Task 5 Step 7 lane-map PERM 1), and the four silicon steps are Task 8 Steps 5-8.
- Review Focus 1-5: F12, F13, F11, F4/F5, F14 plus Task 2's back-to-back cases.
- Names checked across tasks: `tl_stat_t.link_wait` (Task 2 package, FSM, regs STATUS bit 18), `F_XW` (FSM, K1 and K4 anchors), FSM generics without RXDEPTH (Task 2, Task 6 `tok_loop` generic map), row-source ports `exp_valid/exp_val` (row_synth_src) against `rs_exp_valid/rs_exp` (FSM), `jc_link_rx` port names (Task 4, Task 5 bench, Task 6 `tok_loop`), `lk_beats` (Task 4 package, Task 6 pair bench), loop offsets (Task 2 map, Task 7 C model and `jc_loop.py`).
