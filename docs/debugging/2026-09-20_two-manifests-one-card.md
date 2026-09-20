# Two manifests, one card: the image interlock

Date: 2026-09-20. TRACK IMGLOCK, branch `fpga`, MAIN checkout.
Bitstream `bitstreams/fk33_qwen35-9b_kvreg-striped_75mhz_2026-09-20.bit`
(`FK33_CAP_ENG_KV_BASE`, `C_MAXPOS = 65536`, 75 MHz core).
Images: `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd` (flat) and
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27` (resident).

## The question, verbatim

> "At 11:04 the user ran `hw/fk33/host/fk33_chat.sh "..."` with no environment
> set, which defaults `FK33_MODEL_DIR` to the FLAT image
> `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd`. The card was holding the
> LANE-STRIPED image `...-striped-seg27`. Both manifests declare
> `desc_arena_base = 0x1ffadd000`, the SAME address, so the flat descriptor
> table overwrote the striped one and A fetched weights from flat addresses on
> a striped image. Output was one token repeated 200 times. `pl_backend.c`
> programmed the FLAT `kv_base = 0x10d93e000` into the new KV seam register,
> and C wrote 24 positions of KV into the striped weight image. The image had
> verified 251 of 251 clean immediately before. **Nothing on the card records
> which image is resident, and nothing on the host checks.** Make it impossible
> to drive the card with a manifest that does not describe the resident image."

## The answer, up front

**The card now records which image is resident, in HBM, and every tool that
drives it refuses a manifest that disagrees.**

`fk33_load_weights.py load` writes a 512-byte **image record** into the last
512 bytes of the descriptor arena extent the manifest itself reserves
(`desc_arena_base + desc_arena_bytes - 512`, `0x1ffb03e00` for every 9B set).
It carries the eleven region numbers verbatim plus a **placement
fingerprint** -- BLAKE2b-128 over a canonical text of the region block AND
every piece address of every object. `pl_open()`, `fk33ctl.py seam`,
`fk33_imgfp.py check` and `fk33_chat.sh` read it back and refuse on any
disagreement, naming the resident manifest, the requested one and the field.

**The fingerprint is over PLACEMENT, not content, and that is load-bearing.**
MEASURED: all 250 per-file `blake2b_128` digests are IDENTICAL across the
flat, striped and seg27 sets -- the packer decides addresses, not bytes -- so
no content digest of HBM or of the files can tell the three apart.

**Two of the three cannot be told apart by reading weight bytes either.**
MEASURED: `-striped` and `-striped-seg27` place all 250 objects and all their
pieces at IDENTICAL addresses and differ ONLY in the GDN state and KV regions,
which hold no file bytes. The byte probe added in `c419de7` reports both and
says so; the placement fingerprint separates them (`2431269a...` against
`7f9e57e3...`) because the region block is inside it.

**And the record's existence is what makes the trade in `109dc27` safe.**
Making C's KV base a host-programmed seam register is what made the striped
image runnable and delivered 2.04x. It is also what converted this class from
*wrong answer* to *data loss*: before it, a mismatched manifest misaddressed
READS; after it, one GO writes KV records over the weights. Both halves of
that trade are real and the register should stay. This is the guard it needed
and did not get.

## Procedure

Each step and what it isolates.

1. **Reproduce the damage arithmetically from the two manifests alone.**
   Intersect the FLAT image's KV slot grid -- `K = hbm.kv_base`,
   `V = K + C_MAXPOS * (kv_bytes_per_token/2)`, 32 slots each at stride
   `C_MAXPOS * kv_record_bytes` -- with every piece of the RESIDENT manifest.
   Isolates: whether C's writes alone account for the reported objects, with
   no appeal to descriptors, to A, or to anything else that ran.
   Script: `docs/debugging/2026-09-20_two-manifests-one-card_predict.py`.
2. **Control for the parameter that is a property of the BITSTREAM, not of
   the image**: `C_MAXPOS`. Read from `FK33_SEAM_KV_MAXPOS` in the card's own
   `seam_after.txt`, not assumed. Isolates the measurement trap recorded below.
3. **Measure whether a content digest could have caught it.** Compare all 250
   `blake2b_128` values, and all 250 `hbm_offset` values, pairwise across the
   three sets.
4. **Measure whether the byte probe (`fk33_resident_image.py`, `c419de7`)
   could have caught it.** Compare the full piece lists of the two striped
   sets. Isolates the stated gap in that commit from the rest of the problem.
5. **Enumerate where a record could live, and cost each option**, from
   `tools/hbm_map.py`'s own region report rather than from intent.
6. **Build it, then reconstruct the incident against `fk33_sim`** -- a
   simulated card whose HBM already holds the striped record, driven with the
   flat manifest -- **with the attribution control**: the same pair with no
   record, which is the state of the world before this change.

## Evidence

### 1. The 35 objects, predicted from the two manifests

```
$ python3 docs/debugging/2026-09-20_two-manifests-one-card_predict.py
K 0x10D93E000  V 0x12F93E000  half 0x22000000  slot stride 0x1100000
NTOK  1 -> 35 distinct weight objects predicted destroyed
NTOK  8 -> 35 distinct weight objects predicted destroyed
NTOK 24 -> 35 distinct weight objects predicted destroyed
NTOK 34 -> 35 distinct weight objects predicted destroyed
```

35, exactly the reported count, 0 missed and 0 extra, and INSENSITIVE to the
token count over 1..34 -- because each slot's first record already lands
inside (or outside) a piece and 34 records are 9,248 B against a 4 KB-aligned
piece boundary. The grid is a property of the two manifests and of
`C_MAXPOS`; the number of tokens only decides how much of each object is
overwritten.

### 2. A content digest cannot tell the three images apart

```
flat vs striped : digests equal? True   offsets equal? False
striped vs seg27: digests equal? True   offsets equal? True
files with differing digest  flat vs seg27 : 0 of 250
files with differing hbm_offset striped vs seg27: 0 of 250
pieces identical striped vs seg27: True   (differing files: 0)
```

So: the flat image is separable by reading bytes at claimed addresses; the two
striped images are NOT. What separates them is the region block --
`gdn_state_base 0x1B0000000` against `0x1ABDE4000`, `kv_base 0x1B1938000`
against `0x1AD71C000` -- and `kv_base` is the field that did the damage.

### 3. The placement fingerprint separates all six packed sets

```
qwen35-9b-mv4i-noembd                    bc8d7fac56473e216da29e663dc6bbf9
qwen35-9b-mv4i-noembd-striped            2431269a737cda96a3cd609b6bf08527
qwen35-9b-mv4i-noembd-striped-seg27      7f9e57e300d7beb3c1967bd56e87f3a3
qwen35-9b-mv4i-noembd-stripe27           476c3241e3b15d98ae6aef77ed149737
qwen35-9b-mv4i-qkvpad                    100a2faaaba031a55b041a71e92c9a83
qwen35-9b-mv4i-stackfix                  dad47cf38c116bb4a760d2374a5b3afd
qwen35-9b-mv4i                           REFUSED: no `desc_arena_base`
```

The last row is the fail-closed case: a set packed before the region block
existed (2026-08-29) cannot be fingerprinted, is refused, and the message is
the migration command. It is already unloadable for the same reason.

### 4. The refusal, against a file standing in for HBM

```
$ FK33_C2H=$SD/hbm.bin fk33_imgfp.py check .../qwen35-9b-mv4i-noembd/manifest.json
IMAGE LOCK: REFUSE -- the card is NOT holding this image
  resident : .../qwen35-9b-mv4i-noembd-striped-seg27/manifest.json
  requested: .../qwen35-9b-mv4i-noembd/manifest.json
    hbm.weights_end: resident 0x1ABDE4000, this manifest 0x10C006000
    hbm.gdn_state_base: resident 0x1B0000000, this manifest 0x10C006000
    hbm.kv_base: resident 0x1B1938000, this manifest 0x10D93E000
    placement fingerprint: resident 7f9e57e3..., this manifest bc8d7fac...
rc=1

$ ... check .../qwen35-9b-mv4i-noembd-striped/manifest.json       # the pair
IMAGE LOCK: REFUSE -- the card is NOT holding this image           # a byte
    hbm.gdn_state_base: resident 0x1B0000000, this manifest 0x1ABDE4000
    hbm.kv_base: resident 0x1B1938000, this manifest 0x1AD71C000   # probe
    placement fingerprint: resident 7f9e57e3..., this manifest 2431269a...
rc=1                                                               # cannot see
```

### 5. `pl_open()` refusing the incident, against `fk33_sim`

`server/tests/imglock_selftest.c`, MEASURED 0.00 s, 2.88 MB peak:

```
IMGLOCK SELFTEST -- the card holds seg27, record at 0x1FFB03E00
  X1 the resident manifest (must be ACCEPTED)          accepted  ok
  X2 THE INCIDENT: the flat manifest at a striped card REFUSED   ok
  X3 ATTRIBUTION the same pair, interlock disabled     accepted  ok
  X4 no record at all, on the hardware path            REFUSED   ok
  X5 a TORN record, on the hardware path               REFUSED   ok
  X5b NOT BITING a torn record off the hardware path   accepted  ok
  X6 striped vs seg27: same pieces, different KV       REFUSED   ok
  X7 kv_base edited alone                              REFUSED   ok
  X8 a different model shape (arena elsewhere)         REFUSED   ok
  X9 no manifest at all, on the hardware path          REFUSED   ok
  X10 NOT BITING max_context_tokens edited alone       accepted  ok
  X11 a PARTIALLY loaded image                         REFUSED   ok
  X12 ORDERING the image lock fires before the v2 program check REFUSED ok

IMGLOCK_SELFTEST PASS  (15 checks, 0 failed)
```

**X3 is the attribution control and it is the point of the table.** With no
record on the card, the flat manifest at a striped image is ACCEPTED by
`pl_open()` -- every other check it makes (the 40-bit and 33-bit port widths,
the 16-byte `kv_base` alignment, the C_MAXPOS extent against the image's KV
ceiling, the register read-back) passes, because they check the manifest
against ITSELF and against the card's CAPS. Nothing else catches this.

**X12 is the safety property.** The refusal must land before the first base
register is written, because a programmed `KVK` is enough on its own: one GO
afterwards writes C's records at the wrong address. The row drives a v2 card
with no descriptor program, which has its own refusal waiting in `pl_open`,
and asserts the message is the image lock's rather than the program check's.

### 6. The record's own teeth

`hw/fk33/host/fk33_imgfp.py selfcheck`, MEASURED 0.29 s, 23.6 MB peak, 32
rows, 0 FAIL. Abridged:

```
  determinism                                       ok
  file-order-invariance                             ok    same fingerprint
  content-invariance                                ok    identical placement, different digests -> same fingerprint
  record-addr                                       ok    0x1ffb03e00
  absent-record                                     ok    no record
  round-trip                                        ok    written, read back, agrees
  incident-flat-vs-striped                          ok    REFUSED: hbm.gdn_state_base...
  same-manifest-twice                               ok    accepted
  striped-vs-seg27-kv-only                          ok    REFUSED: hbm.gdn_state_base...
  kv-base-edited-alone                              ok    REFUSED: hbm.kv_base...
  gdn-const-base-edited-alone                       ok    REFUSED
  host-max-chunk-edited-alone                       ok    REFUSED
  different-model-shape                             ok    REFUSED
  one-piece-moved                                   ok    REFUSED: placement fingerprint
  ATTRIBUTION region-fields-alone-vs-flat           ok    would still refuse on gdn_state_base,kv_base
  ATTRIBUTION region-fields-alone-vs-moved-piece    ok    BLIND, as intended
  NOT-BITING different-packed-bytes-same-addresses  ok    accepted (guard: fk33_load_weights.py verify)
  NOT-BITING max-context-tokens-edited              ok    accepted (guard: pl_open's C_MAXPOS extent check)
  record-all-zero / magic-corrupt / wrong-version   ok
  record-body-bit-flipped / torn-head-of-new-tail-of-old / truncated / tail-clobbered  ok
  partial-load-record                               ok    REFUSED
  arena-slot-overflow / arena-provenance-absent     ok    REFUSED
  c-decoder-agrees / c-decoder-refuses-incident / c-decoder-refuses-torn  ok
  c-packer-agrees                                   ok    512 of 512 bytes identical to the Python packer
IMGFP SELFCHECK: 32 rows, 0 FAIL
```

The two ATTRIBUTION rows measure whether the record's two halves are
redundant. They are not: the region fields alone refuse the incident pair
(`gdn_state_base`, `kv_base`) and are BLIND to a single moved piece; only the
fingerprint catches that. And `fk33_load_weights.py selfcheck` adds R1..R3,
where R3 is the mirror case -- two fixtures sharing one `hbm` block, exactly
as the real manifests share `desc_arena_base = 0x1ffadd000` -- so every region
field agrees and only the fingerprint refuses.

### 7. Where the record lives, and what the alternatives cost

`tools/hbm_map.py` on the resident manifest:

```
A descriptor arena            0x1_ffad_d000  0x1_ffb0_4000     159,744
host R_X staging              0x1_ffb0_4000  0x1_fff0_c000   4,227,072
host logits writeback         0x1_fff0_c000  0x1_ffff_e840     993,344
host D program                0x1_ffff_f000  0x2_0000_0000       4,096
```

`311 jobs * 512 B stride = 159,232`, and `159,744 - 512 = 159,232`. So the
arena's last 512 bytes are free **exactly**, with zero margin, and the margin
being zero is stated rather than hidden: `record_addr()` REFUSES when
`jobs * stride > bytes - 512`, so a shape needing one more job gets a loud
refusal rather than an overwritten descriptor
(`arena-slot-overflow` row above). MEASURED: `token.arena` as emitted by
`gen_layer_program.py --arena-image` is 159,232 bytes, so the arena load
writes that many and stops 512 short.

## Measured and REJECTED -- do not retry

- **A new seam register.** 16 bytes of fingerprint is four registers and a
  4.5-hour place-and-route. Worse, a register is cleared by reconfiguration
  while the image in HBM is not, so after a bitstream reload it would say "no
  image" about an image that is still there -- and a register the host wrote
  is not evidence about HBM in the first place. REJECTED on both counts.
- **A carved page at the top of HBM.** There is no gap. MEASURED from the map
  above: the arena ends at `0x1_ffb0_4000` and `host_x_base` begins at
  `0x1_ffb0_4000`; the D-program page ends exactly at `0x2_0000_0000`. Every
  block abuts. Shifting any of them down one page makes every packed set's
  `host_x_base`/`host_l_base`/`host_desc_ptr` provenance disagree with
  `pl_derive_bases()` AND puts the arena on top of `x_base`, so
  `fk33_load_weights.py load` would refuse EVERY existing image until each
  manifest was re-derived. On a card that is serving, that is an outage, not a
  migration.
- **The 1,984-byte gap between the logits block and the D-program page**
  (`0x1_ffff_e840 .. 0x1_ffff_f000`). It exists only as a rounding fragment of
  `align_down(desc_ptr - 4*n_vocab - 16)`; a different vocabulary closes it
  with nothing to say so. REJECTED as a silent-tomorrow address.
- **The D-program page itself** (`0x1_ffff_f000`), unused on every bitstream
  built so far because none advertises `FK33_CAP_HBM_FETCH`. REJECTED: taking
  a page that a v3 card will use, on the grounds that today's card does not,
  is a landmine with a build in front of it.
- **A host-side state file** recording the last load. The entire defect class
  is "the host believed something about the card". A file goes stale on a
  reboot, on a second machine, and on anyone loading through `fk33ctl.py`
  directly -- and it goes stale SILENTLY.
- **A content digest of the resident bytes.** Section 2: it cannot separate
  the three images at all. This is the one that feels obviously right and is
  measurably useless here.
- **Relying on the byte probe alone** (`fk33_resident_image.py`, `c419de7`).
  It is a real check and it stays as the fallback, but section 2 measures its
  ceiling: the two striped images are byte-identical everywhere it looks.

## Measurement traps hit

- **`C_MAXPOS` IS A PROPERTY OF THE BITSTREAM AND IT CHANGED THE SAME DAY.**
  The first run of the prediction used 131,072 -- the value in the
  2026-09-20 morning doc -- and predicted **41** objects, not 35. It looked
  like a near miss worth explaining. It was the wrong constant:
  `hw/fk33/gen_fk33_card.py:353` says `C_MAXPOS=65536`, halved that day so the
  striped layout would fit, and the card's own `seam_after.txt` reports
  `kv_maxpos 65536`. With the card's value the prediction is 35, exactly, at
  every token count. **Read the geometry from the card or from the build that
  produced it, never from a document about a different build** -- the same
  cross-configuration borrowing `CLAUDE.md` records for the 25.0 GiB figure.
- **`objs_loaded` was counted against `mani["files"]`, which is not the load
  list.** The GDN constant image is declared in `hbm`, not in `files`, and
  `const_entries()` puts it on the list, so every full load recorded itself as
  `5 of 4 objects` and therefore as PARTIAL. Caught by the R1 row of
  `fk33_load_weights.py selfcheck` within a minute of writing it -- a check
  written to test the loader found a defect in the thing being added, which is
  the argument for writing it first.
- **A 512-byte write can cost 8 GB of RSS.** Writing the record at
  `0x1f0027e00` makes the selfcheck's sparse fake-HBM file really extend to
  8.32 GB, and the `M9 whole image shifted` mutation did `f.read()` on it.
  MEASURED by sampling `/proc/PID/status VmHWM`: the loader selfcheck went
  from 18 MB / 0.05 s to **7,953 MB / 7.25 s**, silently, while still printing
  PASS on every row. `f.read(span)` -- the bound was always available, since
  only `img[:span - delta]` was used -- returns it to **20.5 MB / 0.10 s**.
  A peak that only appears when a file grows elsewhere is invisible to every
  row's verdict.
- **`/usr/bin/time %M` agreed with `VmHWM` here, but neither is a budget.**
  The figure above is a real unthrottled peak (no cgroup cap), which is the
  only kind worth quoting -- see CLAUDE.md on a capped `memory.peak` being the
  cap.
- **Two tools with the same name for different things.** `fk33_imgfp.py`'s
  `CANDIDATES` and `fk33_resident_image.py`'s `CANDIDATES` are different
  lists (four entries against three). They are used for different purposes --
  one supplies a record ADDRESS, the other supplies images to probe -- and
  merging them would be a single point of staleness for two questions. Stated
  here because the duplication is deliberate and looks like an oversight.

## What is open, and NOT determined

- **The card carries no image record today.** The resident seg27 image was
  loaded before this existed, so `fk33_chat.sh` will take the NO-RECORD
  fallback: the byte probe reports BOTH striped images and the script
  REFUSES, by design. The dispatcher must run, on the card,
  `fk33_load_weights.py verify <seg27 manifest>` and then
  `fk33_imgfp.py write <seg27 manifest>` (or reload, which writes it).
  Until then nothing runs. This is fail-closed and it is also a real
  interruption.
- **Nothing here has touched the card.** Every measurement above is against
  the manifests, `fk33_sim`, or an ordinary sparse file pointed at by
  `FK33_C2H`/`FK33_H2C`. The interlock has NOT been exercised against
  `/dev/xdma*`, and in particular the `PL_TRANSPORT_CHARDEV` branch that
  forces `require_image_lock` has only been exercised through the equivalent
  `opts.require_image_lock = 1` on the simulated transport.
- **A torn record is only refused on the hardware path** (X5b). Off it, a
  record that fails its checksum reads as ABSENT and pl_open continues with a
  NOTE. That is deliberate -- a simulated card has no image to disagree with
  -- but it means a test transport can never see the refusal by accident.
- **The record does not protect the GDN state or the arena from being
  written by a mismatched tool that does not call `pl_open`.**
  `fk33ctl.py load <file> --offset <addr>` still takes an address on the
  command line and writes it. `fk33_chat.sh` now derives that address from the
  checked manifest, but the tool itself is unguarded.
- **Whether A's descriptor fetch can be made to check anything** is untouched.
  The arena collision half of the incident is prevented here only because the
  arena is written from a manifest that has been checked, not because the card
  would notice a foreign descriptor table.
- **The 200-token repetition** reported as the first symptom has not been
  reproduced or explained in detail; it is consistent with A fetching weights
  from flat addresses on a striped image, and that attribution is an
  ESTIMATE, not a measurement.
