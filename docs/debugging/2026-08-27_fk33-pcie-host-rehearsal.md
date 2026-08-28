# FK33 PCIe bring-up: rehearsing the whole procedure with no card

**Date:** 2026-08-27, evening, the night before the FK33 goes into the slot
**Host:** `Oren-Dell-Ubuntu`, Z790 AERO G, kernel 6.8.0-138-generic
**Constraint:** a Vivado `fk33_pcieep` build was running throughout (7.4 GB
RSS), so nothing here touched Vivado. Everything is host-side.

## The question

Does the bring-up procedure in `docs/2026-08-27_fk33-pcie-bringup-procedure.md`
actually work when it is run, by the user who will run it, without root, with
no card in the machine? And which of its claims survive contact with the
hardware that is already here?

## The answer

Six real defects, four of which would have cost time tomorrow and one of which
would have destroyed the bitstream being built tonight.

1. **`/tmp` is emptied at every boot and the bitstream is built into `/tmp`.**
   Fitting the card requires a power-off. The hour-long build would have been
   gone at exactly the moment it was needed.
2. **The root-port `LnkSta` check produced nothing at all** for a non-root
   user. It is the procedure's designated observer for the failure case with
   the least feedback, and it returned zero bits.
3. **The hardcoded root port `0000:00:1c.0` is Gen3 x1, not x4**, and the
   procedure diagnosed a x1 link as "lanes are dropping out, contact or
   solder". It would have sent the user hunting a hardware fault that does not
   exist.
4. **The root port cannot be known tonight at all.** The BIOS hides sixteen of
   nineteen PCH root ports until something is attached to them.
5. **`modprobe xdma` loads the wrong module.** The kernel ships an unrelated
   in-tree `xdma` with zero PCI IDs.
6. **Nothing autoloads on `10EE:9034`**, so an explicit `insmod` is mandatory.

Everything else in the procedure that could be executed tonight was executed
and passed.

## The procedure that produced it, in the order it was run

Each step says what it controls for, because that is the reusable part.

| # | probe | isolates |
|---|---|---|
| 1 | `make clean && make check && make` | that the host program is valid C and that every printf format matches its argument. Controls for "the test program is the bug". |
| 2 | `./selftest_nocard.sh` | the program's own logic against seeded files, plus four deliberate corruptions. Controls for a test that only ever verifies the passing path. |
| 3 | `python3 check_pcieep_xdc.py` | the XDC against Vivado's real package file. No Vivado process needed. |
| 4 | `lspci -tvnn`, then `max_link_width` / `current_link_width` per bridge | the topology, and specifically which ports are free and how wide. |
| 5 | ACPI `path` of every root port | whether ports exist that have no PCI device, i.e. whether the visible topology is the whole topology. |
| 6 | `/sys/bus/pci/slots/*` | whether presence detect exists as an observer at all. |
| 7 | `modinfo` on the built `.ko`, plus `modules.alias` | whether the ID matches and whether anything autoloads. |
| 8 | `tmpfiles.d` plus `uptime -s` versus the oldest file in `/tmp` | whether the build output survives to tomorrow. |
| 9 | re-running every fixed script end to end | that the fixes work, and that the no-card verdicts are the correct ones rather than merely green. |

## The evidence

### The topology, measured

```
$ for d in /sys/bus/pci/devices/0000:00:0*.* /sys/bus/pci/devices/0000:00:1c.*; do ... done
BDF            maxspd   maxw     curspd    curw      driver
0000:00:01.0   32.0     8        2.5       8         pcieport     RTX 3090 Ti
0000:00:01.1   32.0     8        8.0       4         pcieport     Samsung root NVMe
0000:00:06.0   16.0     4        16.0      4         pcieport     Crucial P3
0000:00:1c.0   8.0      1        2.5       0         pcieport     EMPTY
0000:00:1c.2   8.0      1        5.0       1         pcieport     Intel I225-V
0000:00:1c.4   16.0     4        2.5       4         pcieport     RTX 3090
```

The only free port is Gen3 **x1**. There is no free x4 port with the card out.

### Sixteen hidden root ports

```
$ for d in /sys/bus/acpi/devices/*; do ... done
\_SB_.PC00.RP01 -> 0000:00:1c.0
\_SB_.PC00.RP03 -> 0000:00:1c.2
\_SB_.PC00.RP05 -> 0000:00:1c.4
\_SB_.PC00.RP02, RP04, RP06, RP07, RP08, RP09 ... RP19  ->  physical_node (none)
```

Nineteen declared, three with a PCI device. So a new bridge can appear at an
unpredictable BDF tomorrow, and its appearance is itself proof that a powered
card is in that slot.

### The root-port check, before

```
$ ./fk33_pcie_check.sh
=== STAGE 2  root port link state (0000:00:1c.0) ===
  (LnkSta needs root for the full capability dump; re-run with sudo
   for this stage only)
  (no link capability lines readable)
  INFO   read LnkSta above by hand
```

There was nothing above to read. `lspci -vvv -s 00:1c.0` gives
`Capabilities: <access denied>` as a normal user because `LnkSta` lives past
the 64 config bytes an unprivileged reader may see.

### The root-port check, after

```
$ ./fk33_pcie_check.sh
=== STAGE 2  root port link state (0000:00:1c.0) ===
  sysfs  capability 8.0 GT/s PCIe x1   current 2.5 GT/s PCIe x0
  slot 0  presence detect = 0  power = 1
  FAIL   width x0: LINK TRAINING FAILED
```

Same information, no root, from `current_link_width` / `current_link_speed`,
which the kernel exports world-readable.

### Presence detect exists, and is a fifth observer

```
$ cat /sys/bus/pci/slots/0/{address,adapter,power}
0000:04:00
0
1
```

`adapter 0` with `power 1` is "empty but live". Tomorrow `adapter 1` with
`current_link_width 0` means seated and powered and the link did not train,
which no other observer on the host can say.

### `/tmp` does not survive a boot

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

`D` plus `--remove --boot` clears the directory. Nothing in `/tmp` predates the
last boot. `/tmp` is on ext4, not tmpfs, which is why this is not obvious.

### The module

```
$ modinfo ~/GitHub/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko
version:        2025.2.0
vermagic:       6.8.0-138-generic SMP preempt mod_unload modversions
$ modinfo -F alias .../xdma.ko | grep -i 9034
pci:v000010EEd00009034sv*sd*bc*sc*i*
$ grep -i 'v000010EEd00009034' /lib/modules/6.8.0-138-generic/modules.alias
(no output)
$ modinfo xdma
filename:       /lib/modules/6.8.0-138-generic/kernel/drivers/dma/xilinx/xdma.ko
description:    AMD XDMA driver
$ modinfo -F alias xdma | wc -l
0
```

The ID is right in the module that was built. Nothing autoloads. And there is a
same-named in-tree module with no PCI IDs that `modprobe xdma` would load
instead.

### BIOS state, inferred from what is already working

```
$ lspci -vv -s 01:00.0 | grep Region
Region 1: Memory at 5000000000 (64-bit, prefetchable) [size=32G]
$ lspci -vv -s 06:00.0 | grep Region
Region 1: Memory at 4000000000 (64-bit, prefetchable) [size=32G]
$ ls /sys/kernel/iommu_groups | wc -l
0
$ cat /proc/cmdline
... quiet splash acpi_enforce_resources=lax resume=... (no intel_iommu)
```

BARs above 4 GB prove Above 4G Decoding is enabled. A 32 GB BAR1 on a GA102,
whose un-resized default is 256 MB, proves Resizable BAR is enabled. No IOMMU
groups and no `intel_iommu=on` proves the IOMMU is off.

### The end state, rehearsed

```
$ ./fk33_go.sh --quiet
  PASS  A    FT2232H 'SQRL FK' serial 153300000607 -- the card has power
  FAIL  B    no root port appeared or changed state since the baseline
  FAIL  B    slot 0 presence detect = 0
  FAIL  C    width x0 -- LINK TRAINING FAILED
  FAIL  D    no 10ee:9034 and no 1e24 subsystem in lspci
  FAIL  F    the xdma module is not loaded
  FAIL  G    not reached
 FIRST failing stage: B
 -> SEATING or POWER.  Nothing is physically detected in any slot.
```

That is the correct reading for an empty machine, and it is the reading the
tool must give tomorrow if the card is not seated or has no aux power.

## Measured and REJECTED. Do not retry.

- **`lspci -vvv -s <rootport> | grep LnkSta` as a normal user.** Returns
  `Capabilities: <access denied>` and nothing else. It is in the procedure
  because it works under `sudo`, and the procedure never rehearsed it without.
  Use `/sys/bus/pci/devices/<bdf>/current_link_{width,speed}`.
- **Hardcoding `FK33_RP=0000:00:1c.0`.** It is a Gen3 x1 port and probably not
  where the card lands. Discover the port instead.
- **Treating `Width x1` as a lane fault.** Compare against `max_link_width`
  first. On the only free port here, x1 is full width.
- **`lsusb | grep 0403:6010` as a power check.** This box already has other
  FT2232H adapters attached. Match the manufacturer string: the FK33 reports
  `Xilinx` / `SQRL FK` / serial `153300000607`.
- **Counting `ls /sys/bus/pci/devices/<bridge>/0000:*` to decide whether a
  port is empty.** It matches the pcie service entries
  (`0000:00:1c.0:pcie001`) and reported three children for a port with nothing
  in it. Filter on the presence of a `vendor` file.
- **Using "link width changed" on an occupied port as evidence a card
  appeared.** The 3090 Ti sits at 2.5 GT/s at idle and retrains on its own.
  Only ports that were empty in the baseline are admissible.
- **`modprobe xdma`.** Loads `drivers/dma/xilinx/xdma.ko`, which is a different
  driver with the same name and zero PCI IDs.

## Measurement traps hit

- **`/proc/iomem` is address-masked for non-root**, so every line reads
  `00000000-00000000`. It looks like a broken file rather than a permission
  effect. Use `/sys/bus/pci/devices/*/resource`, which is not masked.
- **`dmesg` is blocked for non-root here** (`dmesg: read kernel buffer failed:
  Operation not permitted`), so every `dmesg | grep xdma` in the procedure
  silently returns nothing rather than failing. Prefix them with `sudo`.
- **`/tmp` being ext4 rather than tmpfs makes it look persistent.** The
  clearing comes from `tmpfiles.d`, not from the mount type.
- **`modinfo -F alias | head -40` truncated before `9034`** and produced a
  false "the ID is missing" reading on the first pass. Grep, do not paginate.
- **A relative `./host/fk33_go.sh -h` broke** because the script chdirs to its
  own directory and then `sed`s `"$0"`. Resolve the self path before the cd.

## What changed

| file | change |
|---|---|
| `hw/fk33/host/fk33_go.sh` | new. The one command: stages A to G, per-stage verdict, first-failure naming, plus `--selftest` and `--baseline` |
| `hw/fk33/host/pci_baseline.txt` | new. Tonight's PCI topology, so tomorrow's "nothing enumerated" is answerable |
| `hw/fk33/save_bitstream.sh` | new. Copies bitstreams out of `/tmp` before the reboot |
| `hw/fk33/host/fk33_pcie_check.sh` | stage 2 reads sysfs instead of `lspci -vvv`; root port auto-discovered; x1 no longer misdiagnosed |
| `hw/fk33/pcieep.sh` | prefers `hw/fk33/bit/`, warns when the bitstream is under `/tmp` |
| `docs/2026-08-27_fk33-pcie-bringup-procedure.md` | aux-lead warning promoted to line one; the one command; corrected topology; pre-power-on checklist; explicit card-only list; verified table extended with eleven measured rows |

## Open, not yet answered

Everything on the "ONLY THE CARD CAN SETTLE THESE" list at the end of the
procedure. In particular, and deliberately not upgraded to verified:

- No FK33 has ever enumerated on PCIe.
- Which root port the card lands on and how wide it is.
- Whether the slot it goes into wires presence detect at all. If it does not,
  stage B degrades to a guess and stage C carries the whole load.
- Whether `pciehp` enumerates the card on its own when the link comes up after
  a JTAG configure, making the rescan unnecessary. Hotplug is active on
  `00:1c.0`; the hidden ports' hotplug state is unknown.
- Whether the endpoint bitstream builds, meets timing, and places the x4 link
  in quad 227. The build was still running when this was written.
