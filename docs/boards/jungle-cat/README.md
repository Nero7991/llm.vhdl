# SQRL Jungle Cat: a user guide

This is the current state of what is known about the SQRL Jungle Cat board, written for
someone who wants to use one. It consolidates the dated logs listed in the file index at
the end. Where those logs were corrected later, this file states the corrected fact.

Labels: **MEASURED** (a tool or instrument read it, the evidence is linked), **DERIVED**
(arithmetic from measured numbers), **ESTIMATE** (an assumption is named). The board is
reached only over its Ethernet BMC. Addresses below are placeholders: `<bmc-ip>` is the
BMC, `<host>` is the Linux machine on the same link.

## 1. What the board is

| Item | Value | Basis |
|---|---|---|
| Carrier | JCC2L-A7, silkscreen "JCC-Lite Rev A3" | photos, [bring-up S12](2026-09-27_bringup.md) |
| Modules | two JCM35P, slots A and B | MEASURED, [bring-up S5](2026-09-27_bringup.md) |
| FPGA per module | one XCVU35P, IDCODE `14b71093`, two SLRs | MEASURED by `sqrl_bridge` |
| HBM per module | 8 GiB, two stacks of 4 GiB | the loader's HBM map, [loader README](../../../hw/jc/loader/README.md) |
| BMC | STM32F765 with a LAN8742 10/100 Ethernet PHY | parts read from the board, [bring-up S15](2026-09-27_bringup.md) |
| Host link | RJ45, 100 Mbit full duplex | MEASURED, [host path S10](../../debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md) |
| Other connectors | micro-USB to the BMC (vendor protocol, see below), 3 PCIe 8-pin power inputs (3 more unpopulated), an SD card slot | photos, [bring-up S2, S7, S8](2026-09-27_bringup.md) |
| Module connector | proprietary high-density mezzanine, not FMC; part number not identified | photos, [bring-up S8, S14](2026-09-27_bringup.md) |

**Part string.** The bitstreams that have run on these modules were built for
`xcvu35p-fsvh2104-1-e` (census, JTAG-AXI probe, weight loader) and
`xcvu35p-fsvh2104-2L-e` (pin finder). Both configure the module. SQRL's own reference
bitstream header says `xcvu35p-fsvh2104-2L-e` (MEASURED from the file), so -2L is what the
vendor targeted. The silicon grade itself has not been read. Using `-1-e` gives
conservative timing.

**The micro-USB port** (`3122:c0ed`, "SQRL CoU Interface", vendor class, WinUSB) is not a
JTAG cable and no public tool speaks it. The BMC has a DFU bootloader, so do not send it
unknown commands ([bring-up S2](2026-09-27_bringup.md)). Use Ethernet.

**The SD card** is the BMC's local storage. It is not reachable over the network
(MEASURED port scan, [bring-up S7](2026-09-27_bringup.md)). It is not a weight load path.

## 2. Power and cooling

- Power enters through the PCIe 8-pin connectors. 12 V reaches each module through the
  mezzanine connector.
- **Cooling.** The modules sit under water blocks. With no coolant flowing they idle at
  about 40-65 C with no bitstream or a light one (MEASURED, `sqrl_bridge` telemetry,
  2026-09-27 and 2026-10-05/06). Module B idled about 20 C hotter than module A. Get
  coolant flowing, or fit fans, before running a heavy design. The working rule on
  2026-09-27 was a cooling budget of about 50 W for the whole board; SQRL's full miner
  bitstream and any real inference build exceed it.
- The vendor XDC has a fan PWM output on G9 (with a pulldown) and a fan sense input on
  H9. The project's bitstreams drive `fan_ctl` high. An unconfigured module may not drive
  a fan at all.
- HBM catastrophic-trip outputs exist per stack. The loader shows their OR on LED_C.

## 3. VCCINT and telemetry

- **Default VCCINT is 0.850 V** on this board (MEASURED, 0.853 V module A, 0.850 V
  module B, [bring-up S5](2026-09-27_bringup.md)). This is the vendor's own setting.
  Rules written for other SQRL boards (for example the FK33) do not transfer.
- `sqrl_bridge` can set VCCINT through its third argument. Pass `skip` to leave it alone.
  Nothing in this project has changed it.
- Telemetry printed by `sqrl_bridge` on connect (MEASURED): per-SLR temperature, VCCINT,
  VCCAUX (about 1.79 V), VCCBRAM (about 0.855 V), HBM VRM (about 1.23 V), DNA, USER and
  USER128 fuses, USR_ACCESS, and the carrier/module/LED fields.
- The vendor XDC has `err_vccint` on D13: an open-collector over-temperature or
  over-current flag from the PMIC (A3 carriers). Leave it as an input with a pullup.

## 4. Network setup

The BMC uses DHCP and announces itself over mDNS on link-up only: services
`_sqrl-coe._tcp` (TCP 21363) and `_sqrl-ipcfg._udp` (UDP 21347), hostname
`SQRL-JCC-<serial>`. A directed mDNS query gets no answer (MEASURED,
[bring-up S4, S13](2026-09-27_bringup.md)).

The setup that worked was a direct cable from the BMC to a spare host NIC:

1. Take the NIC away from NetworkManager and give it a static address, for example
   `192.0.2.1/24`.
2. Run dnsmasq on that NIC with a DHCP range in the same subnet.
3. Open the host firewall for that NIC. A default-drop INPUT policy silently drops the
   BMC's DHCP request (MEASURED, this was the real blocker).
4. Bounce the link. The BMC leases an address within seconds.

The only open TCP port on the BMC is 21363. There is no web, SSH or telnet interface.
Do not probe the ipcfg UDP service blind: it is an IP-configuration service and may move
the BMC off its address. A host reboot clears a non-persistent version of this setup, and
a dead ping then measures the host, not the board.

## 5. Programming over CoE with `sqrl_bridge`

`sqrl_bridge` is SQRL's Linux x86-64 loader from `sqrl_eth_release_v1.3.1_public.zip`
(August 2020). The vendor download site is gone. A copy survives on the Wayback Machine:
`https://web.archive.org/web/20220708112532id_/https://download.squirrelsresearch.com/sqrl_eth_release_v1.3.1_public.zip`.
It needs only glibc and libstdc++. It loads any standard unencrypted Vivado `.bit`.

Command shape for the Jungle Cat (CoE, "Chip over Ethernet"):

    sqrl_bridge C<bmc-ip> <bitstream.bit | skip> <vccint | skip> [<xvc-port>]

| Use | Command |
|---|---|
| Read-only query (IDCODE, DNA, telemetry) | `sqrl_bridge C<bmc-ip> skip` |
| Load a bitstream onto both modules | `sqrl_bridge C<bmc-ip> design.bit,design.bit skip` |
| Load and open Vivado access | `sqrl_bridge C<bmc-ip> design.bit,design.bit skip 2542` |
| Vivado access only, no reprogram | `sqrl_bridge C<bmc-ip> skip skip 2542` |

**The fifth argument is undocumented.** It is the XVC server port. Without it the XVC
thread never starts (MEASURED and found by static analysis, [bring-up S6](2026-09-27_bringup.md)).
Then in Vivado:

    open_hw_manager
    connect_hw_server -url localhost:3121
    open_hw_target -xvc_url localhost:2542

Both devices appear as `xcvu35p_0` and `xcvu35p_1`.

**Traps, all MEASURED:**

- **Only the first file of a comma list is used.** `sqrl_bridge C<bmc-ip> a.bit,b.bit`
  loads `a.bit` onto both devices (2026-10-06, the log printed `Using Bitstream a.bit`
  for device 0 and device 1). Earlier loads used the same file twice, which hid this.
  To put different designs on the two dies you need a different method; none is
  established yet.
- **`open_hw_target` over XVC fails about half the time** with "No devices detected" and
  then succeeds. Retry it up to 8 times in your Tcl. Once open it is stable.
- **A trailing `Labtools 27-2269 No devices detected`** after a successful batch run is
  teardown noise. Gate on your own sentinel, not on the absence of `ERROR`.
- **XVC `settck` is a no-op.** The bridge echoes any period, including 1 ns.
- **XVC shifts must be at most 16,384 bits.** The `getinfo` reply `xvcServer_v1.0:4096`
  is the combined TMS plus TDI byte count. A 32,768-bit shift hangs the connection and
  kills the bridge's XVC thread. Restart the bridge with `skip skip 2542` to recover; the
  loaded design is not affected.
- **The bridge's JTAG clock is fixed at 13.5 MHz** (an immediate in the binary, no CLI
  option). A copy with the 4 bytes at file offset 0x6fae changed from 13500000 to
  27000000 runs clean at 27 MHz. The direct client in section 6 sets its own clock and
  does not need this.
- **Stopping a bridge.** Identify it by `/proc/<pid>/exe`. Process names longer than 15
  characters do not match `pkill -x`, and an old bridge that keeps port 2542 breaks the
  next one.
- **One BMC client at a time.** Stop `sqrl_bridge` before running the direct CoE tools,
  and stop them before restarting the bridge.
- Bitstream configuration runs at about 0.7-1.4 MB/s (MEASURED, [bring-up S10](2026-09-27_bringup.md)).

## 6. The CoE protocol (summary)

Reverse-engineered from packet captures of `sqrl_bridge` on 2026-10-05
([host path S12](../../debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md)).
Implemented in `tools/jc/coe.py`, which sends only commands observed from the stock
bridge.

- TCP to port 21363. Little-endian. Request: `u16 total_len | u16 txn | u32 cmd |
  payload`. Reply: `u16 len | u16 txn | u32 0x8000000a | data`.
- **txn bit 15 is not a counter bit.** txn 0x8000 draws a 4-byte error reply. Wrap
  below 0x8000.

| Command | Meaning |
|---|---|
| `0x80001000` | hello |
| `0x8000100c` | JTAG clock: `u32 0, u32 Hz` |
| `0x80001001` | mode (`0002` at init, `0001` before shift traffic) |
| `0x80001010` | IDCODEs (returns `14b71093` twice) |
| `0x80001011` | IR lengths (`000c0c`: 12 bits per die) |
| `0x80001012` | sysmon and DNA register scans |
| `0x8000100e` | shift with TMS: `u8 dev, u8 flags, u16 nbits`, then (TDI, TMS) byte pairs |
| `0x8000100f` | shift TDI only, TMS held 0: `u8 dev, u8 0x20, u16 nbits, TDI`; TDO streams back |
| `0x80001110` | telemetry poll (the bridge sends these on the same socket) |

**JTAG clock (MEASURED).** 13.5 MHz and 27 MHz work. Requests of 36 and 40.5 MHz run at
27 MHz. 54 MHz corrupts the scan (wrong IDCODE, zero DNA) but did no damage. **27 MHz is
the top usable setting.**

**Rates (MEASURED, BYPASS loopback, full bit check over 100 MB):**

| Path | Rate |
|---|---|
| Vivado `jtag_axi` through the bridge | 39 KB/s (about 23 ms per transaction, any size) |
| Raw XVC through the stock bridge, 13.5 MHz | 1.0 MB/s |
| Raw XVC through the 27 MHz bridge | 1.42 MB/s |
| Direct CoE client, 27 MHz, 4 requests in flight | **2.68 MB/s** |

The bridge waits for each reply before sending the next request; the BMC accepts several
in flight, which is why the direct client is faster. Larger commands (32,768 bits) do not
help once pipelined. The limit is the BMC's shift engine, about 22 Mbit/s (DERIVED).

**Stale replies.** The BMC can hold a reply from a previous connection and deliver it to
the next one (MEASURED: a HELLO got back txn 0x0000). `CoE.start()` discards anything that
arrives until 0.3 s pass quietly, before sending any command.

## 7. JTAG chain and IR safety

- **Chain order (MEASURED 2026-10-06):** device 0 is nearest TDI. Device 0 is module A,
  which Vivado names `xcvu35p_0`. Use `--chain AB` with the loader.
- In BYPASS each die adds one bit of delay; the chain delay is 2.
- **Shift only these IR values: BYPASS `0xFFF`, IDCODE `0x249`, USER3 `0x8A4`, USER4
  `0x8E4`** (12-bit IR per die). The VU35P IR also holds JPROGRAM and eFUSE-programming
  opcodes (see the vendor BSDL, `xcvu35p_fsvh2104.bsd`). A stray IR shift can wipe the
  configuration or burn fuses permanently. `tools/jc/coe.py` enforces this allowlist and
  tracks the TAP state; keep that guard if you write your own client.
- **Die identity.** Vivado exposes each die's DNA as `REGISTER.DNA.SLR0` (`0x` plus 32
  hex digits; the 24 low digits are the DNA). The loader's `DNA_PORTE2` readout in fabric
  matches it bit for bit, not reversed (MEASURED 2026-10-06). It is not
  `REGISTER.EFUSE.FUSE_DNA`.
- **`jtag_axi` masters show generic names** (`hw_axi_1` to `hw_axi_4`) even with the
  `.ltx` loaded. Select a master by `CELL_NAME`, for example
  `get_hw_axis -of_objects $dev -filter {CELL_NAME =~ *jtag_hbm}`.
- Keep DNA values out of version control. The loader refuses to write its die record or
  checkpoints inside any git checkout.

## 8. Clocks

| Clock | Pins | Source | State |
|---|---|---|---|
| `sysclk` | BC26 / BC27, bank 65, LVDS, 100 ohm DIFF_TERM, DQS_BIAS | oscillator on the module | **live, 200.0 MHz** on both dies, stable to 0.07% (MEASURED) |
| `sysclk_ext` | G10 / F10, bank 67 | carrier | dead (MEASURED) |
| `sysclk_ext2` | F13 / F12, bank 67 | carrier | dead (MEASURED) |
| GTY refclks | all 16 MGTREFCLK inputs, banks 124-131 | carrier X1/X2 sites | **none present** (MEASURED) |
| CFGMCLK | internal (STARTUPE3) | FPGA | 48.57 MHz on the unit measured (spec 50 MHz +-15%) |

Evidence: the clock census bitstream ([bring-up S11, S14](2026-09-27_bringup.md)) counted
edges on every input, six samples each, with BC26 as the stability control. A floating
GTY refclk input picks up noise and can read like a clock once: AD38 read 24-28 M per gate
on one die, swinging 10%. **Always take several samples next to a known clock.** IBERT
also showed `REFCLKLOST=1` on both quad-126 QPLLs ([bring-up S9](2026-09-27_bringup.md)).

A GTY PLL cannot take its reference from fabric or from BC26, so **no transceiver works
on this carrier as shipped.**

### The GTY refclk fix (designed, not yet fitted)

The carrier has two unpopulated clock sites, **X1 and X2**, both are under one module socket.
Each is a two-part chain: a small 6-pad LVDS oscillator feeding a 16-pin QFN 1:4 fanout
buffer, with R35 (X2) or R4 (X1) as the 100 ohm termination between them and 8 AC
coupling caps on the outputs. Sites are reachable only with the modules removed.
[Bring-up S15, S16 and its 2026-10-04 correction](2026-09-27_bringup.md).

Current BOM, per site (the earlier CDCLVD1204 / 2.5 V version is withdrawn):

| Item | Part |
|---|---|
| Fanout buffer | TI LMK1D1204RGTR (pin-compatible with CDCLVD1204, VDD 1.71-3.465 V) |
| Oscillator | SiTime SIT9501AI-02A2-YY10-156.250000E (LVDS, 2.5 x 2.0 mm, 156.25 MHz, +-25 ppm) |
| R4 / R35 | 100 ohm 0603, 1% |
| Caps | 100 nF 0603 X7R: 8 output AC, 2 bypass |

Facts the BOM depends on:

- **The clock rail is 3.3 V** (MEASURED 3.387 V, multimeter, 2026-10-04). CDCLVD1204 is
  rated 2.375-2.625 V and must not be fitted.
- **IN_SEL (buffer pin 2) is open on the board.** Open IN_SEL disables the inputs on this
  whole part family. **Solder-bridge pin 1 (GND) to pin 2.** Check: 0 ohm to GND
  unpowered, 0 V powered (about 1.3 V means the bridge is missing).
- VAC_REF (pin 8) stays open (the input is DC-coupled).
- SiT9501 pin 1 is OE, active high with an internal pull-up. Confirm the pad is not
  grounded.
- Datasheets: [`docs/datasheets/`](../../datasheets/) (LMK1D1204, CDCLVD1204,
  8SLVD1204-33, SiT9501).

**Acceptance test:** load the clock census and read AD38 (`MGTREFCLK0P_126`) several
times. A nonzero count that is stable across samples means the clock arrives. Constrain
IBERT or Aurora to 156.25 MHz to match.

## 9. Inter-module GTY pairs

- 16 differential pairs run slot to slot on the carrier (counted on the board). One quad
  between two modules uses 8 pairs, so DERIVED: two quads, 4 lanes each way per quad.
- The vendor XDC's Aurora refclk `aur_ref_clk_p` is AD38 = `MGTREFCLK0P_126`, GTY quad
  126 (`GTYE4_COMMON_X0Y2`) (MEASURED, Vivado part query, [bring-up S1](2026-09-27_bringup.md)).
  Quad 126 lane pins are in [`quad126_pins.txt`](quad126_pins.txt). Refclk pins of quads
  124-128 (REFCLK0/REFCLK1, P side): 124 AK38/AH38, 125 AF38/AE36, 126 AD38/AC36,
  127 AB38/AA36, 128 Y38/V38.
- Which second quad carries the other 8 pairs, and which X1/X2 output reaches which
  module's MGTREFCLK, are not known. No link has been brought up.

## 10. Loading weights into HBM

The loader is a bitstream with a BSCANE2 receiver on **USER4** that writes frames into
HBM, plus a host tool that streams them over the direct CoE client.

- Bitstream: [`hw/jc/loader/results/2026-10-05/full/jc_loader.bit`](../../../hw/jc/loader/results/2026-10-05/full/)
  with its `.ltx`. Clocks from BC26 through a clk_wiz. Also contains two `jtag_axi`
  masters on USER1 for independent readback: `jtag_axi_0` (8 KB BRAM at `0xC0000000`)
  and `jtag_hbm` (HBM port SAXI_16, 64 bits wide).
- Host tool: `tools/jc/coe_load.py` with `identify`, `load` and `verify`.
- **Measured 2026-10-06:** a 7.1 GB 27B card image on die A (7,170 pieces) and a second
  image on die B (6,750 pieces). Every piece's range CRC matched, `JCVERIFY_PASS`, and
  1,000 of 1,000 random 256-byte windows per die read back through `jtag_hbm` matched the
  files. Rate about 2.6 MB/s while streaming.
  [Host path S14](../../debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md).
- **The BMC ends each CoE connection after about 290 s of streaming**, alternately by
  TCP reset and by silence (MEASURED). Packet loss was measured and rejected as the cause:
  drop and retransmit counters did not move during a connection that ended in a reset.
  The loader resumes from the die's own committed sequence number, so a full die takes
  about 10 connections and **42-54 minutes** of wall time.

Procedure (run each step only after the previous one passed):

1. Load the loader onto both dies and stop the bridge:
   `sqrl_bridge C<bmc-ip> jc_loader.bit,jc_loader.bit skip` (expect `Bitstream Loaded` and
   `Houseclean OK` per device).
2. Record each die's identity once, in a file outside any git checkout:

       python3 tools/jc/coe_load.py identify --bmc <bmc-ip> --die A --chain AB --dies /path/outside/repo/dies.json
       python3 tools/jc/coe_load.py identify --bmc <bmc-ip> --die B --chain AB --dies /path/outside/repo/dies.json

   Cross-check each printed DNA against Vivado's `REGISTER.DNA.SLR0` for `xcvu35p_0`
   (die A) and `xcvu35p_1` (die B). `identify` cannot detect a wrong `--chain` by itself.
   `load` and `verify` refuse a die whose DNA does not match the record.
3. Load. The first run is plain; every later run adds `--resume`. Pass `--ckpt` with a
   path outside the repo (the built-in default is a directory on the author's machine):

       python3 tools/jc/coe_load.py load card0/manifest.json --bmc <bmc-ip> --die A --chain AB \
           --dies /path/outside/repo/dies.json --ckpt /path/outside/repo/A.ckpt.json

   Repeat with `--resume` until a run prints a line starting `JCLOAD_DONE`. Stop and read
   the log on a line starting `JCLOAD_ABORT`. The auto-resume loop is not yet a committed
   tool.
4. Verify (re-reads every piece's range CRC from HBM): the same arguments with `verify`
   instead of `load`. Gate on a line starting `JCVERIFY_PASS`.
5. Spot check, independent of the loader (different BSCAN chain, AXI master and HBM port).
   Stop the CoE tools, restart the bridge with `skip skip 2542`, start `hw_server`, then:

       python3 tools/jc/spot_check_manifest.py gen card0/manifest.json 1000 <seed> addrs.txt expect.txt
       vivado -mode batch -source tools/jc/spot_check.tcl -tclargs addrs.txt <die-dna-24-hex> spot.txt jc_loader.ltx
       python3 tools/jc/spot_check_manifest.py cmp expect.txt spot.txt

   Expect `SPOT_COMPARE windows=1000 expected=1000 match=1000 bad=[]`. The Tcl picks the
   device by DNA, never by list position.

Optional: `load --corrupt-seq N` flips one payload bit in frame N on its first send, to
show on silicon that the die's CRC check rejects it and the loader resends it
(MEASURED: `crc_fail=1 resyncs=1`, then verify passed). The `MB/s` on the final line of a
resumed load was computed over the whole plan in an earlier version; it now reports the
bytes that run sent.

## 11. Pins

From the vendor XDC [`JCCL2-JCM35.xdc`](JCCL2-JCM35.xdc). All general I/O listed is
LVCMOS18 (1.8 V) unless stated.

| Function | Pins | Notes |
|---|---|---|
| Module oscillator | BC26 / BC27 | 200 MHz LVDS, see section 8 |
| Carrier clock inputs | G10 / F10, F13 / F12 | LVDS pairs, carrier side dead |
| LEDs | LED_A K10, LED_B K9, LED_C J9, LED_D J10, RGB R K11, G L12, B L11 | |
| Fan | `fan_ctl` G9 (pulldown), `fan_sense` H9 (pullup) | |
| `jcm_sync` | H12 | GPIO chained across all modules to the BMC, pullup; vendor recommends open drain |
| `err_vccint` | D13 | PMIC fault input, pullup |
| UART to BMC | `uart_rx` E10, `uart_tx` E11 | the bridge's virtual serial port (TCP 2000) |
| I2C to PMIC | SCL E9, SDA F9 | |
| I2C global | SCL B9, SDA B10 | |
| Secondary SPI flash | AV28, AW28, BB28, BC28, SS AW24 | |

**Candidates for bodge links or side channels** (1.8 V; routing on the carrier is NOT
verified): the dead carrier clock inputs G10/F10 and F13/F12 (usable as LVDS pairs), and
the seven LED pins. Do not drive H12 (`jcm_sync` may be a shared net). Leave the config
SPI, UART, both I2C buses and `err_vccint` alone; the BMC and PMIC use them.

The pin finder ([`hw/jc/pinfinder/`](../../../hw/jc/pinfinder/README.md)) drives a
distinct square wave (1-11 kHz on variant A, 12-22 kHz on variant B) on each of those 11
pins, so a multimeter in frequency mode can locate them on carrier footprints. Both
variants are built. **Probing has not been done yet.** Because of the comma-list trap,
the bridge puts the same variant on both modules.

Bank facts (MEASURED, Vivado `DIFF_PAIR_PIN` query): BC26/BC27 bank 65; G10/F10, F13/F12
and all LED pins bank 67. LED pairs in bank 67: K10/K9, J9/J10, K11/L11.

## 12. Not known yet

- What sets the ~290 s connection life: a BMC timer, a byte count or a command count.
  Proposed test: one connection at `--hz 13500000`. If it still lasts ~290 s it is a
  timer and the client can reconnect before it.
- Why connections end alternately by reset and by silence, and why die B's first
  connection of a session twice lasted only about 1 minute.
- How to load two different bitstreams onto the two dies.
- Whether the GTY refclk fix works: X1/X2 parts are ordered, not fitted. Which X1/X2
  output reaches which module, and whether the refclk net is shared.
- Which second GTY quad carries the other 8 slot-to-slot pairs, and the link rate the
  carrier supports. No IBERT link has run.
- Routing of the bodge-candidate pins on the carrier (pin finder not yet probed).
- The silicon speed grade of these modules.
- A safe VCCINT range other than the 0.850 V default.
- The cooling capacity once coolant flows.
- What the SD card holds, and whether the BMC firmware can do anything beyond CoE JTAG.
- What the ipcfg UDP service accepts.
- The mezzanine connector's part number.

## 13. Projections (ESTIMATE, not measured)

From [`docs/2026-09-24_jungle-cat-performance-estimate.md`](../../2026-09-24_jungle-cat-performance-estimate.md),
written before any inference ran on this board. Each figure rests on a model fitted to
the FK33 and named assumptions in that file.

- 9B split across the two dies, 75 MHz, the FK33 RTL unchanged: about 7 tok/s prefill and 3.4
  tok/s generation at short context, the same per die as the FK33 pair.
- 27B on two dies as a pipeline, 75 MHz, as built: about 2 tok/s prefill and 1.1 tok/s
  generation at short context, 0.47 tok/s at 16k. Resized to the die: about 3 tok/s
  generation at short context.
- Four VU35Ps (two boards) under 4-way tensor parallelism at 200 MHz: about 25 tok/s
  generation at short context. This needs the GTY link and an all-reduce ring.

## 14. File index

| Path | What |
|---|---|
| [`2026-09-27_bringup.md`](2026-09-27_bringup.md) | Bring-up log: network, `sqrl_bridge`, XVC, clocks, X1/X2, BOM (S1-S16 with corrections) |
| [`../../debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md`](../../debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md) | Host path: JTAG-AXI, XVC rates, TCK, CoE protocol (S12), loader on silicon (S14) |
| [`JCCL2-JCM35.xdc`](JCCL2-JCM35.xdc) | Vendor module pinout |
| [`quad126_pins.txt`](quad126_pins.txt), [`pinq_aurora_refclk.tcl`](pinq_aurora_refclk.tcl) | Quad 126 pin query and its script |
| `01_*.png` to `10_*.jpg`, `images_from_oren/` | Board photos (X1 close-up `IMG_8249.jpeg`, X2 `IMG_8253.jpeg`) |
| [`../../datasheets/`](../../datasheets/) | Refclk buffer and oscillator datasheets |
| [`../../../hw/jc/census/`](../../../hw/jc/census/) | Clock census bitstreams (banks 124-128 and 127-131) |
| [`../../../hw/jc/axiprobe/`](../../../hw/jc/axiprobe/README.md) | JTAG-AXI bandwidth probe |
| [`../../../hw/jc/loader/`](../../../hw/jc/loader/README.md) | HBM weight loader bitstream and build |
| [`../../../hw/jc/pinfinder/`](../../../hw/jc/pinfinder/README.md) | Pin finder bitstreams |
| [`../../../hw/jc/xvcstream/`](../../../hw/jc/xvcstream/) | `xvc_bypass_rate.py` (raw XVC rate), `coe_stream.py` (direct CoE rate) |
| [`../../../tools/jc/`](../../../tools/jc/) | `coe.py` (CoE client), `coe_load.py` (loader host), `spot_check*` (readback) |
