# Qwen3.5-9B on one FK33: parallelism, DSP, and the capacity envelope

> **TIME FIGURES RE-DERIVED 2026-08-27 AT THE MEASURED CLOCK.** This document
> computes at two clocks and names both, which was the right structure --
> but **neither of its two clocks is the one the card runs at**. 254.32 MHz is
> `gdn_emit_chain` post-route at **0.85 V** and is not achievable at 0.717 V;
> 299.04 MHz is a 0.85 V synthesis target. The card measures **237.8 MHz at
> 0.717 V** (`sim/ooc_sweep/results.csv:7`). The **cycle counts are unchanged
> and remain the invariant**; a 237.8 MHz column has been added beside the
> existing ones in section 2.2 and the findings that depend on it are restated
> in place rather than deleted. Derivation and method:
> `docs/2026-08-27_budgets-at-the-measured-clock.md`.

**Date:** 2026-08-27. Branch `fpga`. Part `xcvu33p-fsvh2104-2L-e`, one card, N = 1.

**Status: ANALYSIS ONLY. No Vivado was run for this document** (two place-and-route
jobs were already running and a third would contend for memory). No RTL was
modified. Every arithmetic result below was produced by a parametric script
written for this document and kept in a session scratchpad, which is ephemeral;
the formulas and the inputs are therefore reproduced inline in every section so
the document stands on its own.

**Labelling discipline, following the D and C skeletons.** Each number is
MEASURED (a tool was run and the output recorded, with the file named), DERIVED
(arithmetic shown here from MEASURED or spec-normative inputs), or ESTIMATE (a
judgement with its assumption stated). Where two documents disagree, both are
quoted.

**Validation of the method before any 9B number is used.** The cycle and
parameter models below were built parametrically and then evaluated at 27B N=2
first. They reproduce, exactly and without tuning:

| Independent check | This document | Source it must match |
|---|---|---|
| 27B A cycles, all 18 GDN rows and 15 attention rows | every row identical | `docs/superpowers/specs/2026-08-27-D-sequencer-skeleton.md:111-130`, `:158-168` |
| 27B A subtotal per GDN block | 104,112 | D skeleton `:132` |
| 27B A subtotal per attention block | 100,912 | D skeleton `:174` |
| 27B lm_head | 342,560 | D skeleton `:187` |
| 27B A total per token | 6,954,528 | D skeleton `:201` |
| 27B stored weights, all params at 4.5 bpw | 14.0896 GiB | `docs/fpga-hardware-recon.md:38` ("14.09 GiB") |
| 27B stored weights per card at N=2 | 7.0448 GiB | recon `:45` ("7.04 GiB") |
| 27B KV at 262,144 ctx, 1 B/element | 8.590 GB | `rtl/model_cfg_pkg.vhd:88-90` ("8.59 GB") |
| 27B per-card total at N=2 and N=4 | 11.86 / 5.93 GB | `rtl/model_cfg_pkg.vhd:88-90` ("11.86 ... 5.94") |
| 27B D-vec cycles per token | 468,224 | D skeleton `:205` |
| 27B B state sweep at LANES=32 | 589,824 | `sim/tb_model_cfg.vhd:36` |
| 27B B conv at LANES=32 | 18,384 | `docs/superpowers/specs/2026-08-21-gated-deltanet-design.md:1819` |
| 27B C cycle table, all six rows | within 8 cycles on one row | `docs/superpowers/specs/2026-08-27-C-gated-attention-skeleton.md:521-529` |
| 27B C MACS ladder | 32 / 64 / 96 / 192, 384 at two ports | C skeleton `:340`, `:352-358` |

The only row that does not land exactly is C's IMROPE (7,992 against 8,000),
because the spec's row carries an unstated "fill" term that this document
approximates as a 1.115 factor. Nothing turns on 8 cycles.

That agreement is the licence to trust the 9B columns, which are produced by the
same functions with different constants.

---

## 0. Findings, up front

- **F1. Per-card work at 9B N=1 is about two thirds of 27B N=2, not one third,
  and the same for all three subsystems.** A 0.6195x (DERIVED, section 1.1),
  B 0.6667x (DERIVED, and independently pinned by `sim/tb_model_cfg.vhd:53`),
  C 0.6667x (DERIVED, section 1.3). The parent's estimate of 0.67x for A is
  close and 0.33x for C is exactly a factor of 2 out: **0.33x is the ratio of
  whole-MODEL work; the per-CARD ratio is 0.67x because the 27B card holds only
  half its model and the 9B card holds all of its own.** The whole-model ratios
  are A 0.3097x and C 0.3333x, so the parent's number is right for the wrong
  quantity.

- **F2. C's MACS ladder loses its top two rungs at 9B, and this is forced, not
  chosen.** The GQA group falls from 6 to 4, `QH_TILE` must divide the group,
  so the legal ladder becomes **32, 64, 128** at one port per stream (against
  32, 64, 96, 192 at 27B). `MACS = 192` has **no legal `QH_TILE` at 9B**.
  C's array therefore books **256 DSP, not 384**, and C totals **303 DSP against
  431**. Nothing is lost by it: at `MACS = 128` the 9B KV sweep is **1,048,576
  cycles, bit-for-bit the same number as 27B at `MACS = 192`** (section 1.3).
  128 DSP disappear from the budget for free.

- **F3. A is NOT feed-bound at 9B at the achieved clock, and it was never the
  model that made it feed-bound.** Feed-boundness is a property of
  (`ROWS_IF`, `f_core`) alone: demand is `ROWS_IF x 18 B x f`, independent of
  the model. At `ROWS_IF = 58` and 254.32 MHz demand is **265.5 GB/s against
  288.0 GB/s supply**, so A has **7.8% of the device spare**. At 299.04 MHz the
  same `ROWS_IF` demands 312.2 GB/s and is short by 8.4%, exactly as at 27B
  (the D skeleton's 8.75% is the same calculation at a round 300 MHz).
  **The timing miss cured the feed shortfall.** Section 4.
  **RE-DERIVED 2026-08-27: at the MEASURED 237.8 MHz the demand is 248.3 GB/s
  and the spare is 13.8%, not 7.8%.** The finding strengthens; only the margin
  moves.

- **F4. The whole 9B token fits the 39 ms budget with room to spare, at the
  achieved clock, with the 27B parallelism unchanged.** 24.80 ms at
  254.32 MHz, 22.29 ms at 299.04 MHz (section 2). The budget is not the
  constraint at 9B; nothing forces a re-tune.
  **RE-DERIVED 2026-08-27: 26.52 ms at the MEASURED 237.8 MHz**, so F4's
  conclusion survives -- but note it survives for the wrong reason, since
  neither clock it was stated at is reachable, and 39 ms is an inherited
  assumption rather than a budget
  (`docs/2026-08-27_budgets-at-the-measured-clock.md` section 3).

- **F5. 262,144 context does not fit, and the real shortfall is worse than the
  parent's estimate.** Weights at 4.5 bpw are **5.036 GB stored, not 4.5**, and
  the KV record is **272 bytes per 256-element head vector, not 256**, so KV at
  full context is **4.563 GB, not 4.295**. Total **9.626 GB** against 8 GiB
  (8.590 GB), an overshoot of 1.04 GB rather than 0.79. The maximum context that fits is **202,621** (8 GiB, untied
  embedding, BFP record), and **168,732** if the card is treated as 8 decimal GB.
  Section 5.

- **F6. Context is compute-capped far below where it is capacity-capped.** At
  the maximum context that fits, C's sweep alone is **408.6 ms per token**, 10x
  the whole budget. The context that fits inside 39 ms at 254.32 MHz is between
  4,096 and 8,192. Capacity is not the binding constraint on context; C's linear
  sweep is. Section 5.4.

- **F7 (BOTH HALVES SUPERSEDED 2026-08-27, and the coincidence is gone).** At
  the MEASURED **237.8 MHz**, `ROWS_IF = 32` is **41.05 ms and no longer meets
  39 ms**, so it is not the smallest A that does. And `ROWS_IF = 58`
  post-reclaim **has now been synthesised** -- `sim/ooc_sweep/results.csv:7`
  gives 1,914 DSP, exactly as extrapolated, at 237.8 MHz at 0.717 V -- so it is
  no longer the largest ever synthesised either, and recommendation 1 in
  section 6 is **discharged**. The original finding is kept below unaltered.
  **F7 as written:** `ROWS_IF = 32` is simultaneously the smallest A that meets
  the 39 ms budget at 9B and the largest A ever synthesised in the post-reclaim
  form the 1,914 DSP figure prices. `sim/ooc_sweep/results_reclaim_085.csv` stops at
  `ROWS_IF = 32` (1,056 DSP, 345.7 MHz at 0.85 V) and `sim/ooc_sweep/results.csv`
  measures the same point at **275.3 MHz at 0.72 V**. Builds above 32 do exist
  but none of them is this configuration: 48 and 56 are **pre-reclaim** (2,198
  and 2,612 DSP, 276.1 and 287.9 MHz, both missing 300), and 64/80/88 are
  `-max_dsp 2880` capped runs on the **`-2-e` speed grade rather than the target
  `-2L-e`**. So **`ROWS_IF = 58` post-reclaim has never been built**, and 1,914
  DSP is `33.00 x 58` extrapolated 1.8x beyond the measured range with no Fmax
  attached at all. That changes the recommendation in section 6.

---

## 1. Per-card work at 9B N=1 against 27B N=2, per subsystem

### 1.0 Shapes, and where they come from

All from `rtl/model_cfg_pkg.vhd:64-79`. The 27B row is read from the shipped
GGUF's own metadata; the 9B row is from `huggingface.co/Qwen/Qwen3.5-9B`
`config.json` (provenance block, `rtl/model_cfg_pkg.vhd:28-40`). **The 9B
provenance could not be re-verified here** (no network access, and no 9B GGUF on
this box), so the 9B row is taken on the package's authority. See section 7.

| | 9B | 27B | derived |
|---|---|---|---|
| blocks | 32 | 64 | |
| attention layers | 8 | 16 | `blocks / attn_interval` |
| GDN layers | 24 | 48 | |
| hidden | 4096 | 5120 | |
| ffn | 12288 | 17408 | |
| GDN key dim | 2048 | 2048 | `lin_key_heads x lin_head_dim`, **identical** |
| GDN value dim | 4096 | 6144 | `lin_val_heads x lin_head_dim` |
| GDN conv dim | 8192 | 10240 | `2 x key_dim + value_dim` |
| attention query heads | 16 | 24 | |
| attention KV heads | 4 | 4 | **identical** |
| attention head dim | 256 | 256 | **identical** |
| GQA group `G` per card | **4** (N=1) | **6** (N=2) | `q_heads / N / (kv_heads / N)` |
| vocab | 248320 | 248320 | |

The GQA group is the one shape that behaves counter-intuitively: it is
**invariant in N** (both numerator and denominator divide by N) and it drops
from 6 to 4 purely because the model has fewer query heads per KV head. That is
what moves C's ladder in F2.

### 1.1 Subsystem A: parameter count, derived from shapes

Per GDN block, with `H` = hidden, `Kd` = key dim, `Vd` = value dim, `F` = ffn:

```
q, k            2 x H x Kd
v, z            2 x H x Vd
ssm_beta/alpha  2 x H x lin_val_heads
ssm_out             Vd x H
ffn gate/up/down 3 x H x F
depthwise conv      conv_dim x 4
```

Per attention block:

```
attn_q (Q + fused gate)  H x (q_heads x 256 x 2)
attn_k, attn_v       2 x H x (kv_heads x 256)
attn_output              (q_heads x 256) x H
ffn gate/up/down     3 x H x F
```

The `x 2` on `attn_q` is the fused gate, confirmed at 27B by
`attn_q.weight [5120, 12288] = 24 x 256 x 2`
(C skeleton `:53`, `:104`). **At 9B it is an ASSUMPTION** carried over from the
shared architecture. Sensitivity: if the 9B `attn_q` is not doubled, A's token
cost falls by 72,704 cycles, **1.69% of A** (DERIVED).

| | 9B | 27B |
|---|---|---|
| per GDN block | 218,398,720 | 383,262,720 |
| per attention block | 209,715,200 | 372,244,480 |
| all blocks | 6,919,290,880 | 24,352,522,240 |
| lm_head | 1,017,118,720 | 1,271,398,400 |
| **streamed per token (whole model)** | **7,936,409,600** | **25,623,920,640** |
| embedding table (looked up, not streamed) | 1,017,118,720 | 1,271,398,400 |
| **stored, all params** | **8,953,528,320** | **26,895,319,040** |

At 4.5 bits per weight (`0.5625 B`, 4-bit weight plus one 16-bit scale per 32,
D skeleton `:339`):

| | 9B N=1 | 27B N=2 |
|---|---|---|
| streamed per token, **per card** | **4.4642 GB** | **7.2067 GB** |
| stored, per card | 5.0364 GB (4.6905 GiB) | 7.5643 GB (7.0448 GiB) |

**Per-card ratio 4.4642 / 7.2067 = 0.6195. Whole-model ratio 0.3097.**

Three corrections fall out of this and each matters somewhere else:

1. **The parent's 6.75 GB for 27B N=2 is 6.3% low.** 6.75 is exactly
   `27e9 x 4 bits / 8 / 2`: it uses the nominal parameter count at exactly 4
   bits and ignores the 0.5 bits per weight of scale. The correct streamed
   figure is 7.2067 GB.

2. **The parent's 4.50 GB for 9B N=1 is right to 0.8%, by coincidence.**
   `9e9 x 4 bits / 8 = 4.50` happens to land within 0.8% of the correct
   `7.936e9 x 4.5 bits / 8 = 4.4642`, because the streamed set is 12% smaller
   than the nominal parameter count and 4.5 bits is 12.5% more than 4. The two
   errors nearly cancel. **Do not reuse the method**; it does not cancel at 27B,
   where it is 6.3% out.

3. **D skeleton `:269` and `:290` use 7,559 MB as "the weight read" per token
   and that is the wrong quantity.** 7.559 GB is `recon:45`'s **7.04 GiB stored
   weight shard**, which includes the embedding table. The per-token streamed
   figure is 7.2067 GB unpadded, or 7.2605 GB counting A's tile padding. D's own
   cycle table implies 7.2605 (`6,954,528 cycles x 58 rows x 18 B/cycle`), so
   the document contradicts itself by 4.1% one section apart. The consequence is
   small (the activation re-read fraction becomes 6.13%, not 5.89%) but the
   citation is wrong.

### 1.2 Subsystem B: GDN

`gdn_sweep_cycles` is normative in `rtl/model_cfg_pkg.vhd:141-149` and pinned by
`sim/tb_model_cfg.vhd:36,53`:

```
9B  N=1, LANES=32: 128 x 128 x 32 vheads / 32 = 16,384 per layer x 24 = 393,216
27B N=2, LANES=32: 128 x 128 x 24 vheads / 32 = 12,288 per layer x 48 = 589,824
ratio = 0.6667 exactly
```

The other B terms, rebuilt at 9B by the same formulas the B spec uses:

| term | 9B N=1 | 27B N=2 | source of the formula |
|---|---|---|---|
| state sweep, LANES=32 | 393,216 | 589,824 | `model_cfg_pkg:141` |
| conv, `2 x nch x layers / LANES + 3 x layers x 21` | 13,800 | 18,384 | B spec `:1826-1831` |
| silu at 4 per cycle | 73,728 | 98,304 | B spec `:1818`, `:1727-1729` |
| output rmsnorm + L2, 3N 4-lane | 170,496 | 213,120 | B spec `:1817` |
| **nonlinear + conv** | **258,024** | **329,808** | |
| emit chain, MEASURED 719 cycles/head | 552,096 | 828,144 | `docs/debugging/2026-08-27_gdn-emit-chain-w-latch.md`, via D skeleton `:144-148` |
| **B bound = max of the above** | **552,096** | **828,144** | |

Two notes on this table, both honest problems rather than results:

- **The B spec's own overlapped subtotal is stale.** B spec `:1820` sums the
  nonlinear terms to 342,144, which is `213,120 + 98,304 + 30,720` using the
  **superseded** conv figure that the same table strikes through two rows above
  (`:1819`, `~~30,720~~ 18,384`). The correct sum is 329,808. Immaterial (B is
  emit-bound either way) but it is a live arithmetic error in a shipped table.
- **The emit-chain per-head cost is an ESTIMATE.** The MEASURED figure is 17,253
  cycles for 24 heads at a 1 ns testbench clock; this document divides it by 24
  and multiplies by 32. That assumes the chain's cost is linear in heads with
  zero intercept. The DSP and Fmax were measured flat across HEADS 8/16/24/32
  (`docs/debugging/2026-08-27_gdn-emit-chain-sizing.md:78-81`); the **cycle**
  cost was not swept in HEADS.

**B is emit-bound at both scales, by 1.40x at both.** The ratio `552,096 /
828,144 = 0.6667` is the same 2/3 as the sweep, because both scale as
`val_heads x gdn_layers` and `(32 x 24) / (24 x 48) = 2/3`.

### 1.3 Subsystem C: attention

Sweep MACs per card per token, with `L` attention layers, `Hq` query heads per
card, `D = 256` head dim, and the factor 2 for score plus PV:

```
9B  N=1:  8 x 16 x 256 x 2 x ctx = 65,536 x ctx
27B N=2: 16 x 12 x 256 x 2 x ctx = 98,304 x ctx
ratio = 0.6667 exactly
```

Whole-model, without the per-card divisor: `8 x 16` against `16 x 24`, ratio
**0.3333**. That is the number the parent's 0.33x estimate matches. It is the
right arithmetic applied to the wrong side of the tensor-parallel split.

Cycle model at 9B, same six rows as C skeleton `:521-529`, at `MACS = 128`,
`ctx = 2048`:

| row | arithmetic | 9B cycles | 27B cycles |
|---|---|---|---|
| KV sweep | `8 lyr x 4 kvh x 2048 pos x (4 x 256 x 2 / 128)` | **1,048,576** | 1,048,576 |
| rescale stalls | `27 events x 8 cyc x 32 (lyr,kvh)` | 6,912 | 9,728 |
| QK-norm, exposed | `8 lyr x (4 Q + 4 K) x 814` | 52,096 | 104,192 |
| IMROPE | `8 lyr x 20 heads x 32 pairs + fill` | 5,708 | 8,000 |
| KV quantize + write | `8 lyr x 8 vectors x 2 passes x 256` | 32,768 | 32,768 |
| gate + output | `8 lyr x (4 kvh x (4 x 46 + 4 x 256) + 4096)` | 71,424 | 107,136 |
| **C total** | | **1,217,484** | 1,310,400 |

Rescale events derived the way C skeleton `:545` derives them, at `G = 4`:
`sum_{k=1..2048} [1 - (1-1/k)^4] = 26.67`, rounded to 27. At `G = 6` the same
sum gives 37.56, and the spec rounds to 38. The formula is reproduced, only the
group changed.

**The KV sweep is identical at both scales**, 1,048,576 cycles, because
`L x Hkv x (G x D x 2 / MACS)` is `16 x 2 x 16` at 27B and `8 x 4 x 16` at 9B.
C at 9B is therefore 7.1% cheaper in cycles than at 27B, for 30% less DSP.

---

## 2. The parallelism needed to hit the token budget

### 2.1 Which budget, and why

**39 ms is used, and it is the only sourced figure available.** Its provenance:
`docs/superpowers/specs/2026-08-24-transformer-sequencer-design.md:829`
("Roughly ~39 ms => ~26 tok/s at N=2"), assembled from the five-row table at
`:821-827`, and explicitly headed "informative, derived -- nothing here is
measured" (`:816`). The E skeleton restates it at `:255` with the same caveat.

**Three reasons to hold it loosely, all recorded elsewhere:**

- It is a **27B N=2** budget. Applying it to 9B N=1 is a choice, not an
  inheritance. If anything a 9B bring-up vehicle deserves a tighter one.
- `docs/2026-08-27_direction-review-fable.md:250-257` says the tok/s ladder "has
  not been re-derived and is now misleading by ~2-3x", and that at the 0.717 V
  operating point the real budget is closer to 45-50 ms.
- `docs/fpga-hardware-recon.md:70` still carries a 16.5 ms bandwidth-bound
  ceiling from a **460 GB/s** assumption that the measured 288.0 GB/s
  (`hw/fk33/results/hbmbw_30port_300mhz.txt`, via D skeleton `:371`) has since
  replaced. That row should not be used.

### 2.2 Token budget at 9B N=1, ctx 2048, `MACS = 128`, `LANES = 32`

E is **zero** at N=1: there is no collective. That removes 0.60 to 0.71 ms and,
more importantly, removes an entire unbuilt subsystem from the critical path.

At **237.8 MHz** (the clock the card actually reaches at its MEASURED 0.717 V
VCCINT, `sim/ooc_sweep/results.csv:7`; added 2026-08-27, and this is now the
primary column):

| `ROWS_IF` | DSP_A | die DSP | A demand | A ms | B ms | C ms | D-vec | D-ctrl | **total** | tok/s |
|---|---|---|---|---|---|---|---|---|---|---|
| 24 | 792 | 1,350 | 102.7 | 43.53 | 2.32 | 5.12 | 0.97 | 0.05 | 51.99 | 19.2 |
| 32 | 1,056 | 1,614 | 137.0 | 32.59 | 2.32 | 5.12 | 0.97 | 0.05 | **41.05** | 24.4 |
| 40 | 1,320 | 1,878 | 171.2 | 26.18 | 2.32 | 5.12 | 0.97 | 0.05 | 34.64 | 28.9 |
| 48 | 1,584 | 2,142 | 205.5 | 21.82 | 2.32 | 5.12 | 0.97 | 0.05 | 30.28 | 33.0 |
| 53 | 1,749 | 2,307 | 226.9 | 19.78 | 2.32 | 5.12 | 0.97 | 0.05 | 28.24 | 35.4 |
| **58** | **1,914** | **2,472** | **248.3** | **18.06** | **2.32** | **5.12** | **0.97** | **0.05** | **26.52** | **37.7** |
| 62 | 2,046 | 2,604 | 265.4 | 16.98 | 2.32 | 5.12 | 0.97 | 0.05 | 25.44 | 39.3 |

DERIVED, same cycle counts as the 254.32 MHz table below, divided by 237.8 MHz
instead. The A demand column scales with the core clock; the 288.0 GB/s supply
does not, so **every row is fed at this clock** and A is array-limited
throughout (the clock-invariant HBM floor is 15.57 ms, below every A row here).
`ROWS_IF = 32` lands at **41.05 ms and no longer meets 39 ms**.

The two tables below are kept as the **0.85 V reference**, superseded as
operating points but not deleted. **254.32 MHz is `gdn_emit_chain` post-route
at 0.85 V and is not achievable at 0.717 V**; 299.04 MHz is a 0.85 V synthesis
target.

At **254.32 MHz** (the achieved post-route clock, MEASURED,
`sim/ooc_micro/pnr_results.csv:12`; **0.85 V, superseded 2026-08-27**):

| `ROWS_IF` | DSP_A | die DSP | A demand | A ms | B ms | C ms | D-vec | D-ctrl | **total** | tok/s |
|---|---|---|---|---|---|---|---|---|---|---|
| 24 | 792 | 1,350 | 109.9 | 40.70 | 2.17 | 4.79 | 0.91 | 0.05 | 48.61 | 20.6 |
| **32** | 1,056 | 1,614 | 146.5 | 30.47 | 2.17 | 4.79 | 0.91 | 0.05 | **38.38** | 26.1 |
| 40 | 1,320 | 1,878 | 183.1 | 24.48 | 2.17 | 4.79 | 0.91 | 0.05 | 32.40 | 30.9 |
| 48 | 1,584 | 2,142 | 219.7 | 20.40 | 2.17 | 4.79 | 0.91 | 0.05 | 28.31 | 35.3 |
| 53 | 1,749 | 2,307 | 242.6 | 18.49 | 2.17 | 4.79 | 0.91 | 0.05 | 26.40 | 37.9 |
| **58** | 1,914 | 2,472 | 265.5 | 16.88 | 2.17 | 4.79 | 0.91 | 0.05 | **24.80** | 40.3 |
| 62 | 2,046 | 2,604 | 283.8 | 15.88 | 2.17 | 4.79 | 0.91 | 0.05 | 23.79 | 42.0 |

At **299.04 MHz** (B's target, MEASURED as met by the emit chain in OOC
synthesis but not post-route; **a 0.85 V analysis clock, kept as the reference
column, superseded as an operating point 2026-08-27**):

| `ROWS_IF` | DSP_A | die DSP | A demand | A ms | **total** | tok/s |
|---|---|---|---|---|---|---|
| 26 | 858 | 1,416 | 140.0 | 31.96 | 38.70 | 25.8 |
| 32 | 1,056 | 1,614 | 172.2 | 25.92 | 32.64 | 30.6 |
| 40 | 1,320 | 1,878 | 215.3 | 20.82 | 27.55 | 36.3 |
| 48 | 1,584 | 2,142 | 258.4 | 17.35 | 24.08 | 41.5 |
| **53** | 1,749 | 2,307 | 285.3 | 15.73 | **22.46** | 44.5 |
| **58** | 1,914 | 2,472 | 312.2 | 15.57 | **22.29** | 44.9 |
| 62 | 2,046 | 2,604 | 333.7 | 15.65 | 22.38 | 44.7 |

"A ms" is `max(array time, bytes / 288 GB/s)`: the array time when the demand is
under supply, otherwise the array time scaled by the shortfall, which is the
same rule D skeleton `:202` applies.

### 2.3 The answers

**Minimum parallelism to hit 39 ms at 9B N=1, ctx 2048:**

| clock | min `ROWS_IF` | `MACS` | A DSP | die DSP | achieved |
|---|---|---|---|---|---|
| 299.04 MHz (target, 0.85 V) | **26** | 128 | 858 | 1,416 (49.2%) | 38.70 ms |
| 254.32 MHz (0.85 V post-route) | **32** | 128 | 1,056 | 1,614 (56.0%) | 38.38 ms |
| ~~214.1 MHz (0.717 V bound)~~ | ~~40~~ | ~~128~~ | ~~1,320~~ | ~~1,878 (65.2%)~~ | ~~38.48 ms~~ |
| **237.8 MHz (MEASURED at 0.717 V)** | **DISPUTED, see below** | 128 | | | |

> **RE-DERIVED 2026-08-27.** The **214.1 MHz row is SUPERSEDED and struck**: it
> is `254.32 x (1 - 0.158)`, a bound built on a derate that a direct
> measurement has now replaced. The card measures **237.8 MHz**
> (`sim/ooc_sweep/results.csv:7`).
>
> **The minimum `ROWS_IF` at 237.8 MHz is NOT SETTLED and no value is written
> into the table above.** `docs/2026-08-27_budgets-at-the-measured-clock.md`
> section 7.7 gives **34**. Recomputing here from this document's own cycle
> counts gives **36**: the non-A terms sum to 8.462 ms at 237.8 MHz
> (B 552,096 + C 1,217,484 + D-vec 230,400 + D-ctrl 12,275 cycles), leaving
> 30.54 ms for A, and A is **30.78 ms at `ROWS_IF = 34`** (total 39.24 ms, a
> miss) against **29.02 ms at 36** (total 37.48 ms, a fit). `ROWS_IF` must also
> be **even** (D skeleton `:513-520`, `NPORTS_W = ROWS_IF x 128 / 256` must be
> an integer), so 35 is not available as a compromise.
>
> The two answers can be reconciled: **34 is the minimum if B is taken at its
> sweep-only floor** (393,216 cycles, 1.653 ms, non-A 7.79 ms), and **36 is the
> minimum if B is taken at the emit-bound estimate this document's own tables
> use** (552,096 cycles, 2.32 ms). B's emit-chain cycle cost is an ESTIMATE
> measured only at HEADS=24, so the difference is B's unresolved range and not
> an arithmetic error on either side. Recorded as OPEN.

For comparison, the same question at 27B N=2, `MACS = 192`: 46 rows at
299.04 MHz, **57 rows at 254.32 MHz**, 74 rows at 214.1 MHz. The 27B choice of
`ROWS_IF = 58` is the tightest of these and has one row of margin at the
achieved clock; at 0.717 V it does not meet 39 ms at any affordable `ROWS_IF`
(74 rows is 2,442 DSP for A alone, and the die would be 3,000).

The 214.1 MHz row is `254.32 x (1 - 0.158)`, using the **bounded** derate from
`docs/debugging/2026-08-25_voltage-derate-on-hardware.md:29` ("at 0.717 V this
design's delay increase is <= 18.8%, i.e. its Fmax derate is no worse than
-15.8%"). The true derate is still unmeasured (`:207`), so this row is a
**worst-known bound, not a prediction**.

**`MACS` is not a free parameter at 9B.** At `MACS = 64` the C row grows from
4.79 ms to 8.91 ms at 254.32 MHz and the token to 28.92 ms, so 64 also meets
39 ms. But 128 costs only 128 DSP more than 64 and buys 4.1 ms, which is the
best DSP-per-millisecond ratio anywhere in this document. Take 128.

---

## 3. The DSP that implies

### 3.1 The per-subsystem models, and what they are worth

| subsystem | model | status |
|---|---|---|
| A | `DSP = 33.00 x ROWS_IF`, intercept 0 | MEASURED at `ROWS_IF` 8/16/24/32 post-reclaim, `sim/ooc_sweep/results_reclaim_085.csv`. Exact: 264 / 528 / 792 / 1,056. **Extrapolated beyond 32.** |
| B | 226 to 251 | see 3.3 |
| C | `DSP = 2 x MACS + 47` | array MEASURED per lane at 2 DSP (C skeleton `:343-346`); aux 47 derived per-unit at C skeleton `:365-377` |
| D | 28 shared, 52 unshared, at `LANES_V = 8` | MEASURED, `docs/debugging/2026-08-25_d-vec-dsp-measured.md` via D spec `:840` |
| E | 0 | by construction; and **absent entirely at N = 1** |

**The `46.50 x ROWS_IF` figure is the PRE-reclaim slope** (A spec `:1674`) and
is not the one to use against the booked 1,914. D skeleton `:382-383` charges
"5 x 46.5 = 233 DSP" for the five rows between 53 and 58 while the same
sentence cites the post-reclaim 1,914. At the post-reclaim 33.00/row those five
rows are **165 DSP**, not 233. Both slopes are real; they belong to different
builds. `1,914 = 33.00 x 58` is post-reclaim, so 165 is the consistent number.

### 3.2 C's ladder at 9B, worked

`MACS = QH_TILE x DIM_TILE`. `DIM_TILE = 32` is forced by the 256-bit HBM AXI
beat delivering exactly one 32-element `KV_BLOCK` (C skeleton `:332-336`).
`QH_TILE` must divide the GQA group `G` or the last sub-tile idles
(C skeleton `:337`).

**At 27B N=2, `G = 6`:** divisors 1, 2, 3, 6, so `MACS` in {32, 64, 96, 192}.

**At 9B N=1, `G = 4`:** divisors **1, 2, 4**, so `MACS` in **{32, 64, 128}**.

| 9B `QH_TILE` | `DIM_TILE` | `MACS` | `DSP_array` | cycles per (pos, KV head) | port duty per master |
|---|---|---|---|---|---|
| 1 | 32 | 32 | 64 | `4 x 256 x 2 / 32` = 64 | `8.5/64` = 13.3% |
| 2 | 32 | 64 | 128 | 32 | 26.6% |
| **4** | **32** | **128** | **256** | **16** | **53.1%** |
| 1 | 64 | 64 | 128 | 32 | 53.1% (two ports per stream) |
| 2 | 64 | 128 | 256 | 16 | 106.2% (does not fit) |
| 4 | 64 | 256 | 512 | 8 | 212.5% (does not fit) |

**`MACS = 96` and `MACS = 192` are both gone.** 3 and 6 do not divide 4. The
96 rung was C's stated single fallback at 27B (C skeleton `:460`, "it is the
only fallback"); at 9B **the fallback below 128 is 64, which doubles the sweep**
from 3.5 to 7.0 ms at 299.04 MHz. That is a different and slightly worse
fallback ladder, and it is worth knowing before a routing failure forces the
question.

**`MACS = 128` at 9B is throughput-equal to `MACS = 192` at 27B.** Both give 16
cycles per (position, KV head) and both give a 1,048,576-cycle sweep. The 128
extra DSP that 192 costs buys nothing at 9B even if the tiling were made legal
by masking two idle lanes, because the group only has 4 heads to feed.

The 53.1% port duty at `MACS = 128` is identical to 27B's at 192, so C's HBM
port allocation (two masters, one port each) is unchanged.

### 3.3 B's row, which has a live bookkeeping ambiguity

The C skeleton's non-C table books B at **226**
(`docs/superpowers/specs/2026-08-27-C-gated-attention-skeleton.md:427`). The
GDN audit assembles it from measured per-unit rows at **227**
(`docs/debugging/2026-08-26_gdn-spec-audit.md:511-525`):

```
gdn_recur_pipe  LANES=32   129      rmsnorm_rs LANES=4  40
l2norm_rs       LANES=2     26      gdn_silu   LANES=4   8
gdn_conv        LANES=4     16      gdn_scalar           7
gdn_head_emit                0      gdn_y_emit           1   -> 227
```

**Both predate the assembled emit chain.** `gdn_emit_chain` at the adopted
`SILU_LANES=16 / RMS_LANES=4` measures **73 DSP** for the four units the list
above prices at `0 + 40 + 8 + 1 = 49`
(`docs/debugging/2026-08-27_gdn-emit-chain-sizing.md:33,55`;
`sim/ooc_micro/pnr_results.csv:12` confirms 73 post-route). B's honest row
today is therefore **251**, and 226/227 is 24-25 DSP low.

This document carries B at **227** so its totals are comparable with the
existing die tables, and flags that **every total below is 24 DSP optimistic**
for that reason. It is not this document's call to re-book B.

**B's DSP does not change between 9B and 27B.** `gdn_recur_pipe` is
`4 x LANES + 1` and the emit chain is MEASURED flat at 73 DSP across HEADS
8, 16, 24 and 32 (`gdn-emit-chain-sizing.md:78-81`) -- and 32 is exactly the 9B
per-card value head count, so the measurement covers the 9B case directly rather
than by extrapolation. This is the cleanest instance of the parent's own point
that DSP is set by parallelism, not by model size.

### 3.4 Summary table: DSP per subsystem, 9B against 27B

| subsystem | 27B N=2 | 9B N=1, 27B parallelism | 9B N=1, re-tuned to the budget | basis |
|---|---|---|---|---|
| **A** | 1,914 (`ROWS_IF` 58) | 1,914 (`ROWS_IF` 58) | **1,056** (`ROWS_IF` 32) | `33.00 x ROWS_IF` |
| **B** | 227 | 227 | 227 | `LANES = 32` unchanged; emit chain flat in HEADS |
| **C** | 431 (`MACS` 192) | **303** (`MACS` 128, forced) | 303 (`MACS` 128) | `2 x MACS + 47` |
| **D** | 28 | 28 | 28 | `LANES_V = 8`, shared |
| **E** | 0 | 0 (absent) | 0 (absent) | no collective at N=1 |
| **total** | **2,600** | **2,472** | **1,614** | |
| of 2,880 | 90.3% | **85.8%** | **56.0%** | |
| with B re-booked at 251 | 2,624 (91.1%) | 2,496 (86.7%) | 1,638 (56.9%) | section 3.3 |
| with C aux as-booked (54) | 2,607 (90.5%) | 2,479 (86.1%) | 1,621 (56.3%) | C skeleton `:441` |
| with D unshared (52) | 2,624 (91.1%) | 2,496 (86.7%) | 1,638 (56.9%) | D spec `:840` |

**What the 9B configuration leaves on the table:**

- Keeping the 27B parallelism: **128 DSP freed (4.4% of the die), entirely from
  C, and entirely forced by the GQA group.** There is no discretionary saving at
  all in this column.
- Re-tuning A to the budget: **a further 858 DSP (29.8% of the die)**, taking the
  die from 90.3% to 56.0%.
- Not modelled as a saving, but real: **subsystem E disappears**, along with the
  PCIe P2P bring-up, the 5.12 MB per token of collective traffic
  (D skeleton `:458`), and the unresolved 0.42-versus-0.6 ms citation conflict
  (D skeleton `:461-466`).

---

## 4. Is A still feed-bound at 9B?

**Verifying the parent's inputs first.**

| parent's figure | verdict | correct value |
|---|---|---|
| 4.50 GB/token at 9B N=1 | **right to 0.8%, by cancelling errors** | 4.4642 GB (section 1.1) |
| 6.75 GB/token at 27B N=2 | **6.3% low** | 7.2067 GB unpadded, 7.2605 GB with A's tile padding |
| 288 GB/s supply | **correct** | MEASURED, 30 ports x 32 B x 300 MHz, D skeleton `:371` |

**The verdict, and it depends on the clock rather than the model.**

Demand is `ROWS_IF x 18 B/cycle x f_core`. The model appears nowhere in it. What
the model sets is how long that rate has to be sustained, not the rate.

| config | clock | demand | supply | fed? | A time |
|---|---|---|---|---|---|
| 27B N=2, `ROWS_IF` 58 | 299.04 MHz | 312.2 GB/s | 288.0 | **NO, -7.8%** | 25.21 ms |
| 27B N=2, `ROWS_IF` 58 | **254.32 MHz** | 265.5 GB/s | 288.0 | **yes, 7.8% spare** | 27.35 ms |
| 9B N=1, `ROWS_IF` 58 | 299.04 MHz | 312.2 GB/s | 288.0 | **NO, -7.8%** | 15.57 ms |
| 9B N=1, `ROWS_IF` 58 | **254.32 MHz** | 265.5 GB/s | 288.0 | **yes, 7.8% spare** | 16.88 ms |
| 9B N=1, `ROWS_IF` 32 | 254.32 MHz | 146.5 GB/s | 288.0 | yes, 49% spare | 30.47 ms |

**So: at 9B, at the ACHIEVED clock, A is NOT feed-bound. At the TARGET clock it
is, by exactly the same 8.4% as at 27B.** The bandwidth-balanced `ROWS_IF` is
`288.0e9 / (18 x f)`: **62.9 at 254.32 MHz**, 53.5 at 299.04, 53.3 at 300.

Two consequences worth stating plainly:

- **The timing miss partly pays for itself.** Dropping 299.04 to 254.32 MHz is
  a 15.0% clock loss but only an **8.4% loss in A's effective time** (15.57 to
  16.88 ms at 9B; 25.21 to 27.35 at 27B), because the cycles A loses were
  cycles it was stalling on HBM anyway. This is the quantitative form of the
  parent's "the freed cycle budget absorbs the timing miss", and it is correct
  for a reason the parent did not state.
- **There is a hard floor no `ROWS_IF` crosses.** `4.4642 GB / 288 GB/s =
  15.50 ms` for A at 9B (25.02 ms at 27B N=2). In the 299.04 MHz table of
  section 2.2, `ROWS_IF` 53, 58 and 62 give 15.73, 15.57 and 15.65 ms: all three
  are sitting on that floor, and the 9 DSP-hundreds between them buy 0.16 ms.
  **At 299.04 MHz, `ROWS_IF = 53` is the last row that buys anything.**

**Not resolved here: the port count is a separate constraint and it is tighter
than the bandwidth one.** D skeleton `:390-422` shows A's HBM port count does not
close at 300 MHz (33 wanted of 30 available at `ROWS_IF = 48`, 43 of 30 at 58),
because A spec `:15.1` provisions at 1.3x and the MEASURED per-port rate at
300 MHz is 9.6 GB/s, not the 14.4 the table assumed. Redone at 9B, weights
`ROWS_IF x 16 B x f` and scales `ROWS_IF x 2 B x f`:

| config | weights | scales | ports at 1.3x | ports at 1.0x |
|---|---|---|---|---|
| `ROWS_IF` 58 @ 299.04 MHz | 277.5 GB/s | 34.7 | **43 of 30** | 33 of 30 |
| `ROWS_IF` 58 @ 254.32 MHz | 236.0 GB/s | 29.5 | **36 of 30** | 28 of 30 |
| `ROWS_IF` 32 @ 254.32 MHz | 130.2 GB/s | 16.3 | **21 of 30** | 16 of 30 |

**Being inside the aggregate bandwidth does not make the port count fit.** At
`ROWS_IF = 58` and 254.32 MHz A is 7.8% under the device supply and still wants
36 ports at the spec's own provisioning, or 28 of 30 with no provisioning at
all, leaving 2 for B's four and C's two. At `ROWS_IF = 32` it wants 21, leaving
9. **That is a genuine architectural relief that only the re-tuned column gets,
and it is an argument the token budget alone does not surface.**

---

## 5. The capacity envelope

### 5.1 Verifying the parent's figures

| parent's figure | verdict |
|---|---|
| "9B at INT4 is roughly 4.5 GB of weights" | **11% low.** All params at 4.5 bpw is **5.0364 GB** (4.6905 GiB). The same understatement is in `rtl/model_cfg_pkg.vhd:82`, which says "about 4.5 GB against 8 GB HBM". 4.5 GB is `9e9 x 4 bits` and drops the scales. |
| KV `= ctx x attn_layers x kv_heads x head_dim x 2 x 1 byte` | **arithmetic correct, formula 6.25% low.** `262,144 x 8 x 4 x 256 x 2 x 1 = 4,294,967,296 B = 4.295 GB`, exactly as stated. But C's on-HBM KV record is **272 bytes** for a 256-element head vector: `8 B block exponents + 8 B pad + 256 B mantissas` (C skeleton `:167`). The formula counts mantissas only. |
| "8.79 GB total against 8 GB: does NOT fit" | **conclusion right, margin understated.** Correct total is **9.626 GB** (weights 5.036 + KV 4.563 + GDN and conv state 0.026), against **8 GiB = 8.590 GB**, so the overshoot is **1.04 GB, not 0.79**. Against a decimal 8 GB it is 1.63 GB. |

Also missing from the parent's accounting and small but not zero: the **GDN
recurrent state must be HBM-resident**, `128 x 128 x 32 value heads x 24 layers
x 2 B = 25.17 MB`, plus `8192 x 3 x 2 B x 24 = 1.18 MB` of conv history. The 2
bytes per state element is inferred from B spec `:1707`'s 37.75 MB at 27B N=2,
which this document reproduces exactly at `128 x 128 x 24 x 48 x 2`.

### 5.2 Maximum context that fits one card

```
KV bytes per position = attn_layers x kv_heads x 2 (K and V) x record
                      = 8 x 4 x 2 x 272 = 17,408 B          (BFP record)
                      = 8 x 4 x 2 x 256 = 16,384 B          (mantissa only)

available = HBM - weights - GDN state - conv state
max ctx   = floor(available / bytes per position)
```

| HBM taken as | embedding | weights | available | KV record | **max context** |
|---|---|---|---|---|---|
| **8 GiB = 8,589,934,592 B** | untied | 5.036 GB | 3.527 GB | 272 B | **202,621** |
| 8 GiB | untied | 5.036 GB | 3.527 GB | 256 B (naive) | 215,285 |
| 8 GiB | tied | 4.464 GB | 4.099 GB | 272 B | 235,487 |
| **8 GB = 8,000,000,000 B** | untied | 5.036 GB | 2.937 GB | 272 B | **168,732** |
| 8 GB | tied | 4.464 GB | 3.509 GB | 272 B | 201,598 |

**Recommended headline: 202,621 at 8 GiB with an untied embedding**, which is
the conservative reading on the parameter side and the generous reading on the
capacity side. It is **77.3% of the 262,144 the model supports**
(`rtl/model_cfg_pkg.vhd:71`).

Two inputs this rests on that are **not verified here**:

- **Whether the 9B ties its embedding to the lm_head.** Untied is assumed
  (it costs 0.572 GB and 32,866 positions of context). Nothing in the repo
  states it either way. If tied, the answer is 235,487.
- **8 GiB versus 8 GB.** `docs/fpga-hardware-recon.md:38` says "One FK33 holds
  8 GiB"; `:176` says "8 GB HBM2" in a comparison table. The VU33P carries two
  4 GiB HBM2 stacks, so 8 GiB is the physically correct reading, but the
  repo contradicts itself and the difference is 33,889 positions.

### 5.3 What changes at 2 bytes of KV mantissa

The record becomes `8 + 8 + 512 = 528 B`, a **1.941x** growth (not 2x: the
16-byte header does not double).

```
KV bytes per position = 8 x 4 x 2 x 528 = 33,792 B
max ctx (8 GiB, untied) = 3,527,174,412 / 33,792 = 104,380
```

| | 1 B mantissa | 2 B mantissa |
|---|---|---|
| bytes per position | 17,408 | 33,792 |
| KV at 262,144 ctx | 4.563 GB | 8.858 GB |
| max context, 8 GiB untied | **202,621** | **104,380** |
| max context, 8 GB untied | 168,732 | 86,922 |
| KV read per token at ctx 32,768 | 0.570 GB | 1.107 GB |

**It halves the context and it is not otherwise free.** C's lane is specified as
`score q s16 x k s8` and `PV e u13 x v s8` (C skeleton `:304`), both of which fit
one DSP48E2 tile. A 16-bit KV mantissa makes the score `16 x 16` and the PV
`13 x 16`, which still fit 27x18 -- **so the lane cost does not change**, but
the 8.5-beat record becomes 16.5 beats, and **port duty at `MACS = 128` goes
from 53.1% to 103.1%: it no longer fits one port per stream.** A 2-byte KV
therefore forces `MACS` down to 64 as well, doubling C's sweep. That is the
expensive consequence, not the capacity.

### 5.4 Context is compute-capped, not capacity-capped

C's sweep is linear in context. At 9B, `MACS = 128`, 254.32 MHz (a **0.85 V**
clock; the **237.8 MHz** restatement follows the table):

| ctx | C ms | token ms | KV read per token | HBM floor |
|---|---|---|---|---|
| 2,048 | 4.79 | 24.80 | 0.036 GB | 15.62 ms |
| 4,096 | 8.91 | 28.92 | 0.071 GB | 15.75 ms |
| **8,192** | 17.16 | **37.17** | 0.143 GB | 16.00 ms |
| 16,384 | 33.66 | 53.66 | 0.285 GB | 16.49 ms |
| 32,768 | 66.64 | 86.65 | 0.570 GB | 17.48 ms |
| 131,072 | 264.55 | 284.56 | 2.282 GB | 23.42 ms |
| 202,621 (capacity max) | 408.60 | 428.60 | 3.527 GB | 27.75 ms |

> **RE-DERIVED 2026-08-27 at the MEASURED 237.8 MHz** (same cycles, x1.06947).
> The KV-read and HBM-floor columns are byte counts over a clock-invariant
> 288.0 GB/s supply and do NOT move:
>
> | ctx | C ms @237.8 | token ms @237.8 |
> |---|---|---|
> | 2,048 | 5.12 | 26.52 |
> | 4,096 | 9.53 | 30.93 |
> | **8,192** | 18.35 | **39.75** |
> | 16,384 | 35.99 | 57.39 |
> | 32,768 | 71.27 | 92.67 |
>
> The conclusion below survives, and at this clock it becomes strict rather
> than approximate: 8,192 lands at **39.75 ms, just over 39**, where at
> 254.32 MHz the same row read 37.17 ms and was just under.
> `docs/2026-08-27_budgets-at-the-measured-clock.md` section 5.3.

**The context that fits inside 39 ms is between 4,096 and 8,192.** The context
that fits in memory is 202,621. The gap is a factor of about 30, and it is C's
sweep, not capacity, that closes it. Quoting a "maximum context" without this
row attached would be misleading, which is why it is here.

A separate reason not to quote long context yet: C skeleton `:283-288` records
that `MAXCTX` is pinned at 2,048 in every width in the C spec (`s` at u26, the
divider at NW = 44, the SIN phase) and that "nothing in this document is valid
at 32K without re-deriving those three widths". Everything above 32K in the
table is arithmetic on a design that has not been dimensioned for it.

---

## 6. Recommendation

**The parent's position:** do not re-tune parallelism down for 9B, because
keeping the 27B parallelism means what you validate is what you ship, and the
freed cycle budget absorbs the timing miss.

**Verdict: agree on B unconditionally; the position is not available at all for
C; and on A it is conditionally right but currently rests on a configuration
that has never been synthesised. Recommendation: keep `LANES = 32`, take
`MACS = 128` because there is no legal alternative, and make `ROWS_IF = 58`
contingent on one out-of-context synthesis run, with the MEASURED
`ROWS_IF = 32` named in advance as the fallback. The 39 ms token budget is not
what should decide this; Fmax and the HBM port count are, and neither appears
in the budget.**

### 6.1 Where the position is simply correct

**B: keep `LANES = 32`, unconditionally.** B's DSP is identical at both scales
and the emit chain has been MEASURED flat at 73 DSP across HEADS 8 to 32, which
brackets both 24 (27B per card) and 32 (9B per card). There is nothing to tune
and no risk in not tuning. `gdn-emit-chain-sizing.md:60-67` also records the one
real hazard here, and it argues the parent's way: `RMS_LANES = 2` looks better
on every static report and drops 24 columns because `gdn_recur_pipe` cannot be
back-pressured. **Throughput margin is a correctness property in B.** Cutting B
down for 9B would be actively dangerous.

**The clock argument is right, and better than stated.** Section 4 shows the
15.0% clock loss costs only 8.4% of A's time. And the binding path at 254.32 MHz
is inside **`rmsnorm_bf`**, in B's emit chain
(`gdn-emit-chain-sizing.md:99-109`: `u_rms/ARG__21/DSP_A_B_DATA_INST/CLK ->
u_rms/mr_m_reg[60]/D`, 84.9% logic). It has nothing to do with A's parallelism,
so **re-tuning A does not recover the clock**. The 9B token at `ROWS_IF = 58`
lands at 24.80 ms against 39 ms; the miss is absorbed with 14.2 ms to spare.

### 6.2 Where the position is not available

**C cannot keep `MACS = 192`.** There is no legal `QH_TILE` at `G = 4`. Even if
the array were built at 192 with two masked lanes, it would deliver exactly the
throughput of 128 for 128 more DSP. **C is re-tuned by arithmetic, not by
choice**, and the 9B build will therefore sit at 85.8% of the die where the 27B
build sits at 90.3%.

That partially defeats the "validate what you ship" argument on its own terms:
**the highest-value thing a 9B build could de-risk is whole-die routability at
~91% DSP**, which `docs/2026-08-27_direction-review-fable.md:210-213` names as
the top unmeasured risk and which C skeleton `:508-511` independently flags
("high utilisation on this device is historically non-deterministic"). A 9B
build at 85.8% does not test that, and it is 128 DSP short in exactly the
subsystem (C's dense lane array) whose congestion behaviour is least understood.

**If the parent wants the routing risk retired, that has to be said out loud and
paid for**, by synthesising a deliberate 128-DSP ballast block or by accepting
that the 27B route remains untested after 9B works. What is not available is
getting it for free by "keeping the parallelism".

### 6.3 Where I disagree, plainly

**`ROWS_IF = 58` in the post-reclaim form the 1,914 figure prices has never been
synthesised.** Every A build on disk, with what it actually is:

| source | `ROWS_IF` | part | form | max Fmax at the top row |
|---|---|---|---|---|
| `sim/ooc_sweep/results_reclaim_085.csv` | 8, 16, 24, **32** | `-2L-e` | **post-reclaim, 0.85 V** | 345.7 MHz at 32 |
| `sim/ooc_sweep/results.csv` | 8, 16, 24, **32** | `-2L-e` | post-reclaim, **0.72 V** | 275.3 MHz at 32 |
| `sim/ooc_sweep/results_baseline.csv` | 8, 16, 24, 32 | `-2L-e` | pre-reclaim | 317.7 MHz at 32 |
| `sim/ooc_sweep_2L/sweep.log` | 32, **48, 56** | `-2L-e` | pre-reclaim | 287.9 MHz at 56, **misses 300** |
| `sim/ooc_sweep_2e/sweep.log` | 4, 8, 16, 32, 48, 56 | `-2L-e` | pre-reclaim | same 48 and 56 rows |
| `sim/ooc_sweep_2e/hybrid.log` | **64, 80, 88** | **`-2-e`** | `-max_dsp 2880` capped | 257.1 MHz at 64 |
| `sim/ooc_sweep_prepipe/sweep.log` | 4, 8, 16, 24, 32 | `-2L-e` | pre-pipelining, 13,455 DSP at 32 | 179.6 MHz, superseded |

Nothing in that table is the configuration the die budget books. `1,914 DSP` is
`33.00 x 58` extrapolated **1.8x past the largest post-reclaim point**, and its
Fmax is not extrapolated at all -- it is unknown. The nearest evidence is the
pre-reclaim `-2L-e` sweep, which says A stops meeting 300 MHz somewhere between
32 (317.7 MHz, met) and 48 (276.1 MHz, missed), with 56 recovering only to
287.9. The reclaim added ~11.5K LUT at `ROWS_IF = 32` (72,965 against 61,413) to
remove 440 DSP, and **whether that trade still closes timing at 58 rows is
exactly the question nobody has asked.** Note also that the one build above 56,
`ROWS_IF = 64` DSP-capped at 2,880, reached only 257.1 MHz and needed
153,181 LUT, on the **faster** `-2-e` speed grade.

Against that, the post-reclaim measured points are strong:

| `ROWS_IF` | DSP | Fmax @0.85 V | Fmax @0.72 V |
|---|---|---|---|
| 8 | 264 | 320.0 | 244.0 |
| 16 | 528 | 318.3 | 242.0 |
| 24 | 792 | 320.4 | 244.8 |
| **32** | **1,056** | **345.7** | **275.3** |

`ROWS_IF = 32` is the largest A ever built, it closes 345.7 MHz at 0.85 V and
**275.3 MHz at the card's real 0.717 V**, and section 2.3 shows it is
simultaneously the smallest A that meets the 39 ms budget at 9B and the achieved
clock (38.38 ms). That coincidence is worth naming because it is not a
coincidence: both quantities are pinned by the same HBM supply.

> **BOTH HALVES SUPERSEDED 2026-08-27; the coincidence is gone.** At the
> MEASURED **237.8 MHz** `ROWS_IF = 32` is **41.05 ms** and does not meet
> 39 ms, so it is not the smallest A that does. And it is no longer the largest
> ever built: `sim/ooc_sweep/results.csv:7` now carries **`ROWS_IF = 58`
> post-reclaim at 1,914 DSP and 237.8 MHz at 0.717 V**, exactly the DSP figure
> that had been extrapolated. Note also that the 275.3 MHz quoted here is
> withdrawn upstream (`docs/debugging/2026-08-27_clock-at-the-real-voltage.md:83-85`);
> it compares a 3.333 ns / 0.72 V run against a 3.3 ns / 0.717 V run, so the
> constraint period changed as well as the voltage.

**And the port budget does not close at 58 either, at either clock.** Section 4
shows `ROWS_IF = 58` wants 36 HBM ports of 30 available at 254.32 MHz with the
spec's 1.3x provisioning, or 28 of 30 with none, leaving 2 for B's four and C's
two. `ROWS_IF = 32` wants 21, leaving 9. This is inherited from 27B rather than
introduced by 9B (D skeleton `:419-422` already concludes "D section 8.1's static
port assignment does not survive"), but it is the second independent constraint
that the re-tuned column satisfies and the kept-parallelism column does not. The
first is Fmax. Neither shows up in the token budget, which is why the 24.80 ms
figure alone is not sufficient grounds to keep 58.

**So the concrete recommendation:**

1. ~~**Synthesise `ROWS_IF = 58` out of context before anything else.**~~
   **DISCHARGED 2026-08-27.** It has been run: `sim/ooc_sweep/results.csv:7`
   gives 1,914 DSP -- exactly `33.00 x 58`, as extrapolated -- 134,675 LUT, and
   **237.8 MHz at 0.717 V** (`:9` is the same netlist at 0.85 V, 284.90 MHz).
   It remains out-of-context synthesis: it has not been placed or routed.
   *Original text:* it is one OOC run on an existing sweep script, it costs
   nothing but wall clock, and it is the only thing standing between 1,914 DSP
   and a figure extrapolated 1.8x past every measurement.
2. **If it closes, build the 9B bring-up at `ROWS_IF = 58`, `LANES = 32`,
   `MACS = 128`.** 2,472 DSP, 85.8%, 24.80 ms per token at the achieved clock.
   This is the parent's position and it is then the right default, because it
   exercises A's real geometry and its cascade columns, which is what the 27B
   build needs proven. Note it still leaves the port budget unsolved (2 spare
   ports of 30), inherited from 27B.
3. **If it does not close, drop to `ROWS_IF = 32` without further analysis.**
   It is measured at 345.7 MHz at 0.85 V and 275.3 MHz at 0.717 V, it meets the
   39 ms budget at the achieved clock (38.38 ms), it takes the die to 56.0%, and
   it takes A's port demand to 21 of 30. Write it into the config now as the
   named fallback so a failure at 58 is a switch, not a re-planning exercise.
   Accept, explicitly, that this build then proves nothing about 27B routing.

   > **AMENDED 2026-08-27: the fallback no longer meets the budget it was
   > chosen for.** At the MEASURED **237.8 MHz**, `ROWS_IF = 32` is
   > **41.05 ms**, not 38.38, so "it meets the 39 ms budget" is no longer true.
   > Since 39 ms is an inherited assumption rather than a requirement
   > (`docs/2026-08-27_budgets-at-the-measured-clock.md` section 3), this is a
   > re-labelling rather than a failure -- but **"without further analysis" is
   > withdrawn**: the fallback now needs a stated reason of its own. The
   > smallest `ROWS_IF` that does meet 39 ms at 237.8 MHz is disputed between
   > 34 and 36; see the note in section 2.3.
4. **Do not spend the 128 DSP that C frees.** Raising `ROWS_IF` to 62 to consume
   them buys 1.0 ms of a 14.2 ms surplus and puts A back within 1.5% of the HBM
   supply ceiling. The freed DSP is better left as routing headroom on a die
   whose congestion behaviour at this utilisation is unmeasured.
5. **Book the 9B budget at 8,192 context, not 262,144.** Capacity allows
   202,621; the 39 ms budget allows between 4,096 and 8,192; and the C spec's
   own widths are only dimensioned for 2,048.

---

## 7. What I could not determine

Required section. Each item is open, not resolved by rounding.

1. **Whether the 9B shapes are correct.** They are taken from
   `rtl/model_cfg_pkg.vhd:64-71`, which cites `huggingface.co/Qwen/Qwen3.5-9B`
   `config.json`. **There is no 9B GGUF on this box and no network access**, so
   unlike the 27B row (which this document re-derived to 14.0896 GiB and matched
   against the recon's independently obtained 14.09 GiB) the 9B row could not be
   checked against anything. Every number in this document scales off it. The
   27B validation shows the *method* is right; it says nothing about the 9B
   *inputs*.

2. **Whether the 9B `attn_q` carries the fused gate** (the `x 2` on
   `16 x 256`). Assumed by architectural analogy with 27B's
   `attn_q.weight [5120, 12288]`. Sensitivity: 1.69% of A's cycles and 0.076 GB
   of weights.

3. **Whether the vocab is really 248,320.** D skeleton `:190-192` flags it at
   27B ("roughly 1.6x the 151,936 of the shipped Qwen3 tokenizer and is **not
   verified here**"). It is asserted identically for 9B. Sensitivity at 9B:
   **4.95% of A's cycles**, because lm_head is 12.8% of A at N=1 where it is not
   sharded at all. This is the single largest unverified input to A.

4. **Whether the embedding is tied to the lm_head.** Costs 0.572 GB of HBM and
   32,866 positions of context. Nothing in the repo states it.

5. **Whether the card is 8 GiB or 8 GB.** `fpga-hardware-recon.md:38` and `:176`
   disagree. Worth 33,889 positions of context.

6. **A's Fmax and DSP at any `ROWS_IF` above 32 post-reclaim, on `-2L-e`.**
   Section 6.3 tabulates every A build on disk; none is that configuration. This
   is the highest-value single measurement available and it is one OOC run on an
   existing script. Related and also open: whether the `33.00 DSP/row` slope
   itself survives past 32, since the pre-reclaim slope drifted from 48.0 at
   `ROWS_IF = 4` to 45.8 at 48 (A spec `:1665-1672`).

7. **C's Fmax at any `MACS` above 64.** C skeleton `:566-569` says it outright:
   "No Fmax measurement exists at 192 lanes -- the routed 339.6 MHz is at 64".
   At 9B the relevant point is `MACS = 128`, which is also unmeasured. The
   post-route data in `sim/ooc_micro/pnr_results.csv` reaches
   `micro_c_array_p_LANES64` at 339.6 MHz and stops.

8. **B's emit-chain cycle cost as a function of HEADS.** DSP, LUT and Fmax were
   swept across HEADS 8/16/24/32 and are flat; the **cycle** count was measured
   only at 24. The 552,096-cycle figure for 9B is `17,253 / 24 x 32 x 24`, a
   linear extrapolation with an assumed zero intercept. B is emit-bound in both
   configurations, so this term sets B's whole row.

9. **B's true DSP row: 226, 227, or 251.** Section 3.3. Every die total in this
   document is 24 DSP optimistic if 251 is right, and it probably is.

10. **The 0.717 V derate.** Bounded at <= 15.8% by a passing test
    (`2026-08-25_voltage-derate-on-hardware.md:29`), never measured
    (`:207`). The 214.1 MHz row in section 2.3 is a worst-known bound. Note the
    A sweep itself measured 345.7 to 275.3 MHz at `ROWS_IF = 32`, a **-20.4%**
    derate, which is outside the bound the other document establishes -- these
    two are measuring different things (a synthesis-model voltage corner against
    a hardware pass/fail) and this document cannot reconcile them.

11. **Whether the 39 ms budget should apply to 9B at all.** It is a 27B N=2
    figure, derived and unmeasured, and the direction review says the ladder it
    belongs to is misleading by 2-3x. A 9B target could reasonably be much
    tighter. Section 2.1.

12. **Everything downstream of the ~91% DSP routability question.** No whole-die
    build exists at any scale. This document computes DSP totals; it does not
    and cannot say whether they place and route.

13. **HBM read latency on this card**, which D skeleton `:445` records as never
    measured and which sets the port re-grant cost. At 9B with `ROWS_IF = 32`
    the port pressure is much lower (21 of 30, section 4), so the question is
    less acute, but it is not answered.

---

## 8. Corrections this document proposes to other files

Listed for the owners of those files, not applied here.

| file | line | says | should say |
|---|---|---|---|
| `docs/superpowers/specs/2026-08-27-D-sequencer-skeleton.md` | 269, 290 | "7.559 GB weight read" per token | 7.2605 GB (its own tables imply it); 7.559 GB is the recon's stored shard including the embedding table |
| same | 382-383 | "5 x 46.5 = 233 DSP" between `ROWS_IF` 53 and 58 | 5 x 33.00 = 165, since the same sentence books A post-reclaim at 1,914 |
| `docs/superpowers/specs/2026-08-21-gated-deltanet-design.md` | 1820 | nonlinear + conv = 342,144 | 329,808; the row still uses the conv figure struck through at `:1819` |
| `docs/superpowers/specs/2026-08-27-C-gated-attention-skeleton.md` | 340, 460 | ladder is 32/64/96/192; 96 is "the only fallback" | true at `G = 6` only; state the dependence on the group so the 9B retarget does not inherit it |
| `rtl/model_cfg_pkg.vhd` | 82 | "about 4.5 GB against 8 GB HBM" | 5.04 GB (4.69 GiB) at 4.5 bpw; and 8 GiB, per `recon:38` |
| `docs/debugging/2026-08-25_whole-die-budget-reconciliation.md` | 46 | A at 1,914 "MEASURED" | measured slope, extrapolated 1.8x past the largest synthesised point |
| `docs/fpga-hardware-recon.md` | 70, 176 | 460 GB/s; "8 GB HBM2" | 288.0 GB/s measured; and 8 GiB per its own `:38` |
