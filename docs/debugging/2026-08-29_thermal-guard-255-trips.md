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
