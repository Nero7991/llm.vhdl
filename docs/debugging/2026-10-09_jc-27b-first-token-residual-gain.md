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

## 2026-10-09 addendum: the gain is the RMSnorm mean divisor (found offline, no hardware)

**Answer.** `rtl/rmsnorm_bf_mem.vhd` computes the mean as `S >> LOG2N` with
`LOG2N = clog2(N)` (lines 255, 693: `e_mean <= LOG2N + 2*xe + ...`). Its only guard is
`assert 2**LOG2N = N ... severity failure` (line 578), which Vivado ignores. Both
`rtl/llama_top.vhd:3257` and the generated `rtl/fk33_llama_top.vhd:3406` instantiate it with
`N => NN`, `NN = SHAPE.hidden`. That is 4096 at 9B, which is exact, and 5120 at 27B, which
rounds up to 8192. So every hidden-length norm (attn_norm, post_attention_norm, output_norm)
divides by 8192 where it should divide by 5120, and its output comes out
`sqrt(8192/5120) = 1.2649x` too large (DERIVED). Head-dim norms (128, 256) are powers of two and
are not affected. This also covers the 9B: it never showed the gain because 4096 is a power
of two.

**Procedure.**
1. Task 1, constants (`tools/ref9b/check_image_consts_27b.py`, MEASURED): on both images the
   NORM_HBM rows (129 x 5120 at exp 12, rows 2b / 2b+1 / 128), the GDN conv / dt / a / ssm_norm
   with their per-vector exponents, and `qkn_27b.hex` (the file jccard8's fk33_card.vhd names)
   all match the GGUF to within half a quantum. Teeth: a 1.01 scale on three vectors gives
   BAD. The program indexes norm rows by the global block (`const_base = 2b`, `2b+1`). Both
   images carry all 48 GDN layers and identical `gdn_const.bin`.
2. A grep over the RTL for every "must be a power of two" guard, checked against the 27B
   sizes: only rmsnorm_bf_mem gets a non-power-of-two N (5120). GHDL confirms it: the
   unit's own assert fails at elaboration with N = 5120 and passes at 4096.
3. A 27B mode for `ref/run9b.c` (commit 20862d03), run in bfp mode on the card's own INT4
   bytes, one die per process, with and without `--norm-pow2`.

**Evidence** (MEASURED, `hw/jc/card/results/jc27b_first_token_2026-10-09/offline_normpow2/`):

    token 0, die A (blocks 0-32, gguf-py embedding in)
      ok model    vs llama.cpp l_out-32   corr 0.99926 rel_rms 0.0877 fit 0.9199
      pow2 model  vs llama.cpp l_out-32   corr 0.99897 rel_rms 0.1832 fit 1.1753
      card        vs llama.cpp l_out-32   corr 0.99885 rel_rms 0.1833 fit 1.1744
      pow2 model  vs card                 corr 0.99986 rel_rms 0.0170 fit 1.0004
      ok model    vs card                 corr 0.99902 rel_rms 0.2206 fit 0.7821
    token 0, die B alone (llama.cpp l_out-32 in)
      pow2 model  vs card                 corr 0.99854 rel_rms 0.0607 fit 1.0247
      ok model    vs card                 corr 0.96357 rel_rms 0.4435 fit 0.5875
    token 0, die B fed the card's die A row: pow2 vs card  corr 0.99956 rel_rms 0.0298
    token 0, ok chain A then B vs llama.cpp l_out-63      corr 0.99665 rel_rms 0.0831 fit 1.0064
    23-token prompt, position 22:
      l_out-32  ok vs llama.cpp corr 0.99584 rel 0.0925 | card vs llama.cpp corr 0.94470 rel 0.3544
      l_out-63  ok vs llama.cpp corr 0.98473 rel 0.1856 | card vs llama.cpp corr 0.87032 rel 0.5852
      l_out-63  pow2 vs card    corr 0.96012 rel 0.3028 | ok vs card       corr 0.89526 rel 0.4612
    top at position 22:
      pow2 model  1206 27.96, 2064 26.07, 7732 25.55, 89454 25.20   (card: 1206, 2064, 89454, 16619, 7732)
      ok model    1206 22.838, 7732 22.722, 2064 22.00, 5449 21.77  (llama.cpp: 7732, 5449, 1206)

The divisor is read from the RTL, not fitted. With no free parameter it reproduces the card's
token-0 row to rel RMS 0.017. The correct divisor takes the same INT4 model to within 0.08 to
0.19 rel RMS of llama.cpp.

**Measured and REJECTED, do not retry.**
- "A norm gain, GDN constant or QK-norm gain in the image is wrong or mis-indexed." All
  match the GGUF to within half a quantum (above).
- "A 27B-specific packer scale." The pow2 model on the same packed bytes matches the card,
  and the ok model on those bytes matches llama.cpp, so the packed weights are not the cause.

**Traps.**
- `ref/run9b.c` at 9B leaned on two coincidences, `ATT_QH*ATT_HD == HIDDEN` and
  `VAL_DIM == HIDDEN` (both 4096). At 27B both are 6144 against 5120. The 27B mode sizes
  R_Y and R_Z explicitly.
- `ref/rmsnorm_bf_vec.c:202` computes LOG2N as floor(log2 N) (12 at 5120), and the RTL uses
  clog2 (13). At N = 5120 the "bit-exact" vector model, the RTL and the algorithm all
  disagree, so that bench cannot be the oracle for the fix as it stands.

**Proposed fix (not applied: no RTL edit without a failing test first).** In rmsnorm_bf_mem,
replace the shift with a multiply by an elaboration-time reciprocal,
`m_mean = S * RN`, `RN = round(2^(LOG2N+K) / N)`, `e_mean += K`, where 2^LOG2N / N = 1.6 at
5120 (8/5). Use one pipelined DSP multiply in S_INV2/S_INV3, or fold `x 1.6` into the rsqrt
seed and the exponent. Turn the line-578 assert into an out-of-range-natural elaboration pin
for any N the reciprocal path does not cover. The failing test to write first: a
`sim/tb_rmsnorm_bf_mem` row at N = 5120 against a float oracle. Today that row fails at
elaboration on the assert, and after the fix it needs a value check. Fix
`ref/rmsnorm_bf_vec.c` with it.

**Open, not determined.**
- Whether the card picks 7732 once the fix is in. The INT4 ok model still picks 1206 at
  position 22, by 0.116 logit over 7732, against a 0.16-logprob instrument resolution. That
  is inside the noise, and it is a statement about the reference, not the card.
- The ok model sits at fit 0.92 against llama.cpp at die A's token 0 (rel 0.088). That is
  in line with the 9B's INT4-format cost (0.084), but at 27B it has not been attributed.
- At later positions the pow2 model matches the card less tightly (rel 0.10 at l_out-32
  and 0.30 at l_out-63, position 22). The non-A stages in run9b are float, not the card's
  fixed point, and that gap has not been separated from any second defect.
