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
  **CORRECTION 2026-09-04: THE 25.0 GiB FIGURE DID NOT REPRODUCE.** A full
  `hw/fk33/pcieep_build.sh` that ran to a bitstream with 0 errors peaked at
  **10.66 GB** (Vivado's own `Memory (MB): peak` at the largest phase; RSS
  sampled via `/proc/PID/exe` agreed at 9.98 GB), and `free physical` never
  went below 14,440 MB. See
  `docs/debugging/2026-09-04_first-pcieep-bitstream.md`. **Do not quote 25.0
  GiB for this script again without re-measuring it**, and in particular do not
  use it to refuse to run the build -- the refusal is the expensive error, and
  this build had been unrun for weeks partly on that number. The 25.0 GiB may
  belong to a different configuration; it has never been re-derived.
  What does NOT change: the peak is a property of the JOB, one observation is
  not the peak, and the thing that made running it safe was the
  `systemd-run -p MemoryHigh=26G` cap, not the sample.
- **A composed `route_design` left `free physical = 233 MB` while ALONE on the
  box** (MEASURED 2026-08-30, TRACK TIMING). Six of those were running
  concurrently when the box hung. **A tool that leaves 233 MB when it is the
  only thing running has no safe multiplicity at all** -- the correct
  concurrency was never "two, carefully", it was one. And no amount of checking
  `free` before starting reveals this, because the number only exists at peak.
  **Peak is a property of the job, not of the moment you looked.**
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
  **NOT the argv form.** `ps -eo rss,args | grep unwrapped/lnx64.o/vivado`
  OVER-COUNTS by matching any process that merely CARRIES that text in its own
  command line. MEASURED 2026-08-30 on this box: with five real Vivado workers
  running, the same filter also matched **four `bash` processes and a `ugrep`**,
  adding ~18 MB of phantom Vivado; and with ZERO Vivados running, TRACK NORMURAM
  measured 3,532 KiB of "Vivado" and **sat in a sleep loop for ELEVEN MINUTES
  against a lane that was already free**. **The `[u]nwrapped` bracket trick does
  NOT save you here** -- the bracket only stops the filter matching its OWN
  argv, and the text that matched belonged to SIBLING processes. This is the
  `pgrep -f` self-match trap generalised, and it is silent: it looks exactly
  like a busy lane, so it costs time rather than raising an error.

  **Read `/proc/PID/exe`, which a command line cannot spoof, and sum `VmRSS`:**

  ```bash
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    e=$(readlink /proc/$p/exe 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*)
      awk -v p=$p '/VmRSS/{s+=$2} END{print s}' /proc/$p/status;; esac
  done | awk '{s+=$1} END {printf "%.2f GB\n", s/1048576}'
  ```

  Better still where the job is yours: take the cgroup's own `memory.peak`
  rather than any sampled `free` or `ps`, because peak is a property of the job
  and a sample only sees the moment you looked.

  **BUT A CAPPED JOB'S `memory.peak` IS THE CAP, NOT THE PEAK, and these two
  pieces of advice interact.** MEASURED 2026-08-30 by TRACK NORMURAM: a
  five-point batch run under `MemoryHigh=13G` reported `memory.peak` **1.1 MB
  above 13 GiB**. That is not the job's appetite, it is the throttle holding it
  there -- `MemoryHigh` forces reclaim rather than failing, so RSS sits at the
  cap and `memory.peak` records the cap. **The only honest unthrottled figure in
  that batch was the one point that never reached its cap, at 10.54 GiB.**

  So: cap for SAFETY, and read `memory.peak` for SIZE only from a run that did
  not reach its cap. A capped `memory.peak` tells you nothing except that the
  cap worked, and quoting it as a footprint over-states small jobs and
  under-states large ones by exactly the amount you needed to know.
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
- **`ghdl-mcode` is not free, BUT THE 20.9 GiB FIGURE IS NOT THE GATE.**
  MEASURED: 20.9 GiB anon-RSS in a single process, OOM-killed twice, contained
  only because `claude-tmux --mem` put it in a cgroup. **That figure belongs to
  ONE bench, not to a regression run, and it has never been attributed to a
  named row.** MEASURED 2026-08-30 by TRACK GATEGREEN: **the FULL both-suite
  gate at `--jobs 1` peaks at 2.13 GiB** (cgroup `memory.peak`, well under its
  8G cap so it is a real peak and not the cap), running beside a 7-10.6 GiB
  Vivado `place_design` with `MemAvailable` never below 19 GiB. **`--jobs 2` is
  fine; preferring 1 is politeness, not safety.** Do not provision the whole
  dispatch budget against 20.9 GiB, as this dispatcher did all night -- **pin
  which bench actually reaches it before quoting it again.**
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

**VIVADO'S INFERENCE LOG LIES IN BOTH DIRECTIONS. Only the mapping report and
the primitive census are authoritative.** Two MEASURED cases, one each way, on
the same day:

- **It claims a resource the design never gets.** `[Synth 8-10226]`: the URAM
  request "can not be honored", and the run reports `uram=0` while three
  documents quoted "114 URAM" that was really the BRAM column.
- **It denies a resource the design DID get.** `[Synth 8-7186]`: `Applying
  attribute ram_style = "distributed" is ignored, object 'cb[0][0]' is not
  inferred as ram due to incorrect usage`, printed one hundred times -- and
  **every object it names is a `RAM32M16` in the same run's mapping report.**

So a warning saying an inference failed is not evidence that it failed, and a
message saying one succeeded is not evidence that it succeeded. **Cross-check
`report_utilization` against an object-level `get_cells` census, and when they
disagree the census wins.** The cheap discriminator is
`get_cells -hier -filter {REF_NAME =~ RAM*}` next to the LUT-as-memory row: if a
run reports `RAM=0 FF=1024` you have registers, and `RAM=4352 FF=0` you have
distributed RAM, whatever the log said about either.

**URAM CANNOT HOLD A CONSTANT TABLE ON THIS DEVICE, and asking anyway gets you
BRAM with only a WARNING.** MEASURED, Vivado's own words in TRACK NWROM's log:
`[Synth 8-10226] The ram_style = ultra set on ROM ... can not be honored for
this device. The URAM primitives on this device do not support initializations
to any non 0 values. This ROM will be implemented using BRAMs`. The run then
reports `uram=0`. **So "320 idle URAM288" is real and unusable for any
initialised table** -- URAM is available only to a store written at run time,
which means the HBM route, not a ROM. Three separate briefs carried "114 URAM"
for the norm gain image; that 114 was the **`bram` column** of a run whose URAM
request had been refused. Charge such levers in BRAM (672 tiles on this part),
and prefer `rom_style = "block"` explicitly so the log does not carry a WARNING
claiming a resource the design never gets.

**The FK33's HBM slave is AXI3: `ARLEN` is 4 bits, so 16 beats is the hard burst
cap**, not the 128 that AXI4's 4 KB rule allows. A module's own assert bounds
what THAT MODULE permits and says nothing about what the slave accepts.

**Vivado silently ignores `assert ... severity failure` in synthesis**; use an
out-of-range `natural` constant. Its XDC reader forbids `if`, skipping the block
with only a CRITICAL WARNING. Reading a block-design `CONFIG.*` reads a REQUEST,
not an answer.

**A BLOCK-DESIGN CELL'S PORTS ARE NOT VHDL PORTS, AND THE TWO RULES ARRIVE ONE
AT A TIME.** MEASURED 2026-09-03, `hw/fk33/pcieep_build.sh --bd-only` against
`rtl/fk33_seam.vhd`:

- **`natural` is not a port type.** `[IP_Flow 19-734] Port type 'natural' is
  not recognized. Only std_logic and std_logic_vector types are allowed`, then
  `19-4668 Failed to infer definition` and `BD 41-1699 Unable to add reference
  type cell`. Perfectly legal VHDL that elaborates and simulates.
- **A port WIDTH is an XPath expression over the generics, evaluated by the
  packager, NOT by VHDL.** So the obvious fix fails differently:
  `[IP_Flow 19-627] Unsupported function call "clog2" in the expression`. It
  can reference a generic and do arithmetic on it; **no function of a generic
  is admissible however trivially it evaluates.** This error is invisible until
  `19-734` is gone.

The fix is to carry the width as its OWN generic (`HREG_W : positive := 4`)
and size the port `std_logic_vector(HREG_W-1 downto 0)`. **A generic that must
agree with a derived value is a new way to be silently wrong**, so pin it
TWO-SIDED with the out-of-range-`natural` idiom -- `HREG_W - clog2(NREG)` AND
`clog2(NREG) - HREG_W` -- because a one-sided check lets a too-WIDE port
through.

**Neither error is reachable by any bench**, so no amount of simulation finds
them. `--bd-only` costs 3 minutes and 3.4 GB and finds everything that is not a
timing or placement result; nothing schedules it, which is why the build had
been dead since `3a145fd` with nobody aware.

**AND A SENTINEL GREP MUST BE LINE-ANCHORED, BECAUSE THE LOG CONTAINS THE
SCRIPT THAT WRITES IT.** MEASURED 2026-09-03, twice in a row on the same job:
`sim/ooc_compose4_pnr.tcl` echoes its own source into its log, so the log holds
`#     puts "C4_DONE synth $tag"` and `#  error "C4 FAIL: ..."` from the moment
it starts. An unanchored `grep -qE 'C4_DONE synth|C4 FAIL:'` therefore matched
the SCRIPT'S OWN TEXT and the waiter reported a finished synthesis seconds
after launch, both times, while `synth_design` was still fetching its licence.
Use `grep -qE '^(C4_DONE|ERROR:)'`, and confirm with a count of the anchored
pattern before believing any waiter.

**This is the `pgrep -f` self-match trap again, in a third place.** First it was
a process matching its own command line, then a `/proc` loop matching the
script text that was searching for it, now a log grep matching the source
embedded in the log. **Whenever you search a haystack that can contain your own
needle, anchor the match or pick a needle the haystack cannot hold.**

**A COMPLETION SIGNAL THAT ALSO FIRES ON FAILURE IS NOT A COMPLETION SIGNAL.**
MEASURED 2026-08-30: a waiter armed on a `systemd` unit reported **"completed"
when the unit was KILLED**, not only when it succeeded, and announced a
finished job a minute after that job was deliberately stopped. **Gate on a
sentinel the work itself writes into its log, never on the waiter firing.**
Same shape as `wait_on_run -timeout`, which returns rc 0 on expiry without
raising, and as a Vivado run that prints full success and then dies on a Tcl
error afterwards. In all three the harness is reporting that it finished
waiting, which is a fact about the harness and not about the job.

**Never `pkill -f <pattern>`, and never `pgrep -f` on a pattern that appears in
your own command line.** This has killed the shell FIVE times in this project,
most recently 2026-09-03 -- and that fifth time was not `pgrep` at all. It was a
hand-rolled `/proc` loop matching `cmdline` against a scratch-directory name,
which matched the running shell because the SCRIPT TEXT contained that name.
**The hazard is matching on a command line, not the particular tool that reads
it.** `ps`, `pgrep -f`, and your own `/proc` loop are the same mistake, and the
`[b]racket` trick does not save you: the bracket only stops a pattern matching
its own argv, and here the text belonged to the shell that was interpreting it.

**Identify a process by `/proc/PID/exe` or `/proc/PID/cwd`, which a command line
cannot spoof.** That is the same rule the Vivado RSS census above already
states, generalised: whenever the question is "is this process the thing I
mean", the answer comes from the kernel's view of what it is running or where
it is running, never from the string it was invoked with.

**`git commit -m` with a long message dies with `Argument list too long`.**
Write the message to a file in the scratchpad and use `git commit -F <file>`.
This is not a heredoc quoting problem and no amount of re-quoting fixes it.

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

**BEFORE WRITING A MODULE, GREP THE ENTITY DECLARATIONS FOR THE SHAPE YOU ARE
ABOUT TO BUILD, NOT FOR THE WORDS A DOCUMENT USED.** A null grep for one
spelling is not evidence about the design. MEASURED, twice in one day
(2026-09-03):

- A track searched for `a_job_index`, found it in three DOCUMENTS and in no
  `.vhd`, and concluded nothing sourced A's descriptor address. The RTL port is
  **`u_index`**, `rtl/a_desc_adapter.vhd` had owned the whole job since
  2026-09-02, and the word the documents used is a signal name in a GENERATED
  top. It then wrote `rtl/a_desc_ptr.vhd`, which reimplemented that file's
  address arithmetic, its `N_JOBS` bound check and its stride refusal, and
  committed it. **The area census measured the duplication: 20 LUT / 50 FF /
  4 CARRY against the replacement's 11 FF / 0 CARRY**, and those four CARRYs
  were the adder `a_desc_adapter:213` already had.
- Earlier the same day the same track claimed A's weight fetcher did not exist.
  It does -- `matvec_int4_desc_axi`'s `gen_wb` -- and `llama_top` merely
  bypasses it.

The rule already written here, *a "not done HERE" comment is a statement about
ITS FILE*, did not prevent either. The operational form is the one above:
search for a **port of that width** or a **generic of that name**, and read the
entity, not the prose. `hw/fk33/gen_*.py` are part of the RTL surface -- a
grep over `*.vhd` alone cannot see a generated port.

**MANY OF THIS PROJECT'S `.vhd` FILES ARE GENERATED. CHECK LINE 2 BEFORE
EDITING ANY OF THEM.** `hw/fk33/rtl/fk33_engine.vhd` and
`hw/fk33/rtl/compose4_top.vhd` both open with *"GENERATED by ... DO NOT
HAND-EDIT; edit the generator."* MEASURED 2026-09-03: a track hand-edited
`fk33_engine.vhd` to add a port, and the edit would have vanished at the next
`python3 hw/fk33/gen_fk33_engine.py`, taking the port with it and breaking a
composed top that had elaborated cleanly, with nothing to point at the cause.
Edit the generator, regenerate, then `git diff` the output and confirm it
contains your change and nothing else.

**BEFORE CONNECTING A SIGNAL, READ THE DRIVER'S STATED CONTRACT FOR IT, NOT THE
SHAPE YOU EXPECT -- AND WHERE THEY DIFFER, TAKE THE WEAKER ONE**, because that
is the one the other end is allowed to produce. MEASURED 2026-09-03:
`rtl/seq_desc_fetch.vhd:166` says *"`go` is a level or a pulse; it is only read
in S_IDLE."* D can read a level because it leaves S_IDLE on the same edge. A
new counter wired to it reloaded on the LEVEL, so a host holding `go` high
would have pinned it at zero and **every A job of that token would have fetched
descriptor 0** -- a well-formed descriptor for the wrong step. The module had
already been verified and mutation-tested; the defect was in the assumed
contract, and it was written down in the driver's own header the whole time.
The fix cost one flip-flop (10 -> 11) and made the module unbreakable by a
caller behaving correctly.

**AND EDITING `regress.sh` ITSELF MID-RUN IS WORSE THAN EDITING A BENCH: IT CAN
CORRUPT THE RUNNER.** Bash executes a script by byte offset -- it parses one
compound command, runs it, then SEEKS BACK to the stored offset. Inserting
lines ahead of that offset shifts every byte after them, so when the main loop
finishes bash resumes mid-line and executes garbage. MEASURED 2026-09-03: ~20
comment lines (~1.1 KB) were added to `sim/regress.sh` at line 437 while a gate
was 96 rows into its main loop. **The damage would have landed in the TAIL --
the summary and the BASELINE check -- which is precisely the part whose verdict
you were waiting for**, and nothing in the log up to that point looks wrong.
The run was stopped and re-run rather than trusted. **Make every edit BEFORE
starting a gate, and if you touch the runner while one is live, that run is
dead: stop it, do not read its verdict.** A comment-only edit is not exempt;
bash counts bytes, not meaning.

**A GATE RUN THAT OVERLAPPED AN EDIT PROVES NOTHING ABOUT EITHER VERSION.**
`regress.sh` compiles from the repo per row. MEASURED 2026-09-03: three rows
sharing ONE bench body reported `FAIL 3`, `FAIL 1` and `PASS 1` in the same
run, because the file changed underneath it. Only a run started after the last
edit counts, and the output looks like an ordinary mixed result rather than a
corrupted measurement.

**NAME SCRATCH DIRECTORIES PER RUN, AND USE `ls -la` WHEN A RESULT LOOKS
SUSPICIOUSLY COMPLETE.** MEASURED 2026-09-03: `ls` on a gate's scratch returned
~230 row directories covering every bench in the project. It was a directory
from a PREVIOUS SESSION and the gate that should have written it had not
started. The only tell was that the two new rows were missing; had they been
named something that already existed, nothing would have looked wrong.

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
- **A TEETH TEST WHOSE MUTANT IS BUILT FROM THE SAME MISCONCEPTION AS THE CHECK
  CANNOT DETECT THAT MISCONCEPTION.** MEASURED 2026-09-03. `gen_pcieep.py`'s
  D-presence guard matched `\bllama_top\b` anywhere, so a COMMENT satisfied
  it, and the pcieep build had been dead since 3a145fd. Its own selftest,
  `seam_tieoff_teeth()`, constructed the state "subsystem D is present" as
  `with_d = no_d + "  -- u_top : entity work.llama_top"` -- **also a comment.**
  Check and mutant were wrong in the same direction, so all four rows agreed
  with each other and `sim:runguard` passed GREEN every day the build was
  dead. It went red only when the detector was FIXED, i.e. the failure was the
  selftest catching up.
  **Construct the mutant from the THING, never from the check's notion of it.**
  A real instantiation, not the string the detector happens to look for.
  The attribution control then showed how little the existing rows were worth:
  with the pre-fix detector, S1-S4 all give the CORRECT verdict and only the
  two NEW rows (a comment-only reference, both with and without the tie-off)
  disagree. **Four rows were insensitive to the defect in both directions.**
  Same shape as the `check_bd_ports.py` first draft an hour later, which
  trusted Vivado's error TEXT ("Only std_logic and std_logic_vector are
  allowed") and reported 11 failures against RTL that demonstrably builds --
  `signed`/`unsigned` are accepted, MEASURED by a passing `--bd-only` whose
  packager named only the `natural` ports. **When a check and the thing it
  checks disagree, re-run the check against a state you have MEASURED, before
  believing either.**
- **A BUFFERED LOG'S LINE COUNT IS NOT A PROGRESS SIGNAL.** MEASURED
  2026-09-03: a full gate under `nohup ... > log` sat at **0 rows for 20
  minutes** while 142 row directories existed in its scratch tree and two
  `ghdl-mcode` processes were live. stdout to a file is block-buffered, so
  per-row lines appear only at the end. Count the scratch ROW DIRECTORIES, or
  read `/proc/PID/cwd` of the running tool, both of which the kernel updates
  immediately. This is the third form of "the harness is reporting a fact
  about the harness": after `wait_on_run -timeout` returning 0 on expiry and a
  waiter firing on a killed unit, now a log that has not been flushed.
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

  **AND THE SEQUEL, MEASURED 2026-08-30 by TRACK LEVERC48: NOT FITTING BEAT
  FITTING, ON THE SAME DATA.** Two models were fitted to three points to project
  lever C's saving at 1,536 lanes. Both were wrong and **the range between them
  did not contain the answer**: linear-in-lanes was -8.59%, log2 was -14.88%,
  and their average was worse than either at -11.73%. The measurement is
  **-42,633 LUT**.

  Drawing three MORE geometries showed why. The per-lane saving is **not
  monotone** -- 29.109, 27.707, 26.051, 25.353, 28.391, 27.756 at
  128/256/512/768/1024/1536 -- it is flat with **plus or minus 6.9% scatter and
  no direction at all**. A **constant** per-lane saving, taken as the mean of
  *the same three points both models were fitted to*, predicts **42,428 against
  42,633: an error of 0.48%.**

  In the author's words, and this is the reusable part: **"a two-parameter fit
  to two points cannot tell scatter from slope, so it read the scatter as a
  slope and extrapolated it."** Fitting a trend to noise does not produce a
  weak trend, it produces a confident wrong one, and adding a second parameter
  makes it worse rather than better.

  **Before fitting anything, plot the residuals and ask whether the quantity has
  a direction at all.** Where a per-unit figure is genuinely structural it holds
  EXACTLY and needs no fit -- LUTRAM per lane and MUXF8 per lane were 8.0000 at
  all six points, and the FF closed form was exact to 0. **A quantity that
  scatters is a mean; a quantity that is structural is a constant; neither is a
  slope.**
- **AN INVARIANCE ARGUMENT IDENTIFIES WHAT A NUMBER IS *NOT*, NEVER WHAT IT
  IS.** MEASURED 2026-09-03: B's extracted data mover reported 5,472 BRAM tiles
  against 672 on the part. A size sweep showed the figure did not move when the
  buffers were quadrupled, so it was not the buffers -- and from "not the
  buffers" this dispatcher concluded "then it is `gdn_block`", wrote it up with
  a table, cross-checked the arithmetic against the project's known 24 MB
  finding, and got AGREEMENT. The attribution was still wrong. `gdn_block`
  alone is **22 tiles**; the array belongs to the enclosing block, one level up.
  The 24 MiB was real and was simply somewhere else.
  **Ruling out one candidate promotes nothing, because there were never only
  two.** An agreeing cross-check does not rescue this: the quantity agreed
  because the quantity was right, which says nothing about the owner. The
  control that settled it cost six minutes and the wrong document was already
  written when it landed.
- **WHEN A REPORT NAMES THE OBJECT, NO ARGUMENT ABOUT THE TOTAL IS ADMISSIBLE.**
  In the same run, Vivado's `Report RAM Utilization` table named
  `gb_real.stmem_p.stmem_reg | 3072 K x 64 | 5472` outright, and had done from
  the first run. This file already says the log lies in both directions and
  only the mapping report and an object-level census are authoritative -- and
  the reasoning above was still done from the utilization TOTAL, with the
  naming table sitting unread in the same log. **Read the census FIRST, not as
  a confirmation step after forming a theory**, because once a theory exists
  the census gets used to check it rather than to replace it.
- **The parts do not sum across synthesis contexts, so do not do arithmetic on
  them.** MEASURED the same day: `gdn_block` alone reports 22 BRAM tiles and
  10,161 LUT-as-memory; inside the composed block the RAM table attributes ALL
  5,472 tiles to one other object and LUT-as-memory is 35,078. Vivado maps the
  same RTL to different primitives depending on what surrounds it. A saving
  predicted by subtracting one context's number from another's is not a
  prediction, it is two unrelated measurements. Substitute and re-synthesise.
- **Teeth-check everything.** A checker never shown to fail has not been shown
  to work. **Report mutations that do NOT bite** under their own names: they
  measure your check's resolution floor and are the most valuable line in the
  table. Never discard one.
- **A GREEN BENCH ACROSS A REAL FIX MEANS THE FIX IS UNTESTED, not that it was
  unnecessary.** MEASURED 2026-09-03: `tb_a_job_counter` passed 122 checks
  against a level-triggered reload AND against the edge-triggered one that
  replaced it, because it had no case holding the signal high. Adding that case
  took it to 134 and the pre-fix version failed 4 of them. **Whenever you change
  RTL and the bench still passes, the next action is to write the case that
  distinguishes them, and to run the OLD version against it.** If you cannot
  make the old version fail, you did not fix anything.
- **A CHECK CAN BE CORRECT FOR THE WRONG CONTRACT.** The same bench had a
  deliberate, mutation-killed check that `tok_start` wins over a simultaneous
  retire. It is right for a pulse and fatal for a level. A check surviving its
  mutant says the check works; it says nothing about whether the property is
  the one the driver actually guarantees.
- **COUNT BENCH CHECKS IN VARIABLES, NEVER IN SIGNALS.** A signal assigned twice
  in one delta keeps only the last value, so consecutive `chk` calls with no
  `wait` between them collapse to ONE increment. MEASURED 2026-09-03: a bench
  reported `checks=13` for a body containing 60 and passed. **A check that does
  not count is indistinguishable from a check that did not run**, so read the
  count and ask whether it matches the number of `chk` calls you wrote.
- **A WAITER'S EXIT CODE IS THE HARNESS'S, NOT THE JOB'S.** This is the
  `wait_on_run -timeout` lesson in a new place: a background waiter ending in
  `grep -c <pattern>` reports FAILURE when the pattern is absent, which is
  exactly the success case when the pattern is a defect you removed. Twice on
  2026-09-03 a green gate arrived labelled "failed with exit code 1". Gate on a
  sentinel the work itself wrote, never on the waiter's status.
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
