# A whole-model numeric reference for Qwen3.5-9B, and the bisect that uses it

**Date:** 2026-08-29. Branch `fpga`. Track REF9B, backlog item 12.
**Model:** `/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf` (17.9 GB,
`general.architecture = qwen35`, 427 tensors).
**Packed set:** `/mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/`
(250 `.mv4i` + `nonmatvec_f32.bin`, `ROWS_IF = 48`, `AXI_DW = 256`,
`qkv_segment_pad = true`, 5,059,649,536 weight bytes).
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/`, nothing opening `/dev/xdma*`.

Labels used throughout: **MEASURED** (a tool ran, and it is named), **DERIVED**
(arithmetic shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

> `ref/` holds exactly one whole-model reference and it is stories260K. Every 9B
> claim to date is per-unit or per-seam. Until a fixed-point 9B reference stream
> exists, "first token" is UNFALSIFIABLE: the card will emit *a* token and no
> artefact in this repo can distinguish success from failure, and on-card
> numeric debugging has no stream to diff against.

And, as the substantive design question:

> **DECIDE AND JUSTIFY: float or fixed point.** State which you chose and how
> you defend against the failure mode of the one you chose. A defensible answer
> might be both, layered: float for algorithmic truth, fixed-point for
> bit-exactness, with the gap between them measured rather than assumed. If you
> propose that, say what the measured gap actually is.

---

## 2. The answer, up front

**A first token is now falsifiable, and the answer for this prompt is on disk.**
Three independent rungs -- llama.cpp on the BF16 checkpoint, an INT4-weight
float-activation reference, and the hardware's own INT4 + int16-BFP format
running `ref/matvec_int4.c` bit-exactly on the card's own packed bytes -- all
predict the **same next token id on all five positions of the reference
prompt**, and the two lower rungs agree on the top five candidates exactly.

**The decision is BOTH, LAYERED, and the gap is measured, not assumed.**
MEASURED at the logits, token 4, 32 layers:

| what it isolates | rel RMS at LOGITS | 1 - cos at LOGITS |
|---|---|---|
| INT4 **weight** format (rung 1 -> rung 2) | **0.1252** | 0.00685 |
| int16 BFP **activation** format (rung 2 -> rung 3) | **0.00313** | -- |
| both together (rung 1 -> rung 3) | 0.1257 | 0.00690 |

**The activation format the hardware uses costs 40x less than the weight format
that was already chosen, and neither compounds across 32 layers** (`l_out-7`
0.123, `l_out-15` 0.149, `l_out-31` 0.120). Nobody had measured either number.

**Cost, MEASURED:** 30.1 s per token for rung 3 at 4.5 GB RSS; 112 s per token
for rung 2; 17.3 s WALL for all five tokens of rung 1, of which about 13 s is
the 17.9 GB model load, at 17.4 GB RSS. Stream size 6.0 MB per token for rung 3
(BFP16), 14 MB for rung 1 (f32). 491 seams per token.

**The bisect works and has teeth.** Nine mutants, each a defect a careful person
would plausibly write. Against a same-format reference the harness locates
**8 of 9** at the correct seam; the ninth is bit-identical to the clean run and
therefore has nothing to detect. Against the float anchor it locates only 6 of
9, which is the single strongest argument for the fixed-point rung existing.

**Four things found on the way**, all reported rather than worked around:

1. **`rtl/llama_top.vhd` cannot emit a token.** Its own banner at `:133-134`:
   "There is no sampler and no lm_head output. The final A job is issued with
   dst = R_NONE and its result is discarded." The descriptor table asks for the
   opposite (`sim/seq_tbl_pkg.vhd:341` sets `FLG_TO_SMP`), and `FLG_TO_SMP`
   appears **nowhere** in `rtl/llama_top.vhd` (MEASURED by grep).
2. **The RMS norm at the top level uses a synthetic constant weight**, not the
   model's. `rtl/llama_top.vhd:1494` builds `W_CONST` as
   `2**12 + ((i*37) mod 512) - 256` and `:1546` passes it to the only
   `rmsnorm_rs` instance. No per-layer `attn_norm.weight` is wired anywhere.
3. **`rtl/model_cfg_pkg.vhd`'s `QWEN35_9B` record is CORRECT in every field**,
   MEASURED against the GGUF's own metadata. This closes audit section 5.3,
   which said the 248,320 vocabulary "has not been checked against a 9B GGUF,
   because there is no 9B GGUF here". There is one now, and it says 248,320.
4. **`tools/ref9b/bisect.py` shadowed the Python standard library.** Renamed to
   `seam_bisect.py`. Details in section 8.

---

## 3. The seam list, named from the RTL, and where it disagrees with the spec

The names are `rtl/llama_map_pkg.vhd`'s REGION names, not spec unit names,
because a region is what the hardware can actually be asked for:
`hr_reg`/`hr_addr`/`hr_data` (`rtl/llama_top.vhd:483-485`, combinational at
`:1005`) reads any element of any region, and `sim/seq_tbl_pkg.vhd`'s descriptor
table is written in exactly these names. A seam named after a spec unit would be
a seam nothing can capture.

491 seams per token. DERIVED: 16 per GDN block x 24 = 384, 13 per attention
block x 8 = 104, plus the embedding, the final norm and the logits = 491, which
is what the stream contains (2455 records for 5 tokens).

| RTL seam | llama.cpp node | notes |
|---|---|---|
| `R_X.embed` | `model.input_embed` | gather, not a matvec |
| `R_XN-L` | `attn_norm-L` | **RTL uses `W_CONST`, not the model weight** |
| `R_QKV.q-L` | `linear_attn_qkv_mixed-L[0:2048]` | separate A job, own exponent |
| `R_QKV.k-L` | `linear_attn_qkv_mixed-L[2048:4096]` | packed rows start at **2064** |
| `R_QKV.v-L` | `linear_attn_qkv_mixed-L[4096:8192]` | packed rows start at **4128** |
| `R_Z-L` | `z-L` | `attn_gate.weight` |
| `R_BETA-L` | `beta-L` | pre-sigmoid, 32 values |
| `R_ALPHA-L` | `alpha-L` | pre-softplus, 32 values |
| `R_Y-L` (GDN) | `final_output-L` | after `ssm_norm` then the `silu(z)` gate |
| `R_ER-L` (GDN) | `linear_attn_out-L` | `ssm_out.weight` |
| `R_QG-L` | `Qcur_full-L` | 8192, q and gate **interleaved per head** |
| `R_KIN-L` | `Kcur-L` (first occurrence) | raw projection, pre-norm, pre-RoPE |
| `R_VIN-L` | `Vcur-L` (first occurrence) | |
| `R_Y-L` (attn) | `attn_gated-L` | after the sigmoid gate |
| `R_ER-L` (attn) | `attn_output-L` | `attn_output.weight` |
| `R_X.attn-L` | `attn_residual-L` | first residual |
| `R_XN.ffn-L` | `attn_post_norm-L` | `post_attention_norm.weight` |
| `R_G-L` / `R_U-L` / `R_H-L` | `ffn_gate-L` / `ffn_up-L` / `ffn_swiglu-L` | |
| `R_ER.ffn-L` | `ffn_out-L` | `ffn_down.weight` |
| `R_X-L` | `l_out-L` | second residual |
| `R_XN.final` | `result_norm` | |
| `LOGITS` | `result_output` | **no RTL counterpart, see D1** |

Machine-readable in `tools/ref9b/seam_map.py`.

### 3.1 Structural disagreements, and which side is right

**S1. `R_QKV` is three jobs with three exponents; llama.cpp has one tensor.**
The packer pads the fused `attn_qkv` segments to tile-aligned starts 0 / 2064 /
4128 because a row window must begin on a tile boundary and `2048 mod 48 = 32`.
llama.cpp's segments are at 0 / 2048 / 4096. Both are right about their own
artefact; the map slices the anchor. The hardware's three block exponents have
no counterpart on the anchor side at all -- there is nothing in a float stream
that a shared exponent can be compared against. Mutant 8 exists precisely
because reading the unpadded starts is the plausible way to get this wrong.

**S2. `R_QG` is interleaved per head and both sides know it.** The 8192 rows are
`[h0 q(256) | h0 gate(256) | h1 q(256) | ...]`, fixed by llama.cpp's two
`ggml_view_3d` calls with row stride `2*head_dim`. `sim/seq_tbl_pkg.vhd:81`
says `ATT_QG : natural := 2 * ATT_Q; -- Q and gate interleaved` and `:57` says
`R_QG ... attention Q + gate, interleaved`. **No disagreement.** Recorded
because it is the highest-value latent trap in subsystem C's consumer -- every
other fused projection in this model is block-split -- and mutant 1 measures
what it would cost.

**S3. Audit section 1.4's spec/RTL split for subsystem C stands**, and this
track adds nothing to it. Six spec-named C units still do not exist; that is
backlog item 9 and is not touched here.

### 3.2 Defects found in the RTL (reported, not fixed -- this track owns no RTL)

**D1. The design cannot emit a token.** `sim/seq_tbl_pkg.vhd:336-341` emits the
lm_head A job with `flags => FLG_TO_SMP, dst => R_NONE`, described in its own
comment as "lm_head in raw mode straight into the sampler ... the one job whose
destination is 0xFF with the sampler route flag, which is exactly the case the
decoder checks." `grep -n "FLG_TO_SMP\|sampler" rtl/llama_top.vhd` returns only
two comment lines, one of which (`:133-134`) states the gap outright. So the
descriptor asks for a sampler route and the top level implements none.

Consequence for this track, and it is the reason `LOGITS` has no RTL
counterpart above: **the last seam of the reference is the one seam the current
design cannot produce.** Falsifying a first token on silicon therefore needs
backlog item 4 (token I/O) to land first, or needs the host to read `R_XN`
(which IS reachable over `hr_reg`) and run the lm_head itself.

**D2. The top-level norm weight is synthetic.** `rtl/llama_top.vhd:1494` builds
`W_CONST(i) = 2**NORM_W_EXP + ((i * 37) mod 512) - 256` with `NORM_W_EXP = 12`,
and `:1546` is the only place a norm weight reaches `rmsnorm_rs`. Every
`R_XN-L` and `R_XN.ffn-L` the hardware produces today is therefore normalised
by a ramp, not by `blk.L.attn_norm.weight`. This is a known-incomplete area
rather than a surprise, but it means those two seams cannot be compared against
this reference at all until the real weights are wired, and there is currently
no committed statement of that anywhere.

**D3, NOT a defect, recorded because it was expected to be one.** The three
`R_QKV` A jobs in `sim/seq_tbl_pkg.vhd:300-308` carry `dst_off` 0 / `KEY_DIM` /
`2*KEY_DIM`, which are the DESTINATION offsets inside the region and are
correct. The SOURCE row window (0 / 2064 / 4128) is not in the descriptor table
because it lives in the weight base pointers a program generator would emit,
and no such generator exists (backlog item 6, OI-4). **Not determined:** whether
`tools/gen_layer_program.py` gets those three bases right. It is another
track's file and was not read.

---

## 4. The procedure, in the order it was run

Each step's purpose is to control for exactly one thing.

1. **Read the GGUF metadata directly** (`python3`, raw struct unpack, 42 keys).
   Controls for: whether `rtl/model_cfg_pkg.vhd` describes this checkpoint at
   all. Everything downstream is meaningless if the shape is wrong.
2. **Confirm llama.cpp can run this architecture**, and time it.
   `~/GitHub/llama.cpp.upstream` has `qwen35` in `src/llama-arch.cpp:41`.
   Controls for: whether an external anchor is available at all. If it were
   not, the whole float rung would have to be self-written and the m7 defence
   would be gone.
3. **Measure the cost of one bit-exact INT4 matvec** before designing anything
   that needs many. A throwaway probe on `output.weight` (1.017e9 MAC).
   Controls for: committing to a plan the machine cannot afford.
4. **Build the anchor dumper** (`tools/ref9b/dump_llamacpp.cpp`) and run its
   `--selfcheck`. Controls for: the callback perturbing the graph it observes.
5. **Build the reference** (`ref/run9b.c`) and run `--selftest`. Controls for:
   the one piece of arithmetic this file re-expresses rather than reuses.
6. **Compare rung 3 against rung 1** seam by seam. Controls for: nothing yet --
   this is the measurement.
7. **Compare rung 2 against rung 1 and rung 3 against rung 2.** Controls for:
   attributing the total error to the wrong format.
8. **Nine mutants, in both bisect modes.** Controls for: a harness that agrees
   with itself and cannot fail.
9. **Extend to 21 tokens for the two position-dependent mutants.** Controls
   for: calling a mutant undetectable when it was only untested at short
   context.
10. **Full unfiltered gate.** Controls for: this track having broken something.

---

## 5. The evidence, as raw captured output

### 5.1 The GGUF says exactly what `model_cfg_pkg` says

```
general.architecture = qwen35
qwen35.block_count = 32                 qwen35.embedding_length = 4096
qwen35.feed_forward_length = 12288      qwen35.attention.head_count = 16
qwen35.attention.head_count_kv = 4      qwen35.attention.key_length = 256
qwen35.attention.value_length = 256     qwen35.full_attention_interval = 4
qwen35.ssm.conv_kernel = 4              qwen35.ssm.state_size = 128
qwen35.ssm.group_count = 16             qwen35.ssm.time_step_rank = 32
qwen35.ssm.inner_size = 4096            qwen35.rope.dimension_count = 64
qwen35.rope.freq_base = 10000000.0      qwen35.rope.dimension_sections = [11, 11, 10, 0]
qwen35.attention.layer_norm_rms_epsilon = 9.999999974752427e-07
tokenizer.ggml.tokens = arr[str,248320]
```

Every field matches `rtl/model_cfg_pkg.vhd:64-70`. There is **no**
`qwen35.attention.recurrent_layers` key, so the `(il+1) % 4 != 0` default rule
applies and `is_attn_block` in `llama_map_pkg` is right.

`output.weight` and `token_embd.weight` are **separate tensors** in the packed
set (both M=248320), so the LM head is **not tied** to the embedding.

### 5.2 Cost per token, MEASURED

```
# llama.cpp, BF16, CPU, 5 tokens including a 17.9 GB model load
WALL 17.31 s   MAXRSS 17765588 kB

# ref/run9b --acts bfp   (rung 3, the hardware model)
TOKEN 0 id=760   argmax=2614   logit=12.382477  32.48 s
TOKEN 1 id=6511  argmax=314    logit=17.050171  30.18 s
TOKEN 2 id=314   argmax=279    logit=14.794373  30.09 s
TOKEN 3 id=9338  argmax=369    logit=19.442627  30.04 s
TOKEN 4 id=369   argmax=11751  logit=17.576599  30.11 s
WALL 153.00 s   MAXRSS 4491652 kB

# ref/run9b --acts f32    (rung 2)
TOKEN 4 id=369   argmax=11751  logit=17.580719  114.73 s
WALL 562.21 s
```

DERIVED: 7.94e9 MAC per token excluding the embedding gather; 240-288 MMAC/s
single-threaded with assertions on, hence ~30 s. Rung 2 is 3.7x slower because
`w_deq` calls `get_widx`/`get_scale` per element rather than per block.

**Budget for the next track: one rung-3 token is 30 s, 4.5 GB of RSS and 6.0 MB
of stream. There is no reason to be frugal with tokens; there is every reason to
be frugal with `--acts f32`, which is 3.7x slower because `w_deq` re-derives the
byte offset per element rather than per block.**

### 5.3 The anchor does not perturb the graph it observes

```
SELFCHECK argmax_nocb=11751 argmax_cb=11751 ndiff=0/248320 worst_abs=0 at=-1
SELFCHECK VERDICT: bit-identical with and without the callback.
```

The check is on the **full** 248,320-wide logit vector, not the argmax: an
argmax can survive a change that moved every logit.

### 5.4 The one piece of arithmetic this reference re-expresses is exact

`mv4i_matvec` has no row window, and the fused `attn_qkv` needs three. So a job
runs in `MV4I_MODE_RAW` and the BFP scan is done over the window using the same
generated primitives from `ref/mv4i_arith.h`. A full-range window must therefore
reproduce `MV4I_MODE_BFP` bit for bit:

```
SELFTEST blk.0.ssm_out.weight         M=4096    exp 2 vs 2  mismatches=0  exact
SELFTEST blk.3.attn_k.weight          M=1024    exp 2 vs 2  mismatches=0  exact
SELFTEST blk.0.ffn_down.weight        M=4096    exp 2 vs 2  mismatches=0  exact
```

And, because the mutants are `#if` blocks threaded through the same file, the
clean build after they were added must still reproduce the stream that was
measured before they existed:

```
# exact compare, token 0: 491 seams identical, 0 differ
EVERY COMPARED SEAM IS BIT-IDENTICAL.
```

### 5.5 The token-level result: all three rungs agree

```
tok0 anchor top5 [2614, 7193,  220, 20438, 3049]
     rung2  top5 [2614, 7193, 1414,  3788, 3049]
     rung3  top5 [2614, 7193, 1414,  3788, 3049]
tok1 anchor top5 [ 314, 3177, 5416,  6321, 2695]
     rung2  top5 [ 314, 3177, 6321,  1954, 5416]
     rung3  top5 [ 314, 3177, 6321,  1954, 5416]
tok2 anchor top5 [ 279,  264, 6535,  9338, 1478]
     rung2  top5 [ 279,  264, 6535,  9338, 15477]
     rung3  top5 [ 279,  264, 6535,  9338, 15477]
tok3 anchor top5 [ 369,   11,   13,   682,  321]
     rung2  top5 [ 369,   11,   13,   682,  321]
     rung3  top5 [ 369,   11,   13,   682,  321]
tok4 anchor top5 [11751,  264, 3750,  1259, 6924]
     rung2  top5 [11751,  264, 1259,  3750, 7172]
     rung3  top5 [11751,  264, 1259,  3750, 7172]
```

Argmax matches on 5 of 5. Top-2 matches on 5 of 5. **Rung 2 and rung 3 have
identical top-5 on every position**, which is the token-level statement of the
0.31% activation-format number.

Decoding rung 3's argmax chain through the GGUF's own vocabulary:

```
prompt token        rung-3 prediction
"The"            -> " following"
"The capital"    -> " of"
"The capital of" -> " the"
"...France"      -> " is"
"...France is"   -> " Paris"
```

This is a **qualitative** check and it is labelled as one: it is not numeric and
it is not a substitute for the seam comparison. It is here because it is the
only evidence in this document that bears at all on section 6's single point of
failure -- a checkpoint loaded wrongly, or an architecture implemented wrongly
by llama.cpp, would be very unlikely to produce five consecutive linguistically
correct continuations through a chain that also passes through 24 Gated
DeltaNet recurrences and 8 gated-attention blocks.

### 5.6 The layered gap, per seam, token 4

`w:1->2` is the INT4 weight format alone, `a:2->3` the BFP activation format
alone, `tot:1->3` both. All are relative RMS against the stated denominator.

```
seam           anchor node                  w:1->2     a:2->3   tot:1->3 | 1-cos 1->2 1-cos 1->3
R_X.embed      model.input_embed           0.09398  0.0003942    0.09398 |    0.00403    0.00403
R_XN-0         attn_norm-0                 0.08254  0.0006109    0.08252 |    0.00341    0.00341
R_QKV.q-0      linear_attn_qkv_mixed-0     0.04839  0.0003469    0.04841 |    0.00106    0.00106
R_Y-0          final_output-0              0.01851  0.0005736    0.01849 |   0.000169   0.000169
R_ER-0         linear_attn_out-0           0.04062   0.001173    0.04103 |     0.0008   0.000816
R_X-0          l_out-0                     0.05477   0.001771    0.05511 |    0.00114    0.00116
R_X-7          l_out-7                      0.1227   0.003483     0.1232 |    0.00742    0.00747
R_X-15         l_out-15                     0.1476   0.004349     0.1487 |     0.0108      0.011
R_X-23         l_out-23                     0.1393   0.004656     0.1403 |     0.0094    0.00956
R_X-31         l_out-31                     0.1195   0.004245     0.1201 |    0.00697    0.00705
R_XN.final     result_norm                  0.1212   0.004321     0.1218 |    0.00734    0.00741
LOGITS         result_output                0.1252    0.00313     0.1257 |    0.00685     0.0069
```

Two readings that matter more than the headline:

- **The error saturates rather than compounding.** It rises through the first
  eight blocks and then sits between 0.12 and 0.15 for the remaining 24. An
  error that compounded would put a 32-layer model far past 1.0.
- **The angular error is two orders of magnitude smaller than the RMS error**
  (0.0069 against 0.126 at the logits). The INT4 format is mostly changing
  magnitudes, not directions, which is exactly why the argmax survives.

### 5.7 The mutation table

Nine mutants, each a defect a careful person would plausibly write, all
reachable as `-DREF9B_MUT=n` in `ref/run9b.c`. Both bisect modes were run at
token 2 of the reference prompt.

| # | mutant | cross mode, vs the float anchor | exact mode, vs the reference |
|---|---|---|---|
| 1 | `R_QG` read block-split instead of interleaved | **R_Y-3** | **R_Y-3**, exp 14 vs 13, 4071/4096 |
| 2 | l2norm `sqrt(s+eps)` instead of `max(sqrt(s),eps)` | **NOT FOUND** | **R_Y-1**, 430/4096 |
| 3 | GDN value head `h` reads key head `h/2` not `h%16` | **R_Y-0** | **R_Y-0**, exp 13 vs 14, 4030/4096 |
| 4 | RoPE pairs `(2i, 2i+1)` instead of `(i, i+32)` | **NOT FOUND** | **R_Y-3**, 2680/4096 |
| 5 | `ssm_norm` applied AFTER the z gate | **R_Y-0** | **R_Y-0**, exp 13 vs 12, 3929/4096 |
| 6 | softplus without ggml's passthrough above 20 | **INERT** | **INERT** (bit-identical) |
| 7 | rmsnorm eps added outside the sqrt | **R_Y-0** (weak) | **R_XN-0**, 1477/4096 |
| 8 | qkv segments read at unpadded 0/2048/4096 | **R_QKV.k-0** | **R_QKV.k-0**, 2048/2048 |
| 9 | attention q head `h` -> kv head `h%4` not `h/4` | **R_Y-3** | **R_Y-3**, exp 14 vs 16, 4076/4096 |

Every located seam is the correct one. Mutant 8 is the sharpest case: the `q`
segment starts at row 0 in both the padded and unpadded plans, so it is
unaffected, and `R_QKV.k-0` is the **first** seam that could possibly move.

**The three rows that do not bite are the most valuable rows here.**

- **Mutant 6 is INERT, not undetected.** The stream is bit-identical to clean,
  all 491 seams. `a_softplus-0` reaches 23.6, so the clamp branch IS taken, but
  `log1p(exp(23.6))` in double is 23.6 to full precision. The clamp exists for
  float32, and at double there is nothing to detect. Do not read this row as a
  gap in the checker.
- **Mutant 2 is BELOW THE INT4 NOISE FLOOR in cross mode and found in exact
  mode.** `sqrt(s + 1e-6)` differs from `max(sqrt(s), 1e-6)` by ~5e-7 relative
  when `s` is O(1); the resulting change (430 of 4096 mantissas at `R_Y-1`)
  never rises to 3x the clean-run baseline anywhere. **This is the harness's
  measured cross-mode resolution floor: a defect whose effect is smaller than
  the INT4 weight format's own error cannot be found by comparison against the
  float anchor, at any threshold, ever.**
- **Mutant 4 is nearly invisible at short context and grows with position.**
  MEASURED at `R_Y-7` over 21 tokens, against the clean run at the same
  position:

  | token | clean | mutant 4 | mutant 2 |
  |---|---|---|---|
  | 2 | 0.189 | 0.1918 | 0.1886 |
  | 6 | 0.2027 | 0.2485 | 0.2018 |
  | 10 | 0.1896 | 0.3616 | 0.1894 |
  | 14 | 0.2403 | 0.3164 | 0.2398 |
  | 20 | 0.2471 | 0.2962 | 0.2483 |

  The trend is unmistakable and the gate still never fires at 21 tokens.
  DERIVED explanation: at position `p` the rotation angle of pair `i` is
  `p * 1e7^(-2i/64)`, which is below 0.02 rad for `i >= 10`, so only about five
  of the 32 pairs move at all, and RoPE touches only 64 of each head's 256
  dims. A wrong pairing is still a consistent orthogonal transform, so the
  relative-position property survives it and only the frequency assignment
  changes. **Consequence for bring-up: no test at short context can validate
  the RoPE pairing convention. Do not treat a passing 4-token run as evidence
  about RoPE.**

### 5.8 The exact mode resolves one LSB, MEASURED

`--mode exact` was useless until something other than `ref/run9b.c` could write
the format, because neither a GHDL testbench nor the FK33 host driver is going
to emit a binary struct.  `tools/ref9b/capture_to_r9bs.py` is that bridge: a
line-oriented text format either can emit, converted to `.r9bs`.

Its `--selftest` is a ROUND TRIP and is labelled as one -- it prices the
parser, not the capture, and a round trip is not an oracle.  The teeth-check
that means something is a deliberate single-LSB corruption of one mantissa in
one seam, converted and compared:

```
round trip: 491 records bit-identical.  This prices the PARSER; it says
nothing about whether a capture is right.

perturbed one mantissa of R_XN-0
# exact compare, token 0: 490 seams identical, 1 differ
FIRST DIVERGENCE: R_XN-0 at element 3 -- exp 10 vs 10, 1 of 4096 mantissas differ
```

**One LSB in 4096 values, named to the element.** That is the resolution the
card will be debugged at, and it is three to four orders of magnitude finer
than anything the float anchor can offer.

### 5.9 The exact mode is the sharper instrument, and by how much

Cross mode locates 6 of 9; exact mode locates 8 of 9 and, for mutant 7,
localises it one seam EARLIER -- `R_XN-0`, the very first norm of the model,
rather than `R_Y-0` at the end of the first block. That difference is the whole
case for the fixed-point rung: **a float oracle can tell you the algorithm is
wrong; only a same-format oracle can tell you which cycle to look at.**

---

## 6. What makes this trustworthy, and what would make it confidently wrong

**Trustworthy:**

- The algorithmic truth comes from llama.cpp, which nobody on this project
  wrote and which is exercised against the published checkpoint by a large user
  base. This is the same anchor that certified the tokenizer bit-exactly over
  53,409 strings, so the method has precedent here.
- The weights are the **card's own bytes**. `ref/run9b.c` mmaps the `.mv4i`
  files and reads them through `ref/matvec_int4.c`'s own `get_widx`/`get_scale`
  accessors, so the byte layout has exactly one implementation in the loop and
  a re-quantization cannot silently differ.
- The A arithmetic is `mv4i_matvec`, already depended on by TRACK A-CTRL,
  A-SHAPE and OUTMODE, and the four rounding primitives come from
  `ref/mv4i_arith.h`, which `tools/gen_arith.py` generates into both this file
  and `rtl/mv4i_arith_pkg.vhd` from one description.
- The one arithmetic statement re-expressed here (the windowed BFP scan) is
  checked bit-for-bit against the version it replaces, and the run refuses to
  continue if it is not exact.
- Nine mutants, eight located, and the three non-biting rows explained with
  numbers rather than dismissed.

**What would make it confidently wrong:**

- **If llama.cpp's `qwen35` implementation is itself wrong for this
  checkpoint, all three rungs agree and all three are wrong.** This is a single
  point of failure and NOTHING in this repository closes it. The cheap partial
  defence is that the reference prompt's continuations are linguistically
  correct (`"The capital of France is"` -> id 11751, and the model then
  continues the pattern), but that is not a numeric check and is not claimed as
  one.
- **The rung-2/rung-3 gap is measured on ONE prompt of five tokens.** The
  0.31% activation-format figure is a measurement of this prompt, not a bound.
- **The interior of every block is float.** Where the RTL's fixed-point recipe
  for the conv, the L2 norm, the delta rule, the softmax or the swiglu differs
  numerically from double arithmetic, this reference will disagree with correct
  hardware. Those stages are marked `FX-HOOK` in `ref/run9b.c` and each one
  that lands should be measured on the way in.

---

## 7. Measured and REJECTED -- do not retry

**A flat relative-RMS threshold as the cross-mode gate. REJECTED, with the
number that killed it.** The clean reference sits at rel_rms **0.105 at the very
first seam** (the embedding) and 0.05 to 0.25 everywhere after, because that is
the INT4 weight format's own error. At threshold 0.05, **483 of 491 seams**
report as diverged on a clean run. There is no flat threshold that both stays
silent on a clean run and fires on mutant 2. The gate is per-seam
baseline-relative instead (`--baseline`, `--factor`), which is the only form
that survived.

**Building the anchor against `~/GitHub/llama.cpp.upstream`'s prebuilt
libraries. REJECTED.** That tree's HEAD is dated 2026-08-14 and its
`build/bin/libllama.so.0` is dated 2026-06-26, so the public headers and the
shared object are two months apart. The mismatch is silent at compile and link
time and surfaces as `llama_init_from_model: failed to initialize the context:
Unsupported ctx type`, because `llama_context_params` gained a `ctx_type` field
the built library does not know about. Build against
`/mnt/storage/llama-dflash2-src` instead, whose source (2026-08-18) and build
(2026-08-19) agree and which also has `qwen35`.

**Substring matching on ggml node names. REJECTED.** ggml derives names by
suffixing, so `Qcur-3` spawns `Qcur-3 (view)` and `Qcur-3 (view) (permuted)`. A
substring filter takes all three; the permuted one is not contiguous, so a
row-major read of it records a tensor that never existed, and `ggml_nbytes` of
it exceeds `ggml_nelements * 4`, which overruns the buffer. It presented as
`malloc(): invalid size (unsorted)` and SIGABRT, ~1800 nodes into the graph.
The filter now matches `<prefix><digits>` exactly and there is a contiguity gate
behind it.

**Running the anchor on the GPUs. REJECTED, deliberately and without
measuring.** `llama-cpp-server` holds ~18 GB of GPU0 and is a service the owner
uses. Every run here is `-ngl 0` with `CUDA_VISIBLE_DEVICES=""`.

**Parsing `manifest.json` in C. REJECTED.** `ref/run9b.c` is the numeric
reference; every line in it that is not arithmetic is a line that can be wrong
with no oracle watching. `tools/ref9b/make_index.py` does the structural read in
the same language the packer is written in and emits a format `fscanf` cannot
misread.

**Re-deriving subsystem B and C's fixed-point recipes for this reference.
REJECTED as the m7 mutant.** Their recipes live in about twenty units with no
composed description at the 9B shape, and re-deriving them from the specs is
exactly how a second implementation of the same misunderstanding gets written.
The interior is float and the file says so in its header.

---

## 8. Measurement traps hit, including my own

**T1. A file named `bisect.py` in a tools directory shadows the Python standard
library.** It broke `random`, which broke `tempfile`, which broke Ubuntu's
`apport` excepthook, so an unrelated `KeyError` printed as an `ImportError`
raised *inside the crash handler* and the original exception was almost lost.
Renamed to `seam_bisect.py`. **Generalise it: any new `tools/<dir>/*.py` name
should be checked against the stdlib module list before it is committed.**

**T2. `1 - cos` and relative RMS answer different questions and this data
separates them.** At the logits the RMS error is 0.126 and the angular error is
0.0069. A defect that rotates a vector without changing its norm -- which is
what a wrong permutation, a wrong head mapping or a wrong interleave does -- is
under-reported by RMS. The gate therefore tests both, and mutants 1, 8 and 9 all
show `1-cos` near 0.8 to 1.0 while their RMS is a factor of a few.

**T3. Relative RMS on a low-magnitude seam is misleading.** `R_Y-24` at token 0
reports rel_rms **0.75**, ten times its neighbours, and it is not a defect: the
anchor's own RMS there is 0.0969 against 0.35 and 0.86 at layers 25 and 26, so
it is a quiet seam and the same absolute error reads as a huge relative one. The
per-seam baseline absorbs this; a global threshold would have flagged it
forever. It is also why the mutation table reports the seam the gate FIRES on
rather than the seam with the largest ratio.

**T4. A `cb_eval` callback can perturb the graph it observes**, because asking
for a node makes `ggml_backend_sched` cut the graph there and a suppressed
fusion changes rounding. MEASURED here as zero effect
(`ndiff=0/248320`), but the check has to be run, not assumed;
`tools/bfx/gdn_probe.cpp` records the same hazard under the name `identity`.

**T5. My own: I nearly reported the lm_head as "discarded" from a subagent's
reading.** The descriptor table actually sets `FLG_TO_SMP` and calls it "straight
into the sampler". The defect is real but it is in the TOP LEVEL, not the
table, and the two claims point at different files. Reading
`sim/seq_tbl_pkg.vhd:336-341` and grepping `rtl/llama_top.vhd` took under a
minute and changed the finding.

**T7. The root `.gitignore` was being staged by another track at commit time.**
`git status` showed it as `MM`: their hunk in the index (three `server/*` build
products), my two lines in the working tree. A pathspec commit on a shared file
takes the WORKING TREE, so `git commit -- .gitignore` would have swept their
staged hunk into a commit whose message described neither -- which is exactly
the `4891c6d` defect the worklog already records. **Staging only my hunk would
NOT have helped either, because theirs was already staged.** Resolved
structurally rather than carefully: `ref/.gitignore` and
`tools/ref9b/.gitignore`, directory-local files that exactly one track owns and
that cannot collide. **Generalise it: when a shared file already has another
track's changes in the INDEX, there is no safe way to commit it, and the fix is
to stop needing to.**

**T6. My own: the first cross-mode run reported `FIRST DIVERGENCE: R_X.embed`
and 483 of 491 seams diverged, and for a few minutes that looked like a
catastrophic defect.** It is the INT4 format's own error against a BF16 anchor.
The tell was that `1-cos` stayed at 0.004 while `rel_rms` was 0.10, and that
the argmax matched. **A metric that fires on everything has told you about
itself, not about the thing under test.**

---

## 9. Explicitly NOT verified

- **Nothing here has been compared against hardware or against GHDL.** No
  simulation capture in `.r9bs` format exists. The `--mode exact` path is
  exercised only by mutant-vs-reference and by a synthetic single-LSB
  corruption, both of which come from the same producer.
  `tools/ref9b/capture_to_r9bs.py` now removes the format as an obstacle -- a
  GHDL bench or the host driver can emit text -- but **emitting that text from
  `sim/tb_llama_top*` is NOT done**, and that file belongs to TRACK TOP-KV. It
  is the obvious next step and it is the only step between this reference and
  an actual bisect of the machine.
- **`R_XN-L` and `R_XN.ffn-L` cannot be compared against the RTL at all today**,
  because of D2 (synthetic norm weight).
- **`LOGITS` has no RTL counterpart**, because of D1.
- **The interior of every block is float.** No claim of bit-exactness is made
  for the conv, the L2 norm, the beta/alpha path, the delta-rule recurrence,
  the output norm, the z gate, the attention kernel, the SwiGLU, the residual
  add, or the float-to-BFP repack at region boundaries.
- **The float-to-BFP repack is VALUE-equivalent to `rtl/bfp_pack.vhd`, not
  proven bit-identical to it.** `bfp_pack` shifts an int32 Q-grid input;
  `reg_put` shifts a double. The rule (`shift so the max lands in bit 14`,
  round half toward +inf, saturate) is the same and the exponent convention is
  the same, but no test compares them.
- **Only one prompt, 5 tokens (21 for the two position-dependent mutants).**
  No perplexity, no corpus, no sampling. In particular **the perplexity number
  in `docs/2026-08-27_epsilon-class-measurement-plan.md` is still on the WRONG
  MODEL (Qwen3.8-27B) and this track did not re-run it.** It remains not
  citable for the 9B.
- **The KV cache in the reference is a plain float array, not the packed
  per-block int8 BFP records `attn_kv_axi` writes.** So `R_KIN`/`R_VIN` can be
  compared but the cache contents cannot.
- ~~**The manifest hashes are not verified.**~~ **WITHDRAWN, see 11.1:**
  `tools/check_mv4i_set.py --full` hashed all 251 payloads (5,059,649,536
  bytes) against the manifest with 0 mismatches. Note that `ref/run9b.c` itself
  still checks only the index against each file's own header (M, K, w_exp,
  out_shift); the hash check is a separate tool that has to be run.
- **Multi-card (`NCARDS > 1`) is not modelled**, and `MV4I_MODE_PARTIAL` is
  never exercised.
- **`tools/gen_layer_program.py` was not read**, so whether the three `attn_qkv`
  weight base pointers land on 0 / 2064 / 4128 is not determined (D3).

---

## 10. Files

| file | what it is |
|---|---|
| `ref/run9b.c` | the reference. `--acts bfp` (rung 3) / `--acts f32` (rung 2), `--selftest`, `-DREF9B_MUT=n` |
| `tools/ref9b/seam_stream.h` | the `.r9bs` format, shared by every producer |
| `tools/ref9b/dump_llamacpp.cpp` | the external float anchor, via `cb_eval` |
| `tools/ref9b/build.sh` | builds the anchor against a prebuilt llama.cpp, writing nothing into it |
| `tools/ref9b/make_index.py` | `manifest.json` -> the flat index the C reads |
| `tools/ref9b/r9bs.py` | stream reader; run it on a file to dump per-seam statistics |
| `tools/ref9b/seam_map.py` | RTL seam name -> llama.cpp node, with the slices |
| `tools/ref9b/seam_bisect.py` | the bisect. `--mode cross` / `--mode exact`, `--baseline` |
| `tools/ref9b/capture_to_r9bs.py` | a line-oriented TEXT capture -> `.r9bs`, and back with `--from-r9bs`. This is what lets a GHDL bench or the FK33 driver feed `--mode exact` |

Reproduce:

```sh
python3 tools/ref9b/make_index.py /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad
gcc -O2 -Wall -Wextra -I ref -o ref/run9b ref/run9b.c -lm
LLAMA_SRC=/mnt/storage/llama-dflash2-src bash tools/ref9b/build.sh

CUDA_VISIBLE_DEVICES= ./tools/ref9b/dump_llamacpp \
  -m /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf \
  -o anchor.r9bs --tokens 760,6511,314,9338,369 -ngl 0 --selfcheck

./ref/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad --selftest
./ref/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad \
  --tokens 760,6511,314,9338,369 --out ref.r9bs

cd tools/ref9b
python3 seam_bisect.py ../../ref.r9bs ../../anchor.r9bs --tok 4 \
        --write-baseline base4.txt              # once, on a clean run
python3 seam_bisect.py suspect.r9bs ../../anchor.r9bs --tok 4 --baseline base4.txt
python3 seam_bisect.py ../../ref.r9bs capture.r9bs --mode exact --tok 4
```

The gate is untouched: this track adds no `sim/tb_*.vhd`, so `BASELINE_PASS`
stays at 83. The full-gate result is in section 11.

---

## 11. Full gate

Full unfiltered run, `REGRESS_SCRATCH=<scratch> bash sim/regress.sh`, no
`--only`, started 09:09:05 on 2026-08-29 and run under heavy contention (up to
seven concurrent `ghdl-mcode` processes from other tracks, against this run's
two jobs).

```
 suite sim   PASS 57   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 83   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 83 passing, matches the recorded floor of 83
 REGRESSION: PASS
```

**`OVERALL PASS 83`, `FAIL 0`, matching the recorded floor.** This track adds no
`sim/tb_*.vhd`, so `BASELINE_PASS` was neither raised nor touched.

### 11.1 The packed set itself, re-verified

The claim that this reference reads "the card's own bytes" is worth only as much
as the bytes being the ones the packer wrote. `tools/check_mv4i_set.py --full`
already existed for this and was run rather than duplicated:

```
250 packed tensors + 1 F32 side file, 5059649536 bytes total, 251 payloads hashed and matched
PASS  every header, size, sub-region offset and HBM placement is as spec 6.4/6.5a requires
```

All 251 blake2b-128 digests match the manifest. This supersedes the "only 3 of
250 packed tensors had their hash checked -- in fact none did" line that stood
in section 9 while the run was pending; that line is withdrawn.

---

## 12. Corrections

None yet. Append here rather than editing anything above.
