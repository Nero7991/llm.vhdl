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
| `hw/fk33/gen_pcieep.py` | free | released by the HBM-port track (it deliberately changed nothing) |
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

### TRACK C-ORACLE -- does `attn_block` compute attention?

**Status:** RUNNING (dispatched 2026-08-28)
**Owns:** `ref/attn_block_vec.c` (new), `sim/tb_attn_block.vhd`, `rtl/attn_*.vhd`

**The question.** `attn_block` is wired into `llama_top` and a 32-block token
passes, but the integration bench says in its own PASS line that **nothing
establishes it computes attention**. Subsystem C has no block-level reference
anywhere. Eight units are individually excellent and the composition is
unchecked.

**Pre-written next steps:**

- **If bit-exact against a new independent C oracle** -> mark off. Next: raise
  C from "auxiliary path verified" to "block verified" in the audit, and open
  `attn_kv_axi` (the HBM KV interface, still absent) as the remaining C gap.
- **If it diverges** -> this is the most valuable outcome available today and
  must NOT be worked around. Write the divergence down with the failing case,
  bisect to the unit, and report. Do not adjust the oracle to agree.
- **If a block-level oracle proves impractical** (e.g. the block's schedule is
  not reproducible outside the simulator) -> say so plainly, and fall back to
  checking the ARRAY (`attn_mac_array`) against `ref/attn_mac_array_vec.c`
  under the block's real schedule. Partial coverage honestly labelled beats a
  block-level claim that is not real.
- **If it hits `attn_emit.vhd:400`** (the `NGRP=1` bound violation) -> that is
  a known latent defect, recorded below. Do not fix it inside this track
  without saying so; note it and route around with `NGRP >= 2`.

### TRACK B-ACCURACY -- the two places B checks transcription but not arithmetic

**Status:** RUNNING (dispatched 2026-08-28)
**Owns:** `rtl/gdn_recur_pipe.vhd`, `rtl/l2norm_rs.vhd`, their benches, `ref/gdn_*`, `ref/l2norm*`

**The question.** Two measured holes from the completeness audit:
1. `gdn_recur_pipe` is the SHIPPING recurrence and its bench **explicitly
   discards the oracle's accuracy columns** (`sim/tb_gdn_recur_pipe.vhd:147-148`
   reads and drops oracle `u` and `o`). It is checked only for equality with
   `gdn_recur`'s recipe, so a shared recipe error is invisible.
2. `l2norm_rs` is tolerance-checked against `math_real` at 0.75 LSB and
   **`ref/` contains no l2norm model at all**.

**Pre-written next steps:**

- **If both close bit-exactly** -> mark off, and B moves from "most complete"
  to genuinely oracle-covered. Next: B still has **zero** mutation coverage;
  open that as the follow-on.
- **If `gdn_recur_pipe` diverges from the accuracy oracle** -> that is a real
  finding about the shipping unit. Report it, do not relax the check, and do
  not "fix" it by reinstating the discard.
- **If `l2norm_rs` cannot be made bit-exact** (e.g. it is genuinely an
  approximation with a specified error bound) -> then the deliverable changes
  to: state the bound, prove it holds over an adversarial input sweep, and say
  so. A documented bound is a real result; a silent tolerance is not.
- **If either needs an RTL change** -> stop and report before changing RTL that
  `llama_top` now depends on.

### TRACK TOK-C -- the tokenizer in C, so the server can link it

**Status:** LANDED 2026-08-28. The first pre-written branch fired: the C
matches the oracle over the same corpus and the same sweep, and over two checks
that did not exist before (all 248,320 token ids; malformed-byte fuzz). Tables
came from llama.cpp's own `src/unicode-data.cpp`, not from a UCD download, so
the version skew cannot recur. Size reported before committing: +42,704 bytes
(+28.3%) on the native `llama_server` link, no new dependency, so the
third branch did not fire. Two findings raised as OI-5 and OI-6 below. Next, as
written: the server seam itself, still `BLOCKED-DEP` on the descriptor format
AND on rendering the chat template, which nothing implements in any language.
See `docs/debugging/2026-08-28_qwen35-tokenizer-c.md`.

### TRACK A-CTRL -- the descriptor control plane, the CDC, and MAXOUT

**Status:** LANDED (2026-08-28)
**Owns:** `rtl/matvec_int4*.vhd`, `rtl/weight_streamer.vhd`, `rtl/axi_rd_port.vhd`, `rtl/axi_rd_fsm.vhd`, `rtl/async_fifo.vhd`, `hw/mv_driver.c`, the matvec benches

**The decision, taken and not to be relitigated.** Oren chose **descriptor in
memory**: the AXI-Lite map stays constant and the 24 `W_BASE` plus 3 `S_BASE`
entries move into a descriptor block the host DMAs in. The map therefore does
not grow with geometry, so `ROWS_IF` can change later without touching the
driver; it unifies with subsystem D, which already fetches descriptors through
`rtl/seq_desc_fetch.vhd`; and the 3.27 GB/s H2C path that delivers the
descriptor is already proven on silicon.

Rejected: a generated fixed map (about 60 registers, reshapes whenever
`ROWS_IF` or `AXI_DW` moves, driver and bitstream must be version-locked), and
an indexed window (81 stateful writes at 1 to 2 us per PCIe round trip, and the
existing header's "a map no driver could parse" objection applies to it most
strongly).

**Which branch fired.** The first one: bit-exact through the new control path
at `MAXB=16`. Format at `docs/2026-08-28_matvec-descriptor-format.md`, RTL at
`rtl/matvec_int4_desc_axi.vhd`, bench at `sim/tb_matvec_fk33_desc.vhd`.
**Next, per the pre-written step: the shell integration** -- `gen_pcieep.py`
enabling the HBM ports AND `llama_top` instantiated, the first build that could
put arithmetic on the card.

**The other three branches, answered:**

- The descriptor format did NOT collide with D. It IS D's: D's 64-byte header,
  D's base array at `0x40`, and a four-word A extension placed AFTER the base
  array -- the one region `seq_desc_fetch` never reads. A descriptor written to
  A's spec is still a valid D descriptor. What D's header genuinely cannot
  carry (`w_beats`, `s_beats`, `x_exp`) is what went into the extension, and
  why is written down.
- The CDC closed. `rtl/async_fifo.vhd` + `DUAL_CLK` on `axi_rd_port`, per-port,
  `DEPTH = 256` beats at `AXI_DW = 256` (8 KB/port, spec 7.7's budget, and
  exactly `MAXOUT*MAXB = 256` in-flight beats). Bit-exact at four AXI/core
  ratios including a non-integer one.
- **Two mutations pass without an error, and both are reported as defects
  rather than as test gaps.** See OI-1 below. Neither is a silent wrong answer
  presented as success in the way OI-3's are: one is wrong output with no way
  to know, the other is a hang.

---

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

### OI-10: `matvec_core:779` writes `ybuf` past the end in `out_mode = "01"`

Found by TRACK RANGE while fixing OI-8, **not reproduced and not fixed**, and
it is the same family as the one it was fixing.

`:779` writes `ybuf(re2_t)` whenever `out_mode /= "10"`, but `S_IDLE` bounds
`n_rows` against `MAXROWS_BFP` **only when `out_mode = "00"`**. So `out_mode =
"01"` can write past `TILES-1` on exactly the argument that produced OI-8, where
the read side did the same thing.

**Not reproduced because no bench drives that mode.** That is the finding as much
as the code is: `out_mode` 1 and 2 descriptors are byte-checked by
`tools/verify_mv4i_desc.py` and **never run**. A mode nothing exercises is a mode
whose bounds nobody has tested, and OI-8 showed what that costs.

Closing this needs a bench that drives `out_mode = "01"` first. Fixing the
bound without a bench that reaches it would repeat the mistake that made OI-8
survive: a guard nobody has watched fail.

### OI-11: the FK33 shape sweep scores a HANG as an acceptance

Pre-existing, found by TRACK RANGE while lifting the sweep ceilings, not
introduced by that work.

The FK33 arm of `sim/tb_matvec_fk33_desc.vhd` judges a legal shape by checking
`err` after a bounded poll. A shape that **hangs** therefore scores as accepted,
which is the same silent-success shape as OI-3 and case 19.

What actually proved the newly-reachable top-corner shapes completed was
incidental: the OI-8 defect killed the whole process, so the run finishing at
all was the evidence. That is luck, not a check, and it stops being available
now that OI-8 is fixed.

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
| 2 | **FK33 shell integration.** Instantiate subsystem A into `gen_pcieep.py`, enable the HBM ports, build. **This is the first build that could put arithmetic on the card.** Needs the port enable AND a top to connect them to, which is why it was blocked all day. | TRACK SYNTH (need real area/timing first) | `hw/fk33/gen_pcieep.py`, `hw/fk33/*.tcl` |
| 3 | **Multi-token verification at `cur_pos > 0`.** `llama_top` runs ONE token at `cur_pos = 0`, which is exactly why both `attn_block` defects were invisible to it. Until a second token runs, the KV path is unexercised end to end. | items 1 and 2 partially | `sim/tb_llama_top.vhd` |
| 4 | **Token I/O: embedding and LM head.** Still 512-entry / 64-dim stories260K ROMs. The residency map gives the embedding an HBM home and says the lookup path has no owner. Note `MAXROWS_BFP = 17408` means `output.weight` and `token_embd.weight` need 15 descriptor jobs each. | none | `rtl/`(new), `tools/` |
| 5 | **`pl_backend` v2 and the server seam.** `server/llama_server.cpp` is zero-dep C++ and the C tokenizer now links. The seam must move from the AXU3EG's whole-loop-in-hardware to prefill plus decode-returning-logits. | item 4 for a real vocab path | `server/**` |
| 6 | **Subsystem D: the layer-level descriptor program.** One matvec job is emitted and verified; a LAYER needs job sequencing, region routing and the D fields subsystem A does not read. | none (format is settled) | `tools/`, `rtl/seq_*` |
| 7 | **OI-3: the two defect classes `tb_llama_top` cannot see.** An exponent claim re-aimed at R_X and a prefetch consuming at k-3 both change every element and no property can observe either. Needs a property that can. | none | `sim/tb_llama_top.vhd` |
| 8 | **`gdn_recur` and `gdn_exp_capture` mutation coverage**, plus the open `d_m` grid defect behind the 8.955 LSB worst case. | TRACK B-MUT (avoid overlap) | `sim/tb_gdn_recur.vhd`, `sim/mutate_*` |
| 9 | **Subsystem C spec reconciliation.** Six spec-named units (`attn_lane`, `attn_score_tree`, `attn_acc`, `attn_qk_norm`, `attn_ctrl`, and `attn_kv_axi` until C-KV lands) do not exist; the design took a different decomposition and the spec was never updated. The spec and the RTL now disagree. | TRACK C-KV | `docs/` spec files |
| 10 | **OI-9: the descriptor error-code space is full.** A decision (widen, subdivide via `ERR_INFO`, or take a reserved D value), with consequences for D. **Ask Oren rather than choosing.** | none | decision |
| 11 | **The five B units with no accuracy gate `regress.sh` can fail.** `gdn_silu` and `rmsnorm_bf` PRINT their oracle figures from the generator; `gdn_head_emit`, `gdn_y_emit` and `gdn_emit_chain` assert inside a generator the gate never runs, because their vectors are committed. The flagship: the `rmsnorm_bf` mutation reintroducing exactly the defect that unit exists to fix is bit-exact-green and 1.7e10 output LSB wrong. Two routes, scoped in section 7 of `docs/debugging/2026-08-29_b-verification-defects-d1-d3.md`, and they are NOT equivalent: Route A adds a `tb_vector_args` row per unit so the gate regenerates and consults the generator's exit code (cheap, also kills the D1 staleness class for good, but moves the claim out of the bench so it cannot see an RTL-only accuracy defect); Route B moves the gate into the bench, as `tb_gdn_scalar` now does (~60 lines per unit plus a measurement pass). **Do `gdn_silu` and `rmsnorm_bf` first**: the other three have oracle blind spots that must be answered before a tolerance means anything -- head_emit/y_emit exclude on an OUTPUT property and EMPTY their oracle at a narrowed rail (41 saturating + 7 all-zero = 48 of 48), and emit_chain's metric is normalised by the very quantity one BOTH mutation changes, so it moved the WRONG WAY (1.1280 -> 0.8505). | TRACK B-FIX (landed) | `sim/tb_gdn_silu.vhd`, `sim/tb_rmsnorm_bf.vhd`, then the other three |

