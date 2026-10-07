# hw/jc/ctl: the Jungle Cat USER3 control core

The host drives the card's registers (AXI-Lite) and reads HBM through this core, over JTAG
USER3 (IR 0x8A4), in 16,384-bit slots. The protocol is plan Task 2's "Protocol (exact)"
(`docs/superpowers/plans/2026-10-07-jc-engine-composition.md`), with the host-driven ack
and the two status CRCs.

The Jungle Cat chain also exposes JPROGRAM and eFUSE-programming instructions. The host
may shift only BYPASS 0xFFF, IDCODE 0x249, USER3 0x8A4 and USER4 0x8E4.

## Files

| file | what |
|---|---|
| `rtl/jc_ctl_core.vhd` | the composition (block-design module reference `jc_ctl_core`) |
| `hw/jc/ctl/rtl/jc_ctl_rx.vhd` | BSCANE2 `JTAG_CHAIN => 3` + BUFG on TCK (synthesis only) |
| `hw/jc/ctl/jc_ctl_timing.tcl` | CDC constraints and audits as `jctl_*` procs |
| `hw/jc/ctl/ooc_ctl_core.tcl` | OOC synth/place/route at 200 MHz aclk, 27 MHz TCK |
| `sim/tb_jc_ctl_core.vhd` | end-to-end bench through the real crossings |
| `sim/gen_jc_ctl_core_vec.py`, `sim/jc_ctl_core_vec.txt` | host-library slots (from `tools/jc/jc_ctl.py`) the bench cross-checks |
| `sim/mutate_jc_ctl_core.sh` | composition mutants against the bench |
| `hw/jc/ctl/test_jc_ctl_timing.tcl` | tclsh unit check of the synchroniser consumer trace (mocked Vivado commands) |

The composition uses the following units:
- `rtl/jc_ctl_frame_core.vhd` (TCK)
- `rtl/async_fifo.vhd`, 258 x 128 (the loader's instance shape)
- `rtl/jc_ctl_exec.vhd` (aclk)
- `rtl/jc_status_sync.vhd`, W = 384
- a 2-FF `ASYNC_REG` synchroniser for `rsp_ack_tgl`
- a 512 x 32 dual-clock block RAM for the response (written on aclk, read on TCK)

The loader files are instantiated only, never edited.

## Ports (match `hw/jc/card/gen_jc_card.py`'s port table)

- **Clock and reset:** `aclk` (clk_core) and `arst` (active high).
- **JTAG from `jc_ctl_rx`:** `tck`, `sel`, `capture`, `shift` and `tdi` in, `tdo` out.
- **`m_axil_*`:** the AXI-Lite master, 32-bit address and data, with AWPROT and ARPROT.
- **`m_axi_*`:** the AXI4 read-only master:
  - `araddr(32:0)`, `arlen(7:0)` with ARLEN at most 15, `arsize`, `arburst`, `arvalid`/`arready`;
  - `rdata(255:0)`, `rresp`, `rlast`, `rvalid`/`rready`.
- **Generic:** `TMO_CYC` (default 65536). It is the executor's AXI response timeout, in aclk cycles.

The file is VHDL-93 syntax, with std_logic ports, literal widths and no input defaults.
The units under it use VHDL-2008 (`jc_ctl_exec` uses `process(all)`).

## Reset contract

- **Source.** `arst` is `core_reset/peripheral_reset`, which is synchronous to clk_core. It
  passes through a 2-FF synchroniser anyway, so the executor sees it 2 aclk cycles late.
- **What gets reset with it.** The executor drops AXI VALIDs when it is reset mid-transaction.
  The AXI-Lite interconnect (`axil2eng`) and the HBM smartconnect (`hbm_sc`) must therefore be
  reset together with this core. In the card BD they are: all three take the same
  proc_sys_reset. Never reset this core alone.
- **The async FIFO is never reset.** While reset is high, the executor neither sees nor pops
  FIFO words. A frame still queued executes after the reset. A frame already popped is
  dropped. Orphan words are discarded up to the next header. No frame executes twice.
- **Why not the loader's pattern.** Resetting the FIFO's read side from `arst` while TCK is
  stopped replays stale words. `sim/mutate_jc_ctl_core.sh` row K8 is that mutant.
- **What the host sees.** After a reset, last_done_seq, rsp_seq and err_seq read
  `0xFFFFFFFF`, and rsp_valid reads 0. When the host sees last_done_seq go back to none,
  every frame in flight is UNKNOWN.
- **What no reset clears.** The frame core and the TCK half of the status sync have no
  reset, so desync, crc-fail and ovf are sticky until reconfiguration.

## Status crossing: is jc_status_sync safe for this use?

Yes, for coherence and order. Staleness is the one exception, and the frame core's stale
rule exists for it.

The aclk side copies `live` into `snap` and toggles `pub`, on the same edge. It does this
only when `ack`, through two flops, equals `pub`. The TCK side copies `snap` into `st_r`
when `pub`, through two flops, differs from `ack`, and toggles `ack` on that edge. Three
properties follow:

1. **Coherent.** Every `st_r` value is one `snap`. All 384 bits come from one aclk edge.
   `snap` cannot move between a `pub` toggle and the TCK capture that acknowledges it.
   This relies on the `snap -> st_r` data path delay being within the margin, so it is
   bounded by `set_max_delay` at one TCK period.
2. **Monotonic.** `st_r` only ever takes the newest `snap`, and each `snap` is taken
   after the previous one was captured. The TCK side can never latch an older snapshot
   than the one it holds.
3. **Can be stale.** TCK-side progress happens only on TCK edges. The first slot after
   an idle gap can therefore show the snapshot from the end of the previous scan.

**Measured** (`sim/tb_jc_ctl_core.vhd` case S, GHDL). A second `jc_status_sync` ran on the
bench's real BSCAN-gated TCK at 37 ns, with aclk at 5 ns. Its `live` word changed on
every aclk:
- 338,704 TCK-side updates (final GREEN run, ~/regress_scratch/t4-core-5);
- 0 incoherent, 0 not newer;
- minimum time from the snapshot write to its capture: 96.5 ns, which is 2.6 TCK periods;
- minimum time from a capture to the next snapshot write: 10.5 ns, which is 2 aclk;
- maximum snapshot age at capture while TCK ran continuously: 100.5 ns.

How the frame core and executor rely on this:
- **The executor publishes in one cycle.** All fields change together in S_DONE, so
  every snapshot is a frame boundary.
- **The stale rule covers the first slot after a gap.** If that slot re-shows an acked
  `rsp_seq` that is still valid, it is masked.
- **Monotonic order lets the frame core forget an ack.** Once a slot has shown the clear,
  no later slot can show the acked seq again. So the frame core can drop its stale memory
  at that point.

## Response RAM and the ack slot

The ack is taken at bit 16159 of the frame that carries it. That slot keeps shifting
the acked response's last words, up to bit 16255. A following MEM_RD can overwrite them
meanwhile.

The executor writes at most one RAM word per aclk, in address order. It reaches word 495
at 2.48 us or later. The frame core reads word 495 63 TCK after the ack:

- **At 27 MHz** that is 2.33 us, so the tear cannot happen. The bench measured 0 words
  overwritten (case E1).
- **Below about 24 MHz** TCK, it does happen. At 5 MHz the bench overwrote the tail and
  the slot's rsp_crc did not match, so it was detected (case E2).

The host must never accept a response from the slot that carried its ack. It has already
accepted that response from an earlier slot.

## OOC result (MEASURED by the controller, 2026-10-07, /mnt/storage/fk33_builds/jcctl_ooc2)

This is the first version of the script, before fix round 1 added the synchroniser and
RAM-clock refusals:
- xcvu35p-fsvh2104-2L-e, 200 MHz aclk and 27 MHz TCK;
- routed WNS +1.487 ns, WHS +0.039 ns, routing_errors 0;
- `JCCTL_OOC_CDC unexpected 0`. The audit saw 157 aclk-to-TCK paths and 10 TCK-to-aclk
  paths, all ending at named synchronisers;
- `JCCTL_OOC_RRAM 1`;
- peak memory 5.56 GB.

The response RAM is one RAMB18E2 with WRITE_MODE NO_CHANGE on both ports. CLKARDCLK is
tck (port A, read) and CLKBWRCLK is aclk (port B, write).

Every named crossing is within its bound (slack / requirement, ns):

| crossing | slack | requirement |
|---|---|---|
| snap_to_st_r | 36.308 | 37.037 |
| pub_to_tgl | 4.698 | 5.000 |
| ack_to_ack_s1 | 4.592 | 5.000 |
| rsp_ack_tgl | 4.661 | 5.000 |
| wp_gray | 4.515 | 5.000 |
| rp_gray | 4.537 | 5.000 |

## OOC (not run by the implementer)

```
vivado -mode batch -source hw/jc/ctl/ooc_ctl_core.tcl -tclargs <repo> <outdir> [part]
```

Gate on these lines:
- `^JCCTL_OOC_DONE`
- `^JCCTL_OOC_ROUTE routing_errors 0`
- `^JCCTL_OOC_CDC unexpected 0`: every aclk/TCK endpoint is a named synchroniser
- `^JCCTL_OOC_RRAM`: the response RAM must be a RAMB18E2 or RAMB36E2. Its written port
  must be on aclk and its other port on TCK. Otherwise the script stops before DONE (fix
  round 1).
- `^JCCTL_SYNC_OK` for each synchroniser, and `^JCCTL_SYNC_DRIVER` for the executor's
  `rsp_ack_tgl` and `rst` (fix round 1). The script refuses, with no DONE, when:
  - a stage lacks ASYNC_REG;
  - a first stage feeds anything other than its second stage;
  - the executor's ack or reset is not taken from the second stage. Fix round 2 checks
    this on LEAF loads, not hierarchical port names, which synthesis does not keep:
    - every leaf load of `rak_s2_reg/Q` is under `ex/`;
    - `rst_s2_reg/Q` loads are under `ex/` or `fifo/`, or are a top-level combinational
      reset gate;
    - at least one load is under `ex/`;
    - no load of a first stage is under `ex/`.

  `tclsh hw/jc/ctl/test_jc_ctl_timing.tcl` checks that trace against a mocked netlist,
  with no Vivado.
- `JCCTL_OOC_WNS` and `JCCTL_OOC_WHS` must not be negative.

Budget: 5.56 GB peak, MEASURED on this core. Run one Vivado per box, under
`run_capped.sh`.
