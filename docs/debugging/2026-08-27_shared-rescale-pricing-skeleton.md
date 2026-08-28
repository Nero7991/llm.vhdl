# Pricing the shared rescale unit, and three coincidences that made checks pass without checking

Date: 2026-08-27
Branch: `fpga`
Subsystem: C, gated attention -- site 5d, the softmax rescale multiply
Files: `rtl/attn_rescale_skel.vhd`, `ref/attn_rescale_vec.c`,
`sim/tb_attn_rescale.vhd`, and the two mutation scripts beside them
Environment: GHDL mcode, `--std=08 -frelaxed`. **No Vivado was run.**

## The question

`docs/2026-08-27_attn-lane-rescale-pricing.md` measured that taking the rescale
mode off the MAC lane halves the lane's DSP cost, 2 to 1, and left the decision
undecidable because the shared rescale unit that change implies had never been
priced:

```
  MACS x 1 DSP  -  (MACS / LANES_SERVED) x (one shared unit)  -  mux
```

**If a shared unit costs 2 DSP at `LANES_SERVED = 2`, the saving is exactly
zero.** So: can the shared unit be built in ONE DSP48E2, and is `LANES_SERVED`
really capped at 2?

## The answer

**A skeleton now exists to measure both, and its arithmetic is proved rather
than asserted.** `rtl/attn_rescale_skel.vhd` sweeps `SEQ_MULT` (single-cycle
against two-pass), `MUX_FLAT` (the flat 16-entry mux against a hierarchical one
that reuses the lane's own read mux) and `LANES_SERVED`. The file is ready for
the coordinator to synthesise; I did not run Vivado.

**It is anchored on a measurement that predates it.** C spec 2.6, measured
2026-08-23 and confirmed routed 2026-08-24, states the rescale multiply is "a
36 x 13 product that does not fit one DSP48E2 (36 > 27), so it needs 2" and
measured DSP = 2 with an independent census agreeing. `SEQ_MULT = false` is
exactly that product standing alone. **It must synthesise to 2 DSP or the
`SEQ_MULT = true` number means nothing.** The anchor is independent of
`attn_lane_skel`: it is the spec's own lane measurement, taken before either
skeleton existed.

**The hypothesis being priced is a two-pass chunk split**, which is arithmetic
NOT in the spec:

```
o = a_hi * 2^17 + a_lo         a_hi signed 19 bits, a_lo UNSIGNED 17 bits
o * f = (a_hi * f) * 2^17 + (a_lo * f)
```

Both partials are 19x14 and 18x14, each inside one 27x18 tile, with the
recombination a shift-and-add in fabric. That is deliberately the right way
round for this die: with `ROWS_IF = 48` forced, DSP is at ~75% and LUT at ~65%,
so trading DSP for LUT is worth more than it was this morning.

**The arithmetic is proved bit-exact before any number is quoted.** 24
configurations of `sim/tb_attn_rescale.vhd` PASS, 512 cases each, covering both
branches, both mux topologies, `LANES_SERVED` in {2, 4} and three stall shapes.

**What is NOT free is the schedule, and it must not be dropped from the
decision.** Two passes per accumulator means a rescale pass over
`LANES_SERVED` lanes takes `2 x LANES_SERVED x ACC_N` cycles against `ACC_N`
when the rescale is on the lane and all lanes run in parallel: **8 cycles
becomes 32 at `LANES_SERVED = 2`.** `y_valid` exposes the cadence and the
testbench asserts it, so the cost is measured rather than assumed. Whether it
is affordable is `attn_ctrl`'s question.

## The procedure that produced it

1. **Write the C reference and mutation-test it before any RTL exists.** This
   caught the oracle gap in item 3 below, at a point where there was no DUT to
   confuse it with.
2. **Find the anchor before writing the skeleton.** A pricing skeleton's only
   evidence that it prices the right thing is reproducing a known measurement.
   Reading spec 2.6 for the 2026-08-23 lane figure came first, and it decided
   what `SEQ_MULT = false` had to be.
3. **State the decomposition as an oracle, not as a comment.** ORACLE 5 asserts
   both the operand identity and the product identity; ORACLE 9 asserts both
   chunks fit a DSP48E2 port.
4. **Make the mux testable by POISONING every entry the DUT should not read.**
   Loading all entries with the same accumulator would have made a broken mux
   indistinguishable from a working one -- and the mux is half the question.
5. **Sweep the configurations that exercise different code, not just different
   timing.** The kill pattern below is what shows the four configurations are
   individually necessary.

## The evidence

### The functional matrix, all 24 PASS

`SEQ_MULT` x `MUX_FLAT` x `LANES_SERVED` in {2,4} x `EN_GAP` in {0,3,11}, 512
cases each, bit-exact against the C golden with no tolerance.

### The mutation kill pattern, and why it is stronger than the ratio

`rtl/attn_rescale_skel.vhd`: **25 of 25 killed, no survivors.** But the ratio is
the less interesting half. Each mutation dies in exactly the configurations that
exercise the code it touches, and in no others:

| mutations | killed by | what that shows |
|---|---|---|
| R1-R13, R24 (the chunk split, the phase, the cadence flag) | A B C, survive D | they touch only the two-pass path, which D does not use |
| R14 (the flat mux selects wrongly) | A B D, survives C | C uses the hierarchical mux |
| **R15, R16 (the hierarchical mux loses its lane stride)** | **C only** | **no other configuration exercises that topology at all** |
| R22 (the anchor narrows the accumulator) | D only | it is the anchor branch's own operand path |
| R17-R21, R23, R25 (rounding, operand carrier, freeze) | A B C D | shared logic |

**R15 and R16 are caught by configuration C alone.** The hierarchical mux is the
topology that could move the ratio from `MACS/2` to `MACS/8`, and without a
configuration that uses it, it would have shipped entirely unverified while the
suite still read 25 of 25.

`ref/attn_rescale_vec.c`: **12 of 15 killed.** All three survivors were read:

- **S12** (the oracle's split moves 17 to 18) is genuinely equivalent. The chunk
  identity holds for ANY split, and 18 fits the DSP ports just as well. Nothing
  pins 17 except that it is the DSP48E2's own cascade granularity. `SPLIT` was
  therefore made a **generic** rather than a constant, so the coordinator can
  sweep it if the fabric adder turns out to matter.
- **S13** (ORACLE 7's range bound widened by a bit) is a guard on a condition
  valid inputs never reach: `|o| <= 2^35` and `f <= 4096` give `|y| <= 2^35`, so
  the bound is exercised at the rail but never violated. Honest position: ORACLE
  7 licenses "no saturation logic" but its exact bound is not independently
  pinned.
- **S14** (`ACC_W` 36 to 37) is a geometry parameter; the reference is correct at
  any `ACC_W`. The testbench pins 36 by comparing the vector header against its
  own generic.

## Three coincidences, all of the same family

The coordinator's warning for tonight was that another agent found an ordering
guard passing on a numeric coincidence -- two values equal at the single index
tested. That failure mode turned up **three times** in this one unit, each time
in a different disguise, and each time it made a check pass without checking.

**1. The pipeline fill hid behind two zero goldens.** The skeleton is
free-running and centrally scheduled in the real design, so from reset it
publishes the rounded contents of its own zeroed registers until real data
arrives -- `FILL = 2` at `SEQ_MULT = false`. The first version of the testbench
discarded nothing, and the run still passed cases 0 and 1, because golden case 0
(`o = 0, f = 4096`) and case 1 (`o = 0, f = 0`) both have `y = 0`. **Two fill
zeros agreed with two golden zeros.** The mismatch only surfaced at case 2:

```
sim/tb_attn_rescale.vhd:288:@75ns:(report error): VALUE: case 2 got 0 want 123135
sim/tb_attn_rescale.vhd:288:@95ns:(report error): VALUE: case 4 got 123135 want -123103
```

`published[k] = golden[k-2]`, with the first two mismatches invisible.

**2. Fixing it exposed the same coincidence one layer down.** With the fill
discarded, `SEQ_MULT = true` could not be distinguished between "`FILL = 0`" and
"`FILL = 2`, masked by the same two zeros". Fixed at the source: the C reference
now offsets its shape assignment by two so the `o = 0` cases do not land at 0
and 1, and a coverage assertion **fails** if `y[0]` or `y[1]` is zero, with the
reason stated -- a consumer's pipeline flushes zeros, so the leading golden must
be distinguishable from a zeroed pipeline. `FILL` was then established by
**direct observation** of the published stream, not by argument: 2 at
`SEQ_MULT = false`, 0 at true.

**3. My own reasoning about `FILL` was wrong and I nearly acted on it.** I read
a truncated error log, concluded the first published value had been accepted as
a zero, and reasoned my way to `FILL = 1`. Instrumenting the stream showed
`PUB[0] = golden[0]` exactly. **The reasoning had already been wrong once in
this session; the instrument was two minutes and settled it.**

## Measured and REJECTED -- do not retry

- **Loading every accumulator entry with the same value.** It is the obvious way
  to drive the read mux without the testbench knowing the DUT's select
  sequence, and it makes the mux completely untestable: every entry returns the
  right answer. That would have silently voided R14, R15 and R16 -- the entire
  second question this skeleton exists to answer. Poison every entry, place the
  wanted value at exactly the one the DUT should read.
- **Asserting `y_valid` is LOW on frozen cycles.** It looked like the obvious
  freeze check and it failed on **1,530 cycles of entirely correct behaviour**:
  a frozen register HOLDS a raised valid. The check was testing the opposite of
  the requirement. What must be true is that nothing CHANGES, so `en` is sampled
  alongside the outputs and compared on the edge whose update that same `en`
  gated.
- **Deriving the pass phase from the counter's parity at the consuming stage.**
  Correct only if the pipeline depth is exactly right, and silently wrong
  otherwise. The phase is CARRIED alongside the data instead -- the same pattern
  `attn_twiddle` and `attn_rope` use -- and mutations R9, R10 and R11 all die on
  it.
- **Widening ORACLE 1's tolerance instead of using exact double.** Never needed:
  `|o*f| <= 2^47 < 2^53`, so binary64 holds the product exactly and the oracle
  is an exact equality against genuinely independent machinery. A transcendental
  would have needed a derived bound; this does not, and taking one would have
  been slack for nothing.
- **Treating the DSP saving as `MACS x 1`.** Still wrong, still for the reason
  the earlier write-up gave, and now with a second term: the schedule. A
  decision made on DSP alone that quadruples the rescale pass latency is not a
  decision.

## Measurement traps hit, including my own

- **`to_integer` on a 36-bit `signed` overflows VHDL's 32-bit integer and kills
  the run inside the `report` statement itself**, so a diagnostic printer
  destroyed the diagnosis. The error surfaces as a bare
  `ghdl-mcode:error: overflow detected` naming a process, not the line. Print
  wide values as hex.
- **Reading a truncated log.** `head -2` cut off the error that would have
  contradicted my conclusion, and I built a theory on what remained. See
  coincidence 3.
- **A conditional expression is not legal in a VHDL constant declaration.**
  `constant PASSES : integer := 2 when SEQ_MULT else 1;` does not analyse; a
  function does.
- **`ghdl -a` of the entity without re-analysing the testbench** leaves the
  architecture obsolete and `ghdl -r` reports `is obsoleted by entity` rather
  than running -- a build-order failure that reads as a run failure. Third time
  this has cost time; it is worth a habit, not a note.
- **The skeleton's own first draft advanced the entry counter every cycle**, so
  the two passes would have read DIFFERENT accumulators and the file would have
  priced a structure that computes nothing. Caught by bit-exact simulation. This
  is the argument for giving a pricing skeleton a functional testbench whenever
  its arithmetic is new -- a digest alone would have folded nothing and reported
  a perfectly plausible 1 DSP.

## Open, not yet answered

- **Every DSP figure in this file is a HYPOTHESIS, not a measurement.** No
  Vivado was run -- the workstation is building the FK33 bitstream tonight. The
  derivation says `SEQ_MULT = false` is 2 tiles (36 > 27) and `true` is 1 (19x14
  and 18x14 both inside 27x18), but operand widths predicting a tile count is
  exactly what the lane skeleton existed to CHECK rather than assume, and the
  spec's own measured figure for identical rope arithmetic came out at twice the
  derived number elsewhere in C. The sweep is the deliverable; the numbers are
  not mine to state.
- **No Fmax claim is made.** Both lane branches already clear the binding clock
  by over 170 MHz at the real voltage, so timing is not a term in this decision,
  and a figure taken at 0.85 V would be misleading anyway
  (`docs/debugging/2026-08-27_tuning-at-the-wrong-voltage.md`).
- **Whether the lane's own `ACC_N:1` read mux is genuinely reusable during a
  rescale pass.** `MUX_FLAT = false` assumes it is, on the grounds that spec 2.6
  puts that mux on the routed critical path regardless and that the lane is idle
  during the pass. If it is not reusable, the flat number is the one that counts
  and the cap of 2 stands.
- **The write-back path to the lane files** is not modelled. It is a demux of
  enables rather than of data and should be small, but it is not zero.
- **Whether the "at most 2 lanes" bound survives at all.** It comes from spec
  2.6's 16-entry knee, which only binds under `MUX_FLAT = true`. The sweep over
  `LANES_SERVED` in {2, 4, 8} is what answers it.
