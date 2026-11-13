# Subsystem A at 450 MHz, Per-Port Tiles: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Subsystem A closes at 450 MHz, routed, on the Jungle Cat part, as 24 self-contained per-port tiles in their own clock domain (`aclk_a`), with every output bit identical to today's `matvec_int4`.

**Architecture:** One `mv_tile` per HBM weight port owns its two rows end to end (AXI3 reader, LUTRAM codebook, 2 x 32 products on a DSP-style cascade, scale, accumulate, round, sat32). A distributor reads one x block per cycle from a true dual-port activation memory and broadcasts it, with the 48 merged scales, down a registered tree; tiles pace it with a registered "room" AND tree. Results leave through a 24-stage daisy chain and a 97-bit async FIFO into `clk_core`, where `mv_back` assembles the 48-row beat and runs the existing BFP fold and emit. `A_CLK_SPLIT` puts the tiles on `clk_core` (false) or on `aclk_a` (true).

**Tech Stack:** VHDL-2008 (GHDL 1.0.0 mcode for benches, Vivado 2023.2 for synthesis and route), Python 3 (model, generators, pytest), Tcl (block design and build scripts), the repo's `sim/regress.sh` gate, `sim/mutate_rows.py`, and `tools/rate/rate.py`.

**Spec:** `docs/superpowers/specs/2026-11-12-a450-per-port-tiles-design.md` (binding; read it in full before any task).

## Global Constraints

- No emojis, no em-dashes (code, comments, commit messages, docs).
- Values bit-exact with today's A: every `y_data`, `y_addr`, `y_mask`, `y_exp`, `err` and `sat_event` of every job equals `rtl/matvec_int4.vhd`'s.
- Routed WNS only: no timing figure is a result unless the run contains `route_design`. Placed or phys_opt WNS is never quoted.
- Subagents get no hardware access. Ever. No `xsdb`, `hw_server`, `vivado ... program`, `sqrl_bridge`, XVC, CoE (`tools/jc/coe.py`, `coe_load.py`), no broker against the BMC, no real runs of `hw/jc/host/jc_ctxtest.sh`, `jc_bc_lane.sh`, `jc_seam.py`, `run_prompt --jc`, nothing under `/dev/xdma*`, nothing that opens the Jungle Cat JTAG. Put this line in every subagent brief. Vivado in non-hardware modes (synth, route, `report_*`) is allowed.
- Nothing expensive under `/tmp` (the session scratchpad included); build roots under `/mnt/storage/fk33_builds/<tag>/`.
- Stage explicit paths only: never `git add -A`, never `git add .`. Never `git stash`. Never push. No Co-Authored-By line.
- One Vivado per box (presence by `/proc/PID/exe`, never `pgrep -f`). State the memory budget out loud before every Vivado run: resident now (`free -g`), the job's peak, what is left. The workstation has 31 GiB and `llama-server` holds about 18 GiB; stopping it is Oren's call.
- Never `pkill -f`, never `pgrep -f`, never a shell variable in a path passed to `rm`.
- Anchor every sentinel grep (`grep -qE '^SENTINEL'`).
- Never edit `sim/regress.sh` while a gate runs from the same tree.
- GHDL 1.0.0 identifiers are case-insensitive and cannot end in `_`: a variable `lf` hides a generic `LF`, a constant `NS` hides the time unit `ns`, a generic `RAM_STYLE` collides with the attribute `ram_style`. The code below already avoids all four; keep it that way when editing.

## Review Focus

The five input classes the spec implies but its own section 3.1 list does not name, most likely to bite first. Each has its test in the task that owns the code (all five are in `sim/tb_mv4i_tiled.vhd`, Task 6: its job table, whose fields are rows, cols, out_shift, mode, w_exp, x_exp, kind, and its port stall table `lpm`):

1. **A raw or partial job with `n_rows` above `MAXROWS_BFP` and one block per row (the LM-head shape).** Expected: identical beats; the BFP buffer index must not overflow (it did in the first draft of `mv_back`), and the result crossing fills because tiles finish a row-tile every few cycles while `clk_core` drains one word per cycle. Test: Task 6 job `(480, 32, 9, 1, 2, 3, 0)` with `MAXROWS_BFP` 240.
2. **A reset in the middle of a job, then a compared job.** Expected: no stale word from the killed job leaks into the next one (the chain, the crossing, every tile FIFO and every result FIFO clear). Test: Task 6 job `(96, 640, 4, 0, 0, 0, 2)` (kind 2: `rst` pulsed 300 cycles in, not compared), then job `(96, 640, 4, 0, 1, 1, 0)` compared.
3. **A codebook-only change with the same weights and x.** Expected: the new codebook reaches all 24 tiles' 64 LUTRAM copies before the first ITEM flit of the job. Test: Task 6 job `(480, 32, 9, 2, 0, 0, 3)` (kind 3: the previous job's weights and x, a new codebook, partial mode).
4. **Scale-port starvation stalling every tile at once.** Expected: no tile underflows or reorders; all tiles stop together because ITEM flits need all three scale words. Test: Task 6 SPLIT DUT scale port index 25 with 300-cycle stalls (`lpm`).
5. **Tile drift and credit exhaustion under long weight-port stalls.** Expected: the room tree stops the distributor before any tile flit FIFO overflows; the bench's overrun assertion never fires. Test: Task 6 job 16 `(480, 640, 9, 1, 1, 2, 0)` (200 items per tile, past the 64-beat weight FIFO) with SPLIT weight port 13 stalled about 70% of the time, plus the credit-loss mutant `C1` in `sim/mutants/mv4i_tiled.json` that must be KILLED (it survived twice before job 16 and the heavier port 13 stalls were added).

## Rulings where the RTL contradicted the spec

These were found while grounding the plan in the RTL. Each is a deliberate deviation; the reason is the RTL.

- **R1. BFP needs the whole matrix.** The BFP mode (`out_mode` 00) folds `amax` over all rows of the job and emits only after the fold (`rtl/matvec_core.vhd`, SCAN/EMIT). A tile sees two rows. So the tile ends at sat32 and the sat flag; the 48-row assembly, the BFP buffer, the fold and SCAN/EMIT stay central in `clk_core` (`rtl/mv_back.vhd`). Spec 1.2's "BFP/raw/partial output modes" in the tile is honoured for the per-row arithmetic only.
- **R2. The descriptor fetch stays in `clk_core`** (spec 2.4 says it moves to `aclk_a`). Its existing DUAL_CLK fetch port already puts the AXI half on `m_aclk`, which is `aclk_a` when split. Only start (a toggle through `mv_tsync`) and the result words cross; done, err and sat are produced on the `clk_core` side by `mv_back`.
- **R3. Words cross, the beat is assembled in `clk_core`** (spec 2.3 assembles the 48-row beat in `aclk_a`). Each result is a 97-bit word (2 x 48-bit values plus sat) crossing through `mv_rcross` (async FIFO, 16 deep). Assembling 3,072 bits in `aclk_a` would need a 2.3k-flop shared enable at 450 MHz, the exact net shape this design exists to remove.
- **R4. Credits are a registered room level, not counted credits.** Each tile raises `room` while its flit FIFO level is below `XD - SLACK`; an AND tree (`mv_xbcast`) gives `room_all`. `SLACK = LF + LR + 4 = 12` with `XD = 32` (MEASURED in Task 4's bench: SLACK 3 overflows, 8 passes).
- **R5. Pad columns are zeroed by the distributor**, so the tile needs no `n_cols`.
- **R6. B and C reach `aclk_a` through `axi_clock_converter` and a two-clock smartconnect**, not `axi_rd_port DUAL_CLK` (spec 1.1): their masters read and write. Loader SAXI_00 and grant SAXI_30/31 get one converter each; the SAXI_16 smartconnect gets `NUM_CLKS 2`.
- **R7. `aclk_a` comes from a second MMCM** (`clk_wiz_a`, fed from `clk_wiz_0/clk_out2`). 125 and 450 MHz have no common VCO in range on one MMCM.
- **R8. `BEATS` under `A_TILED`** grows by `nb` per row-tile, so the total equals today's (one per weight beat per port); `STARVED` reads 0. A's util counters already count on `m_aclk`, which is `aclk_a` when split, so `jobcyc / port beats` is in `aclk_a` cycles as spec 3.3 asks.
- **R9. New rating rows use tier `anchor`**, since `rate.py preflight` refuses unrated rows of other tiers; and a new device row `vu35p_jc_2l85` rates the `-2L` part at 0.85 V (spec 0). The 25 STALE rows `rate.py status --check` reports are stale on the jc-loop HEAD this plan starts from (MEASURED 2026-11-12, before any edit); this plan does not refresh them and gates on its own rows by name.
- **R10. `stream_fifo` is not edited.** It is in the GHDL closure of every A rating; a new generic would re-key them. The tile's small FIFOs are `rtl/mv_lfifo.vhd`, a FAST_POP copy in distributed RAM.

## Memory budget (quote these, not older figures)

| Job | Peak | Where | Notes |
|---|---|---|---|
| GHDL `tb_mv_tile`, `tb_mv_dist`, `tb_mv_rchain` | under 0.5 GB each | either box | seconds |
| GHDL `tb_mv4i_tiled` | 3.7 GB RSS (MEASURED, `/usr/bin/time -v`) | workstation | 11 to 14 min quiet, about 45 min under a parallel gate |
| GHDL `tb_matvec_fk33_desc_tiled` | 1.25 GB RSS (MEASURED) | workstation | 44 min quiet (MEASURED) |
| Vivado `a450_tile` OOC route | ESTIMATE 4 GB (one tile is 1/24 of `a_engine`, whose route peaked at the 16 GB cap) | workstation with `llama-server` up, `--mem 6G` | |
| Vivado `a450_afast` OOC route | ESTIMATE 16 to 20 GB (same cell count as `a_engine`, MEASURED 16.66 GB at a 16G cap with 2.4 GB swap, so its appetite is higher) | workstation, `llama-server` stopped (Oren's call), `--mem 20G` | |
| Vivado a450 A+HBM design | ESTIMATE 20 to 24 GB | workstation, `llama-server` stopped, `MemoryHigh 24G`, swap kill 8 GiB | |
| JC card build | about 47 GB including swap (MEASURED) | workstation alone, `llama-server` stopped, swap guard 30 GiB | Oren's go |

## File Structure

New files:

| Path | Responsibility | Task |
|---|---|---|
| `tools/mv_tile_model.py` | Independent A arithmetic model (imports only `tools/gen_arith.py`); selftest against `ref/matvec_int4.c --trace`; writes and checks `sim/mv_tile_vec.txt` | 1 |
| `sim/mv_tile_vec.txt` | Generated per-tile vectors (26 cases) | 1 |
| `rtl/mv_lfifo.vhd` | Small FWFT FIFO in distributed RAM, FAST_POP cadence | 2 |
| `rtl/mv_tile.vhd` | One weight port's tile: AXI reader, flit FIFO, codebook, cascade MAC, scale, accumulate, round, sat32, result FIFO | 2 |
| `sim/axi_rd_mem_model.vhd` | AXI3 read slave with its own memory, random RVALID gaps and long stalls | 2 |
| `sim/tb_mv_tile.vhd` | Tile bench against `sim/mv_tile_vec.txt` | 2 |
| `sim/mutants/mv_tile.json`, `sim/mutants/mv_tile_attr.json` | Tile mutants and the attribution control | 2 |
| `rtl/act_mem_dp.vhd` | True dual-port activation memory (write `clk_core`, read `aclk_a`) | 4 |
| `rtl/mv_xbcast.vhd` | Registered broadcast tree and room AND tree | 4 |
| `rtl/mv_dist.vhd` | Distributor: PARAM, codebook and ITEM flits, scale ports, pad masking | 4 |
| `sim/tb_mv_dist.vhd`, `sim/mutants/mv_dist.json` | Distributor bench and mutants | 4 |
| `rtl/mv_tsync.vhd` | Toggle pulse synchronizer | 5 |
| `rtl/mv_rlink.vhd`, `rtl/mv_rchain.vhd` | Result daisy chain stage and chain | 5 |
| `rtl/mv_rcross.vhd` | 97-bit result crossing with registered almost-full | 5 |
| `sim/tb_mv_rchain.vhd`, `sim/mutants/mv_rchain.json` | Chain and crossing bench and mutants | 5 |
| `rtl/mv_afast.vhd` | `aclk_a` composition: distributor, tree, 24 tiles, chain | 6 |
| `rtl/mv_back.vhd` | `clk_core` back end: checks, job params, beat assembly, BFP fold and emit | 6 |
| `rtl/mv4i_tcore.vhd` | Both domains wired: back end, start sync, dual-port x, fast half, crossing | 6 |
| `rtl/mv4i_tiled.vhd` | `matvec_int4`-compatible wrapper with `A_CLK_SPLIT` | 6 |
| `sim/tb_mv4i_tiled.vhd`, `sim/mutants/mv4i_tiled.json` | Composed equivalence bench (old vs split vs same) and the credit-loss mutant | 6 |
| `rtl/a450_stub_seq.vhd` | LFSR job generator for the timing design | 7 |
| `hw/jc/a450/gen_a450_hbm_top.py`, `hw/jc/a450/a450_hbm_top.vhd` | Generator and generated top for the A+HBM design | 7 |
| `hw/jc/a450/a450_bd.tcl`, `a450.xdc`, `a450_cdc.tcl`, `a450_pblocks.tcl`, `build_a450.tcl`, `run_a450.sh`, `test_a450.py` | The A+HBM 450 MHz timing design and its run script | 7 |
| `sim/tb_matvec_fk33_desc_tiled.vhd` | Descriptor-plane bench through the tiled A | 8 |

Modified files:

| Path | Change | Task |
|---|---|---|
| `hw/targets/devices.json`, `hw/targets/blocks.json` | Device row `vu35p_jc_2l85`; rows `a450_tile` (Task 3), `a450_afast` (Task 7) | 3, 7 |
| `sim/regress.sh` | Per-row timeout for `tb_mv4i_tiled` (Task 6); the `tb_matvec_fk33_desc_tiled` row (Task 8) | 6, 8 |
| `rtl/matvec_int4_desc_axi.vhd` | Generics `A_TILED`, `A_CLK_SPLIT`; `mv4i_tiled` as a component under `A_TILED`; BEATS by words | 8 |
| `sim/tb_matvec_fk33_desc.vhd` | Generics `TILED`, `SPLIT` forwarded | 8 |
| `hw/fk33/gen_fk33_engine.py`, `hw/fk33/rtl/fk33_engine.vhd` | Engine generics `A_TILED`, `A_CLK_SPLIT` (above the LEVER block so `build12_levers_off.patch` still applies) | 8 |
| `hw/jc/card/gen_jc_card.py`, `hw/jc/card/jc_card_bd.tcl` | `JC_A_TILED`, `JC_A_CLK_SPLIT`; split-on clocking (`clk_wiz_a`, `aclk_reset`, converters, HBM at 450) | 8 (generator, split off), 9 (split-on render used) |
| `hw/jc/card/build_card.tcl`, `hw/jc/card/run_card.sh` | Tiled sources; split-on CDC constraints; env echo and provenance | 8 |
| `hw/jc/card/test_gen_jc_card.py`, `hw/jc/card/test_run_card.py` | Tests for the above | 8 |

## Task order and why it is not merged

The nine tasks follow spec section 4 one to one. None is merged: each ends with its own independently checkable deliverable (a model selftest, a unit bench plus mutants, a routed rating, a composed equivalence bench, a routed system design, a silicon gate). Task 3 and Task 7 are Vivado-only and can run while the next GHDL task is written, as long as only one Vivado runs on the box.

---
### Task 1: Tile model and vectors

**Files:**
- Create: `tools/mv_tile_model.py`
- Create (generated): `sim/mv_tile_vec.txt`

**Interfaces:**
- Consumes: `tools/gen_arith.py` (`floor_shr`, `round_shift`, `sat16`, `sat32`, `msb_pos_u`), `ref/matvec_int4.c` (built by the selftest with `cc -O2 -w -I ref -o <exe> ref/matvec_int4.c -lm`, run as `<exe> --trace <file> n_rows n_cols ROWS_IF mode`).
- Produces: `sim/mv_tile_vec.txt`, read by `sim/tb_mv_tile.vhd` (Task 2). Format, one record per line:
  - `CASE <id> <out_shift> <mode 0|1|2> <nb> <ntiles>`
  - `CB <16 signed ints>` (codebook entries 0..15)
  - `B <t> <b> <w256 hex> <x512 hex> <s32 hex> <first 0|1> <last 0|1>` (row-tile t, block b; `w` is the port beat, row 0 nibbles in bits 127:0 and row 1 in 255:128; `x` is 32 x 16-bit; `s` is row 0's scale in 15:0 and row 1's in 31:16)
  - `R <t> <v0 hex12> <v1 hex12> <sat 0|1>` (the two 48-bit results of row-tile t: sat32 values sign-extended for modes 0 and 1, the raw accumulator for mode 2)
  - `END`, and the last line `DONE <ncases>`
- Sentinels: `^MV_TILE_MODEL_SELFTEST_OK`, `^MV_TILE_VEC_WROTE`, `^MV_TILE_VEC_CHECK OK`.

- [ ] **Step 1: Run the selftest before the model exists**

Run: `python3 tools/mv_tile_model.py --selftest`
Expected: FAIL, `can't open file ... tools/mv_tile_model.py`.

- [ ] **Step 2: Write the model**

`tools/mv_tile_model.py`:

```python
#!/usr/bin/env python3
"""tools/mv_tile_model.py -- the subsystem A arithmetic model the 450 MHz tile is checked against.

WHY THIS EXISTS.  docs/superpowers/specs/2026-11-12-a450-per-port-tiles-design.md 3.1 names
the oracle for rtl/mv_tile.vhd: an INDEPENDENT implementation of the A arithmetic, not the
RTL's own structure.  This file is that implementation.  It shares no code with the RTL and
none with ref/matvec_int4.c: its only import is tools/gen_arith.py, the authority that the C
reference and rtl/mv4i_arith_pkg.vhd are both GENERATED from.

    tools/mv_tile_model.py --selftest     the model against ref/matvec_int4.c --trace, three
                                          traces, plus a negative control that must DIFFER
    tools/mv_tile_model.py --write        write sim/mv_tile_vec.txt
    tools/mv_tile_model.py --check        regenerate in memory and compare with the file

Sentinels (line-anchored): ^MV_TILE_MODEL_SELFTEST_OK, ^MV_TILE_MODEL_SELFTEST_FAIL,
^MV_TILE_VEC_WROTE, ^MV_TILE_VEC_CHECK OK|STALE.

THE CONTRACT MODELLED (spec 2026-08-20 7.4, as rtl/matvec_core.vhd implements it):
  partial = sum_j cb[idx] * x_j over one 32-column block (pad columns contribute 0); the
            C reference asserts |partial| < 2^27 (s28), and so does this model
  contrib = floor_shr(partial * scale, 15)          scale is the 16-bit field, MSB 0
  acc     = sum over blocks of contrib              s48
  raw     = sat32(round_shift(acc, out_shift))      modes 00 and 01
  sat     = raw != round_shift(acc, out_shift)      modes 00 and 01 only, EVERY row of every
            issued row-tile, pad rows included (matvec_core re2 loops rr over all ROWS_IF)
  partial mode 10 emits acc unrounded and never saturates
  BFP (00): ns = max(0, msb_pos(max |raw| over rows < n_rows) - 14),
            mant = sat16(round_shift(raw, ns)), y_exp = w_exp + x_exp - out_shift - ns
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from gen_arith import floor_shr, round_shift, sat16, sat32, msb_pos_u  # noqa: E402

BLK = 32
VEC = os.path.join(REPO, "sim", "mv_tile_vec.txt")
SEED = 20261112


def block_partial(cb, idx_blk, x_blk):
    """One row, one block: idx_blk and x_blk are BLK ints each (pad columns already 0)."""
    p = 0
    for j in range(BLK):
        p += cb[idx_blk[j]] * x_blk[j]
    assert -(1 << 27) < p < (1 << 27), "partial %d leaves s28: outside the C contract" % p
    return p


def row_acc(cb, idx_row, scale_row, xpad):
    """idx_row: NB*BLK nibbles, scale_row: NB scales, xpad: NB*BLK x values, pad zeroed."""
    acc = 0
    for b in range(len(scale_row)):
        p = block_partial(cb, idx_row[b * BLK:(b + 1) * BLK], xpad[b * BLK:(b + 1) * BLK])
        c = floor_shr(p * scale_row[b], 15)
        assert -(1 << 28) <= c < (1 << 28), "contrib leaves s29"
        acc += c
    assert -(1 << 47) <= acc < (1 << 47), "acc leaves s48"
    return acc


def row_out(acc, out_shift, mode):
    """(value the tile emits, sat bit).  mode: 0 BFP, 1 raw, 2 partial."""
    if mode == 2:
        return acc, 0
    r = round_shift(acc, out_shift)
    a = sat32(r)
    return a, int(a != r)


def matvec(cb, idx, scale, x, n_rows, n_cols, out_shift, mode, w_exp, x_exp, rows_if):
    """Whole-matrix model.  idx/scale are given for ceil(n_rows/rows_if)*rows_if rows (pad
    rows included, as the hardware reads them).  Returns dict(y, y_exp, sat, acc, ns)."""
    nb = (n_cols + BLK - 1) // BLK
    xpad = [x[k] if k < n_cols else 0 for k in range(nb * BLK)]
    acc = [row_acc(cb, idx[r], scale[r], xpad) for r in range(len(idx))]
    outs = [row_out(a, out_shift, mode) for a in acc]
    sat = int(any(s for (_, s) in outs))
    if mode == 2:
        return {"y": acc[:n_rows], "y_exp": w_exp + x_exp, "sat": sat, "acc": acc, "ns": None}
    raw = [v for (v, _) in outs]
    if mode == 1:
        return {"y": raw[:n_rows], "y_exp": w_exp + x_exp - out_shift, "sat": sat,
                "acc": acc, "ns": None}
    amax = max(abs(v) for v in raw[:n_rows])
    ns = max(0, msb_pos_u(amax) - 14)
    mant = [sat16(round_shift(v, ns)) for v in raw[:n_rows]]
    return {"y": mant, "y_exp": w_exp + x_exp - out_shift - ns, "sat": sat, "acc": acc,
            "ns": ns, "raw": raw}


# --------------------------------------------------------------------------- selftest
def parse_trace(path):
    t = {"cb": [0] * 16, "x": {}, "scale": {}, "idx": {}, "acc": {}, "ydata": {}, "ymant": {}}
    for ln in open(path):
        f = ln.split()
        if not f or f[0].startswith("#"):
            continue
        k = f[0]
        if k == "DIMS":
            t["M"], t["K"], t["NB"], t["os"], t["w_exp"], t["x_exp"], t["RI"] = map(int, f[1:8])
        elif k == "CB":
            t["cb"][int(f[1])] = int(f[2])
        elif k == "X":
            v = int(f[2], 16)
            t["x"][int(f[1])] = v - 65536 if v >= 32768 else v
        elif k == "SCALE":
            t["scale"][(int(f[1]), int(f[2]))] = int(f[3], 16)
        elif k == "IDX":
            t["idx"][(int(f[1]), int(f[2]))] = int(f[3])
        elif k in ("ACC", "YDATA", "YMANT"):
            v = int(f[2], 16)
            t[k.lower()][int(f[1])] = v - (1 << 64) if v >= (1 << 63) else v
        elif k == "NS":
            t["ns"] = int(f[1])
        elif k == "YEXP":
            t["yexp"] = int(f[1])
    return t


def check_trace(t, perturb=False):
    M, K, NB = t["M"], t["K"], t["NB"]
    idx = [[t["idx"].get((r, k), 0) for k in range(NB * BLK)] for r in range(M)]
    scale = [[t["scale"][(r, b)] for b in range(NB)] for r in range(M)]
    if perturb:
        scale[0][0] ^= 1
    x = [t["x"][k] for k in range(K)]
    m = matvec(t["cb"], idx, scale, x, M, K, t["os"], 0, t["w_exp"], t["x_exp"], t["RI"])
    bad = 0
    for r in range(M):
        bad += m["acc"][r] != t["acc"][r]
        bad += m["raw"][r] != t["ydata"][r]
        bad += m["y"][r] != t["ymant"][r]
    bad += m["ns"] != t["ns"]
    bad += m["y_exp"] != t["yexp"]
    return bad


def selftest(work):
    os.makedirs(work, exist_ok=True)
    exe = os.path.join(work, "mv4i_ref")
    subprocess.run(["cc", "-O2", "-w", "-I", os.path.join(REPO, "ref"), "-o", exe,
                    os.path.join(REPO, "ref", "matvec_int4.c"), "-lm"], check=True)
    n = 0
    for argv in (["8", "96", "4", "0"], ["8", "1024", "4", "1"], ["50", "200", "48", "0"]):
        tr = os.path.join(work, "tr_%s.txt" % "_".join(argv))
        subprocess.run([exe, "--trace", tr] + argv, check=True, stdout=subprocess.DEVNULL)
        t = parse_trace(tr)
        bad = check_trace(t)
        if bad:
            print("MV_TILE_MODEL_SELFTEST_FAIL trace %s: %d fields differ" % (" ".join(argv), bad))
            return 1
        if check_trace(t, perturb=True) == 0:
            print("MV_TILE_MODEL_SELFTEST_FAIL trace %s: a perturbed scale still agrees "
                  "(the comparison has no teeth)" % " ".join(argv))
            return 1
        n += 1
    print("MV_TILE_MODEL_SELFTEST_OK %d traces agree with ref/matvec_int4.c, perturbation detected"
          % n)
    return 0


# --------------------------------------------------------------------------- vectors
def hexs(v, bits):
    return format(v & ((1 << bits) - 1), "0%dX" % (bits // 4))


def gen_case(rng, cid, os_, mode, nb, ntiles, kind):
    """One tile case: 2 rows per row-tile.  Returns the vector-file lines."""
    if kind == "sat":
        cb = [-127] + [rng.randint(-127, 127) for _ in range(15)]
    else:
        cb = [rng.randint(-127, 127) for _ in range(16)]
    n_cols = nb * BLK - (rng.randint(0, BLK - 1) if kind == "pad" else 0)
    out = ["CASE %d %d %d %d %d" % (cid, os_, mode, nb, ntiles),
           "CB " + " ".join(str(c) for c in cb)]
    res = []
    for t in range(ntiles):
        if kind == "sat":
            x = [-32768] * (nb * BLK)
        else:
            x = [rng.randint(-32768, 32767) for _ in range(nb * BLK)]
        xpad = [x[k] if k < n_cols else 0 for k in range(nb * BLK)]
        idx = [[0 if kind == "sat" else rng.randint(0, 15) for _ in range(nb * BLK)]
               for _ in range(2)]
        if kind == "sat":
            sc = [[32767] * nb for _ in range(2)]
        elif kind == "zscale":
            sc = [[0] * nb, [rng.randint(0, 32767) for _ in range(nb)]]
        else:
            sc = [[rng.randint(0, 32767) for _ in range(nb)] for _ in range(2)]
        for b in range(nb):
            w = 0
            for r in range(2):
                for j in range(BLK):
                    w |= idx[r][b * BLK + j] << (4 * (r * BLK + j))
            xw = 0
            for j in range(BLK):
                xw |= (xpad[b * BLK + j] & 0xFFFF) << (16 * j)
            s = sc[0][b] | (sc[1][b] << 16)
            out.append("B %d %d %s %s %s %d %d" % (t, b, hexs(w, 256), hexs(xw, 512), hexs(s, 32),
                                                  int(b == 0), int(b == nb - 1)))
        vals = []
        sat = 0
        for r in range(2):
            a = row_acc(cb, idx[r], sc[r], xpad)
            v, s = row_out(a, os_, mode)
            vals.append(v)
            sat |= s
        res.append("R %d %s %s %d" % (t, hexs(vals[0], 48), hexs(vals[1], 48), sat))
    return out + res + ["END"]


def gen_vectors():
    rng = random.Random(SEED)
    lines = ["# GENERATED by tools/mv_tile_model.py --write -- DO NOT EDIT",
             "# CASE id out_shift mode nb ntiles / CB 16 ints / B t b w256 x512 s32 first last /",
             "# R t v0 v1 sat (v = 48-bit two's complement the tile emits) / END"]
    cases = []
    for os_ in (0, 1, 3, 15, 31, 40):
        for mode in (0, 1, 2):
            cases.append((os_, mode, rng.randint(1, 6), rng.randint(1, 4), "rand"))
    for mode in (0, 1, 2):
        cases.append((0, mode, 40, 2, "sat"))
    cases.append((7, 1, 5, 3, "pad"))
    cases.append((7, 0, 5, 3, "pad"))
    cases.append((9, 1, 3, 2, "zscale"))
    cases.append((12, 1, 160, 1, "rand"))
    cases.append((5, 2, 1, 6, "rand"))
    for cid, (os_, mode, nb, nt, kind) in enumerate(cases):
        lines += gen_case(rng, cid, os_, mode, nb, nt, kind)
    lines.append("DONE %d" % len(cases))
    return "\n".join(lines) + "\n"


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest(os.environ.get("MV_TILE_WORK", "/mnt/storage/fk33_builds/scratch/mv_tile_model"))
    if argv[1:] == ["--write"]:
        txt = gen_vectors()
        open(VEC, "w").write(txt)
        print("MV_TILE_VEC_WROTE %s %d lines" % (VEC, txt.count("\n")))
        return 0
    if argv[1:] == ["--check"]:
        ok = os.path.exists(VEC) and open(VEC).read() == gen_vectors()
        print("MV_TILE_VEC_CHECK %s" % ("OK" if ok else "STALE"))
        return 0 if ok else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 3: Run the selftest**

Run: `python3 tools/mv_tile_model.py --selftest`
Expected: `MV_TILE_MODEL_SELFTEST_OK 3 traces agree with ref/matvec_int4.c, perturbation detected`. The selftest is its own teeth check: it perturbs one field of each trace and requires the comparison to fail (prints `MV_TILE_MODEL_SELFTEST_FAIL ... (the comparison has no teeth)` otherwise).

- [ ] **Step 4: Write and check the vectors**

Run: `python3 tools/mv_tile_model.py --write && python3 tools/mv_tile_model.py --check`
Expected: `MV_TILE_VEC_WROTE sim/mv_tile_vec.txt 712 lines` then `MV_TILE_VEC_CHECK OK`. The file is 124,791 bytes with 67 `R` lines, 4 of them with sat 1 (`grep -c '^R ' sim/mv_tile_vec.txt` gives 67; `grep -cE '^R .* 1$' sim/mv_tile_vec.txt` gives 4).

- [ ] **Step 5: Commit**

```bash
git add tools/mv_tile_model.py sim/mv_tile_vec.txt
git commit -m "a450 Task 1: independent tile model, selftest against ref/matvec_int4.c, 26 vector cases"
```

---

### Task 2: `mv_tile` RTL, bench and mutants

**Files:**
- Create: `rtl/mv_lfifo.vhd`, `rtl/mv_tile.vhd`
- Create: `sim/axi_rd_mem_model.vhd`, `sim/tb_mv_tile.vhd`
- Create: `sim/mutants/mv_tile.json`, `sim/mutants/mv_tile_attr.json`

**Interfaces:**
- Consumes: `sim/mv_tile_vec.txt` (Task 1); `rtl/axi_rd_port.vhd` (`DUAL_CLK false`, `FAST_POP true`), `rtl/mv4i_arith_pkg.vhd` (`floor_shr`, `round_shift`, `sat32`), `rtl/util_pkg.vhd` (`clog2`).
- Produces:
  - `entity mv_lfifo generic(W : positive := 64; DEPTH : positive := 32) port(clk, rst; i_valid; i_data(W-1:0); i_ready; q_valid; q_data(W-1:0); q_ready; level : out integer)`.
  - `entity mv_tile generic(BLK 32, AXI_DW 256, ADDR_W 40, DEPTH 512, MAXB 16, MAXOUT 16, XD 32, SLACK 12, RD 4) port(clk, rst; w_base(ADDR_W-1:0); w_beats : integer; arvalid, arready, araddr, arlen(7:0), arsize(2:0), arburst(1:0), rvalid, rready, rdata(AXI_DW-1:0), rlast; f_v; f_kind(1:0); f_x(BLK*16-1:0); f_s(31:0); f_first; f_last; room; r_v; r_d(96:0); r_rdy)`.
  - Flit kinds on `f_kind`: `"10"` PARAM (`f_x(5:0)` out_shift, `f_x(7:6)` mode; it also starts the weight port for `w_beats` beats at `w_base`), `"01"` CB (`f_x(3:0)` address, `f_x(11:4)` data), `"00"` ITEM (one block: x, both scales, first and last block of the row-tile). `f_s`, `f_first`, `f_last` are don't-care on PARAM and CB.
  - Result word `r_d`: `r_d(47:0)` row 0, `r_d(95:48)` row 1, `r_d(96)` sat (modes 00 and 01: either row's sat32 clipped; mode 10: 0).
  - `room` is registered: '1' while the flit FIFO level is below `XD - SLACK`.
  - `entity axi_rd_mem_model generic(AXI_DW, ADDR_W, NWORDS, SEED, GAPPCT, LONGPM, LONGLEN, QD)` with a bench write port `wr_en, wr_addr : natural, wr_data`.

- [ ] **Step 1: Write the AXI read model and the bench**

`sim/axi_rd_mem_model.vhd`:

```vhdl
-- sim/axi_rd_mem_model.vhd -- an AXI read slave with its own word memory, random RVALID
-- gaps, random ARREADY, and optional long stalls.  Bench-side only (no UNISIM).
--
-- The bench fills the memory through wr_en/wr_addr/wr_data (one AXI_DW word per cycle,
-- word address = byte address / (AXI_DW/8)).  Bursts are queued in arrival order (up to
-- QD outstanding) and answered in order; RVALID, once raised, holds until RREADY, as AXI
-- requires.  GAPPCT is the percentage of cycles a beat is withheld; LONGPM is the
-- per-mille chance per cycle of starting a LONGLEN-cycle stall, which is what drains a
-- tile's credits in the composed bench.  An address outside the memory is a failure.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_rd_mem_model is
  generic(
    AXI_DW  : positive := 256;
    ADDR_W  : positive := 40;
    NWORDS  : positive := 1024;
    SEED    : positive := 1;
    GAPPCT  : natural  := 30;
    LONGPM  : natural  := 0;
    LONGLEN : natural  := 200;
    QD      : positive := 32
  );
  port(
    clk, rst : in  std_logic;
    arvalid  : in  std_logic;
    arready  : out std_logic;
    araddr   : in  std_logic_vector(ADDR_W-1 downto 0);
    arlen    : in  std_logic_vector(7 downto 0);
    rvalid   : out std_logic;
    rready   : in  std_logic;
    rdata    : out std_logic_vector(AXI_DW-1 downto 0);
    rlast    : out std_logic;
    wr_en    : in  std_logic;
    wr_addr  : in  natural;
    wr_data  : in  std_logic_vector(AXI_DW-1 downto 0)
  );
end entity;

architecture sim of axi_rd_mem_model is
  type mem_t is array(0 to NWORDS-1) of std_logic_vector(AXI_DW-1 downto 0);
  signal mem : mem_t := (others => (others => '0'));
  signal ar_r, rv_r, rl_r : std_logic := '0';
  signal rd_r : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
begin
  arready <= ar_r;
  rvalid  <= rv_r;
  rlast   <= rl_r;
  rdata   <= rd_r;

  p : process(clk)
    type q_t is array(0 to QD-1) of natural;
    variable qa, ql : q_t;
    variable qh, qt, qn : natural := 0;
    variable cur, left : natural := 0;
    variable busy : boolean := false;
    variable lf : unsigned(31 downto 0) := to_unsigned((SEED * 7919 + 12345) mod 2147483647, 32);
    variable stall : natural := 0;
    variable go : boolean;
    function nxt(v : unsigned(31 downto 0)) return unsigned is
      variable x : unsigned(31 downto 0) := v;
    begin
      x := x xor shift_left(x, 13);
      x := x xor shift_right(x, 17);
      x := x xor shift_left(x, 5);
      return x;
    end function;
  begin
    if rising_edge(clk) then
      if wr_en = '1' then
        assert wr_addr < NWORDS report "axi_rd_mem_model: bench write past NWORDS" severity failure;
        mem(wr_addr) <= wr_data;
      end if;
      if rst = '1' then
        qh := 0; qt := 0; qn := 0; busy := false; stall := 0;
        ar_r <= '0'; rv_r <= '0'; rl_r <= '0';
      else
        -- AR
        if arvalid = '1' and ar_r = '1' then
          qa(qt) := to_integer(unsigned(araddr)) / (AXI_DW/8);
          ql(qt) := to_integer(unsigned(arlen)) + 1;
          qt := (qt + 1) mod QD; qn := qn + 1;
        end if;
        lf := nxt(lf);
        if qn < QD - 1 and to_integer(lf(7 downto 0)) mod 100 >= GAPPCT / 2 then
          ar_r <= '1';
        else
          ar_r <= '0';
        end if;
        -- R: a beat leaves on the handshake
        if rv_r = '1' and rready = '1' then
          rv_r <= '0';
          if left = 0 then busy := false; end if;
        end if;
        if not busy and qn > 0 then
          cur := qa(qh); left := ql(qh);
          qh := (qh + 1) mod QD; qn := qn - 1; busy := true;
        end if;
        lf := nxt(lf);
        if stall > 0 then
          stall := stall - 1;
        elsif LONGPM > 0 and to_integer(lf(19 downto 10)) < LONGPM then
          stall := LONGLEN;
        end if;
        go := stall = 0 and to_integer(lf(29 downto 22)) mod 100 >= GAPPCT;
        if busy and left > 0 and go and not (rv_r = '1' and rready = '0') then
          assert cur < NWORDS report "axi_rd_mem_model: read past NWORDS" severity failure;
          rd_r <= mem(cur);
          rv_r <= '1';
          if left = 1 then rl_r <= '1'; else rl_r <= '0'; end if;
          cur := cur + 1; left := left - 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
```

`sim/tb_mv_tile.vhd` (plays the distributor, with a tree delay of `LF` cycles on flits and `LR` on room, random flit gaps `FGAP`% and result back-pressure `RGAP`%). This bench does not stress the credit loop: the 512-beat weight FIFO prefetches during PARAM and CB, so the tile pops one flit per cycle and its flit FIFO never fills (MEASURED: `-gSLACK=3 -gFGAP=0 -gRGAP=90` still passes). The credit sweep is Task 4's, where tile 0 stalls:

```vhdl
-- sim/tb_mv_tile.vhd -- rtl/mv_tile.vhd against tools/mv_tile_model.py.
--
-- Vectors: sim/mv_tile_vec.txt (tools/mv_tile_model.py --write; --check proves it is
-- current).  Every expected value comes from that model, which is checked against
-- ref/matvec_int4.c by `tools/mv_tile_model.py --selftest`; nothing here computes one.
--
-- Per case: the weight beats go into an AXI read model (random RVALID gaps), then the
-- bench plays the distributor: a PARAM flit (which starts the tile's weight port), 16 CB
-- flits, then one ITEM flit per (row-tile, block).  Flits travel through LF bench
-- registers and `room` comes back through LR, the depths of the real trees, and a random
-- gate withholds flits so the tile drains and refills.  The result side takes words
-- under a random RDY.  Checks, counted in variables: every row-tile's two 48-bit values
-- and its sat bit (CHECK_VALUES), and the number of results per case (always).
--
-- CHECK_VALUES = false is the attribution control for the mutation rows
-- (sim/mutants/mv_tile_attr.json): a value mutant must survive it, a dropped-valid mutant
-- must not.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_mv_tile is
  generic(
    VEC          : string   := "mv_tile_vec.txt";
    XD           : positive := 32;
    SLACK        : positive := 12;
    LF           : positive := 5;
    LR           : positive := 3;
    FGAP         : natural  := 20;   -- percent of cycles the bench withholds a flit
    RGAP         : natural  := 30;   -- percent of cycles result RDY is low
    CHECK_VALUES : boolean  := true
  );
end entity;

architecture sim of tb_mv_tile is
  constant BLK : positive := 32;
  constant TCK : time := 1.111 ns;
  constant MAXB : positive := 1024;    -- beats per case the bench can hold
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal done_sim : boolean := false;

  signal arvalid, arready, rvalid, rready, rlast : std_logic;
  signal araddr : std_logic_vector(39 downto 0);
  signal arlen  : std_logic_vector(7 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst : std_logic_vector(1 downto 0);
  signal rdata  : std_logic_vector(255 downto 0);
  signal wr_en  : std_logic := '0';
  signal wr_addr : natural := 0;
  signal wr_data : std_logic_vector(255 downto 0) := (others => '0');

  signal w_beats : integer := 0;
  signal f_v : std_logic := '0';
  signal f_kind : std_logic_vector(1 downto 0) := "00";
  signal f_x : std_logic_vector(BLK*16-1 downto 0) := (others => '0');
  signal f_s : std_logic_vector(31 downto 0) := (others => '0');
  signal f_first, f_last : std_logic := '0';
  signal room : std_logic;
  signal r_v, r_rdy : std_logic := '0';
  signal r_d : std_logic_vector(96 downto 0);
begin
  clk <= not clk after TCK when not done_sim else '0';

  dut : entity work.mv_tile
    generic map(BLK => BLK, AXI_DW => 256, ADDR_W => 40, DEPTH => 64, MAXB => 16,
                MAXOUT => 16, XD => XD, SLACK => SLACK, RD => 4)
    port map(clk => clk, rst => rst, w_base => (others => '0'), w_beats => w_beats,
             arvalid => arvalid, arready => arready, araddr => araddr, arlen => arlen,
             arsize => arsize, arburst => arburst, rvalid => rvalid, rready => rready,
             rdata => rdata, rlast => rlast,
             f_v => f_v, f_kind => f_kind, f_x => f_x, f_s => f_s,
             f_first => f_first, f_last => f_last, room => room,
             r_v => r_v, r_d => r_d, r_rdy => r_rdy);

  mem : entity work.axi_rd_mem_model
    generic map(AXI_DW => 256, ADDR_W => 40, NWORDS => MAXB, SEED => 7, GAPPCT => 25)
    port map(clk => clk, rst => rst, arvalid => arvalid, arready => arready,
             araddr => araddr, arlen => arlen, rvalid => rvalid, rready => rready,
             rdata => rdata, rlast => rlast,
             wr_en => wr_en, wr_addr => wr_addr, wr_data => wr_data);

  run : process
    file fv : text;
    variable l : line;
    variable tok : string(1 to 8);
    variable ch : character;
    variable good : boolean;
    type x_arr is array(0 to MAXB-1) of std_logic_vector(BLK*16-1 downto 0);
    type s_arr is array(0 to MAXB-1) of std_logic_vector(31 downto 0);
    type b_arr is array(0 to MAXB-1) of std_logic;
    type v_arr is array(0 to 63) of std_logic_vector(96 downto 0);
    variable xs : x_arr;
    variable ss : s_arr;
    variable fs, ls : b_arr;
    variable ev : v_arr;
    variable cbv : integer;
    type cb_arr is array(0 to 15) of integer;
    variable cbs : cb_arr;
    variable cid, osh, mode, nb, nt, t, b, fi, la, sat, nflit, nres : integer;
    variable w256 : std_logic_vector(255 downto 0);
    variable x512 : std_logic_vector(BLK*16-1 downto 0);
    variable s32 : std_logic_vector(31 downto 0);
    variable v48a, v48b : std_logic_vector(47 downto 0);
    variable checks, fails, ncase, waitc : natural := 0;
    -- flit pipeline (the tree) and room pipeline
    type fl_t is record
      v : std_logic; k : std_logic_vector(1 downto 0);
      x : std_logic_vector(BLK*16-1 downto 0); s : std_logic_vector(31 downto 0);
      f, l : std_logic;
    end record;
    type fp_t is array(0 to LF-1) of fl_t;
    variable fp : fp_t;
    variable rp : std_logic_vector(LR-1 downto 0);
    variable nxt : fl_t;
    variable rng : unsigned(31 downto 0) := x"1234ABCD";
    variable sent, total : integer;

    procedure rnd is
    begin
      rng := rng xor shift_left(rng, 13);
      rng := rng xor shift_right(rng, 17);
      rng := rng xor shift_left(rng, 5);
    end procedure;
    procedure skip(variable ln : inout line) is
      variable c : character;
    begin
      while ln'length > 0 and (ln(ln'left) = ' ' or ln(ln'left) = HT) loop
        read(ln, c);
      end loop;
    end procedure;
    procedure rhex(variable ln : inout line; v : out std_logic_vector) is
      variable c : character;
      variable n : integer;
      variable r : std_logic_vector(v'length-1 downto 0);
    begin
      skip(ln);
      for i in v'length/4 - 1 downto 0 loop
        read(ln, c);
        case c is
          when '0' to '9' => n := character'pos(c) - character'pos('0');
          when 'A' to 'F' => n := character'pos(c) - character'pos('A') + 10;
          when 'a' to 'f' => n := character'pos(c) - character'pos('a') + 10;
          when others => n := 0;
            report "tb_mv_tile: bad hex character in " & VEC severity failure;
        end case;
        r(i*4 + 3 downto i*4) := std_logic_vector(to_unsigned(n, 4));
      end loop;
      v := r;
    end procedure;
    procedure rword(variable ln : inout line; w : out string) is
      variable c : character;
      variable s : string(1 to 8) := (others => ' ');
      variable i : natural := 0;
    begin
      skip(ln);
      while ln'length > 0 and ln(ln'left) /= ' ' loop
        read(ln, c);
        i := i + 1;
        if i <= 8 then s(i) := c; end if;
      end loop;
      w := s;
    end procedure;
    procedure tick is
    begin
      wait until rising_edge(clk);
    end procedure;
  begin
    file_open(fv, VEC, read_mode);
    for i in 0 to LF-1 loop fp(i).v := '0'; end loop;
    rp := (others => '0');
    rst <= '1';
    for i in 1 to 8 loop tick; end loop;
    rst <= '0';
    tick;
    while not endfile(fv) loop
      readline(fv, l);
      if l'length = 0 then next; end if;
      if l(l'left) = '#' then next; end if;
      rword(l, tok);
      if tok(1 to 4) = "DONE" then
        read(l, cid);
        assert cid = ncase report "tb_mv_tile: DONE count disagrees with the cases read"
          severity failure;
        exit;
      end if;
      assert tok(1 to 4) = "CASE" report "tb_mv_tile: expected CASE, got " & tok severity failure;
      read(l, cid); read(l, osh); read(l, mode); read(l, nb); read(l, nt);
      readline(fv, l); rword(l, tok);
      for i in 0 to 15 loop read(l, cbv); cbs(i) := cbv; end loop;
      -- the B lines: weights straight into the AXI model, the rest kept for the flits
      for i in 0 to nt*nb - 1 loop
        readline(fv, l); rword(l, tok);
        read(l, t); read(l, b);
        rhex(l, w256); rhex(l, x512); rhex(l, s32); read(l, fi); read(l, la);
        assert t*nb + b = i report "tb_mv_tile: B lines out of order" severity failure;
        xs(i) := x512; ss(i) := s32;
        if fi = 1 then fs(i) := '1'; else fs(i) := '0'; end if;
        if la = 1 then ls(i) := '1'; else ls(i) := '0'; end if;
        wr_en <= '1'; wr_addr <= i; wr_data <= w256;
        tick;
      end loop;
      wr_en <= '0';
      for i in 0 to nt - 1 loop
        readline(fv, l); rword(l, tok);
        read(l, t); rhex(l, v48a); rhex(l, v48b); read(l, sat);
        ev(i)(47 downto 0) := v48a; ev(i)(95 downto 48) := v48b;
        if sat = 1 then ev(i)(96) := '1'; else ev(i)(96) := '0'; end if;
      end loop;
      readline(fv, l); rword(l, tok);
      assert tok(1 to 3) = "END" report "tb_mv_tile: expected END" severity failure;
      w_beats <= nt * nb;

      -- play the flits; collect the results
      total := 17 + nt*nb; sent := 0; nres := 0; waitc := 0;
      while nres < nt loop
        -- result side: the handshake happened at the edge we just passed
        rnd;
        -- send decision on the room seen LR cycles ago
        nxt.v := '0';
        if sent < total and rp(LR-1) = '1' and to_integer(rng(7 downto 0)) mod 100 >= FGAP then
          nxt.v := '1'; nxt.x := (others => '0'); nxt.s := (others => '0');
          nxt.f := '0'; nxt.l := '0';
          if sent = 0 then
            nxt.k := "10";
            nxt.x(5 downto 0) := std_logic_vector(to_unsigned(osh, 6));
            nxt.x(7 downto 6) := std_logic_vector(to_unsigned(mode, 2));
          elsif sent <= 16 then
            nxt.k := "01";
            nxt.x(3 downto 0) := std_logic_vector(to_unsigned(sent - 1, 4));
            nxt.x(11 downto 4) := std_logic_vector(to_signed(cbs(sent - 1), 8));
          else
            nxt.k := "00";
            nxt.x := xs(sent - 17); nxt.s := ss(sent - 17);
            nxt.f := fs(sent - 17); nxt.l := ls(sent - 17);
          end if;
          sent := sent + 1;
        end if;
        f_v <= fp(LF-1).v; f_kind <= fp(LF-1).k; f_x <= fp(LF-1).x; f_s <= fp(LF-1).s;
        f_first <= fp(LF-1).f; f_last <= fp(LF-1).l;
        for i in LF-1 downto 1 loop fp(i) := fp(i-1); end loop;
        fp(0) := nxt;
        if to_integer(rng(15 downto 8)) mod 100 >= RGAP then r_rdy <= '1'; else r_rdy <= '0'; end if;
        tick;
        rp := rp(LR-2 downto 0) & room;
        if r_v = '1' and r_rdy = '1' then
          checks := checks + 1;
          if CHECK_VALUES and r_d /= ev(nres) then
            fails := fails + 1;
            report "tb_mv_tile: MISMATCH case " & integer'image(cid) & " row-tile "
                 & integer'image(nres) & " got " & to_hstring(r_d) & " want "
                 & to_hstring(ev(nres)) severity error;
          end if;
          nres := nres + 1;
        end if;
        waitc := waitc + 1;
        assert waitc < 200000 report "tb_mv_tile: case " & integer'image(cid)
          & " timed out with " & integer'image(nres) & " of " & integer'image(nt)
          & " results" severity failure;
      end loop;
      f_v <= '0'; r_rdy <= '0';
      -- flush the tree model; no stray result may follow
      for i in 0 to LF-1 loop fp(i).v := '0'; end loop;
      for i in 1 to 80 loop
        tick;
        rp := rp(LR-2 downto 0) & room;
        assert r_v = '0' report "tb_mv_tile: an extra result after the case's last row-tile"
          severity failure;
      end loop;
      checks := checks + 1;
      ncase := ncase + 1;
    end loop;
    assert ncase > 0 report "tb_mv_tile: no cases read" severity failure;
    assert fails = 0 report "tb_mv_tile: FAIL " & integer'image(fails) & " mismatches"
      severity failure;
    report "PASS: tb_mv_tile checks=" & integer'image(checks) & " cases="
         & integer'image(ncase) severity note;
    done_sim <= true;
    wait;
  end process;
end architecture;
```

- [ ] **Step 2: Run the bench row and watch it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/a450_t2_red bash sim/regress.sh --suite sim --only tb_mv_tile --keep`
Expected: the row is `BUILD-ERROR` (no entity `mv_tile`), `OVERALL PASS 0`.

- [ ] **Step 3: Write the FIFO and the tile**

`rtl/mv_lfifo.vhd`:

```vhdl
-- rtl/mv_lfifo.vhd -- a small first-word-fall-through FIFO in distributed RAM, one beat
-- per cycle in and out.  rtl/stream_fifo.vhd's structure at FAST_POP = true (registered
-- memory read, 2-entry output stage, the after-pop read-issue bound), with the memory in
-- LUTRAM: the a450 tile's 32-deep flit FIFO and 4-deep result FIFO would each waste a
-- BRAM36 (spec 2.2).  A separate entity, not a generic on stream_fifo, because a change
-- to stream_fifo's text re-keys every block rating that contains it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mv_lfifo is
  generic(
    W     : positive := 64;
    DEPTH : positive := 32
  );
  port(
    clk, rst : in  std_logic;
    i_valid  : in  std_logic;
    i_data   : in  std_logic_vector(W-1 downto 0);
    i_ready  : out std_logic;
    q_valid  : out std_logic;
    q_data   : out std_logic_vector(W-1 downto 0);
    q_ready  : in  std_logic;
    level    : out integer := 0     -- memory + output stage + read in flight
  );
end entity;

architecture rtl of mv_lfifo is
  type mem_t is array(0 to DEPTH-1) of std_logic_vector(W-1 downto 0);
  signal mem : mem_t;
  attribute ram_style : string;
  attribute ram_style of mem : signal is "distributed";
  signal wp, rp : integer range 0 to DEPTH-1 := 0;
  signal mcnt   : integer range 0 to DEPTH := 0;
  signal mem_q  : std_logic_vector(W-1 downto 0) := (others => '0');
  signal mem_q_v : std_logic := '0';
  type ob_t is array(0 to 1) of std_logic_vector(W-1 downto 0);
  signal ob : ob_t := (others => (others => '0'));
  signal ob_wp, ob_rp : integer range 0 to 1 := 0;
  signal ocnt : integer range 0 to 2 := 0;
  signal do_rd : std_logic;
  signal inflight : integer range 0 to 1;
  signal after_e : integer range 0 to 3;
begin
  inflight <= 1 when mem_q_v = '1' else 0;
  -- the pop term is inlined, not a signal (stream_fifo.vhd records why: a delta-late
  -- pop makes the subtraction reach -1 in simulation)
  after_e <= ocnt + inflight - 1 when (ocnt > 0 and q_ready = '1') else ocnt + inflight;
  do_rd   <= '1' when mcnt > 0 and after_e < 2 else '0';
  i_ready <= '1' when mcnt < DEPTH else '0';
  q_valid <= '1' when ocnt > 0 else '0';
  q_data  <= ob(ob_rp);
  level   <= mcnt + ocnt + inflight;

  process(clk)
    variable m, o : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        wp <= 0; rp <= 0; mcnt <= 0; ob_wp <= 0; ob_rp <= 0; ocnt <= 0; mem_q_v <= '0';
      else
        m := mcnt; o := ocnt;
        if i_valid = '1' and mcnt < DEPTH then
          mem(wp) <= i_data;
          wp <= (wp + 1) mod DEPTH;
          m := m + 1;
        end if;
        mem_q   <= mem(rp);
        mem_q_v <= do_rd;
        if do_rd = '1' then
          rp <= (rp + 1) mod DEPTH;
          m := m - 1;
        end if;
        if mem_q_v = '1' then
          ob(ob_wp) <= mem_q;
          ob_wp <= (ob_wp + 1) mod 2;
          o := o + 1;
        end if;
        if ocnt > 0 and q_ready = '1' then
          ob_rp <= (ob_rp + 1) mod 2;
          o := o - 1;
        end if;
        mcnt <= m; ocnt <= o;
      end if;
    end if;
  end process;
end architecture;
```

`rtl/mv_tile.vhd`:

```vhdl
-- rtl/mv_tile.vhd -- subsystem A at 450 MHz: one tile per weight port.
--
-- Spec: docs/superpowers/specs/2026-11-12-a450-per-port-tiles-design.md 1.2.
--
-- A tile owns ONE HBM weight port and the TWO rows that port carries (lane split 6.5a:
-- bits [BLK*4-1:0] of a beat are row 0's BLK nibbles, bits [2*BLK*4-1:BLK*4] row 1's).
-- It computes exactly what rtl/matvec_core.vhd computes for those two rows, with no
-- signal shared with any other tile: a stall stops only this tile's own FIFO pops.
--
-- FLITS.  Everything else a tile needs arrives in order through one flit FIFO fed by the
-- distribution tree (rtl/mv_xbcast.vhd):
--   kind 10  PARAM  x[5:0] out_shift, x[7:6] out_mode; also pulses the weight port's start
--   kind 01  CB     x[3:0] codebook address, x[11:4] the int8 entry (16 of them per job)
--   kind 00  ITEM   x = one block of BLK activations (pad columns already zero),
--                   s[15:0] row 0's scale, s[31:16] row 1's, first/last of the row-tile
-- An ITEM pops together with one weight beat.  PARAM and CB pop alone.  Because the three
-- kinds share one FIFO, a codebook write can never overtake the items it precedes.
--
-- ROOM.  `room` is '1' while the flit FIFO's level is below XD - SLACK, registered.  The
-- distributor sends only while every tile's room is '1' (a registered AND tree), so SLACK
-- must cover every flit in flight between a tile's room falling and the distributor seeing
-- it.  rtl/mv_afast.vhd derives SLACK from the two tree depths; an overrun is a failure
-- assertion here, never a silent drop.
--
-- PIPELINE (e0 = the cycle the popped flit sits in the p0 registers):
--   lane j's x and its two nibbles are delayed j cycles (SRL), then
--   e0+j+1  codebook lookup (per-lane LUTRAM) and x, registered      DSP A/B regs
--   e0+j+2  product cb*x, s24                                        DSP M reg
--   e0+j+3  c(j) = c(j-1) + product, 48 bits                         DSP P reg, PCIN cascade
--   e0+BLK+2  partial = c(BLK-1) mod 2^28: the old adder tree's s28 wrap, bit for bit
--   S   sprod = partial * ('0' & scale)          s45
--   C   contrib = floor_shr(sprod, 15)           s29
--   ACC acc = first ? contrib : acc + contrib    s48
--   E2..E6 (on last) round_shift by out_shift, sat32, the sat flag, the out-mode select
-- Nothing in the pipeline has a shared enable: data registers load every cycle and a valid
-- bit travels beside them.
--
-- RESULT.  One 97-bit word per row-tile: [47:0] row 0, [95:48] row 1, [96] sat.  The value
-- is the raw accumulator in mode 10, else sat32(round_shift(acc, out_shift)) sign-extended
-- to 48.  sat is set for modes 00/01 when sat32 clamped, on BOTH rows whatever the row
-- count (matvec_core's re2 loop does the same).  The BFP scan and the row mask are the back
-- end's (rtl/mv_back.vhd), because they need every row of the matrix.
--
-- RESULT CREDIT.  A last ITEM pops only while `outst` (row-tiles issued and not yet taken
-- by the result chain) is below RD, so the RD-deep result FIFO can never overflow.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mv4i_arith_pkg.all;

entity mv_tile is
  generic(
    BLK    : positive := 32;
    AXI_DW : positive := 256;   -- must be 2*BLK*4
    ADDR_W : positive := 40;
    DEPTH  : positive := 512;   -- weight FIFO, beats
    MAXB   : positive := 16;    -- HBM is AXI3: 16-beat bursts
    MAXOUT : positive := 16;
    XD     : positive := 32;    -- flit FIFO depth
    SLACK  : positive := 12;    -- room falls at level XD - SLACK
    RD     : positive := 4      -- result FIFO depth
  );
  port(
    clk, rst : in  std_logic;
    w_base   : in  std_logic_vector(ADDR_W-1 downto 0);
    w_beats  : in  integer;
    arvalid  : out std_logic;
    arready  : in  std_logic;
    araddr   : out std_logic_vector(ADDR_W-1 downto 0);
    arlen    : out std_logic_vector(7 downto 0);
    arsize   : out std_logic_vector(2 downto 0);
    arburst  : out std_logic_vector(1 downto 0);
    rvalid   : in  std_logic;
    rready   : out std_logic;
    rdata    : in  std_logic_vector(AXI_DW-1 downto 0);
    rlast    : in  std_logic;
    f_v      : in  std_logic;
    f_kind   : in  std_logic_vector(1 downto 0);
    f_x      : in  std_logic_vector(BLK*16-1 downto 0);
    f_s      : in  std_logic_vector(31 downto 0);
    f_first  : in  std_logic;
    f_last   : in  std_logic;
    room     : out std_logic;
    r_v      : out std_logic;
    r_d      : out std_logic_vector(96 downto 0);
    r_rdy    : in  std_logic
  );
end entity;

architecture rtl of mv_tile is
  constant XW   : positive := BLK*16;
  constant FW   : positive := XW + 36;
  constant B_F  : natural  := XW + 32;
  constant B_L  : natural  := XW + 33;
  constant B_K  : natural  := XW + 34;
  constant LAT  : positive := BLK + 2;
  constant NTAP : natural  := BLK*(BLK-1)/2;
  -- AXI_DW must be exactly two rows of BLK nibbles; an out-of-range natural stops both
  -- GHDL and Vivado at elaboration (Vivado ignores a failing assert in synthesis).
  constant CHK_DW : natural := 1 - abs(AXI_DW - 2*BLK*4);

  function tbase(j : natural) return natural is
  begin
    return j*(j-1)/2;
  end function;

  -- flit FIFO
  signal fq_d  : std_logic_vector(FW-1 downto 0);
  signal fq_in : std_logic_vector(FW-1 downto 0);
  signal fq_v, fq_ir, pop, is_item : std_logic;
  signal fq_lvl : integer;
  signal room_r : std_logic := '0';
  -- weight port
  signal wq_v, wq_r : std_logic;
  signal wq_d : std_logic_vector(AXI_DW-1 downto 0);
  signal port_start : std_logic := '0';
  -- p0
  signal p0_v : std_logic := '0';
  signal p0_x : std_logic_vector(XW-1 downto 0) := (others => '0');
  signal p0_w : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
  signal p0_s : std_logic_vector(31 downto 0) := (others => '0');
  signal p0_f, p0_l : std_logic := '0';
  -- codebook: one LUTRAM per lane, written in lockstep from one command per row
  type cb_t   is array(0 to 15) of std_logic_vector(7 downto 0);
  type cbl_t  is array(0 to 2*BLK-1) of cb_t;
  signal cbl : cbl_t := (others => (others => (others => '0')));
  attribute ram_style : string;
  attribute ram_style of cbl : signal is "distributed";
  type cmd_a_t is array(0 to 1) of std_logic_vector(3 downto 0);
  type cmd_d_t is array(0 to 1) of std_logic_vector(7 downto 0);
  signal cbw_v : std_logic_vector(1 downto 0) := (others => '0');
  signal cbw_a : cmd_a_t := (others => (others => '0'));
  signal cbw_d : cmd_d_t := (others => (others => '0'));
  attribute dont_touch : string;
  attribute dont_touch of cbw_v : signal is "true";
  attribute dont_touch of cbw_a : signal is "true";
  attribute dont_touch of cbw_d : signal is "true";
  -- params
  signal os_r   : natural range 0 to 63 := 0;
  signal hi_r   : natural range 0 to 7 := 0;
  signal lo_r   : natural range 0 to 7 := 0;
  signal mode_r : std_logic_vector(1 downto 0) := "00";
  signal bias_r : signed(48 downto 0) := (others => '0');
  -- skew: lane j's {row1 nibble, row0 nibble, x} delayed j cycles
  type tap_arr is array(0 to NTAP) of std_logic_vector(23 downto 0);
  signal tap : tap_arr := (others => (others => '0'));
  -- DSP columns
  type s8_arr  is array(0 to 2*BLK-1) of signed(7 downto 0);
  type s16_arr is array(0 to BLK-1) of signed(15 downto 0);
  type s24_arr is array(0 to 2*BLK-1) of signed(23 downto 0);
  type s48_arr is array(0 to 2*BLK-1) of signed(47 downto 0);
  signal a_cb : s8_arr  := (others => (others => '0'));
  signal a_x  : s16_arr := (others => (others => '0'));
  signal m    : s24_arr := (others => (others => '0'));
  signal c    : s48_arr := (others => (others => '0'));
  -- tag delay: valid (with reset) and first/last/scale (no reset, SRL)
  type td_t is array(0 to LAT-1) of std_logic_vector(33 downto 0);
  signal vd : std_logic_vector(LAT-1 downto 0) := (others => '0');
  signal td : td_t := (others => (others => '0'));
  -- per-row stages
  type s45_2 is array(0 to 1) of signed(44 downto 0);
  type s29_2 is array(0 to 1) of signed(28 downto 0);
  type s48_2 is array(0 to 1) of signed(47 downto 0);
  type s49_2 is array(0 to 1) of signed(48 downto 0);
  type s32_2 is array(0 to 1) of signed(31 downto 0);
  signal s_v, c_v, e1_v, e2_v, e3_v, e4_v, e5_v, e6_v : std_logic := '0';
  signal s_f, s_l, c_f, c_l : std_logic := '0';
  signal s_sp : s45_2 := (others => (others => '0'));
  signal c_ct : s29_2 := (others => (others => '0'));
  signal acc, e1_acc, e2_acc, e3_acc, e4_acc, e5_acc : s48_2 := (others => (others => '0'));
  signal e2_w, e3_w : s49_2 := (others => (others => '0'));
  signal e4_rs, e5_rs : s48_2 := (others => (others => '0'));
  signal e5_a32 : s32_2 := (others => (others => '0'));
  signal e6_d : std_logic_vector(96 downto 0) := (others => '0');
  -- result FIFO and its credit
  signal rq_ir : std_logic;
  signal outst : integer range 0 to RD := 0;
begin
  fq_in(XW-1 downto 0)  <= f_x;
  fq_in(XW+31 downto XW) <= f_s;
  fq_in(B_F) <= f_first;
  fq_in(B_L) <= f_last;
  fq_in(B_K+1 downto B_K) <= f_kind;

  flitq : entity work.mv_lfifo
    generic map(W => FW, DEPTH => XD)
    port map(clk => clk, rst => rst,
             i_valid => f_v, i_data => fq_in, i_ready => fq_ir,
             q_valid => fq_v, q_data => fq_d, q_ready => pop, level => fq_lvl);

  wport : entity work.axi_rd_port
    generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH, MAXB => MAXB,
                MAXOUT => MAXOUT, DUAL_CLK => false, FAST_POP => true)
    port map(clk => clk, rst => rst, start => port_start,
             base => w_base, n_beats => w_beats,
             arvalid => arvalid, arready => arready, araddr => araddr, arlen => arlen,
             arsize => arsize, arburst => arburst,
             rvalid => rvalid, rready => rready, rdata => rdata, rlast => rlast,
             q_valid => wq_v, q_data => wq_d, q_ready => wq_r);

  is_item <= '1' when fq_d(B_K+1 downto B_K) = "00" else '0';
  pop  <= '1' when fq_v = '1' and (is_item = '0' or
                   (wq_v = '1' and (fq_d(B_L) = '0' or outst < RD))) else '0';
  wq_r <= pop and is_item;
  room <= room_r;

  overrun : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '0' then
        assert not (f_v = '1' and fq_ir = '0')
          report "mv_tile: a flit arrived with the flit FIFO full (room/credit overrun)"
          severity failure;
      end if;
    end if;
  end process;

  -- p0, the codebook command, the params, room
  front : process(clk)
    variable osv : natural range 0 to 63;
  begin
    if rising_edge(clk) then
      p0_x <= fq_d(XW-1 downto 0);
      p0_s <= fq_d(XW+31 downto XW);
      p0_f <= fq_d(B_F);
      p0_l <= fq_d(B_L);
      p0_w <= wq_d;
      for r in 0 to 1 loop
        cbw_a(r) <= fq_d(3 downto 0);
        cbw_d(r) <= fq_d(11 downto 4);
      end loop;
      if fq_lvl < XD - SLACK then room_r <= '1'; else room_r <= '0'; end if;
      if pop = '1' and fq_d(B_K+1 downto B_K) = "10" then
        osv    := to_integer(unsigned(fq_d(5 downto 0)));
        os_r   <= osv;
        hi_r   <= osv / 8;
        lo_r   <= osv mod 8;
        mode_r <= fq_d(7 downto 6);
        if osv = 0 then
          bias_r <= (others => '0');
        else
          bias_r <= shift_left(to_signed(1, 49), osv - 1);
        end if;
      end if;
      if rst = '1' then
        p0_v <= '0'; cbw_v <= "00"; port_start <= '0'; room_r <= '0';
      else
        p0_v <= pop and is_item;
        if pop = '1' and fq_d(B_K+1 downto B_K) = "01" then cbw_v <= "11";
        else cbw_v <= "00"; end if;
        if pop = '1' and fq_d(B_K+1 downto B_K) = "10" then port_start <= '1';
        else port_start <= '0'; end if;
      end if;
    end if;
  end process;

  -- the codebook write, every lane of a row from that row's command copy
  cbwr : process(clk)
  begin
    if rising_edge(clk) then
      for r in 0 to 1 loop
        if cbw_v(r) = '1' then
          for j in 0 to BLK-1 loop
            cbl(r*BLK + j)(to_integer(unsigned(cbw_a(r)))) <= cbw_d(r);
          end loop;
        end if;
      end loop;
    end if;
  end process;

  -- skew, lookup, multiply, cascade
  mac : process(clk)
    variable ln : std_logic_vector(23 downto 0);
  begin
    if rising_edge(clk) then
      for j in 0 to BLK-1 loop
        if j > 0 then
          tap(tbase(j)) <= p0_w(BLK*4 + j*4 + 3 downto BLK*4 + j*4)
                         & p0_w(j*4 + 3 downto j*4) & p0_x(j*16 + 15 downto j*16);
          for d in 1 to j-1 loop
            tap(tbase(j) + d) <= tap(tbase(j) + d - 1);
          end loop;
        end if;
      end loop;
      for j in 0 to BLK-1 loop
        if j = 0 then
          ln := p0_w(BLK*4 + 3 downto BLK*4) & p0_w(3 downto 0) & p0_x(15 downto 0);
        else
          ln := tap(tbase(j) + j - 1);
        end if;
        a_x(j) <= signed(ln(15 downto 0));
        a_cb(j)       <= signed(cbl(j)(to_integer(unsigned(ln(19 downto 16)))));
        a_cb(BLK + j) <= signed(cbl(BLK + j)(to_integer(unsigned(ln(23 downto 20)))));
      end loop;
      for r in 0 to 1 loop
        for j in 0 to BLK-1 loop
          m(r*BLK + j) <= a_cb(r*BLK + j) * a_x(j);
          if j = 0 then
            c(r*BLK) <= resize(m(r*BLK), 48);
          else
            c(r*BLK + j) <= c(r*BLK + j - 1) + resize(m(r*BLK + j), 48);
          end if;
        end loop;
      end loop;
    end if;
  end process;

  -- tags, scale, accumulate, row end
  tail : process(clk)
    variable an : signed(47 downto 0);
    variable sc : std_logic_vector(31 downto 0);
    variable vv : signed(47 downto 0);
    variable sat : std_logic;
    variable s17 : std_logic_vector(16 downto 0);
  begin
    if rising_edge(clk) then
      td(0) <= p0_l & p0_f & p0_s;
      for i in 1 to LAT-1 loop
        td(i) <= td(i-1);
      end loop;
      sc := td(LAT-1)(31 downto 0);
      -- S
      s_f <= td(LAT-1)(32);
      s_l <= td(LAT-1)(33);
      for r in 0 to 1 loop
        -- through a variable: GHDL 1.0.0 crashes on a concatenation directly in signed()
        s17 := '0' & sc(r*16 + 15 downto r*16);
        s_sp(r) <= signed(c(r*BLK + BLK - 1)(27 downto 0)) * signed(s17);
      end loop;
      -- C
      c_f <= s_f; c_l <= s_l;
      for r in 0 to 1 loop
        c_ct(r) <= resize(floor_shr(s_sp(r), 15), 29);
      end loop;
      -- ACC
      for r in 0 to 1 loop
        if c_f = '1' then an := resize(c_ct(r), 48);
        else              an := acc(r) + resize(c_ct(r), 48); end if;
        if c_v = '1' then acc(r) <= an; end if;
        e1_acc(r) <= an;
      end loop;
      -- E2: bias.  E3: shift by 8*os(5:3).  E4: by os(2:0), back to 48.  E5: sat32.
      for r in 0 to 1 loop
        e2_w(r)   <= resize(e1_acc(r), 49) + bias_r;
        e2_acc(r) <= e1_acc(r);
        e3_w(r)   <= shift_right(e2_w(r), 8*hi_r);
        e3_acc(r) <= e2_acc(r);
        e4_rs(r)  <= resize(shift_right(e3_w(r), lo_r), 48);
        e4_acc(r) <= e3_acc(r);
        e5_a32(r) <= sat32(e4_rs(r));
        e5_rs(r)  <= e4_rs(r);
        e5_acc(r) <= e4_acc(r);
      end loop;
      -- E6: the out-mode select and the sat flag
      sat := '0';
      for r in 0 to 1 loop
        if mode_r = "10" then
          vv := e5_acc(r);
        else
          vv := resize(e5_a32(r), 48);
          if e5_rs(r) /= resize(e5_a32(r), 48) then sat := '1'; end if;
        end if;
        e6_d(r*48 + 47 downto r*48) <= std_logic_vector(vv);
      end loop;
      e6_d(96) <= sat;

      if rst = '1' then
        vd <= (others => '0');
        s_v <= '0'; c_v <= '0'; e1_v <= '0'; e2_v <= '0'; e3_v <= '0';
        e4_v <= '0'; e5_v <= '0'; e6_v <= '0';
      else
        vd  <= vd(LAT-2 downto 0) & p0_v;
        s_v <= vd(LAT-1);
        c_v <= s_v;
        e1_v <= c_v and c_l;
        e2_v <= e1_v; e3_v <= e2_v; e4_v <= e3_v; e5_v <= e4_v; e6_v <= e5_v;
      end if;
    end if;
  end process;

  resq : entity work.mv_lfifo
    generic map(W => 97, DEPTH => RD)
    port map(clk => clk, rst => rst,
             i_valid => e6_v, i_data => e6_d, i_ready => rq_ir,
             q_valid => r_v, q_data => r_d, q_ready => r_rdy, level => open);

  credit : process(clk)
    variable o : integer range -1 to RD + 1;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        outst <= 0;
      else
        o := outst;
        if pop = '1' and is_item = '1' and fq_d(B_L) = '1' then o := o + 1; end if;
        if r_v = '1' and r_rdy = '1' then o := o - 1; end if;
        outst <= o;
      end if;
      if rst = '0' then
        assert not (e6_v = '1' and rq_ir = '0')
          report "mv_tile: a row-tile result reached a full result FIFO (outst credit broken)"
          severity failure;
      end if;
    end if;
  end process;
end architecture;
```

- [ ] **Step 4: Run the bench row**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/a450_t2 bash sim/regress.sh --suite sim --only tb_mv_tile --keep`
Expected: `PASS sim:tb_mv_tile ... PASS: tb_mv_tile checks=93 cases=26` and `OVERALL PASS 1`. Read the `PASS 1`: `PASS 0` with no FAIL means the substring matched nothing.

- [ ] **Step 5: Write the mutants and the attribution control**

`sim/mutants/mv_tile.json` (scale-path, codebook-index, out_shift and dropped-valid mutants, spec 3.1):

```json
{
  "tb": "tb_mv_tile",
  "deps": ["rtl/util_pkg.vhd", "rtl/mv4i_arith_pkg.vhd", "rtl/stream_fifo.vhd",
           "rtl/async_fifo.vhd", "rtl/axi_rd_fsm.vhd", "rtl/axi_rd_port.vhd",
           "rtl/mv_lfifo.vhd", "rtl/mv_tile.vhd", "sim/axi_rd_mem_model.vhd", "sim/tb_mv_tile.vhd"],
  "vectors": ["sim/mv_tile_vec.txt"],
  "stop_time": "100ms",
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "S1", "expect": "KILLED", "file": "rtl/mv_tile.vhd",
     "why": "scale path: the scale multiply reads row 0's scale for both rows",
     "old": "s17 := '0' & sc(r*16 + 15 downto r*16);",
     "new": "s17 := '0' & sc(15 downto 0);"},
    {"tag": "K1", "expect": "KILLED", "file": "rtl/mv_tile.vhd",
     "why": "codebook index: row 1 decodes row 0's nibble",
     "old": "a_cb(BLK + j) <= signed(cbl(BLK + j)(to_integer(unsigned(ln(23 downto 20)))));",
     "new": "a_cb(BLK + j) <= signed(cbl(BLK + j)(to_integer(unsigned(ln(19 downto 16)))));"},
    {"tag": "O1", "expect": "KILLED", "file": "rtl/mv_tile.vhd",
     "why": "out_shift: the coarse shift drops one byte step",
     "old": "e3_w(r)   <= shift_right(e2_w(r), 8*hi_r);",
     "new": "e3_w(r)   <= shift_right(e2_w(r), 8*(hi_r/2));"},
    {"tag": "V1", "expect": "KILLED", "file": "rtl/mv_tile.vhd",
     "why": "dropped valid: a row-tile result is never pushed when the last block also starts the row-tile",
     "old": "e1_v <= c_v and c_l;",
     "new": "e1_v <= c_v and c_l and not c_f;"}
  ]
}
```

`sim/mutants/mv_tile_attr.json` (the same mutants with the value check off: only V1, which drops a result word and so trips the count check, may die; S1, K1 and O1 must survive, which proves the value comparison is what kills them):

```json
{
  "tb": "tb_mv_tile",
  "generics": [
    "-gCHECK_VALUES=false"
  ],
  "deps": [
    "rtl/util_pkg.vhd",
    "rtl/mv4i_arith_pkg.vhd",
    "rtl/stream_fifo.vhd",
    "rtl/async_fifo.vhd",
    "rtl/axi_rd_fsm.vhd",
    "rtl/axi_rd_port.vhd",
    "rtl/mv_lfifo.vhd",
    "rtl/mv_tile.vhd",
    "sim/axi_rd_mem_model.vhd",
    "sim/tb_mv_tile.vhd"
  ],
  "vectors": [
    "sim/mv_tile_vec.txt"
  ],
  "stop_time": "100ms",
  "rows": [
    {
      "tag": "Z0",
      "expect": "PASS"
    },
    {
      "tag": "S1",
      "expect": "PASS",
      "file": "rtl/mv_tile.vhd",
      "why": "ATTRIBUTION: scale path: the scale multiply reads row 0's scale for both rows; survives with the value check off, so its kill above is the value check",
      "old": "s17 := '0' & sc(r*16 + 15 downto r*16);",
      "new": "s17 := '0' & sc(15 downto 0);"
    },
    {
      "tag": "K1",
      "expect": "PASS",
      "file": "rtl/mv_tile.vhd",
      "why": "ATTRIBUTION: codebook index: row 1 decodes row 0's nibble; survives with the value check off, so its kill above is the value check",
      "old": "a_cb(BLK + j) <= signed(cbl(BLK + j)(to_integer(unsigned(ln(23 downto 20)))));",
      "new": "a_cb(BLK + j) <= signed(cbl(BLK + j)(to_integer(unsigned(ln(19 downto 16)))));"
    },
    {
      "tag": "O1",
      "expect": "PASS",
      "file": "rtl/mv_tile.vhd",
      "why": "ATTRIBUTION: out_shift: the coarse shift drops one byte step; survives with the value check off, so its kill above is the value check",
      "old": "e3_w(r)   <= shift_right(e2_w(r), 8*hi_r);",
      "new": "e3_w(r)   <= shift_right(e2_w(r), 8*(hi_r/2));"
    },
    {
      "tag": "V1",
      "expect": "KILLED",
      "file": "rtl/mv_tile.vhd",
      "why": "ATTRIBUTION: dropped valid: a row-tile result is never pushed when the last block also starts the row-tile; still killed with the value check off (the result count)",
      "old": "e1_v <= c_v and c_l;",
      "new": "e1_v <= c_v and c_l and not c_f;"
    }
  ]
}
```

- [ ] **Step 6: Run the mutants**

Run: `python3 sim/mutate_rows.py sim/mutants/mv_tile.json && python3 sim/mutate_rows.py sim/mutants/mv_tile_attr.json`
Expected: first run `MUTROW Z0 PASS PASS`, S1, K1, O1, V1 each `KILLED KILLED`, `MUTANTS_OK 5`; second run Z0 `PASS PASS`, S1, K1, O1 `PASS PASS`, V1 `KILLED KILLED`, `MUTANTS_OK 5`.

- [ ] **Step 7: Commit**

```bash
git add rtl/mv_lfifo.vhd rtl/mv_tile.vhd sim/axi_rd_mem_model.vhd sim/tb_mv_tile.vhd \
        sim/mutants/mv_tile.json sim/mutants/mv_tile_attr.json
git commit -m "a450 Task 2: mv_tile, one weight port's two rows, bit-exact against the model, 4 mutants killed"
```

---
### Task 3: Tile rating at 450 MHz

Vivado out of context, routed. A subagent may run this task (Vivado synth and route only; no hardware of any kind).

**Files:**
- Modify: `hw/targets/devices.json` (new row `vu35p_jc_2l85`)
- Modify: `hw/targets/blocks.json` (new row `a450_tile`)
- Create (by `rate.py`): `hw/targets/ratings/vu35p_jc_2l85/a450_tile.QWEN38_27B.json`

**Interfaces:**
- Consumes: `rtl/mv_tile.vhd` (Task 2) and its GHDL closure (`rate.py` derives it: `mv4i_arith_pkg`, `mv_lfifo`, `util_pkg`, `axi_rd_fsm`, `stream_fifo`, `async_fifo`, `axi_rd_port`, `mv_tile`).
- Produces: the rating record. Task 7 reads `route.wns` from it only as a precursor; the binding gate is Task 7's.
- `tools/rate/rate.py run <row> --device <dev> --model <model> [--mem <cap>]` prints `^RATE_RECORD <row> achieved <f> MHz ceiling <f> MHz -> <path>`. The record's `route` has `wns`, `whs`, `unrouted`, `start`, `end`, `levels`; `util` has `DSP`, `LUT`, `FF`, `BRAM`, `URAM`; `mem` has `peak`, `swap_peak`, `cap`.

- [ ] **Step 1: Add the device row and the tile row**

Save as `/mnt/storage/fk33_builds/scratch/a450_add_tile_row.py` and run it from the repo root. It keeps the files' existing format (`json.dump(indent=2, sort_keys=True)` plus a newline), so the diff is additions only.

```python
import json
D = "hw/targets/devices.json"
B = "hw/targets/blocks.json"
d = json.load(open(D))
d["vu35p_jc_2l85"] = {
    "board": "jungle_cat",
    "build_part": "xcvu35p-fsvh2104-2L-e",
    "rating_part": "xcvu35p-fsvh2104-2L-e",
    "vccint_run": 0.85,
    "note": "the JC dies at their measured board default 0.850 V, where the -2 timing "
            "model applies to the -2L part (spec 2026-11-12-a450 section 0)",
}
with open(D, "w") as f:
    json.dump(d, f, indent=2, sort_keys=True)
    f.write("\n")
b = json.load(open(B))
b["a450_tile"] = {
    "top": "mv_tile", "clocks": {"clk": "*"}, "extra_files": [], "levers": [],
    "generics": {"ADDR_W": "40", "AXI_DW": "256", "BLK": "32", "DEPTH": "512",
                 "MAXB": "16", "MAXOUT": "16", "RD": "4", "SLACK": "12", "XD": "32"},
    "target_ns": 2.222, "tier": "anchor"}
with open(B, "w") as f:
    json.dump(b, f, indent=2, sort_keys=True)
    f.write("\n")
print("RATE_ROWS_ADDED vu35p_jc_2l85 a450_tile")
```

Run: `python3 /mnt/storage/fk33_builds/scratch/a450_add_tile_row.py && git diff --stat hw/targets/ && python3 tools/rate/rate.py status | grep -E '^RATESTATUS vu35p_jc_2l85 a450_tile '`
Expected: `RATE_ROWS_ADDED vu35p_jc_2l85 a450_tile`; the diff stat shows insertions only (`devices.json | 7 +`, `blocks.json | 20 +` or close); `RATESTATUS vu35p_jc_2l85 a450_tile - UNRATED`.

`tier: anchor` is deliberate (ruling R9): `rate.py preflight` refuses unrated rows of other tiers, and this row must not block other builds before it is rated. No `resources` in the device row: `tools/rate/devices.py` accepts a row without them and fills them only through `devices.refresh()`.

- [ ] **Step 2: State the memory budget, then check the lane**

```bash
free -g | head -2
for p in /proc/[0-9]*; do
  e=$(readlink $p/exe 2>/dev/null) || continue
  case "$e" in */unwrapped/lnx64.o/vivado*) echo "VIVADO_PRESENT ${p#/proc/}";; esac
done
```
Expected: no `VIVADO_PRESENT` line. Write the budget into the task report: resident now, this job's ESTIMATE peak of 4 GB under a 6 GB cap, what is left (with `llama-server` up, about 13 GB). If a Vivado is present, wait; never start a second one.

- [ ] **Step 3: Rate the tile, routed, at 2.222 ns**

Run: `python3 tools/rate/rate.py run a450_tile --device vu35p_jc_2l85 --model QWEN38_27B --mem 6G 2>&1 | tee /mnt/storage/fk33_builds/scratch/a450_tile_rate.log`
Expected: a line matching `^RATE_RECORD a450_tile achieved` (`grep -E '^RATE_RECORD a450_tile ' /mnt/storage/fk33_builds/scratch/a450_tile_rate.log`).

- [ ] **Step 4: Gate on the record**

```bash
python3 - <<'PY'
import json, sys
r = json.load(open("hw/targets/ratings/vu35p_jc_2l85/a450_tile.QWEN38_27B.json"))
ro, u = r["route"], r["util"]
print("A450_TILE wns %.3f whs %.3f unrouted %d DSP %d LUT %d FF %d peak %.2f GB cap %s"
      % (ro["wns"], ro["whs"], ro["unrouted"], u["DSP"], u["LUT"], u["FF"],
         r["mem"]["peak"] / 1e9, r["mem"]["cap"]))
ok = ro["wns"] >= 0 and ro["whs"] >= 0 and ro["unrouted"] == 0 and 64 <= u["DSP"] <= 68
print("A450_TILE_GATE " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
```
Expected: `A450_TILE_GATE PASS`, DSP 66 (ESTIMATE: 64 product DSPs plus one scale DSP per row, the ratio `a_engine` MEASURED, 1,585 = 48 x 33 + 1). The gate accepts 64 to 68 because the 28 x 17 scale product may split; any count other than 66 means reading the mapping report (skill `vivado-results`) and stating in the commit message what the extra DSPs are. The DSP count does not prove the cascade was inferred (fabric adders would leave it at 64 too); what this gate binds is the routed WNS, and the reports and `routed.dcp` stay in the rating work directory under `/mnt/storage/fk33_builds/ratings/a450_tile/xcvu35p-fsvh2104-2L-e/` for anyone who needs to look. If `mem.peak` equals the cap, the run was capped, not sized: say so, and take no size from it.

If WNS is negative: record the worst path's `start`, `end` and `levels` from the record, and stop. Do not change the RTL in this task; a timing fix is a new task with its own bench rerun and mutants.

- [ ] **Step 5: Commit**

```bash
git add hw/targets/devices.json hw/targets/blocks.json \
        hw/targets/ratings/vu35p_jc_2l85/a450_tile.QWEN38_27B.json
git commit -m "a450 Task 3: mv_tile rated routed on xcvu35p -2L at 0.85 V, target 2.222 ns"
```

---
### Task 4: x/scale distributor with credits

**Files:**
- Create: `rtl/act_mem_dp.vhd`, `rtl/mv_xbcast.vhd`, `rtl/mv_dist.vhd`
- Create: `sim/tb_mv_dist.vhd`, `sim/mutants/mv_dist.json`

**Interfaces:**
- Consumes: the flit contract and the `room` rule of `mv_tile` (Task 2): PARAM `"10"` (`x(5:0)` os, `x(7:6)` mode), CB `"01"` (`x(3:0)` addr, `x(11:4)` data), ITEM `"00"`; room is registered and falls at level `XD - SLACK`. `rtl/axi_rd_port.vhd` for the 3 scale ports.
- Produces:
  - `entity act_mem_dp generic(ELEMS 17408, BLK 32, W 16) port(wclk; we; waddr(clog2(ELEMS)-1:0); wdata(W-1:0); rclk; rbaddr(clog2(ceil(ELEMS/BLK))-1:0); rdata(BLK*W-1:0))`, one registered read cycle.
  - `entity mv_xbcast generic(NT 24, G 6, XW 512) port(clk, rst; i_v; i_kind(1:0); i_x(XW-1:0); i_s(NT*32-1:0); i_first; i_last; o_v(NT-1:0); o_kind(NT*2-1:0); o_x(NT*XW-1:0); o_s(NT*32-1:0); o_first(NT-1:0); o_last(NT-1:0); rooms(NT-1:0); room_all)`. Flit latency root to leaf: 2 registers (`LF` in the tile benches counts these plus the distributor's own output register). `room_all` latency: 2 registers.
  - `entity mv_dist generic(BLK 32, ROWS_IF 48, NPORTS_S 3, AXI_DW 256, ADDR_W 40, DEPTH 512, MAXB 16, MAXOUT 16, MAXCOLS 17408) port(clk, rst; go; j_nb, j_rows, j_lastv : natural; j_os(5:0); j_mode(1:0); j_cb(127:0); s_base(NPORTS_S*ADDR_W-1:0); s_beats : integer; x_rbaddr; x_rdata(BLK*16-1:0); m_ar*/m_r* for NPORTS_S ports; o_v; o_kind; o_x; o_s(ROWS_IF*16-1:0); o_first; o_last; room_all; busy)`. `j_cb` entry e is bits `8e+7:8e`. `j_lastv` is the valid column count of the last block, 1..BLK. On `go` it emits PARAM, 16 CB flits, then `ceil(j_rows/ROWS_IF) * j_nb` ITEMs, the scales of row-tile t block b being scale superword `t*j_nb + b` from the 3 scale ports.

- [ ] **Step 1: Write the bench**

`sim/tb_mv_dist.vhd` (distributor, tree and dual-port memory, three scale AXI models, 24 stub tiles with level counters and tile 0 stalling, six jobs):

```vhdl
-- sim/tb_mv_dist.vhd -- rtl/mv_dist.vhd + rtl/mv_xbcast.vhd + rtl/act_mem_dp.vhd.
--
-- What it proves: every one of the NT tiles receives exactly the flit sequence the a450
-- spec 2.2 defines, in order -- PARAM, 16 CB, then one ITEM per (row-tile, block) with
-- the activation block read through the dual-clock memory, every column at or past n_cols
-- zero, and that tile's own two scales from the 3-port scale superword -- and that the
-- room/credit loop never lets a tile FIFO of depth XD overflow, even with tile 0 stalled
-- for long stretches while the others drain.
--
-- The tiles are bench stubs: a level counter per tile (one arrival per flit, random pops,
-- long stalls on tile 0) and a registered room = level < XD - SLACK, which is
-- rtl/mv_tile.vhd's rule.  The expected flits are built here from the same random data
-- the bench writes into the activation memory and the three scale AXI models.
--
-- Clocks: the activation memory is written on wclk (125 MHz) and read on aclk (450 MHz).
-- Sweep the credit sizing by hand:  -gXD=24 -gSLACK=12 passes;  -gSLACK=3 must FAIL with
-- "overflow" (the slack no longer covers the 5 + 3 cycle loop).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mv_dist is
  generic(
    XD    : positive := 32;
    SLACK : positive := 12
  );
end entity;

architecture sim of tb_mv_dist is
  constant NT   : positive := 24;
  constant BLK  : positive := 32;
  constant MAXC : positive := 1024;
  constant NBMX : positive := MAXC / BLK;
  constant XW   : positive := BLK*16;
  signal aclk, wclk : std_logic := '0';
  signal rst : std_logic := '1';
  signal done_sim : boolean := false;

  signal go : std_logic := '0';
  signal j_nb, j_rows, j_lastv : natural := 1;
  signal j_os : std_logic_vector(5 downto 0) := (others => '0');
  signal j_mode : std_logic_vector(1 downto 0) := "00";
  signal j_cb : std_logic_vector(127 downto 0) := (others => '0');
  signal s_beats : integer := 0;
  signal x_we : std_logic := '0';
  signal x_waddr : std_logic_vector(9 downto 0) := (others => '0');
  signal x_wdata : std_logic_vector(15 downto 0) := (others => '0');
  signal x_rbaddr : std_logic_vector(4 downto 0);
  signal x_rdata : std_logic_vector(XW-1 downto 0);
  signal arv, arr, rv, rr, rl : std_logic_vector(2 downto 0);
  signal ara : std_logic_vector(3*40-1 downto 0);
  signal arl : std_logic_vector(3*8-1 downto 0);
  signal ars : std_logic_vector(3*3-1 downto 0);
  signal arb : std_logic_vector(3*2-1 downto 0);
  signal rd  : std_logic_vector(3*256-1 downto 0);
  signal s_wr : std_logic := '0';
  signal s_wa : natural := 0;
  type s3_t is array(0 to 2) of std_logic_vector(255 downto 0);
  signal s_wd : s3_t := (others => (others => '0'));
  signal d_v, d_f, d_l : std_logic;
  signal d_k : std_logic_vector(1 downto 0);
  signal d_x : std_logic_vector(XW-1 downto 0);
  signal d_s : std_logic_vector(NT*32-1 downto 0);
  signal o_v, o_f, o_l : std_logic_vector(NT-1 downto 0);
  signal o_k : std_logic_vector(NT*2-1 downto 0);
  signal o_x : std_logic_vector(NT*XW-1 downto 0);
  signal o_s : std_logic_vector(NT*32-1 downto 0);
  signal rooms : std_logic_vector(NT-1 downto 0) := (others => '0');
  signal room_all, busy : std_logic;
begin
  aclk <= not aclk after 1.111 ns when not done_sim else '0';
  wclk <= not wclk after 4 ns when not done_sim else '0';

  xmem : entity work.act_mem_dp
    generic map(ELEMS => MAXC, BLK => BLK, W => 16)
    port map(wclk => wclk, we => x_we, waddr => x_waddr, wdata => x_wdata,
             rclk => aclk, rbaddr => x_rbaddr, rdata => x_rdata);

  dist : entity work.mv_dist
    generic map(BLK => BLK, ROWS_IF => 2*NT, NPORTS_S => 3, AXI_DW => 256, ADDR_W => 40,
                DEPTH => 64, MAXB => 16, MAXOUT => 16, MAXCOLS => MAXC)
    port map(clk => aclk, rst => rst, go => go, j_nb => j_nb, j_rows => j_rows,
             j_lastv => j_lastv, j_os => j_os, j_mode => j_mode, j_cb => j_cb,
             s_base => (others => '0'), s_beats => s_beats,
             x_rbaddr => x_rbaddr, x_rdata => x_rdata,
             m_arvalid => arv, m_arready => arr, m_araddr => ara, m_arlen => arl,
             m_arsize => ars, m_arburst => arb, m_rvalid => rv, m_rready => rr,
             m_rdata => rd, m_rlast => rl,
             o_v => d_v, o_kind => d_k, o_x => d_x, o_s => d_s, o_first => d_f,
             o_last => d_l, room_all => room_all, busy => busy);

  gm : for q in 0 to 2 generate
    sm : entity work.axi_rd_mem_model
      generic map(AXI_DW => 256, ADDR_W => 40, NWORDS => 256, SEED => 11 + q, GAPPCT => 20)
      port map(clk => aclk, rst => rst, arvalid => arv(q), arready => arr(q),
               araddr => ara(q*40+39 downto q*40), arlen => arl(q*8+7 downto q*8),
               rvalid => rv(q), rready => rr(q), rdata => rd(q*256+255 downto q*256),
               rlast => rl(q), wr_en => s_wr, wr_addr => s_wa, wr_data => s_wd(q));
  end generate;

  tree : entity work.mv_xbcast
    generic map(NT => NT, G => 6, XW => XW)
    port map(clk => aclk, rst => rst, i_v => d_v, i_kind => d_k, i_x => d_x, i_s => d_s,
             i_first => d_f, i_last => d_l, o_v => o_v, o_kind => o_k, o_x => o_x,
             o_s => o_s, o_first => o_f, o_last => o_l, rooms => rooms,
             room_all => room_all);

  run : process
    type xmem_t is array(0 to MAXC-1) of std_logic_vector(15 downto 0);
    type sm_t is array(0 to 255) of std_logic_vector(3*256-1 downto 0);
    type nat_arr is array(0 to NT-1) of natural;
    variable xm : xmem_t;
    variable sm : sm_t;
    variable got, lvl : nat_arr;
    variable rng : unsigned(31 downto 0) := x"C0FFEE11";
    variable cbv : std_logic_vector(127 downto 0);
    variable checks, fails, cyc, stall0 : natural := 0;
    variable ncols, nrows, nb, ntl, total, osv, mdv, lastv : natural;
    variable fi, t, bb : natural;
    variable ek : std_logic_vector(1 downto 0);
    variable ex : std_logic_vector(XW-1 downto 0);
    variable es : std_logic_vector(31 downto 0);
    variable ef, el : std_logic;
    variable allin : boolean;
    type job_t is record cols, rows, os, md : natural; end record;
    type jobs_t is array(0 to 5) of job_t;
    constant JOBS : jobs_t := ((96, 48, 3, 0), (100, 96, 40, 1), (31, 1, 0, 2),
                               (1024, 50, 7, 0), (33, 144, 12, 1), (257, 49, 0, 0));
    procedure rnd is
    begin
      rng := rng xor shift_left(rng, 13);
      rng := rng xor shift_right(rng, 17);
      rng := rng xor shift_left(rng, 5);
    end procedure;
    procedure chk(c : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not c then
        fails := fails + 1;
        report "tb_mv_dist: MISMATCH " & msg severity error;
      end if;
    end procedure;
  begin
    rst <= '1';
    for i in 1 to 10 loop wait until rising_edge(aclk); end loop;
    rst <= '0';
    for jb in JOBS'range loop
      ncols := JOBS(jb).cols; nrows := JOBS(jb).rows;
      osv := JOBS(jb).os; mdv := JOBS(jb).md;
      nb := (ncols + BLK - 1) / BLK;
      ntl := (nrows + 2*NT - 1) / (2*NT);
      lastv := ncols - (nb - 1) * BLK;
      total := 17 + ntl * nb;
      -- activations: every element of the memory, so stale columns are nonzero
      for k in 0 to MAXC-1 loop
        rnd;
        xm(k) := std_logic_vector(rng(15 downto 0));
        x_we <= '1'; x_waddr <= std_logic_vector(to_unsigned(k, 10)); x_wdata <= xm(k);
        wait until rising_edge(wclk);
      end loop;
      x_we <= '0';
      -- scales, one superword per (row-tile, block)
      for i in 0 to ntl * nb - 1 loop
        for q in 0 to 2 loop
          for w in 0 to 7 loop
            rnd;
            sm(i)(q*256 + w*32 + 31 downto q*256 + w*32) := std_logic_vector(rng);
          end loop;
          s_wd(q) <= sm(i)(q*256 + 255 downto q*256);
        end loop;
        s_wr <= '1'; s_wa <= i;
        wait until rising_edge(aclk);
      end loop;
      s_wr <= '0';
      for e in 0 to 15 loop
        rnd; cbv(e*8+7 downto e*8) := std_logic_vector(rng(7 downto 0));
      end loop;
      j_nb <= nb; j_rows <= nrows; j_lastv <= lastv;
      j_os <= std_logic_vector(to_unsigned(osv, 6));
      j_mode <= std_logic_vector(to_unsigned(mdv, 2));
      j_cb <= cbv; s_beats <= ntl * nb;
      for t2 in 0 to NT-1 loop got(t2) := 0; end loop;
      wait until rising_edge(aclk);
      go <= '1';
      wait until rising_edge(aclk);
      go <= '0';
      cyc := 0;
      loop
        -- leaves: arrivals are checked against the expected sequence
        for t2 in 0 to NT-1 loop
          if o_v(t2) = '1' then
            fi := got(t2);
            chk(fi < total, "tile " & integer'image(t2) & " got more than " & integer'image(total) & " flits");
            if fi < total then
              ex := (others => '0'); es := (others => '0'); ef := '0'; el := '0';
              if fi = 0 then
                ek := "10";
                ex(5 downto 0) := std_logic_vector(to_unsigned(osv, 6));
                ex(7 downto 6) := std_logic_vector(to_unsigned(mdv, 2));
              elsif fi <= 16 then
                ek := "01";
                ex(3 downto 0) := std_logic_vector(to_unsigned(fi - 1, 4));
                ex(11 downto 4) := cbv((fi-1)*8+7 downto (fi-1)*8);
              else
                ek := "00";
                t := (fi - 17) / nb; bb := (fi - 17) mod nb;
                for j in 0 to BLK-1 loop
                  if bb*BLK + j < ncols then ex(j*16+15 downto j*16) := xm(bb*BLK + j); end if;
                end loop;
                es := sm(fi - 17)(t2*32 + 31 downto t2*32);
                if bb = 0 then ef := '1'; end if;
                if bb = nb - 1 then el := '1'; end if;
              end if;
              -- s, first and last are don't-care on PARAM and CB flits (mv_tile ignores them)
              chk(o_k(t2*2+1 downto t2*2) = ek and o_x((t2+1)*XW-1 downto t2*XW) = ex
                  and (ek /= "00" or (o_s(t2*32+31 downto t2*32) = es
                                      and o_f(t2) = ef and o_l(t2) = el)),
                  "job " & integer'image(jb) & " tile " & integer'image(t2) & " k=" & to_hstring(o_k(t2*2+1 downto t2*2)) & " x=" & to_hstring(o_x(t2*XW+15 downto t2*XW)) & " ex=" & to_hstring(ex(15 downto 0)) & " s=" & to_hstring(o_s(t2*32+31 downto t2*32)) & " es=" & to_hstring(es) & " fl=" & std_logic'image(o_f(t2)) & std_logic'image(o_l(t2)) & " flit "
                  & integer'image(fi));
            end if;
            got(t2) := fi + 1;
            lvl(t2) := lvl(t2) + 1;
            assert lvl(t2) <= XD report "tb_mv_dist: tile " & integer'image(t2)
              & " flit FIFO overflow (level " & integer'image(lvl(t2)) & " > XD)" severity failure;
          end if;
        end loop;
        -- leaves: random pops, tile 0 stalls in long runs
        rnd;
        if stall0 > 0 then stall0 := stall0 - 1;
        elsif to_integer(rng(9 downto 0)) < 8 then stall0 := 150; end if;
        for t2 in 0 to NT-1 loop
          rnd;
          if lvl(t2) > 0 and to_integer(rng(6 downto 0)) mod 4 /= 0
             and not (t2 = 0 and stall0 > 0) then
            lvl(t2) := lvl(t2) - 1;
          end if;
          if lvl(t2) < XD - SLACK then rooms(t2) <= '1'; else rooms(t2) <= '0'; end if;
        end loop;
        allin := true;
        for t2 in 0 to NT-1 loop
          if got(t2) /= total then allin := false; end if;
        end loop;
        exit when allin and busy = '0';
        cyc := cyc + 1;
        assert cyc < 100000 report "tb_mv_dist: job " & integer'image(jb) & " timed out"
          severity failure;
        wait until rising_edge(aclk);
      end loop;
      -- nothing more may arrive
      for i in 1 to 40 loop
        wait until rising_edge(aclk);
        chk(o_v = (o_v'range => '0'), "a flit after the job's last");
      end loop;
    end loop;
    assert fails = 0 report "tb_mv_dist: FAIL " & integer'image(fails) severity failure;
    report "PASS: tb_mv_dist checks=" & integer'image(checks) severity note;
    done_sim <= true;
    wait;
  end process;
end architecture;
```

- [ ] **Step 2: Run it and watch it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/a450_t4_red bash sim/regress.sh --suite sim --only tb_mv_dist --keep`
Expected: the row is `BUILD-ERROR` (no entity `mv_dist`), `OVERALL PASS 0`.

- [ ] **Step 3: Write the memory, the tree and the distributor**

`rtl/act_mem_dp.vhd`:

```vhdl
-- rtl/act_mem_dp.vhd -- subsystem A's activation memory with a write clock and a read
-- clock (a450 spec 2.2).  Same organisation and the same 1-cycle registered read as
-- rtl/act_mem_striped.vhd: word = BLK elements of W bits, element a lives in word a/BLK at
-- lane a mod BLK.  Written on the core clock by the existing load path, read on aclk_a by
-- rtl/mv_dist.vhd.  The sequencer loads x before it starts a job and does not write it
-- during one, so no address is ever read and written in the same cycle pair.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity act_mem_dp is
  generic(
    ELEMS : positive := 17408;
    BLK   : positive := 32;
    W     : positive := 16
  );
  port(
    wclk   : in  std_logic;
    we     : in  std_logic;
    waddr  : in  std_logic_vector(clog2(ELEMS)-1 downto 0);
    wdata  : in  std_logic_vector(W-1 downto 0);
    rclk   : in  std_logic;
    rbaddr : in  std_logic_vector(clog2((ELEMS+BLK-1)/BLK)-1 downto 0);
    rdata  : out std_logic_vector(BLK*W-1 downto 0)
  );
end entity;

architecture rtl of act_mem_dp is
  constant WORDS : positive := (ELEMS + BLK - 1) / BLK;
  type mem_t is array(0 to WORDS-1) of std_logic_vector(BLK*W-1 downto 0);
  signal mem : mem_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";
  signal rw : std_logic_vector(BLK*W-1 downto 0) := (others => '0');
begin
  wr : process(wclk)
    variable a, word, lane : integer;
  begin
    if rising_edge(wclk) then
      if we = '1' then
        a    := to_integer(unsigned(waddr));
        word := a / BLK;
        lane := a mod BLK;
        for j in 0 to BLK-1 loop
          if lane = j then
            mem(word)((j+1)*W-1 downto j*W) <= wdata;
          end if;
        end loop;
      end if;
    end if;
  end process;

  rd : process(rclk)
  begin
    if rising_edge(rclk) then
      rw <= mem(to_integer(unsigned(rbaddr)));
    end if;
  end process;
  rdata <= rw;
end architecture;
```

`rtl/mv_xbcast.vhd`:

```vhdl
-- rtl/mv_xbcast.vhd -- the a450 distribution tree and the room AND tree (spec 2.2).
--
-- One flit enters per cycle at most and reaches every tile three register levels later:
--   root (1 copy)  ->  mid (NT/G copies, each carrying the scales of its G tiles)
--                  ->  leaf (NT copies, each carrying its own tile's 32 scale bits)
-- Every copy is its own register (dont_touch: the copies are logically equal and
-- equivalent-register removal would otherwise merge them back into the one wide net
-- this tree exists to avoid).  A copy carries only the scale bits its subtree needs,
-- so dont_touch keeps no dead flops.
--
-- room_all is the AND of the tiles' registered rooms through a mid AND register and a
-- root AND register: the only NT-input signal in A, and never on a single-cycle path.
-- Latency: flits 3 cycles in, room 2 cycles back (plus the tile's own room register).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mv_xbcast is
  generic(
    NT : positive := 24;
    G  : positive := 6;      -- tiles per mid copy; NT mod G must be 0
    XW : positive := 512
  );
  port(
    clk, rst : in  std_logic;
    i_v      : in  std_logic;
    i_kind   : in  std_logic_vector(1 downto 0);
    i_x      : in  std_logic_vector(XW-1 downto 0);
    i_s      : in  std_logic_vector(NT*32-1 downto 0);
    i_first  : in  std_logic;
    i_last   : in  std_logic;
    o_v      : out std_logic_vector(NT-1 downto 0);
    o_kind   : out std_logic_vector(NT*2-1 downto 0);
    o_x      : out std_logic_vector(NT*XW-1 downto 0);
    o_s      : out std_logic_vector(NT*32-1 downto 0);
    o_first  : out std_logic_vector(NT-1 downto 0);
    o_last   : out std_logic_vector(NT-1 downto 0);
    rooms    : in  std_logic_vector(NT-1 downto 0);
    room_all : out std_logic
  );
end entity;

architecture rtl of mv_xbcast is
  constant NM : positive := NT / G;
  constant CHK_G : natural := 1 - (NT mod G);   -- out of range unless G divides NT
  type xa_t is array(natural range <>) of std_logic_vector(XW-1 downto 0);
  type ga_t is array(natural range <>) of std_logic_vector(G*32-1 downto 0);
  type ka_t is array(natural range <>) of std_logic_vector(1 downto 0);
  -- root
  signal r_v, r_f, r_l : std_logic := '0';
  signal r_k : std_logic_vector(1 downto 0) := "00";
  signal r_x : std_logic_vector(XW-1 downto 0) := (others => '0');
  signal r_s : std_logic_vector(NT*32-1 downto 0) := (others => '0');
  -- mid
  signal m_v, m_f, m_l : std_logic_vector(NM-1 downto 0) := (others => '0');
  signal m_k : ka_t(0 to NM-1) := (others => "00");
  signal m_x : xa_t(0 to NM-1) := (others => (others => '0'));
  signal m_s : ga_t(0 to NM-1) := (others => (others => '0'));
  -- leaf
  signal l_v, l_f, l_l : std_logic_vector(NT-1 downto 0) := (others => '0');
  signal l_k : ka_t(0 to NT-1) := (others => "00");
  signal l_x : xa_t(0 to NT-1) := (others => (others => '0'));
  signal l_s : std_logic_vector(NT*32-1 downto 0) := (others => '0');
  -- rooms
  signal mr : std_logic_vector(NM-1 downto 0) := (others => '0');
  signal ra : std_logic := '0';
  attribute dont_touch : string;
  attribute dont_touch of m_v : signal is "true";
  attribute dont_touch of m_f : signal is "true";
  attribute dont_touch of m_l : signal is "true";
  attribute dont_touch of m_k : signal is "true";
  attribute dont_touch of m_x : signal is "true";
  attribute dont_touch of l_v : signal is "true";
  attribute dont_touch of l_f : signal is "true";
  attribute dont_touch of l_l : signal is "true";
  attribute dont_touch of l_k : signal is "true";
  attribute dont_touch of l_x : signal is "true";
begin
  p : process(clk)
    variable a : std_logic;
  begin
    if rising_edge(clk) then
      r_k <= i_kind; r_x <= i_x; r_s <= i_s; r_f <= i_first; r_l <= i_last;
      for k in 0 to NM-1 loop
        m_k(k) <= r_k; m_x(k) <= r_x; m_f(k) <= r_f; m_l(k) <= r_l;
        m_s(k) <= r_s((k+1)*G*32-1 downto k*G*32);
      end loop;
      for t in 0 to NT-1 loop
        l_k(t) <= m_k(t / G); l_x(t) <= m_x(t / G);
        l_f(t) <= m_f(t / G); l_l(t) <= m_l(t / G);
        l_s(t*32+31 downto t*32) <= m_s(t / G)((t mod G)*32+31 downto (t mod G)*32);
      end loop;
      for k in 0 to NM-1 loop
        a := '1';
        for i in 0 to G-1 loop a := a and rooms(k*G + i); end loop;
        mr(k) <= a;
      end loop;
      a := '1';
      for k in 0 to NM-1 loop a := a and mr(k); end loop;
      ra <= a;
      if rst = '1' then
        r_v <= '0'; m_v <= (others => '0'); l_v <= (others => '0');
        mr <= (others => '0'); ra <= '0';
      else
        r_v <= i_v;
        m_v <= (others => r_v);
        for t in 0 to NT-1 loop l_v(t) <= m_v(t / G); end loop;
      end if;
    end if;
  end process;

  room_all <= ra;
  o_v <= l_v; o_first <= l_f; o_last <= l_l; o_s <= l_s;
  g_o : for t in 0 to NT-1 generate
    o_kind(t*2+1 downto t*2) <= l_k(t);
    o_x((t+1)*XW-1 downto t*XW) <= l_x(t);
  end generate;
end architecture;
```

`rtl/mv_dist.vhd`:

```vhdl
-- rtl/mv_dist.vhd -- the a450 x/scale distributor (spec 2.2), in aclk_a.
--
-- On `go` (a one-cycle pulse; the job inputs are stable from it to the job's end, the
-- back end holds them) it starts the NPORTS_S scale ports and sends, in order and only
-- while room_all is '1':
--   1 PARAM flit   x[5:0] = out_shift, x[7:6] = out_mode
--   16 CB flits    x[3:0] = entry, x[11:4] = the int8 codebook value
--   one ITEM per (row-tile t, block b), b fastest: x = activation block b with every
--                  column at or past n_cols forced to 0, s = the 48 scales of the scale
--                  superword (scale port q is rows 16q..16q+15, spec 6.5a), first = (b = 0),
--                  last = (b = nb-1)
-- Pad columns are zeroed HERE, so a tile needs no column count: a zero activation
-- contributes exactly the 0 that matvec_core's `k < n_cols` arm writes.
--
-- Two stages: A decides and pops (scale FIFOs, block counter, the activation read
-- address), B lands the 1-cycle activation read and masks it.  Both outputs registered.
-- The row-tile count comes from rows_left counting down by ROWS_IF, never a divide.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity mv_dist is
  generic(
    BLK      : positive := 32;
    ROWS_IF  : positive := 48;
    NPORTS_S : positive := 3;
    AXI_DW   : positive := 256;
    ADDR_W   : positive := 40;
    DEPTH    : positive := 512;
    MAXB     : positive := 16;
    MAXOUT   : positive := 16;
    MAXCOLS  : positive := 17408
  );
  port(
    clk, rst  : in  std_logic;
    go        : in  std_logic;
    j_nb      : in  natural;                      -- ceil(n_cols / BLK)
    j_rows    : in  natural;                      -- n_rows
    j_lastv   : in  natural;                      -- valid columns in the last block, 1..BLK
    j_os      : in  std_logic_vector(5 downto 0);
    j_mode    : in  std_logic_vector(1 downto 0);
    j_cb      : in  std_logic_vector(127 downto 0);   -- entry e at [8e+7:8e]
    s_base    : in  std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats   : in  integer;
    x_rbaddr  : out std_logic_vector(clog2((MAXCOLS+BLK-1)/BLK)-1 downto 0);
    x_rdata   : in  std_logic_vector(BLK*16-1 downto 0);
    m_arvalid : out std_logic_vector(NPORTS_S-1 downto 0);
    m_arready : in  std_logic_vector(NPORTS_S-1 downto 0);
    m_araddr  : out std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector(NPORTS_S*8-1 downto 0);
    m_arsize  : out std_logic_vector(NPORTS_S*3-1 downto 0);
    m_arburst : out std_logic_vector(NPORTS_S*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORTS_S-1 downto 0);
    m_rready  : out std_logic_vector(NPORTS_S-1 downto 0);
    m_rdata   : in  std_logic_vector(NPORTS_S*AXI_DW-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORTS_S-1 downto 0);
    o_v       : out std_logic;
    o_kind    : out std_logic_vector(1 downto 0);
    o_x       : out std_logic_vector(BLK*16-1 downto 0);
    o_s       : out std_logic_vector(ROWS_IF*16-1 downto 0);
    o_first   : out std_logic;
    o_last    : out std_logic;
    room_all  : in  std_logic;
    busy      : out std_logic
  );
end entity;

architecture rtl of mv_dist is
  -- GRP = 1 only: one superword is exactly one row-tile's scales (ROWS_IF = 48, 3 x 256).
  constant CHK_GRP : natural := 1 - abs(NPORTS_S*AXI_DW - ROWS_IF*16);
  type st_t is (D_IDLE, D_PAR, D_CB, D_RUN);
  signal st : st_t := D_IDLE;
  type qd_t is array(0 to NPORTS_S-1) of std_logic_vector(AXI_DW-1 downto 0);
  signal qv : std_logic_vector(NPORTS_S-1 downto 0);
  signal qd : qd_t;
  signal s_allv, s_take : std_logic;
  signal s_start : std_logic := '0';
  signal nb_r, rows_left : natural := 0;
  signal b    : natural range 0 to (MAXCOLS+BLK-1)/BLK := 0;
  signal cbi  : natural range 0 to 15 := 0;
  signal lvm  : std_logic_vector(BLK-1 downto 0) := (others => '1');
  signal os_r : std_logic_vector(5 downto 0) := (others => '0');
  signal md_r : std_logic_vector(1 downto 0) := "00";
  signal cb_r : std_logic_vector(127 downto 0) := (others => '0');
  -- stage A
  signal a_v, a_f, a_l : std_logic := '0';
  signal a_k   : std_logic_vector(1 downto 0) := "00";
  signal a_pay : std_logic_vector(11 downto 0) := (others => '0');
  signal a_s   : std_logic_vector(ROWS_IF*16-1 downto 0) := (others => '0');
  signal a_msk : std_logic_vector(BLK-1 downto 0) := (others => '1');
  -- stage B
  signal b_v, b_f, b_l : std_logic := '0';
  signal b_k : std_logic_vector(1 downto 0) := "00";
  signal b_x : std_logic_vector(BLK*16-1 downto 0) := (others => '0');
  signal b_s : std_logic_vector(ROWS_IF*16-1 downto 0) := (others => '0');
begin
  gen_s : for q in 0 to NPORTS_S-1 generate
    sport : entity work.axi_rd_port
      generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH, MAXB => MAXB,
                  MAXOUT => MAXOUT, DUAL_CLK => false, FAST_POP => true)
      port map(clk => clk, rst => rst, start => s_start,
               base => s_base((q+1)*ADDR_W-1 downto q*ADDR_W), n_beats => s_beats,
               arvalid => m_arvalid(q), arready => m_arready(q),
               araddr => m_araddr((q+1)*ADDR_W-1 downto q*ADDR_W),
               arlen => m_arlen((q+1)*8-1 downto q*8),
               arsize => m_arsize((q+1)*3-1 downto q*3),
               arburst => m_arburst((q+1)*2-1 downto q*2),
               rvalid => m_rvalid(q), rready => m_rready(q),
               rdata => m_rdata((q+1)*AXI_DW-1 downto q*AXI_DW), rlast => m_rlast(q),
               q_valid => qv(q), q_data => qd(q), q_ready => s_take);
  end generate;

  agg : process(qv)
    variable a : std_logic;
  begin
    a := '1';
    for q in 0 to NPORTS_S-1 loop a := a and qv(q); end loop;
    s_allv <= a;
  end process;

  s_take   <= '1' when st = D_RUN and room_all = '1' and s_allv = '1' else '0';
  x_rbaddr <= std_logic_vector(to_unsigned(b, x_rbaddr'length));
  busy     <= '0' when st = D_IDLE else '1';

  p : process(clk)
  begin
    if rising_edge(clk) then
      a_v <= '0';
      s_start <= '0';
      -- stage B: land the activation read, mask the pad columns
      b_v <= a_v; b_k <= a_k; b_f <= a_f; b_l <= a_l; b_s <= a_s;
      b_x <= (others => '0');
      if a_k = "00" then
        for j in 0 to BLK-1 loop
          if a_msk(j) = '1' then b_x(j*16+15 downto j*16) <= x_rdata(j*16+15 downto j*16); end if;
        end loop;
      else
        b_x(11 downto 0) <= a_pay;
      end if;
      -- stage A
      case st is
        when D_IDLE =>
          if go = '1' then
            nb_r <= j_nb; rows_left <= j_rows; b <= 0; cbi <= 0;
            os_r <= j_os; md_r <= j_mode; cb_r <= j_cb;
            for j in 0 to BLK-1 loop
              if j < j_lastv then lvm(j) <= '1'; else lvm(j) <= '0'; end if;
            end loop;
            s_start <= '1';
            st <= D_PAR;
          end if;
        when D_PAR =>
          if room_all = '1' then
            a_v <= '1'; a_k <= "10";
            a_pay <= "0000" & md_r & os_r;
            st <= D_CB;
          end if;
        when D_CB =>
          if room_all = '1' then
            a_v <= '1'; a_k <= "01";
            a_pay <= cb_r(cbi*8+7 downto cbi*8) & std_logic_vector(to_unsigned(cbi, 4));
            if cbi = 15 then st <= D_RUN; else cbi <= cbi + 1; end if;
          end if;
        when D_RUN =>
          if s_take = '1' then
            a_v <= '1'; a_k <= "00";
            for q in 0 to NPORTS_S-1 loop
              a_s((q+1)*AXI_DW-1 downto q*AXI_DW) <= qd(q);
            end loop;
            if b = 0 then a_f <= '1'; else a_f <= '0'; end if;
            if b = nb_r - 1 then
              a_l <= '1'; a_msk <= lvm; b <= 0;
              if rows_left <= ROWS_IF then st <= D_IDLE;
              else rows_left <= rows_left - ROWS_IF; end if;
            else
              a_l <= '0'; a_msk <= (others => '1'); b <= b + 1;
            end if;
          end if;
      end case;
      if rst = '1' then
        st <= D_IDLE; a_v <= '0'; b_v <= '0'; s_start <= '0';
      end if;
    end if;
  end process;

  o_v <= b_v; o_kind <= b_k; o_x <= b_x; o_s <= b_s; o_first <= b_f; o_last <= b_l;
end architecture;
```

- [ ] **Step 4: Run the bench row**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/a450_t4 bash sim/regress.sh --suite sim --only tb_mv_dist --keep`
Expected: `PASS: tb_mv_dist checks=9936` and `OVERALL PASS 1`.

- [ ] **Step 5: Sweep the credit sizing (spec section 5)**

```bash
cd /mnt/storage/fk33_builds/scratch/a450_t4/sim_tb_mv_dist/run
for a in "-gSLACK=3" "-gSLACK=8" "-gSLACK=12" "-gXD=24 -gSLACK=12"; do
  echo "ARGS $a"
  timeout 600 ghdl -r --std=08 -frelaxed --workdir=../work tb_mv_dist $a \
    --max-stack-alloc=0 --stop-time=2ms 2>&1 | grep -E 'PASS:|overflow|FAIL' | head -1
done
```
Expected (MEASURED 2026-11-12):
```
ARGS -gSLACK=3
...(assertion failure): tb_mv_dist: tile 0 flit FIFO overflow (level 33 > XD)
ARGS -gSLACK=8
...PASS: tb_mv_dist checks=9936
ARGS -gSLACK=12
...PASS: tb_mv_dist checks=9936
ARGS -gXD=24 -gSLACK=12
...PASS: tb_mv_dist checks=9936
```
SLACK 3 must fail: that row is the bench's own teeth for the overflow check. `SLACK = LF + LR + 4 = 12` keeps 4 words of margin over the measured minimum of 8.

- [ ] **Step 6: Write and run the mutants**

`sim/mutants/mv_dist.json` (D1 is the credit-loss mutant of spec 3.1 at unit level; D2 pad masking; D3 scale routing; D4 activation address):

```json
{
  "tb": "tb_mv_dist",
  "deps": ["rtl/util_pkg.vhd", "rtl/stream_fifo.vhd", "rtl/async_fifo.vhd", "rtl/axi_rd_fsm.vhd",
           "rtl/axi_rd_port.vhd", "rtl/act_mem_dp.vhd", "rtl/mv_dist.vhd", "rtl/mv_xbcast.vhd",
           "sim/axi_rd_mem_model.vhd", "sim/tb_mv_dist.vhd"],
  "stop_time": "2ms",
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "D1", "expect": "KILLED", "file": "rtl/mv_xbcast.vhd",
     "why": "credit loss: the room AND tree ignores tile 0",
     "old": "for i in 0 to G-1 loop a := a and rooms(k*G + i); end loop;",
     "new": "for i in 0 to G-1 loop if k*G + i /= 0 then a := a and rooms(k*G + i); end if; end loop;"},
    {"tag": "D2", "expect": "KILLED", "file": "rtl/mv_dist.vhd",
     "why": "pad columns of the last block are not zeroed",
     "old": "a_l <= '1'; a_msk <= lvm; b <= 0;",
     "new": "a_l <= '1'; a_msk <= (others => '1'); b <= 0;"},
    {"tag": "D3", "expect": "KILLED", "file": "rtl/mv_xbcast.vhd",
     "why": "every tile gets the first mid copy's scales",
     "old": "l_s(t*32+31 downto t*32) <= m_s(t / G)((t mod G)*32+31 downto (t mod G)*32);",
     "new": "l_s(t*32+31 downto t*32) <= m_s(0)((t mod G)*32+31 downto (t mod G)*32);"},
    {"tag": "D4", "expect": "KILLED", "file": "rtl/mv_dist.vhd",
     "why": "the activation read address runs one block ahead",
     "old": "x_rbaddr <= std_logic_vector(to_unsigned(b, x_rbaddr'length));",
     "new": "x_rbaddr <= std_logic_vector(to_unsigned((b + 1) mod (MAXCOLS/BLK), x_rbaddr'length));"}
  ]
}
```

`stop_time` is 2 ms against a passing run's 51.5 us: a mutant that deadlocks ends at the stop time without the PASS line (KILLED) instead of running into the 1,800 s timeout.

Run: `python3 sim/mutate_rows.py sim/mutants/mv_dist.json`
Expected: `MUTROW Z0 PASS PASS`, D1 to D4 `KILLED KILLED`, `MUTANTS_OK 5`.

- [ ] **Step 7: Commit**

```bash
git add rtl/act_mem_dp.vhd rtl/mv_xbcast.vhd rtl/mv_dist.vhd sim/tb_mv_dist.vhd sim/mutants/mv_dist.json
git commit -m "a450 Task 4: distributor, broadcast tree and room AND tree; SLACK 3 overflows, 8 passes, 12 used"
```

---

### Task 5: Result chain and the crossings

**Files:**
- Create: `rtl/mv_tsync.vhd`, `rtl/mv_rlink.vhd`, `rtl/mv_rchain.vhd`, `rtl/mv_rcross.vhd`
- Create: `sim/tb_mv_rchain.vhd`, `sim/mutants/mv_rchain.json`

**Interfaces:**
- Consumes: the tile's result port (`r_v`, `r_d(96:0)`, `r_rdy`, Task 2); `rtl/async_fifo.vhd` (`W`, `DEPTH`, `OUT_MARGIN`, `FAST_POP`, `w_level`).
- Produces:
  - `entity mv_tsync port(sclk, srst; s_pulse; dclk, drst; d_pulse)`: one `s_pulse` gives exactly one `d_pulse` (toggle, two `async_reg` flops, edge detect). Pulses must be at least 3 `dclk` cycles apart.
  - `entity mv_rlink generic(K 0, NT 24, W 97) port(clk, rst; o_v, o_d, o_rdy (own tile); u_v, u_d, u_afull (from stage K+1); d_v, d_d, d_afull (to stage K-1))`: per row-tile it sends its own word, then passes `NT-1-K` upstream words, so stage 0 emits tile 0, 1, ..., NT-1 in order with no tags.
  - `entity mv_rchain generic(NT 24, W 97) port(clk, rst; own_v(NT-1:0); own_d(NT*W-1:0); own_rdy(NT-1:0); d_v; d_d; d_afull)`.
  - `entity mv_rcross generic(W 97, DEPTH 16) port(wclk, wrst; w_v; w_d; w_afull; rclk, rrst; q_valid; q_data; q_ready)`: `w_afull` is registered, high at `w_level >= DEPTH - 6`.

- [ ] **Step 1: Write the bench**

`sim/tb_mv_rchain.vhd` (two systems: chain plus crossing at 450:125 and at 125:125; 40 row-tiles of random tile completion times, random read back-pressure and 150-cycle read stalls; 50 start pulses through `mv_tsync`):

```vhdl
-- sim/tb_mv_rchain.vhd -- rtl/mv_rchain.vhd (+ mv_rlink), rtl/mv_rcross.vhd, rtl/mv_tsync.vhd.
--
-- Two systems run side by side: S (split) with the chain on aclk (450 MHz) and the
-- crossing's read side on clk (125 MHz), whose phase rolls against aclk because
-- 8 / 2.222 is not an integer; and E (equal) with both sides on aclk, which is what
-- A_CLK_SPLIT = false builds.  In each, NT producer queues stand in for the tiles: word
-- (tile k, row-tile r) becomes available after a random, per-tile, cumulative delay, so
-- the tiles drift far apart.  The reader takes words under a random ready and checks the
-- one order the chain promises -- for r = 0.., tiles 0..NT-1 -- word for word, 97 bits
-- each, plus that nothing extra arrives.  mv_rcross fails on a write into a full FIFO,
-- so no word can be dropped silently; the reader stalls 150 cycles at random so the
-- crossing fills and its almost-full is exercised (mutant R3).  Last, PULSES start pulses cross clk -> aclk
-- through mv_tsync: exactly PULSES arrive, never two in adjacent cycles.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mv_rchain is
  generic(
    R      : positive := 40;
    PULSES : positive := 50
  );
end entity;

architecture sim of tb_mv_rchain is
  constant NT : positive := 24;
  constant W  : positive := 97;
  signal aclk, clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal done_sim : boolean := false;
  type sv_t is array(0 to 1) of std_logic_vector(NT-1 downto 0);
  type sd_t is array(0 to 1) of std_logic_vector(NT*W-1 downto 0);
  type w_t is array(0 to 1) of std_logic_vector(W-1 downto 0);
  signal own_v, own_rdy : sv_t := (others => (others => '0'));
  signal own_d : sd_t := (others => (others => '0'));
  signal cv, ca, qv, qr : std_logic_vector(0 to 1) := (others => '0');
  signal cd, qd : w_t;
  signal rclk : std_logic_vector(0 to 1);
  signal sp, dp : std_logic := '0';
  signal fin : std_logic_vector(0 to 1) := (others => '0');
  signal npulse : natural := 0;

  function word(k, rt : natural) return std_logic_vector is
    variable v : std_logic_vector(W-1 downto 0) := (others => '0');
    variable h : unsigned(31 downto 0);
  begin
    h := to_unsigned((k * 7919 + rt * 104729 + 13) mod 2147483647, 32);
    v(15 downto 0) := std_logic_vector(to_unsigned(k, 16));
    v(31 downto 16) := std_logic_vector(to_unsigned(rt, 16));
    v(63 downto 32) := std_logic_vector(h);
    v(95 downto 64) := std_logic_vector(h xor x"A5A5A5A5");
    v(96) := h(3);
    return v;
  end function;
begin
  aclk <= not aclk after 1.111 ns when not done_sim else '0';
  clk  <= not clk after 4 ns when not done_sim else '0';
  rclk(0) <= clk;
  rclk(1) <= aclk;

  g : for s in 0 to 1 generate
    ch : entity work.mv_rchain
      generic map(NT => NT, W => W)
      port map(clk => aclk, rst => rst, own_v => own_v(s), own_d => own_d(s),
               own_rdy => own_rdy(s), d_v => cv(s), d_d => cd(s), d_afull => ca(s));
    cx : entity work.mv_rcross
      generic map(W => W, DEPTH => 16)
      port map(wclk => aclk, wrst => rst, w_v => cv(s), w_d => cd(s), w_afull => ca(s),
               rclk => rclk(s), rrst => rst, q_valid => qv(s), q_data => qd(s),
               q_ready => qr(s));

    prod : process
      type n_arr is array(0 to NT-1) of natural;
      variable nxt, due : n_arr := (others => 0);
      variable rng : unsigned(31 downto 0) := to_unsigned(977 + 31*s, 32);
      variable cyc : natural := 0;
      variable all_done : boolean;
    begin
      wait until rst = '0';
      for k in 0 to NT-1 loop due(k) := k * 3; end loop;
      loop
        wait until rising_edge(aclk);
        cyc := cyc + 1;
        all_done := true;
        for k in 0 to NT-1 loop
          if own_v(s)(k) = '1' and own_rdy(s)(k) = '1' then
            nxt(k) := nxt(k) + 1;
            rng := rng xor shift_left(rng, 13); rng := rng xor shift_right(rng, 17);
            rng := rng xor shift_left(rng, 5);
            -- drift: 0..63 cycles, and tile 5 is slow
            due(k) := cyc + to_integer(rng(5 downto 0)) + (k mod 6) * 2;
            if k = 5 then due(k) := due(k) + 90; end if;
          end if;
          if nxt(k) < R and cyc >= due(k) then
            own_v(s)(k) <= '1';
            own_d(s)((k+1)*W-1 downto k*W) <= word(k, nxt(k));
          else
            own_v(s)(k) <= '0';
          end if;
          if nxt(k) < R then all_done := false; end if;
        end loop;
        exit when all_done;
      end loop;
      wait;
    end process;

    cons : process
      variable rng : unsigned(31 downto 0) := to_unsigned(4441 + 7*s, 32);
      variable k, rt, checks, fails, idle, stall : natural := 0;
    begin
      wait until rst = '0';
      loop
        wait until rising_edge(rclk(s));
        if qv(s) = '1' and qr(s) = '1' then
          checks := checks + 1;
          if qd(s) /= word(k, rt) then
            fails := fails + 1;
            report "tb_mv_rchain: MISMATCH system " & integer'image(s) & " expected tile "
                 & integer'image(k) & " row-tile " & integer'image(rt) & " got tile "
                 & integer'image(to_integer(unsigned(qd(s)(15 downto 0)))) & " row-tile "
                 & integer'image(to_integer(unsigned(qd(s)(31 downto 16)))) severity error;
          end if;
          if k = NT-1 then k := 0; rt := rt + 1; else k := k + 1; end if;
        end if;
        rng := rng xor shift_left(rng, 13); rng := rng xor shift_right(rng, 17);
        rng := rng xor shift_left(rng, 5);
        -- random ready, plus a 150-cycle read stall about once per 128 cycles, so the
        -- crossing fills and its almost-full has to hold the chain back
        if stall > 0 then
          stall := stall - 1;
          qr(s) <= '0';
        elsif to_integer(rng(10 downto 4)) = 0 then
          stall := 150;
          qr(s) <= '0';
        elsif to_integer(rng(3 downto 0)) < 11 then qr(s) <= '1'; else qr(s) <= '0'; end if;
        if rt = R then
          idle := idle + 1;
          -- qv is sampled pre-edge, so the cycle of the last pop still shows it high
          assert idle < 3 or qv(s) = '0' report "tb_mv_rchain: a word after the last"
            severity failure;
          exit when idle > 200;
        end if;
      end loop;
      assert fails = 0 report "tb_mv_rchain: FAIL system " & integer'image(s) severity failure;
      report "tb_mv_rchain: system " & integer'image(s) & " " & integer'image(checks)
           & " words in order" severity note;
      fin(s) <= '1';
      wait;
    end process;
  end generate;

  ts : entity work.mv_tsync
    port map(sclk => clk, srst => rst, s_pulse => sp, dclk => aclk, drst => rst, d_pulse => dp);

  main : process
  begin
    rst <= '1';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for i in 1 to PULSES loop
      sp <= '1';
      wait until rising_edge(clk);
      sp <= '0';
      for j in 1 to 2 + (i mod 5) loop wait until rising_edge(clk); end loop;
    end loop;
    wait until fin = "11";
    assert npulse = PULSES report "tb_mv_rchain: FAIL mv_tsync delivered "
      & integer'image(npulse) & " of " & integer'image(PULSES) & " pulses" severity failure;
    report "PASS: tb_mv_rchain checks=" & integer'image(R * NT * 2 + PULSES) severity note;
    done_sim <= true;
    wait;
  end process;

  count : process(aclk)
    variable n : natural := 0;
    variable prev : std_logic := '0';
  begin
    if rising_edge(aclk) then
      if dp = '1' then
        n := n + 1;
        assert prev = '0' report "tb_mv_rchain: mv_tsync pulsed two cycles running" severity failure;
      end if;
      prev := dp;
      npulse <= n;
    end if;
  end process;
end architecture;
```

- [ ] **Step 2: Run it and watch it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/a450_t5_red bash sim/regress.sh --suite sim --only tb_mv_rchain --keep`
Expected: `BUILD-ERROR` (no entity `mv_rchain`), `OVERALL PASS 0`.

- [ ] **Step 3: Write the four units**

`rtl/mv_tsync.vhd`:

```vhdl
-- rtl/mv_tsync.vhd -- one-cycle pulse from one clock domain to another, by toggle.
-- The source flips a toggle on each pulse; the destination samples it through two
-- ASYNC_REG flops and a third, and pulses on the change.  Pulses must be at least four
-- destination cycles apart (A_JOB start is: the back end cannot start a second job
-- before the first has returned all its results).  With equal clocks it is a 3-cycle
-- delay, which is what A_CLK_SPLIT = false gets.
library ieee;
use ieee.std_logic_1164.all;

entity mv_tsync is
  port(
    sclk, srst : in  std_logic;
    s_pulse    : in  std_logic;
    dclk, drst : in  std_logic;
    d_pulse    : out std_logic
  );
end entity;

architecture rtl of mv_tsync is
  signal tog : std_logic := '0';
  signal s1, s2, s3 : std_logic := '0';
  attribute async_reg : string;
  attribute async_reg of s1 : signal is "TRUE";
  attribute async_reg of s2 : signal is "TRUE";
begin
  src : process(sclk)
  begin
    if rising_edge(sclk) then
      if srst = '1' then tog <= '0';
      elsif s_pulse = '1' then tog <= not tog;
      end if;
    end if;
  end process;

  dst : process(dclk)
  begin
    if rising_edge(dclk) then
      s1 <= tog; s2 <= s1;
      if drst = '1' then s3 <= s2; d_pulse <= '0';
      else s3 <= s2; d_pulse <= s2 xor s3;
      end if;
    end if;
  end process;
end architecture;
```

`rtl/mv_rlink.vhd`:

```vhdl
-- rtl/mv_rlink.vhd -- one stage of the a450 result chain (spec 2.3), beside tile K.
--
-- The chain runs from tile NT-1 (the head) down to tile 0 and on to the crossing.  For
-- every row-tile, stage K sends its OWN tile's result first and then passes exactly
-- NT-1-K words from upstream, which are tiles K+1..NT-1's results for that same row-tile
-- (stage K+1 obeys the same rule, so its stream is own(t), pass(t).., own(t+1), ...).
-- The words therefore leave stage 0 in the fixed order tile 0, 1, .., NT-1 per row-tile,
-- whatever the tiles' relative drift, with no tag and no reorder buffer.
--
-- Flow control is local: each stage holds upstream words in a 4-deep FIFO and tells
-- upstream to stop with a REGISTERED u_afull (count >= 2), so no ready signal chains
-- through stages.  With one cycle of decision and one of output register in flight a
-- stage can receive at most two words after asserting it: 4 is enough.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mv_rlink is
  generic(
    K  : natural  := 0;
    NT : positive := 24;
    W  : positive := 97
  );
  port(
    clk, rst : in  std_logic;
    o_v      : in  std_logic;                       -- own tile's result FIFO
    o_d      : in  std_logic_vector(W-1 downto 0);
    o_rdy    : out std_logic;
    u_v      : in  std_logic;                       -- from stage K+1
    u_d      : in  std_logic_vector(W-1 downto 0);
    u_afull  : out std_logic;
    d_v      : out std_logic;                       -- to stage K-1 (or the crossing)
    d_d      : out std_logic_vector(W-1 downto 0);
    d_afull  : in  std_logic
  );
end entity;

architecture rtl of mv_rlink is
  constant NPASS : natural := NT - 1 - K;
  type uf_t is array(0 to 3) of std_logic_vector(W-1 downto 0);
  signal uf : uf_t := (others => (others => '0'));
  signal uh, ut : natural range 0 to 3 := 0;
  signal un : natural range 0 to 4 := 0;
  signal own_ph : std_logic := '1';
  signal cnt : natural range 0 to NT := 0;
  signal ua_r, dv_r : std_logic := '0';
  signal dd_r : std_logic_vector(W-1 downto 0) := (others => '0');
  signal take_own, take_up : std_logic;
begin
  take_own <= '1' when own_ph = '1' and d_afull = '0' and o_v = '1' else '0';
  take_up  <= '1' when own_ph = '0' and d_afull = '0' and un > 0 else '0';
  o_rdy    <= '1' when own_ph = '1' and d_afull = '0' else '0';
  u_afull  <= ua_r;
  d_v      <= dv_r;
  d_d      <= dd_r;

  p : process(clk)
    variable n : natural range 0 to 5;
  begin
    if rising_edge(clk) then
      n := un;
      if u_v = '1' then
        uf(ut) <= u_d; ut <= (ut + 1) mod 4; n := n + 1;
      end if;
      if take_up = '1' then
        uh <= (uh + 1) mod 4; n := n - 1;
      end if;
      if take_own = '1' then dd_r <= o_d; else dd_r <= uf(uh); end if;
      dv_r <= take_own or take_up;
      if take_own = '1' and NPASS > 0 then
        own_ph <= '0'; cnt <= NPASS;
      elsif take_up = '1' then
        if cnt = 1 then own_ph <= '1'; end if;
        cnt <= cnt - 1;
      end if;
      un <= n;
      if n >= 2 then ua_r <= '1'; else ua_r <= '0'; end if;
      if rst = '1' then
        uh <= 0; ut <= 0; un <= 0; own_ph <= '1'; cnt <= 0; ua_r <= '0'; dv_r <= '0';
      end if;
      assert rst = '1' or not (u_v = '1' and un = 4)
        report "mv_rlink: upstream word into a full stage FIFO" severity failure;
    end if;
  end process;
end architecture;
```

`rtl/mv_rchain.vhd`:

```vhdl
-- rtl/mv_rchain.vhd -- the NT stages of the result chain (rtl/mv_rlink.vhd), wired head
-- (NT-1) to tail (0).  Stage K sits beside tile K; the pblock of tile K is meant to hold
-- both (spec 1.2), so every link is a neighbour-to-neighbour wire.
library ieee;
use ieee.std_logic_1164.all;

entity mv_rchain is
  generic(
    NT : positive := 24;
    W  : positive := 97
  );
  port(
    clk, rst : in  std_logic;
    own_v    : in  std_logic_vector(NT-1 downto 0);
    own_d    : in  std_logic_vector(NT*W-1 downto 0);
    own_rdy  : out std_logic_vector(NT-1 downto 0);
    d_v      : out std_logic;
    d_d      : out std_logic_vector(W-1 downto 0);
    d_afull  : in  std_logic
  );
end entity;

architecture rtl of mv_rchain is
  signal lv : std_logic_vector(NT downto 0);
  type ld_t is array(0 to NT) of std_logic_vector(W-1 downto 0);
  signal ld : ld_t;
  signal la : std_logic_vector(NT downto 0);
begin
  -- link k's output is lv(k); its upstream is lv(k+1); lv(NT) is the empty head input
  lv(NT) <= '0';
  ld(NT) <= (others => '0');
  la(0)  <= d_afull;
  g : for k in 0 to NT-1 generate
    lk : entity work.mv_rlink
      generic map(K => k, NT => NT, W => W)
      port map(clk => clk, rst => rst,
               o_v => own_v(k), o_d => own_d((k+1)*W-1 downto k*W), o_rdy => own_rdy(k),
               u_v => lv(k+1), u_d => ld(k+1), u_afull => la(k+1),
               d_v => lv(k), d_d => ld(k), d_afull => la(k));
  end generate;
  d_v <= lv(0);
  d_d <= ld(0);
end architecture;
```

`rtl/mv_rcross.vhd`:

```vhdl
-- rtl/mv_rcross.vhd -- the result words' crossing from aclk_a to clk_core (spec 2.3).
-- An async FIFO (rtl/async_fifo.vhd, gray pointers) and a REGISTERED almost-full for the
-- chain's tail stage: w_afull is '1' while the FIFO's conservative write-side level is at
-- or above DEPTH - 6, which leaves room for the two words a link can still send after
-- seeing it.  A write with the FIFO full is a failure assertion, never a drop.
library ieee;
use ieee.std_logic_1164.all;

entity mv_rcross is
  generic(
    W     : positive := 97;
    DEPTH : positive := 16     -- power of two
  );
  port(
    wclk, wrst : in  std_logic;
    w_v        : in  std_logic;
    w_d        : in  std_logic_vector(W-1 downto 0);
    w_afull    : out std_logic;
    rclk, rrst : in  std_logic;
    q_valid    : out std_logic;
    q_data     : out std_logic_vector(W-1 downto 0);
    q_ready    : in  std_logic
  );
end entity;

architecture rtl of mv_rcross is
  signal w_ready : std_logic;
  signal w_level : integer range 0 to 2*DEPTH + 3;
  signal af : std_logic := '1';
begin
  q : entity work.async_fifo
    generic map(W => W, DEPTH => DEPTH, OUT_MARGIN => 3, FAST_POP => true)
    port map(wclk => wclk, wrst => wrst, w_valid => w_v, w_data => w_d, w_ready => w_ready,
             w_level => w_level, clr => '0', clr_done => open,
             rclk => rclk, rrst => rrst, q_valid => q_valid, q_data => q_data,
             q_ready => q_ready);
  p : process(wclk)
  begin
    if rising_edge(wclk) then
      if wrst = '1' then af <= '1';
      elsif w_level >= DEPTH - 6 then af <= '1';
      else af <= '0'; end if;
      assert wrst = '1' or not (w_v = '1' and w_ready = '0')
        report "mv_rcross: a result word reached a full crossing FIFO" severity failure;
    end if;
  end process;
  w_afull <= af;
end architecture;
```

- [ ] **Step 4: Run the bench row**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/a450_t5 bash sim/regress.sh --suite sim --only tb_mv_rchain --keep`
Expected: `PASS: tb_mv_rchain checks=1970` and `OVERALL PASS 1`.

- [ ] **Step 5: Write and run the mutants**

`sim/mutants/mv_rchain.json` (R1 order, R2 chain almost-full late, R3 crossing almost-full late, T1 level instead of edge):

```json
{
  "tb": "tb_mv_rchain",
  "deps": ["rtl/util_pkg.vhd", "rtl/async_fifo.vhd", "rtl/mv_rlink.vhd", "rtl/mv_rchain.vhd",
           "rtl/mv_rcross.vhd", "rtl/mv_tsync.vhd", "sim/tb_mv_rchain.vhd"],
  "stop_time": "1ms",
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "R1", "expect": "KILLED", "file": "rtl/mv_rlink.vhd",
     "why": "a stage passes one upstream word too many per row-tile (order broken)",
     "old": "constant NPASS : natural := NT - 1 - K;",
     "new": "constant NPASS : natural := NT - K;"},
    {"tag": "R2", "expect": "KILLED", "file": "rtl/mv_rlink.vhd",
     "why": "the stage's almost-full comes two words late (its FIFO overflows)",
     "old": "if n >= 2 then ua_r <= '1'; else ua_r <= '0'; end if;",
     "new": "if n >= 4 then ua_r <= '1'; else ua_r <= '0'; end if;"},
    {"tag": "R3", "expect": "KILLED", "file": "rtl/mv_rcross.vhd",
     "why": "the crossing's almost-full rises only past full (w_level carries OUT_MARGIN + 1 = 4 of conservatism, so a threshold of DEPTH alone is still safe and survives)",
     "old": "elsif w_level >= DEPTH - 6 then af <= '1';",
     "new": "elsif w_level >= DEPTH + 8 then af <= '1';"},
    {"tag": "T1", "expect": "KILLED", "file": "rtl/mv_tsync.vhd",
     "why": "the start pulse is the synchronised level, not its edge",
     "old": "else s3 <= s2; d_pulse <= s2 xor s3;",
     "new": "else s3 <= s2; d_pulse <= s2;"}
  ]
}
```

`stop_time` is 1 ms against a passing run's 22.2 us. MEASURED: R1 deadlocks the chain, and at a 100 ms stop time it ran past 18 minutes. R3 is deliberately `DEPTH + 8`, not `DEPTH`: `async_fifo`'s `w_level` already carries `OUT_MARGIN + 1 = 4` words of conservatism, so a threshold of `DEPTH` is still safe, and a first draft with that mutant SURVIVED for that reason (MEASURED 2026-11-12). The bench's 150-cycle read stalls are what make the crossing fill at all.

Run: `python3 sim/mutate_rows.py sim/mutants/mv_rchain.json`
Expected: `MUTROW Z0 PASS PASS`, R1, R2, R3, T1 `KILLED KILLED`, `MUTANTS_OK 5`.

- [ ] **Step 6: Commit**

```bash
git add rtl/mv_tsync.vhd rtl/mv_rlink.vhd rtl/mv_rchain.vhd rtl/mv_rcross.vhd \
        sim/tb_mv_rchain.vhd sim/mutants/mv_rchain.json
git commit -m "a450 Task 5: result daisy chain, 97-bit crossing and start toggle sync, 4 mutants killed"
```

---
### Task 6: Composed A, `A_CLK_SPLIT`, and the equivalence bench

**Files:**
- Create: `rtl/mv_afast.vhd`, `rtl/mv_back.vhd`, `rtl/mv4i_tcore.vhd`, `rtl/mv4i_tiled.vhd`
- Create: `sim/tb_mv4i_tiled.vhd`, `sim/mutants/mv4i_tiled.json`
- Modify: `sim/regress.sh` (per-row timeout and `SLOW_TBS` for the two composed rows)

**Interfaces:**
- Consumes: `mv_tile` (Task 2), `act_mem_dp`, `mv_xbcast`, `mv_dist` (Task 4), `mv_tsync`, `mv_rchain`, `mv_rcross` (Task 5); `rtl/matvec_int4.vhd` as the bench's reference DUT.
- Produces:
  - `entity mv4i_tiled`: the port list of `matvec_int4` (same names, widths and meanings: `clk, rst, aclk, start, n_rows, n_cols, out_shift, w_exp, x_exp, out_mode, w_base, w_beats, s_base, s_beats, cb_we, cb_addr, cb_data, x_we, x_waddr, x_wdata, m_ar*/m_r*` for `NPORTS_W + NPORTS_S` ports, `y_we, y_addr, y_data, y_mask, y_exp, done, err, sat_event`), with `dbg_rtile` (one pulse per row-tile assembled, on `clk`) and `dbg_words : std_logic_vector(31 downto 0)` (the job's `nb`, words per tile per row-tile) instead of `dbg_wbeat`, `dbg_wstarve`, `dbg_sstarve`. Generics: those of `matvec_int4` minus `DUAL_CLK`, `CB_STYLE`, `FAST_POP`, plus `A_CLK_SPLIT : boolean := false`, `XD : positive := 32`, `G : positive := 6`. With `A_CLK_SPLIT` false, `aclk` is ignored and every port is on `clk`; with true, the `m_*` ports and the tiles are on `aclk`.
  - Task 7 relies on these instance paths: `<tiled>/g_split.u/back/go_r_reg` (start toggle source, `clk`), `<tiled>/g_split.u/fast/dist/s_start_reg` (`aclk`), tiles `<tiled>/g_split.u/fast/g_t[p].tile`, links `<tiled>/g_split.u/fast/chain/g[p].lk`.

- [ ] **Step 1: Write the equivalence bench**

`sim/tb_mv4i_tiled.vhd` (OLD `matvec_int4` on `clk` 125 MHz, SPLIT on `aclk` 450 MHz with a rolling phase, SAME on `clk`; 27 AXI models per DUT; on SPLIT, weight port 13 stalls 300 cycles at a rate of 8 per 1,024 cycles and weight port 0 and scale port 25 at 3 per 1,024; 17 jobs including the five Review Focus cases, the last a 200-item-per-tile raw job that outgrows the 64-beat weight FIFO):

```vhdl
-- sim/tb_mv4i_tiled.vhd -- the a450 composed-A equivalence bench (spec 3.1).
--
-- Three DUTs see the same jobs, the same weights, scales, activations and codebook:
--   OLD   rtl/matvec_int4.vhd at the JC geometry (ROWS_IF 48, 24+3 ports, 256-bit), the
--         design proven bit-exact on silicon, on clk (125 MHz)
--   SPLIT rtl/mv4i_tiled.vhd, A_CLK_SPLIT = true: tiles on aclk (450 MHz, rolling phase
--         against clk because 8 / 2.222 is not an integer)
--   SAME  rtl/mv4i_tiled.vhd, A_CLK_SPLIT = false: everything on clk
-- and every y beat (y_addr, y_data, y_mask, y_exp), and err, sat_event and y_exp at done,
-- must be IDENTICAL across the three, beat by beat, for every job.  Each DUT has its own
-- 27 AXI read models with their own random RVALID gaps; on SPLIT, weight ports 0 and 13
-- and scale port 1 (index 25) also stall for 300-cycle stretches, so tiles drift, tile
-- credits run out, and every tile starves at once.
--
-- Jobs: all three out modes, pad rows (n_rows not a multiple of 48), pad columns (n_cols
-- not a multiple of 32, with nonzero junk written past n_cols), a codebook over the
-- full int8 range (-128 included: the cascade's 28-bit wrap must equal the old tree's),
-- out_shift 0 and 40, a saturating job (raw: sat_event 1; partial: 0), three refused
-- descriptors (err), and a job after them (err and sat cleared).  Then the plan's Review
-- Focus cases: a raw job with n_rows above MAXROWS_BFP and one block per row (the LM-head
-- shape, and the crossing fills because tiles finish row-tiles faster than clk drains
-- them), the same weights with only the codebook changed, and a reset pulsed in the
-- middle of a job followed by a compared job.  Last, a raw job of 200 items per tile:
-- every earlier job fits in the 64-beat weight FIFO and in a tile's 32-deep flit FIFO,
-- so only this one makes a stalled port stop its tile while the others run on, which is
-- what the credit loop exists for (without it the credit-loss mutant C1 SURVIVED).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mv4i_tiled is
end entity;

architecture sim of tb_mv4i_tiled is
  constant NW   : positive := 24;
  constant NSP   : positive := 3;
  constant NP   : positive := NW + NSP;
  constant RI   : positive := 48;
  constant DW   : positive := 256;
  constant AW   : positive := 40;
  constant MAXC : positive := 2048;
  constant MAXR : positive := 240;
  constant NWRD : positive := 256;
  constant ND   : positive := 3;      -- 0 OLD, 1 SPLIT, 2 SAME
  signal clk, aclk : std_logic := '0';
  signal rst : std_logic := '1';
  signal done_sim : boolean := false;

  signal start, cb_we, x_we : std_logic := '0';
  signal n_rows, n_cols, out_shift, w_exp, x_exp, beats : std_logic_vector(31 downto 0) := (others => '0');
  signal out_mode : std_logic_vector(1 downto 0) := "00";
  signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
  signal cb_data : std_logic_vector(7 downto 0) := (others => '0');
  signal x_waddr, x_wdata : std_logic_vector(15 downto 0) := (others => '0');
  signal wr_en : std_logic := '0';
  signal wr_addr : natural := 0;
  type pw_t is array(0 to NP-1) of std_logic_vector(DW-1 downto 0);
  signal wr_data : pw_t := (others => (others => '0'));

  type v1_t  is array(0 to ND-1) of std_logic_vector(NP-1 downto 0);
  type va_t  is array(0 to ND-1) of std_logic_vector(NP*AW-1 downto 0);
  type v8_t  is array(0 to ND-1) of std_logic_vector(NP*8-1 downto 0);
  type v3_t  is array(0 to ND-1) of std_logic_vector(NP*3-1 downto 0);
  type v2_t  is array(0 to ND-1) of std_logic_vector(NP*2-1 downto 0);
  type vd_t  is array(0 to ND-1) of std_logic_vector(NP*DW-1 downto 0);
  signal arv, arr, rv, rr, rl : v1_t;
  signal ara : va_t; signal arl : v8_t; signal ars : v3_t; signal arb : v2_t;
  signal rd : vd_t;
  type yd_t is array(0 to ND-1) of std_logic_vector(RI*64-1 downto 0);
  type ym_t is array(0 to ND-1) of std_logic_vector(RI-1 downto 0);
  type y16_t is array(0 to ND-1) of std_logic_vector(15 downto 0);
  type y32_t is array(0 to ND-1) of std_logic_vector(31 downto 0);
  signal y_we, done, err, sat : std_logic_vector(0 to ND-1);
  signal y_addr : y16_t; signal y_data : yd_t; signal y_mask : ym_t; signal y_exp : y32_t;
  signal wbase : std_logic_vector(NW*AW-1 downto 0) := (others => '0');
  signal sbase : std_logic_vector(NSP*AW-1 downto 0) := (others => '0');

  -- the beat log each DUT appends to; the main process compares them
  constant MAXBT : positive := 16;
  type beat_t is record
    a : std_logic_vector(15 downto 0); d : std_logic_vector(RI*64-1 downto 0);
    m : std_logic_vector(RI-1 downto 0); e : std_logic_vector(31 downto 0);
  end record;
  type blog_t is array(0 to MAXBT-1) of beat_t;
  type logs_t is array(0 to ND-1) of blog_t;
  signal logs : logs_t;
  type cnt_t is array(0 to ND-1) of natural;
  signal nbeat : cnt_t := (others => 0);
  signal clr_log : std_logic := '0';
begin
  clk  <= not clk after 4 ns when not done_sim else '0';
  aclk <= not aclk after 1.111 ns when not done_sim else '0';

  old : entity work.matvec_int4
    generic map(BLK => 32, ROWS_IF => RI, NPORTS_W => NW, NPORTS_S => NSP, AXI_DW => DW,
                ADDR_W => AW, MAXCOLS => MAXC, MAXROWS_BFP => MAXR, FIFO_DEPTH => 64,
                MAXB => 16, MAXOUT => 16, DUAL_CLK => false, FAST_POP => false)
    port map(clk => clk, rst => rst, start => start, n_rows => n_rows, n_cols => n_cols,
             out_shift => out_shift, w_exp => w_exp, x_exp => x_exp, out_mode => out_mode,
             w_base => wbase, w_beats => beats, s_base => sbase, s_beats => beats,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
             m_arvalid => arv(0), m_arready => arr(0), m_araddr => ara(0), m_arlen => arl(0),
             m_arsize => ars(0), m_arburst => arb(0), m_rvalid => rv(0), m_rready => rr(0),
             m_rdata => rd(0), m_rlast => rl(0),
             y_we => y_we(0), y_addr => y_addr(0), y_data => y_data(0), y_mask => y_mask(0),
             y_exp => y_exp(0), done => done(0), err => err(0), sat_event => sat(0),
             dbg_wbeat => open, dbg_wstarve => open, dbg_sstarve => open);

  g_new : for d in 1 to 2 generate
    dut : entity work.mv4i_tiled
      generic map(BLK => 32, ROWS_IF => RI, NPORTS_W => NW, NPORTS_S => NSP, AXI_DW => DW,
                  ADDR_W => AW, MAXCOLS => MAXC, MAXROWS_BFP => MAXR, FIFO_DEPTH => 64,
                  MAXB => 16, MAXOUT => 16, A_CLK_SPLIT => (d = 1))
      port map(clk => clk, rst => rst, aclk => aclk, start => start, n_rows => n_rows,
               n_cols => n_cols, out_shift => out_shift, w_exp => w_exp, x_exp => x_exp,
               out_mode => out_mode, w_base => wbase, w_beats => beats, s_base => sbase,
               s_beats => beats, cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
               x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
               m_arvalid => arv(d), m_arready => arr(d), m_araddr => ara(d),
               m_arlen => arl(d), m_arsize => ars(d), m_arburst => arb(d),
               m_rvalid => rv(d), m_rready => rr(d), m_rdata => rd(d), m_rlast => rl(d),
               y_we => y_we(d), y_addr => y_addr(d), y_data => y_data(d),
               y_mask => y_mask(d), y_exp => y_exp(d), done => done(d), err => err(d),
               sat_event => sat(d));
  end generate;

  -- 27 AXI read models per DUT.  OLD and SAME run their masters on clk, SPLIT on aclk.
  g_d : for d in 0 to ND-1 generate
    g_p : for p in 0 to NP-1 generate
      function lpm(dd, pp : natural) return natural is
      begin
        -- SPLIT only.  Port 13 stalls most (8 per 1024 cycles, about 70% of the time
        -- stalled): with a 64-beat weight FIFO and a 32-deep flit FIFO, a rarer stall
        -- let the credit-loss mutant C1 SURVIVE twice (MEASURED 2026-11-12).
        if dd = 1 and pp = 13 then return 8;
        elsif dd = 1 and (pp = 0 or pp = 25) then return 3;
        else return 0; end if;
      end function;
      function mclk_is_a(dd : natural) return boolean is
      begin
        return dd = 1;
      end function;
    begin
      g_a : if mclk_is_a(d) generate
        m : entity work.axi_rd_mem_model
          generic map(AXI_DW => DW, ADDR_W => AW, NWORDS => NWRD, SEED => 100*d + p + 1,
                      GAPPCT => 20, LONGPM => lpm(d, p), LONGLEN => 300)
          port map(clk => aclk, rst => rst, arvalid => arv(d)(p), arready => arr(d)(p),
                   araddr => ara(d)(p*AW+AW-1 downto p*AW), arlen => arl(d)(p*8+7 downto p*8),
                   rvalid => rv(d)(p), rready => rr(d)(p), rdata => rd(d)(p*DW+DW-1 downto p*DW),
                   rlast => rl(d)(p), wr_en => wr_en, wr_addr => wr_addr, wr_data => wr_data(p));
      end generate;
      g_c : if not mclk_is_a(d) generate
        m : entity work.axi_rd_mem_model
          generic map(AXI_DW => DW, ADDR_W => AW, NWORDS => NWRD, SEED => 100*d + p + 1,
                      GAPPCT => 20, LONGPM => lpm(d, p), LONGLEN => 300)
          port map(clk => clk, rst => rst, arvalid => arv(d)(p), arready => arr(d)(p),
                   araddr => ara(d)(p*AW+AW-1 downto p*AW), arlen => arl(d)(p*8+7 downto p*8),
                   rvalid => rv(d)(p), rready => rr(d)(p), rdata => rd(d)(p*DW+DW-1 downto p*DW),
                   rlast => rl(d)(p), wr_en => wr_en, wr_addr => wr_addr, wr_data => wr_data(p));
      end generate;
    end generate;

    logger : process(clk)
      variable n : natural := 0;
    begin
      if rising_edge(clk) then
        if clr_log = '1' then
          n := 0;
        elsif y_we(d) = '1' then
          assert n < MAXBT report "tb_mv4i_tiled: beat log full" severity failure;
          logs(d)(n) <= (y_addr(d), y_data(d), y_mask(d), y_exp(d));
          n := n + 1;
        end if;
        nbeat(d) <= n;
      end if;
    end process;
  end generate;

  run : process
    type job_t is record
      rows, cols, os, md, wexp, xexp : integer;
      kind : natural;  -- 0 random, 1 saturating, 2 reset mid-job (not compared),
                       -- 3 the previous job's weights and x with a new codebook
    end record;
    type jobs_t is array(natural range <>) of job_t;
    constant JOBS : jobs_t := (
      (48, 32, 3, 1, 2, 5, 0), (50, 100, 7, 0, -3, 4, 0), (144, 64, 0, 2, 1, 1, 0),
      (97, 250, 12, 1, 0, -2, 0), (10, 544, 0, 1, 0, 0, 1), (10, 544, 0, 2, 0, 0, 1),
      (200, 33, 40, 0, 6, -7, 0), (1, 1, 5, 1, 0, 0, 0),
      (20, 0, 3, 1, 0, 0, 0),        -- refused: n_cols = 0
      (241, 64, 3, 0, 0, 0, 0),      -- refused: BFP above MAXROWS_BFP
      (20, 64, 41, 1, 0, 0, 0),      -- refused: out_shift 41
      (60, 300, 5, 0, 1, 2, 0),
      (480, 32, 9, 1, 2, 3, 0),      -- LM-head shape: raw, n_rows above MAXROWS_BFP, nb 1
      (480, 32, 9, 2, 0, 0, 3),      -- same weights and x, a new codebook, partial
      (96, 640, 4, 0, 0, 0, 2),      -- rst pulsed 300 cycles into the job
      (96, 640, 4, 0, 1, 1, 0),      -- the job after the reset
      (480, 640, 9, 1, 1, 2, 0));    -- 200 items per tile, over the 64-beat weight FIFO:
                                     -- the SPLIT stalls now exhaust tile credits
    variable rng : unsigned(31 downto 0) := x"5EED1234";
    variable nb, nt, cyc, checks, fails : natural := 0;
    variable bad : boolean;
    variable w : std_logic_vector(DW-1 downto 0);
    variable alldone : std_logic_vector(0 to ND-1);
    variable e0, s0, ex0 : std_logic_vector(31 downto 0);
    procedure rnd is
    begin
      rng := rng xor shift_left(rng, 13);
      rng := rng xor shift_right(rng, 17);
      rng := rng xor shift_left(rng, 5);
    end procedure;
    procedure chk(c : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not c then
        fails := fails + 1;
        report "tb_mv4i_tiled: MISMATCH " & msg severity error;
      end if;
    end procedure;
  begin
    rst <= '1';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    for j in JOBS'range loop
      if JOBS(j).cols > 0 then nb := (JOBS(j).cols + 31) / 32; else nb := 1; end if;
      nt := (JOBS(j).rows + RI - 1) / RI;
      -- weights and scales, written to all 81 models at once (kind 3 reuses them)
      for i in 0 to nt*nb - 1 loop
        exit when JOBS(j).kind = 3;
        for p in 0 to NP-1 loop
          for k in 0 to DW/32 - 1 loop
            rnd;
            if JOBS(j).kind = 1 then
              if p < NW then w(k*32+31 downto k*32) := (others => '0');       -- idx 0
              else w(k*32+31 downto k*32) := x"7FFF7FFF"; end if;              -- scale 32767
            elsif p < NW then
              w(k*32+31 downto k*32) := std_logic_vector(rng);
            else
              w(k*32+31 downto k*32) := std_logic_vector(rng and x"7FFF7FFF"); -- uint15
            end if;
          end loop;
          wr_data(p) <= w;
        end loop;
        wr_en <= '1'; wr_addr <= i;
        wait until rising_edge(aclk);
        wait until rising_edge(clk);
      end loop;
      wr_en <= '0';
      -- activations: n_cols rounded up to a block, plus junk past n_cols
      for k in 0 to nb*32 - 1 loop
        exit when JOBS(j).kind = 3;
        rnd;
        x_we <= '1'; x_waddr <= std_logic_vector(to_unsigned(k, 16));
        if JOBS(j).kind = 1 then x_wdata <= x"8000";
        else x_wdata <= std_logic_vector(rng(15 downto 0)); end if;
        wait until rising_edge(clk);
      end loop;
      x_we <= '0';
      -- codebook: cb[0] = -127 for the saturating job, else the full int8 range
      for e in 0 to 15 loop
        rnd;
        cb_we <= '1'; cb_addr <= std_logic_vector(to_unsigned(e, 4));
        if JOBS(j).kind = 1 and e = 0 then cb_data <= x"81";
        elsif e = 15 then cb_data <= x"80";
        else cb_data <= std_logic_vector(rng(7 downto 0)); end if;
        wait until rising_edge(clk);
      end loop;
      cb_we <= '0';
      n_rows <= std_logic_vector(to_signed(JOBS(j).rows, 32));
      n_cols <= std_logic_vector(to_signed(JOBS(j).cols, 32));
      out_shift <= std_logic_vector(to_signed(JOBS(j).os, 32));
      out_mode <= std_logic_vector(to_unsigned(JOBS(j).md, 2));
      w_exp <= std_logic_vector(to_signed(JOBS(j).wexp, 32));
      x_exp <= std_logic_vector(to_signed(JOBS(j).xexp, 32));
      beats <= std_logic_vector(to_unsigned(nt*nb, 32));
      clr_log <= '1';
      wait until rising_edge(clk);
      clr_log <= '0';
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      if JOBS(j).kind = 2 then
        -- reset in the middle of the job; nothing of it is compared, the next job is
        for i in 1 to 300 loop wait until rising_edge(clk); end loop;
        rst <= '1';
        for i in 1 to 3 loop wait until rising_edge(clk); end loop;
        rst <= '0';
        for i in 1 to 30 loop wait until rising_edge(clk); end loop;
        report "tb_mv4i_tiled: job " & integer'image(j) & " reset mid-job" severity note;
        next;
      end if;
      alldone := (others => '0'); cyc := 0;
      while alldone /= "111" loop
        wait until rising_edge(clk);
        for d in 0 to ND-1 loop
          if done(d) = '1' then
            alldone(d) := '1';
          end if;
        end loop;
        cyc := cyc + 1;
        assert cyc < 400000 report "tb_mv4i_tiled: job " & integer'image(j) & " timed out"
          severity failure;
      end loop;
      wait until rising_edge(clk);
      -- compare
      chk(nbeat(1) = nbeat(0) and nbeat(2) = nbeat(0),
          "job " & integer'image(j) & " beat counts " & integer'image(nbeat(0)) & " "
          & integer'image(nbeat(1)) & " " & integer'image(nbeat(2)));
      for b in 0 to nbeat(0) - 1 loop
        for d in 1 to ND-1 loop
          if b < nbeat(d) then
            chk(logs(d)(b) = logs(0)(b), "job " & integer'image(j) & " DUT "
                & integer'image(d) & " beat " & integer'image(b) & " addr "
                & to_hstring(logs(d)(b).a) & " vs " & to_hstring(logs(0)(b).a));
          end if;
        end loop;
      end loop;
      for d in 1 to ND-1 loop
        chk(err(d) = err(0) and sat(d) = sat(0) and y_exp(d) = y_exp(0),
            "job " & integer'image(j) & " DUT " & integer'image(d) & " err/sat/y_exp at done");
      end loop;
      report "tb_mv4i_tiled: job " & integer'image(j) & " beats " & integer'image(nbeat(0))
           & " err " & std_logic'image(err(0)) & " sat " & std_logic'image(sat(0)) severity note;
    end loop;
    assert fails = 0 report "tb_mv4i_tiled: FAIL " & integer'image(fails) severity failure;
    report "PASS: tb_mv4i_tiled checks=" & integer'image(checks) severity note;
    done_sim <= true;
    wait;
  end process;
end architecture;
```

- [ ] **Step 2: Give the two composed rows their own timeout**

The gate's default is 900 s per row. `tb_mv4i_tiled` took 10 min 56 s quiet (MEASURED, `/usr/bin/time -v`, 3.7 GB peak RSS) and about 45 min under a parallel gate. Do not edit `sim/regress.sh` while any gate runs from this tree. Apply with this script, from the repo root:

```python
p = "sim/regress.sh"
t = open(p).read()
a = 'tb_args() {   # extra `ghdl -r` arguments for $1\n'
fn = ('tb_timeout() {   # <suite:name> -> seconds for its `ghdl -r`; never below --timeout\n'
      '  local t="$TIMEOUT"\n'
      '  case "$1" in\n'
      '    # The a450 composed A (plan 2026-11-12 Tasks 6 and 8): 24 tiles beside the old\n'
      '    # core.  tb_mv4i_tiled MEASURED 11 min quiet and about 45 min under a parallel gate;\n'
      '    # tb_matvec_fk33_desc_tiled simulates the 24 tiles through the whole descriptor\n'
      '    # bench (about 730 us of simulated time).\n'
      '    sim:tb_mv4i_tiled)               [ "$t" -lt 3600 ] && t=3600 ;;\n'
      '    sim:tb_matvec_fk33_desc_tiled)   [ "$t" -lt 7200 ] && t=7200 ;;\n'
      '  esac\n'
      '  echo "$t"\n'
      '}\n\n')
assert t.count(a) == 1; t = t.replace(a, fn + a)
a = '    ( cd "$run" && timeout -k 5 "$TIMEOUT" \\\n        "$GHDL" -r $STD $RELAX --workdir="$work" "$top" \\\n'
b = '    ( cd "$run" && timeout -k 5 "$(tb_timeout "$key")" \\\n        "$GHDL" -r $STD $RELAX --workdir="$work" "$top" \\\n'
assert t.count(a) == 1; t = t.replace(a, b)
a = '    verdict TIMEOUT "no result within ${TIMEOUT}s -- unguarded clock or deadlock, NOT the same thing as a failure"; return\n'
b = '    verdict TIMEOUT "no result within $(tb_timeout "$key")s -- unguarded clock or deadlock, NOT the same thing as a failure"; return\n'
assert t.count(a) == 1; t = t.replace(a, b)
a = '          tb:tb_weights_pkg"'
b = '          tb:tb_weights_pkg\n          sim:tb_mv4i_tiled sim:tb_matvec_fk33_desc_tiled"'
assert t.count(a) == 1; t = t.replace(a, b)
open(p, "w").write(t)
print("REGRESS_TIMEOUT_EDIT_OK")
```

Run: `python3 <that script> && bash -n sim/regress.sh && echo SYNTAX_OK`
Expected: `REGRESS_TIMEOUT_EDIT_OK` and `SYNTAX_OK`. `SLOW_TBS` membership means `--quick` skips both rows; the full gate gives them 3,600 s and 7,200 s (the descriptor row MEASURED 44 min quiet, Task 8).

- [ ] **Step 3: Run the bench row and watch it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/a450_t6_red bash sim/regress.sh --suite sim --only tb_mv4i_tiled --keep`
Expected: `BUILD-ERROR` (no entity `mv4i_tiled`), `OVERALL PASS 0`.

- [ ] **Step 4: Write the fast half, the back end and the wrappers**

`rtl/mv_afast.vhd` (the `aclk_a` composition: distributor, tree, `NPORTS_W` tiles, chain; `SLACK = LF + LR + 4` is a constant here):

```vhdl
-- rtl/mv_afast.vhd -- everything of the a450 subsystem A that runs in aclk_a (spec 1.1):
-- the distributor and its NPORTS_S scale ports, the distribution and room trees, NT =
-- NPORTS_W tiles (one per weight port) and the result chain.  Single clock, so it is the
-- unit the A-composed block rating (hw/targets/blocks.json a450_afast) times at 2.222 ns.
--
-- SLACK, THE CREDIT SIZE, IS DERIVED HERE AND NOWHERE ELSE.  A flit decided in mv_dist
-- stage A reaches a tile's FIFO LF = 2 + 3 cycles later (dist A, B; tree root, mid, leaf);
-- a tile's level change reaches stage A LR = 1 + 2 cycles later (tile room register; mid
-- and root AND).  Everything sent in that LF + LR window lands after room fell, so the
-- tile withdraws room at XD - SLACK with SLACK = LF + LR + 4 (4 of margin).
-- sim/tb_mv_dist.vhd measures the loop: SLACK = 3 overflows, 8 does not.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity mv_afast is
  generic(
    BLK        : positive := 32;
    ROWS_IF    : positive := 48;
    NPORTS_W   : positive := 24;
    NPORTS_S   : positive := 3;
    AXI_DW     : positive := 256;
    ADDR_W     : positive := 40;
    MAXCOLS    : positive := 17408;
    FIFO_DEPTH : positive := 512;
    MAXB       : positive := 16;
    MAXOUT     : positive := 16;
    XD         : positive := 32;
    G          : positive := 6
  );
  port(
    clk, rst  : in  std_logic;
    go        : in  std_logic;
    j_nb      : in  natural;
    j_rows    : in  natural;
    j_lastv   : in  natural;
    j_os      : in  std_logic_vector(5 downto 0);
    j_mode    : in  std_logic_vector(1 downto 0);
    j_cb      : in  std_logic_vector(127 downto 0);
    w_base    : in  std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats   : in  integer;
    s_base    : in  std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats   : in  integer;
    x_rbaddr  : out std_logic_vector(clog2((MAXCOLS+BLK-1)/BLK)-1 downto 0);
    x_rdata   : in  std_logic_vector(BLK*16-1 downto 0);
    m_arvalid : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_arready : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_araddr  : out std_logic_vector((NPORTS_W+NPORTS_S)*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector((NPORTS_W+NPORTS_S)*8-1 downto 0);
    m_arsize  : out std_logic_vector((NPORTS_W+NPORTS_S)*3-1 downto 0);
    m_arburst : out std_logic_vector((NPORTS_W+NPORTS_S)*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rready  : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rdata   : in  std_logic_vector((NPORTS_W+NPORTS_S)*AXI_DW-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    res_v     : out std_logic;
    res_d     : out std_logic_vector(96 downto 0);
    res_afull : in  std_logic
  );
end entity;

architecture rtl of mv_afast is
  constant NT    : positive := NPORTS_W;
  constant XW    : positive := BLK*16;
  constant LF    : positive := 5;
  constant LR    : positive := 3;
  constant SLACK : positive := LF + LR + 4;
  -- ROWS_IF must be two rows per weight port (lane split 6.5a at AXI_DW = 256)
  constant CHK_ROWS : natural := 1 - abs(ROWS_IF - 2*NT);
  signal d_v, d_f, d_l : std_logic;
  signal d_k : std_logic_vector(1 downto 0);
  signal d_x : std_logic_vector(XW-1 downto 0);
  signal d_s : std_logic_vector(ROWS_IF*16-1 downto 0);
  signal l_v, l_f, l_l, rooms : std_logic_vector(NT-1 downto 0);
  signal l_k : std_logic_vector(NT*2-1 downto 0);
  signal l_x : std_logic_vector(NT*XW-1 downto 0);
  signal l_s : std_logic_vector(NT*32-1 downto 0);
  signal room_all, busy : std_logic;
  signal own_v, own_rdy : std_logic_vector(NT-1 downto 0);
  signal own_d : std_logic_vector(NT*97-1 downto 0);
begin
  dist : entity work.mv_dist
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_S => NPORTS_S, AXI_DW => AXI_DW,
                ADDR_W => ADDR_W, DEPTH => FIFO_DEPTH, MAXB => MAXB, MAXOUT => MAXOUT,
                MAXCOLS => MAXCOLS)
    port map(clk => clk, rst => rst, go => go, j_nb => j_nb, j_rows => j_rows,
             j_lastv => j_lastv, j_os => j_os, j_mode => j_mode, j_cb => j_cb,
             s_base => s_base, s_beats => s_beats, x_rbaddr => x_rbaddr, x_rdata => x_rdata,
             m_arvalid => m_arvalid(NT+NPORTS_S-1 downto NT),
             m_arready => m_arready(NT+NPORTS_S-1 downto NT),
             m_araddr  => m_araddr((NT+NPORTS_S)*ADDR_W-1 downto NT*ADDR_W),
             m_arlen   => m_arlen((NT+NPORTS_S)*8-1 downto NT*8),
             m_arsize  => m_arsize((NT+NPORTS_S)*3-1 downto NT*3),
             m_arburst => m_arburst((NT+NPORTS_S)*2-1 downto NT*2),
             m_rvalid  => m_rvalid(NT+NPORTS_S-1 downto NT),
             m_rready  => m_rready(NT+NPORTS_S-1 downto NT),
             m_rdata   => m_rdata((NT+NPORTS_S)*AXI_DW-1 downto NT*AXI_DW),
             m_rlast   => m_rlast(NT+NPORTS_S-1 downto NT),
             o_v => d_v, o_kind => d_k, o_x => d_x, o_s => d_s, o_first => d_f,
             o_last => d_l, room_all => room_all, busy => busy);

  tree : entity work.mv_xbcast
    generic map(NT => NT, G => G, XW => XW)
    port map(clk => clk, rst => rst, i_v => d_v, i_kind => d_k, i_x => d_x, i_s => d_s,
             i_first => d_f, i_last => d_l, o_v => l_v, o_kind => l_k, o_x => l_x,
             o_s => l_s, o_first => l_f, o_last => l_l, rooms => rooms,
             room_all => room_all);

  g_t : for p in 0 to NT-1 generate
    tile : entity work.mv_tile
      generic map(BLK => BLK, AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => FIFO_DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, XD => XD, SLACK => SLACK, RD => 4)
      port map(clk => clk, rst => rst,
               w_base => w_base((p+1)*ADDR_W-1 downto p*ADDR_W), w_beats => w_beats,
               arvalid => m_arvalid(p), arready => m_arready(p),
               araddr => m_araddr((p+1)*ADDR_W-1 downto p*ADDR_W),
               arlen => m_arlen((p+1)*8-1 downto p*8),
               arsize => m_arsize((p+1)*3-1 downto p*3),
               arburst => m_arburst((p+1)*2-1 downto p*2),
               rvalid => m_rvalid(p), rready => m_rready(p),
               rdata => m_rdata((p+1)*AXI_DW-1 downto p*AXI_DW), rlast => m_rlast(p),
               f_v => l_v(p), f_kind => l_k(p*2+1 downto p*2),
               f_x => l_x((p+1)*XW-1 downto p*XW), f_s => l_s(p*32+31 downto p*32),
               f_first => l_f(p), f_last => l_l(p), room => rooms(p),
               r_v => own_v(p), r_d => own_d((p+1)*97-1 downto p*97), r_rdy => own_rdy(p));
  end generate;

  chain : entity work.mv_rchain
    generic map(NT => NT, W => 97)
    port map(clk => clk, rst => rst, own_v => own_v, own_d => own_d, own_rdy => own_rdy,
             d_v => res_v, d_d => res_d, d_afull => res_afull);
end architecture;
```

`rtl/mv_back.vhd` (the `clk_core` back end; the descriptor checks, the codebook bank, the beat assembly and the BFP fold and emit are `matvec_core`'s, moved here unchanged in arithmetic; `t_cnt` and `tiles_r` are plain integers and the BFP buffer index is clamped through `ybuf_addr`, the fix for raw and partial jobs with `n_rows` above `MAXROWS_BFP`):

```vhdl
-- rtl/mv_back.vhd -- the a450 A back end, in clk_core (spec 2.3, 2.4).
--
-- Everything of rtl/matvec_core.vhd that needs the whole matrix or talks to the outside
-- lives here, unchanged in meaning:
--   * the spec 7.6 start checks (bad n_rows / n_cols / out_shift, BFP above MAXROWS_BFP):
--     err and done, and the fast side is never started;
--   * the codebook, written in idle exactly as before (a cb_we cycle ignores start);
--   * the job values the fast side reads (j_*), held from the start pulse to the next
--     start, and the one-cycle j_go that rtl/mv_tsync.vhd carries to aclk_a;
--   * the result words from the crossing, NT per row-tile in tile order, assembled into
--     one ROWS_IF-row beat, then the y outputs: raw and partial beats go out at once,
--     BFP beats go to ybuf and the masked max fold, then SCAN and EMIT as before;
--   * sat_event (sticky, cleared by an accepted start), err, done, y_exp;
--   * w_beat / w_words, so the descriptor plane's BEATS still reads tiles * nb.
-- Rows past n_rows are masked (y_mask, and out of the BFP max) exactly as before.  The
-- tiles compute sat on every row, pad rows included, as matvec_core does.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mv4i_arith_pkg.all;
use work.util_pkg.all;

entity mv_back is
  generic(
    BLK         : positive := 32;
    ROWS_IF     : positive := 48;
    MAXCOLS     : positive := 17408;
    MAXROWS_BFP : positive := 17408
  );
  port(
    clk, rst  : in  std_logic;
    start     : in  std_logic;
    n_rows    : in  integer;
    n_cols    : in  integer;
    out_shift : in  integer;
    w_exp     : in  integer;
    x_exp     : in  integer;
    out_mode  : in  std_logic_vector(1 downto 0);
    cb_we     : in  std_logic;
    cb_addr   : in  std_logic_vector(3 downto 0);
    cb_data   : in  std_logic_vector(7 downto 0);
    j_go      : out std_logic;
    j_nb      : out natural;
    j_rows    : out natural;
    j_lastv   : out natural;
    j_os      : out std_logic_vector(5 downto 0);
    j_mode    : out std_logic_vector(1 downto 0);
    j_cb      : out std_logic_vector(127 downto 0);
    q_valid   : in  std_logic;
    q_data    : in  std_logic_vector(96 downto 0);
    q_ready   : out std_logic;
    y_we      : out std_logic;
    y_addr    : out std_logic_vector(15 downto 0);
    y_data    : out std_logic_vector(ROWS_IF*64-1 downto 0);
    y_mask    : out std_logic_vector(ROWS_IF-1 downto 0);
    y_exp     : out integer;
    done      : out std_logic;
    err       : out std_logic;
    sat_event : out std_logic;
    -- one pulse per row-tile beat taken, and the weight words it stands for (nb):
    -- matvec_int4_desc_axi's BEATS register adds w_words on each w_beat
    w_beat    : out std_logic;
    w_words   : out natural
  );
end entity;

architecture rtl of mv_back is
  constant NT    : positive := ROWS_IF / 2;
  constant TILES : positive := (MAXROWS_BFP + ROWS_IF - 1) / ROWS_IF;
  function ybuf_addr(t : integer) return integer is
  begin
    if t >= TILES then return TILES - 1; else return t; end if;
  end function;
  function lvl_of(r : positive) return positive is
    variable c : natural := clog2(r);
  begin
    if c = 0 then return 1; else return c; end if;
  end function;
  constant LVLR   : positive := lvl_of(ROWS_IF);
  constant MAXPOW : positive := 2 ** LVLR;
  constant HALF   : positive := MAXPOW / 2;

  type st_t is (B_IDLE, B_RUN, B_DRAIN, B_SCAN, B_EMIT, B_DONE);
  signal st : st_t := B_IDLE;
  signal cbk : std_logic_vector(127 downto 0) := (others => '0');
  signal go_r : std_logic := '0';
  signal nb_r, rows_r, lastv_r : natural := 0;
  signal os_r : natural range 0 to 63 := 0;
  signal md_r : std_logic_vector(1 downto 0) := "00";
  signal sat_r, err_r : std_logic := '0';
  -- assembly
  type asm_t is array(0 to NT-1) of std_logic_vector(95 downto 0);
  signal asm  : asm_t := (others => (others => '0'));
  signal wi   : natural range 0 to NT-1 := 0;
  signal asat : std_logic := '0';
  signal bt_v, bt_sat : std_logic := '0';
  signal bt_rows : std_logic_vector(ROWS_IF*48-1 downto 0) := (others => '0');
  signal rows_left, rbase : integer := 0;
  -- Plain integers, as matvec_core's t_iss/tiles_r: a raw or partial job may have far
  -- more than MAXROWS_BFP rows (the LM head), and only a BFP job indexes ybuf with them.
  signal t_cnt, tiles_r : integer := 0;
  -- BFP
  type ybuf_t is array(0 to TILES-1) of std_logic_vector(ROWS_IF*32-1 downto 0);
  signal ybuf : ybuf_t;
  attribute ram_style : string;
  attribute ram_style of ybuf : signal is "block";
  signal ybuf_q : std_logic_vector(ROWS_IF*32-1 downto 0) := (others => '0');
  type mag_arr is array(0 to ROWS_IF-1) of unsigned(35 downto 0);
  signal re3_v : std_logic := '0';
  signal re3_mag : mag_arr := (others => (others => '0'));
  signal re3_ok : std_logic_vector(ROWS_IF-1 downto 0) := (others => '0');
  type wide_mag is array(0 to MAXPOW-1) of unsigned(35 downto 0);
  type fold_arr is array(0 to LVLR*HALF-1) of unsigned(35 downto 0);
  signal fold   : fold_arr := (others => (others => '0'));
  signal fold_v : std_logic_vector(LVLR-1 downto 0) := (others => '0');
  signal amax   : unsigned(35 downto 0) := (others => '0');
  signal ns_r   : natural range 0 to 63 := 0;
  signal rd_t, rd_td : integer range 0 to TILES := 0;
  signal rd_v, em_v : std_logic := '0';
  signal em_t : integer := 0;
  type em_arr is array(0 to ROWS_IF-1) of signed(31 downto 0);
  signal em_shv : em_arr := (others => (others => '0'));
begin
  j_go <= go_r; j_nb <= nb_r; j_rows <= rows_r; j_lastv <= lastv_r;
  j_os <= std_logic_vector(to_unsigned(os_r, 6)); j_mode <= md_r; j_cb <= cbk;
  q_ready <= '1' when st = B_RUN else '0';
  w_beat  <= bt_v;
  w_words <= nb_r;

  process(clk)
    variable v48  : signed(47 downto 0);
    variable a32  : signed(31 downto 0);
    variable ynew : std_logic_vector(ROWS_IF*32-1 downto 0);
    variable wm   : wide_mag;
    variable ymn  : signed(15 downto 0);
    variable rb   : integer;
    variable fv   : std_logic;
  begin
    if rising_edge(clk) then
      y_we <= '0'; done <= '0'; go_r <= '0'; bt_v <= '0'; re3_v <= '0';

      if rst = '1' then
        st <= B_IDLE; sat_r <= '0'; err_r <= '0'; wi <= 0; asat <= '0';
        fold_v <= (others => '0');
      else
        -- assembly: NT words, tile order, per row-tile
        if st = B_RUN and q_valid = '1' then
          if wi = NT-1 then
            for k in 0 to NT-2 loop
              bt_rows(k*96+95 downto k*96) <= asm(k);
            end loop;
            bt_rows(ROWS_IF*48-1 downto (NT-1)*96) <= q_data(95 downto 0);
            bt_sat <= asat or q_data(96);
            bt_v <= '1';
            wi <= 0; asat <= '0';
          else
            asm(wi) <= q_data(95 downto 0);
            asat <= asat or q_data(96);
            wi <= wi + 1;
          end if;
        end if;

        -- one beat: raw/partial out now, BFP to ybuf and the fold
        if bt_v = '1' then
          if bt_sat = '1' then sat_r <= '1'; end if;
          for rr in 0 to ROWS_IF-1 loop
            v48 := signed(bt_rows(rr*48+47 downto rr*48));
            a32 := v48(31 downto 0);
            ynew(rr*32+31 downto rr*32) := std_logic_vector(a32);
            y_data(rr*64+63 downto rr*64) <= std_logic_vector(resize(v48, 64));
            re3_mag(rr) <= unsigned(abs(resize(a32, 36)));
            if rbase + rr < n_rows then
              y_mask(rr) <= '1'; re3_ok(rr) <= '1';
            else
              y_mask(rr) <= '0'; re3_ok(rr) <= '0';
            end if;
          end loop;
          y_addr <= std_logic_vector(to_unsigned(rbase, 16));
          if md_r = "00" then
            ybuf(ybuf_addr(t_cnt)) <= ynew;
            re3_v <= '1';
          else
            y_we <= '1';
          end if;
          t_cnt <= t_cnt + 1; tiles_r <= t_cnt + 1;
          rbase <= rbase + ROWS_IF;
          if rows_left <= ROWS_IF then
            if md_r = "00" then st <= B_DRAIN; else st <= B_DONE; end if;
          else
            rows_left <= rows_left - ROWS_IF;
          end if;
        end if;

        -- the masked max fold, one register stage per level (matvec_core's)
        fold_v(0) <= re3_v;
        if re3_v = '1' then
          for rr in 0 to ROWS_IF-1 loop
            if re3_ok(rr) = '1' then wm(rr) := re3_mag(rr); else wm(rr) := (others => '0'); end if;
          end loop;
          for rr in ROWS_IF to MAXPOW-1 loop wm(rr) := (others => '0'); end loop;
          for i in 0 to HALF-1 loop
            if wm(2*i+1) > wm(2*i) then fold(i) <= wm(2*i+1); else fold(i) <= wm(2*i); end if;
          end loop;
        end if;
        for sg in 1 to LVLR-1 loop
          fold_v(sg) <= fold_v(sg-1);
          if fold_v(sg-1) = '1' then
            for i in 0 to (MAXPOW / (2**(sg+1))) - 1 loop
              if fold((sg-1)*HALF + 2*i+1) > fold((sg-1)*HALF + 2*i) then
                fold(sg*HALF + i) <= fold((sg-1)*HALF + 2*i+1);
              else
                fold(sg*HALF + i) <= fold((sg-1)*HALF + 2*i);
              end if;
            end loop;
          end if;
        end loop;
        if fold_v(LVLR-1) = '1' and fold((LVLR-1)*HALF) > amax then
          amax <= fold((LVLR-1)*HALF);
        end if;

        ybuf_q <= ybuf(ybuf_addr(rd_t));

        case st is
          when B_IDLE =>
            if cb_we = '1' then
              cbk(to_integer(unsigned(cb_addr))*8+7 downto to_integer(unsigned(cb_addr))*8)
                <= cb_data;
            elsif start = '1' then
              if n_rows <= 0 or n_cols <= 0 or n_cols > MAXCOLS
                 or out_shift < 0 or out_shift > 40
                 or (out_mode = "00" and n_rows > MAXROWS_BFP) then
                err_r <= '1'; st <= B_DONE;
              else
                nb_r    <= (n_cols + BLK - 1) / BLK;
                lastv_r <= n_cols - ((n_cols - 1) / BLK) * BLK;
                rows_r  <= n_rows;
                rows_left <= n_rows;
                os_r    <= out_shift;
                md_r    <= out_mode;
                rbase <= 0; t_cnt <= 0; tiles_r <= 0;
                wi <= 0; asat <= '0';
                amax <= (others => '0');
                sat_r <= '0'; err_r <= '0';
                go_r <= '1';
                st <= B_RUN;
              end if;
            end if;

          when B_RUN =>
            null;

          when B_DRAIN =>
            fv := re3_v or bt_v;
            for i in 0 to LVLR-1 loop fv := fv or fold_v(i); end loop;
            if fv = '0' then st <= B_SCAN; end if;

          when B_SCAN =>
            if msb_pos_u(amax) > 14 then ns_r <= msb_pos_u(amax) - 14;
            else ns_r <= 0; end if;
            rd_t <= 0; rd_v <= '0'; em_v <= '0';
            st <= B_EMIT;

          when B_EMIT =>
            if rd_t < tiles_r then
              rd_v <= '1'; rd_td <= rd_t; rd_t <= rd_t + 1;
            else
              rd_v <= '0';
            end if;
            em_v <= rd_v; em_t <= rd_td;
            if rd_v = '1' then
              for rr in 0 to ROWS_IF-1 loop
                em_shv(rr) <= resize(round_shift(signed(ybuf_q(rr*32+31 downto rr*32)), ns_r), 32);
              end loop;
            end if;
            if em_v = '1' then
              rb := em_t * ROWS_IF;
              y_we <= '1';
              y_addr <= std_logic_vector(to_unsigned(rb, 16));
              for rr in 0 to ROWS_IF-1 loop
                ymn := sat16(em_shv(rr));
                y_data(rr*64+63 downto rr*64) <= std_logic_vector(resize(ymn, 64));
                if rb + rr < n_rows then y_mask(rr) <= '1'; else y_mask(rr) <= '0'; end if;
              end loop;
              if em_t = tiles_r - 1 then st <= B_DONE; end if;
            end if;

          when B_DONE =>
            done <= '1';
            st <= B_IDLE;
        end case;
      end if;
    end if;
  end process;

  y_exp <= (w_exp + x_exp)               when out_mode = "10" else
           (w_exp + x_exp - os_r - ns_r) when out_mode = "00" else
           (w_exp + x_exp - os_r);
  err       <= err_r;
  sat_event <= sat_r;
end architecture;
```

`rtl/mv4i_tcore.vhd`:

```vhdl
-- rtl/mv4i_tcore.vhd -- the body of rtl/mv4i_tiled.vhd, with clk_core (`clk`) and
-- aclk_a as two ports.  mv4i_tiled ties aclk_a to clk or to its `aclk` (A_CLK_SPLIT).
--
--   clk     mv_back (checks, codebook, assembly, ybuf, emit), the x write port
--   aclk_a  mv_afast (distributor, trees, tiles, chain), the x read port
--   crossings: j_go by mv_tsync; the result words by mv_rcross; x by act_mem_dp.
--   The j_* values and the bases/beats are held by the back end from the start pulse
--   to the next start, so aclk_a reads them only after j_go has crossed: they need a
--   set_max_delay -datapath_only of one aclk_a period, not a synchroniser.  The card's
--   timing Tcl applies it (plan Task 9, a450_cdc.tcl).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity mv4i_tcore is
  generic(
    BLK, ROWS_IF, NPORTS_W, NPORTS_S, AXI_DW, ADDR_W, MAXCOLS, MAXROWS_BFP,
    FIFO_DEPTH, MAXB, MAXOUT, XD, G : positive
  );
  port(
    clk, rst, aclk_a, start : in std_logic;
    n_rows, n_cols, out_shift, w_exp, x_exp : in std_logic_vector(31 downto 0);
    out_mode : in std_logic_vector(1 downto 0);
    w_base : in std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats : in std_logic_vector(31 downto 0);
    s_base : in std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats : in std_logic_vector(31 downto 0);
    cb_we : in std_logic;
    cb_addr : in std_logic_vector(3 downto 0);
    cb_data : in std_logic_vector(7 downto 0);
    x_we : in std_logic;
    x_waddr, x_wdata : in std_logic_vector(15 downto 0);
    m_arvalid : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_arready : in std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_araddr : out std_logic_vector((NPORTS_W+NPORTS_S)*ADDR_W-1 downto 0);
    m_arlen : out std_logic_vector((NPORTS_W+NPORTS_S)*8-1 downto 0);
    m_arsize : out std_logic_vector((NPORTS_W+NPORTS_S)*3-1 downto 0);
    m_arburst : out std_logic_vector((NPORTS_W+NPORTS_S)*2-1 downto 0);
    m_rvalid : in std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rready : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rdata : in std_logic_vector((NPORTS_W+NPORTS_S)*AXI_DW-1 downto 0);
    m_rlast : in std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    y_we : out std_logic;
    y_addr : out std_logic_vector(15 downto 0);
    y_data : out std_logic_vector(ROWS_IF*64-1 downto 0);
    y_mask : out std_logic_vector(ROWS_IF-1 downto 0);
    y_exp : out std_logic_vector(31 downto 0);
    done, err, sat_event : out std_logic;
    dbg_rtile : out std_logic;
    dbg_words : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of mv4i_tcore is
  constant XA : positive := clog2(MAXCOLS);
  constant XB : positive := clog2((MAXCOLS + BLK - 1) / BLK);
  signal ar1, ar2 : std_logic := '1';
  attribute async_reg : string;
  attribute async_reg of ar1 : signal is "TRUE";
  attribute async_reg of ar2 : signal is "TRUE";
  signal i_rows, i_cols, i_osh, i_wexp, i_xexp, i_yexp, i_wb, i_sb : integer := 0;
  signal j_go, a_go : std_logic;
  signal j_nb, j_rows, j_lastv : natural;
  signal j_os : std_logic_vector(5 downto 0);
  signal j_mode : std_logic_vector(1 downto 0);
  signal j_cb : std_logic_vector(127 downto 0);
  signal xr_baddr : std_logic_vector(XB-1 downto 0);
  signal x_rdata : std_logic_vector(BLK*16-1 downto 0);
  signal res_v, res_af, q_v, q_r : std_logic;
  signal res_d, q_d : std_logic_vector(96 downto 0);
  signal i_words : natural;
begin
  dbg_words <= std_logic_vector(to_unsigned(i_words, 32));
  i_rows <= to_integer(signed(n_rows));
  i_cols <= to_integer(signed(n_cols));
  i_osh  <= to_integer(signed(out_shift));
  i_wexp <= to_integer(signed(w_exp));
  i_xexp <= to_integer(signed(x_exp));
  i_wb   <= to_integer(signed(w_beats));
  i_sb   <= to_integer(signed(s_beats));
  y_exp  <= std_logic_vector(to_signed(i_yexp, 32));

  -- aclk_a's reset: rst through two flops
  arst : process(aclk_a)
  begin
    if rising_edge(aclk_a) then
      ar1 <= rst; ar2 <= ar1;
    end if;
  end process;

  back : entity work.mv_back
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, MAXCOLS => MAXCOLS, MAXROWS_BFP => MAXROWS_BFP)
    port map(clk => clk, rst => rst, start => start, n_rows => i_rows, n_cols => i_cols,
             out_shift => i_osh, w_exp => i_wexp, x_exp => i_xexp, out_mode => out_mode,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             j_go => j_go, j_nb => j_nb, j_rows => j_rows, j_lastv => j_lastv,
             j_os => j_os, j_mode => j_mode, j_cb => j_cb,
             q_valid => q_v, q_data => q_d, q_ready => q_r,
             y_we => y_we, y_addr => y_addr, y_data => y_data, y_mask => y_mask,
             y_exp => i_yexp, done => done, err => err, sat_event => sat_event,
             w_beat => dbg_rtile, w_words => i_words);

  gosync : entity work.mv_tsync
    port map(sclk => clk, srst => rst, s_pulse => j_go, dclk => aclk_a, drst => ar2,
             d_pulse => a_go);

  xmem : entity work.act_mem_dp
    generic map(ELEMS => MAXCOLS, BLK => BLK, W => 16)
    port map(wclk => clk, we => x_we, waddr => x_waddr(XA-1 downto 0), wdata => x_wdata,
             rclk => aclk_a, rbaddr => xr_baddr, rdata => x_rdata);

  fast : entity work.mv_afast
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W, NPORTS_S => NPORTS_S,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W, MAXCOLS => MAXCOLS,
                FIFO_DEPTH => FIFO_DEPTH, MAXB => MAXB, MAXOUT => MAXOUT, XD => XD, G => G)
    port map(clk => aclk_a, rst => ar2, go => a_go, j_nb => j_nb, j_rows => j_rows,
             j_lastv => j_lastv, j_os => j_os, j_mode => j_mode, j_cb => j_cb,
             w_base => w_base, w_beats => i_wb, s_base => s_base, s_beats => i_sb,
             x_rbaddr => xr_baddr, x_rdata => x_rdata,
             m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
             m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
             m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
             m_rlast => m_rlast, res_v => res_v, res_d => res_d, res_afull => res_af);

  cross : entity work.mv_rcross
    generic map(W => 97, DEPTH => 16)
    port map(wclk => aclk_a, wrst => ar2, w_v => res_v, w_d => res_d, w_afull => res_af,
             rclk => clk, rrst => rst, q_valid => q_v, q_data => q_d, q_ready => q_r);
end architecture;
```

`rtl/mv4i_tiled.vhd`:

```vhdl
-- rtl/mv4i_tiled.vhd -- subsystem A at 450 MHz: per-port tiles in their own clock domain.
-- Spec: docs/superpowers/specs/2026-11-12-a450-per-port-tiles-design.md.
--
-- A drop-in for rtl/matvec_int4.vhd: the same ports (its three per-word dbg_* taps are
-- replaced by dbg_rtile/dbg_words) and the same y/err/sat/done contract, bit for bit, so
-- rtl/matvec_int4_desc_axi.vhd chooses it with A_TILED and nothing above that changes.
--
-- A_CLK_SPLIT selects the fast domain:
--   false  aclk_a IS clk.  The crossings (mv_tsync, mv_rcross, act_mem_dp) are still
--          there and are crossed between equal clocks, exactly as the JC card already
--          crosses axi_rd_port's async FIFO today.  The m_* AXI masters are on clk.
--   true   aclk_a is the `aclk` port (450 MHz).  The m_* AXI masters are on aclk.
-- The choice is a generate around ONE entity, never a clock assigned through a signal:
-- an assigned clock is a delta late in simulation and the paths between the two would
-- race (rtl/axi_rd_fsm.vhd's header records that trap).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity mv4i_tiled is
  generic(
    BLK         : positive := 32;
    ROWS_IF     : positive := 48;
    NPORTS_W    : positive := 24;
    NPORTS_S    : positive := 3;
    AXI_DW      : positive := 256;
    ADDR_W      : positive := 40;
    MAXCOLS     : positive := 17408;
    MAXROWS_BFP : positive := 17408;
    FIFO_DEPTH  : positive := 512;
    MAXB        : positive := 16;
    MAXOUT      : positive := 16;
    A_CLK_SPLIT : boolean  := false;
    XD          : positive := 32;
    G           : positive := 6
  );
  port(
    clk, rst  : in  std_logic;
    aclk      : in  std_logic := '0';
    start     : in  std_logic;
    n_rows    : in  std_logic_vector(31 downto 0);
    n_cols    : in  std_logic_vector(31 downto 0);
    out_shift : in  std_logic_vector(31 downto 0);
    w_exp     : in  std_logic_vector(31 downto 0);
    x_exp     : in  std_logic_vector(31 downto 0);
    out_mode  : in  std_logic_vector(1 downto 0);
    w_base    : in  std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats   : in  std_logic_vector(31 downto 0);
    s_base    : in  std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats   : in  std_logic_vector(31 downto 0);
    cb_we     : in  std_logic;
    cb_addr   : in  std_logic_vector(3 downto 0);
    cb_data   : in  std_logic_vector(7 downto 0);
    x_we      : in  std_logic;
    x_waddr   : in  std_logic_vector(15 downto 0);
    x_wdata   : in  std_logic_vector(15 downto 0);
    m_arvalid : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_arready : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_araddr  : out std_logic_vector((NPORTS_W+NPORTS_S)*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector((NPORTS_W+NPORTS_S)*8-1 downto 0);
    m_arsize  : out std_logic_vector((NPORTS_W+NPORTS_S)*3-1 downto 0);
    m_arburst : out std_logic_vector((NPORTS_W+NPORTS_S)*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rready  : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rdata   : in  std_logic_vector((NPORTS_W+NPORTS_S)*AXI_DW-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    y_we      : out std_logic;
    y_addr    : out std_logic_vector(15 downto 0);
    y_data    : out std_logic_vector(ROWS_IF*64-1 downto 0);
    y_mask    : out std_logic_vector(ROWS_IF-1 downto 0);
    y_exp     : out std_logic_vector(31 downto 0);
    done      : out std_logic;
    err       : out std_logic;
    sat_event : out std_logic;
    -- a pulse per row-tile result taken by the back end, and the weight words (nb) it
    -- stands for: what matvec_int4_desc_axi's BEATS register counts in place of
    -- matvec_int4's per-word dbg_wbeat
    dbg_rtile : out std_logic;
    dbg_words : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of mv4i_tiled is
begin
  g_split : if A_CLK_SPLIT generate
    u : entity work.mv4i_tcore
      generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W, NPORTS_S => NPORTS_S,
                  AXI_DW => AXI_DW, ADDR_W => ADDR_W, MAXCOLS => MAXCOLS,
                  MAXROWS_BFP => MAXROWS_BFP, FIFO_DEPTH => FIFO_DEPTH, MAXB => MAXB,
                  MAXOUT => MAXOUT, XD => XD, G => G)
      port map(clk => clk, rst => rst, aclk_a => aclk, start => start,
               n_rows => n_rows, n_cols => n_cols, out_shift => out_shift, w_exp => w_exp,
               x_exp => x_exp, out_mode => out_mode, w_base => w_base, w_beats => w_beats,
               s_base => s_base, s_beats => s_beats, cb_we => cb_we, cb_addr => cb_addr,
               cb_data => cb_data, x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
               m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
               m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
               m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
               m_rlast => m_rlast, y_we => y_we, y_addr => y_addr, y_data => y_data,
               y_mask => y_mask, y_exp => y_exp, done => done, err => err,
               sat_event => sat_event, dbg_rtile => dbg_rtile, dbg_words => dbg_words);
  end generate;
  g_same : if not A_CLK_SPLIT generate
    u : entity work.mv4i_tcore
      generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W, NPORTS_S => NPORTS_S,
                  AXI_DW => AXI_DW, ADDR_W => ADDR_W, MAXCOLS => MAXCOLS,
                  MAXROWS_BFP => MAXROWS_BFP, FIFO_DEPTH => FIFO_DEPTH, MAXB => MAXB,
                  MAXOUT => MAXOUT, XD => XD, G => G)
      port map(clk => clk, rst => rst, aclk_a => clk, start => start,
               n_rows => n_rows, n_cols => n_cols, out_shift => out_shift, w_exp => w_exp,
               x_exp => x_exp, out_mode => out_mode, w_base => w_base, w_beats => w_beats,
               s_base => s_base, s_beats => s_beats, cb_we => cb_we, cb_addr => cb_addr,
               cb_data => cb_data, x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
               m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
               m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
               m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
               m_rlast => m_rlast, y_we => y_we, y_addr => y_addr, y_data => y_data,
               y_mask => y_mask, y_exp => y_exp, done => done, err => err,
               sat_event => sat_event, dbg_rtile => dbg_rtile, dbg_words => dbg_words);
  end generate;
end architecture;
```

- [ ] **Step 5: Run the bench row**

Memory: 3.7 GB for this row. Check `free -g` first; with `llama-server` up there are about 13 GB.

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/a450_t6 bash sim/regress.sh --suite sim --only tb_mv4i_tiled --keep`
Expected: `PASS sim:tb_mv4i_tiled ... PASS: tb_mv4i_tiled checks=150` and `OVERALL PASS 1`. The log shows one `job <j> ...` note per job: jobs 8, 9 and 10 with `err '1'`, job 4 with `sat '1'`, job 14 `reset mid-job`, job 16 `beats 10`.

- [ ] **Step 6: Write and run the credit-loss mutant (spec 3.1)**

`sim/mutants/mv4i_tiled.json`:

```json
{
  "tb": "tb_mv4i_tiled",
  "deps": ["rtl/util_pkg.vhd", "rtl/mv4i_arith_pkg.vhd", "rtl/stream_fifo.vhd",
           "rtl/async_fifo.vhd", "rtl/axi_rd_fsm.vhd", "rtl/axi_rd_port.vhd",
           "rtl/weight_streamer.vhd", "rtl/act_mem_striped.vhd", "rtl/matvec_core.vhd",
           "rtl/matvec_int4.vhd", "rtl/mv_lfifo.vhd", "rtl/mv_tile.vhd", "rtl/mv_xbcast.vhd",
           "rtl/act_mem_dp.vhd", "rtl/mv_dist.vhd", "rtl/mv_rlink.vhd", "rtl/mv_rchain.vhd",
           "rtl/mv_rcross.vhd", "rtl/mv_tsync.vhd", "rtl/mv_afast.vhd", "rtl/mv_back.vhd",
           "rtl/mv4i_tcore.vhd", "rtl/mv4i_tiled.vhd", "sim/axi_rd_mem_model.vhd",
           "sim/tb_mv4i_tiled.vhd"],
  "stop_time": "1ms",
  "timeout_s": 5400,
  "rows": [
    {"tag": "Z0", "expect": "PASS"},
    {"tag": "C1", "expect": "KILLED", "file": "rtl/mv_xbcast.vhd",
     "why": "credit loss under real tiles: the room AND tree ignores tile 13, whose weight port has the long stalls",
     "old": "for i in 0 to G-1 loop a := a and rooms(k*G + i); end loop;",
     "new": "for i in 0 to G-1 loop if k*G + i /= 13 then a := a and rooms(k*G + i); end if; end loop;"}
  ]
}
```

Run: `python3 sim/mutate_rows.py sim/mutants/mv4i_tiled.json`
Expected: `MUTROW Z0 PASS PASS` (about 13 min), `MUTROW C1 KILLED KILLED`, `MUTANTS_OK 2`; C1's log ends on `mv_tile: a flit arrived with the flit FIFO full (room/credit overrun)` in `g_t(13).tile` at about 54 us (MEASURED 2026-11-12). C1 SURVIVED twice while this plan was written: first because no job had more than 40 items per tile (every job fit in the 32-deep flit FIFO plus the 64-beat weight FIFO), then because port 13's stalls at 3 per 1,024 cycles rarely landed while job 16 still had items to send. Job 16 and port 13's 8 per 1,024 are what give Review Focus item 5 its teeth. If C1 survives again, stop and fix the bench, not the mutant.

- [ ] **Step 7: Commit**

```bash
git add rtl/mv_afast.vhd rtl/mv_back.vhd rtl/mv4i_tcore.vhd rtl/mv4i_tiled.vhd \
        sim/tb_mv4i_tiled.vhd sim/mutants/mv4i_tiled.json sim/regress.sh
git commit -m "a450 Task 6: composed tiled A, A_CLK_SPLIT, beat-identical to matvec_int4 on 16 jobs split and same"
```

---
### Task 7: A+HBM 450 MHz test design with pblocks (spec 3.2 gate 2, the honest gate)

Vivado synthesis and route only. A subagent may run it; it must not touch hardware. `llama-server` must be stopped for Steps 6 and 8 (Oren's call: ask first, through the main session).

**Files:**
- Create: `rtl/a450_stub_seq.vhd`
- Create: `hw/jc/a450/gen_a450_hbm_top.py`, `hw/jc/a450/a450_hbm_top.vhd` (generated)
- Create: `hw/jc/a450/a450_bd.tcl`, `hw/jc/a450/a450.xdc`, `hw/jc/a450/a450_cdc.tcl`, `hw/jc/a450/a450_pblocks.tcl`, `hw/jc/a450/build_a450.tcl`, `hw/jc/a450/run_a450.sh`
- Create: `hw/jc/a450/test_a450.py`
- Modify: `hw/targets/blocks.json` (row `a450_afast`)

**Interfaces:**
- Consumes: `mv4i_tiled` (Task 6) and its instance paths (`g_split.u/back/go_r_reg`, `g_split.u/fast/dist/s_start_reg`, `g_split.u/fast/g_t[p].tile`, `g_split.u/fast/chain/g[p].lk`); `hw/fk33/gen_pcieep.py` `ENG_PORT_MAP` (the card's SAXI map, whose first 27 entries are `1..15, 17..28`); `tools/genstamp.py`; `hw/jc/loader/run_capped.sh <nonce> <MemoryHigh> <swap_kill_bytes> <root> <cmd...>`.
- Produces:
  - `proc a450_cdc {core_glob aclk_glob}` (in `a450_cdc.tcl`): finds the two clocks from one pin of each domain, sets `set_max_delay -datapath_only` both ways (core to aclk at 2 aclk periods, aclk to core at 1 aclk period), prints `A450CDC ...`, returns `{core_clock aclk_clock}`. Task 8's `build_card.tcl` calls it.
  - `proc a450_pblocks {fast_re hbm_glob portmap}` (in `a450_pblocks.tcl`): one pblock per HBM clock-region column holding the tiles and chain links of the ports there; returns the pblock count.
  - `run_a450.sh [--dry-run] <root>` prints exactly one of `A450RUN_PASS <wns>`, `A450RUN_TIMING_FAIL <wns>`, `A450RUN_FAIL <reason>` (or `A450RUN_DRY`).

- [ ] **Step 1: Write the structural tests**

`hw/jc/a450/test_a450.py`:

```python
"""hw/jc/a450/test_a450.py -- structural checks over the a450 A+HBM timing design
(plan docs/superpowers/plans/2026-11-12-a450-per-port-tiles.md, Task 7).

Pure Python plus GHDL analysis; no Vivado, no hardware.  Run:
    python3 -m pytest hw/jc/a450/test_a450.py -q

What these checks are NOT: evidence that the design routes or meets 450 MHz.  They pin
what the run script and the Tcl promise (the generated top is current, the port map is
the card's, every pblock names a tile port, the run is routed and refuses the unsafe
cases), so a broken edit fails here in seconds instead of 90 minutes into a route.
"""
import os
import re
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "hw", "fk33"))
saved = sys.argv
sys.argv = ["gen_pcieep.py"]
import gen_pcieep as P  # noqa: E402
sys.argv = saved


def _read(name):
    with open(os.path.join(HERE, name)) as f:
        return f.read()


def _code(text):
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def _tcl_list(text, var):
    m = re.search(r"^set %s \{([^}]*)\}" % var, text, re.M)
    assert m, var
    return [int(x) for x in m.group(1).split()]


def test_generated_top_is_current():
    r = subprocess.run([sys.executable, os.path.join(HERE, "gen_a450_hbm_top.py"), "--check"],
                       capture_output=True, text=True)
    assert r.returncode == 0 and re.search(r"^GEN_A450_TOP_CHECK OK", r.stdout, re.M), r.stdout


def test_top_has_27_axi3_masters():
    t = _read("a450_hbm_top.vhd")
    for i in range(27):
        assert re.search(r"\bm%02d_axi_arvalid\b" % i, t), i
    assert not re.search(r"\bm27_axi_arvalid\b", t)


def test_portmap_is_the_card_s_engine_map():
    bd = _read("a450_bd.tcl")
    assert _tcl_list(bd, "PORTMAP") == list(P.ENG_PORT_MAP[:27])


def test_pblocks_name_the_24_tile_ports():
    b = _read("build_a450.tcl")
    m = re.search(r"a450_pblocks \{[^}]*\} \"[^\"]*\" \\\s*\{([^}]*)\}", b)
    assert m, "a450_pblocks call not found"
    assert [int(x) for x in m.group(1).split()] == list(P.ENG_PORT_MAP[:24])


def test_build_routes_and_reports_routed_wns():
    b = _code(_read("build_a450.tcl"))
    assert re.search(r"^\s*route_design\b", b, re.M)
    r = b.index("route_design")
    for s in ("A450HBM_WNS_ACLK", "A450HBM_WNS_CORE", "A450HBM_DONE"):
        assert b.index(s, r) > r, "%s is not printed after route_design" % s
    assert re.search(r"^\s*source \$here/a450_cdc\.tcl", b, re.M)


def test_run_script_dry_run_and_refusals():
    sh = os.path.join(HERE, "run_a450.sh")
    r = subprocess.run(["bash", sh, "--dry-run", "/mnt/storage/fk33_builds/a450_test_dry_never"],
                       capture_output=True, text=True)
    assert r.returncode == 0 and re.search(r"^A450RUN_DRY$", r.stdout, re.M), r.stdout
    assert "run_capped.sh" in r.stdout and " 24G " in r.stdout
    for bad in ("/tmp/a450x", "relative/a450"):
        r = subprocess.run(["bash", sh, "--dry-run", bad], capture_output=True, text=True)
        assert r.returncode != 0 and re.search(r"^A450RUN_FAIL ", r.stdout, re.M), bad
    s = _read("run_a450.sh")
    assert "pgrep" not in s and "pkill" not in s
    assert "/proc" in s and "readlink" in s
    assert re.search(r"grep -nE \"\^A450HBM_NONCE", s)
    assert re.search(r"grep -nE '\^A450HBM_DONE'", s)


@pytest.mark.skipif(subprocess.run(["which", "ghdl"], capture_output=True).returncode != 0,
                    reason="ghdl not installed")
def test_rtl_closure_analyses(tmp_path):
    b = _read("build_a450.tcl")
    files = re.search(r"^set RTL08 \{([^}]*)\}", b, re.M).group(1).split()
    files.append("hw/jc/a450/a450_hbm_top.vhd")
    for f in files:
        r = subprocess.run(["ghdl", "-a", "--std=08", "-frelaxed", "--workdir=%s" % tmp_path,
                            os.path.join(REPO, f)], capture_output=True, text=True)
        assert r.returncode == 0 and "error" not in r.stderr.lower(), (f, r.stderr)
```

Run: `python3 -m pytest hw/jc/a450/test_a450.py -q`
Expected: FAIL (errors: `gen_a450_hbm_top.py`, `a450_bd.tcl` and the rest do not exist yet).

- [ ] **Step 2: Write the stub sequencer and the top generator, then generate the top**

`rtl/a450_stub_seq.vhd` (an LFSR job generator: writes 64 x values, 16 codebook entries, sets a job, pulses start, waits for done; folds every `y_data` bit, `y_exp`, `err` and `sat_event` into `obs` so synthesis keeps the whole datapath):

```vhdl
-- rtl/a450_stub_seq.vhd -- the stub sequencer of the a450 A+HBM timing design (plan
-- Task 7, spec 3.2 gate 2).  It keeps every path of rtl/mv4i_tiled.vhd alive without a
-- host: it loads 64 activations and a codebook from an LFSR, starts a legal job (random
-- shape, out_shift and mode, bases and beat counts consistent with the shape), waits for
-- done, and folds every y beat, y_exp, err and sat into `obs`, which drives an LED, so
-- synthesis can trim nothing.  It computes nothing anyone checks; it is timing harness.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity a450_stub_seq is
  generic(
    NPORTS_W : positive := 24;
    NPORTS_S : positive := 3;
    ADDR_W   : positive := 40;
    ROWS_IF  : positive := 48
  );
  port(
    clk, rst  : in  std_logic;
    start     : out std_logic;
    n_rows    : out std_logic_vector(31 downto 0);
    n_cols    : out std_logic_vector(31 downto 0);
    out_shift : out std_logic_vector(31 downto 0);
    w_exp     : out std_logic_vector(31 downto 0);
    x_exp     : out std_logic_vector(31 downto 0);
    out_mode  : out std_logic_vector(1 downto 0);
    w_base    : out std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats   : out std_logic_vector(31 downto 0);
    s_base    : out std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats   : out std_logic_vector(31 downto 0);
    cb_we     : out std_logic;
    cb_addr   : out std_logic_vector(3 downto 0);
    cb_data   : out std_logic_vector(7 downto 0);
    x_we      : out std_logic;
    x_waddr   : out std_logic_vector(15 downto 0);
    x_wdata   : out std_logic_vector(15 downto 0);
    y_we      : in  std_logic;
    y_data    : in  std_logic_vector(ROWS_IF*64-1 downto 0);
    y_exp     : in  std_logic_vector(31 downto 0);
    done      : in  std_logic;
    err       : in  std_logic;
    sat_event : in  std_logic;
    jobs      : out std_logic_vector(31 downto 0);
    obs       : out std_logic
  );
end entity;

architecture rtl of a450_stub_seq is
  type st_t is (T_X, T_CB, T_SET, T_GO, T_WAIT);
  signal st  : st_t := T_X;
  signal lf  : unsigned(31 downto 0) := x"ACE11234";
  signal cnt : natural range 0 to 63 := 0;
  signal tl, nbk : natural range 1 to 8 := 1;
  signal acc : std_logic_vector(63 downto 0) := (others => '0');
  signal fold : std_logic_vector(7 downto 0) := (others => '0');
  signal o : std_logic := '0';
  signal nj : unsigned(31 downto 0) := (others => '0');
begin
  jobs <= std_logic_vector(nj);
  obs  <= o;
  g_wb : for p in 0 to NPORTS_W-1 generate
    w_base((p+1)*ADDR_W-1 downto p*ADDR_W) <= std_logic_vector(to_unsigned(p, ADDR_W - 22)) & (21 downto 0 => '0');
  end generate;
  g_sb : for q in 0 to NPORTS_S-1 generate
    s_base((q+1)*ADDR_W-1 downto q*ADDR_W) <= std_logic_vector(to_unsigned(NPORTS_W + q, ADDR_W - 22)) & (21 downto 0 => '0');
  end generate;

  seq : process(clk)
    variable v : std_logic_vector(63 downto 0);
  begin
    if rising_edge(clk) then
      lf <= lf(30 downto 0) & (lf(31) xor lf(21) xor lf(1) xor lf(0));
      start <= '0'; cb_we <= '0'; x_we <= '0';
      -- observe everything the DUT emits
      if y_we = '1' then
        v := acc;
        for r in 0 to ROWS_IF-1 loop v := v xor y_data(r*64+63 downto r*64); end loop;
        acc <= v xor (x"00000000" & y_exp);
      end if;
      for i in 0 to 7 loop
        fold(i) <= acc(i*8) xor acc(i*8+1) xor acc(i*8+2) xor acc(i*8+3)
                 xor acc(i*8+4) xor acc(i*8+5) xor acc(i*8+6) xor acc(i*8+7);
      end loop;
      o <= fold(0) xor fold(1) xor fold(2) xor fold(3) xor fold(4) xor fold(5)
         xor fold(6) xor fold(7) xor err xor sat_event;
      case st is
        when T_X =>
          x_we <= '1';
          x_waddr <= std_logic_vector(to_unsigned(cnt, 16));
          x_wdata <= std_logic_vector(lf(15 downto 0));
          if cnt = 63 then cnt <= 0; st <= T_CB; else cnt <= cnt + 1; end if;
        when T_CB =>
          cb_we <= '1';
          cb_addr <= std_logic_vector(to_unsigned(cnt, 4));
          cb_data <= std_logic_vector(lf(7 downto 0));
          if cnt = 15 then cnt <= 0; st <= T_SET; else cnt <= cnt + 1; end if;
        when T_SET =>
          tl  <= to_integer(lf(2 downto 0)) + 1;
          nbk <= to_integer(lf(5 downto 3)) + 1;
          st  <= T_GO;
        when T_GO =>
          n_rows    <= std_logic_vector(to_unsigned(tl * ROWS_IF - to_integer(lf(3 downto 0)), 32));
          n_cols    <= std_logic_vector(to_unsigned(nbk * 32 - to_integer(lf(8 downto 4)), 32));
          out_shift <= std_logic_vector(to_unsigned(to_integer(lf(13 downto 9)) mod 41, 32));
          w_exp     <= std_logic_vector(resize(signed(lf(17 downto 14)), 32));
          x_exp     <= std_logic_vector(resize(signed(lf(21 downto 18)), 32));
          if lf(23 downto 22) = "11" then out_mode <= "00";
          else out_mode <= std_logic_vector(lf(23 downto 22)); end if;
          w_beats   <= std_logic_vector(to_unsigned(tl * nbk, 32));
          s_beats   <= std_logic_vector(to_unsigned(tl * nbk, 32));
          start <= '1';
          nj <= nj + 1;
          st <= T_WAIT;
        when T_WAIT =>
          if done = '1' then st <= T_X; end if;
      end case;
      if rst = '1' then
        st <= T_X; cnt <= 0; acc <= (others => '0'); nj <= (others => '0');
      end if;
    end if;
  end process;
end architecture;
```

`hw/jc/a450/gen_a450_hbm_top.py`:

```python
#!/usr/bin/env python3
"""hw/jc/a450/gen_a450_hbm_top.py -- writes hw/jc/a450/a450_hbm_top.vhd, the module-reference
top of the a450 A+HBM timing design (plan 2026-11-12-a450-per-port-tiles Task 7, spec 3.2
gate 2): rtl/mv4i_tiled.vhd at A_CLK_SPLIT = true, driven by rtl/a450_stub_seq.vhd, with
its 27 read masters as 27 AXI3 interfaces m00_axi..m26_axi that the block design wires to
HBM SAXI ports.

The top is VHDL-93 with literal widths and no input defaults (hw/fk33/CLAUDE.md: a
module-reference top), so the 27 x 29 ports are generated, not typed.  The write channels
exist only so the block design infers full AXI3 interfaces; they are tied idle.

    python3 hw/jc/a450/gen_a450_hbm_top.py           write the file
    python3 hw/jc/a450/gen_a450_hbm_top.py --check   compare, print GEN_A450_TOP_CHECK OK|STALE
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools"))
import genstamp  # noqa: E402

DST = os.path.join(HERE, "a450_hbm_top.vhd")
NW, NS = 24, 3
NM = NW + NS
AW = 33          # the HBM SAXI address
DW = 256
IDW = 6


def ports():
    out = []
    for i in range(NM):
        p = "m%02d_axi" % i
        out += ["    %s_awvalid : out std_logic;" % p,
                "    %s_awready : in  std_logic;" % p,
                "    %s_awaddr  : out std_logic_vector(%d downto 0);" % (p, AW - 1),
                "    %s_awid    : out std_logic_vector(%d downto 0);" % (p, IDW - 1),
                "    %s_awlen   : out std_logic_vector(3 downto 0);" % p,
                "    %s_awsize  : out std_logic_vector(2 downto 0);" % p,
                "    %s_awburst : out std_logic_vector(1 downto 0);" % p,
                "    %s_wvalid  : out std_logic;" % p,
                "    %s_wready  : in  std_logic;" % p,
                "    %s_wdata   : out std_logic_vector(%d downto 0);" % (p, DW - 1),
                "    %s_wstrb   : out std_logic_vector(%d downto 0);" % (p, DW // 8 - 1),
                "    %s_wlast   : out std_logic;" % p,
                "    %s_bvalid  : in  std_logic;" % p,
                "    %s_bready  : out std_logic;" % p,
                "    %s_bid     : in  std_logic_vector(%d downto 0);" % (p, IDW - 1),
                "    %s_bresp   : in  std_logic_vector(1 downto 0);" % p,
                "    %s_arvalid : out std_logic;" % p,
                "    %s_arready : in  std_logic;" % p,
                "    %s_araddr  : out std_logic_vector(%d downto 0);" % (p, AW - 1),
                "    %s_arid    : out std_logic_vector(%d downto 0);" % (p, IDW - 1),
                "    %s_arlen   : out std_logic_vector(3 downto 0);" % p,
                "    %s_arsize  : out std_logic_vector(2 downto 0);" % p,
                "    %s_arburst : out std_logic_vector(1 downto 0);" % p,
                "    %s_rvalid  : in  std_logic;" % p,
                "    %s_rready  : out std_logic;" % p,
                "    %s_rdata   : in  std_logic_vector(%d downto 0);" % (p, DW - 1),
                "    %s_rlast   : in  std_logic;" % p,
                "    %s_rid     : in  std_logic_vector(%d downto 0);" % (p, IDW - 1),
                "    %s_rresp   : in  std_logic_vector(1 downto 0);" % p]
    out[-1] = out[-1].rstrip(";")
    return "\n".join(out)


def wiring():
    out = []
    for i in range(NM):
        p = "m%02d_axi" % i
        out += ["  %s_awvalid <= '0'; %s_awaddr <= (others => '0'); %s_awid <= (others => '0');"
                % (p, p, p),
                "  %s_awlen <= (others => '0'); %s_awsize <= \"101\"; %s_awburst <= \"01\";"
                % (p, p, p),
                "  %s_wvalid <= '0'; %s_wdata <= (others => '0'); %s_wstrb <= (others => '0');"
                % (p, p, p),
                "  %s_wlast <= '0'; %s_bready <= '1'; %s_arid <= (others => '0');" % (p, p, p),
                "  %s_arvalid <= m_arvalid(%d); m_arready(%d) <= %s_arready;" % (p, i, i, p),
                "  %s_araddr <= m_araddr(%d downto %d);" % (p, i * AW + AW - 1, i * AW),
                "  %s_arlen <= m_arlen(%d downto %d);" % (p, i * 8 + 3, i * 8),
                "  %s_arsize <= m_arsize(%d downto %d); %s_arburst <= m_arburst(%d downto %d);"
                % (p, i * 3 + 2, i * 3, p, i * 2 + 1, i * 2),
                "  m_rvalid(%d) <= %s_rvalid; %s_rready <= m_rready(%d);" % (i, p, p, i),
                "  m_rdata(%d downto %d) <= %s_rdata; m_rlast(%d) <= %s_rlast;"
                % (i * DW + DW - 1, i * DW, p, i, p)]
    return "\n".join(out)


BODY = """-- hw/jc/a450/a450_hbm_top.vhd -- GENERATED by hw/jc/a450/gen_a450_hbm_top.py.
-- DO NOT HAND-EDIT; edit the generator.
--
{STAMP}--
-- The a450 A+HBM timing design's module-reference top (plan Task 7): rtl/mv4i_tiled.vhd
-- at A_CLK_SPLIT = true (tiles and the 27 masters on aclk_a, the back end on clk_core),
-- jobs from rtl/a450_stub_seq.vhd, everything it emits folded into `led`.  ARLEN is AXI3
-- (4 bits): MAXB = 16 keeps every burst at or below 16 beats, so the truncation is exact.
library ieee;
use ieee.std_logic_1164.all;

entity a450_hbm_top is
  port(
    clk_core  : in  std_logic;
    core_rstn : in  std_logic;
    aclk_a    : in  std_logic;
    led       : out std_logic;
{PORTS}
  );
end entity;

architecture rtl of a450_hbm_top is
  signal rst : std_logic;
  signal start, cb_we, x_we : std_logic;
  signal n_rows, n_cols, out_shift, w_exp, x_exp, w_beats, s_beats : std_logic_vector(31 downto 0);
  signal out_mode : std_logic_vector(1 downto 0);
  signal w_base : std_logic_vector({NW}*{AW}-1 downto 0);
  signal s_base : std_logic_vector({NS}*{AW}-1 downto 0);
  signal cb_addr : std_logic_vector(3 downto 0);
  signal cb_data : std_logic_vector(7 downto 0);
  signal x_waddr, x_wdata : std_logic_vector(15 downto 0);
  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast : std_logic_vector({NM}-1 downto 0);
  signal m_araddr : std_logic_vector({NM}*{AW}-1 downto 0);
  signal m_arlen : std_logic_vector({NM}*8-1 downto 0);
  signal m_arsize : std_logic_vector({NM}*3-1 downto 0);
  signal m_arburst : std_logic_vector({NM}*2-1 downto 0);
  signal m_rdata : std_logic_vector({NM}*{DW}-1 downto 0);
  signal y_we, done, err, sat : std_logic;
  signal y_addr : std_logic_vector(15 downto 0);
  signal y_data : std_logic_vector(48*64-1 downto 0);
  signal y_mask : std_logic_vector(47 downto 0);
  signal y_exp : std_logic_vector(31 downto 0);
begin
  rst <= not core_rstn;

  a : entity work.mv4i_tiled
    generic map(BLK => 32, ROWS_IF => 48, NPORTS_W => {NW}, NPORTS_S => {NS}, AXI_DW => {DW},
                ADDR_W => {AW}, MAXCOLS => 17408, MAXROWS_BFP => 17408, FIFO_DEPTH => 512,
                MAXB => 16, MAXOUT => 16, A_CLK_SPLIT => true)
    port map(clk => clk_core, rst => rst, aclk => aclk_a, start => start,
             n_rows => n_rows, n_cols => n_cols, out_shift => out_shift, w_exp => w_exp,
             x_exp => x_exp, out_mode => out_mode, w_base => w_base, w_beats => w_beats,
             s_base => s_base, s_beats => s_beats, cb_we => cb_we, cb_addr => cb_addr,
             cb_data => cb_data, x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
             m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
             m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
             m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
             m_rlast => m_rlast, y_we => y_we, y_addr => y_addr, y_data => y_data,
             y_mask => y_mask, y_exp => y_exp, done => done, err => err, sat_event => sat);

  stub : entity work.a450_stub_seq
    generic map(NPORTS_W => {NW}, NPORTS_S => {NS}, ADDR_W => {AW}, ROWS_IF => 48)
    port map(clk => clk_core, rst => rst, start => start, n_rows => n_rows, n_cols => n_cols,
             out_shift => out_shift, w_exp => w_exp, x_exp => x_exp, out_mode => out_mode,
             w_base => w_base, w_beats => w_beats, s_base => s_base, s_beats => s_beats,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
             y_we => y_we, y_data => y_data, y_exp => y_exp, done => done, err => err,
             sat_event => sat, jobs => open, obs => led);

{WIRING}
end architecture;
"""


def render():
    stamp = genstamp.stamp(["python3", "hw/jc/a450/gen_a450_hbm_top.py"], [], comment="--")
    return BODY.format(STAMP=stamp, PORTS=ports(), WIRING=wiring(), NW=NW, NS=NS, NM=NM,
                       AW=AW, DW=DW)


def main(argv):
    txt = render()
    if argv[1:] == ["--check"]:
        ok = os.path.exists(DST) and open(DST).read() == txt
        print("GEN_A450_TOP_CHECK %s" % ("OK" if ok else "STALE"))
        return 0 if ok else 1
    if argv[1:]:
        print(__doc__)
        return 2
    open(DST, "w").write(txt)
    print("wrote %s (%d masters)" % (DST, NM))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

Run: `python3 hw/jc/a450/gen_a450_hbm_top.py && python3 hw/jc/a450/gen_a450_hbm_top.py --check`
Expected: `wrote .../hw/jc/a450/a450_hbm_top.vhd (27 masters)` then `GEN_A450_TOP_CHECK OK`.

- [ ] **Step 3: Write the block design, constraints and build scripts**

`hw/jc/a450/a450_bd.tcl` (sysclk through IBUFDS into `clk_wiz_0` at 100/200/125 MHz; `clk_wiz_a` makes 450 MHz from `clk_out2`; all 32 HBM SAXI ports on `aclk_a`; the top as a module reference with masters on `PORTMAP`):

```tcl
# hw/jc/a450/a450_bd.tcl -- block design of the a450 A+HBM timing design (plan
# 2026-11-12-a450-per-port-tiles Task 7, spec 3.2 gate 2).  Sourced by build_a450.tcl.
#
#   sysclk (200 MHz LVDS, BC26/BC27) -> clk_wiz_0: clk_out1 100 (HBM APB), clk_out2 200
#   (HBM ref), clk_out3 125 (clk_core) -> clk_wiz_a: clk_out1 450 (aclk_a), from clk_out2.
#   hbm: 2 stacks, all 32 SAXI on aclk_a at USER_AXI_INPUT_CLK_FREQ 450 (PG276: the switch
#   runs on an AXI port clock, so every port moves with A).
#   top (a450_hbm_top): m00..m23 weight ports, m24..m26 scale ports, on hbm/SAXI_nn per
#   gen_pcieep.ENG_PORT_MAP's first 27 entries (the card's own map).  SAXI 00, 16, 29, 30,
#   31 are enabled and clocked but carry no master.
# Every CONFIG this file sets is read back (a set_property on a name the object lacks is
# silent).  Sentinels: A450BD_CFG lines, A450BD_DONE; failures are Tcl errors.
create_bd_design a450

proc a4_want {cell key want} {
  set got [get_property CONFIG.$key [get_bd_cells $cell]]
  if {[string toupper $got] ne [string toupper $want]} {
    error "A450BD_CFG FAIL $cell.$key is \"$got\", not \"$want\""
  }
  puts "A450BD_CFG $cell.$key = $got"
}

set PORTMAP {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 17 18 19 20 21 22 23 24 25 26 27 28}

create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 sysclk_buf
set_property CONFIG.C_BUF_TYPE {IBUFDS} [get_bd_cells sysclk_buf]
make_bd_intf_pins_external [get_bd_intf_pins sysclk_buf/CLK_IN_D]
set_property name sysclk [get_bd_intf_ports CLK_IN_D_0]
set_property CONFIG.FREQ_HZ 200000000 [get_bd_intf_ports sysclk]

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list CONFIG.PRIM_IN_FREQ.VALUE_SRC USER] [get_bd_cells clk_wiz_0]
set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} CONFIG.PRIM_IN_FREQ {200.000} \
  CONFIG.USE_RESET {false} \
  CONFIG.CLKOUT1_USED {true} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
  CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {125.000}] [get_bd_cells clk_wiz_0]
foreach {k v} {PRIM_SOURCE No_buffer USE_RESET false CLKOUT1_REQUESTED_OUT_FREQ 100.000
               CLKOUT2_REQUESTED_OUT_FREQ 200.000 CLKOUT3_REQUESTED_OUT_FREQ 125.000} {
  a4_want clk_wiz_0 $k $v
}
connect_bd_net [get_bd_pins sysclk_buf/IBUF_OUT] [get_bd_pins clk_wiz_0/clk_in1]

# aclk_a: a second MMCM on clk_out2.  One MMCM cannot make 125 and 450 together (their
# lcm, 2250 MHz, is above the VCO range), so the 450 comes from its own.
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_a
set_property -dict [list CONFIG.PRIM_IN_FREQ.VALUE_SRC USER] [get_bd_cells clk_wiz_a]
set_property -dict [list CONFIG.PRIM_SOURCE {Global_buffer} CONFIG.PRIM_IN_FREQ {200.000} \
  CONFIG.USE_RESET {false} \
  CONFIG.CLKOUT1_USED {true} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {450.000}] [get_bd_cells clk_wiz_a]
foreach {k v} {PRIM_SOURCE Global_buffer USE_RESET false CLKOUT1_REQUESTED_OUT_FREQ 450.000} {
  a4_want clk_wiz_a $k $v
}
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins clk_wiz_a/clk_in1]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one
set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] [get_bd_cells one]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 core_reset
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 aclk_reset
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 apb_rst
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins core_reset/dcm_locked]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins apb_rst/dcm_locked]
connect_bd_net [get_bd_pins clk_wiz_a/locked] [get_bd_pins aclk_reset/dcm_locked]
foreach r {core_reset aclk_reset apb_rst} {
  connect_bd_net [get_bd_pins one/dout] [get_bd_pins $r/ext_reset_in]
}
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins core_reset/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins aclk_reset/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins apb_rst/slowest_sync_clk]

create_bd_cell -type ip -vlnv xilinx.com:ip:hbm:1.0 hbm
set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {2} \
  CONFIG.USER_MEMORY_DISPLAY {8192}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_HBM_REF_CLK_0 {200} CONFIG.USER_HBM_REF_CLK_1 {200} \
  CONFIG.USER_AXI_INPUT_CLK_FREQ {450} CONFIG.USER_AXI_INPUT_CLK1_FREQ {450}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_SWITCH_ENABLE_00 {TRUE} CONFIG.USER_SWITCH_ENABLE_01 {TRUE}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK}] [get_bd_cells hbm]
for {set i 0} {$i < 32} {incr i} {
  set_property [format CONFIG.USER_SAXI_%02d $i] {true} [get_bd_cells hbm]
}
set_property CONFIG.USER_APB_EN {false} [get_bd_cells hbm]
foreach {k v} {USER_HBM_DENSITY 8GB USER_HBM_STACK 2 USER_HBM_REF_CLK_0 200 USER_HBM_REF_CLK_1 200
               USER_AXI_INPUT_CLK_FREQ 450 USER_AXI_INPUT_CLK1_FREQ 450
               USER_SWITCH_ENABLE_00 TRUE USER_SWITCH_ENABLE_01 TRUE
               USER_CLK_SEL_LIST0 AXI_00_ACLK USER_CLK_SEL_LIST1 AXI_16_ACLK USER_APB_EN false} {
  a4_want hbm $k $v
}
for {set i 0} {$i < 32} {incr i} { a4_want hbm [format USER_SAXI_%02d $i] true }
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_0_PCLK]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_1_PCLK]
connect_bd_net [get_bd_pins apb_rst/peripheral_aresetn] [get_bd_pins hbm/APB_0_PRESET_N]
connect_bd_net [get_bd_pins apb_rst/peripheral_aresetn] [get_bd_pins hbm/APB_1_PRESET_N]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins hbm/HBM_REF_CLK_0]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins hbm/HBM_REF_CLK_1]
for {set i 0} {$i < 32} {incr i} {
  connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins [format hbm/AXI_%02d_ACLK $i]]
  connect_bd_net [get_bd_pins aclk_reset/peripheral_aresetn] [get_bd_pins [format hbm/AXI_%02d_ARESET_N $i]]
}

create_bd_cell -type module -reference a450_hbm_top top
set busif {}
for {set m 0} {$m < 27} {incr m} { lappend busif [format m%02d_axi $m] }
set busif [join $busif :]
set_property CONFIG.ASSOCIATED_BUSIF $busif [get_bd_pins top/aclk_a]
set got [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins top/aclk_a]]
if {$got ne $busif} { error "A450BD FAIL: top/aclk_a ASSOCIATED_BUSIF is \"$got\"" }
puts "A450BD ASSOCIATED_BUSIF top/aclk_a = 27 interfaces"
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins top/clk_core]
connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins top/core_rstn]
connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins top/aclk_a]
for {set m 0} {$m < 27} {incr m} {
  set s [lindex $PORTMAP $m]
  connect_bd_intf_net [get_bd_intf_pins [format top/m%02d_axi $m]] [get_bd_intf_pins [format hbm/SAXI_%02d $s]]
  for {set g 0} {$g < 32} {incr g} {
    assign_bd_address -target_address_space [get_bd_addr_spaces [format top/m%02d_axi $m]] \
      -offset [format 0x%X [expr {$g * 0x10000000}]] -range 256M \
      [get_bd_addr_segs [format "hbm/SAXI_%02d/HBM_MEM%02d" $s $g]]
  }
  set n [llength [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces [format top/m%02d_axi $m]]]]
  if {$n != 32} { error "A450BD FAIL: top/m[format %02d $m]_axi maps $n segments, not 32" }
}
puts "A450BD PORTMAP $PORTMAP"
create_bd_port -dir O led
connect_bd_net [get_bd_pins top/led] [get_bd_ports led]
validate_bd_design
save_bd_design
puts "A450BD_DONE"
```

`hw/jc/a450/a450.xdc`:

```tcl
# hw/jc/a450/a450.xdc -- pins of the a450 A+HBM timing design: the module oscillator and
# one LED, exactly as hw/jc/loader/jc_loader.xdc places them.  Timing between clk_core and
# aclk_a is in a450_cdc.tcl, applied to the opened design (an XDC line that matches
# nothing is only a warning; the Tcl stops).
set_property PACKAGE_PIN BC26 [get_ports sysclk_clk_p]
set_property PACKAGE_PIN BC27 [get_ports sysclk_clk_n]
set_property IOSTANDARD LVDS [get_ports sysclk_clk_p]
set_property IOSTANDARD LVDS [get_ports sysclk_clk_n]
set_property DIFF_TERM_ADV TERM_100 [get_ports sysclk_clk_p]
set_property DQS_BIAS TRUE [get_ports sysclk_clk_p]
create_clock -name sysclk -period 5.000 [get_ports sysclk_clk_p]
set_property PACKAGE_PIN K10 [get_ports led]
set_property IOSTANDARD LVCMOS18 [get_ports led]
set_false_path -to [get_ports led]
```

`hw/jc/a450/a450_cdc.tcl`:

```tcl
# hw/jc/a450/a450_cdc.tcl -- the clk_core <-> aclk_a crossings of rtl/mv4i_tiled.vhd
# (and of anything else between the two clocks), for an OPENED design.  Used by
# build_a450.tcl (Task 7) and by the split-on card (Task 9).
#
#   proc a450_cdc <core_pin_glob> <aclk_pin_glob>
# finds the two clocks from one register pin each (a pattern that matches nothing is an
# error), then bounds every path between them, datapath only:
#   clk_core -> aclk_a  2 aclk_a periods.  The j_* job values, the bases and the beat
#       counts are held from the start pulse on; aclk_a reads them only after j_go has
#       crossed (three aclk_a edges after the toggle lands, rtl/mv_tsync.vhd), and the
#       gray-coded read pointer of mv_rcross changes one bit per clk_core cycle.
#   aclk_a -> clk_core  1 aclk_a period: the gray-coded write pointer changes one bit per
#       aclk_a cycle, so its skew must stay under one aclk_a period.
# Prints A450CDC lines; returns the two clock names.
proc a450_cdc {core_glob aclk_glob} {
  set cp [get_pins -quiet -hierarchical -filter "NAME =~ $core_glob"]
  set ap [get_pins -quiet -hierarchical -filter "NAME =~ $aclk_glob"]
  if {[llength $cp] < 1} { error "A450CDC FAIL: no pin matches $core_glob" }
  if {[llength $ap] < 1} { error "A450CDC FAIL: no pin matches $aclk_glob" }
  set cc [get_clocks -of_objects [lindex $cp 0]]
  set ca [get_clocks -of_objects [lindex $ap 0]]
  if {[llength $cc] != 1 || [llength $ca] != 1 || $cc eq $ca} {
    error "A450CDC FAIL: clocks '$cc' and '$ca' are not two distinct clocks"
  }
  set pa [get_property PERIOD $ca]
  set_max_delay -datapath_only -from $cc -to $ca [expr {2.0 * $pa}]
  set_max_delay -datapath_only -from $ca -to $cc $pa
  puts "A450CDC core $cc period [get_property PERIOD $cc] aclk_a $ca period $pa"
  return [list $cc $ca]
}
```

`hw/jc/a450/a450_pblocks.tcl`:

```tcl
# hw/jc/a450/a450_pblocks.tcl -- spec 1.2's placement: one pblock per tile COLUMN, in
# SLR0 directly above the tiles' HBM ports.  For an OPENED, linked design.
#
#   proc a450_pblocks <fast_re> <hbm_glob> <portmap>
#     fast_re    a REGEXP for the mv_afast instance, e.g. {.*/g_split\.u/fast}
#     hbm_glob   the HBM IP instance prefix, e.g. "*/hbm/inst"
#     portmap    the SAXI number of weight tile p, p = 0..23 (scale ports are not tiles)
# For each tile p: the HBM interface cell of SAXI n = portmap(p) (stack n/16, interface
# n mod 16), its LOC, that site's clock region X; tile p and its result-chain link go in
# pblock pb_a450_x<X>, which spans CLOCKREGION_X<X>Y0:CLOCKREGION_X<X>Y3 (SLR0).
# Any query matching nothing is an error.  Prints A450PB lines; returns the pblock count.
proc a450_pblocks {fast_re hbm_glob portmap} {
  set cols [dict create]
  for {set p 0} {$p < [llength $portmap]} {incr p} {
    set n [lindex $portmap $p]
    set s [expr {$n / 16}]; set i [expr {$n % 16}]
    set hc [get_cells -quiet -hierarchical -filter \
      "NAME =~ ${hbm_glob}*HBM_ONE_STACK_INTF<$s>_INST/HBM_SNGLBLI_INTF_AXI<$i>_INST"]
    if {[llength $hc] != 1} { error "A450PB FAIL: SAXI_$n interface cell: [llength $hc] matches" }
    set loc [get_property LOC $hc]
    if {$loc eq ""} { error "A450PB FAIL: SAXI_$n interface cell $hc has no LOC" }
    set cr [get_clock_regions -of_objects [get_sites $loc]]
    if {![regexp {X(\d+)Y(\d+)} $cr -> x y]} { error "A450PB FAIL: clock region '$cr' of $loc" }
    set tc [get_cells -quiet -hierarchical -regexp -filter "NAME =~ ${fast_re}/g_t\\\[$p\\\]\\.tile"]
    set lc [get_cells -quiet -hierarchical -regexp -filter "NAME =~ ${fast_re}/chain/g\\\[$p\\\]\\.lk"]
    if {[llength $tc] != 1 || [llength $lc] != 1} {
      error "A450PB FAIL: tile $p: [llength $tc] tile cells, [llength $lc] link cells"
    }
    dict lappend cols $x $tc $lc
    puts "A450PB tile $p SAXI_$n site $loc region $cr"
  }
  foreach x [lsort -integer [dict keys $cols]] {
    set pb [create_pblock pb_a450_x$x]
    add_cells_to_pblock $pb [dict get $cols $x]
    resize_pblock $pb -add "CLOCKREGION_X${x}Y0:CLOCKREGION_X${x}Y3"
    puts "A450PB pblock pb_a450_x$x cells [llength [dict get $cols $x]]"
  }
  return [dict size $cols]
}
```

`hw/jc/a450/build_a450.tcl`:

```tcl
# hw/jc/a450/build_a450.tcl -- the a450 A+HBM timing design (plan 2026-11-12-a450-per-
# port-tiles Task 7, spec 3.2 gate 2): block design, synthesis, the CDC bounds and the
# tile pblocks, then opt/place/phys_opt/ROUTE in this process, and the routed reports.
# Synthesis and implementation only: nothing here opens a hardware target.
#
#   vivado -mode batch -source build_a450.tcl -tclargs <src_tree> <build_dir> -nonce <n>
#
# Sentinels (anchored): A450HBM_NONCE, A450HBM_SYNTH_DONE, A450HBM_ROUTE routing_errors,
# A450HBM_WNS_ACLK, A450HBM_WNS_CORE, A450HBM_WNS, A450HBM_WHS, A450HBM_UTIL, A450HBM_DONE;
# any failure prints A450HBM_FAIL <reason> and exits 1.  The gate is A450HBM_WNS_ACLK >= 0:
# the worst routed setup slack of every path ending in aclk_a.
set src   [file normalize [lindex $argv 0]]
set bd    [file normalize [lindex $argv 1]]
set ni    [lsearch -exact $argv -nonce]
set nonce [expr {$ni >= 0 ? [lindex $argv [expr {$ni + 1}]] : ""}]
proc a4_fail {msg} { puts "A450HBM_FAIL $msg"; exit 1 }
if {$nonce eq ""} { a4_fail "no -nonce on -tclargs" }
puts "A450HBM_NONCE $nonce"
set part xcvu35p-fsvh2104-2L-e
set here $src/hw/jc/a450
puts "A450HBM_PART $part"

create_project -force a450 $bd -part $part
set_param general.maxThreads 8
set RTL08 {
  rtl/util_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/stream_fifo.vhd rtl/async_fifo.vhd
  rtl/axi_rd_fsm.vhd rtl/axi_rd_port.vhd rtl/mv_lfifo.vhd rtl/mv_tile.vhd
  rtl/mv_xbcast.vhd rtl/act_mem_dp.vhd rtl/mv_dist.vhd rtl/mv_rlink.vhd rtl/mv_rchain.vhd
  rtl/mv_rcross.vhd rtl/mv_tsync.vhd rtl/mv_afast.vhd rtl/mv_back.vhd rtl/mv4i_tcore.vhd
  rtl/mv4i_tiled.vhd rtl/a450_stub_seq.vhd
}
foreach f $RTL08 {
  if {![file exists $src/$f]} { a4_fail "missing source $f" }
  add_files -norecurse $src/$f
  set_property file_type {VHDL 2008} [get_files $src/$f]
}
# the module-reference top: VHDL-93
add_files -norecurse $here/a450_hbm_top.vhd
update_compile_order -fileset sources_1
if {[catch {source $here/a450_bd.tcl} err]} { a4_fail "bd: $err" }
generate_target all [get_files a450.bd]
make_wrapper -files [get_files a450.bd] -top -import
add_files -fileset constrs_1 -norecurse $here/a450.xdc
set_property top a450_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { a4_fail "synth_1 [get_property STATUS [get_runs synth_1]]" }
puts "A450HBM_SYNTH_DONE"
open_run synth_1 -name synth_1

source $here/a450_cdc.tcl
source $here/a450_pblocks.tcl
if {[catch {
  lassign [a450_cdc "*/g_split.u/back/go_r_reg/C" "*/g_split.u/fast/dist/s_start_reg/C"] cc ca
  set npb [a450_pblocks {.*/g_split\.u/fast} "*/hbm/inst" \
           {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 17 18 19 20 21 22 23 24 25}]
  puts "A450HBM_PBLOCKS $npb"
} err]} { a4_fail "constraints: $err" }

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $bd routed.dcp]
report_route_status -file [file join $bd route_status.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -file [file join $bd timing_routed.rpt]
report_clock_interaction -file [file join $bd clock_interaction.rpt]
report_utilization -file [file join $bd util_routed.rpt]
report_utilization -hierarchical -file [file join $bd util_routed_hier.rpt]
report_utilization -pblocks [get_pblocks pb_a450_*] -file [file join $bd util_pblocks.rpt]
report_cdc -details -file [file join $bd cdc.rpt]
report_design_analysis -logic_level_distribution -file [file join $bd levels_routed.rpt]

set rs [report_route_status -return_string]
if {[regexp {routing errors[ .]*:\s*(\d+)} $rs -> nerr]} {
  puts "A450HBM_ROUTE routing_errors $nerr"
  if {$nerr != 0} { a4_fail "route status: $nerr routing error(s)" }
} else { a4_fail "route status: could not parse the routing error count" }
set pa [get_timing_paths -quiet -setup -max_paths 1 -to $ca]
set pc [get_timing_paths -quiet -setup -max_paths 1 -to $cc]
if {[llength $pa] != 1 || [llength $pc] != 1} { a4_fail "no setup path into aclk_a or clk_core" }
puts "A450HBM_WNS_ACLK [get_property SLACK $pa] LEVELS [get_property LOGIC_LEVELS $pa] START [get_property STARTPOINT_PIN $pa] END [get_property ENDPOINT_PIN $pa]"
puts "A450HBM_WNS_CORE [get_property SLACK $pc]"
puts "A450HBM_WNS [get_property SLACK [get_timing_paths -setup -max_paths 1]]"
puts "A450HBM_WHS [get_property SLACK [get_timing_paths -hold -max_paths 1]]"
set u [report_utilization -return_string]
proc used {u row} { if {[regexp "\\| $row +\\| +(\[0-9.\]+)" $u -> v]} { return $v }; return -1 }
puts "A450HBM_UTIL LUT [used $u {CLB LUTs}] FF [used $u {CLB Registers}] BRAM [used $u {Block RAM Tile}] DSP [used $u DSPs]"
puts "A450HBM_DONE"
```

`hw/jc/a450/run_a450.sh` (fresh root under `/mnt/storage/fk33_builds/`, refuses on a second Vivado or on too little memory, `git archive HEAD` so the run is the commit, `MemoryHigh 24G` and a swap kill at 8 GiB, verdict from the nonce-gated log):

```bash
#!/usr/bin/env bash
# hw/jc/a450/run_a450.sh -- run the a450 A+HBM timing design (build_a450.tcl) once, capped.
#
#   run_a450.sh [--dry-run] <root>
#
# <root> must be a fresh directory under /mnt/storage/fk33_builds/ (never /tmp).  The
# TRACKED tree at HEAD is copied to <root>/src (git archive), so the run is reproducible
# from the commit.  Refuses if another Vivado runs (by /proc/PID/exe, never by command
# line) or if MemAvailable is below the cap plus 2 GiB.  Vivado runs under
# hw/jc/loader/run_capped.sh: MemoryHigh 24G, killed if its swap passes 8 GiB.
# The verdict is read from Vivado's own log: ^A450HBM_DONE after this run's nonce, then
# the A450HBM_WNS_ACLK value.  Prints A450RUN_PASS <wns>, A450RUN_TIMING_FAIL <wns> or
# A450RUN_FAIL <reason>.  No hardware access of any kind.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
ROOT=${1:-}
fail() { echo "A450RUN_FAIL $1"; exit 1; }
[ -n "$ROOT" ] || fail "usage: $0 [--dry-run] <root>"
case "$ROOT" in /mnt/storage/fk33_builds/*) ;; *) fail "root $ROOT is not under /mnt/storage/fk33_builds/" ;; esac
if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then fail "root $ROOT exists and is not empty"; fi
MEM_HIGH=24G
SWAP_KILL=8589934592
NONCE="a450hbm_$(date +%s)_$$"
MEMAVAIL=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo)
echo "A450RUN_BUDGET MemAvailable=$MEMAVAIL cap=$MEM_HIGH swap_kill=$SWAP_KILL nonce=$NONCE"
VIVADO_BIN=$(command -v vivado 2>/dev/null || true)
if [ "$DRY" = 1 ]; then
  echo "+ git -C $REPO archive HEAD | tar -x -C $ROOT/src"
  echo "+ bash $REPO/hw/jc/loader/run_capped.sh $NONCE $MEM_HIGH $SWAP_KILL $ROOT ${VIVADO_BIN:-vivado} -mode batch -nojournal -log $ROOT/build.log -source $ROOT/src/hw/jc/a450/build_a450.tcl -tclargs $ROOT/src $ROOT/proj -nonce $NONCE"
  echo "A450RUN_DRY"
  exit 0
fi
[ -n "$VIVADO_BIN" ] || fail "vivado is not on PATH (source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh)"
[ "$MEMAVAIL" -ge $(( $(numfmt --from=iec $MEM_HIGH) + 2147483648 )) ] \
  || fail "MemAvailable $MEMAVAIL is below $MEM_HIGH + 2 GiB (stop llama-server first: Oren's call)"
for p in /proc/[0-9]*; do
  e=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$e" in */unwrapped/lnx64.o/vivado*) fail "another Vivado is running (${p#/proc/}): one per box" ;; esac
done
mkdir -p "$ROOT/src" || fail "mkdir $ROOT/src"
git -C "$REPO" archive HEAD | tar -x -C "$ROOT/src" || fail "git archive"
bash "$REPO/hw/jc/loader/run_capped.sh" "$NONCE" "$MEM_HIGH" "$SWAP_KILL" "$ROOT" \
  "$VIVADO_BIN" -mode batch -nojournal -log "$ROOT/build.log" \
  -source "$ROOT/src/hw/jc/a450/build_a450.tcl" -tclargs "$ROOT/src" "$ROOT/proj" -nonce "$NONCE"
NL=$(grep -nE "^A450HBM_NONCE ${NONCE}\$" "$ROOT/build.log" | head -1 | cut -d: -f1)
DL=$(grep -nE '^A450HBM_DONE' "$ROOT/build.log" | tail -1 | cut -d: -f1)
if [ -z "$NL" ] || [ -z "$DL" ] || [ "$DL" -le "$NL" ]; then
  R=$(grep -E '^A450HBM_FAIL' "$ROOT/build.log" | tail -1)
  fail "${R:-no A450HBM_DONE after the nonce of this run (see $ROOT/build.log and the swap guard log)}"
fi
W=$(grep -E '^A450HBM_WNS_ACLK ' "$ROOT/build.log" | tail -1 | awk '{print $2}')
if awk -v w="$W" 'BEGIN { exit !(w >= 0) }'; then echo "A450RUN_PASS $W"; else echo "A450RUN_TIMING_FAIL $W"; fi
```

Run: `chmod +x hw/jc/a450/run_a450.sh && python3 -m pytest hw/jc/a450/test_a450.py -q`
Expected: `7 passed`.

- [ ] **Step 4: Commit (the run archives HEAD, so it must be committed first)**

```bash
git add rtl/a450_stub_seq.vhd hw/jc/a450/gen_a450_hbm_top.py hw/jc/a450/a450_hbm_top.vhd \
        hw/jc/a450/a450_bd.tcl hw/jc/a450/a450.xdc hw/jc/a450/a450_cdc.tcl \
        hw/jc/a450/a450_pblocks.tcl hw/jc/a450/build_a450.tcl hw/jc/a450/run_a450.sh \
        hw/jc/a450/test_a450.py
git commit -m "a450 Task 7: A+HBM 450 MHz timing design, tile pblocks over their HBM ports, capped run script"
```

- [ ] **Step 5: Add the `a450_afast` rating row**

Save as `/mnt/storage/fk33_builds/scratch/a450_add_afast_row.py`, run from the repo root:

```python
import json
B = "hw/targets/blocks.json"
b = json.load(open(B))
b["a450_afast"] = {
    "top": "mv_afast", "clocks": {"clk": "*"}, "extra_files": [], "levers": [],
    "generics": {"ADDR_W": "40", "AXI_DW": "256", "BLK": "32", "FIFO_DEPTH": "512",
                 "G": "6", "MAXB": "16", "MAXCOLS": "17408", "MAXOUT": "16",
                 "NPORTS_S": "3", "NPORTS_W": "24", "ROWS_IF": "48", "XD": "32"},
    "target_ns": 2.222, "tier": "anchor"}
with open(B, "w") as f:
    json.dump(b, f, indent=2, sort_keys=True)
    f.write("\n")
print("RATE_ROW_ADDED a450_afast")
```

Run: `python3 /mnt/storage/fk33_builds/scratch/a450_add_afast_row.py && python3 tools/rate/rate.py status | grep -E '^RATESTATUS vu35p_jc_2l85 a450_afast '`
Expected: `RATE_ROW_ADDED a450_afast`, then `RATESTATUS vu35p_jc_2l85 a450_afast - UNRATED`.

- [ ] **Step 6: Rate the fast half out of context (precursor, no HBM)**

Budget (state it): `free -g`; this job's ESTIMATE peak is 16 to 20 GB (it has `a_engine`'s DSP count, and `a_engine` MEASURED 16.66 GB at its 16G cap with 2.4 GB swap, so that cap was reached); left after it must be at least 4 GB. `llama-server` stopped (Oren's call); no other Vivado (the `/proc/PID/exe` loop of Task 3 Step 2).

Run: `python3 tools/rate/rate.py run a450_afast --device vu35p_jc_2l85 --model QWEN38_27B --mem 20G 2>&1 | tee /mnt/storage/fk33_builds/scratch/a450_afast_rate.log`
Expected: `^RATE_RECORD a450_afast achieved`. Then read `hw/targets/ratings/vu35p_jc_2l85/a450_afast.QWEN38_27B.json`: report `route.wns`, `route.unrouted`, `util.DSP` (ESTIMATE 1,584 = 24 x 66) and `mem.peak` (if it equals the cap, say the run was capped). This step is not the gate: an OOC block has no HBM sites to sit against and no pblocks. A negative WNS here, with its `start`/`end`, still goes into the commit message: it names the path the gate run will meet.

- [ ] **Step 7: Commit the rating**

```bash
git add hw/targets/blocks.json hw/targets/ratings/vu35p_jc_2l85/a450_afast.QWEN38_27B.json
git commit -m "a450 Task 7: mv_afast rated out of context on xcvu35p -2L at 2.222 ns (precursor to the HBM gate)"
```

- [ ] **Step 8: Run the A+HBM design, routed (the gate)**

Budget (state it): `free -g`; ESTIMATE peak 20 to 24 GB, capped at `MemoryHigh 24G`, killed if its swap passes 8 GiB; `run_a450.sh` itself refuses below 26 GiB available. `llama-server` stopped. One Vivado on the box.

```bash
bash hw/jc/a450/run_a450.sh --dry-run /mnt/storage/fk33_builds/a450_hbm_r1
bash hw/jc/a450/run_a450.sh /mnt/storage/fk33_builds/a450_hbm_r1 2>&1 | tee /mnt/storage/fk33_builds/a450_hbm_r1.out
grep -E '^A450RUN_(PASS|TIMING_FAIL|FAIL)' /mnt/storage/fk33_builds/a450_hbm_r1.out
grep -E '^A450HBM_(PBLOCKS|ROUTE|WNS_ACLK|WNS_CORE|WNS|WHS|UTIL)' /mnt/storage/fk33_builds/a450_hbm_r1/build.log
grep -E '^A450CDC' /mnt/storage/fk33_builds/a450_hbm_r1/build.log
```
Expected: dry run prints `A450RUN_DRY`; the run prints `A450RUN_PASS <wns>`; the log shows `A450HBM_PBLOCKS` with a count of at least 2, `A450HBM_ROUTE routing_errors 0`, `A450HBM_WNS_ACLK` at or above 0, `A450HBM_WNS_CORE` at or above 0, `A450HBM_WHS` at or above 0. The gate is all of: `A450RUN_PASS`, `WNS_CORE >= 0`, `WHS >= 0`. `report_cdc` output is in `/mnt/storage/fk33_builds/a450_hbm_r1/proj/cdc.rpt`: every crossing must be `mv_tsync`, the async FIFO inside `mv_rcross`, `act_mem_dp`'s two-clock RAM, or the quasi-static job parameters (`j_*`, `w_base`, `s_base`, beats) that `a450_cdc` bounds; list any other in the task report.

If the gate fails: copy `timing_routed.rpt` and `util_pblocks.rpt` into `hw/jc/a450/results/a450_hbm_r1/`, record the worst path (`A450HBM_WNS_ACLK ... START ... END ...`), and stop. A fix is a new task with its own bench rerun (Task 6 Step 5) and a new run root; never reuse a root.

- [ ] **Step 9: Record and commit the result**

```bash
mkdir -p hw/jc/a450/results/a450_hbm_r1
cp /mnt/storage/fk33_builds/a450_hbm_r1/build.log /mnt/storage/fk33_builds/a450_hbm_r1/proj/timing_routed.rpt \
   /mnt/storage/fk33_builds/a450_hbm_r1/proj/util_routed.rpt /mnt/storage/fk33_builds/a450_hbm_r1/proj/util_pblocks.rpt \
   /mnt/storage/fk33_builds/a450_hbm_r1/proj/clock_interaction.rpt /mnt/storage/fk33_builds/a450_hbm_r1/proj/cdc.rpt \
   hw/jc/a450/results/a450_hbm_r1/
git add hw/jc/a450/results/a450_hbm_r1/build.log hw/jc/a450/results/a450_hbm_r1/timing_routed.rpt \
        hw/jc/a450/results/a450_hbm_r1/util_routed.rpt hw/jc/a450/results/a450_hbm_r1/util_pblocks.rpt \
        hw/jc/a450/results/a450_hbm_r1/clock_interaction.rpt hw/jc/a450/results/a450_hbm_r1/cdc.rpt
git commit -m "a450 Task 7: A+HBM routed at 450 MHz on aclk_a, WNS <value> ns (spec 3.2 gate 2)"
```
Replace `<value>` with the `A450HBM_WNS_ACLK` number from the log before committing.

---
### Task 8: Card integration, split off; silicon gate 1

Steps 1 to 8 are code and simulation a subagent may do (GHDL, pytest, generators; no Vivado, no hardware). Step 9 (the card build) needs Oren's go and runs in the main session. Steps 10 to 13 are silicon: **main session only, never a subagent.**

**Files:**
- Modify: `rtl/matvec_int4_desc_axi.vhd`
- Modify: `sim/tb_matvec_fk33_desc.vhd`; Create: `sim/tb_matvec_fk33_desc_tiled.vhd`
- Modify: `sim/regress.sh` (the `tb_matvec_fk33_desc_tiled` row)
- Modify: `hw/fk33/gen_fk33_engine.py`, regenerate `hw/fk33/rtl/fk33_engine.vhd`
- Modify: `hw/jc/card/gen_jc_card.py`, regenerate `hw/jc/card/jc_card_bd.tcl`
- Modify: `hw/jc/card/build_card.tcl`, `hw/jc/card/run_card.sh`
- Modify (tests): `hw/jc/card/test_gen_jc_card.py`, `hw/jc/card/test_run_card.py`
- Create (results): `hw/jc/card/results/jccard_a450s0_<YYYY-MM-DD>/`, `docs/debugging/<YYYY-MM-DD>_a450-silicon.md`

**Interfaces:**
- Consumes: `mv4i_tiled` (Task 6: ports, `dbg_rtile`, `dbg_words`); `a450_cdc` (Task 7).
- Produces:
  - `matvec_int4_desc_axi` generics `A_TILED : boolean := false` and `A_CLK_SPLIT : boolean := false` (after `FAST_POP`). With `A_TILED` false the design is today's, line for line. With true, `mv4i_tiled` replaces `matvec_int4` (as a component, so hand-written closures that never set `A_TILED` still analyse without the tiled files), `BEATS` advances by `dbg_words` per row-tile (the same total as today), `STARVED` reads 0, `CB_STYLE` and `FAST_POP` are not read.
  - `fk33_engine` generics `A_TILED`, `A_CLK_SPLIT`, forwarded; placed above the `-- LEVER AIDLE` block so `hw/fk33/results/card_build20_2026-09-24/build12_levers_off.patch` still applies.
  - `gen_jc_card.py`: `A_TILED_ENV = "JC_A_TILED"`, `A_SPLIT_ENV = "JC_A_CLK_SPLIT"`, `a_tiled(env)`, `a_split(env)` (each "0" or "1"; split without tiled exits), `ACLK_A = "clk_wiz_a/clk_out1"`, `ACLK_A_RSTN = "aclk_reset/peripheral_aresetn"`, `ACLK_A_MHZ = 450`; `render_tcl(P, mhz, env)`, `clock_lines(mhz, env)`, `hbm_lines(mhz, env)` take the environment. Both names are stamped generator inputs.
  - `build_card.tcl` prints `^JCCARD_A450_SPLIT (on|off)`; `run_card.sh` prints `^JCCARD_A_ENV JC_A_TILED=<v> JC_A_CLK_SPLIT=<v>` and records both in `PROVENANCE.txt`.

- [ ] **Step 1: Write the generator and build-script tests**

Append to `hw/jc/card/test_gen_jc_card.py`:

```diff
diff --git a/hw/jc/card/test_gen_jc_card.py b/hw/jc/card/test_gen_jc_card.py
index d53985af..1c9f3044 100644
--- a/hw/jc/card/test_gen_jc_card.py
+++ b/hw/jc/card/test_gen_jc_card.py
@@ -627,3 +627,55 @@ def test_gtg_mmcm_has_a_site_and_a_dedicated_route():
                      r"\{NAME =~ \*gtgclk/\*u_mmcm\}\]$", xdc, re.M)
     assert re.search(r"^set_property CLOCK_DEDICATED_ROUTE BACKBONE \[get_nets -of_objects \[get_pins -hier "
                      r"-filter \{NAME =~ \*gtgclk/\*u_mmcm/CLKIN1\}\]\]$", xdc, re.M)
+
+
+# ---- A_TILED / A_CLK_SPLIT (a450 plan, Tasks 8 and 9) ---------------------------------
+_SPLIT = {"JC_A_TILED": "1", "JC_A_CLK_SPLIT": "1"}
+
+
+def _render(env):
+    return "\n".join(_code_lines(G.render_tcl(P, G.CLK_CORE_DEFAULT, env)))
+
+
+def test_a_flags_default_off_and_refusals():
+    assert not G.a_tiled({}) and not G.a_split({})
+    for bad in ("2", "yes", "true"):
+        with pytest.raises(SystemExit):
+            G.a_tiled({"JC_A_TILED": bad})
+    with pytest.raises(SystemExit):
+        G.a_split({"JC_A_CLK_SPLIT": "1"})         # split without tiled
+    names = {n for _, n, _ in G.stamp_inputs({})}
+    assert {"JC_A_TILED", "JC_A_CLK_SPLIT"} <= names
+
+
+def test_tiled_split_off_renders_today_s_clocking():
+    t = _render({"JC_A_TILED": "1"})
+    assert "clk_wiz_a" not in t and "axi_clock_converter" not in t
+    assert re.search(r"CONFIG\.A_TILED \{true\}", t)
+    assert re.search(r"CONFIG\.A_CLK_SPLIT \{false\}", t)
+
+
+def test_split_on_puts_hbm_and_engine_ports_on_aclk_a():
+    t = _render(_SPLIT)
+    assert "clk_wiz_a" in t and "aclk_reset" in t
+    assert "CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {450.000}" in t
+    assert "CONFIG.USER_AXI_INPUT_CLK_FREQ {450}" in t
+    assert "CONFIG.USER_AXI_INPUT_CLK1_FREQ {450}" in t
+    assert re.search(r"CONFIG\.A_CLK_SPLIT \{true\}", t)
+    nets = _nets(t)
+    hbm_clk = _net_of(nets, "hbm/AXI_00_ACLK")
+    assert G.ACLK_A in hbm_clk, "SAXI_00 is not on aclk_a"
+    for s in list(range(1, 16)) + list(range(17, 32)):
+        assert G.ACLK_A in _net_of(nets, "hbm/AXI_%02d_ACLK" % s), s
+    assert "%s/hbm_aclk" % P.ENG_CELL in _net_of(nets, G.ACLK_A)
+
+
+def test_split_on_crosses_read_write_masters_with_converters():
+    t = _render(_SPLIT)
+    n = len(re.findall(r"create_bd_cell[^\n]*axi_clock_converter", t))
+    assert n == 3, "loader + two grant masters need a converter each, got %d" % n
+    assert re.search(r"CONFIG\.NUM_CLKS \{2\}", t), "SAXI_16 smartconnect is not two-clock"
+
+
+def test_split_off_default_render_is_unchanged_by_the_flags():
+    assert _render({}) == _render({"JC_A_TILED": "0", "JC_A_CLK_SPLIT": "0"})
```

Append to `hw/jc/card/test_run_card.py`:

```diff
diff --git a/hw/jc/card/test_run_card.py b/hw/jc/card/test_run_card.py
index ecc7448b..16c3ea18 100644
--- a/hw/jc/card/test_run_card.py
+++ b/hw/jc/card/test_run_card.py
@@ -551,3 +551,32 @@ def test_build_card_congestion_strategy_directives():
                  "route_design -directive AggressiveExplore"):
         assert line in t, line
     assert re.search(r"if \{\$impl eq \"congestion\" && \$post_wns < 0\} \{\s*phys_opt_design -directive AggressiveExplore", t)
+
+
+def test_build_card_lists_the_tiled_a_sources_and_its_cdc():
+    """a450 plan Task 8: every file of the tiled A closure is in ENG_SRCS (else the
+    A_TILED=1 elaboration finds no mv4i_tiled), and the split-on CDC is sourced."""
+    with open(os.path.join(HERE, "build_card.tcl")) as f:
+        t = f.read()
+    m = re.search(r"^set ENG_SRCS \{(.*?)^\}", t, re.M | re.S)
+    srcs = m.group(1).split()
+    want = ["rtl/mv_lfifo.vhd", "rtl/mv_tile.vhd", "rtl/mv_xbcast.vhd",
+            "rtl/act_mem_dp.vhd", "rtl/mv_dist.vhd", "rtl/mv_rlink.vhd",
+            "rtl/mv_rchain.vhd", "rtl/mv_rcross.vhd", "rtl/mv_tsync.vhd",
+            "rtl/mv_afast.vhd", "rtl/mv_back.vhd", "rtl/mv4i_tcore.vhd",
+            "rtl/mv4i_tiled.vhd"]
+    for f in want:
+        assert f in srcs, f
+    assert srcs.index("rtl/mv4i_tiled.vhd") < srcs.index("rtl/matvec_int4_desc_axi.vhd")
+    assert "async_fifo.vhd" in t
+    assert re.search(r"^\s*source .*a450_cdc\.tcl", t, re.M)
+    assert "JCCARD_A450_SPLIT" in t
+
+
+def test_dry_run_echoes_the_a450_generator_inputs(tmp_path):
+    r = subprocess.run(["bash", RUN_CARD, "--dry-run", "--allow-scratch-root", str(tmp_path / "r")],
+                       cwd=REPO, capture_output=True, text=True,
+                       env=dict(os.environ, JC_A_TILED="1", JC_A_CLK_SPLIT="1"))
+    assert re.search(r"^JCCARD_A_ENV JC_A_TILED=1 JC_A_CLK_SPLIT=1$", r.stdout, re.M), r.stdout
+    t = _run_card_text()
+    assert "jc_a_tiled=" in t and "jc_a_clk_split=" in t
```

Run: `python3 -m pytest hw/jc/card/test_gen_jc_card.py hw/jc/card/test_run_card.py -q`
Expected: FAIL: the new tests error with `AttributeError: module 'gen_jc_card' has no attribute 'a_tiled'` and the `ENG_SRCS`, `JCCARD_A_ENV` assertions fail; every pre-existing test passes.

- [ ] **Step 2: Wire the tiled A into the descriptor plane**

`rtl/matvec_int4_desc_axi.vhd` (line 2 is not a GENERATED marker; this file is hand-written):

```diff
diff --git a/rtl/matvec_int4_desc_axi.vhd b/rtl/matvec_int4_desc_axi.vhd
index 6481c197..a8264dad 100644
--- a/rtl/matvec_int4_desc_axi.vhd
+++ b/rtl/matvec_int4_desc_axi.vhd
@@ -217,6 +217,21 @@ entity matvec_int4_desc_axi is
     -- (docs/2026-09-20_d-side-vector-traffic.md section 4.1).  true removes
     -- the bubble.  Values and their order are unchanged either way.
     FAST_POP    : boolean := false;
+    -- THE a450 SUBSYSTEM A (docs/superpowers/specs/2026-11-12-a450-per-port-tiles-
+    -- design.md).  false (the default) builds rtl/matvec_int4.vhd, the design on the
+    -- card.  true builds rtl/mv4i_tiled.vhd in its place: the same values bit for bit
+    -- (sim/tb_mv4i_tiled.vhd), the same ports, every register here unchanged, except
+    -- that STARVED (0x3C) reads 0 (the tiled array has no single weight-word accept to
+    -- watch) and BEATS (0x38) grows by nb per row-tile instead of by 1 per word: the
+    -- same tiles * nb at done.  The per-port UTIL counters are unaffected.
+    -- Under A_TILED, CB_STYLE is not read (every tile decodes through its own per-lane
+    -- LUTRAM) and the A ports always run at one beat per cycle; FAST_POP still sets this
+    -- file's own descriptor read master.
+    A_TILED     : boolean := false;
+    -- A_TILED only.  false: the tiles run on s_axi_aclk; m_aclk must then carry the
+    -- same clock (the Jungle Cat card ties hbm_aclk to clk_core).  true: the tiles and
+    -- the A masters run on m_aclk (aclk_a, 450 MHz).
+    A_CLK_SPLIT : boolean := false;
     C_S_AXI_DATA_WIDTH : integer := 32;
     C_S_AXI_ADDR_WIDTH : integer := 8
   );
@@ -611,6 +626,58 @@ architecture rtl of matvec_int4_desc_axi is
   signal base_bad  : std_logic;
   signal base_code : std_logic_vector(3 downto 0);
   signal base_info : std_logic_vector(15 downto 0);
+  -- rtl/mv4i_tiled.vhd as a COMPONENT, not `entity work.`: an entity reference makes
+  -- every analysis of this file need mv4i_tiled's twelve files first, and the scripts
+  -- that list this file's closure by hand (sim/mutate_mv4i_desc*.sh,
+  -- tools/verify_mv4i_desc.py, the OOC Tcl) would all break.  A component is bound at
+  -- elaboration, and only when A_TILED builds the branch.
+  component mv4i_tiled is
+    generic(
+      BLK, ROWS_IF, NPORTS_W, NPORTS_S, AXI_DW, ADDR_W, MAXCOLS, MAXROWS_BFP,
+      FIFO_DEPTH, MAXB, MAXOUT : positive;
+      A_CLK_SPLIT : boolean
+    );
+    port(
+      clk, rst  : in  std_logic;
+      aclk      : in  std_logic;
+      start     : in  std_logic;
+      n_rows, n_cols, out_shift, w_exp, x_exp : in std_logic_vector(31 downto 0);
+      out_mode  : in  std_logic_vector(1 downto 0);
+      w_base    : in  std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
+      w_beats   : in  std_logic_vector(31 downto 0);
+      s_base    : in  std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
+      s_beats   : in  std_logic_vector(31 downto 0);
+      cb_we     : in  std_logic;
+      cb_addr   : in  std_logic_vector(3 downto 0);
+      cb_data   : in  std_logic_vector(7 downto 0);
+      x_we      : in  std_logic;
+      x_waddr   : in  std_logic_vector(15 downto 0);
+      x_wdata   : in  std_logic_vector(15 downto 0);
+      m_arvalid : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
+      m_arready : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
+      m_araddr  : out std_logic_vector((NPORTS_W+NPORTS_S)*ADDR_W-1 downto 0);
+      m_arlen   : out std_logic_vector((NPORTS_W+NPORTS_S)*8-1 downto 0);
+      m_arsize  : out std_logic_vector((NPORTS_W+NPORTS_S)*3-1 downto 0);
+      m_arburst : out std_logic_vector((NPORTS_W+NPORTS_S)*2-1 downto 0);
+      m_rvalid  : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
+      m_rready  : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
+      m_rdata   : in  std_logic_vector((NPORTS_W+NPORTS_S)*AXI_DW-1 downto 0);
+      m_rlast   : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
+      y_we      : out std_logic;
+      y_addr    : out std_logic_vector(15 downto 0);
+      y_data    : out std_logic_vector(ROWS_IF*64-1 downto 0);
+      y_mask    : out std_logic_vector(ROWS_IF-1 downto 0);
+      y_exp     : out std_logic_vector(31 downto 0);
+      done      : out std_logic;
+      err       : out std_logic;
+      sat_event : out std_logic;
+      dbg_rtile : out std_logic;
+      dbg_words : out std_logic_vector(31 downto 0)
+    );
+  end component;
+  -- what BEATS adds per dbg_wbeat: 1 weight word from matvec_int4, nb from mv4i_tiled
+  signal dbg_wn : unsigned(31 downto 0);
+  signal dbg_words_t : std_logic_vector(31 downto 0);
 begin
   -- ------------------------------------------------------- generic contract
   assert ADDR_W >= 32 and ADDR_W <= 64
@@ -718,30 +785,61 @@ begin
   end process;
 
   -- ----------------------------------------------------------------- core
-  dut : entity work.matvec_int4
-    generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W,
-                NPORTS_S => NPORTS_S, AXI_DW => AXI_DW, ADDR_W => ADDR_W,
-                MAXCOLS => MAXCOLS, MAXROWS_BFP => MAXROWS_BFP,
-                FIFO_DEPTH => FIFO_DEPTH, MAXB => MAXB, MAXOUT => MAXOUT,
-                DUAL_CLK => DUAL_CLK, CB_STYLE => CB_STYLE,
-                FAST_POP => FAST_POP)
-    port map(clk => s_axi_aclk, rst => rst, aclk => m_aclk,
-             start => core_start,
-             n_rows => v_rows, n_cols => v_cols, out_shift => v_osh,
-             w_exp => v_wexp, x_exp => v_xexp, out_mode => v_mode,
-             w_base => w_base, w_beats => v_wbeats,
-             s_base => s_base, s_beats => v_sbeats,
-             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
-             x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
-             m_arvalid => m_arvalid, m_arready => m_arready,
-             m_araddr => m_araddr, m_arlen => m_arlen,
-             m_arsize => m_arsize, m_arburst => m_arburst,
-             m_rvalid => m_rvalid, m_rready => m_rready_i,
-             m_rdata => m_rdata, m_rlast => m_rlast,
-             y_we => y_we_i, y_addr => y_addr_i, y_data => y_data_i,
-             y_mask => y_mask_i, y_exp => v_yexp,
-             done => core_done, err => core_err, sat_event => core_sat,
-             dbg_wbeat => dbg_wbeat, dbg_wstarve => dbg_wstarve);
+  g_core : if not A_TILED generate
+    dbg_wn <= to_unsigned(1, 32);
+    dut : entity work.matvec_int4
+      generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W,
+                  NPORTS_S => NPORTS_S, AXI_DW => AXI_DW, ADDR_W => ADDR_W,
+                  MAXCOLS => MAXCOLS, MAXROWS_BFP => MAXROWS_BFP,
+                  FIFO_DEPTH => FIFO_DEPTH, MAXB => MAXB, MAXOUT => MAXOUT,
+                  DUAL_CLK => DUAL_CLK, CB_STYLE => CB_STYLE,
+                  FAST_POP => FAST_POP)
+      port map(clk => s_axi_aclk, rst => rst, aclk => m_aclk,
+               start => core_start,
+               n_rows => v_rows, n_cols => v_cols, out_shift => v_osh,
+               w_exp => v_wexp, x_exp => v_xexp, out_mode => v_mode,
+               w_base => w_base, w_beats => v_wbeats,
+               s_base => s_base, s_beats => v_sbeats,
+               cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
+               x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
+               m_arvalid => m_arvalid, m_arready => m_arready,
+               m_araddr => m_araddr, m_arlen => m_arlen,
+               m_arsize => m_arsize, m_arburst => m_arburst,
+               m_rvalid => m_rvalid, m_rready => m_rready_i,
+               m_rdata => m_rdata, m_rlast => m_rlast,
+               y_we => y_we_i, y_addr => y_addr_i, y_data => y_data_i,
+               y_mask => y_mask_i, y_exp => v_yexp,
+               done => core_done, err => core_err, sat_event => core_sat,
+               dbg_wbeat => dbg_wbeat, dbg_wstarve => dbg_wstarve);
+  end generate;
+
+  g_tiled : if A_TILED generate
+    dut : mv4i_tiled
+      generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W,
+                  NPORTS_S => NPORTS_S, AXI_DW => AXI_DW, ADDR_W => ADDR_W,
+                  MAXCOLS => MAXCOLS, MAXROWS_BFP => MAXROWS_BFP,
+                  FIFO_DEPTH => FIFO_DEPTH, MAXB => MAXB, MAXOUT => MAXOUT,
+                  A_CLK_SPLIT => A_CLK_SPLIT)
+      port map(clk => s_axi_aclk, rst => rst, aclk => m_aclk,
+               start => core_start,
+               n_rows => v_rows, n_cols => v_cols, out_shift => v_osh,
+               w_exp => v_wexp, x_exp => v_xexp, out_mode => v_mode,
+               w_base => w_base, w_beats => v_wbeats,
+               s_base => s_base, s_beats => v_sbeats,
+               cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
+               x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
+               m_arvalid => m_arvalid, m_arready => m_arready,
+               m_araddr => m_araddr, m_arlen => m_arlen,
+               m_arsize => m_arsize, m_arburst => m_arburst,
+               m_rvalid => m_rvalid, m_rready => m_rready_i,
+               m_rdata => m_rdata, m_rlast => m_rlast,
+               y_we => y_we_i, y_addr => y_addr_i, y_data => y_data_i,
+               y_mask => y_mask_i, y_exp => v_yexp,
+               done => core_done, err => core_err, sat_event => core_sat,
+               dbg_rtile => dbg_wbeat, dbg_words => dbg_words_t);
+    dbg_wn      <= unsigned(dbg_words_t);
+    dbg_wstarve <= '0';
+  end generate;
 
   y_we    <= y_we_i;
   y_addr  <= y_addr_i;
@@ -1052,7 +1150,7 @@ begin
 
           when S_WAIT =>
             c_cycles <= c_cycles + 1;
-            if dbg_wbeat   = '1' then c_beats  <= c_beats + 1;  end if;
+            if dbg_wbeat   = '1' then c_beats  <= c_beats + dbg_wn; end if;
             if dbg_wstarve = '1' then c_starve <= c_starve + 1; end if;
             if core_err = '1' then
               err_code <= EC_CORE;
```

`sim/tb_matvec_fk33_desc.vhd`:

```diff
diff --git a/sim/tb_matvec_fk33_desc.vhd b/sim/tb_matvec_fk33_desc.vhd
index c882cd59..eb8428cf 100644
--- a/sim/tb_matvec_fk33_desc.vhd
+++ b/sim/tb_matvec_fk33_desc.vhd
@@ -162,7 +162,14 @@ entity tb_matvec_fk33_desc is
     -- this false on both and prints the marker itself only once BOTH have
     -- finished; otherwise one arm completing while the other hung would put
     -- the marker in the log and the row would pass on half a run.
-    MARK    : boolean := true
+    MARK    : boolean := true;
+    -- THE a450 SUBSYSTEM A, forwarded as matvec_int4_desc_axi's A_TILED / A_CLK_SPLIT.
+    -- Defaults false: every existing row of this architecture is unchanged.
+    -- sim/tb_matvec_fk33_desc_tiled.vhd sets both (with DUAL, so the tiles run on mclk):
+    -- the same 22 cases, the same element-exact comparison with ref/matvec_int4.c, the
+    -- same register and UTIL checks, through the tiled array.
+    TILED   : boolean := false;
+    SPLIT   : boolean := false
   );
   port(
     -- Unconnected when this entity is the simulation top, which is how
@@ -654,6 +661,7 @@ begin
                 DESC_MAXB => 16, WDOG_LIMIT => 4096,
                 USE_XEXP_PORT => XEXP_PORT,
                 DUAL_CLK => DUAL, CB_STYLE => CB_STYLE, FAST_POP => FASTP,
+                A_TILED => TILED, A_CLK_SPLIT => SPLIT,
                 C_S_AXI_ADDR_WIDTH => 8)
     port map(
       s_axi_aclk => clk, s_axi_aresetn => aresetn, m_aclk => mclk,
```

`sim/tb_matvec_fk33_desc_tiled.vhd`:

```vhdl
-- sim/tb_matvec_fk33_desc_tiled.vhd -- sim/tb_matvec_fk33_desc.vhd with the a450 tiled
-- subsystem A behind the descriptor plane (matvec_int4_desc_axi A_TILED = true,
-- A_CLK_SPLIT = true, the tiles and the A masters on mclk).  A thin wrapper, as
-- tb_matvec_fk33_desc_dual and _xexp are: regress keys a row by bench name and cannot run
-- one bench twice.  The whole 22-case matrix, the element-exact comparison against
-- ref/matvec_int4.c from the real .mv4i bytes, the register reads (BEATS = tiles * nb,
-- Y_EXP, the stale-done window) and the UTIL counters run through the tiled array.
-- The trace is mv_fk33_tr.txt, the same file the other three rows read.
entity tb_matvec_fk33_desc_tiled is
end entity;

architecture sim of tb_matvec_fk33_desc_tiled is
begin
  b : entity work.tb_matvec_fk33_desc
    generic map(TRACE => "mv_fk33_tr.txt", DUAL => true, TILED => true, SPLIT => true);
end architecture;
```

- [ ] **Step 3: Add the descriptor-plane row to the gate**

No gate may run from this tree while `sim/regress.sh` is edited. From the repo root:

```python
p = "sim/regress.sh"
t = open(p).read()
edits = [
 ('    sim:tb_matvec_fk33_desc_xexp) echo "--stop-time=200ms --stop-delta=1000000" ;;\n',
  '    sim:tb_matvec_fk33_desc_xexp) echo "--stop-time=200ms --stop-delta=1000000" ;;\n'
  '    # The a450 tiled A behind the same descriptor plane (plan 2026-11-12 Task 8).\n'
  '    sim:tb_matvec_fk33_desc_tiled) echo "--stop-time=200ms --stop-delta=1000000" ;;\n'),
 ('    sim:tb_matvec_fk33|sim:tb_matvec_fk33_desc|\\\n'
  '    sim:tb_matvec_fk33_desc_dual|sim:tb_matvec_fk33_desc_xexp)\n',
  '    sim:tb_matvec_fk33|sim:tb_matvec_fk33_desc|\\\n'
  '    sim:tb_matvec_fk33_desc_dual|sim:tb_matvec_fk33_desc_xexp|\\\n'
  '    sim:tb_matvec_fk33_desc_tiled)\n'),
 ('    sim:tb_matvec_fk33_desc|sim:tb_matvec_fk33_desc_dual|sim:tb_matvec_fk33_desc_xexp)\n'
  '                         echo \'every checked mutation is refused\' ;;\n',
  '    sim:tb_matvec_fk33_desc|sim:tb_matvec_fk33_desc_dual|sim:tb_matvec_fk33_desc_xexp|\\\n'
  '    sim:tb_matvec_fk33_desc_tiled)\n'
  '                         echo \'every checked mutation is refused\' ;;\n'),
]
for a, b in edits:
    assert t.count(a) == 1, a
    t = t.replace(a, b)
open(p, "w").write(t)
print("REGRESS_DESC_TILED_EDIT_OK")
```

Run: `python3 <that script> && bash -n sim/regress.sh && echo SYNTAX_OK`
Expected: `REGRESS_DESC_TILED_EDIT_OK`, `SYNTAX_OK`. (Task 6 already gave this row a 7,200 s timeout and put it in `SLOW_TBS`.)

- [ ] **Step 4: Run the four descriptor-plane rows**

Memory: 1.25 GB peak for the tiled row (MEASURED, `/usr/bin/time -v`); time: the tiled row took 43 min 58 s quiet (MEASURED 2026-11-12, 752 us simulated), so this step is about an hour.

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/a450_t8_desc bash sim/regress.sh --suite sim --only tb_matvec_fk33_desc --keep`
Expected: `PASS` for `sim:tb_matvec_fk33_desc`, `_dual`, `_xexp` and `_tiled`, and `OVERALL PASS 4`. The tiled row's log carries the same `shape sweep, FK33 arm (ROWS_IF=48, GRP=1): 10 legal shapes accepted, 38 one-off beat-count mutations refused` note as the others and ends on `every checked mutation is refused`. The tiled row needs more than the default 900 s (MEASURED: it timed out at 900 s in the gate, then passed in 44 min run directly with the same arguments, ending `23 cases run, 0 failures` and `UTIL counters: 27 ports match the bench's R-beat count`); Task 6 gave it 7,200 s. A `TIMEOUT` at 7,200 s is a finding about the bench's cost under load, not a pass: record the time and rerun on a quiet box, never drop the row.

- [ ] **Step 5: Engine generics, regenerate, check the levers patch**

`hw/fk33/gen_fk33_engine.py`:

```diff
diff --git a/hw/fk33/gen_fk33_engine.py b/hw/fk33/gen_fk33_engine.py
index 5cd5f205..4eb9fac3 100755
--- a/hw/fk33/gen_fk33_engine.py
+++ b/hw/fk33/gen_fk33_engine.py
@@ -332,6 +332,18 @@ entity fk33_engine is
     -- opt out on a host-driven build reads a port nothing drives.
     USE_XEXP_PORT : boolean := false;
 
+    -- THE a450 SUBSYSTEM A (docs/superpowers/specs/2026-11-12-a450-per-port-tiles-
+    -- design.md), forwarded to matvec_int4_desc_axi.  A_TILED false (the default) is
+    -- the array on the card today; true is rtl/mv4i_tiled.vhd, the same values bit
+    -- for bit.  A_CLK_SPLIT (A_TILED only): false runs the tiles on core_clk, and
+    -- the card must then drive hbm_aclk from the same clock (the Jungle Cat does);
+    -- true runs the tiles and all 28 masters on hbm_aclk (aclk_a).  Generics of THIS
+    -- entity for the reason FAST_POP gives below.  Declared ABOVE FAST_POP so that
+    -- FAST_POP stays the last generic: build12_levers_off.patch's hunk matches the
+    -- three lines after it.
+    A_TILED : boolean := false;
+    A_CLK_SPLIT : boolean := false;
+
     -- LEVER AIDLE, forwarded to matvec_int4_desc_axi -> matvec_int4 ->
     -- weight_streamer -> all {NLANE} read ports, and to this engine's own
     -- descriptor read master.
@@ -734,6 +746,8 @@ begin
       CHECK_JOB_INDEX => CHECK_JOB_INDEX,
       USE_XEXP_PORT => USE_XEXP_PORT,
       FAST_POP      => FAST_POP,
+      A_TILED       => A_TILED,
+      A_CLK_SPLIT   => A_CLK_SPLIT,
       DUAL_CLK      => true,
       C_S_AXI_DATA_WIDTH => 32,
       C_S_AXI_ADDR_WIDTH => 8
```

Run:
```bash
python3 hw/fk33/gen_fk33_engine.py && python3 hw/fk33/gen_fk33_engine.py --check
git apply --check hw/fk33/results/card_build20_2026-09-24/build12_levers_off.patch && echo PATCH_APPLIES
git diff --stat hw/fk33/rtl/fk33_engine.vhd
```
Expected: `GEN_FK33_ENGINE_CHECK: OK hw/fk33/rtl/fk33_engine.vhd (92032 bytes, 28 masters)`, `PATCH_APPLIES`, and `fk33_engine.vhd | 14 ++++` (the two generics and their map lines, nothing else; any other change means the generator read something from the environment: stop and read its GENSTAMP inputs).

- [ ] **Step 6: The card generator and the build scripts**

`hw/jc/card/gen_jc_card.py` (`JC_A_TILED`, `JC_A_CLK_SPLIT`; with split on: `clk_wiz_a` at 450 MHz from `clk_wiz_0/clk_out2`, `aclk_reset`, HBM `USER_AXI_INPUT_CLK*_FREQ` 450 and all 32 SAXI clocks on `aclk_a`, an `axi_clock_converter` for the loader and each grant master, the SAXI_16 smartconnect at `NUM_CLKS 2`, the engine's `hbm_aclk` on `aclk_a`; `CONFIG.A_TILED` and `CONFIG.A_CLK_SPLIT` set on the engine cell and read back):

```diff
diff --git a/hw/jc/card/gen_jc_card.py b/hw/jc/card/gen_jc_card.py
index d36a9ee8..f01fd5c5 100644
--- a/hw/jc/card/gen_jc_card.py
+++ b/hw/jc/card/gen_jc_card.py
@@ -138,9 +138,12 @@ def stamp_inputs(env=None):
     env = os.environ if env is None else env
     link_rate(env)
     link_refclk(env)
+    a_split(env)
     return [("env", CLK_CORE_ENV, env.get(CLK_CORE_ENV) or None),
             ("env", LINK_RATE_ENV, env.get(LINK_RATE_ENV) or None),
-            ("env", LINK_REFCLK_ENV, env.get(LINK_REFCLK_ENV) or None)]
+            ("env", LINK_REFCLK_ENV, env.get(LINK_REFCLK_ENV) or None),
+            ("env", A_TILED_ENV, env.get(A_TILED_ENV) or None),
+            ("env", A_SPLIT_ENV, env.get(A_SPLIT_ENV) or None)]
 
 
 def stamp_block(comment, env=None):
@@ -311,6 +314,40 @@ def link_refclk(env=None):
     return v
 
 
+# ---- the a450 subsystem A (plan 2026-11-12-a450-per-port-tiles, Tasks 8 and 9) -------
+# JC_A_TILED=1 builds rtl/mv4i_tiled.vhd behind the engine's descriptor plane (the same
+# values bit for bit).  JC_A_CLK_SPLIT=1 (needs JC_A_TILED=1) adds aclk_a, a second MMCM
+# at ACLK_A_MHZ on clk_out2, moves the engine's hbm_aclk and all 32 HBM AXI ports onto
+# it, and puts the four non-engine HBM masters (loader SAXI_00, hbm_sc SAXI_16, the B/C
+# grant SAXI_30/31) behind clock converters.  Both unset: the card as it is.
+A_TILED_ENV = "JC_A_TILED"
+A_SPLIT_ENV = "JC_A_CLK_SPLIT"
+ACLK_A = "clk_wiz_a/clk_out1"
+ACLK_A_RSTN = "aclk_reset/peripheral_aresetn"
+ACLK_A_MHZ = 450
+
+
+def _flag(env, name):
+    v = env.get(name) or "0"
+    if v not in ("0", "1"):
+        sys.exit("ABORT: %s=%r; it is 0 or 1" % (name, v))
+    return v == "1"
+
+
+def a_tiled(env=None):
+    env = os.environ if env is None else env
+    return _flag(env, A_TILED_ENV)
+
+
+def a_split(env=None):
+    env = os.environ if env is None else env
+    split = _flag(env, A_SPLIT_ENV)
+    if split and not a_tiled(env):
+        sys.exit("ABORT: %s=1 needs %s=1: only the tiled A has an aclk_a domain"
+                 % (A_SPLIT_ENV, A_TILED_ENV))
+    return split
+
+
 def aurora_core_ports():
     """[(name, dir, width or None)] of the Aurora core, from the committed wrapper's component
     (generated from the IP's own stub by hw/jc/link/gen_aurora_wrap.py)."""
@@ -505,7 +542,7 @@ def _c(a, b):
 
 
 # ---- board sections (no gen_pcieep needed; the test calls these directly) -------------
-def clock_lines(mhz):
+def clock_lines(mhz, env=None):
     L = [
         "",
         "# ---- clocks and resets (hw/jc/loader/jc_loader_bd.tcl's, clk_out3 = clk_core) ---",
@@ -543,10 +580,34 @@ def clock_lines(mhz):
         _c(CORE_CLK, "core_reset/slowest_sync_clk"),
         _c(APB_CLK, "apb_rst/slowest_sync_clk"),
     ]
+    if a_split(env):
+        L += [
+            "",
+            "# aclk_a (JC_A_CLK_SPLIT=1): its own MMCM on clk_out2.  One MMCM cannot make",
+            "# clk_core and %d MHz together (their lcm is above the VCO range)." % ACLK_A_MHZ,
+            "create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_a",
+            "set_property -dict [list CONFIG.PRIM_IN_FREQ.VALUE_SRC USER] [get_bd_cells clk_wiz_a]",
+            "set_property -dict [list CONFIG.PRIM_SOURCE {Global_buffer} CONFIG.PRIM_IN_FREQ {200.000} \\",
+            "  CONFIG.USE_RESET {false} \\",
+            "  CONFIG.CLKOUT1_USED {true} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {%.3f}] [get_bd_cells clk_wiz_a]"
+            % ACLK_A_MHZ,
+            "foreach {k v} {PRIM_SOURCE Global_buffer USE_RESET false CLKOUT1_REQUESTED_OUT_FREQ %.3f} {"
+            % ACLK_A_MHZ,
+            "  jcc_want clk_wiz_a $k $v",
+            "}",
+            _c(REF_CLK, "clk_wiz_a/clk_in1"),
+            "create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 aclk_reset",
+            _c("clk_wiz_a/locked", "aclk_reset/dcm_locked"),
+            _c("one/dout", "aclk_reset/ext_reset_in"),
+            _c(ACLK_A, "aclk_reset/slowest_sync_clk"),
+        ]
     return L
 
 
-def hbm_lines(mhz):
+def hbm_lines(mhz, env=None):
+    split = a_split(env)
+    amhz = ACLK_A_MHZ if split else mhz
+    aclk, arstn = (ACLK_A, ACLK_A_RSTN) if split else (CORE_CLK, CORE_RSTN)
     L = [
         "",
         "# ---- HBM: 2 stacks, 8 GB, all 32 SAXI on clk_core ---------------------------------",
@@ -556,8 +617,8 @@ def hbm_lines(mhz):
         "set_property -dict [list CONFIG.USER_HBM_REF_CLK_0 {200} CONFIG.USER_HBM_REF_CLK_1 {200}] [get_bd_cells hbm]",
         "# The AXI clock both stacks are told to expect: clk_core, the net every AXI_nn_ACLK",
         "# below is on.",
-        "set_property CONFIG.USER_AXI_INPUT_CLK_FREQ {%d} [get_bd_cells hbm]" % mhz,
-        "set_property CONFIG.USER_AXI_INPUT_CLK1_FREQ {%d} [get_bd_cells hbm]" % mhz,
+        "set_property CONFIG.USER_AXI_INPUT_CLK_FREQ {%d} [get_bd_cells hbm]" % amhz,
+        "set_property CONFIG.USER_AXI_INPUT_CLK1_FREQ {%d} [get_bd_cells hbm]" % amhz,
         "set_property -dict [list CONFIG.USER_SWITCH_ENABLE_00 {TRUE} CONFIG.USER_SWITCH_ENABLE_01 {TRUE}] [get_bd_cells hbm]",
         "set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK}] [get_bd_cells hbm]",
     ]
@@ -566,7 +627,7 @@ def hbm_lines(mhz):
         "set_property CONFIG.USER_APB_EN {false} [get_bd_cells hbm]",
         "foreach {k v} {USER_HBM_DENSITY 8GB USER_HBM_STACK 2 USER_HBM_REF_CLK_0 200",
         "               USER_HBM_REF_CLK_1 200 USER_AXI_INPUT_CLK_FREQ %d USER_AXI_INPUT_CLK1_FREQ %d"
-        % (mhz, mhz),
+        % (amhz, amhz),
         "               USER_SWITCH_ENABLE_00 TRUE USER_SWITCH_ENABLE_01 TRUE",
         "               USER_CLK_SEL_LIST0 AXI_00_ACLK USER_CLK_SEL_LIST1 AXI_16_ACLK USER_APB_EN false} {",
         "  jcc_want hbm $k $v",
@@ -580,15 +641,15 @@ def hbm_lines(mhz):
         _c(REF_CLK, "hbm/HBM_REF_CLK_1"),
         "# SAXI_00 (loader) and SAXI_16 (hbm_sc).  The other 30 ports' ACLK/ARESET_N are",
         "# connected where their masters are: the engine's 28 and the grant's 2, below.",
-        _c(CORE_CLK, "hbm/AXI_00_ACLK"),
-        _c(CORE_RSTN, "hbm/AXI_00_ARESET_N"),
-        _c(CORE_CLK, "hbm/AXI_16_ACLK"),
-        _c(CORE_RSTN, "hbm/AXI_16_ARESET_N"),
+        _c(aclk, "hbm/AXI_00_ACLK"),
+        _c(arstn, "hbm/AXI_00_ARESET_N"),
+        _c(aclk, "hbm/AXI_16_ACLK"),
+        _c(arstn, "hbm/AXI_16_ARESET_N"),
     ]
     return L
 
 
-def loader_lines():
+def loader_lines(env=None):
     L = [
         "",
         "# ---- the USER4 loader (jc_loader_top, unchanged; hw/jc/loader/jc_loader_bd.tcl) ---",
@@ -614,16 +675,34 @@ def loader_lines():
         _c("hbm/DRAM_1_STAT_CATTRIP", "%s/hbm_cattrip1" % LOADER_CELL),
         _c("hbm/apb_complete_0", "%s/hbm_ready0" % LOADER_CELL),
         _c("hbm/apb_complete_1", "%s/hbm_ready1" % LOADER_CELL),
-        "connect_bd_intf_net [get_bd_intf_pins %s/%s] [get_bd_intf_pins hbm/SAXI_00]"
-        % (LOADER_CELL, LOADER_INTF),
     ]
+    if a_split(env):
+        L += [
+            "# JC_A_CLK_SPLIT: SAXI_00 is on aclk_a, the loader on clk_core.  A converter with",
+            "# the loader's own inferred protocol (read, then set, then read back).",
+            "create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 ld_cdc",
+            "set _lp [get_property CONFIG.PROTOCOL [get_bd_intf_pins %s/%s]]" % (LOADER_CELL, LOADER_INTF),
+            "set_property CONFIG.PROTOCOL $_lp [get_bd_cells ld_cdc]",
+            "jcc_want ld_cdc PROTOCOL $_lp",
+            "connect_bd_intf_net [get_bd_intf_pins %s/%s] [get_bd_intf_pins ld_cdc/S_AXI]"
+            % (LOADER_CELL, LOADER_INTF),
+            "connect_bd_intf_net [get_bd_intf_pins ld_cdc/M_AXI] [get_bd_intf_pins hbm/SAXI_00]",
+            _c(CORE_CLK, "ld_cdc/s_axi_aclk"),
+            _c(CORE_RSTN, "ld_cdc/s_axi_aresetn"),
+            _c(ACLK_A, "ld_cdc/m_axi_aclk"),
+            _c(ACLK_A_RSTN, "ld_cdc/m_axi_aresetn"),
+        ]
+    else:
+        L.append("connect_bd_intf_net [get_bd_intf_pins %s/%s] [get_bd_intf_pins hbm/SAXI_00]"
+                 % (LOADER_CELL, LOADER_INTF))
     for pin, port in LOADER_PINS:
         L.append("create_bd_port -dir O %s" % port)
         L.append("connect_bd_net [get_bd_pins %s/%s] [get_bd_ports %s]" % (LOADER_CELL, pin, port))
     return L
 
 
-def jtag_hbm_lines():
+def jtag_hbm_lines(env=None):
+    split = a_split(env)
     return [
         "",
         "# ---- SAXI_16: jtag_hbm (spot checks) and the ctl core's read master ---------------",
@@ -634,15 +713,19 @@ def jtag_hbm_lines():
         "jcc_want jtag_hbm M_AXI_ADDR_WIDTH 64",
         "create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 %s" % HBM_SC_CELL,
         "# S00 jtag_hbm, S01 the ctl read master, S02 tok/m_hbm (the embedding gather)",
-        "set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] [get_bd_cells %s]"
-        % HBM_SC_CELL,
+        "set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {%d}] [get_bd_cells %s]"
+        % (2 if split else 1, HBM_SC_CELL),
+        "jcc_want %s NUM_CLKS %d" % (HBM_SC_CELL, 2 if split else 1),
         "connect_bd_intf_net [get_bd_intf_pins jtag_hbm/M_AXI] [get_bd_intf_pins %s/S00_AXI]" % HBM_SC_CELL,
         "connect_bd_intf_net [get_bd_intf_pins %s/M00_AXI] [get_bd_intf_pins hbm/SAXI_16]" % HBM_SC_CELL,
         _c(CORE_CLK, "jtag_hbm/aclk"),
         _c(CORE_RSTN, "jtag_hbm/aresetn"),
         _c(CORE_CLK, "%s/aclk" % HBM_SC_CELL),
         _c(CORE_RSTN, "%s/aresetn" % HBM_SC_CELL),
-    ]
+    ] + ([
+        "# JC_A_CLK_SPLIT: M00 (to SAXI_16) is on aclk_a; the smartconnect crosses.",
+        _c(ACLK_A, "%s/aclk1" % HBM_SC_CELL),
+    ] if split else [])
 
 
 def ctl_lines():
@@ -711,7 +794,9 @@ def ctl_lines():
 
 
 # ---- sections built from gen_pcieep.py --------------------------------------------------
-def eng_lines(P):
+def eng_lines(P, env=None):
+    tiled, split = a_tiled(env), a_split(env)
+    aclk, arstn = (ACLK_A, ACLK_A_RSTN) if split else (CORE_CLK, CORE_RSTN)
     L = P._eng_cell_lines()
     L += [
         "# BUILD 20's LEVERS, READ BACK, NOT SET.  build12_levers_off.patch sets",
@@ -726,13 +811,19 @@ def eng_lines(P):
         "}",
         "puts \"JCCARD_LEVER %s FAST_POP $_fp\"" % P.ENG_CELL,
         "",
+        "# THE a450 SUBSYSTEM A (JC_A_TILED / JC_A_CLK_SPLIT), set and read back.",
+        "set_property -dict [list CONFIG.A_TILED {%s} CONFIG.A_CLK_SPLIT {%s}] [get_bd_cells %s]"
+        % (str(tiled).lower(), str(split).lower(), P.ENG_CELL),
+        "jcc_want %s A_TILED %s" % (P.ENG_CELL, str(tiled).lower()),
+        "jcc_want %s A_CLK_SPLIT %s" % (P.ENG_CELL, str(split).lower()),
+        "",
 
         "# ON THIS BOARD core_clk AND hbm_aclk ARE THE SAME NET, clk_core.  The engine's",
         "# internal crossing (axi_rd_port's async FIFO) is still present and is crossed",
         "# between equal clocks; no AXI clock converter sits between the engine and HBM.",
         _c(CORE_CLK, "%s/core_clk" % P.ENG_CELL),
         _c(CORE_RSTN, "%s/core_aresetn" % P.ENG_CELL),
-        _c(CORE_CLK, "%s/hbm_aclk" % P.ENG_CELL),
+        _c(aclk, "%s/hbm_aclk" % P.ENG_CELL),
         "",
         "# THE THERMAL HALT: either HBM stack's catastrophic-temperature trip.  The FK33",
         "# drives compute_halt from fk33_thermal (SYSMON plus the HBM trips); the Jungle Cat",
@@ -750,12 +841,40 @@ def eng_lines(P):
         "connect_bd_intf_net [get_bd_intf_pins axil2eng/M01_AXI] [get_bd_intf_pins %s/s_axix]" % P.ENG_CELL,
         "",
     ]
-    L += P._eng_hbm_lines(CORE_CLK, CORE_RSTN)
+    L += P._eng_hbm_lines(aclk, arstn)
     L += ["# ---- end subsystem A ------------------------------------------------------", ""]
     return L
 
 
-def card_lines(P):
+def pool_split_lines(P):
+    """bcgrant/m0, m1 -> axi_clock_converter -> hbm/SAXI_30, SAXI_31 on aclk_a: the FK33
+    shape of gen_pcieep._card_pool_lines(one_clock=None), with the Jungle Cat's clocks."""
+    L = ["# ---- the grant's pool onto SAXI_30/31 through converters (JC_A_CLK_SPLIT) -----"]
+    for i, port in enumerate(P.CARD_SAXI):
+        cc = "bc_cdc%d" % i
+        L += [
+            "set _gp [get_property CONFIG.PROTOCOL [get_bd_intf_pins %s/m%d]]" % (P.GRANT_CELL, i),
+            "if {$_gp ne \"AXI3\"} { error \"JCCARD_BD FAIL: %s/m%d PROTOCOL is $_gp, not AXI3\" }"
+            % (P.GRANT_CELL, i),
+            "set_property CONFIG.USER_SAXI_%02d {true} [get_bd_cells hbm]" % port,
+            "create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 %s" % cc,
+            "set_property -dict [list CONFIG.PROTOCOL {AXI3}] [get_bd_cells %s]" % cc,
+            "jcc_want %s PROTOCOL AXI3" % cc,
+            "connect_bd_intf_net [get_bd_intf_pins %s/m%d] [get_bd_intf_pins %s/S_AXI]"
+            % (P.GRANT_CELL, i, cc),
+            "connect_bd_intf_net [get_bd_intf_pins %s/M_AXI] [get_bd_intf_pins hbm/SAXI_%02d]"
+            % (cc, port),
+            _c(CORE_CLK, "%s/s_axi_aclk" % cc),
+            _c(CORE_RSTN, "%s/s_axi_aresetn" % cc),
+            _c(ACLK_A, "%s/m_axi_aclk" % cc),
+            _c(ACLK_A_RSTN, "%s/m_axi_aresetn" % cc),
+            _c(ACLK_A, "hbm/AXI_%02d_ACLK" % port),
+            _c(ACLK_A_RSTN, "hbm/AXI_%02d_ARESET_N" % port),
+        ]
+    return L
+
+
+def card_lines(P, env=None):
     one = (CORE_CLK, CORE_RSTN)
     L = P._card_cells_lines()
     L += card_27b_lines(P)
@@ -772,7 +891,7 @@ def card_lines(P):
     L += P._card_engctl_lines(one_clock=one)
     L += P._card_hostseam_lines()
     L += P._card_grant_lines()
-    L += P._card_pool_lines(one_clock=one)
+    L += pool_split_lines(P) if a_split(env) else P._card_pool_lines(one_clock=one)
     L += P._card_grant_addr_lines()
     L += P._card_a_addr_lines()
     L += ["# ---- end subsystems B, C, D -----------------------------------------------", ""]
@@ -925,13 +1044,13 @@ def render_tcl(P, mhz, env=None):
         "  puts \"JCCARD_CFG $cell.$key = $got\"",
         "}",
     ]
-    body += clock_lines(mhz)
+    body += clock_lines(mhz, env)
     body += P._core_clk_sentinel().split("\n")
-    body += hbm_lines(mhz)
-    body += loader_lines()
-    body += jtag_hbm_lines()
+    body += hbm_lines(mhz, env)
+    body += loader_lines(env)
+    body += jtag_hbm_lines(env)
     body += ctl_lines()
-    body += eng_lines(P)
+    body += eng_lines(P, env)
     body += link_lines()
     seam = P._seam_block(one_clock=True)
     hook = "                    [get_bd_intf_pins %s/s_axi]" % P.SEAM_CELL
@@ -941,7 +1060,7 @@ def render_tcl(P, mhz, env=None):
     body += seam.replace(hook, "                    [get_bd_intf_pins %s/s_host]" % TOK_CELL).split("\n")
     body += link_ctl_lines(P)
     body += seam_27b_lines(P)
-    body += card_lines(P)
+    body += card_lines(P, env)
     body += addr_lines(P)
     body += check_lines(P)
     return ("\n".join(head) + "\n" + stamp_block("#", env) + "\n".join(body) + "\n")
```

`hw/jc/card/build_card.tcl`:

```diff
diff --git a/hw/jc/card/build_card.tcl b/hw/jc/card/build_card.tcl
index 8ed611d6..60fd85cb 100644
--- a/hw/jc/card/build_card.tcl
+++ b/hw/jc/card/build_card.tcl
@@ -156,10 +156,16 @@ update_compile_order -fileset sources_1
 # -- subsystem A (gen_pcieep.ENG_SRCS, the engine's own RTL; VHDL-93 default, as the
 #    FK33 build leaves them). rtl/a_util_ctr.vhd is Task 1's addition: it must be
 #    here, or the engine elaborates against stale port counts.
+# The a450 tiled A (plan 2026-11-12, Task 8): matvec_int4_desc_axi instantiates
+# mv4i_tiled as a component under A_TILED, so its files are listed here; with A_TILED
+# false Vivado never elaborates them.
 set ENG_SRCS {
   rtl/mv4i_arith_pkg.vhd rtl/matvec_int4_desc_pkg.vhd rtl/stream_fifo.vhd
   rtl/axi_rd_fsm.vhd rtl/axi_rd_port.vhd rtl/weight_streamer.vhd
   rtl/act_mem_striped.vhd rtl/matvec_core.vhd rtl/matvec_int4.vhd
+  rtl/mv_lfifo.vhd rtl/mv_tile.vhd rtl/mv_xbcast.vhd rtl/act_mem_dp.vhd rtl/mv_dist.vhd
+  rtl/mv_rlink.vhd rtl/mv_rchain.vhd rtl/mv_rcross.vhd rtl/mv_tsync.vhd rtl/mv_afast.vhd
+  rtl/mv_back.vhd rtl/mv4i_tcore.vhd rtl/mv4i_tiled.vhd
   rtl/a_util_ctr.vhd rtl/matvec_int4_desc_axi.vhd
 }
 foreach f $ENG_SRCS { add_files -norecurse $repo/$f }
@@ -447,6 +453,17 @@ if {[catch {
   puts "JCCARD_LINK_CDC_UNEXPECTED $lk_bad"
   if {$lk_bad != 0} { error "link cdc audit: $lk_bad unexpected crossing(s)" }
 
+  # the a450 split (plan 2026-11-12 Task 9): only when the BD carries aclk_a's MMCM.
+  # Every clk_core <-> aclk_a path is bounded datapath-only (hw/jc/a450/a450_cdc.tcl).
+  if {[llength [get_cells -quiet -hierarchical -filter {NAME =~ "*/clk_wiz_a/*" && IS_PRIMITIVE == 1 && REF_NAME =~ "MMCM*"}]] > 0} {
+    source $repo/hw/jc/a450/a450_cdc.tcl
+    a450_cdc "*/eng/inst/eng/g_tiled.dut/g_split.u/back/go_r_reg/C" \
+             "*/eng/inst/eng/g_tiled.dut/g_split.u/fast/dist/s_start_reg/C"
+    puts "JCCARD_A450_SPLIT on"
+  } else {
+    puts "JCCARD_A450_SPLIT off"
+  }
+
   # the GTG MMCM's site and dedicated route (jc_card.xdc; finding 3): read back, because a
   # filter that matches nothing in an XDC is a CRITICAL WARNING, not a stop.
   set gm [get_cells -quiet -hierarchical -filter {NAME =~ "*gtgclk/*u_mmcm" && IS_PRIMITIVE == 1}]
```

`hw/jc/card/run_card.sh`:

```diff
diff --git a/hw/jc/card/run_card.sh b/hw/jc/card/run_card.sh
index a6438301..87a97f65 100755
--- a/hw/jc/card/run_card.sh
+++ b/hw/jc/card/run_card.sh
@@ -168,6 +168,8 @@ echo "JCCARD_RUN root=$ROOT part=$PART clk_core_mhz=$CLK_CORE_MHZ mem_high=$MEM_
 # this environment and are stamped into jc_card_bd.tcl; build_card.tcl reads JC_LINK_REFCLK
 # from that stamp (systemd-run --user does not pass this environment on to Vivado).
 echo "JCCARD_LINK_ENV JC_LINK_REFCLK=${JC_LINK_REFCLK:-(unset)} JC_LINK_RATE=${JC_LINK_RATE:-(unset)}"
+# the a450 tiled A (plan 2026-11-12 Tasks 8-9): generator inputs like the two above
+echo "JCCARD_A_ENV JC_A_TILED=${JC_A_TILED:-(unset)} JC_A_CLK_SPLIT=${JC_A_CLK_SPLIT:-(unset)}"
 echo "JCCARD_MEMORY_BUDGET MemAvailable=$MEMAVAIL SwapFree=$SWAPFREE requested_cap=$MEM_HIGH swap_kill=$SWAP_KILL_BYTES run_capped=$RUN_CAPPED vivado=$VIVADO_BIN"
 
 # ---- fix round 2, CRITICAL: run() now ONLY PRINTS. The original version
@@ -229,6 +231,8 @@ else
     echo "nonce=$NONCE"
     echo "jc_link_refclk=${JC_LINK_REFCLK:-(unset)}"
     echo "jc_link_rate=${JC_LINK_RATE:-(unset)}"
+    echo "jc_a_tiled=${JC_A_TILED:-(unset)}"
+    echo "jc_a_clk_split=${JC_A_CLK_SPLIT:-(unset)}"
   } > "$ROOT/PROVENANCE.txt"
 fi
 
```

Run: `python3 -m pytest hw/jc/card/ hw/jc/a450/ -q`
Expected: `211 passed` (204 in `hw/jc/card/` plus 7 in `hw/jc/a450/`, MEASURED on the draft; if other tests were added since, all pass and none fail).

- [ ] **Step 7: Commit the code, then regenerate the card BD from the commit**

`gen_jc_card.py` regenerates through a scratch copy of git HEAD (`generate_via_scratch`), so the generator change must be committed before the generated files can follow it.

```bash
git add rtl/matvec_int4_desc_axi.vhd sim/tb_matvec_fk33_desc.vhd sim/tb_matvec_fk33_desc_tiled.vhd \
        sim/regress.sh hw/fk33/gen_fk33_engine.py hw/fk33/rtl/fk33_engine.vhd \
        hw/jc/card/gen_jc_card.py hw/jc/card/build_card.tcl hw/jc/card/run_card.sh \
        hw/jc/card/test_gen_jc_card.py hw/jc/card/test_run_card.py
git commit -m "a450 Task 8: A_TILED and A_CLK_SPLIT through desc_axi, the engine and the JC card generator"
python3 hw/jc/card/gen_jc_card.py
python3 hw/jc/card/gen_jc_card.py --check
git diff --stat hw/jc/card/
```
Expected: `JCCARD_CHECK: PASS`; the diff touches `hw/jc/card/jc_card_bd.tcl` only, in three places (MEASURED on the draft by rendering both): the GENSTAMP gains `env JC_A_CLK_SPLIT = (unset)` and `env JC_A_TILED = (unset)`; the JTAG-HBM section gains `jcc_want hbm_sc NUM_CLKS 1`; the engine section gains the `CONFIG.A_TILED {false} CONFIG.A_CLK_SPLIT {false}` set and its two `jcc_want` readbacks. Anything else means the scratch render saw a different environment: stop. Then `python3 -m pytest hw/jc/card/ -q` passes, and:

```bash
git add hw/jc/card/jc_card_bd.tcl
git commit -m "a450 Task 8: regenerate jc_card_bd.tcl (A_TILED/A_CLK_SPLIT readback, default off)"
```

- [ ] **Step 8: The full gate, against the parent commit**

The descriptor plane is shared by every engine bench. Memory: the full gate at `--jobs 1` peaks at 2.13 GiB, plus 3.7 GB while `tb_mv4i_tiled` runs. Time: the two composed rows alone are about an hour quiet. Run:

```bash
REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/a450_t8_full bash sim/regress.sh 2>&1 | tee /mnt/storage/fk33_builds/scratch/a450_t8_full.log
grep -E '^ OVERALL|^ REGRESSION' /mnt/storage/fk33_builds/scratch/a450_t8_full.log
```
Expected: `REGRESSION: PASS`. If any row fails in a file this plan did not touch, that is machine contention until shown otherwise: rerun that row alone on a quiet box. If it still fails, run it on the commit before Task 1 (`git worktree add /mnt/storage/fk33_builds/scratch/a450_parent <sha>`, same command there): a row that fails on both is not this plan's; a row that passes there and fails here is, and blocks the task.

- [ ] **Step 9: The split-off card build (MAIN SESSION, needs Oren's go)**

Ask Oren (the build costs `llama-server`, about 2 to 3 hours of box time and about 47 GB including swap). State the budget before starting: `free -g`, the job's peak (about 47 GB including swap, `MemoryHigh 24G`, swap guard 30 GiB), what is left; one Vivado on the box (the `/proc/PID/exe` loop); `llama-server` stopped.

```bash
JC_A_TILED=1 bash hw/jc/card/run_card.sh --dry-run --clk-mhz 125 --impl congestion /mnt/storage/fk33_builds/jccard_a450s0
JC_LINK_REFCLK=gtg JC_LINK_RATE=10.3125 JC_A_TILED=1 \
  bash hw/jc/card/run_card.sh --clk-mhz 125 --impl congestion /mnt/storage/fk33_builds/jccard_a450s0 \
  2>&1 | tee /mnt/storage/fk33_builds/jccard_a450s0.run.out
grep -E '^JCCARD_(DONE|FAIL)' /mnt/storage/fk33_builds/jccard_a450s0/build.log | tail -1
grep -E '^JCCARD_(A_ENV|A450_SPLIT|LINK_CDC_UNEXPECTED|GT_LOC)|^ECOA_DONE' \
  /mnt/storage/fk33_builds/jccard_a450s0.run.out /mnt/storage/fk33_builds/jccard_a450s0/build.log
```
Expected: the dry run prints `JCCARD_A_ENV JC_A_TILED=1 JC_A_CLK_SPLIT=(unset)`; the build ends `^JCCARD_DONE`, with `JCCARD_A450_SPLIT off`, `ECOA_DONE commons=1`, `JCCARD_GT_LOC GTYE4_CHANNEL_X0Y0`, `JCCARD_LINK_CDC_UNEXPECTED 0`. As soon as `JCCARD_DONE` appears, copy the bitstream and the reports into the repo, as `jccard_loop5_2026-11-11/` was:

```bash
D=hw/jc/card/results/jccard_a450s0_$(date +%F)
mkdir -p $D
cp /mnt/storage/fk33_builds/jccard_a450s0/results/jc_card.bit /mnt/storage/fk33_builds/jccard_a450s0/results/jc_card.ltx \
   /mnt/storage/fk33_builds/jccard_a450s0/PROVENANCE.txt /mnt/storage/fk33_builds/jccard_a450s0/results/route_status.rpt \
   /mnt/storage/fk33_builds/jccard_a450s0/results/utilization.rpt /mnt/storage/fk33_builds/jccard_a450s0/results/clock_interaction.rpt \
   /mnt/storage/fk33_builds/jccard_a450s0/results/cdc_summary.rpt $D/
gzip -c /mnt/storage/fk33_builds/jccard_a450s0/build.log > $D/build.log.gz
(cd $D && sha256sum jc_card.bit > BITSTREAM.sha256)
```

- [ ] **Step 10: Program, load, K1 anchor (MAIN SESSION ONLY)**

Set the runbook's variables (`docs/superpowers/plans/2026-10-09-jc-silicon-runbook.md` section 1: `$BMC`, `$SOCK`, `$REPO`, `$QTK`, `$EMB`) and check its section 2 preconditions. Then:

```bash
W=/mnt/storage/fk33_builds/jccard_a450s0/silicon
mkdir -p $W
MAN0=/mnt/storage/llama-models/qwen38-27b-card0-b0-32-ownpc/manifest.json
MAN1=/mnt/storage/llama-models/qwen38-27b-card1-b33-63-ownpc/manifest.json
BIT=/mnt/storage/fk33_builds/jccard_a450s0/results/jc_card.bit
sqrl_bridge C$BMC $BIT,$BIT skip 2>&1 | tee $W/load.log
```
Then runbook 3.1 and 3.2 (token programs and side images into `$W/card0`, `$W/card1`, from `$MAN0`/`$MAN1`), 3.3 (side and weight images, one die at a time, broker not running; gate `JCVERIFY_PASS 7170 pieces, 0 bad` on A and `6750 pieces, 0 bad` on B), 3.4 (broker; `LANE_OK`, `FWD_OK`), 3.5 (seam ID and CAPS on both dies). Then:

```bash
RB=(--seq-reset --v2 --dtbl $W/card0/token.dtbl --rel $W/card0/token.rel
    --dtbl2 $W/card1/token.dtbl --rel2 $W/card1/token.rel
    --manifest $MAN0 --manifest2 $MAN1 --qtk $QTK --mv4i $EMB)
for d in A B; do python3 $REPO/hw/jc/host/jc_seam.py util-clear --sock $SOCK --die $d; done
$REPO/server/run_prompt --jc $SOCK --jc-die A --jc-die2 B "${RB[@]}" \
  --prompt /mnt/storage/fk33_builds/jc27b_silicon_2026-11-04/prompt_k1.txt --max-new 1 --stop -1 \
  --ids-out $W/k1.ids --dump-xout $W/xout_A_k1.txt --dump-xout2 $W/xout_B_k1.txt > $W/k1.out 2> $W/k1.err
tail -1 $W/k1.ids
cmp $W/xout_A_k1.txt /mnt/storage/fk33_builds/jc27b_ownpc_2026-11-11/xout_A_k1.txt && \
cmp $W/xout_B_k1.txt /mnt/storage/fk33_builds/jc27b_ownpc_2026-11-11/xout_B_k1.txt && echo K1_ANCHOR_OK
```
Expected: last id `8678` and `K1_ANCHOR_OK` (the own-PC pair's MEASURED host-path result). A difference stops the task: the tiled A changed a value, which no bench saw; bisect with `tools/jc/` single-job tools against the oracle before anything else.

- [ ] **Step 11: A's cadence on silicon at 125 MHz (MAIN SESSION ONLY)**

Right after Step 10 (the util counters hold the k1 token):

```bash
for d in A B; do
  python3 $REPO/hw/jc/host/jc_seam.py util --sock $SOCK --die $d > $W/util_$d.txt 2>&1
  python3 - $W/util_$d.txt $d <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"^JCUTIL die \S+ nports_w (\d+) nports_s (\d+) jobcyc (\d+) seam_cycles_last_go (\d+)", t, re.M)
b = [int(x) for x in re.findall(r"^JCUTIL die \S+ port \d+ [ws] beats (\d+)", t, re.M)]
if not m or not b or len(set(b)) != 1:
    print("JCTOKEN die %s UNREADABLE (util lines missing or ports unequal)" % sys.argv[2]); sys.exit(1)
jc, sc = int(m.group(3)), int(m.group(4))
print("JCTOKEN die %s seam_cycles %d a_jobcyc %d port_beats %d c_per_word %.4f"
      % (sys.argv[2], sc, jc, b[0], jc / float(b[0])))
PY
done | tee $W/token_cadence.txt
```
Expected: two `JCTOKEN` lines. `port_beats` equals today's (die A 8,192,096, die B 8,520,192, MEASURED 2026-11-11 `measure_token.log`): the layout and the job list did not change. `c_per_word` ESTIMATE at or below 1.05 (today 1.508: the tiles pop at FAST_POP cadence even at 125 MHz). Record both, MEASURED, with today's numbers beside them; this step has no pass/fail beyond `port_beats` equality.

- [ ] **Step 12: The 500-token context test (MAIN SESSION ONLY)**

Per CLAUDE.md, after every card build:

```bash
# plus the runbook's JC_BC, JC_BMC, JC_BCW, JC_BC_MAN0, JC_BC_MAN1 for the default GDN re-zero (jc_ctxtest.sh header)
export JC_SOCK=$SOCK JC_RUN0=$W/card0 JC_RUN1=$W/card1 JC_MAN0=$MAN0 JC_MAN1=$MAN1
hw/jc/host/jc_ctxtest.sh pair   /mnt/storage/fk33_builds/jccard_a450s0/ctxtest/n500  500 2>&1 | tee $W/ctx_pair.log
hw/jc/host/jc_ctxtest.sh single /mnt/storage/fk33_builds/jccard_a450s0/ctxtest/n500s 500 2>&1 | tee $W/ctx_single.log
grep -E '^CTXTEST_(PASS|FAIL)' $W/ctx_pair.log $W/ctx_single.log
R=/mnt/storage/fk33_builds/jccard_loop5/ctxtest
for m in "n500 b_n500_loop" "n500s b_n500s_loop"; do
  set -- $m
  for t in input output; do
    diff <(grep -v '^#' /mnt/storage/fk33_builds/jccard_a450s0/ctxtest/$1/${t}_r1.ids) \
         <(grep -v '^#' $R/$2/${t}_r1.ids) > /dev/null && echo "IDS_SAME $1 $t" || echo "IDS_DIFF $1 $t"
  done
done
```
Expected: `CTXTEST_PASS` for pair and for single, and four `IDS_SAME` lines (the current card's ids, by content: the host `.ids` files start with a `# run_prompt:` comment line, which `grep -v '^#'` drops). A `CTXTEST_FAIL` whose `.err` shows a broker `WindowUnknown` is the transport refusing to retry (docs/debugging/2026-11-12_jc-loop-silicon.md 4.5), not a die error: rerun that mode once and say so.

- [ ] **Step 13: Write the record and commit**

Write `docs/debugging/<YYYY-MM-DD>_a450-silicon.md` in the CLAUDE.md shape (question; answer up front; procedure; raw evidence: `load.log` verify lines, `k1.ids` last line, the `cmp` result, `token_cadence.txt`, the `CTXTEST` and `IDS_*` lines; Measured and REJECTED; traps; open questions), then:

```bash
D=hw/jc/card/results/jccard_a450s0_<the date of Step 9>
cp $W/token_cadence.txt $W/k1.ids $D/
git add $D/jc_card.bit $D/jc_card.ltx $D/PROVENANCE.txt $D/route_status.rpt $D/utilization.rpt \
        $D/clock_interaction.rpt $D/cdc_summary.rpt $D/build.log.gz $D/BITSTREAM.sha256 \
        $D/token_cadence.txt $D/k1.ids docs/debugging/<YYYY-MM-DD>_a450-silicon.md
git commit -m "a450 Task 8: tiled A on silicon at 125 MHz (split off): K1 anchor identical, ctxtest pass, c/word <value>"
```
Fill in the two dates and `<value>` (die A's `c_per_word`) from the run before committing.

---
### Task 9: Split-on card build; silicon gate 2

The code for the split (generator, CDC hook, tests) landed in Task 8 and is pinned by its tests; this task builds it and measures it. The build needs Oren's go and runs in the main session; Steps 3 to 6 are **main session only, never a subagent.**

**Files:**
- Create (results): `hw/jc/card/results/jccard_a450s1_<YYYY-MM-DD>/`
- Modify: `docs/debugging/<YYYY-MM-DD>_a450-silicon.md` (append a dated section; never rewrite Task 8's)

**Interfaces:**
- Consumes: `JC_A_TILED=1 JC_A_CLK_SPLIT=1` (Task 8 generator); `a450_cdc` from `build_card.tcl` (prints `JCCARD_A450_SPLIT on` and an `A450CDC core ... aclk_a ...` line); Task 8 Steps 10 to 12 procedures.
- Produces: the split-on bitstream and the spec 3.3 gate 2 record.

- [ ] **Step 1: Render the split-on BD in a scratch tree and check it before spending a build**

```bash
python3 - <<'PY'
import os, re, sys
sys.argv = ["x"]
for k in list(os.environ):
    if k.startswith("FK33_"):
        del os.environ[k]
sys.path[:0] = ["hw/jc/card", "hw/jc/link", "hw/fk33"]
import gen_pcieep as P, gen_jc_card as G
t = G.render_tcl(P, G.CLK_CORE_DEFAULT, {"JC_A_TILED": "1", "JC_A_CLK_SPLIT": "1"})
need = ["CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {450.000}", "CONFIG.USER_AXI_INPUT_CLK_FREQ {450}",
        "CONFIG.USER_AXI_INPUT_CLK1_FREQ {450}", "connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins eng/hbm_aclk]",
        "jcc_want eng A_CLK_SPLIT true"]
miss = [n for n in need if n not in t]
conv = len(re.findall(r"create_bd_cell[^\n]*axi_clock_converter", t))
aclk = len(re.findall(r"connect_bd_net \[get_bd_pins clk_wiz_a/clk_out1\]\s+\[get_bd_pins hbm/AXI_\d\d_ACLK\]", t))
print("A450_SPLIT_RENDER missing %d converters %d hbm_aclk_ports %d" % (len(miss), conv, aclk))
for n in miss:
    print("  MISSING " + n)
PY
```
Expected: `A450_SPLIT_RENDER missing 0 converters 3 hbm_aclk_ports 32`. (These are the generator's promises; Task 8's pytest pins them too. This step only refuses to start a 3-hour build on a tree where they are not true.)

- [ ] **Step 2: The split-on card build (MAIN SESSION, needs Oren's go)**

Ask Oren. State the budget: `free -g`; about 47 GB including swap (`MemoryHigh 24G`, swap guard 30 GiB); one Vivado; `llama-server` stopped.

```bash
JC_A_TILED=1 JC_A_CLK_SPLIT=1 bash hw/jc/card/run_card.sh --dry-run --clk-mhz 125 --impl congestion /mnt/storage/fk33_builds/jccard_a450s1
JC_LINK_REFCLK=gtg JC_LINK_RATE=10.3125 JC_A_TILED=1 JC_A_CLK_SPLIT=1 \
  bash hw/jc/card/run_card.sh --clk-mhz 125 --impl congestion /mnt/storage/fk33_builds/jccard_a450s1 \
  2>&1 | tee /mnt/storage/fk33_builds/jccard_a450s1.run.out
grep -E '^JCCARD_(DONE|FAIL)' /mnt/storage/fk33_builds/jccard_a450s1/build.log | tail -1
grep -E '^JCCARD_(A_ENV|A450_SPLIT|LINK_CDC_UNEXPECTED|GT_LOC)|^ECOA_DONE|^A450CDC' \
  /mnt/storage/fk33_builds/jccard_a450s1.run.out /mnt/storage/fk33_builds/jccard_a450s1/build.log
```
Expected: `JCCARD_A_ENV JC_A_TILED=1 JC_A_CLK_SPLIT=1`; `^JCCARD_DONE`; `JCCARD_A450_SPLIT on`; `A450CDC core <clk_core clock> period 8.000 aclk_a <clk_wiz_a clock> period 2.222`; `ECOA_DONE commons=1`; `JCCARD_GT_LOC GTYE4_CHANNEL_X0Y0`; `JCCARD_LINK_CDC_UNEXPECTED 0`.

Known risk, check it in the reports rather than assume: `a450_cdc` bounds every `clk_core` to `aclk_a` path datapath-only, which also covers the three `axi_clock_converter`s and the two-clock smartconnect. Their own scoped constraints are tighter or equal (one destination period), so read `exceptions.rpt` and `clock_interaction.rpt` in `results/`: if any converter path is now bounded only by `a450_cdc`'s 2-period figure, say so in the record. An `A450CDC FAIL: no pin matches ...` error means the engine's instance path differs from `*/eng/inst/eng/g_tiled.dut/g_split.u/...`: find the real path in the synthesised design (`get_cells -hier -filter {NAME =~ *g_split.u/back/go_r_reg}`), fix the two globs in `build_card.tcl`, commit, and rebuild in a new root.

On `JCCARD_DONE`, copy the bitstream and reports exactly as Task 8 Step 9 does, into `hw/jc/card/results/jccard_a450s1_$(date +%F)/`, with `/mnt/storage/fk33_builds/jccard_a450s1` as the source and also `results/exceptions.rpt` and `results/timing_summary.rpt` (gzip the latter).

- [ ] **Step 3: Program, load, K1 anchor (MAIN SESSION ONLY)**

Task 8 Step 10's commands with `W=/mnt/storage/fk33_builds/jccard_a450s1/silicon` and `BIT=/mnt/storage/fk33_builds/jccard_a450s1/results/jc_card.bit`. Expected: last id `8678`, `K1_ANCHOR_OK`.

- [ ] **Step 4: Gate 2's cadence (MAIN SESSION ONLY)**

Task 8 Step 11's commands, into `$W/token_cadence.txt`. A's util counters run on `m_aclk`, which is `aclk_a` here, so `a_jobcyc` is in 450 MHz cycles (ruling R8).
Expected: `port_beats` equal to today's (A 8,192,096; B 8,520,192) and `c_per_word <= 1.05` on both dies (spec 3.3 gate 2). Also record `seam_cycles` (in `clk_core` cycles) against today's 32,719,893 (A) and 32,836,359 (B): spec 3.4's ESTIMATE is A's share falling from 12.36M cycles at 125 MHz (98.9 ms) to 8.19M at 450 MHz (18.2 ms), a die token of about 181 ms instead of 262 ms. Label the token figure DERIVED from the measured cycles, with the arithmetic shown.

- [ ] **Step 5: The 500-token context test (MAIN SESSION ONLY)**

Task 8 Step 12's commands with outputs under `/mnt/storage/fk33_builds/jccard_a450s1/ctxtest/`. Expected: `CTXTEST_PASS` pair and single, four `IDS_SAME`.

- [ ] **Step 6: Append the record and commit**

Append a dated `## Split on (aclk_a 450 MHz), <date>` section to Task 8's debugging file (raw `JCTOKEN` lines, `A450CDC` line, `CTXTEST` and `IDS_*` lines, the DERIVED token time, anything REJECTED). Then:

```bash
D=hw/jc/card/results/jccard_a450s1_<the date of Step 2>
cp $W/token_cadence.txt $W/k1.ids $D/
git add $D/jc_card.bit $D/jc_card.ltx $D/PROVENANCE.txt $D/route_status.rpt $D/utilization.rpt \
        $D/clock_interaction.rpt $D/cdc_summary.rpt $D/exceptions.rpt $D/timing_summary.rpt.gz \
        $D/build.log.gz $D/BITSTREAM.sha256 $D/token_cadence.txt $D/k1.ids \
        docs/debugging/<the Task 8 file>.md
git commit -m "a450 Task 9: A on aclk_a at 450 MHz on silicon: values identical, c/word <A>/<B>, die token <ms> ms derived"
```
Fill in the dates, the file name and the three numbers from the run before committing.

---
## Self-review (run against the spec, 2026-11-12)

**1. Spec coverage.**

| Spec | Where |
|---|---|
| 1.1 `aclk_a` at 450 MHz for A and all 32 HBM ports; `clk_core` stays 125 | Task 7 (`a450_bd.tcl`), Task 8/9 (`gen_jc_card.py` split-on clocking) |
| 1.1 B and C through dual-clock ports | Ruling R6: `axi_clock_converter` x 3 and a two-clock smartconnect; Task 8 tests, Task 9 Step 1 |
| 1.2 `mv_tile` per port: AXI3 16-beat reader, FAST_POP, LUTRAM codebook, 2 x 32 cascade, scale, 48-bit acc, rounding and modes | Task 2 (`mv_tile.vhd`); BFP fold central per ruling R1 |
| 1.2 no shared enables, valid beside data | Task 2 (every stage carries `*_v`; the only stall is the tile's own FIFO pop) |
| 1.2 one pblock per tile column above its port, A crosses no SLR | Task 7 (`a450_pblocks.tcl`, `A450HBM_PBLOCKS`) |
| 1.3 descriptor format, A_JOB contract, arithmetic, layout, util meaning unchanged | Task 6 (equivalence bench), Task 8 (descriptor rows, full gate, K1 anchor, ctxtest), ruling R8 |
| 2.1 weights never cross a tile | Task 2 (each tile owns its `axi_rd_port`) |
| 2.2 one dual-port x memory, registered tree, credits through an AND tree, FIFO depth covers the loop | Task 4 (`act_mem_dp`, `mv_xbcast`, `mv_dist`, SLACK sweep), ruling R4 |
| 2.3 results through a daisy chain and an async FIFO, region-file contract unchanged | Task 5, Task 6 (`mv_back`), ruling R3 |
| 2.4 control crossings, x load before start, util counters in `aclk_a` | Task 5 (`mv_tsync`), Task 6, rulings R2 and R8 |
| 2.5 `A_CLK_SPLIT` both ways | Task 6 (SPLIT and SAME DUTs), Task 8 (off on silicon), Task 9 (on) |
| 3.1 tile bench against the independent model, four named mutants and an attribution control | Tasks 1 and 2 |
| 3.1 composed bench old vs new, back-pressure, FIFO corners, both settings, rolling phase, credit-loss mutant | Task 6 (`tb_mv4i_tiled`, `C1`); unit-level credit loss `D1` in Task 4 |
| 3.1 GHDL benches free of UNISIM | all benches are behavioural; no `library unisim` anywhere in the new files |
| 3.2 gate 1: tile OOC at 2.222 ns on -2L at 0.85 V, recorded as a rating | Task 3 |
| 3.2 gate 2: real HBM, 24 tiles, distributor, chain, crossings, stub sequencer, pblocks, routed WNS >= 0 at 450 | Task 7 |
| 3.3 gate 1: split off, K1 identical, ctxtest identical | Task 8 Steps 10 to 12 |
| 3.3 gate 2: split on, same values, `a_jobcyc` per word <= 1.05 in `aclk_a` cycles | Task 9 |
| 3.4 expected gain | Task 9 Step 4 records it as DERIVED from measured cycles |
| 5 risks: depth sweep, cascade column, port sites, B/C ports at 450 | Task 4 Step 5; Task 3 (DSP count, honest about what it cannot show); Task 7 (pblocks against real sites); Task 9 Step 2 (converter constraints) |

Gaps found and fixed while writing: the tile bench could not stress credits (moved the sweep to Task 4); mutant R3 survived for a real reason (`w_level`'s built-in margin) and was replaced, with the bench gaining read stalls; the composed credit-loss mutant C1 survived twice until the bench got a job larger than a tile's buffering and a heavily stalled port; the composed and descriptor rows exceed the gate's 900 s (Task 6 Step 2 adds a per-row timeout).

**2. Placeholder scan.** The only angle-bracket tokens left are run-time values the executor fills from the run (`<value>`, dates, die numbers in commit messages), each with an explicit "fill in from the run" instruction, and generic argument names in interface signatures. No step says "similar to Task N" for code; Task 9 reuses Task 8's silicon commands by step number because they are operator procedures with only `W`/`BIT` changed, and says exactly which two variables change.

**3. Type and name consistency.** Checked across tasks: `mv_tile` ports (`f_*`, `room`, `r_*`) as consumed by `mv_xbcast`/`mv_afast`; `r_d` 97 bits through `mv_rlink`, `mv_rchain`, `mv_rcross` (`W => 97`) and `mv_back` (`q_data(96 downto 0)`); `dbg_rtile`/`dbg_words` from `mv4i_tiled` to `matvec_int4_desc_axi`; the instance paths `g_split.u/back/go_r_reg` and `g_split.u/fast/dist/s_start_reg` used by `build_a450.tcl` and `build_card.tcl`; `a450_cdc` and `a450_pblocks` signatures; env names `JC_A_TILED`, `JC_A_CLK_SPLIT` in the generator, `run_card.sh`, the tests and Tasks 8/9; rating rows `a450_tile`, `a450_afast` and device `vu35p_jc_2l85` in the scripts, commands and record paths.

**4. Review Focus.** Five lines, each pinned by a test in Task 6 (`tb_mv4i_tiled` jobs 12 to 16, the `lpm` stall table, and mutant `C1`). Checked against the spec: the remaining implied inputs (pad rows, pad columns, all three modes, out_shift 0 and 40, saturation, refused descriptors, the job after an error) are already in Task 2's vectors or Task 6's job table.

**Verification status of this plan's code (MEASURED 2026-11-12 on a scratch worktree of jc-loop at 034d6b67, GHDL 1.0.0):** `MV_TILE_MODEL_SELFTEST_OK`; `tb_mv_tile` 93 checks, `tb_mv_dist` 9,936, `tb_mv_rchain` 1,970, `tb_mv4i_tiled` 150 (as the `mv4i_tiled` mutants' Z0; its 127-check predecessor passed as a gate row in 661 s); `tb_matvec_fk33_desc_tiled` 23 cases, 0 failures (direct run, 43 min 58 s); mutants `mv_tile` 5/5, `mv_tile_attr` 5/5, `mv_dist` 5/5, `mv_rchain` 5/5, `mv4i_tiled` 2/2; pytest `hw/jc/card/` + `hw/jc/a450/` 211 passed; `GEN_A450_TOP_CHECK OK`; `GEN_FK33_ENGINE_CHECK OK`; the levers patch applies; `run_a450.sh --dry-run` prints `A450RUN_DRY`. NOT run while planning: any Vivado job (Tasks 3, 7, 8 Step 9, 9), the full gate, silicon. 
