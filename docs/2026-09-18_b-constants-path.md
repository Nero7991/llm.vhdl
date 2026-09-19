# The B constants path: the model's learned GDN constants reach the card through HBM

Written 2026-09-18 22:40, the interface contract for four parallel tracks.
Background and the measurement that forced it:
`docs/debugging/2026-09-18_the-card-runs-subsystem-b-on-stand-in-inputs-and-weights.md`.

**The RTL wins over this document where they disagree, and a track that finds
a disagreement fixes the document in the same commit.**

## What is being built

Subsystem B has four learned constants per GDN layer that today are `m12`
stand-ins in every configuration of `rtl/llama_top.vhd` (`:4068-4071`):

| constant | GGUF tensor | shape | max abs (9B, MEASURED) |
|---|---|---|---|
| conv weights | `blk.L.ssm_conv1d.weight` | [KCONV=4][QKVN=8192] | 1.234 |
| dt bias | `blk.L.ssm_dt.bias` | [VAL_HEADS=32] | 18.5 |
| A (already `-exp(A_log)`) | `blk.L.ssm_a` | [32] | 77.0 |
| ssm norm weight | `blk.L.ssm_norm.weight` | [DIM=128] | 1.318 |

A 1.5 MiB ROM does not fit (449.5 of 672 BRAM tiles used; ~341 more would be
needed), so they are packed per layer into an HBM region and loaded into the
resident tier by `rtl/gdn_state_store.vhd` as a FOURTH, load-only phase of the
existing per-job sequence (mantissas, exponents, conv taps, then constants).
The same mechanism at the sim shape gives the benches and the oracle one file
to agree on.

Two more things ride along and are NOT part of the HBM path:

- `B_SRC_REAL=true` on the card (taps, alpha, beta from the regions; verified
  with the tier on 2026-09-05).
- `NORM_W_IMAGE` = the 9B norm-gain image, an elaboration-time table
  (`sim/ooc_nwrom_gen_image.py` already writes it; ~114 BRAM).

## Fixed-point conventions (from the RTL, do not re-derive)

Every exponent `e` is a COUNT OF FRACTION BITS: `value = mant * 2^-e`.
`gdn_scalar.to_q_wide(m, e)` moves Q(e) to Q(SP_Q) with `sh = e - SP_Q`
(`rtl/gdn_scalar.vhd:161-173`, negative `sh` is a left shift); `gdn_conv` sets
`e_acc = e_ref + cw_exp` (`rtl/gdn_conv.vhd:9`). The stand-ins use `e = 12`
everywhere. The packer chooses `e` PER VECTOR PER LAYER as the largest value
with `max|v| * 2^e <= 32767`, clamped to `[-64, 63]`, and records it in the
image, so the RTL never assumes a scale. Expected at 9B: conv 14, dt 10, a 8,
norm 14. Track D verifies each unit accepts those ranges.

**CORRECTION 2026-09-18 (track B, MEASURED by `tools/pack_gdn_consts.py` on
the shipped GGUF): the four figures above are the per-MODEL minima, i.e. the
exponent of the layer whose vector is largest, and the per-layer values run
HIGHER because most layers' vectors are smaller.** The per-layer ranges are
conv (per segment) 14..17, dt 10..12, a 8..17, norm 14..15; `ssm_a` spans
0.143 (blk.0, `a_e` 17) to 77.0 (blk.12, `a_e` 8). At the sim shape the
sliced vectors are smaller still: over all 24 layers cw_exp reaches 19, a_e
18, dt_e 13 and w_exp 15. So the range a unit must accept is `[8, 19]` for
what this model produces at either shape, and `[-64, 63]` for what the image
format can carry. The full per-layer table is in the manifest's
`hbm.gdn_const_exponents` and is printed by the packer.

## The HBM region `gdn_const`

Manifest keys (`hbm` section), allocated by `tools/hbm_map.py`:

```
gdn_const_base              4 KiB aligned, in the free area below desc_arena_base
gdn_const_layers            24     (= gdn_state_layers)
gdn_const_bytes_per_layer   66048  (= 129 bursts of 512 B; 16-beat AXI3 bursts at 32 B)
gdn_const_bytes             1585152
gdn_const_stack             1
gdn_const_words_per_layer   33024  (= CONST_WORDS)
gdn_const_file              "gdn_const.bin"   relative to the manifest's directory
gdn_const_blake2b_128       the image's digest, what fk33_load_weights.py verify compares
gdn_const_exponents         [[cw_q, cw_k, cw_v, dt_e, a_e, w_exp] per layer]
```

MEASURED 2026-09-18 on `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd`:
`gdn_const_base = 0x1_FF95_A000`, so the image ends exactly at
`desc_arena_base = 0x1_FFAD_D000`. **The image is declared in `hbm`, NOT as
a `files` entry**, because every other reader of `files`
(`tools/check_hbm_stack.py`, `tools/check_mv4i_set.py`) parses a non-`f32blob`
entry as an mv4i header and the image has none; the loader synthesises the
entry itself (`fk33_load_weights.const_entries()`). **The KV extents are
RE-CAPPED at `gdn_const_base`** and `free_after_gdn` / `max_context_tokens`
recomputed (233,638 -> 233,237 tokens), because the image is paid for out of
the KV arena's top like the descriptor arena and the host blocks; before this
the manifest's figure counted 310 tokens of KV the host blocks already
occupied. `server/fk33_manifest.c` reads `gdn_const_base` / `gdn_const_bytes`
as the ONLY optional pair in its struct (a set packed before the image reads
0 and `pl_open` warns rather than refusing; see the header comment for why).

Layer L's image is at `gdn_const_base + L * 66048`, L being the SAME index
the B job carries (`js_layer`, 0..23 over the GDN layers only).

Per-layer image, byte offsets, every field little-endian int16:

```
0x00000 .. 0x0FFFF  conv weights: word[t*QKVN + ch] = W[ch][t]
                    t = 0 OLDEST tap .. KCONV-1 NEWEST (this token's column),
                    the order gdn_conv and cvdata_p use; GGUF flat index is
                    cw[ch*KCONV + t] (ref/run9b.c:612-613).
                    ch in q|k|v channel order: q 0..2047, k 2048..4095,
                    v 4096..8191 (R_QKV's order, cvdata_p's sbase).
0x10000 .. 0x1003F  ssm_dt_bias[32]   Q(dt_e)
0x10040 .. 0x1007F  ssm_a[32]         Q(a_e), every value <= 0
0x10080 .. 0x1017F  ssm_norm[128]     Q(w_exp)
0x10180             cw_exp[0] (q segment)     int16
0x10182             cw_exp[1] (k segment)     int16
0x10184             cw_exp[2] (v segment)     int16
0x10186             dt_e                      int16
0x10188             a_e                       int16
0x1018A             w_exp                     int16
0x1018C .. 0x101FF  zero
```

As 16-bit WORDS for the mover: `CONST_WORDS = KCONV*QKVN + 256 = 33024`;
word `w` at byte `2w`. Words `>= KCONV*QKVN` (32768) are the scalar block:
32768 dt, 32800 a, 32832 norm, 32960 the six exponents, then zero.

At the SIM shape (`mk_shape_scaled`) the same layout holds with that shape's
KCONV, QKVN, VAL_HEADS and DIM; the scalar block is still 512 B and the
per-layer size is `2*KCONV*QKVN + 512`, which the packer must keep a multiple
of 512.

## Track ownership and interfaces

### Track A: the store (`rtl/gdn_conv_w_mem.vhd` NEW, `rtl/gdn_state_store.vhd`, `sim/tb_gdn_conv_w_mem.vhd` NEW, `sim/tb_gdn_state_store.vhd`)

`gdn_state_store` gains:

```vhdl
generic  CONST_EN     : boolean  := false;   -- the fourth phase exists
         CONST_STRIDE : positive := 66048;   -- gdn_const_bytes_per_layer
         CONST_BYTES  : positive := 66048;   -- bytes moved per layer (= stride)
port     const_base : in  std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
         -- the conv WEIGHT face, addressed exactly like cv_seg/cv_grp and with
         -- the same timing (address sampled on the edge, data valid next cycle):
         cw_seg  : in  integer range 0 to 2;
         cw_grp  : in  natural range 0 to (VAL_HEADS*DIM)/CONV_LANES-1;
         cw_w    : out std_logic_vector(KCONV*CONV_LANES*16-1 downto 0);
         -- bit slice (t*CONV_LANES+ln)*16 +: 16 is tap t, lane ln, t=KCONV-1 newest
         cw_exp  : out std_logic_vector(3*8-1 downto 0);  -- seg s at s*8 +: 8, signed
         -- the scalar block, LEVELS, valid from the end of the load phase:
         sc_dt_m : out std_logic_vector(VAL_HEADS*16-1 downto 0);
         sc_a_m  : out std_logic_vector(VAL_HEADS*16-1 downto 0);
         sn_w    : out std_logic_vector(DIM*16-1 downto 0);
         sc_dt_e, sc_a_e, sn_exp : out signed(7 downto 0);
```

- A fourth `gdn_state_axi` instance at `VAL_HEADS => 1, DIM => CONST_WORDS,
  N_GRP => 1, WORD_BITS => 16, LAYER_STRIDE => CONST_STRIDE,
  MANT_BYTES => CONST_BYTES`, `state_base => const_base`, LOAD ONLY (its
  `save_start` is never pulsed; a save job skips the phase). `sel` grows to
  cover it; the AXI 4:1 keeps the forced-low rule.
- Words `< KCONV*QKVN` go to `gdn_conv_w_mem`, a copy of
  `gdn_conv_tap_mem` with KCONV slots, NO rotation, NO unit write port, the
  mover's flat address `t*QKVN + ch` decomposed the same way. Words
  `>= KCONV*QKVN` go to the scalar registers (a plain decoded register file;
  the exponents are the low byte of their words, sign-extended).
- `CONST_EN = false` must be BIT-IDENTICAL to today: no fourth phase, the new
  outputs driven to the stand-in-free constants (zeros). Existing rows
  `tb_gdn_state_store`, `tb_llama_top_bstate*` must not move.
- The store's elaboration refusals extend: `CONST_BYTES = 2*CONST_WORDS`,
  `CONST_BYTES mod 512 = 0`, `CONST_STRIDE >= CONST_BYTES`.
- Bench: load an image with known contents through the AXI model, read every
  (seg, grp) back through `cw_w`, every scalar, every exponent; a save must
  not touch the const region; a second load of another layer replaces all of
  it. Teeth: a mutant that skips the phase, one that swaps tap order, one that
  drops the scalar decode. Report the mutants that do NOT bite.

### Track B: packing, arena, host (`tools/pack_gdn_consts.py` NEW, `tools/hbm_map.py`, `hw/fk33/host/fk33_load_weights.py`, `hw/fk33/host/fk33ctl.py` load path only, `server/pl_backend.c`, `tools/tests` for the packer)

LANDED 2026-09-18. What was built differs from the lines below in the ways
marked **(as built)**.

- `tools/pack_gdn_consts.py --gguf G --manifest M --out DIR/gdn_const.bin
  [--hex PATH] [--shape 9b|sim] [--check]`: writes the image above for every
  GDN layer in schedule order, updates the manifest's `hbm` keys through
  `hbm_map.py`'s allocator (NOTHING already placed moves: weights, gdn_state,
  kv_base, desc arena, host areas), and records `gdn_const_blake2b_128` for
  verification. `--check` re-derives and compares. The chosen exponents are
  printed per layer.
  **(as built)** `--hex PATH` also writes the SAME image as text: one 16-bit
  word per line as 4 hex digits two's complement, word index order (word 0
  first, i.e. the `.bin`'s little-endian words in order), all layers back to
  back, no header, so a VHDL textio loader reads it the way
  `rtl/llama_top.vhd` reads `NORM_W_IMAGE`. The 9B hex is 792,576 lines. The
  allocator is `hbm_map.derive_gdn_const_block()`, the only function that
  chooses the address; `--out` must be beside the manifest, since the loader
  resolves `hbm.gdn_const_file` relative to it. The packer's test is
  `--selftest` (no GGUF, no manifest); the gate row to add is
  `[gdnconst]="python3 $REPO/tools/pack_gdn_consts.py --selftest"` in
  `sim/regress.sh`'s `SELFCHECK_CMD`, plus its plan line and `run_one` case.
- `--shape sim` packs the SAME layout at `mk_shape_scaled` from a reduced
  gain (reuse `tools/gen_llama_top_weights.py`'s reduction rules) so track D
  can feed `tb_llama_top` and the oracle from one file.
  **(as built)** `--shape sim [--blocks 4] [--attn-interval 4]
  [--norm-reduce mean|slice]`, no manifest: 2,560 B per layer (5 bursts;
  KCONV 4 x QKVN 256 x 2 B + 512 B scalar block; dt at word 1024, a at 1028,
  norm at 1032, the six exponents at 1064..1069, zero to 1279), 3 layers =
  7,680 B at the default 4 blocks, 24 layers = 61,440 B at 32. The conv
  weights, dt and a are ROW SLICES of the 9B tensors (sim channel c of
  segment s is real channel `[0, 2048, 4096][s] + c`, sim head h is real
  head h), which is how `gen_llama_top_weights.py` cuts the A jobs those rows
  belong to; only the ssm_norm gain goes through `reduce_gain()`.
- `hbm_map.py`: the region appears in the map/`Region` listing and in
  `arena_sizes()`; `max_context_tokens` is recomputed.
  **(as built)** kind `gdn_const`, owner `pack_gdn_consts.py`; the KV extents
  are re-capped at the region (see the region section); `check_arenas()`
  refuses a wrong `gdn_const_bytes_per_layer` outright, not only a short
  region, because a wrong stride serves layer L another layer's constants
  with every address still aligned and disjoint. `--self-test` gained five
  address rows and six size rows; `--gdn-const` prints the derivation.
- `server/pl_backend.c`: after writing `FK33_SEAM_BST_LO/HI`, write
  `FK33_SEAM_BCB_LO/HI` from `hbm.gdn_const_base` (the defines land in
  track C's `server/fk33_seam.h`; if they are not there yet, wait for that
  commit, do not define them locally). `fk33_load_weights.py`/`fk33ctl load`
  must load and verify the image with the weights.
  **(as built)** reaching `hbm.gdn_const_base` from C needed three files the
  ownership list did not name and no other track owns:
  `server/fk33_manifest.h/.c` (the optional pair, checked as a region when
  present) and `server/pl_backend.h` (`pl_open_opts.gdn_const_base`, which
  outranks the manifest like the other two bases). A 33-bit overflow is a
  refusal; an ABSENT base is written as 0 with a capitalised warning, not
  refused, because refusing would make every pre-image set unopenable on
  every card including the ones that ignore the register. `fk33ctl load|verify
  FILE --manifest M` takes the offset and the pack-time digest from the
  manifest for the file it names (today only the constant image) and refuses
  a disagreeing `--offset`; `fk33_load_weights.py load|verify|plan` place and
  digest the image with the 250 weight objects, digesting it even under
  `--headers-only` (the `f32blob` policy).

### Track C: the seam and the card generators (`rtl/fk33_seam.vhd`, `sim/tb_fk33_seam.vhd`, `server/fk33_seam.h`, `server/fk33_sim.c`, `tools/check_seam_regs.py`, `hw/fk33/gen_pcieep.py`, `hw/fk33/gen_fk33_card.py`, `tools/gen_cardtop.py` if a pattern needs it)

- Seam registers `A_BCB_LO = 16#84#` (RW, `bst_const_base[31:0]`) and
  `A_BCB_HI = 16#88#` (RW, bit 32), port `d_bcb_base : out
  std_logic_vector(32 downto 0)`, exactly as `A_BST_LO/HI` and `d_bst_base`.
  Host defines `FK33_SEAM_BCB_LO 0x84u`, `FK33_SEAM_BCB_HI 0x88u`; the
  drift table in `check_seam_regs.py` and `fk33ctl.py`'s `seam` print gain
  the pair; `fk33_sim.c` models it. Bench: write/readback and that the port
  follows the register.
- `gen_pcieep.py`: `("d_bcb_base", "bst_const_base")` beside
  `("d_bst_base", "bst_state_base")`, and the unconnected-input check must
  see it connected.
- `gen_fk33_card.py`: add `B_SRC_REAL=true`, `B_CONST_HBM=true`, and
  `NORM_W_IMAGE=<absolute repo path>/hw/fk33/gen/norm_w_9b.hex` (track E
  writes that file; wait for it to exist before adding the line, and the
  generated `fk33_card.vhd` must be regenerated and committed). The
  `bst_const_base` port on `fk33_llama_top` is track D's; until it lands,
  the generator's port pass-through is unchanged, so add the generics and the
  seam wire first and regenerate again after D.

### Track D: `rtl/llama_top.vhd`, `sim/tb_llama_top.vhd`, `sim/tb_llama_top_bstate*.vhd`, `tools/ref9b/gdn_oracle.py`, `rtl/fk33_llama_top.vhd` via `tools/gen_cardtop.py` (the dispatcher's own track, not delegated)

- Generic `B_CONST_HBM : boolean := false` (requires `B_STATE_AXI`; refuse
  otherwise with the out-of-range-natural idiom), port `bst_const_base : in
  std_logic_vector(32 downto 0) := (others => '0')`.
- `gen_st_tier` passes `CONST_EN => B_CONST_HBM`, `const_base`, and wires the
  new faces; `cvdata_p` takes `wv` from `st_cw_w` (same bit order), `cvsq`
  takes `cv_cw_exp` from `st_cw_exp(cv_seg)`, `scdrv` takes dt/a mantissas
  and exponents from the store, `wdrv` takes `w_mant`/`w_exp` from it, all
  under `if B_CONST_HBM`, the `m12` branches untouched otherwise.
- `tb_llama_top`'s `bst_slave` memory grows by the const region and is
  initialised from the packed sim-shape image when `B_CONST_HBM`;
  `gdn_oracle.py --b-const IMAGE` reads the same file instead of
  `conv_weights()/scalars_synth()/ssm_norm_w()`.

### Track E: the norm image (`hw/fk33/gen/norm_w_9b.hex` NEW, `sim/ooc_nwrom_gen_image.py`, a `--check` row in `sim/regress.sh`)

- Generate the 9B image (65 x 4096, `NORM_W_EXP = 12`) with the existing
  generator, commit it, add a gate row that regenerates and diffs.
- Confirm the BRAM cost from `docs/debugging/2026-08-29_nwrom-norm-gain-image-area.md`
  and, if that measurement is not at the exact committed image, re-measure
  by OOC synthesis ON THE BC-250 (sync first; one Vivado there, none here).
