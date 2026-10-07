# Jungle Cat Engine Composition: Design

**Date:** 2026-10-07. **Status:** design approved section by section in session; spec
awaiting Oren's review. Labels: MEASURED (a tool ran, named), DERIVED (arithmetic shown),
ESTIMATE (assumption stated).

**Goal:** run Qwen3.8-27B on the Jungle Cat's two VU35P dies, at one 200 MHz clock domain,
with the host reaching each die over JTAG (CoE), and with subsystem A taking every HBM
weight port's full width on every fabric cycle so that throughput rises with the clock
and no width ever changes.

This is sub-project 1 of the throughput work. It is backlog item 3 in `docs/WORKLOG.md`
("Jungle Cat block design for the 2-die 27B pipeline").

---

## 1. Why this first

The FK33 9B token is 30,115,246 cycles, 0.4015 s at 75 MHz (MEASURED,
`fk33_step_profile.py`, `docs/2026-09-20_a-clock-domain-split.md:31`): B 52.6%, A 36.2%.
Neither term is bound by fabric area:

- **B is bound by the state mover's per-beat handshake**, not by lanes or HBM
  (`docs/debugging/2026-09-20_b-job-660k-cycles.md`). The fixes `WIDE`, `PIPE` and
  `MAXOUT => 8` exist, are bench-verified, and ship off because the FK33 had no room:
  `WIDE` saves 327,677 cycles per B job and `PIPE` 8,711 more, of ~660,600 (MEASURED,
  bench).
- **A is port-bound and bubble-bound.** Its port count is fixed by the identity
  `NPORT = ROWS_IF x 9/16` (27 at `ROWS_IF=48`: 24 weight + 3 scale), plus one descriptor
  port. On the 9B it streams 29.7 GB/s against a weight ceiling of 24 x 32 B x 75 MHz =
  57.6 GB/s, 51.6% (DERIVED).
- **The clock is the multiplier the VU35P adds.** Every shipping block rates at or above
  204.5 MHz on VU35P -2 (`a_engine` 264.0, `b_gdn` 254.3, `c_attn` 204.5, `c_kv` 228.2,
  `v_swg` 242.9, `v_rms` 281.9; MEASURED, `tools/rate/`, README). The 27B card uses
  46.1% of the VU35P's LUTs (MEASURED, OOC,
  `docs/debugging/2026-09-30_27b-fits-vu35p-ooc-timing-artifact.md`).

A homogeneous tile array was considered and set aside: no measured term is compute-bound.
It returns only if a profile taken after this sub-project shows one.

## 2. The width rule (Oren, 2026-10-07)

HBM delivers 32 B per port per port-clock cycle at 100% efficiency at every port count
from 1 to 30 (MEASURED, 288.0 GB/s = 30 x 32 B x 300 MHz, `docs/fpga-hardware-recon.md`
header). Therefore:

- every HBM AXI port runs on the fabric clock (`clk_core`); there is no clock converter
  between the engine and the HBM;
- A accepts one 256-bit beat per weight port per cycle with no bubbles inside an A job;
- A's weight ceiling is `24 x 32 B x f`: 153.6 GB/s at 200 MHz, 230.4 GB/s at 300 MHz
  (DERIVED). Compute per cycle is fixed at 24 x 64 = 1,536 INT4 weights.

Raising `clk_core` raises throughput with no RTL change, up to the HBM's own port clock
limit. The FK33's A already has this width (`AXI_DW = 256`,
`hw/fk33/rtl/fk33_engine.vhd:1118`); what this spec adds is the clock and the measurement.

**Utilisation counters.** The seam gains one counter pair per A port: R beats accepted,
and cycles inside A jobs. Target: at least 95% during A jobs at every clock tried. A
shortfall is reported with its cause (descriptor turnaround, row boundaries, output drain,
or HBM refresh), not hidden by an average.

## 3. Per-die architecture (one bitstream serves both dies)

The 9B two-card pipeline already ran bit-exact with one bitstream on both FK33 cards
(`hw/fk33/results/twocard_9b_2026-09-23/README.md`): the HBM image decides which blocks a
card runs. The Jungle Cat keeps that: die A holds blocks 0-32, die B holds blocks 33-63
plus the LM head (the images already loaded and verified on silicon 2026-10-06).

**Part:** `xcvu35p-fsvh2104-2L-e` (the vendor's grade). VCCINT is the board default,
0.85 V (MEASURED, bringup doc).

**Clocking:**

| net | source | frequency |
|---|---|---|
| sysclk | BC26/BC27, bank 65, LVDS, IBUFDS | 200.0 MHz (MEASURED, both dies) |
| `clk_core` | clk_wiz output | 200 MHz, a build parameter |
| HBM APB | clk_wiz output | 100 MHz |
| HBM_REF_CLK_0/1 | clk_wiz output | 200 MHz |
| TCK | BSCANE2 (USER3, USER4) | 13.5-27 MHz, async to `clk_core` |

`clk_core` clocks the engine, every enabled HBM AXI port, the loader's `aclk`, the USER3
core's AXI side and `jtag_hbm`. A timing miss lowers the parameter; it does not change the
design.

**HBM port table** (FK33 census, `hw/fk33/gen_pcieep.py:436-440, 4068-4083`):

| ports | FK33 | Jungle Cat |
|---|---|---|
| SAXI_00 | host (`pcie2hbm`) | USER4 loader (`jc_loader_top`) |
| SAXI_01..15, SAXI_17..29 | A: 24 weight + 3 scale + 1 descriptor (m00..m27) | same |
| SAXI_16 | host | `jtag_hbm` (spot checks) |
| SAXI_30, SAXI_31 | B state mover, C KV | same |

The implementation plan confirms which of SAXI_30/31 is B and which is C from the card
generator, not from this table.

**Card cells:** the FK33 card RTL (`FK33_CARD=1` content) with no edits to the shared
card sources beyond generics. A Jungle Cat variant of `gen_pcieep.py`'s card mode emits the
board-level BD: sysclk, clk_wiz, HBM, the loader, the USER3 core and `jtag_hbm`, in place
of XDMA. Generated files carry the `tools/genstamp.py` block.

**Levers:**
- on: B `PIPE => true, WIDE => true, MAXOUT => 8` (`u_state` generic map);
- off: C `SWEEP_PIPE`, `SCORE_EARLY` (the position-32 hang, not separated yet).

**New: USER3 control core (`hw/jc/ctl/`).** It has three parts:
- a BSCANE2 USER3 frame receiver in the TCK domain, with the loader's frame discipline
  (magic, sequence number, CRC, status word returned on every shift);
- an async FIFO;
- an AXI-Lite master on `clk_core` driving the seam (`SEAM_BASE = 0xE000`) and the
  engine control block.

The frame set is: write N words to consecutive or fixed addresses, read N words, and
status. "Fixed address" serves the WIN_DATA windows. A 5,120-element residual therefore
moves in a few frames. The core has no HBM master: activation in and residual out already
go through the seam's WIN_SEL windows (2 = activation in, 3 = residual out,
`server/fk33_seam.h`).

**Unchanged:** the USER4 loader, byte for byte (`hw/jc/loader/rtl/`).

## 4. Host side

**Broker (`tools/jc/jc_broker.py`).**
- It is the only process that opens the BMC. It is built on `tools/jc/coe.py`
  unchanged, with every guard: IR allowlist BYPASS/IDCODE/USER3/USER4, shadow TAP,
  poisoning, the `start()` stale-reply flush, and the proactive reconnect before the
  ~310 s BMC timer.
- One connection reaches both dies (chain AB). Dies are selected by DNA from the
  `--dies` record, never by chain position.
- It serves a Unix socket with requests `reg_read32`, `reg_write32`, `read_n`, `write_n`
  and `status`, each naming a die. It refuses a second client.
- The broker and `coe_load.py` are separate lanes and never hold the BMC at once.

**C transport.** `fk33_transport_open_jc()` in `server/` implements the existing
`struct fk33_transport` (`server/fk33_transport.h:82-95`) over the broker's socket.
`pl_backend.c` and the token flow above it do not change. The guard is not reimplemented
in C.

**Token flow, per generated token:**
1. The host gathers the embedding row: 5,120 values, about 10 KB.
2. It writes the row to die A through window 2, sets SEQ_POS and pulses GO.
3. It polls die A's STATUS.
4. It reads die A's residual through window 3, about 10 KB.
5. It writes the residual to die B through window 2, pulses GO and polls.
6. It reads die B's ARGMAX.

That is about 30 KB per token: about 12 ms at 2.6 MB/s plus polling round trips (DERIVED
for the transfer; the round-trip cost is measured in the plan, not assumed). Prefill uses
the same flow per prompt token. Pipelining across tokens is out of scope: at batch 1,
each token depends on the previous one.

## 5. Verification

The oracle for every value is an independent implementation; structural checks are not
counted as evidence of values.

- **USER3 core (GHDL).** A host-side frame model drives the core. An independent
  AXI-Lite slave model records every transaction, and each read and write is compared
  against it.
  - Cases: corrupted CRC, a sequence gap, FIFO full, back-to-back frames, and a status
    poll in the middle of a batch.
  - Mutation teeth come from the core itself, never from the check's model of it, with
    the attribution control run. Surviving mutants are reported by name.
- **Utilisation counters (GHDL).** The bench counts R handshakes per port independently;
  the counter must equal it. A mutant that counts cycles instead of beats must fail.
- **Broker and transport (pytest and a C test).** The fakes model both dies. Tests
  cover:
  - die selection by DNA;
  - refusing a second client;
  - batched reads and writes;
  - reconnect inside a request;
  - the existing `coe.py` guard tests, unchanged.
- **Composed card (GHDL).** The existing card benches run at the 27B config with the B
  levers on. The levers are bench-verified alone; this proves them in composition.
- **Silicon (main session only; no subagent touches hardware).**
  1. Load both images (`coe_load.py`), verify, and spot-check.
  2. Generate the first token over 2 dies. Its argmax must equal the CPU reference for
     the same prompt.
  3. Port `fk33_ctxtest.sh` to the Jungle Cat: N = 500, input and output, each twice,
     gated on `^CTXTEST_PASS`.
  4. Read per-port utilisation and the token time at each `clk_core` tried.

## 6. Build plan and memory budget

1. **OOC first.** Route the 27B card on `xcvu35p-fsvh2104-2L-e` at 200 MHz with the levers
   on, with `route_design` in the script. Routed WNS is the only fmax result; placed WNS
   is not reported as one.
2. **Full build.** One Vivado, alone on the workstation, under `MemoryHigh=24G` with a swap
   guard that kills the unit at 30 GB. The build root is
   `/mnt/storage/fk33_builds/<tag>/`. The bitstream and logs are copied into the repo when
   the sentinel appears.
   - Peak memory is unknown. The FK33 card build took ~47 GB including swap at 99%
     fill. The loader-only VU35P build peaked at 14.4 GB (MEASURED).
   - **It needs `llama-server` stopped, which is Oren's call**, asked before it runs.
   - The BC-250 (15.2 GB) cannot take it.

## 7. Done

All of the following hold:
- the 27B generates on 2 dies at `clk_core` = 200 MHz with the reference argmax;
- it passes the N = 500 context test;
- it reports A at 95% or more of `24 x 32 B x f` during A jobs, or the measured shortfall
  and its cause.

## 8. Out of scope

- Aurora over the 16 die-to-die pairs: needs X1/X2 populated, and comes later.
- B's double-buffered resident state (~156,000 cycles per job, DERIVED) and the
  small-memory widening (~85,000, DERIVED): sub-project 2.
- C's levers.
- Tensor parallelism and subsystem E.
- Changes to the USER4 loader.

## 9. Open, not yet answered

- The CoE round-trip cost per polling transaction at the broker, which sets how much of
  the ~30 KB-per-token budget is latency.
- Whether the composed card closes at 200 MHz on -2L. The OOC engine alone closed at
  222.0 MHz with WNS -0.253 ns.
- The full build's memory peak on the VU35P.
- Which of SAXI_30/31 is B and which is C, to be read from the generator.

---

## CORRECTION 2026-10-07 (same day, before the plan): the B levers already ship ON

Withdrawn: section 1's "ship off because the FK33 had no room" and section 3's "on:
B `PIPE => true, WIDE => true, MAXOUT => 8`" as a change. Both rest on the 2026-09-20 kvreg
profile (B_JOB 660,600 cycles), which predates the levers reaching the card.

MEASURED since: B_JOB is **324,211 cycles** per job on build 18
(`hw/fk33/results/card_build18_2026-09-23/profile_pair_2026-09-24/README.md`) and 324k on
build 12b (`hw/fk33/results/card_build12b_2026-09-21/characterisation/README.md`). The
shipping build 20's levers-off patch
(`hw/fk33/results/card_build20_2026-09-24/build12_levers_off.patch`) turns OFF only
`FAST_POP`, `NWIDE`, `SWEEP_PIPE` and `SCORE_EARLY`; `MAXOUT => 8, PIPE => true,
WIDE => true` are unchanged context lines, i.e. on.

What this changes:
- **The current split, per card of the 9B pair at 75 MHz (MEASURED, build 18):** A_JOB
  46.9% / 50.2%, B_JOB 37.1% / 32.6%, card totals 139.8 ms and 159.0 ms. **A is the
  largest term**, which strengthens section 2's priority.
- **Levers on the Jungle Cat:** exactly build 20's set, i.e. the committed tree plus
  `build12_levers_off.patch` (FAST_POP, NWIDE, SWEEP_PIPE, SCORE_EARLY off; PIPE, WIDE,
  MAXOUT 8 on). That is the set validated on silicon. No lever changes in this
  sub-project.
- **Sub-project 2's B figures** (double buffer ~156,000, small memories ~85,000 cycles per
  job) were derived against the 660k job and must be re-derived against 324k before they
  are quoted again.
