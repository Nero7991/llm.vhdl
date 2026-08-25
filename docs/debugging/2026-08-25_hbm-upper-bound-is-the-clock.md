# How do you measure HBM's upper bound, and why the obvious method cannot

**Date:** 2026-08-25
**Hardware:** SQRL FK33, xcvu33p-fsvh2104-2L-e, VCCINT 0.717 V
**Design:** `build_fk33_hbmbw.tcl`, 15 ports, 300.000 MHz, build WNS +0.455 ns
**Result file:** `hw/fk33/results/hbmbw_oversubscription.txt`

## The question

The 144.0 GB/s measured with one port per pseudo-channel is a LOWER bound: at
300 MHz a 256-bit port demands `32 B x 300 MHz = 9.6 GB/s` and a pseudo-channel
supplies `460.8/32 = 14.4 GB/s`, so the port cannot saturate the channel and
100% of the port ceiling is arithmetic rather than a finding.

Proposed method: **oversubscribe**. Point several ports at ONE pseudo-channel.
Two ports demand 19.2 GB/s against 14.4, the channel becomes the limit, the
rate stops scaling with port count, and the plateau is the channel's real
delivered bandwidth. That would reach saturation with more ports instead of a
faster clock, and would need no datapath pipelining.

## The answer

**The method does not work, and the reason generalises: there is no way to
measure HBM's DRAM-level bandwidth from the fabric.**

The rate did not rise at all. It was flat at **exactly 9.60 GB/s** from one
port through fifteen.

`9.60 = 32 B x 300 MHz`. That is not a coincidence and it is not the DRAM.
**Each pseudo-channel is reached through its OWN 256-bit AXI interface running
at the same ACLK**, so the access path to a channel carries 32 B/cycle no
matter how many masters target it. Oversubscription piles demand upstream of a
bottleneck that is itself clock-limited, so it cannot reveal what lies beyond.

The premise's 450 MHz is therefore deeper than "the clock at which one port
matches one channel": at 450 MHz, `32 B/cycle = 14.4 GB/s` = exactly the DRAM's
per-channel rate. **The IP is balanced at 450 MHz by construction.** Below it
the AXI path is the limit; above it there would be nothing to gain.

Consequence, and it is the useful part:

```
device usable bandwidth = 32 channels x 32 B x f_ACLK
                        = 307.2 GB/s at 300 MHz
                        = 460.8 GB/s at 450 MHz
```

The upper bound is **not a memory question at all**. It is entirely a clock
question, hence a timing and voltage-derate question. The bandwidth thread and
the frequency thread are the same thread; this is now proven rather than
suspected.

## The procedure

Two sweeps in one run, on one bitstream, differing only by a register write.

1. **Port per channel** (`rgn_stride = 1`) -- the aggregate case. Establishes
   whether anything upstream is shared.
2. **All ports on channel 1** (`rgn_stride = 0`) -- the oversubscription case.
   Establishes the per-channel access limit.

Running both from one bitstream matters: the only difference between them is
one control register, so nothing about placement, routing or clocking can
differ between the two halves.

**Guard that made the negative result trustworthy.** A sweep whose region
write silently failed would rerun case 1 and report the same guaranteed 100%,
i.e. it would fake a positive. Three defences: the testbench captures ARADDR
from ports 0 and NPORT-1 and asserts their region fields are equal AND equal to
the programmed channel; the sweep reads the region register back before
starting; and the response counter would have caught the DECERRs that a
half-applied address map produces. Given that a silently dropped control write
is exactly how this instrument failed the first time, none of these are
decorative.

## Evidence

```
=== A: port per channel ===             === B: all ports -> channel 1 ===
 ports    beats     cycles    GB/s       ports    beats     cycles   GB/s  vs14.4
     1  3200000   3200166      9.6           1  3200000   3200065   9.60   66.7%
     2  6400000   3200155     19.2           2  6400000   6400243   9.60   66.7%
     4 12800000   3200162     38.4           3  9600000   9600062   9.60   66.7%
     8 25600000   3200066     76.8           4 12800000  12800049   9.60   66.7%
    15 48000000   3200161    144.0           8 25600000  25600050   9.60   66.7%
                                            15 48000000  48000094   9.60   66.7%
```

Zero non-OKAY read responses in either sweep.

**The cycle column is the proof the channel was really shared.** In A it stays
at 3.2 M regardless of port count -- the ports run in parallel on separate
channels. In B it scales exactly linearly, 3.2 M -> 48 M -- the ports are
queueing behind one another for one channel. That is what sharing looks like,
and it rules out "the redirection silently did nothing".

## What this DID establish

- **Per-channel access path: exactly `32 B x f_ACLK`.** Measured, flat under
  15x oversubscription.
- **Switch aggregate capacity: at least 144 GB/s.** From sweep A, 15 channels
  concurrently at full port rate with no interference. So the 9.60 limit is
  per-channel, not a global switch limit -- the switch carried 144 GB/s in the
  other sweep.
- **DRAM efficiency under heavy interleaving is at least 66.7%, with NO
  measurable degradation.** Fifteen independent sequential streams interleaved
  onto one channel is close to a worst-case row-access pattern, and it cost
  nothing: full 9.6 GB/s, same as a single stream. The true figure is >= 66.7%
  and unmeasurable from here because the AXI path saturates first. **This is
  directly relevant to C §2.5 and B, whose 53% duty premise is conservative.**

## Measured and REJECTED -- do not retry

- **Oversubscribing a pseudo-channel to find its bandwidth.** This document.
  Flat at 32 B x f_ACLK. The access path is clock-limited, so no port count
  reaches the DRAM's rate.
- **Adding ports to raise total bandwidth beyond 32 B x f per channel.**
  Same reason.
- **Any fabric-side method of measuring HBM's DRAM-level ceiling.** The fabric
  cannot request more than 32 B/cycle/channel. The DRAM's 14.4 GB/s is not
  observable from here at any clock below 450 MHz, and at 450 MHz it is
  exactly matched rather than exceeded, so it is never observable as a
  distinct limit at all.

## Measurement traps hit

- **I predicted a plateau ABOVE the single-port rate and got one exactly AT
  it.** The tell that separates "channel saturated" from "method invalid" was
  not the bandwidth column, which looks identical in both stories, but the
  CYCLE column scaling linearly. Design the experiment so a null result is
  distinguishable from a broken one.
- **9.60 GB/s could have been read as "the pseudo-channel delivers 9.6".**
  It is `32 B x 300 MHz` to three significant figures, which should always
  prompt the question of whether the number is the memory or the plumbing. A
  measured value that reproduces your own clock arithmetic exactly is almost
  never the thing you were trying to measure.

## Open, not yet answered

- **The actual voltage derate**, unchanged, and now the ONLY thing standing
  between this project and a bandwidth number. 350 MHz misses by 0.467 ns with
  both CDC bugs fixed; 450 MHz needs real pipelining of the HBM-to-fabric
  paths.
- **Write traffic.** `hbm_tg` has no write channel at all, so C's 2R+1W and
  B's four-master patterns remain untested. The read-side efficiency result
  above does not transfer to them.
- **Whether DRAM efficiency stays at 100% of the AXI path under a 450 MHz
  demand.** At 300 MHz the memory had 50% headroom over the request rate, so
  the clean result may not survive at the balanced point.
