# Jungle Cat pin-finder

Two bitstreams for the SQRL Jungle Cat VU35P module
(`xcvu35p-fsvh2104-2L-e`), built 2026-10-05 on the BC-250 lane, synthesis +
implementation only. Purpose: Oren programs each onto a module and probes
empty carrier footprints with a multimeter in frequency mode; whichever
reading it gets identifies which pin is routed where. Each of the 11 driven
pins outputs a distinct, meter-readable 50% square wave, counter-generated
from the module's own 200 MHz LVDS oscillator (`sysclk_clk_p/n`, BC26/BC27).

Variant A uses 1..11 kHz (nominal) on the 11 outputs; variant B uses
12..22 kHz on the same 11 outputs in the same order, so a net that is
actually shared between two carrier slots shows up as two different
readings instead of one that could be either side.

Frequency = `100_000_000 / DIVn` Hz (period = `2*DIVn` cycles of the 200 MHz
/ 5 ns clock). The nominal kHz values are targets; the divisor is the exact
integer that gets closest, so the achieved frequency is not always a round
number -- stated to 4 decimal places below, as produced by
`python3 -c "print(100000000/<DIVn>)"`, not rounded to the nominal.

## Pin / net / frequency table

| # | Port (pinfinder_top.vhd) | Package pin | Net name (vendor XDC) | Divisor | Freq A (Hz) | Freq B (Hz) |
|---|---------------------------|--------------|------------------------|---------|-------------|-------------|
| 0 | out_g10_p | G10  | sysclk_ext_clk_p  | 100000 / 8333 | 1000.0000  | 12000.4800 |
| 1 | out_g10_n | F10  | (sysclk_ext's diff-pair partner; no vendor net name -- unused by the vendor design) | 50000 / 7692 | 2000.0000 | 13000.5200 |
| 2 | out_f13_p | F13  | sysclk_ext2_clk_p | 33333 / 7143 | 3000.0300 | 13999.7200 |
| 3 | out_f13_n | F12  | (sysclk_ext2's diff-pair partner; no vendor net name) | 25000 / 6667 | 4000.0000 | 14999.2500 |
| 4 | LED_A     | K10  | LED_A | 20000 / 6250 | 5000.0000 | 16000.0000 |
| 5 | LED_B     | K9   | LED_B | 16667 / 5882 | 5999.8800 | 17001.0201 |
| 6 | LED_C     | J9   | LED_C | 14286 / 5556 | 6999.8600 | 17998.5601 |
| 7 | LED_D     | J10  | LED_D | 12500 / 5263 | 8000.0000 | 19000.5700 |
| 8 | LED_RGB_R | K11  | LED_RGB_R | 11111 / 5000 | 9000.0900 | 20000.0000 |
| 9 | LED_RGB_G | L12  | LED_RGB_G | 10000 / 4762 | 10000.0000 | 20999.5800 |
| 10 | LED_RGB_B | L11 | LED_RGB_B | 9091 / 4545 | 10999.8900 | 22002.2002 |

(The "Divisor" column reads "variant A divisor / variant B divisor"; both
are DERIVED as `round(100000/f_kHz)`, exact per `build_pinfinder.tcl`'s
`DIV0..DIV10` generics for each variant.)

Not driven (left at Vivado default, per the task boundary): H12 (`jcm_sync`,
possibly shared across modules on the carrier), and every SPI/config, UART,
I2C, fan and `err_vccint` pin from the vendor XDC.

## Clock and N-pin resolution (measured, not guessed)

`hw/jc/pinfinder/query_pins.tcl` (`link_design -part xcvu35p-fsvh2104-2L-e`,
`get_property DIFF_PAIR_PIN [get_package_pins <P>]`) ran on the BC-250
2026-10-05 and found:

| P pin | N pin (measured) | I/O bank |
|-------|-------------------|----------|
| BC26 (sysclk_clk_p) | BC27 | 65 |
| G10  (sysclk_ext_clk_p) | F10 | 67 |
| F13  (sysclk_ext2_clk_p) | F12 | 67 |

(The same query also showed the 4 LED pins and 3 LED_RGB pins are
diff-pair partners of each other in bank 67 -- K10/K9, J9/J10, K11/L11 --
and L12's partner is L13, not used here. Irrelevant to this design: every
LED stays single-ended LVCMOS18, exactly as the vendor XDC drives it.)

`sysclk_clk_n` is placed at BC27 with `IOSTANDARD LVDS`, `DIFF_TERM_ADV
TERM_100` and `DQS_BIAS TRUE` on the P port, exactly as
`docs/boards/jungle-cat/JCCL2-JCM35.xdc`. `out_g10_n` and `out_f13_n` are
placed at F10/F12 as plain single-ended `LVCMOS18` outputs (`DRIVE 4`,
`SLEW SLOW`), driven independently from `out_g10_p`/`out_f13_p` by separate
counters, not as a differential pair.

## Bank VCCO check

`report_io` (full version: `/mnt/storage/fk33_builds/jc_pinfinder/build_{a,b}/report_io_{A,B}.rpt`;
pins-used excerpt: `results/report_io_A_filtered.rpt`) confirms, MEASURED
from the placed design, not assumed:

- Bank 65 (BC26/BC27, `sysclk_clk_p/n`): `LVDS`, `100Ohm Differential`
  input termination, `DQS_BIAS TRUE` -- matches the vendor XDC's clock
  input exactly.
- Bank 67 (G10, F13, F10, F12, and all 7 LED pins): every one of those 11
  pins reports `IO Standard = LVCMOS18`, `Drive (mA) = 4`, `Slew = SLOW`.
  Since this design puts only LVCMOS18 in bank 67 (unlike the vendor
  design, which also runs the LVDS `sysclk_ext`/`sysclk_ext2` clock inputs
  through the same bank), there is no joint VCCO constraint to resolve: the
  whole bank is 1.8 V-only in this bitstream. `report_drc` found 0
  violations on both variants, which would have flagged a bank
  IOSTANDARD/VCCO conflict had one existed.

## Build results

Both variants: synthesis + implementation (`route_design` then
`write_bitstream`) completed successfully on the BC-250
(`xcvu35p-fsvh2104-2L-e`), `vivado -mode batch`, project-mode flow
(`build_pinfinder.tcl`). No hardware access of any kind was used to produce
or check these bitstreams.

| | Variant A | Variant B |
|---|---|---|
| WNS (setup) | +3.493 ns | +3.370 ns |
| WHS (hold) | +0.005 ns | +0.053 ns |
| Timing constraints | All user specified timing constraints are met. | All user specified timing constraints are met. |
| DRC violations | 0 | 0 |
| DRC critical warnings | none | none |
| Vivado warnings (whole run, from journalctl) | 1 (routine: `XILINX_HLS not found`, `Auto Incremental Compile: no reference checkpoint`, `Parallel synthesis criteria is not met` -- tool/flow notices, none about an output pin) | same three, same reason |
| CLB LUTs used | 66 / 871680 | 66 / 871680 |
| Anchored pin check (`get_ports ... PACKAGE_PIN`) | all 13 ports (11 outputs + clock P/N) match the table | all 13 ports match the table |
| Bitstream sentinel | `PINFINDER_BITSTREAM_DONE A <path>` (printed only after `write_bitstream` returned and the `.bit` file was found on disk) | `PINFINDER_BITSTREAM_DONE B <path>` |

Full reports: `/mnt/storage/fk33_builds/jc_pinfinder/build_a/` and
`build_b/` (bitstream + full `utilization`/`timing_summary`/`drc`/`report_io`).
Small excerpts of the same reports: `hw/jc/pinfinder/results/`.

## Vivado peak memory (BC-250, capped via `run_capped.sh`, `MemoryHigh=11G`)

Readback confirmed the cap was actually applied before trusting any run
(`systemctl --user show <unit> -p MemoryHigh` = `11811160064` bytes = 11 GiB
on every run below), per CLAUDE.md's systemd-run-over-ssh trap.

| Run | `systemd-run` summary `Memory peak` | swap | Hit the 11G cap? |
|---|---|---|---|
| N-pin query (`query_pins.tcl`) | 1.8 G | 0 B | no |
| Build A (variant A) | 5.7 G | 0 B | no |
| Build B (variant B) | 5G (sampled peak 5.40 GB resident) | 0 B | no |

None of the three runs came close to the 11 GiB cap or touched swap; this
is a tiny design (66 LUTs), so the memory floor is Vivado's own project/
synthesis/implementation overhead, not this design's size.
