# Auditing the Gated DeltaNet design spec against its own arithmetic and against what has since been measured

**Date:** 2026-08-26
**Target:** `docs/superpowers/specs/2026-08-21-gated-deltanet-design.md`, rev 1
plus every amendment through 2026-08-26 (2,513 lines as audited).
**Model:** Qwen3.8-27B on 2x SQRL FK33 (`xcvu33p-fsvh2104-2L-e`), TP = 2 by head.
**Nothing was synthesized or simulated for this audit.** Every number below is
either quoted from the spec, quoted from a `docs/debugging/*.md` measurement, read
out of `rtl/*.vhd` or `sim/*.csv`, or recomputed from those by arithmetic that is
shown in full.

## The question, verbatim

> audit `docs/superpowers/specs/2026-08-21-gated-deltanet-design.md` (the
> subsystem B / Gated DeltaNet design spec) and produce a DURABLE findings file.
> A previous audit found ~16 issues, but that list existed only in a conversation
> that has since been summarized away, so the findings were lost and are being
> re-derived. The single most important deliverable is therefore the file itself,
> not the count.
>
> Look for: internal contradictions (same quantity, two values, two places);
> claims contradicted by measured results in the `docs/debugging/*.md` files that
> post-date the spec; numbers that no longer follow from their own inputs; and
> head-count / dimension confusions, given that the model has 48 GDN value heads
> (`num_v_heads = ssm_dt_rank = 48`), 16 key heads (`ssm_group_count = 16`),
> `head_v_dim = 128` for BOTH head types, S_DIM 128, d_inner 6144, 64 blocks of
> which 48 are GDN and 16 attention, and that tensor parallelism splits by head
> across 2 cards (24 value heads, 8 key heads per card).

Four findings were given as a calibration set: the bundle margin is +12% and not
the +36%/+47% quoted; the conv cycle model differs by 2x between section 3.3 and
section 3.6; section 2.7 still splits AXI by direction; and section 3 site 13's
"16-head renorm" (already fixed in `bc0a030`, not re-reported).

All four are reproduced below (F3, F4, F7, and the re-verification of the
site-13 fix). The +12% is confirmed exactly from `491,520/LANES`; it refines to
**+11.4%** once `gdn_conv`'s measured per-invocation overhead is included, which
was measured by a concurrent work item while this audit was running.

## The answer

**All four calibration findings stand and are reproduced below with their
arithmetic. Seventeen findings in total hold up under the "quote plus
computation" test -- the three live calibration items plus fourteen more. Two of
the new ones are larger than anything in the calibration set, and both change
hardware:**

1. **B's output RMSNorm has no epsilon.** Not in the spec's normative §2.1, not in
   `rmsnorm.vhd`, not in `rmsnorm_rs.vhd`. The model's `eps = 1e-6` dominates
   `mean(x^2)` on **72.57%** of 2.74M real 27B samples, and the RTL's degenerate
   clamp is **244x too large** and lands **above the median activation**, so the
   unit is ~14x wrong on the typical sample. §3.6's "**CLOSED** for rmsnorm" is
   therefore not a closure, and the bit-exactness that closed it is the reason the
   defect was invisible.
2. **The two block-floating emit stages, sites 12 and 13, are absent from every
   schedule in §3, and BOTH of their RTL headers price themselves per LAYER while
   comparing against a per-TOKEN sweep.** Each claims ~1% of the sweep; each is
   really ~50%, and together they are **605,952 cycles = 102.7% of the
   589,824-cycle sweep**. Both units are single-buffered, so both serialize against
   the stream that feeds them rather than merely adding to a budget.

With finding 1 the output stage computes the wrong function; with finding 2 the
§3.3 bundle no longer hides under the sweep by any summation model
(`529,440 + 605,952 = 1,135,392` against 589,824, a margin of 0.52).

**The die DSP total barely moves** and remains the §3.6 range of 2,606 to 2,648 of
2,880 (90.5% to 91.9%), plus the 1 DSP of site 13 measured after that table was
built. B's own honest row is **227**, a number that appears nowhere in the spec as
a single figure.

## The procedure that produced it

Ordered, and each step isolates something the previous one cannot see.

1. **Read the spec end to end first, before any debugging file.** The point is to
   collect what it asserts, not to check it. Checking while reading anchors on the
   first value seen and the second one then reads as a restatement, which is
   exactly how the 16-vs-24 head error survived.
2. **Build a table of every quantity that appears more than once**, keyed by the
   quantity and not by the section. Head counts, cycle counts, Fmax, DSP, margins,
   ms/token. Contradictions fall out of the key collision, not out of reading.
3. **Recompute every derived number from the inputs printed next to it.** This is
   what catches numbers that no longer follow (findings F14, F17) and it is cheap:
   one `python3` heredoc over the whole set.
4. **Diff the spec against `rtl/*.vhd` and `sim/*.csv`, not against its own prose.**
   The RTL is the only thing that cannot be internally consistent with a wrong
   spec. This is what found F5 (two units implementing two different halves of a
   contradictory rule) and F2 (two units with no budget line).
5. **Read the `docs/debugging/*.md` files newest first**, because a later file
   supersedes an earlier one and the spec quotes whichever it was written against.
   `2026-08-26_rmsnorm-magnitude-window.md` (18:41 on the audit day) is newer than
   every rmsnorm claim in the spec.
6. **Check every head count against the four canonical values**
   (`v_heads = 48`, `k_heads = 16`, `head_v_dim = head_k_dim = 128`,
   `d_inner = 6144`) and against which of them the quantity is INDEXED BY. Both
   head types being 128 wide means no shape check separates them, so indexing is
   the only discriminator. `ssm_dt`, `ssm_a`, `ssm_beta`, `ssm_alpha`, `beta`, `g`
   and the recurrent state are all indexed by VALUE head; `q`, `k` and the L2 norms
   are indexed by KEY head.
7. **Rank by "would this change hardware", not by how wrong it is.** A stale 0.8B
   footprint in a table §4 explicitly supersedes is not a finding; a stale 0.8B
   dimension inside a live derivation is.

## The findings, ranked

Severity: **H** = changes hardware or a build decision. **M** = changes a number a
decision rests on. **L** = documentation defect, decision unaffected.

### F1 (H). The output RMSNorm's epsilon does not exist anywhere in subsystem B

`grep -in eps` over the spec returns **10 hits, every one of them about the L2
norm** (§1.1(c), §1.5, §2.1.2, §2.1.3's zero rule). §2.1 claims to be "the single
source of truth for every exponent, alignment and rounding decision in subsystem
B" and its rmsnorm chain is stated in full as

> `rmsnorm (output gate)     :  o_exp = xe + we + Q - shift_total`

with no epsilon term. §1.1(g) sources the operation correctly:

> the per-head output norm is **RMSNorm** over `head_v_dim = 128` with the
> per-layer weight `ssm_norm[128]` ... (`build_norm_gated`, `qwen35.cpp:247-255`)

and `build_norm_gated` is `LLM_NORM_RMS`, i.e. `x / sqrt(mean(x^2) + eps)`.

Measured, `docs/debugging/2026-08-26_rmsnorm-magnitude-window.md`, 2,741,760
samples (48 GDN layers x 48 value heads x 1,190 tokens, Qwen3.8-27B Q4_K_M,
`qwen35.attention.layer_norm_rms_epsilon = 1e-6`):

```
fraction with mean(x^2) < eps        : 72.57%   eps DOMINATES
fraction with mean(x^2) < 0.1 * eps  : 38.88%   norm is a CONSTANT gain
effective gain 1/sqrt(mean+eps): p50 = 901.2, max = 1000.0 = 1/sqrt(eps)

                     divisor          gain
  model  sqrt(2.31e-07 + 1e-06) = 1.11e-03    901
  RTL    sqrt(2.4414e-04)       = 1.5625e-02   64
                                              -> 14x wrong AT THE MEDIAN
```

Consequences the spec does not carry:

- **§3.6's "CLOSED for rmsnorm 2026-08-25: `rtl/rmsnorm_rs.vhd` exists, is
  bit-exact with `rtl/rmsnorm.vhd`, and reaches 300.8 MHz" is not a closure.** The
  two units are bit-identical **in the failure**: at `rms_real = 2^14` both report
  `o_exp = 24` and 0/128 nonzero. The golden being the other unit is the reason.
- **Range, not just correctness.** `1/rms` needs 24.12 octaves and the unit's
  window is 19; `1/sqrt(mean+eps)` needs **8.84**. The epsilon is what bounds the
  divider, so implementing it also removes the all-zeros region.
- **Widening `Q` is measured and rejected** (same file, CORRECTION section):
  `Q = 24` still leaves 2.02e-02, because the absolute-grid recipe rounds `mean`
  away before the epsilon is added. The fix is block-floating, which is what
  `rtl/rmsnorm_bf.vhd` now does.
- **DSP-neutral, so no budget row moves.** `sim/rmsnorm_bf.csv`: `rmsnorm_rs` and
  `rmsnorm_bf` are both 40 DSP / 0 BRAM / 300.75 MHz at `LANES = 4`; LUT +719.

*Left for a human:* whether B's §2.1 should state the epsilon in the model's native
activation units or in the unit's fixed-point grid. The scaling caveat in the
measurement file is load-bearing (`eps` scales as `2^2k` with the input scale) and
is a numeric-contract decision, not an audit finding.

### F2 (H). Sites 12 and 13 have no budget line, both price themselves per LAYER
against a per-TOKEN sweep, and both serialize the stream that feeds them

§2.1.4's stage 6 and §2.1.5's rows 12 and 13 specify both emit stages. **No cycle
count for either appears in §3.2, §3.3, §3.5 or §3.6.** The §3.3 bundle contains
exactly four terms: output rmsnorm, L2, silu, conv.

Both units now exist, are bit-exact and mutation-tested, and are measured:
`rtl/gdn_head_emit.vhd` (`870ace3`, `7cfa761`, 0 DSP / 1 BRAM36 / 440.9 MHz) and
`rtl/gdn_y_emit.vhd` (`c905496`, 1 DSP / 4 BRAM36 / 488.8 MHz at HEADS=24).
`docs/debugging/2026-08-26_gdn-head-and-y-emit.md` covers both and calls them
correctly: *"Two units of the SAME shape at different granularities."* **The
shape they also share is the costing error.**

#### F2a. Site 12, `gdn_head_emit`

Its own header states the cost:

```
-- COST.  Pass A is free: it runs concurrently with gdn_recur_pipe's own output
-- stream, one column per cycle, which is the rate that stream arrives at.
-- Passes B and C are ~DIM cycles each plus drain, so ~270 cycles per head and
-- ~6,500 per token for 24 value heads per card, against a state sweep of
-- 589,824 cycles per token. That is ~1.1%, which is why this unit is scalar
-- and has no LANES generic: widening it would optimise a rounding error.
```

`270 x 24 = 6,480`. **That is one layer.** There are 48 GDN layers, so per token
per card it is `24 x 48 = 1,152` head-emits, the same count §3.2 already uses for
the output rmsnorm ("24 heads x 48 layers = 1,152"):

```
1,152 x 270 = 311,040 cycles/token/card
311,040 / 589,824 = 52.7%   of the sweep, not 1.1%
```

The 48x error is the same shape as F1's: a per-layer figure compared against a
per-token denominator. It also invalidates the design decision the header draws
from it ("which is why this unit is scalar and has no LANES generic").

**And it is worse than an additive term, because the store is single-buffered.**
`rtl/gdn_head_emit.vhd:120-122,142` declares one `mem_t is array (0 to DIM-1)` and
one FSM `S_FILL -> S_AMAX -> S_EMIT -> S_DONE -> S_FILL`. Pass A of head h+1
cannot begin until pass C of head h retires, and pass A is fed directly by
`gdn_recur_pipe`'s output stream. So the recurrence stalls ~270 cycles at every
head boundary, on a head that takes `128 columns x II 4 = 512` sweep cycles:

```
512 -> 782 cycles per head   =  +52.7% on B's token time
```

This is structurally identical to the `k_n`/`q_s` head-boundary drain that §3.6
closed on 2026-08-26 ("a head boundary needs a ~60-cycle drain ... 11.7%"), and it
is 4.5x larger. The same fix (double bank plus a select bit carried on the column
context) applies and was measured free there.

#### F2b. Site 13, `gdn_y_emit`, the identical error one day later

`rtl/gdn_y_emit.vhd:57-61`:

```
-- COST.  Pass A is free: it consumes elements at the rate the norm and gate
-- produce them, and its multiply is the only DSP in the unit.  Passes B and C
-- are HEADS*DIM cycles each, so ~6,150 per token at 24 x 128, against a state
-- sweep of 589,824 cycles per token.  That is ~1.0%, which is why this unit is
-- scalar and has no LANES generic.
```

`2 x 24 x 128 = 6,144`. **That is one layer** -- this unit runs once per GDN
layer, over the whole 24-head block, so per token per card:

```
48 x 6,144 = 294,912 cycles/token/card
294,912 / 589,824 = 50.0%   of the sweep, not 1.0%
```

Same structure as F2a: `rtl/gdn_y_emit.vhd:136,149` declares one
`mem_t is array (0 to NTOT-1)` with `NTOT = HEADS * DIM = 3,072` and the same
`S_FILL -> S_AMAX -> S_EMIT -> S_DONE` FSM, so pass A of layer L+1 cannot begin
until pass C of layer L retires, and pass A is fed by the `rmsnorm_bf` and
`gdn_silu` output stream.

#### F2c. Together

```
site 12   1,152 x 270   = 311,040   52.7% of the sweep   (claimed 1.1%)
site 13      48 x 6,144 = 294,912   50.0% of the sweep   (claimed 1.0%)
                        ---------
                          605,952  102.7% of the sweep

bundle (F3) 529,440 + 605,952 = 1,135,392 against a 589,824 sweep
margin = 589,824 / 1,135,392 = 0.52
```

Both headers draw the same design decision from the same wrong percentage --
*"which is why this unit is scalar and has no LANES generic"* -- and that decision
is what the corrected number reopens.

**What does NOT move: DSP.** Site 12 is 0 and site 13 is 1
(`sim/gdn_head_emit.csv`, `sim/gdn_y_emit.csv`), so the die total stands. BRAM
moves by 5 tiles, inside §2.6's stated 50-60 range.

*Left for a human:* the 270 and the 6,144 are the units' own header estimates, not
timed simulations. No GHDL run was made for this audit. The 48x count error and the
single-buffer serialization do not depend on either being exact, and the two units
were written a day apart by different work items, which is why the error is worth
recording as a class rather than as two typos.

### F3 (H). The bundle margin is +11%, not the +36% of §3.3 or the +47% of §3.6

Every input is a measured number already in §3.6. Substituting each unit at the
lane count that actually closes B's clock:

| term | invocations/token/card | cycles each | cycles | source |
|---|---|---|---|---|
| output `rmsnorm_rs`, `LANES = 4` | 1,152 | 142 | 163,584 | §3.6 rmsnorm_rs table |
| `l2norm_rs`, `LANES = 2` | 768 | 185 | 142,080 | §3.6 l2norm_rs table |
| `gdn_silu`, `LANES = 4` | -- | -- | 98,304 | `sim/gdn_silu_sweep.csv` |
| `gdn_conv`, `LANES = 4` | 144 | 530 / 530 / 1,554 | 125,472 | measured cycle model, below |
| **bundle** | | | **529,440** | |
| state sweep, `LANES = 32` | | | 589,824 | §3.1, measured II = NB |

```
589,824 / 529,440 = 1.1141   ->  +11.4%
```

The conv term is taken from a measured cycle model rather than from
`491,520/LANES`, which lands at 122,880 and would give +12.0%. `gdn_conv` costs
`2*(nch/LANES) + 16 + max(1, log2 LANES)` cycles per invocation, exact on 136
points (`docs/debugging/2026-08-26_gdn-conv-cycle-model.md`, measured by a
concurrent work item during this audit), so at `LANES = 4` it is
530 + 530 + 1,554 = 2,614 per layer and 125,472 per token per card. The
difference against `491,520/LANES` is the fixed per-invocation overhead that
neither §3.3 nor §3.6 counts, over 144 invocations.

Against §3.3's **+36%** (**+35%** once its conv row is corrected) and §3.6's
**+47%**. The two published figures are each
optimistic for a different reason, and neither reason is stated:

- **§3.6's 401,664** prices the L2 at `768 x 142`, i.e. at `rmsnorm_rs`'s rate.
  `l2norm_rs` is a different unit and its 4-lane point **does not close timing**
  (285.8 MHz against B's 299.04 MHz), so the closing point is 2 lanes at 185
  cycles. §3.6's own retained note says this is unverified -- "§3.3's
  109,056-cycle L2 term assumes the same per-element cost as rmsnorm, which is
  plausible and unverified" -- and `109,056 = 768 x 142` exactly. It is now
  refuted by the l2norm_rs table two bullets above it in the same section.
- **§3.6's 401,664 also keeps conv at `LANES = 32` (30,720)** while §3.6 itself
  chooses `LANES = 4` (122,880 by its own model, 125,472 measured) as the decision. §3.3's correction note catches
  exactly this substitution and applies it; §3.6 does not.

Delta: `529,440 - 401,664 = 127,776` cycles = +0.43 ms at 300 MHz.

### F4 (H). §3.3 and §3.6 disagree about the conv cycle model by exactly 2x

§3.3's budget table:

> | conv, depthwise k=4 over 5,120/layer at `LANES = 32` | 30,720 | 0.10 |

§3.6's:

> Per card the conv is 5,120 channels over 48 GDN layers, two passes each, so
> `491,520 / LANES` cycles per token

```
3.3 model at LANES=32 :  5,120 x 48 x 4 / 32 = 30,720   (4 taps SERIAL, 1 pass)
3.6 model at LANES=32 :  5,120 x 48 x 2 / 32 = 15,360   (4 taps PARALLEL, 2 passes)
```

**§3.6 is the one that matches the built unit.** `rtl/gdn_conv.vhd:29-30` -- "The
unit is two passes because amax cannot be known until every acc exists: pass A
streams the channels and accumulates, pass B requantizes" -- and §3.6's measured
`DSP = 4 x LANES exactly, one per tap per lane`, so all four taps retire in one
cycle per channel per lane. §3.3's factor of 4 is a serial-tap model that no unit
implements.

Direction of the error: §3.3's is conservative (2x high), so correcting it moves
margin the safe way. It matters anyway because §3.3's own correction note mixes
the two models in one subtraction (`342,144 - 30,720 + 122,880`), taking 30,720
from the serial model and 122,880 from the parallel one.

### F5 (H). §2.1.3 and §2.1.5 give the Q-conversion two different saturation
rules, and the two shipped units implement one each

§2.1.3, in the block labelled "The Q12 conversion rule (used by **every**
nonlinearity argument -- silu's sigma, beta's sigmoid, softplus, exp)":

```
x_q12 : s32 = (sh >= 0) ? round_shift(x, sh)      -- round half toward +infinity
                        : sat32( x << (-sh) )     -- exact, saturating
```

§2.1.5 site 3, for the same rule:

> | 3 | Q argument conversion (silu's sigma at Q12; the scalar path at **Q18**) |
> `sh>=0`: half+inf; `sh<0`: **saturating left at a 2^45 sentinel, NOT the s32
> rail** |

These cannot both be normative. Both units exist and they split:

- `rtl/gdn_scalar.vhd:158, 174`: `constant SAT_W : wide_t := shift_left(to_signed(1,
  wide_t'length), 45);` on a 68-bit `wide_t`. The header states why: *"SATURATING
  at a sentinel instead of at the s32 rail, so the two terms of the softplus
  argument cannot cancel each other's saturation"*, and *"32767 << 36 is ~2**51 per
  term, so two terms overflowed the s52 accumulator and wrapped NEGATIVE -- an open
  gate where the reference has a shut one."*
- `rtl/gdn_silu.vhd:105,120`: `type s32_arr is array (0 to LANES-1) of
  signed(31 downto 0);` -- the s32 rail, as §2.1.3 writes it.

**The split is correct engineering and neither section states it.** silu's argument
only indexes a sigmoid table already clamped to +/-16, so an s32 rail is harmless;
the scalar path SUMS two converted terms, and that is precisely the defect
§2.1.3's own amendment names ("a true argument of -34826 computes as -1, turning a
shut decay gate into a wide-open one"). §2.1.3 as written still prescribes for the
scalar path the exact rail that amendment exists to remove.

### F6 (H). The §1.4 interface pins `H_k = H_v` with one generic, which §4 refutes,
and five interface quantities are still key-head-sized

§1.1(i): *"`H_k == H_v == 16` for this model ... **B pins `H_k = H_v` as a generic
constraint**"*. §1.4's entity: `H : positive := 16;   -- heads (H_k = H_v pinned
for v2.2, see 1.1(i))`.

§4 and §2.9's GGUF read refute it for the actual target:

> | key heads (`ssm_n_group`) | 16 | **16** |
> | **value heads (`ssm_dt_rank`)** | 16 | **48** |
>
> **Note `num_k_heads != num_v_heads` at 27B** (16 vs 48) ... **This is the single
> largest structural change from the 0.8B derivation**

§4 draws only the q/k-sharing consequence. It does not reach the interface, and
these five are still sized off the key-head count or off 18 layers, while the
quantity each names is indexed by the VALUE head or by 48 layers:

| site | as written | correct at 27B, per card |
|---|---|---|
| §1.4 entity generic | `H : positive := 16` (one generic, both head types) | needs two: `H_K = 8`, `H_V = 24` |
| §1.4 table, §2.1.1 | `ssm_dt` (bias), `ssm_a` -- `[16]` each, per layer | `[48]` (24 per card): `dt_rank = 48` |
| §2.1.3 scalar path | "per head; **16 values** each" | 48 (24 per card) |
| §1.4 entity | `y_addr : ... (10 downto 0);   -- 2048 entries` | `ssm_out` input is 6,144, i.e. 3,072/card -> 12 bits |
| §1.4 entity, §2.1.1 | `MAXLAYERS := 18`; conv slot exponent registers `18 x 3 x 3 = 162` | 48 layers; `48 x 3 x 3 = 432` |

This is the failure mode §1.1(g)'s own correction note names: *"a number that was
correct for the old target and remains a plausible value for the new one, because
the quantity it names still exists at that value under a different name."* 16 is
still a real head count at 27B, so every one of these reads correct.

### F7 (H). §2.7, §2.6 and §2.9 still split B's AXI by direction

§2.7:

> The top-level arbiter grants the HP ports to the active unit; **B claims 2 read
> + 2 write channels (§2.5)**.

Contradicted three times in the same document, twice by measurement:

- §1.4's port block: *"AXI4: FOUR masters, each BIDIRECTIONAL (2.5 as corrected by
  3.4). **NOT two read plus two write**"*.
- §2.5's own box: *"**SUPERSEDED 2026-08-25 by §3.4.** This paragraph said 'two
  read masters and two write masters'."*
- §3.4, measured on the loaded bitstream: in-place 4 ports doing R+W deliver
  **47.1 GB/s** against the ping-pong's 38.4, so *"§2.5's four-master allocation
  stands with the masters bidirectional rather than split by direction."*

Two further sites carry the superseded split and were missed by the §2.5
supersession: §2.6's on-chip table row `AXI FIFOs (2R + 2W state, conv weights)`
and §2.9's device table row `State backing | PS DDR4, 2R+2W masters`.

### F8 (M). §1.5 pins beta at Q15; §2.1.1 and §2.1.3 pin it at Q16

§1.5: *"§2.1 pins beta and the decay factor at **Q15 out**, so the table must be
regenerated"*.

§2.1.1: `| beta_h | uint16, 0..65535 | exp **16** (Q16; sigmoid < 1 strictly) |`
§2.1.3: `beta = sigmoid_q( Q18(b_mant, b_exp), 18 ) -> Q16   -- uint16, sat 65535`

§2.1 is normative and Q16 is the one the arithmetic uses: §2.1.4 stage 3's
`e_dm = e_d + 16 - shd` carries the 16. One bit, and it is a grid, so it silently
halves or doubles `d`.

### F9 (M). The Q15 regeneration of SIG_ROM and EXP_ROM is not a deliverable; it is
discharged by construction

§1.5 twice, and §3.6 once:

> `sigmoid_q` + SIG_ROM for beta and silu | Q12 in/out as shipped; §2.1 pins beta
> and the decay factor at Q15 out, so **the table must be regenerated**
> (`tools/gen_fixed_luts_pkg.py`) -- a §3 deliverable

> The **Q15 regenerations of EXP_ROM and SIG_ROM** (`tools/gen_fixed_luts_pkg.py`)
> are deliverables.

Both built units read the **shipped** Q30 tables directly and round at the output:

- `rtl/gdn_silu.vhd` -- `docs/debugging/2026-08-26_gdn-silu-unit.md`: *"This unit
  reads the same Q30 `SIG_ROM` with a Q12 index and rounds to Q15, so nothing needs
  regenerating and nothing needs keeping in step. B's reuse table still describes
  the shipped Q12-in/Q12-out form as needing regeneration; that item is discharged
  by construction, not by a new table."*
- `rtl/gdn_scalar.vhd:309-313` reads `EXP_ROM(ip_k)` and `SIG_ROM(ip_k)` directly
  and emits `eg` as `unsigned Q15` and beta as Q16.

### F10 (M). "the 231 MHz this card reaches at 0.717 V" is refuted

§2.5: *"~2.48 ms/token at 300 MHz, **~3.22 ms at the 231 MHz this card reaches at
0.717 V**"*. 231 MHz is `300 x (1 - 0.229)`, the whole-die application of the
-22.9% derate.

`docs/debugging/2026-08-25_voltage-derate-on-hardware.md`, section 2:

> **The -22.9% derate does NOT transfer to this design.** A 300 MHz build whose
> [...] It did not break. So at 0.717 V this design's delay increase is
> **<= 18.8%**, i.e. its Fmax derate is **no worse than -15.8%**.

and its trap section: *"Treating -22.9% as a whole-die constant is not safe in
either direction."* The 231 figure inflates B's worst case; the honest statement is
`>= 252.6 MHz` bounded, actual unmeasured.

### F11 (M). B's LUT exceeds both the §2.8 estimate and the whole-die LUT sum's
allocation

§2.8's table row, `LANES = 32`: `LUT ... ~25-35K (3.2K measured, sweep+gate only)`.
`docs/debugging/2026-08-25_lut-budget-measured.md` allocates B `1,600 (GDN lanes,
32 x 50, MEASURED) + 25,000 (conv/state buffers, marshalling, control, GUESS)`
= 26,600.

Summing the units that now exist, each at the lane count the schedule needs:

| unit | LANES | LUT | source |
|---|---|---|---|
| `gdn_recur_pipe` | 32 | 24,037 | §3.6 II table |
| `rmsnorm_rs` | 4 | 9,042 | `sim/rmsnorm_bf.csv` |
| `gdn_silu` | 4 | 4,818 | `sim/gdn_silu_sweep.csv` |
| `gdn_conv`, `CH_MAX = 3,072` | 4 | 3,136 | §3.6 shapes table |
| `gdn_head_emit`, `DIM = 128` | -- | 1,199 | `sim/gdn_head_emit.csv` |
| **subtotal** | | **42,232** | |

`l2norm_rs` and `gdn_scalar` are not included (their LUT columns are not captured
in `sim/gdn_scalar_sweep.csv`, which reports 0), and neither is any marshalling,
state feed, elastic buffer or control -- i.e. the entire 25K "GUESS" line. So B is
already **+59% over its whole-die allocation** with the cheap half unmeasured, and
above the top of §2.8's 25-35K band. Whole-die LUT moves ~266.6K -> ~282K of
439.7K = 64.2%, which still fits comfortably; LUT is not the binding resource. The
finding is that the direction of error on B's LUT is **high**, which reverses the
LUT document's stated prior ("Direction of error, where it has ever been
checkable, has been HIGH" -- for guesses, but B's guess is the one that went low).

Also worth noting against F11's grain: `rmsnorm_bf` (the F1 fix) is +719 LUT at
`LANES = 4` and DSP/BRAM/Fmax neutral.

### F12 (M). B's honest DSP row is 227 and appears nowhere

Assembled from the measured rows the spec already carries, one per unit:

```
gdn_recur_pipe  LANES=32   129   (4 x LANES + 1, MEASURED)
rmsnorm_rs      LANES=4     40
l2norm_rs       LANES=2     26
gdn_silu        LANES=4      8   (2 x LANES, MEASURED)
gdn_conv        LANES=4     16   (4 x LANES, MEASURED)
gdn_scalar                   7   (MEASURED, SP_Q-independent)
gdn_head_emit                0   (MEASURED)
gdn_y_emit                   1   (MEASURED, flat in HEADS)
                          ----
                           227
```

The spec carries this as `202` (§3.6's aux table) plus three separate `+1`, `+16`,
`+7` deltas in the whole-die table two bullets later, and site 13's `+1` was
measured after that table was built, so the honest floor is **2,607**, not 2,606. The whole-die floor of 2,606
already includes all of them, so **the die total is correct**; what is missing is a
single B row a reader can quote. Every citation of "B's row" in the document is one
of 42-56, 138-152, 148, 166, 170, 202 or ~330, all of them live somewhere in the
text.

### F13 (L). §2.6's corrected conv-accumulator BRAM row uses the sum of three
segments where the accumulator is per-segment

§2.6's 27B re-derivation: `| conv segment accumulator (s34) | 2 | **5** (5,120 x
34 b) |`. The row it corrects reads "conv segment accumulator buffer (2048 x s34,
**reused per segment**)". Per card the segments are q 1,024 / k 1,024 / v 3,072,
so the buffer is sized by the LARGEST segment, 3,072, not by their sum.

Measured: §3.6's re-measured shapes table, `CH_MAX = 3,072`, `LANES = 4`, **4
BRAM36**, and the note that follows it: *"At the v segment it is 768 x 136b and
costs **4 BRAM36**, consistent with §2.6's own corrected row."* It is consistent
with the row's value by coincidence, not with its basis.

### F14 (L). §3.3's whole-phase budget table, row 1, does not follow from its
components

```
| shipped 5N, serial 1 element/cycle | 1,386,624 cycles, 4.62 ms | does not hide |
| 5N, 4 lanes, no other change       |   465,024 cycles, 1.55 ms | +27% |
| 3N, 4 lanes                        |   342,144 cycles, 1.14 ms | +72% |
```

Rows 2 and 3 each add exactly `129,024 = 98,304 (silu at 4/cycle) + 30,720 (conv)`
to their norm+L2 term (336,000 and 213,120). Row 1 adds **148,224** to 1,238,400.
It should be `1,238,400 + 129,024 = 1,367,424 = 4.56 ms`. 19,200 cycles have no
component behind them. Conclusion unaffected: the row does not hide either way.

### F15 (L). The serial worst case is 10.03 ms in §3.2 and 10.09 ms in §3.5

§3.2's table totals `589,824 + 743,040 + 495,360 + 1,179,648 = 3,007,872 cycles`
and reports **10.03 ms**, which is exact at 300 MHz. §3.5 says *"at §4 dimensions
with shipped units it is **10.09 ms** (§3.2)"*, citing §3.2 for a figure §3.2 does
not contain. `3,023,232` (the same total plus conv at §3.6's model) would give
10.08; no combination gives 10.09.

### F16 (L). §3.3 cites D's 3-DSP silu lane without the qualifier that makes it 2
for B

§3.3: *"D's measured narrowed silu lane is **3 DSP at 646 MHz**"*. That is
`micro_silu_narrow` with `SILU = 2` (`silu(g) * u`, the swiglu lane). B needs the
bare `x * sigmoid(x)`, `SILU = 1`, which §2.8 records at 2 DSP. B's own unit
measures **2 DSP at 391.8 MHz** (`sim/gdn_silu_sweep.csv`). The silu doc names this
directly: *"§3.3 cites the 3-DSP figure without that qualifier, which is what made
12 look plausible."* The rate conclusion survives (391.8 > 300); the DSP figure
would have been 50% high had anyone scaled from it.

### F17 (L). §2.1.4 stage 4's `|kd| <= 2^31` is not the bound of either recipe

```
kd[i] = k_n[i] * d_m               -- s16 x s18, one DSP; |kd| <= 2^31, s33
```

- Under the **superseded** fixed `shd = 16`: `|diff| <= 2^17` (s18), `beta <= 65535`,
  so `|d_m| <= 2^17 - 1`; with `|k_n| <= 32767` (sat16, exp 15), `|kd| <=
  32767 x 131071 = 4,294,803,457`, i.e. **~2^32**, two bits above the stated bound.
  `s33` still holds it (`2^32 - 1 = 4,294,967,295`), by 163,838.
- Under the **adopted** normalized `shd = max(0, msb_pos(|diff*beta|) - 14)`:
  `|d_m| < 2^15`, so `|kd| < 2^30`, one bit BELOW the stated bound.

So `s33` is right in both cases and no hardware changes; the documented bound
describes neither recipe, and anyone narrowing to `s32` from the "2^31" would break
the superseded form. Worth recording because the same section calls out this exact
class at stage 1 (*"which is why w18 is s19, not s18 -- the off-by-one-bit class A's
MA-1 documents"*).

### Verified still standing, already flagged in the document, not re-reported as new

- **Four values of `gdn_recur_pipe`'s Fmax** (318.9 sequential, 302.5 pipelined,
  305.6 with the corrected recipe, 299.04 double-buffered) and three places still
  carrying 305.6. §3.6's double-buffer note names this itself and prescribes the
  fix ("Quote the sweep in CYCLES"). Still unreconciled.
- **§2.9 contradicts §4.1 on residency** ("the 0.8B state ... FITS the VU33P's
  14.2 MB") and on supply ("19 MB/token vs 460 GB/s: ~41 us -- noise"; measured is
  288 GB/s and 75.5 MB/token per card). §3.1 records the contradiction and rules
  §4.1 wins; the §2.9 site itself is still unannotated.
- **§2.8's "Plan of record for `v3.0`: option 1 (C at `MACS=32`)"** is an AXU3EG
  co-fit decision. The FK33 budget runs C at `MACS = 192`. Not a contradiction,
  since §2.8 is scoped to `v3.0`, but it is the only "plan of record" in the
  document and it is not the plan.
- **§3.6 prices `gdn_silu` at 1 BRAM/lane** ("unless the lanes share one");
  measured is 0.5 (`sim/gdn_silu_sweep.csv`), so 2 BRAM at 4 lanes, not 4.

## Measured and REJECTED -- do not retry

- **Do not re-report section 3 site 13's "16-head renorm".** Fixed in `bc0a030`,
  and §2.1.5's row 13 was fixed with it. Both now read 24. Re-verified.
- **Do not report §1.4's, §2.2's, §2.3's or §2.5's 0.8B dimensions as
  contradictions.** §4 opens with *"This section supersedes every Qwen3.5-0.8B
  dimension elsewhere in this document"*, so a stale table is declared, not
  contradictory. Only a stale dimension inside a LIVE derivation counts (which is
  what F6 is, and what §3.1's "27B numerator against an 0.8B denominator" already
  caught for the sweep).
- **Do not report §2.10's precision numbers as contradicting §2.1.4's amendment.**
  §2.10's re-derivation box already carries it: `ref/gdn_err.c` now implements all
  three flags, `--pinned --fix-init` reproduces every old row to quoted precision,
  and the COVERAGE GAP paragraph already states that `EG0_ED` is inert on the
  weight-table paths. There is nothing left to find there.
- **Do not conclude that the whole-die DSP total moved.** It did not. `gdn_head_emit`
  is 0 DSP (`sim/gdn_head_emit.csv`) and `rmsnorm_bf` is 40, identical to
  `rmsnorm_rs` (`sim/rmsnorm_bf.csv`). The F1 and F2 findings are schedule and
  correctness findings, not budget findings. 2,606-2,648 of 2,880 stands.
- **Do not "fix" F4 by making §3.6 match §3.3.** §3.3's 4x-serial-tap model matches
  no unit; `gdn_conv` retires four taps per lane per cycle by construction
  (`DSP = 4 x LANES`, one per tap per lane).
- **Do not resolve F5 by picking one saturation rule for both units.** The split is
  correct: silu's argument indexes a table clamped to +/-16 so the s32 rail is
  unreachable in effect, while the scalar path sums two converted terms and the
  rail lets two saturations cancel. Both sections need the split stated, not one
  section's rule imposed on the other.

## Measurement traps hit, including my own

- **I nearly reported the bundle margin as +19%.** First pass priced the L2 with
  `rmsnorm_rs`'s 142 cycles, which is what §3.6 does, and only caught it by asking
  which unit each invocation actually runs on. The trap is that `l2norm_rs` and
  `rmsnorm_rs` are adjacent tables in the same section with the same column
  headings, so substituting one for the other looks like reading carefully.
- **`sim/gdn_scalar_sweep.csv` and `sim/gdn_recur_pipe_dbuf.csv` report `lut = 0,
  ff = 0`.** Those columns were not captured by the harness. Reading them as
  measured zeros would have made F11's subtotal look complete when two units are
  missing from it. Any LUT total assembled from `sim/*.csv` must check for zeros
  before summing.
- **`grep -in eps` over the spec returns 10 hits and all of them are about the L2
  norm.** The hit count reads as coverage. What settles F1 is not the count but
  which SITE each hit is at, and the site that needs one has none.
- **A per-layer figure compared against a per-token denominator produces a
  confident, small, wrong percentage** (F2's 1.1% and 1.0%). It is small precisely
  because the denominator is 48x too big, so it reads as reassurance and no one
  checks it. This is now the third and fourth instance in this project after §2.5's
  withdrawn 0.93 ms; all of them were caught only by rebuilding the number from its
  inputs rather than by scaling it. **The two emit units make the error
  independently, a day apart**, which says it is a property of the comparison and
  not of one author: the sweep figure `589,824 cycles per token` is quoted
  everywhere and is the natural denominator to reach for, while every emit unit's
  natural numerator is per-invocation. Nothing in the sentence looks wrong.
  A cheap guard: never write a percentage whose numerator and denominator were not
  both derived in the same line of arithmetic.
- **Bit-exactness against a golden that shares the DUT's recipe certifies the
  defect** (F1, and `2026-08-25_l2norm-recipe-collapse.md` before it). Two units
  now, same mechanism. The transferable rule: a golden must differ from the DUT in
  its NUMBER SYSTEM, not merely in its implementation.
- **Both head types are 128 wide, so no shape check separates them.** The only
  discriminator is what each quantity is INDEXED BY. F6's five sites all pass every
  dimensional check.

## Open, not yet answered

- **The 270 and 6,144 cycle figures are the units' own header estimates.** No GHDL
  run was made for this audit, and neither `sim/gdn_head_emit.csv` nor
  `sim/gdn_y_emit.csv` carries a cycle column. The 48x count error and the
  single-buffer serialization do not depend on them, but the exact size of F2 does.
- **Neither emit unit has been integrated** (`2026-08-26_gdn-head-and-y-emit.md`:
  "no top-level wires them together. The handshakes are compatible by inspection,
  which is not the same as tested"). So the serialization in F2 is read off the
  FSMs and the single `mem` arrays, not observed. A top level that double-buffers
  both would remove it, and that is the fix, not a reason the finding is wrong.
- **Whether the four §3 phases actually overlap has still never been
  demonstrated.** §3.3 says so of itself ("Neither figure is a demonstration") and
  the silu document repeats it. Every margin in this audit, including the +11.4%,
  assumes a summation model that no schedule has exhibited. If the units are
  genuinely independent hardware running concurrently, the binding constraint is
  `max(term)` and not the sum, and every term individually fits under 589,824. The
  spec does not say which model it means, and the answer changes F2 and F3.
- **What epsilon B should implement, in which units.** F1 establishes that one is
  needed and that block-floating is the structure; it does not settle the grid, and
  the `2^2k` scaling caveat means the log2 figures in the measurement file are not
  directly usable against B's rails.
- **`l2norm_rs`'s and `gdn_scalar`'s LUT.** Not captured; F11's subtotal is a lower
  bound.
- **Whether `l2norm_rs` at 4 lanes can be made to close.** At 285.8 MHz it misses
  B's 299.04 by 4.4%. The `rmsnorm_rs` and `l2norm_rs` histories both say the fix is
  splitting a fused state and both say the failing path is never the one predicted.
  If it closes, the L2 term falls 142,080 -> 92,928 and the F3 margin goes
  +11.4% -> +23%.
- **C's QK-norm lane count and D's phase sharing** remain the only two unmeasured
  terms in the die total, per §3.6. Unchanged by this audit.
- **Whether 90% is the right congestion line for this part.** Still folklore, still
  untested by any placed-and-routed run, still steering `MACS` and `LANES`
  decisions. Unchanged by this audit and named here only so the list stays honest.

## What was corrected in the spec, and what was left

Corrected in place, as dated `> **CORRECTED 2026-08-26.**` blockquotes in the style
of §3.6's site-13 note (`bc0a030`), never by deleting the wrong text:

F1 (at §3.6's rmsnorm CLOSED bullet), F2, F3 and F14 (one blockquote after §3.3's
existing correction note), F5 (at §2.1.5 site 3), F6 (at §1.1(i)), F7 (at §2.7),
F8 and F9 (at §1.5), F10 (at §2.5), F13 (at §2.6).

**F4 was landed independently and better by a concurrent work item while this
audit was running**, as a measured cycle model
(`docs/debugging/2026-08-26_gdn-conv-cycle-model.md`, `2*(nch/LANES) + 16 +
max(1, log2 LANES)`, exact on 136 points) rather than as the structural argument
this audit had. Two sessions reached the same finding from opposite directions on
the same day, which is worth recording as corroboration: the audit derived the 2x
from the RTL's `DSP = 4 x LANES` and its two-pass header, the measurement derived
it from `start`-to-`o_done`. The audit's correction was rewritten to build on the
measured model rather than to restate the argument, and the bundle arithmetic uses
the measured 125,472.

**Note on concurrency, because it affected attribution.** Another session was
committing to this repository throughout, and it swept several of these
corrections into its own commits (`1daeb11` in particular). The content is
present and correct; the commit boundaries do not separate the two work items.

Left for a human, with the reason:

- **F11, F12, F16, F17**: documentation and roll-up figures. Correcting them means
  choosing which of the seven live "B's row" figures becomes canonical, which is an
  editorial decision about the document's structure rather than a factual fix.
- **F15**: 10.03 against 10.09. Neither reconstructs from a stated component, so
  there is nothing to correct TO.
- **The §2.9 residency and 460 GB/s rows**: §3.1 already adjudicates them in the
  document. Annotating the §2.9 site would be duplicating an existing ruling, and
  §2.9 is scoped as device-scaling narrative.
- **§2.8's `v3.0` plan of record**: scoped to a device rung that is not the current
  target. Withdrawing it is a project decision, not an audit one.
