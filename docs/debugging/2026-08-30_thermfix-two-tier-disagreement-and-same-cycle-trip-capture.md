# THERMFIX: fixing the two-stack equality halt and the trip record that lies

**Date:** 2026-08-30
**Tree:** branch `fpga`, parent `54f45c5`.
**Files changed:** `hw/fk33/rtl/fk33_thermal.vhd`,
`hw/fk33/sim/tb_fk33_thermal.vhd`, and the two host wording sites.
**Root cause document this fixes:**
`docs/debugging/2026-08-30_therm255-is-two-stacks-not-two-copies.md` (`54f45c5`).

**NO HARDWARE was touched by this track.** Every number below is from GHDL 1.0.0
(mcode) and Vivado 2023.2 xsim on the workstation. The card measurements quoted
are Oren's, taken with the card in his hands, and are labelled as his.

## The question, verbatim

> **1. Decide the fix for defect 1 and justify the choice against the
> alternatives.** [...] (a) drop `h0_acc = h1_acc` from `hbm_valid` and halt on
> `max(h0_acc, h1_acc)` [...]; (b) keep the equality test but only as a sticky
> DIAGNOSTIC, never as a halt input; (c) require the inequality to persist for
> N ms before it counts. **Do not just pick (a) because I listed it first.** [...]
> In particular: with the equality term gone, what still catches a genuinely
> torn or stuck sensor? [...] **If removing the equality term opens a hole,
> close it in the same change; do not leave it for later.**
>
> **2. Fix defect 2** so the record cannot lie. Sample the cause and the
> temperatures in the SAME cycle as the condition that halts, not a cycle later.

## The answer, up front

**Defect 1 is fixed as (b) and (c) TOGETHER, on two tiers, plus a repair to a
third defect the brief did not know about.** Neither (a), (b) nor (c) alone is
right, and (a) alone is unsafe for a reason that is not the one the brief
anticipated:

* **ANY sustained disagreement (delta >= 1 code, held for `G_HBM_DIV_MS` = 250 ms)
  sets the `THERM_STATUS[30]` sticky and does NOTHING ELSE.** That is candidate
  (b) with candidate (c)'s dwell bolted on. It keeps the sensitive stuck-sensor
  detector Oren asked to keep, and it cannot stop the card.
* **A disagreement WIDER than `G_HBM_MAX_DELTA` = 20 codes, held for the same
  250 ms, invalidates the sensor and therefore halts.** That is the tier that
  covers the failure which actually endangers the part.
* **Every threshold now compares `max(stack0, stack1)`, and the plausibility
  band is applied to BOTH stacks.**

**The third defect, found while doing this and not previously recorded:
`hbm_hot`, `hbm_cool`, `warn` and `cause` all compared `h0_acc` and nothing
else. Stack 1's temperature reached NO THRESHOLD in the design.** The equality
term was the only thing that made stack 1 matter at all. So candidate (a) as
written -- "drop the equality term" -- would have left an 8 GiB HBM stack
completely unguarded, and it would have looked like a clean one-line fix. This
is the hole the brief asked about, and it is bigger than the stuck-sensor one.

**Defect 2 is fixed** by capturing on `armed = '1' and halted = '0' and
(die_hot = '1' or hbm_hot = '1')` -- the combinational hot term, with `halted`
still reading its pre-halt registered value -- instead of on the registered edge
`halted = '1' and halted_d = '0'`. `halted_d` is deleted; nothing else used it.

**MEASURED:** 22 bench sections pass under both GHDL and xsim, 0 metavalue
warnings. **18 mutants injected, 17 killed, and all 17 kills are attributable:
the pre-change bench survives all 18.** The 1 survivor is named in the
resolution-floor table below rather than hidden.

## Why not (a), (b) or (c) on their own

Oren's card data (his measurement, quoted in full in his mid-track message)
settles the input to this decision and I am taking it as given:

| His measurement | Number |
|---|---|
| THERM_TEMPS samples with `h0 /= h1` | **0 of ~123,000,000** at 3.89 us, idle and under a 320-job load |
| Code crossings in 338 s | 82 up, 82 down, 0.243/s, **both stacks in the same 3.89 us sample every time** |
| Trips in that window | 2, **both landed on a crossing to the millisecond** |
| Fraction of crossings that trip | 2 / 82 = **2.44%** |
| Implied duration of the disagreement | **one aux clock, 5 ns at 200 MHz** |

### (a) alone -- drop the equality term, halt on max(). REJECTED.

Two independent holes, and the second is the one that matters.

1. *The stuck-sensor hole the brief named.* A stack sensor frozen at a plausible
   in-range code while its stack really heats is invisible to `max()` -- max
   reads the GOOD stack and stays cool. Coverage table for what remains:

   | remaining term in `hbm_valid` | catches a sensor stuck at a plausible code? |
   |---|---|
   | `hbm_seen` | **No.** It only records that a value was ever accepted. |
   | `hbm_wd < G_STALE_MS` | **No.** It watches the APB PCLK divider, which is independent of the value by design. A frozen reader with a running clock passes it, and the module header already says so in as many words. |
   | `G_HBM_MIN_CODE` / `G_HBM_MAX_CODE` | **No.** "Plausible" is the premise of the failure. |
   | `hbm_cattrip0/1` | **Yes, but only catastrophically**, and it is the stack's own pin, not our reading. |

   So the honest answer to "what still catches it" is: **nothing in the guard,
   only CATTRIP.** That is why the hole is closed in this change and not later.

2. *The hole the brief did not name, and the larger one.* `hbm_hot` compared
   `h0_acc >= G_HBM_HALT_C`. `hbm_cool` compared `h0_acc <= G_HBM_RESUME_C`.
   `warn` compared `h0_acc`. `cause` compared `h0_acc`. Under the equality term,
   `h0_acc = h1_acc` was a validity precondition, so comparing one stack was
   comparing both and the design was accidentally correct. **Remove the equality
   term and stack 1 stops being compared against any threshold at any point.**
   A card whose stack 1 reaches 110 C while stack 0 idles at 38 would not halt,
   would not warn, and would report `CAUSE_NONE`.

   This is exactly the shape the brief warned about -- "a fix which trades a
   false halt for a missed one" -- and it is why (a) is a four-line change and
   not a one-line one.

### (c) alone -- keep bare inequality, require N ms. REJECTED, with the reason.

On Oren's data (c) looks strongest, and I agree with his reading of the margin:
the false condition is ~5 ns and any N from a microsecond up removes 100% of the
observed trips. **The objection is not the margin, it is what the guard does on
a condition the card has never yet been in.**

(c) says: the two stacks differing by one code for N ms is a HALT. The evidence
that this never happens is 123 million samples **at one operating point** -- one
card, one ambient, one workload, both stacks parked on code 38 and dithering
across the 38/39 boundary. They are two separate dies at two board positions.
Under a sustained asymmetric HBM load -- which is what 9B inference on subsystem
A will be, and which the card has never run -- a steady 1-code gradient is an
ordinary thing for two dies to do.

If that happens, (c) halts, and it halts **permanently**, because the condition
is steady rather than transient. And a halt is not a 4.4% duty loss:
`fk33_run_job.py:811-814` refuses to start a job at all while `compute_halt` is
asserted. **(c) converts a spurious 4.4% duty loss into a card that cannot be
given work, on the premise that two separate dies are always exactly equal.**
That premise is measured true at one point and is not a property the hardware
guarantees.

The two-tier design keeps everything (c) buys and pays none of that: the
sensitive detector still fires on a sustained 1-code difference, it just reports
instead of halting.

### (b) alone -- demote to a sticky diagnostic. REJECTED, but it is half the fix.

(b) is right about the sensitive tier and wrong to stop there: it gives up
halting on a genuinely divergent sensor, which is a real safety property, and it
does nothing about the four `h0_acc`-only comparisons. Adopted for the
any-difference tier, with (c)'s dwell, and paired with a wide tier that halts.

### What the chosen design costs

DERIVED, not measured: two 7-bit comparators, one 7-bit subtract, two 16-bit
millisecond counters and four flops, on a VU33P. No synthesis was run for this
track -- see "open, not yet answered".

### The dwell, and why 250 ms is not a judgement call

DERIVED from Oren's numbers: the transient is **5 ns**; the dwell is **250 ms**;
the ratio is **5 x 10^7**. An HBM stack's thermal time constant is seconds, so
250 ms is also two orders below anything thermal. The threshold sits in a gap
seven orders of magnitude wide. There is no tuning to do here and no reason to
revisit the value.

### The bound, and why 20 codes

DERIVED. A sensor stuck at the measured idle code 38 is flagged once the live
stack reaches 38 + 20 = 58, which is **27 codes below the 85 halt point**, so the
halt still happens well before anything is over temperature. In the other
direction, 20 is 20x the largest stack-to-stack difference this card has ever
shown (1 code, and only for 5 ns). Both directions are asserted at elaboration
and one is also a synthesis-time `natural` constant (`C_HBM_DELTA_CEILING`,
`C_HBM_DELTA_FLOOR`) because **Vivado ignores `assert ... severity failure`** --
the existing idiom in this file, followed rather than reinvented.

## The procedure

1. **Read the RTL for what it compares, not for what its comments claim.** The
   entity comment asserted the two ports were "identical sources". Grepping for
   `h0_acc` was what found the four `h0_acc`-only comparisons, and that is the
   finding that decided against candidate (a).
2. **Check the bench's blind spot before writing a row.** `set_hbm(code)` drives
   BOTH stacks to the same value on every call. Seventeen sections, none of
   which could ever see a two-stack defect. **The bench was not weak, it was
   blind on one axis**, which is not the same thing and is not visible from a
   pass count.
3. **Establish the fast loop.** GHDL mcode runs this bench in 3.5 s; `sim_aux.sh`
   (xsim) takes ~45 s and is the real gate. Iterate on the first, gate on the
   second, and run BOTH before believing anything.
4. **Build `stage0`: the unmodified HEAD RTL with only the two new generics
   added, unused.** This is the "does the new row fail before the change" control
   in a form that actually elaborates.
5. **Write the rows, confirm they fail against `stage0`.**
6. **Apply the RTL fix, confirm all 22 sections pass under GHDL and xsim.**
7. **Mutate, with the attribution control.** 18 mutants of the FIXED RTL, each
   run against BOTH the new bench and the pre-change bench from `54f45c5`. A kill
   counts only if the old bench survives the same mutant.
8. **Add rows for the survivors that are real gaps; report the rest.**

## The evidence, raw

### The new rows fail against the unfixed RTL

`stage0` = `git show 54f45c5:hw/fk33/rtl/fk33_thermal.vhd` plus the two new
generic declarations, unused:

```
$ ghdl -r --std=08 tb_fk33_thermal
tb_fk33_thermal.vhd:240:7:@121100001ns:(assertion failure): tb_fk33_thermal:
halted='1' but expected '0' while the two HBM STACKS read one code apart at a
benign temperature.  They are separate dies; disagreement is not a fault
rc=1
```

### The fixed design, GHDL

```
$ ghdl -r --std=08 tb_fk33_thermal
rc=0
metavalue warnings: 0
tb_fk33_thermal.vhd:915:5:@242100750ns:(report note): TB_FK33_THERMAL PASS
```

### The fixed design, xsim -- the real gate

```
$ SIM_WORK=<scratch> bash hw/fk33/sim_aux.sh
Note: TB_FK33_AUX PASS
TB_FK33_AUX PASS
Note: THERM_STATUS = 0xC20777CD
Note: THERM_TEMPS  = 0x1E3C7A70
Note: THERM_PEAK   = 0x1EAF5E70
Note: THERM_TRIP   = 0x573C7A70
Note: THERM_CANARY = 15972
Note: die halt code = 745  resume code = 715
Note: TB_FK33_THERMAL PASS
TB_FK33_THERMAL PASS
```

`hw/fk33/sim_aux.sh` runs `tb_fk33_aux` as well, so this also confirms the
autonomous VCCINT controller bench is unaffected.

### `gen_pcieep.py --selftest` (the `sim:runguard` regression row)

```
$ python3 hw/fk33/gen_pcieep.py --selftest
GUARD ALONE=8  both=0  NEITHER=0
SELFTEST PASS
```

Relevant because `gen_pcieep.py` refuses to emit a build unless a list of exact
literal strings is present in `fk33_thermal.vhd` (the threshold generics, the
synthesis-time ceiling constants, the elaboration asserts, the `-- FAIL SAFE`
comment). None of them were disturbed.

### The mutation matrix, with the attribution control

Every mutant is applied to the FIXED RTL. "OLD bench" is
`git show 54f45c5:hw/fk33/sim/tb_fk33_thermal.vhd`, unmodified -- that column IS
the attribution control the project's verification discipline requires.

| mutant | what it reverts | NEW bench | OLD bench (control) |
|---|---|---|---|
| M1_equality_restored | `and h0_acc = h1_acc` back into `hbm_valid` | KILLED | SURVIVED |
| M2_hot_stack0_only | `hbm_hot` compares `h0_acc` | KILLED | SURVIVED |
| M3_cool_stack0_only | `hbm_cool` compares `h0_acc` | KILLED | SURVIVED |
| M4_warn_stack0_only | `warn` compares `h0_acc` | KILLED (only after a row was added; see below) | SURVIVED |
| M5_cause_stack0_only | `cause` compares `h0_acc` | KILLED | SURVIVED |
| M6_no_divergence_term | drop `hbm_div_bad` from `hbm_valid` | KILLED | SURVIVED |
| M7_divergence_no_dwell | wide tier fires on the first sample | KILLED | SURVIVED |
| M8_no_stack1_range_check | drop the `h1_acc` plausibility band | KILLED | SURVIVED |
| M9_trip_capture_one_late | trip capture back on the `halted` edge | KILLED | SURVIVED |
| M10_max_is_actually_min | `hbm_max` computes the minimum | KILLED | SURVIVED |
| M11_sticky_back_to_inequality | sticky back to bare `h0_acc /= h1_acc` | KILLED | SURVIVED |
| M12_hbm_seen_stack0_only | `hbm_seen <= h0_seen` | **SURVIVED** | SURVIVED |
| M13_delta_bound_is_zero | wide tier bound set to 0 codes | KILLED | SURVIVED |
| M14_sticky_only_on_wide_tier | sticky driven by the wide tier only | KILLED | SURVIVED |
| M15_sensitive_tier_can_halt | sensitive tier wired into `hbm_valid` | KILLED | SURVIVED |
| M16_no_sticky_at_all | `st_dis` never set | KILLED | SURVIVED |
| M17_sticky_not_cleared_by_clr | `st_dis` not cleared by a trip clear | KILLED | SURVIVED |
| M18_neq_dwell_removed | sensitive tier fires on the first sample | KILLED | SURVIVED |

Unmutated controls: fixed RTL + NEW bench SURVIVED; **fixed RTL + OLD bench
SURVIVED** -- so the change is not a regression against the bench that existed.

The kill messages are the rows' own assertion text; three worth quoting because
they name the defect rather than a symptom:

```
M1 : halted='1' but expected '0' while the two HBM STACKS read one code apart
     at a benign temperature.  They are separate dies; disagreement is not a fault
M2 : halted='0' but expected '1' while HBM STACK 1 ALONE is above the halt threshold
M9 : latched cause is 0, expected 1 after a SYSMON OT alarm exactly one aux clock long
```

M9's message is the card's own failure reproduced in simulation: a one-cycle
cause recorded as `CAUSE_NONE`.

### MUTATIONS THAT DID NOT BITE -- the resolution floor

This is the most useful part of the table and it is not discarded.

**M4_warn_stack0_only -- SURVIVED the first pass, then a row was added.**
Reverting `warn` to `h0_acc` survived the entire bench INCLUDING all the new
two-stack rows, because every row that put stack 1 alone above a threshold put
it above the HALT threshold, where the halt assertion fires first and `warn`
is never independently checked. `warn` is the host's only advance notice, so a
warn blind to stack 1 means a card that goes from quiet to halted with nothing
in between. Section 19 now has a row at `HBM_WARN_C + 2` on stack 1 alone, below
the halt point, and M4 is killed. **Found only by mutation; no amount of reading
the new rows would have shown it, because they all looked like they covered
stack 1.**

**M12_hbm_seen_stack0_only -- SURVIVED, and is NOT being chased.** `hbm_seen`
reduced to `h0_seen` changes behaviour only in a window of about four aux clocks
at power-on, before `h1_seen` sets. The bench's finest observation is the
agreement filter's own latency, so this is below its resolution floor and would
stay below it for any bench built on `wait for`. It is also **partly redundant
by construction after this change**: the new per-stack plausibility band rejects
an unread stack 1 (code 0 < `G_HBM_MIN_CODE` = 6), which is the condition
`h1_seen` existed to catch. Recorded, not closed.

## Measured and REJECTED -- do not retry

* **Candidate (a) alone, "drop the equality term and halt on max()".** REJECTED.
  It leaves stack 1 compared against no threshold anywhere (`hbm_hot`,
  `hbm_cool`, `warn` and `cause` all read `h0_acc` only), and it leaves a sensor
  stuck at a plausible code undetected by every remaining term. Mutants M2, M3,
  M4, M5 and M6 are that fix, and five of five are killed.
* **Candidate (c) alone, "bare inequality with an N ms dwell".** REJECTED on the
  argument above, not on the data -- the data supports it at the one operating
  point measured. It halts, permanently, on a steady 1-code gradient between two
  separate dies, and a halt blocks job start outright. Mutant M15 is that fix
  and it is killed by section 18b.
* **Candidate (b) alone, "sticky diagnostic only".** REJECTED: it gives up
  halting on a genuinely divergent sensor. Mutant M6 is that fix and it is
  killed. Adopted for the sensitive tier only.
* **Making the sticky fire on the wide tier instead of on any difference**
  (M14). REJECTED: the wide tier is a subset of the any-difference tier, so this
  discards exactly the sensitive detection the sticky exists for. Killed.
* **A dwell of 8 ms in the bench.** REJECTED as a BENCH parameter, not as a
  design one: section 18 spends three consecutive 3 ms waits with the stacks one
  code apart, and the dwell does not reset when the difference merely changes
  sign, so 9 ms of continuous disagreement set the sticky legitimately and the
  row failed. **That was the bench being wrong about its own timing, not the
  design.** The bench dwell is 20 ms; the build's is 250 ms.
* **Changing the block-design wiring** (`build_fk33_pcieep.tcl:781-782`).
  Not attempted, and it is not the fix -- the wiring is correct and the RTL's
  belief about it was not. Read it as the authority; do not edit it.

## Measurement traps hit, including my own

* **I nearly shipped candidate (a).** It is the first candidate listed, it is a
  one-line diff, and it makes the bench pass. What stopped it was grepping for
  `h0_acc` rather than reading around the equality term, and finding four
  comparisons that had never been about stack 0 in particular -- they were
  correct only as a downstream consequence of the defect being removed. **A
  defect can be load-bearing for correctness elsewhere, and removing it is then
  not a subtraction.**
* **The bench passed 17 sections and was blind on the axis that mattered.**
  `set_hbm` sets both stacks to one code; every HBM row in the file called it.
  A pass count says nothing about which axes were driven. The tell was cheap to
  look for and I nearly did not: read what the STIMULUS procedures can express
  before trusting what the assertions check.
* **The first mutation pass credited the new rows with a coverage they did not
  have.** M4 survived. All five `h0_acc` mutants looked like they should be
  killed by the same rows and four were; the fifth was not, because every
  stack-1-alone row sat above the HALT point where the halt assertion fires
  first. **A row can cover four mutants and miss the fifth for a reason that is
  invisible in the row's own text.**
* **`ghdl -r ... | head` reports the PIPELINE's return code, not GHDL's.** Known
  and in CLAUDE.md; the harness captures to a file and tests `rc` separately.
* **A metavalue warning I introduced and removed.** `hbm_max`/`hbm_min`/
  `hbm_delta` without initial values produced two `NUMERIC_STD.">=": metavalue
  detected` warnings at time 0. The baseline run had zero. Harmless in itself,
  but a simulation that prints routine warnings is one whose warnings stop being
  read; initialised and back to zero.
* **The final host-view comparison (section 22) was passing on an accident.**
  It requires the design to be STILL, because the canary counts every compute
  cycle while the guard is released and the publication filter can then never
  accept a word that still matches the live one. Section 16 happened to leave
  the guard halted and section 22 silently inherited that. Adding rows that
  leave the guard RUNNING broke it. Fixed by halting explicitly in a new
  section 21b rather than by depending on the row above. **This was a real
  pre-existing fragility, not something the new rows introduced.**

## Correction to the root-cause document (`54f45c5`)

That document states the two accumulators are unequal "transiently at every code
crossing" because the debounce counters are independent. **Oren's own card data
refutes it and he flagged it himself: 97.6% of crossings are clean (2 trips /
82 crossings), because both stacks' raw inputs usually change in the same aux
cycle.** Independent debounce makes them unequal only when the raw inputs land
in different cycles. No bench row here is built on the "every crossing" premise.

## Correction to this track's brief

The brief lists three candidate fixes for defect 1 and asks which is right. **The
answer is none of them as written**, because all three are framed as changes to
the equality term alone, and the equality term was masking a separate defect in
four other expressions. The brief's own instruction -- "if removing the equality
term opens a hole, close it in the same change" -- is what surfaced it; the hole
it anticipated (stuck sensor) is real but is the smaller of the two.

## Open, not yet answered

* **No synthesis was run.** The area and timing cost of two comparators, a
  subtract and two 16-bit counters on the aux domain is DERIVED as negligible
  and is NOT measured. The aux domain is 200 MHz and not timing-critical, but
  that is an estimate. **A build must be run before this reaches a bitstream.**
* **`gen_pcieep.py` does not guard the new generics.** It refuses to emit a build
  if `G_HBM_HALT_C`, the ceiling constants or the fail-safe comment go missing,
  and `G_HBM_MAX_DELTA` / `G_HBM_DIV_MS` have no such entry. I do not own that
  file. Someone should add `("G_HBM_MAX_DELTA : natural := 20", ...)` and the
  two `C_HBM_DELTA_*` constants to the literal list at `gen_pcieep.py:2294`.
* **Whether the two stacks ever separate under a sustained asymmetric load.**
  Still open -- Oren's 123 million samples are at one operating point with both
  stacks on code 38. **This change makes the card answer it: `THERM_STATUS[30]`
  now reads 0 on a healthy card and 1 only on a disagreement sustained past
  250 ms, and it cannot halt the card while doing so.** If it ever sets, the
  measurement has been taken for free.
* **The `G_HBM_MAX_DELTA` = 20 bound is set from one card at one temperature.**
  If bit 30 stays clear through a long 9B run, it can be tightened to ~6, which
  would flag a stuck sensor at live code 44 instead of 58. Do not tighten it on
  the current evidence.
* **The staleness path still has no dwell.** Oren noted this and it is correct:
  `hbm_wd >= G_STALE_MS` halts with no minimum persistence. It is covered by
  bench sections 16 and 21b for the "clock stopped" case. Whether it can produce
  a brief spurious halt of its own was NOT investigated here. Out of scope,
  written down.
* **Nothing here is on the card.** The bitstream loaded on the FK33 still
  contains both defects. This is a tree change only.
