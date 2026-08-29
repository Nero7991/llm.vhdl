# The manifest is the authority, and the optional key is gone

**Date:** 2026-08-29
**Track:** ARENA-MANIFEST
**Tree:** `fk33` branch. Every "before" number was measured against a pristine
`git archive 3e93bed` tree in the session scratchpad, not against a working
copy carrying three other tracks' edits. HEAD was **`3e93bed`** at dispatch
(the brief named `a802780`, which was five commits back by then).
**Tools:** `python3` (`tools/hbm_map.py`, `tools/pack_model_fk33.py`,
`tools/gen_layer_program.py`, `tools/weights_residency.py`,
`tools/check_mv4i_set.py`, `hw/fk33/host/fk33_load_weights.py`), `cc`
(gcc 11, via `server/Makefile` and two throwaway probes), `git archive`,
`free`, `df`.
**No hardware was touched.** Nothing here opened `/dev/xdma*`; no `xsdb`,
`hw_server`, `vivado ... program`, `hw/fk33/*.sh`, `hw/fk33/tcl/*` or
`hw/fk33/host/fk33ctl.py` was run. Every C binary built here links
`server/fk33_sim.c`, the simulated card.

**Machine, measured first.** `df -h`: root `/dev/nvme1n1p6` 1.3 T at **97%,
39 G free**; `/mnt/storage` 916 G at 56%, **389 G free**. `free -g`: 31 GB
total, 6 free, **26 available**, 27 of 31 GB swap free. A Vivado synthesis was
running throughout. Root was 39 G free at the start and 39 G free at the end;
nothing multi-GB was written anywhere. The one scare is in section 7.

---

## 1. The question, verbatim

> **OREN HAS DECIDED. Implement it.**
> TRACK ADDRARENA built both options and deliberately left the MECHANISM
> question open. **Oren chose (a): a region block in the manifest is the
> authority.**
>
> 1. **The packer emits the region block.** `pack_model_fk33.py` should write
>    the descriptor arena, and ideally every region `tools/hbm_map.py` models,
>    into the manifest's `hbm` block at pack time.
> 2. **Both consumers READ it and neither computes it.** A producer that
>    invents an address should be impossible, not merely checked.
> 3. **Make the optional keys MANDATORY**, or say precisely why they cannot be
>    yet. `arena_span == 0` still PASSES `pl_check_bases()` and is protected
>    only by a warning. A warning that reads as "checked" is how this defect
>    survived in the first place.
> 4. **Retire the interim.** `--policy below-host` derives `0x1FFADD000` and
>    labels it INTERIM everywhere. With the manifest as authority that should
>    become a real allocation, not a policy fallback.
> 5. **Extend to the unallocated regions if cheap.** Nothing currently
>    allocates *within* the GDN state or KV arenas. Say what that would take
>    even if you do not do it.

---

## 2. The answer, up front

**The address is chosen once, at pack time, by one function, and written into
the manifest. Every consumer reads it and none can compute it.** Concretely:

* `tools/hbm_map.py::derive_region_block()` is now **the only function in the
  repository that chooses an arena address.** `tools/pack_model_fk33.py` calls
  it while writing `manifest.json`; `hbm_map.py --write-manifest-hbm` calls it
  to migrate a set packed before the block existed. Nothing else allocates.
* `plan(policy="manifest")` is the default and does **no placement arithmetic
  at all** — it reads `hbm.desc_arena_base`. `gen_layer_program.py`,
  `weights_residency.py` and `fk33_load_weights.py` all go through it, with
  `strict_arena=True` for the producer, so a manifest with no block is a
  **refusal**, not a re-derivation. Two producers agreeing is not a state this
  address space can reach any more, because only one of them can allocate.
* **The keys are MANDATORY.** `server/fk33_manifest.c` requires
  `hbm.desc_arena_base`, `hbm.desc_arena_bytes` and `hbm.host_max_chunk`
  exactly once each, and range-checks all three. MEASURED: 8 of 8 mutations of
  a real manifest are refused, control passes (section 5.3).
* **`arena_span == 0` no longer passes `pl_check_bases()`.** It returns
  `FK33_SEAM_ERR_POS`. `pl_derive_bases()` calls a new static
  `check_geometry()` instead, because it places the three HOST blocks and the
  fourth region arrives one call later; there is one implementation of every
  arithmetic rule and two entry points to it. MEASURED: the `--check-c` row
  `none` flipped from `rc 0 (wanted 0)` to `rc 1 (wanted nonzero)`.
* **The interim is retired.** `--policy below-host` is renamed
  `allocate-below-host` and is now the **allocation rule**, not a consumer
  fallback; the word INTERIM is gone from the module. It still derives
  `0x1_FFAD_D000` at the 9B shape, and the migrated manifests carry exactly
  that. MEASURED: `--token` and `--layer 3` now give the identical base, and
  the last descriptor lands at `0x1FFB03C00`, `0x400` below the host's
  `x_base` — the reservation fits to the page.
* **`max_chunk` is pinned**, closing ADDRARENA's open item 2. `pl_open()`
  refuses a card whose CAPS `max_chunk` **exceeds** the pinned value.
  One direction only, and the asymmetry is DERIVED, not chosen:
  `x_base = align_down(l_base - x_stride*max_chunk)` decreases monotonically in
  `max_chunk`, so a smaller cap can only move `x_base` **up**, away from the
  arena. MEASURED at the `pl_open` level: cap 512 opens, cap 8 opens, cap 1024
  is refused (section 5.4).

**Four unplanned findings, none in the brief:**

1. **`pack_model_fk33.py` reserves both unallocated arenas for a model that is
   not this one.** MEASURED: `GDN_STATE_BYTES = 48 * 6144 * 128 * 2` and
   `KV_BYTES_PER_TOKEN = 16 * 4 * 256 * 2 * 2`, i.e. **48 GDN layers and 16
   attention layers**, while `gen_layer_program.QWEN35_9B` is 32 blocks at
   `attn_interval 4` = **8 attention and 24 GDN**. Both reservations are 2x the
   shape's. The KV one is the expensive half: 65,536 B/token where 32,768 would
   do, which is **half the context this card can hold**. Over-reservation is
   SAFE, so nothing was changed and nothing refuses it; see section 8.
2. **The original `qwen35-9b-mv4i` set cannot be migrated, and the refusal is
   correct.** `derive_region_block()` declined to write a block into it:
   `blk.7.ffn_gate.weight.mv4i: 0xfe57_4000..0x1_0007_5000 CONTAINS the stack
   line`. That is the pre-`stackfix` defect, and the new allocator refuses to
   declare an address inside a map that is already broken. It is also the set
   `gen_layer_program.py --manifest` still DEFAULTS to.
3. **`server/tests/seam_selftest.c` needed exactly one line**, not the ten the
   breakage suggested: all ten failing `pl_open` sites go through one
   `small_opts()` helper.
4. **`embed_e2e`'s case F stopped isolating what it names.** It is the control
   asserting that case E's refusal comes from the MANIFEST and not from a new
   constant; with a mandatory arena it was being refused for a third, unrelated
   reason. One line restores the isolation. Recorded because a control that
   fails for a new reason is worse than no control.

---

## 3. Corrections to the brief

Reported under their own heading because the brief asked for them.

| claim | source | measured |
|---|---|---|
| ADDRARENA is at `a802780`, work should be measured against it | brief | **HEAD was `3e93bed`** at dispatch, five commits later (`seamgate` x3, `realfix` x1). All work here started from `git archive 3e93bed`. |
| `--one-lmhead-job` exits **2** by design | brief | **Confirmed**, still 2 after this change. |
| `tools/gen_layer_program.py` defaults to the PRE-QKV-PAD set | brief | **Confirmed and now worse in a useful way.** That set is `qwen35-9b-mv4i`, which is the one whose map is broken (finding 2), so the default now REFUSES outright instead of quietly using a bad set. Still not changed: the default is not this track's call under three concurrent tracks. |
| `max_chunk` "moves the map and nothing in the manifest constrains it... ADDRARENA has a teeth row for this; it goes red" | brief | **Confirmed and closed.** `hbm.host_max_chunk` pins it. ADDRARENA's row `max_chunk_grown_over_a_fixed_arena` was SUPERSEDED rather than deleted, for the reason in section 7. |
| the fix costs 2 tokens of context, 61,231 -> 61,229 | brief, from ADDRARENA | **Confirmed by a different route.** `hbm_map` reports the charge as 5,386,240 B = **82 tokens** off the manifest's own 61,311, giving 61,229. |
| `--check-c` is the only real evidence in `hbm_map.py`; keep that property | brief | **Kept, and it grew.** 7 of 7 derived values still match; the arena case table went from 10 rows to 10 rows with two verdicts INVERTED by this change, and both inversions were predicted before the run. |

---

## 4. The procedure, in the order it was run

Each step names what it isolates.

1. **Baseline on a pristine tree at the real HEAD.** `git archive 3e93bed`,
   then build and run `seam_selftest` (84 checks) and `embed_e2e`. Isolates
   "what was green before" from "what this change breaks", which matters
   because two of the three regressions here are in test files.
2. **Count the A jobs over EVERY program variant, not the default.** The
   packer has to reserve for a program that will be generated later, possibly
   with different flags. Isolates "is 311 the maximum" from "is 311 the
   default". It is both: 311 / 297 / 263 / 249 (section 5.1).
3. **Build the one allocator** (`derive_region_block`) and make it REFUSE
   rather than return a block it cannot stand behind: it installs the block in
   a trial manifest, runs the whole map, and raises on any fault. Finding 2
   fell out of this immediately.
4. **Migrate on a COPY first.** `--write-manifest-hbm` into a scratch copy of
   the shipping manifest, and check the derived base against the number
   ADDRARENA measured independently. `0x1_FFAD_D000` both ways.
5. **Wire the consumers to read**, and delete the ability to compute:
   `policy="manifest"` is the default and `--desc-policy below-host` no longer
   exists in `gen_layer_program.py`.
6. **Make it mandatory in the C, then find out what breaks.** This is the step
   the brief was really about, and the honest sequence is: change it, run
   everything, read the ten failures, fix them one line at a time, and record
   which of them were the check working (all of them).
7. **Teeth, in four separate populations**, because they measure different
   layers and a green one says nothing about the others: the Python map's
   `--self-test` (20 mutations), the C's arena table inside `--check-c` (10
   placements), a new C probe over `fk33_manifest_read()` (8 mutations), and a
   new C probe over `pl_open()` (6 configurations). Every verdict was written
   down before the run.
8. **Regress everything that consumes a manifest**: `make check`,
   `seam_selftest`, `embed_e2e`, `fk33_load_weights.py selfcheck`,
   `tools/dprog_check.sh`, `weights_residency.py`, `check_mv4i_set.py`, and
   `gen_layer_program.py` in `--token`, `--shape sim`, `--no-a` and
   `--one-lmhead-job` modes.

---

## 5. The evidence, as raw output

### 5.1 The reservation must be the MAXIMUM over the program variants

```
$ python3 - <<'EOF'   # build_plan needs a Shape, not a manifest, so this is
                      # not circular with the packer importing it
one_lmhead=False qkv_fused=False A_JOBS=311  total_steps=505
one_lmhead=False qkv_fused=True  A_JOBS=263  total_steps=457
one_lmhead=True  qkv_fused=False A_JOBS=297  total_steps=491
one_lmhead=True  qkv_fused=True  A_JOBS=249  total_steps=443
```

DERIVED: the default is the maximum, so reserving 311 x 512 B covers every
variant. `pack_model_fk33.a_descriptor_jobs()` takes the max rather than the
default, because a reservation that is too small for a variant somebody runs
later is a silent overrun into the host's R_X staging.

### 5.2 The migration, and the address it produces

```
$ python3 tools/hbm_map.py <noembd>/manifest.json --write-manifest-hbm
wrote the region block into .../manifest.json
  before: no region block at all
  after:  {
 "desc_arena_base": 8584548352,      # 0x1_FFAD_D000
 "desc_arena_bytes": 159744,
 "desc_arena_jobs": 311,
 "desc_arena_stride": 512,
 "host_max_chunk": 512,
 "host_n_embd": 4096,
 "host_n_vocab": 248320,
 "host_x_base": 8584708096,          # 0x1_FFB0_4000
 "host_l_base": 8588935168,
 "host_desc_ptr": 8589930496
}
  backup: .../manifest.json.bak
```

Four sets were migrated. THREE succeeded (`qkvpad`, `stackfix`, `noembd`). The
fourth is finding 2:

```
--- /mnt/storage/llama-models/qwen35-9b-mv4i
  blk.7.ffn_gate.weight.mv4i: 0xfe57_4000..0x1_0007_5000 CONTAINS the stack
  line 0x1_0000_0000; an out-of-stack read does not fault, it returns the
  wrong bytes and reports success
```

### 5.3 `fk33_manifest_read()`: 8 of 8 refusals, control passes

```
$ mprobe set/manifest.json m_no_block.json m_only_base.json m_no_chunk.json \
         m_zero_bytes.json m_unaligned.json m_past_top.json m_inside_kv.json \
         m_zero_chunk.json
fk33_manifest: m_no_block.json: hbm.desc_arena_base appears 0 times, want exactly 1. ...
  hbm.desc_arena_base / hbm.desc_arena_bytes / hbm.host_max_chunk
  are the region block. ... migrated in place with
    python3 tools/hbm_map.py m_no_block.json --write-manifest-hbm
fk33_manifest: m_only_base.json: hbm.desc_arena_bytes appears 0 times, ...
fk33_manifest: m_no_chunk.json:  hbm.host_max_chunk appears 0 times, ...
fk33_manifest: m_zero_bytes.json: hbm.desc_arena_bytes is 0; a declared arena with no length is not a declaration
fk33_manifest: m_unaligned.json:  hbm.desc_arena_base is not 4 KB aligned
fk33_manifest: m_past_top.json:   the declared descriptor arena runs past hbm.size
fk33_manifest: m_inside_kv.json:  the declared descriptor arena starts below kv_base, i.e. inside bytes the card already owns
fk33_manifest: m_zero_chunk.json: hbm.host_max_chunk is 0; the host blocks cannot have been placed under a zero chunk cap
  rc= 0  set/manifest.json
         manifest ...: A arena 0x1FFADD000+159744, host_max_chunk 512
  rc=-1  m_no_block.json
  rc=-1  m_only_base.json
  rc=-1  m_no_chunk.json
  rc=-1  m_zero_bytes.json
  rc=-1  m_unaligned.json
  rc=-1  m_past_top.json
  rc=-1  m_inside_kv.json
  rc=-1  m_zero_chunk.json
```

### 5.4 `pl_open()`: the mandatory arena and the pinned cap, 6 of 6

```
ok   manifest declares the arena, cap matches       chunk=512   rc=0   want=open
ok   cap SMALLER than pinned (safe direction)       chunk=8     rc=0   want=open
ok   cap LARGER than pinned (the hazard)            chunk=1024  rc=-3  want=REFUSE
ok   no manifest, no arena declared                 chunk=512   rc=-3  want=REFUSE
ok   no manifest, arena declared explicitly         chunk=512   rc=0   want=open
ok   manifest with NO region block                  chunk=512   rc=-3  want=REFUSE
OPROBE PASS  (0 rows failed)
```

Row 4 is the one the brief asked for: an open that does not say where
subsystem A's descriptors live is now refused. It used to succeed with a
printed note.

### 5.5 `--check-c`: the C compiled and run, with two INVERTED verdicts

```
ok    x_base = 0x1_ffb0_4000  (C and Python agree)      [7 of 7 match]
...
ok    pl_check_bases arena case none                base=0x0 span=0 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case historic_top_down   base=0x1_fffd_9000 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case on_d_program        base=0x1_ffff_f000 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case on_logits_tail      base=0x1_ffff_d000 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case on_r_x              base=0x1_ffb0_4000 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case aligned_512_not_4k  base=0x1_ffad_c200 -> rc 3 (wanted nonzero)
ok    pl_check_bases arena case misaligned_64       base=0x1_ffad_c040 -> rc 3 (wanted nonzero)
ok    pl_check_bases arena case past_top            base=0x1_ffff_f000 -> rc 1 (wanted nonzero)
ok    pl_check_bases arena case straddles_stack_line base=0xffff_f000  -> rc 4 (wanted nonzero)
ok    pl_check_bases arena case place_below_host    base=0x1_ffad_d000 -> rc 0 (wanted 0)
```

`none` was `wanted 0` and is now `wanted nonzero`: that is item 3.
`aligned_512_not_4k` was `wanted 0` and is now `wanted nonzero`: ADDRARENA
recorded that the C demanded 512-B alignment while `hbm_map` demanded 4 KB, so
a 512-aligned base was accepted by one and rejected by the other, and left it
unharmonised because nothing produced such an address. Something produces it
now — `derive_region_block()` — and it produces a page-aligned one, so the
looser rule bought nothing and cost a hole where the two checkers disagreed.
The C is 4 KB too.

### 5.6 The Python map's teeth, 20 mutations, 7 of them new

```
mutation                                  want   got   n  verdict
control_clean                            green green   0  ok
no_region_block_at_all                     RED   RED   1  ok
region_block_missing_one_key               RED   RED   1  ok
declared_block_on_the_logits_row           RED   RED   2  ok
declared_block_too_small_for_the_program   RED   RED   1  ok
declared_block_unaligned                   RED   RED   2  ok
declared_host_x_base_disagrees_with_the_mirror   RED   RED   1  ok
max_chunk_larger_than_the_one_the_arena_was_placed_under   RED   RED   2  ok
max_chunk_smaller_than_the_pinned_one    green green   0  ok
arena_historic_top_down                    RED   RED   2  ok
arena_on_weight_image                      RED   RED   1  ok
arena_straddles_stack_line                 RED   RED   2  ok
arena_unaligned                            RED   RED   4  ok
arena_past_top                             RED   RED   2  ok
host_blocks_grown_down_through_a_fixed_arena   RED   RED   1  ok
two_packed_tensors_on_one_address          RED   RED   1  ok
gdn_state_moved_into_the_kv_arena          RED   RED   1  ok
a_tensor_declares_the_wrong_stack          RED   RED   1  ok
a_tensor_straddles_the_stack_line          RED   RED   4  ok
arena_inside_the_kv_arena_only           green green   0  ok
arena_right_place_wrong_jobcount         green green   0  ok

TEETH PASS  every mutation gave the verdict written down for it before it ran
```

The two most informative first lines:

```
no_region_block_at_all
    NO REGION BLOCK: the manifest's hbm block does not declare
    desc_arena_base, desc_arena_bytes, host_max_chunk. ...
declared_block_too_small_for_the_program
    <A descriptor arena>: the manifest reserves 4096 B but 311 jobs at 512
    B/descriptor need 159744 B.  The reservation is in the right place and TOO
    SMALL, so the tail of the program would run past it into the host R_X
    staging.
```

The second is a class the map could not see before: a DECLARED region can be
wrong by being too short, which an allocator that computes its own size never
is.

### 5.7 The producer, reading rather than computing

```
$ python3 tools/gen_layer_program.py --token --x-exp 0 --no-hash --print \
    --manifest <migrated>/manifest.json
A descriptor arena 0x1_ffad_d000 .. 0x1_ffb0_4000 (159744 B, 311 jobs in the
full token program, 311 selected here); READ FROM manifest hbm.desc_arena_base;
checked disjoint against 256 regions from 3 allocators
  step 503  output.weight  rows 243264..248319 of 248320 ... @0x1FFB03C00
  311 of 311 A jobs emitted, 0 refused

$ ... --layer 3 --close-token ...
A descriptor arena 0x1_ffad_d000 .. 0x1_ffb0_4000 (159744 B, 311 jobs in the
full token program, 7 selected here); READ FROM manifest hbm.desc_arena_base
```

Identical base from both command lines, which was ADDRARENA's defect (1). The
last descriptor ends at `0x1FFB04000`, exactly `host_x_base`.

And against an UNMIGRATED manifest, the producer refuses rather than
re-deriving:

```
$ python3 tools/gen_layer_program.py --token ... --manifest <unmigrated>
hbm_map: the manifest's hbm block does not declare desc_arena_base,
desc_arena_bytes, host_max_chunk.  The descriptor arena is declared in the
manifest and read from it; nothing re-derives it.  Run `python3
tools/hbm_map.py <manifest> --write-manifest-hbm` on a set packed before the
block existed, or repack.
rc=1
```

### 5.8 Everything downstream, after

```
server make check                    SERVER_COMPILE OK
server/seam_selftest                 SEAM_SELFTEST PASS  (84 checks, 0 failed)
server/embed_e2e                     EMBED_E2E PASS  (0 failed)
tools/hbm_map.py --self-test         TEETH PASS  (20 mutations)
tools/hbm_map.py --check-c           PASS + 17 ok rows
fk33_load_weights.py selfcheck       PASS  (16 mutations)
tools/dprog_check.sh                 DPROG_CHECK: PASS
tools/weights_residency.py           PASS
tools/check_mv4i_set.py              PASS  (249 packed + 1 F32)
gen_layer_program --token            rc=0, 311 of 311 emitted
gen_layer_program --shape sim        rc=0
gen_layer_program --no-a             rc=0
gen_layer_program --one-lmhead-job   rc=2  (by design, unchanged)
fk33_manifest_read teeth             8 of 8 refused, control passes
pl_open teeth                        OPROBE PASS  (6 rows)
```

No `sim/tb_*.vhd` was added, so the shared VHDL gate gains no row and its
`BASELINE_PASS 99` is untouched. `sim/regress.sh` was not run: it is modified
in the working tree by another track and a Vivado synthesis was running, which
is the recorded machine-contention trap.

---

## 6. Measured and REJECTED -- do not retry

**Making `pl_check_bases()` demand an arena UNCONDITIONALLY, including from
`pl_derive_bases()`.** Tried first and REVERTED. `pl_derive_bases()` ends with
`return pl_check_bases(out)` and places only the three HOST blocks; the fourth
arrives from the manifest one call later, and the arena sits BELOW `x_base` so
it cannot be placed until `x_base` exists. Demanding it there makes deriving
the host blocks impossible without first knowing the arena, which is backwards.
The split is `static check_geometry()` (every arithmetic rule, once) plus a
public `pl_check_bases()` that adds the completeness requirement.

**Refusing ANY `max_chunk` that differs from the pinned one.** Implemented,
measured, and narrowed to `>` only. It refused `server/tests/embed_e2e.c`,
which deliberately opens a small simulated card (`max_chunk = 8`) against the
real manifest. The refusal was WRONG, not the test:
`x_base = align_down(l_base - x_stride*max_chunk)` decreases monotonically in
`max_chunk`, so a smaller cap moves `x_base` UP, away from the arena, leaving a
gap and never an overlap. Refusing a strictly safer configuration is ceremony,
and ceremony is what gets checks disabled.

**Adding `hbm.host_x_base` / `_l_base` / `_desc_ptr` to the C's required key
set.** REJECTED. They are provenance: they let a reader see what the arena was
derived from without re-deriving it, and `hbm_map.check()` compares them
against its mirror. Requiring them in the C would grow the migration for no
check the C can make that `pl_derive_bases()` does not already make itself.

**Failing the map when the declared host blocks disagree with the mirror at
ANY `max_chunk`.** Tried; it made `max_chunk_smaller_than_the_pinned_one` go
red for a reason that had nothing to do with the row. The declared host blocks
are a FACT ABOUT `host_max_chunk`, so the comparison is gated on the map being
built at that cap. See section 7.

**Halving `GDN_STATE_BYTES` and `KV_BYTES_PER_TOKEN` to match the 9B shape.**
NOT rejected on merit — it is very likely correct and worth ~2x the context —
but NOT DONE here, and it must not be done from this write-up alone. The layer
counts 48 and 16 are measurably wrong for this model (24 and 8), but the
per-layer terms `6144*128` and `4*256` come from the SS audit and this track
did NOT check them against the RTL. Changing a reservation on half-verified
arithmetic is how the original collision happened. See section 8.

**Editing the live `manifest.json` files while a load might be in flight.**
Considered and made safe rather than avoided: `write_region_block()` writes a
temp file and `os.replace()`s it, which is atomic, so a concurrent reader sees
one whole file or the other and never a torn one; a `.bak` is kept; and only
region-block keys are added, so every reader that predates the block still
parses. `ps -eo args= | grep -c 'fk33_load[_]weights'` was 0 before the write.

---

## 7. Measurement traps hit, including my own

**A stale binary reported a PASS for a change that broke ten checks.**
`make seam_selftest` said "up to date" because the last build predated the C
edits, and `make check` is `-fsyntax-only` and links nothing. `SEAM_SELFTEST
PASS (84 checks, 0 failed)` was printed by a binary compiled from the OLD
`pl_backend.c`. Two minutes from concluding that a mandatory arena broke
nothing. `rm -f` the binaries before rebuilding, or read the compiler lines.

**`rc=$?` after a pipeline reads the LAST command's status** — ADDRARENA's
trap, hit again in the same shape: `python3 tools/hbm_map.py <unmigrated> 2>&1
| tail -6; echo rc=$?` printed `rc=0` with a `1 FAIL` visible on the screen
above it. The tool exits 1; `tail` does not. Redirect and check separately.

**A teeth row that fires for two reasons is not measuring either.** ADDRARENA's
`max_chunk_grown_over_a_fixed_arena` drove an UNDECLARED cap over a fixed
arena. With the cap pinned it goes red for the geometric overlap it was written
for AND for the declared-cap disagreement. It was SUPERSEDED, not deleted, by
two rows that each isolate one thing:
`max_chunk_larger_than_the_one_the_arena_was_placed_under` (declaration, cap
differs, geometry untouched) and `host_blocks_grown_down_through_a_fixed_arena`
(geometry, cap mismatch explicitly suppressed with `_allow_chunk_mismatch`).
The second now reports a genuine `OVERLAP: <host R_X staging> ... and <A
descriptor arena>`, which is what it always claimed to be about.

**I nearly copied a weight set to a 97%-full root.** `cp -r
/mnt/storage/llama-models/qwen35-9b-mv4i-noembd <scratch>` was run to get a
test set. It completed in a second and was 1.2 MB — because that directory is
250 SYMLINKS into the two real sets plus the manifest. Had it been
`qwen35-9b-mv4i` it would have been 4.8 GB onto a filesystem with 39 G free.
The symlink layout is the only reason this was harmless. Check `du -sh` of a
source before copying it, not after.

**A green auditor over a manifest with no region block.** The first version of
`plan()` recorded a missing block as a NOTE, and the map came back PASS. That
is the exact defect this track exists to remove, reproduced in Python within an
hour of removing it from the C. It is now an `extra_fails` entry, so the map is
still BUILT and PRINTED — a tool that refuses to run is a tool nobody runs —
but it is not PASS.

---

## 8. Checks that do NOT bite, under their own names

The most valuable section on re-reading. Each is a real limit, not an
oversight.

**`arena_right_place_wrong_jobcount` -- green by design, unchanged.** The map
sees ADDRESSES. An arena of the right size in the right place holding the wrong
descriptors is invisible here and always will be. What DID change: an arena of
the wrong SIZE is now visible, because the size is declared rather than
computed (`declared_block_too_small_for_the_program`). Contents remain
`gen_layer_program.rtl_would_reject`'s and `fk33_load_weights verify`'s job.

**`arena_inside_the_kv_arena_only` -- green by design, unchanged.** A
top-anchored reservation inside the KV extent is a capacity CHARGE, not a
collision, because the KV arena is defined as everything above the GDN state.
The map cannot tell you that you have priced yourself out of context; it
restates `max_context_tokens` and leaves the judgement to a reader.

**`max_chunk_smaller_than_the_pinned_one` -- green, and this is a DERIVATION
rather than a leniency.** See section 6. The consequence worth knowing: a card
that opens at a small cap silently leaves a gap between the arena and R_X.
Nothing reclaims it and nothing reports it.

**Nothing allocates WITHIN the GDN state or the KV arena, and this change did
not fix that.** It made the sub-structure DECLARED, which is the input a future
check needs and which nothing wrote down before:

```
hbm.gdn_state_layers            48    hbm.gdn_state_bytes_per_layer  1572864
hbm.kv_layers                   16    hbm.kv_bytes_per_layer_per_token  4096
hbm.gdn_state_layers_used       24    hbm.kv_layers_used                   8
```

**What a real per-slot check would take, item 5's answer:**

* **GDN.** One `Region` per slot is cheap — 48 of them — and the existing
  pairwise overlap check would work unchanged. What is MISSING is not the
  arithmetic but the MAPPING: which of the 32 transformer blocks owns slot `i`.
  Nothing in the manifest or in `hbm_map` knows that, and the RTL is the only
  oracle for it. Until that mapping is written down, 48 evenly-spaced regions
  would be a model of a layout nobody has confirmed, which is worse than no
  model.
* **KV.** A `Region` per slot is NOT viable: 8 layers x 61,229 tokens is
  ~490k regions, and the report would be unreadable even though the O(n log n)
  sort would cope. The right model is an arithmetic sub-allocation check —
  `kv_layers * kv_bytes_per_layer_per_token == kv_bytes_per_token`, and
  `kv_bytes_per_token * tokens <= extent` per stack extent — which is about
  three lines. What is MISSING is the within-record layout (K then V, or
  interleaved, and at what alignment), which again only the RTL knows.
* **The check that WOULD have paid for itself today** is the one comparing the
  declared layer counts against the program's, and it is implemented:
  `pack_model_fk33.check_arena_substructure()` REFUSES under-reservation (a
  25th GDN slot in a 24-slot arena lands on the KV cache) and REPORTS
  over-reservation without refusing it. It printed finding 1 the first time it
  ran. It is deliberately not a FAIL, because over-reservation is safe and a
  check that fails on a safe configuration is a check people turn off.

**The map still cannot see the F32 blob's 177 internal entries.** They are
sub-ranges of one object, not Regions. Only
`weights_residency.check_manifest_arithmetic()` checks them.

**Header-only verification, restated from WEIGHTS because it still holds.**
246 of 249 packed tensors share their entire header with a sibling.

---

## 9. Open, not yet answered

1. **`GDN_STATE_BYTES` and `KV_BYTES_PER_TOKEN` are sized for 48 GDN and 16
   attention layers; this model has 24 and 8.** The KV one halves the usable
   context. NOT changed here, because the per-layer terms were not checked
   against the RTL. This is the single highest-value follow-up in this
   write-up and it needs the RTL as its oracle, not this document.
2. **`/mnt/storage/llama-models/qwen35-9b-mv4i` has a tensor straddling the
   stack line** and therefore has no region block and cannot get one. It is
   still `gen_layer_program.py --manifest`'s DEFAULT. Changing that default was
   left alone under three concurrent tracks; it now fails loudly instead of
   quietly, which is an improvement but not a fix.
3. **The packer was NOT run end-to-end.** A real pack needs the 18 GB BF16
   GGUF and hours, and root has 39 G. What WAS measured: `a_descriptor_jobs()`
   returns 311 against the real file list, `derive_region_block()` returns the
   block that is in the shipped manifests byte for byte, `check_arena_
   substructure()` runs, the module compiles and `--help` works. The
   region-block path is exercised; the surrounding pack is not.
4. **Nothing cross-checks the arena's CONTENTS against its declaration.** The
   manifest says 311 descriptors at 512 B; `gen_layer_program.py` checks that
   its own count fits, but nothing verifies that the bytes actually at
   `desc_arena_base` on the card are those descriptors. That is
   `fk33_load_weights.py verify`'s shape of problem and it does not cover the
   arena, which is written by whatever runs the D program, not by the loader.
5. **Whether the A descriptors reach the card through HBM at all** is still the
   open integration decision. `--desc-jobs 0` remains a real arrangement in
   which the arena disappears; the region block would then be a declaration of
   something nobody uses, which is a fine outcome and not a wasted one.
