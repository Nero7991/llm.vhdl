# HBM read/write turnaround measured: 81.8% of channel, and it does NOT justify a ping-pong

**Date:** 2026-08-25
**Card:** SQRL FK33, VU33P, wiper 68 / 0.717 V (NOT raised to 0.85 V)
**Design:** `hw/fk33/build_fk33_hbmbw.tcl`, 30 HBM AXI3 ports, 300.000 MHz,
routed WNS **+0.017 ns** (the read-only build was +0.499)
**RTL:** `rtl/hbm_tg.vhd` with the write channel added the same day
**Raw:** `hw/fk33/results/hbmbw_readwrite.txt`

## 1. The question

Every bandwidth number this card had produced was read-only, because the
traffic generator had no write channel: 144.0 GB/s on 15 ports, 288.0 on 30,
both exactly `ports x 32 B x f`. The specs were quoting those as the memory
system's capability, but only subsystem A issues read-only traffic. C section
2.5 assumes two reads and one write CONCURRENTLY; B assumes four masters, two
of them writing. C section 3.13 lists "HBM port efficiency for C's 2R+1W
concurrent pattern is unmeasured; the 53% duty premise is DERIVED" as an open
item, and B section 2.5 says "the efficiency premise must be re-measured for
this pattern".

**What does mixed read/write traffic cost, and is the cost turnaround or
arbitration?**

## 2. The answer

**81.8% of a pseudo-channel's rate, and it is 100% turnaround and 0%
arbitration.** One master mixing reads and writes into one pseudo-channel gets
11.77 GB/s of the 14.4 GB/s that channel supplies. Twenty readers and ten
writers on *independent* channels get 288.0 GB/s -- identical to read-only to
within one cycle in 1.6 million.

**And the obvious fix for B is wrong.** B's state sweep is an in-place
read-modify-write, so the plan (written earlier the same day, B section 3.4)
was to ping-pong between two state regions so reads and writes never share a
channel. The measurement says do not: dedicating a port to one direction leaves
its other direction idle, and that costs more than the turnaround it avoids.

| B at `LANES = 32`, needs 19.2 GB/s each way | delivered | margin |
|---|---|---|
| **in-place, 4 ports doing R+W** | **47.1 GB/s** (23.5 each way) | **+23%** |
| ping-pong, 2 read + 2 write ports | 38.4 GB/s (19.2 each way) | 0% |

Both need four ports. In-place has margin and needs no second copy of the
state; the ping-pong would have cost 37.75 MB per card to make things worse.

## 3. Procedure

Three runs, deliberately designed so that subtracting them isolates one cause.
A single "mixed traffic" number would have averaged turnaround and arbitration
together and been unattributable.

| run | configuration | what it isolates |
|---|---|---|
| W1 | write-only, one channel per port | that the write path moves every beat |
| W2 | `rw_both`, one channel per port | **turnaround alone** -- at one port there is no second master to arbitrate against |
| W3 | every third port writes, independent channels | **arbitration alone** -- no bus turns around |

**W2 is the only configuration reachable from fabric at 300 MHz in which the
DRAM has to set the answer.** A port demands 32 B/cycle = 9.6 GB/s while a
channel supplies 14.4, so any read-only or write-only arrangement is
arithmetically guaranteed to hit 100% of the port ceiling and measures the
clock, not the memory -- the same trap the oversubscription sweep fell into
when it returned a flat 9.60 GB/s. AXI's read and write paths are independent,
so `rw_both` demands 9.6 + 9.6 = 19.2 GB/s from that 14.4 GB/s channel. That is
the whole reason the write channel was worth building.

W1 is run anyway and is explicitly labelled not-a-finding in the results file,
so nobody later cites 288.0 GB/s of write bandwidth as a measured capability.

## 4. Evidence

```
==== W1  WRITE-ONLY, one channel per port  (GUARANTEED, NOT A FINDING) =
experiment                   ports      rbeats      wbeats       cycles        GB/s
write-only 1 ports              1           0     1600000      1600017         9.6
write-only 4 ports              4           0     6400000      1600017        38.4
write-only 15 ports            15           0    24000000      1600017       144.0
write-only 30 ports            30           0    48000000      1600019       288.0

==== W2  READ+WRITE CONCURRENT, one channel per port  (THE HEADLINE) ===
R+W both 1 ports                1     1600000     1600000      2609145        11.8
R+W both 2 ports                2     3200000     3200000      2610205        23.5
R+W both 4 ports                4     6400000     6400000      2609248        47.1
R+W both 15 ports              15    24000000    24000000      2610874       176.5
R+W both 30 ports              30    48000000    48000000      2610491       353.0

==== W3  MIXED 2R+1W ACROSS PORTS  (arbitration, not turnaround) =======
2R+1W 30 ports                 30    32000000    16000000      1600176       288.0

(read-only 30 ports, same session:  96000000 beats   1600175 cycles   288.0)
```

Every beat count is exact against `nburst x (arlen+1)` per port, B responses
matched the burst count on every write port, and no run logged a non-OKAY
response or a thermal trip. Stack codes stayed 25-27 throughout, die 22-25 C.

**W1 vs read-only: 1,600,019 cycles against 1,600,175 for the same beat
count.** A write beat costs what a read beat costs, to 0.01%, with writes
marginally ahead.

**W3 vs read-only: 1,600,176 against 1,600,175.** One cycle in 1.6 million.
Arbitration between read and write masters on independent channels is free --
not cheap, free.

**W2 scales exactly linearly**: 11.77, 11.77, 11.78, 11.77, 11.77 GB/s per port
from 1 to 30 ports. Nothing upstream saturates, so the per-port number is a
property of one channel and multiplying it by port count is licensed.

**353.0 GB/s at 30 ports is the highest figure ever measured on this card**,
22.6% above the 288.0 read-only number, because bidirectional traffic uses both
AXI directions per port.

## 5. Measured and REJECTED -- do not retry

- **The B section 3.4 ping-pong.** Withdrawn on the strength of section 2's
  table. It was written the same day with the explicit caveat "must not be
  cited before that lands", which is the only reason it never propagated. The
  reasoning error was treating turnaround as a pure loss without pricing what
  dedicating a port to one direction gives up.
- **Quoting 353.0 GB/s as the device supply.** It applies only to genuinely
  bidirectional traffic. Subsystem A's weight stream is read-only and still
  gets 9.6 GB/s per port; for A the supply is 288.0 GB/s and unchanged.
- **Expecting arbitration to cost something.** It was the more plausible of the
  two candidate costs going in -- the HBM global switch has to interleave 30
  masters -- and it measures at zero. Had W2 been run alone, its 18.2% loss
  would have been split between the two causes by guesswork.

## 6. Measurement traps hit

- **A write-only sweep at 300 MHz cannot produce a finding, and the original
  plan for the night was to run one.** It is guaranteed by the same arithmetic
  that made the oversubscription sweep return a flat 9.60 GB/s: below ~450 MHz
  a single port cannot pressure a pseudo-channel. Caught in review before the
  RTL was written, which is why `rw_both` exists at all.
- **The testbench's memory model was enforcing the DUT's correctness.** It
  gated WREADY on having an accepted AW, which made the "W data ahead of its
  address" assertion unfireable -- a mutant that asserted WVALID with no AW
  outstanding was held off by the model and passed. Making WREADY purely
  rate-based exposed a real bug in the DUT immediately (below). **A model that
  enforces the DUT's correctness makes every assertion downstream of it
  decoration.**
- **A deferred counter in the write-credit path was a hang, not a slowdown.**
  `wcred` was decremented via an event register like every other counter in the
  unit, so after the final burst the idle branch saw a stale nonzero credit for
  one cycle and re-asserted WVALID with no AW behind it. Real HBM asserts
  WREADY freely out of its write buffer, so on hardware that sends an extra
  burst the memory never framed: a permanently desynchronised write channel.
  Found only because the model stopped covering for it.
- **Timing margin collapsed and the run could have been garbage.** Adding the
  write path took routed WNS from +0.499 ns to +0.017 ns at the same clock. The
  card runs 0.717 V where Vivado signs off at 0.85 V, so there was a real
  chance of silent corruption; the exact beat-count self-checks are what make
  the result trustworthy rather than the WNS number. Any further work on this
  bitstream should re-close timing first.

## 7. Open, not yet answered

- **Read/write ratios other than 1:1.** W2 issues equal beats each way. C's
  2R+1W *on one channel* is a different mix, and 81.8% is not that number.
- **Turnaround at shorter bursts.** Everything here is ARLEN=15 (16 beats, the
  AXI3 maximum). A shorter burst turns the bus around more often and must be
  worse; nothing bounds how much.
- **Whether C's 53% duty premise is now closed.** This measures the memory, not
  C's schedule. C section 3.13's item is narrowed, not discharged.
- **350 MHz.** Unreachable on this bitstream at +0.017 ns of slack.
- **The stack temperature code to Celsius mapping**, still unverified: codes
  25-27 against a die at 22-25 C is consistent with a 1:1 degree mapping but
  does not establish one, and the soft ceiling therefore still ships disabled.
