# The HBM port count is a WIDTH budget, not a bandwidth budget, and it kills `ROWS_IF = 58`

**Date:** 2026-08-27. Branch `fpga`, at `adc6fe1`. Part `xcvu33p-fsvh2104-2L-e`,
FK33, VCCINT 0.717 V. No Vivado was run.

## 1. The question, verbatim

> the audit measured that the current design wires 2 of 32 HBM AXI ports, which
> is about 16 GB/s and 3.6 tok/s, against the roughly 288 GB/s and 30 ports the
> budgets assume. [...] what does the weight streamer have to look like to
> sustain 288 GB/s across ~30 ports, and what does that cost in fabric, in
> address-map complexity, and in timing at 237.8 MHz (or lower)?

Symptom numbers as found: **2 ports wired** (`build_fk33_pcieep.tcl:149-150`),
**16.0 GB/s** DERIVED, **3.6 tok/s** DERIVED
(`docs/2026-08-27_weight-path-audit.md:603`), against **288.0 GB/s at 30 ports**
MEASURED (`hw/fk33/results/hbmbw_30port_300mhz.txt`) and a project-wide
`ROWS_IF = 58` settled on by A spec section 15.4c.

## 2. The answer, up front

**The streamer must not try to sustain 288 GB/s, because at the measured core
clock subsystem A cannot ask for it, and the number of ports it needs is not set
by how many bytes per second it wants.** One HBM SAXI port delivers 256 bits per
ACLK cycle into one lane of A's `ROWS_IF x 144`-bit core word. The port count is
therefore

```
NPORT = ROWS_IF x 144 / 256 = ROWS_IF x 9 / 16          (BLK = 32, AXI_DW = 256)
```

an **exact integer identity with no clock in it and no provisioning factor**.
At `ROWS_IF = 58` that is **33 ports against 30 available: not buildable.** At
`ROWS_IF = 48` it is 27, which fits with 3 to spare.

**Lowering the core clock does not lower the port count.** It lowers each port's
duty cycle. At 237.8 MHz against a 300 MHz ACLK every port sits idle 20.7% of the
time, and that idle capacity is unusable because a lane cannot be fed by half a
port.

**Both existing port-count tables in the repo are wrong, in opposite directions,
and for the same underlying reason: they price ports in GB/s.**

| source | method | at `ROWS_IF = 58` | at `ROWS_IF = 48` |
|---|---|---|---|
| A spec section 15.1 | `demand x 1.3 / 14.4 GB/s` | 30 | 23 |
| D skeleton section 3.3 | `demand x 1.3 / 9.6 GB/s` | 43 | 33 |
| D skeleton, at 1.0x | `demand / 9.6 GB/s` at 300 MHz | 33 | 26 |
| bandwidth at the MEASURED core clock | `ROWS_IF x 18 B x f_core / 9.6 GB/s` | 26 | 22 |
| **width, this document** | **`ROWS_IF x 9 / 16`** | **33** | **27** |

The 1.0x row coincides with the width answer at `ROWS_IF = 58` only because it
was evaluated at `f_core = f_ACLK = 300 MHz`, where the two methods are the same
calculation. Everywhere else they diverge, and **the width answer is the binding
one because it is a lower bound the bandwidth answer can drop below.**

## 3. The procedure, and what each step isolates

Each step is inspection or arithmetic; the control at every step is an
independently published number in the repo that the step has to reproduce.

1. **Read the achieved per-port rate and the burst length it was achieved at.**
   `hw/fk33/results/hbmbw_30port_300mhz.txt`. Isolates: whether the memory or
   the fabric is the limit. Control: the file's own self-check that the beat
   count is exactly `nports x nburst x (arlen+1)`.
2. **Read the SAXI data width and the core word width from the RTL, not from
   prose.** `rtl/hbm_tg.vhd:92` for 256 bits; `rtl/matvec_core.vhd:78` and
   `:81-82` for `ROWS_IF*BLK*4` and `ROWS_IF*16`. Isolates: whether the lane
   count is a design choice or an identity.
3. **Divide.** Isolates the width budget from the bandwidth budget. Control:
   at `f_core = f_ACLK` the two must agree exactly, and they do (33 = 33).
4. **Check the divisibility.** `ROWS_IF x 144 / 256` integral iff
   `ROWS_IF mod 16 = 0`. Isolates which `ROWS_IF` values need scale padding.
5. **Ask whether a port can feed more than one lane.** A port supplies
   `256 x f_ACLK / f_core` bits per core cycle; a lane consumes 256. So
   `K = floor(f_ACLK / f_core)` lanes per port. Isolates the clock ratio as the
   only lever that changes the port count.
6. **Compare against both published tables** and account for the difference
   term by term. Isolates arithmetic error from method error. Result: neither
   table is arithmetically wrong; both use a method that cannot see the
   constraint.

## 4. The evidence

### 4.1 Per-port rate and burst length, MEASURED

```
hw/fk33/results/hbmbw_30port_300mhz.txt
:114   ceiling at NPORT ports = 288.0 GB/s
:119   # set ARLEN 15          ;          -> 16 beats x 32 B = 512 B bursts
:349   HEADLINE: 288.0 GB/s, 100.0% of the arithmetic ceiling, 96,000,000 beats,
:352   Sweep A scales perfectly linearly to 30 ports and the CYCLE COUNT STAYS AT
:358   Sweep B (oversubscription, all ports -> one channel) is flat at 9.60 GB/s
:364   WHAT THIS IS: usable read bandwidth at 30 of 32 SAXI ports.  SAXI_00 and
:369     288.0 GB/s  =  30 ports x 32 B x 300 MHz          MEASURED
:370     336.0 GB/s  =  30 ports x 32 B x 350 MHz          if 350 ever closes
:371     460.8 GB/s  =  32 ports x 32 B x 450 MHz          the device paper figure
```

Two things this pins that the GB/s figure hides: **512-byte bursts already reach
100%**, so no burst in this design needs to approach AXI4's 4 KB boundary rule;
and the oversubscription sweep shows a single pseudo-channel serving all 30
ports delivers 9.60 GB/s **in total**, i.e. the port ceiling, not a switch
collapse.

### 4.2 The width identity, from the RTL

```
rtl/matvec_core.vhd:78    w_data : ROWS_IF*BLK*4-1 downto 0     -- 6,144 b at R=48
rtl/matvec_core.vhd:81-82 s_data : ROWS_IF*16-1   downto 0      --   768 b at R=48
rtl/hbm_tg.vhd:92         AXI_DW : positive := 256              -- HBM SAXI width
```

`(6144 + 768) / 256 = 27` exactly. At `ROWS_IF = 58`,
`(7424 + 928) / 256 = 32.625`, so 29 weight lanes plus `ceil(928/256) = 4` scale
lanes = **33**, with 96 bits of scale padding per word.

### 4.3 The clock ratio, MEASURED both sides

```
f_core  237.812 MHz   sim/ooc_sweep/results.csv:7   ROWS_IF=58, 0.717 V, synth
f_core  236.128 MHz   sim/ooc_sweep/results.csv:8   ROWS_IF=48, 0.717 V, synth
f_ACLK  300 MHz       hbmbw_30port_300mhz.txt       30 ports, WNS +0.101 ns, on card
ratio   300 / 237.8 = 1.2616      -> K = floor(1.2616) = 1 lane per port
```

At `K = 1` each port is busy `1 / 1.2616 = 79.3%` of the time. **20.7% of the
288 GB/s the card can supply is structurally unreachable by A**, and no FIFO
depth, prefetch or scheduling recovers it.

### 4.4 Port count against the available 30

DERIVED, `NPORT = ROWS_IF x 9/16` where integral, otherwise
`ROWS_IF/2 + ceil(ROWS_IF/16)`:

| `ROWS_IF` | weight lanes | scale lanes | ports | of 30 | DSP (33 x R) | A cycles, 9B |
|---|---|---|---|---|---|---|
| 32 | 16 | 2 | 18 | fits, 12 spare | 1,056 | 7,752,704 |
| **48** | **24** | **3** | **27** | **fits, 3 spare** | **1,584** | **5,187,328** |
| 52 | 26 | 4 | 30 | fits, 0 spare | 1,716 | 4,787,200 |
| 58 | 29 | 4 | **33** | **-3, IMPOSSIBLE** | 1,914 | 4,293,888 |
| 64 | 32 | 4 | 36 | -6, impossible | 2,112 | 3,877,888 |

Cycle counts are DERIVED by summing `ceil(M/ROWS_IF) x ceil(K/32)` over the
reconstructed 273-tensor 9B list, whose `sum(M x K)` reproduces
`docs/2026-08-27_9b-single-card-resource-envelope.md:197`'s 7,936,409,600
exactly.

### 4.5 What `ROWS_IF = 48` costs against the unbuildable 58

DERIVED, at the MEASURED per-`ROWS_IF` clocks:

```
R=58:  4,293,888 cycles / 237.812e6 = 18.06 ms      (but needs 33 ports)
R=48:  5,187,328 cycles / 236.128e6 = 21.97 ms
delta                                = +3.91 ms per token, +21.6% on A alone
```

Applied to the 26.52 ms 9B token of
`docs/2026-08-27_budgets-at-the-measured-clock.md` section 0, with every other
term held: **30.43 ms, 32.9 tok/s against 37.7.** A 12.7% throughput cost, and
it buys 330 DSP back (11.5% of the die), which section 15.4c would spend on C.

## 5. Measured and REJECTED -- do not retry

- **Provisioning the port count at 1.3x** (A spec section 15.1, inherited by D
  skeleton 3.3). Rejected: the port count must be an exact divisor of the core
  word width, so 1.3x is a category error. It inflates 29 to 38 and makes
  `ROWS_IF = 58` look 5 ports short when it is 3. Measured efficiency is 100.0%
  at every port count from 1 to 30 and 100% under 30-way oversubscription, so
  there is nothing to provision against.
- **Two lanes per port by widening the FIFO read port to 512 bits.** Rejected by
  arithmetic: the port would have to supply `512 b x 237.8e6 = 15.2 GB/s`
  against the MEASURED 9.6. It is not a BRAM problem, it is a bandwidth
  impossibility. (Rev 3 of A spec section 7.7 rejected 512-bit FIFO read ports on
  BRAM cost grounds; that argument is now redundant, the bandwidth one is
  stronger.)
- **Recovering the 20.7% idle port capacity by lowering the core clock further.**
  Rejected: `K = floor(f_ACLK/f_core) = 2` needs `f_core <= 150 MHz` at a
  300 MHz ACLK, and `ROWS_IF = 64` at 150 MHz is `3,877,888 / 150e6 = 25.9 ms`,
  **worse** than `ROWS_IF = 48` at 236 MHz. Halving the port count by halving
  the clock is self-defeating.
- **Borrowing `SAXI_00` and `SAXI_16` from the host path** to reach 32 ports.
  Rejected on two counts: it is still one short of the 33 that `ROWS_IF = 58`
  needs, and those two ports sit behind the `pcie2hbm` smartconnect
  (`build_fk33_pcieep.tcl:194-197`), so their latency and jitter differ from the
  other 31. Under lockstep lane consumption the slowest lane sets the rate, so
  two atypical lanes would set it for all 33.
- **`AXI_DW = 128` on the HBM ports** to get 32 narrow ports. Rejected: total
  width is unchanged (`32 x 128 = 16 x 256`), so the lane count doubles and the
  port count doubles with it. No gain, twice the AR logic.
- **8-bit scales** to shrink the scale lanes. Rejected as arithmetic, before it
  reaches the numeric-contract question: `ROWS_IF x 136 / 256` at 58 is 30.8, so
  it saves at most 2 of the 3 ports needed and still does not fit.

## 6. Measurement traps hit

- **"288 GB/s of supply against 248 GB/s of demand, therefore A is fed" is true
  and irrelevant.** `docs/2026-08-27_budgets-at-the-measured-clock.md` section
  1.2 and `docs/2026-08-27_9b-single-card-resource-envelope.md` F3 both conclude
  A has 13.8% of the device spare at `ROWS_IF = 58` and 237.8 MHz. Both are
  correct about bandwidth. Neither is evidence that the configuration is
  buildable, because the spare bandwidth is spread across ports A cannot use.
  **Aggregate headroom is not port headroom**, and this is the same shape of
  trap as the already-recorded "an HBM-bandwidth-bound term does not scale with
  the core clock": a term that looks like it moves with the clock and does not.
- **The 1.0x column of D skeleton 3.3 gives the right number at `ROWS_IF = 58`
  for the wrong reason.** It reads 33, which is exactly the width answer, purely
  because it was evaluated at `f_core = f_ACLK = 300 MHz`. Re-evaluating the
  same formula at the measured 237.8 MHz gives 26 and would have licensed
  `ROWS_IF = 58`. A method that is right only at one clock is not a method.
- **`rtl/hbm_tg.vhd`'s "port-local" wording invites a wrong reading of the
  address map.** `:20-25` says addressing is port-local, and the audit's section
  3 concluded from it that `hbmbw` has a different address map from `pcieep`. It
  does not: `build_fk33_hbmbw.tcl:483-738` assigns all sixteen of each stack's
  segments to every `SAXI_nn` at the same flat offsets `pcieep` uses. What is
  port-local is the **generator's choice of addresses**, not the address space.
  See `docs/2026-08-27_hbm-residency-map.md` section 6.
- **`sim/ooc_sweep/results.csv` now has the two rows a document written earlier
  today said were missing.** `docs/2026-08-27_budgets-at-the-measured-clock.md`
  section 1.1 records that the `ROWS_IF = 32` and `40` rows of the four-point
  voltage table are "not present in any file I could find". They are lines 10
  and 11 of that CSV (236.295 and 240.558 MHz at 0.717 V). The caveat is stale
  and the flatness conclusion is now fully reproducible. Noted rather than
  edited into that document, per its own corrections discipline.
- **The VU33P is monolithic, and assuming otherwise nearly bought a
  floorplanning problem that does not exist.** A draft of
  `docs/2026-08-27_hbm-weight-streamer-design.md` reasoned "1,584 DSP against
  roughly 1,440 per SLR, therefore the 6,912-bit merge must cross an SLR" and
  called it the design's biggest timing risk. MEASURED by inspection of the
  Vivado 2023.2 part data: `xcvu33p_fsvh2104.bsd` contains **zero** `SLR`
  references, `xcvu35p_fsvh2104.bsd` contains 35 and `xcvu37p_fsvh2892.bsd`
  contains 55
  (`/tools/Xilinx/2023.2/Vivado/2023.2/data/parts/xilinx/virtexuplusHBM/public/bsdl/`).
  Multi-die SSI parts declare per-SLR TAP structure in BSDL; monolithic parts do
  not. The "1,440 per SLR" figure was invented by dividing the VU33P's own DSP
  count by an assumed 2. **Do not reason about SLR count from resource counts;
  read the BSDL, which needs no Vivado run.**

- **`DSP = 8 + 46.50 x ROWS_IF` (A spec section 15) is the PRE-reclaim curve.**
  The post-reclaim curve in `sim/ooc_sweep/results.csv` is exactly
  `DSP = 33 x ROWS_IF` at every measured point (8, 16, 32, 40, 48, 58). Using
  the old curve overstates `ROWS_IF = 48` by 656 DSP, 23% of the die.

## 7. Open, not yet answered

- **Whether the HBM SAXI ports close at 2x the core clock.** That is the only
  lever that changes `NPORT`, and it would take `ROWS_IF = 64` to 18 ports. 350
  MHz misses by 0.395 to 0.467 ns
  (`docs/debugging/2026-08-25_voltage-derate-on-hardware.md:244`), so 2x looks
  out of reach at a 237.8 MHz core, and reachable at a 200 MHz post-route core
  only if 400 MHz closes. ESTIMATE, not measured.
- **HBM read latency and its jitter under 27 concurrent readers.** Sizes the
  lane FIFOs. `hbm_tg` measured throughput and `arstall`, never latency.
- **Whether `ROWS_IF = 48` survives place and route at 27 lanes.** The 236.1 MHz
  figure is out-of-context synthesis of `matvec_core` alone
  (`sim/ooc_sweep/results.csv:8`), with no streamer, no 6,912-bit merge and no
  HBM IP in the same device.
- **Whether the project accepts the 12.7% token-rate cost of moving 58 to 48.**
  That is a whole-die allocation decision of the kind A spec section 15.4c makes,
  and this document does not have the standing to make it.

## 8. Corrections

None yet. Append here with a date; mark superseded claims withdrawn in place.
