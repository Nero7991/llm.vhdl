# B's scalar path: three defects, and where the decay gate's accuracy actually goes

**Date:** 2026-08-26
**Unit:** `rtl/gdn_scalar.vhd` (new), `ref/fx.h` (`fx_softplus_q` added),
`ref/gdn_scalar_vec.c` (new), `sim/tb_gdn_scalar.vhd` (new)
**Build:** GHDL 5.0.1 for simulation; Vivado 2023.2 OOC for the resource numbers.

## The question

B 2.1.3's last block turns four per-head weights into the two scalars the
recurrence consumes:

```
arg  = Q(alpha) + Q(dt)
sp   = softplus(arg)
g    = min(0, round_shift(sp * a_m, a_e))    clamped at -16
eg   = exp(g)         -> unsigned Q15
beta = sigmoid(Q(b))  -> unsigned Q16
```

Until now nothing built it: `gdn_recur` took `eg` and `beta` from its
testbench, `softplus` did not exist in `ref/fx.h` at all, and 3 listed its
recipe as still owed. 2.8 priced the whole block as "believed cheap ... but
believed is not measured", at +2 to +4 DSP.

## The answers, up front

1. **The block is 7 DSP, 0 BRAM, 3,577 LUT at 327.8 MHz**, and it closes
   2.8's unpriced row -- but ABOVE the guessed range, not inside it. 2.8 said
   "believed cheap ... +2 to +4"; the measurement is 7, with one interpolator
   already shared across all three kernels. I wrote "3 DSP" into an earlier
   draft of this file from the same intuition 2.8 used, before synthesizing.
   It was wrong by the same factor, in the same direction.
2. **Two defects in 2.1.3 as written**, both of which turn a shut decay gate
   into a wide-open one, and both found by the double oracle rather than by
   inspection.
3. **The pinned Q12 grid, not the exp table, is what limits `eg`'s accuracy.**
   On the real Qwen3.8-27B weights the Q12 grid costs 1.92e-4 relative on the
   slow heads, compounding to **2.196x over a 4096-token sequence**. Q18 takes
   that to 1.133x and reaches the floor set by the exp table itself. The change
   costs a wider shift and nothing else.

## Defect 1: the sum must not be formed from two saturated terms

2.1.3 says `alpha` and `dt` are "converted to Q12 (rule above ...) and **added
in s32**". Taken literally that saturates each term before the add, and two
opposite-sign saturations cancel:

```
true argument            : -34826.0
exact in Q18             : a=16478896128 d=-25608323072 sum=-9129426944
each saturated to s32    : a=2147483647 d=-2147483648 sum=-1
```

A correctly very negative argument becomes `-1`. `softplus(-1/2^18)` is then
about `ln 2`, so `g = -8.9` instead of a number far past the clamp, and

```
eg = 4      (gate shut, correct)   ->   eg = 32768   (gate wide open)
```

The state stops decaying entirely for that head. **Fix:** convert both terms
on a wide grid and clamp the sum once. This is also strictly cheaper in RTL,
since it deletes the per-term saturator.

## Defect 2: the positive tail must not be clamped

My first fix for defect 1 clamped the sum symmetrically to `+/-16 * 2^q`, on
the argument that softplus is the identity above +16 and zero below -16, so
neither tail carries information.

**That argument is exactly backwards on the positive side, and my own sentence
contains the refutation.** Below -16 softplus is zero, so clamping genuinely
loses nothing. Above +16 softplus is the *identity* -- which is precisely why
the magnitude must survive: it is multiplied by `a` on the very next line, and
`g = a * sp`. Pinning `sp` at 16 pins `g` at `16 * a` instead of its true
value.

Measured on case 88 of the vector set: true `arg` 31900, `a` -0.00496, so
`g = -158` and the gate is hard shut at `eg = 0.0037`. With the symmetric
clamp `sp = 16`, `g = -0.079`, and `eg = 30280` -- open. Same failure
direction as defect 1, different cause.

**Fix:** clamp only the negative tail. The positive side takes the identity
branch on the wide grid.

Worth stating plainly: defect 2 was mine, introduced while fixing defect 1,
and the vector set caught it within one run. A symmetric clamp *looks* like
the tidy version of an asymmetric one, and the asymmetry here is load-bearing.

## Defect 3 (RTL, mine): the LUT index shortcut is wrong at the endpoint

`fx.h` computes the table index as

```
idx = offset * 16 ;  k = idx >> q ;  frac = idx - (k << q)
```

Since the 16 is a power of two this looks like a pure field split of `offset`:
`k` is the high bits, `frac` the low bits shifted up by 4. No arithmetic at
all. I implemented that, and it is correct **in the interior and wrong at the
top of the table**.

`fx.h` clamps `k` to `kmax` (255 for the 257-entry tables) and then lets `frac`
run all the way to a **full `2^q`**, so the interpolation still evaluates to
exactly `lut[kmax+1]`. The field-split form yields `frac = 0` at that same
point and returns `lut[kmax]` instead -- one table step low.

This is not a corner case. The exp call sits at that endpoint whenever
`g` rounds to zero, which is the common case for a slow head: **104 of 320
vectors failed**. `beta` was bit-exact throughout and hid the bug, because
`fx_sigmoid_q` returns early for `z >= 16*2^q` and so can never reach its own
endpoint.

**Fix:** compute `frac = (offset << 4) - (k << q)` with the clamped `k`. One
subtract, exact everywhere, no case analysis.

## Where `eg`'s accuracy actually goes

Measured end to end -- this recipe, against a double oracle in real arithmetic
-- on the real model's own `ssm_a` and `ssm_dt_bias`, all 2304 GDN heads of
Qwen3.8-27B (`ref/gdn_eg_qwen3_27b.txt`). The band that matters is the slow
heads, those retaining >= 99.9% per token, because only there does a
per-token error compound:

| scalar grid | slow-band worst rel err | compounded over 4096 tokens |
|---|---|---|
| Q12 (pinned) | 1.92e-04 | **2.196** |
| Q13 | 1.40e-04 | 1.777 |
| Q14 | 5.23e-05 | 1.239 |
| Q15 | 5.05e-05 | 1.230 |
| Q16 | 4.09e-05 | 1.183 |
| Q17 | 3.75e-05 | 1.166 |
| **Q18** | **3.06e-05** | **1.133** |
| Q20 | 3.01e-05 | 1.131 |

The curve saturates at Q18, and it saturates at exactly the exp table's own
interpolation error -- 3.04e-05, measured independently in
`2026-08-25_gdn-recurrence-error-bound.md` by a completely different route.
Two measurements from different directions landing on the same floor is the
main reason to believe either.

**Two mechanisms, not one, make Q12 bad:**

1. `g` itself is unrepresentable. The slow heads need `g` around -3e-5, and
   Q12's LSB is 2.44e-4. For 4 heads out of 2304 (0.2%) `g` quantizes to
   exactly zero and the decay vanishes completely. That fraction is small --
   small enough that it is worth saying I expected it to be much larger before
   measuring.
2. **`softplus`'s output underflows and is then amplified.** This is the
   bigger effect. `dt_bias` reaches -8.94, where `softplus` is 1.31e-4 --
   below Q12's LSB. And `|ssm_a|` reaches **139.4** in this model, so that
   underflowed value is multiplied by up to 139 on its way into `g`. A term
   that rounds to 0 or 1 at Q12 lands as a 1.6% error on `eg`.

The cost of Q12 -> Q18 is a wider barrel shift, and it is **measured, not
argued**. OOC on `xcvu33p-fsvh2104-2L-e` at a 3.0 ns target:

| `SP_Q` | DSP | BRAM | Fmax |
|---|---|---|---|
| 12 (pinned) | 7 | 0 | 327.8 MHz |
| 15 | 7 | 0 | 327.8 MHz |
| 18 | 7 | 0 | 327.8 MHz |

Byte-identical, which is what a silently-ignored generic also looks like, so it
was checked rather than assumed: the log reports `Parameter SP_Q bound to: 12`
/ `15` / `18` on the three runs, and the LUT count does move. The results are
identical because no datapath WIDTH depends on `SP_Q` -- only constant shift
amounts do, and those fold away.

**Updated 2026-08-26: `SP_Q` now defaults to 18, ADOPTED.** At the time this
section was written it defaulted to 12, so the then-pinned Q12 contract was
what built by default. The table above is what moved it: Q18 reaches the floor
set by the exp table's own interpolation error, and the cost is a wider shift
and nothing else. Q12 remains reachable by overriding the generic.

## The softplus recipe, now pinned

3 owed this. `fx_softplus_q`, by range reduction:

```
softplus(x) = max(x, 0) + log(1 + exp(-|x|))
```

The correction term is confined to `[-16, 0]` and to `(0, ln 2]`, so a
257-entry table carries it to the same absolute accuracy a direct table over
`[-16, 20]` would need 577 entries to reach. The geometry is deliberately
**identical to the exp table's** (step 1/16, Q30, `offset = z + 16*2^q`) so the
RTL evaluates softplus, exp and sigmoid with one interpolator and a ROM mux --
which is why the block is 3 DSP rather than 9.

1.1(f)'s threshold rule (`x > 20 ? x : log(1+exp(x))`) falls out for free
rather than needing a branch: beyond `|x| = 16` the correction is 1.1e-7,
below the LSB of every grid this model uses, so the function returns exactly
`x`. Measured worst absolute error 1.35e-4, which is interpolation-bound and
therefore does not improve with `q` -- it enters `g` multiplied by `|a|`.

## Four MORE divergences, found by review after the 320-vector suite passed

The suite above passed at Q12, Q15 and Q18, and the unit was committed on that
basis. An adversarial review then ran the RTL against the C path on inputs the
generator never drew and found **four divergences, every one of them a
port-legal input**. All are fixed; the point of recording them is that the
passing suite was not evidence of what it was taken to be.

**The common root cause is width.** Three of the four are a wide value being
narrowed or shifted at the wrong width, in a unit whose entire header is about
not letting a shut gate read as an open one.

1. **`g` was narrowed to s32 BEFORE being clamped.** `resize` keeps the sign
   bit and the low bits, so `g = -(2^32 + 100)` became `-100`, which is inside
   `(-LIM, 0]` and never clamps. A gate the reference shuts hard reads as
   `eg = 31992` -- nearly wide open -- and `err_g` is wrong too. The clamp now
   happens on the s68 value and narrows in the same step, so no intermediate
   exists that could alias. **Adopting Q18 would have widened this bug's alias
   window 64x**, since the window is `16*2^SP_Q` out of `2^31`.

2. **`shift_left` on a `wide_t` is performed AT `wide_t`'s width.** The
   saturation check sat after the shift, so `-27632 << 37` wrapped inside s52
   and the check never saw the overflow -- while the C reference, working in
   int64, had the headroom and saturated correctly. The check is now on the
   mantissa, before the shift. This is the subtlest of the four: the RTL and
   the C were the *same algorithm*, and differed only in the width the
   intermediate lived at.

3. **A left shift by a negative `a_e` overflowed both sides, differently.**
   `sp * a_m` reaches 2^61, and `a_e` may be negative, so `rsh_r` shifts that
   left by up to 40 -- past s68 in the RTL and past int64 in C. Both wrapped,
   which makes it a divergence rather than a shared inaccuracy. Both now
   saturate at 2^62; since `g` is clamped to `[-16*2^q, 0]` and `16*2^q <= 2^26`,
   saturating there gives the identical clamped result.

4. **A ZERO mantissa with a large exponent returned the positive sentinel.**
   The `-sh > 40` branch tested `m >= 0`, so `m = 0` took the positive rail and
   slammed `beta` to 65535 where the reference gives 32768. `to_q_wide` now
   returns zero for a zero mantissa on every grid, which is also the only
   defensible reading of the format.

A fifth, smaller one: the beta path used the saturating s32 `to_q` in C and
`to_q_wide` in the RTL. They agree everywhere the sigmoid's domain guard bites,
which is why it never showed -- but two converters where the contract says one
is a divergence waiting for a corner. Both sides now use `to_q_wide` plus the
same clamp.

### Why the suite missed all of them

**The generator drew exponents in [-4, 20].** Every wide-shift guard in the
unit -- the `>62` and `>40` cutoffs, the saturation sentinel, and the s52
accumulator's headroom -- was therefore dead in test, and any mutation of those
constants passed. The four defects live entirely in that hole. The band now
spans **[-40, 60]**, and four named deterministic corners reproduce the exact
counterexamples.

**`err_g` was read from the vector file into a variable and never compared.**
Tying `err_g` high passed all 320 vectors at all three grids. It is now
asserted. 103 of 320 cases exercise it.

**The lesson, and it is the same one this project has now learned three
times.** `tb_l2norm_rs` certified a broken recipe because its golden shared the
recipe's assumptions. Here the golden is genuinely independent -- a different
language and, for the oracle, a different number system -- and it *still*
certified a broken unit, because **the inputs shared the generator's
assumptions**. An independent oracle over a biased input distribution measures
only the region you thought to sample. Coverage of the guards is a separate
obligation from independence of the golden, and passing the second does not
discharge the first.

## Measured and REJECTED (do not retry)

- **Symmetric clamp of the softplus argument.** See defect 2. Turns a shut
  gate into an open one; measured `eg` 30280 against a true 0.0037.
- **Field-split LUT index without endpoint handling.** See defect 3. Broke 104
  of 320 vectors. The shortcut is still used, just with the subtract.
- **Scalar grid beyond Q18.** Q20 gains 0.002 on the compounding factor.
  The exp table's interpolation error is the floor; widening the grid past it
  buys nothing. If more accuracy is ever wanted the next move is a finer exp
  table, not a wider grid.
- **Dropping the initial value on the ROM address register to get the tables
  into BRAM.** Synthesis warns `[Synth 8-6040] Register ip_k_reg driving
  address of a ROM cannot be packed in BRAM/URAM because of presence of initial
  value`, which reads like a one-character fix for 3,577 LUT of Q30 tables.
  Removing it changes nothing: 3,577 LUT, 0 BRAM, identical WNS. The warning
  is real but it is not the binding constraint -- the three tables are selected
  by a mux on the same address, so they infer as distributed ROM regardless.
  Getting them into BRAM needs the ROM restructured, not the attribute removed.
- **A second transcription of the recipe as the golden.** Not attempted here,
  deliberately. Every number above comes from a double oracle that touches no
  LUT, no shift and no integer grid. Defects 1 and 2 are both invisible to a
  same-recipe golden, since such a golden reproduces the saturation and the
  clamp faithfully.

## Measurement traps hit

- **`fx.h`'s kernels read LUTs built by `fx_init()`.** A probe that forgets to
  call it gets an all-zero table, which made `fx_sigmoid_q` appear to return 0
  across 64% of its range -- a spectacular and entirely fictitious defect. If
  an approximation kernel here looks broken *everywhere at once*, check
  `fx_init()` before believing it.
- **`awk` compares numerically only if you force it.** `a = $4; if (a > mx)`
  compares strings, and reported `|ssm_a|` max as 0 instead of 139.4 -- which
  would have hidden the amplification mechanism entirely. Use `$4 + 0`.
- **My own vector generator drew `a_m` outside s16** (-40766 in one band),
  which presented as 15 RTL mismatches. The port type is `signed(15 downto 0)`
  and the reference used int32, so the reference was right and the generator
  was wrong. Same class as the earlier `diff`/s18 scare: when the RTL and the
  reference disagree, check that the vector is legal before assuming either.

## Open, not yet determined

- **Whether to adopt Q18.** Measured, free, and defaulted OFF. This is a
  contract change and it is the user's call, exactly like the 2.1.4 amendment.
- **`beta`'s Q16 output saturates one LSB low.** `gdn_recur`'s port is
  `unsigned(15 downto 0)` and Q16's 1.0 is 65536, which does not fit. Saturated
  at 65535, a 1.5e-5 relative error at the very top of the range only. Not
  measured through the recurrence.
- **`alpha`'s real distribution is unknown.** Every number here fixes
  `alpha = 0`, because that is what `gdn_eg_qwen3_27b.txt` extracts. `alpha` is
  an activation, so the operating `g` in a real decode may differ from the
  weight-only figure, and could reach the `eg = 0` region the table's minimum
  (1.17e-4) does not.
- **No P&R.** The DSP and BRAM counts are OOC synthesis.
