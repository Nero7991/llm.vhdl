# How to measure what subsystem B's fixed-point numerics cost the model, and what it takes to do it

**Date:** 2026-08-27
**Model under measurement:** `Qwen3.8-27B-Q4_K_M` (18.97 GB),
`/mnt/storage/llama-dflash2-src` build (llama.cpp PR#27342 fork, `libllama.so.0.1.2`)
**Status:** harness BUILT and VALIDATED; the full measurement is FEASIBLE on this
machine and has NOT been run to completion. Partial results below are labelled
with the exact command that produced them.
**Prompted by:** `docs/2026-08-27_direction-review-fable.md` section 2, which
names this class as the project's highest-probability killer.

---

## 0. The answer, up front

**The measurement is feasible on this machine, today, and the harness is built
and validated.** It needs no llama.cpp fork, no Vivado, no model download and no
service restart: it links the existing prebuilt `libllama.so` read-only and
substitutes fixed-point arithmetic into a running forward pass through the
public `cb_eval` hook.

**Subsystem B's emit chain (the epsilon class, the named suspect) is not the
killer.** Measured on real Qwen3.8-27B activations: 5.34e-4 relative RMS error,
+0.0035 perplexity at 20 chunks, no layer above 3.8e-3. The catastrophic class
that this experiment exists to rule out is ruled out for this site.

**But the perplexity number does not yet resolve.** The 20-chunk scatter band is
+/-0.02 and B sits inside it. Resolving it needs the full 655-chunk corpus, about
ten minutes of GPU time per row.

**One idea in the brief is refuted by measurement.** The proposed cheap proxy --
measure B's relative error offline, convert to a perplexity estimate through a
noise calibration curve -- cannot work. The curve was measured and it is FLAT:
random multiplicative noise of 1e-6, 1e-4, 1e-3, 1e-2, 3e-2 and 1e-1 relative at
the GDN emit output all land inside the same +/-0.02 band, with 3% noise scoring
*better* than baseline. There is nothing to look an error magnitude up in. The
proxy catches catastrophe and ranks design variants; it cannot price them.

**Four sites remain unbuilt**, and one of them has no C reference to build from:
the recurrence (compounding error, `ref/gdn_err.c` has the arithmetic but is
shaped as a program not a library), the conv, the scalar path, and the
**l2norm, for which `ref/` contains no model at all**. The l2norm is the site the
direction review singles out as having no visibility of any kind, and it is now
the single highest-value piece of reference work this measurement needs.

---

## 1. The question, and what quantity answers it

### The question

Subsystem B is bit-exact against its C references and those references are
checked against double-precision oracles. That certifies **transcription** and
**recipe**. It cannot certify the **format choices** -- the epsilon grid, the
block-floating exponents, the int16 state width, the Q12/Q15/Q18 argument grids
-- because a bit-exact comparison makes both sides commit to the same choices.
The two defects that beat the method (`l2norm` recipe collapse 2026-08-25,
rmsnorm epsilon 2026-08-26) were both format-level and both invisible by
construction.

So: **on real Qwen3.8-27B activations, do B's format choices degrade the model,
and by how much.**

### The quantity that answers it

`ppl(B substituted) - ppl(control)` on wikitext-2, where `control` is the same
pipeline perturbed in a way known to be harmless, and BOTH are scored on
identical tokens by identical code. Not `ppl(B) - ppl(baseline)`; section 4
shows why that difference is not the quantity it looks like.

This mirrors `docs/debugging/2026-08-24_subsystem-a-format-perplexity.md`
exactly, with one structural difference that dominates everything below:

| | subsystem A | subsystem B |
|---|---|---|
| where the format lives | the WEIGHTS | the ACTIVATION path |
| so it can be applied | offline, into a GGUF | only inside a running forward pass |
| carries state across tokens | no | **yes, the GDN recurrence** |

The third row is the one that changes the measurement design, not just its
implementation. See section 4.

### What "acceptable" means, numerically

Anchors, all measured, not asserted:

- A's weight format costs **+0.1185 PPL (+1.69%)** and was judged viable. That
  is roughly one quant tier.
- The storage control in that same run cost **+0.0025 (+0.036%)**, which is the
  scale of "free".
- The engine's total quality budget against llama.cpp Q4_K_M is A + B + C + D.
  A has already spent +0.1185 of it.

Proposed thresholds for B, stated before the measurement so the result cannot be
rationalised afterwards:

| B's delta vs control | verdict |
|---|---|
| <= +0.04 PPL (<= 0.6%) | **accept.** B costs a third of what A costs, on a subsystem doing a fraction of the arithmetic. |
| +0.04 to +0.10 | **investigate the dominant site before hardening RTL.** Bisect by site (the harness does this) and price the fix. |
| > +0.10 | **redesign.** B alone would equal A's entire cost and roughly double the deployment's quality tax. |
| > +1.0, or NaN, or a PPL in the tens | the 14x-wrong class. Not a tax, a defect. |

The last row is the one this is really for. A format defect of the kind already
found twice does not cost 2% perplexity; it produces garbage. That failure is
detectable in a **20-chunk run, about 40 seconds of GPU time**, and it does not
need any of the statistical care the rest of this document is about.

**Perplexity is the wrong final metric for this deployment and this is a known,
already-documented limitation.** The A revision of 2026-08-24 re-measured on an
agentic/code corpus with `--kl-divergence` and found the recommendation
*inverted*: mixed precision recovered 22.8% of the damage by wikitext perplexity
and 59.2% by the 99.9% KLD tail. Section 7 says how to extend this harness to
KLD. Perplexity is the right FIRST metric because it is cheap, it is what A was
measured on so the numbers are comparable, and it catches the catastrophic class
immediately.

---

## 2. The measurement design, step by step

Each step names what it controls for. The order is not cosmetic: every step
exists because the step after it is uninterpretable without it.

### Step 0 -- locate subsystem B in the ggml graph, structurally

**Controls for:** intercepting the wrong tensor. Names in a ggml graph are
cosmetic (`node_50`, `norm-0` appears at three different widths); shapes are
what the arithmetic sees.

**Done.** `tools/bfx/gdn_probe --inventory` prints the literal node sequence of
one GDN block. Verified output in section 3.

### Step 1 -- validate the perplexity loop against llama-perplexity

**Controls for:** a harness that scores a different quantity from the reference
implementation. If the baseline does not reproduce, no delta measured through it
means what it says.

**Done, exact match.** Section 3.

### Step 2 -- identity write-back

**Controls for:** the substitution MECHANISM. The callback splits the graph
per node, disables cross-node fusion within a split, round-trips ~3 MB per site
through `ggml_backend_tensor_get`/`_set`, and could alias a view. If any of that
is not free, every substitution number is that non-neutrality plus the format.

**Done, exactly neutral to 10 decimal places.** Section 3.

### Step 3 -- reimplement B's block in DOUBLE and substitute that

**Controls for:** this harness's understanding of the tensor layout and of the
chain's structure. A wrong head stride, a transposed exponent, a weight applied
at the wrong point -- all produce a finite, plausible perplexity. The double
path shares no integer helper with the fixed path, so it is a genuine second
oracle rather than a second transcription.

**Done for the emit chain: 8.1e-8 relative RMS against ggml over 4.5e8 real
activation values.** That is f32 rounding noise. Section 3.

This is the double-oracle rule applied to the harness rather than to a unit, and
it is the step most likely to be skipped. It is also the step that caught the
z-gate misidentification (section 6).

### Step 4 -- establish the scatter band with a noise ladder

**Controls for:** the recurrence. This is the step that has no counterpart in
the subsystem A measurement and it is the reason A's procedure cannot simply be
copied. Without it a substitution result has nothing to be "small" relative to.

**Done at 20 chunks, and the band is +/-0.02 and magnitude-independent.**
Section 3.5. That result also refutes the calibration-curve idea; section 4(c).

### Step 5 -- substitute B's fixed-point path, one site at a time, then composed

**Controls for:** attribution. A composed number says whether B is affordable;
per-site numbers say what to fix. The A measurement's `--only-q4k` attribution
run inverted its own headline conclusion, so per-site attribution is not
optional polish.

Site order, cheapest and most suspect first:

1. `out_rmsnorm` + `z_gate` (the emit chain) -- the named suspect, the epsilon.
2. `gated_delta_net` -- the only site whose error compounds across tokens.
3. `l2norm` -- the site with a documented recipe collapse and, per the review,
   a k path that "no number in either document can see a normalizer error of any
   size" on.
4. `conv`, `silu_qkv`, `beta_sigmoid`, `softplus` -- feed-forward, per-token,
   non-compounding.
5. all sites at once.

### Step 6 -- repeat at full corpus length with a seed ladder

**Controls for:** the chaos floor averaging down. Each chunk is an independent
trajectory (the harness clears the memory between chunks), so the floor should
fall as `1/sqrt(n_chunks)`. Section 4 gives the projected numbers.

---

## 3. What was actually run, and what it printed

Everything in this section is real output from this machine on 2026-08-27. The
Vivado `gdn_emit_chain` PnR run was active throughout; no Vivado was started by
this work and no systemd service was started or stopped.

### 3.0 The subsystem B block, as ggml actually builds it

`./tools/bfx/gdn_probe -m .../Qwen3.8-27B-Q4_K_M.gguf --inventory --ctx 512`

```
==== graph inventory: 3655 nodes in one 512-token graph ====
site             op                 shape                        count / srcs
conv             SSM_CONV           [ 10240,  512,    1,  1] x48   src0[515,10240,1,1] src1[4,10240,1,1]
silu_qkv         SILU               [ 10240,  512,    1,  1] x48   src0[10240,512,1,1]
l2norm           L2_NORM            [   128,   16,  512,  1] x96   src0[128,16,512,1]
softplus         SOFTPLUS           [    48,  512,    1,  1] x48   src0[48,512,1,1]
beta_sigmoid     SIGMOID            [     1,   48,  512,  1] x48   src0[1,48,512,1]
gated_delta_net  GATED_DELTA_NET    [  6144,  640,    1,  1] x48   src0[128,16,512,1] src1[128,16,512,1] src2[128,48,512,1] src3[1,48,512,1] src4[1,48,512,1] src5[128,128,48,1]
out_rmsnorm      RMS_NORM           [   128,   48,  512,  1] x48
z_gate_mul       MUL                [   128,   48,  512,  1] x48
```

48 of each, one per GDN layer; 96 L2_NORM because q and k are normed
separately. Every count matches the architecture, which is the reconciliation
the A measurement's `ssm_a` substring bug says to always do.

The literal node chain of one block:

```
TRACE  0 SSM_CONV        [10240,512,1,1]  conv_output_raw-0    s0[515,10240,1,1] s1[4,10240,1,1]
TRACE  1 SILU            [10240,512,1,1]  conv_output_silu-0
TRACE  3 L2_NORM         [128,16,512,1]   q_conv_predelta-0
TRACE  5 L2_NORM         [128,16,512,1]   k_conv_predelta-0
TRACE 10 SOFTPLUS        [48,512,1,1]     a_softplus-0
TRACE 11 MUL             [48,512,1,1]     gate-0               s1[48,1,1,1]
TRACE 15 SIGMOID         [1,48,512,1]     beta_sigmoid-0
TRACE 17 GATED_DELTA_NET [6144,640,1,1]   node_44              s0..s5 = q k v g beta state
TRACE 18 VIEW            [128,128,48,1]   new_state-0          s0[6144,640,1,1]
TRACE 20 CPY             [786432,1,1,1]   cache_s_l0 (copy of new_state-0)
TRACE 21 VIEW            [128,48,512,1]   attn_output-0        s0[6144,640,1,1]
TRACE 22 RMS_NORM        [128,48,512,1]   norm-0
TRACE 23 MUL             [128,48,512,1]   node_50              s1[128,1,1,1]     <- norm WEIGHT
TRACE 26 SILU            [128,48,512,1]   node_53                                <- silu(z)
TRACE 27 MUL             [128,48,512,1]   node_54              s1[128,48,512,1]  <- z GATE
TRACE 29 MUL_MAT         [5120,512,1,1]   linear_attn_out-0                      <- subsystem A again
```

Two things this settles that guesswork got wrong:

- **The fused GDN op is enabled** (`resolve_fused_ops: fused Gated Delta Net
  (chunked) enabled`), so the entire recurrence is ONE node whose output
  `[6144,640]` is `[attn_scores | new_state]` concatenated, and node 20 copies
  the state half into the cache. Substituting that one node therefore
  substitutes the STATE as well, which is the only way B's compounding error can
  be modelled at all.
- **There are two MULs after the output norm and they are not interchangeable.**
  Node 23 is the `ssm_norm` weight multiply (`src1` is `[128,1,1,1]`); node 27 is
  the z gate (`src1` is `[128,48,512,1]`). The first version of this tool
  classified "the MUL whose src0 is the RMS_NORM" as the z gate and got the
  weight multiply.

### 3.1 The perplexity loop reproduces llama-perplexity exactly

| tool | settings | PPL, 20 chunks |
|---|---|---|
| `llama-perplexity` | `-c 512` (default `-b 2048`) | 6.9675 +/- 0.24321 |
| `llama-perplexity` | `-c 512 -b 512 -ub 512` | **6.9497** +/- 0.24218 |
| `gdn_probe --mode baseline` | `--ctx 512` | **6.949680** |

**`llama-perplexity`'s default batch size silently changes the answer.** With
`-b 2048` and `-c 512` it sets `n_seq = n_batch / n_ctx = 4` and evaluates four
chunks as four concurrent sequences; the same nominal settings then give 6.9675
instead of 6.9497, a 0.26% difference. Nothing in its output says which
geometry it used except one line reading `n_seq=4`. Any comparison against a
previously recorded llama-perplexity number must pin `-b` and `-ub`.

### 3.2 Identity write-back is exactly neutral

```
==== mode=identity ctx=512 chunks=20 ====
nll           : 1.9386956315        <- baseline: 1.9386956315
PPL           : 6.949680            <- baseline: 6.949680
callback hits : 10560
  conv 960  silu_qkv 960  l2norm 1920  beta_sigmoid 960  softplus 960
  gated_delta_net 960  out_rmsnorm 960  out_norm_weight 960
  silu_z 960  z_gate_mul 960
```

Ten decimal places of `nll`, identical. Read-modify-write through the eval
callback costs nothing numerically, at all ten sites including the fused GDN
node with its state half.

### 3.3 The double reimplementation of the emit chain matches ggml

`--mode emit_dbl --report-only` (compute the chain in double from the same
inputs, compare against what ggml produced at the same node, do NOT substitute):

```
vs ggml : rel RMS 8.136583e-08   max abs 2.288818e-05   over 452984832 values
```

8.1e-8 relative RMS is f32 rounding. Over 4.5e8 real activation values across 48
layers and 3 chunks. The chain's structure, the head stride, the point at which
the `ssm_norm` weight enters and the eps value (`f_norm_rms_eps = 1.0e-06`,
read from the model, not assumed) are all confirmed.

### 3.4 The result that changes the design

`--mode emit_dbl` with the substitution ENABLED, i.e. writing back values that
differ from ggml's by 8.1e-8 relative:

```
==== mode=emit_dbl ctx=512 chunks=20 ====
PPL : 6.964689        baseline 6.949680     delta +0.015009  (+0.216%)
```

**A perturbation at the f32 rounding limit, from a computation that is strictly
MORE accurate than the one it replaced, moves 20-chunk perplexity by +0.015.**
That is 6x the entire storage-control cost of the subsystem A measurement
(+0.0025), produced by a change that is numerically nothing.

### 3.5 The noise ladder, which says what that +0.015 actually is

`--mode z_gate_mul --noise R`: write back exactly what ggml computed, scaled
elementwise by `1 + R*u` with `u` unit-variance uniform. Full run log at
`tools/bfx/results_wikitext_20chunks.txt`.

| row | PPL | delta vs baseline |
|---|---|---|
| baseline | 6.949680 | -- |
| identity, all ten sites | 6.949680 | **0.000000** |
| identity, z gate only | 6.949680 | **0.000000** |
| noise 1e-8, seeds 1..6 | 6.949680 (all six) | **0.000000** |
| noise 1e-6 | 6.953502 | +0.0038 |
| noise 1e-4 | 6.958740 | +0.0091 |
| noise 1e-3 | 6.967646 | +0.0180 |
| noise 1e-2 | 6.948231 | **-0.0015** |
| noise 3e-2 | 6.947908 | **-0.0018** |
| noise 1e-1 | 6.964051 | +0.0143 |

Every row 960 callback hits. Two things follow, and the second one is the
important one.

**1e-8 is exactly zero, and that is a property of the generator, not luck.**
The uniform is bounded at `sqrt(3) * R = 1.73e-8`, and the f32 half-ULP is
2.98e-8, so at that magnitude the perturbed value always rounds back to the
original float. The perturbation is provably a no-op. (An earlier gaussian
version of the same knob did NOT give zero at 1e-8, because a gaussian is
unbounded and its 8.5% tail beyond 1.73 sigma does cross the rounding
boundary. Same nominal magnitude, different answer, entirely because of the
distribution's support.)

**There is no dose-response.** 1% relative noise is *better* than baseline;
3% is better still; 10% is +0.014; 0.1% is +0.018. Across five orders of
magnitude the displacement stays inside about +/-0.02 with no trend.

**So the +0.015 from the double control is not a measurement of anything. It
is one draw from a +/-0.02 scatter band, and so is every other row here.** The
model is genuinely insensitive to random multiplicative perturbation of the GDN
emit output up to at least 3% relative; what moves the 20-chunk number is
trajectory reshuffling through the recurrence, and that is bounded and
magnitude-independent.

### 3.6 Subsystem B's fixed-point emit chain, substituted

`--mode emit_fx`, which runs `bfx_emit_chain.c` -- head emit, `rmsnorm_bf` with
the epsilon, `gdn_silu` on z, the gated product and the per-card head fold --
over the real activations, in place of nodes 22, 23, 26 and 27:

| row | PPL | delta | B's rel RMS vs f32 |
|---|---|---|---|
| baseline | 6.949680 | -- | -- |
| **emit_fx, fold 24 heads** (the hardware's per-card fold) | **6.953196** | **+0.0035** | **5.340182e-04** |
| emit_fx, fold 48 heads (both cards' heads on one exponent) | 6.954881 | +0.0052 | 6.067116e-04 |
| double control, same nodes | 6.964689 | +0.0150 | 8.136583e-08 |

**B's emit chain costs +0.0035 PPL at 20 chunks, which is inside the +/-0.02
scatter band and therefore not distinguishable from zero.** It is also smaller
than the double control's own displacement, which is the clearest possible
statement that this run does not resolve the effect. What it DOES establish is
an upper bound: whatever B's emit chain costs, it is under the scatter, i.e.
well under the +0.04 acceptance threshold, and it is nowhere near the
catastrophic class.

**The sign of that +0.0035 is not stable, which is the point.** Re-run at 10
chunks instead of 20, after a clean rebuild:

```
baseline  10 chunks : 7.379899     identity 10 chunks : 7.379899  (bit-identical)
emit_fx   10 chunks : 7.370956     delta -0.0089
```

Same substitution, different corpus length, opposite sign. Nothing about B
changed between those two runs. This is the scatter band of section 3.5 seen
directly, and it is why no conclusion is drawn from either number beyond "under
the band".

**The measured error magnitude is 5.34e-4 relative RMS** on 4.53e8 real
activation values, max absolute 7.69e-3. For int16 block-floating with a
24-head shared output exponent that is the expected order; 0.05% is a normal
quantization error, not a rail hit.

**Folding 48 heads onto one exponent instead of 24 costs 14% more error**
(6.07e-4 vs 5.34e-4). The hardware's 24-head fold is the better of the two, and
the margin is small enough that the split-by-head-across-two-cards decision is
not load-bearing for numerics.

### 3.7 Per layer, where the aggregate hides things

`--mode emit_fx --report-only`, full table at
`tools/bfx/results_perlayer_emit_fx.txt`:

```
  L0   3.8162e-03      L1   7.3734e-04   L2   6.9279e-04   L3   5.2360e-04
  L4   5.5766e-04      L5   1.1528e-03   L6   6.5195e-04   L7   8.2185e-04
  ...
  L44  5.4940e-04      L45  4.6955e-04   L46  4.6686e-04   L47  4.5680e-04
```

**Layer 0 is 3.82e-3, seven times the stack median of about 5.5e-4.** That is
the layer `docs/debugging/2026-08-26_rmsnorm-magnitude-window.md` measured as
sitting ~8 octaves above the rest of the stack in `rms(o_h)`, and whose own span
of 19.28 octaves exceeds the unit's 19-octave window by itself. The per-layer
view finds it; the aggregate does not. Nothing here says layer 0 is broken --
3.8e-3 is still a small number -- but it is the row to watch when the recurrence
and the l2norm are substituted, because it is where any magnitude rail will be
hit first.

---

## 4. Why subsystem A's procedure does not transfer, and what replaces it

### The mechanism

A's measurement was **paired**: source, control and A-format were three static
weight sets scored on identical tokens, and the text's chunk-to-chunk variance
(+/-0.045) cancelled in the difference, leaving a measured noise floor of
0.0025 against a 0.1185 effect. That is a 47:1 signal-to-floor ratio and it is
why the +/-0.045 error bars were correctly dismissed.

**B has a recurrence.** The GDN state is carried across all 512 tokens of a
chunk, and the emit chain feeds the residual stream, which feeds the next
layer's state. A perturbation at token 1 changes the state seen by tokens
2..511, in 48 stacked layers. The trajectory does not shift, it diverges.
Pairing on identical tokens no longer cancels, because the two runs stop being
the same computation after the first token.

### What section 3.5 measured, stated plainly

Two facts, and they point in opposite directions:

1. **Any perturbation above the f32 rounding boundary displaces the 20-chunk
   number by up to +/-0.02.** A strictly more accurate computation of the same
   chain, differing by 8.1e-8 relative, moved it +0.015.
2. **The displacement does not grow with the perturbation.** 1e-6 gave +0.0038,
   1e-3 gave +0.0180, 1e-2 gave **-0.0015**, 3e-2 gave **-0.0018**, 1e-1 gave
   +0.0143. Random multiplicative noise of 3% relative at the GDN emit output
   costs the model *nothing*.

So the +/-0.02 is a **scatter band**, not a dose-response curve, and the model's
real sensitivity to random error at this site is astonishingly low.

### Three consequences, one of which kills an idea in this document's own brief

**(a) The control is not the baseline; it is the scatter band.** No single
20-chunk delta below 0.02 means anything. The correct control is the ensemble of
harmless perturbations that produces the band, and a substitution result is
"inside" or "outside" it.

**(b) Averaging is the only lever, and it should work.** The harness calls
`llama_memory_clear` between chunks, so each chunk is an independent trajectory
and the displacement is a mean over `n_chunks` independent draws. It should fall
as `1/sqrt(n_chunks)`:

| chunks | wall clock, baseline | projected scatter band |
|---|---|---|
| 20 | 18 s | +/-0.020 |
| 100 | 90 s | +/-0.0089 |
| 655 (all of wiki.test) | ~10 min | **+/-0.0035** |

+/-0.0035 at full length is the same order as A's measured 0.0025 control, which
is a consistency check on the projection rather than a coincidence. Against the
+0.04 acceptance threshold that is better than 10:1. **This projection is
arithmetic, not measurement.** Step 6 measures it, and it is the single
load-bearing assumption behind "the full measurement is worth running".

**(c) The noise ladder CANNOT be used as a calibration curve, and the cheap
proxy therefore cannot predict perplexity.** The brief for this work proposed
measuring B's relative error offline and converting it to a perplexity estimate.
That conversion requires a monotone mapping from error magnitude to PPL delta.
**Section 3.5 shows there is no such mapping at this site:** the curve is flat
from 1e-6 to 1e-1, five orders of magnitude, and non-monotone within the band.
A measured relative error of 5.3e-4 maps to "somewhere in +/-0.02", which is the
whole band and therefore no information at all.

This is a genuinely useful negative result. It means the proxy's job is to catch
catastrophe and to localise error, not to price it, and that pricing requires
the substitution run at full corpus length. It also means a defence of the form
"our relative error is only 0.05%, therefore perplexity is fine" is not an
argument -- 3% random error is also fine, and 0.05% *structured* error might not
be. Only the substitution distinguishes them.

### The trap this creates for anyone reading a single number

A single 20-chunk run showing "+0.02" is indistinguishable from one showing
"-0.01". **Any B result quoted from fewer than ~100 chunks, without the scatter
band beside it, is noise.** The catastrophic class is the exception: a defect of
the kind found twice already moves perplexity by whole multiples, not by 0.02,
and 20 chunks resolves that in 40 seconds.

## 5. Feasibility, step by step

| step | feasible here? | what exists | what is missing |
|---|---|---|---|
| 0 site location | **DONE** | `tools/bfx/gdn_probe --inventory`, verified output in 3.0 | -- |
| 1 ppl loop | **DONE** | own loop, exact match to `llama-perplexity` | -- |
| 2 identity | **DONE** | `--mode identity`, exactly neutral | -- |
| 3 double control | **DONE for the emit chain** | `--mode emit_dbl`, 8.1e-8 vs ggml | the same control for the GDN, conv, l2norm and scalar sites |
| 4 noise ladder | **DONE at 20 chunks** | `--mode z_gate_mul --noise R` | the ladder at 655 chunks |
| 5a emit chain fixed point | **BUILT AND RUN**, sections 3.6/3.7 | `tools/bfx/bfx_emit_chain.c` composing `ref/rmsnorm_bf_vec.c` and `ref/gdn_silu_vec.c` | full-length rerun to get out of the scatter band |
| 5b GDN recurrence fixed point | **NOT BUILT** | `ref/gdn_err.c` already implements the exact 2.1.4 recurrence at real 27B shapes with per-column int8 exponents | it is written as a standalone `main()` with its own driver; its core needs the `#ifndef ..._INCLUDE` guard treatment before it can be called per node. ~1 day. |
| 5c conv / silu / l2norm / scalar | **NOT BUILT** | `ref/gdn_conv_vec.c`, `ref/gdn_silu_vec.c`, `ref/gdn_scalar_vec.c` exist and are verified | same guard work, plus B has no l2norm reference at all in `ref/` -- only RTL and the collapse document. That is the largest single gap. |
| 6 full-length run | **feasible, not run** | -- | ~10 min per baseline row, ~20 min per substituted row; a full ladder plus five site rows is 3-4 h of GPU |

**Nothing in this plan needs a llama.cpp fork, a rebuild of the tree
`llama-cpp-server` runs from, Vivado, or a model download.** The tool links the
existing prebuilt `libllama.so` and its public headers, read-only.

### Blockers, concretely

1. **No l2norm reference in `ref/`.** `docs/debugging/2026-08-25_l2norm-recipe-collapse.md`
   documents the defect and the RTL is fixed, but there is no C model of the
   shipped recipe to substitute. This is the site the review flags as having
   never been driven by real activations at all, and it is the one this harness
   currently cannot reach.
2. **`ref/gdn_err.c` is a program, not a library.** It has the right arithmetic
   for step 5b and the wrong shape for calling. Guarding its core is the same
   mechanical change `rmsnorm_bf_vec.c` and `gdn_silu_vec.c` already carry.
3. **The GPU must be free.** `llama-cpp-server` holds ~37 GB of the 48 GB when
   running and the 27B will not fit alongside it. It is currently stopped and
   was deliberately left that way; **this work did not start or stop it and a
   full run must not either without the owner's say-so.** The harness aborts
   loudly rather than silently falling back to partial offload.
4. **The emit-chain fixed-point path is single-threaded C.** Cost is measured in
   section 3.5's wall clock. If the composed all-sites run is too slow, the
   parallelisation is trivial (heads are independent) and has not been done.

### The one thing that is genuinely NOT feasible here

**A task-level eval with the statistical power to decide the question the A
revision left open** ("divergence is not damage"). That document's own
arithmetic: detecting a 1-point pass@1 difference on HumanEval at 80% power
needs ~37,600 problems against the 164 that exist. That is not a machine
limitation, it is a benchmark-size limitation, and no amount of GPU here fixes
it.

---

## 6. The cheaper proxy, what it establishes and what it does not

### The proxy

`--mode emit_fx --report-only` runs B's fixed-point chain over the real
activations of the layer it is sitting in, compares against what ggml computed
at the same node, and **does not substitute**. It needs no perplexity run, no
control, and no reasoning about chaos, because the forward pass is unmodified.
Cost: 3 chunks, about 20 seconds.

It reports relative RMS and max absolute error against the f32 truth, over 1.5e8
activation values per chunk, at every one of the 48 layers.

### What it CAN establish

- **The catastrophic class, immediately.** A recipe that emits zeros above a
  magnitude rail, or is 14x wrong at the median, shows as a relative RMS of
  order 1 rather than order 1e-3. This is the failure the review calls the
  project-killer and it is the failure the proxy is best at.
- **Where the error is, per layer and per site.** Layer 0's activations sit ~8
  octaves above the rest of the stack
  (`2026-08-26_rmsnorm-magnitude-window.md`); a rail hit only there is visible
  per-layer and invisible in any aggregate.
- **Whether real activations reach the regions the synthetic sweeps assumed.**
  The same document records that sweeping a range the model does not occupy
  overstated the design's error by 66x. The proxy measures the occupancy
  directly.
- **A magnitude, in units the RTL work can act on.** 5.34e-4 relative RMS at
  fold 24 against 6.07e-4 at fold 48 is a direct, cheap comparison of two design
  choices, and it needed no perplexity run at all. This is what the proxy is
  genuinely good for: ranking variants of the same site.

### What it CANNOT establish

- **A perplexity number, and not even a bracket.** The original plan was to
  read the measured relative error against a noise-vs-PPL calibration curve.
  **Section 3.5 measured that curve and it is flat** from 1e-6 to 1e-1 relative,
  and non-monotone inside the scatter band. There is nothing to look the number
  up in. Beyond that, B's error is not random anyway: it is deterministic,
  correlated across the 128 elements of a head (they share an exponent),
  correlated across the 24 heads of a card (they share a `y_exp`), and
  systematically biased wherever a rail or a saturation is involved. Random-noise
  behaviour tells you nothing about it in either direction.
- **Anything about compounding.** The proxy measures one site's error against
  the f32 value at that site, with the f32 pipeline supplying the inputs. In
  hardware, B's state is fixed-point from token 0 and its error feeds itself.
  `ref/gdn_err.c` bounds that separately with synthetic drives; only the
  substituted GDN node measures it on real data.
- **Whether the error matters.** 1.118% top-1 disagreement cost +0.036%
  perplexity in the A measurement. Magnitude is not damage.

---

## 7. Extensions worth doing, in order

1. **KL divergence instead of perplexity, on the agentic corpus.** The A
   revision established that the metric changes the recommendation, and the
   infrastructure is already on disk:
   `/mnt/storage/ppl-data/corpus/agentic_code.txt` (485 KB) and
   `/mnt/storage/ppl-data/corpus/base_q4km.logits` (5.1 GB, the Q4_K_M reference
   logits for exactly that corpus). The harness needs a logits-dump mode
   compatible with `llama-perplexity --kl-divergence`'s file format.
2. **The full-length seed ladder** (step 6), which is what makes any single
   number quotable.
3. **Per-site attribution across all ten sites**, which is what turns "B costs
   X" into "fix this one thing".
4. **The same treatment for subsystem C before its RTL hardens.** The sites are
   already classified in the inventory; C's QK-norm is an `RMS_NORM` at a
   different width and its softmax is a `SOFT_MAX` node, both interceptable by
   the same mechanism at no additional cost.

---

## 8. Measurement traps hit while building this, including my own

**`llama-perplexity`'s `-b` default changes its answer** (3.1). Two runs of the
same command with the same `-c` gave 6.9675 and 6.9497. Pin `-b` and `-ub`.

**A substitution mode that reported the baseline exactly, because it never
fired.** `--mode z_gate_mul` classified the z gate by walking forward from the
output norm, but the anchor was only recorded in the callback's *compute*
phase, and asking for the gate alone meant the anchor node was never computed
through the callback. The gate was therefore never recognised, the callback
never ran, and the run printed a perplexity **identical to the baseline to ten
decimal places** -- which reads as a clean neutrality result. It was caught only
by checking `callback hits`, which was 0. **A substitution mode reporting zero
hits measured nothing; the harness now prints the count on every run and every
result in this document quotes it.**

**A noise sweep that reported zero effect at every magnitude up to 1e-2**,
because the perturbation was applied as `f[i] * (1.0f + delta)` in float. For
`delta` below the f32 epsilon of 1.19e-7 the multiplier rounds to exactly 1.0
and nothing happens; and at 1e-2 the run was still in the old code path from a
stale binary. Two different causes producing the same clean, wrong table. The
scaling is now done in double.

**Box-Muller made the sweep unrunnable.** 960 nodes x 3.1M floats = 3.0e9
`log`/`sqrt`/`cos` evaluations per 20-chunk run. Replaced with a unit-variance
uniform, which measures the same thing: the knob is a magnitude, not a shape.

**The z gate was first identified as the norm's weight multiply** (3.0). Both
are a `GGML_OP_MUL` immediately after the output `RMS_NORM`. Discriminating on
`src[1]`'s shape separates them; discriminating on position does not. This was
caught by the double control failing to be neutral, which is exactly the job
step 3 exists to do.

**A noise ladder that looked like a dose-response curve until it was extended.**
The first three rows measured (1e-6, 1e-4, 1e-3) gave +0.0038, +0.0091, +0.0180:
monotone, plausible, and consistent with "perplexity grows with error, roughly
logarithmically". Extending the ladder to 1e-2 and 3e-2 gave **negative**
deltas. Had the sweep stopped at 1e-3 -- which is where a sensible person stops,
because 0.1% relative error is already large for a quantization study -- this
document would have contained a calibration curve, and every number derived from
it would have been wrong. **Sweep past the range you think matters, and stop only
when the trend breaks or the range is absurd.** This is the same lesson as the
rmsnorm magnitude sweep that stopped two octaves short of a hard rail and
reported it REFUTED.

**Gaussian and uniform noise of the same nominal sigma give different answers at
sub-ULP magnitudes**, and the difference is not subtle: at 1e-8 the bounded
uniform is provably a no-op (its support, 1.73e-8, is under the f32 half-ULP of
2.98e-8) while the unbounded gaussian's 8.5% tail beyond 1.73 sigma does flip
the rounding. Neither is wrong; they answer different questions. State the
support, not just the variance.

**The included-reference initialisation trap, checked for explicitly.**
`tools/bfx/bfx_emit_chain.c` `#include`s `ref/rmsnorm_bf_vec.c` and
`ref/gdn_silu_vec.c` with `GDN_CHAIN_INCLUDE`, which guards away their `main()`
-- and every setup call `main()` was making. That is how
`ref/gdn_emit_chain_vec.c` once ran with `M_EPS = 0` (an epsilon of ZERO) and an
all-zero sigmoid table. `bfx_init()` calls `bf_resolve_eps()` and `fx_init()`
and then **asserts that each took effect**: `M_EPS != 0`, the sigmoid LUT
non-zero at two indices, and `sigma_q15(0) == 16384 +/- 4`. A check that cannot
fail is not a check.

---

## 9. What I could not determine

- **Whether B's composed fixed-point path is affordable.** Only the emit chain
  is built. The recurrence -- the one site whose error compounds and therefore
  the one most likely to be expensive -- is not substituted yet, and neither are
  the conv, the l2norm or the scalar path. The composed number is the one that
  matters and it does not exist.
- **What B's emit chain actually costs.** The 20-chunk number is +0.0035 and
  the scatter band is +/-0.02, so the only defensible statement is an upper
  bound: it is under the band. That is enough to say it is not the killer, and
  not enough to put a number on it. The full-length run is what puts a number on
  it and it has not been run.
- **Whether the scatter band really falls as `1/sqrt(n_chunks)`.** It should,
  because chunks are independent trajectories, and the projection lands on the
  same order as A's measured control. It is arithmetic, not measurement, and it
  is the load-bearing assumption behind the claim that the full measurement is
  worth running. One 100-chunk seed ladder settles it in about 15 minutes.
- **Why the model is so insensitive to random error at this site.** 3% relative
  multiplicative noise at the GDN emit output costs nothing measurable. The
  plausible reason is that the output passes through `ssm_out`, a 6144 -> 5120
  projection that averages zero-mean error away, and that the branch is added to
  a residual stream. If that is the reason, the same insensitivity does NOT
  extend to sites whose error is biased rather than zero-mean, and B's is.
  Nothing here tests the explanation.
- **Anything about the l2norm site on real activations**, which is the site the
  direction review singles out as having no visibility of any kind. There is no
  C reference to substitute, so this harness cannot currently reach it. That gap
  is the single highest-value piece of reference work this measurement needs.
- **Whether the emit chain's site-12 input quantization is faithful.** In
  hardware, `e_h` comes from the recurrence's per-column accumulator exponents;
  here the recurrence ran in f32 and the exponent is derived from the head's own
  dynamic range. Those agree in the common case and can differ where a column's
  exponent is an outlier. Substituting the GDN node too removes the
  approximation; until then it is an unmeasured difference between the harness
  and the hardware.
- **Whether any of this predicts token-level behaviour at 27B.** The A revision
  showed a greedy 100-token run matches llama.cpp 32.5% of the time even for a
  control that costs +0.036% perplexity. Perplexity agreement is not output
  agreement and nothing here changes that.
