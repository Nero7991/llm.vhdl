# The layer-level descriptor program (worklog backlog item 6)

**Date:** 2026-08-29
**Repo state:** branch `fpga`, HEAD `8ba48e4`, with several other tracks'
uncommitted edits present in `sim/`. Nothing in `sim/` or `rtl/` was touched
here; the only repository change is the new `tools/gen_layer_program.py` and
this file, so no gate row was added and `BASELINE_PASS` is untouched.
**Hardware:** none. Nothing in this file touched an FK33.

---

## 1. The question

> One matvec job can be emitted and is verified four ways. **Nothing emits a
> LAYER.** A layer needs job sequencing, region routing, and the subsystem D
> header fields subsystem A reads none of. `rtl/llama_top.vhd` already runs a
> 491-descriptor 32-block token; find how `tb_llama_top` builds it, understand
> it, and emit a real layer program for one Qwen3.5-9B layer, from the
> manifest, at the FK33 geometry. Verify it against something independent.

---

## 2. The answer

`tools/gen_layer_program.py` emits, for any Qwen3.5-9B block, the subsystem D
step table (16 descriptors for a GDN block, 13 for an attention block), the
per-step release mask, and one 312-byte subsystem A descriptor per matvec at
the FK33 geometry, from `manifest.json` and the packed tensors' own headers.

The strongest checks achieved, both MEASURED:

* **Byte-identity against BOTH VHDL generators.** The tool's whole-token table
  is byte-identical to `sim/seq_tbl_pkg.vhd`'s `build_table` over all 491
  descriptors / 3,928 words at the real 9B shape, and byte-identical to
  `sim/llama_sched_pkg.vhd`'s `build_table` (plus its `build_plan` release
  mask) at **10 different simulation shapes**. Those are two independent VHDL
  implementations, written by other authors, and the second is the one
  `rtl/llama_top.vhd` actually executes.
* **The RTL as judge, twice.** All 15 A descriptors of layers 0 and 3 are
  ACCEPTED by `rtl/matvec_int4_desc_axi.vhd` through
  `sim/tb_mv4i_desc_image.vhd`, on their actual bytes. And a program emitted by
  this tool, read from a file, was **executed by `rtl/llama_top.vhd`** and
  produced bit-identical region R_X to the run driven by the VHDL table, at 1,
  2 and 4 blocks.

**Three findings that matter more than the tool:**

1. **A subsystem A descriptor and a subsystem D table entry cannot be the same
   bytes.** D's table is DENSE at a 64-byte stride, so step `i+1`'s header sits
   exactly where step `i`'s base array would have to be. The format document's
   claim that "a descriptor written to this specification is accepted by
   `seq_desc_fetch` unchanged" is true of ONE descriptor and false of a TABLE.
2. **Two of the three GDN qkv jobs are not expressible at ROWS_IF = 48.** The
   packed tensor is fused; the split asks for row windows at 2048 and 4096;
   `2048 mod 48 = 32` and `4096 mod 48 = 16`, and a window can only begin on a
   tile boundary. 48 of the token's 297 A jobs are refused for this reason.
3. **A layer program is a FRAGMENT, not a runnable table.** `seq_desc_fetch`
   enforces END_TOKEN-last in hardware. MEASURED: the 16-step layer slice is
   refused with `ERR_DESC` at step 15.

---

## 3. The survey: how the existing 491-descriptor program is built

There are **two** VHDL table generators and they are not the same thing.

| file | what it is | executed? |
|---|---|---|
| `sim/seq_tbl_pkg.vhd` | the real 491-descriptor Qwen3.5-9B token at REAL dimensions (hidden 4096, FFN 12288). Every dimension folded off `rtl/model_cfg_pkg.vhd`. | **NO.** It is walked by `sim/tb_seq_desc_fetch.vhd` and never computed; its own header says 491 real steps is "tens of millions of element-cycles, which GHDL will not finish inside a working day". |
| `sim/llama_sched_pkg.vhd` | the SAME step sequence from a `shape_t`, so it can be scaled down (hidden 64, FFN 128). Encodes every descriptor with `seq_tbl_pkg.mk_desc`, so the wire format cannot fork. | **YES**, by `sim/tb_llama_top.vhd`. |

So the thing `rtl/llama_top.vhd:350` calls "the 491-descriptor 32-block token"
is `llama_sched_pkg.build_table(mk_shape_scaled(32, 4))`: the real 491-step
SEQUENCE at a scaled ELEMENT COUNT. The 491 real-dimension descriptors of
`seq_tbl_pkg` have never been executed by anything.

**The step sequence, at NCARDS = 1** (`NSTEP_GDN_N1 = 16`,
`NSTEP_ATTN_N1 = 13`, plus 3 for the tail; 24x16 + 8x13 + 3 = 491):

```
GDN block                          attention block
 0 VEC_NORM  X   -> XN              0 VEC_NORM  X   -> XN
 1 A_JOB     XN  -> QKV off 0       1 A_JOB     XN  -> QG    (wq, Q+gate)
 2 A_JOB     XN  -> QKV off KEY     2 A_JOB     XN  -> KIN   (wk)
 3 A_JOB     XN  -> QKV off 2*KEY   3 A_JOB     XN  -> VIN   (wv)
 4 A_JOB     XN  -> Z     (gate)    4 C_JOB     QG  -> Y
 5 A_JOB     XN  -> BETA            5 A_JOB     Y   -> ER    (wo)
 6 A_JOB     XN  -> ALPHA           6 VEC_RES   X,ER-> X
 7 B_JOB     QKV -> Y               then the same 6-step FFN tail
 8 A_JOB     Y   -> ER   (ssm_out)
 9 VEC_RES   X,ER-> X
   then the 6-step FFN tail:  VEC_NORM X->XN, A XN->G, A XN->U,
                              VEC_SWG G,U->H, A H->ER, VEC_RES X,ER->X
tail of the token: VEC_NORM X->XN, A_JOB XN->(sampler, out_mode 1), END_TOKEN
```

### 3.1 How `seq_desc_fetch` consumes the table

`rtl/seq_desc_fetch.vhd:574`:

```vhdl
d_raddr <= resize(fetch_idx & "000", 16) + to_unsigned(f_beat, 16);
```

Step `i`'s 8 words are at 64-bit word addresses `8i .. 8i+7`. **The table is a
dense array of 64-byte headers in URAM.** `d_ren`/`d_rvalid` is a registered
read of arbitrary latency; the fetch writes a two-bank shadow and the banks
swap once, at the transition into `S_ISSUE`.

Three things the table does NOT carry, each with a different owner:

* **The base array.** `seq_desc_fetch.vhd:113-115` says it is not fetched;
  fetching it is remaining work. `rtl/llama_top.vhd:1913` therefore synthesises
  A's bases as `A_MEM_BASE + step*A_JOB_STRIDE + p*4096`.
* **The release mask.** `rtl/seq_opdec.vhd` finding (3): it is a whole-table
  liveness property with no field in the format, so it arrives on the
  `rel_mask` port and the host computes it.
* **The codebook.** D's header has words 5 and 6 for it and flags bit 2 for
  `cb_load`; neither VHDL generator ever sets any of them.

### 3.2 Which D header fields matter, per opcode

MEASURED by mutation (section 6), not asserted:

| field | A_JOB | B/C_JOB | D-vec op | END_TOKEN |
|---|---|---|---|---|
| `opcode` | selects the unit; a wrong one is `ERR_UNIT`-class and refused | same | same | must be last, and last must be it |
| `src`, `dst`, `dst_offset`, `n_rows` | checked by `seq_region_lock`: append-only (`iss_off = fill_ptr`), must fit, lock state legal | same | same | ignored |
| `src2` | ignored (A has one source) | ignored | **load-bearing** for VEC_RES and VEC_SWG | ignored |
| `n_cols` | A's K | ignored | ignored | ignored |
| `w_exp`, `out_shift` | **live for the whole job** in `matvec_core`; `out_shift` outside 0..40 is `err` | ignored | ignored | ignored |
| `out_mode` | 0/1/2 | ignored | ignored | ignored |
| `ordinal` | inert | reaches B/C as the layer index | inert | inert |
| `nsub_w`, `nsub_s` | range-checked against `NSUB_MAX` only | ditto | ditto | ditto |
| `const_base`, `const_exp` | inert | inert | published, **consumed by nothing in `llama_top`** | inert |
| word 3 `[63:56]`, word 7 | PAD, checked `0x00` | same | same | same |

### 3.3 Contradictions found, RTL over prose

**(a) The A descriptor cannot live inside the D table.**
`docs/2026-08-28_matvec-descriptor-format.md` section 2 places A's base array
at offset `0x40` of the same descriptor and concludes that "a descriptor
written to this specification is accepted by `seq_desc_fetch` unchanged". That
holds for a descriptor read alone. In a TABLE the next header is at `0x40`.
The two objects have to be separately allocated, and **nothing in D's header
points at A's descriptor**: `matvec_int4_desc_axi` takes `DESC_PTR` over
AXI-Lite, and `llama_top` bypasses the question entirely by synthesising bases
arithmetically. This is an open integration decision, named here, not invented.

**(b) The two VHDL generators disagree about three fields.** All three are
inert to the gateware, which is why the disagreement survived:

| field | `seq_tbl_pkg` | `llama_sched_pkg` |
|---|---|---|
| `ordinal` | the block index on a VEC_NORM, the per-type ordinal on B/C, 0 elsewhere; **0 on the tail norm** | `blk mod 64` on EVERY step, so `blocks mod 64` on the tail norm |
| `nsub_w`/`nsub_s` | only on an A_JOB | on every step |
| `const_base` | only on a VEC_NORM | on every step |

The tool reproduces either, selected by `--stamp`, which is what makes the
byte comparison against both of them possible.

**(c) `nsub_w = 29 / nsub_s = 4` is not the FK33 geometry.** Both VHDL
generators write 29/4 ("D section 2.2-J"). The FK33 packing is 24/3
(`manifest.json` `geometry`), and `matvec_int4_desc_axi` raises `ERR_GEOM` on
anything else. D never notices because it only range-checks the field against
`NSUB_MAX = 64`. `--stamp manifest` takes 24/3 from the manifest.

**(d) `MAXROWS_BFP` bites the lm_head step, not any layer step.** The tail
A_JOB has `n_rows = 248320` against `MAXROWS_BFP = 17408`. Confirmed here (not
newly discovered) that the usable stride is `(17408 // 48) * 48 = 17376` and
that 15 windows tile 248,320 rows exactly, every one accepted by
`rtl_would_reject`.

---

## 4. What one layer actually requires

`blk.0` (GDN), 16 steps, 1,024 bytes of D table, 8 matvecs:

```
  # step  opcode     src  src2 dst  off      n_rows  n_cols  tensor
      0  VEC_NORM  X    -    XN   0        4096    0
      1  A_JOB     XN   -    QKV  0        2048    4096    blk.0.attn_qkv.weight  rows    0..2047
      2  A_JOB     XN   -    QKV  2048     2048    4096    blk.0.attn_qkv.weight  rows 2048..4095  REFUSED
      3  A_JOB     XN   -    QKV  4096     4096    4096    blk.0.attn_qkv.weight  rows 4096..8191  REFUSED
      4  A_JOB     XN   -    Z    0        4096    4096    blk.0.attn_gate.weight
      5  A_JOB     XN   -    BETA 0        32      4096    blk.0.ssm_beta.weight
      6  A_JOB     XN   -    ALPHA 0        32      4096    blk.0.ssm_alpha.weight
      7  B_JOB     QKV  -    Y    0        4096    0
      8  A_JOB     Y    -    ER   0        4096    4096    blk.0.ssm_out.weight
      9  VEC_RES   X    ER   X    0        4096    0
     10  VEC_NORM  X    -    XN   0        4096    0
     11  A_JOB     XN   -    G    0        12288   4096    blk.0.ffn_gate.weight
     12  A_JOB     XN   -    U    0        12288   4096    blk.0.ffn_up.weight
     13  VEC_SWG   G    U    H    0        12288   0
     14  A_JOB     H    -    ER   0        4096    12288   blk.0.ffn_down.weight
     15  VEC_RES   X    ER   X    0        4096    0
```

The tensor-to-step mapping is unambiguous and is CHECKED against the packed
shapes rather than assumed: `ffn_gate` gives hidden and FFN, `attn_qkv` gives
`qkv_dim`, `attn_gate` gives `val_dim`, `ssm_beta` gives `val_heads`,
`attn_q` gives `att_qg`, `attn_k` gives `att_kv`, `output.weight` gives the
vocab. Nine such identities at a GDN layer, eight at an attention layer, all
of which must hold or nothing is emitted (teeth-checked, case G1).

### 4.1 The qkv split, and why it does not fit

`seq_tbl_pkg`'s three-way split exists so each of q, k and v gets its own
`y_exp`: `seq_opdec` INFERS the exponent segment from `dst_offset` against its
`MSEG_OFF1`/`MSEG_OFF2` generics. The packed tensor is one fused matrix of
8,192 rows, so the k and v jobs are row WINDOWS of it. A window advances every
sub-region base by whole TILES, because a sub-region's beats run tile-major:

```
key_dim      = 16 * 128 = 2048      2048 mod 48 = 32
2 * key_dim  =           4096       4096 mod 48 = 16
ROWS_IF      =             48       fixed:  NPORTS_W*AXI_DW = ROWS_IF*BLK*4
                                            24*256 = 6144 = ROWS_IF*128
```

so neither window starts on a tile boundary and neither is expressible. **Only
segment 0 of the split survives at ROWS_IF = 48.** MEASURED over the whole
token: 297 A jobs, 248 emitted, 49 refused -- 24 at row 2048, 24 at row 4096,
1 the lm_head shape.

`--qkv-fused` emits one job over all 8,192 rows instead. That is a DIFFERENT
PROGRAM, not a repair: it collapses R_QKV's three exponent segments into one,
and it changes the step count (443 instead of 491 for the token). With it, 248
of 249 A jobs are emitted and the only refusal is the lm_head.

Closing this properly needs one of: repacking `attn_qkv` as three tensors, a
`ROWS_IF` dividing 2048 (impossible at this AXI_DW), or accepting one exponent
segment for q|k|v. It is a packing/geometry decision, not a tool fix.

---

## 5. The evidence

### 5.1 Byte-identity against both VHDL generators (MEASURED)

Dumped with a scratch `dump_tables` entity that writes
`seq_tbl_pkg.build_table` and `llama_sched_pkg.build_table`/`build_plan` to
text; compared with `diff`. No repository file was touched.

```
seq_tbl_pkg  (real 9B, 491 steps, 3928 words): diff = 0
llama_sched_pkg + build_plan release mask, 10 shapes:

blocks=1  attn_int=4 hd=32  steps=19   table_diff=0  rel_diff=0
blocks=2  attn_int=4 hd=32  steps=35   table_diff=0  rel_diff=0
blocks=4  attn_int=4 hd=32  steps=64   table_diff=0  rel_diff=0
blocks=8  attn_int=4 hd=32  steps=125  table_diff=0  rel_diff=0
blocks=16 attn_int=4 hd=32  steps=247  table_diff=0  rel_diff=0
blocks=32 attn_int=4 hd=32  steps=491  table_diff=0  rel_diff=0
blocks=4  attn_int=4 hd=16  steps=64   table_diff=0  rel_diff=0
blocks=32 attn_int=4 hd=16  steps=491  table_diff=0  rel_diff=0
blocks=8  attn_int=2 hd=32  steps=119  table_diff=0  rel_diff=0
blocks=9  attn_int=3 hd=32  steps=138  table_diff=0  rel_diff=0
```

The release mask is the part worth noting: it is a whole-table liveness pass,
it is the one thing in the program with no descriptor field at all, and two
independent implementations of it agree on 1,703 masks.

### 5.2 The RTL judging the A descriptor bytes (MEASURED)

`sim/tb_mv4i_desc_image.vhd`, unmodified, pointed at each emitted image:

```
layer 0 (GDN, --qkv-fused)                       layer 3 (attention)
a01 blk.0.attn_qkv.weight    accept              a49 blk.3.attn_q.weight       accept
a02 blk.0.attn_gate.weight   accept              a50 blk.3.attn_k.weight       accept
a03 blk.0.ssm_beta.weight    accept              a51 blk.3.attn_v.weight       accept
a04 blk.0.ssm_alpha.weight   accept              a53 blk.3.attn_output.weight  accept
a06 blk.0.ssm_out.weight     accept              a56 blk.3.ffn_gate.weight     accept
a09 blk.0.ffn_gate.weight    accept              a57 blk.3.ffn_up.weight       accept
a10 blk.0.ffn_up.weight      accept              a59 blk.3.ffn_down.weight     accept
a12 blk.0.ffn_down.weight    accept
```

15 of 15, "accept" meaning S_CHECK passed and the core pulsed `start`.

### 5.3 `llama_top` executing a host-generated program (MEASURED)

A scratch bench (`tb_prog_file`, in the session scratchpad, NOT committed and
NOT a gate row) instantiates `rtl/llama_top.vhd` unchanged and reads the
descriptor table and release mask from FILES instead of from the VHDL package.
Everything else is `tb_llama_top`'s configuration: real A, real B, stub C,
`NORM_ANCHOR` on, the same synthetic weight function, the same embedding.

```
blocks=1  REF (VHDL table)   steps=19 issued=18 cmp=19 faults=0 RX0=108    hash=970568
blocks=1  MINE (this tool)   steps=19 issued=18 cmp=19 faults=0 RX0=108    hash=970568
blocks=2  REF               steps=35 issued=34 cmp=35 faults=0 RX0=-15808 hash=113254
blocks=2  MINE              steps=35 issued=34 cmp=35 faults=0 RX0=-15808 hash=113254
blocks=4  REF               steps=64 issued=63 cmp=64 faults=0 RX0=-12049 hash=613102
blocks=4  MINE              steps=64 issued=63 cmp=64 faults=0 RX0=-12049 hash=613102
```

`hash` is a 31-multiplier rolling hash over all `hidden` elements of R_X after
the token; `distinct` was 63 of 64 in every run, so the stream is not a
constant.

**One LAYER, executed on its own:**

```
layer 0 slice, 16 steps, no END_TOKEN
    FAULT err='1' code=3 step=15        <- ERR_DESC, the counting identity
    RESULT steps=15 issued=15 faults=257

layer 0 slice + END_TOKEN (--close-token), 17 steps
    RESULT steps=17 issued=16 cmp=17 faults=0 RX0=108 hash=970568 distinct=63

layer 3 slice + END_TOKEN, 14 steps
    RESULT steps=14 issued=13 cmp=14 faults=0 RX0=-2759 hash=112105 distinct=63
```

The layer-0 figure `RX0=108 hash=970568` is **the same R_X the 1-block whole
token produces**, which is the right answer: the token tail writes R_XN and the
lm_head writes nowhere, so R_X after block 0 is unchanged by it. That agreement
was not arranged; it is two differently-generated programs reaching the same
state through the same RTL.

---

## 6. Teeth: 20 program mutations, judged by the RTL

`blocks=4` sim shape, one mutation at a time on the emitted files, the DUT
unchanged. Verdicts: **REFUSED** = a seam fault fired or the walker raised
`err` (the RTL saw it, unaided); **DIFFERENT** = the token completed clean but
R_X changed (only a reference program can see this); **SILENT** = the token
completed clean and R_X was bit-identical.

| # | mutation | verdict | evidence |
|---|---|---|---|
| 1 | step ORDER: block 0's steps 2 and 3 swapped | REFUSED | halts at step 2, 257 faults |
| 2 | REGION id: the v segment writes R_Z, not R_QKV | REFUSED | halts at step 3 |
| 2b | REGION id: BETA and ALPHA destinations swapped | **SILENT** | identical hash |
| 3 | DST OFFSET: step 3's `dst_off` + 8 | REFUSED | halts at step 3 (append-only check) |
| 4 | ORDINAL: the B_JOB's ordinal + 1 | DIFFERENT | hash 613102 -> 376450 |
| 4b | ORDINAL: block 0's norm claims ordinal 3 | **SILENT** | identical hash |
| 5 | SRC region: step 2 reads R_X, not R_XN | DIFFERENT | hash 613102 -> 557158 |
| 6 | SRC2: the residual's second operand R_H, not R_ER | REFUSED | halts at step 9 |
| 7 | N_ROWS: step 2 halved | REFUSED | halts at step 3 |
| 8 | OPCODE: step 5 A_JOB -> B_JOB | REFUSED | halts at step 5 |
| 9 | W_EXP: step 2 + 1 | DIFFERENT | hash 613102 -> 904448 |
| 10 | OUT_SHIFT: step 2 + 1 | **SILENT** | identical hash |
| 11 | CONST_BASE: block 0's norm names block 3 | **SILENT** | identical hash |
| 12 | CONST_EXP: + 1 on every step | **SILENT** | identical hash |
| 13 | NSUB_W: 29 -> 23 on every step | **SILENT** | identical hash |
| 14 | PAD: word 3 `[63:56]` nonzero on step 1 | REFUSED | halts at step 1 |
| 15 | END_TOKEN removed | REFUSED | 257 faults at the end |
| 16 | STEP DROPPED: block 0's residual | REFUSED | halts at step 13 |
| 17 | REL MASK: R_XN released one reader early | REFUSED | halts at step 2 |
| 18 | REL MASK: nothing ever released | REFUSED | halts at step 10 |

**13 REFUSED, 3 DIFFERENT, 6 SILENT** (counting 2b and 4b).

### 6.1 The six silent passes, named

Every one is a real defect class, and none is a defect in the generator.

| mutation | why nothing can see it |
|---|---|
| **2b BETA/ALPHA destinations swapped** | the two regions have the SAME size (`val_heads`), so every structural check the lock makes is satisfied. The values reach subsystem B on the wrong ports. `llama_top`'s B adapter is fed alpha and beta from fixed-scale stand-ins by default (`B_SRC_REAL = false`), so the run was numerically insensitive to it here; with `B_SRC_REAL` true it would be a wrong number, still with no fault. **Only a numeric oracle for B can catch this.** |
| **4b norm ordinal wrong** | `ordinal` on a VEC_NORM would select the norm WEIGHT for that block. There is no weight region, no packed norm weight and no consumer: `llama_top`'s norm uses a fixed-scale stand-in. The field is currently decorative on this opcode. |
| **10 out_shift off by one** | it changes a scaling by one binary place, and the BFP exponent absorbs it: `y_exp = w_exp + x_exp - out_shift - ns`. Same family as `gen_mv4i_desc`'s x_exp/w_exp silent passes. Here the mantissas came back identical, so even the differential could not see it. |
| **11 const_base wrong** | same as 4b: it names a norm weight nothing loads. |
| **12 const_exp wrong everywhere** | published by `seq_desc_fetch`, consumed by nothing in `llama_top`. |
| **13 nsub_w 29 -> 23** | D only range-checks it against `NSUB_MAX = 64`. Note this is the SAME field whose value the FK33's A wrapper refuses with `ERR_GEOM` -- so the field has real teeth in A and none at all in D, and the value both VHDL generators write (29) is one A would refuse. |

Mutations 4, 5 and 9 are DIFFERENT rather than REFUSED, which is worth stating
plainly: they were caught **only because a reference program existed**. A host
generator in production has no reference. So on the current design the D
program's `ordinal`, `src` and `w_exp` fields have no gateway-side check at
all -- the region lock checks `dst` placement, not `src` identity.

### 6.2 Subsystem A descriptor mutations, judged by the RTL

| mutation | RTL verdict |
|---|---|
| clean `ffn_gate`-step descriptor | accept |
| the `ffn_up` step's 27 bases pasted into the `ffn_gate` step | **accept -- SILENT** |
| `w_base[7]` aimed at sub-region 8 | **accept -- SILENT** (worklog OI-1) |
| `x_exp` + 1 | **accept -- SILENT** |
| `dst_offset` = 777 (a D field A ignores) | **accept -- SILENT**, and correctly so |
| `w_beats` halved | reject, `err_code 0xF` (ERR_SHAPE), `err_info 36` |
| every base + 4096 (a wrong `hbm_offset`) | **accept -- SILENT** |

The second row is the PROGRAM-level instance of OI-3's family and is new here:
**nothing binds an A descriptor to the step it belongs to.** Both descriptors
are perfectly well-formed; only the bases differ; the gateware computes a
plausible wrong answer for both. The generator closes this at the host by
building both from the same step record, but on the card there is no check.

### 6.3 The generator's own teeth (MEASURED)

| # | broken input | result |
|---|---|---|
| G1 | manifest whose `blk.0.ffn_gate.K` is 4095 | refuses everything: "the model shape and the packed tensors DISAGREE: hidden shape says 4096, manifest says 4095" |
| G2 | `blk.0.ssm_out.weight` removed from the manifest | that step REFUSED "not in the manifest", 7 of 8 emitted |
| G2b | the `.mv4i` files absent from disk | every step REFUSED by name |
| G3 | one byte flipped in `blk.0.ssm_beta.weight.mv4i` | REFUSED: "blake2b_128 e37a12af... manifest says 477b3b60..." |
| G4 | `--x-exp` omitted | refuses to emit any A descriptor and says why |
| G5 | `--layer 99` | "no steps for layer 99" |
| G6 | the qkv split at ROWS_IF = 48 | both windows REFUSED with the modular arithmetic |

G3 is inherited from `gen_mv4i_desc.py` and is re-confirmed through this path
rather than assumed.

---

## 7. Measured and REJECTED -- do not retry

* **Putting the A base array at `0x40` of a D table entry.** It is where the
  next step's header lives. Measured from `seq_desc_fetch.vhd:574`, not
  reasoned about. The two objects must be separately allocated.
* **Expressing the three-way qkv split as three row windows at ROWS_IF = 48.**
  `2048 mod 48 = 32`. Not a tool limitation and not fixable in a tool.
* **Running a layer slice as a D table.** ERR_DESC at the last step, measured.
  It needs a terminating END_TOKEN (`--close-token`).
* **Editing `sim/tb_llama_top.vhd` to read a table from a file.** Not this
  track's file, and not needed: `llama_top`'s program arrives entirely over
  `d_rdata`, `rel_mask` and `tbl_len`, so a separate bench substitutes the
  program without touching the DUT or the committed bench.
* **Treating the tool's own decoder as verification.** Deliberately not
  written. Every check here is either another implementation
  (`seq_tbl_pkg`, `llama_sched_pkg`, `mv4i_desc_ref.c` via `gen_mv4i_desc`) or
  the RTL itself. The `m7` mutant is why.

---

## 8. Measurement traps hit

* **Two mutations initially hit the wrong step** and came back SILENT with a
  bit-identical hash, which read as a finding. It was an off-by-one in the
  mutation harness: at the scaled shape step 4 is already the gate matvec and
  step 7, not 8, is the B_JOB, so "change step 4's destination to R_Z" was a
  no-op. Corrected and re-run; both then bit. **A silent pass whose mutation
  changed nothing is not a silent pass**, and the tell is a byte-identical
  output rather than merely an equal verdict.
* **`ghdl -a` in a blind loop over `rtl/*.vhd` obsoletes its own results.**
  Re-analysing an already-analysed package marks every dependent obsolete, so
  the naive "run it five times until it works" loop never converges. Track
  which files succeeded and stop analysing those.
* **A `cd` inside a shell helper function leaks to the caller.** Two runs of
  the differential compared a stale table against a fresh reference and
  reported a spurious assertion failure. Wrap the `cd` in a subshell.
* **8 blocks does not finish in two minutes.** The differential was run at 1,
  2 and 4; 8 was started and timed out. That is wall time, not a result, and
  it is recorded as not-run rather than as a pass.

---

## 9. Open, not determined here

* **Nothing links a D step to its A descriptor.** D's header has no pointer
  field, `matvec_int4_desc_axi` takes `DESC_PTR` over AXI-Lite, and `llama_top`
  synthesises bases arithmetically instead. Whoever wires A into the FK33 shell
  decides: a pointer field in a widened header, a host-side table indexed by
  step, or writing `DESC_PTR` per job from the host. This tool ALLOCATES the
  addresses (`--desc-base`, default the top of HBM, 512-byte aligned, 126,976
  bytes for a whole token) and emits them, and that allocation is a proposal.
* **Nothing in the manifest reserves descriptor space.** The default placement
  takes it from the top of HBM, which comes out of `max_context`. 126,976 bytes
  is about 2 tokens of the 65,536-byte-per-token KV budget. Someone owns this
  number; it is not the tool.
* **`x_exp` is still a hole, by design.** Same as `gen_mv4i_desc`: it is a
  per-token runtime value and the descriptor's copy is stale by construction.
  `USE_XEXP_PORT` exists for exactly this and which one the FK33 build uses is
  undecided.
* **`w_exp`/`out_shift` for a D-vec op have no source at all.** Written 0 by
  `--stamp manifest`. Both VHDL generators stamp them from the step index on
  purpose, which is right for a walker test and wrong for a program.
* **No arithmetic claim is made about the layer.** The layer program was
  executed at the SCALED shape (hidden 64) against SYNTHETIC weights and a stub
  C. `tb_llama_top`'s own header is explicit that there is no block-level
  oracle, and the whole of worklog OI-3 applies unchanged. **What is verified
  here is the PROGRAM, not the computation it drives.**
* **The real-dimension layer was never executed.** 4096-wide steps at 12,288
  FFN are the same cost that keeps `seq_tbl_pkg`'s 491 descriptors unexecuted.
  The A descriptors for the real layer were judged by the real A wrapper; the
  D table for the real layer was byte-compared against `seq_tbl_pkg` and never
  run.
* **`out_mode` 1 and 2 remain unexercised**, as in worklog OI-10. The lm_head
  step is the only `out_mode = 1` descriptor the tool emits and it is refused
  for its shape before that matters.

---

## 10. From one layer to one token

The tool already emits the whole token (`--token`). What is missing is not the
generator:

1. **The lm_head must become 15 jobs, not one.** `MAXROWS_BFP = 17408`, usable
   stride 17,376, 14 x 17,376 + 5,056 = 248,320 (confirmed here, every window
   accepted by `rtl_would_reject`). But a D step is one job, so this is a
   SCHEDULE change -- 15 steps writing 15 windows -- not a descriptor change,
   and it needs a destination region the sampler can read from. `token_embd`
   has the same shape and the same problem at the input end.
2. **The qkv split has to be resolved** (section 4.1). 48 of 297 A jobs are
   currently inexpressible.
3. **The A-descriptor delivery mechanism has to be chosen** (section 9).
4. **`x_exp` per step** has to come from the previous stage rather than the
   descriptor, or `USE_XEXP_PORT` has to be turned on and wired.
5. **The token loop** -- position, KV cache, RoPE -- is absent from `llama_top`
   entirely, and `attn_kv_axi` is not wired. A token is one pass; a SEQUENCE is
   not, and multi-token is worklog backlog item 3.

Nothing on that list is host-tool work except (1).
