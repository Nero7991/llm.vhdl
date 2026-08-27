# attn_softmax: `resize` on a `signed` deleted the top code point, and only the grid-aligned shape saw it

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. New files, never committed with the
defect present. GHDL 1.0.0 mcode backend, `ghdl -r` direct, no `ghdl -e`.
**Unit:** `rtl/attn_softmax.vhd`, subsystem C step 7, the online softmax for one
query head, at `P_W = 32`, `Q = 12`, `ROM_N = 256`, `E_W = 13`, `S_W = 26`.

**This is the SECOND occurrence of the same `numeric_std` trap in this
subsystem, one unit apart.** The first is
`docs/debugging/2026-08-27_attn-kv-quant-abs-resize.md`. Read that one too; the
shapes differ but the cause is one sentence long and identical.

## The question

First run of `sim/tb_attn_softmax.vhd` against `ref/attn_softmax_vec.c`,
`ACK_LAG = 4`, `RS_ACK_LAG = 3`, 44 heads. Two heads of 44 failed, and both
failed on **every** position with the same value:

```
case 10 pos 0: e_p got 0 want 4096  (score -16896)
case 10 pos 1: e_p got 0 want 4096  (score -16896)
...
case 10: s got 0 want 98304
case 15 pos 0: e_p got 0 want 4096  (score 4096)
```

The other 42 heads -- 1,008 weights, every rescale factor, every denominator --
were bit-exact. Nothing was out of range and no flag was raised.

## The answer

`numeric_std`'s `resize` on a `signed` keeps the SIGN bit and drops the top
MAGNITUDE bit. The cone's offset stage was written as

```vhdl
x3_off <= unsigned(resize(x2_z + OFF_MID, OFF_W));   -- OFF_W = 17.  THE DEFECT.
```

`OFF_MID` is `16 * 2^Q = 65536` and `x2_z` is the clamped `z`, so the sum lies
in `[0, 65536]`. The value 65536 needs **18** signed bits, not 17: it is
`0_1_0000_0000_0000_0000`. `resize(..., 17)` keeps the sign bit `'0'` and the
low 16 bits, all of which are zero, giving **zero**.

The sum reaches 65536 at exactly one input: `z = 0`, which is the score that
just set the maximum and lands exactly on the grid. There the cone read
`EXP_ROM(0) = 121` instead of `EXP_ROM(256) = 2^30`, so
`e_p = round_shift(121, 18) = 0` instead of `4096`.

Fixed by taking a SLICE of the wide sum instead of resizing it:

```vhdl
off_v  := x2_z + OFF_MID;
x3_off <= unsigned(off_v(OFF_W-1 downto 0));
```

`0 <= off_v <= 2^17` by construction, so the low `OFF_W` bits ARE the value and
no resize is needed at all.

## The procedure that produced it

The order matters. Two of these steps existed only because of prior defects in
this project, and both earned their place again.

1. **Build the C reference first, with double oracles that share none of its
   fixed-point machinery.** `ref/attn_softmax_vec.c` checks the final
   denominator against a BATCH double-precision sum inside a per-case derived
   bound, every `e_p` against `exp()` inside the chord bound of a convex
   function over a 1/16 grid step, the DIRECTION of that chord, and the grid
   invariants as exact equalities.

2. **Mutation-test the C reference before trusting the RTL against it.** 13
   mutations, 10 killed, table below. This is what establishes that a later RTL
   failure is an RTL failure.

3. **Let the reference's own COVERAGE CHECK invent the shape.** This is the
   step that produced the failing case, and nothing else would have. The first
   version of the generator reported `e_p = 4096` **zero times across 40 random
   heads**, and the generator FAILS on a coverage gap rather than noting it. A
   maximum landing exactly on a grid point has probability about 1/256 per head
   at random, and `z = 0` is the only input that reaches the top code point.
   Shape 10 -- constant scores, rounded to the grid -- was added to close the
   gap, and it is the only shape that failed.

4. **Read the failing SHAPE, not the failing value.** Both failing cases were
   shape 10, both failed at every position, and both returned exactly 0. That
   named the input (`z = 0`, the one value where offset saturates its declared
   width) in one step. `0 vs 4096` on its own did not.

5. **Confirm the fix is load-bearing** by re-introducing it as mutation M8 in
   the RTL mutation harness after the fix, and checking it is killed. A fix
   that is not shown to be necessary is not shown to be the fix.

## The evidence

C-reference self-mutation, before any RTL existed:

| # | mutation of `ref/attn_softmax_vec.c` | result |
|---|---|---|
| C1 | `ceil_grid` becomes `floor_grid` | killed, oracle 4: `z 76 > 0` |
| C2 | cone Q30 to Q12 floors instead of rounding | killed, oracle 2 |
| C3 | frac clamped to `2^Q - 1` at the top index | **SURVIVED -- equivalent** |
| C3b | frac forced to 0 at the top index | killed, oracle 2: `e_p 3848 vs 4096` |
| C4 | the rescale of `s` is dropped | killed, oracle 1 |
| C5 | `k` derived with one grid step too many | killed, oracle 1 (internal) |
| C6 | cone spans 15.0 instead of 16.0 | killed, oracle 2 |
| C7 | interpolation dropped, nearest entry only | killed, oracle 2 |
| C8 | `e_p` never folded into `s` | killed, oracle 1 |
| C9 | the maximum is not updated on a rise | killed, oracle 4 |
| C10 | the rise test is not strict | killed, oracle 4 |
| C11 | `k > ROM_N` clamps the INDEX not the FACTOR | **SURVIVED -- equivalent** |
| C12 | the domain guard is `<` instead of `<=` | **SURVIVED -- equivalent** |

RTL mutation results after the fix. Configurations: **A** = `ACK_LAG 4`,
`RS_ACK_LAG 9` (the shipped one); **B** = both acks tied high (degenerate);
**C** = `ACK_LAG 4`, `RS_ACK_LAG 3`.

| # | mutation | A | B | C |
|---|---|---|---|---|
| M1 | grid snap floors instead of ceiling | killed | killed | killed |
| M2 | rise test not strict (`>=`) | killed | killed | killed |
| M3 | the DRAIN removed | killed | killed | killed |
| M4 | `sc_q12` read live, not latched (RULE 2) | killed | killed | killed |
| M5 | explicit `done_r` clear inside the ack branch | survived | **killed** | survived |
| M5b | `done` a bare one-cycle pulse (RULE 1) | killed | **survived** | killed |
| M6 | `rs_valid` pulsed, not held (RULE 1) | killed | **survived** | **survived** |
| M7 | cone Q30 to Q12 floors instead of rounding | killed | killed | killed |
| M8 | offset narrowed with `resize` (**this defect**) | killed | killed | killed |
| M9 | `k > ROM_N` clamps the INDEX not the FACTOR | **survived** | **survived** | **survived** |
| M10 | first position treated as an ordinary rise | killed | killed | killed |
| M11 | `done` before the cone has drained | killed | killed | killed |
| M12 | table-delta width one bit narrow | killed | killed | killed |
| M13 | frac clamped to `2^Q - 1` at the top index | **survived** | **survived** | **survived** |
| M14 | frac forced to 0 at the top index | killed | killed | killed |
| M15 | the fold reads the cone output one cycle early | killed | killed | killed |

14 of 16 killed. M8's kill message is the original symptom exactly:
`case 10 pos 0: e_p got 0 want 4096`.

### The two survivors, read rather than assumed

- **M9, index clamp instead of factor clamp.** For `k > ROM_N` the RTL forces
  `rom_ix` to 0 and then zeroes `f_r`. Removing the second zeroing leaves
  `f = round_shift(EXP_ROM(0), 18) = round_shift(121, 18) = 0`, the same value,
  because `exp(-16)` is below half a Q12 count. The branch exists for the ROM's
  ADDRESS RANGE, not for the value. Confirmed independently as C11 on the C
  reference. **Equivalent.**
- **M13, frac clamped to `2^Q - 1`.** At the clamped top index the shortfall in
  Q30 is `65,054,728 - floor(65,054,728 * 4095 / 4096) = 15,883`, against a
  rounding step of `2^18 = 262,144`, so the Q12 result is still 4096.
  **Equivalent.** The paired mutation M14, which forces frac to 0 instead, is
  killed with `e_p 3848 vs 4096` -- so the pair proves the clamp is checked and
  that only one of the two ways of writing it is wrong. Confirmed independently
  as C3 and C3b on the C reference.

## Measured and REJECTED -- do not retry

- **"`resize` is safe here because the operands are both in range."** They are
  in range for the VALUE and out of range for the DECLARED WIDTH, which is the
  only thing `resize` looks at. `resize` on `signed` is sign-preserving, not
  magnitude-preserving. Do not "tidy" `unsigned(off_v(OFF_W-1 downto 0))` back
  into a `resize` to make the widths line up; widen the target or slice it.
  This is the second time in two units. **The general rule for this codebase:
  a narrowing `resize` on a `signed` is a defect until proven otherwise, and
  the proof is that the value fits in `width - 1` magnitude bits, not `width`.**
- **A random-magnitude generator.** The failing input is `z = 0`, which needs
  the maximum to land exactly on a 256-count grid point. At random that is
  about 1/256 per head, and the shapes that dominate the vector set draw
  offsets from ranges that make it rarer still. 40 heads produced it **zero**
  times. The coverage assertion, not the sample size, is what found it.
- **Checking the denominator alone.** `s` was wrong too (`0 vs 98304`), but
  only on the same two heads, and only because every weight in them was wrong.
  On any head where the maximum is not grid-aligned, `s` is exact. A testbench
  that checked only `s` on random data would have passed.

## Measurement traps hit

- **A rescale ack lag SHORTER than the producer's own sequence does not test
  the hold.** The rescale sequence is five states (`S_F`, `S_MUL`, `S_SB`,
  `S_SS`, `S_RS`), so at `RS_ACK_LAG = 3` a DUT that pulses `rs_valid` and
  advances unconditionally still has `rs_valid` high when the ack arrives, and
  the mutation is **equivalent**. M6 survives at lag 3 and is killed at lag 9.
  The testbench's default was moved from 3 to 9 for this reason. A hold test
  whose ack is prompter than the thing being held has tested nothing -- the
  same shape as `attn_kv_quant`'s M6 being an equivalent mutant at `M_GAP = 0`.
- **The DEGENERATE configuration is not strictly weaker.** M5 -- an explicit
  `done_r <= '0'` inside the `done_ack = '1'` branch, which is the exact
  `gdn_head_emit` anti-pattern the RTL comment warns about -- is killed ONLY by
  the configuration with both acks tied high, and survives both lagged ones.
  With the ack lagged the branch is simply not taken while `done` is being
  checked; with it tied high the later assignment wins on the first cycle and
  `done` never rises at all, so the run HANGS. Its complement M5b, a genuine
  one-cycle pulse, is killed only by the lagged configurations. **Neither
  configuration alone catches both, and both defects are real.**
- **M5's kill is a TIMEOUT, not a checker error.** The harness prints no
  `report error` line for it. A kill by hang is weaker evidence than a kill by
  a checker and is recorded as such; what makes it trustworthy here is that the
  hang is at the expected place (waiting for `done`) and that the complementary
  mutation M5b is killed by a checker.
- **`wait until rising_edge(clk)` resumes in the SAME delta as the edge**, so a
  `_taken` pulse the DUT assigns on that edge still reads as `'0'`. The
  testbench waits `1 ns` past the edge at the `cfg_taken` check for that reason.
  Carried over from `tb_attn_kv_quant`; it would have cost a run again.

## Open, not yet answered

- **No Vivado.** Both machines were busy, so nothing here is a routed result.
  `attn_softmax` declares **802 flip-flops** and **2 datapath multiplies**,
  counted from the signal declarations and a grep of the architecture at the
  shipped generics. Neither is a measurement and the Fmax is unknown.
- **The 2-DSP claim is a DERIVATION from operand widths, not a synthesis
  result.** The cone interpolation is 26 x 13 unsigned (27 x 14 signed) because
  the largest `EXP_ROM` delta is 65,054,728, which needs 26 bits and not 27;
  the `s` rescale is 26 x 13 unsigned. Both fit one DSP48E2 tile under the
  27x18 rule. The C DSP skeleton books the exp cone at **8** from a 2026-08-24
  measurement of the verbatim-width `fixed_pkg.exp_q`, and lists narrowing it as
  its open item 3. This is that narrowing, and mutation M12 shows the width is
  load-bearing rather than decorative -- but the skeleton also records that on
  the sigmoid cone, narrowing the interpolation delta ALONE changed no DSP
  count. Both operands are narrowed here. Only Vivado settles it.
- **This unit serves ONE head.** The real schedule interleaves the 6 query
  heads of a GQA group through one cone, which is what turns the front end's
  four-cycle per-score path from an initiation interval into a latency. The
  interleave is NOT built, and the 6 sets of `(m_g, s, first)` it needs are not
  declared. Nothing in the cone changes; the front end does.
- **`AREG`/`BREG` on the two multiplies is not asserted.** C spec 2.6 makes
  registered operand muxes normative (246 MHz combinational versus 340 MHz
  registered at the same 128 DSP), and a DSP48E2 census on any build must show
  `AREG/BREG = 1`. Both multiplies here read registered signals written in the
  previous stage, which is the idiom, but no attribute is pinned and no build
  has confirmed it.
- **`ovf` and `err` have no policy.** They are observable and nothing consumes
  them -- the same state `attn_kv_quant`'s `err` and `attn_score_q12`'s
  `ovr`/`err` have been in since they were written.
