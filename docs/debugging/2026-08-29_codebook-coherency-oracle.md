# The IQ4_NL codebook's write contract, and the oracle lever C would need

Date: 2026-08-29
Track: CB-ORACLE
Design: `rtl/matvec_core.vhd` at HEAD (`0ff6828`), subsystem A datapath core
Tools: GHDL 1.0.0 mcode (Ubuntu 1.0.0+dfsg-6). No Vivado, no hardware.
New files: `sim/tb_matvec_cb_contract.vhd`, `sim/mutate_matvec_cb.sh`

---

## 1. The question

Verbatim from the dispatch:

> **Oren has pre-authorised "lever C" -- moving that codebook to LUTRAM -- as
> the fallback if the floorplan does not get the design routing.** [...] Its one
> risk, recorded when he approved it:
>
> > it multiplies a correctness-critical **write-coherency surface by 32x**, so
> > it needs its own oracle work.
>
> [...] **You are that oracle work, and you are doing it BEFORE the change.**
>
> - What happens to an in-flight read when a codebook write lands in the same
>   cycle?
> - Are all replicas coherent, or can lanes disagree during an update?
> - Is there a window where a job starts against a partially-written codebook?
> - What enforces "codebook writes only while idle", and is that enforced or
>   merely intended?
>
> **Read `rtl/matvec_core.vhd` and find the real questions rather than taking
> my list.**

---

## 2. The answer, up front

**Eight contract terms, K1..K8, are now written down and held by a bench.**
`sim/tb_matvec_cb_contract.vhd`, nine runs, added to the gate. It closes both
mutations `sim/mutate_matvec_core.sh` left open (`C2` writes outside idle, `C3`
the start interlock) and adds six terms nothing had stated at all.

**The four questions, answered from the RTL:**

| question | answer |
|---|---|
| in-flight read vs a same-cycle write | **Cannot happen.** A write is captured only in `S_IDLE` and `S_IDLE` implies `inflight = '0'`. `P_CB_CHK` asserts both, and both now have stimulus. |
| can replicas disagree during an update | **Not today.** They are peers written by one command on one edge. Transient divergence is caught ONLY by `P_CB_CHK`; the value oracle cannot see it (row `K3c`). |
| a job against a partially-written codebook | **YES, and nothing prevents it.** See section 6. Coherency is guaranteed across REPLICAS and not across the sixteen ENTRIES. Demonstrated, not fixed. |
| what enforces "writes only while idle" | The capture gate `cb_we and st = S_IDLE and rst = '0'`, plus the empty `elsif cb_we = '1' and st = S_IDLE` arm of the main process, which is the START interlock. **Both are now tested**; before today neither was. |

**Three results matter more than the kill ratio.**

**(a) `P_CB_CHK`'s idle invariant watches the wrong end of the write path, and
lever C is the change that exposes it.** The assertion tests `cbw_v(0)`, the
COMMAND register, not the write. Row `K2b` adds one broadcast stage BELOW that
register -- precisely the shape a 1,536-replica command path needs so that
`cb_data` does not become the 1,536-fanout net the whole change exists to
remove -- and it **SURVIVES all six columns**: both value benches, the absolute
oracle, with and without the assertion. Nothing in the tree notices. **Whoever
takes lever C must re-aim that invariant at the LAST stage of the command path.**
This is not a defect in today's RTL, which has no stage there. It is a guard
that is one refactor away from vacuous, and it is the refactor that has already
been approved.

**(b) The only witness to a transient replica divergence is `P_CB_CHK`.**
Row `K3c` (upper half of the bank writes one cycle late, which is what a
two-level enable tree produces) is KILLED in every column with the assertion
live and SURVIVES every column with it demoted. `docs/debugging/2026-08-27_
matvec-codebook-replication.md` argued this; it is now measured against a
mutation that models the actual lever-C structure.

**(c) The replica SELECT cannot be tested by any functional bench, ever.**
`K8a` (every row reads replica 0) and `K8b` (every row reads its neighbour's
copy) both survive all six columns. While the replicas are coherent, every
select is correct. Coherency is the only thing protecting the select, which
means the 32x surface is entirely a WRITE-path surface and not a read-path one.

**One contract hole found, reported in section 6:** an operation started after a
partial codebook load consumes a mixed table and reports success.

---

## 3. The contract, read out of the RTL

Symbols, not line numbers: the `cb_we`/`cb_addr`/`cb_data` ports; the `cb`,
`cbw_v`, `cbw_a`, `cbw_d` declarations; process `P_CB`; process `P_CB_CHK`; the
`elsif cb_we = '1' and st = S_IDLE` arm of the main clocked process; and the
`cb(rr / CB_ROWS_PER_COPY)(idx)` read in the s1 product stage.

| # | term | status before today |
|---|---|---|
| **K1** | A command is captured iff `cb_we = '1' and st = S_IDLE and rst = '0'` before the edge. | untested |
| **K2** | The write lands one edge after the capture: two edges after `cb_we` is seen. | tested only in the direction "not too late" |
| **K3** | Every replica writes off its OWN command register on the same edge. No cycle exists in which two replicas differ. | asserted by `P_CB_CHK`, killed by `C1` |
| **K4** | A captured command implies `st = S_IDLE` and implies `inflight = '0'`. | asserted, **no stimulus** (`C2` survived) |
| **K5** | A write offered outside idle, or under reset, is SILENTLY DROPPED. No `err`, no deferral. | **stated nowhere**, untested |
| **K6** | Reset kills an uncaptured command and deliberately does NOT clear `cb`. The table outlives a reset. | stated in a comment, untested |
| **K7** | `cb_we = '1'` in `S_IDLE` makes that edge not also a start edge. | the interlock exists; **no stimulus** (`C3` survived) |
| **K8** | `cb` initialises to all zeros, so an operation run before any write emits zero. | **stated nowhere**, untested |

K5 and K8 are the two that had no textual existence at all. K8 is the one that
matters most for lever C: it is the ONLY property in the tree that tests the
initialiser, and under distributed RAM the initialiser is the INIT string,
because distributed RAM has no reset.

**Two structural facts worth recording because they are not obvious from the
source.**

*The `rst = '0'` term in the capture gate is REDUNDANT.* Removing it (`K1b`)
survives everything, and that is correct rather than a coverage hole: the
trailing `if rst = '1' then cbw_v <= (others => '0'); end if;` in the same
process overrides the capture on the same edge. `K1d` removes BOTH and is
killed by the bench, which is how the redundancy was distinguished from a blind
spot. Do not "clean up" either one alone.

*`st` is `S_IDLE` during reset*, because the main process's `rst` arm sets it.
So "under reset" and "outside idle" are not disjoint cases, and the bench tests
them separately for that reason.

---

## 4. The procedure

1. Read `P_CB`, `P_CB_CHK`, the interlock arm and the s1 read. Classify every
   consumer and every producer of `cb`. There are exactly two of each.
2. Write the contract down as K1..K8 BEFORE writing any stimulus, so the bench
   is a statement about the design rather than about what was easy to drive.
3. Choose a bench shape whose OUTPUT can witness replica divergence, so the
   value oracle does not depend on `P_CB_CHK` surviving lever C. This is the
   design decision in the whole track; section 5 has the measurement that
   forced it.
4. Build the mutation harness with a CONTROL row and an ASSERT-NEUTERED column,
   because the question "does the value oracle stand alone?" is the question
   lever C turns on.
5. Add the ABSOLUTE oracle (`tb_matvec_core` against `ref/matvec_int4.c`) as a
   third bench column, because the two codebook benches are RELATIONAL -- they
   compare runs against each other and have no model of what a codebook should
   produce. `K7a` is the mutation that proves this is not a hypothetical.
6. Gate row, floor raise, full unfiltered run.

---

## 5. The bench shape, and the measurement that chose it

`tb_matvec_cb_contract` drives `BLK = 16`, `ROWS_IF = 4`, nibble `(rr,j) = j`,
one scale for every row, one activation word for every block. **Every row's
stimulus is identical**, so the `ROWS_IF` lanes of an emitted beat must be
bit-identical, and row `rr` decodes through replica `rr / CB_ROWS_PER_COPY`.
**Lane inequality IS replica divergence, observed at the output.** A separate
concurrent process checks it on every emitted beat of every run, including the
power-up run and the partial-load run.

The first version of the bench used per-row-distinct nibbles, the obvious
choice. MEASURED: with that shape, `K3b` (replicas 1..3 never written) changes
every run identically and NO comparison between runs can see it. Only
`P_CB_CHK` can. With identical rows, `K3b` is killed by the value oracle alone
(`NC:KILL(v)`).

**That is what makes the oracle lever-C ready, and it is DEMONSTRATED rather
than argued.** Row `K9a` corrupts the codebook value seen by exactly one lane,
`(rr=1, j=0)` -- which is what a single stale per-lane replica looks like at the
read, and a thing the current one-replica-per-row structure cannot express.
MEASURED: `AC:KILL(v)` and `NC:KILL(v)`, so the lane-equality oracle catches it
**with and without `P_CB_CHK`**, and its message names the offending lane:

```
tb_matvec_cb_contract: FAIL -- emitted lane 1 differs from lane 0 on a beat
whose rows carry IDENTICAL weights, scale and activations.
```

What it still cannot see is a divergence that is transient across a load; that
is `K3c`, and it stays `P_CB_CHK`'s job.

MEASURED, the bench passes at every granularity offered:

```
-gCB_ROWS_PER_COPY=1                       PASS
-gCB_ROWS_PER_COPY=2                       PASS
-gCB_ROWS_PER_COPY=4                       PASS      (= ROWS_IF, the single-copy control)
-gROWS_IF=8                                PASS
-gROWS_IF=8 -gCB_ROWS_PER_COPY=8           PASS
```

---

## 6. THE HOLE: a job CAN start against a partially-written codebook

**Reported prominently because it answers one of the four questions with "yes,
and nothing prevents it".**

Coherency is guaranteed across REPLICAS. It is guaranteed nowhere across the
sixteen ENTRIES. Nothing in `matvec_core` marks the codebook complete, so:

* a host that writes eight of sixteen entries and then starts gets a MIXED
  table, a plausible-looking answer, and `err = '0'`;
* a reset asserted mid-load leaves the entries written so far in place (K6:
  `cb` survives reset) and the rest at their previous values, with the same
  result;
* the AXI wrapper offers no "codebook valid" bit for a driver to gate on.

MEASURED, run 8 of `tb_matvec_cb_contract`: with `CB1` loaded and then the first
eight entries of `CB2` written over it, the operation completes, `err = '0'`,
and the result matches NEITHER whole table.

```
sim/tb_matvec_cb_contract.vhd:588:5:@8205ns:(report note): tb_matvec_cb_contract:
NOTE -- an operation started after a PARTIAL codebook load consumed a mixed
table and reported success.  Nothing in matvec_core marks the codebook
complete.  This is a demonstrated hazard, not a failure of the RTL against its
stated contract.
```

**Deliberately NOT fixed.** A completeness guard is a design change with a
register-map consequence (a "codebook loaded" bit, or a written-entry mask that
`S_IDLE` checks alongside its other spec 7.6 checks), and the descriptor plane
is not this track's. It is the same family as OI-1's "a well-formed base
pointing at the WRONG sub-region is undetectable": the design validates the
SHAPE of what it is given and never its CONTENT. Run 8 will start failing if a
guard is ever added, and that failure is the correct signal.

This hazard is unchanged by lever C. It is neither made worse nor better by 32x
more replicas.

---

## 7. The evidence

### 7.1 The bench on honest RTL

```
sim/tb_matvec_cb_contract.vhd:612:5:@8875ns:(report note): tb_matvec_cb_contract:
PASS -- 9 runs, 0 failures.  Codebook writes outside idle and under reset are
dropped; the table survives reset; the cb_we/start interlock holds from both
sides; an un-loaded codebook decodes to zero; a partial load is consumed
silently (documented, run 8).  CB_ROWS_PER_COPY=1 NB=24
```

Gate discovery, MEASURED:

```
$ REGRESS_SCRATCH=... bash sim/regress.sh --only matvec_cb
 OVERALL     PASS 2   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

### 7.2 `sim/mutate_matvec_cb.sh`, 20 rows plus a control, 6 columns each

Columns are `<mode><bench>`. Mode `A` = `P_CB_CHK` live, `N` = its three
assertions demoted to `severity note`. Bench `C` = `tb_matvec_cb_contract`,
`L` = `tb_matvec_cb_lockstep`, `M` = `tb_matvec_core` on the committed
`sim/tr.txt` against `ref/matvec_int4.c`. `KILL(v)` = a bench's value oracle,
`KILL(a)` = `matvec_core`'s own assertion.

```
CTRL   SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv     -- the UNMUTATED design through this same path

K1a    KILLED    AC:KILL(a) AL:surv    AM:surv    NC:KILL(v) NL:surv    NM:surv     -- the idle gate is dropped, so writes are accepted while an operation runs
K1b    SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv     -- the reset gate is dropped, so writes are accepted while rst is asserted
K1c    KILLED    AC:KILL(a) AL:surv    AM:surv    NC:KILL(v) NL:surv    NM:surv     -- both gates dropped: cb_we alone is enough to capture a command
K1d    KILLED    AC:KILL(v) AL:surv    AM:surv    NC:KILL(v) NL:surv    NM:surv     -- the reset gate AND the trailing rst clear of cbw_v are both dropped

K2a    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(v) NC:surv    NL:surv    NM:KILL(v)  -- the command capture is one cycle late
K2b    SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv     -- a broadcast stage is added BELOW the command register
K2c    SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv     -- the command registers are bypassed; cb written straight from cb_addr/cb_data

K3a    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(v) NL:surv    NM:KILL(v)  -- replica 1 skips a write whenever replica 0 takes one
K3b    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(v) NL:surv    NM:KILL(v)  -- only replica 0 is ever written
K3c    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:surv    NL:surv    NM:surv     -- the upper half of the bank writes one cycle late (a two-level tree)
K3d    SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv     -- every replica writes off replica 0's command registers (master/follower)

K4a    KILLED    AC:KILL(a) AL:surv    AM:surv    NC:KILL(v) NL:surv    NM:surv     -- the empty cb_we arm is deleted, so start can be honoured on a write edge

K5a    KILLED    AC:KILL(v) AL:surv    AM:surv    NC:KILL(v) NL:surv    NM:surv     -- cb loses its initialiser
K5b    KILLED    AC:KILL(v) AL:surv    AM:surv    NC:KILL(v) NL:surv    NM:surv     -- cb initialises to all ones

K6a    KILLED    AC:KILL(v) AL:surv    AM:surv    NC:KILL(v) NL:surv    NM:surv     -- rst clears the codebook

K7a    KILLED    AC:surv    AL:surv    AM:KILL(v) NC:surv    NL:surv    NM:KILL(v)  -- the write address is taken LIVE from cb_addr
K7b    KILLED    AC:surv    AL:surv    AM:KILL(v) NC:surv    NL:surv    NM:KILL(v)  -- the write data is taken LIVE from cb_data

K8a    SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv     -- every row reads replica 0
K8b    SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv     -- the replica select is rotated by one

K9a    KILLED    AC:KILL(v) AL:surv    AM:KILL(v) NC:KILL(v) NL:surv    NM:KILL(v)  -- lane (1,0) decodes one entry one step off (a single stale PER-LANE replica)

kill ratio: 14 KILLED + 0 ABORTED = 14 of 20;  6 SURVIVED
survivors (nothing in the closure watches these): K1b K2b K2c K3d K8a K8b
killed ONLY with P_CB_CHK live (the assertion is the sole witness): K3c
```

Sample kill lines, quoted from the logs rather than paraphrased:

```
AC (K1a):  matvec_core: a codebook write landed after the operation had already left idle.
AC (K3c):  matvec_core: codebook replica 2 diverged from replica 0.
NC (K3b):  tb_matvec_cb_contract: FAIL -- emitted lane 1 differs from lane 0 ...
AC (K5a):  tb_matvec_cb_contract: FAIL -- an operation run before any codebook write did not emit zero
AC (K6a):  tb_matvec_cb_contract: FAIL -- a codebook write offered while rst was asserted took effect
AM (K7a):  STAGE MISMATCH PARTIAL r=0 b=0 got -4805852 want -5989552
AM (K7b):  STAGE MISMATCH PARTIAL r=0 b=0 got -5984756 want -5989552
NC (K9a):  tb_matvec_cb_contract: FAIL -- emitted lane 1 differs from lane 0 ...
```

### 7.3 What each column is FOR, DERIVED from the table

* Column `C` alone kills 12 of 20; `L` alone kills 4; `M` alone kills 7.
  (Counted from the `A` columns of the table above.)
* `M` is the ONLY column that kills `K7a` and `K7b`. Both corrupt every load in
  the same way, so a relational bench sees a self-consistent world. **The two
  codebook benches must never be read as sufficient on their own.**
* `L` kills nothing that `C` does not, and it kills only the divergence rows. It
  earns its place as the LOAD-SCHEDULE bench, which is the one thing `C` does
  not drive; it is not a coherency instrument.
* Demoting `P_CB_CHK` loses `K3c` ENTIRELY -- no column kills it -- and loses
  `K2a` on both codebook benches, leaving only the absolute oracle to catch it.
  Five further rows (`K1a`, `K1c`, `K3a`, `K3b`, `K4a`) convert from `KILL(a)`
  to `KILL(v)`, which is the good case: the value oracle stands where the
  assertion previously spoke first.

### 7.4 The 32x, DERIVED

FK33 geometry is `ROWS_IF = 48`, `BLK = 32`. One replica per row is 48. One
replica per lane is `48 * 32 = 1,536`. `1536 / 48 = 32`. That is the coherency
surface multiplier Oren attached to the approval; it is not the area win, which
CONGEST measured separately at roughly 7.1x on 86,992 primitives.

`P_CB_CHK`'s divergence loop is `O(CB_COPIES)` full-table compares per cycle.
DERIVED at the FK33 shape: `1535 * 16 * 8 = 196,480` bit compares per cycle. No
behavioural bench runs at that geometry, and at the bench shape
(`ROWS_IF = 4, BLK = 16`) per-lane granularity gives 64 copies and
`63 * 16 * 8 = 8,064`, which is not a problem. Recorded so that nobody weakens
the loop for a cost that has not been measured.

---

## 8. Measured and REJECTED -- do not retry

* **Per-row-distinct weight nibbles in the codebook bench.** The obvious shape,
  and it makes the value oracle blind to a permanently-stale replica set:
  `K3b` changes every run identically, so no run-to-run comparison can see it.
  MEASURED on the first version of `tb_matvec_cb_contract`. Identical rows plus
  a lane-equality check is what recovers it.
* **Treating `tb_matvec_cb_contract` and `tb_matvec_cb_lockstep` as sufficient.**
  Both are RELATIONAL. `K7a` and `K7b` corrupt the table identically on every
  load and survive both, in both assert modes, and are killed instantly by
  `tb_matvec_core` against `ref/matvec_int4.c`. Any future codebook work must
  keep the absolute oracle in the loop.
* **Deleting the `rst = '0'` term from the capture gate as redundant.** It IS
  redundant (`K1b` survives) but only because the trailing `if rst = '1'` clear
  of `cbw_v` covers it. Remove both (`K1d`) and the bench fires. Neither is
  safe to remove alone, and the redundancy is not the defect it looks like.
* **Expecting `P_CB_CHK`'s `st` invariant to cover a late WRITE.** It covers a
  late CAPTURE (`K2a`, killed) and not a late write (`K2b`, survives). The
  distinction is which side of `cbw_v` the delay is on, and it is exactly the
  distinction lever C changes.
* **Testing the replica SELECT functionally.** `K8a` and `K8b` both survive all
  six columns and always will while the replicas are coherent. Do not spend a
  slot writing a bench for it; spend it on the write path.

---

## 9. Measurement traps hit, including my own

* **A registered `done` is seen one edge AFTER the edge that set it, and `st`
  returned to `S_IDLE` on that earlier edge.** The first version of run 7 held
  `start` high until its poll noticed `done`, which launched a SECOND unwanted
  operation on the `S_IDLE` edge in between. Every later run then loaded its
  codebook into a busy core, had it dropped by the very interlock under test,
  and failed. MEASURED: runs 8 and 9 failed on honest RTL. The comment at that
  site in the bench names it. **Anything that polls a one-cycle pulse and holds
  a request across the poll has this bug.**
* **A survivor is not automatically a coverage hole.** `K1b` looked like one for
  as long as it took to write `K1d`. The general move: when a mutation survives,
  construct the STRICTLY STRONGER mutation that removes whatever might be
  masking it, and see whether that one is killed. If it is, the survivor is
  redundancy; if it is not, it is a hole.
* **The kill ratio is the least useful number in the table.** 13 of 19 says
  nothing. The two lists under it -- the survivors and the assertion-only row --
  are the entire result, and the `N` column exists only to produce the second.
* **`sim/regress.sh` auto-discovers `sim/tb_*.vhd`**, so the new bench became a
  gate row on creation, before its floor was raised. Nothing broke because it
  passed, but a bench that failed would have turned the shared gate red for six
  other live tracks. Write the bench, run it standalone, THEN let a gate run see
  it.
* **`BASELINE_PASS` had moved from the 91 in my brief to 93 by the time I read
  it.** Re-read it immediately before editing; do not trust a number quoted in
  a dispatch written minutes earlier.

---

## 10. NOT verified

* **Any hardware behaviour.** No hardware was touched, per the standing
  boundary. No Vivado either: TRACK PBLOCK owns place-and-route on this machine
  and a synth run would have contended with it.
* **Everything in the L-list of `sim/mutate_matvec_cb.sh`**, restated here:
  distributed RAM `WRITE_MODE` at a colliding address (needs post-synthesis
  simulation against UNISIM; a behavioural array model cannot represent it);
  whether Vivado emits the RAM `INIT` strings (needs an OOC netlist read);
  whether the tool actually builds `CB_COPIES` replicas rather than one table
  with many read ports (needs `report_utilization` RAMD/RAMS counts against the
  DERIVED expectation); and the balance of the write-enable tree at 1,536
  replicas (needs STA).
* **Whether lever C should be taken at all.** That is TRACK PBLOCK's result to
  produce, not this track's.
* **`CB_ROWS_PER_COPY > 1` against the C reference.** The granularity sweep in
  section 5 is `tb_matvec_cb_contract` only. `tb_matvec_core` runs at the
  default of 1, so bit-exactness at 2 and 4 rests on the 2026-08-27 sweep, not
  on anything measured here.
* **The AXI wrapper's codebook path.** `rtl/matvec_int4_axi.vhd` is what a
  driver actually writes through; this track tested `matvec_core`'s port. The
  wrapper's own idle-gating, if any, is unexamined.
* **Whether a completeness guard is wanted** (section 6). Demonstrated, costed
  as a design change, left for Oren.
* **`inflight` as an independent invariant.** `P_CB_CHK`'s second assertion
  (`cbw_v(0) = '1' and inflight = '1'`) is SUBSUMED by its first while
  `S_DRAIN` waits for `inflight = '0'` before `S_IDLE` can be reached again. No
  mutation in this set kills the second without also killing the first, so its
  independent value is unmeasured.

---

## 11. Corrections

None yet. Append here rather than editing above.
