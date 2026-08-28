# attn_twiddle and attn_rope: four defects that all hid behind a check that could not move

Date: 2026-08-27
Branch: `fpga`
Subsystem: C, gated attention -- step 3 (IMROPE), sites R1 and R2
Units: `rtl/attn_twiddle.vhd`, `rtl/attn_rope.vhd`, and their C references
Environment: GHDL mcode, `--std=08 -frelaxed`. No Vivado was run.

## The question

Building subsystem C's step 3 -- `attn_twiddle` (the stateless sin/cos
generator) and `attn_rope` (the NEOX-paired rotation) -- four separate things
went wrong, and every one of them shares a shape:

1. `attn_twiddle` produced cosines and sines wrong by **120 to 210 counts out
   of 32767** immediately after `DLT_W` was narrowed from 17 bits to 9. Before
   the narrowing the unit was bit-exact.
2. Mutation `N12`, which changed how `DLT_W` was derived, **survived every
   handshake configuration** while the width was 17.
3. `attn_twiddle`'s reference ORACLE 4 reported error ratios of about
   **39,000** against a bound that ORACLE 3 -- checking the same angle --
   passed cleanly.
4. `attn_rope`'s reference ORACLE 1 failed **17 of 1,792 components by 1 to
   6%**, concentrated entirely on the largest outputs.

And in the RTL mutation runs, two mutations survived all three handshake
configurations: `P25` (done reduced to a pulse) and `P26` (a latched input read
live instead).

## The answer

**Numbers 1 and 2 are the same defect seen from two sides, and it is the
`numeric_std` narrowing trap for the third time in this subsystem -- but the
first time on the OPERANDS of an expression rather than on its result.**
`resize(a, DLT_W) - resize(b, DLT_W)` narrows both 16-bit operands to 9 bits
*before* subtracting, so the subtraction is performed on truncated inputs. The
fix is to form the difference at full width and take a **slice**. While
`DLT_W` was 17 the narrowing was a no-op, which is exactly why `N12` survived:
the width was **decorative**, and a constant that no behaviour depends on
cannot be mutated into a failure.

**Numbers 3 and 4 are both a missing scale factor in the ORACLE, not in the
code under test** -- a spurious `2*pi` in one and a missing `32767/32768` in
the other. Both were caught because a *second* oracle checking the same
quantity in different units disagreed with the first.

**`P25` and `P26` were gaps in the TESTBENCH, not equivalences.** Each
mutation's subject was **constant across every vector**: `done_ack` was always
pulsed, never tied high; `x_exp` never changed after the latch instant. This is
the coordinator's 2026-08-27 warning -- a guard whose subject is a constant is
a comment -- reproduced independently here.

Final position: `ref/attn_twiddle_vec.c` **15/15 killed**,
`rtl/attn_twiddle.vhd` **22/22 killed**, `ref/attn_rope_vec.c` **13/13
killed**, `rtl/attn_rope.vhd` **30/30 killed**, all with no survivors, and both
testbenches PASS in three handshake configurations. `attn_rope` is bit-exact on
2,688 elements per configuration -- 1,792 rotated and 896 passed through,
tallied separately so a boundary off-by-one cannot be absorbed by the other
region's count.

## The procedure that produced it

The order matters, because two of the four were found by a step that exists
only because an earlier unit was burned by skipping it.

1. **Write the C reference first and mutation-test it before any RTL exists.**
   This is what caught 3 and 4. Neither is a defect in a DUT -- there was no
   DUT yet. They are defects in the *check*, and the only window in which a
   check can be debugged in isolation is before the thing it checks exists.
2. **Give every derived quantity a second, independent derivation.**
   `attn_twiddle`'s ORACLE 3 measures the phase in **turns**; ORACLE 4 measures
   the same angle in **radians** against libm. They cannot both be wrong in the
   same direction by accident. ORACLE 3 passing while ORACLE 4 read 39,000 is
   what localised the `2*pi` to the oracle rather than the unit.
3. **Derive widths from the DATA, not from the operands' declared range.**
   `DLT_W` was originally `Q_W + 1` = 17, which is the worst case for a
   difference of two s16 values in the abstract. Re-deriving it from the actual
   `SIN_TBL` -- the largest step between adjacent entries -- gives 9. That
   change is what turned a decorative constant into a load-bearing one, and it
   immediately exposed defect 1.
4. **Mutate the derivation itself, not only the value.** `N12` targets the
   function that computes `DLT_W`. A mutation that changes a width and produces
   no failure is a direct statement that nothing reads that width.
5. **Run three handshake configurations, and read every survivor rather than
   assuming it is equivalent.** Both `P25` and `P26` were read and found to be
   real behavioural changes that the stimulus could not distinguish.
6. **Ask of each survivor: what value does its subject take across the
   vectors?** For `P26` the answer was "one value, for the whole job". That
   answer is the defect.

## The evidence

### Defect 1 -- the narrowing, verbatim

Before, bit-exact with a decorative width:

```vhdl
constant DLT_W : integer := Q_W + 1;                    -- 17
s6_sd <= resize(s5_shi, DLT_W) - resize(s5_slo, DLT_W);
```

After narrowing `DLT_W` to 9, the same line, unchanged, produced:

```
sim/tb_attn_twiddle.vhd:...:(report error): COS: case 3 j 7 got 30119 want 30263
sim/tb_attn_twiddle.vhd:...:(report error): SIN: case 3 j 7 got 12652 want 12841
```

Errors of 144 and 189 counts. The fix forms the difference at full width and
takes a slice, with an assertion that the slice is lossless:

```vhdl
sd_v := resize(s5_shi, Q_W+1) - resize(s5_slo, Q_W+1);
if STRICT_PRODUCER then
  assert sd_v = resize(sd_v(DLT_W-1 downto 0), Q_W+1)
    report "attn_twiddle: a SIN_TBL step does not fit DLT_W bits. ..."
    severity error;
end if;
s6_sd <= sd_v(DLT_W-1 downto 0);
```

This is the **third** appearance of this trap in subsystem C. The first two
were on the RESULT of an expression, where the habit of reading
`resize(x, N)` as "make this N bits wide" is at least locally true. Here it is
on the OPERANDS, where `resize` runs *before* the operator and the declared
result width is never consulted at all.

### Defect 2 -- the decorative width, as a mutation result

With `DLT_W = Q_W + 1`:

```
N12  SURVIVED EVERY CONFIG   -- the delta width is derived from the operands
```

With `DLT_W` derived from `SIN_TBL`:

```
N12  KILLED by: A B C   survived: -   -- the delta width is derived from the operands
      [A shipped: tw_ready period 3, done ack lag 4]
        (report error): SIN: case 0 j 3 got 4106 want 4107
```

The mutation is textually identical in both runs. Only the surrounding code's
dependence on the value changed.

### Defect 3 -- the spurious 2*pi in the twiddle oracle

```c
/* WRONG: this is 2*pi times the angle, not the angle */
double true_th = 2.0 * M_PI * pos * pow(BASE, -(double)j / npair);
```

produced

```
  oracle 4  worst |s - 32767*sin(theta)| / derived bound: 39118.4  (case 6, j 0)
  oracle 3  worst |phi/2^32 - frac(true turns)| / derived bound: 0.4013
```

ORACLE 3 measures the same angle in turns and passes at 0.40 of its bound.
Two oracles over one quantity disagreeing by four orders of magnitude locates
the fault in the one that moved. After removing the factor:

```
  oracle 4  worst |s - 32767*sin(theta)| / derived bound: 0.7440
```

### Defect 4 -- the missing Q15 scale in the rope oracle

```
  oracle 1  worst |y - true rotation| / derived bound: 1.0614  (case 23)
  17 of 1792 components outside the bound, all with |y| > 20000
```

The failures being concentrated on large outputs is the signature of a
*multiplicative* discrepancy, not an additive one. The cause: Q15 encodes 1.0
as 32767, not 32768, so the twiddle is a rotation shrunk by exactly
`1 - 2^-15`. The oracle's target was the unshrunk rotation.

Fixed by scaling the TARGET, which is the tighter of the two available fixes --
widening the bound would have hidden any real defect of the same size:

```c
double qs = 32767.0 / 32768.0;
double t0 = qs * (x0 * cos(th) - x1 * sin(th));
```

and correspondingly in ORACLE 2, whose norm target becomes `qs*qs*|x|^2`.
Result:

```
  oracle 1  worst |y - true rotation| / derived bound: 0.9350 (case 23)
  oracle 2  worst | |y|^2 - |x|^2 | / derived: 0.6976
```

### The two survivors, and why the stimulus could not see them

```
P25  SURVIVED EVERY CONFIG   -- done is a PULSE instead of held (RULE 1)
P26  SURVIVED EVERY CONFIG   -- the exponent is read LIVE at publish
                                instead of from its latch (RULE 2)
```

`P25` inserts `done_r <= '0';` inside the `done_ack = '1'` branch. That is a
LATER assignment than the `done_r <= '1'` above it, so it wins -- and with
`done_ack` **tied high**, which is the port's own default, `done` never rises
at all. With a *pulsed* ack, `done` has already been high for many cycles
before the ack arrives, so the mutation only shortens it by one cycle and
nothing notices. The testbench pulsed the ack in all three configurations.

`P26` swaps `exp_l` (the latched copy) for `x_exp` (the live port). The
testbench set `x_exp` once per case and held it for the whole job, so the two
expressions were **the same value at every instant of the simulation**.

Both fixes are to the stimulus. The degenerate configuration now ties
`done_ack` high along with every other ack, and `x_exp` is poisoned with a
value no case uses the moment `start` falls:

```vhdl
start <= '1'; cyc(1); start <= '0';
x_exp <= to_signed(-64, 8);      -- RULE 2 is only testable if the input MOVES
```

After both fixes, `P26` is killed by all three configurations -- and `P25` is
killed by **exactly one**:

```
P25  KILLED by: B    survived: A C  -- done is a PULSE instead of held (RULE 1)
P26  KILLED by: A B C survived: -   -- the exponent is read LIVE at publish
```

`P25` is the sharpest measurement in this file. The configuration that stalls
nothing, offers everything immediately and acks everything instantly -- the one
that looks like the weakest of the three -- is the **only** one that catches a
deleted completion signal. The two configurations with real back-pressure both
miss it. Set against `P23`, `P24`, `P28` and `P29`, which are killed by A and C
and survive B, the three configurations are strictly complementary: neither the
stalling nor the non-stalling shape is a superset of the other.

### A fifth, found by inspection rather than by test

`attn_rope`'s pass-through phase derived its output index as `ri - 2`, tracking
the memory's two-cycle latency. `ri` **stops incrementing** at `HEAD_DIM` while
the final two reads are still in flight, so the last two elements would both
have been labelled `HEAD_DIM-2`. Replaced with a real counter, `pi_o`. Recorded
because it is the same class as the four above -- an expression whose
correctness depended on a quantity still being able to move, at the exact point
where it stops.

### A sixth, found ONLY by the degenerate configuration

`attn_rope`'s out-of-step guard initially raised `err` for a twiddle offered in
any state other than `S_LOAD` or `S_IDLE`. It fired at **95 ns**, in `S_HDR`,
on entirely correct producer behaviour: a producer that HOLDS its first pair
from the moment it has one -- which is what RULE 1 requires -- is naturally
already asserting before this unit has walked from `S_HDR` into `S_LOAD`.

It is invisible in every configuration with a twiddle gap, because a gap of
even 3 cycles carries the producer past `S_HDR` before it asserts. Only the
configuration where the producer never stalls can reach it. Concrete evidence,
in this subsystem for the second time, that the degenerate handshake is not a
weaker test but a different one.

## Measured and REJECTED -- do not retry

- **Widening `attn_rope` ORACLE 1's bound to absorb the 1 to 6% error.**
  Rejected. The error is multiplicative and concentrated on large outputs; a
  bound wide enough to pass at `|y| = 32767` is 6% slack at every other
  magnitude, which is roughly 2,000 counts of blindness on a 16-bit output.
  The scale factor is exactly derivable, so the target was scaled instead.
- **Leaving `DLT_W` at `Q_W + 1` = 17 because it was bit-exact.** Rejected.
  It *was* bit-exact -- and `N12` proved the width was load-bearing on nothing.
  Narrowing it to the table-derived 9 both removes 8 bits x 2 registers per
  stage and makes the constant testable. Bit-exactness is not evidence that a
  constant is right; it is only evidence that it is not wrong in a way this
  stimulus reaches.
- **Treating `P25` and `P26` as equivalent mutants.** Rejected on reading.
  Both change real behaviour. `P25` deletes `done` entirely against the port's
  own default ack. Calling either equivalent would have shipped two live
  defects behind a 28/30 kill ratio.
- **Making `attn_rope` a generic wrapper around the existing `rtl/rope.vhd`.**
  Rejected before any code was written. `rope.vhd` already has a `NEOX` generic
  that selects the `(j, j+HALF)` pairing, so the temptation is real -- but it
  indexes a per-position twiddle ROM of `512 * HALF` entries, and at this
  geometry (`N_ROT` 64, positions to 40960) that ROM is not representable. It
  also rotates the *whole* vector, with no unrotated tail, and takes its input
  as one flat `DIM*16` bus rather than from a memory. The arithmetic kernel is
  deliberately identical; nothing else is.
- **Driving `attn_rope`'s twiddle port from `attn_twiddle` in the testbench.**
  Rejected. It is the obvious integration shortcut and it destroys the
  property that makes both units checkable: a defect in either could then mask
  a defect in the other. The twiddle port is driven from the golden file, and
  the two units are verified separately.

## Measurement traps hit, including my own

- **`cc ... | head -6` kills the compiler with SIGPIPE**, so no binary is
  produced while the pipeline still reports success -- the exit status is
  `head`'s. Cost one confusing run where an old binary was being re-executed.
  Do not pipe a compiler invocation whose success you intend to test.
- **`pkill -f <pattern>` matches the shell running the command.** Hit twice
  now, both times returning exit 144 and silently discarding everything else
  in that command -- including, on the second occasion, a `python3` heredoc
  that had not yet run. Kill by PID.
- **Editing a shell script while bash is executing it** shifts every byte after
  the interpreter's read cursor. A suite edited mid-run produced output that
  did not correspond to any version of the file.
- **`--stop-time=900ms` on a unit with a real pipeline.** A mutation that hangs
  runs to the stop time; at 900 ms that is ~90 million simulated cycles per hung
  configuration. The longest legitimate `attn_rope` run is 411 us, so the
  scripts here use 40 ms -- a 97x margin and a 22x reduction in the worst case.
- **A `ghdl -a` of the entity without re-analysing the testbench** leaves the
  architecture obsolete, and `ghdl -r` then reports
  `architecture "tb" ... is obsoleted by entity` rather than running. It looks
  like a failure of the run and is a failure of the build order.
- **My own cfg_taken monitor reported a defect that was entirely the
  monitor's.** `cfg_taken` is registered, so it lands the cycle *after*
  `start`; a per-job window that reset its counter on `start` raced its own
  increment and fired on all 28 cases. Counting globally and comparing the
  total against the job count is both correct and a stronger invariant, since
  it catches a missing pulse as well as a duplicated one.
- **`ghdl -e` produces no binary under the mcode backend and exits 0.** Run
  `ghdl -r <entity>` directly. A build script that gates on `ghdl -e`
  succeeding gates on nothing.

## A note on oracle non-redundancy, measured

The C-reference mutation suites are committed as
`sim/mutate_ref_attn_twiddle.sh` and `sim/mutate_ref_attn_rope.sh`, so the kill
ratios reported here are reproducible rather than remembered. Phase 1 ran its C
mutations ad hoc and committed no script; that is corrected here.

The more useful reading of those two runs is not the ratio but **which oracle
did the killing**. If one oracle caught everything, the rest would be
decoration:

| suite | oracle 1 | oracle 3 | oracle 4 | oracle 5 |
|---|---|---|---|---|
| `attn_twiddle`, 15 mutations | 4 | 5 | 2 | 4 |
| `attn_rope`, 13 mutations | 11 | 2 | -- | -- |

`attn_twiddle`'s four oracles are genuinely non-redundant: the table checks
(1), the phase check (3), the trig check (4) and the chord-direction check (5)
each own a region of the recipe that the others do not reach. `attn_rope` is
more concentrated -- ORACLE 1's derived per-component bound is strong enough to
catch eleven of thirteen -- but the two that ORACLE 3 catches alone are exactly
the ones ORACLE 1 structurally cannot see, because they move elements in the
UNROTATED region that ORACLE 1 never looks at. That is the argument for keeping
ORACLE 3 despite its apparently poor yield.

## Open, not yet answered

- **The DSP counts in both units are DERIVED from operand widths, not
  measured.** `attn_twiddle` is 4 tiles by the 27x18 rule (one 16x32 at two
  tiles, two 9x22 at one each); `attn_rope`'s kernel is 4 by the same rule.
  But the C spec's **measured** 2026-08-25 figure for `rope.vhd`, on
  arithmetic identical to `attn_rope`'s, is **8** -- Vivado spends two tiles
  per 16x16 product there. Whether the restaged form here maps to 4 or 8 is
  open and is the C DSP skeleton's own open item 4. No Vivado was run for
  either unit.
- **No Fmax claim is made for either unit.** Per
  `docs/debugging/2026-08-27_tuning-at-the-wrong-voltage.md`, the same netlist
  reads 305.4 MHz at 0.85 V and 232.2 MHz at 0.717 V, and the binding path
  changes identity between the two. The restaging here is justified by the
  project's structural timing rule -- never two of {barrel shift, wide add,
  wide compare, bus mux, multiply} in series in one stage -- and by the C
  spec's measured 206.4 MHz for the unstaged `rope.vhd`, not by a number of
  my own.
- **Whether `DLT_W = 9` is reachable in the worst case is asserted, not
  proved.** The `STRICT_PRODUCER` assertion checks every step of the table the
  unit actually holds. A different `TBL` or `QMAX` would need the width
  re-derived, which `sin_delta_w` does automatically -- but nothing yet tests
  the unit at a second table size.
