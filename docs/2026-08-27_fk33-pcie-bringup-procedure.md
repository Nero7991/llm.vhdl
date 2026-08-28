# FK33 PCIe bring-up procedure: what to check, in order, when it does not enumerate

> # 0. THE 6-PIN AUX LEAD
>
> **The FK33 does not run on slot power.** Plug the PSU's 6-pin PCIe lead into
> the card before you close the case. Without it the fans stay still, the LEDs
> stay dark, the FTDI does not appear on USB, and every single check below
> fails in a way that looks like a design fault and is not.
>
> This is step zero, not a note inside step 1. Confirm it with your eyes, and
> then confirm it again from the host:
>
> ```
> lsusb -d 0403:6010            # must show "SQRL FK", serial 153300000607
> ```
>
> `fk33_go.sh` makes this stage A for the same reason, and matches on the
> manufacturer string rather than the bare VID:PID, because this workstation
> already has other FT2232H adapters attached and 0403:6010 alone proves
> nothing.

---

## The one command

Tonight, with the card OUT and before shutting down, in this order:

```bash
cd hw/fk33 && ./save_bitstream.sh          # /tmp does not survive the reboot
cd host && ./fk33_go.sh --selftest         # everything checkable with no card
         ./fk33_go.sh --baseline           # cannot be taken once the card is in
```

Tomorrow, with the card IN and JTAG-configured:

```bash
cd hw/fk33/host && ./fk33_go.sh
```

It runs stages A through G, prints a verdict per stage, and ends by naming the
**first** failing stage and what to look at. It is read-only, needs no root,
and prints every root command instead of running it. Add `--hbm` once it is
green to extend the run into real HBM.

The baseline is what makes the worst case diagnosable. See "Why a baseline"
below: it is the difference between "nothing enumerated" being a dead end and
being a two-line answer.

---

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
| the host program builds clean on this box | **verified 2026-08-27 21:14** | `make check` -> `FK33_HOST_COMPILE OK`, no warnings at `-Wall -Wextra -Wconversion` |
| every script the procedure names exists and is executable | **verified** | `./fk33_go.sh --selftest` section 4, 13 of 13 present |
| `10EE:9034` is in the ID table of the module that was actually built | **verified** | `modinfo -F alias xdma.ko` contains `pci:v000010EEd00009034sv*sd*bc*sc*i*` |
| `xdma.ko` vermagic matches the running kernel | **verified** | `6.8.0-138-generic SMP preempt mod_unload modversions` |
| Above 4G Decoding is already ENABLED in BIOS | **verified** | both GPUs hold 64-bit prefetchable BARs at `0x4000000000` and `0x5000000000`, which a 32-bit-only window cannot place |
| Resizable BAR is already ENABLED | **verified** | GPU BAR1 reads `[size=32G]`; the un-resized default for a GA102 is 256 MB |
| the IOMMU is OFF | **verified** | `/sys/kernel/iommu_groups` is empty and the cmdline carries no `intel_iommu=on` |
| `xdma` will NOT autoload | **verified** | no entry for `v000010EEd00009034` anywhere in `/lib/modules/6.8.0-138-generic/modules.alias` |
| a DIFFERENT in-tree module is also named `xdma` | **verified** | `/lib/modules/6.8.0-138-generic/kernel/drivers/dma/xilinx/xdma.ko`, "AMD XDMA driver", 0 PCI aliases. `modprobe xdma` loads THAT one. |
| the root-port `LnkSta` check works with no card and no root | **verified, after being FIXED** | it did not. See "The root-port check was broken" below. |
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

**Added 2026-08-27: a fifth observer, and it is better than three of the four.**
This board registers a PCIe hotplug slot on the free root port, so the kernel
exports **presence detect** at `/sys/bus/pci/slots/<n>/adapter`. It reads 1 as
soon as a powered card is seated, entirely independently of whether the FPGA is
configured or the link ever trains. Measured tonight with the slot empty:

```
$ cat /sys/bus/pci/slots/0/address /sys/bus/pci/slots/0/adapter /sys/bus/pci/slots/0/power
0000:04:00
0
1
```

`adapter 0` with `power 1` is exactly what "empty but live slot" looks like, so
tomorrow `adapter 1` will mean the card is physically there. That single bit
splits the worst failure class in two:

| presence | link width | means |
|---|---|---|
| 0 | 0 | not seated, or no aux power. Nothing to do with the design. |
| 1 | 0 | seated and powered, and the link did not train. FPGA unconfigured, no refclk, or a GTY/finger fault. |
| 1 | 4 | the interesting cases start here. |

---

## The root-port check was broken, and is now fixed

The procedure said the root-port `LnkSta` read "reports link state even when
nothing enumerates". Rehearsed tonight with no card, as the ordinary user who
will actually run it, that check produced **nothing at all**:

```
$ ./fk33_pcie_check.sh
=== STAGE 2  root port link state (0000:00:1c.0) ===
  (LnkSta needs root for the full capability dump; re-run with sudo
   for this stage only)
  (no link capability lines readable)
  INFO   read LnkSta above by hand
```

There was nothing above to read by hand. `LnkSta` lives in the PCIe capability,
past the 64 configuration bytes an unprivileged process may see, so
`lspci -vvv` prints `Capabilities: <access denied>` and the single most
diagnostic step in the procedure yielded zero bits. On the one day it matters,
in the failure case with the least feedback.

**The fix costs nothing: the kernel already exports the same two fields,
world-readable.** Both `fk33_pcie_check.sh` and `fk33_go.sh` now read sysfs
first and treat `lspci -vvv` as root-only enrichment:

```
$ ./fk33_pcie_check.sh
=== STAGE 2  root port link state (0000:00:1c.0) ===
  sysfs  capability 8.0 GT/s PCIe x1   current 2.5 GT/s PCIe x0
  slot 0  presence detect = 0  power = 1
  FAIL   width x0: LINK TRAINING FAILED
```

That is the correct reading for an empty slot, produced with no root, which is
what the procedure claimed all along and did not deliver.

---

## The slot: measured, and not what the procedure assumed

The procedure hardcoded `0000:00:1c.0` and called it "the free chipset x4 port".
Measured on this box:

```
BDF            max speed  max width  current    occupant
0000:00:01.0   32.0 GT/s  x8         2.5 x8     RTX 3090 Ti          (CPU)
0000:00:01.1   32.0 GT/s  x8         8.0 x4     Samsung root NVMe    (CPU)
0000:00:06.0   16.0 GT/s  x4         16.0 x4    Crucial P3           (CPU)
0000:00:1c.0    8.0 GT/s  x1         2.5 x0     EMPTY                (PCH)
0000:00:1c.2    8.0 GT/s  x1         5.0 x1     Intel I225-V NIC     (PCH)
0000:00:1c.4   16.0 GT/s  x4         2.5 x4     RTX 3090             (PCH)
```

Two things follow, and both would have cost time tomorrow.

**1. The only root port visible with no card in is Gen3 x1, not x4.** If the
card lands there, `LnkSta` will read `Width x1` -- and the old procedure
diagnosed exactly that as "lanes are dropping out. Contact, solder, or cable."
It would have sent you looking for a hardware fault that does not exist. Both
scripts now compare `current_link_width` against `max_link_width` and say
"this port is only x1 wide, the design is fine, the slot is the limit" when
they are equal. Gen3 x1 is about 0.98 GB/s, so it is usable for bring-up and
useless for weight loading.

**2. The root port BDF is not knowable tonight.** The ACPI namespace declares
`RP01` through `RP19`, but only three of them have a PCI device:

```
\_SB_.PC00.RP01 -> 0000:00:1c.0
\_SB_.PC00.RP03 -> 0000:00:1c.2
\_SB_.PC00.RP05 -> 0000:00:1c.4
\_SB_.PC00.RP02, RP04, RP06 ... RP19  ->  no physical_node
```

The BIOS **hides** a PCH root port with nothing attached. So if the FK33 goes
into a slot wired to any of the sixteen hidden ports, a brand new bridge
appears at a BDF that could not have been predicted tonight, and every
hardcoded `-s 0000:00:1c.0` in the procedure points at the wrong thing.

That is also good news, and it is the reason for the baseline: **a root port
appearing that was not there before is itself proof that a powered card is in
that slot**, before any link has trained. It is the strongest evidence
available in the case with the least feedback.

---

## Why a baseline

Run this tonight, with the card out:

```bash
cd hw/fk33/host && ./fk33_go.sh --baseline     # writes pci_baseline.txt
```

It records every bridge, its link capability and current state, every hotplug
slot's presence detect, and every device. Tomorrow `fk33_go.sh` identifies the
card's root port by what **moved**, in this order of strength:

1. an enumerated `10EE:9034`, whose parent is definitive;
2. a bridge that did not exist in the baseline (the BIOS unhid a port);
3. a device behind a port that was empty in the baseline;
4. a link width change on a port that was empty in the baseline;
5. a hotplug slot whose presence detect went 0 to 1;
6. failing all of that, the single port that was empty, clearly labelled a guess.

Only ports that were **empty** in the baseline are trusted for the width test:
an occupied port retrains its own width and speed on its own (the 3090 Ti sits
at 2.5 GT/s at idle), so a change there is evidence of nothing.

The baseline captured tonight is committed as `hw/fk33/host/pci_baseline.txt`.
If the machine's PCI layout changes for any other reason before tomorrow,
retake it.

---

## Before you power off to fit the card

Everything on this list is cheap now and expensive with the card in the slot.
Items 1 to 4 are already confirmed and need no action; they are listed so a
failure tomorrow can be attributed correctly rather than re-litigated.

| # | item | state | action |
|---|---|---|---|
| 1 | **Above 4G Decoding** | **already Enabled** -- both GPUs hold 64-bit prefetchable BARs at `0x4000000000` and `0x5000000000` | none |
| 2 | **Resizable BAR** | **already Enabled** -- GPU BAR1 is `[size=32G]`, against a 256 MB default | none, unless stage E fails: then set it to Disabled to free 63 GB of MMIO |
| 3 | **IOMMU** | **off** -- `/sys/kernel/iommu_groups` empty, no `intel_iommu=on` | none. Leave it off: XDMA scatter-gather then uses plain physical addresses and there is no DMA remapping to misconfigure |
| 4 | **MMIO headroom** | fine -- the highest address in use is about 352 GB, the card needs 192 KB | none |
| 5 | **The 6-pin aux lead** | -- | **plug it in.** See the top of this file |
| 6 | **Which slot** | the only visible free port is Gen3 **x1**. A x4 port may exist behind a hidden RP | decide deliberately; expect x1 and do not read it as a fault |
| 7 | **The GPU that has to move**, if you want x4 | `0000:00:1c.4` is the only free-able Gen4 x4 port and the RTX 3090 is in it | optional, and it costs the second GPU |
| 8 | **Baseline snapshot** | -- | `./fk33_go.sh --baseline` **before** shutting down. It cannot be taken afterwards |
| 8b | **The bitstream is in `/tmp`, and `/tmp` is emptied at every boot** | `pcieep_build.sh` writes to a scratchpad under `/tmp` | **`cd hw/fk33 && ./save_bitstream.sh`** after the build finishes and before powering off. Without it the hour-long build is gone at exactly the moment the card is in the slot |
| 9 | **`xdma` will not autoload** | verified: nothing in `/lib/modules` claims `10EE:9034` | plan on an explicit `insmod` |
| 10 | **`modprobe xdma` loads the WRONG module** | the kernel ships an unrelated in-tree `xdma` (`drivers/dma/xilinx`, AMD XRT dmaengine, zero PCI IDs) | **always `insmod` the absolute path.** Never `modprobe xdma` |
| 11 | **The module load must not run in a code-server terminal** | a session teardown reaped a driver install mid-flight on 2026-08-19 | `claude-tmux`, or `systemd-run --unit` |
| 12 | **The card is JTAG-configured after boot** | PCIe allows about 100 ms from PERST to the first config read; JTAG takes tens of seconds | plan on `echo 1 > /sys/bus/pci/rescan`, and do not touch the SPI flash |

The exact root commands, in order, none of which this user can run without
typing a password:

```bash
# after JTAG configuration, to make the kernel look again
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'

# the driver, poll mode first, by ABSOLUTE PATH
sudo insmod $HOME/GitHub/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko poll_mode=1

# only if the module loaded and did not bind
echo "10ee 9034" | sudo tee /sys/bus/pci/drivers/xdma/new_id

# make the character devices usable without root
echo 'KERNEL=="xdma*", MODE="0666"' | sudo tee /etc/udev/rules.d/60-xdma.rules
sudo udevadm control --reload && sudo udevadm trigger

# only if stage E says the device enumerated but got no BAR, and BIOS is
# already correct: let the kernel redo the bridge windows
#   add  pci=realloc  to GRUB_CMDLINE_LINUX_DEFAULT, update-grub, reboot
```

---

## Telling the three big failure classes apart

This is the question the procedure has to answer first, because the remedies
have nothing in common.

### A. NOT ENUMERATED

`lspci -Dnn | grep -i xilinx` is empty.

**Distinguishing evidence:** look at the *root port*, not the device. Do NOT
use `lspci -vvv` for this: as an ordinary user it prints
`Capabilities: <access denied>` and tells you nothing (measured, see "The
root-port check was broken" above). Read sysfs, which is world-readable, and
do not hardcode the BDF -- `fk33_go.sh` discovers it from the baseline:

```bash
cd hw/fk33/host && ./fk33_go.sh          # stages B and C do exactly this

# by hand, once you know the port:
RP=0000:00:1c.0
cat /sys/bus/pci/devices/$RP/{max_link_width,current_link_width}
cat /sys/bus/pci/devices/$RP/{max_link_speed,current_link_speed}
cat /sys/bus/pci/slots/*/{address,adapter,power}
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
- `Width x1` or `x2` -- **compare against `max_link_width` before concluding
  anything.** The only free port on this board is Gen3 **x1**, so `x1` there is
  the port's full width and not a fault at all. Only if `current < max` are
  lanes actually dropping out, and then it is contact, solder, or (through
  MCIO) cable and adapter lane mapping. Either way **not a design fault; the
  link works.**
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
| 0.6 | `cd hw/fk33/host && ./fk33_go.sh --selftest` | `FK33_GO_SELFTEST OK` | one of: the program, a referenced script, the probe bitstream, the module, or the baseline is missing |
| 0.7 | `./fk33_go.sh --baseline` **before powering off** | `pci_baseline.txt` written | it cannot be taken once the card is in, and without it "nothing enumerated" has no answer |
| 0.7b | `cd hw/fk33 && ./save_bitstream.sh` **before powering off** | 2 of 2 bitstreams in `hw/fk33/bit/` | `/tmp` is emptied at every boot and the build writes there |
| 0.8 | BIOS | Above 4G Decoding **Enabled** -- **already confirmed enabled**, see the pre-power-on table | if it were off, stage E fails with the device present and no BAR |

### Stage 1 -- power and configuration. Card in, host booted.

| # | check | isolates | fail means |
|---|---|---|---|
| 1.1 | look at the card: fan spinning, LEDs lit | power delivery | **the 6-pin aux lead is not connected.** The card does NOT run on slot power. This is the single most likely first-day fault. |
| 1.2 | `lsusb -d 0403:6010` | the FTDI JTAG bridge, hence housekeeping power | as 1.1. **Match the string, not the VID:PID:** this workstation already has other FT2232H adapters on the bus. The FK33 reports manufacturer `Xilinx`, product `SQRL FK`, serial `153300000607`. `fk33_go.sh` stage A checks the manufacturer string for this reason. |
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
| 2.2 | `./fk33_go.sh` stages B and C | presence detect, then the root port's link width and speed, from sysfs, with no root and with the port discovered rather than assumed. **Reports link state even when nothing enumerates**, which the old `lspci -vvv` form did not. |
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
sudo insmod $HOME/GitHub/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko poll_mode=1
ls -l /dev/xdma0_*
```

**Use `insmod` with the absolute path. Never `modprobe xdma`.** The kernel
ships an unrelated in-tree module with the same name at
`/lib/modules/6.8.0-138-generic/kernel/drivers/dma/xilinx/xdma.ko`
("AMD XDMA driver", the XRT dmaengine driver, **zero PCI aliases**).
`modprobe xdma` loads that one, it will never bind to `10EE:9034`, and the
resulting "module loaded, nothing bound" looks exactly like a device-ID miss.

**It will not autoload either.** Nothing in
`/lib/modules/6.8.0-138-generic/modules.alias` claims `v000010EEd00009034`, so
no amount of rescanning brings the driver in on its own. Verified tonight.

The ID itself is fine: `modinfo -F alias` on the module that was actually
built contains `pci:v000010EEd00009034sv*sd*bc*sc*i*`, so `new_id` should
never be needed.

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
- **`/tmp` on this box is emptied at every boot, and the bitstream is built
  into `/tmp`.** Fitting the card requires a power-off, so the build and the
  reboot are on a collision course. Measured 2026-08-27:

  ```
  $ grep '^D /tmp' /usr/lib/tmpfiles.d/tmp.conf
  D /tmp 1777 root root -
  $ systemctl cat systemd-tmpfiles-setup.service | grep ExecStart
  ExecStart=systemd-tmpfiles --create --remove --boot --exclude-prefix=/dev
  $ uptime -s
  2026-08-24 16:53:56
  $ find /tmp -maxdepth 1 -printf '%TF %TT %p\n' | sort | head -1
  2026-08-24 16:54:11 /tmp/.font-unix
  ```

  `D` plus `--remove --boot` clears the directory, and nothing in `/tmp`
  predates the last boot. Run **`hw/fk33/save_bitstream.sh`** the moment the
  build finishes; `pcieep.sh` now prefers `hw/fk33/bit/` and warns when the
  bitstream it is about to load is under `/tmp`.
- **Never `modprobe xdma`.** The kernel ships an unrelated in-tree module of
  the same name with zero PCI IDs. Always `insmod` the absolute path of the
  `dma_ip_drivers` build.
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
| Which root port the card lands on, and how wide it is | it cannot be known tonight: the BIOS hides sixteen of the nineteen PCH root ports until something is attached. `fk33_go.sh` finds it by diffing against `pci_baseline.txt`. |
| Whether the slot the card goes into wires presence detect | `cat /sys/bus/pci/slots/*/adapter` with the card in. Today the one registered slot reads `adapter 0`, `power 1`. |
| Whether `pciehp` enumerates the card on its own when the link comes up after a JTAG configure | watch for the device before running the rescan. Hotplug is active on `00:1c.0`, so a rescan may prove unnecessary; if the card lands on a hidden port instead, that port's hotplug state is unknown. |

---

## ONLY THE CARD CAN SETTLE THESE -- read before you start

Everything below was deliberately left unverified rather than upgraded on a
plausible argument. None of it can be closed tonight, and each item names the
one measurement that closes it.

1. **Whether an FK33 enumerates on PCIe at all.** No FK33 ever has. Every
   result in this project so far went over JTAG.
2. **Whether the edge fingers, the refclk pair AD8/AD9 and PERST on BE24 are
   wired as the board file claims.** A trained link proves all three at once;
   a failure does not say which of the three.
3. **Whether the link trains at the power-on VCCINT of 0.678 V**, which is
   below the 0.698 V floor of every characterised speed grade. The first link
   attempt necessarily happens before anything can raise the rail.
4. **Which root port the card lands on, and its width.** The only port visible
   with the slot empty is Gen3 x1. Sixteen more are hidden by the BIOS and one
   of them may be the x4 port. Expect x1 and do not read it as a fault.
5. **Whether PERST is also strapped to `PROG_B` in copper.** Not knowable from
   any file we hold. It decides whether a secondary bus reset costs you the
   bitstream. One JTAG re-read after the first reset settles it permanently.
6. **Whether `echo 1 > /sys/bus/pci/rescan` finds a device that appeared after
   boot.** If it does not, writing the SPI flash becomes mandatory, and that
   flash has never been written and its contents are unknown.
7. **Whether the design meets timing at 250 MHz, and whether Vivado places the
   x4 link in quad 227.** Both are implementation results. The build running
   tonight answers them; the XDC is verified only to *request* quad 227.
8. **Real DMA throughput, and the negotiated MPS and MRRS.** Every load-time
   number in the plan is arithmetic on a link rate, not a measurement.
9. **LED 6's polarity.** Undocumented. Take the *change* as the signal, never
   the direction, and write down which way it went the first time.
