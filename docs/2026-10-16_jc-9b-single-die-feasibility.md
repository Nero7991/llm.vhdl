# Feasibility: Qwen3.5-9B on one Jungle Cat VU35P die

Date 2026-10-16. Branch `jc-card`. Research note only: no hardware touched, no Vivado run,
no code changed. All evidence below is read from the tree as it stands (HEAD `1cd7d8df`).

## Answer up front

A single-die 9B JC card is mostly a **parameter change at the generator layer** plus a
**handful of literal-string gates that currently refuse anything but the 27B** (small, named
edits, not a redesign). The weight **image for a full 32-layer single-card 9B already exists
on disk** and is built against the exact same HBM port map the JC generator uses, so it is
very likely already loadable by the JC loader, though that has never been tried on a die.
The **biggest blocker is that no 9B JC card build has ever been attempted**: there is no
routed bitstream, no composed timing, and no measured memory peak for this specific
configuration, only a same-tree OOC control run from the 27B-fit investigation.

---

## Q1. What does a 9B single-die JC build need that the 27B JC flow does not already do?

**It is a parameter change at `gen_pcieep.py` (the shared card plumbing), but
`hw/jc/card/`'s own three driver files hard-gate on the string `QWEN38_27B` and on
`HADDR_W == 15`, and would refuse a 9B run as written.** Every one of these gates is a
literal check against the 27B's identifiers, not a structural dependency on 27B logic: the
functions underneath (`_eng_cell_lines`, `_card_*_lines`, `card_27b_lines`,
`seam_27b_lines`) already compute their widths from `P.MODEL_HADDR_W` / `P.MODEL_REGMAX`,
i.e. they are already model-generic; only the gates that call them are pinned.

Enumerated 27B hard-wiring in `hw/jc/card/`, each with its own fix shape:

1. **`hw/jc/card/gen_jc_card.py:139-144`**, `JC_CARD_ENV` dict: pins
   `FK33_C_KV_BLOCK=16`, `FK33_C_MAXPOS=16384`, `FK33_MODEL=QWEN38_27B` (build 27B-1's
   generics). A 9B variant needs a second dict (or the same dict parameterised by a model
   argument) with these all at their defaults (unset), since the **committed**
   `hw/fk33/rtl/fk33_card.vhd` is already the 9B's GENSTAMP (see below).
2. **`hw/jc/card/gen_jc_card.py:147-162`**, `pcieep_env()`: pins `FK33_MODEL=QWEN38_27B`
   again, independently of (1). Same fix.
3. **`hw/jc/card/gen_jc_card.py:516`**, `PKG_REL = "hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd"`,
   and `pkg_lines()` (`:518-539`): this whole function exists only because the 27B is a
   **non-default** model and needs its package rebound into the project in place of the
   committed `rtl/model_cfg_pkg.vhd`. The 9B **is** the default binding
   (`tools/model_cfg.py:23`, `rtl/model_cfg_pkg.vhd`'s own default), so a 9B build does not
   need this rebind dance at all: it would just add the committed package, unmodified. This
   is the one place where the fix is "skip a step", not "change a string".
4. **`hw/jc/card/gen_jc_card.py:769-773`**, `generate_in_place()`: hard
   `sys.exit` unless `P.MODEL_NAME == "QWEN38_27B" and P.MODEL_HADDR_W == 15`. This is the
   single sharpest gate: as written it refuses to emit anything for any other model,
   including the 9B. Needs a model argument threaded through, or a parallel check.
5. **`hw/jc/card/run_card.sh:240`**: `FK33_C_KV_BLOCK=16 FK33_C_MAXPOS=16384
   FK33_MODEL=QWEN38_27B python3 hw/fk33/gen_fk33_card.py` -- the literal regeneration
   call. Same fix as (1): a 9B invocation would run `gen_fk33_card.py` with none of these
   set (its own defaults).
6. **`hw/jc/card/build_card.tcl:233-235`**: after sourcing the BD, asserts exactly one file
   named `*model_cfg_pkg_QWEN38_27B.vhd` is in `sources_1`. For 9B this check does not
   apply (no rebind, no such file) and would need to branch to "exactly one
   `model_cfg_pkg.vhd`, not the QWEN38_27B one" instead.

What does **not** need to change, because it is already model-generic:
- `hw/jc/card/jc_card.xdc` and `jc_card_top.vhd`: pins, board clock and the USER3 BSCANE2
  wrapper, copied from `hw/jc/loader/jc_loader.xdc` (`gen_jc_card.py:7-8, :95`); nothing
  model-specific.
- `card_27b_lines()` / `seam_27b_lines()` (`:543-563`): despite the name, both read
  `P.MODEL_HADDR_W` / `P.MODEL_REGMAX` off the loaded `gen_pcieep` module, so they would
  assert 14 bits / REGMAX 12288 correctly under a 9B environment without being touched
  (only their hardcoded message text says "27B").
- `N_MODULE_REFS = 6` (`:233`): a structural count (loader, ctl, eng, seam, card, bcgrant)
  independent of model.
- `ENG_PORT_MAP` (`hw/fk33/gen_pcieep.py:731-732`, 28 entries, ports 1-15 and 17-29): the
  HBM port/segment layout is one constant shared by the FK33 and JC generators alike --
  see Q2.

**MEASURED**: `hw/fk33/rtl/fk33_card.vhd:10-13` (GENSTAMP block) reads
`FK33_A_ROWS_IF = (unset)`, `FK33_C_KV_BLOCK = (unset)`, `FK33_C_MAXPOS = (unset)`,
`FK33_MODEL = (unset)` -- i.e. **the file committed in the tree right now is already the
9B's wrapper**, generated at every default. That is exactly the opposite situation to the
27B's: `gen_jc_card.py`'s own docstring (`:50-57`) says "the committed wrapper is the 9B,
so this generator REFUSES to run in place" against `JC_CARD_ENV`, and regenerates a 27B
copy in a scratch tree. For a 9B JC build, the in-place wrapper would already be correct;
only the refusal condition and the package/HADDR_W gates above need a 9B-shaped twin.

Defaults that a 9B JC build would inherit for free (`hw/fk33/gen_fk33_card.py`):
`C_MAXPOS=65536` / `C_CTXLEN=65536` (`:376-377`), `C_KV_BLOCK=32` (`:298`),
`NORM_HBM=true` (`:259`).

**DERIVED**: `QWEN35_9B` REGMAX 12288 -> HADDR_W `(12288-1).bit_length() = 14`; `QWEN38_27B`
REGMAX 17408 -> HADDR_W 15 (`tools/model_cfg.py:40,108-111`; `REGMAX_MEASURED` table at
`:40`). This is the 14-vs-15 split `gen_jc_card.py` already talks about.

---

## Q2. Does a single-card 9B image exist, and is it loadable?

**Yes, a full 32-layer single-card image exists on disk, in the manifest format the JC
loader already consumes, built against the exact HBM port map the JC generator uses. It
has never been loaded onto a JC die.**

**MEASURED** (read directly, no hardware): `/mnt/storage/llama-models/
qwen35-9b-mv4i-noembd-striped-seg27-nh/manifest.json` (and its padded sibling
`...-seg27/manifest.json`):
- `"format": "llama.vhdl FK33 load manifest v2 lane-striped"`, 250 file entries, covering
  `blk.0` through `blk.31` (all 32 layers; checked by regex over every `files[].file`).
- `hbm.size` 8,589,934,592 (8 GiB, one die's HBM). `hbm.weights_bytes`
  4,487,442,432 (4.49 GB) == the sum of every `files[].nbytes` (checked directly), so
  4.49 GB is what an actual load transfers, not `weights_end` (7,178,436,608, which
  includes unused segment-arena padding up to each 256 MB segment's capacity).
- `card_c_maxpos: 65536`, `card_kv_fits: true`, `checks[]` all `"ok": true` (piece
  alignment, no overlaps, per-lane segment ownership, pseudo-channel fan-out <= 2 lanes).
  `max_context_tokens: 75151` (`-nh` variant) at that KV sizing.
- `lane_stripe.eng_port_map` is exactly `[1..15, 17..29]` (28 entries) -- byte-for-byte the
  same list as `ENG_PORT_MAP` in `hw/fk33/gen_pcieep.py:731-732`, the constant
  `gen_jc_card.py` imports and reuses unchanged for the JC BD's `eng m00..m27` wiring
  (`gen_jc_card.py` docstring, `:21,:28`). The manifest's `lane_stripe` geometry
  (`nports_w=24`, `rows_if=48`, `axi_dw=256`) is therefore not an FK33-only artifact: it is
  the same port map the JC card would wire up, just packed under the "FK33" name because
  that is the build that produced it.
- The file entries carry `hbm_offset` (an absolute byte address) and `nbytes`, the same two
  keys `hw/jc/loader/` (`tools/jc/coe_load.py`'s `plan_frames`) reads for the 27B images it
  already loaded onto silicon (`docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-
  bound.md` S14, "Card 0's image (7.1 GB, 7,170 pieces) is in die A"). Nothing in that
  reading path is FK33-specific; `hw/jc/host/jc_side_image.py` itself imports
  `fk33_load_weights` (`FLW`) and `fk33_imgfp` directly (`jc_side_image.py:23`) to build the
  JC-side pieces, i.e. the JC host code already reuses the "FK33" manifest reader as its own.

What is **not yet done**: nobody has pointed `coe_load.py load` at this manifest for a real
die, so "is loadable" is a strong structural inference (same keys, same port map, same
reader code), not a result. The directory itself is a symlink farm (e.g.
`qwen35-9b-mv4i-noembd-striped-seg27-nh/blk.0.attn_qkv.weight.mv4i` resolves to
`.../qwen35-9b-mv4i-qkvpad/blk.0.attn_qkv.weight.mv4i`); `coe_load.py` opens files by path
and would follow the symlinks transparently, but this was not exercised here.

**Size vs. one die's 8 GiB HBM**: weights 4.49 GB + `gdn_const.bin` ~1.5-2.1 MB +
GDN state 26.4 MB + KV arena (sized to `max_context_tokens`) comfortably inside 8 GiB, per
the manifest's own `checks` (peak segment fill 74.2%, "ok": true throughout).

---

## Q3. Host path: what else does `run_prompt --jc` need for 9B?

`server/tests/test_run_prompt_jc.py` (`test_single_die`, `:168`) already exercises
`run_prompt --jc SOCK --jc-die D` end to end against a **simulated** broker, but its
fixtures (`MAN_A`/`MAN_B` = `server/tests/fixtures/jc27b_die_a_hbm.json` /
`jc27b_die_b_hbm.json`, `KV_MAXPOS = "16384"` at `:27`) are the **27B's** manifests and
`C_MAXPOS`. No 9B fixture has been run through this path, simulated or real.

Structurally, the pieces that would need to differ for 9B are already read from the
manifest rather than hardcoded:
- **GDN zero side image**: `hw/jc/host/jc_side_image.py:28-29` sizes `gdn_zero.bin` from
  `h["gdn_state_bytes"]` (26,443,776 for the 9B manifest above, a different number from the
  27B's) -- no code change, just a different manifest path as input.
- **KV base / seam CAPS**: `hw/jc/host/test_jc_seam.py:58,103` shows the seam's CAPS
  registers (`n_vocab`, `n_embd`, `n_layer`, `ctx`) are read back from hardware, not
  hardcoded by the host tooling; those test values (`16384`, `5120`, `64`) are 27B test
  fixture constants, not production literals.
- **`fk33_load_weights` / `fk33_imgfp`**: generic manifest readers, reused as-is by
  `jc_side_image.py` (Q2).

What is genuinely unconfirmed, not just unexercised: whether `run_prompt` / `tools/
gen_layer_program.py` take the per-model `C_MAXPOS` (or the manifest path) as an explicit
argument, or whether that number is currently wired to the 27B value anywhere in the host
scripts that drive a real `--jc` run (as opposed to the sim-broker test). A grep of
`server/run_prompt.c` found no `--maxpos`-shaped flag; this needs a direct read of
`gen_layer_program.py`'s argument list before the single-die 9B run, not an assumption.

---

## Q4. Resource/timing ESTIMATE for a 9B single-die VU35P build

**MEASURED, same-tree OOC control** (`docs/debugging/2026-09-30_27b-fits-vu35p-ooc-timing-
artifact.md`, evidence table): the **committed 9B** `fk33_card` (subsystems B/C/D +
`llama_top`) was already run through the VU35P OOC harness as the 27B-fit investigation's
control:

| top | LUT | BRAM | DSP | URAM | WNS (ns) | MHz |
|---|---|---|---|---|---|---|
| `fk33_card` (B/C/D) 9B control | 231,114 | 225.5 | 497 | 32 | -10.24 | 69.0 |
| `fk33_card` (B/C/D) 27B | 268,703 | 345 | 440 | 50 | -10.05 | 69.9 |
| `fk33_engine` (A), 27B tree | 133,303 | 192.5 | 1,585 | 0 | -0.253 | 222.0 |

The doc's own finding is that the 69-70 MHz number is a **standalone-OOC artifact** for
both models alike (no block design, no floorplan): the shipped 9B build 20 runs the same
compute path at >=120 MHz in-context (core clock 75 MHz, WNS +4.98 ns, `vissue`/`wsum`/
`j_dst` absent from its routed worst paths). The same caveat applies to any 9B-single-die
number derived here: **no WNS before `route_design` in a real composed build is a result**.

**DERIVED** (not MEASURED, since the 9B engine has not been run through this OOC harness
separately): if the engine's footprint carries over unchanged from the 27B tree's row
(133,303 LUT; an assumption, since engine datapath width can depend on `hidden`), a 9B
single-die card's combined OOC-cell footprint would be roughly
231,114 + 133,303 = 364,417 LUT = **41.8% of the VU35P's 871,680 LUT**, against the real
27B card's measured 402,006 LUT = 46.1% (`hw/jc/card/README.md`-referenced
`2026-09-30` doc). I.e. 9B should fit with more headroom than the 27B already does, but
this specific combined number has not been measured for 9B.

**Memory peak**: no 9B-specific JC card build has been run. What exists:
- **MEASURED**, the real 27B JC card build (`jccard10`): unit peak 20.6 GB resident, 0.56 GB
  swap; system unit peak 23.7 GB, min `MemAvailable` 2.93 GB
  (`hw/jc/card/results/jccard10_2026-10-10/README.md:26`).
- **MEASURED**, same-tree OOC pieces for 27B alone: `fk33_card` OOC-alone peak 11,780 MB,
  `fk33_engine` OOC-alone peak 9,008 MB (`hw/jc/card/README.md`, Memory section; these two
  sum to roughly the real composed build's 20.6 GB, which is the basis for trusting the
  composed number rather than an OOC-alone one).
- A **9B** `fk33_card` OOC-alone figure of 2.58 GiB is cited in `hw/jc/card/README.md`'s
  Memory section, but explicitly as the number a prior, REJECTED 4-8 GB build ESTIMATE was
  wrongly extrapolated from (it excluded the engine, and the reference OOC run behind it is
  not re-identified in that text). It should not be combined with the 27B engine's 9.0 GB to
  produce a clean 9B total: that would be fitting a model from mismatched runs. The honest
  statement is: **no reliable 9B-specific composed memory peak exists**; ESTIMATE it is
  bounded above by the 27B JC card's measured 20.6 GB (smaller LUT/BRAM/URAM footprint per
  the OOC table above), not fitted to a number.

CLAUDE.md's generic `FK33_CARD=1` card-build peak (~47 GB including swap, under
`MemoryHigh=24G`) is the FK33 (VU33P) 27B-1 build's number, a different board and a
different (larger) model; it is not a safe stand-in for a JC 9B single-die build either.

---

## Q5. Task list to a 9B single-die bitstream and a first-token comparison

Ordered; each step names its gate and whether it needs the main session (hardware) or can
run as a subagent (no hardware, no Vivado-with-hardware-flow).

1. **(subagent)** Confirm `gen_layer_program.py` / `run_prompt`'s model-size inputs (Q3's
   open item): read the argument list, confirm `C_MAXPOS`/manifest path flow through
   without a 27B-specific literal. Gate: a dry run (no hardware) against the existing 9B
   manifest produces a descriptor program without error.
2. **(subagent)** Add a 9B `JC_CARD_ENV` twin (or parameterise the existing one) in
   `hw/jc/card/gen_jc_card.py`, drop the package-rebind path for the default-model case, and
   relax `generate_in_place()`'s `QWEN38_27B`/HADDR_W==15 gate to accept either model by
   name. Mirror the same change in `run_card.sh:240` and `build_card.tcl:233-235` (Q1).
   Gate: `python3 -m pytest hw/jc/card/test_gen_jc_card.py -q` extended with a 9B case, plus
   `gen_jc_card.py --check` against the (already-9B) committed `fk33_card.vhd`.
3. **(subagent)** Dry-run `hw/jc/card/run_card.sh` with `--bdonly` (or equivalent) under the
   9B environment to confirm the BD sources, elaborates and reads back CONFIG.HADDR_W=14 /
   REGMAX=12288 on the seam, with no Vivado hardware flow invoked. Gate: `JCCARD_BD_DONE`
   and the `JCCARD_CFG`/`JCCARD_27B`-equivalent readback lines in the log.
4. **(main session, Vivado only, no hardware)** Run the full 9B JC card build
   (`run_card.sh`), one Vivado at a time per the memory budget, swap-guarded. Gate:
   `JCCARD_DONE`, a routed `jc_card.bit`, and a real (not OOC-alone) WNS at whatever clock
   it closes at.
5. **(subagent)** Pack/verify a JC-shaped manifest from the existing 9B single-card tensors
   (Q2): either confirm the existing `qwen35-9b-mv4i-noembd-striped-seg27-nh/manifest.json`
   loads cleanly through `coe_load.py`'s own offline checks (`plan_frames`, dry run, no
   die), or regenerate one with `tools/pack_model_fk33.py`/`tools/hbm_map.py` if the checks
   disagree. Gate: `plan_frames` produces a plan with 0 overlap and the per-piece digests
   match the manifest.
6. **(main session, hardware)** Reload one JC die with the new 9B bitstream (sudoless
   `fk33_reload.sh`-equivalent for JC, main session only per CLAUDE.md's hardware boundary).
   Gate: DNA/IDCODE readback matches the new bitstream's record.
7. **(main session, hardware)** Load the 9B image via the USER4 loader (`coe_load.py load`,
   broker stopped), same procedure as the 27B loads. Gate: `JCVERIFY_PASS`, spot-window CRC
   match (as done for the 27B, S14 of the loader doc).
8. **(main session, hardware)** Run `run_prompt --jc` for a first token against the loaded
   die.
9. **(subagent)** Run `tools/ref9b/dump_llamacpp.cpp` (or the existing CPU reference
   harness used for the 27B's first-token check, commit `2a8faefe`) against
   `/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf` for the same prompt, and diff
   argmax/logit-gap against the card's token-0 output. This tool already takes `-m
   MODEL.gguf`, so no new tool is needed, only the 9B gguf path. Gate: argmax match (or a
   measured, explained gap, as the 27B's first-token doc records).
10. **(subagent)** Write up the result (pass or the gap found) as a dated debugging note,
    following the same structure as `docs/debugging/2026-10-09_jc-27b-first-token-residual-
    gain.md`.

Steps 1, 2, 3, 5, 9, 10 need no hardware and can run off-hours as subagents. Steps 4
(Vivado, one at a time, per the memory budget) is hardware-adjacent only in the sense that
`llama-server`/another Vivado must not be competing; it needs no physical card. Steps 6-8
touch the JC die directly and are main-session-only per CLAUDE.md's hardware boundary
(subagents get no `xsdb`/`hw_server`/JTAG access of any kind).

---

## Top concern

Every "this should just work" conclusion above (Q2's image compatibility, Q3's manifest-
driven host path, Q4's smaller-than-27B footprint) rests on **structural** evidence --
shared code paths, shared constants, matching keys -- not on a single thing that has
actually been run end to end for this exact configuration. The 27B JC card got to silicon
through several rounds of surprises that structural reasoning alone did not catch (the
`rmsnorm_bf_mem` divide-by-wrong-power-of-two at non-power-of-two hidden size, the fan-out
WNS fixes, the module-reference count checks). A 9B single-die build is smaller and almost
certainly easier, but "almost certainly easier" is not "measured", and the task list above
is sized on that assumption.
