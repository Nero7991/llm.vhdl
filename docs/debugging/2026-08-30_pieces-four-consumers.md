# Can the four consumers that model a tensor as ONE contiguous extent learn `pieces` without weakening `check_bases`?

**Date:** 2026-08-30. Branch `fpga`. **TRACK PIECES.** Commit `263e0ee`.

**No hardware was touched.** Nothing below ran `xsdb`, `hw_server`,
`vivado ... program`, `hw/fk33/pcieep.sh`, `hw/fk33/jtag.sh`, `hw/fk33/flash.sh`
or anything under `hw/fk33/tcl/`. Six offline commands were traced with
`strace -f -e trace=openat,open`: **zero `/dev` opens of any kind**, section
4.6. Section 9 is a command list for Oren and its card arm is separated from
its offline arm.

**Tools named:** `python3` over `tools/hbm_map.py`, `tools/gen_mv4i_desc.py`,
`tools/gen_layer_program.py`, `tools/gen_lmhead_windows.py`,
`tools/verify_mv4i_desc.py`, `hw/fk33/host/fk33_load_weights.py`,
`hw/fk33/host/fk33_run_job.py`; `cc` building `ref/mv_fk33_tr.c`;
`strace`; `git diff`, `git show`, `git rev-parse`.

**Files read as the authority:**
`docs/debugging/2026-08-30_packstripe-lane-arena-placement.md` (including the
correction it appended today), `docs/debugging/2026-08-30_counters-cycles-beats-starved.md`,
`tools/pack_model_fk33.py::expand_pieces/check_lane_stripe` at `0e175cc`, and
the live manifest at
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json`.

Labels: **MEASURED** (a named tool ran), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement with its assumption stated).

---

## 1. The question, verbatim

> **Four consumers still model a tensor as ONE CONTIGUOUS EXTENT and must learn
> about `pieces`. PACKSTRIPE deliberately applied none of them.**
>
> - `tools/hbm_map.py::manifest_regions` (~6 lines)
> - `tools/gen_mv4i_desc.py` -- **the base join ONLY**
> - `hw/fk33/host/fk33_load_weights.py` -- load and verify
> - `hw/fk33/host/fk33_run_job.py` -- its cross-check
>
> **A hard constraint carried from PACKSTRIPE and agreed by me: `check_bases`
> must NOT be relaxed.** ... If you find yourself needing to relax it, STOP and
> report -- that is the signal that the `pieces` model is wrong, not that the
> check is.
>
> Deliver: the four changes; a test that the striped and flat paths produce
> IDENTICAL DESCRIPTORS for a flat model; teeth with an attribution control;
> mutations that do NOT bite, under their own names; coverage stated
> explicitly; a copy-pasteable command list with offline and card arms
> separated.

---

## 2. The answers, up front

**`check_bases` was not relaxed, was not touched, and did not need to be.**
It compares two FILE offsets, and striping moves no file offset. The join to
the manifest happens strictly downstream of it, in a new function
`gen_mv4i_desc.sub_base()`, and **the join key is the file offset that
`check_bases` has already certified** -- never a `lane`, `kind` or `segment`
label. A manifest whose labels are wrong but whose addresses are right still
produces the right descriptor; a manifest whose labels are right and whose
addresses are wrong is not rescued by them.

**The four changes are in, at `263e0ee`, and the flat path is provably inert.**
MEASURED by an oracle that reaches the same descriptor by two different routes:
249 of 249 tensors, 699 descriptors, **27,261 descriptor words identical**
between the flat path and the pieces path on a flat layout. The same comparison
against the real striped manifest is the discrimination control for that test:
**6,723 of 6,723 sub-region bases MOVE**, into **25 distinct segments read out
of address bits [32:28]**, so the inertness result is not the feature being
dead code.

**THE FIFTH CONSUMER IS THE FINDING, AND IT IS THE ONE THAT MATTERS.**
`tools/gen_layer_program.py` -- the tool that emits the whole token's
descriptor program -- is not in the brief's list of four. MEASURED against the
striped manifest before any guard existed:

```
311 of 311 A jobs emitted, 0 refused
bases identical: 0   bases moved: 0
```

Every one of its 6,723 sub-region bases was byte-identical to the flat
program's, i.e. aimed at bytes that are not there, gateware-acceptable, and
reported as success. Two more callers (`tools/gen_lmhead_windows.py`,
`tools/verify_mv4i_desc.py`) have the same shape, and a fourth
(`hw/fk33/host/fk33_run_layer.py`) is out of reach of the guard below. **None
of them was edited.** Instead `gen_mv4i_desc.load_manifest()` -- which three of
the four go through -- now REFUSES a v2 manifest to a caller that has not
declared it reads pieces. That converts a plausible wrong program into a loud
stop, in one file this track owns, and is exactly what PACKSTRIPE's `format`
bump exists to provoke. `fk33_run_layer.py` reads the manifest with a bare
`json.load` and is listed as open in section 8.

**A SECOND FINDING, AND IT CORRECTS PACKSTRIPE'S SECTION 7.5.** Its specified
split of `make_plan`'s base check is "strictly stronger than the single check
it replaces". It is not. MEASURED: with the split in and a piece's HBM address
mutated, **`make_plan` reported `69 of 69 fields agree`**. It must: `w_base[p]`
is built from the manifest and compared against the C's file offset carried
through THE SAME manifest, so the placement cancels on both sides. The 42-field
form it replaced had the identical defect with `hbm_base` cancelling. **The
base half of that cross-check has never been able to see a placement fault
under either layout** -- it is a file-layout check wearing an address's
clothes, which is the `m7 mutant` shape. The fix is not in the split: it is
that `make_plan` now runs `hbm_map.plan(...).check()`, an independent reader
that never sees the descriptor, before it describes anything. MEASURED 13 ms on
the 6,973-extent map.

**The layout is not 27 segments and not 21.** The live striped manifest, which
PACKSTRIPE rewrote today, is **27 lanes compacted onto 25 segments, at most 2
per pseudo-channel, 75,340 tokens**. Nothing in this change hard-codes 27, 21,
25, or an assumption that two tensors have the same number of pieces; every
consumer asks the manifest. The one number that is NOT taken from the manifest
is the 256 MiB granule, which is DERIVED as `HBM_TOP / 32` and cross-checked
against the packer's own scrape (rule P6).

---

## 3. The procedure, in the order it was run

| # | step | what it isolates |
|---|---|---|
| 1 | capture baseline outputs of all four tools on the SHIPPING flat manifest | the control. Every later "identical" claim is a diff against these files, not a memory |
| 2 | read the live v2 manifest's actual shape rather than the doc's | it had changed under the doc: 25 segments, not 27. A change that hard-coded the doc's number would have passed every test here and been wrong |
| 3 | put ONE producer of the extent model in `hbm_map.file_pieces()`; make the other three call it | four private ideas of where a tensor is, is the defect being closed. A synthetic one-piece list for the flat case means both layouts run the SAME loop |
| 4 | `manifest_regions()` emits one Region per piece | the overlap/alignment/stack machinery then answers about extents that exist. This is the "make them understand, do not silence them" requirement |
| 5 | `manifest_piece_fails()` P1..P6 | the piece-to-FILE relation and the two labels nothing else compares, which the region model structurally cannot see |
| 6 | `gen_mv4i_desc.sub_base()`, joined on file offset | the descriptor. Deliberately downstream of `check_bases`, so that check keeps its teeth and its inputs |
| 7 | the inertness oracle, plus its own discrimination control | that the change is inert where it must be AND live where it must be. Either half alone is worthless |
| 8 | 14 mutations of the piece model x 3 arms x 4 consumers | which check bit, not merely that one did |
| 9 | six striped rows added to `fk33_load_weights selfcheck` | the residency backstop on the new path. A path with no teeth is a path nobody has shown to work |
| 10 | `strace` on six offline commands | the hardware boundary, as evidence rather than as a claim |

---

## 4. The evidence, raw

### 4.1 The inertness oracle and its discrimination control

`/mnt/storage/track-pieces/inert_pieces.py`, copied to
`docs/debugging/2026-08-30_pieces-inert_pieces.py`.

```
INERTNESS ORACLE -- flat path vs pieces path on the FLAT manifest
  manifest                 /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json
  format                   'llama.vhdl FK33 load manifest v1'
  mv4i objects in manifest 249
  objects read from disk   249   (COVERAGE: 249 of 249)
  files absent             0 []
  descriptors built        699 per arm, 39 words each
  words compared           27261
  descriptors that DIFFER  0
  -> PASS the pieces path is inert on a flat layout

DISCRIMINATION CONTROL -- the same comparison on the STRIPED manifest
  format                   'llama.vhdl FK33 load manifest v2 lane-striped'
  sub-region bases compared 6723
  bases that MOVED          6723
  bases unchanged           0
  distinct segments reached 25  [1, 2, 3, ... 24, 25, 26]
  -> PASS the pieces path is live: it moves bases into many pseudo-channels
```

**Why the first half is an oracle and not a round trip.** The two arms reach
the same 39 words by different code: the flat arm never looks at a piece, the
pieces arm never computes `hbm_base + off`. The pieces fed to the second arm
are cut at the header's own 0x38 table, read by `Mv4iHeader`, which does not
know striping exists. They can only agree if the join, the ordering and the
bound all compose to the flat answer.

**Why the second half is not decoration.** An inertness test passes trivially
if the feature is dead. The control says the argument moves 6,723 of 6,723
bases, and it reads the segment from `y >> 28` -- **address bits, not the
manifest's `segment` field**, which is PACKSTRIPE's own T3 lesson.

The three jobs per tensor are a 100-row prefix, a full-`MAXROWS_BFP` window,
and a window that does NOT start at row 0. Only the last exercises non-zero
`w_skip`/`s_skip`, which is where an offset or bound mistake would hide.

### 4.2 Teeth: 14 mutations, 3 arms, 4 consumers

`/mnt/storage/track-pieces/teeth_pieces.py`, copied to
`docs/debugging/2026-08-30_pieces-teeth_pieces.py`.

```
teeth over /mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json
  format   'llama.vhdl FK33 load manifest v2 lane-striped'
  objects  250, striped 249, extents 6973
  target   blk.0.ffn_gate.weight.mv4i

mutant   what it does                                        killed by (NEW)                P-OFF                 FLAT
control  the striped manifest, untouched                     -- SURVIVES --                 none                  hbm_map,load_weights,gen_desc
M1       one weight piece moved a whole 256 MiB segment up   hbm_map,load_weights           hbm_map,load_weights  hbm_map,load_weights,gen_desc
M2       one weight piece misaligned by 1 byte               hbm_map,load_weights           hbm_map,load_weights  hbm_map,load_weights,gen_desc
M3       two pieces of one tensor given the SAME address     hbm_map,load_weights           hbm_map,load_weights  hbm_map,load_weights,gen_desc
M4       a piece's segment LABEL changed, address untouched  hbm_map                        none                  hbm_map,load_weights,gen_desc
M5       a piece moved INSIDE its own segment's free tail    -- SURVIVES --                 none                  hbm_map,load_weights,gen_desc
M6       one piece 4096 B short, file no longer tiled        hbm_map,load_weights           load_weights          hbm_map,load_weights,gen_desc
M7       two pieces swapped, file offsets non-monotonic      hbm_map,load_weights           load_weights          hbm_map,load_weights,gen_desc
M8       object hbm_offset points at piece 5, not the header hbm_map                        none                  hbm_map,load_weights,gen_desc
M9       the object's declared stack flipped                 hbm_map                        none                  hbm_map,load_weights,gen_desc
M10      the declared stripe granule halved to 128 MiB       hbm_map                        none                  hbm_map,load_weights,gen_desc
M11      one weight piece deleted from the list              hbm_map,load_weights,gen_desc  load_weights,gen_desc hbm_map,load_weights,gen_desc
M13      a weight piece shrunk below the job's read span     hbm_map,load_weights,gen_desc  load_weights,gen_desc hbm_map,load_weights,gen_desc
M14      a piece's file_offset shifted off the 0x38 table    hbm_map,load_weights,gen_desc  load_weights,gen_desc hbm_map,load_weights,gen_desc
M12      two SAME-shape tensors swap one lane arena          -- SURVIVES --                 none                  hbm_map,load_weights,gen_desc

fk33_run_job.make_plan -- the CROSS-LANGUAGE consumer, on disk
  control  the striped manifest, untouched                   -- SURVIVES -- 69 of 69 agree
  M1       one weight piece moved a whole segment up         REFUSED RunError: tools/hbm_map.py refuses this manifest's own address map
  M3       two pieces of one tensor given the SAME address   REFUSED RunError: tools/hbm_map.py refuses this manifest's own address map
  M5       a piece moved INSIDE its own segment's free tail  -- SURVIVES -- 69 of 69 agree
  M6       one piece 4096 B short                            REFUSED RunError: tools/hbm_map.py refuses this manifest's own address map
  M11      one weight piece deleted from the list            REFUSED RunError: tools/hbm_map.py refuses this manifest's own address map
  M13      a weight piece shrunk below the job's read span   REFUSED RunError: tools/hbm_map.py refuses this manifest's own address map
  M14      a piece's file_offset shifted off the 0x38 table  REFUSED RunError: tools/hbm_map.py refuses this manifest's own address map
```

### 4.3 What the attribution control actually says

Three arms per mutant. `NEW` is everything on. `P-OFF` neuters
`manifest_piece_fails()` only, keeping the per-piece Regions. `FLAT` forces
`file_pieces()` back to one contiguous extent per object, i.e. the code as it
stood before this commit.

**THE `FLAT` COLUMN CARRIES NO ATTRIBUTION AND IS PRINTED TO SAY SO.** With the
pre-change model, the CONTROL row dies too -- the v1 consumers refuse a v2
manifest wholesale (PACKSTRIPE section 7.1, 249 faults). A column in which
every row including the control fails cannot tell an old property from a new
one. `P-OFF` is the arm that attributes.

Reading `P-OFF`:

| rule | independent kills | verdict |
|---|---|---|
| P3 (object base is its first piece) | **M8** | earns its place |
| P4 (declared stack vs the header's real stack) | **M9** | earns its place |
| P5 (declared segment vs address bits [32:28]) | **M4** | earns its place; this is T3's lesson turned into a rule |
| P6 (granule cross-check against `HBM_TOP/32`) | **M10** | earns its place |
| P1/P2 (pieces tile the file, and sum to `nbytes`) | **NONE** | **`load_weights` preflight catches M6, M7, M11, M13, M14 without them.** Kept because the two run in different tools for different users -- `hbm_map` is the one `fk33_load_weights` and the packer both call and the one that mirrors `server/fk33_manifest.c` -- but by this project's own definition P1/P2 in `hbm_map` are **not load-bearing**, and nobody should credit them with a detection |
| the per-piece Region model | M1, M2, M3, and M6/M7/M11/M13/M14 alongside | load-bearing. It is the whole reason the striped map can be checked at all |
| `sub_base`'s missing-piece refusal | M11, M14 (with `load_weights`) | earns its place: it is the only thing standing between a wrongly-cut manifest and a descriptor |
| `sub_base`'s extent bound | M13 (with `load_weights`) | earns its place. DERIVED that it cannot fire on a valid flat job: `tiles(n_rows) <= tiles(M)` for `n_rows <= M`, so `wb*port_b <= w_stride`; MEASURED over 699 descriptors, zero refusals |
| the `make_plan` base-check SPLIT | **NONE, under either layout** | **decoration, and it always was.** See section 2 |
| `hbm_map.plan().check()` inside `make_plan` | M1, M3, M6, M11, M13, M14 | the only thing that gives `make_plan` any view of the placement at all |

### 4.4 Mutations that do NOT bite, under their own names

- **M5, a piece moved to a different 4 KB-aligned address inside the segment
  its own lane already owns.** It survives everything and it SHOULD: that is a
  legal placement, and a rule that refused it would fail on a safe
  configuration. Same class as PACKSTRIPE's M8/M10.
- **M12, two tensors of the SAME shape swapping one lane arena** (PACKSTRIPE's
  M9). Survives every structural rule in this change, in `hbm_map`, and in
  `pack_model_fk33.check_lane_stripe()`, because structurally it is correct.
  **It is caught, and this is the closure PACKSTRIPE could not measure:**
  `fk33_load_weights.py verify` reading HBM back, exercised offline as
  selfcheck row **S4**, section 4.5. Say it plainly: the placement checks in
  this change are NOT a residency check and do not replace one.
- **S5, a byte flipped in a middle sub-region under `--headers-only`.** Cannot
  be seen and is not meant to be. The floor is WIDER on the striped path than
  the flat one: headers-only reads exactly ONE extent per object -- 4 of 112 in
  the selfcheck, **249 of 6,973** on the shipping set. The `extents N of M
  digested` line now prints that on every run.
- **M8 and M14 of the pre-existing flat selfcheck** are unchanged and still do
  not bite, for the reasons already recorded in that file.

### 4.5 `fk33_load_weights selfcheck`, extended with six striped rows

```
S0 BASELINE striped image (must PASS)                                   PASS   no   ok
S1 BASELINE striped, headers only (must PASS)                           PASS   no   ok
S2 one byte flipped in a MIDDLE sub-region                              FAIL  yes   ok
S3 two sub-regions of one tensor swapped in HBM                         FAIL  yes   ok
S4 two IDENTICAL-shape tensors swap one lane arena (PACKSTRIPE M9)      FAIL  yes   ok
S5 one byte flipped in a middle sub-region, headers only (NOT TO BITE)  PASS   no   ok

PASS  every check was shown to fail on a defect it claims to catch
```

The striped arm cuts the same four synthetic tensors at their own sub-region
boundaries and places the pieces in **reverse order of file offset**, so HBM
order and file order disagree everywhere. A loader or verifier that quietly
assumed they matched would get a wrong digest rather than a lucky pass. That
the digest still equals the pack-time value is what keeps `verify` an oracle
rather than a round trip after striping.

### 4.6 The hardware boundary, as evidence

`strace -f -qq -e trace=openat,open` on six offline commands. The logs are
122-800 lines each and contain real opens (`server/fk33_seam.h`,
`rtl/model_cfg_pkg.vhd`, `rtl/attn_kv_axi.vhd`), so the tracer was working:

```
hbmmap:     /dev/xdma opens = 0   any /dev =
lwplan:     /dev/xdma opens = 0   any /dev =
gendesc:    /dev/xdma opens = 0   any /dev =
runjobplan: /dev/xdma opens = 0   any /dev =
teeth:      /dev/xdma opens = 0   any /dev =
inert:      /dev/xdma opens = 0   any /dev =
```

### 4.7 The flat path, byte-for-byte

```
$ diff base/hbm_map_flat.txt hbm_map_flat_new.txt        -> no output
$ diff base/desc_flat_ffngate.txt desc_flat_new.txt      -> no output
$ diff base/runjob_plan_flat.txt rj_flat2.txt
11c11
< cross-check 42 of 42 fields agree ...
> cross-check 69 of 69 fields agree ...
$ diff base/lw_plan_flat.txt lw_plan_flat_new.txt
1c1
< 250 objects, 4,487,442,432 B = 4.1793 GiB, HBM 0x0..0x10c006000
> 250 objects in 250 extents, 4,487,442,432 B = 4.1793 GiB, HBM 0x0..0x10c006000
```

Descriptor JSON, field by field: **0 pre-existing fields changed**; three
added (`striped`, `w_extent_base`, `s_extent_base`). The two report-line
changes are deliberate: the field count is now honest about what is compared,
and the object/extent distinction is the whole point.

Neighbouring tools re-run unchanged: `gen_mv4i_desc --selftest` PASS,
`verify_mv4i_desc --teeth` PASS, `gen_lmhead_windows --mutate` killed 6 of 6,
`fk33_run_job selfcheck` 32 mutations / 17 refusal rows / 0 disagreements,
`gen_layer_program --token` on the flat manifest 311 of 311.

---

## 5. Coverage, stated -- how many were READ, not how many passed

| thing | flat set | striped set |
|---|---|---|
| manifest objects | 250 | 250 |
| of which lane-striped | 0 | 249 |
| **extents (`file_pieces`)** | **250** | **6,973** |
| Regions `manifest_regions` emits for them | 250 | 6,973 |
| `manifest_piece_fails` faults | 0 | 0 |
| distinct segments touched, from address bits [32:28] | 16 | 26 |
| sub-region bases `--audit` READ | 6,723 | 6,723 |
| tensors `--audit` parsed / refused | 249 / 0 | 249 / 0 |
| descriptors in the inertness oracle | 699 per arm | 249 x 1 |
| descriptor words compared | 27,261 | (bases only: 6,723) |
| `fk33_load_weights plan` extents preflighted | 250 | 6,973 |
| `verify --headers-only` extents digested | 0 of 250 | **249 of 6,973** |
| `verify` full read-back extents digested | 250 of 250 | 6,973 of 6,973 |

**What this coverage does NOT reach, enumerated separately.**

1. **No striped image has ever been resident on the card.** Every number above
   is about files, manifests and descriptors. The residency backstop is
   exercised only against a 448 KB file-backed fake HBM in `selfcheck`.
2. **The `--audit` sub-region count is 6,723 both ways, and that is 249 x 27.**
   It does not include the 249 header pieces, which no descriptor base points
   at. `file_pieces` returns 6,973 because it includes them.
3. **One mv4i geometry family.** All 249 tensors are `ROWS_IF=48 AXI_DW=256
   GRP=1`, so `w_stride == s_stride` on every one of them. The extent bound and
   the file-offset join were exercised at exactly one stride ratio on real
   data. `gen_mv4i_desc --selftest` covers other geometries but not the piece
   path.
4. **`hbm_map`'s P1..P6 were exercised on one mutated tensor at a time.** No
   run mutated two objects at once, so nothing here says the fault list stays
   readable at scale.
5. **The 39 descriptor words compared in the oracle are the whole descriptor,
   but only ONE tensor's pieces were fed to `make_plan`.** The 249-tensor
   coverage is `build_descriptor`'s; `make_plan`'s cross-language coverage is
   `blk.0.ffn_gate.weight` alone, because each run compiles and runs
   `ref/mv_fk33_tr`.

---

## 6. Measured and REJECTED -- do not retry

| approach | how it died | do not retry |
|---|---|---|
| **Relax `check_bases` to accommodate striping** | Never needed. Striping moves no FILE offset, and the join is downstream of the check on the offset the check certified. MEASURED: 249 of 249 tensors agree by both rules under both layouts, unchanged | The brief's stop condition never fired. If it ever seems to, the `pieces` model is wrong |
| **Join the descriptor's bases to the manifest by lane index or by the piece's `kind`/`lane`/`segment` fields** | It certifies a layout it never saw -- PACKSTRIPE's T3, where two lanes sharing an address survived a distinct-segment check that read the label | Join on the file offset. It is the artefact two independent rules already agree on |
| **Trust the split base cross-check in `make_plan` to catch a misplaced piece** | MEASURED: `69 of 69 fields agree` with the address moved a whole segment, colliding, or shortened. The placement is on both sides and cancels | It is a file-layout check. Use `hbm_map.plan().check()`, which never sees the descriptor |
| **Take the 256 MiB stripe granule from `hbm.lane_stripe.segment_bytes`** | A manifest that lies about the granule then validates itself. Same failure shape as reading the `segment` label | DERIVE it (`HBM_TOP / 32`) and make the manifest's value a cross-check (P6), which is what M10 kills |
| **Give each piece-Region the object's declared `stack`** | 12 of 27 lanes are in stack 1 by design; the object's field is its header's. It would FAIL on a correct layout | Give pieces no declared stack and check the object's field against its header instead (P4) |
| **Derive a piece-Region's `stack_field` from its own address** | The check then compares `stack_of(base)` with `stack_of(base)`. It cannot fail | A check that cannot fail is decoration. Say so and delete it, or find a real second source |
| **Let `fk33_load_weights` fall back to the flat model when `hbm_map` cannot be imported** | Not a degraded check, a wrong one: it would write `nbytes` contiguous bytes from a header's address over 27 other lanes' arenas | Refuse. The flat fallback stays, flat-only, for a stripped checkout |
| **Hard-code 27 lanes, or 27/21/25 segments, from any of the three published tables** | The live manifest changed under the doc inside one working day: 27-wide/44,500 -> 25-segment/75,340, with up to 2 lanes per segment | Ask the manifest. Nothing in this change counts lanes or segments |
| **`git commit` with no pathspec while five tracks run** | Recorded in CLAUDE.md: the index is shared mutable state and a track lost six documents to it on 2026-08-29 | Pathspec form, on exclusively-owned files, which is what `263e0ee` used |

---

## 7. Measurement traps hit, including my own

1. **My first inertness run "found a bug" that was mine.** The extent bound
   raised `DescError` on `blk.0.ssm_alpha.weight` -- because my harness asked
   for `--rows 100` on a tensor with fewer than 100 rows. The tool was right
   and the caller was wrong. The lesson that survives is the one I then had to
   prove instead of assume: the bound cannot fire on a valid flat job, DERIVED
   from `tiles(n_rows) <= tiles(M)`, and MEASURED over 699 descriptors.
2. **The obvious attribution arm was worthless and looked authoritative.**
   Forcing the pre-change model produced a full column of kills -- including on
   the CONTROL. Ten seconds of reading it as "the old code caught everything"
   would have inverted every conclusion. It is printed with the explanation
   attached so the next reader cannot make that mistake either.
3. **The striped manifest on disk was NOT the one PACKSTRIPE's document
   described.** The doc said 27 segments and 44,500 tokens; the file said 25
   segments and 75,340. PACKSTRIPE appended its correction while this track was
   running. Read the artefact, not the write-up, and re-read it late.
4. **`fk33_run_job selfcheck` and `plan` both PASSED on the striped manifest
   before `make_plan` could see a misplacement.** A green run of the shipping
   tool on a mutated manifest is exactly what a two-copies-of-one-mistake check
   looks like from outside. It was found by mutating the manifest, not by
   reading the code, and the code had a comment saying the check was "the point".
5. **`fk33_run_job.py` has no `--dry-run` at the top level.** It is
   `fk33_run_job.py run --dry-run`; `plan` needs no flag and opens nothing.
   Two minutes lost to a usage error; noted so the next reader loses none.
6. **`tools/check_hbm_stack.py` still PASSES on a v2 manifest for the wrong
   reason.** PACKSTRIPE measured it: 7,154 ranges checked, zero of which exist.
   It is not in this track's ownership and was NOT fixed. Its verdict on a v2
   manifest is evidence in neither direction.

---

## 8. Open, not yet answered

1. **`hw/fk33/host/fk33_run_layer.py:996` builds a flat descriptor from
   `json.load`ed manifest entries and is out of reach of the
   `load_manifest` guard.** It is on the token path that produced this
   project's only silicon-proven result, so it was not touched. On a v2
   manifest it would emit a wrong program silently. It needs the same two
   lines `fk33_run_job.py` got.
2. **`tools/gen_layer_program.py` now REFUSES a v2 manifest rather than
   emitting the program.** That is correct and it is also a dead end: nothing
   can emit a token program for a striped set until it learns `pieces`. One
   line: `pieces=G.piece_extents(ent)` at line 704, plus `allow_striped=True`
   at its two `load_manifest` sites. Not done, because it is not this track's
   file and PACKSTRIPE may still be moving the layout.
3. **`tools/gen_lmhead_windows.py` and `tools/verify_mv4i_desc.py`** are in the
   same position and refuse cleanly. Same one-line fix each.
4. **`tools/check_mv4i_set.py` and `tools/check_hbm_stack.py` are untouched.**
   The first correctly refuses v2; the second wrongly passes it.
5. **`pack_model_fk33.expand_pieces()` is still a second producer** of the
   extent model. `hbm_map.file_pieces()` now exists and is the one it should
   call; the packer's copy should be deleted when PACKSTRIPE is done moving.
   This change is compatible with either -- a pre-expanded list has no
   `pieces` key and reads as flat.
6. **Nothing here says the striped image is correct on silicon.** It says the
   addresses are internally consistent, that four consumers agree about them,
   and that the read-back check would catch a swapped lane arena. The card test
   is PACKSTRIPE's section 8 and it is unchanged by this work.
7. **P1/P2 in `hbm_map` earned zero independent kills.** They are kept for the
   reason in section 4.3 and they are labelled. If a later reader wants to
   delete them, that judgement is available and this table is the input to it.
8. **The `attempted` coverage branch in `_verify` is still unreachable**, as
   its own comment says, and the new extent counter does not change that.

---

## 9. Commands

### 9.1 Offline arm -- no card, no `/dev`, safe for anyone

```bash
cd /home/orencollaco/GitHub/llama.vhdl
FLAT=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json
STRP=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json
SD=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd
SDS=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped
SCR=/mnt/storage/track-pieces

# 1  the map, both layouts.  Both must end PASS.
python3 tools/hbm_map.py "$FLAT" --markdown | tail -1
python3 tools/hbm_map.py "$STRP" --markdown | tail -1

# 2  placement preflight, both layouts.  Note "in N extents".
python3 hw/fk33/host/fk33_load_weights.py plan "$FLAT"
python3 hw/fk33/host/fk33_load_weights.py plan "$STRP"

# 3  every base of every tensor, both layouts.  6,723 each, 0 misaligned.
python3 tools/gen_mv4i_desc.py --audit --manifest "$FLAT"  | tail -6
python3 tools/gen_mv4i_desc.py --audit --manifest "$STRP"  | tail -6

# 4  one descriptor, striped.  w_base[0] must be 0x12142000, matching
#    PACKSTRIPE's own dry-run relocation table.
python3 tools/gen_mv4i_desc.py --mv4i "$SDS/blk.0.ffn_gate.weight.mv4i" \
        --manifest "$STRP" --rows 100 --x-exp -6 --print

# 5  the cross-language plan, both layouts.  69 of 69, "plan consistent".
python3 hw/fk33/host/fk33_run_job.py plan --mv4i "$SD/blk.0.ffn_gate.weight.mv4i" \
        --manifest "$FLAT" --rows 100 --x-exp -6 --slot 0 --scratch "$SCR/scratch"
python3 hw/fk33/host/fk33_run_job.py plan --mv4i "$SDS/blk.0.ffn_gate.weight.mv4i" \
        --manifest "$STRP" --rows 100 --x-exp -6 --slot 0 --scratch "$SCR/scratch"

# 6  the teeth.  22 rows, all "ok", including the six striped ones.
python3 hw/fk33/host/fk33_load_weights.py selfcheck | tail -30
python3 hw/fk33/host/fk33_run_job.py selfcheck --scratch "$SCR/scratch2" | grep ^selfcheck
python3 tools/gen_mv4i_desc.py --selftest | tail -1

# 7  this track's two harnesses (copies live beside this document)
python3 docs/debugging/2026-08-30_pieces-inert_pieces.py
python3 docs/debugging/2026-08-30_pieces-teeth_pieces.py --runjob

# 8  the guard.  This one MUST fail, rc=1.  If it emits 311 jobs, the guard
#    is gone and every A descriptor for a striped set is aimed at nothing.
python3 tools/gen_layer_program.py --manifest "$STRP" --token --x-exp -6 --print \
  ; echo "rc=$?  (1 is correct)"

# 9  the hardware boundary, re-proved
strace -f -qq -e trace=openat,open -o /tmp/pieces.strace \
  python3 hw/fk33/host/fk33_run_job.py plan \
    --mv4i "$SDS/blk.0.ffn_gate.weight.mv4i" --manifest "$STRP" \
    --rows 100 --x-exp -6 --slot 0 --scratch "$SCR/scratch" >/dev/null 2>&1
grep -c /dev/ /tmp/pieces.strace          # must be 0
```

### 9.2 Card arm -- OREN ONLY. NO AGENT RUNS THIS.

Nothing in this change alters PACKSTRIPE's section 8 test, which is still the
decisive one. What this change adds is that the loader and the verifier can now
place a striped set at all, so the following becomes possible where before it
was not. **HAZARD: writing a striped image puts bytes into segments 1..28,
which under the FLAT layout hold other tensors. Reload a flat image afterwards
or accept that the card holds a mixture.**

```bash
cd /home/orencollaco/GitHub/llama.vhdl
STRP=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json

python3 hw/fk33/host/fk33ctl.py id
python3 hw/fk33/host/fk33ctl.py vccint        # wiper 68, ~0.717 V.  NEVER 0.85 V.

# ONE tensor, striped, with the read-back.  Expect
#   "PASS every object written and its source bytes match the manifest digest"
#   "extents 28 of 28 digested"
#   "PASS the image on the card is the image the manifest describes (1 of 1 ...)"
python3 hw/fk33/host/fk33_load_weights.py load "$STRP" \
        --only blk.0.ffn_gate.weight --verify
```

### 9.3 Failure modes

| what you see | reading |
|---|---|
| `hbm_map` PASS on flat, `249 FAIL OVERLAP` on striped | `file_pieces()` is not being reached. Check that the manifest really carries `pieces` and that `tools/` is on `sys.path` |
| `PIECES P5: ... labelled segment N and its address ... decodes to segment M` | the manifest's label and its address disagree. The ADDRESS is what the hardware reads; treat the label as the suspect |
| `PIECES P6: ... striped at a N B granule` | the packer scraped a different granule out of `gen_pcieep.py` than `HBM_TOP/32`. Striping at the wrong granule puts every lane back on one pseudo-channel and still looks striped. Stop |
| `... is 'llama.vhdl FK33 load manifest v2 lane-striped': 249 of its 250 objects are LANE-STRIPED` | a tool that has not learned `pieces` was pointed at a striped manifest. Correct behaviour. Section 8 lists the four that do this and the one-line fix for each |
| `weight sub-region P is at file +N and the manifest places no piece there` | the manifest cuts the file somewhere other than the header's own 0x38 table. The two disagree about what a sub-region IS; do not adjust `check_bases` |
| `weight sub-region P would read N bytes from +S of an extent that is only M bytes` | the job would run off the end of its lane arena into another tensor's, without faulting. Either the job is too large or the piece is too small |
| `tools/hbm_map.py refuses this manifest's own address map` from `fk33_run_job` | the placement does not hold together. The 69-field cross-check would still have said `69 of 69`; this is the check that can see it |
| `cross-check 69 of 69` where you expected 42 | expected. The base check was split so each half can be named. The count is not a constant anywhere |
| `extents 249 of 6973 digested` under `--headers-only` | expected, and it is why the line exists. A striped object has one header and many payload extents; headers-only reads the header |
| `UNVERIFIED n of m objects were read by neither check` | a hole in the CHECKER, not the image. Still unreachable as far as anyone has managed to construct |

---

## 10. Corrections to the brief

- **"Four consumers ... must learn about `pieces`."** There are at least
  **eight** callers of the flat model. The four named are done. The fifth,
  `tools/gen_layer_program.py`, is the one that emits the token program and it
  was silently wrong; it and two others now refuse instead, via a guard in
  `gen_mv4i_desc.load_manifest()`. `hw/fk33/host/fk33_run_layer.py` is not
  reached by that guard and is open.
- **PACKSTRIPE section 7.5, "strictly stronger than the single check it
  replaces."** No. MEASURED `69 of 69 agree` with a piece address mutated. The
  split names the two halves honestly and adds no teeth; the teeth come from
  `hbm_map.plan().check()`, which `make_plan` now runs.
- **"`fk33_load_weights.py --verify` is the residency backstop."** It is, and
  it is now MEASURED to be: selfcheck row S4 kills the swapped lane arena that
  every structural rule accepts. Before this change no test in the tree
  exercised its striped path at all.
- **The brief's context table (27-lane/44,500, 21-segment/138,600,
  extent-aware/214,000).** Superseded by PACKSTRIPE's own same-day correction
  and by the artefact: **25 segments, at most 2 lanes each, 75,340 tokens.**
  No consumer in this change depends on any of those numbers.
- **"`check_bases` must NOT be relaxed ... if you need to, STOP."** The stop
  condition never fired. It was not touched, and section 6 records why it never
  needs to be.
