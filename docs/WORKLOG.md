# Parallel worklog

A live board, not a report. One section per track that is in flight, the files
each track owns so two agents cannot collide, and **the next step written down
BEFORE the result arrives**, branched by what the result could be.

Why the branches are pre-written: deciding what to do next while holding a
fresh result is how scope drifts and how a negative result gets talked into
being a positive one. If the branch was written before the answer was known,
the answer only has to be classified, not argued with.

## THE REFILL RULE (read this first, every time)

**Standing instruction from Oren, 2026-08-28: the parallel slots must not go
empty while the backlog is non-empty, and this runs overnight.**

So: **every time an agent completes, before writing the report, check the
BACKLOG below and dispatch the next ready item.** Closing a track and refilling
its slot are one action, not two. It is easy to land a result, write it up well,
and only then notice that four slots have been idle for the whole write-up --
that happened once already today and Oren caught it, not me.

Target **four concurrent tracks**. Fewer only when the backlog genuinely has
nothing whose dependencies are met. If that ever happens, say so explicitly
rather than quietly running one agent.

A backlog item is READY when its file ownership does not collide with a running
track and its listed dependency has landed. If nothing is ready, the right move
is to look for what the last few results NEWLY unblocked, because every landing
today opened at least one new item.

**Discipline for closing a track.** When an agent lands, do exactly one of:

- **MARK OFF** the branch that fired, move the row to the Landed table with its
  commit, and dispatch whatever that branch names.
- **WRITE THE ISSUE DOWN** in Open issues below, with the evidence, then either
  send the agent a follow-up (if the fix is determined) or raise it with Oren
  (if it is a decision rather than a fix). Never silently retry.

Status values: `RUNNING`, `LANDED`, `BLOCKED-DECISION` (needs Oren),
`BLOCKED-DEP` (waiting on another track).

---

## File ownership, right now

Two agents editing one file has already cost this project real time. Nothing
below may be edited by a track that does not own it.

| path | owner | note |
|---|---|---|
| `sim/regress.sh` | **SHARED** | any track adding a test edits it. Re-read it immediately before editing, keep the edit to the rows you add, and re-check `BASELINE_PASS` at commit time. |
| `rtl/llama_top.vhd`, `sim/tb_llama_top.vhd`, `rtl/llama_map_pkg.vhd` | free | released by the integration track at `3246046` |
| `hw/fk33/gen_pcieep.py`, `hw/fk33/*.tcl`, `hw/fk33/*.xdc`, `hw/fk33/gen_fk33_engine.py`, `hw/fk33/rtl/fk33_engine.vhd` | free | released by TRACK SHELL at `928ad9f`. `gen_fk33_engine.py` and `rtl/fk33_engine.vhd` are new files from that track; the second is GENERATED, so edit the first. |
| `rtl/attn_*.vhd`, `sim/tb_attn_block.vhd`, `ref/attn_*` | TRACK C-ORACLE | |
| `rtl/gdn_*.vhd`, `rtl/l2norm_rs.vhd`, `sim/tb_gdn_*.vhd`, `sim/tb_l2norm_rs.vhd`, `ref/gdn_*`, `ref/l2norm*` | TRACK B-ACCURACY | |
| `tools/qwen35_tokenizer.py`, `tools/*tokenizer*`, `server/**` | TRACK TOK-C | |
| `rtl/matvec_int4*.vhd`, `rtl/weight_streamer.vhd`, `rtl/axi_rd_port.vhd`, `rtl/axi_rd_fsm.vhd`, `rtl/async_fifo.vhd`, `hw/mv_driver.c`, matvec benches | TRACK A-CTRL | landed 2026-08-28, see Landed. `axi_rd_fsm.vhd` and `async_fifo.vhd` are new files from that track and belong to it. |

**A COMPLETED AGENT CAN STILL WAKE UP AND COMMIT.** Observed 2026-08-28: the
subsystem-A-sim track reported done, was superseded, and then woke hours later
and committed `2b12a7b` while TRACK A-CTRL already owned those files. It landed
clean (a doc correction plus a comment in `sim/regress.sh`, `BASELINE_PASS`
untouched, the bench itself not touched) so nothing was lost, but that was
luck rather than design. Consequences:

- "Completed" is not "released". A track's ownership row stays until its files
  are verified quiescent, not merely until its report arrives.
- After any late commit, re-run the affected tests yourself rather than
  trusting either agent's report. That agent explicitly said its own
  confirmation run never returned and declined to claim it, which was the right
  call; the run was completed separately and all three passed.
- Prefer giving a superseded track NO further instructions. Sending it a
  follow-up is what turns a harmless late commit into a genuine collision.

**`git commit -m msg -- <paths>` COMMITS THE WORKING TREE, NOT THE INDEX.
THREE INDEPENDENT TRACKS HIT THIS ON THE SAME DAY** -- C-ORACLE, B-ACCURACY,
and me, the last of them one commit after documenting it. B-ACCURACY hit it in
its most deceptive form: it staged a single hunk of the shared `regress.sh`
with `git apply --cached` and then named the file on the commit line, which
discarded the careful staging entirely. It caught this only because the
committed `--stat` disagreed with the staged one, 22 lines against 7.

Three instances in a day means this is not an advisory to be more careful; it
is a property of the command that has to be worked around structurally. **On a
shared file: stage the hunk, then commit with NO pathspec.**
Observed 2026-08-28: TRACK C-ORACLE's first commit swept in TRACK A-CTRL's
uncommitted `sim/regress.sh` edits (`BASELINE_PASS=78`, rows for tests whose
files were not committed yet) purely because they were sitting in the working
tree at that path. It caught this and amended them out, and HEAD is clean, but
the pathspec form is the exact form this project's standing instruction
mandates in order to AVOID `git add -A`, so the two rules fight each other on
shared files.

The rule that resolves it: **for a SHARED file, run `git diff -- <file>` and
confirm every hunk is yours BEFORE committing.** If it is not, stage only your
hunks with `git add -p` and then commit with no pathspec so the index is what
lands. For files only your track owns, the pathspec form is still correct and
still the default.

An amend is only available while the bad commit is still the tip. Two tracks
committing within a minute of each other would have made it permanent.

**Editing `sim/regress.sh` under a running instance is ALREADY SAFE, and you
do not need to `pgrep` first.** bash reads a script lazily by byte offset, so
in general editing a script mid-run resumes the shell mid-token and the process
that dies is not the one that edited it. `sim/regress.sh` was bitten by exactly
this three times during its own development, once to a third party, so section
0 now copies the file to a private temp path, syntax-checks the copy in case
the original was mid-write, and re-execs that (`:287`, `:299`). From then on
the running process reads a file nobody else can name.

Recorded because a track disclosed having edited it during another run and
could not rule out damage. There was none, and there could not have been. The
disclosure was still the right call: reporting a suspected collision you cannot
disprove is worth more than a silent hope, and the answer only took one grep.

**CORRECTION, appended: commit `4891c6d` mixes two authors' work.** Its
message describes only my `regress.sh` note; everything else in it is TRACK
A-CTRL's own worklog update, swept in by a pathspec commit while A-CTRL was
editing the same file. Nothing was lost and A-CTRL's content is intact; the
defect is a message that described half its contents. It could not be amended,
because another track committed on top within the minute -- which is the
failure mode recorded two paragraphs above, reproduced against its own author
inside an hour.

The root cause is worth more than the incident. I ran the prescribed check,
saw it print DIRTY, and committed anyway, because I had chained the check and
the commit into one command so the check merely PRECEDED the action instead of
GATING it. **A check whose result you do not branch on is decoration.** Run the
check as its own step, read it, then act.

**Standing rule for every track: no hardware.** No `xsdb`, `hw_server`,
`vivado ... program`, `pcieep.sh`, `jtag.sh`, `flash.sh`, `program.tcl`, and
nothing that opens `/dev/xdma*`. A live FK33 is in this session, and an agent
has already destroyed its factory flash image by crossing that line.

---

## In flight

**Refreshed 2026-08-29 by the dispatcher.** The previous contents of this
section listed TRACK C-ORACLE and TRACK B-ACCURACY as RUNNING; both landed
2026-08-28. An independent review caught the staleness before I did. On a board
whose entire purpose is stopping concurrent agents from colliding, a stale row
is the next collision, so this section is now rewritten at every dispatch
rather than appended to.

| track | question | owns | dispatched |
|---|---|---|---|
| **REF9B** | A whole-model 9B numeric reference. `ref/` holds one whole-model reference and it is stories260K, so nothing here can currently say whether a token is the RIGHT token. Must choose float vs fixed-point and defend the choice against the failure mode of the one it picks. Backlog 12. | `ref/**` (new), `tools/` (new) | 2026-08-29 |
| **CONGEST** | WHERE is the shell build congested, and what does each lever cost. Measurement only: it is explicitly forbidden from implementing a fix, because every lever changes arithmetic parallelism and re-floors the cycle budgets, which is Oren's decision. | `hw/fk33/**` | 2026-08-29 |
| **B-RECUR** | Mutation coverage for `gdn_recur` and `gdn_exp_capture`, and root-cause the open `d_m` grid defect behind the 8.955 LSB worst case. Part 2 outranks Part 1. Backlog 8. | `sim/tb_gdn_recur.vhd`, `sim/tb_gdn_exp_capture.vhd`, `sim/mutate_gdn_recur*`, `sim/mutate_gdn_exp*` | 2026-08-29 |
| **SERVER** | The host seam from whole-loop-in-hardware to prefill plus decode-returning-logits; `pl_backend` v2 against a SIMULATED transport; the C tokenizer wired in. Plus the one-line `mk_shape_scaled` refusal in the Python. Backlog 5. | `server/**`, `tools/gen_layer_program.py` | 2026-08-29 |

**Standing instruction to every track: nothing may be run against the card.**
There is no bitstream at present in any case (see OI-12).


## Decisions taken, with their triggers

**Why this section exists.** An independent review on 2026-08-29 named
"decisions deferred so long they have quietly become decisions" as a failure
mode of this project. A deferral with no recorded trigger is indistinguishable
from having forgotten. Each row below says what was decided, by whom, on what
evidence, and **what event should reopen it**.

| decision | by | on what evidence | trigger to revisit |
|---|---|---|---|
| **Congestion fallback is lever C (IQ4_NL codebook to LUTRAM)**, pre-authorised: I may take it without asking if the floorplan falls short. | Oren, 2026-08-29 | CONGEST measured the codebook at 86,992 primitives, 39.5% of `matvec_core`, and 97.7%/98.8% of the design's MUXF7/MUXF8. ~7.1x win, zero throughput cost. Risk is a 32x write-coherency surface. | If TRACK PBLOCK routes the design, the fallback is not needed. If lever C is taken, its oracle work must be dispatched ALONGSIDE, not after: the correctness surface is the whole risk. |
| **Tandem PCIe Field Updates: DEFER the three-partition hierarchy decision until the design routes.** Do NOT restructure the shell for it now. | Oren, 2026-08-29 | TANDEM (`abbd2ed`) calls Tandem "unevaluable now, not merely later": its stage-1 pblock excludes `SLICE_X216Y0:SLICE_X232Y239` at DRC severity Error, 50,135 placed cells sit inside it, and they can only move LEFT into the congested half. The number that decides the whole case, the stage-1 bitstream size, is unmeasured. | **Two events, either one:** (a) the design routes AND the stage-1 bitstream size is measured; (b) the cold-boot `lspci` on card 2 shows the factory image enumerating at power-on, which would falsify the DERIVED 225.7 ms budget and remove much of the Tandem case outright. Accepted cost: retrofitting the hierarchy later is the expensive path. |
| **Logits egress is the full writeback, NOT on-card top-k.** Not a judgement call in the end. | evidence, confirmed by dispatcher 2026-08-29 | EGRESS measured writeback at 124 us, **0.32% of the 38.27 ms budget** and 32x oversupplied vs the 300 MB/s A can produce logits at, on two already-reserved idle pseudo-channels. The fabric direction is INVERTED from the intuition: top-k's logic lands inside `matvec_core`, which is 72-81% of every level-6/7 congestion window, while the writeback lands at the die edge. Top-k also loses repetition/frequency penalties, `logit_bias` outside k, speculative verification, and the oracle at the seam that decides a token, and makes `top_p` an approximation whose error the host CANNOT DETECT. | If the writeback is ever measured to add materially to `matvec_core`'s congestion. Two unexplored options are recorded in `docs/debugging/2026-08-29_logits-egress.md`: top-k plus the exact normaliser, and C2H from the existing 43-BRAM36 result buffer. |
| **Cross-stack read measurement on the card: NOT taken.** Needs a JTAG reconfiguration; raised with Oren and never confirmed. | pending | 12 of 27 masters read cross-stack; a stack offers at most 15 engine ports. | Still open. Lower priority now: the design does not route, so there is no engine bitstream to measure with. |


## Open issues

### OI-1: RESOLVED 2026-08-28 -- descriptor in memory

A is bit-exact at the FK33 geometry and the HBM can serve its 27 masters
(30 already measured at 288.0 GB/s, 100% of ceiling). Three things stand
between that and arithmetic on silicon, and the first is a decision:

1. **The register map.** `rtl/matvec_int4_axi.vhd:252,265` asserts
   `NPORTS_W=4 / NPORTS_S=1` and holds four `W_BASE`/`W_BASE_HI` pairs plus one
   `S_BASE` pair. FK33 needs 24+3. Its own header argues the map must NOT grow
   with a generic, on the grounds that it would be "a map no driver could
   parse". So this is a fork, not an edit.
2. **The HBM-to-core CDC does not exist.** `weight_streamer` is single-clock.
   At ACLK = f_core the duty is exactly 100% with zero margin, so the CDC is
   mandatory.
3. **`axi_rd_port`'s `MAXOUT` defaults to 2** (32 outstanding beats); the
   measured 288 GB/s run used 16.

Items 2 and 3 are determined work. **Item 1 was Oren's call and is now
answered: descriptor in memory.** All three landed 2026-08-28 as TRACK A-CTRL
above. This issue is closed; the record is kept because the rejected options
and their costs are the part worth re-reading.

**Two gaps opened by that work, both MEASURED by
`sim/tb_matvec_fk33_desc.vhd`'s mutation table, both deliberately NOT closed:**

- **A well-formed base pointing at the WRONG sub-region is undetectable.**
  Case 19 aims weight sub-region 7's base at sub-region 8's bytes. The design
  accepts, computes and reports success, and 4 of 100 result elements are wrong
  -- exactly the two rows that bit slice 7 carries, in each of the two live
  tiles. Nothing in the descriptor says what a sub-region should CONTAIN, so
  only the weight store's own hash can catch this. Same family as OI-3.
- **A `w_beats` that is too small HANGS.** Case 20 halves it; the array starves
  and the job never completes and never errors, because `WDOG_LIMIT` covers the
  descriptor FETCH only. Not a wrong answer, but a driver polling for
  `done or err` waits forever. Closing it needs a compute-phase watchdog whose
  limit is a per-geometry number, which is a decision rather than an
  implementation, so it was left for Oren.

### OI-2: `attn_emit.vhd:400` is a bound violation at `NGRP = 1` (latent)

**RESOLVED at HEAD, 2026-08-29.** `rtl/attn_emit.vhd` no longer assigns
`grp <= 1` anywhere; `:410` is now a comment documenting the old defect, and
the `NGRP = 1` case takes an explicit `grp <= 0; state <= S_SHIFTS`. VERIFIED
by reading the file at HEAD, not by trusting this entry. The description below
is kept for the record and is no longer the state of the tree.


`grp` is declared `integer range 0 to NGRP-1` (`:263`) and line 400 assigns
`grp <= 1` unconditionally. `NGRP` is `positive`, so `NGRP = 1` (one KV head)
is a legal generic value that is an immediate bound violation. Default is 2,
so nothing hits it today. Found by the integration track, verified directly,
deliberately not fixed.

### OI-3: the bench cannot see two classes of defect

Of nine mutations on the integration bench, **two pass while broken**: an
exponent claim re-aimed at R_X, and the prefetch consuming at k-3. Both change
every element and no property in the bench can observe either. Fourth and fifth
instance of the same family. This is the honest ceiling on what `tb_llama_top`
proves, and it is not closed by any track above.

### OI-5: RESOLVED 2026-08-28 (`c8a57d8`) -- the Python decoder was wrong on 243 ids

Found by TRACK TOK-C while verifying the C port, and deliberately NOT fixed
there. `tools/extract_tokenizer.py`'s `TOKEN_TYPE` table has `5: BYTE,
6: UNUSED`; llama.cpp has it the other way round (`5 = UNUSED`, `6 = BYTE`).
The 243 tokens with `token_type == 5` are ids 248,077..248,319, text
`[PAD248077]`..`[PAD248319]` -- vocabulary padding, not byte-map characters.
llama.cpp decodes them to the **empty string**;
`qwen35_tokenizer.py::piece_bytes` returns their literal text. MEASURED against
the oracle: 243 of 248,320 ids mismatch.

Unreachable from `encode`, so every corpus number in
`docs/debugging/2026-08-28_qwen35-tokenizer.md` stands. Reachable from a
sampler, so a server using the Python would emit text llama.cpp does not.
`server/qwen35_tok.c` is correct. The fix is one line in `piece_bytes` plus the
label swap in `extract_tokenizer.py`, but it needs a re-run of that file's
numbers, so it is an issue rather than a drive-by edit. This also withdraws
that file's claim that "13 byte-mapped characters carry NORMAL type": this
vocabulary has ZERO tokens of type BYTE. Write-up:
`docs/debugging/2026-08-28_qwen35-tokenizer-c.md` section 8.1.

**RESOLVED, `c8a57d8`.** The label swap and the decoder case are both fixed,
but the part worth keeping is the third change. **No corpus of any size could
ever have caught this**, because UNUSED tokens are unreachable from `encode`,
so the only ids the corpus can decode are the ids encoding produced. The
Python's verifier had no way to look anywhere else, which is why the C found it
and the Python did not, despite the Python having been checked over 53,411
strings AND a 1.1M-codepoint sweep. Coverage of the input space is not coverage
of the output space.

So `tools/verify_tokenizer.py` gained `--all-ids`, decoding every id in the
vocabulary one per string against the oracle -- the check the C's verifier had
and the Python's lacked. MEASURED after the fix: 248,320 ids, 0 mismatches,
corpus still 0/0. Teeth-checked by removing the fix again: 243 mismatches,
every one a `[PAD*]` token with `type=5`.

**Generalise this before the next tokenizer-shaped thing:** when a check is
driven by generated inputs, ask what part of the output space those inputs
cannot reach, and enumerate it separately.

### OI-7: `l2norm_rs` rejects a legal input, at `severity failure`

**RESOLVED at HEAD, 2026-08-29.** `rtl/l2norm_rs.vhd:256` now states the bound
INCLUSIVELY (`ssq <= shift_left(...)`), matching `:97`. Fixed by RANGE rather
than by widening `SSQ_BITS`, which would have admitted up to `2^38-1` and
thrown away half the overflow detection. VERIFIED at HEAD.


Found by TRACK B-ACCURACY and deliberately not fixed, because `l2norm_rs` sits
under `gdn_block` and `llama_top` as of `3246046`.

`rtl/l2norm_rs.vhd:97` states the bound INCLUSIVELY: `ssq <= N * 2^30`, i.e.
`2^37` at `N = 128`. `:245` asserts it STRICTLY: `ssq < 2^SSQ_BITS` with
`SSQ_BITS = 30 + LOG2N = 37` (`:128`). The vector `x[i] = -32768` for all `i`
is a legal int16 input whose `ssq` is exactly `128 * 2^30 = 2^37`, so the
maximum legal input trips the assert. MEASURED on untouched RTL:

    rtl/l2norm_rs.vhd:245: (assertion failure):
        l2norm_rs: ssq outside the u37 bound implied by N

`severity failure`, so it kills the run rather than saturating.

**Corroboration the finder did not cite:** `:90` calls this "the u38 bound",
and representing `2^37` inclusively does require 38 bits, while the constant
computes 37. The author's comment disagrees with the author's constant, which
is what an off-by-one looks like from the outside. Fix is `SSQ_BITS = 31 +
LOG2N`, or make the compare `<=`.

**Not determined: whether `ssq = 2^37` is reachable from `gdn_block`'s real
activations.** Spec 2.1.3's requantizer argues against it. That is an argument,
not a measurement, and the distinction is the whole issue: an unreachable
defect is a latent trap, a reachable one is a crash. `msb(ssq) = 37` is also
the single exponent the new 182-case sweep cannot reach, so adding it to the
vector set would turn the regression red, which is not the same thing as
reporting the defect. The generator carries it as a comment naming the
measurement.

### OI-8: `matvec_core` reads `ybuf` one past the end at the top of its row range

**RESOLVED at HEAD, 2026-08-29** (`7ccc239`). `rtl/matvec_core.vhd:928` reads
`ybuf(ybuf_addr(rd_t))` through the clamping function at `:128`, which bounds
the ADDRESS rather than gating the read, so the BRAM read port still infers.
The same buffer's WRITE side was a separate defect, OI-10, fixed at `:865`.
VERIFIED at HEAD.


Found by TRACK A-SHAPE while sweeping legal shapes, and not fixed because
`rtl/matvec_core.vhd` is not that track's file.

`ybuf` is declared `array(0 to TILES-1)` (`:191`), `rd_t` is an
**unconstrained** integer (`:389`) that `S_EMIT` advances to `tiles_r`
(`:883-884`), and `:835` reads `ybuf(rd_t)` **unconditionally every cycle**.
So whenever `ceil(n_rows / ROWS_IF) = TILES` -- that is, whenever `n_rows`
falls in the top `ROWS_IF` rows of the declared `MAXROWS_BFP` range -- the last
emit cycle indexes one past the array. Verified here by inspection of all three
lines.

MEASURED by the finder at `MAXROWS_BFP=192 / ROWS_IF=48`: `n_rows = 145` and
`n_rows = 192` each abort with
`index (4) out of bounds (0 to 3) at rtl/matvec_core.vhd:835`.

**Synthesis-benign, simulation-fatal**, the same shape as OI-7: `rd_v` is `'0'`
that cycle so nothing consumes `ybuf_q`, but GHDL kills the run. **It bites
hardest for exactly the build you would want to ship**: one that sets
`MAXROWS_BFP` to the precise `n_rows` it needs in order to save BRAM, because
then every job trips it.

Consequence for the shape check that found it: A-SHAPE's sweep deliberately
stays below the trap, so **the top corner of the row range is unverified**, and
that is precisely where an off-by-one in `tiles` would show. Closing OI-8
unblocks that verification too.

### OI-10: RESOLVED 2026-08-29 (`0ff6828`) -- `matvec_core` wrote `ybuf` past the end in raw mode

Filed by TRACK RANGE, reproduced and fixed by TRACK OUTMODE. Write-up:
`docs/debugging/2026-08-29_out_mode-raw-oracle-and-oi10.md`.

Reproduced exactly as filed. `ybuf(re2_t)` was written whenever `out_mode /=
"10"`, while `S_IDLE` bounds `n_rows` against `MAXROWS_BFP` only when
`out_mode = "00"` -- and spec 7.6 makes `n_rows > MAXROWS_BFP` **legal** in raw
("in raw mode `M` may exceed `MAXROWS_BFP`", `lm_head` being the caller).
MEASURED at `MAXROWS_BFP = 64 / ROWS_IF = 4`, `out_mode = "01"`, `n_rows = 65`:
`index (16) out of bounds (0 to 15) at rtl/matvec_core.vhd:839`, with the SAME
65 rows in partial mode passing in the pass immediately before it.

**Two corrections to the filing, both worth carrying.**

1. **It is NOT reachable "on exactly the argument that produced OI-8".** That
   argument is `n_rows` in the top `ROWS_IF` rows *of* the range, and raw mode
   at exactly `MAXROWS_BFP` passes on unfixed RTL (measured). The write pointer
   stops at `tiles - 1`; only OI-8's read pointer runs one past. OI-10 needs
   `n_rows` **above** the range. Do not look for it at the top corner.
2. **`out_mode = "10"` was NOT unexercised.** `sim/tb_matvec_core` PASS 2 has
   been running partial and comparing `y_data` against the reference's `ACC`
   line all along. `out_mode = "01"` was driven, too, by
   `sim/tb_matvec_cb_lockstep` -- but that bench compares four runs **against
   each other** at one tile and never against `ref/matvec_int4.c`, so raw had
   no oracle. "Never run" was wrong; "never checked against the reference" was
   right, and it is the half that mattered.

Fixed by narrowing the write ENABLE to `out_mode = "00"`, not by clamping the
address as OI-8 did: OI-8 clamped because that access is a READ that must stay
unconditional to infer the BRAM read port, while this is a WRITE whose
condition already IS the write enable. `ybuf` is the BFP output buffer and
nothing else, so the raw write was dead as well as out of range.

`sim/tb_matvec_core` now drives all three modes against the reference and needed
no new vector -- `ref/matvec_int4.c` already writes the `YDATA` line and that IS
the raw payload; the loader was dropping it. 343 output values compared, up from
24. Six mutations; the one that does NOT bite is the alternative address-clamp
fix, which is the bench's permanent resolution floor here because nothing reads
`ybuf` in raw mode at all.

### OI-11: WITHDRAWN for the FK33 arm, RESOLVED 2026-08-29 for the AXU3EG arm

Filed by TRACK RANGE against `sim/tb_matvec_fk33_desc.vhd`; examined by TRACK
OUTMODE.

**The FK33 arm does not have this defect and did not have it when the issue was
written.** Its `k = 0` branch is `if st(2) = '1' ... elsif st(0) /= '1' then
"is LEGAL and never completed (timeout N)"`, so a hang exits the bounded poll
with both bits clear and is scored as a failure. `git log -S"is LEGAL and never
completed"` puts that line in `f693faf`, which predates `7ccc239`, the commit
under which OI-11 was filed. Withdrawn for that arm.

**The gap is real on the AXU3EG arm**, which the filing did not name. That arm
ties off the weight masters, so an accepted descriptor can never complete by
construction and there is no `done` to poll; its verdict was `err` alone after a
fixed window. A design that silently did nothing -- never started, never errored
-- scored as an acceptance.

Closed by requiring the accepted descriptor to be RUNNING: STATUS bit 1 (`busy`)
set and bit 0 (`done`) clear after the window. That is the only completion-class
statement available where completion cannot happen. TEETH, MEASURED: an RTL
mutant that never raises `busy` on the accepted path passes the ENTIRE bench at
HEAD -- both shape sweeps, all 22 cases, `GHDL_EXIT=0` -- and fails 9 of 9 legal
AXU3EG shapes with the check in place. Nothing else in the tree saw it.

### OI-9: the descriptor error-code space is FULL

`EC_SHAPE = 0xF` (`rtl/matvec_int4_desc_pkg.vhd:52-57`) took the last free
value. `0x0, 0x3, 0x4, 0x9..0xE` were already taken and `0x1, 0x2, 0x5..0x8`
stay reserved for subsystem D, whose header this format shares verbatim. The
field is 4 bits and it is now full.

Not urgent, and deliberately not pre-solved: the next error condition anyone
wants to report has nowhere to go, and the options (widen the field, subdivide
a code using `ERR_INFO`, or take a reserved D value) all have consequences for
D. Whoever needs the next code decides. Recorded now so that decision is not
discovered at the worst moment.

### OI-6: llama.cpp aborts on some malformed UTF-8 (upstream, informational)

`unicode_cpt_from_utf8` masks a 4-byte UTF-8 lead with `0x07` and applies no
upper bound, so the bytes `F4 BF BF BF` decode to U+13FFFF;
`unicode_cpt_to_utf8` then throws `std::invalid_argument` and nothing between
there and `llama_tokenize` catches it. The process dies with SIGABRT.
Reproduced against `llama.cpp.upstream@1692f9e5`. Only reachable from a host
that feeds raw bytes; a JSON parser rejects them first. Recorded so nobody
re-derives it while fuzzing, and because it is why the byte fuzz excludes lead
bytes `0xF0..0xFF` -- there is no oracle answer to compare against.

### OI-12: the FK33 shell build does not route

**MEASURED 2026-08-29, `928ad9f`.** The first build carrying subsystem A on the
card's HBM ports places, but `route_design` terminates:

    ERROR: [Route 35-3] Design is not routable as its global congestion
                        level is 7.

7 is the top of the scale. Six attempts at initial net routing over 7 min 48 s,
then abandoned. **There is no routed checkpoint and no bitstream.**

**It is not area.** Whole design 39.50% LUT, 14.22% FF, 38.91% BRAM36, 55.03%
DSP, 0 URAM. The engine's own area in the shell is within 1.8% of the
out-of-context figure on every line (LUT 132,113 vs 134,534; FF 63,797 vs
64,067; DSP and BRAM36 identical), so the OOC numbers were honest and the
shell costs 41,581 LUT and 69 BRAM36 on top.

**It is probably not timing either, though that is not settled.** Design-wide
WNS went -0.763 after place, -0.368 after phys_opt, -0.260 at the router's last
update before it quit, against 250 MHz on the HBM AXI side and 200 MHz on the
core.

**What is NOT known is what is congested.** `report_design_analysis
-congestion` did not complete in the time available, so the 128x128
long-congestion regions south and east are the only localisation there is. The
untried experiments, in order of cheapness: a pblock putting the engine in the
clock regions nearest the HBM BLI interfaces (its core clock currently spans
all 8x4 regions); a lower clock, which separates congestion from the
timing-driven replication that added 185 of the design's 3,887 control sets;
and a different placer directive.

Write-up, including five things measured and rejected:
`docs/debugging/2026-08-29_fk33-shell-integration-does-not-route.md`.

### OI-13: the aux domain's CDC check does not scale to subsystem A

The impl-stage verification that made the aux domain trustworthy -- enumerate
every path crossing the clock boundary and demand that none is ANALYSED, since
an asynchronous group excludes a path without stopping it being enumerated --
**does not terminate** on a design containing subsystem A. MEASURED: over 20
minutes on `get_timing_paths -from <core> -to <axi> -max_paths 8`, killed.
`report_timing_summary` on the same checkpoint likewise. 28 gray-pointer FIFOs
plus 28 four-phase clear handshakes is an enormous enumeration where the aux
domain is a handful of single-bit crossings.

`gen_pcieep.py` now checks only that both clock lookups RESOLVE, which is what
decides whether the XDC `set_clock_groups` matched anything (an empty group is
a warning, not an error), and writes `report_clock_interaction` to a file for a
human. It is labelled in the script as the weaker check it is. **Consequence:
nothing currently proves the per-port CDC is being treated as asynchronous
rather than timed, and no per-clock WNS figure exists for this design.** If the
group did NOT apply, every WNS above is pessimistic rather than optimistic.

### OI-4: no descriptor-program generator exists, in any language

Subsystem D's control core is integrated and mutation-tested, but nothing emits
the descriptor program it executes. This is **host software** and it is on the
critical path for both the card and the server. **UNBLOCKED 2026-08-28:** the
descriptor format is settled and byte-pinned in
`docs/2026-08-28_matvec-descriptor-format.md`, whose section 7 carries a
reference builder in C for the A job. Still nothing emits it.

---

## Landed

| track | result | commit |
|---|---|---|
| **SHELL: the composed design does NOT route** | First FK33 build containing real arithmetic (subsystem A's descriptor plane as `fk33_engine`, 28 AXI masters). Places, then `[Route 35-3] Design is not routable as its global congestion level is 7` after six attempts over 7:47. **No bitstream exists.** NOT a timing miss (WNS -0.260) and NOT an area blowout (39.50% LUT, 55.03% DSP, 38.91% BRAM36). The engine SHRANK in the shell vs OOC (134,534 -> 132,113 LUT), so the OOC figures were honest. Corrected its brief three times: 192.5 vs 145.5 BRAM36 are different builds, masters are 28 not 27, and backlog 2's `llama_top` is a sim top with stories260K ROMs and no HBM interface. Found a combinational halt mask that did not block a GO, caught by a scratch bench with a firing negative control rather than by inspection. Peak RSS 22.81 GB. Filed OI-12 and OI-13. | `928ad9f`, `70c35db`, `d807a1c` |
| **LMHEAD: the whole token's A program is expressible** | `311 of 311 A jobs emitted, 0 refused` (was 296 of 297). 15 raw row windows at stride 17,376. **Route 2 refuted with the RTL as judge:** `matvec_int4_desc_axi`'s `S_CHECK` bounds `n_rows` in EVERY `out_mode`, so a 248,320-row descriptor is refused `err_code 0x3` in raw and BFP alike -- answering OUTMODE's open question NO. Raw over BFP is load-bearing: in BFP 832 of 1024 mantissas move and every value is exactly 2x, feeding a sampler whose only input is a bare 32-bit integer. 248,320 of 248,320 logits bit-identical, 9 of 10 mutations killed, m10 named a permanent structural non-biter. The 'destination region nobody has decided' does NOT exist: `dst = R_NONE` + `FLG_TO_SMP` was always there. Found a defect in `seq_tbl_pkg`, which encodes the job the gateware refuses. | `a781326` |
| **B-GATE: the flagship mutation now fails the gate** | `gdn_silu` and `rmsnorm_bf` had oracles that were PRINTED, not gated. Route B (in-bench real-valued oracle) chosen and Route A killed with one line: an RTL-only mutation leaves the generator reading the UNMUTATED 0.7704 LSB while the bench reads 1.68e10. Flagship closed WITH a control (same tree, only the bench swapped: FAIL new, PASS old). Gates max/count/mean/floor. **Warning for all of subsystem B: the committed `rmsnorm_bf` seed is the benign extreme of a 13x range** (honest worst 0.770 -> 9.999 LSB over nine seeds), so the pre-existing `ACC_LSB=1.0` fires on the HONEST unit at eight of nine seeds. Any B threshold calibrated on one seed is suspect. Also: a max-only gate could not have been made honest for either unit, and a mutation that destroys a unit reads BETTER than the correct one on every figure but the floor. 33 of 43 mutations killed, all 11 BOTH-class killed, 10 survivors named. | `728fcfe` |
| **QKV-PAD: 49 refused A jobs became 1** | Each fused row segment padded with ZERO rows to a whole `ROWS_IF` tile: starts 0/2064/4128, M = 8224 vs M_logical 8192, uniform across all 24 tensors and derived from GGUF metadata rather than the brief. Zero is the fill BECAUSE it is the only one also invisible under a WRONG scan domain (measured: a full-scale pad shifts ns 5 -> 8). 33,554,432 nibbles and 1,048,576 scales identical; 5 of 5 equivalence mutants bite. Found a silent pass in the tooling: a tile-aligned but WRONG `row_start` makes a descriptor the RTL accepts whose bases read past the tensor, and the gateware can never see it because `row_start` is not a descriptor field. | `e28083f` |
| **OUTMODE: raw mode had no oracle and wrote past the end of ybuf** | `out_mode=01` was already DRIVEN, by `tb_matvec_cb_lockstep` -- but that bench compares four runs against EACH OTHER and never against the reference. A round trip, not an oracle. With a real oracle attached, raw needed no new vector (`ref/matvec_int4.c` already emits `YDATA`; the loader dropped the line). Coverage 184/24 -> 464/343 values, masked rows now scored against zero rather than skipped. OI-10 fixed by narrowing the write ENABLE, not clamping the address as OI-8 did, with the reason in the code. **M6, the alternative fix form, DOES NOT BITE and is reported as a permanent floor:** nothing reads `ybuf` in raw mode, so no bench can separate the two forms. OI-11 WITHDRAWN for the arm it named (`f693faf` predates the filing, verified by ancestry) and closed on the AXU3EG arm it missed, where a `busy <= '0'` mutant passed all 22 cases. | `0ff6828`, `b65d9ad` |
| **B-FIX: three verification defects, and a corrected diagnosis** | Fixed D1 (golden two days behind its generator), D2 (the chain gate ran at the one `Z_DELAY` that hides the defect; bisection put the threshold at (520,540], corrected from '~512', and 640 is DERIVED from 616 cycles per head), and D3. **Corrected B-MUT's diagnosis on D3:** the sentinel-cancellation story explains only 14 of 17 cases past 100 LSB and the joint-worst case has NO saturation. The unifying statement is that the error is |a| times the softplus error, so the gate became a DOMAIN PREDICATE on inputs rather than a threshold. BOTH-class score 0 of 5 -> 4 of 5. Trap recorded: ghdl-mcode cannot override a `real` generic. | `ebcca86`, `6332abe`, `6e20668` |
| **TRACK TOP-KV: the KV seam at the INTEGRATION level** | `llama_top` instantiates `attn_kv_axi`, connects `attn_block`'s four seam handshakes, and advances a sequence position on `tok_done`/`tok_ack` instead of hardwiring 0. Four tokens of one sequence, TWO attention layers, three KV read latencies (100/7/403), R_X bit-identical per token, 0 KV faults. 26 mutation rows, 13 killed, 9 survivors all analysed. **Also closes backlog 14:** the gate had NO row with the real path on, and now has two. The 32-block real-weight landmark is byte-identical (`R_X(0) = -14110 hash 52347`, all 65 `log2 rms` samples). Regression 81 -> 83. `docs/debugging/2026-08-29_llama-top-kv-seam-multitoken.md` | see git log |
| Thermal guard synthetic trip | Guard halts, latches, freezes compute, releases. Teeth-checked. | `0b8831c` |
| Subsystem A at FK33 geometry | Bit-exact from real `.mv4i` bytes, 27 masters. Regression 76 -> 77. | `055b6ed` |
| AXI3 burst cap | HBM is AXI3, 16 beats not 128. Bit-exact at both; bench now runs the legal one. | `809ada7` |
| HBM port feasibility | 27 masters fit; 30 already measured at 288.0 GB/s, 100% of ceiling. Design note only. | doc only |
| Qwen3.5 tokenizer | Bit-exact vs llama.cpp, 53,411 strings x 2 + 1.1M codepoints. 7 of 9 mutations bite. | `4123bd8` |
| Qwen3.5 tokenizer in C | Bit-exact vs llama.cpp: 53,409 strings x 2, ALL 248,320 token ids, 1.1M codepoints, 20,051 malformed-byte strings. 7 of 7 mutations bite. +42,704 bytes linked, no new dependency. Found OI-5 and OI-6. | `0181cc3` |
| Full gate re-measured | 77 PASS / 0 FAIL, matches the recorded floor. Verified independently after `3246046`. | n/a |
| **C-ORACLE: `attn_block` did NOT compute attention** | First block-level oracle for subsystem C. 64 of 64 mantissas wrong on first comparison; bisected to TWO independent defects in `rtl/attn_block.vhd` (cached V exponents overwritten by the current token's, because `hdr_valid` is a level not a pulse; and every accumulator rescaled twice per rise, because `rs_have` re-latched from a still-standing `rs_valid`). Both fixed, oracle never adjusted. 17 wiring mutations, 17 killed. Regression 77, unchanged: a property was added to an existing test, not a test. VERIFIED SEPARATELY: `tb_attn_block` PASS and `tb_llama_top` PASS after the RTL fix. Note what that second one is and is not evidence for -- it shows the fix broke nothing, NOT that the fix is right, since `llama_top` runs one token at `cur_pos = 0` and never reaches either defect. The evidence the fix is right is the bit-exact oracle. | `8baa413` |
| A-sim MAXB correction | The original A agent woke, independently confirmed the AXI3 defect in its own bench, and appended a dated CORRECTION rather than editing the wrong claim out. Confirmation run completed separately: matvec_fk33, weight_streamer, axi_rd_port all PASS. | `2b12a7b` |
| **A-CTRL: the descriptor control plane, the CDC, and MAXOUT** (OI-1) | Descriptor format is D's, byte for byte, plus a four-word A extension AFTER the base array where D never reads. `matvec_int4_desc_axi` fetches and checks it before starting anything; `matvec_int4_axi` retained unchanged for the AXU3EG. Per-port async FIFO closes the HBM-to-core CDC; MAXOUT 2 -> 16. MEASURED: 100 of 100 elements bit-exact against `ref/matvec_int4.c` on the core bus AND 100 of 100 rows bit-exact through the AXI-Lite map, at `MAXB=16`, at four AXI/core clock ratios including a non-integer one. 22-case mutation table: 19 refused with the right code, 2 named as undetectable (see OI-1), 1 is the clean case. Found and fixed two of its own defects: a delta-skewed clock signal (broke `tb_matvec_int4_ip`) and a descriptor fetch left in the wrong clock domain (broke 17 of 22 cases under `DUAL_CLK`). Full gate 78 PASS / 0 FAIL, matches the raised floor. | `a4f7e17` |
| Magnitude blocker | Explosion was the STIMULUS (synthetic row norm 2^4.87 vs real 2^-0.03). PART 5 withdrawn, PART 3 reinstated. `attn_block` wired behind `C_REAL`. | `3246046` |
| **B-FIX: the three defects B-MUT measured in the CHECKING** | D1 `sim/gdn_conv_vec.txt` regenerated: 19 of 641 lines move, all case headers, all at `c % 7 == 0`, only the `cw_exp`/`e_seg`/`err` fields; no `x`/`w`/`sm`/oracle line moves and the worst-vs-oracle figure is unchanged at `4.99999999998181e-1`. Mutation R13 went pass -> FAIL against the committed golden. D2 `sim/regress.sh` now passes `-gZ_DELAY=640` to `tb_gdn_emit_chain`; MEASURED, the `z_have` mutation passes at 0/7/40/520 and fails at 540 and above, control PASSes at 640, so the kill threshold is (520, 540] and not the "~512" previously estimated. Cost 52 s -> 61 s. D3 the answer is NOT the expected one: the sentinel-cancellation diagnosis is INCOMPLETE -- the joint-worst case (70) has ZERO sentinel saturation and is 32767.9963 LSB wrong through the softplus negative-tail flush times an abs(a) of 3.09e14. `sim/tb_gdn_scalar.vhd` now GATES accuracy on a domain defined by a predicate on the INPUTS: 259 of 320 cases, worst 15.3271 LSB(Q15), gate 23.0, plus a count-past-1-LSB gate at 100 (67 measured) that catches B5 which the max cannot see, plus a beta gate and an in-domain-count FLOOR so the domain cannot empty. Teeth: 4 of 5 BOTH mutations now fail the BENCH; B4 deliberately still survives. `gdn_scalar` becomes the second of B's seven units with an accuracy gate `regress.sh` can fail. Full gate 81 PASS / 0 FAIL, matches the recorded floor; no test added or removed. Writeup: `docs/debugging/2026-08-29_b-verification-defects-d1-d3.md`. | `ebcca86`, `6332abe` + this |

---

## BACKLOG, ordered, ready-to-dispatch

Dependencies are named. An item with no dependency is dispatchable now.
Keep this list fed: when a track lands, add whatever it unblocked.

| # | task | depends on | owns |
|---|---|---|---|
| 1 | **`attn_block` <-> `attn_kv_axi` seam.** Wire the KV interface into the block and prove multi-token attention. | TRACK C-KV | `rtl/attn_block.vhd`, `sim/tb_attn_block.vhd` |
| 2 | ~~**FK33 shell integration.**~~ **DONE and NEGATIVE, `928ad9f` / `70c35db`.** 28 HBM ports enabled and driven, subsystem A connected, the thermal halt reaching it. **route_design terminates: global congestion level 7.** Area is not the reason -- 39.50% LUT, 55.03% DSP, and the engine in the shell is within 1.8% of its OOC area on every line. See OI-12. | -- | `hw/fk33/gen_pcieep.py`, `hw/fk33/*.tcl` |
| ~~3~~ | **LANDED 2026-08-29, TRACK TOP-KV.** `llama_top` instantiates `attn_kv_axi`, connects `attn_block`'s four seam handshakes, and carries a sequence position. Four tokens, two attention layers, three KV read latencies. See the Landed table. | -- | -- |
| 4 | **Token I/O: embedding and LM head.** Still 512-entry / 64-dim stories260K ROMs. The residency map gives the embedding an HBM home and says the lookup path has no owner. Note `MAXROWS_BFP = 17408` means `output.weight` and `token_embd.weight` need 15 descriptor jobs each. | none | `rtl/`(new), `tools/` |
| 5 | **`pl_backend` v2 and the server seam.** `server/llama_server.cpp` is zero-dep C++ and the C tokenizer now links. The seam must move from the AXU3EG's whole-loop-in-hardware to prefill plus decode-returning-logits. | item 4 for a real vocab path | `server/**` |
| 6 | **Subsystem D: the layer-level descriptor program.** One matvec job is emitted and verified; a LAYER needs job sequencing, region routing and the D fields subsystem A does not read. | none (format is settled) | `tools/`, `rtl/seq_*` |
| 7 | **OI-3: the two defect classes `tb_llama_top` cannot see.** An exponent claim re-aimed at R_X and a prefetch consuming at k-3 both change every element and no property can observe either. Needs a property that can. | none | `sim/tb_llama_top.vhd` |
| 8 | **`gdn_recur` and `gdn_exp_capture` mutation coverage**, plus the open `d_m` grid defect behind the 8.955 LSB worst case. | TRACK B-MUT (avoid overlap) | `sim/tb_gdn_recur.vhd`, `sim/mutate_*` |
| 9 | **Subsystem C spec reconciliation.** Six spec-named units (`attn_lane`, `attn_score_tree`, `attn_acc`, `attn_qk_norm`, `attn_ctrl`, and `attn_kv_axi` until C-KV lands) do not exist; the design took a different decomposition and the spec was never updated. The spec and the RTL now disagree. | TRACK C-KV | `docs/` spec files |
| 10 | **OI-9: the descriptor error-code space is full.** A decision (widen, subdivide via `ERR_INFO`, or take a reserved D value), with consequences for D. **Ask Oren rather than choosing.** | none | decision |
| 11 | **The five B units with no accuracy gate `regress.sh` can fail.** `gdn_silu` and `rmsnorm_bf` PRINT their oracle figures from the generator; `gdn_head_emit`, `gdn_y_emit` and `gdn_emit_chain` assert inside a generator the gate never runs, because their vectors are committed. The flagship: the `rmsnorm_bf` mutation reintroducing exactly the defect that unit exists to fix is bit-exact-green and 1.7e10 output LSB wrong. Two routes, scoped in section 7 of `docs/debugging/2026-08-29_b-verification-defects-d1-d3.md`, and they are NOT equivalent: Route A adds a `tb_vector_args` row per unit so the gate regenerates and consults the generator's exit code (cheap, also kills the D1 staleness class for good, but moves the claim out of the bench so it cannot see an RTL-only accuracy defect); Route B moves the gate into the bench, as `tb_gdn_scalar` now does (~60 lines per unit plus a measurement pass). **Do `gdn_silu` and `rmsnorm_bf` first**: the other three have oracle blind spots that must be answered before a tolerance means anything -- head_emit/y_emit exclude on an OUTPUT property and EMPTY their oracle at a narrowed rail (41 saturating + 7 all-zero = 48 of 48), and emit_chain's metric is normalised by the very quantity one BOTH mutation changes, so it moved the WRONG WAY (1.1280 -> 0.8505). | TRACK B-FIX (landed) | `sim/tb_gdn_silu.vhd`, `sim/tb_rmsnorm_bf.vhd`, then the other three |
| 12 | **A whole-model 9B numeric reference. NOTHING IN THE REPO CAN CURRENTLY SAY WHETHER A TOKEN IS THE RIGHT TOKEN.** `ref/` holds exactly one whole-model reference and it is stories260K. Every 9B claim to date is per-unit or per-seam. Until a fixed-point 9B reference stream exists, "first token" is unfalsifiable: the card will emit *a* token and no artefact here can distinguish success from failure, and on-card numeric debugging has no stream to diff against. The 9B GGUF now exists (it did not when the audit was written), so the `cb_eval` epsilon-class harness can be re-run on the real model. **Raised by the 2026-08-29 independent review; it had never been a backlog item, only a line in audit section 5.1/5.2, which is why it fell through.** Building this AFTER the card produces wrong tokens is the expensive order. | none | `ref/`, `tools/` |
| 13 | **A composed synthesis at the real shape, with stubs where a subsystem is not ready.** All composition evidence today is at `mk_shape_scaled`; the real 9B shape has never elaborated in ANY simulator, and the first full-shape elaboration is currently scheduled to happen inside Vivado on the critical path. The project's own defect record (OI-7, OI-8, OI-10: unconstrained integers, index bounds, off-by-one at maxima) is precisely the class that appears only at real dimensions, and the synthesis-fatal siblings of those have no bench that can see them. Separately, A alone MEASURED 1,585 DSP (55.0%) and the modeled B+C+D adds ~558 more, so ~74% before the shell, on a device the envelope doc calls historically non-deterministic at high DSP. **Both risks retire in one stubbed composed run.** | none | `sim/`(new), `hw/` |
| ~~14~~ | **LANDED 2026-08-29, TRACK TOP-KV.** Two rows, not one: `sim/tb_llama_top_real.vhd` (real A, B, C, the real `rmsnorm_rs` and committed real weights, 75 s, reproduces PART 6's `R_X(0) = -16339 hash 92903` exactly) and `sim/tb_llama_top_seq.vhd` (the KV cache, 302 s). They cover DISJOINT real paths and cannot be combined -- the reason is in the write-up. | -- | -- |

