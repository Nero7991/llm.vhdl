# FK33 thermal protection: what the silicon already does, and what had to be built

## 1. The question, verbatim

> **Task 1.** Does UltraScale+ SYSMON on `xcvu33p` provide an over-temperature
> alarm with AUTOMATIC device power-down, and is it active with the stock
> `system_management_wiz` configuration this design uses, or does it require
> explicit enabling? What is the OT trip point and its hysteresis, and are they
> configurable from the bitstream or over the DRP? What is Tj max for this speed
> grade and temperature grade? (The part is `xcvu33p-fsvh2104-2L-e`. Note the
> `-2L` and the `-e`.) The OT trip is a die-destruction backstop well ABOVE Tj
> max; state both numbers so the gap is explicit.
>
> **Task 2.** Implement thermal protection in the bitstream. Wire HBM stack
> temperature out. Halt the COMPUTE datapath on a threshold, with hysteresis.
> Do NOT stop the PCIe or AXI clocks, and do not stop the aux domain. Latch WHY,
> and expose it. Fail SAFE: a sensor that returns garbage, never updates, or
> reads implausibly must be treated as HOT. Make it hard to disable by accident.
> Derive the thresholds, do not accept mine.

**Date:** 2026-08-28.
**Hardware:** SQRL FK33, `xcvu33p-fsvh2104-2L-e` (ES1 die), Gigabyte Z790 AERO G,
BIOS F12, kernel 6.8.0-138-generic. Vivado 2023.2. Card idle at 36.5-37.3 C die,
VCCINT 0.7147-0.7171 V, with an EXTERNAL fan of uncharacterised airflow.
**Starting point:** `hw/fk33/bit/fk33_pcieep_aux.bit` and the design described in
`docs/debugging/2026-08-28_fk33-free-running-observability.md`.
**Status:** built and simulated. **Nothing here is verified on silicon.** No
hardware command was run at any point; the hardware freeze was respected in full.

---

## 2. The answer, up front

**Task 1: the OT shutdown is real, it IS armed in this design, and it is useless
as thermal management.** The SYSMONE4 primitive only accepts a new OT limit when
the low nibble of register `53h` is `0011`, which is itself the automatic-shutdown
enable, and `system_management_wiz` forces that nibble unconditionally -- so a
bitstream cannot set an OT trip point without also arming the shutdown. This is
not inference: `INIT_53` was read out of the routed netlist of the bitstream
that was built here and its low nibble is **`0x3`** (section 4.8). SQRL's block
design sets the trip to **100.90 C with a 98.99 C release** (the wizard's "101 /
99" is a rounded display of those two register values). Against DS890 Table
33 the `-2LE` grade is **0 to 110 C Tj, with 110 C limited to 1% of device
lifetime** and a sustained column of **100 C**, and DS890 note 1 recommends a
maximum of **95 C for the HBM**. So the backstop fires **1 C above the sustained
rating and 6 C above the HBM recommendation**, and its consequence is a device
shutdown that takes the card off the PCIe bus. The second, retunable comparator
that this design adds was verified the same way: `INIT_50`/`INIT_54` decode to
**89.998 C / 74.996 C**, the 90 / 75 asked for. **What the shutdown physically
does could NOT be established** from anything on this workstation and is not
claimed here (section 6).

**Task 2: built.** `hw/fk33/rtl/fk33_thermal.vhd` runs on the free-running 200 MHz
board oscillator, reads the die through SYSMON's `temp_out[9:0]` plus its `ot_out`
and `user_temp_alarm_out` comparators, reads the HBM stacks through the HBM IP's
own `DRAM_x_STAT_TEMP` / `DRAM_x_STAT_CATTRIP` pins (which needed **no IP
reconfiguration** and were simply left dangling), and halts the compute datapath
at **die 90 C / HBM code 85**, resuming at **75 / 70**. It stops arithmetic only:
the PCIe link, the AXI fabric, the aux domain and every status register stay
alive and readable, over both the PCIe BAR and JTAG. Every sensor carries a
liveness watchdog and a plausibility band as well as a threshold, and an invalid
sensor is treated as hot, so the guard comes up HALTED and only releases once it
has actually seen a temperature.

---

## 3. The procedure, in the order it was run, and what each step isolates

### 3.1 Ask the primitive, not the documentation, whether OT shutdown is armed

`UG580` is not installed on this workstation (`find /tools/Xilinx/2023.2 -iname
"*.pdf"` returns 88 files, none of them SYSMON). The authoritative local sources
are the UNISIM behavioural model of `SYSMONE4`, the `system_management_wiz_v1_3`
IP definition and its generator templates, and `docs/datasheets/ds890-*.pdf`.
Isolates: "is the shutdown a thing you opt into" from "is it a thing you opt out
of". Answer in 4.1.

### 3.2 Ask the IP which ports exist, and under what condition

`component.xml` carries a `PORT_ENABLEMENT` dependency per port. Isolates "the
die temperature is reachable" from "the die temperature is reachable at the
CURRENT IP configuration". Answer in 4.2.

### 3.3 Ask the HBM IP's own HDL where the temperature comes from

`hdl/hbm_v1_0_vl_rfs.sv` contains the internal APB reader. Isolates "the pin
exists" from "the pin carries what it appears to carry" -- and this is where the
per-stack assumption dies (4.3).

### 3.4 Read the repo's own prior art before designing anything

`rtl/hbm_tg.vhd` already consumes all four HBM pins and already recorded a
thermal CDC failure that cost a frequency sweep. Isolates avoidable rediscovery.

### 3.5 Simulate every threshold, including the ones that are not thresholds

`sim/tb_fk33_thermal.vhd`, run by `./sim_aux.sh`. Seventeen numbered checks: the
power-up halt, release, warn, die over-temperature, hysteresis, staleness,
stuck-at-zero, all-ones, the HBM code, CATTRIP stickiness, a clear with the wrong
key, a clear while hot, a clear that releases, the host clear path, the peak
clear, both SYSMON alarms, and the HBM APB clock stopping. Isolates "written
down" from "implemented".

### 3.6 Prove every guard fails on a deliberately broken copy

Twenty-three generator guards and twelve RTL mutations, each run against a
control that must pass first, plus one synthesis-level and one
block-design-level check. This step found two of my own assertions to be
insensitive and one Tcl bug in a script that had never been run (4.6, 7).

### 3.7 Block design only, then the full build

`./pcieep_build.sh --bd-only` (~4 min) reads back what Vivado actually did with
each `set_property`, because Vivado silently ignores a `CONFIG.*` name that does
not apply and would otherwise produce a clean build of a blind guard.

### 3.8 Interrogate the artefact itself, not the request that produced it

Everything in 3.7 reads a block-design parameter, which records what the wizard
*accepted*, not what the device will *load*. The last step opens the routed
checkpoint of the finished bitstream and reads the `SYSMONE4` primitive's
`INIT_50/53/54/57` attributes -- the SYSMON configuration registers themselves --
then decodes them through the same transfer function used to derive the
thresholds in the first place. This is what isolates "Vivado accepted my
threshold" from "the silicon will trip at my threshold", and it is the only step
in this document whose evidence comes from the shipped artefact rather than from
a script that built it. It also answers the arming question of Task 1 outright.
As a control it is self-checking: two independently requested temperatures both
have to round-trip to within a fraction of a degree, and they do (section 4.8).

---

## 4. The evidence

### 4.1 The automatic shutdown is armed, and arming is not optional

**This was first argued from the simulation models and the wizard's Tcl, below.
It has since been MEASURED, on the routed netlist of the very bitstream that was
saved as `hw/fk33/bit/fk33_pcieep_therm.bit`. That measurement is section 4.8 and
it is the authority; the source reading that follows explains the mechanism.**


`/tools/Xilinx/2023.2/Vivado/2023.2/data/verilog/src/unisims/SYSMONE4.v`,
lines 1106-1117:

```verilog
    // User can overwrite the ot_limit_reg only while enabling automatic shutdown.
    // Otherwise default value will be kept.
    tmp_otv = INIT_53_BIN;
    if (tmp_otv [3:0] == 4'b0011) begin
      dr_sram[8'h53] = INIT_53_BIN;
      ot_limit_reg  = INIT_53_BIN;
      $display("Info: [Unisim %s-20] OT upper limit has been overwritten and
                automatic shutdown bits have been set 53h = h%0h. ...
    end
    else begin
      dr_sram[8'h53] = 16'hCB00;
      ot_limit_reg   = 16'hCB00;  // default value for OT is 125C
    end
```

and on the runtime DRP path, line 2240:

```verilog
        else if ( cfg_check_addr == 8'h53 && cfg_in[3:0] == 4'b0011)
          ot_limit_reg <= cfg_in;// overwrite the OT upper limit
```

with an explicit refusal message at line 2278: *"OT upper limit can only be
overwritten while enabling automatic shutdown, hence input value h%0h will be
ignored and the default value will be kept."* The VHDL model agrees; its process
is literally named `ot_out_shutdown` (`SYSMONE4.vhd:4585`).

The wizard forces that nibble with no branch on anything
(`xgui/system_management_wiz_v1_3.tcl`, end of
`update_MODELPARAM_VALUE.C_ALARM_LIMIT_R3`):

```tcl
   set r3_final_val [expr {(int($r3_val/16)*16)+3} ]
	set_property value $r3_final_val  ${MODELPARAM_VALUE.C_ALARM_LIMIT_R3}
```

and `C_ALARM_LIMIT_R3` goes straight into `INIT_53` for this family
(`ttcl/core_sysmon_vhd.ttcl:768`, guarded by `is_olympus_pele`, which includes
`virtexuplusHBM`).

Separately, Configuration Register 1 bit 0 is an active-high OT *disable*
(`ot_en <= ~cfg_reg1[0];`, SYSMONE4.v:2435), and `PARAM_VALUE.OT_ALARM` defaults
to `true`, so the bit is clear. And in "default mode" -- the state the block sits
in when nothing has configured it -- OT is forced on and every other alarm off:

```verilog
      if (default_mode) begin
        alm_en  <= 0;
        ot_en   <= 1;
      end
```

**Register map, trip points and hysteresis.** From
`ttcl/core_sysmon_vhd.ttcl:764-773`: `50h` user-temp upper, `53h` **OT upper**,
`54h` user-temp reset, `57h` **OT reset**. Bit 0 of `57h` selects window vs
hysteresis mode and this family forces hysteresis
(`ttcl/variables.ttcl:429-436`). Both are set from the bitstream through the
primitive's `INIT_*` generics, and `53h` is additionally writable over the DRP at
runtime -- but only with the arming nibble, so **you cannot lower the OT trip
without leaving the shutdown armed.** Wizard defaults are **125 C trip / 70 C
release**. This design overrides them:

```
FK33_SYSMON TEMPERATURE_ALARM_OT_TRIGGER = 101
FK33_SYSMON TEMPERATURE_ALARM_OT_RESET = 99
```

read back from the block design, not from the script that asked for them.

**Tj max.** `docs/datasheets/ds890-ultrascale-overview.pdf`, Table 33, puts
`-2LE` under the `0 C to +110 C` column, with:

* note 3: 110 C is limited to **1% of device lifetime**;
* note 4: HBM devices at `-2LE` may run **95-105 C for 4.1% of lifetime, no more
  than 96 hours at a time, and require at least 4x refresh above 95 C**;
* note 1: the recommended maximum for the high-bandwidth memory is **95 C**.

**The gap, stated plainly: OT backstop 101 C (as configured; 125 C by default),
sustained Tj 100 C, absolute Tj 110 C for 1% of lifetime, HBM recommended
maximum 95 C.** The backstop is above every one of the operating numbers.

### 4.2 The die temperature bus exists but is OFF by default

`component.xml` port enablements:

| port | width | enabled by | default |
|---|---|---|---|
| `temp_out` | `[9:0]` | `C_HAS_TEMP_BUS` <- `ENABLE_TEMP_BUS` | **false** |
| `ot_out` | 1 | `C_HAS_OT_ALARM` <- `OT_ALARM` | true |
| `user_temp_alarm_out` | 1 | `C_HAS_USER_TEMP_ALARM` <- `USER_TEMP_ALARM` | true, **but SQRL sets it false** |
| `eoc_out` | 1 | `C_HAS_EOC` <- `ENABLE_EOC` | true |
| `alarm_out` | 1 | none -- always present | -- |

**Trap: `alarm_out` is NOT the OT alarm.** `ALM_out[7] = |ALM_out[6:0]`
(SYSMONE4.v:4400) is the OR of the voltage and user-temperature alarms; OT is
deliberately excluded. Bringing out `alarm_out` and believing it covers
over-temperature would be silently wrong.

`ENABLE_TEMP_BUS` is only offered when the interface is AXI and the sequencer is
not one-pass (`update_PARAM_VALUE.ENABLE_TEMP_BUS`). In a block design
`bd/bd.tcl:48` sets `CONFIG.INTERFACE_SELECTION "Enable_AXI"`, and the defaults
are `channel_sequencer` / `Continuous`, so it is available here. Read back after
the change:

```
FK33_SYSMON ENABLE_TEMP_BUS = true
FK33_SYSMON USER_TEMP_ALARM = true
FK33_SYSMON TEMPERATURE_ALARM_TRIGGER = 90
FK33_SYSMON TEMPERATURE_ALARM_RESET = 75
FK33_SYSMON REFERENCE = External
FK33_SYSMON INTERFACE_SELECTION = Enable_AXI
```

**Transfer function.** The wizard's own inverse for UltraScale+ with an external
reference (`update_MODELPARAM_VALUE.C_ALARM_LIMIT_R0`) is
`code16 = (T + 279.42657680) / 507.5921310 * 2^16`, matching the constants
`host/fk33ctl.py` already uses. `temp_out` is the top ten bits
(`ttcl/drp_to_axi_stream_vhd.ttcl:201`, `temp_out <= do_i(15 downto 6)`), so one
LSB is 0.496 C. Do NOT use the 7-series `503.975 / 273.15` pair; it is still
present in the same tree but only on the PMBus path.

### 4.3 HBM temperature is already on the IP's pins -- and is NOT per stack

`ttcl/hbm_v1_0.ttcl:2792-2796`:

```
  output          DRAM_0_STAT_CATTRIP,
  output [  6:0]  DRAM_0_STAT_TEMP,
  output          DRAM_1_STAT_CATTRIP,
  output [  6:0]  DRAM_1_STAT_TEMP
```

`DRAM_0_*` have no enablement condition at all; `DRAM_1_*` appear when
`USER_HBM_STACK = 2`, which this design already sets. **No CONFIG parameter had
to change and no new waiver was needed.** The value comes from the IP's own APB
reader (`hdl/hbm_v1_0_vl_rfs.sv`, `hbm_temp_rd`), clocked by `APB_x_PCLK` and
refreshed every `TEMP_WAIT_PERIOD_0 = 100000` APB cycles, i.e. about 1 ms at the
100 MHz this design supplies:

```verilog
end else if (main_fsm_curr_state == C_READ_TEMP && pready == 1'b1) begin
    temp_valid_r <= prdata[31];
    temp_value_r <= prdata[30:24];
```

**The trap, and it changes the design.** On a two-stack part both outputs are
driven from the same merged expression (`hdl/hbm_v1_0_vl_rfs.sv:3744-3745`):

```verilog
assign TEMP_STATUS_ST0 = ((temp_value_0_s > 7'h05) && (temp_value_1_s > 7'h05))
   ? ((temp_value_0_s > temp_value_1_s) ? temp_value_0_s : temp_value_1_s)
   : ((temp_value_0_s < temp_value_1_s) ? temp_value_0_s : temp_value_1_s) ;
assign TEMP_STATUS_ST1 = <the identical expression>
```

So **there is no per-stack temperature at these pins**, and any per-stack
reasoning built on them is illusory. Two consequences were taken:

1. the design treats them as ONE sensor and says so;
2. the `> 7'h05` term in the IP's own merge is where the plausibility floor of
   6 comes from -- a code of 5 or less means at least one stack has not produced
   a reading and the output is the useless one, not a cold stack.

`CATTRIP` **is** genuinely per stack: it is a direct port of the hard macro
(`.CATTRIP (DRAM_0_STAT_CATTRIP)`), needs no APB traffic, no clock and no
calibration.

**Calibration status of the code: NOT established.** PG276 is not bundled and
nothing in the IP converts the code. The only local evidence is measured, in this
repository: `docs/debugging/2026-08-25_voltage-derate-on-hardware.md` records
codes 28-29 at a die temperature of 27.7-28.2 C at idle, rising to 32 under load.
That is consistent with the code being degrees C and with nothing else proposed,
so it is treated as degrees C **with extra margin because the assumption is not
proven** -- see 5.2.

### 4.4 The whole build, read back from the tool

`./pcieep_build.sh --bd-only`:

```
FK33_THERM hbm/DRAM_0_STAT_TEMP connected
FK33_THERM hbm/DRAM_1_STAT_TEMP connected
FK33_THERM hbm/DRAM_0_STAT_CATTRIP connected
FK33_THERM hbm/DRAM_1_STAT_CATTRIP connected
FK33_AUX_CLKCHECK violations=0
FK33_CFG auxconnect.NUM_MI = 7
FK33_CFG pcie2axil.NUM_MI = 7
FK33_BD_VALIDATE OK
```

no `FK33_CFG MISSING AUX CELL` lines, zero `12-584` unmatched constraints and
zero `Designutils 20-1307` silently-skipped XDC commands. Address map, read back
rather than assumed:

```
FK33_MAP /jtag_aux/Data   SEG_aux_therm_Reg   0x00004000  0x00001000
FK33_MAP /jtag_aux/Data   SEG_aux_peak_Reg    0x00005000  0x00001000
FK33_MAP /jtag_aux/Data   SEG_aux_ctl_Reg     0x00006000  0x00001000
FK33_MAP /xdma/M_AXI_LITE SEG_fk33_therm_Reg  0x0000B000  0x00001000
FK33_MAP /xdma/M_AXI_LITE SEG_fk33_thermp_Reg 0x0000C000  0x00001000
FK33_MAP /xdma/M_AXI_LITE SEG_fk33_thermc_Reg 0x0000D000  0x00001000
```

### 4.5 The simulation crosses every threshold

`./sim_aux.sh`:

```
Note: TB_FK33_AUX PASS
TB_FK33_AUX PASS
Note: THERM_STATUS = 0x8A0377CD
Note: THERM_TEMPS  = 0x1E830670
Note: THERM_PEAK   = 0x1E830670
Note: THERM_TRIP   = 0x57830670
Note: THERM_CANARY = 4486
Note: die halt code = 745  resume code = 715
Note: TB_FK33_THERMAL PASS
TB_FK33_THERMAL PASS
```

Decoded by `tcl/aux_probe.tcl`'s own self-test, which is fed exactly those
vectors -- so the RTL and the JTAG decoder are checked against each other with no
hardware:

```
HALTED  YES     warn=0  armed=1  die_valid=1  hbm_valid=0
DIE     29.9 C  (code 624)   peak 29.9 C
HBM     code 65 / 65   peak 65 / 65
CAUSE   HBM sensor STALE or implausible -- treated as hot
TRIP    LATCHED: HBM sensor STALE or implausible -- treated as hot
        at die 29.9 C, HBM code 65 / 65, 3 trips since the last clear
        STICKY: SYSMON OT alarm has fired
        STICKY: SYSMON user temperature alarm has fired
```

Every field matches the state the testbench left the design in.

### 4.6 Every guard bites

Twenty-three generator guards, each run against a broken copy after a control
run that must succeed first:

```
TEETH OK   gen: rtl/fk33_thermal.vhd missing
TEETH OK   gen: die halt threshold moved to 95 C
TEETH OK   gen: HBM halt threshold moved to 95
TEETH OK   gen: die resume threshold moved to 88 C
TEETH OK   gen: elaboration ceiling on the die halt removed
TEETH OK   gen: the guard no longer comes up halted
TEETH OK   gen: compute_halt no longer resets to halted
TEETH OK   die liveness strobe unwired
TEETH OK   HBM stack-0 CATTRIP unwired
TEETH OK   HBM stack-1 CATTRIP unwired
TEETH OK   HBM stack temperature unwired
TEETH OK   SYSMON temperature bus disabled
TEETH OK   SYSMON user temp alarm disabled
TEETH OK   the thermal guard is not instantiated
TEETH OK   thermal registers off the jtag_aux map
TEETH OK   thermal registers off the PCIe BAR map
TEETH OK   compute domain unwired
TEETH OK   HBM APB clock unwired
TEETH OK   host/RTL threshold divergence
TEETH OK   host register base drift
TEETH OK   removed: constant C_DIE_HALT_CEILING
TEETH OK   removed: constant C_HBM_HALT_CEILING
TEETH OK   removed: constant C_DIE_HYST_FLOOR
```

Twelve RTL mutations against the testbench, control passing first:

```
CONTROL PASS
TEETH OK   die liveness term removed from validity
           Failure: halted='0' but expected '1' while the die liveness strobe stopped with a cool value
TEETH OK   die plausibility band removed
           Failure: halted='0' but expected '1' while the die sensor reads all-zeroes with a live strobe
TEETH OK   hysteresis removed (resume at the halt point)
           Failure: halted='0' ... while the die is between the resume point and the halt point -- HYSTERESIS
TEETH OK   HBM plausibility floor removed
           Failure: the HBM sensor must NOT be valid at code 0
TEETH OK   the clear key is not checked
           Failure: a host clear with the wrong key cleared the latch
TEETH OK   clearing the trip also clears the peak-hold
           Failure: the peak-hold must survive a trip clear.  It read 624
TEETH OK   the guard powers up released
           Failure: the guard does not power up halted
TEETH OK   compute_halt powers up released
           Failure: compute_halt does not power up HALTED
TEETH OK   CATTRIP stickiness removed from BOTH hot and cool
           Failure: halted='0' ... while CATTRIP deasserted -- it is STICKY and must not self-clear
TEETH OK   elaboration ceiling: die halt asked for at 95 C
           Failure: fk33_thermal: G_DIE_HALT_C must not exceed 90 C
TEETH OK   elaboration ceiling: HBM halt asked for at 95
           Failure: fk33_thermal: G_HBM_HALT_C must not exceed 85
TEETH OK   elaboration check: die hysteresis band narrowed to 3 C
           Failure: fk33_thermal: the converted die codes are not monotonic
```

One BD-level teeth check, forcing the IP into a state where the wizard refuses
`ENABLE_TEMP_BUS` (single-channel startup, 10 us acquisition):

```
WARNING: [BD 5-235] No pins matched 'get_bd_pins system_management_wiz_0/temp_out'
ERROR: [BD 41-701] connect_bd_net requires at least two pins/ports, or one pin/port and a net
ERROR: [Common 17-39] 'connect_bd_net' failed due to earlier errors.
```

The build dies with a hard ERROR before reaching the readback check. So the
failure mode is caught -- but **the readback check itself was not exercised** and
is reported here as unproven. It remains as the second net, for the case where
the port exists and the property is reverted later.

### 4.6b What the guard costs

Out-of-context synthesis of `fk33_thermal` alone, from the build's own run
directory:

```
+------+-------+------+
|1     |CARRY8 |    30|
|2     |LUT1-6 |   381|
|8     |FDRE   |   951|
|9     |FDSE   |     1|
+------+-------+------+
Synthesis finished with 0 errors, 0 critical warnings and 29 warnings.
```

**No DSP48 and no BRAM.** Most of the 952 flip-flops are the 160-bit
aux-to-host publication filter (four registers per bit) and the sensor
synchronisers -- the price of making every crossing skew-tolerant rather than
constraint-dependent, and it is nothing on a VU33P.

### 4.7 Vivado synthesis ignores `assert ... severity failure`

Measured, because the whole "hard to disable by accident" requirement rests on
it. An out-of-context synthesis of `fk33_thermal` with `G_DIE_HALT_C` moved from
90 to 98:

```
INFO: [Synth 8-638] synthesizing module 'fk33_thermal'
INFO: [Synth 8-256] done synthesizing module 'fk33_thermal' (0#1)
...
SYNTH_COMPLETED_WITHOUT_ERROR
```

No error, no critical warning, **no message about the assertion at all**. The
same file simulated under xsim stops at time zero with the assertion's own text.

Adding one unused constant that would have to be negative changes it:

```
ERROR: [Synth 8-11323] assigned value '-8' out of range   (line 330)
ERROR: [Synth 8-285] failed synthesizing module 'fk33_thermal'
ERROR: [Common 17-69] Command failed: Vivado Synthesis failed
```

So `C_DIE_HALT_CEILING`, `C_HBM_HALT_CEILING`, `C_DIE_HYST_FLOOR` and
`C_HBM_HYST_FLOOR` are now in the RTL and are the only in-RTL mechanism that can
stop an out-of-spec threshold reaching a bitstream. **This applies equally to
`rtl/fk33_aux.vhd`'s `assert G_POT_WIPER = 68`**, which the previous work
describes as an elaboration-time guard: it is a simulation guard, and what
actually protects that value is the check in `gen_pcieep.py`. Not changed here,
but it should get the same treatment.

---

### 4.8 The thresholds as they exist in the silicon, read from the routed netlist

Everything else in section 4 reads a *request*: a block-design `CONFIG.*`
parameter, or a line of the IP's own Tcl. This reads the *answer*. The
`SYSMONE4` primitive's `INIT_4x`/`INIT_5x` attributes ARE the SYSMON
configuration registers, loaded from the bitstream at startup, so what they hold
in the routed checkpoint is what the device will hold on power-up.

Read directly out of the checkpoint that produced the saved bitstream
(`impl_1/bd_wrapper_routed.dcp`, build of 2026-08-28 15:05). The whole recipe,
which needs no card and no rebuild and takes about two minutes -- worth keeping,
because it interrogates any bitstream you still have the checkpoint for:

```tcl
open_checkpoint <impl_1/bd_wrapper_routed.dcp>
set smc [get_cells -quiet -hierarchical -filter {REF_NAME =~ "SYSMONE4*"}]
puts "PROBE count=[llength $smc]"
foreach c $smc { puts "PROBE name=[get_property NAME $c] ref=[get_property REF_NAME $c]" }
foreach r {INIT_40 INIT_41 INIT_42 INIT_46 INIT_48 INIT_4A INIT_50 INIT_53 INIT_54 INIT_57} {
    puts "PROBE $r = >[get_property $r [lindex $smc 0]]<"
}
```

giving:

```
PROBE count=1
PROBE name=bd_i/system_management_wiz_0/inst/AXI_SYSMON_CORE_I/inst_sysmon ref=SYSMONE4
PROBE INIT_40 = >16'h0000<
PROBE INIT_41 = >16'h2E90<
PROBE INIT_42 = >16'h1400<
PROBE INIT_46 = >16'h0007<
PROBE INIT_48 = >16'h4F01<
PROBE INIT_4A = >16'h0000<
PROBE INIT_50 = >16'hBA51<
PROBE INIT_53 = >16'hBFD3<
PROBE INIT_54 = >16'hB2C0<
PROBE INIT_57 = >16'hBEDA<
```

Decoded through the external-reference transfer function established in section
4.2, `T = code * 507.5921310 / 65536 - 279.42657680`:

```
  INIT_50 user temp UPPER (alarm trigger)    0xBA51 = 47697 ->  89.998 C
  INIT_54 user temp LOWER (alarm reset)      0xB2C0 = 45760 ->  74.996 C
  INIT_53 OT upper (raw, incl. nibble)       0xBFD3 = 49107 -> 100.919 C
  INIT_53 OT limit field [15:4]              0xBFD0 = 49104 -> 100.896 C
  INIT_57 OT lower (shutdown reset)          0xBEDA = 48858 ->  98.990 C

  INIT_53[3:0] = 0x3  -> automatic shutdown ARMED

  requested 90 C -> got 89.998 C  (error -0.002 C)
  requested 75 C -> got 74.996 C  (error -0.004 C)
```

Four things are settled by this and by nothing before it:

1. **`INIT_53[3:0]` is `0011`.** The automatic power-down is armed in this
   bitstream. Measured on the artefact, not inferred from the wizard's Tcl.
2. **The OT trip is 100.90 C with a 98.99 C release**, i.e. the "101 / 99" the
   wizard reports is a rounded display of these two register values.
3. **The second, retunable comparator did take, exactly.** The user-temperature
   alarm sits at 89.998 C with a 74.996 C reset -- the 90 / 75 this design asked
   for, to within one part in 45000. A `set_property` on a `CONFIG` name Vivado
   does not recognise is silently ignored, so this is the check that separates
   "asked for 90 C" from "the device will trip at 90 C".
4. **The transfer function used throughout this document is the right one.** Two
   independently requested temperatures both land within 0.005 C of their target
   after a round trip through the wizard's own arithmetic and back through mine.

`gen_pcieep.py` now emits this same read-back as `FK33_SYSMONI` in the
implementation stage of **every** build, decoding the registers and failing the
build if `INIT_50`/`INIT_54` drift more than 1 C from the configured thresholds.
The OT nibble is reported rather than enforced: what it *should* be is a bench
decision, and the fabric guard exists precisely because the OT shutdown is a
die-destruction backstop rather than a thermal-management mechanism.

---

## 5. What was built, and why each threshold

### 5.1 `hw/fk33/rtl/fk33_thermal.vhd`

Runs entirely on `fk33_aux_0/aux_clk`, the 200 MHz board oscillator through a
plain BUFG. **Both sensors are in PCIe-derived domains** -- SYSMON's temperature
bus is registered in the wizard's AXI/DRP domain (`s_axi_aclk` = `xdma/axi_aclk`)
and the HBM reader is clocked by `APB_0_PCLK` = `clk_wiz_0/clk_out1`, whose
reference is also `xdma/axi_aclk`. A guard clocked by either would lose the
thermal record exactly when it is wanted, and its staleness watchdogs could
themselves go stale.

| register | jtag_aux | PCIe BAR | contents |
|---|---|---|---|
| `THERM_STATUS` | 0x4000 | 0xB000 | halt/warn/armed/valid/hot, live cause, latched cause, trip count, stickies, **[31]=1 constant** |
| `THERM_TEMPS` | 0x4008 | 0xB008 | `[9:0]` die code, `[16:10]` HBM 0, `[23:17]` HBM 1, `[31:24]` die C |
| `THERM_PEAK` | 0x5000 | 0xC000 | the same fields, peak-hold |
| `THERM_TRIP` | 0x5008 | 0xC008 | the same code fields captured at the trip, plus the cause |
| `THERM_CTL` | 0x6000 | 0xD000 | write; `[31:16]` must be `0xC1EA`, `[0]` clear trip, `[1]` clear peak |
| `THERM_CANARY` | 0x6008 | 0xD008 | count of compute-domain canary toggles |

`THERM_STATUS[31]` is a fabric constant 1. **A bitstream without the guard reads
0 there**, so "is this card protected" is one read rather than a belief.

### 5.2 The thresholds, and the arithmetic behind them

| | warn | halt | resume | justification |
|---|---|---|---|---|
| die | 80 C | **90 C** | 75 C | 10 C under the 100 C sustained column, 20 C under the 110 C absolute, **11 C under the armed 101 C OT backstop so this guard always fires first**, and 5 C under the 95 C HBM recommendation because the stacks share the interposer. The 15 C band is 30x the 0.496 C ADC LSB, so it cannot chatter. |
| HBM | 75 | **85** | 70 | 10 below the 95 C DS890 recommendation. The extra margin is deliberate: the code-to-Celsius mapping is NOT calibrated (4.3), and above 95 C the datasheet requires 4x refresh which this HBM IP is not configured to do. |

Thresholds are converted to SYSMON codes at elaboration with integer arithmetic
only: `code10 = (T*10000 + 2794266) / 4957`, where 4957 is `507.5921310 * 10000 /
1024` rounded. The exact form overflows a 32-bit VHDL integer at 3.8e9; the
rounding error is 9e-6 relative, under 0.01 of one code. **90 C is code 745 and
75 C is code 715**, both checked by an elaboration assertion rather than trusted.

The reported degrees-C field uses a cheaper approximation (`code * 127 / 256 -
279`, worst case 0.8 C) so that no runtime divider is needed. **Nothing compares
against it**: every threshold comparison is on exact codes, so the approximation
cannot move a trip point.

### 5.3 Failing safe, and why a value comparison is not enough

A stuck-at-zero sensor and a very cold card produce the same value. Every sensor
therefore carries three independent tests and must pass all of them:

1. **liveness**, from a signal independent of the value. The die uses SYSMON's
   own `eoc_out`, divided by 8 and toggled in the SYSMON clock domain, so a
   frozen ADC with a running DCLK still fails. HBM has **no** valid or strobe pin
   (`temp_valid_r` is internal and not brought out), so it uses the APB clock
   divided and toggled -- which detects the clock stopping but **not** the reader
   wedging. That is weaker and is stated rather than glossed.
2. **plausibility**. Die code 0 maps to -279 C and 0x3FF to +228 C, both outside
   the -40..150 C band, so all-zeroes and all-ones are both caught. The HBM floor
   of 6 comes from the IP's own merge expression (4.3).
3. **agreement** between two independently synchronised copies of the HBM word.

Failing any of them marks the sensor invalid, and an invalid sensor is hot. Both
`halted` and the compute-domain `compute_halt` synchroniser reset to **1**, so
the guard comes up halted and a datapath whose clock is dead or whose
synchroniser has not propagated never sees a release.

### 5.4 What the halt does and does not stop

`compute_halt` is one bit, synchronous to `compute_clk`, active high, reset value
1. It is a request to stop ISSUING work. It does **not** stop `compute_clk`,
`xdma/axi_aclk`, the PCIe link, the AXI fabric, the HBM controller or the aux
domain, and a consumer **must still complete AXI bursts it has already issued** --
abandoning an accepted burst hangs the channel permanently, which
`rtl/hbm_tg.vhd:727` already records for the same reason.

**There is no compute datapath in this bitstream yet, so `compute_halt` is
deliberately left unconnected.** It is not untested for that reason: the module
carries a canary counter in the compute domain which the halt gates, and the aux
domain counts its toggles into `THERM_CANARY`. Two JTAG reads a few tens of
milliseconds apart therefore answer "is the compute domain running and un-halted"
with no datapath, no host and no instrument -- and the simulation asserts on
exactly that counter at every one of its seventeen steps.

### 5.5 Clock domain crossings

Single-bit crossings are two-stage `ASYNC_REG` synchronisers. The temperature
WORDS cannot use that rule alone -- two flops per bit make each bit stable but not
the word coherent -- so every multi-bit crossing here uses an **agreement filter**:
a candidate is accepted only after `G_STABLE+1` consecutive identical samples.
The sources change at about 1 kHz against a 200 MHz sampler, so a real value is
stable for ~200,000 samples and a torn one for at most one. **That is why no
`set_bus_skew` is owed and why the existing `set_clock_groups -asynchronous` is a
complete constraint**: arbitrary bit skew only ever produces a candidate the
filter rejects.

The same filter publishes all five status words into the PCIe clock domain as one
160-bit bundle, so the host's five reads are mutually consistent. Handing an
aux-domain word straight to an `axi_gpio` on `xdma/axi_aclk` would have torn.

### 5.6 Guards, following the pattern already set for `G_POT_WIPER = 68`

* **synthesis-time ceilings**, as four `natural` constants that would have to be
  negative if a threshold moved out of spec. These are load-bearing and the
  assertions are not: **Vivado synthesis IGNORES `assert ... severity failure`
  entirely** (4.7). The constants produce
  `ERROR: [Synth 8-11323] assigned value '-8' out of range` and stop the build;
* elaboration assertions in the RTL on every threshold, the hysteresis bands, the
  converted codes, the time base and the filter depth. These fire in xsim and
  carry the explanatory message, but they are a SIMULATION guard only;
* `gen_pcieep.py` refuses to emit a build if the RTL is missing, if any threshold
  or assertion has moved, if the guard does not come up halted, if any sensor or
  clock is unwired, if either register set is off the address map, or if the
  Python and host copies of a threshold or a base address disagree with the RTL;
* the block-design check reads `ENABLE_TEMP_BUS`, `USER_TEMP_ALARM` and the alarm
  limits back **from the tool**, because Vivado silently ignores a `set_property`
  on a `CONFIG.*` name that does not apply;
* the implemented-design check requires `fk33_therm_0/aux_clk` to be `sysref_clk`.

---

## 6. Measured and REJECTED -- do not retry

* **"The OT alarm is thermal management."** REJECTED on the datasheet. It fires at
  101 C as configured (125 C by default) against a 100 C sustained rating and a
  95 C HBM recommendation, and its consequence is a shutdown that takes the card
  off the PCIe bus. Do not retune it downward either: the arming nibble means a
  lower OT trip is still an armed shutdown, and a shutdown is the failure mode a
  diagnosable card must avoid.
* **Per-stack HBM temperature from `DRAM_0/1_STAT_TEMP`.** REJECTED at the IP's
  HDL: on a two-stack part both outputs carry the same merged expression
  (4.3). Getting per-stack values needs `CONFIG.USER_APB_EN true` and our own APB
  reads of `0x24000C` on each of `APB_0` and `APB_1`. Not done, and the cost is
  stated rather than hidden. `CATTRIP` remains per stack and is used as such.
* **`alarm_out` as the over-temperature signal.** REJECTED: `ALM[7]` is the OR of
  `ALM[6:0]` and OT is deliberately excluded from it.
* **Hanging the thermal registers off `pcie2axil` only.** REJECTED for the same
  reason the aux registers were: a card that halts and then loses its link must
  still be answerable. Both views exist, and the aux one is the authoritative one.
* **A plain 2FF synchroniser on the temperature words.** REJECTED. Two flops per
  bit do not make a word coherent, and `rtl/hbm_tg.vhd:258-290` already records
  what that costs: all 34 failing endpoints in a 350 MHz build were that one
  structure, and it read as an HBM AXI frequency ceiling that it was not.
* **`set_bus_skew` on the temperature crossings.** REJECTED in favour of the
  agreement filter, deliberately, so the constraint story has nothing to get
  wrong -- the same reasoning that put a divided single-bit toggle in
  `fk33_aux.vhd` instead of a gray-coded bus.
* **Driving an LED from the halt.** Considered and NOT done. LED 4 is the RGB red
  and the link-up LED block already re-cuts the 7-bit concat that feeds
  `led_inv`; splitting it again risks the one diagnostic that works with no host
  and no instrument, to duplicate something already readable over both JTAG and
  the BAR. If it is wanted later, extend `LNK_LED_BLOCK` rather than adding a
  second block that fights it.
* **A runtime divider to report degrees C exactly.** REJECTED: it costs a DSP and
  a 23-bit multiply for a display field. The comparisons are on exact codes and
  the reported value is a documented approximation with an 0.8 C bound.

---

## 7. Measurement traps hit, including my own

* **Ours, and the one that would have cost a bench session: `expr {0x$hz}` is not
  valid Tcl.** Braces stop substitution, so `expr` parses the expression itself
  and sees the bareword `0x` followed by a variable:
  `invalid bareword "0x" ... should be "$0x" or "{0x}" or "0x(...)"`. It throws on
  the FIRST decode, which aborts the whole script, so every register would read as
  unreachable and the aux instrumentation would look dead on a perfectly good
  card. **`tcl/aux_probe.tcl` carried five of these before this work and they had
  never been executed** -- the script was written under a hardware freeze. All nine
  occurrences are now `scan ... %x`, which also passes the `-1` no-answer sentinel
  through instead of throwing, and the script now has an `AUXPROBE_SELFTEST=1`
  mode that runs its decode under a plain `tclsh` against vectors from the RTL
  simulation, with no hardware. `pcieep_build.sh` runs it as a board-free gate.
* **Ours: a teeth harness that edits the shared source moves the guard along with
  the thing it guards.** Eleven emitted-text guards were "verified" by replacing a
  string in `gen_pcieep.py` -- which changed the guard's own needle as well as the
  emitted Tcl, so all eleven reported OK while testing nothing. Replacing only the
  FIRST occurrence fixed ten; the eleventh (`fk33_therm_0/compute_clk`) still did
  not bite because the same substring appears in the block-design check's
  allowlist, so the guard was satisfied by an unrelated line. The needle is now
  `[get_bd_pins fk33_therm_0/compute_clk]`.
* **Ours: a teeth harness that fails for the wrong reason reports success.** The
  first run copied `hw/fk33` to a scratch directory; the copied
  `build_fk33_i2cprobe.tcl` still carried absolute paths to the ORIGINAL
  directory, so every generator run aborted on an unrelated anchor and every
  check printed OK. **A teeth test needs a control run that must PASS before each
  broken variant is tried**, and the second harness has one.
* **Ours: two assertions that could not fail.** "The peak-hold survives a trip
  clear" passed against an RTL deliberately broken to clear the peak, because the
  clear was issued before the cool reading had been accepted, so the peak
  immediately re-acquired the still-hot value. "The guard powers up halted"
  passed against a released power-up value, because the combinational fail-safe
  re-asserts the halt within one clock. Both were found by the teeth process, not
  by review. The testbench now settles the reading before clearing, and checks
  the power-up values at t = 1 ns before any clock edge.
* **Ours: bash re-reads a script FILE while it is running, so editing
  `pcieep_build.sh` during a build corrupts the part not yet reached.** A guard
  was added to the script's report section while a 15-minute build was in
  flight; bash resumed at a byte offset that no longer meant what it had, and
  the run ended with `./pcieep_build.sh: line 57: with: command not found`. The
  Vivado work was unaffected -- `FK33_BUILD_DONE`, `WNS=0.260 ns` and the
  bitstream were all produced -- but **the script's own post-build report never
  ran**, which is exactly the part that reads the log for the things that must
  not be assumed. Python scripts are read in full at start and are safe; bash
  scripts are not. The build was re-run from an untouched script.
* **Ours: `assert ... severity failure` looked like a build guard and is not.**
  See 4.7. Two things follow: the RTL now carries negative-`natural` constants
  that synthesis does reject, and the same correction applies to
  `rtl/fk33_aux.vhd`'s wiper assertion.
* **Ours: `* 127` inferred two DSP48s for a display field.** Vivado turned the
  code-to-Celsius approximation into two DSP48E2s and then raised two DRC
  warnings that neither was pipelined. Rewritten as an explicit shift and
  subtract on `unsigned`, which is arithmetically identical for non-negative
  values and costs LUTs instead.
* **Ours: `tee /dev/stderr` truncates the capture file.** `pcieep_build.sh` piped
  a check through `tee /dev/stderr`; when the script's own output is redirected to
  a file, `/dev/stderr` IS that file and `tee` opens it with `O_TRUNC`. A 4-minute
  `--bd-only` run produced a 13-line log with everything before that line gone.
  Pre-existing, now fixed.
* **Ours: `xelab` and `xsim` write their own `xelab.log` / `xsim.log` into the
  working directory whatever the shell redirection says.** Running a second
  testbench in the same directory overwrote the first one's log, and the harness
  then reported the second testbench's result twice while claiming the first had
  failed. Each testbench now runs in its own directory.
* **`0x00000000` from a thermal status register is a dead bus, not a cold card.**
  Both the host tool and the JTAG decoder now say so explicitly, because
  all-zeroes is exactly what an unclocked AXI-Lite BAR returns and it would
  otherwise decode as a perfectly healthy, very cold, unprotected card.
* **The `INIT_53` default in the primitive is commented "125C" and is not.**
  `0xCB00` through the UltraScale+ transfer functions is 123.6 C (on-chip
  reference) or 123.1 C (external); it is 126.5 C only under the legacy 7-series
  equation. The comment predates the UltraScale+ coefficients.
* **`component.xml`'s static `C_ALARM_LIMIT_*` values are computed with the
  legacy equation and are placeholders.** `update_MODELPARAM_VALUE.*` recomputes
  every one of them per architecture at instantiation. Do not read the raw
  numbers as what lands in a VU33P bitstream.
* **Ours, and the worst one: three build alarms fired on a completely healthy
  build.** Vivado echoes every line of the sourced Tcl into `build.log` prefixed
  with `#`, so `grep "FK33_THERM FAIL" build.log` matched the *`puts` statement
  that would print it* rather than any printed line. `pcieep_build.sh` therefore
  reported "THE THERMAL GUARD IS BLIND", "AN AUX CELL IS MISSING" and "AN AUX PIN
  SHARES A NET WITH xdma/axi_aclk" on a build where all three were false. An
  alarm that fires every time is worse than no alarm: it trains the reader to
  scroll past the one that matters. Every grep that *decides* something is now
  anchored with `^`, where only real output can be, and the anchoring was
  teeth-checked both ways -- silent on the healthy log, still biting when a real
  emission is injected.
* **Ours: the thermal read-back only ran in `--bd-only` mode, so the build that
  produced the bitstream never once checked it.** The whole SYSMON/HBM check sat
  inside `if {[info exists ::env(FK33_STOP_AFTER_BD)]}`. The evidence in section
  4.4 came from a separate `--bd-only` run, and when the chain was actually
  examined its log turned out to *predate* the Tcl file it was supposed to have
  checked -- so it proved nothing about the artefact. A guard that does not run
  on the thing you ship is not a guard. The check is now unconditional, and a
  *structural* generator guard (comparing the emitted byte offsets of the
  read-back and the gate) fails the build if anyone moves it back inside.
* **Reading a block-design `CONFIG.*` parameter is reading a REQUEST, not an
  answer.** The whole reason the BD check exists is that Vivado silently ignores
  `set_property` on a `CONFIG` name that does not apply -- but reading the same
  parameter back only proves the property was accepted by the *wizard*, not that
  the wizard translated it into the register the device loads. The build now also
  reads `INIT_50/53/54/57` off the `SYSMONE4` primitive in the **routed netlist**
  and decodes them through the external-reference transfer function. Those
  attributes are the configuration registers themselves, so that is the first
  check in this design that reads what actually reaches the silicon.

---

## 8. Open, not yet answered

* **What the SYSMON automatic shutdown physically DOES.** Every local file defers
  to a "Thermal Management section of the User Guide" that is not installed. The
  arming mechanism and the trip condition are established; the consequence is
  not, and is not claimed here. It needs UG580.
* **Everything on silicon.** No register in this document has been read from
  hardware. The full build result is in section 9; a bitstream that closes timing
  is not a bitstream that works.
* **The HBM code-to-Celsius mapping.** Still uncalibrated. The one measurement
  available (codes 28-29 at 27.7-28.2 C die, idle) is consistent with degrees C
  but is a single point at one temperature. **The cheap experiment: read
  `THERM_TEMPS` over JTAG at idle and again after a sustained HBM bandwidth run,
  alongside the die temperature, and see whether the code tracks the die with a
  plausible offset.** Until then the 85 threshold carries deliberate extra margin.
* **Whether the external fan's airflow is adequate at all.** Uncharacterised, and
  this work does not characterise it. What it does do is make the answer
  measurable: `THERM_PEAK` after a long run is the number.
* **Whether the HBM staleness check is strong enough.** It detects the APB clock
  stopping, not the IP's internal reader wedging with the clock running. The IP
  exposes no valid pin. Driving the external APB (`CONFIG.USER_APB_EN true`) and
  reading `0x24000C` directly would give both a per-stack value and a real valid
  bit, and is the obvious upgrade if the HBM sensor is ever suspected.
* **A frozen `THERM_CANARY` is ambiguous.** It stops when the compute domain is
  halted AND when the aux clock itself stops, and `THERM_STATUS` alone does not
  separate the two. `AUX_MS` at jtag_aux 0x3000 does -- it is the aux domain's own
  millisecond counter -- so read both. The host has no equivalent, because the
  aux registers are deliberately not on the PCIe BAR.
* **Whether 90 C is the right die threshold for THIS card's thermal time
  constant.** It is derived from the datasheet, not from a measured ramp rate. If
  the die can climb 10 C in less than the 1 ms sensor refresh, the warn level is
  decoration; nothing here measures that.

---

## 9. Build result

Full `./pcieep_build.sh`, Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`. It builds and
it closes timing.

```
FK33_AUXCLK clocks=sysref_clk
FK33_AUXCLK period=5.000 ns
FK33_AUXCLK analysed paths crossing the aux boundary: 0 (must be 0)
FK33_HUBCLK OK dbg_hub is on sysref_clk
FK33_THERMCLK fk33_therm_0/aux_clk clocks=sysref_clk
FK33_THERMCLK OK the thermal guard runs on the free-running oscillator
FK33_TIMING WNS=0.386 ns  WHS=0.010 ns
FK33_BITSTREAM bd_wrapper.bit (12208654 bytes)
```

Setup slack 0.386 ns and hold slack 0.010 ns, both positive. Unmatched
constraints (`12-584`) zero; XDC commands silently skipped (`Designutils
20-1307`) zero; `BD 41-1377` address-overlap warnings after the exclude sequence
zero. The thermal guard's decision logic is confirmed by the tool, not by
reading the diagram, to be clocked by `sysref_clk` -- the free-running board
oscillator -- and not one analysed timing path crosses into the aux domain, so
the `set_clock_groups` asynchronous declaration took.

Configuration time from the bitstream that was actually produced:

```
FK33_CFGTIME data=12208524 bytes (97668192 bits), 24417048 CCLK cycles at x4
FK33_CFGTIME   nominal 127.5 MHz ->   191.5 ms
FK33_CFGTIME   -15%    108.4 MHz ->   225.3 ms
FK33_CFGTIME   +15%    146.6 MHz ->   166.5 ms
```

This is unchanged in character from the pre-thermal build and remains tight
against the 200 ms budget; it is not a thermal issue and is tracked separately.

`fk33_thermal` costs, from its own out-of-context synthesis run: **CARRY8 30,
LUT 381, FDRE 951, FDSE 1, DSP 0, BRAM 0.** Under a thousand flip-flops and no
DSP on a part with 1.7 M of them. Top-level synthesis finished with 0 errors, 0
critical warnings and 2 warnings, the only notable one being the expected
`[Synth 8-7071] port 'compute_halt' ... is unconnected` -- there is no compute
datapath to connect it to yet, which is the point.

**Artefact:** `hw/fk33/bit/fk33_pcieep_therm.bit` (12,208,654 bytes) and
`hw/fk33/bit/fk33_pcieep_therm.ltx`. `bit/fk33_pcieep.bit` and
`bit/fk33_pcieep_aux.bit` were deliberately not touched; their MD5s
(`6769554980c180a51d5a3c606cf3bb57` and `a433eeb3f6ee481d01962feba7226693`) are
recorded here so that can be checked rather than trusted.

**What this build's own log did NOT check, and how it was covered instead.** At
the time this bitstream was produced the SYSMON/HBM read-back still sat inside
the `FK33_STOP_AFTER_BD` block, so the build that made the artefact never ran it
(section 7). Rather than rebuild, the artefact was interrogated **directly**: its
routed checkpoint was opened and the `SYSMONE4` configuration registers read out
of it (section 4.8). That is strictly stronger evidence than the check would have
been, because it reads the device configuration itself rather than the
block-design parameter that requests it.

The generator has since been fixed so that both checks run inline on every
future build, and it was confirmed that this changed **no design-affecting Tcl
command**: extracting every `create_bd_cell`, `connect_bd_net`,
`set_property`, `assign_bd_address`, `exclude_bd_segment`, `add_files`,
`create_clock` and `set_clock_groups` from the Tcl that built the artefact and
from the current generator output gives byte-identical lists. The two files
differ only in comments, `puts` and check code.

**Nothing here has been verified on silicon.** No register in this document was
read from hardware, no bitstream was loaded, and no hardware command was run at
any point in this work. A bitstream that closes timing is not a bitstream that
works.

## 10. What to run on hardware

**Nothing here has been run. All of it is for the user.** The bitstream is saved
under a new name and neither `bit/fk33_pcieep.bit` nor `bit/fk33_pcieep_aux.bit`
was overwritten.

```sh
cd ~/GitHub/llama.vhdl/hw/fk33

# 1. Read the thermal guard over JTAG, with or without a PCIe link.  Writes
#    nothing.
./jtag.sh tcl/aux_probe.tcl

# 2. With a link up, the same five words over the BAR.  Agreement between the
#    two proves the PCIe MMIO path against a path that does not need the link.
./host/fk33ctl.py thermal
```

Expected on the bench with no host and no link: `THERM_STATUS` bit 31 set,
`HALTED YES`, `armed=0`, and `CAUSE` reporting a stale die or HBM sensor. **That
is the correct reading, not a fault**: SYSMON's temperature bus and the HBM APB
clock are both in PCIe-derived domains, so with the link down the guard has no
sensor and holds the datapath off, which is exactly what it is supposed to do.
The reading that would be wrong is `HALTED no` with both sensors invalid.

In a slot with a trained link, expect `armed=1`, `HALTED no`, a die temperature
within a degree or two of what `pcieep.sh --check` reports through the JTAG DRP,
an HBM code in the twenties at idle, and `THERM_CANARY` advancing between two
reads. A canary that does not advance while `HALTED` reads `no` means the compute
clock is dead, which is a different fault from a thermal halt and is worth
separating.
