# Restoring card 1 after the hard reboot, with two cards on the chain

Date: 2026-08-30. Hardware: SQRL FK33 serial **153300000607** ("card 1"), in the
PCIe slot behind root port `0000:00:1c.0`. Card 2 (**153300001366**) is on USB
JTAG and aux power, not in a slot. Bitstream
`hw/fk33/bit/fk33_pcieep_eng.bit`, 22,568,402 bytes, sha256 `6b12b3c4...64c6`.

## The question

The box was hard-rebooted with the power button on 2026-08-30 (see
`2026-08-30_the-box-hung-under-my-own-dispatch.md`). That cut slot power, so the
FPGA came up unconfigured and the volatile VCCINT wiper was lost. What does it
take to get the card back to a usable state, and what changed now that a second
card is on the chain?

## The answers, up front

1. **The FPGA is configured and VCCINT is restored.** `FPGA_PROG_OK`, three
   JTAG2AXI masters (the engine build's signature), wiper 64, **VCCINT
   0.7216 V**, VCCBRAM 0.7569 V, die 33.3 C, SYSMON `FLAG_REG = 0x0010` with the
   VCCINT alarm bit clear.
2. **PCIe is NOT enumerated, and cannot be from this account.** The endpoint did
   not exist at POST, so the link was never trained. Recovery needs one command
   as **root**, and this account has no passwordless sudo (`sudo -n -l` returns
   `a password is required`). **This is the only remaining step.**
3. **`./pcieep.sh` alone is no longer sufficient, and it correctly refuses.**
   Two variables must be set, and they are different variables.

## The procedure that produced it

| step | what it isolates |
|---|---|
| `lspci \| grep -i xilinx` | whether the endpoint exists at all. It did not, which is consistent with either an unconfigured FPGA or a down link and does not separate them |
| `lsmod \| grep xdma`, `ls /dev/xdma*` | rules out a driver-side explanation. Neither present, as expected with no endpoint |
| sysfs walk of `0403:6010` USB devices | **which cards are physically present, by serial.** This is the step that matters now that there are two |
| `./pcieep.sh` with no selector | confirms the guard fires rather than guessing |
| `./pcieep.sh` with both selectors | configures probe, steps VCCINT, configures the endpoint |
| `fk33_pcie_check.sh` | identifies the root port and prints the recovery ladder |

## Evidence

Both cards present, by sysfs rather than by enumeration order:

```
1-10     mfr=Xilinx  prod=SQRL FK  serial=153300001366
1-8.2    mfr=Xilinx  prod=SQRL FK  serial=153300000607
```

The guard firing, which is the correct behaviour and not a fault:

```
FPGA_PROG_FAIL: REFUSING TO GUESS -- 2 configurable targets present
     2  xcvu33p (idcode 04b69093 irlen 6 fpga)
     4  xcvu33p (idcode 04b69093 irlen 6 fpga)
```

The VCCINT climb, ending in spec:

```
  wiper  72 ->  68   VCCINT=0.7169 V  (+0.0050 V)  die=33.0 C
  wiper  68 ->  64   VCCINT=0.7207 V  (+0.0039 V)  die=34.4 C
REACHED TARGET: wiper=64  VCCINT=0.7214 V

FINAL STATE
  wiper   = 64  (power-up default 128)
  VCCINT  = 0.7216 V
  VCCBRAM = 0.7569 V
  die     = 33.3 C
  SYSMON FLAG_REG = 0x0010  (bit1 VCCINT alarm = 0)
```

Configuration, with the engine build's three masters:

```
FPGA_PROG_OK
  2* xcvu33p
     3  Legacy Debug Hub
        4  JTAG2AXI
        5  JTAG2AXI
        6  JTAG2AXI
```

The JTAG-side check, whose failure is expected and does NOT indict the
bitstream:

```
  probe hw_axi_1 at 0xA000 -> 0xDEC0DEE3
ERROR: [Xicom 50-38] xicom: AXI TRANSACTION TIMED OUT     (hw_axi_2)
ERROR: [Xicom 50-38] xicom: AXI TRANSACTION TIMED OUT     (hw_axi_3)
PCIEEP_FAIL: 0 of 3 JTAG-AXI masters answered
```

`pcieep.sh` stage 3 says so itself before running: every read there goes through
`xdma/axi_aclk`, which does not run until the link is up. **One master answering
`0xDEC0DEE3` while two time out is the signature of a configured fabric with a
down link**, not of a bad bitstream. A success there would have been conclusive
the other way.

## The remaining step, for the operator

Root, on the workstation:

```
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'
# if that finds nothing, secondary bus reset on the root port, then rescan:
sudo setpci -s 0000:00:1c.0 BRIDGE_CONTROL=40:40; sleep 1
sudo setpci -s 0000:00:1c.0 BRIDGE_CONTROL=00:40; sleep 1
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'
```

`fk33_pcie_check.sh` notes that the bus reset "should NOT deconfigure the FPGA,
because PERST lands on an ordinary I/O pin (BE24), not on PROG_B -- but that is
inferred from the board file, not verified". **Re-check over JTAG afterwards
that the bitstream is still loaded.** Note the root port already has bus
resources assigned (`primary=00, secondary=04, subordinate=04`), so a rescan has
somewhere to enumerate into.

## Measured and REJECTED -- do not retry

- **`./pcieep.sh` with no target selector.** Aborts at stage 1 with two
  configurable targets. This is the guard working; do not set an index to get
  past it. An agent already destroyed card 1's factory flash by aiming an
  operation at the wrong target, and **card 2 now holds the only surviving copy
  of that image, which is card 1's restore path.**
- **`FK33_TARGET` alone.** It is read by the Vivado-side scripts
  (`tcl/target_select.tcl`, `get_hw_targets` / `open_hw_target`) and NOT by
  `tcl/program.tcl`, which is xsdb and reads **`FK33_XSDB_TARGET`**. Setting
  only one leaves the other stage guessing or refusing. Both are needed:
  `FK33_XSDB_TARGET=0607A FK33_TARGET=153300000607A`.
- **A plain `/sys/bus/pci/rescan` from this account.** `sudo: a password is
  required`; there is no rule in `/etc/sudoers.d/` for it.

## Measurement traps hit

- **The first `lspci` reading proves nothing on its own.** No endpoint is
  equally consistent with an unconfigured FPGA and with a configured one whose
  link is down. Only the sysfs USB walk plus the JTAG probe separate them, and
  the USB walk is the cheap one, so do it first.
- **Stage 3's `PCIEEP_FAIL` reads like a bad bitstream and is not.** The doc for
  the first load records three separate defects *in the check* rather than in
  the card, including a decimal-versus-hex comparison. Treat a stage 3 failure
  as uninformative until the link is up.
- **`0xDEC0DEE3` at `0xA000` is not the identity register's expected value**
  (`0x464B3333`). It is not yet established whether that is the engine build's
  own scratch value on a different master, or a stale bus. Open, below.

## Correction to CLAUDE.md

CLAUDE.md says "Stay at wiper 68 (~0.717 V)". **The tooling's own operating
point is wiper 64 at ~0.720 V**, and it gets there deliberately:
`tcl/vccint_step.tcl` sets `V_TARGET 0.720` with an accept band of
0.716..0.728, and `host/fk33_powercycle.sh:15` records "after a warm reboot:
wiper=64 VCCINT=0.7203 V" as the expected state. Both 64 and 68 are inside the
0.698..0.742 V band that is in spec for **both** -2L and -2/-1, so this is not a
safety issue. The load-bearing half of the CLAUDE.md rule is the other half:
**never SQRL's 0.850 V**, which `vccint_step.tcl` explicitly rejects and guards
with `V_CEILING 0.760`.

## Open, not yet answered

- **PCIe enumeration.** Blocked on a root command. Everything below it is
  unfalsifiable until it happens.
- **Whether the secondary bus reset deconfigures the FPGA.** The board file says
  PERST lands on BE24 and not PROG_B; that is inferred, never verified. If the
  reset is used, re-check over JTAG.
- **What `0xDEC0DEE3` at `0xA000` on `hw_axi_1` actually is.** Not chased,
  because the link being down makes any conclusion from it weak.
- **Whether THERM-255 still trips on this configuration.** The thermal guard was
  measured tripping roughly once every three minutes for reasons that are not
  heat, and each trip halts the compute domain. No result from this card is
  evidence about subsystem A unless the trip count is read alongside it.

---

## CORRECTION, 2026-08-30, same day: the rescan CANNOT work, and this document told you to try it

**WITHDRAWN: the section above headed "The remaining step, for the operator".**
Oren ran `sudo sh -c 'echo 1 > /sys/bus/pci/rescan'` and it found nothing, which
is not bad luck. **No rescan and no secondary bus reset can recover this state,
and the reason was already on disk in this repository when the advice was
written.**

### What was actually wrong

The recovery ladder named `0000:00:1c.0`. That port is **not the card's**. It
was chosen because `fk33_pcie_check.sh` printed it, and the port was never
cross-checked against the recorded baseline.

MEASURED, `hw/fk33/host/pci_baseline.txt`, captured 2026-08-27:

```
BRIDGE 0000:00:1c.0 8.0GT/sPCIe 1 2.5GT/sPCIe 0 4 0     <- 0 children, an empty slot
BRIDGE 0000:00:1c.4 16.0GT/sPCIe 4 2.5GT/sPCIe 4 6 2    <- bus 06
DEV 0000:06:00.0 0x10de 0x2204
DEV 0000:06:00.1 0x10de 0x1aef
```

Bus 06 is the port the card now sits behind, which is why the first-load
document and `fk33_reload.sh`'s default both say `0000:06:00.0`. (In the
baseline that bus held an RTX 3090, `0x10de 0x2204`; the card was fitted into
that slot afterwards.)

**Today `0000:00:1c.4` is ABSENT from config space entirely.** Bridges present
now: `00:01.0`, `00:01.1`, `00:06.0`, `00:1c.0`, `00:1c.2`. The baseline has all
five plus `00:1c.4`. `ls /sys/class/pci_bus/0000:06` does not exist.

`fk33_pcie_check.sh` had already stated this case in its own output, in the run
quoted earlier in this document:

> A port with a slot entry that is ABSENT from config space is a real connector
> whose root port the BIOS disabled after nothing trained on it at POST. That is
> a bring-up finding, not a missing card: **there is no bridge to rescan behind
> and setpci cannot address it.**

The FPGA was unconfigured at POST because slot power had been cut, so nothing
trained, so the BIOS disabled the port. **There is no bridge, so `rescan` has
nowhere to enumerate and `setpci -s 0000:00:1c.4` has no target.**

### The actual fix

**A warm reboot, taken NOW THAT THE FPGA IS CONFIGURED.** Configuration and the
VCCINT wiper both survive a warm reboot; `host/fk33_powercycle.sh:15` records it
as MEASURED on 2026-08-28: `after a warm reboot: wiper=64 VCCINT=0.7203 V`. With
a live endpoint present at POST the BIOS will train the link and enumerate the
port normally. **The order that works is configure, then reboot** -- the
opposite of the order this document originally implied.

Deferred by Oren's decision until the running synthesis and gate work quiesces,
because nothing needs the card in the meantime.

### Measurement trap, and it is the reusable part

**`fk33_pcie_check.sh` prints a recovery ladder that names a port it has not
established is yours.** Its ladder is a template. The document above copied it
verbatim and turned it into an instruction, and the disconfirming evidence -- a
baseline capture, in this repository, listing every bridge and its bus -- was
never consulted. **The check that would have caught it costs one `grep`:**

```
grep '^BRIDGE' hw/fk33/host/pci_baseline.txt
lspci -D | awk '/PCI bridge/{print $1}'
```

A bridge in the first list and missing from the second is a hidden port, and a
hidden port is not recoverable from userspace at any privilege level.

**Generalised: an empty root port and an absent root port look identical in
`lspci` output if you only look at what is there.** The signal is what is
MISSING relative to a known-good capture, and the only reason that capture
existed is that someone took a baseline before the first bring-up. Take
baselines.

---

## SECOND CORRECTION, 2026-08-30: the reboot cannot work either, and why

**WITHDRAWN: "The actual fix -- a warm reboot, taken NOW THAT THE FPGA IS
CONFIGURED."** Two reboots were taken with the engine bitstream loaded. Neither
enumerated the card. The reasoning was sound and the conclusion was wrong.

### What was measured

After the second reboot, with the engine bitstream loaded before it:

```
AXI_MASTERS hw_axi_1 hw_axi_2 hw_axi_3
  probe hw_axi_1 at 0xA000 -> 0xDEC0DEE3
```

Three JTAG-AXI masters is the engine build's signature, and one answers. **So
FPGA configuration DOES survive a warm reboot on this board.** `flash.sh
--status` agrees: `CFG_DONE 1`, `CFG_SYSMON TEMP=35.6 VCCINT=0.715`,
`CFG_AXI_MASTERS 3`. And `00:1c.4` was still absent from config space.

**Configuration was never the blocker.** The wiper reading 68 rather than 128
was a correct measurement used to support a conclusion that had not been tested:
it proves card power survived, and says nothing about whether the endpoint
trained.

### The actual mechanism, from the project's own record

`docs/debugging/2026-08-28_fk33-first-light.md`, describing the ONLY successful
bring-up:

> **Exploit the live root port.** The handoff's reasoning -- PCIe wants a
> trained link within ~100 ms of PERST# deassertion, JTAG configuration cannot
> meet it, so the host disables the port -- **is sound for a COLD boot. It does
> not apply when a root port is already up.** So: remove the PCI device, JTAG
> configure our bitstream, rescan.

**The root port was already up because the card configured itself from its
FACTORY FLASH at power-on, inside the 100 ms window.** The JTAG bitstream was
then swapped in behind an already-live bridge. `hw/fk33/flash.sh`'s own header
records the card enumerating as `Squirrels Research Labs ForestKitten 33
[1e24:1533]` behind root port `00:1d.0` while running that factory image.

**So the working procedure was never "configure over JTAG, then reboot".** It
was "flash boot trains the link, then remove / configure / rescan". Card 1's
factory image was destroyed, so the first half no longer happens and there is
never a live port for the second half to exploit. **JTAG configuration cannot
open the window; only something in flash can.**

## Measured and REJECTED -- do not retry

- **A warm reboot with the bitstream JTAG-loaded.** Taken TWICE. Configuration
  survives; the port stays hidden. **Do not take a third.**
- **`/sys/bus/pci/rescan`.** No bridge exists to enumerate behind.
- **A secondary bus reset on `0000:00:1c.0`.** Wrong port, and see below.
- **Reading the wiper as evidence about FPGA configuration.** It is evidence
  about card POWER only. The discriminator for configuration is the JTAG-AXI
  master count, or `flash.sh --status`, and it is cheap.

## A SAFETY DEFECT FOUND WHILE DIAGNOSING, not yet fixed

**`hw/fk33/host/potlatch.tcl:52` opens the JTAG target by BARE INDEX:**

```tcl
open_hw_target [lindex [get_hw_targets] 0]
```

`hw/fk33/tcl/target_select.tcl` exists precisely to eliminate this, and its own
header says why: *"An agent already destroyed card 1's SQRL factory flash image
by aiming a flash operation at the wrong thing; card 2's copy of that image is
now the ONLY surviving one."* With two cards on the chain, index 0 is whichever
enumerated first.

`host/fk33_powercycle.sh` reads no target variable at all, so its verdict is
about whichever card index 0 happens to be. **That is why it reported
`no_axi_master` for a card that had three**: it was reading card 2. The verdict
was not wrong about what it looked at; it looked at the wrong card.

`potlatch.tcl` has no write path, so this is a WRONG-ANSWER defect rather than a
destructive one. It is still the same selection defect in the same directory as
the operation that caused the original damage. **Convert it to
`target_select.tcl` and give `fk33_powercycle.sh` the target variables.**

## Still open

- Whether card 1's flash is genuinely empty. Being tested by reading it out and
  letting `check_flash_backup.py` judge; a rejection IS the evidence.
- **Card 2's factory backup is VERIFIED GOOD**: two independent readbacks are
  byte-identical (`dcb97432538b9c7d2855b1d9c93658f7`) and copies exist on two
  physical disks (`/dev/nvme1n1p6` and `/dev/nvme0n1p1`). Note
  `hw/fk33/bit/` is gitignored, so the `/mnt/storage/fk33-factory-backups/`
  copy is the one under protection. Nothing is off-box.

---

## ROOT CAUSE, 2026-08-30: card 1's flash has a 7.85 MiB erased hole

**The answer, up front: card 1's SPI flash contains a factory image whose middle
was erased and never rewritten. The FPGA therefore cannot configure at power-on,
DONE never asserts, no PCIe endpoint exists inside the ~100 ms PERST window, and
the BIOS hides the root port. Every observation of 2026-08-30 follows from this
single fact.**

MEASURED, `flash.sh --backup` against `153300000607A` (target confirmed in the
log, not assumed), largest run of erased bytes INSIDE the used region:

```
card1_readback_2026-08-30.bin          used=27038696  longest 0xFF run inside = 8230124 bytes at 0x3D0000
fk33_factory_backup_153300001366.bin   used=26999096  longest 0xFF run inside =   52744 bytes at 0x19831F8
```

**7.85 MiB gone from card 1, starting at `0x3D0000`.** Card 2's 52,744 bytes is
ordinary inter-section padding. The erase aborted partway: the header survived,
the tail survived, the body did not. Consistent with the recorded incident in
which an agent aimed a flash operation at the wrong target.

Corroborating: card 1's image differs from card 2's factory image in **80.26% of
bytes** and matches none of `bit/*.mcs`, while their first 0x50 bytes are
byte-identical (`0000 00bb 1122 0044` bus width, `aa99 5566` sync, then
`3003 e001 0000 026b`).

## THE GUARD PASSED, AND IT IS THE ONE GUARD THAT MATTERS

`check_flash_backup.py` reported:

```
  sync word   AA995566 at offset 0x000050
BACKUP_CHECK_OK: this looks like a genuine flash image.
```

**about an image with 7.85 MiB missing.** `flash.sh`'s own header explains the
design intent -- *"an all-0xFF or all-0x00 readback is a FAILED READ that
produces a plausible 32 MB file. check_flash_backup.py looks for the Xilinx sync
word instead of trusting the file's size"* -- and that reasoning is correct for a
WHOLLY failed read. It has no coverage of a PARTIAL one, and a partial erase is
the failure this project has actually experienced.

The sync word lives in the first 0x50 bytes. **Any image with an intact header
passes, whatever happened to the body.** This is the dominant defect class here:
the check had never been shown to discriminate on the thing it guards.

**FIX, not yet applied:** add a largest-internal-0xFF-run test to
`check_flash_backup.py` and fail above a threshold (card 2's legitimate maximum
is 52,744 bytes; card 1's defect is 8,230,124 -- two orders of magnitude apart,
so the threshold is not delicate). **Teeth-check it against
`card1_readback_2026-08-30.bin`, which is a real, non-synthetic instance of the
defect** and should be kept for exactly that purpose.

## What this makes true

- **Nothing of value remains in card 1's flash.** It cannot configure the FPGA.
  Writing to it therefore risks nothing that is not already lost -- an asymmetry
  that does not apply to any other flash operation on this project.
- **Card 2's image must still not be written to card 1 casually.** It is the
  only surviving SQRL image and card 1 does not need it: our own endpoint
  bitstream in flash opens the port just as well, and is rebuildable.
- **The 100 ms window can only be met from flash.** JTAG cannot, which is why
  two warm reboots failed and why no host-side action can substitute.

## Still open

- Whether our own endpoint bitstream, written to card 1's flash, configures and
  trains inside the window. Untested; it is the next experiment.
- What card 1's flash held before the erase. Unknowable now.
- `potlatch.tcl` bare-index target selection, and `fk33_powercycle.sh` taking no
  target variable. Both must be fixed BEFORE any flash write, since wrong-target
  selection is the mechanism that caused this damage.
