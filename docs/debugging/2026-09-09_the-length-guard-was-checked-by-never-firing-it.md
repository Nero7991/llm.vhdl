# The AXI3 length guard was "verified" by never firing it

**Date:** 2026-09-09
**Tree:** `llama.vhdl` branch `fpga`, at `8abe9f7`
**Files:** `rtl/bc_port_grant.vhd` (unchanged), `sim/tb_bc_port_grant.vhd`
**Tool:** `ghdl-mcode`, `--std=08`, `--stop-time=500us`

## The question

Verbatim from the open-issues list carried into this session:

> The `err_len_ovf` 16-beat threshold is unexercised (only its plumbing was
> teeth-tested).

Does `bc_port_grant`'s AXI3 length guard actually discriminate at the 16-beat
boundary, and does the bench that claims to cover it discriminate at all?

## The answer

**It did not test the threshold, and six separate defects in the guard would
all have passed.** `err_len_ovf` appeared in the verdict only as a term
requiring it to stay `'0'`, and the bench's own traffic never presents a burst
longer than 4 beats. That term is satisfied identically by the correct guard,
by a guard tied to `'0'`, by a guard reading the wrong bits, and by a guard
that ignores `c_arvalid`.

A directed phase on a second DUT instance now drives each of the five sources
that reach the guard at 15, 16 and 32 beats and checks the sticky bit after
withdrawal. 17 checks. Six mutants, all killed. The guard itself was correct;
the RTL needed no change.

## The procedure

1. **Read what the bench actually drives**, rather than what its verdict
   mentions. `grep -n 'arlen\|awlen'` on the bench: every length driven is
   `x"00"`, `x"01"`, `x"02"` or `x"03"`. The maximum is 4 beats against a
   16-beat cap, so the guard is never presented with anything it should catch.

2. **Confirm the guard is reachable independently of the arbiter**, so a
   directed test does not have to win a grant first. `rtl/bc_port_grant.vhd`
   lines 243-262: `errlen_p` is gated on `clk` and `rstn` only, and tests the
   `valid` lines directly. No grant needed, and no handshake needed either --
   it fires on the cycle a length is *presented*.

3. **Use a SECOND DUT instance, not a phase on the existing one.** `b_arlen`
   and `c_arlen` already have drivers in `bmast`/`cmast`. A signal cannot be
   driven from two processes, so a directed phase on the main instance is not
   expressible without disturbing the traffic that the rest of the bench
   depends on. The second instance costs nothing and keeps the 8494 existing
   checks byte-identical.

4. **Drive each source alone, from its own reset.** Five sources reach the
   guard: B's read, B's write, C's write, and each of C's two reads, which
   live in one flattened 16-bit vector. Resetting between cases makes a firing
   attributable to the source under test rather than to whichever ran first --
   the guard is sticky, so without the reset the first fire would mask all
   later ones.

5. **Put a decoy on the other half of the flattened vector.** In the `c_ar0
   len=15` case the *high* byte carries 16 with its own valid low. A guard
   that ignores `c_arvalid` and tests the whole vector fires on the decoy.
   This is what catches M4, and nothing else in the phase does.

6. **Run the attribution control**: for each mutant, check whether any
   pre-existing verdict term also fails. All of them are printed on the RESULT
   line, so this is free.

7. **Probe the resolution floor with a mutant designed to slip through**, and
   only then decide whether to close it.

## The evidence

Clean run, and the six mutants, all at 17 checks:

```
CLEAN:           PASS -- checks=8494 misdeliveries=0 switches=7619 reads=5142 writes=3352 p0rd=3352 p0wr=1790 p1rd=1790 p1wr=1562 err_switch_busy='0' err_len_ovf='0' lenguard_checks=17 lenguard_fail=0
M1_tied_low:     FAIL -- ... lenguard_checks=17 lenguard_fail=11
M2_thresh_32:    FAIL -- ... lenguard_checks=17 lenguard_fail=3
M3_offby8:       FAIL -- ... lenguard_checks=17 lenguard_fail=4
M4_ignore_valid: FAIL -- ... lenguard_checks=17 lenguard_fail=2
M5_not_sticky:   FAIL -- ... lenguard_checks=17 lenguard_fail=1
M6_only_bit4:    FAIL -- ... lenguard_checks=17 lenguard_fail=6
```

The elided fields are identical in all seven runs:
`misdeliveries=0 switches=7619 reads=5142 writes=3352 p0rd=3352 p0wr=1790
p1rd=1790 p1wr=1562 err_switch_busy='0' err_len_ovf='0'`.

**That identity IS the attribution control.** Every term the old verdict tested
holds in all six mutants, so the old bench returns PASS on all six. The new
phase is the sole detector for every one, and the counters being unchanged also
shows the added instance perturbs nothing.

### Each mutant fails for its own reason, not by a blanket effect

The fail counts are distinct, and each is derivable in advance. This is the
check that the kills are real rather than one broken thing knocking everything
over:

| mutant | what it does | predicted failing cases | count |
|---|---|---|---|
| M1 | `errlen_r` never set | all 10 must-fire cases + sticky | 11 |
| M2 | tests `7 downto MLEN_W+1` | the three len=16 cases on B ar/aw and C aw; their len=32 cases still fire (bit 5) | 3 |
| M3 | port 1 reads port 0's byte | `c_ar1` at 15 (false fire), 16 and 32 (missed), + sticky | 4 |
| M4 | `c_arvalid` ignored | both `len=15` C-read cases fire on the decoy | 2 |
| M5 | not sticky | only `sticky after withdraw` | 1 |
| M6 | tests `axlen(MLEN_W)` only | all five len=32 cases + sticky | 6 |

## Measured and REJECTED -- do not retry

- **A 15/16 boundary pair alone is NOT sufficient, MEASURED.** The first
  version of this phase had 12 checks using only 15 and 16. **M6 passed it**
  with `lenguard_fail=0`. A guard written `axlen(MLEN_W) = '1'` instead of as a
  test of the whole upper nibble catches 16 through 31 and passes 32 and above
  silently, and no 15/16 pair can see that. Do not trim the 32-beat cases back
  out as redundant: they were added to close a floor that had been
  demonstrated, and removing them restores a hole with a named mutant in it.

- **Adding the phase to the existing DUT instance -- rejected, not
  expressible.** `b_arlen`/`c_arlen` already have drivers. Any version of this
  that reuses the main instance has to either take those drivers over (killing
  the 8494 traffic checks) or add a mode signal to the traffic generators
  (changing the thing under test to accommodate the test). The second instance
  is cheaper and leaves the existing evidence untouched.

- **Testing through a granted burst -- unnecessary.** `errlen_p` does not
  depend on grant or on `ready`. Routing the directed lengths through the
  arbiter would have added an arbitration dependency to a test that has nothing
  to do with arbitration, and made each case's timing depend on the request
  pattern.

## Measurement traps hit

- **The absence of a firing looked like coverage.** `err_len_ovf='0'` on the
  RESULT line reads as evidence that the guard is behaving. It is evidence
  that nothing asked it to behave. This is the project's recorded "guards that
  pass for the wrong reason" class again: the check had never been shown to
  discriminate on the thing it guards, and the tell was available without
  running anything -- the maximum length the bench drives is 4.

- **The mutants had to be built from the GUARD, not from my description of
  it.** `mk.py` asserts its anchor text appears exactly once in the real RTL
  and that the substitution changed the file, so a mutant that silently failed
  to apply would raise rather than run and "pass". CLAUDE.md's recorded
  `seam_tieoff_teeth` failure is exactly a mutant built from the check's notion
  of the thing instead of from the thing.

- **M2's replacement is narrower than it looks.** `"7 downto MLEN_W"` does not
  occur inside `c_arlen(i*8+7 downto i*8+MLEN_W)`, so M2 mutates only the three
  non-flattened sources. That is why its count is 3 and not 5, and it is a
  property of the string substitution rather than of the mutation intended.
  Worth knowing before reading the count as "M2 misses two cases".

- **The RTL was never edited.** Every mutant is a copy under the session
  scratchpad, confirmed with `git diff --quiet -- rtl/bc_port_grant.vhd`. A
  card synthesis was running against that file at the time, so an in-place
  mutation would have silently changed what was being built.

## Open, not yet answered

- **`err_len_ovf` and `err_switch_busy` are still not wired to the host.** Both
  are sticky outputs of `bc_port_grant` that nothing reads. A guard that fires
  into a disconnected net is not observable on hardware, so all of the above
  establishes that the guard *works*, not that anyone would ever *hear* it.
  This is the more valuable remaining item of the two.

- **Neither requester is checked against its own compile-time 16-beat cap by
  this bench.** The guard's comment says `gdn_state_axi` and `attn_kv_axi` cap
  themselves at compile time and that the narrowing is therefore lossless. That
  is a property of two other files and is still taken on trust here.
