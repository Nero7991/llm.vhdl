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
unconfigured. **Measured 2026-08-23: an unconfigured AA11 runs the fan at full
speed**, with the thermal governor reporting healthy the whole time because it
is writing registers that reach nothing. An earlier version of this file said an
undriven pin *stops* the fan; that was a guess about which way a floating
active-low input settles, and it is wrong. If the IP repo is
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

## Reserving the weight buffer (do this before running the driver)

**There is no IOMMU in this path.** The PL masters issue physical addresses
straight at the HP ports, so a `malloc`'d buffer is useless: it is neither
physically contiguous nor at an address the PL knows. The weights have to sit
in a region the kernel does not own.

**Until that region is reserved, do not point `--phys` at it.** The driver maps
it through `/dev/mem` and writes tens of megabytes; aimed at memory Linux is
using, that corrupts the kernel silently.

Add a `reserved-memory` node to `system-user.dtsi` in the PetaLinux project and
rebuild the device tree:

```dts
/ {
    reserved-memory {
        #address-cells = <2>;
        #size-cells = <2>;
        ranges;
        mv_weights: mv-weights@50000000 {
            no-map;
            reg = <0x0 0x50000000 0x0 0x10000000>;   /* 256 MB */
        };
    };
};
```

`no-map` is what keeps the kernel from mapping it at all, which is what makes
`/dev/mem` access to it safe. 256 MB is ample: the §11 acceptance matrix
(5120 -> 17408) packs to about **50 MB**, and the largest single 27B layer
tensor is the same size. `lm_head` at ~715 MB would need a larger reservation.

**Do not put it at the top of the bank.** The first attempt used 0x70000000 on
the reasoning that the low DDR bank ends at 0x7FFFFFFF, and the kernel refused
it. The top of the bank is the most contended part of it: CMA takes 256 MB
there (`cma: Reserved 256 MiB at 0x0000000065800000`), and the base device tree
already reserves 0x758f6000-0x7bbf3fff and 0x7bf00000-0x7fefffff. CMA is placed
dynamically -- size, no `reg` -- and takes the highest free window below the
static reservations, so it will keep landing near the top wherever this node
goes. The free window is 0x3EE48000 up to CMA at 0x65800000, about 615 MB, and
0x50000000 sits in the middle of it.

It must be the **low** bank: the masters are `ADDR_W=32`, so the 2 GB high bank
at 0x800000000 is not addressable by this design.

**A failed reservation is not a boot failure.** The kernel prints one line and
carries on, and `/dev/mem` will still write the region -- into memory Linux is
using. Check it explicitly after every device-tree change:

```
dmesg | grep -i 'reserved memory'     # must say nothing about failing
grep -i 5000 /proc/iomem              # must show 50000000-5fffffff
```

## Running it

```
# on the workstation
python3 tools/pack_int4.py MODEL.gguf blk.0.ffn_gate.weight ffn.mv4i --rows-if 4
make -C hw board                       # -> hw/mv_driver_aarch64, static

# on the board
./mv_driver --mv4i ffn.mv4i --phys 0x50000000
```

`--dry-run` prints every register value it would write, without touching
`/dev/mem`. The sub-region bases and beat counts it computes from the file
header have been checked against `tools/pack_int4.py`'s `packed_layout()`
computed independently from the shape -- they agree, which is worth knowing
before a wrong beat count produces a silent wrong answer rather than a crash.

Output reports the §11 numbers: bit-exactness against `ref/matvec_int4.c`
running on the board's own cores, and sustained weight bandwidth as a
percentage of the 19.2 GB/s DDR4-2400 peak. Bandwidth is computed from the PL's
own `BEATS` and `CYCLES` counters rather than wall-clock, so it measures what
the datapath consumed and does not fold in the AXI-Lite activation load or the
polling loop.
