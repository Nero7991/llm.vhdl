# JC 27B first token: the card's residual carries a per-layer gain error (2026-10-09)

## The question

2026-10-09, Jungle Cat, bitstream jccard8 (`hw/jc/card/results/jccard8_2026-10-09/`, 125 MHz,
VCCINT 0.85 V), images `qwen38-27b-card0-b0-32` on die A and `qwen38-27b-card1-b33-63` on die
B. Prompt `hw/fk33/results/goal_dcdc_2026-09-17/prompt_tokens.txt` (23 ids). The card's
first argmax is **1206 ("To")**; llama.cpp on `Qwen3.8-27B-Q4_K_M.gguf` picks **7732
("While")**, with 1206 its third choice (`hw/jc/card/results/jc_cpu_ref_2026-10-09/`). Is the
card's answer precision drift (INT4 weights, block-float activations) or a defect?

## The answer

A defect, not yet located. At token 0 the card's residual has the right shape (corr 0.999 at
layer 32) but the wrong magnitude: 1.17x llama.cpp's after die A's 33 layers and 1.31x after
die B's 31 layers fed an exact input. Both dies gain, so the error is in how the shared block
runs in the 27B configuration, not in the two-die composition or the host hop. INT4 rounding
does not produce a consistent gain; the 9B card at token 0 measured corr 0.9965 / rel RMS
0.084 with no such gain.

## Procedure (in the order run)

1. **First token** (runbook 4.1): argmax 1206, deterministic (reproduced in run 4).
2. **Utilisation** (runbook step 6): `jc_seam.py util` on both dies.
3. **llama.cpp residual capture**: `tools/ref9b/dump_llamacpp -m Qwen3.8-27B-Q4_K_M.gguf
   --tokens <23 ids> --include l_out- --selfcheck -c 64 -t 16 -ngl 0` (CPU). 64 layers x 23
   positions. SELFCHECK bit-identical with and without the callback, argmax 7732: the capture
   does not perturb the model and agrees with llama-server.
4. **CPU lm_head instrument** (`lmhead_from_x.py`): rmsnorm x output_norm, then
   output.weight (Q6_K) dequantised by gguf-py. Validated on llama.cpp's own l_out-63: it
   reproduces llama.cpp's top-5 order (7732, 5449, 1206, 2064, 89454); its logprobs are
   within 0.16 of llama-server's. Resolution about 0.16 logprob.
5. **Card residuals**: `run_prompt --dump-xout` (die A, after its last GO = l_out-32 of the
   last position) and the new `--dump-xout2` (die B = l_out-63) (commit 3cdfce0f).
6. **Alignment check built into the comparator** (`xout_vs_lout.py`): metrics against the
   neighbouring layers and positions too; the target must be the best match. It is at
   positions 3 and 22. At position 0 every layer 30-34 correlates 0.998+ (the row is
   dominated by a few massive activations), so "aligned" is uninformative there.
7. **Short prompts** k=1 and k=4 (first 1 / 4 ids, GDN state re-zeroed before each), to
   separate per-token math from accumulated sequence state.
8. **Die B alone** (`run_prompt --jc --jc-die B --x-row`), GDN re-zeroed:
   - control: die A's own k=1 row in, which must reproduce the pair's die B row;
   - test: llama.cpp's l_out-32 at position 0, quantised to BFP16 (exp 6, rel error 0.0011).

## Evidence (MEASURED unless labelled)

Files: `hw/jc/card/results/jc27b_first_token_2026-10-09/`.

| position | die A out vs l_out-32 | die B out vs l_out-63 |
|---|---|---|
| 0 (k=1) | corr 0.99885, rel RMS 0.183, fit scale 1.174 | corr 0.98671, rel RMS 0.675, fit scale 1.620 |
| 3 (k=4) | corr 0.95381, rel RMS 0.360 | corr 0.97424, rel RMS 0.486 |
| 22 (k=23) | corr 0.94470, rel RMS 0.354, fit scale 1.019 | corr 0.87032, rel RMS 0.585, fit scale 1.033 |

Die B alone at position 0:

    control  (card die A row in):    bit-identical to the pair's die B row, 0 of 5120 differ, exp 4 = 4
    exact    (llama.cpp l_out-32 in): corr 0.97622  rel_rms 0.4253  fit_scale 1.3101
    largest: 3994: card 848 ref 623, 3456: card 28.9 ref 69.3, 4538: card -55.2 ref -30.5

Logits from the card's own final row (position 22), CPU lm_head:

    top1 1206 logprob -0.388, top2 2064 -2.248, top3 89454 -3.217 ... 7732 rank 5 (-3.377), 5449 rank 10

So the card's sampler is consistent with its residual: the divergence is upstream of the head.

Utilisation (A-job cycles, 125 MHz): die A 0.3272 of the port ceiling on all 24 weight ports,
die B 0.3469. Timing: 23 positions in 1184-1255 s, of which reading R_X over the broker is
1165-1235 s; engine cycles on the last position 45.5 M = 0.36 s (DERIVED).

DERIVED: per-layer gain if uniform, die A 1.174^(1/33) = 1.0049, die B alone 1.31^(1/31) =
1.0087. Not shown to be uniform: only die-boundary rows are readable.

## Measured and REJECTED (do not retry)

- **"1206 vs 7732 is INT4 precision drift."** Rejected: a consistent 17-31% gain over each
  die at token 0 with corr 0.999 of shape is not rounding noise; the 9B at token 0 had none.
- **"The two-die hop or the host path corrupts the row."** Rejected: die B alone with the
  card's own die A row reproduces the pair bit for bit, and die B gains with an exact input.
- **"The card's lm_head or sampler picks wrong."** Rejected: the CPU lm_head on the card's
  final row also picks 1206.
- **"The comparison is misaligned by a layer or a position."** Rejected at positions 3 and
  22 by the neighbour scan.

## Measurement traps hit

- **A re-run needs the GDN re-zero, not just `--seq-reset`.** `--seq-reset` clears positions
  only; `hw/jc/host/jc_bc_lane.sh rezero` zeroes the recurrent state. My first re-run skipped
  it and would have measured a contaminated sequence (it failed for another reason first).
- **BMC link drops killed 3 of 5 runs** with `WindowUnknown` on a die A window read. Root
  cause and fix: `docs/debugging/2026-10-09_jc-broker-windowunknown-after-link-drop.md`
  (commits 7f5e8f18, 336c3dd0). Writes in flight at a drop are still fatal.
- **The broker ignored SIGINT for its whole life** (started under `nohup ... &`); fixed in
  336c3dd0, and the clean stop was confirmed on hardware after the sync.
- The BC-250's shell is fish: `ssh ... 'p=$(...)'` fails; use `bash -s`.

## Open, not yet answered

- Which block carries the gain: GDN or attention layers, the FFN, or the norms. The 27B
  fetches norm gains from HBM by row (NORM_HBM), which the 9B does not; a gain on every
  layer of both dies points at a per-layer constant (norm gain, an exponent, a packing
  scale) but that is a lead, not a finding.
- Whether the 27B image's constants (norm gains, GDN constants) match the GGUF.
- No whole-model 27B numeric oracle exists in sim: `ref/run9b` has no 27B mode. The
  per-unit `ref/*_vec` benches ran with 27B parameters; that is not a composition oracle.
