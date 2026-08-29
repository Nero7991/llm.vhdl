# Subsystem C: gated attention -- DSP skeleton and interface specification

**Date:** 2026-08-27. Branch `fpga`. Part `xcvu33p-fsvh2104-2L-e` (SQRL FK33),
two cards, N = 2 tensor parallel.

> **Time figures re-derived at the measured clock, 2026-08-27.** Every ms in
> this document was computed at 300 MHz or 299.04 MHz, both of which are
> **0.85 V analysis clocks**. The card runs VCCINT 0.717 V, where `matvec_core`
> at `ROWS_IF = 58` measures **237.812 MHz** (MEASURED,
> `sim/ooc_sweep/results.csv:7`). **The cycle counts are unchanged and remain
> the invariant**; only the divisor moves. Corrections are marked in place
> rather than overwritten, so the superseded figure stays readable. Three later
> findings also bite and are called out where they do: the `x0.835` derate rule
> is **WITHDRAWN** (`docs/2026-08-27_verdicts-at-0.717V.md`); `ROWS_IF = 58` is
> **NOT BUILDABLE** (`docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`);
> and at 0.717 V every norm unit is bound by the same DSP-to-DSP hop in the Q30
> Newton rsqrt, not by its lane count
> (`docs/debugging/2026-08-27_derate-is-not-a-constant.md`). Full derivation:
> `docs/2026-08-27_budgets-at-the-measured-clock.md` section 7.6.

**Status: ANALYSIS AND SKELETON ONLY.** No Vivado was run for this document.
Every DSP figure is either transcribed from a prior measurement with its date
and source named, or derived from operand widths against the DSP48E2's
27x18 signed multiplier, and each row says which. Nothing here is a routed
result and nothing here is verified RTL.

**Relationship to `2026-08-21-gated-attention-design.md` (C spec rev 7).** That
document is the authority on C's numeric contract, and this one does not
restate it. This document exists to answer one question the parent asked --
how many DSP48E2 does C need and how sensitive is that to the parallelism
choices -- by re-deriving it from first principles instead of transcribing it,
and to specify the interfaces with the discipline that subsystem B's two
2026-08-27 integration defects showed is necessary. Where the two documents
disagree the disagreement is stated, not silently resolved.

---

## 0. The model facts, verified against the GGUF, and one correction

The task that commissioned this document supplied three model facts. Two of
them are wrong for attention, and they are wrong in a way that would have
halved every dimension in the DSP budget. They are read directly from the
target GGUF below rather than from any prose.

Source: `/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf`, metadata and
tensor shapes parsed on 2026-08-27.

| Key | Value |
|---|---|
| `qwen35.block_count` | 64 |
| `qwen35.full_attention_interval` | 4 |
| `qwen35.attention.head_count` | 24 |
| `qwen35.attention.head_count_kv` | 4 |
| `qwen35.attention.key_length` | **256** |
| `qwen35.attention.value_length` | **256** |
| `qwen35.rope.dimension_count` | 64 |
| `qwen35.rope.dimension_sections` | `[11, 11, 10, 0]` |
| `qwen35.rope.freq_base` | 1e7 |
| `qwen35.embedding_length` | 5120 |
| `qwen35.ssm.state_size` | 128 |
| `qwen35.ssm.group_count` | 16 |
| `qwen35.ssm.time_step_rank` | 48 |

Tensor shapes for `blk.3`, which `full_attention_interval = 4` makes an
attention block (`blk.0` carries `ssm_*` and is Gated DeltaNet):

```
blk.3.attn_q.weight       [5120, 12288]     12288 = 24 heads x 256 x 2  (Q + fused gate)
blk.3.attn_k.weight       [5120,  1024]      1024 = 4 heads x 256
blk.3.attn_v.weight       [5120,  1024]
blk.3.attn_q_norm.weight  [256]
blk.3.attn_k_norm.weight  [256]
blk.3.attn_output.weight  [6144,  5120]      6144 = 24 x 256
```

**Confirmed:** 64 blocks, `64 / 4 = 16` attention blocks at indices
3, 7, ... 63, and 48 Gated DeltaNet blocks.

**CORRECTED, and this is the one number that matters most:**

| Claim as supplied | Verdict | What is actually true |
|---|---|---|
| `head_v_dim = 128` for both head types | **FALSE for attention** | `attention.key_length = value_length = 256`, confirmed independently by `attn_q_norm.weight [256]` and by `attn_output.weight`'s 6144 = 24 x 256. The 128 is `ssm.state_size`, a **Gated DeltaNet** dimension. "Both head types are 128 wide" is a true statement about subsystem B's key and value heads and a false one about subsystem C. |
| 16 key heads total, 8 per card | **FALSE for attention** | `ssm.group_count = 16` is GDN's key-head count. Attention has **24 query heads and 4 KV heads**, so at N = 2 each card owns **12 query heads and 2 KV heads**, not 8. |

The consequence is not cosmetic. At head_dim 128 and 8 heads per card the
per-position MAC count would be 2,048; at the real 256 and 12 query heads it is
3,072, a factor of 1.5, and the GQA group is 6 rather than 8, which changes
which `MACS` values are even legal (section 3). Every figure below uses the
GGUF values.

C spec rev 7 section 4.1 already carries the correct 24 / 4 / 256 geometry. The
supplied facts are B's, transposed.

---

## 1. The attention math, written out

Per attention layer, per decode token. Notation follows the C spec's numeric
contract; `value = mant * 2^-e` throughout, which is the project's BFP
convention and the reason every "exponent" below is subtracted.

Dimensions, all from section 0:

| Symbol | Value | Source |
|---|---|---|
| `D` head_dim | 256 | GGUF `attention.key_length` |
| `H_q` query heads per card | 12 | `head_count` 24 / N=2 |
| `H_kv` KV heads per card | 2 | `head_count_kv` 4 / N=2 |
| `G` GQA group | 6 | `H_q / H_kv` |
| `L` attention layers | 16 | `block_count / full_attention_interval` |
| `N_ROT` rotated dims | 64 | GGUF `rope.dimension_count` |
| `KV_BLOCK` | 32 | C spec 2.1.1 |
| `kq_scale` | 1/16 | `= 1/sqrt(256)`; `qwen35.cpp:320` via C spec 1.1(d) |

**Step 1: split.** Subsystem A produces `wq`'s 12,288-wide output per card.
The gate is **interleaved with Q per head, not split half and half**
(`qwen35.cpp:273-276, 293-296`, confirmed in C spec 1.1(a) and corroborated
here by `attn_q.weight`'s second dimension being exactly `24 x 256 x 2`):

```
wq_out = [ Q_h0(256), G_h0(256), Q_h1(256), G_h1(256), ... ]
```

A half/half assumption produces plausible garbage rather than an obvious
failure, which is why it is stated first.

**Step 2: QK-norm, before RoPE.** RMSNorm over `D = 256` per head, one shared
weight per layer per side (`attn_q_norm.weight [256]`,
`attn_k_norm.weight [256]`). Q-norm at `qwen35.cpp:279` precedes rope at 303;
K-norm at 289-291 precedes rope at 309.

```
q_n[qh] = rmsnorm(Q_h[qh], attn_q_norm)     12 invocations per layer per card
k_n[h]  = rmsnorm(K_h[h],  attn_k_norm)      2 invocations
```

with the exponent chains, which are **data-dependent and not derivable from any
interface port** (`rmsnorm.vhd:336`):

```
q_norm_exp[qh] = qg_exp + qn_exp + Q - shift_total_q[qh]     -- 12 distinct values
k_norm_exp[h]  = k_exp  + kn_exp + Q - shift_total_k[h]      --  2 distinct values
v_norm_exp     = v_exp                                       -- V is neither normed nor roped
```

`Q = 12`. `shift_total` differs per head because `rmsnorm` runs once per head.

**Step 3: IMROPE over the first 64 dims.** `LLM_ARCH_QWEN35` maps to
`LLAMA_ROPE_TYPE_IMROPE`, pairing is NEOX `(x[j], x[j+32])` for `j = 0..31`,
and dims 64..255 pass through unrotated (C spec 3.4, verified against
`ggml-cpu/ops.cpp:5898-5906, 6073-6078` and the GGUF's own
`rope.dimension_sections`).

**The collapse.** With sections `[11, 11, 10, 0]` the 32 sectors enumerate to
exactly 11 t + 11 h + 10 w, so `theta_e` is unreachable; in text mode
`p_t = p_h = p_w = pos`, so all three live streams carry the same angle.
**Text-mode IMROPE for this model is arithmetically identical to plain NEOX
RoPE over the first 64 dims.** The hardware builds the collapsed form. This is
a decode-only, text-only result and it silently stops being true if multimodal
input or the MTP block enters scope.

```
theta_j = pos * 1e7^(-j/32)                          j = 0..31
(x'[j], x'[j+32]) = (x[j]cos - x[j+32]sin, x[j]sin + x[j+32]cos)
```

Exponent PRESERVED (`rope.vhd:7`), which is what lets the chain in step 2
terminate at the norm stage.

**Step 4: KV cache write, per 32-element block.** For each of the 4 head-vectors
written per layer per card (2 KV heads x {K, V}), independently for each of the
8 blocks:

```
amax[b] = max over the 32 values of |value|
sh[b]   = max(0, msb_pos(amax[b]) - 6)                  msb_pos(0) = 0
mant[d] = sat8( round_shift(value[d], sh[d/32]) )
e[b]    = src_exp - sh[b]                               src_exp = k_norm_exp[h] or v_norm_exp
```

Record = 8 B exponents + 8 B pad + 256 B mantissas = **272 bytes**, 8.5
bits/value. K is stored post-RoPE; V is raw. No division anywhere.

`v_ref[layer][kvh] = min over all blocks written so far of e_v[b]`, folded at
write time into ~12 int8 registers, reset to **+127** per sequence.

**Step 5: scores, per query head, per position.** Aligned to the minimum block
exponent so every shift is a right shift:

```
partial[b] = sum over the 32 elements of block b of q_n[qh][d] * k_mant[d]
score      = sum over b of ( partial[b] asr (e_k[b] - e_min) )
score_exp  = q_norm_exp[qh] + e_min + 4                 -- kq_scale = 2^-4, folded
```

Bound: `partial[b] <= 32 * 127 * 32768 < 2^27`, so the 8-term sum is `< 2^30`
and fits s32.

**Step 6: convert to Q12 at the point of production.** `score_exp` contains
`e_min`, which varies per position, so raw scores from different positions are
not comparable and cannot feed a running maximum:

```
sh = score_exp - 12
score_q12 : s32 = round_shift(score, sh)     when sh >= 0
                = sat32( score sll (-sh) )   when sh <  0
```

Both branches are reachable because `q_norm_exp` is data-dependent and unbounded
below.

**Step 7: online softmax, per query head.** Running maximum kept snapped to the
EXP_ROM index grid (256 Q12 counts = 1/16):

```
m_g' = ((max(m_g, score_q12) + 255) asr 8) sll 8              exact
z    = score_q12 - m_g'   (<= 0)
e_p : u13 = EXP_ROM cone of z                                  e_p <= 4096
on a max rise, k = (m_g_new - m_g_old) asr 8  is an exact integer, so
f : u13 = round_shift(EXP_ROM(256 - k), 18)   for k <= 256, else 0
o'[d] = round_shift(o[d] * f, 12)      s'  = round_shift(s * f, 12)
o[d] += e_p * v_aligned[d]             s  += e_p
```

with `v_aligned[d] = v_mant[d] asr (e_v[d/32] - v_ref)`, unconditionally a
right shift because `v_ref` is a minimum, so `|v_aligned| <= 127`.

Accumulator bound: `|o| <= 2^11 positions * 2^12 * 2^7 = 2^30`. s32 suffices;
**s36 is declared for margin**.

**Processing order is part of the numeric contract** because online softmax
results depend on it: `[cur_pos, 0, 1, ..., cur_pos-1]`, the bypassed current
position first from on-chip quantized registers, then the DDR sweep ascending.

**Step 8: normalize, gate, emit.**

```
p = msb_pos(s)                            11 <= p <= 23 at MAXCTX = 2048
r : u16 = floor( 2^(p+15) / s )           divider_rs, NW = 44, DW = 28
t[qh][d] : s24 = round_shift( o[qh][d] * r[qh], p[qh] + 1 )
zg  : s32 = Q12 conversion of the gate word (g_mant, qg_exp), the step-6 rule
g15 : u16 = sigmoid(zg), Q15, clamped to [0, 32767]
y_pre[d] : s24 = round_shift( t[d] * g15[d], 15 )
y_al  = y_pre asr (e_grid[kvh] - e_min)   e_grid[kvh] = v_ref[layer][kvh] + 14
y_mant, y_exp = bfp_pack semantics over all 3,072 y_al
```

The gate activation is **`ggml_sigmoid`** (`qwen35.cpp:327`), applied to the
attention output before `wo`, and the gate view reads **pre-norm** `Qcur_full`.
The same file's `build_norm_gated` uses **silu**, but only from the DeltaNet
path. Two gates, two activations, and confusing them is a one-line change that
produces plausible output.

### 1.1 Where the spec is ambiguous or self-contradictory

Stated rather than silently resolved, as required.

1. **`y_addr` width contradicts itself.** C spec 1.4 declares
   `y_addr : out std_logic_vector(10 downto 0)` -- 2,048 entries, an 0.8B
   count. Section 3.10 says 3,072 entries and 12 bits, and flags 1.4 as needing
   the edit. **12 bits is correct** (12 query heads x 256). The declaration in
   1.4 has been left stale through at least two revisions.

2. **`layer : in integer` in section 1.4 violates the project's own rule.**
   C spec 3.2's closing paragraph states as normative that "no datapath value
   transits a VHDL `integer`", and 1.4 declares `layer`, `cur_pos` and
   `ctx_len` as `integer`, plus three exponents. Exponents and indices are
   explicitly exempted by that rule, so this is arguably legal, but the
   exemption is stated for "exponents, shifts and indices only" and `cur_pos`
   is compared against `ctx_len`, which is a datapath comparison. The
   skeleton in `rtl/attn_c_ports_skel.vhd` uses `unsigned`/`signed` throughout.

3. **The sigmoid cone's DSP row is stale.** C spec 3.8 books the sigmoid cone
   at **8 DSP**, citing the 2026-08-25 measurement of `micro_sig_cone` at
   verbatim `fixed_pkg.sigmoid_q` widths. On the **same day**, the whole-die
   reconciliation measured the **narrowed** cone at **1 DSP and 510.7 MHz,
   bit-identical to the wide form over 5,769 outputs including both saturation
   corners** (`docs/debugging/2026-08-25_whole-die-budget-reconciliation.md`,
   `sim/micro/micro_silu_narrow.vhd` with `SILU = 0`). C's row was never
   updated. This is 7 DSP that C is currently booked for and does not need. See
   section 3.

4. **The expected rescale-event count is quoted without a derivation.** C spec
   3.7 uses "~46 events"; section 3.3 separately says `E[R] = H_n ~= 8.2`. The
   two are different quantities -- 8.2 is per head, 46 is meant to be per
   6-head group -- and neither is derived in the document. The correct
   expression for the number of positions at which at least one of `G = 6`
   exchangeable sequences sets a new maximum over `n` positions is
   `sum_{k=1..n} [1 - (1 - 1/k)^G]`, which at `n = 2048, G = 6` evaluates to
   **37.6**, not 46. The difference is 2,000 cycles per token and changes
   nothing, but the figure should carry its derivation.

5. **C spec 2.5's "17 beats per master per position" is superseded but still
   appears in three places.** Section 3.0 supersedes it to 8.5 beats of 256
   bits. This document uses 8.5 throughout.

6. **`MAXCTX` is pinned at 2,048 everywhere while section 4.2 argues context is
   capped near 32K by memory.** Every width in the spec -- `s` at u26, the
   divider at NW = 44, the SIN phase -- is stated parametrically and evaluated
   only at 2,048. This is flagged in the spec's own open list (3.13 item 9) and
   remains open; nothing in this document is valid at 32K without re-deriving
   those three widths.

---

## 2. Decomposition into units

One line each on what the unit computes. The `_skel` suffix marks the two files
written alongside this document.

| Unit | Computes |
|---|---|
| `attn_qk_norm` | Per-head RMSNorm over 256 elements and its data-dependent output exponent; wraps the existing `rmsnorm_rs` at `LANES = 1` |
| `attn_twiddle` | `phi_j = low32(cur_pos * W_j)` and the Q15 sin/cos pair by interpolation into one 1,024-entry table; no per-position ROM |
| `attn_rope` | The NEOX-paired rotation of dims 0..63 of one head vector, one pair per cycle, `rope.vhd`'s kernel arithmetic at NEOX indexing |
| `attn_kv_quant` | The per-32-block BFP quantizer of step 4, producing the 272 B record, and the `v_ref` write-time min-fold |
| `attn_kv_axi` | Two read masters and one write master over HBM; burst splitting at 4 KB, 16-byte record-phase realignment, drain-then-flush on `start` |
| `attn_lane` | One MAC lane: score `q s16 x k s8`, PV `e u13 x v s8`, and (optionally) rescale `acc s36 x f u13`, with registered operand muxes. **`rtl/attn_lane_skel.vhd`** prices it |
| `attn_score_tree` | Per-head 32:1 fabric adder tree reducing one dim-tile of lane products to one `partial[b]`, plus the `asr (e_k[b] - e_min)` alignment and the s32 sum |
| `attn_acc` | 6 x 256 x s36 accumulator files, `ACC_N = 8` per lane, one shared adder per lane |
| `attn_softmax` | Grid-snapped running maximum, the pipelined EXP_ROM cone, `s` accumulation, rescale factor generation and rescale-pass sequencing |
| `attn_recip` | `r = floor(2^(p+15)/s)` on one shared `divider_rs`, 12 heads sequentially per layer |
| `attn_gate` | Sites 6b/6c/6d/6e: reciprocal-multiply, Q12 gate conversion, Q15 sigmoid, gate multiply, one element per cycle |
| `attn_emit` | Site 6f: grid align to `e_min`, `bfp_pack` semantics over 3,072 elements, `y` stream out |
| `attn_ctrl` | The job FSM, the position schedule, the two-position PV lag, and every latch instant. **`rtl/attn_c_ports_skel.vhd`** is its interface |

`attn_lane`, `attn_score_tree` and `attn_acc` are the replicated array;
everything else is a fixed cost. That split is the whole structure of the DSP
budget.

### 2.1 RECONCILIATION, appended 2026-08-29: the RTL took a different decomposition

**The table above is a DESIGN-TIME decomposition and it is not the file layout
that was built.** Six of its thirteen names exist in no `rtl/` file, and
`docs/2026-08-28_9b-completeness-audit.md` section 1.4 read that as six absent
units and rated subsystem C *"the array does not exist"*. That verdict was
correct when it was written and is wrong now, and the shape of the mistake is
worth more than the correction: **an absent NAME was read as an absent
RESPONSIBILITY.**

This section maps every row of the table above to what implements it. It does
not change the table, and it does not change the DSP budget in section 3 -- the
budget is derived from operand widths and lane counts, both of which survived
the regrouping intact (`rtl/attn_mac_array.vhd:226-228`: the A operand is sized
by the rescale mode at `ACC_W`, "that is the whole reason the lane is 2 DSP").

**Every file:line below is read at commit `abbd2ed`**, against a working tree
verified clean for `rtl/` (`git status --porcelain rtl/` empty). Where a
document and the RTL disagree, the RTL wins; this section is that rule applied
to this document.

| spec name | status | what implements it, at `abbd2ed` |
|---|---|---|
| `attn_qk_norm` | **no file of that name, and deliberately so** | `rtl/rmsnorm_rs.vhd:59` instantiated DIRECTLY as `u_norm`, `rtl/attn_block.vhd:772`, at `NORM_LANES = 1`. The spec's own line for this row is "wraps the existing `rmsnorm_rs` at `LANES = 1`"; a wrapper that only renames ports is a seam with no content, so none was written. ONE shared instance serves 14 invocations per layer (`rtl/attn_block.vhd:20-21`) |
| `attn_twiddle` | present | `rtl/attn_twiddle.vhd`; `rtl/attn_block.vhd:779` |
| `attn_rope` | present | `rtl/attn_rope.vhd`; `rtl/attn_block.vhd:790` |
| `attn_kv_quant` | present | `rtl/attn_kv_quant.vhd`; `rtl/attn_block.vhd:806` |
| `attn_kv_axi` | **present, and NOT inside `attn_block`** | `rtl/attn_kv_axi.vhd:267`. Instantiated one level UP, at `rtl/llama_top.vhd:3420`, inside the `gkvaxi` generate gated by `C_KV_AXI` (`:405`, default `false`). `attn_block` presents a one-cycle memory-port seam plus four `_rdy` handshakes instead, and its header (`:44-56`) argues that is a boundary and not a stub |
| `attn_lane` | **implemented, no file of that name** | `rtl/attn_mac_array.vhd`. The `LANES = QH_TILE*DIM_TILE` multiply is the loop at `:431-433`; the three operand modes are muxed ahead of it and registered (`A_W`/`B_W` at `:226-231`). `rtl/attn_lane_skel.vhd` is still present and is still a pricing harness that computes an XOR digest -- MEASURED, it is instantiated by nothing in `rtl/`, `sim/`, `tb/` or `hw/` |
| `attn_score_tree` | **implemented, SPLIT ACROSS TWO FILES** | The multiply and the per-head `DIM_TILE`-term fabric adder tree are `rtl/attn_mac_array.vhd:441-456` (`M_SCORE`, with the `P_W` overflow check at `:447-450`). The `asr (e_k[b] - e_min)` alignment, the s32 sum and the Q12 conversion are `rtl/attn_score_q12.vhd:128`, instantiated at `rtl/attn_block.vhd:845`. **Half of this row existed before the array did**, which is why the audit could see the file and still call the unit absent |
| `attn_acc` | **implemented, no file of that name** | `rtl/attn_mac_array.vhd:242,247` declares `acc` as `NACC = QH_TILE*ACC_N*DIM_TILE` entries of `signed(ACC_W-1 downto 0)`; the read-modify-write with ONE shared adder per lane is `:457-470`, and the readback mux is `:492` |
| `attn_softmax` | present | `rtl/attn_softmax.vhd`; `rtl/attn_block.vhd:861` |
| `attn_recip` | present | `rtl/attn_recip.vhd`; `rtl/attn_block.vhd:875` |
| `attn_gate` | present | `rtl/attn_gate.vhd`; `rtl/attn_block.vhd:885` |
| `attn_emit` | present | `rtl/attn_emit.vhd`; `rtl/attn_block.vhd:901` |
| `attn_ctrl` | **implemented, no file of that name** | `rtl/attn_block.vhd`'s own phase machine: `type ph_t` at `:586-597`, **36 states**, signal `ph` at `:598`, the `case ph is` at `:1140`. `rtl/attn_c_ports_skel.vhd` remains the documented interface and remains instantiated by nothing (MEASURED) |

**Not on this document's list at all, and real:** `rtl/attn_score_q12.vhd`
(504 lines, bit-exact against `ref/attn_score_q12_vec.c`, which is itself checked
against three double-precision oracles). It is half of `attn_score_tree`. A
thirteen-row table that omits a real unit is the same defect class as six rows
that name units nobody built.

**Why three names became one file, in the RTL's own words**
(`rtl/attn_mac_array.vhd:13-18`):

> This file is attn_lane + attn_score_tree + attn_acc from the C skeleton's
> section 2 table, as ONE unit. They are one unit here and three names there
> because the accumulator file cannot be separated from the lane that writes
> it: C spec 2.6 measures the read mux going non-linear above 16 entries per
> lane precisely because the file is INSIDE the lane, and a decomposition that
> put a port between them would be pricing a structure nobody builds.

**What this reconciliation does NOT claim.** It says the responsibilities are
implemented and where. It says nothing about whether they are implemented
CORRECTLY -- that is a separate question with a separate answer, and the answer
is `ref/attn_block_vec.c` (commit `8baa413`), the first block-level oracle,
which found 64 of 64 mantissas wrong and bisected to two independent defects
that seven passing properties and 13 of 17 wiring mutations had not seen. The
per-unit evidence classes in the audit's section 1.4 were all honest and none of
them predicted that.

**Three deviations from this document that are live, and are NOT reconciled by
renaming anything**, all self-declared in `rtl/attn_block.vhd:186-190`:

- **No two-position PV lag and no overlap.** One position at a time. Section
  3.7's cycle budget assumes both, so the built cycle cost is not the budgeted
  cycle cost.
- **G exp cones, not one shared cone.** A deviation from section 3's sizing.
- **The gate is re-read one element at a time**, not through a 512-bit block
  port. Same values, more cycles.

**One stale in-code comment found and deliberately NOT fixed** (five tracks are
live in `rtl/`): `rtl/attn_block.vhd:184-185` says *"`rtl/llama_top.vhd` leaves
them open today and runs one token at cur_pos = 0, where nothing is ever read."*
MEASURED at `abbd2ed`: `rtl/llama_top.vhd:3577` drives `c_cpos` from `tok_pos`,
and the `gkvaxi` branch at `:3387-3430` connects the handshakes. That sentence
was true before `5d0253f` and is false after it.

---

## 3. DSP budget

### 3.1 The primitive, and why operand width is the whole story

A DSP48E2 is a **27x18 signed multiplier**. Every row below is decided by
whether both operands fit that, and nothing else. Rows marked DERIVED are
derived from that rule against the widths pinned in section 1; rows marked
MEASURED carry the date and the file.

### 3.2 The replicated term: `DSP_array = 2 x MACS`, or possibly `1 x MACS`

`MACS = QH_TILE x DIM_TILE`.

- **`DIM_TILE = 32` is forced by the feed.** The FK33 HBM AXI port is 256 bits,
  so one beat delivers 32 int8 mantissas, which is exactly one `KV_BLOCK`. A
  MAC cycle therefore spans exactly one exponent block and the header-first
  record layout delivers all 8 block exponents before any mantissa. `DIM_TILE =
  64` needs two ports per stream.
- **`QH_TILE` must divide `G = 6`**, or the last sub-tile idles. Legal values:
  1, 2, 3, 6.

So the legal `MACS` ladder is **32, 64, 96, 192** at one port per stream, and
384 at two.

The lane cost is **2 DSP**, MEASURED 2026-08-23 by OOC synthesis of a single
lane with the three operand modes muxed and the mode driven by a free-running
counter, with an independent DSP48E2 census agreeing and `USE_MULT = MULTIPLY`
on both tiles; CONFIRMED 2026-08-24 place-and-routed at 64 lanes as 128 DSP.
The second tile is forced by the **rescale mode alone**: `acc` is s36 and
36 > 27. Score (16x8) and PV (13x8) each fit one tile with room to spare.

**Therefore `DSP_array = 2 x MACS`, and the arithmetic is:**

| `QH_TILE` | `DIM_TILE` | `MACS` | `DSP_array` | cycles per (position, KV head) | port duty per master |
|---|---|---|---|---|---|
| 1 | 32 | 32 | 64 | 3072/32 = 96 | 8.5/96 = 9% |
| 2 | 32 | 64 | 128 | 48 | 18% |
| 3 | 32 | 96 | 192 | 32 | 27% |
| **6** | **32** | **192** | **384** | **16** | **53%** |
| 6 | 64 | 384 | 768 | 8 | **106% -- needs two ports per stream** |

`3072` is `G x D x 2` = 6 heads x 256 dims x (score + PV). `8.5` is the
272-byte record in 32-byte beats.

### 3.3 The fixed term: auxiliary units

| Unit | DSP | Basis |
|---|---|---|
| QK-norm, `rmsnorm_rs` at `LANES = 1`, N = 256 | **22** | MEASURED 2026-08-26. `LANES = 4` is 40 DSP **and only 281.8 MHz at N = 256**, so it is a timing failure, not a budget option. See 3.4 |
| exp cone, pipelined, verbatim widths | **8** | MEASURED 2026-08-24 |
| sigmoid cone, Q15 out, **narrowed** | **1** | Anchored on MEASURED 2026-08-25 (`micro_silu_narrow`, `SILU = 0`: 1 DSP, 510.7 MHz, bit-identical over 5,769 outputs). C's site 6d adds a Q15 round and a clamp to 32767, which are a shift and a compare, not a multiply. **ESTIMATE at 1** |
| IMROPE rotation kernel | **8** | MEASURED 2026-08-25 on `rope.vhd` as built. It runs at 206.4 MHz and must be restaged for 300; the restaging is stated not to change the DSP count |
| twiddle generation | **4** | DERIVED: `cur_pos * W_j` is 16x32, so 2 tiles; the sin and cos interpolations are 16x22 each, 1 tile each |
| site 6b, reciprocal-multiply `o s36 x r u16` | **2** | DERIVED: 36 > 27 |
| site 6e, gate multiply `t s24 x g15 u16` | **1** | DERIVED: 24 <= 27, 16 <= 18 |
| `s` rescale multiplier `s u26 x f u13` | **1** | DERIVED: 26 <= 27, 13 <= 18 |
| reciprocal `divider_rs`, NW = 44 / DW = 28 | **0** | MEASURED 2026-08-25 |
| write-side quantizer, score adder trees, all alignment shifters | **0** | By construction. The quantizer is scan/shift/saturate with no division; the trees are fabric, per the A adder-tree-reclaim precedent |
| **total** | **47** | |

**Cross-check against the spec.** Substituting the spec's own two stale inputs
-- sigmoid at 8 rather than 1, everything else identical -- gives
`22 + 8 + 8 + 8 + 4 + 2 + 1 + 1 = 54`, which is exactly C spec 3.8's
corrected total. The derivation reproduces the spec's number from its own
inputs, which is the evidence that it is pricing the same design. The
difference between 47 and 54 is entirely the sigmoid narrowing that was
measured but never written back.

**Two further narrowings are available and are NOT claimed here.** The exp cone
at 8 DSP is the verbatim-width form, and the sigmoid cone -- structurally the
same thing, a Q30 ROM with a linear interpolation -- went from 8 to 1 under
narrowing. The rope kernel's 8 partly reflects `rope.vhd`'s resize-to-32
multiplies and a 16x16 rewrite may cost 4. If both land, aux is **36**. Both
are **UNMEASURED** and neither is booked.

There is a documented trap in the sigmoid narrowing that applies to the exp
cone too (`docs/debugging/2026-08-26_gdn-silu-unit.md`): narrowing the
interpolation delta ALONE does not reduce the DSP count. The multiplicand has
to be narrowed as well -- a `sig` value holding 0..32768 but declared 32 bits
makes `sm * sig` a 16x32 and costs two tiles; at 18 bits it is 16x18 and costs
one. Anyone who narrows only the delta will measure no change and conclude the
lever does not work.

### 3.4 Why `LANES = 1` on the QK-norm, and why the published die ceiling is 18 DSP too high

The whole-die ceiling of 2,648 includes `+22` for C's QK-norm, i.e. it prices
`rmsnorm_rs` at `LANES = 4` and 40 DSP against `LANES = 1` and 22. That branch
is unreachable for two independent reasons, both already measured and both
recorded in C spec 3.8's own correction block:

1. **It does not close.** At N = 256, `LANES = 4` measures 281.8 MHz. C's clock
   target is 300 MHz at the 0.85 V analysis and the die's shared achieved clock
   is B's 299.04 MHz. A unit that misses the clock is not a budget option.
2. **It is not needed.** `rmsnorm_rs` at N = 256, `LANES = 1`, measures **814
   cycles per vector in simulation**. The demand is `(12 + 2) x 16 = 224` norms
   per card per token, so `224 x 814 = 182,336` cycles = 0.61 ms at 300 MHz,
   comfortably inside C spec 3.7's own 290K-cycle serial fallback.

**CORRECTION 2026-08-27 -- reason 1's constant is wrong, its conclusion is
right, and reason 1 now disqualifies the fallback it chose.** The 300 MHz and
299.04 MHz constants are 0.85 V analysis clocks; the shared achieved clock at
the card's VCCINT of 0.717 V is at most **237.812 MHz** (MEASURED,
`sim/ooc_sweep/results.csv:7`). `rmsnorm_rs` at N = 256 has since been measured
at 0.717 V (`docs/2026-08-27_verdicts-at-0.717V.md` section 2.2, MEASURED, run
twice bit-identical):

| `LANES` | Fmax @0.85 V | **Fmax @0.717 V** | vs 237.812 |
|---|---|---|---|
| 1 | 300.75 | **224.57** | **MISS by 13.2** |
| 2 | 281.85 | **211.46** | **MISS by 26.4** |
| 4 | 281.85 | **211.46** | **MISS by 26.4** |

So `LANES = 4` is still rejected, but **`LANES = 1` does not close either**, and
reason 1's own rule -- "a unit that misses the clock is not a budget option" --
applied consistently disqualifies C's chosen fallback as well. There is no
closing configuration of this unit at 0.717 V at any lane count.

**And the cause is not the lane count.** At 0.717 V every one of these forms is
bound by the same path, a DSP48E2-internal multiply in the Q30 Newton rsqrt
(`ARG__N/DSP_A_B_DATA_INST/CLK -> mr_m_reg[65]/D`, 4.414 ns, 87.6% logic), which
is why `LANES = 1` here and `l2norm_rs` at `LANES = 1/2` all report exactly
224.57 MHz. Widening or narrowing lanes does not move it. See
`docs/debugging/2026-08-27_derate-is-not-a-constant.md`.

**On the fix, and a citation to distrust.** `docs/2026-08-27_verdicts-at-0.717V.md`
§6 and the derate note §7 both say "C spec 3.13 item 1 already names `MREG` on
the 34x32 Newton stage as the expected fix". **C spec §3.13 item 1 says the
opposite**: "`MREG` was NOT the fix, and this item predicted that it was". What
the path actually needed is in
`docs/debugging/2026-08-27_newton-rsqrt-cascade-hop.md`: the MREG and the PREG
were already present, and the unregistered part was the **DSP-to-DSP hop**
inside the 34x32 span. A third register level `mr_m2` landed on 2026-08-27 in
`rtl/rmsnorm_rs.vhd` and `rtl/l2norm_rs.vhd`, MEASURED at **+6 cycles per
rsqrt** (`rmsnorm_rs` N=256, 142 -> 148) and **+12 for `l2norm_rs`**. **Its
effect on Fmax at 0.717 V has NOT been measured**, so the figures in the table
above are for the pre-`mr_m2` netlists.

**Do not re-derive this by scaling.** The `x0.835` rule that the earlier budget
pass offered is WITHDRAWN: the measured derate runs 16.5% to 28.0% and 16.5% is
its minimum, so a scaled estimate is optimistic in every case checked. Scaling
put `LANES = 4` at 235.3 MHz against a measured 211.5.

So C's row is **438 DSP on both ends** (384 + 54 as booked), not 438-456, and
**the published die ceiling should fall from 2,648 to 2,630.** Applying the
sigmoid narrowing as well takes C to **431** and the die to **2,599-2,623**.

### 3.5 The total, and the fraction of remaining headroom

Non-C die, from the B spec 3.6 rebuild that produced the 2,606-2,648 range:

```
A, ROWS_IF = 58 post-reclaim   1,914   MEASURED
B, LANES = 32 + conv 16 + scalar 7 + recur 1   226   MEASURED
D, LANES_V = 8                    28   floor (phase sharing), 52 unshared
E                                  0   by construction
non-C total                    2,168 floor .. 2,192 ceiling
```

**Headroom available to C: 2,880 - 2,168 = 712, down to 2,880 - 2,192 = 688.**

| `MACS` | `DSP_array` | aux | **C total** | fraction of the 688-712 left | die total | die % |
|---|---|---|---|---|---|---|
| 32 | 64 | 47 | **111** | 16-16% | 2,279 | 79.1% |
| 64 | 128 | 47 | **175** | 25-25% | 2,343 | 81.4% |
| 96 | 192 | 47 | **239** | 34-35% | 2,407 | 83.6% |
| **192** | **384** | **47** | **431** | **61-63%** | **2,599** | **90.2%** |
| 192 | 384 | 54 (as booked) | **438** | 62-64% | 2,606 | 90.5% |
| 384 | 768 | 47 | **815** | **115-118% -- DOES NOT FIT** | 2,983 | 103.6% |

**The headline number: C at `MACS = 192` needs 431 DSP (438 as currently
booked), which is 61% to 64% of every DSP the rest of the design leaves
unclaimed, and puts the die at 90.2% to 91.3% of 2,880.**

**CORRECTION 2026-08-27 -- the A row above is an unbuildable configuration, and
correcting it moves this whole table in C's favour.** `ROWS_IF = 58` cannot be
built. The HBM port count is a WIDTH budget, `NPORT = ROWS_IF x 9 / 16`, an
exact integer identity with no clock in it; `ROWS_IF = 58` needs **33 ports of
the 30 available** and is not an integer number of ports either. `ROWS_IF` must
be a multiple of 16 and at most 48, so **48 is forced**
(`docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`). A at
`ROWS_IF = 48` is **1,584 DSP** (MEASURED, `sim/ooc_sweep/results.csv:8`), not
1,914. Re-running the block above with that one substitution, DERIVED:

```
A, ROWS_IF = 48 post-reclaim   1,584   MEASURED, results.csv:8
B, LANES = 32 + conv 16 + scalar 7 + recur 1   226   MEASURED
D, LANES_V = 8                    28   floor (phase sharing), 52 unshared
E                                  0   by construction
non-C total                    1,838 floor .. 1,862 ceiling
headroom to C                  1,018 .. 1,042      (was 688 .. 712)
```

Consequences, and the second one is the one that matters:

- C at `MACS = 192` and 431 DSP falls from **61-64% of the remaining headroom to
  41-42%**, and the die from 90.2-91.3% to **2,269-2,300 of 2,880, 78.8-79.9%**.
- **`MACS = 384`'s "DOES NOT FIT" verdict no longer holds on DSP.** 815 DSP
  against 1,018-1,042 available is 78-80%, and the die total is
  **2,653-2,677, 92.1-93.0%**. It still fails, but on **ports**: at 106% port
  duty it needs two ports per stream, and A at `ROWS_IF = 48` has already taken
  27 of the 30, leaving 3 for B, C, D and E combined. **The reason for the
  rejection changes from DSP to ports, and the rejection stands.** The
  `MACS = 384` row of the table above and the "384 does not fit ... exceeds the
  die by itself" bullet later in this section are superseded on that specific
  ground, and only on that ground.

Not corrected here: this substitution costs A time. `ROWS_IF = 48` is
5,187,328 A cycles at 9B against 4,293,888 at 58, **+3.91 ms per token, +21.6%
on A alone** (DERIVED, port-count note section 4.5). That is a whole-die
allocation question of the kind A spec section 15.4c owns, and this document
does not settle it.

**Sensitivity, stated as the parent asked.** `DSP_C = 2 x MACS + 47`. The
array term is 89% of C's total at `MACS = 192` and is the only term that moves
with a design choice. Because the ladder is quantised to
{32, 64, 96, 192, 384} by the feed and the GQA group, the sensitivity is not a
smooth curve but four rungs, and the choice is effectively binary:

- **384 does not fit.** It needs 815 DSP against 688-712 available, exceeds the
  die by itself, and additionally needs a second HBM port per stream because
  its port duty is 106%. The 1.75 ms sweep it buys is unreachable. This is an
  independent confirmation of C spec 3.0's rejection, by different arithmetic.
  (**Superseded in part, 2026-08-27:** with A forced to `ROWS_IF = 48` and 1,584
  DSP, headroom is 1,018-1,042 and 815 DSP **does** fit. The rejection now rests
  entirely on the port half of this bullet, which is stronger than it was: A
  takes 27 of the 30 HBM ports at `ROWS_IF = 48`, leaving 3 for B, C, D and E.
  See the correction earlier in this section, under "the headline number".)
- **96 fits with 200 DSP to spare and doubles the sweep** from 3.51 to 7.01 ms
  at 299.04 MHz, which is +3.5 ms on a ~4.4 ms subsystem. It is the correct
  fallback if routing binds at 192, and it is the only fallback.
  (**At the MEASURED 237.812 MHz: 4.41 to 8.82 ms, +4.4 ms on a ~5.5 ms
  subsystem.** DERIVED 2026-08-27; the cycle counts and the 2x ratio are
  unchanged.)
- **192 is the unique choice.** It is the largest legal rung that fits.

### 3.6 The one lever that could still move the array term, priced and not taken

The lane is 2 DSP **only because of the rescale mode**. A two-mode lane
(score 16x8, PV 13x8) should be 1 DSP by the 27x18 rule. If rescale moves to a
dedicated array of `R` multipliers at 2 DSP each, sweeping the 1,536
accumulators in `1536/R` cycles:

| `R` | `DSP_array` | rescale pass | extra cycles per token | extra ms @299.04 | **extra ms @237.812** | accumulators per rescale unit |
|---|---|---|---|---|---|---|
| on-lane (spec) | **384** | 8 cyc | 9,728 | 0.033 | **0.041** | 8 |
| 96 | 384 | 16 | 19,456 | 0.065 | **0.082** | 16 |
| 48 | **288** | 32 | 38,912 | 0.130 | **0.163** | 32 |
| 24 | **240** | 64 | 77,824 | 0.260 | **0.327** | 64 |
| 8 | **208** | 192 | 233,472 | 0.781 | **0.982** | 192 |

The `@237.812` column is DERIVED 2026-08-27 from the same cycle counts at the
MEASURED operating clock; the `@299.04` column is a 0.85 V analysis figure and
is kept for traceability.

At `R = 48` this is **96 DSP -- 3.3% of the whole die -- for +0.13 ms**, on a
die that is at 90-92%. (**+0.163 ms at the measured clock.**)

**It is not recommended without a measurement, for a stated reason.** C spec
2.6 measured the accumulator read mux going non-linear above 16 entries: at
`ACC_N = 32` a lane measures 543 LUT against a linear prediction of 478,
because the 32:1 mux exhausts the F7/F8 chain and needs a third fabric level.
A rescale unit serving 32 accumulators is exactly that shape. The saving is
therefore **not** the naive 96 DSP; it is 96 DSP minus an unmeasured LUT and
timing cost, and at `R = 96` -- the largest grouping inside the measured safe
limit -- there is **no saving at all** (384 either way).

`rtl/attn_lane_skel.vhd` exists specifically to answer the first half of this
by synthesis: its `RESCALE_ON_LANE` generic prices the two-mode lane against
the three-mode one, and the three-mode branch must reproduce the measured 2 DSP
or the skeleton is not pricing the right thing. **This is the single
highest-value measurement available on C's budget.**

### 3.7 Resources that are not binding

Stated only to confirm they are not binding, not derived here.

- **LUT.** The measured per-lane fit is `158 + 10.0 x ACC_N` at `ACC_N = 8`, so
  `192 x 238 = 45.7K` for the array, and C spec 3.8 puts C's total at ~80K.
  Die-wide LUT is at ~64.2% of 439.7K. Not binding, and it has ~35 points of
  slack against DSP's ~9.
- **FF.** `192 x (182 + 36.4 x 8) = 90.8K` for the array plus ~67K elsewhere,
  ~158K of 879K = 18%. Not close.
- **BRAM36.** ~13, against 216. Not close.

The one caveat is that **high utilisation on this device is historically
non-deterministic**: `rmsnorm.vhd:296`, `bfp_pack.vhd`'s header and the
`attention_ml` debug history all document congestion-induced behaviour at lower
utilisation than 90%. DSP fitting is necessary, not sufficient.

---

## 4. Cycle model per token

Per card, `ctx_len = 2048`, `MACS = 192`, exp cone pipelined, 16 attention
layers, 12 query heads and 2 KV heads per card. Comparable in form to the B
spec's state-sweep model. Every row shows its arithmetic.

| Component | Arithmetic | cycles | ms @300 | ms @299.04 |
|---|---|---|---|---|
| KV sweep | `16 lyr x 2 kvh x 2048 pos x 16 cyc` | **1,048,576** | 3.495 | 3.506 |
| rescale stalls, expected | `38 events x 8 cyc x 32 (lyr,kvh) sweeps` | 9,728 | 0.032 | 0.033 |
| QK-norm, exposed | `16 lyr x 8 norms x 814 cyc` | 104,192 | 0.347 | 0.348 |
| IMROPE | `16 lyr x (14 heads x 32 pairs + fill)` | 8,000 | 0.027 | 0.027 |
| KV quantize + write | `16 lyr x 4 vectors x 2 passes x 256` | 32,768 | 0.109 | 0.110 |
| gate + output stage | `16 lyr x (2 x (6 x 46 + 6 x 256) + 3072)` | 107,136 | 0.357 | 0.358 |
| **C total per token** | | **1,310,400** | **4.368** | **4.382** |

**The sweep is 80% of C.** Every other term together is 0.87 ms.

**CORRECTION 2026-08-27 -- the ms columns above are 0.85 V analysis clocks.**
The two columns are kept as printed for traceability. At the MEASURED operating
clock of **237.812 MHz** (`sim/ooc_sweep/results.csv:7`, VCCINT 0.717 V) the
same cycle counts give, DERIVED:

| Component | cycles | **ms @237.812** |
|---|---|---|
| KV sweep | 1,048,576 | **4.409** |
| rescale stalls, expected | 9,728 | **0.041** |
| QK-norm, exposed | 104,192 | **0.438** |
| IMROPE | 8,000 | **0.034** |
| KV quantize + write | 32,768 | **0.138** |
| gate + output stage | 107,136 | **0.451** |
| **C total per token** | **1,310,400** | **5.511** |

The "80% of C" split is a cycle ratio and is unaffected. The 0.87 ms of aux
terms becomes **1.10 ms**.

**237.812 MHz is itself an upper bound for C, not a promise.** It is
`matvec_core`'s number. Every norm unit measured at 0.717 V is below it, and
C's own QK-norm unit `rmsnorm_rs` at N = 256 measures **211.46 MHz** at
`LANES = 2/4` and **224.57 MHz** at `LANES = 1`
(`docs/2026-08-27_verdicts-at-0.717V.md` section 2.2, MEASURED). If C's own
clock binds the die, every ms above scales again by `237.812 / f_actual`.

Notes on the rows that are not simple products:

- **KV sweep, 16 cycles per (position, KV head).** Cycles 0-7 are score(p): 8
  beats of K, one exponent block per cycle, `partial[b]` through the per-head
  tree, aligned to `e_min` and accumulated. Cycles 8-15 are PV(p-2): 8 beats of
  V, `v_aligned` e-weighted into the accumulators. **PV trails score by TWO
  positions**, not one, because the group's 6 scores complete together and the
  shared exp cone then needs 6 conversions plus 3 stages of latency = 9 cycles,
  which does not fit the 8 cycles a one-position lag allows.

- **Rescale events, derived rather than quoted.** The number of positions at
  which at least one of `G = 6` exchangeable score sequences sets a new maximum
  over `n = 2048` positions is `sum_{k=1..n} [1 - (1-1/k)^6] = 37.6`, rounded
  to 38. C spec 3.7 uses 46 without derivation; the difference is 2,000 cycles
  per token, immaterial either way. **The worst case is not immaterial**:
  `R = cur_pos` under adversarial monotone-rising scores gives +524K cycles
  (+1.75 ms) and an L1 softmax weight distortion of 0.25, which C spec 3.3
  calls unacceptable if hit. There is observability (`rescale_max`) and no
  mitigation.

- **QK-norm exposure assumes group overlap.** 224 norms at 814 cycles is
  182,336 cycles serial. With the two Q register planes of C spec 3.1, group 1's
  norms run under group 0's 32,768-cycle sweep, so only the FIRST group's norms
  are exposed: 6 Q heads + 2 K heads = 8 per layer. If the overlap control is
  not built -- C spec 3.13 item 7 says it is priced but not designed -- the row
  is 182,336 and C's total is **1,388,544 cycles = 4.643 ms @299.04**
  (**5.839 ms at the MEASURED 237.812 MHz**, DERIVED 2026-08-27; the exposed
  row alone is 182,336 cycles = **0.767 ms** there).

- **This is 0.2 ms below C spec 3.7's ~4.59 ms @300 MHz** and the entire
  difference is the QK-norm row: 3.7 carries 166K cycles, derived before
  `rmsnorm_rs` existed at an assumed 1,296 cycles per invocation. The measured
  unit is 814. C spec 3.13 item 1 explicitly declines to re-derive it from
  outside; that is done here, and 3.7's row should be updated to 104K.

**Nothing in this table is a promise of routed silicon.** No Fmax measurement
exists at 192 lanes -- the routed 339.6 MHz is at 64, and broadcast fanout
grows with lane count -- so both the 300 and 299.04 columns are conditional on
a gate that has not been run.

---

## 5. Entity and port sketches, with handshake discipline

Two skeletons are written alongside this document and both analyze clean:

```
ghdl -a --std=08 -frelaxed --workdir=<scratch> rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
ghdl -a --std=08 -frelaxed --workdir=<scratch> rtl/attn_lane_skel.vhd
ghdl -a --std=08 -frelaxed --workdir=<scratch> rtl/attn_c_ports_skel.vhd
```

Both were run on 2026-08-27 and both returned clean. Note that this backend is
GHDL **mcode**: `ghdl -e` produces no binary and silently succeeds, so
analysis is the only check these files have had. **Neither is an
implementation.** `attn_c_ports_skel` ties every output off and computes
nothing; `attn_lane_skel` computes an XOR digest and is a synthesis pricing
harness in the established `micro_b_lane` style.

### 5.1 The two rules, from B's 2026-08-27 defects

**RULE 1: no completion or result signal is a bare pulse.** From
`docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md`: `gdn_head_emit`'s
`done` was a one-cycle pulse with no handshake, the reduce ran on whatever bank
was pending regardless of whether the consumer was free, and a consumer busy
elsewhere when the pulse landed **lost an entire head**. The unit then went
idle with both banks empty, looking healthy. Every completion signal below is
held until an explicit ack, and every ack input **defaults to `'1'`** so an
unconnected testbench reproduces the old pulse semantics exactly. That default
is the gdn_head_emit convention and it makes the change strictly a widening.

**RULE 2: every input read for longer than one cycle is latched at a named
instant, and the instant is made observable.** From
`docs/debugging/2026-08-27_gdn-emit-chain-w-latch.md`: `w_mant` was a single
unlatched port read combinationally once per head for 24 heads while blocks
overlap by design, so head 23 of every block normalized with the NEXT block's
weights. Heads 0 through 22 were bit-exact. **The rejected fix was "document
the timing contract instead of latching"** -- a safe window did exist, but it
was not observable from outside the unit, and a contract a producer cannot see
is a bug waiting on a schedule change.

**And the generalisable lesson from both:** in a design whose producer cannot
be back-pressured, throughput margin is a **correctness** property and it
appears in no static report. Worse, the lossy path scores **better** on the
obvious metric -- COL_GAP=3 went from "0 refused columns" to "167 refused
columns" as a result of a bug **fix**. Read a zero back-pressure count as a
question, not a result.

### 5.2 Back-pressure, stated per interface

Required by the project rule: for every interface, whether the producer can be
stalled, and if not, what bounds the consumer's service time.

| Interface | Producer stallable? | If not, what bounds service time |
|---|---|---|
| `qg_rbaddr/rdata`, `k_*`, `v_*` (A's activation memory) | **N/A -- C is the master.** C drives the address; a memory cannot refuse and C never issues an address it is not ready to consume. No loss is possible in this direction | -- |
| AXI R channel (2 read masters) | **Yes**, RREADY. Standard | -- |
| AXI B channel (write master) | **Yes**, BREADY | -- |
| `attn_lane` array -> `attn_score_tree` | **No.** The array runs on a fixed 16-cycle position slot driven by the AXI beat rate; it cannot stall mid-slot without desynchronising from the K stream | The tree is combinational-plus-register with a fixed 5-level depth; its service time is 1 cycle per dim-tile by construction |
| `attn_softmax` exp cone -> PV mode of the array | **No.** The cone is a fixed-latency 3-stage pipeline with no ready. This is C's internal `gdn_recur_pipe`: an `e_p` the array does not take is a lost weight, not a delayed one | **The two-position PV lag is the bound, and it is the entire reason the lag is two rather than one.** 6 conversions + 3 stages = 9 cycles against the 8 a one-position lag allows. A rescale stall inserts 8 cycles, and the cone must be held off at its INPUT (valid gated) rather than stalled at its output |
| `attn_gate` -> `y_pre` scratch | **Yes**, internal, 1 element/cycle into 2 BRAM36 | -- |
| `y_we/y_addr/y_data/y_exp` -> A's activation memory | **NO, as the spec is written.** C spec 1.4 and 3.10 declare no ready. C is then a producer that cannot be stalled, structurally identical to `gdn_recur_pipe` | **Today: nothing bounds it at the interface. It is safe only because subsystem D guarantees A is idle while C runs (C spec 2.7: A and C are never active simultaneously).** That is a schedule property, not an interface property, and it is exactly the invisible contract that the `w_mant` defect punished. **`rtl/attn_c_ports_skel.vhd` adds `y_ready : in std_logic := '1'`**, which changes nothing for a consumer that genuinely cannot stall and converts the failure from silent loss into a visible stall |
| `done` -> D | **See RULE 1.** The spec says one-cycle pulse | `done_ack : in std_logic := '1'` added. D is believed to be always waiting at that instant, which is the same unobservable-safe-window argument that was rejected for `w_mant` |

### 5.3 The latch instants

Every one of these is a RULE 2 site. `attn_c_ports_skel` declares the
observable pulse for each.

| Latched | When | Pulse | Why it matters |
|---|---|---|---|
| `layer`, `cur_pos`, `ctx_len`, `k_base`, `v_base` | on `start` | `cfg_taken` | D advancing the descriptor mid-job corrupts the tail of the job and nothing else, which is the head-23 shape exactly |
| `qn_rdata[0..255]`, `kn_rdata[0..255]`, `qn_exp`, `kn_exp` | at the start of the layer | `wn_taken` | **This is the direct `w_mant` analogue.** 14 norms per layer on one shared `rmsnorm_rs` instance means the read window is ~11,400 cycles. If D presents the next layer's norm weights while the last head is normalising, that head alone is wrong |
| `qg_exp`, `k_exp`, `v_exp` | with their vectors | (covered by `cfg_taken`) | Three independent A jobs with three independent `y_exp` values; C spec defect C2 was a single shared `x_exp` port that could not represent the data |
| `kv_seq_rst` effect on the `v_ref` fold | on the level | `seq_rst_taken` | The init value +127 **is not neutral**: an init of 0 right-shifts every V block by its full exponent and silently destroys the cache's precision while passing every structural check |

### 5.4 One simulation-only generic

`STRICT_PRODUCER : boolean := false`, following `gdn_emit_chain`. It asserts
that a producer which cannot be stalled is never refused, and that a latched
input is stable across its window. An assertion synthesizes to nothing, so it
costs no area, and it is the **only** thing that catches this defect class:
`gdn_emit_chain`'s own history records three configurations that were all
bit-exact and differed only in how many columns they silently dropped. The
defect was invisible to a value check and invisible to synthesis.

### 5.5 Entity sketch, `attn_lane`

Full text in `rtl/attn_lane_skel.vhd`. The load-bearing points:

```vhdl
generic( RESCALE_ON_LANE : boolean := true;   -- true = the measured 2-DSP lane
         ACC_W : positive := 36;  E_W : positive := 13;
         Q_W   : positive := 16;  K_W : positive := 8 );
port( clk, rst, en : in std_logic;
      q_in : in signed(Q_W-1 downto 0);   k_in : in signed(K_W-1 downto 0);
      e_in : in unsigned(E_W-1 downto 0); v_in : in signed(K_W-1 downto 0);
      a_in : in signed(ACC_W-1 downto 0); f_in : in unsigned(E_W-1 downto 0);
      digest : out std_logic_vector(31 downto 0) );
```

**Registering the operand muxes is normative, not an optimisation.** C spec
2.6's MEASURED 2026-08-24 block: the routed 64-lane array made 246 MHz with
combinational operand muxes and **340 MHz with them registered**, at the same
128 DSP and 5% **fewer** LUT. The registers are `AREG`/`BREG` and exist in the
tile whether used or not, so the stage is free; its cost is one cycle of
latency, which the two-position PV lag already absorbs. A DSP48E2 census on any
build must show `AREG/BREG = 1` on every datapath multiplier or the number does
not describe what will be built.

This also satisfies the project's timing rule directly: bus mux and multiply
are two of {barrel shift, wide add, wide compare, bus mux, multiply} and are in
separate stages here. The unit that violated that rule held at 117.2 MHz and
reached 300.8 after the states were split, and **`MREG` was not the fix** -- it
was worth 26 MHz of the 183, and a version written with the MREG cadence
already in it measured 117.2, worse than the original.

### 5.6 Entity sketch, subsystem C top

Full text in `rtl/attn_c_ports_skel.vhd`, with the handshake reasoning inline
on every port. Differences from C spec 1.4, all of them deliberate:

| Change | Reason |
|---|---|
| `y_ready : in std_logic := '1'` **added** | 5.2, the only loss-capable interface at the top level |
| `done_ack : in std_logic := '1'` **added**, `done` held not pulsed | RULE 1 |
| `cfg_taken`, `wn_taken`, `seq_rst_taken` **added** | RULE 2 |
| `y_addr` widened 11 -> 12 bits | 3,072 entries at 27B N=2. C spec 3.10 already flags 1.4's declaration as stale |
| `layer`, `cur_pos`, `ctx_len` as `unsigned`, exponents as `signed(7 downto 0)` | C spec 3.2's "no datapath value transits a VHDL integer" |
| `v_ref` is **not** a port | Folded internally at write time; C spec CR5-1 deleted the port and left its comment standing for a revision |

---

## 6. What I could not determine

Required section. Each item says what is unknown and what would settle it.

1. **Whether the two-mode lane is actually 1 DSP.** This is the largest open
   question in the budget: it is worth up to 96 DSP, 3.3% of a die at 90-92%.
   The 27x18 rule says it should be, and the measured 2-DSP lane included the
   36-bit rescale operand that forces the second tile. **Not measured.** Settled
   by synthesizing `rtl/attn_lane_skel.vhd` over `RESCALE_ON_LANE` in
   {true, false} on `xcvu33p-fsvh2104-2L-e` at 3.333 ns via `sim/ooc_micro.tcl`.
   The `true` branch must reproduce 2 DSP first, or the `false` branch's number
   means nothing.

2. **Whether the saving in item 1 survives the accumulator read mux.** A
   rescale unit serving 32 accumulators is the shape C spec 2.6 measured going
   non-linear (543 LUT against a predicted 478, F7/F8 chain exhausted). At the
   largest grouping inside the measured safe limit there is no saving at all.
   **The LUT and Fmax cost of the crossing mux is unpriced**, so item 1's 96
   DSP is an upper bound on a saving, not a saving.

3. **Whether the exp cone narrows the way the sigmoid cone did (8 -> 1).** They
   are structurally the same thing. **Not attempted, not measured.** Worth 7
   DSP. The documented trap is that narrowing the interpolation delta alone
   changes nothing; the multiplicand must be narrowed too.

4. **Whether the IMROPE kernel is 4 DSP rather than 8** under a 16x16 rewrite.
   The 8 is measured on `rope.vhd` as built, which also runs at 206.4 MHz and
   must be restaged regardless. **Not measured.** Worth 4 DSP.

5. **Fmax at 192 lanes. This is the largest risk in the document and it is not a
   DSP question.** The routed 339.6 MHz is at **64** lanes. Broadcast fanout
   grows with lane count -- `k` and `v_aligned` fan out `G`, `e` and `f` fan out
   `DIM_TILE`, control fans out to all 192 -- and at 64 lanes the limiter had
   **already moved** to the DSP-to-DSP cascade the 36-bit operand split
   requires, with `MREG` unused and unusable because it would break that path.
   Baseline logic delay was flat at 2.38-2.45 ns from 1 lane to 64 while net
   delay grew 0.66 to 1.76 ns. **Do not extrapolate.** If 192 does not route,
   the only fallback on the legal ladder is 96, which doubles the sweep.

6. **HBM port efficiency for C's specific 2R+1W mix.** Measured on the card:
   read and write masters on **independent** pseudo-channels cost nothing
   (288.0 GB/s against read-only's 288.0, matching to one cycle in 1.6
   million), but a single master mixing reads and writes into **one**
   pseudo-channel gets 81.8%, entirely DRAM bus turnaround. That 81.8% is a 1:1
   ratio at ARLEN=15 and C is 2:1. **C's actual mix is unmeasured** and the
   53% duty premise in section 3.2 rests on it. The 81.8% must not be
   substituted for C's number.

7. **Whether the group-overlap control can be built.** The section 4 QK-norm row
   of 104K cycles assumes it. C spec 3.13 item 7 says it is priced but not
   designed. If it is not built the row is 182,336 and C's total moves from
   4.382 to 4.643 ms at 299.04 MHz. That is a 6% cost, not a fit question.
   (**At the MEASURED 237.812 MHz: 5.511 to 5.839 ms.** DERIVED 2026-08-27. The
   6% is a ratio of two figures at one clock and survives unchanged.)

8. **Real 27B attention score dynamics, and therefore the rescale regime.** The
   expected `R = 37.6` derived in section 4 assumes exchangeable score
   sequences. The worst case is `R = cur_pos` and costs +1.75 ms and an
   unacceptable 0.25 L1 weight distortion. **No measurement of real 27B score
   sequences exists**; the stories260K analog does not transfer. There is
   observability (`rescale_max`) and no mitigation.

9. **Whether `MACS = 192` is compatible with D's unshared corner.** The
   headroom of 688 assumes D lands at 52 rather than 28, which is the worst
   case of a subsystem with **no RTL at all**. If D overruns 52, C at 438 is
   what pushes the die over. C is 61-64% of the remaining headroom, so C and D
   are coupled and neither can be sized alone.

10. **Everything in this document is at `MAXCTX = 2048`.** The widths for `s`
    (u26), the reciprocal (NW = 44) and the SIN phase are stated parametrically
    in the spec and evaluated only at 2,048. Section 4.2's 32K ambition
    re-derives them (`s` to 28 b, NW to 48) and none of the cycle figures here
    survive that change: the sweep is linear in `ctx_len`, so 32K is 16x, or
    56 ms.

11. **No Vivado was run.** Deliberately, at the parent's instruction. Every
    "MEASURED" row is a transcription from a prior run, with its date; every
    "DERIVED" row is operand-width arithmetic. The composite figure of 431 has
    never been synthesized as an assembly, and C spec 3.11 gate 5 (routed,
    DSP <= 440, Fmax >= 300 with AREG/BREG = 1 on every multiplier) remains the
    check that would make it real.

---

## 7. Files

| Path | What it is |
|---|---|
| `docs/superpowers/specs/2026-08-27-C-gated-attention-skeleton.md` | this document |
| `rtl/attn_lane_skel.vhd` | DSP pricing skeleton for the replicated lane; `RESCALE_ON_LANE` generic answers item 1 above. Analyzes clean, computes nothing real |
| `rtl/attn_c_ports_skel.vhd` | Subsystem C top-level interface with the handshake discipline of section 5. Analyzes clean, ties every output off |
