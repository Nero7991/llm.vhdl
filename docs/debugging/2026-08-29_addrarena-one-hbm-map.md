# One HBM address space, one model of it, and a check that bites

**Date:** 2026-08-29
**Track:** ADDRARENA
**Tree:** `fk33` branch. All work started from a pristine
`git archive 9d7a9e5` tree in the session scratchpad, and every "before"
number below was measured against that tree, not against a working copy.
HEAD was `9d7a9e5` at dispatch.
**Tools:** `python3` (`tools/hbm_map.py`, `tools/weights_residency.py`,
`tools/gen_layer_program.py`, `hw/fk33/host/fk33_load_weights.py`), `cc`
(gcc 11, via `server/Makefile` and via a temp-dir probe), `git archive`,
`free`, `df`.
**No hardware was touched.** Nothing here opened `/dev/xdma*`; no `xsdb`,
`hw_server`, `vivado ... program`, `hw/fk33/*.sh` or `hw/fk33/tcl/*` was run.
Every C program built here links `server/fk33_sim.c`, the simulated card.

**Machine, measured first.** `free -g`: 31 GB total, 4 free, 23 available,
25 GB of 31 GB swap free. `df -h`: root `/dev/nvme1n1p6` 1.3 T at **95%, 68 G
free**; `/mnt/storage` 916 G at 56%, **389 G free**. Nothing multi-GB was
written anywhere: the only large artefacts read are the packed set's
`manifest.json` (a few MB) under `/mnt/storage`, and the C probe compiles into
a `tempfile.TemporaryDirectory` that is deleted on exit. No new bytes on root.

---

## 1. The question, verbatim

> **Build the single source of truth for the 8 GiB HBM address space, and a
> check that BITES on overlap.**
>
> 1. **One authoritative map** of every region in the 8 GiB: weights, F32 blob,
>    GDN state, KV arena, host R_X / logits / D program, and the A descriptor
>    arena. WEIGHTS' `tools/weights_residency.py` is the auditor; extend or
>    build alongside it.
> 2. **An overlap check that FAILS**, wired so both producers consult it. Today
>    `gen_layer_program.py` and `pl_derive_bases()` are mutually blind; whatever
>    you build must make that impossible to reintroduce, not merely detect it
>    once.
> 3. **Teeth**: show the check going red on the CURRENT default (which genuinely
>    collides), and on at least one synthetic overlap it was not written
>    against. Report checks that do NOT bite under their own names.
> 4. If the fix needs a base address that is somebody's decision, use
>    `--desc-base 0x1FFADD000` as an INTERIM with a loud note, and say plainly
>    it is interim.

---

## 2. The answer, up front

**`tools/hbm_map.py` is now the only model of the 8 GiB, and the two producers
consult it instead of each other.** Concretely:

* `tools/gen_layer_program.py` no longer computes a descriptor address. It
  calls `hbm_map.plan()`, which places the arena in a map that already contains
  `pl_derive_bases()`'s three host blocks, and it **raises `SystemExit` rather
  than emitting a single descriptor** if the resulting map has any overlap.
  MEASURED: with the historic placement forced back on, it refuses (rc 1) and
  names both overlaps.
* `server/pl_backend.c::pl_check_bases()` gained the descriptor arena as a
  **fourth checked region**, on the same terms as the other three: alignment,
  bounds, the stack line, mutual overlap, and the weight image. MEASURED in
  the C: nine of ten arena placements give exactly the verdict written down
  for them before the run.
* `tools/weights_residency.py` **stopped being a fourth model**. It used to
  re-derive `pl_derive_bases()` in Python from the strides in
  `server/fk33_seam.h`; it is now a report over `hbm_map` plus the
  manifest-arithmetic checks that are genuinely its own.
* `hw/fk33/host/fk33_load_weights.py preflight()` now runs the WHOLE map, not
  only the packed objects, before a byte moves.
* `hbm_map.py --check-c` **compiles `server/pl_backend.c` and runs the real
  `pl_derive_bases()`**, requiring all seven derived values to match the Python
  mirror. That is the only evidence in the file; everything else is a claim.
  MEASURED: 7 of 7 match.

**The interim placement reproduces WEIGHTS' constant as a derivation, not a
constant.** `--policy below-host` puts the arena in the first 4 KB-aligned
block below the host's R_X staging. At the 9B shape that computes to
**`0x1_FFAD_D000`**, which is exactly the `--desc-base 0x1FFADD000` the brief
named. It is still INTERIM: which allocator owns the top of HBM, and whether
the arena is declared in the manifest (mechanism a) or allocated by
`pl_derive_bases()` (mechanism b), is Oren's decision. **Both mechanisms are
now implementable without further plumbing** -- `fk33_manifest` reads optional
`hbm.desc_arena_base` / `hbm.desc_arena_bytes`, and `pl_place_desc_arena()`
exists -- and **neither is chosen here.**

**Two new defects of the same class, neither in WEIGHTS' write-up:**

1. **The old arena base depended on the COMMAND LINE.** `need` was sized from
   the SELECTED steps, so `--layer N` and `--token` placed descriptors at
   different addresses out of the same program. MEASURED on the pristine
   `9d7a9e5` tree: `--token` put the first descriptor at `0x1FFFD9000`;
   `--layer 3` (7 A jobs) put it at **`0x1FFFFF000`, which is the host D
   program page base exactly**, so a single-layer emission landed all seven of
   its descriptors, 3,584 B, wholly inside the 4,096 B page the host writes its
   D program into.
2. **`max_chunk` moves the map and nothing in the manifest constrains it.** It
   comes from the card's CAPS at open time. A larger cap drags `x_base` DOWN
   through a fixed arena. Included as a teeth row
   (`max_chunk_grown_over_a_fixed_arena`), which goes red.

---

## 3. Corrections to the brief and to TRACK WEIGHTS

Reported under their own heading because the brief asked for them.

| claim | source | measured |
|---|---|---|
| the fix "costs 3 tokens of context" | brief, quoting WEIGHTS | **2 tokens.** 61,231 with the colliding top-down arena, 61,229 with `below-host`. Both are `floor(kv_bytes / 65,536)`. The manifest's own untouched figure is 61,311. |
| the arena overlaps the D program page by **3,584 B** | WEIGHTS | **Both are right, about different things.** The arena's *occupied* extent is 159,232 B (311 x 512) ending at `0x1FFFFFE00`, giving 3,584 B. `hbm_map` *reserves* whole 4 KB pages, 159,744 B ending at `0x200000000`, giving 4,096 B. The reserved figure is the conservative one and is what the check uses. |
| `--one-lmhead-job` "exits 1 by design" | brief | **It exits 2**, on both the pristine `9d7a9e5` tree and after this change. Behaviour is otherwise byte-identical; only the arena base moved. Verified side by side so the number in the brief cannot be blamed on this track. |
| `tools/gen_layer_program.py` defaults to the pre-qkv-pad set | brief, from WEIGHTS | **Confirmed.** `--manifest` still defaults to `.../qwen35-9b-mv4i/manifest.json`. Left as it is: changing a default under three concurrent tracks is not this track's call, and `place_desc_arena()` now refuses outright when there is no manifest at all. |
| `weights_residency.py` "reports it as a FAIL" | WEIGHTS | **Confirmed, and it exits 1.** Beware the measurement trap in section 6. |

---

## 4. The procedure, in the order it was run

Each step names what it isolates.

1. **Reproduce, on a pristine tree.** `git archive 9d7a9e5 | tar -x` into the
   scratchpad, then run WEIGHTS' auditor on the real manifest. Isolates "does
   the reported collision exist at the named sha", separately from anything in
   the working copy, which carries four other tracks' edits.
2. **Confirm the producer, not just the auditor.** Run
   `gen_layer_program.py --token` and read the descriptor addresses it actually
   emits. The auditor models the arena; this measures it. They agree:
   `0x1FFFD9000` first, `0x1FFFFFC00` last, 311 of 311 emitted.
3. **Confirm the other producer, in C.** Build a throwaway probe against
   `server/pl_backend.c` and print what `pl_derive_bases()` really computes.
   Isolates "is the Python mirror of the C correct today" from "is the C
   correct". It was correct: `x_base = 8584708096 = 0x1FFB04000`, matching the
   mirror exactly.
4. **Vary the command line.** Run the PRISTINE tool with `--layer 3` instead of
   `--token`. This is the step that found defect (1) in section 2: nothing in
   the brief or in WEIGHTS' write-up suggested the base moved, and it does.
5. **Build the one model** (`tools/hbm_map.py`), scraping
   `FK33_BLOCK_ALIGN` / `FK33_SEAM_HDR_BYTES` / `FK33_HBM_TOP` /
   `FK33_HBM_STACK_LINE` out of `server/fk33_seam.h` and `desc_maxb` /
   `axi_dw` out of `gen_mv4i_desc.FK33`, so no constant is restated.
6. **Wire the producers to it**, and make the wiring refuse rather than warn.
7. **Teeth, three separate populations**, because they measure different
   things: the Python map's `--self-test` (13 mutations of a real manifest),
   the C's arena table inside `--check-c` (10 placements), and the loader's
   whole-map preflight (3 manifests). All predictions written before the runs.
8. **Regress everything that consumes these files**: `seam_selftest` (84
   checks), `embed_e2e`, `fk33_load_weights.py selfcheck` (16 mutations),
   `tools/dprog_check.sh`, and `gen_layer_program.py` in `--shape sim`,
   `--no-a` and `--one-lmhead-job` modes.

---

## 5. The evidence, as raw output

### 5.1 The collision, at `9d7a9e5`, from the PRODUCER

```
$ python3 tools/gen_layer_program.py --token --x-exp 0 --no-hash --print \
    --manifest /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json
  step 1    blk.0.attn_qkv.weight   ... @0x1FFFD9000
  ...
  step 497  output.weight   rows 139008..156383 of 248320 ... @0x1FFFF000
  step 498  output.weight   rows 156384..173759 of 248320 ... @0x1FFFF200
  ...
  step 503  output.weight   rows 243264..248319 of 248320 ... @0x1FFFFFC00
  311 of 311 A jobs emitted, 0 refused
```

Steps 497..503 are seven descriptors, 3,584 B, at `0x1FFFFF000..0x1FFFFFE00`.
`pl_derive_bases()` puts the host's D program page at
`0x1FFFFF000..0x200000000`. DERIVED: they are the same 3,584 bytes.

### 5.2 The base moved with the command line (pristine tree, new finding)

```
$ python3 <9d7a9e5>/tools/gen_layer_program.py --layer 3 --close-token \
    --x-exp 0 --no-hash --print --manifest <noembd>/manifest.json
  step 49   blk.3.attn_q.weight ... @0x1FFFFF000
  step 50   blk.3.attn_k.weight ... @0x1FFFFF200
  step 51   blk.3.attn_v.weight ... @0x1FFFFF400
$ python3 <9d7a9e5>/tools/gen_layer_program.py --token ... | head -1
  step 1    blk.0.attn_qkv.weight ... @0x1FFFD9000
```

DERIVED: 7 A jobs x 512 B = 3,584; `(8 GiB - 3584) & ~0xFFF = 0x1FFFFF000`,
the host D program page base to the byte.

After the change, both give `0x1FFADD000`, because the arena is sized from the
whole token program:

```
$ python3 tools/gen_layer_program.py --layer 3 --close-token --x-exp 0 \
    --no-hash --print --manifest <noembd>/manifest.json | grep arena
A descriptor arena 0x1_ffad_d000 .. 0x1_ffb0_4000 (159744 B, 311 jobs in the
full token program, 7 selected here); checked disjoint against 256 regions
from 3 allocators
```

### 5.3 The producer now REFUSES

```
$ python3 tools/gen_layer_program.py --token --x-exp 0 --no-hash \
    --manifest <noembd>/manifest.json --desc-policy top-down
gen_layer_program: REFUSING to emit A descriptors -- the HBM map has 2
overlap/placement fault(s).  See tools/hbm_map.py.
  OVERLAP: <host logits writeback> 0x1_fff0_c000..0x1_ffff_e840 (placed by
    pl_derive_bases()) and <A descriptor arena> 0x1_fffd_9000..0x2_0000_0000
    (placed by gen_layer_program.py) share 153664 bytes
  OVERLAP: <A descriptor arena> 0x1_fffd_9000..0x2_0000_0000 (placed by
    gen_layer_program.py) and <host D program> 0x1_ffff_f000..0x2_0000_0000
    (placed by pl_derive_bases()) share 4096 bytes
rc=1
```

The same refusal fires on `--desc-base 0x1FFFD9000`, i.e. an operator asking
for the historic address by hand is refused too.

### 5.4 The clean map

```
$ python3 tools/hbm_map.py <noembd>/manifest.json
region                          base            end           bytes       GiB  placed by              note
packed weights + F32 blob        0x0  0x1_0b78_f000   4,487,442,432    4.1793  pack_model_fk33.py     250 objects, 8876032 B of stack-line hole
gdn recurrent state    0x1_0c00_6000  0x1_1080_6000      75,497,472    0.0703  pack_model_fk33.py
kv arena 0             0x1_1080_6000  0x1_ffad_d000   4,012,732,416    3.7371  pack_model_fk33.py     61229 tokens at 65536 B/token, after the charge
A descriptor arena     0x1_ffad_d000  0x1_ffb0_4000         159,744    0.0001  gen_layer_program.py   NOT reserved by the manifest
host R_X staging       0x1_ffb0_4000  0x1_fff0_c000       4,227,072    0.0039  pl_derive_bases()      NOT reserved by the manifest
host logits writeback  0x1_fff0_c000  0x1_ffff_e840         993,344    0.0009  pl_derive_bases()      NOT reserved by the manifest
host D program         0x1_ffff_f000  0x2_0000_0000           4,096    0.0000  pl_derive_bases()      NOT reserved by the manifest

device      8,589,934,592 B = 8.0000 GiB
accounted   8,589,932,608 B = 8.0000 GiB
unaccounted 1,984 B
PASS  every region is aligned, in range, in one stack, and disjoint across all 3 allocators
```

`unaccounted 1,984 B` is the padding between the end of the logits row and the
D program page: DERIVED, `0x1FFFFF000 - 0x1FFFFE840 = 0x7C0 = 1,984`. It falls
out of `l_span` being 64-B aligned (`FK33_BLOCK_ALIGN`) while `desc_ptr` is
4 KB aligned. It is a gap, not an overlap, and is reported rather than
absorbed.

### 5.5 The C, compiled and executed

```
$ python3 tools/hbm_map.py <noembd>/manifest.json --check-c
ok    x_base = 0x1_ffb0_4000  (C and Python agree)
ok    x_span = 0x40_8000  (C and Python agree)
ok    l_base = 0x1_fff0_c000  (C and Python agree)
ok    l_span = 0xf_2840  (C and Python agree)
ok    desc_ptr = 0x1_ffff_f000  (C and Python agree)
ok    desc_span = 0x1000  (C and Python agree)
ok    hbm_top = 0x2_0000_0000  (C and Python agree)
ok    pl_check_bases arena case none                   base=0x0 span=0 -> rc 0 (wanted 0)
ok    pl_check_bases arena case historic_top_down      base=0x1_fffd_9000 span=159744 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case on_d_program           base=0x1_ffff_f000 span=4096 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case on_logits_tail         base=0x1_ffff_d000 span=4096 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case on_r_x                 base=0x1_ffb0_4000 span=4096 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case aligned_512_not_4k     base=0x1_ffad_c200 span=159744 -> rc 0 (wanted 0)
ok    pl_check_bases arena case misaligned_64          base=0x1_ffad_c040 span=159744 -> rc 3 (wanted nonzero)
ok    pl_check_bases arena case past_top               base=0x1_ffff_f000 span=8192 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case straddles_stack_line   base=0xffff_f000 span=8192 -> rc 4 (wanted nonzero)
ok    pl_check_bases arena case place_below_host       base=0x1_ffad_d000 span=159744 -> rc 0 (wanted 0)
```

rc 1 is `FK33_SEAM_ERR_POS`, 3 is `FK33_SEAM_ERR_ALIGN`, 4 is
`FK33_SEAM_ERR_STACK`.

### 5.6 The Python map's teeth, 13 mutations

```
$ python3 tools/hbm_map.py <noembd>/manifest.json --self-test
mutation                                  want   got   n  verdict
control_clean                            green green   0  ok
arena_historic_top_down                    RED   RED   2  ok
arena_on_weight_image                      RED   RED   1  ok
arena_straddles_stack_line                 RED   RED   2  ok
arena_unaligned                            RED   RED   4  ok
arena_past_top                             RED   RED   2  ok
max_chunk_grown_over_a_fixed_arena         RED   RED   1  ok
two_packed_tensors_on_one_address          RED   RED   1  ok
gdn_state_moved_into_the_kv_arena          RED   RED   1  ok
a_tensor_declares_the_wrong_stack          RED   RED   1  ok
a_tensor_straddles_the_stack_line          RED   RED   4  ok
arena_inside_the_kv_arena_only           green green   0  ok
arena_right_place_wrong_jobcount         green green   0  ok

TEETH PASS  every mutation gave the verdict written down for it before it ran
```

### 5.7 The manifest-arithmetic checks still bite

Four independent corruptions of a copied manifest, through
`tools/weights_residency.py`:

```
max_context_tokens+1       rc=1  FAIL  max_context_tokens: manifest 61312, 4018118656 bytes / 65536 per token = 61311
weights_bytes-4096         rc=1  FAIL  weights_bytes: manifest 4487438336, placements sum to 4487442432
stack_hole_bytes=0         rc=1  FAIL  stack_hole_bytes: manifest 0, the gaps between consecutive placements sum to 8876032
f32 entry hbm_offset+8     rc=1  FAIL  f32 entry blk.0.ssm_dt.bias: hbm_offset 4491898888 is not blob base 4491747328 + 151552
```

### 5.8 The loader's whole-map preflight, and that it sees what the old one could not

```
control (unmutated)                                  want=green got=green ok
gdn state moved into the kv arena                    want=RED   got=RED   ok
   FAIL  WHOLE MAP: OVERLAP: <kv arena 0> ... and <gdn recurrent state> ...
hbm.size shrunk so host blocks land on the GDN state want=RED   got=RED
   whole-map-fails=3 other=0  ok
   FAIL  WHOLE MAP: <gdn recurrent state>: 0x1_0c00_6000..0x1_1080_6000 is outside the 4.2500 GiB map
```

The last row is the important one: **3 fails, all from the whole-map check and
0 from the per-object pass**, so the new check is not merely re-detecting what
the old one already caught.

### 5.9 Regression of everything downstream

```
server/seam_selftest                 SEAM_SELFTEST PASS  (84 checks, 0 failed)
server/embed_e2e                     EMBED_E2E PASS  (0 failed)
fk33_load_weights.py selfcheck       PASS  every check was shown to fail on a defect it claims to catch
tools/dprog_check.sh                 DPROG_CHECK: PASS   (505 steps, 39330 checks, 0 FAIL; control FAILs as required)
gen_layer_program --shape sim        rc=0
gen_layer_program --no-a             rc=0
gen_layer_program --one-lmhead-job   rc=2, 296 of 297 emitted, 1 refused -- IDENTICAL to 9d7a9e5
```

No `sim/tb_*.vhd` was added, so the shared VHDL gate gains no row and its
`BASELINE_PASS` is untouched.

---

## 6. Measured and REJECTED -- do not retry

**Placing the arena at the top and moving the host blocks down instead.**
REJECTED without implementing. The host blocks' top-down placement is
load-bearing and documented in `pl_backend.c`: coming down from the top makes
them the first thing a growing image or a growing KV cache meets, so a
collision is a refusal at open time rather than a silently overwritten weight.
Inverting that trades a loud failure for a quiet one. The arena is the movable
party because it is produced offline by a tool that can be told an address.

**Making `weights_residency.py` the single source of truth by having the
producers import it.** REJECTED. It is a REPORT with a `main()` that prints a
residency table and checks manifest arithmetic; importing it from
`gen_layer_program.py` would drag the report into the producer and would leave
the address model living inside a tool whose name says it is about weights.
The model moved OUT of it instead.

**A second Python copy of `pl_derive_bases()` kept in step by review.** MEASURED
as the failure mode already: `weights_residency.py` carried exactly that copy,
it was correct on the day it was written, and nothing would have told anyone if
`pl_backend.c` had changed. Replaced by `--check-c`, which compiles the C.

**Restating the seam constants as Python literals.** REJECTED on the recorded
precedent in `gen_layer_program.py`: the `nsub_w` literal `29` agreed with a
wrong `29` in the VHDL package and the agreement proved nothing. `hbm_map.py`
scrapes `server/fk33_seam.h` and raises rather than defaulting when the scrape
stops matching.

**`--desc-jobs 0` (descriptors in host memory) as the fix.** NOT rejected, but
NOT chosen: it is a real arrangement, it is one flag, and it makes the arena
question disappear rather than answering it. It is Oren's to pick, and the map
supports it today (`--desc-jobs 0`).

**Refusing in `hbm_map.plan()` when the host blocks cannot be modelled.** Tried
and REVERTED, with the reason kept in the code. It broke
`fk33_load_weights.py selfcheck`, whose synthetic images carry no
`output.weight` and therefore no shape: 16 of its own checks went red for a
reason that had nothing to do with them. A tool that refuses to run is a tool
nobody runs. The strictness is now a parameter: PRODUCERS get
`strict_arena=True` (guessing an address is the defect); AUDITORS get the
report plus a loud note that no arena is in the map.

---

## 7. Measurement traps hit, including my own

**`rc=$?` after a pipeline reads the LAST command's status.** The first check
of `weights_residency.py`'s exit code was `python3 ... | tail -30; echo rc=$?`,
which printed `rc=0` while the tool had exited 1 and printed two FAILs on the
screen above. Ten seconds from concluding that WEIGHTS' auditor could not fail.
Use `${PIPESTATUS[0]}`, or redirect and check separately.

**A teeth case that fires for the wrong reason is not a passing teeth case.**
The C case `aligned_512_not_4k` was built as `x_base - 159744 + 512`, intending
"512-aligned but not 4 KB aligned, so it must be ACCEPTED". It was refused --
correctly, because it also ran 512 B into R_X. Read at face value it says
`pl_check_bases()` demands 4 KB alignment, which it does not. Rebuilt as
`x_base - 159744 - 4096 + 512`, clear of every other block, and it passes. The
original construction is kept in a comment: a case that cannot separate two
reasons for a refusal is not measuring the one it names.

**An artefact of the KV charge masquerading as the fault under test.** The KV
arena is DEFINED as everything above the GDN state, so `carve_kv()` shortens it
to the lowest top-anchored base. Taking `min()` over EVERY top-anchored region
meant a mutation that put the arena at address 0 shrank the KV arena to zero,
and the first reported fault was `nbytes 0 is not positive` -- true, and not
what the mutation was testing. The charge is now applied only by a reservation
that actually sits INSIDE the extent; a reservation below it collides with
whatever is down there, and the overlap check says so on its own.

**Reading `159,232` and `159,744` as a disagreement.** They are the occupied
extent and the page-rounded reservation of the same arena. Every derived
overlap figure inherits the difference, which is why WEIGHTS reports 3,584 B
against the D page and this map reports 4,096.

**A large mutation can be caught by the wrong check.** Shifting the whole
image up by `0x1FF000000` to test the loader's new whole-map pass was caught
by the PRE-EXISTING per-object bound check instead, so it proved nothing about
the new one. Reported as a non-biting row for the new check, and replaced with
the `hbm.size` mutation in 5.8, which the per-object pass cannot see at all.

---

## 8. Checks that do NOT bite, under their own names

The most valuable section on re-reading. Each of these is a real limit, not an
oversight, and none should be mistaken for coverage.

**`arena_inside_the_kv_arena_only` -- green by design.** A top-anchored
reservation placed 1 GiB into the KV arena is a CAPACITY CHARGE, not a
collision, and the map shortens the arena and restates the context instead of
failing. If it failed, every legitimate placement would fail, because the KV
arena is defined as everything above the GDN state. The consequence: **the map
cannot tell you that you have priced yourself out of context.** It prints the
restated `max_context_tokens` and leaves the judgement to a reader.

**`arena_right_place_wrong_jobcount` -- green by design.** An arena of the
right size in the right place, holding the wrong descriptors, is invisible
here and always will be. The map sees ADDRESSES. Contents are
`gen_layer_program.py`'s `rtl_would_reject` and
`fk33_load_weights.py verify`'s digests.

**`pl_check_bases` case `none` -- green by design, and this is the one to
watch.** `arena_span == 0` means "no arena was declared" and passes. That is
the state every existing caller is in, including `seam_selftest`'s 84 checks
and `embed_e2e`. The protection is a `pl_open` warning printed every time,
naming the historic address and the 153,664 B. **A warning is weaker than a
refusal**, and it was chosen only because making a declared arena mandatory
would break every current caller of a function whose owning decision is still
open. If Oren picks either mechanism, this should become a refusal.

**`aligned_512_not_4k` -- green, and it means the C is LOOSER than the Python.**
`pl_check_bases()` demands 512-B alignment of the arena (matching `desc_ptr`);
`hbm_map.check()` demands 4 KB of every region. A 512-aligned arena would be
accepted by the C and rejected by the map. Recorded rather than harmonised,
because 512 is the descriptor stride and 4 KB is the allocation granularity,
and both are defensible. Nothing produces such an address today.

**The map cannot see the F32 blob's 177 internal entries.** They are sub-ranges
of one object, not Regions. They are checked only by
`weights_residency.check_manifest_arithmetic()`.

**Header-only verification, restated from WEIGHTS because it still holds.**
246 of 249 packed tensors share their entire header with a sibling; a header
check is a 33 ms screen and never a verdict.

---

## 9. Open, not yet answered

1. **THE MECHANISM IS STILL OREN'S.** `--policy below-host` is INTERIM. Both
   options are now buildable: manifest keys (`hbm.desc_arena_base` /
   `hbm.desc_arena_bytes`, read by `fk33_manifest.c`, printed by
   `hbm_map.py --emit-manifest-hbm`) or a fourth `pl_derive_bases()` block
   (`pl_place_desc_arena()`). **Neither is wired into `pack_model_fk33.py`**,
   which is not this track's file, so no shipped manifest declares an arena
   today.
2. **`max_chunk` is unconstrained by anything in the map.** It comes from CAPS.
   Nothing checks that the `max_chunk` a host opens with is the one the arena
   was placed under. That is a runtime cross-check nobody performs.
3. **`--manifest`'s default is still the pre-qkv-pad set.** Deliberately left.
4. **Whether the A descriptors reach the card through HBM at all** is still the
   open integration decision `gen_layer_program.py`'s own docstring records.
   If they end up in host memory the arena disappears and so does this
   collision; this work is then a check that never fires, which is a fine
   outcome and not a wasted one.
5. **`arena_span == 0` still passes `pl_check_bases()`.** See section 8.
