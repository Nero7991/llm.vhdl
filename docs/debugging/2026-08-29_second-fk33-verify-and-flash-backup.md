# Verifying the second FK33 and backing up its factory flash

Date: 2026-08-29.  Hardware: SQRL FK33 `xcvu33p-fsvh2104-2L-e`, serial
**153300001366** ("card 2", eBay, unknown provenance), on USB JTAG and **ATX
PCIe aux power only -- NOT in a slot**.  Card 1 (serial 153300000607) remained
attached and powered throughout.

## The question, verbatim

> "Plugged in the second FK33 with USB JTAG and PCIe power for working
> verification (eBay buy)" ... "And it's a good idea dumping it's bitstream
> (since we don't ahve that)"

and, on being told VCCINT reads 0.677 V:

> "Wait then how do we know that it's at the lower voltage?"
> "I eman for the new card, it's factory flash might have the correct volatge,
> let's back up directly"

## The answers, up front

1. **Card 2 works.**  It self-configured from its own SPI flash at power-on:
   `CFG_DONE 1`, DONE pin and DONE internal both 1, over-temp alarm 0, every
   BOOT_STATUS error bit clear.
2. **The SQRL factory image does NOT raise VCCINT.**  Card 2 was measured at
   **0.677 V** while running that image with DONE=1.  This had never been
   observable before, because card 1's factory image was destroyed.
3. **VCCINT was NOT raised before the backup**, on the operator's instruction.
   The voltage gate guards a *hypothesis* (that a low-VCCINT readback may be
   quietly wrong).  That hypothesis is testable rather than assumable, so it is
   tested by re-reading and comparing, not by asserting the gate.
4. **`jtag.sh` reset the WRONG CARD's FTDI**, silently, regardless of
   `FK33_TARGET`.  Root-caused and fixed.  See below.
5. **The ES1 revision check DID block the Xilinx programmer bitstream**, and
   `xicom.skip_bitstream_compatibility_check 1` waived it.  MEASURED, where the
   code had only documented it as expected.

## The procedure, in the order it was run

Each step isolates one thing; the control at every stage is card 1, which is
the same board revision in a known state.

| # | Probe | What it isolates |
|---|---|---|
| 1 | `flash.sh --status`, no selector | Whether the new target guard refuses to guess with 2 cards attached |
| 2 | `flash.sh --status`, `FK33_TARGET=...1366A` | Card 2's configuration state, temperature, rails |
| 3 | `vccint_step.tcl` on card 2 | Whether the pot is reachable -- it is not, and WHY is the finding |
| 4 | SYSMON path audit (JTAG DRP vs AXI) | Which path produced the 0.677 V, i.e. is that number trustworthy |
| 5 | `flash.sh --backup` | The image itself |
| 6 | sysfs FTDI enumeration | Root cause of the wrong-card USB reset |

## Evidence

### Identification is certain from three independent signals

| | card 2 (`153300001366`) | card 1 (`153300000607`) |
|---|---|---|
| USB enumeration | devnum **19**, later | devnum 10 |
| JTAG tree | bare `xcvu33p` | Debug Hub + 3x JTAG2AXI |
| VCCINT | **0.677 V** (power-on default) | 0.715 V (raised earlier) |
| die temp | **27.7 C** | 41.6 C |

### The target guard fired correctly on real hardware

`tcl/target_select.tcl`, added earlier the same day, refused with no selector:

```
CFG_NO_TARGET: REFUSING TO GUESS: 2 JTAG targets are present and FK33_TARGET is not set.
         [0] localhost:3121/xilinx_tcf/Xilinx/153300001366A
         [1] localhost:3121/xilinx_tcf/Xilinx/153300000607A
```

### Card 2 self-configured from its own flash, undervolted

```
CFG_DONE 1
CFG_SYSMON TEMP=27.7 VCCINT=0.677 VCCAUX=1.828
CFG_WIPER cold: VCCINT 0.677 V is the power-on default (wiper 128).
          This WAS a cold boot and nothing has raised VCCINT since.
```

This is the positive control this project has never had.  The configuration
time budget sits in the docs as a DERIVED ~225.7 ms against a ~200 ms window,
an assertion nobody could test once card 1's factory image was gone.  Card 2
configures from the same flash part at 0.677 V, so the budget is not violated
in practice at the factory image's size.

### `vccint_step.tcl` cannot run on a bare device, and that is not a fault

```
WARNING: [Labtoolstcl 44-227] No matching hw_axi_txns were found   (x28)
ERROR:   [Labtoolstcl 44-228] Required <hw_axi_txns> argument is empty.
```

There are **two independent SYSMON access paths** and they must not be
confused:

* `tcl/flash_common.tcl:67` `fk33_vccint` -- **JTAG DRP**.  Needs no design, no
  design clock, no AXI.  Works on a bare device.  *This is what produced the
  0.677 V.*
* `tcl/vccint_step.tcl:93` `vccint` -- reads `rdreg 3404`, SYSMON mapped into
  **AXI** address space by the i2cprobe design.  Needs a JTAG-AXI master.

Card 2 runs the factory image, which contains no JTAG-AXI master, so
`get_hw_axis hw_axi_1` returned empty and all 28 accesses were no-ops.  The
digital pot is likewise only reachable over that AXI path, so raising VCCINT
requires first overwriting the running factory configuration in SRAM.  That is
reversible -- the wiper is volatile and the flash is untouched, so a power
cycle restores factory configuration -- but it is not free, and it was skipped.

### The ES1 revision check, MEASURED

```
attempt with xicom.skip_bitstream_compatibility_check = 0
ERROR: [Labtools 27-3303] Incorrect bitstream assigned to device. Bitstream was
generated for part xcvu33p-fsvh2104-1-e, target device (with IDCODE revision 0)
is compatible with es1 revision bitstreams
  load failed: ERROR: [Common 17-39] 'program_hw_devices' failed due to earlier errors.

attempt with xicom.skip_bitstream_compatibility_check = 1
program_hw_devices: Time (s): cpu = 00:00:04 ; elapsed = 00:00:05
FLASH_REVCHECK_BIT: the ES1 revision check DID block the load;
  xicom.skip_bitstream_compatibility_check 1 waived it.
```

### Flash part identification

```
Mfg ID : 20   Memory Type : bb   Memory Capacity : 19
```

Micron (0x20), 1.8 V (0xbb), 256 Mbit = 32 MB (0x19).  Matches the
`mt25qu256` single-device cfgmem entry the scripts already use.

## Root cause: `jtag.sh` reset the wrong card's FTDI

`jtag.sh` recovers a stuck cable with a `USBDEVFS_RESET` before every run.  It
picked the device like this:

```python
m = re.search(r'Bus (\d+) Device (\d+): ID 0403:6010', out)
```

`re.search` returns the **first** match.  With two FK33s attached, every run
reset whichever card enumerated first, **no matter what `FK33_TARGET` said**.

MEASURED: a backup correctly bound at the Vivado layer to `153300001366A`
printed `cable reset: /dev/bus/usb/001/010`, which is the *other* card.

This is the same defect class `tcl/target_select.tcl` removed one layer up,
sitting one layer lower, at USB.  It was invisible while only one card existed.

**Impact on this run: benign.**  `USBDEVFS_RESET` re-enumerates the FTDI USB
bridge only; it does not reconfigure the FPGA and does not touch flash, and the
JTAG operations themselves were correctly bound to card 2 by `target_select.tcl`
(verified: `JTAG target: localhost:3121/xilinx_tcf/Xilinx/153300001366A`).  A
reset landing on a card *mid-JTAG-transfer* would abort that transfer, so it is
not benign in general.

### The fix

Select by **serial** from sysfs, applying the same rule as `target_select.tcl`:
refuse rather than guess.  One FTDI, use it; more than one and no `FK33_TARGET`,
abort and print the list.  No fallback to "the first one" -- a fallback is what
makes the hazard silent.  sysfs rather than `lsusb -v` because
`/sys/bus/usb/devices/*/serial` is world-readable and carries busnum/devnum
alongside, whereas `lsusb -v` must open the device to read string descriptors.

### Teeth-check of the fix, all five cases

`FK33_USB_NORESET=1` reports the selection and stops, so the rule is testable
without resetting a cable that has a transfer in flight.

```
FK33_TARGET=153300001366A -> would reset /dev/bus/usb/001/019  (serial 153300001366)
FK33_TARGET=153300000607A -> would reset /dev/bus/usb/001/010  (serial 153300000607)
FK33_TARGET=<unset>       -> REFUSING TO GUESS: 2 FK33 FTDI devices present
FK33_TARGET=1533          -> FK33_TARGET=1533 matches 2 of 2 FTDI devices
FK33_TARGET=999999        -> FK33_TARGET=999999 matches 0 of 2 FTDI devices
```

Rows 4 and 5 are the ones that measure the check's resolution floor: an
ambiguous selector and an unmatched selector both refuse, rather than falling
through to a default.  Row 1 is the direct demonstration of the defect -- 019
where the shipped code chose 010.

## Measurement traps hit

**A bug caught by teeth-check, not by reasoning.**  The first version of the
fix matched one-directionally:

```python
hits = [d for d in devs if want in d['serial']]
```

sysfs reports the serial as `153300001366`, but the Vivado JTAG target name --
which is what `FK33_TARGET` is normally set to -- is `153300001366A`, with a
trailing letter sysfs does not carry.  So `want in serial` is **false**, and the
"fix" would have matched nothing and refused every run, on both cards, forever.
It looked obviously correct.  It was caught only by running all five cases
against real enumeration before shipping it.  Matching is now bidirectional.

**Two SYSMON paths that report the same quantity.**  Concluding "there is no AXI,
therefore we cannot know the voltage" would have been wrong: the voltage came
from the JTAG DRP path, which needs no AXI.  When a reading and a failure seem
to contradict, check whether they travelled the same path before reconciling
them.

**`.mcs` size is not flash size.**  The readback file passed 88 MB for a 32 MB
device.  Intel HEX is ASCII, roughly 2.8x expansion (about 45 characters per
16-byte record).  A file "too big for the part" is not evidence of anything.

## Measured and REJECTED -- do not retry

* **`vccint_step.tcl` against a card running the factory image.**  Fails with
  `Required <hw_axi_txns> argument is empty` after 28 no-op warnings.  There is
  no JTAG-AXI master in that image and therefore no route to the I2C pot.  To
  raise VCCINT you must first configure the i2cprobe bitstream, which overwrites
  the running factory configuration.  Not a card fault.
* **Raising VCCINT before backing up, as a precondition.**  Skipped
  deliberately.  It is not free (it destroys the running factory configuration,
  which is the only positive control we have) and the risk it mitigates is
  testable directly by re-reading the flash and comparing.

## Results of the backup

`BACKUP_OK` then `BACKUP_CHECK_OK`, twice, on two independent reads:

```
  decoded     33554432 bytes (32.00 MiB)
  0xFF bytes  6713365 (20.01%)
  0x00 bytes  107826 (0.32%)
  distinct    256 byte values
  sync word   AA995566 at offset 0x000050
  bus width   000000BB at offset 0x000040
  sync count  1
  last data   offset 0x19BF938 (25.75 MiB used)
```

### The low-VCCINT hypothesis, tested rather than assumed

The voltage gate exists because a readback taken below the 0.698 V floor "risks
being quietly wrong".  That is a hypothesis, and it is directly testable.  The
flash was read twice, independently, both at 0.677 V:

```
f8d2a6a0cc627647fe7b9c0f5836ce9075d01e304b81dfb5b0c352c66c445f7e  ..._153300001366.bin
f8d2a6a0cc627647fe7b9c0f5836ce9075d01e304b81dfb5b0c352c66c445f7e  ..._153300001366_read2.bin
```

**BIT-IDENTICAL.**  MEASURED, `sha256sum` and `cmp`.

**What this does and does not establish.**  It establishes that the readback at
0.677 V is REPEATABLE.  It does NOT by itself establish that it is CORRECT: a
systematic error in the read path at low VCCINT would appear identically in
both reads.  The independent support for correctness is structural -- canonical
bus-width sequence at 0x40, sync word at the canonical 0x50, 256 distinct byte
values, and a payload extent consistent with an uncompressed configuration
stream for this device -- plus the fact that the card demonstrably configures
from this flash.  A read path corrupted enough to matter would be unlikely to
yield a canonically structured bitstream twice.  Stated as: strong, not proof.

### What the image is

MEASURED, by scanning the decoded `.bin`:

* exactly **one** `AA995566` sync word, at 0x50
* exactly **one** `000000BB 11220044` bus-width sequence, at 0x40
* payload runs continuously to 0x19BF314, with only a 1572-byte `20000000`
  NOOP tail after it

So it is a **single configuration stream of 25.75 MiB**, not a golden plus
multiboot pair.

That is 2.2x our own `fk33_pcieep.bit` at 11.66 MiB for the same device.  The
reason is not a second image: `fk33_pcieep.xdc:132` and `fk33_i2cprobe.xdc:127`
both set `BITSTREAM.GENERAL.COMPRESS TRUE`, so **our** image is compressed and
25.75 MiB is the uncompressed size.  DERIVED.

**This strengthens finding 1 considerably.**  Card 2 loads 2.2x more
configuration data than our own image would, from the same flash part, at
0.677 V, and still reaches DONE=1 with every BOOT_STATUS error bit clear.  The
configuration-time budget that sits in the docs as a DERIVED ~225.7 ms against
a ~200 ms window is not violated in practice even at more than double our
image's size.  That budget concern should be re-examined against this
measurement rather than carried forward unchanged.

### Where the image is stored

`bit/` is gitignored, so the backup is NOT in version control.  Archived to
`/mnt/storage/fk33-factory-backups/` with `SHA256SUMS.txt` and a `README.txt`
carrying the caveat above.  `/mnt/storage/files` is owned by the `sftpgo` uid
and is not writable, hence `/mnt/storage` directly.

**This is the only copy of this image.**  Card 1's factory image was destroyed
and SQRL is the only other source.

## Open, not yet answered


* Whether a readback at 0.677 V matches one taken at 0.717 V.  ANSWERED only
  in part: two reads at 0.677 V agree bit-for-bit, but no read at 0.717 V has
  been taken, so the comparison ACROSS voltages is still untested.  Doing it
  costs one probe-bitstream load plus two minutes and would settle it.
* What the factory design DOES.  The image is structurally identified above,
  but not decoded: no design name is recoverable (the ASCII header exists only
  in the `.bit` wrapper, not in a flash image) and the configuration stream has
  not been disassembled.
* Whether card 2 trains a PCIe link.  It is on aux power only, not in a slot,
  so this run cannot say.
