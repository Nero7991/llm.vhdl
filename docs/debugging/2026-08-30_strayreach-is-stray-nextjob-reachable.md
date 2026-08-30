# STRAYREACH: is STRAY-NEXTJOB reachable on the card, and does the HBM slave share the reset

**Date:** 2026-08-30
**Track:** STRAYREACH, following TRACK STRAYROW (`679128e`) and TRACK A7 (`75f95a8`)
**Baseline at start:** `c309572`. **HEAD when the bench landed:** `b13d837`
(HEAD moved under this track; both are recorded rather than one assumed).
**Tools:** GHDL 1.0.0 mcode (`ghdl -a` + `ghdl -r`, never `ghdl -e`),
`sim/regress.sh`, `grep`, `python3`. **No hardware. No Vivado. Nothing under
`hw/fk33/` was executed** -- four files there were READ and none was edited.
`rtl/**` was READ and NEVER edited; every RTL variation below was made on a
COPY in the session scratchpad.
**Machine at start:** MEASURED `df -h /` 91% used / 126 G free; `/mnt/storage`
56% / 387 G free; `free -g` 31 G total, 0 free, 22 G swap in use; `uptime` load
average 6.06 6.78 8.06 at 00:51.

---

## 1. The question, verbatim

> TRACK STRAYROW raised open issue **STRAY-NEXTJOB** and left exactly one thing
> undone, in its own words:
>
> > "Whether the shipping flow can produce STRAY-NEXTJOB's reset-then-restart
> > sequence was not investigated (hardware boundary)."
>
> **Answer this: can the shipping design actually get into that state?**
> Concretely -- is there any sequence the real gateware and the real host flow
> can produce in which `rtl/axi_rd_port.vhd` (and `rtl/axi_rd_fsm.vhd`,
> `rtl/weight_streamer.vhd`) is reset or restarted while a burst it issued is
> still in flight from the HBM slave, and then starts a new job before those
> beats have drained?
>
> **Both answers are valuable and I want whichever is true.**

And, as the single most valuable thing this track could return:

> **Is the reset shared with the HBM slave or not?** A7's section 8 fork turns
> on precisely this [...] **If you can settle that from the block design, you
> have also settled A7's fork.**

---

## 2. The answers, up front

**STRAY-NEXTJOB is NOT reachable on the shipping FK33. The HBM slave DOES
share the reset, in the only sense that matters, and A7's fork is therefore
settled by taking NEITHER arm: the committed RTL is already the correct one,
and A7's proposed "preserve `outst`/`arv` across `rst`" fix would HANG the
card. `rtl/**` needs no change. The thermal guard is ruled out completely --
it is a GO mask and touches no reset.**

Taking the four deliverables in order.

### (a) Does the slave share the reset? YES -- and "are they the same net" was the wrong question

This is the finding everything else rests on, and it is a three-line structural
fact read off the block design rather than an inference. MEASURED from
`hw/fk33/build_fk33_pcieep.tcl` at `b13d837`:

```
:921  connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins core_reset/ext_reset_in]
:924  connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins eng/core_aresetn]
:959  connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_01_ARESET_N]
      ... 28 more, one per engine master, through :1040
```

**Both earlier write-ups say the two nets are NOT the same net, and that is
true. It is also not the property that decides anything.** `eng/core_aresetn`
is `core_reset/peripheral_aresetn`, and `core_reset` is a `proc_sys_reset`
whose `ext_reset_in` **IS** `xdma/axi_aresetn` -- which is exactly the net that
resets every HBM slave port. So `core_aresetn` is not a *sibling* of the
slave's reset, it is a *descendant* of it. **The port's reset cannot assert
unless the slave's reset asserted first.**

`core_reset` has exactly three driven inputs (MEASURED, `grep -n core_reset`
returns 5 lines, one of which is the `create_bd_cell` and one a verification
loop): `slowest_sync_clk` = `clk_wiz_0/clk_out3`, `dcm_locked` =
`clk_wiz_0/locked`, `ext_reset_in` = `xdma/axi_aresetn`. `aux_reset_in` and
`mb_debug_sys_rst` are undriven, therefore constant, therefore incapable of
producing a mid-job event -- which sidesteps the question of what value the BD
ties them to, and that sidestep is deliberate (see section 7).

That leaves two ways for `core_aresetn` to fall, and **both take the HBM slave
with them**:

1. `xdma/axi_aresetn` falls. It is the slave's own reset net. Whatever caused
   it -- PERST, link down, FLR, a host warm reboot, an `xdma` driver reload --
   is irrelevant, because the *same net* is the slave's `ARESET_N`. This is why
   the enumeration of host-side triggers does not need to be exhaustive to be
   conclusive.
2. `clk_wiz_0/locked` drops. Its `resetn` is `xdma/axi_aresetn`
   (`build_fk33_pcieep.tcl:448`, inside the `EnablePCIe == 1` branch that spans
   `:356`-`:502`) and its `clk_in1` is `xdma/axi_aclk` (`:400`). So an unlock
   requires either that same reset or the loss of `xdma/axi_aclk` -- and
   `xdma/axi_aclk` is `hbm/AXI_nn_ACLK` **and** `eng/hbm_aclk`, so it stops the
   slave and the port's whole AXI-side domain together.

DERIVED, the ordering, and the asymmetry matters: on assert, `axi_aresetn`
falls first and `core_aresetn` a synchroniser later; on release,
`axi_aresetn` rises first and `core_aresetn` a `proc_sys_reset` bsr hold later.
Neither window contains the other. But at every instant `core_aresetn` is low,
the slave either is in reset or has just left it **empty** -- so there is no
window in which the port is reset while the slave still holds a burst it
accepted before that reset. That is precisely the precondition STRAY-NEXTJOB
needs, and it does not exist.

MEASURED that this is generated rather than hand-wired, so it survives a
regeneration by TRACK BITPREP: `hw/fk33/gen_pcieep.py:798` and `:801` emit the
`core_reset` wiring and `:838` emits
`xdma/axi_aresetn -> hbm/AXI_%02d_ARESET_N` inside the per-port loop.

MEASURED that the topology is uniform across all 28 masters, including the
descriptor reader: `d_*` is `m27_axi` (`hw/fk33/rtl/fk33_engine.vhd:1880`), an
ordinary HBM SAXI port. Counting drivers over the whole file, 30 of the 32
`hbm/AXI_nn_ARESET_N` connections are `xdma/axi_aresetn`; the other two are
`AXI_00`/`AXI_16` at `:526`-`:527`, and those are inside the **`EnablePCIe == 0`**
branch, which `:631` makes a hard `error`. In the shipping build every port is
`xdma/axi_aresetn`.

### (b) Is STRAY-NEXTJOB reachable? NO -- and it is measured, not only argued

The wiring argument above is structural. It is also exactly the kind of
argument this project has repeatedly found to be true and irrelevant, so it was
put to a bench. `sim/tb_axi_rd_port_stray.vhd`'s slave was given the shipping
reset topology -- a reset window that leads in and leads out of the port's, as
`proc_sys_reset` orders them -- and the drain window was cut to the aggressive
`DRAIN_WAIT = 4` that reproduces the defect:

| | slave | drain | value oracle | `strayl` |
|---|---|---|---|---|
| **E0** | does NOT share reset (STRAYROW control E) | 4 | **10 errors** | 0/1/1 |
| **E1** | **SHARES reset (SHIPPING)** | 4 | **0 errors** | **0/0/0** |
| **E1b** | does NOT share, **E1's reset timing** | 4 | **2 errors** | 2/2/3 |

E0 reproduces STRAYROW's control E to the digit (`got 3133 want 5120`,
`got 3108`, `got 3155`), which is the evidence that the harness is faithful
before anything is concluded from it. **E1b is the attribution control and it
is the reason E1 can be believed**: E1 changed two things at once (the slave's
reset-awareness *and* the reset timing), so E1b keeps the new timing and takes
only the reset-awareness away. It fails. The single variable is the slave's
reset-awareness, not the reset width and not the drain window.

### (c) A7's fork, settled -- and A7's arm HANGS on this card

A7 wrote that preserving `outst`/`arv` across `rst`, so `S_DRAIN` waits for the
strays, "is correct if the slave does NOT share the reset (the FK33 case) and
HANGS if it does". The parenthesis is the part that is wrong: by (a) the FK33
is the *shares* case. Measured on scratch copies of `rtl/axi_rd_fsm.vhd`:

| arm | slave SHARES reset (**SHIPPING**) | slave does NOT share |
|---|---|---|
| **committed RTL** (`outst <= 0; arv <= '0'` on rst) | **PASS**, 0 errors (E1) | FAIL, wrong numbers (E0) |
| A7 "preserve", **naive** | **HANG** (E2) | **HANG** (E3) |
| A7 "preserve", **charitable** | **HANG** (E4) | **PASS**, 0 errors (E5) |

**Which arm is correct: NEITHER. The committed RTL is already right for the
FK33, and adopting A7's fix would convert an unreachable wrong-numbers defect
into a reachable permanent stall.** The cost of being wrong is asymmetric and
worth stating in both directions:

* **Wrong in the direction of "leave it alone" (what this track recommends).**
  If the topology ever changes so the slave does *not* share the reset -- a
  separate reset for the compute domain, an engine reset register added for the
  gateware-timed abort A7 asked for, or a composed top that resets one engine
  independently -- STRAY-NEXTJOB becomes live again and it is silent wrong
  numbers. Rows 0-2 of the gate row are the standing check for that, and this
  document is the reason someone would look.
* **Wrong in the direction of "apply A7's fix".** The port enters `S_DRAIN` and
  never leaves. Every job after any reset stalls forever, on all 28 masters. It
  is not silent, but it is unrecoverable without a power cycle, and it would be
  introduced to fix something that cannot happen.

**A genuine correction to A7's section 6, which is worth more than the fork
itself: the fork as A7 stated it is under-specified, and the naive
implementation hangs in BOTH topologies.** E3 was expected to PASS and did not.
Diagnosed rather than assumed (section 5.4): while `rst` is asserted, the FSM
takes the `if rst = '1'` branch, so the retirement accounting
`if rlast = '1' then os := os - 1` **is not executed at all** -- yet
`rtl/axi_rd_port.vhd:182` forces `rready` high outside `S_RUN`, so beats keep
crossing the R channel and retiring bursts the counter never decrements.
Preserving `outst` therefore preserves a count that is permanently too high by
the number of bursts that completed during the reset window, and `S_DRAIN`'s
`os = 0` never comes true. An instrumented run shows the port stuck at
`st=s_drain outst=2 arv='0' ar_left=0` for the rest of the simulation. E4/E5
are the charitable form, with the accounting kept live in the reset branch, and
only that form reproduces the trade A7 described.

### (d) The thermal guard: RULED OUT, and not by its own documentation

The brief flagged `compute_halt` as "a live candidate and not hypothetical" --
253 trips in 1300 s, counter saturated at 255. **It cannot produce this state.**
MEASURED, `grep -n compute_halt hw/fk33/rtl/fk33_engine.vhd` returns exactly
five lines and three are uses: `:1056` and `:1069` mask bit 0 of the AXI-Lite
write data (the GO bit), and `:1140` reports it back over the status register.
`:38` and `:66` are a comment and the port declaration. **It touches no reset,
no clock enable and no FSM.** The header comment at `:62`-`:64` claims exactly
this, and the claim was checked against the code rather than believed, because
a comment asserting its own correctness is the weakest possible evidence.

What it does instead is block the *start* of new work. So a saturating thermal
guard produces **fewer** job starts, not resets -- it moves the design away
from STRAY-NEXTJOB's precondition, not toward it.

### (e) The host: it was never the interesting question

A7's dispatcher already MEASURED that `hw/fk33/host/fk33_regs.h` has no reset
register or bit. This track did not re-derive that and did not need to extend
it, because of the structural result in (a): **there is no net that reaches the
engine's reset without also reaching the HBM slave's.** An exhaustive
enumeration of host-side triggers would be a stronger-sounding argument and a
weaker one -- it could only ever be as complete as the enumeration.

---

## 3. The procedure, in the order it was run

Each step says what it controls for.

1. **Check the machine before trusting any timing or any verdict.** Reported in
   the header. *Controls for reading a contended box's numbers as a result.*
2. **Rule out the loudest candidate first, from the RTL and not from its
   comment.** `compute_halt`'s every occurrence in `fk33_engine.vhd`. *Controls
   for spending the night on a mechanism that a three-line grep eliminates, and
   for trusting a header that asserts its own correctness.*
3. **Trace the reset in the block design rather than assuming it.** `core_reset`
   inputs, `hbm/AXI_nn_ARESET_N` drivers, the branch structure that decides
   which of them the shipping build takes. *Controls for the previous two
   write-ups' "they are not the same net", which is true and which was doing
   all the work.*
4. **Check the GENERATOR agrees with the generated script.** `gen_pcieep.py`.
   *Controls for an answer that a regeneration silently invalidates -- TRACK
   BITPREP owns those files right now.*
5. **Reproduce the known result before measuring a new one.** E0 against
   STRAYROW's control E, digit for digit. *Controls for a harness that is
   subtly not the thing the earlier track measured.*
6. **Measure the shipping topology** (E1). *Controls for a purely structural
   argument, which is the failure mode this project's CLAUDE.md is mostly about.*
7. **Run the attribution control** (E1b), because E1 varied two things.
   *Controls for crediting the reset-awareness with a result the timing change
   produced.*
8. **Test A7's fork in BOTH topologies** (E2, E3), then **diagnose the arm that
   behaved unexpectedly instead of reporting it** (E3 debug), then **re-test the
   charitable form** (E4, E5). *Controls for killing a proposal with an unfair
   rendering of it.*
9. **Only then make the bench change**, teeth-check it, and run it through the
   real `sim/regress.sh` rather than the hand harness.

---

## 4. What changed in the tree

**`sim/tb_axi_rd_port_stray.vhd` only.** No `rtl/**`, no `hw/**`, no
`sim/regress.sh`, no `docs/WORKLOG.md`. The row is **still GREEN** and
`BASELINE_PASS` is unaffected -- this modifies an existing gate row rather than
adding a file, so the row count does not move.

`NC` goes 3 -> 6, as two groups of three with opposite claims:

* **Rows 0-2 (`afast`/`aslow`/`anear`) are unchanged in every respect**, still
  at `DRAIN_WAIT = 200` on the safe side of the undecided defect, and still
  producing `stray` 30/27/32 and `strayl` 4/4/4. Verified by output, not by
  reading the diff: the three lines are identical to STRAYROW's section 5.3.
* **Rows 3-5 (`sfast`/`sslow`/`snear`) are the shipping FK33 topology**: the
  modelled slave honours an upstream reset `srst`, ordered as `proc_sys_reset`
  orders it, and the drain window is the aggressive `DRAIN_W = 4` that makes
  rows 0-2 produce wrong numbers. They assert that the value oracle holds
  anyway.

The coverage asserts are per-group and they point in **opposite** directions,
which is the part worth reading before editing the file. Rows 0-2 require
`stray > 0` and `strayl > 0` (without strays they test nothing). Rows 3-5
require `strayl = 0` -- **as a property, not as coverage**: if the slave shares
the reset then no pre-reset burst may be retired against the zeroed `outst`,
and a non-zero `strayl` there means the model has stopped modelling the card,
so the value oracle would be passing for a reason that does not hold on
silicon. That inversion is the guard against the failure mode where the new
rows quietly become decoration.

MEASURED runtime **0.106 s** wall for the whole six-configuration bench.

---

## 5. The evidence, as raw output

All runs used a hand-built GHDL harness over the exact closure `sim/regress.sh`
derives for this row (`rtl/util_pkg.vhd rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd
rtl/stream_fifo.vhd rtl/axi_rd_port.vhd sim/tb_axi_rd_port_stray.vhd`),
`--std=08`, `ghdl -r`, redirected to a file so no pipeline can mask the exit
code. Section 5.6 is the real `sim/regress.sh`.

### 5.1 The harness is faithful: BASE reproduces STRAYROW exactly

```
anear: beats=83 stall=103 stray=32 strayl=4 err=0
aslow: beats=74 stall=153 stray=27 strayl=4 err=0
afast: beats=85 stall=93  stray=30 strayl=4 err=0
axi_rd_port_stray: 0 errors across 3 clock ratios
PASS: tb_axi_rd_port_stray
```

### 5.2 E0 -- STRAY-NEXTJOB reproduced, digit for digit

`DRAIN_WAIT` 200 -> 4, slave not reset-aware, committed RTL:

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

### 5.3 E1 -- the SHIPPING topology, same aggressive drain: NO wrong numbers

```
anear: beats=83 stall=104 stray=1 strayl=0 err=1
aslow: beats=74 stall=152 stray=1 strayl=0 err=1
afast: beats=85 stall=93  stray=1 strayl=0 err=1
axi_rd_port_stray: 3 errors across 3 clock ratios
```

**Not one `BEAT got ... want ...` line.** The three errors are the OLD coverage
assert (`strayl = 0`) firing, which under this topology is the *expected*
outcome and is why rows 3-5 invert it into a property. `beats` 83/74/85 are
identical to the `DRAIN_WAIT = 200` base, i.e. every job after the reset
delivered exactly the right words.

### 5.4 E1b -- the attribution control

E1's reset timing kept, slave's reset-awareness removed, nothing else:

```
aslow: BEAT got 3118 want 5120 ...
aslow: BEAT got 5120 want 3120 ...
anear: beats=83 stall=104 stray=21 strayl=2 err=0
aslow: beats=74 stall=151 stray=13 strayl=2 err=2
afast: beats=85 stall=93  stray=27 strayl=3 err=0
axi_rd_port_stray: 2 errors across 3 clock ratios
```

**Two honest notes on this row.** First, it is the control that matters: same
timing as E1, and the defect comes straight back, so the reset-awareness is the
whole difference. Second, **it bit at only ONE of three ratios (2 errors) where
E0 bit at all three (10 errors)** -- the longer reset hold reduced the exposure
without removing the mechanism, and `strayl` stayed 2/2/3 at every ratio. That
is a resolution note, not a contradiction, and it is recorded because a reader
comparing E0's 10 with E1b's 2 would otherwise think the control had half
failed.

### 5.5 A7's fork, measured

E2 (preserve, naive, SHIPPING slave) and E3 (preserve, naive, non-sharing
slave) BOTH stall, at all three ratios, on both post-reset jobs:

```
anear: JB after the reset STALLED -- 24 of 24 beats never arrived.  The port issued no further AR, which is what an underflowed `outst` looks like in hardware
...
anear: beats=46 stall=70055 stray=1  strayl=0 err=3     (E2)
anear: beats=46 stall=70055 stray=21 strayl=2 err=2     (E3)
```

E3 was the surprise, so it was instrumented rather than reported. The port is
stuck for the rest of the run at:

```
DBG n=774 st=s_drain outst=2 arv='0' ar_left=0 clr='0'
DBG n=779 st=s_drain outst=2 arv='0' ar_left=0 clr='0'
```

`S_DRAIN` waiting on two bursts that already returned during the reset window,
uncounted -- see section 2(c).

E4/E5, the charitable form with the retirement accounting kept live in the
reset branch:

```
E4  slave SHARES reset (SHIPPING):     JB/JC STALLED at all three ratios, 9 errors, FAIL
E5  slave does NOT share the reset:    0 errors across 3 clock ratios, PASS
```

### 5.6 The new rows in the tree, and their teeth

Committed RTL, all six:

```
snear: beats=83 stall=104 stray=1  strayl=0 err=0
sslow: beats=74 stall=152 stray=1  strayl=0 err=0
sfast: beats=85 stall=93  stray=1  strayl=0 err=0
anear: beats=83 stall=103 stray=32 strayl=4 err=0
aslow: beats=74 stall=153 stray=27 strayl=4 err=0
afast: beats=85 stall=93  stray=30 strayl=4 err=0
axi_rd_port_stray: 0 errors across 6 clock ratios
PASS: tb_axi_rd_port_stray
```

Through the real gate:

```
$ REGRESS_SCRATCH=<scratch> bash sim/regress.sh --only axi_rd_port --keep
 OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS

$ REGRESS_SCRATCH=<scratch> bash sim/regress.sh --only axi_rd_port_stray --keep
PASS       sim:tb_axi_rd_port_stray               0s  ... PASS: tb_axi_rd_port_stray
 OVERALL     PASS 1   FAIL 0 ...
```

`PASS 3` and `PASS 1` are read rather than the `REGRESSION: PASS` line, because
`--only` takes a substring and a non-matching pattern prints PASS over zero rows.

**The mutation table.** The column that decides whether the new group is worth
its maintenance is the third one.

| | mutation | rows 0-2 (old) | rows 3-5 (new) |
|---|---|---|---|
| **M1** | A7 "preserve `outst`/`arv`", charitable form | **SURVIVED**, err 0/0/0 | **KILLED** -- JB and JC STALLED, 6 errors |
| **M2** | A7 "preserve", naive form | KILLED | KILLED |
| **M3** | A7's `if os < 0 then os := 0` clamp DELETED | KILLED, `bound check failure at rtl/axi_rd_fsm.vhd:251` | **DID NOT BITE** -- the run dies in the old group first |
| **M4** | the shipping rows' slave stops honouring its own reset | unaffected, err 0/0/0 | **KILLED** -- the new `strayl /= 0` property fires at all three, plus 2 value-oracle errors at `sslow` |

* **M1 is the whole justification for the new rows.** The existing rows PASS
  the change that would hang the shipping card; the new rows catch it. The
  attribution control demanded by the brief was run and the kill is not
  duplicated by anything already present.
* **M3 DID NOT BITE for the new group, and it is reported under its own name.**
  It is the mutation the old rows exist for, so this is the correct outcome and
  it measures the new group's resolution floor: rows 3-5 add nothing to the
  `outst` underflow, which the old rows already own at their own level.
* **M4 is the teeth check on the new property itself.** Without it, "rows 3-5
  pass" would be compatible with a slave model that had silently drifted back
  to the non-sharing case, which is exactly the guard-that-passes-for-the-wrong-
  reason failure class this project keeps finding. It fires, and it leaves rows
  0-2 at err 0, confirming the mutation was isolated to the group it targets.

---

## 6. Measured and REJECTED -- do not retry

* **"The thermal guard resets the engine, so STRAY-NEXTJOB fires hundreds of
  times an hour."** REJECTED, and it was the brief's leading hypothesis.
  `compute_halt` has three uses in `hw/fk33/rtl/fk33_engine.vhd` and all three
  are the GO mask (`:1056`, `:1069`) or the status readback (`:1140`). It
  touches no reset. It makes job starts *less* frequent, which moves away from
  the precondition. **Do not re-open this from the trip statistics.**
* **"The two reset nets differ, therefore the slave does not share the
  reset."** REJECTED. This is STRAYROW's and A7's shared premise and it is the
  load-bearing error. They differ, and `core_aresetn` is *generated from*
  `axi_aresetn` by `core_reset`, so the slave's reset is a strict precondition
  of the port's. **The question to ask is not "same net" but "can the port's
  reset assert while the slave's has not".**
* **"A7's `preserve outst/arv` arm is correct for the FK33."** REJECTED twice
  over. It is not correct *for the FK33* because the FK33 is the sharing case
  (E4 hangs). And as A7 stated it, it is not correct for *either* case, because
  the naive form omits the retirement accounting during reset (E2 and E3 both
  hang). **Do not apply this fix.**
* **"A host-side enumeration is needed to settle reachability."** REJECTED as
  unnecessary. No net reaches `eng/core_aresetn` without reaching
  `hbm/AXI_nn_ARESET_N`, so no trigger enumeration can change the answer, and
  an enumeration is only ever as good as its completeness.
* **"Cut `DRAIN_WAIT` on the existing rows now that the defect is understood."**
  REJECTED, and this is a judgement. Rows 0-2 stay at 200. They are the
  standing check for the topology CHANGING, and turning them red today would
  tax every other track for a defect that is unreachable.
* **"`ar_left` going negative is what hangs the preserve arm."** REJECTED,
  checked: `rtl/axi_rd_fsm.vhd:98` declares `ar_left : integer := 0`, unbounded,
  so a negative silently makes `ar_left > 0` false and traps nothing. The hang
  is `outst`, confirmed by the instrumented trace.

---

## 7. Measurement traps hit, including my own

* **The one I nearly walked into: I had the reachability answer from the wiring
  before I had run anything, and the wiring argument was correct.** That is the
  most dangerous position in this project, because a correct structural
  argument and a wrong conclusion are indistinguishable from the inside. E1
  and E1b exist for that reason. They agreed -- which is a weaker outcome than
  it looks, since agreement is what you get in both the case where you were
  right and the case where the bench inherited your assumption. What makes E1
  worth something is E1b, which shows the bench *can* still produce the defect.
* **I changed two variables between E0 and E1 and would have reported it.** The
  slave's reset-awareness and the reset timing moved together, because
  modelling `proc_sys_reset` ordering necessarily lengthens the hold. E1b was
  added only after noticing, and it is the reason the attribution is stated at
  all. STRAYROW's finding that `RST_HOLD` does not matter at `DEPTH = 64` made
  it *tempting* to skip the control on the grounds that it was already known --
  a result measured in one configuration being carried into another without
  re-measuring is precisely the trap STRAYROW itself recorded.
* **E3 contradicted A7's prediction and my first instinct was to report it as a
  kill.** "A7's fix hangs in both topologies" is a bigger-sounding finding than
  "A7's fix hangs in one", and it would have been a kill scored against an
  unfair rendering of the proposal. Diagnosing it first turned a cheap
  refutation into the actual mechanism (the reset branch skipping the
  retirement accounting), which is both more useful and less flattering to the
  result.
* **The `CONFIG.*`-is-a-request trap does NOT apply to the central evidence,
  and saying so is part of the evidence.** The brief flagged it and it is real,
  but every load-bearing line in section 2(a) is a `connect_bd_net` -- a
  structural connection, not a property whose readback can disagree with the
  request. The `CLKOUT3_REQUESTED_OUT_FREQ {200.000}` and `axisten_freq {250}`
  values *are* requests and are used here only for narrative, never for a
  conclusion.
* **Undriven `proc_sys_reset` inputs were sidestepped rather than resolved.**
  `aux_reset_in` and `mb_debug_sys_rst` are unconnected, and what a BD ties an
  unconnected active-low reset input to is not something I could settle without
  generating the design. The argument was restructured so it does not need the
  answer: an undriven pin is a *constant*, and a constant cannot produce a
  mid-job reset event. Recorded because the tempting move was to assert the
  tie-off value and move on.
* **`hbm/AXI_00`/`AXI_16` have a different reset driver and it is a red
  herring.** Two of 32 connections use `hbm_reset/peripheral_aresetn`. They are
  inside the `EnablePCIe == 0` branch, which `build_fk33_pcieep.tcl:631` turns
  into a hard `error`. A `grep` that does not check the branch structure reports
  a mixed topology that does not exist in any build.
* **`--only` takes a substring**, so `PASS 3` and `PASS 1` were read rather than
  `REGRESSION: PASS`.
* **The box was NOT quiet.** Load average 6.06 at start, TRACK COMPOSE4 running
  a place-and-route, 22 G of swap in use. Every measurement here is a GHDL run
  of 0.1 s to a few seconds; contention can starve a run into a timeout but
  cannot make a failing value oracle pass, and no run here timed out.

---

## 8. Open, not yet answered

* **Nothing here was run on hardware, and nothing here was synthesised.** The
  answer is a claim about the block design and the RTL, not a measurement on
  the card. A7's section 9 experiment remains unrunnable for the reasons its
  dispatcher recorded, and this document does not make it runnable -- it makes
  it unnecessary.
* **The answer is conditional on the reset topology, and that condition is not
  asserted anywhere by a check.** If `hw/fk33/gen_pcieep.py` ever gives the
  compute domain a reset that is not descended from `xdma/axi_aresetn` -- an
  engine reset register, a per-engine reset in a composed top, the
  gateware-timed abort A7 asked for -- STRAY-NEXTJOB becomes live again and it
  is silent wrong numbers. **A `build_fk33_pcieep.tcl` verification loop
  asserting that `core_reset/ext_reset_in` and every `hbm/AXI_nn_ARESET_N` trace
  to the same source would make the condition checkable rather than
  documented.** That file belongs to TRACK BITPREP and this track did not touch
  it. This is the single highest-value follow-up.
* **`hw/fk33/rtl/compose4_top.vhd` was NOT analysed.** It instantiates the
  engine (`:1274`) and is TRACK COMPOSE4's file. Whether a four-engine
  composition preserves the property in the bullet above is unexamined, and it
  is exactly the kind of change that would break it.
* **The FLR / driver-reload question was not answered on its own terms**, only
  dissolved. It is genuinely unknown here whether an `xdma` FLR deasserts
  `axi_aresetn`; the argument does not need to know, because the same net feeds
  both. If anyone ever adds an engine-only reset path, that question becomes
  live again and is not answered in this document.
* **`AXIRD-FRST` is still not fixed.** Fifth sighting, unchanged, still one
  deleted line, still `rtl/**`.
* **Whether subsystem A can be re-armed after `EC_CORE` without a reset** is
  still open (A7, ASURV). It is worth recording that this track partially
  narrowed it: a plain re-arm with no reset does NOT reach STRAY-NEXTJOB,
  because `rtl/axi_rd_fsm.vhd`'s `start` handler parks in `S_DRAIN` and waits
  for `arv = '0' and os = 0`. The defect needs the reset to zero those
  counters. That does not answer the re-arm question, but it removes one
  reason to care about the answer.

---

## 9. Corrections to the brief, and to the two documents upstream

* **"The thermal guard is a live candidate and it is not hypothetical [...] If
  it resets them mid-burst, STRAY-NEXTJOB is not only reachable, it is
  reachable hundreds of times an hour."** Withdrawn. `compute_halt` resets
  nothing (section 2(d)). The trip statistics are real and the inference from
  them is not.
* **"On the FK33 the streamer's `rst` is `core_aresetn` while the HBM slave is
  reset by the XDMA's `axi_aresetn`, so the two are NOT the same net and the
  case is reachable"** -- A7 section 8, repeated in STRAYROW section 5.5 and in
  the WORKLOG's STRAY-NEXTJOB entry as "the SHIPPING case, not a bench
  contrivance". **The premise is true and the conclusion does not follow.**
  `core_aresetn` is generated from `axi_aresetn`, so the slave is reset
  whenever the port is. The non-reset-aware slave model is a bench contrivance
  after all -- a useful one, which is why rows 0-2 keep it.
* **A7 section 6, "preserving `outst`/`arv` across `rst` [...] is correct if the
  slave does NOT share the reset (the FK33 case)".** Corrected twice: the FK33
  is not that case, and the fix as stated hangs in both cases (section 2(c)).
* **STRAY-NEXTJOB's status.** It is a real defect in `rtl/axi_rd_fsm.vhd`,
  reproduced and unchanged, and it is **UNREACHABLE in the shipping FK33
  topology**. It should be re-classified from "OPEN, a design decision" to
  "OPEN, unreachable in the current topology, with the topology as the
  condition". The WORKLOG is not this track's file; the entry needs that edit.
