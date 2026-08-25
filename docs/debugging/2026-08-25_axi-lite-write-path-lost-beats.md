# The HBM bandwidth instrument measured zero, and the traffic generator was not the fault

**Date:** 2026-08-25
**Hardware:** SQRL FK33, xcvu33p-fsvh2104-2L-e, VCCINT 0.717 V measured
**Build:** `hw/fk33/build_fk33_hbmbw.tcl`, 15 HBM ports, AXI clock 300.00 MHz
**Symptom:** every sweep point reported `beats=0 cycles=0 GB/s=0.0`

## The question

Does the -22.9% voltage derate measured on this card apply to a real HBM
design, i.e. does a bitstream that Vivado signs off at 300 MHz actually run
at 300 MHz on a card at 0.717 V? The sweep was built to answer that by
failing its own beat check if the design ran outside its timing envelope.

The first run produced:

```
generator OK, NPORT=15, AXI clock 300.00 MHz
ceiling at NPORT ports = 144.0 GB/s
die temperature before: 27.7 C   stack codes: 28 28 29 29
 ports      beats       cycles         GB/s   %ceiling    die_C stacks
     1          0            0          0.0       0.0%     27.7 29 29 29 29  <-- BEATS WRONG, want 3200000
```

## The answer

The derate question is still unmeasured. This was not a timing failure and
not an HBM failure. **Every AXI-Lite control write was being silently
dropped, so the traffic generator was never told to start.** Reads worked
perfectly throughout, which is exactly what made it look like the generator
or the memory was at fault.

The slave asserted `s_wready` from reset but only decoded the data beat on a
cycle where the address had **already** been captured. smartconnect presents
AW and W in the same cycle. The master saw WREADY high, drove the beat, and
dropped WVALID; the slave took the address on that cycle and went looking for
data on the next one, where WVALID was gone. Fix: capture AW and W
independently, each with its own seen flag, and decode once both have
arrived. Commit `8643fcb`.

## The procedure that produced it

The sweep's own self-check is what made the run interpretable at all: it
knows how many beats a correct run must move (`n * NBURST * (ARLEN+1)`), so
it could say "this is not a measurement" rather than printing 0.0 GB/s as a
result. Everything below is about deciding **which** subsystem was silent.

1. **Read the ID register.** `0x48424D31` ("HBM1"). Proves the AXI-Lite
   address map, the clock-domain crossing, the smartconnect route and the
   read path are all correct end to end. This is the control that made the
   whole diagnosis possible, and it eliminated the four things that would
   normally be suspected first.
2. **Read NPORT.** Returned 15. Proves the generator was built with the
   parameters intended, so this is not a wrong-bitstream problem.
3. **Read the thermal registers.** `TEMP 0x03C78E9D`, `TRIP 0x00000000`.
   No trip, so the run was not being aborted by thermal protection.
4. **Write a control register whose effect is observable in a DIFFERENT
   register, then read that one.** This is the probe that isolates it.
   `TEMP_LIMIT = 1` against stacks reading ~28 **must** trip the ceiling and
   set bit 3 of TRIP. If the write lands, TRIP changes. It does not depend on
   HBM, on the traffic path, on timing, or on anything the generator does
   with its bursts.

   ```
   TEST 1: writing TEMP_LIMIT=1 (stacks read ~28, so this MUST trip)
     TRIP now 0x00000000  (bit3 = programmed ceiling)
     WRITES DO NOT REACH THE GENERATOR
   ```

   That one read splits the problem in half: control-plane vs data-plane.
   It came out control-plane, and every data-plane hypothesis was dead.

5. **Confirm with a full arm sequence.** Ports armed, six samples over 300 ms:

   ```
     t0 busy=0 cycles=0 beats=0 arstall=0 retired=0
     ... identical through t5
   ```

   `busy=0` is the tell. A generator that had been started and was stalling
   on HBM would show `busy=1` with `arstall` climbing. All-zero including
   `cycles` means the run never began. Had `arstall` been climbing, the
   reading would have been the opposite: generator fine, HBM not accepting.

6. **Find it in the source, not by guessing.** `s_wready <= wrq`, with `wrq`
   `'1'` from reset, while the data decode was gated on `awr = '0'`. READY
   high is a promise the beat was taken; the slave was making that promise a
   cycle before it was able to keep it.

## Evidence

The write path decode, before:

```vhdl
if s_awvalid = '1' and awr = '1' then
  wa <= unsigned(s_awaddr); awr <= '0';
end if;
if s_wvalid = '1' and wrq = '1' and awr = '0' then   -- never true same-cycle
  ...
```

After (`rtl/hbm_tg.vhd`):

```vhdl
if s_awvalid = '1' and awr = '1' then
  wa <= unsigned(s_awaddr); aw_seen <= '1'; awr <= '0';
end if;
if s_wvalid = '1' and wrq = '1' then
  wd <= s_wdata; w_seen <= '1'; wrq <= '0';
end if;
if (aw_seen = '1' or (s_awvalid = '1' and awr = '1')) and
   (w_seen  = '1' or (s_wvalid  = '1' and wrq = '1')) and bv = '0' then
  bv <= '1';
end if;
```

## Measured and REJECTED -- do not retry

- **"The design is running outside its timing envelope at 0.717 V."** This
  was the leading hypothesis and it is the whole reason the run existed.
  Refuted by step 1: a design missing timing badly enough to move zero beats
  would not return a correct ID, NPORT and packed thermal register over the
  same AXI-Lite path. Routed WNS was positive at sign-off.
- **"HBM has not finished initialising and is not accepting requests."**
  Refuted by step 5: `arstall` stayed 0. A generator waiting on HBM stalls
  visibly; this one never started. The diagnostic script had this reading
  pre-written and it did not fire.
- **"A port is mapped to the wrong pseudo-channel."** Refuted by step 4:
  the fault is in the control plane, upstream of any port.
- **"The address map or the CDC is wrong."** Refuted by step 1.
- **Thermal trip.** Refuted by step 3, and by the fixed check ordering since.

## Measurement traps hit

- **Reads working made the write path the LAST thing suspected.** Both
  directions cross the same smartconnect, the same CDC, the same address
  decode; four of the five shared stages were proven good by a successful
  read, and the intuition "the bus works" quietly extended to the one stage
  that was not shared. Prove each direction separately.

- **The testbench was more forgiving than the bus it stood in for.** Its
  write procedure held WVALID until it observed WREADY on a **later** edge,
  which re-offered a beat the slave had already dropped. No real master does
  that. The bug was fully present in RTL that passed simulation, and the
  testbench is what let it reach hardware. A too-lenient testbench is worse
  than none: it converts a protocol error into a mystery.

  Verified after the fix: the corrected testbench, run against the pre-fix
  RTL, fails at the "handshook but produced no BVALID" watchdog. The check
  now has demonstrated power against the actual defect, not just a green run
  against the fixed one.

- **The control registers were write-only.** With writes being dropped there
  was no way to ask the design what it thought it had been told, so the fault
  had to be cornered through the one side channel that happened to exist
  (TEMP_LIMIT's effect on TRIP). That worked, but only because a
  write-affects-a-different-register pair existed by accident. A readback
  window at `0x100` now mirrors all six control registers, and both the
  testbench and the sweep read them back **before** starting traffic.

- **The sweep checked beats before thermal trip.** A trip aborts the run and
  therefore also shortens the beat count, so a genuine thermal event would
  have been reported as "BEATS WRONG" and sent the reader looking for a
  timing fault. Reordered: the cause that explains the other symptom is
  checked first.

## Open, not yet answered

- **Does the -22.9% voltage derate apply to this design?** Unmeasured. The
  300 MHz build with the fixed write path is what answers it.
- **The 7-bit HBM stack temperature code is uncalibrated.** Idle codes 28-29
  observed at 27.7 C die. Whether the code is degrees is unconfirmed, so the
  programmed ceiling is currently a relative guard, not an absolute one.
  CATTRIP is the hard protection and does not depend on this.
- **Nothing in this design waits for or reports HBM initialisation
  completion.** It did not bite here, but the diagnostic anticipated it and
  the gap is real.
