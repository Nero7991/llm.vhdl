# Subsystem A board build (AXU3EG / XCZU3EG)

Scripted, reproducible Vivado build for the §14.4 validation configuration of
`docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md`:
`ROWS_IF=4`, `NPORTS_W=4`, `AXI_DW=128`, 200 MHz.

```
vivado -mode batch -source hw/build_bringup.tcl -tclargs bd     # validate only
vivado -mode batch -source hw/build_bringup.tcl -tclargs synth
vivado -mode batch -source hw/build_bringup.tcl -tclargs all    # bitstream
```

Everything is generated from source into `hw/mv_bringup/`, which is disposable
and not checked in.

## Read this before programming the board

**The fan is part of the design, not an optional extra.** `fan_pwm` (the
`axi_pwm` IP from `~/GitHub/axu3eg-pwm-ip`) is instantiated at **0x80090000**,
the same address the running design uses, so the existing `pl-pwm-fan` driver
and device-tree node bind unchanged. A bitstream without it leaves **AA11**
unconfigured, and the fan is **active-low**: an undriven pin stops the fan while
the thermal governor still reports everything healthy. If the IP repo is
missing, the script warns and continues -- do not program that bitstream.

**This replaces whatever is currently loaded**, including the v1.0
`llama_engine_axi` design. That is recoverable by reloading the old bitstream,
but it is not automatic.

## Why this does not live in the hardware repo

`~/GitHub/AlinxMigrated` carries `design_1` (the full TRD, with video and
ethernet IP this has no use for) and `design_2` (minimal PS + fan + llama
engine). At the time of writing that repo has ~26 uncommitted files including a
half-finished clock change, so editing a checked-in `.bd` there would mean
committing someone else's work in progress and reviewing a binary blob. This
design is generated from text instead.

The **PS configuration is lifted verbatim** from `design_2` by
`hw/gen_ps_config.py`, which reads the `.xci` directly rather than opening the
project (opening one rewrites files). The PS carries the DDR4 timing and the
MIO assignment for SD/UART/ethernet; getting any of it wrong means a board that
does not boot, and the only way back in is JTAG. So it is copied, not re-derived.

Two things are deliberately overridden on top of it:

| | design_2 | here | why |
|---|---|---|---|
| `PL0_REF_CTRL` | 100 MHz | **200 MHz** | §14.4. Also makes the fan's `period=8000` land on the 25 kHz its device tree documents, instead of 12.5 kHz. |
| PS slave ports | none | **HP0-3 + HPC0** | `llama_engine_axi` is AXI-Lite only and never touches DDR. |

## Topology

```
PS ── M_AXI_HPM0_LPD ── smartconnect ─┬─ mv/s_axi   0x80000000 (64K)
                                      └─ fan_pwm    0x80090000 (64K)

mv/m00_axi ── S_AXI_HP0   weight sub-region 0
mv/m01_axi ── S_AXI_HP1   weight sub-region 1
mv/m02_axi ── S_AXI_HP2   weight sub-region 2
mv/m03_axi ── S_AXI_HP3   weight sub-region 3
mv/m04_axi ── S_AXI_HPC0  scales
```

**One master per PS slave port is the point, not tidiness.** Sharing a port
would halve delivered bandwidth, and sustained bandwidth as a fraction of DDR
peak is §11's acceptance criterion -- the number every projection in
`docs/fpga-hardware-recon.md` rests on. DDR4-2400 at 64 bit is **19.2 GB/s**
peak against this configuration's **14.4 GB/s** demand, so the design sits right
at the boundary §4 predicted and the measurement is genuinely informative.

Masters are **read-only** (AR and R channels only). Subsystem A never writes to
DDR; results return through the AXI-Lite result buffer.

## Register map

See the header of `rtl/matvec_int4_axi.vhd`. `sim/tb_matvec_axi.vhd` executes
the whole driver sequence against it in simulation and is the specification the
board-side C driver should follow.
