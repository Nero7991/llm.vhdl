# The host embedding gather: a real provider, a base-address collision, and which copy of the embedding

**Date:** 2026-08-29
**Track:** HOSTEMB
**Tree:** `fk33` branch. Five other tracks were live; only `server/**` and two
new files under `tools/` were touched, and `server/**` was this track's
exclusively.
**Tools that ran:** `gcc` 11 (`-O2 -std=c99 -Wall -Wextra`), `g++`,
`python3` + `numpy`, `make` (`server/Makefile` targets `check`, `test`,
`embed-check`, `llama_server`), `tools/check_embed_c.py`,
`tools/embed_gather.py`.
**No hardware was touched.** Nothing here ran against the FK33. No
`/dev/xdma*`, `xsdb`, `hw_server`, `vivado ... program` or `hw/fk33/*.sh`
invocation appears anywhere in this work, and the only card in the loop is
`server/fk33_sim.c`.

---

## 1. The question, verbatim

> Oren decided the host owns the embedding gather, and TRACK EMBDROP has just
> repacked without `token_embd.weight` (`46216b3`). [...] It left three gaps,
> and they are your task.
>
> **PART 1: a real embedding provider.** `pl_embed_fn` already has the right
> signature [...] But the only implementations are `pl_embed_synthetic` and
> NULL-is-an-error. The recipe exists in Python: `tools/embed_gather.py
> --recipe wide`, two contiguous 4 KB reads per token. **Port it to C.** [...]
> **Verify it against something you did not write.** [...] Find an external
> check, or say precisely why none is available.
>
> **PART 2: a latent defect EMBDROP found, reported not fixed.** [...] the
> host's default scratch bases point into the weights. **Fix it, and do not
> simply pick a bigger constant** -- derive the bases from the manifest, or
> refuse at open time when they overlap the image, or both. [...] Also stale
> and cheap: `server/pl_backend.h` carries "5,056,995,328 bytes", which no
> longer matches any set.
>
> **PART 3: a decision that appeared with the drop.** **Nobody decides which
> copy of the embedding the host holds.** [...] the packed
> `token_embd.weight.mv4i`, **572,207,104 B** [...] or the source GGUF,
> **2,034,237,440 B** of BF16 [...] **These are not equivalent numerically**
> and that is the crux: the card's arithmetic was verified against INT4
> weights. Work out which one produces the activation the rest of the pipeline
> was verified against, say so with evidence, and implement that.

---

## 2. The answers, up front

**PART 1. `server/embed_mv4i.c` is the provider**, a third independent
implementation of spec 6.5a's row layout that reads a row as TWO CONTIGUOUS
`pread`s and BFP-packs it. It is **bit-identical over 998 corner-forced tokens**
to three things this track did not write: `ref/matvec_int4.c`'s
`get_widx`/`get_scale` as used by `ref/run9b.c`'s own `embed()` + `reg_put()`;
`tools/embed_gather.py`'s `direct` decoder; and its `reassemble` decoder, which
rebuilds the whole tile word from all 24 weight sub-regions and shares no
addressing arithmetic with anything else. Against the BF16 GGUF -- the one
oracle that never touches the packed file -- worst relative error **0.12667**,
worst correlation **0.99200**, zero rows outside the gate. **Twelve of twelve
named C mutants are killed**, and the four checks are each recorded with what
they can and cannot see.

**PART 2. Fixed by derivation AND by refusal, and the fix is shown firing.**
`x_base` / `l_base` / `desc_ptr` default to **0, meaning derive**;
`pl_derive_bases()` allocates them top-down from the top of HBM out of
`n_embd`, `n_vocab`, `max_chunk` and `hbm.size` alone. `server/fk33_manifest.c`
reads the loaded set's `manifest.json` and `pl_open()` refuses any base -- given
or derived -- that lands below `reserved_end`. MEASURED against the post-drop
set: the derivation yields `x 0x1FFB04000 / l 0x1FFF0C000 / desc 0x1FFFFF000`,
and the three constants that shipped are refused by name. The stale
"5,056,995,328 bytes" comment is gone, replaced by a read of the manifest.

**PART 3. The host holds the PACKED INT4 copy**, `token_embd.weight.mv4i`,
572,207,104 B. The deciding evidence is `ref/run9b.c`'s `embed()`:

```c
static void embed(int tok, reg_t *RX)
{
    mvw_t *m = mv("token_embd.weight");            /* from the PACKED set */
    for (int k = 0; k < HIDDEN; k++) t[k] = w_deq(&m->f, tok, k);
    reg_put(RX, t);
}
```

`run9b` is the whole-model 9B reference, and every number that makes a first
token falsifiable -- 0.1252 relative RMS at the logits for the INT4 weight
format, 0.00313 more for the int16 BFP activation format, all three rungs
picking the same next token id at all five reference positions -- was MEASURED
with that INT4 embedding in place.

**And the INT4 copy is emphatically NOT the more accurate one.** MEASURED over
48 corner-forced rows against the BF16 GGUF: the packed path is 0.086295 mean
relative error at the activation, a GGUF-fed path would be 0.000048, a factor of
**1,803**. The INT4 copy is the *verified* copy, not the *accurate* one, and
section 5 states exactly what the GGUF choice would have changed.

**A correction to the brief's own number**, DERIVED and MEASURED: the per-token
host-to-card transfer is **8,256 B, not 8,208**. 8,208 is the payload
(16 B header + 4,096 x 2 B); `fk33_x_stride()` rounds it up to the 64-byte block
alignment, `round_up(8208, 64) = 8256`. MEASURED: 5 tokens moved 41,280 B
(`5 x 8256`).

---

## 3. The procedure, in the order it was run

Each step says what it controls for, because most of them exist only to rule out
one specific way of being fooled.

1. **Read `ref/run9b.c` before writing any C.** Controls for the deepest
   version of this task's failure mode: writing a provider that is internally
   consistent and feeds the card an activation no reference ever evaluated.
   This step is what settled PART 3, and it settled it before PART 1 was
   written rather than after.
2. **Establish that `ref/run9b.c`'s `embed()` + `reg_put()` IS the `wide`
   recipe**, by algebra rather than by assertion (section 6.1). Controls for
   implementing the spec-D-3.2-as-written recipe and then "verifying" it
   against a Python file that also implements it.
3. **Write the provider as a genuinely different shape** -- two contiguous
   reads, `pread` not `mmap`, no numpy, no per-element addressing. Controls for
   the `m7` mutant: a decoder that shares arithmetic with its checker agrees
   with it for free.
4. **Reproduce, before comparing anything, the ONE published addressing
   example.** `docs/2026-08-28_token-io-path.md` section 2.1 records token
   12,345 as `tile=257 row_in_tile=9 w_sub=4 half=1 s_sub=0 s_idx=9`, weight
   read `0x51DA000`, scale read `0x1E612000`. Controls for a build that
   compiles and computes something plausible.
5. **Build the ref oracle by INCLUDING `ref/matvec_int4.c`**, exactly as
   `ref/run9b.c` does, and edit nothing in `ref/`. Controls for a
   re-implementation of the oracle drifting from the oracle.
6. **Compare bit-exact at TWO levels** -- the pre-pack integer row and the
   packed mantissas plus exponent. Controls for a pack defect and an addressing
   defect cancelling in the final row, and it is what separates the two when
   one fires.
7. **Run the corner-forced token set, not a random one.** `sample_tokens()`
   forces row 0, row `M-1`, the rows either side of every tile / beat-half /
   scale-sub-region boundary, and the first row of the PARTIAL last tile.
   Controls for coverage of the input space being mistaken for coverage of the
   output space. Token 248,319 is a real case and it is in the set.
8. **Run the mutation table**, twelve named C defects plus a clean control,
   and record the ones
   that a given check does NOT see. Controls for a checker never shown to
   fail.
9. **Teeth-check the refusals separately from the mutants**: an out-of-range
   token, an `n_embd` that does not match `K`, and a mutant selected in a build
   without `-DEMBED_MV4I_MUTANTS`. Controls for a refusal that is a comment.
10. **Only then PART 2.** Read both manifests with the new C reader and compare
    every field against EMBDROP's independently-obtained numbers. Controls for a
    hand-rolled JSON scanner that parses and lies.
11. **Show the fix firing on the real artefact**: the three shipped constants,
    offered to `pl_open()` with the post-drop manifest, must be refused; and the
    SAME manifest with the bases left at zero must open. Controls for a refusal
    that refuses everything.
12. **Show the refusal is NOT a new constant**: the same three constants with
    NO manifest must still OPEN, with a printed note saying the image check did
    not run. Controls for having replaced a wrong hardcoded address with a right
    one.
13. **Re-run the whole existing gate**: `make check`, `make test`
    (84 checks), `make llama_server`. Controls for the derivation breaking the
    tests that pinned the old constants.

---

## 4. The evidence, as captured output

### 4.1 The published addressing example, reproduced by the new C

```
$ embed_dump --mv4i .../token_embd.weight.mv4i --tokens 12345
INFO mv4i .../token_embd.weight.mv4i M=248320 K=4096 ROWS_IF=48 AXI_DW=256 BLOCK=32 nports_w=24 n_scale_sub=3 nb=128 tiles=5174 w_exp=8 recipe=wide read=4096B x2
SHAPE M 248320 K 4096
TOK 12345 EXP 19 VALEXP 23 AMAX 479685 ADDR 257 9 4 1 0 9 85827584 509681664 4096
MANT 20841 -11988 -4058 -15308 -6455 2398 184 -1844 7009 ...
BYTES 16384 GATHERS 2
```

`85827584 = 0x51DA000` and `509681664 = 0x1E612000`, and `ADDR 257 9 4 1 0 9` is
`tile=257 row_in_tile=9 w_sub=4 half=1 s_sub=0 s_idx=9`. Both match
`docs/2026-08-28_token-io-path.md` section 2.1 exactly.

### 4.2 The same token, out of `ref/matvec_int4.c`'s accessors

```
$ embed_ref_oracle --mv4i .../token_embd.weight.mv4i --tokens 12345
SHAPE M 248320 K 4096
TOK 12345 EXP 19
MANT 20841 -11988 -4058 -15308 -6455 2398 184 -1844 7009 ...
```

### 4.3 The full check, 998 corner-forced tokens

```
$ tools/check_embed_c.py --mv4i .../token_embd.weight.mv4i --n 1000 \
      --dump ./embed_dump --ref-oracle ./embed_ref_oracle
mv4i     /mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i
geometry M=248320 K=4096 ROWS_IF=48 AXI_DW=256 nb=128 w_exp=8 GRP=1
tokens   998, corner-forced
oracles  ref/matvec_int4=yes  embed_gather=yes  gguf=yes
recipe   wide

tokens compared                     998
vs ref/matvec_int4 (run9b embed)    0 exp, 0 mant mismatches
vs embed_gather direct              0 exp, 0 mant mismatches
vs embed_gather reassemble          0 exp, 0 mant mismatches
vs embed_gather pre-pack integers   0 mismatches
reported addressing disagreements   0
checked against the BF16 GGUF       998 (0 zero rows skipped)
worst relative error                0.12667
worst correlation                   0.99200
rows the GGUF gate rejects          0
CHECK PASS

real  0m12.973s
```

`0.12667` is the same worst relative error `tools/embed_gather.py --selftest
--n 1000` records for this tensor, arrived at through a different
implementation.

### 4.4 The mutation table, `--n 64`

```
mutation table -- a row is KILLED if some check refuses it
mutant                                       verdict  what fired
c0 clean (control)                           PASS     must PASS or the table means nothing
c1 nibble order swapped                      KILLED   ref/matvec_int4 0 exp + 64 mant of 64, embed_gather direct 0 exp + 64 mant, embed_gather reassemble 0 exp + 64 mant, pre-pack integer row 64, gguf 64/64 worst relerr 1.447 corr -0.055
c2 wrong half of the beat                    KILLED   ref/matvec_int4 1 exp + 63 mant of 64, ..., reported addressing 64, gguf 64/64 worst relerr 1.474 corr -0.009
c3 weight sub-region + 1                     KILLED   ref/matvec_int4 3 exp + 54 mant of 64, ..., reported addressing 57, gguf 57/64 worst relerr 2.573 corr -0.021
c4 tile + 1                                  KILLED   ref/matvec_int4 17 exp + 44 mant of 64, ..., reported addressing 61, gguf 60/63 worst relerr 1.965 corr -0.021
c5 scale sub-region + 1                      KILLED   ref/matvec_int4 13 exp + 29 mant of 64, ..., reported addressing 42, gguf 14/61 worst relerr 1.375 corr 0.435
c6 scale index within beat + 1               KILLED   ref/matvec_int4 16 exp + 48 mant of 64, ..., reported addressing 64, gguf 25/64 worst relerr 1.282 corr 0.524
c7 beats read block-major not tile-major     KILLED   ref/matvec_int4 3 exp + 61 mant of 64, ..., gguf 64/64 worst relerr 2.815 corr -0.060
c8 codebook reversed                         KILLED   ref/matvec_int4 4 exp + 60 mant of 64, ..., gguf 64/64 worst relerr 2.051 corr -0.996
c9 BFP headroom TARGET_MSB 14 -> 13          KILLED   ref/matvec_int4 64 exp + 0 mant of 64, embed_gather direct 64 exp + 0 mant, embed_gather reassemble 64 exp + 0 mant
c10 BFP pack truncates instead of rounding   KILLED   ref/matvec_int4 0 exp + 64 mant of 64, embed_gather direct 0 exp + 64 mant, embed_gather reassemble 0 exp + 64 mant
c11 x_exp returned with the wrong sign       KILLED   ref/matvec_int4 64 exp + 0 mant of 64, ..., gguf 64/64 worst relerr 4371691583101.121 corr 0.992
c12 scales read big-endian                   KILLED   ref/matvec_int4 64 exp + 0 mant of 64, ..., pre-pack integer row 64, gguf 64/64 worst relerr 83.880 corr 0.360
killed 12 of 12
```

**Checks that do NOT bite, named** -- this is the part of the table worth
re-reading:

| the check | what it CANNOT see | evidence |
|---|---|---|
| the BF16 GGUF gate | **c9 and c10 entirely.** A BFP headroom change and a rounding-mode change move the row by at most half an LSB of a 4.5-bit pack; the GGUF's own 0.086 quantization floor is three orders of magnitude coarser. | c9, c10 rows show no `gguf` term |
| the GGUF's CORRELATION half | **c11.** Correlation is scale-invariant, so negating the exponent leaves `corr 0.992`, indistinguishable from a clean row. Only the relative-error half fires, and it fires at 4.4e12. | c11 row |
| the reported-addressing check | **c1, c7, c8, c9, c10, c11.** It compares the tile / sub-region / half / index the C reports against the Python's, so it sees only defects in those six numbers. c7 reads the RIGHT beats in the wrong ORDER and c1/c8 mis-decode bytes that were addressed correctly. | c1, c7, c8 rows have no `reported addressing` term |
| the pre-pack integer row | **c9, c10, c11.** All three are pack-stage defects and the integer row is identical. | c9, c10, c11 rows have no `pre-pack integer row` term |
| every decoder-agreement check, jointly | a defect present in ALL FOUR implementations. Nothing here can see one; that is what the GGUF is for, and `tools/embed_gather.py`'s own table measures it -- its m1 and m8 are killed by **the GGUF only**, because there both Python decoders were mutated together. | `docs/2026-08-28_token-io-path.md` section 8.1 |

The asymmetry is worth stating plainly: this table mutates ONE of four
implementations, so the agreement checks are far more sensitive here than in
`embed_gather.py`'s own table, where two of three were mutated together. The
GGUF's independent contribution is measured by that table, not by this one.

### 4.5 Teeth on the refusals, separately from the mutants

```
$ embed_dump --mv4i ... --tokens 248320
pl_embed_mv4i: token 248320 outside 0 .. 248319                            rc=4

$ embed_dump --mv4i ... --tokens 248319                       # the LAST row
TOK 248319 EXP 21 VALEXP 23 AMAX 82804 ADDR 5173 15 7 1 0 15 169541632 529817600 4096
  (tile 5173 is the PARTIAL last tile: 248320 - 5173*48 = 16 rows, and rr = 15
   is its last row.  It is in the checked set and it passes.)

$ embed_dump_without_mutant_hooks --mv4i ... --tokens 0 --mutant 1
embed_dump: mutant 1 refused.  A build without -DEMBED_MV4I_MUTANTS
  cannot select a defect, which is the point                               rc=3

$ (a caller asking for 64 elements from a K=4096 tensor)
pl_embed_mv4i: caller wants 64 elements, ... has K = 4096.
  Refused rather than truncated: a short embedding row is a
  plausible-looking wrong answer.                                          rc=-1
```

### 4.6 The recipe, measured through the new C

```
d32   rows 48  mean relerr 0.22794  worst 0.70541
wide  rows 48  mean relerr 0.08630  worst 0.12667
ratio d32/wide mean = 2.641x
```

Identical to `docs/2026-08-28_token-io-path.md` section 5, reproduced by an
implementation that shares no code with the one that produced it.

**And the sharper result**, which is what actually pins the recipe. Running the
whole check with `--recipe d32`:

```
tokens compared                     48
vs ref/matvec_int4 (run9b embed)    3 exp, 45 mant mismatches
vs embed_gather direct              0 exp, 0 mant mismatches
vs embed_gather reassemble          0 exp, 0 mant mismatches
rows the GGUF gate rejects          4  (ADVISORY for this recipe)
CHECK FAIL
```

The two Python decoders agree with `d32` perfectly -- they are correct
implementations of a worse recipe -- and `ref/run9b.c`'s embedding **disagrees
in 45 of 48 rows**. That is direct evidence that the whole-model reference's
embedding is the `wide` recipe, not spec D 3.2 as written, and that shipping
`d32` would feed the card an activation no rung ever evaluated. Note also that
the GGUF gate rejects only 4 of 48 under `d32`, confirming the recorded finding
that the two populations overlap there and the gate is not usable.

### 4.7 The two copies, at the activation

MEASURED over the same 48 corner-forced rows, both packed to int16 BFP by the
same rule (`exp = 14 - floor(log2(amax))`, round half toward +inf), both scored
against the BF16 GGUF row:

```
rows 48
packed INT4 -> BFP int16   mean relerr 0.086295  worst 0.126667
GGUF BF16   -> BFP int16   mean relerr 0.000048  worst 0.000425
ratio INT4/BF16 mean = 1803.5x
```

### 4.8 The manifest reader, against EMBDROP's independently-obtained numbers

```
$ mtest .../qwen35-9b-mv4i-noembd/manifest.json .../qwen35-9b-mv4i-qkvpad/manifest.json
manifest .../qwen35-9b-mv4i-noembd/manifest.json:  hbm 8589934592 B, weights_end 0x10C006000,
    gdn 0x10C006000+75497472, kv_base 0x110806000, 65536 B/token, max_ctx 61311,
    reserved_end 0x110806000
manifest .../qwen35-9b-mv4i-qkvpad/manifest.json:  hbm 8589934592 B, weights_end 0x12F203000,
    gdn 0x12F203000+75497472, kv_base 0x133A03000, 65536 B/token, max_ctx 52319,
    reserved_end 0x133A03000
```

Every value matches `docs/debugging/2026-08-29_token-embd-drop.md` section 4.10,
which obtained them in Python from the same files.

### 4.9 The base-address fix, firing

```
$ server/embed_e2e --mv4i .../token_embd.weight.mv4i \
                   --manifest .../qwen35-9b-mv4i-noembd/manifest.json

A  the manifest, read by server/fk33_manifest.c
   ... reserved_end 0x110806000
B  the OLD hardcoded bases against THIS image
   x 0x000E0000000  l 0x000E1000000  desc 0x000E2000000
   the card owns everything below 0x00110806000
   all three are inside it: yes
C  the derivation, from the shape and hbm.size alone
   x    0x001FFB04000  span 4227072
   l    0x001FFF0C000  span 993344
   desc 0x001FFFFF000  span 4096
   costs 79 tokens of KV at 65536 B/token (max_ctx 61311 -> 61232)
D  the real provider driving the real seam (simulated card)
   mv4i ... M=248320 K=4096 ROWS_IF=48 AXI_DW=256 ... recipe=wide read=4096B x2
   seam v1 @BAR+0xE000 vocab=248320 embd=4096 layer=32 ctx=4096 chunk=8
       x_stride=8256 l_stride=993344 | SIMULATED card
   prefilled 5, pos 5, argmax 145844 (SYNTHETIC logits: meaningless)
   H2C 41280 B for 1 GOs; the provider read 40960 B in 5 gathers
E  the OLD x_base, offered to pl_open with this manifest
F  and the same offer with NO manifest, which cannot be checked

EMBED_E2E PASS  (0 failed)
```

Step E's refusal, in full:

```
pl_open: block layout refused: out of range: SEQ_POS + N_STEP past the KV capacity,
                               or a block past the top of HBM
  x_base   = 0x000E0000000  span 66048
  l_base   = 0x001FFF0C000  span 993344
  desc_ptr = 0x001FFFFF000  span 4096
  hbm_top  = 0x00200000000
  the card owns everything below 0x00110806000
  Leave x_base/l_base/desc_ptr at 0 to have them derived.
  -> x_base is INSIDE the loaded image
```

Step F's note, which is what makes this a derivation rather than a new constant:

```
[pl_backend] NOTE: neither manifest_path nor hbm_reserved_end was given, so the
  blocks at 0xE0000000 / 0xE1000000 / 0xE2000000 were checked for alignment, the
  stack line and overlap with each other, but NOT against the loaded weight
  image.  That is the check that the old hardcoded 0x00E0000000 needed and did
  not have.
```

### 4.10 The existing gate still passes

```
$ make check
SERVER_COMPILE OK

$ make test
T1 .. T12
SEAM_SELFTEST PASS  (84 checks, 0 failed)

$ make llama_server
g++ ... -o llama_server -lm -lpthread          (links the two new objects)
```

`seam_selftest`'s T6 previously perturbed the three hardcoded constants. It now
perturbs the DERIVED bases, and gained four checks that the old bases could not
have had: an `x_base` inside the image is refused, a `desc_ptr` inside the image
is refused, the same `reserved_end` with derived bases OPENS (the control
without which the refusals measure nothing), and a `reserved_end` 4 KB below the
top of HBM makes the derivation itself refuse.

---

## 5. PART 3 in full: which copy, and what the other one would have changed

### 5.1 The evidence for the packed INT4 copy

1. **`ref/run9b.c`'s `embed()` reads it.** It calls `mv("token_embd.weight")`,
   which resolves through `tools/ref9b/make_index.py` into a **packed set**, and
   dequantizes with `w_deq` = `codebook[get_widx] * get_scale / 32768 *
   2^-w_exp`. Verified by reading the file, not by grep alone.
2. **Every number that makes a token falsifiable was measured with it.**
   `docs/debugging/2026-08-29_9b-whole-model-reference.md`: the INT4 weight
   format costs 0.1252 relative RMS at the logits, the int16 BFP activation
   format 0.00313 on top, and all three rungs pick the same next token id on all
   five positions of the reference prompt. Change the embedding's source and
   every one of those has to be re-measured before it means anything again.
3. **`ref/run9b.c`'s embedding IS the `wide` recipe** (section 6.1 shows the
   algebra), and MEASURED at 4.6 it disagrees with `d32` in 45 of 48 rows. So
   the recipe question and the copy question have the same answer and the same
   source of truth.
4. **An on-card gatherer is still a live option.** `sim/seq_tbl_pkg.vhd` records
   `OP_EMBED` as explicitly REJECTED, which is not the same as impossible, and
   `docs/2026-08-28_token-io-path.md` costs it precisely because the gather is
   two contiguous bursts. HBM holds INT4, so an on-card gatherer can only ever
   read the packed copy. A host that read the GGUF would make the two gathers
   non-interchangeable -- which is the exact thing `tools/embed_gather.py`'s
   docstring says its shared recipe exists to prevent.
5. **The SBC.** 572,207,104 B against 2,034,237,440 B, on a machine with at
   least 4 GB. This is the weakest of the five arguments and it is listed last
   on purpose; it would not have decided anything by itself.

### 5.2 What the GGUF choice would have changed, stated rather than dismissed

* **It would be 1,803x more accurate at the activation** (4.7: 0.000048 against
  0.086295 mean relative error). This is the honest cost of the decision, and
  the INT4 copy is the *verified* copy, not the *accurate* one.
* **It would require re-running the reference.** `ref/run9b.c` is not this
  track's file, and its `embed()` would have to change, rung 2 and rung 3 would
  have to be re-captured, and the 0.1252 / 0.00313 / same-next-token results
  would all have to be re-established before any of them could be cited again.
  Around 30 s per token for rung 3 at 4.5 GB RSS, five tokens, plus rung 1.
* **It would need a BF16 reader on the SBC**, plus either 2.03 GB of storage for
  the tensor or a GGUF tensor-table parse to find its data offset. The per-token
  READ is not worse -- one contiguous 8,192 B read against two contiguous
  4,096 B reads -- so the cost is storage and a new file format, not bandwidth.
* **It is not blocked.** If perplexity ever shows that a 4.5-bit embedding is
  where the model loses its quality, this is the change to make, and the
  measurement in 4.7 is the reason to expect it to help. It should be made by
  changing `ref/run9b.c` FIRST and the host second, in that order, so the
  reference never trails the thing it certifies.

### 5.3 How the choice is expressed in code

No struct change was needed, exactly as the brief predicted: `embed_user`
carries it.

```c
pl_embed_mv4i_t *e;
pl_embed_mv4i_open("/mnt/.../qwen35-9b-mv4i/token_embd.weight.mv4i",
                   PL_EMBED_RECIPE_WIDE, &e);
o.embed      = pl_embed_mv4i;
o.embed_user = e;
```

The packed tensor is NOT part of the `noembd` set (that is the whole point of
the drop) and is kept where EMBDROP left it,
`/mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i`.

---

## 6. Derivations worth keeping

### 6.1 `ref/run9b.c`'s `embed()` + `reg_put()` IS `embed_gather.py --recipe wide`

This is the load-bearing algebra of the whole track, so it is written out.

`w_deq` gives `v_j = cb_j * sc_j * 2^-15 * 2^-w_exp`, i.e. the integer product
`p_j = cb_j * sc_j` scaled by `2^-(w_exp + 15)`. `RECIPE_WIDE` is defined as
exactly that: `value = p_j`, `val_exp = w_exp + 15`.

`reg_put` sets `exp = 14 - floor(log2(amax_double))`. For an integer `a`,
`floor(log2(a)) = msb_pos(a)`, and `amax_double = amax_int * 2^-(w_exp+15)`, so

```
exp = 14 - (msb_pos(amax_int) - (w_exp + 15))
    = (w_exp + 15) - (msb_pos(amax_int) - 14)
    = val_exp - sh              with sh = msb_pos(amax_int) - TARGET_MSB
```

which is `bfp_pack`'s exponent exactly, TARGET_MSB = 14 and `sh` unclamped.
For the mantissas, `floor(v_j * 2^exp + 0.5) = floor(p_j * 2^-sh + 0.5)` =
`round_shift(p_j, sh)` for `sh > 0`, and an exact left shift for `sh < 0`. Both
saturate with the same `mv4i_sat16`. **The two are value-identical, and 4.3
confirms they are bit-identical over 998 rows.**

### 6.2 Why the blocks are allocated top-down

The weight image grows from address 0 and the KV cache grows upward from
`kv_base`. Placing the host's three blocks at the TOP means they are the first
thing either growth collides with, and that collision surfaces as a refusal in
`pl_open()` rather than as an overwritten weight. It also means the placement
needs only `hbm.size`, not the KV extent, so it does not have to model an
allocator that does not exist. **The price is stated rather than hidden**: at
the 9B shape with `max_chunk = 512` the three blocks plus their alignment gaps span 5,226,496 B
from `x_base` to the top of HBM, which is 79 tokens of KV at 65,536 B/token, taking `max_context_tokens` 61,311 -> 61,232.

### 6.3 The per-token transfer is 8,256 B, not 8,208

`fk33_x_stride(n_embd) = round_up(16 + 2*n_embd, 64)`. At `n_embd = 4096` that
is `round_up(8208, 64) = 8256`. 8,208 is the payload; 8,256 is what crosses.
MEASURED: five tokens moved 41,280 B. At the same H2C rate the seam header
assumes (3.27 GB/s) that is 2.52 us rather than 2.51 us, so nothing downstream
changes, but the number in `docs/debugging/2026-08-29_token-embd-drop.md`
section 8 is the payload and should be read as such.

---

## 7. Measured and REJECTED -- do not retry

**Verifying the C gather by decoding a row and re-encoding it.** REJECTED before
it was written. `CLAUDE.md`'s `m7` is the recorded case: a packer plus a
reversed decoder passed an entire self-test suite while both were wrong. Every
check in section 4 compares against an implementation this track did not write.

**Making the C provider call `ref/matvec_int4.c`'s accessors.** REJECTED. It
would have been less code and it would have made 4.2 and 4.3 vacuous: a decoder
that calls its own oracle agrees with it for free. The provider deliberately
uses a different shape (two contiguous reads against per-element addressing),
which is also the shape a driver and an on-card gatherer actually issue.

**Shipping `PL_EMBED_RECIPE_D32`, i.e. spec D 3.2 as written.** MEASURED and
rejected twice over: 2.641x worse mean relative error (4.6), and 45 of 48 rows
disagreeing with `ref/run9b.c`'s embedding (4.6). It is retained only as a
selectable recipe so that check can be run; the default is `wide` and the header
says not to ship it.

**Holding the BF16 GGUF copy on the host.** REJECTED for this landing, with the
full argument and the measured accuracy it forgoes in section 5.2. It is not
"wrong"; it is unverified, and making it verified starts with `ref/run9b.c`,
which is not this track's file.

**Replacing `0x00E0000000` with a bigger constant.** REJECTED explicitly. The
brief forbade it and the data agrees: `kv_base` moved 0x1_33A0_3000 ->
0x1_1080_6000 with the drop, so any constant chosen against one image is wrong
against the next. Step F of 4.9 is the check that the refusal comes from the
manifest and not from a new number.

**Writing or vendoring a general JSON parser for the manifest.** REJECTED. A
general parser is more code and would still have to be told which keys matter.
`server/fk33_manifest.c` is a narrow scanner that tracks string literals so a
brace inside a `"why"` value cannot corrupt the depth, reads only keys at the
`hbm` object's own depth (so `kv_extents[0].base` cannot be mistaken for a
top-level `base`), and REQUIRES every key it needs to appear exactly once,
because a missing key read as zero would mean "no constraint" -- the exact
failure this file exists to prevent.

**`mmap`-ing the 546 MiB embedding tensor in the provider.** REJECTED in favour
of `pread`. The read shape is then literally the two bursts a driver issues, the
per-token cost is visible in a counter (`pl_embed_mv4i_bytes_read`), and an SBC
does not map half a gigabyte to answer a 4 KB question. The ref ORACLE does
`mmap`, because `mv4i_parse` takes a whole image and `ref/` is not this track's
to change; that is a test binary on the dev box, not the shipping path.

**Supporting `GRP > 1` in the provider.** REJECTED, refused at open with a
message. At `GRP > 1` several `(tile, block)` groups share a superword, the
scale beat index stops being `t*nb + b`, and the second read stops being
contiguous. `tools/embed_gather.py` refuses on the same rule, so the two cannot
silently diverge. The shipped geometry is `GRP = 1`.

---

## 8. Measurement traps hit, including my own

**My own, and it nearly cost the whole PART 3 argument: I started to reason
about which copy was "more accurate" instead of which copy was verified.** The
GGUF copy is 1,803x more accurate at the activation (4.7). Had accuracy been the
criterion, this track would have shipped a provider whose output no rung of the
whole-model reference has ever evaluated, and the 0.1252 relative RMS everyone
now quotes would silently have stopped applying. The criterion the brief gave --
"which one produces the activation the rest of the pipeline was verified
against" -- is the right one and it is NOT the same question.

**A checker that mutates one of four implementations flatters itself.** Section
4.4's agreement checks kill c1 and c8, which `tools/embed_gather.py`'s own table
records as killed by **the GGUF only**. The difference is entirely that this
table mutates one implementation and that one mutates two together. Reading 12
of 12 as "the checks are stronger than the Python's" would be wrong; it is
measuring a different thing, and 4.4's table says so.

**Correlation is scale-invariant, so the GGUF's correlation gate cannot see an
exponent error.** c11 negates `x_exp` -- a factor of `2^38` on the row -- and
correlation stays at 0.992, a perfectly healthy-looking number. Only the
relative-error half fires. A gate written as "correlation > 0.9" alone would
have passed a row that is 275 billion times too large.

**`floor(log2(x))` in `double` versus `msb_pos` on an integer.** The oracle
computes the exponent in floating point and the provider computes it from a bit
position. They agree over 998 rows here, but that agreement is an empirical
result at this tensor's dynamic range, not a proof. If a future tensor's `amax`
lands within one ULP of a power of two, this is where the two would part.
Recorded as a known, unproven edge, and the bit-exact comparison is what would
catch it.

**The brief's `8,208 B per card per token` is the payload, not the transfer.**
The stride rounds to 64, giving 8,256. Caught by asserting the measured H2C byte
count against `5 * fk33_x_stride(4096)` in `embed_e2e` rather than against the
number in the brief.

**`FK33_SEAM_ERR_POS`'s text is misleading for this refusal.** It reads "SEQ_POS
+ N_STEP past the KV capacity, or a block past the top of HBM", which is the
code's documented two senses and neither of them is "inside the weight image".
The error code space is the card's and is not this track's to extend, so
`pl_open` now prints an explicit `-> x_base is INSIDE the loaded image` line
after the generic text. A reader who stopped at the first line would have
diagnosed the wrong thing.

**`du -sh` on any of these model directories is meaningless** (inherited from
EMBDROP's write-up and re-confirmed here): the sets are symlink farms, and only
`du -shL` or the manifest's own `nbytes` is honest.

**Running tools from the repository's `sim/` directory overwrites committed
vector files.** Every command in this write-up was run from the repository root
or from `server/`, and every scratch binary was built into the session
scratchpad, not into `sim/`.

---

## 9. What was changed

| file | change |
|---|---|
| `server/embed_mv4i.h`, `server/embed_mv4i.c` | NEW. The provider: open a `.mv4i`, gather a row as two contiguous `pread`s, dequantize, BFP-pack. `PL_EMBED_RECIPE_WIDE` default; `D32` selectable and documented as not shippable. Twelve named mutants behind `-DEMBED_MV4I_MUTANTS`, unavailable in a normal build. |
| `server/fk33_manifest.h`, `server/fk33_manifest.c` | NEW. A narrow, strict reader for the `hbm` object of a packed set's `manifest.json`, plus the DERIVED `reserved_end`. |
| `server/pl_backend.h` | `x_base`/`l_base`/`desc_ptr` documented as 0-means-derive; new `manifest_path`, `hbm_reserved_end`, `hbm_size`; new `pl_hbm_bases`, `pl_derive_bases()`, `pl_check_bases()`. The stale "5,056,995,328 bytes" comment REMOVED. The sign convention of `pl_embed_fn`'s `*exp` stated, with mutant c11 named as what enforces it. |
| `server/pl_backend.c` | `pl_derive_bases()` / `pl_check_bases()`; `pl_open()` reads the manifest, derives the missing bases, checks all three including against the image, names the offending block, and prints the KV cost of the placement (or a NOTE that the image check could not run). `pl_open_opts_default()` no longer carries the three constants. |
| `server/tests/embed_dump.c` | NEW. The C gather as parseable text; drives the mutants. |
| `server/tests/embed_ref_oracle.c` | NEW. `ref/run9b.c`'s `embed()` + `reg_put()`, by including `ref/matvec_int4.c` the way run9b does. Nothing in `ref/` is edited. |
| `server/tests/embed_e2e.c` | NEW. The provider driving the real seam against the simulated card, plus the base-address refusal on a real manifest, plus the control that it is not a new constant. |
| `server/tests/seam_selftest.c` | T6 perturbs the DERIVED bases; four new checks for the image-overlap refusal and its control. 75 -> 84 checks, all passing (MEASURED: the pre-change file, built from `git show HEAD:`, reports 75). |
| `server/Makefile` | `fk33_manifest.c` and `embed_mv4i.c` into `CSRC` (so both toolchains compile them and the board build carries them); new `embed_dump`, `embed_ref_oracle`, `embed_e2e`, `embed-check` targets; `check` covers the new files and tries the aarch64 syntax check. |
| `tools/check_embed_c.py` | NEW. Runs the C against the ref oracle, both Python decoders and the BF16 GGUF, and runs the mutation table. |

Reproduce with:

```sh
cd server && make embed-check
# or, explicitly:
make embed_dump embed_ref_oracle embed_e2e
python3 ../tools/check_embed_c.py \
    --mv4i /mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i \
    --dump ./embed_dump --ref-oracle ./embed_ref_oracle --n 1000
python3 ../tools/check_embed_c.py ... --n 64 --mutate
./embed_e2e --mv4i /mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i \
            --manifest /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json
```

---

## 10. NOT verified

* **Nothing ran against the card.** No `/dev/xdma*` was opened by anything in
  this work, no bitstream was loaded, no JTAG or `hw_server` was started. The
  only card in the loop is `server/fk33_sim.c`, and `fk33_seam.h` states in its
  own words that the engine it describes does not exist: the composed FK33
  design does not route, `llama_top` issues its final A job with `dst = R_NONE`
  and discards the result, and `rtl/embed.vhd` is still the 512-entry, 64-dim
  stories260K ROM. **No token produced by any path in this write-up is
  inference.**
* **The derived addresses have never been written to.** `pl_derive_bases()`
  produces `0x1FFB04000 / 0x1FFF0C000 / 0x1FFFFF000` on the post-drop set, and
  nothing has confirmed those bytes are reachable, that HBM is 8 GiB as the
  manifest says, or that a port on the upper stack answers there. The stack rule
  is asserted from `docs/2026-08-27_hbm-residency-map.md`, not measured.
* **No loader exists.** Nothing in this tree DMAs a packed set to a card, so
  "the image ends at `weights_end`" is a statement about a manifest, not about
  the contents of any HBM.
* **The provider's per-token cost is derived, not measured over PCIe.** Two
  4,096 B host reads per token and 8,256 B H2C per token are MEASURED as byte
  counts inside the process; no PCIe transfer, no small-transfer latency and no
  SBC disk latency has been measured. `fk33_seam.h` records that no
  small-transfer latency has EVER been measured on this card.
* **The GGUF gate is an addressing check, not an accuracy check.** It can say
  "this is the right row"; it cannot say the 4.5-bit pack is good enough for
  this model. Nothing here measures perplexity, and
  `docs/2026-08-28_token-io-path.md` says the same about its own numbers.
* **`sample_tokens` covers 998 of 248,320 rows.** The corners are forced and the
  rest is a seeded spread. A defect that affects only some other specific row is
  not excluded.
* **The equality of the double-precision exponent search and the integer
  `msb_pos` is empirical**, over these 998 rows on this tensor. See section 8.
* **`ref/run9b.c` was read, not run.** The 0.1252 / 0.00313 / same-next-token
  results are quoted from `docs/debugging/2026-08-29_9b-whole-model-reference.md`
  and were not re-measured here; what WAS measured here is that this provider's
  output is bit-identical to that reference's embedding stage.
* **The `noembd` set's payloads were not re-verified.** EMBDROP hashed them;
  this track read only its `manifest.json`.
* **Nothing was measured on the SBC.** The 4 GB constraint is taken from the
  brief. The 572,207,104 B and 2,034,237,440 B figures are file sizes, MEASURED.

---

## 11. Corrections

*(None yet. Later findings that overturn something above go here, dated, with
the superseded claim marked withdrawn rather than deleted.)*
