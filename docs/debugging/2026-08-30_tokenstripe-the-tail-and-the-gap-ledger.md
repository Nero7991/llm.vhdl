# Can the lm-head tail of the token path learn `pieces`, and can `weights_residency`'s `stack_hole_bytes` rule be made right for a layout with by-design arena gaps instead of muted?

**Date:** 2026-08-30. Branch `fpga`. **TRACK TOKENSTRIPE.** Base commit
`2c66e89` (HEAD moved to `a8053ca` while this ran; see section 7 trap 6).

**No hardware was touched.** Nothing below ran `xsdb`, `hw_server`,
`vivado ... program`, `hw/fk33/pcieep.sh`, `hw/fk33/jtag.sh`,
`hw/fk33/flash.sh`, anything under `hw/fk33/tcl/`, or any `hw/fk33/host/*`
against the card. Eight offline commands were traced with
`strace -f -qq -e trace=openat,open`: **zero `/dev` opens of any kind**,
section 4.7. Section 9 is a command list with its card arm separated and
unrun.

**Tools named:** `python3` over `hw/fk33/host/fk33_run_token.py` (`plan`,
`selfcheck`, `--help`, and `make_tail` driven directly),
`hw/fk33/host/fk33_run_layer.py`, `tools/weights_residency.py`,
`tools/hbm_map.py`, `tools/gen_mv4i_desc.py`, `tools/gen_layer_program.py`,
`tools/gen_lmhead_windows.py`, `tools/check_hbm_stack.py`,
`hw/fk33/host/fk33_load_weights.py`; `strace`; `diff`; `git show`,
`git rev-parse`, `git log`.

**THE MANIFESTS THIS WAS MEASURED AGAINST, pinned by hash.** PACKSTRIPE has
moved this file under two separate tracks already and STRIPEPATH's headline
numbers stopped reproducing because of it. `sha256sum`:

```
697bc32c7389e216691f04a175080f565b6e35542e9a5a772f77b63e6bcc17e6  /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json
  size=117219    mtime=2026-08-29 18:07:55 -0600     (v1 flat, 250 objects)
5e5df0839dac2377c97e1810003a4cff2f5808118d67d530c1b2a47ac7fc2938  /mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json
  size=1177349   mtime=2026-08-30 07:48:26 -0600     (v2 lane-striped, 250 objects, 249 striped)
```

**No number from another document is quoted here without being re-measured.**

Labels: **MEASURED** (a named tool ran), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement with its assumption and its falsifier stated).

---

## 1. The question, verbatim

> **`hw/fk33/host/fk33_run_token.py:1103` is a sixth consumer with the identical
> defect and it is on the token path**, emitting the lm-head's 15 window
> descriptors. Same two lines. **Until it lands, a striped set gives a correct
> 32-layer body and a wrong lm-head.** Not my file.
>
> **`tools/weights_residency.py` fails on a striped manifest** for a reason
> unrelated to what it guards (`stack_hole_bytes` computed for the flat layout
> vs 2.69 GiB of by-design arena gaps). **Needs an owner before it gets muted.**
>
> Do NOT simply mute `weights_residency.py`. It is a guard. ... the fix is to
> make `stack_hole_bytes` correct for a layout with by-design arena gaps, NOT
> to widen a tolerance until it stops complaining. If you conclude the guard is
> genuinely obsolete, say so with the argument, do not quietly delete it.

---

## 2. The answers, up front

**The tail was emitting a wrong lm-head silently, and it is now measured how
wrong.** MEASURED on the pre-change file against the shipping striped
manifest: **15 window descriptors emitted, 0 errors, and 405 of 405 sub-region
bases wrong** -- every one `hbm_offset + <file offset>` where `hbm_offset`
names a 4 KB header. Three lines fixed it: `"pieces"` in `TailJob.__slots__`,
`j.pieces = G.piece_extents(ent)` in `make_tail`, and `pieces=j.pieces` at the
`build_descriptor` call.

**AND THE DEFECT WAS INVISIBLE TO THE OBVIOUS TEST.** `output.weight.mv4i` is
placed at `hbm_offset` **0 under BOTH layouts** (MEASURED, and its
`blake2b_128` is the same in both manifests), so the pre-change tail's 15
descriptors are **byte-identical between the flat and the striped manifest**.
Diffing the two runs against each other shows nothing at all. Only a comparison
against the manifest's own `pieces` sees it. This is why the defect survived a
track that was looking straight at it.

**Inertness on the flat set, quantified.** MEASURED: the 15 tail descriptors,
**585 descriptor words, byte-identical** to the pre-edit dump; and
`fk33_run_token.py plan` over four layers plus the whole tail (37 lines
including the 248,320-logit oracle) **identical** between the working tree and
the file at its last commit.

**Discrimination on the striped set.** MEASURED by an oracle that re-derives
every base from the .mv4i's own 0x38 table and the manifest's raw `pieces`
JSON, importing neither `gen_mv4i_desc` nor `hbm_map`: **405 of 405 bases MOVE,
0 wrong, and the lm-head goes from 3 distinct pseudo-channels to 25**, read
from address bits [32:28].

**The tail fix earns ZERO independent detections and that is measured, not
assumed.** MEASURED, 9 mutants x 2 arms: the pre-change file refuses all nine,
with an identical message, because `make_token` calls
`fk33_run_layer.make_layer` for every layer before reaching `make_tail`, and
each of those calls `place_desc_arena()`, which runs `hbm_map.plan().check()`
and raises. **A 33rd copy of that check would earn nothing.** Its value is 405
bases made right.

**`weights_residency.py`'s rule was not obsolete, it was fitted to one
layout.** `stack_hole_bytes` is not "the gaps": `pack_model_fk33.place()`
returns `hole` **only** for bytes skipped so an object does not straddle the
4 GiB stack line, and the `--stripe-lanes` branch never calls `place()`, so its
value is structurally 0. The old one-line check compared it against the sum of
**all** inter-placement gaps. Those two quantities coincide under the flat
layout for one unstated reason -- **a bump allocator leaves no other gaps** --
so the check agreed with its subject by coincidence of geometry on every
manifest it had ever seen. That is this project's recorded dominant defect
class, arrived at from the producer side.

**It is now a closed ledger and it balances to the byte.** Every empty byte
between the weight placements must be accounted for by something the manifest
declares: a `stack_holes` entry, the unused tail of a declared lane arena, or a
segment declared reserved. DERIVED and MEASURED on the striped set:

```
2,690,994,176 total inter-placement gap bytes
  =         0  hbm.stack_hole_bytes
  + 2,422,558,720  the declared lane arena tails (25 arenas, the last excluded)
  +   268,435,456  segment 16, declared in hbm.lane_stripe.reserved_segments
```

**It is STRICTER on the flat layout than the rule it replaced, not looser.**
The old rule compared TOTALS, so a `stack_holes` entry at the wrong address, a
`stack_holes` list disagreeing with its own `stack_hole_bytes`, and an emptied
`stack_holes` list all passed. All three now fail (teeth rows R12, R13, R14),
and the pre-change file survives all three.

**Its output on a flat manifest is byte-identical.** MEASURED across **four
different flat manifests**, 124 report lines, `diff` clean -- including the
four pre-existing FAILs on the oldest one, which are reproduced unchanged.

**Teeth, with attribution: 15 of 15 rows behave as designed.** The ledger earns
**10 independent kills** against an arm with the whole ledger removed. Inside
it, one arm per rule: containment 1, occupancy 1, reserved-segment 1, and the
`stack_holes` LIST rule 4. **Three rows are reported as earning the ledger
NOTHING under their own names** (S1b, S5, S6 -- section 6).

---

## 3. The procedure, in the order it was run

| # | step | what it isolates |
|---|---|---|
| 1 | pin both manifests by `sha256sum` before reading either | the trap that killed two previous documents' numbers |
| 2 | dump the 15 tail descriptors on BOTH layouts with the PRE-change file | the control, on disk, before the new path existed |
| 3 | an oracle re-deriving every striped base from the .mv4i header + raw `pieces` JSON | sizes the defect at 405 of 405 before it is fixed |
| 4 | the three-line edit | -- |
| 5 | re-dump and `diff`; and `fk33_run_token.py plan` on both revisions | inertness, twice, by two different instruments |
| 6 | run the oracle again | discrimination |
| 7 | 9 mutants x 2 arms on the tail | whether the fix detects anything. It does not, and that is the finding |
| 8 | run `weights_residency` on FOUR flat manifests and the striped one, PRE and POST | the second file's control set |
| 9 | derive the gap structure of the striped set by hand before writing any rule | so the rule matches the producer rather than the one manifest |
| 10 | read `pack_model_fk33.place()` and `lane_stripe_plan()` for what the fields MEAN | the difference between fixing a guard and widening it |
| 11 | 15 mutants x 7 arms, one arm per new rule | which rule bit, not merely that one did |
| 12 | `strace` on eight offline commands | the hardware boundary, as evidence rather than as a claim |

---

## 4. The evidence, raw

### 4.1 The size of the defect on the token tail, BEFORE fixing it

```
TOKENSTRIPE DISCRIMINATION CONTROL -- fk33_run_token.py make_tail
  windows compared            15
  windows byte-identical      15 (must be 0)
  sub-region bases compared   405
  bases that MOVED            0
  bases unchanged             405
  bases WRONG vs the manifest 405 [('output.weight w00', 'w', 0, 4096, 268435456), ...]
  distinct segments, FLAT     3 [0, 1, 2]
  distinct segments, STRIPED  3 [0, 1, 2]
  -> FAIL the pieces path is NOT live
```

The first wrong base is the whole story: the pre-change file aims window 0's
first weight sub-region at **4096**, the byte after the header, where the
manifest places it at **268,435,456**, the base of segment 1.

### 4.2 Inertness on the flat set, two instruments

```
$ diff tail_flat_PRE.json tail_flat_POST.json
IDENTICAL 15 window descriptors, 585 words
```

DERIVED: `15 x 39 = 585 descriptor words byte-identical`.

```
$ fk33_run_token.py plan --ref ref_bfp.r9bs --manifest <FLAT> --packed <FLAT> \
      --only-layers 0,7,15,31        (timings normalised, everything else verbatim)
NEW    lines=37
TOKPRE lines=37
PLAN OUTPUT IDENTICAL (flat manifest, 4 layers + the whole tail)
```

That second instrument includes the tail's own oracle, which re-runs the
lm-head on the host and compares 248,320 logits against the reference's LOGITS
record.

### 4.3 Discrimination on the striped set

```
TOKENSTRIPE DISCRIMINATION CONTROL -- fk33_run_token.py make_tail
  windows compared            15
  windows byte-identical      0 (must be 0)
  sub-region bases compared   405
  bases that MOVED            405
  bases unchanged             0
  bases WRONG vs the manifest 0 []
  distinct segments, FLAT     3 [0, 1, 2]
  distinct segments, STRIPED  25 [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                                  17, 18, 19, 20, 21, 22, 23, 24, 25, 26]
  -> PASS the pieces path is LIVE
```

**Why this is an oracle.** The `want` value is built by a program that opens the
.mv4i and unpacks its 0x38 table with `struct`, reads `pieces` out of raw JSON,
and recovers the row-window skip **as the residue of the FLAT dump's own base
arithmetic**, so the skip never comes from the striped side. It imports neither
`gen_mv4i_desc` nor `hbm_map`, so it can inherit neither `sub_base`'s join nor
`file_pieces`. Segments are read from `addr // 256 MiB`, never from a piece's
`segment` label.

### 4.4 The tail fix earns zero independent detections

Arms: `NEW` the working tree; `TOKPRE` = `fk33_run_token.py` at its last commit
(`c309572`) with everything else at HEAD. Mutants are STRIPEPATH's, retargeted
at `output.weight.mv4i`, which is the tensor the tail actually reads.

```
mutant   what it does                                         NEW       TOKPRE
control  the striped manifest, untouched                      -         -
T1       one lm-head piece moved a whole 256 MiB segment up   KILL      KILL
T2       one lm-head piece misaligned by 1 byte               KILL      KILL
T3       two lm-head pieces given the SAME address            KILL      KILL
T4       a piece's segment LABEL changed, address untouched   KILL      KILL
T7       one lm-head piece deleted from the list              KILL      KILL
T9       a piece straddling the 4 GiB HBM STACK boundary      KILL      KILL
T10      the object's hbm_offset points at piece 5, not the header KILL  KILL
T11      one piece's nbytes doubled                           KILL      KILL
T12      ALL 27 lm-head lanes into ONE pseudo-channel         KILL      KILL
kills (control excluded): NEW=9  TOKPRE=9
INDEPENDENT kills earned by this change: 0
```

The control SURVIVES in both arms, so the column attributes. The refusal is
character-for-character the same on both, and it names its origin:

```
--- T9 NEW rc=1 ---
gen_layer_program: REFUSING to emit A descriptors -- the HBM map has 1 overlap/placement fault(s).  See tools/hbm_map.py.
  output.weight.mv4i:2: 0xfff8_0000..0x1_013b_6000 CONTAINS the stack line 0x1_0000_0000; an out-of-stack read does not fault, it returns the wrong bytes and reports success
--- T9 TOKPRE rc=1 ---
gen_layer_program: REFUSING to emit A descriptors -- the HBM map has 1 overlap/placement fault(s).  See tools/hbm_map.py.
  output.weight.mv4i:2: 0xfff8_0000..0x1_013b_6000 CONTAINS the stack line 0x1_0000_0000; an out-of-stack read does not fault, it returns the wrong bytes and reports success
```

**This settles the "same two lines" question for this path.** No
`hbm_map.plan().check()` was added to `make_tail`. `make_token` calls
`fk33_run_layer.make_layer` for every one of the 32 layers before reaching the
tail, and each call runs `place_desc_arena()`, which runs one and raises. The
check is already there 32 times over. This is the same correction STRIPEPATH
made for `fk33_run_layer`, confirmed independently on this path rather than
copied.

**T12 is still the hole nothing closes.** It is killed here only incidentally,
by `hbm_map` seeing the resulting overlap. A 27-lanes-in-one-pseudo-channel
layout that did NOT overlap anything would pass every consumer either track has
touched. Only `pack_model_fk33.check_lane_stripe()` check 1, which reads
`ENG_PORT_MAP`, can see it. Inherited from STRIPEPATH unchanged.

### 4.5 The gap structure of the striped set, derived before any rule was written

MEASURED, 6,973 placements, **exactly 25 inter-placement gaps**, each running
from the top of one segment arena's occupancy to the base of the next:

```
  gap at 0x555000     size 262844416   seg 0 -> 1   after nonmatvec_f32.bin
  gap at 0x19e4e000   size 102440960   seg 1 -> 2   after blk.9.ssm_out.weight.mv4i:1
  ...
  gap at 0xf9e4e000   size 370876416   seg 15 -> 17  <-- 256 MiB of this is segment 16
  ...
  gap at 0x19bde4000  size 69320704    seg 25 -> 26
n gaps: 25   total: 2690994176
```

The declared arenas, read from `hbm.lane_stripe`:

```
  seg  0 base 0x0          bytes 5591040    capacity 268435456  tail 262844416
  seg  1 base 0x10000000   bytes 165994496  capacity 268435456  tail 102440960
  ... (segments 1..15 identical)
  seg 17 base 0x110000000  bytes 199188480  capacity 268435456  tail 69246976
  ... (segments 17..26)
sum of ALL 26 declared tails: 2491879424
```

DERIVED: `2,491,879,424 - 69,320,704` (the segment 26 tail, which lies above
the last placement and is therefore not an inter-placement gap)
`+ 268,435,456` (segment 16, reserved, skipped whole) `= 2,690,994,176`.
**Exact, to the byte.** And the same three-term identity on the flat set is
`8,876,032 = 8,876,032 + 0 + 0`.

MEASURED, and this is what made the rule safe to write: **0 placements outside
a declared arena, 0 arenas whose declared `bytes` is not the extent its pieces
occupy, and 0 interior holes across all 6,973 placements.** Segment 16 is the
only unclaimed segment inside the weight span, and it is declared reserved.

### 4.6 `weights_residency` inertness, four flat manifests

```
=========== INERTNESS SWEEP, weights_residency.py, four FLAT manifests ===========
  qwen35-9b-mv4i           IDENTICAL  (33 lines)
  qwen35-9b-mv4i-noembd    IDENTICAL  (31 lines)
  qwen35-9b-mv4i-qkvpad    IDENTICAL  (30 lines)
  qwen35-9b-mv4i-stackfix  IDENTICAL  (30 lines)
--- and the 4 pre-existing FAILs on qwen35-9b-mv4i, PRE and POST alike ---
FAIL  NO REGION BLOCK: the manifest's hbm block does not declare desc_arena_base, ...
FAIL  blk.7.ffn_gate.weight.mv4i: 0xfe57_4000..0x1_0007_5000 CONTAINS the stack line ...
FAIL  max_context_tokens: manifest 52756, 0 bytes / 65536 per token = 0
FAIL  free_after_gdn 3457441792 is not the KV extent total 0
```

Those four are an old manifest packed before the region block existed. They are
**not** this track's and they are reproduced unchanged, which is the point of
including that manifest in the sweep.

And on the striped set, the whole delta:

```
31,33c31
< FAIL  stack_hole_bytes: manifest 0, the gaps between consecutive placements sum to 2690994176
<
< 1 FAIL
---
> PASS  every region is aligned, in range, in one stack, and disjoint, and the manifest agrees with its own placements
```

### 4.7 Teeth, 15 mutants x 7 arms

Arms: `NEW` the working tree; `NOGAP` = NEW with `check_gap_accounting`
removed **entirely** (the outer attribution: a row both kill is a row some
older property already caught); `NOA1`/`NOA2`/`NOA3` = NEW with exactly one of
the three arena rules removed; `NOLIST` = NEW with the `stack_holes` LIST
unread, i.e. the old total-only semantic; `PRE` = the file before this track.

**Every arm's control survives on both shipping manifests except `PRE`, whose
control dies on the striped one.** That column therefore carries no
attribution and is printed to say so -- the same trap STRIPEPATH recorded for
its `OFF` and `PRE` columns, hit again.

```
FLAT manifest (v1) -- the inherited rows plus the new list rules
mutant   what it does                                         NEW    NOGAP  NOA1   NOA2   NOA3   NOLIST PRE
control  the flat manifest, untouched                         -      -      -      -      -      -      -       ok
R7       hbm.stack_hole_bytes zeroed                          KILL   -      KILL   KILL   KILL   KILL   KILL    ok
R12      a stack_holes entry moved 4 KB up                    KILL   -      KILL   KILL   KILL   -      -       ok
R13      a stack_holes entry 4 KB short, the total left alone KILL   -      KILL   KILL   KILL   -      -       ok
R14      the stack_holes list emptied, the total left alone   KILL   -      KILL   KILL   KILL   -      -       ok
kills per arm (control excluded): NEW=4  NOGAP=0  NOA1=4  NOA2=4  NOA3=4  NOLIST=1  PRE=1
rows behaving as designed: 5 of 5

STRIPED manifest (v2) -- the lane arena rules
mutant   what it does                                         NEW    NOGAP  NOA1   NOA2   NOA3   NOLIST PRE
control  the striped manifest, untouched                      -      -      -      -      -      -      KILL    ok
S1a      a piece moved into RESERVED segment 16               KILL   -      KILL   KILL   KILL   KILL   KILL    ok
S1b      a piece parked in RESERVED segment 27 (LEDGER EARNS NOTHING) KILL KILL KILL KILL KILL KILL KILL  ok
S1c      the same, with the vacated arena's `bytes` corrected KILL   -      -      KILL   KILL   KILL   KILL    ok
S2a      an arena's declared `bytes` 4 KB too large           KILL   -      KILL   KILL   KILL   KILL   KILL    ok
S2b      an arena's declared `bytes` 4 KB too small           KILL   -      KILL   -      KILL   KILL   KILL    ok
S3       segment 16 dropped from reserved_segments            KILL   -      KILL   KILL   -      KILL   KILL    ok
S4       stack_hole_bytes 4096 with an empty stack_holes list KILL   -      KILL   KILL   KILL   -      KILL    ok
S5       two SAME-SIZE pieces swapped (EXPECTED NOT TO BITE)  KILL   KILL   KILL   KILL   KILL   KILL   KILL    ok
S6       a piece's segment LABEL changed (EXPECTED NOT TO BITE) KILL KILL KILL KILL KILL KILL KILL      ok
kills per arm (control excluded): NEW=9  NOGAP=3  NOA1=8  NOA2=8  NOA3=8  NOLIST=8  PRE=9
rows behaving as designed: 10 of 10

TEETH: PASS
```

Reading it:

| check | independent kills | verdict |
|---|---|---|
| the gap ledger as a whole (vs `NOGAP`) | R7, R12, R13, R14, S1a, S1c, S2a, S2b, S3, S4 (**10**) | earns its place |
| A1 CONTAINMENT (a placement inside a declared arena) | **S1c** (1) | earns its place, but only just, and only on the constructed row. Every simpler version of "a piece in the wrong segment" is caught by something else first: A2's occupancy if the vacated arena's `bytes` is left stale, `hbm_map`'s PIECES P5 if the `segment` label is left stale, `hbm_map`'s OVERLAP if it lands on the GDN state. **S1c is the row where every one of those is made consistent around the moved piece, and containment is then the only thing in the program that can see it.** That row is exactly the silent-corruption case the striping exists to prevent: a lane reading a pseudo-channel its master is not wired to |
| A2 OCCUPANCY (`bytes` is the extent the pieces run) | **S2b** (1) | earns its place. `S2a` dies in every arm because an over-large `bytes` also shrinks the declared tail and leaves an unaccounted residue, so only the under-declaration is attributable |
| A3 RESERVED SEGMENTS (an empty segment must be declared) | **S3** (1) | earns its place. Without it, a whole 256 MiB pseudo-channel can be left out of the layout with nothing to say so |
| the `stack_holes` LIST rule (read the list, not just the total) | **R12, R13, R14, S4** (4) | earns its place, and it is the part that makes this stricter on the FLAT layout than the rule it replaced. `PRE` survives all four |

**Rows on which this change earns NOTHING, under their own names:**

* **S1b** -- a piece parked in reserved segment 27. `NOGAP` kills it too:
  segment 27 is where the GDN recurrent state lives, so `hbm_map` reports
  `OVERLAP ... and <gdn recurrent state> ... share 352256 bytes` and the
  pre-existing `weights_end` rule reports the moved end. The row is kept to
  record **which segments the older properties already cover** -- 27..31 are
  covered by the GDN and KV regions, and 16 is not covered by anything except
  A1/A3.
* **S5** -- two same-size pieces of one tensor exchanged. Every extent is
  identical, so the ledger is blind by construction; it is an ADDRESS ledger,
  not an identity check. It is killed by `hbm_map`, not by anything here. This
  is the same resolution floor the 2026-08-29 table recorded as R10/R11 and it
  is the file's division of labour, not a gap.
* **S6** -- a piece's `segment` LABEL changed, address untouched. Every rule
  added here reads address bits, deliberately: PACKSTRIPE's T3 is the recorded
  case of a check that counted the label and certified a layout it never saw.
  The kill belongs to `hbm_map`'s PIECES P5.

### 4.8 The hardware boundary, as evidence

`strace -f -qq -e trace=openat,open` on eight offline commands:

```
wr_flat:       lines=126     /dev/xdma opens=0  any /dev opens=0
wr_striped:    lines=126     /dev/xdma opens=0  any /dev opens=0
tail_flat:     lines=145     /dev/xdma opens=0  any /dev opens=0
tail_strp:     lines=145     /dev/xdma opens=0  any /dev opens=0
oracle:        lines=92      /dev/xdma opens=0  any /dev opens=0
teeth_wr:      lines=13552   /dev/xdma opens=0  any /dev opens=0
teeth_tail:    lines=2851    /dev/xdma opens=0  any /dev opens=0
selfcheck:     lines=135     /dev/xdma opens=0  any /dev opens=0
--- proof the tracer was working: real opens seen ---
"/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json"
"/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/blk.0.attn_qkv.weight.mv4i"
"/home/orencollaco/GitHub/llama.vhdl/rtl/model_cfg_pkg.vhd"
```

### 4.9 Neighbouring gates, re-run unchanged

```
tools/hbm_map.py            flat     PASS  every region is aligned, in range, in one stack, and disjoint across all 3 allocators
tools/hbm_map.py            striped  PASS  (same line)
tools/check_hbm_stack.py    flat     0 of 250 entries are LANE-STRIPED ... PASS no range crosses a stack boundary
tools/check_hbm_stack.py    striped  249 of 250 entries are LANE-STRIPED, contributing 6972 piece ranges ... PASS
tools/gen_mv4i_desc.py --selftest    SELFTEST PASS
fk33_load_weights selfcheck          PASS  every check was shown to fail on a defect it claims to catch
gen_layer_program --token striped    311 of 311 A jobs emitted, 0 refused
gen_lmhead_windows striped           WINDOW SET PASS
fk33_run_token.py selfcheck          PASS over 13 checks, none of which needs a model, a card or /dev
python3 -m py_compile <both files>   OK
```

---

## 5. Coverage, stated -- how many were READ, not how many passed

| thing | flat set | striped set |
|---|---|---|
| manifest objects read | 250 | 250 |
| of which lane-striped | 0 | 249 |
| `make_tail` windows / descriptor words / sub-region bases | 15 / 585 / 405 | 15 / 585 / 405 |
| descriptor words byte-identical, flat | **585** | -- |
| `fk33_run_token plan` lines diffed, two revisions | 37 | -- |
| logits the tail's own oracle compared | 248,320 | -- |
| `weights_residency` MANIFESTS swept, PRE and POST | **4** | 1 |
| `weights_residency` report lines diffed | **124** | 33 |
| weight placements the ledger walked | 250 | **6,973** |
| inter-placement gaps classified | 1 | **25** |
| declared lane arenas checked for containment and occupancy | 0 | **26** |
| teeth invocations | 5 x 7 = 35 | 10 x 7 = 70, plus 10 x 2 = 20 on the tail |

**What this coverage does NOT reach, enumerated separately.**

1. **No striped image has ever been resident on the card**, so nothing here is
   a statement about silicon. Inherited from PIECES and STRIPEPATH, unchanged.
2. **The card has never judged a striped lm-head descriptor.** Acceptance is
   asserted only by `rtl_would_reject`, which is Python restating the RTL's
   `S_CHECK`. No GHDL was run: two synthesis lanes were committed and
   `ghdl-mcode` has been MEASURED at 20.9 GiB in one process.
3. **`fk33_run_token.py plan` was NOT run end to end on the striped set.** The
   striped packed directory has **no `index.txt`**, so the host re-run stops
   before the first layer with
   `.../qwen35-9b-mv4i-noembd-striped/index.txt does not exist`. The program
   build, the arena, and the 15-window layout were all reached and are
   identical on both revisions; the host oracle was not. Open item 3.
4. **One mv4i geometry family** (ROWS_IF=48 AXI_DW=256 GRP=1), so
   `w_stride == s_stride` on all 249. Inherited.
5. **Every teeth mutant perturbs ONE object or ONE field.** Nothing says two
   faults do not mask each other, and nothing says the fault lists stay
   readable at scale.
6. **The ledger has been shown correct on ONE striped layout.** Its three
   terms were derived from `pack_model_fk33.place()` and `lane_stripe_plan()`
   rather than fitted to that layout -- which is the whole point of section
   4.5 preceding the rule rather than following it -- but a second striped
   layout (a different `--stripe-stack1-segments`) has not been run through
   it. **That is the single cheapest thing that would falsify this work**,
   section 8 item 5.
7. **Nothing here checks a lane's pieces land in the segment its engine MASTER
   is wired to.** That needs `ENG_PORT_MAP` and is
   `pack_model_fk33.check_lane_stripe()` check 1. `hbm.lane_stripe.checks` in
   the manifest is that function's PACK-TIME self-report copied in, i.e. a
   claim; nothing here reads it, deliberately, because a checker that reads
   another checker's recorded verdict has checked nothing.

---

## 6. Measured and REJECTED -- do not retry

| approach | how it died | do not retry |
|---|---|---|
| **Mute, relax or delete the `stack_hole_bytes` check** | Not measured to death -- rejected on the argument, and then the argument was checked against the producer. `place()` returns `hole` only for stack-boundary skips; the striped branch never calls it. The field is not obsolete and it is not wrong; the CHECK was fitted to one layout. Widening it would have discarded R7, R12, R13, R14 and S4 | Read what the producer writes into the field before deciding what the consumer should compare it to |
| **Fix it by making the packer declare 2.69 GiB in `stack_hole_bytes`** | Would make the field mean two different things on the two layouts and would still not say WHERE the gaps are. Also not available: `tools/pack_model_fk33.py` is PACKSTRIPE's | The consumer learns the layout; the field keeps one meaning |
| **Compare the gap total against `sum(capacity - bytes)` over the declared arenas** | An identity between two manifest fields. It balances by construction and has no teeth: S2a and S2b both move both sides. MEASURED -- it is `NOA2`, which survives S2b | Derive the occupancy from the PLACEMENTS and compare THAT to the declared `bytes`, which is what A2 does |
| **Require the pieces of an arena to be strictly CONTIGUOUS from its base** | Would refuse a correct packing on any future geometry whose sub-region size is not a 4 KB multiple, because `take()` pads. `bytes` is `fill[s]`, a bump pointer, i.e. an EXTENT | Check the EXTENT. An interior hole is not waved through: it is an inter-placement gap and the ledger reports it with its address |
| **Use `NOARENA` (the whole lane-arena half disabled) to attribute the arena rules** | MEASURED: its CONTROL dies with 10 FAILs on the striped manifest, so every striped row is a kill and nothing is distinguishable. Same shape as STRIPEPATH's `OFF` column | One arm per rule (`NOA1`, `NOA2`, `NOA3`), each with a surviving control, plus `NOGAP` as the outer attribution |
| **Read the teeth verdict off the program's exit code alone** | MEASURED: S5 and S6 "killed" under every arm and looked like ledger detections. They are `hbm_map`'s. The first table credited this change with 8 kills it had not earned | Attribute against an arm with the check removed. `NOGAP` reduced NEW=9 to 6 real ones on the striped set |
| **Mutate a piece's address without also fixing its `segment` LABEL** | MEASURED: `hbm_map`'s `PIECES P5 ... is labelled segment 2 and its address 0x1_0000_0000 decodes to segment 16` fires first, so the row measures P5 and not containment | Keep every other declaration consistent around the mutation. That is what `_park(..., fix_arena=True)` is for |
| **Add `hbm_map.plan().check()` to `make_tail`, copying `fk33_run_job.make_plan`** | It is already in the path 32 times over: `make_token` calls `make_layer` per layer and each runs `place_desc_arena()`. MEASURED: the pre-change file refuses all 9 tail mutants with an identical message | Read what the call chain already does. This is the second track to record this correction |
| **Write the mutated manifest into a bare scratch directory for the tail teeth** | MEASURED: `make_tail` opens `output.weight.mv4i` beside the manifest, so every row died on `FileNotFoundError` -- the control included, and a column whose control dies attributes nothing. STRIPEPATH's trap 5, from a different direction | A full symlink farm of the model directory with one real `manifest.json` |
| **Assume `fk33_run_token.py` cannot be exercised without the card** | STRIPEPATH recorded "running it needs the card". MEASURED: `plan` ("no card, no /dev") and `selfcheck` ("no card, no model") are both subcommands, both were run here, and both traced clean | Read `--help` before concluding a host tool needs hardware |
| **Diff the pre-change tail's FLAT run against its STRIPED run to see the defect** | MEASURED: `output.weight.mv4i` is at `hbm_offset` 0 in BOTH manifests, so all 15 descriptors are byte-identical across the two layouts. The diff is empty and the program is wrong | Compare against the manifest's `pieces`, never against the other layout's output |
| **`git commit` with no pathspec while other tracks run** | Recorded in CLAUDE.md; a track lost six documents to it on 2026-08-29 | Pathspec form on exclusively-owned files, which is what section 10 used |

---

## 7. Measurement traps hit, including my own

1. **The first teeth table credited this change with 8 kills it had not
   earned.** Without an arm that removes the ledger entirely, S5 and S6 read as
   detections when both belong to `hbm_map`. The tell was that they were rows
   explicitly designed NOT to bite and they bit anyway. **A mutant you expect to
   survive is worth more than one you expect to kill, because when it kills
   instead it tells you your instrument is measuring something else.**
2. **The `PRE` arm produced five identical nonsense lines before it produced
   anything.** Run from a scratch directory it died in `hbm_map`, which
   resolves `rtl/model_cfg_pkg.vhd` from `dirname(dirname(__file__))`. Every
   manifest "failed" with the same message, which looked like a real result.
   Fixed with a complete symlink farm including `rtl`, `server`, `hw` and
   `sim`. Same class as STRIPEPATH's trap 5, which is now the second and third
   occurrence in two days: **an arm built from symlinks is a harness, and a
   harness failure is indistinguishable from a code failure unless the control
   passes first.**
3. **`tail -1` on a pipeline reports the PIPELINE's exit code, not the
   program's.** The first `weights_residency` measurement printed `rc=0` for a
   run that had just printed `1 FAIL`. Every exit code in this document is
   taken from the program directly.
4. **An old manifest in the sweep looked like a regression.**
   `qwen35-9b-mv4i` reports 4 FAILs under the new file. It reports the same 4
   under the old one -- it predates the region block. Including it was right
   and reading its rc without the PRE arm beside it would have been wrong.
5. **The striped `plan` run printed its `index.txt` error at the TOP**, above
   fifteen lines of successful program build, so the tail of the output looked
   like a clean truncation rather than a refusal. Read the whole file.
6. **HEAD moved twice while this ran** (`2c66e89` -> `a8053ca`). `git rev-parse
   HEAD` is captured as its own step and the PRE arms are pinned to the last
   commit that touched each file (`b28e92b` for `weights_residency.py`,
   `c309572` for `fk33_run_token.py`), not to HEAD.

---

## 8. Open, not yet answered

1. **Nothing has confirmed the striped lm-head reads the right BYTES.** This
   document proves 405 bases land where the manifest places the file offset. It
   does not prove the manifest places them where the data is. That is
   `fk33_load_weights.py load --verify` plus a card run, section 9.2.
2. **The `NOEXT`-class question for A1.** Containment earns exactly one kill,
   on a row constructed specifically for it. It is kept because that row is the
   defect striping exists to prevent, and because without it A2's occupancy is
   computed over a subset. **Deleting it is an available judgement and this
   table is the input to it**, exactly as STRIPEPATH said of its extent rule.
3. **The striped packed directory has no `index.txt`.** So
   `fk33_run_token.py plan` and anything else needing the host's f32 index
   cannot run against it. `python3 tools/ref9b/make_index.py <striped dir>` is
   what the tool itself suggests; it was not run because that directory is
   PACKSTRIPE's artefact, not this track's.
4. **`pack_model_fk33.expand_pieces()` is still a second producer** of the
   extent model. Nothing here reads it: the ledger reads `hbm.lane_stripe` and
   the placements `hbm_map` builds. Reported, not edited; PACKSTRIPE owns that
   file.
5. **The ledger has seen ONE striped layout.** Repacking with a different
   `--stripe-stack1-segments` changes the arena count, the reserved list and
   the tail sizes, and is the cheapest available falsifier. **ESTIMATE, and the
   assumption is load-bearing: the three-term identity holds for any layout the
   current packer can emit, because the three terms are the only ways
   `lane_stripe_plan()` and `place()` can leave a byte empty. What would
   falsify it: any repack whose `weights_residency` run reports an unaccounted
   range.**
6. **`tools/check_mv4i_set.py` still refuses a v2 manifest** with 249 failures.
   Correct behaviour for a tool that has not been taught; untouched. Inherited
   from STRIPEPATH.
7. **T12 remains unclosed** and is now recorded by two tracks. See 4.4.
8. **Nothing here says the striped image is faster.** STRIPEPATH's section 10
   states that prediction; this track adds nothing to it and did not run it.

---

## 9. Commands

### 9.1 Offline arm -- no card, no `/dev`, safe for anyone

```bash
cd /home/orencollaco/GitHub/llama.vhdl
SD=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd
SDS=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped

# 0  pin the manifests FIRST.  Both hashes are in the header of this document;
#    if either differs, no number below is quotable.
sha256sum $SD/manifest.json $SDS/manifest.json

# 1  the gap ledger, both layouts.  BOTH must end PASS.  Before this change the
#    striped one ended `stack_hole_bytes: manifest 0, the gaps ... 2690994176`.
python3 tools/weights_residency.py $SD/manifest.json  | tail -1
python3 tools/weights_residency.py $SDS/manifest.json | tail -1

# 2  the 15 lm-head window descriptors, both layouts.
python3 docs/debugging/2026-08-30_tokenstripe-tail_desc_dump.py $SD/manifest.json  /tmp/tail_flat.json
python3 docs/debugging/2026-08-30_tokenstripe-tail_desc_dump.py $SDS/manifest.json /tmp/tail_strp.json
#    "jobs with pieces 0 / jobs flat 15" on the flat set and the reverse on the
#    striped one.  Either way round is the tell.

# 3  the oracle.  Must read 405 bases MOVED, 0 WRONG, 3 -> 25 segments.
python3 docs/debugging/2026-08-30_tokenstripe-oracle.py \
        /tmp/tail_flat.json /tmp/tail_strp.json $SD/manifest.json $SDS/manifest.json $SDS

# 4  the tail's own offline gates.  Neither needs a card.
python3 hw/fk33/host/fk33_run_token.py selfcheck | tail -3
python3 hw/fk33/host/fk33_run_token.py plan --ref /mnt/storage/ref9b/ref_bfp.r9bs \
        --manifest $SD/manifest.json --packed $SD --only-layers 0,7,15,31 | tail -8

# 5  the teeth.  15 of 15 rows must behave; TEETH: PASS.  The arms live under
#    /mnt/storage/track-tokenstripe/arm_*/ and are rebuilt by hand -- see
#    section 4.7 for what each one disables.
python3 docs/debugging/2026-08-30_tokenstripe-teeth_residency.py | tail -3
python3 docs/debugging/2026-08-30_tokenstripe-teeth_tail.py      | tail -2

# 6  the neighbours, unchanged
python3 tools/hbm_map.py $SDS/manifest.json --markdown | tail -1
python3 tools/check_hbm_stack.py $SDS | tail -2
python3 tools/gen_layer_program.py --manifest $SDS/manifest.json --token --x-exp -6 --print | tail -1

# 7  the hardware boundary, re-proved
strace -f -qq -e trace=openat,open -o /tmp/ts.strace \
  python3 docs/debugging/2026-08-30_tokenstripe-tail_desc_dump.py $SDS/manifest.json /tmp/x.json >/dev/null 2>&1
grep -c '"/dev/' /tmp/ts.strace          # must be 0
```

The teeth harnesses write only into `/mnt/storage/track-tokenstripe/mut/` and
`/mnt/storage/track-tokenstripe/tailmut/`, both of which are symlink farms of a
model directory plus one `manifest.json` they write and remove. Neither ever
writes into a model directory.

### 9.2 Card arm -- OREN ONLY. NO AGENT RUNS THIS.

Unchanged from STRIPEPATH section 9.2, with **one line of it now expected to
succeed that was expected to fail**:

```bash
# STRIPEPATH's step 4 said:
#   "a whole token.  EXPECT THE LM-HEAD TO BE WRONG until open item 1 lands"
# Open item 1 has landed.  The prediction is now:
python3 hw/fk33/host/fk33_run_token.py run --manifest "$STRP"
```

**PREDICTION, stated in advance.** With the striped set resident and verified,
the whole token is bit-exact against the reference -- **body AND logits**. The
lm-head was the one part STRIPEPATH knew was wrong and it was wrong in a
specific, measured way: every one of its 405 sub-region bases pointed
`hbm_offset + <file offset>` into segment 0, 1 or 2. Those are real, mapped
addresses holding OTHER tensors' data, so the failure mode is not a fault --
it is 248,320 plausible wrong logits.

**What falsifies it:**

* **The 32-layer body bit-exact and the logits still wrong** means the tail's
  bases are right and something else in the lm-head path is not. Compare one
  window's `w_base[0]` against the manifest's `pieces` with the oracle in 9.1
  step 3 BEFORE looking anywhere else.
* **The body wrong too** is not this change; it is STRIPEPATH's territory or
  the image on the card is not the striped one.
* **A refusal from `gen_layer_program: REFUSING to emit A descriptors`** means
  the manifest itself does not hold together and no descriptor was built. Run
  `tools/weights_residency.py` and `tools/hbm_map.py` on it first.

**Prerequisite that is NOT this track's**: the striped packed directory needs
an `index.txt` before `plan` can cross-check on the host (open item 3). The
card `run` path does not need it.

---

## 10. Corrections to the brief, and the landing

* **"Same two lines."** It was three: `TailJob.__slots__` also needed
  `"pieces"`, because the class uses `__slots__` and an unlisted attribute
  raises `AttributeError`. The brief warned that "the same two lines" had been
  wrong once already; it was wrong again, in a different place.
* **"Check whether the same is true on your path before adding one."**
  Correct, and it is: no `hbm_map.plan().check()` was added. MEASURED in 4.4,
  and for a stronger reason than `fk33_run_layer`'s -- the token path runs that
  check 32 times before reaching the tail.
* **STRIPEPATH's "`fk33_run_token.py` was not run ... running it needs the
  card" is wrong.** `plan` and `selfcheck` are both offline subcommands and
  both were run here. Correction recorded against section 5 item 7 of
  `2026-08-30_stripepath-five-emitters.md`.
* **STRIPEPATH's section 9.2 step 4** ("EXPECT THE LM-HEAD TO BE WRONG") is
  superseded by this landing. Section 9.2 above states the replacement
  prediction.
* **The brief's framing of the `weights_residency` failure** -- "`stack_hole_bytes`
  computed for the flat layout vs 2.69 GiB of by-design arena gaps" -- is
  right about the symptom and slightly off about the location. The manifest's
  `stack_hole_bytes` is correct and means what it has always meant; it is the
  CHECKER's re-derivation of it that was flat-only. That distinction is what
  made the fix a consumer change rather than a packer change, which matters
  because the packer is another track's file.
