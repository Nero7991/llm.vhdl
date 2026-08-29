# Padding the fused qkv row segments to a ROWS_IF tile

**Date:** 2026-08-29. Branch `fpga`. Track QKV-PAD.
**Card:** SQRL FK33, `xcvu33p-fsvh2104-2L-e`. **No hardware was touched.**
**Sets:** input `/mnt/storage/llama-models/qwen35-9b-mv4i/` (hash-verified, NOT
modified); output `/mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/`.
Labels: **MEASURED** (a named tool ran), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement, assumption stated).

---

## 1. The question

> `docs/debugging/2026-08-29_layer-descriptor-program.md` finding 2: the GDN
> qkv tensor is packed FUSED at `M = 8192`, but the layer program needs three
> jobs whose row windows start at 0, 2048 and 4096. A window can only begin on
> a tile boundary, and `2048 mod 48 = 32`, `4096 mod 48 = 16`. **48 of the
> token's 297 subsystem A jobs are refused outright.** Oren has chosen: pad
> each segment up to the next multiple of `ROWS_IF = 48` so the following
> segment starts tile-aligned. Confirm the shapes, decide what the pad rows
> contain, implement it, verify the packed BYTES, prove the jobs are accepted,
> and teeth-check.

---

## 2. The answer, up front

**Done, and the refused-job count went from 49 to 1.** The one that remains is
the lm_head, which is a different defect (`MAXROWS_BFP`, a schedule change) and
is untouched here.

Each segment but the last is padded with **zero** rows to a whole tile, so the
packed starts are **0, 2064, 4128** (= 0, 43, 86 tiles) and `M` becomes
**8224**. The pad rows are numerically inert: **MEASURED**, a matvec over each
padded segment reproduces the unpadded rows **bit for bit**, over all 24
tensors, in RAW; over the 33,554,432 quantized nibbles and 1,048,576 scales of
every real row; and in BFP on the one window both files can express, including
`ns` and `y_exp`.

**Zero is the right fill for a reason stronger than "it is inert".** Pad rows
sit at an index `>= n_rows`, and both `ref/matvec_int4.c:404` and
`rtl/matvec_core.vhd:876` mask such a row out of the BFP `amax` fold, so under
the correct scan domain ANY fill would be invisible. Zero is the only fill that
is also invisible under the WRONG scan domain, because a magnitude of zero
cannot change a maximum. MEASURED, `nsprobe`, q window of `blk.0`:

```
clean padded file      n_rows=2048  ns=5  y_exp=5   mantissa hash -317029762172332375
                       n_rows=2064  ns=5  y_exp=5   mantissa hash -317029762172332375   <- pad included, NOTHING moves
pad rows corrupted     n_rows=2048  ns=5  y_exp=5   mantissa hash -317029762172332375
to full scale          n_rows=2064  ns=8  y_exp=2   mantissa hash  8006707523924609726  <- pad included, exponent shifts 3 places
```

So the brief's worry -- "a tile of mostly-zeros can shift a shared exponent" --
is backwards for this format, and the measurement says so: there is no per-tile
shared exponent (`scale` is per row per BLOCK of 32, `w_exp` is per matrix), a
zero row cannot move the per-job `ns`, and it is a NONZERO fill that would make
the design depend on the `n_rows` masking staying correct for ever.

Cost, DERIVED and MEASURED as the difference between two manifests: 48 dead
rows in 8,192 (0.586%), one extra tile per file, **+110,592 B per tensor,
+2,654,208 B over the 24**, and **-12 tokens of context** (52,331 -> 52,319).
`check_hbm_stack.py` PASSes on the new manifest, 7,182 ranges.

---

## 3. Confirming the shape first, from the files and the GGUF

Not from the brief. Two independent sources, MEASURED.

**The packed headers.** All 24 `blk.*.attn_qkv.weight.mv4i` parse to
`M = 8192, K = 4096, ROWS_IF = 48, NPORTS_W = 24, AXI_DW = 256,
n_scale_sub = 3`; the manifest's `M`/`K`/`nbytes` agree with every header;
`w_exp` is 8 on 21 of them, 9 on two and 7 on one (per tensor, as expected);
`out_shift` is 3 on all. The qkv tensors are in blocks
`0,1,2,4,5,6,8,...,30` -- the 24 GDN blocks -- and `attn_q` is in the 8
attention blocks `3,7,...,31`, so no block has both.

**The GGUF metadata**, read straight out of `Qwen3.5-9B-BF16.gguf`:

```
qwen35.ssm.state_size  = 128     = lin_head_dim    (rtl/model_cfg_pkg.vhd:32)
qwen35.ssm.group_count = 16      = lin_key_heads   (rtl/model_cfg_pkg.vhd:33)
qwen35.ssm.inner_size  = 4096    = val_dim
qwen35.block_count = 32   qwen35.full_attention_interval = 4
```

so `key_dim = 128*16 = 2048`, `val_dim = 4096`, and
`2*key_dim + val_dim = 8192 = M`. **The 2048 | 2048 | 4096 split is confirmed
and is the same in every one of the 24 layers**, because `M` is identical in
all 24 files and the split is a per-MODEL number. D-PROG's report is right; there
is no per-layer variation to report.

`tools/pack_model_fk33.py:qkv_segments` derives the split from those three
metadata keys and **raises rather than assuming** if `2*key + val != M`. The
constant 2048 appears nowhere in the packer.

---

## 4. The pad, and why it is 16 / 16 / 0

`tools/pack_int4.py:segment_row_plan`, DERIVED:

```
segment   logical rows        pad   packed rows          start / 48
q         0    .. 2047        16    0    .. 2063          0 = 0*48
k         2048 .. 4095        16    2064 .. 4111         43 = 2064/48
v         4096 .. 8191         0    4128 .. 8223         86 = 4128/48
                                    M_packed = 8224
```

**The last segment is not padded**: nothing follows it, and `pack()` already
rounds the file up to a whole tile. `tiles = ceil(8224/48) = 172`, so the file
holds 8,256 rows and the trailing 32 are the packer's pre-existing implicit
padding. Against the old file (`tiles = 171`, 8,208 rows, 16 implicit pad rows)
the file grows by exactly **one tile = 48 rows**, which is the "48 wasted rows"
of the brief. Note the brief's illustration writes `v 4128..8207`; that is 4,080
rows and would drop 16 real rows of v. The correct end is **8223**.

Every window is inside `MAXROWS_BFP = 17408` and `GRP = 3*256/(48*16) = 1`, so
`skip_tiles*nb mod GRP = 0` for every start and the scale window is expressible
as a base offset. **The padding does not interact with the `MAXROWS_BFP`
17,376 stride**: that stride only applies to the two 248,320-row tensors, which
are not fused, carry no `segments`, and were not repacked (their digests are
unchanged).

**Beat counts move with the window and the generator computes them:**
`w_beats = tiles*nb` is 43*128 = **5504** for q and k and 86*128 = **11008**
for v, and the descriptor carries them. See section 8 for the ERR_SHAPE teeth.

---

## 5. The implementation

| file:line | what |
|---|---|
| `tools/pack_int4.py:361` `segment_row_plan` | the pad arithmetic, and the written-down reason zero is the fill |
| `tools/pack_int4.py:416` `apply_segment_padding` | inserts the zero rows into the (M,K) float array before `quantize` |
| `tools/pack_int4.py:835,882` | `--seg-rows a,b,c` for the single-tensor packer |
| `tools/pack_model_fk33.py:183` `gguf_kv` / `:194` `qkv_segments` | the split, DERIVED from GGUF metadata and checked against `M` |
| `tools/pack_model_fk33.py:309` | the per-tensor pad decision; `M` becomes the padded count everywhere a size is derived from it |
| `tools/pack_model_fk33.py:346` | `W` is padded before `quantize`, and the shape asserted both before and after |
| `tools/pack_model_fk33.py:403` | manifest entry gains `M_logical` and `segments` |
| `tools/pack_model_fk33.py:477,499` | `geometry.qkv_segment_pad` records which kind of set this is |
| `tools/pack_model_fk33.py` CLI | `--no-qkv-pad` reproduces the historic set |
| `tools/check_mv4i_set.py:173` | the segment guard: tile alignment, cover, the pad rule, no overrun |
| `tools/gen_layer_program.py:515` | LOGICAL row -> PACKED row through the manifest's segment table |
| `tools/gen_layer_program.py:537` | refuses a window that runs past the packed `M` (new, see section 8 m7) |
| `tools/gen_layer_program.py:586` | the shape cross-check reads `M_logical`, not `M` |
| `tools/qkv_pad_equiv.c` | NEW. The numeric and byte-level oracle of section 6 |

**`quantize` is unaffected by the pad, and that is checked rather than
assumed.** `w_exp` is global and comes from `|W|.max()`, which zero rows cannot
move; a zero row takes the `best_scl == 0` branch and emits `idx = 0`,
`scale = 0`, the same bytes `pack()` already writes for trailing tile padding.
`qkv_pad_equiv` FAILs immediately if `w_exp` or `out_shift` differs between the
two files, so a requantization drift could not hide behind the row compare.

**The stack rule.** `place()` is untouched; the allocator ran over the larger
files and moved the single hole from 27,836,416 B to 25,956,352 B (the qkv
growth pushed `blk.7.ffn_gate` closer to the boundary before the skip).
MEASURED, `tools/check_hbm_stack.py`, which shares no code with the allocator
and reads every sub-region base out of each file's own header:

```
checked 7182 byte ranges against a 4294967296 B stack boundary in
  /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json
PASS no range crosses a stack boundary
```

**The manifest delta**, MEASURED:

| quantity | stackfix set | qkvpad set | delta |
|---|---|---|---|
| weights bytes | 5,056,995,328 | 5,059,649,536 | +2,654,208 |
| stack hole | 27,836,416 | 25,956,352 | -1,880,064 |
| `kv_base` | 5,160,329,216 | 5,161,103,360 | +774,144 |
| free for KV | 3.1941 GiB | 3.1933 GiB | -774,144 B |
| max context | 52,331 tok | 52,319 tok | **-12 tok** |
| files whose `hbm_offset` moved | -- | 182 of 251 | -- |
| files whose PAYLOAD digest changed | -- | **24 of 251** | exactly the qkv files |

---

## 6. Verifying the packed BYTES, not the layout

`tools/qkv_pad_equiv.c` links `ref/matvec_int4.c` -- the bit-exact reference
the RTL is validated against -- and runs three different comparisons. It never
uses the packer's arithmetic.

1. **RAW slice equivalence.** One `MODE_RAW` job over the WHOLE UNPADDED tensor
   is the oracle. RAW emits `sat32(round_shift(acc, out_shift))` per row with no
   cross-row term at all, so `y[r]` is a function of row `r` alone and slicing
   it is legitimate. Each padded segment is then issued as a real row window
   (advance every weight base by `skip_tiles*nb*port_b`, every scale base by
   `(skip_tiles*nb/GRP)*port_b`, exactly as `gen_mv4i_desc.build_descriptor`
   does) and compared element by element.
2. **Row identity.** `get_widx` / `get_scale` on both files, old row `r` against
   padded row `map(r)`, for every real row: 4,096 nibbles and 128 scales each.
   This asks the different question -- are the packed BYTES the same -- and
   would catch a requantization that moved a nibble without changing any dot
   product. It also checks that every pad row is genuinely empty.
3. **BFP identity on segment q**, the one window both files can express
   (`row_start = 0`). `ns` and `y_exp` and all 2,048 mantissas must match. This
   is the check that the pad rows do not reach the `amax` scan.

MEASURED, `blk.0`, and identical in form for all 24:

```
old   .../qwen35-9b-mv4i/blk.0.attn_qkv.weight.mv4i         M=8192 K=4096 w_exp=8 out_shift=3
new   .../qwen35-9b-mv4i-qkvpad/blk.0.attn_qkv.weight.mv4i  M=8224 K=4096 w_exp=8 out_shift=3
geom  ROWS_IF=48 nb=128 grp=1 port_b=32 nports_w=24 n_scale_sub=3
oracle   1 RAW job over the unpadded tensor, 8192 rows, sat=0
  seg 0  logical     0.. 2047 -> packed     0.. 2047 (2048 rows, tile    0)  mismatches 0
  seg 1  logical  2048.. 4095 -> packed  2064.. 4111 (2048 rows, tile   43)  mismatches 0
  seg 2  logical  4096.. 8191 -> packed  4128.. 8223 (4096 rows, tile   86)  mismatches 0
  rows     8192 real rows compared nibble by nibble: 0 idx mismatches, 0 scale mismatches
  pad      32 pad rows: 0 nonzero idx/scale entries
  BFP seg 0  old ns=5 y_exp=5  new ns=5 y_exp=5  mantissa mismatches 0
elements compared 8192 of 8192
PASS every padded segment reproduces the unpadded rows bit for bit
```

```
qkv_pad_equiv over 24 tensors: 0 failures
```

And the structural guards, MEASURED:

```
tools/check_mv4i_set.py .../qwen35-9b-mv4i-qkvpad --full
  250 packed tensors + 1 F32 side file, 5059649536 bytes total, 251 payloads hashed and matched
  PASS  every header, size, sub-region offset and HBM placement is as spec 6.4/6.5a requires
```

**The input set is unmodified.** All 251 files re-hashed against their recorded
`blake2b_128` after the run: 0 changed. The new directory holds 24 real `.mv4i`
files plus `manifest.json` and `pack.log` (26 real files, **435.6 MiB**), and
227 symlinks to the untouched payloads. `/mnt/storage` has 390 GB free.

**`--no-qkv-pad` reproduces the historic set exactly.** MEASURED: run against a
symlink directory of the ORIGINAL 251 files, the emitted manifest is identical
to `qwen35-9b-mv4i-stackfix/manifest.json` apart from the timestamp and the new
`qkv_segment_pad: false` flag. So defaulting the pad ON did not change the old
path; it added a new one.

---

## 7. The jobs are now accepted

MEASURED, `tools/gen_layer_program.py --token --x-exp 5 --stamp manifest`:

| manifest | A jobs emitted | refused |
|---|---|---|
| `qwen35-9b-mv4i-stackfix` (unpadded) | 248 of 297 | **49** -- 24 at row 2048, 24 at row 4096, 1 lm_head |
| `qwen35-9b-mv4i-qkvpad` (padded) | 296 of 297 | **1** -- the lm_head |

**All 48 qkv refusals are gone.** Layer 0, with the three windows now real:

```
  step 1    blk.0.attn_qkv.weight    rows    0.. 2047 of 8224  w_beats=5504
  step 2    blk.0.attn_qkv.weight    rows 2064.. 4111 of 8224  w_beats=5504
  step 3    blk.0.attn_qkv.weight    rows 4128.. 8223 of 8224  w_beats=11008
  10 of 10 A jobs emitted, 0 refused
```

**The one that remains, and why it is not fixed here.** `output.weight` is
248,320 rows against `MAXROWS_BFP = 17408`, so it needs 15 windows of stride
17,376 -- proven to tile exactly and MEASURED bit-identical to a single job in
`2026-08-28_hbm-stack-boundary-straddle.md` section 9. That is a **schedule**
change (15 steps, not one) and it needs a destination region the sampler can
read from, which is not decided anywhere. It would also change the token's step
count from 491 to 505 and so would break the byte-identity of the D table
against BOTH VHDL generators, which is D-PROG's strongest evidence. Deliberately
not done. `docs/debugging/2026-08-29_layer-descriptor-program.md` section 10
item 1 is the owner.

**The RTL as judge, on the actual bytes.** All 10 layer-0 A descriptors,
including the two windows that were inexpressible yesterday, driven through
`rtl/matvec_int4_desc_axi.vhd` by the unmodified `sim/tb_mv4i_desc_image.vhd`:

```
a01 blk.0.attn_qkv.weight   accept      a08 blk.0.ssm_out.weight    accept
a02 blk.0.attn_qkv.weight   accept      a11 blk.0.ffn_gate.weight   accept
a03 blk.0.attn_qkv.weight   accept      a12 blk.0.ffn_up.weight     accept
a04 blk.0.attn_gate.weight  accept      a14 blk.0.ffn_down.weight   accept
a05 blk.0.ssm_beta.weight   accept
a06 blk.0.ssm_alpha.weight  accept                            10 of 10
```

Repeated on the three qkv windows of five different GDN blocks (4, 8, 12, 20,
and 30), because one layer proves the format and not the placement: **15 of 15
accepted.**

**Subsystem D's program does not move at all.** MEASURED: the layer-0 D table
and release mask emitted against the PADDED manifest are byte-identical to the
ones emitted against the unpadded one, and the three qkv steps still carry the
LOGICAL `dst_offset` 0 / 2048 / 4096:

```
step 1 opcode=0 src=1 dst=2 dst_offset=0     n_rows=2048 n_cols=4096
step 2 opcode=0 src=1 dst=2 dst_offset=2048  n_rows=2048 n_cols=4096
step 3 opcode=0 src=1 dst=2 dst_offset=4096  n_rows=4096 n_cols=4096
```

That is the property that had to hold: `seq_opdec` infers the exponent SEGMENT
from `dst_offset` against its `MSEG_OFF1`/`MSEG_OFF2` generics, so the pad had
to move `row_start` and nothing else. It also means D-PROG's byte-identity of
the whole-token table against BOTH VHDL generators is unaffected by this track.

---

## 8. Teeth

### 8.1 The equivalence checker (5 mutants, MEASURED)

| # | mutation | verdict | evidence |
|---|---|---|---|
| 0 | clean control | PASS | -- |
| 1 | the pad NOT applied: read each segment at its LOGICAL row | KILLED | 2,048 + 4,096 = 6,144 mismatches; segment q unaffected, correctly, because its start does not move |
| 2 | one WEIGHT base +1 beat, segment k only | KILLED | 86 mismatches = 43 tiles x the 2 rows sub-region 0 supplies |
| 3 | one SCALE base +1 beat, segment k only | KILLED | 688 mismatches = 43 tiles x the 16 rows scale sub-region 0 supplies |
| 4 | a segment one row short | KILLED | cover check: 8,189 of 8,192 |
| 5 | a segment reads 16 rows INTO its own pad | KILLED | 16 mismatches per segment; also proves the pad rows are not the real rows that used to follow |

### 8.2 Mis-alignment and the manifest (7 mutants, MEASURED)

Each rebuilds a symlink directory with a perturbed manifest and runs both
`check_mv4i_set.py` and `gen_layer_program.py`.

| # | mutation | `check_mv4i_set` | `gen_layer_program` |
|---|---|---|---|
| m0 | clean control | PASS | 10 of 10, 0 refused |
| **m1** | **segment k `row_start` 2064 -> 2065, one row of mis-alignment** | **FAIL** "starts at row 2065, which is not a multiple of ROWS_IF=48" | **REFUSED** "--row-start 2065 is not a multiple of ROWS_IF = 48" |
| m2 | segment k `n_rows` 2048 -> 2047 | FAIL "segments cover 8191 rows, M_logical is 8192" | REFUSED, no segment matches the window |
| m3 | segment q `pad_rows` 16 -> 0 | FAIL "does not reach a tile boundary" | **SILENT**, 10 of 10 |
| m4 | the `segments` field deleted | **PASS** (the field is optional by design) | REFUSED x2 "tensor is padded but declares no segments" |
| m5 | segment v `logical_row` 4096 -> 4097 | FAIL "logical_row 4097, want 4096" | REFUSED, no segment matches |
| m6 | `M_logical` 8192 -> 8208 | FAIL "segments cover 8192, M_logical is 8208" | refuses everything: "the model shape and the packed tensors DISAGREE" |
| m7 | segment v `row_start` 4128 -> 4176, still tile-aligned | FAIL "the pad rule gives 4128" | REFUSED "window rows 4176..8271 runs past the packed M = 8224" |

**m7 was a SILENT PASS in `gen_layer_program` until this track added the
overrun check, and that is the most useful row in the table.** A tile-aligned
`row_start` that is simply wrong produced a perfectly well-formed descriptor
that the RTL ACCEPTS, whose bases point past the tensor's own sub-regions into
whatever the allocator placed next. Nothing downstream can see it: `row_start`
is not a descriptor field, it is folded into the 27 bases, and
`rtl_would_reject` bounds only `n_rows` against `MAXROWS_BFP`. This is the
program-level instance of OI-1 / `tb_matvec_fk33_desc` case 19, and the fix is
host-side because there is nowhere else for it to go.

**m3 and m4 are the resolution floor and are reported under their own names.**
m3 is silent in the generator because `row_start` is read from the manifest
directly, so a `pad_rows` that disagrees with the starts is internally
inconsistent but still names legal windows. m4 is silent in `check_mv4i_set`
because a set may legitimately carry no segments (the `--no-qkv-pad` set does),
so absence cannot be an error there; it is `gen_layer_program` that knows the
tensor is padded (`M != M_logical`) and refuses.

### 8.3 `ERR_SHAPE 0xF`, judged by the RTL (2 mutants, MEASURED)

The brief asks for this on a mis-aligned segment. **It cannot come from there,
and that is a finding rather than a failure to reproduce:** a mis-aligned
`row_start` is not visible to the gateware at all (section 8.2 m7). `ERR_SHAPE`
is the `w_beats`/`s_beats` check, and the beat count IS what a padding change
moves, so it is exercised on the k window's real descriptor:

```
clean w_beats=5504 s_beats=5504, extension word index 36

w_beats 5504 -> 2752  ->  RESULT reject: err_code 15 (0xF) err_info 36   PASS
w_beats 5504 -> 5505  ->  RESULT reject: err_code 15 (0xF) err_info 36   PASS
```

Both bite, on the exact code and `ERR_INFO` the format document specifies. The
generator computes 5504 / 5504 / 11008 for the three windows and the RTL accepts
all three, so the beat counts followed the shape.

Cosmetic note: `sim/tb_mv4i_desc_image.vhd:365` prints the code as
`"0x" & integer'image(verdict)`, so a decimal 15 appears as `0x15`. The code is
`0xF`. Not this track's file; recorded so the next reader is not misled.

### 8.4 A corrupted pad row (MEASURED)

All 32 pad rows of `blk.0` set to `idx = 15, scale = 32767` on every block:

```
  seg 0 mismatches 0    seg 1 mismatches 0    seg 2 mismatches 0
  rows  8192 real rows: 0 idx mismatches, 0 scale mismatches
  BFP seg 0  old ns=5 y_exp=5  new ns=5 y_exp=5  mantissa mismatches 0
  pad   32 pad rows: 135168 nonzero idx/scale entries   <- the ONLY thing that fires
```

**The non-pad result is bit-identical, which is the property this track needed
to establish.** 135,168 = 32 rows x (4,096 idx + 128 scale), so the corruption
landed; it is caught by the pad-emptiness check and by `--full`'s digest, and
by nothing numeric, correctly, because the hardware masks those rows too.

The complementary measurement is in section 2: extend the job's `n_rows` to
2,064 so the scan domain wrongly includes the pad, and the corrupted file moves
`ns` 5 -> 8 and `y_exp` 5 -> 2 while the clean file does not move at all. That
is the whole argument for zero fill in one pair of numbers.

---

## 9. Measured and REJECTED -- do not retry

* **Splitting `attn_qkv` into three tensors.** Rejected by Oren before this
  track: it changes the manifest's tensor count and naming and every tool that
  reads it. Not re-litigated.
* **`--qkv-fused`, one job over all 8,192 rows.** No repack at all, but it
  collapses three exponent segments into one and is a different 443-step
  program. Still available in `gen_layer_program.py`; it is a fallback, not a
  repair.
* **A `ROWS_IF` that divides 2048.** Impossible at this `AXI_DW`:
  `NPORTS_W*AXI_DW = ROWS_IF*BLK*4` pins `ROWS_IF = 48` at `AXI_DW = 256`.
  Already measured in D-PROG section 4.1; not re-derived.
* **Padding the LAST segment too.** Pointless: nothing follows v, and `pack()`
  already rounds the file to a whole tile. Padding it would cost another tile
  for no alignment gain.
* **Re-slicing the existing packed bytes instead of repacking from the GGUF.**
  Cheaper, and rejected: it makes the packer's own unpacker the authority for
  the new file's contents, which is the `m7 mutant` round-trip CLAUDE.md names.
  Repacking from the GGUF and comparing the two files with an INDEPENDENT
  reader (`ref/matvec_int4.c`) is the check that a re-slice could not provide.
* **Fixing the lm_head's 15 windows here.** Section 7. It is a schedule change
  with an undecided destination region and it would break D-PROG's byte
  identity against both VHDL generators.
* **Defaulting `--qkv-pad` OFF.** Considered so the historic command would
  reproduce the historic bytes. Rejected because the padded set is the one the
  FK33 needs; the escape is `--no-qkv-pad`, the manifest self-describes with
  `geometry.qkv_segment_pad`, and MEASURED, the OFF path reproduces the
  stackfix manifest exactly.

---

## 10. Measurement traps hit

* **The brief's own arithmetic is off by one segment.** "`v 4128..8207`" is
  4,080 rows and silently drops 16 rows of v. The end is 8,223 and
  `M_padded = 8224`. Anyone re-deriving this should check that the segment
  lengths still sum to the logical `M`, which is what `check_mv4i_set`'s cover
  test now does.
* **A `mv4i_result` initialiser with the fields in the wrong order segfaults
  silently.** `{y_data, y_acc, y_mant, ...}` -- putting the mantissa buffer in
  the `y_acc` slot leaves `y_mant` NULL and BFP mode writes through it. The
  crash lost the whole stdout buffer, so it looked like the tool had done
  nothing at all.
* **`--mutate 5` does NOT distinguish a clean pad from a corrupted one.** Both
  give 16 mismatches per segment, because both differ from the real rows that
  used to sit there. It was briefly used as the proof that the corruption had
  landed and it proves no such thing; the `pad ... nonzero` count does.
* **The manifest's `M` is now two different numbers depending on the question.**
  Sizes come from the PACKED `M`; the model's shape check must use
  `M_logical`. The first run after the repack failed with "qkv_dim shape says
  8192, manifest says 8224", which reads as a packing bug and is a checker
  reading the wrong field.
* **`os.replace(tmp, out)` over a symlink replaces the LINK, not the target.**
  That is what makes the symlink-farm build safe against writing into the
  hash-verified input set. Verified afterwards by re-hashing all 251 originals,
  not assumed.

---

## 11. What this does NOT establish

* **Nothing ran on hardware.** No `xsdb`, no `hw_server`, no programming, no
  `/dev/xdma*`. The judge for the descriptors is GHDL running
  `rtl/matvec_int4_desc_axi.vhd`.
* **No arithmetic claim about the LAYER.** This track proves the three qkv jobs
  are expressible, accepted and numerically equal to the unpadded rows. Whether
  subsystem B then consumes R_QKV correctly is worklog OI-3 and is untouched.
* **The three exponent SEGMENTS are preserved by construction, not measured.**
  `seq_opdec` infers the segment from `dst_offset`, and `dst_offset` is
  deliberately still the LOGICAL 0 / 2048 / 4096 -- the pad moves only
  `row_start`. Nothing here exercises `MSEG_OFF1`/`MSEG_OFF2`.
* **The `GRP > 1` scale path stays unexercised.** `GRP = 1` at this geometry, so
  `s_skip == w_skip` by arithmetic and mutant 3 of section 8.1 bites only
  because it perturbs a scale base directly. A defect in the `/ grp` divisor is
  invisible here, exactly as recorded for the lm_head windows.
* **The real-dimension layer was not EXECUTED.** Same reason as D-PROG: 4,096
  wide steps are the cost that keeps `seq_tbl_pkg`'s 491 descriptors unrun.
* **No `sim/`, `rtl/`, `tb/` or `hw/` file was touched**, so no gate row moved
  and no synthesis result can have changed. The gate was run anyway:
  **OVERALL PASS 82 / FAIL 0 / NOVERDICT 0 / TIMEOUT 0 / BUILD-ERROR 0,
  NOCHECK 5**, `REGRESSION: PASS`. Note the floor is **82**, not the 81 this
  track was briefed with: `sim/regress.sh` carries another track's UNCOMMITTED
  `BASELINE_PASS=82` plus a `tb_llama_top_seq` row, so the run measured against
  that in-flight state. That file was deliberately left unstaged.

## 12. Corrections

None yet. Append here with a date; mark superseded claims withdrawn in place.
