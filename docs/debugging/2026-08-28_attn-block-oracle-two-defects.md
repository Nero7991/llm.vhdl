# attn_block: does subsystem C compute attention?

2026-08-28. Track C-ORACLE. Simulation only, no hardware.
Build: `rtl/attn_block.vhd` at `3246046` + the fpga branch working tree, GHDL mcode
`--std=08 -frelaxed`, `sim/tb_attn_block.vhd` at its generic defaults
(HEAD_DIM 16, N_QH 4, N_KVH 2, KV_BLOCK 4, N_ROT 8, cur_pos 3, ctx_len 4).

## 1. The question, verbatim

> `rtl/attn_block.vhd` composes ten units. It is now instantiated in `llama_top`
> and a 32-block token passes. **But nothing anywhere establishes that it
> computes attention.** Subsystem C has no block-level reference. `ref/` has
> per-unit vector oracles and the units are individually well verified, but the
> COMPOSITION is unchecked: correct parts wired wrongly would pass everything
> that exists today. Close that. Build an independent block-level C oracle and
> check `attn_block` against it bit-exactly.

## 2. The answer

**It did not.** The first bit-exact block-level comparison ever run against
`attn_block` disagreed on **64 of 64 output mantissas**, and bisection found
**two independent defects**, both in `rtl/attn_block.vhd`, both invisible to
every check that existed:

1. **Every cached position's V block exponents were replaced by the current
   token's.** `attn_kv_quant.hdr_valid` is a LEVEL, not a pulse, so the block's
   header capture re-ran on every cycle of the sweep and overwrote the header
   just read from the cache. The site-3 alignment shift `e_v[b] - v_ref` came
   out 0 for every earlier token instead of its true value, so cached V was
   attended at up to 2^8 times its real magnitude.

2. **Every accumulator was multiplied by the softmax rescale factor `f` twice
   per rise.** `rs_have` was re-latched from a still-standing `rs_valid` on the
   ack cycle, so `P_EPW` ran a second uniform rescale pass. The denominator `s`
   is rescaled inside `attn_softmax` and was rescaled exactly once, so only the
   numerators were wrong -- by a data-dependent factor in (0, 1] per rise.

Both are fixed in `rtl/attn_block.vhd` in this change, with the reasoning at
each site. With both fixed the block is **bit-exact** against
`ref/attn_block_vec.c`: 64 mantissas plus `y_exp`, on each of two consumer
configurations, 130 compared values, zero tolerance.

**Neither defect is reachable from `llama_top` today**, and that is checkable
rather than hopeful: `rtl/llama_top.vhd:2746` runs one token with `cur_pos = 0`
and `ctx_len = 1`, so the sweep is one position -- the cache is never read
(defect 1 unreachable) and no maximum can rise after the first score (defect 2
unreachable). The 32-block token's numbers do not move. `tb_llama_top` still
passes unchanged.

## 3. The procedure that produced it

Each step is listed with what it isolates, in the order it was run.

1. **Recompute the five constant tables from their defining formulas and diff
   them against the RTL packages.** `RSQRT_ROM`, `EXP_ROM`, `SIG_ROM` from
   `rtl/fixed_luts_pkg.vhd`, `IMROPE_W` and `SIN_TBL` from `rtl/imrope_pkg.vhd`
   -- 1,890 entries, all agreeing. This runs FIRST because it is the one
   dependency the oracle cannot avoid: if the tables had drifted from their
   stated formulas, every later comparison would have been noise. Controls for
   a shared-constant error.

2. **Write the oracle from the model definition, not from the RTL's phase
   machine.** `ref/attn_block_vec.c`: for each query head, RoPE'd RMSNorm'd Q
   against RoPE'd RMSNorm'd K of head `qh / G`, softmax over positions, times
   un-normed un-RoPE'd V, times sigmoid of the second half of wq. The per-site
   fixed-point numerics are necessarily shared (see section 6); the DATAFLOW is
   not. That asymmetry is the whole design: the dataflow is what was unchecked.

3. **Put the stimulus in the oracle's own file and have the bench read it.**
   A bench that regenerated the inputs would be a second source of truth for
   them, and a divergence in the inputs would present as an arithmetic failure.
   Controls for exactly that.

4. **Compare, and read `y_exp` before the mantissas.** `y_exp` matched (15) on
   the first run while all 64 mantissas differed. That is information, not a
   detail: `y_exp = e_min - shp` carries `v_ref`, the whole `e_grid`, and the
   msb of the aligned peak, so a matching `y_exp` rules out a gross scale error
   and says the defect is inside the values.

5. **Bisect forward through the chain with paired dumps.** A scratch copy of
   the RTL (never the repo copy) instrumented with `report` at each stage, and
   the same points printed from the oracle on stderr. The order matters: check
   the earliest stage first, because everything after it is downstream.

   | stage | RTL | oracle | verdict |
   |---|---|---|---|
   | RMSNorm out + `o_exp` (K and Q, both heads) | match | match | clean |
   | RoPE out | match | match | clean |
   | KV quantizer record (K and V mantissas + exponents) | match | match | clean |
   | `score_q12`, all 4 positions x 2 heads x 2 KV heads | match | match | clean |
   | `e_p`, same | match | match | clean |
   | softmax denominator `s`, `v_ref` | match | match | clean |
   | reciprocal `(p, r)` | match | match | clean |
   | gate operand `g` | match | match | clean |
   | **PV accumulator `o`** | **830432** | **434498** | **DIVERGES** |

   Nine stages clean and the tenth wrong localises the defect to the PV path
   with no guesswork.

6. **Dump the PV operands, not the PV result.** Per position, per block: the V
   mantissas, the V block exponent, and `v_ref`. The mantissas matched and the
   EXPONENTS did not -- which is defect 1, and is also why the mantissa dump was
   worth doing separately. A dump of the product alone would have said "the PV
   is wrong" and stopped there.

7. **Dump the bench's own `vr_hdr` too.** It delivered 9,7,9,7 correctly, which
   moved the fault from the memory model into `attn_block` and pinned it on the
   only other writer of `vhdr` in that process.

8. **Fix defect 1 alone and re-measure.** 64/64 mismatches became 48/64, and
   exactly one query head of four became bit-exact -- the one head with no
   rescale after its first position. That is what named defect 2 before any
   further instrumentation.

9. **Instrument the accumulator file itself** (`rtl/attn_mac_array.vhd`, scratch
   copy, `report` on every write to `acc(0)`), which printed two consecutive
   rescale writes with the same factor. Root cause read directly off the
   handshake: `rs_valid` legitimately stands for one more cycle after the ack.

10. **Mutation-test the finished check** (section 5). A check that has never
    failed on a defect it was built for is a claim, not a result.

## 4. The evidence

### Defect 1, the substituted V header

Cached position 0, KV head 0. The oracle's cache file line says the record's
block exponents are 9,7,9,7; the bench's memory model delivers 9,7,9,7; the
block's `vhdr` reads 6,6,6,6, which is the CURRENT token's V header.

```
=== bench, what vr_hdr actually delivered ===
DBGB VRD a=512 pos=0 blk=0 hdr=9,7,9,7
DBGB VRD a=512 pos=0 blk=1 hdr=9,7,9,7
DBGB VRD a=512 pos=0 blk=2 hdr=9,7,9,7
DBGB VRD a=512 pos=0 blk=3 hdr=9,7,9,7

=== oracle ===            === attn_block, before the fix ===
pos=0 blk=1 ve=7 vm=72,23   pos=0 blk=1 ve=6 vm=72,23
pos=0 blk=2 ve=9 vm=30,56   pos=0 blk=2 ve=6 vm=30,56
pos=0 blk=3 ve=7 vm=17,60   pos=0 blk=3 ve=6 vm=17,60
                             (the current token's own record is e=6,6,6,6)
```

Mantissas identical, exponents wrong. `err` clear, `vsh_neg` never asserted,
every exponent a legal int8, the shift still non-negative.

### Defect 2, the doubled rescale

`acc(0)` = KV head 0, query head 0, element 0. Every write, in order:

```
=== before the fix ===                     === after ===
DBGA PV acc0 0      + 444416 = 444416      PV acc0 0      + 444416 = 444416
DBGA PV acc0 444416 + 55776  = 500192      PV acc0 444416 + 55776  = 500192
DBGA PV acc0 500192 + 53270  = 553462      PV acc0 500192 + 53270  = 553462
DBGA RS acc0 553462 -> 458876              RS acc0 553462 -> 458876
DBGA RS acc0 458876 -> 380455              PV acc0 458876 + -24378 = 434498
DBGA PV acc0 380455 + -24378 = 356077
```

Two `RS` writes with one softmax rise. The oracle's value is 434498.

### The verdict line, after both fixes

```
tb_attn_block: PASS -- 3 consumer configurations, 64 elements each, y stream
bit-identical across all of them, y_exp tracks vin_exp exactly, the current
position was never read back, y_exp(run 0) = 15, and BIT-EXACT against
ref/attn_block_vec.c over 130 compared values
```

## 5. Teeth-check: 17 mutations, 17 killed

Every mutation is applied to a scratch copy of the RTL, never the repo copy.
The column that matters is the last one: it is the answer to "would the bench
that existed yesterday have caught this?"

| # | mutation | killed by | old bench (P1-P7 alone) |
|---|---|---|---|
| m1 | K and V transposed at the quantizer source | P8 | **would have PASSED** |
| m2 | RoPE dropped on Q (un-rotated norm parked in the Q plane) | P8 | **would have PASSED** |
| m3 | RoPE dropped on K (quantize the un-rotated vector) | P8 | **would have PASSED** |
| m4 | gate head misaligned by one inside the GQA group | P8 | **would have PASSED** |
| m5 | Q and its gate halves swapped | P8 | **would have PASSED** |
| m6 | sweep order: cache first, bypass last | P8 | **would have PASSED** |
| m7 | GQA grouping strided (`qh*N_KVH + kvh`) not contiguous | P8 | **would have PASSED** |
| m8 | `v_ref` fold takes the MAXIMUM not the minimum | P5 + `err` + P8 | caught |
| m9 | operand bus from the live `blk` not the registered `opb` | GHDL bound check | caught (hard error) |
| m9b | same, kept in range with `blk mod NBLK` | P8 | **would have PASSED** |
| m10 | **defect 1 re-introduced** | P8 | **would have PASSED** |
| m11 | **defect 2 re-introduced** | P8 | **would have PASSED** |
| m12 | accumulator rescale made a no-op (softmax `s` still rescaled) | P8 | **would have PASSED** |
| m13 | `e_grid` off by one (`v_ref + R_Q` not `+ R_Q - 1`) | P8 | **would have PASSED** |
| m14 | bypass removed: the current position read back from the cache | **P7 only** | caught |
| m15 | Q-norm and K-norm weight vectors swapped | P8 | **would have PASSED** |
| m16 | score's `q_exp` taken from `kin_exp` instead of the Q norm | P8 | **would have PASSED** |

**13 of 17 mutations were invisible to all seven structural properties.** That
is the measurement of what the block-level oracle bought, and it is the same
number stated the other way round: 13 different wrong wirings of ten correct
units all produced a stream of the right length, in the right order, with a
correctly-tracking exponent, never touching the current cache position.

**m14 is the complementary case and is worth keeping.** Removing the bypass is
INVISIBLE to P8 (0 mismatching mantissas) and caught only by P7, because the
bench's memory model returns exactly what the block wrote to that address
earlier in the same job. The race the bypass exists to avoid cannot be
reproduced by a memory model, so the property has to be stated over the
addresses. P8 does not subsume P7.

**m9's kill is weaker than it looks.** With `opb` replaced by the live `blk`,
`blk` reaches `NBLK` and GHDL reports `overflow detected` -- a hard error, not a
silent wrong value, so it does not demonstrate that the check can SEE that
defect class. m9b was added to answer that properly: kept in range with
`blk mod NBLK`, it is killed by P8 alone.

## 6. Measured and REJECTED -- do not retry

- **A float oracle.** Rejected before it was written and stated here so nobody
  tries it: the block does not compute attention in the reals. It computes one
  specific fixed-point approximation -- a block-floating quantizer, a
  table-interpolated exp on a snapped grid, an online softmax with grid-exact
  rescaling, a restoring-divider reciprocal, a table-interpolated sigmoid, a
  block-floating pack. No float model of that chain is bit-exact with it, so a
  float oracle forces a tolerance, and a tolerance is what defect 2 lives under:
  a factor of `f` in (0, 1] per rise is well inside any tolerance anyone would
  pick.

- **Composing the existing per-unit `ref/attn_*_vec.c` in the order the RTL
  wires them.** Rejected on the grounds that it would have reproduced BOTH
  defects. Defect 1 is a wiring fact about which header reaches the alignment;
  defect 2 is a wiring fact about how many times the rescale pass runs. A
  composition that took its dataflow from the RTL would have agreed with the
  RTL, passed, and been reported as coverage.

- **`NGRP = 1` (one KV head).** Not retried, and not fixed here.
  `rtl/attn_emit.vhd:400` assigns `grp <= 1` into a signal declared
  `integer range 0 to NGRP-1` at `:263`, so `NGRP = 1` is an immediate bound
  violation. Worklog OI-2. The oracle refuses `N_KVH < 2` with that message
  rather than producing a vector file nobody can run.

## 7. Measurement traps hit

- **`y_exp` matching is not reassurance.** It matched on the very first run
  while every mantissa was wrong. It is a function of `v_ref` and the aligned
  peak's msb, both of which survive a defect that changes values by less than a
  factor of two. Read it as a localisation hint, never as a partial pass.

- **Interleaved stderr from a `fprintf` split across two branches.** The
  oracle's paired debug prints emitted the first head's line without a newline
  and the second head's afterwards, so a `grep DBG PV` dropped every block-0
  line and made the oracle look as though it disagreed with its own vector
  file. It did not. If a dump line goes missing, check the print, not the
  arithmetic.

- **`grep -c` on a mutation log is not a kill count.** m14 produces eight
  identical P7 errors from eight offending reads; the mutation is one.

- **A property list is not a kill list.** m9's row read "killed" until the log
  was opened and showed GHDL's own bound check, not the bench. Always read what
  killed it.

## 8. Open, not yet answered

- **`attn_kv_axi` does not exist.** The KV cache here is a memory port with a
  one-cycle synchronous read. Nothing about 4 KB burst splitting, 16-byte
  record-phase realignment, drain-then-flush on `start`, or `done` gated on
  BRESP is exercised by anything, in any bench. This is the largest remaining
  hole in subsystem C and P8 does not touch it.

- **Multi-token sequences.** `v_ref` is a per-SEQUENCE minimum folded over every
  record ever written. This bench writes exactly ONE token per sequence, so the
  fold is checked at its first value and never across an append. C spec 2.1.4
  warns that a cache truncation or rollback breaks the append-only invariant
  SILENTLY; nothing here would see it.

- **The shipping geometry.** The regression point is HEAD_DIM 16 / 4 query
  heads / 2 KV heads / KV_BLOCK 4 / N_ROT 8 / cur_pos 3, not 256 / 12 / 2 / 32 /
  64. A **second geometry has been run by hand and is also bit-exact** --
  HEAD_DIM 64 / N_QH 6 / N_KVH 3 / KV_BLOCK 8 / N_ROT 16 / cur_pos 2, 384
  elements, 770 compared values, which additionally exercises `NGRP = 3` in
  `attn_emit` and reaches `rope_sat`. Neither is the shipping shape, and the
  widths that would first bite there (the s26 denominator at long context, the
  s36 accumulator) do not scale with either point. HEAD_DIM must stay an EVEN
  power of two or `attn_block`'s own elaboration assert fires, because
  `1/sqrt(head_dim)` stops being a power of two.

- **Whether defects 1 and 2 are the only two.** P8 is bit-exact on one
  descriptor at one geometry. It is a strong check on that point and says
  nothing about any other.

- **Vivado.** Nothing here was synthesized. The two fixes add one comparison
  each to already-existing combinational conditions; the timing claim is a
  derivation, not a measurement.
