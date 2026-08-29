# Dropping `token_embd.weight` from the packed HBM image

**Date:** 2026-08-29
**Track:** EMBDROP
**Tree:** `fk33` branch, HEAD `a3dc2f4` at the start of the work. Five other
tracks were live in the tree; `tools/gen_llama_top_weights.py` and four new
`tools/` files were staged in the shared index by other tracks and were NOT
touched here. Only `tools/pack_model_fk33.py` and `tools/check_mv4i_set.py`
were edited, both exclusively owned by this track.
**Tools:** `python3` (`tools/pack_model_fk33.py`, `tools/check_mv4i_set.py`,
`tools/check_hbm_stack.py`), `b2sum`, `sha256sum`.
**No hardware was touched.** Nothing here ran against the FK33, and no
`/dev/xdma*`, `xsdb`, `hw_server`, `vivado ... program` or `hw/fk33/*.sh`
invocation appears anywhere in this work.

---

## 1. The question, verbatim

> **Drop `token_embd.weight` from the packed HBM image.** The host owns the
> embedding gather.
>
> 1. **Repack without `token_embd.weight`**, via `tools/pack_model_fk33.py`.
>    Make it an explicit, named, reversible option rather than a deletion [...]
>    Say what the flag is and what the default is.
> 2. **Prove nothing on the card reads it.** Do not take TOKIO's word or mine.
>    [...] **If you find a consumer, STOP and report it -- that falsifies the
>    decision's premise.**
> 3. **Verify the new image** [...] `tools/check_hbm_stack.py` must PASS with
>    no range crossing a 4 GiB stack boundary, and `tools/check_mv4i_set.py
>    --full` must pass with every payload hashed. [...] confirm the input GGUF
>    is unchanged by re-hashing it after the run.
> 4. **Report the recovered space** precisely, as bytes and as a fraction of
>    both the 8 GiB HBM and the ~2 GB N=4 spare budget.
> 5. **Check the host side has what it needs.** `server/pl_backend.c` v2 and
>    `pl_embed_fn` are the landing place TRACK SERVER left for this.

---

## 2. The answers, up front

**The flag is `--drop TENSOR`, repeatable, and the default is to drop
NOTHING.** It refuses a name the GGUF does not have rather than silently
dropping zero tensors. MEASURED: with no `--drop`, the regenerated manifest is
identical to the shipped `qwen35-9b-mv4i-qkvpad` manifest in every placement,
size, header field and payload digest; the only differences are the
`generated` timestamp and two strictly additive keys (`dropped_tensors: []`,
`counts.gguf_tensors` / `counts.dropped`).

**Nothing on the card reads `token_embd.weight`, and the premise stands.**
Zero references in `rtl/`, zero in the descriptor and schedule generators, zero
in `hw/`. The RTL is built for the opposite: the host writes the BFP row into
region X over `hw_we / hw_reg / hw_addr / hw_data`
(`rtl/llama_top.vhd:583-589`, override at `:1088-1097`, arbitration at
`:1278`), and `rtl/seq_opdec.vhd:611` (`tok_fsm`) exists solely to publish that
write into the lock plane. An `OP_EMBED` opcode is recorded as explicitly
REJECTED at `sim/seq_tbl_pkg.vhd:44-49`.

**`output.weight` is NOT tied to `token_embd.weight`,** which was the one way
the premise could have been falsified. They are two separate BF16 tensors of
identical shape `[4096, 248320]` at different GGUF data offsets with different
bytes, and the LM head reads `output.weight` as 15 row windows
(`tools/gen_layer_program.py:435`). Dropping the embedding does not touch it.

**The new set is `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd`.**
`check_hbm_stack.py` PASS over 7,154 byte ranges; `check_mv4i_set.py --full`
PASS with 250 of 250 payloads hashed and matched (249 `.mv4i` + the F32 side
blob). The input GGUF is byte-identical before and after: blake2b-128
`9cb8238e2691edd72d46e8b72d872053`, sha256
`daebe40e...39159a`, size and mtime unchanged.

**Recovered space: 589,287,424 B (562.0 MiB) of HBM per card**, of which
572,207,104 B is the tensor itself and 17,080,320 B is stack-boundary hole that
the shorter image no longer has to skip. That is **6.86 % of the 8 GiB HBM** and
**29.5 % of the ~2 GB N=4 spare budget**, or **2,357,149,696 B (2.195 GiB)
across a 4-card cluster**. Measured downstream effect: `kv_base` moves from
`0x1_33A0_3000` to `0x1_1080_6000` and `max_context_tokens` rises 52,319 ->
61,311 on a single card.

**The host interface is SUFFICIENT in shape and EMPTY in substance.**
`pl_embed_fn` (`server/pl_backend.h:70-72`) takes exactly the right arguments
and `pl_backend.c:327` already calls it per token; the only implementations are
`pl_embed_synthetic` and NULL-is-an-error. Three things are missing and are
named in section 8, the sharpest being that **`pl_open_opts`' default
`x_base`/`l_base`/`desc_ptr` at `0x00E0_0000_00` sit INSIDE the weight image in
both the old and the new set** and must move.

---

## 3. The procedure, in the order it was run

Each step is listed with what it controls for, because several of them exist
only to rule out a specific way of being fooled.

1. **Read the current manifest before touching anything**, and confirm which of
   the three candidate sets is live. Controls for the trap recorded in the
   brief: a track today read the SUPERSEDED `qwen35-9b-mv4i` set (which FAILS
   the stack check) and reported its defect as the shipped design's. The set
   read here is `qwen35-9b-mv4i-qkvpad`, `qkv_segment_pad: true`, 251 files.
2. **Hash the input GGUF BEFORE any tool ran.** Controls for the packer or a
   GGUFReader mmap writing back into the source; the same hash is taken again
   at the end and compared.
3. **Independent RTL/tooling sweep for any consumer**, dispatched as its own
   read-only search over `rtl/`, `sim/`, `tb/`, `tools/`, `hw/`, `server/`,
   `docs/`, plus a direct read of the GGUF tensor table to settle the
   `output.weight` tie question. Controls for taking the decision's own
   premise on trust, which is what the brief explicitly forbade.
4. **Implement `--drop` and re-run with NO flag into a staging directory**
   whose files are symlinks to the shipped set's real payloads. Because every
   file is present at its exact expected size the packer takes its KEPT path,
   rebuilds the whole manifest from the bytes on disk, and re-hashes
   everything. Comparing that manifest to the shipped one is therefore a real
   check of "the default changed nothing", not a claim about the diff.
5. **Teeth-check the flag on a name that does not exist** (`--drop
   token_embd.wieght`). Controls for the exact failure this option invites: a
   typo that drops nothing and still exits 0.
6. **Run with `--drop token_embd.weight`** into the deliverable directory.
7. **Both checkers on the new set**, `check_hbm_stack.py` and
   `check_mv4i_set.py --full`.
8. **Negative control for `check_hbm_stack.py`**: run it on the superseded
   `qwen35-9b-mv4i` set, which is known to straddle. A checker never shown to
   fail has not been shown to work.
9. **Three mutants of the new manifest** against the new `dropped_tensors`
   guard in `check_mv4i_set.py`, plus a **backwards-compatibility control**:
   the shipped qkvpad manifest, which carries none of the new keys, must still
   PASS unchanged.
10. **Cross-check every surviving payload digest** between the shipped set and
    the new set. Controls for the drop having perturbed some other tensor:
    250 of 250 common files match on `blake2b_128`, `nbytes`, `M`, `K`,
    `w_exp`, `out_shift` and `segments`, while 249 of 250 legitimately move
    their `hbm_offset`.
11. **Re-hash the GGUF** and compare against step 2.

---

## 4. The evidence, as captured output

### 4.1 The set that is live, before any change

```
counts {'tensors': 427, 'matvec': 250, 'f32': 177}
geometry {'rows_if': 48, 'axi_dw': 256, 'block': 32, 'nports_w': 24, 'n_scale_sub': 3, 'axi_read_masters': 27, 'qkv_segment_pad': True}
source /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf
nfiles 251
weights_bytes 5059649536
TOKEN_EMBD ENTRY: {'file': 'token_embd.weight.mv4i', 'kind': 'mv4i', 'tensor': 'token_embd.weight',
 'M': 248320, 'K': 4096, 'w_exp': 8, 'out_shift': 3, 'nbytes': 572207104,
 'hbm_offset': 572207104, 'stack': 0, 'blake2b_128': '72fc532f3ea6dfa23bf8949a5977ebaa'}
```

### 4.2 The input GGUF, before and after every run

```
--- before ---
9cb8238e2691edd72d46e8b72d872053  Qwen3.5-9B-BF16.gguf          (b2sum -l 128)
daebe40eeea7057c1cdf35ac56d13f507d8bf12171bbb7a6b6b0d3f05439159a  Qwen3.5-9B-BF16.gguf
17920697312 1787925155 Qwen3.5-9B-BF16.gguf                      (size mtime name)
--- after ---
9cb8238e2691edd72d46e8b72d872053  Qwen3.5-9B-BF16.gguf
daebe40eeea7057c1cdf35ac56d13f507d8bf12171bbb7a6b6b0d3f05439159a  Qwen3.5-9B-BF16.gguf
17920697312 1787925155 Qwen3.5-9B-BF16.gguf
```

### 4.3 The default changes nothing

`pack_model_fk33.py <gguf> qwen35-9b-mv4i-defaultcheck --rows-if 48 --axi-dw 256`,
no `--drop`, all 251 files KEPT, manifest fully rebuilt and re-hashed:

```
  weights          5059649536 B  4.712 GiB  (58.9 % of 8 GiB)
  GDN state        72.0 MB at 0x12f203000
  dropped          none
  qkv segment pad  on, 24 fused tensor(s) padded
  stack holes      25956352 B  24.8 MiB in 1 hole(s)
    25956352 B at 0xfe73f000: stack boundary before blk.7.ffn_gate.weight.mv4i
  free for KV      3.193 GiB from 0x133a03000 => 52319 tokens of context in 1 per-stack extent(s)
```

Compared field by field against the shipped `qkvpad` manifest:

```
keys only in NEW: ['dropped_tensors']
counts old: {'tensors': 427, 'matvec': 250, 'f32': 177}
counts new: {'tensors': 427, 'matvec': 250, 'f32': 177, 'gguf_tensors': 427, 'dropped': 0}
dropped_tensors new: []
IDENTICAL modulo generated/dropped_tensors/new count keys: True
```

That `True` covers every `hbm_offset`, `nbytes`, `M`, `K`, `w_exp`,
`out_shift`, `segments`, `blake2b_128`, every stack hole, `gdn_state_base`,
`kv_base`, `kv_extents` and `max_context_tokens`.

### 4.4 The flag has teeth: a typo is refused, nothing is written

```
$ pack_model_fk33.py <gguf> teethdir --drop token_embd.wieght
model    /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf
outdir   teethdir
geometry ROWS_IF=48 AXI_DW=256 BLOCK=32 -> NPORTS_W=24 n_scale_sub=3 (27 AXI read masters)
--drop 'token_embd.wieght': the GGUF has 0 tensors with that exact name, want exactly 1. Nothing was written.
rc=1
$ ls teethdir
(empty)
```

### 4.5 The drop itself

```
$ pack_model_fk33.py <gguf> qwen35-9b-mv4i-noembd --rows-if 48 --axi-dw 256 --drop token_embd.weight
tensors  427 in the GGUF, 1 dropped, 426 placed: 249 matvec, 177 kept F32
  DROPPED token_embd.weight ne=[4096, 248320] matvec, 572207104 B not placed
nonmatvec_f32.bin present at 4571136 bytes, kept
[1/249] output.weight kept (572207104 B)
...
  weights          4487442432 B  4.179 GiB  (52.2 % of 8 GiB)
  GDN state        72.0 MB at 0x10c006000
  dropped          1 tensor(s), 572207104 B (0.533 GiB) NOT placed: token_embd.weight
  qkv segment pad  on, 24 fused tensor(s) padded
  stack holes      8876032 B  8.5 MiB in 1 hole(s)
    8876032 B at 0xff789000: stack boundary before blk.29.attn_qkv.weight.mv4i
  free for KV      3.742 GiB from 0x110806000 => 61311 tokens of context in 1 per-stack extent(s)
```

### 4.6 Both checkers on the new set

```
$ check_hbm_stack.py /mnt/storage/llama-models/qwen35-9b-mv4i-noembd
checked 7154 byte ranges against a 4294967296 B stack boundary in .../manifest.json
PASS no range crosses a stack boundary
rc=0

$ check_mv4i_set.py /mnt/storage/llama-models/qwen35-9b-mv4i-noembd --full
1 tensor(s) declared dropped and confirmed absent from the image: token_embd.weight (572207104 B)

249 packed tensors + 1 F32 side file, 4487442432 bytes total, 250 payloads hashed and matched
PASS  every header, size, sub-region offset and HBM placement is as spec 6.4/6.5a requires
rc=0
```

**Range count 7,154** (was 7,182 on the 251-file set: one `.mv4i` removed takes
its 27 sub-regions plus itself, 7,182 - 28 = 7,154). **Payload count 250**
hashed and matched, i.e. every file in the set.

### 4.7 Negative control: `check_hbm_stack.py` still bites

```
$ check_hbm_stack.py /mnt/storage/llama-models/qwen35-9b-mv4i      # the SUPERSEDED set
checked 7182 byte ranges against a 4294967296 B stack boundary in .../manifest.json
FAIL 2 range(s) cross a stack boundary or are structurally wrong:
  blk.7.ffn_gate.weight.mv4i: 4267130880 .. 4295446528 crosses 4294967296 (stack 0 -> 1); 479232 bytes on the wrong side
  blk.7.ffn_gate.weight.mv4i:s2: 4294397952 .. 4295446528 crosses 4294967296 (stack 0 -> 1); 479232 bytes on the wrong side
rc=1
```

### 4.8 The new `dropped_tensors` guard has teeth

Three mutated copies of the new manifest, payloads untouched:

```
=== MUTANT m1 (declare output.weight dropped while it is placed) ===
FAIL output.weight: declared dropped, but a manifest entry places it
FAIL output.weight: declared dropped, but output.weight.mv4i is in the file list
2 FAILURES                                                              rc=1

=== MUTANT m2 (counts.dropped says 2, the list has 1) ===
FAIL counts.dropped 2 but dropped_tensors lists 1
FAIL counts: 426 placed + 2 dropped != 427 in the GGUF
2 FAILURES                                                              rc=1

=== MUTANT m3 (delete the declaration; the tensor really is absent) ===
FAIL counts.dropped 1 but dropped_tensors lists 0
1 FAILURES                                                              rc=1
```

Backwards-compatibility control, the shipped manifest with none of the new
keys:

```
$ check_mv4i_set.py /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad --full
250 packed tensors + 1 F32 side file, 5059649536 bytes total, 251 payloads hashed and matched
PASS  ...                                                               rc=0
$ check_hbm_stack.py /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad
PASS no range crosses a stack boundary                                  rc=0
```

### 4.9 Nothing else moved

```
in A not B: ['token_embd.weight.mv4i']
in B not A: []
common files: 250; payload hash mismatches: 0; size mismatches: 0
files whose HBM offset moved: 249 of 250
files whose M/K/w_exp/out_shift/segments are unchanged: 250 of 250
```

### 4.10 The space, as arithmetic

```
--- qkvpad (current)                --- noembd (new)
  files              251              files              250
  weights_bytes      5059649536       weights_bytes      4487442432
  stack_hole_bytes   25956352         stack_hole_bytes   8876032
  weights_end        0x12f203000      weights_end        0x10c006000
  gdn_state_base     0x12f203000      gdn_state_base     0x10c006000
  kv_base            0x133a03000      kv_base            0x110806000
  free_after_gdn     3428831232       free_after_gdn     4018118656
  max_context_tokens 52319            max_context_tokens 61311

=== DELTAS ===
  weights payload freed  572207104 B  = 0.532909 GiB = 545.699 MiB
  stack hole shrank by    17080320 B  =  16.289 MiB
  kv_base moved down     589287424 B  = 561.988 MiB
  free_after_gdn gained  589287424 B  (identical to the kv_base delta: True)
  context tokens gained  8992
  as % of 8 GiB HBM       6.8602 %
  as % of ~2 GB N=4 spare 29.46 %   (spare taken as 2e9 B)
  as % of 2 GiB N=4 spare 27.44 %
  across a 4-card cluster 2357149696 B = 2.1953 GiB
```

DERIVED: 572,207,104 + 17,080,320 = 589,287,424, and the free-space gain equals
the `kv_base` movement exactly, so no alignment byte is unaccounted for.

---

## 5. Measured and REJECTED -- do not retry

**Deleting the tensor from the packer, or from the model.** REJECTED before it
was written. The option is `--drop`, defaulting to empty, and the manifest
records every dropped tensor's name, shape and `bytes_if_placed` next to
`source_gguf`, so the set states what it lacks and where to get it. The reason
is not tidiness: the host now NEEDS those bytes (section 8), and an on-card
gather opcode is a live future option (`sim/seq_tbl_pkg.vhd:44-49` records it
as rejected, not impossible). A deletion would be irreversible in exactly the
case where reversal is wanted.

**A `--no-token-embd` boolean flag.** REJECTED in favour of a general
`--drop TENSOR`. A model-specific boolean would need a second one the next
time, and it cannot express "drop this and check it was really there".

**Trusting `--drop` because the output looked smaller.** MEASURED and rejected
as evidence: an unmatched `--drop` name is the natural failure mode of this
option and produces a full-size image with a success exit code. That is why
the tool refuses an unmatched name (4.4) and why the checker cross-examines
the declaration against the file list (4.8), and why neither claim rests on
reading the packer's own printout.

**Verifying the new image by unpacking it with our own decoder.** NOT DONE, on
purpose. `CLAUDE.md`'s `m7` mutant is the recorded case of a packer plus a
reversed decoder passing an entire self-test suite while both were wrong. The
evidence used instead is: payload digests carried forward unchanged from a set
that was already verified (4.9), a checker that shares no arithmetic with the
allocator and reads sub-region bases out of each file's own header
(`check_hbm_stack.py`), and that checker demonstrated failing on a known-bad
set (4.7).

**Believing TOKIO's file:line citations without re-reading them.** One was
already stale: the brief and an early draft of the packer docstring cite
`rtl/llama_top.vhd:544-547` for the host write port. MEASURED with `grep -n`
against both the working tree and `git show HEAD:rtl/llama_top.vhd`, the port
is at `:583`. The packer's docstring now cites the SYMBOL names with the line
as an aside, because `rtl/llama_top.vhd` is under active edit by another track
and any line number in a comment goes stale within the day.

**Repacking the 249 surviving tensors from the GGUF.** REJECTED as
unnecessary and as a risk: they are bit-identical inputs producing bit-identical
outputs, it costs hours of CPU, and it would have put a second writer on
5 GB of files while other tracks run. The staging directories are symlink
farms into the shipped payloads, which is the same construction the shipped
`qkvpad` set already uses, and both checkers follow symlinks (`os.path.getsize`
and `open` both do), so the verification is of the real bytes.

---

## 6. Measurement traps hit, including my own

**The three-sets trap, avoided deliberately.** `qwen35-9b-mv4i` (superseded,
FAILS the stack check), `-stackfix` (PASS) and `-qkvpad` (PASS, current) all
exist side by side and differ. Section 4.1 records which one every "before"
number came from. The negative control in 4.7 is the superseded set used ON
PURPOSE as a known-bad input, which is the only safe use for it.

**`du -sh` on these sets is meaningless.** The shipped `qkvpad` directory
reports `437M` because most of its entries are symlinks into `qwen35-9b-mv4i`;
the set is 4.71 GiB of payload. `du -shL` (follow links) or summing the
manifest's `nbytes` is the honest measure. The new set reports `1.2M` for the
directory and `4.2G` followed.

**A `--drop` that matches nothing would have exited 0.** Caught by design,
teeth-checked in 4.4. This is the same class as `regress.sh --only` matching
nothing and still printing PASS, recorded in `CLAUDE.md`.

**The default-equality claim needed a REGENERATED manifest, not a diff of the
tool.** Reading the patch and concluding "the default path is unchanged" is
structure, not values. The check that was actually run rebuilds the entire
manifest from the bytes on disk, including every blake2b-128, and compares it
field by field (4.3).

**My own trap: I copied a stale line number into a shipping comment.** The
packer docstring initially carried `rtl/llama_top.vhd:544-547` straight from
the brief. It was wrong by 39 lines. Fixed to cite symbols; recorded here
because the same citation is likely to be copied again from the brief or from
TOKIO's note.

**The GGUF hash was taken BEFORE the first tool ran, not after.** A hash taken
only afterwards proves nothing about whether a tool wrote to it. Both are in
4.2.

**`counts.tensors` changed meaning and could have gone unnoticed.** It now
counts what is PLACED (426), not what the GGUF holds (427, recorded separately
as `counts.gguf_tensors`). `check_mv4i_set.py` compares `counts.matvec` against
the number of `.mv4i` entries it checked, so had `tensors`/`matvec` been left
at the GGUF's counts the checker would have FAILED the new set. The new guard
asserts `tensors == matvec + f32` and `gguf_tensors == tensors + dropped` so
this cannot drift silently.

---

## 7. What was changed

| file | change |
|---|---|
| `tools/pack_model_fk33.py` | `--drop TENSOR` (repeatable, default empty, refuses an unmatched name); `dropped_tensors` in the manifest with name/shape/matvec/`bytes_if_placed`; `counts.gguf_tensors` and `counts.dropped`; a docstring section stating what the option is not. |
| `tools/check_mv4i_set.py` | guards that every declared dropped tensor is really absent from `files`, that `counts.dropped` matches the list, and that placed + dropped == GGUF; prints the dropped list. Old manifests without the keys are unaffected. |

Deliverable set: **`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd`**, 250
entries (249 `.mv4i` + `nonmatvec_f32.bin`), 4,487,442,432 B of payload
(4.179 GiB). The payload files are symlinks into the shipped set, matching the
construction of `qwen35-9b-mv4i-qkvpad`. `--force` would materialize real
files at the cost of a full repack.

Reproduce with:

```
python3 tools/pack_model_fk33.py \
    /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf \
    /mnt/storage/llama-models/qwen35-9b-mv4i-noembd \
    --rows-if 48 --axi-dw 256 --drop token_embd.weight
```

---

## 8. The host side: sufficient in shape, empty in substance

**Sufficient.** `pl_embed_fn` at `server/pl_backend.h:70-72` is
`int (*)(void *user, int token_id, int16_t *mant, int n_embd, int32_t *exp)`
-- BFP mantissas plus one shared exponent, which is exactly the layout the
activation block wants (`server/fk33_seam.h:106-115`: `+0x00 i32 x_exp`,
`+0x04 u32 token_id`, `+0x08 u64 0`, `+0x10 i16 * n_embd`). `pl_backend.c:327`
already calls it per token and `:334` already DMAs the staged block. The
`void *user` pointer is the extension point a real provider needs, so no
signature change is required. DERIVED per-token cost: 16 B header +
4,096 x 2 B = **8,208 B per card per token**, which is the figure the decision
was costed on.

**Missing, in the order the next track will hit them:**

1. **No real provider exists.** The only implementations are
   `pl_embed_synthetic` (`pl_backend.h:78`, "NOT A MODEL OF ANYTHING") and
   NULL, which `pl_open` rejects (`pl_backend.c:150-153`). Writing the real one
   is backlog item 4 and is stated as such at `pl_backend.h:30-38`. The recipe
   exists: `tools/embed_gather.py`, and specifically `--recipe wide`, which
   `pl_backend.h:34-38` records as MEASURED to move mean relative error from
   0.22794 to 0.08630 by folding the `>>15` into the BFP pack's own shift.
   That is a Python reference that needs a C port, not a design question.

2. **No way to tell the provider where the bytes are.** This is NEW as of this
   drop. Until now the embedding was in HBM and "the host reads it" was
   ambiguous; now the host must hold its own copy. There is no `embedding_path`
   in `pl_open_opts` and there does not need to be -- `embed_user` carries it
   -- but somebody must decide WHICH copy: the packed
   `token_embd.weight.mv4i` (572,207,104 B, two contiguous 4 KB reads per
   token, `tools/embed_gather.py`'s whole point) or the source GGUF
   (2,034,237,440 B of BF16, simpler and 3.6x larger). The packed file is kept
   at `/mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i` and is
   NOT deleted by this work.

3. **`pl_open_opts`' default HBM bases sit inside the weight image.**
   `pl_backend.c:134-136` sets `x_base = 0x00E0000000`, `l_base = 0x00E1000000`,
   `desc_ptr = 0x00E2000000`. The weight image runs from 0 to `weights_end`,
   which is `0x12F203000` in the shipped set and `0x10C006000` in the new one.
   `0xE0000000` is 3.5 GiB and is inside BOTH. Its own comment says the bases
   are "below the stack line at 0x1_0000_0000", which is true and is not the
   binding constraint. After the drop the free region starts at `kv_base`
   `0x110806000`, above the stack line, so the three blocks want either that
   region or the 8,876,032 B hole at `0xFF789000`. This is a real collision
   and it is not caused by the drop; the drop only changes the number it must
   clear. `server/**` is not this track's to edit, so it is reported, not
   fixed.

4. **Stale constant in a comment:** `pl_backend.h:100` says "the shipped weight
   image's 5,056,995,328 bytes". The shipped `qkvpad` set is 5,059,649,536 B
   of payload ending at 5,085,605,888; the new set is 4,487,442,432 B ending at
   4,496,318,464. Whoever fixes item 3 should replace the constant with a read
   of the manifest.

---

## 9. NOT verified

* **Nothing ran on hardware.** No card confirmed that a shorter image loads,
  that the freed region is usable, or that the host write to R_X reaches the
  region file. There is no loader in the tree that DMAs a packed set to the
  card at all (`grep -rn manifest.json hw/ server/` returns nothing).
* **The N=4 spare budget of ~2 GB is taken from the brief and from
  `~/GitHub/pcie-llm-hardware`, not re-derived here.** The 29.5 % figure
  inherits whatever that number's accuracy is. The 6.86 % of 8 GiB is
  independent of it.
* **The 249 surviving payloads were not re-quantized from the GGUF.** They are
  the shipped bytes, carried forward and re-hashed (4.9). If the shipped set
  were wrong, this set is wrong in the same way. That is a deliberate choice
  (section 5) and it means this work verifies the DROP, not the pack.
* **`max_context_tokens` 61,311 is the packer's own arithmetic** over the
  post-GDN free region at 17,408 B/token. It is not a measurement of any KV
  allocator, and no KV allocator exists.
* **The host-side gather was not implemented, ported, or benchmarked.** The
  8,208 B/token is derived from the declared block layout, not measured over
  PCIe.
* **No claim is made that dropping the tensor is right at N=1.** At N=1 the
  freed 562 MiB buys 8,992 tokens of context and nothing else; the argument
  that makes it decisive is the N=4 one, which is Oren's and is not re-derived
  here.
* **The `--drop` option was exercised on exactly one tensor, a matvec one.**
  The non-matvec branch of `bytes_if_placed` (which would also shrink
  `nonmatvec_f32.bin`) is written and reviewed but NOT exercised.

---

## 10. Corrections

None yet. Append here rather than editing above.
