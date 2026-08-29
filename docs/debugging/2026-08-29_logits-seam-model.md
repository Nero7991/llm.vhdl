# The LOGITS seam gets a model on both sides, and the checker stops comparing fewer things than it claims

**Date:** 2026-08-29
**Track:** LOGITS
**Repository HEAD:** `3070fab` when the track started, `d1d1e95` when the
measurements below were taken. Four commits landed underneath it. **Every
measurement is from a pristine `git archive <rev> | tar -x` tree with only this
track's files copied over it**, never from the working tree, which carried
three other tracks' uncommitted edits throughout.
**Tools:** GHDL (mcode backend), Python 3, `ref/matvec_int4.c` via
`tools/ref9b/mv_step_oracle`.

---

## 1. The question, verbatim

> TRACK CAPTURE delivered seam captures and a matching reference stream, and
> named this in its NOT-verified list:
>
> > anything about `LOGITS` (destination `R_NONE`, no model on either side --
> > **the one seam that decides a token**)
>
> That is the gap that matters most now. [...] A wrong token would be
> indistinguishable from a right one at exactly the point where it counts.
>
> Deliver, in priority order:
> 1. **A model for the LOGITS seam**, on both sides, so it can be compared like
>    the other 59. Establish why its destination is `R_NONE` and whether that is
>    the reason it was never modelled.
> 2. **The LM head path** (backlog 4's remaining half). [...] `token_embd.weight`
>    needs ZERO descriptor jobs [...] and `output.weight` needs 15 windows [...]
>    Verify both.
> 3. **Fix a silent coverage loss CAPTURE found**: `tools/ref9b/seam_map.SEAMS`
>    hardcodes the 9B attention interleave [...] 57 modelled, 54 compared, and
>    the verdict line reads like full coverage. **Make the safe behaviour the
>    default.**

---

## 2. The answer, up front

**LOGITS is modelled on both sides now and compares bit-exactly, and so does
the argmax.** Coverage on the `real` configuration went from **59 seams
modelled and compared of 63 captured** to **61 of 65**, and the two new records
are the ones that decide the token.

**Why it was never modelled is not a matter of effort. The capture could not
reach it.** `sim/tb_llama_top.vhd`'s seam capture snapshots the DESTINATION
REGION of each completed job (`if dstr /= R_NONE ... snap(dstr, ...)`). The
lm_head job has `dst = R_NONE`, so there was nothing to snapshot, and the seam
was absent from the capture entirely -- not "present and unchecked", absent.
The reference side then omitted it because there was nothing to be a reference
FOR. **A seam missing from both streams is not walked by any comparison and
produces no warning anywhere.**

`R_NONE` is not a placeholder either. MEASURED from `rtl/llama_map_pkg.vhd`'s
`region_sizes`: at the 9B shape the largest region is **12,288** entries
(`ffn`), against a **248,320**-row vocabulary -- a factor of 20.2. No region
can hold the logits, in any build, and `rtl/seq_desc_fetch.vhd:494-505` makes
`R_NONE` and a route flag **mutually required**: `dst = 0xFF` with no route
flag is `ERR_DESC`, and a named destination WITH one is equally refused.

So the seam reaches the outside world through `rtl/llama_top.vhd`'s `SMP_EN`
route -- raw s32 rows on `smp_valid`/`smp_v`/`smp_idx` with one `smp_exp` for
the whole token, into `rtl/sampler_stream.vhd` -- and the capture now collects
that STREAM instead of snapshotting a region. It emits two records per token,
`LOGITS` (s32) and `TOKEN` (the design's own argmax), and the reference models
both: the logits from `ref/matvec_int4.c` in RAW `out_mode`, the argmax from
the MODEL's own logits rather than from the capture's.

**The `.r9bs` format could not carry it either**, and that is a second reason
it stayed unmodelled. It had two kinds, F32 and BFP16-with-an-int16-payload,
and the logits are a raw s32 with a shared exponent. Recording them as BFP16
right-shifts them by the normalising `ns` before anything compares them; F32
loses bits above 2^24, and a lost low bit is exactly what flips a near tie. A
third kind, `S32`, was added, with a version gate so an older reader stops
loudly instead of decoding 32-bit values as int16.

**The silent coverage loss is fixed at the checker, not at the map.**
`seam_bisect.exact()` walked `seam_map.SEAMS`; it now walks the INTERSECTION of
the two streams, ordered by `SEAMS` where the map knows a name and by file
order after that, and the verdict line states the compared count against the
records present. MEASURED on the `seq` capture: **54 compared became 57, and
the three seams that had been dropped in silence are bit-identical.** That
closes one of CAPTURE's open questions as well as the defect.

**On the LM head, the brief's figures are right and one of its framings is
stale.** `token_embd.weight` really does need zero descriptor jobs; the
generated token program is 505 steps with 311 A jobs, all accepted, none on
that tensor. `output.weight` really is 15 windows at stride 17,376 with a last
window of 5,056. **But both VHDL schedule generators already emit fifteen** --
they were changed together in `80d3a61` -- so "`build_plan` emits ONE lm_head
step" is no longer true of any committed state.

---

## 3. The procedure, in the order it was run, and what each step isolates

| # | probe | what it isolates |
|---|---|---|
| 1 | Read the capture process's emit guard and `llama_map_pkg.region_sizes` | WHY the seam is absent, as a property of the design rather than of the tooling |
| 2 | Reproduce the `seq` silent skip on CAPTURE's committed streams | that the coverage defect is real and not a reading of the report |
| 3 | Fix `exact()` to walk the intersection; re-run all three configurations AND the firing negative control | that the fix adds coverage without loosening anything |
| 4 | Add `KIND_S32` to the format, with a version gate, and round-trip it | that the payload survives the format before any claim rests on it |
| 5 | `mv_step_oracle` gains a `YRAW` block from the SAME call | that the reference has a raw-mode payload at all |
| 6 | Wire `SMP_EN` into `tb_llama_top` and collect the stream | the capture side |
| 7 | Model LOGITS and TOKEN in `bisect_scaled.py` and `ref_stream_scaled.py` | the reference side |
| 8 | `mutate_logits.sh`: nine mutations, two expected to survive | whether the chain has teeth and where its floor is |
| 9 | Measure the smallest single-element change that moves the token | what the argmax check can and CANNOT distinguish, in its own terms |
| 10 | Re-run everything on a pristine tree at the current HEAD | that four concurrent commits did not contaminate any of it |

Step 10 is not ceremony. HEAD moved from `3070fab` to `d1d1e95` during the
track, and `sim/llama_sched_pkg.vhd` -- which builds the plan this bench
executes -- was one of the files that changed.

---

## 4. What changed

| file | what |
|---|---|
| `tools/ref9b/seam_bisect.py` | `exact()` walks the intersection of the two streams, not `SEAMS`. Verdict states compared / present / not-compared, and names the records in only one stream. `cross()` skips a seam with no anchor node. |
| `tools/ref9b/seam_stream.h` | `R9BS_KIND_S32`, `r9bs_write_s32`, `R9BS_VERSION_S32 = 2`, `r9bs_write_header_ver`. Version 1 writers unchanged. |
| `tools/ref9b/r9bs.py` | reads S32; refuses an S32 record in a version-1 file and refuses an unknown kind rather than mis-framing the rest of the file. |
| `tools/ref9b/capture_to_r9bs.py` | `s32` in the text format; two-pass so the version can depend on the contents; an unknown seam name is a loud WARNING by default, `--check-names` still refuses. |
| `tools/ref9b/mv_step_oracle.c` | a `YRAW` block: the raw s32 payload and its exponent, from the same call as the BFP one. |
| `tools/ref9b/scaled_plan.py` | `check_against_capture` checks the LOGITS record against the lm_head step's row count and the TOKEN record's length, instead of refusing them as drift. |
| `tools/ref9b/bisect_scaled.py` | `run_a_oracle_full`, `argmax_first`, and the LOGITS/TOKEN models. |
| `tools/ref9b/ref_stream_scaled.py` | emits the LOGITS and TOKEN records, at version 2. |
| `tools/ref9b/seam_map.py` | a `TOKEN` entry with no anchor node, and a header saying this map is the 9B model's and must not be what `exact()` walks. |
| `tools/ref9b/capture_llama_top.sh` | `SMP=1`; a provenance header naming the HEAD revision and whether the tree was DIRTY. |
| `tools/ref9b/mutate_logits.sh` | new. Nine mutations against the logits seam. |
| `sim/tb_llama_top.vhd` | `SMP_EN` (default false) and `SMP_FIFO`; the `smp_*` ports; the stream collector; the LOGITS and TOKEN records; three capture-integrity counters folded into `fail`. |

`sim/regress.sh` is NOT touched and no gate row is added or removed. The
logits seam already has two gate rows (`tb_llama_top_smp`,
`tb_llama_top_smp_beh`, `c754e39`); what this track adds is the seam's
appearance in the STREAM, which is a capture and not a gate.

---

## 5. The evidence, as raw captured output

### 5.1 Why the seam was absent, in the two places that decide it

`sim/tb_llama_top.vhd`'s capture, before this track:

```vhdl
          wait for CAP_SETTLE;
          if dstr /= R_NONE and nv > 0 and nv <= REGMAX then
            snap(dstr, off, nv);
            emit(seam_of(SHAPE, stp), ...);
          end if;
```

`dstr` is `PLAN(stp).dst`. For the lm_head step that is `R_NONE`, so the
branch is not taken and no record is written. The seam is not "captured and
unchecked"; it is not captured. The reference side then omitted it with the
reason "destination is R_NONE: the lm_head job discards its result", which is
the correct reason for omitting it and the wrong description of what the design
does.

Why the destination is `R_NONE` is a bound, not a convention. `region_sizes`
in `rtl/llama_map_pkg.vhd` gives, at `QWEN35_9B`: R_X / R_XN / R_ER / R_Z /
R_Y = 4096, R_QKV = 8192, R_QG = 8192, R_KIN / R_VIN = 1024, R_BETA / R_ALPHA =
32, **R_G / R_U / R_H = 12,288** (= `ffn`). So `region_max` is 12,288 against a
248,320-row vocabulary, a factor of **20.2**. DERIVED from those functions;
independently re-derived by a second reader.

And the pairing is enforced. `rtl/seq_desc_fetch.vhd:494-505`:

```vhdl
if f_dst(pf_w) = NO_REGION then
  if f_flags(pf_w)(0) = '0' and f_flags(pf_w)(1) = '0' then
    bad := '1'; why := ERR_DESC;      -- R_NONE requires a route flag
  end if;
else
  if f_dst(pf_w) >= NREG then ... end if;
  if f_flags(pf_w)(0) = '1' or f_flags(pf_w)(1) = '1' then
    bad := '1'; why := ERR_DESC;
  end if;
end if;
```

`R_NONE` without a route flag is refused, and a named region WITH one is
refused. So `dst = R_NONE, flags = FLG_TO_SMP` is the only legal encoding of
"this result leaves the region file", and it has been legal all along.

### 5.2 The silent coverage loss, reproduced and then fixed

BEFORE, on TRACK CAPTURE's own committed streams:

```
$ python3 seam_bisect.py .../ref_scaled_seq_HEAD.r9bs \
      .../llama_top_seq_HEAD.r9bs --mode exact --tok 1
# exact compare, token 1: 54 seams identical, 0 differ

EVERY COMPARED SEAM IS BIT-IDENTICAL.
```

57 records per token are present in both streams. 54 were compared. Nothing in
that output says so.

AFTER:

```
# exact compare, token 1: 57 seams identical, 0 differ
# coverage: compared 57 of 57 records present in BOTH streams; reference has 57, other has 60 at this token
# 3 record(s) are in ONE stream only and were NOT compared.  A clean verdict says nothing whatever about these:
    only in .../llama_top_seq_HEAD.r9bs: R_X.embed
    only in .../llama_top_seq_HEAD.r9bs: R_Y-0
    only in .../llama_top_seq_HEAD.r9bs: R_Y-2
# 3 compared record(s) have no seam_map entry, so --mode cross and any map-keyed tool cannot compare them: R_QG-1, R_KIN-1, R_VIN-1

EVERY COMPARED SEAM IS BIT-IDENTICAL (57 of 57 present in both; 3 record(s) present in only one stream were not compared).
```

**The three seams that had been dropped in silence are bit-identical**, which
closes CAPTURE's open question "whether the three skipped `seq` seams are
correct" as well as the defect.

The fix does not loosen anything. The firing negative control still fires, at
the same seams and the same elements:

```
--attn-fold shared (the pre-b75d7a1 behaviour):
tok 0: 57 seams identical, 0 differ    EVERY COMPARED SEAM IS BIT-IDENTICAL.
tok 1: 56 identical, 1 differ  FIRST DIVERGENCE: R_Y-1 at element 12 -- exp 8 vs 8, 92 of 256 mantissas differ
tok 2: 56 identical, 1 differ  FIRST DIVERGENCE: R_Y-1 at element 16 -- exp 8 vs 8, 126 of 256 mantissas differ
```

**Why the fix is in the walk and not in the map.** `seam_map.SEAMS` maps an RTL
seam name to a **llama.cpp node name for the 9B model**. It cannot be made
shape-generic without inventing anchor names for a model that does not exist,
and `--mode cross` genuinely needs it. What was wrong was that `exact()` -- a
comparison between two same-format streams that has no business consulting the
anchor at all -- was keyed on it.

### 5.3 The LOGITS seam, end to end

```
$ SMP=1 bash tools/ref9b/capture_llama_top.sh real .../cap_real_smp.txt
tb_llama_top: logits capture: holes=0 out-of-range indices=0 count disagreements=0 design FIFO overflow='0'
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run,
    R_X bit-identical across all of them, R_X(0) = -16364 hash(R_X) = 91622
wrote .../cap_real_smp.txt (65 records)

$ python3 ref_stream_scaled.py .../cap_real_smp.txt -o .../ref_real_smp.r9bs \
      --blocks 4 --attn-int 4 --attn-hd 16 --norm real \
      --w-image ../../sim/llama_top_w_b4_pool.hex
wrote .../ref_real_smp.r9bs: 61 seams modelled, 4 omitted, format version 2
  OMITTED tok 0 R_Y-0    subsystem B has no integration-level model
  OMITTED tok 0 R_Y-1    subsystem B has no integration-level model
  OMITTED tok 0 R_Y-2    subsystem B has no integration-level model
  OMITTED tok 0 R_X.embed the bench writes it; it is an INPUT to the model, not an output of one

$ python3 seam_bisect.py .../ref_real_smp.r9bs .../cap_real_smp.r9bs --mode exact --tok 0 -v
  LOGITS           exact (128 values, exp 12)
  TOKEN            exact (1 values, exp 0)
# exact compare, token 0: 61 seams identical, 0 differ
# coverage: compared 61 of 61 records present in BOTH streams; reference has 61, other has 65 at this token
EVERY COMPARED SEAM IS BIT-IDENTICAL (61 of 61 present in both; 4 record(s) present in only one stream were not compared).
```

**59 modelled and compared of 63 captured became 61 of 65**, and the two new
records are `LOGITS` and `TOKEN`. `bisect_scaled.py` reports the same, with the
provenance of each model: LOGITS is `ref/matvec_int4.c in RAW out_mode on the
bench's own weight bytes`, TOKEN is `argmax of the modelled logits, first-max
on ties (rtl/sampler_stream.vhd:57)`.

**The argmax is taken over the MODEL's logits, not over the capture's.** Over
the capture's own values it would be a round trip: Python's argmax against
Python's argmax, passing for any wrong-but-consistent machine. Note the same
distinction against `sim/tb_llama_top_smp.vhd`'s property P5, which computes
the argmax of the stream the sampler was fed -- correct evidence for the
SAMPLER, and silent about whether those were the right logits. In its
`A_BEHAV = true` row the values are independently recomputed too, so that chain
is closed at the unit; this one closes it at the token.

### 5.4 The route is additive, and that is measured rather than argued

`SMP_EN` defaults false. A capture taken with it off, from a tree that is
pristine `git archive d1d1e95` plus only this track's files, against one from
the untouched `git archive d1d1e95`:

```
$ diff <(grep -v '^#' .../cap_pristine_nosmp.txt) <(grep -v '^#' .../cap_mine_nosmp.txt)
[no output]
BYTE-IDENTICAL payloads

pristine: tb_llama_top RESULT: PASS -- ... R_X(0) = -16364 hash(R_X) = 91622
mine:     tb_llama_top RESULT: PASS -- ... R_X(0) = -16364 hash(R_X) = 91622
```

With `SMP_EN` on, the same landmark holds (`-16364 / 91622` in every run
below), so the logits route reads the machine and does not perturb it.

### 5.5 Coverage, all three configurations

| configuration | before: modelled / compared, of captured | after |
|---|---|---|
| `real` | 59 / 59 of 63 | **61 / 61 of 65** |
| `stub` | 58 / 58 of 63 | **60 / 60 of 65** |
| `seq` (per token, 3 tokens) | 57 / **54** of 60 | **59 / 59 of 62** |

`seq` gains five: three from the coverage fix (`R_QG-1`, `R_KIN-1`, `R_VIN-1`,
which were being dropped in silence) and two from the logits seam. Every one
of the new comparisons is bit-identical, on every token:

```
--- seq tok 0/1/2 ---
  LOGITS           exact (128 values, exp 10)
  TOKEN            exact (1 values, exp 0)
# exact compare: 59 seams identical, 0 differ
# coverage: compared 59 of 59 records present in BOTH streams; reference has 59, other has 62
```

### 5.6 The teeth. Nine mutations, six killed, two named survivors, one bench catch

Every RTL mutation is applied to a COPY of the tree in scratch; `rtl/` is never
touched. `MUTBASE` is namespaced with the track name, which is the second
recorded near-miss on the shared session scratchpad.

| mut | what it breaks | verdict | how it presents |
|---|---|---|---|
| control | nothing | -- | 61 identical, 0 differ |
| **L0** | one logit of the CAPTURE, +1 | **KILLED** | `LOGITS` at element 0, **1 of 128** values differ. `TOKEN` exact. |
| **L1** | the argmax index of the CAPTURE, +1 | **KILLED** | `TOKEN` at element 0, 1 of 1. `LOGITS` exact. |
| **L2** | the route takes the UPPER half of the 64-bit lane (sign extension, not payload) | **KILLED** | `LOGITS` 128 of 128, and `TOKEN` |
| **L3** | the serialiser retires a beat at its first valid lane: 3 of every 4 logits never folded | **KILLED, by the BENCH first** | `holes=96`, `RESULT: FAIL`; then `LOGITS` 96 of 128 and `TOKEN` |
| **L4** | the published logits exponent is one lower | **KILLED** | `LOGITS` **exp 12 vs 11, 0 of 128 values differ** |
| **L5** | the per-window base never advances | **SURVIVED** | 61 identical, 0 differ |
| **L6** | the pad-row mask is ignored | **SURVIVED** | 61 identical, 0 differ |
| **L8** | each value filed at the MIRRORED lane index within its beat | **KILLED** | `LOGITS` 128 of 128, **`TOKEN` exact**, `holes=0` |
| **L7** | `SMP_FIFO` back to the RTL default 8 | **BENCH ABORT** | `holes=4`, `design FIFO overflow='1'`, no verdict |

Raw, for the rows that carry the most information:

```
===================== L2 =====================
tb_llama_top: logits capture: holes=0 out-of-range indices=0 count disagreements=0 design FIFO overflow='0'
tb_llama_top RESULT: PASS -- ... R_X(0) = -16364 hash(R_X) = 91622
  LOGITS           exp 12/12  128/128 values differ, first at 0
  TOKEN            exp 0/0  1/1 values differ, first at 0
FIRST DIVERGENCE: LOGITS at element 0 -- exp 12 vs 12, 128 of 128 values differ

===================== L4 =====================
tb_llama_top RESULT: PASS -- ... R_X(0) = -16364 hash(R_X) = 91622
  LOGITS           exp 12/11  0/128 values differ, first at -1
  TOKEN            exact (1 values, exp 0)
FIRST DIVERGENCE: LOGITS at element -1 -- exp 12 vs 11, 0 of 128 values differ

===================== L8 =====================
tb_llama_top RESULT: PASS -- ... R_X(0) = -16364 hash(R_X) = 91622
  LOGITS           exp 12/12  128/128 values differ, first at 0
  TOKEN            exact (1 values, exp 0)

===================== L7 =====================
tb_llama_top: logits capture: holes=4 out-of-range indices=0 count disagreements=0 design FIFO overflow='1'
L7: the bench ABORTED before its verdict.
```

**L2, L4 and L8 all leave `tb_llama_top` reporting PASS with the R_X landmark
bit-identical at `-16364 hash 91622`.** Three defects on the seam that decides
a token, invisible to the bench's own verdict, invisible to its residual hash,
and -- before this track -- invisible to the reference comparison too, because
the seam was in neither stream. That is the coverage this work buys, stated as
a measurement rather than as a claim.

**L0 fixes the resolution floor at ONE LSB of a raw s32 in one of 128 values**,
and the report names the element index.

**L4 is the exponent-only row and it matters more than it looks.** Zero values
differ; only the shared exponent moves. Every logit is off by a factor of two,
the argmax is unchanged, and any comparison that looked at values alone would
pass. This is the same family as the open `reg_put`-versus-clamp divergence,
and it shows `--mode exact` reports that family at the exponent.

**L8 is the most informative KILL.** It permutes which vocabulary index each
value is filed under, without losing anything. `LOGITS` catches it on every one
of 128 values; `TOKEN` is EXACT, because `sampler_stream` counts ARRIVALS and
the arrival order did not move. **So the two records catch disjoint things and
neither replaces the other.** L1 is the mirror of it: the argmax wrong with the
values right.

**L5 and L6 SURVIVED, and both are properties of THIS SHAPE, not gaps in the
tree.** `llama_sched_pkg.lm_windows()` is 1 at every scaled shape, so there is
no second window for a window base to be wrong about; and `vocab_shard = 128`
is a multiple of `A_ROWS_IF = 4`, so no beat of this job has a pad row at all.
**Both are covered by `sim/tb_llama_top_smp.vhd`**, whose two windows are 30
and 34 rows -- neither a multiple of four, deliberately -- and whose P1 checks
"every logit, and no pad row" while P2 and P6 hold the window base down. What
survives here is a limit of the CAPTURE at this shape; naming it is the point,
and reporting it as a project gap would be wrong.

**L3 is the row where the bench beat the oracle**, which is the order you want:
a lost beat is a capture integrity failure, and a capture with a hole in it
emits a record of the right LENGTH carrying stale zeros. The hole counter fires
first and the run does not reach a verdict.

### 5.7 What the argmax check can and cannot distinguish

The two records have wildly different sensitivities and the numbers say so.
MEASURED on the `real` capture's 128 logits:

```
argmax index 101 value 11199; runner-up index 120 value 10389; gap 810
smallest single-element change that moves the token: index 101 by -811
rms of the logits: 4090.2;  that perturbation is 0.1983 of rms
duplicate values anywhere: 0 (128 distinct)
```

So on this stimulus:

* **`LOGITS` resolves one LSB** anywhere in the vector (L0).
* **`TOKEN` cannot move at all until a single logit changes by 811** -- about a
  fifth of the vector's own RMS. Every smaller error changes no token.
* Conversely a change far smaller than the RMS **can** flip the token, if it
  lands on the top two. There is no threshold below which the token is safe;
  there is only a gap, and the gap is a property of the stimulus.

This is the argmax form of "coverage of the input space is not coverage of the
output space". **A harness that compared only the token would be blind to
errors up to 810 LSB, and a harness that compared only the logits would miss a
sampler that read them correctly and reduced them wrongly** (L1, and L3 in the
region where the values are right). Both are compared.

**The tie rule is NOT exercised by this stimulus.** All 128 values are
distinct, so `sampler_stream`'s strict `>` -- first max wins -- is never
reached, and neither the design's rule nor the model's `argmax_first` is
verified here. Where it IS reached is not established either; that is in
section 8.

### 5.8 The format, and its own teeth

```
$ python3 capture_to_r9bs.py --selftest .../cap_real_smp.r9bs
wrote /tmp/.../rt.r9bs: 65 records, format version 2
round trip: 65 records bit-identical.  This prices the PARSER; it says nothing
about whether a capture is right.

$ # the version gate: rewrite the header to version 1 and read it back
REFUSED: .../bad_v1.r9bs: an S32 record in a version-1 file.  A file carrying
S32 must declare version 2 so an older reader stops here rather than decoding
32-bit values as int16.
```

Re-converting TRACK CAPTURE's existing `seq` text capture with the new
two-pass writer produces a file **byte-identical** to the one it committed, so
the restructuring did not move anything that was already right.

`ref/run9b.c` and `tools/ref9b/dump_llamacpp.cpp` both still compile against
the extended `seam_stream.h` (`gcc -fsyntax-only`, rc 0 for both); the version-1
writers are untouched.

### 5.9 The 9B side, and what the card will be compared against

The whole-model reference already emits a LOGITS record, as F32, and so does
the llama.cpp anchor. MEASURED:

```
ref_bfp.r9bs    LOGITS         kind 0 (f32) n 248320  argmax 2614  max 12.382477
anchor_f32.r9bs result_output  kind 0 (f32) n 248320  argmax 2614  max 12.216234
```

Both rungs pick token **2614** at position 0. And a clean cross-mode compare of
the two puts the INT4 weight format's own cost at the logits:

```
  LOGITS  result_output   rel_rms 0.08793   max_abs 1.688   1-cos 0.0027   at 185189
```

So a card capture at the real shape has something to be compared against today,
in `--mode cross` with `--baseline`. Two things it does NOT have:

1. **`--mode exact` at LOGITS is impossible against `ref/run9b`**, which writes
   f32 where the card writes s32. The kinds differ and `exact()` says so rather
   than pretending.
2. **`ref/run9b.c` writes no TOKEN record.** It computes the argmax (`int best`)
   and PRINTS it; the stream does not carry it. So the argmax of the whole-model
   reference cannot be compared automatically. The fix is one `seam` call
   alongside the existing `seam_f32("LOGITS", ...)`, in `ref/`, which is not
   this track's file.

### 5.10 The BFP repack open issue does not reach the logits themselves

The open issue is that `ref/run9b.c`'s `reg_put` always normalises while every
shipping unit clamps. **RAW `out_mode` has no normalising shift at all** --
`y_exp = w_exp + x_exp - out_shift`, with no `ns` term, which is exactly the
property that lets fifteen windows share one exponent -- so the logits' own
packing is exempt from that divergence on both sides.

Their INPUT is not. `run9b` does `reg_put(&RXN, t)` before `lm_head`, so the
divergence enters at `R_XN.final`, one seam earlier. The statement that is true
and the one that is not:

* TRUE: no repack rule is applied to the logits, so the LOGITS record is not
  affected by the choice.
* NOT TRUE: that the logits are therefore unaffected. They are computed from a
  vector whose packing is.

### 5.11 The LM head path, verified independently

Every figure below was re-derived from the tree by a second reader, with the
`qkvpad` manifest passed explicitly (the WORKLOG's trap: the default manifest
is the PRE-QKV-PAD set and 48 of 311 A jobs are refused there -- reproduced,
24 at `row_start 2048` and 24 at `4096`, all `attn_qkv`).

**`token_embd.weight` needs ZERO descriptor jobs. CONFIRMED.**

```
$ tools/gen_layer_program.py --token --shape 9b --x-exp 5 \
      --manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json
n_emitted     : 505
len(a_jobs)   : 311
opcode hist   : Counter({0: 311, 4: 65, 5: 64, 6: 32, 1: 24, 2: 8, 7: 1})
steps mentioning token_embd : []
a_jobs accepted             : 311 of 311
```

The mechanism, not just the count: `rtl/seq_opdec.vhd:130-136` states that the
host writes the embedding row into region X and its exponent before each `go`,
`:611`'s `tok_fsm` publishes it, and `rtl/llama_top.vhd:1219` passes
`HOST_REG => R_X`. The host's write has no descriptor.

**`output.weight` needs 15 windows at stride 17,376. CONFIRMED**, and each
constant traced to its site: `MAXROWS_BFP = 17408` at
`rtl/matvec_int4_desc_axi.vhd:108`, `ROWS_IF = 48` at `:102`, vocabulary
248,320 at `rtl/model_cfg_pkg.vhd:70`. `tools/check_a_geometry.py` reports all
five sites agreeing. The emitted schedule:

```
row_start 0, 17376, 34752, ... 225888   n_rows 17376   (14 windows)
row_start 243264                        n_rows 5056    (the last)
14 * 17376 + 5056 = 248320
```

and the VHDL side, from a GHDL elaboration of `sim/tb_seq_tbl_shape`:

```
tb_seq_tbl_shape: 505 steps, 4040 words, LM_WINDOWS = 15, LM_STRIDE = 17376
tb_seq_tbl_shape: 1016 checks, 15 lm_head windows covering 248320 of 248320 rows
```

**The last window's `n_rows = 5056` is NOT a multiple of `ROWS_IF = 48`
(`5056 mod 48 = 16`) and does not need to be.** `matvec_int4_desc_axi:721-726`
bounds `n_rows` only as non-zero and `<= MAXROWS_BFP`; `matvec_core:1011-1012`
masks the tail (`if rbase + rr < n_rows then y_mask(rr) <= '1'`) and `:876-882`
excludes pad rows from the amax fold. It is `row_start` that must be
tile-aligned, and every emitted one is.

**Every one of the 15 carries `dst = 255` (R_NONE), `flags = 2` (FLG_TO_SMP),
`src = 1` (R_XN), `out_mode = 1` (raw)**, decoded from the emitted bytes.

**Raw rather than BFP is load-bearing and the reason is the exponent.** Raw's
`y_exp` carries no per-job term, so all 15 windows publish ONE exponent and a
single running argmax over bare 32-bit integers is meaningful; BFP's `ns` is a
max over each job's own rows, so fifteen BFP windows would hand fifteen
different exponents to a sampler that has nowhere to put them.

### 5.12 One correction to the brief, and it changes the shape of item 2

**"`build_plan` emits ONE lm_head step while `seq_tbl_pkg` now emits 15" is
stale.** At HEAD both window it: `sim/llama_sched_pkg.vhd:270-272` loops
`for w in 0 to lm_windows(s)-1` with `lm_windows` at `:103-105`, and
`sim/seq_tbl_pkg.vhd:141-142` defines the same `LM_STRIDE`. They were changed
in the SAME commit, `80d3a61`, and there is no committed state after it in
which they disagree. `lm_windows` is 1 at every scaled shape and 15 at the 9B
one, which is why the scaled bench still sees a single lm_head step.

Three smaller corrections, all measured by reading the files:

* `seq_desc_fetch`'s two-sided route check is at **`:494-505`**, not `:490-505`.
* `tools/gen_lmhead_windows.py`'s docstring cites
  `rtl/matvec_int4_desc_axi.vhd:684` for the `n_rows > MAXROWS_BFP` refusal.
  That is 38 lines off; `:684` is the `EC_MAGIC` assignment and the refusal is
  at **`:722`**.
* `docs/debugging/2026-08-29_layer-descriptor-program.md:33-34` claims
  byte-identity "over all 491 descriptors / 3,928 words". The windowed table is
  **505 descriptors / 4,040 words**; 491 is the pre-windowing count. The
  identity claim still holds, the figures do not.

### 5.13 The gate

Six rows, on a pristine `git archive d1d1e95` tree with this track's files
overlaid:

```
PASS       sim:tb_llama_top                     119s
PASS       sim:tb_llama_top_normw                86s
PASS       sim:tb_llama_top_real                 79s
PASS       sim:tb_llama_top_seq                 294s
PASS       sim:tb_llama_top_smp                   1s
PASS       sim:tb_llama_top_smp_beh               1s
 OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0
 REGRESSION: PASS
```

No gate row is added or removed and `sim/regress.sh` is not touched, so
`BASELINE_PASS` is unchanged.

---

## 6. Measured and REJECTED -- do not retry

- **Do not record the logits as BFP16 to avoid extending the format.** The
  normalising `ns` right-shifts them before anything compares them, and TRACK
  LMHEAD measured that in BFP 832 of 1024 mantissas move and every value is
  exactly 2x. An argmax must not be compared through a quantisation the design
  does not perform.

- **Do not record them as F32 either.** A raw s32 exceeds binary32's exact
  integer range above 2^24, and the perturbation that flips a token here is 811
  -- three orders of magnitude below the rounding that would introduce.

- **Do not fix the silent skip by making `seam_map.SEAMS` shape-generic.** Its
  right-hand column is llama.cpp's node names for the 9B model; a scaled shape
  has no such nodes, and `--mode cross` genuinely needs the map. The defect was
  that `exact()` -- a same-format comparison with no business consulting an
  anchor -- was keyed on it. MEASURED: fixing the walk raised `seq` from 54
  compared to 57 and left the firing negative control firing at the same seams
  and elements.

- **Do not run the logits capture at `SMP_FIFO = 8`** (the RTL default) at this
  shape. MEASURED: the FIFO overflows twice, `y_we` has no ready, and the
  LOGITS record comes out with four zeros at indices 100..103 -- a record of the
  right length that looks like a value defect. This is a rate artefact of a
  128-row vocabulary against a 4-rows-per-2-cycles producer, NOT a design
  defect: `sim/tb_llama_top_smp.vhd` row M10 measured the card's peak occupancy
  at one beat.

- **Do not compute the TOKEN oracle from the capture's own logits.** It would
  be Python's argmax against Python's argmax, which passes for any
  wrong-but-consistent machine. The model's argmax is taken over the MODEL's
  logits, recomputed from `R_XN.final` by `ref/matvec_int4.c`.

- **Do not treat L5 or L6 as coverage gaps in the project.** MEASURED: both are
  properties of the scaled shape (`lm_windows = 1`; `vocab_shard` a multiple of
  `A_ROWS_IF`) and both are covered by `sim/tb_llama_top_smp.vhd`, whose windows
  are 30 and 34 rows for exactly that reason.

- **Do not compare only the token, or only the logits.** MEASURED on the same
  capture: L8 moves 128 of 128 values and leaves the token EXACT; L1 moves the
  token and leaves the values exact. Each record is blind to the other's
  failure mode.

- **Do not diff a fresh capture against a committed golden and conclude
  "stale".** TRACK CAPTURE's lesson, now mechanised: `capture_llama_top.sh`
  stamps the revision and whether the tree was dirty, so the two readings are
  separated in the file itself rather than in an hour of bisecting.

- **Do not expect `--mode exact` to work between a card capture and
  `ref/run9b`'s stream at LOGITS.** The kinds differ (s32 against f32) and will
  until `run9b` is taught to emit the raw payload. `--mode cross` works today.

## 7. Measurement traps hit, including my own

### 7.1 A signal incremented in a loop counts ONE, and is then overwritten

The worst of the track, and it produced a capture-integrity counter that read
`holes=0` on a record that visibly had four zeros in it.

The collector publishes its counters every cycle. The end-of-token check was
written as `if not lgs(i) then n_smp_hole <= n_smp_hole + 1; end if;` inside a
loop. Two compounding errors: a signal assigned repeatedly in one process
execution takes the LAST assignment, so the loop reports 1 however many indices
are missing; and the collector's own publication on the NEXT edge overwrites
even that with the variable's value. The counter was therefore structurally
incapable of reporting anything.

`kvrd` in the same file already carries a comment about exactly this, which is
the part worth noticing: **the trap was documented in the file I was editing and
I hit it anyway.** Both counters are now accumulated in variables and published
in one place, and L3 and L7 are the teeth that show they fire (`holes=96`,
`holes=4`).

### 7.2 Copying a script into a tree while a background job is reading it

`mutate_logits.sh` was updated in the repository and copied into the scratch
tree while the previous run of it was still executing there. bash reads a script
lazily by byte offset, so the running instance resumed mid-file and died with
`syntax error near unexpected token '&'` at a line it had not reached yet. The
L7 MEASUREMENT was already complete and is valid; the error is in the loop that
follows. `docs/WORKLOG.md` documents this class for `sim/regress.sh`, which
defends against it by re-execing a private copy. A one-shot script has no such
defence, so the rule is simply: do not overwrite a script another process is
inside. The affected row was re-run.

### 7.3 "At HEAD" is a measurement, and HEAD moved twice

`3070fab` at the start, `d1d1e95` by the end, and one of the four commits that
landed was `sim/llama_sched_pkg.vhd` -- the file that builds the plan this bench
executes. Everything was re-measured on a pristine `git archive d1d1e95` tree
with only this track's files copied over it. The landmark did not move
(`R_X(0) = -16364 hash 91622` at both revisions), so SCHED-FIX's `nsub_w`
correction is not visible at the scaled shape; that is a measurement, not an
assumption.

### 7.4 A `git archive` scratch tree is not a git repository

The provenance header's first version called `git rev-parse` and stamped
`# HEAD unknown` in exactly the situation it exists for -- a capture taken from
a pristine extraction. `CAPTURE_REV` now overrides it, and the fallback text
says which flag to pass rather than just "unknown".

### 7.5 A pretty-printer that lied about the numeric kind

`r9bs.py`'s `__main__` printed `bfp16 e=12` for the S32 LOGITS record: one of
the two edits that should have taught it the new kind did not match its target
text and the change silently no-op'd. The stored record was correct; only the
display was wrong. Caught by reading the output rather than by any check --
which is the argument for the version gate, since a mis-declared kind that
reaches a READER mis-frames every record after it.

### 7.6 `nohup cmd &` inside a tool call does not survive it

A backgrounded regression produced a four-line log and exit 0, which reads like
a run that found nothing. It had been reaped. Unrelated to the subject matter
and worth one line: use the harness's own background mode, and confirm a run
produced a VERDICT rather than merely an exit code.

### 7.7 The scratchpad is shared, and this is the third recorded near-miss

`MUTBASE` defaults to a `mktemp -d -t logitsmut.XXXXXX` and every explicit path
used here is under a `logits_track/` prefix. TRACK CAPTURE's `mut` collided with
another track's sweep and was saved by case sensitivity.

## 8. What was NOT determined

- **Anything on the card.** No hardware was touched and none could be. The S32
  record is designed for a host driver to emit and nothing has emitted one.

- **The argmax of the whole-model reference.** `ref/run9b.c` computes it and
  prints it; the stream does not carry it, so there is no TOKEN record at the 9B
  shape to compare a card against. One `seam` call fixes it, in `ref/`.

- **`--mode exact` at LOGITS against `ref/run9b`.** Impossible while that side
  is f32. Whether it SHOULD emit raw s32 is a decision with the same shape as
  the BFP repack one, and it was not taken here.

- **The tie rule.** All 128 logits of this stimulus are distinct, so
  `sampler_stream`'s first-max-on-ties is never reached and neither
  implementation is exercised. Whether any bench in the tree reaches it was not
  established.

- **The 15-window index space and the pad-row mask, at the INTEGRATION level.**
  L5 and L6 survive here; `sim/tb_llama_top_smp.vhd` covers both, but at its own
  synthetic schedule and weight memory, not on the real path. Nothing has run
  fifteen real windows anywhere.

- **Whether 15 windows produce the same 248,320 logits as one hypothetical
  job.** The window schedule is verified as GEOMETRY -- row cover, byte cover,
  descriptor acceptance, exponent invariance, six of six mutations killed -- and
  not as VALUES. `matvec_int4_desc_axi` refuses a 248,320-row descriptor in every
  `out_mode`, so the one-job comparison cannot be run on the gateware; it would
  have to be `ref/matvec_int4.c` against itself, windowed and not.

- **Whether `llama_sched_pkg` and `seq_tbl_pkg` agree byte for byte at the 9B
  shape.** `seq_tbl_pkg` was checked against the Python emission (505 steps,
  4,040 words, 15 windows, stride 17,376). No bench in the tree elaborates
  `llama_sched_pkg` at the 9B shape, and its own comments say the surrounding
  assertions are exercised only where `lm_windows(s) = 1`.

- **Whether the golden should be committed at all.** It is regenerated here,
  with a provenance block and a header saying what it is, but it still rots on
  every `rtl/` commit on the real path and nothing gates on it. Generating it in
  the gate is the real fix and costs a gate row and about 40 s; that is a
  dispatcher decision, not an edit.

- **`--mode cross` on the scaled streams.** Only `--mode exact` was exercised
  there; cross needs a float anchor at the scaled shape, which does not exist.

---

## 9. Reproducing all of it

```sh
# the capture, with the logits seam on
SMP=1 bash tools/ref9b/capture_llama_top.sh real /path/cap.txt

cd tools/ref9b
cc -O2 -Wall -DMV4I_LIB -I ../../ref -o mv_step_oracle mv_step_oracle.c -lm
python3 capture_to_r9bs.py /path/cap.txt -o /path/cap.r9bs
python3 ref_stream_scaled.py /path/cap.txt -o /path/ref.r9bs \
    --blocks 4 --attn-int 4 --attn-hd 16 --norm real \
    --w-image ../../sim/llama_top_w_b4_pool.hex
python3 seam_bisect.py /path/ref.r9bs /path/cap.r9bs --mode exact --tok 0 -v

# the teeth.  NAMESPACE THE SCRATCH: the session scratchpad is shared.
MUTBASE=<a name nobody else is using> bash tools/ref9b/mutate_logits.sh all
```

`--norm` must match what the run elaborated and is not recorded in the capture;
guessing it wrong makes every norm seam diverge, which looks exactly like a
defect. `real` uses `NORM_REAL=true`; `stub` and `seq` take the default
`NORM_ANCHOR=true`.
