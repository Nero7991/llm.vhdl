# FK33 first fit: the endpoint cannot enumerate from a JTAG configure, and why

**Date:** 2026-08-28. First day an FK33 was ever fitted to a host.
**Written by:** the `llama-fk33-runtime` session, for this repository to act on.
**Hardware:** SQRL FK33, `xcvu33p-fsvh2104-2L-e` (ES1 die), fitted to a Gigabyte
Z790 AERO G, BIOS F12, kernel 6.8.0-138-generic.
**Bitstream under test:** `hw/fk33/bit/fk33_pcieep.bit`, 12,227,950 bytes,
built 2026-08-27 22:58:46.

**Status: no FK33 has still ever enumerated.** Nothing below establishes that
the endpoint bitstream trains a link. It establishes that it has never been
given the chance.

---

## 0. The answer, up front

**A JTAG-configured FK33 can never enumerate on this host, by construction, and
no choice of slot changes that.** The reason is already written in
`hw/fk33/fk33_pcieep.xdc`:

```tcl
set_property BITSTREAM.CONFIG.CONFIGRATE 127.5 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
# CONFIGRATE 127.5 and CONFIG_MODE SPIx4 are inherited from upstream and are
# there so a flash-booted FPGA is configured inside the ~100 ms PCIe gives it
# after PERST# deasserts.  They are irrelevant while configuring over JTAG.
```

The ~100 ms between PERST# deassertion and the host expecting a trained link is
a PCIe requirement. JTAG configuration cannot meet it: by the time `pcieep.sh`
finishes, the host has already given up, **disabled the root port**, and is
holding PERST# asserted, which keeps the FPGA's PCIe block in reset forever.

**The ask: put the bitstream in SPI flash.** Upstream's own recipe is already in
this repo, commented out at `hw/fk33/build_fk33_pcieep.tcl:677-683`, and it
names the part.

---

## 1. Evidence that the PCIe block never leaves reset

This replaces the LED 6 reading that
`docs/2026-08-27_fk33-pcie-bringup-procedure.md` calls for. **The same
information is available over JTAG, with no physical access**, which is worth
folding back into the procedure.

The bitstream IS resident. Both JTAG-AXI masters enumerate and match
`bit/fk33_pcieep.ltx` exactly, and SYSMON answers through the JTAG DRP, which
needs no design clock:

```
AXI_MASTERS hw_axi_1 hw_axi_2
SYSMON via get_hw_sysmons:  TEMP=38.6  VCCINT=0.718
```

Every AXI-Lite transaction nevertheless fails:

```
SYSMON_RAW t=0x-1 v=0x-1        # reads of 0x3400 / 0x3404 through jtag_axil
ID         magic=0x-1 build=0x-1 # reads of 0xA000 / 0xA008
```

`hw/fk33/tcl/pcieep_jtag.tcl`'s own header gives the reading: the entire AXI
fabric is clocked by `xdma/axi_aclk` and reset by `xdma/axi_aresetn`, both
derived from the PCIe reference clock and released only once the link is up.

The debug hub answering while the AXI fabric does not is itself informative:
the hub is on a separate free-running clock, per the XDC's
`connect_debug_port dbg_hub/clk [get_nets bd_i/hbm/inst/TWO_STACK.u_hbm_top/APB_0_PCLK]`.
So JTAG works, the design is genuinely loaded, and the PCIe user clock is dead.

## 2. Host-side evidence for the port being disabled

The card was fitted to `0000:00:1c.4`, the PCH Gen4 x4 port that had held an
RTX 3090. Baseline taken before the fit, by `host/fk33_go.sh --baseline`:

```
BRIDGE 0000:00:1c.4 16.0GT/sPCIe 4 2.5GT/sPCIe 4 6 2
```

After the fit, with the card powered and seated, that bridge is **absent from
config space entirely** -- not merely at width 0. The BIOS hides a PCH root
port that saw nothing at POST. Since it hid the port with a card physically
present, it decides on link training, not on presence pins.

A rescan cannot help and should not be suggested: there is no bridge to scan
behind. `fk33_go.sh` stage D prints
`sudo sh -c 'echo 1 > /sys/bus/pci/rescan'` as its remedy, which is correct for
a card on a visible port and useless here.

**The warm-reboot workaround was tried and does not work.** The card was
JTAG-configured, then the host was warm-rebooted with power maintained. The
FPGA was demonstrably still configured across that POST, and the BIOS still
presented no bridge. Proof that power was maintained: the VCCINT digital-pot
wiper is volatile and resets to 128 on a power cycle, and it read 64 afterwards.

That wiper is a **latch recording whether power was interrupted**, and it is the
single most useful probe found in this whole exercise. Worth documenting in the
procedure. Measured values:

```
after a warm reboot:  START wiper=64   VCCINT=0.7203 V
after a power cycle:  START wiper=128  VCCINT=0.6786 V
```

## 3. Eliminated on inspection -- do not re-investigate

- **CLKREQ# not asserted.** `gen_pcieep.py` item 4 explicitly overrides
  upstream's `xlconstant` default of 1 and drives it LOW, and the pin is
  constrained (`PACKAGE_PIN BE25`, LVCMOS18). Worth having checked, because
  Intel PCH root ports really do gate SRC clocks on CLKREQ#, but it is correct.
- **Unconstrained refclk or PERST.** Both present and verified against Vivado's
  package file: `AD9/AD8 = MGTREFCLK0P/N_226`, `pcie_perstn = BE24`.
- **Lane reversal.** The XDC notes lane order is reversed inside quad 227,
  normal for a card edge, and PCIe negotiates lane reversal during training.
- **A different slot.** Tried, and it cost a power cycle for nothing. See
  section 5.
- **BIOS settings.** Z790 AERO G F12 exposes no port-hiding or per-root-port
  enable option. Above 4G Decoding is already Enabled and greyed out.

## 4. The task

`hw/fk33/build_fk33_pcieep.tcl:677-683` already carries it, commented out:

```tcl
#create_hw_cfgmem -hw_device [lindex [get_hw_devices xcvu33p_0] 0] \
#    [lindex [get_cfgmem_parts {mt25qu256-spi-x1_x2_x4}] 0]
#set_property PROGRAM.BLANK_CHECK 0 ...
#set_property PROGRAM.ERASE 1 ...
#set_property PROGRAM.CFG_PROGRAM 1 ...
#set_property PROGRAM.VERIFY 1 ...
```

Micron MT25QU256, 32 MB, against a 12,227,950-byte bitstream. Steps:
`write_cfgmem` to an `.mcs`, `create_hw_cfgmem` plus `program_hw_cfgmem` over
JTAG, power cycle, and the FPGA should configure inside the PCIe window.

**Obstacle 1, the ES1 revision check.** `hw/fk33/tcl/program.tcl` records that
Vivado's `program_hw_devices` refuses this die outright:

> target device (with IDCODE revision 0) is compatible with es1 revision
> bitstreams

with no way to waive it, which is why configuration goes through
`xsdb -no-revision-check`. Flash programming loads a programmer bitstream into
the FPGA through that same Vivado path, so it may hit the same check. Untested.
If it does, the fallback is to load the flash programmer manually via xsdb, or
to drive the QSPI from a design of our own over `jtag_axil`.

**Obstacle 2, VCCINT at boot.** A flash-booted design configures with VCCINT at
0.678 V, below the 0.698 V floor for the -2L grade, and must train the link in
that state. `host/fk33ctl.py vccint` exists to raise it over MMIO once the link
is up, so the intended sequence is already anticipated -- but whether an ES1 die
trains reliably while undervolted is not known. If it does not, the ordering
problem becomes genuinely hard, because the pot needs the probe bitstream's
GPIO and the probe bitstream has no PCIe.

## 5. Measurement traps hit, including our own

- **`host/fk33_go.sh` mis-diagnoses a card SWAPPED into an occupied slot.** It
  looks for a port that was EMPTY in the baseline and became occupied, which is
  right for adding a card to a free slot and wrong here. It therefore guessed
  root port `00:1c.0` and measured the wrong port in stages B, C and D, then
  reported "no root port appeared or changed state since the baseline ...
  points at power or seating, not at the bitstream. Check the 6-pin aux lead
  and reseat" -- after its own stage A had already passed on card power. Worth
  fixing: diff every bridge against the baseline, including ports that
  DISAPPEARED, and say so explicitly.
- **`hw/fk33/tcl/pcieep_jtag.tcl` aborts before doing any work.** It fails on
  `get_property REGISTER.IDCODE [current_hw_device]` with
  `ERROR: [Labtoolstcl 44-56] hw_device [xcvu33p_0] does not have a
  [REGISTER.IDCODE] property`, so stage 3 never runs its AXI reads. Dropping
  that line, and using `refresh_hw_device -update_hw_probes false`, makes the
  whole script work. That is how the section 1 evidence was obtained.
- **`hw/fk33/tcl/vccint_verify.tcl` cannot verify VCCINT under the endpoint
  bitstream.** It reaches SYSMON through JTAG-AXI, which is dead until the link
  is up, and fails with 28 x `No matching hw_axi_txns were found` -- which reads
  like a card fault and is not one. `get_hw_sysmons` reaches SYSMON through the
  JTAG DRP instead and works regardless of the link. Consider switching it.
- **A failed AXI transaction reports as `-1`, not as an error.** Any script
  that string-compares the result will conclude "the AXI path answered with the
  wrong value" when in fact it never answered. Check for `-1` explicitly.
- **Ours: we recommended moving the card to `0000:00:1c.0`** on the strength of
  a comment in `host/fk33_pcie_check.sh` describing it as the only free port.
  It is not a card slot. `sudo lspci -vv -s 00:1c.0` gives
  `SltCap: HotPlug+ Surprise+ PwrCtrl- MRL-` and, with the card supposedly in
  it, `SltSta: PresDet-`; at Gen3 x1 with hotplug and no power controller it is
  almost certainly the M.2 Key-E Wi-Fi socket. The table in
  `host/fk33_pcie_check.sh` should not be trusted on which port is which
  physical connector.
- **`sudo dmidecode -t slot` is NOT authoritative on this board, and we
  initially said it was.** Measured 2026-08-28, the SMBIOS type 9 table is
  Intel reference-board boilerplate that Gigabyte never customised. Its
  designations are `J6B2/J6B1/J6D1/J7B1/J8B4` rather than Gigabyte's silkscreen
  (`PCIEX16` and friends); it describes `00:1c.4` as "x1 PCI Express, Short"
  when the baseline recorded that port at `16.0GT/s x4` holding an RTX 3090;
  and it reports `Current Usage: In Use` for `1c.3`, `1c.5` and `1c.6`, none of
  which appear in `lspci` at all. Widths, lengths and usage are all unusable.

  Two signals in it do survive, and both are negative results worth having:
  `0000:00:1c.0` does **not** appear in the slot table at all, which
  independently supports the M.2 reading above; and `0000:00:1c.4` does appear,
  so firmware does regard that one as a card slot. The table also incidentally
  demonstrates the hiding behaviour, listing `1c.3/1c.5/1c.6` as slots while
  config space shows nothing.

  **There is still no established mapping from root port to physical
  connector on this machine.** If one is needed, it has to come from the board
  manual or from moving a known-good card and diffing `lspci`.

## 6. Open, not yet answered

- Whether `program_hw_cfgmem` clears the ES1 revision check.
- Whether the link trains at 0.678 V on an ES1 die.
- Which physical connector each root port is. `dmidecode` cannot answer it on
  this board (section 5); it needs the board manual or a known-good card moved
  slot to slot with `lspci` diffed each time.
- Whether the endpoint bitstream trains a link at all, given the chance. Every
  failure so far is explained by the host side never offering one.
- Whether this x4 endpoint downtrains to x1, if a narrow slot is ever used.

## 7. Reproducing the section 1 measurement

From `hw/fk33`, with the card powered and JTAG attached:

```sh
./pcieep.sh            # probe bitstream, VCCINT step, endpoint bitstream
```

then a Tcl through `./jtag.sh` that opens the target, does
`refresh_hw_device -quiet -update_hw_probes false`, and reads `0xA000` through
`[lindex [get_hw_axis] 1]`. Expect `-1` while the link is down, and
`464B3333` once it is up. `get_hw_sysmons` works either way and is the correct
way to read VCCINT under the endpoint bitstream.

Full host-side narrative, with the wrong turns kept:
`~/GitHub/llama-fk33-runtime/docs/debugging/2026-08-28_fk33-hidden-root-port-deadlock.md`

---

## 8. CORRECTION, appended 2026-08-28

**The claim in sections 0 and 1 that the ILA debug hub sits on "a separate
free-running clock" is WITHDRAWN.** It was inferred from the XDC line

```tcl
connect_debug_port dbg_hub/clk [get_nets bd_i/hbm/inst/TWO_STACK.u_hbm_top/APB_0_PCLK]
```

An XDC line names a net; it does not say what drives it. In
`build_fk33_i2cprobe.tcl`, `hbm/APB_0_PCLK` is `clk_wiz_0/clk_out1`, and inside
the `EnablePCIe == 1` branch `clk_wiz_0/clk_in1` is `xdma/axi_aclk` and
`clk_wiz_0/resetn` is `xdma/axi_aresetn`. So under the endpoint bitstream the
hub's clock is an MMCM output referenced to the PCIe user clock, with the MMCM
held in reset by the PCIe reset. **There was no free-running clock anywhere in
`fk33_pcieep`.** The `EnablePCIe == 0` branch feeds the same `clk_wiz_0` from
the board oscillator instead, which is why the probe bitstream behaves
differently on the bench and why the two cases were easy to conflate.

Two consequences for anything already written on top of this document:

1. `AXI_MASTERS hw_axi_1 hw_axi_2` in section 1 is NOT proof that the debug hub
   answered. It is consistent with that and also consistent with Vivado having
   created those objects while nothing behind them responded. It could not be
   separated without the card.
2. Section 3's list of things eliminated on inspection is unaffected. Nothing
   in it depended on the hub claim.

**The fix, and where it lives:** the FK33's 200 MHz oscillator on BC26/BC27
(`sysref_clk`) IS free-running with no host -- every `EnablePCIe == 0` bitstream
in this repository runs from nothing else -- and the endpoint build simply never
connected it. As of 2026-08-28 `fk33_pcieep` carries an aux domain on that
oscillator: status registers readable over a third JTAG-AXI master with the link
down, the debug hub moved onto it, and an autonomous VCCINT controller that
dissolves Obstacle 2 in section 4. Full write-up, including the configuration
time arithmetic section 4 asks about:
`docs/debugging/2026-08-28_fk33-free-running-observability.md`.
