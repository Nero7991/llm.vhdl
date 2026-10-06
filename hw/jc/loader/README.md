# Jungle Cat JTAG-to-HBM weight loader: bitstream

Plan Task 10 (spec `docs/superpowers/specs/2026-10-05-jc-jtag-hbm-loader-design.md`).
Building only: nothing in this directory opens a hardware target.

## Files

| File | What |
|---|---|
| `rtl/jc_frame_rx.vhd` | BSCANE2 (`JTAG_CHAIN => 4`, USER4) + BUFG on TCK. Exposes TCK/SEL/CAPTURE/SHIFT/TDI/TDO only; the receiver (`rtl/jc_frame_core.vhd`) is inside `rtl/jc_loader_core.vhd`. |
| `rtl/jc_loader_top.vhd` | Block-design module reference: `jc_frame_rx`, `jc_loader_core`, `DNA_PORTE2` (DIN `'0'`), HBM-calibration reset hold, cattrip OR, fan/LEDs, `m_axi` (AXI3, 33-bit, 256-bit) |
| `jc_loader_bd.tcl` | Block design `jcl`: IBUFDS, clk_wiz (100/200/200 MHz), HBM (2 stacks, global switch, SAXI_00 loader, SAXI_16 jtag_hbm via smartconnect), jtag_axi_0 -> 8 KB BRAM at `0xC0000000`; CONFIG readback, unconnected-pin check |
| `jc_loader.xdc` | Pins (BC26/BC27 sysclk, fan G9, LEDs K10/K9/J9/J10) and the board clock |
| `jc_loader_timing.tcl` | TCK, dna_clk and every CDC bound, as procs shared by the OOC and full builds |
| `build_loader.tcl` | Full build: BD, synth_1, in-process implementation, checks, bitstream |
| `ooc_loader_core.tcl` | OOC synth + place + route of `jc_loader_core` (200 MHz aclk, 27 MHz TCK) |
| `run_capped.sh` | systemd-run `MemoryHigh` cap + swap guard + cgroup sampling (local or `ssh ... 'bash -s'`) |
| `results/2026-10-05/` | `full/`: `jc_loader.bit`, `.ltx`, routed reports, sentinels, memory samples. `ooc/`: OOC reports |

## Build

    # full bitstream (one Vivado per box; workstation measured 14.4 GB peak, see results)
    bash run_capped.sh jcl_full 14G 32212254720 <root> \
      vivado -mode batch -source build_loader.tcl -tclargs <root>/proj xcvu35p-fsvh2104-1-e
    # OOC route of the core
    vivado -mode batch -source ooc_loader_core.tcl -tclargs <repo> <outdir> xcvu35p-fsvh2104-1-e

Gate on the anchored sentinels: `^JCLOADER_DONE` (full), `^JCL_OOC_DONE` plus
`^JCL_OOC_ROUTE routing_errors 0` (OOC). A failure prints `^JCLOADER_FAIL <reason>`.

Part: `xcvu35p-fsvh2104-1-e` for both, the string `hw/jc/axiprobe` built the bitstream
that ran on the Jungle Cat with. The module is -2L; -1 timing is the conservative side.

## Result (2026-10-05, build `full4` from commit ed0a750)

- Routed WNS +0.521 ns, WHS +0.010 ns, all constraints met (a bound, not an fmax);
  full3 (one commit earlier, report-only difference) routed to the identical numbers.
  Worst path: DNA_PORTE2 DOUT -> `dnar/val_reg[95]` at Vivado's one-aclk worst case.
- BSCAN census: `dbg_hub` BSCANE2 `JTAG_CHAIN=1` (`C_USER_SCAN_CHAIN=1`), loader
  BSCANE2 `JTAG_CHAIN=4`; exactly one chain-4 instance.
- `report_cdc`: every loader crossing is `Max Delay Datapath Only`, 303 endpoints
  aclk->TCK and 9 TCK->aclk, 0 unsafe, 0 unknown, 0 missing ASYNC_REG.
- Debug cores (ltx): `jcl_i/jtag_axi_0` (BRAM, slave 0) and `jcl_i/jtag_hbm`
  (HBM SAXI_16, slave 1), both on user chain 1.

**Post hoc (Task 10 fix round 1).** The shipped `.bit` was routed before two constraints
existed: the BSCANE2 TDI bound (`jcl_tdi`, TDI was unconstrained) and the DNA DOUT
multicycle (`jcl_dna_mcp`). `posthoc_constraints.tcl` applied both to full4's routed
checkpoint without re-implementing (`results/2026-10-05/post_constraints/`): TDI worst
+7.119 ns of 18.519, DNA DOUT setup +45.521 / hold +1.038, design WNS +0.703 / WHS
+0.010. DNA_PORTE2/CLK library limits: min period 4.875 ns, pulse 2.275 ns.
A rebuild needs ~15 GB on the workstation (llama-server stopped; does not fit beside it).

Details, adaptations from the plan, and every accepted warning: the Task 10 report
(`.superpowers/sdd/2026-10-05-jc-jtag-hbm-loader/task-10-report.md`).
