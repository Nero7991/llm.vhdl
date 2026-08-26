# The first token's state can be lost entirely: d_m is quantized on the wrong grid

Date: 2026-08-25 (filed under 2026-08-26, the working day it belongs to)
Spec: B section 2.1.4, stage 3, site 9
Found by: writing `rtl/gdn_recur.vhd` and checking it against a double-precision
oracle, not by reading the spec

## The question

B section 2.1.4 already carries one correction about the first token of a
sequence: at `tk = 0` the masked-zero state must be excluded from `e_u`'s
minimum, or the whole first write-back is floored right by ~30 bits. That was
found and fixed on 2026-08-25. Is the `tk = 0` case now correct?

## The answer

No. There is a SECOND, independent first-token weakness in the same stage, and
it is worse in the tail: **at `tk = 0` the entire state is `k_n * d_m`, so
`d_m`'s quantization error becomes the state's relative error directly, with
nothing else in the sum to dilute it.** `d_m` is quantized on the grid `e_d`,
which is set by `min(e_v, ske)` -- the magnitudes of `v` and `sk` -- and NOT by
the magnitude of `d` itself. When `beta` is small, `d` is small, `d_m` is a
small integer, and its relative error is large.

At `beta = 2.4e-4` (Q16 = 16), **`d_m` rounds to zero in 7.0% of draws, which
means the first token's state is identically zero**, and the median relative
error over the rest is 6.4%.

The fix is one line of the same kind the spec already applies one stage
earlier: normalize `d` onto its own grid exactly as site 7 normalizes `sk`.

## The procedure that produced it

1. **Implement the recipe in RTL and check it BIT-EXACTLY against the C.** This
   passes. It proves the RTL transcribes the recipe correctly and proves
   nothing about whether the recipe is right -- the l2norm incident of the same
   week is the reference case for why that distinction matters.
2. **Check the same RTL against a DOUBLE-PRECISION ORACLE of the same column**,
   carried in the same vector file. This is the check that fires. The oracle
   shares no grids, shifts or exponents with the fixed path.
3. **Separate the failing cases by what they have in common** rather than
   loosening the tolerance until they pass. One case failed at 561 LSB while
   the median case sat at 0.63. It was not a large-magnitude case or an
   exponent-spread case: it was a `tk0` case with `beta = 96/65536`.
4. **Reduce to the mechanism by hand.** At `tk = 0`, `sk_acc = 0`, so
   `skm = 0`, `diff = v_j`, and `u[i] = k_n[i] * d_m` exactly. There is no
   state term. The state IS `d_m` up to a per-element constant.
5. **Sweep the suspected parameter and measure**, rather than reasoning about
   whether it matters.

## The evidence

`d_m = round(v_j * beta / 2^16)` at `tk = 0`, 4,000 draws of `v_j` per row:

```
 beta_q16      beta  P(d_m=0)  median relerr       p95       max
       16   0.00024      7.0%          6.39%   100.00%   100.00%
       64   0.00098      1.4%          1.60%    16.75%   100.00%
      256   0.00391      0.4%          0.40%     4.02%   100.00%
     1024   0.01562      0.1%          0.10%     0.93%   100.00%
     4096   0.06250      0.0%          0.02%     0.24%    12.73%
    16384   0.25000      0.0%          0.01%     0.06%     3.45%
    65535   0.99998      0.0%          0.00%     0.00%     0.00%
```

A `max` of 100% is not a rounding artifact: it is `d_m = 0`, the first token's
entire state discarded.

The testbench reports the split directly, over 96 physically realizable cases:

```
worst state error 4.90 LSB in steady state, 561.59 LSB at tk = 0
```

A 115x gap between the first token and every later one, on the same unit with
the same inputs.

## The proposed correction

Normalize `d` onto its own grid, the way site 7 already normalizes `sk`:

```
dm_raw = diff * beta                       -- grid e_d + 16
shd    = max(0, msb_pos(|dm_raw|) - 14)
d_m    = round_shift(dm_raw, shd)          -- s18, grid e_dm = e_d + 16 - shd
kd[i]  = k_n[i] * d_m                      -- grid e_kd = 15 + e_dm
```

Everything downstream is unchanged; `e_kd` simply reads `e_dm` instead of
`e_d`. Measured against the same 4,000 draws per row:

| beta | P(d_m = 0) now | with the fix | worst rel err now | with the fix |
|---|---|---|---|---|
| 2.4e-4 | 7.0% | **0.0%** | 100% | **0.0000%** |
| 9.8e-4 | 1.4% | **0.0%** | 100% | **0.0000%** |
| 3.9e-3 | 0.4% | **0.0%** | 100% | **0.0000%** |
| 1.6e-2 | 0.1% | **0.0%** | 100% | **0.0000%** |
| 6.3e-2 | 0.0% | 0.0% | 12.7% | **0.0000%** |
| 1.0 | 0.0% | 0.0% | 0.0% | 0.0015% |

**Hardware cost: one msb scan and one shift. No extra multiply, no extra DSP.**
It is the same hardware site 7 already instantiates, and `gdn_recur.vhd`
already has the msb-scan function and a spare state to put it in.

The one row where the fix is very slightly worse (1.5e-5 at `beta = 1`) is the
normalization keeping 15 significant bits instead of an exact small integer;
that is three orders of magnitude below the error it removes.

## NOT DONE, and deliberately so

**The RTL still implements the recipe as PINNED, not the fix.** `2.1.4` is a
pinned numerical contract and the correction above changes an exponent that
`gdn_err.c`, the section 2.10 precision result and the section 3.3 schedule all
reference. Changing it silently, overnight, on the strength of one night's
measurement, is exactly the move that produced the l2norm situation. The
evidence is here; the decision is not mine to take alone.

What IS in the tree: `sim/tb_gdn_recur.vhd` carries a separate `TOL_S_TK0`
generic whose comment says in full that it is not slack but the measured size
of an open defect, and says to delete it when the correction lands.

## Measured and REJECTED -- do not retry

- **"Loosen TOL_S until the cases pass."** The failing case sat 900x above the
  median. A tolerance that admits it admits everything; the l2norm testbench
  had exactly this and it let a dropped rounding bias through.
- **"It is a small-beta corner, so it does not matter."** `beta = sigmoid(b)`,
  so `beta = 2.4e-4` needs only `b ~ -8.3`. More to the point, the spec's OWN
  correction note measures that a corrupted first token dilutes only as `1/t`
  and is still visible at `t ~ 1900` -- so a first-token defect is a
  whole-sequence defect for most sequences.
- **Blaming the widths.** `diff` overflowing its `s18` looked at first like a
  spec width bug. It was not: `v[j]` is int16 (2.1.3's format table) and my
  vector generator drew it from an s18 range. The spec's widths are right. The
  RTL's `v_j` port is now `signed(15 downto 0)` so the type carries the
  contract and an out-of-range `v` cannot be presented at all.

## Measurement traps hit

- **Relative error against a heavily cancelling sum is not a measurement.** The
  output dot is a 128-term signed sum; normalizing the error by `|sum|` reported
  errors of 1e8 wherever the sum landed near zero while every term was fine.
  Normalize by the sum of `|term|` instead. The first run of this testbench was
  unreadable because of this and looked like a broken unit.
- **Unphysical test vectors measure nothing about accuracy.** The first vector
  set drew `k_n` as full-scale random int16. `k_n` is a UNIT VECTOR by
  construction (it is what `l2norm_rs` emits), so those inputs cannot occur, and
  holding them to an accuracy tolerance produced failures that were purely an
  artifact of the generator. The vectors are now split into a PHYS group
  (unit-norm k, folded q, near-1 eg, plausible exponent spread) checked both
  ways, and an ADV group (corners, saturation, extreme spreads) checked
  bit-exactly ONLY. Corner cases are for exactness; accuracy claims are about
  realizable inputs.
- **A dropped shift clamp in an extracted reference looks exactly like an RTL
  bug.** `gdn_err.c` clamps shift counts to 63 (lines 383-384, 398-399) because
  `1LL << 64` is undefined behaviour in C. The column extraction dropped those
  clamps, and the resulting disagreement pointed at the RTL for a while. When a
  reference is extracted rather than reused, diff it against the original.

## Open, not yet answered

- Whether `beta` in the real model ever reaches the range where this bites.
  `ref/gdn_eg_qwen3_27b.txt` carries the measured `exp(g)` table but there is no
  equivalent for `beta`, and `gdn_err.c` feeds `beta` in as a value rather than
  computing it from `softplus`/`sigmoid`. Until that table exists the frequency
  of the defect in practice is unknown -- its SIZE is measured, its RATE is not.
- Whether the same "quantized on a borrowed grid" pattern appears at other
  sites. Site 9 borrows `e_d`; the sweep above shows what that costs when the
  borrowed grid is unrelated to the value's own magnitude. Sites 6 and 10 should
  be checked the same way.
