# Firing the FK33 thermal guard on purpose, at room temperature

## The question, verbatim

> We should run a synthetic quick test for the temp verification?
>
> We could set the temp thresholds lower and test the guard out?

Date: 2026-08-28. Hardware: SQRL FK33, `xcvu33p-fsvh2104-2L-e`, in a Gigabyte
Z790 AERO G at PCIe `06:00.0`, Gen3 x4. Bitstream: `fk33_pcieep_therm.bit`,
build stamp `0x20260828`. Die temperature throughout: 34.8 to 35.4 C. State
before the test: `THERM_STATUS = 0xc001009c`, i.e. `halted=0 armed=1
die_valid=1 hbm_valid=1 trips=1`, guard present (bit 31).

The context that makes the question the right one: every thermal result on
silicon so far had been the guard's REPORTING path. It said 35.3 C, it said
`armed=1`, it said `HALTED no`. **Nothing had ever made it say `HALTED yes`.**

## The answer, up front

**The guard works.** Lowering SYSMON's own user temperature alarm to 5 C below
the current die temperature makes it halt within milliseconds, latch cause 2,
increment the trip counter, snapshot the die temperature, and -- the part that
matters -- **freeze the compute domain**, which then resumes when the alarm
clears. Verified twice, and the test was teeth-checked by making the alarm
unable to assert, whereupon it correctly reported FAILED.

## The procedure, in the order it was run

The reusable idea is that **you do not need heat, and you should not lower the
guard's own thresholds.**

1. **Do not rebuild with lower generics.** The obvious reading of "set the
   thresholds lower" is to rebuild with `G_DIE_HALT_C` at 30. That tests a
   DIFFERENT BITSTREAM from the one you ship, costs a multi-hour synthesis, and
   leaves the shipped thresholds still unproven. Rejected on those grounds.

2. **Use the second comparator instead.** SYSMON carries its own programmable
   temperature comparator, `user_temp_alarm_out`, wired into the guard as
   `sysmon_alarm` and reported as cause 2. Its trip and reset points live in
   DRP registers 0x50 and 0x54, which are **writable at runtime over the same
   AXI-Lite BAR the host already uses**. Drop the trip point below the current
   die temperature and SYSMON asserts exactly as it would at 90 C. This
   exercises the real `sysmon_alarm -> cause -> halt -> compute_halt` path, in
   the shipped bitstream, with the shipped fabric thresholds untouched.

3. **Identify the registers by CONTENT, not by arithmetic.** See the traps
   section: the arithmetic was wrong. `INIT_53 = 0xBFD3` is this build's OT
   limit and is a distinctive word, so a read-only dump of the 4K window
   anchors DRP 0x53 unambiguously, and 0x50 / 0x54 follow from it. Do this
   BEFORE writing anything.

4. **Refuse to write anything not proven.** The test carries an address
   allowlist of exactly two registers. DRP 0x53 is the OT limit whose low
   nibble arms an automatic device shutdown; writing it low would trigger a
   real power-down. An allowlist means a typo cannot reach it.

5. **Measure the canary THREE times, not once.** The canary counts only while
   the guard is releasing work. "Canary frozen while halted" proves nothing on
   its own, because a canary that was broken and always frozen reads the same.
   The before-measurement is the control and it is not optional.

6. **Teeth-check the test.** Mutate it so the alarm cannot assert, confirm it
   FAILS, revert. A test that has never failed has never been shown to work.

## The evidence

### Identification, read-only, before any write

```
  alarm trip   DRP 0x50 @ 0x3540 = 0xba51  =   90.0 C
  alarm reset  DRP 0x54 @ 0x3550 = 0xb2c0  =   75.0 C
  OT limit     DRP 0x53 @ 0x354c = 0xbfd3  =  100.9 C   (never written)
```

This is also the **first on-silicon proof that the user alarm was really
programmed to 90/75**. Until now that was known only from a block-design
`CONFIG` property, and reading a `CONFIG` property reads a REQUEST, not an
answer.

### The trip

```
canary BEFORE     +239 toggles in 0.50 s

lowering the SYSMON user alarm to 29.8 C trip / 24.8 C reset (die is 34.8 C)
THERM_STATUS      0xcc0222bd
  halted=1  warn=0  armed=1  die_valid=1  hbm_valid=1  alarm_live=1
  alarm_sticky=1  trips=2  cause=SYSMON user temperature alarm
  trip count 1 -> 2
THERM_TRIP        0x52468e7b  cause=SYSMON user temperature alarm  die code=635
canary DURING     +0 toggles in 0.50 s

restored the alarm to 90/75 C
THERM_STATUS      0xc802209c
  halted=0 ... alarm_live=0  alarm_sticky=1  trips=2  cause=none
canary AFTER      +238 toggles in 0.50 s

THERMAL SELFTEST PASS
```

Second run, independently: `trips 2 -> 3`, canary `+239 / +0 / +238`.

`die code=635` is a 10-bit code, so `635 * 64 * 507.5921310 / 65536 - 279.42657680
= 35.3 C`, matching ambient at the instant of the trip. `fk33ctl.py thermal`
decoded the same snapshot independently as "at die 35.3 C, HBM code 35 / 35".

### The teeth check

Mutation: write the trip register with `code_of(CFG_TRIP_C)`, i.e. the 90 C it
already holds, so SYSMON can never assert.

```
lowering the SYSMON user alarm to 30.4 C trip / 25.4 C reset (die is 35.4 C)
THERM_STATUS      0xc803209c
  halted=0 ... trips=3  cause=none
canary AFTER      +239 toggles in 0.50 s

THERMAL SELFTEST FAILED
  - the guard did NOT halt when SYSMON asserted its user temperature alarm
```

Trip count did not move, confirming the guard genuinely never fired. Reverted,
and the PASS was reproduced.

### The clear path

```
$ ./fk33ctl.py thermal --clear
cleared; THERM_STATUS now 0x8000001c
```

Sticky bits, latched cause and trip count all reset; `armed`, `die_valid`,
`hbm_valid` and the guard-present bit retained. This also cleared the
pre-existing HBM CDC-disagreement sticky (bit 30).

## Measured and REJECTED -- do not retry

- **Rebuilding the bitstream with lower `G_DIE_*_C` generics.** Tests a
  different bitstream from the one you ship, costs hours of synthesis, and
  leaves the shipped thresholds unproven. The runtime SYSMON alarm gives a
  strictly better result for no build.
- **`AXI = base + 0x200 + 4 * drp` for the System Management Wizard.** That is
  the 7-series XADC Wizard map (status at +0x200, control at +0x300). On this
  UltraScale+ block the DRP window starts at **+0x400**. The wrong offset put
  `drp(0x00)` at `0x3200`, which is unmapped and reads 0, reported as a die
  temperature of **-279.4 C**. Confirmed correct at +0x400 by content.
- **Comparing the trip register for exact equality with the computed code.**
  It reads back `0xBA51`, not `0xBA50`: SYSMON does not clear the low nibble.
  The comparator uses only the top 12 bits, so mask before comparing or a
  correctly programmed part fails the check.

## Measurement traps hit, including our own

- **A read-only mode that wrote.** `--status` is documented "write nothing" and
  its restore ran in a `finally` block regardless, rewriting the trip register
  from `0xBA51` to `0xBA50`. The effect was harmless -- the low nibble is below
  the comparator's resolution -- but a read-only mode that writes is broken, and
  the next such bug will not be harmless. Fixed with a `modified` flag set only
  by the first real write.
- **A confident message naming a command that does not exist.** The script's
  own closing note said `./fk33ctl.py therm --clear`; the subcommand is
  `thermal`. This is the sixth instance today of the same defect shape: a
  specific, confident message about the wrong object.
- **`id -nG` does not tell you what the account can do.** It reports the
  CURRENT PROCESS's credentials, which are fixed at login. `orencollaco` is in
  `fk33` per `getent group fk33`, but a shell started before that lacks it and
  fails with `PermissionError: /dev/xdma0_user`. Use `sg fk33 -c '<cmd>'` for a
  single command rather than re-logging in.
- **The canary control measurement.** Omitting the before-reading would have
  made the whole test vacuous while looking exactly as green.

## Open, not yet answered

Cause 2 is now fully tested. Everything DOWNSTREAM of the cause mux is
therefore tested for every cause: the halt, the cause latch, the trip counter,
the trip snapshot, the CDC of `compute_halt` into the compute domain, and the
release. What remains untested is each other cause's own DETECTION:

- **cause 1**, SYSMON's armed OT alarm at 101 C. Deliberately not testable this
  way: its consequence is a device shutdown.
- **cause 3**, the fabric guard's own comparison against `G_DIE_HALT_C`. Needs
  either real heat or a rebuild, and shares no detection logic with cause 2.
- **cause 4 / 7**, sensor staleness. Would need a sensor to stop updating.
- **causes 5 / 6**, HBM CATTRIP and the HBM over-temperature comparison. **The
  HBM code-to-Celsius mapping is still uncalibrated** while the guard halts at
  code 85; code 35 alongside a 35.3 C die is consistent with code == Celsius but
  that remains an inference, not a measurement.
- **A latched HBM CDC fault (bit 30) was standing before this test** and was
  cleared by the `--clear` above. Its cause is still not understood.
- **The autonomous pot controller has still never had to MOVE the wiper**, only
  to agree with a value JTAG had already set. That needs a cold power cycle.
