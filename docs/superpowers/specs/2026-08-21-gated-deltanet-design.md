# Subsystem B: Gated DeltaNet

Design spec, 2026-08-21. Milestone `v2.2`. **Revision 1.**

**STATUS: sections 1-2 only. Section 3 (datapath scheduling, nonlinearity
implementations, validation, acceptance criteria) is deliberately unwritten**
pending review of this foundation, because section 3's arithmetic depends on
every decision here. This mirrors how subsystem C's spec was staged.

**DEVICE-PARAMETRIC.** Like subsystem A, this spec scales between the AXU3EG
(`v3.0`) and the FK33 (`v4.0`/`v5.0`) by changing generics, not the datapath.
§2.8 carries both device columns; §2.9 states what is invariant between them and
what changes. Where a decision differs by target it is written as a generic plus
a per-target value.

## 0. Revision history

**Rev 1.** No adversarial review has run against this document yet. Every
arithmetic bound below is derived in-text rather than asserted, but none has
been independently recomputed; A took 4 review rounds before its §7.4 survived
one, C took 5 for its §2.1, and there is no reason to expect rev 1 of this
document to be different.

Process rules inherited from A and C, applied from this first revision:

- **One normative subsection (§2.1) owns every exponent, alignment and rounding
  decision.** No other section restates a rule; they reference it. (C rev 4
  lesson, A §7.4 lesson.)
- **The automated reference sweep** (extract all section anchors, extract every
  `§N.M` reference, report unresolved ones) runs after every edit pass. (C rev 6
  process change.)
- **Interface ports are cross-checked against the contract**, since C's CR5-1
  was a port contradicting §2.1 while both individually looked plausible.
- **Alignment references are minima, so alignment shifts are unconditionally
  right shifts** wherever possible (C's CR4-1/MJ4-1 lesson). Every alignment in
  §2.1.4 follows this policy; none needs saturation.

## 1. Context and scope

Subsystem B implements the **18 Gated DeltaNet (linear attention) layers** of
Qwen3.5-0.8B — indices 0-2, 4-6, 8-10, 12-14, 16-18, 20-22 of 24, i.e. every
layer where `(i+1) % 4 != 0` (`qwen35.cpp:27`, the `full_attention_interval = 4`
default). The other 6 are full attention and belong to subsystem C. See
`docs/fpga-hardware-recon.md` for the ladder,
`2026-08-20-int4-streaming-matvec-design.md` for subsystem A, and
`2026-08-21-gated-attention-design.md` for subsystem C.

### 1.1 The flow, taken from the reference implementation

From `llama.cpp`'s `src/models/qwen35.cpp`
(`llama_model_qwen35::graph::build_layer_attn_linear`, line 339) and
`src/models/delta-net-base.cpp`
(`llm_build_delta_net_base::build_delta_net_autoregressive`, line 289 — **the
decode path**; the chunking and fused variants in the same file are prefill
batching and out of scope, see §1.2).

Per layer, on the post-`attn_norm` activation `cur` (1024 wide):

```
1. qkv   = wqkv      . cur          [6144]   (build_qkvz, qwen35.cpp:231)
   z     = wqkv_gate . cur          [2048]
2. beta  = sigmoid(ssm_beta  . cur) [16]     (qwen35.cpp:366)
   alpha = ssm_alpha . cur          [16]
   g     = ssm_a * softplus(alpha + ssm_dt)  [16]   (qwen35.cpp:371-377)
3. conv_input = [conv_state(3 cols) | qkv]   (build_conv_state, delta-net-base.cpp:449)
   conv_out   = depthwise_conv1d_k4(conv_input, ssm_conv1d)   (qwen35.cpp:395)
   conv_out   = silu(conv_out)                                (qwen35.cpp:398)
   conv_state <= last 3 columns of conv_input (shift by one token)
4. split conv_out -> q[128x16], k[128x16], v[128x16]  (views at offsets 0, 2048, 4096)
5. q = l2_norm(q, eps); k = l2_norm(k, eps)           (qwen35.cpp:432-433)
6. per head h (delta-net-base.cpp:289-367, decode recurrence):
     q_h *= 1/sqrt(128)                     (line 319-321)
     S_h  = S_h * exp(g_h)                  (line 339-340, scalar per head)
     sk[j]   = sum_i S_h[i,j] * k_h[i]      (line 343-345)
     d[j]    = (v_h[j] - sk[j]) * beta_h    (line 348-350)
     S_h[i,j] += k_h[i] * d[j]              (line 356-360, outer product)
     o_h[j]  = sum_i S_h[i,j] * q_h[i]      (line 365-366)
7. o_h = rmsnorm(o_h, ssm_norm) * silu(z_h)  per head  (build_norm_gated, qwen35.cpp:247-255)
8. y = ssm_out . o                  [2048 -> 1024]
```

Facts pinned against source, each of which an implementer could plausibly get
wrong from a paper description:

**(a) The recurrence is exactly `s = s*exp(g) + k (x) d^T; o = s^T q`** with
`d = (v - s'^T k) * beta` computed from the **decayed** state `s' = s*exp(g)`.
Index convention, from the ggml dims: `s` is `[S_v, S_v, H_v]` with the first
(contiguous, ne0) index being the **k-dimension** i and the second the
**v-dimension** j; `sk = ggml_sum_rows(s*k)` sums over i, and
`o = ggml_sum_rows(s*q)` likewise. Getting i and j swapped transposes the state
and produces plausible garbage.

**(b) The per-head gate is a scalar.** For this architecture (`GDA`, not KDA)
`g->ne[0] == 1` (`delta-net-base.cpp:322-330`): one `exp(g_h)` per head per
token multiplies all 16,384 state elements of that head. `g <= 0` always:
`ssm_a` stores `-exp(A_log)` (the comment at `qwen35.cpp:376`:
`// -A_log.exp() * softplus`) and softplus is `>= 0`, so **`exp(g) in (0, 1]`
and the decay never amplifies the state**. This is load-bearing for the
fixed-point format of §2.1: the decay factor is representable as an unsigned
fraction with `1.0` included.

**(c) `q` and `k` are L2-normalized, not RMS-normalized**, and the eps is a
**floor on the norm, not an addend under the root**:
`scale = 1/fmaxf(sqrtf(sum), eps)` (`ggml-cpu/ops.cpp:4204`), with
`eps = f_norm_rms_eps`. There is no weight vector. `v` is neither normalized
nor roped. Note the norm makes the output **independent of the input
exponent** — the chain deliberately terminates here, see §2.1.2.

**(d) The q scale `1/sqrt(128)` is NOT a power of two.** `2^-3.5`, unlike C's
`kq_scale = 1/16`. It cannot be folded into an exponent alone. It **is** foldable
into the L2-norm: `q/sqrt(128 * sum(q^2))`, one extra shift of the rsqrt
argument and zero extra rounding sites. §2.1.4 pins this fold as normative.

**(e) The conv is depthwise, kernel 4, no bias, no fused activation**
(`ggml-cpu/ops.cpp:9557-9608`): `y[c] = sum_{t=0..3} x[t][c] * w[t][c]` per
channel, with `x[0..2]` the stored state (three prior tokens, oldest first) and
`x[3]` the current `qkv` output. silu is applied afterwards to the whole 6144
(`qwen35.cpp:398`) — **including the q and k channels**, before their L2 norm.
The stored conv state is the last 3 columns of `conv_input`, i.e. a
shift-by-one-token FIFO (`build_conv_state`, `delta-net-base.cpp:481-500`).

**(f) softplus has a threshold**: `x > 20 ? x : log(1+exp(x))`
(`ggml-impl.h:107-109`). The C reference must implement the threshold, not just
the formula.

**(g) The z gate uses silu; the per-head output norm is RMSNorm** over
`head_v_dim = 128` with the per-layer weight `ssm_norm[128]` shared across all
**48 value heads (24 per card at N=2)**, gated **after** the norm:
`rmsnorm(o) * silu(z)` (`build_norm_gated`, `qwen35.cpp:247-255`).

> **CORRECTED 2026-08-25: this said 16 heads. It is a stale 0.8B number that
> survived the 27B retarget.** At 0.8B the GDN had 16 key heads and 16 value
> heads, so "16" was right, and it stayed right-LOOKING at 27B because 16 is
> still a real head count there -- the KEY heads (`ssm_n_group = 16`). The
> value heads went 16 -> 48 in the retarget (`ssm_dt_rank`), and this line did
> not follow. C §4's retarget table records the change explicitly
> ("GDN key heads / value heads: 16/16 -> 16/48"); B's §1.1(g) did not.
>
> The output norm runs over VALUE heads: `num_v_heads = ssm_dt_rank = 48`,
> `head_v_dim = d_inner / num_v_heads = 6144/48 = 128` (`qwen35.cpp:347-350`,
> `build_norm_gated` call site line 457). Both head types are 128 wide, so
> every shape check passes either way and ONLY the count is wrong -- there is
> no dimensional inconsistency anywhere to catch it. Confirmed against the
> shipped 27B GGUF: `ssm_norm.weight [128]` in all 48 GDN layers, with
> `qwen35.ssm.group_count = 16`, `ssm.time_step_rank = 48`,
> `ssm.inner_size = 6144`.
>
> This is the retarget failure mode to watch for: a number that was correct
> for the old target and remains a plausible value for the new one, because
> the quantity it names still exists at that value under a different name.
> B §4 already carried "24 value heads per card", so B was internally
> inconsistent before it was wrong against source. §2.5's invocation count
> inherited the error; see the correction there. Contrast subsystem C, whose
attention gate is **sigmoid** — two gates, two activations, confirmed in C's
§1.1(b).

**(h) `wqkv`'s output layout is plain `[q | k | v]`, contiguous, head-major
within each segment** (the three views at element offsets 0, 2048, 4096,
`qwen35.cpp:406-424`) — NOT interleaved per head the way C's `wq` interleaves
Q/G. The gate `z` comes from a **separate** matvec (`wqkv_gate`). **This
determines the packer's row ordering for `wqkv`** and the channel ordering of
the conv state and conv weights, which all share it.

**(i) `H_k == H_v == 16` for this model**, so the
`ggml_repeat` broadcast path (`qwen35.cpp:439-443`, taken only when
`num_k_heads != num_v_heads`) is dead. B pins `H_k = H_v` as a generic
constraint; the 27B has `ssm_group_count = 16` but its `dt_rank` has not been
read from the GGUF, so v4.0/v5.0 must re-verify (§2.9).

### 1.2 Decode-only, single-sequence

The reference decode path asserts `n_tokens == 1`
(`delta-net-base.cpp:305`). B computes **one token per invocation**; the
chunked (`build_delta_net_chunking`) and fused variants are prefill batching
and out of scope, exactly as batched prefill is out of scope for C (§1.2
there). The PS teacher-forces prompts one position at a time, as it does today.
`n_seqs = 1` is pinned; there is one conv/recurrent state set, not a batch.

### 1.3 Scope boundary

All weight matvecs belong to **subsystem A**. B consumes activations, exactly
as C does. Per GDN layer the A jobs are:

| A job | K -> M | Mode | Note |
|---|---|---|---|
| `wqkv` slice q | 1024 -> 2048 | BFP | see split note below |
| `wqkv` slice k | 1024 -> 2048 | BFP | |
| `wqkv` slice v | 1024 -> 2048 | BFP | |
| `wqkv_gate` (z) | 1024 -> 2048 | BFP | |
| `ssm_beta` | 1024 -> 16 | BFP | 16 divisible by `ROWS_IF=4`, no masking |
| `ssm_alpha` | 1024 -> 16 | BFP | |
| `ssm_out` | 2048 -> 1024 | BFP | consumes B's `y` output |

**The `wqkv` matvec must be issued as THREE A jobs, not one.** `M = 6144`
exceeds A's `MAXROWS_BFP = 4096`, which A's §7.6 makes a descriptor abort in
BFP mode. This was not visible when A was specced ("GDN projections: defined by
subsystem B"). Three jobs of 2048 (q, k, v segments, in the §1.1(h) order) fit
A unchanged, and are **numerically better** than one job: each segment gets its
own `y_exp` instead of sharing one exponent across q, k and v, whose scales
have no reason to match. The packer emits three packed blobs (or one blob with
three headers); subsystem D sequences three jobs. Raising `MAXROWS_BFP` was
considered and rejected: it costs A output-buffer BRAM and *loses* exponent
granularity.

**In scope for B:** the depthwise conv1d and its DDR-resident state, silu,
the L2 norms, the beta/alpha/g scalar path (sigmoid, softplus, exp), the
DDR-resident recurrent state and its read-modify-write sweep, the per-head
RMSNorm-and-silu(z) output gate, and B's own MAC lanes.

**Out of scope, owner = subsystem D (the transformer sequencer):** steering A's
outputs into the correct activation regions for the 7 jobs above, sequencing
the A -> A -> ... -> B -> A order per layer, `attn_norm` / `attn_post_norm`,
the residual adds, and interleaving B-layers with C-layers per the §1 layer
map. Same seam as C §1.3.

**Out of scope, owner = the packer:** quantizing `ssm_conv1d` to the §2.1.1
int16 format, quantizing `ssm_dt`/`ssm_a`/`ssm_norm` to int16+exponent, and the
`wqkv` three-way split.

### 1.4 Dimensions and interface

All model dimensions verified against `qwen35.cpp:56-99` (tensor creation) and
the GGUF-derived table in A §3 ("16 K heads, 16 V heads, dim 128, conv kernel
4"):

| | Qwen3.5-0.8B |
|---|---|
| GDN layers | 18 of 24, indices `(i+1) % 4 != 0` |
| `S` = head_k_dim = head_v_dim = `ssm_d_state` | 128 |
| `H` = num_k_heads = num_v_heads (`ssm_n_group` = `ssm_dt_rank`) | 16 |
| key_dim = value_dim = `S*H` | 2048 |
| conv_dim = 2*key_dim + value_dim | 6144 |
| conv kernel (`ssm_d_conv`) | 4 |
| `wqkv` | 1024 -> 6144 (three 2048 slices, §1.3) |
| `wqkv_gate` | 1024 -> 2048 |
| `ssm_beta`, `ssm_alpha` | 1024 -> 16 each |
| `ssm_out` | 2048 -> 1024 |
| `ssm_dt` (bias), `ssm_a` | [16] each, per layer |
| `ssm_norm` | [128], per layer, shared across heads |
| recurrent state per layer | `S*S*H` = **262,144 elements** |
| conv state per layer | `(4-1)*6144` = **18,432 elements** |

State sizes cross-checked against `llama-hparams.cpp:183-205` (`n_embd_r` =
`(d_conv-1)*(d_inner + 2*n_group*d_state)` = 3*6144; `n_embd_s` =
`d_state*d_inner` = 128*2048).

**Parameter count, resolving A §3's open estimate.** Per GDN layer:
`wqkv` 6,291,456 + `wqkv_gate` 2,097,152 + `ssm_out` 2,097,152 + beta/alpha
32,768 + conv 24,576 + dt/a/norm 160 = **10,543,264**. Across 18 layers:
**189.8M** — inside A's "170-240M" bracket. Model total: embed 254.3M + FFN
264.2M + attention 44.0M + GDN 189.8M + norms ~0.1M ≈ **752M params ≈ 423 MB
at 4.5 bpw**, not the 450 MB placeholder. Per-token throughput estimates
improve ~6%; `docs/fpga-hardware-recon.md` should adopt the number.

```vhdl
entity gdn_layer is
  generic(
    S         : positive := 128;   -- head dim (k and v; S_k = S_v asserted by ref)
    H         : positive := 16;    -- heads (H_k = H_v pinned for v2.2, see 1.1(i))
    CONV_K    : positive := 4;
    LANES     : positive := 8;     -- state elements processed per cycle
                                   -- (the scaling knob; 8 on AXU3EG, see 2.8)
    MAXLAYERS : positive := 18
  );
  port(
    clk, rst : in std_logic;
    start    : in std_logic;
    layer    : in integer;   -- GDN ORDINAL 0..MAXLAYERS-1, not the model layer
                             -- index; subsystem D owns the model-index mapping
    seq_rst  : in std_logic; -- per-SEQUENCE reset: token counter, conv ring
                             -- pointer, conv slot-exponent registers (2.1.2).
                             -- Driven by D at sequence start, NOT per token.
    -- DDR region bases, from the PS, all 4 KB aligned (2.2)
    s_base   : in std_logic_vector(31 downto 0);  -- state mantissas
    se_base  : in std_logic_vector(31 downto 0);  -- state exponent headers
    cv_base  : in std_logic_vector(31 downto 0);  -- conv state slots
    cw_base  : in std_logic_vector(31 downto 0);  -- conv weights (packed)
    cw_exp   : in integer;                        -- per-layer conv weight exponent
                                                  -- (descriptor, from the packer)
    -- inputs from subsystem A's activation memories, SIX independent exponents
    -- (three wqkv slices + z + beta + alpha; see 1.3 and C's C2 lesson)
    qkv_rbaddr : out ...; qkv_rdata : in ...;     -- block-wide port, 1.5
    qkvq_exp, qkvk_exp, qkvv_exp : in integer;
    z_rbaddr   : out ...; z_rdata   : in ...; z_exp  : in integer;
    b_rbaddr   : out ...; b_rdata   : in ...; b_exp  : in integer;
    al_rbaddr  : out ...; al_rdata  : in ...; al_exp : in integer;
    -- per-layer constants (D-steered small memories, loaded at boot)
    sn_raddr : out std_logic_vector(6 downto 0);        -- ssm_norm, 128 entries
    sn_rdata : in  std_logic_vector(15 downto 0);
    sn_exp   : in  integer;    -- REQUIRED by the 2.1.2 rmsnorm chain (C CR3-2)
    dt_rdata, a_rdata : in ...; dt_exp, a_exp : in integer;  -- [16] each
    -- result to A's activation memory for ssm_out
    y_we   : out std_logic;
    y_addr : out std_logic_vector(10 downto 0);   -- 2048 entries
    y_data : out std_logic_vector(15 downto 0);
    y_exp  : out integer;
    done   : out std_logic;   -- one-cycle pulse, gated on BRESP (2.7)
    err    : out std_logic;
    -- AXI4: FOUR masters, each BIDIRECTIONAL (2.5 as corrected by 3.4).
    -- NOT two read plus two write: splitting a port by direction leaves
    -- its other direction idle, which measured WORSE than paying the
    -- read/write turnaround.  See 3.4.
    ...
  );
end entity;
```

There is deliberately **no `cur_pos` port**: B derives everything positional
(conv ring slot, first-token state masking) from an internal token counter
reset by `seq_rst`. Supplying a position and computing `mod 3` from it was
rejected — the counter is 2 bits of state and cannot disagree with itself.
`ssm_a <= 0` is required (§1.1(b)) and **checked at every `start`** (A's M-F
lesson: re-check resident invariants, don't trust load-time).

### 1.5 Reuse

| Reused | From | Caveat |
|---|---|---|
| RMSNorm for the output gate | `rmsnorm.vhd`, N=128 | ports are N*16 parallel (2048 b); needs a marshalling buffer; `o_exp = xe + we + Q - shift_total` is data-dependent per invocation (`rmsnorm.vhd:336`) |
| `rsqrt_q` + RSQRT_ROM for the L2 norms | `fixed_pkg.vhd:14,45-48` | rmsnorm's kernel; L2 norm differs from RMSNorm (no /N, no weight, eps is a floor §1.1(c)) so a small new wrapper unit is needed, not `rmsnorm` itself |
| `sigmoid_q` + SIG_ROM for beta and silu | `fixed_pkg.vhd:17,185-187` | Q12 in/out as shipped; §2.1 pins beta and the decay factor at **Q15 out**, so the table must be regenerated (`tools/gen_fixed_luts_pkg.py`, cited by `fixed_pkg.vhd:9-11`) — a §3 deliverable |
| `exp_q` + EXP_ROM for `exp(g)` | `fixed_pkg.vhd:16,123-125` | same Q15-out regeneration; domain [-16,0] with underflow-to-zero suits `g <= 0` exactly (§1.1(b)) |
| BFP quantize (amax -> msb_pos -> shift) | `bfp_pack.vhd` | the conv segment requantizer and the state write-back quantizer (§2.1.3/§2.1.4) |
| `divider_rs` | `divider_rs.vhd` | only if §3's softplus/log needs a true divide; the VHDL `/` stays banned |
| Block-wide activation read | A's `act_mem_striped` concept | B's `qkv_rdata` port is the same BLOCK*16 shape |

**Why Q15 for the decay factor is worth a table regeneration:** `exp(g)`
multiplies the *entire persistent state* once per token. At Q12 the factor's
quantization step is `2^-12`, a relative error up to ~1.2e-4 **compounding
multiplicatively per token** on state that is never rewritten from scratch. Q15
cuts it 8x for the cost of regenerating a 257-entry ROM. beta gets the same
treatment for uniformity (it scales the correction term, where error is
self-limiting — Q15 is cheap insurance, not a requirement; §3 may argue it back
down with an error analysis).

### 1.6 The conv state is a ring buffer, and its ggml equivalence

The reference materializes `conv_input = [state | new]` and copies the last 3
columns back (`delta-net-base.cpp:481-500`) — a shift. B instead keeps **three
DDR slots per layer and a 2-bit ring pointer** (slot = token counter mod 3,
maintained incrementally): per token it writes ONE slot (the new qkv vector,
12,288 B) instead of rewriting all three (36,864 B). The equivalence with the
reference shift is exact **under append-only, single-sequence decode** (§1.2);
any future rollback/branching feature breaks it silently and must revisit —
the same caveat class as C's write-time `v_ref` min-fold.

**Zero initialization is by masking, not by zeroing DDR.** The reference
zero-fills both states at sequence start. B masks instead: with internal token
counter `tk`, conv taps referring to tokens `< 0` contribute zero (`tk < 3`
cases), and at `tk = 0` the state read is skipped entirely and `smant = 0` is
substituted. **The masked state has no exponent**, and §2.1.4's `e_u` must
exclude it from its minimum rather than substitute a constant. The PS never
initializes B's DDR regions.

> **CORRECTED 2026-08-25. `SE_INIT = 0` was a defect, and a severe one.**
> This paragraph previously said `se[j] = SE_INIT = 0` is substituted, pinned
> "because it enters `e_u` below". It does enter `e_u`, and 0 is the worst
> value it can take: see §2.1.4.



## 2. The recurrent state

The dominant architectural fact of subsystem B: **4.72M state elements
(262,144 x 18 layers) are read AND written every token, independent of context
length**, plus 331,776 conv-state elements. At int16 that is ~19 MB of traffic
per token that exists at context 1 and never grows. On the AXU3EG this must
stream from PS DDR4 (the whole PL has 0.95 MB of BRAM; one layer's state alone
is 512 KB). On the FK33 it can be URAM-resident (§2.9). Everything in §2.1-§2.6
is written for the streaming case; §2.9 states what residency changes.

### 2.1 Numeric contract (NORMATIVE)

**This section is the single source of truth for every exponent, alignment and
rounding decision in subsystem B.** Sections 2.2 onward reference it and must
not restate it. The convention throughout is `value = mant * 2^-exp`.

#### 2.1.1 Storage formats

**Recurrent state, per (layer, head):** the head state `S_h[i,j]`, `i` = k-dim,
`j` = v-dim (§1.1(a)), is stored **column-major with one exponent per
column j**:

| | |
|---|---|
| Mantissas | int16, 128 per column, column j contiguous (`S_h[0..127, j]`) |
| Exponents | one int8 `se[j]` per column, 128 per head, in a separate header region |
| Head record | 128 B header + 32,768 B mantissas |
| Cost | 16.06 bits/element |

**Why per-column:** both dot products that read the state — `sk[j]` and
`o[j]` — run over `i` **within a fixed j**, so a per-column exponent means
**neither dot product ever needs intra-sum alignment**. The delta-rule update
`k[i]*d[j]` also touches exactly one column's grid per element. Columns are the
natural magnitude groups (`column j` tracks output channel j, scaled by that
channel's `v` history), so this is also where the dynamic range lives. A
single per-head exponent was rejected (one hot column crushes 127 others — the
same argument as C's per-32 V exponents), and per-32 blocks within a column
were rejected as pure cost: they would force intra-dot alignment for no
precision gain over per-column.

**int16, not int8.** Unlike C's KV cache, where each record is written once and
read many times, the state is **requantized every token**: quantization error
feeds back through the recurrence. int8 would halve the traffic and was
rejected for v2.2 on that ground; §3's error analysis may revisit with data.

**Conv state, per (layer, slot):** the slot is **A's BFP output copied
verbatim** — int16 mantissas in the §1.1(h) channel order, 6144 per slot, with
the three per-segment exponents (`qkvq_exp`, `qkvk_exp`, `qkvv_exp`) captured
**on-chip** at write time (18 layers x 3 slots x 3 segments = 162 int8
registers, reset by `seq_rst`). Copying verbatim adds **zero** quantization
error and zero rounding sites at this seam.

**Conv weights, per layer:** int16 mantissas, one per-layer exponent `cw_exp`
in the descriptor, packed channel-major, 4 taps x int16 = 8 B per channel, in
the §1.1(h) channel order (packer deliverable). Per-channel scales were
considered and rejected for v2.2: the tensor is 24,576 values with one shared
exponent already giving 15 significant bits.

**Per-layer constants:** `ssm_dt`, `ssm_a` (16 x int16 + one exponent each),
`ssm_norm` (128 x int16 + `sn_exp`). Packer-quantized, boot-loaded, read via
the §1.4 ports. `ssm_a` mantissas must be `<= 0` (§1.1(b), checked at `start`).

**Pinned working formats** (the value grids at internal seams; production
rules in §2.1.3-§2.1.4):

| Signal | Format | Grid |
|---|---|---|
| `k_n[i]` (L2-normed k) | int16 | exp **15** (Q15; unit norm ⇒ `abs <= 1`) |
| `q_s[i]` (L2-normed q, `1/sqrt(128)` folded) | int16, `abs <= 23171` | exp **18** |
| `v[j]` | int16 | exp `e_v` = v-segment exponent, §2.1.3 |
| `beta_h` | uint16, `0..65535` | exp **16** (Q16; sigmoid < 1 strictly) |
| `eg_h = exp(g_h)` | uint16, `0..32768` | exp **15** (Q15; `eg = 1.0` at `g = 0` is exact: 32768 fits u16) |
| scalar path (`alpha`, `dt`, `softplus`, `g`) | s32 | exp **12** (Q12, `exp_q`'s native domain) |

`q_s`'s bound: after the fold `norm2(q_s) = 1/sqrt(128)`, so
`abs(q_s[i]) <= 2^18/sqrt(128) = 23170.5`, hence 23171. The exponent 18 (not
15) exists to keep those ~14.5 significant bits; at Q15 the top 3.5 bits would
be structurally zero.

#### 2.1.2 Exponent chains

All data-dependent, none derivable from a single interface port. The six A-job
exponents (`qkvq_exp, qkvk_exp, qkvv_exp, z_exp, b_exp, al_exp`) are
per-invocation values of A's BFP output (`y_exp = w_exp + x_exp - out_shift -
ns` per A §7.4, with `ns` data-dependent) — **six independent values**, the
same lesson as C's C2.

```
conv tap t of segment seg :  e_t = the CAPTURED slot exponent for (layer, slot(t), seg)
                             (t = 3, current token: the live A y_exp for that segment)
conv accumulator          :  e_acc(seg) = min over valid taps t of e_t  +  cw_exp
conv segment requant      :  e_seg = e_acc(seg) - sh_seg          -- sh_seg data-dependent, 2.1.3
silu                      :  exponent PRESERVED (y = round_shift(x * sigma_q15, 15), 2.1.3)
L2 norm                   :  chain TERMINATED; outputs pinned at exp 15 (k), 18 (q) -- 2.1.1
v                         :  e_v = e_seg(v-segment)               -- silu preserves it
state column              :  se[j], from the header; updated to se_new[j] per 2.1.4
rmsnorm (output gate)     :  o_exp = xe + we + Q - shift_total    -- rmsnorm.vhd:336,
                             DATA-DEPENDENT per head; xe = e_head[h] (2.1.4),
                             we = sn_exp. NEVER an interface constant (C CR3-2).
y (to ssm_out)            :  single y_exp across all 24 value heads/card; owned by 3
```

The L2-norm termination is exact, not approximate: `x/norm2(x)` computed on
mantissas equals the same computed on values — the exponent cancels
algebraically. The **only** exponent-dependent part of the L2 norm is the eps
clamp (§2.1.3), which compares a real-valued threshold.

**Captured, not re-read:** the conv slot exponents live in on-chip registers
(§2.1.1) written when the slot is written. Reading A's `y_exp` port at *use*
time would read the exponent of whatever job A ran last — a per-token,
per-segment power-of-two error, the C1/CR3-2 disease on a new seam.

#### 2.1.3 Conv, silu, L2 norm and the scalar path

**Conv (per channel c of segment seg).** Taps: `x_t` = slot mantissa (int16,
exp `e_t`), `w_t` = conv weight mantissa (int16, exp `cw_exp`). Invalid taps
(token index < 0, §1.6) are **excluded from both the products and the
`e_ref` minimum**:

```
e_ref     = min over valid t of e_t
p_t       = x_t * w_t                                  -- s32, |p_t| <= 2^30
acc[c]    = sum over valid t of ( p_t >> (e_t - e_ref) )   -- floor; s34
```

Right-shift-only by construction (`e_t >= e_ref`). Bound: `4 * 2^30 = 2^32`,
s34 declared (1 bit margin). Grid: `e_acc = e_ref + cw_exp`.

**Segment requantizer** (per segment, over its 2048 `acc` values, buffered
s34): `bfp_pack` semantics exactly — `amax` held unsigned over the segment,
`p = msb_pos(amax)` with **`msb_pos(0) = 0`**, `sh_seg = max(0, p - 14)`,
`sm[c] = sat16(round_shift(acc[c], sh_seg))`, `e_seg = e_acc - sh_seg`.

**silu** (every conv channel, and the z gate at the output stage):

```
x_q12  = Q12(sm, e_seg)                    -- site 3 below, both branches
sm'    = round_shift( sm * sigma_q15(x_q12), 15 )     -- exponent preserved
```

`sigma_q15` is the Q15-out sigmoid of §1.5; its internal interpolation is
pinned by §3. `abs(silu(x)) <= abs(x)` since `sigma <= 1`, so `sm'` cannot
exceed int16 on the same grid — no re-scan, no saturation.

**The Q12 conversion rule (used by every nonlinearity argument — silu's sigma,
beta's sigmoid, softplus, exp):**

```
sh = e - 12
x_q12 : s32 = (sh >= 0) ? round_shift(x, sh)      -- round half toward +infinity
                        : sat32( x << (-sh) )     -- exact, saturating
```

Both branches stated because `e` is data-dependent and unbounded in both
directions (C's MJ5-1). All shift counts in C are clamped to [0, 63] and all
intermediates are >= 64 bits (A's M-C).

**L2 norm** (per head, over 128 post-silu mantissas `xm`; input exponent `e`):

```
ssq  = sum of xm[i]^2          -- <= 128 * 2^30 = 2^37, u38
k_n[i] = quantize15( xm[i] / sqrt(ssq) )            -- k path, exp 15
q_s[i] = quantize18( xm[i] / sqrt(128 * ssq) )      -- q path, exp 18; the
                                                    -- 1/sqrt(128) fold of 1.1(d):
                                                    -- one shift of the rsqrt
                                                    -- argument, no multiply
```

The fixed-point recipe (rsqrt_q reuse, iteration count, rounding of the final
multiply, `sat16`) is **pinned in §3**; §2.1 pins the output formats and this
much: **if `ssq = 0`, the output is all zeros.** The reference would divide by
`eps = f_norm_rms_eps` and emit amplified numerical dust
(`scale = 1/max(norm, eps)`, §1.1(c)); for int16 mantissas the region
`0 < norm_real < 1e-6` is reachable only at extreme exponents, and the C
reference is **defined** with the zero rule, so RTL and reference cannot
diverge. The accepted (and documented) divergence is against the float
reference in that degenerate region only.

**This is a DELIBERATE, KNOWN DIVERGENCE from the reference implementation, and
it qualifies the bit-exactness claim.** `ggml_l2_norm` computes
`1/max(sqrt(ssq), eps)`, so at `ssq = 0` it emits `xm * (1/eps)` -- amplified
dust from an all-zero input. B emits zeros instead, which is the numerically
sane answer but is **not bit-identical**.

Consequences that §3 must carry, rather than discovering at validation time:

- **The C reference implements B's behaviour, not ggml's.** Validation compares
  RTL against `ref/`, and `ref/` against ggml **excluding this case**.
- **The case is reachable, not theoretical.** At position 0 every conv tap but
  one is masked (§1.6), so a single zero projection output produces `ssq = 0`
  for a whole head.
- §3's test plan must include an `ssq = 0` vector asserting zeros, and must
  document the ggml mismatch rather than treating it as a failure.

**Scalar path** (per head; 16 values each): `alpha` and `dt` are converted to
Q12 (rule above, exponents `al_exp`, `dt_exp`) and added in s32.
`sp = softplus_q12(.)` (threshold per §1.1(f); internals §3). Then

```
g_q12 = min( 0, round_shift_bidir( sp * a_mant, a_exp ) )   -- a <= 0 so g <= 0
        clamped below at -16*2^12 (exp_q's domain; deeper values underflow to
        eg = 0, which is the mathematically correct limit)
eg    = exp_q15( g_q12 )        -- uint16, 0..32768
beta  = sigmoid_q16( Q12(b_mant, b_exp) )   -- uint16 Q16; internals per 3
```

`round_shift_bidir` = the two-branch rule above with `a_exp` in place of
`e - 12`. The `min(0, .)` guard is defensive: `g > 0` is impossible per
§1.1(b) but a rounding artifact must not amplify the state.

#### 2.1.4 The recurrence, per head h, per column j

This is the core contract. One pass per column, in stream order; the whole
sweep is column-local (nothing in column j depends on any other column of the
same token — the reason the state can stream, §2.4).

**At `tk = 0`** (first token of a sequence): the state read is skipped and
`smant[i,j] = 0` is substituted. **The state term is then identically zero, so
it takes no part in stage 4's grid selection**: `e_u = e_kd`, and `u[i] = kd[i]`
with no shift of the state term at all. There is no `SE_INIT`.

> **CORRECTED 2026-08-25, measured.** Rev 1 substituted `se[j] = SE_INIT = 0`
> and let it enter `e_u = min(se[j] + 2, e_kd)` unchanged, reasoning that
> "zero mantissas make the *values* exact regardless". They do. The
> **exponent** does not: `se[j] + 2 = 2` while `e_kd` is typically ~28-32, so
> the min pins the whole first write-back to grid 2 and the update is floored
> right by ~30 bits. `|kd| <= 2^31`, so `kd >> 30` leaves **one or two bits**
> of the first token's entire state.
>
> The rule that makes min-referencing safe is that both operands' exponents
> describe real values. A masked zero's exponent describes nothing, and
> `SE_INIT` is a constant unrelated to the update's scale, so including it is
> not a conservative choice but an arbitrary one. Pinning it (C's MJ5-2
> lesson) was right; pinning it to a value that participates in an arithmetic
> minimum was not.
>
> **This spec already states the rule correctly one section earlier.** §2.1.3's
> conv excludes invalid taps "from both the products **and the `e_ref`
> minimum**" -- the identical situation, masked by the identical `tk` counter,
> handled the identical way. So this is not a new rule being introduced; it is
> §2.1.3's rule that §2.1.4 failed to apply. **Any future masked operand must
> leave the grid selection as well as the sum**, and the two sites are now the
> precedent for it.
>
> | worst-head relative output error | as written | corrected |
> |---|---|---|
> | t = 128, real per-head `exp(g)` | **4.7e-1** | 3.9e-4 |
> | t = 256, `exp(g)` pinned to 1.0 | **4.0e-1** | 4.7e-4 |
> | t = 2048, real `exp(g)` | 1.0e-3 | 5.0e-4 |
> | t = 4096, `exp(g)` pinned to 1.0 | 6.1e-4 | 6.0e-4 |
>
> **The first token is corrupted by ~1000x and it does not wash out quickly.**
> Recovery is dilution, not correction: the bad state is a fixed addend that
> becomes a shrinking fraction of an accumulating sum, so the error falls
> roughly as 1/t and only reaches the 5e-4 equilibrium floor at t ~ 1900.
> **Every sequence shorter than that is degraded end to end**, which is most
> of them. It is not a contraction effect and pinning the gate at `exp(g) = 1`
> (no contraction at all) does not avoid it.
>
> `SE_INIT >= +100` measures digit-identical to the corrected form, because it
> forces the same `e_u = e_kd`. It is **not** the preferred fix: it leaves a
> magic constant whose correctness depends on staying above a data-dependent
> `e_kd`, and it makes `se[j] + 2 - e_u` a large positive shift of a zero
> rather than no shift at all. State the tk = 0 case structurally instead.
>
> Note the corrected form must **not** be written as a negative shift. With
> `e_u = e_kd > se[j] + 2` the expression `w18[i] >> (se[j] + 2 - e_u)` is a
> left shift, which is why the tk = 0 case drops the state term rather than
> shifting it.
>
> Tool, procedure and the full sensitivity sweep:
> `docs/debugging/2026-08-25_gdn-recurrence-error-bound.md`, `ref/gdn_err.c`.

**Stage 1 — decay** (site 6):

```
w[i]   = smant[i,j] * eg          -- s16 x u16(<=2^15): |w| <= 2^30, s32
w18[i] = round_shift(w[i], 13)    -- |w18| <= 2^17, s19; grid e_w = se[j] + 2
```

The prescale to 19 bits exists so every downstream product fits ONE DSP48E2
(27x18); it keeps 2 more bits than the stored state, so the decay costs at
most 1/4 ulp of the eventual write-back grid. Note `|w18|` can reach exactly
`2^17` (`smant = -32768`, `eg = 32768`), which is why w18 is **s19, not s18** —
the off-by-one-bit class A's MA-1 documents.

**Stage 2 — sk dot** (no alignment needed — one exponent per column, §2.1.1):

```
sk_acc = sum over i of w18[i] * k_n[i]   -- 128 * 2^17 * 2^15 = 2^39, s41
                                          -- grid: se[j] + 2 + 15 = se[j] + 17
skm, ske = normalize(sk_acc)              -- site 7: sh_sk = max(0, msb_pos(|sk_acc|) - 14),
                                          -- skm = round_shift(sk_acc, sh_sk) (s16),
                                          -- ske = se[j] + 17 - sh_sk
```

**Stage 3 — delta** (sites 8, 9):

```
e_d   = min(e_v, ske)                          -- coarser grid = larger values =
                                               -- RIGHT-shift-only alignment
diff  = (v[j] >> (e_v - e_d)) - (skm >> (ske - e_d))   -- floor shifts; s18
d_m   = round_shift( diff * beta, 16 )         -- s18 x u16 Q16; |d_m| <= 2^16, s18
                                               -- grid e_d unchanged (Q16 folded)
```

The operand on the `e_d` grid shifts by zero; the other shifts right by the
spread, floor, shift count clamped at 63. Bits lost are below the larger
operand's ulp. Cancellation (`v ≈ sk`, the converged-state case) is exact —
subtraction after alignment loses nothing.

**Stage 4 — update and write-back quantizer** (sites 10, 11):

```
kd[i] = k_n[i] * d_m               -- s16 x s18, one DSP; |kd| <= 2^31, s33
                                   -- grid e_kd = 15 + e_d
e_u   = ( tk = 0 ) ? e_kd : min( se[j] + 2, e_kd )   -- right-shift-only again;
                                   -- at tk=0 the state is a MASKED ZERO with no
                                   -- exponent and must not enter the min
u[i]  = (tk = 0) ? kd[i]
                 : (w18[i] >> (se[j]+2 - e_u)) + (kd[i] >> (e_kd - e_u))  -- floor; s34
        -- |u| <= 2^31 + 2^17 < 2^32
amax  = max over i of |u[i]|, held unsigned
sh    = max(0, msb_pos(amax) - 14)          -- msb_pos(0) = 0
smant_new[i,j] = sat16( round_shift(u[i], sh) )   -- bfp_pack semantics:
                                                  -- bias only when sh > 0, THEN sat16
se_new[j]      = e_u - sh          -- int8 RANGE-CHECKED; out of range -> err, 2.1.6
```

Because both alignments reference a minimum, **no alignment here can overflow
and none needs saturation** — the only saturation is `sat16` in the final
quantize, needed for the biased-path corner exactly as A §7.4's third
divergence row documents. When the update dwarfs the state (`e_kd < se[j]+2`),
the state's low bits fall below `e_u`'s grid and are floored away; when the
state dwarfs the update, the update contributes its top bits only. Both are
the correct behaviours of a min-referenced grid.

**Stage 5 — output dot** (uses the REQUANTIZED mantissas, so the emitted
output is bit-consistent with the stored state, exactly as the reference's `o`
uses the updated `s`):

```
o_acc[j] = sum over i of smant_new[i,j] * q_s[i]   -- 128 * 2^15 * 23171 < 2^37, s38
                                                    -- grid e_o[j] = se_new[j] + 18
```

**Stage 6 — head emit** (site 12): `e_o[j]` varies per column, so the head
vector is folded to a common grid before the output gate:

```
e_h      = min over j of e_o[j]
o_al[j]  = o_acc[j] >> (e_o[j] - e_h)              -- floor, right-shift-only
o_head[j], e_head = bfp requantize over the 128 o_al  -- amax/msb/round/sat16,
                                                       -- e_head = e_h - sh_h
```

`o_head/e_head` feeds `rmsnorm` (`x_exp = e_head`, `w_exp = sn_exp`); the
gated product with `silu(z_h)` and the final renormalization of all **24 value
heads per card** to the single `y_exp` are §3's sites (13), constrained but
not fixed here —
the same split C made for its sites 5-6.

#### 2.1.5 Rounding sites

Scope: new arithmetic introduced by B. Rounding inside reused bit-pinned units
(`rmsnorm`'s internals, `bfp_pack`) is fixed by those units. "half+inf" =
round half toward +infinity, `fixed_pkg.scale_mul`'s convention throughout the
codebase.

| # | Site | Mode |
|---|---|---|
| 1 | conv tap alignment `>> (e_t - e_ref)` | floor, arithmetic right shift |
| 2 | conv segment requantize | bfp_pack semantics: half+inf, bias only `sh>0`, `sat16` |
| 3 | Q12 argument conversion (silu/sigmoid/softplus/exp args) | `sh>=0`: half+inf; `sh<0`: `sat32` left, exact |
| 4 | silu mantissa multiply `round_shift(sm * sigma_q15, 15)` | half+inf (sigma internals §3) |
| 5 | L2-norm output quantize (k Q15, q Q18 with fold) | **§3** pins the rsqrt recipe; `sat16` + half+inf required |
| 6 | decay prescale `round_shift(smant * eg, 13)` | half+inf |
| 7 | sk normalize `round_shift(sk_acc, sh_sk)` | half+inf |
| 8 | v/sk alignment to `e_d = min(e_v, ske)` | floor, right-shift-only |
| 9 | beta multiply `round_shift(diff * beta, 16)` | half+inf |
| 10 | update alignment to `e_u = min(se[j]+2, e_kd)` | floor, right-shift-only |
| 11 | state write-back quantize | bfp_pack semantics, `sat16`; `se_new` range-checked |
| 12 | head-emit alignment + requantize | floor for alignment; bfp semantics for requantize |
| 13 | gated-norm product and 16-head renorm to one `y_exp` | **§3** |
| 14 | softplus / sigmoid / exp internals; `g` clamp | **§3** (formats fixed in §2.1.3) |

Sites 1-2, 3-4, 6-12 are fixed here. All C-reference intermediates are
`int64_t` with shift counts clamped to [0, 63] (A §9's width discipline).

#### 2.1.6 Range checks and `err`

`err` is sticky, cleared by `rst` or a successful `start` (A §7.6 semantics).
Descriptor-class checks abort at `start` with `done` still pulsing:

| Condition | Class |
|---|---|
| `layer >= MAXLAYERS` | descriptor, abort at `start` |
| resident `ssm_a` mantissa `> 0` | descriptor, **re-checked at every `start`** (A M-F) |
| any captured exponent outside int8 when a slot header is written | data: raise `err`, continue; results undefined, PS discards |
| `se_new[j]` outside int8 | data: raise `err`, continue |
| A-side exponent ports outside int8 range at capture | data: raise `err`, continue |

There is no `cur_pos`/`ctx_len` check because B takes no position inputs
(§1.4); the token counter cannot exceed anything.

### 2.2 DDR layout

Four regions, all bases 4 KB aligned, all sized so no burst ever crosses a
4 KB boundary mid-record — unlike C's 272 B records, every record here packs
pages exactly:

```
state mantissas : s_base  + ((layer*H + head) * 32768) ; column j at +j*256
                  32 KB/head = 8 pages exactly; a 256 B column = 16 beats;
                  16 columns = exactly one 4 KB page
state headers   : se_base + ((layer*H + head) * 128)   ; 128 B = 8 beats
conv slots      : cv_base + ((layer*3 + slot) * 12288) ; 12,288 B = 3 pages
conv weights    : cw_base + (layer * 49152)            ; 12 pages; channel-major,
                  4 x int16 per channel (packer 1.3)
```

Footprint: state 9.44 MB + headers 36.9 KB + conv state 663.6 KB + conv
weights 884.7 KB ≈ **11.0 MB** — trivial against 4 GB, and comparable to C's
13.4 MB KV at 2048 context.

The header for a head is read (8 beats) before its mantissa stream begins;
`se[j]` is consumed in column order, matching the stream.

### 2.3 Sizing and traffic

Per token, all context-independent:

| Stream | Read | Written |
|---|---|---|
| State mantissas, 18 x 16 x 32,768 B | 9.44 MB | 9.44 MB |
| State headers | 36.9 KB | 36.9 KB |
| Conv slots (3 read, 1 written, per layer) | 663.6 KB | 221.2 KB |
| Conv weights | 884.7 KB | - |
| **Total** | **11.0 MB** | **9.70 MB** |

**20.7 MB/token total, ~4.9% of the 423 MB weight traffic.** Compare C: 13.4 MB
*read* per token at 2048 context, growing linearly with context. B's traffic
exceeds C's at short context, is flat forever, and its write half is as large
as its read half — the state is the only large object in the design that is
rewritten every token.

### 2.4 The column pipeline

The §2.1.4 recurrence is **column-local**: `d[j]` needs only `sk[j]`, which
completes when column j has streamed in. So the state is processed as a
single-pass read-modify-write pipeline with NO full-head buffering:

```
for head h in 0..H-1:                         -- k_n, q_s, v, eg, beta ready (2.1.3)
  read header se[0..127]
  for column j in 0..127:                     -- one 256 B burst, 16 beats
    stream in smant[*,j]  ->  stage 1 decay, stage 2 sk-MAC   (LANES elems/cycle)
    at column end: d[j] per stage 3           -- a few scalar cycles, pipelined
    re-walk the column from a 128-element ring: stage 4 update + quantize
    stream out smant_new[*,j] + fold se_new[j] into the header write
    stage 5 output-MAC on the outgoing elements
  emit o_head per stage 6 (overlapped with head h+1's read)
write back the header
```

The only state buffer is a **128-element working ring per lane group** (the
column being updated) plus the per-head input vectors — a few KB of
registers/LUTRAM, not BRAM-scale. This is what makes DDR residency viable at
all: nothing requires the 512 KB layer state on chip.

**Intra-job read-write ordering is inherent**: column j's write is issued only
after its read data arrived (a data dependency, not an AXI ordering
assumption). The **inter-token** hazard — token T+1's read of a column against
token T's write through a different master — is real and is closed the same
way C closed it: **`done` does not assert until every outstanding write has
BRESP'd** (§2.7). There is no analog of C's bypass because B never re-reads
within a job what it wrote in that job.

**Order of phases per layer invocation:** conv (needs the 6 A jobs done) →
silu → L2 norms + scalar path → per-head state sweeps → per-head
rmsnorm + z-gate → y emit. Phase overlap (e.g. head h's rmsnorm under head
h+1's sweep) is §3 scheduling; the contract does not depend on it.

### 2.5 Compute and bandwidth

Multiplies per layer per token, from §2.1.4: 4 per state element (decay, sk,
kd, output) x 262,144 = **1.049M**, plus conv 24,576, plus ~20K of L2/silu/
gate/misc — ~1.09M/layer, **~19.7M/token** over 18 layers. Compare A's ~752M
weight MACs: B is ~2.6% of the multiply work but ~4.9% of the traffic.

**Sweep cycle count** at `LANES` elements/cycle (each element passes the 4
pipelined stages in parallel DSP groups):

```
cycles/layer = S*S*H / LANES = 262,144 / LANES
LANES = 8 :  32,768 cycles/layer ; 589,824/token = 2.95 ms @ 200 MHz
```

**Feed and drain requirement, stated honestly.** LANES = 8 consumes 16 B/cycle
of state read AND produces 16 B/cycle of write — 3.2 GB/s each way at 200 MHz,
which is 100% of one 128-bit AXI master in each direction. Against A's
measured-premise range of 47-70% port efficiency, **one master per direction
cannot feed the pipeline**. B therefore uses **four masters**, striped by head
parity; each then needs >= 50% sustained:

> **SUPERSEDED 2026-08-25 by §3.4.** This paragraph said "two read masters and
> two write masters". Measurement says the four masters must each be
> BIDIRECTIONAL, not split by direction: a port dedicated to one direction
> leaves the other idle, and that costs more than the read/write turnaround it
> avoids (47.1 GB/s against 38.4). The count of four is unchanged. The
> per-master efficiency table below is also 0.8B-era and is superseded by
> §3.1.

| Port efficiency (per master) | State sweep, 18 layers |
|---|---|
| >= 50% | 2.95 ms (compute-bound) |
| 47% | 3.14 ms (feed-bound) |

Conv phase adds ~0.1 ms of traffic (1.77 MB at the same efficiency) and
~3-4K compute cycles/layer. **The efficiency premise must be re-measured for
this pattern** — four concurrent masters, two of them writing, none of which
A's single-stream measurement covers; C recorded the same caveat for its
two-read-plus-write pattern (C §2.5).

**Latency accounting is incomplete, deliberately.** The 2.95-3.14 ms covers
the state sweep and conv only. **Twenty-four** `rmsnorm` invocations per layer
per card (~645 cycles each at N=128 → **~2.48 ms/token at 300 MHz, ~3.22 ms at
the 231 MHz this card reaches at 0.717 V**, if fully serial), 32 L2 norms per
layer, ~8,192 silu evaluations per layer (0.74 ms/token at 1/cycle, ~2.2 ms
at the 3-cycle-FSM rate of the existing softmax cone), and the scalar path are
all outside it.

> **CORRECTED 2026-08-25.** The invocation count was 16, inherited from
> §1.1(g)'s stale-0.8B head count above: the output norm runs over the 48
> value heads (24/card), not the 16 key heads. That is 1.5x the invocations
> per card.
>
> The old **0.93 ms does not reproduce from its own stated inputs** and never
> did: 16 x 645 x 48 GDN layers is 495,360 cycles, which is 1.65 ms at
> 300 MHz, not 0.93. Some third input was applied and not written down, so the
> figure could not be corrected by scaling it -- it had to be rebuilt.
> Rebuilt: 24 x 645 x 48 = 743,040 cycles = 2.48 ms at 300 MHz. Both the
> count and the arithmetic were wrong, in the same direction, and either alone
> would have been recoverable from the text. Together they were not.

Serialized worst case is **~7.5-8.5 ms/token** (was ~6-7, before the +1.55 ms
correction above); with the §3 schedule overlapping norms and nonlinearities
under the next head's sweep, the target is **~3.5-4.5 ms/token**. §3 must
produce the real budget before the recon throughput figures are re-derived;
with A at 35-53 ms (423 MB) and C at ~4-4.4 ms, B's plausible range puts
`v3.0` at **~16-23 tok/s**, i.e. the low half of the recon's 19-28 band.

The overlapped target and the throughput band are deliberately NOT moved.
The correction lands entirely on a term the §3 schedule is meant to hide
under the sweep, and whether it still hides is exactly what §3 has to answer
with a real budget; scaling the target here would be inventing the answer.
What the correction does change is the margin: the term §3 must absorb is now
2.48 ms against a 2.95-3.14 ms sweep it hides under, i.e. it no longer fits
with room to spare and the overlap has to be near-perfect rather than
merely good. That is a §3 obligation, recorded, not discharged.

### 2.6 On-chip state

| State | Size | Medium |
|---|---|---|
| `k_n`, `q_s` (post-L2, all heads) | 2 x 2048 x 16 b | 2 BRAM36 |
| `v` (post-silu) | 2048 x 16 b | 1 BRAM36 |
| conv segment accumulator buffer (2048 x s34, reused per segment) | 8.5 KB | 2 BRAM36 |
| column working ring + pipeline regs | ~128 x 34 b x few stages | ~2-4K FF |
| head header `se[]` + `se_new[]` | 2 x 128 x 8 b | FF/LUTRAM |
| conv slot exponent registers (18 x 3 x 3 int8) | 162 B | FF |
| `o_head` staging + y buffer | 128 x 16 + 2048 x 16 b | 1-2 BRAM36 |
| `rmsnorm` marshalling (`x_mant`+`w_mant`, 2 x 128 x 16 b) | 4,096 FF | FF (C MJ4-3 precedent) |
| `ssm_norm`/dt/a constants (18 layers resident) | ~5.8 KB | 2 BRAM36 |
| AXI FIFOs (2R + 2W state, conv weights) | ~5 x 2 | ~10 BRAM36 |
| **Total** | | **~18-20 BRAM36, ~15-20K FF** (estimate) |

**Two normative requirements on subsystem D** (the C §2.6 pattern, same
reasoning):

1. **The `z` region must not be written until B asserts `done`.** z is
   consumed at the very END of the job (the output gate), long after the other
   five A outputs are dead. No copy of z is kept in B.
2. **B's `y` output region must be disjoint from `z`** (both are 2048 wide;
   nothing else prevents `y` overwriting unread gate words) and from the
   `qkv` regions until the conv slot write has BRESP'd.

### 2.7 AXI arbitration with subsystems A and C

A, B and C are **never active simultaneously** — subsystem D runs exactly one
unit at a time (per layer: A x6 → B → A, or A x3 → C → A, then FFN's A x3).
**CORRECTED 2026-08-25 (D's R7, its §2.2-A):** the attention arm read
"A x3 → C → A x3", which double-counts. Exactly ONE A job (`wo`) sits between
C and the FFN; the other three are the FFN's own gate/up/down, which the
"then FFN" already covers. C §2.7 is the authoritative order for its layer
type and reads A (`wq`,`wk`,`wv`) → C → A (`wo`) → A (FFN). D §4.3 counts 7 A
jobs in an attention layer, not 9. The GDN arm was right as written and is
unchanged. The
top-level arbiter grants the HP ports to the active unit; B claims 2 read + 2
write channels (§2.5). No bandwidth splitting, no starvation case.

- **`done` gates on the last BRESP** — the inter-token state RAW hazard of
  §2.4, C's MA-3/§2.7 rule, applies identically here and matters MORE: every
  B job re-reads what the previous B job wrote, every token, not just at cache
  positions.
- **B drains outstanding reads (count RLASTs to zero), then flushes its FIFOs,
  on `start`** — the corrected sequence from C §2.7, adopted wholesale; flush
  without drain corrupts the next job.
- Region bases come from the PS descriptor; B never parses a header,
  consistent with A §6.4 and C §2.7.

### 2.8 Resource budget, device-parametric

DSP cost as a function of the scaling generic: **`DSP_B ≈ 4·LANES +
aux(10-24)`** — 4 per lane from §2.1.4 (decay s16xu16, sk s19xs16, kd
s16xs18, output s16xs16; every one fits a single 27x18 DSP48E2 **because of**
the site-6 prescale and site-7 normalize, which exist for exactly this
reason). The aux estimate: sigma/silu interpolation 2-4, beta/scalar path
2-3, L2 sum-of-squares and output multiplies 4-8 (partially time-shareable
with the sweep lanes since the phases are disjoint, §2.4), `rmsnorm`
internals 2-4, conv MACs 0-8 (time-shared with the decay/sk lanes across
phases, or dedicated if §3's schedule overlaps conv with the sweep). **The aux
row is an estimate and unverified**, exactly the caveat C §2.8 carries.

> **MEASURED 2026-08-25 (`sim/micro/micro_b_array.vhd`, OOC at 300 MHz):**
> **`DSP_B = 4 x LANES + 20`, exact at LANES 4/8/16/32.** So **148 at
> LANES=32** and 52 at LANES=8, both inside the estimates above. The fixed 20
> is precisely `rmsnorm_rs 18 + silu 2`, the two instantiated units summed:
> array integration costs **no** DSP, because the reduction is an XOR tree and
> the broadcasts are routing.
>
> Swept with the shared aux BOTH in and out, so the per-lane and fixed terms
> separate by direct subtraction rather than only through a fit intercept --
> which is what shows the aux is CONSTANT rather than merely small.
>
> The array had to be measured rather than extrapolated from `micro_b_lane`:
> subsystem C's array measured **30% above** its own single-lane LUT fit,
> because an isolated lane has no broadcast, reduction or shared operand
> registers. For B that inflation is **+16% in LUT and exactly 0% in DSP**.
>
> **This is a FLOOR for B, not its total.** The micro covers the state-sweep
> arithmetic and the §1.1(g) output gate. B's **L2 norms** (32/layer),
> **softplus** and scalar path are NOT in it. Believed cheap -- C measured its
> divider at 0 DSP and the rsqrt sits inside `rmsnorm_rs`, already counted --
> but believed is not measured.
> Full procedure: `docs/debugging/2026-08-25_b-lane-dsp-measured.md`

| Resource | B @ LANES=8 | B @ LANES=32 | AXU3EG (XCZU3EG) | FK33 (XCVU33P) |
|---|---|---|---|---|
| DSP48E2 | **42-56** (52 measured) | ~138-152 -> **148 MEASURED** | 360 | **2,880** |
| LUT (shifters x4 alignment sites, quantizers, control) | ~10-14K (1.8K measured, sweep+gate only) | ~25-35K (3.2K measured, sweep+gate only) | 70,560 | ~440K |
| FF | ~15-20K | ~35-45K | 141,120 | ~880K class |
| BRAM36 | ~18-20 | ~25-30 | 216 | 23.6 Mb + 90 Mb URAM (14.2 MB) |
| State residency | DDR stream (9.5 MB) | URAM option, §2.9 | 0.95 MB on-chip | 14.2 MB on-chip |
| Sweep time (0.8B shapes, 200 MHz) | 2.95-3.14 ms | ~0.74 ms (0.49 at 300 MHz) | | |

LUT/FF/BRAM rows are estimates from the §2.6 table plus alignment barrel
shifters; none has seen synthesis.

> **MEASURED 2026-08-23: the 4-per-lane term is confirmed; the aux row is not.**
> OOC synthesis of one lane carrying the full four-stage §2.1.4 chain, on the
> real part (`xcvu33p-fsvh2104-2L-e`, 300 MHz target), gives **DSP=4, LUT=50,
> FF=118** -- utilisation and an independent DSP48E2 census agreeing, all four
> `USE_MULT=MULTIPLY`. So every product does fit a single 27x18 DSP48E2, and the
> site-6 prescale and site-7 normalize do the job they were introduced for.
>
> Two things the census shows that the estimate did not predict. The s41 sk
> accumulate folded into the DSP's own 48-bit P register (`sk_acc_reg` PREG=1)
> rather than spilling to fabric, which is why the lane is 50 LUT and not several
> hundred. And the lane closes at **446 MHz** in isolation -- B's arithmetic is
> nowhere near the critical path, so if B ever fails timing the cause will be the
> state feed or the cross-lane reduction, not this chain.
>
> At `LANES = 32` the derived part of the budget is therefore **128 DSP, ~1.6K
> LUT, ~3.8K FF** -- the fabric cost is negligible against the estimated 25-35K
> LUT row, because that row is dominated by the barrel shifters and control this
> skeleton does not contain. **The aux(10-24) range remains unverified**, along
> with the cross-lane sk reduction tree, sigma/silu, the L2 sum-of-squares and
> the conv MACs, none of which are in the skeleton. Procedure and evidence:
> `docs/debugging/2026-08-23_bc-lane-micro-synthesis.md`.

**FINDING: A + B + C do NOT safely co-fit the AXU3EG at their current
nominal widths.** The arithmetic:

```
A (ROWS_IF=4)              136        (A 7.9, derived)
C MAC+rescale (MACS=64)    128        (C 2.8, derived)
C auxiliary                 15-40     (C 2.8, estimate)
B (LANES=8)                 42-56     (this section, 32 derived + aux estimate)
                          ---------
                           321-360  of 360   =  89-100%
```

At the optimistic end of both estimate ranges this fits with zero margin; at
the pessimistic end it consumes the entire device — and this project's silicon
history (C §2.8: `rmsnorm.vhd:296`, `bfp_pack`'s header, the `attention_ml`
debug log) documents **non-deterministic behaviour from congestion at lower
utilization than this**. This is a project-level result about the `v3.0`
ladder rung, not a defect of any one spec, and belongs in
`docs/fpga-hardware-recon.md`. The honest options, with numbers:

1. **C at `MACS=32`** (C §2.8's own documented fallback): -64 DSP → total
   **257-296 (71-82%)**, which fits with real margin. Cost: C's attention
   sweep ~7.9 ms instead of ~3.9 — about +8% of the token budget.
2. **B at `LANES=4`**: -16 DSP → 305-344 (85-96%). Still marginal, and B's
   sweep doubles to ~5.9 ms — a worse trade than option 1.
3. **Cross-subsystem DSP time-sharing.** Logically sound — A, B and C are
   never concurrent (§2.7), so peak *simultaneous* demand is max(136, ~168,
   ~56), not the sum. But DSP48E2s are not runtime-relocatable: sharing means
   one multiplexed super-datapath serving three masters, with the routing
   congestion and verification surface that implies. Rejected for v2.x;
   recorded because at some future rung it becomes the only lever left.

Plan of record for `v3.0` until §3 of both B and C produce synthesized
numbers: **option 1** (C at MACS=32). If C's auxiliary estimate lands at the
low end AND B's aux lands low, MACS=64 can be restored by re-running one
generic.

### 2.9 FK33 / device scaling: what changes and what does not

**Invariant across targets:** the entire §2.1 numeric contract, the column
pipeline (§2.4), the record formats and layouts (§2.1.1, §2.2), the interface,
and the C reference. As with A, the streamer backend and the generics change;
the datapath does not.

**What changes:**

| | AXU3EG (`v3.0`) | FK33 (`v4.0`/`v5.0`) |
|---|---|---|
| `LANES` | 8 | 32-64 |
| State backing | PS DDR4, 2R+2W masters | HBM ports, or **URAM-resident** |
| State traffic pressure | 19 MB/token vs 8-12 GB/s: **1.6-2.4 ms, a first-order term** | 19 MB/token vs 460 GB/s: **~41 us — noise** |
| Target model | Qwen3.5-0.8B (dims verified) | 9B / 27B (**GDN dims NOT verified**, below) |

**The recurrent state is where the devices differ most.** The 0.8B state at
int16 is 9.47 MB including headers — it FITS the VU33P's 14.2 MB of
BRAM+URAM with ~4.7 MB to spare, so on the FK33 the state need never touch
external memory at all: the "streamer" becomes a URAM address generator, the
2R+2W masters disappear, the §2.7 BRESP gate becomes trivial, and the sweep is
purely compute-bound (`262,144/LANES` cycles/layer; at LANES=32 and 300 MHz,
~0.49 ms/token for 18 layers). URAM's 72-bit ports stripe naturally at 4
int16 elements per URAM per cycle — 8 URAMs per lane-group of 32.

**But the FK33 rung does not require residency** — that is the important
architectural point. Even streamed from HBM, 19 MB/token is 41 us. Residency
is an optimization that frees HBM bandwidth for weights, not a structural
change, so the AXU3EG streaming design ports unchanged and residency can be
adopted afterwards without touching the contract.

**Unverified for v4.0/v5.0:** the 9B's GDN head structure (`ssm_dt_rank`,
`ssm_d_inner`, layer count 32 with 3:1 hybrid → 24 GDN layers). If the 9B
mirrors the 0.8B head structure scaled (e.g. H=32), the state is
`32,896 B/head * 24 layers * H` ≈ 25.3 MB at H=32 — **exceeding 14.2 MB**, forcing
either int8 state mantissas (~13 MB, with the §2.1.1 feedback-error caveat) or
HBM streaming (which, again, costs ~nothing at 460 GB/s). The 27B (48 GDN
layers, `ssm_group_count=16` confirmed in the recon doc, `dt_rank`
unconfirmed) is a two-FK33 target and its state partitioning follows the layer
split. **These dims must be read from the GGUFs before v4.0 planning, not
assumed** - the same rule the recon doc applies to everything else.

> **VERIFIED 2026-08-25 for the 27B**, read directly from
> `/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf` via gguf-py, not
> inferred:
>
> | key | value |
> |---|---|
> | `ssm.state_size` | 128 |
> | `ssm.group_count` | 16 (key heads) |
> | `ssm.time_step_rank` | 48 (value heads) |
> | `ssm.inner_size` | 6144 |
> | `ssm.conv_kernel` | 4 |
> | `block_count` | 64 |
> | `full_attention_interval` | 4, so **48 GDN layers** |
>
> This closes the `dt_rank` unconfirmed note above for the 27B: it is 48, and
> the GQA ratio inside GDN is **3 value heads per key head**, not the 1:1 of
> the 0.8B. The 9B remains unverified.

### 2.10 State precision under recurrence: RESOLVED 2026-08-25, int16 stands

> **MEASURED. The error is bounded, not compounding.** It reaches an
> equilibrium of ~5e-4 relative output error by token ~1000 and stays flat
> through 16,384 tokens with the decay gate **pinned at `exp(g) = 1.0`**, the
> least contractive value the gate can take. That last condition is the one
> that matters: a recurrence driven by inputs that happen to keep the gate
> contractive looks stable for reasons that do not hold in production, so the
> bound was taken at zero contraction rather than at the real per-head decay.
>
> | regime | worst-head relative output error |
> |---|---|
> | real per-head `exp(g)` from the GGUF, sigmoid beta, iid inputs | 5.2e-4, flat |
> | `exp(g) = 1.0`, 16,384 tokens | 6.1e-4, flat from t ~ 1024 |
> | persistent `beta = 0.02` | 5.1e-3 |
> | 2% of v channels at 30x outliers | 5.6e-3 |
> | correlated inputs, rho = 0.9 | 1.4e-3 |
> | **every adversarial knob stacked**, 8192 tokens | **2.27%** |
>
> Against this project's own yardstick, that is noise: A's weight format
> carries ~8% relative weight error for +1.69% perplexity
> (`2026-08-24_subsystem-a-format-perplexity.md`).
>
> **Widening the state does not help in the only regime where the error is
> large.** Stacked-adversarial measures 2.27% at W16, **2.06% at W18 and 2.04%
> at W20**. The residual comes from the 16-bit seams this spec pins at sites
> 7, 9 and 12, not from the state width, so the contingency below would spend
> traffic and DSP for a ~10% reduction in an error that is already acceptable.
> The width sweep at the base regime bottoms out at ~2.4e-4 for W >= 18
> against 5.2e-4 at W16, and 1.4e-2 at W12.
>
> **Consequences: none of the contingency fires.** §2.8's four-products-in-one-
> DSP48E2 co-fit and §2.3's traffic numbers stand as written. `se_new` never
> left int8 range in any run (0 events); `sat16` events were rare and benign.
>
> Two caveats. **No real Qwen3.8 GDN activations exist in this repo** (the
> golden vectors are stories260K), so the drive is synthetic with sensitivity
> knobs, and the production bound lies somewhere between 5e-4 and the 2%
> stacked ceiling. And input quantization alone contributes ~3.3e-3, about 6x
> the loop's own error, so the recurrence is not the dominant term either way.
>
> This measurement is also what found the `SE_INIT` defect in §2.1.4, which
> was doing ~1000x more damage than the effect it was written to bound.
> Procedure, raw output and the rejected hypotheses:
> `docs/debugging/2026-08-25_gdn-recurrence-error-bound.md`; tool
> `ref/gdn_err.c`.

The original statement of the risk follows, unedited, because it is what the
measurement was designed against.

**This is a premise of section 2, not a section 3 detail.** The state is
requantized to int16 **every token**, and the result feeds back through the
recurrence, so quantization error compounds across a sequence in a way that C's
write-once KV cache never does. Over a 2048-token sequence that is 2,048
successive requantizations of the same state.

Nothing in this spec bounds that error. If §3's analysis shows int16 is
insufficient:

- the state format widens (int24 or int32), so per-token traffic rises from
  18.9 MB to 28-38 MB, which is 4.5% -> 7-9% of the token budget;
- the DDR-residency argument (§2.6) weakens correspondingly;
- the four-products-in-one-DSP48E2 result (§2.8) may not survive a wider
  mantissa, which would change the co-fit conclusion.

The error bound is therefore a **gating deliverable for §3**, not an optional
analysis, and it should be computed before any RTL is written. A cheap
first check: run the C reference at int16 against an fp32 model of the same
recurrence over a few thousand tokens and measure divergence.

**That check was run and is the box above. The gate is open.** One correction
to the plan as stated: the fp32 oracle must eat **dequantized** inputs, not
the raw ones, or input quantization dominates the measurement and the feedback
loop's own contribution is never isolated. `ref/gdn_err.c` does this by
default and `--inq-real` shows the difference.

## 3. Datapath scheduling, nonlinearities, validation

**PARTIALLY WRITTEN 2026-08-25.** §3.1-§3.5 below discharge the phase-schedule
and per-token-budget bullet. The remaining bullets (fixed-point recipes, the
error bound, the C reference, the GHDL test list) are listed as still owed in
§3.6 and are NOT closed.

### 3.1 §2.5's headline comparison is not like-for-like, and the sweep is 1.97 ms

§2.5 concludes that the norm term "no longer fits with room to spare and the
overlap has to be near-perfect". **That conclusion compares a 27B-corrected
numerator against an 0.8B denominator.** The 2.48 ms norm figure was rebuilt on
2026-08-25 at 48 GDN layers, 24 value heads per card and 300 MHz -- all §4
numbers. The 2.95-3.14 ms sweep it is compared against is the §2.5 body's
0.8B figure: 262,144 elements/layer, 18 layers, 200 MHz. The two cannot be
divided by one another, and the ratio that was read off them means nothing.

This is the §4-overlay failure mode Fable's review names generally and it has
now produced a numeric conclusion, not just a stale dimension. The sweep,
rebuilt at §4 dimensions:

```
state elements per layer per card = head_v_dim^2 x v_heads/card = 128 x 128 x 24
                                  = 393,216
x 48 GDN layers                   = 18,874,368 elements per token per card
cycles = 18,874,368 / LANES
```

| `LANES` | sweep cycles | ms @ 300 MHz | GB/s demanded |
|---|---|---|---|
| 8 | 2,359,296 | 7.86 | 9.6 |
| 16 | 1,179,648 | 3.93 | 19.2 |
| **32** | **589,824** | **1.97** | **38.4** |
| 64 | 294,912 | 0.98 | 76.8 |

(Port counts moved below, because deriving them needs §3.4's measurement.)

**`LANES = 32` needs four HBM ports, and B is compute-bound there with
margin.** The sweep reads 2 B and writes 2 B per element, so it demands
`4 x LANES` B/cycle = 38.4 GB/s at `LANES = 32` and 300 MHz.

> **CORRECTED 2026-08-25, later the same evening.** This paragraph first
> derived the port count as `LANES / 8` from "a measured HBM port delivers
> 32 B/cycle", and then claimed B's compute time and its four-master
> allocation "coincide to the cycle... simultaneously compute-bound and
> feed-bound". **Both halves were wrong, and §3.4's own measured table --
> written ten minutes later -- contradicts the second one.**
>
> The 32 B/cycle figure is the READ-ONLY rate. An AXI port carries 32 B/cycle
> **per direction**, 64 total, so a naive read of the port would give
> `LANES/16` = 2 ports. The binding constraint is neither: it is the
> read/write turnaround measured in §3.4, which puts a channel carrying a 1:1
> R+W mix at **11.77 GB/s**. So:
>
> **ports = ceil(4 x LANES x f / 11.77 GB/s)** -- at `LANES = 32`,
> 38.4 / 11.77 = 3.26, hence **4 ports**. The count is unchanged; the reason
> is not, and the reason is what generalises.
>
> And B is **not** balanced there. Four ports deliver 47.1 GB/s against 38.4
> demanded: **+23% feed margin**, i.e. compute-bound with room, which is a
> better position than the one the original text claimed and a different one.

| `LANES` | demand | ports at 11.77 GB/s each | margin |
|---|---|---|---|
| 8 | 9.6 GB/s | 1 | +23% |
| 16 | 19.2 GB/s | 2 | +23% |
| **32** | **38.4 GB/s** | **4** | **+23%** |
| 64 | 76.8 GB/s | **7** (not 8) | +7% |

Note this replaces §2.9's FK33 row, which is stale on three counts at 27B: it
says state traffic is "19 MB/token vs 460 GB/s: ~41 us -- noise", but per-card
traffic is **75.5 MB/token** (§4.1), the supply is **288 GB/s measured, not
460**, and B is allocated 4 ports of 30, not the whole device. Against B's
actual allocation the traffic is 1.97 ms and co-limiting, not noise. §2.9 also
still claims the state fits on chip; §4.1 already says 37.75 MB per card does
not fit 14.2 MB, so §2.9 contradicts §4.1 and §4.1 wins.

### 3.2 The nonlinearities dominate the sweep, and no schedule hides them

Rebuilt at §4 dimensions, per card per token, 300 MHz. All three terms use
`rmsnorm.vhd`'s shipped cost, which §2.5 quotes as 645 cycles at N=128:

| term | invocations/token/card | cycles each | cycles | ms |
|---|---|---|---|---|
| state sweep, `LANES = 32` | -- | -- | 589,824 | **1.97** |
| output `rmsnorm(o_h)` | 24 heads x 48 layers = 1,152 | 645 | 743,040 | 2.48 |
| `l2_norm(q)`, `l2_norm(k)` | 8 k-heads x 2 x 48 = 768 | 645 | 495,360 | 1.65 |
<!-- 495,360 collides with the WITHDRAWN 16-invocation output-norm figure in
     §2.5's correction note, for an unrelated reason: 8 k-heads x 2 operands
     = 16 L2 invocations per layer, and the withdrawn figure used 16 output
     norms per layer.  Same count, different quantity.  Not a copy. -->
| `silu`, 3-cycle FSM rate | 393,216 evaluations | 3 | 1,179,648 | 3.93 |
| **serial total** | | | **3,007,872** | **10.03** |

The silu count is derived rather than inherited: `silu(conv_out)` runs over the
per-card conv width (q 1024 + k 1024 + v 3072 = 5,120) and `silu(z_h)` over the
per-card value width (3,072), so 8,192 per layer x 48 = 393,216. It coincides
with §2.5's 0.8B figure of 8,192/layer for unrelated reasons -- there the whole
conv_dim was 6,144 with no sharding -- so it is stated with its derivation to
stop the coincidence reading as a copy.

**The nonlinearities are 2,418,048 cycles against a 589,824-cycle sweep: 4.10x.
Overlap cannot hide 4x under 1x.** §2.5 frames this as a scheduling problem
that a near-perfect overlap might solve. It is not one. A *perfect* schedule
gives `max(sweep, nonlinear)` = 8.06 ms, which sits inside §2.5's own
7.5-8.5 ms **serial** worst case: with these unit rates, overlapping everything
perfectly buys essentially nothing, because the thing being hidden is larger
than the thing it would hide under. **The units have to get faster; arranging
the phases only matters afterwards.**

### 3.3 What makes them fast, and why the first hypothesis was wrong

The obvious hypothesis -- the 24 head norms per layer are independent, so
pipeline them and pay the rsqrt latency once instead of 24 times -- **is
wrong**, and it was rejected by reading `rtl/rmsnorm.vhd`'s FSM rather than by
subtracting estimates. The 645 cycles are almost entirely element-proportional:

```
S_ACC              N cycles     one x*x per element
S_INV + rsqrt    ~15 cycles     FIXED: seed, 2 Newton iterations x 3 mults, fold
S_RAW/S_RAW_B     2N cycles     two cycles per element
S_SHIFT             1 cycle
S_EMIT/S_EMIT_B   2N cycles     two cycles per element
                 = 5N + ~15  =  655 at N = 128, against the 645 §2.5 quotes --
                                 close enough to confirm the structure, and
                                 645 is used throughout below so the arithmetic
                                 stays comparable with §2.5's own figures
```

The fixed part is ~15 cycles, ~2%. Pipelining across invocations saves that and
nothing else. Two changes do the work instead:

1. **DO NOT fuse RAW and EMIT by storing `raw`.** An earlier draft of this
   section proposed exactly that, on the reading that `S_EMIT` needlessly
   re-derives what `S_RAW` already computed. **It is not needless.** The RTL
   comment at `rtl/rmsnorm.vhd:S_RAW` records why:

   > "This removes a 64x64-bit indexed array that Vivado inferred as
   > UNINITIALIZED distributed RAM in the congested engine (-> non-deterministic
   > HW output); recompute is bit-identical (same widths/order)."

   The duplication is a **fix for a measured silicon failure**, not an
   oversight, and re-introducing the `raw` array re-introduces the bug. The
   proposal is withdrawn.
2. **Pipeline RAW and EMIT to one cycle per element.** The shipped unit spends
   TWO cycles in each (`S_RAW`/`S_RAW_B`, `S_EMIT`/`S_EMIT_B`), split so that
   `xm*inv` and `(xm*inv)*wm` are not a cascaded-DSP combinational cone -- the
   same reason the rsqrt is pipelined. Registering between them at one element
   per cycle keeps that property and costs nothing: 5N becomes **3N**, with no
   array and no stored `raw`.
3. **Vectorize.** The element-proportional part divides by the lane count.
   Only x and w are buffered, at 16 bits each -- not the 64-bit `raw`.

| form | cycles at N=128 | out+L2 cycles | ms |
|---|---|---|---|
| `rmsnorm.vhd` as shipped, 5N, 1 element/cycle | 645 | 1,238,400 | 4.13 |
| 5N, **4 elements/cycle** -- vectorized only, no other change | 175 | 336,000 | 1.12 |
| **3N, 4 elements/cycle** -- RAW/EMIT pipelined, recompute KEPT | **111** | **213,120** | **0.71** |
| 2N by storing `raw`, 4 elements/cycle | 79 | 151,680 | 0.51 (**REJECTED**, see above) |

**Vectorization alone is sufficient**, which is the important line in that
table. Whole-phase budgets against the 589,824-cycle sweep:

| norm form (4 lanes) | norms + L2 + silu + conv | vs sweep |
|---|---|---|
| shipped 5N, serial 1 element/cycle | 1,386,624 cycles, 4.62 ms | **does not hide** |
| 5N, 4 lanes, no other change | 465,024 cycles, 1.55 ms | hides, +27% margin |
| **3N, 4 lanes** | **342,144 cycles, 1.14 ms** | **hides, +72% margin** |

So the rejected `raw` array was buying margin the design does not need. 3N at
4 lanes is the target; 5N at 4 lanes is the fallback and still works.

silu must be **at least 1 per cycle and preferably 4**; the 3-cycle FSM rate of
the existing softmax cone is 3.93 ms on its own, twice the sweep. That is
already known to be achievable and cheap: D's measured narrowed silu lane is
**3 DSP at 646 MHz**, bit-identical to the verbatim-width cone over 5,769
outputs (`docs/debugging/2026-08-25_d-vec-dsp-measured.md`, and the
`micro_silu_narrow` row in D §12).

**Budget with fused 4-lane norms and 4/cycle silu:**

| term | cycles | ms |
|---|---|---|
| state sweep, `LANES = 32` | 589,824 | 1.97 |
| output rmsnorm + L2, **3N, 4 lanes** | 213,120 | 0.71 |
| silu at 4/cycle | 98,304 | 0.33 |
| conv, depthwise k=4 over 5,120/layer at `LANES = 32` | 30,720 | 0.10 |
| **nonlinear + conv, overlapped under the sweep** | 342,144 | 1.14 |
| **B token time = max(sweep, overlapped)** | **589,824** | **~1.97** |

The nonlinearities now fit under the sweep with 72% margin, which is the
"merely good" overlap §2.5 wanted and did not have. **B lands at ~2.0 ms/token,
better than §2.5's 3.5-4.5 ms target**, and the term that moved is unit
throughput, not scheduling.

### 3.4 The sweep is a read-modify-write on ONE pseudo-channel

§2.4's column pipeline reads column j and writes it back. Read and write
therefore land in the **same state region**, hence the same 256 MB
pseudo-channel. That is not the striping §2.5 describes -- striping by head
parity separates heads across masters, it does not separate a head's read from
its own write.

This matters because a pseudo-channel that turns its bus around pays tWTR/tRTW,
and B's sweep turns it around continuously. §2.5's ">= 50% per master"
premise is stated for four masters but never distinguishes four masters on four
channels from a read and a write contending for one.

**MEASURED 2026-08-25, and the answer is: keep the in-place sweep.** The
turnaround was measured on the card at 30 ports, 300 MHz
(`docs/debugging/2026-08-25_hbm-read-write-turnaround.md`,
`hw/fk33/results/hbmbw_readwrite.txt`):

| | measured | of the 14.4 GB/s channel |
|---|---|---|
| one port, reads AND writes into one pseudo-channel | **11.77 GB/s** | **81.8%** |
| 30 ports, same | 353.0 GB/s | linear, nothing upstream saturates |
| 20 readers + 10 writers on INDEPENDENT channels | 288.0 GB/s | identical to read-only within 1 cycle in 1.6M |

So the turnaround costs **18.2%**, and switch arbitration between read and
write masters costs **nothing at all** -- the mixed-across-ports run matched
the read-only run to one cycle in 1.6 million. The whole penalty is the DRAM
bus reversing.

**A ping-pong between two state regions was drafted here and is WITHDRAWN.**
The reasoning was that separating reads from writes onto different channels
avoids the 18.2%. It does -- and it costs more than it saves, because a port
dedicated to one direction leaves its other direction idle, and AXI's two
directions are independent:

| B at `LANES = 32`, needing 19.2 GB/s each way | delivered | margin |
|---|---|---|
| **in-place, 4 ports doing R+W** | **47.1 GB/s** (23.5 each way) | **+23%** |
| ping-pong, 2 read + 2 write ports | 38.4 GB/s (19.2 each way) | 0% |

Both need four ports, so the ping-pong buys no port back; it would have spent
37.75 MB per card to arrive with zero margin instead of 23%. **B's state sweep
stays an in-place read-modify-write, and §2.5's four-master allocation stands
with the masters bidirectional rather than split by direction.**

The 81.8% is not a general HBM efficiency figure and must not be reused as one.
It is a 1:1 read/write mix; C's 2R+1W on a single channel is a different mix
and is not covered.

**Burst length checked, 2026-08-25.** The 11.77 GB/s was measured at ARLEN=15
(16 beats), and B does not issue that burst -- §2.4's column pipeline works one
128-element column at a time, which is 256 B = **8 beats**. A doubled
turnaround frequency could plausibly have eaten the whole margin, so it was
measured on the loaded bitstream rather than argued about:

| burst | beats | GB/s | 4 ports vs 38.4 demanded |
|---|---|---|---|
| ARLEN=15 | 16 | 11.8 | +23% |
| **ARLEN=7** | **8 (B's column)** | **11.5** | **+20%** |
| ARLEN=3 | 4 | 11.0 | +15% |
| ARLEN=1 | 2 | 8.9 | -7%, does not feed |

**B's real burst costs 2.0%.** The margin is +20%, not +23%, and the in-place
conclusion is untouched -- the ping-pong sits at 0% margin at *any* burst
length, because what limits it is dedicating each port to one direction, not
turnaround.

**But below 4 beats it collapses.** Any B access pattern that would issue
2-beat bursts must be restructured before it is built; §2.4 should be read as
requiring at least a full column per burst.

### 3.5 Consequences for §2.5, §2.8 and the recon ladder

- §2.5's **2.95-3.14 ms sweep and its 47%/50% efficiency table are 0.8B
  figures** and are superseded by §3.1. The four-master claim survives; the
  numbers behind it do not.
- §2.5's **7.5-8.5 ms serial worst case is optimistic**, not pessimistic: at
  §4 dimensions with shipped units it is 10.09 ms (§3.2).
- §2.5's **3.5-4.5 ms overlapped target is superseded downward to ~2.0 ms**,
  conditional on §3.3's unit rates, which are a design obligation and not yet
  synthesised (§3.6).
- **§2.8's DSP row is a floor and this section raises it.** The measured 148
  (`DSP_B = 4 x LANES + 20`) carries `rmsnorm_rs 18 + silu 2` as its fixed 20,
  i.e. ONE norm unit at 1 element/cycle. §3.3 requires a 4-lane fused norm and
  a 4/cycle silu, which the fixed 20 does not cover. The increment is not yet
  measured; §3.6 owns it.
- The recon tok/s ladder should NOT be re-derived from this section yet. B
  moving 3.5-4.5 -> ~2.0 ms would move `v3.0` upward, but A dominates at
  35-53 ms, and although §3.3's norm DSP cost is now measured its **Fmax is
  278.9 MHz, not the 300 this budget is quoted at** (§3.6). One unmeasured
  term is exactly how §2.5's 0.93 ms got into the document; an unreached clock
  is the same failure wearing a different hat.

### 3.6 Still owed by §3 (NOT closed by the above)

The phase-schedule bullet is discharged. These are not:

- **CLOSED for rmsnorm 2026-08-25: `rtl/rmsnorm_rs.vhd` exists, is bit-exact
  with `rtl/rmsnorm.vhd`, and reaches 300.8 MHz.**

  | `LANES` | DSP | Fmax | cycles at N=128 |
  |---|---|---|---|
  | 1 | 22 | 300.8 MHz | 430 |
  | **4** | **40** | **300.8 MHz** | **142** |
  | 8 | 64 | 200.0 MHz (does not close) | 94 |

  `DSP = 16 + 6 x LANES`. Against the shipped unit at N=128: **4.6x fewer
  cycles and 2.2x the clock, for 40 DSP against 78**. Bit-exact on 64 cases at
  every `LANES` in {1,2,4,8,16}, `o_mant` and `o_exp`, with the original
  instantiated side by side as the golden (`sim/tb_rmsnorm_rs.vhd`).

  **`MREG` was not the fix**, contrary to what this item and C §3.13 both
  predicted -- it is worth 26 MHz of the 183, and a version written with the
  MREG cadence already in it measured 117.2 MHz. The rest came from splitting
  fused states, seven measured iterations, each one bucketed from the actual
  failing path. `docs/debugging/2026-08-25_rmsnorm-rs-300mhz.md`.

  §3.3's budget with the measured 142 cycles: norms + L2 + silu + conv =
  **401,664 cycles = 1.34 ms against the 589,824-cycle sweep, +47% margin.**
  Whole-die DSP moves **2,524 -> 2,546 of 2,880 = 88.4%** (B's row 148 -> 170,
  the fixed 18 becoming 40).

- **CLOSED 2026-08-26: `rtl/gdn_recur.vhd` implements 2.1.4 stages 1-5, one
  column of one head, multi-lane, with the cross-lane reduction and the state
  feed actually built. It CONFIRMS the DSP figure and REFUTES the schedule.**

  | `LANES` | DSP | Fmax | cycles/column | ideal | ratio |
  |---|---|---|---|---|---|
  | 1 | 5 | 318.9 MHz | 416 | 128 | 3.3x |
  | 4 | 17 | 320.2 MHz | 131 | 32 | 4.1x |
  | 8 | 33 | 318.9 MHz | 88 | 16 | 5.5x |
  | 16 | 65 | 318.9 MHz | 67 | 8 | 8.4x |
  | **32** | **129** | **318.9 MHz** | **58** | **4** | **14.5x** |

  **DSP = `4 x LANES + 1`, so §2.8's 4-per-lane figure is now measured on a
  unit that computes the right answer** rather than on `micro_b_lane`. At
  `LANES = 32` that is 129 against the 128 the aux table assumes: +1, the only
  DSP surprise in the unit.

  **But §3.1's 589,824-cycle sweep assumes 4 cycles per column at
  `LANES = 32`, and this unit takes 58.** The budget's arithmetic is
  self-consistent -- 4 cycles for 128 elements at 32 lanes means every one of
  the 4 multiplies per element is busy every cycle -- and that is exactly what
  a unit running passes A, B and C SEQUENTIALLY for one column cannot do. Each
  stage's multiplier is idle while the other stages run, and the per-column
  scalar chain (two tree reductions, the site-7 normalize, the delta scalar,
  the `sh` derive) is ~50 of the 58 cycles and does not shrink with `LANES` at
  all. That is why the ratio gets WORSE as lanes are added: 3.3x at 1 lane,
  14.5x at 32.

  | `LANES` | measured cycles/token/card | ms @ 300 MHz | §3.1 budget |
  |---|---|---|---|
  | 8 | 12,976,128 | 43.3 | 7.86 |
  | 16 | 9,879,552 | 32.9 | 3.93 |
  | **32** | **8,552,448** | **28.5** | **1.97** |

  **28.5 ms against a 1.97 ms budget.** §3.3's whole "the nonlinearities hide
  under the sweep" argument compares against the 1.97, and §3.1's HBM port
  derivation assumes the sweep is compute-bound at that rate. Neither survives
  a 14.5x throughput miss, so both are now open pending the item below.

  **What closes it, and it is not a tuning change.** The columns are
  independent -- §2.4's column-locality, the property the whole streaming
  design rests on -- so the fix is to software-pipeline COLUMNS through the
  fixed datapath, keeping several in flight at different stages so the scalar
  chain is amortized instead of paid per column. That needs per-column
  replication of the scalar state and double-buffered `w18`/`u`, which is FF
  and possibly BRAM, not DSP. Until it is built and measured, treat the
  4-cycles-per-column figure as an ASSUMPTION, not a measurement: it is the
  arithmetic ideal of the DSP count, and this unit is the first evidence about
  what a real implementation achieves against it.

  Verified two ways, 192 cases, bit-exact at every `LANES` in {1,2,4,8,16,32}:
  against `ref/gdn_recur_vec.c` (cross-language, catches transcription) and
  against a double-precision oracle of the same column (different number
  system, catches a wrong recipe). The second one found a defect -- see the
  next item.

- **DEFECT FOUND 2026-08-26 in §2.1.4 stage 3, and it is a SECOND first-token
  weakness independent of the one corrected on 2026-08-25.** At `tk = 0`,
  `sk_acc = 0`, so `u[i] = k_n[i] * d_m` exactly: the state IS `d_m` up to a
  per-element constant, with nothing else in the sum to dilute its error. And
  `d_m` is quantized on `e_d`, a grid set by `min(e_v, ske)` -- the magnitudes
  of `v` and `sk` -- and not by `|d|`. With a small `beta`, `d_m` is a small
  integer and its relative error is large.

  | `beta` | P(`d_m` = 0) | median rel err | max |
  |---|---|---|---|
  | 2.4e-4 | **7.0%** | 6.39% | 100% |
  | 9.8e-4 | 1.4% | 1.60% | 100% |
  | 3.9e-3 | 0.4% | 0.40% | 100% |
  | 1.6e-2 | 0.1% | 0.10% | 100% |

  A max of 100% is not rounding: it is `d_m = 0`, **the first token's entire
  state discarded**. The testbench reports the split directly -- 4.90 LSB worst
  in steady state against 561.59 LSB at `tk = 0`, on the same unit with the
  same inputs. By this section's OWN correction note, a corrupted first token
  dilutes only as `1/t` and is still visible at `t ~ 1900`, so this degrades
  most sequences end to end.

  **Proposed correction, measured: normalize `d` onto its own grid, exactly as
  site 7 already normalizes `sk`.** `dm_raw = diff * beta`;
  `shd = max(0, msb_pos(|dm_raw|) - 14)`; `d_m = round_shift(dm_raw, shd)`;
  `e_dm = e_d + 16 - shd`; `e_kd = 15 + e_dm`. Drives `P(d_m = 0)` to zero and
  worst relative error to 1.5e-5 at every `beta`, for **one msb scan and one
  shift -- no extra multiply and no extra DSP.**

  **NOT APPLIED.** §2.1.4 is a pinned contract that `gdn_err.c`, §2.10's
  precision result and §3.3's schedule all reference. The evidence is recorded;
  the decision to change a pinned numerical contract is not one to take
  silently on a single night's measurement. `sim/tb_gdn_recur.vhd` carries a
  `TOL_S_TK0` generic whose comment says it is the measured size of an open
  defect rather than slack, and says to delete it when the correction lands.
  Full account: `docs/debugging/2026-08-26_gdn-first-token-dm-grid.md`.

  **RATE UNKNOWN, SIZE MEASURED.** Whether the real model's `beta` reaches this
  range is not established: `ref/gdn_eg_qwen3_27b.txt` carries the measured
  `exp(g)` table but there is no equivalent for `beta`, and `gdn_err.c` feeds
  `beta` in as a value rather than computing it from `softplus`/`sigmoid`.

- **CORRECTION 2026-08-25, same day: the recipe this item first pinned was
  NUMERICALLY BROKEN, and its testbench certified it. Withdrawn and replaced
  below.** Full account: `docs/debugging/2026-08-25_l2norm-recipe-collapse.md`.

  ~~`Q = 18` is forced -- `rsqrt_q` takes s64, `ssq < 2^37`, and the q path's
  `<<7` fold means `ssq<<7<<Q` must fit s63, so `Q <= 19`; at 18 the output
  shifts fall out as `>>3` and none.~~ **WITHDRAWN.** That derivation described
  the collapsed form `inv = round(2^Q/sqrt(ssq))`, which rounds to 1 or to 0
  across the unit's own operating range: the q path emitted **all zeros for
  every input with `ssq >= 2^33`** and the k path erred by up to **41%** below
  it. No value of `Q <= 19` rescues the form; the fault is the collapse to an
  integer, not the constant. In the corrected algebra **`Q` cancels entirely**
  and the generic is gone.

  The bug survived 55 passing cases because the golden was computed from the
  SAME recipe using the same `fixed_pkg.rsqrt_q` -- both sides of the comparison
  were wrong in the same direction. The commit that introduced it (`87fc976`)
  names that hazard in its own message and does not act on it.

- **CLOSED 2026-08-25 (corrected): `rtl/l2norm_rs.vhd` implements the L2 norm,
  both paths, on a recipe that keeps the rsqrt MANTISSA and a scalar shift.**

  ```
  ssq    = sum xm[i]^2
  m_k    = msb(ssq)          he_k = m_k/2   (fold by 1/sqrt(2) if m_k odd)
  k_n[i] = sat16( round_shift( xm[i] * y_k, 15 + he_k ) )    -- exp 15
  m_q    = msb(ssq << 7)     he_q = m_q/2
  q_s[i] = sat16( round_shift( xm[i] * y_q, 12 + he_q ) )    -- exp 18
  ```

  with `y_k`, `y_q` the Q30 Newton mantissas normalised to [1,2). The
  `1/sqrt(128)` fold stays a shift of the rsqrt ARGUMENT, not the output --
  that part of the original item survives, since `sqrt(128) = 8*sqrt(2)` is
  still not a power of two. `ssq = 0` emits zeros, the documented `ggml_l2_norm`
  divergence, still asserted explicitly.

  | `LANES` | DSP | Fmax | cycles at N=128 |
  |---|---|---|---|
  | 1 | 21 | 300.0 MHz | 313 |
  | **2** | **26** | **300.0 MHz** | **185** |
  | 4 | 36 | 285.8 MHz (does not close) | 121 |

  DSP is unchanged by the correction; the cycle counts drop by 6 (four states
  deleted, two added). **The first synthesis of the corrected unit came in at
  272.3 MHz**, not 300: the `1/sqrt(2)` fold multiply and its shift landed in
  the cycle that produces `y_k`, and `y_k` is absorbed into the lane
  multiplier's DSP B-input register, so the path ran arg -> multiply -> ALU ->
  3x CARRY8 -> B at 12 logic levels. Splitting the fold into `S_RQ_FOLD` /
  `S_RQ_FOLD2` costs 2 cycles of 313 and returns the full 300 MHz. This is the
  same rule the `rmsnorm_rs` work produced, applied to a second unit.

  Verified against an **INDEPENDENT real-valued golden** (a parallel `real`
  sum of squares and `math_real.sqrt`, sharing no machinery with the DUT and
  not using `fixed_pkg`), 56 cases, passing at every `LANES` in {1,2,4,8,16}
  with worst error **0.4995 LSB** against a 0.75 LSB tolerance. The testbench
  was then **mutation-tested**, which is the part that makes the above mean
  anything: the integer collapse that was the original bug is caught in 49
  cases at worst 2896 LSB, the withdrawn `Q = 18` form in all 56, and shift,
  parity-fold and rounding-bias mutations in 31-56 each.

- **CONSEQUENCE, and it is the uncomfortable one: meeting §3.3's schedule takes
  the die to the congestion line.** §2.8's measured `DSP_B = 4 x LANES + 20`
  prices its aux row with **1-lane** units (rmsnorm_rs 18 + silu 2). Those
  units cannot meet §3.3's schedule -- at 1 lane the norms alone are 740K
  cycles against a 590K sweep. The aux row that *does* meet it:

  | | 1-lane aux (the 148 figure) | the aux §3.3 needs |
  |---|---|---|
  | rmsnorm_rs | 18 (1 lane) | **40** (4 lanes) |
  | l2norm_rs | -- | **26** (2 lanes) |
  | silu | 2 (1 lane) | **8** (4 lanes, MEASURED) |
  | **aux total** | **20** | **74** |
  | **B total** (`4 x 32` sweep lanes + aux) | **148** | **202** |

  ```
  A 1,914 + C 434 + B 148 + D 28 = 2,524 of 2,880 = 87.6%   schedule NOT met
  A 1,914 + C 434 + B 202 + D 28 = 2,578 of 2,880 = 89.5%   schedule met
  ```

  The silu row is measured, not scaled: `micro_silu_narrow` with `SILU = 1`
  (the bare `x * sigmoid(x)` B needs, as opposed to D's `silu(g) * u` swiglu
  lane) is **2 DSP and 646 MHz per lane**, so 4 lanes is 8 rather than the 12
  a naive scaling from D's 3-DSP lane would give. It also costs **1 BRAM per
  lane** for the sigmoid ROM unless the lanes share one, which is a BRAM
  question and does not move the DSP sum.

  ~~**Every term in the 89.5% is now measured.**~~ **RETRACTED 2026-08-25**, by
  the author, before anyone had to catch it. Three terms are not:

  - the **depthwise conv** MACs, 0 to 32 depending on a sharing decision this
    section still lists as open, which alone is the difference between 89.5%
    and 90.6%;
  - **softplus and the scalar path**, ~2-4 DSP, never priced;
  - **C's row is the spec's 434**, not a measured unit; C's own norm is the
    same shape as `rmsnorm_rs` at N=256, which has never been synthesized.

  **The range above is itself too narrow -- corrected the same day, after
  review.** Two more terms are soft, and both were being counted as measured:

  | term | counted as | honest | delta |
  |---|---|---|---|
  | C's QK-norm inside the 434 | 18, a skeleton; C's own aux doc says the unit is unwritten | the real `rmsnorm_rs` is 22 at 1 lane, and **40 at 4** if C's schedule needs 4 -- the exact 1-lane-cannot-do-the-job failure that already moved B's own row from 148 to 202 | +4 to +22 |
  | conv MACs | absent | 0 time-shared, **32 dedicated**, and §3.3's schedule runs conv at LANES=32 | 0 to +32 |
  | softplus + scalar | absent | §2.8's own words are "believed cheap ... but believed is not measured" | +2 to +4 |
  | D's 28 | assumes phase sharing | unshared is 52, and the sharing "is a property of how the RTL is written" -- no D RTL exists | 0 to +24 |

  **Honest range: 2,584 to 2,670 of 2,880 = 89.7% to 92.7%.** The FLOOR is
  already above the 90% line this document keeps invoking, not at it.

  The claim to have measured everything was made in the same document that
  lists the conv sharing decision as open. Worse, it counted
  measured-as-a-skeleton and measured-on-a-broken-unit as measured -- which is
  the same epistemic move that produced the l2norm recipe collapse two items
  above: a number certified by something that shares its assumptions.

- **AND THE 90% CONGESTION LINE IS FOLKLORE FOR THIS PART.** Traced 2026-08-25.
  Every citation of it in this repo bottoms out at the gated-attention spec's
  "high utilization on this device is historically non-deterministic", whose
  evidence is `rmsnorm.vhd`, `bfp_pack`, and the `attention_ml` history -- all
  **AXU3EG (XCZU3EG, 360 DSP)** incidents, on a die two orders of magnitude
  smaller than the VU33P's 2,880. The flagship one was an **uninitialized
  inferred distributed RAM**, a functional bug whose visibility merely
  correlated with congestion. Nothing in it says a DSP percentage causes
  failure on this part, and the LUT document's own open list already concedes
  the point: "whether 90% is the right congestion line for this part -- still
  untested by any placed-and-routed run."

  Three reasons it is probably the wrong number here: it came from a different
  and much smaller die; DSP% is not usually the congestion driver, routing and
  LUT pressure are, and LUT sits at 60.6%; and what actually binds DSP-heavy
  UltraScale+ designs is cascade-column geometry (A's 33-DSP rows want
  contiguous column segments), which can bite well BELOW 90% or not at all.

  So `MACS=64` vs `32`, the conv sharing decision, and every "the die is at the
  line" alarm in these specs are currently being steered by an unvalidated
  threshold imported from other silicon. **Until a placed-and-routed fill
  experiment on this part says otherwise, treat 90% as an unvalidated
  assumption and not as a constraint.**

  **89.5% is at the 90% congestion line both B §2.8 and C §2.8 cite**, and the
  87.6% that every document has been quoting was only comfortable because the
  aux row was priced with units that do not do the job. The silu term is the
  one still estimated (~12, scaled from D's measured 3-DSP swiglu lane, which
  includes a `*u` multiply a bare silu does not need) and is the obvious place
  to look first. **This is a real finding and it should be treated as one: the
  die is no longer comfortably under the line.**

- ~~STILL OWED: the L2 norm is a DIFFERENT function~~ **-- closed above.**
  Retained note: `rmsnorm_rs` alone does not cover it, and §2.1.3 requires divide by `sqrt(ssq)` not `sqrt(mean)`, TWO
  output quantizations per element, the `1/sqrt(128)` fold (not a pure shift,
  since `sqrt(128) = 8*sqrt(2)`), no weight multiply, and a deliberate
  divergence from `ggml_l2_norm` at zero input. §3.3's 109,056-cycle L2 term
  assumes the same per-element cost as rmsnorm, which is plausible and
  unverified. ~~A `l2norm_rs` needs its own golden, which needs the C reference
  below.~~ **Superseded 2026-08-25:** the golden did NOT need the C reference,
  and waiting for it was the wrong instinct -- a golden in real arithmetic is
  both available immediately and STRONGER than a C reference transcribed into
  the same fixed-point form, which is exactly the trap that produced the recipe
  collapse above. **`rmsnorm_rs` closes the rmsnorm half of this line, not the line.**

- ~~The §3.3 norm DSP cost is now MEASURED; its Fmax is the problem.~~
  **Superseded by the two items above; the skeleton numbers are kept for the
  record.**
  `sim/micro/micro_rmsn_lanes.vhd`, OOC on `xcvu33p-fsvh2104-2L-e` at 3.333 ns:

  | `LANES` | DSP | LUT | Fmax |
  |---|---|---|---|
  | 1 | 18 | 385 | 278.9 MHz |
  | 2 | 24 | 480 | 278.9 MHz |
  | **4** | **36** | **554** | **278.9 MHz** |
  | 8 | 60 | 756 | 200.9 MHz |

  **`DSP = 12 + 6 x LANES`, affine with a nonzero intercept**, which is the
  structural check passing: the rsqrt consumes the accumulated sum of squares,
  one per vector, and is NOT replicated per lane. `LANES = 1` reproduces
  `micro_rmsn_narrow`'s 18 exactly, cross-validating both skeletons.

  So §3.3's 4-lane form costs **36 DSP against §2.8's fixed 18** for the 1-lane
  `rmsnorm_rs`, i.e. **+18 DSP**, and B's row moves 148 -> ~166 plus whatever a
  4/cycle silu adds over the fixed 2. Whole-die goes 2,524 -> ~2,542 of 2,880
  = 88.3%, still under the 90% line. **This is affordable.**

  **What is NOT resolved is that none of these forms reaches 300 MHz.** 278.9
  MHz at 1, 2 and 4 lanes -- identical, so it is one fixed critical path, not a
  width effect -- and 200.9 MHz at 8 lanes where the accumulator tree takes
  over. §3.1-§3.3's entire budget is quoted at 300 MHz. Either the norm gets
  another pipeline stage (the path is not yet bucketed, and every previous
  Fmax surprise in this project turned out to be one structure replicated), or
  B's token time scales by 300/278.9 = 1.076 and ~2.0 ms becomes ~2.1 ms.

  **The path is already diagnosed, by C.** C §3.6 hit 278.9 MHz on its own
  narrowed `rmsnorm_rs` skeleton and C §3.13 item 1 names `MREG` on the 34x32
  Newton stage as the expected fix. Two independent skeletons landing on the
  same 278.9 MHz -- and B's landing there at 1, 2 AND 4 lanes identically --
  says it is one fixed structure, not a width or fanout effect. **B and C
  share this fix; whoever lands it closes both.**
- ~~The same-channel read/write turnaround~~ **MEASURED, see §3.4.** 81.8% of
  channel; the in-place sweep wins and the ping-pong is withdrawn.
- **Pin the fixed-point recipes for sigma (sigmoid), softplus, exp-Q15 and the
  L2-norm rsqrt** — table sizes, interpolation, and every internal rounding —
  as §2.1.3/§2.1.5 sites 5, 13, 14 require. The Q15 regenerations of EXP_ROM
  and SIG_ROM (`tools/gen_fixed_luts_pkg.py`) are deliverables. The softplus
  threshold (`x > 20` passthrough, §1.1(f)) must be in the C reference.
- **A recurrence error bound is required, not just per-site rounding.** The
  state is requantized every token (site 11) after a Q15 decay multiply
  (site 6); error compounds through the feedback path in a way C's
  write-once KV cache never faces. §3 must bound the drift over a
  2048-token sequence against the float reference, and this bound decides
  whether int16 state mantissas (§2.1.1) and Q15 decay (§1.5) survive or need
  widening. This is the hardest deliverable in §3 and the reason it is not
  being written before sections 1-2 are reviewed.
- **The phase schedule** (§2.4/§2.5): overlap rmsnorm, L2 and silu under the
  state sweeps to land B's token time nearer 3.5 than 7 ms; silu must be
  pipelined ~1/cycle, not the 3-cycle FSM rate of the softmax cone. Produce
  the full per-token latency budget; feed the result back to
  `docs/fpga-hardware-recon.md`'s tok/s ladder together with the §2.8 co-fit
  decision and the 423 MB model size (§1.4).
- **The final output stage** (site 13): gated product `rmsnorm(o_h) * silu(z_h)`
  and the 16-head renormalization to the single `y_exp`, including both shift
  branches (the C MJ5-1 class).
- **The conv/sweep DSP time-sharing decision** (§2.8 aux row) with synthesized
  numbers, and the co-fit option 1/2 choice made jointly with C's §3.
- Bit-exact C reference implementing exactly §2.1 (`int64_t` intermediates,
  shift counts clamped, `msb_pos(0)=0`, both branches of every dual-branch
  site), validated against the reference implementation with the state held
  in the §2.1.1 format; GHDL tests must include: zero-state first token,
  `eg = 1.0` exact (g=0), the `smant=-32768 x eg=32768` prescale corner
  (§2.1.4 stage 1), sat16 corners of sites 2/11, a conv tap-masking test at
  tk = 0, 1, 2, and a multi-token state-feedback sequence compared
  token-by-token.
- The three `v1.0-silicon` rules: at most one multiply per state; never route
  data through a VHDL `integer` (exponents and descriptor fields excepted);
  constrain at the real clock. The VHDL `/` operator stays banned;
  `divider_rs` is the only sanctioned divide.
- An `err` consolidation completing §2.1.6, and bring-up steps mirroring A
  §10, including the **four-concurrent-master efficiency measurement** that
  §2.5's timing depends on.

## 4. RETARGET to Qwen3.8-27B on FK33 (2026-08-21, NORMATIVE)

**This section supersedes every Qwen3.5-0.8B dimension elsewhere in this
document.** All derivations in §1-2 remain valid; only the numbers change.

| Parameter | 0.8B (superseded) | **27B (current)** |
|---|---|---|
| hidden | 1024 | **5120** |
| GDN layers | 18 of 24 | **48 of 64** |
| key heads (`ssm_n_group`) | 16 | **16** |
| **value heads (`ssm_dt_rank`)** | 16 | **48** |
| `head_k_dim` / `head_v_dim` (`ssm_state_size`) | 128 | **128** |
| `d_inner` (`ssm_inner_size`) | 2048 | **6144** |
| key_dim / value_dim | 2048 / 2048 | **2048 / 6144** |
| conv_dim | 6144 | **10240** |
| `wqkv` | 1024 -> 6144 | **5120 -> 10240** |
| `wqkv_gate` (z) | 1024 -> 2048 | **5120 -> 6144** |
| `ssm_out` | 2048 -> 1024 | **6144 -> 5120** |
| `ssm_beta` / `ssm_alpha` | 1024 -> 16 | **5120 -> 48** |

**Note `num_k_heads != num_v_heads` at 27B** (16 vs 48), which was not true at
0.8B. The reference handles this by repeating q and k 3x to match v
(`qwen35.cpp`: `ggml_repeat_4d` when `num_k_heads != num_v_heads`), so each key
head serves **3 value heads**. §2.1 and §2.4 must treat the k/q operands as
shared across a group of 3 heads rather than private to one. **This is the
single largest structural change from the 0.8B derivation** and it affects the
column pipeline's operand fetch, not its arithmetic.

### 4.1 State size, the dominant fact

```
per layer : head_v_dim^2 x num_v_heads = 128 x 128 x 48 = 786,432 elements
x 48 GDN layers                        = 37.75M elements
at int16                               = 75.5 MB
```

| | Total | Per card (2-way, sharded by value head) |
|---|---|---|
| Elements | 37.75M | 18.9M (24 of 48 heads) |
| int16 bytes | 75.5 MB | **37.75 MB** |
| Traffic per token (read + write) | 151 MB | **75.5 MB** |

Against a 7.57 GB per-card weight read, state traffic is **~1.0%** -- lower than
the 4.5% at 0.8B scale, because weights grew 36x while the state grew only 8x.

**37.75 MB per card does NOT fit the 14.2 MB of on-chip BRAM+URAM**, so the
§2.4 column pipeline's DDR/HBM streaming architecture is **required**, not
optional. At 0.8B residency was a possible optimization; at 27B it is off the
table, which retroactively validates designing for the streaming case.

### 4.2 Sharding

Value heads shard exactly: **48 / 2 = 24** per card at N=2, **48 / 8 = 6** at
N=8. Key heads: 16 / 2 = 8, 16 / 8 = 2. Both clean at both topologies.

**The recurrence needs no collective.** State is per-value-head and never
crosses heads, so each card runs its own heads to completion. Only `ssm_out` is
row-parallel and needs one all-reduce (subsystem A §14.2), and `wqkv`/`wqkv_gate`
are column-parallel needing none.

That makes B the **best-sharding subsystem in the design** -- the 3:1 k-to-v
head grouping of §4 stays entirely within a card provided the shard boundary
falls on a multiple of 3 value heads. **24 and 6 are both multiples of 3, so
both topologies are safe**; a shard count that broke that would split a key
head's group across cards and force a broadcast.
