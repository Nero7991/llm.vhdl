# The SwiGLU on the card is `g*u`, no gate: the third stand-in, found by bisecting token 0 on the seqrst+bfnorm bitstream

Date: 2026-09-19 16:30. Card: FK33, bitstream
`hw/fk33/bit/fk33_card_seqrst_bfnorm_75mhz_2026-09-19.bit` (sha256
`f6c89e4f…`, WNS +0.054, built from `b601ca8`; seq_rst + `rmsnorm_bf_mem`).
Prompt token 248045; reference token 846 (`tok0.r9bs` TOKEN record,
`ref/run9b.c` double precision).

## The question

With the tok_pos and norm defects fixed, token 0 runs end to end with no
faults (504 steps, logits exp 15, sane magnitude) and the argmax is
**247749** against the reference **846**. Where is the remaining defect?

## The answer

**`rtl/llama_top.vhd:1832`: the D-vec `OP_VEC_SWG` is a behavioural
stand-in, `out(i) = (g(i)*u(i)) / 2**MANT_W`, with no silu gate.** The header
says so ("THE TWO D-VEC ENGINES THAT DO NOT EXIST", "swiglu always ... no
gate") and `tools/ref9b/vec_oracle.swg` models exactly that, so every
sim-shape seam gate passes bit for bit while the value is not SwiGLU. The
norm was the other engine in that pair and got its adapter (`gvr`,
`NORM_REAL`); `rtl/swiglu.vhd` (the real Q12 silu*gate unit, element
sequential, verified by `ref/test_swiglu.c`) has no D-vec adapter and is
not in the composed top. Every FFN in the model therefore computes the wrong
H. The tok_pos and norm defects had masked it in the earlier bisection.

## The procedure

The seqrst bitstream made B-reaching probes free (no reconfiguration per
probe: `--seq-reset` now clears the engine's `tok_pos`, `fk33ctl seam`
prints `engine tok_pos`). `$SD/bisect_layers.sh`: for block L, run the
token program up to and including the FIRST A job of block L (which reads
XN = norm(X after block L-1)) with `FLG_TO_SMP`, and compare its argmax with
`probe_ref` over the reference `R_XN-L` record from `tok0.r9bs` with the
same tensor and row count. Then inside the first failing block, one probe
per A job (`--upto` the A job, `--override STEP:tensor=` to run a second
weight over the same region).

| entering block | tensor / rows | card | ref | |
|---|---|---|---|---|
| 1 | attn_qkv 2048 | 1756 | 1756 | MATCH (B is right after the tok_pos fix) |
| 2 | attn_qkv 2048 | 709 | 709 | MATCH |
| 3 | attn_q 8192 | 1183 | 1183 | MATCH |
| 4 | attn_qkv 2048 | 1790 | 343 | **DIFF** |
| 6 | attn_qkv 2048 | 1385 | 1385 | match (coincidence, see below) |
| 8 | attn_qkv 2048 | 1989 | 1020 | DIFF |
| 12, 16, 24 | attn_qkv 2048 | = | = | match (coincidence) |
| 31 | attn_q 8192 | 546 | 3610 | DIFF |

Inside block 3 (the first attention block):

| probe | card | ref | |
|---|---|---|---|
| attn_v(XN-3), 1024 rows | 992 | 992 | MATCH |
| attn_output(Y-3), 4096 rows | 3456 | 3456 | MATCH: C is right |
| ffn_gate(XN.ffn-3), 12288 rows | 468 | 468 | MATCH |
| ffn_up(XN.ffn-3), 12288 rows | 9176 | 9176 | MATCH |
| ffn_down(H-3), 4096 rows | 577 | 3456 | **DIFF** |
| blk.0.ffn_down over the same H-3 | 3994 | 2500 | DIFF: H is wrong, not the weight |

Block 0's `ffn_down(H-0)` argmax matches (3994 = 3994) with the card's H at
exponent 10 against the reference 14 (decoded from `logit_exp = w_exp +
x_exp - out_shift`, 12 = 7 + x - 5); block 3's H is at 9 against 13. A
4-octave scale offset and different mantissas in every block, with the
argmax of the next matvec surviving in some blocks and not others.

`grep -n swiglu rtl/llama_top.vhd` then gave the answer in one line.

## The evidence

```
last job   seq_pos 1  cycles 61119438  argmax 247749  logit_exp 15   (whole token, ref 846)
L=4  step=62  blk.4.attn_qkv.weight rows=2048 card=1790 ref=343  DIFF
--- blk.3.ffn_down.weight (upto 60)   card argmax 577  logit_exp 11 ; ref argmax=3456
--- blk.0.ffn_down over the card's H-3 card argmax 3994 ; ref argmax=2500
--- blk.0.ffn_down(H-0) (upto 15)     card argmax 3994 logit_exp 12 ; ref argmax=3994
rtl/llama_top.vhd:1832:  -- swiglu: out(i) = (a(i) * b(i)) / 2**MANT_W       no gate, not swiglu
```

## Measured and REJECTED -- do not retry

- **A weight-image fault for `blk.3.ffn_down`**: a second weight over the
  same H disagrees with the reference the same way, and the image verified
  251/251 after the reload.
- **The K=12288 A job**: `ffn_gate`/`ffn_up` (M=12288) match and the same
  K=12288 job in block 0 matches to the argmax; the operand is wrong, not
  the job.

## Measurement traps hit

- **An argmax MATCH downstream of a wrong vector is weak evidence.** XN
  entering blocks 6, 12, 16 and 24 matched the reference argmax with H wrong
  in every block before them; only the DIFF rows carry information. Bisect
  on DIFFs, and confirm a suspected-clean region with a second weight.
- **The stale-seam trap, again**: `--upto 16` made the last kept step a
  VEC_RES, `--probe-smp` refused (no files), the script ran the previous
  program and the seam line read like a result (same `cycles` as the run
  before). Check `PROBE ...` and the arena verify count before reading the
  argmax.
- **The per-unit "verified" label**: `rtl/swiglu.vhd` is verified against
  `ref/test_swiglu.c` and the composed top never instantiates it. The same
  shape as `rmsnorm_bf` this morning. The list of stand-ins is the top's
  banner (`rtl/llama_top.vhd:75-90`), and it still says "unit C always:
  ATTENTION IS A STUB", which the block-3 probe shows is no longer true; the
  banner is not maintained and cannot be trusted either way.

## The fix (dispatched 16:40)

A D-vec adapter for `rtl/swiglu.vhd` on the pattern of `gvr` /
`rmsnorm_bf_mem`: G and U streamed from the region file into banked RAM,
the sequential Q12 silu*gate datapath, then the BFP pack (max-abs,
normalise to 16-bit mantissas, publish the exponent) into H. RTL-fidelity
Python model beside `vec_oracle.swg`, gate rows at the sim shape, then a
fourth card build.

## Still open

- Whether anything else is a stand-in: after this, re-read the banner and
  grep the top for "behavioural"/"stand-in"/"model" and list them; do not
  wait for the bisection to find the next one.
