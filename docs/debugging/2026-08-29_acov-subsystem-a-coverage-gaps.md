# Subsystem A's three named coverage gaps, closed and measured

**Date:** 2026-08-29
**Track:** ACOV, row N8 of `docs/WORKLOG.md`
**Baseline:** `a269ed4` (TRACK ERRINFO's release of the descriptor-side files)
**Commits:** `b39c389`, `337b5fd`, `578c546`, `164024e`
**Tools:** GHDL mcode (`ghdl --version` backend), `sim/regress.sh`, `cc` for the
reference and vector generators. No hardware, no Vivado, nothing under
`hw/fk33/`.

---

## 1. The question, verbatim

> **THE TASK -- ROW N8, THREE GAPS, ALL NAMED BY TRACK DESC-MUT AND ALL STILL OPEN**
>
> 1. **`rtl/matvec_int4.vhd` and `rtl/axi_rd_port.vhd` have NO mutation script at all.**
> 2. **`USE_XEXP_PORT=true` appears in NO bench** anywhere in the tree.
> 3. **`DUAL_CLK=true` is a manual run**, so the descriptor-path CDC has no automatic
>    coverage -- and that CDC's absence once broke **17 of 22 cases** when TRACK A-CTRL
>    first built it. A defect class that has already bitten once, with no gate.
>
> **Verify all three still hold at HEAD before building anything.**

---

## 2. The answer, up front

**All three were still open at `a269ed4`, with one correction to gap 1, and all
three are now closed.**

| gap | state at `a269ed4` | now |
|---|---|---|
| 1a `rtl/matvec_int4.vhd` | no mutation script -- **confirmed** | `sim/mutate_matvec_int4.sh`, 26 mutations, **14 caught**, 12 survived, 0 VOID |
| 1b `rtl/axi_rd_port.vhd` | **the brief is wrong**: `sim/mutate_axi_rd_port_dual.sh` already mutates this file, but ONLY inside the `g_dc` generate. The `g_sc` branch and the shared body -- what every gate row and every AXU3EG build actually takes -- had none. | `sim/mutate_axi_rd_port.sh`, 22 mutations, **11 caught**, 11 survived, 0 VOID |
| 2 `USE_XEXP_PORT=true` | in no bench, no `.tcl`, no shell -- **confirmed**, the only occurrences are `false` in `hw/fk33/**` and a "not elaborated" survivor note in `sim/mv4i_desc_mutations.py` | gate row `sim:tb_matvec_fk33_desc_xexp`, with the descriptor's own x_exp word **deliberately sabotaged** so the row fails if the port is ignored |
| 3 `DUAL_CLK=true` on the descriptor path | a manual `-gDUAL=true`, and `sim/regress.sh` says why in as many words ("regress keys a test by name and cannot run one testbench twice") -- **confirmed** | gate row `sim:tb_matvec_fk33_desc_dual` |

Two things found along the way that were not in the brief:

* **`sim/tb_axi_rd_port.vhd` accepted an ARLEN of 255 and reported 0 bad beats.**
  The FK33's HBM slave is AXI3, where ARLEN is four bits, so a burst over 16
  beats is not slow -- it is unanswerable. The bench now asserts it, and two
  mutations that were silent now die, the second at *exactly one beat* over the
  cap.
* **`frst <= rst;` in `rtl/axi_rd_port.vhd`'s `g_sc` generate is dead.** Nothing
  in the single-clock branch reads `frst`; the FSM and the FIFO are both given
  `rst` directly. Tying it low is invisible (row B1). Reported, **not fixed** --
  this is a test-coverage track.

**BASELINE_PASS is unchanged at 93**, by construction and not by omission: both
new rows need the `.mv4i` model set, which is not in git, so `tb_prereq` marks
them OPTIONAL and the floor is a clean-checkout number that never included them.

---

## 3. The procedure, in the order it was run

Each step is stated with what it controls for.

1. **Verify the three gaps at HEAD before building anything.** `grep -rn
   USE_XEXP_PORT` and `grep -rn DUAL_CLK` over the whole tree; then, for every
   `sim/mutate_*.sh`, count references to each target RTL file and read them to
   separate "mutates it" from "compiles it as a dependency". *Controls for the
   failure this project hit three times tonight -- dispatching a track onto
   already-finished work.* It is what caught the correction to gap 1b.
2. **Time a clean run of every candidate judge before writing any mutation
   script.** A judge at 10 s is affordable at 26 mutations; one at 50 s is not.
   *Controls for discovering the cost after the script exists.*
3. **Build each mutation script around a control run first.** The control is run
   in *every* configuration, and the script exits 2 if any of them is not a pass.
   *Controls for the case where a red table is a statement about the harness.*
4. **Score an analysis or elaboration failure as VOID, never as a kill.** Built
   in from the first line, not retrofitted. *Controls for the recorded case where
   a script scored seven of seven CAUGHT because ghdl could not open a file.*
5. **Teeth-check the tag uniqueness gate on every run.** The script re-runs its
   own gate against a copy of itself with one tag duplicated and refuses to
   proceed if the gate accepts it. *Controls for the `mv4i_desc_mutations.py
   --apply` trap: a duplicate row name silently tests one edit twice and another
   never, and the table looks full either way.*
6. **Read the survivors, form a hypothesis about WHY, and test the hypothesis.**
   This is where the two useful findings came from -- and where one hypothesis was
   measured and rejected (section 6).
7. **Teeth-check the new `USE_XEXP_PORT` row by mutating the mux in a SCRATCH
   copy of the RTL.** Nothing under `rtl/` was edited. *Controls for the
   "structure is not values" failure: a configuration that elaborates a generic
   and passes has not shown that the generic does anything.*
8. **Run the changed rows through `sim/regress.sh` itself, not just ghdl.** The
   vector machinery, the prereq gate and the pass marker are separate mechanisms
   from the simulation and each can fail on its own.

---

## 4. The evidence, as raw output

### 4.1 `sim/mutate_axi_rd_port.sh` -- 22 mutations, 11 caught

```
tag uniqueness gate: 22 tags, all distinct
tag uniqueness gate TEETH: a duplicated A5 is refused -- the gate bites

=== control: the UNMUTATED rtl/axi_rd_port.vhd, all five configurations ===
  gate   SURV|0 bad beats
  deep   SURV|0 bad beats
  tight  SURV|0 bad beats
  brim   SURV|0 bad beats
  brim2  SURV|0 bad beats

tag  class verdict  detail                                         caught-by
A1   AR    KILLED   arsize must match AXI_DW                       by[ gate deep tight brim brim2]
A2   AR    KILLED   burst type must be INCR                        by[ gate deep tight brim brim2]
A3   RUN   ABORT    hung: reached --stop-time with no verdict      by[ gate deep tight brim brim2]
A4   RUN   SURVIVED 0 bad beats                                    by[ none]
A5   RUN   SURVIVED 0 bad beats                                    by[ none]
A6   RUN   KILLED   job4 after abandon: beat 0 got 1300 want 2304  by[ gate deep tight brim brim2]
A7   RUN   SURVIVED 0 bad beats                                    by[ none]
A8   LVL   SURVIVED 0 bad beats                                    by[ none]
A9   LVL   SURVIVED 0 bad beats                                    by[ none]
B1   SC    SURVIVED 0 bad beats                                    by[ none]
B2   SC    ABORT    hung: reached --stop-time with no verdict      by[ gate deep tight brim brim2]
B3   SC    KILLED   job4 after abandon: beat 0 got 1300 want 2304  by[ gate deep tight brim brim2]
B4   SC    KILLED   job4 after abandon: beat 0 got 1300 want 2304  by[ gate deep tight brim brim2]
B5   SC    ABORT    hung: reached --stop-time with no verdict      by[ gate deep tight brim brim2]
B6   SC    ABORT    hung: reached --stop-time with no verdict      by[ gate deep tight brim brim2]
B7   SC    SURVIVED 0 bad beats                                    by[ none]
C1   GEN   SURVIVED 0 bad beats                                    by[ none]
C2   GEN   SURVIVED 0 bad beats                                    by[ none]
C3   GEN   SURVIVED 0 bad beats                                    by[ none]
C4   GEN   SURVIVED 0 bad beats                                    by[ none]
C5   GEN   KILLED   ARLEN 63 exceeds 15 -- the FK33's HBM slave is AXI3 and
C6   GEN   KILLED   ARLEN 16 exceeds 15 -- the FK33's HBM slave is AXI3 and

 22 mutations: 7 KILLED, 4 ABORT (11 caught), 11 SURVIVED, 0 VOID
 SURVIVORS (this bench's resolution floor, do not delete): A4 A5 A7 A8 A9 B1 B7 C1 C2 C3 C4
```

`C5` and `C6` are the rows the script was worth writing for. Both **survived**
before the ARLEN assert was added.

### 4.2 The FIFO occupancy witness

`sim/tb_axi_rd_port.vhd` now reports its own high-water mark, derived at the
boundary as (beats accepted on R) minus (beats popped on Q):

```
-gMAXOUT=2  -gDEPTH=64  -gSTALL=3 -gQSTALL=0 -gSEED=1   0 bad beats (QSTALL=0, FIFO high-water 26 of DEPTH 64)
-gMAXOUT=16 -gDEPTH=512 -gSTALL=0 -gQSTALL=0 -gSEED=7   0 bad beats (QSTALL=0, FIFO high-water 43 of DEPTH 512)
-gMAXOUT=1  -gDEPTH=32  -gSTALL=5 -gQSTALL=0 -gSEED=3   0 bad beats (QSTALL=0, FIFO high-water 11 of DEPTH 32)
-gMAXOUT=4  -gDEPTH=32  -gSTALL=0 -gQSTALL=3 -gSEED=5   0 bad beats (QSTALL=3, FIFO high-water 25 of DEPTH 32)
-gMAXOUT=2  -gDEPTH=32  -gSTALL=2 -gQSTALL=2 -gSEED=8   0 bad beats (QSTALL=2, FIFO high-water 30 of DEPTH 32)
```

### 4.3 `sim/mutate_matvec_int4.sh` -- 26 mutations, 14 caught

```
=== control: the UNMUTATED rtl/matvec_int4.vhd ===
  small  SURV|ok
  fk33   SURV|ok

tag  class verdict  detail                                   caught-by
T1   TAP   SURVIVED ok                                       by[ none]
T2   TAP   SURVIVED ok                                       by[ none]
C1   CONV  SURVIVED ok                                       by[ none]
C2   CONV  SURVIVED ok                                       by[ none]
C3   CONV  SURVIVED ok                                       by[ none]
C4   CONV  SURVIVED ok                                       by[ none]
C5   CONV  KILLED   SUBSYSTEM A DIVERGES FROM THE C REFERENCE END TO END by[ small fk33]
C6   CONV  KILLED   descriptor rejected                      by[ small fk33]
C7   CONV  ABORT    hung: reached --stop-time with no verdict by[ small]
C8   CONV  ABORT    overflow detected                        by[ small fk33]
W1   WIRE  SURVIVED ok                                       by[ none]
W2   WIRE  SURVIVED ok                                       by[ none]
W3   WIRE  KILLED   END-TO-END MISMATCH r=0 got 2472 want -13581 by[ small fk33]
W4   WIRE  KILLED   END-TO-END MISMATCH r=0 got -26311 want -13581 by[ small fk33]
W5   WIRE  KILLED   END-TO-END MISMATCH r=0 got -13174 want -13581 by[ small fk33]
W6   WIRE  KILLED   END-TO-END MISMATCH r=0 got -869212 want -13581 by[ small fk33]
S1   SIZE  SURVIVED ok                                       by[ none]
S2   SIZE  ABORT    bound check failure                      by[ small fk33]
G1   GEN   KILLED   descriptor rejected: err IS SET          by[ fk33]
G2   GEN   KILLED   descriptor rejected: err IS SET          by[ fk33]
G3   GEN   ABORT    bound check failure                      by[ small fk33]
G4   GEN   SURVIVED ok                                       by[ none]
G5   GEN   ABORT    bound check failure                      by[ fk33]
G6   GEN   SURVIVED ok                                       by[ none]
G7   GEN   SURVIVED ok                                       by[ none]
G8   GEN   ABORT    hung: reached --stop-time with no verdict by[ small fk33]

 26 mutations: 8 KILLED, 6 ABORT (14 caught), 12 SURVIVED, 0 VOID
 SURVIVORS (the resolution floor of these benches, do not delete): T1 T2 C1 C2 C3 C4 W1 W2 S1 G4 G6 G7
```

**The caught-by column is the reason two judges exist.** `C7` (`w_beats` and
`s_beats` swapped) is caught **only** by `small`, where
`GRP = NPORTS_S*AXI_DW/(ROWS_IF*16) = 2` makes the two numbers different, and
survives at the FK33 shape where `GRP = 1` makes them equal. `G1`, `G2` and `G5`
are caught **only** by `fk33`, the only bench in the tree with `NPORTS_S > 1`.

### 4.4 The `USE_XEXP_PORT` teeth check

The new row passes:

```
tb_matvec_fk33_desc: 22 cases run, 0 failures [DUAL=false XEXP_PORT=true]
subsystem A is bit-exact with ref/matvec_int4.c through the descriptor control
plane, and every checked mutation is refused
```

With `rtl/matvec_int4_desc_axi.vhd:547` rewritten **in a scratch copy** from

```vhdl
v_xexp <= x_exp_in when USE_XEXP_PORT else lo32(dw(EXT0 + 2));
```

to `v_xexp <= lo32(dw(EXT0 + 2));` -- the mux forced to the descriptor side --
the same row reports:

```
sim/tb_matvec_fk33_desc.vhd:1505:11:@478065ns:(report error): CASE 0: Y_EXP MISMATCH got 13 want 6
sim/tb_matvec_fk33_desc.vhd:1646:5:@541485ns:(report note): tb_matvec_fk33_desc: 22 cases run, 1 failures [DUAL=false XEXP_PORT=true]
sim/tb_matvec_fk33_desc.vhd:1650:5:@541485ns:(assertion failure): SUBSYSTEM A'S DESCRIPTOR CONTROL PLANE FAILED 1 CASES
/usr/bin/ghdl-mcode:error: simulation failed
```

`13 = 6 + 7`, which is the deliberate sabotage of the descriptor's own x_exp
word landing in `y_exp`. Nothing under `rtl/` was edited.

### 4.5 The new rows through `sim/regress.sh`

```
 suite sim   PASS 2   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 2   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```
(`--only tb_matvec_fk33_desc_`, which matches exactly the two new rows.)

The unchanged gate row, after the `tb_axi_rd_port.vhd` edit:

```
PASS       sim:tb_axi_rd_port       0s  ...:@3395ns:(report note): axi_rd_port: 0 bad beats (QSTALL=0, FIFO high-water 26 ...
PASS       sim:tb_axi_rd_port_dual  0s  ...:@9947ns:(report note): PASS: tb_axi_rd_port_dual
 OVERALL     PASS 2   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
```

`@3395ns` is the same end time the row had before the edit, so `QSTALL = 0` and
`ARLEN_MAX = 15` really are the historical behaviour.

Every `matvec` row in both suites, after all four commits (`--only tb_matvec`):

```
PASS       sim:tb_matvec_axi                      2s
PASS       sim:tb_matvec_cb_contract              1s
PASS       sim:tb_matvec_cb_lockstep              0s
PASS       sim:tb_matvec_core                     2s
PASS       sim:tb_matvec_core_ragsat              3s
PASS       sim:tb_matvec_fk33                    11s
PASS       sim:tb_matvec_fk33_desc               47s
PASS       sim:tb_matvec_fk33_desc_dual          52s
PASS       sim:tb_matvec_fk33_desc_xexp          47s
PASS       sim:tb_matvec_int4                     2s
PASS       sim:tb_matvec_int4_ip                  0s
PASS       tb:tb_matvec_engine                    0s
 suite sim   PASS 11   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 12   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

Note the third field is elapsed **seconds**, not a check count.

### 4.6 Measured wall clock, one core, load average 5-8

| run | seconds |
|---|---|
| `tb_axi_rd_port`, any configuration | 0.07 - 0.09 |
| `tb_matvec_int4` (`small`) | 0.75 |
| `tb_matvec_fk33` (`fk33`) | 10.4 |
| `tb_matvec_fk33_desc` default | 48.9 |
| `tb_matvec_fk33_desc` at `-gDUAL=true` | 50.9 |
| `tb_matvec_fk33_desc` at `-gXEXP_PORT=true` | 49.1 |

The gate grows by about 100 s, on optional rows only.

---

## 5. Machine, as measured at the start

```
/dev/nvme1n1p6  1.3T  1.2T  120G  91% /
/dev/nvme0n1p1  916G  482G  388G  56% /mnt/storage
Mem: total 31  used 5  free 6  buff/cache 19  available 25
load average: 4.94, 13.45, 14.00   (rose to 8.2 mid-session, two other tracks)
```

No full gate was run concurrently with another track's.

---

## 6. Measured and REJECTED -- do not retry

### 6.1 Consumer backpressure does NOT kill the `axi_rd_port` FIFO survivors

**The hypothesis.** Eleven of twenty rows survived, and five of them (`A5`, `A8`,
`A9`, `C1`, `C2`) all look like ways to overrun the FIFO. The bench held
`q_ready` high for the whole of every job, so the FIFO drained as fast as the
slave filled it and its level never rose. Adding consumer stalls should make the
FSM's AR throttle bind and those five should die.

**What was built.** A `QSTALL` generic on `sim/tb_axi_rd_port.vhd` (default 0 =
historical behaviour), two configurations using it, and an occupancy witness.

**The measurement.** The witness confirms the stimulus worked -- the FIFO high-water
mark went from 26 of DEPTH 64 to **30 of DEPTH 32**. The mutation table did not
move by a single row: **the same eleven mutations survive with five
configurations as with three.**

**Why, and why no stimulus will fix it.** The R channel is backpressured.
`rready_i <= f_ir when run_f = '1' else '1'`, and the FSM's throttle
(`f_level + pr + want <= DEPTH`, `rtl/axi_rd_fsm.vhd:223`) is precisely the
guarantee that queued-plus-outstanding beats never exceed `DEPTH`. If the FSM
over-issues, the FIFO stops accepting, the slave waits, and the job finishes
correctly -- just later. `DEPTH`, `MAXOUT` and `LVL_MARGIN` **as the FSM is told
them** are throughput parameters of this unit, not correctness ones.

**A stronger form of the same result:** `A5` (`beat_f <= rvalid` instead of
`rvalid and rready_i`) is a **provably equivalent mutant**. Since the throttle
guarantees the FIFO is never full, `f_ir` is never low, so `rready` is high on
every legal trace and the two expressions are the same function. No consumer
stall rate can make it bite. **Do not "fix" the bench for it.**

`QSTALL` and the two configurations were kept -- they take the throttle's false
branch and the witness is worth reading -- but they are **not** presented as a
coverage win, and the script header says so.

**A witness built on `rvalid and not rready` was also tried and is wrong.** It
reads 0 at every `QSTALL`, because it measures something this design makes
impossible. That cost one iteration and is why the shipped witness is built from
the boundary counts instead.

### 6.2 Do not use `SEED > 8` on `sim/tb_axi_rd_port.vhd`

The slave's LFSR seeds itself with `SEED*7919 + 1` through a 16-bit
`to_unsigned`, which truncates above 8 and prints a `numeric_std` warning at time
0. Harmless -- it only picks a different LFSR start -- but it is noise in a
mutation log. The configurations were moved from `SEED=11,17` to `SEED=5,8`.
This is pre-existing and was not introduced here.

---

## 7. Measurement traps hit, including my own

1. **My own: I wrote a claim into a shipped file before measuring it.** The first
   version of the `QSTALL` header said the five survivors were "four independent
   ways to overrun the FIFO, none of them visible". They are not -- they are not
   overruns at all. Caught before commit only because I re-derived the throttle
   from `rtl/axi_rd_fsm.vhd` rather than from the mutation names. **A plausible
   explanation for a survivor is not a measurement of why it survived.**
2. **A witness that reads 0 can be measuring an impossibility rather than a
   gap.** See 6.1.
3. **`git commit -m msg -- <path>` fails outright on an untracked file** with
   `pathspec ... did not match any file(s) known to git`. The safer pathspec form
   needs a `git add` of that one file first; the add is the risky moment, so it
   is done immediately before the commit and nothing else is staged.
4. **A pass marker that is a substring of a failure message.**
   `tb_pass_marker` for `sim:tb_axi_rd_port` is `'0 bad beats'`, and the bench
   prints `<n> bad beats` -- so `10`, `20`, `30`... bad beats all CONTAIN the pass
   marker. This is **pre-existing and was not introduced here**; it is survivable
   only because the bench also asserts `nbad = 0` at `severity failure`, so the
   run exits non-zero. It is left alone because changing the phrase is an edit to
   the shared `sim/regress.sh`, but it is a real trap for the next person.
5. **`sim/regress.sh` discovers a test's data files from string literals in the
   TESTBENCH FILE ITSELF** (`files[tb][3]`), not from its dependency closure. A
   wrapper entity that inherited the inner bench's `TRACE` default would be run
   with no vector generated and would fail on "cannot open mv_fk33_tr.txt". Both
   wrappers therefore pass `TRACE => "mv_fk33_tr.txt"` explicitly.
6. **`regress.sh --only` takes a SUBSTRING.** `--only tb_matvec_fk33_desc_`
   (trailing underscore) selects exactly the two new rows and not the original;
   `--only tb_matvec_fk33_desc` would have selected three and the count would
   have looked wrong for the wrong reason.
7. **A new gate row does not always move `BASELINE_PASS`.** Both new rows depend
   on the `.mv4i` model set, which is not in git, so `tb_prereq` classes them as
   OPTIONAL and `regress.sh` explicitly refuses to let such rows raise the floor.
   The floor is a clean-checkout number; these rows are not in it. Checking this
   before editing saved a shared-file change that would have been wrong.

---

## 8. Open, NOT determined here

* **No bench drives a negative `w_exp` or `x_exp` into subsystem A.** MEASURED
  from the DIMS line of both traces: `w_exp = 2, x_exp = 5` (small) and
  `w_exp = 8, x_exp = 5` (fk33). Rows `C3`/`C4` therefore survive, because for a
  never-negative value `signed` and `unsigned` are the same function. The same
  runs emit `y_exp = -2`, so the *output* side of this arithmetic is routinely
  negative. Whether `ref/matvec_int4.c` can produce a negative block exponent at
  all, and what the RTL does if it does, is **not answered here**.
* **`XB`'s ceiling divide in `rtl/matvec_int4.vhd` is untested** (row `S1`): no
  bench picks a `MAXCOLS` that is not a multiple of `BLK`.
* **`dbg_wbeat` and `dbg_wstarve` are observed by nothing** (rows `T1`/`T2`).
  Spec 11 asks for sustained bandwidth as a percentage of DDR peak and these two
  signals are the only measurement it could come from. Every bench leaves them
  `open`.
* **`frst <= rst;` in `axi_rd_port`'s `g_sc` generate is dead code** (row `B1`).
  Reported, not fixed -- this track does not edit `rtl/`.
* **`MAXOUT` is not observable in `sim/tb_axi_rd_port.vhd` at all** (row `C3`,
  `MAXOUT => 64`). Its behavioural slave accepts one AR, returns all of its
  beats, and only then accepts the next, so no configuration of this bench ever
  has two bursts in flight. Consumer backpressure does **not** fix this; a
  reordering slave would be needed.
* **The dual-clock row runs one clock ratio (1.67x) and no sweep.** An RTL
  simulator samples atomically, so a synchroniser cut to one flop or to none
  still crosses cleanly -- five of twenty rows in
  `sim/mutate_axi_rd_port_dual.sh` survive for that reason. `sim/cdc_teeth.sh`
  (`report_cdc`) is the flow that reaches them. Read the three together.
* **`USE_XEXP_PORT = true` is elaborated at `DUAL_CLK = false` only.** The cross
  product is not covered, and this track takes no position on which source the
  FK33 build should use -- that build sets the generic false and this row does
  not argue with it.
* **No full-tree gate run was performed by this track.** Two other tracks were
  synthesising and `CLAUDE.md` forbids two concurrent full gates. What was run is
  in section 4.5.

---

## 9. Corrections to the dispatching brief

* **Gap 1 as written is wrong about `rtl/axi_rd_port.vhd`.** It says the file has
  "NO mutation script at all". `sim/mutate_axi_rd_port_dual.sh` has existed since
  earlier on 2026-08-29 (TRACK CDC-STATIC) with `RTL=rtl/axi_rd_port.vhd`. What
  was genuinely missing is coverage of the `g_sc` generate and the concurrent
  assignments above both generates. The new script is scoped to exactly that and
  its header says so, so the two do not overlap.
* **Everything else in the brief held.** `rtl/matvec_int4.vhd` really had no
  script, `USE_XEXP_PORT = true` really appeared nowhere, and `DUAL_CLK = true`
  on the descriptor path really was manual, with `sim/regress.sh`'s own comment
  as the reason.
