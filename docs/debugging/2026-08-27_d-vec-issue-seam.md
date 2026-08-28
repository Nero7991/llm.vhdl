# Subsystem D: closing the D-ctrl / D-vec seam, and two guards that were passing on a coincidence

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`.
New files: `rtl/seq_vec_issue.vhd`, `ref/seq_vec_chain_vec.c`,
`sim/tb_seq_vec_seam.vhd`, `sim/run_seq_vec_seam.sh`,
`sim/mutate_seq_vec_issue.sh`, `sim/mutate_ref_seq_vec_chain.sh`.
Existing files changed: `rtl/seq_vec_res.vhd` (one constant, one comment
correction), `ref/seq_vec_res_vec.c` (a `main` guard so the file can be used as
a library), `sim/tb_seq_vec_res.vhd` (`POISON` promoted from a constant to a
generic), `sim/run_seq_vec_res.sh` (two configurations added),
`sim/tb_seq_opdec.vhd` (one guard corrected), `sim/regress.sh` (registration).
**Tools:** GHDL 1.0.0, **mcode** backend (`ghdl -r` run directly; `ghdl -e`
produces no binary and silently succeeds). gcc for the references.
**No synthesis was run**, so every resource figure below is a COUNT FROM THE
RTL and is labelled DERIVED.
**Target:** `MODEL = QWEN35_9B`, `NCARDS = 1`. Designed for **~180 MHz**, which
is subsystem A's measured post-route figure at the card's real 0.717 V, not the
300 MHz the D specs were written against.
**Predecessors:** `2026-08-27_d-sequencer-first-units.md`,
`2026-08-27_d-sequencer-opcode-decode.md`,
`2026-08-27_d-seq-scalar-ordering-audit.md`,
`2026-08-27_d-vec-residual-numeric-contract.md`.

## The question

Verbatim, from the previous D pass's open list and repeated in this pass's
brief:

> `seq_vec_res` is not yet issued by `seq_opdec`. That seam has never been
> exercised. Each unit has only ever been verified against a stub of the other,
> which is precisely the condition that produced four findings in the previous
> pass. Close it: make `seq_opdec` actually issue `seq_vec_res`, and verify the
> pair together.

with the standing rules: a double oracle sharing no machinery with the RTL,
bit-exactness with no tolerance, mutation of the reference BEFORE the RTL
exists and of the RTL after, at least three handshake configurations of which
the degenerate one is not treated as weaker, and every guard proved to have
teeth against a deliberately broken copy.

## The answer

The seam is closed by a new unit, `rtl/seq_vec_issue.vhd`, and is verified with
**five real units in the loop and no stub between them** -- `seq_desc_fetch`,
`seq_opdec`, `seq_region_lock`, `seq_vec_issue`, `seq_vec_res` -- over **22
configurations, all passing**: 19 clean walks, bit-exact on every element of
every step of a chained residual against `ref/seq_vec_chain_vec.c`, and 3 fault
injections that abort with the expected error code and failing step.

Kill ratios, honestly:

| | killed | survived | of |
|---|---|---|---|
| the seam reference, `ref/seq_vec_chain_vec.c` | **11** | 2 | 13 |
| the seam RTL, `rtl/seq_vec_issue.vhd` | **11** | 5 | 16 |

All seven survivors were read. Two of the reference's are expected and are
explained in the script itself (a bound is an inequality; removing a term from
it only fails if some case reaches the tightened bound, and none does). All
five of the RTL's are **equivalent mutants under the CURRENT walker**, with a
structural argument given below and with the exact condition under which each
stops being equivalent.

**Two defects were found, and neither is in the new unit.** Both are in shipped
code, both had been green for a day, and both are the same shape -- a check
that was passing because its subject never varied or happened to agree:

1. **`rtl/seq_vec_res.vhd`'s negative-saturation branch had never been executed
   by any test**, and it contains an out-of-range `to_signed` that emits
   `NUMERIC_STD.TO_SIGNED: vector truncated` on every execution. It was
   unreachable in `tb_seq_vec_res` for one reason and one only: that bench
   poisons its padding lanes with **+21845**, so a masked lane that overruns
   the chosen shift saturates POSITIVELY. The seam bench poisons with -21846.
   One sign of one testbench constant was the whole difference.
2. **`sim/tb_seq_opdec.vhd`'s ordering guard was passing on a numeric
   coincidence.** It treats `seq_opdec`'s token-start HOST PUBLISH as a job
   completion and compares the host's exponent against the last captured
   exponent of the PREVIOUS token. Those two numbers are `3 + t` and
   `exp_of(489)`, and at `t = 1` both are **4**. Measured: the same shipped
   suite, unchanged except for `TOKENS=3`, **fails**.

## Why this and not something else

The remaining D work is the region banks, the AXI grant mux with `S_GRANT`, the
base-array and codebook load, the norm and the swiglu, and the E seam. The
brief named this one and the reasoning is worth restating because it is the
same reasoning three passes in a row have used: **every integration defect this
project has found came from a seam rather than from a unit**, and this was the
only place where two finished D units stood next to each other having never
been connected. The region banks and the grant mux both remain deferred for the
reasons the previous two passes recorded (a synthesis question, and a state
inside a unit this pass may not restructure).

## What the seam actually is, and why it is a unit and not wires

The two sides speak different protocols and neither is wrong.

**D-ctrl issues by BROADCAST.** `seq_desc_fetch` raises `u_start(u)` while a
20-signal `job_*` shadow describes the step -- but the shadow is only
guaranteed from the cycle `job_issue` pulses, which is the cycle AFTER
`u_start` was accepted, because `live_bank` and `issue_r` move on the same
edge. **A unit cannot read its parameters in the cycle it is started.**

**D-vec issues by VALUE.** `seq_vec_res` wants `i_n`, `i_exp_x` and `i_exp_e`
valid in the cycle it accepts `start`, and latches all three at that instant.

And two of those three values **are not in the descriptor at all**. The
descriptor names REGIONS; the EXPONENTS of those regions live in
`seq_region_lock`'s capture file. That file had a read port --
`exp_rd_region` / `exp_rd_seg` / `exp_rd_data` / `exp_rd_valid` -- which
`tb_seq_region_lock` drove directly and **which no unit in the design had ever
read**. `seq_vec_issue` is its first consumer.

So the adapter: accepts the broadcast start, latches the shadow one cycle later
when it is valid, looks up the two source exponents in the lock in two
consecutive states, and only then starts the engine by value. Eight states,
one action each.

### `u_ready` is the AND over every D-vec engine, and that is exact rather than lazy

`seq_desc_fetch` maps all three D-vec opcodes to ONE unit index and tests
`u_ready(cur_unit)` in S_ISSUE -- one clocked state before the adapter can know
which opcode is coming. The candidate opcode is on `chk_opcode` during
S_CHECK, but reading the `chk_*` group outside `chk_req` is documented trap a2
in `seq_opdec`: the prefetch bank is written beat by beat, so outside `chk_req`
those ports show half of one descriptor and half of the next. D runs one job at
a time, so the engines are idle together or not at all, and the AND is one gate
against a latched-candidate-opcode scheme that would have to take a position
on a2.

## The double oracle, and what it cannot certify

`ref/seq_vec_chain_vec.c` shares no state machine, no handshake and no control
flow with any RTL. It is a sequential loop over the steps with one array of
per-region exponents, which is the SPECIFICATION of the seam rather than a
model of the implementation.

**It does share `recipe()` with `ref/seq_vec_res_vec.c`, by including that file
as a library, and that is deliberate.** `recipe()` is the reference for the
arithmetic, it is mutation tested in its own right, and the RTL it is compared
against (`rtl/seq_vec_res.vhd`) shares nothing with it. Writing the chain's
arithmetic a second time would give two references that can disagree with each
other, which is worse than one. A mutation of `seq_vec_res_vec.c` now mutates
BOTH programs.

**Why a CHAIN is the right shape.** The residual is IN PLACE: it reads X,
writes X, and publishes X's new exponent, which `seq_opdec` captures at the
unit's first `done` and `seq_region_lock` latches at the commit; the NEXT
residual reads that exponent back out through `seq_vec_issue`. The feedback
path therefore runs through all five units, and a single lost, stale, swapped
or misrouted exponent does not produce one locally wrong step -- it
desynchronises every remaining step, with an error that GROWS. **A bag of
independent cases with the exponents handed in by the testbench cannot test
that path at all, because then the testbench IS the path.**

The chain oracles, neither of which restates the recipe:

| | oracle |
|---|---|
| C1 | the exact running sum, as `__int128` at a common dyadic grid, against a bound DERIVED from the recipe's rounding rules and ACCUMULATED step by step. No floating point and no tolerance |
| C2 | whole-chain exponent-shift invariance: add K to the initial exponent AND to every ER exponent; every mantissa of every step bit-identical, every published exponent moved by exactly K. The per-step O4 says one step depends only on the DIFFERENCE of its exponents; C2 says the CHAIN does, which is a different statement once the output exponent feeds the next input |
| C3 | coverage, printed every run and FAILING the generator on a zero column |

**What no data-driven oracle can see, stated up front: the ARBITRATION.**
Whether `u_ready` falls at the right instant, whether a start is accepted while
a completion is held, whether `done` survives an ack -- none of that is a
function of the input data. Those are covered by counting identities and
protocol guards in the testbench, which is a weaker instrument, and the
mutation table below says which mutations only they catch (P11 and P14 are
killed by nothing else).

## The procedure, in the order it was run

1. **Write the chain reference first and mutate it before any RTL exists.**
   13 mutations, in two classes: the chain MODEL (an oracle must catch it) and
   the ORACLES themselves with the model left alone (each must fail on a
   correct chain, or the oracle is a comment).
2. **Fix the coverage the reference could not reach by luck.** Two steps of the
   chain are CRAFTED, and the reasons are different: step 0 for the saturating
   clamp (which random mantissas essentially never reach), step 1 for `sh = 0`
   (which after a saturating step is a coin flip on the sign of one element).
3. **Write the adapter to the two protocols**, applying the three defect-class
   rules at design time rather than discovering them.
4. **Wire five real units together and run one configuration.** It failed
   immediately -- on the ER exponent, which was a STIMULUS gap, not a design
   defect (below).
5. **Sweep 22 configurations**, four producer skews, seven engine-side
   handshake disciplines, three stub disciplines, three lane counts, two
   tokens, three fault injections, and the real 4,096-element residual.
6. **Chase the one thing that was not an error but was not silence either**:
   six `NUMERIC_STD.TO_SIGNED: vector truncated` warnings per residual. That is
   finding 1.
7. **Mutate the RTL, then READ every survivor.** Five survivors, five
   structural arguments.
8. **Re-run the whole regression** and the ordering-guard teeth test.

## The evidence

### 22 configurations: 19 clean walks and 3 fault injections

Every clean row walks 37 descriptors, completes 36 jobs, latches 20 D-vec jobs
in the adapter, performs 20 pairs of exponent lookups, and verifies 8 chained
residuals bit-exactly on all 250 elements plus the poisoned tail.

```
producer skew
  memory fast, stub units slow (prefetch far ahead)        PASS
  memory fast, stub units instant                          PASS
  memory slow, stub units instant (starves the walker)     PASS
  memory slow, stub units slow                             PASS
the D-vec engine handshake, behind the same adapter
  done is a LEVEL held until the adapter's ack             PASS
  done is a ONE-CYCLE PULSE (the withdrawn convention)     PASS
  done drops on its own timer, not on the ack              PASS
  engine re-arms ready while still driving done            PASS
  start left unaccepted 20 cycles (> the adapter's 8)      PASS
  ready withheld 20 cycles after every completion          PASS
  y_exp valid for exactly ONE cycle of done                PASS
the stub units' completion discipline
  stub done is a one-cycle pulse                           PASS
  stub done stays asserted PAST its ack                    PASS
  stub re-arms on the ack while still driving done         PASS
the lane count, against the SAME chain vectors
  LANES = 4                                                PASS
  LANES = 16                                               PASS
  LANES = 4, slow memory, engine pulse, ready gap          PASS
two tokens back to back                                    PASS
the real 9B element count: NELEM=4096, 16 residuals        PASS
faults, one at a time
  element count past the engine port, on a residual   err=1 code=1 step=2  vi=2
  element count past the engine port, on a norm       err=1 code=1 step=3  vi=2
  a generator that appends into a D-vec destination   err=1 code=1 step=3  vi=5
```

`code=1` is ERR_UNIT from the walker; `vi` is `seq_vec_issue`'s own `err_code`,
which narrows ERR_UNIT to EC_NROWS (2) or EC_OFF (5).

**One property is confirmed here for the first time by a REAL producer rather
than by a synthetic one.** Every write beat `seq_vec_res` emits is routed
through `seq_region_lock`'s `wr_we`/`wr_gate` pair, and `residual writes dropped
by the lock = 0` in every clean configuration -- 32 beats per job at LANES = 8,
512 at the 4,096 configuration. The opcode-decode pass could only test that
window with a free-running strobe generator of its own; here it is the actual
unit's actual emission, and it lands inside `[iss_commit, cmp_valid]` at every
lane count and every skew.

### The chain reference, 8 steps, 6 per-step oracles plus C1 and C2

```
seq_vec_chain_vec: n=250, 8 chained residual steps, 6 per-step oracles + C1 + C2 clean
  coverage: sh=0 1 | sh>0 7 | saturating clamp 1 | SHMAX clamp 2 |
            ee above ex 2 | ee below ex 4 | output exponent moved 5 |
            n not a multiple of 16 1

seq_vec_chain_vec: n=4096, 16 chained residual steps, 6 per-step oracles + C1 + C2 clean
  coverage: sh=0 1 | sh>0 15 | saturating clamp 1 | SHMAX clamp 3 |
            ee above ex 7 | ee below ex 6 | output exponent moved 9 |
            n not a multiple of 16 0
```

### Reference mutations, 11 of 13 killed

| # | mutation | result |
|---|---|---|
| C1a | the feedback is cut: every step re-reads the INITIAL exponent | killed by C1 |
| C1b | the feedback is one step STALE | killed by C1 |
| C1c | the two exponents are swapped at every step | killed by C1 |
| C1d | the recorded output is the raw accumulator | killed by C1 |
| C1e | the data fed forward is the ORIGINAL X | killed by C1 |
| C1f | element 7 never receives its ER | killed by C1 |
| C2a | C1's bound drops the output-rounding term | killed by C1 |
| C2b | C1's bound drops both alignment terms | **SURVIVED, expected** |
| C2c | C1's bound drops the saturation term | **SURVIVED, expected** |
| C2d | C1 accumulates ER at the OUTPUT grid | killed by C1 |
| C2e | C2 shifts only the initial exponent | killed by C2 |
| C2f | C1's bound widened 2^12 AND the feedback cut (compound) | killed by C1 |
| C3a | every ER exponent equals its step's input exponent | killed by the C3 coverage gate |

**C2b and C2c are expected survivors and are kept for that reason.** A bound is
an INEQUALITY: removing a term tightens it, and a tightened bound only fails if
some element actually reaches it. Neither term is reached here, because step
0's saturation term is one output LSB while its real error is half of one --
the round and the clamp move in opposite directions -- and that slack swamps
the half-LSB alignment term for the rest of the chain. So the two say the bound
is SOUND BUT NOT TIGHT, which is worth knowing and is not a defect. **C2f is
the entry that shows the bound is not vacuous: widened by a factor of 2^12 it
still kills a cut feedback.**

### RTL mutations, 11 of 16 killed, over seven configurations

Configurations: **A** memory fast + stub units slow, **B** engine `done` is a
one-cycle pulse, **C** engine leaves `start` unaccepted 20 cycles and withholds
`ready` 20 after every completion, **D** LANES = 4 with a slow memory, **E** two
tokens, **F** an element count past the engine port, **G** a generator that
appends.

| # | mutation | killed by | survived |
|---|---|---|---|
| P1 | the element count is driven from the LIVE `job_n_rows` (class a) | -- | **ALL, equivalent** |
| P2 | the two source exponents are swapped | A B C D E G | F |
| P3 | both exponents read from `src`: the second lookup never moves the address | A B C D E G | F |
| P4 | the first exponent is captured one state LATE | A B C D E G | F |
| P5 | `u_y_exp` is a live pass-through of the engine port (class c) | A C D E F G | B |
| P6 | `u_done` is driven from the RAW engine `done` | **A B C D E F G** | -- |
| P7 | the job shadow is latched at the ACCEPT, one cycle early | A B C D E G | F |
| P8 | the completion payload is never captured | A B C D E | F G |
| P9 | the element-count range check is removed | F | A B C D E G |
| P10 | the destination-offset check is removed | G | A B C D E F |
| P11 | `v_start` is PULSED instead of held until `v_taken` | C | A B D E F G |
| P12 | the region numbers are driven live from `job_*` (class a) | -- | **ALL, equivalent** |
| P13 | the ack's engine select is taken from the LIVE `job_opcode` (class a) | -- | **ALL, equivalent** |
| P14 | the completion is waited on at a FIXED engine | **A B C D E F G** | -- |
| P15 | the `exp_rd_valid` check is removed | -- | **ALL, unreachable** |
| P16 | `u_done_epoch` is driven from the LIVE `job_epoch` (class a) | -- | **ALL, equivalent** |

The message that killed each one, so that "killed" is not merely "did not
print PASS":

```
P2   residual 0 read exponent 11 for region X, the chain says 12
P3   residual 0 read exponent 12 for region ER, the chain says 11
P4   residual 0 read exponent 0 for region X, the chain says 12
P5   u_y_exp CHANGED after the first cycle of u_done
P6   u_y_exp CHANGED after the first cycle of u_done
P7   residual 0 read exponent -24 for region X, the chain says 12
P8   residual 1 read exponent 0 for region X, the chain says 11
P9   residual 0 started with n = 0, the descriptor says 250
     adapter code (EC_NROWS) is 6, expected 2
P10  err_code (ERR_UNIT) is 3, expected 1   [the LOCK catches it two blocks later]
P11  steps_done is 0, expected 37           [the walk never starts]
P14  err is 1, expected 0                   [watchdog: the wrong engine's done]
```

### Every survivor, read

**P1, P12, P13 and P16 are equivalent mutants under the CURRENT walker, and the
argument is structural rather than empirical.** `seq_desc_fetch`'s `job_*`
group is a combinational decode of `dw(live_bank)`; `live_bank` moves only in
S_ISSUE, the fetch side writes only the PREFETCH bank, and D runs one job at a
time -- so `job_*` is stable for the entire interval from a job's `job_issue`
to the next job's `job_issue`, which strictly contains the adapter's whole
lifetime for that job. A live read and a latched read therefore see the same
value at every instant the adapter looks. **The latch is defence against a
future overlapped walker, not against today's**, and it stops being an
equivalence the moment `S_GRANT` or any other overlap lands -- the same shape
of argument as M7/M8 in the first-units document. The one class-(a) mutation
that is NOT equivalent is P7, reading `job_*` one cycle EARLIER than
`job_issue`, and it is killed by six of seven configurations.

**P15 is unreachable, and the proof is a property of the lock rather than of
the schedule.** `exp_rd_valid` is low only for a slot never written since the
lock reset. `seq_region_lock`'s verdict rejects consuming a FREE region, and a
region leaves FREE only at a producing commit whose completion sets
`exp_vld` for that slot. Since D runs one job at a time, the consumer's check
happens strictly after the producer's completion, so any region a step is
allowed to consume already has its segment-0 exponent captured. The guard is
kept because it costs one gate and stops being redundant if the append-only
rule is relaxed or if a segment-scoped read is added; it is recorded here as a
guard whose subject is currently a constant, which by this project's own rule
makes it a comment until then.

**P5's survivor column is the informative one.** Under configuration B the
engine's `done` is a one-cycle pulse, so the stub stops advancing its
deliberately-moving garbage exponent the moment `done` falls: the port then
holds a constant, and "captured once" and "re-read every cycle" become the same
waveform. That is exactly the condition under which the mutation is
semantically equivalent, which is what a survivor column is for -- and it is
why the moving garbage was introduced at all (below).

**The degenerate configuration and the lagged one each catch what the other
misses, and the mutation table is the evidence rather than the assertion.**
P11 -- `v_start` pulsed instead of held -- is killed by C alone, the
configuration where the engine leaves `start` unaccepted for 20 cycles; every
prompt-accept configuration takes the pulse in the cycle it appears and cannot
tell a pulse from a level. P5 runs the other way: it survives B, the pulsed-
`done` configuration, and is killed by all six others including the prompt
ones. **Neither end of the sweep is weaker, and dropping either would leave one
of those two mutations alive.**

**P8, P9, P10 and P11's survivor columns are reachability, not gaps.** F and G
abort the token in the first three steps BY DESIGN, so they reach almost none
of the chain; P9 is only reachable by F and P10 only by G, since those are the
only configurations that present the malformed field; and P11 needs an engine
that does not accept `start` immediately, which is only C.

## The two defects found, and how

### Defect 1: a branch of `seq_vec_res` that no test had ever executed

**Symptom.** Six `NUMERIC_STD.TO_SIGNED: vector truncated` warnings per
residual step, at two instants per token, in an otherwise fully passing run.
Not an error, not silence.

**Cause.** `rtl/seq_vec_res.vhd`'s negative-saturation branch wrote

```vhdl
std_logic_vector(-to_signed(2**(MANT_W-1), MANT_W))
```

which asks `numeric_std` to convert **+32768** into 16 signed bits. It does not
fit; the conversion truncates (warning) to -32768, and the unary minus then
overflows back to -32768. The value is right, twice by accident, and the
warning fires on every execution.

**Why it had never fired.** The branch is only reachable by a lane MASKED OUT
of the final partial group. A masked lane takes no part in the magnitude fold,
so the chosen `sh` says nothing about its accumulator and it can overrun the
int16 clamp in either direction. `tb_seq_vec_res` poisons its padding lanes
with **+21845**, so every overrun there is POSITIVE and uses the well-formed
`to_signed(32767, 16)`. The seam bench poisons with **-21846**. That is the
entire difference, and it means the branch had never been executed by any test
in the repository.

**Measured, on the shipped unit testbench with the OLD spelling:**

```
POISON = +21845 :  0 truncation warnings   PASS
POISON = -21846 : 71 truncation warnings   PASS
```

**Fix, three parts.** The constant is spelled `to_signed(-(2**(MANT_W-1)),
MANT_W)`, which is -32768 and fits exactly. `POISON` in `tb_seq_vec_res` is
promoted from a constant to a generic and `sim/run_seq_vec_res.sh` sweeps both
signs. And the unit's own header comment is CORRECTED: it claimed negative
saturation was "UNREACHABLE by construction", which is true only for a
PARTICIPATING lane. The RTL itself is right -- `o_sat` is guarded by `m6(i)`
and the write by `w_be`, so neither the summary flag nor the region is affected
-- but the sentence was too strong and the correction is appended in place.

**Verified after the fix:** 0 warnings at both poison signs, both PASS.

### Defect 2: an ordering guard passing on a numeric coincidence

**Symptom.** The seam bench's copy of `tb_seq_opdec`'s `ord_chk` guard fired at
the start of the SECOND token:

```
tb_seq_vec_seam: the captured exponent CHANGED between y_exp_taken and cmp_valid
```

**Cause.** `seq_opdec` raises `cmp_valid` in state T_PUB at every token start,
carrying the HOST's exponent for region X. No unit ran, so there is no
`y_exp_taken` to pair it with -- and the guard was still holding the LAST job
of the PREVIOUS token. It compared that against `host_x_exp`.

**The part worth keeping.** The shipped `tb_seq_opdec` has the identical guard,
runs two tokens by default, and PASSES -- because its two numbers are
`exp_of(489) = 4` and `host_x_exp = 3 + t = 4` at `t = 1`. They agree by
accident. Measured, on the shipped suite with nothing changed but the token
count:

```
tb_seq_opdec  TOKENS=2 : PASS
tb_seq_opdec  TOKENS=3 : assertion failure -- 0000000000000100 at the capture,
                         0000000000000101 at the commit
```

**Fix.** Both guards now ignore `cmp_valid` while `host_busy` is high, and
reset their state there. `host_busy` is `seq_opdec`'s own statement that the
token-start publish sequence is running and no job is being completed;
`tb_seq_opdec` already uses it to gate its commit-mismatch check, so the fix
is the existing idiom rather than a new one.

**Teeth re-checked after the fix.** `sim/ord_teeth_seq.sh` still reports TEETH
on all four deliberately broken copies, including D2 (`seq_opdec` capturing at
`job_cmp` instead of at the first `done`), which is the break this guard
exists for.

## Measured and REJECTED -- do not retry

- **"The stub A unit can report a step-derived exponent for ER."** It cannot,
  and this was the first run's failure. The residual's arithmetic depends on
  ER's exponent, and the chain reference has already fixed what the answer is
  for the exponent IT chose; a stub reporting `exp_of(step)` instead makes
  every downstream comparison a mismatch that looks exactly like a seam defect.
  The ER-producing stub takes its exponent from the vector file; every OTHER
  stub keeps the step-index formula, so a shared or stale capture is still a
  WRONG NUMBER and not a repeat. **The rule: a stimulus value the reference
  depends on must come FROM the reference, and every other stimulus value must
  come from a formula that varies.**
- **A CONSTANT garbage value on the stub engine's `y_exp` after its decay
  window.** With it, mutation P5 -- `u_y_exp` re-read live instead of captured
  -- SURVIVES every configuration, because after the first cycle a re-read and
  a capture return the same constant. The garbage has to MOVE, one step per
  cycle, or "captured once" and "re-read every cycle" are the same waveform.
  Same family as the predecessor's `EXP_DECAY` finding, one level up.
- **Injecting a fault that makes `exp_rd_valid` low.** There is no such fault
  reachable through the descriptor table, and the reason is a theorem about
  `seq_region_lock` rather than an accident of this schedule -- see P15 above.
  Four constructions were considered and all four are rejected by an EARLIER
  check: naming an unproduced region is caught by the lock's FREE-consume rule;
  writing a non-zero segment first is caught by append-only; a non-zero
  `dst_offset` is caught by append-only; and `n_rows = 0` is caught by
  `seq_desc_fetch`'s own descriptor check. **Do not spend time on this again
  without first relaxing one of those rules.**
- **A `ROWS_BIG` fault of 9,000 elements.** The LOCK rejects it first, as
  ERR_DESC, because the region is not that large, so the ADAPTER's range check
  goes untested and the run reports the wrong unit. The working construction is
  `n_rows = 2**VN_W` with every region sized to `2**VN_W`: the lock's capacity
  bound then passes by exactly one element and only the adapter can catch it.
  **Two checks that reject the same stimulus test as one check** -- the same
  lesson as the predecessor's append-only-versus-capacity trap, in a new place.
- **A non-zero `dst_offset` fault on its own.** `seq_region_lock`'s append-only
  rule rejects any offset that is not the region's fill pointer, so the adapter
  never sees it. The fault has to be a COMPOUND: the destination is not
  released, the region is sized for two copies, and the offset is the fill
  pointer -- a generator that legitimately APPENDS. The lock then accepts it
  and only the adapter can say that a two-pass renormalise cannot append,
  because its output exponent is a property of the whole region.
- **Re-deriving the adapter's `u_done_epoch` and `u_y_exp` in the testbench**
  because they are slices of vectors other generate blocks also drive. That
  puts a model of the DUT inside the bench and leaves the DUT's real outputs
  untested. The fix is two intermediate signals and two type conversions; the
  values come out of the DUT unchanged.
- **Reading the lock's exponent file from the testbench to check the chain.**
  `exp_rd_region`/`exp_rd_seg` now have a real consumer, so a second driver is
  an elaboration error. It is also unnecessary: the NEXT residual's `v_exp_a`
  IS that readback, and checking it there tests the whole path rather than the
  file.

## Measurement traps hit

- **`V_ERR` as a state name collides with a port named `v_err`.** VHDL is
  case-insensitive, so GHDL reports `identifier "v_err" already used for a
  declaration` at the state assignment and then a cascade of unrelated type
  errors. Renamed `V_FAIL`.
- **This GHDL build rejects VHDL-2008's unary `and` reduction.** `(and
  v_ready) = '1'` analyses as `no function declarations for operator "="`,
  which reads like a type problem in the comparison rather than a missing
  operator. Spelled as a function.
- **A `head -6` on the sweep output hid a failing configuration.** The two-token
  run printed token 0's results and its FAILURE line was past the cut, so the
  row looked clean. Every runner line in `sim/run_seq_vec_seam.sh` now greps
  for `PASS|FAIL` explicitly, and the two-token failure was found by running
  that one configuration on its own.
- **Bash quoting of VHDL anchors.** The first version of
  `sim/mutate_seq_vec_issue.sh` passed anchors as shell arguments. VHDL is full
  of single quotes (`'1'`, `'0'`), one description contained a backtick, and
  another contained an apostrophe; between them they produced a command
  substitution, a syntax error at a line 40 lines later, and one mutation whose
  anchor silently changed. The anchors are now built in ONE python pass and the
  shell only runs the results. **An anchor that stops matching because of shell
  quoting is a mutation that reports a survivor for the wrong reason.**
- **`--max-stack-alloc=0` again.** The chain vectors are process variables of
  `NRES * NELEM` integers and exceed ghdl-mcode's 128 KB default at the 4,096
  configuration.

## Resource counts -- COUNTS FROM THE RTL, NOT MEASURED UTILISATION

No synthesis was run.

| | `seq_vec_issue` at NVOP = 3 |
|---|---|
| DSP48E2 | **0** |
| RAMB36 | **0** |
| FF, total | **~124** |
| of which | job shadow 61 (`j_n` 13, `j_ep` 4, three region bytes 24, `j_hasb` 1, `j_sel` 2, the exponent read address 8, plus `j_step` 11 which exists ONLY to name the step in the STRICT reports and synthesises away with them); the two looked-up exponents 32; the completion capture 17 (`y_r` 16, `eerr` 1); `ecode` 4; the FSM and the two observation pulses 8 |

The 0-DSP claim is a construction argument: there is no `*` on any datapath and
the only products in the file are elaboration-time constants (`2**VN_W`,
`(j_sel+1)*EXP_W`, the latter a constant-scaled index into a vector, so a
3-way 16-bit mux in LUTs). The 0-RAMB claim is structural: nothing is
memory-shaped.

Running total for D as built: `seq_desc_fetch` ~1,222 + `seq_region_lock`
~1,036 + `seq_opdec` ~118 + `seq_vec_res` ~2,900 + `seq_vec_issue` ~124 =
**~5,400 FF, 0 DSP, 0 RAMB36**, against D section 12's ~15-25K FF estimate.

**Timing, DERIVED and not measured.** Designed for ~180 MHz. No state holds two
of {barrel shift, wide add, wide compare, bus mux, multiply} in series. The
deepest path is `V_RDA`/`V_RDB`: register `erd_r` -> a 4-bit address add
(`region*SEGS`, SEGS = 3, so a shift and an add) -> a 42-entry 16-bit
register-file mux inside `seq_region_lock` -> register `e_a`. One bus mux and
one narrow add, register to register, and it is the only path that leaves this
unit and comes back. The range compares that qualify the job are in `V_ARM`, a
different state from the read they qualify, deliberately.

**The die is at about 75% DSP rather than 90%** after `ROWS_IF = 48` returned
330 DSP, so a design that spends a few DSP to remove a timing hazard is a good
trade tonight. This unit spends none, and there is nowhere in it that a DSP
would help: every operation is a compare or a mux.

### Regression

```
bash sim/regress.sh --jobs 4
 suite sim   PASS 44   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 70   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 REGRESSION: PASS
```

70 against the 69 baseline, and the one extra is `tb_seq_vec_seam` itself. It
is deliberately NOT on `--quick`'s exclusion list: it is a seam test, which
that list otherwise drops, but it runs in under a second on the short schedule
and there is no reason to lose the coverage.

`sim/ord_teeth_seq.sh` still reports TEETH on all four deliberately broken
copies after the guard change, including D2, which is the break the corrected
guard exists for.

## Corrections to earlier documents that this work implies

- **`2026-08-27_d-vec-residual-numeric-contract.md`'s statement that negative
  saturation is "UNREACHABLE by construction" is WITHDRAWN as written** and
  replaced by: unreachable for a PARTICIPATING lane; reachable for a lane
  masked out of the final partial group, where it is correctly excluded from
  `o_sat` and from the write byte-enables. The unit's own header carries the
  correction in place.
- **`2026-08-27_d-seq-scalar-ordering-audit.md`'s verdict on `seq_opdec` still
  stands** (the unit is clean), but its `ord_chk` guard was not sound across a
  token boundary and passed on a coincidence. The audit's own rejected-approach
  entry -- "a guard whose subject is a constant is a comment" -- has a sibling:
  **a guard whose two subjects happen to be equal is also a comment**, and it
  is harder to spot because nothing about it looks constant.
- `2026-08-27_d-vec-residual-numeric-contract.md`'s open item "this unit is not
  connected to `seq_opdec`" is **closed**.

## Open, not yet answered

- **Four class-(a) mutations of the adapter are equivalent today**, because the
  walker's broadcast shadow is stable for a whole job. They must be re-run the
  moment anything overlaps -- `S_GRANT`, or a second unit running concurrently.
  The latch is right; it is currently untestable.
- **The `exp_rd_valid` guard is unreachable** and is therefore, by this
  project's own rule, a comment until one of the four rules listed above is
  relaxed.
- **The seam's arbitration has no independent oracle** and cannot be given one:
  a golden model of an issue handshake that did not share the handshake would
  be the handshake written twice. It is covered by counting identities and by
  P11 and P14, which nothing else kills. Proposed instead, if it is ever worth
  more: a separate PROTOCOL MONITOR written from the port contract alone --
  `u_ready` low from the accept to the ack, `v_start` held until `v_taken`,
  exactly one `v_taken` per `iss_lat`, `u_done` never falling except at
  `u_ack` -- which is an independent statement of the contract even though it
  is not an independent implementation of it.
- **The norm and the swiglu are still stubs**, so two of the three engines
  behind this adapter are not real. The adapter's dispatch is exercised by
  them, its arithmetic path only by the residual.
- **The synthetic schedule is nine steps per block, not sixteen.** The
  descriptor FORMAT is the real one (`seq_tbl_pkg.mk_desc`), and the 4,096
  element count is the real one, but the real 491-descriptor table is not
  walked through this seam -- it contains B and C jobs whose region traffic
  this bench models as stubs. Walking it here would need the A/B/C stubs to
  produce real region contents, which is a bigger stimulus than the seam
  needs.
- **No synthesis, so no Fmax**, and the claim most worth testing is now the
  round trip named above: `seq_vec_issue`'s address register out, through
  `seq_region_lock`'s exponent-file mux, back into `e_a`, in one clocked state
  at ~180 MHz.
- **The region banks still do not exist.** This bench models them, and the
  model asserts the obligations (unconditional 1-element write, 1-cycle
  registered read, no ready on either) rather than proving them.
- **Hazard B7 (E's unstallable stream into residual pass 1) is untouched** and
  returns at `NCARDS > 1`.
