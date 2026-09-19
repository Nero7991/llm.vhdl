# The card's first norm clamps on the embedding, and XN comes out 0.75x

Date: 2026-09-19, same session as
`2026-09-19_b-ran-every-probe-token-as-not-the-first.md`, found the moment
that defect was out of the way. Card: FK33, bitstream
`fk33_card_bconst_qkn_75mhz_2026-09-19.bit` reconfigured at ~07:5x so that
one token could run at `tok_pos = 0`. Model: Qwen3.5-9B INT4, prompt token
248045.

## The question

With B running as a real first token, `attn_gate(Y)` on the card gives the
reference argmax 2131, but the card's post-token GDN state S agrees with the
model's only in shape: per-column mantissa correlation 0.999, per-column
VALUE ratio scattered 0.61..3.4, and 900 columns that are exactly zero in
the model are full-scale on the card. The card's conv tap column (B's own
input, A's qkv output) is 0.7727x / 0.7834x / 0.7767x the reference for q /
k / v, each at correlation 0.999. Why is every A output at the top of the
layer 22% low by the same factor?

## The answer

**`rmsnorm_rs_mem`, the norm `llama_top` instantiates, clamps its mean
square at `2^-Q = 2^-12` (rms 2^-6), and the embedding row's rms is
2^-6.35.** The clamp makes the norm divide by 2^-6 instead of the real rms,
so `XN` is 0.784x (bit-exact model: 0.7496x on the card's INT4 row) of the
correct value, and everything computed from XN in that layer -- q, k, v, z,
alpha, beta -- inherits the factor. The mechanism, the window
(`rms in [2^-6, 2^12]`) and the fix (`rtl/rmsnorm_bf.vhd`, block-floating
mean plus a real epsilon, 0.013% worst error over the model's range) were
all established on 2026-08-26 in
`docs/debugging/2026-08-26_rmsnorm-magnitude-window.md`. **The fix never
reached the composed top:** `rmsnorm_bf` has no memory-backed `_mem`
variant, and `rtl/llama_top.vhd:2571` still instantiates `rmsnorm_rs_mem`.
The reference stream (`ref/run9b.c`, double precision, eps 1e-6) does not
clamp, which is why the card and the reference disagree.

The argmax survives because it is scale-invariant; B's Y does not, because
silu(z), beta and alpha are not.

## The procedure

1. **Reconfigure, load weights, run ONE token program through B**
   (`--upto 9`, `attn_gate` overriding `ssm_out` at step 8) as the first
   token. Argmax 2131 = reference. Confirms the tok_pos root cause and
   gives a state image at tk0 = 1.
2. **Read layer-0 S back from HBM** and compare against the model's dumped
   state (scratch copy of `ref/gdn_block_cap_vec.c` with `GDN_STATE_DUMP`).
   Mantissa shape agrees per column (0.999), values do not.
3. **Compare B's INPUT, the tap column, against the reference qkv records**
   and against `bfp_job` run on the reference XN: the reference record IS
   the INT4 matvec of the reference XN (y_exp 11, absmax 28494 exactly), and
   the card is 0.7727x of it. So the difference is upstream of A's
   arithmetic: in XN.
4. **The scale test.** `run_prompt --x-exp-bias +2` and `-2` on the B-only
   program (no first token needed), reading the tap column each time:

   | X scale | card q absmax | ratio to reference |
   |---|---|---|
   | x4 (bias +2) | 22018 | 0.7727 |
   | x1 | 22018 | 0.7727 |
   | x1/4 (bias -2) | 27851 | 0.9774 |

   A scale-invariant norm moves nothing; an epsilon effect would move the
   OTHER way (smaller x, smaller XN). Identical output at x1 and x4 and a
   jump at x1/4 is a clamp.
5. **Locate the clamp** in `rtl/rmsnorm_rs_mem.vhd:510-533`: the mean square
   is shifted right by `2*x_exp` = 38, `1.67e11 / 2^38 = 0.61`, and
   `if shifted_r < 1 then msq_r <= 1`. `llama_top.vhd:317` already names
   the window.
6. **Run the bit-exact model** `tools/ref9b/vec_oracle.py:norm_rs` on the
   reference embedding record with the real block-0 gain: 0.7873x of the
   reference `R_XN-0` at corr 1.0000. On the card's INT4 row: 0.7496x, corr
   0.9967. The card behaves as the clamped unit; the reference does not.

## The evidence

```
R_X.embed   exp 19  absmax 23040  rms 6428.5      (reference, BF16 row)
xcard       exp 19  absmax 21936  rms 6378.0      (card, INT4 row)
R_XN-0      exp 13  absmax 29278                  (reference, run9b double)
norm_rs(ref emb, real gain): exp 13 absmax 23051  ratio 0.7873  corr 1.00000
norm_rs(card X):             exp 13 absmax 21947  ratio 0.7496  corr 0.99674
bfp_job(ref XN) q: y_exp 11 absmax 28494  == R_QKV.q-0
card q tap: absmax 22018 corr 0.99930 ratio 0.7727
```

Arithmetic of the clamp (DERIVED): `S = 4096 * 6378^2 = 1.666e11`;
`msq = S * 2^12 / 4096 = 1.666e11`; `>> 38 = 0.606`; floor at 1 means the
divisor is `sqrt(2^-12) = 2^-6 = 0.015625` against the true rms 0.01226;
`0.01226 / 0.015625 = 0.784`.

## Measured and REJECTED -- do not retry

- **A host-side exponent bias on the embedding** (`--x-exp-bias -2`) moves
  the norm into its window but is NOT a fix: `VEC_RES` adds X to ER with
  exponent alignment, and ER (from Y, downstream of a scale-free norm) does
  not carry the bias, so the residual would weight X by 4x. The bias
  experiments earlier in the night changed downstream argmaxes for exactly
  this reason.
- **Raising `NORM_Q`.** Rejected on 2026-08-26 with numbers: 2% error at
  Q = 24 because the rescale to the fixed grid happens before the epsilon
  add. `llama_top.vhd:332` says it too.
- **Attributing the 0.77 to INT4-vs-BF16 embedding rows.** That difference
  is corr 0.9967 in shape and cannot produce a uniform scale factor through
  a scale-invariant norm.

## Measurement traps hit

- **The tk0 defect masked this one completely.** Y at tk0 = 0 was so wrong
  (state drowned to exponent 2) that a 22% input scale was invisible under
  it. It became measurable only after a reconfiguration gave one true first
  token. Two defects in series, and the bisection saw one.
- **An argmax that matches is not a value that matches.** 2131 came back
  from a Y computed from a 0.75x XN. The S-image value comparison, not the
  argmax, exposed the second defect.
- **The 2026-08-26 resolution was recorded as RESOLVED and was not
  composed in.** `rmsnorm_bf` exists, is gated, is mutation-tested, and is
  instantiated nowhere in `llama_top`. A "RESOLVED" heading in a debugging
  document is a statement about the unit, not about the top.

## What is still open

- `rmsnorm_bf` needs a memory-backed variant (`rmsnorm_bf_mem`, the same
  port transformation `rmsnorm_rs -> rmsnorm_rs_mem` made) and `llama_top`
  must instantiate it; then the 9B reference's XN should agree with the
  card's to the unit's 0.013%.
- The 27B measurement in the 08-26 doc (77% of `build_norm_gated` inputs
  below eps) concerns B's per-head gated norm, a different unit; whether
  that unit has the same clamp in the composed top has not been checked
  here.
- The first-token-after-reload argmax 0 / logit exp -25 (whole token) is
  still unexplained; it may be this defect compounding over 32 blocks or a
  third one.

## UPDATE 2026-09-19 (later): the `_mem` variant exists and the top binds it

The first open item above is closed at commit `3527c44` (worktree branch,
not yet merged): `rtl/rmsnorm_bf_mem.vhd` is `rmsnorm_bf` under exactly the
port transformation `rmsnorm_rs -> rmsnorm_rs_mem`, `rtl/llama_top.vhd`'s
`u_rms` binds it, and `sim/tb_rmsnorm_bf_mem.vhd` is a gate row asserting
it bit-exact with `rmsnorm_bf` in every element, `o_exp` and the `done`
cycle, including an x_exp 19 / rms 2^-6.35 trial (MEASURED: checks=1822
bad=0, 13 of 14 trials non-degenerate).  `tools/ref9b/vec_oracle.norm_bf`
is the bit-exact Python of the same recipe (220 of 220 cases against the C).

Two things learned while doing it, recorded because they are the kind that
get re-derived:

- **`done` fires ONE cycle later than `rmsnorm_rs_mem`'s** at equal N/LANES
  (MEASURED 149 vs 148 at N=128 LANES=4).  `rmsnorm_bf` carries a DSP MREG
  stage (`p2_m`) in the element passes that `rmsnorm_rs` never had.  Any
  cycle-pinned landmark downstream moves by +1 per norm op.
- **The embedding is NOT in the eps-dominated branch.**  At rms 2^-6.35 the
  mean square is 1.5e-4 against eps 1e-6, so the unit takes the
  "eps is smaller" alignment branch and the epsilon is a 0.33% gain term
  there.  A mutant dropping the eps add on the OTHER branch passed the
  embedding trial bit-for-bit and was caught only by the deep-eps trial (by
  the unit's own S_SEED2 assert).  The gain the embedding needs from this
  unit is the un-clamped `1/rms` far more than the epsilon; the fixed-grid
  unit's defect on it is the 2^-12 floor, not the missing 1e-6.
  DERIVED on an N=4096 embedding-shaped vector: rs gain 64.0000, bf gain
  80.4480, ideal 80.4481, ratio 0.7955.

### What `rmsnorm_bf_mem` costs at the shipping shape (MEASURED 2026-09-19)

BC-250, Vivado 2023.2, `sim/ooc_bfmem_run.sh` driving `sim/ooc_lutdiet_ports.tcl`
unmodified (the flow that drew rs_mem's 4,825 on 2026-08-30), N=4096 LANES=4,
`-flatten_hierarchy none`, 5.0 ns, numbers from `report_utilization` plus
the `get_cells` census, both units in one session:

```
bf_mem: rmsnorm_bf_mem,"N=4096 LANES=4",dsp=40,lut=4995,ff=2411,ramb18=12,bram=6,carry8=258,f7=0,f8=0,wns=0.971
rs_mem: rmsnorm_rs_mem,"N=4096 LANES=4",dsp=40,lut=4825,ff=1629,ramb18=12,bram=6,carry8=252,f7=0,f8=0,wns=0.971
```

The control reproduced the 08-30 draw exactly (4,825 / 1,629 / 6 / 40 /
+0.971), so the +170 LUT / +782 FF is attributable to the arithmetic.  The
FF delta is the DSP MREG/PREG pairs rmsnorm_bf carries (four Newton pairs
plus `p2_m`), which are fabric flops only if the absorption fails.  Peak
RSS 3.54 GB.

Measurement trap hit: `ooc_lutdiet_ports.tcl` globs every `.vhd` in the
directory it is given, and `rtl/ooc_gdnadapt_top.vhd` (a stale area-draw
extraction naming an undeclared `b_const_hbm`) made Vivado abort the whole
`synth_design` AFTER the unit itself had synthesised cleanly.  The runner
now hands the flow a directory of symlinks to the six-file closure.

### The gate on the BC-250 cannot judge llama_top-level rows

Its GHDL 6.0.0 rejects `rtl/axi_rd_port.vhd:260` ("range of formal
`level` is different from formal range") at elaboration, so every
`tb_llama_top*`, `seamgate_*` and `tb_fk33_cardtop_ident` row failed there
in 1 to 20 s with no capture.  The workstation's GHDL 1.0.0 accepts the
same file (`tb_fk33_cardtop_ident` PASS, 108 s, same tree).  That file was
not touched by this change; it is a GHDL-version incompatibility and is
recorded here so nobody reads those rows as a norm regression.
`tb_fk33_seam` and `tb_fk33_seam_wdog` do not reach that unit and PASSED
there with their pinned landmarks (`EXP_X0 -17280`, `EXP_XSUM 53529`)
unchanged.
