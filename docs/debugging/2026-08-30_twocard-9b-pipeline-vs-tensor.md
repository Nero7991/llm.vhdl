# Two FK33s for the 9B: is it easy, and is it pipeline or tensor?

Date: 2026-08-30. TRACK TWOCARD. **Analysis only. No hardware was touched at
any point, and no Vivado was run** (both Vivado lanes were held by TRACK
TIMING). Every area number below is read out of a report already on disk;
every memory number is produced by importing `tools/hbm_map.py` and calling
`arena_sizes()`, which is pure Python.

Repo SHA at the start of this track: `494f8817cd0e93a7e6b53a15d9e7bfd8d4c26dc7`
(`git rev-parse HEAD`, run as its own step).

---

## The question, verbatim

> "let's look at the two card solution for running the 9B model if it easy to
> fit in two. The MCIO dual card thing is here"

---

## The answer, up front

**No, it is not easy, and the specific reason is worse than "it is a big
project": the cheap version of two cards does not solve the problem it would be
bought for.** For the 9B the binding constraint is CLB area, not HBM capacity,
and area is set by the datapath's WIDTH (MACs and lanes), not by the layer
count, because the engine is one physical A, B, C and D time-multiplexed over
all 32 blocks. Pipeline parallelism splits the layer count, so it removes
**4.0%** of the per-card area and leaves the design at **116% of the die**
(DERIVED, section 2.3). It also delivers zero speedup, because a single
autoregressive token cannot occupy both halves of a pipeline at once. Tensor
parallelism does shrink the datapath, but only in the configuration that gives
up the speedup: **TP at half width lands at 88.9% CLB and roughly 57 tok/s,
which is exactly what ONE card would give if it fitted**; TP at full width is
2x faster and is still at 120% of the die. The single biggest cost, though, is
not any of that. It is that **two cards for the 9B would be spent on an area
problem that has an identified, unexecuted, FREE single-card fix worth 76,156
LUT** (the two URAM moves TRACK TIMING named), and nobody has tried it yet.

**The one thing two cards genuinely and uniquely buys the 9B is context.** At
262,144 tokens the 9B needs 9.625 GB against 8 GiB and does **not** fit one
card; one card tops out near **202,681 tokens** (DERIVED, section 1.2). If full
context is a product requirement, that is a real reason for N=2 and it is
independent of every area argument here.

---

## 0. Corrections to the brief, and to the documents it rests on

Recorded first because three of them change what follows.

**C1. `docs/2026-08-25_single-card-fallback-decision.md` line 24 is wrong about
the 9B fitting one card.** It says "5.1 GB of 8 GiB, **yes**, ~2.9 GiB spare".
That row counts weights only. Adding the KV cache at the model's own
`max_context` of 262,144 puts the 9B at 9.625 GB against 8.590 GB. The row
should read "yes below ~202k context, no at 262k". The same document's whole
framing of two cards as being about 27B capacity therefore also applies to the
9B, just at a different context length.

**C2. The E spec's central UNKNOWN U1 is RETIRED.**
`docs/superpowers/specs/2026-08-27-E-tp-collective-skeleton.md:101` lists
"whether an FK33 enumerates on PCIe at all" as the cheapest open question in
the project. It is answered: an FK33 is enumerated and doing XDMA transfers
today. MEASURED, commit `97aed66` (2026-08-30): a C2H DMA cost sweep on the
card, "~7.5 us fixed, flat to 1 KB", 8.37 us at 4 KB, peak ~1.5 GB/s at 64 KB.
That is a live PCIe link, not a model. U3 (negotiated width) is also settled by
construction: the shell requests **Gen3 x4** (section 4.1).

**C3. The brief's premise that the interim MCIO hardware makes pipeline "the
only one the present hardware can run" is TRUE but does not favour pipeline.**
It is true: `~/GitHub/pcie-llm-hardware/docs/03-interim-mcio-bringup.md` is
explicit that the interim setup does **not** provide a card-to-card peer link,
so every inter-card byte goes through the host. It does not favour pipeline,
because pipeline solves nothing that the 9B needs solving. Being the only
runnable option is not an argument when the option delivers no benefit.

**C4. Both FK33s physically exist and both work.** MEASURED,
`docs/debugging/2026-08-29_second-fk33-verify-and-flash-backup.md`: card 1 s/n
153300000607 and card 2 s/n 153300001366, the second verified 2026-08-29
self-configuring from its own factory flash with `CFG_DONE 1` and every
`BOOT_STATUS` error bit clear. Card 2 was on USB JTAG and aux power, **not in a
slot**. So "two cards in hand" is not an assumption; "two cards in slots
simultaneously" still is.

**C5. The `pcie-llm-hardware` README's status line "Subsystems C, D and E have
no RTL" is stale** (written 2026-08-26). C is `rtl/attn_block.vhd` at 85,592
LUT synthesised and placed; D is five `seq_*` units plus `ooc_normadapt`. Only
E still has no RTL.

**C6. The MCIO doc's "each at PCIe x8 over cable" will not happen with the
current bitstream.** The shell requests x4 (`hw/fk33/gen_pcieep.py:1555`). The
slot and the cable can be wider; the endpoint will train x4. Separately, that
doc already notes PCIEX16 runs at x8 today because the Samsung root NVMe holds
`M2C_CPU`, so bifurcation gives x4/x4. At an x4 endpoint that costs nothing.

---

## 1. The 9B, measured

### 1.1 Shape

MEASURED, `rtl/model_cfg_pkg.vhd:64-70` (`QWEN35_9B`) and the derived functions
at `:112-150`:

```
blocks 32, attn_interval 4   ->   8 attention layers, 24 GDN layers
hidden 4096, ffn 12288
lin_key_heads 16, lin_val_heads 32, lin_head_dim 128, conv_kernel 4
attn_q_heads 16, attn_kv_heads 4, attn_head_dim 256
vocab 248320, max_context 262144
NCARDS = 1                       (rtl/model_cfg_pkg.vhd:91)
```

The layer pattern is every 4th block attention, so an even split by index gives
each half **4 attention and 12 GDN layers**. The brief's worry is confirmed:
**an index split leaves both halves needing both B and C.**

### 1.2 Memory, and the context ceiling nobody has stated

MEASURED, by importing `tools/hbm_map.py` and calling
`arena_sizes(scrape_model_cfg("QWEN35_9B"), n)`:

| | N=1 | N=2 | N=4 |
|---|---:|---:|---:|
| `kv_bytes_per_token` | 17,408 | 8,704 | 4,352 |
| `gdn_state_bytes` | 25,264,128 | 12,632,064 | 6,316,032 |
| `val_heads_per_card` | 32 | 16 | 8 |
| `kv_heads_per_card` | 4 | 2 | 1 |

Weights, all params at 4.5 bpw: **5.0364 GB** (DERIVED, and taken from
`docs/2026-08-27_9b-single-card-resource-envelope.md:638`, which corrects
`rtl/model_cfg_pkg.vhd:82`'s "about 4.5 GB" as 11% low).

DERIVED, at the model's own `max_context` of 262,144:

```
KV        = 17,408 B x 262,144        = 4,563,402,752 B = 4.5634 GB
weights                               = 5,036,400,000 B = 5.0364 GB
GDN state                             =    25,264,128 B = 0.0253 GB
                                        ----------------------------
total per card at N=1                              9.6251 GB
8 GiB                                              8.5899 GB
                                        OVER BY    1.0352 GB
```

```
max context on one card = (8.5899e9 - 5.0364e9 - 0.0253e9) / 17,408
                        = 3,528,200,000 / 17,408
                        = 202,681 tokens          (DERIVED)
```

and that leaves nothing for descriptors, activations or the host blocks, so the
usable figure is somewhat under 200k.

At N=2 (either parallelism, since both halve the KV): 2.5182 + 2.2817 + 0.0126
= **4.8125 GB**, fitting with 3.78 GB spare.

**So the 9B does have a genuine capacity reason for two cards. It is context,
not weights, and it appears only above ~200k tokens.** Note this is a different
statement from the `pcie-llm-hardware` README's N=4 argument, which is 27B
arithmetic and must not be carried over: the 9B has 8 attention layers where
the 27B has 16, so its KV per token is exactly half.

### 1.3 Sharding divisibility at N=2 and N=4

Checked against `rtl/llama_map_pkg.vhd:176-189` (`mk_shape`) and
`tools/hbm_map.py:377-384`, both of which REFUSE rather than round:

| quantity | N=1 | N=2 | N=4 |
|---|---:|---:|---:|
| `attn_q_heads` 16 | 16 | 8 | 4 |
| `attn_kv_heads` 4 | 4 | 2 | **1** |
| `lin_val_heads` 32 | 32 | 16 | 8 |
| `lin_key_heads` 16 | 16 | 8 | 4 |
| `vocab` 248,320 | -- | 124,160 | 62,080 |

All divide cleanly at both N. **N=2 is easier than the README's N=4 case and
raises no new sharding question**: 4 KV heads to 2 is comfortable, where the
README's "4 KV heads makes N=4 the natural TP ceiling" is about the 27B hitting
1 KV head per card. The 9B hits 1 KV head per card at N=4 too, so N=4 is its
ceiling as well, for the same reason.

---

## 2. Area: the crux, answered with the per-subsystem numbers

### 2.1 What the composed design actually costs, by subsystem

MEASURED, `report_utilization -hierarchical` on the composed A+B+C+D synthesis,
raw artefact
`hw/fk33/results/compose4_2026-08-29/util_hier_c4_synth.rpt` (Vivado 2023.2,
part `xcvu33p-fsvh2104-2L-e`, design state Synthesized):

| instance | module | LUT | FF | RAMB36 | DSP |
|---|---|---:|---:|---:|---:|
| `a_eng` | `fk33_engine` (A) | **134,633** | 63,704 | 192 | 1,585 |
| `b_gdn` | `gdn_block` (B) | **75,181** | 52,470 | 36 | 253 |
| `c_attn` | `attn_block` (C) | **85,592** | 101,046 | 3 | 298 |
| `d_norm` | `ooc_normadapt` (D) | **48,501** | 133,169 | 0 | 41 |
| `d_vres` `d_lock` `d_fetch` `d_opdec` `d_viss` | `seq_*` (D) | 6,376 | 5,079 | 0 | 0 |
| | **`compose4_top`** | **350,283** | 355,468 | 231 | 2,177 |

The four subsystem rows sum to 350,283 exactly, and the DSP column sums to
2,177 exactly, so nothing is unaccounted for.

Placement took 350,283 to 346,971 LUT at **54,866 of 54,960 CLB = 99.83%**,
packing density **6.32 LUT per CLB** (MEASURED / DERIVED,
`docs/debugging/2026-08-30_timing-composed-a-b-c-d.md:415-425`). The honest
total for a build that can actually run adds the shell and the norm gain image:

```
composed, placed, MEASURED                       346,971 LUT
+ FK33 shell, DERIVED (171,458 - 131,132)         40,326 LUT
+ real NORM_W_IMAGE, MEASURED (best of 6 draws)   32,943 LUT
                                                 -----------
                                                 420,240 LUT = 95.6% of 439,680
at the measured 6.32 LUT/CLB                      66,494 CLB = 121% of 54,960
```

**Caveat carried forward, and it is load-bearing.** The 32,943 is the BEST of
six draws of the norm gain ROM; `docs/debugging/2026-08-30_scatter-per-draw-area-variance.md`
records that root spanning **82,597 to 128,065** (1.55x) and rules that "no
single number may be quoted; report the range or nothing". So the honest
single-card total is **420,240 to 465,708 LUT**, and everything below that
carries a norm-image term inherits that range. Every comparison in this
document uses the best draw for every configuration, so the COMPARISONS are
fair even though the absolutes are optimistic.

Second caveat, from the brief and confirmed: the 121% is a projection. The
346,971 placed; the shell and the norm image were measured elsewhere and added.
That projection is under adversarial review. **Section 2.5 states which
conclusions here survive if it is overturned.**

### 2.2 Why layer count does not set area: the engine is time-multiplexed

This is the mechanism the whole pipeline-vs-tensor answer turns on, and it is
readable directly out of the hierarchy report.

MEASURED, the depth-2 rows under `c_attn` in the same report: there are exactly
**four** `gen_head[i]` instances, one per **KV head** (`N_KVH = 4`), and exactly
**one** `u_arr` (`attn_mac_array`, 55,854 LUT, 256 DSP). There is no
per-attention-layer replication anywhere. `rtl/attn_block.vhd:225` says what
`LAYERS` is for in its own words: `LAYERS : positive := 8; -- attention layers,
for the cache map`. The only structure it sizes is `vref_r`, which
`docs/debugging/2026-08-30_timing-composed-a-b-c-d.md:57` measures at
`LAYERS * N_KVH * EXP_W = 8 * 4 * 8 = 256 bits`.

Same for B: `rtl/gdn_block.vhd:194` reads `LAYERS : positive := 24; -- GDN
layers, for the exponent store`, and the exponent store is `u_exp`
(`gdn_exp_capture`) at **844 LUT** of B's 75,181.

**So one physical A, B, C and D execute all 32 blocks in sequence. Halving the
layer count removes about 1,100 LUT of state arrays out of 350,283.** Every
other LUT is set by `MACS`, `RECUR_LANES`, `SILU_LANES`, `L2_LANES`,
`CONV_LANES`, head counts and `HEAD_DIM`.

### 2.3 Pipeline parallelism, split by layer index

Card A takes blocks 0-15, card B takes 16-31. Both halves contain 4 attention
and 12 GDN layers, so both need the full A, B, C and D.

What actually leaves a card (DERIVED):

| term | saving |
|---|---:|
| `NORM_W_IMAGE`, half the layers' gains | -16,472 |
| `attn_block` LAYERS 8 to 4, `gdn_block` LAYERS 24 to 12 | ~-500 (ESTIMATE) |
| everything else | 0 |

```
420,240 - 16,472 - 500 = 403,268 LUT per card
403,268 / 6.32         =  63,808 CLB = 116.1% of 54,960
```

**Pipeline by index removes 4.0% of the per-card area and the design still does
not fit, by 16%.** It costs a second card and a split of the D descriptor
program across two sequencers to achieve that.

### 2.4 Pipeline parallelism, split by TYPE, which the brief did not raise

The obvious repair: put all 24 GDN layers on card A and all 8 attention layers
on card B, so each card drops a whole subsystem. Both still need A, because
every block of both kinds is mostly matvecs.

DERIVED, using the section 2.1 rows and splitting the norm image roughly 48:17
by norm-vector count:

```
card A = a_eng 134,633 + b_gdn 75,181 + D 54,877 + shell 40,326 + norm ~24,300
       = 329,317 LUT  ->  52,107 CLB  =  94.8%
card B = a_eng 134,633 + c_attn 85,592 + D 54,877 + shell 40,326 + norm ~8,643
       = 324,071 LUT  ->  51,277 CLB  =  93.3%
```

**Better than the index split and still above the 90% line that the composed
design's congestion level 7 says is the real limit.** It also costs 16 card
crossings per token instead of 1 (the pattern is GDN,GDN,GDN,ATTN repeating, so
control leaves and returns at every attention layer), and it leaves card B idle
75% of the time and card A idle 25%.

**MEASURED and REJECTED. Do not retry either pipeline split as an area fix.**

### 2.5 Tensor parallelism, and the two operating points it has

TP splits heads and FFN columns, which is what the RTL was actually
parameterised for: `rtl/llama_map_pkg.vhd:182-189` divides `key_heads`,
`val_heads`, `attn_q_heads` and `vocab` by `ncards`, and
`rtl/attn_block.vhd:206` states the intended N=2 set in its own header.

There are two distinct configurations and conflating them is how this question
gets answered wrong.

**TP-fast: keep the full datapath width.** Each card holds half the weights and
reads them from its own HBM concurrently, so the weight-stream floor halves.
Only the head-count-dimensioned logic shrinks: the four `gen_head[i]` pairs
(4,210 LUT to 2,105), `attn_kv_quant` (7,329 to ~3,665), and B's LUTRAM staging
in its own glue (6,120 LUTRAM to ~3,060). DERIVED:

```
420,240 - ~8,830 + ~5,000 (subsystem E) = 416,410 LUT
                                        ->  65,888 CLB = 119.9%
```

**TP-fast is 2x faster and does not fit, by 20%.**

**TP-small: halve the datapath width too.** Each card does half the arithmetic
per layer, so half the MACs and half the lanes keep the same schedule. ESTIMATE,
built leaf by leaf from the section 2.1 depth-2 rows, with the assumption named
on every line:

| term | N=1 MEASURED | N=2 | assumption |
|---|---:|---:|---|
| `matvec_core` | 120,573 | ~60,300 | `MACS` halves |
| `weight_streamer` + `dfetch` + A glue | 14,060 | 14,060 | **invariant**: 27 HBM read masters exist to saturate this card's own HBM, and that does not change |
| `gdn_recur_pipe` | 27,842 | ~13,900 | `RECUR_LANES` 32 to 16 with the state sweep |
| `gdn_emit_chain` | 21,710 | ~16,000 | conservative: `gdn_emit_chain`'s own header says 8 lanes misses B's Fmax, so 16 to 8 may be illegal |
| B conv / l2 / silu / scalar / exp | 18,002 | 18,002 | invariant: per-head-dim, not per-head-count |
| B glue | 7,631 | ~4,600 | LUTRAM staging halves |
| `attn_mac_array` | 55,854 | ~27,900 | `MACS` 128 to 64 |
| C per-KV-head units | 11,539 | ~5,770 | `N_KVH` 4 to 2 |
| C norm / rope / twiddle / gate / emit / glue | 18,199 | 18,199 | invariant: `HEAD_DIM` 256 does not shard |
| `d_norm` | 48,501 | 48,501 | **invariant**: `rmsnorm_rs` at N=4096 runs on the full reduced vector on every card |
| `seq_*` | 6,376 | 6,376 | invariant |
| shell | 40,326 | 40,326 | invariant |
| `NORM_W_IMAGE` | 32,943 | 32,943 | **invariant**: the gains are full `d_model` and are not sharded |
| subsystem E | 0 | ~5,000 | GUESS, `docs/debugging/2026-08-25_lut-budget-measured.md:36` |
| **total** | **423,556** | **~311,900** | |

**Read the basis of that table carefully.** Its leaves are SYNTHESIS rows, so
the N=1 column sums to 423,556, not to the 420,240 headline. The 3,316 LUT
difference is exactly the placement shrink (350,283 synth to 346,971 placed);
the headline uses the placed figure and this table cannot, because no
per-instance decomposition of the placed netlist exists (trap T1). Applying the
same 0.99 factor to the N=2 column for consistency:

```
synthesis basis : 311,900 / 6.32 = 49,351 CLB = 89.8% of 54,960
placed basis    : 308,900 / 6.32 = 48,877 CLB = 88.9% of 54,960
```

Both land within a point of the 90% line, which is the finding; the 0.9 point
between them is not.

**TP-small fits, and only just, landing exactly on the 90% line the composed
design's congestion says is the real target.**

Note the floor this exposes. The invariant rows total **133,146 LUT = 21,067
CLB = 38.3% of the die** and no amount of TP removes them. N=4 would land near
217,000 LUT = 62%. TP saturates fast.

**DSP is not binding at the 9B, contrary to the 27B figure.** MEASURED, 2,177
of 2,880 = 75.6% at N=1, against the 90.5-91.9% that
`docs/2026-08-25_single-card-fallback-decision.md:78-83` records for 27B at
N=2. TP-small takes it to roughly 1,240 = 43%.

### 2.6 The comparison, on one page

At the best norm-image draw throughout, so the columns are comparable even
though the absolutes are optimistic:

| configuration | LUT/card | CLB | fits? | tok/s floor | what it buys |
|---|---:|---:|---|---:|---|
| **one card** | 420,240 | 121% | **no** | 57.2 | -- |
| one card + the two URAM moves | 344,084 | 99.1%* | **not yet** | 57.2 | free, unexecuted |
| **PP by index, N=2** | 403,268 | 116% | **no** | 57.1 | context |
| **PP by type, N=2** | 324-329k | 93-95% | **no** | 57.1 | context |
| **TP-fast, N=2** | 416,410 | 120% | **no** | 112 | context, speed |
| **TP-small, N=2** | ~308,900 | 88.9% | **yes, just** | 57.2 minus the collective | context, and a FIT |

\* the URAM row's CLB is computed at the unchanged 6.32 density and is therefore
pessimistic: the two moves also delete 26,432 of the design's 90,896 MUXF7/F8
pairs (`docs/debugging/2026-08-30_timing-composed-a-b-c-d.md:524-529`), and it
is exactly those indivisible shapes that pushed density from the architectural
8 down to 6.32. How much density recovers is unmeasured and is the single most
valuable unknown on this page.

**The sentence that answers the question.** The two-card configuration that
fits (TP-small) is no faster than the single card would be if IT fitted, and
the two-card configuration that IS faster (TP-fast) does not fit either. Two
cards therefore buy the 9B a FIT and a CONTEXT, not speed. And the fit may be
available for free on one card.

### 2.7 If the 121% fit claim is overturned

Stated because the brief says it is under review. Which conclusions depend on
it:

- **DEPENDS.** "One card does not fit", and therefore the entire framing of two
  cards as an area solution. If the composed design plus shell plus norm image
  actually places, the area argument for two cards evaporates completely and
  only the 262k-context argument survives.
- **DOES NOT DEPEND.** That pipeline parallelism saves only 4.0% of per-card
  area. That is arithmetic on the layer-count-dependent terms and holds at any
  absolute total.
- **DOES NOT DEPEND.** That pipeline parallelism gives zero throughput gain for
  single-stream decode (section 3.1).
- **DOES NOT DEPEND.** The 202,681-token single-card context ceiling.
- **DOES NOT DEPEND.** That the interim MCIO hardware provides no peer link.

---

## 3. Throughput: the argument the brief did not make, and it is decisive

### 3.1 Pipeline parallelism gives zero speedup for single-stream decode

Token t+1 depends on token t, and within one token, block 16 depends on block
15. So under a pipeline split card B cannot start until card A has finished.
Per token:

```
T_pp   = T/2 (card A) + T/2 (card B) + handoff  =  T + handoff
```

Each card is idle 50% of the time. **Two cards, the same wall time as one, plus
a handoff.** The idle half becomes useful only with two or more concurrent
sequences in flight, and there is no batching anywhere in this design: the
sequencer's `seq` is `token_index x steps + ...`, one token at a time, and
`server/llama_server.cpp` is single-stream.

Tensor parallelism has no such problem: both cards work on the same token at
the same time on different heads and columns.

### 3.2 The floors, at the MEASURED 288.0 GB/s

Weight-stream floors only, pure bandwidth. **288.0 GB/s is the measured usable
HBM read figure, superseding the refuted 460.8 GB/s; it is NOT what the engine
achieves today**, which is 7.39-7.88 GB/s because of the single-pseudo-channel
packer bug TRACK PACKSTRIPE is fixing. Treat these as ceilings for comparing
schemes, not as predictions.

```
one card      : 5.0364 GB / 288.0 GB/s = 17.49 ms = 57.2 tok/s
N=2 per card  : 2.5182 GB / 288.0 GB/s =  8.74 ms
```

---

## 4. The interconnect, costed on all three transports

### 4.1 What is physically here, and what it can carry

MEASURED, `hw/fk33/gen_pcieep.py:33-46` and `:1546-1556`: the shipping shell is
**Gen3 x4 on GTY quad 227 (edge lanes 0-3)**, and quads **226, 225 and 224
(edge lanes 4-15, twelve channels) are deliberately left free for Aurora**. The
lane-to-quad map is stated as verified against Vivado's own
`xcvu33p_fsvh2104.pkg` rather than assumed. This is not a comment: it is
enforced by a gate, `hw/fk33/check_pcieep_xdc.py:153`, which fails the build if
the width is not x4 and the Aurora quads are not free.

**So the x4-host / 12-lane-Aurora split from `~/GitHub/pcie-llm-hardware` is
already done on the card side.** What does not exist is any Aurora RTL: `grep
-rni aurora rtl/ hw/fk33/rtl/` returns only the comments above, and there is no
`gtwizard` or `GTYE4` instantiation anywhere in the design sources.

What arrived is the interim MCIO bring-up, and its own document is explicit:

> **Does not:** the card-to-card peer link. That needs a TX/RX crossover which
> no vendor stocks, and the backplane exists precisely to avoid needing one.

**So on the hardware that is physically here there is no card-to-card path at
all.** Both cards can be enumerated by the host simultaneously; every
inter-card byte goes host-mediated.

### 4.2 Message sizes for the 9B

DERIVED from the E spec's method at the 9B shape:

| scheme | messages per token | bytes per message |
|---|---:|---:|
| TP, either width | 2 per block x 32 blocks = **64** | 4096 rows x 8 B = **32,768** (+12 B trailer) |
| PP by index | **1** | 4096 x 16-bit mantissa + exponent ~ **8,192** |
| PP by type | **16** | ~8,192 |

Note TP's message is 32 KB, not the E spec's 40,960 B: that figure is `d_model`
5120 for the 27B, and the 9B's `d_model` is 4096.

### 4.3 Host-mediated, which is the only transport that exists today

MEASURED, commit `97aed66`: XDMA C2H on this card costs **~7.5 us fixed per
call**, flat from 64 B to 1 KB, 8.37 us at 4 KB, peaking near 1.5 GB/s at
64 KB. DERIVED per transfer, assuming H2C matches C2H:

```
32 KB : 7.5 us + 32,768/1.5e9 = 29.3 us   ->  round trip 58.6 us + t_sw
 8 KB : 7.5 us +  8,192/1.5e9 = 13.0 us   ->  round trip 25.9 us + t_sw
```

`t_sw` is the host software round trip, UNMEASURED here; the E spec's band is
5 us (dedicated spin-polling core) to 60 us (interrupt plus thread wakeup).

| scheme | per token | vs its own budget |
|---|---:|---|
| TP, `t_sw` = 5 us | 64 x 63.6 us = **4.07 ms** | 47% of TP-fast's 8.74 ms |
| TP, `t_sw` = 30 us | 64 x 88.6 us = **5.67 ms** | 65% |
| TP, `t_sw` = 60 us | 64 x 118.6 us = **7.59 ms** | 87% |
| PP by index, `t_sw` = 30 us | 1 x 55.9 us = **0.056 ms** | 0.3% of 17.49 ms |
| PP by type, `t_sw` = 30 us | 16 x 55.9 us = **0.89 ms** | 5.1% |

**The brief's instinct was right and the numbers back it: host-mediated tensor
parallelism costs 47% to 87% of the budget it was meant to halve.** TP-fast
host-mediated lands at 8.74 + 4.07..7.59 = **12.8 to 16.3 ms = 61 to 78
tok/s**, against one card's 57.2. A 1.07x to 1.37x gain for two cards, two
slots and a burnt host core.

**And the whole of that cost is per-call overhead, not bytes.** Of the 58.6 us,
15.0 us is fixed DMA call overhead and 43.6 us is transfer at 1.5 GB/s; add
`t_sw` and the byte term is a minority everywhere. The 64 collectives are
strictly sequential through the layers, so they cannot be batched.

### 4.4 PCIe peer-to-peer between the two cards

UNVERIFIED, and the project's own documents disagree about whether it can even
be tested here. On the MCIO setup both cards hang off a bifurcated PCIEX16,
i.e. **sibling CPU root ports**, which `~/GitHub/pcie-llm-hardware/docs/00-rationale.md`
explicitly rejected: "peer traffic still has to traverse the root complex. Not
the 'common switch' the spec requires, and still an unmeasured premise."
`docs/fpga-hardware-recon.md:722-740` proposes the two chipset x4 slots instead
as "probably the better test". Neither has been measured. `docs/fpga-hardware-recon.md`
also flags "Intel root-port P2P latency is unmeasured here; could be 2-5 us
rather than 1".

If it worked, at the shell's actual Gen3 x4 (3.94 GB/s raw payload ceiling) and
2 us latency, with `t_tail` = 4096/16 lanes = 256 cycles = 1.08 us at 237.8 MHz:

```
T_coll  = 2 + 32,768/3.94e9 + 1.08 = 2 + 8.32 + 1.08 = 11.4 us
per token = 64 x 11.4 us = 0.73 ms   =  8.4% of TP-fast's 8.74 ms
```

**Gateware cost: real but bounded.** XDMA must move from DMA mode to AXI Bridge
mode (PG194) so the datapath can initiate writes to a peer BAR via
`AXIBAR2PCIEBAR`, or a C2H descriptor must be pointed at the peer's physical
BAR. `docs/fpga-hardware-recon.md` lists both as documented paths and notes the
64-bit prefetchable BARs P2P requires are already enabled in the reference
design. Plus an ACS override on the host, which may need a patched kernel.

**Unverified: everything.** Whether peer writes are routed rather than bounced
(U4), the real latency (U5), and whether this chassis can host the test (U6).

### 4.5 Aurora over quads 226/225/224

DERIVED, 12 lanes at 16 Gbps with 64B/66B encoding:

```
12 x 16e9 x 64/66 = 186.2 Gbps = 23.3 GB/s
T_coll = 0.2 (design parameter) + 32,768/23.3e9 + 1.08 = 2.69 us
per token = 64 x 2.69 us = 0.172 ms   =  2.0% of 8.74 ms
```

**Cost: a backplane that does not exist**, listed "to design" in
`~/GitHub/pcie-llm-hardware`, plus three Aurora 64B/66B cores in gateware
(ESTIMATE 2,000-3,500 LUT per quad, so 6,000 to 11,000 LUT) added to a design
that has 94 spare CLBs. Oren's own position, quoted in the coordinator's
correction: "Yes Aurora after the PCB design is done."

### 4.6 Does the link need to be fast? No

Comparing 4.3, 4.4 and 4.5 at TP-fast's 8.74 ms budget:

| transport | per token | % of budget |
|---|---:|---:|
| Aurora, 23.3 GB/s, 0.2 us | 0.172 ms | 2.0% |
| PCIe P2P, Gen3 x4, 2 us | 0.73 ms | 8.4% |
| host-mediated, `t_sw` 30 us | 5.67 ms | 65% |

Aurora is 4.2x the bandwidth of Gen3 x4 and buys 6.4 percentage points.
Host-mediation is not slower because of bandwidth; it is slower because of
15 us of fixed DMA call overhead plus `t_sw`, 64 times per token.

**So: the link does not need to be fast. It needs to not be the host.** That is
the E spec's own section 3.4 conclusion ("The design does not need a fast link.
It needs a link that exists") and it survives unchanged at the 9B shape. The
practical consequence is that **PCIe P2P at the shell's existing x4, if it
works at all, is entirely adequate for TP on the 9B and needs no backplane and
no Aurora.** That is the cheapest path to a usable two-card 9B, and its only
blocker is a measurement nobody has taken.

---

## 5. What is real in the tree, and what is a comment

Established by reading the files, not the documents. Where a document and the
RTL disagree, the RTL wins.

### REAL: executes, or gates a build

| what | where | evidence |
|---|---|---|
| `NCARDS` as a constant, currently 1 | `rtl/model_cfg_pkg.vhd:91` | read by `mk_shape`, `seq_tbl_pkg`, `probe_abc_ports`, `tb_realshape_9b` |
| `val_heads_per_card` / `key_heads_per_card` with a divisibility **assert ... severity failure** | `rtl/model_cfg_pkg.vhd:127-140` | real functions with a real refusal |
| `mk_shape(m, ncards)` dividing `key_heads`, `val_heads`, `attn_q_heads`, `vocab` | `rtl/llama_map_pkg.vhd:176-189` | the shape record every unit is generic-mapped from |
| `arena_sizes(cfg, ncards)` halving the GDN arena and the KV per-token figure, with a **refusal** on non-divisibility | `tools/hbm_map.py:377-384` | I ran it; section 1.2's table is its output |
| `--ncards` on the CLI, and two self-test rows asserting the N=2 halving | `tools/hbm_map.py:1730-1735, 1893` | executes in `--self-test` |
| `pack_int4.py` calling `arena_sizes(ncards=cards)` | `tools/pack_int4.py:815` | the packer is already N-aware |
| **x4 Gen3 on quad 227, quads 226/225/224 reserved** | `hw/fk33/gen_pcieep.py:1546-1556` | **and gated**: `hw/fk33/check_pcieep_xdc.py:153` fails the build otherwise |
| Unit E as a **refusal**: raises `u_err`, reports an error, does not complete | `rtl/llama_top.vhd:4466-4500` | a schedule built for N>1 STOPS rather than producing a number |
| `FK33_FAULT_E_COLL` host-visible fault bit | `server/fk33_seam.h:309` | real |
| Two working FK33s | serials 153300000607 and 153300001366 | `docs/debugging/2026-08-29_second-fk33-verify-and-flash-backup.md` |
| A live PCIe link doing XDMA transfers | commit `97aed66` | the C2H cost sweep |

### COMMENT ONLY: no execution anywhere

| what | where | how I checked |
|---|---|---|
| descriptor **flags bit 3, "an E step follows this job (NCARDS > 1)"** | `rtl/seq_desc_fetch.vhd:109` | `grep -n "bit 3"` across `seq_desc_fetch.vhd`, `seq_opdec.vhd`, `llama_top.vhd` returns **only that one comment line**. The bit is documented in the format and decoded nowhere. |
| "AT NCARDS = 1 THERE IS NO E SEAM ... hazard B7 returns at NCARDS > 1" | `rtl/seq_vec_res.vhd:168-173` | a comment describing an **unresolved** hazard: `e_o_we` into D-vec's residual pass has no ready at all, called "UNSTALLABLE, AND UNRESOLVED" in two files |
| "27B on two cards is N_QH = 12, N_KVH = 2, LAYERS = 16" | `rtl/attn_block.vhd:206` | header prose |
| `rtl/tp_collective_skel.vhd` | -- | its own spec says it "analyzes clean, does nothing" |
| Aurora | `hw/fk33/gen_pcieep.py`, `build_fk33_pcieep.tcl`, `check_pcieep_xdc.py` | comments and a lane reservation only. **No Aurora IP, no `gtwizard`, no `GTYE4` instantiation exists in any design source.** |
| PCIe peer-to-peer | -- | no RTL, no BAR aperture, no `AXIBAR2PCIEBAR` programming anywhere |

**Summary: the shape plumbing and the memory map are genuinely N-parametric and
would work today at NCARDS=2. Everything that would actually move a byte
between two cards is absent, and unit E is wired as a refusal rather than a
stub, which is the right choice and means a wrong build stops instead of lying.**

---

## 6. What subsystem E should become

Conditional on TP being chosen, which section 2 says it must be if two cards
are used at all.

**E is still needed, and the existing spec is still substantially right, but
five things change at the 9B shape and one changes because of C2.**

1. **`MAXROWS` should be 4096, not 5120 and certainly not 17408.** The spec's
   own section 7.1 argument is correct and its number is the 27B `d_model`. At
   the 9B every row-parallel matvec output is 4096 wide.
2. **BRAM falls with it.** A BRAM36 in 512x72 mode holds 512 x 64-bit words, so
   4096 rows is 8 BRAM36 per buffer. At N=2: local partial 8, receive
   `1 x NBUF 2 x 8` = 16, `y32` 4 (aliasable). **~28 of 672 = 4.2%.**
3. **Collectives per token is 64, not 128** (32 blocks, not 64). Message 32,768
   B, not 40,960.
4. **`t_tail` is `MAXROWS/LANES` = 4096/16 = 256 cycles = 1.08 us at the
   MEASURED 237.8 MHz**, not at the 300 MHz the spec assumes.
5. **The spec's section 1 must be rewritten.** Its finding "whether PCIe P2P
   works between two FK33s is UNKNOWN, because no FK33 has ever enumerated on
   PCIe on this workstation and only one card exists" is now wrong on both
   clauses: a card is enumerated and transferring, and two cards exist. Its own
   2026-08-27 CORRECTION (Aurora) is right in direction and should absorb
   section 4.5's finding that the Aurora lane reservation is already
   implemented and gated in the shell.
6. **The unresolved hazard is the thing to fix first, and it is not in E.**
   `rtl/seq_vec_res.vhd:168-173` and `rtl/llama_top.vhd:4470-4472` both record
   that `e_o_we` into D-vec's residual pass has **no ready signal at all** and
   call it "UNSTALLABLE, AND UNRESOLVED". Per the project's own head_emit
   precedent, a producer that cannot be back-pressured loses beats silently.
   That is a D change, it is a prerequisite for E, and it is currently owned by
   nobody.

**If pipeline were chosen instead, E would be replaced, not reduced.** A
pipeline handoff is a single 8 KB activation transfer with a sequence number,
which is a DMA and a doorbell, not a reduction: no `amax`, no BFP repack, no
`out_shift` reconciliation, no `NBUF=2` proof, no seqlock recheck. Roughly 5%
of E's design content. But section 2 says pipeline should not be chosen, so
this is recorded to close the question rather than to recommend it.

---

## 7. The cheapest experiment that would de-risk this, stated so it can fail

**The gating question is not about cards. It is whether TP-small's area
actually halves.** Every number in section 2.5 is an ESTIMATE, and the whole
two-card case rests on it. If B and C do not shrink the way the table assumes,
TP-small lands above 100% and two cards buy nothing at all.

### 7.1 Experiment 1: the half-width OOC draw. Needs a Vivado slot, which I do not have

**This is the report-and-ask item.** Both Vivado lanes were held by TRACK
TIMING, so this was not run. It is three OOC synthesis runs, no place-and-route,
no hardware, and it either confirms or kills the entire TP case.

**How it fails:** if `attn_block` at half heads comes back above ~68,000 LUT,
or `gdn_block` above ~60,000, or `matvec_core` above ~75,000, the section 2.5
total exceeds 54,960 CLB and TP-small does not fit either. State that threshold
BEFORE running, and treat a single draw as a draw: `attn_block` has been
measured to vary by 278 LUT across pinned trees and the norm ROM by 1.55x.

```bash
cd /home/orencollaco/GitHub/llama.vhdl
SD=/mnt/storage/twocard_halfwidth
mkdir -p /mnt/storage/twocard_halfwidth

# C at N=2: half the query heads, half the KV heads, same LAYERS.
# Edit sim/ooc_compose_bcd.tcl's GEN(attn_block) to
#   {HEAD_DIM=256 N_QH=8 N_KVH=2 LAYERS=8}
# in a COPY under the scratch dir, not in the repo.
COMPOSE_TARGET=attn_block COMPOSE_OUT=/mnt/storage/twocard_halfwidth/c_n2 \
  vivado -mode batch -source /mnt/storage/twocard_halfwidth/ooc_compose_bcd.tcl

# B at N=2: KEY_HEADS 8, VAL_HEADS 16, LAYERS 24, RECUR_LANES 16.
COMPOSE_TARGET=gdn_block COMPOSE_OUT=/mnt/storage/twocard_halfwidth/b_n2 \
  vivado -mode batch -source /mnt/storage/twocard_halfwidth/ooc_compose_bcd.tcl

# Controls, on the SAME machine in the SAME session, because a cross-session
# area comparison is not a comparison:
COMPOSE_TARGET=attn_block COMPOSE_OUT=/mnt/storage/twocard_halfwidth/c_n1 \
  vivado -mode batch -source sim/ooc_compose_bcd.tcl
COMPOSE_TARGET=gdn_block COMPOSE_OUT=/mnt/storage/twocard_halfwidth/b_n1 \
  vivado -mode batch -source sim/ooc_compose_bcd.tcl

grep -E 'COMPOSE_DONE' /mnt/storage/twocard_halfwidth/*/*.log
```

One Vivado at a time. `sim/ooc_compose_bcd.tcl:38-41` says so in its own header,
and the box hung last night under six.

### 7.2 Experiment 2: the free single-card fix, which should be tried FIRST

Before spending a card, execute the two URAM moves TRACK TIMING already
identified and priced at **76,156 LUT**, plus whatever density recovery follows
from deleting 26,432 MUXF7/F8 pairs. If that closes the fit, the entire
two-card area question disappears and only the 262k-context question remains.
It is RTL work with a bit-exactness obligation on `rtl/rmsnorm_rs.vhd`, not a
knob, and TRACK TIMING's write-up says so. **It is still cheaper than a
backplane.**

### 7.3 Experiment 3: two cards in slots, host-mediated only. Needs hands

This does NOT test any conclusion in this document, but it is the prerequisite
for everything and it uses only what has arrived. **I did not run it and must
not.**

**SAFETY, and it must be read before power is applied.** The MCIO device
adapters take 12 V from a **GPU power connector**, and the vendor warns that
**the wrong connector destroys both the adapter and the card**. Check the
connector before applying power. On each device adapter the host cable goes in
the connector **near the power plug**, which carries lanes 0-7.

```bash
# 0. BIOS: confirm PCIEX16 offers x8/x8 bifurcation.  Note it currently runs
#    at x8 total because the Samsung root NVMe holds M2C_CPU, so bifurcation
#    gives x4/x4.  The shell requests Gen3 x4, so x4/x4 costs nothing.
# 1. Wire per ~/GitHub/pcie-llm-hardware/docs/03-interim-mcio-bringup.md.
# 2. Boot, then:
lspci -nn | grep -i xilinx
lspci -d 10ee: -vv | grep -E 'LnkCap|LnkSta'      # expect Speed 8GT/s, Width x4
ls -l /dev/xdma*
```

**How it fails:** only one endpoint appears, or `LnkSta` shows a width or speed
below `LnkCap`, or the second card's `/dev/xdma*` nodes do not appear.

### 7.4 Experiment 4: PCIe P2P, once 7.3 passes

The one that would let TP run without a backplane. Requires a bitstream in AXI
Bridge mode or a C2H descriptor pointed at the peer's BAR, neither of which
exists. **Do not attempt before 7.1 says TP-small fits**, because there is no
point proving a transport for a configuration that does not fit.

---

## 8. Measured and REJECTED. Do not retry

1. **Pipeline parallelism split by layer index, as an area fix.** REJECTED.
   Saves 16,472 LUT of norm image plus ~500 LUT of state arrays out of 420,240
   = **4.0%**, leaving 116% of the die. The reason is structural and will not
   change: the engine is one instance time-multiplexed over layers, so `LAYERS`
   sizes only `attn_block`'s 256-bit `vref_r` and `gdn_block`'s 844-LUT
   exponent store.
2. **Pipeline parallelism split by type (all GDN on one card, all attention on
   the other).** REJECTED. Lands at 93-95% CLB, above the 90% line that
   congestion level 7 makes the real limit, while costing 16 card crossings per
   token and leaving one card idle 75% of the time.
3. **Pipeline parallelism as a throughput measure.** REJECTED, and this one is
   not about area at all. A single autoregressive token cannot occupy both
   halves of a pipeline, so `T_pp = T + handoff`. Two cards, the same wall time
   as one.
4. **Treating "the interim hardware can only do pipeline" as an argument FOR
   pipeline.** REJECTED. It is true and it is not an argument, because pipeline
   delivers neither of the things two cards would be bought for.
5. **Carrying `~/GitHub/pcie-llm-hardware`'s capacity table into a 9B
   analysis.** REJECTED. That table is 27B at 262,144 context: 11.86 GB per
   card at N=2, needing N=4. The 9B has half the attention layers, so its KV is
   exactly half, and it fits comfortably at N=2 (4.81 GB).
6. **Quoting a tok/s figure without naming its bandwidth premise.** The ladder's
   figures are against the refuted 460.8 GB/s. This document uses the MEASURED
   288.0 GB/s throughout, and notes that the engine currently achieves
   7.39-7.88 GB/s because of the packer bug TRACK PACKSTRIPE is fixing, so even
   288 is a ceiling and not an achievement.

---

## 9. Measurement traps hit

**T1. The per-subsystem area figures exist only at the post-SYNTHESIS point.**
The composition placed at 346,971 LUT, but the only per-instance breakdown is
of the 350,283 synthesis figure. Every per-subsystem number in section 2 is
therefore pre-placement, and any attribution of the placed 346,971 to
subsystems would be interpolation. I did not attempt one.

**T2. A single area number is a draw.** `docs/debugging/2026-08-30_scatter-per-draw-area-variance.md`
measures the norm gain ROM at 82,597 to 128,065 across six draws from the same
command, and rules that no single number may be quoted. I used the best draw in
every configuration so the comparisons are internally fair, and said so, rather
than picking a favourable draw for one column.

**T3. I nearly credited TP with halving subsystem A's weight streamer.** It does
not. The 27 HBM read masters exist to saturate **this card's own** HBM, and
that requirement is unchanged at any N. Only `matvec_core`'s MACs shrink. Had I
missed it, TP-small's total would have read ~300,000 rather than ~311,900 and
the 90% line would have looked comfortable rather than marginal.

**T4. The 12.38 s of MMIO per token is not the host-mediated collective cost.**
It is the current bring-up readback path over MMIO registers, which commit
`494f881` is replacing. The right figure for a host-mediated collective is the
MEASURED XDMA DMA curve (~7.5 us fixed), and using the MMIO number would have
overstated the host path by four orders of magnitude and made pipeline look
mandatory for the wrong reason.

**T5. `grep -rniL x` is not a "list files without matches" idiom that does what
you want without a pattern file.** Run against the repo root it walked 4.8 GB of
`sim/` and produced 29.7 KB of filenames. Cost: one wasted round trip. Scope
every recursive grep to `rtl/ hw/ tools/` with `--include`.

---

## 10. Open, not yet answered

1. **Does TP-small's area actually halve?** Everything in section 2.5 is an
   ESTIMATE built leaf by leaf. Section 7.1 is the experiment and it needs a
   Vivado slot I did not have.
2. **How much packing density recovers when the two URAM moves delete 26,432
   MUXF7/F8 pairs?** This is the single most valuable unknown on the page,
   because it decides whether the free single-card fix closes the gap and makes
   the whole two-card question moot. Unmeasured, and not derivable.
3. **Is the 121% single-card fit claim correct?** Under adversarial review.
   Section 2.7 states which conclusions here survive if it is overturned.
4. **Is `gdn_emit_chain` at 8 lanes legal at N=2?** Its own header says 8
   "misses B's 299.04 MHz" at N=1. At N=2 the per-head deadline changes, so it
   might become legal, which would take another ~5,000 LUT off TP-small. Not
   analysed.
5. **What does subsystem E actually cost in LUT?** The ~5,000 in section 2.5 is
   a GUESS from `docs/debugging/2026-08-25_lut-budget-measured.md:36`. The E
   spec deliberately leaves LUT and FF blank rather than guessing. An OOC sweep
   over `LANES in {8,16,32}` would settle it and `t_tail` together.
6. **Does PCIe P2P work between two FK33s on sibling CPU root ports?** U4, U5
   and U6 from the E spec, all still open, and the two project documents still
   contradict each other about whether this chassis can even host the test.
7. **`t_sw`, the host software round trip.** Section 4.3 sweeps 5 to 60 us from
   the E spec's band. Nobody has measured it on this host, and it is the term
   that decides whether host-mediated TP is a 1.07x or a 1.37x gain.
8. **Is 262,144 context a product requirement?** If it is, two cards are needed
   for the 9B regardless of every area argument in this document. If it is not,
   ~200k on one card may be enough and the two-card question is purely about
   area. **This is Oren's call and I have not assumed either way.**
9. **Who owns the unstallable `e_o_we` hazard?** `rtl/seq_vec_res.vhd:168-173`
   and `rtl/llama_top.vhd:4470-4472` both call it UNRESOLVED. It is a
   prerequisite for E and it is on nobody's track.
10. **Whether the two cards can be in slots simultaneously at all.** Card 2 has
    only ever been on JTAG and aux power, never in a slot. Power is 2 x ~155 W
    on a 700 W system, which recon says is fine, but it has not been done.
