# The ns broadcast in `matvec_core`, and why it is two defects not one

Date: 2026-08-27
Design: `rtl/matvec_core.vhd`, subsystem A datapath core
Build: FK33, VU33P, `ROWS_IF = 58`, DSP 1914, LUT 134874, 0.717 V measured
Symptom: post-route 172.6 MHz, WNS -2.495, against a 3.300 ns constraint

---

## The question

Verbatim from the coordinator brief, 2026-08-27:

> **A binds the die clock and it is not close.** First place-and-route of
> `matvec_core` at the card's real 0.717 V landed: **172.6 MHz**, WNS -2.495, at
> `ROWS_IF=58` (DSP 1914, LUT 134874). That is 27.4% below A's synthesis figure
> of 237.8 that every budget in the repo assumes [...]
>
> ```
> startpoint: ns_r_reg[1]_rep__7/C
> endpoint:   em_shv_reg[54][17]/D
> slack -2.495   logic 2.543   net 3.045      (54.5% ROUTE)
> ```
>
> **This is your `si_e_seg` problem again.** [...] One small control register
> drives the variable shift of 58 lanes of 32 bits. [...] There is a second
> problem here that `gdn_silu` did not have. **`ns_r` is declared `integer` at
> `:185`**, so a shift amount whose range is 0 to about 49 is being broadcast as
> a full 32-bit signal to 58 lanes. [...] Do both, and if you can separate their
> contributions, say which did what.

Plus, explicitly: does the fix cost cycles, given `tap_ns <= ns_r` at `:620` and
the `out_mode` exponent expression at `:663` also read the same register.

---

## The answer

Both changes are made and both are bit-exact. **The fix costs ZERO cycles**, and
that is not a lucky accident, it is a property of the state machine: `ns_r` is
written in `S_SCAN`, `S_SCAN` enters `S_EMIT` unconditionally, and `S_EMIT` also
clears `rd_v`, so its first cycle never writes `em_shv`. The first read of the
shift amount is therefore TWO cycles after `ns_r` is written, and a replica one
cycle behind `ns_r` is already correct. **The margin is exactly one cycle**, and
that was verified by breaking it deliberately, not by reading the code.

The true range is tighter than the brief assumed. `amax` is `unsigned(35 downto
0)`, so `msb_pos_u` returns 0..35 and `ns = max(0, that - 14)` is **0..21**, not
0..49. Six bits hold it, so the declaration is `natural range 0 to 63` and the
broadcast narrows **32 bits to 6, a factor of 5.3**, before any replication.

**A prediction, stated in advance so the measurement can refute it: the width
narrowing is the more valuable of the two, and it is the only one of the two
that can touch the LOGIC term.** The arithmetic that forces this conclusion:

```
constraint          3.300 ns     (Fmax 1/(3.300 + 2.495) = 172.6 MHz, exact)
path logic          2.543 ns
path net            3.045 ns
clocking overhead   0.207 ns     (5.795 achieved - 5.588 path)
=> to meet 3.300 with the logic term UNCHANGED, net must be <= 0.550 ns
```

`gdn_silu`'s per-lane replication landed at 0.530 ns. So replication alone, even
if it reproduces that result exactly, meets the constraint by **0.02 ns**. That
is not a margin, it is a coin toss. The narrowing is what can move the other
2.543 ns: with `sh` declared as a 32-bit `integer`, `round_shift` builds a
barrel shifter and a `shift_left(to_signed(1,33), sh-1)` one-hot bias decoder
sized for a 32-bit shift operand, in every one of the 58 lanes. Sized for a
6-bit operand instead, both shrink. **Watch the LUT count as well as Fmax** --
if the narrowing does what it should, `matvec_core` gets cheaper at the same
time, across 58 lanes, and that is a second measurable this change should be
judged on.

On the DONT_TOUCH question the brief raised: **it is safe here and it should be
kept.** `_rep__7` means Vivado replicated to 8 copies for 58 sinks, roughly 7
lanes each. The source-level array gives it 58, one per lane, which is the
maximum useful replication for the inter-lane distribution -- there is nothing
further for the tool to usefully do at that level, so forbidding it costs
nothing. What DONT_TOUCH would block is replication WITHIN a lane, and the
per-lane load is 6 bits into one 32-bit shifter, a fanout of roughly 32 per
control bit. That does not need replication. Cost: 58 x 6 = 348 flops at
`ROWS_IF = 58`, against 32 flops freed by narrowing `ns_r` itself, so **+322 FF**
on a design with 134,874 LUTs. Noise.

---

## What replication actually does, since it is easy to state wrongly

It does NOT reduce fanout. `ns_r` still drives 58 destinations; they are now
registers rather than shifters. What changes is the arc those 58 destinations
sit on:

```
before:  ns_r --(fanout 58, long)--> [32-bit barrel shifter, 2.543 ns] --> em_shv
after:   ns_r --(fanout 58, long)--> ns_rep(rr)        <- a whole period, ZERO logic
         ns_rep(rr) --(short, local)--> [barrel shifter] --> em_shv
```

The long-haul distribution gets a dedicated clock period with nothing in series
with it, and the arc that carries 2.543 ns of shifter logic now starts from a
register the placer is free to put next to the lane it feeds. That is the same
mechanism as the `gdn_silu` fix, and it is why the extra register level is not
an extra cycle of latency in the design: the lead already existed.

---

## The procedure

1. Read the three consumers of `ns_r` and classify them. `:632` is the 58-lane
   broadcast and the only one on the failing path. `:620` `tap_ns <= ns_r` is a
   trace output, single sink. `:663` `y_exp` is a combinational output
   expression, single sink. Only the first is replicated; the other two keep
   reading the master deliberately.
2. Derive the true range of `ns_r` from `amax`'s width rather than from the
   brief's estimate, because the declaration has to be a hard bound.
3. Establish the lead by walking the state machine cycle by cycle, then
   **verify it by breaking it**: add one more register level to the replica and
   confirm the existing testbench fails. A lead argument that no test can
   falsify is not a lead argument.
4. `sim/regress.sh --only matvec` before and after, then the full run.

---

## The evidence

Baseline, before any change:

```
 suite sim   PASS 4   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 1   FAIL 0
 OVERALL     PASS 5   FAIL 0 ... REGRESSION: PASS
```

After both changes, identical:

```
 suite sim   PASS 4   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 1   FAIL 0
 OVERALL     PASS 5   FAIL 0 ... REGRESSION: PASS
```

The teeth check. One extra register level on the replica, so it is TWO cycles
behind `ns_r` instead of one, everything else identical:

```
FAIL  sim:tb_matvec_core  exit 1: sim/tb_matvec_core.vhd:363:15:@515ns:
      (report error): Y MISMATCH mode=00 r=0 got -32768 want -13581
```

It fails on the very first row of the very first tile, and it fails as a
SATURATION (-32768), which is what a shift amount of 0 where 21 was wanted looks
like coming out of `sat16`. So the one-cycle margin is real, it is exactly one
cycle, and `tb_matvec_core` covers that boundary. Nothing about the correctness
of this change rests on reading the state machine.

Full suite, both suites, after the change:

```
 suite sim   PASS 43   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 69   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 REGRESSION: PASS
```

69 PASS / 0 FAIL, which is the stated baseline exactly. No count moved.

---

## Measured and REJECTED -- do not retry

* **A replica two cycles behind `ns_r`.** Measured, FAILS immediately with the
  capture above. There is exactly one cycle of lead in `S_EMIT` and it is fully
  spent by the single replica stage. **Do not add a second stage to `ns_rep`**,
  and do not "improve" the fix by pipelining the emit shift into two register
  levels without also moving `rd_v`: the first `S_EMIT` cycle is the entire
  budget.
* **Gating the replica update on `st = S_EMIT`.** Rejected by construction and
  worth naming because it is the obvious-looking tidy-up. A gated replica tracks
  `ns_r` only while the gate is true, and the one cycle where they must already
  agree is the cycle the gate turns on. The update is unconditional on purpose.

### Rejected by reasoning, NOT measured -- no Vivado was run

Flagged separately because they carry less weight than the section above.

* **Hoisting the rounding bias out of the lanes.** `round_shift` computes
  `shift_left(to_signed(1, 33), sh - 1)`, a 33-bit one-hot decoded from `sh`.
  Computing it once centrally and broadcasting it would replace a 6-bit
  broadcast with a 33-bit one, which is the defect this change exists to remove.
  Per-lane decode is correct here.
* **Replicating `tap_ns` and `y_exp` too.** Both are single-sink and off the
  failing path, so replication buys nothing, and a control value that is one
  cycle late in one consumer and current in another is precisely the silent
  defect class this project keeps hitting. They stay on the master. Note that
  moving them to a replica would very likely still PASS the suite, since `ns_r`
  is constant across the whole of `S_EMIT` -- which is the reason to decide it
  on structure rather than on a green run.
* **MREG/PREG and the DSP-to-DSP cascade hop.** Explicitly out of scope: those
  are remedies for logic-bound paths and this path is 54.5% route. Named here
  only so nobody arrives from the `rmsnorm_bf` and Newton-rsqrt work and applies
  them by pattern match.

---

## Measurement traps hit

* **`sim/regress.sh` analyses `$REPO/<file>` in place, not a copy.** Editing any
  `rtl/*.vhd` while a run is in progress kills that run with `file ... has
  changed and must be reanalysed`, minutes in, with no partial results. The
  scratch tree it makes holds the GHDL library and symlinks to the vectors, not
  the sources. Finish the edits, then start the run. (The script's own header
  warns about editing *itself* mid-run, for a different reason -- bash reads by
  byte offset. Both are real and they are separate hazards.)
* **The brief's range for `ns` was 0..49; the true range is 0..21.** Both fit in
  six bits so the fix is unaffected, but a declared bound is a hard assertion in
  simulation: had the real range been wider than the declaration, this would
  have surfaced as a range-check failure and not as a timing result.
* **A fanout fix cannot be verified by a passing testbench.** Every version of
  this change that keeps the value correct passes, including the ones that do
  nothing useful. The only evidence that the replicas will survive to placement
  is the DONT_TOUCH attribute, and the only evidence that the lead exists is the
  deliberate break above.

---

## Open, not yet answered

* **No Vivado, so no Fmax and no utilisation.** Two A runs at `ROWS_IF` 48 and
  32 were using the box; the measurement is handed over.
* **Attribution between the two fixes is set up but not performed.** To measure
  the narrowing alone, change `ns_rep(rr)` back to `ns_r` at the single marked
  line in `S_EMIT` and change nothing else. The comment at that line says so.
* **The logic term is the next path and it is already close.** 2.543 ns of
  shifter logic against a 3.300 ns constraint leaves 0.550 ns for routing even
  in the best case. If the narrowing does not shrink the shifter, this fix gets
  A to roughly the constraint and no further, and the next move is pipelining
  SITE 4's shift into two stages -- which DOES cost a cycle, and which the
  one-cycle `S_EMIT` lead measured above will not pay for.
