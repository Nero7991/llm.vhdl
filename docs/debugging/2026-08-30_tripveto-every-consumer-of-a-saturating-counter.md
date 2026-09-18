# TRIPVETO: every consumer of the thermal trip counter, and which of them die at 255

**Date:** 2026-08-30
**Tree:** `639880e2ee6c4ead37d48d53a659c908e1267091` at dispatch (HEAD moves constantly).
**Card:** SQRL FK33, `xcvu33p-fsvh2104-2L-e`. **No hardware was touched. No host
tool was invoked at all** -- see "Hardware boundary" below.
**Status:** THIS IS THE ENUMERATION HALF ONLY. **No code was changed.** The
fix to `hw/fk33/host/fk33_run_job.py` is designed and argued below but is NOT
in the tree, because a hazard found while designing it (section 5) makes the
obvious form a regression in a second file. A reboot cut the window.

## The question, verbatim

> `hw/fk33/host/fk33_run_job.py`'s thermal veto rests on `trip_cnt`, and that
> counter SATURATES at 255. So once the counter reaches 255, the veto's
> `trip1 != trip0` test is false forever, while the tool still cheerfully
> prints `trips=255 (was 255)`. Fix the veto; enumerate every OTHER consumer
> of `trip_cnt` and say which of them have the same defect; decide, and argue,
> whether the RTL saturation is itself wrong.

## The answer, up front

**Three answers, in the order they are cheapest to act on.**

1. **The saturation defect has SIX consumers, in four files, and they are not
   all the same defect.** Two are false-PASS vetoes (`fk33_run_job.py`,
   `fk33_run_token.py`), two are silent under-reports, one is an INVERTED
   defect that produces a false FAIL rather than a false pass
   (`therm_selftest.py`), and one is already defended
   (`fk33_stripe_experiment.py`, TRACK STRIPEREADY's, not mine). The full
   table is section 2. `fk33_run_layer.py`, `fk33_load_weights.py` and
   everything under `server/` are **not** consumers, checked and named so
   nobody re-checks them.

2. **The RTL saturation at `fk33_thermal.vhd:1166` is CORRECT and must not be
   changed.** MEASURED: it is the only choice that keeps the counter
   monotone, and monotonicity is the entire property every host veto rests
   on. Wrapping would make `trip1 != trip0` fail at a *multiple of 256*
   instead of at a threshold, which is strictly worse because it is
   unbounded in time rather than one-shot. The defect is not in the counter.
   **The defect is that six consumers read a saturating counter as if it were
   an unbounded one.** Argument in section 4.

3. **The fix belongs in the host and its shape is already settled by
   STRIPEREADY**: clear the counter and refuse unless the post-clear word
   reads 0. What stopped it landing is section 5, and it is a real finding,
   not an excuse: **applying that shape inside `fk33_run_job.py` silently
   breaks `fk33_run_token.py`**, whose retry wrapper reads the counter around
   the very call that would now clear it.

## 1. Hardware boundary

**No host tool was run, so there is nothing to `strace`.** The complete set of
commands issued by this track was `git rev-parse`, `git log`, `git status`,
`grep`, `sed`, `wc`, `ls`, `mkdir`, `free`, `uptime`, `python3 -c` on two
integer expressions, and the write of this file. None of them can open
`/dev/xdma*`, no `xsdb`, no `hw_server`, no `vivado`, no `hw/fk33/*.sh`, no
`hw/fk33/tcl/*`.

**This is a weaker claim than a traced run and is stated as such.** The
proof-of-tracer line the brief asks for is owed by whoever lands the code
change, because that is the first point at which a host tool is invoked.

## 2. Every consumer of `trip_cnt`, and its verdict

The field is `THERM_STATUS[23:16]`. The search that produced this table is

```
grep -rn 'THERM_STATUS\|THERM_TRIP\|trip_cnt\|TRIP_COUNT\|>> 16) & 0xFF' \
     --include=*.py --include=*.sh --include=*.c --include=*.h \
     --include=*.tcl --include=*.vhd hw/ server/ tools/ ref/ sim/ tb/
```

with `hw/fk33/results/` and the RTL itself excluded. **The starting grep in the
brief (`hw/fk33/host/ server/ tools/` on `trip_cnt|trips=|trip1|trip0`) misses
three of the six**, because `fk33_run_token.py` names its variables `t0`/`t1`
and `trips0`/`trips1`, `therm_selftest.py` names them `trips_before`/
`trips_after`, and `aux_probe.tcl` is Tcl under `hw/fk33/tcl/`. Widening to
the register name is what found them.

| # | file:line | what it does with the count | verdict at 255 |
|---|---|---|---|
| 1 | `hw/fk33/host/fk33_run_job.py:909, 1000-1001` | `trip0`, `trip1`, `moved = trip1 != trip0`; `moved` turns PASS/FAIL into INCONCLUSIVE at :1010, :1021, :1074 | **FALSE PASS.** The veto is dead. :926 prints a `warn` naming the saturation and then **proceeds anyway** -- a warning is not a refusal |
| 2 | `hw/fk33/host/fk33_run_token.py:737-738, 748, 775-776` | `_trips(bar)` around each job; `if t1 == t0 or res[0] == PASS` decides whether to retry and whether to log a trip | **FALSE PASS.** `t1 == t0` is true forever, so no trip is ever logged and no retry ever fires for a trip |
| 3 | `hw/fk33/host/fk33_run_token.py:980-981, 1044-1045, 1352` | whole-run `trips0`/`trips1`, printed as `THERM-255 trip counter %d -> %d` with `<-- MOVED` | **SILENT UNDER-REPORT.** Prints `255 -> 255` with no `MOVED` and no saturation note. The adjacent paragraph correctly warns the count is a lower bound *because of sampling*, and never mentions the ceiling |
| 4 | `hw/fk33/host/therm_selftest.py:256, 294-297` | `trips_before`/`trips_after`; `if trips_after == trips_before: fail.append("halted, but the trip count did not move")` | **INVERTED -- a false FAIL, not a false pass.** This test *wants* the counter to move. At 255 it reports the guard as broken when the guard worked. Less dangerous than 1 and 2, and it is the only consumer whose failure direction is safe |
| 5 | `hw/fk33/host/fk33ctl.py:358` | `print(f"trips since the last clear: {(st >> 16) & 0xFF}")` | **SILENT UNDER-REPORT.** 255 means "at least 255" and the line says "255" |
| 6 | `hw/fk33/tcl/aux_probe.tcl:114-116` | `%d trips since the last clear`, over JTAG | **SILENT UNDER-REPORT.** Same as 5, on the path that does not depend on the PCIe link |
| -- | `hw/fk33/host/fk33_stripe_experiment.py:227-260` | clears the counter and refuses unless the post-clear word reads 0 | **DEFENDED.** TRACK STRIPEREADY's, and explicitly not mine to edit |

**Checked and NOT consumers** -- recorded so the next track does not re-derive
this: `hw/fk33/host/fk33_run_layer.py` (`grep -c THERM_STATUS` = **0**; it
inherits the veto entirely from `fk33_run_job.run_job`),
`hw/fk33/host/fk33_load_weights.py`, `server/*.c`, `server/*.h` (the only
thermal thing there is `FK33_SEAM_ERR_HALT` at `server/fk33_seam.h:418`, which
is the *halt*, not the counter), and everything under `tools/`.

### 2a. The existing test fixture cannot see this defect

`hw/fk33/host/tests_fk33ctl.py:137` pins `THERM_STATUS = 0x8A0377CD`.

```
DERIVED: (0x8A0377CD >> 16) & 0xFF = 0x03 = 3 trips
         (0x0A0377CD >> 16) & 0xFF = 0x03    (the no-guard variant at :175)
```

**Both fixtures sit at 3.** So `fk33ctl.py`'s decode is exercised only at a
value where saturation is invisible. This is the brief's own warning made
concrete: *a veto that works at `trip_cnt = 3` and fails at 255 is the defect,
and a test that only exercises small counts reproduces it.* The fixture is not
wrong; it has simply never been asked the question. **Any fix must add a 255
fixture, and adding that fixture alone -- with no code change -- is a
worthwhile commit, because it makes the defect visible in a test rather than
in a document.**

### 2b. `fk33_run_job.py` already contains the answer and does not act on it

`hw/fk33/host/fk33_run_job.py:926`:

```
    if trip0 == 255:
        w("warn        the trip counter is at its 8-bit SATURATING maximum, so "
          "'it did not move' cannot be observed on this run.  Clear it first: "
          "fk33ctl.py thermal --clear\n")
```

The text is exactly right and the control flow ignores it. **This is the
project's "guard that passes for the wrong reason" class in its purest
observed form: the tool knows the measurement is void, says so in prose, and
then prints a verdict derived from it.** A reader who trusts the VERDICT line
-- which is what every automated consumer does -- never sees the warning.

## 3. What would make the new check FAIL

The brief asks this and it is the question the existing warning was never
asked. For the check designed in section 5, the answer is:

* the clear write does not take (wrong register, wrong key, dead bus) --
  caught, because the post-clear read-back is required to be 0 and the
  observed transition is nonzero -> 0;
* the counter is stuck at 0 (a broken instrument) -- **NOT caught**, and this
  is a genuine residual hole, named in "open" below;
* the guard is absent (`THERM_STATUS[31] = 0`) -- the count field is not a
  measurement at all, and the check must say so rather than pass;
* the BAR is unmapped (`0xFFFFFFFF`) -- bit 31 reads 1 and the count reads
  255, so the clear cannot take and the check refuses. **This is the one case
  where the new check is strictly better than the old one for a reason that
  has nothing to do with temperature.**

## 4. Item 3: the RTL saturation is CORRECT. Do not change it.

`hw/fk33/rtl/fk33_thermal.vhd:1166-1168`, read in this tree today:

```vhdl
        if trip_cnt /= to_unsigned(255, trip_cnt'length) then
          trip_cnt <= trip_cnt + 1;
        end if;
```

**Recommendation: leave it exactly as it is.** No rebuild. The argument, and
it is an argument against my own first instinct:

* **Saturating is the only option that preserves monotonicity, and
  monotonicity is what every host consumer actually relies on.** `trip1 !=
  trip0` is sound for any monotone non-decreasing counter with a known
  ceiling; the host merely has to know where the ceiling is. Wrapping breaks
  monotonicity and turns a one-shot, permanently visible failure (pinned at
  255, detectable by a single comparison) into a **recurring, invisible** one
  (equal readings whenever exactly 256 trips land between two samples). The
  saturated form is loud; the wrapped form is silent. Given a choice between a
  broken instrument that is stuck and one that lies periodically, stuck is
  correct.
* **Widening the field does not fix it, it postpones it.** A 16-bit counter
  saturates at 65535. MEASURED in
  `docs/debugging/2026-08-30_therm255-is-two-stacks-not-two-copies.md`
  CORRECTION 2, the card reached 255 from 2 inside a 1500 s probe with 30
  crossings/s; DERIVED at that rate 65535 would take about 4.5 hours, and at
  the earlier 0.24 crossings/s segment it would take weeks. **Any fixed width
  has a rate above which it saturates.** A host that reads the ceiling
  correctly works at 8 bits; a host that does not, fails at 64.
* **The register field is 8 bits wide by the block-design contract**
  (`THERM_STATUS[23:16]`, `hw/fk33/host/fk33_regs.h:80`). Widening the counter
  without widening the field just moves the truncation from the RTL to the
  read path, where it is *less* visible.
* **There is a clear-to-zero path already** (`THERM_CTL` with key `0xC1EA`,
  bit 0, `fk33_regs.h:59-65`), which is the RTL's own answer to saturation and
  is what STRIPEREADY uses. A counter that can be cleared on demand does not
  need to be unbounded.
* **The one change that WOULD be worth a rebuild is not to the counter.**
  It is a sticky `trip_cnt_sat` bit -- one flip-flop, set when the increment
  is suppressed -- so that a host reading `255` can distinguish "exactly 255"
  from "at least 255" **without having to clear first**. That is strictly
  additive, costs one FF and one status bit, and closes consumers 3, 5 and 6
  (the silent under-reports) which no host-side change can close, because
  clearing destroys the very history they are reporting. **Recommendation
  only. It is not worth a rebuild on its own** and should ride along with the
  next `fk33_thermal.vhd` change, whatever that turns out to be.

**Where I was wrong.** I opened this expecting to recommend widening the
counter. The measurement above kills that: widening changes the time-to-fail
and not the failure mode, and I would have shipped a rebuild that made the
defect rarer and therefore harder to find. The brief's framing -- *"saturating
is a defensible choice for a counter that must not wrap"* -- is correct and I
am agreeing with it after trying to disagree.

## 5. The fix, and the hazard that stopped it landing

**Designed, argued, NOT written.** The shape is TRACK STRIPEREADY's, applied
one level down (`hw/fk33/host/fk33_stripe_experiment.py:227`):

1. read `THERM_STATUS`; if bit 31 is clear there is no guard and the count
   field is not a measurement -- say so and do not pretend to veto;
2. if the count is nonzero, write `THERM_CTL = (0xC1EA << 16) | 1`, then 0
   (edge-triggered, exactly as `fk33ctl.py:380-382` does), re-read, and
   **REFUSE unless the post-clear count is 0**;
3. refuse outright at 255 when clearing is disabled, instead of the present
   `warn`-and-continue;
4. after the job, when the count is at 255, print it as a lower bound.

Doing it through the `bar` object the tool already holds -- rather than
shelling out to `fk33ctl.py` -- is what makes `--dry-run` exercise it, which
is the only way the 255 case can be constructed offline. `SimBar._therm_word`
at `fk33_run_job.py:711` **already models the saturation** (`min(self.trip,
255)`), so the mutant is `dict(trip0=255, trip_during=1)` and today it yields
`PASS`. That single row is the whole teeth-check and it was one line away.

**THE HAZARD, and it is why this is not in the tree.**
`hw/fk33/host/fk33_run_token.py:748-775` wraps `fk33_run_job.run_job`:

```python
            t0 = _trips(bar)
            try:
                res = _ORIG_RUN_JOB(p, regs_, bar, hbm, a, out)
            ...
            t1 = _trips(bar)
            if t1 == t0 or res[0] == J.Verdict.PASS:
```

**If `run_job` clears the counter, `t1 < t0` on every job**, so `t1 != t0` is
true, and `run_token` logs a phantom trip and burns a retry on **every single
job of every layer of every token**. The naive fix converts a dead veto into
a live false alarm, which is worse: it would make a whole-token run appear to
be tripping constantly and would be read as evidence about THERM-255 itself.

The fix for that is structural, not a patch: `run_job` must publish its
observation on a channel the wrapper can read -- `p["therm"] = dict(trip0=,
trip1=, moved=, cleared=)` on the plan dict the caller already owns -- and
`run_token` must consume that instead of sampling the register around the
call. `run_token`'s own comment at :770 explicitly forbids the lazy
alternative, and it is right to:

> Read the counter, do not read run_job's prose: [...] a check that depended
> on another module's wording would stop working without saying so.

A structured field is not prose and satisfies that rule. **But it is a
two-file change with a hardware-only consumer, and I will not land half of it
before a reboot.**

## Measured and REJECTED -- do not retry

* **"Widen `trip_cnt` to 16 bits."** REJECTED, section 4. DERIVED from the
  MEASURED 30 crossings/s: it buys ~4.5 hours and changes nothing about the
  failure mode. It also requires a bitstream rebuild, which is not a track's
  call.
* **"Let `trip_cnt` wrap instead of saturating."** REJECTED, section 4.
  Trades a permanent, detectable failure for a periodic, undetectable one.
* **"Just make `fk33_run_job.py:926`'s warning a refusal and stop there."**
  REJECTED as insufficient, though it is a strict improvement and is the
  correct fallback if the clear path cannot be landed. It closes consumer 1
  only, leaves the tool unusable on the current card until somebody clears by
  hand, and does nothing for consumers 2-6.
* **"Have `fk33_run_job.py` shell out to `fk33ctl.py thermal --clear`, the way
  `fk33_stripe_experiment.py` does."** REJECTED. It would open a second
  mapping of `/dev/xdma0_user` while the tool holds one, and -- decisively --
  it is unreachable from `--dry-run`, so the 255 case could never be
  constructed offline and the guard could never be teeth-checked. STRIPEREADY
  is right to do it that way because it is a *driver of subprocesses* and owns
  no BAR; `fk33_run_job.py` is not, and owns one.
* **"`grep -rn 'trip_cnt\|trips=\|trip1\|trip0' hw/fk33/host/ server/ tools/`
  is the enumeration."** REJECTED as incomplete: it finds three of six. See
  section 2.

## Measurement traps hit, including my own

* **I nearly reported `therm_selftest.py` as a sixth false-pass.** It is the
  opposite: it asserts the counter MUST move, so saturation makes it fail a
  working guard. **Grouping consumers by "reads the counter" rather than by
  "which way it is wrong" would have put a false-FAIL and a false-PASS in the
  same bucket and produced a wrong remediation for one of them.** The failure
  *direction* is the load-bearing column in that table, not the file name.
* **The brief's own starting grep misses half the consumers**, and I ran it
  first and briefly believed it. Variable names are not a search key;
  the register name is. Recorded as a correction to the brief, per its
  request.
* **`fk33_run_job.py` prints a correct warning about exactly this defect**, so
  a reader grepping for "does this tool know about saturation?" gets a hit and
  moves on. **Presence of the right words is not presence of the right control
  flow.** I lost several minutes convinced the file was already defended.
* **Line 1166 of `fk33_thermal.vhd` is not where the brief's other cited
  defect lives any more.** The capture-a-cycle-late defect described in
  `2026-08-30_therm255-is-two-stacks-not-two-copies.md:63-87` has since been
  FIXED in this tree (`fk33_thermal.vhd:1146-1160` now documents the old
  `halted='1' and halted_d='0'` form as historical and uses the combinational
  hot term). **The write-up's "nothing here is fixed" line at :262 is stale
  FOR THE RTL IN THE TREE.** It remains true for the bitstream on the card,
  which predates that change and still carries both defects -- so the sentence
  is half right, which is the hardest kind of stale line to catch. Reading the
  document as wholly current would have had me argue against a defect that is
  gone from the source. The RTL wins; the document is what was out of date.

## Open, not yet answered

* **The fix itself is not in the tree.** Nothing in `hw/fk33/host/` was
  changed by this track. Consumers 1-6 all still carry the defect they carry
  in the table above.
* **A counter stuck at 0 is indistinguishable from a quiet card**, and the
  designed check does not close that. Clearing proves the *write* path when
  the count was nonzero; when it already reads 0 nothing is exercised and the
  0 is taken at face value. The only tool that proves the counter can move is
  `therm_selftest.py`, which needs the card and deliberately trips the guard.
  **Named, not solved.**
* **Neither the teeth table nor the attribution control was run**, because no
  code was written. The row that must be added is
  `("trip counter saturated at 255", dict(trip0=255, trip_during=1),
  Verdict.REFUSED)` in `cmd_selfcheck`'s table at `fk33_run_job.py:1199`, and
  the attribution control is that same mutant with the new check disabled,
  which must yield `PASS` -- i.e. must be shown to be caught by *nothing* that
  exists today.
* **`SimBar._status` has a latent obstacle to that row.**
  `fk33_run_job.py:774` fires the injected in-job trip only when `self.trip ==
  self.f.get("trip0", 0)`. After a clear, `self.trip` is 0 and `trip0` is 255,
  so **the injected trip would never fire and the new row would pass for the
  wrong reason.** The model needs a `tripped` flag instead of that comparison.
  Found by reading, not by running; it is exactly the shape of a mutant that
  fails to bite while looking like it bit.
* **Whether `aux_probe.tcl` should be touched at all.** It is under
  `hw/fk33/tcl/`, which this track may not run, and its defect is
  presentational. Left alone deliberately.
* **The `trip_cnt_sat` sticky bit** (section 4) is a recommendation with no
  owner and no scheduled rebuild to ride along with.

---

## CORRECTION 2026-09-17: the fix is LANDED, and two of this document's predictions were wrong in opposite directions

Commit `5e8495d`. Everything section 5 designed is now in the tree, all six
consumers, plus the section 2a fixture. **The withdrawn claim is only the
status line: "designed, argued, NOT written" and "the fix is designed but NOT
landed" no longer describe the tree.** Every technical judgement in sections
1-4 survives unchanged, including the one that matters most: **the RTL
saturation is CORRECT and was not touched.**

### What was predicted correctly, and it saved a wrong result

Section "open, not yet answered" said `SimBar._status` fires the injected
in-job trip only when `self.trip == self.f.get("trip0", 0)`, so after a clear
the equality is false, **the injected trip would never fire, and the new row
would pass for the wrong reason.** MEASURED: that is exactly what happened on
the first run.

```
saturated, then a trip         INCONCLUSIVE   PASS           MISMATCH
```

It was found by reading rather than by running, and the note is why the PASS
was recognised as a broken model rather than as a working tool. The fix is the
`tripped` latch this document asked for. **The general form: an injection
predicated on the state NOT having been touched cannot survive a change that
touches it, and it fails silently in the flattering direction.**

### PREDICTION WRONG 1: the new row's verdict is INCONCLUSIVE, not REFUSED

This document specified
`("trip counter saturated at 255", dict(trip0=255, trip_during=1), Verdict.REFUSED)`.
MEASURED, it is **INCONCLUSIVE**, and REFUSED is a *different* row.

The reasoning that produced REFUSED assumed the tool would refuse to run at the
ceiling. What it actually does is CLEAR the counter, which is the whole point:
the base is then 0, the injected trip is visible as 0 -> 1, and the job runs
and comes out INCONCLUSIVE exactly as an ordinary in-job trip does. REFUSED is
right only when the clear itself does not take, which is now its own row
(`clear_refused=True`). **Two rows, not one, and the distinction is the
difference between "cannot measure" and "measured a trip".**

### PREDICTION WRONG 2: `aux_probe.tcl` was touched, and should have been

"Left alone deliberately" on the grounds that its defect is presentational and
its directory was out of scope. That reasoning does not hold up: it is the
readout on the **JTAG** path, i.e. the one that still works when PCIe does not,
which is precisely when someone is reading a trip count under pressure. The
change is three lines and prints `255 OR MORE (SATURATED)`.

### The attribution controls, MEASURED

Each was produced by reverting ONLY the named change in the working tree and
re-running, then restoring from a saved copy.

`fk33_run_job.py selfcheck`, control = clear-and-prove removed, SimBar latch
fix KEPT, so the control isolates the tool change rather than the model change:

| row | with the fix | control |
|---|---|---|
| saturated, then a trip | INCONCLUSIVE | **PASS** |
| saturated, clear refused | REFUSED | **PASS** |
| counter at 7, cleared | PASS | PASS |

The third bites in neither arm and is listed under its own name in the
do-not-bite output. It is a control, not a tooth, and discarding it would hide
that the clear path is exercised in the ordinary case too.

`fk33_run_token.py selfcheck`, control = the OLD sampling wrapper. **The
halt-retry wrapper had no coverage at all before this**; these are its first
rows, and they measure the hazard section 5 predicted rather than asserting it:

| row | new wrapper | control (sampling) |
|---|---|---|
| a cleared counter is not a phantom trip | 1 call / 0 trip | **1 call / 1 trip** |
| a real in-job trip is still retried | 3 call / 3 trip | 2 call / 1 trip |
| run_job publishing no `p['therm']` refuses | refused | **returned** |

Row 1 is the phantom trip, measured: a job that merely cleared the counter is
logged as a thermal trip by the old wrapper. Row 2 exists so row 1 cannot be
satisfied by a wrapper that has simply gone deaf.

`tests_fk33ctl.py`, 48 checks, control = the `fk33ctl.py` line reverted with
the fixture kept: exactly the two new rows fail, and the `trip_cnt = 3` control
row (which must NOT print the saturation note) passes in both arms.

### Also found, and fixed, while writing the teeth

`_wait_clear` raised `ZeroDivisionError` on `poll_s = 0` -- a legitimate
caller intent, "do not sleep at all" -- **before the job ran**, and therefore
indistinguishable from a guard refusal at the call site. It was reached by a
teeth row passing `poll_s=0.0`, not by any hardware path.

### Still open

* **Nothing here has run against the card.** Every row above is the simulated
  register plane. The clear-and-prove writes `THERM_CTL` for the first time
  from this tool, and that write has never been issued to silicon.
* **The `trip_cnt_sat` sticky bit** (section 4) is still a recommendation with
  no owner. Unchanged.
* **`fk33_run_layer.py` remains a non-consumer** and inherits the fixed veto
  through `fk33_run_job.run_job`. Re-checked, still 0 matches on
  `THERM_STATUS`.
