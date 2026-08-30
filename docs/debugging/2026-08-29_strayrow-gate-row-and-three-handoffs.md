# STRAYROW: the gate row A7 could not add, and the defect building it found

**Date:** 2026-08-29
**Track:** STRAYROW, following TRACK A7 (`75f95a8`) and TRACK FLOOR (`b60591d`)
**Baseline:** `75f95a8`
**Commits:** `2217778` (the bench), `15b2f39` (`ip_repo/check_ip_sync.py`
docstring), `9ae2b5a` (WORKLOG), `0a2598a` (bench comments corrected by
measurement), `912ada7` (`BASELINE_PASS` 98 -> 99)
**Tools:** GHDL 1.0.0 mcode, `sim/regress.sh`, `python3`. No hardware. No
Vivado. Nothing under `hw/fk33/` was executed. `rtl/**` was READ and NEVER
edited; every RTL variation below was made on a COPY in the session scratchpad.
**Machine at start:** MEASURED `df -h /` 91% used / 120 G free; `/mnt/storage`
56% / 388 G free; `free -g` 31 G total, 22 G available, 4 G swap in use;
`uptime` load average 3.33 5.11 5.97 at 23:39.

---

## 1. The questions, verbatim

Three handoffs, each found by a track that correctly stopped at an ownership
line.

> **1.** A7 (`75f95a8`) fixed a **real hardware hang** and wrote down the row
> that would have caught it, but `sim/regress.sh` was held by another track and
> a new `sim/tb_*.vhd` auto-creates a row. Its words:
>
> > **`sim/tb_axi_rd_port_stray.vhd`** -- `DUAL_CLK` against a
> > **non-reset-aware** slave with a **one-cycle** reset mid-flight. ~1 s, would
> > go in green, `BASELINE_PASS` 98 -> 99. **It is the row that would have
> > caught tonight's failure at its own level.**
>
> Write the bench, add the row, and **measure the new floor rather than
> assuming 99**.
>
> **2.** `ip_repo/check_ip_sync.py`'s docstring is now wrong. TRACK FLOOR fixed
> the packaging scripts and then reported, under its own name, that its fix
> **made another file's docstring cite a now-fixed defect as a live example**.
> Fix it, and check for any sibling that cites the same example.
>
> **3.** `frst` in `rtl/axi_rd_port.vhd` is dead -- CONFIRM and RECORD, do not
> fix. **Verify the finding still holds at HEAD** (line numbers move; identify
> by content) and make sure it is recorded properly on the board.

---

## 2. The answers, up front

**All three are done. The gate row is in and green and the floor is raised.
The floor came out exactly as A7 predicted -- 98 -> 99 -- and that is the ONLY
prediction on this track that survived contact with a measurement. The reason
the row bites is not the reason A7 gave; the constant the brief told me to get
right turned out not to matter; and building the row turned an OPEN item of
A7's into a REPRODUCED defect.**

**(a) The row exists, runs in 0 s, and goes in green -- but NOT for the reason
A7 designed it around, and the difference matters to anyone who edits it.**
A7 attributed its first vacuous control to the reset being held for 20 core
cycles, and specified a ONE-cycle reset as the fix. **MEASURED: the reset hold
is not the sensitive variable at all.** Holds of 1, 2 and 20 core cycles give
an IDENTICAL stray-`rlast` count of 4 at every clock ratio, and a hold of 20
still kills the unclamped RTL. What decides it is the **FIFO depth**: at A7's
`DEPTH = 16` the AR throttle in `rtl/axi_rd_fsm.vhd` only ever has ONE burst in
flight (MEASURED: 0, 1 and 1 outstanding at the reset, at `anear`, `aslow`,
`afast`), and at `anear` the reset caught nothing at all, so the first version
of this bench **failed its own coverage assert** rather than passing vacuously.
At `DEPTH = 64` all `MAXOUT` slots fill and the reset catches 3 to 4 bursts at
every ratio. `rtl/weight_streamer.vhd:75` defaults `DEPTH` to **512**, so 64 is
the representative number and 16 was quietly the easy case.

**This is the correction to the brief and to A7's section 8b: the one-cycle
reset is not what makes the row bite.** It is kept at 2 for a different and
smaller reason (determinism across the CDC at `aslow`), and the file says so.

**(b) The attribution holds: nothing that exists catches this.** MEASURED with
A7's `os` clamp deleted from a scratch copy of `rtl/axi_rd_fsm.vhd`:
`sim/tb_axi_rd_port_dual.vhd` reports `0 errors across 4 clock ratios` and
**PASSES**; `sim/tb_axi_rd_port.vhd` reports `0 bad beats` and **PASSES**; the
new row dies on `bound check failure at ...axi_rd_fsm.vhd:250`, which is
`outst <= os` -- the same statement, at its own level rather than four layers
up in `tb_matvec_fk33_desc`.

**(c) A7's section-8 OPEN ITEM IS REAL, AND IT IS A WRONG-NUMBERS DEFECT.**
This is the finding that was not asked for. A7 wrote that stray beats can still
be written into the NEXT job's FIFO after a reset, that the clamp does not fix
it, and that it is a design decision it would not take alone. It had no
reproduction. **MEASURED here, on the COMMITTED RTL with the clamp present:**
cut this bench's `DRAIN_WAIT` from 200 core cycles to 4 and all three ratios
report the value oracle firing --

```
anear: BEAT got 3133 want 5120
aslow: BEAT got 3108 want 5120
afast: BEAT got 3155 want 5120
```

-- a beat from a burst issued BEFORE the reset, handed to the consumer as the
new job's word 0. Raised on the board as **STRAY-NEXTJOB**. **It is NOT fixed
here** (`rtl/**` is outside this track's ownership, and A7 already showed the
two candidate fixes have opposite costs depending on whether the slave shares
the reset net). **The gate row is deliberately parked at `DRAIN_WAIT = 200` so
that it goes in GREEN**: turning the shared gate red for a defect that has no
decision would punish every other track for a finding they cannot act on. The
oracle that catches it is already in the file; whoever takes the decision
shrinks one constant.

**Nothing here says the card computed anything wrong.** Reaching STRAY-NEXTJOB
needs a reset mid-job followed by a restart inside the drain window, and the
shipping flow has not been shown to produce one.

**(d) The floor is 99**, `BASELINE_PASS` raised in `912ada7`. MEASURED on a
clean `git archive 2217778`: `OVERALL PASS 99 FAIL 0 TIMEOUT 0 NOCHECK 4
SKIPPED 10`, and the gate printed the RAISE SUGGESTION rather than the refusal,
so its NOT-IN-GIT list was empty. 103 rows selected with FAIL 0, so 99 is the
CEILING, not merely the score. A7 predicted 99 and it was right -- **and it was
still measured**, because FLOOR's identical arithmetic was right four times and
wrong on the fifth, and nothing tells you which case you are in except running
it. Raw output in section 5.6.

**(e) `check_ip_sync.py` (IPSYNC-DOC).** Fixed in `15b2f39`. The worked example
is kept in its FIXED form rather than deleted, as FLOOR asked: the weakness it
illustrates is real and still open in general, and `hw/package_mac_axi.tcl:36`
points back at the note by name, so deleting it would have broken a live
cross-reference in the other direction. VERIFIED at HEAD rather than trusted
from the WORKLOG entry. A sweep for siblings citing the same example found
**none**.

**(f) `frst` (AXIRD-FRST).** CONFIRMED at HEAD, NOT fixed, and the WORKLOG
entry's line numbers were stale -- A7's `abort_c` and `gate_chk` moved
everything down by 36 and more. Re-measured and refreshed; see section 5.7.

---

## 3. The procedure, in the order it was run

Each step says what it controls for.

1. **Read the RTL the row is about before writing the row.**
   `rtl/axi_rd_fsm.vhd`'s reset branch zeroes `outst`; `rtl/axi_rd_port.vhd:184`
   gates `f_iv` on `run_f`. That second line is why the row can be green today:
   stray beats arriving outside `S_RUN` are accepted and go nowhere. *Controls
   for writing a bench whose expected verdict is a guess.*
2. **Write the bench, run it, and let it fail.** The FIRST run FAILED, at
   `anear`, on its own `stray = 0` coverage assert. *Controls for the failure
   mode this whole file exists to prevent: a bench that passes because its
   stimulus never reached the condition.* It is worth stating that the coverage
   assert paid for itself on the very first run, before any control did.
3. **Diagnose the vacuity by measurement, not by adjusting constants until it
   goes green.** A throwaway instrumented copy counted AR accepts and `rlast`
   retirements on the AXI side and printed the outstanding count at the reset
   edge: `0`, `1`, `1`. *Controls for the tempting move of nudging RST_HOLD
   until the assert stops firing, which would have produced a row that was
   green and meaningless.*
4. **Fix the STIMULUS at its cause (`DEPTH`), then re-measure the outstanding
   count**: 3, 4, 4. *Controls for treating a symptom.*
5. **Run the BASE before any mutation.** A mutation sweep whose base does not
   work scores everything CAUGHT. Printed its verdict: PASS.
6. **Teeth-check the row against the defect it exists for** (control T).
7. **Run the attribution control the brief demands: do the EXISTING rows catch
   the same mutation?** (controls A1, A2.) A kill does not settle it.
8. **Run the control that could have made the DESIGN unnecessary** -- the
   reset hold (controls C, C2, C3). This is A7's own trap, taken deliberately:
   it said *"I had the fix designed before I ran the control that could have
   made it unnecessary"*. Here the control did not make the row unnecessary,
   but it **destroyed the stated reason for one of its constants**, which is
   the same lesson at lower stakes.
9. **Run the control that isolates the slave's reset-awareness** (control B),
   because that is the one variable the row is named after.
10. **Only then, probe the open item** (control E), which is what found
    STRAY-NEXTJOB.
11. **Commit the bench, THEN measure the floor from a clean `git archive` of
    that commit.** The floor is a clean-checkout number; measuring it from the
    working tree measures rows a clone does not get. *Controls for the mistake
    that produced an unreachable 101.*

---

## 4. Why the row is green today, stated as an argument that can be checked

The row asserts a value oracle on two jobs run AFTER a reset that abandoned a
third. That oracle holds today for one reason, and it is not that stray beats
do not arrive -- 27 to 32 of them do, MEASURED.

`rtl/axi_rd_port.vhd:184` is `f_iv <= rvalid when run_f = '1' else '0'`, and
`rtl/axi_rd_port.vhd:182` forces `rready` high outside `S_RUN`. So while the
FSM is in `S_IDLE` after the reset, stray beats are **accepted and discarded**:
they retire nothing (the FSM only decrements `promised` in `S_RUN`) and they
enter no FIFO. The only thing they do is carry `rlast`, and that is what
underflows `outst` -- which is exactly the defect the clamp fixes.

The row therefore separates cleanly into:

* **`strayl >= 1`** -- the precondition for the underflow. ASSERTED.
* **the value oracle on the following jobs** -- holds while the strays have
  finished before the next job reaches `S_RUN`. That is what `DRAIN_WAIT`
  buys, and control E measures what happens when it does not.

**The invariant that keeps the row green is "every pre-reset burst has returned
before the next `start`", and it is bought by a bench constant, not by the
design.** Saying so is the difference between "the row passes" and "the row
passes for a reason someone can check".

---

## 5. The evidence, as raw output

All runs used a hand-built GHDL harness over the exact closure `sim/regress.sh`
derives for this row (`rtl/util_pkg.vhd rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd
rtl/stream_fifo.vhd rtl/axi_rd_port.vhd sim/tb_axi_rd_port_stray.vhd`),
`--std=08`, `ghdl -r` (never `ghdl -e`). Each control tree is a full COPY; the
repository's `rtl/` was never modified.

### 5.1 The first run of the bench FAILED, on its own coverage assert

DEPTH was 16, copied from `sim/tb_axi_rd_port_dual.vhd`.

```
sim:tb_axi_rd_port_stray  FAIL  1  ...:483:9:@1369500ps:(report error):
  anear: COVERAGE -- NO beat of the abandoned job arrived after the reset,
  so the reset did not catch a burst in flight and nothing here was tested.
  Check RST_HOLD
  anear: COVERAGE -- no stray beat carried `rlast`, so no burst was retired
  against a zeroed `outst` and the clamp in rtl/axi_rd_fsm.vhd was never reached

anear: beats=83 stall=103 stray=0 strayl=0 err=1
aslow: beats=74 stall=152 stray=3 strayl=1 err=0
afast: beats=85 stall=93  stray=6 strayl=1 err=0
axi_rd_port_stray: 1 errors across 3 clock ratios
```

`aslow` and `afast` scraped through on ONE stray `rlast` each. Had `anear` not
been in the list, this row would have gone in green on a stimulus that was one
timing accident away from testing nothing.

### 5.2 The cause, measured rather than guessed

Instrumented copy, counting AR accepts and `rlast` retirements on the AXI side:

```
DEPTH = 16
anear: DBG at reset nar=7  nlast=7  outst=0
aslow: DBG at reset nar=6  nlast=5  outst=1
afast: DBG at reset nar=8  nlast=7  outst=1

DEPTH = 64
anear: DBG at reset nar=11 nlast=8  outst=3
aslow: DBG at reset nar=9  nlast=5  outst=4
afast: DBG at reset nar=14 nlast=10 outst=4
```

DERIVED: `rtl/axi_rd_fsm.vhd`'s AR throttle issues only while
`f_level + promised + want <= DEPTH`. At `DEPTH = 16` with `MAXB = 8`,
`promised` is already 8 after the first burst, so a second rarely fits. At
`DEPTH = 64` the guard is slack against `MAXOUT * MAXB = 32` and all four slots
fill.

### 5.3 BASE: the committed RTL and the committed bench

```
anear: beats=83 stall=103 stray=32 strayl=4 err=0
aslow: beats=74 stall=153 stray=27 strayl=4 err=0
afast: beats=85 stall=93  stray=30 strayl=4 err=0
axi_rd_port_stray: 0 errors across 3 clock ratios
PASS: tb_axi_rd_port_stray
```

Through `sim/regress.sh` in the working tree, alongside the two existing rows:

```
PASS  sim:tb_axi_rd_port         1s  ... 0 bad beats (QSTALL=0, occupancy upper bound 26 of DEPTH 64, R beats refused 0)
PASS  sim:tb_axi_rd_port_dual    1s  ... PASS: tb_axi_rd_port_dual
PASS  sim:tb_axi_rd_port_stray   0s  ... PASS: tb_axi_rd_port_stray
 OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

MEASURED runtime: **0 s**, third field. (A7 estimated ~1 s. The third field is
elapsed SECONDS, not a check count.)

### 5.4 The controls

Each varies exactly ONE thing against the committed tree, except `D` which is
the state the bench started in.

| | arm | verdict | numbers |
|---|---|---|---|
| **BASE** | committed RTL + committed bench | **PASS** | `strayl` 4 / 4 / 4 |
| **T** | `if os < 0 then os := 0; end if;` DELETED | **KILLED** | `bound check failure at ...axi_rd_fsm.vhd:250` (`outst <= os`), rc=1 |
| **A1** | clamp deleted, run `tb_axi_rd_port_dual` | **SURVIVED** | `0 errors across 4 clock ratios`, `PASS` |
| **A2** | clamp deleted, run `tb_axi_rd_port` | **SURVIVED** | `0 bad beats` |
| **B** | clamp deleted + slave made RESET-AWARE | **SURVIVED the RTL, CAUGHT by coverage** | `stray=1 strayl=0` at all three; the `strayl` assert fired |
| **C** | clamp deleted + `RST_HOLD = 20` | **KILLED** | same bound check |
| **C2** | committed RTL + `RST_HOLD = 20` | **PASS** | `strayl` 4 / 4 / 4 -- identical to BASE |
| **C3** | committed RTL + `RST_HOLD = 1` | **PASS** | `strayl` 4 / 4 / 4 -- identical to BASE |
| **D** | committed RTL + `DEPTH = 16` | **FAIL (coverage)** | `stray` 0 / 3 / 6, `strayl` 0 / 1 / 1 |
| **D2** | committed RTL + `DEPTH = 16` + `RST_HOLD = 20` | **FAIL (coverage)** | `stray` 0 / 3 / 6, `strayl` 0 / 1 / 1 -- IDENTICAL to `D` |
| **E** | committed RTL + `DRAIN_WAIT = 4` | **FAIL (value oracle)** | `BEAT got 3133 want 5120` and 9 more |

Read as six separate statements:

* **`T` gives the row its teeth.** Without the clamp the row dies at the exact
  statement A7 named.
* **`A1` and `A2` are the attribution, and they are the reason the row is worth
  its maintenance.** Both existing `axi_rd_port` rows SURVIVE the same
  mutation. The new row is not credited with a kill an existing property would
  have caught anyway.
* **`B` is the single load-bearing stimulus difference, and it is a DOUBLE
  result.** Give the bench a reset-aware slave and the mechanism vanishes:
  strays collapse from 27-32 to 1 and `strayl` to 0, so the unclamped RTL walks.
  **And the bench said so** -- the coverage assert fired rather than the run
  passing quietly. A bench that can be made vacuous and reports it is a
  different object from one that cannot.
* **`C`, `C2`, `C3` and `D2` DID NOT BITE, and that is the most useful group
  in the table.** Four arms varying only the reset hold, across BOTH depths:
  at `DEPTH = 64` holds of 1, 2 and 20 give an identical `strayl` of 4, and
  at `DEPTH = 16` holds of 2 and 20 give an identical `stray` of 0/3/6.
  **The reset hold is not the sensitive variable in this bench at either
  depth.** `D2` is the one that closes it: my first written explanation was
  "at `DEPTH = 16` a long hold could drain the single burst", which is a
  plausible sentence I had not measured. It is false. Recorded rather than
  discarded, and the bench's own comment was rewritten to say so.
  This does NOT overturn A7's section 7: that measured a 20-cycle hold going
  vacuous in `sim/tb_axi_rd_port_dual.vhd`, whose J7 reset lands where the
  job has already drained. It says the result does not carry over here.
* **`D` is the resolution floor of the stimulus**, and it is why `DEPTH` is 64.
* **`E` is a defect, not a control result.** See section 5.5.

### 5.5 Control E in full -- STRAY-NEXTJOB

Committed RTL, clamp present, `DRAIN_WAIT` 200 -> 4:

```
anear: BEAT got 3133 want 5120 -- a beat was DROPPED, DUPLICATED, REORDERED, or came from a burst issued BEFORE THE RESET and landed in this job's FIFO
anear: BEAT got 5120 want 3144 ...
aslow: BEAT got 3108 want 5120 ...
aslow: BEAT got 5120 want 3120 ...
afast: BEAT got 3155 want 5120 ...
afast: BEAT got 5120 want 3160 ...
anear: beats=84 stall=101 stray=5 strayl=0 err=4
aslow: beats=75 stall=148 stray=3 strayl=1 err=3
afast: beats=86 stall=92  stray=7 strayl=1 err=3
axi_rd_port_stray: 10 errors across 3 clock ratios
FAIL: tb_axi_rd_port_stray
```

Word 3133 is in the ABANDONED job's range (`JA_BASE = 3072`); word 5120 is the
new job's word 0. The consumer was handed the old job's beat first. The
mechanism, from `rtl/axi_rd_fsm.vhd`: after the reset `arv = '0'` and
`outst = 0`, so a following `start` satisfies `S_DRAIN`'s exit condition
(`arv = '0' and os = 0`) IMMEDIATELY, the four-phase clear runs, `S_RUN` is
entered, and pre-reset beats then arrive with `run_f = '1'` and are written to
the FIFO as the new job's.

On the FK33 the streamer's `rst` is `core_aresetn` while the HBM slave is reset
by the XDMA's `axi_aresetn`, so a slave that keeps its queue across the port's
reset is the SHIPPING case.

### 5.6 The full gate, unfiltered last `OVERALL` line, both trees

**CLEAN `git archive 2217778`**, `MV4I_FK33_FILE=/nonexistent`, `--jobs 2`,
2026-08-29 23:50 to 2026-08-30 00:1x. `REGRESS_REPO` confirmed on the LIVE
processes via `/proc/<pid>/environ` as `.../scratchpad/strayrow/arch`:

```
 suite sim   PASS 73   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 3
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 99   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4   SKIPPED 10
 baseline: 99 passing, above the recorded floor of 98 -- raise BASELINE_PASS in this script
 REGRESSION: PASS
```

**`BASELINE_PASS` 98 -> 99**, committed in `912ada7`. DERIVED and consistent:
103 rows selected, 4 NOCHECK, FAIL 0, so **99 is the CEILING and not merely
the score**. The gate printed the RAISE SUGGESTION rather than the refusal,
which is the evidence that its NOT-IN-GIT list was empty on this tree.

**98 + 1 = 99, and for once the prediction and the measurement agree.** A7
predicted 99 and the brief told me to measure rather than assume, because
FLOOR's identical arithmetic had been right four times and wrong on the fifth.
It was still measured. There is no way to know which case you are in except by
running it, and a floor set one below the ceiling is invisible until something
else goes missing.

The row itself in the archive run: `sim:tb_axi_rd_port_stray  PASS  1` (third
field is elapsed SECONDS).

**WORKING TREE**, `--jobs 2`, run immediately after on the same box:

```
 suite sim   PASS 81   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 107   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 REGRESSION: PASS
```

FLOOR measured 106 here; 107 is that plus this row. `sim:tb_axi_rd_port_stray
PASS 0` (0 s in the working tree, 1 s in the contended archive run).

**This run launched before `912ada7`, so its note reads "above the floor of
98".** It also shows the deliberate refusal working, which is worth capturing
because it is the mechanism that produced an unreachable 101 when it was
absent:

```
 baseline: 107 passing, above the floor of 98 -- but this tree has rows a clean
 checkout does not get: sim:tb_attn_cmp2 sim:tb_attn_fix_beh ... sim:tb_matvec_fk33
 sim:tb_matvec_fk33_desc sim:tb_matvec_fk33_desc_dual sim:tb_matvec_fk33_desc_xexp.
 DO NOT raise BASELINE_PASS from this run: the floor is a CLEAN-CHECKOUT number,
 and a floor raised to include rows that depend on your working tree or your
 model set is unreachable for everybody else, including you after a clean clone.
```

**The two runs reconcile exactly**, which is worth doing rather than assuming,
because it is the check that would catch a row silently disappearing from one
of them. The list has 22 entries; by verdict in the working-tree run they are
8 PASS (`tb_rope_ps`, `tb_engine_dump`, `tb_attn_fix_beh`,
`tb_attn_replay_beh`, and the four `tb_matvec_fk33*` OPTIONAL rows), 1 NOCHECK
(`tb_rms_sweep`), and 13 SKIP. So:

* PASS: 99 + 8 = **107**
* NOCHECK: 4 + 1 = **5**
* SKIPPED: 10 - 4 (the `fk33` rows stop skipping once the model set is
  present) + 13 = **19**

All three match the working-tree line. **The refusal was NOT worked around**;
the floor was set from the archive run, where the list was empty and the gate
printed the raise suggestion instead.

### 5.7 AXIRD-FRST, re-measured at HEAD

```
$ grep -n frst rtl/axi_rd_port.vhd
157:  signal frst    : std_logic;
239:    frst    <= rst;
309:    frst  <= rst_s2;
357:      port map(clk => aclk, rst => frst, start => start_f,
367:      port map(wclk => aclk, wrst => frst,

$ grep -n "generate" rtl/axi_rd_port.vhd
236:  g_sc : if not DUAL_CLK generate
273:  end generate;
276:  g_dc : if DUAL_CLK generate
372:  end generate;
```

DERIVED: `:239` is inside `g_sc` (`:236`-`:273`); `:309`, `:357` and `:367` are
all inside `g_dc` (`:276`-`:372`). Exactly one generate elaborates. So under
`DUAL_CLK = false` the signal is driven and **never read**, and the `g_sc` FSM
and FIFO both take `rst => rst` directly (`:246`, `:259`).

**FLOOR's recorded line numbers (`:203`, `:241`, `:282`, `:292`) are STALE** --
`75f95a8` inserted `abort_c` and the `gate_chk` process into the same file. The
finding and the warning are both unchanged: **the safe deletion is the `g_sc`
driver (now `:239`); deleting the `g_dc` one (now `:309`) breaks the dual-clock
path.** NOT FIXED here: `rtl/**` was outside this track's ownership.

### 5.8 IPSYNC-DOC, verified at HEAD rather than trusted

```
$ git log --oneline -1 -- hw/package_mac_axi.tcl
d2adbcd package_mac_axi/package_matvec_engine: the CLOCK_ASSOC readback exited non-zero after succeeding

$ git status --porcelain -- hw/package_mac_axi.tcl hw/package_matvec_engine.tcl
(empty)

$ python3 ip_repo/check_ip_sync.py --selftest | tail -3
CHECK ALONE=6
SELFTEST PASS

$ python3 ip_repo/check_ip_sync.py
IPSYNC: 3 IP(s), 32 packaged .vhd, 0 finding(s) [rules: STALE,NOSRC,NOSCRIPT,UNLISTED]
IPSYNC: PASS
```

Sibling sweep, for the same worked example:

```
$ grep -rn "ASSOCIATED_BUSIF" --include=*.py --include=*.tcl --include=*.sh --include=*.md .
```

returns `ip_repo/check_ip_sync.py` (the one fixed), the two packaging scripts
(both fixed), `hw/build_bringup.tcl` and `hw/fk33/build_fk33_pcieep.tcl` (the
BLOCK-DESIGN spelling, which is correct and unrelated), and
`docs/debugging/*` (historical records, corrected in place by their own tracks,
not edited here). **No sibling cites the fixed defect as live.**

---

## 6. Measured and REJECTED -- do not retry

* **"A one-cycle reset is what makes the stray row bite."** REJECTED, and this
  is the brief's own premise and A7's section 8b. Controls `C`, `C2`, `C3`,
  `D2`: holds of 1, 2 and 20 core cycles give an identical `strayl` of 4 at
  every ratio on the committed RTL at `DEPTH = 64`, holds of 2 and 20 give
  identical numbers at `DEPTH = 16`, and a hold of 20 still kills the
  unclamped RTL. **Do not tune `RST_HOLD` hoping to strengthen the row.**
  The sensitive variable is `DEPTH`.
* **"At `DEPTH = 16` the long hold is what drains the single outstanding
  burst."** REJECTED -- and it was MY OWN sentence, written into the bench
  before it was measured. Control `D2` gives numbers identical to `D`.
* **"Copy `sim/tb_axi_rd_port_dual.vhd`'s constants."** REJECTED. Its
  `DEPTH = 16` makes the AR throttle carry at most one burst in flight, so at
  `anear` the reset caught nothing and the row tested nothing. Measured
  outstanding counts 0/1/1 against 3/4/4 at `DEPTH = 64`.
* **"The existing `axi_rd_port` rows already cover this."** REJECTED, measured.
  Controls `A1`/`A2`: both PASS with the clamp deleted.
* **"A7's section-8 stray-beat path is theoretical."** REJECTED. Control `E`
  reproduces it on the COMMITTED RTL at all three clock ratios with a specific
  wrong word. It is now STRAY-NEXTJOB on the board.
* **"Shrink `DRAIN_WAIT` so the gate row also covers STRAY-NEXTJOB."**
  REJECTED, deliberately, and it is a judgement rather than a measurement: the
  gate is shared, the defect has no decision, and a permanently red row is a
  tax on nineteen other tracks for a finding they cannot act on. The oracle is
  in the file and one constant turns it on.
* **"Delete the stale worked example from `check_ip_sync.py`."** REJECTED.
  FLOOR asked for it to be marked fixed, not removed; the weakness it
  illustrates is still open in general, and `hw/package_mac_axi.tcl:36` points
  back at the note by name.

---

## 7. Measurement traps hit, including my own

* **The one I walked into, and it is A7's trap wearing a different hat.** A7's
  lesson was *"run the control that could have made the work unnecessary
  FIRST"*. I ran mine -- and it did not make the WORK unnecessary, it made the
  stated JUSTIFICATION for one of the bench's constants false. I had already
  written a fifteen-line derivation for `RST_HOLD = 2` about crossing the CDC
  and about long holds draining the bursts, complete with arithmetic, before
  measuring that 1 and 20 behave identically. **A derivation that is internally
  correct can still be an explanation of something that is not happening.** The
  comment now says what the constant actually buys, which is much less.
  **And I then did it a SECOND time in the same file.** The replacement comment
  said "at `DEPTH = 16` the port only ever had one burst in flight, so a long
  hold could drain it" -- a plausible sentence, written to explain away A7's
  result, which I had not measured either. Control `D2` says it is false: at
  `DEPTH = 16` a 20-cycle hold gives numbers identical to a 2-cycle one. The
  correction is in the bench. **The pattern to watch for is a sentence that
  reconciles your measurement with someone else's without a measurement of its
  own; it is the most comfortable kind of claim to write and the least
  supported.**
* **The coverage assert fired before any control did, and that is the whole
  argument for writing it first.** The first run of this bench was RED at
  `anear` with `stray = 0`. Two of the three ratios passed on a single stray
  `rlast`. Without the witness the row would have been committed green,
  measured as green in the floor run, and been a decoration at two ratios and
  worthless at the third.
* **`aslow` and `afast` passing while `anear` failed looks like a flaky bench
  and is not.** The temptation is to treat one failing ratio out of three as
  noise. It was the only ratio telling the truth.
* **A `git archive` floor run must come AFTER the commit, not before.** The
  planner globs `sim/tb_*.vhd` off the FILESYSTEM, so an untracked bench is a
  gate row for the holder and for nobody else. Committing first is what makes
  the archive contain the row.
* **`regress.sh` re-execs from a temp copy.** Verified `REGRESS_REPO` on the
  LIVE processes via `/proc/<pid>/environ` and got
  `.../scratchpad/strayrow/arch`, not the working tree.
* **The box was NOT quiet.** TRACK DONE1 was running its own `regress.sh`
  (`REGRESS_REPO=.../done1/teeth/run.DEFECT`) and COMPOSE4 a place-and-route.
  Load average ran 7.3 to 9.5 during the floor run. Stated BEFORE relying on
  it, per FLOOR's argument: contention can starve a row into TIMEOUT but cannot
  make a failing row pass, so a contended clean-archive run is a valid LOWER
  bound on the ceiling, and a floor set from a lower bound is conservative
  rather than unreachable.
* **`ghdl -r ... | head` reports the PIPELINE's status.** The harness redirects
  to a file and reads `${PIPESTATUS[0]}` rather than piping.

---

## 8. Open, not yet answered

* **STRAY-NEXTJOB is reproduced but not decided.** The fix is a fork with
  opposite costs depending on whether the slave shares the reset net (A7's
  section 6), and one track should not choose. It is on the board.
* **What the shipping flow does with `core_aresetn` mid-job is not
  established.** STRAY-NEXTJOB needs a reset while `busy` is high followed by a
  restart inside the drain window. Whether `hw/fk33/host/` can even produce
  that sequence was NOT investigated -- it is on the far side of the hardware
  boundary and this track did not go near it. A7's section 9 card experiment
  remains the way to settle it.
* **`AXIRD-FRST` is still not fixed**, by design. Fourth finding, second
  re-measurement.
* **The row's value oracle has never been shown to catch a MISALIGNMENT other
  than the one control E produces.** It is a strict word-index oracle so it
  should, but that is DERIVED from its structure, not measured.
* **Nothing here was synthesised.** The claim that an underflowed `outst` is a
  permanent AR stall in hardware is A7's, carried forward from its reading of
  the RTL; this track added no Vivado evidence for it.
* **Nothing here was run on hardware.**

---

## 9. Corrections to the brief

* **"a `one-cycle` reset mid-flight ... your bench turns on a one-cycle reset
  for exactly this reason; get that wrong and it will pass vacuously."**
  Withdrawn as to causation. The reset width is not what makes it bite (section
  6, controls `C`/`C2`/`C3`). The bench CAN pass vacuously -- the first run
  did -- but the variable that does it is `DEPTH`, and the thing that caught it
  was the coverage witness, not the choice of hold.
* **"`BASELINE_PASS` 98 -> 99"** (A7's estimate, repeated in the brief).
  CONFIRMED, not corrected. MEASURED 99 on a clean archive. It is the one
  prediction here that held, and measuring it was still right.
* **"`frst` ... driven at `:203` (in `g_sc`), read only at `:282` and `:292`."**
  Correct as a FINDING, stale as line numbers at HEAD. Now `:239`, `:357`,
  `:367`, with the `g_dc` driver at `:309` (section 5.7).
