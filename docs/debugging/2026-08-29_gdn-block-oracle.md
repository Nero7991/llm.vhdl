# Subsystem B's block-level oracle, and defect B-BLK-1

2026-08-29. TRACK B-BLOCK. GHDL mcode, `--std=08 -frelaxed`, no hardware.

## The question, verbatim

> **`ref/gdn_block_vec.c` does not exist** -- exactly the artefact class that
> found `attn_block` computing 64 of 64 mantissas wrong under a column of
> well-verified units.
>
> **Subsystem B has no block-level oracle.** Its units are individually well
> verified [...] But nothing checks the **composition**.
>
> Build `ref/gdn_block_vec.c`, a block-level oracle for `rtl/gdn_block.vhd`,
> and compare it against the RTL. [...] If it diverges, that is the most
> valuable outcome available and must NOT be worked around.

Plus: gate `tb_gdn_block`'s four printed checks, which SPECREC flagged as "the
third instance of a shape already fixed twice".

## The answer

**It diverges, in exactly one place, and that place is a real defect in
shipping RTL.**

`rtl/gdn_block.vhd` feeds value head `h` from key head
`h / (VAL_HEADS/KEY_HEADS)` -- the GQA-style contiguous grouping. The model
feeds it from `h mod KEY_HEADS`, because `qwen35.cpp` broadcasts q and k with
`ggml_repeat_4d`, and every ggml broadcast TILES rather than groups. Call it
**defect B-BLK-1**. At the bench shape (2 key heads, 4 value heads, DIM 32,
2 tokens) it moves **128 of 256 y mantissas, 2048 of 4096 final state
mantissas and 20 of 128 final state exponents** -- precisely value heads 1
and 2, the two the two rules disagree on. At the real 9B shape (16 key heads,
32 value heads) it is **30 of 32 value heads**.

**Everything else in the composition is bit-exact on the first comparison.**
With the oracle told to use the RTL's mapping, y, y_exp, the final state, the
final state-exponent table and all four status flags agree exactly: 0 of 256,
0 of 4096, 0 of 128. So the conv, the tap masking, the tap-exponent pairing,
silu over the whole conv output, both L2 paths and their two different output
grids, the scalar path, the recurrence with its three 2026-08-26 amendments,
the state write-back layout, site 12, the output rmsnorm, the z gate and
site 13 are all correctly wired. That is a much better result than subsystem C
got, and it is worth saying so plainly.

The four printed flags in `tb_gdn_block` are now gated, and all four gates were
shown to fire.

## The procedure, in the order it was run

Each step says what it controls for.

1. **Read the spec's normative sections before any code.** B spec 1.1 (the
   flow, taken from the reference), 1.4 (interface), 1.6 (the conv ring and
   masking), 2.1.1-2.1.6 (the whole numeric contract), 3.3, and section 4 (the
   27B/9B retarget). This is what the oracle's dataflow is written from.
   Controls for: an oracle transcribed from the RTL agrees with it by
   construction (the `m7` mutant).

2. **Decide, per stage, whether to transcribe or to compose.** Four of B's
   stages are approximation kernels with their own double oracles and their own
   benches -- `rmsnorm_bf`, `gdn_silu`, `gdn_scalar`, `l2norm_rs`. A second
   transcription of an approximation kernel measures self-consistency and
   nothing else; that is exactly how the collapsed L2 recipe survived 55
   passing cases. Those four are `#include`d as cores.
   `ref/gdn_emit_chain_vec.c` set the precedent and states the same reason.
   The three short normative code blocks -- the conv, the recurrence, the two
   emit sites -- are transcribed from the spec.
   Controls for: a golden that drifts from the unit it certifies.

3. **Extract the two cores that were still trapped inside a `main()`, and
   prove the extraction is inert.** `gdn_scalar_int()` out of
   `ref/gdn_scalar_vec.c`, and a `GDN_CHAIN_INCLUDE` guard onto
   `ref/l2norm_rs_vec.c`. Both verified byte-identical on the emitted vector
   file: the scalar generator at SP_Q 12, 15, 18 and 20, the L2 generator at
   N 32, 64 and 128.
   Controls for: a refactor that silently changes the golden it was supposed
   to preserve.

4. **Write `ref/gdn_block_vec.c` and give it a second, independent
   double-precision oracle over the same stimulus.** The double path shares no
   integer helper, no grid, no exponent and no LUT. It is the only check that
   can see a wrong RECIPE rather than a wrong transcription.
   Controls for: a shared misunderstanding of the dataflow that both the oracle
   and the RTL happen to hold.

5. **Teeth-check the oracle's own self-gates before believing any of it.**
   Removing `fx_init()` and removing `bf_resolve_eps()` are the two failures
   that bit `ref/gdn_emit_chain_vec.c`, each as a silent wrong answer.
   Controls for: a bound that has never been shown to fail.

6. **Write `sim/tb_gdn_block_vec.vhd`, carrying the stimulus in the file.**
   Not regenerated in VHDL: two sources of truth for the inputs make a stimulus
   divergence read as an arithmetic failure. The producer contracts are the
   ones `tb_gdn_block` established, including the REGISTERED scalar source.
   Controls for: a bench that lets the block sample a port a cycle earlier than
   any real producer could present it.

7. **Run it. Read the shape of the mismatch, not just its size.** 128 of 256,
   2048 of 4096, first mismatch at head 1 element 0, head 0 clean. Halves and a
   head boundary, not a smear.
   Controls for: treating a structured divergence as noise.

8. **Bisect by flipping ONE decision in the oracle, in scratch, and checking
   whether the divergence goes to zero.** It did: 0 / 0 / 0.
   Controls for: a divergence that is really several defects added together.

9. **Settle which side is right from the MODEL, not from either
   implementation.** `ggml_compute_forward_repeat_f32` in
   `~/GitHub/llama.cpp.upstream/ggml/src/ggml-cpu/ops.cpp` writes destination
   row `i1*ne01 + k1` from source row `k1`, so destination head `h` reads
   source head `h % ne01`. Confirmed a second time from the other direction:
   in the non-fused decode path `ggml_mul(s, k)` broadcasts a `[S, 1, H_k]`
   operand against an `[S, S, H_v]` one, and every ggml broadcast indexes the
   smaller operand modulo its own extent. And `q_conv` is a
   `ggml_view_4d(..., head_k_dim, num_k_heads, ...)`, so dim 1 really is the
   key head index.
   Controls for: deciding a contest between two implementations by preferring
   one of them.

10. **Check nothing else in the repo compensates.** No packer permutes key
    heads (`tools/pack_model_fk33.py`, `tools/gen_layer_program.py`), and the
    only two mentions of the mapping anywhere are `rtl/gdn_block.vhd`'s `VPK`
    constant and its single use.
    Controls for: calling a deliberate convention a defect.

11. **Quarantine the defect rather than fix it or hide it.** The oracle's
    DEFAULT is the model. A `KMAP` argument selects the RTL's rule, the vector
    file carries a `kmap` flag, and the bench asserts that flag against its own
    `KMAP_DIV` generic so the two cannot silently disagree. The gate row runs
    `div` and the bench prints a loud note saying so on every run.
    Controls for: turning the shared gate red for five live tracks overnight,
    and, in the other direction, for the defect being quietly forgotten.

12. **Gate `tb_gdn_block`'s four printed flags**, and teeth-check each one by
    flipping its expectation generic.
    Controls for: a check that cannot fail, which mutation testing will NOT
    catch, because mutating what it watches changes nothing.

13. **Mutation-test the WIRING**, with a CONTROL row and three verdicts.

## The evidence

### The first comparison, raw

```
$ ./gen_gdn_block_vec gdn_block_vec.txt 2 4 32 2 2 mod
seed 20260829  [committed default]
gdn_block_vec: KH=2 VH=4 D=32 KCONV=4 tokens=2 kmap=mod (the model) -> gdn_block_vec.txt
  flags: err_conv=0 err_g=0 err_se=0 y_sat=0 (0 saturating tokens excluded from the oracle)
  worst end-to-end error vs the double oracle: 9.9698 LSB of the y grid (token 0, element 34)
  elements compared: 256 of 256;  over 64 LSB: 0 (0.00%)
  OK

$ ghdl -r --std=08 -frelaxed tb_gdn_block_vec --stop-time=200ms --max-stack-alloc=0
tb_gdn_block_vec.vhd:760:11:@4594500ps:(report note): tb_gdn_block_vec: FIRST y MISMATCH at token 0 head 1 element 0: got 10365 expected 8469
tb_gdn_block_vec.vhd:794:5:@4594500ps:(report note): tb_gdn_block_vec: y mismatches 128 of 256, state mismatches 2048 of 4096, state-exponent mismatches 20 of 128
tb_gdn_block_vec.vhd:801:5:@4594500ps:(assertion failure): tb_gdn_block_vec: 128 of 256 y mantissas disagree with the oracle
ghdl:error: simulation failed
```

### The bisect: one decision accounts for all of it

`hk = h % KH` replaced by `hk = h / (VH/KH)` in the oracle, in scratch,
nothing else touched:

```
$ ./gbv_div gdn_block_vec.txt 2 4 32 2 2
  worst end-to-end error vs the double oracle: 6.0877 LSB of the y grid (token 0, element 34)
  OK
$ ghdl -r ... tb_gdn_block_vec ...
tb_gdn_block_vec.vhd:794:5: tb_gdn_block_vec: y mismatches 0 of 256, state mismatches 0 of 4096, state-exponent mismatches 0 of 128
tb_gdn_block_vec.vhd:839:5: tb_gdn_block_vec: PASS, 256 y elements, 4096 state mantissas and 128 state exponents bit-exact against gdn_block_vec.txt
```

### The model, quoted

`ggml/src/ggml-cpu/ops.cpp`, `ggml_compute_forward_repeat_f32`:

```c
for (int i1 = 0; i1 < nr1;  i1++) {
    for (int k1 = 0; k1 < ne01; k1++) {
        ...
        ggml_vec_cpy_f32(ne00,
            (float *) ((char *)  dst->data + ... + (i1*ne01 + k1)*nb1  + ...),
            (float *) ((char *) src0->data + ... + (          k1)*nb01));
```

Destination row `i1*ne01 + k1` from source row `k1`: destination head `h`
reads source head `h % ne01`. `src/models/qwen35.cpp`:

```c
q_conv = ggml_view_4d(ctx0, conv_qkv_mix, head_k_dim, num_k_heads, ...);
...
if (num_k_heads != num_v_heads && (!cparams.fused_gdn_ar || !cparams.fused_gdn_ch)) {
    GGML_ASSERT(num_v_heads % num_k_heads == 0);
    q_conv = ggml_repeat_4d(ctx0, q_conv, head_k_dim, num_v_heads, n_seq_tokens, n_seqs);
    k_conv = ggml_repeat_4d(ctx0, k_conv, head_k_dim, num_v_heads, n_seq_tokens, n_seqs);
}
```

### The RTL, quoted

`rtl/gdn_block.vhd`, state `P_HKQ`:

```vhdl
          when P_HKQ =>
            base := (vh/VPK)*DIM*16;
            rp_kn      <= knb(base+DIM*16-1 downto base);
            rp_qs      <= qsb(base+DIM*16-1 downto base);
```

with `constant VPK : integer := VAL_HEADS/KEY_HEADS;`. Those are the only two
occurrences of `VPK` in the file.

### The independent confirmation that has NOT been run, and how to run it

`tools/ref9b/` builds its golden from `dump_llamacpp`, i.e. from real
llama.cpp tensor dumps, so it inherits ggml's broadcast semantics without
anyone having to decide anything. A `q_conv_predelta` / `k_conv_predelta`
capture at a GDN layer, compared per value head against what
`rtl/gdn_block.vhd` feeds `gdn_recur_pipe`, would confirm B-BLK-1 at the REAL
shape and would not depend on this oracle at all. That is the cheapest
available second opinion and it was not run here, because `tools/ref9b/**` is
TRACK C1's and `layer` is hardwired to 0 in every B bench.

### Where the wrong rule most plausibly came from

B spec 2.9's VERIFIED box says "the GQA ratio inside GDN is **3 value heads per
key head**". That sentence is true under both rules and names neither, and
"GQA ratio" invites the contiguous grouping GQA actually uses. Section 4 says
only "each key head serves 3 value heads". **The spec never pins WHICH three.**
This is a spec hole as much as an RTL defect, and closing it needs one
normative sentence in section 4.

### The oracle's own self-gates, teeth-checked

Both are the failures that bit `ref/gdn_emit_chain_vec.c`, each as a silent
wrong answer rather than an error:

| removed | worst error vs the double oracle | verdict |
|---|---|---|
| `bf_resolve_eps()` | 2.6067808e7 LSB | FAIL, both gates |
| `fx_init()` | 7.8816454e30 LSB | FAIL, both gates |
| CONTROL (neither) | 9.97 LSB | OK |

### The shape header assert, teeth-checked

```
$ ghdl -r ... tb_gdn_block_vec -gKMAP_DIV=true      # against kmap=mod vectors
tb_gdn_block_vec.vhd:357:5:@0ms:(assertion failure): tb_gdn_block_vec: gdn_block_vec.txt was generated with kmap=0 and this testbench has KMAP_DIV=true.
```

### The double-oracle bound: what the denominator had to be, and which gate carries it

The first denominator was one LSB of the y grid. It is **shape-dependent by an
order of magnitude on identical, correct code**, so a bound calibrated at one
shape fires spuriously at another:

| shape (KH VH DIM tokens) | worst, bare y LSB |
|---|---|
| 2 4 32 2 | 6.09 |
| 4 8 16 3 | 2683.32 |
| 1 3 16 4 | 26481.23 |
| 2 4 32 8 | 2966.36 |
| **16 32 128 2 -- the real 9B shape** | **6.89** |

`ref/gdn_recur_vec.c` hit the same thing first and says why: the output dot is
a D-term SIGNED sum that cancels heavily, so an error measured against the
result explodes wherever the result is near zero while every term is fine. Its
fix is to emit the sum of |terms| and normalise by that. Doing the same here --
denominator `max(one y LSB, the element's own term norm)` -- makes the figure
shape-stable: 0.135 to 0.544 across the same five shapes.

Seed sensitivity at the committed shape, 29 seeds, kmap=div, on the new metric:
worst **0.1224** (seed 1) to **0.4973** (seed 77777); worst count over 0.05
**10.94%** (seed 1). The knob is live -- nine sampled seeds gave nine distinct
vector-file md5s.

**And then the important measurement: the MAX is the weakest of the four
gates.** With `fx_init()` removed, or with `bf_resolve_eps()` removed -- the
two failures that bit `ref/gdn_emit_chain_vec.c`, each as a silent wrong answer
-- the term-norm max reads **0.664** and **0.665**, which is BELOW what a
legitimate seed produces, while the count reads **99.22%** in both:

```
--- fx_init() removed ---
  worst end-to-end error vs the double oracle: 0.664863, relative to max(one y LSB, the element term norm)
  elements compared: 256 of 256;  over 0.05: 254 (99.22%)
  worst error in bare y LSB, no term norm: 9647912845648509027052624543744.0000
  FAIL: 99.22% of elements are over 0.05 from the double oracle; the DISTRIBUTION has moved
  FAIL: worst bare-LSB error 9.648e+30 is a blow-up, not quantization
--- bf_resolve_eps() removed ---
  worst end-to-end error vs the double oracle: 0.663658
  elements compared: 256 of 256;  over 0.05: 254 (99.22%)
  worst error in bare y LSB, no term norm: 31896156.8301
  FAIL (both)
```

The max got SMALLER than a good seed can produce while the design was
destroyed, because a term-norm denominator structurally caps the ratio near 1
once the output collapses to zero. So the generator gates **four** things:

1. the term-norm max, at 2.0 (4x the measured worst),
2. the COUNT over 0.05, at 45% (4x the measured worst) -- **this is the gate
   that catches both catastrophic failures**,
3. the bare-LSB max, at 1e6, deliberately loose: it is the only figure that
   grows without bound, and it reads 3.2e7 and 9.6e30 on the two above,
4. a FLOOR on the number of elements actually compared, because a run that
   compares nothing must not be able to pass and none of the other three can
   see that.

**One measurement recorded without a conclusion.** At the real 9B shape
(16 key heads, 32 value heads, DIM 128) the worst element reads 0.5435 and
4.2% of elements exceed 0.05, both larger than at the bench shape. The worst
element is in **token 0**, which is the masked-state first token where spec
2.1.4's own correction table already shows the largest error. The stimulus is
synthetic. This is a number, not a defect claim, and it should be re-measured
against captured activations before anyone acts on it.

### `tb_gdn_block`'s four flags: gated, and each gate shown to fire

Measured values on that bench's own stimulus, all four low:

```
tb_gdn_block: err_conv='0' err_g='0' err_se='0' y_sat='0'
tb_gdn_block: CYCLES token 0 = 2267
tb_gdn_block: CYCLES token 1 = 2267
```

Teeth, one run per generic, each flipping only that expectation:

| generic set true | line that fired |
|---|---|
| `EXP_ERR_CONV` | `tb_gdn_block.vhd:691` assertion failure |
| `EXP_ERR_G` | `tb_gdn_block.vhd:696` assertion failure |
| `EXP_ERR_SE` | `tb_gdn_block.vhd:701` assertion failure |
| `EXP_Y_SAT` | `tb_gdn_block.vhd:706` assertion failure |

Two of the four expectations are DERIVED and two are MEASURED, and the file
says which: `err_conv` cannot fire because `m12()` bounds every conv mantissa
at +/-2047, so `|acc| < 2^24` and `e_seg` lands in roughly [10, 24]; `err_g`
cannot fire because `|a| <= 0.5` and `|alpha+dt| <= 1`, so `|g| <= 0.66`
against a clamp at 16. `err_se` and `y_sat` are measured, not derived.

### Mutation table

`bash sim/mutate_gdn_block.sh`, at the gate row's own configuration
(vectors `2 4 32 2 2 div`, bench `-gKMAP_DIV=true`). Three verdicts via
`sim/mutverdict.py`, so an ABORT is counted apart from a kill.

```
TAG        CLASS   VERDICT        DESCRIPTION
CONTROL    control PASS           UNMUTATED design through the same mutate path
M01        rtl     KILLED         key-head map h/(VH/KH) -> h mod KEY_HEADS (the B-BLK-1 FIX)
M02        rtl     KILLED         L2 input: the q head is normed from the k segment buffer
M03        rtl     KILLED         L2 output: q_s takes the exp-15 output instead of exp-18
M04        rtl     KILLED         L2 output: k_n takes the exp-18 output instead of exp-15
M05        rtl     KILLED         silu output routing: the q buffer is filled from segment 1
M06        rtl     KILLED         e_v taken from the k segment instead of the v segment
M07        rtl     PASS           segment exponent captured LIVE instead of from the frozen copy
M08        rtl     KILLED         tk0 dropped: the first token reads the resident state
M09        rtl     KILLED         the decay gate and beta are swapped into the recurrence
M10        rtl     KILLED         the scalar group is stored one value head late
M11        rtl     KILLED         v column index off by one within the head
M12        rtl     KILLED         the state column exponent is read as a constant
C01        c       KILLED         oracle: silu dropped from the conv output (spec 1.1(e))
C02        c       KILLED         oracle: masked conv taps are included in the products
C03        c       KILLED         oracle: the z gate multiplies before the norm, not after

CONTROL (unmutated, same path): PASS
MUTATIONS 15   KILLED 14   SURVIVED 1   ABORT 0
```

**The CONTROL row is the reason the other fifteen mean anything.** The first
version of this harness counted it as a survivor, which is a labelling defect
in the harness rather than in the design, and it is fixed: the control is
tracked separately and a control that is not PASS prints a banner saying every
other row in the table is meaningless.

**The one survivor, under its own name.** M07 replaces the FROZEN segment
exponent with the live port. MEASURED at `CV_GAP` = 0, 1, 3 and 7 with the
unmutated control re-run at each: **0 of 256 y mismatches in all eight runs**.
This is a statement about the schedule, not a hole in the bench.
`gdn_block`'s phases are strictly sequential, so by the time `seg_e(seg)` is
taken `gdn_conv` is back in `S_IDLE` and its live `e_seg` still holds the right
value; the file's own comment at that line says so. The frozen copy is defence
against the OVERLAPPED schedule the file's closing note describes and does not
implement. Making it observable needs segment s+1 started before segment s's
exponent is consumed, which nothing in this block can currently do.

**The three C-class rows exist so the comparison is two-sided.** A bench that
only ever saw the RTL move would be measuring half of what it claims to. All
three are killed, including C02, which removes the spec 1.6 tap masking from
the ORACLE and is caught through `y_exp` alone -- which is what the deliberate
garbage in masked taps is for.

**M01 is the B-BLK-1 fix and it is KILLED here on purpose.** The vectors are
generated at `kmap=div`, so the corrected mapping disagrees with them. If M01
ever survives, this harness has stopped seeing the mapping and every other row
is suspect.

## Measured and REJECTED -- do not retry

- **Do not write the oracle as a fresh transcription of the four approximation
  kernels.** `rmsnorm_bf`, `gdn_silu`, `gdn_scalar` and `l2norm_rs` each have a
  verified core with its own double oracle. Copying their arithmetic creates a
  second definition that drifts, and the drift is invisible. This is the
  documented `l2norm` collapse, 55 passing cases against a recipe that emitted
  zeros for a whole path. `ref/gdn_emit_chain_vec.c` already reached this
  conclusion; the same answer twice is a rule, not a preference.

- **Do not put the stimulus in the VHDL.** `sim/tb_gdn_block.vhd` generates its
  own from `hsh()`, which is right for a cross-skew identity comparison because
  it guarantees the inputs cannot move. It is wrong for a value comparison: the
  oracle would then have to reproduce `hsh()` exactly, giving two sources of
  truth for the inputs, and a divergence between them would read as an
  arithmetic failure. Rejected before it was built, for the reason
  `ref/attn_block_vec.c` states.

- **Do not `#include` `rmsnorm_bf_vec.c` and `l2norm_rs_vec.c` into one
  translation unit unrenamed.** They both define `RSQRT_ROM`, `INV_SQRT2_C` and
  `THREE_Q30` at file scope, and the second pair are a `#define` against a
  `static const`, so the collision is a syntax error inside an unrelated file.
  The L2 copies are now `L2_`-prefixed; the rename was verified byte-identical
  at N = 32, 64 and 128.

- **Do not gate the double-oracle comparison on a maximum alone.** MEASURED:
  the two catastrophic failures score 0.664 and 0.665 on the term-norm max,
  BELOW what a legitimate seed produces, and 99.22% on the count. See the
  evidence section. The generator gates four things, and the count is the one
  that carries it.

- **Do not use one LSB of the y grid as the only denominator.** MEASURED on
  identical, correct code: 6.09 at (2,4,32,2 tokens) against 26481.23 at
  (1,3,16,4 tokens). A bound calibrated at one shape fires spuriously at
  another. The denominator is `max(one y LSB, the element term norm)`, the
  same move `ref/gdn_recur_vec.c` already makes for the same reason. The bare
  LSB figure is kept as a separate, deliberately loose blow-up detector.

- **Do not re-seed the double state from the fixed state at every token.** It
  was tried, on the theory that the token-count dependence of the error was the
  recurrence's accumulated quantization drift. MEASURED: it moved the worst
  figure at (1,3,16,4 tokens) from 26481.23 to 26464.24, a change of 0.06%.
  The cause was cancellation in the output dot, not drift. Reverted.

- **Do not "fix" the divergence by changing the oracle's default.** The
  oracle's default is the model. The RTL's rule is reachable only through an
  explicit `div` argument that is echoed on stderr, written into the vector
  file's header, and asserted against a bench generic. C-ORACLE's entire value
  came from not touching its oracle.

- **`VAL_HEADS = KEY_HEADS` is not a valid bench shape for this question.**
  At 1:1 both candidate mappings are the identity and the defect is
  structurally unreachable. The bench shape is 2 key heads and 4 value heads
  for that reason and the generic carries the note.

## Measurement traps hit, including my own

- **I wrote a bound from a number I had not actually measured.** The first
  version of the count gate said "worst bad-fraction 1.17%" and set the gate at
  10%. The real worst over the same 29 seeds was 8.20%, so the gate I had just
  written and called measured was 1.2x above the observed worst. Corrected to
  35% with the real numbers in the file. The lesson is narrow and exact: the
  seed sweep that produced 1.17% was sorted by the WRONG COLUMN, and I read the
  bad-fraction off the row that was worst by maximum error.

- **`ref/gdn_conv_vec.c`'s comment says the sequence-start masks are
  `0001, 0011, 0111`, and `rtl/gdn_exp_capture.vhd`'s header says the current
  token is the TOP byte and `tvalid(t) = 1` for `t >= K - n`.** Those are
  opposite bit conventions. Both files are internally consistent -- the
  generator is sweeping mask prefixes and never claims which end is time-current
  -- but read together they will send you to the wrong tap. The oracle takes
  the time order from spec 1.1(e) and the port packing from
  `gdn_exp_capture`'s documented interface, and says so in its header. This
  cost twenty minutes and is the single most likely thing to be got backwards
  by the next reader.

- **A `report` at `severity note` is invisible to a pass/fail gate.** The four
  flags in `tb_gdn_block` had been printed since the bench was written, and the
  regression could not fail on any of them. This is the third instance of the
  shape in subsystem B and it will not be the last: grep for `report` lines that
  print a checkable quantity.

- **`sim/regress.sh` treats any bare `"*.txt"` string literal in a testbench as
  a vector file** and will build `ref/<stem>.c` for it. That is how
  `gdn_block_vec.txt` gets generated with no plumbing, and it is also why
  `tb_gdn_block`'s `OUTFILE = "gdn_block_out.txt"` is harmless only because
  `ref/gdn_block_out.c` does not exist. Naming an output file after an existing
  generator would silently overwrite the run's vectors.

## NOT verified

- **The real shape.** Everything above is at KEY_HEADS 2, VAL_HEADS 4, DIM 32,
  2 tokens, 1 layer. The 9B shape is 16, 32, 128, and 24 GDN layers. Nothing
  here has been run at it, and one token at the shipping shape is minutes of
  GHDL.
- **More than one layer.** `layer` is hardwired to 0 in both benches, exactly
  as it is in `tb_gdn_block`. The per-(layer, segment) exponent store is
  therefore exercised at one layer plus, under `CAP_BUSY`, a colliding capture
  against a second. **This is the same hole that hid defect C1** (`attn_block`'s
  `v_ref` with no layer index, invisible because `tb_attn_block` hardwires
  `layer => 0`), and subsystem B has a structurally identical surface in
  `gdn_exp_capture`. It is the first thing to do next.
- **More than two tokens.** The conv tap mask reaches `1111` only at token 3;
  the run stops at token 1, so masks `0001` and `0011` are covered and `0111`
  and `1111` are not. Raising TOKENS to 5 is a one-word change to the
  `tb_vector_args` row and costs about 30 s.
- **That the four status flags can go HIGH.** They are gated to LOW and the
  gates were shown to fire by flipping the expectation, which proves the assert
  is wired. No stimulus in either bench drives any of the four true, so their
  HIGH branch is unexercised. `ref/gdn_conv_vec.c` had exactly this problem and
  fixed it with a wide-`cw_exp` case class; the same move would work here.
- **Whether the block's status flags are sticky or per-token.** With all four
  expected low the check cannot tell the two apart.
- **The fused-GDN path in llama.cpp.** `cparams.fused_gdn_ar` defaults true,
  and the explicit `ggml_repeat_4d` is skipped when both fused flags are set.
  The fused kernel's own broadcast was not read. Two independent non-fused
  mechanisms both give modulo, so the conclusion is not in doubt, but the fused
  path is unexamined.
- **The skew axes under the value check.** `Z_DELAY`, `W_MOVE`, `SC_MOVE`,
  `CW_MOVE` and `CAP_BUSY` all exist in `tb_gdn_block_vec` and all default off.
  Running the value check under skew is strictly more than either bench alone
  and has not been done.
- **Subsystem A's actual segment ordering.** The oracle asserts spec 1.1(h)'s
  plain `[q | k | v]`, head-major. Nothing here checks that the packer emits
  it, only that the block consumes what it is given in that order.

## Corrections

None yet. Append here rather than editing above.
