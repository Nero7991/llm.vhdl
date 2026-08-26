# Subsystem C's auxiliary DSP row, measured: QK-norm as shipped is disqualifying

## 1. The question

2026-08-25, while writing C spec section 3 (rev 7). C section 2.8 carried the
auxiliary DSP row as an unpriced **15-40 estimate** covering QK-norm
(`rmsnorm` at N=256), IMROPE's multiplies, EXP_ROM interpolation, the section-3
sigmoid ROM, and the reciprocal stage, and gated the `MACS` decision on real
numbers. "Synthesising `rmsnorm` at N=256 is the single biggest unknown."

What do the auxiliary units actually cost on `xcvu33p-fsvh2104-2L-e` at
3.333 ns?

## 2. The answer

**The row lands at ~50 DSP, above the 15-40 band, and only because the reused
`rmsnorm` is width-narrowed. As shipped, `rmsnorm` at N=256 is 78 DSP at
138.4 MHz -- disqualifying on both counts** (a fifth of C's whole 384-DSP MAC
array, and 2.2x off the clock). With it, the whole-die DSP sum crosses the 90%
congestion line (89.2-90.3%); narrowed, the die sits at 87.2-88.2%.
[**Superseded 2026-08-26: narrowed, the die sits at 90.5%-91.9%** -- over the
line anyway, on later measurement of B's scalar path and conv. The conclusion
that narrowing is mandatory is unchanged and reinforced.] The
narrowing is therefore mandatory, not an optimization. Full roll-up in C spec
section 3.8.

| unit | DSP | LUT | FF | Fmax (synth, 0.85 V) |
|---|---|---|---|---|
| `rmsnorm.vhd`, N=256, as shipped | **78** | 11,766 | 4,694 | **138.4 MHz** |
| width-narrowed skeleton (`sim/micro/micro_rmsn_narrow.vhd`) | **18** | 385 | 248 | 278.9 MHz |
| `rope.vhd` (defaults; the rotation kernel) | 8 | 2,330 | 1,684 | **206.4 MHz** |
| sigmoid cone, Q15 out (`sim/micro/micro_sig_cone.vhd`) | 8 | 1,062 | 121 | 343.4 MHz |
| `divider_rs`, NW=44 / DW=28 (the reciprocal) | 0 | 76 | 152 | 681.7 MHz |

(The exp cone's 8 DSP was measured 2026-08-24, see
`2026-08-24_vccint-derate-and-exp-cone.md`.)

## 3. The procedure

Harness: `sim/ooc_micro.tcl` (OOC synth + opt + DSP48E2 census reconciled
against the utilization count), part `xcvu33p-fsvh2104-2L-e`, period 3.333 ns.

1. `rmsnorm` synthesized **as-is** at `g:N=256` first -- the reuse-verbatim
   baseline the spec assumed.
2. Attribution of the 78: the census names are anonymized (`ARG__*`) so the
   attribution is by reading the RTL's multiply sites, not the netlist: three
   64x64 `mulshr` calls in the pipelined rsqrt (S_RQ_I1M1..I2M3), the 64-bit
   RAW/EMIT multiply chains, and `scale_mul(raw, 1, shift_total)` at
   `rmsnorm.vhd:355` -- a literal multiply-by-one, the identical waste
   `bfp_pack.vhd`'s 2026-07-27 header documents removing.
3. The narrowed form priced as a **skeleton** (the `micro_b_lane` method for
   units that do not exist yet): real multiply shapes (17x17, 3x 32x32/34x32,
   17x32, 48x17, shift-only emit), operands registered, control a free-running
   counter so nothing folds, XOR-fold digest so nothing prunes. Bounds that
   make the narrowing lossless: the rsqrt runs on a Q30-normalized mantissa,
   so `smant/y/y2/my2` fit s32 and `diff = 3<<30 - my2` fits s34 -- the same
   pattern as `attention_ml`'s proven 64/64 -> 52/24 divider narrowing.
4. `rope.vhd` and the sigmoid cone synthesized to price the IMROPE kernel and
   the gate; the sigmoid micro was GHDL-checked against sigmoid values at 11
   points (0 -> 16384, +/-4096 -> 23955/8813, saturations, +/-1 LSB) before
   synthesis.
5. `divider_rs` at the reciprocal widths (NW=44, DW=28) to confirm 0 DSP.

Logs: `sim/ooc_micro/util_*.rpt`, `dsp_*.txt`; batch driver was a scratchpad
script (results transcribed into C spec section 3.8).

## 4. The evidence

```
MICRO rmsnorm_N256        DSP=78 (census 78)  LUT=11766  FF=4694  WNS=-3.890  Fmax=138.4 MHz
MICRO micro_rmsn_narrow   DSP=18 (census 18)  LUT=385    FF=248   WNS=-0.253  Fmax=278.9 MHz
MICRO rope                DSP=8  (census 8)   LUT=2330   FF=1684  WNS=-1.511  Fmax=206.4 MHz
MICRO micro_sig_cone      DSP=8  (census 8)   LUT=1062   FF=121   WNS= 0.421  Fmax=343.4 MHz
MICRO divider_rs_NW44_DW28 DSP=0 (census 0)   LUT=76     FF=152   WNS= 1.866  Fmax=681.7 MHz
```

Whole-die consequence (A post-reclaim 1,914 + C 384+aux + B 138-152 + D
24-40, of 2,880):

```
aux = 110 (rmsnorm as shipped) : 2,570-2,600 = 89.2-90.3%   AT/OVER the 90% line
aux =  50 (rmsnorm narrowed)   : 2,510-2,540 = 87.2-88.2%
```

## 5. Measured and REJECTED - do not retry

- **Reusing `rmsnorm.vhd` verbatim for C's QK-norm.** 78 DSP / 138 MHz. The
  unit was written for the AXU3EG engine's much slower clock and its widths
  were never the point there. Do not re-synthesize it hoping for a different
  answer; the fix is the narrowing (C spec 3.6), with `engine_shared` keeping
  the original untouched.
- **Budgeting sigmoid via EXP_ROM + divider** was already rejected in C rev 1
  (~3 ms/token); the measured direct SIG_ROM cone is 8 DSP and one
  element/cycle, closing that item.

## 6. Measurement traps hit

- **The DSP census names are anonymized** (`ARG__*`) in this flow, so per-site
  attribution must come from the RTL, not the census. The census still does
  its job (count reconciliation, USE_MULT, AREG/BREG).
- **The narrowed skeleton is NOT a functional rmsnorm.** It prices shapes.
  Quoting its 18 DSP as final before `rmsnorm_rs` exists and passes bit-exact
  GHDL against `rmsnorm.vhd` would be the "agrees with itself" trap; C spec
  3.13 item 1 keeps it open.
- **`rope.vhd`'s 8 DSP partly reflects its resize-to-32 multiplies**; a 16x16
  rewrite may cost 4. The budget keeps 8 (the measured form) rather than the
  hoped-for number.
- Synthesis-only Fmax throughout; the 2026-08-24 C-array work showed routed
  can be far worse and that AREG/BREG registration recovers it. WNS here is a
  screen, not a promise.

## 7. Open, not yet answered

- `rmsnorm_rs` (the real narrowed unit): unwritten, bit-exactness unproven,
  and the skeleton's 278.9 MHz is still shy of 300 -- `MREG` on the 34x32
  Newton stage is the expected fix, unmeasured.
- Whether Vivado shares the three Newton multiplies across FSM states in the
  real unit (the skeleton instantiates them separately, so 18 may be
  pessimistic by a few DSP).
- All numbers are 0.85 V analysis; at the card's 0.717 V the -22.9% derate of
  `2026-08-24_vccint-derate-and-exp-cone.md` applies.
