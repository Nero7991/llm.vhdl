# Subsystem B sites 12 and 13: the two block-floating emit stages

**Date:** 2026-08-26
**Units:** `rtl/gdn_head_emit.vhd` (site 12), `rtl/gdn_y_emit.vhd` (site 13)
**Part:** `xcvu33p-fsvh2104-2L-e`, 3.3 ns target, Vivado 2023.2

## The question

> `gdn_recur_pipe` emits the output dot as one `(o_acc, e_o)` pair per column,
> with a per-column exponent. `rmsnorm` takes a single `x_exp` for the whole
> vector, and `ssm_out` takes a single scale for the whole 24 x 128 block.
> What folds one onto the other, and what does it cost?

## The answer

Two units of the SAME shape at different granularities, because it is the same
problem twice: many per-block exponents, one consumer that wants a single grid.

```
site 12 (per head, over 128 columns)      site 13 (per block, over 24 heads)
  e_h     = min over j of e_o[j]            e_y_raw = min over h of e_p[h]
  o_al    = floor_shr(o_acc, e_o - e_h)     p_al    = floor_shr(p, e_p - e_y_raw)
  sh_h    = max(0, msb_pos(max|o_al|) - 14) sh      = max(0, msb_pos(max|p_al|) - 14)
  o_head  = sat16(round_shift(o_al, sh_h))  y       = sat16(round_shift(p_al, sh))
  e_head  = e_h - sh_h                      y_exp   = e_y_raw - sh
```

Both measured DSP-cheap and comfortably above B's 299.04 MHz:

| unit | config | DSP | LUT | FF | BRAM36 | fmax |
|---|---|---|---|---|---|---|
| `gdn_head_emit` | DIM=128 | **0** | 1199 | 2328 | 1.0 | 440.92 MHz |
| `gdn_y_emit` | HEADS=24, DIM=128 | **1** | 639 | 316 | 4.0 | 488.76 MHz |

One DSP between them, for the site-13 gated product, which is the whole
arithmetic cost of both emit stages. That matters because DSP is the binding
whole-die constraint at 90.5-91.9% of 2,880.

`gdn_y_emit` across head counts, since the single-card fallback needs 48:

```
RESULT HEADS=8  dsp=1 lut=622 ff=305 bram=1.0 wns=1.254 fmax=488.76
RESULT HEADS=24 dsp=1 lut=639 ff=316 bram=4.0 wns=1.254 fmax=488.76
RESULT HEADS=48 dsp=1 lut=666 ff=324 bram=6.5 wns=1.254 fmax=488.76
```

DSP and timing are flat in HEADS and only the product store grows, which is
what a scalar unit with one multiply and an N-entry buffer should do. The 4.0
BRAM36 at 24 heads is the predicted 98,304 bits (3,072 x 32) plus the
granularity of the primitive.

## The procedure

1. Read the normative recipe out of `ref/gdn_err.c` (stage 6, lines 514-523)
   rather than out of the spec prose. The prose is where the transcription
   errors live; see below.
2. Write the C generator with a DOUBLE ORACLE: the integer path the RTL must
   match, plus an independent evaluation in `double` from the real values the
   `(mant, exp)` pairs denote, sharing no helpers.
3. Write the testbench to assert bit-exactness with NO tolerance.
4. **Mutation-test the testbench.** A first-try pass is not evidence.
5. OOC for cost and clock, sweeping the dimension generic.

## Three findings, in order of how easily they would have shipped

### 1. The one-pass amax shortcut is FALSE for negatives

Both units look like they need only two passes, because

```
msb_pos(o_al[j]) = msb_pos(o_acc[j]) - (e_o[j] - e_h)
```

and `e_h` is a common additive term that drops out of an argmax -- so the amax
exponent looks computable during the CAPTURE pass, before any alignment.

It is false, and the counterexample is small:

```
v = -(2^k - 1),  shift 1
floor_shr(v, 1) = -2^(k-1)        msb = k - 1
msb_pos(|v|) - 1 = (k-1) - 1      = k - 2
```

`floor_shr` rounds toward minus infinity, so it can carry a negative magnitude
UP across a power of two. The shortcut under-shifts, and it under-shifts
exactly on the value that is about to saturate. Both vector files carry the
case deliberately (`shape 3` in site 12, `shape 4` in site 13).

**Do not re-derive this shortcut.** It is tempting every time.

### 2. Both error thresholds were too tight, and passing was luck of the seed

The generators checked the integer path against the double oracle with a
`> 0.5 LSB` failure threshold, reasoning that the requantize rounds and half an
LSB is the floor. That counts ONE of TWO error sources:

1. the alignment **FLOOR** loses up to `(2^shj - 1)/2^shj < 1` LSB of the
   ALIGNED grid, and one aligned LSB is `2^-sh` LSB of the OUTPUT grid;
2. the requantize rounds, `<= 0.5` output LSB, and **exactly 0 when `sh = 0`**
   because it is then a no-op.

So the bound is `< 2^-sh + 0.5*[sh > 0]`, which is `< 1.0` output LSB and
reaches it only in the limit.

Measured, with the generator instrumented to report the worst case's shape:

```
  worst error vs double oracle: 0.7500 LSB (case 4)
  worst case had shape 4, sh = 0, max alignment shift = 2
    shape 0 worst: 0.5000 LSB      shape 4 worst: 0.7500 LSB
    shape 1 worst: 0.0000 LSB      shape 5 worst: 0.5000 LSB
    shape 2 worst: 0.5000 LSB      shape 6 worst: 0.5000 LSB
    shape 3 worst: 0.0000 LSB
```

`sh = 0` means there was no requantize rounding at all: the entire 0.75 is the
alignment floor, 3/4 of an aligned LSB at a shift of 2. Nothing was wrong with
the recipe; the check was wrong.

`gdn_head_emit_vec.c` carried the identical 0.5 threshold and PASSED, because
its worst element happened to land at `shj = 0`. A different seed would have
failed it. Both are now `< 1.0` with the derivation in the source.

### 3. `o_last` arrived one cycle after the final `o_valid`

Site 13 streams its result, so it carries an `o_last`. The first version raised
it from the drain counter at the state transition. Tracing the drain by hand:

```
T+4  p5_v <= p4_v (=1)                  drain 3 -> 4
T+5  emit stage sees p5_v=1, o_valid_r <= 1   drain 4 -> 5
T+6  o_valid high; p5_v now 0; drain = DEPTH -> o_last_r <= 1
T+7  o_last high, o_valid LOW            <-- one cycle late
```

The last element reaches the emit stage at `drain = DEPTH-1`; the transition is
at `drain = DEPTH`. Fixed by carrying a last-flag down the pipeline beside the
valid flags.

**This was found by tracing, not by simulation**, and the testbench would not
have caught it as originally written: a consumer that only counts elements
never notices. The testbench now records `o_last` by INDEX and asserts it
coincides with element `NTOT-1`, so it notices on the consumer's behalf.

## Measured and REJECTED -- do not retry

- **The one-pass amax shortcut** (finding 1). Measured false by construction.
- **Leaving the RAM style to inference.** Unpinned, Vivado chose distributed
  RAM at DIM 64 and 128 (63 and 126 cells) and switched to a RAMB36 at
  DIM 256. An inference that changes primitive with a generic makes resource
  tables incomparable across configurations. Pinning to `block` cost nothing:
  LUT went DOWN 1248 -> 1199 and FF down 48, timing unchanged.

  ```
  unpinned   DIM=64   0 DSP  1253 LUT  1351 FF  0.0 BRAM  63 lutram  440.92 MHz
  unpinned   DIM=128  0 DSP  1248 LUT  2376 FF  0.0 BRAM 126 lutram  440.92 MHz
  unpinned   DIM=256  0 DSP  3430 LUT  4470 FF  1.0 BRAM   1 lutram  387.15 MHz
  pinned     DIM=64   0 DSP  1253 LUT  1303 FF  1.0 BRAM   1 lutram  440.92 MHz
  pinned     DIM=128  0 DSP  1199 LUT  2328 FF  1.0 BRAM   1 lutram  440.92 MHz
  pinned     DIM=256  0 DSP  3430 LUT  4470 FF  1.0 BRAM   1 lutram  387.15 MHz
  ```

- **Storing the per-head exponent alongside each product** in site 13. It would
  widen the RAM from 32 to 40 bits across 3,072 entries and remove only a
  HEADS-to-1 mux on 8 bits, which the read counters regenerate for free.

## Measurement traps hit

- **A mutation that is a near-no-op reads as testbench blindness.** A `sed`
  anchored with `;$` matched only ONE of the two alignment sites in site 13,
  because the other line carries a trailing comment. Mutating pass B alone only
  perturbs `amax`, and if `msb_pos(amax)` is unchanged the emitted values are
  identical -- so it "survived". Mutating BOTH sites is caught immediately.
  **Before concluding a testbench is blind, confirm the mutation actually
  changes the output.**
- **A first-try pass is not evidence.** Both units passed on the first run.
  Site 12's mutations (align rounds, `e_h` takes max, `sh_h` off by one) and
  site 13's (o_last from drain, `e_y_raw` takes max, align rounds at both
  sites, `sh` off by one, alignment skipped) are all caught, which is what
  makes the pass mean something.
- **An over-strict edit guard rejects a correct edit.** Three separate times
  today a Python edit guard failed on a landed edit: `count('KLO') >= 4` when
  the symbol occurs 3 times; `'2**37' not in s` when the replacement comment
  itself contains `2**37`; `'16-head renorm' not in s` when a dated correction
  note legitimately QUOTES the wrong phrase. Guard on `s != original` plus a
  check on the specific target, never on global absence.

## Cross-reference: the inclusive-versus-strict bound

Site 13's rounding-bias width bound is INCLUSIVE (`<= 2^30`) because int16's
asymmetric range makes `(-32768)^2 = 2^30` exactly attainable. Writing that
bound strict is the off-by-one that shipped in `rmsnorm_bf`'s sum-of-squares
assert on the same day and failed on legal input; see
`docs/debugging/2026-08-26_rmsnorm-magnitude-window.md`. Site 13's vectors
drive both operands at `-32768` (`shape 3`) to pin it, and site 12's assert was
re-derived and widened to inclusive for the same reason.

The general lesson, which cost two defects in one day: **derive the bound from
the type, do not transcribe it from prose.** Prose says `N * 32767^2`; the type
says `(-32768)^2`.

## A number I quoted that I could not check

Both unit headers originally stated the cost as a percentage of B's state
sweep ("~1.1%" and "~1.0%" of 589,824 cycles per token). That percentage is
withdrawn, because the denominator does not survive checking:

- Section 2.6 derives `cycles/layer = S*S*H / LANES = 262,144 / LANES` and
  quotes **589,824/token at LANES = 8**.
- Section 3.1's table quotes **589,824 at LANES = 32**.

Those cannot both hold. Worse, `262,144 = 128 * 128 * 16` uses **H = 16**,
which is the stale KEY head count. The state is per VALUE head, and there are
24 per card, giving `128 * 128 * 24 = 393,216`. This is the same 16-versus-24
confusion already corrected in two places in the spec, except that here it is
inside a CYCLE MODEL, where it understates the sweep by 1.5x.

The headers now quote cycles per head and per layer, which are measurable and
not in dispute: **~270 per head** for `gdn_head_emit` (so ~6,480 per layer at
24 heads) and **~6,150 per layer** for `gdn_y_emit`, which runs once per layer
across all heads rather than once per head.

The design conclusion is unaffected either way: both units are scalar because
their cost is small against every candidate value of the denominator.

## Open, not yet answered

- **Neither unit has been integrated.** Site 12's input is
  `gdn_recur_pipe.o_res_valid`, site 13's inputs are `rmsnorm_bf` and
  `gdn_silu` outputs, and no top-level wires them together. The handshakes are
  compatible by inspection, which is not the same as tested.
- **The 589,824-cycle sweep figure itself** needs resolving before any phase
  budget built on it can be trusted. See the section above.
- **The `o_sat` outputs are reported but nothing consumes them.** Saturation is
  not fatal but it means a head or block lost its top end, and no policy exists
  for what the engine should do when it fires.

## CORRECTION 2026-08-26 (later): both units silently dropped input

Found by the parallel spec audit (finding F2), confirmed here by measurement.
Both units, as first committed, were **single banked**: they spent their two
reduce passes not examining `in_valid` at all, and neither had a back-pressure
port.

```
gdn_head_emit, cycle probe on the correctness testbench:
  fill   128 cycles
  reduce 268 cycles      <- in_valid ignored for all of it
  total  396 per head
```

`gdn_recur_pipe` starts the next head immediately (its own head-boundary double
buffer measures 0 wait after any head of 16 columns or more), so the next
head's first ~67 column results would have been **silently dropped**. That is a
correctness bug at integration, not a throughput one, and nothing in either
unit would have reported it.

### The fix is TWO things, and a mutation run is what showed they are separate

This is the part worth keeping:

1. **`in_ready` fixes correctness.** Without it, columns are lost. With it, a
   producer that outruns the unit stalls.
2. **The second bank fixes throughput.** With a correct valid/ready handshake,
   a single-banked unit merely stalls the producer and **still returns the
   right answers**.

So collapsing the two banks back into one **passes every value comparison**.
It is visible only as cycles:

| unit | test | double buffered | banks collapsed |
|---|---|---|---|
| `gdn_head_emit` | 4 heads back-to-back | **1,202** | 1,586 |
| `gdn_y_emit` | 2 blocks back-to-back | **15,390** | 18,462 |

Both testbenches now carry a cycle bound set between the measured figures
(1,300 and 17,000). Without those bounds the double buffering is untested.

### Two protocol errors, both mine

- **`in_ready` was REGISTERED**, so it reported `pending` one cycle late and a
  producer sampling it could still hit a full bank. Now combinational, a
  2-to-1 mux on one bit.
- **The DUT accepted on `in_valid` alone and ASSERTED if the bank was full.**
  That gets the protocol backwards: holding valid while ready is low is
  precisely what a stalled producer does, so the assert fired on *correct*
  behaviour. Now a proper transfer on an edge where both are high.

### Measured cost, and neither prediction was right

| unit | before | after |
|---|---|---|
| `gdn_head_emit` | 1.0 BRAM36, 440.9 MHz | **1.0** BRAM36, **389.4** MHz |
| `gdn_y_emit` | 4.0 BRAM36, 488.8 MHz | **6.5** BRAM36, 488.8 MHz |

`gdn_head_emit`'s BRAM does not move at all: two banks of 128 x 48 is 12,288
bits and still fits one 36 Kb primitive. What it costs is clock, 440.9 to
389.4 MHz, from the combinational `in_ready` and the fill running every cycle
rather than as a state. Still 30% above B's 299.04 MHz.

`gdn_y_emit` goes 4.0 to 6.5, not the 8.0 a doubling predicts, because the
second bank packs into granularity the first was already wasting.

### Measurement traps hit, continued

- **A registered status output cannot be honoured by the thing it is telling.**
  The overlap test failed with an assertion inside the DUT, which read as a DUT
  bug; it was the handshake.
- **`ram_style = "block"` is not always accepted.** `gdn_exp_capture` got
  `WARNING: [Synth 8-6849] Infeasible attribute ram_style = "block" ... trying
  to implement using LUTRAM`, six times, for a 144 x 32 array. The pin was
  removed. An attribute the tool rejects is worse than none: it warns on every
  build and misdescribes where the storage lives.
- **Guarding an edit on the global absence of a string fails when the
  replacement quotes that string.** Three times in one night: `'KLO' >= 4` when
  the symbol occurs 3 times; `'2**37' not in s` when the new comment contains
  `2**37`; `'16-head renorm' not in s` when a correction note quotes the wrong
  phrase; and `'attribute ram_style' not in s` when the new comment quotes
  Vivado's warning verbatim. **Guard on `s != original` plus a structural check
  (is there still a DECLARATION?), never on global absence.**
