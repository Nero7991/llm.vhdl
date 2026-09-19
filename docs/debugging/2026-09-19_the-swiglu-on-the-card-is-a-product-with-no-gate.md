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

## 2026-09-19 (later): the fix landed -- `swiglu_mem` behind `gsr`, `SWG_REAL`

Worktree branch `worktree-agent-a42b1fd60db64f01f` off `fpga` at `09f68a0`;
not merged.  Everything below is MEASURED unless marked.

### What was built

- `rtl/swiglu_mem.vhd`.  `rtl/swiglu.vhd`'s arithmetic, per element and
  bit-identical (the same `S_CALC_A` 64-bit conversion with its round-half-up
  bias, `sigmoid_q` from `fixed_pkg`, the two floor shifts, the `resize` to
  32 that can wrap), behind word-stream ports into three 16-bit `vec_mem`
  banks (g, u, o), PIPELINED one element per cycle (four stages, one
  multiply each, the split swiglu.vhd's own S_CALC comment demands for
  timing), with `rtl/bfp_pack.vhd`'s pack folded in.  Two passes: pass 1
  folds `max|out|` (as an UNSIGNED vector, bfp_pack's silicon rule), pass 2
  RECOMPUTES the identical `out` and packs it.  The 32-bit intermediate is
  never stored: that is the 12 RAMB36 `engine_shared` spends at N=12288,
  traded for +N cycles per op (12.3 k cycles x 32 FFNs = 0.6% of the
  61 M-cycle token).  Single-port banks, no `LANES` generic: the datapath is
  one element per cycle by construction and LANES would multiply the DSPs.
  Rate 2N+12 cycles per op (MEASURED 268 at N=128, 24,588 at N=12288)
  against swiglu.vhd + bfp_pack's 6N+ (771 / 73,731).
- The rounding rule, stated once: ROUND HALF UP on the input conversion
  (exp > Q) and on the pack; FLOOR on the two product shifts;
  `o_exp = Q - shift`, `shift = max(0, msb(max|out|) - 14)`.  Under
  `value = mant * 2^-exp`, a right shift of the mantissa by `s` subtracts
  `s` from the exponent, which is the rule the stub's S_DONE derives.
- `rtl/llama_top.vhd`: generic `SWG_REAL : boolean := false`; `gsr : if
  SWG_REAL and vi = V_SWG generate` beside `gvr`, the same
  S_IDLE/S_RD/S_GO/S_RUN/S_WR/S_DONE shape (both exponents latched at
  accept, two-edge region reads consumed at k-2, one-edge output bank read
  through the two-deep `rav`/`rav_d` pipeline, `done` held until `v_ack`);
  `gv` excludes `V_SWG` when `SWG_REAL`; n asserted against `SHAPE.ffn`;
  `MANT_W = 16` pinned two-sided with out-of-range naturals.  Elaborated
  ONCE at N = SHAPE.ffn (12288 on the card, 128 at the sim shape).
- THE BANNER WAS WRONG ABOUT C, AND IS NOW SAID TO BE UNMAINTAINED.  Lines
  75-90 read "unit C always: ATTENTION IS A STUB" while `C_REAL` had composed
  the real `attn_block` since 2026-09-11 and the card built with it (the
  block-3 probe above measured C right).  Fixed to "unit C when not C_REAL",
  the norm line updated to `rmsnorm_bf_mem`, the swiglu line to "when not
  SWG_REAL", and a note added that the list is a banner and nothing
  maintains it.  The time-zero report now prints SWG_REAL beside NORM_REAL.
- Generated: `rtl/fk33_llama_top.vhd` + `sim/tb_fk33_cardtop_ident.vhd`
  (`gen_cardtop.py --bench`; `--check` OK; 327 diff lines in source and in
  output alike), `hw/fk33/rtl/fk33_card.vhd` (`SWG_REAL => true` beside
  `NORM_REAL => true`), `hw/fk33/build_fk33_pcieep.tcl` (`swiglu_mem.vhd`
  in CARD_SRCS, `FK33_CARD 51 sources`; `--selftest` PASS).  Both card
  generators embed the checkout's absolute path in their input and output;
  from a worktree they were run against a prefix-rewritten copy of the input
  and the prefix mapped back, and the resulting diffs are exactly the
  `swiglu_mem` / `SWG_REAL` lines (verified by `git diff`; zero `worktrees`
  strings in any generated file).  Hand-maintained lists updated next to
  `rmsnorm_bf_mem.vhd`: `capture_llama_top.sh`, `ooc_card_dcp.tcl`,
  `ooc_c_in_card.tcl`, `mutate_fk33_seam.sh`, `mutate_llama_top_smp.sh`,
  `mutate_llama_top_kv.sh`, `mutate_normw.sh`, `capture_normw.sh`.
- Model: `tools/ref9b/vec_oracle.swg_real` (transcribed from
  `ref/run_fx.c:swiglu_fx` and `ref/fx.h:fx_sigmoid_q`, the Q-conversion
  from the RTL, the pack from `bfp_pack`), selected by `--swg real` in
  `bisect_scaled.py` and `ref_stream_scaled.py` (default `standin`, so old
  captures compare as before; `gdn_oracle.py` accepts-and-ignores it).
  `tools/ref9b/check_swg_real.py` holds it to the C and to the 9B capture.
- Gate rows: `sim:tb_swiglu_mem` (N=128), `sim:tb_swiglu_mem_9b` (N=12288),
  `sim:tb_llama_top_swg` (real + NTOK=3 + SWG_REAL, landmarks EXP_X0 10238,
  EXP_XSUM 87031, EXP_XALL 65159, EXP_STEPH 35900), `sim:seamgate_swg`.

### The evidence

Identity, `sim/tb_swiglu_mem.vhd` (reference = the shipping chain `swiglu ->
vec_mem(32) -> bfp_pack` exactly as `engine_shared` wires it; no code shared
with the DUT):

```
N=128:   tb_swiglu_mem: checks=3226 bad=0 live=18 rail=7 rdlat=1 N=128
N=12288: tb_swiglu_mem: checks=184336 bad=0 live=14 rail=1 rdlat=1 N=12288   (98 s wall)
  live blk3 g_exp 14 u_exp 13 o_exp 12 shift 0 nonzero 11993/12288 ref_cyc 73731 dut_cyc 24588 badel 0
  live wrap g_exp 0 u_exp 0 o_exp -4 shift 16 nonzero 6164/12288 ref_cyc 73731 dut_cyc 24588 badel 0
```

Teeth, `sim/mutate_swiglu_mem.sh` (columns: all checks / no values / no
values no exponent / no checks at all):

```
MUTANT     FULL    noVAL   noVL+EX noALL   VERDICT
nosig      rc=1    rc=1    rc=1    rc=0    BITE      sigmoid dropped (out = g*u, the stand-in at Q12)
packrnd    rc=1    rc=0    rc=0    rc=0    BITE      pack truncates instead of rounding   (VALUE check only)
raskew     rc=1    rc=1    rc=1    rc=0    BITE      input-bank read address +1 (read-latency off by one)
convrnd    rc=1    rc=1    rc=1    rc=0    BITE      Qq conversion truncates for exp > Q
opswap     rc=1    rc=1    rc=1    rc=0    BITE      silu(u)*g
expswap    rc=1    rc=1    rc=1    rc=0    BITE      exponents exchanged
oexpsign   rc=1    rc=1    rc=0    rc=0    BITE      o_exp = Q + shift                    (EXPONENT check only)
silush     rc=1    rc=1    rc=1    rc=0    BITE      silu shifted by Q-1
nodrain    rc=0    rc=0    rc=0    rc=0    SURVIVES  last element excluded from max|out|
nosat      rc=0    rc=0    rc=0    rc=0    SURVIVES  pack saturation dropped
doneearly  rc=0    rc=0    rc=0    rc=0    SURVIVES  done one cycle before the last write lands
wrot       rc=1    rc=1    rc=1    rc=0    BITE      output words written one address late
```

Every kill vanishes with all checks off, so every kill belongs to a check
this bench credits.  The `noVL+EX` column still carries the latency probe,
which compares `o_rdata` to ONE reference element and is therefore a value
check in disguise; that is why most rows stay red there and why the fourth
column exists.

The three NON-BITING mutants, by name, and why:

- `nodrain`: the shift is computed on the edge the last element's fold
  lands, so element N-1 is excluded from the max.  It bites only when the
  max IS element N-1; no trial puts it there (`one_big` is at N/2+1).  A
  trial with the max in the last element would close this; not added,
  because the surviving mutant is the honest measurement of the floor.
- `nosat`: only a mantissa that rounds up to exactly 32768 (the max element
  with its dropped bits at or above the half) can show it.  Random draws do
  not hit it.
- `doneearly`: the bench (and the `gsr` adapter) read the output long after
  `done`, so a `done` one cycle before the last write lands is invisible to
  both.  The reference is 3x slower, so the bench cannot see it even in
  principle.  The unit's own comment states the contract; nothing checks it.

Model against the C (`tools/ref9b/check_swg_real.py`, n=4096 per case):

```
TABLE  sig_lut.mem vs fx_init() formula: 0 of 513 differ
C      eg= 14 eu= 13  differ=2241  half-ties (exp>Q, negative, RTL rounds up) 2241, resize32 wraps 0, UNEXPLAINED 0
C      eg= 12 eu= 12  differ=0
C      eg=  9 eu= 10  differ=0
C      eg=  8 eu=  8  differ=0
C      eg=  0 eu=  0  differ=2046  half-ties 0, resize32 wraps 2046, UNEXPLAINED 0
C      eg= 13 eu= 15  differ=2130  half-ties 2130, wraps 0, UNEXPLAINED 0
C      eg= 16 eu= 14  differ=1714  half-ties 1714, wraps 0, UNEXPLAINED 0
```

The half-ties are PLANTED (every 5th/7th element is a negative mantissa on
an exact half of the conversion): `lroundf` rounds half away from zero, the
RTL's `shift_right(m + 2^(k-1), k)` rounds half toward +infinity.  The RTL
is the spec and the model follows it; the C harness records the one
documented place `run_fx.c` is not the RTL.  The wraps are the C's int64
`out_q` against the RTL's `resize(.., 32)`, modelled.

Model against the 9B reference, block 3 of `tok0.r9bs` (R_G-3 exp 14,
R_U-3 exp 13, R_H-3 exp 13, N=12288):

```
swg_real -> o_exp 12 (ref 13), shift 0, max_abs 8247, sat 0
swg_real vs double R_H-3:  corr 0.999996  max|err|/max|H| 2.425e-04  rms(err)/rms(H) 4.768e-03
Q12-grid-only (double silu, same conversion/grid/pack):
                           corr 0.999996  max|err|/max|H| 1.819e-04  rms(err)/rms(H) 4.741e-03
```

So the Q12 GRID is the limiting term, not the sigmoid table: replacing the
table with double silu moves the rms relative error from 4.77e-3 to
4.74e-3.  The grid enters twice -- G at exp 14 loses 2 bits and U at exp 13
loses 1 bit in the conversion to Q12, and the output is on the 2^-12 grid
(`o_exp` is CAPPED at Q = 12: max|out_q| 8247 uses 14 of 15 mantissa bits,
against the reference's own int16 at 2^-13).  H's rms is 0.031, i.e. ~128
Q12 LSB, so a 2^-12 grid is 0.4% of an rms element.  This is a property of
`swiglu.vhd`'s recipe, which is what `ref/run_fx.c` computes; a wider Q
would be a different recipe and a different model, not a fix to this one.

Seam gate, `sim:seamgate_swg` (real + NTOK=3 + SWG_REAL=true, judged with
`--swg real`):

```
  token 0: 64 seams bit-exact against a model, 0 not checked
  token 1: 64 seams bit-exact against a model, 0 not checked
  token 2: 64 seams bit-exact against a model, 0 not checked
SEAMGATE PASS -- swg: 3 token(s), at least 64 seams per token
```

Attribution controls (both MUST fail, both do):

```
stand-in model vs the SWG_REAL capture:
  tok 0  FIRST DIVERGENCE: R_H-0 at element 0 -- expected 61, captured 760 (exponent 8 vs 12, 127 of 128 mantissas differ)
  tok 1  FIRST DIVERGENCE: R_H-0 at element 0 -- expected -79, captured -474 (exponent 8 vs 12, 127 of 128 mantissas differ)
  tok 2  FIRST DIVERGENCE: R_H-0 at element 0 -- expected -53, captured -484 (exponent 8 vs 12, 128 of 128 mantissas differ)
real model vs the seamgate_real capture (SWG_REAL false):
  tok 0  FIRST DIVERGENCE: R_H-0 at element 0 -- expected 760, captured 61 (exponent 12 vs 8, 127 of 128 mantissas differ)
```

### The OOC draw at N = 12288 (BC-250, Vivado 2023.2, `sim/ooc_swgmem_run.sh`
-> `sim/ooc_lutdiet_ports.tcl` unmodified, `report_utilization` + census)

```
LUTDIET_RESULT target=swiglu_mem gen="N=12288 Q=12" dsp=16 lut=2493 lut_logic=2493 lut_mem=0 ff=319
               ramb36=18 ramb18=3 bram=19.5 uram=0 carry8=103 f7=278 f8=120 wns=-3.669 (5.0 ns)
second draw, same netlist, period 13.333 ns (the card's 75 MHz engine clock):
               wns=+4.664, 0 failing endpoints; every area column identical
peak RSS 3.15 GB / 3.24 GB (sampled via /proc/PID/exe; both under the 7G cap, so real peaks)
```

Primitive census (`report_utilization` section 8, i.e. REF_NAMEs, not the log):

```
| LUT6 1428 | LUT2 481 | LUT5 345 | FDRE 302 | MUXF7 278 | LUT1 175 | LUT4 174 | LUT3 148 |
| MUXF8 120 | CARRY8 103 | RAMB36E2 18 | FDSE 17 | DSP48E2 16 | RAMB18E2 3 |
```

Hierarchy (`report_utilization -hierarchical`): the three `vec_mem` banks
are 6 RAMB36 + 1 RAMB18 each (12288 x 16 = 196,608 bits = 6.0 RAMB36 plus
the remainder in an 18); everything else is the top: 2,472 LUT, 319 FF, 16
DSP.  The name census puts 891 LUT + 270 MUXF7 + 119 MUXF8 under `ARG` (the
513 x 31-bit sigmoid ROM, in LUTs), 515 + 515 under the two Qq conversions
(`a_vq`/`a_hq`, the 64-bit barrel shifters), 251 under `b_sig`, 168 under
the pack (`o_wd`), 111 under `max_abs`.  The 16 DSP48E2 are the three
multiplies (interpolation, v_q*sig, silu*h2_q), each a 32x32 cascade.

The worst path at 5.0 ns (8.376 ns data path, 35 logic levels, 12 CARRY8
and one DSP cascade) is `a_vq_reg -> sigmoid ROM -> (hi - lo) -> the
interpolation DSP`: entirely inside `sigmoid_q`, i.e. swiglu.vhd's own
S_CALC_B cone, unchanged.  115.4 MHz post-opt OOC (NOT a routed number).  At
the card's 13.33 ns it has 4.66 ns of slack OOC.  If a future card clock
needs it, `sigmoid_q` splits into three registered stages (index+ROM,
multiply, shift+round) without changing a bit -- not done here, because the
requirement was bit-identity via the same function, and the card is at 75.

Does it fit (MEASURED card totals from
`hw/fk33/results/card_seqrst_bfnorm_2026-09-19/bd_wrapper_utilization_placed.rpt`;
the unit's numbers are OOC and DO NOT SUM across contexts, so the sums are
ESTIMATE):

| resource | card now | unit OOC | ESTIMATE after | of |
|---|---|---|---|---|
| CLB LUT | 367,685 (83.63%) | +2,493 | see below | 439,680 |
| CLB FF | 308,140 (35.04%) | +319 | 308,459 (35.1%) | 879,360 |
| BRAM tile | 547.5 (81.47%) | +19.5 | 567.0 (84.4%) | 672 |
| DSP | 2,072 (71.94%) | +16 | 2,088 (72.5%) | 2,880 |

The LUT line is not a simple sum in the flattering direction either: the
arm this replaces is `gen_vstub[2].gv` and on the card it holds
`buf_reg` and `buf2_reg` as `RAM64M8 x 576` each (Vivado's own RAM table,
docs/debugging/2026-09-17_one-flop-array-was-the-whole-lut-gap.md), i.e.
1,152 RAM64M8 of LUT-as-memory that go away with `SWG_REAL=true`, plus the
stub's 16x16 multiply and glue.  DERIVED at 8 LUTs per RAM64M8 that is
~9,216 LUT-as-memory removed against 2,493 LUT-as-logic added, so the
expectation is a net LUT DECREASE of a few thousand; that is an estimate
until the fourth card build measures it.  BRAM is the resource that moves
in the costly direction: 19.5 tiles of the 124.5 free.  It fits.

### Gate rows (`--jobs 1`, one regress per box)

Workstation (GHDL 1.0.0):

```
--only seamgate      OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
                     real 36s, stub 27s, seq 146s, bconst 187s, qkn 115s, swg 119s
--only tb_swiglu     OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
                     sim:tb_swiglu_mem 2s, sim:tb_swiglu_mem_9b 100s, tb:tb_swiglu 0s
--only cardtop       OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
                     sim:tb_fk33_cardtop_adesc 2s, sim:tb_fk33_cardtop_ident 104s, sim:cardtop GEN_CARDTOP_CHECK: OK
--only tb_llama_top  OVERALL     PASS 11  FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
                     tb_llama_top 104s, bconst 192s, bstate 109s, bstate_seq 370s, normw 71s, qkn 116s,
                     real 72s, seq 293s, smp 1s, smp_beh 1s, swg 120s
```

BC-250 (GHDL 6.0.0, `--timeout 2400`, fresh scratch, single instance):

```
--only tb_fk33_seam  OVERALL     PASS 2   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
                     sim:tb_fk33_seam 159s, sim:tb_fk33_seam_wdog 18s
```

(The tb_llama_top family was ALSO run on the BC-250 first and every one of
those rows is discarded; see the two-instance trap below.  The lanes were
then swapped: tb_llama_top here, tb_fk33_seam there.)

No pinned landmark moved in any existing configuration (every existing row
elaborates `SWG_REAL=false`, the default); the ONLY new landmarks are
`tb_llama_top_swg`'s, measured from a run with none pinned.

### Measured and REJECTED -- do not retry

- **Storing the 32-bit intermediate in a vec_mem, as engine_shared does.**
  12 RAMB36 at N=12288 for one pass fewer (0.6% of a token).  BRAM is at
  84% with this unit in; the recompute is exact.  Retry only if the SWG op
  ever becomes schedule-critical, which at 2N cycles beside two 12288x4096
  matvecs it is not.
- **LANES-way banks.**  The datapath is one element per cycle; lanes would
  need one sigmoid + two multiplies per lane, x16 DSP each, in a design
  measured DSP-bound in every congested window.
- **A cleaner conversion for absurd exponents** (exp >= Q+64, where
  swiglu.vhd's 64-bit bias term wraps and it returns -1 for a non-negative
  mantissa).  Rejected in favour of exact identity with the verified unit;
  the clamps at 64/65 reproduce the wrap and the bench's `wild` sweep
  asserts it.

### Measurement traps hit

- **`report ... severity error` exits 0 in GHDL 1.0.**  The first mutation
  run showed every real mutant SURVIVING with `checks=3226 bad=1273` in its
  own log: the bench had found them and the script read the exit code.  The
  house form ends with `assert ... severity failure` for exactly this
  (tb_rmsnorm_bf_mem does); the bench now does too.  A regress row would
  still have gone red via FAIL_RE; an rc-gated caller would not.
- **Two "bites" that were crashes.**  The first `nodrain` (drain test
  removed outright) and `wextra` mutants failed in EVERY attribution
  column, including all-checks-off: a bound-check failure on `widx` and a
  never-firing `done`.  A kill that survives the removal of every check is
  not a detection, it is the simulator.  Both mutants were rewritten so the
  fault is a wrong number, and `nodrain` then SURVIVES, which is the honest
  row.
- **The card generators embed the checkout's absolute path.**  From a
  worktree, `gen_fk33_card.py` writes the worktree's path into
  `NORM_W_IMAGE`/`C_QKN_IMAGE`, and `gen_pcieep.py` refuses outright because
  its input `build_fk33_i2cprobe.tcl` carries the main checkout's paths.
  Both were run against a prefix-rewritten copy of the input and the prefix
  mapped back; `--check`/`--selftest` were run the same way.  From the main
  checkout after merge, both `--check`s should report OK unchanged.
- **TWO REGRESS INSTANCES ON THE BC-250, AND THE FIRST ROUND OF ITS
  RESULTS WAS CONTAMINATED.**  The first launch went through an
  ssh-attached shell under the tool's 10-minute cap, so it was stopped and
  relaunched under `nohup`.  Stopping it killed the `ghdl` (found by
  `/proc/PID/exe`) -- and NOT the `regress.sh` loop above it, which simply
  moved to its next row.  For 45 minutes two instances walked the same row
  list into the SAME scratch, each truncating and writing the same log
  files: `res.*` files were rewritten with different elapsed times
  (bstate 346 s then 350 s; bstate_seq FAIL 1079 s then PASS 1072 s), and
  one 18 MB log carried a run of NUL bytes where the two writers' offsets
  diverged.  That NUL run made GNU grep call the log binary, the
  `GHDL_EXIT` grep in `regress.sh` returned nothing, and a row whose log
  ended `RESULT: PASS` / `GHDL_EXIT=0` was reported `FAIL exit 1:` with an
  empty reason (the `-a` is now on that grep; every other grep in the
  function already had it).  Found by the rewritten `res.*`, not by any
  verdict.  Both instances were killed by LINEAGE from `/proc` (exe = bash,
  cwd = the repo, parent = the ssh session's `fish` for the stray one),
  every BC-250 row from that round was DISCARDED, and the family was re-run
  from fresh scratch directories, one instance per box.  The rule that was
  missing: a killed CHILD is not a killed JOB; find the loop that spawned
  it, and never share a scratch between two launches.
- **A user `systemd-run` unit starts in `$HOME`, not the caller's cwd**:
  the first OOC launch died on `sim/ooc_swgmem_run.sh: No such file`.
  The `cd` goes inside the unit's command.

### Still open

- The fourth card build with `SWG_REAL=true` (hw/fk33/rtl/fk33_card.vhd and
  build_fk33_pcieep.tcl are regenerated and committed; the build itself is
  Oren's call: ~47 GB with swap, `MemoryHigh=24G`, alone on the box).  Its
  placed report is what turns the LUT ESTIMATE above into a number.
- Whether anything else in the composed top is a stand-in: the banner is
  fixed but stated unmaintained; `grep -n "behavioural\|stand-in\|model"
  rtl/llama_top.vhd` is the check, not the banner.
- The three non-biting mutants (`nodrain`, `nosat`, `doneearly`) name three
  properties nothing checks at the unit level: the max folding the LAST
  element, pack saturation, and `done` firing after the last write lands.
  The seam gate covers the first two only by luck of the data.
