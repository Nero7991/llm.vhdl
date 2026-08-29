# The host-side descriptor generator for subsystem A (worklog OI-4)

**Date:** 2026-08-28
**Repo state:** branch `fpga`, HEAD `6f96bd6` at the time of the RTL runs, with
TRACK A-SHAPE's **uncommitted** edits present in `rtl/matvec_int4_desc_axi.vhd`
and `rtl/matvec_int4_desc_pkg.vhd`. That matters and is called out where it
changed a result.
**Hardware:** none. Nothing in this file touched an FK33.

---

## 1. The question

> Weights are on the card (250 tensors, 4.7099 GiB, hash-identical on silicon).
> The descriptor format is byte-pinned. The control plane is bit-exact in
> simulation. **Nothing emits a descriptor for a real tensor.** Build the
> generator, and verify it against something that is not itself.

---

## 2. The answer

`tools/gen_mv4i_desc.py` emits the 39-word / 312-byte descriptor for any of the
250 packed tensors at the FK33 geometry, with HBM bases taken from the
manifest's `hbm_offset` plus the file's own sub-region table.

It is verified three ways, none of which is a round trip through its own
decoder:

| check | oracle | result |
|---|---|---|
| field values | `ref/mv_fk33_tr` (C, via `ref/matvec_int4.c`'s `mv4i_parse`) | 8 of 8 field groups identical, including all 27 sub-region offsets, `w_beats`, `s_beats`, all 16 codebook entries |
| the 312 bytes | `tools/mv4i_desc_ref.c`, the spec's section 7 builder written out in C | 75 of 75 images byte-identical, over 25 tensors x {full job, PARTIAL mode, offset row window} |
| acceptance and refusal | `rtl/matvec_int4_desc_axi.vhd` itself, through the new `sim/tb_mv4i_desc_image.vhd` | clean image ACCEPTED; 21 of 26 mutations refused with the exact documented `err_code` and `ERR_INFO`; 5 accepted, all 5 named |
| the whole arithmetic | `sim/tb_matvec_fk33_desc.vhd` at `a4f7e17`, with the generator's fields substituted into its trace | CASE 0 **100 elements bit-exact on the core bus and 100 rows bit-exact through AXI-Lite**, `y_exp = 6`; all 22 cases as expected |

**Three fields cannot be derived from the manifest plus the `.mv4i` header and
are arguments, not derivations:** `x_exp`, `n_rows` (and the row window), and
`out_mode`. D's routing fields (`src_region`, `dst_region`, `dst_offset`,
`ordinal`, `src_region2`, `const_base`, `const_exp`) are also underivable;
subsystem A reads none of them, so they are written to spec section 7's
conventional values and are a **finding**, not a computation.

---

## 3. The procedure, in the order it was run, and what each step isolates

1. **Read the format spec, `rtl/matvec_int4_desc_pkg.vhd`, `ref/matvec_int4.c`
   and `ref/mv_fk33_tr.c` before writing anything.** The package, not the
   document, is the source of the word offsets: the gateware and the existing
   bench both compute from it, and a generator that agreed with a wrong
   document would agree just as happily.
2. **Parse one real header and reconcile it with the manifest by hand** to
   establish what is actually present (section 4 below). This is what showed
   that every field except three is derivable.
3. **Compute the bases twice, by rules that share no code**, and refuse to emit
   anything if they disagree. Rule 1 is the file's own offset table at 0x38;
   rule 2 is spec 6.5a's layout (4 KB header, then `nsub_w` weight sub-regions
   of `ceil(M/ROWS_IF)*ceil(K/BLOCK)*(AXI_DW/8)` bytes, then `nsub_s` scale
   sub-regions of the same size). Rule 2 pins the **order**, which rule 1 alone
   cannot: a permuted offset table satisfies every structural property of the
   file. This is the highest-risk part of the tool, because worklog OI-3's
   family says a well-formed base aimed at the wrong sub-region computes wrong
   data and reports success.
4. **Audit all 250 tensors** with the same parser, checking the two rules, the
   4 KB alignment every base needs, and `ADDR_W = 40`. Controls for "it works
   on the one tensor I looked at".
5. **Cross-check the fields against `ref/mv_fk33_tr`.** Different language,
   different header parser, its own `w_beats`/`s_beats` arithmetic. This is the
   check that would catch a wrong beat identity or a misread offset.
6. **Byte-compare against a separate implementation of the spec's section 7
   builder.** Isolates the *encoding* -- bit positions, endianness, the pads --
   which step 5 cannot see because it compares values, not bytes.
7. **Let the RTL judge the actual bytes.** `sim/tb_mv4i_desc_image.vhd` reads
   the image `gen_mv4i_desc.py --hex` writes and reports whether S_CHECK
   accepted it or which `err_code`/`ERR_INFO` it refused it with. This is the
   only step that can catch the generator and both C paths being wrong the same
   way about the *layout* (e.g. landing the extension at the wrong word).
8. **Mutate one field at a time and re-ask the RTL.** 26 image mutations plus 2
   pointer mutations. The rows the RTL is expected NOT to see are declared as
   such and fail the run if they are silently detected or silently missed the
   other way.
9. **Substitute the generator's fields into the arithmetic bench's trace.**
   `sim/tb_matvec_fk33_desc.vhd` builds its descriptor from the trace's
   `GEOM`/`DIMS`/`CB`/`WSUB`/`SSUB`/`WBEATS`/`SBEATS` lines; rewriting exactly
   those from the generator makes the bench build *these* field values and then
   prove the answer bit-exact against `ref/matvec_int4.c`. The lines it does
   not touch (`X`, `IMG`, `YMANT`, `YEXP`, `SATEV`) stay `mv_fk33_tr`'s, so the
   expected answer is not derived from anything under test.

---

## 4. Where every descriptor field comes from

`blk.11.attn_k.weight.mv4i`, `M = 1024`, `K = 4096`, packed at
`ROWS_IF = 48 / AXI_DW = 256`, `hbm_offset = 4438286336`.

| descriptor field | source | derivable? |
|---|---|---|
| `opcode` | constant `OP_A_JOB = 0` | yes |
| `flags` bit 2 `cb_load` | schedule decision | **NO** |
| `src_region`, `dst_region`, `dst_offset` | D's routing | **NO**, and A ignores them |
| `n_rows` | job shape | **NO** |
| `n_cols` | header `K` | yes |
| `w_exp` | header `0x10` | yes |
| `out_shift` | header `0x14` | yes |
| `out_mode` | schedule decision | **NO** |
| `ordinal`, `src_region2` | D's | **NO**, and A ignores them |
| `const_base`, `const_exp` | D's | **NO**, and A ignores them |
| codebook (16 bytes) | header `0x20..0x2F` | yes, it travels in the file |
| `nsub_w` | header `nports_w` | yes |
| `nsub_s` | header `n_scale_sub` | yes |
| `w_base[0..23]` | `hbm_offset` + header `0x38+8p` | yes, and cross-checked by rule 2 |
| `s_base[0..2]` | `hbm_offset` + header `0x38+8*npw+8q` | yes, same |
| `ext_magic`, `ext_version` | constants | yes |
| `w_beats` | `ceil(n_rows/ROWS_IF) * ceil(K/BLOCK)` | yes, given `n_rows` |
| `s_beats` | `ceil(w_beats / GRP)` | yes, given `n_rows` |
| `x_exp` | previous stage, per token | **NO** |

**The two beat identities, stated because the RTL does not check them** (at
`a4f7e17`; see the correction in section 7):

```
tiles    = ceil(n_rows / ROWS_IF)
w_beats  = tiles * nb          where nb = ceil(K / BLOCK) is the FILE's
s_beats  = ceil(w_beats / GRP) where GRP = n_scale_sub*AXI_DW / (ROWS_IF*16)
```

`nb` is the FILE's, not `ceil(n_cols/BLOCK)`: the block stride inside a
sub-region is fixed by the file, which is why **column subsetting is not
available at all** and `n_cols` is always `K`. Row subsetting is: a job of
`n_rows` rows is a contiguous prefix of every sub-region.

Verbatim, at `n_rows = 100`:

```
tensor        blk.11.attn_k.weight.mv4i
shape         M=1024 K=4096  job n_rows=100 n_cols=4096
geometry      ROWS_IF=48 AXI_DW=256 BLOCK=32 GRP=1 nb=128 tiles=3
sub-regions   nsub_w=24 nsub_s=3
beats         w_beats=384 s_beats=384
numeric       w_exp=8 out_shift=3 x_exp=5 out_mode=0 cb_load=1
hbm_base      0x1088AE000
w_base[0..2]  0x1088AF000 0x1088C5000 0x1088DB000
s_base        0x108ABF000 0x108AD5000 0x108AEB000
descriptor    39 words, 312 bytes, ext at word 35
note          bases agree by two independent rules; regions tile the file exactly (2437120 bytes)
```

---

## 5. The evidence

### 5.1 All 250 tensors (MEASURED)

```
$ tools/gen_mv4i_desc.py --audit
manifest geometry {'rows_if': 48, 'axi_dw': 256, 'block': 32, 'nports_w': 24,
                   'n_scale_sub': 3, 'axi_read_masters': 27}
tensors parsed        250 (0 refused)
bases not 4 KB aligned 0
bases outside ADDR_W=40  0
largest full-tensor w_beats  662272
```

Every one of the 250 satisfies both offset rules, and all 6750 bases
(250 x 27) are 4 KB aligned and inside `ADDR_W = 40`.

### 5.2 Fields against `ref/mv_fk33_tr` (MEASURED)

```
== --cross: field values vs ref/mv_fk33_tr (C, ref/matvec_int4.c parse) ==
PASS geometry           RI=48 NPW=24 NPS=3 DW=256 BLK=32 GRP=1
PASS shape              n_rows=100 n_cols=4096 nb=128
PASS numeric            out_shift=3 w_exp=8 x_exp=5
PASS codebook, all 16 entries
PASS weight sub-region offsets   24 of them
PASS scale sub-region offsets     3 of them
PASS w_beats            384
PASS s_beats            384
```

### 5.3 Bytes against the section 7 builder in C (MEASURED)

```
== --bytes: 312-byte image vs tools/mv4i_desc_ref.c (spec s7, in C) ==
PASS 75 images byte-identical to the C builder          (default, 25 tensors)
PASS 702 images byte-identical to the C builder         (--sweep 0, all 250)
```

Up to three jobs per tensor: the full tensor in BFP mode, a one-tile job in
PARTIAL mode with a **negative** `x_exp` (which is what exercises the
two's-complement packing of `w_exp`/`out_shift`/`x_exp`), and a one-tile job in
RAW mode at a row window that is not row 0.

### 5.4 The RTL as judge, on the generator's actual bytes (MEASURED)

`sim/tb_mv4i_desc_image.vhd`, working tree of 2026-08-28
(HEAD `6f96bd6` **plus** TRACK A-SHAPE's uncommitted edits):

```
PASS  0 clean                                  RTL: accept
PASS  1 ext_magic off by one                   RTL: 0xA info 35
PASS  2 ext_version = 2                        RTL: 0xB info 35
PASS  3 ext_flags nonzero                      RTL: 0x3 info 35
PASS  4 nsub_w = 23 (build has 24)             RTL: 0x9 info 3
PASS  5 nsub_s = 2 (build has 3)               RTL: 0x9 info 3
PASS  6 opcode = 4 (not OP_A_JOB)              RTL: 0x3 info 0
PASS  7 word 3 pad byte nonzero                RTL: 0x3 info 3
PASS  8 word 7 (D reserved) nonzero            RTL: 0x3 info 7
PASS  9 ext word 2 pad half nonzero            RTL: 0x3 info 37
PASS 10 ext word 3 nonzero                     RTL: 0x3 info 37
PASS 11 out_mode = 3                           RTL: 0x3 info 3
PASS 12 n_rows = 0                             RTL: 0x3 info 1
PASS 13 n_rows = MAXROWS_BFP+1                 RTL: 0x3 info 1
PASS 14 n_cols = MAXCOLS+1                     RTL: 0x3 info 1
PASS 15 w_beats = 0                            RTL: 0x3 info 36
PASS 16 s_beats = 0                            RTL: 0x3 info 36
PASS 17 w_base[7] misaligned by 64 B           RTL: 0xC info 15
PASS 18 s_base[1] bit at ADDR_W                RTL: 0xD info 33
PASS 19 cb_load clear, none ever loaded        RTL: 0x3 info 0
PASS 20 w_base[7] aims at sub-region 8         RTL: accept    <- SILENT
PASS 21 w_beats halved                         RTL: 0xF info 36  [see 7.1]
PASS 22 codebook byte 3 changed                RTL: accept    <- SILENT
PASS 23 x_exp off by one                       RTL: accept    <- SILENT
PASS 24 w_exp off by one                       RTL: accept    <- SILENT
PASS 25 every base +4096 (wrong hbm_offset)    RTL: accept    <- SILENT
PASS  P DESC_PTR misaligned by 8 B             RTL: 0xC info 65535
PASS  P DESC_PTR_HI bit at ADDR_W              RTL: 0xD info 65535
```

`ERR_INFO` is the descriptor word index: 35 is the extension's first word
(`EXT0 = 8 + 24 + 3`), 36 the beat-count word, 37 the `x_exp` word, 15 is
`w_base[7]`, 33 is `s_base[1]`, 65535 is the pointer sentinel.

### 5.5 The arithmetic bench, driven by the generator's fields (MEASURED)

`sim/tb_matvec_fk33_desc.vhd` builds its descriptor from the trace's
`GEOM`/`DIMS`/`CB`/`WSUB`/`SSUB`/`WBEATS`/`SBEATS` lines. `--gate` rewrites
exactly those 47 lines from `gen_mv4i_desc.py` and leaves the rest
(`X`, `IMG`, `YMANT`, `YEXP`, `SATEV`) as `ref/mv_fk33_tr` wrote them, so the
expected answer is not derived from anything under test. Run against the RTL
and the bench **as committed at `a4f7e17`**:

```
CASE  0 clean descriptor   OK -- 100 elements bit-exact on the core bus,
                                 100 rows bit-exact through AXI-Lite, y_exp=6
...
subsystem A is bit-exact with ref/matvec_int4.c through the descriptor control
plane, and every checked mutation is refused
```

That is the strongest single result here: the whole 22-case gate passes with
the generator's field values substituted in, so the bit-exactness claim is a
claim about **these** `w_beats`, `s_beats`, sub-region offsets, codebook,
`n_rows`, `n_cols`, `w_exp`, `out_shift` and `x_exp`.

The 47 substituted lines were also byte-identical to `mv_fk33_tr`'s own, which
is the same statement section 5.2 makes field by field.

---

## 6. The silent passes, named

Five mutations the gateware accepts. All five are correctness defects that
report success, and none of them is a defect in this generator -- they are the
boundary of what a descriptor can be checked against.

| mutation | why it is invisible | evidence it is wrong |
|---|---|---|
| `w_base[7]` aims at sub-region 8 | nothing in the descriptor says what a sub-region should CONTAIN | `tb_matvec_fk33_desc` case 19 MEASURED 4 of 100 elements wrong (worklog OI-1) |
| every base `+4096` (a wrong `hbm_offset`) | still 4 KB aligned, still inside `ADDR_W` | same family; only the weight store's own hash can see it |
| codebook byte changed | the descriptor's codebook is not bound to the file's | the codebook is the dequantisation table; every product changes |
| `x_exp` off by one | `x_exp` is a free runtime value, so every value is legal | MEASURED: `mv_fk33_tr` at `x_exp` 5 vs 6 gives `YEXP` 6 vs 7 with **identical mantissas**, i.e. every result doubled |
| `w_exp` off by one | same | same term of `ref/matvec_int4.c:426` (`y_exp = w_exp + x_exp - out_shift - ns`), so the same doubling |

The first two are OI-3's family and the mitigation already exists: the manifest
carries a `blake2b_128` per file and the load path verified them on silicon.
`gen_mv4i_desc.py` therefore **re-checks the on-disk file against that hash
before emitting**, so a descriptor cannot be written for a file that is not the
file the manifest says was loaded. That closes the "the file changed under me"
path; it does not close "the DMA landed somewhere else", which needs a read-back
hash and is not host-tool work.

---

### 6.1 The generator's OWN two teeth, both MEASURED

Two of the five silent passes above are things the *generator* can be made to
refuse even though the gateware cannot. Both were teeth-checked by breaking
them:

**A permuted offset table.** `w_sub_offset[7]` and `[8]` swapped in a copy of
`blk.11.attn_k.weight.mv4i` -- structurally perfect, still 4 KB aligned, still
tiles the file -- and the generator refuses:

```
gen_mv4i_desc: .../mut.mv4i: the file's offset table and spec 6.5a's layout DISAGREE.
  header w=[..., 544768, 724992, 634880, 815104, ...]
  layout w=[..., 544768, 634880, 724992, 815104, ...]
Nothing is emitted: a base is the one field whose corruption the gateware cannot see.
```

That is `tb_matvec_fk33_desc` case 19's defect class caught at the host, before
a descriptor exists. It cannot catch a base that is wrong for a reason the FILE
does not know about (a DMA that landed elsewhere).

**A file that is not the file that was loaded.** One weight byte flipped at
offset 4219:

```
gen_mv4i_desc: .../blk.11.attn_k.weight.mv4i: blake2b_128 is 7dbeebaf96b44db2800d36185aef43c6,
manifest says e21ef237a77081a93e4457f93808b317 -- the file on disk is NOT the file
that was loaded, so its sub-region offsets describe different bytes
```

**And one refusal that is not a corruption at all:** the two 248320-row
tensors, described as a single job, are refused before emission with the code
the gateware would have used --

```
$ tools/gen_mv4i_desc.py --mv4i .../output.weight.mv4i --x-exp 5
the FK33 build would REJECT this descriptor:
  err_code 0x3  ERR_DESC: shape
```

-- because `MAXROWS_BFP` is 17408. `--row-start` is how those two are
expressed as 15 jobs each.

---

## 7. Measured and REJECTED / corrected

### 7.1 CORRECTION -- "w_beats halved is undetectable" is already out of date

The mutation table was written from the committed spec, which says
(section 5.1) that a `w_beats` inconsistent with the shape is not checked.
**MEASURED both ways on the same bytes:**

* against `a4f7e17`'s RTL, extracted with `git show` into a separate GHDL
  library: `RESULT accept: S_CHECK passed and the core started` at 885 ns.
* against the working tree of 2026-08-28, which carries TRACK A-SHAPE's
  uncommitted `EC_SHAPE = 0xF` (`rtl/matvec_int4_desc_pkg.vhd:57`,
  `rtl/matvec_int4_desc_axi.vhd:753`): `RESULT reject: err_code 0xF err_info 36`.

So A-SHAPE's check is live and it bites, confirmed from a completely different
stimulus path than its own bench -- a host-generated byte image rather than a
descriptor built in VHDL. `0xF` is **not in the spec document's error table**
(section 5 lists `0x0`, `0x3`, `0x4`, `0x9..0xE`); the document needs the row
when that work lands. The clean descriptor is accepted by both RTLs.

**Do not retry** "w_beats halved is a silent pass" against the working tree.
It is a silent pass only at `a4f7e17` and earlier.

### 7.1b OBSERVATION, not a claim: the same run crashes on the working tree

The identical `--gate` run against the **working tree** of 2026-08-28 (TRACK
A-SHAPE's uncommitted RTL *and* its uncommitted `sim/tb_matvec_fk33_desc.vhd`,
which adds a "shape sweep" section after the 22-case table) reached
`CASE 0 ... OK` and every case verdict, then died:

```
/usr/bin/ghdl-mcode:error: bound check failure at rtl/axi_rd_fsm.vhd:189
in process .tb_matvec_fk33_desc(sim).dut@matvec_int4_desc_axi(rtl)
           .dfetch@axi_rd_port(rtl).g_sc.fsm@axi_rd_fsm(rtl).P5
```

`rtl/axi_rd_fsm.vhd` is **not** among the modified files, so this is the new
shape sweep reaching an existing bound in the DESCRIPTOR fetch port. It is
recorded here and nowhere else because it belongs to a track that was mid-edit
while this ran: a file being edited under a reader is not evidence about that
file's finished state. The a4f7e17 run of the same trace does not reach it,
because that revision has no shape sweep.

### 7.2 Rejected: extending `hw/mv_driver.c` to cover the FK33

That file's own header refuses it, and correctly: `matvec_int4_axi` asserts
`NPORTS_W = 4 / NPORTS_S = 1` at elaboration. The two control planes are
different maps, not one map with options. Only its stale "the generator does
not exist yet" sentence was corrected.

### 7.3 Rejected: making `sim/tb_matvec_fk33_desc.vhd` read a descriptor file

It is owned by another track and is explicitly not to be edited, and it does not
need to be: its descriptor is built entirely from trace fields, so rewriting the
trace's descriptor-bearing lines substitutes the generator's values without
touching a line of the bench. That is section 3 step 9.

### 7.4 Rejected: a Python re-implementation of the RTL's checks as the judge

`gen_mv4i_desc.py:rtl_would_reject()` predicts what the gateware will refuse, so
the tool can decline to emit something the card will reject. It is a
**prediction, not the judge** and is labelled as such in the source. Treating it
as verification would be exactly the m7 mutant failure: a checker written from
the same reading as the thing it checks.

---

## 8. Measurement traps hit

* **The RTL under test was not HEAD.** The first teeth run reported an
  unexpected `err_code 0xF` and read as a generator defect. It was another
  track's uncommitted work in the same working tree. `verify_mv4i_desc.py`
  now prints `git status --porcelain` over its own RTL closure before the
  table, because a mutation table read without knowing which RTL answered it
  can be argued either way.
* **`ghdl -r` on the mcode backend is the only exit code worth reading.** No
  `-e` was used anywhere here.
* **A bench that never answers the weight masters looks like a hang.** That is
  deliberate in `tb_mv4i_desc_image`: the accept signal is the FIRST
  `m_arvalid`, which can only rise after S_CHECK passed and `start` was pulsed.
  Nothing about the arithmetic is claimed there; that stays
  `tb_matvec_fk33_desc`'s claim.
* **`--audit` reads 250 headers in 57 ms** because it reads only the first
  4 KB of each. Do not "improve" it into hashing every file by default; the
  hash check is per-descriptor and opt-out for that reason.

---

## 9. Open, not determined here

* **`sim/tb_mv4i_desc_image.vhd` is NOT in `sim/regress.sh`.** It was
  deliberately not added: `regress.sh` is shared, TRACK A-SHAPE was running
  concurrently, and `BASELINE_PASS` would have had to move under it. The row
  and the floor bump belong to whoever lands next. Until then the bench rots
  unless run by hand.
* **Nothing verifies that the bytes at `hbm_offset` on the CARD are this
  file's bytes.** The manifest's `blake2b_128` was verified at load time and is
  re-verified against the on-disk file here, but no read-back was performed
  (no hardware in this session).
* **The two 248320-row tensors (`output.weight`, `token_embd.weight`) need 15
  jobs each** at `MAXROWS_BFP = 17408`. `--row-start` expresses the window as a
  base offset (whole tiles, `nb*port_b = 4096` bytes per tile, so alignment
  survives) and the C builder agrees byte for byte, but **no row-windowed job
  has been run through the arithmetic bench**: `mv_fk33_tr` has no row-offset
  argument, so there is no expected answer to compare against. The window
  arithmetic is DERIVED, not MEASURED.
* **`out_mode` 1 and 2 descriptors are byte-checked but not run.** The RTL run
  used BFP only.
* **`x_exp` remains a hole by design.** `USE_XEXP_PORT` exists precisely
  because the descriptor's copy is stale in the integrated system, and which
  one the FK33 build uses is an integration decision nobody has taken.
* `i_wbeats <= to_integer(signed(w_beats))` in `rtl/matvec_int4.vhd:199` reads
  the field as **signed**, so a `w_beats` at or above 2^31 would be negative.
  The largest real value is 662272, so this is unreachable today; recorded
  because the field is documented as u32.

---

## 10. How to run it

```sh
# one descriptor
tools/gen_mv4i_desc.py --mv4i /mnt/storage/llama-models/qwen35-9b-mv4i/blk.11.attn_k.weight.mv4i \
    --rows 100 --x-exp 5 --hex desc.hex --bin desc.bin --json desc.json --print

# every tensor's constraints
tools/gen_mv4i_desc.py --audit

# all four verifications (the last two need ghdl and take minutes)
tools/verify_mv4i_desc.py --all

# just the RTL teeth
tools/verify_mv4i_desc.py --rtl --teeth
```
