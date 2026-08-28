# The host-side diagnostic tooling mis-diagnosed the first FK33 fit

**Date:** 2026-08-28.
**Repository:** `llama.vhdl`, branch `fpga`. All work is in `hw/fk33/host/`.
**Hardware:** SQRL FK33 (`xcvu33p-fsvh2104-2L-e`, ES1 die) in a Gigabyte
Z790 AERO G, BIOS F12, kernel 6.8.0-138-generic.
**Scope:** host scripts only. No FPGA build was run and no JTAG was touched.

## 1. The question, verbatim

> Fix the host-side diagnostic tooling that mis-diagnosed the first fit.
>
> **Defect 1** -- `fk33_go.sh` mis-diagnoses a card swapped into an OCCUPIED
> slot. It looks for a root port that was EMPTY in the baseline and became
> OCCUPIED. The FK33 was swapped into `0000:00:1c.4`, which had held an
> RTX 3090, and after the fit that bridge is absent from config space entirely.
> So the tool guessed root port `00:1c.0`, measured the WRONG port in stages B,
> C and D, and reported "no root port appeared or changed state since the
> baseline ... points at power or seating, not at the bitstream. Check the
> 6-pin aux lead and reseat" -- after its own stage A had already passed on
> card power. Also: stage D prints `sudo sh -c 'echo 1 > /sys/bus/pci/rescan'`
> as its remedy, which is useless when there is no bridge to scan behind.
>
> **Defect 2** -- an unverified port-to-connector table. `fk33_pcie_check.sh`
> describes `0000:00:1c.0` as the only free port. It is not a card slot. That
> mistake cost a power cycle. Make the tooling derive the mapping, and say
> "unknown" rather than guess. `dmidecode` needs root and this user does NOT
> have passwordless sudo.
>
> **Defect 3** -- a failed JTAG-AXI read reports as `-1`, not as an error. Any
> script that string-compares the result concludes "the AXI path answered with
> the wrong value" when in fact it never answered at all.
>
> **Defect 4** -- the power-cycle latch is undocumented tooling. The VCCINT
> digital-pot wiper is volatile and resets to 128 on a power cycle, retaining
> its set value across a warm reboot. Surface it as a first-class check.

Symptom numbers from the first fit: baseline recorded
`BRIDGE 0000:00:1c.4 16.0GT/sPCIe 4 2.5GT/sPCIe 4 6 2`; after the fit that BDF
is absent from config space. Latch readings: `wiper=64 VCCINT=0.7203 V` after a
warm reboot, `wiper=128 VCCINT=0.6786 V` after a power cycle.

## 2. The answer, up front

All four defects were real, all four are fixed, and every fix is now covered by
a test that fails when the fix is reverted. The root cause common to defects 1,
2 and 3 is the same: **the tooling rendered a FAILED observation as a VALUE**
(a vanished bridge as "nothing changed", a guessed connector as a fact, a
failed AXI transaction as the number -1, and -- found during this work -- an
absent driver symlink as a driver named `driver`). Each now has its own
verdict, distinct from the value it used to be confused with.

Two things were also learned that change the original brief: `dmidecode -t slot`
is **not** the authority the handoff assumed for slot width or designation on
this board (section 6), and the FK33 **is currently enumerated** on this machine
(section 5).

## 3. The procedure, and what each probe isolates

Order matters: each step isolates one thing, and the later steps depend on the
harness the earlier ones built.

1. **Reproduce the wrong answer against the live machine.**
   `./fk33_go.sh` with the existing `host/pci_baseline.txt` in place. The
   machine is still in the interesting state: the baseline holds `00:1c.4` and
   `00:1c.4` is gone today. Isolates "is the defect real and still present"
   from "was it a one-off misreading".

2. **Build a synthetic sysfs so the diff can be exercised without hardware.**
   `FK33_SYSFS` relocates `bus/pci/devices`, `bus/pci/slots` and
   `bus/usb/devices`. Entries are symlinks into a `devices/` hierarchy exactly
   as the kernel presents them, so `kids()` and the endpoint-parent lookup
   traverse the same way. Isolates the diagnosis logic from the machine's
   current state, which is the only way the vanished-bridge case can be
   regression-tested at all. A diagnosis testable only by refitting hardware is
   a diagnosis that never gets tested.

3. **Write the failing cases FIRST, including the ones that already worked.**
   `tests_hostdiag.sh` has seven cases. Case 1 is the regression. Cases 2, 3, 4
   are situations the tool handled correctly and must continue to. Case 5 is
   "genuinely nothing moved", where the old wording was right and had to
   survive. Case 6 is the negative control: an occupied port that merely
   retrained must NOT be mistaken for the card's port. Isolates a fix from a
   different wrong answer.

4. **Make stage A pass in every synthetic case.** Deliberate: the original
   wrong verdict said "check the 6-pin aux lead" while stage A had already
   proven card power. If the fixture did not prove power, the test would not
   reproduce the contradiction that made the verdict obviously wrong.

5. **Derive the connector mapping instead of asserting it**
   (`fk33_slotmap.sh`), with three states -- has an entry / not confirmed /
   unknown -- and a capture-file path so root is never required at runtime.
   Isolates "we know" from "we do not know", which is the distinction the
   deleted comment table destroyed.

6. **Cross-check the SMBIOS capture against reality before trusting it.**
   This is the step that saved the whole exercise. See section 6.

7. **Classify the latch, not the raw wiper** (`fk33_powercycle.sh`). The wiper
   alone is ambiguous, so the classifier compares it against a stamped
   `boot_id` + wiper pair. Isolates "power was interrupted" from "the latch was
   never armed", which a bare wiper value cannot do.

8. **Prove the pot cannot be driven past the sanctioned point**
   (`tests_fk33ctl.py`), by sweeping all 256 wiper values through
   `pot_write` and asserting the minimum accepted is exactly 68.

## 4. The evidence, as raw captured output

### Defect 1, BEFORE and AFTER

The `--diff` view did not exist before. Against the real baseline, on the real
machine, it now reports both directions:

```
$ ./fk33_go.sh --diff
baseline: /home/orencollaco/GitHub/llama.vhdl/hw/fk33/host/pci_baseline.txt
taken:    -- 2026-08-27T21:25:45-06:00 -- kernel 6.8.0-138-generic

  GONE   0000:00:1c.4  was max 16.0GT/sPCIe x4, current x4, 2 device(s)
         the BRIDGE ITSELF is no longer in config space
  NEW    0000:00:1d.0  max 16.0GT/sPCIe x4, current x4, 1 device(s)
```

**BEFORE**, reconstructed exactly (the card gone from `1c.4`, nothing
enumerated, stage A passing on power). This is the text the first fit acted on:

```
  PASS  A    FT2232H 'SQRL FK' serial 153300000607 -- the card has power
  FAIL  B    no root port appeared or changed state since the baseline
      Nothing moved at all: no new bridge, no width change, no
      presence-detect flip.  ...  Nothing appearing therefore points at
      power or seating, not at the bitstream.  Check the 6-pin aux lead
      and reseat.
      assuming root port 0000:00:1c.0: it is the ONLY port that was
      empty in the baseline.
      0000:00:1c.0  capability: 8.0 GT/s PCIe x1   current: 2.5 GT/s PCIe x0
  FAIL  C    width x0 -- LINK TRAINING FAILED
  FAIL  D    no 10ee:9034 and no 1e24 subsystem in lspci
      The card was JTAG-configured after boot, so the kernel has not
      looked since.  Rescan, then re-run this script.  ROOT:
          sudo sh -c 'echo 1 > /sys/bus/pci/rescan'
          sudo setpci -s 0000:00:1c.0 BRIDGE_CONTROL=40:40 ; sleep 1
```

Three separate wrong statements: a power/seating verdict contradicting stage A;
stages C and D measuring `00:1c.0`, a port the card was never in; and two root
commands that cannot work.

**AFTER**, same fixture (`tests_hostdiag.sh` case 1):

```
  PASS  A    FT2232H 'SQRL FK' serial 153300000607 -- the card has power
      baseline diff (every bridge, both directions):
    GONE   0000:00:1c.4  was max 16.0GT/sPCIe x4, current x4, 2 device(s)
           the BRIDGE ITSELF is no longer in config space
  FAIL  B    a root port that existed in the baseline is GONE from config space
        vanished: 0000:00:1c.4 -- was max 16.0GT/sPCIe x4, current x4, 2 device(s) behind it
        slot behind 0000:00:1c.4: YES -- the BIOS lists a physical connector on this port
        So the SLOT IS NOT THE FAULT: the BIOS itself lists a physical
        connector on this port.  Do not move the card looking for a
        better slot; the card is already in a legitimate one.

      READ THIS BEFORE TOUCHING THE CARD.  This is NOT a power or seating
      fault and reseating will not change it.  An unpowered or unseated
      card cannot remove a bridge from config space; only the firmware
      can.  ...  It is self-sustaining.

      What this does and does not prove:
        PROVES   the firmware saw no link train on that port during POST.
        DOES NOT prove the card is dead, unpowered, unseated, or that the
                 bitstream is wrong.  Stage A above is the power evidence;
                 if it passed, power is not the question.

  FAIL  C    the card's root port is not in config space, so there IS no link state
      0000:00:1c.4 existed in the baseline and does not exist now.  ...
      Deliberately NOT falling back to some other port: measuring a port
      the card is not in is how the 2026-08-28 fit was mis-diagnosed.

  FAIL  D    no 10ee:9034 and no 1e24 subsystem in lspci
      DO NOT RESCAN.  It cannot work here and it is not worth trying.
      A rescan enumerates devices behind a bridge, and the card's
      bridge (0000:00:1c.4) is not in config space at all.  ...
      For the same reason setpci cannot reassert PERST: you cannot
      setpci a function that does not exist.

 -> FIRMWARE.  The root port 0000:00:1c.4 is GONE from config space.
    Not a seating or power fault: only the BIOS can remove a bridge.
```

The negative controls still pass, which is the part that makes this a fix
rather than a different wrong answer:

```
$ ./tests_hostdiag.sh
CASE 1  the 2026-08-28 regression ...
CASE 2  the case that ALREADY worked: a brand new root port appears ...
CASE 3  a new root port appears but NOTHING enumerates behind it:
        the port is visible, so a rescan IS the right remedy
CASE 4  the ORIGINAL design case: a card added to a port that was EMPTY ...
CASE 5  genuinely NOTHING moved ...
CASE 6  an occupied port whose width merely RETRAINED ...
CASE 7  the driver symlink ...
FK33_HOSTDIAG_TESTS OK
```

Case 3 is the one that stops the fix over-reaching: with the port VISIBLE, the
rescan and `setpci` remedies are still printed, because there they work.

### Defect 2

The comment table was deleted, not corrected. Live output with the real
capture, on the real machine:

```
$ ./fk33_slotmap.sh
=== which root ports have a physical card slot behind them ===
source: cached capture .../host/dmidecode_slots.txt  (5 System Slot records)
NOTE: fields inside a type 9 record (Designation, Type, Length,
    Current Usage) are unreliable vendor boilerplate on this board and are
    deliberately not reported.  Only the presence of an entry is used.

  PORT           SLOT ENTRY             IN CONFIG SPACE NOW
  0000:00:01.0   YES, a connector       present, 2 device(s)
  0000:00:1c.3   YES, a connector       ABSENT -- port hidden by the BIOS
  0000:00:1c.4   YES, a connector       ABSENT -- port hidden by the BIOS
  0000:00:1c.5   YES, a connector       ABSENT -- port hidden by the BIOS
  0000:00:1c.6   YES, a connector       ABSENT -- port hidden by the BIOS
  0000:00:01.1   not confirmed          present, 1 device(s)  <- table is incomplete here
  0000:00:06.0   not confirmed          present, 1 device(s)  <- table is incomplete here
  0000:00:1c.0   not confirmed          present, 0 device(s)
  0000:00:1c.2   not confirmed          present, 1 device(s)  <- table is incomplete here
  0000:00:1d.0   not confirmed          present, 1 device(s)  <- table is incomplete here
```

With no capture at all it degrades to a stated non-answer and the exact root
command, and never blocks on a password:

```
$ FK33_DMI=/nonexistent ./fk33_slotmap.sh --lookup 0000:00:01.0 ; echo rc=$?
slot behind 0000:00:01.0: UNKNOWN -- no SMBIOS slot capture available
  Nothing here can say whether this port has a physical connector.
  run:  sudo dmidecode -t slot > .../host/dmidecode_slots.txt
rc=3
```

`00:1c.0`, the port the first attempt moved the card to:

```
$ ./fk33_slotmap.sh --lookup 0000:00:1c.0 ; echo rc=$?
slot behind 0000:00:1c.0: NOT CONFIRMED -- no SMBIOS System Slot entry names this port
  This is WEAKER evidence than a YES, not its mirror image ...
  Do NOT move a card here on this evidence alone.  Corroborate first:
      sudo lspci -vv -s 00:1c.0 | grep -E 'SltCap|SltSta'
rc=1
```

Exit 1 (not confirmed) and exit 3 (unknown) are asserted distinct, so a missing
capture can never read as "not a slot".

### Defect 3

```
$ ./fk33_powercycle.sh --selftest
--- DEFECT 3: a failed AXI read is -1 and must NOT read as a value
    ok   axi_dead is its own verdict, not a wrong wiper
    ok   a dead AXI path yields NO power verdict at all
    ok   says -1 is a failed transaction, not data
    ok   link down and genuine value mismatch are distinct messages
--- DEFECT 3: a pot NACK (-1 wiper on a LIVE bus) is distinct again
    ok   pot NACK is not the same as a dead AXI path
    ok   explicitly separates the two -1 sources
```

There are three distinct `-1`-ish conditions, and they now produce three
different messages: the AXI path never answered; the AXI path answered but the
pot NACKed; and the AXI path answered with data that is not what was expected.
Only the last is a value mismatch.

In `fk33ctl.py`, over MMIO the same failure surfaces as `0xFFFFFFFF` or
`0x00000000`, routed through one classifier:

```
$ python3 tests_fk33ctl.py
    ok   all-ones says NOT A VALUE
    ok   -1 is classified the same as all-ones
    ok   all-ones does NOT claim a bitstream mismatch
    ok   all-zeroes names reset/unclocked, not a mismatch
    ok   a genuine wrong value IS called a mismatch
    ok   the three cases produce three different messages
    ok   magic 0xffffffff does not say 'not this bitstream'
```

**Same defect found in a fourth place, and fixed.** On the live machine, stage F
reported:

```
  WARN  F    0000:06:00.0 bound to 'driver', not xdma
      ROOT:  echo 0000:06:00.0 | sudo tee /sys/bus/pci/drivers/driver/unbind
```

There is no driver called `driver`. `readlink -f` resolves a path that does not
exist, so an ABSENT symlink produced the literal string `driver`. Same family:
a failed lookup rendered as a value, with a root command pointing at a
nonexistent sysfs path. Fixed by testing the symlink with `-L`. After:

```
  FAIL  F    0000:06:00.0 has no driver bound
```

### Defect 4

```
$ ./fk33_powercycle.sh --selftest
--- DEFECT 4: the real 2026-08-28 measurements must classify correctly
    ok   warm reboot: boot changed, wiper still 64
    ok   power cycle: boot changed, wiper back to 128
--- DEFECT 4: the ambiguous cases must say so, not guess
    ok   wiper 128 before AND after: the latch was never armed
    ok   no stamp at all: baseline only, no verdict claimed
--- DEFECT 4: same boot means no reboot happened
    ok   same boot_id, same wiper
    ok   same boot_id, wiper reset: power lost without a reboot
    ok   same boot_id, wiper stepped: not a power event
--- END TO END through the real entry point, with a stubbed reader
    ok   end to end: warm reboot verdict, and the stamp is updated
    ok   the new reading was stamped
    ok   end to end: a dead AXI path exits 3 with its own message
    ok   a FAILED read did not overwrite the stamp
    ok   no POTLATCH line at all is called a tooling failure,
         explicitly not evidence about the card
```

The two rows fed to the classifier are the measured values from the handoff
verbatim (`wiper=64 / 0.7203 V` and `wiper=128 / 0.6786 V`), so the tool is
tested against the real readings rather than invented ones.

### Safety: the VCCINT ceiling

```
$ python3 tests_fk33ctl.py
    ok   W_FLOOR is 68
    ok   pot_write(0) refused
    ok   pot_write(59) refused
    ok   pot_write(60) refused      <- the OLD floor, now refused
    ok   pot_write(64) refused
    ok   pot_write(67) refused
    ok   pot_write(68) accepted
    ok   pot_write(128) accepted
    ok   the lowest writable wiper is exactly 68
```

`W_FLOOR` was 60 and is now 68 (~0.717 V), enforced inside `I2C.pot_write`
rather than in the stepping loop, so no future caller can route around it. The
sweep over all 256 values is the proof that 68 is the true minimum by every
path, not just the intended one. `potlatch.tcl` has no pot write at all, and
that is asserted mechanically against a deliberately poisoned copy of itself.

One behaviour change follows from the floor: running out of sanctioned travel
now STOPS at wiper 68 instead of reverting to 128. Reverting would put the rail
back to ~0.678 V, below the 0.698 V -2L floor, which is strictly worse than
stopping at 68, which is already in spec.

## 5. Unexpected finding: the FK33 IS enumerated right now

Not asked for, and it contradicts "no FK33 has still ever enumerated" in the
handoff, so it is recorded here rather than buried.

```
$ lspci -Dnn | grep -i squirrel
0000:06:00.0 Serial controller [0700]: Squirrels Research Labs ForestKitten 33 [1e24:1533] (rev a3)

$ cat /sys/bus/pci/devices/0000:00:1d.0/{max_link_speed,max_link_width,current_link_speed,current_link_width}
16.0 GT/s PCIe
4
8.0 GT/s PCIe
4
```

A card is trained at **Gen3 x4** behind `0000:00:1d.0`, a root port that did not
exist in the pre-fit baseline, with BARs placed. The device ID is `1e24:1533`,
not our `10ee:9034`, so this is **the factory image out of the card's SPI
flash**, not `fk33_pcieep.bit`.

Why it matters, and it is not a small point: it demonstrates on this exact
board that a flash-booted FK33 configures inside the ~100 ms PCIe window, trains
a link, and is enumerated by this BIOS. The SPI-flash route the handoff proposes
is therefore not merely plausible; the mechanism is observed working on this
hardware. It also gives the endpoint work a positive control -- a known-good
enumeration to compare against.

Not established: nothing here says `fk33_pcieep.bit` will train. That is still
open.

## 6. Measured and REJECTED -- do not retry

- **Reading slot width or silk-screen name out of `dmidecode -t slot`.**
  This was the brief's own recommended authority and it is WRONG on this board.
  It reports `0000:00:1c.4` as `Type: x1 PCI Express, Length: Short`, and that
  port demonstrably ran a Gen4 x4 RTX 3090 with the baseline recording
  `16.0GT/sPCIe 4 ... 2 children`. All five records claim
  `Current Usage: In Use`, which cannot be true. It lists exactly one x16 slot
  where the board has three x16-length connectors. The designations
  `J6B2 / J6B1 / J6D1 / J7B1 / J8B4` are Intel customer-reference-board names,
  not Gigabyte silk screen. **Do not surface any of these fields.** The tool
  asserts mechanically that none of them leaks into its output.

- **Treating "no type 9 entry" as proof a port is not a card slot.**
  Rejected on live evidence during this work. `0000:00:1d.0` has no entry and
  has an FK33 enumerated behind it right now. The table is incomplete, so
  absence is weak evidence and presence is strong. An earlier draft of
  `fk33_slotmap.sh` printed "NO -- not a card slot"; that was a new wrong
  answer of the same shape as the original defect and was withdrawn before
  being committed. The tool now says "not confirmed", and marks any row where
  an enumerated device contradicts the table.

- **Keeping a corrected comment table in `fk33_pcie_check.sh`.** Rejected: the
  defect was the FORM, not the contents. A comment cannot be cross-checked,
  ages silently, and carries identical authority whether it was measured or
  guessed. Deleted and replaced by a derivation.

- **Keeping the "only one empty port in the baseline, so assume it" fallback
  unconditional.** That fallback is what silently substituted `00:1c.0` and
  made stages C and D measure the wrong hardware. It is retained, because when
  nothing vanished it is genuinely the most informative reading available, but
  it is now suppressed whenever a bridge vanished (the card's port is then
  KNOWN, not guessable) and whenever the candidate is not in config space.

- **Reverting the wiper to 128 when the floor is reached.** Rejected: 128 is
  ~0.678 V, below the 0.698 V -2L floor, so the "safe" action was leaving the
  die further out of spec than stopping would. Now stops at the floor.

- **Running the JTAG path to validate `potlatch.tcl` on hardware.** Deliberately
  NOT done. Other agents own the FPGA-side instrumentation and the SPI flash
  path in this session, `jtag.sh` kills `hw_server` and resets the FTDI, and the
  card is currently enumerated. Validating a diagnostic by disturbing the thing
  another agent is measuring is not validation. `potlatch.tcl` is therefore
  UNVERIFIED against hardware; see section 8.

## 7. Measurement traps hit, including our own

- **Ours: the `dmidecode` trap above.** The handoff said "the authoritative
  mapping is `sudo dmidecode -t slot`, which was never run", and building the
  fix on a naive reading of it would have replaced a wrong hardcoded table with
  a wrong derived one, wearing the authority of a measurement. The trap is that
  the data LOOKS authoritative: it is structured, it comes from the BIOS, and
  it is not obviously boilerplate until cross-referenced against a port whose
  real width is independently known. **Cross-reference any SMBIOS field against
  something already measured before trusting it.**

- **Ours: a test harness bug that made every case report the same wrong thing.**
  `classify()` reads `$STAMP`, resolved once at script load. The selftest tried
  to repoint it with an env prefix (`FK33_POT_STAMP=... classify ...`), which
  does nothing, so every case fell through to "BASELINE ONLY". It was caught
  only because the expectations asserted an exact exit code and an exact
  substring per case. **Loose expectations would have shown a green selftest
  over a classifier that was never exercised.** Assert the specific verdict,
  never merely "it printed something".

- **Ours: a safety check that passed for the wrong reason.** The assertion that
  `potlatch.tcl` never writes the pot was first written as a single-line grep,
  but `create_hw_axi_txn` spans several lines, so it inspected fragments. It is
  now an awk that joins the whole command, AND it is run against a deliberately
  poisoned copy of the file to confirm it fires. A guard never seen to fail is
  not a guard.

- **A comment naming a forbidden thing trips a grep for that thing.** The
  "no pot_write here" comment in `potlatch.tcl` failed the "contains no
  pot_write" check. Strip comments before grepping for code properties, or the
  documentation of a safety property breaks the test of it.

- **`readlink -f` succeeds on paths that do not exist.** This is what produced
  the phantom driver named `driver`. Test the symlink with `-L` before
  resolving. The general form is the whole theme of this session: a failed
  lookup must never be rendered as a value.

- **The live machine is not in the state the brief describes.** The brief says
  the card "may not be powered and is NOT enumerated". It is powered and it IS
  enumerated (section 5). Every fix was therefore tested against synthetic
  topologies as well as the live one, because the live state can no longer
  reproduce the failure. Do not rely on the machine being in the interesting
  state.

## 8. Open, not yet answered

- **`potlatch.tcl` is not verified against hardware.** Its classifier, its
  argument plumbing and its safety properties are tested; the Tcl itself has
  never been executed. Specifically unverified: whether `report_hw_axi_txn`
  returns the token format the numeric conversion assumes, and whether the
  `-1` probe fires in the way `tcl/pcieep_jtag.tcl` observed. The wrapper fails
  safe (a missing or unparsable `POTLATCH` line is reported as a TOOLING
  failure and explicitly not as evidence about the card), but the first real
  run should be watched. Run it with the PROBE bitstream loaded.
- **`tcl/vccint_step.tcl` still carries `W_FLOOR 60`.** Out of scope this
  session (another agent owns `hw/fk33/tcl/*`), so the JTAG path remains the
  looser of the two. Raise it to 68 there.
- **Which physical Gigabyte connector each root port is** remains genuinely
  unknown. SMBIOS answers only "does a connector exist", and its designations
  are reference-board names. Settling it needs the board manual or a look at
  the silk screen.
- **Whether `fk33_pcieep.bit` trains a link**, given the chance section 5 shows
  the flash path provides.
- **Whether `00:1d.0` is a card slot, an M.2 adapter, or a riser.** Something
  is enumerated behind it and SMBIOS does not name it.

## 9. Files

New, all in `hw/fk33/host/`:

| file | purpose |
|---|---|
| `fk33_slotmap.sh` | derives the port-to-connector claim from SMBIOS; says unknown otherwise (defect 2) |
| `fk33_powercycle.sh` | the power-cycle latch as a first-class check (defect 4) |
| `potlatch.tcl` | read-only JTAG read of the pot wiper; never writes it |
| `dmidecode_slots.txt` | the real capture, so the tooling needs no root at runtime |
| `tests_hostdiag.sh` | seven synthetic topologies, including the regression (defect 1) |
| `tests_fk33ctl.py` | wiper floor and the -1 classifier (defect 3, safety) |

Modified: `fk33_go.sh` (defect 1, the driver symlink, `--diff`, `FK33_SYSFS`),
`fk33_pcie_check.sh` (defect 2, no hardcoded default port),
`fk33ctl.py` (defect 3 classifier, wiper floor 60 -> 68).

Everything is wired into `./fk33_go.sh --selftest`, which needs no card:

```
$ ./fk33_go.sh --selftest
=== 2b. the host DIAGNOSTIC tooling, against synthetic topologies ===
  ok      tests_hostdiag.sh
  ok      fk33_slotmap.sh --selftest
  ok      fk33_powercycle.sh --selftest
  ok      tests_fk33ctl.py
...
FK33_GO_SELFTEST OK -- everything testable without a card passes.
```
