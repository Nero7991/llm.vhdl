# FK33 first light: the endpoint always worked, and three tools said otherwise

## The question, verbatim

> **Status: no FK33 has still ever enumerated.** Nothing below establishes that
> the endpoint bitstream trains a link. It establishes that it has never been
> given the chance.
>
> -- `docs/2026-08-28_fk33-first-fit-handoff.md`, written earlier the same day

Date: 2026-08-28. Hardware: SQRL FK33, `xcvu33p-fsvh2104-2L-e` (ES1 die), in a
Gigabyte Z790 AERO G, BIOS F12, kernel 6.8.0-138-generic, Vivado 2023.2.
Bitstream under test: `hw/fk33/bit/fk33_pcieep.bit`, 12,227,950 bytes, built
2026-08-27 22:58:46. Symptom: no `10ee:9034` in `lspci`, ever.

## The answer, up front

**The endpoint bitstream trains a Gen3 x4 link with clean equalization and has
presumably always been able to.** It had never been loaded successfully at a
terminal, because `hw/fk33/tcl/program.tcl` had no success-path `exit` and
`xsdb` runs under `rlwrap`, which holds the terminal after the Tcl finishes; the
`timeout 300` that killed it reported 124, and `set -euo pipefail` turned that
into a silent abort of `pcieep.sh` **after `FPGA_PROG_OK` had already printed**.
The PCIe rescan that followed therefore tested a card holding
`fk33_i2cprobe.bit`, which contains no PCIe block at all.

## The procedure, in the order it was run

Each step is listed with what it controls for, because the order is the reusable
part.

1. **Ask what the root port is doing, not what the card is doing.** `lspci -tv`
   rather than `lspci | grep -i xilinx`. This is what found that the card was
   behind `0000:00:1d.0` and NOT `0000:00:1c.4`, which the handoff names
   throughout. `1c.4` is absent from config space because the RTX 3090 was
   removed from it, not because of anything the FK33 did. **Several of the
   original hidden-root-port measurements were taken against a port the card was
   not in.**

2. **Look for a device that is already enumerated before assuming none can be.**
   `lspci -nn | grep -i squirrel` returned
   `06:00.0 ... ForestKitten 33 [1e24:1533]` -- the SQRL FACTORY image, booting
   from the card's own SPI flash, at Gen3 x4 with BARs placed. That single line
   proves the PCIe configuration window is beatable on this board and this BIOS,
   which converts "can an FK33 ever enumerate here" into the much narrower
   "can OUR payload configure in time". It also makes `00:1d.0` a live, visible
   root port.

3. **Exploit the live root port.** The handoff's reasoning -- PCIe wants a
   trained link within ~100 ms of PERST# deassertion, JTAG configuration cannot
   meet it, so the host disables the port -- is sound for a COLD boot. It does
   not apply when a root port is already up. So: remove the PCI device, JTAG
   configure our bitstream, rescan.

       echo 1 | sudo tee /sys/bus/pci/devices/0000:06:00.0/remove
       cd hw/fk33 && ./pcieep.sh
       echo 1 | sudo tee /sys/bus/pci/rescan

   Fully reversible: a power cycle restores whatever is in flash. Costs nothing.

4. **Capture the exit code of every hardware script.** This is the step that
   actually solved it, and it was added only on the second attempt. `EXIT=124`
   is `timeout`; nothing else in the visible output said anything was wrong.

5. **Read the negotiated link, not just the presence of a device.** `LnkSta`
   with `(ok)` on both width and speed distinguishes "enumerated" from
   "enumerated at the width we asked for".

6. **Prove the datapath, not just the link.** One MMIO read of a fabric constant
   exercises refclk, PCIe user clock, `xdma/axi_aclk`, the AXI-Lite fabric and
   the register block in a single transaction.

## The evidence

### The silent abort, captured

```
$ ./pcieep.sh 2>&1 | tee ~/pcieep_run.log ; echo "EXIT=${PIPESTATUS[0]}"
=== configuring hw ===
    .../bit/fk33_i2cprobe.bit (9978842 bytes, 2026-08-27 22:58:46)
FPGA_PROG_OK
  1* xcvu33p
     2  Legacy Debug Hub
        3  JTAG2AXI
        4  JTAG2AXI
EXIT=124
```

`FPGA_PROG_OK` and the target tree are printed by `tcl/program.tcl` and are
genuine. The script then aborts, five minutes later, with no message. Stage 2
never runs, so the ENDPOINT bitstream is never loaded and the card sits holding
the probe image.

### The cause, isolated

`tcl/program.tcl` ended:

```tcl
if {[catch {fpga -no-revision-check -file $bit} err]} {
    puts "FPGA_PROG_FAIL: $err"
    exit 1            ;# the FAILURE path exits
}
puts "FPGA_PROG_OK"
puts [targets]        ;# the SUCCESS path does not
```

Adding `exit 0` was necessary and **not sufficient**: the hang persisted.
Controlled measurement, same command, one variable:

```
FK33_BIT=bit/fk33_i2cprobe.bit timeout 150 xsdb tcl/program.tcl              -> EXIT=124
FK33_BIT=bit/fk33_i2cprobe.bit timeout 150 xsdb tcl/program.tcl < /dev/null  -> EXIT=0
```

`xsdb` execs itself under `rlwrap`, which outlives the Tcl interpreter and keeps
waiting on stdin. Both fixes are in: `exit 0` in `tcl/program.tcl` (`cc77355`),
and `< /dev/null` on the xsdb and Vivado invocations in `pcieep.sh` and
`jtag.sh` (`f9ee620`).

### First light

```
$ lspci -nn | grep -i '10ee'
06:00.0 Processing accelerators [1200]: Xilinx Corporation Device [10ee:9034] (rev a3)

$ sudo lspci -vv -s 06:00.0 | grep -E "LnkSta|Region 0"
        Region 0: Memory at 4802b00000 (64-bit, prefetchable) [size=128K]
                LnkSta: Speed 8GT/s (ok), Width x4 (ok)
                LnkSta2: ... EqualizationComplete+ EqualizationPhase1+

$ ./fk33ctl.py id
id magic   0x464b3333   expected 0x464b3333 ("FK33")
id build   0x20260827   yyyymmdd, BCD
```

### The full path, same session

```
scratch 8 KB at 0x10000: OK
die temperature 36.2 C   VCCINT 0.7157 V   in spec
H2C 3.27 GB/s (1024 MB in 0.328 s)     C2H 1.11 GB/s (1024 MB in 0.967 s)   data MATCHES

blk.0.attn_qkv.weight  M=8192 K=4096, ROWS_IF=48 AXI_DW=256, 18.92 MB
PASS  18915328 bytes identical
      source 108a8f43e507d3cd90ed13c458ae3534  hbm 108a8f43e507d3cd90ed13c458ae3534
```

## Measured and REJECTED -- do not retry

- **`sudo dmidecode -t slot` as the authoritative port-to-connector map.** The
  handoff names it as authoritative and it is not, on this board. It reports
  `0000:00:1c.4` as "x1 PCI Express, Short" when that port demonstrably ran a
  Gen4 **x4** RTX 3090 and `fk33_go.sh --baseline` recorded `LnkCap x4`; it lists
  all five slots as `In Use`; and it lists one x16 slot where the board has three
  x16-length connectors. The designations `J6B2 J6B1 J6D1 J7B1 J8B4` are Intel
  customer-reference-board names, copied through unmodified.
- **Falling back to "a type 9 entry exists, therefore it is a card slot".** Also
  wrong, and this one was believed for about an hour. `0000:00:1d.0` has NO type
  9 entry and had the card enumerated behind it the whole time. Nothing in this
  board's SMBIOS slot table can be used to reason about connectors.
- **Importing `rtl/*.vhd sim/*.vhd tb/*.vhd` into one GHDL library** to
  reproduce a simulation result. Four entity names are defined in both `sim/` and
  `tb/`, `rope_ps` is defined twice, and `sim/post_*.vhd` plus the `library beh`
  benches need xsim and UNISIM. `sim/regress.sh` builds a per-test closure in a
  per-test library precisely for this. Cost two failed attempts.
- **`exit 0` in `program.tcl` alone.** Correct, committed, and does not fix the
  hang. rlwrap outlives the interpreter. See the controlled pair above.

## Measurement traps hit, including our own

- **A confident message about the wrong object, three times in one day.**
  `fk33_go.sh` measured `00:1c.0` and reported "check the 6-pin aux lead and
  reseat" after its own stage A had passed on card power; `tcl/pcieep_jtag.tcl`
  demanded 3 JTAG-AXI masters from a bitstream that correctly has 2, printing
  "the device is not running the instrumented endpoint bitstream" about a
  bitstream nobody had built; and `setup-fk33-access.sh` looked for the kernel
  module under `$HOME`, which is `/root` under sudo, and announced it was not
  built. In every case the message was specific and confident, which is what made
  it expensive.
- **A tool that only fails for humans.** `xsdb` exits by itself when stdin is not
  a tty, so every scripted invocation of `pcieep.sh` worked and every by-hand one
  hung. That is the reverse of the usual pattern and is why it survived in a
  script whose entire purpose is to be run at a bench.
- **Reassuring output printed before the failure.** `FPGA_PROG_OK` scrolls past,
  then five silent minutes, then an abort with no message. The visible evidence
  all said success. Capture `${PIPESTATUS[0]}` on every hardware script.
- **A `grep` in a `set -euo pipefail` pipeline is a hidden `exit`.** It returns 1
  when it matches nothing. Several stages of `pcieep.sh` pipe through one.
- **The JTAG target tree is itself a measurement.** Under the probe bitstream:
  Debug Hub plus two JTAG2AXI. Under the endpoint bitstream: Debug Hub only. The
  JTAG-AXI masters hang off `xdma/axi_aclk` and vanish when the link is down.
  Reading that tree is free and tells you whether the PCIe user clock exists.

## Corrections

**2026-08-28, appended.** The handoff's section 1 states that under the endpoint
bitstream "both JTAG-AXI masters enumerate and match `bit/fk33_pcieep.ltx`
exactly". Observed today, directly, they do not: only the debug hub appears. That
claim is **withdrawn**. Its role in the argument was to show the bitstream was
genuinely resident; the target tree shows the opposite is the useful signal.

**2026-08-28, appended.** A separate correction is recorded in the handoff by the
observability work: the debug hub was never on a free-running clock either.
`hbm/.../APB_0_PCLK` is an MMCM output whose input is `xdma/axi_aclk` and whose
reset is `xdma/axi_aresetn`. The real free-running clock on this board is the
200 MHz oscillator on BC26/BC27.

## Open, not yet answered

- **Whether a COLD boot works.** Everything above required a JTAG configure into
  an already-live root port. The card cannot configure itself in time from
  power-on today, which is what the SPI flash and Tandem Configuration work is
  for. This result does not touch that.
- **The card's SPI flash is erased and partially written**, and the SQRL factory
  image is destroyed. A failure to enumerate at the next power-on says nothing
  about the configuration-time budget.
- **C2H at 1.11 GB/s against H2C at 3.27 GB/s.** Unexplained. Not blocking, since
  results are kilobytes, but a 3x asymmetry is not expected. Candidates in order:
  `poll_mode=1` (chosen deliberately), MRRS negotiated small, descriptor overhead.
- **No inference logic has ever been on the card.** `fk33_pcieep.bit` is a PCIe
  and HBM shell: XDMA, SmartConnect, an ID register, SYSMON, GPIO. The first
  arithmetic on silicon has not been attempted.
