# Subsystem B gets a top level: the silu DSP question, and three seams that only wiring could find

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. New files only:
`rtl/gdn_block.vhd`, `sim/tb_gdn_block.vhd`, `sim/run_gdn_block.sh`.
No existing RTL was modified.
**Tools:** GHDL 1.0.0 mcode, `ghdl -r` direct, `--stop-time` on every run.
**Vivado was NOT run.** Every DSP number below is a COUNT read off an
instantiation multiplied by a previously measured per-lane figure, not a
utilisation report.

---

## The question

Section 3.6 of the GDN design spec books `silu` at **8 DSP (4 lanes, measured)**.
The assembled `gdn_emit_chain` does not close timing at 4 lanes, and its
shipping point is **16 lanes = 32 DSP**. The spec audit could not tell whether
those are the same instance, and said so in its own words:

> This document cannot tell which, because no B top level exists to say how
> many `gdn_silu` instances there are -- `gdn_emit_chain` is the only unit in B
> that instantiates other B units. OPEN, and it is a genuine contradiction
> rather than a stale number.

`docs/debugging/2026-08-27_B-interface-audit.md` bounds five of its own eight
findings the same way: they are contracts between units that are not wired
together, so their reachability is a statement about prose.

---

## The answer

**A B block contains TWO `gdn_silu` instances, at different widths.** Read off
`rtl/gdn_block.vhd`:

| instance | site | lanes | DSP |
|---|---|---|---|
| `u_silu_conv` | `silu(conv_out)`, spec 1.4(e)/(g) | `CONV_LANES` = 4 | **8** |
| `u_emit/u_silu` (inside `gdn_emit_chain`) | `silu(z_h)`, the output gate | `SILU_LANES` = 16 | **32** |
| | | | **40 total** |

`gdn_silu` is exactly 2 DSP per lane, measured, `sim/gdn_silu_sweep.csv`:

```
lanes,dsp,lut,ff,bram,wns_ns,fmax_mhz
1,2,1336,112,0.5,0.448,391.84952978056424
4,8,4818,419,2.0,0.448,391.84952978056424
16,32,19122,1655,8.0,0.448,391.84952978056424
```

**So B's aux row moves +32 DSP, not +24.** The audit's optimistic branch
assumed the two might be one instance, in which case only the 16-lane gate is
owed and the move is 32 - 8 = +24. They are not one instance, so both are
owed: 40 - 8 = **+32**.

Which of the two the spec's 8 DSP actually prices is now decidable, and the
answer is the conv-path one. The aux row's silu is the **4-lane**
`micro_silu_narrow` figure; `u_silu_conv` is a 4-lane instance and
`u_emit/u_silu` is not, so the booked row is right for the conv activation and
the **gate is entirely unbooked**. Carrying it through the spec's own line:

```
A 1,914 + C 434 + B 202 + D 28 = 2,578 of 2,880 = 89.5%   as booked
A 1,914 + C 434 + B 234 + D 28 = 2,610 of 2,880 = 90.6%   with both silus
```

**They cannot be shared as built, and the reason is structural rather than
schedular.** `gdn_conv` implements 1.4(e) literally -- "depthwise, kernel 4, no
bias, **no fused activation**" -- so `silu(conv_out)` has no home except the
top level. The gate silu is instantiated *inside* `gdn_emit_chain`. Sharing
one instance would require hoisting the gate out of that unit and muxing two
streams of different widths (4 and 16) through it, which forces the conv path
to 16 lanes and a rate adapter, and saves 8 DSP. It is not taken here.

**The two sites are also different sizes in the algorithm, which is why one
generic cannot serve both.** `silu(conv_out)` runs over the conv width --
q 2,048 + k 2,048 + v 4,096 = **8,192 channels per layer at 9B** -- and
`silu(z_h)` over the value width, **4,096**. The spec's own budget derives
exactly this split (8,192 per layer at 27B/card from 5,120 + 3,072); it simply
never said they were two pieces of hardware.

---

## What was wired, and where the boundary is

`rtl/gdn_block.vhd` instantiates **seven** units for one GDN layer, one token:

```
gdn_exp_capture -> gdn_conv (x3 segments) -> gdn_silu -> +- l2norm_rs (q, k)
                                                         |
gdn_scalar (per value head) --------------------------> gdn_recur_pipe
                                                         |
                                                        gdn_emit_chain
                                                         (gdn_head_emit ->
                                                          rmsnorm_bf ->
                                                          gdn_silu -> gdn_y_emit)
```

Three things stay outside, and each is a memory rather than a computation:

* the recurrent state (`DIM*DIM*VAL_HEADS` int16 per layer, 2 MiB at 9B,
  DDR/HBM resident per section 2.4) -- a one-cycle synchronous read port and a
  write port;
* the conv taps (`[3 stored columns | this token's qkv]` and the quantized
  `ssm_conv1d`) -- same contract;
* A's activations and the packer's scalars (`al`/`dt`/`a`/`b`, `ssm_norm`, `z`).

`gdn_recur` (the sequential twin of `gdn_recur_pipe`) and `rmsnorm_rs` are
deliberately not instantiated: both are superseded on the shipping path.

The phases run **strictly sequentially** -- conv, silu, L2, scalars, sweep --
with only the sweep and the emit chain concurrent. That is not the fastest
schedule and is not meant to be. Every extra concurrency is a new seam, and
the one concurrency kept is the one where the known class-3 defect lives.

---

## The procedure

The units are already bit-exact individually against double-oracled C
references. Re-checking arithmetic would prove nothing. The property under
test is the one that would have caught all four of this week's defects:

> **The block's output must be bit-identical under every producer skew.**

`sim/tb_gdn_block.vhd` drives **five independent producers**, each from its own
process with its own skew generic, and dumps the y stream, the per-token
`y_exp`, the **final recurrent state memory** and the **final state-exponent
table** to a file. `sim/run_gdn_block.sh` runs the matrix and diffs every dump
against the reference run -- the one in which every producer runs maximally
ahead and nothing moves after it is taken, i.e. the configuration a naive
testbench would report clean.

| generic | what it controls | what it isolates |
|---|---|---|
| `Z_DELAY` | idle cycles between z heads | audit B-2's masked window; also whether a slow gate starves the column path |
| `W_MOVE` | scramble `ssm_norm` after `w_taken` | the `w_held` latch (the 2026-08-27 fix) |
| `SC_MOVE` | scramble `al`/`dt`/`a`/`b` after `sc_taken` | audit B-4: `gdn_scalar` latches nothing and reads `b_m` at the END of a ~30-state FSM |
| `CW_MOVE` | scramble `cv_cw_exp` after `cv_taken` | audit B-3b: `gdn_conv` reads `cw_exp` at `S_FIN` |
| `CAP_BUSY` | free-running captures against another layer | audit B-12: `gdn_exp_capture` drops a colliding read silently |
| `ISSUE_GAP` | idle cycles per state column | widens the column arrival period without changing the memory word shape |
| `HEAD_GAP` | idle cycles per value head | widens the arrival period by exactly ONE cycle per step |

The state memory is real: read and written across the run, carried between
tokens, and part of the comparison. A one-column misalignment in the
write-back counters shows up there and nowhere else.

---

## The evidence

### Cross-skew comparison, `KEY_HEADS=2 VAL_HEADS=4 DIM=32`, 2 tokens

```
=== reference: every producer maximally ahead ===
  [ref] tb_gdn_block: PASS, 256 elements, dump in ref.txt
=== diffs against the reference ===
  z1:      identical to ref
  z7:      identical to ref
  z31:     identical to ref
  wmove:   identical to ref
  scmove:  identical to ref
  cwmove:  identical to ref
  capbusy: identical to ref
  all:     identical to ref
  fastall: identical to fastref
```

`all` is `Z_DELAY=5 W_MOVE SC_MOVE CW_MOVE CAP_BUSY` together.

### The emit chain's per-head deadline, MEASURED

`gdn_recur_pipe` has no ready input, so the column arrival period is a
**correctness** parameter, not a performance one. `HEAD_GAP` moves it one
cycle at a time. At the shipping datapath shape
(`DIM=128 SILU_LANES=16 RMS_LANES=4`, `RECUR_LANES=64` so the base period is
`DIM * DIM/RECUR_LANES = 256`):

```
arrival 256 cycles/head: COLUMN DROPPED
arrival 365 cycles/head: COLUMN DROPPED
arrival 366 cycles/head: COLUMN DROPPED
arrival 367 cycles/head: no column refused
arrival 512 cycles/head: no column refused
```

**The deadline is 367 cycles per head.** At the shipping `RECUR_LANES=32` the
period is 512, so the margin is **145 cycles, 28%**. At `RECUR_LANES=64` the
period is 256 and the shortfall is **111 cycles per head**.

The same experiment at the small shape (`DIM=32 SILU_LANES=8 RMS_LANES=4`,
base period 128) pins the deadline at **145**:

```
arrival 128: DROP    arrival 144: DROP
arrival 133: DROP    arrival 145: PASS
arrival 142: DROP    arrival 148: PASS
arrival 143: DROP    arrival 160: PASS
```

**This is a rate limit, not a burst limit, and that corrects the audit.**
`docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md` prescribes "an elastic
buffer in front of the chain" for the `LANES = 64` case. A buffer absorbs a
transient. Here the chain is 111 cycles per head slower than arrival *in
steady state*, so the backlog grows without bound and **no finite buffer fixes
it**. The fix has to make the chain faster (larger `RMS_LANES`, which then runs
into audit B-1's 257-cycle floor) or give `gdn_head_emit` a double-buffered
OUTPUT register so its next reduce need not wait for `o_ack`.

**Summing the units' documented latencies over-estimates the deadline, and by
a shape-dependent amount.** The sum is
`head_emit reduce + 1 (S_IDLE) + SI_BEATS + rmsnorm_bf`:

| shape | sum | measured | over-estimate |
|---|---|---|---|
| `DIM=128 SILU_LANES=16 RMS_LANES=4` | 268 + 1 + 8 + 142 = 419 | **367** | 52 |
| `DIM=32 SILU_LANES=8 RMS_LANES=4` | 76 + 1 + 4 + 70 = 151 | **145** | 6 |

The stages partially overlap and the overlap does not scale with either term,
so **do not use the sum as the budget**. It is conservative at both points
measured, and there is no argument that it stays conservative elsewhere.

**`gdn_emit_chain`'s own `CONSUME_BUDGET` watchdog does not catch this.** That
constant is 780 and guards the *result register* (head h's `o_mant` must be
consumed before head h+1's reduce overwrites it). The binding constraint is
the *column bank*: `gdn_head_emit` cannot start head h+1's reduce until head
h's result is acked, so head h+2's columns arrive at a full double buffer. Two
different deadlines, and only the looser one was written down.

---

## Measured and REJECTED, and defects found in the new top level

### Found: `cv_seg` was published AFTER `cv_cw_exp` was sampled -- do not reintroduce

The first version set `cv_seg_i <= seg` in `P_CVWAIT`, which runs *after* the
`cv_cw_exp` latch in `P_EXP`. The producer was therefore asked for a segment's
conv-weight exponent while the port still named the **previous** segment.
Class 2 of the audit exactly: an output that says what a read refers to,
published after the read.

**It was invisible until the testbench made `cv_cw_exp` depend on `cv_seg`.**
With a constant exponent every run agrees. Probe output from the broken
version, three segments per token:

```
PROBE cv_taken seg=0 cw_on_port=12  dirty=false
PROBE cv_taken seg=0 cw_on_port=-99 dirty=true
PROBE cv_taken seg=1 cw_on_port=-99 dirty=true
```

Three `cv_taken` pulses reporting segments 0, 0, 1 for segments q, k, v.
Fixed by publishing `cv_seg_i` with `ec_rd_seg`, several cycles ahead of the
latch. **Lesson, and it generalises: a testbench whose producer ignores the
address the DUT publishes cannot test the address.**

### Found: the scalar port gave its producer ZERO cycles of read latency

`P_SCADR` presented `sc_head` and `P_SCLAT` sampled `al`/`dt`/`a`/`b` on the
very next edge -- a combinational read contract, while the conv-tap port and
the state port in the same file both allow one cycle. A register file or a
BRAM cannot meet it, and a producer one cycle late hands over the **previous**
head's scalars: every head but the first is decayed and gated wrong.

Caught by `SC_MOVE` with a *registered* producer model. The first diff:

```
scmove: DIFFERS from ref
35,61c35,61
< y 32 -1722
< y 33 -330
...
```

y 0..31 (head 0) correct, y 32 onward wrong -- the exact head-boundary
signature. Fixed with a `P_SCRD` state, costing one cycle per value head
(32 cycles per layer at 9B, against a 393,216-cycle sweep).

**Do not "simplify" this back to two states.** The saving is 0.008% and the
failure mode is silent.

### Found: `gdn_conv` publishes `e_seg` AFTER the data it describes

`e_seg` and `sh_seg` are assigned in `S_FIN`, which is two states after pass B
has finished streaming `o_data`. `gdn_silu` needs the segment exponent to form
its Q12 argument for the **first** beat. So the conv output stream **cannot**
be piped straight into the gate: a straight-through connection silus every
beat of segment s against segment s-1's exponent, which is a per-segment
power-of-two error with a legal-looking `e_seg` and no error flag -- the same
signature as the `tvalid` skew defect one seam upstream.

`gdn_block` therefore buffers each segment, waits for `o_done`, and makes a
**second pass** over the buffer through silu. Cost at 9B and `CONV_LANES=4`:
2,048 extra cycles per layer against a 16,384-cycle sweep.

**Section 3.6's schedule assumes silu overlaps the conv. It cannot, as
`gdn_conv` is built.** The unit would need to publish `e_seg` at `S_SH`, where
`shq`, `e_ref` and `cw_r` are all already known, i.e. before pass B streams.
That is a one-line change to a file this work was not allowed to touch, and it
is the single cheapest schedule win available in B.

### Rejected: BRAM-shaped staging for q, k, k_n, q_s

`l2norm_rs` takes `x_mant` as one `N*16` parallel bus; `gdn_recur_pipe` takes
`k_n`/`q_s` the same way; `rmsnorm_bf` takes `x_mant` the same way. A block RAM
cannot present 2,048 bits in a cycle, so these are **flat registers** in this
top level: `(2 + 2)*KEY_HEADS*DIM*16 + VAL_HEADS*DIM*16 = 196,608 FF` at 9B.
Section 2.6 books q/k/v as BRAM36 rows; **at these interfaces they are not**.

A BRAM-shaped variant is possible -- keep the segment buffers beat-wide and
assemble one head into a `DIM*16` register just before each `l2norm_rs` -- and
costs one extra `DIM/CONV_LANES`-cycle pass per head. Not taken, because it
trades a counted register figure for an uncounted BRAM figure and Vivado was
not run. **This is an open area question, flagged, not answered.**

---

## Measurement traps hit

* **`ghdl -e` produces no binary on the mcode backend and silently succeeds.**
  Run `ghdl -r <entity>` directly. Already project lore; repeated because it
  cost time again.
* **`ghdl-mcode` refuses a large function return value** with
  `declaration of a too large object (1024 > --max-stack-alloc=128 KB)`, not a
  VHDL error. The testbench builds the whole initial state memory as one
  function result; `--max-stack-alloc=0` is required at `DIM=128`.
* **A plain `integer` signal cannot be connected to a constrained `integer
  range` port**: `bounds or direction of actual don't match with port`. Every
  testbench signal facing an address port must carry the DUT's own subtype.
* **`NUMERIC_STD.TO_INTEGER: metavalue detected` at @0ms** on every run. It is
  `gdn_emit_chain`'s `x_exp => to_integer(he_e_head)` evaluating before
  `gdn_head_emit` has driven anything. Benign, fires once, pre-existing.
* **The trap that nearly hid both new defects:** the first testbench drove
  `cv_cw_exp` as a constant and modelled the scalar source combinationally.
  Both defects are then unobservable. A producer that is kinder than the real
  system reports a clean result -- the same lesson the `gdn_head_emit` note
  records, now at the block level.

---

## Open, not yet answered

* **No block-level bit-exactness against a C reference.** There is no
  `ref/gdn_block_vec.c`. Everything above is a self-consistency and protocol
  result: the units are individually bit-exact, and the block's output does not
  move under skew. It is NOT a statement that the block computes the right
  numbers end to end. That reference is the obvious next piece of work.
* **Nothing was synthesized.** All DSP figures are counts times a measured
  per-lane figure. B's assembled area, LUT and Fmax are unknown.
* **The 40 DSP of silu assumes `CONV_LANES = 4`.** The generic is exposed; at
  `gdn_conv`'s own default of 8 the conv-path silu is 16 DSP and the total is
  48. 4 was chosen because it is what section 3.6 already books and because
  the schedule permits it, not because it was measured to be optimal.
* **The multi-layer and multi-card schedule is untouched.** This block runs one
  layer for one token with no overlap between layers.
* **`err_conv`, `err_g`, `err_se` are now consumed and published, but nothing
  consumes THEM.** Audit B-10 is moved up one level, not closed.
* **Audit B-1 remains unreachable but is now closer.** The `S_SER` duplicate
  needs a per-head period under ~257 cycles at `DIM=128`; the deadline measured
  here is 367, so the chain cannot currently be driven into it. Any change that
  makes the emit chain faster must re-check B-1 before it re-checks anything
  else.
* **Audit B-6, B-7, B-9 are untouched.** `w_taken`, `sc_taken` and `cv_taken`
  are all still pulses with no back-pressure, and every B output stream is
  still un-refusable.
