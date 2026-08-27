# The state drift bound over a 2,048-token sequence for subsystem B's Gated DeltaNet recurrence

Date: 2026-08-26
Build: `ref/gdn_err.c` at this date, `cc -O2 -Wall -Wextra -fopenmp -o gdn_err
gdn_err.c -lm`, gcc x86-64, zero warnings, assertions ON (the file refuses to
build with `-DNDEBUG`). Two new flags added for this task, `--eg-bits` and
`--eg-oracle-real`; everything else untouched, and the pre-edit binary is
reproduced byte-identically on seven existing configurations (see Procedure,
step 0). No Vivado, no RTL change, no service touched. `OMP_NUM_THREADS=6`
throughout because synthesis was running on this box.
Shapes: Qwen3.8-27B GDN, S=128, 48 value heads, 16 key heads, as verified
against the GGUF on 2026-08-24 and recorded in
`2026-08-25_gdn-recurrence-error-bound.md`.
Recipe: §2.1.4 **as amended 2026-08-26** (`d_norm=1 tk0_ed=1 eg0_ed=1`), which
is what `rtl/gdn_recur.vhd` and `ref/gdn_recur_vec.c` carry. `--pinned`
reproduces the superseded form.

## The question

Spec §3.6, verbatim:

> **A recurrence error bound is required, not just per-site rounding.** The
> state is requantized every token (site 11) after a Q15 decay multiply
> (site 6); error compounds through the feedback path in a way C's write-once
> KV cache never faces. §3 must bound the drift over a 2048-token sequence
> against the float reference, and this bound decides whether int16 state
> mantissas (§2.1.1) and Q15 decay (§1.5) survive or need widening. This is
> the hardest deliverable in §3 and the reason it is not being written before
> sections 1-2 are reviewed.

## The answer

**Both survive 2,048 tokens, but not for the reason §2.10 records, and the two
terms are not the same size: the Q15 decay factor is the dominant error in the
loop by 5.7x, not the int16 state.** At the worst real gates, the state
requantization loop contributes 6.9e-4 relative output error at t=2048 while
the Q15 decay contributes **3.9e-3** measured on its own -- a term no previous
run in this repo could see, because the oracle was fed the same quantized decay
factor the fixed path used, so it cancelled exactly. The realistic production
worst case at t=2048 is **~1e-2 worst-head / ~5e-3 mean**, against A's yardstick
of 8% relative weight error for +1.69% perplexity. int16 stands; Q15 stands;
**Q12 does not** (3.2e-2 at the same point, and 1.6e-1 at 8,192 tokens in the
non-contracting regime). Q15 is a requirement, and it is the format with the
least margin in the loop.

> **MISATTRIBUTION, withdrawn same day.** This paragraph originally continued
> "so §1.5's 'cheap insurance' framing is withdrawn". It is not: that clause of
> §1.5 attaches to **beta**, not to the decay, and it has since been measured
> and CONFIRMED. §1.5's decay claim was right all along and this measurement
> agrees with it. See the CORRECTION at the end of this file.

**The shape is a rise-then-plateau in every regime that contracts, and a power
law in the one regime that does not.** Drift rises with a local log-log slope
of +0.3..+0.9 out to t ~ 500-1000 and is then flat to t=8,192 (measured, not
extrapolated). The condition for the plateau is that the state have an
effective memory horizon shorter than the sequence. When neither the gate nor
the delta rule contracts (`eg_q = 32767`, `beta = 0.001`) there is no plateau
inside 8,192 tokens and the error follows a power law whose exponent is set by
the DECAY rounding, not by the state requantization: `t^0.49` when the gate is
exactly 1.0 and site 6 does not round at all, `t^0.86` at any other Q15 code,
and `t^1.00` -- linear -- at Q12.

## The procedure

`ref/gdn_err.c` runs the recurrence three ways over one set of driving inputs:
**ORACLE** in double (the truth), **FLOAT** in IEEE binary32 (the floor an fp32
implementation would have), and **FIXED**, exactly §2.1.4 as amended, `int64_t`
intermediates, every shift through `mv4i_floor_shr`/`mv4i_round_shift`, state in
`--wbits` mantissas with one int8 exponent per column. The golden is a
different number system by construction; no second integer path was built.

Probes, in the order they were run, and what each isolates:

**0. Behaviour preservation of the two new flags.** Before any measurement, the
edited binary was diffed against the pre-edit one on `--tokens 256`,
`--tokens 256 --eg 1.0`, `--eg-worst`, `--wbits 12`, `--pinned --fix-init`,
`--inq-real`, and a stacked-adversarial config: all seven stdout-identical. Then
two controls on the new flags themselves: `--eg 1.0 --eg-oracle-real` must be
identical to `--eg 1.0` (1.0 is exact in Q15, so there is nothing to isolate),
and it is; and `--eg-bits 12` *without* `--eg-oracle-real` must stay near the
baseline (the error cancels), and it does. Without step 0 the new numbers would
not be attributable.

**1. Shape, four regimes, T=2048, dense.** `--csv` writes every token. Regimes:
base (real per-head `exp(g)` drawn from the GGUF table, `beta = sigmoid(N(0,1))`,
iid inputs), `--eg 1.0`, `--eg-worst` (the 48 slowest real heads), and stacked
adversarial. Isolates the growth law from the endpoint value; a single number at
t=2048 cannot distinguish a plateau from the middle of a linear ramp.

**2. `--eg` sweep, 0.1 to 1.0 plus eight points inside the top Q15 code.**
Isolates the gate as a variable. The eight near-1 points test whether `eg = 1.0`
is really the worst gate, which the 2026-08-25 bound assumed.

**3. `--wbits` sweep, W = 10..24, in three regimes.** Isolates the state
mantissa width, the first thing the bound is meant to decide.

**4. Decay precision, ISOLATED.** New. `--eg-bits N` produces the decay factor
at Q<N> and carries it in the Q15 field the datapath expects
(`eg_q = round(eg*2^N) << (15-N)`), so no shift in the recurrence changes and
what is measured is the ROM's output precision -- exactly what §1.5 argues
about. `--eg-oracle-real` keeps the ORACLE on the true double `exp(g)` while the
fixed path gets the quantized one, with every other input still
exact-dequantized. **This is the control the 2026-08-25 document's open list
asks for by name, and it is why that document's numbers are 5.7x low on this
term.** Run at slow gates (where a per-token error can compound), at mixed real
gates, and at fast gates (where it provably cannot).

**5. Mechanism: `--eg 1.0` with `--beta` swept 0.98 down to 0.001.** With the
gate pinned fully open the *only* contraction available is the delta rule's
rank-1 projection. This is the probe that decides whether the plateau is owed to
the decay gate (as §2.10 records) or to `beta`.

**6. The longest-memory regime the format can express**, `--eg 0.99997`
(`eg_q = 32767`, the worst code strictly below 1.0) with `beta = 0.001`, out to
T=8192, with and without the decay isolation. This is the probe that finds the
condition under which the plateau does not exist.

**7. Seed robustness**, seeds 12345/999/31337/4 on the two headline numbers.

No real Qwen3.8-27B GDN activations exist in this repo, so the drive is
synthetic gaussians with the knobs above as the sensitivity sweep. The
per-head `exp(g)` values are NOT synthetic: they are `ref/gdn_eg_qwen3_27b.txt`,
extracted from the GGUF's `ssm_a` / `ssm_dt.bias` tensors at `alpha = 0`.

### The realistic `exp(g)` range, and where it comes from

2,304 real head/layer pairs, `g = ssm_a * softplus(alpha + ssm_dt.bias)` at
`alpha = 0`. `1/(1-eg)` is the head's memory in tokens:

```
p  0  eg=0.000116787  memory        1.0 tokens
p 10  eg=0.620571213  memory        2.6
p 25  eg=0.872677254  memory        7.9
p 50  eg=0.973160786  memory       37.3
p 75  eg=0.997471149  memory      395.4
p 90  eg=0.999314219  memory     1458.2
p 95  eg=0.999523799  memory     2100.0
p 99  eg=0.999730788  memory     3714.5
p100  eg=0.999961773  memory    26159.3

heads with memory > 2048 tokens: 128 of 2304 (5.6%)
heads with memory > 1000 tokens: 341 of 2304
heads whose eg rounds to exactly 1.0 at Q12 (decay LOST entirely):  4
heads whose eg rounds to exactly 1.0 at Q15 (decay LOST entirely):  0
```

**Caveat carried forward from 2026-08-25 and still binding:** this is
`alpha = 0`. In production `alpha` varies per token, `softplus >= 0` and
`ssm_a < 0`, so `g -> 0` and `eg -> 1` is reachable for *any* head. The table is
the typical distribution, not the range; the range is `(0, 1]`. That is why the
`--eg 1.0` and `eg_q = 32767` runs exist.

## The evidence

### 1. Drift versus token index, T=2048, W=16 (the deliverable)

Worst-head relative output error. Every column is a measured run, `--csv`, one
row per token, subsampled here. Columns 4 and 5 have the decay error isolated
(`--eg-oracle-real`) at the 48 slowest real gates; every other column has it
cancelling, as all pre-2026-08-26 runs did.

```
     t     base-mixed         eg=1.0       eg-worst  Q15decay-slow  Q12decay-slow        stacked
     1     1.3727e-03     2.5061e-04     2.5061e-04     2.5061e-04     2.5061e-04     5.5507e-04
     2     4.1520e-04     7.4574e-04     8.0358e-04     8.0357e-04     7.8032e-04     9.8554e-04
     4     3.9557e-04     1.9355e-04     1.9153e-04     1.9294e-04     2.9803e-04     1.8388e-03
     8     2.5969e-04     2.5812e-04     2.3398e-04     2.4023e-04     4.4374e-04     2.5410e-03
    16     2.6543e-04     2.9528e-04     2.8689e-04     3.2102e-04     1.1015e-03     2.6953e-03
    32     3.6388e-04     3.0060e-04     2.9364e-04     4.0298e-04     2.0355e-03     2.1994e-03
    64     3.0412e-04     2.8473e-04     3.0598e-04     5.5753e-04     4.5416e-03     3.6139e-03
    96     3.7014e-04     4.2310e-04     4.4824e-04     7.9721e-04     6.8962e-03     4.3632e-03
   128     3.5831e-04     3.9703e-04     4.6351e-04     1.0860e-03     8.2698e-03     3.2775e-03
   192     4.0583e-04     4.6047e-04     5.0604e-04     1.4497e-03     1.1252e-02     3.0082e-03
   256     4.3513e-04     4.7343e-04     4.9995e-04     1.8954e-03     1.4483e-02     5.3193e-03
   384     5.1110e-04     5.1769e-04     5.5584e-04     2.5986e-03     2.1507e-02     7.5898e-03
   512     4.5275e-04     5.2107e-04     5.2860e-04     2.9160e-03     2.6602e-02     2.4323e-03
   768     6.7646e-03     5.6211e-04     5.8440e-04     3.5866e-03     3.0851e-02     5.0572e-03
  1024     5.2820e-04     6.2036e-04     6.0025e-04     3.4305e-03     3.0980e-02     5.3662e-03
  1280     4.9894e-04     6.1412e-04     6.3931e-04     3.8363e-03     3.1862e-02     6.9486e-03
  1536     4.8836e-04     5.7385e-04     6.0824e-04     3.5364e-03     3.2458e-02     5.0372e-03
  1792     1.8401e-03     5.9962e-04     7.0562e-04     3.6236e-03     2.9805e-02     4.9148e-03
  2048     5.1679e-04     6.7776e-04     6.9141e-04     3.9148e-03     3.1597e-02     7.6863e-03
```

Worst-head relative STATE error, same runs. Note it is smoother than the output
error, because it has no near-zero denominator (see Traps):

```
     t     base-mixed         eg=1.0       eg-worst  Q15decay-slow  Q12decay-slow        stacked
     1     4.6398e-05     4.6799e-05     4.6799e-05     4.6799e-05     4.6799e-05     5.1366e-05
     4     1.5781e-04     1.4481e-04     1.4061e-04     1.4088e-04     2.5410e-04     1.8851e-03
    16     1.6429e-04     1.5661e-04     1.5967e-04     2.0902e-04     9.5225e-04     2.5166e-03
    64     2.4123e-04     2.3754e-04     2.5885e-04     5.7449e-04     4.1095e-03     2.7812e-03
   128     3.2229e-04     3.2199e-04     3.7337e-04     1.0226e-03     7.8031e-03     2.8657e-03
   256     3.8287e-04     3.8761e-04     4.4613e-04     1.7938e-03     1.5086e-02     2.9134e-03
   512     4.3668e-04     4.5463e-04     5.2952e-04     2.7979e-03     2.3674e-02     2.8749e-03
  1024     4.9663e-04     4.9720e-04     6.2370e-04     3.4886e-03     2.9691e-02     2.9917e-03
  1536     4.8118e-04     4.9760e-04     6.2192e-04     3.4809e-03     3.1235e-02     2.9124e-03
  2048     4.8887e-04     5.0653e-04     6.5223e-04     3.5055e-03     3.0044e-02     2.8910e-03
```

**The plateau is measured past 2,048, not extrapolated.** `--eg 1.0` run to
T=8192 and Q15-decay-isolated run to T=8192:

```
eg=1.0, W16:        t=1024  6.204e-4   t=2048  6.778e-4   t=4096  5.797e-4   t=8192  6.330e-4
Q15 decay, slow:    t=1024  3.431e-3   t=2048  3.915e-3   t=4096  3.842e-3   t=8192  4.065e-3
```

Local log-log slope `dlog(out_rel_max)/dlog(t)` for the Q15-decay-isolated run,
which is the steepest of the contracting curves: +0.32 (t=8-16), +0.47 (32-64),
+0.96 (64-128), +0.80 (128-256), +0.40 (384-512), **-0.16 (768-1024), +0.08
(1024-1536), -0.03 (2048-4096), +0.08 (4096-8192)**. Rise, then flat.

### 2. Sensitivity to the state mantissa width (`--wbits`), T=2048

`out_rel_max / state_rel_max`, and `sat16` events over the whole run.

```
  W | base (real mixed eg)        | eg=1.0                      | stacked adversarial
 10 | 8.257e-02/7.649e-02 s=7997  | 4.198e-02/3.121e-02 s=10953 | 3.987e-01/8.499e-02 s=9859
 12 | 1.427e-02/1.491e-02 s=2068  | 1.029e-02/7.865e-03 s=2636  | 1.033e-01/2.251e-02 s=2531
 13 | 5.604e-03/5.473e-03 s=936   | 5.346e-03/3.933e-03 s=1310  | 2.843e-02/1.132e-02 s=1348
 14 | 2.235e-03/2.216e-03 s=491   | 2.614e-03/1.976e-03 s=683   | 2.161e-02/5.910e-03 s=603
 15 | 1.146e-03/1.008e-03 s=266   | 1.214e-03/1.007e-03 s=341   | 8.316e-03/3.482e-03 s=333
 16 | 5.168e-04/4.889e-04 s=113   | 6.778e-04/5.065e-04 s=183   | 7.686e-03/2.891e-03 s=177
 17 | 2.910e-04/2.529e-04 s=63    | 4.435e-04/2.623e-04 s=80    | 6.096e-03/2.709e-03 s=94
 18 | 2.235e-04/1.523e-04 s=30    | 3.132e-04/1.576e-04 s=42    | 6.037e-03/2.667e-03 s=31
 20 | 2.021e-04/1.143e-04 s=10    | 2.842e-04/1.075e-04 s=18    | 6.059e-03/2.654e-03 s=12
 24 | 2.025e-04/1.138e-04 s=0     | 2.734e-04/1.030e-04 s=1     | 6.072e-03/2.653e-03 s=0
```

Clean 2x per bit from W10 to W17, then a floor at ~2.0e-4 (base) and ~6.0e-3
(stacked) from W18 up. W16 sits 2.5x above the floor in the base regime and
1.27x above it in the stacked one. The floor is present in the STATE error as
well (1.14e-4 at both W20 and W24), so it is set by the 16-bit working formats
the spec pins at sites 7/9/12 independently of the state width, exactly as
2026-08-25 found. `se_new` left int8 range **0** times in every run reported in
this document.

### 3. Sensitivity to the decay gate `eg` (the dominant variable), T=2048, W=16

Decay error cancelling, so this is the state loop's own response to the gate:

```
eg=0.100   out_max=1.971e-04       eg=0.999     out_max=6.183e-04
eg=0.500   out_max=2.205e-04       eg=0.9999    out_max=7.250e-04
eg=0.900   out_max=2.467e-04       eg=0.99997   out_max=8.776e-04
eg=0.990   out_max=3.908e-04       eg=1.0       out_max=6.778e-04
```

Monotone in the gate over four orders of magnitude of memory, spanning only
4.5x -- **and then it turns over**. Eight points inside the top Q15 code:

```
eg=0.99990    out_max=7.2504e-04   (eg_q = 32765)
eg=0.99995    out_max=7.9666e-04   (eg_q = 32766)
eg=0.999969   out_max=8.7765e-04   (eg_q = 32767)  <- WORST
eg=0.99998    out_max=8.7765e-04   (eg_q = 32767, identical, as it must be)
eg=0.999985   out_max=6.7776e-04   (eg_q = 32768)
eg=0.99999    out_max=6.7776e-04   (eg_q = 32768)
eg=0.999995   out_max=6.7776e-04   (eg_q = 32768)
eg=1.0        out_max=6.7776e-04   (eg_q = 32768)
```

**`eg = 1.0` is NOT the worst gate; `eg_q = 32767` is, by 1.30x.** The reason is
in the datapath, not the statistics: at `eg_q = 32768 = 2^15` site 6's
`round_shift(smant * eg_q, 13)` degenerates to an exact left shift by 2 and the
decay contributes **no rounding error at all**. Every other code rounds. The
2026-08-25 bound took `eg = 1.0` as "the worst the gate can do" and therefore
took its bound at the one gate value where site 6 is exact.

### 4. Sensitivity to decay precision, ISOLATED (the new measurement)

`--eg-oracle-real`, so the ORACLE keeps the true double `exp(g)`. T=2048, W=16,
`out_rel_max / state_rel_max`:

```
eg fmt | eg-worst (slow heads)   | base (mixed real eg)    | eg=0.99 (fast heads)
Q8     | 9.218e-02 / 8.388e-02   | 4.019e-01 / 3.908e-01   | 1.109e-01 / 9.343e-02
Q10    | 9.218e-02 / 8.388e-02   | 1.009e-01 / 9.371e-02   | 1.707e-02 / 1.422e-02
Q11    | 6.985e-02 / 6.033e-02   | 5.390e-02 / 5.129e-02   | 1.707e-02 / 1.422e-02
Q12    | 3.160e-02 / 3.004e-02   | 3.085e-02 / 2.847e-02   | 7.725e-04 / 6.410e-04
Q13    | 1.572e-02 / 1.467e-02   | 1.279e-02 / 1.187e-02   | 7.725e-04 / 6.410e-04
Q14    | 7.101e-03 / 7.089e-03   | 6.376e-03 / 6.953e-03   | 7.725e-04 / 6.410e-04
Q15    | 3.915e-03 / 3.505e-03   | 3.267e-03 / 3.229e-03   | 7.725e-04 / 6.410e-04
```

Clean 2x per bit from Q11 to Q15 at the slow gates, **and no floor is reached at
Q15** -- unlike the state width, which floors at W18. Q15 is the term with the
least margin in the loop.

The control that shows why nobody saw this before, same Q12, same gates, but
with the oracle also quantized (i.e. every pre-2026-08-26 run):

```
# eg_bits=12 (Q12 decay) eg_oracle=quantized (decay error cancels)
# eg: worst-real  min=0.999755859 max=1.000000000
    2048     4.7418e-04     4.9597e-04     4.9416e-04     6.9141e-04
```

**6.9e-4 instead of 3.2e-2, a factor of 46.** Note also `max=1.000000000` in
that header: a head whose true `exp(g)` is 0.99976 has rounded up to exactly
1.0 at Q12 and lost its decay entirely -- and because the oracle was handed the
same 1.0, the run reports no error for it.

Against the same run with the isolation on:

```
# eg_bits=15 (Q15 decay) eg_oracle=REAL (decay error isolated)
# eg: worst-real  min=0.999672668 max=0.999961773
    1792     1.9638e-03     3.4783e-03     1.9599e-03     3.6236e-03     7.2102e-06
    1920     1.9655e-03     3.4291e-03     2.0035e-03     4.3820e-03     7.9914e-06
    2048     1.9704e-03     3.5055e-03     2.0190e-03     3.9148e-03     7.4233e-06
# sat16 events: 124   se_new out-of-int8 events: 0
# worst head 31: eg=0.999709804  state_rel=3.5055e-03  out_rel=3.9148e-03  (fp32 out_rel=4.9469e-06)
```

The fp32 column is the control on the metric: 7.4e-6, i.e. the fixed path sits
~500x above an fp32 loop, and both are flat.

**Decay precision only matters where the gate is slow, and that is measured, not
argued.** At `eg = 0.99` (memory 100 tokens) Q12 and Q15 are identical to four
digits. Testing a fast gate at a deliberately bad quantization point rather than
a lucky one:

```
eg=0.900135  Q12 out_max=2.6758e-04     Q15 out_max=2.6758e-04    (identical)
eg=0.990135  Q12 out_max=7.2679e-03     Q15 out_max=6.3132e-04    (11.5x)
```

So the crossover is already at `eg ~ 0.99` -- a memory of 100 tokens is long
enough for Q12 to hurt by an order of magnitude. That is 40% of the model's
heads (910 of 2,304 have `eg > 0.99`), not a tail.

### 5. Mechanism: the plateau is owed to `beta`, not to the decay gate

`--eg 1.0`, so the gate contributes exactly zero contraction and the only
contraction available is the delta rule's `(I - beta k k^T)`. Mean state norm
and mean absolute state error, T=2048:

```
beta      ||s||@64    ||s||@512   ||s||@2048  abs_err@2048  out_rel_max
0.98    7.8761e+01   1.2427e+02   1.2556e+02    5.2548e-02   5.3358e-04
0.5     4.1332e+01   7.2046e+01   7.3914e+01    3.2994e-02   5.5785e-04
0.1     8.8317e+00   2.1426e+01   2.8671e+01    2.7115e-02   1.2042e-03
0.02    1.7992e+00   4.9246e+00   8.8190e+00    9.7808e-03   1.3013e-03
0.005   4.5179e-01   1.2685e+00   2.4645e+00    2.7866e-03   1.3533e-03
0.001   9.0998e-02   2.5728e-01   5.1171e-01    6.1923e-04   1.6024e-03
```

With the gate fully open, the state norm still saturates for `beta >= 0.1` and
still bounds the relative error at ~1e-3 for every `beta` down to 0.001. The
delta rule, not the decay, is what makes the recurrence contractive.

The absolute numbers behind the `eg = 1.0` plateau, which is where the
2026-08-25 mechanism is refuted:

```
     t     abs_err       ||s||      ratio  abs/sqrt(t)  nrm/sqrt(t)
     1  2.1594e-04  5.5755e+00 3.8220e-05   2.1594e-04   5.5755e+00
    64  1.0084e-02  4.5114e+01 2.2344e-04   1.2605e-03   5.6392e+00
   256  2.6229e-02  7.1673e+01 3.6608e-04   1.6393e-03   4.4796e+00
  1024  3.9304e-02  8.2165e+01 4.7842e-04   1.2283e-03   2.5677e+00
  2048  3.9789e-02  8.2318e+01 4.8341e-04   8.7921e-04   1.8190e+00
  4096  3.9933e-02  8.2192e+01 4.8592e-04   6.2396e-04   1.2843e+00
  8192  3.9749e-02  8.2320e+01 4.8292e-04   4.3917e-04   9.0951e-01
```

Both the numerator and the denominator saturate independently (`||s||` is
82.165 / 82.318 / 82.192 / 82.320 at t = 1024/2048/4096/8192). `nrm/sqrt(t)`
falls by 6x, so `||s||` is **not** growing as `sqrt(t)`.

### 6. The one regime with no plateau, and the condition that produces it

`eg_q = 32767` (the worst code strictly below 1.0) AND `beta = 0.001`, so
neither contraction mechanism is available. T=8192:

`out_rel_max`. "fitted slope" is a least-squares log-log fit over the 64 CSV
rows with t in [64, 8192] (8,129 of them; the CSV has one row per token);
the endpoint slope over [512, 8192] agrees to within
0.01 in every row, so the fit is not hiding curvature. **The fits are the only
fitted quantities in this document; every tabulated value is measured.**

```
                              t=512      t=1024     t=2048     t=4096     t=8192   fitted slope
eg exactly 1.0 (site 6 exact)  8.445e-4   1.018e-3   1.602e-3   1.998e-3   2.957e-3     t^0.49
eg_q=32767, decay cancelling   1.235e-3   1.962e-3   3.980e-3   6.177e-3   1.362e-2     t^0.86
eg_q=32767, + Q15 decay err    1.241e-3   1.977e-3   4.003e-3   6.378e-3   1.361e-2     t^0.86
eg_q=32767, + Q12 decay err    9.951e-3   1.962e-2   3.901e-2   7.733e-2   1.605e-1     t^1.00
```

Three things to read out of that table, in order of importance:

1. **The exponent is set by the decay, not by the state requantization.** Row 1
   and row 2 differ in nothing but the gate code: 32768, where site 6's
   `round_shift(smant * eg_q, 13)` degenerates to an exact shift, versus 32767,
   where it rounds every token. That one bit of rounding moves the growth law
   from `sqrt(t)` to `t^0.86`. The state width is identical (W16) in both.
2. **Rows 2 and 3 are the same to three digits**, so at `eg_q = 32767` the Q15
   *value* error adds nothing on top of the per-token site-6 *rounding* error
   that is already there. The two decay error sources are not additive; the
   rounding dominates. Q12 (row 4) is large enough to dominate in turn.
3. `||s||` grows as exactly `sqrt(t)` here (`nrm/sqrt(t)` = 1.1319e-2,
   1.1364e-2, 1.1355e-2, 1.1284e-2, 1.0971e-2, 1.0568e-2 at
   t = 1/64/128/512/2048/4096) while the absolute error grows faster. **This is
   the only measured regime where the 2026-08-25 sqrt(t)-over-sqrt(t) mechanism
   is actually the operative one**, and it is the regime where that mechanism
   fails to give a bound.

At t=2048 all four are still tolerable (1.6e-3, 4.0e-3, 4.0e-3, 3.9e-2) but
only Q15 stays tolerable at 8,192: Q12 reaches **16%**.

### 7. Worst case for the verdict, T=2048, decay error NOT cancelling

`eg_q = 32767`, `beta = 0.02`, `rho_k = rho_v = 0.9`, 2% of v channels at 30x,
`--eg-bits N --eg-oracle-real`:

```
W16, Q15   out_max=1.9606e-02  out_mu=4.2223e-03  state_max=4.4684e-03
W18, Q15   out_max=6.1785e-03  out_mu=1.3672e-03  state_max=2.7342e-03
W20, Q15   out_max=6.1738e-03  out_mu=1.1831e-03  state_max=2.7070e-03
W16, Q12   out_max=7.4665e-02  out_mu=3.4498e-02  state_max=3.6190e-02
```

And the realistic-production composite (real mixed per-head `exp(g)`, realistic
`beta = sigmoid(N(0,1))`, correlated inputs `rho = 0.9`, Q15 decay isolated,
W16), which is the number to quote:

```
mixed real eg    t=2048  out_max=7.9665e-03  out_mu=1.3034e-03  state_max=8.7389e-03
48 slowest eg    t=2048  out_max=9.4918e-03  out_mu=5.2822e-03  state_max=9.5610e-03
```

### 8. Seed robustness

```
Q15 decay isolated, eg-worst, T=2048:  3.915e-3 (12345)  4.352e-3 (999)  3.858e-3 (31337)  3.630e-3 (4)
eg = 1.0, T=2048:                      6.778e-4 (12345)  6.061e-4 (999)  6.093e-4 (31337)  5.978e-4 (4)
```

Spread under 1.2x. The headline numbers are not seed artifacts.

### 9. Reproduction

Per-token CSVs live in this session's scratchpad, which is not durable. The
command lines are, and every table above regenerates from them in seconds
(a T=2048 run is ~4 s at `OMP_NUM_THREADS=6`; the whole document is ~15 min).
From `ref/`, after `cc -O2 -Wall -Wextra -fopenmp -o gdn_err gdn_err.c -lm`:

```sh
# 1  shape, T=2048, dense
./gdn_err --tokens 2048 --csv base.csv
./gdn_err --tokens 8192 --eg 1.0 --csv eg1.csv
./gdn_err --tokens 2048 --eg-worst --csv egworst.csv
./gdn_err --tokens 2048 --eg 1.0 --beta 0.02 --rho-k 0.9 --rho-v 0.9 --outlier 0.02 --csv stacked.csv
# 2  gate sweep, and the eight points inside the top Q15 code
for e in 0.100 0.500 0.900 0.990 0.999 0.9999 0.99997 1.0; do ./gdn_err --tokens 2048 --eg $e; done
for e in 0.99990 0.99995 0.999969 0.99998 0.999985 0.99999 0.999995 1.0; do ./gdn_err --tokens 2048 --eg $e; done
# 3  state mantissa width
for w in 10 12 13 14 15 16 17 18 20 24; do ./gdn_err --tokens 2048 --wbits $w; done
# 4  decay precision, ISOLATED (the new measurement)
for b in 8 10 11 12 13 14 15; do ./gdn_err --tokens 2048 --eg-worst --eg-bits $b --eg-oracle-real; done
./gdn_err --tokens 2048 --eg-worst --eg-bits 12                    # the cancelling control
./gdn_err --tokens 2048 --eg 0.990135 --eg-bits 12 --eg-oracle-real  # bad quant point, fast gate
# 5  mechanism: gate fully open, only beta can contract
for b in 0.98 0.5 0.1 0.02 0.005 0.001; do ./gdn_err --tokens 2048 --eg 1.0 --beta $b; done
# 6  the regime with no plateau
./gdn_err --tokens 8192 --eg 0.99997 --beta 0.001 --csv nodq.csv
./gdn_err --tokens 8192 --eg 0.99997 --beta 0.001 --eg-bits 15 --eg-oracle-real --csv q15.csv
./gdn_err --tokens 8192 --eg 0.99997 --beta 0.001 --eg-bits 12 --eg-oracle-real --csv q12.csv
./gdn_err --tokens 8192 --eg 1.0     --beta 0.001 --csv eg1b001.csv
# 7  the two numbers to quote
./gdn_err --tokens 2048 --eg-bits 15 --eg-oracle-real --rho-k 0.9 --rho-v 0.9
./gdn_err --tokens 2048 --eg-worst --eg-bits 15 --eg-oracle-real --rho-k 0.9 --rho-v 0.9
```

The CSV columns are
`t,state_rel_mean,state_rel_max,out_rel_mean,out_rel_max,f32_state_rel_max,f32_out_rel_max,state_abs_err_mean,state_nrm_mean`.
The last two are absolute and were added for this task: a flat *relative* error
is equally consistent with a bounded absolute error and with an absolute error
growing at exactly the rate the state norm grows, and only those columns tell
the two apart. That distinction is what refutes the 2026-08-25 mechanism.

## Verdict

**int16 state mantissas: SURVIVE, unconditionally at 2,048 tokens.** Worst
measured contribution from the state loop alone is 6.9e-4 (slow real gates) and
8.8e-4 (worst Q15 gate code), flat from t ~ 1000 through t = 8192. Even the
non-contracting `beta = 0.001` regime reaches only 4.0e-3 at t=2048. Every 2
bits below 16 costs ~4x, and W18 buys 2.5x in the base regime and 3.2x in the
adversarial one -- but from 2.0e-2 to 6.2e-3, both of which are one to two
orders below A's +1.69%-perplexity yardstick. §2.10's widening contingency does
not fire, so §2.8's DSP48E2 co-fit and §2.3's traffic numbers stand.

**Q15 decay: SURVIVES, conditionally, and it is the binding term.** 3.9e-3 at
the slowest real gates at t=2048, ~5x the state loop's own contribution, with no
floor reached at Q15 and 2x available per additional bit. The condition is
precisely: **the drift bound holds while the state's effective memory horizon is
shorter than the sequence**, i.e. while `min(1/(1-eg), horizon(beta))` is less
than T. When both exceed T the drift is a power law rather than a plateau, and
Q15 keeps that power law's exponent at 0.86 and its t=2048 value at 4.0e-3,
where Q12 takes it to 1.00 and 3.9e-2.

**Q12 decay: DOES NOT SURVIVE.** 3.2e-2 at slow gates and 7.5e-2 stacked at
t=2048, growing **linearly** to 1.6e-1 by t=8192 in the non-contracting regime,
and it destroys 4 of the model's 2,304 heads outright by rounding their
`exp(g)` up to exactly 1.0. ~~§1.5's characterisation of Q15 as "cheap
insurance, not a requirement, §3 may argue it back down with an error analysis"
is **withdrawn by this error analysis**~~ -- **WITHDRAWN, misattribution: that
clause is about beta, not the decay; see the CORRECTION at the end.** §1.5's
own decay claim ("worth a table regeneration", for the compounding reason) is
CONFIRMED by the numbers above. Q15 is a requirement. Q16 or Q17 would
still buy 2x per bit if the decay ever needs to be tightened, which is the
opposite of where §2.10 expected the next bit to be spent.

## Measured and REJECTED (do not retry)

- **"`eg = 1.0` is the worst gate."** Rejected, 1.30x. `eg_q = 32768` makes
  site 6 an exact shift, so it is the single gate value with zero decay rounding.
  The worst gate is `eg_q = 32767` (8.78e-4 against 6.78e-4). Any future bound
  taken at `--eg 1.0` is taken at a lucky point; use `--eg 0.99997`.
- **"The state norm grows as sqrt(t) and the noise grows as sqrt(t), so the
  ratio saturates"** (the 2026-08-25 mechanism). Rejected in the regime it was
  claimed for: at `eg = 1.0` with realistic `beta` the state norm SATURATES
  (82.2 at t=1024 and 82.3 at t=8192) and so does the absolute error
  independently; `nrm/sqrt(t)` falls 6x. The sqrt(t)-over-sqrt(t) picture is
  only correct at `beta ~ 1e-3`, and there it does not produce a plateau at all.
  The correct mechanism is the delta rule's rank-1 projection, whose strength is
  set by `beta`, not by the gate.
- **Widening the state past W16 as the answer to this bound.** W18 costs
  12.5% more state traffic to move the realistic worst case from 9.5e-3 to
  roughly 3e-3, while one extra bit on the DECAY factor buys the same 2x on a
  term that is 5.7x larger. If a bit is ever spent, spend it on `exp(g)`.
- **W12 and below.** 1.43e-2 base, 1.03e-1 stacked, with 2,068 `sat16` events
  against W16's 113. W10 reaches 40% in the stacked regime. Stays rejected.
- **Measuring decay precision without `--eg-oracle-real`.** The error cancels
  exactly: Q12 reads 6.9e-4 instead of 3.2e-2, a factor of 46, and a head that
  has lost its decay entirely reports zero error. Every number about `eg`
  precision produced before 2026-08-26 in this repo is this measurement.
- **Estimating the decay term as `(1 + eps)^t`.** The 2026-08-25 CLOSED section
  computes +13% at 4,096 tokens from a measured 3.04e-5 relative `exp_q` error.
  The direct measurement is 3.8e-3 at 4,096 -- about **34x lower**. The
  compounding formula tracks the worst single contribution's age, whereas the
  state is a weighted sum over all ages and the metric is an RMS over it. The
  formula is a valid upper bound and a bad estimate; do not quote it as one.

## Measurement traps hit

- **`out_rel_max` has a near-zero denominator and spikes.** The base run reads
  6.76e-3 at t=768 and 1.84e-3 at t=1792 against a 5e-4 plateau either side.
  These are not fixed-point events: the **fp32** column spikes at the same
  tokens by the same factor (1.70e-5 against a 4.9e-7 floor at t=768, 34x), and
  `state_rel_max` does not move at all (4.809e-4 at t=768 against 4.808e-4 at
  t=767). One head's output norm passed near zero. Read `state_rel_max`, or the
  mean columns, when the question is about the loop; `out_rel_max` alone will
  manufacture a 13x transient out of nothing. This is why both metrics and the
  fp32 control are reported side by side above.
- **A tool that quantizes an input for BOTH number systems cannot measure that
  input's format.** This is the whole reason the decay term was missed for a
  day. `--inq exact` is the right control for isolating the *feedback path*, and
  it is exactly the wrong control for asking whether a *format* is adequate. The
  general rule: for every format under test, check which side of the comparison
  it appears on. Here `eg` appeared on both.
- **`--eg-bits` had to preserve the datapath.** The obvious implementation --
  change the Q15 shift at site 6 to Q<N> -- would have changed the alignment of
  every downstream grid and measured a different recipe. Carrying the coarse
  value in the Q15 field (`round(eg*2^N) << (15-N)`) keeps every shift identical
  and isolates the ROM's output precision, which is what §1.5 is about. The
  `--eg 1.0 --eg-oracle-real` control (must be a no-op, and is) is what confirms
  the plumbing.
- **Picking a lucky test value hides the effect.** `eg = 0.99` reports Q12 and
  Q15 as identical to four digits, which reads as "decay precision does not
  matter at fast gates". It does not: 0.99 happens to sit within 1e-5 of a Q12
  code. At `eg = 0.990135` the same comparison is 11.5x. Always test a
  quantization format at a deliberately bad point for the format.
- **The plateau is a property of the regime, not of the recurrence.** Reporting
  the base-regime curve alone would have supported "drift always saturates". It
  took pinning `eg_q = 32767` AND `beta = 0.001` together to find a regime with
  no plateau inside 8,192 tokens. Either knob alone still saturates.
- **A 2,048-token run costs 4 seconds.** There was never a reason to extrapolate
  from a short run, and nothing in this document is extrapolated. The only fitted
  quantities are the four power-law exponents in section 6, and they are
  labelled as fits over measured points.

## Open, not yet answered

- **Is `beta = 0.001` reachable in production?** The verdict's condition turns
  on it, and it is unmeasured. `beta = sigmoid(W x)` requires a pre-activation
  of about -6.9, which is large but not absurd. The per-head `beta` distribution
  has never been extracted from the GGUF the way `exp(g)` was, and it could be:
  the same `gguf-py` path that produced `ref/gdn_eg_qwen3_27b.txt` would give
  the `b_proj` bias distribution, which bounds `beta` at `x = 0` exactly as the
  `exp(g)` table bounds the gate at `alpha = 0`. **This is the single highest
  value follow-up in this document** and it is a couple of hours.
- **Real activation drive.** Still none in this repo; the golden vectors are
  stories260K. Everything here is synthetic gaussians with real `exp(g)` values.
  The production bound lies between the composite 9.5e-3 and the stacked 2.0e-2.
- **Whether `exp_q`'s own approximation error rides on top of the Q15
  quantization measured here.** This document injects `eg` as a value quantized
  to Q<N>; it does not run `fx.h`'s `exp_q` kernel. The 2026-08-25 CLOSED
  section measured that kernel at 1.00 LSB of Q15 in the band that matters, i.e.
  at the quantization floor, so the two should coincide -- but they have not
  been measured in the same run. Wiring `exp_q` into `gdn_err.c` behind a flag
  would close it.
- **`k` through the actual fixed L2-norm recipe.** Still owed from the
  2026-08-25 CORRECTION and still not done. Same class of defect as the `eg` one
  closed here: `--inq exact` feeds the oracle the same dequantized `k`, so no
  number in either document can see a normalizer error of any size.
- **Q16/Q17 decay.** The 2x-per-bit is still live at Q15 and was not swept past
  it, because `eg` is a uint16 in §2.1.1 and Q16 would need `0..65536`, i.e. 17
  bits, or a change of representation. Whether that is cheap in the RTL was not
  investigated.
- **The end-to-end acceptability threshold.** Unchanged from 2026-08-25: B's own
  perplexity cost is unmeasured and will stay so until the full B reference
  exists. Everything here is compared against A's format yardstick, which is a
  proxy.

## Corrections to `2026-08-25_gdn-recurrence-error-bound.md`

Appended here rather than by editing that file.

1. **Its open item "Q15 vs Q12 decay factor was not isolated ... at the measured
   error levels it is moot for the verdict" is WITHDRAWN.** It is isolated now
   and it is not moot: it is the largest single term in the loop, 5.7x the state
   requantization it was compared against, and Q12 fails.
2. **Its stated mechanism for boundedness is WITHDRAWN** (see Measured and
   REJECTED). The conclusion it supported is unaffected; the reason given for it
   was wrong, and the regime where the stated reason is actually operative is
   the one regime that does not saturate.
3. **Its "worst the gate can do" is CORRECTED** from `eg = 1.0` to
   `eg_q = 32767`, a 1.30x understatement.
4. Its CLOSED-2026-08-26 `(1+eps)^t` figures (+6%, +13%) are upper bounds that
   overstate the measured value by ~34x. Not wrong, but not estimates.

## Spec edits owed (not made in this task, following the 2026-08-25 precedent)

1. ~~**§1.5**: withdraw "Q15 is cheap insurance, not a requirement; §3 may
   argue it back down with an error analysis".~~ **WITHDRAWN, DO NOT DO THIS.**
   That clause attaches to **beta**, whose Q15 has since been measured as
   genuinely cheap insurance (Q12 costs 1.11x). Acting on this item would have
   deleted a correct sentence. What §1.5 owed was the error analysis it invited,
   and that is now recorded in §1.5 itself. See the CORRECTION at the end.
2. **§3.6**: the state-drift bullet is discharged; mark it done and point here.
3. **§2.10**: append the correction that `eg = 1.0` is not the worst gate and
   that the sqrt(t)/sqrt(t) mechanism it records does not hold.
4. **§2.1.1**: record that `exp_q`'s Q15 output is now the tightest format in
   the recurrence, so that any future format review starts there rather than at
   the state width.

## CORRECTION 2026-08-26 (same day): the "cheap insurance" withdrawal is itself withdrawn

This document withdraws §1.5's "Q15 is cheap insurance, not a requirement" on
the strength of the decay measurement. **That is a misattribution.** Read §1.5
again with the sentence boundaries:

> **Why Q15 for the decay factor is worth a table regeneration:** `exp(g)`
> multiplies the *entire persistent state* once per token. ... Q15 cuts it 8x
> for the cost of regenerating a 257-entry ROM. **beta gets the same treatment
> for uniformity** (it scales the correction term, where error is
> self-limiting -- Q15 is cheap insurance, not a requirement; §3 may argue it
> back down with an error analysis).

The parenthetical sits inside the clause about **beta**, not the decay. So this
document's decay result does not touch it. Worse, beta's precision could not
have been measured by the work above at all: no `--beta-bits` flag existed, and
beta's oracle shares the quantized value by default (`betad[h] = c.inq_real ? b
: (double)bq / 65536.0`), which is the *identical* cancellation that hid the
decay term. `--inq-real` bundles beta with k, q and v, so it cannot isolate it
either.

### So it was measured, with the flags that were missing

Added `--beta-bits` and `--beta-oracle-real`, mirroring the decay pair. The
edited binary is byte-identical to the pre-edit one on four existing configs
including `--eg-bits 12 --eg-oracle-real`. Isolated, 512 tokens, oracle keeps
the true beta:

| `beta_bits` | worst `out_rel` | vs Q16 |
|---|---|---|
| 16 (shipped) | 4.5522e-04 | 1.00x |
| 15 | 4.5649e-04 | 1.00x |
| 14 | 4.6820e-04 | 1.03x |
| 12 | 5.0690e-04 | **1.11x** |
| 10 | 8.0495e-04 | 1.77x |
| 8 | 3.2939e-03 | 7.24x |

against the decay at the same token count:

| `eg_bits` | worst `out_rel` |
|---|---|
| 15 | 2.2327e-03 |
| 12 | 2.1912e-02 (**9.8x**) |

**§1.5 is CONFIRMED, not withdrawn.** Dropping beta from Q16 to Q12 costs 11%
more error; dropping the decay from Q15 to Q12 costs 9.8x. That is precisely
the asymmetry §1.5 predicted and gave the reason for: the decay multiplies the
entire persistent state every token and compounds, while beta scales the
correction term where the error is self-limiting. The error analysis §1.5
invited has now been done, and it comes out the way §1.5 guessed.

What this document DID establish about the decay stands unchanged, and it is
the more important half: the decay's Q15 is a requirement, Q12 fails, and the
oracle-cancellation defect that hid this was real. Verified independently at
t = 256, where the old oracle gives **byte-identical** results at Q15 and Q12
(4.3513e-04 both, the term cancelling exactly) against 1.6145e-03 and
1.4432e-02 with a true-double oracle.

### One more discrepancy, not resolved here

The reference quantizes beta at **Q16** (`llround(b * 65536.0)`, `uint16`), not
the Q15 §1.5 describes. That is the spec audit's finding F8 and is untouched by
this work; `beta_bits = 16` is the shipped behaviour and 15 is what the spec
text says.

### The trap, stated generally

**A finding about one quantity was applied to a sentence about another because
they share a number.** Both are "Q15", both are in §1.5, and both are about
quantization -- so the decay result read as if it settled the beta claim. It
does not, and the two go in opposite directions. Before withdrawing a spec
sentence, check which noun its clause attaches to.
