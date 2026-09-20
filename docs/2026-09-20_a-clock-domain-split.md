# The A clock-domain split: subsystem A on its own clock (TRACK ACLK, 2026-09-20)

**Status: designed, implemented behind `FK33_ENG_SPLIT_CLK=1` (default OFF),
verified by bench and mutation, NOT YET BUILT.** Nothing here has been through
synthesis, placement or a routed timing report; section 8 lists exactly what a
routed build has to establish before the switch can be turned on for a card
image.

Oren's question, verbatim: *"can we not clock the blocks that have more cycles
faster? Target those first for higher clock?"*

## 1. The motivation, MEASURED

`hw/fk33/results/card_swg_2026-09-20/bd_wrapper_timing_summary_routed.rpt`:
the shipped card runs everything -- A's engine with its 28 HBM masters, B, C,
D and the vector ops -- on `clk_wiz_0/clk_out3` at 75 MHz, WNS +0.299 ns of a
13.333 ns period. The worst core-clock paths are 0.5 ns logic / 12.0 ns route
(`u_fetch/issue_r_reg` into B's `qkv_b_reg` LUTRAM write enables) and 0.2 ns
logic / 12.4 ns route (`core_reset` into A's `ns_rep`/`os_rep` registers): the
design is route-bound at 83% LUT, not logic-bound. The engine-only build (A
alone, `hw/fk33/pcieep_build.sh` without `FK33_CARD`) closed at 200 MHz
(`docs/debugging/2026-09-04_first-pcieep-bitstream.md`,
`2026-09-05_cross-machine-bitstream-identity.md`).

Per-opcode cycles of the token-0 profiles in
`hw/fk33/results/card_swg_2026-09-20/profile/` (MEASURED, summed with awk):

| image | A_JOB (311 steps) | B_JOB (24) | C_JOB (8) | VEC_* (161) | token |
|---|---:|---:|---:|---:|---:|
| flat | 42,686,358 (69.0%) | 15,854,607 (25.6%) | 594,472 | 2,771,688 | 61,907,125 = 0.8254 s |
| striped | 10,894,638 (36.2%) | 15,854,448 (52.6%) | 594,472 | 2,771,688 | 30,115,246 = 0.4015 s |

## 2. The seam, mapped from the generator and the RTL

`hw/fk33/gen_pcieep.py` wires exactly twelve signal-level nets between the
`card` cell (`fk33_card`) and the `eng` cell (`fk33_engine`), in two tables,
plus one AXI interface. Widths are from `hw/fk33/rtl/fk33_engine.vhd` and
`hw/fk33/rtl/fk33_card.vhd`; the class is from the driver's own contract
(`rtl/matvec_int4_desc_axi.vhd`, `rtl/a_desc_adapter.vhd`,
`rtl/fk33_llama_top.vhd` ga_desc arm).

| table | card pin | engine pin | width | dir | class |
|---|---|---|---:|---|---|
| CARD_SEAM_TO_ENG | `a_job_index` | `job_index` | 32 | card->eng | quasi-static: changes at job retire; read by the engine at S_CHECK only when `CHECK_JOB_INDEX` (false on the card) |
| | `a_x_we` | `d_x_we` | 1 | card->eng | push stream, NO ready: one element per card cycle, `j_cols` back to back (S_XRD) |
| | `a_x_waddr` | `d_x_waddr` | 16 | card->eng | payload of the push |
| | `a_x_wdata` | `d_x_wdata` | 16 | card->eng | payload of the push |
| | `a_x_exp` | `d_x_exp` | 32 | card->eng | quasi-static: written at the card's S_GO (the edge the first AXI write is armed), read by the engine at S_CHECK after the GO |
| CARD_SEAM_FROM_ENG | `a_y_we` | `d_y_we` | 1 | eng->card | beat stream, NO ready: matvec_core S_EMIT emits a job's tiles back to back, one per engine cycle, up to `A_MAXROWS/ROWS_IF` = 256 beats |
| | `a_y_addr` | `d_y_addr` | 16 | eng->card | payload (tile base row) |
| | `a_y_data` | `d_y_data` | 3072 | eng->card | payload (48 x 64) |
| | `a_y_mask` | `d_y_mask` | 48 | eng->card | payload |
| | `a_y_exp` | `d_y_exp` | 32 | eng->card | payload; the card reads it again AFTER done (`yexp <= a_y_exp` in S_DONE) |
| | `a_job_done` | `d_job_done` | 1 | eng->card | LEVEL: set at completion, cleared by the next GO write, masked on the GO cycle |
| | `a_job_err` | `d_job_err` | 1 | eng->card | LEVEL, STICKY: only reset clears it |
| intf `card/a` -> `engctl/S01` | `a_aw*`,`a_w*`,`a_b*` | `s_axi_*` (via smartconnect) | 12-bit addr, 32-bit data | card->eng | AXI-Lite WRITE-ONLY: three writes per job (DESC_PTR_LO, DESC_PTR_HI, CTRL=GO) |

Descriptor fields, `u_index`, the arena base and the KV/BST bases do NOT cross
this seam: the descriptor is fetched by the engine's own 28th master from HBM,
`u_index` becomes an address inside `a_desc_adapter` (card side), and the bases
go from `fk33_seam` to the card (`SEAM_TO_CARD`) and never touch the engine.
`seq_rst` is `fk33_seam -> card` only. `a_jobs_issued` is a card output with no
engine counterpart and is unconnected today.

Clocks and resets today (from `_eng_block`, `_card_block`, `_core_reset_lines`):

| pin | today | class |
|---|---|---|
| `eng/core_clk` | `clk_wiz_0/clk_out3` (75 MHz on the card build) | compute AND both AXI-Lite slaves (`s_axi`, `s_axix`) |
| `eng/hbm_aclk` | `xdma/axi_aclk`, 250 MHz | all 28 HBM masters; the crossing is INSIDE `rtl/axi_rd_port.vhd` (per-port `async_fifo`) |
| `hbm/AXI_nn_ACLK` (28 engine ports) | `xdma/axi_aclk` | unchanged by the split |
| `eng/core_aresetn` | `core_reset/peripheral_aresetn` | proc_sys_reset, `ext_reset_in = xdma/axi_aresetn`, `dcm_locked = clk_wiz_0/locked` |
| `card/clk`, `bcgrant/clk`, `fk33_seam/clk` | `clk_wiz_0/clk_out3` | |
| `fk33_therm_0/compute_clk` | `clk_wiz_0/clk_out3` | `compute_halt` is defined synchronous to it |
| `clk_wiz_0` | in `xdma/axi_aclk`; out1 100 MHz (APB), out2 200 MHz (HBM_REF_CLK), out3 `FK33_ENG_CORE_MHZ` | |
| `axil2eng` | NUM_CLKS 2: `aclk` xdma, `aclk1` clk_out3 | host AXI-Lite into the core domain |
| `engctl` | NUM_CLKS 2: `aclk` xdma, `aclk1` clk_out3 | 2:1 onto `eng/s_axi` (host + card) |

**So the 28 HBM ports already run at 250 MHz and the split does not move
them.** That is the same arrangement as the engine-only 200 MHz build, and it
is why the split is a change to ONE clock pin of the engine and not to the
memory side.

## 3. The boundary and the crossing per class

`FK33_ENG_SPLIT_CLK=1` (with `FK33_CARD=1`; refused otherwise) makes the
generator emit:

- `clk_wiz_0` CLKOUT4 at `FK33_ENG_FAST_MHZ` (default 200.000).
- `fast_reset`, a second `proc_sys_reset` with `slowest_sync_clk = clk_out4`,
  `dcm_locked = clk_wiz_0/locked`, `ext_reset_in = xdma/axi_aresetn`.
- `eng/core_clk = clk_out4`, `eng/core_aresetn = fast_reset/peripheral_aresetn`,
  `fk33_therm_0/compute_clk = clk_out4`.
- `axil2eng` and `engctl` at NUM_CLKS 3 with `aclk2 = clk_out4`.
- the cell `eng_cdc` (`rtl/fk33_eng_cdc.vhd`) between `card` and `eng`, every
  table row wired `card/<pin> -> eng_cdc/<pin>` and `eng_cdc/<pin> -> eng/<pin>`
  (the wrapper's card face carries the card's pin names and its engine face the
  engine's), `card/a -> eng_cdc/sa` and `eng_cdc/ma -> engctl/S01`.
- the XDC line `set_clock_groups -asynchronous` between the clocks on
  `bd_i/eng/core_clk` and `bd_i/card/clk`, under a sentinel comment.

Everything else (B, C, D, the grant, the seam, the vector ops) stays on
`clk_out3`.

The card side was written for one clock, and its correctness rests on three
orderings a single clock gives for free. The wrapper reproduces each one
structurally, by handshake, so that no claim depends on the clock ratio or on
route delay:

| class | signals | crossing | why this shape |
|---|---|---|---|
| push stream | `a_x_*` | `async_fifo` W=32 D=16, card writes, engine pops unconditionally; sticky `x_ovf` if pushed while full | no ready on either end; with the engine faster it never holds more than one or two |
| beat stream | `a_y_*` | `async_fifo` W=3168 D=256 (44 RAMB36), engine writes, card pops unconditionally; sticky `y_ovf` | beats arrive back to back at the engine clock and the card has no ready, so the FIFO must hold a WHOLE JOB (256 = `A_YWORDS`); then no ratio can overflow it, and the done ordering below guarantees it is empty before the next job |
| AXI-Lite write | `sa_*` -> `ma_*` | toggle handshake, payload (addr, data, strb) registered two card cycles BEFORE the toggle flips and untouched until the response returns; response (`bresp`) the same way back | one outstanding write, three per job |
| quasi-static words | `a_x_exp`, `a_job_index` | CAPTURED WITH EACH WRITE REQUEST and presented on the engine side before the write executes | the card writes `a_x_exp` on the edge it arms the job's first write and the engine reads it after the GO; carrying it with the GO makes "settled before the pulse" a property of the handshake rather than of two latencies |
| done | `d_job_done` -> `a_job_done` | RISING-EDGE EVENT via a toggle; `a_job_done` set on the event, CLEARED when the next write is accepted | a level synchroniser leaks the previous job's `done` into the next S_WAIT (a_desc_adapter's correctness argument is "the GO that put us here cleared done_l"); an event cannot be cleared before it was seen because the adapter holds S_DONE until `u_ack` |
| err | `d_job_err` | two-flop level synchroniser, OR-ed with `x_ovf` and `y_ovf` | sticky and monotone: no stale window |

The three orderings, and where each is enforced:

1. **x before the first write.** Card side accepts a write only when the x
   FIFO's write side sees the read pointer caught up (`w_level =
   OUT_MARGIN + 1` and no push this cycle or the last); engine side executes it
   only when the FIFO's output stage is empty and the last `d_x_we` has been
   presented.
2. **done is never the previous job's.** The event scheme above.
3. **every y beat before done.** Engine side flips the done toggle only after
   the y FIFO's write side sees the read pointer caught up; card side raises
   `a_job_done` only after its output stage is empty and the last `a_y_we`
   pulse has gone out.

Each of (1) and (3) is enforced on BOTH sides; the mutation table in section 6
shows each half alone still orders the traffic under the bench's stimulus and
the pair is what the bench can kill.

One behavioural difference at the seam's edge, recorded rather than hidden: a
GO refused by the thermal halt (`fk33_engine` masks the GO bit) leaves `done`
high with no new rising edge. On one clock the adapter completes such a job
instantly and silently; through the wrapper it waits forever, which the host's
watchdog sees. A hang is preferred to a silent skip.

## 4. Why `rtl/async_fifo.vhd` and not `xpm_fifo_async`

Subsystem A already carries a gray-pointer dual-clock FIFO with ASYNC_REG
synchronisers, a registered full flag, a BRAM-inferring memory, its own bench
(`sim/tb_async_fifo.vhd`) and mutation table (`sim/mutate_async_fifo.sh`), and
it is in every engine build's source list (`ENG_SRCS`). XPM would need a
`library beh` stand-in for GHDL -- a second implementation free to disagree
with the first -- and `sim/regress.sh` would have to carry the wrapper's bench
as a netlist-side row like the `sim/post_*.vhd` benches that need UNISIM. The
project's own FIFO costs nothing new and its four-phase clear is simply tied
off.

MEASURED on the bench's first run: `async_fifo`'s read side pops TWO beats
per THREE rclk cycles with `q_ready` held high (`do_rd` is gated on `ocnt +
inflight < 2`). This is why the swapped-ratio phase throttles x pushes to one
per five card cycles, and why the y FIFO's whole-job depth matters more than
the ratio: a 256-beat lm_head window at 200/75 MHz leaves ~192 beats resident
(peak), and drains in 256 x 20 ns = 5.1 us against a job of ~500 us.

## 5. Reset

Two `proc_sys_reset`s, both with `ext_reset_in = xdma/axi_aresetn` and
`dcm_locked = clk_wiz_0/locked`: `core_reset` (card, seam, grant, the
wrapper's card side) and `fast_reset` (engine, `fk33_therm_0/compute_clk`, the
wrapper's engine side). The brief asked for the fast domain to be released
after the slow one; it is NOT chained that way, for two reasons:

- `check_reset_topology` (STRAY-NEXTJOB) requires the engine's reset to be the
  `peripheral_aresetn` of a `proc_sys_reset` whose `ext_reset_in` IS the HBM
  slaves' reset net. A chain through `core_reset` is a descendant too, but the
  guard compares the immediate driver and would refuse it; its nine teeth rows
  retarget to `fast_reset` under the switch and all pass (T1-T7 refused, T8/T9
  accepted, T0 control accepted).
- `rtl/fk33_eng_cdc.vhd` is written so the order does not matter: every
  cross-domain source register (pointers, toggles, the err level) resets to
  '0' and every receiver's reference register resets to '0', so a side that is
  out of reset while the other is held sees "no event, empty FIFO". The bench
  releases the engine side first in phase 1 and the card side first in phase 2.

`seq_rst` does not cross this seam (it is `fk33_seam -> card`).

## 6. Verification

`sim:tb_eng_cdc` (auto-discovered gate row): card and engine models on
13.333 / 5 ns, then the swapped 5 / 13.333 ns with a 12-element back-to-back
tail on the x pushes, then the two overflow phases and the sticky err. 11,678
checks, `OVERALL PASS 1`.

`sim/mutate_eng_cdc.sh`, 15 rows, all as expected (MEASURED):

| row | verdict | mutation |
|---|---|---|
| W1 | SURV | card side forwards a write without the x read-out wait (first half of ordering 1) |
| W2 | SURV | engine side executes without the x output-stage wait (second half) |
| W12 | **KILL** | both x waits removed: the attribution control for the pair |
| W3 | SURV | engine side sends done without the y read-out wait (first half of ordering 3) |
| W4 | SURV | card side raises done without the y output-stage wait (second half) |
| W34 | **KILL** | both y waits removed |
| W5 | **KILL** | a write no longer clears `a_job_done` (ordering 2) |
| W6 | **KILL** | done crosses as a LEVEL: the naive design |
| W7 | SURV | done toggle taken from the FIRST synchroniser flop (one stage) |
| W8 | SURV | payload and toggle flip on the same edge |
| G1 | SURV | gray encode and decode both identity (binary pointers) |
| G2 | **KILL** | encoder only: the control that makes G1 readable |
| F1 | ABORT | full flag late by one: `async_fifo`'s own assert in the overflow phase |
| F2 | SURV | full flag early by one |
| C0 | SURV | unmutated control |

The survivors are the resolution floor of a zero-delay RTL simulation and are
the point of the table: a functional bench samples atomically, so a binary
pointer crosses as cleanly as a gray one and one flop is as good as two.
`sim/gray_check.sh` guards the gray property statically; ASYNC_REG on every
synchroniser and `report_cdc` on the implemented design (emitted into the build
script under `FK33_ENGSPLIT`) are the guards for W7/W8. W12 survived the first
version of the bench: the request path's own latency (five card cycles plus
five engine cycles) exceeds the x FIFO's at either ratio and ordered them by
luck; the 12-element tail burst is what made ordering (1) reachable.

Generator gate rows, with the switch OFF then ON (`OVERALL PASS n`):
`sim:runguard` PASS 1 / PASS 1; `sim:cardtop` PASS 3 / PASS 3; `sim:fk33card`
PASS 1 / PASS 1 (see the WORKLOG entry for the ON lines). The `--selftest`
also passes in the engine-only and `FK33_ENG=0` configurations. Byte-identity
with the switch off: regenerated with `FK33_CARD=1 FK33_CB_STYLE=distributed
FK33_ENG_CORE_MHZ=75`, `git diff --quiet hw/fk33/build_fk33_pcieep.tcl
hw/fk33/fk33_pcieep.xdc` is empty (MEASURED), and `split_gate_teeth` asserts no
split fragment is in the generated text when off and every fragment is when on.

New checks in `gen_pcieep.py`: `check_cdc_pins` (every seam pin on both faces
plus the two AXI-Lite faces and the four clock/reset pins, 48 names, refused at
generation time; teeth remove one port on each face and the check names it),
the live-cell existence check `FK33_ENGCDC` on all 24 seam pins, the
ASSOCIATED_BUSIF read-back on both wrapper clocks, and the implemented-design
check `FK33_ENGSPLIT` (card and engine clocks distinct, `bd_i/eng_cdc`
present with at least ten ASYNC_REG cells, `report_cdc` both ways, its own
utilization report). `FK33_UNCONNECTED` covers the new cell by construction:
it walks every module-reference cell's input pins.

## 7. What it should buy (DERIVED, with the assumptions stated)

An `A_JOB` step in the profile is NOT all engine time. From the manifest
shapes (`/mnt/storage/llama-models/qwen35-9b-mv4i/manifest.json`) and the
card top's FSM: the card pushes `K + 2` x elements per job at ITS clock
(S_XRD) and drains `M` rows per non-lm_head tensor at ITS clock (S_DRAIN):

```
push  sum(K+2) over 311 jobs      = 1,536,622 cycles
drain sum(M) over drained tensors = 1,426,944 cycles
card-side                         = 2,963,566 cycles  (27.2% of striped A_JOB)
engine-side, striped              = 7,931,072 cycles over ~5,184,384 beats = 1.53 cycles/beat
```

1.53 cycles/beat at 75 MHz is the datapath floor (the ideal-memory simulation
in `docs/debugging/2026-08-30_counters-cycles-beats-starved.md` gave 1.60 with
fixed overhead): **at 75 MHz the striped A is compute-bound and its memory is
idle three cycles in four.** The same striping on the 200 MHz engine-only
build MEASURED **2.03 cycles/beat** (WORKLOG, "THE STRIPING EXPERIMENT RAN ON
SILICON"), i.e. 10.15 ns per beat.

The memory-side assumption. The busiest pseudo-channel carries 2 lanes
(census `{(25,2): 249}`); one PC delivers 32 B per ACLK cycle at 250 MHz, so
two lanes each get a 32 B beat every 8.0 ns, and a weight word needs one beat
per lane: the supply bound is **8.0 ns per beat = 1.6 cycles at 200 MHz**, the
same number as the datapath floor. The measured 10.15 ns is 27% above both.
So **at 200 MHz with two lanes per PC, A is within 21% of the busiest-PC
supply bound and 27% above its datapath floor: not cleanly bound by either,
and the 2.03 figure is the joint measurement the projection uses.** It does
not improve by clocking the core faster than 200 MHz; the next lever there is
one lane per PC (27 PCs of 32).

Token time with the engine at 200 MHz, everything else at 75 MHz:

| | now (MEASURED) | with the split (DERIVED) | ratio |
|---|---:|---:|---:|
| striped, A engine-side | 7,931,072 / 75 MHz = 0.1057 s | 5,184,384 x 10.15 ns = 0.0526 s | 2.01x |
| striped, A card-side | 2,963,566 / 75 MHz = 0.0395 s | 0.0395 s | 1 |
| striped, A_JOB total | 0.1453 s | 0.0921 s | 1.58x |
| striped, rest (B, C, VEC) | 19,220,608 / 75 MHz = 0.2563 s | 0.2563 s | 1 |
| **striped, token** | **0.4015 s** | **0.3484 s** | **1.15x** |
| flat, A engine-side | 39,722,792 / 75 MHz = 0.530 s | 5.18 M x 108 ns = 0.560 s (single-PC bound, clock-independent) | ~1 |
| **flat, token** | **0.8254 s** | **~0.83 s** | **1.0x** |

Assumptions: (a) the engine's cycles per beat at 200 MHz on the card equal the
engine-only measurement (2.03), which shares the memory layout and the ACLK;
(b) the card-side cycles are unchanged, since D, the x push and the drain stay
at 75 MHz; (c) the per-job fixed engine overhead (descriptor fetch, x load,
S_CHECK) is folded into cycles/beat; (d) B, C and the vector ops are
untouched. The naive projection "all A_JOB cycles at 200 MHz" gives 0.3107 s
(1.29x) and is wrong by the 27% card-side share plus the 2.03/1.53 memory
effect.

The honest answer to the question. By cycles, B (15.85 M, 52.6% of the
striped token) is the bigger block, not A (7.93 M engine-side). A is the one
whose 200 MHz is MEASURED on silicon; B's real fmax is UNKNOWN (CLAUDE.md:
its harness has no memory-sourced weights and its -4.008 ns figure measured
stimulus, not the design). This split is therefore the measured-safe lever
worth 15% of a striped token; B's 660k-cycle job
(`docs/debugging/2026-09-20_b-job-660k-cycles.md`) is the larger one and
needs its own measurement first.

## 8. Unverified until a routed build

- That A closes at 200 MHz INSIDE the card build. The engine-only build closed
  at +0.001 ns with the device otherwise empty; the card build is at 83% LUT
  and route-bound. `FK33_ENG_FAST_MHZ` exists so a first build can ask for
  175 or 150.
- That `clk_wiz_0` can produce 100 / 200 / 75 / 200 from one VCO (it should:
  VCO 1200 MHz divides to all four); the wizard reports otherwise at HDL
  generation.
- That the packager infers `sa` and `ma` as AXI4-Lite write-only interfaces
  compatible with `card/a` and `engctl/S01` (the same signal set as `card/a`,
  which builds today), and gives `eng_cdc/sa/reg0` a segment the 256-byte
  assignment fits in. `--bd-only` answers this in 3 minutes; the BC-250 lane
  was occupied (one Vivado present, 3.75 GB RSS) when this track finished, so
  it has not been run.
- The `set_clock_groups -asynchronous` between the two MMCM outputs, and the
  data-before-toggle margin under it. A `set_max_delay -datapath_only` on the
  same paths would be overridden by the group, so none is emitted; `report_cdc`
  on the implemented design is the check, and the FK33_ENGSPLIT block writes
  it both ways.
- The 44 RAMB36 of the y FIFO (105 tiles were free in the shipped card build,
  MEASURED) and any LUT cost of the wrapper; `fk33_pcieep_engcdc_util.rpt` is
  emitted for it.
- The projection in section 7 is DERIVED from two different builds' numbers
  and has to be re-measured with the card's own `CYCLES/BEATS` counters.

---

## 9. Independent re-verification, 2026-09-20 (TRACK ACLK, second attempt)

The first attempt's last act was to commit sections 1-8; it was rate-limited
before reporting any verification, so everything in this section was re-run
from scratch rather than inherited. Where a number below differs from the one
above, this section is the measurement and the one above is withdrawn.

### 9.1 Byte-identity with the switch OFF (MEASURED)

In the MAIN checkout, with `FK33_ENG_SPLIT_CLK` unset:

```
$ env -u FK33_ENG_SPLIT_CLK FK33_CARD=1 FK33_CB_STYLE=distributed \
      FK33_ENG_CORE_MHZ=75 python3 hw/fk33/gen_pcieep.py     # rc=0
sha256 before == sha256 after, both files:
  dcf6957db2dea3639f4ab2aa006313a17639fa600591a44941f9e403ccdd82dd  build_fk33_pcieep.tcl
  143679ce8c6c96d3fadd8f6f08b3f7d7ec9ce6e8488a216e9297f5b8df9c9f0f  fk33_pcieep.xdc
$ git diff --stat -- hw/fk33/build_fk33_pcieep.tcl hw/fk33/fk33_pcieep.xdc
(empty)
```

A card build was running against the committed tree at the time, so both files
were copied to the scratchpad first and the hashes were compared rather than
assumed. The identity claim in section 6 stands.

**The teeth for that test, which section 6 did not have.** An identity test
passes trivially if the switch does nothing, so the switch was shown to change
the output. This was done in a throwaway `git worktree` at HEAD so the live
build's inputs were never written: OFF and ON in the same tree differ by
**177 lines of `build_fk33_pcieep.tcl` and 9 lines of `fk33_pcieep.xdc`**.

`--selftest` passes in all four configurations (re-run):

| `FK33_ENG_SPLIT_CLK` | `FK33_CARD` | rc | last line |
|---|---|---:|---|
| unset | unset | 0 | `SELFTEST PASS` |
| unset | 1 | 0 | `SELFTEST PASS` |
| 1 | 1 | 0 | `SELFTEST PASS` |
| 1 | unset | 1 | `ABORT: FK33_ENG_SPLIT_CLK=1 without FK33_CARD=1` |

with `CDC-PINS  48 pins checked; one removed port on each face is named; an
empty text raises` in every configuration, and `SPLIT-GATE on: 6 fragments
present, 24 seam pins checked on the live cell` against `SPLIT-GATE off: none
of 6 split fragments in the generated text`.

### 9.2 A TRAP FOUND ON THE WAY: `gen_pcieep.py` IS NOT PATH-PORTABLE

The worktree run ABORTed before writing anything:

```
ABORT: the probe build script no longer contains:
add_files -fileset constrs_1 -norecurse <WORKTREE>/hw/fk33/fk33_i2cprobe.xdc
Refusing to emit a PCIe build whose width, IDs, CLKREQ polarity or
smartconnect fan-out may be wrong.
```

Both inputs (`build_fk33_i2cprobe.tcl`, `fk33_i2cprobe.xdc`) ARE tracked and
WERE present. The guard compares against an **absolute path** baked into
`build_fk33_i2cprobe.tcl`, so the generator runs only from a checkout at
`/home/orencollaco/GitHub/llama.vhdl`. This is the recorded "two `sim/*.tcl`
hardcode the absolute path" trap, in a third file, and it is why
`bc250-sync-llama-vhdl.sh`'s `DEST` must stay exactly that path -- which it
does, so the BC-250 lane is unaffected. **An empty `git diff` from a run that
ABORTed proves nothing**; the rc was checked before the diff was believed,
which is the only reason this was noticed rather than recorded as a pass.

### 9.3 Gate rows, both columns (MEASURED)

`REGRESS_SCRATCH=<per-run dir> bash sim/regress.sh --only <substring> --keep`,
serially, one GHDL at a time. `OVERALL` lines verbatim:

| row | OFF (`FK33_ENG_SPLIT_CLK` unset) | ON (`=1`) |
|---|---|---|
| `tb_eng_cdc` | `PASS 1  FAIL 0` | `PASS 1  FAIL 0` |
| `seamgate` | `PASS 6  FAIL 0` | `PASS 6  FAIL 0` |
| `cardtop` | `PASS 3  FAIL 0` | `PASS 3  FAIL 0` |
| `fk33card` | `PASS 1  FAIL 0` | `PASS 1  FAIL 0` |
| `runguard` | `PASS 1  FAIL 0` | **`PASS 0  FAIL 1`** |
| `bdports` | `PASS 1  FAIL 0` | `PASS 1  FAIL 0` |
| `srvseam` | `PASS 1  FAIL 0` | `PASS 1  FAIL 0` |

All OFF rows `REGRESSION: PASS`. Every ON row is `REGRESSION: PASS` except
`runguard`.

**`sim:runguard` ON is a real red row, and it is the generator's own guard
firing, not a defect in the split.** The row runs
`python3 hw/fk33/gen_pcieep.py --selftest` with no `FK33_CARD`, so exporting
the switch alone puts the generator in the one configuration it refuses:

```
FAIL  sim:runguard  0s  ABORT: FK33_ENG_SPLIT_CLK=1 without FK33_CARD=1.
```

With both variables exported the same row passes (MEASURED, third column):

```
$ FK33_ENG_SPLIT_CLK=1 FK33_CARD=1 bash sim/regress.sh --only runguard
PASS  sim:runguard  0s  SELFTEST PASS
 OVERALL     PASS 1   FAIL 0 ...
```

Section 6's "`sim:runguard` PASS 1 / PASS 1" is therefore **withdrawn as
written**: it is true only for an ON column that also exports `FK33_CARD=1`,
and the environment was not stated. The guard itself is right -- silently
ignoring a requested split would be worse than refusing it -- so nothing was
changed. What this costs is that the switch is **not composable with a
whole-gate run**: `FK33_ENG_SPLIT_CLK=1` exported in a shell turns the shared
gate red on a row that is testing a different configuration. Left open below.

*Caveat on `seamgate`, stated because it is not attributable.* Those six rows
compile from the repo, and `rtl/swiglu_mem.vhd` was being edited by another
track while they ran (three other GHDL processes were live, by
`/proc/PID/cwd`). Both columns agree at `PASS 6`, and the switch cannot reach
those benches, but neither column is a clean measurement of any one tree.

### 9.4 Mutation table, re-run in full (MEASURED)

`SCRATCH=<dir> bash sim/mutate_eng_cdc.sh` -> `MUTATE_ENG_CDC
rows-as-expected=15 unexpected=0`, `MUTATE_ENG_CDC: PASS`. Every row matched
the table in section 6, verdict for verdict, including all seven survivors.

The survivors, and the real guard for each -- this is the part worth re-reading:

| row | verdict | why it cannot bite here, and what does guard it |
|---|---|---|
| W1, W2 | SURV | each is one half of a redundant pair; the other half still orders the x path. **W12 (both removed) KILLs** -- that pair is the attribution control, and without it W1/W2 would read as untested code. |
| W3, W4 | SURV | same shape on the y path. **W34 KILLs.** |
| W7 | SURV | one synchroniser flop instead of two is an MTBF defect. A zero-delay simulation never produces metastability, so no functional bench can reach it. Guarded by `ASYNC_REG` in `rtl/fk33_eng_cdc.vhd` plus `report_cdc` on the implemented design (emitted under `FK33_ENGSPLIT`). |
| W8 | SURV | payload and toggle on the same edge is a skew defect; RTL sim samples atomically. Same guard; the XDC clock group is what makes the router's freedom legal, and `report_cdc` is what reads it back. |
| G1 | SURV | gray encode AND decode both identity: pointers cross as plain binary, which is functionally identical when sampling is atomic. **G2 (encoder only) KILLs**, which is the control proving G1's survival is a property of the simulation and not of a dead bench. Static guard: `sim/gray_check.sh`. |
| F2 | SURV | full flag early by one: refuses a beat the clean phases never ask for. A stated floor of the STIMULUS, not of the checker. |
| C0 | SURV | unmutated control. |

Killed: W12, W34, W5 (done leaks into the next `S_WAIT`), W6 (done as a level),
G2. Aborted: F1, on `async_fifo`'s own severity-failure assert.

The bench drives **both ratios**, so the "one ratio has not been shown to
discriminate" objection does not apply: the clock periods are SIGNALS and the
run reports, from the unmutated C0 control,

```
PHASE 1: card 13.333 ns / engine 5 ns
PHASE 2: card 5 ns / engine 13.333 ns (swapped), x throttled
PHASE 3: x overflow (expected fault)
PHASE 4: reset clears the fault; y overflow (expected fault)
PHASE 5: d_job_err
tb_eng_cdc: checks card=190 eng=11488 fails card=0 eng=0
tb_eng_cdc: PASS  checks=11678
```

11,678 counted in VARIABLES, matching section 6.

### 9.5 The constraints, by anchored grep (MEASURED)

Against the generated `fk33_pcieep.xdc`, OFF and ON from the same tree:

| anchored pattern | OFF | ON |
|---|---:|---:|
| `^set_clock_groups .*-asynchronous` | 2 | **3** |
| `^set_max_delay .*-datapath_only` | 0 | **0** |
| `^set_property ASYNC_REG` | 0 | 0 |
| `^\s*if\s` (anywhere in the file) | 0 | 0 |

The one added group, verbatim and unconditional -- no `if`, no `foreach`, no
`set`, so Vivado's XDC reader cannot skip it with a CRITICAL WARNING:

```
# Sentinel: FK33_ENG_SPLIT_CLK xdc eng/core_clk card/clk asynchronous
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins bd_i/eng/core_clk]] \
    -group [get_clocks -of_objects [get_pins bd_i/card/clk]]
```

**There is no `set_max_delay -datapath_only` anywhere in the generated XDC,
and that is deliberate**, not an omission: a clock group makes the crossing a
FALSE PATH, and a false path outranks a max-delay exception in Vivado's
exception priority, so the bound would be silently overridden. The cost is
real and is recorded as open below: nothing bounds the routed skew across the
gray pointer buses. This is the same trade the shipped design already makes
for the engine's 28 core-to-`hbm_aclk` FIFOs, so it is by precedent, not by
measurement.

**The XDC names no register pairs**, so "every CDC register pair named in the
XDC exists in the wrapper" is not a check that exists. What exists instead,
and what was verified to be emitted, is `FK33_ENGSPLIT` on the IMPLEMENTED
design (3 anchored `puts`, 8 references): it errors unless `card/clk` and
`eng/core_clk` resolve to DISTINCT clocks, unless `bd_i/eng_cdc` is present,
and unless at least ten `ASYNC_REG` cells survive under it, then writes
`report_cdc` both ways. None of that can run without a routed build.

### 9.6 `--bd-only` on the BC-250, WITH ITS OFF CONTROL (MEASURED)

Lane gated on PRESENCE via `/proc/PID/exe` (`vivado_present=0`), address
re-resolved from the router lease (`192.0.2.133`) rather than trusted from
this file, tree synced with `bc250-sync-llama-vhdl.sh` (2,459 tracked files)
first. `hw/fk33/pcieep_build.sh --bd-only`, `MemoryHigh=6G`, run twice: once
with the switch ON and once with it OFF, on the same synced tree.

| anchored sentinel | OFF control | ON |
|---|---|---|
| `^FK33_BD_ONLY_DONE` | 2 | 2 |
| `^FK33_BD_VALIDATE` | `OK`, `OK` | `OK`, `OK` |
| `^FK33_UNCONNECTED count=` | `count=0` | `count=0` |
| `^ERROR:` | 0 | 0 |
| BD **41-759**, real messages | 0 | 0 |
| `^CRITICAL WARNING [BD 41-1377]` | 32 | 32 |
| `^CRITICAL WARNING [BD 41-737]` | **3** | **7** |
| `^FK33_ENGCDC` | 0 | 8 |
| Vivado `peak` MB | 3,795.6 | 3,815.3 |

**The split adds exactly four CRITICAL WARNINGs and changes nothing else in
the census.** All four are `BD 41-737` "Cannot set the parameter ... It is
read-only" on the new cell's `eng_cdc/s_clk`, `m_clk`, `s_rstn`, `m_rstn`. The
attribution control is in the same pair of logs: the identical message class
already occurs **3 times in the shipped OFF build**, on `/eng/core_clk`,
`/eng/core_aresetn` and `/bcgrant/rstn`. So this is a pre-existing pattern
extended to one more cell, not a new failure mode -- but it does mean the
requested `ASSOCIATED_RESET` and `POLARITY` did NOT take, which is recorded as
open below. The 32 `41-1377` are pre-existing HBM address aliasing on the
`xdma`/`jtag_hbm` paths, identical in both columns and untouched by the split.

**The 41-759 count needs stating carefully, because it is the log-contains-its-
own-script trap.** An unanchored `grep -c '41-759'` returns **1** on the ON
log. That single hit is `pcieep_build.sh`'s own echoed source -- a line reading
`#  error "FK33_SEAMWIRE FAIL: ... draws no BD 41-759 when left unconnected."`
Filtering to lines that are actual Vivado messages gives **0**:

```
total                                        : 1
non-# lines                                  : 0
^(CRITICAL WARNING|WARNING|INFO|ERROR):...   : 0
```

This is why the net-based `FK33_UNCONNECTED count=0` is the check that matters
and 41-759 is not: CLAUDE.md already records that an input with a VHDL default
draws no 41-759 at all.

What this run ANSWERS from section 8, which listed it as unverified: the
packager DOES infer `sa` and `ma` as AXI-Lite interfaces, and the two-hop
256-byte assignment DOES resolve --

```
FK33_ENGCDC 48 wrapper pins present in fk33_eng_cdc.vhd
FK33_ENGCDC ASSOCIATED_BUSIF eng_cdc/s_clk = sa
FK33_ENGCDC ASSOCIATED_BUSIF eng_cdc/m_clk = ma
FK33_ENGCDC 24 seam pins exist on both faces of the inferred cell
FK33_ENGCDC card/a maps /card/a/SEG_eng_cdc_reg0
FK33_ENGCDC eng_cdc/ma maps /eng_cdc/ma/SEG_eng_reg0
```

It answers NOTHING about timing, area or `clk_wiz_0`'s ability to produce four
outputs from one VCO: `--bd-only` stops before synthesis.

### 9.7 The projection, re-derived and one row corrected

Section 7 reproduces EXACTLY from the profiles, recomputed independently from
`hw/fk33/results/card_swg_2026-09-20/profile/` (MEASURED, my own aggregation):

```
striped: A=10,894,638  card-side=2,963,566  eng-side=7,931,072  rest=19,220,608  token=0.4015 s
flat:    A=42,686,358  card-side=2,963,566  eng-side=39,722,792 rest=19,220,767  token=0.8254 s
striped post-split = 0.3484 s  ->  1.152x       (section 7's figure, confirmed)
naive "all A_JOB at 200 MHz" = 0.3107 s (1.292x) -- the figure section 7 rejects, and it is right to
```

The memory-side assumption, stated explicitly and shown (DERIVED from
`docs/debugging/2026-08-30_counters-cycles-beats-starved.md`): one pseudo-channel
delivers 32 B per ACLK cycle at 250 MHz ACLK, so **4.0 ns per 32 B beat**; the
busiest PC carries **2 lanes**, so each lane gets a beat every **8.0 ns**,
which at 200 MHz is **1.60 core cycles**. The measured engine does **2.03
cycles/beat = 10.15 ns**. Demand/supply = 8.0/10.15 = **0.788**.

**So at 200 MHz A is NOT memory-bound: it is datapath-and-overhead-bound with
about 21% of the busiest pseudo-channel's supply still unused** (equivalently,
it is 27% above both the supply bound and the 1.53-1.60 cycles/beat datapath
floor). That is the answer to "memory-bound or datapath-bound at 200 MHz", and
it is also why clocking past 200 MHz buys little: the next lever is one lane
per PC, not a faster core.

**CORRECTION to section 7's flat row.** It projects flat A engine-side as
`5.18 M x 108 ns = 0.560 s`, which is SLOWER than the measured 0.530 s, so the
table shows flat getting worse and then rounds it to "~0.83 s, 1.0x". The
108 ns is not derived anywhere in this document. The profile's own arithmetic
gives `39,722,792 cycles / 75 MHz / 5,184,384 beats = **102.16 ns/beat**`.
Using the measured figure, flat A engine-side is clock-independent at
**0.5296 s** and the flat token is **0.8254 s exactly, 1.00x**. The CONCLUSION
is unchanged and was always the right one -- the flat image is single-PC bound
and the split buys it nothing -- but the number quoted for it should be the
measured 102.16 ns, not the unsourced 108 ns.

**What the post-split token time actually depends on, which section 7 could
not yet state.** B's mover is MEASURED at **660,601 cycles per job**
(`docs/debugging/2026-09-20_b-job-660k-cycles.md`), 24 jobs = 15,854,448
cycles = 52.6% of the striped token. Another track has levers projected to cut
that to about **308k/job** (ESTIMATE, that track's, not measured here).
Combining (DERIVED):

| striped token | B at 660,601/job (MEASURED) | B at ~308k/job (ESTIMATE) |
|---|---:|---:|
| no split (today) | 0.4015 s | 0.2887 s (1.39x) |
| with the A split | 0.3484 s (1.15x) | **0.2356 s (1.70x)** |

The two levers are close to independent -- A's saving is engine-side beats, B's
is a per-beat handshake in a different subsystem -- so they compose, but
**neither alone gets past about 1.4x, and the order matters for what is worth
measuring next**: B is the bigger single block by cycles, A is the one whose
200 MHz is MEASURED on silicon. If B's levers land first, the A split's share
of the remaining token RISES from 15% to 23%, which strengthens rather than
weakens the case for it.

### 9.8 Open, NOT determined

- **Everything that needs synthesis or routing.** `--bd-only` stops before it.
  No timing, no area, no `report_cdc`, no evidence that A closes at 200 MHz
  inside a card build at 83% LUT, and no confirmation that `clk_wiz_0` yields
  100/200/75/200 from one VCO. `FK33_ENGSPLIT` and the 44 RAMB36 y-FIFO cost
  are unmeasured.
- **Nothing bounds the routed skew on the crossing.** The `set_clock_groups
  -asynchronous` makes it a false path and no `set_max_delay -datapath_only`
  can survive beside it. Justified by precedent (the engine's own 28 FIFOs
  ship this way), never measured for this seam.
- **`ASSOCIATED_RESET` and `POLARITY` on `eng_cdc`'s clock/reset pins were
  REFUSED by Vivado** (`BD 41-737`, 4 instances). `ASSOCIATED_BUSIF` did take
  and is read back. The consequence of the refusal is not established; it is
  cosmetic for timing, since the XDC group is what constrains the crossing,
  but the generator is asking for something it does not get. CLAUDE.md:
  reading a `CONFIG.*` back reads a REQUEST -- here Vivado says no out loud.
- **`FK33_ENG_SPLIT_CLK=1` exported alone turns `sim:runguard` red.** Decide
  whether the guard should move from configuration time to emission time so
  `--selftest` stays runnable in every environment, or whether the gate row
  should pin `FK33_CARD=1`. Not changed by this track, because the guard is
  correct and changing a shipped refusal on a verification pass is the wrong
  order of operations.
- **`seamgate`'s six rows are not attributable to either tree**, because
  another track was editing `rtl/swiglu_mem.vhd` while they compiled.
- **The projection is still cross-build arithmetic.** The 2.03 cycles/beat
  comes from the engine-only 200 MHz build and the profile from the 75 MHz
  card build. Same memory layout and same ACLK, but they are two builds, and
  CLAUDE.md is explicit that a comparison needs both ends from one tree. The
  card's own `CYCLES`/`BEATS` counters settle it and have not been read at
  200 MHz.
- **B's ~308k/job is another track's ESTIMATE**, carried here unverified. The
  1.70x row stands or falls with it.
