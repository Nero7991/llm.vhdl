# Subsystem A on the AXU3EG: reserved-memory rejection, and where the bandwidth went

**Date:** 2026-08-23
**Hardware:** Alinx AXU3EG (XCZU3EG-SFVC784-1-E), 4 GB DDR4-2400 x64, PL at 200 MHz
**Build:** `hw/build_bringup.tcl all`, section 14.4 configuration -- `ROWS_IF=4`,
`NPORTS_W=4`, `AXI_DW=128`. Two bitstreams appear below: the first,
md5 `a1494fb8f73f4b9d2ba6c950abaf4a6f`, has the fan fault; the fixed rebuild is
the one to keep. WNS +0.172 ns, WHS +0.013 ns, WPWS +1.000 ns, 0 failing
endpoints; 12277 LUTs (17.4%), 5401 FF (3.8%), 80.5 BRAM (37.3%), 192 DSP
(53.3%).
**Boot:** `image.ub` patched by `hw/patch_dtb.sh`, TFTP from 192.0.2.169.

## The questions

0. The board fan ran at **full speed** on the new bitstream, while the PWM duty
   register read 480 of a 8000-cycle period -- exactly the 6% the fan was tuned to,
   and the thermal governor reported every zone healthy at 36-38 C.
1. Why did the kernel print
   `OF: fdt: Reserved memory: failed to reserve memory for node 'mv-weights@70000000': base 0x0000000070000000, size 256 MiB`
   when 0x70000000 is plainly inside System RAM, and the board booted anyway?
2. The section 11 acceptance run is bit-exact but delivers **8.50 GB/s**, 44.3% of the
   19.2 GB/s DDR4-2400 peak, against a design demand of 12.8 GB/s on the weight ports.
   The PL reports itself **starved 33.6% of all cycles**. What is the limiter?

## The answers

0. **The fan output was never connected to a pin.** `build_bringup.tcl` called
   `make_bd_intf_pins_external` on `fan_pwm/pwm_out`, which is a scalar pin, not an
   interface. The intf form applied to a scalar pin does nothing **and reports
   nothing**, so no external port was created, `bringup.xdc` matched no object, AA11
   was left unconfigured, and the fan's floating active-low input ran it flat out.
   Every register the governor wrote was reaching logic whose output went nowhere,
   which is why the duty register read a perfectly plausible 6% throughout.

1. **The top of the low DDR bank is the most contended part of it, not the emptiest.**
   CMA takes 256 MB at 0x65800000-0x757fffff, and the base device tree already
   reserves 0x758f6000-0x7bbf3fff and 0x7bf00000-0x7fefffff. The requested region
   overlapped all three. Moving it to **0x50000000** fixed it. CMA is placed
   *dynamically* and always takes the highest free window, so sitting below it is what
   makes the placement stable rather than lucky.

2. **The weight ports themselves are running dry -- it is not the scale port, and not
   the fabric.** The `STARVED` counter is `not all_v`, which is high only when one of
   the four weight FIFOs is empty. Had the scale stream on HPC0 been the limiter, the
   core would have stalled on `s_valid`, `w_ready` would have dropped, the weight FIFOs
   would have *filled*, and STARVED would have read low. It reads 33.6%. Further,
   696320 working cycles + 352578 starved = 1048898 total **exactly**, so the datapath
   never stalls for any other reason. This is a pure weight-bandwidth bound, and the
   leading (not yet proven) explanation is DRAM-side: five concurrent sequential read
   streams at 11 MB separation, thrashing banks and rows.

## The procedure

Each probe isolates one thing; the order matters because an early wrong answer here is
expensive (the only way back into a non-booting board is JTAG).

| # | Probe | What it isolates |
|---|---|---|
| 1 | `ping` + `ssh` to the board before touching anything | that the board is up on the OLD design, so any later failure is attributable to the change |
| 2 | passive serial capture opened BEFORE the reboot, `dtr=False, rts=False` | a boot failure that never reaches userspace. The flags matter: asserting either line on the CP2102N pulses board reset, so a naive "monitor" script reboots what it is watching |
| 3 | `devmem 0x80000064` -- the PL ID register | that the new bitstream is loaded and responding, independent of anything the driver does. Expect `0x4D563449` |
| 4 | `dmesg \| grep -i 'reserved memory'` | whether the reservation SUCCEEDED. This is the probe that was missing the first time; a failure here is one log line and the board boots normally |
| 5 | `/proc/iomem`, **including indented child ranges** | what actually occupies the region. The children are the whole answer and are easy to filter away by accident |
| 6 | `dmesg \| grep -i cma` | that the occupant is dynamically placed, so the fix is to move ours below it rather than to pick another high address |
| 7 | driver run, bit-exactness vs `ref/matvec_int4.c` on the board's own cores | the datapath, before any performance question is asked |
| 8 | 6 runs, comparing `beats` and `cycles` | determinism. `beats` identical, `cycles` spread 17 across 1.05 M |
| 9 | reading what `STARVED` is wired to in `rtl/matvec_int4.vhd` | WHICH port is behind. The counter's semantics discriminate scale-bound from weight-bound with no extra experiment |
| 10 | `arlen`/`MAXB`/`MAXOUT`/`DEPTH` in the RTL | whether short bursts or too little outstanding depth explain it. They do not |
| 11 | `devmem 0x80090008` vs `0x80090004` | the fan, which is part of this bitstream and silently fails safe-looking |
| 12 | changing the PWM period to restore 12.5 kHz, governor disabled first | whether the fault was the PL clock doubling (100 -> 200 MHz moves `period=8000` from 12.5 to 25 kHz). It was not: still full speed at the identical waveform |
| 13 | `grep create_bd_port hw/design_mv_generated.tcl` | whether the pin exists at all, which is the probe that found it. `write_bd_tcl` output is the text form of the design and shows a missing port immediately |
| 14 | `grep 'No ports matched' hw/build.log` | that the build had said so all along |

## The evidence

Reservation rejected, and what was in the way:

```
[    0.000000] OF: fdt: Reserved memory: failed to reserve memory for node
               'mv-weights@70000000': base 0x0000000070000000, size 256 MiB
[    0.000000] cma: Reserved 256 MiB at 0x0000000065800000

00000000-3ecfffff : System RAM
3ee48000-7fefffff : System RAM
  65800000-757fffff : reserved        <-- CMA
  758e5000-758f3fff : reserved
  758f6000-7bbf3fff : reserved        <-- base device tree
  7bf00000-7fefffff : reserved        <-- base device tree
800000000-87fffffff : System RAM      <-- unreachable, masters are ADDR_W=32
```

After moving to 0x50000000: no failure line, and

```
50000000-5fffffff : reserved
```

Acceptance run, `blk.0.ffn_gate.weight` from Qwen3.8-27B-Q4_K_M, M=17408 K=5120,
packed to 50.14 MB at 4.50 bits/weight:

```
matrix  M=17408 K=5120  rows_if=4 nports=4 block=32  w_exp=8 out_shift=4
PL id    0x4D563449  at 0x80000000

result   bit-exact vs ref/matvec_int4.c  (0 of 17408 rows differ)
y_exp    PL -1   ref -1   ok
sat      clear
cycles   1048898   (5.244 ms at 200 MHz)
beats    696320   starved 352578  (33.6% of cycles)
weights  8.50 GB/s sustained  = 44.3% of DDR4-2400 x64 peak (19.2 GB/s)
wall     13.113 ms (includes the AXI-Lite activation load and polling)
```

Six consecutive runs, all bit-exact, `beats` identical at 696320 every time:

```
cycles 1048898 / 1048895 / 1048910 / 1048893 / 1048894 / 1048895
```

17 cycles of spread in 1.05 M (0.0016%) -- DRAM refresh jitter, and notably the
*beat* count does not move at all.

Fan, confirming the 6% floor is live on silicon: `period=0x1F40` (8000),
`duty=0x1E0` (480), 480/8000 = **6.0%**, at 200 MHz / 8000 = 25 kHz.

## Measured and REJECTED -- do not retry

- **The PWM frequency as the cause of the fan fault.** The PL clock doubling to
  200 MHz does move `period=8000` from 12.5 kHz to 25 kHz, which is a real difference
  from the build the fan was tuned on and an entirely reasonable first suspect.
  Setting `period=16000, duty=960` reproduces the old waveform exactly (12.5 kHz, 6%)
  and the fan stayed at full speed. Not the cause. Disable the thermal governor
  (`echo disabled > /sys/class/thermal/thermal_zone*/mode`) before testing this or the
  governor overwrites the registers under you.
- **The polarity bit as the cause.** `CTRL=0x3` is enable plus polarity, and
  `pwm_out <= raw xor polarity` with `duty=480` gives a pin driven low 6% of the
  period, which for an active-low fan is the intended 6%. The register state was
  correct the whole time; it just was not reaching a pin.
- **0x70000000 as the reservation base.** Collides with CMA and two base-device-tree
  reservations. Any base in 0x65800000-0x7fefffff has the same problem.
- **The high memory bank at 0x800000000.** The masters are `ADDR_W=32`
  (`rtl/matvec_int4_ip.vhd`); the 2 GB high bank is not addressable by this design at
  all, however much free space `/proc/iomem` shows there.
- **The scale port on HPC0 as the bandwidth suspect.** Rejected from the STARVED
  counter's semantics, above -- a scale-bound design would show STARVED *low*, not
  33.6%. HPC0 goes through the CCI and is genuinely slower than an HP port, so this is
  a reasonable first suspect and it is wrong here. No experiment needed to kill it.
- **Short bursts or insufficient outstanding depth.** `MAXB=256` (4 KB, the AXI
  boundary limit), `arburst=INCR`, `MAXOUT=2`, `DEPTH=512` beats -- exactly two full
  bursts per port. Bursts are already maximal.
- **Installing `gcc-multilib` to unblock `petalinux-build`.** apt's plan REMOVES
  `gcc-aarch64-linux-gnu`, `g++-aarch64-linux-gnu` (which `hw/Makefile` needs for
  `mv_driver_aarch64`) and `vpi2-cross-aarch64-l4t`. `hw/patch_dtb.sh` exists because
  of this and patches the built DTB instead.

## Measurement traps hit

- **A failed `reserved-memory` node is not a boot failure.** One dmesg line, then the
  board boots normally and `/dev/mem` still cheerfully writes the region -- into memory
  Linux is using. Nothing downstream complains. `hw/README.md` now carries the explicit
  post-boot check.
- **Filtering `/proc/iomem` to top-level entries hides the answer.** `grep -v "^ "` was
  used to get a clean list of reservations and returned exactly one line, making the
  map look empty where it was in fact full. The occupants are indented children of
  `System RAM`. My own trap, and it cost a probe.
- **The serial console is NOT `/dev/ttyUSB3`** as the AXU3EG repo's CLAUDE.md records;
  it enumerated at `/dev/ttyUSB0` this session. That file already says to identify by
  the `10c4:ea60` CP2102N rather than by port number, which is the advice that worked.
  Note this collides with the workstation CLAUDE.md's claim that ttyUSB0 is the Kiprim
  PSU -- the PSU is a CH340 (`1a86:7523`). Identify by VID:PID, never by number.
- **`scp ... | grep -v Warning` reports the grep's exit status, not scp's.** A run that
  looked like `rc=1` had in fact transferred both files correctly.
- **A Vivado build that "succeeded" had already reported this fault, twice.**
  `No ports matched 'pwm_out_0'` is a WARNING, and the follow-on
  `'set_property' expects at least one object` is a CRITICAL WARNING that appears only
  in implementation, after the line `Synthesis finished with 0 errors, 0 critical
  warnings`. Reading the synthesis summary and moving on is what let this ship. Both
  of this design's silent failure modes are pins rather than logic, and neither timing
  nor utilisation can see them, so `build_bringup.tcl` now asserts that `pwm_out_0`
  exists in the block design AND that it is placed on AA11 in the implemented design.
- **A correct-looking register readback proves nothing about the pin.** `duty=0x1E0`
  over `period=0x1F40` is 6.0%, which is exactly right and was true while the fan ran
  flat out. The register is on the near side of the break.
- **`report_timing_summary -delay_type max` prints Hold as `NA`,** which reads as clean.
  `hw/build_bringup.tcl` uses `min_max`. Hold on this build is +0.013 ns.

## Open, not yet answered

- **Why the weight ports deliver 66% of their interface peak** (2.13 GB/s each against
  3.2 GB/s). The leading hypothesis is DRAM-side: four weight streams 11,145,216 bytes
  apart plus a fifth 44 MB away, all sequential, thrashing bank groups and rows. 60-75%
  is the normal efficiency band for four concurrent DDR4 read streams, and 66% sits in
  it -- but that is an argument from plausibility, not a measurement.
  **What would settle it:** an AXI performance monitor on the HP ports to get
  per-port latency and AR-to-first-R distribution, or a run with `NPORTS_W` reduced so
  the number of concurrent streams changes while everything else stays fixed. If
  per-port throughput RISES as streams are removed, it is DRAM contention; if it stays
  flat, the limit is per-port.
- **Whether the 12.8 GB/s figure in `hw/README.md` was ever achievable on this part.**
  Section 4's projections rest on a bandwidth fraction this run puts at ~50% aggregate
  (8.50 GB/s weights + ~1.06 GB/s scales against 19.2 GB/s). Those projections should
  be revisited against the measured number rather than the peak.
- **Whether raising `MAXOUT` above 2 helps.** It cannot without also raising `DEPTH`,
  since the FIFO is currently sized to exactly two bursts. Untested.

## Resolution

The rebuild connects `pwm_out` with `make_bd_pins_external` and the implemented
design reports `fan: pwm_out_0 placed on AA11 LVCMOS33`. Zero
`No ports matched` warnings. Confirmed by ear on the board: quiet at the same 6%.

Note the fixed build runs the fan at **25 kHz**, not the 12.5 kHz of the 100 MHz
design, because `period=8000` is interpreted against a doubled PL clock. The duty
percentages in `cooling-levels` therefore keep their meaning and the fan is
audibly unchanged, so nothing was adjusted for it. If a future fan does care
about the frequency, `period=16000` restores 12.5 kHz without touching any
percentage.

Acceptance re-run on the fixed bitstream is identical to the faulty one --
bit-exact, 696320 beats, 8.50 GB/s -- so the pin fix does not perturb the
datapath, as expected.

## CORRECTION 2026-08-23 (later the same day): the DRAM contention hypothesis is WRONG

The "Open, not yet answered" section above named DRAM-side contention as the
leading explanation for the 8.50 GB/s figure -- four weight streams 11,145,216
bytes apart plus a fifth 44 MB away, thrashing bank groups and rows. It was
labelled plausibility rather than measurement, correctly, and the measurement
now says it is **wrong**. That claim is WITHDRAWN.

**The probe.** `mv_driver --bw-stride N` overrides `W_BASE1..3` to sit N bytes
from `W_BASE0` instead of at their natural ~11 MB separation, so the four
streams walk through DRAM together in one small sliding window. The bytes each
port reads are then wrong and the result is meaningless, so the correctness
comparison is skipped -- but `BEATS` and `CYCLES` are counted by the PL
regardless and the beat count is identical either way, so delivered bandwidth
remains a valid measurement with address separation as the only variable.
Reads only, all inside the reserved region.

| stream separation | cycles | starved | GB/s |
|---|---|---|---|
| 4 KB | 1,048,882 | 33.6% | 8.50 |
| 16 KB | 1,048,880 | 33.6% | 8.50 |
| 64 KB | 1,048,895 | 33.6% | 8.50 |
| 256 KB | 1,048,895 | 33.6% | 8.50 |
| 1 MB | 1,048,890 | 33.6% | 8.50 |
| 4 MB | 1,048,925 | 33.6% | 8.50 |
| ~11.1 MB (natural) | 1,048,895 | 33.6% | 8.50 |

A 2,700x range of separation moves `cycles` by 45 in 1,048,895 -- 0.004%. If row
and bank locality were the limiter this would be the single most sensitive knob
available, and it does nothing.

**Row geometry is also not it.** `blk.0.ffn_down.weight` (M=5120, K=17408) packs
to exactly the same 696,320 beats as `ffn_gate` (M=17408, K=5120) but with 1,280
tiles of 544 blocks instead of 4,352 tiles of 160 -- rows 4x longer, 3.4x fewer
tiles. Result: 8.52 GB/s against 8.50, starve 33.4% against 33.6%. The 3,072
cycles saved is about 1 cycle per tile of end-of-row overhead, i.e. 0.3%, and
bit-exact on both.

**What that leaves.** Each port sustains 0.664 beats/cycle and every non-transfer
cycle is a starve cycle, so the ports are waiting on returned data rather than
the datapath being unable to consume it. With `MAXOUT=2` and `FIFO_DEPTH=512` --
exactly two 256-beat bursts -- the port can only issue a new AR once a burst's
worth of space frees, so if only one burst is effectively in flight the
throughput is `256/(256+L)`. That fits the measurement at L ~ 129 cycles
(645 ns), a plausible ZynqMP HP-to-DDR read latency under load.

`MAXOUT` was never plumbed past `axi_rd_port`, so it sat at its default of 2 and
was untestable from the top. It is now a generic through `weight_streamer`,
`matvec_int4` and `matvec_int4_ip`, and `hw/build_bringup.tcl` takes
`FIFO_DEPTH` and `MAXOUT` as build arguments so a sweep leaves no diff to
revert. `sim/tb_axi_rd_port.vhd` existed but was never wired into
`sim/run_matvec.sh`; it is now stage 4b and sweeps MAXOUT 1/2/4/8 against
matching depths, because a port that miscounts outstanding bursts corrupts data
rather than merely running slow.

**This matters more for the FK33 than for the AXU3EG.** HBM read latency is
higher than DDR4's, so a design that hides latency this poorly will lose more
there, and the FK33 configuration was already argued to be near-balanced at
nominal bandwidth.

**Still open:** whether raising the outstanding depth actually recovers the
throughput, and if not, whether the ceiling is the HP port, the FPD
interconnect, or the coherent scale traffic on HPC0 degrading the others.
