# How should `ga_desc` be verified, and why the obvious answer is wrong

Date: 2026-09-05, written BEFORE any bench code, after D1/D2 landed analysing
but unsimulated.

## The question

> `ga_desc` binds the card's A through `a_desc_adapter`. It analyses and has
> never been simulated. What bench establishes that it is right?

## The answer, up front

**Instantiate the REAL `matvec_int4_desc_axi` in the identity bench behind
`A_DESC`, and reuse the `A_DESC = false` landmarks UNCHANGED as the oracle.
Do not write a behavioural model of A.** Add a passive monitor for the three
properties that belong to the seam rather than to A.

## The approach that was drafted and REJECTED

A 204-line behavioural model of the card's A (`scratchpad/a_desc_model.vhd`,
analyses clean, teeth-tested) computing a deliberately simple function, on the
stated grounds that re-implementing A's arithmetic would be "a second model of
a thing already checked".

**That reasoning is correct about A's arithmetic and wrong about the bench**,
and `sim/tb_llama_top_bstate.vhd`'s header says why:

> THIS FILE INVENTS NO NUMBERS, AND THAT IS THE WHOLE DESIGN. ... The four
> landmarks are that file's, unmodified. ... Re-deriving these four from a run
> of the tiered arm would make this a round trip against itself, which this
> project has already recorded passing for a wrong-but-consistent
> implementation (the `m7 mutant`).

With a simplified model the two arms compute DIFFERENT numbers. The
`A_DESC = true` row therefore cannot reuse the `A_DESC = false` landmarks and
must derive its own **from a run of itself**. That is the m7 shape exactly.

`bst_slave` in the same bench states the converse: it "MUST ACTUALLY STORE ...
a sink would also make the NTOK=1 row pass while proving nothing, so the round
trip is the point."

**A model is only admissible when it is faithful enough that the other arm's
numbers still apply. A model chosen to be simple is a model chosen to destroy
its own oracle.**

## Why the real unit is available, and cheaper than it looks

The descriptor plane is already covered by three pieces, none of which had to be
built for this:

| piece | what it establishes |
|---|---|
| `tools/gen_mv4i_desc.py` | builds descriptor bytes, host-side |
| `sim/tb_matvec_fk33_desc.vhd` | the arithmetic is **bit-exact through the control plane** |
| `sim/tb_mv4i_desc_image.vhd` | the REAL RTL judges host-written bytes, because "a host tool checked only by its own decoder proves nothing" |

So "build an arena and serve A's descriptor fetch", the reason the model looked
attractive, is mostly an assembly job against existing parts.

Using the real unit also means the row can catch defects in
`matvec_int4_desc_axi`'s own descriptor handling, which **no model could ever
have**, and removes a file that would need maintaining in step with A forever.

## The passive monitor, which survives from the rejected draft

Three properties belong to the SEAM and hold whatever A is:

1. **The x-before-GO ordering rule.** `d_x_we` has no back-pressure and A begins
   reading x on GO, so a GO with x incomplete does not fail loudly: A reads
   whatever the previous token left and completes with `done=1, err=0`. This is
   the correctness crux of `ga_desc` and **nothing else in the design can see
   it**.
2. **The descriptor address.** `ga_desc` delegates `arena_base + index*512` to
   `a_desc_adapter`, and **delegation is not evidence**: the job counter and the
   adapter have never been checked together.
3. **No second GO before completion** -- `a_desc_adapter`'s header calls this
   "the whole correctness argument".

**A monitor drives nothing and implements nothing, so it can raise a false
failure but cannot manufacture agreement.** That asymmetry is the reason to
prefer it over a model wherever a check will do.

## Open, not yet answered

- Whether the `A_DESC = true` arm reproduces the landmarks. **This document
  predicts nothing.** If it does not, the first question is whether the seam is
  wrong or the arena is, and the monitor is what separates them.
- D4, the `w_active` gate, still unapplied.
- B's 29 `bst_*` and C's 26 `kv_*` HBM ports, still unmapped and still the
  largest remaining piece.
