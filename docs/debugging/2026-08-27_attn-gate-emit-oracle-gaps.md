# attn_gate and attn_emit: five checks that looked strong and were not, and one algebra error the coverage assertion found

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. New files, never committed with a defect
present. GHDL 1.0.0 mcode backend, `ghdl -r` direct, no `ghdl -e`.
**Units:** `rtl/attn_gate.vhd` (subsystem C sites 6b/6c/6d/6e) and
`rtl/attn_emit.vhd` (site 6f), with `ref/attn_gate_vec.c` and
`ref/attn_emit_vec.c`.

Companion to the three 2026-08-27 write-ups from the four units before these
(`attn-kv-quant-abs-resize`, `attn-softmax-offset-resize`,
`attn-recip-mutation-gaps`) and to
`2026-08-27_attn-scalar-publication-order.md` from the same session.

## The question

Neither unit's RTL ever produced a wrong value. Both passed their testbench
bit-exactly on the first run in all three handshake configurations. So the
question was again the one that matters: **which properties did those passes
actually test?**

Mutation testing answered it five separate times, and in every case the answer
was that a check which looked airtight was reading something it shared with the
thing it was checking, or was sampling a domain where the witness set was two
points wide.

## The answer

**Five real gaps, all in the CHECKS and none in the RTL, plus one algebra error
of my own that a coverage assertion caught by demanding a value that could not
exist.** In order of how badly they were hiding:

| # | The gap | Found by | The witness |
|---|---|---|---|
| 1 | `attn_emit`'s `y_exp` was an emitted golden that **no oracle read**. ORACLE 1 formed the truth from `(e_min, shp)` directly and never mentioned `y_exp`. | reference mutation R8 | `y_exp = e_min + shp` survived every oracle |
| 2 | `attn_emit`'s peak-window oracle read the path's own `amax`, so it compared a mutated `amax` against the `shp` derived from it. | reference mutation R10 | `amax` folded over the UNALIGNED values survived |
| 3 | The `attn_gate` sigmoid's floor-versus-round has a witness set **2 points wide out of 131,071**. | RTL mutation M7, reference mutation G7 | `zg = -6334` and `zg = 17992`, nothing else |
| 4 | `attn_emit`'s pass-A group-index lookup corrupts only `amax`, so it is invisible unless the PEAK is in the last two elements of a group. | RTL mutation E13 | peak at `GRP_N-1` with grids that differ |
| 5 | `hdr_valid` and the value it qualifies are **two claims** and need two capture points. | RTL mutation E16 | `hdr_valid` raised at `start` |
| 6 | My own derivation said `-32768` was unreachable as a mantissa. It is reachable. | the coverage assertion, by demanding it and failing | `y_pre = -(2^21 - 1)`, equal grids |

## The procedure that produced it

1. **Build the C reference first, with oracles that share none of the RTL's
   fixed-point machinery.** For `attn_gate` that is five oracles; for
   `attn_emit`, five.
2. **Mutation-test the C reference before trusting the RTL against it.** This
   is where gaps 1 and 2 were found, and both are the *restatement trap* one
   level up from the one `attn_score_q12_vec.c` records: that file found a
   shared CONSTANT making a check vacuous; these are a shared *quantity* and a
   *never-read output*.
3. **Mutation-test the RTL, in three handshake configurations, then READ every
   survivor.** A survivor is a question with three possible answers -- a real
   gap, an equivalence, or a mutation that changed nothing -- and only reading
   separates them. Gaps 3, 4 and 5 are the "real gap" answers.
4. **When a survivor is a real gap, find the WITNESS SET before widening the
   generator.** For gap 3 the honest move was to enumerate the domain in Python
   and discover it is two points, then plant those two points. Adding "more
   random vectors" would have needed ~65,000 elements per witness and would
   still have been luck.
5. **Let the coverage assertion invent the shape, and believe it when it
   fails.** Gap 6 is the one where the tool was right and I was wrong.

## The evidence

### C reference self-mutation, `ref/attn_gate_vec.c` -- 13 of 17 killed

| # | mutation | result |
|---|---|---|
| G1 | site 6b shifts `p` instead of `p+1` | killed, oracle 1 |
| G2 | site 6b FLOORS instead of rounding | killed, oracle 1 |
| G3 | site 6c's Q moved on the PATH only | killed, oracle 2 |
| G4 | site 6c's Q moved on the ORACLE only (a check of the check) | killed, oracle 2 |
| G5 | the left-shift clamp lowered 32 -> 31 | **SURVIVED -- value-equivalent** |
| G6 | interpolation dropped, nearest lower entry | killed, oracle 3c (sweep) |
| G7 | the interpolation ROUNDS where it must floor | killed, oracle 3c (sweep) |
| G8 | the Q30 -> Q15 stage FLOORS instead of rounding | killed, oracle 3b (sweep) |
| G9 | the u16 top clamp is 32768 | killed, oracle 3f |
| G10 | the low domain guard is `<` not `<=` | **SURVIVED -- equivalent** |
| G11 | the high domain guard is `>` not `>=` | **SURVIVED -- equivalent** |
| G12 | the index scale is 8, so the cone spans 32.0 | killed, oracle 3c (sweep) |
| G13 | the table built on the wrong grid step | killed, oracle 3a |
| G14 | site 6e shifts 14 instead of 15 | killed, oracle 4 |
| G15 | site 6c's sat32 removed | killed, oracle 2 |
| G16 | site 6b's s24 saturate widened to s25 | **SURVIVED -- unreachable** |
| G17 | the index split uses the offset before the `*16` | killed, oracle 3c (sweep) |

**Four of the kills say `(sweep)`, and that word is the finding.** G7 SURVIVED
the per-element oracles run over the 2,240-element vector set and is killed
only by the EXHAUSTIVE sweep of the interpolated domain that was added because
of it. The interpolated domain is 131,073 points wide, so it can simply be
enumerated; sampling it was a choice with no justification.

The three survivors, read rather than assumed:

- **G5.** `|g_mant| <= 2^15`, so at a left shift of 31 any non-zero word
  already reaches `|value| >= 2^31` and `sat32` clips it to the same rail a
  shift of 32 gives; a zero word gives zero at every shift. **Value-equivalent
  and flag-inequivalent**: `g_mant = -1` at shift 31 lands on `INT32_MIN`
  exactly and does not set the saturation flag, where at 32 it does. The
  oracles check values, so it survives them; the flag is a per-case sticky in
  the RTL and other elements of the same case saturate anyway, so the RTL
  mutation M5 survives too. Recorded as value-equivalent, NOT as equivalent.
- **G10.** At `zg = -16*2^12` exactly the offset is 0, the index is 0, the
  fraction is 0, and the interpolation returns `SIG_ROM[0] = 121`, whose
  `round_shift(121, 15)` is 0 -- identical to the clamp. **Equivalent.**
- **G11.** At `zg = +16*2^12` the offset is `2^17`, the index computes to 512
  and is clamped to 511 by `fixed_pkg`'s own guard, the fraction is `2^12`, and
  the interpolation returns `SIG_ROM[512]`, whose `round_shift(., 15)` is 32768
  -- clamped to 32767, identical. **Equivalent.** Note this is the one place
  where the RTL is NOT equivalent (mutation M12 is killed): the RTL slices the
  offset to 17 bits, so `2^17` wraps to 0 and the guard is load-bearing there.
  The two sides differ and both are correct as written.
- **G16.** Unreachable under the `|o| <= 127*s` contract. Consistent with the
  claim the width guard makes; the same argument as `attn_recip`'s R8/N6 pair.

### RTL mutation, `rtl/attn_gate.vhd` -- 23 of 26 killed

Configurations: **A** = `X_GAP 2, Y_GAP 5, ACK_LAG 4` (shipped); **B** = every
gap 0 (degenerate); **C** = `X_GAP 1, Y_GAP 20, ACK_LAG 12`.

| # | mutation | A | B | C |
|---|---|---|---|---|
| M1 | site 6b shifts `p` not `p+1` | killed | killed | killed |
| M2 | site 6b FLOORS | killed | killed | killed |
| M3 | the branch decision puts `sh = 0` in the LEFT branch | **survived** | **survived** | **survived** |
| M4 | the right-shift clamp one lower than `G_W` | killed | killed | killed |
| M5 | the left-shift clamp lowered to 31 | **survived** | **survived** | **survived** |
| M6 | the cone offset narrowed with `resize` (THE TRAP) | killed | killed | killed |
| M7 | the interpolation ROUNDS where it must floor | killed | killed | killed |
| M8 | the ROM index from the LOW bits of the offset | killed | killed | killed |
| M9 | interpolation dropped, nearest lower entry | killed | killed | killed |
| M10 | the u16 clamp is `2^GQ` | killed | killed | killed |
| M11 | the low domain compare `<` not `<=` | **survived** | **survived** | **survived** |
| M12 | the high domain compare `>` not `>=` | killed | killed | killed |
| M13 | the table delta one bit narrow | killed | killed | killed |
| M14 | the cone's Q30 -> Q15 round bias dropped | killed | killed | killed |
| M15 | site 6e shifts `GQ-1` | killed | killed | killed |
| M16 | site 6e's round bias dropped | killed | killed | killed |
| M17 | the reciprocal read LIVE, not latched (RULE 2) | killed | killed | killed |
| M18 | the gate exponent latched one state LATE | killed | killed | killed |
| M19 | `cfg_taken` never published (the ORDERING guard) | killed | killed | killed |
| M20 | `done` a bare one-cycle pulse (RULE 1) | killed | **survived** | killed |
| M21 | explicit `done_r` clear in the ack branch | killed | killed | killed |
| M22 | `done` before the pipeline has DRAINED | killed | killed | killed |
| M23 | the pipeline advances under a blocked output | killed | **survived** | killed |
| M24 | `x_ready` ignores the stall | killed | **survived** | killed |
| M25 | site 6b's s24 saturate removed | killed | killed | killed |
| M26 | site 6c's sat32 removed | killed | killed | killed |

M7's kill message is the witness verbatim:
`case 0 elem 7: g15 got 5756 want 5755  (sites 6c/6d: g_mant -6334 qg_exp 12)`.

The three survivors: **M3** is exact (`round_shift(v, 0) = v = v sll 0`, so
both branches compute the same thing at `sh = 0`); **M5** is G5's RTL twin,
value-equivalent and flag-inequivalent, and its survival on BOTH sides is the
independent confirmation; **M11** is G10's RTL twin and is equivalent for the
same reason.

### C reference self-mutation, `ref/attn_emit_vec.c` -- 12 of 13 killed

Run AFTER the RTL existed, not before, and that is a deviation from this
project's own procedure worth stating plainly: the reference was
oracle-verified before the RTL was written but not self-mutated until
afterwards. The two gaps it then found (R8, R10) were gaps in the reference
that the RTL happened not to have.

| # | mutation | result |
|---|---|---|
| R1 | `TARGET_MSB` 14 -> 13 on the PATH | killed, oracle 2 |
| R2 | `TARGET_MSB` 14 -> 13 on the ORACLE (a check of the check) | killed, oracle 2 |
| R3 | the alignment ROUNDS where it must floor | killed, oracle 4 |
| R4 | the pack FLOORS where it must round | killed, oracle 1 |
| R5 | `sat16` removed | killed, oracle 5 |
| R6 | the grid scan takes the MAXIMUM | killed, the negative-shift trap |
| R7 | `msb_pos` one too large | killed, oracle 2 |
| R8 | `y_exp = e_min + shp` | killed **after the fix**; SURVIVED before |
| R9 | `shp` not clamped at 0 | killed, oracle 1 |
| R10 | `amax` over the UNALIGNED values | killed **after the fix**; SURVIVED before |
| R11 | the alignment shift with the wrong sign | killed, the negative-shift trap |
| R12 | `msb_pos(0)` treated as `TARGET_MSB` | **SURVIVED -- equivalent** |
| R12b | `msb_pos(0)` treated as `TARGET_MSB + 6` | killed **after the fix**; SURVIVED before |

R12 is equivalent by arithmetic: `shp = max(0, p - 14)` is 0 for `p = 0` and
for `p = 14` alike. R12b moves `p` to 20, which is NOT equivalent, and was
added specifically to check that the new all-zero-layer oracle has teeth.

### RTL mutation, `rtl/attn_emit.vhd` -- 21 of 22 killed

Configurations: **A** = `M_GAP 3, ACK_LAG 4`; **B** = degenerate; **C** =
`M_GAP 11, ACK_LAG 9`.

Killed in all three: E1-E16 and E22 (the pack shift both ways, the pack's
round, a pass-B-only alignment round, `msb_pos`, the `e_min` seed, the
minimum-versus-maximum, the abs `resize` trap, `sat16`, the `amax` source, the
`y_exp` sign, both group-index lookups, `e_grid` read live, `y_exp` published
in `S_DONE`, `hdr_valid` raised at `start`, and the index pipeline).
Configuration-specific: E17 and E20 and E21 killed by A and C only; E18 killed
by **B only**. Surviving: **E19**.

**E19 is equivalent, and the mechanism is worth recording** because it is not
obvious from the source. The mutation removes the `m_valid_r = '0'` guard in
`S_DONE`. That guard is provably redundant: the drain counter lives inside
`if emit_en = '1'`, and `emit_en` is low whenever an unaccepted mantissa stands
at the output, so once the last mantissa is driven the counter can only advance
in a cycle where `m_ready` is high -- which is the same cycle the handshake
clears `m_valid_r`. Reaching `S_DONE` therefore already implies the last
mantissa was accepted. Confirmed by instrumenting the mutant: over 40 layers,
`done` rose with `m_valid = '0'` and `m_cnt = 96` every single time.

```
tbp.vhd:247:11:@5055ns:(report note): DONE ROSE with m_valid='0' m_cnt=96
tbp.vhd:247:11:@10135ns:(report note): DONE ROSE with m_valid='0' m_cnt=96
tbp.vhd:247:11:@15215ns:(report note): DONE ROSE with m_valid='0' m_cnt=96
```

The guard is kept anyway: the redundancy is a property of the drain gating, and
a later change to that gating would silently make it load-bearing. That
reasoning is now in the RTL next to the guard.

### The algebra error, and how the coverage assertion caught it

The reference's ORACLE 5 originally derived the mantissa range like this:

> `shp` is defined so that `amax < 2^(shp+15)`, and `|y_al| <= amax`, so
> `y_al + 2^(shp-1) > -2^(shp+15) + 2^(shp-1)` and the floor is at least
> `-2^15 + 1 = -32767`. So **-32768 is unreachable**.

The last step is false. `floor(x)` for `x` anywhere in `(-32768.0, -32767.5]`
is `-32768`, not `-32767`. The correct statement is that the mantissa range is
`[-32768, 32767]`, `sat16`'s LOW rail never clips, and its HIGH rail clips
exactly the single value 32768.

**Nothing in the oracle suite would have caught this**, because the wrong bound
is looser at one end and the correct values all sit inside it. What caught it
was the coverage assertion written from the wrong derivation: it DEMANDED that
`-32767` appear, could not produce it in 40 layers, and the hunt for a shape
that would produce it found the algebra instead. The witness is a single
element at `-(2^21 - 1)` with equal grids: `amax = 2^21 - 1`, `shp = 6`, and
`round_shift(-2097151, 6) = floor(-32767.484) = -32768` exactly.

The wrong paragraph is kept in `ref/attn_emit_vec.c` as a marked correction
rather than deleted, per this project's convention.

## Measured and REJECTED -- do not retry

- **"More random vectors" as the answer to a surviving mutation.** For the
  sigmoid's rounding mode the witness set is 2 points out of 131,071. At the
  generator's shapes a random element reaches one of them with probability
  about `1.5e-5`, so 2,240 elements give an expected count of 0.03. Enumerating
  the domain and planting the two points is the only workable move, and the
  domain is small enough to enumerate precisely because the argument is Q12 and
  the cone's span is 32.0.
- **Checking the peak window against the path's own `amax`.** It is a
  restatement, not a check: mutation R10 changes `amax` and the oracle then
  checks the changed value against the `shp` derived from it. The oracle now
  recomputes the peak from the aligned array. Do not "simplify" it back to
  reading `r.amax`.
- **Deriving the truth in ORACLE 1 from `(e_min, shp)` rather than from
  `y_exp`.** Arithmetically identical and strictly worse: it leaves `y_exp`
  read by nothing, so a sign error on the one scalar the consumer needs
  survives every check. Form the truth the way a consumer forms it.
- **Excluding the sigmoid's clamps from the magnitude bound.** The first
  version did, on the reasonable-sounding grounds that the C spec's pinned
  32767-instead-of-32768 is a deliberate deviation. It costs 0.996 counts
  against a bound of 2.0397, so the bound covers it with room -- and excluding
  it left the clamp VALUES unchecked by any magnitude oracle at all. Worse, the
  exclusion was written as `clamped = lo_clamp || hi_clamp || g15 == 32767`
  and then wrapped around the counter for "32767 reached from the
  interpolation", which could therefore never count. A coverage counter nested
  inside a guard that excludes what it counts is the same class of mistake as a
  guard no vector reaches.
- **Trusting a structural argument for the ordering rule.** Both units separate
  the scalar from the stream by several states, which is a correct argument and
  is not a test. Both `ord_chk` guards are exercised by a mutation
  (`attn_gate` M19, `attn_emit` E15 and E16).

## Measurement traps hit, including my own

- **`--stop-time=900ms` on a 17-stage pipeline.** The earlier scripts in
  `sim/` use it and it is fine for those units. Here the longest legitimate run
  is 491 us, so 900 ms is 90 million simulated cycles for every mutation that
  HANGS -- and several interface mutations do hang by construction. One hung
  configuration ran over 25 minutes of wall time and had to be killed, which
  also corrupted the suite's output. Both new scripts use `--stop-time=20ms`,
  a 40x margin over the longest real run.
- **Editing a shell script while bash is running it.** bash reads a script
  incrementally by byte offset, so an edit mid-run shifts everything after the
  cursor. The gate suite had to be discarded and restarted. Kill first, edit
  second.
- **`pkill -f <pattern>` matching my own shell.** The pattern that matches the
  mutation script also matches the tool invocation that contains it, so the
  `pkill` killed the caller and the edit that followed it never ran. Kill by
  PID.
- **A function formal named `v` hiding the pipeline's valid vector.** VHDL is
  case-insensitive, so `function sat_t(v : signed)` shadows `signal v` for the
  whole body. GHDL warns (`-Whide`) and the body happened not to read it, so it
  was harmless here -- but it is the identical shadowing that cost a run in
  `tb_attn_recip`, where a variable named `nhead` hid the generic `NHEAD` and
  the failure read as a malformed vector file. Both new units use `a`.
- **Checking a combinational freeze on the DELAYED sample.** `tb_attn_emit`'s
  first `x_re` check looked at the cycle AFTER the frozen one and fired on
  correct behaviour, 12 times in the first case. `emit_en` is combinational, so
  the cycle in which `m_valid` is high and `m_ready` is low is the cycle in
  which `x_re` must already be low. Same off-by-one-cycle shape as
  `tb_attn_score_q12`'s `p_ready` check.
- **`numeric_std`'s `*` on `signed` returns `left'length + right'length`.**
  `s1_o * signed('0' & r_l)` is 36 + 17 = 53 bits, not 52, and the first
  version declared the product register at `O_W + R_W`. GHDL's bound check
  catches it at elaboration, so it cost one run rather than a defect -- but the
  tempting fix is a narrowing `resize` on the result, which is exactly what
  this subsystem has been bitten by twice. The register was widened instead.

## Open, not yet answered

- **No Vivado.** No routed result exists for either unit. `attn_gate` declares
  roughly 1,050 flip-flops at the shipped generics (17 stages, the widest being
  the 53-bit product and the 48-bit left-shift path) and contains **three**
  datapath multiplies; `attn_emit` declares roughly 260 and contains **none**.
  Both figures are counts from the signal declarations, not measurements, and
  neither Fmax is known.
- **The DSP number for `attn_gate` is DERIVED from operand widths, not
  measured.** Stage 2 is 36x16 which exceeds 27x18 and takes 2 tiles; stage 11
  is 24x12 and stage 15 is 24x16, one tile each. That is 4, against the C DSP
  skeleton's `1 (sigmoid) + 2 (6b) + 1 (6e) = 4` for the same sites. The
  skeleton's own figure for the narrowed sigmoid cone is itself an ESTIMATE at
  1, and the same document records that on the sigmoid cone narrowing the
  interpolation delta ALONE changed no DSP count. Both operands are narrowed
  here. Only synthesis settles it, and another agent owns that measurement.
- **`AREG`/`BREG` is not pinned on any of the three multiplies.** C spec 2.6
  makes registered operand muxes normative (246 MHz combinational versus
  340 MHz registered at the same 128 DSP). All three read registered signals
  written in the previous stage, which is the idiom, but no attribute is set
  and no build has confirmed it.
- **`ovr`, `ysat`, `zsat`, `o_sat` and `err` have no policy.** They are
  observable and nothing consumes them -- the same state every flag in this
  subsystem has been in since `attn_kv_quant`.
- **Neither unit is exercised at its production element count.** `attn_gate`
  was run at `N = 256`, which IS production, but `attn_emit`'s production shape
  is `2 x 1536 = 3072` and the largest run here is `2 x 384 = 768`. Nothing in
  the unit is sensitive to the count beyond the address width, but that is an
  argument and not a run.
- **`attn_gate` serves ONE query head per job.** The real schedule sweeps 12
  per layer, and the interleave is not built here.
