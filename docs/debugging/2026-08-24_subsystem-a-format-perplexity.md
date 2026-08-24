# What does subsystem A's INT4 weight format actually cost in model quality?

Date: 2026-08-24
Model: `Qwen3.8-27B-Q4_K_M` (18.97 GB), llama.cpp PR#27342 build
Data: full wikitext-2 raw test set, `-c 512`, all chunks, KV cache at full precision

## The question

Every resource, timing, bandwidth and Fmax result in this project assumes
subsystem A's weight format is good enough to run the model. That had never been
tested above the level of a single tensor. It was a genuine blind spot, and the
kind that invalidates everything downstream rather than adjusting it.

The risk was specific, not hypothetical. **Qwen3.8-27B-Q4_K_M is not a uniformly
4-bit model.** llama.cpp's mixed recipe stores

| tensors | stored as |
|---|---|
| `ffn_gate` / `ffn_up` / `ffn_down`, `token_embd` | Q4_K (193) |
| `attn_qkv`, `attn_gate`, `ssm_out`, `ssm_alpha`, `ssm_beta` | **Q8_0 (288)** |
| `output.weight` | Q6_K (17) |

The projections are kept at **eight bits** because they are the ones that do not
tolerate coarse quantization. Subsystem A's format is a flat ~4.5 bits (IQ4_NL
codebook + per-32 uint15 Q15 scale + per-matrix exponent) for everything it
streams, so it pushes those from 8 bits to 4.5.

## The answer

**A costs +1.69% perplexity (+0.1185) and is viable.** No mixed-precision path
is forced.

| | PPL | vs control |
|---|---|---|
| source, Q4_K_M as shipped | 7.0041 +/- 0.0454 | +0.036% |
| control, storage round trip only | 7.0016 +/- 0.0454 | -- |
| **A format** | **7.1201 +/- 0.0467** | **+0.1185 (+1.69%)** |

+1.7% is a normal-sized quantization step, roughly one quant tier, which is
exactly what A is doing to the Q8_0 tensors. It does not invalidate the project.

## The procedure

The measurement is a **difference**, because the round-tripped weights have to be
stored in some format and that storage has its own error:

```
control :  dequantize -> Q8_0
A       :  dequantize -> A quantize -> A dequantize -> Q8_0
```

A's cost is `ppl(A) - ppl(control)`. Quoting `ppl(A)` against the source would
charge A for the storage requantization, which is not A's to pay.

1. **Cheap calibration first, before any GPU time.** Relative Frobenius error of
   each scheme on real tensors, which is what justified spending three hours on
   the rest:

   | tensor | stored | A err | Q8_0 err |
   |---|---|---|---|
   | `blk.0.ffn_gate` | Q4_K | 7.63% | 0.53% |
   | `blk.0.ffn_down` | Q4_K | 7.66% | 0.54% |
   | `blk.0.attn_qkv` | **Q8_0** | 8.00% | **0.000%** |
   | `blk.0.attn_gate` | **Q8_0** | 8.04% | **0.000%** |
   | `blk.0.ssm_out` | **Q8_0** | 8.19% | **0.000%** |

   A adds ~8% relative error, and on the Q8_0 tensors it adds it on top of
   exactly zero. ~8% is about Q4_0's level, i.e. plausible but not obviously
   safe -- which is precisely the case where the end-to-end metric must decide.
   It also confirms the control is nearly free and can be subtracted honestly.

2. **The inverse was checked against the forward direction** on Gaussian,
   heavy-tailed, non-multiple-of-32 and all-zero inputs before use. A wrong
   scale constant would rescale the whole matrix and still yield a finite,
   plausible perplexity.

3. **Both round-tripped GGUFs were verified structurally** before measuring:
   851/851 tensor names, zero shape mismatches, 39/39 metadata fields.

4. **Control run first.** It is what makes the result interpretable, and it also
   validates the whole harness end to end.

## The evidence, and why the error bars are not the right statistic

```
source   7.0041 +/- 0.04543
control  7.0016 +/- 0.04543      source - control = +0.0025
A        7.1201 +/- 0.04673      A      - control = +0.1185
```

The reported `+/-` is the standard error over **chunk-to-chunk variance in the
text**, not run-to-run reproducibility. Treating the three runs as independent
would give the difference an error of ~0.065 and make +0.1185 look like a
1.8-sigma result. That reasoning is wrong, and the control proves it: source and
control differ by **0.0025** despite each carrying a +/-0.045 bar, because they
are paired on identical data and that variance cancels. **Against a measured
noise floor of 0.0025, a 0.1185 gap is unambiguous.**

Independent confirmation from a separate 200-chunk run on different data volume:
+0.1327 (+1.94%), consistent in sign and magnitude with +0.1185 (+1.69%).

## Measured and REJECTED - do not retry

**Do not quote `ppl(A)` against the source.** It conflates A's cost with the
storage requantization. The control exists for this and costs one extra run.

**Do not conclude the result is marginal from the +/- figures.** See above. The
paired control is the correct precision estimate, and it is 20x tighter.

**Do not assume gguf-py can requantize to Q4_K.** It implements dequantize for
all types but quantize for only Q8_0 / Q4_0 / Q5_0 / F16 / BF16; Q4_K raises
`NotImplementedError`. This is why the control stores Q8_0, which is fortunate
anyway since Q8_0 is nearly lossless and makes the control clean.

## Measurement traps hit

**`GGUFWriter` defaults to `use_temp_file=False` and retains every tensor in
RAM.** The first build reached 20.5 GB RSS with 10 GB free on a 31 GB box and had
to be killed; this machine has previously had systemd-oomd take out the entire
code-server cgroup under Vivado memory pressure. Fixed by registering tensor
infos in one pass (shapes and types need no tensor data) and streaming tensor
data in a second, via `write_tensor_data`. Peak memory is now one tensor.

**`GGUFReader` synthesizes `GGUF.version`, `GGUF.tensor_count` and
`GGUF.kv_count` as if they were KV fields.** They are header values; copying them
writes real duplicates and the file will not reload
(`Duplicate GGUF.version already in list`).

**Substring matching in the skip list silently shrank the experiment.** The list
carried `"ssm_a"` to exclude the 1-D `ssm_a` parameter and, as a substring, also
matched `ssm_alpha.weight` -- excluding 48 alpha projections, one per GDN layer.
Caught only by reconciling the reported count (448 A-quantized) against a hand
prediction (496). It cost 0.04% of parameters and so slightly **understates** A's
cost; the same bug against `"ffn_"` would have gutted the measurement while still
printing a perfectly plausible perplexity. **Always hand-predict the tensor count
and reconcile.** Now fixed to exact-component matching, with a unit test.

**Byte-progress is not linear progress.** Early tensors are small; reading the
output file size gave a badly wrong completion estimate.

**`tail -f` replays the last 10 lines by default**, which made a monitor report
the control run's summary as if the A build had finished with zero A-quantized
tensors. Use `tail -f -n 0`.

## Open, not yet answered

- **The LM head is excluded.** `output.weight` is 1.27B params stored Q6_K, and
  on real hardware A would stream it. llama.cpp keeps it high-precision because
  it is sensitive, so including it should make A look worse. `--include-output`
  measures it; not run.
- **This is A's cost on top of Q4_K_M, not from F16.** No higher-precision GGUF
  is on disk. Total degradation versus the original model is larger; what is
  measured here is the marginal cost of the deployment path actually planned.
- **Perplexity is not task accuracy.** +1.69% ppl is reassuring but does not by
  itself establish that code generation or instruction following are unharmed.
- The 48 skipped `ssm_alpha` tensors were not re-measured after the fix; the
  0.04% parameter share makes a rerun hard to justify, but the headline is
  therefore a very slight underestimate.


## ATTRIBUTION 2026-08-24: 77% of the loss is format structure, not bit width

`--only-q4k` (this format applied only to already-Q4_K tensors, leaving the
Q8_0 projections intact -- which IS the mixed-precision design) measures
**7.0931**, against the 7.0016 control and the 7.1201 uniform run:

```
control                            7.0016
A on FFN only = mixed precision    7.0931    +0.0915   (+1.31%)
A uniform                          7.1201    +0.1185   (+1.69%)

  format underperforming Q4_K on the FFN   +0.0915   77.2%
  degrading the Q8_0 projections           +0.0270   22.8%
```

**This inverts the conclusion the earlier evidence supported.** The Q8_0
projections were the visible risk -- 8 bits dropped to 4.5, ~8% relative error
added where there had been 0.000% -- and they are the MINOR term. Mixed
precision would cost +27% bandwidth and 21% of the token rate to recover 22.8%
of the gap.

The dominant term is this format losing to Q4_K at the SAME bit width, on the
FFN tensors that are 63.6% of all parameters. The structural difference is that
Q4_K is asymmetric, carrying a per-block minimum, while this format is symmetric
(codebook x scale). That is consistent with the earlier calibration, which
showed 7.6% relative error on `ffn_gate` measured against Q4_K's own dequantized
values -- an error that bit width alone cannot explain.

**Lesson for the procedure, not just the result:** the calibration table ranked
the risk by where error was ADDED (0.000% -> 8% on the Q8_0 tensors looked
alarming; 0.53% -> 7.6% on the Q4_K tensors looked unremarkable). Perplexity
weights by parameter share and by sensitivity, and it ranked them the other way
round. Per-tensor error is a screening tool, never an attribution.

**Open:** whether an offset actually recovers the 0.0915, and at what bit cost.
An offset is not free; keeping 4.469 bits/weight would need Q4_K's hierarchical
superblock structure rather than a flat per-block min.

## REVISION 2026-08-24: measured on code, with KL divergence -- the earlier recommendation was metric-dependent

Everything above was measured as **perplexity on wikitext-2**, i.e. Wikipedia
prose, against a deployment target of agentic software development. Re-measured
on an agentic/code corpus (2,374 real dsh session fragments interleaved with 648
repo source files) using llama.cpp's `--kl-divergence`, with the shipped Q4_K_M
as reference, since matching llama.cpp *means* matching that:

| | Same top p | disagree | 99.9% KLD | RMS dp |
|---|---|---|---|---|
| harness self-check | 99.990 +/- 0.010% | 0.010% | 0.000048 | 0.000% |
| control (storage only) | 98.882 +/- 0.104% | 1.118% | 0.057 | 1.25% |
| A on FFN only = mixed precision | 96.422 +/- 0.184% | 3.578% | 0.604 | 3.91% |
| A uniform | 94.951 +/- 0.217% | 5.049% | 1.400 | 5.33% |

**The corpus PPL is 2.4763 against wikitext's 7.0041** -- code is far lower
entropy, which is exactly why the domain had to change.

### The recommendation above is metric-dependent, and the metric was wrong

What mixed precision buys back, as a fraction of A-uniform's excess over control:

| metric | recovered | cost |
|---|---|---|
| wikitext perplexity | 22.8% | -21% tok/s |
| top-1 disagreement, code | 37.4% | -21% tok/s |
| **99.9% KLD tail, code** | **59.2%** | -21% tok/s |

The "do NOT buy precision" conclusion rests on the first row. **For agentic work
the third row is the relevant one**: the tail is where the model is
*confidently* different, which is what breaks a tool call, while the mean mostly
reflects reworded comments and renamed locals. By that measure 21% throughput
buys back nearly 60% of the damage, which is a real trade rather than a clearly
bad one. **Treat the earlier recommendation as withdrawn pending a decision on
which failure mode matters**, not as refuted -- both numbers are correct, they
answer different questions.

### Two controls that make the numbers readable

**Harness floor: 0.010% disagreement** (source against its own logits). Not
0.000%, because GPU reduction order is not deterministic. Everything measured
here is far above it.

**Harmless-perturbation floor: 1.118%.** The control disagrees on 1.1% of tokens
while costing +0.036% perplexity, i.e. nothing. Top-1 is a discrete decision, so
wherever the top two candidates are near-tied any perturbation flips them, and
those are the positions where the choice does not matter. **Raw disagreement
therefore overstates damage and must be read against this floor, not against
zero.** A-uniform is 4.5x the floor on disagreement and 24.5x on the tail.

### Token-identical acceptance does not scale to 27B

Probability an n-token greedy run matches llama.cpp exactly:

| | n=10 | n=100 | n=1000 |
|---|---|---|---|
| control | 89.4% | 32.5% | ~0% |
| A on FFN only | 69.5% | 2.6% | ~0% |
| A uniform | 59.6% | 0.6% | ~0% |

The AXU3EG acceptance criterion was **24/24 token-identical output**. That does
not transfer: at 27B the engine will produce different output from llama.cpp on
essentially any real agentic step. **Note the control says the same** (32.5% at
n=100), so this is a property of quantization at this scale, not of subsystem A.
A different acceptance criterion is needed -- agreement rate against a floor,
not exact match.

### Why the task benchmarks were skipped, with numbers

HumanEval is n=164, so a single run carries a **+/-7.5 point 95% CI** at
pass@1~60%. Detecting a 1-point difference at 80% power needs ~37,600 problems;
2 points needs ~9,400. Running it on both models and comparing would produce
noise indistinguishable from signal. KL and top-1 agreement are measured per
token over ~20,000 tokens, roughly 1000x the sample size, on the exact quantity
that governs greedy decoding. **Cheap task benchmarks are not a weaker version
of this measurement; for an effect this size they are not a measurement at all.**

### Open, and now the most important gap

**Divergence is not damage.** These metrics count how often the top token
differs, not how often it matters, and the 1.118% control proves a large share
of flips are harmless. Distinguishing them needs either greedy first-divergence
with human or model adjudication of whether the divergence changed the answer,
or a task-level eval large enough to have power. That is the measurement that
would actually decide the mixed-precision question, and it has to be designed
rather than merely run.
