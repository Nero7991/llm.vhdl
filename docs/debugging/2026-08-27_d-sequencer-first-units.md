# Subsystem D: the first two units, and four things the spec does not decide

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. New files only:
`rtl/seq_desc_fetch.vhd`, `rtl/seq_region_lock.vhd`, `sim/seq_tbl_pkg.vhd`,
`sim/tb_seq_desc_fetch.vhd`, `sim/tb_seq_region_lock.vhd`, and the four
`sim/run_*.sh` / `sim/mutate_*.sh` scripts.
**Tools:** GHDL 1.0.0, **mcode** backend (`ghdl -r` run directly; `ghdl -e`
produces no binary and silently succeeds). No synthesis was run: every
resource number below is a COUNT FROM THE RTL and not a measured utilisation.
**Target:** `MODEL = QWEN35_9B`, `NCARDS = 1`, from `rtl/model_cfg_pkg.vhd`.

## The question

Begin subsystem D as real RTL, building the first one or two units properly
rather than a subsystem of skeletons, without reproducing either of the two
integration defect classes found in subsystem B on 2026-08-27:

- **class (a)** a value read for the DURATION of a long operation while its
  source moves on underneath (`2026-08-27_gdn-emit-chain-w-latch.md`);
- **class (b)** a completion signalled as a one-cycle pulse and discarded
  because the consumer was busy (`2026-08-27_gdn-head-emit-done-pulse.md`).

## The answer

Two units exist and are verified in simulation against the **real 491-descriptor
Qwen3.5-9B token**, over 14 and 10 independently-skewed configurations
respectively, with 6 of 8 and 7 of 7 mutations killed. Both surviving mutations
are equivalent mutants under the current FSM, established by reading the code,
and the exact condition under which they stop being equivalent is stated below.

Building them surfaced **four places where the D design spec does not decide
something the RTL has to**, and one of them is a direct self-contradiction
inside that spec:

1. **D section 5.3's release rule contradicts D section 4.2's own schedule.**
   "The consumer's `done` returns R to FREE" is written for B and C, one
   consumer per region. Section 4.2 has region XN read by SIX consecutive A
   jobs. Under 5.3 the first of the six frees XN and the second consumes a
   region nobody produced. Resolved with an explicit release mask, which the
   section 6.1 descriptor format has no field for. **OPEN.**
2. **In-place update is undefined.** The residual step reads X and ER and
   writes X. Resolved here, flagged as a decision rather than a derivation.
   **OPEN.**
3. **Hazard A3 is real and now discharged.** The lock freezes a region's DATA;
   nothing froze its EXPONENT, which the consumer reads for the whole job.
   Fixed by making the exponent register part of the locked object.
4. **The host `abort` register was being read only in two states.** Found by
   writing the testbench, not by review. A one-cycle abort pulse was silently
   ignored anywhere else. That is defect class (b) with the HOST as the
   producer, in RTL written specifically to avoid class (b).

## Why these two units, of the candidates offered

`seq_desc_fetch` first because D's schedule is DATA -- a URAM table the host
generates -- so the table walker is what every other part of D hangs off, and
because descriptor PREFETCH is the one mechanism in D that makes class (a)
reachable by construction: prefetch IS the next job's data arriving while the
current job runs.

`seq_region_lock` second because it is the only place the four "region R must
not be written until unit U asserts done" obligations (O7, O8, O9, O15) become
checkable, and because the skeleton spec filed hazard A3 against it as a NEW
finding that nothing had yet acted on.

They are independent: no port connects them except the `chk_req`/`chk_bad`
verdict channel, which is exercised from a stub on each side.

## The procedure, in the order it was run

Each step isolates one thing, and the order is the one the w-latch document
argues for: get the weak configuration passing first so that a later failure is
readable as a concurrency property rather than as arithmetic.

1. **Build the descriptor table from `model_cfg_pkg`, not from spec prose.**
   `sim/seq_tbl_pkg.vhd` emits the whole 9B token -- 24 GDN blocks x 16 steps
   + 8 attention blocks x 13 + final norm + lm_head + END_TOKEN = **491
   descriptors** -- with every dimension a function of `MODEL`. The 16 and 13
   are the N=1 counts: the two E_COLL steps per block vanish and the
   row-parallel matvecs write their region directly. `NCARDS > 1` restores
   them, in the same function.
2. **Run the walker with a fast memory and slow units.** This is the
   configuration that gets the prefetch AHEAD, which is the class (a)
   exposure. It is NOT the configuration a throughput-tuned testbench reaches.
3. **Run it with a slow memory and instant units**, which starves the walker
   at `S_WAITPF` on every step and exercises the held `start` instead.
4. **Sweep the completion discipline**: `done` as a one-cycle pulse, `done` on
   its own timer ignoring the ack, `done` held past its ack, and `done` held
   past its ack by a unit that has already re-armed its `ready`.
5. **Inject one fault at a time** and check the ERROR CODE and the FAILING
   STEP INDEX, not merely that something failed.
6. **Mutate, then read every survivor.**
7. Repeat 2 to 6 for the region lock, with its own three streams.

## The evidence

### `seq_desc_fetch`, 14 configurations

Every one walks 491 descriptors, starts 490 jobs (END_TOKEN starts nobody) and
completes 490. Two tokens back to back on the clean runs.

```
skew: memory fast, units slow (prefetch far ahead)   PASS  stall 1498 cyc/token
skew: memory fast, units instant                     PASS  stall 11788
skew: memory slow, units instant (starves)           PASS  stall 98204
skew: memory slow, units slow                        PASS  stall 59912
skew: turnaround gap on every unit                   PASS  stall 13182
done is a ONE-CYCLE PULSE (withdrawn convention)     PASS
done drops on its own timer, not on the ack          PASS
done stays asserted PAST its ack                     PASS
unit re-arms on the ack while still driving done     PASS
stale job epoch echoed at step 137                   err=1 code=7 (ERR_EPOCH) step=137
unit err at step 200                                 err=1 code=1 (ERR_UNIT)  step=200
unit err for ONE CYCLE then dropped, done held       err=1 code=1 (ERR_UNIT)  step=200
region checker rejects step 64                       err=1 code=2 (ERR_LOCK)  step=64
host abort, a ONE-CYCLE pulse, at step 50            err=1 code=8 (ERR_ABORT) step=50
descriptor pad byte nonzero at step 300              err=1 code=3 (ERR_DESC)  step=300
unit hangs past the watchdog, completes in the drain err=1 code=4 (ERR_WDOG)  step=90
```

**Read the "prefetch-stall cycles" row as a question, not a result.** It is
cycles where `busy` is high and no job is live. The head-emit episode's
generalisable lesson is that a silently lossy path scores BETTER on any
throughput metric than a correct one, so the load-bearing assertions here are
the counting identities -- `steps_done = 491`, `jobs started = 490`,
`jobs completed = 490` -- which are present from the first run.

### `seq_desc_fetch`, mutations

| # | mutation | killed by | survived |
|---|---|---|---|
| M1 | two-bank descriptor shadow -> ONE bank | **A B C D E F G** | -- |
| M2 | S_ISSUE no longer refuses a unit still asserting `done` | C | A B D E F G |
| M3 | `err`/epoch re-latched every cycle instead of frozen at first sight | E | A B C D F G |
| M4 | sticky capture not gated on the unit having a job outstanding | C D | A B E F G |
| M5 | the job-epoch comparison at completion is removed | F | A B C D E G |
| M6 | END_TOKEN is not counted (accounting identity off by one) | A B C D | E F G |
| M7 | S_WAIT samples the RAW `done` instead of the sticky bit | -- | ALL |
| M8 | S_ABORT samples the RAW `done` instead of the sticky bit | -- | ALL |

Configurations: A prefetch far ahead, B units instant, C re-arms on ack with
`done` still high, D `done` on its own timer, E one-cycle unit `err`,
F stale epoch echo, G unit hangs past the watchdog.

### `seq_region_lock`, 10 configurations, all PASS

```
writes fast job slow / writes slow job instant / one write zero latency   PASS
3 write strobes after every completion   490 violations, 1470 drops, 0 unreported
1 late strobe, slow write stream         490 violations,  490 drops, 0 unreported
rogue exponent write at step 8           dropped (region 5, ALPHA, HELD by B)
rogue exponent write at step 110         dropped (region 0, X, HELD by the residual)
dst_offset is not the fill pointer       REJECTED code 3 (ERR_DESC)
consumes a region nobody produced        REJECTED code 2 (ERR_LOCK)
row count overruns the region            REJECTED code 3 (ERR_DESC)
```

### `seq_region_lock`, mutations -- all seven killed

| # | mutation | killed by |
|---|---|---|
| N1 | the exponent write gate ignores HELD (hazard A3 undone) | C |
| N2 | the write gate no longer requires a live committed job | B |
| N3 | append-only not enforced: any `dst_offset` accepted | D |
| N4 | a consumer may take a FREE region | E |
| N5 | the exponent is captured at ISSUE instead of at `done` | ALL |
| N6 | the release mask is ignored | A B C E F |
| N7 | completion acts on the LIVE issue ports, not the latched job | ALL |

## Measured and REJECTED -- do not retry

- **"The prefetch is only dangerous when the memory is slow."** Backwards, and
  it is the single most important result here. The two-bank shadow is
  exercised by a FAST memory and a SLOW unit, because that is when the fetch
  of step n+1 completes while step n is still live. M1 was killed by every
  configuration only because it also breaks the descriptor stream outright; the
  *shadow-moved* detector specifically needs the prefetch to get ahead. A
  testbench tuned for throughput -- short jobs, quick turnaround -- never gets
  it ahead at all.
- **`STALE_HOLD=5, JOB_LAT=4` as the stale-`done` test.** It passes on the
  BROKEN design (M2 survived it) and it looked like a clean result for two
  runs. Cause: at `JOB_LAT=4` the prefetch has not finished when the ack lands,
  so the walker sits in `S_WAITPF` for longer than `STALE_HOLD` and never
  reaches `S_ISSUE` with `done` still high. The guard goes untested and the run
  passes for the wrong reason. The working configuration is
  `STALE_HOLD=6, READY_EARLY, JOB_LAT=40, URAM_LAT=1`, where the prefetch is
  already waiting when the ack lands. **A test whose timing is set by the wrong
  bottleneck tests the bottleneck, not the mechanism.**
- **A stub whose `ready` rises only after its `done` falls.** With that
  coupling the stale-`done` guard is UNREACHABLE and M2 survives every
  configuration. It is the same defect as the head-emit testbench feeding both
  producers from one process: the coupling was in the stimulus, not the design.
  `READY_EARLY` decouples them.
- **`LATE_ERR` asserting `err` for TWO cycles.** M3 survives it. The
  re-latching design has exactly one cycle of slack, so a two-cycle error
  window still lands. `err` must be high for EXACTLY ONE cycle, coincident
  with the first cycle of `done`.
- **Testing append-only and the capacity bound at the same step.** At plan step
  4 (the wqkv v slice, offset 4096 of an 8192-entry QKV) an offset off by one
  ALSO overruns the region, so the capacity check rejects it and N3 -- removing
  append-only entirely -- survived. **Two checks that reject the same stimulus
  test as one check.** Moved to step 3, and added a separate `BAD_ROWS_AT` for
  the bound.
- **Requiring `drops = violations` in the lock testbench.** It FAILED a correct
  design. `viol` deliberately keeps the FIRST offender and does not overwrite
  it, so a burst of late writes gives many drops and one report. The invariant
  that actually matters is that no drop is SILENT: after any dropped strobe,
  `viol` must be asserted on the next cycle.
- **Holding the live `iss_*` ports stable during a job.** With them stable,
  "read the latched job" and "read the live port" are indistinguishable and N7
  survived every configuration. The testbench must SCRAMBLE them after commit,
  because that is what a real sequencer does -- it moves on to the next
  descriptor. **This is defect class (a) in the STIMULUS.**

## Measurement traps hit

- **A VHDL slice keeps its parent's index range.** `w(0)(15 downto 8)` is
  indexed 15..8, so `(0)` on it is a bounds error and not bit zero. Every
  descriptor field accessor now assigns through a declared 0-based variable.
  GHDL caught it at run time on the first execution; it would otherwise have
  been a silently wrong flag decode.
- **Five processes writing one `natural` counter** is five drivers on an
  unresolved type. GHDL reports it with no line number, which this project has
  been bitten by before. Per-unit array elements are distinct drivers under
  VHDL's longest-static-prefix rule and are the fix.
- **A concurrent alias signal is `'U'` at time zero** until the first delta, so
  a combinational process reading it emits a page of `numeric_std` metavalue
  warnings at time zero. Harmless in itself, and exactly what makes a real
  warning later easy to scroll past. Initialise the alias.
- **`TO_UNSIGNED: vector truncated`, once, at 30.8 us.** lm_head emits 248,320
  rows and has no destination region, so passing its row count on a
  region-scoped 16-bit port means nothing. The fix is to pass zero, not to
  widen the port: `iss_n_rows` is bounded by the largest REGION (12,288 at 9B,
  17,408 at 27B), not by the job's output row count.
- **`--max-stack-alloc=0` is mandatory.** The 491-descriptor table and the
  491-step plan are function-local temporaries and exceed ghdl-mcode's default
  128 KB cap. Without it, elaboration fails with a message that reads like a
  design error.
- **An unused input port is a smell.** `iss_req` was declared for interface
  clarity and read by nothing. It now drives a STRICT assertion that a commit
  never happens without a verdict having been asked for.

## Resource counts -- COUNTS FROM THE RTL, NOT MEASURED UTILISATION

No synthesis was run. These are hand counts of declared registers at the
default generics, and they are labelled as counts precisely because the D
design spec's section 12 numbers are estimates that have been withdrawn twice.

| | `seq_desc_fetch` | `seq_region_lock` | note |
|---|---|---|---|
| DSP48E2 | **0** | **0** | no `*` on a datapath anywhere; the only products are elaboration-time constants and `region*SEGS` with `SEGS = 3` constant, i.e. `x<<1 + x` in LUTs |
| RAMB36 | **0** | **0** | nothing is memory-shaped: the descriptor banks are read fully combinationally, so they are registers |
| FF, total | **~1,222** | **~1,036** | |
| of which, dominant term | 1,024 = 2 banks x 8 x 64-bit descriptor words | 672 = 42 exponent slots x 16 bits | |
| remaining | ~198 (counters, FSM, sticky capture, watchdog) | ~364 (14 x 16-bit fill pointers, 28 lock bits, 42 valid bits, latched job, violation latch) | |

Two comparisons against the skeleton spec's section 4.4 itemisation:

- Its "descriptor shadow, live ~512" plus "prefetch bank ~512" is **1,024,
  exactly right**.
- Its "exponent capture, 16 segments x 16 b plus 16 valid bits = 272" is
  **understated by 442 FF** as built, because this RTL uses a UNIFORM
  `SEGS = 3` segments per region (42 slots) so the slot address is
  `region*SEGS + seg`. The packed 16-slot mapping the skeleton assumed needs a
  per-region base table. 442 FF is 0.05% of the device and the uniform version
  is one adder; recorded so the two numbers are not read as disagreeing about
  the design.

Combined ~2,258 FF sits well inside D section 12's ~15-25K FF estimate, which
covers all of D-ctrl plus D-vec's datapath pipelining.

## Corrections to the D design spec that this work implies

Stated rather than made: the spec files are not edited here.

- **Section 1's "one-cycle start/done pulse convention", inherited from
  `engine_shared`, is withdrawn** and this RTL does not implement it. Already
  flagged by the skeleton spec; now it is also a property of shipped code.
- **Section 5.3 needs a release rule for multiple consecutive readers**, and
  section 6.1's descriptor format needs a field to carry it. See finding 1.
- **Section 5.3/5.4 must state that the exponent capture register of a HELD
  region is frozen** (hazard A3). Discharged in RTL; the spec text has not
  caught up.
- **Section 6.1's `n_rows` is doing two jobs**: a region-scoped element count
  and a matvec output row count. They differ by 20x at lm_head. Either the
  lock's port is not `n_rows` or the descriptor needs two fields.
- **Section 10's error table gains ERR_EPOCH**, which the skeleton proposed and
  this RTL implements, with the failing step index in ERR_INFO.

## Open, not yet answered

- **The in-place lock semantics are a CHOICE, not a derivation.** A region that
  is both consumed and produced by one step stays HELD, must have `off = 0`,
  and returns to VALID with `fill_ptr = n_rows`. The alternative readings are
  in the RTL header. Nothing has reviewed this.
- **M7 and M8 are equivalent mutants FOR THIS FSM, and the argument is
  structural, not empirical.** Between `start` acceptance and `S_WAIT` there is
  no reachable state, and the walker never leaves `S_WAIT` for any reason other
  than the completion or the watchdog, so a raw sample and a sticky sample see
  the same set of instants. This was established by reading the state machine,
  not by assuming. **It stops being true the moment D grows the `S_GRANT`
  state that section 8.2 specifies**, or any other state a job can complete
  during. The sticky capture is kept, and its non-equivalent half -- freezing
  `err` and the epoch at first observation -- IS killed, by M3.
- **The base array is not fetched.** `nsub_w + nsub_s` 64-bit bases live at
  offset 0x40 of each descriptor and are only RANGE-CHECKED against
  `NSUB_MAX`. Its length is open with A section 14.5.
- **No synthesis, so no Fmax and no confirmation of the 0 DSP / 0 BRAM claims.**
  Both are construction arguments. The claim most worth testing is that
  `S_CHECK`'s parallel compares plus the external verdict close at the real
  clock in one state.
- **`seq_region_lock` polices the region banks; the banks do not exist.** The
  ten BLOCK-wide banks at 8 RAMB36 each (set by PORT WIDTH, not capacity) are
  the next unit, and the skeleton's item 4 -- whether they can deliver an
  unconditional 1-element write and a 1-cycle 512-bit read with a three-way
  source mux in the path -- is unanswered.
- **D-vec is untouched**, and its numeric contract still does not exist.
- **One token, one table.** Both testbenches walk the 9B N=1 table. The
  `NCARDS > 1` arm of `seq_tbl_pkg` builds E_COLL steps and is analysed but
  never simulated, because `MODEL`/`NCARDS` are compile-time constants and
  changing them is a separate build.
