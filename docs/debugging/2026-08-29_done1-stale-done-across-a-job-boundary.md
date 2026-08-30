# STATUS reported the PREVIOUS job's completion for three clocks after every GO

**Date:** 2026-08-29. Branch `fpga`. **Track DONE1.**
**Files:** `rtl/matvec_int4_desc_axi.vhd`, `sim/tb_matvec_fk33_desc.vhd`,
`sim/mutate_mv4i_desc_stale.sh` (new).
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/*.sh`, `hw/fk33/tcl/` or `hw/fk33/host/`, and nothing opening
`/dev/xdma*`. `hw/fk33/host/fk33_run_job.py` was READ and not edited.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

**Machine, MEASURED at 23:27 before starting** (`df -h`, `free -g`, `uptime`):
root `/dev/nvme1n1p6` 91% used, 120 G free; `/mnt/storage` 56%, 387 G free;
RAM 31 G total, 12 used, 18 buff/cache, swap 14 of 31 used; load average 5.43
with TRACK COMPOSE4's place-and-route in flight. Nothing here ran synthesis.

---

## 1. The question, verbatim

> `rtl/matvec_int4_desc_axi.vhd` clears `done_l` at the next `S_IDLE` (`:643`),
> not on the GO write, so after a GO, STATUS briefly reports the **previous**
> job's completion. A single-job tool can never meet this; a sequence meets it
> on **every job after the first**. PCIe ordering plus AXI-Lite latency almost
> certainly closes it -- **by ~10x, not by construction.** Detected via the
> engine's own BEATS counter, yielding INCONCLUSIVE; **blind on same-shape
> adjacencies** (`ffn_gate`/`ffn_up`). RTL fix: **clear `done_l` on the CTRL
> write.**
>
> 1. Fix it. 2. Prove the fix bit-exact for the single-job case. 3. Build a
> check that would have caught it -- the hard case is two jobs of the SAME
> shape. 4. If a card experiment would demonstrate the race, write it as a
> precise command list.

---

## 2. The answer, up front

**The window is real and it is exactly THREE core clocks, MEASURED, not
"about three". It is fixed, and the fix leaves the single-job path byte-for-byte
identical. A check now exists that fails on the old RTL and passes on the new
one, and the same defect with that check absent still PASSES -- so the kill is
attributable to the check and not to something else that happened to move.**

**And the brief's premise is WRONG in a way that matters, in the project's
favour on the evidence and against it on the reasoning.** See section 7:
`hw/fk33/host/fk33_run_job.py` never resets the engine -- only a bitstream
reload does -- so **from its SECOND invocation onward on one loaded bitstream,
every "single job" run is a job after a completed job and meets this window.**
Tonight's 30+ bit-exact card results are therefore roughly thirty trials of this
race, not zero, and the tool already prints the witness on every run
(`after N polls`, where `N = 1` is the race lost). It is the strongest evidence
available about whether the race can be lost in practice, it was collected
before anyone knew the defect existed, and it costs nothing to read.

Four numbers, all MEASURED by `sim/regress.sh` over the three
`tb_matvec_fk33_desc` rows:

| RTL | bench | OVERALL | what it establishes |
|---|---|---|---|
| fixed | new check | `PASS 3 FAIL 0` | the fix and the check agree |
| **HEAD (the defect)** | **new check** | **`PASS 0 FAIL 3`** | the check kills it, on all three configurations |
| **HEAD (the defect)** | **old bench** | **`PASS 3 FAIL 0`** | **the attribution control: without the new check the defect is invisible** |
| fixed | old bench | `PASS 3 FAIL 0` | the fix does not disturb anything that already existed |

---

## 3. Verifying the brief before acting on it

**LAYERRUN's line numbers are correct.** MEASURED on `HEAD` at `912228c`
(`git show HEAD:rtl/matvec_int4_desc_axi.vhd | grep -n ...`):

```
608:  job_done <= done_l;
624:        st <= S_IDLE; busy <= '0'; done_l <= '0'; err_l <= '0';
643:              done_l <= '0';
903:      go <= '0';
929:            when 2 => if s_axi_wdata(0) = '1' then go <= '1'; end if;
```

`:643` is inside `when S_IDLE => if go_p = '1' then`, and `:878` is the
`S_WAIT -> S_DONE` arm that sets it. So the reading is right.

**The width is not "about three", and it is worth deriving because the fix has
to close all of it.** Let `T` be the cycle in which the AW/W handshake for the
CTRL write occurs -- `awready` and `wready` are both high, which happens for
exactly one cycle:

| cycle | what happens | `done_l` read as |
|---|---|---|
| `T`   | handshake. `go <= '1'`, `bvalid <= '1'` (both take effect after `T`) | 1 |
| `T+1` | `go = '1'`, so `go_p <= '1'`. **BVALID is already high: the host's write has completed** | 1 |
| `T+2` | `go_p = '1'`; `S_DONE` takes `st <= S_IDLE` | 1 |
| `T+3` | `S_IDLE` runs: `done_l <= '0'`, `busy <= '1'` | 1 |
| `T+4` | | 0 |

So `done_l` reads 1 on the three cycles `T+1`, `T+2`, `T+3` after the write has
been acknowledged. **MEASURED, not derived**: the cycle-accurate monitor added
in section 5 reports `job_done stayed asserted for 3 cycle(s)` on the HEAD file,
and `0` on the fixed one.

`busy` is 0 across the whole window too, so the state a host sees is
`done=1, busy=0` -- indistinguishable from a finished job.

---

## 4. The fix, and why it is not the fix the brief asked for

The brief says "clear `done_l` on the CTRL write". Taken literally -- clear it
from the registered `go` -- that closes two of the three cycles and leaves one.
That variant was BUILT AND MEASURED as mutation row `GO1`; see section 6.

What is here instead:

1. **`go_now`, a combinational decode of "a GO write is being accepted, THIS
   cycle"**, and the registered `go` is deleted so there is exactly one decode.
   It is combinational off signals that are all stable in that cycle:
   `awready`/`wready` are registered and high together for one cycle, `wr_addr`
   was captured the cycle before and is held, and AXI requires WDATA stable
   while WVALID is high.
2. **`done_l` is cleared on `go_now`**, in the same unconditional branch that
   captures `go_p`, so it fires from any state. The `S_WAIT` arm that SETS
   `done_l` runs later in the same process and therefore wins if a job completes
   on the very cycle a new GO is written, which is the right priority.
3. **STATUS bit 0 and the `job_done` port are masked with `not go_now`.** The
   registered clear cannot cover cycle `T` itself. No PCIe master can issue a
   read that reaches the slave in the same cycle as the posted write ahead of
   it -- but "no master can" is an argument about the master, and this is meant
   to be an argument about the slave.

The `done_l <= '0'` in `S_IDLE` is **deliberately kept** even though it is now
redundant. It is the assignment the defect lived in, and leaving it means the
`go_now` clear is the only thing standing between the design and the old
three-cycle window -- so a mutation that removes it is caught by the new timing
check **and by nothing else**, which is what makes that check attributable
rather than merely present.

Net effect on the FSM: `go_p` is set one cycle earlier than before, so `busy`
rises at `T+2` instead of `T+3` and every job is one cycle shorter.

### The fix does not move a single value

MEASURED, `sim/regress.sh --only tb_matvec_fk33_desc --keep`, before and after,
all three rows:

```
$ diff <(sed 's/@[0-9]*ns//' base/sim_tb_matvec_fk33_desc/log) \
       <(sed 's/@[0-9]*ns//' fix1/sim_tb_matvec_fk33_desc/log)
IDENTICAL modulo timestamps
== _dual  IDENTICAL modulo timestamps
== _xexp  IDENTICAL modulo timestamps
```

Every report line, every case verdict, every element count, byte for byte. The
only difference anywhere is the simulation end time, `659765 ns -> 659525 ns`,
which is the 24 cycles the earlier `go_p` saves across the run's GO writes.
**That is the single-job proof the brief asked for**: the 23-case matrix, both
shape sweeps and the AXI-Lite readback of every result row are unchanged.

---

## 5. The check, and why a two-job bench is not enough on its own

Two independent statements were added to `sim/tb_matvec_fk33_desc.vhd`. Both
are needed, and the reason is a measurement trap I nearly walked into.

### 5.1 The trap: the register read alone was measuring the testbench

The natural check is "write GO, read STATUS, require done = 0". That check DOES
bite on the HEAD file -- but only just. The bench's own `awr` returns after
BVALID at `T+2`; `ard` then waits one edge and drives ARVALID, which the DUT
samples at `T+3`. **`T+3` is the last stale cycle.** One extra
`wait until rising_edge(clk)` anywhere in `awr` -- a plausible tidy-up by
anybody -- and the defect becomes invisible while the row still says PASS.

A check with one cycle of margin against a three-cycle window is measuring the
testbench, not the design. So the window is ALSO measured directly.

### 5.2 The cycle-accurate monitor

A passive process watches only ports: the AW/W handshake (`awready and wready`
with `awaddr = 0x08` and `wdata(0)`) and the `job_done` output. It counts the
consecutive cycles, starting at the first edge after that handshake, on which
`job_done` is still asserted. The invariant is that the count is **zero**, and
it is asserted per job in the new section and again globally over every GO the
whole bench writes:

```
stale-done: 74 GO writes observed, worst window 0 cycles
```

`mon_gos` is checked too (`< 3` is an error), because a monitor that silently
observed nothing would otherwise report a perfect zero. That is the ACOV lesson
from TRACK ASURV applied here: a quantity that should be unreachable is worth
asserting, not discarding.

### 5.3 The three-job sequence, and the discriminator

Every other check in this file runs ONE job per arming -- the shape sweep resets
between shapes, the case loop resets between cases, because `err`/`err_code` are
sticky by design. So nothing in it could observe state that survives a job
boundary. The new section runs **three jobs back to back with no reset**.

**They are the same shape on purpose, and that is the whole difficulty.** Same
`n_rows` and `n_cols` means the same `tiles*nblk` means the same BEATS, so
`fk33_run_layer.py`'s `stale_done_check()` -- "BEATS must equal `tiles*nblk` for
THIS job" -- cannot see a swap between them. The live instance is `ffn_gate`
followed by `ffn_up` in every FFN layer of the 9B model.

The discriminator is **`x_exp`**, and the choice is not arbitrary.
`rtl/matvec_core.vhd:1031-1033` is the only place `x_exp` is read:

```
  y_exp <= (w_exp + x_exp)                        when out_mode = "10" else
           (w_exp + x_exp - os_r - ns_r)          when out_mode = "00" else
           (w_exp + x_exp - os_r);
```

The datapath never sees it. So job 1 runs with `x_exp + 1` and jobs 0 and 2 with
the trace's own value, giving three jobs that are:

* identical in BEATS -- so the counter check is blind;
* **bit-identical in every mantissa** -- so the element comparison is blind too,
  which is stricter than the brief's framing;
* different in exactly one register, `Y_EXP`, by exactly one.

Job 2 returns `x_exp` to the trace's value so the discriminator is shown to move
in **both** directions: a design that latched `y_exp` on the first job and never
updated it would pass a two-job version of this.

**Both blindnesses are ASSERTED, not described.** If BEATS ever differed across
the three jobs, the adjacency would no longer be the hard case and the section
would be testing something easier than it claims, so that is an error:

```
sequence: 3 jobs back to back with no reset, same shape, BEATS 384 on all three
and mantissas bit-identical on all three, so neither can distinguish them;
Y_EXP 6/7/6; 0 stale STATUS reads after a GO
```

The section is placed after the shape sweeps and **before** the case loop.
Cases 21 and 22 leave AXI reads outstanding at slaves that are not reset-aware
and running anything after them is TRACK ASURV's separate open question; this
section must not be the thing that meets it.

---

## 6. The evidence, as raw captured output

### 6.1 The fixed design

```
SEQUENCE job 0 (x_exp0 offset): 100 elements bit-exact, 100 rows bit-exact through AXI-Lite, Y_EXP=6, BEATS=384, stale-done window 0 cycles
SEQUENCE job 1 (x_exp1 offset): 100 elements bit-exact, 100 rows bit-exact through AXI-Lite, Y_EXP=7, BEATS=384, stale-done window 0 cycles
SEQUENCE job 2 (x_exp0 offset): 100 elements bit-exact, 100 rows bit-exact through AXI-Lite, Y_EXP=6, BEATS=384, stale-done window 0 cycles
sequence: 3 jobs back to back with no reset, same shape, BEATS 384 on all three and mantissas bit-identical on all three, so neither can distinguish them; Y_EXP 6/7/6; 0 stale STATUS reads after a GO
stale-done: 74 GO writes observed, worst window 0 cycles
```

Identical on `tb_matvec_fk33_desc`, `_dual` (DUAL_CLK) and `_xexp`
(USE_XEXP_PORT), i.e. the discriminator works through the wrapper port as well
as through the descriptor word.

### 6.2 The defect, verbatim from HEAD

```
SEQUENCE job 0 ...: 100 elements bit-exact, ... Y_EXP=6, BEATS=384, stale-done window 0 cycles
(report error): SEQUENCE job 1: STATUS reported DONE on the first read after its own GO.
    The job cannot have finished -- Y_EXP reads 6 and this job's answer is 7.  A host
    polling for done takes the PREVIOUS job's result here, and every counter it could
    cross-check against is the previous job's too
(report error): SEQUENCE job 1: job_done stayed asserted for 3 cycle(s) after this job's
    CTRL/GO write handshake.  STATUS.done in that window belongs to the PREVIOUS job
SEQUENCE job 1 (x_exp1 offset): 100 elements bit-exact, 100 rows bit-exact through
    AXI-Lite, Y_EXP=7, BEATS=384, stale-done window 3 cycles
(report error): SEQUENCE job 2: STATUS reported DONE on the first read after its own GO.
    The job cannot have finished -- Y_EXP reads 7 and this job's answer is 6. ...
(report error): stale-done: the WORST window over 74 GO writes was 3 cycle(s).
    STATUS.done must belong to the most recent GO
```

**Read job 1's own summary line.** `100 elements bit-exact, 100 rows bit-exact
through AXI-Lite, BEATS=384`. Every value check and every counter check on that
job passed while STATUS was reporting the previous job's completion and Y_EXP
was returning the previous job's exponent. That is the defect stated as a
measurement rather than as an argument: **the checks that exist are all green on
the job the host is being lied to about.**

### 6.3 The mutation table

`bash sim/mutate_mv4i_desc_stale.sh <scratch>`. Each row is a full
`sim/regress.sh --only tb_matvec_fk33_desc` over all three configurations, so a
`KILLED` is three failing rows, not one. The `why` column is read out of the
bench's own report text, so it says which check did the killing.

| row | RTL | bench | verdict | what killed it |
|---|---|---|---|---|
| BASE | fixed | new | **SURVIVED** (`PASS 3`) | -- (must survive, or nothing below is readable) |
| DEFECT | HEAD | new | **KILLED** (`FAIL 3`) | first-STATUS-read, per-job-window, global-worst |
| **CONTROL** | **HEAD** | **old** | **SURVIVED** (`PASS 3`) | **-- the defect is invisible without the new check** |
| FIXOLD | fixed | old | **SURVIVED** (`PASS 3`) | -- the single-job path is untouched |
| **GO1** | **`done_l <= '0'` on the registered `go`** | **new** | **KILLED** (`FAIL 3`) | **per-job-window, global-worst -- and NOT first-STATUS-read** |
| PORTSTALE | STATUS masked, `job_done` port left stale | new | **SURVIVED** (`PASS 3`) | -- a row that does NOT bite; see 6.5 |

All six rows are MEASURED. The harness's own output, verbatim, 15m58s wall:

```
NAME         RTL       BENCH  VERDICT   DETAIL
-------------------------------------------------------------------------------
BASE         fixed     new    SURVIVED  ... | --
DEFECT       prefix    new    KILLED    ... | first-STATUS-read per-job-window global-worst
CONTROL      prefix    old    SURVIVED  ... | --
FIXOLD       fixed     old    SURVIVED  ... | --
GO1          go1       new    KILLED    ... | per-job-window global-worst
PORTSTALE    portstale new    SURVIVED  ... | --
```

**The CONTROL row is the point.** TRACK GRAY1's table came out
`NEW CHECK ALONE=1, both=4, NEITHER=4` and without the control it would have
claimed five kills. Here the control says `PASS 3` against the same defective
RTL, so this is a `NEW CHECK ALONE` kill and nothing else in the bench moved.

### 6.4 The unfiltered last OVERALL line

Working tree, fix plus check, all three rows:

```
 suite sim   PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
```

Row cost rose from 50/55/48 s to 80/87/77 s -- the three extra jobs plus 300
AXI-Lite readbacks. All three rows are OPTIONAL (`tb_prereq` requires a packed
tensor), so `BASELINE_PASS` is untouched. It is **98** (TRACK FLOOR, `b60591d`),
not the 93 several briefs still say.

### 6.5 The two rows that carry the most information

**`GO1` -- the brief's own fix -- is KILLED, and killed by the monitor ALONE.**
It is the literal "clear `done_l` on the CTRL write" reading: clear it from the
registered `go`, which leaves a one-cycle window. Measured:

```
SEQUENCE job 1: job_done stayed asserted for 1 cycle(s) after this job's CTRL/GO
    write handshake.  STATUS.done in that window belongs to the PREVIOUS job
SEQUENCE job 2: job_done stayed asserted for 1 cycle(s) ...
stale-done: the WORST window over 74 GO writes was 1 cycle(s).
```

**There is no `STATUS reported DONE on the first read` line in that log.** The
register read -- the obvious check, the one a two-job bench naturally grows --
**SURVIVES the brief's own fix**, because at a one-cycle window the bench's
`awr`/`ard` pair samples one cycle too late. That is section 5.1's trap
measured rather than argued: had the register read been the only check, this
track would have applied a partial fix, seen green, and reported the invariant
closed. **The cycle-accurate monitor's resolution floor is one cycle**, which
is the smallest window that can exist in a synchronous design, so it is the
invariant and not a magnitude.

**`PORTSTALE` DOES NOT BITE, and it is recorded under its own name because a
mutation that survives measures the check's floor.** The mutant removes only the
`not go_now` mask from the `job_done` port, leaving the `go_now` state clear in
place. `done_l` is therefore already 0 from cycle `T+1`, the port is stale only
during cycle `T` itself, and the monitor counts from the first edge AFTER `T`.
So the mutant is invisible -- correctly, because **it is not a defect once the
state clear is there**. The mask closes only the same-cycle read, and no check
in this bench can produce one: `awr` and `ard` are sequential procedures on one
process and cannot issue AW and AR in the same cycle. **So the mask is
UNMEASURED defence, kept on the argument in section 4 point 3 and not on
evidence.** Anyone tempted to remove it should know that nothing here would
notice.

---

## 7. CORRECTION to the brief and to LAYERRUN's write-up

**"A single-job tool can never meet this" is FALSE, and the correction changes
what evidence already exists.**

MEASURED by reading `hw/fk33/host/fk33_run_job.py` end to end: **it never resets
the engine.** There is no reset path in it at all; the file's own refusal text
says so about `S_ERR` -- "left only by RESET ... Reload the bitstream before
retrying". The pre-run condition check at `:794` refuses on the sticky error bit
and on `busy`, and **does not look at `done`**.

So on one loaded bitstream:

* invocation 1 runs against `done_l = 0` and cannot meet the window;
* **invocation 2 and every one after it writes GO while `done_l` is still set
  from the previous invocation's completed job.** The process boundary is
  irrelevant -- the engine is the same one and nothing between them clears it.

Two consequences, and the second is the useful one:

1. The defect was reachable by the tools already in use, not only by
   `fk33_run_layer.py`. LAYERRUN's own mitigation and this write-up's framing
   both understated it.
2. **Tonight's 30+ bit-exact card results are roughly thirty trials of this
   race** and every one produced the right answer, which is real evidence that
   it is not being lost on this hardware -- collected before anyone knew there
   was a race, which is the best kind. **And the tool prints the witness on
   every run**: it counts its poll loop and prints
   `job STATUS=... after N polls / T s`. `N = 1` means the very first STATUS
   read after the GO already showed done, which for a job that takes
   microseconds is the race lost and nothing else.

Two transcripts survive in the repository, both `N > 1`:

```
docs/debugging/2026-08-29_first-arithmetic-on-the-silicon.md:
  job  STATUS=0x00000001 done=1 busy=0 err=0 err_code=0x0 (EC_NONE) after 9 polls / 0.000 s
docs/debugging/2026-08-29_first-throughput-numbers.md:
  job  ... after 472 polls / 0.001 s
```

The other ~30 runs' numbers are in the session's terminal history and not in the
repository, which is why section 8 asks for a grep rather than reporting a count.

---

## 8. The card experiment, as a precise command list

**The bitstream currently on card 1 is the DEFECTIVE one** -- it predates this
fix and nothing here rebuilt it. That is the only condition under which this
experiment is possible, so it is worth doing before any rebuild.

### 8.1 Free, no card, do this first

Every card job tonight after the first is a trial. Grep the session history:

```sh
grep -oE 'after [0-9]+ polls / [0-9.]+ s' <the session log or scrollback>
```

* Any `after 1 polls` is **the race lost, observed on hardware.**
* All values `>= 2`, over K runs, is `0 of K` trials lost. Report K.

### 8.2 The positive experiment, on the loaded defective bitstream

Uses `hw/fk33/host/fk33_run_job.py` exactly as it stands -- no edits, no new
tool, and the same discriminator the bench uses. Two jobs differing only in
`--x-exp` are the same shape, the same BEATS and the same mantissas, so the only
thing that separates them is `y_exp` -- and `polls`.

```sh
cd ~/GitHub/llama.vhdl
M=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/blk.0.ffn_gate.weight.mv4i
sg fk33 -c 'python3 hw/fk33/host/fk33ctl.py thermal --clear'
for i in $(seq 1 100); do
  for xe in 5 6; do
    sg fk33 -c "python3 hw/fk33/host/fk33_run_job.py run --mv4i $M \
        --rows 96 --x-exp $xe" 2>&1 | grep -E '^(job|result|VERDICT|y_exp)'
  done
done | tee ~/done1-card.log
grep -c 'after 1 polls' ~/done1-card.log
```

Substitute any packed tensor that already works; `--rows 96` keeps each job
short so `polls = 1` is unmistakable against the normal count.

**How to read it.** Two hundred jobs, of which 199 follow a completed job.

* `grep -c 'after 1 polls'` **greater than zero** -- the race is lost on this
  hardware, at the rate that count implies, and every one of those jobs read
  STATUS for the previous job. Check whether that job also reported a `y_exp`
  mismatch; it may not, because the Y registers are read microseconds later by
  which time the real job has finished. **`polls = 1` is the witness, the
  mismatch is not.**
* `0 of 199` -- the race was not lost in 199 trials. That is an upper bound of
  about 1.5% per job at 95% confidence, and combined with section 3's three
  cycles it is the honest statement: the window is ~15 ns (DERIVED at the
  200 MHz `core_clk` LAYERRUN used; `matvec_int4_desc_axi`'s `s_axi_aclk` IS
  `core_clk`, `hw/fk33/rtl/fk33_engine.vhd:18`) against an MMIO round trip of
  0.3-1 us, so the margin is 20-70x rather than the ~10x in the brief -- an
  ESTIMATE on the round-trip figure, which this same run measures as
  `elapsed / polls`.

**Either outcome is a result.** Zero losses does not withdraw the fix: a race
that is losing by 20-70x of timing margin is still a race, and the fix costs one
AND gate and changes no value.

### 8.3 What would settle it in one command if a tool edit were allowed

Not requested and not done, recorded so nobody re-derives it: read STATUS
immediately after the GO **and** read `BEATS` and `Y_EXP` in the same window,
before the poll loop. On the defective bitstream all three would report the
previous job. `fk33_run_job.py` is LAYERRUN's and mine to read only, so this is
a suggestion for its owner, not a change.

---

## 9. Measured and REJECTED -- do not retry

**`sim/mutate_mv4i_desc.sh` cannot run this check. Do not try to add it there.**
Its 27 weight and scale slaves (`sim/tb_mv4i_desc_image.vhd`) never assert
`arready`, so an accepted descriptor stalls the core on its first read and **no
job in that harness ever completes** -- that is its own header's branch `RUN`. A
stale `done` is by definition a completion belonging to a previous job, so a
harness in which nothing completes has nothing to be stale about. Hence the
separate `sim/mutate_mv4i_desc_stale.sh`, which runs the full bench.

**The register read alone as the check. REJECTED and kept only as the second
statement.** It bites on the HEAD file with exactly one cycle to spare
(section 5.1). It is retained because it is the only thing that says what a HOST
sees, but the verdict must not rest on it.

**`done_l <= '0'` on the registered `go` -- the brief's literal wording.**
Built as mutation row `GO1`. It closes two of three cycles and leaves the window
one cycle wide, which is not "by construction" and is exactly the property the
brief objected to. See section 10 for its measured verdict.

**A different-shape adjacency as the test case. REJECTED as the primary.** It is
the EASY case: BEATS differs, so `fk33_run_layer.py`'s existing host-side check
already catches it, and a bench built on it would have scored a kill while the
real adjacency in the 9B model -- `ffn_gate` then `ffn_up` -- stayed uncovered.

**Removing the redundant `S_IDLE` clear. REJECTED.** With it gone, a mutation of
the `go_now` clear leaves `done_l` set until reset, which trips several existing
checks and would have made the new check look load-bearing when it was not.
Keeping it means the new check is the only thing that catches that mutation.

---

## 10. Measurement traps hit, including my own

**I nearly shipped a check with one cycle of margin and called it a check.**
Section 5.1. The register read bites, and it bites because `awr` happens to
return at `T+2` and `ard` happens to sample at `T+3`. Nothing about the bench
guarantees that, nothing would flag it if it changed, and the row would have
gone on saying PASS. The cycle-accurate monitor exists because of this and not
for elegance.

**A three-job sequence whose jobs differ in shape would have been the wrong
test and would have looked like the right one.** It is the case the existing
host-side mitigation already covers.

**`git show HEAD:` is the right way to get "the defect".** Reconstructing the
pre-fix file by hand-reverting would have produced my idea of the defect. HEAD
is the file that shipped.

**`ghdl -s` on a file in this repository root reports a stale-library error**
(`file "rtl/util_pkg.vhd" has changed and must be reanalysed`) from a work
library left in the tree, and its rc is 1 even when the syntax is fine. Use
`sim/regress.sh` with `REGRESS_SCRATCH`; do not read anything into that message.

**The mutation harness builds a private repo of symlinks.** Four other tracks
are editing this tree; a run that read the live files would have measured
whatever they were mid-write. `git -C` still works because `.git` is symlinked
in.

**MY OWN, AND IT COST 26 GB.** The first version of that harness did
`cp -r "$REPO/sim"`. **`sim/` is 3.6 GB** -- `ooc_mv` 690 M, `e2_funcsim`
589 M, `gate2` 437 M, `xsim.dir` 186 M, `funcsim_mv` 64 M -- so six rows plus a
spare tree took the scratch to **26 GB and root to 93%** while TRACK COMPOSE4
was running a composed place-and-route. Caught by the coordinator, not by me.
Fixed by symlinking `rtl/` and `sim/` entry by entry and copying only the two
files a row mutates; `regress.sh` analyses `"$REPO/$f"` by path and cannot tell
the difference. Reclaimed by deleting each finished row's tree by full literal
path, one `rm -rf` per directory with nothing interpolated. **Assume any
directory in this repository is large until `du` says otherwise.**

**MY OWN, AND IT IS THE TRAP MY BRIEF WARNED ABOUT.** I edited
`sim/mutate_mv4i_desc_stale.sh` while it was executing. bash reads a script
lazily BY BYTE OFFSET, and it resumed mid-token:

```
sim/mutate_mv4i_desc_stale.sh: line 127: syntax error near unexpected token `)'
```

All six rows had already printed, so the table survived by luck and not by
care. The script self-isolates its inputs and does NOT re-exec itself the way
`sim/regress.sh` and `sim/mutate_mv4i_desc.sh` do; that is the gap. **Do not
edit it while it runs.**

---

## 11. Open, not yet answered

1. **No synthesis was run.** `go_now` adds a combinational term to the STATUS
   read mux and to the `job_done` port. It is a single AND on a path that is
   already a registered-handshake decode and is nowhere near the critical path
   (`rtl/matvec_core.vhd`'s header names the `acc+contrib -> round_shift` path
   as the one at -6.354 ns), but that is an ESTIMATE. COMPOSE4 is running the
   largest place-and-route attempted in this project and this did not compete
   for the box.
2. **The bitstream on the card does not have this fix**, and nothing here
   rebuilt one. Section 8's experiment depends on that and stops being possible
   after the next build.
3. **The real PCIe round-trip time is still unmeasured.** Section 8.2 measures
   it as a side effect (`elapsed / polls`).
4. **Whether `err_l` has the same problem.** It is never cleared except by
   reset, and `S_ERR` is sticky by design, so a GO after an error is refused at
   the host by `fk33_run_job.py`'s own pre-run check. Not the same defect, and
   not looked at.
5. **The two related items in the brief are NOT the same root cause, on the
   evidence here.** TRACK ASURV's `rtl/axi_rd_fsm.vhd:231` failures are about
   AXI reads outstanding at slaves across a RESET; this one is about a status
   bit across a GO with no reset involved. They share the phrase "state that
   survives a job boundary" and nothing mechanical. Whether subsystem A can be
   re-armed after `EC_CORE` remains open and belongs to TRACK A7's file.
6. **One activation vector, one shape, three jobs.** Coverage of the input
   space is not coverage of the output space: the sequence exercises the seam,
   not the arithmetic, and the arithmetic coverage is still the case loop's and
   the shape sweep's.
