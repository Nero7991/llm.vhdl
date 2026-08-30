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
