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
   static 198.51.100.1/24, `ufw allow in on enp4s0`, dnsmasq on `enp4s0`, link bounce.
   BMC re-leased .58 within 4 s.
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
