# The GDN emit chain does not connect: what glue is missing

**Date:** 2026-08-26
**Units:** `gdn_head_emit` -> `rmsnorm_bf` -> `gdn_silu` -> `gdn_y_emit`

## The question

> Sites 12 and 13, the B-only output norm, and the z gate are all built and
> bit-exact. `docs/superpowers/specs/...` section 3.6's status block says the
> handshakes are "compatible BY INSPECTION, which is not the same as tested".
> Are they actually compatible?

## The answer

**No.** Three of the four seams need glue that does not exist, and one of them
is a whole sequencer rather than wires. The phrase "compatible by inspection"
was too generous and is withdrawn.

The arithmetic is not at risk here -- every unit is bit-exact against a
double-oracled reference. What is missing is entirely structural.

## The four seams, checked against the actual port lists

| # | seam | status |
|---|---|---|
| 1 | `gdn_head_emit` -> `rmsnorm_bf` | **works**, with two caveats |
| 2 | `rmsnorm_bf` -> `gdn_y_emit.in_o` | **BROKEN**: parallel bus into a serial port |
| 3 | `gdn_silu` -> `gdn_y_emit.in_z` | **BROKEN** unless `LANES = 1` |
| 4 | the `in_e` exponent input | **MISSING**: nothing computes it |

### Seam 1 works, with two caveats

`gdn_head_emit.o_mant` is `std_logic_vector(DIM*16-1 downto 0)` and
`rmsnorm_bf.x_mant` is `std_logic_vector(N*16-1 downto 0)`. Same shape.
`done` -> `start` is a one-cycle pulse handshake and lines up.

- `o_e_head` is `signed(7 downto 0)`; `x_exp` is `integer`. A conversion is
  needed. This is permitted -- the v1.0-silicon rule bans routing DATA through
  a VHDL `integer` but excepts "exponents and descriptor fields" -- so it is a
  conversion, not a violation.
- `rmsnorm_bf` also needs `w_mant`/`w_exp`, the per-layer `ssm_norm[128]` and
  its exponent. Those come from the constant store, not from this chain.

### Seam 2 is broken: bus into a serial port

`rmsnorm_bf.o_mant` presents all `N` elements in parallel with `done`.
`gdn_y_emit.in_o` takes **one element per cycle**. A serializer is required.
There is no such unit.

### Seam 3 is broken unless the gate runs one lane wide

`gdn_silu` is a `LANES`-wide stream (`s_data`/`o_data` are `LANES*16` bits);
`gdn_y_emit.in_z` takes one element per cycle. At `LANES = 1` they match. At
the measured configuration `LANES = 32` they do not, and a width adapter is
needed.

Note the tension: `gdn_silu` was built wide precisely because section 3.2 says
the nonlinearities dominate the sweep and silu "must be pipelined ~1/cycle,
not the 3-cycle FSM rate". Narrowing it to 1 lane to match `gdn_y_emit` would
give that back. The right fix is a width adapter, or widening `gdn_y_emit`'s
input, NOT narrowing the gate -- but that is a decision, not an oversight, and
it has not been made.

### Seam 4 is missing entirely

`gdn_y_emit.in_e` is documented as `o_exp + z_exp` for the head. Nothing
computes it:

- `rmsnorm_bf.o_exp` supplies `o_exp` (an `integer`, needs narrowing to
  `signed(7 downto 0)` with a range check).
- `gdn_silu` **has no exponent port at all**, which is correct -- section
  2.1.2 says silu's exponent is PRESERVED -- so `z_exp` is whatever exponent
  fed the gate, and it must be carried around the gate by the caller.

So `in_e` needs an adder plus a path that routes `z_exp` past a unit that
deliberately does not carry it.

## What is actually needed: a sequencer, not wires

Beyond the three seams, the chain has a control problem. `gdn_head_emit` and
`rmsnorm_bf` operate on ONE head at a time. `gdn_y_emit` accumulates across
**all 24** heads and only then folds them to `y_exp`. So the missing component
must, per GDN block:

1. for `h` in 0 .. 23: run `gdn_head_emit` on head `h`'s 128 column results,
   then pulse `rmsnorm_bf`, then stream the 128 results and the 128 gate
   values into `gdn_y_emit` with `in_hfirst` on the first and
   `in_e = o_exp(h) + z_exp(h)`;
2. wait for `gdn_y_emit.done` and hand `y_exp` plus the 3,072-element stream
   to `ssm_out`.

That is a real unit with its own testbench, not a wiring diagram.

## Measured and REJECTED -- do not retry

- **Nothing yet.** This document records a gap found by reading port lists, not
  a hypothesis tested and killed. Recording that honestly matters: everything
  below the line here is unverified design intent.

## Measurement traps hit

- **"Compatible by inspection" was written into the spec's status block by me,
  a few hours before checking.** The inspection that produced it compared
  concepts (a norm feeds a gate feeds a fold) rather than port lists. Three of
  four seams fail on the port lists. When a status note says "by inspection",
  treat it as "not checked".

## Open, not yet answered

- **Whether to widen `gdn_y_emit`'s input or adapt `gdn_silu`'s width.** This
  is a schedule decision and interacts with section 3.2's claim that the
  nonlinearities dominate the sweep.
- **Where `z` comes from.** The gate input `z_h` is an A-job output with its
  own exponent; this chain assumes it is already resident, which the phase
  schedule has not established.
- **Whether `rmsnorm_bf` at `LANES = 4` is fast enough** to run 24 times per
  block per token without becoming the bottleneck. Its element loop is `3N`
  at `N = 128`, so ~96 cycles per head at 4 lanes plus ~30 fixed, times 24
  heads, times 48 layers. That arithmetic has not been done against the
  589,824-cycle sweep.
- **The `o_sat` outputs of both emit units are still unconsumed.**
