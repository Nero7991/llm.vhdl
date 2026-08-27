# attn_kv_quant: `resize(-ext, IN_W)` silently deleted `abs(-32768)`, and only the exponent check saw it

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. New files, never committed with the
defect present. GHDL mcode backend, `ghdl -r` direct, no `ghdl -e`.
**Unit:** `rtl/attn_kv_quant.vhd`, subsystem C step 4, the KV-cache write-side
block-floating quantizer, at `HEAD_DIM = 256`, `KV_BLOCK = 32`, `IN_W = 16`,
`MANT_W = 8`.

## The question

First run of `sim/tb_attn_kv_quant.vhd` against `ref/attn_kv_quant_vec.c`,
M_GAP = 3, ACK_LAG = 5, 64 vectors of 256 elements. Six vectors of 64 failed,
with two failures each and always in the same shape:

```
case 4 elem 0:  mant got -128  want -64
case 4 block 0: exponent got 14 want 13
case 5 elem 0:  mant got  -64  want -32
case 5 block 0: exponent got 17 want 16
case 8 elem 0:  mant got -128  want -64
case 8 block 0: exponent got 11 want 10
```

Every failing mantissa was exactly twice the reference and every failing
exponent was exactly one too high. Nothing was out of range, no value
saturated that should not have, and the record was the right length.

## The answer

`numeric_std`'s `resize` on a `signed` keeps the SIGN bit and drops the top
magnitude bit. The absolute-value stage was written as

```vhdl
ext := resize(a3_x, IN_W+1);          -- widen to 17 bits, correct
if ext < 0 then
  a4_abs <= unsigned(resize(-ext, IN_W));   -- narrow back to 16.  THE DEFECT.
```

`-ext` for `a3_x = -32768` is `+32768`, which is `0_1000_0000_0000_0000` in 17
bits. `resize(..., 16)` keeps the sign bit `'0'` and the low 15 bits, giving
**zero**. So a block containing `-32768` -- the one value in int16 whose
negation overflows -- contributed 0 to the running `amax` instead of 32768.
The block's `amax` then came from the next largest element, typically 32767,
whose `msb_pos` is 14 rather than 15, so `sh = msb_pos(amax) - 6` came out
**one too small**, every mantissa in that block came out twice too large, and
`e = src_exp - sh` came out one too high.

Fixed by widening `a4_abs` and `amax` to `IN_W+1` bits and removing the
narrowing entirely: `a4_abs <= unsigned(-ext)`.

## The procedure that produced it

The order matters. Two of these steps existed only because of prior defects in
this project, and both earned their place again here.

1. **Build the C reference first, with a double oracle that shares none of its
   fixed-point machinery.** `ref/attn_kv_quant_vec.c` recomputes every mantissa
   in floating point from the emitted exponent (`clip(floor(x_real * 2^e +
   0.5))`, `ldexp` and `floor` only) and separately requires each block's peak
   to land in `[64, 128)` output LSB. Neither check uses `mv4i_arith.h`.

2. **Mutation-test the C reference before trusting the RTL against it.** Five
   non-equivalent mutations of the generator, all killed, table below. This is
   what establishes that a later RTL failure is an RTL failure.

3. **Check the block exponents SEPARATELY from the mantissas in the testbench.**
   This is the step that made the defect readable, and it is the whole reason
   the failure was diagnosable in one run.

4. **Read the failing case's shape rather than the failing value.** Case 4 is
   the generator's `INT16_MIN present` shape, and element 0 of each block is
   where the generator plants `-32768`. The failing element was always element
   0 and always in the shapes that plant a large magnitude. That named the
   cause; the value `-128 vs -64` on its own did not.

5. **Confirm the fix is load-bearing** by re-introducing it as mutation M8 in
   the mutation harness after the fix, and checking it is killed. A fix that
   is not shown to be necessary is not shown to be the fix.

## The evidence

C-reference self-mutation, before any RTL existed (all five killed):

| mutation of `ref/attn_kv_quant_vec.c` | caught by | first failure |
|---|---|---|
| `TARGET_MSB` 6 -> 5 | oracle 2 | shifted block's peak only 32.0 output LSB |
| `TARGET_MSB` 6 -> 7 | oracle 2 | block's peak reaches 255.99 output LSB |
| `round_shift` -> `floor_shr` | oracle 1 | case 2 elem 128: path -128, oracle -127 |
| `sat8` removed | oracle 1 | case 2 elem 152: path -128, oracle 127 |
| `e = src_exp + sh` | oracle 1 | case 2 elem 128: path -127, oracle -128 |

RTL mutation results after the fix, `M_GAP = 3 ACK_LAG = 5` (the shipped
configuration) and `M_GAP = 0 ACK_LAG = 0` (the degenerate one):

| # | mutation | 3/5 | 0/0 |
|---|---|---|---|
| M1 | `TARGET_MSB` `MANT_W-2` -> `MANT_W-1` | killed | killed |
| M2 | `sat8` removed, wrap instead of clip | killed | killed |
| M3 | round bias dropped, floor instead of round-half | killed | killed |
| M4 | block index read live in the mux stage | killed | killed |
| M5 | `v_ref` fold init 127 -> 0 | killed | killed |
| M6 | `x_re` tied high, read-enable freeze removed | killed | **equivalent** |
| M7 | `done` reverted to a bare one-cycle pulse | killed | **equivalent** |
| M8 | abs narrowed back to `IN_W` (**this defect**) | killed | killed |
| M9 | `is_v` ignored, `v_ref` folded for K too | killed | killed |
| M10 | exponent sign flip, `e = src_exp + sh` | killed | killed |
| M11 | descriptor not latched, `src_exp` read live | killed | killed |
| M12 | `hdr_valid` raised at `start` | killed | killed |

M8's kill message is the original symptom exactly: `case 4 elem 0: mant got
-128 want -64`.

## Measured and REJECTED -- do not retry

- **"`resize` is safe because the value was already widened."** It is not. The
  widening is correct and the NARROWING is the defect: `resize` on `signed` is
  a sign-preserving operation, not a magnitude-preserving one, so widening to
  hold `2^(IN_W-1)` and then narrowing back throws away exactly the bit that
  was widened for. Do not "tidy" `unsigned(-ext)` back to
  `unsigned(resize(-ext, IN_W))` to make the widths line up; make `a4_abs`
  wider instead.
- **Checking the mantissas alone.** The mantissas produced by this defect are
  self-consistent with the wrong exponent: `mant = 2 * mant_ref` and
  `e = e_ref + 1` denote the same real value to within the grid, so a
  testbench that reconstructs `mant * 2^-e` and compares against a tolerance
  sees NOTHING. Only the separate, exact exponent comparison catches it. This
  is the same class as the `gdn_emit_chain` note that `y_exp` being constant
  across all six blocks made its exponent check nearly vacuous.
- **Assuming the abs stage is trivial enough not to need a case.** The
  generator's shape 4 (`INT16_MIN present`) exists only because the asymmetric
  end of int16 is a known trap, and it is the only shape that caught this. A
  random-magnitude generator would hit `-32768` with probability about
  `1/65536` per element -- roughly once per 4 vectors of 256 at uniform
  sampling, but the random shapes here draw `k` bits with `k` uniform in
  `0..15`, so the actual rate is far lower and could easily have been zero
  across 64 vectors.

## Measurement traps hit

- **Two testbench defects masqueraded as DUT defects before the real one was
  found**, and both cost a run each:
  1. `wait until rising_edge(clk)` resumes in the SAME delta as the edge, so
     every `_taken` pulse the DUT assigns on that edge reads as `'0'`. It looks
     exactly like a missing pulse. Fixed with `wait for 1 ns` after the edge;
     the fix is now commented at both sites.
  2. `m_ready` keyed off the ACCEPTED count deadlocks: nothing is accepted
     while it is low, so the condition that lowered it never clears. The run
     wedges with `m_valid` high and looks like a DUT hang. Keyed off a
     free-running cycle count instead. `M_GAP = 1` is separately degenerate
     (`tick mod 1 = 0 = M_GAP-1` always) and the testbench now refuses it
     loudly rather than hanging.
- **A heartbeat settled "wedged versus slow" in one run**, as the
  `gdn_head_emit` write-up predicted it would. `HEARTBEAT_US = 5` reported
  `busy='1' m_valid='1' m_ready='0'` identically at 5, 10, 15, 20, 25 and 30
  us. Frozen, not slow, and the frozen state named the deadlocked signal.
- **A mutation that the generic map overrides has tested nothing.** M5 was
  first written as a mutation of the `VREF_INIT` GENERIC DEFAULT. The
  testbench's generic map passes `VREF_INIT => 127` explicitly, so the mutant
  DUT was identical to the original and "survived". It is killed once the
  architecture body is mutated instead. Mutate the value that is USED, not the
  default that may be overridden.
- **`p_ready` checked one delta late fires on correct behaviour.** In
  `tb_attn_score_q12` the sibling check sampled `p_ready` AFTER the accepting
  edge; on the last of NBLK partials that is legitimately `'0'`, because all
  of them have been taken. Check it in the cycle BEFORE the edge, which is the
  value the DUT actually uses to accept.

## Consequence for the design

The read-enable contract on `x_re` came out of the same review and is worth
recording alongside, because it is the same class of silent defect and it is
NOT exercised by the default configuration. The address register runs one item
ahead of the capture stage, so a stall that freezes `x_raddr` but leaves the
source memory enabled makes the memory overwrite its output register with the
item still in flight; on resume the capture stage takes the wrong element with
the right index. Every value stays in range and the record stays the right
length. Mutation M6 (`x_re` tied high) is killed at `M_GAP = 3` and is an
EQUIVALENT MUTANT at `M_GAP = 0`. **A run with no back-pressure does not test
the back-pressure path, and a testbench memory that ignores `x_re` does not
test it either.** The testbench memory implements the enable for that reason.

## Open, not yet answered

- **No Vivado.** Both machines were busy and this box has been OOM-killed by
  Vivado before, so nothing here is a routed result. `attn_kv_quant` declares
  532 flip-flops and `attn_score_q12` declares 443, counted from the signal
  declarations at the shipped generics; neither contains a `*` on a datapath
  value, so both should infer **0 DSP**. That is a count and an inference, not
  a measurement, and the Fmax of neither is known.
- **`sh_arr`, `bias_arr` and `e_arr` are left to inference.** `gdn_head_emit`'s
  header records Vivado switching primitive with a generic (distributed RAM at
  `DIM` 64 and 128, one RAMB36 at 256) and calls that a reproducibility problem
  on its own. At `NBLK = 8` these are 8-entry arrays and will almost certainly
  be flops, but no `ram_style` attribute is pinned and no build has confirmed
  it.
- **One constant multiply survives**: `raddr_r <= to_unsigned(blk*KV_BLOCK +
  rd_idx, AW)`. `KV_BLOCK` is a generic and is 32 in every configuration this
  design uses, so it folds to a wire shift. A non-power-of-two `KV_BLOCK` would
  infer a small LUT multiplier (3 bits by 6 bits), not a DSP, but it has not
  been measured.
- **`err` on `attn_kv_quant` and `err`/`ovr` on `attn_score_q12` have no
  policy.** They are observable and nothing consumes them, which is the same
  state `y_sat` has been in since `72f5c8d`.
