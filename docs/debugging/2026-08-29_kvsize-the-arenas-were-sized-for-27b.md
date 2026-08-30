# The GDN and KV arenas were sized for a different model, and the RTL says by how much

**Date** 2026-08-29. **Track** KVSIZE. **Base commit** `b28e92b` ("arena-manifest:
the region block is the authority, and the optional key is gone"), which was HEAD
when this track started and is the tree every measurement below was taken on.
**Hardware** none. Nothing here opened `/dev/xdma*`, ran `xsdb`, or programmed a
card. **Machine at start**, MEASURED with `df -h` / `free -g`: root
`/dev/nvme1n1p6` 1.3 T, 39 G free, 97 percent; `/mnt/storage` 389 G free;
27 G of RAM available, 4 G of swap in use.

---

## 1. The question, verbatim

> Derive the true per-token KV cost and the true GDN state size for `QWEN35_9B`,
> from the RTL, not from the audit and not from the constants. The RTL is the
> oracle; where a document and the RTL disagree, the RTL wins. Check every term:
> the layer counts (24 GDN / 8 attention, from 32 blocks at interval 4), and the
> per-layer terms `6144*128` and `4*256` that ARENA-MANIFEST explicitly did not
> verify.

The brief that carried it added:

> If the per-token figure is genuinely 2x what the 9B shape needs, that is
> roughly **122,000 tokens** on one card.

---

## 2. The answer, up front

**All four constants were Qwen3.8-27B figures, and both of the per-layer terms
ARENA-MANIFEST left unchecked are wrong as well.** The correct figures, DERIVED
from `rtl/model_cfg_pkg.vhd` and the RTL that implements each arena:

| quantity | was | is | factor |
|---|---|---|---|
| GDN layers | 48 | **24** | 2x over |
| GDN state bytes per layer | `6144*128*2` = 1,572,864 | **1,052,672** | 1.494x over |
| GDN state arena | 75,497,472 | **25,264,128** | **2.988x over** |
| attention layers | 16 | **8** | 2x over |
| KV bytes per layer per token | `4*256*2*2` = 4,096 | **2,176** | 1.882x over |
| KV bytes per token | 65,536 | **17,408** | **3.765x over** |

**Usable context on one FK33 goes from 61,229 to 233,396 tokens, a factor of
3.813, not the 2x the brief estimated.** MEASURED with
`python3 tools/weights_residency.py` on the migrated manifest, after the
top-anchored host and descriptor blocks are charged.

The two terms nobody had checked were wrong in two different ways:

* `6144` is 27B's `d_inner` (`lin_val_heads` 48 x `lin_head_dim` 128). The 9B is
  32 x 128 = 4096. So the GDN arena was **3x** over, not the 2x that follows
  from the layer count alone.
* `4 * 256 * 2 * 2` assumes an **int16** KV mantissa and **no record header**.
  `rtl/attn_kv_axi.vhd` stores an int8 BFP record: a 16-byte granule of block
  exponents plus `HEAD_DIM` int8 mantissas = **272 bytes**, not the 1,024 the
  constant implies. That term is wrong for the 27B too.

**233,396 tokens is still less than the model's own `max_context` of 262,144.**
Holding the full context needs 262,144 x 17,408 = 4,563,402,752 B against
4,062,965,760 B available: **short by 500,436,992 B, 477 MiB.** So one card
reaches 89 percent of the model's context, not all of it. That is a new fact and
it bears directly on the multi-card arithmetic.

---

## 3. The procedure, in the order it was run, and what each step isolates

Every step is a READ of the RTL. `rtl/**` was not modified.

1. **`git log -1`** to pin the tree. HEAD was `b28e92b`, which matched the brief
   for once; ARENA-MANIFEST had found the previous brief five commits stale.
2. **Locate the constants.** `grep -rn "KV_BYTES_PER_TOKEN\|GDN_STATE_BYTES"`
   over `*.py *.c *.h`. All four literals live in `tools/pack_model_fk33.py`
   lines 152-156 and nowhere else. This isolates *how many* places have to
   change: one.
3. **The shape.** `rtl/model_cfg_pkg.vhd` carries `QWEN35_9B` and `QWEN38_27B`
   as `model_cfg_t` records and `constant MODEL := QWEN35_9B` selects the build
   target. Its own `attn_layers`/`gdn_layers` functions give 8 and 24. This
   isolates the layer counts from everything else.
4. **The GDN state extent, from PORTS not prose.** `rtl/gdn_block.vhd`'s
   recurrent-state port group is `st_rhead : 0 to VAL_HEADS-1`,
   `st_rcol : 0 to DIM-1`, `st_rgrp : 0 to DIM/RECUR_LANES-1`,
   `st_rdata : RECUR_LANES*16 bits`. Those ranges say the array is
   `VAL_HEADS x DIM x DIM` sixteen-bit words and nothing else can be read out of
   them. Corroborated independently by `model_cfg_pkg.gdn_sweep_cycles`, whose
   body computes `lin_head_dim * lin_head_dim * val_heads_per_card`.
   **Port ranges were used deliberately in preference to the file's own header
   comment, which says "2 MiB at 9B" and is wrong** -- see the traps section.
5. **The GDN element widths.** `rtl/gdn_recur.vhd` port `s_in : in
   std_logic_vector(DIM*16-1 downto 0)` gives the mantissa width; `se_j : in
   signed(7 downto 0)` gives the per-column exponent. This isolates the width
   question from the extent question.
6. **The KV record.** `rtl/attn_kv_axi.vhd` constants `CH_B = 16` (the record
   granule), `MANT_B = HEAD_DIM*CM_W/8`, `REC_B = CH_B + MANT_B`, with generic
   `CM_W : positive := 8`. Its header states the same in prose and its
   elaboration asserts enforce it. This isolates the per-record size.
7. **The KV region extent, from a SECOND file.** `rtl/llama_top.vhd` computes
   `REC_B_C := 16 + C_HD*C_CM_W/8` and `KVREG_B := C_LAY*C_NKVH*C_MAXPOS*REC_B_C`
   for **one** region, with `C_K_BASE` and `C_V_BASE` separate. That is the
   factor 2 for K and V, stated by a file that is not `attn_kv_axi`. Two
   independent RTL sources for the same equation is what makes this conclusive
   rather than a reading.
8. **Replace the literals with a scrape.** `tools/hbm_map.py` grew
   `scrape_model_cfg()`, `scrape_build_model()`, `scrape_kv_record_terms()`,
   `scrape_gdn_state_terms()` and `arena_sizes()`. `tools/pack_model_fk33.py`
   now imports the answer. A scrape that stops matching is a hard `SystemExit`,
   following the precedent `_scrape_seam_h` already set in the same file.
9. **Teeth**, three tables: under-reservation must go red, the derived figure
   must track the shape, a broken scrape must refuse. Section 6.
10. **Migrate the shipped manifest** with a new `--write-manifest-arenas`, then
    re-run every consumer: `hbm_map` itself, `--check-c` against the real
    `pl_derive_bases()`, `weights_residency.py`, `check_hbm_stack.py`,
    `gen_layer_program.py`, and `server/seam_selftest`.

---

## 4. The evidence, as raw output

### 4.1 The derivation, printed term by term

`python3 tools/hbm_map.py <manifest> --arena`, before the migration:

```
RTL shape      rtl/model_cfg_pkg.vhd constant MODEL = QWEN35_9B
this manifest  output.weight matches QWEN35_9B

  shape          32 blocks at attn_interval 4 -> 8 attention, 24 GDN
  GDN per layer  32 val heads x 128 x 128 x 16/8 B = 1048576 B mantissas
                 + 32 x 128 x 8/8 B = 4096 B column exponents
  GDN total      24 layers x 1052672 B = 25264128 B
  KV record      16 B header + 256 x 8/8 B mantissas = 272 B
  KV per layer   2 streams (K,V) x 4 kv heads x 272 B = 2176 B/token
  KV total       8 attention layers x 2176 B = 17408 B/token

  gdn_state_bytes      manifest 75497472     derived 25264128     2.988x OVER
  kv_bytes_per_token   manifest 65536        derived 17408        3.765x OVER
```

### 4.2 The map before and after

`tools/weights_residency.py /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json`.

BEFORE (`b28e92b`, the 27B literals):

```
gdn recurrent state           0x1_0c00_6000  0x1_1080_6000      75,497,472    0.0703
kv arena 0                    0x1_1080_6000  0x1_ffad_d000   4,012,732,416    3.7371   61229 tokens at 65536 B/token, after the charge
```

AFTER:

```
gdn recurrent state           0x1_0c00_6000  0x1_0d81_e000      25,264,128    0.0235
kv arena 0                    0x1_0d81_e000  0x1_ffad_d000   4,062,965,760    3.7839   233396 tokens at 17408 B/token, after the charge
```

```
  weights   4,487,442,432 = 4.1793 GiB   (52.24% of the device)
  gdn       25,264,128
  kv        4,062,965,760 = 3.7839 GiB  ->  233396 tokens of context
  desc      159,744
  host      5,224,512

PASS  every region is aligned, in range, in one stack, and disjoint, and the
      manifest agrees with its own placements
```

**No placed tensor moved.** `gdn_state_base` is unchanged at `0x1_0c00_6000`,
because both arenas begin after `weights_end` and only their sizes changed. The
weight image resident in the card's HBM is untouched by this.

### 4.3 The migration itself

```
$ python3 tools/hbm_map.py .../qwen35-9b-mv4i-noembd/manifest.json --write-manifest-arenas
re-laid-out the GDN and KV arenas in .../manifest.json
  free_after_gdn                 4018118656 -> 4068352000
  gdn_state_bytes                75497472 -> 25264128
  gdn_state_bytes_per_layer      None -> 1052672
  gdn_state_layers               None -> 24
  kv_base                        4571815936 -> 4521582592
  kv_bytes_per_layer_per_token   None -> 2176
  kv_bytes_per_token             65536 -> 17408
  kv_layers                      None -> 8
  max_context_tokens             61311 -> 233705
  backup: .../manifest.json.bak-arenas
```

`233705` is the arena's own capacity; `233396` is what survives the 5,386,240 B
of top-anchored host and descriptor reservations, which the map charges as
309 tokens.

### 4.4 Every consumer, re-run after the migration

```
tools/hbm_map.py <m>              PASS  every region ... disjoint across all 3 allocators
tools/hbm_map.py <m> --check-c    ok  all seven derived values match server/pl_backend.c
                                  ok  10 of 10 pl_check_bases arena cases
tools/hbm_map.py <m> --self-test  TEETH PASS  (address teeth + the three new tables)
tools/weights_residency.py <m>    PASS
tools/check_hbm_stack.py <dir>    PASS no range crosses a stack boundary
                                  (7154 byte ranges checked)
tools/gen_layer_program.py --manifest <m> --x-exp 0 --outdir <scratch>   rc 0, 313 files
server/seam_selftest              SEAM_SELFTEST PASS  (84 checks, 0 failed)
```

The C-side invariants in `server/fk33_manifest.c` all still hold on the new
layout: `kv_base >= gdn_state_base + gdn_state_bytes`, `gdn_state_base >=
weights_end`, `desc_arena_base >= kv_base`.

---

## 5. What the correct reservation is, with the arithmetic shown

DERIVED. `QWEN35_9B` from `rtl/model_cfg_pkg.vhd`: `blocks = 32`,
`attn_interval = 4`, `lin_val_heads = 32`, `lin_head_dim = 128`,
`attn_kv_heads = 4`, `attn_head_dim = 256`, `max_context = 262144`. `NCARDS = 1`.

```
attn_layers = 32 / 4                      = 8
gdn_layers  = 32 - 8                      = 24

GDN state mantissas per layer
  = lin_val_heads * lin_head_dim * lin_head_dim * (16/8)
  = 32 * 128 * 128 * 2                    = 1,048,576 B
GDN state column exponents per layer
  = lin_val_heads * lin_head_dim * (8/8)
  = 32 * 128 * 1                          =     4,096 B
GDN state per layer                       = 1,052,672 B
GDN state arena  = 24 * 1,052,672         = 25,264,128 B   (24.09 MiB)

KV record   = CH_B + attn_head_dim * CM_W/8
            = 16 + 256 * 1                =       272 B
KV per attention layer per token
            = 2 (K and V) * attn_kv_heads * REC_B
            = 2 * 4 * 272                 =     2,176 B
KV per token = 8 * 2,176                  =    17,408 B
```

Placement, with `weights_end = 4,496,318,464` unchanged:

```
gdn_state_base = 4,496,318,464            (already 4 KB aligned, stack 1)
kv_base        = 4,496,318,464 + 25,264,128
               = 4,521,582,592            = 0x1_0D81_E000
free           = 8,589,934,592 - 4,521,582,592
               = 4,068,352,000 B
arena capacity = 4,068,352,000 / 17,408   = 233,705 tokens
less the top-anchored host + descriptor blocks, 5,386,240 B = 309 tokens
usable context                            = 233,396 tokens
```

Against the previous 61,229: **3.813x**, +172,167 tokens.

### The GDN exponent table is DELIBERATELY over-reserved, and it is 5 tokens

`gdn_block.vhd`'s header calls the state exponent table "a combinational read...
small enough to be distributed RAM", so it may never touch HBM at all. It is
reserved anyway: 24 x 4,096 = 98,304 B, which is **5 tokens of context**. Buying
certainty at a silent-corruption boundary for 5 tokens is not a trade worth
thinking about, and the teeth row `gdn_arena_mantissas_only_no_exponent_table`
is RED on purpose so that a later reader does not "optimise" it back.

---

## 6. Teeth

`python3 tools/hbm_map.py <manifest> --self-test`. Every row's verdict was
written down before it ran. The pre-existing address-teeth table is unchanged
and still passes; these three tables are new.

```
ARENA SIZE TEETH  (oracle: rtl/model_cfg_pkg.vhd, not a constant)
mutation                                                  want   got   n  verdict
kv_per_token_one_byte_under_the_shape                      RED   RED   1  ok
kv_per_token_one_attention_layer_short                     RED   RED   1  ok
kv_per_token_sized_for_int8_but_without_the_record_header  RED   RED   1  ok
gdn_arena_one_byte_under_the_shape                         RED   RED   1  ok
gdn_arena_one_layer_short                                  RED   RED   1  ok
gdn_arena_mantissas_only_no_exponent_table                 RED   RED   1  ok
both_arenas_exactly_the_derived_size                     green green   0  ok
the_27b_literals_this_track_replaced_are_over_not_under   green green   0  ok
arena_keys_absent_entirely                               green green   0  ok
shape_matches_no_model_cfg_record                        green green   0  ok

DOES THE DERIVED FIGURE TRACK THE SHAPE
  ok    27B gdn layers reproduce the removed GDN_STATE_LAYERS      48
  ok    27B gdn mantissas reproduce the removed 6144*128*2         1572864
  ok    27B attention layers reproduce the removed KV_LAYERS       16
  ok    9B gdn layers are 24, not 48                               24
  ok    9B attention layers are 8, not 16                          8
  ok    9B gdn mantissas are 4096*128*2, not 6144*128*2            1048576
  ok    the KV record is 272 B at BOTH scales (head dim 256, int8) (272, 272)
  ok    only the layer count moves the KV per-token figure         (17408, 34816)
  ok    NCARDS=2 halves the GDN arena                              75792384
  ok    NCARDS=2 halves the KV per-token figure                    34816

DOES A BROKEN SCRAPE HARD-FAIL
  ok    model record renamed away                                   refused
  ok    a field dropped from the record                             refused
  ok    the aggregate turned positional                             refused

TEETH PASS  every mutation gave the verdict written down for it before it ran
```

**The sharpest row is `27B gdn mantissas reproduce the removed 6144*128*2`.**
`arena_sizes(QWEN38_27B)` computes 1,572,864 B/layer from the record alone,
which is bit for bit the literal that was deleted. That is not a coincidence to
be noted in passing: it is the proof that `6144` was a **different model's**
figure rather than merely a stale one, and it is the only kind of evidence that
distinguishes the two.

### Rows that do NOT bite, under their own names

These are the resolution floor and they are the reason the table is worth
re-reading.

* **`the_27b_literals_this_track_replaced_are_over_not_under` stays GREEN.** The
  defect this track fixed does not fail the check that now exists. It cannot:
  over-reservation wastes capacity and corrupts nothing, so making it a fault
  would fail a safe configuration and train people to ignore the check. The
  defect is reported as a NOTE with the factor and the token cost, and it is
  only visible at all because someone reads the note. **A check that goes red on
  the wrong direction of this error is not available, and none was written.**
* **`arena_keys_absent_entirely` stays GREEN.** A manifest that declares neither
  size is not checked. Every shipped manifest declares both, but a synthetic one
  need not, and refusing would break `fk33_load_weights.py`'s selfcheck images.
* **`shape_matches_no_model_cfg_record` stays GREEN.** The check is gated on the
  lm_head's `(K, M)` matching a `model_cfg_t` record, which is the only shape
  evidence a manifest carries that this file did not compute. A manifest for a
  model the RTL does not know is reported unchecked, not refused.
* **The whole class of "right size, wrong contents" is invisible here and always
  will be.** `hbm_map` sees sizes and addresses. A KV arena of exactly 17,408
  B/token that the RTL fills in a different order is not something any of this
  can see.

---

## 7. Measured and REJECTED -- do not retry

* **Do not re-derive the GDN state size from `gdn_block.vhd`'s header comment.**
  It says the recurrent state is "DIM\*DIM\*VAL_HEADS int16 per layer, **2 MiB at
  9B**". `128 * 128 * 32 * 2 = 1,048,576 B = 1 MiB`. The formula in that same
  sentence is right and the byte figure beside it is wrong by 2x. It is not the
  27B figure either (that would be 1.5 MiB). Use the port ranges. The exponent
  table in the next paragraph of the same header (`VAL_HEADS*DIM bytes, 4 KiB at
  9B`) IS correct, so the file is not uniformly untrustworthy -- which is worse,
  because it means agreement with one line of it proves nothing about the next.
* **Do not use `model_cfg_pkg.vhd`'s own KV capacity comment.** It says
  "262,144 context is 8.59 GB of KV cache" for the 27B. That is 32,768 B/token,
  which is neither the old constant (65,536) nor the RTL record (34,816 at the
  27B shape). It is a **third** inconsistent figure, in the very file this track
  used as the shape oracle. The shape RECORD in that file is authoritative; its
  prose is not.
* **Do not size the KV cache as `kv_heads * head_dim * 2 * 2`.** That is
  `4*256*2*2 = 4096` and it assumes int16 mantissas with no header. The RTL is
  int8 with a 16-byte block-exponent header: `4 * (16+256) * 2 = 2176`. The
  teeth row `kv_per_token_sized_for_int8_but_without_the_record_header` exists
  specifically to catch the half-fix where someone changes the width to int8 and
  forgets the header, which would give 2,048 B/layer and **under**-reserve by
  128 B per layer per token. That is the dangerous direction.
* **Do not try to run a real pack to validate this.** ARENA-MANIFEST already
  recorded that it needs the 18 GB GGUF and hours on a 39 G root. The functions
  were exercised directly instead, and the migration path
  (`--write-manifest-arenas`) exists because a repack is not available.
* **Do not point `tools/gen_layer_program.py` at the default manifest set.** The
  default `qwen35-9b-mv4i` fails loudly (its `blk.7.ffn_gate.weight.mv4i`
  straddles the stack line). Always pass `--manifest`, and use
  `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd`. Confirmed still true here.

---

## 8. Measurement traps hit, including my own

* **I nearly used `pack_int4.py`'s residency estimate as a second source.**
  `tools/pack_int4.py:792` restates `n_gdn, n_attn = 48, 16` and
  `d_inner, state_size = 6144, 128` in a printed capacity report. It agrees with
  the packer's constants **because it is the same wrong model**, not because two
  independent derivations converged. Two documents agreeing is the failure mode
  this project has on record; it would have read as confirmation.
* **`61,231` vs `61,229` vs `61,311`.** The brief quoted 61,231 tokens from
  TRACK WEIGHTS. The manifest's own `max_context_tokens` was 61,311 (arena
  capacity, before the top-anchored charge) and the map reports 61,229 (after).
  All three are the same layout measured at three points. I used the after-charge
  figure throughout because it is the only one that is a context you can actually
  use. ARENA-MANIFEST already noted the 61,231/61,229 discrepancy.
* **Hand arithmetic disagreed with the code by one token.** I computed
  `4,068,352,000 // 17,408 = 233,704`; the code says 233,705. The code is right.
  Every capacity figure in this document is the tool's, not mine.
* **A one-byte-under teeth row is not obviously going to bite.** It does, because
  the check is `got < want` on an exact integer, but that had to be run rather
  than assumed: a check written with a tolerance or a page rounding would have
  passed it silently, and a reservation one page short is still corruption.

---

## 9. Corrections to the brief and to earlier write-ups

Appended, not edited into place.

1. **The GDN arena was 3x over, not 2x.** `docs/debugging/2026-08-29_arena-manifest-the-region-block.md`
   says "72 MiB of GDN state where **36 MiB** is used". The used figure is
   **24.09 MiB** (25,264,128 B). That write-up caught the layer count and
   explicitly said the per-layer term was unverified; the per-layer term was also
   a 27B figure, so the two errors multiply. Its statement stands as *"reserved
   for a different model"* and is withdrawn only as to the magnitude.
2. **The KV arena was 3.765x over, not 2x**, for the same reason: the record is
   272 B (int8 + header) and not 1,024 B (int16, no header). ARENA-MANIFEST's
   "twice the bytes per token the shape needs" is **withdrawn**; the correct
   statement is 3.765 times.
3. **The context does not double to ~122,000. It goes to 233,396,** a factor of
   3.813. The brief's estimate followed from correction 2 and is superseded.
4. **`tools/pack_int4.py:792` still carries the 27B literals** in its printed
   residency estimate (`n_gdn, n_attn = 48, 16`, `d_inner, state_size = 6144,
   128`, and an int16 KV assumption). That file is not this track's and was not
   touched. It now disagrees with the packer. Whoever owns it should replace
   those six numbers with `hbm_map.arena_sizes()`.

---

## 10. Open, not yet answered

* **`attn_kv_axi` computes a LINEAR address from one base; the packer splits the
  KV region at the 4 GiB stack line.** At this layout the whole KV region lives
  in stack 1 (`0x1_0D81_E000` up to `0x1_FFAD_D000`), so the two views agree and
  `check_hbm_stack.py` passes. That is a property of THIS layout, not a
  guarantee. A future shape whose weights end lower would put `kv_base` below the
  line and the RTL would happily compute an address straight through it. Nothing
  checks this today.
* **The KV arena's sub-structure is still DECLARED and not ALLOCATED.** The
  manifest now states `kv_layers`, `kv_bytes_per_layer_per_token` and
  `kv_record_bytes`, but nothing places a per-(layer, head, position) slot, so
  nothing can check one. Same for the GDN state. That was true before this track
  and remains true.
* **Whether the GDN state exponent table reaches HBM at all** is not determined.
  It is reserved. See section 5.
* **The three other packed sets were not migrated.** `qwen35-9b-mv4i`,
  `qwen35-9b-mv4i-qkvpad` and `qwen35-9b-mv4i-stackfix` still carry the 27B
  figures and now report the over-reservation as a note. Migrate any of them with
  `python3 tools/hbm_map.py <path>/manifest.json --write-manifest-arenas`. Only
  `-noembd` was migrated, to keep the blast radius to the set the project
  actually uses.
* **`NCARDS > 1` is derived but not exercised.** `arena_sizes(cfg, ncards)`
  divides the value heads and the KV heads and the teeth show it halving both
  arenas at `ncards=2`, but nothing in the repository packs for more than one
  card yet.

---

## 11. For Oren: subsystem C's KV memory-map generics, reported not set

TRACK REALFIX STOPPED on this and escalated it: `rtl/llama_top.vhd`'s
`C_KV_BLOCK` 4, `C_K_BASE` 16, `C_V_BASE` 4064, `C_KV_ADDR_W` 16, `C_MAXPOS` 4
are scaled-shape values and every one is illegal at `attn_head_dim` 256. That is
a residency-map decision, and this track was told to report values rather than
set them. **Nothing in `rtl/**` was modified.** These are DERIVED from the same
RTL constraints, at the migrated layout:

| generic | now | proposed | why |
|---|---|---|---|
| `C_KV_BLOCK` | 4 | **32** | `attn_kv_axi` needs `KV_BLOCK*CM_W/8` a multiple of 16 (so >= 16) and `NBLK = HEAD_DIM/KV_BLOCK <= 16`; `attn_block` needs `NBLK >= 2`. Legal set at HEAD_DIM 256 is {16, 32, 64, 128}. 32 gives NBLK 8 and is what C spec 2.1.1 and `attn_kv_axi`'s own header state. |
| `C_MAXPOS` | 4 | **131072**, or 233396 to the limit | 131,072 is a clean power of two with headroom; 233,396 is the ceiling this layout affords. **262,144, the model's `max_context`, does NOT fit** -- it needs 4,563,402,752 B against 4,062,965,760 available, short by 477 MiB. |
| `C_K_BASE` | 16 | **4,521,582,592** (`0x1_0D81_E000`) | `hbm.kv_base` in the migrated manifest. |
| `C_V_BASE` | 4064 | **`C_K_BASE + 8704*C_MAXPOS`** | one region is `attn_layers * kv_heads * MAXPOS * REC_B` = `8*4*272*MAXPOS` = `8704*MAXPOS`. At 131,072 that is 1,140,850,688, so `C_V_BASE = 5,662,433,280` (`0x1_5181_E000`). Always a multiple of 16, which is the format's only alignment requirement. |
| `C_KV_ADDR_W` | 16 | **33** | `llama_top` asserts `clog2(max(K,V base) + KVREG_B) <= C_KV_ADDR_W`. At `C_MAXPOS` 131,072 the pair ends at `0x1_9581_E000` and `clog2` of that is 33. 33 also covers the whole 8 GiB device, so it does not move with `C_MAXPOS`. |
| `C_CTXLEN` | 1 | `<= C_MAXPOS` | unchanged constraint; it bounds the run and does not enter the arithmetic. |
| `attn_block`'s `LAYERS` | 16 | **8** | attention layers at the 9B shape. 16 is the 27B's, the same defect as `KV_LAYERS`. |

At `C_MAXPOS` 131,072 both regions sit inside HBM stack 1
(`0x1_0D81_E000` .. `0x1_9581_E000`), clear of the 4 GiB line and clear of the
descriptor arena at `0x1_FFAD_D000`. At 233,396 they end at `0x1_FFADB000`,
2,048 B below the descriptor arena, which is correct but leaves no margin at all.

---

## 12. What changed

* `tools/hbm_map.py` -- new: `scrape_model_cfg`, `scrape_build_model`,
  `scrape_kv_record_terms`, `scrape_gdn_state_terms`, `arena_sizes`,
  `arena_arithmetic`, `shape_of_manifest`, `check_arenas`, `relayout_arenas`,
  `write_arenas`, `_arena_teeth_cases`, `_arena_shape_teeth`,
  `_arena_scrape_teeth`, `run_arena_teeth`; CLI `--arena`,
  `--write-manifest-arenas`, `--ncards`. `plan()` now folds `check_arenas()`
  into the map's fails and notes.
* `tools/pack_model_fk33.py` -- the four literals are gone; the six constants
  now come from `HM.arena_sizes()`. `check_arena_substructure()` changed meaning:
  it now hard-fails if `gen_layer_program.QWEN35_9B` disagrees with the RTL
  record the arenas were sized from, which is a real cross-oracle check rather
  than a literal-versus-program one.
* `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json` -- arenas
  re-laid-out, `.bak-arenas` alongside. Not in the repository.
* No `rtl/**` file was read-only-violated. No `sim/tb_*.vhd` was added. No
  hardware was touched.
