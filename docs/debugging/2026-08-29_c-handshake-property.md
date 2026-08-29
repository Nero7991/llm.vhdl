# A bench configuration that wedged on the clean design, and one defect class that five benches could only see as a deadlock

2026-08-29. TRACK C-DONE. GHDL 1.0.0 mcode, `Oren-Dell-Ubuntu`, repo
`/home/orencollaco/GitHub/llama.vhdl` at branch `fpga`. Follows
`docs/debugging/2026-08-29_attn-harness-verdicts-and-seeds.md`, which found both
defects and owned neither file.

---

## 1. The question, verbatim

> ### Defect 1: a bench configuration that wedges on the CLEAN design
>
> > `mutate_attn_emit.sh` config B wedges on the **unmutated** design.
> > `-gM_GAP=0 -gACK_LAG=0` on clean `attn_emit` gives **one line of output in
> > 20 ms**. **Every "kill" in that column was unearned.**
>
> Mechanism, read off the RTL rather than instrumented, so verify it before
> trusting it: at `ACK_LAG=0` the bench holds `done_ack` high from before
> `start`, so `done_r` clears in the cycle it is raised, and the
> `while done /= '1'` poll never sees it. Sites named as
> `sim/tb_attn_emit.vhd:455` and `:486` -- **check those line numbers, six
> tracks are editing this tree and one brief today was stale by 39 lines.**
>
> Fix the bench so config B exercises what it was meant to, then **re-measure
> that harness** and say which of its rows were genuinely earned.
>
> ### Defect 2: a systematic hole across FIVE units
>
> > **One mutation is an ABORT in five separate harnesses.** "An explicit
> > `done_r` clear inside the ack branch" appears as `attn_emit` E18,
> > `attn_gate` M21, `attn_twiddle` N19, `attn_softmax` M5 and `attn_recip` N14
> > -- and is detected by **no check in any of the five**, only as a deadlock.
>
> That is the real prize. [...] **A variant that cleared `done_r` one cycle
> later, or under a rarer condition, would not hang and nothing would catch it
> at all.**
>
> **Add a property that detects it directly**, not as a timeout. [...] Then
> show the property fires on all five mutations **and** on the harder
> non-hanging variant you should construct yourself.

---

## 2. The answer, up front

**Defect 1 is real and is FIXED, but the mechanism in the brief is WRONG and
must not be repeated.** `done_r` does not clear in the cycle it is raised. At
`ACK_LAG = 0` the ack already stands when the unit completes, so `done` is
legally high for exactly one cycle -- and `sim/tb_attn_emit.vhd` waited for the
**two** instances' done signals **sequentially**, `while done /= '1'` and then
`while done1 /= '1'`. MEASURED by instrumenting a scratch copy of the bench:
the one-group instance has no `S_EMIN` pass and reaches `S_DONE` **two cycles
earlier**, every case, so the first loop consumed `done1`'s entire pulse and the
second waited for an edge that would never come. The fix latches each pulse as
it is seen. Configuration B is now `A=PASS B=PASS C=PASS` on the clean design.
The named line numbers were stale by one and two lines (`:456` and `:488` at the
time of reading); cite `if ACK_LAG > 0 then done_ack <= '0'` and
`while done /= '1' loop` instead.

**Re-measured, `mutate_attn_emit` earned 20 of its 22 rows.** E18 was earned by
the language of a deadlock, not by a check, and **E19 is a plain SURVIVOR** --
the only thing that ever "killed" it was the broken column. `rtl/attn_emit.vhd`
already documents E19 as an equivalent mutant with instrumented evidence, so
surviving is the right answer; it is now scored that way rather than hidden
behind an unearned kill.

**Defect 2 is fixed by a property, `sim/hsk_chk.vhd`, in FOUR clauses**, now
instantiated in six benches (`attn_emit` twice, for both its instances, plus
`attn_gate`, `attn_twiddle`, `attn_softmax`, `attn_recip`, `attn_rope`):

| clause | statement | what it catches | teeth demonstrated on |
|---|---|---|---|
| 1 LIVENESS | `done` rises within `DEADLINE` cycles of a layer being accepted | the five known `done_r`-clear mutations, plus `attn_rope` P25 | E18/M21/N19/M5/N14/P25, all six |
| 2 HOLD | `done` may fall only on or after an edge where `done` and `done_ack` were BOTH high | a `done` that reverts to a bare pulse | a `if done_ack = '1'` -> `if true` mutant, all five, configs A and C |
| 3 RELEASE | after that edge, `done` falls within `REL_MAX` cycles | **the non-hanging sibling** | H1, all five, all three configs |
| 4 NO SPURIOUS | `done` is low at the edge a new layer is accepted | the same, seen from the other end | H1 on `attn_recip`, all three configs |

**The non-hanging sibling exists and it was invisible.** H1 raises `done`, holds
it for as long as the consumer wants, and then releases it at the NEXT layer's
accept instead of at the ack -- the ack has no effect on `done` at all, and
every value the unit produces is still correct. MEASURED with the property
removed and nothing else changed: **H1 is `A=PASS B=PASS C=PASS` on all five
benches.** A poll for `done = '1'` is satisfied by the stale level; no value
check sees it because no value is wrong. With the property it is killed in all
three configurations of all five.

**Clause 1 is a timeout and the note says so in as many words.** It converts a
wedge into a named, bench-owned failure, which is worth having -- but it does
not establish that any value check would have caught anything. Clauses 2, 3
and 4 are the new coverage.

**Of the 10 ABORT rows the previous track listed, 7 are now determined and one
of those SURVIVES.** See section 5.

**Gate: `OVERALL PASS 92`, `REGRESSION: PASS`, full and unfiltered.** See
section 8.

---

## 3. The procedure, in the order it was run

Each step isolates one thing.

1. **Reproduce the wedge from the committed files**, before reading any
   diagnosis. `ghdl -r` the clean `rtl/attn_emit.vhd` under
   `sim/tb_attn_emit.vhd` at HEAD, in all three configurations. This is the
   BEFORE picture and it is taken from the tree, not from the brief.
2. **Check the cited line numbers.** They were `:455`/`:486` in the brief and
   `:456`/`:488` in the file. Small, but the brief itself warned that a stale
   citation had already cost a day, so the symbols are cited from here on.
3. **INSTRUMENT rather than reason.** A scratch copy of the bench with one
   extra `report` per instance's `done`, run at `-gM_GAP=0 -gACK_LAG=0`. This
   is the step that overturned the diagnosis: it showed both dones DO rise, two
   cycles apart, so the failure is in the WAITING, not in the DUT.
4. **Fix the bench and re-run all three configurations on the clean design.**
   A and C must be unchanged -- at `ACK_LAG > 0` both dones are held, so the
   joint wait is provably equivalent to the two sequential loops there, and the
   measurement confirms it.
5. **Derive the handshake contract from `rtl/attn_emit.vhd`'s `S_DONE` branch**,
   which all five units share, and write it as four clauses in one entity.
6. **Set `DEADLINE` by MEASUREMENT, per bench**, with a `NOTE_MAX` generic that
   prints each new worst start-to-done latency, then leave `NOTE_MAX` false.
7. **Run every clean design through the property first**, in all three
   configurations of its harness. A property that fires on the clean design is
   worth exactly what a configuration that wedges on it is worth. This is what
   caught the HOLD clause's own defect (section 7).
8. **Teeth-check each clause separately** on a mutation chosen for it.
9. **Construct the non-hanging variant and measure it BOTH ways** -- with the
   property removed, and with it in place. Removing the property is what makes
   the claim "nothing caught it" a measurement instead of an assertion.
10. Add the H1 row to five harnesses, wire `sim/hsk_chk.vhd` into their analyze
    step and name it to `sim/mutverdict.py`, `bash -n` all of them.
11. Re-run all six harnesses.
12. Targeted `sim/regress.sh --only <tb>` for each of the six benches, then the
    full unfiltered gate.

`sim/hsk_chk.vhd` is deliberately NOT named `sim/tb_*.vhd`: `sim/regress.sh`
discovers gate rows from that glob (`tb_*.vhd` at its line handling
`glob.glob(os.path.join(repo, d, 'tb_*.vhd'))`), and a checker is not a test.
Its closure logic resolves the entity automatically from the `entity work.`
reference, so no `regress.sh` edit was needed and `BASELINE_PASS` is untouched.

---

## 4. The evidence

### 4.1 The wedge, reproduced from the committed files

```
cfg A rc=0 lines=1 verdict=PASS
cfg B rc=0 lines=1 verdict=ABORT:WEDGE
cfg C rc=0 lines=1 verdict=PASS

$ cat clean_B.log
/usr/bin/ghdl-mcode:info: simulation stopped by --stop-time @20ms
```

### 4.2 The instrumentation that overturned the diagnosis

A scratch copy of `sim/tb_attn_emit.vhd` with one extra process reporting each
instance's `done`, at `-gNCASE=40 -gNGRP=2 -gGRP_N=48 -gM_GAP=0 -gACK_LAG=0`:

```
tb_dbg.vhd:218:9:@2175ns:(report note): DBG done1=1 tick=217
tb_dbg.vhd:215:9:@2195ns:(report note): DBG done=1  tick=219
/usr/bin/ghdl-mcode:info: simulation stopped by --stop-time @20us
```

Both dones rise. `done1` is FIRST, by two cycles, because the one-group
instance has no `S_EMIN` pass. The bench then did

```vhdl
while done  /= '1' loop wait until rising_edge(clk); end loop;
while done1 /= '1' loop wait until rising_edge(clk); end loop;
```

so the first loop exited at tick 219, by which time `done1`'s single-cycle pulse
at tick 217 was long gone, and the second loop waited forever. **The brief's
mechanism -- `done_r` cleared in the cycle it is raised -- is WITHDRAWN. It is
not what the RTL does and it is not what happened.**

### 4.3 The fix, on the clean design

```
cfg A rc=0 verdict=PASS
cfg B rc=0 verdict=PASS
cfg C rc=0 verdict=PASS

sim/tb_attn_emit.vhd:677:7:@87235ns:(report note): tb_attn_emit: PASS -- 40 layers x 96 elements ...
```

### 4.4 `DEADLINE`, measured rather than guessed

`hsk_chk`'s `NOTE_MAX => true`, worst start-to-done latency in cycles, clean
designs, per configuration of each unit's own harness:

| unit | A | B | C | DEADLINE set | margin |
|---|---|---|---|---|---|
| `attn_emit` | 497 | 211 | 1267 | 12000 | 9.5x |
| `attn_gate` | 404 | 85 | 1360 | 12000 | 8.8x |
| `attn_twiddle` | 136 | 41 | 391 | 4000 | 10.2x |
| `attn_softmax` | 371 | 294 | 305 | 4000 | 10.8x |
| `attn_recip` | 57 | 51 | 72 | 2000 | 27.8x |
| `attn_rope` | 717 | 144 | 1453 | 12000 | 8.3x |

Worst ack-to-release, same runs: **2 in configuration A and C, 1 in B, for every
one of the six.** That is structural, not a coincidence -- the ack edge sets
`state <= S_IDLE`, the next edge clears `done_r`, and the edge after that is the
first that reads `done` low. `REL_MAX` is 3.

### 4.5 The property on the CLEAN designs

Run before any mutant, in all three configurations of each harness:

```
clean emit:     A=PASS B=PASS C=PASS
clean gate:     A=PASS B=PASS C=PASS
clean twiddle:  A=PASS B=PASS C=PASS
clean softmax:  A=PASS B=PASS C=PASS
clean recip:    A=PASS B=PASS C=PASS
rope  cfg A -> PASS   cfg B -> PASS   cfg C -> PASS
```

### 4.6 Clause 1 (LIVENESS) has teeth: the five known mutations

The mutation is `if done_ack = '1' then` -> `if done_ack = '1' then done_r <= '0';`

```
e18 emit:     A=PASS           B=KILLED/LIVENESS  C=PASS
e18 gate:     A=KILLED/LIVENESS B=KILLED/LIVENESS C=KILLED/LIVENESS
e18 twiddle:  A=PASS           B=KILLED/LIVENESS  C=PASS
e18 softmax:  A=PASS           B=KILLED/LIVENESS  C=PASS
e18 recip:    A=PASS           B=KILLED/LIVENESS  C=PASS
```

and the message, from `sim/mutate_attn_emit.sh`'s own run:

```
sim/hsk_chk.vhd:190:13:@120085ns:(report failure): HANDSHAKE LIVENESS
  [attn_emit NGRP=1]: done did not rise within 12000 cycles of the layer being
  accepted.  THIS IS A TIMEOUT, reported by the bench and named: the unit never
  completed, which says nothing about whether its values would have been right.
```

**Read the `A=PASS` columns honestly.** At `ACK_LAG > 0` this mutation is
behaviourally within the contract: it releases `done` one cycle earlier than the
clean design, HOLD is satisfied because the release is on the acked edge, and
RELEASE permits up to 3. It is an equivalent mutant there. It destroys `done`
outright only when the ack precedes completion, and configuration B is the only
column that presents that. That is the precise sense in which the degenerate
configuration is not strictly weaker.

### 4.7 Clause 2 (HOLD) has teeth: the pulse mutant

`if done_ack = '1' then` -> `if true then`, i.e. `done` reverts to a bare pulse:

```
pulse emit:     A=KILLED/HOLD B=PASS C=KILLED/HOLD
pulse gate:     A=KILLED/HOLD B=PASS C=KILLED/HOLD
pulse twiddle:  A=KILLED/HOLD B=PASS C=KILLED/HOLD
pulse softmax:  A=KILLED/HOLD B=PASS C=KILLED/HOLD
pulse recip:    A=KILLED/HOLD B=PASS C=KILLED/HOLD
```

`B=PASS` is correct and is the clause being vacuous, not failing: with the ack
tied high there is no window in which `done` could fall unacked.

### 4.8 THE PRIZE -- the non-hanging sibling, measured BOTH ways

H1 replaces the trailing release

```vhdl
if state /= S_DONE then done_r <= '0'; end if;
```

with a release driven by the next layer's accept instead of by the ack
(`start` on `attn_emit`, `attn_twiddle`, `attn_softmax`; `cfg_tk` on
`attn_gate`, which has no `start` port; `s_tk` on `attn_recip`).

**With the `hsk_chk` instance REMOVED from the bench and nothing else changed:**

```
H1 WITHOUT the property, emit:    A=PASS B=PASS C=PASS
H1 WITHOUT the property, gate:    A=PASS B=PASS C=PASS
H1 WITHOUT the property, twiddle: A=PASS B=PASS C=PASS
H1 WITHOUT the property, softmax: A=PASS B=PASS C=PASS
H1 WITHOUT the property, recip:   A=PASS B=PASS C=PASS
```

**With it:**

```
h1 emit:    A=KILLED/RELEASE  B=KILLED/RELEASE  C=KILLED/RELEASE
h1 gate:    A=KILLED/RELEASE  B=KILLED/RELEASE  C=KILLED/RELEASE
h1 twiddle: A=KILLED/RELEASE  B=KILLED/RELEASE  C=KILLED/RELEASE
h1 softmax: A=KILLED/RELEASE  B=KILLED/RELEASE  C=KILLED/RELEASE
h1 recip:   A=KILLED/SPURIOUS B=KILLED/SPURIOUS C=KILLED/SPURIOUS
```

```
sim/hsk_chk.vhd:217:15:@5145ns:(report failure): HANDSHAKE RELEASE
  [attn_emit NGRP=1]: done was still high 3 cycles after the edge on which done
  and done_ack were both high.  The ack is not observable in done, so a consumer
  cannot tell this layer's completion from the next one's

sim/hsk_chk.vhd:166:11:@7085ns:(report failure): HANDSHAKE SPURIOUS
  [attn_recip]: done was ALREADY HIGH at the edge a new layer was accepted. ...
```

### 4.9 The re-measured tables

Mutation rows only; the CONTROL row is excluded from every "of N", and H1 is a
new row this track added, so it is counted in the AFTER column and not in the
BEFORE one. "Before" is
`docs/debugging/2026-08-29_attn-harness-verdicts-and-seeds.md` section 4.5.

| harness | before (killed / ABORT / survived) | after | moved |
|---|---|---|---|
| `mutate_attn_emit` | 20 / 2 / 0, of 22 | **22 / 0 / 1, of 23** | E18 ABORT -> KILLED(LIVENESS); **E19 ABORT -> SURVIVED**; H1 new, KILLED |
| `mutate_attn_gate` | 22 / 1 / 3, of 26 | **24 / 0 / 3, of 27** | M21 ABORT -> KILLED(LIVENESS, all 3); H1 new, KILLED |
| `mutate_attn_twiddle` | 21 / 1 / 0, of 22 | **23 / 0 / 0, of 23** | N19 ABORT -> KILLED(LIVENESS); H1 new, KILLED |
| `mutate_attn_softmax` | 13 / 1 / 2, of 16 | **15 / 0 / 2, of 17** | M5 ABORT -> KILLED(LIVENESS); H1 new, KILLED |
| `mutate_attn_recip` | 12 / 1 / 2, of 15 | **14 / 0 / 2, of 16** | N14 ABORT -> KILLED(LIVENESS); H1 new, KILLED |
| `mutate_attn_rope` | 28 / 2 / 0, of 30 | **29 / 1 / 0, of 30** | P25 ABORT -> KILLED(LIVENESS); P18 unchanged (ABORT:LANG) |

**The CONTROL row is SURVIVED in every one of the six**, which is the statement
that makes the rest of the table readable.

Survivors, named:

| harness | survivors |
|---|---|
| `mutate_attn_emit` | **E19** ("done is raised before the last mantissa has been accepted") -- documented in `rtl/attn_emit.vhd` as an equivalent mutant, with instrumented evidence, before this track existed |
| `mutate_attn_gate` | M3, M5, M11 -- unchanged, pre-existing, each read in that harness's prose |
| `mutate_attn_twiddle` | none |
| `mutate_attn_softmax` | M9, M13 -- unchanged, pre-existing |
| `mutate_attn_recip` | N6, N9 -- unchanged, pre-existing |
| `mutate_attn_rope` | none (P18 is an ABORT, not a survivor) |

### 4.10 Which of `mutate_attn_emit`'s rows were genuinely earned

Of the 22 rows the harness published as "RTL 21/22":

- **20 rows were earned in configurations A and C**, which have always been
  sound, and are unaffected by anything here: E1-E17 and E20-E22.
- **E18 was NOT earned.** Its only killer was the broken column, and it was a
  deadlock rather than a check. It is now a LIVENESS kill in configuration B and
  an equivalent mutant in A and C.
- **E19 was NOT earned, and it is a SURVIVOR.** The broken column was its only
  evidence.
- E17, E20 and E21 survive configuration B and are killed in A and C, so they
  never depended on the broken column at all.

---

## 5. Would the 10 ABORT rows SURVIVE if the abort were removed?

The previous track listed this as not verified. Seven of the ten are now
determined.

| row | was | now | survives? |
|---|---|---|---|
| `attn_emit` E18 | ABORT:WEDGE | KILLED (LIVENESS, cfg B) | no |
| `attn_emit` E19 | ABORT:WEDGE | **SURVIVED, all three** | **YES** |
| `attn_gate` M21 | ABORT:WEDGE | KILLED (LIVENESS, all three) | no |
| `attn_twiddle` N19 | ABORT:WEDGE | KILLED (LIVENESS, cfg B) | no |
| `attn_softmax` M5 | ABORT:WEDGE | KILLED (LIVENESS, cfg B) | no |
| `attn_recip` N14 | ABORT:WEDGE | KILLED (LIVENESS, cfg B) | no |
| `attn_rope` P25 | ABORT:WEDGE | KILLED (LIVENESS, cfg B) | no |
| `attn_rope` P18 | ABORT:LANG | ABORT:LANG | **NOT DETERMINED** |
| `attn_kv_axi` B1 | ABORT:LANG | ABORT:LANG | **NOT DETERMINED** |
| `attn_kv_axi` B4 | ABORT:LANG | ABORT:LANG | **NOT DETERMINED** |

**The six WEDGE rows: the abort was removable and none of them survives.** But
say precisely what removed it. For the five `done_r` rows and P25 the removal is
clause 1, and clause 1 is a timeout: the mutant genuinely never completes, so no
value check can be reached however the bench is written, and "KILLED" here means
the bench named the broken contract rather than the simulator running out of
clock. E19 is the only one of the six whose abort was NOT the mutant's fault at
all -- it was the bench's -- and it is the only one that survives.

**The three LANG rows are NOT answerable by removing anything.** A bound check
firing means the mutant indexed outside an array; there is no switch that lets
the run continue, and constructing an in-bounds sibling is writing a DIFFERENT
mutation, whose survival would say nothing about this one. That work is worth
doing and is not done here.

---

## 6. Measured and REJECTED -- do not retry

- **Do NOT "fix" configuration B by retuning `-gM_GAP` / `-gACK_LAG`.** The
  previous track considered and rejected this, and it was right: the wedge was
  a bench defect and retuning would have hidden it. The bench is fixed instead.
- **Do NOT state HOLD as "done high and ack low at edge k implies done high at
  edge k+1".** MEASURED: that formulation FALSE-FIRES on the CLEAN
  `rtl/attn_rope.vhd` in configurations A and C, because
  `sim/tb_attn_rope.vhd` acks with a one-cycle pulse
  (`done_ack_p <= '1'; cyc(1); done_ack_p <= '0';`) and the ack is already low
  on the edge where `done` falls:
  ```
  hsk_note.vhd:145:11:@7345ns:(report failure): HANDSHAKE HOLD [attn_rope]:
    done fell while done_ack was still low.
  ```
  An ack is an EVENT to remember, not a level to require. The committed clause
  is "done may fall only on or after an edge where done and done_ack were both
  high".
- **Do NOT set `REL_MAX` to 4 "for slack".** MEASURED: at 4,
  `mutate_attn_softmax`'s H1 releases at age 5 and **SURVIVES all three
  configurations with the property in place**. It is killed at 3. The other four
  units never release H1's `done` at all, so they are insensitive to the value
  and would have hidden the problem; `attn_softmax` is the one unit that pins
  it. A margin chosen for comfort rather than from a measurement is how a
  property stops measuring.
- **Do NOT report a clause at `severity error`.** `sim/mutverdict.py` tests for
  the bench's PASS line FIRST, so an error-severity violation is followed by the
  bench's own PASS and the mutant scores as a SURVIVOR with the violation
  printed above it. Every clause is `severity failure`.
- **Do NOT let `sim/hsk_chk.vhd` go unnamed to `sim/mutverdict.py`.** Without
  the extra bench-file argument a clause firing classifies as
  `ABORT:DUTASSERT(hsk_chk.vhd)` -- the exact "wrong in the safe direction"
  error the previous track hit on `kv_axi_harness.vhd`. All six harnesses pass
  `sim/hsk_chk.vhd` as the fourth argument.
- **Do NOT leave the harnesses' kill-reason grep at `report error`.** The
  clauses are `severity failure`, so `grep -E "report error"` matched nothing
  and printed a kill with an empty reason. It is now
  `grep -aE "report (error|failure)"`.
- **Do NOT use the `cfg_tk` release for H1 on `attn_emit` or `attn_twiddle`.**
  MEASURED: on those two, clearing `done_r` at `cfg_taken` instead of at `start`
  lands one cycle later, leaves `done` still high inside the bench's own
  `ACK_LAG` hold window, and is caught by the pre-existing "done fell before
  done_ack" check in all three configurations -- so it is NOT the hard variant
  and choosing it would have overstated what the property adds. The distance
  between this defect class being visible and being invisible is one cycle.
- **Do NOT name the property `sim/tb_hsk_chk.vhd` or anything matching
  `tb_*.vhd`.** `sim/regress.sh` discovers gate rows from that glob, and it
  would have become a gate row with no vectors and no top-level verdict.

---

## 7. Measurement traps hit, including my own

1. **My own first HOLD clause fired on a clean design.** Section 6. It was
   caught only because step 7 of the procedure runs every clean design through
   the property before any mutant -- which is the same discipline the CONTROL
   row enforces for a harness, applied to a checker. Had the mutants been run
   first, six benches' worth of "kills" would have been the checker being
   wrong.
2. **The brief's mechanism was wrong and plausible.** "`done_r` clears in the
   cycle it is raised" reads correctly against the RTL and predicts exactly the
   observed silence. It is still wrong, and the only thing that separated the
   two accounts was one `report` statement. Reasoning from RTL to a symptom
   cannot distinguish two causes that predict the same symptom.
3. **The cited line numbers were stale by 1 and 2.** Not enough to mislead,
   enough to confirm the warning. Symbols, not line numbers.
4. **A `--stop-time` wedge exits 0.** Nothing about the exit status of a wedged
   run distinguishes it from a pass. This is why the verdict comes from the log
   and why clause 1 has to exist at all.
5. **`ghdl -a` of a scratch copy of a bench emits
   `warning: entity "X" was also defined in file ...`.** It is benign and it is
   NOT an error, but in a loop that greps for "error" it looks like one; in a
   loop that greps for nothing it silently analyses the WRONG file into the
   workdir. Scratch copies were given their own workdir every time.
6. **Stripping the property from a bench with a regex that also matched its
   COMMENT.** The first `noprop` script asserted `'hsk_chk' not in s` and always
   failed, because the comment block above the instance names the file. The
   assertion had to be on `'entity work.hsk_chk'`. A guard that cannot pass is
   as useless as one that cannot fail, and it cost one run of five benches.
7. **The `Bash` tool's timeout caps at 600 s and silently kills a longer run.**
   A full gate asked for with a larger timeout was killed at 10 minutes with
   exit 143 and an empty log. Long runs go to the background.
8. **A gate run started before the last source edit is not readable.** One was
   started and then `hsk_chk.vhd` and `tb_attn_rope.vhd` were edited underneath
   it. It was killed and re-run rather than reported. `sim/regress.sh`
   self-isolates its own script by byte offset; it does NOT snapshot the VHDL.

---

## 8. The gate, full and unfiltered

```
 suite sim   PASS 66   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 92   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 92 passing, matches the recorded floor of 92
 REGRESSION: PASS
```

That is the LAST `OVERALL` line in the log, no `--only` and no `--quick`.

**Caveat on this number: the box was NOT quiet.** A second full `sim/regress.sh`
belonging to another track was in flight for most of it (`ps` showed a second
`/tmp/regress-self.*.sh` at 16 min elapsed while this one was at 34), and six
mutation harnesses had been run on the same box minutes earlier. Nothing failed,
so the contention did not matter here -- but a FAIL in this log would have had
to be re-run on a quiet box before being believed.

`BASELINE_PASS` was **91** when this track read `sim/regress.sh` and **92** by
the time the run finished; another track raised it mid-run. This track did not
edit `sim/regress.sh` at all: `sim/hsk_chk.vhd` is deliberately not a
`tb_*.vhd`, so it adds no gate row and moves no floor.

The gate exercises the property directly. All six instrumented benches are gate
rows and every one of them runs the four clauses at its generic DEFAULTS
(`ACK_LAG = 4`, i.e. configuration A), which is the column the `DEADLINE` and
`REL_MAX` measurements in 4.4 cover.

Each of the six was also run alone first, before the full gate:

```
sim/regress.sh --only attn_emit      OVERALL PASS 1   REGRESSION: PASS
sim/regress.sh --only attn_gate      OVERALL PASS 1   REGRESSION: PASS
sim/regress.sh --only attn_twiddle   OVERALL PASS 1   REGRESSION: PASS
sim/regress.sh --only attn_softmax   OVERALL PASS 1   REGRESSION: PASS
sim/regress.sh --only attn_recip     OVERALL PASS 1   REGRESSION: PASS
sim/regress.sh --only attn_rope      OVERALL PASS 1   REGRESSION: PASS
```

`--only` takes a SUBSTRING, not a regex, and a pattern that matches nothing
still prints `REGRESSION: PASS`; the `PASS 1` on each line is what says the row
actually ran.

**One honesty note on ordering.** After the full gate finished, four comment
lines over 80 columns were re-wrapped and two blank lines inserted in the six
benches, and one clause attribution was corrected in
`sim/mutate_attn_recip.sh`'s H1 prose (it is killed by clause 4, NO SPURIOUS
DONE, not clause 3). Those are comments and whitespace only. The six affected
rows were re-run individually afterwards -- the `--only` block above IS that
re-run -- and `sim/mutate_attn_recip.sh` was re-run in full
(14 / 0 / 3 of 17, unchanged). The 92-row gate itself was not repeated for a
comment re-wrap.

---

## 9. Explicitly NOT verified

- **Whether `attn_rope` P18 and `attn_kv_axi` B1/B4 would survive a checker.**
  Section 5. They are language aborts; answering needs a different, in-bounds
  mutation, which is a different measurement.
- **`sim/mutate_attn_rope.sh` has no H1 row.** The property is instantiated in
  `sim/tb_attn_rope.vhd` and kills P25, but the non-hanging sibling was not
  constructed for that unit, so `attn_rope`'s exposure to the RELEASE and
  SPURIOUS clauses is UNMEASURED. Five units, not six, carry that evidence.
- **`sim/mutate_attn_kv_axi.sh`, `sim/mutate_attn_kv_quant.sh`,
  `sim/mutate_attn_rescale.sh`, `sim/mutate_attn_score_q12.sh` were NOT re-run.**
  Only the config-B boilerplate comment was corrected in `rescale` and `rope`
  (`rope` was re-run). `rtl/attn_rescale_skel.vhd` (what
  `sim/mutate_attn_rescale.sh` actually mutates) has no `done_ack` at all --
  `grep -c done_ack sim/tb_attn_rescale.vhd` is 0 -- so the property does not
  apply to it.
- **`sim/mutate_attn_kv_seam.sh` was deliberately left alone.** Its 12 / 0 / 7
  was measured while TRACK C1 was editing `rtl/attn_block.vhd` underneath it and
  is to be re-taken by the dispatcher once C1 lands.
- **Whether the surviving mutants are equivalent.** The pre-existing prose that
  reads each survivor was not re-audited. E19's equivalence claim is
  `rtl/attn_emit.vhd`'s, not this track's, and it is an instrumented claim
  rather than a proof.
- **Whether the property would catch a `done` defect in the units that do NOT
  have this `S_DONE` shape.** Everything here is derived from one idiom shared
  by six units. `rtl/gdn_head_emit.vhd` -- the unit whose real defect gave this
  mutation its name -- was not touched and is not this track's file.
- **The composition.** Every clause is checked at one unit's boundary. Nothing
  here says `rtl/attn_block.vhd` acks its children correctly; that is
  `sim/tb_attn_block.vhd`'s question and TRACK C1's file.
- **Timing/area.** No synthesis was run. Only `sim/*.vhd` changed, so none is
  expected, but none was measured either.

---

## 10. Files changed

- `sim/hsk_chk.vhd` (new) -- the four-clause handshake property, one
  implementation for six benches. Not a `tb_*.vhd`, so not a gate row.
- `sim/tb_attn_emit.vhd` -- the joint done wait (the config-B fix), plus two
  `hsk_chk` instances, one per DUT instance.
- `sim/tb_attn_gate.vhd`, `sim/tb_attn_twiddle.vhd`, `sim/tb_attn_softmax.vhd`,
  `sim/tb_attn_recip.vhd`, `sim/tb_attn_rope.vhd` -- one `hsk_chk` instance
  each, with a measured `DEADLINE`.
- `sim/mutate_attn_{emit,gate,twiddle,softmax,recip,rope}.sh` -- analyse
  `sim/hsk_chk.vhd`, name it to `sim/mutverdict.py`, widen the kill-reason grep
  to `report failure`, and (all but `rope`) an H1 row.
- `sim/mutate_attn_{rescale,rope}.sh` -- the config-B boilerplate comment
  corrected in place.

No RTL was changed. `sim/regress.sh` was not changed by this track and
`BASELINE_PASS` is untouched.

---

## 11. Corrections

### WITHDRAWN 2026-08-29: the config-B mechanism in `2026-08-29_attn-harness-verdicts-and-seeds.md` section 4.2

That note says:

> The mechanism is in `sim/tb_attn_emit.vhd:455`: at `ACK_LAG = 0` the bench
> sets `done_ack <= '1'` once, before `start`, and holds it. The DUT's `done_r`
> is then cleared in the same cycle it is raised, and the bench's
> `while done /= '1' loop wait until rising_edge(clk); end loop` at `:486` never
> observes it.

**The second sentence is withdrawn.** `done_r` is not cleared in the cycle it is
raised; `rtl/attn_emit.vhd`'s trailing clear is guarded by `state /= S_DONE` and
`state` still reads `S_DONE` in that cycle, so `done` is high for exactly one
cycle and a single poll WOULD see it. The bench wedged because it polled two
instances' dones one after the other and they do not complete together. See
section 4.2 above for the instrumented evidence. That note flagged the
diagnosis as "DIAGNOSED, not fixed and not proven" in its own section 7, which
is why the first step here was to instrument rather than to trust it.

Append further dated CORRECTION sections here rather than editing the above.
