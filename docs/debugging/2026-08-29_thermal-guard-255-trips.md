# The thermal guard tripped 255 times overnight, and it was not heat

**Status: OPEN. A watcher is running; this file will gain a CORRECTION when it
catches one.** Written now rather than later because the state that produced it
has already been cleared and cannot be recovered.

## The question

2026-08-29, ~00:30. SQRL FK33, `xcvu33p-fsvh2104-2L-e`, PCIe `06:00.0`, running
`fk33_pcieep_therm.bit` (the thermal build made BEFORE the ID_BUILD stamp fix,
which is why `fk33ctl.py id` reports `0x20260827` while the guard is present --
that is the very defect commit `674da7f` fixed in the generator, observed live).

I cleared the thermal trip counter to 0 at the end of the 2026-08-28 selftest.
On checking the card roughly 14 hours later:

    trips since the last clear: 255

255 is the **saturating** maximum of the 8-bit field, so the true count is 255
or more.

## The answer, so far

**It is not heat, and it is not the SYSMON alarm.** Every temperature was
comfortably cool at the time of reading and the peak-hold registers agree:

| | reading | halt threshold |
|---|---|---|
| die | 35.3 C, peak 37.3 C | 90 C |
| HBM code | 37 / 37, peak 38 / 38 | 85 |
| SYSMON user alarm sticky | **0**, never fired | 90 C |
| SYSMON OT sticky | 0 | 101 C |

What WAS set: **`STICKY: the two HBM temperature copies disagreed (a CDC
fault)`** -- `THERM_STATUS` bit 30. And `LATCHED TRIP: none`, i.e. `trip_cause`
= 0, on a counter that had saturated.

The working hypothesis, NOT yet confirmed, is the HBM staleness path: the guard
holds `hbm_valid` only while the two independently synchronised copies of the
HBM temperature agree for `G_STABLE+1` consecutive samples, and declares the
sensor invalid after `G_STALE_MS` = 250 ms without a fresh accepted sample. An
invalid sensor is treated as HOT, which is the correct fail-safe. So an
intermittently disagreeing HBM sensor produces exactly this signature: repeated
short halts, no temperature anywhere near a threshold, and the CDC sticky set.

**Each trip halts the compute domain.** On a card doing real work this would
present as random stalls with no apparent cause, and it is precisely the class
of fault that gets attributed to the wrong subsystem for a week.

## Why the count matters more than it looks

255 trips over ~14 hours is roughly **one every three minutes**. That rate is
low enough that a short observation misses it entirely, which is what happened
first:

    cleared to 0, then sampled every 5 s for 60 s:
    trips=0 cdc_sticky=0 hbm_valid=1 halted=0   (x12, no change)

**A 60-second clean sample is not evidence of absence at a 3-minute mean
interval.** Recording that explicitly because the obvious next move after a
clean minute is to declare it fixed and move on.

## The procedure

1. `fk33ctl.py thermal` for the full decode, not just `THERM_STATUS`. The trip
   COUNT and the CDC sticky are what carry the signal; the live cause was 0 and
   would have told you nothing on its own.
2. Check the peak-hold registers, not only the live temperatures. They rule out
   a thermal excursion that has since passed, which is the first hypothesis
   anyone forms and it is wrong here.
3. Clear the counter and re-read, to separate a historical burst from an
   ongoing fault.
4. Sample for **hours**, not minutes, printing only on change. Running as
   `scratchpad/therm_watch.py`, 10 s interval, logging every transition of
   `trips` / `cdc` / `hbm_valid` / `die_valid` / `halted` / cause with both
   temperatures alongside.

## Measured and REJECTED -- do not retry

- **"The temperatures are fine, so the guard is spurious."** The guard is
  behaving correctly: an unreadable sensor IS a reason to halt, and coming up
  halted on an invalid sensor is the designed fail-safe. The defect is in the
  HBM sensor path, not in the guard's decision.
- **A 60-second clean observation as proof.** See above. At ~1 per 3 minutes,
  twelve clean samples is an unremarkable gap.
- **Blaming the selftest.** The 2026-08-28 synthetic-trip runs produced 3 trips
  total, each accounted for and each with `trip_cause` = 2 (SYSMON user
  temperature alarm). These 255 have `trip_cause` = 0 and no alarm sticky, so
  they are a different mechanism.

## Open, not yet answered

- **Whether it is still happening.** The watcher will say.
- **Whether the HBM CDC disagreement is the cause or a co-symptom.** Both are
  consistent with the evidence collected so far.
- **Whether a halt of this duration is harmful.** The canary was at 25,225,229
  and advancing, so the compute domain is running; nothing measures how long
  each halt lasts. `G_MIN_HALT_MS` is 100 ms, so 255 trips is at least 25.5 s of
  halted time, and possibly much more.
- **Whether it correlates with anything.** Host DMA, PCIe activity and ambient
  are all uncontrolled in this observation.
- The HBM code-to-Celsius mapping is still uncalibrated, so "code 37" is not
  known to be 37 C. It has never mattered for a threshold decision yet.

---

## CORRECTION, 2026-08-29 07:35: the rate was wrong by 30x, and the hypothesis is confirmed

The watcher ran from 06:54:07 with the counter freshly cleared, sampling
`THERM_STATUS`, `THERM_TEMPS` and `THERM_TRIP` every 10 s and printing only on
change. It caught the whole event, from a clean card to saturation.

### What it measured

```
06:54:07 CHANGE trips=0   cdc=0 ... die=36C hbm=38/38 st=0x8000001c trip=0x50000000
06:58:58 CHANGE trips=1   cdc=1 ... die=36C hbm=37/37 st=0xc001009c trip=0x504c9a7b
...
07:23:49 CHANGE trips=255 cdc=1 ... die=36C hbm=38/38 st=0xc0ff009c trip=0x504c9a7b
07:25:19 CHANGE trips=255 cdc=1 ... halted=1 ...      st=0xc0ff009d trip=0x504c9a7b
```

**The counter went 0 to 255 in 24 minutes 51 seconds.** That is roughly **10
trips per minute**, not the one-per-three-minutes this file states above.

**The claim "255 trips over ~14 hours is roughly one every three minutes" is
WITHDRAWN.** A saturating counter records a FLOOR, not a count, so it sets no
rate at all; dividing it by the elapsed time silently assumes the saturation
happened at the end of the window. It did not. It happens in under half an hour,
so the true overnight figure is on the order of 8,000 trips, and the "a 60-second
sample is not evidence of absence" reasoning below, while correct in general, was
argued from a rate that was 30x too slow. A 60 s sample at the real rate would
have caught ten of them.

### The first trip and the CDC sticky are the same event

From a clean baseline (`trips=0`, `cdc=0`, `st=0x8000001c`), the very first
change in the log has BOTH `trips=1` and `cdc=1`. They set together, in the same
10 s sample, having both been clear for the preceding 4 m 51 s. The CDC
disagreement is not an incidental sticky that happened to be set at some point in
14 hours; it arrives with the first trip.

### The trip snapshot decodes to a HEALTHY card, and that CONFIRMS the mechanism

Decoding `THERM_TRIP` against the RTL's own packing (`fk33_thermal.vhd:1101`,
`[9:0]` die code, `[16:10]` HBM 0, `[23:17]` HBM 1, `[27:24]` cause, `[31:28]`
= 0x5):

| word | cause | die code | die | HBM 0 | HBM 1 |
|---|---|---|---|---|---|
| `0x504c9a7b` | 0 (none) | 635 | 39.4 C | 38 | 38 |
| `0x504a967b` | 0 (none) | 635 | 39.4 C | 37 | 37 |

Both snapshots are **in range and self-consistent**: `die_acc` is inside
`[C_DIE_MIN=474, C_DIE_MAX=860]` and the two HBM copies AGREE. So the guard
captured a card that was, at the capture instant, entirely healthy.

That is not a contradiction, it is the confirmation. The capture fires on
`armed='1' and halted='1' and halted_d='0'` (`:963`), and `halted` is itself
REGISTERED from the combinational `die_hot or hbm_hot` (`:911`). The capture
therefore lands **two aux clocks after** the condition that caused it. A
disagreement lasting one or two cycles drives `hbm_valid` low (`:815`, the
`h0_acc = h1_acc` term), which forces `hbm_hot` (`:826`) and sets `halted` -- and
by the time the capture edge arrives the codes agree again, so both the recorded
sample and `trip_cause` read healthy. `st_dis` (`:898`) is combinational-sticky
on the same disagreement and is the only thing that survives.

**Every observation is explained by exactly one mechanism: the two HBM
temperature copies momentarily disagree, the guard correctly fails closed, and
the diagnostic capture is too late to name why.** The guard is behaving as
designed. The fault is in the HBM temperature readback path.

### Consequence, and it is not cosmetic

`G_MIN_HALT_MS` = 100, so each of these costs at least 100 ms of halted compute
before the guard will release. At 10 trips per minute the compute domain is held
in reset **at least 1.7% of the time, in ~100 ms blocks, at random**. On a card
running inference that is not a 1.7% slowdown, it is a stall of a fifth of a
second appearing without cause in the middle of a token.

### The fix direction

The individual sensors already get an agreement filter (`G_STABLE+1` identical
consecutive samples, `:730`). The h0-vs-h1 comparison does not: it is a bare
combinational `h0_acc = h1_acc` and a single disagreeing cycle is sufficient to
invalidate. Giving that comparison the same treatment -- require N consecutive
disagreements before dropping `hbm_valid` -- restores the fail-safe on a genuine
sensor failure (which persists) while ignoring the transient (which does not).
`st_dis` must keep its current single-cycle sensitivity, so the sticky still
records that the CDC event happened.

**Not yet done, and it must not be done blind:** the real question is why the two
copies disagree at all, and the candidate is that the HBM readback runs off
`APB_0_PCLK`, an MMCM output whose input is `xdma/axi_aclk` -- documented in the
correction to `2026-08-28_fk33-first-light.md`. Filtering the symptom before
understanding the source risks masking a genuine HBM sensor fault.

## Measurement traps hit, added

- **A saturating counter divided by elapsed time is not a rate.** It is a floor
  divided by an assumption. This produced a figure 30x too slow and then that
  figure was used to argue about how long to observe for.
- **Decoding a packed register by hand.** A by-hand pass over `0x504c9a7b`
  produced "die code 123, HBM 32 vs 38, garbage sensor values" and a
  correspondingly dramatic conclusion, all of it wrong; the scripted decode
  against the field offsets in the RTL gives 635 / 38 / 38, healthy. Decode
  packed words with the packing statement open, in a script, or not at all.
