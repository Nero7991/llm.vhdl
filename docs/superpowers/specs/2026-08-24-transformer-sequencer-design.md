# Subsystem D: Transformer Sequencer

Design spec, 2026-08-24. Milestone `v2.4`. **Revision 1.**

**STATUS: no adversarial review has run against this document yet.** A's §7.4
survived a review on its fifth revision, C's §2.1 on its sixth, and B's rev 1
carries the same warning as this one. Expect the same here. The obligations
table in §2 was extracted by reading all four sibling specs in full plus a
grep sweep for "subsystem D" / "out of scope" / "owner"; the design in §3
onward is new and unreviewed.

Process rules inherited from A, B and C, applied from this first revision:

- **The extraction (§2) is separated from the design (§3+)** so a reviewer can
  check the obligations against the source specs independently of whether the
  design discharges them.
- **Contradictions between the source specs are stated, not silently
  resolved** (§2.2). Where this document picks a resolution, the pick and its
  reasoning are marked. This is the defect class C's five review rounds kept
  finding, one seam over.
- **Measured, derived and assumed are labelled.** Nothing in this document has
  seen synthesis; every resource number in §12 is an estimate and says so.
- The automated `§N.M` reference sweep runs after every edit pass (C rev 6
  process change).

## 1. Context and scope

Every other subsystem spec dumps its out-of-scope obligations into "subsystem
D, the transformer sequencer" (C §1.3 named it after review found the A/C seam
"unowned while §2.5 issued instructions to it"; B §1.3 and E §1.2 followed).
D is therefore where the integration contracts live, and B and C cannot have
RTL written until these contracts are pinned: both take region-steered inputs
with captured exponents, ordinal layer indices, and per-sequence resets that
only D drives.

**Target:** Qwen3.8-27B INT4 on N=2 FK33 (`xcvu33p-fsvh2104-2L-e`, 2,880 DSP,
439,680 LUT, 672 RAMB36, 320 URAM, 8 GiB HBM2), 64 layers = 48 GDN + 16
attention, hidden 5120, FFN 17408, per A §14 / B §4 / C §4. **D is designed to
be correct at N=1 as well** (§4.4): a single card running a smaller model is a
live configuration, and nothing in D's hardware may hard-require subsystem E.

**Prior art, same project, same job:** `rtl/seq_ctrl.vhd` (behavioural driver:
embed -> N layers -> final rmsnorm -> lm_head -> sampler, start/done pulse
handshake per unit, KV write-after-use rule) and `rtl/engine_shared.vhd` (the
silicon version: ONE instance of each unit, a single master FSM time-
multiplexing them across all layers and all matmuls, 24/24 tokens bit-exact on
AXU3EG silicon). D is `engine_shared`'s master FSM re-grown for streamed
weights, DDR/HBM-resident state, four independent subsystems and two cards.
The structural lessons carried over: one shared instance per unit, the
one-cycle start/done pulse convention, write-the-cache-after-using-it, and
"the FSM drives a select, the units never know which layer they are".

**In scope for D:**

- the per-token master state machine: layer-type interleave, per-layer job
  sequences, final norm, lm_head, argmax capture;
- the activation memory system: physical regions, producer/consumer steering,
  the structural disjointness C §2.6 and B §2.6 demand, and per-region
  exponent capture registers;
- the descriptor table: format, storage, and delivery of per-layer parameters
  to A, B, C and E;
- **D-vec**: the elementwise arithmetic the other specs assigned to D --
  `attn_norm` / pre-FFN norm, the residual adds, and swiglu (§7). This is
  arithmetic, not sequencing, and it costs DSPs -- see the finding in §7.1;
- the HBM port grant mechanism between A, B and C, and the switch rule;
- per-sequence initialisation (`kv_seq_rst`, B `seq_rst`, `cur_pos`), error
  aggregation, watchdogs, and the host-facing register interface;
- boot-loaded constant memories for B's per-layer constants (B §1.4 calls them
  "D-steered small memories") and for D-vec's norm weight vectors.

**Out of scope:** everything A, B, C and E already own (matvecs, attention,
GDN, the collective); the packer; PCIe enumeration and BAR setup (host, at
boot); batched prefill (B §1.2, C §1.2: the host teacher-forces prompts one
position at a time -- D runs exactly one token per `go`); speculative
decoding / the MTP block (C §1.4 excludes it); and the two per-token host
duties D deliberately leaves on the host (§3.2): the embedding gather and the
cross-card argmax combine.

## 2. Obligations placed on D by the other specs (extracted, cited)

### 2.1 The obligations table

Every row cites the section that imposes it. "Discharged in" points at the
section of this document that satisfies it.

| # | Obligation | Source | Discharged in |
|---|---|---|---|
| O1 | Steer A's output into the correct activation memory region, per job | B §1.3, C §1.3 | §5 |
| O2 | Sequence the seven A jobs per GDN layer (wqkv as THREE jobs q/k/v, then z, beta, alpha, then ssm_out after B) | B §1.3 | §4.2 |
| O3 | Sequence the A -> C -> A -> A order for attention layers | C §1.3, C §2.7 | §4.3 |
| O4 | Own `attn_norm` / `attn_post_norm` and the residual adds | B §1.3, C §1.3 | §7 |
| O5 | Interleave B layers with C layers per the layer map (48 GDN + 16 attention, attention at 3, 7, ..., 63) | B §1, C §4.1 | §4.1 |
| O6 | Supply `layer` as the GDN ORDINAL 0..47 to B and the ATTENTION ORDINAL 0..15 to C; D owns the model-index mapping | B §1.4, C §1.4 | §4.1 |
| O7 | The `wq` output region must not be written by anyone until C asserts `done` | C §2.6 rule 1 | §5.3 |
| O8 | C's `y` output steered to a region disjoint from the `wq` output | C §2.6 rule 2 | §5.1, §5.3 |
| O9 | B's `z` region not written until B asserts `done`; B's `y` region disjoint from `z` and from the qkv regions until the conv-slot write has BRESP'd | B §2.6 | §5.1, §5.3 |
| O10 | Drive `kv_seq_rst` (C) at the start of each sequence, NOT per token | C §1.4 | §9.2 |
| O11 | Drive `seq_rst` (B) at sequence start, NOT per token | B §1.4 | §9.2 |
| O12 | Supply `cur_pos` and `ctx_len` to C | C §1.4 | §9.2 |
| O13 | Run exactly one of A/B/C at a time; grant the external-memory ports to the active unit; no bandwidth splitting | B §2.7, C §2.7 | §8 |
| O14 | Respect drain-then-flush: each unit drains and flushes its OWN FIFOs on `start` (D does NOT flush anyone's FIFOs -- C §2.7 explicitly repatriated that duty); D's part is not to hand a port to a new owner while the old owner's transactions are outstanding | A §7.7, C §2.7, B §2.7 | §8.2 |
| O15 | Supply B's six independent input exponents (`qkvq/qkvk/qkvv/z/b/al`) as the CAPTURED per-job values of the producing A jobs, never a shared or stale value | B §1.4, B §2.1.2 (the C2/CR3-2 lesson) | §5.4 |
| O16 | Supply C's three independent input exponents (`qg/k/v`) likewise | C §1.4 (C2) | §5.4 |
| O17 | Host/boot-load B's per-layer constant memories (`ssm_norm`, `ssm_dt`, `ssm_a`) and route their read ports and exponents to B | B §1.4 ("D-steered small memories, loaded at boot") | §6.4 |
| O18 | Check `err` after every sub-unit `done` -- `done` pulses even on a descriptor abort precisely so "the caller's FSM cannot hang"; the caller is D | A §7.6, B §2.1.6 | §10 |
| O19 | Load A's codebook only while A is idle (`cb_we` outside idle raises `err`) | A §7.5 | §6.3 |
| O20 | Issue the row-parallel matvecs (FFN down, attn `wo`, GDN `ssm_out`) in partial mode and run the E collective after each | A §14.2, A §14.3 | §4.2-4.4 |
| O21 | Barriers across a layer belong to D; E's `done` must be awaitable selectively; D must issue the next layer's weight streaming concurrently with the collective | E §1.2, E §2.5 | §4.5, and the finding in §2.2-K |
| O22 | Supply E's `seq` (per-collective sequence number), `my_rank`, `n_rows`, `y_exp`, `out_shift` | E §2.6 | §6.2, §9.2 |
| O23 | Surface A's sticky `sat_event` per job to the host | A §14.2 | §10 |
| O24 | The whole-model schedule per layer: "per layer: A x6 -> B -> A, or A x3 -> C -> A x3, then FFN" | B §2.7 | §4.2-4.3, but see contradiction §2.2-A |
| O25 | D's region read ports must present `act_mem_striped` semantics to A (BLOCK-wide data, block address, 1-cycle registered read) and the same BLOCK*16 shape to B and C | A §7.8, B §1.5, C §1.4 | §5.2 |
| O26 | Transport per-card `y_exp` alongside partials for the E reduction (the corrected A §14.2 contract) | A §14.2 (as corrected 2026-08-22) | §6.2, blocked -- see §2.2-C |

### 2.2 Contradictions and ambiguities found during extraction

These are stated rather than silently resolved. Where D must pick to make
progress, the pick is labelled and the losing reading is preserved.

**A. B §2.7 and C §2.7 disagree on the attention-layer job count.** B §2.7
says "A x3 -> C -> A x3, then FFN". C §2.7 says "A (`wq`,`wk`,`wv`) -> C ->
A (`wo`) -> A (FFN)". Only ONE A job (`wo`) sits between C and the FFN, so
B's "A x3" after C is wrong unless it was meant to fold the FFN's three jobs
into the phrase and then say "then FFN" redundantly. **D's pick: C's own
§2.7, which is the authoritative spec for its layer type** -- norm, A x3, C,
A(`wo`), collective, residual, then the FFN block. B §2.7 should be corrected
to match.

**B. A §14.1 says the three-way wqkv split "dissolves"; B's interface still
requires it.** A §14.1's 27B retarget raises `MAXROWS_BFP` to 17408 and notes
this "dissolves the `wqkv` M=6144 finding". It dissolves only the *abort*:
B §1.3's second reason for the split -- each segment gets its own `y_exp`
instead of sharing one exponent across q, k and v "whose scales have no
reason to match" -- stands, and B §1.4's interface hardcodes it (three
separate `qkvq_exp/qkvk_exp/qkvv_exp` ports and three captured slot exponents
per conv slot, §2.1.1). **D's pick: three jobs, per B's interface.** A
one-job wqkv is not representable on B's ports. A §14.1's note should be
qualified.

**C. E's numeric contract is stale against A's corrected partial mode, and A
§15.4b says so.** E §1.3/§2.1 assume s32 partials on a shared grid ("All N
cards ... MUST have been programmed with the same `out_shift`. That is what
makes the partials directly summable"), an s36 accumulator, and an exact
reduction. A §14.2, corrected 2026-08-22 after E's own review, emits
**unrounded s48** with a **per-card `y_exp` that cannot be equalised**
(`x_exp` is data-dependent per card), and A §15.4b records the open
contradiction on exactness and states E's accumulator bound "is wrong on two
independent counts". **D cannot close this.** D's collective steps (§6.2) are
specified against the A-corrected contract (s48 payload, `y_exp` transported,
`out_shift` recommended-equal but checked-not-assumed), and E's spec must be
revised before E RTL exists. Until then the E descriptor fields in §6.2 are
provisional.

**D. A's §5 port list contradicts its own §14.2.** `y_data` is declared
`31 downto 0`, but partial mode emits the accumulator "UNROUNDED s48" (and
A's own AXI wrapper already widened its result buffer to 64 bits for exactly
this). D's steering assumes a >= 48-bit y bus in partial mode. This is an
internal A inconsistency that integration surfaces; flagged to A, not worked
around here.

**E. Nobody owns swiglu.** A's scope is the matvec ("Out of scope: the
transformer FSM, Gated DeltaNet, attention, normalization units"); B and C
own their layer types; E owns the collective. The FFN's elementwise
`silu(gate) * up` between the gate/up jobs and the down job appears in no
spec. **It defaults to D** (it sits exactly where the residuals and norms
that were explicitly assigned to D sit), and D takes it -- §7. This is a
discovered obligation, not a cited one.

**F. Nobody owns the embedding gather or the token loop.** The 27B has
untied embeddings (A §14); fetching row `tok` of `token_embd` is a gather,
not a matvec, so A cannot do it (streaming the whole 1.27 GB table per token
to select one row is absurd). B §1.2 and C §1.2 both say "the PS
teacher-forces prompts one position at a time, as it does today", i.e. the
host is already in the per-token loop. **D's pick (§3.2): the host owns the
embedding** -- it dequantizes row `tok` bit-exactly (a defined recipe, §3.2)
and writes the 10,240-byte int16 row plus exponent into D's X region before
each `go`. At ~30 tok/s a 10 KB PCIe write per token is noise. The
alternative (an on-chip embed-fetch unit) is recorded in §15 as an option if
host-in-loop latency ever matters.

**G. Cross-card argmax is in nobody's scope.** lm_head is column-parallel at
N=2 (A §14.3), so each card holds a local argmax over its 124,160 rows. E
reduces sums, not maxima. **D's pick: the host combines** the two (value,
index, `y_exp`) triples, exponent-aware, in software. No new hardware, no new
obligation on E. (Making the comparison exponent-free by forcing equal
`w_exp`/`out_shift` across lm_head shards was considered and dropped -- it
would impose a new packer obligation for zero gain over a two-line host
compare.)

**H. Norm-weight ownership is asymmetric across B and C.** C owns and budgets
its QK-norm weight storage (C §2.8 BRAM row: "norm weights"); B declares its
per-layer constants "D-steered" (B §1.4). D therefore owns B's constants and
all of the layer-level norm weights (`attn_norm`, pre-FFN norm, final norm --
129 vectors x 5120 x int16 = 1.29 MB, §6.4) but none of C's. Asymmetric but
workable; recorded so nobody assumes symmetry.

**I. "attn_post_norm" placement is assumed, not verified.** B §1.3 names
`attn_norm / attn_post_norm` as D-owned. This document reads
`attn_post_norm` as the **pre-FFN norm** of a standard pre-norm block
(x -> norm -> mixer -> +x -> norm -> FFN -> +x), consistent with B §1.1
("on the post-`attn_norm` activation") and with `engine_shared`'s flow. It
has NOT been verified against `qwen35.cpp`'s `build_layer` for the 27B; if
the architecture carries an additional norm (e.g. a post-mixer norm before
the residual), the §4 microprograms gain a step. Listed in §15.

**J. The FK33 pack format is open (A §14.5), so the A-job descriptor width
cannot be pinned.** The number of weight sub-region bases per A job equals
the lane count, which A §14.5 leaves unresolved (lanes vs physical HBM ports,
CDC discipline). D parameterises: `NSUB_W`/`NSUB_S` base slots per
descriptor, sized `NSUB_MAX = 64` (§6.1). At `ROWS_IF = 58`, A §6.5's
invariant (`NPORTS_W * AXI_DW = ROWS_IF * BLOCK * 4`) gives 29 lanes at
`AXI_DW = 256`; the table sizing in §6.1 uses
33 total bases (29 weight + 4 scale) as the working estimate.

**K. E §2.5's overlap requirement cannot be discharged by D scheduling
alone.** E demands D "issue the next layer's weight streaming concurrently
with the collective". At batch 1 every post-collective operation is
data-dependent on the collective result (collective -> residual -> norm ->
next matvec's x), so the only independent work is the next A job's weight
*prefetch* -- and A begins streaming only at `start`, with FIFO depth ~8 KB
per port (A §7.7): at HBM rates the entire prefetchable window is under a
microsecond, against a collective of ~2 us (N=2) to ~11 us (N=8). **D can
overlap what is overlappable** (it pipelines E's output stream into the
residual, §4.5, saving one full vector pass) **but the weight-prefetch
overlap E's v4.0 math needs requires a preload capability in A that A does
not currently specify.** REQUEST R1, §13. At N=2 the unoverlapped cost is
~2.5% (E §2.4) and this is acceptable; at N=8 it is not, and the request
must be settled before v4.0.

**L. Per-tensor codebooks.** A §6.4 carries the codebook per packed file, and
A §6.1 makes it a runtime experiment. If every tensor ships the same
codebook, one boot-time load suffices (O19). If not, D must reload 16 bytes
between jobs. The descriptor carries an optional codebook + `cb_load` flag
(§6.1) so both work; the cost is 16 idle-state writes, ~20 cycles.

## 3. System architecture

### 3.1 The units and who talks to whom

```
                       host (PCIe BAR / AXI-Lite)
                          |            |
                 registers, X write,   descriptor + constant load (boot)
                          |            |
   +----------------------v------------v--------------------------------+
   |  D-ctrl: master FSM, descriptor walker, locks, grants, watchdogs   |
   +--+--------+--------+--------+--------+-------------+---------------+
      | start/desc      |        |        |             |
   +--v---+  +-----v-+  +--v--+  +--v--+  +------v-----+
   |  A   |  |   B   |  |  C  |  |  E  |  |   D-vec    |   (one instance each,
   +--+---+  +---+---+  +--+--+  +--+--+  +------+-----+    engine_shared style)
      |          |         |        |            |
      +----------+----+----+--------+------------+
                       |
        activation regions (§5) + exponent capture registers
                       |
      HBM ports: A ~23-27 dedicated | B/C 4 muxed (grant, §8) | D-vec 0
      PCIe: E peer BARs             | URAM: descriptors + constants (§6)
```

One instance of each subsystem, time-multiplexed by D across all 64 layers --
the `engine_shared` structure. A/B/C are never simultaneously active (B §2.7,
C §2.7); E and D-vec run in the gaps the schedule defines.

### 3.2 What stays on the host, and why

Per token the host: (1) chooses the input token (teacher-forced prompt or
previous argmax), (2) dequantizes the embedding row and writes it to region X
with its exponent, (3) pulses `go`, (4) on `token_done` reads the per-card
argmax triple, combines across cards, loops. This matches the existing
engine's PS-in-loop operation and both B §1.2 / C §1.2.

**The embedding recipe is a normative host deliverable** (it feeds the
bit-exact chain): dequantize the INT4 row with the same integer arithmetic as
A §7.4 (`codebook[idx] * scale`, floor `>> 15` per block -- exact integers
throughout), then BFP-pack the 5120 values to int16 + one exponent with
`bfp_pack` semantics (`amax` unsigned, `msb_pos(0) = 0`, bias only when
`sh > 0`, `sat16`). The C reference implements it; the host runs the C
reference. Both cards receive the identical row (the residual stream is
replicated under tensor parallelism).

At ~30 tok/s the host round trip (~10 KB write + a few register accesses) is
well under 1% of the 33 ms token. ASSUMED, not measured; if PCIe BAR write
latency surprises, the on-chip embed unit in §15 is the fallback.

### 3.3 lm_head and the sampler

The lm_head job is a raw-mode A job (`out_mode = "01"`) over the card's
vocab shard (124,160 rows at N=2). D routes its `y_we/y_data/y_exp` stream to
`sampler_stream` (existing RTL, consumes `y_we`/`y_data` exactly as it
consumes `logit_v/logit_valid` today, A §5) and latches (argmax index, value,
`y_exp`) into host-readable registers at `done`. Raw mode's `y_addr` is
undefined and ignored (A §5); the index comes from the sampler's own counter.

## 4. The per-layer state machine

### 4.1 Layer map and ordinals

64 layers; layer `i` is **attention iff `(i+1) mod 4 = 0`** (indices 3, 7,
..., 63 -- 16 layers, C §4.1), else GDN (48 layers). Ordinals:

```
gdn_ord(i)  = i - (i+1)/4        -- integer division; 0..47 over the 48 GDN layers
attn_ord(i) = (i-3)/4            -- 0..15 over the 16 attention layers
```

(Formulas verified exhaustively over i = 0..63.) In practice D does not
compute these: the descriptor table (§6) carries `layer_type` and `ordinal`
per step, and the formulas are the generator-side check. B receives
`gdn_ord`, C receives `attn_ord` (O6).

### 4.2 GDN layer: 18 steps, 10 A jobs

Per card at N=2 (dims from B §4: 8 key heads and 24 value heads per card,
key_dim/card 1024, value_dim/card 3072, conv_dim/card 5120; FFN 8704/card):

| # | step | unit | reads (region) | writes | A mode | notes |
|---|---|---|---|---|---|---|
| 1 | attn_norm | D-vec | X + norm weights | XN | | X stays locked (residual source) |
| 2 | wqkv q-slice | A | XN | QKV[0..1023] | BFP | 5120 -> 1024; capture `qkvq_exp` |
| 3 | wqkv k-slice | A | XN | QKV[1024..2047] | BFP | capture `qkvk_exp` |
| 4 | wqkv v-slice | A | XN | QKV[2048..5119] | BFP | 5120 -> 3072; capture `qkvv_exp` |
| 5 | wqkv_gate (z) | A | XN | Z | BFP | 5120 -> 3072; capture `z_exp` |
| 6 | ssm_beta | A | XN | BETA | BFP | 5120 -> 24 (row masking live: 24 not divisible by `ROWS_IF`) |
| 7 | ssm_alpha | A | XN | ALPHA | BFP | 5120 -> 24 |
| 8 | GDN | B | QKV, Z, BETA, ALPHA (+HBM state) | Y | | inputs locked until B `done` (O9); D supplies the 6 captured exponents (O15) |
| 9 | ssm_out | A | Y | -> E | **partial** | 3072 -> 5120 K-slice; s48 stream |
| 10 | all-reduce | E | (peer PCIe) | ER | | O20; at N=1 steps 9-10 collapse, §4.4 |
| 11 | residual | D-vec | X, ER | X | | exp-aligned add + requant, §7 |
| 12 | ffn_norm | D-vec | X + norm weights | XN | | the "attn_post_norm" of §2.2-I |
| 13 | ffn_gate | A | XN | G | BFP | 5120 -> 8704 |
| 14 | ffn_up | A | XN | U | BFP | 5120 -> 8704 |
| 15 | swiglu | D-vec | G, U | H | | §2.2-E; silu(g) * u, requant |
| 16 | ffn_down | A | H | -> E | **partial** | 8704 -> 5120 |
| 17 | all-reduce | E | | ER | | |
| 18 | residual | D-vec | X, ER | X | | |

The mixer half discharges O2 exactly: seven A jobs (steps 2-7 and 9), with
wqkv as three jobs in the §1.1(h) channel order q | k | v at fixed offsets in
one region (B's single `qkv_rbaddr` port expects the contiguous layout; the
per-segment exponents stay separate per §2.2-B).

### 4.3 Attention layer: 15 steps, 7 A jobs

Per card at N=2 (dims from C §4: 12 query heads, 2 KV heads per card):

| # | step | unit | reads | writes | A mode | notes |
|---|---|---|---|---|---|---|
| 1 | attn_norm | D-vec | X | XN | | |
| 2 | wq (Q+gate) | A | XN | QG | BFP | 5120 -> 6144, Q/G interleaved per head (C §1.1(a)); capture `qg_exp` |
| 3 | wk | A | XN | KIN | BFP | 5120 -> 512; capture `k_exp` |
| 4 | wv | A | XN | VIN | BFP | 5120 -> 512; capture `v_exp` |
| 5 | attention | C | QG, KIN, VIN (+HBM KV) | Y | | QG locked until C `done` (O7); D supplies `cur_pos`, `ctx_len`, ordinal |
| 6 | wo | A | Y | -> E | **partial** | 3072 -> 5120 K-slice |
| 7 | all-reduce | E | | ER | | |
| 8 | residual | D-vec | X, ER | X | | |
| 9-15 | FFN block | | | | | identical to GDN steps 12-18 |

This is the A -> C -> A -> A order of O3, in C §2.7's authoritative form
(§2.2-A).

**Token totals** (derived): 48 x 18 + 16 x 15 = 1,104 layer steps, plus final
norm (D-vec, X -> XN) and the lm_head A job = **1,106 steps, 593 A jobs**
per token per card.

### 4.4 N=1 degeneration

At N=1 there are no partials: the descriptor for each row-parallel matvec
(steps 9/16, attention 6) carries `out_mode = BFP` and `dst = ER`, the E
steps are absent from the table, and E need not be instantiated
(`HAS_E = false`). **D's hardware is identical**; only the host-generated
descriptor table differs. This is the design property that makes N=1 a
configuration, not a variant: the schedule is data (the table), not gateware.
The same holds for smaller models -- fewer layers is a shorter table.

### 4.5 What D overlaps, and what it does not

- **E's output stream pipelines into the residual.** E emits
  `o_we/o_addr/o_data` in row order; D-vec's residual pass 1 consumes the
  stream directly against X instead of waiting for a full ER region, saving
  ~5,120 cycles per collective. ER remains as the landing buffer (the
  residual's second pass re-reads it), so this is an ordering optimisation,
  not a structural change.
- **Descriptor prefetch**: step n+1's descriptor is fetched from URAM during
  step n. Zero-cost.
- **Weight prefetch across the collective is NOT provided** -- see §2.2-K and
  REQUEST R1. At N=2 the loss is ~0.42 ms/token (E §2.4), ~1.3% of the token
  budget. DERIVED from E's own numbers, not measured.
- Nothing else in a batch-1 token is independent; the schedule is a chain by
  data dependency, which is why D-ctrl's own overhead matters less than
  D-vec's throughput (§7.2, §11).

## 5. Activation memory: regions, steering, structural disjointness

### 5.1 The region map

All regions are `act_mem_striped`-shaped (A §7.8): element-wise 16-bit write
port, BLOCK-wide (512-bit) 1-cycle registered read port, 8 SDP banks. Sizes
are per card at 27B / N=2; every region has a companion **exponent register
file** (§5.4).

| Region | entries | roles | producer(s) | consumer(s) |
|---|---|---|---|---|
| X | 5120 | residual stream | host (embed), D-vec (residual) | D-vec |
| XN | 5120 | post-norm activations; final-norm output | D-vec | A (x port) |
| QKV | 5120 | GDN q\|k\|v, §1.1(h) order | A x3 | B |
| Z | 3072 | GDN gate | A | B |
| BETA | 32 (24 used) | GDN beta | A | B |
| ALPHA | 32 (24 used) | GDN alpha | A | B |
| QG | 6144 | attention Q+gate, interleaved | A | C |
| KIN | 512 | attention K (pre-quantize) | A | C |
| VIN | 512 | attention V (pre-quantize) | A | C |
| Y | 3072 | B's y / C's y | B or C | A (x port, for ssm_out / wo) |
| G | 8704 | FFN gate | A | D-vec |
| U | 8704 | FFN up | A | D-vec |
| H | 8704 | FFN hidden (post-swiglu) | D-vec | A (x port, for down) |
| ER | 5120 | reduced collective result (or direct BFP at N=1) | E or A | D-vec |

59,968 entries = 117 KB (derived). BETA/ALPHA/KIN/VIN are small enough for
LUTRAM banks; the ten large regions cost 8 RAMB36 each = **80 RAMB36**
(§12). D-vec additionally owns one s18 scratch buffer, 8,704 deep (~6
RAMB36), for its two-pass requant (§7.3).

**These regions subsume A's standalone activation memory and result buffer.**
A §7.9/§7.9a price a 16-tile `act_mem_striped` plus a ~36-tile result buffer
inside A's AXI wrapper; in the integrated engine A's x port reads from D's
regions and A's y port writes to them, so those tiles move here rather than
add to the die. The BFP-mode int32 scan buffer (17 tiles) stays inside A --
it is part of A's amax pipeline, not a steering concern.

**Fallback if BRAM binds: the packed map.** Role unions whose lifetimes the
layer FSM (not the descriptor) proves disjoint: {QKV, QG, G} -> one 8,704
region (QKV dies at B `done`, QG at C `done`, G is written only after those,
in the FFN phase); {Z, U} -> 8,704; {Y, H} -> 8,704 (Y dies when the
`wo`/`ssm_out` job's `done` arrives, before swiglu runs). Packed total: 6
large regions = 48 RAMB36 + scratch. The locks of §5.3 apply per physical
region either way. Baseline is the flat map -- clarity over tiles while 80 of
672 is affordable.

### 5.2 Read/write steering

- **Consumer side is static per job.** The mux selecting which region feeds
  A's `x_rbaddr/x_rdata` (6 candidate regions: XN, Y, H) is configured from
  the descriptor BEFORE `start` and is constant for the job's duration, so it
  adds combinational select depth but no pipeline stage: the 1-cycle
  registered-read contract of O25 is preserved. B's five read ports and C's
  three are hard-wired to their dedicated regions (no mux at all).
- **Producer side**: A's `y_we/y_addr/y_data` routes to (region, offset) from
  the descriptor. In partial mode the stream routes to E's `p_we` port
  instead of any region, and in raw mode to `sampler_stream` -- the route is
  part of `out_mode`'s descriptor decode, so a descriptor cannot
  simultaneously claim a region and E.
- **Offsets are append-only.** The three wqkv jobs land at offsets 0, 1024,
  2048 of QKV. D enforces `offset == region.fill_ptr` at job start
  (`fill_ptr` resets when the region unlocks); a descriptor violating it
  aborts (§10). This turns intra-region placement from convention into a
  checked invariant -- overlapping sub-writes cannot be expressed.

### 5.3 Locks: disjointness by structure, not convention

Each region carries a lock with three states: FREE, FILLING, HELD.

- A producer job targeting region R requires R in {FREE, FILLING}; its writes
  move R to FILLING.
- When a consumer job that reads R starts, R -> HELD. **HELD rejects every
  write**: a write strobe to a HELD region is dropped and raises `err`
  (ERR_LOCK, §10) -- this is the hardware form of O7 ("the `wq` region must
  not be written by anyone until C asserts `done`") and O9.
- The consumer's `done` returns R to FREE and clears `fill_ptr`. For B this
  is sufficient for the "until the conv-slot write has BRESP'd" clause of O9
  because B's `done` is itself gated on its last BRESP (B §2.7); D holds the
  qkv/Z locks to B's `done` conservatively rather than tracking the earlier
  conv-slot BRESP.
- O8 and the Y-vs-Z/QKV disjointness of O9 are discharged by physical
  separation: Y is a different BRAM bank set from QG, Z and QKV. No
  descriptor can make them overlap because regions are named, not addressed.

The locks are ~14 x 2-bit FSMs plus per-region fill pointers -- trivial
hardware whose entire purpose is converting C §2.6's and B §2.6's "must not"
sentences from schedule-review obligations into runtime-checked ones.
The scheduling in §4 never trips them; they exist to catch a wrong descriptor
table, which is the descriptor-class error A §7.6 taught this project to
check at `start` rather than trust.

### 5.4 Exponent capture

One int16 exponent register per region *segment* (QKV carries three: q, k, v;
every other region one). Captured from the producer's `y_exp` output **at the
producer's `done`** (BFP y_exp is only final after A's amax scan), or from
E's `o_exp` / D-vec's requant output likewise. Consumers receive the
registered copies on their exponent ports (B's six, C's three -- O15/O16).
This is the "captured, not re-read" rule of B §2.1.2 applied at D's seam:
reading a live `y_exp` port at use time would deliver the exponent of
whatever job ran last. Capture registers are cleared to 0 on `rst` only;
their validity is implied by the lock state (a FREE region's exponent is
never read, by construction of the schedule -- a property the stub testbench
of §14 asserts).

Host-written X carries its exponent via the X_EXP register (§9.3).

## 6. Descriptors: format, storage, delivery

### 6.1 Format (byte-pinned header; base array open per §2.2-J)

A descriptor is a 64-byte header plus an opcode-specific 64-bit base array.
All fields little-endian, pad bytes 0x00 (the A §6.4 discipline: two
conforming generators must produce byte-identical tables).

| Offset | Width | Field |
|---|---|---|
| 0x00 | u8 | `opcode`: 0 A_JOB, 1 B_JOB, 2 C_JOB, 3 E_COLL, 4 VEC_NORM, 5 VEC_RESIDUAL, 6 VEC_SWIGLU, 7 END_TOKEN |
| 0x01 | u8 | `flags`: bit 0 = route y to E (partial); bit 1 = route y to sampler (raw); bit 2 = `cb_load`; bit 3 = E step present after this job (N>1); others 0 |
| 0x02 | u8 | `src_region` (A's x / vec src0) |
| 0x03 | u8 | `dst_region` (or 0xFF when routed to E / sampler) |
| 0x04 | u32 | `dst_offset` (elements; checked against `fill_ptr`, §5.2) |
| 0x08 | u32 | `n_rows` |
| 0x0C | u32 | `n_cols` |
| 0x10 | i32 | `w_exp` |
| 0x14 | i32 | `out_shift` |
| 0x18 | u8 | `out_mode` (A §5 encoding) |
| 0x19 | u8 | `ordinal` (B: 0..47, C: 0..15) |
| 0x1A | u16 | `nsub_w` (weight base count following) |
| 0x1C | u16 | `nsub_s` (scale base count following) |
| 0x1E | u8 | `src_region2` (vec: second operand, e.g. U for swiglu, ER for residual) |
| 0x1F | u8 | reserved (0) |
| 0x20 | u32 | `const_base` (D constant-memory element offset: norm weight vector, or B constants) |
| 0x24 | i32 | `const_exp` (norm weight exponent; B `cw_exp` for B_JOB) |
| 0x28 | 16 x i8 | codebook, valid iff `cb_load` (else 0x00) |
| 0x38 | u64 | reserved (0) |
| 0x40... | u64[] | base array, `nsub_w + nsub_s` entries for A_JOB; opcode-specific otherwise (B_JOB: `s_base, se_base, cv_base, cw_base`; C_JOB: `k_base, v_base`; E_COLL: none) |

All external-memory bases are 64-bit (the A §6.4 lesson: 32-bit bases fail at
the first FK33 rung, not the second). `nsub_w` is bounded by
`NSUB_MAX = 64`, pending A §14.5 (§2.2-J).

### 6.2 What D supplies at run time (not in the table)

Per-invocation values the table cannot carry, supplied from D's counters and
capture registers: `cur_pos`/`ctx_len` to C (O12); the captured exponents
(§5.4) to A (`x_exp`), B (six) and C (three); `seq` to E -- a free-running
per-collective counter, reset by `seq_init` (§9.2), identical on both cards
**because both cards execute identical tables in lockstep-by-rendezvous**
(each collective is itself the synchronisation point; drift between cards is
bounded by one collective). ASSUMED: table identity across cards is a host
responsibility; D cannot verify it beyond E's own `out_shift` cross-check
(E §2.6). For E_COLL steps D also forwards `n_rows`, the producing job's
`out_shift`, and the captured `y_exp` (O22, O26 -- provisional per §2.2-C).

### 6.3 Codebook loads

Issued in D's idle gap between `done` and the next `start` (O19): 16
`cb_we` writes from the descriptor's codebook field when `cb_load` is set.
If the model uses one global codebook (expected -- IQ4_NL throughout, A
§6.1), only the first A job of the boot sequence sets the flag.

### 6.4 Storage: URAM, loaded at boot

| Object | Size (derived) | URAM288 blocks |
|---|---|---|
| Descriptor table (1,106 steps; 593 A jobs at 64 + 33 x 8 B, rest at 64 B) | ~222 KB | ~7 |
| Norm weight vectors (129 x 5120 x int16) + exponents | 1.29 MB | ~36 |
| B constants: `ssm_norm` 48 x 128, `ssm_dt`/`ssm_a` 48 x 48 each, int16 + exps | ~21 KB | ~1 |
| **Total** | **~1.53 MB** | **~44 of 320 (13.8%)** |

URAM is otherwise unused at 27B: B's state cannot be URAM-resident (37.75 MB
per card against 14.2 MB on-chip, B §4.1), and no other subsystem claims it.
Choosing URAM keeps D entirely off the HBM interconnect -- zero ports, zero
arbitration entanglement, deterministic fetch. The host loads all three
objects through the boot aperture (§9.3). FALLBACK if URAM is ever claimed:
the table and norm weights move to HBM and D takes one dedicated read port
(traffic ~1.5 MB/token = ~4 us at HBM rates -- noise); the port-grant story
of §8 gains one static entry.

B's constant read ports (`sn_raddr/sn_rdata/sn_exp`, `dt_rdata`, `a_rdata`,
O17) are served from the B-constants URAM block, offset by `ordinal` from
the descriptor.

## 7. D-vec: the elementwise unit D inherits

### 7.1 FINDING: D is not DSP-free, and this section is why

The task brief for a "sequencer" implies ~0 DSP. **D-ctrl is 0 DSP.** But B
§1.3 and C §1.3 assigned the norms and residual adds to D, and swiglu is
orphaned onto D (§2.2-E) -- and those are multiplies: RMSNorm needs
sum-of-squares, rsqrt, and a per-element `scale_mul`; swiglu needs a sigmoid
ROM interpolation and two multiplies per element. At `LANES_V = 8` (below)
D-vec is an estimated **24-40 DSP48E2** (~1-1.4% of the device). This must
enter the whole-die DSP sum next to A/B/C -- no current co-fit table (B §2.8,
A §15.4c) includes it. The alternative -- declaring a fifth arithmetic
subsystem -- changes the label, not the cost.

### 7.2 Why D-vec must be vectorised (the serial version is a first-order term)

Per layer D-vec touches: 2 norms (2 passes x 5120 each), 2 residuals (2 x
5120 each), 1 swiglu (2 x 8704) = 58,368 element-passes. DERIVED, at
300 MHz over 64 layers:

| `LANES_V` | cycles/token | ms/token | vs a ~34 ms token |
|---|---|---|---|
| 1 | 3.74 M | **12.5** | **+37% -- unacceptable** |
| 4 | 934 K | 3.1 | +9% |
| **8** | **467 K** | **1.56** | **+4.6%** |

A 1-element/cycle unit -- the natural port of the existing `rmsnorm`-class
FSMs -- would silently cost more than subsystem C's entire attention sweep.
`LANES_V = 8` is chosen; the region read ports already deliver 32 elements
per cycle so the feed is free. This is the second finding of this document:
**the elementwise plumbing between subsystems is a first-order latency term
at hidden = 5120 and must be budgeted like a datapath, not like control.**

### 7.3 Structure (pinned) and numeric contract (deferred, deliberately)

Pinned here:

- **Two-pass with an s18 scratch buffer.** Pass 1 computes (norm: sum of
  squares; residual: aligned add; swiglu: `silu(g) * u`) into the scratch
  while folding the unsigned `amax`; pass 2 requantizes scratch -> int16 +
  one exponent with `bfp_pack` semantics and writes the destination region.
  Residual alignment is to the **minimum** of the two operand exponents,
  right-shift-only -- the C §2.1.4 / B §2.1.4 policy, no saturation needed.
- **`rmsnorm.vhd` is reused for arithmetic, not as an entity**: its ports are
  N*16 parallel (at N = 5120 that is an 81,920-bit bus, the exact wall A §5
  prohibits), so D-vec is a streaming reimplementation that must match
  `rmsnorm`'s value semantics (`o_exp = xe + we + Q - shift_total`,
  `rsqrt_q`/RSQRT_ROM, `scale_mul` rounding). Same reuse pattern as B §1.5's
  L2-norm wrapper.
- silu reuses the Q15 sigmoid regeneration B §1.5 already commissions; the
  VHDL `/` stays banned; the three `v1.0-silicon` rules apply (one multiply
  per state, no data through `integer`, constrain at the real clock).

**Deferred**: the full rounding-site table, exponent chain and C reference
for D-vec -- a §2.1-class normative section this document does not contain,
listed first in §15. It must exist before D-vec RTL, for the same reason A
needed §7.4: the residual and norms sit on the residual stream, where an
unpinned rounding site diverges every downstream bit.

## 8. External-memory arbitration

### 8.1 Port assignment (static), grant (job-scoped)

A, B and C are never simultaneously active (O13), so no transaction-level
arbitration exists anywhere in this design. On the FK33's 32 HBM AXI ports:

| Owner | Ports | Basis |
|---|---|---|
| A (weights + scales) | ~23-27, **dedicated** | A §15.1 at `ROWS_IF` 48-58, 1.3x provisioning; final count open with A §14.5 |
| B (2R + 2W) / C (2R + 1W) | **4, muxed** two ways | B §2.5, C §2.7; B and C are never both active |
| D | 0 | descriptors and constants are URAM-resident (§6.4) |
| E | 0 | PCIe, on-chip buffers (E §2.3) |

A's ports are physically dedicated -- no mux, no cost. The four shared ports
carry a 2:1 grant mux (~600 LUT/port estimated) selected by D's grant
register.

### 8.2 The switch rule: port-level outstanding must be zero

Each unit's internal drain-and-flush on `start` (A §7.7 as corrected by
`tb_axi_rd_port`, C §2.7, B §2.7) handles *its own* FIFO hygiene -- D does
not flush anyone's FIFOs (O14). D's distinct hazard is the mux: a unit's
`done` does **not** imply its AXI transactions have retired (A throttles AR
issue against FIFO space and its sub-regions are padded, so ARs for padding
beats can be in flight at `done`; the beats land afterwards). Switching the
grant with reads outstanding would deliver R beats to the wrong master.

**Rule: the grant register may change only when the per-port outstanding
counters (ARs accepted minus RLASTs, AWs accepted minus BRESPs) read zero on
every port being re-granted.** D counts at the port, independent of what any
unit claims. A `grant_stuck` watchdog (outstanding fails to reach zero within
the §10 bound) raises `err` rather than hanging. This is the same
transactions-outlive-the-job mechanism that broke `axi_rd_port` on first
simulation, applied at the seam that test could not see.

Cost when nothing is wrong: zero cycles -- B and C gate `done` on their last
BRESP already, and read drains complete within the drain windows their specs
budget.

## 9. Reset, sequence init, host interface

### 9.1 Cold boot (host-driven order)

1. Bitstream; PCIe/BAR up (host + board flow, out of scope).
2. Host loads the packed weights into HBM; parses every tensor header (A
   §6.4: "the PS parses the header and is authoritative") and generates the
   descriptor table for this card's rank and topology.
3. Host loads descriptor table, norm weights, B constants into URAM (§6.4);
   programs CTRL registers (`ctx_len`, `my_rank`, watchdog bound).
4. Host releases `rst`. D sits in IDLE; all locks FREE; `cur_pos = 0`.

### 9.2 Sequence and token protocol

- **Sequence start**: host sets `seq_init` with the first `go`. Before step 1
  of that token D pulses `kv_seq_rst` (C, resets the v_ref min-folds to +127
  -- O10) and `seq_rst` (B, resets token counter / conv ring / slot-exponent
  registers -- O11), zeroes `cur_pos`, and zeroes the E `seq` counter. The
  host must assert `seq_init` on the same token index on every card (§6.2).
- **Per token**: host writes X + X_EXP, pulses `go`. D walks the table;
  at END_TOKEN it increments `cur_pos`, latches the argmax triple, raises
  `token_done`. `cur_pos >= ctx_len` at `go` aborts with ERR_CTX (C's
  `ctx_len <= MAXCTX` check remains C's own).
- Prefill is teacher forcing, one position per `go` (B §1.2 / C §1.2).

### 9.3 Register map (AXI-Lite / BAR, sketch -- widths and addresses pinned at implementation)

| Offset | Reg | Notes |
|---|---|---|
| 0x00 | CTRL | `go` (W1P), `seq_init`, `abort`, `en` |
| 0x04 | STATUS | `busy`, `token_done` (W1C), `err` (sticky), `err_code` |
| 0x08 | ERR_INFO | failing step index (11 b) + unit id |
| 0x0C | CUR_POS | RO |
| 0x10 | CTX_LEN | RW, per sequence |
| 0x14 | TOPOLOGY | `my_rank`, `n_peers` (informational; the table encodes the topology) |
| 0x18 | X_EXP | embed row exponent, host-written per token |
| 0x1C-0x24 | ARGMAX | token index, value, `y_exp` (RO, valid with `token_done`) |
| 0x28 | SAT_LOG | sticky OR of A `sat_event` + first flagged step index (O23) |
| 0x2C | WDOG | per-job watchdog bound, cycles |
| apertures | X write window; URAM load window (boot only) | |

`abort`: D stops issuing steps, waits for the in-flight unit's `done` or the
watchdog (it cannot safely kill a unit mid-job -- outstanding AXI), releases
grants under the §8.2 rule, returns to IDLE with `err_code = ABORTED`.

## 10. Error and completion semantics

`err` is sticky, cleared by `rst` or by the next successful `go` (the A §7.6
convention). D checks each sub-unit's `err` at its `done` (O18). Policy on
any error: **abort the token** -- latch ERR_INFO, stop issuing steps, do not
advance `cur_pos`, raise `token_done` with `err` set so the host never
hangs. Proceeding past a failed job would compute the rest of the token on
garbage and, worse, would let a corrupted K/V or GDN state write poison every
subsequent token; the host decides whether to re-run the token or reset the
sequence (a failed token has already possibly written KV[cur_pos] / GDN
state, so the safe host recovery is `seq_init` replay -- stated here so it
is not discovered on hardware).

| Condition | Detector | Class |
|---|---|---|
| sub-unit `err` at `done` (all A/B/C/E classes, incl. A descriptor aborts) | D, at each `done` | abort token, ERR_UNIT |
| write strobe to a HELD region | lock (§5.3) | abort token, ERR_LOCK |
| `dst_offset != fill_ptr`, or `dst_offset + n_rows` exceeds region | descriptor check at step issue | abort token, ERR_DESC |
| unknown opcode / `nsub_w > NSUB_MAX` / dst=0xFF without a route flag | descriptor check | abort token, ERR_DESC |
| per-job watchdog expiry (unit never `done`s; E flag timeout is E's own and surfaces as its `err`) | D counter per step | abort token, ERR_WDOG |
| grant switch blocked (outstanding never reaches 0) | §8.2 counters | abort token, ERR_GRANT |
| `go` with `cur_pos >= ctx_len` | D | refuse at `go`, ERR_CTX |
| A `sat_event` at `done` | D | **not an error**: log to SAT_LOG, continue (A §14.2 -- policy on saturation is calibration-level, host-owned) |

Every descriptor-class check runs at step issue, before the unit starts --
the same "check at `start`, abort before output" discipline as A §7.6.

## 11. Timing budget (informative, derived -- nothing here is measured)

Per token per card, N=2, 27B, at the §15.4c "balanced" point
(`ROWS_IF ~ 58`, C `MACS = 192`, 276-300 MHz):

| Component | ms | Basis |
|---|---|---|
| A jobs (weights, 7.57 GB/card) + C | ~34 | A §15.4c balanced row (measured-OOC-anchored derivation) |
| B state sweeps | ~2.0 | derived: 128 x 128 x 24 vheads x 48 layers / 32 lanes at 300 MHz; B's own §2.5 aux latencies NOT included (B §3 unwritten) |
| E collectives | ~0.42 | E §2.4, N=2 |
| D-vec at `LANES_V = 8` | ~1.6 | §7.2 |
| D-ctrl step overhead | ~0.1 | 1,106 steps x ~20-30 cycles (descriptor decode is prefetched; grant switches are usually free) |

Roughly **~38 ms => ~26 tok/s at N=2**, consistent with the recon ladder's
lower band. The B row and the D-vec row are the two entries no other document
carries; both are derived, unsynthesised, and B's is a floor (its §3
scheduling may add). This table exists so the whole-token sum finally
includes the seams; it is not a promise.

## 12. Resource cost (ESTIMATES -- no D RTL has been synthesised)

| Resource | D estimate | What it is, and what is approximate about it |
|---|---|---|
| DSP48E2 | **24-40** (D-ctrl: 0; D-vec: all of it) | §7.1 finding. Depends on `LANES_V` (8 assumed) and on whether swiglu shares the norm lanes (phases are disjoint, so sharing is expected; 40 is the no-sharing bound). |
| LUT | **~18-28K** (~4-6% of 439,680) | Muxing dominates and is the soft part: A's x-port 512-bit read mux from ~3 regions plus y-route (~4-6K), region write decoders and lock logic (~3-5K), 4 shared-port AXI grant muxes (~2.5K), D-ctrl FSM + descriptor decode (~3-5K), D-vec datapath + shifters (~5-8K). Approximate because port shapes B/C elided ("...") are guessed, and no mux has been synthesised. |
| FF | ~15-25K | pipeline + capture registers + counters; unsynthesised |
| BRAM36 | **~86 flat map** (80 regions + ~6 scratch), of which ~16 replace A's standalone act mem (§5.1); **~54 packed** | Bank counts derived from the striped geometry; the flat/packed choice is open until whole-die BRAM is summed. C's ~43 and A's FIFOs are separate. |
| URAM288 | **~44 of 320** | §6.4, derived from table/constant sizes; grows with `NSUB` if A §14.5 lands above 33 bases/job |
| HBM ports | 0 dedicated (URAM-resident constants); +1 if the §6.4 fallback triggers | |

**Whole-die context (informative, rough, first time anyone has summed it):**
DSP: A at `ROWS_IF = 58` post-reclaim 1,914 + C `MACS = 192` 384 + B
`LANES = 32` 138-152 + D 24-40 = **~2,460-2,490 of 2,880 (85.4-86.5%)** --
D pushes the known ~85-86% up by ~1%, still under the 90% congestion line
both B §2.8 and C §2.8 cite. LUT: A ~129K (58 x 2,223 measured/row) +
streamer (unmeasured at FK33 scale, ~10K?) + C ~41K accumulators (measured
fit) + C arrays/control (~15K?) + B 25-35K (estimate) + D 18-28K + E ~5K
(guess) = **~245-265K of 439.7K (~56-60%)** -- but three of those terms have
never seen synthesis, so treat the LUT sum as a screening number, not a
budget. It is recorded because the task brief is right that nobody had
computed it; it says "probably fits with margin", and it says it weakly.

## 13. REQUESTS to other subsystems (needed by D, not currently provided -- to be negotiated, not assumed)

| # | To | Request | Why |
|---|---|---|---|
| R1 | A | A weight-**preload** mechanism: accept the next job's descriptor and begin AR issue/FIFO fill while the previous consumer phase completes (or, minimally, a deeper prefetch FIFO budget), separable from `start` | E §2.5's overlap requirement is not implementable by scheduling alone (§2.2-K). Not needed at N=2; blocking for v4.0's ~34% overhead figure. |
| R2 | A | Widen the §5 `y_data` port declaration to the s48 partial-mode payload (the wrapper already stores 64 bits) | §2.2-D: internal A inconsistency; D and E both need the real width. |
| R3 | B | Pin the elided port shapes: `qkv/z/b/al` read-port widths and whether their access windows are temporally disjoint | D hard-wires five region read ports (§5.2) and could merge regions if reads never collide; currently guessed from "block-wide, 1.5". |
| R4 | C | Same for the `qg/k/v` pre-quantize reads (are they sequential?) | KIN/VIN could share a region if so. |
| R5 | E | Carry the sender's `y_exp` (and the s48 payload width) in the transport, and confirm `seq` is supplied externally by D per §6.2 | §2.2-C: E's §2.1/§2.6 predate A's corrected partial contract; E cannot be built, and D's E_COLL descriptor cannot be frozen, until E revises. |
| R6 | A | Confirm an idle `matvec_int4` issues no ARs before `start` (assumed from the §7.7 state machine) | The §8.2 grant rule relies on it; one sentence in A's spec closes it. |
| R7 | B §2.7 | Correct "A x3 -> C -> A x3" to C §2.7's order | §2.2-A; editorial but it is exactly the restated-rule divergence class C's process rules ban. |

## 14. Validation and bring-up (outline)

1. **Stub-level GHDL**: behavioural A/B/C/E stubs with programmable latency,
   `err` injection and scripted `y` streams. Asserts: full 64-layer walk in
   table order; every lock transition; append-only fill enforcement; exponent
   capture-at-done (a stub that changes `y_exp` after `done` must not be
   seen); abort/watchdog paths; the §8.2 grant rule against a stub that
   leaves ARs outstanding past `done` (the class `tb_axi_rd_port` caught).
2. **Descriptor generator + checker**: the host-side generator emits the
   table from tensor headers; an independent checker replays the §4
   microprograms and diffs. Two generators, byte-identical tables (the A
   §6.4 cross-check trick).
3. **Token-level co-simulation**: D-ctrl + the real unit C references
   orchestrated by a `ref/` generate loop (the `seq_ctrl`/`run_fx.c`
   pattern); token stream bit-exact vs the reference, N=1 table and N=2
   tables (the N=2 co-sim models E as the reference reduction).
4. **N=1 silicon first**: a reduced-model single-card build exercises every
   D mechanism except E routing before any two-card work -- which is the
   point of §4.4.
5. D-vec gets its own §2.1-class contract and bit-exact tests before RTL
   (§15 item 1).

## 15. Open, not yet answered

1. **D-vec's numeric contract does not exist yet.** §7.3 pins structure and
   reuse; the rounding-site table, residual exponent chain, swiglu Q-format
   and the C reference are unwritten. Gating for D-vec RTL, exactly as B §3
   gates B.
2. **The "attn_post_norm" placement is assumed** (§2.2-I) and must be
   verified against `qwen35.cpp`'s 27B layer builder before the table
   generator is written. If an extra norm exists, step counts and the URAM
   norm-weight budget change.
3. **The A-job descriptor width is open with A §14.5** (lane/port structure,
   `NSUB`). The table format reserves for it; the URAM figure moves with it.
4. **The E seam is blocked** on A §15.4b / R5. D's E_COLL fields are
   provisional.
5. **Whether the flat or packed region map ships** awaits a whole-die BRAM
   sum with real (synthesised) numbers from A's FK33 streamer, B and C.
6. **No D number is measured.** Every LUT/FF/DSP/BRAM figure in §12 is an
   estimate; the §11 token budget composes other specs' derivations with two
   new derived rows (B at 27B, D-vec). First OOC synthesis of the region
   bank + mux fabric and of one D-vec lane group is the cheapest way to
   convert the two riskiest estimates, and should happen before the region
   map is frozen.
7. **Host-in-loop latency is assumed negligible** (§3.2). Measure the
   per-token BAR write + register round trip on the first FK33 before
   committing; the on-chip embed-fetch unit (a ~1-DSP dequant of one packed
   row into X) is the designed fallback and would also remove the host from
   the steady-state loop entirely if autonomous multi-token generation is
   ever wanted.
8. **Abort recovery on shared state** (§10): a failed token may have written
   KV[cur_pos] and GDN state before aborting. The stated host recovery is
   sequence replay; a cheaper token-granular recovery (roll back `cur_pos`
   and rely on overwrite semantics) is plausible for C's append-only cache
   but NOT for B's read-modify-write state, and has not been designed.
9. **Two-card lockstep is by rendezvous only** (§6.2): the `seq` counters
   stay equal because the tables are identical and E blocks. Power-on
   mismatch, one-card abort, or divergent tables produce an E timeout, not a
   diagnosis. A cross-card table checksum exchanged at `seq_init` (through
   E's flag mechanism) would convert that to a clean error and costs almost
   nothing; not yet specified.
