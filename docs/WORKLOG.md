# Parallel worklog

A live board, not a report. One section per track that is in flight, the files
each track owns so two agents cannot collide, and **the next step written down
BEFORE the result arrives**, branched by what the result could be.

Why the branches are pre-written: deciding what to do next while holding a
fresh result is how scope drifts and how a negative result gets talked into
being a positive one. If the branch was written before the answer was known,
the answer only has to be classified, not argued with.

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

**`git commit -m msg -- <paths>` COMMITS THE WORKING TREE, NOT THE INDEX.**
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
| Magnitude blocker | Explosion was the STIMULUS (synthetic row norm 2^4.87 vs real 2^-0.03). PART 5 withdrawn, PART 3 reinstated. `attn_block` wired behind `C_REAL`. | `3246046` |
