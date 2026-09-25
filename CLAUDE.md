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

  **AND THE 10.66 GB FIGURE IS THE *ENGINE-ONLY* BUILD. THE CARD BUILD IS
  BIGGER.** MEASURED 2026-09-16: the first `FK33_CARD=1` build -- the one that
  adds subsystems B, C and D via `hw/fk33/rtl/fk33_card.vhd` -- reached
  `memory.peak` **18.00 GB within 28 minutes, still inside SYNTHESIS**, before
  place-and-route began. That figure is exactly its `MemoryHigh`, so per the
  rule below it is the CAP and not the appetite; the true peak is unknown and
  is at least 18 GB. Swap went from 2 GB to 15 GB in the same period.
  **`gen_pcieep.py:958` says outright that the card cell is gated so "the
  engine-only build that has produced bitstreams is not disturbed", so the two
  are different jobs and their budgets are not interchangeable.** This
  dispatcher quoted 10.66 GB for the card build while calling the budget
  "stated explicitly", which is the same cross-configuration borrowing that
  cost three sessions on the elaboration wall. **Budget a `FK33_CARD=1` build
  at 18 GB or more, and never at the eng-only number.**
  **MEASURED 2026-09-19, AND THE REAL NUMBER IS ABOUT 47 GB.** The card
  build under `MemoryHigh=24G` in synthesis: cgroup `memory.current`
  23.5 GB AND `memory.swap.current` 23.9 GB at the same instant, box swap
  27 of 31 GB. Every figure above counted RESIDENT memory only, and a capped
  job's resident set is the cap; the rest was in the swapfile the whole
  time. **The build fits this box only because of 31 GB of swap, and a
  second large job beside it fills that swap.** Run it alone, put a guard
  on swap-in-use (kill the unit at 30 GB, `$SD/build6/swapguard.sh` is the
  shape), and read `memory.swap.current` next to `memory.current` before
  quoting any footprint.
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

**`labuser@192.0.2.133` (`cachyos-bc250`) exists for exactly this and was
never touched.**

**CORRECTION 2026-09-15: THE ADDRESS ABOVE USED TO READ `.200`, AND IT IS
DHCP, SO ANY NUMBER WRITTEN HERE CAN GO STALE.** MEASURED: `ssh ... .200`
returned `No route to host`, and this dispatcher read that as "the BC-250 is
down, its sweep results are lost" and said so. The box was UP the whole time.
The router's lease says `79834 40:a5:ef:5f:0a:79 192.0.2.133 cachyos-bc250`.
**A failed connection to a hardcoded address measures the address, not the
host**, and it is the same shape as every other trap in this file: a fact
about the harness reported as a fact about the job. `~/GitHub/DevOps/CLAUDE.md`
already said `.133` and already said *"Find it from the router, never by
guessing"*; the guess was made anyway because the number was sitting here.
**Resolve it before every dispatch, and do not trust this line either:**

```bash
ssh labuser@192.0.2.1 "grep -i cachyos /var/lib/misc/dnsmasq.leases"
```

`~/GitHub/DevOps/bc250-sync-llama-vhdl.sh` carried the same stale `.200` as its
`HOST` default and was fixed the same day. **A lease entry is not proof the box
is up** (the Dell note records exactly that failure), but the absence of a
route to a WRONG address is proof of nothing at all. On the night the workstation died it was **up 3 days, load
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
- **What it is NOT for:** it has **15.2 GB unified** memory. A full
  `engine_shared` OOC peaks 23.8 GB and does not fit. **Check the peak against
  14 GB before sending anything.**

  **CORRECTION 2026-09-05: A FULL `pcieep` BUILD DOES FIT, AND HAS RUN THERE
  TO A BITSTREAM.** This entry used to say it "peaks at 25.0 GiB and does not
  fit". MEASURED on the BC-250: **Vivado's own peak 11.85 GB**, lowest free
  physical 2,361 MB, 0 errors, `bd_wrapper.bit` written. That is the SECOND
  independent measurement against the 25.0 GiB figure (the first, on the
  workstation, was 10.66 GB) and the first that completes the job on this box.
  **The 25.0 GiB number has never been re-derived and should not be quoted
  again.** Refusing to run a build on it is the expensive error.

  **AND THE RESULT IS THE SAME BITSTREAM.** `cmp -l` against the workstation's:
  **35 differing bytes of 21,647,330, all at offsets 28-123, all header** --
  the attribute order (`COMPRESS`/`UserID`) and the build timestamp. All
  21,647,207 bytes of configuration payload are IDENTICAL, and timing matched
  exactly (WNS 0.001, TNS 0.000, WHS 0.009, 0 failing endpoints of 672,531,
  286,806 of 286,806 nets routed). So the documented "bit-identical across the
  two machines" property, previously established only for OOC synthesis,
  **holds for a full place-and-route and bitstream**. A pcieep build measured
  there is quotable here.

  **CAVEAT ADDED SAME DAY, AND IT COST THE BOX.** The completed build above
  ran under `MemoryHigh=11G`. A SECOND build was then launched with the cap
  raised to **12G on a 14 GB box**, specifically to avoid the throttling noted
  below -- and the machine became **completely unreachable** partway through
  (3 pings unanswered, ARP `FAILED`). Not proven to be the cause: `wlan0` is a
  **USB dongle** and could have dropped on its own. But one thing changed and
  the box died, and it is on **no WoL watchdog**, so it needs a physical
  power-cycle. **Stay at or below `MemoryHigh=11G` there for a pcieep build**
  until someone establishes otherwise, and treat the ~2.3 GB of free physical
  that the 11G run left as the real headroom rather than slack to spend.

    **Do NOT read the 2h18m wall time as a speed ratio.** That run was capped at
  `MemoryHigh=11G` and peaked at 11.85 GB, so it built partly throttled into
  reclaim. A capped job's wall time measures the cap, not the machine. See
  `docs/debugging/2026-09-05_cross-machine-bitstream-identity.md`.
- **It is 2.3x slower** end to end, MEASURED on identical ZU3EG synthesis. A
  2 h workstation sweep is ~4.5 h there. **That is still infinitely faster than
  a sweep that hangs the box and loses ninety minutes of place-and-route.**
- **Its shell is fish**, so wrap remote commands in `bash -c "..."`, or
  better `ssh ... 'bash -s' < script.sh`, which sidesteps fish's quoting
  of `$` entirely (MEASURED 2026-09-19: a `bash -c` with a `/proc` loop
  died on `$"`).
- **It has GHDL since 2026-09-19** (AUR `ghdl` 6.0.0, mcode; the official
  repos carry none, and a stale pacman DB 404s the AUR's deps until
  `pacman -Sy`). MEASURED: `sim/regress.sh --only tb_rmsnorm_rs_mem` PASS
  there with `REGRESS_SCRATCH=~/regress_scratch/<run>`. So it is a second
  GATE lane as well as a second Vivado lane; keep the two `sim/*.tcl`
  absolute-path traps in mind (the sync destination already matches) and
  `ulimit -s unlimited` before the big benches.
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
**2026-09-24, Oren's decision for a test: VCCINT 0.78 V (wiper 25).** Build
19's attention hang is a timing failure at 0.715 V (every build is signed off
at 0.85 V): 2 of 3 ctxtest runs hung at 0.715 V, 0 of 8 at 0.78 V. Oren: "We can
interlock to there in the bitstream once we verify". Until the full-context test
passes and the clamp is moved, wiper 68 remains the standing value and the
raise is `hw/fk33/host/fk33_vccint_test.py` only. The pot is VOLATILE: a power
cycle returns 128 (0.678 V). See
`docs/debugging/2026-09-24_build19-attention-hang-is-voltage-sensitive.md`.
**CORRECTION same day: 0.78 V REDUCES the hang (1 in 11 runs), it does not
remove it** (n500 output run hung at position 32 on card 2). Do not quote it
as fixed. **CORRECTION 2, same day: no voltage effect is established at
all** (0.715 V 4 hangs in 13 sequences, 0.78-0.80 V 2 in 15, Fisher p = 0.26);
the "2 of 3" baseline was three trials. Count every sequence as a trial.
**CORRECTION 3, same day: it HANGS AT 0.85 V** (1 in 36 sequences, after
0.80 V 2 in 18), the voltage the design is signed off at. Raising VCCINT is
not a fix at any value and there is no threshold; the lead is a race or CDC
in build 19's NORM_HBM change. Wiper 68 stands.
**CORRECTION 4, same day: build 19 was NOT a one-variable change.** It dropped
`build12_levers_off.patch`, which every card build from 12b to 18 applied, so
`FAST_POP`, `NWIDE`, `SWEEP_PIPE` and `SCORE_EARLY` came on with NORM_HBM. The
committed tree has all four ON since `a95017c`; **a card build that does not
apply the patch gets them silently.** Diff `Parameter ... bound to` out of both
logs before attributing anything to a build.
**CORRECTION 5, same day: build 20 (NORM_HBM alone, levers off) does NOT hang**, 0 in
60 at 0.715 V against build 19's 4 in 13 (p = 6.6e-4), and passes N=500 pair and single.
The hang comes with the levers; which one is open. **`build12_levers_off.patch` is
load-bearing for every card build until a lever is shown safe on silicon.**
**AND THE LOG'S BIND LINES ARE NOT COMPLETE, SO THEIR ABSENCE PROVES NOTHING.** MEASURED
2026-09-25: build 20's log has `done synthesizing module 'attn_block'` but not its
`[Synth 8-638] synthesizing module 'attn_block'` line nor any of its `Parameter` lines
(94 `8-638` lines; build 18's has 172, including attn_block's, so it is not the 100-message
limit). Cause not established. A lever's bind line may be quoted when present; when absent,
read the worktree the build compiled.

---

## AFTER EVERY CARD BUILD: THE FULL-CONTEXT TESTS, TWICE

**Standing instruction from Oren, 2026-09-24: "full input context and full
output context length tests after every build, ran two times, so issues
surface better."** **REVISED THE SAME DAY:** "Run a much shorter test (500 in and
out) and considering how long these test take, we don't need to run them" -- the
FULL-context runs are no longer required. A bitstream is not done until the
500-token test has run on it, twice:

```bash
hw/fk33/host/fk33_ctxtest.sh pair   /mnt/storage/fk33_builds/<build>/ctxtest/n500 500   # two-card split
hw/fk33/host/fk33_ctxtest.sh single /mnt/storage/fk33_builds/<build>/ctxtest/n500 500   # one card
```

It runs the INPUT test (a real-text prompt of the full context, prefill only)
and the OUTPUT test (a 16-id prompt, then decode with the stop token disabled
to the full context), each twice, compares the two runs' ids, and dumps every
card's seam after every run. Gate on `^CTXTEST_PASS` and check that it says
`FULL`: a third argument N makes a SHORT run, and the verdict says so.
**Cost at the 9B's 65,536 context is about 4.4 h per run, ~17.5 h for the
four.** Run a short N=256 pass first; it costs 4 minutes and has already
caught the build-19 attention hang (position 32, second run) that twenty
ordinary 25-id prompts caught twice.

Why it exists: every earlier silicon check was a ~25-id prompt with 64 tokens
out, which crosses ONE KV-block boundary ONCE. Opens `/dev/xdma*`: the main
session or Oren runs it, never a subagent.

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

**AN UNCONNECTED MODULE-REFERENCE INPUT IS TIED TO ZERO, AND WHETHER VIVADO
SAYS SO DEPENDS ON WHETHER THE VHDL PORT HAS A DEFAULT.** MEASURED twice on
2026-09-18. Two `FK33_CARD=1` builds carried `CRITICAL WARNING: [BD 41-759]`
naming `/card/a_arena_base` and `/card/bst_state_base` -- ports WITHOUT a
default, because `tools/gen_bd_wrapper.py` strips them -- and every gate
passed because the build greps `^ERROR`. A fetched descriptors from HBM
address 0. Then the mutant of the fix: `eng/d_x_exp`, declared
`:= (others => '0')`, left with no net, and `validate_bd_design` printed
**nothing at any severity** (`grep -c 41-759` = 0). The whole D-facing
surface of `fk33_engine` is declared with defaults. So the loud case was
luck, the quiet case is the normal one, and the only guard on either is the
net-based `FK33_UNCONNECTED` check in `gen_pcieep.py`, which walks every
`module_ref` cell's input pins and errors on any without a net. **Gate on
nets, never on the warning, and never on `^ERROR` alone.** Its own teeth:
count=2 on the arena mutant, count=1 naming `/eng/d_x_exp` on the wire
mutant, count=0 on both controls.

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

**PRESENCE IS A LANE CHECK, NOT A QUEUE. TWO WAITERS ON `vivado_present` BOTH
START.** This file already says to gate on PRESENCE via `/proc/PID/exe` rather
than on a count, and that is right for "may I use the lane". It does NOT
serialise. MEASURED 2026-09-05: two jobs were armed on the same presence poll
while a third ran; when that third ended, both would have seen a free lane in
the same window and launched together -- two Vivados, which is the condition
that hung this box in August. Caught before it fired, by arithmetic rather than
by observation.

**Chain each queued job on the SENTINEL of the job ahead of it, then check
presence as the safety net.** The sentinel says "the work before me finished";
presence says "nothing else grabbed the lane meanwhile". Neither alone is
enough: a sentinel cannot see an unrelated tool, and presence cannot see a
sibling waiter that is about to start.

**A `phys_opt_design` WNS IS NOT A RESULT ON THIS PART. IT OVER-PROMISES BY
0.4 TO 0.6 ns, MEASURED TWICE.**

| design | phys_opt (pre-route) | routed | given back |
|---|---|---|---|
| composed top, 2026-09-05 | **+0.006**, 0 failing endpoints | -0.422 | **0.428 ns** |
| C's mover, 2026-09-05 | **-0.805** | -1.438 | **0.633 ns** |

Both clean routes, both large enough to INVERT THE VERDICT: the composed run
showed positive slack with zero failing endpoints before routing and would have
been reported as meeting 200 MHz. A placed WNS is no better and can be worse --
that same run placed at **-0.406**, WORSE than the baseline's -0.402, and ended
phys_opt 0.4 ns BETTER. **Nothing before `route_design` orders two runs
correctly.** This is the `STATS.WNS`-from-the-wrong-stage lesson, except the
intermediate number had the opposite SIGN.

**AND THE PLACED STAGE HAS NOW INVERTED A ONE-VARIABLE SAME-TREE PAIR, AT 3.5x
THE LARGEST OVER-PROMISE RECORDED ABOVE.** MEASURED 2026-09-21 by TRACK
ATTNDRAW on `attn_block` at the card's 9B generics, two arms differing only in
`SWEEP_PIPE`/`SCORE_EARLY`, same tree `3e344a2`, same script, both clean routes
with 0 failing endpoints:

| | placed WNS | routed WNS | over-promise |
|---|---|---|---|
| `coff` (both levers off) | 4.558 | **2.356** | **2.202 ns** |
| `con` (both on) | 3.774 | **2.735** | 1.039 ns |

**Placed says `coff` is better by 0.784 ns. Routed says `con` is better by
0.379 ns.** The sign of the comparison reverses. Every earlier entry here is a
`phys_opt` figure or a cross-run comparison; this is the cleanest possible
setting -- one variable, one tree, one script, one harness -- and the placed
number still ordered the two arms backwards. **So "a placed WNS is no better and
can be worse" understates it: a placed WNS cannot be used to RANK two arms even
when everything else about them is identical.**

The corollary ATTNDRAW drew, and it is the reusable half: **it reported the
0.379 ns routed delta as NOT A RESULT**, pre-registered as such, because it is
below the harness's noise floor, has the favourable sign, and its worst paths
are in different modules. A cross-tree spread of **0.745 ns** on the same arm
puts the real floor at roughly twice the 0.4 ns previously recorded, and
settling that needs REPEATS OF ONE ARM, which nobody has run. **Quote a routed
WNS as a bound, not as a comparison, until the floor is measured.**

**AND A SYNTHESIS-ONLY HARNESS IS NOT A TIMING RESULT AT ALL.** MEASURED
2026-09-05: `grep -cE 'opt_design|place_design|route_design' sim/ooc_cattnadapt.tcl`
returns **0**, and B's harness is the same. Both movers' headline figures --
`-4.008` (111 MHz) and `-1.611` (151.3 MHz) -- were POST-SYNTHESIS estimates
quoted as blockers for a week. Implemented, C is **-1.438 (155.3 MHz)**.
Check for `route_design` before quoting any fmax from an OOC script.

**SYNTHETIC STIMULUS DISTORTS TIMING AND AREA, NOT ONLY VALUES.** MEASURED
2026-09-05: B's `-4.008`, the project's headline blocker in three documents, is
`m12` -- a 32-bit LCG with TWO SERIAL 32x32 multiplies that builds the conv
WEIGHTS combinationally in `llama_top`'s `cvdata_p`. In the shipping design
those weights come from memory and that cascade does not exist. Two independent
proofs: the path traverses `DSP_MULTIPLIER U[43]` and `ALU_OUT[47]`, which a
`signed(16)*signed(16)` MAC producing 32 bits CANNOT reach; and all 15 worst
paths share ONE startpoint fanning to sixteen `p1_reg[t][ln]` A-inputs at
constant depth, the signature of `m12`'s shared first argument.

**It does NOT follow that B is fast.** The harness has no memory-sourced
weights, so B's real fmax is UNKNOWN. The established claim is only that the
quoted number measures something that will not be built. This is the recorded
`B_SRC_REAL` stimulus finding generalised from VALUES to TIMING AND AREA, and
the distortion was large enough to have set project priorities.

**A `get_cells` FILTER THAT MATCHES NOTHING IS A WARNING, NOT AN ERROR.**
MEASURED the same day: `get_cells -hier -filter {PRIMITIVE_GROUP == DSP}`
matched nothing (`WARNING: [Vivado 12-180]`), so a census printed zero lines
while `report_utilization` said 194 DSPs, and the run still reported success.
The working idiom is `REF_NAME =~ DSP*`, matching this file's recorded
`REF_NAME =~ RAM*`. Same silent-empty-result shape as a checker printing PASS
over an object it never read.

**CORRECTION 2026-09-20: `REF_NAME =~ DSP*` OVER-COUNTS BY EXACTLY 9x, AND
THIS FILE RECOMMENDED IT FOR THREE WEEKS.** MEASURED by TRACK GDNSYNTH on the
BC-250: **1,719 matches against a true 191**, because the filter also catches
the DSP58's SUB-PRIMITIVES (the slice decomposes, and every piece carries a
`REF_NAME` beginning `DSP`). So the two failures are mirror images and the
paragraph above only warned about one of them: `PRIMITIVE_GROUP == DSP`
silently matches NOTHING, and the "fix" silently matches NINE TIMES TOO MANY.
Both run clean, both report success, and neither raises anything above a
WARNING.

**The rule is not a better filter, it is that A CENSUS IS AUTHORITATIVE ONLY
WHEN ITS FILTER HAS BEEN VALIDATED, and a filter can be wrong in EITHER
DIRECTION.** Anchor it against a total you already trust before you quote
anything it produces -- `report_utilization`'s DSP row is the cheap
cross-check here, and the discriminator is that agreement to the digit is
evidence and a 9x discrepancy is the filter, not the design. The same caution
now attaches to `REF_NAME =~ RAM*`, which has never been validated this way
and is recorded above as authoritative.

This does NOT retract the paragraph above. The census still beats the
inference log, and where the two disagree the census still wins. What is
retracted is the idea that switching to `REF_NAME` made the census
self-validating.

**CORRECTION 2026-09-21: `REF_NAME =~ RAM*` HAS NOW BEEN VALIDATED AND IT
OVER-COUNTS BY 17.6x.** MEASURED by TRACK CBCENSUS on card build 11b's
synthesis checkpoint: under one instance it returns **651 against 37 real
macros**, because 518 `RAMD32` + 74 `RAMS32` = 592 = 37 x 16 are the macro's
own CHILDREN, and the filter additionally sweeps in 22 `RAMB*` block RAMs,
which are a DIFFERENT RESOURCE and belong to another column entirely. So the
paragraph above was right to withhold trust, and the answer is now measured:
this idiom is wrong in the same direction as `REF_NAME =~ DSP*` and by a larger
factor. **For distributed RAM, count the MACROS (`RAM32M16` and friends) and
multiply by their width, then anchor against `report_utilization`'s
`LUT as Distributed RAM` row** -- CBCENSUS got 37 x 8 = 296 against a reported
296, exact.

**AND THE LUT ROWS CANNOT ANCHOR A CELL CENSUS AT ALL, because they are SITE
counts.** MEASURED the same day: census `LUT1`-`LUT6` = 124,338 against
`LUT as Logic` = 118,975, and the 5,363 gap is LUT COMBINING, not a filter
error. Anchor a cell census only against a row that counts cells: the F7/F8 Mux
rows, `CLB Registers`, the DSP row and the Shift Register row all matched
exactly to the digit. Pick the anchor before running the filter, and if the only
available anchor is a site count, say the census cannot be validated rather
than quoting it.

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

**`fk33ctl.py vccint` IS NOT A READ. IT STEPS THE VCCINT POT.** MEASURED
2026-09-24: run as a check with `| head -2`, it wrote wiper 68 -> 69 on both
cards and died on SIGPIPE mid-procedure. Read the rail with `fk33ctl.py sysmon`
and the wiper with a bare `I2C(Mmio()).pot_read(POT_ADDR)`. The MMIO
bit-banged I2C also NACKs intermittently (one read, one write that did not
land, same session), so never trust a single pot transaction.

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

**A SECOND ARRAY WRITTEN FROM THE SAME WRITE PORT AS THE FIRST CAN LEAVE THE
FIRST ONE NEVER WRITTEN, AND NO BENCH CAN SEE IT.** MEASURED 2026-09-22/23,
builds 15 and 17: `rtl/region_mem.vhd` mirrored R_X into a `ram_style=block`
"shadow" array written from the region's own `wr_*` signals, to give the host
window a registered BRAM read. GHDL: every row green, the seam bench in the
card configuration reproducing the reference residual. Silicon: argmax 0,
all-zero residual, token 0.23% SHORTER. The synthesis checkpoint's netlist
(`get_pins` on the four region-0 `RAMB36E2`): **every `WEBWE`/`WEA` pin on
`<const0>`**, the write decode alive only on the shadow BRAMs. `synth_design`
kept one writer and grounded the other, and `report_ram_utilization` plus
"recognized as a true dual port RAM template" said nothing either way. It took
a closed route (+0.373 ns), a load, and a one-variable silicon control (the
shadow without the other change) to attribute. **Never mirror a region; serve
a second reader from an existing port at idle** (the card's window now rides
the element read port in `llama_top`'s `elmux`), and gate the flow on the
NETS: `hw/fk33/gen_pcieep.py` now opens the synthesized run and errors
(`FK33_REGION0_WE FAIL`) if any region-0 BRAM has all its write enables on a
constant net. See
`docs/debugging/2026-09-22_the-r-x-shadow-zeroes-the-residual-on-silicon.md`.

**A TABLE INDEXED BY A PER-TOKEN COUNTER IS CORRECT FOR EVERY PROGRAM THAT
STARTS AT STEP 0 AND WRONG FOR EVERY OTHER, AND NO BENCH RUNS ANY OTHER.**
MEASURED 2026-09-23 on the first two-card run: `rtl/llama_top.vhd` serves
the RMSNorm gain from `NORM_W_IMAGE` "one entry per OP_VEC_NORM of the token,
in SCHEDULE ORDER", a counter, while every VEC_NORM step carries its block in
`const_base`. Card 1's program starts at block 16, so its first norm got
block 0's gain and the pair diverged at positions 7, 28 and 0 with plausible
text that decayed into repetition. Every static input was identical (D table,
tensors, header, bases, bytes, placement); the bit-exact oracle (the full
card's own residual dumped at the same step via `--upto`/`--override`) put
the difference in the FIRST step. `gen_layer_program --pad-norms 2*lo` is
the workaround; the fix is to index by the step's block. **When a unit keeps
a counter that a descriptor field could replace, the counter is a latent
split bug**, and the bench that finds it runs a program from the middle.
`docs/debugging/2026-09-23_the-norm-gain-is-indexed-by-a-per-token-counter.md`.
**FIXED IN RTL 2026-09-23, NOT YET ON SILICON:** the row is the norm's
`const_base` (2*blk, 2*blk+1, 2*blocks) and the card reads it from HBM
(`NORM_HBM`). A program generated before that names the BLOCK there, which
the new RTL reads as the wrong gain; `dprog_oracle` C5 refuses it.

**AN `mmap` ACCESS TO THE USER BAR HITS AN AUTO-INCREMENTING REGISTER TWICE.**
MEASURED the same day: a python probe reading the seam window through an
`mmap` slice advanced `WIN_ADDR` by 2 per access (8192 after 4,096 reads)
and wrote every other address, which looked exactly like "the upper half of
the window is dead" (2,048 of 4,096 differ, all zeros). The host code uses
pread/pwrite, one AXI-Lite transaction per access, and is bit-faithful (0 of
4,096). **Probe the seam only with the primitive the host code uses**, and
treat a clean power-of-two boundary in a "hardware" fault as the instrument.

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

**AND THE RULE RUNS BOTH WAYS: EDITING A GENERATOR'S *INPUT* CARRIES THE SAME
OBLIGATION, BUT LINE 2 CANNOT WARN YOU.** MEASURED 2026-09-05: the full gate
went red on `sim:cardtop` (`GEN_CARDTOP_CHECK: STALE`) after a commit appended
a 13-line COMMENT to `rtl/llama_top.vhd`. That file is hand-written, carries no
banner, and is a perfectly ordinary file to edit -- **it is also the input to
`tools/gen_cardtop.py`, which emits `rtl/fk33_llama_top.vhd`, and nothing on
the source says so.** The check above is performable by reading the file in
front of you; this one is not, because the derived file is elsewhere and the
source holds no back-pointer. Ask whether anything generates FROM the file,
not only whether it was generated.

There is **no clean detector** and do not build one:
`grep -rln "llama_top" tools/*.py hw/fk33/gen_*.py` returns **29 files**,
narrowing to those that also emit a `.vhd` gives **9**, and nine still
over-reports. It is a LEAD that turns "read every tool" into "read nine".
**What actually works is the `--check` gate row**, and the contrast is the
argument for them: this cost one row and printed the diff, whereas the
IDENTICAL staleness in `compose4_top.vhd` had no gate, was wrong since
`11bf64b`, and surfaced only because an unrelated run happened to regenerate
it -- luck, not a check. **`fk33_engine.vhd` is still ungated**, because its
generator writes unconditionally and even `--help` rewrites the repo file.

**AND LINE 2 DOES NOT SAY *WITH WHAT*. A GENERATOR THAT READS THE ENVIRONMENT
OR AN ARGUMENT MAKES "REGENERATE AND DIFF" THE ACTION THAT DESTROYS THE
EVIDENCE.** MEASURED 2026-09-20: `hw/fk33/build_fk33_pcieep.tcl` has a correct
banner and was built with `FK33_CARD=1` plus `FK33_CB_STYLE=distributed`;
regenerating it with the default environment deleted **496 lines, the whole
lever-C block**, in a diff that reads as ordinary drift. Nine environment
variables decide what that generator emits and the file records none of them.

**Before regenerating any committed generated file, read its `GENSTAMP` block
and regenerate with exactly those values.** If it has no stamp, do NOT
regenerate to find out what it is: recover the inputs first (`git log` on the
file, and the configuration visible in its own text), confirm by byte-identity,
and add the stamp. **A diff you cannot attribute to a named input is not a
staleness result.**

**When you write or change a generator whose output is COMMITTED, emit
`tools/genstamp.py`'s block into that output.** Values and the reproduce
command only: **no timestamp, no user, no hostname, no working directory**, or
every `--check` staleness row (`sim:cardtop`, `sim:gdnstale`, `sim:c4stale`,
`sim:fk33card`, `sim:ipsync`) goes red on every machine.
`rtl/ooc_cattnadapt_top.vhd` is the counter-example already in the tree: its
regenerate line embeds a `/tmp/claude-.../scratchpad` path that is neither
reproducible nor still present.

**And the stamp must not itself depend on what it says it does not depend on.**
MEASURED the same day: one shared reproduce command built from the process
environment made `fk33_bc_grant.vhd`, stamped `inputs: NONE`, grow by exactly
19 bytes under `FK33_C_KV_BLOCK=16` -- the width of the prefix. Derive the
command from the same list the rows are printed from.

**A GENERATOR THAT REFUSES ITS ARGUMENT LEAVES THE FILE UNTOUCHED, AND AN
UNTOUCHED FILE COMPARES EQUAL TO ITSELF.** `gen_hbmbw.py 31 300` was reported
as a byte-identical reproduction, twice by `sha256sum`, while the generator had
exited on a range check with its output sent to `/dev/null`. A `SyntaxError`
did the same thing an hour later. **Read the exit status and let the generator
print, and prefer a reproduction test that must CHANGE something over one that
must change nothing.** This is the "guards that pass for the wrong reason"
class arriving through the shell rather than through the check.

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
- **A COMPARISON NEEDS BOTH ENDS DRAWN FROM THE SAME TREE, AND INTERNAL
  CONSISTENCY CANNOT DETECT STALENESS.** MEASURED 2026-09-05: a subsystem area
  table was read from `hw/fk33/results/compose4_2026-08-29/` -- the date is in
  the path -- and compared against this week's routed run. `d_norm` was wrong by
  **9.7x in LUT and 66x in FF** (48,501/133,169 against the real 5,017/2,004),
  and the whole difference between a week-old synthesis and a current routed
  number was written up as a **25% stage over-count**. Same-tree, the stage
  effect is **-1.4%**. A week of design change had been charged to the mechanism
  under discussion.
  **The stale table passed every arithmetic check**: its four subsystems summed
  to 343,907 against its stated top of 350,283, leaving 6,376 of glue, and the
  CORRECT table leaves the identical 6,376. Self-consistency survives staleness
  because staleness does not break arithmetic. Nothing but reading the date
  would have caught it.
  This is the "not the buffers" failure in a new place: a difference was
  attributed to the mechanism being discussed rather than to the uncontrolled
  variable. **Assert the tree identity; do not infer it from a filename being
  plausible.** The cheap discriminator is a control that should NOT move: in the
  corrected experiment `a_eng` was 92,134 LUT in both runs to the digit and
  `b_gdn` differed by 3, which is what made the 14,383 LUT delta attributable at
  all.
- **THE SAVING IS NOT PROPORTIONAL TO THE PARAMETER.** MEASURED the same day, on
  a fresh case: `u_arr`'s DSP count is exactly `2 * G * KV_BLOCK` and an 8x
  reduction in `KV_BLOCK` delivered exactly the derived **-224 DSP**. Scaling its
  **LUT** the same way predicts about -50,000; the measurement is **-18,022** in
  `u_arr` and **-14,383** net, because a narrower array needs deeper muxing
  (F8 muxes **+113%**) and ~3,642 LUT plus ~2,051 FF reappeared elsewhere in the
  same block. **An exact relationship for one resource is not a licence to scale
  a different resource by the same factor.** Refusing to project was worth 3.4x
  here, and the projection would have erred in the flattering direction.
- **ENUMERATE WHAT DIFFERS BETWEEN TWO RUNS FROM THE RUNS' OWN RECORDED
  PARAMETERS, NEVER FROM THE INTENT OF WHOEVER LAUNCHED THEM -- AND A CONTROL ON
  THE WRONG AXIS READS AS RIGOUR.** MEASURED 2026-09-05, and it happened within
  an hour of the same-tree entry above being written, in the document announcing
  it. Two composed runs were compared as a one-variable `KV_BLOCK` experiment and
  a **1.120 ns** result was written up, committed, and propagated to three
  documents. **They differed in FIVE things**: `KV_BLOCK` plus all four
  implementation directives (`c4nd` `''`/`ExtraNetDelay_high`/`AggressiveExplore`/
  `NoTimingRelaxation` against `c4kv4` `ExploreWithRemap`/`ExtraTimingOpt`/
  `AggressiveExplore`/`Explore`). Both runs print a one-line `C4_DIRECTIVES`
  sentinel and both sat in the logs the whole time; the comparison was made from
  memory of what the run was *for*.
  **The experiment HAD careful controls and they were on the wrong axis.**
  `a_eng` was 92,134 LUT in both runs to the digit and `d_norm` 5,017 in both --
  genuinely good controls, which is precisely why the SYNTHESIS results survive
  (synthesis does not read implementation directives). They say nothing about
  implementation, so every timing, congestion and placement claim fell. **Having
  a control is not having the control the claim needs, and a well-chosen one on
  a neighbouring axis is worse than none, because it reads as rigour.**
  Ask which stage the claim lives at, then ask what was held constant AT THAT
  STAGE. An area claim and a timing claim from the same pair of runs can have
  different answers, and here they did.
- **AND "THE RUNS' OWN RECORDED PARAMETERS" INCLUDES THE LAUNCH ENVIRONMENT,
  WHICH IS IN NO COMMIT. MEASURED 2026-09-21: this cost a 4h25m card build and
  a wrong root cause that was committed and reported.** Build 11b was launched
  to test a codebook change and was silently synthesised at `CB_STYLE=regs`
  while builds 9 and 10 were at `distributed`, because
  `hw/fk33/pcieep_build.sh` never sets `FK33_CB_STYLE` and `gen_pcieep.py`
  defaults it to `regs`. At `regs` the codebook is 48 copies rather than 1,536,
  `cb_rank_of(c) = c`, and **the commit under test was the IDENTITY** -- while
  the design forbade its own RAM inference (`dont_touch=true`,
  `ram_style=registers`) and became a 12,288-MUXF8 mux tree that could not
  route. The failure was written up as the codebook's, in a section explicitly
  titled "a MULTI-VARIABLE comparison" that enumerated two commits and five RTL
  files. **The enumeration was of the wrong space.** Diff
  `Parameter <NAME> bound to` out of both LOGS, and the `--setenv` list of both
  units; a `git diff` between two builds cannot see either. The full parameter
  diff here was four entries and only one mattered.
- **NAMING THE OBJECT IS NOT NAMING THE CAUSE.** Same incident, and the
  measurement was sound: 38 of the 40 nets Vivado listed at its top ten
  signal-overlap nodes were `core/cb`, which correctly bounds WHERE the
  congestion was. It says nothing about WHY that object had the shape it had,
  and the step from one to the other was taken silently. This file's rule that
  a naming report beats an argument about a total still holds -- it establishes
  location, not mechanism.
- **`[Synth 8-5859]` MAY BE QUOTED WHEN PRESENT AND NEVER WHEN ABSENT.**
  MEASURED 2026-09-21 by TRACK CBRUN across four OOC arms at
  `CB_STYLE=distributed`: the anchored count of `8-5859` naming `cb_reg` is
  **0 in all four**, while the same runs' mapping reports name **1,536
  RAM32M16** copies each and `get_cells` gives `cb_ram=26112, cb_ff=0`
  identically. The message is absent in runs where the inference DEMONSTRABLY
  SUCCEEDED, so its absence distinguishes success, refusal and non-attempt not
  at all. This dispatcher used its absence twice in one day: once to claim the
  log "says nothing either way", and then, in the correction to that, to assert
  that "no inference was attempted". The second was the same error as the first.
  The netlist census is the load-bearing evidence in both directions.
- **AN ARM THAT CANNOT DIFFER IS NOT A CONTROL, AND THIS HAS NOW HAPPENED
  TWICE.** MEASURED 2026-09-21: CBRUN's `fan` arm is byte-equivalent to its
  `new` arm in the netlist -- identical cells, nets and pins
  (171,716 / 2,046,259 / 4,708,060) and `cbx_any=0`, because the aliases it
  introduced do not survive elaboration. The same harness separately REFUSES
  `CB_STYLE=regs` precisely because two arms are provably one design there and
  a naive run would print a zero delta that is a fact about the generic.
  **Before drawing an arm, state what in the netlist must differ, then check
  that it did.** A zero delta and an identical netlist look the same in a
  results table.
- **A CAP-VERIFICATION CHECK CAN PASS FOR THE WRONG REASON THROUGH
  `systemd-run`'s OWN COMMAND-LINE EXPANSION.** MEASURED 2026-09-21: a readback
  written as `systemd-run ... bash -c '... $cg ...'` had `$cg` consumed by
  systemd before bash ever saw it, so the check read `/sys/fs/cgroup/memory.high`
  instead of the scope's file, got "No such file", **and exited 0.** Write the
  wrapper to a FILE and run the file. This matters because the readback is
  itself the guard against `systemd-run --user` silently doing nothing when
  `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` are absent over ssh -- so a
  readback that passes for the wrong reason removes the only protection against
  an uncapped Vivado on a 14 GB box with no WoL watchdog.
- **A SENTINEL NOTHING REFUSES ON IS DECORATION.** The `^FK33_CB_STYLE` line
  that would have caught the above ALREADY EXISTED, was already anchored, and
  already read count 0 for that build, printed into a log nobody gated on. Two
  independent instruments recorded the defect in real time. The gap was never
  detection. **When you add a sentinel, add the refusal in the same change, or
  you have added a line to a log.**
- **A FALSIFIABLE PREDICTION TESTED BY AN UNCONTROLLED EXPERIMENT IS NOT
  FALSIFIED.** Same incident. The congestion mechanism had been registered in
  advance, deliberately, with the net sign left unpredicted -- all correct
  practice -- and the uncontrolled result was then written up as a refutation
  and propagated. **Pre-registration makes the verdict feel earned and does
  nothing to make it valid.** Registering the prediction and controlling the
  experiment are two separate obligations; discharging the first well is the
  thing most likely to stop you checking the second.
- **RE-IMPLEMENT FROM THE EXISTING DCP WHEN ONLY IMPLEMENTATION VARIES.**
  Synthesis cannot read `opt/place/phys_opt/route` directives, so a directive
  control reuses the synthesised checkpoint and skips ~20 minutes. This also
  makes the control exact rather than merely equivalent: there is one netlist,
  not two that ought to match.
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

**AND THE SESSION SCRATCHPAD IS ITSELF UNDER `/tmp`, SO NOTHING EXPENSIVE MAY
LIVE THERE.** MEASURED 2026-09-20: a drive cleanup removed
`/tmp/claude-1000/.../scratchpad` while a `FK33_CARD=1` build was running out
of it. The unit stayed `active`, `/proc/PID/cwd` read
`.../build10/root (deleted)`, and every byte Vivado had written since launch
was unlinked. Lost with it: build 9's synthesis DCP, which was the
re-implementation path for a routing failure, and `tok0.r9bs`, the 9B token-0
reference capture that `probe_ref` and `tools/ref9b/check_token.py` compare
against. Oren's instruction, same day: *"Don't use /tmp/ for things since that
can get delete when cleaning."* The root filesystem on this box runs near
full, which is exactly why it gets cleaned, so this is not a one-off.

**FPGA build roots go under `/mnt/storage/fk33_builds/<tag>/`** (separate
device, 916 GB) passed as `BUILD_ROOT`. Put the swap guard and the waiter
there too, and have the guard watch free space on the device the build is
actually on. **Copy a bitstream and its logs into the repo as soon as the
sentinel appears**, not at the end of the session: every bitstream survived
this incident only because it had already been committed.
