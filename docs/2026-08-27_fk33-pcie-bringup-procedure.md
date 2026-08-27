# FK33 PCIe bring-up procedure: what to check, in order, when it does not enumerate

**Date:** 2026-08-27
**Hardware:** SQRL FK33, XCVU33P (`xcvu33p-fsvh2104-2L-e`, ES1 die), 8 GB HBM,
on `Oren-Dell-Ubuntu` (Z790, kernel 6.8.0-138-generic)
**Bitstream:** `fk33_pcieep`, PCIe Gen3 x4 XDMA endpoint, GTY quad 227
**Status when this was written:** no FK33 has ever enumerated on PCIe. Every
result in this project so far went over JTAG.

This is the operational companion to `docs/2026-08-27_pcie-host-bringup-plan.md`,
which is the design reasoning. Read that for *why*; read this for *what to do*.

---

## What is verified today, and what is only written

Verified means a tool ran and produced the output quoted.

| claim | status | how |
|---|---|---|
| every PACKAGE_PIN in `fk33_pcieep.xdc` exists on `xcvu33p-fsvh2104` | **verified** | `check_pcieep_xdc.py`, 29 of 29 live constraints parsed against Vivado's own package file |
| all 16 PCIe lane pins are GTY quad 227, refclk is `MGTREFCLK0_226` | **verified** | same, per-pin table printed |
| the XDMA IP is really x4 / Gen3 / 128-bit / 1 channel each way | **verified** | parameters read back out of the IP after configuration, `FK33_CFG` lines |
| the device ID a driver must match | **verified: `10EE:9034`** | `FK33_PCIE_IDS`, and it is an ID `dma_ip_drivers` already carries |
| LED 6 follows `user_lnk_up` | **verified** | `FK33_LNKLED OK` |
| the address map is what the host program expects | **verified** | `validate_bd_design` plus the smartconnect routing tables, both quoted in the debugging note |
| the three bring-up peripherals synthesise on this part | **verified** | OOC synthesis: 721 LUTs and 1273 FFs for all three together |
| `fk33_bringup` finds a good card, and finds each fault | **verified** | `selftest_nocard.sh` runs the program against seeded files and against four deliberately corrupted ones |
| the design meets timing at 250 MHz | **NOT verified** | needs implementation, which has not been run |
| the x4 link is *placed* in quad 227 | **NOT verified** | placement is an implementation result |
| anything at all about the card | **NOT verified** | no FK33 has ever enumerated |

**The full build has not been run.** Command and cost:

```bash
cd hw/fk33 && ./pcieep_build.sh
```

Roughly **1 to 1.5 hours** wall clock and **12 to 20 GB peak RSS** during
placement and routing of a design containing the HBM controller, XDMA and 32
HBM address segments. For calibration, the block-design stage alone measured
**3.35 GB peak in about 3 minutes**, and that stage is the cheapest part by a
wide margin.

**Do not run it on a loaded workstation.** This box has 32 GB and systemd-oomd
has killed the entire code-server cgroup during a Vivado run before. Either run
it on the BC-250 (measured 2.2 to 2.35x slower, so budget 2.5 to 3.5 h, and the
VU33P licence there is `~/.Xilinx/Xilinx-4.lic`, valid to 25-oct-2026), or run
it locally under `claude-tmux --mem 20G` with nothing else running.

The cheap gate to run after any edit, which catches everything except timing
and placement:

```bash
cd hw/fk33 && ./pcieep_build.sh --bd-only     # ~3 min, ~3.4 GB
```

---

## The single most important idea

**A card that does not appear on the bus gives you almost no feedback.** There
is no console, no log, no error code. The failure looks identical whether the
FPGA never configured, the reference clock is absent, the link failed to train,
the BAR was never placed, or the driver simply did not bind.

So the whole procedure is built around **four independent observation points**,
chosen because each one is alive under a different subset of failures:

| observer | needs | still works when |
|---|---|---|
| **LED 6** on the card (`user_lnk_up`) | nothing at all | there is no host, no driver, no JTAG |
| **root port `LnkSta`** (`lspci -vvv` on the *bridge*) | host only | the endpoint never enumerates |
| **JTAG AXI-Lite read** | JTAG cable | the host has never seen the card |
| **identity register** `0x464B3333` at BAR offset `0xA000` | the whole path | nothing -- it is the last thing to work |

Any one of them alone is ambiguous. Read together they separate the failures.
That is the entire reason LED 6 was rewired and the identity register exists.

---

## Telling the three big failure classes apart

This is the question the procedure has to answer first, because the remedies
have nothing in common.

### A. NOT ENUMERATED

`lspci -Dnn | grep -i xilinx` is empty.

**Distinguishing evidence:** look at the *root port*, not the device:

```bash
sudo lspci -vvv -s 0000:00:1c.0 | grep -E 'LnkCap|LnkSta'
```

- `LnkSta: ... Width x0` -- the physical layer never trained. Nothing
  electrically present, or the FPGA is not configured, or there is no reference
  clock. **LED 6 then separates them:** if LED 6 has *changed state* relative
  to its unconfigured appearance, the PCIe block left reset and is running, so
  the fault is on the wire or at the far end; if LED 6 has not changed, the
  block never came out of reset, which means no reference clock or no
  configuration.
- `LnkSta: Width x4, Speed 8GT/s` but nothing in `lspci` for the device --
  the link layer is up and **config space is not answering**. This is a rarer
  and quite different fault. Rescan first; if that does not help, the endpoint
  is trained but its configuration space logic is wedged.
- `Width x1` or `x2` -- lanes are dropping out. Contact, solder, or (through
  MCIO) cable and adapter lane mapping. **Not a design fault; the link works.**
- `Speed 2.5GT/s` or `5GT/s` -- trained but downshifted. Signal integrity, not
  configuration. Costs proportional bandwidth and nothing else.

### B. ENUMERATED BUT BAR UNMAPPED

`lspci` shows the device; `lspci -v` shows a Region line with no address, or
`[virtual]`, or `[disabled]`.

```bash
sudo lspci -v -s <bdf> | grep -A1 Region
```

Healthy looks like `Memory at 6000000000 (64-bit, prefetchable) [size=128K]`.
Broken looks like `Memory at <unassigned> (64-bit, prefetchable) [size=128K]`.

**This is a BIOS/resource problem, not a card problem.** The XDMA BARs are
64-bit prefetchable, so the fix is **Above 4G Decoding: Enabled**. The second
cause is MMIO space exhaustion with two GPUs already in the machine.

Symptom seen from `fk33_bringup`: **stage 1 fails with an EIO on the read**, or
stage 0 fails because the driver refused to probe a device with no resources.

### C. BAR MAPPED BUT DMA DEAD

`fk33_bringup` **passes stage 1 and 2** and fails at stage 4.

This is the good failure, because everything upstream is proven: the link is
up, config space answers, the BAR is placed, the AXI fabric is clocked and out
of reset, and MMIO reads *and writes* both work. What is left is the DMA
engines, their descriptors, or the path from `xdma/M_AXI` through `pcie2hbm`.

Distinguish further:

- **Stage 4 fails but stage 5 (HBM) also fails identically** -- the fault is in
  XDMA or its descriptor handling, not in the memory. The BRAM at
  `0x2_0000_0000` and HBM share only `xdma/M_AXI` and the smartconnect.
- **Stage 4 passes and stage 5 fails** -- the DMA path is fine and HBM is not.
  `tcl/hbmdiag.tcl` is the existing instrument.
- **Both engines report short transfers rather than wrong data** -- descriptor
  stall, not a data fault. `dmesg | grep xdma`.
- **Full-length transfers with wrong data** -- read the same address back over
  JTAG (`./pcieep.sh --check`). That is what separates "XDMA wrote the wrong
  bytes" from "the read-back path is wrong". They are different bugs and the
  host cannot tell them apart alone.

---

## The ordered checklist

Cheapest and most diagnostic first. Each step says what it isolates, because a
step that isolates nothing is a step you will run twice.

### Stage 0 -- before the card goes in. No card needed.

| # | command | pass | fail means |
|---|---|---|---|
| 0.1 | `hw/fk33/host/build_xdma_driver.sh` | `xdma.ko` exists, `modinfo` vermagic starts `6.8.0-138-generic` | `dma_ip_drivers` has not caught up with this kernel. **Already done: 2025.2.0 built.** |
| 0.2 | `cd hw/fk33/host && make check && ./selftest_nocard.sh` | `FK33_HOST_SELFTEST OK` | the test program itself is wrong. Fix before blaming hardware. |
| 0.3 | `python3 hw/fk33/check_pcieep_xdc.py` | `FK33_XDC_CHECK OK`, 16 lane pins all `_227` | a constraint names a pin that does not exist, or a lane escaped quad 227 |
| 0.4 | `hw/fk33/pcieep_build.sh` | `FK33_BITSTREAM` line present | see 0.5 |
| 0.5 | read the build log | `FK33_PCIE_IDS` shows a `10ee:xxxx`; `FK33_LNKLED OK`; `GTYE4_CHANNEL: 4 used`; zero `12-584` warnings | **4 channels, not 4, means the width did not take.** Any `12-584` means a port name moved. |
| 0.6 | BIOS list written down before rebooting | -- | Above 4G Decoding must be **Enabled** |

### Stage 1 -- power and configuration. Card in, host booted.

| # | check | isolates | fail means |
|---|---|---|---|
| 1.1 | look at the card: fan spinning, LEDs lit | power delivery | **the 6-pin aux lead is not connected.** The card does NOT run on slot power. This is the single most likely first-day fault. |
| 1.2 | `lsusb \| grep 0403:6010` | the FTDI JTAG bridge, hence housekeeping power | as 1.1 |
| 1.3 | `hw/fk33/pcieep.sh` | the whole JTAG configuration path plus VCCINT | `FPGA_PROG_OK` twice and `SETTLED wiper=... VCCINT=0.71x V` expected. A programming failure is the ES1 revision check, and the fix is already in `tcl/program.tcl` (xsdb with `-no-revision-check`), not Vivado. |

**Note the order.** VCCINT powers up at 0.678 V, below the 0.698 V floor of
every characterised speed grade, and the fix is a **volatile** digital-pot
wiper. The pot is only reachable from the *probe* bitstream's GPIO, and in the
endpoint bitstream the JTAG-AXI masters are themselves clocked by the PCIe user
clock and dead until the link is up. So it must be probe -> VCCINT -> endpoint,
never the reverse. `pcieep.sh` enforces this.

### Stage 2 -- link training. The go/no-go.

| # | check | reads |
|---|---|---|
| 2.1 | LED 6 (RGB blue) on the card | `user_lnk_up`, with no host and no instrument. Polarity is undocumented: take the **change** as the signal, not the direction. |
| 2.2 | `sudo lspci -vvv -s 0000:00:1c.0 \| grep LnkSta` | the root port's view. **Reports link state even when nothing enumerates.** |
| 2.3 | `hw/fk33/pcieep.sh --check` | the AXI fabric downstream of the PCIe user clock, over JTAG |

Reading them together is the whole point -- see "Telling the three big failure
classes apart" above.

Recovery, in increasing order of disruption, all as root:

```bash
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'

# secondary bus reset on the root port: reasserts PERST# to the card
sudo setpci -s 0000:00:1c.0 BRIDGE_CONTROL=40:40 ; sleep 1
sudo setpci -s 0000:00:1c.0 BRIDGE_CONTROL=00:40 ; sleep 1
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'
```

**After any secondary bus reset, check the FPGA is still configured.** PERST
lands on an ordinary I/O ball (BE24) in the board file, so it should reset only
the PCIe block, but whether SQRL also strapped it to `PROG_B` in copper is not
knowable from any file we have. One JTAG re-read settles it permanently.

### Stage 3 -- enumeration and resources

```bash
lspci -Dnn | grep -i xilinx
sudo lspci -v -s <bdf> | grep -A2 Region
```

Both BARs must show real, non-zero addresses. See failure class B above.

### Stage 4 -- driver

```bash
sudo insmod .../xdma.ko poll_mode=1
ls -l /dev/xdma0_*
```

**Poll mode first, deliberately.** It removes MSI-X from the picture entirely,
so a DMA failure at stage 6 cannot be an interrupt misconfiguration wearing a
disguise. Switch to interrupts only after the whole path passes.

- Module loads but no `/dev/xdma0_*` and nothing bound: purely a device-ID
  match. `echo "<vid> <did>" | sudo tee /sys/bus/pci/drivers/xdma/new_id`.
- Bound but **no engines**: the driver reached config space and the AXI side is
  not responding. Points at the bitstream or the user clock, not the link.

Do **not** run the module load from a code-server terminal: a session teardown
kills it mid-flight. Use `claude-tmux` or `systemd-run --unit`.

### Stage 5 -- one command

```bash
cd hw/fk33/host && make && ./fk33_bringup
```

This runs stages 0-4 of its own numbering: device nodes, identity, scratch
read/write, SYSMON, and the DMA round trip through the on-chip BRAM. It touches
no HBM, so it is safe to re-run at any time.

Then, when that passes:

```bash
./fk33_bringup --hbm            # adds a 1 MB round trip into real HBM
./fk33_bringup --bench 1024     # throughput, written to the TOP of HBM
```

The **identity register is the load-bearing check**. `0x464B3333` is ASCII
"FK33", driven from a fabric constant into a read-only `axi_gpio`. It cannot be
produced by a driver that merely loaded, by a BAR that is mapped but
unanswered (which returns `0xFFFFFFFF`), or by a fabric held in reset (which
returns `0x00000000`). A correct read of it proves, in one access: the link
trained, config space answered, the BIOS placed the BAR, the AXI-Lite master is
clocked and out of reset, the smartconnect decodes, and the FPGA holds *this*
bitstream and not an older one.

The scratch BRAM at `0x10000` is what proves MMIO **writes** land, which SYSMON
(read-only) and the identity register (read-only by construction) cannot. Its
walking-ones pass catches a stuck data bit; its address-in-word pass catches a
stuck or swapped **address** bit, which a single `0xDEADBEEF` write cannot see.

---

## Cross-checks that are worth more than either half

Two independent paths agreeing is much stronger evidence than either alone.
Three exist here and all three are cheap:

1. **SYSMON over MMIO vs SYSMON over JTAG.** `fk33_bringup` stage 3 and
   `tcl/telemetry.tcl` read the same registers through paths that share only
   the silicon. Agreement rules out an addressing error in either.
2. **DMA BRAM over PCIe vs over JTAG.** `fk33_dmabram` is deliberately left
   visible to `jtag_hbm` as well as to `xdma/M_AXI`, so the same 64 KB can be
   read both ways. This is the only way to tell "XDMA wrote the wrong bytes"
   from "the read-back is wrong".
3. **Identity register vs `lspci` subsystem ID.** `1E24:0001` in `lspci -nn`
   says the *board* is an FK33; `0x464B3333` at BAR `0xA000` says the *fabric*
   holds this design. A card can satisfy one and not the other, and which one
   fails tells you whether to reconfigure or to reseat.

---

## Address map, for reference

```
AXI-Lite BAR, 128 KB  --  /dev/xdma0_user, offset == BAR offset
  0x00003400  SYSMON die temperature   raw * 507.6/65536 - 279.43   degC
  0x00003404  SYSMON VCCINT            raw * 3.0/65536              V
  0x00009000  GPIO ch1 DATA   bit0 = SCL (BB24), bit1 = SDA (BA24)
  0x00009004  GPIO ch1 TRI    1 = released, 0 = driven low.  Resets all-ones.
  0x00009008  GPIO ch2 DATA   the 7 board LEDs, through led_inv
  0x0000A000  ID magic        READ-ONLY, always 0x464B3333 ("FK33")
  0x0000A008  ID build date   READ-ONLY, 0x20260827 (BCD yyyymmdd)
  0x00010000  scratch RAM     8 KB, read/write, drives nothing

DMA  --  /dev/xdma0_h2c_0 and _c2h_0, file offset == AXI address
  0x0_0000_0000 .. 0x0_FFFF_FFFF   HBM MEM00-15 via SAXI_00
  0x1_0000_0000 .. 0x1_FFFF_FFFF   HBM MEM16-31 via SAXI_16
  0x2_0000_0000 .. 0x2_0000_FFFF   64 KB BRAM, the DMA loopback target
```

The DMA BRAM sits **above** the 8 GB of HBM on purpose: an off-by-one in a host
offset calculation then lands on nothing rather than silently in memory.

---

## Known hazards, each of which has already cost time somewhere

- **The card does not run on slot power.** The 6-pin aux lead is mandatory and
  the LEDs stay dark without it. Check this before anything else.
- **VCCINT is volatile.** 0.678 V at every power-on, against a 0.698 V floor.
  The fix does not survive a power cycle and cannot be applied from the endpoint
  bitstream over JTAG. This is a permanent operational property of the card, not
  a bring-up hurdle that goes away.
- **The endpoint bitstream looks completely dead over JTAG on the bench.** The
  whole AXI fabric, including both JTAG-AXI masters, is clocked by
  `xdma/axi_aclk` and held in reset until the link is up. With no slot there is
  no reference clock. That is expected, not a broken build. Use the probe
  bitstream for bench work.
- **JTAG configuration takes tens of seconds; PCIe allows ~100 ms from PERST#
  deassertion to the first configuration request.** A JTAG-only card therefore
  cannot be present at boot. The flow is: boot the host, JTAG-configure, then
  `echo 1 > /sys/bus/pci/rescan`. The SPI flash would fix this properly and
  **has never been written; its contents are unknown.** Do not write it until
  the JTAG-plus-rescan path has worked at least once -- it is the only boot
  device on a card with a defunct vendor.
- **Vivado silently ignores `set_property` on a `CONFIG.*` name that does not
  exist for that IP.** A typo in the XDMA settings produces a perfectly clean
  build of the wrong design. `FK33_STOP_AFTER_BD=1` reads the parameters back
  for exactly this reason.
- **Do not run driver installs or long builds from a code-server terminal.**
  A session teardown reaps the cgroup mid-flight; that is how the 2026-08-19
  driver install ended up half-configured.

---

## What is still unknown, and the measurement that settles each

| unknown | measurement |
|---|---|
| Whether an FK33 enumerates on PCIe **at all** | stage 2. This is the whole point. |
| Whether the edge fingers, refclk (AD8/AD9) and PERST (BE24) are wired as the board file claims | a trained link proves all three at once; a failure does not say which |
| Whether the link trains at the power-on 0.678 V | the first link attempt happens before anything can raise VCCINT, so stage 2 answers it as a side effect |
| Whether the root port will enumerate a device that appeared after boot | `echo 1 > /sys/bus/pci/rescan`. If it will not, the flash write becomes mandatory. |
| Whether PERST is also strapped to `PROG_B` | JTAG re-read after the first secondary bus reset |
| Real achievable DMA throughput | `./fk33_bringup --bench 1024`. Every load-time number in the plan is arithmetic on a link rate, not a measurement. |
| Negotiated MPS and MRRS | `lspci -vvv`, `DevCtl` line. This is what moves 3.5 GB/s to 3.0. |
| Whether the x4 link lands in quad 227 as Vivado places it | the placed GT sites in the utilization report. The XDC is verified to *request* quad 227 (`check_pcieep_xdc.py`); that Vivado *will* honour it is not yet verified. |
