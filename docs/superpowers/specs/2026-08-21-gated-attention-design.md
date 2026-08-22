# Subsystem C: Gated Attention

Design spec, 2026-08-21. Milestone `v2.1`. **Revision 6.**

**STATUS: sections 1-2 only. Section 3 (softmax datapath, gate, IMROPE,
validation, acceptance criteria) is deliberately unwritten** pending review of
this foundation, because section 3's arithmetic depends on every decision here.

## 0. Revision history

**Rev 6** incorporates a fifth adversarial review. Its finding was that rev 5
**recorded the lesson from CR4-2 and then repeated it one layer down**: the
structure check verified headings but not cross-section content consistency, so an
interface port contradicting the contract survived.

| Ref | Defect in rev 5 | Resolution |
|---|---|---|
| CR5-1 | **`v_ref : in integer` was still declared as an interface port.** Rev 4 added it when `v_ref` was a static descriptor value; rev 5 replaced that with a write-time min-fold and left the port standing, its comment still citing §2.1.4 as justification. §1.4 therefore said the PS supplies it while §2.1.4 said C computes it -- divergence in every PV bit. §2.1.4 also said "subsystem D resets it per sequence" through an entity with **no reset port**. | Port deleted; `kv_seq_rst` added, with an explicit comment that `v_ref` is folded internally and never supplied. |
| MJ5-1 | `score_q12 = round_shift(score, score_exp - 12)` is **undefined when `score_exp < 12`**, which is reachable since `q_norm_exp` is data-dependent and unbounded below. A negative right shift is C undefined behaviour, and `scale_mul`'s natural-typed shift count does not define it either. `score_q12` also had no pinned width. | §2.1.4 states both branches (site 4 and 4b), pins `score_q12` to **s32**, and the negative branch saturates. |
| MJ5-2 | **The min-fold init was unpinned.** The right-shift invariant and the 2^30 bound survive any init, so no structural check catches it -- but init = 0 right-shifts every V block by its full exponent and silently destroys cache precision. | Reset to **+127** (the int8 header maximum §2.1.5 guarantees `e_v` never exceeds), so the fold yields exactly `min over e_v`. Append-only equivalence condition stated. |
| MJ5-3 | The §2.7-2.9 renumbering swept the rev-4 history table but **not the rev-2/rev-3 tables**, and missed a live §1.5 reference pointing at §2.4 for the quantizer (now §2.1.3). | All fixed, and an **automated reference check** now runs after every edit pass (below). |
| minor | §2.6 still said "40-bit" twice after the 36-bit change; "PV MACs are 13 x 16" (`v_aligned` is int8, so 13 x 8); "three places" listed two; marshalling FF was asserted at ~12K rather than derived. | Corrected; marshalling derived at **8,192 FF** (`x_mant` + `w_mant`; `o_mant` is internal to the reused unit), so the total falls to **~45K FF**. |

**Process change.** Heading-level structure checking was not enough. Every edit
pass now also runs an automated sweep that extracts all section anchors, extracts
every `§N.M` reference, and reports any that do not resolve. That check found the
stale §1.5 pointer in this revision. It does not catch semantic contradictions
like CR5-1, which remain a manual read.

**Rev 5** incorporates a fourth adversarial review. Rev 4's two criticals were an
arithmetic inversion and a **copy-paste artifact**: the consolidation replaced
§2.1-§2.4 but the original GQA section sat past §2.5, outside the replaced range,
so the document carried two GQA sections and the stale one resurrected CR3-2
verbatim. Process lesson recorded: **verify document structure, not just text,
after every edit pass.**

| Ref | Defect in rev 4 | Resolution |
|---|---|---|
| CR4-1 | **The PV alignment formula was inverted.** `v_mant >> (v_ref - e_v)`; under `value = mant * 2^-e` the correct factor is `2^(v_ref - e_v)`, a *left* shift when `v_ref > e_v`. Three things in rev 4's own text contradicted it: a right-shifted int8 cannot reach `sat16`; the "derived" 2^38 bound needed left shifts; `e_v > v_ref` gave a negative shift count. | Fixed by MJ4-1's change: with a min-fold reference `e_v >= v_ref` always, so alignment is unconditionally a right shift, matching `attention_ml.vhd:874`. |
| CR4-2 | **A duplicate GQA section**, restating and contradicting §2.1 two sections after §2.1 declared restatement forbidden. | Deleted; §2.7-§2.9 renumbered to §2.6-§2.8. |
| MJ4-1 | The static `v_ref` was justified by a false claim that `attention_ml`'s min-fold "has no DDR analog". It does: **fold the min at write time** in ~12 registers. The static form also needed `sat16`, silently clamped the very V outliers per-32 exponents exist to preserve, and required an unprovable calibration guarantee. | §2.1.4: write-time min-fold. Removes saturation, calibration and §3's error-analysis deliverable. Bound falls from 2^38 to **2^30**, so accumulators drop 40 -> 36 bits. |
| MJ4-2 | "Q -> 2 BRAM36" under-feeds the array 4x: Q demand is `4 x 16 x 16 = 1,024 b/cycle` against a RAMB36E2 port's **72 bits** -- the same limit A hit. | §2.6: ~16 striped BRAM36. |
| MJ4-3 | The ~41K FF total omitted QK-norm marshalling, which §1.5 itself requires: `rmsnorm` re-reads its parallel N*16 ports in S_EMIT, so both must be held. | +12K FF; total ~49K. |
| MJ4-4 | Deleting the gate buffer was justified by "that memory must survive until C finishes regardless", which is untrue on its own. | §2.6 pins two normative requirements on subsystem D: the `wq` region is not written until C's `done`, and `y` is steered to a disjoint region. |
| minor | The score-to-softmax alignment rule was missing while §2.1 claimed to own every alignment decision; `>> 4` and "quantizer of §2.4" were stale §3 references; the rounding table implied exhaustiveness; header exponent range unpinned; "most positions" cross 4 KB (it is ~6%). | §2.1.4 adds `score_q12`; §2.1.5 scoped and extended; §2.2 corrected. |

**Rev 4** incorporates a third adversarial review, which found that rev 3's own
edits had introduced two criticals. The structural response was to **consolidate
every exponent, alignment and rounding rule into one normative section (§2.1)**,
because rev 3 carried them in three places and patched only one.

| Ref | Defect in rev 3 | Resolution |
|---|---|---|
| CR3-1 | **The per-32 format was declared but not delivered.** §2.4 scanned all 256 values for a single `amax`, producing 8 identical exponents -- per-vector behaviour under a per-block header. The stated justification (V outliers) was not achieved. §2.1 also still contained the verbatim rev-2 sentence saying the whole vector is one block. | §2.1.3: the quantizer is **per block**, 8 independent scans. The stale sentence is gone. |
| CR3-2 | **The Q-side exponent chain had the same defect just fixed on the K side.** `score_exp` used `qg_exp`, which is **pre-norm**; Q passes through QK-norm exactly as K does, so the correct term is the per-head `rmsnorm` output exponent with its own data-dependent `shift_total` -- 8 distinct values. Additionally `kn_exp` appeared in the normative formula but **existed nowhere in the interface**, and `Q` was never pinned. | §2.1.2 states all **three** chains together; `qn_exp`/`kn_exp` ports added; `Q = 12` pinned. |
| MJ3-2 | **No alignment policy existed** for either dot product, though §0 claimed otherwise, and §2.6's 2^38 bound silently depended on one. The claimed `attention_ml` precedent aligns per-position vector exponents, not 8 intra-vector block exponents. | §2.1.4: score aligns to `e_min` (right-shift, bounded); PV uses a per-layer static `v_ref` from the descriptor, which avoids a second rescale mechanism and makes the 2^38 bound **derived**. |
| MJ3-3 | The DSP figure was a floor: no auxiliary multipliers, and **no allowance for subsystems B or D** on the same 360-DSP part. | §2.8 adds an auxiliary row and states B's remaining headroom explicitly. |
| MJ3-4 | ~115K FF was labelled "mandatory". The 32,768 FF gate buffer is **not needed at all** -- the gate lives in A's activation memory, which C already reads and which must survive anyway. | §2.6: gate buffer deleted, Q and bypass demoted to BRAM. **~41K FF.** |
| minor | `272` does not divide `4096`, so per-position 17-beat bursts cross 4 KB boundaries, which AXI4 forbids. Flush-on-`start` without first draining outstanding transactions still corrupts the next job. `rope`'s exponent preservation assumes its int16 saturation never fires. | §2.2, §2.7, §2.1.2. |

A structural note carried forward: three revisions never broke the skeleton --
GQA grouping, online softmax, the layout and the reuse choices held every round.
What failed repeatedly was arithmetic asserted in one place and restated in
another. §2.1 exists to make that class of defect impossible.

**Rev 3** incorporates a second adversarial review. Rev 2's structural skeleton
held -- the C1 unit fix works, `sh = max(0, msb_pos - 6)` was verified as the
correct int8 analog of `bfp_pack`'s `-14` with no off-by-one, and every IMROPE
claim and sizing figure recomputed clean. One critical and five majors remained.

| Ref | Defect in rev 2 | Resolution |
|---|---|---|
| CR-1 | **The stored K exponent was wrong -- C1 reintroduced on the write side.** §2.4 said `src_exp = k_exp`, but K is stored *post-RoPE* and QK-norm comes first, and `rmsnorm.vhd:336` emits `o_exp = xe + we + Q - shift_total`, folding in the norm weight exponent, Q, and a **data-dependent** shift. Every K record would misstate its value by the whole norm delta, varying per token. | §2.4: the exponent chain is now normative and differs for K and V. `rope.vhd:7` confirms IMROPE preserves the exponent, so the chain terminates at the norm stage. |
| MA-1 | The 47%-efficiency row read ~5.3 ms; correct is **4.44 ms** (5.3 corresponds to ~40%, a figure in neither spec). That row exists to state timing honestly. | §2.5 corrected with both derivations, plus a note that A's efficiency premise was measured on *one* sequential stream and must be re-measured for C's two-reads-plus-write pattern. |
| MA-2 | One exponent per 256 elements coarsened rev 1's per-32 granularity with no precision analysis, and §3's "validate with q8_0-class KV" then described a different format than §2.1 defined. | §2.1: **per-32 exponents restored**, 8 int8 in the same 16-byte header, so the record stays 272 B and all sizing is unchanged. Matters because **V is raw** and outliers are the classic coarse-quantization failure. |
| MA-3 | The bypass closed the same-job race only; token T's write is read by token T+1 through a different master, with the same absent AXI ordering. | §2.8: `done` gated on BRESP. |
| MA-4 | The bypass value domain was unpinned (pre- or post-quantization), and the bypass/Q/gate registers were unbudgeted. | §2.6 pins the **quantized** copy; §2.6 tabulates all mandatory state at ~115K FF. |
| MA-5 | The 40-bit accumulator decision silently required 40x13 rescale products that **do not fit the 8x16 MAC array** §2.5's timing assumes. | §2.6: 128 dedicated rescale DSPs priced; §2.8 shows this drives DSP to 91% of the device. |
| minor | `kq_scale` applied as a mantissa shift, discarding 4 bits, when it is `2^-4` exactly and can be folded into the exponent for free. | §2.1.4: `score_exp += 4`. |
| minor | Accumulator bound assumed s16-aligned V without stating a dequant alignment policy; QK-norm timing assumed 3 cycles/element against `rmsnorm`'s 2; FIFO flush delegated to D inconsistently with A; quantizer input width unstated; `layer` index ambiguous; `MAXCTX` 4 KB alignment holds only for multiples of 256; **no resource budget existed at all**. | Addressed in §1.4, §2.4, §2.6, §2.7 and the new §2.8. |

**Rev 2** incorporates an adversarial review of rev 1. The review **confirmed all
four source-derived claims in §1.1** against `qwen35.cpp` (per-head gate
interleaving, `ggml_sigmoid`, QK-norm before RoPE, `kq_scale = 1/16`), so the
reference reading was sound. What was built on top of it was not.

| Ref | Defect in rev 1 | Resolution |
|---|---|---|
| C1 | **The KV record had no exponent.** A uint15 Q15 scale is a fraction, so the format encoded values of an *undefined unit*. K and V arrive from A as BFP whose `y_exp` varies per token (it depends on each vector's own amax via `ns`), so positions sat on incommensurable scales: the running maximum was meaningless and PV accumulation undefined. Rev 1 claimed to match `attention_ml.vhd`'s convention while dropping the **per-slot exponent** that makes that convention work. | §2.1 rewritten to **pure BFP**: int8 mantissas plus one integer exponent per head-vector. Simpler, smaller, and it eliminates a banned division. Write-side quantizer specified in §2.4. |
| C2 | A single `x_exp` port served qg, k and v, which are outputs of **three separate A jobs** with three independent `y_exp` values. The interface could not represent the data. | §1.4: `qg_exp`, `k_exp`, `v_exp`. |
| C3 | **The rope is IMROPE, not mRoPE.** `ggml.h:1857-1858` documents contiguous `[ttttyyxxttttyyxx00]` for MROPE against interleaved `[ttyxttyxttyxttyx00]` for IMROPE, dispatched by `sector % 3` (`ggml-cpu/ops.cpp:5898-5903`). Rev 1 named mRoPE three times. A contiguous-section implementation rotates the right dimensions against the **wrong position streams**. | §1.6 added, pinning the variant and what section 3 must still confirm. |
| C4 | **DDR read-after-write race.** C writes K/V[cur_pos] through the write master, then the sweep reads 0..cur_pos *including cur_pos* through a read master. AXI orders nothing between masters. `attention_ml` got write-before-read free inside one BRAM; the DDR move lost it silently. | §2.4: current position is **bypassed from on-chip registers and never re-read**. |
| M1 | **64 MACs were not feedable.** One 544 B record is 34 beats of a single 128-bit master, consumed in 32 compute cycles: a structural shortfall at perfect efficiency, before A's 47-70% DDR premise. | §2.2: **separate K and V regions with one read master each**, 17 beats per master per position. §2.5 restates timing honestly. |
| M2 | Rescale cost understated 4x (maxima are per *query* head, so up to 4 per position), and the **error compounding** of repeated `exp(m_old - m_new)` multiplications was not mentioned. | §3 constraint list corrected; error bound named as a section-3 deliverable. |
| M3 | "4 KB, one BRAM" for the accumulators was wrong on width (values reach ~2^38, so 32 bits wraps) and on ports (64 MACs/cycle is 64 read-modify-writes, against a BRAM36's two 72-bit ports). | §2.6: ~36-bit accumulators in registers, budgeted. |
| M4 | `MAXCTX` appeared in the layout and nowhere in the interface; `kv_base` plus `ctx_len` cannot derive the address map. | §1.4 generic + `k_base`/`v_base`. |
| M5 | 8,192-context row read 10.6%; correct value is **11.9%**. | §2.3 corrected. |
| M6 | The A/C seam had an **unowned strip**: steering A's output into the right activation memory, sequencing QK-norm, and the A->C->A->A order all belong to a transformer FSM that both specs declare out of scope, while §2.5 issued instructions to it. | §1.3 names **subsystem D** as its owner. |
| minor | Sigmoid via EXP_ROM + `divider_rs` costs ~3 ms/token, comparable to the entire attention sweep. | §3: dedicated sigmoid ROM. |
| minor | §1.5 proposed reciprocal-multiply, which `divider_rs.vhd:26-28` explicitly warns against. | §1.5: legitimate only if the C reference is *defined* as reciprocal-multiply with a pinned Q-format. |
| minor | Decode-only sweep never stated; prefill batching would silently violate it. | §1.2. |

## 1. Context and scope

Subsystem C implements the **6 full-attention layers** of Qwen3.5-0.8B (indices
3, 7, 11, 15, 19, 23 of 24). The other 18 are Gated DeltaNet and belong to
subsystem B. See `docs/fpga-hardware-recon.md` for the ladder and
`2026-08-20-int4-streaming-matvec-design.md` for subsystem A.

### 1.1 The flow, taken from the reference implementation

From `llama.cpp`'s `src/models/qwen35.cpp`
(`llama_model_qwen35::graph::build_layer_attn`). That file states its own order
at line 267:

```
// Order: joint QG projection, QG split, Q norm, KV projection, K norm, RoPE, attention
```

Four facts, all independently confirmed in review:

**(a) The gate is interleaved with Q per head, not split half/half**
(lines 273-276, 293-296). Both views stride `n_embd_head * 2`, gate at offset
`n_embd_head`, so `wq`'s 4096-wide output is
`[Q_h0(256), G_h0(256), Q_h1(256), G_h1(256), ...]`. **This determines the
packer's row ordering for `wq`**; a half/half assumption yields plausible garbage
rather than an obvious failure.

**(b) The gate activation is `ggml_sigmoid`** (line 327), applied to the
attention output at line 330, before `wo` at 333. The gate view reads
**pre-norm** `Qcur_full`. The same file's `build_norm_gated` uses **silu**, but
it is called only from `build_layer_attn_linear` -- the DeltaNet path. Two gates,
two activations.

**(c) QK-norm precedes RoPE** (Q-norm 279 before rope 303; K-norm 289-291 before
rope 309). RMSNorm over `head_dim = 256` per head, one shared weight per layer.

**(d) `kq_scale = 1/sqrt(256) = 1/16`** (line 320); `f_attention_scale` defaults
to 0 and is never set for this arch. A power of two, so a shift.

Note on provenance: only (a)-(d) and the layer flow come from `qwen35.cpp`.
`N_ROT`, `rope_theta` and the §1.3 dimensions come from **GGUF metadata**.

### 1.2 Decode-only

C computes attention for **one position per invocation**, sweeping
`p in 0..cur_pos`. This is equivalent to the reference's causal mask
(`build_attn`'s `kq_mask`) **only for single-token decode**. Prefill batching
would silently violate it. Batched prefill is out of scope; the PS teacher-forces
prompts one position at a time, as it does today.

### 1.3 Scope boundary

`wq`, `wk`, `wv` and `wo` are INT4 weight matvecs, so **subsystem A performs
them**. C never touches a weight matrix.

**In scope:** Q/gate split, QK-norm, IMROPE, the DDR KV cache (write, quantize
and read), scores, online softmax, PV accumulation, the sigmoid gate, and C's own
MAC array.

**Out of scope, and now with a named owner:** steering A's outputs into the
correct activation memory per job, sequencing the ~10 per-layer unit invocations,
enforcing the A -> C -> A -> A order, `attn_norm`/`attn_post_norm`, the residual,
and the FIFO-flush instruction of §2.7. All belong to **subsystem D, the
transformer sequencer**, which needs its own spec. Rev 1 left this strip unowned
while issuing instructions to it.

### 1.4 Dimensions and interface

| | Qwen3.5-0.8B |
|---|---|
| Attention layers | 6, at indices 3, 7, 11, 15, 19, 23 |
| n_head / n_head_kv / head_dim | 8 / 2 / 256 (GQA 4:1) |
| Q+gate width from `wq` | 4096, interleaved per head |
| K, V width | 512 each |
| `attn_q_norm`, `attn_k_norm` | [256], shared per layer |
| N_ROT / rope_theta | 64 of 256 dims / 1e7 |
| kq_scale | 1/16 |

`MAXLAYERS = 6` deliberately excludes the model's **MTP/NextN block**, which is
itself a full-attention layer (`qwen35.cpp:97-120`). Speculative decoding is out
of scope for `v2.1`.

```vhdl
entity attn_gated is
  generic(
    HEAD_DIM  : positive := 256;
    N_HEAD    : positive := 8;
    N_KVH     : positive := 2;
    N_ROT     : positive := 64;
    MACS      : positive := 64;
    KV_BLOCK  : positive := 32;     -- quantization granularity, see 2.1
    MAXLAYERS : positive := 6;
    MAXCTX    : positive := 2048    -- allocation constant, MUST be a multiple
                                    -- of 256 (see 2.2 alignment note)
  );
  port(
    clk, rst : in std_logic;
    start    : in std_logic;
    layer    : in integer;   -- ATTENTION ORDINAL 0..MAXLAYERS-1, not the model
                             -- layer index; subsystem D owns the 3,7,11,15,19,23
                             -- to 0..5 mapping
    cur_pos  : in integer;
    ctx_len  : in integer;                        -- runtime bound, <= MAXCTX
    k_base   : in std_logic_vector(31 downto 0);  -- K region, from PS
    v_base   : in std_logic_vector(31 downto 0);  -- V region, from PS
    -- inputs from subsystem A, THREE independent exponents
    qg_rbaddr : out ...; qg_rdata : in ...; qg_exp : in integer;
    k_rbaddr  : out ...; k_rdata  : in ...; k_exp  : in integer;
    v_rbaddr  : out ...; v_rdata  : in ...; v_exp  : in integer;
    -- per-layer norm weights
    qn_raddr, kn_raddr : out std_logic_vector(7 downto 0);
    qn_rdata, kn_rdata : in  std_logic_vector(15 downto 0);
    qn_exp,   kn_exp   : in  integer;   -- norm-weight exponents; REQUIRED by the
                                        -- 2.1.2 chains and absent in rev 3
    kv_seq_rst         : in  std_logic; -- per-SEQUENCE reset of the v_ref min-fold
                                        -- registers (2.1.4). Driven by D at the
                                        -- start of each sequence, NOT per token.
                                        -- There is deliberately no v_ref input:
                                        -- v_ref is folded internally at write
                                        -- time, not supplied by the PS.
    -- gated result to A's activation memory for wo
    y_we   : out std_logic;
    y_addr : out std_logic_vector(10 downto 0);
    y_data : out std_logic_vector(15 downto 0);
    y_exp  : out integer;
    done   : out std_logic;   -- one-cycle pulse
    err    : out std_logic;
    -- AXI4: TWO read masters (K, V) + one write master
    ...
  );
end entity;
```

The gate shares `qg_exp` with Q, since both are views of one `wq` output.

### 1.5 Reuse

| Reused | From | Caveat |
|---|---|---|
| RMSNorm for QK-norm | `rmsnorm.vhd`, N=256 | ports are N*16 parallel (4096 b); needs a marshalling buffer from the 512-bit striped read |
| EXP_ROM (257 entries, domain [-16,0] Q12) | `softmax.vhd` | the cone is a **3-state FSM**, ~1 exp per 3 cycles, not a pipeline; section 3 must schedule it |
| Reciprocal for `1/s` | `divider_rs.vhd` | see below |
| BFP quantize (amax -> msb_pos -> shift) | `bfp_pack.vhd` | now the KV write-side quantizer, §2.1.3 |
| `layer`-selected banked regions | `attention_ml.vhd` concept | moved BRAM -> DDR |

**The reciprocal-multiply caveat is normative.** `divider_rs.vhd:26-28` warns
that "a reciprocal-multiply would NOT preserve [the caller's rounding] and is
deliberately not used". One divide plus 256 multiplies per head is exactly that
pattern. It is used here anyway, because 256 real divides per head is ~3 ms/token,
but **only on condition that the C reference is defined as reciprocal-multiply
with the reciprocal's Q-format pinned** in section 3. Otherwise RTL and reference
diverge.

### 1.6 IMROPE, not mRoPE

`ggml.h:1857-1858` documents the distinction for `n_dims = 16`:

```
GGML_ROPE_TYPE_MROPE   --> [ttttyyxxttttyyxx00]   contiguous sections
GGML_ROPE_TYPE_IMROPE  --> [ttyxttyxttyxttyx00]   interleaved  (Qwen3-VL style)
```

with `sector % 3` dispatch at `ggml-cpu/ops.cpp:5898-5903` and a fourth position
stream `theta_e` for sectors falling through the boundary conditions.

**Section 3 must pin, against ggml source rather than inference:** the exact
`rope_sections` from the target GGUF (the 27B carries `[11, 11, 10, 0]`; the 0.8B
must be read, not assumed), the `sector % 3` mapping, how the t/h/w streams are
filled in text-only mode, and what fills `theta_e`. Getting this wrong rotates
correct dimensions against wrong position streams -- a per-dimension error that
is invisible structurally and very expensive to localize on silicon.

## 2. The KV cache

### 2.1 Numeric contract (NORMATIVE)

**This section is the single source of truth for every exponent, alignment and
rounding decision in subsystem C.** Sections 2.5 onward reference it and must not
restate it. Rev 3 carried the exponent rules in three separate sections
and a revision patched one copy, leaving the others wrong -- that is exactly how
CR3-2 happened, and subsystem A hit the same disease before consolidating into
its §7.4.

#### 2.1.1 Storage format

| | |
|---|---|
| Mantissas | int8, 256 per head-vector |
| Exponents | **one int8 per `KV_BLOCK = 32` elements**, so 8 per head-vector |
| Head-vector record | 8 B exponents + 8 B pad + 256 B mantissas = **272 bytes** |
| Cost | 8.5 bits/value |

Element `d` has value `mant[d] * 2^-e[d / KV_BLOCK]`.

Per-32 granularity matters because **K is post-RMSNorm and bounded, but V is
raw**: one V channel 2^4 above the rest would otherwise cost 4 of every other
channel's 7 mantissa bits. It is free -- 8 int8 exponents plus padding occupy the
same 16 bytes a single exponent did, so the record stays 272 B and every sizing
figure in §2.3 is unchanged. It also makes the format `q8_0`-class in granularity
and bits/value, differing only in using an exponent rather than an fp16 scale.

**K is stored post-RoPE, V raw.** V is never roped in the reference.

#### 2.1.2 Exponent chains

Three chains, all data-dependent, none derivable from the interface ports alone.
`Q = 12` throughout (the `rmsnorm` generic default).

```
rmsnorm.vhd:336 :  o_exp = xe + we + Q - shift_total     -- shift_total is DATA-DEPENDENT
rope.vhd:7      :  exponent PRESERVED (twiddle >>15 keeps mantissas at scale)

V  (no norm, no rope):
    v_norm_exp        = v_exp

K  (norm then rope, per KV head h):
    k_norm_exp[h]     = k_exp + kn_exp + Q - shift_total_k[h]

Q  (norm then rope, per query head qh):
    q_norm_exp[qh]    = qg_exp + qn_exp + Q - shift_total_q[qh]
```

**All three are per-invocation and data-dependent.** `rmsnorm` runs once per head,
so `shift_total` differs per head: 2 distinct values for K, 8 for Q. Taking any of
these from an interface port instead of from the norm stage misstates every
affected value by a per-token, per-head power of two.

Rev 3 fixed the K chain and **left the Q chain reading the pre-norm `qg_exp`** --
the identical defect on the read side. Both are now stated together, in one place,
which is the point of this section.

`rope.vhd`'s exponent preservation holds only while its int16 saturation
(lines 121-130) does not fire. A saturated K mantissa breaks the premise this
chain terminates on; §3 owns the check.

#### 2.1.3 Write-side quantizer, PER BLOCK

Runs in fabric, once per layer per token, for each of the 4 head-vectors written
(2 KV heads x {K, V}). Input width is **int16** (norm/rope output for K, A's
output for V).

**For each of the 8 blocks independently** -- rev 3 specified a single 256-wide
scan, which produced 8 identical exponents and delivered per-vector behaviour
under a per-block header:

1. Scan that block's 32 values for `amax`, held unsigned.
2. `msb_pos(amax)`, with **`msb_pos(0) = 0`** (matches `bfp_pack.msb_pos_u`).
3. `sh[b] = max(0, msb_pos - 6)` -- the int8 analog of `bfp_pack`'s `-14`.
4. `mant = sat8(round_shift(value, sh[b]))`, saturating to [-128, 127].
5. `e[b] = src_exp - sh[b]`, where `src_exp` is `k_norm_exp[h]` or `v_norm_exp`
   from §2.1.2 -- **never the raw interface port**.

No division anywhere.

#### 2.1.4 Alignment policy

Rev 3 omitted this entirely while §0 claimed it addressed. Both dot products span
multiple exponents and need a stated reference.

**Score dot: align to the minimum block exponent, right-shifting.** Under
`value = mant * 2^-e`, a smaller `e` means larger values, so `e_min` is the
reference with the most headroom and every other block shifts **right** -- LSB
loss, bounded, no overflow. Aligning to `e_max` would left-shift by an unbounded
inter-block spread.

```
partial[b] = sum over the 32 elements of block b of (q_mant * k_mant)
score      = sum over b of ( partial[b] >> (e_k[b] - e_min) )
score_exp  = q_norm_exp[qh] + e_min + 4        -- kq_scale = 2^-4, see below
```

Shifting the 8 partials rather than the 256 mantissas costs 8 shifts, not 256.
Bound: `partial[b] <= 32 * 127 * 32768 < 2^27`, so the 8-term sum is `< 2^30` and
fits s32.

**`kq_scale` is folded into the exponent, never applied as a mantissa shift.** It
is `2^-4` exactly, so `score_exp += 4` is lossless and free.

**PV: align to a write-time min-fold reference `v_ref[layer][kv_head]`.**

Rev 4 used a per-layer *static* reference from the descriptor, justified by the
claim that `attention_ml.vhd`'s `S_VREF` min-fold pre-pass (lines 693-714) "has
no DDR analog". **That claim was false**, and the static form was strictly worse:
its alignment formula was inverted (see below), it needed `sat16`, it silently
clamped exactly the V outliers per-32 exponents exist to preserve, and it required
an offline calibration guarantee against unseen activations.

The min folds **at write time**, at zero DDR cost:

```
on quantizing V for position p:  v_ref[layer][kvh] = min(v_ref[layer][kvh], e_v[b]) for all b
```

Roughly 12 int8 registers, **reset to +127 by `kv_seq_rst` at the start of each
sequence**. +127 is the int8 header maximum, which §2.1.5's range check
guarantees `e_v` never exceeds, so the fold yields exactly `min over e_v` and
reproduces `attention_ml`'s `S_VREF` semantics. **The init value must be pinned
because it is not neutral**: the right-shift invariant and the 2^30 bound survive
any init, but init = 0 would right-shift every V block by its full exponent and
silently destroy the cache's precision while passing every structural check.

Positions only append during decode, so by the time the sweep runs `v_ref`
already covers `0..cur_pos` and is constant for its duration. **The write-time
fold equals `attention_ml`'s read-time min only under append-only semantics**
(§1.2) with a per-sequence reset; any future cache truncation or rollback breaks
the equivalence silently and must revisit this.

**Because `v_ref` is a minimum, `e_v[b] >= v_ref` always, so alignment is
unconditionally a RIGHT shift:**

```
v_aligned[d] = v_mant[d] >> ( e_v[d / KV_BLOCK] - v_ref )
```

matching `attention_ml.vhd:874` (`sh_r <= vc_e_do - vref_s`) exactly. Rev 4 printed
`v_mant >> (v_ref - e_v)`, which is inverted: under `value = mant * 2^-e`, moving
to the `2^-v_ref` grid needs `mant * 2^(v_ref - e_v)`. Three things in rev 4's own
text contradicted it -- a right-shifted int8 can never reach `sat16`; the "derived"
2^38 bound needed left shifts; and `e_v > v_ref` gave a negative shift count.

**Accumulator bound, now genuinely derived.** Right-shift-only alignment means
`|v_aligned| <= 127 = 2^7`. With `e_p <= 2^12` (Q12) over `2^11` positions:

```
|o| <= 2^11 * 2^12 * 2^7 = 2^30
```

s32 suffices; **s36 is declared for margin**. Rev 4's 2^38 was an artifact of the
inverted formula assuming s16-scaled V.

**Scores: convert to Q12 fixed-point at the point of production.**
`score_exp` contains `e_min`, which varies per position, so raw scores from
different positions are not comparable and cannot feed a running maximum. Each
score is therefore converted immediately:

```
sh = score_exp - 12
score_q12 : s32 = (sh >= 0) ? round_shift(score, sh)          -- site 4
                            : sat32( score << (-sh) )         -- site 4b
```

**Both branches must be stated.** `score_exp = q_norm_exp[qh] + e_min + 4` and
`q_norm_exp` is data-dependent and unbounded below, so `sh < 0` is reachable. A
negative right shift is undefined behaviour in C, and `fixed_pkg.scale_mul`'s
`shift_left(to_signed(1,96), shift-1)` violates its natural-typed count at
`shift < 1`, so "match `scale_mul`" does not define it either. The left branch
saturates rather than wrapping.

`score_q12` is **s32**, which is ample: `|score| < 2^30` per the bound above, and
real attention logits are O(2^17) in Q12.

This makes all positions directly comparable **and** forms the EXP_ROM argument in
one step, since `softmax.vhd`'s table is Q12 over [-16, 0], with underflow-to-zero
already handled by that unit's `ex_uf`.

#### 2.1.5 Rounding sites

Scope: **new arithmetic introduced by C**. Rounding inside reused, bit-pinned
units -- `rmsnorm`'s internal `scale_mul` and rsqrt, IMROPE's `(+2^14) >> 15`
(`rope.vhd:113-119`), EXP_ROM interpolation -- is fixed by those units and is not
restated.

| # | Site | Mode |
|---|---|---|
| 1 | quantizer `round_shift(value, sh[b])`, then `sat8` | round half toward +infinity, matching `fixed_pkg.scale_mul` |
| 2 | score partial alignment `>> (e_k[b] - e_min)` | **floor**, arithmetic right shift |
| 3 | V alignment `>> (e_v[b] - v_ref)` | **floor**, arithmetic right shift. No saturation: right-shifting an int8 cannot overflow. |
| 4 | `score_q12`, `sh >= 0`: `round_shift(score, sh)` | round half toward +infinity |
| 4b | `score_q12`, `sh < 0`: `sat32(score << -sh)` | exact, saturating |
| 5 | softmax rescale multiply | §3 |
| 6 | final reciprocal-multiply and output renormalization | §3 |

Sites 1-4 are fixed here; 5-6 belong to section 3. `kq_scale` is deliberately
absent -- it is an exponent adjustment, not a rounding site.

**Header exponent range.** `e[b] = src_exp - sh[b]` is stored int8 while
`k_norm_exp`/`v_norm_exp` are unbounded integers. Out-of-range values raise `err`
and abort the job rather than wrapping silently.

### 2.2 DDR layout: separate K and V regions

Rev 1 stored K and V adjacently per position to serve online softmax in one
sweep. That forced 34 beats through a single master against a 32-cycle compute
budget. **Separate regions with one read master each** serve the same single
sweep -- the masters run in lockstep -- at 17 beats per master.

```
K_region[layer][kv_head][pos] = 272 B
V_region[layer][kv_head][pos] = 272 B

addr = base + ((layer * N_KVH + kv_head) * MAXCTX + pos) * 272
```

With `(layer, kv_head)` fixed and `pos` sweeping, records are contiguous, so each
region is one long sequential burst.

`MAXCTX` is an **allocation constant**; `ctx_len` is the runtime bound and must
satisfy `ctx_len <= MAXCTX`.

**`MAXCTX` must be a multiple of 256.** Each sub-region is `MAXCTX * 272` bytes
and 4 KB alignment requires `17 * MAXCTX / 256` integral, since `272 = 16 x 17`.
True at 2,048; silently false at most other values.

**Bursts are split at 4 KB boundaries, independent of record boundaries.**
`272` does not divide `4096`, so a per-position 17-beat burst crosses a 4 KB
boundary on **16 of every 256 records (~6%)** -- `lcm(272, 4096) = 69,632` -- which
AXI4 forbids. `k_base` and `v_base` must themselves be 4 KB aligned for the split
arithmetic to hold. The sweep issues long bursts over
the contiguous region and splits them at 4 KB, exactly as subsystem A does.

### 2.3 Sizing

Per position per layer: `N_KVH * (K 272 + V 272)` = 1,088 B; across 6 layers,
**6,528 B per position**.

| Context | Region total | Per-token read | % of 423 MB |
|---|---|---|---|
| 512 | 3.34 MB | 3.34 MB | 0.8% |
| **2,048** | **13.37 MB** | **13.37 MB** | **3.2%** |
| 8,192 | 53.48 MB | 53.48 MB | **12.6%** |
| 262,144 (native) | 1.711 GB | 1.711 GB | **404%** |

At native context KV traffic is nearly 4x the weight traffic and throughput
collapses to roughly 2 tok/s. The cost is linear in `ctx_len` and explicit.

### 2.4 GQA head-grouping and the current-position bypass

With 8 query heads over 2 KV heads, a naive loop reads `K[p][kvh]` once **per
query head** -- four redundant reads. Instead:

```
for kvh in 0..N_KVH-1:
  process p = cur_pos from the QUANTIZED on-chip bypass registers
  for p in 0..cur_pos-1:
    read K[p][kvh], V[p][kvh] from DDR      -- ONCE
    for qh in the 4 query heads sharing kvh:
      score, score_exp  per 2.1.4
      online-softmax update of m[qh], s[qh], o[qh] using v_aligned per 2.1.4
```

**4x reduction in KV read bandwidth**, the dominant traffic term; without it the
2048-context figure would be 53.5 MB rather than 13.4 MB.

**The bypass copy is the QUANTIZED record**, not the pre-quantization value. The
reference attends over the quantized cache including the current token, so
bypassing the int16 norm/rope output would differ in every low bit.

**The bypass is a correctness requirement, not an optimization.** C writes
K/V[cur_pos] through the write master and would otherwise read it back through a
read master in the same job; AXI orders nothing between masters. `attention_ml`
got write-before-read free inside one BRAM. Holding `cur_pos` in registers removes
the hazard and saves 544 B.

### 2.5 Compute and bandwidth

| Per position, per KV head | MACs |
|---|---|
| Scores, 4 query heads x 256 | 1,024 |
| PV, 4 accumulators x 256 | 1,024 |

At 2048 context: 4,096 per position per layer, 8.39M per layer, **50.3M per
token**, about 6.3% of the ~800M for weights. At `MACS = 64` and 200 MHz that is
786,432 cycles = **3.93 ms**.

**Port-limited timing, stated honestly.** Each master fetches 272 B = 17 beats
per position against a 32-cycle compute budget. That needs sustained port
efficiency of `17/32 = 53%`. Against A's own DDR premise of 47-70%:

| Port efficiency | Cycles/position/kvh | Attention time |
|---|---|---|
| >= 55% | 32 (compute-bound) | **3.93 ms** |
| 47% | 17/0.47 = 36.2 | **4.44 ms** |

At 47%: `24,576 position-kvh-layer units x 36.2 = 889K cycles / 200 MHz`.
Cross-check by bandwidth: `16 B x 200 MHz x 0.47 = 1.504 GB/s` per master, and
`6.69 MB / 1.504 GB/s = 4.45 ms`. **Rev 2 printed 5.3 ms here, which corresponds
to ~40% efficiency -- a figure appearing in neither spec.** This row exists to
state the timing honestly, so an unreproducible number in it defeats the purpose.

Rev 1's unqualified 3.9 ms assumed a single master delivering 34 beats in 32
cycles, which is impossible at any efficiency.

**The efficiency premise itself needs re-measuring for this access pattern.** A's
47-70% figure is for *one* long sequential stream; C runs **two concurrent read
streams plus a write stream**, a different bank and page pattern. A's bring-up
step 4 must be extended to cover it.

### 2.6 Accumulators

`o[qh][d] = sum over p of e_p * v_aligned_p`. Under §2.1.4's right-shift-only
alignment `|v_aligned| <= 2^7`, so with `e_p <= 2^12` over `2^11` positions the
bound is **2^30**. Rev 4 claimed 2^38, which followed from its inverted alignment
formula assuming s16-scaled V.

| | |
|---|---|
| Width | **36 bits** (bound 2^30 per §2.1.4, s32 would suffice; 4 bits margin) |
| Count | 4 query heads x 256 dims |
| Storage | **registers, 36,864 FF** of 141,120 |

Registers rather than BRAM: PV at 64 MACs/cycle is 64 read-modify-writes per
cycle (2,560 bits each way), against a BRAM36's two 72-bit ports. A BRAM
implementation needs ~36 banked tiles; registers have no port limit. Rev 1's
"4 KB, one BRAM" was wrong on both width and ports.

**Registers are not free.** 64 read-modify-writes per cycle into 1,024 x 40-bit
registers needs roughly **16:1 read muxes per MAC lane, about 10-13K LUT**
(1,024 x 36-bit).

**Rescale multipliers are time-shared with the MAC lanes, not added to them.**
§3 requires up to 1,024 rescale multiplies per position, each a 40-bit
accumulator times a Q12 factor -- a **36 x 13 product that does not fit one
DSP48E2** (36 > 27), so it needs 2. But score MACs are 8 x 16 and PV MACs are
13 x 8 (`v_aligned` is int8), both of which leave a second DSP **idle**. Widening each of the 64 lanes
to 2 DSPs and time-sharing them for rescale therefore costs **128 DSPs total**
rather than 64 MAC + 128 dedicated rescale = 192, with no throughput loss, since
rescale and MAC never run in the same cycle. Rev 3 priced the dedicated version.

**State, corrected. Rev 3 called 115K FF "mandatory"; most of it is not:**

| State | Rev 3 | Rev 5 | Why |
|---|---|---|---|
| PV accumulators, 4 x 256 x 36 b | 40,960 FF | **36,864 FF** | genuinely needs registers (64 RMW/cycle); width now derived |
| Normed/roped Q, 8 x 256 x 16 b | 32,768 FF | **16 BRAM36, striped** | see feed rate below |
| QK-norm marshalling (`rmsnorm` x/w ports) | not counted | **8,192 FF** | `x_mant` + `w_mant`, 2 x 256 x 16 b, held because `rmsnorm` re-reads its parallel ports in S_EMIT. `o_mant` is internal to the reused unit and needs no external copy. |
| Bypass records, 4 x 272 B | 8,704 FF | **1 BRAM36** | one position per job, sequential |
| Gate values, 8 x 256 x 16 b | 32,768 FF | **0** | **deleted** -- see below |
| **Total** | **~115K FF** | **~45K FF + 17 BRAM36** | |

**Q cannot live in 2 BRAM36.** The DDR K feed is 128 b/cycle (16 int8 mantissas),
so the 64 MACs organize as 4 query heads x 16 dims per cycle, making Q demand
`4 x 16 x 16 = 1,024 b/cycle`. A RAMB36E2 read port tops out at **72 bits**, the
same limit subsystem A hit. Q therefore needs **~16 striped BRAM36**, exactly as
`act_mem_striped` is built. Rev 4 budgeted 2.

**The gate buffer was never needed.** The gate is the second half of each head's
`wq` output, already in A's activation memory, which C reads through
`qg_rbaddr`/`qg_rdata`. It is consumed sequentially at the output stage, so
re-reading it costs nothing and removes 32,768 FF.

**This imposes two normative requirements on subsystem D**, without which the
deletion is unsafe. Rev 4 asserted the memory "must survive until C finishes
regardless", which is not true on its own: absent the re-read, the `wq` output is
dead after C's initial Q read, early in the job.

1. **The `wq` output region must not be written by anyone until C asserts
   `done`** -- not by a subsequent A job, not by D.
2. **C's `y` output must be steered to a region disjoint from the `wq` output.**
   `y` is 2,048 entries; the interleaved Q/G buffer is 4,096. Nothing otherwise
   prevents `y` overwriting unread gate words.

### 2.7 AXI arbitration with subsystem A

A and C are **never active simultaneously**: within a layer the order is A
(`wq`,`wk`,`wv`) -> C -> A (`wo`) -> A (FFN). A top-level arbiter grants DDR to
whichever unit is running, with no bandwidth splitting and no starvation case.
That order is enforced by **subsystem D** (§1.3), not by C.

C needs two read masters and one write master; the write master is nearly idle at
~1 KB per layer per token.

`k_base` and `v_base` come from the PS in the descriptor. C never parses a
header, for the same reason A does not.

**C flushes its own read FIFOs on `start`**, internally. Rev 2 delegated this to
subsystem D, which is an inconsistent seam: subsystem A flushes its own FIFOs
(A §7.7) and there is no reason C should differ.

**Flushing alone is insufficient: outstanding transactions must be drained
first.** R beats from ARs issued near the end of the previous job land *after* a
naive flush and corrupt the next one. The sequence is: stop issuing ARs, count
RLASTs until outstanding reaches zero, then flush. This is latent in A §7.7 too
and should be fixed there.

**`done` must not assert until every outstanding write has completed (BRESP
received).** The §2.6 bypass closes the read-after-write race *within* a job, but
token T's write of K/V[cur_pos] for layer L is read by **token T+1's** job for the
same layer, through a different master, and "AXI provides no ordering between
masters" applies there identically. The window is milliseconds today, so this
would pass every test and fail only under a future pipelining change -- the same
silent class as the original C4.

### 2.8 Resource budget

| Resource | C (rev 5) | A (`ROWS_IF=4`) | Total | Device |
|---|---|---|---|---|
| DSP48E2, MAC + rescale (time-shared) | **128** | 136 | 264 | 360 |
| DSP48E2, auxiliary (est.) | **+15-40** | - | ~280-305 | |
| LUT | ~13K muxes + ~10K shifters/quantizer/control | ~6.1K | **~29K** | 70,560 |
| FF | **~49K** | not budgeted in A | **~49K+** | 141,120 |
| BRAM36 | **~26** (Q 16, FIFOs, norm weights, bypass) | ~22 | **~48** | 216 |

Changes from rev 4: accumulators 40 -> 36 bits on the corrected §2.1.4 bound
(-4,096 FF); QK-norm marshalling added (+12K FF); Q moved from 2 to 16 BRAM36 on
the 72-bit port limit.

**The auxiliary DSP row is an estimate and matters**: QK-norm `rmsnorm`, IMROPE's
4 multiplies per pair, EXP_ROM interpolation, the §3 sigmoid ROM, and the
reciprocal-multiply output stage. None are counted precisely.

**A has no FF budget at all** (A §7.9 has no FF row), so the total FF figure is a
floor, not a sum.

**Subsystems B and D are not in this table and must fit the same device.** B is 18
of 24 layers and is named the project's largest architectural risk. At ~280-305 of
360 DSP for A+C alone, **B has at most ~55-80 DSPs**. That is a whole-project
constraint and belongs in `docs/fpga-hardware-recon.md`, not discovered when B is
specced.

**High utilization on this device is historically non-deterministic** --
`rmsnorm.vhd:296`, `bfp_pack.vhd`'s header and the `attention_ml` debug history all
document congestion-induced silicon behaviour at lower utilization than this. If
the auxiliary estimate lands high, `MACS = 32` halves C's MAC+rescale to 64 DSPs
and halves the Q feed rate (8 striped BRAM36 instead of 16), at roughly double the
attention time (~7.9 ms, about +8% of the token budget). **Section 3 must produce
real numbers before `MACS` is fixed.**

## 3. Softmax datapath, gate, IMROPE, validation

**NOT YET WRITTEN**, pending review of sections 1-2.

Constraints it must satisfy, recorded so review can flag anything sections 1-2
have already made impossible:

- **Online single-pass softmax.** Rescaling the 256-wide accumulator when the
  running maximum rises costs **1,024 multiplies per position worst case** (the
  maxima are per *query* head, so up to 4 of the 4 heads in a group rescale
  together) -- 4x rev 1's stated figure.
- **A rescale error bound is required, not just a throughput bound.** Each
  rescale multiplies the accumulator by `exp(m_old - m_new)` carrying EXP_ROM's
  interpolation error (~5e-4 relative), and up to `cur_pos` such factors compound
  multiplicatively on top of progressive LSB loss. This is the harder half of the
  problem and must appear in section 3's numeric contract.
- **IMROPE** per §1.6, pinned against ggml source.
- **A dedicated sigmoid ROM.** Sigmoid at width 2048 per layer via EXP_ROM plus
  `divider_rs` would cost ~0.5 ms per layer, about **3 ms per token** --
  comparable to the entire attention sweep.
- **Rounding sites 5-6 of §2.1.5**: the softmax rescale multiply, the
  reciprocal-multiply of §1.5, and the final output renormalization to a single
  `y_exp` across all 8 heads. Sites 1-4 are already fixed in §2.1.5, and
  `kq_scale` is an exponent adjustment, not a rounding site.
- **A consolidated `err` table**: range checks on `ctx_len <= MAXCTX`,
  `cur_pos < ctx_len`, `layer < MAXLAYERS`.
- Bit-exact C reference, validated against the reference implementation with KV
  quantized to the **§2.1 format** (int8 mantissas, per-32 exponents), which is
  `q8_0`-class in granularity and bits/value but uses an exponent rather than an
  fp16 scale.
- The three `v1.0-silicon` rules: at most one multiply per state; never route
  data through a VHDL `integer`; constrain at the real clock.

**Latency accounting is incomplete.** §2.5's 3.93 ms counts only the KV sweep.
QK-norm (**~0.39 ms**: `rmsnorm.vhd` is ~5 cycles/element -- S_ACC 256 +
S_RAW/S_RAW_B 512 + S_EMIT/S_EMIT_B 512 = ~1,290 cycles per 256-vector, 10 invocations per layer x 6 layers = ~77K cycles), IMROPE, rescales,
per-head reciprocals and the gate are all outside it. Section 3 must produce a full per-token budget before the ~20 tok/s
figure in `docs/fpga-hardware-recon.md` can be trusted for `v3.0`.
