# Subsystem D: sequencer skeleton and interface specification

Skeleton spec, 2026-08-27. **Analysis and a documented skeleton, not a verified
implementation.** No RTL in this document has been simulated; the only tool run
against it is `ghdl -a` on `rtl/seq_top_skel.vhd`.

> **Time figures re-derived at the measured clock, 2026-08-27.** Every ms in
> this document was computed at 300 MHz, a **0.85 V analysis clock**. The card
> runs VCCINT 0.717 V, where `matvec_core` at `ROWS_IF = 58` measures
> **237.812 MHz** (MEASURED, `sim/ooc_sweep/results.csv:7`) and at
> `ROWS_IF = 48` measures **236.128 MHz** (`:8`). **The cycle counts are
> unchanged and remain the invariant**; only the divisor moves. Corrections are
> marked in place rather than overwritten, so the superseded figure stays
> readable. Three later findings also bite, and each changes a conclusion rather
> than only a number:
>
> 1. **The `x0.835` derate rule is WITHDRAWN.** Measured across 14
>    configurations the VCCINT derate runs 16.5% to 28.0% against a measurement
>    spread of exactly zero, and 16.5% is its minimum, so every scaled estimate
>    is optimistic. Do not scale an Fmax anywhere in this document.
>    `docs/2026-08-27_verdicts-at-0.717V.md`,
>    `docs/debugging/2026-08-27_derate-is-not-a-constant.md`.
> 2. **`ROWS_IF = 58` is NOT BUILDABLE.** HBM ports are a WIDTH budget,
>    `NPORT = ROWS_IF x 9 / 16`, an exact integer identity with no clock in it.
>    58 needs 32.62 ports, which is not an integer, and rounds to 33 against the
>    30 that exist. `ROWS_IF` must be a multiple of 16 and at most 48, so **48
>    is forced**. Every figure below at `ROWS_IF = 58` is a figure for a
>    configuration that cannot be built.
>    `docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`.
> 3. **§3.3's port table is wrong at the root, not merely at the clock.**
>    Pricing ports in GB/s and provisioning at 1.3x is a category error against
>    a count that must be an exact width divisor. Restating 43/33 as 34/26 would
>    preserve the error. See the correction in §3.3.
>
> Full derivation: `docs/2026-08-27_budgets-at-the-measured-clock.md` section
> 7.4.

**Relationship to the existing D document.** `2026-08-24-transformer-sequencer-
design.md` already exists and is the authority for D's obligations table,
descriptor format, region map, lock states, error semantics and register map.
This document does NOT restate them. It adds the five things that document does
not contain and that the two integration defects of 2026-08-27 make urgent:

1. per-step cycle counts for the schedule (D §4 has the step ORDER, no times);
2. the residual-stream storage decision with its arithmetic;
3. a weight-prefetch analysis against measured HBM numbers, which turns out to
   contradict the `ROWS_IF = 58` balanced point;
4. an entity and port sketch with a stated handshake discipline and an explicit
   stallability verdict per interface;
5. a defect-class analysis: every place D can reproduce the `w_mant` latch
   defect or the `done`-pulse defect, and the mechanism that prevents each.

**Labelling discipline.** Every number below is marked MEASURED (someone ran a
tool and recorded the output), DERIVED (arithmetic shown here from MEASURED or
spec-normative inputs), or ESTIMATE (a judgement with its assumption stated).
Where two specs disagree, both are quoted and neither is silently dropped.

---

## 0. Findings, up front

Five results a reader should not have to dig for. Each is derived in the
section named.

- **F1. The activation regions, residual stream included, are on-chip, and it
  is not a close call (§2).** The residual stream itself is 10,240 bytes. The
  argument that decides it is not its size but the **445 MB per token** of
  activation re-reads that an HBM-resident region set would generate (DERIVED,
  §2.3), plus the fact that A's `x` port contract is a 1-cycle registered read
  (A §7.8 / D O25) that HBM cannot satisfy at any bandwidth.

- **F2. Weight prefetch does NOT close at `ROWS_IF = 58` (§3).** A's weight plus
  scale demand at that point is **313.2 GB/s** against a **MEASURED 288.0 GB/s**
  device supply (30 ports x 32 B x 300 MHz). A is feed-bound by 8.75%. The
  balance point is `ROWS_IF ~= 53`, which A §13's own 2026-08-25 correction
  already states and then describes as "close to (and independently
  corroborates)" `ROWS_IF ~ 58`. It does not corroborate it; 53 < 58 and the
  gap is the stall.

  > **CORRECTION 2026-08-27. F2's ARITHMETIC is superseded; F2's VERDICT stands,
  > for a different and stronger reason.** The 313.2 GB/s demand was computed at
  > 300 MHz, a 0.85 V analysis clock. At the MEASURED 237.812 MHz the demand is
  > `58 x 18 B x 237.812e6` = **248.3 GB/s** against 288.0 supply, so on
  > **bandwidth** A is fed with **13.8% spare** and the bandwidth-balanced
  > `ROWS_IF` moves from 53.3 to 67.3. Read alone that would dissolve F2.
  >
  > **It does not dissolve F2, because bandwidth was never the binding
  > constraint.** HBM ports are a WIDTH budget: one 256-bit port feeds one lane
  > of A's `ROWS_IF x 144`-bit core word, so `NPORT = ROWS_IF x 9 / 16` exactly,
  > with no clock in it. `ROWS_IF = 58` needs 32.62 ports, which is not an
  > integer, and 33 once the scale lane is padded -- against **30 available**.
  > **`ROWS_IF = 58` is not buildable at any clock**, and lowering the clock
  > does not lower the port count, it only lowers each port's duty cycle
  > (79.3% at 237.812 MHz against a 300 MHz ACLK). `ROWS_IF` must be a multiple
  > of 16 and at most 48; **48 is forced**, at 27 ports of 30.
  >
  > "288 GB/s of supply against 248 GB/s of demand, therefore A is fed" is true
  > and irrelevant: the spare bandwidth is spread across ports A cannot use.
  > **Aggregate headroom is not port headroom.**
  > `docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`.

- **F3. A §15.1's HBM port-count table is stale by a factor of 1.5 (§3.3).** It
  divides demand by **14.4 GB/s per port**, which is `32 B x 450 MHz`. The
  achieved ACLK is 300 MHz, where a port carries **9.6 GB/s** (MEASURED, flat
  from 1 to 30 ports). Redone at 9.6, A at `ROWS_IF = 48` with the spec's own
  1.3x provisioning wants **33 ports against 30 available**. D §8.1's "A gets
  ~23-27 dedicated ports, B and C share 4 muxed" is therefore not affordable as
  written.

  > **CORRECTION 2026-08-27. F3 replaced one wrong divisor with another; the
  > 1.3x provisioning is the real defect.** Ports must be an exact divisor of
  > A's core word width, `NPORT = ROWS_IF x 9 / 16`, so there is nothing to
  > provision and no GB/s in the calculation. At `ROWS_IF = 48` the answer is
  > **27 ports of 30, which fits** -- not the 33 F3 computes. A §15.1's table
  > is indeed stale, but redoing it at 9.6 GB/s does not fix it.
  >
  > **F3's conclusion is half right.** D §8.1's "~23-27 dedicated" for A is
  > exactly affordable at its top end, 27. What does not survive is the "4
  > muxed" for B and C: 30 - 27 = **3**. And the operating point F3 was written
  > against, `ROWS_IF = 58`, needs 33 ports and is **not buildable at any
  > clock**. See the §3.3 correction and
  > `docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`.

- **F4. D §5.4's exponent capture is protected by nothing (§5.2, hazard A3).**
  The region lock freezes a region's DATA in HELD. Nothing in D §5.3 or §5.4
  freezes that region's exponent capture register, and the exponent is read by
  the consumer for the whole job. That is defect class (a) exactly: a value the
  consumer reads for the duration, held by convention rather than by a checked
  instant. NEW finding.

- **F5. D §4.5's "pipeline E's output stream into the residual" introduces an
  unstallable producer (§5.3, hazard B7).** E's `o_we/o_addr/o_data` has no
  ready in E §2. If D-vec pass 1 can stall for even one cycle, the beat is
  lost, silently, exactly as `gdn_recur_pipe`'s columns were lost. The
  optimisation is worth ~5,120 cycles per collective and must not ship without
  either a ready on E or a proven-unstallable pass 1.

---

## 1. The per-token schedule, with cycle counts

### 1.1 Layer map (verified, not assumed)

64 blocks. Block `i` is attention iff `(i+1) mod 4 = 0`, i.e. 3, 7, ..., 63:
16 attention, 48 GDN (C §4.1, D §4.1). Ordinals, checked at i = 0, 1, 2, 4, 63:

```
gdn_ord(i)  = i - (i+1)/4     -- integer division, 0..47
attn_ord(i) = (i-3)/4         -- 0..15
```

D does not compute these at run time. They are host-side generator checks; the
descriptor carries `layer_type` and `ordinal` per step (D §6.1).

### 1.2 The cost model for an A job

A's array retires `ROWS_IF` output rows against `BLOCK = 32` input columns per
cycle. For an M-row, K-column job on one card:

```
cycles_A(M, K) = ceil(M / ROWS_IF) * ceil(K / BLOCK)
```

DERIVED, from A §7.2's geometry. It excludes per-job start, drain and
descriptor-abort checks, which D §11 lumps into its ~20-30 cycles per step. All
tables below use `ROWS_IF = 58` (A §15.4c "balanced") and `BLOCK = 32`.

> **2026-08-27: `ROWS_IF = 58` is not buildable, so every cycle count below is
> for a configuration that cannot be built.** It needs 33 HBM ports of the 30
> available, by the exact width identity `NPORT = ROWS_IF x 9 / 16` (§3.3
> correction). **`ROWS_IF = 48` is forced.** The model itself is unaffected --
> `cycles_A(M, K) = ceil(M / ROWS_IF) x ceil(K / BLOCK)` holds at any
> `ROWS_IF` -- but its instantiation is not. At 48 the 27B A total is
> **8,381,664 cycles** against 6,954,528 at 58, and the padding waste changes
> too: `ceil(8704/48) = 182` and `ceil(24/48) = 1`. Nothing below has been
> re-tabulated at 48; the totals that matter are in the §1.6 correction.

The ceilings are not decoration. `ceil(24/58) = 1` is what makes `ssm_beta` and
`ssm_alpha` cost a full 160 cycles each to produce 24 numbers, and
`ceil(8704/58) = 151` wastes 54 of 8,758 row slots. Total padding waste across
a GDN layer is 104,112 against 103,238 unpadded cycles, **0.85%** (DERIVED).

### 1.3 GDN block: 18 steps

Dimensions per card at N=2 from D §4.2 and B §4: key_dim 1024, value_dim 3072,
conv_dim 5120, FFN 8704, hidden 5120, 24 value heads, 8 key heads.

| # | step | unit | M | K | tiles | blocks | cycles | basis |
|---|---|---|---|---|---|---|---|---|
| 1 | attn_norm | D-vec | | 5120 | | | 1,280 | DERIVED, 2 passes / `LANES_V` 8 |
| 2 | wqkv q | A | 1024 | 5120 | 18 | 160 | 2,880 | DERIVED |
| 3 | wqkv k | A | 1024 | 5120 | 18 | 160 | 2,880 | DERIVED |
| 4 | wqkv v | A | 3072 | 5120 | 53 | 160 | 8,480 | DERIVED |
| 5 | wqkv_gate z | A | 3072 | 5120 | 53 | 160 | 8,480 | DERIVED |
| 6 | ssm_beta | A | 24 | 5120 | 1 | 160 | 160 | DERIVED |
| 7 | ssm_alpha | A | 24 | 5120 | 1 | 160 | 160 | DERIVED |
| 8 | GDN | B | | | | | **12,288 to 35,942** | see below |
| 9 | ssm_out | A | 5120 | 3072 | 89 | 96 | 8,544 | DERIVED, partial mode |
| 10 | all-reduce | E | | | | | ~1,406 | DERIVED from E §2.4 |
| 11 | residual | D-vec | | 5120 | | | 1,280 | DERIVED |
| 12 | ffn_norm | D-vec | | 5120 | | | 1,280 | DERIVED |
| 13 | ffn_gate | A | 8704 | 5120 | 151 | 160 | 24,160 | DERIVED |
| 14 | ffn_up | A | 8704 | 5120 | 151 | 160 | 24,160 | DERIVED |
| 15 | swiglu | D-vec | | 8704 | | | 2,176 | DERIVED |
| 16 | ffn_down | A | 5120 | 8704 | 89 | 272 | 24,208 | DERIVED, partial mode |
| 17 | all-reduce | E | | | | | ~1,406 | DERIVED |
| 18 | residual | D-vec | | 5120 | | | 1,280 | DERIVED |

**A subtotal 104,112 cycles. D-vec subtotal 7,296. E subtotal 2,812.**

Step 8, B, is the widest range in this document and the honest form is a range:

- **12,288 cycles** is the state sweep alone: `589,824 / 48` at `LANES = 32`
  (B §3.1). VERIFIED three independent ways in
  `docs/2026-08-27_direction-review-fable.md` §2; the two derivations
  (`128 x 128 x 24 x 48 / 32` at 27B, and `262,144 x 18 / 8` at 0.8B) coincide
  exactly because `(24/16) x (48/18) = 4 = 32/8`.
- **35,942 cycles** is `1,725,216 / 48`, the direction review's worst case with
  the conv/scalar bundle (529,440) and both emit stages (605,952) fully
  serialized against the sweep and nothing overlapping.
- The MEASURED emit-chain figure is **17,253 cycles per block** overlapped
  (`2026-08-27_gdn-emit-chain-w-latch.md`, 24 heads x 128 at a 1 ns clock,
  against 22,386 serialized). That is a testbench-rate number, not a
  system-rate number, and it already exceeds the 12,288-cycle sweep, which is
  what B's F2 single-buffering defect predicts.

**D must not encode either endpoint.** B's `done` is a handshake; D waits. The
range matters only for the token budget of §1.6.

### 1.4 Attention block: 15 steps

Per card at N=2: 12 query heads, 2 KV heads, head dim 256, so wq emits Q plus
gate interleaved at 6144, wk and wv at 512 each, C's y at 3072 (D §4.3, C §4).

| # | step | unit | M | K | tiles | blocks | cycles | basis |
|---|---|---|---|---|---|---|---|---|
| 1 | attn_norm | D-vec | | 5120 | | | 1,280 | DERIVED |
| 2 | wq (Q+gate) | A | 6144 | 5120 | 106 | 160 | 16,960 | DERIVED |
| 3 | wk | A | 512 | 5120 | 9 | 160 | 1,440 | DERIVED |
| 4 | wv | A | 512 | 5120 | 9 | 160 | 1,440 | DERIVED |
| 5 | attention | C | | | | | **~86,100** | DERIVED, see below |
| 6 | wo | A | 5120 | 3072 | 89 | 96 | 8,544 | DERIVED, partial mode |
| 7 | all-reduce | E | | | | | ~1,406 | DERIVED |
| 8 | residual | D-vec | | 5120 | | | 1,280 | DERIVED |
| 9-15 | FFN block | | | | | | 78,670 | = GDN steps 12-18, see below |

The FFN block is identical in both layer types: ffn_norm 1,280 + gate 24,160 +
up 24,160 + swiglu 2,176 + down 24,208 + all-reduce 1,406 + residual 1,280 =
**78,670 cycles**, of which 72,528 is A.

**A subtotal 100,912 cycles. D-vec subtotal 7,296. E subtotal 2,812.**

Step 5: D §11 carries C at **4.59 ms/token at 300 MHz** (C §3, after C's R-C2
correction added the aux terms). Over 16 blocks that is 0.287 ms = **86,100
cycles per block**, DERIVED. It scales linearly with context: 4.59 ms is
ctx 2048, and 4K doubles it (A §15.4c). D's schedule is indifferent to the
value; the token budget is not.

> **2026-08-27: this cycle count was back-derived from a ms figure, which is the
> anti-pattern §1.6 warns about one section later.** It happens to be
> clock-neutral -- 4.59 ms was itself `cycles / 300 MHz`, so dividing by
> 300 MHz recovers cycles -- but it inherits whatever cycle count produced the
> 4.59. **C's cycle count has since moved.** The C skeleton's §4 model gives
> **1,310,400 cycles per token = 81,900 per block**, against the 86,100 here,
> the whole difference being a QK-norm row that 4.59 carried at 166K cycles and
> the measured `rmsnorm_rs` puts at 104,192. Not changed here, because this pass
> changes no cycle counts. Quote C in cycles, not in ms.

### 1.5 Token tail

| step | unit | cycles | basis |
|---|---|---|---|
| final rmsnorm | D-vec | 1,280 | DERIVED |
| lm_head | A | 342,560 | DERIVED, `ceil(124160/58) = 2141` tiles x 160 blocks |
| argmax capture | D | ~2 | latched from `sampler_stream` at `done` |

`124,160` is D §3.3's per-card vocab shard at N=2, implying vocab 248,320.
That is roughly 1.6x the 151,936 of the shipped Qwen3 tokenizer and is **not
verified here**; see §7 item 6.

### 1.6 Token totals

Per card, N=2, `ROWS_IF = 58`, `LANES = 32`, `LANES_V = 8`, `MACS = 192`,
300 MHz, ctx 2048. All DERIVED by summing the tables above.

| unit | cycles/token | ms | note |
|---|---|---|---|
| A, array-limited | 6,954,528 | 23.18 | 48 x 104,112 + 16 x 100,912 + 342,560 |
| A, feed-limited | 7,563,049 | 25.21 | x 1.0875, the §3.2 shortfall |
| C | 1,377,600 | 4.59 | 16 x 86,100 |
| B | 589,824 to 1,725,216 | 1.97 to 5.75 | sweep only, to worst case |
| D-vec | 468,224 | 1.56 | 64 x 7,296 + 1,280 final norm |
| E | 179,968 | 0.60 | 128 x 1,406, E §2.4's N=2 row |
| D-ctrl | 22,000 to 33,000 | 0.07 to 0.11 | 1,106 steps x 20-30 |
| **total** | **10,200,665 to 11,347,057** | **34.00 to 37.82** | |

**CORRECTION 2026-08-27 -- the ms column is at a 0.85 V analysis clock, and the
whole table is at an unbuildable operating point.** The table is kept as printed.
Cycle counts are unchanged. At the MEASURED **237.812 MHz**, DERIVED from the
same cycle counts:

| unit | cycles/token | **ms @237.812** | note |
|---|---|---|---|
| A, array-limited | 6,954,528 | **29.244** | |
| A, HBM floor | -- | **25.210** | `7.2605 GB / 288.0 GB/s`, **clock-invariant**; it no longer binds, see the §3.2 correction |
| **A = max of the two** | | **29.244** | |
| C | 1,377,600 | **5.793** | this row's own cycle count; see the disagreement note below |
| B | 589,824 to 1,725,216 | **2.480 to 7.255** | |
| D-vec | 468,224 | **1.969** | |
| E | 179,968 | **0.636** | **only 0.036 of the change is the clock**; E is PCIe-bound and only its 320-cycle `t_tail` per collective is core-clock work |
| D-ctrl | 22,000 to 33,000 | **0.093 to 0.139** | |
| **total** | **9,592,144 to 10,738,536** | **40.21 to 45.03** | |

**Note on the total's cycle column.** The printed 10,200,665 to 11,347,057 sums
A at its **feed-limited** 7,563,049, which was the binding row at 300 MHz. At
237.812 MHz the array-limited 6,954,528 binds instead, so the correct cycle
total is **9,592,144 to 10,738,536**. The ms total is not a division of it in any
case: E's 0.636 ms is almost entirely PCIe and does not come from its cycle
count, so cycles and milliseconds cannot be converted into each other at the
token level. Quote whichever one the argument needs, never both as if they were
the same statement.

**Recorded disagreement, C's row.** The budget document's correction table gives
this row as **5.51 ms**, which is not a rescaling of 1,377,600 cycles -- it is
1,310,400 cycles, the C skeleton's corrected count, divided by 237.812 MHz. That
substitutes a cycle count as well as a clock, and this pass changes no cycle
counts. **Both are printed: 5.793 ms from this table's own 1,377,600 cycles, and
5.510 ms if the C skeleton's 1,310,400 is adopted.** With the latter the total
is **39.93 to 44.75 ms**. The budget document prints 39.97 to 44.74 for that
case; neither figure reproduces here to better than 0.04 ms and the difference
is rounding in the intermediate rows. Nothing was written from it.

**And the operating point does not exist.** This table is at `ROWS_IF = 58`,
which needs 33 HBM ports against 30 available (§3.3 correction). At the forced
`ROWS_IF = 48` and its own measured clock of 236.128 MHz, A is 8,381,664 cycles
= **35.50 ms**, and the 27B N=2 token is **~47.3 ms, ~21.1 tok/s** (DERIVED).
The table above is therefore an upper bound on performance that no build can
reach, not a projection.

Against the project's **~39 ms reference**: that reference is the sum of
D §11's own table and is **verified as a sum**, but it is not an independent
check on this one. Three of its five rows (C, E, D-vec) are quoted here rather
than re-derived, so the agreement to within 3 to 13% mostly reflects shared
inputs. What is genuinely independent is the A row: D §11 implies A at ~30.5 ms
(35.1 minus C's 4.59), where the tile arithmetic above gives 23.18 ms
array-limited and 25.21 ms feed-limited. **That is a 17 to 24% disagreement on
the largest term in the token and this document cannot resolve it**; see §7
item 1.

**CORRECTION 2026-08-27 -- most of the RANGE was the clock; the GAP was not.**
The two derivations were made at different clocks. D §11's A term descends from
A §15.4c, whose own anchors are stated at **276 MHz**; the tile arithmetic above
is at **300 MHz**; and the feed-limited figure is clock-invariant. Normalised to
a single clock the two comparisons collapse onto each other at 18.6-18.7%,
which expressed the way this paragraph expresses it -- as a fraction of the
larger figure -- is **~16%, not a 17-to-24% range**. The range was an artefact
of comparing figures derived at different clocks. **The residual ~16% is real
and is still unresolved**, and this correction does not resolve it either.
Derivation: `docs/2026-08-27_budgets-at-the-measured-clock.md` section 4.

The **1.97 ms** figure for B's sweep checks out at both clocks quoted in B's
own document: `589,824 / 300.0 MHz = 1.966 ms` and
`589,824 / 299.04 MHz = 1.972 ms`. Both round to 1.97, which is a coincidence
of rounding rather than agreement, and B §3.1 quotes the number against both
clocks without saying so.

> **2026-08-27: `589,824 / 237.812 MHz = 2.480 ms`.** The lesson of this
> paragraph is the durable part and it survives: two clocks 0.32% apart cannot
> be told apart through two-decimal rounding, so a figure must be quoted in
> cycles with its clock named. The two clocks it compares are both 0.85 V
> analysis clocks, and the gap that actually mattered was the 20.5% to the
> operating voltage, which no amount of rounding hides.

### 1.7 What D overlaps

Unchanged from D §4.5 and re-stated because §5 depends on it: descriptor
prefetch (free), E's output stream into the residual (see hazard B7 in §5.3 --
this one is not free, it is unsafe as specified), and nothing else. At batch 1
every post-collective operation is data-dependent on the collective. The token
is a chain.

---

## 2. The residual stream

### 2.1 Where it lives and how wide

The residual stream is region **X** of D §5.1: `hidden = 5120` elements of
int16 plus one shared BFP exponent.

```
5120 elements x 16 bits = 81,920 bits = 10,240 bytes  (DERIVED)
plus 1 x int16 exponent  =        2 bytes
```

It is written once by the host (the embedding row, D §3.2) and then read-
modify-written **128 times per token**: two residual adds per block (post-mixer
and post-FFN) across 64 blocks.

### 2.2 Bytes per token through it

Each residual pass reads X, reads ER, writes X:

```
128 passes x (10,240 read + 10,240 read + 10,240 write) = 3,932,160 B
                                                        = 3.93 MB/token (DERIVED)
```

Plus 129 norm passes (128 in-block plus the final norm) reading X and writing
XN, two passes each for the sum-of-squares then the scale:

```
129 x 2 passes x (10,240 read + 10,240 write) = 5.28 MB/token (DERIVED)
```

So the residual stream itself moves under 10 MB per token. That is 0.13% of the
7.559 GB weight read and would be affordable in HBM **bandwidth**. Bandwidth is
not what decides it.

### 2.3 The number that decides it: 445 MB of activation re-reads

X is not read alone. Every A job re-reads its whole source vector once per
output tile, because the array holds `ROWS_IF` rows and streams K columns past
them; the next tile of rows re-streams the same K columns. Traffic for one A
job is `ceil(M/ROWS_IF) x K x 2 bytes`.

| block type | per-block activation reads | count | total |
|---|---|---|---|
| GDN | 6,663,168 B | 48 | 319,832,064 B |
| attention | 6,458,368 B | 16 | 103,333,888 B |
| lm_head | 21,923,840 B | 1 | 21,923,840 B |
| **total** | | | **445,089,792 B = 445.1 MB/token** |

DERIVED. Worked for one GDN block: q 18x5120x2 + k 18x5120x2 + v 53x5120x2 +
z 53x5120x2 + beta 1x5120x2 + alpha 1x5120x2 + ssm_out 89x3072x2 +
gate 151x5120x2 + up 151x5120x2 + down 89x8704x2 = 6,663,168 B.

Against the weight read: `445.1 / 7,559 = 5.89%`. At the MEASURED 288.0 GB/s
device supply that is **1.55 ms per token of additional HBM time**, and it would
have to come out of ports A already does not have (§3.3). On-chip it is free.

### 2.4 The structural argument, which is stronger than the bandwidth one

A §7.8 and D O25 specify A's `x` port as a **BLOCK-wide (512-bit) 1-cycle
registered read**. HBM cannot do that at any bandwidth: the read latency is tens
of cycles and variable. An HBM-resident X would require a full activation cache
in front of A, which is the on-chip region with extra steps.

The same applies to B's five read ports and C's three.

### 2.5 Verdict and the BRAM arithmetic

**On-chip BRAM. Not a close call.**

The cost is set by **port width, not capacity**. A 512-bit read port needs 8
banks of 64 bits; a RAMB36 in SDP mode is at most 72 bits wide. So every
BLOCK-wide region costs 8 RAMB36 regardless of how shallow it is.

| | value | basis |
|---|---|---|
| X alone, by capacity | 81,920 bits = 2.22 RAMB36 | DERIVED |
| X alone, by port width | **8 RAMB36** | DERIVED, 8 x 64 b = 512 b |
| 10 BLOCK-wide regions (X, XN, QKV, Z, QG, Y, G, U, H, ER) | **80 RAMB36** | DERIVED |
| capacity actually used by those 10 | 58,880 entries x 16 b = 942,080 b of 2,949,120 b | **32%** |
| 4 narrow regions (BETA, ALPHA, KIN, VIN) | 1,088 entries, LUTRAM | D §5.1 |
| D-vec s18 two-pass scratch, 8,704 deep | ~6 RAMB36 | D §7.3 |
| **D total, flat map** | **~86 RAMB36 of 672 = 12.8%** | |
| D total, packed map (D §5.1 fallback) | ~54 RAMB36 = 8.0% | |

The 32% capacity utilisation is the honest characterisation of this design: D
is spending BRAM on bandwidth, not on storage, and a narrower read port would
save tiles at the cost of A's feed rate. It is not worth doing while 86 of 672
is affordable, but it is the first lever if the die-wide BRAM sum (which does
not exist, see §7 item 3) comes in tight.

---

## 3. Weight prefetch, and whether HBM supports it

### 3.1 What has to be in flight

At batch 1 there is no weight reuse. Every weight is read once and multiplied
once, so **A's compute rate and A's memory rate are the same quantity** and the
ratio is fixed by the pack format:

```
bytes per MAC = (4 bits weight + 16 bits scale / 32 weights) / 8
              = 4.5 bits / 8 = 0.5625 B/MAC        (DERIVED, A section 6.1)
```

Per core cycle at `ROWS_IF` rows and `BLOCK = 32` columns:

```
weights: ROWS_IF x 32 x 4 bits  = 128 x ROWS_IF bits/cycle
scales:  ROWS_IF x 16 bits      =  16 x ROWS_IF bits/cycle
total:                            144 x ROWS_IF bits/cycle = 18 x ROWS_IF B/cycle
```

Cross-check against A §15.1's own table, which is the point of doing it this
way: at `ROWS_IF = 56` and 288 MHz the formula gives `56 x 16 B x 288e6 =
258.0 GB/s` of weights and `56 x 2 B x 288e6 = 32.3 GB/s` of scales. A §15.1
prints 258 and 32. The model reproduces the spec exactly, so what follows is a
disagreement about inputs, not about arithmetic.

There is no prefetch depth that changes this. A prefetch buffer smooths burst
structure; it cannot raise the average. The question "what has to be in flight
to keep compute busy" has the answer **the full steady-state rate, continuously**,
and the only sizing question left is the FIFO depth needed to cover HBM's
latency and refresh jitter, which A §7.7 budgets at ~8 KB per port.

### 3.2 Demand against supply

| | value | basis |
|---|---|---|
| Device usable bandwidth | `ports x 32 B x f_ACLK` | MEASURED, `2026-08-25_hbm-upper-bound-is-the-clock.md` |
| Ports available to a design that also talks to the host | **30 of 32** | MEASURED, A §13 correction (SAXI_00 and SAXI_16 carry `jtag_hbm`) |
| Achieved ACLK | **300 MHz** (350 misses by 0.395 to 0.467 ns; 450 needs unbuilt pipelining) | MEASURED, same |
| Per-port rate at 300 MHz | **9.6 GB/s**, flat from 1 to 30 ports, 100.0% of the arithmetic ceiling | MEASURED |
| **Device supply** | **288.0 GB/s** | MEASURED, `hw/fk33/results/hbmbw_30port_300mhz.txt` |
| A demand at `ROWS_IF = 58`, 300 MHz | `58 x 18 B x 300e6` = **313.2 GB/s** | DERIVED |
| **Shortfall** | **313.2 / 288.0 = 1.0875** | DERIVED |

**A is feed-bound at the balanced point by 8.75%.** The bandwidth-balanced
`ROWS_IF` is `288.0 / (18 x 300e6) = 53.3`, so **53**.

A §13's own 2026-08-25 correction reaches the same 53 (`80 x 288/432 ~ 53`) and
then writes that this is "close to (and independently corroborates) the §15.4c
balanced point at `ROWS_IF ~ 58`". **It does not corroborate it.** 53 is the
point at which the array is exactly fed; 58 is 9% past it, and the extra 5 rows
cost `5 x 46.5 = 233` DSP (8.1% of the die, from A §15's `DSP = 8 + 46.50 x
ROWS_IF`) to buy array capacity that memory cannot supply. Both statements are
in the same document, one section apart.

Since A/B/C are never simultaneously active (D O13), this is a comparison of A
alone against the whole device, which is the most favourable form. It still
fails.

**CORRECTION 2026-08-27 -- the demand row and the shortfall are at the wrong
clock, and the shortfall disappears without the conclusion changing.** The
`313.2 GB/s` and the `1.0875` are computed at `f_core = 300 MHz`, a 0.85 V
analysis clock. Every other row in the table above is MEASURED and unaffected:
the 30 ports, the 300 MHz ACLK, the 9.6 GB/s per port and the 288.0 GB/s device
supply all stand. Restated at the MEASURED `f_core = 237.812 MHz`, DERIVED:

| | at 300 MHz (as printed) | **at 237.812 MHz** |
|---|---|---|
| A demand at `ROWS_IF = 58` | 313.2 GB/s | **248.3 GB/s** |
| shortfall against 288.0 | **1.0875** | **none; 13.8% spare** |
| bandwidth-balanced `ROWS_IF` | 53.3 | **67.3** |

**The `x1.0875` multiplier applied to A's feed-limited row in §1.6 is therefore
1.0 at the operating clock.** A's HBM floor of 25.21 ms survives as a
clock-invariant lower bound -- it is `7.2605 GB / 288.0 GB/s` with both inputs
MEASURED -- but it stops being the binding term, because the array-limited
figure at 237.812 MHz is 29.24 ms.

**None of this licenses `ROWS_IF = 58`, and the "balanced 67.3" must not be read
as a design point.** The bandwidth-balanced `ROWS_IF` is not the buildable
`ROWS_IF`. Ports are a width budget, `NPORT = ROWS_IF x 9 / 16`; 58 needs 33 of
30 and 67 would need 38. The buildable ceiling is **48, at 27 ports of 30**, and
`ROWS_IF` must be a multiple of 16. See the F2 correction in §0 and
`docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`.

### 3.3 The port-count table is stale by 1.5x

A §15.1 sizes ports as `demand x 1.3 / 14.4 GB/s`. The 14.4 figure is
`32 B x 450 MHz`, the rate at which one AXI port exactly matches one HBM
pseudo-channel. At the achieved 300 MHz ACLK a port carries 9.6 GB/s. Redone:

| | A §15.1, at 14.4 GB/s | at the MEASURED 9.6 GB/s |
|---|---|---|
| `ROWS_IF = 48` @ 276 MHz, weights 212 GB/s | 20 ports | **29 ports** |
| same, scales 27 GB/s | 3 ports | **4 ports** |
| **total at 1.3x** | **23 of 32** | **33 of 30 available** |
| `ROWS_IF = 58` @ 300 MHz, weights 278.4 GB/s | 26 | **38** |
| same, scales 34.8 GB/s | 4 | **5** |
| **total at 1.3x** | **30** | **43 of 30** |

A §15.1 is dated 2026-08-23; the HBM clock measurement is 2026-08-25. The table
predates its input. This is exactly the failure mode D §2.2-C records against
itself: a cross-spec figure is only true as of the revision it was read at.

**CORRECTION 2026-08-27 -- the METHOD is wrong, not just the divisor, and this
section inherits the error it is correcting.** F3 is right that 14.4 GB/s is
stale and 9.6 GB/s is the measured per-port rate. It is wrong that swapping the
divisor fixes the table, because **pricing a port in GB/s and provisioning it at
1.3x is a category error.**

A port is not a quantity of bandwidth here. One HBM SAXI port delivers 256 bits
per ACLK cycle into one lane of A's `ROWS_IF x 144`-bit core word, so the count
is an exact integer identity:

```
NPORT = ROWS_IF x 144 / 256 = ROWS_IF x 9 / 16      (BLK = 32, AXI_DW = 256)
```

**with no clock in it and nothing to provision against.** Measured HBM
efficiency is 100.0% at every port count from 1 to 30, and 100% under 30-way
oversubscription, so the 1.3x has nothing to absorb. The identity is a **lower
bound the bandwidth answer can drop below**, which is the whole failure: a
bandwidth calculation at a lower `f_core` returns a smaller number and licenses
a configuration that cannot be wired.

The corrected counts, DERIVED
(`docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`):

| `ROWS_IF` | weight lanes | scale lanes | **ports** | of 30 |
|---|---|---|---|---|
| 32 | 16 | 2 | **18** | fits, 12 spare |
| **48** | **24** | **3** | **27** | **fits, 3 spare** |
| 52 | 26 | 4 | **30** | fits, 0 spare |
| 58 | 29 | 4 | **33** | **-3, NOT BUILDABLE** |
| 64 | 32 | 4 | **36** | -6, impossible |

`ROWS_IF x 144 / 256` is integral only when `ROWS_IF mod 16 = 0`; otherwise the
scale lane pads (58 wastes 96 bits per word, 9.4%). So `ROWS_IF` must be a
multiple of 16 and at most 48: **48 is forced.**

**Do NOT restate the 43/33 and 30/23 counts above as 34/26.** Those are the
numbers a 237.812 MHz bandwidth calculation returns, and they are wrong in the
dangerous direction: 26 at 1.0x would look like `ROWS_IF = 58` fits in 30 ports
when it needs 33. **The 1.0x column's 33 at `ROWS_IF = 58` is numerically right
by accident** -- it was evaluated at `f_core = f_ACLK = 300 MHz`, the one point
where the bandwidth method and the width identity are the same calculation.
Re-evaluating that same formula at the measured core clock gives 26 and would
have licensed an unbuildable design. **A method that is right only at one clock
is not a method.**

**Both of the two readings offered below are therefore void as written.** The
first ("the port table is right and ACLK must reach 450 MHz") rests on the
bandwidth method; raising ACLK does not reduce a width divisor, it only raises
the lanes-per-port ratio `K = floor(f_ACLK / f_core)`, and reaching `K = 2` at a
300 MHz ACLK would need `f_core <= 150 MHz`, which is a net loss. The second
("`ROWS_IF` drops to ~53") lands one short of 52 and is not a multiple of 16.
**The surviving answer is `ROWS_IF = 48` at 27 ports of 30**, which costs
+3.91 ms per token on A at 9B, +21.6% on A alone, and returns 330 DSP.

Two readings, and this document does not have the standing to choose:

- **The port table is right and ACLK must reach 450 MHz.** Then supply is
  `30 x 14.4 = 432 GB/s`, `ROWS_IF = 58` fits at 313.2 GB/s with 27% margin,
  and A §14.5 item 3's CDC between the ~450 MHz HBM clock and the ~300 MHz core
  clock becomes mandatory rather than deferred. Nothing has closed 450 MHz.
- **300 MHz ACLK stands and `ROWS_IF` drops to ~53.** Then the die reclaims 233
  DSP, which is 8.1% and larger than every open DSP question in the project
  combined (the direction review puts the whole unmeasured spread at 42 DSP).

Either way, **D §8.1's static port assignment does not survive.** At 300 MHz
ACLK there are not 4 spare ports for B and C after A is fed; at 450 MHz ACLK
there are, but D's grant mux then straddles a clock-domain crossing that no
document specifies.

### 3.4 What D can and cannot do about it

D can do **nothing** about F2. The shortfall is a steady-state rate mismatch
inside one job; no reordering of jobs, no prefetch depth and no overlap changes
an average. Recording it here is the deliverable, not fixing it.

What D **is** responsible for is not making it worse:

- **The grant switch must not cost bandwidth.** D §8.2's rule (grant changes
  only when per-port outstanding counters read zero) drains the pipe at every
  re-grant. Two cases, and they differ by an order of magnitude:
  - **If A keeps dedicated ports** (D §8.1 as written), only the 4 muxed ports
    switch, and only at a layer-type change. The block pattern is
    `GDN,GDN,GDN,ATTN` repeating, so there are 16 B-to-C and 16 C-to-B
    transitions: **32 switches per token**. At an assumed ~100-cycle HBM read
    latency that is ~3,200 cycles, **0.03% of the token**.
  - **If §3.3 forces A onto the shared pool**, every A-to-mixer and
    mixer-to-A boundary re-grants: 593 A jobs plus 64 mixer jobs, so **~650
    switches per token**, ~65,000 cycles, **0.6% of the token**. Still small,
    but it is 20x the first case and it is a cost F3 introduces silently.

  Both are ESTIMATEs: **nothing has measured HBM read latency on this card**,
  and `hbm_tg` has no write channel at all, so the write-side drain is
  unmeasured in principle. This is the reason to keep counting at the port
  rather than trusting `done`.

  > **2026-08-27: the cycle counts are unchanged; the ms and the percentages
  > both move slightly.** In milliseconds at the MEASURED 237.812 MHz the two
  > costs are **0.013 ms** and **0.273 ms** (DERIVED), against 0.011 and 0.217
  > at 300 MHz. The percentages move for a reason that is easy to miss: the
  > printed 0.03% and 0.6% are fractions of §1.6's 10,200,665-cycle token, which
  > sums A at its **feed-limited** 7,563,049. At 237.812 MHz the array-limited
  > 6,954,528 binds instead, so the token is 9,592,144 cycles and the same costs
  > are **0.03%** and **0.68%** (0.68% either way: 65,000 / 9,592,144 = 0.678%,
  > and 0.273 / 40.21 ms = 0.679%). The order-of-magnitude gap between the two
  > cases, which is the point of the bullet, is unchanged.
  >
  > **The second case is now the live one.** It is conditioned on "if §3.3 forces
  > A onto the shared pool". §3.3's corrected answer is that A takes 27 of the 30
  > ports at the forced `ROWS_IF = 48`, leaving 3 rather than the 4 D §8.1
  > allocates, so the static assignment does not survive as written.
  >
  > **The second case is now the live one.** It is conditioned on "if §3.3 forces
  > A onto the shared pool". §3.3's corrected answer is that A takes 27 of the 30
  > ports at the forced `ROWS_IF = 48`, leaving 3 rather than the 4 D §8.1
  > allocates, so the static assignment does not survive as written.
- **D must not put its own traffic on A's ports.** D §6.4's URAM residency for
  the descriptor table, the norm weights and B's constants is worth ~1.53 MB
  per token of HBM traffic avoided and, more importantly, zero ports. Keep it.
- **The 445 MB/token of activation re-reads must stay off HBM** (§2.3). At
  5.89% of the weight read it would push a design that is already 8.75% short
  to 15% short.
  > **2026-08-27: there is no 8.75% shortfall at the measured clock.** At
  > 237.812 MHz and `ROWS_IF = 58` the demand is 248.3 GB/s against 288.0
  > supply, 13.8% spare, and at the forced `ROWS_IF = 48` and 236.128 MHz it is
  > 204.0 GB/s, 29.2% spare (DERIVED). The 445 MB/token would consume 5.89% of
  > that spare rather than deepening a deficit. **The rule still holds and the
  > reason is now the stronger one:** those re-reads would need PORTS, and at
  > `ROWS_IF = 48` A already takes 27 of the 30. Bandwidth headroom is not port
  > headroom.

### 3.5 E's collective traffic, for completeness

At N=2, 128 collectives x 40 KB = **5.12 MB/card/token** over PCIe, not HBM
(E §2.4). It does not compete for HBM ports.

**Contradiction, unresolved.** E §2.4's table gives "Est. collective time per
token" as **~0.6 ms** at N=2. D §4.5 and D §11 both cite **~0.42 ms** and
attribute it to E §2.4. There is no 0.42 anywhere in E's document; the nearest
source is the recon's `128 x 2 x ~1.5 us = 0.4 ms`. §1.6 uses E's own 0.6 ms.
The difference is 0.18 ms, under 0.5% of the token, so nothing turns on it, but
the citation is wrong and should be corrected in D §11 rather than propagated.

---

## 4. State and resource budget

### 4.1 DSP: D-ctrl is zero, and here is the argument

**D-ctrl uses no DSP48E2.** Not "should" -- it is achievable, and the reason is
that every multiplication in D's job has been moved off the critical path by
construction:

| candidate | why it is not a multiply |
|---|---|
| `gdn_ord` / `attn_ord` from the block index | computed by the host generator, delivered as a descriptor field (D §4.1) |
| `ceil(M/ROWS_IF)`, `ceil(K/BLOCK)` tile counts | A computes its own loop bounds from `n_rows`/`n_cols`; D never divides |
| region base plus offset addressing | adds and compares |
| `dst_offset + n_rows <= region_size` bound check | one add, one compare |
| descriptor address from step index | a 64-byte stride, so a shift, not a multiply |
| URAM constant address from `ordinal` | `ordinal x 128` for `ssm_norm`, `ordinal x 5120` for norm weights: **the second one is not a power of two** |

That last row is the only real one, and the fix is structural, not arithmetic:
**pad the norm-weight stride to 8192 elements** and the address is a shift. The
cost is `129 x (8192 - 5120) x 2 B = 792 KB` of URAM, which is ~22 URAM288
blocks on top of D §6.4's ~44, taking D to ~66 of 320. Alternatively keep 5120
and use a small adder-accumulator walked once per block (5120 added per block
advance, 64 adds per token). **Take the accumulator**: it is one 32-bit adder,
it costs nothing, and it does not spend 22 URAM blocks to avoid a DSP that a
LUT-based multiplier would also have absorbed.

D-vec is a separate matter and is **28 DSP MEASURED** at `LANES_V = 8`, shared
(52 unshared), per D §7.1 and `2026-08-25_d-vec-dsp-measured.md`. Sharing is a
property of how the RTL is written, so it is normative on D-vec, not margin.

**D total: 28 DSP, 0.97% of 2,880.** The whole-die figure it enters is
2,606 to 2,648 = 90.5% to 91.9% (B §3.6), and D's row is not where that pressure
comes from.

### 4.2 BRAM

From §2.5: **~86 RAMB36 flat (12.8% of 672), ~54 packed**. Of the 86, ~16
replace A's standalone activation memory and result buffer rather than adding to
the die (D §5.1), so D's marginal cost is ~70.

### 4.3 URAM

D §6.4's ~44 of 320 stands: descriptor table ~7, norm weights ~36, B constants
~1. It grows with `NSUB` if A §14.5 resolves above 33 bases per job. At
`ROWS_IF = 58` the §6.5 invariant `NPORTS_W x AXI_DW = ROWS_IF x BLOCK x 4`
gives `NPORTS_W = 58 x 128 / 256 = 29` lanes exactly, so 29 weight bases plus 4
scale bases = 33, which is what D §2.2-J assumes. At `ROWS_IF = 53` it is
`53 x 128 / 256 = 26.5`, **not an integer**: the invariant is not satisfiable at
53 with `AXI_DW = 256`. Legal `ROWS_IF` values are even. **`ROWS_IF = 52` is
the largest legal point that the 288 GB/s supply feeds** (`52 x 18 x 300e6 =
280.8 GB/s`). NEW, DERIVED; A's own text does not note the parity constraint.

### 4.4 Sequencer state, itemised

| item | bits | note |
|---|---|---|
| step index | 11 | 1,106 steps per token |
| block index, layer type, ordinal | 6 + 1 + 6 | |
| `cur_pos`, `ctx_len` | 2 x 16 | |
| descriptor shadow, live | ~512 | 64-byte header |
| descriptor shadow, prefetch bank | ~512 | the double buffer of §5.2 |
| base array shadow, 33 x 64 b, double banked | 4,224 | this dominates |
| job epoch counter and echoes | 4 + 5 x 4 | §5.2 |
| region locks, 14 x 2 b | 28 | |
| region fill pointers, 14 x 14 b | 196 | |
| exponent capture, 16 segments x 16 b, plus 16 valid bits | 272 | |
| per-unit `done_seen` sticky, 5 units | 5 | §5.3 |
| per-port outstanding counters, 30 x 2 x 8 b | 480 | §3.4 |
| grant register and `grant_taken` | ~8 | |
| watchdog counter | 32 | |
| error latch, `err_code`, `ERR_INFO` | ~32 | |
| sticky logs: SAT_LOG, QUAL_LOG, RESCALE_MAX | ~96 | |
| **subtotal** | **~6,450 FF** | plus pipeline and mux registers |

D §12's ~15-25K FF ESTIMATE covers this with room; the named state is ~6.5K and
the rest is datapath pipelining in D-vec and the region write decoders.

---

## 5. Entity and port sketch, with stallability stated

The skeleton entity is `rtl/seq_top_skel.vhd`. It analyzes under
`ghdl -a --std=08 -frelaxed` with packages in the order `fixed_luts_pkg`,
`fixed_pkg`, `util_pkg`. It has not been simulated and implements no behaviour
beyond a state machine outline; the hazard mechanisms of §5.2 and §5.3 are
present as declared registers and commented obligations, not as verified logic.

### 5.1 Handshake and stallability, per interface

"Can the producer be stalled" is the question D §4.5's E-into-residual
optimisation did not ask, and it is the question the `RMS_LANES` result makes
load-bearing: where a producer cannot be stalled, throughput margin is a
correctness property and does not appear in any synthesis report.

| interface | direction | discipline | producer stallable? | if not, what bounds service time |
|---|---|---|---|---|
| host `go` | in | W1P register, D latches | n/a, host polls `busy` | |
| host X-write aperture | in | AXI-Lite writes to region X | yes, AXI-Lite backpressures | |
| `<unit>_start` | out | one-cycle pulse, qualified by the shadow registers being stable | n/a | |
| `<unit>_done` | in | **level, held until `<unit>_ack`** (REQUIRED, §5.3) | n/a | if a unit cannot be changed, D's sticky `done_seen` is the compensating mechanism and must be the sole sampler |
| `<unit>_err`, `sat_event`, `rope_sat` | in | sticky in the unit, sampled at `done` | n/a | |
| A `x_rbaddr` / `x_rdata` | out/in | combinational address, **1-cycle registered read**, no ready (A §7.8) | **NO** | the region read port must return a BLOCK-wide word every cycle unconditionally. Single-reader by the lock; no refresh, no arbitration, no second master. This is a design obligation on the region banks, not a schedule property |
| A `y_we` / `y_addr` / `y_data` / `y_exp` | in | free-running write strobe, **no ready** | **NO** | the region write port must accept one element per cycle unconditionally. Single-writer by the lock. A lost strobe is a silently wrong activation |
| A `y` in partial mode into E `p_we` | in -> out | free-running, no ready | **NO** | E's receive buffer must absorb 5,120 s48 words at A's emit rate. E §2.3 sizes 40 KB per peer, which is exactly one collective, so the margin is zero by construction and depends on E draining between collectives |
| A `y` in raw mode into `sampler_stream` | in -> out | free-running (`logit_valid` semantics, A §5) | **NO** | sampler is a 1-element/cycle argmax fold; it keeps up by construction |
| B/C region read ports | out/in | 1-cycle registered read, BLOCK*16 shape (O25) | **NO** | same obligation as A's x port |
| B `ssm_norm` bus and its exponent | out | **held from `start` until `w_taken`** (§5.2) | n/a | D must not advance the block counter before `w_taken`; see hazard A2 |
| B six input exponents, C three | out | job-scoped shadow registers, written at issue only | n/a | frozen by the region lock, see hazard A3 |
| C `cur_pos` / `ctx_len` | out | job-scoped shadow, latched at C's issue | n/a | |
| E `o_we` / `o_addr` / `o_data` | in | free-running, **no ready in E §2** | **NO** | **unresolved.** See hazard B7. Either E gains a ready, or D-vec residual pass 1 is proven to consume one element per cycle at E's emit rate with no arbitration, or the pipelining is dropped and ER is used as a landing buffer |
| HBM AXI, A dedicated ports | pass-through | full AXI, backpressured | yes | |
| HBM AXI, B/C shared ports through D's grant mux | pass-through | full AXI, backpressured; grant changes only on outstanding == 0 | yes | but the grant register itself is read combinationally for the whole job, see hazard A5 |
| URAM descriptor and constant reads | out/in | registered read, D is the only master | n/a | |

Five interfaces on that list cannot be stalled. Four of them are safe by a
structural argument (single reader, single writer, no arbitration, no refresh).
**The fifth, E into D-vec, is safe by nothing.**

### 5.2 Defect class (a): a value read for the duration of a job

The `gdn_emit_chain` defect: `w_mant` was a single unlatched port read
combinationally once per head for all 24 heads, while blocks overlap by design,
so head 23 of every block used block b+1's weights.
(`2026-08-27_gdn-emit-chain-w-latch.md`.)

D drives 64 blocks and ~1,106 steps per token. Every value D presents that a
consumer reads for longer than one cycle is an instance. Enumerated:

| # | value | consumer reads it for | hazard | mechanism |
|---|---|---|---|---|
| A1 | descriptor header and base array | the whole job | D §4.5 prefetches step n+1's descriptor during step n. If the prefetch writes the live register set, the running unit sees the next job's `n_rows`, `w_exp`, bases | **two-bank shadow.** Prefetch writes bank `^live`; the banks swap at exactly one instant, the `start` pulse. The URAM read port never drives a unit port directly |
| A2 | B's `ssm_norm` mantissas and exponent | the whole GDN block, latched internally at head 0 | this is the original defect, one level up. D's URAM address is `ordinal`-derived; advancing the block counter changes it | **D holds the bus and does not advance until `w_taken`.** `w_taken` already exists on `gdn_emit_chain` and D must consume it. The URAM address is a registered copy latched at job issue, never the live block counter |
| A3 | the six B / three C input exponents | the whole job | **NEW FINDING.** D §5.3's lock freezes a region's DATA in HELD. D §5.4 captures exponents at the producer's `done`. Nothing states that a HELD region's exponent register is also frozen, so a later producer targeting that region's exponent slot can overwrite it mid-consumer-job. The exponent has a longer live window than the lock protects | **the exponent capture register is part of the locked object.** A write to the exponent of a HELD region is dropped and raises `ERR_LOCK`, identically to a data write. One extra term in an existing check |
| A4 | `cur_pos`, `ctx_len` to C | the whole C job | `cur_pos` increments at `END_TOKEN`, which is after C's `done`, so the schedule makes it safe. That is precisely the "safe by convention, not observable" argument the w-latch document rejects | **latch at C's issue** into the job shadow. Costs 32 FF and removes the schedule dependence |
| A5 | the port grant register | the whole job, read combinationally by the AXI mux | changing it mid-job re-routes R beats to the wrong master | D §8.2's outstanding-zero rule, **plus** a `grant_taken` acknowledgement from the mux so the safe instant is observable rather than inferred |
| A6 | `n_rows`, `out_shift`, captured `y_exp` to E | the whole collective | same shape as A1 | same two-bank shadow |
| A7 | norm-weight vector base to D-vec | a whole two-pass norm | derived from a block counter | same registered-copy-at-issue rule |

**The normative rule that covers all seven, and any future eighth:**

> No D output that a consumer reads for longer than one cycle may be driven by
> a live counter, a live memory read port, or a combinational function of
> either. Every such output is driven by a **job-scoped shadow register written
> at exactly one instant**, the `start` pulse. Any consumer that latches such a
> value internally must expose a `*_taken` pulse, and D must not change the
> value between `start` and `*_taken`.

**And the mechanism that makes a violation detectable rather than silent**,
which the w-latch document says is what was missing: a 4-bit **job epoch**.
D increments it at every issue and presents it alongside the shadow registers.
Every unit that latches a D-supplied value latches the epoch with it and echoes
it back with `done`. D compares. A mismatch means the unit latched a value from
a different job and raises `ERR_EPOCH`. Cost is 4 FF in D, 4 FF per unit, one
4-bit comparator. It converts the entire class from "invisible until the output
is wrong" into a runtime error with the failing step index in `ERR_INFO`.

This is the piece D §5.4 does not have. D §5.4 gets the capture instant right
and then relies on the schedule for everything after it.

### 5.3 Defect class (b): a `done` pulse discarded because the consumer was busy

The `gdn_head_emit` defect: `done` was a one-cycle pulse with no handshake, so
when the chain happened to be in `S_GATE`/`S_RMS`/`S_SER` the pulse was missed
and an **entire head was discarded**. The lossy path scored better on the
back-pressure metric than the fixed one.
(`2026-08-27_gdn-head-emit-done-pulse.md`.)

D's exposure is larger, because D §1 explicitly inherits the offending
convention: *"The structural lessons carried over: ... the one-cycle start/done
pulse convention"*. That sentence must be withdrawn.

| # | event | if lost | mechanism |
|---|---|---|---|
| B1 | A, B, C, E `done` into D | D waits forever, caught only by the per-job watchdog, which reports `ERR_WDOG` and names the wrong cause | **`done` is a level held until `<unit>_ack`.** Where a unit's RTL cannot be changed, D latches it into a sticky per-unit `done_seen`, cleared only by that unit's next `start`, and `done_seen` is the **sole** sampler in D. Never sample `done` in a state-conditional branch |
| B2 | `w_taken` from B's emit chain | D advances the block counter early and corrupts the next block's norm: hazard A2 fires | same sticky capture. Note the w-latch document's own open item: `w_taken` has no back-pressure, so an assertion that w is stable from issue to `w_taken` is the only check, and it does not exist |
| B3 | `err` from any unit | error is missed and the token completes on garbage | `err` is sticky in the unit (A §7.6) and sampled at `done`. Safe **only because** `done` is now a level; with a pulse, missing `done` also misses `err` |
| B4 | `sat_event`, `rope_sat`, `rescale_max` | a quality log entry is lost | sticky in the unit, max-reduced in D. Not fatal |
| B5 | `token_done` to the host | host hangs | W1C status bit, not a pulse. Already correct in D §9.3 |
| B6 | A's `y_we` strobes into a region | a silently wrong activation element | the write port cannot stall (§5.1). Structural: one writer, no arbitration. This is an obligation on the region bank RTL |
| B7 | **E's `o_we` beats into D-vec residual pass 1** | **a silently wrong residual element, and the whole point of the optimisation was to avoid the landing buffer that would have caught it** | **UNRESOLVED.** E §2 gives `o_we/o_addr/o_data` no ready. D §4.5 pipelines it straight into D-vec. Three exits: (i) E gains a ready, (ii) D-vec pass 1 is proven to consume one element per cycle with no arbitration against the region ports, (iii) drop the pipelining, land in ER, pay ~5,120 cycles per collective = 655,360 cycles/token = **2.18 ms** (**2.756 ms at the MEASURED 237.812 MHz**, DERIVED 2026-08-27; cycles unchanged), which is 6% of the token (**6.1 to 6.9% of the 40.21-45.03 ms token at the measured clock**) and not affordable. Exit (i) or (ii). This must be settled before D-vec RTL |
| B8 | D's `start` pulse into a unit that is not listening | the unit never runs; watchdog fires | `start` is qualified by the unit's `ready`/idle, and D asserts it until accepted. Symmetric with B1 |

**The generalisable rule, stated the way the head-emit document states it:**

> A `done` that is a pulse is a contract that the consumer is always listening.
> D is a 1,106-step state machine with error handling, grant switching and
> watchdogs; it is provably not always listening. Therefore every completion
> D consumes is a level with an acknowledgement, and every completion D
> produces is a level with an acknowledgement.

**And the metric warning, which is the part that generalises furthest:** a
silently lossy path reports a cleaner number than a correct one. If D's
bring-up testbench reports "zero stalls at the grant switch" or "zero refused
region writes", that is a question, not a result. The corresponding assertion
must be that the *count of completed steps equals 1,106*, which is the counting
argument that named the head-emit cause and that no throughput metric would
have.

### 5.4 What the stub testbench must assert

Extending D §14 item 1 with the two classes above:

- a stub unit that changes its `y_exp` after `done` must not be observed;
- a stub unit that returns a stale **epoch** must raise `ERR_EPOCH`;
- a stub unit that holds `done` for 1 cycle only, while D is in its error or
  grant-switch state, must still be seen (this is the B1 regression test and it
  must be run against the *sticky* path, not only the acked path);
- a stub that changes `w` before `w_taken` must raise an assertion;
- the completed-step counter must equal 1,106 at `token_done`, and this
  assertion must be present from the first run, not added after a hang;
- a heartbeat generic, per the head-emit document's `HEARTBEAT_US`, so a
  non-terminating run is distinguishable from a slow one without a second run.

---

## 6. Skeleton RTL

`rtl/seq_top_skel.vhd`, entity `seq_top_skel`. Verified only that it analyzes:

```
ghdl -a --std=08 -frelaxed --workdir=<scratchpad> \
  rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd rtl/seq_top_skel.vhd
```

What it contains: the port list of §5.1 with the stallability verdicts in
comments; the two-bank descriptor shadow of hazard A1; the job epoch of §5.2;
the sticky `done_seen` capture of hazard B1; the `w_taken` gate of hazard A2;
the region lock array; the exponent capture array with the A3 freeze; the
outstanding-transaction counters of §3.4; and a ten-state FSM outline.

What it does NOT contain, deliberately: descriptor decode, region address
generation, the AXI grant mux, D-vec, and every arithmetic operation. It is a
skeleton for review of the interfaces, and `ghdl -a` proves only that it is
well-formed VHDL. Note the GHDL here is the **mcode** backend, where `ghdl -e`
produces no binary and silently succeeds, so an elaboration step would prove
nothing either.

---

## 7. What I could not determine

Required section. Nothing below is rhetorical hedging; each item changes a
number in this document.

1. **Why D §11 implies A at ~30.5 ms when the tile arithmetic gives 23.18 ms
   array-limited and 25.21 ms feed-limited.** D §11's row is "A jobs (weights,
   7.57 GB/card) + C ~35.1 ms" sourced to A §15.4c's "balanced ~34 ms", which is
   itself a two-variable optimisation whose per-term breakdown is not printed
   anywhere. The 17 to 24% gap on the largest term in the token is unresolved.
   It could be per-job overheads, K padding, the `ROWS_IF = 58` vs the 276 MHz
   the 48-row point closes at, or an error in either derivation. **This is the
   single most consequential unknown in the document**, because everything in
   §1.6 and §3 rests on it.
   > **2026-08-27: partly answered, and the answer is "the clock, but only the
   > range".** The two derivations were at different clocks -- D §11's A term
   > descends from A §15.4c's 276 MHz anchors, the tile arithmetic here is at
   > 300 MHz, and the feed-limited figure is clock-invariant. Normalised, the
   > 17-to-24% *range* collapses to a single **~16%**. The ~16% *gap* remains
   > unresolved and is still the most consequential unknown here.
   > `docs/2026-08-27_budgets-at-the-measured-clock.md` section 4.
2. **Whether ACLK can reach 450 MHz.** The entire §3.3 fork hangs on it. What
   is MEASURED is that 350 MHz misses by 0.395 to 0.467 ns with the CDC bugs
   fixed, and that 450 MHz "needs real pipelining of the HBM-to-fabric paths"
   that does not exist. Nobody has attempted it.
   > **2026-08-27: the §3.3 fork no longer hangs on it, because §3.3's method
   > was wrong.** Port count is a width divisor, not a bandwidth quotient, so a
   > faster ACLK does not reduce it -- it only raises the lanes-per-port ratio
   > `K = floor(f_ACLK / f_core)`, which is 1 at any ACLK below twice the core
   > clock. A 450 MHz ACLK against a 237.8 MHz core is still `K = 1` and still
   > 33 ports at `ROWS_IF = 58`. **What ACLK >= 2 x f_core would buy is real**
   > (it would halve the port count and let `ROWS_IF = 64` fit in 18 ports), and
   > it remains unmeasured and unattempted. That is the question worth keeping;
   > the fork it was framed as is void.
3. **The die-wide BRAM sum.** D is ~86 flat, B ~50-60, C ~43, E ~10 at N=2
   (E §2.3 prices 280 KB as ~70 BRAM36 at N=8, so 40 KB scales to ~10), A's
   weight-stream FIFOs unquantified (~30 ports x 8 KB = 240 KB = ~54 RAMB36 if
   A §7.7's per-port budget carries to HBM, which is an ESTIMATE). Nothing has
   added them. The direction review flags the same gap.
4. **Whether the region banks can actually deliver an unconditional
   1-element-per-cycle write and a 1-cycle 512-bit read simultaneously** in the
   striped geometry, at the real clock, once the read mux across three source
   regions is in the path. D §5.2 asserts the mux "adds combinational select
   depth but no pipeline stage". That is exactly the kind of claim the timing
   rule in this project exists to catch, and no synthesis has tested it. If it
   needs a pipeline stage, O25's 1-cycle contract breaks and A's x-port timing
   changes.
5. **B's real per-block cost.** §1.3 gives a range of 12,288 to 35,942 cycles,
   a factor of 2.9. It resolves only when B's block sequencer, the F2 double
   banking and the elastic state feed exist. The direction review bounds the
   token-level damage at ~9%, which is why this is listed fourth rather than
   first.
6. **Whether the vocabulary is 248,320.** D §3.3's 124,160 rows per card at N=2
   implies it. The shipped Qwen3 tokenizer is 151,936. Nothing in any spec
   derives the number, and lm_head is 342,560 cycles per token, 1.14 ms, so a
   1.6x error there is 0.4 ms. Not checked against the GGUF here.
7. **HBM read latency on this card**, which sets the §3.4 grant-drain cost. The
   ~100-cycle figure is an ESTIMATE with no measurement behind it. `hbm_tg` has
   no write channel at all, so the write-side drain is doubly unmeasured.
8. **Whether E can be given a ready** (hazard B7). This is a question for E's
   owner and is the one item on this list that blocks D-vec RTL rather than
   merely making a number uncertain.
9. **D-vec's numeric contract**, unchanged from D §15 item 1: the rounding-site
   table, the residual exponent chain, the swiglu Q-format and the C reference
   do not exist. Nothing here advances it.
10. **Whether the 1,106-step count survives.** It assumes the two-norm pre-norm
    block that D §2.2-I verified against the shipped 27B GGUF. That verification
    is recorded and this document did not repeat it.
