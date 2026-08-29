# First load of the routed engine bitstream on card 1

Date: 2026-08-29. Hardware: SQRL FK33 serial **153300000607** ("card 1"), in the
PCIe slot, `06:00.0`. Bitstream `hw/fk33/bit/fk33_pcieep_eng.bit`, 22,568,402
bytes, sha256 `6b12b3c4...64c6`, from TRACK PBLOCK's `ed1ffe2`.

## The question

Does the routed, timing-clean engine bitstream configure, train a PCIe link, and
identify itself? Nothing had ever loaded it.

## The answers, up front

1. **YES to configure, link and identity.** `FPGA_PROG_OK`; the link trains at
   **Gen3 x4** (`LnkSta: Speed 8GT/s (ok), Width x4 (ok)`); the endpoint
   identifies as `0x464B3333` ("FK33") with build stamp `0x20260828`; SYSMON
   reads through the design at `VCCINT 0.7146-0.7164 V`, die 36-38 C; GPIO reads
   its documented reset value.
2. **NO to the memory path.** Neither non-AXI-Lite master round-trips the DMA
   BRAM window at `0x2_0000_0000`. MEASURED, after three separate measurement
   bugs were removed. **Open, not diagnosed.**
3. **The first run's `PCIEEP_FAIL` was a FALSE ALARM**, as were all eight
   `HBM_MISMATCH` / `DMABRAM_MISMATCH` lines. Three independent defects in the
   CHECK, not in the card.

## Defects found in the instrument, not the card

### 1. Decimal compared against hex

`report_hw_axi_txn -t d4` prints the data word in **decimal** (that is what the
`d` means), as a signed 32-bit value. The identity check did:

```tcl
if {[string toupper $idm] eq "464B3333"}
```

comparing decimal TEXT against a hex STRING. It can never match. The run
reported:

```
PCIEEP_FAIL: id magic reads 0x1179333427, expected 0x464B3333.
             The AXI-Lite path answers but this is not fk33_pcieep.
```

on a card answering with exactly the right magic. **Decimal 1179333427 =
0x464B3333.** The same bug produced every `HBM_MISMATCH` ("wrote DEADBEEF read
3"), so the memory failures were unproven too.

Note the printed value had TEN hex digits after an `0x` prefix, which is
impossible for a 32-bit read. That was visible in the output and was the tell.

### 2. The AXI-Lite master was selected by ORDINAL

`set axil [lindex $axis 1]`, under a comment asserting "hw_axi_1 is jtag_hbm,
hw_axi_2 is jtag_axil". That is a statement about **enumeration order, which is
not a contract**. It worked by coincidence with two masters; the engine build
has three. Same defect class as selecting a JTAG target by index, which already
cost this project a factory flash image.

There is nothing in the masters' properties to tell them apart: all three report
`NAME hw_axi_N`, `PROTOCOL AXI4_Full`, and `ADDR_WIDTH`/`DATA_WIDTH` do not
exist on this object at all. But they are **self-identifying** by what they
answer:

```
probe hw_axi_1 at 0xA000 -> 0xDEC0DEE3     <- decode sentinel, not in its map
probe hw_axi_2 at 0xA000 -> 0x464B3333     <- the AXI-Lite master
probe hw_axi_3 at 0xA000 -> 0xA4960CF2
```

Now selected by probe, refusing unless exactly one answers.

### 3. A `catch` that swallowed its own diagnostic

The memory-master probe reported "0 answered" with no probe lines at all. The
transactions were not returning wrong data, they were **erroring**, and
`catch {...} { continue }` discarded the message. Surfacing it showed my own
bug: `proc wr` was defined AFTER its first use, so Tcl resolved bare `wr` to an
ambiguous builtin (`write_abstract_shell`, `write_bitstream`, ...).

## Evidence, after the fixes

```
PART   xcvu33p
AXI_MASTERS hw_axi_1 hw_axi_2 hw_axi_3
  probe hw_axi_1 at 0xA000 -> 0xDEC0DEE3
  probe hw_axi_2 at 0xA000 -> 0x464B3333
  probe hw_axi_3 at 0xA000 -> 0xA4960CF2
  probe hw_axi_1 at 0x200000000 -> 0xA4960CF2
  probe hw_axi_3 at 0x200000000 -> 0x00000000
AXI_LITE_MASTER hw_axi_2
ID_OK magic=0x464B3333 build=0x20260828  ("FK33")
SYSMON die=37.2 C  VCCINT=0.7146 V  (raw 0x9fb0 0x3cfb)
VCCINT_OK 0.7146 V
GPIO tri=0x00000003 data=0x00000003
HBM_SKIPPED / DMABRAM_SKIPPED: no unambiguous HBM master
```

Host side, from the reload script:

```
LnkCap: Port #0, Speed 8GT/s, Width x4, ASPM not supported
LnkSta: Speed 8GT/s (ok), Width x4 (ok)
Region 0: Memory at 4802b00000 (64-bit, prefetchable) [size=128K]
/dev/xdma0_control  Aug 29 15:12
```

## Host-side defects fixed in `host/fk33_reload.sh`

* **`rmmod` must come AFTER the PCI remove.** The module's refcount is held by
  the bound device (`/sys/module/xdma/refcnt` = 1,
  `/sys/bus/pci/drivers/xdma/0000:06:00.0`). rmmod-then-remove can never work
  with the card present.
* **The refcount does not drop instantly** even after the remove; a single
  `sleep 1` was not enough. Now a bounded wait, and rmmod is SKIPPED rather than
  forced if it never reaches 0, because the driver re-binds correctly on rescan.
* **Tools must be resolved by absolute path.** `lsmod` is `/usr/sbin/lsmod` and
  the script runs under sudo's `secure_path`; a not-found tool makes an `if`
  read as "no", which silently skipped the whole rmmod branch on the first run.
* **`get_property REGISTER.IDCODE` aborts the script.** That trap was written
  down in `tcl/flash_common.tcl:56`, `tcl/aux_probe.tcl:172` and
  `tcl/flash_status.tcl:65`, and left live in `tcl/pcieep_jtag.tcl:37` -- the one
  file whose job is to check the endpoint. It killed the check at its first line
  after a successful configure, reporting nothing about a link that was up.

## Measured and REJECTED -- do not retry

* **Reading anything through `report_hw_axi_txn` as a hex string.** It is
  decimal. Compare numerically or format explicitly.
* **Identifying a JTAG-AXI master by its index in `get_hw_axis`.** Not a
  contract, and it silently broke the moment a third master appeared.
* **Identifying one by `ADDR_WIDTH`/`DATA_WIDTH`/`PROTOCOL`.** MEASURED: those
  properties either do not exist on the object or are identical across all three.

## Measurement traps hit

* **A number that cannot be the right width is the tell.** `0x1179333427` has ten
  hex digits. A 32-bit read cannot produce that. It was printed and not read.
* **My own `catch` hid the difference between "wrong answer" and "errored".**
  Those need completely different diagnoses.
* **A guard that fails open.** The earlier `lsof ... | grep -q .` check for open
  device handles rested on a pipeline's exit status, deciding whether it was safe
  to yank a live PCIe device. Replaced with a captured-text test.

## Open, not yet answered

* **Why neither memory master answers the DMA BRAM at `0x2_0000_0000`.** Both
  respond to transactions now (no error), one returning `0xA4960CF2` and the
  other `0x00000000`, neither the written pattern. Note `0xA4960CF2` also appears
  from a different master at a different address, so it looks like an unmapped
  read rather than data. Candidates not yet separated: the engine build's address
  map, HBM initialisation not having completed, or the memory path held in reset
  until the engine is configured. `tcl/hbmdiag.tcl` is the named instrument.
* **Whether the engine COMPUTES anything.** Nothing here touches that. The
  design routed, links, and identifies; that is all.
* **The build stamp reads `0x20260828`** while the bitstream file is dated
  2026-08-29. Probably a block-design constant rather than a build timestamp,
  but not established.

---

## ADDENDUM, same day: the host side, and the memory finding WITHDRAWN

The dispatcher's shell reported no `fk33` group and the host tests were deferred
to Oren. That was wrong: `getent group fk33` shows `fk33:x:1004:orencollaco`.
Group membership is read at **login**, and the shell predated the change.
**`sg fk33 -c '<cmd>'` bridges it with no re-login.** Worth remembering: `id -nG`
describes the PROCESS, not the account, and the two can disagree for hours.

### Every host-side test passes

MEASURED with `hw/fk33/host/fk33ctl.py` through the BAR, and with `dd` on
`/dev/xdma0_{h2c,c2h}_0`:

```
id       magic 0x464b3333  build 0x20260828 (BCD yyyymmdd)   OK
sysmon   die 35.5 C   VCCINT 0.7174 V   in spec
gpio     TRI 0x3  DAT 0x3   SCL=1 SDA=1, live pull-up on BB24/BA24
scratch  8 KB at 0x10000: OK                    <- BAR WRITES work
```

`id` alone proves link, config space, BAR placement, AXI-Lite clock and reset,
smartconnect decode and bitstream identity. Combined with the JTAG read of the
same register, this is the conclusive pair the check's own header describes:

```
JTAG OK + host OK   -> everything works
```

The MMIO path also cross-checks against JTAG on the same registers: BAR reports
VCCINT 0.7174 V / die 35.5 C where JTAG reported 0.7146 V / 37.2 C. Two
independent paths, same silicon, agreeing.

### The memory finding is WITHDRAWN. Memory is fine.

```
DMA BRAM at AXI 0x2_0000_0000
  wrote     464B3333 4A544147 12345678 FEDCBA98
  read back 464B3333 4A544147 12345678 FEDCBA98    MATCH

HBM at AXI 0x1FFFFF000 (last 4 KB of the 8 GB map, SAXI_16's half)
  wrote     DEADBEEF 0BADC0DE 5A5A5A5A A5A5A5A5
  read back DEADBEEF 0BADC0DE 5A5A5A5A A5A5A5A5    MATCH
HBM at AXI 0x0                                      MATCH
```

**HBM initialisation HAS completed, both stacks are mapped, and the addresses
the JTAG script uses are correct.** The section above titled "NO to the memory
path" is hereby withdrawn as a statement about the CARD. It remains true as a
statement about the JTAG-AXI instrument.

This kills four of the five candidate causes listed earlier: the address map is
not different, HBM init is not incomplete, the memory path is not held in reset,
and the `axi_aclk`/`axi_aresetn` domain is demonstrably serving the host. What
remains is the JTAG-AXI master question: which of the three masters reaches the
memory space in this build, and in what transaction shape. Note the earlier
enumeration showed one master returning TWO data words from a single read, so a
64-bit master driven with a 32-bit single-beat probe is a live sub-hypothesis.

**The methodological point.** The JTAG check and the host check disagree, and
the host is right. The check's own comment predicted the value of running both:
a JTAG failure with a host success localises the fault to the instrument. Had
only JTAG been run, "HBM does not work" would have been recorded as a property
of the card. It was very nearly written up that way.

### A trap avoided by luck, worth recording

The first DMA BRAM write used `printf "\x33\x33..."` inside `sg fk33 -c '...'`,
where the escapes were not interpreted, so LITERAL backslash-x text was written.
The read returned exactly that text. **The round trip was still proved** -- what
went in came out -- but the pattern was not the intended one, and a less careful
reading would have called it a data-integrity failure. Rewritten with
`struct.pack` to write exact bytes.
