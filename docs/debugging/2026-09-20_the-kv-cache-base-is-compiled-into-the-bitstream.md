# The KV cache base is compiled into the bitstream, so the striped image is overwritten by C

Date: 2026-09-20. Bitstream `hw/fk33/bit/fk33_card_swg_75mhz_2026-09-20.bit`
(`8dbe160`, tagged `v3.0-first-answer`), 75 MHz core, FK33 card. Image:
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/` (lane-striped,
`pack_model_fk33.py --stripe-lanes`, same bytes and digests as the flat image).

## The question

"The striped image runs token 0 in 30.1 M cycles (0.402 s, 2.05x faster than
flat) but the argmax is 111007 against the reference 846, while every one of
the 32 blocks' XN probes matches to the argmax. `fk33_load_weights.py verify`
after the token reports 41 objects whose HBM bytes no longer match the file.
Descriptor bases are correct. What is writing over the weights?"

## The answer

**Subsystem C's KV cache base is a build-time generic derived from the FLAT
manifest** (`hw/fk33/gen_fk33_card.py:322-323`: `C_K_BASE_CH=282672640`,
`C_V_BASE_CH=353975808`, i.e. K at `0x10D93E000` and V at `0x15193E000`, each
32 (layer, head) slots of `C_MAXPOS * 272 = 0x2200000` bytes). The striped
manifest places its KV cache at `0x1AD71C000` and puts stack-1 lane arenas in
segments 17..29, so every C job writes its records into weight pieces. The 64
compiled slot heads (position 0) predict the failing object list EXACTLY: the
40 objects that fail are precisely the objects holding a slot head, and every
slot head that lands in free space is clean (0 missed, 0 extra, at any token
count from 1 to 8).

B's state base is a seam register (`0x74/0x78`) and followed the manifest;
the KV base never had one. This is the third HBM base found hard-wired or
unconnected in three days (`2026-09-18_two-hbm-bases-were-never-connected.md`
covered the arena and the B state).

## Procedure

1. `fk33_load_weights.py verify` on the striped manifest after tokens ran:
   41 FAIL lines (40 distinct objects, `output.weight` twice), saved as
   `verify_after.log`. Isolates: which bytes changed, not who changed them.
2. Two differing extents were located to the byte inside lm_head window 6:
   `0x14087c000 + 794624 = 0x14093E000` (lane 18) and
   `0x111cb2000 + 573440 = 0x111D3E000` (lane 25). Both end in `...3E000`,
   which is the compiled K base's low bits. Isolates: a writer with a fixed
   base, not a descriptor error (descriptor bases had been checked against
   the pieces and the file).
3. Manifest regions (gdn_state, kv, gdn_const, arena) were checked against
   every piece: no overlap. Isolates: the manifest's own map is consistent, so
   the writer is not using the manifest.
4. The two HBM writers are B's state store (seam register) and C's KV cache.
   `grep -n "K_BASE\|V_BASE" hw/fk33/gen_fk33_card.py rtl/llama_top.vhd`:
   generics, values from the flat manifest.
5. Falsification test: compute the 64 slot heads `K + i*0x2200000`,
   `V + i*0x2200000` and intersect `[slot, slot + ntok*272)` with every piece
   of the striped manifest. Compare the predicted set with the FAIL set.

## Evidence

Arithmetic (DERIVED):

```
K = 282672640*16 = 0x10d93e000   V = 353975808*16 = 0x15193e000
V - K = 0x44000000 = 131072 * 8704   slot stride = 131072*272 = 0x2200000
0x14093E000 - K = 0x33000000 = 24 * 0x2200000   (slot K24, position 0)
0x111D3E000 - K = 0x04400000 =  2 * 0x2200000   (slot K02, position 0)
```

Prediction against the FAIL list (MEASURED, script in this doc's procedure):

```
NTOK  predicted  missed  extra
   1      40       0     []
   8      40       0     []
  16      41       0     ['blk.24.ssm_out.weight.mv4i']   (window past the tokens actually written)
```

Per-slot table (`kvgrid_table.txt`): all 44 slot heads that land inside a
piece are FAIL; all 20 that land in free space (segments 16, and the tails of
17..25) are clean. Excerpt:

```
K00  0x10d93e000  (no piece)
K02  0x111d3e000  output.weight.mv4i lane 25 seg 17                    FAIL
K24  0x14093e000  output.weight.mv4i lane 18 seg 20                    FAIL
V00  0x15193e000  blk.15.ffn_gate.weight.mv4i lane 15 seg 21           FAIL
V31  0x19373e000  blk.17.ffn_down.weight.mv4i lane 21 seg 25           FAIL
```

Why the 32 block probes all matched while the argmax did not: the probes
were run on a freshly loaded image, before any C job had written; each token
writes only 64 records of 272 B, and the lm_head window 6 read is the first
consumer to cross a corrupted record. The XN agreement is real and says
nothing about the weights below the KV slots.

## Measured and REJECTED, do not retry

- **Descriptor bases wrong on the striped path.** Checked for all lm_head
  windows against pieces and file: correct. Not the cause.
- **Manifest regions overlapping pieces.** All four regions checked: none.
- **`pack_gdn_consts.py` modifying the striped manifest.** It added
  `gdn_const` at `0x1ff95a000` (backup `striped_manifest.before.json`); that
  region is above every piece and B's constants verified. Not the cause.
- **Re-striping the image around the compiled region.** Does not fit: the
  compiled KV occupies segments 16.85 to 25.35 (2.28 GB) on stack 1, and the
  12 stack-1 lanes need 1.9 GB across segments 26..31 (1.45 GB free). Not a
  packer option.
- **Using the flat image on the same bitstream as a "control" after the
  striped image was loaded.** Flat descriptors point at addresses that no
  longer hold those tensors; reads 0. Not evidence of anything.

## Measurement traps hit

- The verify was run AFTER tokens; a verify on a fresh load passes, so the
  corruption looked like a load problem at first. Verify after the first GO
  on any new layout.
- `C_MAXPOS = 131072` with the striped `kv_base` does not fit in HBM at all
  (`0x1AD71C000 + 2*131072*8704 = 9.5 GB`), so the striped manifest's
  `max_context_tokens 79163` and the compiled `C_MAXPOS` were already
  inconsistent before this bug fired. `sim:kvmap` pins the generics to ONE
  manifest (the flat one), so the gate is green while the loaded image is a
  different one.

## The fix (in flight)

Make the KV base a seam register like `bst_state_base` (host writes it from
`hbm.kv_base`; V derived in RTL from K and `C_MAXPOS`), expose `C_MAXPOS` to
the host read-only, have the host refuse a manifest whose KV extent is too
small for `2 * C_MAXPOS * 8704` or whose pieces intersect it, drop
`C_MAXPOS` to 65536 so the striped layout's 1.378 GB free fits, and rebuild.
The kvmap gate should then check BOTH manifests against the card's geometry.

## Open, not yet answered

- Whether C_MAXPOS 65536 changes anything else in the card (POSW 17 bits,
  RoPE tables): to be measured by the gate and the build.
