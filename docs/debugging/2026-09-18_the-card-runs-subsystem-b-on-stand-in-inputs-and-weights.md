# 2026-09-18: the card runs subsystem B on stand-in inputs and stand-in weights

## The question

Verbatim, from the bring-up session of 2026-09-18, bitstream
`hw/fk33/bit/fk33_card_xexp_wdog_seam_75mhz_2026-09-18.bit` (sha256 a52013f2..,
WNS +0.143 at 75 MHz), weights `qwen35-9b-mv4i-noembd` loaded and verified:

> Four whole tokens ran on the composed card (B completes, 0.80 s/token,
> FAULTS 0), and the card's argmax is wrong AND input-independent: 151353 for
> every input. A probe bisection against the rung-3 stream matches at steps
> 1-6 (qkv.q 838, k 1286, v 113, Z 2395, BETA 2, ALPHA 4) and first mismatches
> at step 8 (ssm_out, the first job consuming B's output Y): card 2768,
> reference 3994. Is it the `ga_desc` region drain (a), or subsystem B (b)?

## The answer

**Neither is a defect. The card build never asked for the model.**
`hw/fk33/gen_fk33_card.py` passes 17 generics to `fk33_llama_top` and
**`B_SRC_REAL` is not one of them**, so it elaborates FALSE: on the card,
subsystem B's conv taps, alpha and beta are `m12` stand-ins, deterministic
functions of their index (`rtl/fk33_llama_top.vhd:5174, :5220-5221`). B
reads exactly ONE per-token input, z from R_Z. Its output Y therefore cannot
equal the reference's Y for any input, and step 8 is exactly where the first
B-derived value enters the A chain.

Independently of that switch, four learned constants have **no path onto the
card at all** and are stand-ins in every configuration (`:4068-4071`): the
conv WEIGHTS (`:5133`), `ssm_dt_bias` and `ssm_a` (`:5204, :5208`) and the
`ssm_norm` weight (`:5231`). The D-vec norm gain is the synthetic ramp
`2^12 + ((i*37) mod 512) - 256` because `NORM_W_IMAGE` is also not passed
(`:2116`), and C's QK-norm gains are stand-ins (`:5766`). So a correct token
needs FOUR things the current card does not have, of which one is a generic
and three are new data paths.

The region drain (a) is CLEARED by measurement (below): A jobs reading the
A-drained regions Z and QKV produce the reference argmax.

## The procedure

Every probe is a truncated token program with `FLG_TO_SMP` on its last A job
(`tools/gen_layer_program.py --upto N --probe-smp --close-token`), run on the
card with `server/run_prompt --allow-hardware HOST --seq-reset`, and the
card's `ARGMAX` compared against `ref/matvec_int4.c` (`MV4I_MODE_RAW`, first
max wins) on the rung-3 stream's mantissas for token 248045
(`ref/run9b --acts bfp`, `$SD/tok0.r9bs`). The reference harness reproduces
the already-matching Z probe (2395) before it is trusted for anything else.

1. **A read port on any A-drained region, without hardware changes.**
   `--probe-dup-src REGION` (added today) appends a COPY of the last kept A
   job with its source replaced by REGION and probes the copy. The original
   still drains into its region, so the copy reads what the drain wrote:
   `[VEC_NORM X->XN, .., attn_gate XN->Z, attn_gate Z->SMP]`. Controls for the
   drain and for A's region read path, with B not in the program at all.
2. **Choose the probing tensor by reference margin, not convenience.**
   `attn_gate(Z)` has a 0.5% top-2 margin (1117 at 420,239 vs 3128 at
   417,966) and is not a discriminator; `ssm_beta(Z)` (14%) and
   `ssm_alpha(Z)` (28%) are.
3. **Read the QKV region the same way**, first 4,096 entries = q|k mantissas
   (K = 4,096 tensors cannot reach v at offset 4,096; there is no source
   offset field).
4. **Hypothesis tests on the card's 2768** against the one weight matrix that
   produced it: constant inputs, and every one-hot column (7m58s of
   `mv4i_matvec`). 17 columns single-handedly select 2768; not decisive, and
   abandoned in favour of reading the generic list.
5. **Read `gen_fk33_card.py`'s generic list against `llama_top`'s header**,
   which is what should have been done first, and what
   `docs/debugging/2026-09-11_the-card-builds-subsystem-c-as-a-stub.md`
   already did once for C in the same file.

## The evidence

Probes on the card (bitstream above, `bash $SD/probe.sh N`, GDN state region
zeroed before the step-8 run):

| program | probed job (rows) | source | card ARGMAX | reference | margin | verdict |
|---|---|---|---|---|---|---|
| upto 5 + dup | attn_gate (4096) | Z (A-drained) | 3128 | 1117 (3128 is 2nd) | 0.5% | near-tie, uninformative |
| upto 6 + dup | ssm_beta (32) | Z | 5 | 5 | 14% | MATCH |
| upto 7 + dup | ssm_alpha (32) | Z | 25 | 25 | 28% | MATCH |
| upto 6 + dup | ssm_beta (32) | QKV[0:4096] = q,k | 31 | 31 | 34% | MATCH |
| upto 7 + dup | ssm_alpha (32) | QKV[0:4096] | 26 | 26 | 35% | MATCH |
| upto 9 | ssm_out (4096) | Y (B-written) | 2768 | 3994 | 50x | MISMATCH |

Reference for the step-8 job, `ssm_out.weight` on `R_Y-0`:

```
top0 row 3994 y 835056
top1 row 2653 y 16712
row 2768 y -1036
```

Row 3994 is the argmax for R_Y-0, for R_QKV.v-0 and R_Z-0 used as inputs,
and for an all-positive constant vector; the card's Y is nothing like any
vector the model produces here.

The generic list, `grep '"--generic"' hw/fk33/gen_fk33_card.py`:

```
A_DESC=true  B_STATE_AXI=true  C_KV_AXI=true  HOST_WINDOW=false  C_REAL=true
NORM_REAL=true  SMP_EN=true  C_N_ROT=64  C_KV_BLOCK=32  C_KV_ADDR_W=33
C_K_BASE_CH=282672640  C_V_BASE_CH=353975808  C_MAXPOS=131072
C_CTXLEN=131072  WDOG_LIMIT=4000000  A_ROWS_IF=48  A_JOB_STRIDE=16#40000#
```

No `B_SRC_REAL`, no `NORM_W_IMAGE`. `rtl/fk33_llama_top.vhd:303`:
`B_SRC_REAL : boolean := false;`.

The stand-ins, `grep -n "m12(" rtl/fk33_llama_top.vhd` (non-comment):

```
5133  conv weights      m12(cvq_seg*65537 + cvq_grp*13, t*101 + ln + 5)   always
5174  conv taps         m12(cvq_seg*104729 + cvq_grp*31, t*17 + ln)       not B_SRC_REAL
5204  ssm_dt_bias       m12(ix*31 + 2, 3)                                  always
5208  ssm_a             -abs(m12(ix*31 + 3, 4))                            always
5220  alpha             m12(ix*31 + 1, 2)                                  not B_SRC_REAL
5221  beta              m12(ix*31 + 4, 5)                                  not B_SRC_REAL
5231  ssm_norm weight   m12(4242, j)                                       always
2116  D-vec norm gain   2**NORM_W_EXP + ((i*37) mod 512) - 256             NORM_W_IMAGE = ""
```

Sizes of the real constants (GGUF `Qwen3.5-9B-BF16.gguf`, MEASURED):

| tensor | shape | max abs | per layer | all GDN layers (24) |
|---|---|---|---|---|
| `ssm_conv1d.weight` | [4, 8192] F32 | 1.234 | 64 KiB as int16 | 1.5 MiB |
| `ssm_dt.bias` | [32] | 18.5 | 64 B | 1.5 KiB |
| `ssm_a` | [32] | 77.0 | 64 B | 1.5 KiB |
| `ssm_norm.weight` | [128] | 1.318 | 256 B | 6 KiB |
| `attn_norm` / `post_attention_norm` | [4096] | 2.41 / 1.74 | 8 KiB each | 65 norms, 520 KiB |
| `attn_q_norm` / `attn_k_norm` | [256] | 2.34 / 2.92 | 512 B each | 8 attention layers |

BRAM on the running bitstream: **449.5 of 672 tiles** (`fk33_pcieep_util.rpt`),
222 free. The norm-gain image was measured at 114 tiles (TRACK NWROM) and
fits; a 1.5 MiB conv-weight ROM (~341 tiles) does not, so the conv weights
go through HBM, loaded per layer by the state mover, or not at all.

## Measured and REJECTED, do not retry

- **The `ga_desc` region drain (`ybw`, `S_DRAIN`) as the cause of step 8.**
  Four probes reading A-drained regions through A match the reference with
  14-35% margins. The drain and A's region read path are correct for Z and
  for the q,k segments of QKV; v (offset 4,096) is not reachable by this
  method and is untested.
- **The unassigned grant-master address map (`[BD 41-1356]` x128) as a
  cause.** The connection is a clock converter straight into HBM SAXI_30/31;
  no decoder is generated from that map. Fixed anyway in the maxpos build
  because it was an unread CRITICAL WARNING, not because it changes data.
- **Zeroing the HBM state region to emulate token 0.** It does what it says
  (`gdn_job_seq` loads from HBM on every job, `rtl/gdn_job_seq.vhd:205`), it
  just cannot make a stand-in input real.
- **`attn_gate` as a probe of Z.** 0.5% margin; the card picking the
  reference's second row is consistent with the card's Z differing from the
  stream's Z by rounding, and says nothing either way.
- **Inferring Y from the one-hot column analysis.** 17 candidate columns, no
  way to combine them without more probes; the generic list answered the
  question in one grep.

## Measurement traps hit

- **Six matching probes proved less than they seemed.** Steps 1-6 all read
  XN from VEC_NORM, whose gain is the synthetic ramp, and they matched the
  reference anyway: the ramp is 1.0 +/- 6% and the real `attn_norm` gain is
  1.033 +/- 0.037, both near enough to unity that a 2,048- or 4,096-row
  argmax cannot see the difference. A matching argmax is a weak equality
  test, and it is weakest exactly on a per-element gain near 1.
- **The stream's `R_X-0` is not the input to block 0's norm.** A Python
  `x / rms(x) * gain` from it correlates 0.07 with `R_XN-0`. Do not build
  norm references from that record; use `run9b` for the whole chain.
- **The generic list was read for C on 2026-09-11 and not for B.** Same
  file, same class of omission, seven days apart. The check is one grep
  against the top's header table of "WHAT IS STILL A STAND-IN" and it does
  not need a bitstream.

## What is still open

- Whether the card's B, GIVEN real inputs and real weights, matches the
  oracle at 9B on silicon: unmeasured, because the inputs were never real.
- The v segment of the QKV drain (offset 4,096) is unprobed.
- Whether B's Y is ALSO wrong for a reason the stand-ins hide: cannot be
  known until the stand-ins are gone.

## What a correct token needs, DERIVED

1. `B_SRC_REAL=true` in `gen_fk33_card.py`. Verified in simulation with the
   tier by `tools/ref9b/gdn_oracle.py --b-src-real` (2026-09-05). Zero
   structural cost; the tap history is already in the state store.
2. `NORM_W_IMAGE` = the 9B gain image (`tools/gen_llama_top_weights.py
   --norm-out`, 65 x 4096 lines). Verified path; ~114 BRAM of the 222 free.
3. A path for B's conv weights: 64 KiB per layer through HBM, a fourth phase
   of `gdn_state_store`'s mover into a tap-shaped BRAM (16 tiles), loaded
   with the state and never saved; plus `ssm_dt_bias`, `ssm_a` and
   `ssm_norm` (small enough for an image, 24 x 192 int16). None of this
   exists, and the oracle models the `m12` weights, so it changes too.
4. C's QK-norm gains: 8 layers x 2 x 256, an image.
