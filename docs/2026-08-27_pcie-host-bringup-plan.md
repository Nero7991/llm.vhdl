# PCIe host path: everything that can be prepared before the card is in the slot

**Date:** 2026-08-27
**Hardware:** SQRL FK33, XCVU33P (fsvh2104, ES1 die, built as -2L), on
`Oren-Dell-Ubuntu` (Z790, kernel 6.8.0-138-generic)
**Status of the thing being planned:** no FK33 has ever enumerated on PCIe.

> **Addendum, same day.** Three bring-up peripherals were added to the design
> after this was written -- a read-only identity register at BAR `0xA000`, 8 KB
> of read/write scratch BRAM at `0x10000`, and a 64 KB BRAM DMA target at
> `0x2_0000_0000` -- together with a host test program
> (`hw/fk33/host/fk33_bringup.c`) and a board-free constraint checker
> (`hw/fk33/check_pcieep_xdc.py`). Section 4.5's address map is superseded by
> the one in **`docs/2026-08-27_fk33-pcie-bringup-procedure.md`**, which is also
> now the operational checklist; this document remains the design reasoning.
> The block design has since been validated in Vivado
> (`./pcieep_build.sh --bd-only`); see
> `docs/debugging/2026-08-27_pcieep-bd-critical-warnings.md` for the one
> surprising thing that came out of it.

Every result in this project to date -- first light, I2C, SYSMON telemetry, the
288-353 GB/s HBM bandwidth sweeps -- went over JTAG. Every bitstream ever built
here set `EnablePCIe 0`.

---

## The question

Prepare the PCIe host path as far as it can be taken without the card being
plugged in, because plugging it in costs a machine restart. PCIe is the only
route by which model weights and input tokens reach HBM, so nothing runs
without it, and nothing about it has ever been tested.

## The answer, up front

Six things, all of which are now done or written and none of which needed the
card:

1. **The lane split is settled and verified, not assumed.** The FK33's 16 edge
   lanes are exactly GTY quads 227/226/225/224. Edge lanes 0-3 are quad 227 in
   its entirety. x4 to the host therefore consumes one quad and leaves three
   whole quads for Aurora. Narrowing to x1 or x2 frees nothing usable. Checked
   against Vivado's own package file, below.

2. **XDMA, not QDMA.** Reasoning in section 3. The decisive argument is that
   the XDMA character device's file offset *is* the AXI address, so the weight
   loader is `pwrite(fd, blob, len, 0)` and nothing else.

3. **The bitstream is designed and its build script written** (`hw/fk33/`),
   derived from the I2C-probe build by a generator that aborts if any of its
   anchors move. It is not built: Vivado has not been run.

4. **A latent upstream bug was found and fixed in the process.** SQRL's own
   script disconnects SYSMON whenever `EnablePCIe == 1`. It has never been
   caught because that script creates a project and stops without synthesising.
   Anyone enabling PCIe from the vendor sources hits it. Section 4.3.

5. **The bring-up order is forced by VCCINT, and it is not the obvious order.**
   The rail powers up 20 mV below the -2L floor and the fix is volatile. The
   sequence has to be probe bitstream -> raise VCCINT -> endpoint bitstream,
   because in the endpoint bitstream the JTAG-AXI masters are themselves
   clocked by the PCIe user clock and are dead until the link is up. Section 5.

6. **Cold weight load is not a problem.** 4.5 GB at an expected 3.2-3.4 GB/s is
   **about 1.4 s**, 2.3 s at a pessimistic 2 GB/s. The per-token path uses well
   under 1% of the link. Section 7.

What is *not* answered, and cannot be from here, is section 9.

---

## 1. The lane split, and why it had to be settled before the endpoint exists

### 1.1 What was verified

Vivado ships the package pin table for this exact part at
`/tools/Xilinx/2023.2/Vivado/2023.2/data/parts/xilinx/virtexuplusHBM/public/ibis/pkg/xcvu33p_fsvh2104.pkg`.
Cross-referencing every PCIe pin in `hw/fk33/fk33_i2cprobe.xdc` against it:

| edge lane | RX pin | package signal | quad | channel |
|---|---|---|---|---|
| 0 | AL2 | `MGTYRXP3_227` | 227 | 3 |
| 1 | AM4 | `MGTYRXP2_227` | 227 | 2 |
| 2 | AK4 | `MGTYRXP1_227` | 227 | 1 |
| 3 | AN2 | `MGTYRXP0_227` | 227 | 0 |
| 4-7 | AP4 AR2 AT4 AU2 | `MGTYRXP3..0_226` | 226 | 3..0 |
| 8-11 | AV4 AW2 BA2 BC2 | `MGTYRXP3..0_225` | 225 | 3..0 |
| 12-15 | AY4 BB4 BD4 BE6 | `MGTYRXP3..0_224` | 224 | 3..0 |
| refclk | AD9/AD8 | `MGTREFCLK0P/N_226` | 226 | -- |

Two things fall out that were not previously written down anywhere in either
repo:

- **The lane order is reversed inside each quad**, and the quads descend as the
  lane index rises. This is the normal layout for a card-edge connector. It
  needs no constraint: PCIe negotiates lane reversal during link training.
- **The reference clock is in quad 226, not in the quad the block will use.**
  So this design already depends on inter-quad reference clock routing. If it
  builds and links, that routing is proven, which is one fewer unknown for the
  Aurora quads later.

Separately, from DS890 Table 17 (`docs/datasheets/ds890-ultrascale-overview.pdf`):
the VU33P has **32 GTY transceivers** (8 quads: 124-127 and 224-227) and **four
PCIE4C blocks, zero PCIE4**, where PCIE4C is "PCIe Gen3 x16 / Gen4 x8". The four
quads 124-127 exist on the die but are not bonded out on this board. That
matches `fk33_firstlight_util.rpt`'s `GTYE4_CHANNEL: 32 used` and confirms the
16-lane ceiling is a *board* limit, not a die limit.

### 1.2 The consequence, stated three ways

The brief asks me to confirm from device documentation that the hard block
claims a whole quad regardless of width. I can confirm the *conclusion* three
independent ways, and I am only fully confident in two of them:

**(a) Verified from the package file, and decisive on its own.** Edge lanes 1,
2 and 3 are physically wired to the card-edge fingers that go to the *host*
connector. In the planned topology, and in the interim MCIO topology, those
fingers face the motherboard, not a peer card. So even if an x1 endpoint left
channels 1-3 of quad 227 completely free, those channels could not carry Aurora
peer traffic -- there is nowhere for them to go. **Narrowing the host link frees
no usable lane.** This argument does not depend on any claim about the hard
block at all.

**(b) Verified from the interconnect design.** A K4 mesh needs three equal peer
links. 12 divides as 3 x 4 on quad boundaries; 14 and 15 do not divide three
ways at all. (`pcie-llm-hardware/docs/00-rationale.md`.)

**(c) The quad-ownership claim itself: mechanism understood, primary source not
checked on this machine.** At Gen3 the line rate is 8 Gb/s, above what a GTY
CPLL reaches, so the PCIe block must use the quad's QPLL, which lives in the
`GTYE4_COMMON`. The Vivado PCIe/XDMA IP instantiates that COMMON inside its own
hierarchy and does not expose its ports, so user GT logic placed in the same
quad would have to share a PLL it has no handle on, at a reference clock and
line rate chosen for PCIe. That is the documented architecture and I believe it,
but I did not open UG578 today to quote it, and I could not query the site
database without running Vivado. **Do not cite (c) as verified.** The decision
rests on (a) and (b), which are.

### 1.3 What this means for the constraint file

Concretely, in `hw/fk33/fk33_pcieep.xdc` (generated):

- **Constrain lanes 0-3 only.** Eight differential pairs: AL2/AL1 + Y5/Y4,
  AM4/AM3 + AA7/AA6, AK4/AK3 + AB5/AB4, AN2/AN1 + AC7/AC6. Those are quad 227
  and nothing else.
- **Comment lanes 4-15 out; do not delete them.** They are the Aurora quads and
  the file that will need their pin mapping is this one. Unmatched `get_ports`
  in an XDC is only a warning (confirmed: the i2cprobe build carries 24 of
  them), so leaving them in would *work* -- but 48 warnings is exactly the noise
  that hides a real constraint error, and the house rule is that a log you have
  to skim is a log you do not read.
- **Add no lane-reversal constraint.** The reversal is inside the quad and the
  link layer handles it.
- **Do not LOC the GT channels directly.** Let the IP place from the port pin
  constraints, then read the placed sites back out of the utilization report and
  confirm quad 227. `hw/fk33/pcieep_build.sh` greps for exactly that.
- **Comment out `sysref_clk_p/n`.** Those ports exist only in the
  `EnablePCIe == 0` branch, where the 200 MHz on-board SiTime oscillator feeds
  `clk_wiz_0`. With PCIe on, `clk_wiz_0`'s input is `xdma/axi_aclk` instead and
  the sysref buffer is never instantiated.
- **Keep the refclk `create_clock -period 10.000`.**

---

## 2. What the card actually needs, physically

Established in earlier work, restated because it is the part that a machine
restart makes expensive to get wrong:

- **The card does not come up on slot power.** The LEDs stay dark until the
  6-pin aux connector is fed. Slot power is supplementary here. A 6-pin PCIe
  lead from the PSU must reach the card in its final position.
- The exact aux connector count and type were never pinned down beyond "6-pin".
  Confirm visually before the lid goes on.
- The card has been seated before, in the free chipset x4 port at `00:1c.0`.
  That slot is x4 electrically, which suits an x4 endpoint exactly, and it hangs
  off the PCH sharing the DMI 4.0 x8 uplink with the NIC. DMI x8 is ~15.75 GB/s;
  a 3.4 GB/s endpoint does not stress it.
- Claimed TDP is ~155 W, from community sources, never measured on this card.
  SYSMON's current-sense channels have no known scale, so do not publish watts
  from them.

---

## 3. Driver: XDMA, and why not QDMA

**Recommendation: XDMA** (`Xilinx/dma_ip_drivers`, `XDMA/linux-kernel/`).

The workload is one bulk stream and one tiny control path. That is the entire
requirement, and it maps onto XDMA with no glue at all:

- The character device's **file offset is the AXI address**. Loading weights is
  literally `pwrite(fd, blob, len, hbm_offset)` against `/dev/xdma0_h2c_0`. No
  descriptor management, no queue setup, no ioctl vocabulary to learn. The
  weight loader in `hw/fk33/host/fk33ctl.py` is a dozen lines because of this.
- The **AXI-Lite master BAR** appears as `/dev/xdma0_user` and reaches SYSMON,
  the I2C GPIO, and later the engine's control registers. A 4-byte posted MMIO
  write is a far better fit for "here is the next token" than a DMA descriptor.
- **XDMA is already the IP in SQRL's reference block design.** Choosing it makes
  the diff from a design that at least elaborates one config change, not a
  rewrite. That is the same argument that made every previous bitstream here
  derive from the last one that worked.
- The driver has a **poll mode** (`insmod xdma.ko poll_mode=1`), which removes
  MSI-X from the picture entirely for first bring-up. That matters: without it,
  an interrupt misconfiguration and a broken DMA engine produce the same
  symptom.

**QDMA, rejected.** Its advantages are many independent queues, SR-IOV, mailbox
between PF and VF, and high packet rates. This design uses none of them: one
bulk transfer at load time, then a few bytes per token. Against that it costs a
significantly larger fabric footprint on a die where the LUT budget is already
the binding constraint on the inference engine
(`docs/debugging/2026-08-25_lut-budget-measured.md`), and it replaces the
offset-is-an-address model with per-queue configuration through `dmactl` and
sysfs before any transfer can happen. Paying resources and setup complexity for
capabilities the workload never exercises is the wrong trade.

**Bare AXI Bridge / BAR-mapped HBM, rejected as the primary path.** Simplest
possible design, but host MMIO moves ~4-8 bytes per TLP from the CPU; 4.5 GB
would take minutes to tens of minutes. XDMA's optional AXI-Bypass BAR gives the
same debug window as an *addition* later if a non-DMA path into HBM is ever
wanted. Not needed for bring-up.

**Writing a driver from scratch, rejected.** PG195 documents the register model
and the Xilinx driver already implements it under a permissive licence. Writing
one costs weeks and buys nothing until the DMA path is proven working, at which
point the reason to replace it would be a measured deficiency that does not yet
exist.

---

## 4. The bitstream

### 4.1 Files

| path | what it is |
|---|---|
| `hw/fk33/gen_pcieep.py` | generator: `build_fk33_i2cprobe.tcl` -> `build_fk33_pcieep.tcl` + `fk33_pcieep.xdc`. Aborts loudly if any anchor moves. Already run; outputs are committed alongside. |
| `hw/fk33/build_fk33_pcieep.tcl` | generated build script. **Not run.** |
| `hw/fk33/fk33_pcieep.xdc` | generated constraints. |
| `hw/fk33/pcieep_build.sh` | runs the build, then greps the log for the four things that must be read rather than assumed. |
| `hw/fk33/pcieep.sh` | JTAG bring-up in the correct order (section 5). |
| `hw/fk33/tcl/pcieep_jtag.tcl` | JTAG-side check of the endpoint bitstream. |
| `hw/fk33/host/build_xdma_driver.sh` | builds the driver, no root, prints the root steps. Runnable **today**, before the card goes in. |
| `hw/fk33/host/fk33_pcie_check.sh` | staged read-only PCIe diagnosis, cheapest first. |
| `hw/fk33/host/fk33ctl.py` | MMIO, VCCINT over PCIe, DMA selftest, benchmark, weight load and verify. |

Derived from the **I2C probe** build rather than from first light, deliberately:
it is the newest thing proven to build, configure and run on this card, and it
carries the GPIO bit-bang peripheral that is the only working way to move
VCCINT. That second point is load-bearing -- see section 5.

### 4.2 What changes from the probe build

| # | change | why |
|---|---|---|
| 1 | `EnablePCIe 0` -> `1` | the point |
| 2 | width `X1` -> `X4`, Gen3 8.0 GT/s, `axi_data_width 128_bit`, 1 H2C + 1 C2H channel | section 1. 128-bit at 250 MHz = 4.0 GB/s, just over the 3.94 GB/s link ceiling, so the fabric is not the limit and a wider bus would only add smartconnect logic the link can never fill |
| 3 | vendor/device ID overrides **removed** | SQRL sets `1E24:1533`, which no stock driver has in its match table. The IP's own defaults are the IDs `dma_ip_drivers`' table was generated from. Subsystem stays `1E24:0001` so `lspci -nn` still identifies the board |
| 4 | CLKREQ# driven **low** | it is active-low and the endpoint asserts it. Upstream's bare `xlconstant` leaves it at 1, deasserted. Most desktop slots free-run the refclk and never look, but a host that honours it would gate the clock and the link would never train, with no symptom separating that from a dead transceiver |
| 5 | `pcie2axil` `NUM_MI` forced to 2 | **upstream bug**, section 4.3 |
| 6 | LED 6 driven from `xdma/user_lnk_up` | section 4.4 |
| 7 | own project dir, own XDC, own util report | the probe and first-light bitstreams stay intact as fallbacks |

### 4.3 The upstream bug

`SQRL_FK33/projects/fk33_example.tcl` sets the AXI-Lite smartconnect to
`NUM_MI 2` at line 134 and connects M01 to `system_management_wiz_0`. Then
inside the `EnablePCIe == 1` branch, line 190:

```tcl
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells pcie2axil]
```

Shrinking a connected smartconnect deletes `M01_AXI` and orphans SYSMON, so
`assign_bd_address` for `system_management_wiz_0/S_AXI_LITE` has nothing to
assign. Upstream's default is `EnablePCIe 1`, so this is on the vendor's own
default path -- it has survived only because that script creates the project and
stops without ever synthesising (which is also why `gen_firstlight.py` had to
append synthesis in the first place). Anyone enabling PCIe from the vendor
sources hits it. Fixed to `NUM_MI {2}`, and the generator asserts the old form
is gone.

### 4.4 The link-up LED, and why it is worth the trouble

In this design the **entire AXI fabric, including both JTAG-AXI masters, is
clocked by `xdma/axi_aclk` and reset by `xdma/axi_aresetn`**, both derived from
the PCIe reference clock and released only once the link is up. That has a sharp
consequence which will otherwise be discovered the hard way:

> Configured on the bench, out of a slot, with no reference clock, this
> bitstream looks **completely dead over JTAG**. That is not a broken build.

It also means JTAG cannot distinguish "no refclk" from "link down" from "the
bitstream never configured": all three hang the same reads. So LED 6 (the RGB
blue) is rewired to follow `user_lnk_up` through the existing 7-bit inverter. It
is the only link-state indicator that needs no host, no JTAG and no instrument.
The board's LED polarity is undocumented, so do not predict the direction --
observe LED 6 with the link down and with it up and take the *change* as the
signal.

The rewire is guarded: if `xdma/user_lnk_up` does not exist under this IP
version the original wiring is kept with a warning, and any failure mid-rewire
is caught and reverted rather than failing an hour-long build. `FK33_NO_LNKLED=1`
skips it.

### 4.5 The address map the host sees

```
AXI-Lite BAR (128 KB)
  0x3400   SYSMON die temperature      raw * 507.6/65536 - 279.43  degC
  0x3404   SYSMON VCCINT               raw * 3.0/65536            V
  0x9000   GPIO ch1 DATA   bit0 = SCL (BB24), bit1 = SDA (BA24)
  0x9004   GPIO ch1 TRI    1 = released, 0 = driven low.  Resets all-ones.
  0x9008   GPIO ch2 DATA   the 7 board LEDs, through led_inv

DMA (file offset == AXI address)
  0x0_0000_0000 .. 0x0_FFFF_FFFF   HBM MEM00-15 via SAXI_00
  0x1_0000_0000 .. 0x1_FFFF_FFFF   HBM MEM16-31 via SAXI_16
```

8 GB, flat and contiguous, with the redundant cross-stack routes excluded so
there is exactly one path to each 256 MB pseudo-channel. Loading weights is a
single `pwrite` at offset 0.

---

## 5. The bring-up order is forced, and it is not the obvious one

VCCINT on this card powers up at **0.678 V**, below the **0.698 V** floor of
every characterised speed grade, and the fix -- stepping an MCP45XX-class
digital pot at I2C `0x2c` down to wiper 68, giving 0.717 V -- writes the
**volatile** wiper register. A power cycle restores 128 and 0.678 V. Every time.

The pot is reachable only by bit-banging I2C from the GPIO that the *probe*
bitstream carries. So:

```
1. JTAG-configure the PROBE bitstream          GPIO bit-bang available
2. step VCCINT 0.678 -> 0.717 V                tcl/vccint_step.tcl, unchanged
3. JTAG-configure the ENDPOINT bitstream       wiper survives; die now in spec
4. host: rescan PCIe                           host/fk33_pcie_check.sh
```

Step 3 does not undo step 2 because **reconfiguring the FPGA does not
power-cycle the board**, and the wiper lives in the PMIC, not the FPGA.

The reverse order does not work. In the endpoint bitstream the JTAG-AXI masters
are themselves held in reset until the PCIe link is up, so there is no JTAG path
to the pot before the link exists. `hw/fk33/pcieep.sh` implements exactly this
sequence and refuses to be run out of order by accident.

Once the link *is* up, VCCINT can be raised from the host over MMIO instead:
`host/fk33ctl.py vccint` is a port of the same stepping algorithm, including the
deliberate first step in the wrong direction. That is what eventually removes
JTAG from the loop -- but it presupposes the link trains at 0.678 V, which is
unknown (section 9).

---

## 6. Bring-up checklist

Ordered cheapest-and-most-diagnostic first. Each stage says what it isolates,
because a stage that isolates nothing is a stage you will run twice.

### Stage 0 -- before the card goes in. No card needed. Do this now.

| step | isolates | pass | fail means |
|---|---|---|---|
| 0.1 `hw/fk33/host/build_xdma_driver.sh` | kernel API compatibility, nothing about the card | `xdma.ko` exists and `modinfo` vermagic starts with `6.8.0-138-generic` | `dma_ip_drivers` has not caught up with 6.8. Known class of problem: `class_create` losing `THIS_MODULE`, `pin_user_pages` signature churn, `MODULE_SUPPORTED_DEVICE` removal. Check branches and tags before patching |
| 0.2 `hw/fk33/pcieep_build.sh` | the design, not the hardware | `FK33_BITSTREAM` line, and `FK33_PCIE_IDS` reporting a vendor/device ID | see 0.3 |
| 0.3 read the build log | four things that can pass silently and be wrong | `FK33_PCIE_IDS` shows `10ee:xxxx`; `FK33_LNKLED OK`; `GTYE4_CHANNEL: 4 used`; zero `12-584` unmatched-constraint warnings | 4 channels not 4 means the width did not take. Any `12-584` means a port name moved |
| 0.4 BIOS list, written down before rebooting | -- | see section 8 | -- |

### Stage 1 -- power and configuration. Card in, host booted.

| step | isolates | pass | fail means |
|---|---|---|---|
| 1.1 look at the card | power delivery | fan spins, LEDs lit | the 6-pin aux is not connected or not delivering. The card does **not** run on slot power |
| 1.2 `lsusb \| grep 0403:6010` | the FTDI JTAG bridge, hence that the card has housekeeping power | present | as 1.1 |
| 1.3 `hw/fk33/pcieep.sh` | the whole JTAG configuration path plus VCCINT | `FPGA_PROG_OK` twice, `SETTLED wiper=... VCCINT=0.71x V` | if programming fails, this is the ES1 revision-check problem and the fix is already in `tcl/program.tcl` (xsdb, `-no-revision-check`), not Vivado |

### Stage 2 -- link training. The go/no-go.

This is the stage where the three failure modes have to be told apart, and the
key is that **the root port reports link state even when nothing enumerates**.

| step | isolates | pass |
|---|---|---|
| 2.1 LED 6 on the card | the PCIe block's own `user_lnk_up`, with no host and no instrument | LED 6 changed state relative to the link-down observation |
| 2.2 `sudo lspci -vvv -s 0000:00:1c.0 \| grep LnkSta` | the physical and data link layers, independently of config space | `Width x4`, `Speed 8GT/s` |
| 2.3 `hw/fk33/pcieep.sh --check` | the AXI fabric downstream of the PCIe user clock | SYSMON reads a plausible temperature |

Reading the three together:

- **`LnkSta: Width x0`** -- link training failed. Nothing is on the other end
  electrically, or the FPGA is not configured, or there is no reference clock.
  If 2.3 nonetheless *succeeds*, the link is actually up and `LnkSta` is stale:
  rescan. If 2.3 hangs too, the two agree and the fault is upstream of the
  fabric. LED 6 then separates "block never left reset" from "block is running
  but the far end never answered".
- **`Width x1` or `x2`** -- lanes 1-3 are not getting through. On a bare slot
  that is contact or solder; through the MCIO adapters it is the cable or the
  adapter's lane mapping. Not a design fault, and the link still works.
- **`Speed 2.5GT/s` or `5GT/s`** -- trained but downshifted. That is a
  signal-integrity result, not a configuration error. It costs proportional
  bandwidth and nothing else; a Gen1 x4 link still loads 4.5 GB in ~5 s.
- **Link up but nothing in `lspci`** -- the link layer is fine and config space
  is not answering. Different fault, and much rarer.

Recovery, in increasing order of disruption, all root:

```
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'

# secondary bus reset on the root port: reasserts PERST# to the card
sudo setpci -s 0000:00:1c.0 BRIDGE_CONTROL=40:40 ; sleep 1
sudo setpci -s 0000:00:1c.0 BRIDGE_CONTROL=00:40 ; sleep 1
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'
```

**Check after any secondary bus reset that the FPGA is still configured.** PERST
lands on an ordinary I/O ball (BE24) in the board file, so it should reset only
the PCIe block, but whether SQRL also strapped it to `PROG_B` in copper is not
knowable from any file we have.

### Stage 3 -- enumeration and resources

| step | isolates | fail means |
|---|---|---|
| 3.1 `lspci -Dnn \| grep -i xilinx` | config space responding | see stage 2 |
| 3.2 BARs assigned and non-zero | whether the BIOS could place the windows | Above 4G Decoding is off, or MMIO space is exhausted. This is a BIOS fix, not a card fix |

### Stage 4 -- driver

| step | isolates | fail means |
|---|---|---|
| 4.1 `sudo insmod xdma.ko poll_mode=1` | module load only | -- |
| 4.2 driver bound to the device | purely a device-ID match | `echo "<vid> <did>" \| sudo tee /sys/bus/pci/drivers/xdma/new_id`. Nothing else |
| 4.3 `/dev/xdma0_h2c_0` and `_c2h_0` exist | whether the driver found the engines *inside* the device | bound but no engines = the driver reached config space but the AXI side is not responding. Points at the bitstream or the user clock, not the link |

Poll mode first is deliberate: it takes MSI-X out of the picture, so a DMA
failure in stage 5 cannot be an interrupt misconfiguration wearing a disguise.
Switch to interrupts only after stage 6 passes.

### Stage 5 -- MMIO, before any DMA

`host/fk33ctl.py sysmon`. Isolates BAR -> AXI-Lite -> peripheral, with no DMA
engine involved at all. **This is the highest-value early check**, because it
has an independent cross-reference: the same registers were read over JTAG in
stage 2.3, and agreement between two paths that share only the silicon is much
stronger evidence than either alone.

Then `host/fk33ctl.py gpio`, which proves MMIO *writes* land -- SYSMON is
read-only and cannot show that.

### Stage 6 -- DMA

| step | isolates | pass |
|---|---|---|
| 6.1 `fk33ctl.py selftest` | descriptor path and both engines, 4 KB | round trip identical |
| 6.2 read the same address over JTAG (`pcieep.sh --check` writes the same scratch page) | whether a mismatch is in XDMA or in HBM | -- |
| 6.3 `fk33ctl.py bench --size-mb 1024` | throughput | >= 2.5 GB/s each way |
| 6.4 `fk33ctl.py load <blob> --verify` | the real thing | full read-back identical |

A 6.1 failure with 6.2 showing correct data in HBM means the fault is in XDMA or
the driver. A 6.1 failure with 6.2 showing wrong data too means the fault is in
HBM or the interconnect, and `tcl/hbmdiag.tcl` is the existing instrument.

Below 2.5 GB/s at 6.3, in order of likelihood: MPS/MRRS negotiated small (check
`DevCtl` in `lspci -vvv`), poll mode competing for CPU, chunks too small to
amortise descriptor setup.

---

## 7. Weight loading

### 7.1 The numbers

Gen3 x4 raw payload rate: `8.0 GT/s x 4 lanes x 128/130 = 3.938 GB/s` per
direction. TLP overhead at a 256-byte MPS is ~24 bytes of header, framing, LCRC
and sequence per TLP, so ~91%, less a few percent for DLLP acknowledgements and
flow control. Expect **3.2-3.5 GB/s**; ~3.0 GB/s if the root port negotiates a
128-byte MPS.

| load | at 3.3 GB/s | at 3.0 | at 2.0 (pessimistic) |
|---|---|---|---|
| 4.5 GB (9B INT4) | **1.4 s** | 1.5 s | 2.3 s |
| 7.11 GiB (this repo's own single-card envelope figure) | 2.3 s | 2.5 s | 3.8 s |
| with full read-back verification | double the above | | |

**Cold load is a non-issue.** Even verifying the whole thing byte for byte costs
under 5 s. HBM is not the constraint either: the measured HBM bandwidth on this
card is 288-353 GB/s, two orders of magnitude above the link.

Per token, the link is close to idle:

| direction | content | bytes/token | at 30 tok/s | as % of 3.3 GB/s |
|---|---|---|---|---|
| host -> card | token id + position | 8 | 240 B/s | ~0 |
| card -> host, full logits fp16 | 151,936 x 2 | 304 KB | 9.1 MB/s | 0.28% |
| card -> host, argmax or top-k on chip | ~64 | 1.9 KB/s | ~0 |

Latency, not bandwidth, is the thing to watch, and it is still comfortable. A
synchronous MMIO doorbell plus a DMA completion is ~20-40 us round trip; at 30
tok/s (33 ms per token) that is 0.1%, and it stays under 2% even at 500 tok/s.

### 7.2 The protocol sketch

```
COLD START
  1. link up at x4 Gen3, driver bound, /dev/xdma0_* present
  2. host raises VCCINT over MMIO             fk33ctl.py vccint
  3. host holds the engine in reset           MMIO write to a control register
  4. host DMAs the weight blob to HBM 0x0     one pwrite, ~1.4 s
  5. host reads it back and compares          ~1.4 s, first load only
  6. host writes the tensor manifest          a few MMIO writes: per-tensor
                                              base addresses, shapes, the KV
                                              cache base, the layer count
  7. host releases the engine reset
  8. host reads a ready flag                  MMIO poll

PER TOKEN
  9.  MMIO write   token id, position         posted, ~0.2 us
  10. MMIO write   doorbell
  11. wait         MSI-X, or MMIO poll on a done flag
  12. read result  MMIO if argmax-on-chip, DMA if full logits

KV cache never crosses PCIe.  It lives in HBM and is written by the engine.
```

The blob is prepared offline as one contiguous image in exactly the layout the
engine expects, so the FPGA never scatters and the host never issues more than
one descriptor chain. Verification uses a blake2b digest over both the source
and the read-back, which localises a corruption to a chunk rather than telling
you only that something is wrong.

### 7.3 The load-bearing assumption

**x4 is only sufficient because the weights are resident in HBM.** If they ever
had to be streamed from host memory per token, 4.5 GB at 3.3 GB/s is 1.4 s *per
token*, which is not a slow design, it is no design at all. Everything about the
host interconnect choice rests on residency, and residency in turn is what the
8 GB HBM budget is spent on. If a model configuration ever stops fitting, the
answer is more cards, never more PCIe.

For a sharded N=4 configuration the per-card blob is ~1.1 GB and loads in ~0.35 s
over its own x4 -- except through the interim MCIO setup, where two cards share
one bifurcated host port and therefore share host bandwidth. Still under 2 s for
both.

---

## 8. What the user has to do, as root, in order

Nothing in this document has been run with root, and nothing needed it. These
are the steps that do.

**Before rebooting to install the card:**

1. Run `hw/fk33/host/build_xdma_driver.sh` (no root). If it needs headers:
   `sudo apt-get install --no-install-recommends linux-headers-$(uname -r)`.
   The `--no-install-recommends` is not optional on this box -- see the
   2026-08-19 incident, where omitting it installed fifteen kernel flavours and
   took the network down.
2. Build the bitstream (`hw/fk33/pcieep_build.sh`), preferably on the BC-250.
   Vivado has OOM-killed this workstation before.

**BIOS, during the restart that installs the card:**

3. **Above 4G Decoding: Enabled.** The XDMA BARs are 64-bit prefetchable.
4. Note which slot the card goes in. `00:1c.0` is the free chipset x4 port and
   suits an x4 endpoint exactly.
5. Only if using the MCIO interim setup: set x8/x8 (or x4/x4) bifurcation on
   PCIEX16. Not needed for a direct slot install.
6. Leave spread spectrum alone. SSC matters for Aurora, not for the host link.

**Physical:**

7. Connect a **6-pin PCIe aux power lead** to the card. It does not run on slot
   power. If using the MCIO device adapters, check their power connector against
   the vendor warning first -- the wrong connector destroys both adapter and
   card.

**After boot, in this order:**

8. `hw/fk33/pcieep.sh` -- JTAG, no root beyond what the existing scripts already
   need (the FTDI node is world-writable and `jtag.sh` resets it without root).
9. `sudo sh -c 'echo 1 > /sys/bus/pci/rescan'`
10. `hw/fk33/host/fk33_pcie_check.sh` (run some stages with `sudo` for the full
    capability dump; it says which).
11. `sudo insmod .../xdma.ko poll_mode=1`
12. If no `/dev/xdma0_*`:
    `echo "<vid> <did>" | sudo tee /sys/bus/pci/drivers/xdma/new_id`
13. udev rule so the char devices are usable without root:
    ```
    sudo tee /etc/udev/rules.d/60-xdma.rules >/dev/null <<'RULE'
    KERNEL=="xdma*", MODE="0666"
    RULE
    sudo udevadm control --reload && sudo udevadm trigger
    ```
14. Only after the whole path works: `sudo rmmod xdma && sudo insmod .../xdma.ko`
    (interrupts), then `sudo make install && sudo depmod -a` to persist.

**Do not run steps 11-14 from a code-server terminal.** A session teardown kills
the module load mid-flight; that is exactly how the 2026-08-19 driver install
ended up half-configured. Use `claude-tmux` or `systemd-run --unit`.

---

## 9. Risks, ranked, and what retires each

### 1. The link does not train, and we cannot tell why

The single go/no-go. No FK33 here has ever linked; the vendor is defunct; there
is no schematic; the card is second-hand mining hardware of unknown history; and
SQRL's own files contradict each other about how many lanes are even routed.
Every diagnostic downstream of the link is dead while the link is dead.

*Retired by:* LED 6 (`user_lnk_up`, no host needed) plus the root port's
`LnkSta` (reports link state even when nothing enumerates) plus the JTAG
AXI-Lite read (conclusive when it succeeds). Those three together separate "no
reference clock" from "block never left reset" from "trained but nothing
enumerated". Building all three in was the main reason the bitstream is not just
`EnablePCIe 1`.

*What we cannot do anything about in advance:* if the fingers or the refclk
trace are damaged, the answer is a different card.

### 2. Configuration timing, and the flash that has never been written

PCIe allows ~100 ms from PERST# deassertion to the first configuration request.
JTAG configuration takes tens of seconds, so a JTAG-only card cannot be present
at boot. The proper fix is the on-board `mt25qu256` SPI flash, which SQRL's XDC
is already set up for (`CONFIG_MODE SPIx4`, `CONFIGRATE 127.5`, and the
`create_hw_cfgmem` block sitting commented out in three build scripts). **It has
never been written, and its current contents are unknown.**

*Retired by:* JTAG-configure with the host already up, then
`echo 1 > /sys/bus/pci/rescan`. This is the standard FPGA development flow and
needs no flash write at all. Only if the root port refuses to enumerate a device
that appeared after boot does the flash become necessary.

*The residual risk is real:* writing the flash is the one irreversible step in
this whole plan, and a bad write to the only boot device on a card with no
vendor is how you turn a working card into a paperweight. Do not do it until the
JTAG-plus-rescan path has been tried and the bitstream is known good.

### 3. VCCINT volatility

0.678 V at every power-on against a 0.698 V floor, and the only pre-link fix is
JTAG with a *different* bitstream. This is not a bring-up hurdle that goes away;
it is a permanent operational property of the card. "Install it and it works" is
not achievable until the link is shown to train at 0.678 V, at which point
`fk33ctl.py vccint` can raise it from the host on every boot.

*Retired by:* the probe -> VCCINT -> endpoint order in `pcieep.sh` for JTAG
bring-up, immediately. For the flash-boot future, by measuring whether the link
trains at 0.678 V -- which stage 2 of the checklist answers as a side effect,
since the first link attempt happens before the host can raise anything.

### 4. Only 8 lanes may actually be routed

`board.xml` names the edge component `pcie_8lane_edge` while `part0_pins.xml`
lists 16 lanes and `sqrl_fk33.xdc` constrains 16. Two vendor files, one board,
different answers.

**This does not threaten the x4 host link** -- lanes 0-3 are the lowest under
either reading. It threatens the 12-lane Aurora plan, which is a different
subsystem on a different timeline.

*Retired by:* building an x8 or x16 variant later and reading the trained width,
or continuity-testing the fingers with the card out.

### 5. `dma_ip_drivers` does not build on 6.8

*Retired by:* `build_xdma_driver.sh`, runnable **today**, before the card goes
in. This is the one risk on the list that can be fully eliminated in advance.

### 6. Device ID mismatch, so the driver never binds

Cheap and fully diagnosed: the driver loads, nothing appears in `/dev`.
*Retired by:* `new_id`, one command. Removing SQRL's `1E24:1533` override in the
bitstream is a belt-and-braces measure for the same thing.

### 7. BAR allocation fails

*Retired by:* Above 4G Decoding in BIOS, set during the same restart that
installs the card so it costs no extra reboot.

### 8. Thermal

~155 W (claimed, never measured) into a chassis already holding a 3090 Ti and a
3090. SYSMON die temperature is readable over both JTAG and MMIO, and
`fk33ctl.py sysmon` flags implausible values.

*Retired by:* watching it during the first sustained DMA benchmark, which is
also the first time the card does real work in this chassis.

### 9. A secondary bus reset deconfigures the FPGA

If SQRL strapped PERST to `PROG_B` in copper, the standard recovery for a
non-enumerating device also wipes the bitstream.

*Retired by:* re-reading the device over JTAG after the first time a secondary
bus reset is used. One observation settles it permanently.

---

## 10. Unknown until the card is in the slot

Required section, and the honest one. None of these can be established from
here, and each is followed by the measurement that settles it.

| unknown | measurement |
|---|---|
| Whether an FK33 enumerates on PCIe **at all** | stage 2 of the checklist. This is the whole point |
| Whether the PCIe edge fingers, refclk (AD8/AD9) and PERST (BE24) are wired as the board file claims | a trained link proves all three at once; a failure does not tell you which |
| Whether the link trains at the power-on 0.678 V | the first link attempt happens before anything can raise VCCINT, so stage 2 answers it as a side effect |
| Whether the 100 MHz refclk comes from the slot or from an on-board oscillator | `board.xml` names it `pcie_8lane_edge` (edge) while naming the 200 MHz sysclk a real SiTime part, which is evidence for "from the slot" but is a label, not a schematic. Settled by whether the endpoint bitstream shows any life on the bench with no slot |
| Whether the root port will enumerate a device that appeared after boot | `echo 1 > /sys/bus/pci/rescan`. If it will not, the flash write becomes mandatory |
| Whether PERST is also strapped to `PROG_B` | JTAG re-read after the first secondary bus reset |
| What is currently in the SPI flash | `create_hw_cfgmem` + a read-back, over JTAG, before ever writing it |
| The real achievable DMA throughput | `fk33ctl.py bench`. Every load-time number in section 7 is arithmetic on a link rate, not a measurement |
| Negotiated MPS and MRRS | `lspci -vvv`, `DevCtl` line. This is what moves 3.5 GB/s to 3.0 |
| Whether the x4 link lands in quad 227 as intended | the placed GT sites in the utilization report, which `pcieep_build.sh` greps for. Verified from the package file that it *should*; not verified that Vivado *will* |
| Card slot-rail current draw | still open from the interconnect work, and still needs a real measurement, not SYSMON |
| The die's actual speed grade | still unknown, and **not** obtainable from the IDCODE, contrary to what `build_fk33_firstlight.tcl`'s header suggests. The IDCODE gives die identity; speed grade is a binning result and is only on the package top-mark, under the heatsink |

## 11. Corrections to earlier documents

- `hw/fk33/build_fk33_firstlight.tcl` header note 3 says the speed grade can be
  settled from the IDCODE via the hardware manager. It cannot;
  `docs/debugging/2026-08-24_fk33-sysmon-vccint-undervolt.md` establishes that
  speed grade is not encoded there. The `-2L` choice remains correct as the
  conservative direction, but it will not be confirmed by connecting a cable.
- `pcie-llm-hardware/docs/00-rationale.md` says the x1/x2/x4 quad argument rests
  on the hard block claiming a whole quad. That is probably true but is not the
  strongest form of the argument, and it is not the form I could verify from
  here. The physical wiring argument in section 1.2(a) reaches the same
  conclusion without needing it.
