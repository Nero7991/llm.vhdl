# The composed top is ALREADY at the real 9B shape, and nothing holds it there

**Date:** 2026-09-04
**Build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, GHDL 1.0.0 mcode
**Files:** `hw/fk33/gen_compose4_top.py`, `rtl/model_cfg_pkg.vhd`,
`rtl/attn_block.vhd`, `rtl/gdn_block.vhd`, `sim/shape_probe.vhd` (new),
`sim/check_model_shape.py` (new)

## The question, verbatim

From Oren, 2026-09-04: *"Can we not use compose4_top to get the real 9B shape
in llama top so that we can to our full inference goal"*

## The answer

**The composed top is already at the real 9B shape. It has been for some time,
and the thing standing between it and full inference is not the shape.**

MEASURED, `python3 sim/check_model_shape.py`:

```
SHAPE_OK 13 literals agree with model_cfg_pkg (MODEL at NCARDS=1):
  attn 16x4 hd=256 layers=8, gdn 16/32 hd=128 layers=24
```

Every one of those is the Qwen3.5-9B value from `QWEN35_9B`:
`attn_q_heads = 16`, `attn_kv_heads = 4`, `attn_head_dim = 256`,
`blocks / attn_interval = 32 / 4 = 8` attention layers, `lin_key_heads = 16`,
`lin_val_heads = 32`, `lin_head_dim = 128`, and `32 - 8 = 24` GDN layers.

**But they agree by hand-transcription, not by construction**, which is the
second half of the answer and the reason this file exists. The 9B shape is
written out at THREE independent sites and only ONE consumer derives anything:

| site | how it gets the shape |
|---|---|
| `rtl/model_cfg_pkg.vhd` `QWEN35_9B` | the authority |
| the `--wire` top's `RG_SHAPE` | **derived**, `mk_shape(MODEL, NCARDS)` |
| `rtl/attn_block.vhd` generic defaults | literals; the derivation is in a COMMENT at 199-206 |
| `rtl/gdn_block.vhd` generic defaults | literals, and the file does not mention `model_cfg_pkg` at all |
| `hw/fk33/gen_compose4_top.py` `c_attn` | the same four literals AGAIN, as Python strings |

So flipping `MODEL` to `QWEN38_27B` would move the region file and leave A, B
and C at 9B numbers, with no error raised anywhere. That is this project's
recorded *"guard that passes by coincidence of geometry"* class one level up:
a **configuration** that agrees by coincidence.

`sim/check_model_shape.py` now holds the three sites together, and takes its
expected values from GHDL elaborating `sim/shape_probe.vhd` against the real
package functions rather than re-deriving `blocks / attn_interval` in Python,
because a guard that restates the thing it guards agrees with it by
construction.

## What actually blocks full inference, and it is TIMING, not shape

The composed top carries all four subsystems' COMPUTE at the real 9B shape,
plus D's control plane, plus (new today, `--wire-v`) unit V. What is absent is
**B's and C's data movers**, and both were measured this week with blockers
that are not about geometry:

| piece | in `compose4_top`? | measured state |
|---|---|---|
| A `fk33_engine` | yes, `a_eng` | descriptor-driven, no shape generic; job counter wired 2026-09-03 |
| B `gdn_block` | yes, `b_gdn` | 22 BRAM, 141 DSP, **WNS +0.483 = 221 MHz, MEETS 200** |
| B's mover `gb_real` | **no** | fits after the `gdn_state_store` substitution (34 BRAM + 32 URAM), but **-4.008 = 111 MHz, unattributed** |
| C `attn_block` | yes, `c_attn` | real 9B generics |
| C's mover `gcr` | **no** | fits on area (60 BRAM of 672), **151.3 MHz**; the KV-AXI arm does not synthesise (`recbuf_reg`) |
| D control | yes | `d_fetch`, `d_opdec`, `d_lock` |
| D vec / unit V | yes, **new today** | `d_viss`, `d_vres`, `d_norm` under `--wire-v` |

**So the honest statement of the gap: the shape is right, the compute meets
timing, and both movers are 45-90 MHz short of the card's 200 MHz target with
neither critical path attributed.** B's `-4.008` is identical across four runs
(both variants at both buffer sizes), which already rejects `stmem` as the
cause. That is the work, and it is measurement work rather than writing.

## A separate defect found on the way: the generated top was STALE

`hw/fk33/rtl/compose4_top.vhd` is generated and is committed. Commit `11bf64b`
("wire the A job counter") added the `job_index` port to
`hw/fk33/rtl/fk33_engine.vhd`, which `compose4_top` instantiates, **and did not
regenerate `compose4_top.vhd`.** The committed generated file therefore lost a
port its own instance needed and stayed that way.

Nothing noticed because nothing checked. `tools/gen_cardtop.py` has carried
`--check` since TRACK CARDTOP and is gated as `sim:cardtop`;
`gen_compose4_top.py` had no equivalent. It surfaced only because an unrelated
run regenerated the file and `git status` showed it modified when the
generation should have been a no-op. That is luck, not a gate.

Fixed: `gen_compose4_top.py --check` plus the `sim:c4stale` row.

### And the row's FIRST clean-checkout run found a SECOND, worse defect

MEASURED 2026-09-04. Run against a `git archive` of the tree about to be
committed, `sim:c4stale` FAILED:

```
FAIL  sim:c4stale  0s  COMPOSE4 ABORT: missing .../tree/rtl/ooc_normadapt_top.vhd
```

`rtl/ooc_normadapt_top.vhd` was **untracked and not gitignored**, while both
its siblings, `rtl/ooc_gdnadapt_top.vhd` and `rtl/ooc_cattnadapt_top.vhd`,
were tracked. It had simply never been committed.

**The committed `compose4_top.vhd` instantiates `ooc_normadapt`.** So a clean
checkout of `HEAD` carried a generated top referencing an entity whose file
was not in the repository: nobody could have built the composed top from a
fresh clone, and nothing had noticed, because every run had been done in a
working tree that happened to have the file.

Fixed by tracking it, after confirming it is **byte-identical** to what
`sim/ooc_normadapt_extract.py` produces from the current `rtl/llama_top.vhd`
-- i.e. current, not a stale local artefact that would have frozen an old
extraction into the repo.

Swept for the same class: it is the ONLY untracked `.vhd` under `rtl/` or
`hw/fk33/rtl/`. The many untracked `sim/tb_*.vhd` are the deliberate
working-tree-only benches the gate already enumerates in its baseline warning.

**This is worth more than the six mutants in the generator's teeth table.**
Those show the check CAN fail; this shows it failed on something that was
actually wrong, on its first contact with a tree other than the author's.

MEASURED, `fk33_engine.vhd` itself was already in sync. It remains **ungated**,
because `gen_fk33_engine.py` takes no arguments and writes unconditionally.

## Measured and REJECTED -- do not retry

- **"The composed top needs to be retargeted to the 9B shape."** It does not.
  13 of 13 literals already match, MEASURED. Any work premised on changing the
  generics is work against a problem that does not exist.
- **"`stmem` is what holds B's mover to 111 MHz."** WITHDRAWN 2026-09-03 and
  restated here so it is not re-derived: the substituted build measures the
  same `-4.008` to the digit, so the 24 MiB array is not on the critical path.
- **Reading `gen_fk33_engine.py --help` to learn its interface.** It has no
  argument parser and writes the repo file unconditionally, so even `--help`
  regenerates `fk33_engine.vhd`. MEASURED 2026-09-04 (harmless that day only
  because the output was already in sync).

## Measurement traps hit

- **A generator copied into the scratchpad silently looks for its inputs
  there.** `gen_compose4_top.py` derives `--fk33-rtl` from
  `os.path.dirname(__file__)`, so the byte-identity control run against a
  backup copy aborted with `missing .../scratchpad/rtl/fk33_engine.vhd` and
  produced no output file. The diff then compared against a file that did not
  exist and reported "DIFFERS", which reads exactly like a real regression.
  Pass `--rtl` and `--fk33-rtl` explicitly when running a relocated copy.
- **`grep -c model_cfg_pkg` returning 1 is not evidence that a file uses it.**
  `attn_block.vhd`'s single match is inside a COMMENT that states the
  derivation. The code has literals. A count of matches cannot tell a use from
  a mention.
- **A background tool call that launches `nohup ... &` completes immediately**,
  and its "completed, exit code 0" notification is about the launcher, not the
  gate. The gate's real progress was read from `/proc/PID/cwd`, because the
  `nohup` log is block-buffered and sat at 0 rows for the first 20 minutes.

## Controls run on the `--wire-v` change itself

`--wire-v` is additive and off by default, so section 14's numbers must keep
describing what they measured. MEASURED 2026-09-04:

| control | result |
|---|---|
| `--wire` output, pre-change vs post-change generator | **IDENTICAL**, 134,199 bytes |
| default output, pre-change vs post-change generator | **IDENTICAL**, 123,286 bytes |
| teeth: `--wire` vs `--wire --wire-v` | differs by 449 lines, so the comparison discriminates |
| `--wire --wire-v` elaboration | `ELABV_RESULT OK cells=444169`, 0 errors |

## Open, not yet answered

- **B's `-4.008` and C's `-1.611` are both unattributed.** No failing-endpoint
  census has been run on either.
- **Neither mover is instantiated in `compose4_top`.** Both exist only as
  generated OOC measurement tops.
- **The `gdn_state_store` substitution is still not made in the RTL.** It
  exists in `ooc_gdnadapt_extract.py --state-store` only.
- **`zb`/`yb` still need a real memory** before B's mover builds at 12288.
- **Nothing here says B or C computes a correct token.** `llama_top:4316`
  still refuses `B_SRC_REAL` past token 0.
- **`fk33_engine.vhd` is ungated** against its generator.
- **The V-wired top has not been synthesised**, so it has no area or timing
  figure; section 14's numbers are `--wire` only.
