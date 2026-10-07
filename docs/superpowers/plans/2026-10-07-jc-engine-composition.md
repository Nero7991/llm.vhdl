# Jungle Cat Engine Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Qwen3.8-27B generating on the Jungle Cat's two VU35P dies at one 200 MHz `clk_core`,
controlled over JTAG through a new USER3 control core and a host broker, with A's per-port
HBM utilisation measured.

**Architecture:** One bitstream per die. It contains the FK33 card RTL with build 20's levers,
the unchanged USER4 loader, a new USER3 control core, HBM with every AXI port on
`clk_core`, and the 200 MHz board sysclk. On the host, a Python broker owns the single CoE
connection, with `coe.py`'s guard. A C transport implementing `struct fk33_transport` talks
to the broker, so `pl_backend.c` and `pl_pipeline.c` run unchanged.

**Tech Stack:**
- VHDL-2008 under GHDL 6 mcode, through `sim/regress.sh`; the gate is GHDL only.
- Vivado 2025.x for OOC runs and the full build.
- Python 3 with pytest for `tools/jc/`.
- C99 for `server/`.

**Spec:** `docs/superpowers/specs/2026-10-07-jc-engine-composition-design.md`. Read its
2026-10-07 CORRECTION section: the B levers already ship on.

## Global Constraints

- **Hardware:** subagents get NO hardware access. That means no `xsdb`, `hw_server`,
  `program`, `sqrl_bridge`, `coe_load.py`/`coe_soak.py`/`jc_broker.py` against a real
  address, `/dev/xdma*`, or XVC. Tasks 11 and 12 belong to the main session only.
- **JTAG instructions:** the Jungle Cat chain may shift only BYPASS 0xFFF, IDCODE 0x249,
  USER3 0x8A4 and USER4 0x8E4.
- **Loader:** the USER4 loader is unchanged byte for byte: `rtl/jc_frame_core.vhd`,
  `rtl/jc_loader_*.vhd`, `rtl/jc_hbm_*.vhd`, `rtl/jc_status_sync.vhd`,
  `rtl/jc_dna_reader.vhd`, `hw/jc/loader/**`. They may be instantiated, never edited.
- **`coe.py`:** `tools/jc/coe.py` is unchanged. New host code uses only its vetted API:
  `start`, `ir_scan`, `to_shift_dr`, `exit_dr_to_idle`, `send` (CMD_TDI only), `reply`,
  `drain` and `resync`.
- **Clocks:**
  - `clk_core` = 200 MHz, a build parameter;
  - every enabled HBM AXI port is on `clk_core`, with no AXI clock converter between the
    engine and HBM;
  - HBM APB is 100 MHz and HBM_REF_CLK is 200 MHz.
- **Part:** `xcvu35p-fsvh2104-2L-e`.
- **Levers:** build 20's set exactly. That is the committed tree plus
  `hw/fk33/results/card_build20_2026-09-24/build12_levers_off.patch` (FAST_POP, NWIDE,
  SWEEP_PIPE, SCORE_EARLY off; PIPE, WIDE, MAXOUT 8 on).
- **Generated files:** check line 2 of every `.vhd` before editing it. Generated files
  are changed only through their generator, with `tools/genstamp.py`'s block.
  `rtl/fk33_llama_top.vhd` comes from `rtl/llama_top.vhd` via `tools/gen_cardtop.py`.
  `hw/fk33/rtl/fk33_card.vhd` comes from `tools/gen_bd_wrapper.py`.
- **Gate:** run GHDL only through `REGRESS_SCRATCH=<per-run dir> bash sim/regress.sh --only <substring> --keep`.
  Read the `OVERALL PASS n` line, where `PASS 0` is a failure. Never edit
  `sim/regress.sh` while a gate runs.
- **Git:** stage by explicit path, never `git add -A` or `git add .`. Use
  `git commit -F <file>` with the message file under `/home/orencollaco/regress_scratch/`.
  No Co-Authored-By or Claude attribution line.
- **Style:** no emojis and no em-dashes anywhere.
- **Memory:** one Vivado per box. A Vivado run is dispatched only by the controller, with
  the budget stated, under `run_capped.sh`. The BC-250 never runs above
  `MemoryHigh=11G`.
- **Storage:** nothing expensive goes under `/tmp`. Build roots go under
  `/mnt/storage/fk33_builds/<tag>/`.

## Review Focus

1. **A read response streamed while the aclk side overwrites the buffer.** Expected: the
   host never accepts a response whose seq tag does not match its request. Task 3 pins it
   with a bench case that issues read B before read A's response is acknowledged.
2. **A write frame whose CRC fails.** Expected: no AXI write at all, not a partial one.
   Writes are buffered and executed only on PASS. Task 3 pins it by counting AXI-Lite AW
   handshakes on a FAIL frame (must be 0).
3. **An AXI-Lite SLVERR or DECERR, or a read past the seam's decode.** Expected: the
   status word carries the error and the op's seq, the broker raises it, and
   `fk33_transport` returns a negative code. Task 3's bench has the slave answer SLVERR
   at one address; Task 6 has a test where the fake die reports `axi_err`.
4. **The broker addressing the wrong die after a reconnect or chain order change.**
   Expected: every request re-checks DNA after any reconnect, and a mismatch aborts.
   Task 6 pins it with a fake that swaps die DNA on reconnect.
5. **A utilisation counter that wraps during a long prefill.** Expected: 48-bit counters
   that are read atomically (low word latches high). Task 1 pins it with a forced-wrap
   bench case.

---

## File structure

| file | responsibility | task |
|---|---|---|
| `rtl/a_util_ctr.vhd` | per-port R-beat counters + A-job cycle counter, 48-bit, latch-on-low-read | 1 |
| `rtl/llama_top.vhd`, `rtl/fk33_seam.vhd`, `server/fk33_seam.h` | expose counters through `WIN_SEL = 4` | 1 |
| `rtl/jc_ctl_pkg.vhd` | control-protocol constants (magic, ops, field positions) | 2 |
| `rtl/jc_ctl_frame_core.vhd` | TCK domain: receive ctl frames (TDI), stream status + response buffer (TDO) | 2 |
| `rtl/jc_ctl_exec.vhd` | `clk_core` domain: buffer a frame, execute on PASS as AXI-Lite or HBM read ops, fill response | 3 |
| `rtl/jc_ctl_core.vhd` | frame core + async FIFO + exec + response dual-clock RAM + status sync | 4 |
| `hw/jc/ctl/rtl/jc_ctl_rx.vhd` | BSCANE2 `JTAG_CHAIN => 3` + BUFG wrapper | 4 |
| `hw/jc/ctl/ooc_ctl_core.tcl` | OOC route of `jc_ctl_core` at 200 MHz / 27 MHz TCK | 4 |
| `tools/jc/jc_ctl.py` | host frame build/parse for the ctl protocol; vector generator | 5 |
| `tools/jc/jc_broker.py` | single-owner CoE broker, Unix socket server, die by DNA | 6 |
| `server/fk33_transport_jc.c` | `fk33_transport_open_jc()` over the broker socket; `PL_TRANSPORT_JC` | 7 |
| `hw/jc/card/gen_jc_card.py` | emits `jc_card_bd.tcl` + `jc_card.xdc` + `jc_card_top.vhd` with GENSTAMP | 8 |
| `hw/jc/card/build_card.tcl`, `run_card.sh` | full build; levers patch applied in a scratch tree | 9 |
| `hw/jc/card/ooc_card_200.tcl` | OOC route of the 27B card at 200 MHz on -2L | 10 |
| `hw/jc/host/jc_ctxtest.sh` | N=500 context test over the broker | 12 |

---

### Task 1: A per-port utilisation counters through the seam

**Files:**
- Create: `rtl/a_util_ctr.vhd`, `sim/tb_a_util_ctr.vhd`
- Modify: `rtl/llama_top.vhd` (instantiate, tap A's R handshakes), `rtl/fk33_seam.vhd`
  (window 4), `server/fk33_seam.h` (`FK33_WIN_AUTIL 4`)
- Regenerate: `rtl/fk33_llama_top.vhd` via `tools/gen_cardtop.py`, with the GENSTAMP inputs
  recorded in its current header

**Interfaces:**
- Produces:
  ```vhdl
  entity a_util_ctr is
    generic(NP : positive := 27);
    port(clk, rst : in std_logic;
         in_job   : in  std_logic;                       -- '1' while an A job runs
         rbeat    : in  std_logic_vector(NP-1 downto 0); -- RVALID and RREADY per port
         rd_idx   : in  unsigned(6 downto 0);  -- 0..NP-1 beats, NP job cycles
         rd_hi    : in  std_logic;             -- '0' reads [31:0] and latches [47:32]
         rd_en    : in  std_logic;
         rd_data  : out std_logic_vector(31 downto 0));
  end entity;
  ```
- Seam: `WIN_SEL = 4`, `WIN_ADDR = 2*i` reads the low word of counter i and latches it,
  and `2*i+1` reads the latched high word. Index `i = NP` is the A-job cycle counter.
  Counters reset on `SEQ_RESET` only.

- [ ] **Step 1: Write the failing bench** `sim/tb_a_util_ctr.vhd`, with these cases:
  - Drive 27 ports with a seeded per-port random beat pattern (LFSR per port) for 5,000
    cycles. Half of them have `in_job = '1'`, in 4 windows.
  - Keep an independent count in VARIABLES of `rbeat(i) and in_job` per port and of
    `in_job` cycles, and compare all 28 counters (low and high).
  - Force a wrap: preload through a test-only generic `INIT_HI` so counter 0 starts at
    `2**32 - 3`. Run 10 beats, then check that the low and high reads give
    `2**32 + 7` as a single atomic 48-bit value.
  - Beats outside the job must not count.
  - Print `CHECKS <n>` and fail with `severity failure` on any mismatch.
- [ ] **Step 2: Run it to see it fail.**
  `REGRESS_SCRATCH=~/regress_scratch/t1a bash sim/regress.sh --only tb_a_util_ctr --keep`
  Expected: a FAIL (the entity is missing).
- [ ] **Step 3: Implement `rtl/a_util_ctr.vhd`.** It has NP+1 48-bit counters, increments
  gated by `in_job`, and `rd_data` is registered. A low read copies `cnt(i)(47 downto 32)`
  into `hi_q`, and a high read returns `hi_q`.
- [ ] **Step 4: Run it to see it pass.** Expected: `OVERALL PASS 1`, with the CHECKS count
  printed.
- [ ] **Step 5: Teeth.** Add to `sim/mutate_a_util_ctr.sh` three mutants of
  `rtl/a_util_ctr.vhd`, each of which must FAIL the bench:
  - (a) count `rbeat(i)` without `in_job`;
  - (b) count cycles instead of beats;
  - (c) the high read returns the live high word instead of the latched one.
- [ ] **Step 6: Wire it in.**
  - In `rtl/llama_top.vhd`, instantiate `a_util_ctr` with
    `rbeat(i) = m_rvalid(i) and m_rready(i)` for the 27 data ports, and
    `in_job = a_busy` (A's busy level). Read the entity before choosing the signal names.
  - In `rtl/fk33_seam.vhd`, decode window 4 to `rd_idx`/`rd_hi`/`rd_en`.
  - In `server/fk33_seam.h`, add `#define FK33_WIN_AUTIL 4u`.
  - Regenerate `rtl/fk33_llama_top.vhd` with `tools/gen_cardtop.py` and its GENSTAMP
    inputs. Check the exit status, and diff to confirm only the new instance and ports
    move.
- [ ] **Step 7: Seam bench.** Extend `sim/tb_fk33_seam.vhd` with one case: window 4,
  address 0 and 1, against a stub counter value. Run
  `--only tb_fk33_seam` and `--only tb_a_util_ctr`; both must PASS.
- [ ] **Step 8: Commit.** Stage `rtl/a_util_ctr.vhd`, `sim/tb_a_util_ctr.vhd`,
  `sim/mutate_a_util_ctr.sh`, `rtl/llama_top.vhd`, `rtl/fk33_llama_top.vhd`,
  `rtl/fk33_seam.vhd`, `sim/tb_fk33_seam.vhd` and `server/fk33_seam.h`.

### Task 2: USER3 control frame core (TCK domain)

**Files:**
- Create: `rtl/jc_ctl_pkg.vhd`, `rtl/jc_ctl_frame_core.vhd`, `sim/tb_jc_ctl_frame_core.vhd`,
  `sim/jc_ctl_frame_vec.txt` (generated by Task 5's `gen`; Task 2 commits a hand-checked
  first version produced by the Step 1 script below)

**Protocol (exact).** The slot shape is shared with the loader: `JC_SLOT_BITS = 16384`,
TDI LSB first, header word 0 then 62 payload words of 256 bits, CRC-32 over bits
`0..16127` at bits `16128..16159`. The header word fields are:

| bits | field |
|---|---|
| [31:0] | `JC_CTL_MAGIC = x"4A435431"` ("JCT1") |
| [63:32] | seq |
| [71:64] | op: 1 `WR_INC`, 2 `WR_FIX`, 3 `RD_INC`, 4 `RD_FIX`, 5 `MEM_RD`, 0 `NOP` |
| [87:72] | count of 32-bit items, 1..496 |
| [119:104] | nwords: payload words, `ceil(count/8)` for writes, 0 otherwise |
| [183:120] | addr: AXI-Lite byte offset (ops 1-4) or HBM byte address (op 5, 32-byte aligned, count a multiple of 8) |
| [215:184] | ack_seq: the rsp_seq this frame acknowledges (Ruling 2026-10-07, host-driven ack) |
| [216] | ack_valid |

TDO for every slot:
- bits `0..383` are the status word `JC_CTL_STATUS_BITS = 384`;
- bits `384..384+32*496-1` are the response buffer, word 0 first, each word LSB first;
- the rest are zero.

**Ack rule (Ruling 2026-10-07, after the Task 2 review).** A valid response is re-presented
in every slot until a PASS frame carries `ack_valid = 1` and `ack_seq = rsp_seq`. Only then
does the frame core toggle `rsp_ack_tgl`. An ack of an already-acked seq is ignored, and a
status still showing an acked seq goes out with `rsp_valid = 0` and no words. The executor
gives each response the seq of its own frame, clears `rsp_valid` on the ack, and does not
start another read until then. The host accepts a response only when `rsp_seq`,
`rsp_valid` and `rsp_crc` all check, and otherwise re-polls with a NOP.

Status word fields:

| bits | field |
|---|---|
| [31:0] | `x"4A435354"` ("JCST") |
| [63:32] | `last_done_seq`, the last frame executed |
| [95:64] | `rsp_seq`, the seq whose read data fills this slot's response region; `x"FFFFFFFF"` if none |
| [111:96] | `rsp_count` |
| [112] | `rsp_valid` |
| [113] | `axi_err` (sticky until the next PASS frame) |
| [115:114] | `axi_resp` of the first error |
| [147:116] | `err_seq` |
| [163:148] | desync count |
| [164] | FIFO overflow seen |
| [180:165] | CRC-fail count |
| [212:181] | rsp_crc: CRC-32 (loader conventions) over the rsp_count response words as shifted, computed by the executor |
| [383:213] | zero (forced by the frame core) |

- [ ] **Step 1: Write the failing bench.** The bench drives TCK, CAPTURE and SHIFT with
  real BSCAN timing (TCK only while shifting). It reads frames from
  `sim/jc_ctl_frame_vec.txt`; each line is one slot as 4,096 hex digits LSB-word first,
  then the expected tagged FIFO words. It checks:
  - (a) HDR, DATA and PASS words for a good WR_INC frame of 3 items;
  - (b) FAIL for a corrupted bit;
  - (c) desync++ for a bad magic, with no FIFO words;
  - (d) the TDO bits for a slot equal `status & rsp_buffer` as presented on the `st_in` /
    `rsp_rd_*` stub ports;
  - (e) count > 496 rejected as desync.

  Count checks in variables.
- [ ] **Step 2: Run** `--only tb_jc_ctl_frame_core`. Expected: FAIL.
- [ ] **Step 3: Implement `rtl/jc_ctl_frame_core.vhd`.** Start from `rtl/jc_frame_core.vhd`'s
  receive logic, copied, not edited: the loader file stays untouched. Change the magic and
  the bounds check (`count <= 496`, `nwords <= 62`). Add the TX path:
  - At the slot start, latch `st_in`.
  - Shift it out over bits 0..383.
  - Then read the response RAM through `rsp_addr` (9 bits) and `rsp_q` (32 bits): a
    synchronous read on TCK with one cycle of lookahead, so bit 384 is valid on time.
  - Assert `rsp_ack_tgl` when the slot that carried `rsp_seq` finishes shifting its last
    response bit.
- [ ] **Step 4: Run.** Expected: PASS, with a CHECKS count.
- [ ] **Step 5: Teeth.** Add `sim/mutate_jc_ctl_frame_core.sh` with four mutants that
  must FAIL:
  - drop the CRC compare;
  - shift the response by one bit;
  - accept count 497;
  - ack before the last bit.
- [ ] **Step 6: Commit** the four files plus the mutate script.

### Task 3: control executor (`clk_core` domain)

**Files:** Create `rtl/jc_ctl_exec.vhd`, `sim/tb_jc_ctl_exec.vhd`, `sim/axil_slave_model.vhd`
(an independent recorder: a 64 KB register array, a transaction log, and a configurable
SLVERR address).

**Interfaces:**
- Consumes the FIFO word stream `TAG & word(256)` from Task 2 through the async FIFO.
- Produces:
  - an AXI-Lite master (32-bit address and data);
  - an AXI4 read-only master (33-bit address, 256-bit data, ARLEN up to 15, AXI3-safe);
  - a response RAM write port (`rsp_we`, `rsp_waddr(8:0)`, `rsp_wdata(31:0)`);
  - status fields toward `jc_status_sync`, and `rsp_ack` (synchronised in).

- [ ] **Step 1: Write the failing bench.** Use the slave model behind the master and an
  HBM read model (reuse `sim/jc_axi3_mem.vhd` read side, seeded). Cases:
  - (a) WR_INC 5 words then RD_INC 5: the recorder log equals the 5 writes in order, and
    the response RAM equals them;
  - (b) WR_FIX 300 words to WIN_DATA: 300 writes to one address, in order;
  - (c) a FAIL frame: 0 AW handshakes;
  - (d) SLVERR at one address: `axi_err = 1`, `err_seq` = that frame, and later ops still
    run;
  - (e) MEM_RD 64 words at a 4 KB-crossing address: split into legal bursts, data equals
    the model;
  - (f) read B issued before read A's ack: B waits; the response RAM is not overwritten
    until `rsp_ack`.
- [ ] **Step 2: Run** `--only tb_jc_ctl_exec`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Buffer up to 62 payload words in a frame RAM. Discard them on FAIL.
  - On PASS, run the op: one AXI-Lite transaction at a time, or bursts on MEM_RD that
    never cross 4 KB and are at most 16 beats.
  - Write read data into the response RAM. Publish `rsp_seq`/`rsp_count`/`rsp_valid`,
    and wait for `rsp_ack` before the next read op.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Teeth.** Add `sim/mutate_jc_ctl_exec.sh` with mutants that must FAIL:
  - execute on HDR instead of PASS;
  - WR_FIX increments the address;
  - ignore BRESP;
  - no wait for ack;
  - a burst crosses 4 KB.
- [ ] **Step 6: Commit.**

### Task 4: `jc_ctl_core`, the USER3 wrapper and OOC route

**Files:** Create `rtl/jc_ctl_core.vhd`, `hw/jc/ctl/rtl/jc_ctl_rx.vhd`,
`hw/jc/ctl/ooc_ctl_core.tcl`, `hw/jc/ctl/jc_ctl_timing.tcl`, `hw/jc/ctl/README.md`,
`sim/tb_jc_ctl_core.vhd`.

- [ ] **Step 1: Failing bench.** It runs `jc_ctl_core` end to end: TCK at 27 MHz, aclk at
  200 MHz, the slave model, and the vector file. It writes 496 words to a window, reads
  them back, and checks the TDO response region against the written data. It also covers
  a CRC fail followed by a retry with the same seq.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Instantiate `jc_ctl_frame_core`, then `async_fifo` (the loader's instance shape,
    258 x 128), then `jc_ctl_exec`.
  - The response RAM is a true dual-port BRAM: aclk writes, TCK reads.
  - The status word comes through `jc_status_sync` (instantiated, not edited).
  - The `rsp_ack` toggle uses a 2-FF synchroniser with `ASYNC_REG`.
  - `jc_ctl_rx.vhd` is `jc_frame_rx.vhd`'s shape with `JTAG_CHAIN => 3`.
- [ ] **Step 4: Run** `--only tb_jc_ctl`. Expected: every `tb_jc_ctl*` row PASSES.
- [ ] **Step 5: OOC script.** `ooc_ctl_core.tcl` mirrors
  `hw/jc/loader/ooc_loader_core.tcl`:
  - synth, opt, place, phys_opt, route at 200 MHz aclk and 27 MHz TCK;
  - the CDC bounds go in `jc_ctl_timing.tcl` as procs;
  - sentinels `^JCCTL_OOC_DONE` and `^JCCTL_OOC_ROUTE routing_errors 0`.

  The implementer writes the script and does NOT run Vivado. The controller runs it
  (budget: ~4.4 GB, measured for the loader core).
- [ ] **Step 6: Commit.**

### Task 5: host ctl protocol library and vectors

**Files:** Create `tools/jc/jc_ctl.py`, `tools/jc/test_jc_ctl.py`; regenerate
`sim/jc_ctl_frame_vec.txt` with `python3 tools/jc/jc_ctl.py gen sim/jc_ctl_frame_vec.txt`.

**Interfaces (produces):**
```python
MAGIC = 0x4A435431; STAT_MAGIC = 0x4A435354; MAX_ITEMS = 496
OP_NOP, OP_WR_INC, OP_WR_FIX, OP_RD_INC, OP_RD_FIX, OP_MEM_RD = 0, 1, 2, 3, 4, 5
def build_slot(seq: int, op: int, addr: int, items: list[int] | None, count: int) -> bytes  # 2048 bytes, LSB-first bit order as shifted
def parse_tdo(slot: bytes) -> dict  # keys: last_done_seq, rsp_seq, rsp_count, rsp_valid, axi_err, axi_resp, err_seq, desync, ovf, crc_fail, rsp (list[int])
```

- [ ] **Step 1: Failing tests.**
  - `build_slot` round-trips through an independent decoder written in the test, not
    through `parse_tdo`.
  - The CRC matches `zlib.crc32` over the first 16,128 bits packed LSB first.
  - `count` 0 and 497 raise ValueError.
  - WR ops need `len(items) == count`.
  - MEM_RD needs a 32-byte-aligned address and a count that is a multiple of 8.
  - `parse_tdo` rejects a bad STAT magic.
- [ ] **Step 2: Run** `cd tools && python3 -m pytest jc/test_jc_ctl.py -q`. Expected:
  FAIL.
- [ ] **Step 3: Implement**, plus a `gen` subcommand that writes the Task 2/4 vector file.
- [ ] **Step 4: Run.** Expected: PASS. Then re-run `--only tb_jc_ctl` against the
  regenerated vectors; it must PASS.
- [ ] **Step 5: Commit.**

### Task 6: broker

**Files:** Create `tools/jc/jc_broker.py`, `tools/jc/test_jc_broker.py`.

**Interfaces (produces):** Unix socket protocol, one JSON line per request and response.
```
{"die":"A","op":"rd32","off":N}                -> {"ok":true,"val":V}
{"die":"A","op":"wr32","off":N,"val":V}        -> {"ok":true}
{"die":"A","op":"wrn","off":N,"fix":true,"vals":[...]}
{"die":"A","op":"rdn","off":N,"fix":false,"n":K} -> {"ok":true,"vals":[...]}
{"die":"A","op":"memrd","addr":A,"n":K}        -> {"ok":true,"hex":"..."}
{"op":"status"}                                -> {"ok":true,"dies":{...},"connections":C}
any failure                                    -> {"ok":false,"err":"<class>: <msg>"}
```

CLI: `jc_broker.py serve --bmc IP --chain AB --dies FILE --sock PATH [--hz] [--reconnect-secs]`.
- Die selection is by DNA from `--dies`, through the same `_identify` logic as
  `coe_load.py`; import it, do not copy it.
- Ops are split into slots of at most 496 items. The broker keeps one outstanding read
  per die.
- Reconnects use `coe_load`'s `CoeTransport` and the same proactive rule.
- `memrd` refuses addresses inside the weight image unless `--allow-image-read` is set.
  The image-record read is allowed, because its address comes from the manifest.

- [ ] **Step 1: Failing tests** against a `FakeCtlDie` built on `jc_ctl`'s
  frame model. It executes slots against a dict register file and its own seeded HBM.
  Cases:
  - rd32 and wr32 round trip;
  - wrn 5,120 items to a fixed window: 11 slots, order preserved;
  - rdn 5,120;
  - a second client refused;
  - `axi_err` raised as `{"ok":false}`;
  - after a reconnect the fake swaps the two dies' DNA, and the next request aborts with
    a DNA mismatch;
  - a CRC fail on one slot is retried exactly once and succeeds;
  - `IRNotAllowed` is never retried.
- [ ] **Step 2: Run** `cd tools && python3 -m pytest jc/test_jc_broker.py -q`. Expected:
  FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole `jc/` suite. Expected: PASS (296 + new).
- [ ] **Step 5: Commit.**

### Task 7: C transport

**Files:** Create `server/fk33_transport_jc.c`, `server/test_transport_jc.c`; modify
`server/fk33_transport.h` (declaration), `server/pl_backend.h` (`PL_TRANSPORT_JC`,
`jc_sock`, `jc_die`), `server/pl_backend.c` (the switch case), `server/Makefile`.

**Interfaces (produces):**
```c
fk33_transport *fk33_transport_open_jc(const char *sock_path, const char *die);
```
- `reg_read32` and `reg_write32` map to rd32 and wr32. `mem_read` maps to memrd.
- `mem_write` returns `-EPERM` with a message: the loader is the only HBM writer.
- A short or `ok:false` reply returns a negative code.
- `WIN_DATA` loops in `pl_backend.c` stay as they are. The transport coalesces runs of
  writes to `FK33_SEAM_WIN_DATA` into one `wrn` with `fix:true`, flushing before any
  other access. The test proves that order is preserved.

- [ ] **Step 1: Failing C test.** A forked fake broker on a socketpair, scripted. Cases:
  - read and write;
  - 5,120 WIN_DATA writes become 1 wrn of 5,120, and a following rd32 flushes first;
  - mem_write is refused;
  - `ok:false` gives a negative return code.
- [ ] **Step 2: Run** `make -C server test_transport_jc && ./server/test_transport_jc`.
  Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. Also run the existing `make -C server` tests;
  they must still pass.
- [ ] **Step 5: Commit.**

### Task 8: Jungle Cat card BD generator

**Files:** Create `hw/jc/card/gen_jc_card.py`, `hw/jc/card/test_gen_jc_card.py`; generated
`hw/jc/card/jc_card_bd.tcl`, `hw/jc/card/jc_card.xdc`, `hw/jc/card/jc_card_top.vhd`.

Content of the generated BD:
- IBUFDS (BC26/BC27);
- clk_wiz: out1 100 MHz APB, out2 200 MHz HBM ref, out3 `CLK_CORE_MHZ` (default 200);
- HBM, 2 stacks, every enabled SAXI's `ACLK` = out3, mapped as:
  - SAXI_00: loader;
  - SAXI_01..15 and SAXI_17..29: card A m00..m27, in the FK33 order;
  - SAXI_16: smartconnect fed by `jtag_hbm` and the ctl core's read master;
  - SAXI_30 and SAXI_31: B and C, assigned as `gen_pcieep.py`'s card block assigns
    them;
- the loader module reference, unchanged;
- the ctl module reference;
- `fk33_card` with the 27B generics;
- the fan and LED pins from `hw/jc/loader/jc_loader.xdc`;
- no XDMA and no PCIe.

- [ ] **Step 1: Failing test.** `test_gen_jc_card.py` parses the generated tcl. It asserts:
  - the exact SAXI-to-master map, read from `gen_pcieep.py`'s card port list by
    importing it, not from a copied table;
  - every `CONFIG.USER_AXI_*_CLK` uses one net;
  - no `xdma` cell exists;
  - exactly one BSCANE2 for each of chains 3 and 4 in the top;
  - `CLK_CORE_MHZ` is reflected in the clk_wiz CONFIG;
  - the GENSTAMP block is present with no timestamp, user, host or path.
- [ ] **Step 2: Run** `python3 -m pytest hw/jc/card/test_gen_jc_card.py -q`. Expected:
  FAIL.
- [ ] **Step 3: Implement the generator.** Reuse `gen_pcieep.py`'s card emission by
  import where it is a function. Where it is inline, factor it into a function in
  `gen_pcieep.py`, and prove byte-identical regeneration of `build_fk33_pcieep.tcl`
  in a scratch copy with its GENSTAMP inputs.
- [ ] **Step 4: Run.** Expected: PASS. The FK33 regeneration diff is empty.
- [ ] **Step 5: Commit.**

### Task 9: full build script (written, not run)

**Files:** Create `hw/jc/card/build_card.tcl`, `hw/jc/card/run_card.sh`,
`hw/jc/card/README.md`.

`run_card.sh <root>` does the following:
- copies the tracked tree into `<root>/src`;
- applies `build12_levers_off.patch` there and refuses if it does not apply cleanly;
- records `git rev-parse HEAD` plus the patch's sha256;
- runs Vivado under `hw/jc/loader/run_capped.sh` with `MemoryHigh=24G` and a 30 GB swap
  guard;
- harvests the utilisation, timing and CDC reports;
- writes the `^JCCARD_DONE` or `^JCCARD_FAIL <reason>` sentinels.

`build_card.tcl` checks that the BSCAN census has exactly one chain-3 and one chain-4
instance. It refuses `write_bitstream` on WNS < 0, unless `-tclargs ... allow_neg` is
given.

- [ ] **Step 1: Failing test.** In a dry-run mode, `run_card.sh --dry-run <scratch>` prints
  the exact commands and the parameter bindings. The test asserts:
  - the patch is applied;
  - the part string is `xcvu35p-fsvh2104-2L-e`;
  - `CLK_CORE_MHZ=200`;
  - the cap is 24G and the guard is 30G.
- [ ] **Step 2 to Step 4:** implement, run the dry-run test to PASS, and commit. No Vivado.

### Task 10: OOC route of the 27B card at 200 MHz (controller runs it)

**Files:** Create `hw/jc/card/ooc_card_200.tcl` (modelled on the existing
`ooc_card_vu35.tcl` in `/mnt/storage/fk33_builds/ooc27_vu35/`, with `route_design`).

- [ ] **Step 1:** The implementer writes the script and a dry-run check that grep-asserts
  `route_design`, the -2L part, the 5.000 ns clock and the levers-patched source tree.
- [ ] **Step 2: The controller runs it**, alone on the workstation, under the cap. Before
  dispatching, state the budget: current resident memory, the peak (ESTIMATE ~4-8 GB from
  the recorded 2.58 GiB for `fk33_card` OOC on the VU35P), and what is left. Report routed
  WNS, the worst 10 paths, and utilisation.
- [ ] **Step 3:** Record the result in `hw/jc/card/README.md` and commit.

### Task 11: full build (controller; needs Oren's go-ahead to stop `llama-server`)

- [ ] **Step 1:** Ask Oren through AskUserQuestion: stop `llama-server` for the build
  window?
- [ ] **Step 2:** Run `run_card.sh /mnt/storage/fk33_builds/jccard1`. Gate on
  `^JCCARD_DONE`. Copy the `.bit`, `.ltx` and reports into
  `hw/jc/card/results/<date>/` as soon as the sentinel appears.
- [ ] **Step 3:** Record the memory peak (`memory.peak` together with
  `memory.swap.current`, from a run that did not reach its cap), routed WNS, and the
  census. Commit.

### Task 12: silicon (main session only)

- [ ] **Step 1:** Program both dies with the card bitstream through `sqrl_bridge`, one
  file per invocation, because it loads only the first file of a list. Check identity
  with `coe_load.py identify`.
- [ ] **Step 2:** Load both 27B images with `coe_load.py load` (one run each), then run
  `verify` and the spot check (1,000 windows per die).
- [ ] **Step 3:** Start `jc_broker.py serve`. Bring up through `pl_pipeline` with
  `PL_TRANSPORT_JC` on dies A and B. Read the seam ID, CAPS and the imglock record on
  both dies.
- [ ] **Step 4:** Generate the first token for the reference prompt. Its argmax must equal
  the CPU reference argmax for Qwen3.8-27B. Produce the reference with
  `llama.cpp` on the same GGUF and the same prompt, and record its command.
- [ ] **Step 5:** Write `hw/jc/host/jc_ctxtest.sh`, ported from
  `hw/fk33/host/fk33_ctxtest.sh` with the transport swapped. Run `pair` at N=500, input
  and output, twice, gated on `^CTXTEST_PASS`.
- [ ] **Step 6:** Read window 4 on both dies after one token. Report each port's beats
  divided by the job cycles, and the token time. Write
  `docs/debugging/2026-10-xx_jc-27b-first-token.md` with the evidence.
- [ ] **Step 7:** Commit the results and update `docs/WORKLOG.md`.
