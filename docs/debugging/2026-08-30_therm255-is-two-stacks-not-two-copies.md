# THERM-255: the guard halts compute because the two HBM stacks are not the same temperature

**Date:** 2026-08-30
**Card:** SQRL FK33, `xcvu33p-fsvh2104-2L-e`, the bitstream loaded 2026-08-29.
**Files:** `hw/fk33/rtl/fk33_thermal.vhd`, `hw/fk33/build_fk33_pcieep.tcl`,
`hw/fk33/host/fk33ctl.py`, `hw/fk33/host/fk33_run_job.py`.

## The question, verbatim

Open issue THERM-255: the thermal guard's trip counter reaches its 8-bit
saturating maximum of 255 on an idle card at benign temperatures, and **each
trip halts the compute domain**. Earlier tonight I characterised the trips as
bursty rather than decaying, and recorded that they "track HBM code-boundary
proximity in both directions" (CORRECTION 3 in
`2026-08-29_thermal-guard-255-trips.md`). Why does a card at 36 C trip a guard
whose HBM halt threshold is code 85?

## The answer, up front

**`hbm_valid` requires the two HBM stacks to report exactly the same
temperature code, and they are two physically separate dies.**

`hw/fk33/build_fk33_pcieep.tcl:781-782` wires

```
hbm/DRAM_0_STAT_TEMP -> fk33_therm_0/hbm_temp0
hbm/DRAM_1_STAT_TEMP -> fk33_therm_0/hbm_temp1
```

`fk33_thermal.vhd:814-819` then makes agreement a *validity* condition:

```vhdl
hbm_valid <= '1' when hbm_seen = '1'
                  and hbm_wd < to_unsigned(G_STALE_MS, hbm_wd'length)
                  and h0_acc = h1_acc                       -- <-- this
                  ...
```

and `:827` turns invalidity straight into a halt:

```vhdl
hbm_hot <= '1' when hbm_valid = '0' or ... ;
```

So whenever stack 0 and stack 1 differ by a single code -- which is the normal
condition for two dies at different board positions under different load, and
is *guaranteed* transiently whenever either one crosses a code boundary -- the
guard halts compute and counts a thermal trip.

**The equality test was written for a fault that does not exist in this build.**
The entity comment at `:240-245` states the premise explicitly:

> ... our own APB reads of 0x24000C on each of APB_0 and APB_1. Both are still
> taken, through SEPARATE synchroniser chains, and **required to AGREE:
> identical sources resolving differently is a metastability or tearing fault,
> and that is worth catching.** CATTRIP is genuinely per stack.

That is a correct design rule for two reads of *one* value. The shipping block
design does not do that. It wires the two ports to two stacks. The comment
distinguishes CATTRIP as "genuinely per stack" and thereby asserts that the
temperature is not, and **the temperature is**.

## The second defect, which is why the record never showed this

The trip's cause and temperatures are captured **one cycle after** the
condition that caused the halt. `:963`:

```vhdl
if armed = '1' and halted = '1' and halted_d = '0' then
  trip_valid <= '1';
  trip_cause <= cause;        -- combinational, re-evaluated THIS cycle
  trip_die   <= die_acc;
  trip_h0    <= h0_acc;
  trip_h1    <= h1_acc;
```

`halted` is a register. The edge `halted='1' and halted_d='0'` occurs one clock
after the combinational `hbm_hot` rose. `cause`, `h0_acc` and `h1_acc` are all
sampled in that later cycle. Therefore **any halt condition shorter than two
cycles records `CAUSE_NONE` and post-transient, benign temperatures.**

Every other term that can assert a halt (SYSMON OT, the user alarm, CATTRIP,
an over-threshold accumulator) is level-held by a slow sensor and cannot be
that brief. **A transient `h0_acc /= h1_acc` is the only halt cause in the
design that can be one cycle long.** So `CAUSE_NONE` with equal recorded codes
is not a mystery: it is the signature of exactly this defect, and it is the
reason 255 trips accumulated with nothing in the record pointing anywhere.

## The procedure

The finding fell out of an unrelated experiment. It is recorded in that order
because the order is the point: the state was read before and after a workload
for a different reason, and the *change* is what carried the information.

1. **Clear the counter, establish the baseline.** `fk33ctl.py thermal --clear`
   -> `THERM_STATUS now 0x8000001C`. Bit 31 set (a guard is present), bit 30
   clear (no disagreement sticky), trips 0, no latched trip.
2. **Run a known workload and read the guard on every job.**
   200 `fk33_run_job.py run` invocations. The tool prints `THERM_STATUS` both
   before and after each job's GO, so this is **400 samples of the register
   taken while compute was active.** This is the control: it establishes what
   the guard did *during* the load.
3. **Read the guard again once idle**, twice, five seconds apart, to separate a
   momentary reading from a latched state.
4. **Follow the changed bits into the RTL**, and then follow the RTL's input
   ports out into the block design, because the RTL alone cannot say what is
   wired to them. This last step is what settled it; every earlier step was
   consistent with the comment's "metastability" story.

## The evidence, raw

Baseline, before the 200 jobs:

```
halted        no        warn no        armed yes
die     38.3 C   valid=yes   peak   41.3 C
HBM   code  38 /  38   valid=yes   peak  39 /  39
live cause    none
LATCHED TRIP  none since the last clear
```

All 400 in-job samples, identical:

```
=== every distinct THERM STATUS seen across the 200 jobs (bit30=0x40000000) ===
    400 STATUS=0x8000001C
=== did any job warn about bit 30? ===
0
=== did the trip counter ever move? ===
    200 trips=0 (was 0)
```

Idle, after:

```
halted        no        warn no        armed yes
die     38.8 C   valid=yes   peak   41.3 C
HBM   code  38 /  38   valid=yes   peak  39 /  39
live cause    none
LATCHED TRIP  none
              at die 37.8 C, HBM code 38 / 38
              trips since the last clear: 1
  STICKY: the two HBM temperature copies disagreed (a CDC fault)
```

Read that latched record closely, because three things in it are the whole
diagnosis:

* **`LATCHED TRIP none`** -- a trip fired and its cause is `CAUSE_NONE`.
* **`at die 37.8 C, HBM code 38 / 38`** -- the recorded codes are *equal*. A
  trip caused by inequality recorded equality, because the capture is a cycle
  late.
* **`STICKY: ... disagreed`** -- `st_dis` (`:898`) is sticky and therefore the
  only durable trace, and it survived to say an inequality did occur.

The wiring that settles it:

```
hw/fk33/build_fk33_pcieep.tcl:781:connect_bd_net [get_bd_pins hbm/DRAM_0_STAT_TEMP]    [get_bd_pins fk33_therm_0/hbm_temp0]
hw/fk33/build_fk33_pcieep.tcl:782:connect_bd_net [get_bd_pins hbm/DRAM_1_STAT_TEMP]    [get_bd_pins fk33_therm_0/hbm_temp1]
```

Independent debounce, which is why the inequality is also guaranteed
transiently at every code change (`:752-772`): `h0_acc` and `h1_acc` each have
their own `G_STABLE`-deep run counter (`h0_run`, `h1_run`) and each accepts a
new value only after its own input has been stable. The two counters are not
coupled, so the two accumulators step at different times even if the two stacks
were somehow always at the same temperature.

## What this predicts, and the prediction matches what was already measured

The earlier characterisation in `2026-08-29_thermal-guard-255-trips.md` was
recorded before any of this was understood, so it is an out-of-sample test:

| Recorded earlier | Explained by this |
|---|---|
| 34 trips in 151 s, then **631 s of exactly zero**, then 66 in 150 s | Both stacks sat on the same code for 631 s. Trips need a crossing. |
| Trips track code-boundary proximity **in both directions** | Warming and cooling both make one stack cross before the other. Nothing thermal is directional here. |
| Trips at 35-38 C against an 85 halt threshold | Temperature is irrelevant; only inequality matters. |
| The counter saturates at 255 while idle | An idle card still drifts across code boundaries. |

## Cost, DERIVED

`G_MIN_HALT_MS = 100` (`:193`), and the resume path requires `hold` to reach it
counting `ms_tick`, so **each trip halts the compute domain for at least
100 ms.** At the measured burst rate of 66 trips in 150 s that is 6.6 s of halt
in 150 s, a **4.4% duty loss** that is entirely spurious.

The sharper cost is not throughput. `fk33_run_job.py:811-814` **refuses to
start a job at all** while `compute_halt` is asserted:

```
refuse("compute_halt is asserted RIGHT NOW (ENGX_STAT=0x%08X). "
       "rtl/fk33_engine.vhd masks CTRL bit 0 while it is high, so a GO "
       "would be swallowed.  See open issue THERM-255." % xstat0)
```

So a long run does not degrade; it randomly aborts. Every card result to date
has been short enough to fit between bursts.

## Measured and REJECTED -- do not retry

* **"The trips are a thermal event and the card needs better cooling."**
  REJECTED. Die 35-38 C, peak 41.3 C, HBM code 38 against a halt threshold of
  85 and a warn threshold below that. No sample in 1172 s of 30 s-granularity
  logging came within 40 codes of the threshold. Cooling changes nothing.
* **"The trip counter is decaying / settling after a disturbance."**
  REJECTED earlier and again here: 631 s of exactly zero followed by a burst at
  roughly twice the initial rate is not decay.
* **"It is a CDC metastability fault, as the sticky's name says."**
  REJECTED. This is the one the tool and the RTL comment both assert, and it is
  the reason the issue stayed open. The synchronisers are correct: `h0_m/h0_s`
  and `h1_m/h1_s` are two-flop chains with `async_reg` (`:433-451`). Nothing is
  resolving badly. The two inputs genuinely carry different numbers.
* **"Run the 200-job experiment to catch it in the act."** REJECTED as a
  detection method, on this evidence: **400 register samples taken while
  compute was active caught nothing**, and the trip appeared only in the idle
  read afterwards. Sampling at job boundaries is far too coarse; the event is
  cycles long and the halt is 100 ms.

## Measurement traps hit, including my own

* **I read a truncated line and nearly filed the opposite finding.** My first
  `grep -E 'LATCHED'` returned `LATCHED TRIP  none`, which I read as "no trip".
  It is the *opposite*: `fk33ctl.py:354-360` prints `none since the last clear`
  when bit 7 is **clear**, and prints the decoded cause -- which for cause 0 is
  the string `none` -- followed by two further lines when bit 7 is **set**. The
  two states differ by a suffix and by lines my grep discarded. **A grep that
  keeps the label and drops the qualifier can iningest invert the meaning of a status
  readout.** Print the whole block.
* **The sticky's own name is the misdirection.** Both the RTL comment and
  `fk33ctl.py:365` call the two ports "copies" and the disagreement "a CDC
  fault". Every earlier investigation, mine included, took that at face value
  and went looking at the synchronisers. The name encodes a conclusion, and it
  is the wrong one. The RTL comment even flags CATTRIP as "genuinely per stack"
  while the temperature ports beside it are equally per stack.
* **The RTL cannot answer what its own ports mean.** Reading `fk33_thermal.vhd`
  end to end is not enough and was not enough: the file is self-consistent
  under its stated premise. The question was only settled by leaving the RTL
  for `build_fk33_pcieep.tcl`. A module's comment describes what its author
  believed was connected.
* **Absence of the sticky during 200 jobs is not absence of the fault.** It is
  a statement about the sampling rate, and I nearly reported the 400 clean
  samples as evidence the guard was quiet during load.

## Open, not yet answered

* **Are the two stacks routinely unequal, or only transiently at crossings?**
  Not determined. `peak_h0 = peak_h1 = 39` and both currently read 38, which is
  consistent with either. This decides whether the fix is a hold-off or the
  removal of the equality term, and it is measurable: log `THERM_TEMPS`
  bits [16:10] and [23:17] at high rate under a sustained load.
* **What the correct fix is.** Three candidates, none evaluated:
  (a) drop `h0_acc = h1_acc` from `hbm_valid` and halt on `max(h0_acc, h1_acc)`
  against the threshold, which is what a two-stack guard should do;
  (b) keep the equality test but only as a *sticky diagnostic*, never as a halt
  input; (c) require the inequality to persist for N ms before it counts.
  (a) and (b) both also want the capture-a-cycle-late defect fixed, or the
  record will keep lying about any brief cause.
* **Whether the trip capture defect masks anything else.** Any other one-cycle
  halt cause introduced later will record `CAUSE_NONE` too.
* **Nothing here is fixed.** The bitstream on the card, and the RTL in the
  tree, both still contain both defects.

## Correction to an earlier document

`docs/debugging/2026-08-29_thermal-guard-255-trips.md` CORRECTION 3 states that
the trips "track HBM code-boundary proximity". That observation stands and is
what this file explains, but the framing around it treated proximity to a code
boundary as a *thermal* quantity. It is not. **The temperature is irrelevant at
these levels; what matters is that a boundary crossing is when the two stacks'
accumulators are unequal.** The correlation is with *crossing*, not with
*heat*, and reading it as heat is what kept the search on cooling and on CDC
for as long as it stayed there.
