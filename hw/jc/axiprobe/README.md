# JTAG-AXI bandwidth probe (Jungle Cat weight-load feasibility)

A minimal VU35P bitstream to MEASURE, not estimate, how fast weights could be
pushed into a Jungle Cat die over the only no-new-hardware path (CoE JTAG-AXI).
It answers the spike: is the cheapest existing host-path viable for a ~7 GB
per-die 27B weight load?

## What it is
`jtag_axi` (JTAG-to-AXI master, BSCAN, no pins) -> `axi_bram_ctrl` -> 8 KB BRAM
at **0xC0000000**, clocked by **CFGMCLK** (STARTUPE3, ~50 MHz, no external clock
or GTY refclk needed; the JTAG-AXI path is transport-bound, so the fabric clock
is immaterial to the number). Built on `xcvu35p-fsvh2104-1-e` (the part the
census programs the JC with). Source: `jc_axiprobe_bd.tcl`, `jc_axiprobe.vhd`,
`jc_axiprobe.xdc`, `build_axiprobe.tcl`. Bitstream (rebuildable):
`/mnt/storage/fk33_builds/axiprobe/axiprobe.runs/impl_1/jc_axiprobe.bit`.

## Rebuild
    vivado -mode batch -source build_axiprobe.tcl -tclargs /mnt/storage/fk33_builds/axiprobe xcvu35p-fsvh2104-1-e

## Measure (main session / Oren -- opens the JTAG path, NOT a subagent)
When the Jungle Cat is reassembled and on the LAN:
1. Program jc_axiprobe.bit via sqrl_bridge with XVC on port 2542 (the 5th arg),
   as in the census reload (see docs/boards/jungle-cat/2026-09-27_bringup.md S6).
2. `vivado -mode batch -source measure_jtag_axi.tcl`
3. Read the `AXIBW len=... KB/s -> 7GB in N h` lines. It sweeps burst length
   1..256 beats and stops if a shift hangs the XVC bridge (the documented large-
   shift failure). The headline is the best KB/s and the implied 7 GB load time.

## Expected (to be confirmed)
The extrapolation from the config rate (~0.7-1.4 MB/s, Section 10) says JTAG-AXI
writes are far slower (~KB/s, per-transaction XVC overhead) -> tens of hours to
days for 7 GB -> no-go for weight-scale load. This probe confirms or refutes it
with a hard number.
