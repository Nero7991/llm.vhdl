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

## THE MEMORY BUDGET IS GLOBAL, AND ONLY THE DISPATCHER CAN SEE IT

**The box has 31 GiB and `llama-server` permanently holds 18 of them.**
Everything this project does shares the remaining ~13 GiB: every Vivado, every
GHDL, every track at once.

**MEASURED 2026-08-30 01:25: the box died.** Not an OOM kill, which is
survivable and contained. `kcompactd0` stuck for 75 s, RCU stalls, soft lockups
on nine CPUs including `llama-server` and five separate `bash` processes, and
the kernel could no longer make enough progress to kill anything. Oren had to
hold the power button. **The FPGA lost its configuration when slot power was
cut**, so the card had to be reprogrammed, and a composed place-and-route that
had been running for over ninety minutes was lost.

At the moment of dispatch the dispatcher had measured `0 free, 21 GiB swap in
use, load 10.1`, six Vivado processes and `llama-server` at 18 GiB -- **wrote
those numbers into the briefs of two new tracks as a warning -- and dispatched
them anyway.**

**Telling each agent to check `free -g` first does not create a budget.** Every
agent checks. Every agent finds what it needs. Each is individually correct and
the sum kills the machine. **An agent can only see its own footprint; the
dispatcher is the only one who can see the total, so the dispatcher owns it.**

The rules that follow from this:

- **Count the memory before dispatching, not after.** State the budget out loud:
  what is already resident, what the new track will peak at, and what is left.
  If that arithmetic is not written down, it was not done.
- **ONE Vivado at a time. Not one per track -- one on the box.** MEASURED
  peaks: full `pcieep` build 25.0 GiB, composed place-and-route several GiB,
  and a single OOC synthesis 11.9 GiB. Two of anything in that list does not
  fit beside `llama-server`.
- **`pgrep -x vivado` OVER-REPORTS, and counting its output is wrong.**
  MEASURED 2026-08-30: one running Vivado shows as **four** processes, because
  the launcher is a chain of bash scripts also called `vivado`
  (`bin/vivado` -> `bin/loader` -> `bin/unwrapped/lnx64.o/vivado`), and three of
  them are shells holding ~3 MB each. **But filtering on the unwrapped path is
  ALSO not a count of one tool**: MEASURED on the BC-250 the same day, a single
  Vivado shows **five** matches on `bin/unwrapped/lnx64.o/vivado`, because
  Vivado forks **parallel-synthesis workers that inherit the parent's argv** --
  four at 2.36 GB each plus a 1.41 GB parent. **Gate on PRESENCE, never on a
  count, by any pattern.** For the real footprint, SUM the RSS:
  `ps -eo rss,args | grep unwrapped/lnx64.o/vivado | awk '{s+=$1} END {print s/1048576" GB"}'`.
- **One Vivado costs 10.85 GB of the BC-250's 14 GB** (MEASURED 2026-08-30,
  `attn_block` OOC with forked workers). So the second lane holds exactly one
  tool and has ~3 GB of margin, not the comfortable headroom the 14 GB figure
  suggests. **Two concurrent tools there OOM the box rather than merely slowing
  it.**
  (`pgrep -x` is still the right form -- **never `pgrep -f`**, which matches
  your own command line and has killed the shell four times here.)
- **A full build requires stopping `llama-server` first**, because 25.0 GiB does
  not fit in 13. That is a deliberate act with a user-visible cost, so it is
  Oren's call, not a track's.
- **`ghdl-mcode` is not free.** MEASURED the same day: 20.9 GiB anon-RSS in a
  single process, OOM-killed twice at 16:48. It was contained only because
  `claude-tmux --mem` put it in a cgroup. Uncontained, it is a box-killer.
- **THE REFILL RULE DOES NOT OVERRIDE THIS.** "Four concurrent tracks" is a
  target for keeping the backlog moving, not a licence to exceed the machine.
  **Four tracks that hang the box complete zero work and destroy the work
  already running.** When memory is the binding constraint, say so explicitly
  and run fewer -- that is the rule being followed, not broken.
- **Swap in use is the leading indicator, not free RAM.** By the time `free`
  shows 0 free the box is already living on the swapfile, and the failure that
  follows is compaction thrashing rather than a clean kill.

### AND THERE IS A SECOND MACHINE. USE IT.

**`labuser@192.0.2.200` (`cachyos-bc250`) exists for exactly this and was
never touched.** On the night the workstation died it was **up 3 days, load
0.07, 13 of 14 GB free**, with Vivado 2023.2 at
`/tools/Xilinx/2023.2/Vivado/2023.2` and a node-locked licence at
`~/.Xilinx/Xilinx-4.lic` covering VU33P. Not one track that night mentioned it.

It was provisioned in August specifically to keep FPGA synthesis off this
workstation after an earlier OOM incident, and then the whole overnight run
put six Vivado processes on the workstation instead.

- **Sync first, every time:** `bash ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh`.
  It rsyncs the ~1,829 git-TRACKED files only (21 MB, not the 4.8 GB working
  tree), has no `--delete`, and copies nothing back, so a sweep there cannot
  clobber anything here. Destination is `/home/orencollaco/GitHub/llama.vhdl`
  on that box, **not** `/home/labuser/...`, because two `sim/*.tcl` hardcode
  the absolute path.
- **What it is FOR: OOC unit synthesis and area sweeps.** Results are
  **bit-identical** to the workstation (DSP/LUT/FF/BRAM/WNS/Fmax match to 13
  significant figures), so a number measured there is quotable here.
- **What it is NOT for:** it has **15.2 GB unified** memory. A full `pcieep`
  build peaks at 25.0 GiB and does not fit; a full `engine_shared` OOC peaks
  23.8 GB and does not fit either. **Check the peak against 14 GB before
  sending anything.**
- **It is 2.3x slower** end to end, MEASURED on identical ZU3EG synthesis. A
  2 h workstation sweep is ~4.5 h there. **That is still infinitely faster than
  a sweep that hangs the box and loses ninety minutes of place-and-route.**
- **Its shell is fish**, so wrap remote commands in `bash -c "..."`.
- It is deliberately on no WoL watchdog, so if it is off, it is off.

**The rule, from Oren 2026-08-30: USE BOTH. They are two lanes, not a primary
and a fallback.**

- **One Vivado on the workstation AND one on the BC-250, concurrently.** That is
  two synthesis lanes with neither box over its budget, and roughly double the
  throughput -- which is the whole point of having provisioned the second
  machine.
- **"ONE Vivado at a time" above means one PER BOX, not one in total.** Two on
  either box is what does the damage; one on each is free.
- **Big job here, small job there.** The workstation has ~13 GiB against the
  BC-250's 14 GB but is 2.3x faster, and anything that does not fit in 14 GB
  has to run here by definition.
- **Sync before every BC-250 dispatch.** Its results are bit-identical to this
  box's, so a number measured against a stale tree is indistinguishable from a
  real one. That is the trap the second lane introduces.
- When both lanes are busy, that is the ceiling. **A third Vivado anywhere is
  the mistake that cost a night.**

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

**Never put a shell variable anywhere in a path passed to `rm`.** Not
`rm -rf "$DIR"`, not `rm -rf "$SCRATCH/$x"`, not `rm -rf $TMP/*`. If the
variable is empty or unset, that command deletes from the filesystem root or
the home directory, and nothing here is backed up. Delete only by writing the
full literal path out, one explicit `rm -rf /full/literal/path` per directory,
nothing interpolated, read back before running. If that is tedious, that is
the point.

Oren caught and blocked this on 2026-08-29. The agent that ran it had done so
**ten times**, unquoted, and got away with it every time because `SD` was
assigned on the same command line immediately before each `rm` -- so it never
expanded empty and every target was inside its own scratch. **That is exactly
what makes the habit dangerous rather than exactly what makes it safe.** The
form is indistinguishable from the fatal one at the moment you type it, and it
had already survived long enough to look normal.

The same hazard is not confined to `rm`: that agent also flagged, unprompted,
a `cp "$SD/tree/$f" "$f"` loop overwriting four repo files, with a variable on
**both** sides of the path. Naming it was the right call and is the standard.

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
- **A KILL DOES NOT SETTLE IT. Run the attribution control.** The same mutant
  with your new check DISABLED. Measured 2026-08-29: a track closing OI-3 found
  that in one of four mutant-by-configuration pairs the kill belonged to an
  OLDER property, and without the control its table would have credited the new
  check with four detections instead of three. A check credited with a kill
  that an existing property would have caught anyway is not worth its
  maintenance, and you cannot tell which case you are in without the control.
- **GUARDS THAT PASS FOR THE WRONG REASON are their own defect class.** Four
  found on 2026-08-29 alone: a residency checker that printed PASS over an
  object neither of its two checks ever read (250 in, 249 checked); a
  descriptor base rule that agreed with its cross-check **by coincidence of
  geometry on every file it had ever seen**; three `util_pkg.vhd` copies
  regenerated by a script **nothing schedules**; and gray-coding `G1`, where
  the BROKEN design reports two FEWER `report_cdc` warnings than the correct
  one, so a "must not get worse" rule actively rewards it. The tell is always
  the same: the check has never been shown to discriminate on the thing it
  guards. Ask what it would take for this check to FAIL, and if you cannot
  answer, it is decoration.
- **A ONE-PARAMETER MODEL FITTED TO ONE POINT IS NOT EVIDENCE ABOUT ANY OTHER
  POINT.** MEASURED 2026-08-30: a packing-density model calibrated on a single
  placed design reproduced that design and was used to project a second one. It
  was wrong by **12 percentage points** -- it said a configuration fitted at
  93.2% when the corrected figure is 105.2%, i.e. it does not fit -- and it had
  the **sign** of its own mechanism backwards.
  The author's diagnosis is the reusable part: *"the model's INPUT was sound, so
  the cross-check passed and felt like validation. The model itself was never
  checked against anything -- it reproduced one point because it was calibrated
  on that point. A one-parameter model fitted to one point cannot be wrong
  about that point and cannot be right about any other."*
  It was correctly labelled ESTIMATE with its assumption stated, **and that was
  not enough**, because nobody asked what would falsify it. **Labelling a
  number ESTIMATE discharges honesty, not verification.** When a model has as
  many free parameters as calibration points, it has been fitted, not tested.
  The fix that worked was to derive the quantity from a census instead:
  `CLB = F7/4 + (LUT - 2*F7)/D` predicts 54,846 against a measured 54,866.
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
