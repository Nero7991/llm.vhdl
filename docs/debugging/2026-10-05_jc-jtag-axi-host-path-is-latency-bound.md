# Jungle Cat host path: JTAG-AXI over CoE is latency-bound at ~23 ms per transaction

## 1. The question (2026-10-05)

Can the Jungle Cat's only no-new-hardware host path, CoE JTAG via SQRL `sqrl_bridge`
plus Xilinx `jtag_axi`, load the 27B weights (~7 GB per die on a 2-die pipeline split)
in a usable time? Hardware: JCC2L-A7 Lite carrier, two JCM35P (VU35P) modules, BMC on
the BC-250's `enp4s0`, XVC on BC-250 port 2542, Vivado 2023.2 `hw_server` on the
BC-250. Bitstream: `hw/jc/axiprobe/` (`jtag_axi` -> `axi_bram_ctrl` -> 8 KB BRAM at
0xC0000000, 32-bit data, CFGMCLK), loaded on both dies.

## 2. The answer

**No.** MEASURED: every JTAG-AXI transaction costs about **20-26 ms regardless of size**
(4 B to 1 KB), so bandwidth is simply burst size divided by a fixed latency. The best
measured rate is **39.3 KB/s write / 38.6 KB/s read** at the 256-beat maximum burst,
which is **48 h for 7 GB**. Doubling the AXI data width to 64 bits (2 KB bursts) would
still be about 24 h (DERIVED from the flat latency). JTAG-AXI as a weight-load path is
a no-go; the extrapolation in `hw/jc/axiprobe/README.md` ("~KB/s") is confirmed.

## 3. The procedure

1. Restored the BC-250's JC network after a reboot had cleared it: `enp4s0` unmanaged,
   static <host-ip>/24, `ufw allow in on enp4s0`, dnsmasq on `enp4s0`, link bounce.
   BMC re-leased <bmc-ip> within 4 s.
2. `sqrl_bridge C<bmc> jc_axiprobe.bit,jc_axiprobe.bit skip 2542`: both dies
   `Bitstream Loaded`, XVC listening.
3. `hw_server` on the BC-250, then `vivado -mode batch -source
   hw/jc/axiprobe/measure_jtag_axi.tcl`: 200 writes then 200 reads per burst length
   (1, 4, 16, 64, 256 beats), wall-clock timed in Tcl, then **one readback compared
   against a per-length pattern** (`5A0000LL`), so a stale BRAM from a previous length
   cannot pass and a number is only meaningful for writes that landed.

## 4. Evidence (raw, `hw/jc/axiprobe/axibw_run_2026-10-05.log`)

```
AXIBW_OPEN_RETRY 1: ERROR: [Common 17-39] 'open_hw_target' failed due to earlier errors.
AXIBW_DEVICES xcvu35p_0 xcvu35p_1
JTAG_AXI measuring on hw_axi_1 (xcvu35p_0), BRAM @ 0xc0000000
AXIBW len=1    burst=4    B iters=200  write 0.2 KB/s  read 0.2 KB/s  readback=OK  -> 7GB write in 10461.1 h
AXIBW len=4    burst=16   B iters=200  write 0.6 KB/s  read 0.7 KB/s  readback=OK  -> 7GB write in 3358.7 h
AXIBW len=16   burst=64   B iters=200  write 2.7 KB/s  read 2.6 KB/s  readback=OK  -> 7GB write in 696.1 h
AXIBW len=64   burst=256  B iters=200  write 10.5 KB/s  read 10.0 KB/s  readback=OK  -> 7GB write in 181.0 h
AXIBW len=256  burst=1024 B iters=200  write 39.3 KB/s  read 38.6 KB/s  readback=OK  -> 7GB write in 48.3 h
AXIBW_DONE
```

DERIVED per-transaction time (write): 19.5, 26.0, 23.2, 23.8, 25.5 ms at 4, 16, 64,
256, 1024 B. **Not monotone in size**: the scatter (6.5 ms) is larger than any size
trend, so this is a constant, not a slope. A two-point fit gives "2.13 us/byte, 458 KB/s
marginal ceiling", and **that figure is NOT a result**: it is a slope fitted to scatter
(CLAUDE.md, "a quantity that scatters is a mean").

## 5. Measured and REJECTED, do not retry

- **`jtag_axi` for weight load at any burst length.** 48 h per 7 GB at the maximum
  256-beat burst on a 32-bit bus; ~24 h at 64-bit by the flat latency. Larger bursts
  than 256 beats do not exist in AXI4.
- **Bigger `iters` or longer runs to "average out" the latency.** The cost is per
  transaction; more transactions cost proportionally more.

## 6. Measurement traps hit

- **The first `open_hw_target` fails** (`Common 17-39`) and the second succeeds,
  consistent with bringup doc S6. The script now retries up to 8 times; an unretried
  run would have reported "no target".
- **A trailing `ERROR: [Labtools 27-2269] No devices detected`** appears in the log
  after `AXIBW_DONE`, from teardown, and Vivado exits 0. It is not a measurement
  failure; gate on the anchored `^AXIBW_DONE` and the `readback=OK` fields, not on the
  absence of `^ERROR`.
- **A BC-250 reboot silently drops the JC network** (static address and dnsmasq are
  not persistent). A dead BMC ping measures that, not the board.

## 7. What is left, ESTIMATE, not measured

- A **streaming BSCAN loader** (a `BSCANE2` USER register shifting long DR scans
  straight into an HBM write FIFO, no per-word AXI transaction) would be bound by the
  CoE shift rate rather than transaction latency. The only measured CoE rate is the
  bitstream load at ~0.7-1.4 MB/s (bringup S10), which would put 7 GB at **~1.4-2.8 h
  per die**, and both dies share one chain, so ~3-6 h per full load. Unproven: the
  bridge has a documented large-shift hang, and it is not known whether a user-DR
  stream gets the config rate.
- The GTY paths (Aurora from an FK33 head, or a GTY Ethernet MAC) remain gated on the
  X1/X2 refclk populate (bringup S15-16); parts ordered 2026-10-04.

## 8. Open, not answered

- Whether long user-DR shifts over this bridge reach the config-load rate, or hang.
- Whether a ~3-6 h load per power cycle is acceptable for the 2-die 27B bring-up.

## 9. UPDATE 2026-10-05: the BSCAN-streamer spike. The TRANSPORT does ~1 MB/s; the 23 ms was Vivado

**Question.** Is the ~23 ms per transaction a property of the CoE bridge, or of
Vivado's `jtag_axi` protocol on top of it? Equivalently: what does a raw long-DR
stream (what a `BSCANE2` loader would see) actually get?

**Answer, up front.** It is Vivado. MEASURED with a raw XVC client
(`hw/jc/xvcstream/xvc_bypass_rate.py`, on the BC-250 against the bridge's port 2542),
both dies in BYPASS: **1,005.8 KB/s sustained over 100 MB at 16,384-bit shifts, zero
integrity errors, worst shift 2.84 ms, the XVC listener still up afterwards**. That
projects 7 GB in **1.9 h** per die through a streaming loader. Section 7's ESTIMATE
(1.4-2.8 h) is now a MEASURED transport bound.

**Procedure.** `hw_server` stopped (it holds the XVC socket). TAP reset, 64 ones into
IR (BYPASS on every device, non-destructive), then Shift-DR held for the whole stream
with TMS all zero. In BYPASS, TDO is TDI delayed by one bit per device; the delay is
found with a single-1 probe (**2**, both dies), then every ~997th bit of every shift is
checked against the random TDI stream delayed by 2, across shift boundaries. A shift
that never returns trips a 10 s socket timeout.

**Evidence (raw):**
```
XVCINFO xvcServer_v1.0:4096
XVCDELAY ones_at [2]
XVCRATE bits/shift=1024  shifts=7813  bytes=1000064   2.95s   330.8 KB/s  mean 0.38 ms/shift  worst 0.89 ms  bad_samples=0
XVCRATE bits/shift=2048  shifts=3907  bytes=1000192   1.85s   527.7 KB/s  mean 0.47 ms/shift  worst 0.62 ms  bad_samples=0
XVCRATE bits/shift=4096  shifts=1954  bytes=1000448   1.31s   745.0 KB/s  mean 0.67 ms/shift  worst 1.81 ms  bad_samples=0
XVCRATE bits/shift=8192  shifts=977   bytes=1000448   1.15s   846.4 KB/s  mean 1.18 ms/shift  worst 1.35 ms  bad_samples=0
XVCRATE bits/shift=16384 shifts=489   bytes=1001472   0.92s  1064.6 KB/s  mean 1.88 ms/shift  worst 2.02 ms  bad_samples=0
XVCRATE bits/shift=16384 shifts=48829 bytes=100001792 97.10s 1005.8 KB/s  mean 1.99 ms/shift  worst 2.84 ms  bad_samples=0
```
DERIVED: per-shift time is about 0.25 ms fixed plus ~0.1 us per bit (an effective
~10 Mbit/s against the bridge's reported 13.5 MHz CoE JTAG), so the largest shift wins.

**The shift-size ceiling is now pinned.** 16,384 bits (2,048 B TMS + 2,048 B TDI = the
4,096 B `getinfo` buffer) works; S10's 32,768 bits hangs. `getinfo`'s 4096 is the
COMBINED TMS+TDI byte count. A loader must shift at most 16,384 bits per XVC call.

**Measured and REJECTED, do not retry:** attributing the 23 ms to the bridge.
`jtag_axi` costs 50-100x the transport per word; the bridge is not the limit.

**Not yet determined:**
- This is the transport ceiling. A real loader also needs a `BSCANE2` USER register
  that accepts a bit per TCK into an HBM writer; at ~10 Mbit/s that is trivial fabric
  bandwidth, but it is unbuilt.
- Both dies share the chain, so loading both is ~14 GB at the same aggregate
  ~1 MB/s, ~3.9 h total (one DR scan can feed both USER registers at once, but the
  aggregate does not double).
- TCP pipelining (issuing the next shift before the reply) could hide part of the
  ~0.25 ms fixed cost; not tried.

## 10. UPDATE 2026-10-05: what limits the stream, and two speed-ups measured

**Question (Oren).** Can it go faster, and what is the limit: Ethernet (100 Mbit or
1 Gbit?) or JTAG?

**Answer, up front.** JTAG, set by the BMC's JTAG clock. Ethernet is 100 Mbit full
duplex (MEASURED, `enp4s0` speed 100, duplex full; the BMC PHY is a 10/100 LAN8742)
and the stream uses about 20% of it. `sqrl_bridge` hard-codes the CoE JTAG clock at
13.5 MHz (one immediate, `mov $0xcdfe60,%esi` at file offset 0x6fae, the 2nd argument
of the CoE speed call; no CLI option, and XVC `settck` is ignored). **A patched copy
asking for 27 MHz is accepted by the BMC and streams 1,422.8 KB/s sustained over
100 MB with ZERO bit errors under a full-bit check: 1.3 h per 7 GB die** (was 1.9 h).
TCP pipelining adds +13% at 13.5 MHz and nothing useful at 27 MHz.

**Procedure.** (1) Pipelining: the probe takes a `depth` argument and keeps that
many shifts outstanding on the socket. (2) Clock: `sqrl_bridge_tck27` = the stock
binary with the 4 bytes at 0x6fae changed from 13500000 to 27000000 (`cmp -l`: 4
bytes differ, nothing else); the stock binary is untouched. Bridge restarted with
`skip skip 2542` (no reprogram). 13.5 MHz = 108 MHz / 8 suggests an STM32 prescaler,
so 27 MHz (/4) is a native step. (3) The integrity check was upgraded from sampled
(every 997th bit) to EVERY bit (big-int compare of TDO against TDI delayed by d) for
the 27 MHz soak, since rare bit errors are the risk of a faster clock.

**Evidence (raw):**
```
# 13.5 MHz, pipelining depth sweep, 10 MB each, sampled check
XVCRATE depth=1 bits/shift=16384 ... 1007.4 KB/s  mean 1.99 ms/shift  worst 2.88 ms  bad_samples=0
XVCRATE depth=2 bits/shift=16384 ... 1107.9 KB/s  mean 1.81 ms/shift  worst 4.16 ms  bad_samples=0
XVCRATE depth=4 bits/shift=16384 ... 1140.6 KB/s  mean 1.75 ms/shift  worst 7.56 ms  bad_samples=0
# 27 MHz bridge log
CoE JTAG Initialized to 27000000 MHz
Board 0 Device 0 IDCODE(14b71093) Name: VU35P
Board 0 Device 0 DNA: <redacted>          <- identical to the 13.5 MHz read
# 27 MHz, sampled check
XVCRATE depth=1 bits/shift=16384 ... 1533.9 KB/s  mean 1.30 ms/shift  worst 1.52 ms   bad_samples=0
XVCRATE depth=4 bits/shift=16384 ... 1455.7 KB/s  mean 1.37 ms/shift  worst 934.04 ms bad_samples=0
# 27 MHz, FULL check
XVCRATE depth=1 bits/shift=16384 shifts=48829 bytes=100001792 68.64s 1422.8 KB/s mean 1.41 ms/shift worst 137.90 ms bad_bits=0
# teeth: same check with the delay forced off by one, then the control
XVCRATE depth=1 ... bad_bits=802562   (mutant, rc=1)
XVCRATE depth=1 ... bad_bits=0        (control, rc=0)
```
DERIVED: at 27 MHz a 16,384-bit shift is 0.61 ms of clock against 1.30-1.41 ms
measured, so per-shift overhead (~0.7 ms) is now about half the time; the clock is no
longer the whole limit.

**Measured and REJECTED, do not retry:**
- Pipelining at 27 MHz: 1,455.7 KB/s at depth 4 against 1,533.9 at depth 1, with a
  934 ms stall. Use depth 1.
- "Ethernet is the limit": ~20% of a 100 Mbit link at 1 MB/s. The BMC link ceiling
  (~12 MB/s) is far above any JTAG rate reached.

**Measurement traps hit.**
- The 13.5 MHz runs used the SAMPLED check (1 in 997 bits). Adequate for a rate
  number, NOT for clearing a faster clock; the 27 MHz verdict rests on the full check.
- One boundary-scan field read differently after the restart ("JungleCat Carrier: 1"
  before, "0" after, LEDs now lit). The probe bitstream was loaded between the two
  reads and drives those pins; IDCODE and DNA are bit-identical, so it is not read as
  a 27 MHz scan error. Not proven either way.

**Not determined.**
- 54 MHz (108/2): not tried. The FPGA's own TCK limit and the module wiring decide it.
- Whether the full-chain DR at 27 MHz is clean for USER registers (BYPASS only tested).
- State left: `sqrl_bridge_tck27` running on the BC-250 with XVC on 2542; both dies
  hold `jc_axiprobe.bit`. The stock `sqrl_bridge` is unmodified beside it.

## 11. UPDATE 2026-10-05: 54 MHz fails, 40.5 MHz is clean but buys ~4%. 27 MHz is the setting

**Evidence (raw):**
```
# 54 MHz (108/2): the BMC accepts the speed, the chain does not work
CoE JTAG Initialized to 54000000 MHz
Board 0 Device 0 IDCODE(296e2127) Name: MX2100          <- wrong (VU35P is 14b71093)
Board 0 Device 0 DNA: 000000000000000000000000
Failed to get SQRL JTAG Board 0 Device 0 USER Fuse: 3
# afterwards, at 13.5 MHz, Vivado: both dies still configured, probe intact
CHK xcvu35p_0 AXI=1 ... SLR0.BIT[14]_DONE_PIN=1 ... SLR1.BIT[14]_DONE_PIN=1 ... IR.BIT05_DONE=1
CHK xcvu35p_1 AXI=1 ... SLR0.BIT[14]_DONE_PIN=1 ... SLR1.BIT[14]_DONE_PIN=1 ... IR.BIT05_DONE=1
# 40.5 MHz (27 + 13.5, not a power-of-two divide of 108): scan clean, FULL check
CoE JTAG Initialized to 40500000 MHz
Board 0 Device 0 IDCODE(14b71093) ... DNA: <redacted>
XVCRATE depth=1 bits/shift=16384 shifts=4883  bytes=10000384  5.60s  1742.9 KB/s mean 1.15 ms worst 24.11 ms  bad_bits=0
XVCRATE depth=1 bits/shift=16384 shifts=48829 bytes=100001792 66.19s 1475.4 KB/s mean 1.36 ms worst 865.22 ms bad_bits=0
```

**Answer.** 54 MHz corrupts the scan (no data path at all); it did no damage (both
dies DONE, probe present). 40.5 MHz is error-free over 100 MB but sustains only
1,475 KB/s against 27 MHz's 1,423 (+4%), with an 865 ms stall. At 40.5 MHz the bits
of a shift take ~0.40 ms against 1.15-1.36 ms per shift: **the BMC's per-shift
overhead (~0.8-1 ms) is now the limit, not TCK.** Whether the BMC really clocks
40.5 MHz or rounds it (to 36 = 108/3?) is not determined; the rate cannot separate
those because overhead dominates. **27 MHz is the recommended setting**: same
sustained rate, more timing margin. Bridge left running at 27 MHz.

**Measured and REJECTED, do not retry:** 54 MHz (scan corrupt). Raising TCK further
to speed up the stream: the remaining time is per-shift overhead.

**Trap hit:** `pkill -x sqrl_bridge_tck27` matches nothing (Linux truncates process
names to 15 characters) and the old bridge kept port 2542; stop bridges by
`/proc/PID/exe`. The "Carrier 0 / Module A" boundary-scan change is NOT a 27 MHz
read error: the stock 13.5 MHz bridge reads the same with the probe loaded.

**Remaining lever:** the per-shift overhead is in the bridge/BMC protocol, which XVC
cannot batch beyond 16,384 bits. Going past ~1.5 MB/s means talking CoE directly
(protocol RE) or the GTY path.

## 12. UPDATE 2026-10-05: CoE protocol RE'd; a direct pipelined client doubles the rate. 2.68 MB/s, 43 min per die

**Question (Oren).** RE the CoE protocol: can talking to the BMC directly beat the
bridge? And why did 40.5 MHz give no speed-up?

**Answer, up front.** Yes. The bridge sends ONE CoE request and waits for its reply
before the next; the BMC accepts several in flight. A direct client
(`hw/jc/xvcstream/coe_stream.py`, bridge stopped) with 4 requests outstanding
streams **2,676.8 KB/s sustained over 100 MB at 27 MHz, zero bit errors (full check)
-> 0.71 h (43 min) per 7 GB die**, 1.9x the bridge. And **the BMC cannot run
40.5 MHz: any request between 27 and 54 MHz runs at 27** (MEASURED, below); 54 MHz
corrupts the chain (S11). 27 MHz is the real top of the JTAG clock.

**The protocol (from `tcpdump` on `enp4s0`, TCP to BMC port 21363):**
- Request: `u16 total_len | u16 txn | u32 cmd | payload` (LE). Reply:
  `u16 len | u16 txn | u32 0x8000000a | data`. Telemetry polls (`0x80001110`) share
  the socket. **txn bit 15 is not a counter bit**: txn 0x8000 drew a 4-byte error
  reply; wrap below 0x8000.
- `0x80001000` hello. `0x8000100c` speed: `u32 0, u32 Hz` (the bridge's 13.5 MHz).
  `0x80001001` mode (`0002` at init, `0001` before XVC traffic). `0x80001010` IDCODEs
  (returns `14b71093` x2). `0x80001011` IR lengths `000c0c` (12 bits per die).
  `0x80001012` sysmon/DNA register scans.
- `0x8000100e` shift with TMS: `u8 dev, u8 flags, u16 nbits`, then (TDI byte, TMS
  byte) pairs. `0x8000100f` shift TDI only with TMS held 0: `u8 dev, u8 0x20,
  u16 nbits, TDI`; the reply carries TDO, streamed back in ~350-byte chunks as it
  shifts. One XVC shift of 16,384 bits = one `0x8000100f` (2,052-byte payload).
- The client sends only these observed commands; its TAP moves were checked
  byte-for-byte against the bridge's captured requests before use.

**Evidence (raw):**
```
# direct client, 27 MHz, 16384-bit shifts
COERATE tck=27000000 depth=1 ... 1656.4 KB/s mean 1.207 ms/shift worst 1.28 ms  bad_bits=0
COERATE tck=27000000 depth=2 ... 2601.0 KB/s mean 0.769 ms/shift worst 41.70 ms bad_bits=0
COERATE tck=27000000 depth=4 ... 2666.7 KB/s mean 0.750 ms/shift worst 3.59 ms  bad_bits=0
COERATE tck=27000000 depth=4 bits/shift=16384 shifts=48828 36.48s 2676.8 KB/s mean 0.747 ms/shift worst 3.62 ms bad_bits=0
# the clock: depth 1, so time = fixed + 16384/TCK
COERATE tck=13500000 depth=1 ... mean 1.815 ms/shift
COERATE tck=27000000 depth=1 ... mean 1.187 ms/shift   (13.5 -> 27 saves 0.628 ms; 16384/TCK predicts 0.607)
COERATE tck=36000000 depth=1 ... mean 1.197 ms/shift   (a real 36 MHz would save 0.152 ms more)
COERATE tck=40500000 depth=1 ... mean 1.210 ms/shift   (a real 40.5 MHz would save 0.202 ms more)
COERATE tck=40500000 depth=4 ... 2670.7 KB/s            (= 27 MHz)
```

**CORRECTION to S10/S11:** the "+4% at 40.5 MHz" through the bridge was run-to-run
noise; the BMC was running 27 MHz. 13.5 MHz = 108/8 and 27 = 108/4 are consistent
with a power-of-two prescaler that rounds a request down; that mechanism is a
reading, not measured.

**Where the time goes now (DERIVED):** pipelined, 0.747 ms per 16,384-bit shift
against 0.607 ms of TCK, i.e. 81% of the 3.375 MB/s ceiling. The ~0.14 ms remainder
is BMC turnaround between commands; larger commands (the bit-count field is 16-bit,
so up to 65,528 bits) would amortise it, ESTIMATE ~3.0 MB/s at 32,768 bits. Not tried:
an oversized command may hang the BMC, which needs a carrier power cycle.

**Measured and REJECTED, do not retry:** TCK above 27 MHz (36 and 40.5 run at 27;
54 corrupts). Pipelining through `sqrl_bridge` (it serialises CoE internally; S10).

**Trap hit (mine):** my first client wrapped txn at 0xffff and both 100 MB soaks died
at txn 32768 with a 4-byte error reply. A 10 MB run (4,882 shifts) never reaches it.

**State left:** bridge STOPPED (the direct client owns the BMC socket while it runs).
Both dies hold `jc_axiprobe.bit`. Restart the bridge with
`./sqrl_bridge_tck27 C<bmc> skip skip 2542` (or the stock binary) for XVC/Vivado.

**Consequence for the loader:** the host side is now this client, not XVC. A
`BSCANE2` USER-register loader fed by `0x8000100f` streams at ~2.7 MB/s: ~43 min per
die, ~1.5 h for both on the shared chain.

## 13. UPDATE 2026-10-05: larger commands do not help. ~2.7 MB/s is the BMC's JTAG engine

**Evidence (raw, 27 MHz, full check, BMC ping after each):**
```
COERATE tck=27000000 depth=1 bits/shift=32768 shifts=488  0.91s 2150.0 KB/s mean 1.860 ms/shift worst 1.88 ms  bad_bits=0
COERATE tck=27000000 depth=2 bits/shift=32768 shifts=2441 3.63s 2688.3 KB/s mean 1.488 ms/shift worst 43.00 ms bad_bits=0
COERATE tck=27000000 depth=4 bits/shift=32768 shifts=2441 3.61s 2704.8 KB/s mean 1.479 ms/shift worst 6.42 ms  bad_bits=0
```
**Answer.** 32,768-bit `0x8000100f` commands are accepted (the BMC is not capped at
XVC's 16,384) and are clean, but pipelined they give 2,704.8 KB/s against 2,676.8 at
16,384 bits: the same. **S12's ESTIMATE of ~3.0 MB/s from larger commands is
WITHDRAWN**: pipelining had already hidden the per-command turnaround. The limit is
the BMC's effective shift rate, ~22.2 Mbit/s (DERIVED: 32,768 bits / 1.479 ms), 82%
of the 27 MHz TCK, consistent with the ~23 Mbit/s TDO chunk rate seen on the wire
(S12). 65,528-bit commands were NOT tried: no expected gain, and an unknown hang risk.

**Final figure for the host path:** ~2.7 MB/s, ~43 min per 7 GB die, ~1.5 h for both
dies on the shared chain, through a direct pipelined CoE client at 27 MHz.

**Measured and REJECTED, do not retry:** command size above 16,384 bits as a
throughput lever (no gain when pipelined).

## 14. UPDATE 2026-10-06: the BSCAN loader on silicon. Both 27B images loaded and verified

**Question.** Does the loader (branch `jc-loader`, bitstream
`hw/jc/loader/results/2026-10-05/full/jc_loader.bit`, sha256 `ece8aa08...4b281`, part
`xcvu35p-fsvh2104-1-e`) put a 27B card image into each VU35P's HBM correctly, at what rate,
and does anything independent of the loader agree?

**Answer.** Yes. Card 0's image (7.1 GB, 7,170 pieces) is in die A and card 1's (6,750 pieces)
in die B; every piece's range CRC, read back from HBM by the card, equals the CRC of the
file, and an independent JTAG-AXI readback of 1,000 random 256-byte windows per die matches
the files (1,000 of 1,000 on each die). The data rate is the measured ~2.6 MB/s, but the BMC drops
each connection after ~290 s of streaming, so a die takes ~10 resumed connections, about
42 min (die A) and 54 min (die B) wall time.

### Procedure, in order, and what each step isolates

1. `sqrl_bridge_tck27 C<bmc> jc_loader.bit,jc_loader.bit skip 2542`: `Bitstream Loaded` on
   devices 0 and 1, `Houseclean OK` each. **NOTE: the bridge loads only the FIRST file of a
   comma list onto every device** (MEASURED the same day with the pin finder: `Using
   Bitstream pinfinder_A.bit` for device 0 AND device 1). Every earlier load used the same
   file twice, which hid it.
2. `coe_load.py identify --die A|B --chain AB`: the DNA read through the loader's
   DNA_PORTE2 equals, digit for digit and NOT bit-reversed, the DNA the bridge reports for
   device 0 (die A) and device 1 (die B), and Vivado's `REGISTER.DNA.SLR0` of `xcvu35p_0`
   and `xcvu35p_1`. This settles three things at once: the chain order is AB (die A nearest
   TDI, Vivado device 0), the reader's bit-order ESTIMATE is right, and both dies' HBM
   calibrated (the DNA reader sits behind the core reset, which waits for both stacks'
   `apb_complete`). The record lives outside the repo (`--dies`); no DNA is written here.
3. 100 MB random file at `0x1_8000_0000` (stack 1), die A: load then verify.
4. Same 1,000-window spot check through `jtag_hbm` (BSCAN user chain 1, HBM SAXI_16): shares
   nothing with the loader (different BSCAN chain, AXI master and HBM port).
5. Fault injection: the same 100 MB plan on die B with `--corrupt-seq 1000` (one payload bit
   flipped after the CRC, first send only).
6. Card 0 to die A and card 1 to die B through an auto-resume wrapper (re-run
   `load --resume` until `JCLOAD_DONE`), then `verify`, then the manifest spot check
   (`tools/jc/spot_check_manifest.py`, 1,000 distinct windows inside random pieces).

### Evidence (raw)

```
# step 3, die A
JCLOAD_DONE last=52852 committed=52853 crc_fail=0 resyncs=0 pieces=1 matched 40 s 2.61 MB/s
JCVERIFY_PASS 1 pieces, 0 bad
# step 4, die A
SPOT_DEVICE xcvu35p_0 AXI hw_axi_2
SPOT_DONE 1000
SPOT_COMPARE windows=1000 match=1000 order=hi_first bad=[]
# step 5, die B
JCLOAD_DONE last=52852 committed=52853 crc_fail=1 resyncs=1 pieces=1 matched 40 s 2.60 MB/s
JCVERIFY_PASS 1 pieces, 0 bad
# step 6, die A (after two earlier connections A2, A3; see below)
ATTEMPT 1 rc=2 secs=298 ... (TimeoutError: timed out)
ATTEMPT 2 rc=2 secs=320 ... (ConnectionResetError)
ATTEMPT 3 rc=2 secs=323 ... (TimeoutError)
ATTEMPT 4 rc=2 secs=320 ... (ConnectionResetError)
ATTEMPT 5 rc=2 secs=323 ... (TimeoutError)
ATTEMPT 6 rc=2 secs=323 ... (ConnectionResetError)
ATTEMPT 7 rc=2 secs=319 ... (TimeoutError)
ATTEMPT 8 rc=0 secs=196 JCLOAD_DONE last=3593948 committed=3593949 crc_fail=9 resyncs=0 pieces=7170 matched
VERIFY rc=0 JCVERIFY_PASS 7170 pieces, 0 bad
# step 6, die B (after one earlier 56 s connection)
ATTEMPT 1 rc=2 secs=60 ... (ConnectionResetError)
ATTEMPTS 2-10 rc=2 secs=320 or 323, alternating ConnectionResetError / TimeoutError
ATTEMPT 11 rc=0 secs=151 JCLOAD_DONE last=3735241 committed=3735242 crc_fail=10 resyncs=0 pieces=6750 matched
VERIFY rc=0 JCVERIFY_PASS 6750 pieces, 0 bad
# step 6, manifest spot check through jtag_hbm, 1,000 distinct windows per die
die A: SPOT_DEVICE xcvu35p_0 AXI hw_axi_2 / SPOT_DONE 1000
       SPOT_COMPARE windows=1000 expected=1000 match=1000 bad=[]
die B: SPOT_DEVICE xcvu35p_1 AXI hw_axi_4 / SPOT_DONE 1000
       SPOT_COMPARE windows=1000 expected=1000 match=1000 bad=[]
```

Each attempt's `secs` includes ~30 s of hashing the 7 GB at planning, so a connection lives
~290 s. `crc_fail` is the die's count since configuration and includes frames cut off when a
connection dropped; the per-piece range CRCs show none of them landed. The `MB/s` printed
by the final attempt (40.54, 56.87) is WRONG: it divided the whole plan's bytes by that one
attempt's time. Fixed in this commit (the line now prints the bytes this run sent).

### Measured and REJECTED, do not retry

- **"The connection drops are packet loss on the BC-250 link."** During a 290 s connection
  that ended in a reset (A3), sampled every 10 s: `txdrop=508 tcp_retrans=217
  qdisc_drop=0` at every sample, start to end. No loss, no retransmission. The BMC ends the
  connection by itself.
- **"The BMC drops connections after a fixed one minute."** Die B's first two connections
  lasted ~56-60 s, but every other connection (20 of them) lasted ~290 s.

### Root-caused on the way: a stale reply from a previous session

The first 27B load (die A) aborted on its first exchange, 29 s in (all of it hashing):
`JCLOAD_ABORT txn mismatch: expected 0x0001, reply carried 0x0000`. Nothing had been sent but
the HELLO, so nothing was written. The bridge had been stopped seconds earlier; the BMC
still held a reply from that session and delivered it to the next connection (the bridge's
own log shows the mirror case, `Orphaned Transaction 0000`, when it connects after our
client). `CoE.start()` now discards whatever the BMC holds until 0.3 s pass with nothing
arriving, before any command (commit 32618d2; a test reproduces the exact error first).

### Measurement traps hit

- The spot check's first two runs found no device: Vivado exposes the DNA as
  `REGISTER.DNA.SLR0` (`0x` plus 32 hex digits), not `REGISTER.EFUSE.FUSE_DNA`; and the hw_axi
  `NAME`s are generic (`hw_axi_1..4`) even with the `.ltx` loaded, so the master is chosen by
  `CELL_NAME =~ *jtag_hbm`. `jtag_hbm` is 64 bits wide, so a 256-byte window is 32 beats.
- My first manifest spot-check generator drew windows with replacement; its teeth test
  showed a clean run would have reported failure (`expected=18` for 20 reads). Windows are
  now distinct.

### Open, not yet answered

- What sets the ~290 s connection life: a BMC timer, a command count, or a byte count. The
  rate was constant, so these are not separated. Run one connection at `--hz 13500000`: if
  it still lives ~290 s it is a timer; if ~580 s it is bytes or commands. If it is a timer,
  the client can reconnect proactively before it and avoid the 10 s timeout on every other
  connection.
- Why the connection ends alternately by RST and by silence (strictly alternating, both dies).
- Why die B's first connection of a session twice lasted only ~1 minute.
