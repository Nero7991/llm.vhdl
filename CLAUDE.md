# CLAUDE.md -- llama.vhdl

Qwen3.5-9B inference in VHDL on an SQRL FK33 (`xcvu33p-fsvh2104-2L-e`, 8 GiB
HBM, PCIe Gen3 x4). Subsystems: **A** INT4 streaming matvec, **B** Gated
DeltaNet, **C** gated attention, **D** transformer sequencer, **E** TP
collective (out of scope at `NCARDS = 1`).

**`docs/WORKLOG.md` is the live board.** Read it at the start of every session.
It holds what is in flight, who owns which file, the backlog, and the open
issues. This file holds only what must survive a context compaction.

---

## THE REFILL RULE

**Standing instruction from Oren: parallel agent slots must not go empty while
the backlog is non-empty. This runs overnight.**

**Every time an agent completes, check `docs/WORKLOG.md`'s BACKLOG and dispatch
the next ready item BEFORE writing the report.** Closing a track and refilling
its slot are one action, not two.

This is not theoretical. Five tracks landed in one day and each was written up
carefully while every slot sat idle; Oren noticed, not me. **Writing a good
report is exactly the activity that feels like progress while the machine does
nothing.**

Target **four concurrent tracks**. An item is READY when its file ownership
does not collide with a running track and its dependency has landed. If nothing
is ready, say so explicitly rather than quietly running one agent, and look at
what the last few results newly unblocked, because most landings open something.

---

## THE HARDWARE BOUNDARY (safety, not preference)

**Subagents get NO hardware access. Ever.** Never `xsdb`, `hw_server`,
`vivado ... program`, `hw/fk33/pcieep.sh`, `hw/fk33/jtag.sh`,
`hw/fk33/flash.sh`, `hw/fk33/tcl/program.tcl`, or anything opening
`/dev/xdma*`. Put this in every agent brief.

An agent destroyed the card's SQRL factory flash image by crossing this line.
Vivado in non-hardware modes (synth, `report_*`) is fine.

**Never take VCCINT to 0.85 V.** Stay at wiper 68 (~0.717 V). The vendor script
does otherwise; it is wrong for this board.

---

## TRAPS THAT HAVE ALREADY COST REAL TIME

**Which git form is safe DEPENDS ON WHO OWNS THE FILE, and the two cases want
opposite commands.** Getting this backwards has now cost tracks in both
directions on the same day.

*Shared file.* `git commit -m msg -- <path>` commits the WORKING TREE, not the
index, so on a shared file it silently captures another track's in-flight edits.
It caught FOUR tracks in one day. So: `git diff -- <file>` as its own step, read
it, stage your hunk, commit with **NO pathspec**.

*File your track exclusively owns.* The pathspec form is the **SAFER** one while
other agents are running, because it does not go through the index at all.
**The index is shared mutable state and there is no atomic read-then-commit
through it.** Measured 2026-08-29: a track ran `git add` on only its own paths,
then ran `git diff --cached --name-only` as a separate gating step exactly as
prescribed. The gate FIRED, showing twelve paths of which six were foreign --
and before it could act, another track committed and a pathspec-free commit took
the whole index. Six of that track's documents landed under a message describing
someone else's work. Nothing was lost, and it was recorded rather than amended,
because amending rewrites another track's tip and re-runs the race.

So "run the check" is not the lesson here; the check ran and was correct. A
check whose result you do not branch on is decoration, but a check you cannot
act on atomically is not a guarantee either. An amend only works while your
commit is still the tip. Never `git add -A` or `git add .`.

**GHDL here is the mcode backend.** `ghdl -e` produces no binary and silently
succeeds; run `ghdl -r`. `ghdl -m` can return rc=0 while printing hard errors.

**Never `ghdl -i rtl/*.vhd sim/*.vhd tb/*.vhd` into one library.** Duplicate
entity names across `sim/` and `tb/`, `rope_ps` twice, and `sim/post_*.vhd` plus
`library beh` benches need xsim/UNISIM. Use
`REGRESS_SCRATCH=<dir> bash sim/regress.sh --only <pat> --keep`.

**`regress.sh --only` takes a SUBSTRING, not a regex.** `--only 'a|b'` matches
nothing and still prints `REGRESSION: PASS`. The only tell is `PASS 0`. Always
read the `OVERALL PASS n` line.

**A full-gate run showing many failures in files you cannot have touched is
MACHINE CONTENTION** from a concurrent agent, not your change. Re-run on a quiet
box before believing it.

**A new `sim/tb_*.vhd` becomes a gate row whether you meant it or not**
(auto-discovered). Vectors defaulting to a nonexistent file turn the shared gate
red for every track.

**The FK33's HBM slave is AXI3: `ARLEN` is 4 bits, so 16 beats is the hard burst
cap**, not the 128 that AXI4's 4 KB rule allows. A module's own assert bounds
what THAT MODULE permits and says nothing about what the slave accepts.

**Vivado silently ignores `assert ... severity failure` in synthesis**; use an
out-of-range `natural` constant. Its XDC reader forbids `if`, skipping the block
with only a CRITICAL WARNING. Reading a block-design `CONFIG.*` reads a REQUEST,
not an answer.

**Never `pkill -f <pattern>`, and never `pgrep -f` on a pattern that appears in
your own command line.** This has killed the shell four times in this project.

---

## VERIFICATION DISCIPLINE

This is the through-line of everything that has gone wrong here.

**Structure is not values.** In one day: `attn_block` passed seven properties
and 13 of 17 wiring mutations while computing wrong numbers; the shipping
recurrence was checked only for equality with another unit's recipe; `l2norm_rs`
had a tolerance and no model; the tokenizer was verified over 53,411 strings and
1.1M codepoints and was still wrong on 243 token ids. **Every one was found by
an oracle comparing numbers against an independent implementation, and none by
any amount of additional structural checking.**

- **A per-unit evidence class says nothing about the composition.** A column of
  well-verified units and a green integration test are jointly compatible with a
  block that computes wrong numbers. Ask whether an oracle exists at the level
  of the thing's OUTPUT.
- **A round trip is not an oracle.** Self-consistency passes for a
  wrong-but-consistent implementation. The `m7 mutant` is the recorded case: a
  packer plus a reversed decoder passed an entire self-test suite.
- **Teeth-check everything.** A checker never shown to fail has not been shown
  to work. **Report mutations that do NOT bite** under their own names: they
  measure your check's resolution floor and are the most valuable line in the
  table. Never discard one.
- **Coverage of the input space is not coverage of the output space.** Ask what
  the generated inputs cannot reach, and enumerate it separately.
- **Where a document and the RTL disagree, the RTL wins.** That includes the
  specs, the audit, and this file.

Write a dated `docs/debugging/YYYY-MM-DD_<slug>.md` at the moment something is
root-caused, not at the end. Required sections in order: the question verbatim;
the answer up front; the procedure; the evidence as raw output; **"Measured and
REJECTED -- do not retry"**; measurement traps hit; corrections appended in
place, never deleted.

Label claims **MEASURED** (a tool ran, name it), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement, state the assumption).

---

## HOUSE STYLE

No emojis. No em-dashes. Never add a Co-Authored-By line to a commit.
Use the session scratchpad, not `/tmp`.
