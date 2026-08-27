# Subsystem D: the opcode-to-region decode, and four things that only appear when the units are connected

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. New files only:
`rtl/seq_opdec.vhd`, `sim/tb_seq_opdec.vhd`, `sim/run_seq_opdec.sh`,
`sim/mutate_seq_opdec.sh`. Nothing existing was edited; two interface changes
that `seq_desc_fetch` needs are PROPOSED below rather than made.
**Tools:** GHDL 1.0.0, **mcode** backend (`ghdl -r` run directly; `ghdl -e`
produces no binary and silently succeeds). No synthesis was run: every resource
number below is a COUNT FROM THE RTL and not a measured utilisation.
**Target:** `MODEL = QWEN35_9B`, `NCARDS = 1`, from `rtl/model_cfg_pkg.vhd`.
491 descriptors per token.
**Predecessor:** `docs/debugging/2026-08-27_d-sequencer-first-units.md`.

## The question

Continue subsystem D. The obvious next unit is the opcode-to-region decode that
sits between `seq_desc_fetch` and `seq_region_lock` and currently lives in
`sim/tb_seq_region_lock.vhd` as a function. Build it to the same standard: the
real table, independently skewed producers, fault injection checking the code
AND the failing step, and mutation testing with every survivor read.

## The answer

`rtl/seq_opdec.vhd` exists and is verified over **22 configurations**, all
passing, with **11 of 11 mutations killed**. It is the first test that connects
the three D units to each other rather than each to a stub of the other.

Connecting them is what produced the result worth keeping. **Four defects and
gaps were found that neither existing unit testbench can reach**, because each
of those testbenches contains its own model of the interface and therefore
tests its own reading of it:

1. **Nothing published the host-written X region.** D section 3.2 leaves the
   embedding row on the host and section 5.1 lists the host as a producer of X,
   but every mechanism that moves a region out of FREE is driven by a
   DESCRIPTOR, and the host's write has no descriptor. With the locks reset at
   `go`, the first step of the token -- `attn_norm`, which reads X -- consumes
   a FREE region and is correctly rejected as ERR_LOCK. The token cannot start.
   `tb_seq_region_lock` could not see it: it modelled the host write as a
   synthetic step 0 of its own plan. `tb_seq_desc_fetch` could not see it: it
   has no locks.
2. **`seq_region_lock` has no soft reset, and D section 10's error policy needs
   one.** On an aborted token `job_cmp` never fires, so the lock keeps a live
   committed job and leaves regions HELD; the next token's first commit lands on
   top of it. The only reset is `rst`.
3. **`seq_desc_fetch`'s candidate port group is incomplete for the decode that
   has to sit on it.** It exposes `chk_opcode/src/dst/dst_off/n_rows` and no
   `chk_src2`, so the second operand cannot be checked before the unit starts.
   The check necessarily runs at commit and its abort lands one step late.
4. **A mid-job lock violation has nowhere to be reported until the next
   descriptor check**, because `seq_desc_fetch` reads `chk_bad` only in S_CHECK.
   Consequence, now a tested invariant rather than a surprise on hardware:
   **`err_step` in ERR_INFO names the step AFTER the offender.**

And one open item from the predecessor is now **measured rather than argued**:
D section 5.3's release rule contradicts D section 4.2's own schedule. Running
the real table with `REL_NAIVE` -- section 5.3's sentence "the consumer's `done`
returns R to FREE" applied literally -- fails at step 2 with ERR_LOCK, because
the first of the six consecutive XN readers frees XN and the second consumes a
region nobody produced. It was an argument from reading; it is now a run.

## Why this unit, of the candidates offered

The remaining D work is: the base array and codebook load, the opcode-to-region
decode, the region banks, the AXI grant mux with `S_GRANT`, D-vec, and the E
seam. The decode was picked, and the reasoning matters more than the choice:

- **It is the only one that closes an existing gap rather than opening a new
  one.** Two units shipped and had never been connected. Every hour spent on a
  third independent unit widens the set of seams nobody has tested.
- **The grant mux was the strong alternative and was deliberately deferred.**
  `S_GRANT` is a state INSIDE `seq_desc_fetch`, which this pass may not modify,
  so a grant unit built now would be verified against a stub sequencer -- the
  exact condition that hid all four findings above. It should be built together
  with the `seq_desc_fetch` change that hosts it.
- **The region banks need synthesis to answer their actual open question** (can
  they deliver an unconditional 1-element write and a 1-cycle 512-bit read
  through a three-way source mux at the real clock). Building them without
  synthesis would produce RTL and no answer.

**`S_GRANT` was NOT built, so the M7/M8 equivalence argument in the predecessor
document still holds and the sticky mechanism has not needed re-testing.** That
is stated because the brief flagged it: the moment `S_GRANT` lands, "there is no
reachable state between `start` acceptance and `S_WAIT`" stops being true and
those two mutants become non-equivalent.

## The procedure, in the order it was run

1. **Read what the decode actually has to produce**, from
   `sim/tb_seq_region_lock.vhd`'s plan builder, and separate it into what one
   descriptor can say and what it cannot. Three things it cannot: the consume
   mask, the exponent segment, the release mask. Section "what the descriptor
   cannot say" below.
2. **Write the decode with the check/commit split as the primary mechanism.**
   The walker asks for a verdict in S_CHECK from the PREFETCH bank and issues
   one clocked state later, by which time the banks have SWAPPED. A commit
   driven from the live `chk_*` port moves the locks for the wrong step.
3. **Connect all three and run one clean token.** This is where finding 1
   appeared, immediately, as ERR_LOCK at step 0.
4. **Add the token-start sequence** (reset the locks, publish X, then release
   the walker) and re-run.
5. **Sweep the four producers independently.** Memory, units, write stream,
   exponent lifetime.
6. **Inject one fault at a time** and check the ERROR CODE and the FAILING STEP,
   not merely that something failed.
7. **Mutate, then read every survivor column.**

## The evidence

### 22 configurations, all PASS

Every clean row walks 491 descriptors, starts 490 jobs (END_TOKEN starts
nobody), completes 490, verifies 489 captured exponents (lm_head produces no
region), and observes 490 `y_exp_taken` pulses -- two tokens back to back.

```
producer skew
  memory fast, units slow (prefetch far ahead)        PASS
  memory fast, units instant                          PASS
  memory slow, units instant (starves the walker)     PASS
  memory slow, units slow                             PASS
  turnaround gap on every unit                        PASS
completion discipline
  done is a ONE-CYCLE PULSE (withdrawn convention)    PASS
  done drops on its own timer, not on the ack         PASS
  done stays asserted PAST its ack                    PASS
  unit re-arms on the ack while still driving done    PASS
the write stream, skewed against the job latency
  dense writes, one per cycle                         PASS  7,824 strobes/2 tokens
  sparse writes, long gaps                            PASS
  no writes at all                                    PASS
the produced exponent's lifetime
  y_exp valid for ONE cycle, units slow               PASS
  y_exp valid for ONE cycle, units instant            PASS
  y_exp valid for ONE cycle, done is a pulse          PASS
  y_exp valid for 3 cycles                            PASS
D section 5.3 against D section 4.2
  REL_NAIVE                            err=1 code=2 (ERR_LOCK) step=2
faults, one at a time
  rogue exponent write into a HELD region at step 8
                                       err=1 code=2 step=9, viol_step=8
  write strobes that outlive their job err=1 code=2, err_step-viol_step=1
  src2 names a region the opcode does not read at 200
                                       err=1 code=3 (ERR_DESC) step=201
  n_rows past ADDR_W with a real dst at 300
                                       err=1 code=3 step=300
  a QKV offset that is not a segment boundary at 2
                                       err=1 code=3 step=2
```

Two of those rows carry the b2 finding as a numeric invariant rather than as a
sentence: `err_step - viol_step = 1` exactly. The rogue write happens during
step 8's job and the walker reports step 9.

### Mutations -- 11 of 11 killed

| # | mutation | killed by | survived |
|---|---|---|---|
| O1 | the commit reads the LIVE `chk_*` port instead of the latch (a1) | **A B C D E F G H I** | -- |
| O2 | the produced exponent is captured at `job_cmp`, not at first `done` (a3) | **A B C D E F G H I** | -- |
| O3 | the captured exponent is re-latched every cycle `done` stays high | A B E F G H I | C D |
| O4 | the consume mask forgets the opcode's implied regions (B's four, C's three) | A B C D E F | G H I |
| O5 | the release mask is dropped: nothing is ever returned to FREE | A B C D E F | G H I |
| O6 | `n_rows` passed through even when the step has no destination region | A B C D | E F G H I |
| O7 | the exponent segment is always 0: q, k and v share one capture slot | A B C D E F G H | I |
| O8 | the `src2` consistency check is removed | F | A B C D E G H I |
| O9 | the host-written X region is never published (finding 1, undone) | **A B C D E F G H I** | -- |
| O10 | the locks are not reset between tokens (finding 2, undone) | A B C D | E F G H I |
| O11 | a mid-job lock violation is not forced into the next check (b2) | E F H | A B C D G I |

Configurations: A prefetch far ahead with `y_exp` valid for one cycle,
B instant units, C one-cycle `done` pulse, D dense writes with `y_exp` valid for
three cycles, E rogue exponent write, F `src2` fault, G REL_NAIVE, H late
writes, I bad segment offset.

**Every survivor column was read and none is a gap.** O8 is only reachable by
the `src2` fault; O11 only by the three configurations that produce a violation;
O4, O5, O6 and O10 only by configurations that walk far enough to matter, and
the five fault configurations abort in the first few steps by design. O3's two
survivors are the informative ones and they are correct: under C the `done`
pulse is one cycle wide, so there is no second cycle to re-latch in; under D the
exponent stays valid for three cycles, so re-latching still reads the right
value. Both are exactly the configurations in which the mutation is
semantically equivalent, which is what a survivor column is for.

### What the descriptor format cannot say

Three things the lock needs that D section 6.1's header does not carry. All
three are resolved here, all three are DECISIONS rather than derivations, and
all three are recorded as OPEN.

| what | why the header cannot say it | what was done |
|---|---|---|
| the CONSUME MASK | B reads four regions (QKV, Z, BETA, ALPHA) and C reads three (QG, KIN, VIN). The header has two region bytes, `src` and `src2`. Two bytes cannot name four regions | `OPC_CONS`, a per-opcode extra-consume mask as a GENERIC; the full mask is `bit(src) or OPC_CONS(opcode)` |
| the exponent SEGMENT | QKV carries three captured exponents; there is no segment field | inferred from `dst_offset` against `MSEG_OFF1`/`MSEG_OFF2` generics, with an offset that is not a boundary rejected as ERR_DESC rather than mapped to segment 2 |
| the RELEASE MASK | it is a LIVENESS property of the whole schedule, not of one descriptor | the `rel_mask` port, exactly as `seq_region_lock`'s `iss_rel` states the shape of the fix without inventing the field |

**The cost of the first two is worth stating plainly: the region map leaks out
of the table and into the build.** D section 4.4's property is that the schedule
is DATA -- a smaller model is a shorter table and not different gateware -- and
a generic keeps that true across `MODEL` but NOT across D section 5.1's PACKED
region map, which unions {QKV, QG, G}, {Z, U} and {Y, H} and therefore changes
B's and C's consume sets. A 16-bit `cons_mask` descriptor field would make it
data again; word 7 of the header is reserved and checked-zero, so the room
exists. This has not been decided.

## Measured and REJECTED -- do not retry

- **"`chk_*` gives the release mask its missing lookahead for free."** It does
  not, and it is the most attractive wrong idea in this unit. `chk_opcode`,
  `chk_src` and the rest are CONTINUOUS assignments off the prefetch bank, so
  during a job they appear to show the NEXT descriptor -- which is exactly what
  a liveness rule needs. But the prefetch is eight 64-bit beats written one at a
  time and `pf_ready` is not exposed, so outside `chk_req` the port shows a
  descriptor that is half step n and half step n+1. Reading it there is defect
  class (a) one level down. Nothing in `seq_opdec` reads `chk_*` outside
  `chk_req`, deliberately.
- **A local rule for the release mask.** Enumerated against the real table:
  every region except XN is released by its only consumer, so "release
  everything consumed except an in-place destination" -- D section 5.3 read
  literally -- is right for thirteen of the fourteen regions and wrong for XN,
  which is read by six consecutive A jobs. There is no local rule, because the
  question "is this the last reader" is not answerable from one descriptor.
  Measured: `REL_NAIVE` fails at step 2, ERR_LOCK. **The one-region exception is
  the whole problem; a rule that is right 13/14 of the time is not a rule.**
- **Firing the hazard-A3 rogue exponent write on the descriptor-check counter.**
  It passed against a CORRECT lock for two runs and reported a design defect
  that is not there. A region moves to HELD at the COMMIT, and the check is one
  or more cycles earlier; a write fired on `n_chk` lands while the region is
  still VALID, where a correct lock accepts it. The working trigger is
  `job_valid = '1' and job_step = XW_AT`. **Same shape as the predecessor's
  `STALE_HOLD=5, JOB_LAT=4` trap: a test whose timing is set by the wrong event
  tests the wrong event.**
- **Modelling the region write-acceptance window as `job_valid`.** It is one
  cycle too narrow and it produced 490 false failures. `seq_desc_fetch` clears
  `job_valid` in S_COMPLETE and raises `job_cmp` the cycle after, so there is
  exactly one cycle in which the job is over as far as the shadow is concerned
  but the lock's committed job is still live. A write arriving there is still
  that job's own strobe, into its own destination, before the fill pointer
  moves, and the lock accepts it. **The real window is `[iss_commit, cmp_valid]`
  INCLUSIVE.** Only the instant-unit configurations can see this: with a long
  `JOB_LAT` the write burst is spent long before the completion, so the emitter
  never lands a strobe in that cycle. Which is the entire argument for sweeping
  the skew rather than tuning it.
- **Comparing the decode against the reference plan on a deliberately corrupted
  step.** Three fault injections rewrite a descriptor word in the URAM model;
  the reference plan is built from the CLEAN table, so the decode legitimately
  differs there. Comparing them reports the injection as a decode defect and
  would mask a real one. Those steps are excluded from the comparison by index.

## Measurement traps hit

- **`EXP_DECAY` must be 0, not "small".** The stub's `y_exp` is valid on the
  first cycle of `done` and garbage from the second. That is the only setting
  that separates capture-at-first-`done` from capture-at-`job_cmp`, which differ
  by one clocked state and by a wrong scale in one layer. O2 is killed by every
  configuration at `EXP_DECAY = 0`; at `EXP_DECAY = 3` (row D) O3 survives,
  which is the same lesson the predecessor recorded for `LATE_ERR` needing
  exactly one cycle.
- **The exponent readback needs `exp_rd_valid`, not just the value.** A capture
  that never happened reads as 0 from a register file cleared at reset, and 0 is
  a plausible exponent. O7 -- all three wqkv jobs sharing segment 0 -- is caught
  because segments 1 and 2 are never written and `exp_rd_valid` is low, not
  because the value is wrong.
- **A concurrent `assert` inside a `for ... generate` is the cheap way to bound
  a generic.** `OPC_CONS` entries are converted with `to_unsigned(x, NREG)`,
  which TRUNCATES silently. A mask that does not fit the region count would
  become a different, plausible mask.
- **Warnings do not fail a run.** Three of the mutations considered were
  detectable only through `STRICT` assertions, which are `severity warning` by
  design (the testbench drives violating sequences on purpose). Those were
  replaced with mutations that a checker catches. A mutation score that counts
  warnings is measuring the log, not the design.

## Resource counts -- COUNTS FROM THE RTL, NOT MEASURED UTILISATION

No synthesis was run.

| | `seq_opdec` |
|---|---|
| DSP48E2 | **0** |
| RAMB36 | **0** |
| FF, total | **~118** |
| of which | latched decode 76 (`prod` 1, `dst` 8, `seg` 2, `off` 16, `rows` 16, `cons` 14, `rel` 14, `op` 4, `pend` 1); exponent capture 22; sticky fault 17; token-start FSM 3 |

The 0-DSP claim is a construction argument and has one term worth naming: the
per-unit exponent slice `u_y_exp((x_unit+1)*EXP_W-1 downto x_unit*EXP_W)` has a
signal index, so it is a `NUNIT`-way mux of `EXP_W` bits in LUTs, not a
multiplier -- `EXP_W` is a generic and the product is a constant scale, which is
a shift at 16. Everything else is compares and ORs.

Running total for D-ctrl as built: `seq_desc_fetch` ~1,222 FF + `seq_region_lock`
~1,036 FF + `seq_opdec` ~118 FF = **~2,376 FF, 0 DSP, 0 RAMB36**, against D
section 12's ~15-25K FF estimate which also covers D-vec's datapath pipelining.

## Interface changes PROPOSED, not made

Both are one-line additions to `rtl/seq_desc_fetch.vhd`, which this pass was
told not to edit. Neither is required for correctness today; each moves a check
earlier or removes a generic.

1. **Add `chk_src2 : out unsigned(7 downto 0)` to the candidate port group**,
   alongside `chk_src`. The `src2` consistency check -- a named second source
   must be a region the opcode is declared to consume -- then runs in S_CHECK
   with every other descriptor-class check, BEFORE the unit starts, instead of
   at commit with its abort one step late. Cost: one continuous assignment,
   `chk_src2 <= f_src2(pf_w)`.
2. **Add a 16-bit `cons_mask` and a 16-bit `rel_mask` field to the descriptor
   header** (word 7 is reserved and checked-zero, so there is room), expose them
   on both the `job_*` and `chk_*` groups. That would retire `OPC_CONS`,
   `MSEG_REG`/`MSEG_OFF1`/`MSEG_OFF2` and the `rel_mask` port in one move, and
   restore D section 4.4's "the schedule is data" across the packed region map
   as well as across `MODEL`. It changes the descriptor format, so it needs the
   host generator and `sim/seq_tbl_pkg.vhd` to move with it.

## Open, not yet answered

- **The three descriptor-format gaps above are decisions, not derivations**, and
  nothing has reviewed them. The consume-mask generic is the one with a stated
  cost; the segment inference is the same cost one field narrower; the release
  mask is the predecessor's open item 1 and is unchanged except that the
  contradiction it rests on is now measured.
- **Whether the in-place lock semantics are right** is still open, unchanged
  from the predecessor. `seq_opdec` detects in-place (`cons(dst)`) and enforces
  `off = 0`, which is the predecessor's chosen reading; it does not
  independently justify it.
- **`S_GRANT` does not exist**, so M7 and M8 in the predecessor document remain
  equivalent mutants and the argument for that is still structural. Building the
  grant mux should be paired with the `seq_desc_fetch` change that hosts
  `S_GRANT`, and the sticky capture must be re-mutated in the same pass.
- **The base array is still not fetched** and the codebook is still not loaded.
- **`seq_region_lock` still polices region banks that do not exist**, and their
  open question -- an unconditional 1-element write plus a 1-cycle 512-bit read
  through a three-way source mux, at the real clock -- is a SYNTHESIS question
  and is untouched here.
- **D-vec is untouched** and its numeric contract still does not exist.
- **No synthesis, so no Fmax.** The claim most worth testing is now larger than
  it was: `seq_desc_fetch`'s S_CHECK is one clocked state and it now contains
  this unit's parallel field compares AND the lock's combinational verdict in
  series, round trip. If that does not close, the verdict needs a pipeline stage
  and S_CHECK becomes two states.
- **One token, one table.** All three testbenches walk the 9B N=1 table. The
  `NCARDS > 1` arm of `seq_tbl_pkg` builds E_COLL steps and is still never
  simulated, because `MODEL`/`NCARDS` are compile-time constants.
