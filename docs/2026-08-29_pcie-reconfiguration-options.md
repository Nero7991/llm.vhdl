# Controlling and reloading the FK33 over PCIe: ICAP, MCAP, and Tandem

**Date:** 2026-08-29
**Track:** TANDEM. **Scoping only. Nothing was implemented, no block design was
changed, no place or route was run, and no hardware was touched.**
**Device:** `xcvu33p-fsvh2104-2L-e`, ES1 die (IDCODE `0x04B69093`), SQRL FK33,
PCIe Gen3 x4 at `PCIE4C_X1Y0`, GTY quad 227. Vivado 2023.2, XDMA IP v4.1.
**Reference build:** `hw/fk33` shell + `fk33_engine`, commits `928ad9f` /
`70c35db` / `d807a1c`; the placed checkpoint that does not route.

---

## 1. The question, verbatim

> Oren has asked whether the card can be **controlled and reloaded with a
> bitstream over PCIe**, rather than over JTAG. Three mechanisms exist and I
> want them costed honestly:
>
> 1. **ICAP over AXI, via the existing XDMA.** [...] My ESTIMATE is about a day
>    of work. **Check that estimate against the actual tree** and correct it.
> 2. **MCAP** via the UltraScale+ PCIe hard block's extended config space. No
>    fabric logic needed. Determine whether it is actually available on THIS
>    device and THIS PCIe IP configuration, what it can and cannot load (full vs
>    partial), and what enabling it costs.
> 3. **Tandem PCIe with Field Updates.** [...] **This is the one I care most
>    about, because it also solves a problem already on the open list.**
>
> [...] **how does a Tandem partition interact with a design that is already
> congestion-limited and whose floorplan is being actively reworked?** Does
> Tandem's static region compete for the same resources the pblock work needs?
> Does it make the congestion worse, and by how much?

---

## 2. The answer, up front

**All three mechanisms are available on this exact part at this exact PCIe block
location, confirmed by making Vivado 2023.2 accept each of them (section 3).
None of them can be evaluated further until the design routes, and Tandem in
particular makes routing strictly harder, not easier.**

Three findings decide the shape of the answer:

- **The Tandem stage-1 pblock is a hard exclusion zone of 7.31% of the device's
  CLBs and 6.25% of its DSPs, and it is a full-height stripe at the extreme
  right edge of the die** (`SLICE_X216Y0:SLICE_X232Y239` = CLE tile columns
  X136..X147 of X0..X147 = clock-region column X7, rows Y0 through Y3).
  MEASURED. `DRC HDTC-6 "Non-stage-one logic illegally placed"` is an **Error**,
  so this is exclusion, not preference. **50,135 leaf cells of the shipping
  placed design currently sit inside that rectangle**, of which 8,690 are
  `matvec_core` (including 288 DSPs) and 26,816 are the two PCIe smartconnects.
  Between 38,301 and 50,135 of them would have to move, mostly leftward, into
  the half of the die that the router already cannot finish.

- **MCAP does not require Tandem and imposes no floorplan at all.** Setting
  `CONFIG.mcap_enablement DFX_over_PCIe` emits the MCAP clocking and **no
  stage-1 pblock whatsoever** (MEASURED, diffed across all four modes). Oren's
  "no fabric logic needed" is correct. But MCAP is a partial-bitstream port
  into a pre-planned reconfigurable partition, so the cost is not the IP
  setting, it is the DFX design work behind it.

- **Every user I/O pin in this design is in bank 65, the configuration bank**
  (MEASURED: all 13 non-GT pins, `pcie_perstn`, `pcie_clkreq`, `sysref_clk`,
  7 LEDs, 2 I2C). `DRC HDTC-10 "Config banks not available to second stage I/O"`
  and `HDTC-13 "IO banks can not be shared by first and second stage"` are both
  **Errors**. Under any Tandem variant the LEDs and the I2C probe must become
  static/stage-1 logic or go away. This is the single most likely thing to
  surprise an implementation attempt, and it is not mentioned anywhere in this
  repository's existing FK33 documents.

**On the one-day ICAP estimate: it is right for the plumbing and wrong for the
capability.** An AXI HWICAP hung off `pcie2axil` is about a day. It does not
reload anything by itself. ICAP cannot perform a full-device reconfiguration of
a design that contains the ICAP and the PCIe link delivering the data. To get an
actual reload you need either DFX (2 to 4 weeks) or a host-writable flash path
plus an IPROG warm boot (3 to 5 days), and IPROG drops the PCIe link and needs
the same rescan the JTAG procedure already needs.

**Sequencing: I agree with "route first, then Tandem", and more strongly than
the phrasing implies.** Tandem is not merely later, it is unevaluable now: it
subtracts area from a design that fails at level-7 congestion with 39.50% LUT.
One thing should nonetheless be **decided** now, without implementing anything:
whether Field Updates is ever wanted, because it forces a three-partition
hierarchy that is far cheaper to design for than to retrofit (section 7).

**And the motivation may not survive contact with a measurement.** The 225.7 ms
figure is DERIVED, and the SQRL factory image is a positive control that a
flash-booted FK33 enumerates on this exact board and BIOS. A cold-boot `lspci`
on the second card costs nothing and could remove the entire cold-boot argument
for Tandem. It has not been taken.

---

## 3. Availability, confirmed rather than assumed

### 3.1 What was run

Five Vivado 2023.2 batch sessions, all read-only, no place, no route, no
bitstream, no hardware. Scripts and logs in the session scratchpad under
`scratchpad/tandem/`.

| # | script | what it establishes | peak RSS |
|---|---|---|---|
| 1 | `probe.tcl` | does the XDMA IP accept each Tandem/MCAP mode on this part at this block location, and what XDC does it then emit | 2.22 GB |
| 2 | `geom.tcl` | device geometry, and how much of the shipping placed design sits inside the emitted stage-1 rectangle | 6.30 GB |
| 3 | `probe2.tcl` | the same generation for all four modes, so the emitted constraints can be diffed against each other and against `None` | 2.28 GB |
| 4 | `geom2.tcl` | decomposition of the cells in the stage-1 rectangle by top-level instance and primitive kind | 5.61 GB |
| 5 | `drc.tcl`, `tiles.tcl`, `bli.tcl` | the Tandem DRC rule set and severities; tile-to-slice coordinate mapping; HBM BLI site enumeration | ~2.5 GB |

Sessions 1 to 4 ran under an explicit RSS guard on their own process group
(10.0 GB for session 1, 12.0 GB for 2 to 4), killed by pgid, never by name
pattern. The guard never tripped. Sessions 5 are seconds-long device queries and
were run under a plain `timeout` with no guard; Vivado's own log reports peak
2,504 MB for the largest of them.

### 3.2 Tandem on `xcvu33p` at `PCIE4C_X1Y0`: SUPPORTED, all variants

**MEASURED.** `create_ip xdma:4.1` on `xcvu33p-fsvh2104-2L-e`, configured to
mirror `hw/fk33/build_fk33_pcieep.tcl` (X4, 8.0 GT/s, 128-bit AXI,
`pcie_blk_locn PCIE4C_X1Y0`, `axisten_freq 250`), then each mode set and read
back:

```
PROBE_BLKLOCN PCIE4C_X1Y0
PROBE_MCAP_NOW None
PROBE_MODE Tandem_PROM                     READBACK Tandem_PROM
PROBE_MODE Tandem_PCIe                     READBACK Tandem_PCIe
PROBE_MODE Tandem_PCIe_with_Field_Updates  READBACK Tandem_PCIe_with_Field_Updates
PROBE_MODE DFX_over_PCIe                   READBACK DFX_over_PCIe
PROBE_FINAL_MCAP Tandem_PCIe_with_Field_Updates
PROBE_GEN_OK
```

A rejected value would have reverted to `None` or thrown; all four stuck, and
`generate_target` then succeeded.

The IP's own enablement logic agrees and says why. From
`/tools/Xilinx/2023.2/Vivado/2023.2/data/ip/xilinx/xdma_v4_1/xgui/xdma_v4_1.tcl:10068`,
inside `update_PARAM_VALUE.mcap_enablement`:

```tcl
} elseif {($device == "XCVU31P" || ... || $device == "XCVU33P" || ...
           || $device == "XCU55C") && ($pcie_blk_locn == "PCIE4C_X1Y0")} {
  set_property enabled true $mcap_enablement
  set_property range_value "None,None,Tandem_PROM,Tandem_PCIe,Tandem_PCIe_with_Field_Updates,DFX_over_PCIe" $mcap_enablement
}
```

**`XCVU33P` is named explicitly, and the enabling condition is
`pcie_blk_locn == PCIE4C_X1Y0`, which is exactly what
`build_fk33_pcieep.tcl:376` already sets.** The board wiring does not have to
change: the FK33's edge lanes are on GTY quad 227 which is what drives
`PCIE4C_X1Y0`. Had the design used any other block location, none of this would
be available.

The generated core carries it through to the hard block:

```
MCAP_ENABLEMENT=TANDEM_PCIE_FIELD_UPDATES, MCAP_FPGA_BITSTREAM_VERSION=0x00000000
```

AMD's own documentation is weaker than the tool here and is quoted only as
corroboration: PG195's Tandem Configuration page says Tandem features are
"available for the AMD DMA Subsystem for PCI Express for all AMD UltraScale and
UltraScale+ device with PCIe hard blocks", with no per-device table. **The tool
is the authority and the tool says yes.**

### 3.3 MCAP: available, and available WITHOUT Tandem

**MEASURED**, by generating all four modes and diffing the emitted
`ip_pcie4c_uscale_plus_x1y0.xdc`:

| `mcap_enablement` | Tandem physical constraints emitted | other |
|---|---|---|
| `None` | none | no MCAP |
| `Tandem_PROM` | full stage-1 pblock; `HD.TANDEM_BITSTREAMS Combined`; `HD.OVERRIDE_PERSIST TRUE`; `CONFIG_MODE SPIx4` | |
| `Tandem_PCIe` | full stage-1 pblock; `HD.TANDEM_BITSTREAMS Separate`; `HD.OVERRIDE_PERSIST FALSE` | |
| `Tandem_PCIe_with_Field_Updates` | identical physical constraints to `Tandem_PCIe` | |
| `DFX_over_PCIe` | **NONE.** Only `set_case_analysis` on `bufg_gt_mcapclk` | MCAP present |

So the answer to "MCAP, no fabric logic needed" is **yes, and no floorplan
either**. `DFX_over_PCIe` turns on the MCAP VSEC in PCIe extended configuration
space and adds nothing else. That is a genuinely cheap thing to enable.

**What MCAP can and cannot load.** MCAP is a dedicated path from one PCIe hard
block to the device's internal configuration logic. It cannot load a full
bitstream, for the same structural reason ICAP cannot: a full reconfiguration
tears down the fabric carrying the PCIe endpoint and the configuration control
logic partway through, so the transfer can never complete. This is DERIVED from
the mechanism rather than read off a datasheet line; the clearest external
statement of it is Xillybus's PCIe/ICAP/DFX write-up, which puts it as "since
both the configuration logic and the IP core are implemented in the FPGA's logic
fabric, a full configuration is not possible". What MCAP *can* load is a
partial bitstream for a reconfigurable partition, and a Tandem stage-2
bitstream, which is a partial bitstream by construction.

**Therefore "MCAP with no fabric logic" and "reload the design over PCIe" are
not the same request.** MCAP delivers the bytes; something has to have been
built that those bytes are legal for.

### 3.4 ICAP: the primitive and the IP both exist here

**MEASURED.** `ICAPE3` is a real site on this architecture
(`data/parts/xilinx/virtexuplusHBM/public/liberty/virtexuplusHBM_pt_es1_*.lib`
carries `cell(ICAPE3)`, and `data/vhdl/src/unisims/primitive/ICAPE3.vhd`
exists). `axi_hwicap` v3.0's `component.xml` lists exactly one family as
`Not-Supported`, `versal`, with `autoFamilySupportLevel level_2`, so it is
usable on `virtexuplusHBM`.

The existing shell already has everything the plumbing needs: an AXI-Lite
smartconnect `pcie2axil` with `NUM_MI 2`, and four AXI-Lite peripherals on it
(ID GPIO, SYSMON, scratch BRAM, thermal). Adding a fifth is a `NUM_MI` bump,
one `create_bd_cell`, one `connect_bd_intf_net`, an address assignment, and the
corresponding edits to `gen_pcieep.py`'s self-checks.

---

## 4. What Tandem constrains

### 4.1 The stage-1 region, exactly

**MEASURED**, generated verbatim by the IP for this part and block location
(identical for `Tandem_PROM`, `Tandem_PCIe`, and `Tandem_PCIe_with_Field_Updates`):

```tcl
set stage1Pblock [create_pblock  <ip>_pcie4c_ip_Stage1_main]
set_property HD.TANDEM_IP_PBLOCK Stage1_Main $stage1Pblock
resize_pblock $stage1Pblock -add {SLICE_X216Y0:SLICE_X232Y239 \
                                  RAMB18_X12Y0:RAMB18_X13Y95 \
                                  RAMB36_X12Y0:RAMB36_X13Y47 \
                                  DSP48E2_X30Y0:DSP48E2_X31Y89 \
                                  GTYE4_CHANNEL_X1Y0:GTYE4_CHANNEL_X1Y15 \
                                  GTYE4_COMMON_X1Y0:GTYE4_COMMON_X1Y3 \
                                  PCIE4CE4_X1Y0:PCIE4CE4_X1Y1 \
                                  CONFIG_SITE_X0Y0 \
                                  LAGUNA_X30Y0:LAGUNA_X31Y119 \
                                  BLI_HBM_APB_INTF_X31Y0 \
                                  BLI_HBM_AXI_INTF_X31Y0 }
add_cells_to_pblock $stage1Pblock [get_cells]
```

plus, at the top level, `HD.TANDEM 1` on every cell of the pcie4c IP and on the
ports `sys_clk`, `sys_clk_gt`, `sys_reset`, `pci_exp_rxn`, `pci_exp_rxp`.
A second pblock, `Stage1_cfgiob`, is created empty and resized to the
programmable unit around `MMCM_X0Y1`, with the comment "Users must add their
IOBs to this pblock as required by their design".

Translated into this device's geometry (MEASURED, device queries):

| resource | device total | inside stage 1 | share |
|---|---|---|---|
| SLICE | 54,960 | 4,020 | **7.31%** |
| DSP48E2 | 2,880 | 180 | **6.25%** |
| RAMB36 columns | 14 | 2 | 14.3% |
| BLI_HBM_AXI_INTF | 32 (X0..X31) | 1 (X31) | 3.1% |
| GTY quads | 4 usable on this package edge | 4 (X1Y0..X1Y3) | all of quad column X1 |
| CLE tile columns | X0..X147 | X136..X147 | rightmost 12 of 148 |

`SLICE_X216Y0` is in clock region **X7Y0** and `SLICE_X216Y239` in **X7Y3**
(MEASURED). So the stage-1 region is a **full-height vertical stripe occupying
most of clock-region column X7, in all four clock-region rows.** It is not a
corner and it is not confined to the bottom half.

### 4.2 It is an exclusion zone, not a preference

**MEASURED**, `get_drc_checks HDTC*` on this part in Vivado 2023.2:

```
HDTC-4  | Stage one Pblock logic must be contained                | Error
HDTC-5  | If a first stage Pblock ranges a tile, all sites in that tile should be ranged | Error
HDTC-6  | Non-stage-one logic illegally placed                    | Error
HDTC-10 | Config banks not available to second stage I/O          | Error
HDTC-11 | Non-stage one IO in stage one must be tristated         | Critical Warning
HDTC-12 | CONFIG cells must be in stage one                       | Error
HDTC-13 | IO banks can not be shared by first and second stage    | Error
HDTC-14 | Stage 1 and 2 logic placed in the same tile             | Warning
HDTC-17 | HD.OVERRIDE_PERSIST requires CONFIG_MODE                | Error
HDTC-18 | Stage 1 Pblocks must be aligned to Programmable Units   | Critical Warning
```

`HDTC-6` at severity `Error` settles the question the brief asked: **stage-2
logic may not be placed inside the stage-1 pblock.** The area is gone.

Vivado also carries the string `uses CLOCKREGION grid range. CLOCKREGION grid
range is not supported for stage one Pblock`, so the stage-1 pblock is
necessarily expressed in site ranges. That matters for TRACK PBLOCK only in that
the two kinds of pblock are written differently; it is not a conflict.

### 4.3 Bank 65, and why it is the sharpest edge

**MEASURED.** Every non-GT pin in `hw/fk33/fk33_pcieep.xdc` resolves, in
`data/parts/.../xcvu33p_fsvh2104.pkg`, to a pin name ending `_65`:

```
BE24  IO_L10P_T1U_N6_QBC_AD4P_A12_D28_65   pcie_perstn      <- STAGE 1
BE25  IO_L10N_T1U_N7_QBC_AD4N_A13_D29_65   pcie_clkreq
BC26  IO_L14P_T2L_N2_GC_A04_D20_65         sysref_clk_p
BC27  IO_L14N_T2L_N3_GC_A05_D21_65         sysref_clk_n
BD25  IO_L12N_T1U_N11_GC_A09_D25_65        led[0]
BE26  IO_L15P_T2L_N4_AD11P_A02_D18_65      led[1]
BD23  IO_L11P_T1U_N8_GC_A10_D26_65         led[2]
BF26  IO_L15N_T2L_N5_AD11N_A03_D19_65      led[3]
BC25  IO_L12P_T1U_N10_GC_A08_D24_65        led[4]
BB26  IO_L13N_T2L_N1_GC_QBC_A07_D23_65     led[5]
BB25  IO_L13P_T2L_N0_GC_QBC_A06_D22_65     led[6]
BB24  IO_L5N_T0U_N9_AD14N_A23_65           i2cprobe_tri_io[0]
BA24  IO_L5P_T0U_N8_AD14P_A22_65           i2cprobe_tri_io[1]
```

Bank 65 is the configuration bank; the `A..`/`D..` names in those pin functions
are the multiplexed configuration address and data pins. `pcie_perstn` is
`sys_reset`, which the Tandem XDC marks `HD.TANDEM 1`, i.e. stage 1. Everything
else on the list is currently driven from the AXI-Lite fabric, i.e. stage 2.
`HDTC-13` makes that combination an Error.

AMD's description of the Field Updates flow says the same thing from the other
direction: the reconfigurable partition "includes everything except any I/O and
I/O logic located in bank 65 alongside the PCIe IP PERSTN pin". So under Tandem
the LEDs, the I2C probe bus and their drivers must be **static** logic, hoisted
out of the AXI-Lite fabric they currently hang off.

**Consequence, and it is not small: the observability that
`docs/debugging/2026-08-28_fk33-free-running-observability.md` was written to
establish is all in bank 65.** Under Tandem it either moves into the static
region, which means it can no longer be driven by an AXI-Lite peripheral in the
reconfigurable half, or it stops working. This is a design restructuring, not a
constraint tweak.

### 4.4 What each variant additionally sets

MEASURED, from the diff across modes:

- **Tandem PROM** adds `CONFIG_MODE SPIx4` (which
  `fk33_pcieep.xdc:125` already sets) and `HD.OVERRIDE_PERSIST TRUE`, and emits
  a **Combined** bitstream: one file, both stages, in flash, loaded in one pass
  with the endpoint brought up between them. `HD.OVERRIDE_PERSIST TRUE` means
  the SPI configuration pins remain owned by the configuration engine while
  stage 2 streams. No host software at all.
- **Tandem PCIe** sets `HD.OVERRIDE_PERSIST FALSE` and `HD.TANDEM_BITSTREAMS
  Separate`: two files. Stage 1 from flash, stage 2 pushed by the host through
  the MCAP VSEC.
- **Tandem PCIe with Field Updates** emits the same physical constraints as
  Tandem PCIe. The difference is entirely in the design structure: stage 2
  becomes a **reconfigurable partition** tagged `HD.RECONFIGURABLE`, the PCIe IP
  is tagged `HD.TANDEM`, and the design is built as **three separately
  synthesised partitions** (top, PCIe IP, user application), the two submodules
  out-of-context. That is a DFX design, with every DFX rule attached.

### 4.5 One thing it quietly claims

`BLI_HBM_AXI_INTF_X31Y0` and `BLI_HBM_APB_INTF_X31Y0` are inside the stage-1
pblock. There are exactly 32 of each, `X0..X31` (MEASURED). The X index almost
certainly corresponds to HBM AXI channel 31 (DERIVED from the indexing; **not
confirmed**). `gen_pcieep.py:271` deliberately leaves `SAXI_30` and `SAXI_31`
disabled as "the two spare engine ports" for subsystems B and C. **So Tandem
costs nothing here today and forecloses one of the two reserved spares.**

---

## 5. The costed comparison

Effort figures are **ESTIMATE**s. The assumption behind every one of them is a
single engineer working with the existing `gen_pcieep.py` generator flow, and a
design that already routes; none of these can start before that. Where an
estimate rests on a measured fact I say which.

### 5.1 ICAP over AXI

| variant | what you get | effort | what it forecloses |
|---|---|---|---|
| **1a. HWICAP plumbing only** | host can write bytes to the configuration engine over the existing AXI-Lite BAR | **~1 day**, matching Oren's estimate | nothing |
| **1b. ICAP + DFX** | genuine partial reconfiguration of a planned region | **2 to 4 weeks** | RP boundary kills cross-boundary optimisation; RP pblock is a second floorplan constraint on a design that cannot route |
| **1c. ICAP + flash write + IPROG** | full-device reload, from the host, no JTAG | **3 to 5 days** | link drops on every reload; needs a PCI rescan or reboot; needs an AXI Quad SPI plus `STARTUPE3`, and the config pins are in bank 65 |

**Correction to the one-day estimate.** One day is right for 1a and 1a buys
nothing on its own: an ICAP you can write to is not a design you can reload. The
useful numbers are 3 to 5 days (1c) or 2 to 4 weeks (1b). Two facts from the
tree sharpen this:

- **There is no host-writable flash path today.** MEASURED: no `STARTUPE3` and
  no `axi_quad_spi` anywhere in `gen_pcieep.py` or the generated Tcl. Flash is
  written over JTAG by `hw/fk33/flash.sh` only. 1c has to build that path.
- **1a cannot be tested.** MEASURED (OI-12): there is no bitstream. Adding an IP
  to a design that does not route produces a design that does not route.

Note also that 1c's end state is operationally identical to what already works:
`docs/debugging/2026-08-28_fk33-first-light.md` records a warm JTAG configure
into a live root port followed by `echo 1 > /sys/bus/pci/rescan`, which reloads
the card without rebooting the host. 1c removes the JTAG cable from that loop
and nothing else.

### 5.2 MCAP

| variant | what you get | effort | what it forecloses |
|---|---|---|---|
| **2a. `DFX_over_PCIe`, IP setting only** | MCAP VSEC live in extended config space; **no pblock, no floorplan** (MEASURED) | **hours** | almost nothing; the MCAP clock is derived in the GT and costs a BUFG_GT |
| **2b. MCAP + DFX** | partial reconfiguration over PCIe | **2 to 4 weeks**, same as 1b | same as 1b |

**MCAP's real advantage is not throughput, it is independence.** It is reached
through PCIe extended configuration space, not through a BAR, so it works when
the AXI fabric behind the BARs is broken or absent. That makes it a bring-up and
recovery instrument rather than only a reload path. Against that, MCAP is a
narrow register-write path through config space; I did **not** measure its
throughput and would not assume it is fast for an 11 MB payload.

### 5.3 Tandem

| variant | what you get | effort | what it forecloses |
|---|---|---|---|
| **3a. Tandem PROM** | cold boot closes; endpoint up early, rest streams from the same flash; **no host software** | **2 to 5 days** of build-flow work *plus* the bank-65 restructuring | 7.31% CLB / 6.25% DSP; the LED and I2C observability path; one spare HBM BLI |
| **3b. Tandem PCIe** | 3a, plus a one-shot host push of stage 2 over PCIe | 3a **+ 2 to 3 days** for an MCAP stage-2 loader | as 3a, plus a driver-binding ordering problem (below) |
| **3c. Tandem PCIe with Field Updates** | 3b, plus stage 2 reloadable at runtime with the link staying up. **This is the only option that literally answers "reload over PCIe without dropping the link"** | **3 to 6 weeks** | as 3b, plus the whole design becomes a DFX reconfigurable partition with three separately synthesised partitions |

**The driver-binding problem in 3b and 3c is real and is worth naming.** After
stage 1 the endpoint answers configuration reads, so the BIOS and the OS
enumerate it, but its BARs are backed by stage-2 logic that does not exist yet.
The XDMA driver must not bind until stage 2 has landed. In the Alveo world this
is handled by a separate management function and a userspace loader; here it
means a tool that finds the MCAP VSEC in
`/sys/bus/pci/devices/.../config` at offset >= 0x100 and writes stage 2 before
`modprobe`. That is a few hundred lines, but it has to run in the right order
every boot.

### 5.4 The comparison in one table

| | cold boot fixed | reload over PCIe | link stays up | floorplan cost | host software | effort |
|---|---|---|---|---|---|---|
| do nothing (JTAG + rescan) | no | no | no | none | none | 0, already works |
| 1a HWICAP plumbing | no | no | - | none | trivial | ~1 day |
| 1c ICAP + flash + IPROG | no | **yes** | no | none | moderate | 3 to 5 days |
| 2a MCAP enabled | no | no | - | **none** | none | hours |
| 1b / 2b DFX | no | partial only | yes | RP pblock | moderate | 2 to 4 weeks |
| 3a Tandem PROM | **yes** | no | - | 7.31% CLB stripe | **none** | 2 to 5 days + bank 65 |
| 3b Tandem PCIe | **yes** | one shot | no | 7.31% CLB stripe | MCAP loader | + 2 to 3 days |
| 3c Tandem + Field Updates | **yes** | **yes** | **yes** | stripe **+ RP** | MCAP loader | 3 to 6 weeks |

---

## 6. Floorplan interaction: does Tandem fight the pblock work?

### 6.1 The direct area arithmetic

DERIVED from the measured shares:

- LUT utilisation today is 39.50% of the whole device. Removing 7.31% of the
  CLBs raises the effective figure to `39.50 / (1 - 0.0731) = 42.62%`, **+3.12
  points**.
- DSP utilisation today is 55.03%. Removing 6.25% of the DSPs gives
  `55.03 / (1 - 0.0625) = 58.70%`, **+3.67 points**.
- `matvec_core` holds 1,584 of 2,880 DSPs. After Tandem there are 2,700 DSP
  sites left, so it still fits, with the margin cut from 1,296 spare to 1,116.

Those numbers are mild. They are not the problem.

### 6.2 The eviction, which is the problem

**MEASURED**, by decomposing every placed leaf cell of the shipping placed
checkpoint that falls inside the stage-1 rectangle:

| instance | cells inside the stage-1 rectangle | of which |
|---|---|---|
| `bd_i/pcie2axil` (AXI-Lite smartconnect) | 23,033 | all LUT/FF |
| `bd_i/xdma` | 11,834 | 11,808 LUT/FF, 26 RAMB |
| **`.../dut/core` (`matvec_core`)** | **8,690** | 8,395 LUT/FF, **288 DSP**, 7 RAMB |
| `bd_i/pcie2hbm` | 3,783 | all LUT/FF |
| `bd_i/axil2eng` | 547 | |
| `bd_i/auxconnect` | 530 | |
| `bd_i/fk33_scratch` | 345 | |
| `bd_i/system_management_wiz_0` | 288 | |
| everything else (aux, thermal, GPIO, jtag_axil, HBM, clocking) | ~1,085 | |
| **total** | **50,135** | |

Only the pcie4c hard-block wrapper's own cells are stage 1. That is a subset of
XDMA's 11,834; the DMA engine, the descriptor BRAMs and both smartconnects are
stage-2 logic. So the eviction is **between 38,301 cells (if every XDMA cell in
the stripe turned out to be stage 1, which it will not) and 50,135 cells (if
none is)**. Call it forty-something thousand leaf cells, 288 DSPs among them.

Where do they go? Not right: there is nothing right of `SLICE_X232`, it is the
last CLE tile column. **They go left, into the die that already fails at
congestion level 7.** And two of the three largest evictees, `pcie2axil` at
23,033 cells and `pcie2hbm` at 3,783, are precisely the fabric that has to talk
to the PCIe hard block, so moving them left lengthens the nets that connect to
the one thing that cannot move.

### 6.3 Does the stripe overlap the congestion?

**MEASURED**, by mapping the router's own congested-window tile coordinates from
`docs/debugging/2026-08-29_shell-congestion.md` into slice coordinates on this
device:

| router window (tile coords) | slice coords | overlaps stripe X216..X232? |
|---|---|---|
| West Short **level 5**, the worst: `(CLEL_L_X84Y16, CLEM_X115Y79)` | `SLICE_X131Y16 .. SLICE_X180Y79` | **no** |
| East Short 6 `(CLEM_X33Y0, CLEM_X128Y63)` | `SLICE_X52 .. SLICE_X201` | no |
| East Global 7 `(CLEM_X1Y0, CLEM_X128Y95)` | `SLICE_X1 .. SLICE_X201` | no |
| West Long 7 `(CLEM_X32Y3, CLEL_L_X127Y98)` | `SLICE_X50 .. SLICE_X200` | no |
| South Global 7 `(CLEM_X13Y18, CLEL_R_X140Y81)` | `SLICE_X19 .. SLICE_X221` | **yes** |
| West Global 7 `(CLEL_L_X15Y20, CLEL_R_X142Y83)` | `SLICE_X23 .. SLICE_X224` | **yes** |

So the worst single window, the one at 89% LUT and 53% MUXF where `matvec_core`
is 88% of the cells, is **mid-die and does not touch the Tandem stripe**. Three
of the level-7 global and long windows do extend into it.

The honest reading: **Tandem does not take away area the router is currently
fighting over, and it does not relieve it either. It takes area from the one
part of the die that is working, and pushes forty-odd thousand cells toward the
part that is not.** There is no version of this that makes congestion better.

### 6.4 Against TRACK PBLOCK specifically

CONGEST measured that 96.1% of `matvec_core` sits in clock-region rows Y0 and
Y1, and that Y2 and Y3 hold 1,176 free DSP sites and 663 free RAMB18 sites.
TRACK PBLOCK is trying to spread the core upward into Y2/Y3.

**The two are not in opposition in direction. They overlap in exactly two clock
regions.** Tandem claims clock-region column X7 in all four rows; PBLOCK wants
rows Y2 and Y3 across all eight columns. The intersection is X7Y2 and X7Y3,
which is 2 of the 16 clock regions PBLOCK is aiming at, i.e. it removes roughly
an eighth of the empty top half.

That is a mild direct cost. The real interaction is second-order and worse:

1. **A pblock written now would have to be rewritten.** Any `resize_pblock` that
   ranges across X7 in Y2/Y3 becomes illegal the day Tandem is switched on,
   because `HDTC-6` is an Error. PBLOCK's measurements would then be
   measurements of a floorplan that cannot ship.
2. **Tandem's eviction lands in PBLOCK's target.** The ~40k cells pushed out of
   the stripe have to go somewhere, and the empty space is Y2/Y3, which is the
   same space PBLOCK is trying to give to `matvec_core`. The two claims on that
   space are additive.
3. **Field Updates would add a third, larger pblock.** In 3c the entire user
   application is a reconfigurable partition with its own frame-aligned pblock.
   That is not a refinement of PBLOCK's floorplan, it replaces it.

**So: sequence them, do not run them together.** Not because the constraints
conflict head-on, but because a floorplan optimised without the stripe is not a
floorplan, it is a rehearsal.

---

## 7. Sequencing recommendation

**I agree with "route first, then Tandem", and I would state it more strongly:
Tandem cannot be evaluated at all until the design routes.** The reasoning,
exposed:

1. **Every option in this document terminates in a bitstream, and there is no
   bitstream** (OI-12, MEASURED). ICAP plumbing, MCAP enablement and Tandem
   partitioning are all untestable today.
2. **Tandem strictly subtracts.** It removes 7.31% of CLBs and evicts ~40k cells
   toward the congested half. Adding it to a design that fails at level 7 tells
   you nothing you did not already know, and it destroys the ability to
   attribute a failure to either cause.
3. **The floorplan is in flight.** TRACK PBLOCK's work would be invalidated
   twice: once by the stripe, once again by an RP pblock if Field Updates is
   chosen.
4. **The motivation is not yet measured.** The 225.7 ms is DERIVED, and the same
   document that derives it records a positive control, the SQRL factory image
   enumerating on this board at Gen3 x4 from its own flash. **A cold-boot
   `lspci` on the newly arrived second card is a zero-cost experiment that could
   remove the entire cold-boot case for Tandem.** It has not been taken. Take it
   before spending days on 3a.

**One decision should nonetheless be made now, with no implementation.** Field
Updates (3c) requires the design to be three separately synthesised partitions
with all bank-65 I/O in the static region. That is a hierarchy decision. Making
`gen_pcieep.py` emit a clean top / PCIe / user-application split, and keeping the
LED and I2C drivers out of the reconfigurable half, is far cheaper to do while
the shell is being reworked for congestion anyway than to retrofit later.
**Deciding "is Field Updates on the roadmap, yes or no" costs nothing today and
saves weeks if the answer is yes.** If the answer is no, 3a and 3b need no
hierarchy change and can wait indefinitely.

**What I would do, in order:**

1. **Now, free:** cold-boot `lspci` on the second card with the SQRL factory
   image, and record the size of that factory image, which is the number that
   would tell us how much margin the Z790 really gives. (The previous attempt at
   this destroyed the image before measuring it; the second card is the only
   remaining chance.) Decide the Field-Updates-or-not hierarchy question.
2. **Next:** close routing. Nothing else is decidable until then.
3. **Then, cheap and independently useful:** `mcap_enablement DFX_over_PCIe`
   (hours, no floorplan) if a config-space-reachable configuration port is
   wanted as a bring-up instrument, plus HWICAP plumbing if wanted. Both are
   additive and neither commits to anything.
4. **Only if step 1 shows the cold-boot budget genuinely does not close:**
   Tandem PROM, which is the smallest thing that fixes it and needs no host
   software.
5. **Only if the JTAG development loop is measurably dominating the schedule:**
   Tandem PCIe with Field Updates, on a design that already routes with room to
   spare.

---

## 8. What would have to be true for each option to be the right one

**Do nothing (keep JTAG configure + PCI rescan).** Right if the second card's
cold boot shows the real configuration window on this host is comfortably above
191.8 ms, *and* the JTAG cable is going to be attached during development
anyway, *and* nobody needs to reload the card from a machine without a
programmer. The first-light procedure already works and costs zero.

**1a, HWICAP plumbing.** Right if the goal is a place to put configuration
readback, an IPROG trigger, or a DNA/eFUSE read, rather than a reload. Right if
you want the hook in place before the shell is frozen. Wrong if it is being
bought as "reload over PCIe", because it is not that.

**1c, ICAP plus flash write plus IPROG.** Right if the requirement is honestly
"reload the card from the host without a JTAG cable" and a link drop plus a
rescan is acceptable, which it is today because the existing procedure already
does exactly that. Requires accepting an AXI Quad SPI and `STARTUPE3` on
bank-65 config pins, and it must not collide with whatever Tandem PROM would
later want from the same pins.

**2a, MCAP enabled.** Right if you want a configuration path that is reachable
when the AXI fabric is broken, because it lives in config space and not behind a
BAR. It costs hours and no floorplan, which makes it the highest ratio of
optionality to cost in this document. Wrong if it is expected to load a full
bitstream, which it cannot.

**1b / 2b, DFX.** Right if the thing that actually needs to change between
loads is a bounded part of the design, for example swapping a matvec kernel or a
sampler, rather than the whole engine. Requires the design to route with an RP
pblock and requires giving up optimisation across the RP boundary. Wrong as a
way to reload everything.

**3a, Tandem PROM.** Right if and only if the cold-boot measurement shows the
budget does not close. It is the smallest fix for that specific problem, it
needs no host software, and its `CONFIG_MODE SPIx4` requirement is already
satisfied by `fk33_pcieep.xdc:125`. Requires solving bank 65 for the LEDs and
I2C, and requires the design to route with 7.31% fewer CLBs.

**3b, Tandem PCIe.** Right if 3a's conditions hold *and* you want to change the
design without reprogramming flash, and you can live with a host tool that must
run before the XDMA driver binds. It does not keep the link up across a reload.

**3c, Tandem PCIe with Field Updates.** Right if all of: the cold-boot budget
does not close; the JTAG development loop is measurably the schedule
bottleneck; the design routes with real margin so that a stripe plus an RP
boundary is affordable; and the team is willing to carry a three-partition DFX
build for the life of the project. **None of those is true today**, and the
third is the opposite of true.

---

## 9. Open, not yet answered

1. **The stage-1 bitstream size for this design, and therefore whether Tandem
   actually closes the cold-boot budget.** ESTIMATE only: the stage-1 region is
   ~7% of CLB columns, ~14% of BRAM columns and ~6% of DSP columns, so stage 1
   is plausibly 1 to 2 MB compressed, i.e. 16 to 32 ms at `CONFIGRATE 127.5`
   SPIx4, against 191.8 ms for the whole payload. That is a guess from area, not
   a measurement, and the stage-1 region is dense so it compresses worse than
   average. Only running the flow answers it.
2. **The real cold-boot configuration window on this host.** The 225.7 ms and
   191.8 ms figures are DERIVED. The one experiment that settles it, a cold boot
   with the second card's intact factory image plus a note of that image's size,
   has not been run.
3. **Whether the bank-65 I/O can be retained at all under Tandem.** `HDTC-10`
   and `HDTC-13` are Errors and AMD's Field Updates text says bank-65 I/O goes
   in the static region, but I have not run an implementation to see what
   actually fires and at what severity for this specific pin set.
4. **Which SAXI channel `BLI_HBM_AXI_INTF_X31Y0` serves.** Inferred from the X
   index. Not confirmed. If it is not channel 31 the "costs nothing today" claim
   in 4.5 needs revisiting.
5. **How much of XDMA's 11,834 cells in the stripe are pcie4c hard-block wrapper
   (stage 1) and how much is DMA engine (stage 2).** Not decomposed, which is
   why section 6.2 gives a range rather than a number.
6. **Whether Tandem works on ES1 silicon through the existing waiver.** The
   revision check is client-side and
   `xicom.skip_bitstream_compatibility_check 1` clears it for the flash path
   (MEASURED, `2026-08-28_fk33-spi-flash-boot.md` section 10.2). Whether a
   Tandem stage-1/stage-2 pair loads on an ES1 die through the same waiver is
   untested, and so is MCAP on ES1.
7. **Whether the HBM IP conflicts with Tandem.** Vivado carries a parameter
   named `mig.downGradeMIGAndTandemPCIConflictDRC` (MEASURED, string in
   `librdi_*.so`), so a memory-controller-versus-Tandem conflict DRC exists for
   MIG. Whether the HBM controller triggers an analogue of it, and what the HBM
   APB initialisation sequence does across a stage boundary, is not determined.
   Given that `hbm/APB_0_PCLK` is fed by `clk_wiz_0` off `xdma/axi_aclk`, this
   deserves a look before committing to Tandem.
8. **MCAP throughput.** Not measured. For an 11 MB stage 2 this could be the
   difference between a usable and an unusable development loop.
9. **Whether the design routes at all.** Everything above is contingent on it.

---

## 10. Measured and REJECTED -- do not retry

- **Reading the Tandem constraint generator directly.** `pcie4c_uscale_plus_v1_0
  /ttcl/xilinx_pcie4c_uscale_tandem_xdc.ttcl` and the ten files under
  `ttcl/TANDEM/` are Xilinx-encrypted (`XlxV50EB` header). Generating the IP and
  reading the emitted XDC is the only way to see the stage-1 pblock, and it
  costs 2.2 GB and a couple of minutes.
- **`get_property CLOCK_REGION` on a tile object.** `ERROR: [Common 17-54] The
  object 'tile' does not have a property 'CLOCK_REGION'`. Go via
  `get_sites -of_objects` and query the site.
- **`link_design -part` without a project.** Fails silently in `-mode batch`
  with no output at all. `create_project -in_memory -part ...` first.
- **`get_sites -filter {SITE_TYPE =~ RAMB36*}` as a device-wide site count.** It
  returns 259 on this device, which is the *design's* RAMB36 usage, not the
  device's ~672 sites, because an unoccupied block RAM site reports a different
  SITE_TYPE. The DSP filter does not have this problem (2,880 is correct). Any
  "fraction of the device" claim built on that filter is wrong; the RAMB numbers
  in this document are stated as columns, not sites, for that reason.
- **Treating tile X coordinates as slice X coordinates.** The congestion
  report's windows are in tile coordinates (max CLE tile X = 147); slices run to
  X232. `CLEL_R_X140Y81` is `SLICE_X221Y81`. Comparing the two directly would
  have put every congested window outside the Tandem stripe, which is false for
  three of them.
- **Looking for a per-device Tandem support table in PG213 or PG195.** Neither
  has one; PG213 defers to PG195 and PG195 says only "all UltraScale and
  UltraScale+ devices with PCIe hard blocks". The IP's own XGUI Tcl has the real
  table, names `XCVU33P` explicitly, and gates on `pcie_blk_locn`.

---

## 11. Machine discipline

Five Vivado 2023.2 batch sessions, all read-only. **No place, no route, no
bitstream, no `program_hw_devices`, no `xsdb`, no `hw_server`, nothing touching
`/dev/xdma*`.** Sessions 1 to 4 ran under `setsid` with an RSS guard on their own
process group, killing by pgid and never by name pattern. Peak RSS across all
sessions: **6.30 GB**, guard never tripped. Total wall time under 20 minutes.

Sources for the corroborating documentation claims:

- [Tandem Configuration Logic, PG213](https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus/Tandem-Configuration-Logic)
- [Tandem Configuration, PG213](https://docs.amd.com/r/en-US/pg213-pcie4-ultrascale-plus/Tandem-Configuration)
- [Tandem Configuration, PG195](https://docs.amd.com/r/en-US/pg195-pcie-dma/Tandem-Configuration)
- [AR# 68081, DRC HDTC-6 Non-stage-one logic illegally placed](https://www.xilinx.com/support/answers/68081.html)
- [AR# 71877, Reconfigurable Stage 2 support for Tandem PCIe with Field Updates](https://www.xilinx.com/support/answers/71877.html)
- [Xillybus, Partial Reconfiguration over PCIe with ICAP/MCAP](https://xillybus.com/tutorials/pcie-icap-dfx-partial-reconfiguration)
