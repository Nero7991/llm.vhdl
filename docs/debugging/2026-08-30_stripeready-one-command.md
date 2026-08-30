# Can the striping experiment be closed offline so that ONE command on the card produces a number rather than a procedure, and can that command prove it is measuring the striped image before it measures anything?

**Date:** 2026-08-30. Branch `fpga`. **TRACK STRIPEREADY.** Base commit
`655f71b` (HEAD moved to `2eac3c9` while this ran); landing commit at the end
of section 11.

**No hardware was touched.** Nothing below ran `xsdb`, `hw_server`,
`vivado ... program`, `hw/fk33/pcieep.sh`, `hw/fk33/jtag.sh`,
`hw/fk33/flash.sh`, anything under `hw/fk33/tcl/`, or any `hw/fk33/host/*`
against the card. **No Vivado and no GHDL were run**: both synthesis lanes were
committed to other tracks. Six offline commands were traced with
`strace -f -qq -e trace=openat,open`: **zero `/dev` opens of any kind**,
section 4.8. Section 9 carries the card arm; it is Oren's and it was not run.

**Tools named:** `python3` over `tools/ref9b/make_index.py`,
`hw/fk33/host/fk33_run_token.py` (`plan`, `selfcheck`),
`hw/fk33/host/fk33_run_job.py` (`run --dry-run`), `tools/hbm_map.py`,
`tools/check_hbm_stack.py`, `tools/weights_residency.py`,
`tools/gen_layer_program.py`, `tools/gen_lmhead_windows.py`,
`hw/fk33/host/fk33_load_weights.py` (`selfcheck`), and the two files this track
adds; `strace`; `diff`; `sha256sum`; `git rev-parse`, `git status`, `git diff`.

**THE MANIFESTS THIS WAS MEASURED AGAINST, pinned by hash.** PACKSTRIPE has
moved this file under two tracks already and STRIPEPATH's headline numbers
stopped reproducing because of it.

```
697bc32c7389e216691f04a175080f565b6e35542e9a5a772f77b63e6bcc17e6  /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json
5e5df0839dac2377c97e1810003a4cff2f5808118d67d530c1b2a47ac7fc2938  /mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json
```

Both match the hashes TOKENSTRIPE pinned this morning, so every number below and
every number in `2026-08-30_tokenstripe-the-tail-and-the-gap-ledger.md` are
against the same two artefacts.

Labels: **MEASURED** (a named tool ran), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement with its assumption and its falsifier stated).

---

## 1. The question, verbatim

> The striping experiment is the next real measurement on this project and its
> software path is now complete ... **The only remaining blockers are one
> packaging gap and a host reboot.**
>
> **Your job: close the gap, run the ENTIRE experiment offline end to end, and
> hand me ONE command to run on the card.**
>
> > the striped packed dir has **no `index.txt`**, so `plan`'s host re-run
> > cannot cover the striped set (PACKSTRIPE's artefact)
>
> Close it. `tools/pack_model_fk33.py` is currently unowned so it is available
> to you, but **prefer generating the missing artefact over changing the
> packer** ...
>
> It must **verify it is running the striped image and the striped descriptors**
> before measuring, and abort loudly if not. ... It must **read the THERM-255
> trip count alongside the throughput number and print both.** ... It must print
> the **flat-layout control** alongside ... It must be **idempotent and safe to
> re-run**.

---

## 2. The answers, up front

**The gap closed with zero packer change and the fix was a generated artefact,
exactly as the brief preferred.** `tools/ref9b/make_index.py` reads GEOMETRY and
SHAPE only -- `rows_if`, `axi_dw`, `block`, `nports_w`, `n_scale_sub`,
`qkv_segment_pad`, then per tensor `M`, `K`, `w_exp`, `out_shift` and the
segment plan, and per f32 entry `name/offset/nbytes/ne0/ne1`. **It never reads
`hbm_offset` and never reads `pieces`.** So the striped `index.txt` had to come
out byte-identical to the flat one apart from the provenance comment on line 1.

**That was stated as a prediction before the tool was run and it held.**
MEASURED: `diff` of the two files reports exactly one differing line, line 1;
`diff` of the two bodies (line 2 onward, 428 lines) is empty. `git diff --stat`
on `tools/pack_model_fk33.py` is empty. **The packer was not touched.**

**The blocker is measured shut, before and after.** MEASURED on a symlink farm
of the striped dir with `index.txt` withheld, and then on the shipping dir:

```
BEFORE  fk33_run_token: /mnt/.../noindex/index.txt does not exist.  Build it with
          python3 tools/ref9b/make_index.py /mnt/.../noindex
AFTER   coverage    1 of 32 layers checked, 10 of 296 jobs re-run, 0 differ, 0 host-step faults
        compared    248320 of 248320 logits, 0 differ
```

**But `plan` is INERT to placement and therefore cannot be a striping
verifier.** MEASURED: `fk33_run_token.py plan` over layers 0, 7, 15, 31 on the
FLAT and STRIPED manifests differs in **two lines, both timings**. Its 248,320
logits are recomputed from local files. Closing the gap makes the host oracle
reachable on the striped set; it says nothing about pseudo-channels. This is
TOKENSTRIPE's byte-identical trap in a new place and section 7 records it as
mine.

**The one command is
`python3 hw/fk33/host/fk33_stripe_experiment.py run`, and it has been run end
to end offline.** MEASURED: `run --dry-run` walks both phases, all eight jobs,
every guard and the final table in 0.9 s with zero `/dev` opens. `precheck`
(the whole offline half) passes in 0.04 s. `selfcheck` proves 22 guard rows can
fail.

**THE CENTRAL FINDING IS A GUARD IN SOMEONE ELSE'S TOOL THAT PASSES FOR THE
WRONG REASON, AND IT IS THE ONE THE EXPERIMENT'S THERMAL VETO RESTS ON.**
`fk33_run_job.py` reads the trip counter before and after each job and calls the
result INCONCLUSIVE when `trip1 != trip0`. `hw/fk33/rtl/fk33_thermal.vhd:1166`
is

```vhdl
        if trip_cnt /= to_unsigned(255, trip_cnt'length) then
          trip_cnt <= trip_cnt + 1;
```

so the counter **SATURATES**. Open issue THERM-255 is *named for that counter
sitting at 255*. At 255, `trip1 != trip0` is FALSE FOREVER: the veto still
prints, still says `trips=255 (was 255)`, and can no longer fire. **A
throughput number taken in that state carries a thermal all-clear that is
structurally incapable of being anything else.** The fix is in the runner, not
in their file: it clears the counter through `fk33ctl.py thermal --clear` before
every job and **refuses to proceed unless the post-clear `THERM_STATUS` is
observed to read 0**. Selfcheck row `G5 counter SATURATED at 255` is the
mutant.

**TEETH ROW T12 IS NOW CLOSED, and it is the first thing in the tree that
closes it.** T12 -- all 27 lanes of a tensor collapsed back into ONE
pseudo-channel -- has been carried as open by PIECES, STRIPEPATH and
TOKENSTRIPE, killed in each of their tables only incidentally, by `hbm_map`
noticing an overlap the construction happened to create. **This track built the
clean version**: a same-size PERMUTATION that swaps each of the target's payload
pieces with a same-size piece of another tensor already in the destination
segment, so every address stays occupied by exactly one piece of exactly the
same size. MEASURED on that manifest:

```
  rc=0  tools/hbm_map.py           PASS  every region is aligned, in range, in one stack, and disjoint
  rc=0  tools/check_hbm_stack.py   PASS no range crosses a stack boundary
  rc=0  tools/weights_residency.py PASS  ... the manifest agrees with its own placements
  rc=0  tools/gen_layer_program.py   311 of 311 A jobs emitted, 0 refused
  rc=0  tools/gen_lmhead_windows.py WINDOW SET PASS
  rc=1  fk33_stripe_experiment     G2 FAILED: ... lands its 27 lanes in only 1 distinct pseudo-channels [1]
```

**Five gates certify it and the runner refuses it.** That layout would have
measured 21.6 and read as a null result about the theory.

**THE PRE-REGISTERED PREDICTION IS UNCHANGED AND IS NOW BETTER EVIDENCED.**
STRIPEPATH derived 1.60 to 3.0 from "at most 2 lanes per channel". That was the
load-bearing input and it was inferred from a segment count. MEASURED here over
**all 249 striped tensors**, by opening each `.mv4i`'s own 0x38 table and
joining it onto the manifest's raw `pieces`:

```
G2b whole-image census, (channels, max lanes on one channel) -> tensors
    flat     {(1, 27): 235, (2, 14): 2, (2, 16): 2, (2, 17): 1, (2, 18): 1,
              (2, 19): 1, (2, 20): 2, (2, 21): 1, (2, 23): 2, (2, 26): 1, (3, 13): 1}
    striped  {(25, 2): 249}
```

**Every one of the 249 is (25 channels, max 2 lanes).** Not "at most 2" as an
assumption -- 2, uniformly, measured. I am **not** changing the prediction.

**And the flat row of that census independently reproduces the counters
document.** `2026-08-30_counters-cycles-beats-starved.md` section 4.3 MEASURED
`235 files in 1 segment, 13 in 2, 2 in 3` on the 250-file `qwen35-9b-mv4i` set.
This census, computed by different code on the 249-mv4i `noembd` set, gives
**235 in 1, 13 in 2, 1 in 3** -- the missing 3-segment file is `token_embd`,
which `noembd` does not contain. Two independent programs, two different sets,
the same answer.

**A NEW MEASUREMENT THE PREDICTION'S OWN ESTIMATE ASKED FOR.** STRIPEPATH
flagged as load-bearing the assumption that a lateral crossing of the HBM global
switch is free. It is now known how hard the striped experiment leans on it.
MEASURED, lane index against `ENG_PORT_MAP` in `hw/fk33/gen_pcieep.py:376`:

| tensor | lanes reading the pseudo-channel their OWN master is wired to |
|---|---|
| `blk.0.ssm_alpha.weight` | **17 of 27** |
| `blk.0.ffn_gate.weight` | **15 of 27** |
| `blk.11.attn_k.weight` | **17 of 27** |
| `blk.20.ffn_down.weight` | **15 of 27** |

So 10 to 12 of the 27 masters cross the switch laterally on every job. Lanes
0..14 land on segments 1..15 in order and are all direct; the permutation is
entirely in lanes 15..26. This is printed in the runner's own output beside the
number, and it is the first thing to read if the result lands between 3 and 12.

**Attribution, from an 11 x 5 teeth table.** G1 (manifest shape) earns **1**
independent kill; the census family earns **3**; the whole-image scope of the
census earns **1** that the four-tensor scope cannot see; the oracle's
exact-key join earns **1**. **Three mutants earn G1 nothing and are named**
(M2, M3, M4); **two are expected to survive and do** (M7, M8). Section 4.5.

---

## 3. The procedure, in the order it was run

| # | step | what it isolates |
|---|---|---|
| 1 | `sha256sum` both manifests before reading either | the trap that killed two previous documents' numbers |
| 2 | read `tools/ref9b/make_index.py` and enumerate every manifest field it consumes | lets the index's placement-inertness be PREDICTED rather than observed after the fact |
| 3 | diff the two manifests over exactly those fields | 1 difference, and it is a field `make_index` does not read |
| 4 | generate the striped `index.txt`, diff against the flat one | the prediction, tested |
| 5 | `fk33_run_token.py plan` on a farm with `index.txt` withheld, then on the shipping dir | the blocker, measured shut, before and after |
| 6 | the same `plan` on FLAT and STRIPED, diffed | whether `plan` can serve as a striping verifier. **It cannot** |
| 7 | derive the 27 sub-region bases for the measurement tensors from the `.mv4i` header and raw JSON, and check them against what `fk33_run_job.py` prints | an oracle for G3, built before the runner |
| 8 | census all 249 striped and all 249 flat tensors | the prediction's load-bearing input, and a cross-check against the counters document |
| 9 | write the runner; exercise `precheck`, `run --dry-run` and `selfcheck` | the whole control flow, offline |
| 10 | 11 mutants x 5 arms, one arm per check | which check bit, not merely that one did |
| 11 | run the clean T12 mutants through five EXISTING gates | whether the census earns anything the tree did not already have |
| 12 | `strace` six offline commands | the hardware boundary, as evidence |

---

## 4. The evidence, raw

### 4.1 The gap: what `make_index.py` reads, and the resulting prediction

Fields consumed, read out of the source: `geometry.{rows_if, axi_dw, block,
nports_w, n_scale_sub, qkv_segment_pad}`; per mv4i file `{tensor, file, M, K,
w_exp, out_shift, segments[]}`; per f32blob `{file, entries[].{name, offset,
nbytes, shape_ne}}`. No `hbm_offset`, no `pieces`, no `hbm` block.

The two manifests differ, over the whole document, in exactly two places:

```
--- geometry ---
  lane_stripe None -> True
--- nonmatvec entries ---
  names equal: True     differing entries: 177     the ONLY differing key: hbm_offset
--- index-relevant field diffs over all 250 files: 0 ---
  order identical: True
```

`geometry.lane_stripe` is not one of the six geometry keys the writer emits and
`entries[].hbm_offset` is not one of the five entry keys it emits. **DERIVED
prediction, stated before running the tool: the bodies will be byte-identical
and only the provenance comment will differ.**

```
$ python3 tools/ref9b/make_index.py $SDS
wrote /mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/index.txt: 249 mv4i, 1 blob, 177 f32 entries

$ diff $SD/index.txt $SDS/index.txt
1c1
< # generated by tools/ref9b/make_index.py from /mnt/.../qwen35-9b-mv4i-noembd/manifest.json
---
> # generated by tools/ref9b/make_index.py from /mnt/.../qwen35-9b-mv4i-noembd-striped/manifest.json

$ diff <(tail -n +2 $SD/index.txt) <(tail -n +2 $SDS/index.txt)
BODY BYTE-IDENTICAL
```

**Why that is an oracle and not a tautology.** The two files are produced by one
program from two DIFFERENT inputs that disagree in 178 places. Byte-identity is
therefore a statement that none of those 178 differences reaches the output, and
a `make_index` that had grown a placement dependency would break it. A
`diff` of one program against itself over the SAME input would say nothing; this
is not that.

**Only one file was created and it is not in the repo:**
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/index.txt`, 30,034
bytes. The flat one is untouched (mtime still `Aug 29 23:16`).

### 4.2 The blocker, measured shut

```
BEFORE, index.txt withheld:
$ python3 hw/fk33/host/fk33_run_token.py plan --ref ... --packed $S/noindex --only-layers 0
REAL rc=2
fk33_run_token: /mnt/storage/track-stripeready/noindex/index.txt does not exist.  Build it with
  python3 tools/ref9b/make_index.py /mnt/storage/track-stripeready/noindex

AFTER, on the shipping striped dir:
REAL rc=2
program     32 layers selected; 296 subsystem-A jobs in the layers + 15 lm_head windows = 311
  coverage    1 of 32 layers checked, 10 of 296 jobs re-run, 0 differ, 0 host-step faults (0.9 s)
  lm_head     248320 rows RAW in 3.8 s, y_exp=15, sat_event=0
  compared    248320 of 248320 logits, 0 differ
```

**BOTH ARE rc=2 AND THE EXIT CODE DOES NOT DISCRIMINATE.** After the fix the 2
comes from `the reference stream carries no TOKEN record ... regenerate with
--layers 32`, which is a property of `/mnt/storage/ref9b/ref_bfp.r9bs` and is
reproduced identically on the FLAT set. TOKENSTRIPE recorded this shape (its
trap 5: the error prints at the TOP). Read the first line, not the code.

### 4.3 `plan` is inert to placement, so it is not a striping verifier

Four layers plus the whole tail, FLAT against STRIPED, everything verbatim:

```
$ diff plan_flat.txt plan_striped.txt
26c26
<   coverage    4 of 32 layers checked, 31 of 296 jobs re-run, 0 differ, 0 host-step faults (3.5 s)
---
>   coverage    4 of 32 layers checked, 31 of 296 jobs re-run, 0 differ, 0 host-step faults (3.6 s)
32c32
<   lm_head     248320 rows RAW in 4.0 s, y_exp=15, sat_event=0
---
>   lm_head     248320 rows RAW in 4.4 s, y_exp=15, sat_event=0
```

Two lines, both timings. `plan` recomputes from local files; HBM addresses do
not enter it. **Closing the gap makes the host oracle reachable on the striped
set. It does not make it a witness about pseudo-channels, and nobody should
quote it as one.**

### 4.4 The G2 oracle, and its agreement with what the emitter emits

Derived from each `.mv4i`'s own 0x38 sub-region table (unpacked with `struct`)
joined onto the manifest's raw `pieces` JSON on FILE OFFSET, importing neither
`gen_mv4i_desc` nor `hbm_map`. Segments are address bits [32:28]
(`addr // 256 MiB`), never a piece's `segment` label.

```
blk.11.attn_k.weight.mv4i
  flat  w_base[0]=0xe68fd000  s_base[0]=0xe6b0d000  segs=[14]
  strp  w_base[0]=0x1889c000  s_base[0]=0x1aa40c000  segs=[1..15, 17..26]  (25)
```

and what `fk33_run_job.py` itself printed for that job, independently:

```
weights     hbm_base=0x88000  w_base[0]=0x1889C000  s_base[0]=0x1AA40C000
```

**Equal, and the row-window skip is zero**, which is why G3 can be an exact
equality rather than a tolerance. G3 compares those two numbers on every job of
every phase.

### 4.5 Teeth, 11 mutants x 5 arms

Arms: `NEW` the working tree; `NOG1` = the manifest-shape rules removed;
`NOG2C` = the census family removed at BOTH scopes; `NOG2B` = only the
whole-image scope removed; `NOG2O` = the oracle's exact-key join removed. Every
arm is built by ANCHORED replacement and the build aborts if an anchor does not
occur exactly once.

```
mutant   what it does                                         NEW     NOG1    NOG2C   NOG2B   NOG2O
control  the shipping pair, untouched                         --      --      --      --      --       ok
M1       hbm.lane_stripe deleted                              KILL    --      KILL    KILL    KILL     ok
M2       every `pieces` list removed                          KILL    KILL    KILL    KILL    KILL     ok
M3       the FLAT manifest in the striped slot                KILL    KILL    KILL    KILL    KILL     ok
M4       the STRIPED manifest in the flat slot                KILL    KILL    KILL    KILL    KILL     ok
M5       T12 collapsed onto the header's segment (OVERLAPS)   KILL    KILL    --      KILL    KILL     ok
M5b      T12 CLEAN: same-size permutation, nothing overlaps   KILL    KILL    --      KILL    KILL     ok
M6       a piece cut off the header's own 0x38 table          KILL    KILL    KILL    KILL    --       ok
M7       a piece moved 4 KB INSIDE its own segment (EXPECT SURVIVE) --  --    --      --      --       ok
M8       a piece's `segment` LABEL changed (EXPECT SURVIVE)   --      --      --      --      --       ok
M9       T12 CLEAN on a tensor this run does NOT measure      KILL    KILL    --      --      KILL     ok

kills per arm (control excluded): NEW=8  NOG1=7  NOG2C=5  NOG2B=7  NOG2O=7
rows behaving as designed: 11 of 11
TEETH: PASS
```

**The control survives in every arm**, so every column attributes -- which is
the property STRIPEPATH's `OFF`/`PRE` and TOKENSTRIPE's `PRE` columns did not
have.

| check | independent kills | verdict |
|---|---|---|
| G1, the manifest-shape rules | **M1** (1) | earns its place, but only on M1. Deleting `hbm.lane_stripe` while leaving every `pieces` list intact is the one defect the census cannot see, because the layout IS striped -- the manifest merely stops saying so, and the next tool to read `hbm.lane_stripe` would treat it as flat |
| the census family (G2 + G2b) | **M5, M5b, M9** (3) | **earns its place outright, and M5b is the load-bearing row**: five existing gates certify it (4.6) |
| the WHOLE-IMAGE scope alone (G2b) | **M9** (1) | earns its place. A layout striped for the four tensors this run measures and collapsed for the other 245 would give four honest numbers that do not generalise to a token run. Without M9 this scope would be credited with nothing |
| the oracle's exact-key join | **M6** (1) | earns its place. Nothing else in the runner opens the `.mv4i`, so a manifest that cuts the file somewhere other than its own 0x38 table is invisible to every other rule here |
| G4's extent-count cross-check | **none** | **earns nothing and is labelled so.** `verify`'s blake2b digests fail first on any wrong image. It is kept because it is the only rule that discriminates the two LAYOUTS by a single integer (250 against 6,973) and would catch `verify` being pointed at the wrong manifest with a right image -- but nobody should credit it with a detection |

**Rows on which this change earns NOTHING, under their own names:**

* **M2** (every `pieces` removed) -- the census kills it as well: with no pieces
  the striped side reads 1 channel. G1's `nstr == 0` rule is redundant here.
* **M3** (the flat manifest in the striped slot) -- same reason.
* **M4** (the striped manifest in the flat slot) -- killed by the census's
  `flat must be 1 channel` rule as well as by G1's `nflat_str != 0`.
* **M7** -- a piece moved to another 4 KB-aligned address inside the segment its
  own lane already owns is a LEGAL placement. A rule that refused it would fail
  on a correct configuration. STRIPEPATH's T5, PACKSTRIPE's M8/M10, PIECES' M5.
* **M8** -- a piece's `segment` LABEL changed with the address untouched. Every
  rule here reads address bits, deliberately: PACKSTRIPE's T3 is the recorded
  cost of counting the label. The kill belongs to `hbm_map`'s PIECES P5, which
  this runner does not duplicate.

### 4.6 T12, closed: the clean mutant against five existing gates

M5b (`blk.0.ffn_gate.weight`, a measurement tensor) and M9
(`blk.5.ffn_up.weight`, not one), each a pure same-size permutation:

```
=== m5b ===                                          === m9 ===
  rc=0  tools/hbm_map.py           PASS                 rc=0  tools/hbm_map.py           PASS
  rc=0  tools/check_hbm_stack.py   PASS                 rc=0  tools/check_hbm_stack.py   PASS
  rc=0  tools/weights_residency.py PASS                 rc=0  tools/weights_residency.py PASS
  rc=0  tools/gen_layer_program.py 311 of 311           rc=0  tools/gen_layer_program.py 311 of 311
  rc=0  tools/gen_lmhead_windows.py WINDOW SET PASS     rc=0  tools/gen_lmhead_windows.py WINDOW SET PASS
  rc=1  fk33_stripe_experiment                          rc=1  fk33_stripe_experiment
```

and the refusal, verbatim:

```
STRIPE EXPERIMENT REFUSED
G2 FAILED: blk.0.ffn_gate.weight.mv4i under the STRIPED layout lands its 27 lanes in
only 1 distinct pseudo-channels [1], and this experiment requires at least 20.  A
'striped' layout that collapses back onto few channels is STRIPEPATH's teeth row T12:
it is structurally valid, every consumer accepts it, and it would measure ~21.6 while
looking like a null result.
```

**Every rc above was taken from the program, never from a pipeline.** The first
version of this sweep read `rc` after `| tail -12` and reported 0 for a run
that had refused -- the trap the brief names and TOKENSTRIPE hit this morning.

### 4.7 The runner's own selfcheck, 22 rows

```
selfcheck: each row builds a defect and requires the guard to fire.
  G6 control: counters/thermal/verdict/bases present   pass  x4    ok
  G6 counters / thermal / verdict / bases line deleted BAIL  x4    ok
  G6 CYCLES renamed to Cycles                          BAIL        ok
  G5 control: clear reads 0, armed                     pass        ok
  G5 counter SATURATED at 255                          BAIL        ok
  G5 counter left at 1 after clear                     BAIL        ok
  G5 guard is HALTING (bit 0)                          BAIL        ok
  G5 guard NOT ARMED (bit 2 clear)                     BAIL        ok
  G5 no THERM_STATUS line at all                       BAIL        ok
  G1/G2 control: the shipping pair                     pass        ok
  G1 lane_stripe deleted / pieces removed / flat in
     both slots / striped as the control               BAIL  x4    ok
  G2 T12 / a piece cut off the 0x38 table              BAIL  x2    ok
SELFCHECK PASS
```

The four `G6 control` rows and the `G5 control` and `G1/G2 control` rows are
there because a parser that fires on well-formed input is worse than none, and
because a column whose control dies attributes nothing.

The G5 rows drive the shipping `therm_clear()` with its child runner
monkeypatched, so the rule under test is the one that ships and not a copy of
it.

### 4.8 The hardware boundary, as evidence

`strace -f -qq -e trace=openat,open`, following children:

```
precheck       lines=622     /dev/xdma=0   any /dev=0
dryrun         lines=1752    /dev/xdma=0   any /dev=0
selfcheck      lines=669     /dev/xdma=0   any /dev=0
teeth          lines=18829   /dev/xdma=0   any /dev=0
makeindex      lines=101     /dev/xdma=0   any /dev=0
plan-striped   lines=716     /dev/xdma=0   any /dev=0
--- proof the tracer was working: real opens seen ---
"/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/blk.0.attn_gate.weight.mv4i"
"/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/blk.0.ffn_gate.weight.mv4i"
"/home/orencollaco/GitHub/llama.vhdl/rtl/attn_kv_axi.vhd"
```

`dryrun` traces eight `fk33_run_job.py run --dry-run` children through
`strace -f`, so the zero covers them too.

### 4.9 Neighbouring gates, re-run unchanged

```
tools/hbm_map.py            striped  rc=0  PASS every region is aligned, in range, in one stack, and disjoint
tools/weights_residency.py  striped  rc=0  PASS ... the manifest agrees with its own placements
tools/check_hbm_stack.py    striped  rc=0  PASS no range crosses a stack boundary
tools/gen_layer_program.py  striped  rc=0  311 of 311 A jobs emitted, 0 refused
tools/gen_lmhead_windows.py striped  rc=0  WINDOW SET PASS
fk33_run_token.py selfcheck          rc=0
fk33_load_weights.py selfcheck       rc=0  PASS every check was shown to fail on a defect it claims to catch
```

**Inertness is total and trivial to state: no tracked file was modified.**
`git status --porcelain` shows this track's two files as `??` and nothing else;
`git diff --stat -- tools/pack_model_fk33.py` is empty.

---

## 5. Coverage, stated -- how many were READ, not how many passed

| thing | flat | striped |
|---|---|---|
| manifest objects read | 250 | 250 |
| of which lane-striped | 0 | 249 |
| index.txt body lines diffed | 428 | 428 |
| tensors censused, whole image | **249** | **249** |
| sub-region bases derived and classified | 249 x 27 = **6,723** | **6,723** |
| measurement tensors, both layouts | 4 | 4 |
| `fk33_run_job.py` dry runs driven end to end | 4 | 4 |
| descriptor bases cross-checked emitter-against-oracle (G3) | 8 jobs x 2 bases | -- |
| `fk33_run_token.py plan` lines diffed, flat vs striped | 37 | 37 |
| logits the tail's own oracle compared | 248,320 | 248,320 |
| teeth invocations | 11 x 5 = **55** | plus 12 gate runs on M5b/M9 |
| selfcheck rows | **22** | -- |
| offline commands traced | **6** | -- |

**What this coverage does NOT reach, enumerated separately.**

1. **No striped image has ever been resident on the card**, so nothing here is a
   statement about silicon. Inherited from PIECES, STRIPEPATH and TOKENSTRIPE,
   unchanged. Everything in section 9 is unrun.
2. **The card arm has NEVER been executed, not even once, in any form.** The
   `--dry-run` path exercises the control flow and the parsers; it does not
   exercise `fk33_load_weights.py load`, `verify`, `fk33ctl.py id` or
   `fk33ctl.py thermal --clear`, all four of which are skipped there. **G4 and
   the real half of G5 have never run.** Their teeth are synthetic: the G5 rows
   feed `therm_clear()` a canned `THERM_STATUS` word and the G4 rules have no
   teeth row at all.
3. **The parsers are pinned to four other tools' current output format.** They
   abort rather than default, which converts a format change into a loud
   refusal, but a refusal is still not a measurement. Every format string they
   depend on is quoted in the runner's selfcheck.
4. **`fk33_run_job.py --dry-run` reports CYCLES as the constant 4096**, so no
   cycles/beat number in any offline run means anything. The runner suppresses
   its own READING block in dry-run for exactly this reason.
5. **The census has seen ONE striped layout.** A repack with a different
   `--stripe-stack1-segments` changes the arena count and could move the
   `(25, 2)` uniformity. That is TOKENSTRIPE's open item 5 and it is unchanged.
6. **Nothing here reads `hbm.lane_stripe.checks`**, deliberately: it is
   `pack_model_fk33.check_lane_stripe()`'s pack-time self-report, and a checker
   that reads another checker's recorded verdict has checked nothing.
7. **The `ENG_PORT_MAP` direct/lateral count is a MEASUREMENT, not a rule.**
   Nothing gates on it. A layout that gave every lane its own port would be
   better and this runner would not notice the difference.
8. **One mv4i geometry family** (ROWS_IF=48 AXI_DW=256 GRP=1). Inherited.

---

## 6. Measured and REJECTED -- do not retry

| approach | how it died | do not retry |
|---|---|---|
| **Change `tools/pack_model_fk33.py` to emit `index.txt`** | Not needed and actively harmful. `make_index.py` reads no placement field, so the artefact is generatable from the manifest that already exists. The packer has moved the manifest under two tracks and a third move would invalidate STRIPEPATH's and TOKENSTRIPE's numbers | Generate the artefact. `git diff --stat -- tools/pack_model_fk33.py` is empty and stays that way |
| **Use `fk33_run_token.py plan` as the striping verifier** | MEASURED: FLAT and STRIPED plan output differs in TWO LINES, both timings. It recomputes from local files; HBM addresses never enter it | Compare descriptor bases against the manifest's `pieces` (G3), and the bytes on the card against the manifest's digests (G4) |
| **Trust `fk33_run_job.py`'s own `trips moved` check as the thermal veto** | `trip_cnt` SATURATES at 255 (`fk33_thermal.vhd:1166`) and THERM-255 is the open issue named for it sitting there. At 255 the test is FALSE forever while still printing `trips=255 (was 255)` | Clear the counter before every job and REFUSE unless the post-clear word reads 0. Selfcheck row `G5 counter SATURATED at 255` |
| **Build the T12 mutant by rebasing a tensor's pieces onto the segment its 4 KB HEADER lives in** | MEASURED: that is segment 0, where the f32 blob and the descriptor arena are, so it OVERLAPS -- `hbm_map` reports `nonmatvec_f32.bin ... and blk.0.ffn_gate.weight.mv4i:2 ... share 1048576 bytes` and `weights_residency` reports 15 FAILs. The row then measures overlap detection, not lane collapse. **This is the trap that made T12 look closed in three previous tables** | A same-size PERMUTATION with another tensor's pieces in the destination segment. Every address stays occupied by one piece of one size; five existing gates pass it |
| **Census only the four tensors the run measures** | MEASURED: mutant M9 collapses a tensor outside the measurement set and the four-tensor census passes it (`NOG2B` survives). Four honest numbers off an image that is collapsed elsewhere do not generalise to a token run | Census all 249. It costs 0.04 s |
| **Read a piece's `segment` field to decide which pseudo-channel it is in** | Rejected on PACKSTRIPE's recorded T3 and confirmed here as mutant M8, which changes only the label and MUST survive. A label census would have certified a layout it never looked at | `addr // 256 MiB`. Address bits [32:28] are what the HBM switch decodes |
| **Take an exit code after `\| tail -N`** | MEASURED: reported rc=0 for a refusal, on the first T12 gate sweep. `tail` is the last stage, so the pipeline's status is `tail`'s | Redirect to a file, read `$?` from the program, then read the file |
| **Compare the flat run's output against the striped run's to see whether striping took** | TOKENSTRIPE's recorded trap, hit here from a second direction: `plan` is identical across layouts, and `output.weight.mv4i` sits at `hbm_offset` 0 under both. The diff is empty and the program can still be wrong | The manifest is the oracle. Never the other run |
| **Import `gen_mv4i_desc` or `hbm_map` in the G2 oracle to save writing a header parser** | The whole value of G3 is that the emitter's base and the oracle's base come from independent code. Importing the producer makes agreement a tautology -- the m7-mutant shape, recorded twice in this project | `struct.unpack_from` on the 0x38 table and `json.load` on `pieces`, and nothing else |
| **Load only the measurement tensors for each phase, to save DMA time** | Would leave a mixed image and make the run non-idempotent, and it saves nothing worth having: MEASURED elsewhere at 8.76 s to write 4.49 GB and 5.76 s to read it back | Full load, full verify, both phases. The whole card arm is under a minute of DMA |
| **`git commit` with no pathspec while other tracks run** | Recorded in CLAUDE.md; a track lost six documents to it on 2026-08-29 | Pathspec form on exclusively-owned files, which is what section 11 used |

---

## 7. Measurement traps hit, including my own

1. **My first T12 mutant was not clean and I nearly reported it as one.** It
   overlapped the f32 blob, so `hbm_map` and `weights_residency` killed it for
   an unrelated reason and my census's kill would have been unattributable. The
   tell was running the mutant through the neighbouring gates instead of only
   through my own arms. **The arms told me my check fired; only the neighbours
   told me whether anything else already did.** M5 is kept in the table under
   its own name so the next reader sees both.
2. **I read an exit code off a pipeline** on that same sweep and got rc=0 for a
   refusal. Every rc in this document is taken from the program with the output
   redirected to a file.
3. **The `--dry-run` table prints a cycles/beat column that means nothing**, and
   the first version of the runner then printed a READING paragraph concluding
   "this IS evidence against the single-pseudo-channel theory" -- off a
   simulated constant. **A report that draws a conclusion in a mode where the
   input is synthetic is worse than one that prints nothing.** The READING block
   is now suppressed under `--dry-run` and says why.
4. **`rc=2` before and after the index.txt fix.** The exit code does not
   discriminate; only the first line does. TOKENSTRIPE recorded the same shape
   and I still had to be caught by it once before checking the head of the file
   rather than the tail.
5. **`plan` being identical on the two layouts looked at first like a bug in my
   farm.** It is not: `plan` is placement-inert by construction. A "no
   difference" result that is CORRECT and a harness failure look the same, and
   the only way to tell was to read what the tool computes.
6. **The whole-image census was nearly not written**, because the four
   measurement tensors passed and that felt like enough. M9 exists specifically
   to show it was not, and it is the row that earns G2b its place.
7. **`$S` was unset in one shell** (this harness resets the working directory
   and the environment between calls), so one gate's output went to `/n1` and
   its `rc=1` was the shell's redirect failure, not the tool's. Re-run with a
   literal path. It read exactly like `hbm_map` failing on the striped manifest.

---

## 8. Open, not yet answered

1. **The card arm has not been run and cannot be.** The card is configured but
   NOT enumerated: its root port is hidden by the BIOS and a rescan cannot reach
   it. The fix is a warm reboot, deferred until the synthesis lanes quiesce. See
   the CORRECTION in
   `docs/debugging/2026-08-30_restoring-the-card-after-a-power-cycle.md`.
2. **G4 and the live half of G5 have never executed.** Their teeth are
   synthetic. The first real run of section 9 is also their first test, and if
   either misbehaves it will do so in front of Oren. That is stated rather than
   hidden.
3. **`fk33_run_job.py`'s saturating thermal veto is still in that file.** This
   track defends around it and does not fix it, because it is not this track's
   file and because clearing is the runner's job either way. **Anyone else
   reading `trips=N (was N)` from that tool without clearing first is reading a
   guard that cannot fire.** It needs an owner.
4. **Nothing here says the striped image is faster.** The prediction is
   STRIPEPATH's, restated in section 10 with its own falsifiers, and it is
   unrun.
5. **T12 is closed at the HOST, not at the PACKER.** `check_lane_stripe()`
   check 1 in `tools/pack_model_fk33.py`, which reads `ENG_PORT_MAP`, is still
   the only thing that could refuse a bad layout at pack time. This runner
   refuses to MEASURE one; it does not stop one being made.
6. **The 10-to-12 lateral crossings per job are unexplained as a choice.** The
   packer gives lanes 0..14 their own ports and permutes 15..26. Whether a
   port-aware assignment is available, and whether it would matter, is
   unanswered and is exactly what a result between 3 and 12 would make urgent.
7. **The census has seen one striped layout** (TOKENSTRIPE's open item 5,
   unchanged). A repack is the cheapest falsifier of the `(25, 2)` uniformity.
8. **`tools/check_mv4i_set.py` still refuses a v2 manifest** with 249 failures.
   Correct for a tool that has not been taught; untouched. Inherited.

---

## 9. Commands

### 9.1 Offline arm -- no card, no `/dev`, safe for anyone

```bash
cd /home/orencollaco/GitHub/llama.vhdl
SD=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd
SDS=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped

# 0  pin the manifests.  Both hashes are in this document's header; if either
#    differs, no number below is quotable.
sha256sum $SD/manifest.json $SDS/manifest.json

# 1  the gap.  Idempotent; the body must come out byte-identical to the flat one.
python3 tools/ref9b/make_index.py $SDS
diff <(tail -n +2 $SD/index.txt) <(tail -n +2 $SDS/index.txt) && echo BODY IDENTICAL

# 2  the whole offline half of the experiment, including the census of all 249.
python3 hw/fk33/host/fk33_stripe_experiment.py precheck

# 3  the whole CONTROL FLOW, both phases, all eight jobs, no card.
#    Its cycles/beat column is meaningless by construction and says so.
python3 hw/fk33/host/fk33_stripe_experiment.py run --dry-run

# 4  the guards, each shown to fail.  22 rows, SELFCHECK PASS.
python3 hw/fk33/host/fk33_stripe_experiment.py selfcheck

# 5  the teeth with attribution.  11 rows x 5 arms, TEETH: PASS.
python3 docs/debugging/2026-08-30_stripeready-teeth.py

# 6  the host re-run that the index.txt gap used to block
python3 hw/fk33/host/fk33_run_token.py plan --ref /mnt/storage/ref9b/ref_bfp.r9bs \
        --manifest $SDS/manifest.json --packed $SDS --only-layers 0
#    rc=2 is the reference stream's missing TOKEN record and is IDENTICAL on the
#    flat set.  Read the FIRST line, not the exit code.

# 7  the hardware boundary, re-proved
strace -f -qq -e trace=openat,open -o /tmp/sr.strace \
  python3 hw/fk33/host/fk33_stripe_experiment.py run --dry-run >/dev/null 2>&1
grep -c '"/dev/' /tmp/sr.strace          # must be 0
```

The teeth harness writes only into `/mnt/storage/track-stripeready/teeth/`,
which holds four arm copies of the runner and a set of symlink farms of the
model directory, each with one `manifest.json` it writes. It never writes into a
model directory.

### 9.2 Card arm -- OREN ONLY. NO AGENT RUNS THIS.

**Prerequisite, and it is the only one:** the card is configured but not
enumerated. It needs the warm reboot, then
`python3 hw/fk33/host/fk33ctl.py id` must return `0x464B3333`.

**No new bitstream is required.** The striping change is entirely in the packer,
the manifest and the host descriptors. `ENG_PORT_MAP` is in the bitstream and is
unchanged.

**THE COMMAND.** Two lines, and the second is the whole experiment:

```bash
cd /home/orencollaco/GitHub/llama.vhdl
python3 hw/fk33/host/fk33_stripe_experiment.py run
```

It will, in this order: pin both manifests by hash; run G1, G2 and G2b over all
249 tensors offline and refuse if the layout is not the one this experiment is
about; read `fk33ctl.py id`; load the FLAT image and verify all 250 extents
against the manifest's pack-time digests; clear the thermal trip counter and
prove it reads 0; run the four published jobs, cross-checking every descriptor
base against the oracle; then do the same for the STRIPED image and its 6,973
extents; and print one table with CYCLES, BEATS, STARVED, cycles/beat, the trip
count, and the channel census beside each row.

Expect roughly 30 s of DMA (MEASURED elsewhere: 8.76 s write and 5.76 s read
back per 4.49 GB image) plus eight sub-second jobs.

**It is idempotent.** Both phases are full loads, and it finishes with the card
holding a complete, verified STRIPED image. A run interrupted between phases
leaves whichever image went down last; re-run from the top.

**If it refuses, it produces NO NUMBER, and the refusal names which guard fired
and why.** That is the design: a wrong number is worse than none here, because
the wrong number is 21.6 and 21.6 is also what a real null result looks like.

Optional, afterwards, now that `index.txt` exists on the striped set:

```bash
python3 hw/fk33/host/fk33_run_token.py run --manifest \
  /mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json
```

TOKENSTRIPE's section 9.2 states that one's prediction (body AND logits
bit-exact) and it supersedes STRIPEPATH's step 4.

### 9.3 Failure modes

| what you see | reading |
|---|---|
| `G1 FAILED: ... has no hbm.lane_stripe block` | a v1 manifest in the striped slot. Every downstream tool would have accepted it silently and it would have measured 21.6 |
| `G2 FAILED: ... lands its 27 lanes in only N distinct pseudo-channels` | teeth row T12. The layout is structurally valid and five other gates pass it. Re-pack; do not lower the threshold |
| `G2b FAILED: N tensor(s) are not striped to this experiment's requirement` | the four measurement tensors are striped and something else is not. Four honest numbers that do not generalise |
| `G3 FAILED ... the descriptor emitter put w_base[0]=X, this file derived Y` | **the `unchanged 21.6` failure mode, caught before it became a number.** The descriptors are not the ones this layout calls for. Check that `tools/gen_layer_program.py` and `hw/fk33/host/fk33_run_job.py` are at or after `d7f96cd` |
| `the thermal trip counter reads N AFTER a clear` | THERM-255. While it is pinned, every `trips moved` test in the tree is dead. Do not proceed and do not take a number |
| `THERM_STATUS ... has bit 0 set: the guard is HALTING` | a clear does not release a halt. The card is hot, or a sensor is stale, or the two HBM stacks disagree -- see `2026-08-30_therm255-is-two-stacks-not-two-copies.md` |
| `the trip counter moved A -> B during the job on all N attempts` | each trip halts the compute domain. The runner retried and refused rather than reporting a number with a trip in it |
| `the striped image on the card FAILED verify` | the bytes are not the manifest's. `fk33_load_weights.py verify` never opens a `.mv4i`, so this is not a file/offset pairing error |
| `verify read 250 extents ... expected 6973` | the flat image is resident and the striped manifest is being used to read it, or the reverse. The OBJECT count is 250 either way and discriminates nothing |
| `could not find <line> in the output of <tool>` | a child's output format changed. The runner aborts rather than defaulting to zero, and prints the last 2 KB it searched |
| `VERDICT FAIL` from a job | the mantissas do not match `ref/matvec_int4.c`. A cycle count for a wrong computation is not a throughput measurement |
| the table prints and `mean cycles/beat striped` is between 3 and 12 | half the lanes still share a channel, OR the lateral crossing is not free. Read the `own SAXI` column first: 15 to 17 of 27 is what this layout gives |
| the table prints and striped is unchanged at ~21.6 | **G2, G2b, G3 and G4 all passed, so this IS evidence against the single-pseudo-channel theory.** That reading is available ONLY because those guards ran; without them it is indistinguishable from a misconfiguration |

---

## 10. The prediction -- unchanged, and better evidenced

**I am not changing STRIPEPATH's pre-registered prediction.** It is restated
verbatim and the one input it rested on is now measured rather than inferred.

> **cycles/beat should fall from the MEASURED 21.67 to between 1.60 and 3.0.**
> A measured **10-12** means half the lanes still share a channel. An
> **unchanged 21.6** means the image or the descriptors are not the striped
> ones and is **NOT evidence about the theory.**

**What was an inference and is now MEASURED.** STRIPEPATH derived the 1.60 from
"PACKSTRIPE places at most 2 lanes per pseudo-channel", supported by a count of
25 distinct segments. The census here opens every one of the 249 striped
`.mv4i` headers and joins them onto the manifest's raw `pieces`:

```
striped  {(25, 2): 249}
```

All 249 tensors, 25 channels each, **exactly 2 lanes on the busiest channel,
uniformly**. DERIVED, and unchanged from STRIPEPATH:

```
2 beats / 250 MHz = 8.0 ns = 1.60 core cycles at 200 MHz
```

which is the RTL's own ideal-memory floor in
`2026-08-30_counters-cycles-beats-starved.md` section 5.

**One thing STRIPEPATH could not know, added to the falsifier list rather than
to the prediction.** Its ESTIMATE that a lateral crossing of the HBM global
switch is free is leaned on harder than it knew: **15 to 17 of the 27 lanes are
on their own SAXI port and 10 to 12 are not**, per section 2. STRIPEPATH's own
falsifier for that estimate was "a striped result that lands near 1.60 for
tensors whose lanes happen to sit on their own ports and materially worse for
tensors whose lanes do not". **The four measurement tensors split 17/15/17/15,
which is not enough spread to test it.** If the result lands between 3 and 12,
the next measurement is a tensor set chosen for that spread, not a change to
this prediction.

**What falsifies the prediction**, unchanged from STRIPEPATH except where noted:

- **10 to 12 cycles/beat**: roughly half the lanes still share a channel. Look
  at `ENG_PORT_MAP` against the segments the packer chose -- the `own SAXI`
  column the runner prints -- not at the host descriptors, which G3 has already
  measured correct on every job.
- **~21.6, unchanged**: under STRIPEPATH this meant the image or the descriptors
  were not the striped ones and was not evidence. **That escape is now closed.**
  G2b certifies the layout over all 249 tensors, G3 certifies every descriptor
  base against an independent oracle, and G4 certifies every one of 6,973
  extents against its pack-time digest. An unchanged 21.6 that survives all
  three IS evidence against the single-pseudo-channel theory.
- **Well below 1.60**: falsifies the counters document's ideal-memory floor, not
  this prediction.
- **Between 3 and 8**: the 2-lanes-per-channel figure would have to be wrong for
  the tensors measured, and G2b says it is not -- so this outcome now points at
  the lateral-crossing estimate instead.
- **Any number at all with a non-zero trip count**: not a result. The runner
  refuses to produce one.

---

## 11. Corrections to the brief, and the landing

- **"the striped packed dir has no `index.txt`, so `plan`'s host re-run cannot
  cover the striped set"** -- correct, and closing it is worth less than it
  sounds. `plan` is INERT to placement (4.3), so the covered re-run is a check
  of the program build and the host arithmetic, not of the layout. The gap was
  real and the artefact was missing; the artefact is not a striping verifier.
- **"prefer generating the missing artefact over changing the packer"** --
  followed, and the preference turned out to be forced rather than merely
  preferable: `make_index.py` reads no placement field at all, so there was
  nothing for a packer change to add.
- **"It must verify it is running the striped image and the striped
  descriptors"** -- those are two different guards and the brief's phrasing
  hides it. G4 (the image) is a byte-level digest over 6,973 extents; G3 (the
  descriptors) is an address comparison against an independently derived oracle.
  **Either can pass while the other fails**, which is exactly the case
  TOKENSTRIPE's `output.weight` byte-identity showed is reachable.
- **"read the THERM-255 trip count alongside the throughput number"** -- reading
  it is not sufficient and would have been a guard that cannot fail. The counter
  saturates; it has to be CLEARED and the clear OBSERVED. Section 2.
- **"a striped number with no same-session control is one point"** -- agreed and
  implemented, and the control is better than the published one in a way worth
  recording: two of the four rows in the counters document
  (`blk.0.ssm_alpha.weight` and `blk.11.attn_k.weight`, on the 250-file
  `qwen35-9b-mv4i` set) were in segment 16, which belongs to the host's
  `SAXI_16` and is not in `ENG_PORT_MAP` at all, so **not one of their 27
  masters had a direct path**. MEASURED on the `noembd` flat set this run uses,
  the same four tensors sit in segments **14, 3, 14 and 10** -- none in 16, so
  each has exactly **1 of 27** lanes direct. The published 21.67 and this run's
  flat control are therefore NOT taken over identical port geometry, and the
  flat control is the number to compare the striped result against. That the
  two agree at all would be one more small confirmation that the lateral
  crossing is free.
- **"T12 is still unclosed ... either close it or restate it as open"** --
  **closed**, at the host, for any layout this runner will measure, with the
  clean mutant and the five-gate control that shows nothing else catches it
  (4.6). It remains open at the packer (section 8 item 5).

**Landed at `0eac8d4`.** Files added, both new and
exclusively this track's:
`hw/fk33/host/fk33_stripe_experiment.py`,
`docs/debugging/2026-08-30_stripeready-teeth.py`, and this document. No tracked
file was modified. One artefact was generated outside the repo:
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/index.txt`.
