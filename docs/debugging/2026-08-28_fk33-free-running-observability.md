# FK33: making the endpoint bitstream readable, and VCCINT autonomous, on a clock the PCIe link cannot stop

## 1. The question, verbatim

> Add, to the endpoint design, a small set of status registers clocked from that
> free-running domain and readable over JTAG with the PCIe link DOWN. At minimum:
> a free-running counter clocked by the PCIe reference clock ... the raw
> `pcie_perstn` input level (BE24) ... `xdma/axi_aresetn` ... the PCIe hard
> block's LTSSM state if it can be reached ... **the read path must not touch
> anything clocked by `xdma/axi_aclk`.**
>
> Add a small autonomous state machine, on the free-running domain, that
> bit-bangs the pot to the target wiper shortly after configuration, with no AXI
> and no host involvement ... the target is wiper 68, giving 0.717 V. Do NOT
> raise VCCINT to 0.85 V. Hardcode 68 as a constant.
>
> Compute how long this bitstream takes to load from flash, and write the
> arithmetic down.

**Date:** 2026-08-28.
**Hardware:** SQRL FK33, `xcvu33p-fsvh2104-2L-e` (ES1 die), Gigabyte Z790 AERO G,
BIOS F12, kernel 6.8.0-138-generic. Vivado 2023.2.
**Starting bitstream:** `hw/fk33/bit/fk33_pcieep.bit`, 12,227,950 bytes, built
2026-08-27 22:58:46.
**Status:** built, routed, timing closed, and every claim about the constraints
verified against the ROUTED checkpoint. **Nothing here is verified on silicon.**
No hardware command was run at any point; a hard freeze on hardware access was
in force for the second half of this work and is respected in full (section 10b).
Artefact: `hw/fk33/bit/fk33_pcieep_aux.bit`, 12,098,118 bytes.

---

## 2. The answer, up front

**The premise the task was handed was wrong, and correcting it is the finding.**
The debug hub in `fk33_pcieep` is NOT on a free-running clock: the XDC clocks it
from `hbm/.../APB_0_PCLK`, which in the `EnablePCIe == 1` branch is an MMCM
output whose reference is `xdma/axi_aclk` and whose MMCM is held in reset by
`xdma/axi_aresetn`. There was no clock anywhere in that bitstream that survives
the link being down. So the asset was not "unspent" -- it did not exist.

**A real free-running clock does exist and was never used in the endpoint build:
the FK33's 200 MHz board oscillator on BC26/BC27 (`sysref_clk`).** It is the only
clock every `EnablePCIe == 0` bitstream in this repository has ever run from, and
all of those have been configured and exercised on this card with no host and no
PCIe. The endpoint build simply left it unconnected. Everything delivered here
hangs off it: the status registers, a third JTAG-AXI master to read them, the
debug hub's clock, and an autonomous VCCINT controller hardcoded to wiper 68.

Configuration time is **191.8 ms nominal** for the old bitstream, confirming the
estimate in the task independently, against a spec-minimum budget of 200 ms.
That is over budget once anything else is counted. The instrumented build is
**189.8 ms**, i.e. 2 ms FASTER and 129,832 bytes smaller -- the opposite of what
was predicted, and measured rather than assumed. The instrumentation also
measures whether this particular platform actually gives more than the spec
minimum, which is the only thing that settles it.

Two things could not be delivered as asked and were not forced. **LTSSM** is not
a pin at this XDMA configuration. **A direct counter on `pcie_refclk`** was
built and killed at `route_design` by `DRC BFGTL-1`; the design measures
`xdma/axi_aclk` instead, which with the PERST# level answers the same question
by elimination. Both are in sections 4.2 and 4.6.

---

## 3. The procedure, in the order it was run, and what each step isolates

### 3.1 Read the generator, not the XDC, to test the free-running claim

The handoff's claim rests on one XDC line:

```tcl
connect_debug_port dbg_hub/clk [get_nets bd_i/hbm/inst/TWO_STACK.u_hbm_top/APB_0_PCLK]
```

The XDC names a net; it does not say what drives it. `build_fk33_i2cprobe.tcl`
does. Three lines settle it, and they cost nothing to find:

```tcl
# common section, line 168
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_0_PCLK]
# inside "if {$EnablePCIe == 1}", lines 253 and 290
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins clk_wiz_0/clk_in1]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins clk_wiz_0/resetn]
```

This isolates: whether the hub clock is independent of PCIe. It is not, in this
branch. In the `EnablePCIe == 0` branch the same `clk_wiz_0` is fed by the sysref
oscillator instead, which is why the probe bitstream works on the bench and why
the two cases were easy to conflate.

**Control this measurement carries:** it is a source-level fact, not an
inference from a hardware reading, so it is not contingent on the card being
powered or on how Vivado enumerates cores.

### 3.2 Ask the IP what pins exist, rather than assuming, for LTSSM

An in-memory Vivado session, no project, no card: instantiate `xdma:4.1` with
this design's settings and list `get_bd_pins xdma/*`. Isolates "the task asks
for LTSSM; is it reachable without changing the IP configuration".

### 3.3 Check the module compiles and is small, before touching the block design

Standalone out-of-context synthesis of `rtl/fk33_aux.vhd`. Isolates VHDL and
UNISIM-instantiation errors from block-design errors, at about 90 seconds
instead of 13 minutes.

### 3.4 Block-design-only build

`./pcieep_build.sh --bd-only` (~3 minutes). Isolates IP configuration, cell
connectivity, address assignment and BD validation from synthesis, placement and
timing. This is where the structural claim is checked: a loop added to the BD
check block walks every pin of every aux cell and reports any that shares a net
with `xdma/axi_aclk`.

### 3.5 Simulate the pot controller against a behavioural MCP45xx

`./sim_aux.sh` (~15 s). Isolates the I2C byte order, bit order, ACK handling and
the read-before-write / verify-after-write logic from everything else. This is
not optional: the controller moves a real power rail on an ES1 die with no host
in the loop, and reading VHDL is not a way to be sure of a bit order. The
testbench asserts, in code, that the only data byte ever put on the bus is
`0x44`.

It also runs long enough to exercise the one-second `UCLK_HZ` window, and to
check that the reading falls to zero when the measured clock stops.

### 3.6 Full build

`./pcieep_build.sh` (~15 minutes, ~5.9 GB peak). The only step that produces
timing, placement, routing and a bitstream size -- and the only one that can
report a DRC. Both of the design changes forced on this work (`BUFG_GT`, and
the XDC `if`) were invisible until here.

### 3.6b Verify the constraints on the ROUTED checkpoint, not on the intent

`open_checkpoint bd_wrapper_routed.dcp`, then ask the implemented design which
clock reaches `dbg_hub/clk`, how many clocks exist on `sysref_clk_p[0]`, and
whether any path crossing the aux boundary is still analysed. This is separate
from the build on purpose: XDC constraints can be silently skipped, and the only
way to know one took effect is to interrogate the netlist that came out.

### 3.7 Configuration-time arithmetic from the artefact, not from the file size

The `.bit` file's `e` field carries the configuration data length. Parsed
properly (sequential header walk, not a search for byte 0x65, which is an
ordinary byte inside a design name).

---

## 4. The evidence

### 4.1 The debug hub's clock is downstream of xdma

Verbatim from `hw/fk33/build_fk33_i2cprobe.tcl`:

```
168:connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_0_PCLK]
253:    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins clk_wiz_0/clk_in1]
290:    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins clk_wiz_0/resetn]
```

Lines 253 and 290 are inside `if {$EnablePCIe == 1}`. Line 168 is common.

### 4.2 LTSSM is not a pin at this IP configuration

```
PIN /xdma/axi_aclk
PIN /xdma/axi_aresetn
PIN /xdma/user_lnk_up
PIN /xdma/sys_clk
PIN /xdma/sys_clk_gt
PIN /xdma/sys_rst_n
PIN /xdma/msi_enable
PIN /xdma/msi_vector_width
PIN /xdma/usr_irq_ack
PIN /xdma/usr_irq_req
  (plus pci_exp_* and the two AXI interfaces; 49 pins total, no LTSSM)

PROP CONFIG.enable_ltssm_dbg = false
PROP CONFIG.en_debug_ports = false
PROP CONFIG.en_transceiver_status_ports = false
PROP CONFIG.enable_jtag_dbg = false
```

`user_lnk_up` IS a pin and needs nothing. LTSSM requires flipping
`CONFIG.enable_ltssm_dbg` (or `CONFIG.en_debug_ports`), which is a change to the
XDMA IP configuration. Per the instruction not to force it, it was not changed.
It is a one-line change in `gen_pcieep.py` if it is ever wanted.

### 4.3 The aux module synthesizes, and is negligible

```
Report Cell Usage:
|BUFG    |     1|
|BUFG_GT |     1|     <- REMOVED in the final design; see 4.6
|CARRY8  |    21|
|LUT1..6 |   205|
|SRL16E  |     1|
|FDRE    |   306|
|IOBUF   |     2|
```

No errors. The only non-trivial warnings are `Synth 8-6014` (an unused
`ms_tick` register removed) and the expected flood of `Synth 8-3917`
constant-driven output ports, which is what a read-only magic word looks like.

### 4.4 Block design: the aux branch touches nothing xdma clocks

From the `FK33_STOP_AFTER_BD` run:

```
FK33_AUX LNK user_lnk_up wired into the aux status word
FK33_CFG pcie2axil.NUM_SI = 2
FK33_CFG pcie2axil.NUM_MI = 4
FK33_AUX_CLKCHECK violations=0
FK33_BD_VALIDATE OK
```

No `FK33_CFG MISSING AUX CELL` lines, so all eight aux cells exist. Zero
`12-584` unmatched constraints. Zero `BD 41-1377` address-overlap criticals
after the exclude sequence.

The address map, read back from the tool:

```
FK33_MAP /jtag_aux/Data  /jtag_aux/Data/SEG_aux_id_Reg     0x00000000  0x00001000
FK33_MAP /jtag_aux/Data  /jtag_aux/Data/SEG_aux_clkst_Reg  0x00001000  0x00001000
FK33_MAP /jtag_aux/Data  /jtag_aux/Data/SEG_aux_stat_Reg   0x00002000  0x00001000
FK33_MAP /jtag_aux/Data  /jtag_aux/Data/SEG_aux_time_Reg   0x00003000  0x00001000
FK33_MAP /xdma/M_AXI_LITE .../SEG_system_management_wiz_0_Reg 0x00003000 0x00001000
FK33_MAP /xdma/M_AXI_LITE .../SEG_axi_gpio_0_Reg           0x00009000  0x00001000
FK33_MAP /xdma/M_AXI_LITE .../SEG_fk33_id_Reg              0x0000A000  0x00001000
FK33_MAP /xdma/M_AXI_LITE .../SEG_fk33_scratch_Mem0        0x00010000  0x00002000
```

The four aux segments appear in `jtag_aux/Data` and **in no other address
space**. That is the structural proof the read path avoids `xdma/axi_aclk`:
there is no path from xdma to those registers to be clocked at all. The
`FK33_AUX_CLKCHECK` loop is the second, independent check, at the pin level.

### 4.5 The pot controller, simulated against a behavioural MCP45xx

`./sim_aux.sh`, verbatim:

```
Note: POT_STATUS = 0x44440021
Note: AUX_STATUS = 0xA5A5E01D
Note: AUX_MS     = 22
Note: PERST_MS   = 2
Note: UCLKTICKS  = 175
Note: UCLK_HZ    = 999936
Note: UCLK_HZ after the clock stopped = 0
Note: TB_FK33_AUX PASS
```

Decoded, and each field is a separate assertion in the testbench:

* `POT_STATUS[31:24] = 0x44` -- the wiper this bitstream is able to write is 68.
* `POT_STATUS[23:16] = 0x44` -- and 68 is what the pot read back afterwards.
* `POT_STATUS[5:4] = 2` (the verify transaction), `[0] done = 1`,
  `[1] failed = 0`, `[2] owns-bus = 0`, `[3] nack = 0`, attempts 0.
* Exactly 2 reads and exactly 1 write reached the model, in that order, and the
  model's own assertions fired on none of the address byte (`0x58`/`0x59`), the
  command byte (`0x00`) or the data byte (`0x44`).
* `AUX_STATUS = 0xA5A5E01D`: PERST# level 1, level-at-configuration 0, both
  stickies set, deassertion count 1, `PERST_MS` valid, refclk-ever-ticked set,
  and the fixed `0xA5A5` field intact.
* `PERST_MS = 2` for a deassertion at 2.5 ms.
* `UCLK_HZ = 999936` against a 1 MHz stimulus. The residual is the divider
  granularity, 7812 toggles x 128 = 999,936, and it is exactly what the design
  should produce.
* With the user clock stopped, the tick counter freezes and `UCLK_HZ` falls to 0
  at the first window that is entirely after the stop.

**The simulation found two real bugs that static review had not.** Both are in
section 9.

### 4.6 The BUFG_GT refclk tap is illegal, and it fails at route_design

This is why `UCLK_HZ` measures the PCIe user clock rather than the reference
clock. The first implemented build carried a second `BUFG_GT` on
`util_ds_buf_0/IBUF_DS_ODIV2`, the same net that already feeds `xdma/sys_clk`.
It passed synthesis, placed, and then:

```
CRITICAL WARNING: [DRC BFGTL-1] bad_BUFG_GT_muxing: Invalid CE or CLR
connectivity for BUFG_GT cells bd_i/fk33_aux_0/inst/u_bufg_gt and
bd_i/xdma/inst/pcie4c_ip_i/inst/bufg_gt_sysclk. The CE and CLR pins of BUFG_GT
cells that share a common clock input should be driven by the same net. The CE
pin with net bd_i/xdma/inst/pcie4c_ip_i/inst/sync_sc_ce of the first cell is not
the same as the net on that pin for the other cell, which is
bd_i/fk33_aux_0/xlnx_opt_. These nets must be the same because the input clock
net bd_i/util_ds_buf_0/U0/IBUF_DS_ODIV2[0] is the same for both cells.

CRITICAL WARNING: [Route 35-54] Net: bd_i/util_ds_buf_0/U0/IBUF_DS_ODIV2[0] is
not completely routed.
CRITICAL WARNING: [Route 35-7] Design has 1 unroutable pin ...
ERROR: [Route 35-4445] route_design is terminated due to errors/critical
warnings issued before and during initial routing.
```

It is not a soft check. BUFG_GTs fed from one GT clock source share the CE/CLR
mux in the clock tile, so they must be driven from ONE `BUFG_GT_SYNC`. XDMA
instantiates its own (`sync_sc_ce` / `sync_sc_clr`) inside the IP and exposes
neither, and Vivado inserts a separate one for any BUFG_GT you add.

**Waiving BFGTL-1 was considered and rejected outright.** The net in question is
the PCIe reference clock into the hard block. Waiving a DRC that says it cannot
be routed correctly, on the one net the entire endpoint depends on, to gain a
diagnostic about that same net, is not a trade worth making.

There is no other route to the raw reference clock: `IBUFDS_GTE4` `ODIV2` can
only drive a `BUFG_GT`, `AD9/AD8` are GT refclk balls and cannot be used as
ordinary LVDS inputs, and a second `IBUFDS_GTE4` on the same pair is illegal.
GT status ports would need `CONFIG.en_transceiver_status_ports`, an IP
configuration change, which is out of scope by the same rule as LTSSM.

### 4.7 Configuration time, computed from the shipped bitstream

```
FK33_CFGTIME data=12227820 bytes (97822560 bits), 24455640 CCLK cycles at x4
FK33_CFGTIME   nominal 127.5 MHz ->   191.8 ms
FK33_CFGTIME   -15%    108.4 MHz ->   225.7 ms
FK33_CFGTIME   +15%    146.6 MHz ->   166.8 ms
```

Cross-check on the length: `bit/fk33_pcieep.prm` says the flash image runs
`0x00000000 .. 0x00BA94EB`, which is 12,227,820 bytes, the same number, so the
`.mcs` the flash work is producing carries exactly this much data.

---

## 5. What was built

### 5.1 `hw/fk33/rtl/fk33_aux.vhd`

New. Runs entirely on the 200 MHz sysref oscillator through a plain `BUFG` --
no MMCM, so nothing to lock and nothing anyone can hold in reset.

| offset (on `jtag_aux`) | register | meaning |
|---|---|---|
| 0x0000 | `AUX_MAGIC` | `0x41555831` = "AUX1", a fabric constant |
| 0x0008 | `AUX_VERSION` | `0x20260828` |
| 0x1000 | `UCLK_TICKS` | free-running; 1 tick per 128 `xdma/axi_aclk` cycles |
| 0x1008 | `UCLK_HZ` | measured `xdma/axi_aclk` in Hz. 250,000,000 = the PCIe hard block is clocked; 0 means it is not, and the PERST# level says which reason |
| 0x2000 | `AUX_STATUS` | PERST# level and level-at-configuration, its stickies, a saturating deassertion count, `xdma/axi_aresetn`, `user_lnk_up`, refclk-alive, and a fixed `0xA5A5` field |
| 0x2008 | `POT_STATUS` | the VCCINT controller. `[31:24]` is the only wiper this bitstream can write and must read `0x44` |
| 0x3000 | `AUX_MS` | milliseconds since configuration |
| 0x3008 | `PERST_MS` | `AUX_MS` at the FIRST deassertion of PERST# |

`UCLK_HZ` is a frequency measurement, not a liveness bit: it counts a divided
single-bit toggle from the PCIe user-clock domain over exactly one second of aux
clock and scales by 128. "Present but at the wrong rate" is therefore visible,
and it is not the same reading as "present".

**It measures the PCIe USER clock, not the raw reference clock, and that is a
forced substitution, not a preference.** A direct `pcie_refclk` counter was
designed, built and rejected on a DRC; see section 7. Read together with the
PERST# level it still answers the question the task asked, by elimination:

| `UCLK_HZ` | PERST# | reading |
|---|---|---|
| ~250 MHz | either | reference clock present, PLL locked, block running. A down link is a TRAINING failure. |
| 0 | high | the block is out of reset and still has no clock. **The host is not driving a reference clock.** |
| 0 | low | we are simply held in reset. Says nothing about the reference clock. |

The cost is one inference step in the second row instead of a direct reading.

`PERST_MS` together with `AUX_STATUS[1]` is the flash-boot timing measurement.
`AUX_STATUS[1] = 0` with `PERST_MS` valid means the FPGA was configured and
watching before the host released reset. `AUX_STATUS[1] = 1` means reset had
already been released when configuration finished -- the loss condition, which
today is indistinguishable from a card that never worked.

The saturating PERST# deassertion count also answers something section 2 of the
handoff left open: whether the host pulses PERST# at all across a warm reboot.

### 5.2 The autonomous VCCINT controller, in the same module

Reproduces the byte sequence of `tcl/vccint_step.tcl` rather than inventing one:

```
read  : START, 0x59,             read hi, read lo (NAK), STOP
write : START, 0x58, 0x00, 0x44,                         STOP
```

with `lines`-equivalent steps of 5 us, three per bit, giving ~67 kHz SCL. It
starts 10 ms after configuration and finishes in under a millisecond.

Safety, by construction rather than by care:

* `C_WIPER_BYTE` is a constant derived from `G_POT_WIPER`, which defaults to 68
  and carries `assert G_POT_WIPER = 68 ... severity failure` at elaboration. It
  appears in exactly one stage of one transaction. Nothing computes it, nothing
  outside can set it, and `gen_pcieep.py` refuses to emit a build if either the
  default or the assertion is gone. **A controller that can only ever write one
  value cannot overshoot.** 68 measures 0.717 V, inside the 0.698-0.742 V window
  that is in spec for both -2L and -2LV.
* It READS the wiper first and refuses to write unless the device acknowledges
  and the current value is inside 60..128 -- the same sanity band the Tcl script
  enforces. Three attempts, then it gives up without writing.
* It reads back after writing and reports a mismatch rather than retrying.
* A hard timeout releases the bus whatever happens.
* Open drain in both directions: the output value is hardwired to `'0'` while
  the controller owns the bus, so no line is ever driven high.
* The AXI GPIO owns the pins whenever the controller is idle, so
  `host/fk33ctl.py vccint` and `tcl/vccint_step.tcl` work unchanged.

A single 128 -> 68 write does not need the Tcl's careful stepping: every
intermediate wiper is a LOWER voltage than 68 gives, so there is no overshoot
path, and dV/dwiper is already measured.

### 5.3 Clock-domain crossings

**Every crossing into the aux domain is a single bit through a two-stage
`ASYNC_REG` synchroniser. There is no multi-bit CDC anywhere.** The
reference-clock counter is deliberately NOT transported across; an 8-bit divider
in the reference-clock domain produces one toggle every 128 cycles, that single
bit is synchronised, and the counting happens on the aux side. So the constraint

```tcl
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks $fk33_auxclk]
```

is sufficient and correct, with no bus-skew obligation. A multi-bit crossing
would have needed `set_bus_skew` and would not have been allowed to rely on it.

The clock itself is defined name-independently, through the PORT:

```tcl
if {[llength [get_clocks -quiet -of_objects [get_ports {sysref_clk_p[0]}]]] == 0} {
    create_clock -period 5.000 -name sysref_clk [get_ports {sysref_clk_p[0]}]
}
```

so it is created if the BD did not create one and reused if it did, and either
way the build log records which happened (`FK33_AUXCLK`).

`pcie_perstn` keeps no input delay, exactly as it already had none for
`xdma/sys_rst_n`, so it contributes no timed path; its receiving flip-flops
carry `ASYNC_REG`.

### 5.4 The debug hub moved

The two upstream debug-hub lines are superseded, and `gen_pcieep.py` aborts if
it does not find exactly two of them to supersede. The replacement finds the
buffered aux clock by the `KEEP`/`DONT_TOUCH` name `fk33_freeclk` that the RTL
pins down, and **errors out** rather than silently leaving the hub on a clock
that stops:

```tcl
set fk33_hubnet [get_nets -quiet -hierarchical -filter {NAME =~ "*fk33_freeclk*"}]
...
error "fk33_aux free-running clock net not found; refusing to leave the debug
       hub on a clock that stops with the PCIe link"
```

### 5.5 Scripts

* `hw/fk33/tcl/aux_probe.tcl` -- new, the instrument. Identifies the aux master
  by asking every master for `0x41555831` at offset 0, decodes all eight
  registers, prints a verdict per question, and reads SYSMON through
  `get_hw_sysmons` (JTAG DRP, no design clock).
* `hw/fk33/tcl/pcieep_jtag.tcl` -- the `REGISTER.IDCODE` line that aborted the
  whole script is gone; `refresh_hw_device -update_hw_probes false` replaces it;
  masters are identified by probing rather than by index; `-1` is checked for
  explicitly instead of being compared as a value.
* `hw/fk33/tcl/vccint_verify.tcl` -- reads VCCINT through `get_hw_sysmons`
  first, unconditionally, then probes JTAG-AXI once and stops with an
  explanation instead of emitting 28 x `No matching hw_axi_txns were found`.
* `hw/fk33/pcieep.sh` -- new stage 3a runs the aux probe before the old check.
* `hw/fk33/pcieep_build.sh` -- greps the new markers, and computes the
  configuration time from the bitstream it just built.

---

## 6. Configuration time: the arithmetic, and the verdict

```
configuration data           12,227,820 bytes   (the .bit 'e' field, and the
                                                 .prm's 0x0..0xBA94EB)
                          =  97,822,560 bits
SPIx4, 4 bits per CCLK    =  24,455,640 CCLK cycles
CONFIGRATE 127.5 MHz      =       191.8 ms
```

**The estimate in the task is correct.** Four things make it worse, not better:

1. **CONFIGRATE is a nominal setting on an internal oscillator, not a clock.**
   The XDC's own comment assumes 15% tolerance. At -15% the same bitstream takes
   **225.7 ms**.
1b. **`CONFIGRATE 127.5` is already ABOVE the device's own ceiling.** Reported by
   another agent working the flash path on the same day: DS923's `FMCCK`
   (master-mode CCLK) maximum is **125 MHz**, so 127.5 is out of spec before the
   oscillator tolerance is applied at all. Worse, the XDC comment that justifies
   it -- "flash part accepts 166" -- is citing the **MT25QL**, the 3 V part. The
   FK33 carries an **MT25QU**, the 1.8 V part, rated **133 MHz**. So the headroom
   the comment claims does not exist, and "raise CONFIGRATE to 170" is not a
   lever, it is a fault. Treat the mitigation list below accordingly.
2. **Configuration does not begin at the CONFIGRATE.** The first part of the
   stream is read at the default master CCLK and in x1 until bus-width detection
   and the COR0 register are processed. That is a small fixed cost, order 1-2 ms,
   but it is on the wrong side.
3. **The budget is not 200 ms of shifting.** 100 ms of T_PVPERL plus the ~100 ms
   the host waits after PERST# deasserts is the whole window, and out of it also
   come the FPGA power-on reset, the flash's own power-up, the startup sequence
   after the last configuration bit, GT lock, and link training.

So at the spec minimum the design does not fit, and at -15% it misses by more
than 25 ms.

**Two things stop this being a verdict of "it cannot work".** First, a desktop
platform deasserts PERST# far later than the 100 ms minimum -- PCH PLTRST# on a
Z790 typically lags rail power-good by hundreds of milliseconds. Second, and
this is the point of the instrumentation: `AUX_STATUS[1]` and `PERST_MS` measure
exactly this, on this board, on the first flash boot. Until then the margin is
unknown, not absent.

**Say it plainly: a configuration-time overrun presents as a root port the BIOS
hides, which is bit-for-bit the symptom already seen.** Without the
instrumentation the two are indistinguishable, and a week could be spent on the
wrong one.

If it does turn out to be over budget, the levers, in the order they should be
considered:

* **Measure first.** `PERST_MS` says how much margin there actually is.
* **CONFIGRATE 170. WITHDRAWN, do not do this.** It was on this list before the
  DS923 `FMCCK` = 125 MHz ceiling and the MT25QU (1.8 V, 133 MHz) part number
  came to light. The setting is already out of spec at 127.5; raising it is
  moving in the wrong direction. If anything the honest change is to LOWER
  CONFIGRATE into spec, which makes the budget worse, not better, and forces the
  problem onto the payload size instead.
* **Shrink the design.** Compression is already on. The HBM controller and the
  `pblock_bd_i` spread are what set the frame count.
* **`BITSTREAM.CONFIG.EXTMASTERCCLK_EN`.** Already present and commented out in
  the XDC. Needs a board clock on CCLK, which is not established for the FK33.

**The instrumented build makes the bitstream bigger.** Exact numbers in
section 8.

---

## 6b. Facts learned after this work was dispatched, and what they change

All of these arrived from the coordinator on 2026-08-28 while the build was
running. None was known when the design above was written; all of them make it
more useful, not less.

* **The FK33 enumerates.** At the time of writing it is live at `0000:06:00.0`,
  `1e24:1533`, Gen3 x4, behind root port `0000:00:1d.0`, running the SQRL
  FACTORY image out of the card's own SPI flash. **So a flash-booted FK33 does
  configure inside the PCIe window on this board and BIOS.** The window is
  beatable. The open question is only whether OUR 12.2 MB payload beats it,
  which is exactly the arithmetic in section 6 and exactly what `PERST_MS`
  measures.
* **The first-fit handoff names the wrong root port.** The card is not on
  `00:1c.4`; `1c.4` is absent because the RTX 3090 was removed from it. The
  relevant port is `00:1d.0`, and it stays VISIBLE across a PCI device removal.
  That is new and it matters: a JTAG-configured design now has a LIVE root port
  to train against, which was never true when the handoff was written. The
  experiment is PCI remove, `./pcieep.sh`, rescan -- and this instrumentation is
  what turns its outcome from an inference into a measurement.
* **A direct positive control for the autonomous pot controller.** Under the
  SQRL factory image VCCINT measures **0.715 V, not 0.678**. SQRL's own design
  raises the pot itself, autonomously, after configuration, and the card still
  enumerates at Gen3 x4. So the approach implemented here is not novel and not
  speculative: it is what the working reference design already does on this
  board. It also settles a question in section 10 -- a design CAN train while
  the pot is being raised, so nothing should gate PCIe reset on the ramp
  completing. `fk33_aux` does not: it drives two I2C pins and touches no reset
  anywhere.

## 7. Measured and REJECTED -- do not retry

* **"The ILA debug hub answers over JTAG while the fabric is dead."** REJECTED
  at the source level: `clk_wiz_0/clk_in1` is `xdma/axi_aclk` and
  `clk_wiz_0/resetn` is `xdma/axi_aresetn` in the `EnablePCIe == 1` branch, so
  `hbm/APB_0_PCLK` is neither free-running nor out of reset. Do not build
  anything else on this premise. The corollary is in section 9.
* **Hanging the aux registers off `pcie2axil` so the host can read them too.**
  Rejected without building: the smartconnect is configured with a single `aclk`,
  so a second clock domain needs `NUM_CLKS` and per-port clocks, and every one of
  those ports would then have a path to `xdma/axi_aclk`. The isolation is worth
  more than the convenience, and the host already has `fk33_id`, SYSMON and the
  scratch RAM.
* **Reaching LTSSM.** Not available as a pin at this IP configuration; see 4.2.
  Not forced.
* **A direct counter on `pcie_refclk`, via a second `BUFG_GT` on the
  `IBUFDS_GTE4` ODIV2 tap.** Built, synthesized, placed, and killed at
  `route_design` by `DRC BFGTL-1`. Full text in 4.6. **Do not retry it, and do
  not waive the DRC**: the net is the PCIe reference clock into the hard block.
  The user-clock measurement plus the PERST# level covers the same question in
  every case except one, at the cost of one inference step.
* **Transporting the reference-clock counter across the CDC as a gray-coded
  bus.** Rejected in favour of a divided single-bit toggle, specifically so that
  `set_clock_groups -asynchronous` is a complete constraint rather than a
  convenient one.
* **`BUFGCE_DIV` to halve the aux clock to 100 MHz.** Considered, to keep the
  debug hub at the frequency the current XDC already declares and to relieve
  timing. Rejected because it introduces an auto-derived generated clock whose
  existence the constraints would then depend on. A plain `BUFG` gives exactly
  one clock, named on the port, and the constraint story has nothing to get
  wrong.

---

## 8. Build results

Full `./pcieep_build.sh`, 2026-08-28 13:24-13:39. The design implements, routes
and closes timing.

```
FK33_AUX LNK user_lnk_up wired into the aux status word
Designutils 20-1307 (XDC commands silently skipped)   0
DRC BFGTL-1                                           0
12-584 unmatched constraints                          0
BD 41-1377 after the exclude sequence                 0

FK33_TIMING WNS=0.376 ns   WHS=0.010 ns
BITSTREAM bd_wrapper.bit  12,098,118 bytes
```

Constraint verification, run against the ROUTED checkpoint
(`bd_wrapper_routed.dcp`) so it reflects the implemented design and not the
intent:

```
FK33_AUXCLK clocks=sysref_clk
FK33_AUXCLK period=5.000 ns
FK33_AUXCLK analysed paths crossing the aux boundary: 0 (must be 0)
FK33_HUBCLK pins=dbg_hub/clk dbg_hub/inst/clk ... clocks=sysref_clk
FK33_HUBCLK OK dbg_hub is on sysref_clk
FK33_AUX all aux cells present in the implemented design
```

**`FK33_HUBCLK OK` is the single most important line in this document.** The
debug hub is on the free-running board oscillator in the implemented netlist.
Everything else in the aux domain is reachable only because of it.

Every path that ends inside `bd_i/fk33_aux_0` is `sysref_clk -> sysref_clk`,
with 2.9-3.0 ns of slack. The only paths that cross the boundary are Xilinx's
own debug-hub-to-JTAG-AXI synchronisers -- the hub is now on `sysref_clk` while
`jtag_axil` and `jtag_hbm` stay on the PCIe clock -- and all of them report an
empty slack and `GROUP (none)`, i.e. the asynchronous clock group excluded them
from analysis:

```
OUT slack= grp=(none) sclk=sysref_clk eclk=<xdma domain>
           ep=bd_i/jtag_axil/inst/jtag_axi_engine_u/tx_fifo_i/.../gpr1.dout...
IN  slack= grp=(none) sclk=<xdma domain> eclk=sysref_clk
           ep=bd_i/jtag_hbm/inst/jtag_axi_engine_u/status_reg_datain_ff_reg[0]/D
AUXEP slack=2.902 sclk=sysref_clk eclk=sysref_clk
      ep=bd_i/fk33_aux_0/inst/uclkhz_reg[24]/CE
```

### The instrumented bitstream is SMALLER, not larger

This was predicted to go the other way and the prediction was wrong. Measured:

| | configuration data | nominal 127.5 MHz | -15% |
|---|---|---|---|
| `bit/fk33_pcieep.bit` (2026-08-27, no aux domain) | 12,227,820 B | 191.8 ms | 225.7 ms |
| `bit/fk33_pcieep_aux.bit` (this build) | 12,097,988 B | **189.8 ms** | **223.3 ms** |
| delta | **-129,832 B** | **-2.0 ms** | **-2.4 ms** |

Compression is frame-based, so the payload tracks how many frames differ from
the default, not how many cells the design contains. About two thousand extra
cells in one corner changed the placement enough to compress marginally better.
**Do not generalise this**: it is a measurement of these two builds, not a rule,
and 2 ms of a 200 ms budget is noise. The honest statement is that the
instrumentation did NOT make the configuration-time problem worse.

Saved as `hw/fk33/bit/fk33_pcieep_aux.bit` and `fk33_pcieep_aux.ltx`.
**Deliberately NOT written over `bit/fk33_pcieep.bit`**, which the user was
programming by hand at the time under the hardware freeze.

---

## 9. Measurement traps hit, including our own

* **Ours: the PERST# edge detector compared the wrong two synchroniser stages,
  and nothing static would have caught it.** `syn_perst <= syn_perst(0) & perstn`
  makes stage 0 the NEWEST sample and stage 1 the older one; the edge test read
  `syn_perst(1) = '1' and syn_perst(0) = '0'`, which is a FALLING edge on a
  deassert-high signal. `PERST_MS` and the deassertion count would have read 0
  forever, on hardware, silently -- and `PERST_MS` is the single most important
  register in the set. Found in the first simulation run. Fixed by going to a
  three-stage synchroniser so the edge is detected between two fully
  synchronised samples rather than off a single-stage one.
* **Ours, and it cost a whole 13-minute build: Vivado's XDC reader forbids Tcl
  control flow, in BOTH synthesis and implementation, and skips the block
  silently.** The first version of the aux constraints used `if` to create the
  clock only when one did not already exist, and to fail loudly if the debug-hub
  net could not be found. Vivado emitted

  ```
  CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported in the
  xdc constraint file. [.../fk33_pcieep.xdc:177]
  ```

  three times and then executed none of it. The build completed, timing closed,
  a bitstream was produced -- and it had no `create_clock` on the aux domain, no
  `set_clock_groups`, and a debug hub still on whatever clock `opt_design`
  happened to pick. Three CRITICAL WARNINGs are easy to lose in a log that
  already carries six pblock-alignment warnings. **A defensive `if` in an XDC is
  worse than no `if`: it converts a loud failure into a silent one.** Everything
  is now unconditional, `pcieep_build.sh` greps for `Designutils 20-1307` and
  requires zero, and the verification moved to the implemented design where full
  Tcl is legal.
* **Ours: `KEEP` and `DONT_TOUCH` on an RTL signal do NOT preserve its name
  across a block-design module reference.** `bd_i/fk33_aux_0` is synthesized
  out-of-context as `bd_fk33_aux_0_0`, so in the top-level checkpoint it is a
  black box with 271 pins and no internal nets at all; a
  `get_nets -hierarchical -filter {NAME =~ "*fk33_freeclk*"}` matches nothing.
  The reliable handle is the module's PIN (`bd_i/fk33_aux_0/aux_clk`), whose
  cell and port names this generator sets, not an internal net name that
  synthesis chooses.
* **Ours: scaling a testbench down too far broke the design under test.** Run at
  a 200 kHz aux clock so the one-second measurement window would be cheap to
  simulate, `C_STEP_CYCLES` collapsed to 1, the two-stage SDA synchroniser had
  not settled when the bit was sampled, every read came back skewed and the
  controller reported the pot NACKing three times. That is a testbench artefact,
  not a design fault at 200 MHz -- but it is now an elaboration assertion
  (`C_STEP_CYCLES >= 8`) so nobody has to work it out twice.
* **Ours, and the important one: an XDC line names a net, it does not say what
  drives it.** The whole free-running premise came from reading
  `connect_debug_port dbg_hub/clk [get_nets .../APB_0_PCLK]` and stopping there.
  The driver is three lines away in a different file and in a conditional branch.
  When a claim about a clock rests on a constraint, go and find the
  `connect_bd_net`.
* **`get_hw_axis` returning the expected number of masters is not proof the
  debug hub answered.** The handoff reads `AXI_MASTERS hw_axi_1 hw_axi_2` as
  evidence that the hub is alive. It is consistent with that, and it is also
  consistent with Vivado having created those objects while every transaction
  through them failed. It was not possible to separate the two without the card,
  and after this change it does not matter: the hub is on a clock that runs.
* **`get_hw_axis` order is not stable.** Adding `jtag_aux` can renumber
  `hw_axi_1` and `hw_axi_2`, so `[lindex $axis 1]` is one build away from reading
  the wrong master and blaming the card. Every script here now identifies masters
  by asking them for a magic word.
* **A failed JTAG-AXI transaction reports as `-1`, not as an error** (recorded in
  the handoff, hit again while rewriting the scripts). Two of the scripts wrapped
  the read in `catch` and treated a non-throwing `-1` as data.
* **Parsing a `.bit` header by searching for the byte `0x65`.** It is the `e`
  key that introduces the configuration data length, and it is also an ordinary
  byte inside a design name. The header must be walked field by field.
* **`du`-style reasoning about bitstream size.** The `.bit` FILE is 12,227,950
  bytes; the configuration DATA is 12,227,820. The 130-byte difference does not
  matter here, but taking the file size as the shift length is the kind of thing
  that silently biases a marginal budget.

---

## 10. Open, not yet answered

* **Everything on silicon.** The card was not powered. No register in this
  document has ever been read from hardware.
* Whether the 200 MHz sysref oscillator is genuinely independent of the PCIe
  slot's power rails as well as of its clock. It runs with no host on the bench,
  which is what matters, but it has never been observed while the card is in a
  slot and the port is disabled.
* Whether `BUFG_GT` on the `IBUFDS_GTE4` ODIV2 tap coexists with the XDMA IP's
  own use of the same net on real silicon. It builds; that is not the same claim.
* Whether the pot at 0x2c responds to a 67 kHz hardware bit-bang the same way it
  responds to the Tcl's very slow one. The byte sequence is identical and is
  verified against a behavioural model; the timing is not, and the model is not
  the part.
* The controller requires the read-back wiper to land in 60..128, which implies
  a zero high byte. `tcl/vccint_step.tcl` printing `START wiper=128` on this
  exact board is direct evidence that it does. If it ever does not, the
  controller fails SAFE -- it declines to write and reports reason 2 -- so
  VCCINT stays at 0.678 V rather than moving somewhere unintended. That is the
  right failure direction but it is still a failure, and on a flash boot there
  would be no second chance to notice it except by reading `POT_STATUS`.
* Whether the link trains at 0.678 V, i.e. whether the autonomous controller
  needs to complete BEFORE training or merely before sustained operation. It
  starts 10 ms after configuration, well inside the 100 ms the host waits, so
  this should not bind -- but it is untested.
* Whether the real flash-boot margin on this Z790 is positive. `PERST_MS`
  answers it in one read.

---

## 10b. Hardware freeze

**A hard freeze on all hardware access was in force for the second half of this
work, and no hardware command was run at any point.** Everything above is
Vivado in `-mode batch`: block-design elaboration, out-of-context synthesis,
xsim, and one implementation run. No `open_hw_manager`, no `hw_server`, no
`xsdb`, no `jtag.sh`, no `pcieep.sh`.

Files under `hw/fk33/tcl/` and `hw/fk33/pcieep.sh` were edited BEFORE the freeze
was announced, the last write being **2026-08-28 12:46:14**. Nothing has been
written to them since. If the user's `pcieep.sh` run started before that time it
may have been affected -- bash reads a script incrementally -- and that run
should be treated as suspect.

One edit made before the freeze is **known to be wrong and is held pending**:
`pcieep.sh`'s header now claims in the present tense that the endpoint bitstream
raises VCCINT by itself. `bit/fk33_pcieep.bit` is dated 2026-08-27 22:58 and
contains no such state machine. The corrected wording is held in
`HELD_pcieep_sh_patch.md` in this session's scratchpad and must be applied when
the freeze lifts. It is the same class of defect this project keeps finding: a
contract that is wrong rather than a value that is wrong.

## 11. What to run on hardware

**Nothing here has been run. All of it is for the user, and only once the
hardware freeze is lifted.** The bitstream is already saved, so no step below
needs `save_bitstream.sh` first.

The new bitstream is `hw/fk33/bit/fk33_pcieep_aux.bit` with
`fk33_pcieep_aux.ltx`. It is deliberately a SEPARATE file from
`bit/fk33_pcieep.bit`, which was in use at the time.

```sh
cd ~/GitHub/llama.vhdl/hw/fk33

# 1. Configure the instrumented endpoint bitstream and read the aux domain.
#    EP_BIT selects it without disturbing the existing saved bitstream.
EP_BIT=$PWD/bit/fk33_pcieep_aux.bit ./pcieep.sh

# 2. Or, if the card already holds it, read only.  This writes nothing.
./jtag.sh tcl/aux_probe.tcl
```

Note `pcieep.sh` does NOT yet run `tcl/aux_probe.tcl`; that edit is held pending
the freeze (section 10b), so step 2 is currently the way to read the registers.

Expected from step 2 on the bench -- no host, JTAG configure:

* `AUX_MASTER` identified, `AUX_MAGIC` = `0x41555831`
* `AUX_MS` advancing between two runs. That is the aux clock proving itself.
* `UCLK_HZ` = 0 with `PERST#` low, and `UCLK_VERDICT DEAD, but PERST# is
  ASSERTED`. **This is the reading that proves the instrument works**, because
  it is the one whose right answer is known in advance.
* `POT target-in-bitstream=68` and `done=1`, with `SYSMON VCCINT ~= 0.717 V`.
  If the pot controller works, stages 1 and 2 of `pcieep.sh` become redundant --
  and that is the whole point, because a flash boot cannot run them.

In a slot, behind the live root port `0000:00:1d.0`, the three readings that
matter are `UCLK_HZ`, `AUX_STATUS[1]` (PERST# level at configuration) and
`PERST_MS`. For the PCI-remove / configure / rescan experiment specifically:

* `UCLK_HZ` ~250 MHz after `./pcieep.sh` means the reference clock is present
  and the block is running, so anything that then fails is training or
  enumeration, not clocking.
* `PERST# deassertions` counting up across a warm reboot answers a question
  section 2 of the first-fit handoff left open: whether the host pulses PERST#
  at all when the FPGA stays configured across POST.
