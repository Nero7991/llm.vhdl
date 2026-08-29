# Defect B-BLK-1 fixed: which key head feeds which value head

Date: 2026-08-29.  Track: B-LAYER (the fix was folded into this track because
it was already the only track holding `rtl/gdn_block.vhd`).  GHDL mcode,
`--std=08 -frelaxed`.  No hardware was touched.

## The question, verbatim

> TASK 1: fix defect B-BLK-1. `rtl/gdn_block.vhd:958` reads
> `base := (vh/VPK)*DIM*16` with `VPK = VAL_HEADS/KEY_HEADS` (line 367), which
> is contiguous grouping.  TRACK B-BLOCK measured that the model tiles instead,
> `h mod KEY_HEADS`: at 2 key / 4 value heads, DIM 32, 2 tokens it found 128 of
> 256 y mantissas, 2048 of 4096 final state mantissas and 20 of 128 final state
> exponents wrong, exactly value heads 1 and 2, and flipping that one decision
> in its oracle took all three to zero.  At the real 9B shape it is 30 of 32
> value heads.
>
> Change the RTL to the model's rule.  Then flip TRACK B-BLOCK's oracle back to
> its model default, remove the loud per-run note it prints, and re-run its gate
> row plus `sim/mutate_gdn_block.sh`.  Also add the normative sentence to
> subsystem B spec section 4.

## The answer, up front

**Fixed.  `rtl/gdn_block.vhd`'s `P_HKQ` state now reads
`base := (vh mod KEY_HEADS)*DIM*16`, the quarantine is lifted everywhere, and
the block is bit-exact against the model's mapping: 0 of 256 y mantissas, 0 of
4096 final state mantissas, 0 of 128 final state exponents.**

The `VPK` constant is **deleted**, not left unused.  A dead constant named for
the wrong rule is a statement about the mapping, and the statement is false.

Teeth: the mutation that puts the contiguous grouping back is **KILLED**, with
exactly the signature TRACK B-BLOCK measured in the other direction --
128 of 256 y, 2048 of 4096 state.  Whole harness after the change:
CONTROL PASS, 18 mutations, 16 KILLED, 2 SURVIVED, 0 ABORT.

## What changed, and why each piece had to move together

| file | change |
|---|---|
| `rtl/gdn_block.vhd` | `P_HKQ`: `(vh/VPK)` -> `(vh mod KEY_HEADS)`; `VPK` deleted |
| `sim/regress.sh` | vector args `... 2 2 div` -> `... 2 2 mod`; tb args drop `-gKMAP_DIV=true` |
| `sim/tb_gdn_block_vec.vhd` | the loud per-run quarantine note removed; `KMAP_DIV` generic and its header assertion KEPT |
| `sim/mutate_gdn_block.sh` | `GENARGS` `div` -> `mod`; `RUNARGS` drop `-gKMAP_DIV=true`; M01 inverted |
| spec section 4, and a pointer in 2.9 | the normative tiling sentence |

`KMAP_DIV` is deliberately **not** deleted.  It is the tie between the bench
and the `kmap` flag in the vector file's header, so the oracle and the DUT
cannot silently disagree about a decision that moves half the output, and it
is how the defect is reproduced: generate with `div`, run with
`-gKMAP_DIV=true`.

**M01 is inverted rather than removed.**  It used to be "the FIX", expected
KILLED against `div` vectors.  It is now "REINTRODUCES B-BLK-1", expected
KILLED against `mod` vectors.  Either way its job is the same: if M01 ever
survives, the harness has stopped seeing the key-head mapping and every other
row in the table is suspect.  The mutation writes the divisor out in full
rather than naming `VPK`, because `VPK` no longer exists and an anchor
mentioning it would fail to COMPILE rather than fail to MATCH, which is a much
less useful signal.

## The rule, and where it comes from

```
    hk = h mod num_k_heads          -- TILING, not contiguous grouping
```

At 16 key heads and 48 value heads, key head 0 serves value heads 0, 16 and
32.  Not 0, 1 and 2.

`ggml_repeat_4d` is a broadcast and every ggml broadcast tiles:
`ggml_compute_forward_repeat_f32` writes destination row `i1*ne01 + k1` from
source row `k1`, so destination head `h` reads source head `h % ne01`.  That
derivation is TRACK B-BLOCK's, confirmed by it a second time from the
non-fused decode path, and it is recorded in
`docs/debugging/2026-08-29_gdn-block-oracle.md` step 9.  It was not re-derived
here; what was done here is the change and its verification.

**The two rules agree on the first and the last value head of each group.**
That is why value head 0 was clean and the divergence read as a head-boundary
bug rather than as a permutation.  Worth remembering: a permutation defect
whose fixed points include index 0 will always look like an off-by-one at the
boundary.

## The proximate cause, and the spec sentence that closes it

Section 4 said "each key head serves **3 value heads**" and section 2.9 said
"the GQA ratio inside GDN is **3 value heads per key head**".  Both state the
RATIO.  Neither states the ASSIGNMENT, and `rtl/gdn_block.vhd` was written to
the contiguous reading of it.

Section 4 now carries the index expression, the ggml derivation, the measured
cost of having omitted it, and a general rule:

> **A ratio is not an assignment.**  Any future statement of the form "each X
> serves N Y" in this document owes the index expression alongside it.

Section 2.9 gets a one-line pointer at the same place its ratio sentence sits,
because that is the other paragraph a reader could stop at.

## Evidence, raw

### the fixed RTL against the model's vectors

```
$ ./gen gdn_block_vec.txt 2 4 32 2 2 mod
gdn_block_vec: KH=2 VH=4 D=32 KCONV=4 tokens=2 kmap=mod (the model) -> gdn_block_vec.txt
  flags: err_conv=0 err_g=0 err_se=0 y_sat=0 (0 saturating tokens excluded from the oracle)
  worst end-to-end error vs the double oracle: 0.145028, relative to max(one y LSB, the element term norm) (token 0, element 23)
  elements compared: 256 of 256;  over 0.05: 5 (1.95%)
  OK

$ ghdl -r --std=08 -frelaxed tb_gdn_block_vec --stop-time=200ms --max-stack-alloc=0
tb_gdn_block_vec: y mismatches 0 of 256, state mismatches 0 of 4096, state-exponent mismatches 0 of 128
tb_gdn_block_vec: PASS, 256 y elements, 4096 state mantissas and 128 state exponents bit-exact against gdn_block_vec.txt
```

Note this run is at `DUT_LAYER=1`, the bench's new default, so the mapping fix
and the layer axis are both live in the same comparison.

### the teeth: putting the contiguous grouping back

```
TAG        CLASS   VERDICT        DESCRIPTION
CONTROL    control PASS           UNMUTATED design through the same mutate path
                                  y mismatches 0 of 256, state mismatches 0 of 4096, state-exponent mismat
M01        rtl     KILLED         key-head map h mod KH -> h/(VH/KH) (REINTRODUCES B-BLK-1)
                                  y mismatches 128 of 256, state mismatches 2048 of 4096, state-exponent m
```

128 of 256 and 2048 of 4096 are the same two numbers TRACK B-BLOCK measured
when it found the defect from the other side.  The harness sees the mapping.

### the whole harness after the change

```
CONTROL (unmutated, same path): PASS
MUTATIONS 18   KILLED 16   SURVIVED 2   ABORT 0

SURVIVORS -- these are what the bench CANNOT see:
  M07  segment exponent captured LIVE instead of from the frozen copy
  M13Z  M13 again at DUT_LAYER=0 -- EXPECTED SURVIVOR, the floor
```

Both survivors are documented and deliberate: M07 is TRACK B-BLOCK's schedule
result, M13Z is the layer-index resolution floor added earlier today.

### the gate rows

```
$ bash sim/regress.sh --only gdn_block
 suite sim   PASS 2   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 2   FAIL 0   ...
 REGRESSION: PASS
```

`--only` takes a SUBSTRING, so `gdn_block` selects both `tb_gdn_block` and
`tb_gdn_block_vec`.  `PASS 2` is the check that it selected two rows and not
zero; a `--only` that matches nothing still prints `REGRESSION: PASS`.

## Measured and REJECTED -- do not retry

**Leaving `VPK` in place as an unused constant.**  It compiles and it is inert,
and that is exactly the problem: the next reader takes a named constant as a
statement of the design's rule.  Deleting it also makes any stale mutation
anchor fail loudly at compile time instead of quietly failing to match.

**Deleting the `KMAP_DIV` generic along with the defect.**  Rejected.  It is
the assertion tie against the vector file's `kmap` flag, and without it the
oracle and the DUT could be regenerated onto opposite rules with no complaint.
It also costs nothing: it is `false` everywhere now.

**Re-deriving the ggml broadcast rule.**  TRACK B-BLOCK derived it twice from
two independent code paths and checked that nothing in `tools/` compensates.
Re-deriving it here would have been a third transcription of the same reading,
which measures nothing.  The check that matters is the one that ran: the fixed
RTL against the model-default oracle, bit for bit.

## Measurement traps hit

**`sim/regress.sh --only` takes a SUBSTRING and a no-match run still says
`REGRESSION: PASS`.**  The only tell is the count.  Both targeted runs here
were read for `PASS n` first and for `FAIL 0` second.

**A mutation harness's GENARGS and RUNARGS have to move together.**  Changing
`GENARGS` to `mod` while leaving `-gKMAP_DIV=true` in `RUNARGS` does not
produce wrong numbers, it produces the bench's own header assertion -- which
is the design working, but it aborts every row including the CONTROL, and a
table whose control aborted measures nothing.

## Open, not yet answered

- **The fix is verified at 2 key / 4 value heads.**  The two rules differ on
  30 of 32 value heads at the real 9B shape, and the oracle has never been run
  there: one token at the shipping shape is ~30,000 cycles per skew point.
  The shape at which the question is ASKABLE is any with
  `VAL_HEADS > KEY_HEADS`, and `VAL_HEADS = 2*KEY_HEADS` is the smallest.
- **No full `sim/regress.sh` run.**  The two `gdn_block` rows and the six
  `llama_top` rows were run targeted; the rest of the gate was left alone.
