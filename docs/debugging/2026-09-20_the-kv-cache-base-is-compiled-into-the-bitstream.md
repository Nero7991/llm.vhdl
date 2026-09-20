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

## The fix (landed 2026-09-20, TRACK KVREG; NOT YET BUILT INTO A BITSTREAM)

Appended, not rewritten.  Everything above stands; this section records what
was changed, how each piece was shown to bite, and what is still open.

**RTL.** `rtl/llama_top.vhd` gained two input ports beside `bst_state_base`:
`kv_k_base`, `kv_v_base : in std_logic_vector(C_KV_ADDR_W-1 downto 0)`, BYTE
addresses, defaulting to the compiled pair (`C_K_BASE_CH`/`C_V_BASE_CH`
shifted by 4, the one place the chunk-to-byte shift now lives) and handed
straight to `attn_kv_axi`'s `k_base`/`v_base`.  The generics, their guards
and the comment block stay, marked as DEFAULTS.  `rtl/fk33_seam.vhd` gained
`A_KVK_LO/HI` 0x90/0x94 and `A_KVV_LO/HI` 0x98/0x9C (RW, reset 0, HI keeps bit
0, output pins `d_kv_k_base`/`d_kv_v_base`, in the GO-time zero refusal with
ARENA and BST), `A_KV_MAXPOS` 0xA0 (read-only, the seam's MAXPOS generic,
which `gen_pcieep.py` sets from `gen_fk33_card.py`'s C_MAXPOS -- one read
of one source), and CAPS bit 5 (0x1D -> 0x3D).  `gen_pcieep.py`'s
SEAM_TO_CARD wires both; `gen_fk33_card.py` sets `C_MAXPOS=C_CTXLEN=65536`
and `C_V_BASE_CH=318324224` (DERIVED: 282672640 + 8*4*65536*17; and
(4522762240 + 8704*65536)/16 = 318324224, the two agree).  MEASURED
`--bd-only` on the card configuration: `FK33_SEAMWIRE 40 seam<->card pins`,
`FK33_SEAM MAXPOS = 65536`, `FK33_UNCONNECTED count=0`, `FK33_BD_VALIDATE OK`
(line-anchored), exit 0.

**Host.** `server/pl_backend.c` on a card advertising `FK33_CAP_ENG_KV_BASE`:
reads KV_MAXPOS, programs K = hbm.kv_base and V = K + MAXPOS *
kv_bytes_per_token/2, reads all four registers back, and refuses at open an
image whose free KV space (below gdn_const, else the arena) cannot hold the
pair.  MEASURED on the simulated card against the REAL striped manifest:

```
$ run_prompt --v2 ... --manifest .../qwen35-9b-mv4i-noembd-striped/manifest.json --open-only --sim-kv-maxpos 131072
pl_open: THE IMAGE CANNOT HOLD THIS CARD'S KV CACHE.
  The card's C_MAXPOS is 131072 positions, so its K and V regions
  are 1140850688 bytes each (MAXPOS * 8704) and the pair laid at
  hbm.kv_base 0x1AD71C000 ends at 0x23571C000; the image's free KV
  space ends at 0x1FF95A000 (hbm.gdn_const_base), 903618560 bytes short.
$ ... --sim-kv-maxpos 65536
[pl_backend] KV base programmed: K 0x1AD71C000 V 0x1CF71C000 (C_MAXPOS 65536, 17408 B/token, extent ends 0x1F171C000 under hbm.gdn_const_base 0x1FF95A000)
```

Without the caps bit it prints that the base is compiled in and continues
(today's behaviour).  The piece-overlap check is NOT in the host: the
manifest parser reads only `hbm`, and the extent check against
[kv_base, gdn_const/arena) is sufficient because every piece ends at
weights_end <= gdn_state_base < kv_base (the parser refuses otherwise).
The piece check lives in `tools/check_kv_map.py` (gate row sim:kvmap).

**Gate.** `check_kv_map.py` now checks BOTH manifests at the card's
C_MAXPOS: extent inside hbm.size, no intersection with any piece of any
file, clear of gdn_state/gdn_const/desc_arena.  Teeth (MEASURED, 22 of 22):

```
  striped_image_with_the_compiled_flat_pair_at_131072                REFUSED
        REFUSED striped manifest: KV extent starts at hbm.kv_base    K 4522762240 vs hbm.kv_base 7204880384
        REFUSED striped manifest: KV extent intersects no weight piece  2458 piece(s) hit; first (lowest address): output.weight.mv4i lane 15 seg 17 [4563402752, 4584595456)
    attribution control: same mutant, extent rows OFF                accepted
```

That mutant IS this document's defect, and the accepted control is the
measurement that the older rows could not see it.

**Benches.** `sim/tb_fk33_seam.vhd` P6g, 17 checks counted in a variable
(GO refused with the pair zero and with only K written, reset values,
readback, pins follow, HI keeps bit 0, A_KV_MAXPOS reads the generic, BST
undisturbed, pair survives CLR_ERR).  `sim/tb_llama_top.vhd` gained
`KV_PORT_BASES`: the DUT's generics get DECOY regions and the real bases go
in through the ports; `sim/tb_llama_top_kvport.vhd` is tb_llama_top_seq
with it on (MEASURED PASS, 301 s, 0 of 4 landmarks moved).  Mutants:

| mutant | row | result |
|---|---|---|
| A: seam write-decode arms for A_KV*_* removed | tb_fk33_seam | FAIL, P6g checks 8-13 and 17 by name (7 of 17), then the token refused at GO (141 more faults) |
| B: llama_top's u_kv port map back to the compiled constants | tb_llama_top_kvport | see the report / WORKLOG for the measured line |
| B, attribution control | tb_llama_top_seq (ports unused) | must PASS: the pre-existing row is blind to B |

## Open, not yet answered (after the fix)

- The bitstream with this in it has not been built.  Until it is, the
  shipped `.bit` has the base compiled in and only the flat image is safe.
- On silicon: `fk33ctl.py seam` must show caps 0x3D and the pair after
  `run_prompt --open-only`; the striped image's token 0 must give argmax
  846 and `fk33_load_weights.py verify` must be clean AFTER the token.
- C_MAXPOS 65536 halves the context; POSW drops 18 -> 17.  Nothing else
  in the card reads C_MAXPOS (the behavioural cache is not instantiated),
  MEASURED by the kvport/seq rows only at the sim shape.

---

## CONFIRMED ON SILICON, 2026-09-20 11:20

The fix is built and measured. Bitstream
`hw/fk33/bit/fk33_card_kvreg_75mhz_2026-09-20.bit` (build 9, WNS +0.061 ns,
WHS +0.009 ns at 75 MHz, sha256 f1caefe8...), image
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27`.

MEASURED, in order:

```
seam       cap flags 0x3d, KV_BASE present, kv_maxpos 65536, ctx 65536
bases      kv_k_base 0x1b1938000  kv_v_base 0x1d3938000
           V - K = 570,425,344 B = 65536 * 8704   (exact)
token 0    argmax 846 = THE REFERENCE VALUE, exp 15, smp_n 248320
one token  30,115,217 cycles = 0.402 s at 75 MHz
182 GOs    73.854 s = 0.4058 s/token = 2.46 tok/s = 2.04x the flat image
verify     251 of 251 objects PASS after 34 tokens, and again after 182
           (the same check reported 41 corrupted objects before the fix)
```

`smp_n 248320` matters: TRACK SMPWIN established that the published argmax is
`sampler_stream`'s own fold count, so a single lost beat shifts it. The full
vocabulary was swept, so 846 is the argmax of the whole row and not of a
prefix.

Per-step profile of the corrected striped token
(`hw/fk33/results/card_kvreg_2026-09-20/profile_striped_seg27_tok0.txt`):

| opcode | steps | cycles | share |
|---|---:|---:|---:|
| B_JOB | 24 | 15,854,364 | 52.6% |
| A_JOB | 310 | 10,890,053 | 36.2% |
| VEC_SWG | 32 | 1,967,136 | 6.5% |
| VEC_NORM | 65 | 736,840 | 2.4% |
| C_JOB | 8 | 594,472 | 2.0% |
| VEC_RES | 64 | 67,712 | 0.2% |

B is now the majority of the token, which is what the B-mover lever
(`14fa888`, DERIVED -8.28 M cycles) is for.

The 160-token answer is in
`hw/fk33/results/card_kvreg_2026-09-20/dcdc_prompt_160_striped.txt` and is
coherent and on-topic, including the point that a transformer cannot handle
DC and that a DC-DC converter uses one internally via switching.
