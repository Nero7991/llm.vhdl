# The engine build's address map, and why two JTAG-AXI masters "failed" at 0x2_0000_0000

Date: 2026-08-29
Bitstream: `hw/fk33/bit/fk33_pcieep_eng.bit`, from `ed1ffe2`, rebuilt end to end at `2febb2a`
Card: FK33 serial `153300000607A`, live on the PCIe bus, xdma driver bound
Track: ADDRMAP. **No hardware was touched by this track.** Every measurement
below is either a re-read of the dispatcher's logs or a Vivado run in a
non-hardware mode.

---

## 1. The question, verbatim

> The routed engine bitstream is loaded on card 1 and is healthy in every
> respect the AXI-Lite path can show. **Neither non-AXI-Lite master round-trips
> the DMA BRAM window at 0x2_0000_0000**, which is significant because that
> window has NO memory controller behind it, so a failure there cannot be
> blamed on HBM initialisation. HBM at `0x1FFFFF000` is equally unverified.
> Note `0xA4960CF2` appears from TWO different masters at TWO different
> addresses, so it looks like an unmapped/undriven read rather than data.
>
> Your job is to explain it statically and tell me exactly what to probe.
> Deliver the authoritative address map of the ENGINE build, derived from the
> sources that generate it, NOT from a document. Say what each of the three
> JTAG-AXI masters reaches, and at what addresses. ... Whether `tcl/hbmdiag.tcl`
> is the right instrument and what it would show.

---

## 2. The answer, up front

**The address map is correct and unchanged, and nothing is wrong with the card.
The instrument is wrong in three separate ways, and two of them are the same
defect the dispatcher had already found and fixed once in the same file.**

1. **`jtag_axil` and `jtag_aux` have 32-BIT address spaces.** They cannot issue
   `0x2_0000_0000` at all. That address is 34 bits. MEASURED from the generated
   IP: `M_AXI_ADDR_WIDTH` is 32 on both and 64 on `jtag_hbm`. So one of the two
   "failures" is a master being asked to do something it is physically unable to
   do, and the right outcome there is a refusal to probe, not a probe.

2. **`0xA4960CF2` is not a value the fabric produced. It is a stale
   transaction.** `create_hw_axi_txn -quiet` returns quietly on failure and
   leaves the PREVIOUS transaction of that name in place; the following
   `run_hw_axi` then re-runs *that* transaction and its data is reported as this
   master's answer. The value reported for `hw_axi_1 at 0x200000000` is
   byte-identical to the value reported for the immediately preceding read,
   `hw_axi_3 at 0xA000`, because it IS that read, run a second time. Compounding
   it, `get_hw_axi_txns t` carries no `-of_objects`, so the name `t` reaches
   every master's transaction, not this one's.

3. **`jtag_hbm` is 64 bits wide and the read helper assumes 32.**
   `lindex [report_hw_axi_txn -t d4 $t] 1` takes ONE 32-bit group out of the
   beat. On `jtag_hbm` that is half the word, and which half has not been
   established. `hw_axi_3` at `0x2_0000_0000` returning `0x00000000` after a
   write of `0x5A5A0F0F` is exactly what a correct write plus a
   wrong-half readback looks like: a single 32-bit `-data` value on a 64-bit
   master fills one half of the beat and zeroes the other.

The dispatcher's own host-side round trip (BAR + XDMA, both ends of the map,
MATCH) is the independent confirmation that the fabric was right the whole time.

**Master identity, and it is NOT the ordinal:**

| hw_axi | is | address space | data | burst |
|---|---|---|---|---|
| `hw_axi_1` | `jtag_aux` | 32-bit, its own 7-segment space | 32 | no |
| `hw_axi_2` | `jtag_axil` | 32-bit, identical to `xdma/M_AXI_LITE` | 32 | yes |
| `hw_axi_3` | `jtag_hbm` | **64-bit**, identical to `xdma/M_AXI` | **64** | no |

**`tcl/hbmdiag.tcl` is the WRONG instrument and would have produced a confident
wrong answer.** See section 7.

---

## 3. The authoritative address map, MEASURED

Derived by running the generator's own no-card gate, which prints every
assigned segment after `assign_bd_address` has run. This is a REPORT of what
the address editor holds, not a `CONFIG.*` request.

MEASURED: `FK33_STOP_AFTER_BD=1 vivado -mode batch -source build_fk33_pcieep.tcl`
on the committed `hw/fk33/build_fk33_pcieep.tcl`, 2026-08-29 16:12-16:14,
`FK33_BD_VALIDATE OK`, `FK33_BD_ONLY_DONE`. No synthesis, no place and route,
no hardware.

### 3.1 The five address spaces that matter

```
FK33_MAP  space                segments
          /xdma/M_AXI_LITE       9
          /jtag_axil/Data        9      <- identical to xdma/M_AXI_LITE
          /jtag_aux/Data         7
          /xdma/M_AXI           33
          /jtag_hbm/Data        33      <- identical to xdma/M_AXI
          /eng/m00_axi .. m27   32 each
```

**`jtag_axil` sees exactly what the host's BAR sees, and `jtag_hbm` sees exactly
what the host's DMA master sees.** Not a superset, not a subset. That single
fact kills candidate 1 without needing the card.

### 3.2 `/jtag_axil/Data` and `/xdma/M_AXI_LITE` (byte-identical)

```
0x00003000  4K   system_management_wiz_0   SYSMON
0x00009000  4K   axi_gpio_0                I2C SCL/SDA (ch1) + 7 LEDs (ch2)
0x0000A000  4K   fk33_id                   magic 0x464B3333 @+0, build @+8
0x0000B000  4K   fk33_therm                THERM_STATUS / THERM_TEMPS
0x0000C000  4K   fk33_thermp               THERM_PEAK / THERM_TRIP
0x0000D000  4K   fk33_thermc               THERM_CTL / THERM_CANARY
0x00010000  8K   fk33_scratch              BRAM, 0x10000..0x11FFF
0x00012000  4K   eng/s_axi                 the engine's descriptor register map
0x00013000  4K   eng/s_axix                the activation writer
```

Address `0x00000000` is UNMAPPED here, and that is load-bearing: it is what
makes `jtag_axil` self-identifying (section 5).

### 3.3 `/jtag_aux/Data` (jtag_aux only; never on the BAR, never on xdma)

```
0x00000000  4K   aux_id      AUX_MAGIC 0x41555831 "AUX1" @+0, AUX_VERSION @+8
0x00001000  4K   aux_clkst   UCLK_TICKS @+0, UCLK_HZ @+8
0x00002000  4K   aux_stat    AUX_STATUS @+0, POT_STATUS @+8
0x00003000  4K   aux_time    AUX_MS @+0, PERST_MS @+8
0x00004000  4K   aux_therm   THERM_STATUS @+0, THERM_TEMPS @+8
0x00005000  4K   aux_peak    THERM_PEAK @+0, THERM_TRIP @+8
0x00006000  4K   aux_ctl     THERM_CTL (write) @+0, THERM_CANARY @+8
```

Everything at and above `0x00007000` is unmapped, which is why `hw_axi_1`
answered `0xDEC0DEE3` at `0xA000`. That was never a symptom.

### 3.4 `/jtag_hbm/Data` and `/xdma/M_AXI` (byte-identical, 64-bit space)

```
0x0_00000000 .. 0x0_FFFFFFFF   HBM_MEM00..15 via SAXI_00   256M each, stack 0
0x1_00000000 .. 0x1_FFFFFFFF   HBM_MEM16..31 via SAXI_16   256M each, stack 1
0x2_00000000 .. 0x2_0000FFFF   fk33_dmabram                64K BRAM, no controller
```

So both of the addresses the JTAG check uses are correct in this build:
`0x1FFFFF000` is the last 4 KB of `HBM_MEM31`, and `0x200000000` is the base of
the DMA BRAM. Confirmed independently by the dispatcher from the host.

### 3.5 `/eng/mNN_axi`, the 28 engine masters

Each of the 28 has all 32 `HBM_MEM` segments at `s * 0x1000_0000`, so each sees
the full 8 GiB and nothing else. Max offset `0x1F0000000`; **no DMA BRAM, so an
engine descriptor pointing at `0x2_0000_0000` DECERRs rather than reading a
BRAM.** Port map (`gen_pcieep.py` `ENG_PORT_MAP`): `m00..m14 -> SAXI_01..15`,
`m15..m27 -> SAXI_17..29`. `SAXI_00`/`SAXI_16` stay with the host;
`SAXI_30`/`SAXI_31` are left disabled.

Note the engine truncates 40-bit addresses to 33 for the HBM SAXI port
(`gen_fk33_engine.py` header item 3), so an engine address at or above 8 GiB
**aliases** rather than erroring. That is a real hazard and it is not new.

### 3.6 The three JTAG-AXI masters, MEASURED from the generated IP

From the `.xci` files the block design generated, not from `CONFIG.*` requests:

```
bd_jtag_hbm_0.xci    M_AXI_ADDR_WIDTH 64  M_AXI_DATA_WIDTH 64  M_HAS_BURST 0
bd_jtag_axil_0.xci   M_AXI_ADDR_WIDTH 32  M_AXI_DATA_WIDTH 32  M_HAS_BURST 1
bd_jtag_aux_0.xci    M_AXI_ADDR_WIDTH 32  M_AXI_DATA_WIDTH 32  M_HAS_BURST 0
```

Corroborated by the offset formatting in `FK33_MAP`: `jtag_hbm` offsets print as
16 hex digits, `jtag_axil` and `jtag_aux` as 8, `eng/mNN_axi` as 9.

**Consequence, and it is the direct answer to the dispatcher's question:**
`jtag_axil` and `jtag_aux` have 32-bit address spaces. `0x2_0000_0000` needs 34
bits. Only `jtag_hbm` can issue it.

---

## 4. Ranked causes, with what each is decided by

| # | candidate | verdict | decided by |
|---|---|---|---|
| 4 | the third master changed which master reaches what | **CONFIRMED, and it is narrower than "reaches what"** | enumeration reordered between builds (5.1); reachability itself is unchanged (3.1) |
| 6 | the probe helper re-runs a stale transaction | **CONFIRMED, primary cause of the `0xA4960CF2` ghost** | `-quiet` on `create_hw_axi_txn` + `get_hw_axi_txns t` with no `-of_objects` (6.2); the value equals the immediately preceding read |
| 7 | the 32-bit masters cannot issue a 34-bit address | **CONFIRMED** | `M_AXI_ADDR_WIDTH 32` MEASURED from the generated `.xci` (3.6) |
| 8 | the 64-bit master is read as if it were 32-bit | **CONFIRMED, explains the `0x00000000`** | `M_AXI_DATA_WIDTH 64` (3.6) vs `lindex ... 1` (6.3) |
| 1 | the engine build's address map differs | **EXCLUDED** | `jtag_hbm/Data` is byte-identical to `xdma/M_AXI` (3.4); dispatcher's host round trip at both ends |
| 2 | HBM init has not completed | **EXCLUDED** | dispatcher's host round trip at `0x0` and `0x1FFFFF000`, both MATCH |
| 3 | the memory path is held in reset until the engine is enabled | **EXCLUDED** | same; and the DMA BRAM is on `pcie2hbm`, not behind the engine |
| 5 | something in the `axi_aclk`/`axi_aresetn` domain | **EXCLUDED** | that domain is serving the host's BAR and DMA right now |

Candidates 6, 7 and 8 were not on the dispatcher's list. They are the ones that
were actually true.

---

## 5. The procedure, in the order it was run

### 5.1 Re-read the logs before believing the brief's framing

`hw/fk33/tcl/aux_probe.log:178`, from the THERMAL build on 2026-08-28, already
contained the master identification, unread:

```
  hw_axi_1   0x00000000 -> 0x41555831      "AUX1"    -> jtag_aux
  hw_axi_2   0x00000000 -> 0xDEC0DEE3      DECERR    -> jtag_axil
  hw_axi_3   0x00000000 -> 0x4D563449      HBM bytes -> jtag_hbm
  AUX_MASTER hw_axi_1
```

`aux_probe.tcl` picks the aux master by ASKING and prints every master's answer,
so it identified all three as a side effect a day before the question was asked.
Against `tcl/telemetry.tcl:10`, which says `hw_axi_1` is `jtag_axil` and
`hw_axi_2` is `jtag_hbm` on the two-master first-light build, this is proof that
**enumeration order is not stable across builds of the same source tree.**

### 5.2 Derive the map from what generates the hardware

`hw/fk33/gen_pcieep.py` emits `build_fk33_pcieep.tcl`; the constants are
`ID_BASE`, `SCRATCH_BASE`, `DMABRAM_BASE`, `AUX_*_BASE`, `THERM*_BASE`,
`ENG_CTL_BASE`, `ENG_XW_BASE`, `ENG_PORT_MAP`. The three masters are created in
`build_fk33_pcieep.tcl:250` (`jtag_hbm`), `:305` (`jtag_axil`), `:689`
(`jtag_aux`).

### 5.3 Turn the derivation into a measurement

Ran the generator's own `--bd-only` gate. Three minutes, ~3 GB. Output in
section 3. This is what makes the map MEASURED rather than DERIVED, and it is
the step worth repeating after any edit to `gen_pcieep.py`.

### 5.4 Read the probe helper as carefully as the RTL

That is where the defects were. See section 6.

---

## 6. Evidence

### 6.1 The raw capture (`hw/fk33/tcl/pcieep_jtag.log`, 2026-08-29 16:00)

```
AXI_MASTERS hw_axi_1 hw_axi_2 hw_axi_3
  master hw_axi_1  ADDR_WIDTH=? DATA_WIDTH=?
  master hw_axi_2  ADDR_WIDTH=? DATA_WIDTH=?
  master hw_axi_3  ADDR_WIDTH=? DATA_WIDTH=?
  probe hw_axi_1 at 0xA000 -> 0xDEC0DEE3
  probe hw_axi_2 at 0xA000 -> 0x464B3333
  probe hw_axi_3 at 0xA000 -> 0xA4960CF2
  probe hw_axi_1 at 0x200000000 -> 0xA4960CF2
  probe hw_axi_3 at 0x200000000 -> 0x00000000
```

Line by line against the measured map:

* `hw_axi_1 @ 0xA000 -> DEC0DEE3`. `jtag_aux`'s space ends at `0x6FFF`.
  **Correct behaviour, not a symptom.**
* `hw_axi_2 @ 0xA000 -> 464B3333`. `fk33_id`. Correct.
* `hw_axi_3 @ 0xA000 -> A4960CF2`. `HBM_MEM00 + 0xA000`. HBM held whatever it
  held; the host had not yet written there. **This is data, and it is also one
  half of a 64-bit beat.**
* `hw_axi_1 @ 0x200000000 -> A4960CF2`. `jtag_aux` is a 32-bit master; the
  transaction could not be created. The value is the PREVIOUS transaction's,
  re-run. **Not a read of this master at all.**
* `hw_axi_3 @ 0x200000000 -> 00000000`. The write of `0x5A5A0F0F` on a 64-bit
  master fills one 32-bit half; the read reports the other half.

The `ADDR_WIDTH=? DATA_WIDTH=?` line is itself evidence: those properties do not
exist on a `hw_axi` object, so a script cannot tell the masters apart by
property. It has to ask them.

### 6.2 The stale-transaction defect, in the helper

```tcl
proc rd {ax addr} {
    create_hw_axi_txn -quiet -force t $ax -address $addr -type read
    run_hw_axi -quiet [get_hw_axi_txns t]
    set v [lindex [report_hw_axi_txn -t d4 [get_hw_axi_txns t]] 1]
    return [expr {$v & 0xFFFFFFFF}]
}
```

Two independent problems on three lines:

* `-quiet` on `create_hw_axi_txn` makes a failed create return quietly instead
  of raising, so **the previous transaction named `t` survives** and the next
  two lines run and report IT.
* `get_hw_axi_txns t` has no `-of_objects`, so the name is not scoped to this
  master.

The caller's `catch` cannot help: with `-quiet` there is nothing to catch. That
is why the DMA BRAM probe printed a value instead of the `ERRORED:` line the
dispatcher had just added to make failures visible. **The fix that was applied
an hour earlier -- removing a `catch ... continue` that swallowed errors -- was
correct and insufficient, because the error was being swallowed one level
deeper, by `-quiet`.**

### 6.3 The width defect

`lindex [report_hw_axi_txn -t d4 $t] 1` takes the first data group after the
address column. On a 32-bit master that is the whole word, which is why every
AXI-Lite reading in the same log is right (`ID_OK`, `SYSMON die=37.2 C
VCCINT=0.7146 V`, `GPIO tri=0x00000003`). On `jtag_hbm` a beat is 8 bytes and
`-t d4` yields two groups, so `lindex ... 1` is half the beat. **Which half is
NOT established here and is the one thing this write-up leaves open**; probe P3
in section 8 settles it in one transaction.

### 6.4 The measured map (extract)

```
FK33_MAP /jtag_hbm/Data  SEG_hbm_HBM_MEM00       0x0000000000000000 0x0000000010000000
FK33_MAP /jtag_hbm/Data  SEG_hbm_HBM_MEM31       0x00000001F0000000 0x0000000010000000
FK33_MAP /jtag_hbm/Data  SEG_fk33_dmabram_Mem0   0x0000000200000000 0x0000000000010000
FK33_MAP /xdma/M_AXI     SEG_fk33_dmabram_Mem0   0x0000000200000000 0x0000000000010000
FK33_MAP /jtag_axil/Data SEG_fk33_id_Reg         0x0000A000         0x00001000
FK33_MAP /jtag_axil/Data SEG_eng_reg0            0x00012000         0x00001000
FK33_MAP /jtag_axil/Data SEG_eng_reg0_1          0x00013000         0x00001000
FK33_MAP /jtag_aux/Data  SEG_aux_id_Reg          0x00000000         0x00001000
FK33_MAP /jtag_aux/Data  SEG_aux_ctl_Reg         0x00006000         0x00001000
FK33_MAP /eng/m00_axi    SEG_hbm_HBM_MEM31       0x1F0000000        0x010000000
```

---

## 7. `tcl/hbmdiag.tcl` is the WRONG instrument, and dangerously so

It targets the **hbmbw** bitstream, not the endpoint family. `set TG 0x00010000`
is `build_fk33_hbmbw.tcl`'s traffic generator. In the engine build that address
is `fk33_scratch`, an 8 KB BRAM (MEASURED, section 3.2).

Run against the engine bitstream it would have:

* read `ID` from a scratch BRAM and printed some number,
* **WRITTEN** `TEMP_LIMIT`, `ARLEN`, `NBURST` and the arm bit into that BRAM,
* then reported `busy=0 cycles=0 beats=0 arstall=0` for six samples,

which is precisely the "never armed, the fault is upstream" signature its own
closing text tells you to read. It would have manufactured a confident wrong
diagnosis out of a healthy card. It also had no ID guard at all -- it printed
the ID and carried on regardless.

**Fixed here:** `hbmdiag.tcl` now picks its master by asking, and REFUSES with
an explanation unless the generator ID reads `0x48424D31`. `hbmbw.tcl` got the
same master selection; it already had the ID guard.

The right instrument for the engine build is `tcl/pcieep_jtag.tcl` with the
transaction shape corrected (section 8).

---

## 8. The probe sequence for the dispatcher

Short, ordered, and each step says what it rules OUT. `fk33_axi_rd32`,
`fk33_axi_report` and `fk33_axi_pick` are in the new `hw/fk33/tcl/axi_select.tcl`.

**P0. Classify all three masters by their answer at 0x00000000.** One read per
master, no writes.

```
foreach a [get_hw_axis] { puts "[get_property NAME $a] -> [fk33_axi_rd32 $a 00000000]" }
```

| outcome | meaning |
|---|---|
| one `41555831`, one `DEC0DEE3`, one other | expected. aux / axil / mem identified. Proceed. |
| any master returns `-1` | that master's clock or reset is down. If it is the aux one, the 200 MHz board oscillator is the suspect; if the other two, the PCIe link is. **Stop**, check LED 6. |
| two masters `DEC0DEE3` | the map changed. Re-run `pcieep_build.sh --bd-only` and re-read `FK33_MAP` before anything else. |

This RULES OUT the ordinal hypothesis permanently: it never consults the name.

**P1. Confirm the AXI-Lite master against the identity register.**
`fk33_axi_confirm $axil A000 464B3333`. Disagreement means the fabric is not
running this bitstream and every later step is meaningless. This step costs one
read and is the only thing that ties the classification to THIS build.

**P2. Prove that only the memory master can issue a 34-bit address.** Create,
do NOT run, a read at `0x200000000` on each of the three, without `-quiet`, and
print the error:

```
foreach a [get_hw_axis] {
    puts "[get_property NAME $a]: [catch {create_hw_axi_txn p34 $a -address 200000000 -type read -len 1} e] $e"
}
```

| outcome | meaning |
|---|---|
| exactly one succeeds | confirms `M_AXI_ADDR_WIDTH` 64 on that one and 32 on the others, from the card rather than from the `.xci`. That master is `jtag_hbm`. |
| all three succeed | Vivado does not enforce the width; the 32-bit masters are silently truncating to `0x00000000`, which on `jtag_aux` is `aux_id`. Treat any "memory" reading from them as fiction. |
| all three fail | the address syntax is wrong, not the masters. |

**P3. Settle which half of a 64-bit beat `lindex ... 1` returns. ONE
transaction, and it is the highest-value probe here.** The host has already
written four distinct words at the DMA BRAM base
(`464B3333 4A544147 12345678 FEDCBA98`). Read `0x200000000` on the memory master
and print the RAW report, unparsed:

```
puts [fk33_axi_report $mem 200000000]
```

| outcome | meaning |
|---|---|
| the report shows `4A544147` then `464B3333` | groups are printed MSW-first; `lindex ... 1` has been returning the HIGH half, i.e. the word at +4. **Every previous `jtag_hbm` reading in this project is off by one 32-bit word.** |
| it shows `464B3333` then `4A544147` | LSW-first; `lindex ... 1` is the word at +0 and the DMA BRAM readback of `0x00000000` needs a different explanation -- go to P4. |
| it shows one 16-hex-digit token | `-t d4` is not splitting; parse with `scan`, and every 64-bit reading so far took a decimal of the full beat. |

Whatever it shows, this also **verifies the host-written pattern over JTAG**,
which is the cross-domain check the DMA BRAM exists for -- so P3 subsumes the
old step 4 of `pcieep_jtag.tcl`.

**P4, only if P3 came back LSW-first.** Write `AAAA1111` at `0x200000000` and
`BBBB2222` at `0x200000004` from the memory master, then read both back from the
HOST. If the host sees `AAAA1111 BBBB2222`, JTAG writes are fine and the earlier
`0x00000000` was a read-side artefact. If the host sees `AAAA1111 00000000`, a
32-bit `-data` on a 64-bit master is zeroing the other half via WSTRB and every
JTAG write to memory in this project has been clobbering 4 adjacent bytes.

**P5. HBM, last, and only after P3.** Four words at `0x1FFFFF000` with the beat
shape P3 established. The host has already proven this address round-trips, so a
JTAG-side mismatch here is an instrument fault, not a memory fault -- which is
the opposite of how the old script read it.

**Do NOT run `tcl/hbmdiag.tcl`.** Section 7.

---

## 9. Measured and REJECTED -- do not retry

* **`get_property ADDR_WIDTH` / `DATA_WIDTH` on a `hw_axi` object.** Those
  properties do not exist. MEASURED: `pcieep_jtag.log` prints
  `ADDR_WIDTH=? DATA_WIDTH=?` for all three masters, from a `catch` that fired
  three times. The widths must come from the block design or from behaviour, not
  from the master object. Do not add more `get_property` guesses.
* **Telling the masters apart by elimination.** `pcieep_jtag.tcl` tries "the HBM
  master is whichever is not the AXI-Lite one", which is ambiguous at three
  masters, and its fallback probe was itself broken by the stale-transaction
  defect. Elimination from ONE positive is not enough; elimination from TWO
  positives is, and that is what `axi_select.tcl` does.
* **Blaming HBM initialisation.** MEASURED by the dispatcher from the host:
  `0x0` and `0x1FFFFF000` both round-trip. HBM is initialised. This was the
  leading hypothesis in the original write-up and it is wrong.
* **Blaming the address map.** MEASURED: `jtag_hbm/Data` is byte-identical to
  `xdma/M_AXI`, and `jtag_axil/Data` to `xdma/M_AXI_LITE`. There is no version
  of "the engine build moved the window" that survives that.
* **Assuming the DMA BRAM window is reachable from the engine.** It is NOT in
  any `eng/mNN_axi` space (max offset `0x1F0000000`). A descriptor pointing
  there DECERRs. Do not use it as an engine scratch area.

---

## 10. Measurement traps hit

* **A `catch` around a `-quiet` command catches nothing.** The dispatcher
  removed a `catch ... continue` specifically to stop errors being swallowed,
  and the errors kept being swallowed, because `-quiet` on the command inside
  the `catch` is a second, independent silencer. Removing one silencer while
  leaving the other reads as a fix and is not one.
* **A repeated value across two probes is not a fabric constant.** `0xA4960CF2`
  looked like an "unmapped/undriven read" signature precisely because it
  repeated. It repeated because it was the same transaction run twice. **The
  test that distinguishes them is whether the value equals the immediately
  PRECEDING reading**, and it did.
* **A helper validated on one master is not validated.** Every 32-bit reading in
  that log is correct. That is what made the 64-bit readings look like card
  faults rather than parser faults.
* **The identification was already in the tree.** `aux_probe.log:178` had all
  three masters classified on 2026-08-28. A log nobody re-reads is not evidence.
* **`hw_axi_N` ordinals are an implementation result.** Between the first-light
  build and the thermal build, from the same source tree, `hw_axi_1` changed
  from `jtag_axil` to `jtag_aux`. A comment recording an observed order reads
  like a contract and is not one.

---

## 11. The systemic finding: ten scripts picked their master by ordinal

Raised by the dispatcher mid-task, and it is the same defect as everything
above. `hw/fk33/tcl/` had **ten** call sites doing `get_hw_axis hw_axi_1`.
`tcl/aux_probe.tcl:207` already carried a comment warning about exactly this,
written by somebody who saw the instance and did not generalise it.

**Fixed:** new `hw/fk33/tcl/axi_select.tcl` selects by what a master ANSWERS and
REFUSES unless exactly one candidate matches. Adopted by `vccint_step.tcl`,
`vccint_verify.tcl`, `telemetry.tcl`, `blink.tcl`, `i2cbang.tcl`,
`i2cident.tcl`, `i2cprobe.tcl`, `i2cread.tcl`, `hbmbw.tcl`, `hbmdiag.tcl`.

### 11.1 `vccint_step.tcl`, the one that matters

It bit-bangs the MCP45XX pot that sets VCCINT. Every one of its abort conditions
-- wiper readback, rail direction, per-step delta, ceiling -- is fed by reads
through the one master object it never verified.

**Two honest qualifications, because overstating this would be its own defect.**
The pot WRITES go through the same object as the reads, so a wrong master means
the pot does not move either: the failure is inert, not destructive. And on the
value actually measured, `0xDEC0DEE3`, bit 1 is 1, so `sda_in` reads a permanent
NACK and `pot_write` aborts on its first transaction. **Both of those are luck.**
A sentinel with bit 1 clear reads as ACK on every byte. The defect is that all
the guards sit downstream of one unchecked selection, so they fail together.

Now: the master is picked by `fk33_axi_pick axil`, and a PREFLIGHT block runs
before a single bit reaches the I2C bus. It refuses unless, through the chosen
master, the GPIO does not answer with the DECERR sentinel, `TRI[1:0]` reads
`0b11` (`C_TRI_DEFAULT` is all-ones, so both lines come up as inputs), SYSMON
reports VCCINT in 0.55..0.95 V, and the die temperature is plausible. The last
is the cross-check that costs nothing: a stale or unclocked SYSMON still reports
a number.

This is consistent with the dispatcher's independent host-side result --
`fk33ctl.py vccint` reporting `wiper=READ FAILED (I2C NACK) ... ABORT ...
Nothing was written` while GPIO shows SCL and SDA both high on a live pull-up.
That is a separate open question about the pot itself and is NOT explained by
this track's findings.

### 11.2 Teeth

`AXISEL_SELFTEST=1 tclsh tcl/axi_select.tcl` runs 12 cases against Vivado stubs,
no hardware, and is now a board-free gate in `pcieep_build.sh`. Vectors include
the engine build and the thermal build as MEASURED, the two-master first-light
build, the SAME two roles at swapped ordinals, link-down (only the free-running
aux master answers), an unconfigured card, and two masters that both look like
memory.

Mutations run against it, and this is the part worth re-reading:

| mutation | bit? |
|---|---|
| M1 `fk33_axi_pick` falls back to the first candidate instead of erroring | **yes**, 6 fails |
| M2 aux and axil signatures swapped | **yes**, 8 fails |
| M3 `fk33_axi_pick` always returns `hw_axi_1` (the old behaviour) | **yes**, 9 fails |
| M4 `dead` (no answer) classified as `mem` | **NO** -- see below |

**M4 did not bite, and that is the most useful row.** With `dead` collapsed into
`mem`, the link-down vector has TWO masters classifying as `mem`, so the pick
still refuses -- for the wrong reason. The suite could not tell "refused because
nothing answered" from "refused because two things answered". Closed by adding
`onedead/mem`: one live memory master alongside one silent one must still pick
the live one. M4 now fails that case, and only that case.

---

## 12. Open, not determined

* **Which 32-bit half `lindex [report_hw_axi_txn -t d4] 1` returns on a 64-bit
  master.** Probe P3 settles it in one transaction. Until it is settled, every
  `jtag_hbm` reading in this project's logs, including `0x4D563449` in
  `aux_probe.log`, is one of two adjacent words and it is not known which.
* **Whether a 32-bit `-data` write on a 64-bit master zeroes the other half.**
  Probe P4. If it does, JTAG writes to memory have been clobbering 4 adjacent
  bytes for as long as `jtag_hbm` has been used.
* **Whether Vivado enforces `M_AXI_ADDR_WIDTH` on `create_hw_axi_txn` or
  silently truncates.** Probe P2. Truncation would be worse: `0x200000000` on
  `jtag_aux` becomes `0x00000000`, which is `aux_id` and answers.
* **Why the pot does not acknowledge on the host path.** Separate question, not
  touched here.
* **`pcieep_jtag.tcl` still contains the two defects in section 6.2.** The
  dispatcher owns that file and this track did not edit it.
* **`hbmbw.tcl` and `hbmdiag.tcl` were changed but cannot be run** -- they need
  the hbmbw bitstream, which is not loaded. Their edits are checked by
  `info complete` and by inspection only.
