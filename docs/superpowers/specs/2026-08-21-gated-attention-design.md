# Subsystem C: Gated Attention

Design spec, 2026-08-21. Milestone `v2.1`. **Revision 7.**

**STATUS: sections 1-3 written. Section 3 (added in rev 7, 2026-08-25) has NOT
yet survived an adversarial review**; sections 1-2 have survived five. Treat
§3's contracts as first-revision material with D rev 1's warning attached.

## 0. Revision history

**Rev 7 (2026-08-25)** writes section 3 against the settled §1-2 foundation:
the softmax datapath and schedule, the rescale error bound owed since rev 2
(M2), the reciprocal Q-format §1.5 conditions on, IMROPE pinned against ggml
source and the target GGUF (closing §1.6's list), the sigmoid ROM owed since
rev 2, the QK-norm synthesis §2.8 gated `MACS` on, validation and acceptance
criteria. New measurements: `rmsnorm` at N=256 as shipped is **78 DSP at
138.4 MHz** (disqualifying, §3.6); a width-narrowed skeleton is 18 DSP; the
sigmoid cone is 8 DSP; `rope.vhd`'s kernel is 8 DSP at 206 MHz. The §2.8
auxiliary DSP row lands at **50, above its 15-40 estimate** (§3.8). No §1-2
text is modified; §3.0 lists the §2 figures the FK33 geometry supersedes.

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
| EXP_ROM (257 entries, domain [-16,0] Q12) | `softmax.vhd` | the cone is a **3-state FSM**, ~1 exp per 3 cycles, not a pipeline; **MEASURED 2026-08-24: pipelining it to 1/cycle costs ONE LUT** -- see below |
| Reciprocal for `1/s` | `divider_rs.vhd` | see below |
| BFP quantize (amax -> msb_pos -> shift) | `bfp_pack.vhd` | now the KV write-side quantizer, §2.1.3 |
| `layer`-selected banked regions | `attention_ml.vhd` concept | moved BRAM -> DDR |

> **MEASURED 2026-08-24: the exp cone is the binding constraint at 27B, and the
> fix is free.** A position needs 6 exps (one per query head in the GQA group),
> so 18 cycles at 3 cycles each, against 16 cycles of MAC work at `MACS=192`.
> Because 18 is fixed, it caps C **independently of lane count**: `MACS=384` at
> 768 DSP delivers exactly what `MACS=192` delivers at 384 DSP, 3.93 ms either
> way. Any sizing argument that ignores it is choosing between identical
> outcomes.
>
> The three stages already register between states, so a true pipeline needs one
> register per stage **boundary**, not per in-flight element -- the staged FSM
> was already paying for the storage and not using it. Measured on
> `xcvu33p-fsvh2104-2L-e` at 3.333 ns with the arithmetic copied verbatim
> (`sim/micro/micro_exp_cone.vhd`, both forms behind a `PIPELINED` generic):
>
> | | DSP | LUT | FF | CARRY8 | Fmax |
> |---|---|---|---|---|---|
> | staged, as built | 8 | 629 | 138 | 45 | 343.4 MHz |
> | pipelined | 8 | **630** | 138 | 45 | 343.4 MHz |
>
> Simulation, both driven identically with 24 back-to-back inputs: pipelined
> returns **24**, staged returns **8**, values agreeing on all 8 once aligned.
> Utilisation alone was NOT treated as proof -- identical numbers are equally
> consistent with the two generate branches collapsing into one netlist.
>
> With the cone fixed, `MACS=192` reaches 3.49 ms and `MACS=384` 1.75 ms, so the
> two become genuinely different design points. Integration into `softmax.vhd`
> must still preserve `conv_q`, the `e_arr` store and the sum accumulation,
> which the micro-benchmark drops; the sum accumulator stays sequential.
> Procedure and traps: `docs/debugging/2026-08-24_vccint-derate-and-exp-cone.md`.

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

> **ANSWERED in §3.10, verified against source and against the GGUF itself on
> 2026-08-25.** All four items are pinned there with file:line citations. Two
> results change what §1-2 assumed, so they are flagged here as well:
>
> - **`theta_e` is unreachable for this model.** With `[11, 11, 10, 0]` the 32
>   sectors enumerate to exactly 11 t + 11 h + 10 w and nothing falls through
>   the boundary conditions. The sentence above ("a fourth position stream
>   `theta_e` for sectors falling through") describes the general IMROPE case,
>   not this one. In text mode `p_t = p_h = p_w = pos`, so all three live
>   streams carry the same angle and **text-mode IMROPE here is arithmetically
>   identical to plain NEOX RoPE over the first 64 dims**. The hardware builds
>   the collapsed form; the C reference keeps the full dispatch so the
>   divergence surfaces there if multimodal input ever enters scope.
> - **Pairing is NEOX `(x[j], x[j+32])`, not adjacent.** The diagram above is
>   about **sector interleaving**, not element adjacency, and reading it as
>   adjacency is the natural mistake. `rope.vhd`'s adjacent-pair indexing must
>   be re-indexed.
>
> The `[ttyx...]` quotation is `ggml.h`'s illustration for `n_dims = 16` and is
> reproduced correctly; it just does not depict this model's section vector.

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

> **MEASURED 2026-08-23, and this estimate is incomplete.** A single-lane OOC
> synthesis on the real part (`xcvu33p-fsvh2104-2L-e`, 300 MHz target) gives
>
> ```
> per lane:   LUT = 158 + 10.0 x ACC_N       FF = 182 + 36.4 x ACC_N
> ```
>
> where `ACC_N` is the lane's share of the file. The 36.4 is `ACC_W = 36` -- one
> FF per accumulator bit -- so the **36,864 FF above is exact**. The LUT figure
> is not wrong so much as partial: 10-13K matches the *fixed* file term (10,240)
> and omits a **per-lane** term of 158 LUT that this paragraph never counted,
> because it prices the read mux and stops before the write side, where every
> entry needs its own input mux. The two terms scale differently and must not be
> collapsed, since the file is a fixed 1,024 entries at any `MACS`:
>
> | `MACS` | `ACC_N` | LUT | FF |
> |---|---|---|---|
> | 64 | 16 | 20,352 | 48,960 |
> | 192 | 6 | 40,576 | 71,808 |
> | 288 | 4 | 55,744 | 89,280 |
>
> **Do not put more than 16 accumulators behind one lane.** The fit is linear to
> `ACC_N = 16` and breaks above it (32 measures 543 against a predicted 478):
> the 32:1 read mux exhausts the F7/F8 chain and needs a third fabric level.
>
> **And write the read-modify-write with ONE shared adder.** The obvious form,
> `for i loop if idx = i then acc(i) <= acc(i) + prod; end if; end loop`, builds
> a 36-bit adder **per entry** -- Vivado will not share them, since only one
> branch is ever live but proving the enables one-hot is not something synthesis
> attempts. Measured 1110 LUT and 80 CARRY8 per lane against 318 and 5 for
> identical arithmetic: **792 wasted LUT per lane, 152-228K at 192-288 lanes,
> 35-52% of the device.** Procedure and evidence:
> `docs/debugging/2026-08-23_bc-lane-micro-synthesis.md`.

**Rescale multipliers are time-shared with the MAC lanes, not added to them.**
§3 requires up to 1,024 rescale multiplies per position, each a 40-bit
accumulator times a Q12 factor -- a **36 x 13 product that does not fit one
DSP48E2** (36 > 27), so it needs 2. But score MACs are 8 x 16 and PV MACs are
13 x 8 (`v_aligned` is int8), both of which leave a second DSP **idle**. Widening each of the 64 lanes
to 2 DSPs and time-sharing them for rescale therefore costs **128 DSPs total**
rather than 64 MAC + 128 dedicated rescale = 192, with no throughput loss, since
rescale and MAC never run in the same cycle. Rev 3 priced the dedicated version.

> **MEASURED 2026-08-23: confirmed, 2 DSP48E2 per lane.** OOC synthesis of one
> lane -- a single multiply expression with operands muxed between the three
> modes, the mode driven by a free-running counter so synthesis cannot tell
> which is live -- yields DSP=2, with an independent DSP48E2 census agreeing and
> `USE_MULT=MULTIPLY` on both (neither is a DSP recruited as a wide adder). At
> `MACS = 64` that is **exactly** the 128 DSP §2.8 derives. The measurement
> matters because the alternative was 3 DSP/lane, a 128-288 DSP error on a
> 2,880-DSP device depending on the final `MACS`.
>
> Caveat on timing: the lane closes at **328.6 MHz** in isolation, but that is a
> single lane with no fanout. `k`, `v_aligned` and the rescale factor broadcast
> to all lanes, and that net -- not the lane arithmetic -- is what will set the
> real Fmax. Subsystem A managed 276 MHz on this same part and grade.

> **MEASURED 2026-08-24, placed and routed, 64 lanes: C makes 300 MHz -- but
> only if the lane uses the DSP48E2's own input registers.**
>
> | `MACS`=64, routed | DSP | LUT | FF | Fmax |
> |---|---|---|---|---|
> | operand muxes combinational | 128 | 20,860 | 46,684 | **246 MHz** |
> | operand muxes registered | 128 | **19,844** | 48,819 | **340 MHz** |
>
> **This is a normative RTL requirement, not an optimisation.** As first written
> the lane drove the multiplier from combinational muxes and registered only the
> product, leaving `AREG=0, BREG=0` -- the DSP tile's input registers idle. The
> routed critical path was then accumulator -> 16:1 read mux -> 3:1 operand mux
> -> DSP A port, 2.4 ns of logic, and C missed its own 300 MHz assumption by 18%.
> Registering the operand muxes puts them in `AREG`/`BREG`, which exist in the
> tile whether used or not, so the stage is free: same 128 DSP, 5% **fewer** LUT,
> +4.6% FF (that rise is the control pipeline needed to keep the write-back
> aligned, not the operands). Cost is one cycle of latency, which §3's schedule
> must absorb.
>
> The fanout question that motivated the run is answered too, and the answer is
> that it was the *second* effect, not the first. Baseline logic delay is flat at
> 2.38-2.45 ns from 1 lane to 64 -- mux depth, independent of fanout -- while net
> delay grows 0.66 -> 1.76 ns. Mux depth caps C at ~313 MHz with no fanout at
> all; broadcast then takes a further 21% by 64 lanes.
>
> **Do not extrapolate 340 MHz to `MACS` = 192 or 288.** Only 64 was measured,
> and `f` fans out as `LANES/4`, so it grows with `MACS`. At 64 lanes the limiter
> has already moved again, to the DSP-to-DSP cascade the 36-bit operand split
> requires; `MREG` is still unused and would break that path.
>
> Procedure, the routed control that separates PnR realism from fanout, and the
> traps: `docs/debugging/2026-08-24_c-array-broadcast-fmax.md`.

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

Written 2026-08-25 (rev 7) at the **27B / FK33 geometry of §4**, which is the
build target; 0.8B counts appear only where a contrast is instructive. All
schedules are stated in cycles; times are given at both **300 MHz (0.85 V
analysis)** and **231 MHz (0.717 V as the card runs, the measured -22.9% mean
derate of `docs/debugging/2026-08-24_vccint-derate-and-exp-cone.md`)**.
Numeric rules here extend §2.1 (sites 5-6 and the new arithmetic §3 owns);
§2.1's sites 1-4 are referenced, never restated.

### 3.0 `MACS` fixed at 192, and the §2 figures the FK33 geometry supersedes

**`MACS = 192`, organized as 6 query heads x 32 dims per cycle. NORMATIVE.**
The sizing rule: `MACS = qh_tile x dim_tile`, where `dim_tile` is set by the
K feed and `qh_tile` must divide the GQA group of 6 (§4.1). The FK33 HBM AXI
port is 256 bits (A §6.5's invariant at `AXI_DW = 256`, D §2.2-J), so one
beat delivers **32 int8 mantissas = exactly one `KV_BLOCK`**: `dim_tile = 32`,
and a MAC cycle spans exactly one exponent block of §2.1.4, with the §2.1.1
header-first layout delivering all 8 block exponents before any mantissa.
`qh_tile = 6` (the whole group).

Rejected alternatives, priced:

- **`MACS = 384`** (`dim_tile = 64`): needs a 512-bit K feed (two ports per
  stream) and 768 MAC+rescale DSPs; whole-die DSP goes to ~2,900+ of 2,880 --
  **does not fit the device** (§3.8). The 1.75 ms sweep it buys is moot.
- **`MACS = 96`** (`qh_tile = 3`): 32 cycles/position, sweep 6.98 ms at
  300 MHz. This replaces §2.8's `MACS = 32` congestion fallback (which was
  0.8B-shaped); it remains the fallback if routing binds.

Figures in §2 that this geometry supersedes (they were written against the
AXU3EG's 128-bit DDR masters and the 0.8B head counts; the *decisions* they
justify stand, per §4's "only the numbers change"):

| Stale figure | Where | Superseded by |
|---|---|---|
| "17 beats per master per position", 128-bit masters | §2.2, §2.5 | 272 B = **8.5 beats of 256 bits**; two positions per 17 beats. Odd-numbered records start 16 B into a beat; the stream unpacker carries a 16-byte-granularity realignment mux (~256 LUT/stream). Port duty is 8.5 beats per 16-cycle position = **53%**, unchanged. |
| "The DDR K feed is 128 b/cycle (16 int8)", "4 query heads x 16 dims" | §2.6 | 256 b/cycle, 6 heads x 32 dims. |
| Q in "~16 striped BRAM36" | §2.6, §2.8 | §3.1: Q group planes in **registers** (the §2.6 FF-scarcity premise was the AXU3EG's 141K FF; the VU33P has 879K, and registers dodge the 72-bit port ceiling §2.6 fought). BRAM fallback retained. |
| `MACS = 64`, 3.93 ms sweep | §2.5, §2.6 | §3.1/§3.7: `MACS = 192`, sweep 3.50 ms at 300 MHz with the pipelined exp cone. |

### 3.1 Array geometry and the position schedule

**Lane organization.** 192 lanes = 6 query heads x 32 dims. Each lane is the
measured 2-DSP time-shared lane of §2.6 with **registered operand muxes into
`AREG`/`BREG` (normative per the §2.6 MEASURED 2026-08-24 block)**, now with
the same **three** operand modes (score MAC, q s16 x k s8; PV MAC, e u13 x
v s8; rescale, acc s36 x f u13). The reciprocal-multiply is deliberately NOT
a fourth lane mode -- it runs in the output pipeline (§3.5), precisely so
the lanes and accumulators are free for the next group's sweep. Per-head 32:1 adder trees (fabric, per the A
adder-tree lesson in `2026-08-24_adder-tree-reclaim.md`) reduce score
partials; PV products accumulate into the per-lane accumulator files
(`ACC_N = 1536/192 = 8` per lane, inside the measured <= 16 limit, one shared
adder per lane per the §2.6 MEASURED 2026-08-23 block).

**Accumulator and state widths** (27B group): `m_g[qh]` s32 (grid-snapped
running max, §3.2); `s[qh]` **u26** (bound `s <= 2^23`: `e <= 2^12` per
§2.1.5's EXP_ROM range over `cur_pos+1 <= 2^11` positions at `MAXCTX = 2048`;
width is `13 + clog2(MAXCTX)` + margin, and grows with `MAXCTX`);
`o[qh][d]` s36 per §2.6.

**Q storage: two register planes, one per KV head.** Each plane holds its
group's normed/roped Q: 6 x 256 x 16 b = 24,576 FF; 49,152 FF for both. The
sweep reads a plane as 8 blocks cycling `b = 0..7`, an 8:1 x 16 b mux per
lane (~2K LUT total). Two planes exist so group 1's QK-norms can run under
group 0's sweep (§3.6). Fallback if FF or congestion binds: 43 striped
RAMB36 (3,072 b/cycle against 72-bit ports), the §2.6 mechanism at this width.

**The position slot.** Steady state is **16 cycles per (position, KV head)**:

```
cycles 0-7 : score(p)   -- 8 beats of K, one exponent block per cycle;
                           partial[b] through the tree, aligned to e_min
                           (site 2) and accumulated. e_min for position p is
                           computed from the header, which lands before the
                           mantissas (header-first, 2.1.1).
cycles 8-15: PV(p-2)    -- 8 beats of V, v_aligned per site 3, e-weighted
                           into o[qh][.]. The V master runs two positions
                           behind the K master.
```

**PV trails score by TWO positions.** The 6 scores of position p complete
together at its slot end (parallel trees); the shared exp cone then needs
6 conversions + 3 stages of latency = 9 cycles, which does not fit the 8
cycles a one-position lag would allow. Two positions of lag give a 16-cycle
window for 9 cycles of cone work with margin for the site-4 conversion and
max compare. Cost: 6 x s32 score staging registers per in-flight position
and two extra drain slots per (group, layer) -- noise. The one-cycle
`AREG`/`BREG` operand latency (§2.6) is absorbed the same way: it is
pipeline fill, not throughput.

**Processing order is part of the numeric contract.** Online softmax results
depend on order. Pinned: **`[cur_pos, 0, 1, ..., cur_pos-1]`** -- the §2.4
bypass position first (from the quantized bypass registers), then the DDR
sweep in ascending position. The C reference implements the identical order.
The first processed position initializes `m_g` (site 5a), `s`, and `o` by
overwrite (`ns_first`-style, no clear pass -- the `attention_ml` pattern).
Processing the newest position first also tends to set a high initial max,
which empirically suppresses later rescales; that is a bonus, not a
guarantee (§3.3).

**Rescale stalls.** When any of the group's 6 maxima rises at position p
(detected at p's site-4 conversion, one slot before PV(p) at the two-slot
lag), one **8-cycle rescale pass** is inserted before PV(p): all 192 lanes
in rescale mode sweep the 1,536 accumulators (8 cycles at `ACC_N = 8`).
Heads whose max did not rise use factor `f = 4096` (`k = 0`), which site 5d
makes an exact identity -- so the pass is uniform across heads and needs no
per-head masking. The six `s[qh]` rescales ride the same pass on one
dedicated 26x13 multiplier. Worst case one stall per position (+50% sweep
time); expected ~8 per (head, sweep) (§3.3).

### 3.2 Online softmax numeric contract (NORMATIVE; completes §2.1.5 sites 5-6)

Scores arrive as `score_q12` per §2.1.4 sites 4/4b. Everything below is new
arithmetic owned by this section. Modes: "half+inf" = round half toward
+infinity, matching sites 1 and 4; "floor" = arithmetic right shift,
matching sites 2 and 3.

**Site 5a -- grid-snapped running maximum (exact, no rounding).** The
reference maximum is kept on the EXP_ROM index grid (256 Q12 counts = 1/16):

```
m_g' = ((max(m_g, score_q12) + 255) asr 8) sll 8        -- s32, exact
```

Snapping UP multiplies every weight in the group by the same
`exp(m - m_g) in (0.939, 1]`, which cancels identically in `o/s`; its only
effects are a <= 6.2% loss of `s` headroom (covered by the §3.1 width) and a
1/16 shift of the underflow threshold. What it buys is site 5c.

**Site 5b -- per-position weight.** `z = score_q12 - m_g <= 0`;
`e_p : u13 = ` the EXP_ROM cone of `softmax.vhd` S_EXP_A/B/C **verbatim**
(interpolation, underflow-to-zero below `-2^16`, clamps), in the pipelined
form measured in §1.5 -- fixed by the reused arithmetic per §2.1.5's scope
rule, not restated. `e_p <= 4096`.

**Site 5c -- rescale factor, table-exact by construction.** On a max rise,
`k = (m_g_new - m_g_old) asr 8` is an exact positive integer, so the EXP_ROM
argument lands exactly on entry `256 - k`: **no interpolation, no multiply,
zero interpolation error**:

```
f : u13 = 0                                   when k > 256
        = round_shift(EXP_ROM(256 - k), 18)   otherwise   -- half+inf, the
                                              -- cone's own S_EXP_C step
```

`f <= EXP_ROM(255) >> 18 = 3848` for `k >= 1`; `f = 4096` at `k = 0` (the
§3.1 identity). This is why site 5a exists: an un-snapped max makes every
rescale factor an interpolated lookup carrying ~4.9e-4 relative error INTO A
COMPOUNDING PRODUCT (§3.3), and puts an extra multiply in the stall path.

**Site 5d -- the rescale multiply.**

```
o'[d] = round_shift(o[d] * f, 12)     -- half+inf, per element, 36x13 on the
                                      -- lane's second DSP (2.6)
s'    = round_shift(s * f, 12)        -- half+inf, dedicated 26x13 multiplier
```

At `f = 4096` both are exact identities. Accumulation itself
(`o += e_p * v_aligned`, `s += e_p`) is exact integer arithmetic inside the
§2.1.4 bound `|o| <= 2^23 * 2^7 = 2^30`.

**Site 6a -- the reciprocal, Q-format PINNED (discharges §1.5's condition).**
Per query head, after the sweep:

```
p = msb_pos(s)                        -- 11 <= p <= 23 at MAXCTX = 2048
r : u16 = floor( 2^(p+15) / s )       -- divider_rs, NW = 44, DW = 28
```

`s in [2^p, 2^(p+1))` gives `r in (2^14, 2^15]`, so r is a **Q15 mantissa of
1/s on the 2^(p+15) grid**; its relative error is `0 <= delta_r < s/2^(p+15)
<= 2^-14`, floor-mode (one-sided). `s >= 3848` always (the max-scoring
position contributes `e >= EXP_ROM(255) >> 18`), so the divide is never
degenerate. `divider_rs` computes exactly this floor (its header's
exactness contract), and **the C reference is DEFINED as this floor-divide
reciprocal followed by site 6b** -- not as a true division -- which is the
§1.5 condition. MEASURED 2026-08-25: `divider_rs` at NW=44/DW=28 on
`xcvu33p-fsvh2104-2L-e` is 0 DSP, 76 LUT, 152 FF, Fmax 681.7 MHz; one
instance serves all 12 heads sequentially (12 x ~46 cycles per layer).

**Site 6b -- reciprocal-multiply.**

```
t[qh][d] : s24 = round_shift( o[qh][d] * r[qh], p[qh] + 1 )   -- half+inf
```

value = `t * 2^-(v_ref[kvh] + 14)`: t is the attention output in
`v_aligned` units with a 2^14 precision gain. Bound: `|o/s| <= 127` (convex
combination of `|v_aligned| <= 127`), so `|t| < 2^21`. The multiply is
36x16 (2 DSP) in the output pipeline (§3.5), not on the MAC lanes.

**Site 6c -- gate argument conversion.** The gate value `(g_mant, qg_exp)`
converts to Q12 exactly as scores do (the §2.1.4 two-branch rule, restated
because the operand differs): `sh = qg_exp - 12`;
`zg : s32 = round_shift(g_mant, sh)` when `sh >= 0` (half+inf), else
`sat32(g_mant sll -sh)`.

**Site 6d -- sigmoid, Q15 out.** `g15 : u16 = SIG(zg)`: the
`fixed_pkg.sigmoid_q` arithmetic **verbatim** (513-entry Q30 `SIG_ROM` over
[-16, 16) step 1/16, linear interpolation, the same clamp structure), with
the output stage pinned here as **`round_shift(interp, 15)` half+inf,
clamped to [0, 32767]** -- Q15 rather than sigmoid_q's Qq, and the
saturated-high value 32767 rather than `1 << 15` (a deliberate, pinned
3.1e-5 deviation so g fits u16 and the multiply fits one DSP). Built as a
3-stage pipeline, 1 element/cycle. MEASURED 2026-08-25
(`sim/micro/micro_sig_cone.vhd`, GHDL-checked against sigmoid values at 11
points): **8 DSP, 1,062 LUT, 121 FF, Fmax 343.4 MHz** on the part at
3.333 ns. This is the "dedicated sigmoid ROM" rev 1 demanded: no EXP_ROM,
no divider, ~0.16 ms/token of pipeline occupancy instead of ~3 ms.

**Site 6e -- gate multiply.**
`y_pre[d] : s24 = round_shift(t[d] * g15[d], 15)` -- half+inf, 24x16, 1 DSP.
`|y_pre| <= |t|`.

**Site 6f -- output renormalization to one `y_exp`.** The card's heads sit
on two grids (`v_ref` is per KV head): `e_grid[kvh] = v_ref[layer][kvh] +
14`. Align to `e_min = min(e_grid)` -- the §2.1.4 min-alignment policy --
with a **floor** shift `y_al = y_pre asr (e_grid - e_min)`, then pack with
`bfp_pack` semantics (`amax` over all 3,072 `|y_al|`, `msb_pos(0) = 0`,
`shp = max(0, msb_pos - 14)`, `y_mant = sat16(round_shift(y_al, shp))`
half+inf, `y_exp = e_min - shp`).

| # | Site | Mode |
|---|---|---|
| 5a | max grid-snap | exact |
| 5b | weight `e_p` (EXP_ROM cone) | fixed by reused unit |
| 5c | rescale factor `f` from table entry | half+inf (the cone's own >>18) |
| 5d | rescale multiplies `o*f`, `s*f` | half+inf |
| 6a | reciprocal `r = floor(2^(p+15)/s)` | floor (one-sided, `< 2^-14`) |
| 6b | reciprocal-multiply -> `t` | half+inf |
| 6c | gate argument -> Q12 | half+inf / sat32 (the site-4/4b pair) |
| 6d | sigmoid interp -> Q15, clamp 32767 | interp fixed by reused unit; output half+inf |
| 6e | gate multiply -> `y_pre` | half+inf |
| 6f | grid align + pack -> `y_mant/y_exp` | floor, then half+inf + sat16 (`bfp_pack`) |
| R1 | twiddle phase `phi = low32(pos * W_j)` | exact (mod 2^32) |
| R2 | twiddle sin/cos interpolation | floor (matches the cones' interp shift) |

The three `v1.0-silicon` rules hold throughout: every multiplier is one DSP
op per pipeline stage with operands in `AREG`/`BREG` and no two multiplies
chained combinationally (the rmsnorm/rsqrt cascade lesson); no datapath
value transits a VHDL `integer` (exponents, shifts and indices only); all
synthesis at 3.333 ns on the real part, restated at 0.717 V.

### 3.3 The rescale error bound (the rev 2 M2 deliverable, quantitative)

Errors here are against REAL-VALUED softmax; RTL vs C reference is bit-exact
by construction and unaffected. Let R = number of rescale events in one
(group, sweep).

**Per-factor error.** With site 5c, `f_hat = f_true * (1 + delta)` where
`|delta| <= 0.51 / f_hat` (0.5 from the Q12 rounding of the table entry's
>>18, ~0.01 from the Q30 table entry's own rounding). For the smallest step
`k = 1` (`f = 3848`): `|delta| <= 1.33e-4`. Without the grid snap this would
be the EXP_ROM interpolation error instead, ~4.9e-4 relative
(`max|exp''| * h^2 / 8` at `h = 1/16`), 3.7x worse per factor -- that is
what site 5a buys.

**Compounding, bounded two ways.**

1. *Relative mis-weighting.* A factor error multiplies the retained mass of
   every position before the rescale, identically in `o` and `s`, so it
   cancels in `o/s` EXCEPT as mis-weighting between positions separated by
   rescales: positions with J rescales between them are mis-weighted by
   `prod(1 + delta_j) - 1 <= exp(sum |delta_j|) - 1`.
2. *Mass attenuation.* The absolute weight-mass error a rescale introduces,
   as a fraction of the final denominator, is `<= |f_hat - f| / 2^12 *
   (S_j * prod_later_f) / S_final <= 0.51 * 2^-12 ~= 2^-13` per rescale,
   because the retained mass never exceeds `S_final`. **Total L1 distortion
   of the effective softmax weights `<= R * 2^-13`.**

**LSB loss, bounded independently of R.** Each rescale rounds `o` and `s`
by <= 0.5 ulp, but every earlier rounding is attenuated by later factors
`<= exp(-1/16)`, so the accumulated additive error is geometric:
`<= 0.5 / (1 - e^(-1/16)) < 8.3` ulp of the `o` grid per element (and
<= 8.3 counts on `s`, i.e. <= 8.3/3848 = 0.22% of the denominator worst
case, or `R/2` counts if smaller). After site 6b this is <= ~35 counts of
the s24 `t` at the smallest legal `s`, i.e. ~2^-16 of full scale.

**The two regimes, stated honestly:**

| R | L1 weight distortion | Assessment |
|---|---|---|
| worst case `R = min(cur_pos, (m_g_final - m_g_first)/256)` = 2,047 at 2K ctx | **0.25** | unacceptable IF HIT; adversarial monotone-rising scores only |
| expected for exchangeable score sequences, `E[R] = H_n ~= 8.2` at n = 2048 | ~1e-3 | below the KV int8 mantissa quantization (~3.9e-3 per value) and far below A's measured +1.69% ppl format cost |

There is no hard worst-case mitigation in v2.1; there is **observability**:
a per-job `rescale_max` counter (max R over the job's 32 group-sweeps) is a
host-readable output (§3.9), and the §3.11 acceptance run records its
distribution on the eval corpus. If p99 R exceeds ~64 on real data, this
section must be revisited (candidate fix: per-head two-pass fallback).
Per-position weight interpolation error (site 5b, ~4.9e-4 relative) applies
once per weight, does not compound, and is shared with every softmax this
project has shipped.

### 3.4 IMROPE, pinned against source (closes the §1.6 list)

All items verified against source on 2026-08-25; llama.cpp tree
`~/GitHub/llama.cpp.upstream`, and the **target GGUF itself**
(`Qwen3.8-27B-Q4_K_M.gguf`), not inference:

1. **Variant**: `LLM_ARCH_QWEN35 -> LLAMA_ROPE_TYPE_IMROPE`
   (`src/llama-model.cpp:2727-2732`).
2. **`rope_sections` READ FROM THE GGUF: `[11, 11, 10, 0]`**
   (`qwen35.rope.dimension_sections`), with `rope.dimension_count = 64`,
   `freq_base = 1e7` -- matching §1.4/§4. Sections sum to 32 = `N_ROT/2`
   sectors (sections count PAIRS).
3. **Dispatch**: `sector = (i0/2) % 32`; imrope selects `theta_h` when
   `sector % 3 == 1 && sector < 3*sections[1]`, `theta_w` when
   `sector % 3 == 2 && sector < 3*sections[2]`, `theta_t` when
   `sector % 3 == 0 && sector < 3*sections[0]`, else `theta_e`
   (`ggml/src/ggml-cpu/ops.cpp:5898-5906`). All four theta streams advance
   by `theta_scale = 1e7^(-1/32)` every pair (`ops.cpp:5924-5928`);
   `indep_sects` is false for IMROPE (vision only), so no stream ever
   resets.
4. **Pairing is NEOX, not adjacent**: IMROPE calls
   `rotate_pairs(n_dims, n_dims/2, ...)` (`ops.cpp:6073-6078`), so pair j
   rotates **(x[j], x[j+32])** for j = 0..31. `rope.vhd`'s adjacent-pair
   indexing must be re-indexed; §1.6's `[ttyx...]` diagram describes sector
   INTERLEAVING, not element adjacency. Dims 64..255 of each head pass
   through unrotated. `ext_factor = 0` and `freq_factors = NULL` at the
   qwen35 call sites (`src/models/qwen35.cpp:303-312`), so the yarn path
   degenerates to plain `cos/sin(theta)`.
5. **Text-only fill**: `p_t = p_h = p_w = pos`, **`p_e = 0`**
   (`src/llama-graph.cpp:130-141`) -- answering §1.6's "what fills
   `theta_e`".

**The collapse (NORMATIVE for v2.1).** With sections `[11, 11, 10, 0]`,
enumerate the 32 sectors: `%3==0` gives {0,3,...,30} = 11 sectors, all
< 3x11 = 33 -> t; `%3==1` gives {1,4,...,31} = 11, all < 33 -> h; `%3==2`
gives {2,5,...,29} = 10, all < 30 -> w. **`theta_e` is unreachable**, and in
text mode t = h = w = `pos`, so every sector's angle is
`theta_j = pos * 1e7^(-j/32)` -- **text-mode IMROPE for this model is
arithmetically identical to standard NEOX RoPE over the first 64 dims.**
The v2.1 hardware implements the collapsed form (one angle stream, no
sector mux). The C reference implements the FULL dispatch (four streams,
sections from the GGUF, `theta_e` path) and §3.11 asserts the equivalence
by enumeration -- so if the sections, a multimodal input path, or the MTP
block ever enter scope, the divergence is caught in the reference, not on
silicon. This holds only under §1.2's decode-only, text-only scope.

**Twiddle generation (NORMATIVE; sites R1/R2).** Precomputed per-position
ROMs, `rope.vhd`-style, are REJECTED at this geometry: `MAXCTX x 32` pairs
x 2 tables x 16 b = 58 RAMB36 at 2K context and ~930 at the §4.2 32K cap
(derived). Instead, stateless phase generation:

```
W_j    : u32 = round( 2^32 * 1e7^(-j/32) / (2*pi) ),  j = 0..31   -- ROM, 128 B
phi_j  : u32 = low32( cur_pos * W_j )                             -- site R1, exact mod 2^32 (turns)
SIN[i] : s16 = round( 32767 * sin(2*pi*i/1024) ),  i = 0..1023    -- Q15, one table
sin    = SIN[phi[31:22]] + ( (SIN[(idx+1) mod 1024] - SIN[idx]) * phi[21:0] ) asr 22
                                                                  -- site R2, floor
cos    = the same lookup at phi + 2^30                            -- exact quarter turn
```

One tool (`tools/gen_imrope_pkg.py`, a §3.11 deliverable) emits both the
VHDL package and the C reference header from a single computation, the A
§6.4 discipline. Error: W-rounding `<= pos * 2^-33` turns (2.4e-5 rad at
pos 32K) + interpolation `(2*pi/1024)^2/8 ~= 4.7e-6` + table rounding
0.5 ulp -> **<= ~2 Q15 ulp total against exact `cos/sin`** -- the same
order as the float-generated Q15 tables `ref/run_fx.c` already uses, so the
engine convention is unchanged in kind. Cost: 2 DSP (sin+cos interp) +
2 DSP (`pos * W_j`, 15x32) + 1 RAMB18-class table.

**Rotation kernel.** `rope.vhd`'s per-pair arithmetic **verbatim**
(`(x0*fcr - x1*fci + 2^14) asr 15`, saturate int16 -- the rounding §2.1.5
already fixes to the reused unit) at NEOX indexing, 1 pair/cycle, restaged
as twiddle -> 4 registered products -> combine/saturate. MEASURED
2026-08-25: `rope.vhd` as built synthesizes to **8 DSP, 2,330 LUT, Fmax
206.4 MHz** on the part at 3.333 ns -- the products and combine share one
state, so the restaging is normative for the 300 MHz clock (the §2.6
`AREG`/`BREG` lesson; DSP budget stays 8). Throughput: 14 head-invocations
x (32 pairs + fill) ~= 500 cycles/layer.

**Saturation policy (discharges §2.1.2's "§3 owns the check").** The
kernel's int16 saturation clips the VALUE but does not corrupt the §2.1.2
exponent chain (the stored exponent still describes the clipped mantissa's
scale), and the C reference saturates identically, so bit-exactness is
unaffected. It is therefore a **sticky quality event `rope_sat`**, not an
`err` abort -- the A §14.2 `sat_event` precedent -- raised for either the K
or Q path, cleared at `start`, surfaced per §3.9.

### 3.5 The gate and output stage

One fused element-sequential pipeline, 1 element/cycle, using sites 6a-6f:

- **Per group, immediately after its sweep** (the accumulators are needed by
  the next group, so this cannot wait): the 6 reciprocal divides (site 6a,
  ~276 cycles serialized on the single `divider_rs`), then a **t-pass** over
  6 x 256 elements: read `o[qh][d]` (1/cycle through the existing lane read
  muxes), site 6b -> `t`; simultaneously read the gate word from `qg_rdata`
  (the interleaved layout of §1.1(a): G of head qh at offset
  `512*qh + 256 + d`), sites 6c/6d through the sigmoid cone, site 6e ->
  `y_pre`, fold the running `|y_al|` amax (site 6f's scan, using the
  group's grid), and store `y_pre` into a 3,072 x s24 scratch (2 RAMB36).
  1,536 cycles per group.
- **At layer end**, one emit pass over 3,072 elements: site 6f align to
  `e_min`, shift, saturate, write `y_we/y_addr/y_data` at 1 element/cycle
  (the elementwise 16-bit y port is the floor here regardless) and present
  `y_exp`. 3,072 cycles.

Per layer: 2 x (276 + 1,536) + 3,072 = **6,696 cycles**. The QG region is
re-read up to the end of the t-passes, inside the §2.6 rule-1 window (D O7);
nothing new is asked of D. DSP: sigmoid cone 8 (measured, §3.2) + site 6b
2 + site 6e 1 = 11.

### 3.6 QK-norm at N=256: measured, disqualifying as shipped, and the mandated fix

> **MEASURED 2026-08-25, OOC on `xcvu33p-fsvh2104-2L-e` at 3.333 ns
> (`sim/ooc_micro.tcl`, DSP census reconciled):**
>
> | | DSP | LUT | FF | Fmax |
> |---|---|---|---|---|
> | `rmsnorm.vhd`, N=256, as shipped | **78** | 11,766 | 4,694 | **138.4 MHz** |
> | width-narrowed skeleton (`sim/micro/micro_rmsn_narrow.vhd`) | **18** | 385 | 248 | 278.9 MHz |
>
> As shipped the unit is disqualified twice over: 78 DSP is a fifth of C's
> entire MAC array for a unit §2.8 budgeted inside "15-40 auxiliary", and
> 138 MHz misses the clock by 2.2x. The census attributes the damage to the
> three 64x64 `mulshr` sites of the pipelined rsqrt, the 64-bit-wide
> RAW/EMIT multiplies, and `scale_mul(raw, 1, shift)` -- a literal
> multiply-by-ONE, the identical waste `bfp_pack.vhd` removed on 2026-07-27
> and documented in its header, still present in `rmsnorm.vhd:355`. Procedure,
> evidence and traps: `docs/debugging/2026-08-25_c-aux-dsp-and-qk-norm.md`.

**The fix is the `attention_ml` narrowing pattern (64/64 -> 52/24 divider
precedent): lossless width reduction inside proven value bounds, guarded by
`translate_off` assertions.** The rsqrt operates on a Q30-normalized
mantissa: `smant`, `y`, `y2`, `my2` all fit s32 and `diff = 3<<30 - my2`
fits s34, so the three Newton multiplies are 32x32/34x32, not 64x64; the
RAW/EMIT chain is s16 x s32 then s48 x s16; the multiply-by-one becomes a
round-half-up shift (bit-identical, proven in `bfp_pack`). The narrowed
skeleton (multiply shapes real, control a free-running counter so nothing
folds -- the `micro_b_lane` pricing method) measures **18 DSP**. The
deliverable is `rmsnorm_rs`: bit-exact against `rmsnorm.vhd` in GHDL over
the §3.11 vector set; `engine_shared`/AXU3EG keep the original unit
untouched. Note the skeleton's 278.9 MHz is synthesis-only and still shy of
300 -- `MREG` on the 34x32 stage is the expected fix; open in §3.13.

**Throughput.** 14 invocations per layer (12 Q heads + 2 K heads) x ~1,296
cycles (S_ACC 256 + rsqrt ~10 + RAW/RAW_B 512 + EMIT/EMIT_B 512) on ONE
shared instance = 18.1K cycles/layer. With the two Q planes of §3.1, group
1's six Q-norms (7.8K cycles) run under group 0's 32.8K-cycle sweep, so the
exposed cost is ~8 x 1,296 = 10.4K cycles/layer; the serial fallback is
18.1K. The §3 latency note's 0.8B-era "~0.39 ms" is superseded by §3.7.

### 3.7 The full per-token budget (completes the §2.5/"latency accounting" item)

Per token per card, 27B N=2, `ctx_len = 2048`, `MACS = 192`, exp cone
pipelined. DERIVED from the measured per-unit numbers above; nothing here is
a promise of routed silicon.

| Component | cycles | ms @300 MHz | ms @231 MHz | basis |
|---|---|---|---|---|
| KV sweep, 16 lyr x 2 kvh x 2048 x 16 | 1,048,576 | 3.50 | 4.54 | §3.1 |
| rescale stalls, expected (~46 events x 8 x 32 sweeps) | ~12K | 0.04 | 0.05 | §3.3; worst case +524K = +1.75/+2.27 |
| QK-norm, exposed (group overlap) | 166K | 0.55 | 0.72 | §3.6; serial fallback 290K = 0.97/1.26 |
| IMROPE | 8K | 0.03 | 0.03 | §3.4 |
| KV quantize + write | 34K | 0.11 | 0.15 | §2.1.3 two-pass, 4 vectors/layer |
| gate + output stage | 107K | 0.36 | 0.46 | §3.5 |
| **C total** | **~1.38M** | **~4.59** | **~5.95** | |

The sweep is 76% of C; the aux terms this section finally prices add
**+1.1 ms over the sweep-only figure** every earlier document quoted
(§2.5's 3.93, the derate doc's 3.49). Downstream corrections: D §11's
"A jobs + C ~34 ms" row used sweep-only C (REQUEST R-C2, §3.12), and the
recon ladder's v3.0 tok/s inherits the same +1.1 ms (~-2% tok/s at N=2).
Port duty stays 53% per master during the sweep; the §2.5 obligation to
re-measure port efficiency for C's 2R+1W pattern stands, now against HBM.

### 3.8 Resource cost: the §2.8 auxiliary DSP row, pinned

**The auxiliary row lands at ~50 DSP -- ABOVE the §2.8 estimate's 15-40
band -- and only the §3.6 narrowing keeps it there.** Stated loudly, as
§2.8 demanded: with `rmsnorm` as shipped the row is ~110 and the die
crosses the 90% congestion line.

| Auxiliary unit | DSP | Status |
|---|---|---|
| QK-norm, narrowed (`rmsnorm_rs`) | 18 | MEASURED 2026-08-25 (skeleton; unit unwritten) |
| exp cone, pipelined | 8 | MEASURED 2026-08-24 |
| sigmoid cone, Q15 | 8 | MEASURED 2026-08-25 |
| IMROPE rotation kernel | 8 | MEASURED 2026-08-25 (`rope.vhd` form) |
| twiddle generation | 4 | DERIVED (2 interp + 2 phase) |
| gate stage (sites 6b, 6e) | 3 | DERIVED |
| `s` rescale multiplier | 1 | DERIVED |
| reciprocal divider, quantizer | 0 | MEASURED 2026-08-25 (divider 0 DSP) |
| **total** | **50** | |

**C total: 384 (MAC + rescale) + 50 = 434 DSP.** Whole-die, updating the
§2.8/D §12 sum (A post-reclaim 1,914 at `ROWS_IF = 58`, B 138-152, D
24-40):

```
1,914 + 434 + (138..152) + (24..40) = 2,510..2,540 of 2,880 = 87.2-88.2%
with rmsnorm as shipped:              2,570..2,600           = 89.2-90.3%   -- AT/OVER the line
```

The narrowing of §3.6 is therefore **mandatory, not an optimization**. The
+1.7-point rise over D §12's 85.4-86.5% must propagate to
`docs/fpga-hardware-recon.md` and any B sizing that assumed the old sum.

**LUT (derived from measured fits; supersedes the C terms in D §12's
screening sum):** lanes 192 x (158 + 10 x 8) = 45.7K (the §2.6 measured
lane fit at `ACC_N = 8`) + score trees ~6K + Q-plane muxes ~2K + stream
unpackers/aligners ~4K + quantizer/control ~8K + `rmsnorm_rs` ~8K + cones,
rope, gate ~6K = **~80K** (D §12 carried ~56K for C; whole-die screening
moves ~245-265K -> ~270-290K of 439.7K, still ~62-66%).

**FF:** lanes 192 x (182 + 36.4 x 8) = 90.8K (measured fit; contains the
55.3K §4.1 accumulator bits) + Q planes 49.2K + marshalling 8.2K + control
~10K = **~158K of 879K (18%)**.

**BRAM36:** read-master FIFOs ~8 + bypass 1 + `y_pre` scratch 2 + SIN
table + norm weights ~2 = **~13** (down from §2.8's ~26: Q moved to
registers per §3.0).

### 3.9 Errors and events, consolidated

`err` is sticky, cleared at the next `start`; `done` pulses even on abort so
D's FSM cannot hang (the A §7.6 convention D's O18 consumes).

| Condition | Checked | Action |
|---|---|---|
| `ctx_len > MAXCTX`, `cur_pos >= ctx_len`, `layer >= MAXLAYERS` | at `start`, before any AXI or state write | `err` + `done`, abort |
| header exponent outside int8 (§2.1.5) | at quantize | `err`, abort (cache slot NOT valid; D §10's sequence-replay recovery applies) |
| AXI `RRESP`/`BRESP /= OKAY` | any beat | `err`, abort after drain-then-flush (§2.7) |
| IMROPE int16 saturation (K or Q) | per rotation | **`rope_sat` sticky FLAG, not err** (§3.4) |
| rescale count | per job | `rescale_max` counter output, informational (§3.3) |
| divider `den = 0` | impossible (`s >= 3848`) | simulation assertion only |
| accumulator/dividend/width bounds (§3.2, §3.6 narrowings) | `translate_off` assertions | simulation failure, loud |

### 3.10 Port shapes pinned (answers D REQUEST R4), and one §1.4 correction

All three A-side read ports present `act_mem_striped` semantics (D O25):
**512-bit block read data, block address, 1-cycle registered read.**

| Port | Width | Notes |
|---|---|---|
| `qg_rbaddr` / `qg_rdata` | 8 b / 512 b | 6,144 entries = 192 blocks (27B N=2) |
| `k_rbaddr` / `k_rdata` | 4 b / 512 b | 512 entries = 16 blocks |
| `v_rbaddr` / `v_rdata` | 4 b / 512 b | 16 blocks |
| `y_we` / `y_addr` / `y_data` / `y_exp` | 1 / **12 b** / 16 b / int | 3,072 entries; 1 element/cycle |
| `rope_sat`, `rescale_max[15:0]` | out | §3.9 events, valid from `done` to next `start` |

**Correction to §1.4:** `y_addr` is declared `10 downto 0` there (2,048
entries, an 0.8B count); at 27B N=2 the y vector is 3,072 entries, so
`y_addr` is **11 downto 0**. Flagged rather than silently edited; §1.4's
declaration should be updated with the next §1 edit pass.

**Answer to D's R4 ("are the qg/k/v pre-quantize reads sequential?"):
YES.** C reads VIN and KIN **sequentially, never concurrently** -- pinned
order: V first (its quantize has no norm/rope dependency, so the write
master starts earliest), then K -- each exactly once per layer, in
ascending block order. **KIN and VIN may therefore share one region.** QG
is read in two phases: the Q marshalling reads early in the job; the gate
re-read (§3.5) runs to the end of the t-passes; both are block-sequential.
The §2.6 rule-1 lock window (O7) already covers the whole span; no new
obligation on D.

### 3.11 Validation and acceptance criteria

1. **C reference** (`ref/attn_gated_fx.c`): the full §2.1 + §3.2 chain --
   quantizer, FULL-dispatch IMROPE (four streams, GGUF sections, `theta_e`
   path), online softmax in the §3.1 processing order, reciprocal-multiply
   as DEFINED in site 6a/6b, sigmoid Q15, pack. Twiddle constants and both
   ROMs emitted by `tools/gen_imrope_pkg.py` into the reference and the
   VHDL from one computation.
2. **Property tests in the reference:** (a) the §3.4 collapse -- full
   IMROPE dispatch equals the collapsed NEOX form for sections
   `[11,11,10,0]`, enumerated over all `pos < MAXCTX` and all 32 pairs,
   exact; (b) online vs two-pass softmax divergence within the §3.3 bound
   on random AND adversarial (monotone-rising) score sequences, plus the
   `k = 0` rescale-identity; (c) `e_v >= v_ref` append-only invariants.
3. **GHDL unit TBs:** quantizer vs a `bfp_pack`-derived golden; twiddles vs
   double precision (<= 2 Q15 ulp assertion); both cones back-to-back-input
   throughput AND value agreement (the `micro_exp_cone` method -- identical
   utilization alone is NOT accepted as evidence); **`rmsnorm_rs` bit-exact
   vs `rmsnorm.vhd`** over random vectors plus engine-captured ones;
   divider bounds. Job-level RTL vs reference: **0 mismatches on every
   output** for `ctx_len` in {1, 2, 31, 32, 33, 255, 256, 2047, 2048}
   (block, beat-phase and burst-split boundaries), all layers, both KV
   heads.
4. **Token-level co-sim** in the `seq_ctrl`/`run_fx` pattern under D's stub
   table (D §14). Netlist funcsim of the divider and one MAC lane (project
   precedent).
5. **Synthesis gates:** assembled C at `MACS = 192`: DSP <= 440; routed
   (not synthesis-only -- the broadcast-fanout lesson) Fmax >= 300 MHz at
   the 0.85 V analysis, with the DSP census showing `AREG/BREG = 1` on
   every datapath multiplier; the number is then restated at 0.717 V.
6. **Model quality, measured not asserted, before v2.1 sign-off:** the
   attention-chain increment -- §2.1 KV format + online softmax + Q15 gate
   + fixed twiddles, emulated over the reference implementation with the
   2026-08-24 format-perplexity difference method (control = A weight
   format only) -- costs **<= +0.5% perplexity** on the same wikitext-2
   setup. First suspects if exceeded: per-32 V exponents, the Q15 gate.
   The same run records the `rescale_max` distribution (§3.3's regime
   check: p99 R <= 64).
7. **`softmax.vhd` integration note (the §1.5 obligation, discharged):** C
   does NOT instantiate `softmax.vhd`; it lifts the cone arithmetic
   verbatim (conv_q, stages A/B/C, underflow and clamps) and keeps the sum
   accumulation sequential. `e_arr` has no online-form counterpart --
   scores are consumed as produced -- a deliberate, stated divergence. If
   the AXU3EG engine's `softmax.vhd` is itself ever pipelined, it must
   preserve `conv_q`, the `e_arr` store and the sequential sum, per the
   measured recipe in `sim/micro/micro_exp_cone.vhd`.

### 3.12 REQUESTS to other subsystems (flagged, not assumed)

| # | To | Request | Why |
|---|---|---|---|
| R-C1 | D | Surface C's `rope_sat` and `rescale_max` in a host-visible register, the way O23/SAT_LOG surfaces A's `sat_event` | §3.3/§3.4 events are calibration-level and host-owned; D owns the register map (D §9.3) |
| R-C2 | D | D §11's "A jobs + C" row used C's sweep-only figure; C's full cost is +~1.1 ms at 300 MHz (§3.7) | keep the only whole-token table honest |

Nothing else: `k_base`/`v_base`, `cur_pos`/`ctx_len`, exponent capture and
the O7 lock window already cover §3's needs, and the twiddle path was kept
C-internal specifically to avoid a new D obligation.

### 3.13 Open, not yet answered

1. **`rmsnorm_rs` exists only as a priced skeleton** (18 DSP): the real
   narrowed unit, its bound assertions and its bit-exactness proof are
   unwritten, and the skeleton's 278.9 MHz (synthesis-only) is still shy
   of the clock -- `MREG` on the 34x32 Newton stage is the expected fix,
   unmeasured.
2. **No Fmax measurement exists at 192 lanes.** The routed 339.6 MHz is at
   64; broadcast fanout grows with lanes (k/v fan out 6, e/f fan out 32,
   control 192) and the 64-lane limiter had already moved to the DSP
   cascade. Do not extrapolate; §3.11 gate 5 is the check.
3. **HBM port efficiency for C's 2R+1W concurrent pattern is unmeasured**
   (§2.5's obligation, carried; the 53% duty premise is DERIVED).
4. **The worst-case rescale regime has observability, not mitigation**
   (§3.3). If real 27B score dynamics ever approach it, a per-head
   two-pass fallback must be designed.
5. **Real 27B attention-score range and rescale statistics are
   unmeasured** (the stories260K analog in the partial-sum work does not
   transfer); §3.11 gate 6's corpus run is the first measurement.
6. **The perplexity acceptance run needs tooling that does not exist**: an
   instrumented KV-quant/softmax path implementing §2.1 + §3.2 exactly
   over the reference implementation.
7. **The group-overlap control** (two Q planes, norm-under-sweep) is
   priced (§3.6, §3.7) but not designed; the serial fallback costs +0.42
   ms at 300 MHz.
8. **The 16-byte record phase realignment** in the stream unpacker (§3.0)
   is designed but unsimulated; `ctx_len` parity cases are in §3.11 gate 3
   for exactly this reason.
9. **`MAXCTX` scaling**: widths for `s`, the reciprocal, and the SIN phase
   are stated parametrically but every number here is at `MAXCTX = 2048`;
   the §4.2 32K-context ambition re-derives them (s -> 28 b, NW -> 48).

## 4. RETARGET to Qwen3.8-27B on FK33 (2026-08-21, NORMATIVE)

**This section supersedes every Qwen3.5-0.8B dimension elsewhere in this
document.** All derivations in §1-2 remain valid; only the numbers change.

| Parameter | 0.8B (superseded) | **27B (current)** |
|---|---|---|
| hidden | 1024 | **5120** |
| layers | 24 (18 GDN + 6 attn) | **64 (48 GDN + 16 attn)** |
| FFN dim | 3584 | **17408** |
| vocab | 248,320 | 248,320 |
| tied embeddings | true | **FALSE -- separate lm_head** |
| attention heads / kv | 8 / 2 | **24 / 4** |
| head_dim | 256 | 256 |
| GDN key heads / value heads | 16 / 16 | **16 / 48** |
| GDN state_size / d_inner | 128 / 2048 | **128 / 6144** |
| Params | 752M | **26.896B** |
| Size @ 4.5 bpw | 423 MB | **15.13 GB = 14.09 GiB** |

Derivation check: embed 1.271B + lm_head 1.271B + GDN 5.56B + attention 1.68B +
FFN 17.11B = **26.89B**, against the GGUF's 26.896B. Shapes verified.

### 4.1 What changes for subsystem C

| | 0.8B | **27B** |
|---|---|---|
| Attention layers | 6 of 24 | **16 of 64** (indices 3, 7, ... 63) |
| Query / KV heads | 8 / 2 | **24 / 4** |
| Query heads per KV head (GQA) | 4 | **6** |
| `wq` output (Q + fused gate) | 4096 | **12288** |
| `wo` input | 2048 | **6144** |
| `MAXLAYERS` | 6 | **16** |

`head_dim` stays 256, so **§2.1's numeric contract is unchanged** -- the per-32
block structure, the exponent chains, the alignment policy and all six rounding
sites carry over verbatim. Only counts change.

The GQA head-grouping of §2.4 becomes **6 query heads per KV head** rather than
4, so the grouped loop carries 6 running maxima, 6 sums and 6 accumulators:
`6 x 256 x 36 b = 55,296 FF` per group, up from 36,864.

### 4.2 KV cache at 27B scale

Per position: 16 layers x 4 kv heads x 256 x 2 (K,V) = **32,768 values**, or
34.8 KB at the §2.1.1 format (8.5 bits/value).

| Context | Total | Per card (2-way shard) |
|---|---|---|
| 2,048 | 71.3 MB | **35.6 MB** |
| 8,192 | 285 MB | 143 MB |
| 32,768 | 1.14 GB | 570 MB |

Against ~890 MB of free HBM per card at v3.0 (8 GiB minus the 7.11 GiB
resident), **context is capped near 32K by memory, not by bandwidth.**

### 4.3 Sharding

At **N=2** the split is exact: 24 query heads -> 12, and **4 KV heads -> 2**, so
each card owns whole KV heads and no replication is needed. At **N=8**,
`4 kv / 8 = 0.5`, so **KV replicates 2x** -- each KV head is held by two cards.
Costs memory, not bandwidth. `wq`/`wk`/`wv` are column-parallel by head, `wo` is
row-parallel and needs subsystem A's partial-sum mode (A §14.2).
