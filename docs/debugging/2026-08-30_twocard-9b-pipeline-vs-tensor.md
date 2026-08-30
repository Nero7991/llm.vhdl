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

> ### THE HEADLINE
>
> **This design instantiates ONE physical A, ONE B, ONE C and ONE D, and
> time-multiplexes them over all 32 blocks. So the layer count does not set the
> area. The datapath WIDTH does.**
>
> That single structural fact decides the whole question. Every intuition
> imported from how GPUs shard a transformer assumes the opposite, because on a
> GPU the layers are weights in memory and the "hardware" is the same SMs
> either way, so splitting layers splits the footprint. Here the layers are a
> loop, and splitting a loop in half does not make the loop body smaller.
>
> MEASURED, not inferred: `c_attn` in
> `hw/fk33/results/compose4_2026-08-29/util_hier_c4_synth.rpt` has exactly four
> `gen_head[i]` instances (one per KV head, `N_KVH = 4`) and exactly one
> `u_arr`. There is no per-attention-layer replication anywhere in the report.
> `rtl/attn_block.vhd:225` states `LAYERS`'s job in its own words -- "attention
> layers, **for the cache map**" -- and the only structure it sizes is
> `vref_r`, at `LAYERS * N_KVH * EXP_W = 256 bits`. `rtl/gdn_block.vhd:194`
> likewise: "GDN layers, **for the exponent store**", which is `u_exp` at
> **844 LUT of B's 75,181**.
>
> **Pipeline parallelism is therefore dead for a structural reason, not a
> numerical one.** It is not that the saving is disappointing; it is that there
> is nothing there to save. Halving the layer count removes about 1,100 LUT of
> state arrays out of 350,283.

> ### THE DECISION, AND WHAT WOULD REVERSE IT
>
> **The 9B stays SINGLE-CARD. The two-card case is declined, not deferred.**
> Decided 2026-08-30 on this analysis plus Oren's answer on context: *"Not a
> requirement, even 64k ish is fine."*
>
> **Pipeline parallelism is declined permanently**, for the structural reason
> boxed above. It does not become right at a different model size, a different
> context, or a different area outcome. The only thing that would revive it is
> **concurrent sequences in flight** (trigger X4), because that is the single
> assumption its zero-speedup result rests on.
>
> **Tensor parallelism is declined for the 9B and retained as a costed option.**
> It returns if any of the following becomes true. These are written to be
> checkable by someone who was not here:
>
> | # | trigger | how to check it | status 2026-08-30 |
> |---|---|---|---|
> | **X1** | a context requirement above the single-card ceiling | compare the requirement against section 1.2's ceiling **at the striping configuration actually shipped** (see the watch item below) | 64k required against 202,681 unstriped. **3.2x headroom.** Not triggered |
> | **X2** | a model that does not fit one card's HBM at the required context | run `arena_sizes()` for the model and add the 4.5 bpw weight figure | 9B is 5.10 GB of 8.59 at 64k. Not triggered. **27B is already over this line at 14.09 GiB and always was** |
> | **X3** | the single-card AREA conclusion fails to close | neither norm-gain lever routes, AND section 7's draws confirm TP-small near 89% | two levers stand at 97.9% and 93.2% CLB, both **unrouted**. **Live, not resolved** |
> | **X4** | batching, or two or more concurrent sequences | any change that puts more than one token in flight | single-stream today (`server/llama_server.cpp`, and D's `seq` is one token at a time). Not triggered. **This is the only trigger that revives PIPELINE rather than tensor** |
>
> **X3 is the one that is actually live.** X1, X2 and X4 are all comfortably
> false today; X3 is undecided and is TRACK TIMING's, not mine.
>
> **X3 WAS REWRITTEN 2026-08-30 after the section 7.1 draws came back. It can
> no longer fire in the form above. See section 11.6.** The draws MEASURED
> subsystem C at **0.985** of its N=1 area under tensor parallelism against a
> predicted 0.608, because its mac array is dimensioned on `G = N_QH/N_KVH`,
> which tensor parallelism leaves invariant. **Two cards do not deliver the
> area saving this document estimated**, so a single-card area failure is not a
> reason to reach for them. **FINAL, with B also drawn: TP-small is 355,395 LUT
> = 102.3% of the die. It does not fit at all.** Tensor parallelism at N=2
> removes 7.9% of B and C combined, against the 39% estimated.

> ### WATCH ITEM AGAINST X1: striping SPENDS context, and it can spend past 64k
>
> Arrived after this document's first draft, from TRACK PACKSTRIPE, and it is
> the mechanism most likely to move X1. **Striping the weights across HBM
> pseudo-channels -- the ~13.5x engine speedup that fixes the 7.39-7.88 GB/s
> defect -- costs contiguity, and contiguity is what the KV arena was spending
> to reach 202,681 tokens.** MEASURED by that track:
>
> | striping configuration | engine speedup | usable context | headroom over 64k |
> |---|---:|---:|---:|
> | none (what section 1.2 computes) | 1x | 202,681 | 3.2x |
> | **full striping** | **13.5x** | **44,500** | **0.70x -- VIOLATES 64k** |
> | 21-segment hybrid, no RTL change | 8.6x | 138,600 | 2.2x |
> | full striping + extent-aware KV | 13.5x | ~214,000 | 3.3x |
>
> **This is the first point in the project where single-card context is scarce
> rather than abundant, and the scarcity is created by the speed fix rather
> than by the model.** Two rules follow. First, **X1 must be checked against
> the striping configuration actually shipped, never against the 202,681
> figure**, which now describes a configuration nobody intends to ship.
> Second, if the extent-aware KV change does not land, the working headroom is
> 2.2x and one more claim on the KV arena could put 64k in reach of a
> violation. Neither outcome brings back two cards on its own -- 2.2x is still
> headroom -- but it is the only live path from "abundant" to "triggered".

**No, it is not easy, and the specific reason is worse than "it is a big
project": the cheap version of two cards does not solve the problem it would be
bought for.** For the 9B the binding constraint is CLB area, not HBM capacity,
and area is set by the datapath's WIDTH (MACs and lanes), not by the layer
count, for the reason boxed above. Pipeline parallelism splits the layer count,
so it removes
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

> ### C1. A LOAD-BEARING GUARD IN A DECISION DOCUMENT PASSED FOR THE WRONG REASON
>
> **`docs/2026-08-25_single-card-fallback-decision.md:24` says the 9B fits one
> card: "5.1 GB of 8 GiB, **yes**, ~2.9 GiB spare". It counts WEIGHTS ONLY.**
> The KV cache is not in that row and is not mentioned anywhere on that line.
>
> ```
>              the row says          the truth at max_context 262,144
>   weights    5.1 GB                 5.0364 GB
>   KV         (absent)               4.5634 GB   <- 17,408 B/token x 262,144
>   GDN state  (absent)               0.0253 GB
>              -------                ----------
>              5.1 of 8.59 GB         9.6251 of 8.590 GB
>              "~2.9 GiB spare"       OVER BY 1.0352 GB
> ```
>
> **That table has underwritten the single-card strategy for five days.** It
> reached the right verdict, and it reached it without ever evaluating the term
> that decides it. The verdict survives only because Oren's answer on context
> came back "64k ish is fine" -- at 64k the 9B needs 5.10 GB and the row's
> conclusion holds with room. **Had he answered 262k, the row would have been
> wrong AND load-bearing, and the single-card decision it underwrites would
> have been wrong with it.**
>
> This is the project's own named defect class: *a check that has never been
> shown to discriminate on the thing it guards*. The guard here is "does the
> model fit the card", the thing it guards is total HBM occupancy, and the
> check read one of three terms. **It is the third guard-passing-for-the-wrong-
> reason found in a decision document today, and a decision document is the
> most consequential place for one**, because unlike a testbench nothing
> downstream re-derives the number -- it is quoted.
>
> **The row should read:** "yes at 64k with 3.4 GB spare; yes to ~202,681
> tokens unstriped; NO at 262,144." And per the watch item above, the striped
> figure is lower again.

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
| one card, TRACK TIMING's `lever C + HBM gain` | -- | **97.9%** | unrouted | 57.2 | needs nothing unmeasured |
| one card, TRACK TIMING's `lever C + URAM gain` | -- | **93.2%** | unrouted | 57.2 | free, unexecuted |
| **PP by index, N=2** | 403,268 | 116% | **no** | 57.1 | context |
| **PP by type, N=2** | 324-329k | 93-95% | **no** | 57.1 | context |
| **TP-fast, N=2** | 416,410 | 120% | **no** | 112 | context, speed |
| ~~**TP-small, N=2**~~ **WITHDRAWN, see section 11** | ~~308,900~~ **355,395 MEASURED** | ~~88.9%~~ **102.3%** | ~~yes, just~~ **NO, over 100%** | 57.2 minus the collective | **nothing it was bought for** |

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

**How it fails. There are TWO thresholds and the weaker one was the only one
originally stated, which was a mistake worth recording.**

*Threshold A, "fits the die at all".* If `attn_block` at half heads comes back
above **~68,000 LUT**, or `gdn_block` above **~60,000**, the section 2.5 total
exceeds 54,960 CLB and TP-small does not fit.

*Threshold B, "fits the routable region".* This is the one that matters and it
is far tighter. Section 2.5's TP-small total of 311,877 LUT is **49,351 CLB =
89.8%**, and the 90% target is 49,464 CLB = 312,613 LUT. **The margin is 736
LUT, which is 0.24%.** So against the target that the composed design's
congestion level 7 actually established, the thresholds are essentially the
estimates themselves: `attn_block` above **~52,600** or `gdn_block` above
**~52,600** puts TP-small over 90%.

**Both are stated before the run and both will be reported.** The honest
expectation is that threshold B is missed and threshold A is met, because a
point estimate with 0.24% margin is not an estimate that lands. Recording that
in advance is the point: a result inside threshold A and outside threshold B
means "two cards fit, with no margin", which is a materially different answer
from "two cards fit".

Treat a single draw as a draw: `attn_block` has been measured to vary by 278
LUT across pinned trees and the norm ROM by 1.55x across six draws from the
identical command. Neither of these two targets is ROM-dominated, so they
should be stable, but that is a prediction and it is tested by drawing twice.

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

### 7.2 Experiment 2: the single-card fix, which has overtaken this whole track

> **Its 84.5% TP-small figure is WITHDRAWN by section 11; corrected it is 94.6%.**


**SUPERSEDED IN PROGRESS, 2026-08-30, and in the direction this document
argued.** When section 7.2 was first written the single-card relief was "the
two URAM moves, 76,156 LUT, unexecuted". TRACK TIMING has since found a **third
way to serve the norm gain**, and it is better on the axis that matters most
here, which is evidence quality rather than size. Reported to me by the
coordinator; **I have not read the underlying reports and label it as such**:

| way to serve the norm gain | LUT cost | evidence |
|---|---:|---|
| LUT ROM (what the 420,240 assumes) | **+32,943 to +78,411** | 6 draws, 1.55x spread, **ruled NOT SAFE** |
| URAM | -- | the move this section originally named |
| **stream it from HBM** | **+17,405** | **n=2, reproducible, bit-identical on 11 columns** |

Resulting single-card positions, as reported: `lever C + HBM gain` = **97.9%
CLB on measured-only evidence**, `lever C + URAM gain` = **93.2%**.

**Two things follow, and they point opposite ways.**

It **strengthens** this document's central argument: the single-card fit now has
a path that rests on nothing unmeasured, so two cards would be buying an area
fix that is already available without them. Combined with Oren's 64k answer,
that is what closed the decision.

It does **not** yet close X3, and saying so is the honest half. **Both figures
are above the 90% line**, and 90% is not an aesthetic target: the composed
design placed at 99.83% CLB with **congestion level 7 and 33,767 failing
endpoints**, which is what established that the high nineties is not a routable
region on this die. 97.9% in particular is only 1.9 points below a
configuration already MEASURED as unroutable. **Neither number is a routed
result**, and until one is, X3 is live.

Applied to this document's own arithmetic: substituting the HBM gain for the
ROM takes 15,538 LUT out of TP-small too, giving ~296,300 synth / ~293,400
placed = **46,424 CLB = 84.5%**. So the gap between the best single-card
position and TP-small stays roughly 9 to 13 points either way. **Two cards do
still buy real area. They are declined because 84.5% versus 93.2% is not worth
a card, subsystem E, a peer link and the speedup, not because the area saving
was imaginary.**

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
8. ~~**Is 262,144 context a product requirement?**~~ **ANSWERED 2026-08-30 by
   Oren: "Not a requirement, even 64k ish is fine."** This was the one input I
   could not supply and it resolved the decision. At 64k the 9B needs 5.10 GB
   of 8.59, and the unstriped ceiling of 202,681 tokens gives 3.2x headroom.
   **Superseded by a sharper question: is 64k still safe at the striping
   configuration that actually ships?** Full striping puts the ceiling at
   44,500, which is BELOW 64k. See the watch item under the decision box; this
   is now item 11.
9. **Who owns the unstallable `e_o_we` hazard?** `rtl/seq_vec_res.vhd:168-173`
   and `rtl/llama_top.vhd:4470-4472` both call it UNRESOLVED. It is a
   prerequisite for E and it is on nobody's track.
10. **Whether the two cards can be in slots simultaneously at all.** Card 2 has
    only ever been on JTAG and aux power, never in a slot. Power is 2 x ~155 W
    on a 700 W system, which recon says is fine, but it has not been done.
11. **Which striping configuration ships, and therefore what the real
    single-card context ceiling is.** This replaces item 8 and it is the live
    one. Full striping is 44,500 tokens, which violates the 64k requirement;
    the 21-segment hybrid is 138,600; the extent-aware KV change recovers
    ~214,000. **X1 must be checked against whichever ships, never against this
    document's unstriped 202,681.** Owned by TRACK PACKSTRIPE, not by me, and I
    have not read its measurements.
12. **Whether 93.2% or 97.9% CLB actually routes.** Both single-card lever
    positions are above the 90% line, and the only nearby data point is the
    composed design at 99.83% with congestion level 7 and 33,767 failing
    endpoints, i.e. a MEASURED failure. Until one of the levers is taken
    through `route_design`, trigger X3 is open and the single-card decision
    rests on an unrouted projection. **This is the largest remaining risk to
    the decision this document records.**

---

# 11. RESULTS of the section 7.1 draws, and the withdrawal of section 2.5's C row

**Run 2026-08-30 on the BC-250** (`cachyos-bc250`, 192.0.2.200), Vivado
2023.2, part `xcvu33p-fsvh2104-2L-e`, period 5.0 ns, licence
`~/.Xilinx/Xilinx-4.lic`. Tree synced with
`~/GitHub/DevOps/bc250-sync-llama-vhdl.sh` immediately before the run; md5 of
`rtl/attn_block.vhd`, `rtl/gdn_block.vhd` and `sim/ooc_compose_bcd.tcl` verified
identical on both machines before any Vivado started. One Vivado at a time,
gated on presence. **No hardware, no workstation Vivado.**

Harness `/mnt/storage/twocard_scratch/run_halfwidth.sh`; it rewrites exactly two
`GEN` lines of `sim/ooc_compose_bcd.tcl` into a scratch copy and **refuses to
run if either rewrite did not bite**. The repo's own script is untouched.

## 11.1 The answer, up front

**BOTH THRESHOLDS MISSED, AND NOT NARROWLY. Section 2.5's TP-small estimate is
WITHDRAWN.** `attn_block` at half the heads is **86,012 LUT against the N=1
control's 87,337, a ratio of 0.985**. I predicted 0.608.

**And the reason is structural, not numerical. It is the same class of error I
caught in the brief's pipeline proposal, committed by me, in my own tensor
estimate, in the same document.**

## 11.2 The measurement

| draw | generics | LUT | FF | DSP | F7 | F8 | BRAM | secs |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `c_n1_a` control | `N_QH=16 N_KVH=4` | **87,337** | 101,319 | **298** | 16,350 | 2,992 | 11 | 706 |
| `c_n2_a` | `N_QH=8 N_KVH=2` | **86,012** | 101,127 | **298** | 18,112 | 3,776 | 9.5 | 658 |

Both post-synthesis, `rc=0`, both with the `COMPOSE_DONE attn_block` sentinel.
`HEAD_DIM=256` and `LAYERS=8` held constant in both, as recorded by the
`COMPOSE_GENERICS` line each run printed.

**The control validates the flow.** `c_n1_a` at 87,337 LUT / 101,319 FF / 298
DSP / 11 BRAM reproduces the composed build's `c_attn` instance row (85,592 /
101,046 / 298 / 11) to **+2.0% on LUT and exactly on DSP and BRAM**. That
matters because `sim/ooc_compose_bcd.tcl`'s header warns a per-instance row in
a flattened composed synthesis is not an isolated measurement. It agrees, so
the comparison is sound.

| | ratio | LUT on the OOC basis | verdict |
|---|---:|---:|---|
| section 2.5 estimate | 0.608 | 53,101 | -- |
| **threshold B**, fits the 90% routable target | 0.615 | 53,712 | **MISSED by 32,300** |
| **threshold A**, fits the die at all | 0.795 | 69,433 | **MISSED by 16,579** |
| **MEASURED** | **0.985** | **86,012** | |

## 11.3 Why: G is invariant under tensor parallelism

MEASURED, `rtl/attn_block.vhd:395-396` and `:898-901`:

```vhdl
constant NBLK  : integer := HEAD_DIM/KV_BLOCK;   -- 256/32 = 8
constant G     : integer := N_QH/N_KVH;          -- the GQA group size

u_arr : entity work.attn_mac_array
  generic map ( QH_TILE => G, DIM_TILE => KV_BLOCK, ACC_N => NBLK, ... )
```

**The mac array is dimensioned on the RATIO `G = N_QH/N_KVH`, and tensor
parallelism divides the numerator and the denominator by the same N.**

```
N=1 :  G = 16/4 = 4
N=2 :  G =  8/2 = 4        <-  INVARIANT
```

`KV_BLOCK`, `HEAD_DIM` and `NBLK` are invariant by inspection. So
`attn_mac_array` -- **55,854 LUT and 256 of C's 298 DSP**, the single largest
item in subsystem C -- is **exactly invariant under TP**, and the DSP column
measuring **298 in both draws, to the unit**, is the proof rather than an
argument for it.

The 1.5% that did come out is the `gen_head[i]` replication falling from 4
instances to 2 (4,210 LUT) plus part of `attn_kv_quant`, **partly cancelled by
something that grew**: F7 muxes rose 10.8% and F8 muxes rose 26.2%.

**That last point may matter more than the LUT number.** CLB is the binding
resource, not LUT, and F7/F8 pairs are indivisible placement shapes -- they are
precisely what drove packing density from the architectural 8 down to the
measured 6.32. A configuration with 1.5% fewer LUTs and 12.9% more mux pairs
could occupy **more** CLB, not less. An OOC synthesis is unplaced and cannot
answer that; see the open item below.

## 11.4 The corollary that decides it

The array can only shrink by taking `QH_TILE` **below** `G`, which is the MACS
ladder (`QH_TILE` must divide the group, so at the 9B the legal rungs are 32,
64, 128 -- `docs/2026-08-27_9b-single-card-resource-envelope.md` finding F2).

**Every rung of that ladder is available at N=1.** Halving MACS trades
throughput for area on ONE card, with no second card, no subsystem E, no peer
link and no collective. **So the lever that shrinks C is orthogonal to the card
count, and adding a card unlocks none of it.**

That generalises to the whole TP-small case, and it is the finding worth
keeping: **TP-small was never "two cards buy you area". It was "accept half the
throughput and you buy area", with a second card attached to it for no reason.**
Section 3.2 already showed TP-small runs at one card's speed; section 11.3 now
shows it does not even get the area.

## 11.5 Corrected arithmetic

Substituting the MEASURED C for the estimate, scaled to the compose basis
(86,012 x 85,592/87,337 = 84,293):

```
section 2.5 TP-small total                        311,877 LUT   89.8%
C estimated 52,000, MEASURED 84,293               +32,293
                                                  -----------
corrected TP-small total                          344,170 LUT
344,170 / 6.32                                    = 54,457 CLB = 99.1%
```

**TP-small does not fit.** 99.1% against the composed design's 99.83%, which is
MEASURED unroutable at congestion level 7 with 33,767 failing endpoints. This is
before subsystem B's draws are in, and before any allowance for the mux growth
in 11.3.

**Section 2.5's table, section 2.6's `TP-small` row (88.9%), and every figure
derived from them are WITHDRAWN.** They are left in place rather than deleted,
per the house rule, and this section is the correction. The 84.5% figure in
section 7.2, which applied TRACK TIMING's HBM norm gain to the same estimate,
is withdrawn with them; corrected it is 344,170 - 15,538 = 328,632 LUT = 94.6%.

## 11.6 What this does and does not change

**Does not change the decision.** The 9B stays single-card, and this
strengthens it: the two-card option is now measured to be worse than estimated
on the one axis that motivated it.

**Does change trigger X3.** X3 read "the single-card area conclusion fails to
close, AND section 7's draws confirm TP-small near 89%". **The second clause is
now false and X3 can never fire in the form written.** If single-card area
fails to close, two cards as specified do not rescue it, so the correct
response would be the MACS ladder, the norm-gain levers, or a smaller model --
not a second card. **X3 is rewritten below.**

> **X3, corrected 2026-08-30 after the draws.** The single-card area conclusion
> failing to close is **no longer a trigger for two cards at all**. Measured:
> halving the shape generics leaves subsystem C's area unchanged (0.985),
> because its mac array is dimensioned on the TP-invariant ratio `G`. If area
> fails to close, the levers are `QH_TILE` below `G` (costing throughput, on
> one card), the norm-gain paths, or a smaller model. **Two cards return only
> via X1, X2 or X4.**

## 11.7 Measurement traps hit, mine included

**T6. I halved C's SHAPE generics and left its THROUGHPUT dimensioning alone,
and I did not notice because `attn_block` exposes no generic for the latter.**
Section 2.5 attributed `u_arr`'s halving to "`MACS` 128 to 64" -- but there is
no `MACS` generic on `attn_block`; the array's width is `QH_TILE => G`, derived
inside the file. So the experiment I designed could not have tested the thing
my estimate assumed, and the only reason this is a finding rather than a
botched run is that **the DSP column held at 298 across both draws and made the
invariance impossible to miss.** Had I looked only at LUT (87,337 to 86,012) I
would have recorded "TP saves less than expected" instead of "TP saves nothing
here, structurally".

**T7. I made the same class of error I had just diagnosed in someone else.**
The headline of this document is that pipeline parallelism fails because the
area is dimensioned on something the split does not touch. Section 2.5 then
assumed C's area was dimensioned on the head count, when it is dimensioned on
the ratio of two head counts, which TP preserves exactly. **Diagnosing a
failure mode is not immunity from it.** The general form worth carrying: before
crediting a parallelism scheme with an area saving, find the generic the area
is actually dimensioned on and substitute the sharded values into it, rather
than reasoning about what "should" scale.

## 11.8 Subsystem B's control, and a bound PRE-REGISTERED before its N=2 draw

`b_n1_a` completed in 428 s. **It is the tightest control of the four:**

| | OOC draw (`b_n1_a`) | compose4 `b_gdn` row | delta |
|---|---:|---:|---:|
| CLB LUTs | **75,246** | 75,181 | **+0.09%** |
| CLB Registers | 52,203 | 52,470 | -0.5% |
| DSP | **253** | 253 | **exact** |
| BRAM tile | **43** | 43 (36 x36 + 14 x18) | **exact** |

`COMPOSE_GENERICS gdn_block :` printed empty, which is correct and is itself a
check: `sim/ooc_compose_bcd.tcl:62` sets `GEN(gdn_block) {}` because the file's
own defaults ARE the 9B N=1 values (`KEY_HEADS 16, VAL_HEADS 32, LAYERS 24`).
The N=2 copy overrides all four plus `RECUR_LANES 32 -> 16`.

**Unlike C, B's draw is a fair test of the estimate.** `RECUR_LANES` is a real
throughput generic and it was changed. So B can still move, where C structurally
could not.

**But it cannot reverse the verdict, and this is stated before the number
arrives so it cannot be fitted to it.** With C MEASURED, TP-small stands at
344,170 LUT = 99.1%. The 90% target is 312,612 LUT. So:

```
B would have to land 31,558 LUT BELOW its own estimate,
i.e. B(N=2) = 52,000 - 31,558 = 20,442 LUT.
```

**That is below B's floor.** B's shape-invariant leaves alone -- `gdn_conv`
3,652 + `l2norm_rs` 4,707 + `gdn_scalar` 4,645 + `gdn_silu` 4,154 +
`gdn_exp_capture` 844 = **18,002 LUT** -- are per-head-dim and per-channel, not
per-head-count, and do not shard at all. Even at the physically unreachable
limit where `gdn_recur_pipe`, `gdn_emit_chain` and all of B's glue vanish
entirely, TP-small lands at 310,172 LUT = **89.3%**, which is *at* the 90% line
with no margin, from a configuration that cannot exist.

**So the C draw alone settles it: TP-small does not fit, and B's result can
refine the number but not the verdict.** B's draw is still worth having,
because whether the lane-halving hypothesis holds at all is a reusable fact
about this design independent of the two-card question.

## 11.9 Subsystem B's N=2 draw, and the final verdict

`b_n2_a`, 543 s, `rc=0`, sentinel present, generics as printed by the run:
`KEY_HEADS=8 VAL_HEADS=16 LAYERS=24 RECUR_LANES=16`.

| draw | LUT | FF | DSP | BRAM tile | F7 | F8 |
|---|---:|---:|---:|---:|---:|---:|
| `b_n1_a` control | 75,246 | 52,203 | 253 | 43 | 3,953 | 831 |
| `b_n2_a` | **63,651** | 41,637 | **189** | 25.5 | 4,529 | 767 |
| ratio | **0.846** | 0.798 | 0.747 | 0.593 | 1.146 | 0.923 |

Against the thresholds pre-registered in 11.8: estimate 52,045, **threshold B
52,645 MISSED by 11,006**, **threshold A 60,052 MISSED by 3,599**. B moved, and
missed both anyway.

### The attribution, leaf by leaf

MEASURED, `synthutil_hier_gdn_block.rpt` from each run:

| leaf | N=1 | N=2 | delta | ratio |
|---|---:|---:|---:|---:|
| `u_recur` `gdn_recur_pipe` | 27,910 | **17,114** | **-10,796** | **0.613** |
| `(gdn_block)` glue | 7,610 | 6,854 | -756 | 0.901 |
| `u_exp` `gdn_exp_capture` | 850 | 839 | -11 | 0.987 |
| `u_silu_conv` `gdn_silu` | 4,155 | 4,146 | -9 | 0.998 |
| `u_scal` `gdn_scalar` | 4,652 | 4,645 | -7 | 0.998 |
| `u_conv` `gdn_conv` | 3,658 | 3,653 | -5 | 0.999 |
| `u_l2` `l2norm_rs` | 4,705 | 4,704 | -1 | 1.000 |
| **`u_emit` `gdn_emit_chain`** | **21,710** | **21,700** | **-10** | **1.0000** |
| total | 75,246 | 63,651 | -11,595 | 0.846 |

**Two clean results, and they point opposite ways.**

**The lane-halving hypothesis is CONFIRMED where it was tested.**
`gdn_recur_pipe` fell to 0.613 with `RECUR_LANES 32 -> 16`, and its DSP fell
**129 to 65, exactly half**. That is the one part of section 2.5's model that
survives contact: halving a real throughput generic does remove roughly half of
the unit it dimensions. My predicted 0.50 against a measured 0.613 is the
closest any estimate in this document came.

**`gdn_emit_chain` did not move at all: 21,710 to 21,700, ratio 1.0000, DSP 57
in both.** I credited it with -5,710 LUT and it delivered -10. Its lane count is
a **separate generic that I did not change**, and `rtl/gdn_block.vhd:210-211`
says why it cannot casually be changed: 16 is chosen because "8 misses B's
299.04 MHz and 32 both costs more and closes slower". So unlike C's case the
lever exists -- it is simply **blocked by timing**, not absent.

That distinction is worth keeping. **Subsystem C's invariance is structural and
permanent** (`G = N_QH/N_KVH` is preserved by sharding). **Subsystem B's
residual is a timing constraint on one generic**, which some future Fmax
headroom could unblock. Neither is available today.

### Final corrected arithmetic

```
section 2.5 estimate                            311,877 LUT   89.8%
C: estimated 51,869, MEASURED 84,293            +32,424
B: estimated 52,502, MEASURED 63,596            +11,094
                                                -----------
TP-small, MEASURED where measurable             355,395 LUT
355,395 / 6.32                                  = 56,233 CLB = 102.3%
```

**TP-small does not fit the die. It is over 100%.** And that figure still
grants subsystem A the halving it was never drawn for; if A does not halve
either, TP-small is 415,668 LUT = **119.7%**, which is TP-fast.

**The headline number: tensor parallelism at N=2 removes 12,920 LUT of the
162,583 in B and C combined, which is 7.9%.** Section 2.5 predicted about 39%.

### 11.10 What is now settled, and what A still owes

| claim | status |
|---|---|
| Pipeline parallelism saves ~4% and gives no speedup | stands, structural, section 2.2-2.3 |
| Two cards are an area solution for the 9B | **REFUTED BY MEASUREMENT.** TP-small is 102.3% |
| C shrinks under TP | **REFUTED, structurally.** `G` is invariant. 0.985 |
| B shrinks under TP | **partially.** 0.846, and all of it is `gdn_recur_pipe` |
| Halving a real throughput generic halves its unit | **CONFIRMED**, `gdn_recur_pipe` 0.613, DSP exactly 0.500 |
| A shrinks under TP | **NOT DRAWN.** `ooc_compose_bcd.tcl` has no matvec target |

**A is the one open input and it cannot change the verdict.** Even granting A a
perfect halving, TP-small is 102.3%. A's own halving is the most credible of
the three -- `MACS` is an explicit generic on the matvec path and DSP tracks it
1:1 -- but B's result is the caution: `gdn_recur_pipe` took its generic and
delivered 0.613 rather than 0.500, so "halve the lanes, halve the area" runs
about 20% optimistic even where it works.

### 11.11 Draw counts, stated as required

**Every figure in section 11 is drawn ONCE.** No target was drawn twice. That
is a deliberate stop, not an omission: the verdict is 102.3% against a 90%
target and a 100% hard limit, so the margin is **12.3 percentage points**,
against a per-draw scatter that the project has measured at 1.55x only for
**ROM-dominated** structures. Neither `attn_block` nor `gdn_block` is
ROM-dominated, and the two controls landed within **+2.0%** and **+0.09%** of
independently-produced compose-build rows, which bounds this flow's scatter far
below the gap. A second draw could not move 102.3% under 90%.

**Where a repeat WOULD have been required and is therefore not claimed:** any
conclusion resting on a difference smaller than a few percent. The one such
number here is C's 0.985, and it is not load-bearing as a *number* -- the
load-bearing claim is `G`'s invariance, which is read off `rtl/attn_block.vhd`
and confirmed by DSP holding at exactly 298 across both draws. A count that is
identical to the unit is not a draw.
