# The 9B reference's argmax was printed, not recorded, and three checks around it were counting the wrong things

**Date:** 2026-08-29
**Track:** REF-TOKEN
**Repository HEAD:** `35e0ed0` when the track started, `2a411bb` when the
`dprog_check` item was diagnosed, `99bfe85` at the end. **Every measurement was
taken on a pristine `git archive <rev> | tar -x` tree with only this track's
files copied over it**, never on the working tree, which carried three other
tracks' uncommitted edits throughout (`sim/tb_llama_top.vhd`,
`sim/tb_llama_top_real.vhd`, `sim/tb_llama_top_normw.vhd`,
`sim/tb_llama_top_seq.vhd`).
**Tools:** `gcc`, Python 3 + numpy 2.2.6, `tools/gen_layer_program.py`,
`tools/dprog_check.sh`, `git`. No GHDL run was needed and no hardware was
touched.

---

## 1. The question, verbatim

> **1. `ref/run9b.c` writes no TOKEN record.** It computes the argmax and
> prints it. LOGITS reports that one `seam` call fixes it, and that until then
> the 9B reference's argmax (2614 at position 0, agreed by both rungs) cannot
> be compared automatically. That is the last manual step between the reference
> and an automatic verdict on the one quantity that decides a token. Do it, and
> make the comparison automatic.
>
> **2. A windowed-versus-single value check for the lm_head.** LOGITS verified
> that `output.weight`'s 15 windows are correct **as geometry, not as values**,
> and flagged the awkward part honestly: the gateware REFUSES a 248,320-row
> descriptor, so the comparison has to be `ref/matvec_int4.c` against itself.
> Decide whether that is worth doing and say why [...]
>
> **3. The golden's generate-not-commit decision.** [...] It says generating it
> in the gate rather than committing it is the real fix, costing a gate row and
> about 40 s, and left the decision to the dispatcher. **My decision: do it**,
> unless you find a concrete reason not to, in which case say so and leave it
> committed.

And, mid-track, a fourth:

> `tools/dprog_check.sh` FAILS at HEAD on `C1-count`:
> `program writes 504 regions, llama.cpp's graph has 505 seams`
> [...] Please determine which, fix it, and say plainly if the right answer is
> that `dprog_check.sh` should not hardcode a count at all.

---

## 2. The answer, up front

**1. Done, and the automatic verdict exists.** `ref/run9b.c` writes a `TOKEN`
record (S32, exp 0, n = 1) and `tools/ref9b/check_token.py` compares it across
any number of streams. MEASURED: all three rungs pick **2614** at position 0 and
**314** at position 1, and the comparison now exits 0/1 instead of being read
off two terminals. **TOKEN is the only whole-model seam that can ever compare
EXACTLY between `ref/run9b` and a card**, because `run9b` writes LOGITS as f32
while the design publishes raw s32 -- an index has no such problem.

**2. Not worth doing as a value comparison, and the reason is stronger than
"round trip": it is an IDENTITY.** `mv4i_matvec` takes no row offset, so a
window in that model is the prefix `[0, row_start+n_rows)` sliced, and the
compared elements are literally the same array elements the single call wrote.
The difference cannot be anything but zero **for any schedule whatever**,
including one that overlaps, gaps or reverses. What was worth building instead
is `tools/ref9b/lmhead_window_check.py`: the 15 descriptors as a SET, where a
single window with a different `out_shift` or `w_exp` gives 17,376 wrong logits
inside a schedule whose row cover and byte cover are both perfect, and nothing
in the tree looked at that.

**3. NOT a gate row, and the empirical reason is decisive.** The golden TRACK
LOGITS regenerated at `d1d1e95` a few hours earlier was **already not provably
current** by the time this track measured it. A gate row added that morning
would have been red for the whole window with nothing wrong. It stays
committed, and `tools/ref9b/golden_status.sh` answers "is it current?" in about
a second with no simulation, naming the files that moved.

**4. Neither the map nor the program was wrong, and nothing hardcodes a
count.** `seam_map` gained a `TOKEN` row at `35e0ed0` -- a real seam that NO
descriptor produces, being the argmax `rtl/sampler_stream.vhd` makes from the
LOGITS stream. `dprog_oracle.expected()` decided membership of that class by
testing one name, `R_X.embed`, so it counted TOKEN as a step. The map now
declares the class and the oracle filters on the declaration.
`DPROG_CHECK: PASS`.

---

## 3. The procedure, in the order it was run, and what each step isolates

| # | probe | what it isolates |
|---|---|---|
| 1 | Read `seam_stream.h`, `r9bs.py`, `seam_bisect.exact()`, `ref_stream_scaled.py` | what KIND a TOKEN record must be for a card capture to compare against it, before writing one |
| 2 | Add the record and the version gate to `ref/run9b.c`; run 2 tokens of the real 9B model | that the reference emits it and the reader accepts it |
| 3 | `check_token.py` across three rungs | the automatic verdict, and whether the three rungs agree |
| 4 | `mutate_token.py`, 5 mutations on the STREAM | whether the checker has teeth, and where its floor is |
| 5 | Re-run 4 after the checker's own defect was found | that the fix restores the two kills it had lost |
| 6 | Read `mv4i_matvec`'s signature and row loop | whether a windowed-vs-single VALUE check is an oracle, a round trip, or an identity |
| 7 | `gen_layer_program.py --json`, with and without `--one-lmhead-job` | the 15 descriptors, as EMITTED bytes rather than as a generator's loop |
| 8 | `lmhead_window_check.py` + 12 field mutations | the defect class nothing else covers, and which fields the check cannot see |
| 9 | Reproduce `dprog_check.sh` on a pristine `git archive 2a411bb` tree | that the red check is real and not a working-tree artefact |
| 10 | Count `SEAMS`, and do the arithmetic 492 - 2 + 15 | WHICH side was wrong, before editing either |
| 11 | Fix, re-run, then deliberately misdeclare `R_XN.final` | that `C1-count` still fires -- a fix that silences a check is not a fix |
| 12 | Read `regress.sh`'s planner and `run_one`; `git status` on `sim/tb_llama_top*.vhd` | whether a gate row is even available to this track |
| 13 | `golden_status.sh` on the real repository, then 7 teeth on throwaway git trees | whether the golden is current, and whether the checker can say either answer |

Steps 6 and 10 are the two that changed a decision. Both are reading, not
running.

---

## 4. What changed

| file | what |
|---|---|
| `ref/run9b.c` | `argmax_first()` and `seam_token()`; the header declares format version 2 on any run that will emit `TOKEN`; `lm_head`'s comment now states that it runs as ONE job a descriptor the gateware refuses, why the numbers are unaffected, and where the tiling is checked |
| `tools/ref9b/check_token.py` | new. The automatic verdict on the decided token, with REPORTED/DERIVED labelling and the margin |
| `tools/ref9b/mutate_token.py` | new. Teeth for the above, applied to the stream bytes |
| `tools/ref9b/lmhead_window_check.py` | new. The 15 lm_head windows as a SET |
| `tools/ref9b/golden_status.sh` | new. Is a committed golden provably current, and which file moved |
| `tools/ref9b/capture_llama_top.sh` | `LIST_FILES=1` prints the analysis closure, so the staleness check reads it rather than copying it |
| `tools/ref9b/seam_map.py` | `NON_DESCRIPTOR` and `descriptor_seams()`: the map declares which of its rows no descriptor produces |
| `tools/dprog_oracle.py` | `expected()` filters on that declaration instead of testing one name. **Not this track's file** -- see section 8 |
| `tools/dprog_check.sh` | a dated CORRECTION to its own trap note, and the answer to "should it hardcode a count" |
| `tools/ref9b/README.md` | the token check, the window check, and the golden-rot section |

**`sim/regress.sh` is NOT touched, no gate row is added or removed, and
`BASELINE_PASS` is unchanged.** MEASURED: `git diff --name-only 35e0ed0..HEAD
-- rtl/ sim/` lists three files and **none of them is in any of this track's
four commits** (they are TRACK ORDINAL's `a9792df`). No VHDL was touched, so
the GHDL gate cannot be affected by this work.

Commits: `d23770c`, `fd4cc70`, `7277ec9`, `99bfe85`.

---

## 5. The evidence, as raw captured output

### 5.1 The TOKEN record exists and the format carries it

```
$ ./ref/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad \
      --tokens 760,6511 --out ref_bfp_token.r9bs
EMBED gguf  gguf .../Qwen3.5-9B-BF16.gguf v3 align=32 tensor=token_embd.weight BF16 ...
TOKEN 0 id=760  argmax=2614 logit=12.379822  32.21 s
TOKEN 1 id=6511  argmax=314 logit=17.002502  30.25 s
wrote ref_bfp_token.r9bs: 984 records

$ python3 r9bs.py ref_bfp_token.r9bs | grep -E 'TOKEN|LOGITS'
LOGITS   tok=0 layer=-1  n=248320  f32       min=-11.6257 max=+12.3798 rms=3.87037
TOKEN    tok=0 layer=-1  n=1       s32 e=0   min=+2614 max=+2614 rms=2614
LOGITS   tok=1 layer=-1  n=248320  f32       min=-12.1376 max=+17.0025 rms=2.95226
TOKEN    tok=1 layer=-1  n=1       s32 e=0   min=+314 max=+314 rms=314

$ head -c 8 ref_bfp_token.r9bs | xxd
00000000: 5239 4253 0200 0000                      R9BS....
```

Version 2, as the S32 kind requires. `--selftest` was run first and is exact on
all three sampled tensors.

### 5.2 The automatic verdict, three rungs

```
$ python3 check_token.py ref_bfp_token.r9bs /mnt/storage/ref9b/ref_f32.r9bs \
      /mnt/storage/ref9b/anchor_f32.r9bs --tok 0 --tok 1
tok    stream                   source    token    n        gap        gap/rms   top2
0      ref_bfp_token.r9bs       REPORTED  2614     248320   2.13428    0.55144   10.2455
0      ref_f32.r9bs             DERIVED   2614     248320   2.16894    0.55966   10.2123
0      anchor_f32.r9bs          DERIVED   2614     248320   1.91063    0.46804   10.3056
1      ref_bfp_token.r9bs       REPORTED  314      248320   0.263092   0.08912   16.7394
1      ref_f32.r9bs             DERIVED   314      248320   0.281088   0.09498   16.7604
1      anchor_f32.r9bs          DERIVED   314      248320   0.743801   0.24696   16.5968
# 3 stream(s), 2 token position(s); 2 REPORTED row(s) (the producer's own argmax),
#   4 DERIVED (this script's argmax over that producer's own logits -- a round trip for it)
EVERY STREAM DECIDES THE SAME TOKEN AT EVERY COMPARED POSITION.  That is an
agreement about a decision with a margin, not about the logits; see the gap/rms
column and use seam_bisect.py for the vectors.
rc=0
```

**Only the run9b row is REPORTED.** The llama.cpp anchor can never be anything
but DERIVED: sampling happens outside the graph `cb_eval` sees
(`seam_map.py:38-42`), so the anchor has no argmax to publish. The load-bearing
comparison is therefore run9b's REPORTED against the anchor's DERIVED, which is
our INT4 fixed-point model against somebody else's BF16 f32 graph. The `ref_f32`
row is a third INDEPENDENT logits vector but NOT a third argmax implementation,
and the script's header says so rather than letting three green rows read as
three independent confirmations.

### 5.3 What an argmax agreement is and is not, at the 9B shape

This is the 9B analogue of TRACK LOGITS's section 5.7, and the two positions
of the reference prompt turn out to be very unequal:

```
position 0: winner 2614 = 12.3798218, runner-up 7193 = 10.2455444,
            gap 2.13427734, rms 3.87037, gap/rms 0.55144
            smallest single-element change that moves the token: -2.1342783
position 1: winner 314,  gap 0.263092, rms 2.95226, gap/rms 0.08912
```

So on this stimulus a single logit at position 0 must move by **2.134**, more
than half the vector's own RMS, before the token notices -- while
`seam_bisect --mode exact` resolves one LSB. At position 1 the same threshold is
**0.263**, eight times tighter. **An agreement on TOKEN at position 0 is a much
weaker statement than an agreement at position 1**, and a harness quoting "all
positions agree" without the margins is quoting a number whose meaning varies
by a factor of eight along the prompt. That is why the margin is a column of
the verdict and not a footnote.

The anchor's margins differ from ours (1.911 against 2.134 at position 0), which
is itself the INT4 weight format moving the top two relative to each other.

### 5.4 The teeth, and the defect they found in the checker

Five mutations of the stream, against the anchor:

| mut | what it breaks | verdict | how it presents |
|---|---|---|---|
| control | nothing | -- | same token, rc 0 |
| **T1** | the TOKEN record's payload, +1 | **KILLED** | self-disagreement AND cross-stream disagreement, rc 1 |
| **T2** | the winning logit reduced by HALF its margin | **SURVIVES, by design** | token unchanged; gap/rms falls 0.551 -> 0.276 |
| **T3** | the winning logit one f32 ULP BELOW the runner-up | **KILLED** | "its TOKEN record says 2614 but the argmax of its own LOGITS is 7193" |
| **T4** | the top two values exchanged | **KILLED** | same, and the multiset is unchanged, which is the shape of an index permutation |
| **T5** | the runner-up raised to an exact TIE | **SURVIVES** | `TIE (the first-max rule IS exercised here)` |

Raw, for the two that carry the most information:

```
===================== T2 =====================
# T2 tok 0: winner 2614 = 12.3798218, runner-up 7193 = 10.2455444, gap 2.13427734,
#           smallest move-the-token change = -2.1342783
0  mut_T2.r9bs      REPORTED  2614  248320  1.06714   0.27572  10.2455
0  anchor_f32.r9bs  DERIVED   2614  248320  1.91063   0.46804  10.3056
EVERY STREAM DECIDES THE SAME TOKEN AT EVERY COMPARED POSITION.
rc=0

===================== T4 =====================
  !! mut_T4.r9bs tok 0: its TOKEN record says 2614 but the argmax of its own
     LOGITS is 7193 -- the producer disagrees with ITSELF, so at most one of
     the two records is right
0  mut_T4.r9bs      REPORTED  2614  248320  2.13428  0.55144  10.2455
0  anchor_f32.r9bs  DERIVED   2614  248320  1.91063  0.46804  10.3056
TOKEN CHECK: FAIL (1 disagreement(s))
rc=1
```

**T2 is the resolution floor and is the most valuable row.** A logit moved by
1.067 -- 27.6% of the vector's RMS -- is completely invisible to any token
check, and will be, on any stimulus, up to the margin. **T5 is the first thing
in this tree that exercises the first-max-on-ties rule at all**; TRACK LOGITS
recorded it as unreached because all 128 scaled logits were distinct, and all
248,320 here are too. T5 manufactures the tie and confirms the checker resolves
it to the FIRST index. Note the scope: it prices the CHECKER's `argmax_first`,
not the producer's, because the producer's TOKEN was computed before the
mutation.

**T3 and T4 SURVIVED the first version of `check_token.py` and that was a real
defect in it.** The first version decided REPORTED vs DERIVED as each record
arrived. `ref/run9b.c` writes LOGITS and then TOKEN, so the logits set the row
to DERIVED and the later TOKEN record overwrote that verdict without ever
re-checking -- and a producer disagreeing with ITSELF, which is exactly what a
broken sampler looks like, passed in silence. The reconciliation is now after
the whole walk. **Record order is not something a stream reader may assume.**

Three further teeth on the harness rather than the data, all rc 1: one stream
with no `--expect` refuses to call itself a pass; a wrong `--expect`; and a
`--mutate-token` override.

### 5.5 The lm_head value check is an identity, not a round trip

`ref/matvec_int4.c:329`:

```c
int mv4i_matvec(const mv4i_file *f, const int16_t *x_mant, int x_exp,
                int n_rows, int n_cols, int out_mode, mv4i_result *out)
{
    ...
    if ((uint32_t)n_rows > f->h.M)       return -3;
    for (int r = 0; r < n_rows; r++) {
        ...
                int8_t cb = f->h.codebook[get_widx(f, r, k)];
```

There is no `row_start` parameter and `get_widx` is called with `r`, so output
row r is always FILE row r. `ref/run9b.c:a_job` windows by computing
`need = row0 + nrows` rows and reading `ybuf[row0 + r]`. A "windowed" lm_head
built the same way therefore compares elements of the same array the single
call wrote. The zero is forced by the code, for any schedule at all, and
running it would have produced a number with no information in it.

What is NOT forced, and is not checked anywhere else, is that the 15 emitted
descriptors AGREE. Control:

```
$ python3 lmhead_window_check.py --manifest .../qwen35-9b-mv4i-qkvpad/manifest.json
# 15 lm_head window(s) emitted; the --one-lmhead-job form emits 1
# the one-job form: row_start 0 n_rows 248320 -> accepted=False  ERR_DESC: shape
# tiling: 15 windows cover rows 0..248320 exactly once, from the emitted row_start/n_rows
# per-window relations: s_beats == w_beats everywhere, equal n_rows give equal beats,
#   descriptors at a constant stride of 512 bytes
# rel: the source region is released on the last window only
# field agreement: 6 a_job field(s) and 10 step field(s) checked identical across all 15 windows
# 12 field(s) are per-window by design and are named, not skipped: desc_addr, idx,
#   logical_row, n_rows, ordinal, reason, rel, row_start, s_beats, segment, step, w_beats
# raw y_exp = w_exp + x_exp - out_shift = 10 on every window, so one smp_exp covers the token
LM HEAD WINDOW SET: the 15 windows tile the vocabulary exactly once and agree on
every field that is not per-window.  This says NOTHING about the matvec
arithmetic, which is shared by every window and is checked at the unit by
sim/run_matvec.sh and at the whole model by rung 1.
rc=0
```

Teeth, 12 mutations of the decoded program:

| mut | verdict | how it presents |
|---|---|---|
| `out_shift@3` | **KILLED** | field disagreement AND `RAW EXPONENT is not window-invariant: [9, 10]` |
| `w_exp@0` | **KILLED** | the same two |
| `K@9` | **KILLED** | `FIELD a_job.K DIFFERS ACROSS WINDOWS` |
| `src@5` | **KILLED** | `FIELD step.src DIFFERS ACROSS WINDOWS` |
| `row_start@7` | **KILLED** | a gap of 1 at window 7 AND an overlap of 1 at window 8 |
| `n_rows@14` | **KILLED** | `the set covers 248321 rows, the tensor has 248320` |
| `desc_addr@2` | **KILLED** | `not at a single ascending stride: [511, 512, 513]` |
| `w_beats@1` | **KILLED** | equal `n_rows` disagree on beats, and `s_beats != w_beats` |
| `s_beats@0` | **KILLED** | the same two |
| `rel@3` | **KILLED** | `the release is on window(s) [3, 14]; it must be on the LAST window and no other` |
| **`rel@14`** | **SURVIVES** | the `rel` check asks WHICH window carries the release, not what value it carries |
| unclassified field | **KILLED** | a field the checker has never seen is a FAILURE, not a pass |

`desc_addr`, `w_beats` and `s_beats` all SURVIVED the first version of this
file, which declared them per-window and then checked them with nothing. **A
field declared per-window and left unchecked is exempt, not covered**, which is
the same defect shape as a seam present in both streams and never walked. The
relations in section 2b of the file are the fix and they need no constant from
anywhere: they are statements about the SET.

### 5.6 `C1-count`: neither the map nor the program

Reproduced on a pristine `git archive 2a411bb` tree with none of this track's
changes present:

```
=== PROGRAM: --stamp manifest, must PASS ===============================
dprog_oracle: 505 steps, 39330 checks, 1 FAIL
  FAIL C1-count       program writes 504 regions, llama.cpp's graph has 505 seams
DPROG_ORACLE: FAIL
=== CONTROL: --stamp sched, must FAIL =================================
  by check: C1-count=1, C4-outshift=253, C4-wexp=311, C8-hdr=564
DPROG_CHECK: FAIL
```

The arithmetic that names the side:

```
len(seam_map.SEAMS)                = 492
  - R_X.embed  (a host write)      = 491
  - LOGITS, expanded into windows  = 490
  + 15 lm_head row windows         = 505      <- expected()
program's writing steps                        504
491 - 1 - 1 + 15                   = 504      <- expected() WITHOUT the TOKEN row
```

`SEAMS`'s last four rows at `2a411bb`:

```
[('R_X-31', 'l_out-31', 0, None), ('R_XN.final', 'result_norm', 0, None),
 ('LOGITS', 'result_output', 0, None), ('TOKEN', None, 0, None)]
```

`TOKEN` was added by TRACK LOGITS at `35e0ed0` and it belongs there: it is a
seam of the model with an RTL side and no anchor. It is simply not produced by
a DESCRIPTOR -- it is the argmax `rtl/sampler_stream.vhd` makes from the LOGITS
stream, downstream of the lm_head jobs rather than one of them. And
`seam_region("TOKEN")` raises, so it is hazardous to any consumer that walks
`SEAMS` asking for a region. `expected()` decided membership of that class with
`if rtl == "R_X.embed"`, which knew about the host embedding write and nothing
else.

After the fix, same pristine tree:

```
=== PROGRAM: --stamp manifest, must PASS ===============================
dprog_oracle: 505 steps, 39330 checks, 0 FAIL
DPROG_ORACLE: PASS
=== CONTROL: --stamp sched, must FAIL =================================
  by check: C4-outshift=253, C4-wexp=311, C8-hdr=564
dprog_check: control FAILED as required.
DPROG_CHECK: PASS
```

**A second finding, in the directional control.** Its breakdown used to read
`C1-count=1, C4-outshift=253, C4-wexp=311, C8-hdr=564`. That `C1-count=1` was
this same bug, not the index-derived stamping the control exists to
demonstrate. The control was failing partly for the wrong reason; it now fails
only for the right ones.

TEETH on the fix, because a fix that silences a check is not a fix. Declaring
`R_XN.final` non-descriptor on purpose:

```
  FAIL C1-count   program writes 504 regions, llama.cpp's graph has 503 seams
  FAIL C1-logits  seam 488 result_output: expected a sampler stream, got dst=R_XN flags=0x0
  FAIL C1-op      seam 488 (LOGITS): llama.cpp node result_output is a A_JOB,
                  program step 488 is a VEC_NORM
  by check: C1-count=1, C1-logits=1, C1-op=1, C3-lmwin=2, C3-ncols=1,
            C4-outshift=1, C4-wexp=1, C9-sbase=42, C9-wbase=336
```

**Directly answering the dispatcher's question: NOTHING hardcodes a count, and
nothing should.** Both sides of `C1-count` are derived -- the left from the
emitted descriptor bytes, the right from the seam map plus the RTL's
`MAXROWS_BFP` window derivation -- and that is precisely why the check is worth
having. Freezing either side to a literal would convert a real disagreement
into a number somebody bumps. What must not be restated outside the map is
WHICH seams a descriptor produces.

### 5.7 The golden, and why a gate row was the wrong instrument

```
$ bash tools/ref9b/golden_status.sh
=== real ============================================================
  65 record(s), stamped rev 'd1d1e95'
  NOT PROVABLY CURRENT.  Re-capture before diffing anything against it:
    SMP=1 bash tools/ref9b/capture_llama_top.sh real
  changed between d1d1e95 and HEAD:
    rtl/llama_top.vhd
    sim/llama_sched_pkg.vhd
    sim/seq_tbl_pkg.vhd
    sim/tb_llama_top.vhd
  edited in the WORKING TREE right now (so a capture taken here is
  a capture of nobody's commit):
    sim/tb_llama_top.vhd
```

**The golden TRACK LOGITS regenerated a few hours earlier is already not
provably current.** That is the empirical form of reason 3 below: a byte-identity
gate on this artefact would have been red for that entire window with nothing
wrong, and the next track would have had to adjudicate somebody else's numbers
in order to unblock its own work.

The three reasons, each independently sufficient:

1. **`sim/regress.sh` has no non-VHDL row type.** Its plan is built by globbing
   `sim/*.vhd` and `tb/*.vhd` (`SUITE_DIRS`, `:783`) and `run_one` (`:1212`) is
   `ghdl -a` over a file list then `ghdl -r` on a top entity. A shell or Python
   row needs new machinery in the planner, in `run_one` and in the judging, in
   a file five tracks edited today.
2. **A VHDL-shaped row would live at `sim/tb_llama_top_*.vhd`**, which TRACK
   OI-3B owns and had UNCOMMITTED EDITS in: `git status --porcelain --
   sim/tb_llama_top.vhd sim/tb_llama_top_real.vhd` showed ` M` on both.
3. **A byte-identity gate moves the cost rather than removing it**, as above.

Teeth on `golden_status.sh`, on throwaway git repositories built from
`git archive HEAD`:

| # | setup | verdict |
|---|---|---|
| G1 | restamp to the tree's own commit | **CURRENT, rc 0** (positive control) |
| G2 | `rtl/llama_top.vhd` changes | NOT PROVABLY CURRENT, names it |
| **G3** | `docs/WORKLOG.md`, `rtl/attention.vhd` and `sim/tb_gdn_block.vhd` all change | **CURRENT, rc 0** |
| G4 | a working-tree edit inside the closure | named separately from committed drift |
| G5 | a stamp naming an unknown revision | refused |
| G6 | no stamp at all | refused |
| G7 | stamped `TREE WAS DIRTY` | refused, "stale is not the question" |

**G3 is the row that matters most.** Three files move, one of them a real
`rtl/` file, and none is in this capture's closure; the check still says
CURRENT. Without that row nothing distinguishes this tool from one that always
says stale, which would be decoration.

---

## 6. Measured and REJECTED -- do not retry

- **Do not build a windowed-versus-single VALUE comparison of the lm_head in
  `ref/matvec_int4.c`.** MEASURED by reading `mv4i_matvec`'s signature and row
  loop: there is no row offset, a window is the prefix sliced, and the
  difference is an IDENTITY rather than a round trip. It would return zero for
  a schedule that overlapped, gapped or reversed the windows, so its zero
  carries no information about anything. What such a check is worth doing for
  splits into a windowing bug (already covered by `gen_lmhead_windows.py` and
  `tb_seq_tbl_shape`) and a shared matvec error (not catchable by any
  model-against-itself comparison, and covered by `sim/run_matvec.sh` and rung
  1 instead).

- **Do not add a gate row that diffs a fresh capture against the committed
  golden.** MEASURED: the golden regenerated at `d1d1e95` was already not
  provably current hours later, with four closure files moved and one dirty. It
  would have been red for the whole window with nothing wrong, and the cost of
  adjudicating it would have landed on whichever track needed the gate green
  next. A byte-identity gate is right for an artefact that must not change, and
  the real-path capture is not one while B and C are still landing recipes.

- **Do not try to add a shell or Python row to `sim/regress.sh` for this.** Its
  planner globs `*.vhd` and `run_one` is GHDL-only; the row type does not exist
  and creating it is surgery on a file five tracks edited today.

- **Do not compute the TOKEN oracle by taking the argmax of the stream you are
  checking.** That is what `check_token.py` labels DERIVED, and it is a round
  trip for that producer by construction. It is meaningful ACROSS producers and
  is the only thing available for the llama.cpp anchor, which has no argmax to
  publish, but a DERIVED row is never evidence about the producer whose logits
  it read.

- **Do not read three green rows as three independent confirmations.**
  MEASURED: `ref_bfp` and `ref_f32` share `run9b`'s single `argmax_first`, so
  they are one argmax implementation over two logits vectors. Only the anchor
  is a second implementation of anything, and it is DERIVED.

- **Do not quote "every position agrees" without the margin.** MEASURED on the
  reference prompt: position 0's margin is 2.134 (0.551 of RMS) and position
  1's is 0.263 (0.089). The same sentence means two things eight times apart
  depending on which position produced it.

- **Do not use `gap * 1.0000001` to build a "just crosses the runner-up"
  mutation on an f32 payload.** MEASURED: it rounds back to an exact TIE, which
  the first-max rule then resolves to the ORIGINAL winner, so the mutation
  looks like a survivor when it simply was not applied. One ULP below the
  runner-up (`np.nextafter`) is the honest smallest step.

- **Do not conclude from a lone `C1-count` failure that the descriptor program
  is wrong.** MEASURED twice now, on two different `seam_map` edits. It is a
  question about which rows of the map a descriptor produces. That is now
  declared in the map, so the next occurrence should be a genuine finding
  rather than this.

- **Do not freeze either side of `C1-count` to a literal.** Both are derived and
  that is the design. See section 5.6.

## 7. Measurement traps hit, including my own

### 7.1 A checker that decided its verdict inside the walk, and lost two kills

The worst of the track, and it was found only because the teeth were run. The
first `check_token.py` set each row to REPORTED or DERIVED as records arrived.
`ref/run9b.c` emits LOGITS and then TOKEN, so the logits set DERIVED and the
later TOKEN record overwrote the verdict without re-checking against it. T3 and
T4 -- a producer whose TOKEN record disagrees with its own logits, which is
precisely the shape of a broken sampler -- both passed with `rc=0`. The
reconciliation is now after the whole walk.

The general form is worth keeping: **a reader may not assume record order**, and
a verdict computed incrementally over a stream is a verdict that depends on the
order the producer happened to write.

### 7.2 A field declared "per-window" is exempt, not covered

`lmhead_window_check.py` names 12 fields as legitimately per-window so that a
skipped field is visible rather than silent. But naming a field and then
checking nothing about it is the same hole in a different place: `desc_addr`,
`w_beats` and `s_beats` all survived mutation in the first version. The fix was
to state RELATIONS about them across the set -- equal `n_rows` give equal
beats, `s_beats == w_beats`, a constant descriptor stride -- none of which needs
a constant from anywhere.

### 7.3 A green sentence printed after a finding

`row_start@7` produced two `TILING:` failures AND then the line "15 windows
cover rows 0..248320 exactly once", because the total still came out right.
A reader skimming would have believed the last line printed. The summary is now
suppressed when any finding fired.

### 7.4 A nonzero exit that is the correct answer

`gen_layer_program.py --one-lmhead-job` exits 1, because it emits a descriptor
the gateware refuses -- which is the entire point of asking for it. Treating
the exit code as the result made `lmhead_window_check.py` fail on its own
control with an empty error message. The JSON is the result; a run that wrote
no JSON is the real failure.

### 7.5 `git revert -q` is not accepted by this git, and a teeth row silently did not run

The first attempt at negative control G3 reverted a commit with `git revert -q
--no-edit HEAD`; that git prints usage and does nothing, so the `rtl/` change
was still present and the "outside the closure" row measured nothing. It read
as a FAILING negative control, i.e. as evidence the checker was over-sensitive,
which is the opposite of the truth. Rebuilt on a fresh tree with no revert at
all. **A teeth row whose setup failed is not a result in either direction.**

### 7.6 HEAD moved three times, and one of the moves was the subject

`35e0ed0` at the start, `2a411bb` when `dprog_check` was diagnosed, and TRACK
ORDINAL's `a9792df` changed `tools/gen_layer_program.py` -- the generator
`lmhead_window_check.py` invokes -- in between. Both new checks were re-run on a
pristine tree at the later revision and both hold. The `dprog_check` diagnosis
was made on a pristine `git archive 2a411bb` tree specifically so that the four
dirty `sim/tb_llama_top*.vhd` files in the working tree could not be blamed for
or credited with anything.

### 7.7 The scratchpad is shared

Everything here is under a `reftoken_track/` prefix. This is the fourth recorded
near-miss class on the shared session scratchpad.

## 8. Ownership, disclosed rather than buried

**`tools/dprog_oracle.py` is TRACK ORDINAL's file and this track edited it.**
The brief listed it as MUST NOT TOUCH; the dispatcher's later message assigned
the `C1-count` failure to this track because its cause is in `tools/ref9b/`.
The two instructions conflict and the conflict is resolved here in the open:

- The edit is three lines of code (`if rtl == "R_X.embed"` becomes
  `if rtl in SM.NON_DESCRIPTOR`) plus the docstring explaining them. It is a
  strict generalisation: behaviour for `R_X.embed` is unchanged.
- It was made on a tree where that file was **clean at HEAD** (ORDINAL had just
  committed `a9792df`), and `git diff -- tools/dprog_oracle.py` was read in full
  immediately before the commit; every hunk was this track's.
- The alternative -- declaring `NON_DESCRIPTOR` in `seam_map.py` and leaving the
  consumer alone -- would have left `DPROG_CHECK` red, which the dispatcher
  explicitly asked to fix.
- **Removing `TOKEN` from `SEAMS` was considered and rejected.** It would have
  fixed the count with no consumer edit, but it partially reverts a deliberate
  TRACK LOGITS change whose purpose was that `--mode cross` skip the seam rather
  than report it missing, and it would leave `R_X.embed` -- the other member of
  the same class -- still handled by a name test.

## 9. What was NOT determined

- **Anything on the card.** No hardware was touched and none could be. The
  `TOKEN` record is now writable by a host driver and nothing has written one.

- **Whether `--mode exact` on TOKEN actually works against a card capture.**
  Both sides now emit S32/exp 0/n 1 and `exact()` compares equal kinds
  bit-for-bit, so it should -- but no capture exists at the 9B shape, so this is
  DERIVED from the format and the code, not MEASURED end to end.

- **The tie rule in the DESIGN, and in `run9b`.** T5 exercises
  `check_token.argmax_first` and shows it takes the first maximum. It does not
  exercise `rtl/sampler_stream.vhd`'s rule, nor `run9b`'s own, because in both
  cases the argmax was computed before the mutation. All 248,320 logits of the
  reference prompt are distinct at both positions measured, so no producer's tie
  rule is reached anywhere in this work.

- **Positions 2, 3 and 4 of the reference prompt.** Only two tokens were run
  (~30 s each). The existing five-token streams on `/mnt/storage/ref9b` were
  compared where they overlap.

- **Whether the 15 windows' WEIGHT BYTE ADDRESSES agree with
  `ref/matvec_int4.c`'s own view of the 6.5a layout.** That is the one
  remaining value-adjacent question at the lm_head and it is a genuine oracle:
  `gen_mv4i_desc.build_descriptor` computes a window's 27 sub-region bases and
  `get_widx`/`get_scale` compute where row r lives, independently. Checking them
  against each other needs a model of how the weight streamer turns
  (base, beat, lane) back into (row, k), which lives in RTL this track does not
  own. `gen_lmhead_windows.py` checks that the bases ABUT and UNION correctly,
  which is weaker: a uniformly shifted set of bases would pass it.

- **Whether the `real` golden is actually stale, as opposed to not provably
  current.** `golden_status.sh` deliberately does not answer that; only a
  re-capture does, and a re-capture from the current working tree would be a
  capture of nobody's commit because `sim/tb_llama_top.vhd` is dirty.

- **Any effect on the GHDL gate.** None is possible: `git diff --name-only
  35e0ed0..HEAD -- rtl/ sim/` lists three files and none of them is in this
  track's four commits. `sim/regress.sh` is untouched and `BASELINE_PASS` is
  unchanged. **The gate was NOT re-run**, because nothing this track committed
  can reach it and the box was carrying a place-and-route.

---

## 10. Reproducing all of it

```sh
# item 1
gcc -O2 -Wall -Wextra -I ref -o ref/run9b ref/run9b.c -lm
./ref/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad \
            --tokens 760,6511 --out /path/ref.r9bs
cd tools/ref9b
python3 check_token.py /path/ref.r9bs /mnt/storage/ref9b/anchor_f32.r9bs
for m in T1 T2 T3 T4 T5; do
  python3 mutate_token.py /path/ref.r9bs /path/mut_$m.r9bs --tok 0 --mut $m
  python3 check_token.py /path/mut_$m.r9bs /mnt/storage/ref9b/anchor_f32.r9bs --tok 0
done

# item 2
python3 lmhead_window_check.py \
    --manifest /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json
python3 lmhead_window_check.py --manifest ... --mutate out_shift@3

# item 3
bash tools/ref9b/golden_status.sh

# the fourth item
bash tools/dprog_check.sh
```

**ALWAYS pass `--manifest`**, and pass the `qkvpad` set. The default is the
PRE-QKV-PAD one, where 48 of 311 A jobs are refused, and the failure reads like
a program defect. Namespace any scratch directory with a track name.
