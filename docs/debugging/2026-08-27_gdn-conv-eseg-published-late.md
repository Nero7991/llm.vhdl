# gdn_conv published its segment exponent after the data that exponent describes

## 1. The question

2026-08-27, branch `fpga`, `rtl/gdn_conv.vhd` at commit `5750c37`, GHDL mcode
`--std=08`, no hardware involved.

While wiring subsystem B's top level (`rtl/gdn_block.vhd`), `gdn_conv` could not
be piped straight into `gdn_silu`. The question was why, stated as: **at what
time is `e_seg` valid, relative to the `o_valid` beats it applies to?**

The symptom that raised it is unusual in that there was no symptom. All three
existing `gdn_conv` testbenches passed, including a bit-exact comparison against
the C recipe on 128 cases with a worst error of 0.49999999999818 LSB against a
double oracle. Nothing was wrong with any value.

## 2. The answer

**`e_seg` was assigned in `S_FIN`, which is two states past the end of pass B,
so it was published AFTER every data beat it describes. A consumer that needs
the exponent for its first beat -- `gdn_silu` does -- therefore scaled each
segment by the PREVIOUS segment's exponent, with no error flag anywhere.** It is
now published at `S_SH`, where `e_ref`, `cw_r` and the shift are all already
known, which is three cycles before the first output beat.

The value was always correct. Only its time was wrong, which is exactly why
every existing check passed: all of them sample `e_seg` at or after `o_done`.

## 3. The procedure

1. **Read the state machine for the assignment site, not the value.** `e_seg`,
   `sh_seg` and `err_seg` were all written in `S_FIN`. `o_valid` is driven
   throughout `S_B`. `S_B` -> `S_BDR` -> `S_FIN` is at least two states, and
   `S_B` runs for `nbr` beats. So the exponent trails the data by the whole of
   pass B.
2. **Ask what each input of the assignment depends on, to find the earliest
   legal site.** `e_ref` and `cw_r` are both fixed at `S_PREP`. The shift is
   decided in `S_SH`. So `S_SH` is the earliest state at which the expression
   is computable at all, and it is upstream of every `o_valid`.
3. **Write the ordering property as a check, then verify the check has teeth by
   running it against the unfixed unit.** This is the step that matters. A guard
   added after a fix is worthless unless it is shown to fail before it.

## 4. The evidence

The property, added as `ord_chk` in `sim/tb_gdn_conv.vhd`: capture `e_seg` at
the first `o_valid` of a segment, and require it to equal `e_seg` at `o_done`.

Against the pre-fix unit, from a clean library containing only the old file:

```
/home/orencollaco/GitHub/llama.vhdl/sim/tb_gdn_conv.vhd:265:9:@905ns:(assertion failure):
tb_gdn_conv: e_seg CHANGED after the first data beat -- UUUUUUUU at the first
o_valid, 00010000 at o_done.  The segment exponent must be published before the
data it describes.
```

`UUUUUUUU` is the defect in its starkest form: at the moment the consumer takes
its first beat, the exponent for that beat has never been driven at all.

Against the fixed unit, the same testbench, and the two others unchanged:

```
tb_gdn_conv             : bit-exact with the C recipe on all 128 cases;
                          worst vs the double ORACLE 4.99999999998181e-1 LSB
tb_gdn_conv_cycles      : done                      (CYC rows unchanged)
tb_gdn_conv_tvalid_skew : PASS -- all 6 cases bit-exact at RDREQ_AT=16
```

Cycle counts are unchanged: `CYC,4,3072,{256..3072}` still report
`{146,274,402,530,786,1554}`. Moving an assignment between states did not move
the schedule, because `S_SH` already existed and already took one cycle.

## 5. Measured and REJECTED -- do not retry

- **Assigning from `shq` at `S_SH`.** `shq` is a signal, so the assignment does
  not take effect until the following cycle and `e_seg` would be computed from
  the previous segment's shift -- the same class of error, moved. The state now
  computes the shift into a variable `shv`, uses `shv` for `e_seg`, `sh_seg` and
  the range check, and assigns `shq <= shv` alongside. Rejected on reading, not
  on a run, and recorded so the next reader does not "simplify" it back.
- **Leaving the `S_FIN` assignment in place as well as adding the `S_SH` one.**
  Harmless in value and actively harmful in meaning: it leaves two sources for
  one output and invites the next edit to change only one. `S_FIN` now sets only
  `o_done`.
- **Reporting the failure with `integer'image(to_integer(...))`.** This is how
  the guard was first written and it does not work: on the pre-fix unit `e_seg`
  is metavalued at the first beat, so `to_integer` raises an error INSIDE the
  report expression and the simulation dies with `numeric_std-body.vhdl:3035`
  and no message. Use `to_string`. A guard whose failure message cannot be built
  reports the wrong thing at the worst moment.

## 6. Measurement traps hit

- **Every existing check sampled the output at or after `o_done`, so the entire
  suite was blind to a timing defect by construction.** Bit-exactness against a
  double oracle, 128 cases, a cycle-count table and a producer-skew testbench
  all passed. Correct values proved nothing about when they appeared.
- **This was found only because `gdn_block`'s testbench made the exponent depend
  on the segment.** With a constant or slowly varying exponent the two segments
  agree and the defect is invisible. That is the same lesson as the two
  producer-decoupling findings earlier in B: the stimulus has to vary the thing
  whose ordering is in question.
- **The absence of a symptom is not evidence.** A silent 2^k scaling error on a
  quantised activation path degrades output quality without failing anything.

## 7. Open, not yet answered

- Nothing consumes `err_seg`, and it now asserts one state earlier. The unused
  error-output policy across B (`y_sat`, `err`, `ovr`, `ovf`, `err_conv`,
  `err_g`, `err_se`) is still unresolved and is tracked as audit item B-10.
- ~~The other units that publish a scalar alongside a stream have NOT been
  audited.~~ **The sweep was run the same day. Result below.**

## 8. The sweep, 2026-08-27, same day

Every `rtl/*.vhd` whose entity declares BOTH an exponent- or shift-like output
and a valid-like output, checked for the assignment site of the scalar relative
to the state that raises the valid. Eleven units matched the shape.

| unit | scalar | verdict |
|---|---|---|
| `gdn_conv` | `e_seg`, `sh_seg` | **was the defect**, fixed here |
| `gdn_y_emit` | `y_exp` | CLEAN. `y_exp_r` is set in `S_AMAX`, one state before `S_EMIT` raises `o_valid_r`. This is the correct pattern and it was already correct |
| `gdn_emit_chain` | `y_exp` | CLEAN by inheritance, it wires `gdn_y_emit`'s port straight out |
| `gdn_block` | `y_exp` | CLEAN by inheritance, same port |
| `attn_score_q12` | `s_exp` | CLEAN and not at risk: `s_exp <= to_signed(QOUT, EXP_W)` is a compile-time constant, not state |
| `matvec_int4` | `y_exp` | pass-through of the `i_yexp` INPUT by continuous assignment, so its ordering is the producer's property and not this unit's. Not a defect here; it does mean the obligation moves upstream and is unrecorded there |
| `tp_collective_skel` | `o_exp` | not implemented, `o_exp <= (others => '0')`. Nothing to check yet, and the obligation should be written into E's spec before it is |
| `attn_softmax` | `rescale_n` | OPEN, referred to the C owner |
| `seq_desc_fetch` | `job_w_exp`, `job_out_shift`, `job_const_exp` | OPEN, referred to the D owner |
| `seq_opdec` | `cmp_y_exp`, `y_exp_taken`, `y_exp_held` | OPEN, referred to the D owner |
| `seq_region_lock` | `exp_rd_data` | OPEN, referred to the D owner |

The four OPEN rows are all continuous assignments from a register or from a
combinational function of a latched word, so the answer depends on when that
register or latch is written relative to the valid. That is exactly the
question this document is about, and it is not answerable by reading the port
map alone. They were not edited here because other work owns those files
concurrently; the check was handed to their owners with the pattern to look for.

**The generalisable rule, which is what should have existed before any of this:**
a scalar that qualifies a stream must be assigned in a state STRICTLY EARLIER
than the state that first raises the stream's valid, and a testbench that only
samples it at `done` cannot tell you whether that holds. Every unit with this
shape should carry an `ord_chk`-style guard. Four do not yet.
