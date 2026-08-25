# sat_event fired in PARTIAL mode, where subsystem A runs no saturation at all

## 1. The question

**2026-08-25**, subsystem A (`rtl/matvec_core.vhd`, `rtl/matvec_int4.vhd`),
regression `sh sim/run_matvec.sh`, all green before and after.

The question was not a symptom. It was a documentation check: subsystem D's
cross-spec review filed that **§5 of A's spec declares `y_data` as 32 bits
while §14.2 requires partial mode to emit the UNROUNDED s48 accumulator**. The
check was whether the RTL had the same bug as the paper.

It did not. The RTL is `ROWS_IF*64` and correct. But while writing the
sentence "in partial mode `sat_event` is tied low, because no saturating
operator is in the path", the RTL was read to confirm it, and it was not true.

## 2. The answer

`matvec_core` computed `sat32` on every output row **regardless of
`out_mode`** and set the sticky `sat_event` flag from it. In partial mode
that value is discarded (§14.2 emits the raw accumulator), so the flag
reported saturation of something that never left the unit.

The consequence is not cosmetic. Under cancellation a K-slice partial
legitimately exceeds the magnitude of the full-K result, which is the ordinary
case row-parallel sharding creates. So subsystem E would have seen
`sat_event` asserted on **healthy** partials, in exactly the workload
row-parallelism exists for, with no way to distinguish them from real clipping.

The C reference never had the bug: it `continue`s out of the row loop before
reaching `sat32`. So this was an RTL-versus-reference divergence, which is
precisely the class the whole verification chain is built to catch.

**It was not caught because `sat_event` was wired through three testbenches
and compared in none of them.**

## 3. The procedure

Each step isolates one thing. Run in this order.

1. **Read the RTL before writing the sentence about it.** The claim under test
   was one word ("tied low"). Checking it cost one `grep` and found the defect.
   The four preceding paragraphs of the same edit were spec-versus-spec
   reasoning and could never have found it.
2. **`grep -n "sat_event\|sat_r" rtl/matvec_core.vhd`** - locate every site
   that writes the flag. One write, line 500, inside the requant stage,
   unconditional on `out_mode`. Controls for the possibility that a guard
   existed elsewhere.
3. **`grep -n "sat32\|g_sat_event" ref/matvec_int4.c`** - the same question of
   the authority. Line 230 `continue`s before line 243's `sat32`. This is what
   makes it a divergence rather than a design choice; without it the RTL might
   simply have been implementing a contract the spec stated badly.
4. **`grep -n "sat_event" sim/tb_*.vhd`** - why no test failed. Both
   testbenches declare the signal and port-map it. Neither reads it. Controls
   for "the test exists but the case is not exercised", which would have been
   a different and much smaller fix.
5. **Check what the stage trace covers.** `emit_trace` runs `MV4I_MODE_BFP`
   only, with a random vector and `out_shift = 3`. So even had the flag been
   compared, the expected value would have been 0 in every case in the suite,
   and a stuck-at-0 implementation would have passed identically. **Two
   independent gaps**, and closing either one alone leaves the defect live.
6. **Write the failing test before the fix.** The adversarial vector already
   existed as the reference's test 12; it was promoted into `emit_trace`
   behind a flag.
7. **Fix, then revert the fix and confirm the test fails.** Step 7 is the only
   evidence that step 6 tests anything.

## 4. Evidence

The defect, `rtl/matvec_core.vhd:499-500` as it stood:

```vhdl
a32 := sat32(re2_shv(rr));
if re2_shv(rr) /= resize(a32, 48) then sat_r <= '1'; end if;
```

`a32` is consumed by `ynew` (the BFP output buffer) and `re3_mag` (the BFP
`amax` scan). Twelve lines below, `if out_mode = "10" then` routes the
**unrounded** accumulator to `y_data` instead. So in partial mode `a32` is
computed, tested, and dropped, and only the test has a lasting effect.

The reference, `ref/matvec_int4.c:230-243`:

```c
if (out_mode == MV4I_MODE_PARTIAL) {
    out->y_acc[r] = acc;
    continue;
}
out->y_data[r] = sat32(round_shift(acc, f->h.out_shift));   /* SITES 2/3 */
```

The test, with the guard reverted:

```
../tb_matvec_core.vhd:429:5:@1325ns:(assertion failure):
  SAT_EVENT SET IN PARTIAL MODE: 14.2 runs no sat32 on this path
```

and with the guard in place, the same two cases:

```
M=4   K=1024 ROWS_IF=4  stall=0  sat  OK   TOTAL: 524 stage + 8 output
M=13  K=1024 ROWS_IF=8  stall=5  sat  OK   TOTAL: 1703 stage + 26 output
== all green ==
```

`ns=16` in the BFP pass of those cases confirms the vector really does
saturate: `amax` reached `2^31 - 1`, so `msb_pos_u(amax) - 14 = 16`.

## 5. Measured and REJECTED, do not retry

- **`K = 512` for the adversarial case.** Does not saturate, so the whole test
  is vacuous while still reporting OK. Each block of 32 contributes
  `32 x 127 x 32768 x (32767/32768) ~= 1.33e8`; 16 blocks reach **2.13e9**,
  just under `2^31 - 1 = 2.147e9`. `NB > 16.1` is required, so `K = 1024`
  (`NB = 32`) is the first power-of-two that works. `K = 544` (`NB = 17`)
  would also do but needs the same testbench constant raised anyway.
- **Leaving `MAXB = 16` in `sim/tb_matvec_core.vhd`.** With `NB = 32` the
  trace loader indexes `wscl`/`widx` out of range. Raised to 32.
- **Relying on the existing sweep to cover this.** All eleven pre-existing
  cases have `out_shift = 3` and random weights; none saturates in any mode.
  Adding a `sat_event` comparison without adding a saturating vector would
  have compared 0 against 0 eleven times and proved nothing.
- **Asserting `sat_event = '0'` in partial mode from the trace.** It needs no
  expectation: §14.2 makes it invariant, so the testbench asserts it directly.
  Deriving it from the reference would have made the test agree with the
  reference's own bug had the reference had one.

## 6. Measurement traps hit

- **`ghdl: simulation stopped @205ns by --stop-delta=5000`** on the K=1024
  cases. This reads exactly like a zero-delay combinational loop in the DUT
  and cost a wrong hypothesis. It is not one: `sim/tb_matvec_core`'s trace
  loader does `wait for 0 ns` once per line, and the adversarial trace is
  ~5,000 lines (`M*K` IDX lines alone). The runner now passes
  `--stop-delta=1000000`. **A delta-limit stop is a property of the
  testbench's input size before it is a property of the design.**
- **Re-elaborating after editing the DUT.** `ghdl -a` on the changed entity
  alone gives `architecture "sim" of "tb_matvec_core" is obsoleted by entity
  "matvec_core"` at `-e` time. The testbench must be re-analysed too. Easy to
  read as a spurious error and retry the same command.
- **The spec sentence that started this was going to be wrong in a way no
  reader could detect.** "In partial mode it is tied low" describes behaviour,
  reads as a statement of design intent, and would have been quoted by
  subsystem E as a contract. The spec text is now written against what the
  RTL does, with the fix and the test named.

## 7. Open, not yet answered

- **`sat_event` is still not checked in `sim/tb_matvec_int4.vhd` (the end to
  end testbench) or in the AXI-Lite testbench.** Both wire it. The core-level
  check is the one with the adversarial vector, so the marginal value is low,
  but the same "wired and never compared" condition that produced this defect
  is still true of those two.
- **No test covers `sat_event` in RAW mode.** The flag is live there by the
  same argument as BFP, and `emit_trace` runs BFP only. Untested, not known
  wrong.
- **Whether subsystem E would in fact have acted on the flag.** E's spec
  requires it to be transported, and the failure described in section 2 is
  the plausible reading, but E has no implementation yet, so the blast radius
  is argued rather than observed.
- **The other ten inter-spec contradictions D filed.** This work closed two
  (`y_data` width, and the §5 drift underneath it) out of twelve.
