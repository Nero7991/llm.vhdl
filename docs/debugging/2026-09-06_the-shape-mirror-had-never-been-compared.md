# Two implementations of one shape function, never once compared

**Date:** 2026-09-06
**Question:** subsystem C cannot reach HBM without `C_KV_AXI`, which demands
HEAD_DIM 64. `rtl/llama_map_pkg.vhd`'s `mk_shape_scaled` has an `attn_hd > 32`
branch; `tools/gen_layer_program.py`'s hand transcription of the same function
did not. What is the state of that divergence, and what does closing it need?

## The answer, up front

The divergence's **silent half was already fixed** and the record said
otherwise. The remaining half is now closed and, for the first time, **checked**:

- `tools/gen_layer_program.py` gained the `attn_hd > 32` branch, transcribed
  verbatim from the VHDL.
- `tools/gen_shape_mirror.py` (new) emits the Python side into
  `sim/shape_mirror_pkg.vhd`.
- `sim/tb_shape_mirror.vhd` (new) compares **18 fields at 3 head dims = 54
  checks, 0 divergences**, against the VHDL functions.
- `sim:shapemirror` (new selfcheck row) catches the package going stale.

**Nothing had ever compared the two implementations.** The only prior record was
a table typed by hand into a VHDL comment, and it had gone stale.

## The stale record, and how long it lasted

`rtl/llama_map_pkg.vhd` warned that the Python mirror

> still evaluates the formula, and at `attn_hd = 64` that is not an error there:
> Python has no `positive` subtype, so `32 // 64` is 0 and the generator emits a
> plan with **TWO ZERO-SIZED REGIONS instead of refusing**.

That was true when written and false 36 minutes later:

```
bb2230d  2026-08-29 08:38:32  llama_map_pkg: the attn_hd=64 branch has no Python mirror
51bf591  2026-08-29 09:14:42  server: host seam v2 -- prefill, then decode returning logits
$ git merge-base --is-ancestor bb2230d 51bf591   ->   true
```

`51bf591` gave the Python an explicit `raise`. The comment was never updated, so
for eight days the repository's only statement about this hazard described a
behaviour that no longer existed. **A comment that names a commit reads as
precise and dated; it is neither, because nothing re-runs a comment.**

## Why the transcription was safe to do now, and was not before

The refusal's own docstring set the bar:

> Refusing is deliberately not the same as mirroring. Nothing in the repository
> generates at attn_hd 64 today ... an unverified Python transcription of it
> would be a second unchecked claim. ... when a caller genuinely needs
> attn_hd > 32, transcribe the VHDL branch and check it against the VHDL, then
> remove this raise.

Both conditions changed together. A caller arrived (`C_KV_AXI` -> HEAD_DIM 64),
and the check now exists. **Transcribing without the bench would have satisfied
the letter of that instruction and not its point.**

The branch itself is small, and the "region widths grow" language in the VHDL
comment turned out not to be a separate rule at all:

```vhdl
if attn_hd > 32 then
  return (... attn_q_heads => 4, attn_kv_heads => 2, attn_head_dim => attn_hd ...);
end if;
```

`att_q(s) = attn_q_heads * attn_head_dim`, so pinning the head counts and
letting the head dim grow produces att_q 256 / att_qg 512 / att_kv 128 through
the *same* formulas. Nothing widens anything explicitly.

## The result

```
tb_shape_mirror RESULT: PASS -- checks=54 divergences=0 over attn_hd 16, 32 and 64
```

| attn_hd | q | kv | att_q | att_qg | att_kv | region_max |
|---|---|---|---|---|---|---|
| 16 | 4 | 2 | 64 | 128 | 32 | 256 |
| 32 | 2 | 1 | 64 | 128 | 32 | 256 |
| 64 | 4 | 2 | 256 | 512 | 128 | 512 |

## Mutation table

Mutants injected into the live module rather than a copied tree, each built from
the Python branch itself:

| mutant | verdict | divergences |
|---|---|---|
| reference | PASS | 0 |
| M1 `attn_q_heads=64//hd, attn_kv_heads=32//hd` (the pre-fix formula) | **FAIL** | 6 |
| M2 `attn_q_heads=2` | **FAIL** | 4 |
| M3 CONTROL: threshold `> 33`, cannot change 16/32/64 | PASS | 0 |
| M4 `ffn=256` in the branch | **FAIL** | 1 |

M1 is the one that matters: it is precisely the state the original `raise` was
protecting against, and the bench catches it in six fields.

M3 is the attribution control. A change that genuinely cannot affect any tested
shape does not fire, so the failures above are attributable to the mutation
rather than to the harness being noisy.

The staleness row was teeth-tested separately: editing `BLOCKS_C` in the
generated package makes `--check` exit 1 and print the first differing line;
restoring it returns 0.

## Measurement traps hit

- **My mutant harness reported "generator refused" for a `ModuleNotFoundError`.**
  I copied `tools/gen_layer_program.py` alone into a scratch tree; it imports
  `gen_mv4i_desc`, so every mutant died at import and the harness rendered that
  as the generator correctly rejecting the mutation. **All four mutants
  "behaved as expected" and not one had run.** Copying all of `tools/*.py`
  then failed differently -- the generator scrapes HBM constants from a repo
  file -- and the reference row failed too, which is what exposed it.
  **Running the unmutated reference THROUGH THE MUTANT HARNESS is what caught
  this**, and it is cheap. A mutant table with no reference row cannot tell
  "the check works" from "the harness never ran the check".
- **`--only shapemirror` matched 0 rows and printed `REGRESSION: PASS`.** The
  documented `--only` trap. A selfcheck row needs **three** edits -- the
  `SELFCHECK_CMD` entry, a `printf ... >> "$PLAN"` line, and a case arm in
  `run_one` -- and `regress.sh` itself records a red gate caused by having the
  first two and not the third. Read `PASS n`, never the verdict alone.

## Measured and REJECTED -- do not retry

- **Do not copy a subset of `tools/*.py` into a scratch tree to mutate it.**
  Two different repo dependencies bite. Inject the mutant into the imported
  module instead.
- **Do not treat the hand-written divergence table in `rtl/llama_map_pkg.vhd`
  as current.** It was right when written, stale 36 minutes later, and it is
  the reason this work looked larger than it was.

## Open, not yet answered

- The mirror covers 18 fields at 3 head dims. It does **not** compare
  `n_steps`, the region *order*, or any emitted layer program, so two
  implementations could still diverge in a plan while agreeing here.
- `conv_kernel` exists in the VHDL `shape_t` and not in the Python `Shape`, so
  it is outside the mirror entirely.
- Nothing yet generates a layer program at attn_hd 64. The branch is checked,
  not exercised end to end.

---

## CORRECTION, 2026-09-06, same day: the justification was overstated

The framing above, and the commit message that landed with it, say `C_KV_AXI`
demands HEAD_DIM 64 and therefore "subsystem C cannot reach HBM at any shape
below it", putting this work on the path to the bitstream. **That reads as a
blocker on the CARD and it is not one.**

**The card never calls `mk_shape_scaled`.** It takes `mk_shape(MODEL, NCARDS)`,
and `rtl/model_cfg_pkg.vhd` gives the real Qwen3.5-9B as

```
attn_q_heads => 16,   attn_kv_heads => 4,    attn_head_dim => 256
```

which satisfies **all six** of `C_KV_AXI`'s geometry constraints already:

| constraint | value | ok |
|---|---|---|
| HEAD_DIM an even power of two | 256 | yes |
| HEAD_DIM/KV_BLOCK >= 2 | 8 | yes |
| KV_BLOCK >= 16 at CM_W = 8 | 32 | yes |
| KV_BLOCK*CM_W/8 a multiple of 16 | 32 | yes |
| N_KVH >= 2 | 4 | yes |
| GQA group >= 2 | 4 | yes |

MEASURED independently against the generated composed top, whose C instance is
`HEAD_DIM => 256, N_QH => 16, N_KVH => 4`. `mk_shape_scaled` is the SIMULATION
shape helper (hidden 64, ffn 128) and nothing on the card path reaches it.

**How the error was made.** I saw `attn_hd` and `mk_shape_scaled` in the
`C_KV_AXI` declaration's own comment and assumed the card path ran through
them. It does not. I then read the composed top's port widths -- `(4)` and
`(16)` and `(256)` -- and mapped them onto the scaled shape's numbers rather
than the real one's; `(16)` is `attn_q_heads` and `(256)` is `attn_head_dim`,
which is the real shape saying so plainly. **Reading a generic map takes one
command and settles it; inferring a shape from port arithmetic does not.**

**The real reason, narrower and still good.** The KV cache is entirely
UNCOVERED in simulation, and the benches say so themselves --
`sim/tb_llama_top_real.vhd`:

> WHAT THIS ROW DOES NOT COVER, and it is the whole KV cache: `C_KV_AXI` is
> false here because `attn_kv_axi` cannot elaborate at `ATTN_HD = 16` ... and
> the real weight image is indexed by STEP, so it does not apply at the
> `ATTN_HD = 64` shape either.

`attn_hd = 64` is the smallest shape that could cover it, so this branch is
what a future `C_KV_AXI` bench stands on. **A verification enabler, not a build
blocker**, and that distinction is the correction.

Nothing measured here changes: the transcription is still verified, the mirror
still reports 54 checks and 0 divergences, and the mutation table stands.
What changes is why it matters and how urgent it is.

## Gate

Full run after these changes: **PASS 136, FAIL 0, BUILD-ERROR 0, NOVERDICT 0**,
against a floor of 128.
