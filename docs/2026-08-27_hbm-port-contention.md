# Are A, B and C ever simultaneously active, and does the HBM port budget close?

**Date:** 2026-08-27. Branch `fpga`, at `d2b4a6a`.
**Part:** `xcvu33p-fsvh2104-2L-e`, SQRL FK33, 8 GiB HBM, 32 HBM SAXI ports, 30 usable.
**Model:** Qwen3.5-9B, N=1 (`rtl/model_cfg_pkg.vhd:64-70`): 32 blocks, 24 GDN, 8 attention, `attn_interval` 4.
**Answers:** item **1** of `docs/2026-08-27_die-allocation-at-rows-if-48.md` section 7, and the
"real conflict" left open in `docs/2026-08-27_hbm-residency-map.md` section 7.

**No Vivado was run.** Simulation and RTL reading only, as instructed. Every quantity below is
labelled **MEASURED** (a tool ran, the output is named), **DERIVED** (arithmetic shown) or
**ESTIMATE** (a judgement with its assumption stated).

---

## 0. The answer

**A, B and C are never simultaneously active, and it is a `CANNOT`, not a `does not` -- but only
at the COMPUTE level, which is not the level the port mux needs. And the port mux is not needed
anyway: the deficit that motivated it does not exist. `ROWS_IF = 48` closes at exactly 30 of 30
ports with A's 27 untouched, because B needs THREE ports at the measured core clock, not four,
and because B and C -- being mutually exclusive -- must be taken as `max`, not as a sum.**

Four results, in the order they matter:

1. **Exclusivity is structural.** `rtl/seq_desc_fetch.vhd` holds a single scalar `cur_unit` and
   drives `u_start(u) <= '1' when state = S_ISSUE and cur_unit = u`, so at most one bit of the
   start bus can ever be high; and the state path `S_ISSUE -> S_WAIT -> S_COMPLETE` cannot return
   to `S_ISSUE` without the running unit's `done`. `rtl/seq_region_lock.vhd` independently holds
   ONE latched job (`jb_*`, `jb_live`) and carries the assertion *"a second step was committed
   while the first was still outstanding. Only one job runs at a time in D."* Concurrency is not
   merely unscheduled; **it is inexpressible in the RTL that exists**. MEASURED by simulation over
   the real 491-descriptor 9B token table: **0 cycles of A/B/C compute overlap**, with a negative
   control that fires.

2. **The port-level claim is NOT established, and it is the one the mux depends on.** A unit's
   `done` does not imply its AXI transactions retired. MEASURED: the real walker leaves exactly
   **4 core cycles** between one unit's ack and the next unit's issue, in every skew configuration.
   That is 16.9 ns, roughly 5 ACLK cycles. An HBM read tail of 32 ACLK cycles already produces
   **896 cycles per token** of "A's ports live while B or C computes"; a tail of 200 produces
   **6,272**. The real `rtl/seq_desc_fetch.vhd` has **no grant state and no drain gate** (only the
   never-simulated `rtl/seq_top_skel.vhd` has `S_GRANT`/`ports_busy`), and `rtl/axi_rd_port.vhd`
   exposes **no outstanding-transaction count** for such a gate to read.

3. **The "34 of 30" deficit is arithmetic that contradicts its own premise.**
   `die-allocation-at-rows-if-48.md` section 1.6 adds A 27 + B 4 + C 3 = 34, then resolves the
   overflow by invoking the fact that A, B and C are never simultaneously active. If that fact
   holds, B and C never hold ports at the same time, so the demand is `27 + max(4, 3) = 31`, a
   deficit of **one** port. If it does not hold, the proposed mux is invalid anyway. There is no
   reading on which 34 is the right number.

4. **The remaining deficit of one disappears at the measured clock.** B's port count is
   `ceil(4 x LANES x f_core / 11.77 GB/s)`, MEASURED-based and **proportional to the core clock**.
   The `4` in every published table was computed at 300 MHz. At the measured **236.128 MHz** the
   demand is **30.22 GB/s** and the count is **3**. So `27 + 3 = 30`, exactly the 30 available,
   with **no port muxed off A**. `docs/superpowers/specs/2026-08-21-gated-deltanet-design.md:1849`
   already prints "30.4 GB/s at the measured 237.8 MHz" and the table four lines below it still
   says 4 ports. That is the same failure mode this project was warned about: **the killing number
   is computed and the conclusion is not drawn.**

**Consequence for the die allocation.** `ROWS_IF = 48` is buildable on ports. The
`ROWS_IF = 32` fallback and its 26% throughput cliff (32.80 -> 24.21 tok/s) are **not required**.
The mux that is required is the small one D section 8.1 already specifies -- a 2:1 grant between B
and C over the 3 spare ports -- not a new 4-way mux over A's 27.

**What is still open and must not be skipped:** the drain interlock of result 2. It is cheap
(one counter per shared port, one FSM state, MEASURED cost below 0.02% of the token) and its
absence is a silent-data-corruption class of bug, not a performance one.

---

## 1. The schedule, from the RTL

### 1.1 Where the schedule actually lives

It is not in gateware. `rtl/seq_desc_fetch.vhd` walks a table the host generates, and
`sim/seq_tbl_pkg.vhd` builds the real one for the build target out of `rtl/model_cfg_pkg.vhd` and
nothing else. So "what is the schedule" is answerable exactly, by running it.

At `MODEL = QWEN35_9B`, `NCARDS = 1`: `NSTEP_GDN = 16`, `NSTEP_ATTN = 13`,
`TBL_STEPS = 24 x 16 + 8 x 13 + 3 = 491` (`sim/seq_tbl_pkg.vhd:93-97`).

### 1.2 One GDN block, 16 steps (24 of these per token)

DERIVED from `seq_tbl_pkg.vhd:277-321`. The unit column is the opcode-to-unit decode of
`rtl/seq_desc_fetch.vhd:413`.

| # | opcode | unit | src -> dst |
|---|---|---|---|
| 1 | `VEC_NORM` | D-vec | X -> XN |
| 2 | `A_JOB` | **A** | XN -> QKV[0], `n_rows` 2048 (q) |
| 3 | `A_JOB` | **A** | XN -> QKV[2048], 2048 (k) |
| 4 | `A_JOB` | **A** | XN -> QKV[4096], 4096 (v) |
| 5 | `A_JOB` | **A** | XN -> Z, 4096 (gate) |
| 6 | `A_JOB` | **A** | XN -> BETA, 32 |
| 7 | `A_JOB` | **A** | XN -> ALPHA, 32 |
| 8 | `B_JOB` | **B** | QKV (+Z, BETA, ALPHA) -> Y |
| 9 | `A_JOB` | **A** | Y -> ER, 4096 (ssm_out) |
| 10 | `VEC_RES` | D-vec | X, ER -> X |
| 11 | `VEC_NORM` | D-vec | X -> XN |
| 12 | `A_JOB` | **A** | XN -> G, 12288 |
| 13 | `A_JOB` | **A** | XN -> U, 12288 |
| 14 | `VEC_SWG` | D-vec | G, U -> H |
| 15 | `A_JOB` | **A** | H -> ER, 4096 |
| 16 | `VEC_RES` | D-vec | X, ER -> X |

### 1.3 One attention block, 13 steps (8 of these per token)

| # | opcode | unit | src -> dst |
|---|---|---|---|
| 1 | `VEC_NORM` | D-vec | X -> XN |
| 2 | `A_JOB` | **A** | XN -> QG, 8192 (Q and gate interleaved) |
| 3 | `A_JOB` | **A** | XN -> KIN, 1024 |
| 4 | `A_JOB` | **A** | XN -> VIN, 1024 |
| 5 | `C_JOB` | **C** | QG (+KIN, VIN) -> Y |
| 6 | `A_JOB` | **A** | Y -> ER, 4096 (wo) |
| 7 | `VEC_RES` | D-vec | X, ER -> X |
| 8-13 | | | the same six FFN steps as GDN 11-16 |

Tail: `VEC_NORM`, `A_JOB` (lm_head, raw mode into the sampler), `END_TOKEN`.

### 1.4 The census, MEASURED

`bash sim/run_abc_ports.sh`, configuration "no AXI tail, fast descriptor memory". Counted at
`job_issue` by decoded opcode, i.e. by what the walker actually issued, not by reading the table:

```
A_JOB     = 297
B_JOB     =  24
C_JOB     =   8
E_COLL    =   0        (N=1: no collective, by construction)
VEC_NORM  =  65
VEC_RES   =  64
VEC_SWG   =  32
            ----
jobs issued 490        (491 descriptors; END_TOKEN starts nobody)
stub starts A/B/C/E/V = 297/24/8/0/161
```

### 1.5 Is it serial by design, or does anything overlap?

**Strictly serial across A, B, C, E and D-vec.** Nothing overlaps except two things that cost no
HBM port:

- **Descriptor prefetch**, D section 4.5. The two-bank shadow in `seq_desc_fetch` exists so the
  fetch of step n+1 runs under step n. Descriptors are URAM-resident and D holds **0** HBM ports
  (D section 8.1), so this overlap is invisible to the port budget.
- **E's output stream into D-vec's residual pass 1**, D section 4.5, flagged UNRESOLVED at
  `rtl/seq_top_skel.vhd:186-196` as hazard B7. **Absent at N=1**: `E_COLL = 0` MEASURED above.

Everything else is a data dependency at batch 1. The token is a chain: step 8's `B_JOB` consumes
QKV, Z, BETA and ALPHA, which steps 2-7 produce; step 9's `A_JOB` consumes B's Y. There is no
independent work to overlap it with.

---

## 2. The evidence that they never overlap

### 2.1 Structural, in RTL that exists (this is the strong form)

Three independent mechanisms, all in real RTL, all in the regression suite:

**(a) The walker cannot start two units.** `rtl/seq_desc_fetch.vhd`:

```vhdl
signal cur_unit : integer range 0 to NUNIT-1 := 0;   -- :315
...
u_start(u) <= '1' when state = S_ISSUE and cur_unit = u else '0';   -- :962
```

`cur_unit` is a scalar. At most one bit of `u_start` can be asserted, in any state, ever. The FSM
reaches `S_ISSUE` only from `S_CHECK`, and leaves it only to `S_WAIT`, which exits on
`done_seen(cur_unit)`. A second job cannot be issued while the first is outstanding.

**(b) The lock manager cannot hold two jobs.** `rtl/seq_region_lock.vhd:241-250` declares ONE
latched job (`jb_prod`, `jb_dst`, `jb_cons`, `jb_rel`, `jb_live`). A second `iss_commit` would
overwrite the first job's metadata, and the unit says so:

```vhdl
assert not (iss_commit = '1' and jb_live = '1')
  report "seq_region_lock: a second step was committed while the first "
       & "was still outstanding.  Only one job runs at a time in D."
```

**(c) The issue verdict rejects a second consumer of a live region**
(`rtl/seq_region_lock.vhd:329-334`): a region in `HELD` cannot be consumed again, and cannot be
produced into unless the same step is the in-place case.

**Two qualifications, and they matter.** Mechanism (c) is per region, so it forbids two consumers
of the *same* region, not two jobs. Mechanisms (a) and (b) are the load-bearing ones, and both are
properties of **subsystem D**, not of A, B or C. Nothing inside `matvec_int4`, `gdn_block` or the C
array prevents concurrent operation; widening `cur_unit` from a scalar to a set is a small edit.
So the correct statement is: **cannot, given D as written**, and it is one integer wide.

### 2.2 By simulation, with a negative control

**Instrument:** `sim/probe_abc_ports.vhd`, driver `sim/run_abc_ports.sh`. It elaborates the real
`rtl/seq_desc_fetch.vhd` against the real 491-descriptor table from `sim/seq_tbl_pkg.vhd`, models
five stub units with independent latencies, and counts, per cycle and per pair, how many of A, B
and C are active.

It is deliberately **not** named `sim/tb_*.vhd`: `sim/regress.sh` globs that pattern and the
repo's published verdict today is 69 PASS / 0 FAIL, which other work is gating on. Renaming the
file is the whole of the promotion. `bash sim/regress.sh --quick` after this work: **48 PASS,
0 FAIL**, unchanged.

**MEASURED, compute windows** (`bash sim/run_abc_ports.sh`):

| configuration | A&B | A&C | B&C | verdict |
|---|---|---|---|---|
| fast descriptor memory, 1 token | 0 | 0 | 0 | PASS |
| slow descriptor memory (`URAM_LAT=23`), 1 token | 0 | 0 | 0 | PASS |
| fast memory, 2 tokens | 0 | 0 | 0 | PASS |

**MEASURED, negative control.** A checker that reports zero on a design that cannot express
overlap has proved nothing about itself, so `INJECT_LATE` makes one unit keep computing past its
own ack -- a premature `done`, which is a defect class this project has already been bitten by
(`docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md`):

| injection | A&B | A&C | verdict |
|---|---|---|---|
| unit A computes 50 cycles past its ack | 1,104 | 368 | control FIRED |
| unit B computes 50 cycles past its ack | 1,104 | 0 | control FIRED |

`1,104 = 24 GDN blocks x (50 - 4)` and `368 = 8 attention blocks x 46`, DERIVED, which also
confirms the 4-cycle turnaround measured below.

**MEASURED, inter-job gap.** Identical in every configuration, including with slow descriptor
memory:

```
min gap, any -> any     = 4 core cycles
min gap, A ack -> B/C   = 4 core cycles
min gap, B/C ack -> A   = 4 core cycles
```

This is the `S_COMPLETE -> S_WAITPF -> S_CHECK -> S_ISSUE` path. **It is the entire drain budget
the current RTL provides**, and it is not a function of load: the prefetch is always ready by then.

### 2.3 Port windows: the same instrument, the answer reverses

A unit's `done` is a statement about its computation, not about its bus. `rtl/axi_rd_port.vhd`
issues up to `MAXOUT` bursts in flight and keeps accepting R beats for all of them; its own
`S_DRAIN` comment is the proof:

> bursts already accepted by the slave keep returning beats AFTER the flush, and they land looking
> exactly like the new job's first beats.

`TAIL_x` extends a unit's port window past its ack by that many cycles. MEASURED:

| tail (cycles) | A&B ports | A&C ports | A ports live while B or C computes |
|---|---|---|---|
| 0 | 0 | 0 | 0 |
| 4 | 0 | 0 | 0 |
| **32** | 672 | 224 | **896** |
| **200** | 4,704 | 1,568 | **6,272** |

DERIVED cross-check: `24 x (200 - 4) = 4,704` and `8 x (200 - 4) = 1,568`. Exposure per switch is
exactly `TAIL - 4`, so **any tail longer than 4 core cycles is exposure**.

**Is the tail longer than 4 cycles? Certainly.** 4 core cycles at 236.128 MHz is 16.9 ns, about 5
cycles of the 300 MHz ACLK. The HBM read latency has never been measured in this project -- it is
item 1 of the residency map's own must-measure list, and `rtl/hbm_tg.vhd:76-84` measured
throughput and `arstall`, not latency. ESTIMATE, from the Xilinx HBM controller's published
behaviour: 40 to 60 ACLK cycles idle, more under 27 concurrent readers, plus up to
`MAXOUT x MAXB = 2 x 16 = 32` beats of burst residue at the 512-byte burst the bandwidth run used
(`hw/fk33/results/hbmbw_30port_300mhz.txt:119`, MEASURED). **Tail ESTIMATE 70 to 100 ACLK cycles,
which is 14 to 20 times the available gap.**

**Nothing in the shipping RTL closes this.** `rtl/seq_top_skel.vhd` has the mechanism -- an
`S_GRANT` state that waits on `ports_busy` built from `port_rd_busy`/`port_wr_busy`, with the
correct comment that "a unit's `done` does NOT imply its AXI transactions have retired". But that
file "has never been simulated, never been synthesised, and implements no behaviour" by its own
header. The **real** walker `rtl/seq_desc_fetch.vhd` has no grant ports, no `S_GRANT` and no
port-busy input, and `rtl/axi_rd_port.vhd` exposes no outstanding count for one to read. The
observability the interlock needs does not exist at either end.

### 2.4 So: cannot, or merely does not?

| level | verdict | basis |
|---|---|---|
| A/B/C **compute** windows overlap | **CANNOT**, given D as written | `cur_unit` is one scalar; `jb_live` is one job; MEASURED 0 cycles with a firing negative control |
| A/B/C compute overlap in some **future** D | **could**, cheaply | the invariant lives in one integer in one file, not in the units |
| A/B/C **port** windows overlap | **NOT ESTABLISHED, and probably false** | 4-cycle turnaround MEASURED against a 70-100 cycle tail ESTIMATE; no drain gate, no outstanding counter |

A port mux built on the first row alone is exactly the latent defect the task warned about. Built
on the third row it is a data-corruption bug: an AXI read whose R beats return after the mux has
been re-pointed does not stall, it lands in the wrong master's FIFO.

---

## 3. Back-pressure: where the loss actually is, and where it is not

Checked specifically, because a producer that cannot be stalled loses data rather than delaying it.

**The known no-ready producers are NOT exposed by any port mux.** `y_we`, `x_we` and `cb_we`
(`rtl/matvec_int4.vhd:60-86`, `rtl/matvec_core.vhd:72-91`) and C's `y_we`
(`rtl/attn_c_ports_skel.vhd:189`) are **activation-region** strobes in the core clock domain. A
mux on the HBM SAXI side never touches them. Their safety argument is the region lock's
single-writer rule, unchanged by anything here.

**A's weight feed IS stallable, and stalls without lane skew.** `rtl/weight_streamer.vhd:157`:

```vhdl
pop_w <= all_v and w_ready;
```

The merge pops only when **every** lane has a beat, so stalling a subset of A's 27 lanes stalls
the whole merge in lockstep. There is no drift mode. Back-pressure propagates up through
`stream_fifo` to `axi_rd_port`'s AR throttle (`f_level + pr + want <= DEPTH`), which simply stops
issuing. Muxing a lane away from A **while A is idle** costs nothing and risks nothing.

**The real loss mode is a misrouted R beat, not a dropped one.** AXI has no mechanism to recall an
issued AR. If the mux re-points a port while a burst is outstanding, the returning beats are
delivered to whichever master the mux now selects. They look like valid data. This is the same
class as the per-port misalignment `axi_rd_port`'s `S_DRAIN`/`S_FLUSH` pair was written to prevent,
one level up.

**Both B and C already specify the cure, and neither has it in RTL.**
`gated-deltanet-design.md:1447` requires B to "drain outstanding reads (count RLASTs to zero),
then flush its FIFOs, on `start`", adopted wholesale from C section 2.7. The same discipline has
to exist at the *mux*, not only inside each master, and at the *switch* instant, not only at
`start`. B's write side is already covered -- B's `done` gates on the last BRESP
(`gated-deltanet-design.md:1443`) -- so it is specifically the **read** tail that is open.

---

## 4. What forbidding overlap costs: nothing that is reachable

The task asks for the cost of serialising A, B and C to make a port mux safe. DERIVED, at 9B N=1,
ctx 2048, 236.128 MHz, against the 30.490 ms / 32.80 tok/s baseline of
`die-allocation-at-rows-if-48.md`:

**The cost is zero, because every overlap candidate is either data-dependent or already hidden.**

| candidate overlap | why it is worth nothing |
|---|---|
| A(qkv/z/beta/alpha) with B | B consumes all four. Pure RAW dependency at batch 1. |
| A(wq/wk/wv) with C | C consumes all three. Same. |
| B or C with the following A(ssm_out / wo) | that A consumes their Y. Same. |
| C's KV prefetch under the preceding A jobs | C's KV read is 1.25 ms against C's own 4.79 ms of compute at ctx 2048, and 19.8 ms against 66.6 ms at ctx 32,768 (`hbm-residency-map.md` section 7). **Already fully hidden inside C.** Prefetching it earlier saves nothing. |
| descriptor prefetch | already overlapped, and costs 0 HBM ports (URAM). |
| E into D-vec | `E_COLL = 0` at N=1, MEASURED. |

So serialisation is not a concession made to enable a mux. It is what a batch-1 autoregressive
token is. The only price the mux itself charges is the drain, priced in section 5.4.

---

## 5. Options, ranked

### 5.0 The corrected port arithmetic

**A, MEASURED-derived and clock-independent.** `NPORT_A = ROWS_IF x 9/16 = 27` at `ROWS_IF = 48`.
An exact integer identity with no clock in it
(`docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`).

**B, DERIVED, and clock-PROPORTIONAL.** From `gated-deltanet-design.md:1864`, the
measurement-based rule is

```
ports_B = ceil( 4 x LANES x f_core / 11.77 GB/s )
```

with `11.77 GB/s` MEASURED on the card for one port carrying a 1:1 read/write mix into one
pseudo-channel (`hw/fk33/results/hbmbw_readwrite.txt`,
`docs/debugging/2026-08-25_hbm-read-write-turnaround.md`). At `LANES = RECUR_LANES = 32`:

| `f_core` | demand | `ports_B` | margin |
|---|---|---|---|
| 300.0 MHz (the clock every published table used) | 38.40 GB/s | **4** | +23% |
| 237.812 MHz | 30.44 GB/s | **3** | +16.0% |
| **236.128 MHz, the measured `ROWS_IF = 48` clock** | **30.22 GB/s** | **3** | **+16.8%** |

The crossover is `3 x 11.77 / (4 x 32) = 275.9 MHz`: **below it B needs 3 ports, above it 4.**

**C, DERIVED.** 3 masters (2 read + 1 write) is a *concurrency* requirement, not a bandwidth one.
C's KV traffic is 0.036 GB per token at ctx 2048 over 1,217,484 cycles = 5.156 ms = **6.98 GB/s**,
which is 0.6 of one port; at ctx 32,768 it is 0.570 GB over 66.6 ms = 8.56 GB/s. C needs 3 ports
because its datapath issues three concurrent streams, and it needs no more at any context.

**D, E: 0 ports.** D's descriptors and constants are URAM-resident (D section 6.4); E is PCIe and
absent at N=1. **But D's real port requirement is item 12 of the die-allocation unknown list and
has never been priced** -- see section 7.

**The budget, DERIVED:**

```
A                                     27
max(B, C) = max(3, 3)                  3     <- B and C are never both active
                                      ---
                                      30
available                             30
                                      ---
spare                                  0
```

### 5.1 Option 1 (recommended): B at 3 masters, B|C 2:1 grant mux on the 3 spare ports

Nothing is muxed off A. The 3 leftover engine ports carry B's state sweep during GDN blocks and
C's KV during attention blocks, switched by the grant D section 8.1 already specifies and
`rtl/seq_top_skel.vhd:232` already declares (`grant_sel`, 0 = B, 1 = C).

- **Cost in ports:** 0 taken from A.
- **Cost in LUT:** three 256-bit bidirectional 2:1 AXI muxes. ESTIMATE ~1,500 LUT, against ~152,800
  free (die allocation section 1.2).
- **Cost in time:** the drain. **16 switches per token** (8 attention blocks, in and out of C), not
  64, because A never gives up a port. Priced in 5.4: **0.014% of the token**.
- **Cost in B's throughput: zero, twice over.** B at 3 ports supplies 35.31 GB/s against 30.22
  demanded, so it does not slow at all. And it would not matter if it did, because B is
  **emit-bound, not sweep-bound**: DERIVED, `gdn_sweep_cycles(9B, 1, 32) =
  (128 x 128 x 32) / 32 x 24 = 393,216` cycles against B's 552,096-cycle emit-bound total, so the
  sweep may slow by **40.4%** before it binds anything. DERIVED consequence worth recording:
  **B would also be free on 2 ports** (23.54 GB/s, a 1.284x slowdown, sweep 504,808 cycles, still
  under 552,096). It is only at **1 port** that B becomes feed-bound, at 1,009,388 cycles, which is
  **+6.35% of the 7,199,583-cycle token**. So the binding claimant on the three spare ports is
  **C's three concurrent streams, not B's bandwidth.**
- **Prerequisite, and it is not optional:** the drain interlock of section 6.

### 5.2 Option 2: keep B at 4 masters, mux exactly ONE of A's 27 lanes

If B's 4-master count is defended on grounds other than bandwidth, or if the core clock ever
closes above 275.9 MHz, the demand is 31 and **one** port must be shared. Mux one A lane, not four.

- **Cost:** one 256-bit 2:1 AXI mux, ESTIMATE ~500 LUT; 64 switches per token (every B and C job
  takes it and gives it back), priced at **0.056%** of the token in 5.4.
- **Risk it adds over option 1:** the drain interlock now sits on a lane A depends on, so a drain
  bug corrupts weights rather than state. Prefer option 1.

### 5.3 Option 3: re-split A's lanes 15/12 so all three spare ports sit on one stack

Independent of options 1 and 2, and it answers an open item the residency map explicitly parks
("the 14/13 stack split of A's lanes is arbitrary ... should be chosen to put B's and C's spare
ports on the stacks their data lives in").

The HBM switch is per stack with no cross-stack path. With A split 14/13 the spare ports are
`SAXI_15` (stack 0) and `SAXI_30`, `SAXI_31` (stack 1), so B's state and C's KV must each be
**split across both 4 GiB halves** and every access must select the right half. That is the
residency map's own "silent-wrong-answer" class.

Split A **15/12** instead -- lanes 0..14 on `SAXI_01..15`, lanes 15..26 on `SAXI_17..28` -- and the
three spare ports become `SAXI_29`, `SAXI_30`, `SAXI_31`, **all on stack 1**. B's state and C's KV
then live entirely in one half and the stack rule disappears for both.

- **Cost, DERIVED:** stack 0 holds 15 arenas x 160 MiB = 2,400 MiB, and its remaining 1,696 MiB is
  reachable only by A's own ports and the host, so KV cannot live there. Stack 1 holds 12 arenas
  = 1,920 MiB, leaving 2,176 MiB, minus 546 MiB of embedding and 32 MiB of GDN state = **1,598 MiB
  of KV = 96,256 tokens** against the 14/13 split's 198,415.
- **Is that acceptable?** Yes, by the residency map's own argument: context is compute-capped
  between 4,096 and 8,192 tokens, so 96,256 is still 12x more capacity than is reachable.
- **Host loading is unaffected**: `hw/fk33/build_fk33_pcieep.tcl:194-197` fans the host path
  through the `pcie2hbm` smartconnect into **both** `SAXI_00` (stack 0) and `SAXI_16` (stack 1),
  so `xdma` reaches all 8 GiB. (Worth stating explicitly: a reading in which the host could only
  reach one stack would have made this option unusable, and it was checked.)

### 5.4 Option 4: the die-allocation document's 4-lane mux over A

Superseded by options 1 and 2. It provisions four muxed ports for a demand that is at most one,
because it sums B and C. Costs four AXI muxes and four timing paths on the 300 MHz ACLK domain
instead of one or none, and puts three more of A's lanes behind a switch for no benefit.

### 5.5 Option 5: fall back to `ROWS_IF = 32`

**Not required.** 18 ports, 12 spare, and 24.21 tok/s against 32.80 -- a 26% cliff bought to solve
a deficit that does not exist. Keep it on the shelf only for the case where D turns out to need
several ports of its own (section 7).

### 5.6 The drain, priced

DERIVED, using the tail ESTIMATE of 70-100 ACLK cycles from section 2.3 (call it 85, i.e. 283 ns
at 300 MHz):

| option | switches per token | drain per token | of the 30.490 ms token |
|---|---|---|---|
| 1 (B|C mux only) | 16 | 4.5 us | **0.015%** |
| 2 (one A lane muxed) | 64 | 18.1 us | **0.059%** |
| 4 (four A lanes muxed) | 64 | 18.1 us | 0.059% |

The drain is free. **The interlock that performs it does not exist, and that is the finding.**

---

## 6. What has to be built before any of this is safe

In dependency order. None of it needs Vivado to specify.

1. **An outstanding-transaction count out of `rtl/axi_rd_port.vhd`.** The signal exists internally
   (`outst`, `promised`); it is not a port. One output, `busy <= '1' when outst /= 0 or arv = '1'`.
   Zero DSP, a handful of LUT. Without it nothing can observe a drained port.
2. **A write-side equivalent** for B's and C's masters, gated on BRESP rather than RLAST.
3. **A grant state in the REAL walker.** `rtl/seq_desc_fetch.vhd` needs `S_GRANT`, `grant_sel`,
   `grant_taken` and `port_*_busy` -- the ports `rtl/seq_top_skel.vhd:230-236` already declares and
   the real file does not have. The rule is the skeleton's and it is correct as written: the grant
   may change only when **every port being re-granted** reports zero outstanding, counted at the
   port and never inferred from `done`.
4. **A test that drives the invariant.** `sim/tb_seq_region_lock.vhd` passes 8 configurations and
   **never once commits a second step while the first is live**, so the assertion quoted in section
   2.1(b) has never fired or been shown to fire. It is a `severity warning`, so even if a future
   change did overlap, a suite that does not treat warnings as failures would stay green. Add the
   case, and consider raising it to `severity error` under `STRICT`.
5. **Promote `sim/probe_abc_ports.vhd` to `sim/tb_seq_abc_exclusive.vhd`** once the 69-PASS count
   is no longer being gated on, so the exclusivity property is regression-protected rather than
   re-measured by hand.

---

## 7. What this document does NOT establish

Stated explicitly, because an honest unknown is worth more than a tidy conclusion.

- **The HBM read tail is an ESTIMATE.** 70-100 ACLK cycles is a judgement from the controller's
  published behaviour and the `MAXOUT x MAXB` residue, not a measurement. The project has never
  measured HBM read latency; it is item 1 of the residency map's own list. Everything in section
  2.3 scales with it. It does **not** change the verdict -- any tail above 4 core cycles is
  exposure, and 4 cycles is implausibly short -- but it changes the size of the drain.
- **D's own HBM port requirement is UNKNOWN.** Item 12 of the die-allocation list. The budget in
  5.0 closes at exactly 30 with zero spare, so **any port D turns out to need breaks it**, and the
  fallback is option 2 (mux one A lane) and then option 5. The embedding table -- 545.6 MiB, one
  2,304-byte row per token, with no owner named anywhere in the repo -- is the specific candidate.
- **`seq_desc_fetch` has never been wired to a real A, B or C.** The exclusivity result is about
  D's issue interface. The units are separately verified; the integration does not exist, and the
  two subsystem-B defects of 2026-08-27 were both integration defects.
- **B's `RECUR_LANES = 32` is assumed.** If it ever moves, `ports_B` moves with it linearly, and
  so does the crossover clock.
- **C's 3 masters is taken from the spec, not re-derived.** Its bandwidth needs 1 port; whether its
  datapath genuinely needs three concurrent streams is C's question, and if the answer is 2 then
  option 1 gains a spare port.
- **`11.77 GB/s` is measured for one port on one pseudo-channel.** Whether three muxed ports
  sharing an arena tail region behave the same has not been measured. The adjacent measurement --
  30 ports doing R+W at 353.0 GB/s, linear -- says it should.

---

## 8. Measurement traps hit, including my own

- **The probe's own countdown ordering silently zeroed the result.** The tail and injection
  countdowns were written at the END of the stub process, after the issue branch. In VHDL the last
  signal assignment in a process wins, so the `<= 0` at issue never took effect and a tail left
  over from job n kept counting under job n+1 of the same unit, dropping that unit's activity flag
  mid-job. Because 297 of the 490 jobs are A and A follows A, the effect landed almost entirely on
  A: its port window measured **55,380 cycles against a compute window of 90,288**, i.e. shorter
  than the computation it was supposed to contain, and the port-overlap counters read a confident
  **zero**. The result looked exactly like the answer being sought. **What caught it was the
  negative control**, which failed to fire on unit A while firing correctly on unit B; a probe with
  no control would have shipped the zero. The countdowns now run first, and the totals
  `tot_c`/`tot_p` are printed so `tot_p >= tot_c` can be checked by eye on every run.
- **`ghdl -e` produces no binary on the mcode backend and exits 0.** `sim/run_abc_ports.sh` runs
  `ghdl -r <entity>` directly, and the 491-descriptor table needs `--max-stack-alloc=0`.
- **A phase census taken from the table source would have been weaker than one taken from
  `job_issue`.** Counting what the walker issued, rather than what the generator emitted, is what
  makes `A_JOB = 297` a statement about the DUT.

---

## 9. Where the RTL disagrees with the documents

Recorded as findings, per the method requirement.

1. **`die-allocation-at-rows-if-48.md` section 1.6's "34 of 30" contradicts its own resolution.**
   It sums B's 4 and C's 3, then resolves the overflow by asserting that A, B and C are never
   simultaneously active. Under that assertion the demand is `max`, not the sum: 31, not 34. The
   deficit was over-stated by a factor of four, and the four-lane mux was sized against it.
2. **`gated-deltanet-design.md` prints B's demand at the measured clock and then keeps the port
   count derived at 300 MHz.** Line 1849 reads "30.4 GB/s at the measured 237.8 MHz"; the table at
   1872-1877 still says 4 ports at 38.4 GB/s. `30.4 / 11.77 = 2.58`, so the count is 3. This is the
   same shape as the `ROWS_IF = 58` case: the number that settles it is on the page and the
   conclusion is not drawn.
3. **D O13 is a REQUIREMENT ON D that is cited as EVIDENCE ABOUT D.**
   `2026-08-24-transformer-sequencer-design.md:113` states O13 as "Run exactly one of A/B/C at a
   time", with its basis given as B section 2.7 and C section 2.7 -- and those sections justify
   themselves with "subsystem D runs exactly one unit at a time". The citation is circular. It
   happens to be discharged by the RTL (section 2.1), but no document in the chain establishes it,
   and the die-allocation document's phrase "stated in two specs" is counting one claim twice.
4. **The drain rule exists only in the skeleton.** `rtl/seq_top_skel.vhd` has `S_GRANT`,
   `grant_taken` and `port_rd_busy`/`port_wr_busy` with the correct normative comment; the real
   `rtl/seq_desc_fetch.vhd` has none of them. Any reader who takes the skeleton as the design will
   believe the interlock exists.
5. **`rtl/axi_rd_port.vhd` has no drained-port output**, so the skeleton's `port_rd_busy` has no
   producer anywhere in the repo.
6. **The one-job-at-a-time assertion in `rtl/seq_region_lock.vhd` is never driven** by
   `sim/tb_seq_region_lock.vhd`, and is `severity warning`, so it cannot fail a run.

---

## 10. Corrections

None yet. Append here with a date; mark superseded claims withdrawn in place rather than deleting
them.
