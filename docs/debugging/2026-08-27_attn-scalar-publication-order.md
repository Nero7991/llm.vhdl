# Subsystem C and the scalar-publication-order rule: `attn_softmax` is clean, and the guard that proves it

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. GHDL 1.0.0 mcode backend, `ghdl -r`
direct, no `ghdl -e` (mcode produces no binary and `-e` silently succeeds).
**Units:** `rtl/attn_softmax.vhd` (audited), `rtl/attn_gate.vhd` and
`rtl/attn_emit.vhd` (new, designed against the rule).

Companion to `docs/debugging/2026-08-27_gdn-conv-eseg-published-late.md`, which
records the defect in subsystem B that produced the rule.

## The question

Verbatim, from the subsystem B agent on 2026-08-27:

> `attn_softmax` -- **OPEN, and it is yours to settle.** `rescale_n <= nrs_r`
> is a continuous assignment from a register. Whether it is correct depends on
> when `nrs_r` is written relative to `rs_v_r` rising, which cannot be read off
> the port map.
>
> 1. Settle `attn_softmax`'s `rescale_n`. If `nrs_r` is written in the same
>    state that raises `rs_v_r`, or later, that is the same defect and it needs
>    the same fix.
> 2. Whether or not it is defective, add the ordering guard to
>    `sim/tb_attn_softmax.vhd` [...] capture the scalar at the FIRST valid beat,
>    and assert it already equals the value at `done`.
> 3. **Verify the guard has teeth by running it against a deliberately broken
>    copy** where the scalar is assigned late.
> 4. Apply the same rule to whatever new units you are building now, at design
>    time.

The rule under test: *a scalar that qualifies a stream must be assigned in a
state STRICTLY EARLIER than the state that first raises that stream's valid,
and a testbench that samples it at `done` cannot tell you whether that holds.*

## The answer

**`attn_softmax`'s `rescale_n` is CLEAN, for two independent reasons, and the
first of them means the strict form of the rule does not even apply to it.**

1. `rescale_n` **qualifies nothing**. Nothing in this design is scaled by it;
   it is a diagnostic counter whose declared contract is the one written above
   its port -- `---- results, valid from done to the next start ----`, the same
   class as `s_out` and `m_out`. It reaches its final value at the last `S_F`,
   many cycles before `S_DONE`.
2. Even read as a per-beat qualifier, it is not late. `nrs_r <= nrs_r + 1` and
   `rs_v_r <= '1'` are **both assigned in `S_F`**, so they land on the same
   clock edge and the count already includes the event in the first cycle the
   offer is visible.

The guard was added anyway (item 2), in the form this signal can answer, and it
was shown to have teeth (item 3). The rule was applied at design time to both
new units (item 4).

## The procedure that produced it

1. **Read the assignment sites, not the port map.** `grep -n "nrs_r\|rs_v_r"`
   gives four sites; the only one that writes `nrs_r` outside reset is inside
   `when S_F =>`, four lines below `rs_v_r <= '1'` in the same branch.
2. **Ask what the signal QUALIFIES before asking when it is assigned.** This
   is the step that decides which form of the guard is even correct. `e_seg` in
   `gdn_conv` scales its segment's data; `rescale_n` scales nothing. The
   gdn_conv guard -- "capture at the first beat, assert it equals the value at
   done" -- is **wrong for a counter**, which must change during the stream. The
   guard here is the same question in the form the signal can answer: at the
   n-th offer, the count must already read n.
3. **Add the guard, and confirm the unmutated DUT passes in all three
   handshake configurations** before believing anything about a mutant.
4. **Break the DUT deliberately and confirm the guard is the ONLY thing that
   fires.** A guard that fires alongside twelve other checks has not been shown
   to be necessary.

## The evidence

Baseline, three configurations, guard in place:

```
--- -gACK_LAG=4 -gRS_ACK_LAG=9
tb_attn_softmax: PASS -- 44 heads bit-exact ...  ACK_LAG=4 RS_ACK_LAG=9
--- -gACK_LAG=0 -gRS_ACK_LAG=0
tb_attn_softmax: PASS -- 44 heads bit-exact ...  ACK_LAG=0 RS_ACK_LAG=0
--- -gACK_LAG=4 -gRS_ACK_LAG=3
tb_attn_softmax: PASS -- 44 heads bit-exact ...  ACK_LAG=4 RS_ACK_LAG=3
```

The deliberate break. `nrs_r <= nrs_r + 1` moved out of `S_F` and into the
`rs_tk = '1'` branch of `S_RS`, which executes exactly once per rescale -- so
the TOTAL at `done` is still exactly right and only the publication instant
moves:

```
tb_attn_softmax.vhd:231:13:@265ns:(report error): ORDERING: rescale_n reads
  0000000000000000 at the instant rescale pass 1 is first offered on rs_valid;
  it must already read 1. ...
tb_attn_softmax.vhd:231:13:@545ns:(report error): ORDERING: rescale_n reads
  0000000000000001 at the instant rescale pass 2 is first offered ...
tb_attn_softmax.vhd:231:13:@825ns: ... pass 3 ...
tb_attn_softmax.vhd:231:13:@1145ns: ... pass 4 ...

--- count of non-ORDERING errors:
0
```

**Zero.** Over 44 heads, 76 rescale passes, every `e_p`, every rescale factor,
`s`, `m` and the final `rescale_n` -- nothing else in the file notices. That is
the whole point of the guard and it is why the gdn_conv defect survived a
bit-exact double-oracle check over 128 cases.

Note the guard fires from the FIRST offer, at 265 ns. An earlier version of the
break, which moved the increment into `S_ZED`, first fired at pass 4 -- see the
traps below.

## Applying the rule at design time to the two new units

Both were written against the rule rather than audited afterwards.

| Unit | Scalar | Assigned | First beat of the stream it qualifies | Separation |
|---|---|---|---|---|
| `attn_gate` | `p`, `r`, `qg_exp` | latched in `S_IDLE`, derived in `S_CFG1..S_CFG3` | `x_ready` cannot rise before `S_RUN` | 4 states |
| `attn_emit` | `y_exp` (+ `hdr_valid`) | `S_HDR` | `m_valid` cannot rise until 6 cycles into `S_EMIT` | 7 cycles |

Both carry a `STRICT_PRODUCER` assertion for it, and both testbenches carry an
`ord_chk` process. **Both guards were then shown to have teeth by mutation**,
which is the same demand item 3 makes:

- `attn_gate` mutation M19 (`cfg_taken` never published) is killed in all three
  configurations by `ord_chk`, message
  `ORDERING: an element was accepted before cfg_taken pulsed. p_in reads 00001,
  r_in reads 0000000000000001, qg_exp reads 10...`.
- `attn_emit` mutation E15 (`y_exp` published in `S_DONE` instead of `S_HDR` --
  the gdn_conv shape exactly) is killed in all three configurations.
- `attn_emit` mutation E16 (`hdr_valid` raised at `start`, before the scan pass
  has produced an exponent) **SURVIVED the first version of the guard** and is
  what forced the second capture point below.

## Measured and REJECTED -- do not retry

- **"Capture the scalar at the first beat and assert it equals the value at
  `done`" -- applied verbatim to `rescale_n`.** It is wrong for a COUNTER:
  `rescale_n` legitimately changes on every rescale, so a constancy check
  either fires on correct behaviour or has to be weakened to vacuity. The
  ordering question has to be re-expressed per signal. Only the *shape* of the
  gdn_conv guard transfers, not its predicate.
- **Moving the increment to `S_ZED` as the deliberate break.** `S_ZED` is on
  the main path for EVERY score, not only after a rescale, so the mutant
  OVERCOUNTS rather than publishing late. The guard fired -- at pass 4, with
  readings 5, 6, 8, 9 against expected 4, 5, 6, 7 -- but it fired for the wrong
  reason and would have made a false claim about what the guard catches. The
  faithful break must leave the total correct: `S_RS`'s `rs_tk = '1'` branch.
- **Capturing `y_exp` only at the first mantissa beat in `attn_emit`.**
  Mutation E16 raises `hdr_valid` at `start`, before the scan pass has produced
  an exponent. `y_exp` itself is still published in time, so the first-beat
  capture is correct and the mutation SURVIVED all three configurations -- while
  the flag that *announces* the exponent had become a lie for the entire scan
  pass, and a consumer that latched on its rising edge would take the previous
  layer's value. Fixed by capturing at the RISING EDGE of `hdr_valid` as well;
  E16 is then killed in all three. **A validity flag and the value it qualifies
  are two claims and need two capture points.**

## Measurement traps hit, including my own

- **`mon_err` already had a driver.** VHDL allows exactly one process to drive
  an unresolved signal, and `tb_attn_softmax`'s `mon` process owns `mon_err`.
  Adding the guard as a second driver elaborates cleanly and then dies at run
  time with `error: several sources for unresolved signal` and **no file, line
  or signal name**. It reads like a corrupted work library. Fixed with a
  separate `ord_err` counter folded into the final tally.
- **`to_string`, not `integer'image(to_integer(...))`.** Flagged by the B agent
  and it is correct: on a DUT with the defect the scalar can still be
  metavalued at the first beat, and `to_integer` then raises INSIDE the report
  expression, so the run dies at `numeric_std-body.vhdl` with no message at
  all. Both new guards use `to_string`.
- **A guard added after a fix is worthless unless it is shown to fail before
  it.** Both new units' guards are exercised by a mutation in their own
  mutation script rather than by argument (`M19`, `E15`, `E16`).

## Open, not yet answered

- **The audit covered `rescale_n` only.** `attn_softmax` also publishes `s_out`
  and `m_out` under the same "valid from done to the next start" contract.
  Neither qualifies a stream either, and both are checked at `done` by the
  existing testbench, but neither has an ordering guard and neither was swept
  the way `rescale_n` was.
- **`attn_score_q12`'s `s_exp` was confirmed clean by the B agent** and is not
  re-checked here. It is `to_signed(QOUT, EXP_W)`, a compile-time constant.
- **No Vivado.** Nothing here is a routed result; the guard is a simulation
  construct and synthesizes to nothing.
