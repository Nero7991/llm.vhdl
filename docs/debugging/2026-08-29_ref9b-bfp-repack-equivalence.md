# The 9B reference's repack is not the hardware's repack, and it is the only left-shifting normaliser in the project

**Date:** 2026-08-29. Branch `fpga`. Track REF9B, follow-on to backlog item 12.
**Subject:** `ref/run9b.c`'s `reg_put` against the RTL that produces the same
seams in `rtl/llama_top.vhd`.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/`, nothing opening `/dev/xdma*`. GHDL and gcc only, in a
scratch directory.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

From `docs/debugging/2026-08-29_9b-whole-model-reference.md` section 9,
"Explicitly NOT verified":

> **The float-to-BFP repack is VALUE-equivalent to `rtl/bfp_pack.vhd`, not
> proven bit-identical to it.** `bfp_pack` shifts an int32 Q-grid input;
> `reg_put` shifts a double. The rule (`shift so the max lands in bit 14`,
> round half toward +inf, saturate) is the same and the exponent convention is
> the same, but no test compares them.

That is the whole of what was known. This track wrote the test.

---

## 2. The answer, up front

**The value claim is true and the bit-exactness claim is false, and the reason
is one clause.** `bfp_pack` computes `sh = max(0, msb_pos(amax) - 14)`. The
clamp at zero means it can only ever RIGHT-shift: a quiet block, whose maximum
already sits below bit 14 on the input grid, comes out UNDER-NORMALISED.
`reg_put` computes `exp = 14 - floor(log2(amax))` with no clamp, so it ALWAYS
places the maximum in bit 14, left-shifting when the block is quiet.

MEASURED, `tools/ref9b_bfp_equiv.sh`, 760 cases against the shipping entity run
in GHDL, at five `(N, Q)` settings:

| | count of 760 |
|---|---|
| identical, exponent and every mantissa | 419 |
| **exponent differs** | **341** (quiet 341, **loud 0**) |
| some mantissa differs | 340 |
| **reconstructed VALUE differs** | **0** |

**Every divergence is on a quiet block and there are none on a loud one, and
the reconstructed real values agree exactly, everywhere.** So the section 9
sentence should read: value-equivalent, MEASURED; bit-identical only on blocks
whose maximum reaches bit 15 of the input grid.

**And the finding is much larger than `bfp_pack`.** Three things widen it:

1. **`bfp_pack` is not in the 9B path at all.** MEASURED by grep:
   `rtl/llama_top.vhd` instantiates `attn_block`, `attn_kv_axi`, `gdn_block`,
   `matvec_int4`, `rmsnorm_rs`, `sampler_stream`, `seq_desc_fetch`,
   `seq_opdec`, `seq_region_lock`, `seq_vec_issue`, `seq_vec_res`, and
   `bfp_pack` appears zero times. It lives in `engine_shared` (the AXU3EG
   stories260K design). The reference doc named a comparator that is not on the
   path it is comparing.
2. **Every unit that IS on the path clamps the same way.** MEASURED by reading
   the shift computation in each (section 5.3): `rmsnorm_rs:519-531`,
   `seq_vec_res:598-609`, `gdn_y_emit:373-379`, `attn_emit:551-566`. All four
   are `sh = max(0, msb_pos - 14)`, and in three of the four the shift signal
   cannot even HOLD a negative value, so a left shift is not merely unused but
   unrepresentable: `seq_vec_res:255` `sh_r : natural range 0 to 63`,
   `gdn_y_emit:191` `sh_r : integer range 0 to 63`, `attn_emit:284`
   `shp_r : unsigned(SHPW-1 downto 0)`. The fourth, `rmsnorm_rs:118`
   `shift_total : integer`, is unconstrained and relies on the clamp alone.
   **`reg_put` is the only normaliser in this project that can left-shift**,
   and the only other one that does is `NORM_ANCHOR`, a probe that is off by
   default.
3. **`R_H` is worse than a clamp.** The SwiGLU in `llama_top` is a behavioural
   stub (`gen_vstub`), and its shift is the constant `MANT_W` with no maximum
   scan at all (`llama_top.vhd:1515-1518`, exponent at `:1597`). So `R_H` is
   under-normalised even when the block is loud, unconditionally.

**The consequence is a defect in the instrument, not in the machine.** MEASURED
on the committed reference stream: **193 of the 490 BFP records per token
(39.4%) are produced by `reg_put`**, including all 32 `R_H` records. The
`--mode exact` bisect reports the FIRST divergence, so once a GHDL or on-card
capture exists it will point at the first quiet `reg_put` seam, or at
`R_H-0` regardless of quietness, **before reaching any real defect**. A bisect
whose first hit is always the same false one has stopped being a bisect.

**The clamp is not hypothetical on real 9B data.** MEASURED with
`tools/ref9b_stream_norm.py` on `/mnt/storage/ref9b/ref_bfp.r9bs`: 11 of 2,450
BFP records are under-normalised, every one of them an `R_ER.ffn-L`, with max
mantissa as low as 7,207 -- 1.2 bits below normalised. Those are matvec seams,
where `ref/matvec_int4.c` already carries the clamp, so the reference gets them
right. **They are the proof that the clause fires**, at 11 of 160 `R_ER.ffn`
records = 6.9%, on the same activations the `reg_put` seams see.

**Not fixed here, deliberately.** The fix is in `ref/run9b.c`, an existing
`ref/` file this track does not own, and it is not a one-line change: `reg_put`
has no input grid to clamp against, because the reference's interior is float.
Section 6 states what the fix has to be.

---

## 3. What this does and does not disturb

**Not disturbed.** The whole-model result of backlog item 12 stands untouched.
Every number in it is a comparison of the reference against llama.cpp or
against itself, and both sides of every such comparison use `reg_put`. The
layered gap table, the 8-of-9 mutation localisation, the top-5 agreement and
the argmax chain are all unaffected: a systematically over-precise repack that
is exactly value-preserving cannot move them.

**Disturbed.** Exactly one claim, and one use. The claim is section 9's
"bit-identical" sentence. The use is `--mode exact` against a producer that is
not `ref/run9b.c` -- which is the mode's entire purpose and the reason
`tools/ref9b/capture_to_r9bs.py` exists. Section 5.8 of that document
demonstrates one-LSB resolution, and that demonstration is sound, but it was
run reference-against-reference. Against the machine it will fire on 193 seams
per token before it fires on a defect.

---

## 4. The procedure, in the order it was run

Each step controls for exactly one thing.

1. **Read both rules.** `ref/run9b.c:315` (`reg_put`) and `rtl/bfp_pack.vhd`.
   Controls for nothing; this is where the hypothesis came from and it is not
   evidence.
2. **Run the shipping entity in GHDL** over three hand-made cases.
   `tools/ref9b_bfp_equiv_tb.vhd` drives `rtl/bfp_pack.vhd` unmodified, with a
   BRAM model matching `rtl/vec_mem.vhd`'s read-ahead contract. **Controls for
   the reading being wrong.** The project rule is that the RTL wins, and a
   transcription is evidence about the transcriber.
3. **Score the C transcription against what the entity printed**, over 760
   generated cases at five `(N, Q)` settings. **Controls for every number
   below**: a comparison built on an unverified transcription measures the
   transcription.
4. **Seven mutants of the transcription**, scored against the same RTL run.
   **Controls for a checker that cannot fail.**
5. **Compare the verified transcription against `reg_put`**, classifying each
   divergence as exponent / mantissa / value and each case as quiet / loud.
   **Controls for reporting a count where a class is what matters.**
6. **Ask whether `bfp_pack` is even on the 9B path.** One grep. **Controls for
   answering the wrong question well** -- and it fired: it is not.
7. **Read the shift computation in the four units that ARE on the path.**
   Controls for generalising from one unit to a family that might not share the
   rule. It does share it.
8. **Measure the normalisation signature of the committed reference stream.**
   `tools/ref9b_stream_norm.py`. **Controls for the whole thing being a
   property of synthetic inputs**: it asks whether the clamped rule ever fires
   on real 9B activations, without needing to know any producer's input grid.

---

## 5. The evidence, as raw captured output

### 5.1 The transcription is bit-identical to the shipping entity

`bash tools/ref9b_bfp_equiv.sh`, 760 cases per setting. The case set is 16
named edges (all-zero, single LSB of each sign, the bit-14 boundary from both
sides, the int16 rails, the bias-saturation case, both int32 rails, a power
ladder, a negative tie) followed by a magnitude sweep of 24 vectors in each of
31 magnitude bands.

```
== N=16 Q=12 ==
SCORE 760 compared, 0 mismatched vs rtl/bfp_pack.vhd -- BIT-IDENTICAL
== N=172 Q=12 ==
SCORE 760 compared, 0 mismatched vs rtl/bfp_pack.vhd -- BIT-IDENTICAL
== N=8 Q=0 ==
SCORE 760 compared, 0 mismatched vs rtl/bfp_pack.vhd -- BIT-IDENTICAL
== N=16 Q=20 ==
SCORE 760 compared, 0 mismatched vs rtl/bfp_pack.vhd -- BIT-IDENTICAL
== N=64 Q=12 ==
SCORE 760 compared, 0 mismatched vs rtl/bfp_pack.vhd -- BIT-IDENTICAL
```

`N = 172` is the entity's own default and `N = 8, Q = 0` exercises the
degenerate grid.

### 5.2 The three cases that show the rule directly

The first GHDL run, before any comparator existed:

```
input                                       -> OUT case exp mantissas
1 2 3 ... 16                                -> OUT 0 12  1 2 3 4 ... 16
40000 -40000 1 0 ...                        -> OUT 1 11  20000 -20000 1 0 ...
0 0 0 ... 0                                 -> OUT 2 12  0 0 0 ... 0
```

Case 0 is the finding in one line. The maximum is 16, `msb_pos(16) = 4`,
`sh = max(0, 4 - 14) = 0`, so the entity emits the input unchanged at
`exp = Q = 12`. `reg_put` on the same real values emits `exp = 26` and
mantissas `1024, 2048, ...`: ten more bits of mantissa than the hardware has.

Case 2 is the all-zero divergence: the entity emits `exp = Q = 12`, `reg_put`
emits `exp = 0`. Both are all-zero so the values agree, but the exponent field
is compared, and `0` is not even on the input grid.

### 5.3 Every unit on the 9B path clamps, and three cannot represent a left shift

MEASURED by reading the shift computation in each file.

| unit | seam | line | rule | left shift |
|---|---|---|---|---|
| `rmsnorm_rs` | `R_XN-L`, `R_XN.ffn-L`, `R_XN.final` |  `:519-531` | `if msb_p - 14 < 0 then st := 0; else st := msb_p - 14;` `o_exp <= xe + we + Q - st` | no |
| `seq_vec_res` | `R_X-L`, `R_X.attn-L` | `:598-609` | `sh_v := p_r - KEEP; if sh_v < 0 then sh_v := 0;` with `KEEP = MANT_W - 2 = 14` | no |
| `gdn_y_emit` (via `gdn_block`) | `R_Y-L`, 24 layers | `:373-379` | `if msb_pos(amax) - 14 > 0 then sh_r <= ...; else sh_r <= 0;` | no |
| `attn_emit` (via `attn_block`) | `R_Y-L`, 8 layers |  `:551-566` | `sh_v := p_msb - TARGET_MSB; if sh_v < 0 then sh_v := 0;` | no, `shp_r` is `unsigned` |
| `llama_top` `gen_vstub` | `R_H-L` | `:1515-1518`, `:1597` | fixed `/ 2**MANT_W`, `yexp <= v_exp_a + v_exp_b - MANT_W` | no, and no max scan at all |
| `seq_vec_issue` | -- | -- | no arithmetic; carries exponents by value | n/a |

`seq_vec_res` states the correspondence itself, at `:47-49`:

```
--  3. THE OUTPUT EXPONENT IS DRIVEN BY THE MAXIMUM, exactly as bfp_pack:
--     p = msb_pos(max |acc|), sh = max(0, p - KEEP) with KEEP = MANT_W - 2,
--     oexp = q - sh.
```

and `gdn_y_emit` states the prohibition outright, at `:32-40`:

```
-- ... and BOTH are right-shifts: the alignment is right because e_y_raw is a
-- MINIMUM, and the requantize is right because sh is clamped at 0.  There is
-- deliberately no left-shift path.
```

**One caveat found on the way, worth carrying separately.** `seq_vec_res` DOES
contain a left shifter, in its operand alignment (`:546-560`), and a careless
grep for `shift_left` would call it a counter-example. It is not: the working
grid is `j_q = min(ex, ee) + min(|ex - ee|, SHMAX)`, which is at most
`max(ex, ee)`, and `sh_v >= 0` thereafter, so the OUTPUT exponent is capped at
`max(ex, ee)`. A quiet residual still cannot gain precision.

**A second caveat that bears on the reference's own seam table.**
`rmsnorm_rs`'s widely-quoted "scale-free, `st` cancels the `x_exp` term"
property (repeated at `llama_top.vhd:1622-1630`) holds only on the `st > 0`
branch. On a quiet block `st` is pinned at 0 and `o_exp = xe + we + Q` carries
`x_exp` straight through. That is the same clause, seen from the other side.

### 5.4 The comparison, classified

```
COMPARE cases 760
  identical (exp and every mantissa) : 419
  exponent differs                   : 341  (quiet 341, loud 0)
  some mantissa differs              : 340
  reconstructed VALUE differs        : 0
  blocks bfp_pack leaves un-shifted  : 368  (all-zero 1)
  cases where bfp_pack saturates     : 4
  cases where reg_put  saturates     : 4
  worst relative value divergence    : 0.000000e+00 (case -1 -)
```

Three readings.

- **`loud 0` is the strongest line in the table.** On every block whose maximum
  reaches bit 15 of the input grid the two rules agree bit for bit, exponent
  and all mantissas. The divergence is not a rounding disagreement anywhere; it
  is one clause, reachable from one input class.
- **368 quiet, 341 divergent, so 27 quiet blocks agree.** DERIVED: those are
  the blocks whose maximum lands in `[2^14, 2^15)` on the input grid, where the
  reference's normalisation happens to choose exactly `exp = Q`. The
  agreement is a coincidence of the band, not a shared rule.
- **`worst relative value divergence 0.000000e+00`.** Not "small": exactly
  zero, on all 760 cases at all five settings. `reg_put` differs from the
  hardware by a pure change of representation, never of value. That is why the
  item-12 numbers are undisturbed, and it is also why nothing short of a
  bit-exact comparison could ever have found this.

The two saturation columns being equal, at 3 to 5 depending on `(N, Q)`,
**refutes a prediction I made before measuring**: I expected `reg_put` never to
saturate, on the grounds that normalising to bit 14 leaves a bit of headroom.
It does saturate, by the same mechanism as the hardware -- the round-half-up
bias can carry a maximum of `2^15 - 1` to exactly `32768`. Recorded because a
prediction that survives unmeasured becomes a fact.

### 5.5 Teeth

Seven mutants of the transcription only, so the checker under test is the
comparison against the RTL.

```
   m1 bites          -- SCORE 760 compared, 341 mismatched -- DISAGREES WITH THE RTL
   m2 DOES NOT BITE  -- SCORE 760 compared,   0 mismatched -- BIT-IDENTICAL
   m3 bites          -- SCORE 760 compared, 386 mismatched -- DISAGREES WITH THE RTL
   m4 DOES NOT BITE  -- SCORE 760 compared,   0 mismatched -- BIT-IDENTICAL
   m5 bites          -- SCORE 760 compared, 392 mismatched -- DISAGREES WITH THE RTL
   m6 bites          -- SCORE 760 compared, 368 mismatched -- DISAGREES WITH THE RTL
   m7 bites          -- SCORE 760 compared, 392 mismatched -- DISAGREES WITH THE RTL
```

| # | mutant | verdict |
|---|---|---|
| 1 | remove the `sh < 0` clamp | bites, 341 |
| 2 | `msb_pos(0) = -1` instead of the normative `0` | **does not bite** |
| 3 | truncate instead of round half toward +inf | bites, 386 |
| 4 | symmetric saturation, `-32767` instead of `-32768` | **does not bite** |
| 5 | target bit 15 instead of bit 14 | bites, 392 |
| 6 | apply the rounding bias at `sh = 0` too | bites, 368 |
| 7 | `Q + sh` instead of `Q - sh` | bites, 392 |

**m1 bites on exactly 341 cases, which is the same 341 the comparison stage
reports.** That is not a coincidence and it is the cleanest corroboration in
this document: m1 IS `reg_put`'s rule, injected into the transcription, and two
independent code paths -- one scoring against GHDL, one scoring against
`reg_put` -- pick out the same case set.

**The two rows that do not bite are the more valuable ones.**

- **m2 is unobservable BECAUSE of the clamp, and only because of it.** DERIVED:
  `msb_pos(0) = -1` gives `sh = -15`, `msb_pos(0) = 0` gives `sh = -14`, and
  both are clamped to `0`. Any value of `msb_pos(0)` at or below 14 produces
  identical output. So `rtl/mv4i_arith_pkg.vhd:22`'s "`msb_pos(0) = 0` is
  NORMATIVE, matching `bfp_pack.msb_pos_u`" is normative for OTHER callers;
  through `bfp_pack` itself it is unfalsifiable. **This is a permanent
  structural non-biter, not a coverage gap**, and no case set can close it.
  Note the interaction: under m1, m2 would become observable. The clamp hides
  it.
- **m4 does not bite because `-32768` is unreachable at `bfp_pack`'s output.**
  DERIVED: with `sh >= 1` and `amax < 2^(p+1)` where `p = msb_pos(amax)` and
  `sh = p - 14`, the most negative attainable mantissa is
  `floor((-(2^(p+1) - 1) + 2^(sh-1)) / 2^sh) = -32767`, because the rounding
  bias is toward `+inf` and so pulls the negative rail in by one. With `sh = 0`
  the block is quiet, `amax <= 32767`, so no element is `-32768` in the first
  place. MEASURED across all five RTL runs: `-32768` appears **0** times in the
  entity's output and `32767` appears **21** times. **The negative half of
  `sat16` in `bfp_pack` is dead logic**, and `ref/matvec_int4.c`'s
  `bfp_pack_vec` inherits the same property by construction.

### 5.6 The clamp fires on real 9B activations

`python3 tools/ref9b_stream_norm.py /mnt/storage/ref9b/ref_bfp.r9bs --list-under`

```
BFP16 records   : 2450   (F32 records skipped: 5)
exponent range  : 6 .. 19
  NORMALISED  :   2439  (99.55%)
  UNDER       :     11  (0.45%)
  ZERO        :      0  (0.00%)
signature       : MIXED: 11 records are under-normalised, so at least one
                  producer clamps the shift at zero
UNDER R_ER.ffn-1             tok 0 exp   16 n   4096 max|mant|  13113
UNDER R_ER.ffn-29            tok 0 exp   12 n   4096 max|mant|  16005
UNDER R_ER.ffn-0             tok 1 exp   15 n   4096 max|mant|   7882
UNDER R_ER.ffn-20            tok 1 exp   13 n   4096 max|mant|  12040
UNDER R_ER.ffn-21            tok 1 exp   12 n   4096 max|mant|   9865
UNDER R_ER.ffn-23            tok 1 exp   12 n   4096 max|mant|   7207
UNDER R_ER.ffn-27            tok 1 exp   12 n   4096 max|mant|  11143
UNDER R_ER.ffn-5             tok 2 exp   14 n   4096 max|mant|   9473
UNDER R_ER.ffn-17            tok 2 exp   14 n   4096 max|mant|  13507
UNDER R_ER.ffn-8             tok 4 exp   14 n   4096 max|mant|   8177
UNDER R_ER.ffn-17            tok 4 exp   14 n   4096 max|mant|  15042
```

Every one is `R_ER.ffn-L`, the FFN down projection. MEASURED: 11 of the 160
`R_ER.ffn` records across the five tokens, **6.9%**.

Why that seam and no other: `R_ER.ffn` is a matvec output, so the reference
computes it with `ref/matvec_int4.c`'s BFP path, which carries the same clamp
the RTL does. The reference is CORRECT there. These eleven records are
therefore not a defect; they are the only direct evidence available that the
clause is reachable from real 9B data at all, on a seam whose reference and
hardware rules already agree.

### 5.7 How much of the stream is affected

Token 4, all 490 BFP records, grouped by producer according to the call sites
in `ref/run9b.c` (`reg_put` at `:516, 623, 631, 637, 644, 650, 670, 759, 766,
771, 778, 784, 856, 996`; everything else is `mv4i_matvec`):

```
seam family         recs   norm  under  exp range      producer rule
R_H-L                 32     32      0  9..16          reg_put (ALWAYS normalise)
R_X-L                 32     32      0  8..12          reg_put (ALWAYS normalise)
R_X.attn-L            32     32      0  8..12          reg_put (ALWAYS normalise)
R_XN-L                32     32      0  8..10          reg_put (ALWAYS normalise)
R_XN.ffn-L            32     32      0  9..13          reg_put (ALWAYS normalise)
R_XN.final             1      1      0  9..9           reg_put (ALWAYS normalise)
R_Y-L                 32     32      0  10..16         reg_put (ALWAYS normalise)
R_ALPHA-L             24     24      0  12..13         mv4i_matvec (clamped)
R_BETA-L              24     24      0  12..14         mv4i_matvec (clamped)
R_ER-L                32     32      0  10..17         mv4i_matvec (clamped)
R_ER.ffn-L            32     30      2  8..17          mv4i_matvec (clamped)
R_G-L                 32     32      0  10..15         mv4i_matvec (clamped)
R_KIN-L                8      8      0  12..12         mv4i_matvec (clamped)
R_QG-L                 8      8      0  10..11         mv4i_matvec (clamped)
R_QKV.k-L             24     24      0  9..13          mv4i_matvec (clamped)
R_QKV.q-L             24     24      0  9..13          mv4i_matvec (clamped)
R_QKV.v-L             24     24      0  9..12          mv4i_matvec (clamped)
R_U-L                 32     32      0  11..15         mv4i_matvec (clamped)
R_VIN-L                8      8      0  8..13          mv4i_matvec (clamped)
R_X.embed              1      1      0  16..16         mv4i_matvec (clamped)
R_Z-L                 24     24      0  10..13         mv4i_matvec (clamped)

reg_put-produced records at token 4 : 193
matvec-produced records at token 4  : 297
```

**193 of 490 records per token, 39.4%, are on the affected rule.** Zero of them
are under-normalised, which is `reg_put`'s signature and is exactly the point:
the reference cannot produce an under-normalised block, and the hardware
produces them at a measurable rate.

Of those 193, the 32 `R_H` records are affected **unconditionally**, because
the SwiGLU stub's shift is a data-independent constant. The other 161 are
affected whenever the block is quiet on the producing unit's grid.

---

## 6. What the fix has to be, and why it was not done here

`ref/run9b.c` is an existing `ref/` file this track does not own, so this is a
report, not an edit. It is also not a one-liner, and the reason is worth
recording because it is the same reason the divergence exists.

**`reg_put` has nothing to clamp against.** The hardware's `sh` is clamped
relative to the INPUT GRID: `sh = max(0, msb_pos(amax_on_grid) - 14)` needs
`amax` expressed as an integer on a known grid `2^-Q`. `reg_put`'s input is a
double, and the reference's interior is float by design (item 12 section 7
rejected re-deriving the fixed-point interiors as the `m7` mutant, and that
rejection still stands). So there is no `Q` to clamp against, and inventing one
would be inventing exactly the fixed-point recipe that was deliberately not
re-derived.

Three routes, none free, none taken here:

1. **Carry an input grid through the float interior.** Each `reg_put` call site
   would have to name the exponent its producer would have published. That is
   the fixed-point recipe by another name for `R_Y` and `R_H`; for `R_XN` and
   `R_X` it may be tractable, because `rmsnorm_rs`'s and `seq_vec_res`'s output
   exponents are simple functions of their input exponents, which the reference
   already has.
2. **Make the comparison grid-aware instead.** Have the bisect compare
   `mant * 2^-exp` at a declared tolerance for the `reg_put` seams and
   bit-exactly for the matvec seams, and SAY which mode each seam is in. This
   preserves the item-12 result untouched and costs the one-LSB resolution
   exactly where section 5.8 of that document claimed it. It is the cheap
   route and it is honest, but it gives up the property the fixed-point rung
   exists for on 39.4% of the seams.
3. **Emit both.** Have `reg_put` publish its normalised record and, where the
   producing grid is known, a second clamped record. Costs stream size and a
   format change.

**Route 2 is the one that can be done without touching the interior**, and the
decision between 1 and 2 is Oren's, not this track's, because route 1 is a
scope change to what the reference claims to model.

---

## 7. Measured and REJECTED -- do not retry

**Transcribing `bfp_pack.vhd` into C and comparing that against `reg_put`.
REJECTED before it was run.** It would have produced the same 341, and it
would have been worth nothing: the whole class of defect this project keeps
finding is a second implementation of the same misunderstanding. The
transcription exists only as a bridge, and it is scored against the entity over
760 cases at five settings before any number is taken from it. Note that this
is not caution for its own sake: the transcription was written from a reading
that was WRONG about `seq_vec_res` (section 5.3's first caveat), and the only
reason the wrong reading did not propagate is that the reading was never the
evidence.

**Comparing `reg_put` against `bfp_pack` and stopping there. REJECTED, with the
grep that killed it.** `bfp_pack` appears zero times in `rtl/llama_top.vhd`. It
is `engine_shared`'s unit, on the AXU3EG stories260K design. Had this track
stopped at the sentence it was given, it would have delivered a correct answer
about a unit that is not on the path, and the `R_H` finding -- which is
unconditional and therefore the worst of the three -- would not have appeared
at all. **A brief that names the comparator has already made a judgement, and
it is worth one grep to check it.**

**Deriving the affected rate for the `reg_put` seams by analogy with
`R_ER.ffn`'s 6.9%. REJECTED as unsound.** The clamp fires as a function of the
PRODUCING UNIT's input grid, and `R_ER.ffn`'s grid is
`w_exp + x_exp - out_shift` while `rmsnorm_rs`'s is `xe + we + Q` and
`gdn_y_emit`'s is a minimum over heads. Those are different mechanisms with
different distributions, and 6.9% is a measurement of one of them. What would
settle it is a GHDL capture of `llama_top` in `.r9bs` form, which does not
exist -- it is the same missing artefact item 12 named as its own next step.
The number is quoted in this document ONLY as evidence that the clause is
reachable at all.

**A tolerance on the exponent field. REJECTED.** An exponent that is one out is
a factor of two, not a small error, and the whole reason the format carries the
exponent separately is that a BFP seam recorded as float has thrown away the
only thing comparable bit-exactly (`tools/ref9b/seam_stream.h:11-19`). If the
exponents disagree the right answer is to compare values and say so, which is
route 2, not to widen a window until the disagreement fits inside it.

**Putting the driver bench under `sim/`. REJECTED.** `sim/regress.sh` globs
`sim/tb_*.vhd` and `tb/tb_*.vhd` into gate rows (`SUITE_DIRS` at `:783`, glob
at `:790`), and this bench needs a generated vector file. An absent file would
turn the shared gate red for every concurrent track, which the project has
already been bitten by. VERIFIED by reading `SUITE_DIRS`, not assumed, and
MEASURED separately: `tools/` appears in `regress.sh` only inside two comments.

---

## 8. Measurement traps hit, including my own

**T1. My own, and it is the reason section 5.3 exists.** I formed the whole
hypothesis from reading `bfp_pack.vhd` and `reg_put`, and I was ready to
generalise "the hardware clamps" from one unit. `seq_vec_res` contains a
genuine `shift_left` in its operand alignment, and a grep for left shifts would
have produced a counter-example that is not one. The output exponent is still
capped at `max(ex, ee)`. **A left shift somewhere inside a unit says nothing
about whether the unit's OUTPUT can gain precision**, and only reading the
whole exponent chain settles it.

**T2. The comparison numbers are identical at every `(N, Q)`, which looks like
a broken harness and is not.** 341 divergences and 368 quiet blocks at
`N = 8, 16, 64, 172` and `Q = 0, 12, 20`. Two separate reasons, and I checked
both rather than accepting the coincidence. **Q:** DERIVED, the difference
`hw_exp - ref_exp = msb_pos(amax_int) - sh - 14` has no `Q` term at all, so
`Q`-independence is a property of the rules. **N:** the magnitude sweep bands
are aligned to the threshold -- a band of values below `2^15` is quiet for
every `N`, and a band above it is loud for every `N >= 8` with probability
`1 - 2^-N`. **So this case set is deliberately N-insensitive and must not be
read as evidence that the rules are N-independent.** The evidence for that is
the SCORE line, which passed against the entity at each `N` separately.

**T3. I predicted `reg_put` could not saturate, and it can.** Section 5.4. The
prediction was that normalising to bit 14 leaves a bit of headroom; the
round-half-up bias eats it, on both rules equally. It cost nothing because it
was written down as a prediction and then measured, but had it gone into the
document as a fact it would have been a third false claim in a file about false
claims.

**T4. My own, and the worst one: this harness had the `PASS 0` defect, in a
document about checkers that cannot fail.** The first version of `--score`
counted mismatches and printed `BIT-IDENTICAL` when the count was zero. It was
never shown to fail on an EMPTY comparison, so I pointed it at a log
containing nothing but a GHDL error. MEASURED, before the fix:

```
$ : > empty.txt        &&  bfpeq --score empty.txt   | tail -1
SCORE 0 compared, 0 mismatched vs rtl/bfp_pack.vhd -- BIT-IDENTICAL
$ echo 'ghdl:error: ...' > err.txt && bfpeq --score err.txt | tail -1
SCORE 0 compared, 0 mismatched vs rtl/bfp_pack.vhd -- BIT-IDENTICAL
```

The script redirects GHDL's `stderr` into the same log it later scores, so a
failed elaboration or a bad generic would have produced exactly this, and the
run would have reported the transcription bit-identical to an entity that never
executed. **This is `regress.sh --only` printing `PASS` on `PASS 0`, reproduced
inside a tool written by someone who had just re-read the note about it.**

Fixed by two guards -- at least one `OUT` line, and the entity's own `CASES`
trailer present and equal to the number parsed. MEASURED after the fix, on
three forms of empty:

```
empty log      : SCORE-BAD no OUT lines parsed ... SCORE 0 compared, 2 mismatched
ghdl error log : SCORE-BAD no OUT lines parsed ... SCORE 0 compared, 2 mismatched
truncated log  : SCORE-BAD ... has no CASES trailer ... SCORE 100 compared, 1 mismatched
real log       : SCORE 760 compared, 0 mismatched -- BIT-IDENTICAL
```

The truncated case is the one the OUT-line guard alone would have missed: 100
real comparisons, all correct, and the run had died two thirds of the way
through its vector file.

**T5. The seven mutants were all mutants of MY code, never of the RTL.** That
is deliberate -- the checker under test is the comparison, not `bfp_pack` --
but it means this document contains **no evidence that a defect in
`rtl/bfp_pack.vhd` would be caught by anything here**, and it should not be
read as coverage of that entity. It is coverage of the transcription.

---

## 9. Explicitly NOT verified

- **No capture from `llama_top` was compared against anything.** Every claim
  about the RTL's behaviour in section 5.3 comes from READING the shift
  computation, not from running it. `bfp_pack` is the only entity in this
  document that was executed, and it is the one that turned out not to be on
  the path. **The four units that are on the path have not been run against
  this or any other reference**, and that remains the single missing artefact,
  the same one item 12 named.
- **The rate at which the clamp would fire on the `reg_put` seams is not
  determined.** See section 7.
- **`R_H`'s divergence is stated structurally, not measured.** The SwiGLU stub
  has no maximum scan, so it cannot agree with a normalising rule except by
  accident; by how much it disagrees on real data needs a capture.
- **Whether the shipping `rtl/swiglu.vhd` would clamp is not determined.** It
  is not in the `llama_top` path (`llama_top.vhd:1349-1352` records that it has
  no D-vec adapter) and was not read.
- **Nothing here says the hardware's rule is the RIGHT one.** Clamping loses
  precision that the float reference retains, and on a quiet block that loss is
  real arithmetic error, not a representation choice. This document establishes
  only that the two differ and where; whether the clamp should be removed from
  the RTL is a design question nobody has asked and this track does not answer.
- **The 760-case set reaches the int32 rails only through the 16 named edges.**
  The magnitude sweep is 24 vectors in each of 31 bands, so the high bands are
  thinly sampled. No divergence was found in any loud band at any setting, but
  that is 24 samples per band, not a proof.
- **`ref/matvec_int4.c`'s `bfp_pack_vec` (`:565`) was not run against the
  entity.** It is the repo's other model of the same rule and it reads as
  identical, but "reads as identical" is exactly what this document exists to
  distrust. It would be a cheap addition to `--score`.

---

## 10. Files

| file | what it is |
|---|---|
| `tools/ref9b_bfp_equiv_tb.vhd` | drives the shipping `rtl/bfp_pack.vhd` over a file of int32 vectors and prints `(exp, mantissas)`. Deliberately not under `sim/`. |
| `tools/ref9b_bfp_equiv.c` | the transcription, `reg_put`'s rule, the case generator, `--score` against the entity and `--compare` between the rules. `-DREF9B_BFPEQ_MUT=n` for the seven mutants. |
| `tools/ref9b_bfp_equiv.sh` | the whole run: analyse, build, score, teeth, compare, at five `(N, Q)` settings. |
| `tools/ref9b_stream_norm.py` | reads any `.r9bs` stream and reports the normalisation signature per record and per seam, which identifies the producing RULE without knowing the producer. |

Reproduce:

```sh
bash tools/ref9b_bfp_equiv.sh
python3 tools/ref9b_stream_norm.py /mnt/storage/ref9b/ref_bfp.r9bs --list-under
python3 tools/ref9b_stream_norm.py /mnt/storage/ref9b/ref_bfp.r9bs --tok 4 --per-seam
```

The gate is untouched: no `sim/tb_*.vhd` is added or changed, so
`BASELINE_PASS` stays where it was.

---

## 11. Corrections to
`docs/debugging/2026-08-29_9b-whole-model-reference.md`

Appended here rather than edited into that file, which this track does not own.

1. **Section 9, the repack bullet.** "The rule (shift so the max lands in bit
   14 ...) is the same and the exponent convention is the same" is **WRONG**.
   The rule is the same only when the maximum reaches bit 15 of the input grid;
   below that `bfp_pack` clamps and `reg_put` does not. The same bullet's
   "VALUE-equivalent" is **MEASURED CORRECT**, exactly, on 760 cases at five
   settings.
2. **The same bullet names the wrong comparator.** `rtl/bfp_pack.vhd` is not
   instantiated in `rtl/llama_top.vhd`. The units that produce the `reg_put`
   seams are `rmsnorm_rs`, `seq_vec_res`, `gdn_y_emit` and `attn_emit`, plus
   the `gen_vstub` SwiGLU stub for `R_H`.
3. **Section 5.8's one-LSB resolution claim is sound but its scope is
   narrower than it reads.** It is demonstrated reference-against-reference.
   Against a capture from `llama_top` it will fire on the repack difference
   first, on up to 193 of 490 records per token, and unconditionally on the 32
   `R_H` records.

## 12. Corrections

None yet. Append here rather than editing anything above.
