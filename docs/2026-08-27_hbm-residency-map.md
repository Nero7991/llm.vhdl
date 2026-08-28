# The HBM residency map: where every tensor lives in the FK33's 8 GB

**Date:** 2026-08-27. Branch `fpga`, at `adc6fe1`.
**Part:** `xcvu33p-fsvh2104-2L-e`, SQRL FK33, 8 GiB HBM2, VCCINT 0.717 V MEASURED.
**Model:** Qwen3.5-9B, N=1 (`rtl/model_cfg_pkg.vhd:64-70`). 27B N=4 checked where it differs.
**Answers:** item **N3** of `docs/2026-08-27_weight-path-audit.md` section 10.

**Labelling.** Every quantity is MEASURED (a tool was run and its output file is
named), DERIVED (arithmetic shown here from MEASURED or normative inputs), or
ESTIMATE (a judgement with its assumption stated). **No Vivado was run for this
document.** Two place-and-route jobs were already queued on this machine and a
third would have contended for memory, so every resource and timing figure below
is DERIVED or ESTIMATE and says which.

---

## 0. The answer, up front

**There is only ONE HBM address map, not two, and it already exists.** The
`pcieep` build and the `hbmbw` build assign pseudo-channel `n` to
`n x 256 MiB` from the view of **every** SAXI port. The audit's section 3
worry that "the flat host view and the port-local engine view have to be
reconciled" does not survive inspection: they are the same map. What is
port-local in `hbmbw` is the **generator's choice of addresses**, not the
address space. See section 6 and
`docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`.

**The one real placement constraint is the STACK, not the channel.** The HBM
switch is per stack with no cross-stack path, so a port on `SAXI_01..15` can
only reach `0x0_0000_0000 .. 0x0_FFFF_FFFF` and a port on `SAXI_17..31` only
`0x1_0000_0000 .. 0x1_FFFF_FFFF`. Every tensor is therefore physically split
across both halves of HBM. Putting a lane's bytes in the wrong half is a
**silent wrong answer**, not a bus error, because the address decodes.

**Residency headline, 9B at `ROWS_IF = 48`, DERIVED:**

| region | bytes | of 8 GiB |
|---|---|---|
| 27 weight-lane arenas, 160 MiB each | 4,320 MiB = 4.530 GB | 52.7% |
| embedding table (looked up, not streamed) | 545.6 MiB = 0.572 GB | 6.7% |
| GDN recurrent state + conv history, 26.4 MiB rounded up | 32 MiB = 0.034 GB | 0.4% |
| **free for KV cache** | **3,294 MiB = 3.454 GB** | **40.2%** |
| **maximum context that fits** | **198,415 tokens** | 75.7% of the 262,144 nominal |

**What the 262,144 shortfall costs, and whether it is acceptable: it costs
nothing that is reachable.** At the 198,415-token capacity ceiling subsystem C's
attention sweep alone is **~400 ms per token** (DERIVED by scaling
`docs/2026-08-27_9b-single-card-resource-envelope.md:722`'s 408.60 ms at 202,621
tokens), against a whole-token budget of 26.5 ms at 2,048 tokens. **Context is
compute-capped at between 4,096 and 8,192 tokens, which is 4% of where it is
capacity-capped.** Losing 24% of nominal capacity therefore costs zero reachable
context. It is acceptable, and it would still be acceptable at half the capacity.

**What the host must know before the first DMA byte** is six things, and five of
them are constants rather than data: the lane geometry, the arena base table,
the arena size, the stack rule, the region bases for KV/embedding/state, and one
per-tensor manifest record. Section 5.

---

## 1. What the hardware fixes, and what is free

### 1.1 Fixed by the HBM IP, not negotiable

| Property | Value | Evidence |
|---|---|---|
| Pseudo-channels | 32, 256 MiB each | `hw/fk33/build_fk33_pcieep.tcl:547-578` |
| Address of pseudo-channel `n` | `n x 256 MiB`, **from every port** | `hw/fk33/build_fk33_hbmbw.tcl:483-738` assigns `MEM00..15` at `0x0..0xF000_0000` identically on `SAXI_01`, `SAXI_02`, ... and `MEM16..31` at `0x1_0000_0000..` identically on `SAXI_17..31` |
| The IP refuses any other offset | yes | `rtl/hbm_tg.vhd:97-101`: "the HBM IP FIXES pseudo-channel n at n x 256 MB and refuses any other offset" |
| SAXI data width | 256 bits | `rtl/hbm_tg.vhd:92` |
| Cross-stack path | **none** | `hw/fk33/gen_hbmbw.py:340-343` via the audit, section 1 hop 5 |
| `HBMGlobalSwitch` | 1, so a port reaches any channel **within its stack** | `build_fk33_pcieep.tcl:87` |
| Ports spoken for by the host | `SAXI_00` (stack 0) and `SAXI_16` (stack 1) | `build_fk33_pcieep.tcl:196-197` |
| Ports available to the engine | **30**: `SAXI_01..15`, `SAXI_17..31` | MEASURED buildable, `build_fk33_hbmbw.tcl:443-472` |
| Per-port read rate at 300 MHz ACLK | **9.60 GB/s, flat from 1 to 30 ports** | MEASURED, `hw/fk33/results/hbmbw_30port_300mhz.txt:349` |
| Aggregate at 30 ports | **288.0 GB/s, 100.0% of ceiling, 0 non-OKAY beats** | MEASURED, same file |
| Burst length used to achieve it | **16 beats = 512 B** (`ARLEN 15`) | MEASURED, same file line 119 |

The last row matters more than it looks. 512-byte bursts reached 100% of the
arithmetic ceiling, so **nothing in this design ever needs a burst long enough
to approach AXI4's 4 KB boundary rule.** The DDR4 configuration's `MAXB = 256`
beats would be 8 KB at `AXI_DW = 256` and would be illegal; 16 beats is both
legal and measured-sufficient.

### 1.2 Free to choose

- Which pseudo-channel each engine port addresses.
- Where inside a channel each region starts.
- Whether A's ports stay inside one channel each (port-local) or cross channels.
- `ROWS_IF`, which sets the lane count and therefore the port count.

---

## 2. The unit of residency is a LANE ARENA, not a tensor

Subsystem A consumes, per core cycle, one word of

```
ROWS_IF x BLK x 4  bits of weight  +  ROWS_IF x 16  bits of scale
= ROWS_IF x 144 bits            (BLK = 32)
```

`docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md` section 6.5
splits that word into lanes of `AXI_DW` bits, one lane per sub-region, one
sub-region read sequentially per port. At `AXI_DW = 256`:

```
NLANE_W = ROWS_IF x 128 / 256 = ROWS_IF / 2      lanes of weight
NLANE_S = ceil(ROWS_IF x 16 / 256)               lanes of scale
NLANE   = NLANE_W + NLANE_S
```

Both are integral with no scale padding **iff `ROWS_IF` is a multiple of 16**.
DERIVED table, with the DSP curve `DSP = 33 x ROWS_IF` MEASURED post-reclaim
(`sim/ooc_sweep/results.csv`, exact at `ROWS_IF` 8/16/32/40/48/58):

| `ROWS_IF` | `NLANE_W` | `NLANE_S` | `NLANE` | scale pad | DSP | of 2,880 | ports left of 30 |
|---|---|---|---|---|---|---|---|
| 16 | 8 | 1 | 9 | 0 | 528 | 18.3% | 21 |
| 32 | 16 | 2 | 18 | 0 | 1,056 | 36.7% | 12 |
| **48** | **24** | **3** | **27** | **0** | **1,584** | **55.0%** | **3** |
| 52 | 26 | 4 | 30 | 192 b, 18.8% | 1,716 | 59.6% | 0 |
| 58 | 29 | 4 | **33** | 96 b, 9.4% | 1,914 | 66.5% | **-3, impossible** |
| 64 | 32 | 4 | 36 | 0 | 2,112 | 73.3% | -6, impossible |

**`ROWS_IF = 48` is the residency map's operating point, and `ROWS_IF = 58` is
not implementable with one lane per port.** The full argument, including why the
port count is a *width* budget rather than a *bandwidth* budget, is
`docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md`. This document
takes 48 as given and lays out where the bytes go.

**A lane arena is one lane's bytes for the WHOLE model, concatenated.** Because
every lane of every tensor is the same size (a 256-bit slice of the same word,
for the same number of words), lane `L`'s sub-region for tensor `T` sits at the
**same offset inside arena `L` for every `L`**. That single fact collapses the
per-tensor descriptor from `NPORTS_W` 64-bit bases (spec 6.4's `w_sub_offset[]`)
to **one** offset plus a compile-time arena table.

---

## 3. The map

### 3.1 Lane to port to pseudo-channel

27 lanes, split 14 on stack 0 and 13 on stack 1. DERIVED assignment:

| lane `L` | SAXI port | pseudo-channel | arena base |
|---|---|---|---|
| 0 .. 13 | `SAXI_01` .. `SAXI_14` | `MEM00` .. `MEM13` | `L x 256 MiB` |
| 14 .. 26 | `SAXI_17` .. `SAXI_29` | `MEM16` .. `MEM28` | `(L + 2) x 256 MiB` |

so `ARENA_BASE(L) = CH(L) x 0x1000_0000` with

```
CH(L) = L        for L in 0..13     (stack 0, addresses 0x0_0000_0000 .. )
CH(L) = L + 2    for L in 14..26    (stack 1, addresses 0x1_0000_0000 .. )
```

Left over for the rest of the die: **engine ports** `SAXI_15` (stack 0),
`SAXI_30`, `SAXI_31` (stack 1); **pseudo-channels** `MEM14`, `MEM15`, `MEM29`,
`MEM30`, `MEM31`, plus the tail of every arena channel.

The 14/13 split is a free choice and should be revisited once B's and C's port
needs are pinned: B wants 4 masters and C wants 2 reads plus 1 write, and only 3
engine ports remain. That is a real conflict and it is stated as such in section
7, not hidden here.

### 3.2 Region table, 9B N=1, `ROWS_IF = 48`

DERIVED. Arena size is computed in section 4 as 158.3 MiB and rounded up to
**160 MiB** so the KV window offset is one constant rather than a table.

| region | address | size | reached by |
|---|---|---|---|
| lane arena `L`, `L` in 0..13 | `CH(L) x 256 MiB + 0` | 160 MiB | `SAXI_(L+1)`, port-local |
| KV stripe in `CH(L)`, `L` in 0..13 | `CH(L) x 256 MiB + 160 MiB` | 96 MiB | `SAXI_15` via the stack-0 switch |
| GDN state + conv history | `MEM14` base = `0xE000_0000` | 26.4 MiB, 32 MiB reserved | `SAXI_15` |
| KV stripe in `MEM14` | `0xE000_0000 + 32 MiB` | 224 MiB | `SAXI_15` |
| KV stripe in `MEM15` | `0xF000_0000` | 256 MiB | `SAXI_15` |
| lane arena `L`, `L` in 14..26 | `CH(L) x 256 MiB + 0` | 160 MiB | `SAXI_(L+3)`, port-local |
| KV stripe in `CH(L)`, `L` in 14..26 | `CH(L) x 256 MiB + 160 MiB` | 96 MiB | `SAXI_30/31` via the stack-1 switch |
| embedding table | `MEM29` base = `0x1_D000_0000` | 545.6 MiB, spans `MEM29..MEM31` | `SAXI_30`, or the host port |
| KV stripe above the embedding | `0x1_D000_0000 + 546 MiB` | 222 MiB | `SAXI_31` |
| DMA scratch BRAM | `0x2_0000_0000` | 64 KiB | host only, not HBM |

Capacity check, DERIVED:

```
27 arenas x 160 MiB                    = 4,320 MiB
embedding                                  546 MiB
GDN state 25.17 MB + conv 1.18 MB, rounded  32 MiB
--------------------------------------------------
committed                              = 4,898 MiB
HBM                                    = 8,192 MiB
free for KV                            = 3,294 MiB = 3.454 GB

and it checks against the region table above, stripe by stripe:
  27 arena tails x 96 MiB              = 2,592 MiB
  MEM14 above the GDN state            =   224 MiB
  MEM15, whole                         =   256 MiB
  MEM29..31 above the embedding        =   222 MiB
                                         ---------
                                         3,294 MiB

KV bytes per position (C's BFP record, 272 B per 256-element head vector,
  8 attention layers x 4 KV heads x 2 for K and V)
                                       = 17,408 B
max context = 3,294 x 2^20 / 17,408    = 198,415 tokens
```

Cross-check against two independent derivations of the same quantity:
`docs/2026-08-27_weight-path-audit.md:582` gives 199,793 and
`docs/2026-08-27_9b-single-card-resource-envelope.md:661` gives 202,621. This
document is 0.5% below the first and 1.9% below the second; the difference is
the 1.7 MiB per arena lost to rounding 158.3 up to 160, plus this document
counting the embedding at its real 545.6 MiB. **The residency map costs about
1.9% of the capacity ceiling relative to an idealised flat placement.**

### 3.3 The same map at 27B N=4

DERIVED, for the end goal. Per-card streamed weights at N=4 are
`25.624e9 / 4 x 0.5625 B = 3.604 GB`, so at 27 lanes the arena is
`3.604e9 / 27 = 133.5 MB = 127.3 MiB`, comfortably inside 256 MiB. The map
transfers unchanged with a smaller `ARENA_SIZE`.

**It does NOT transfer at 27B N=2.** There the per-card streamed set is
7.2067 GB (`9b-single-card-resource-envelope.md:211`), so an arena is
`7.2067e9 / 27 = 266.9 MB = 254.6 MiB`, which is inside 256 MiB by 0.5% before
alignment padding and outside it after. **N=2 breaks the one-arena-per-channel
invariant and must either raise `NLANE` or accept cross-channel reads.** Stated
here so it is not discovered during an N=2 bring-up.

---

## 4. Arena size, from the tensor list

DERIVED. `ARENA_SIZE = sum over tensors of ceil(tiles x NB x 32 B / 4 KiB) x 4 KiB`
with `tiles = ceil(M / ROWS_IF)` and `NB = ceil(K / BLK)`.

The 9B tensor list is reconstructed from
`docs/2026-08-27_9b-single-card-resource-envelope.md:180-197` and checked against
its own totals. 273 matvec tensors:

| per block | tensors | shapes (M x K) |
|---|---|---|
| GDN block, 24 of them | 9 | `2048x4096` q, `2048x4096` k, `4096x4096` v, `4096x4096` z, `4096x4096` o, `72x4096` b/a, `12288x4096` gate, `12288x4096` up, `4096x12288` down |
| attention block, 8 of them | 7 | `8192x4096` q (fused gate), `1024x4096` k, `1024x4096` v, `4096x4096` o, and the same three FFN tensors |
| lm_head | 1 | `248320x4096` |

Sum of `M x K` over the 273 = **7,936,409,600**, which reproduces the envelope's
"streamed per token (whole model)" figure exactly, so the reconstruction is
right. The `72x4096` b/a tensor is inferred from the 294,912-weight residual in
the envelope's per-GDN-block total and is the one shape not independently
confirmed; it is 0.004% of the model and cannot move any conclusion.

Result at `ROWS_IF = 48`, `BLK = 32`, `AXI_DW = 256`, 4 KiB sub-region alignment:

```
core words (= beats per lane, whole model)   = 5,187,328
arena size = 5,187,328 x 32 B, per-tensor 4 KiB aligned
                                             = 165,994,496 B = 158.3 MiB
packed streamed total = 27 x 158.3 MiB       = 4.4819 GB
ideal at 4.5 bits/weight                     = 4.4642 GB
overhead (tile padding + block padding + 4 KiB alignment)
                                             = +0.39%
```

The overhead is dominated by tile padding on the small tensors, not by
alignment: 273 tensors x 4 KiB of alignment slack is at most 1.1 MiB per lane,
0.7% of an arena, and averages half that.

**Sensitivity to `ROWS_IF`,** DERIVED, same method:

| `ROWS_IF` | core words | arena | packed | overhead |
|---|---|---|---|---|
| 32 | 7,752,704 | 236.6 MiB | 4.4656 GB | +0.03% |
| **48** | **5,187,328** | **158.3 MiB** | **4.4819 GB** | **+0.39%** |
| 52 | 4,787,200 | 146.1 MiB | 4.5957 GB | +2.95% |
| 58 | 4,293,888 | 131.0 MiB | 4.5343 GB | +1.57% |
| 64 | 3,877,888 | 118.3 MiB | 4.4673 GB | +0.07% |

`ROWS_IF = 32` is the only entry that comes close to the 256 MiB channel bound,
at 92.4% of it, and it would break at 27B N=2 by a wide margin. 52 and 58 carry
their scale padding (18.8% and 9.4% of the scale lanes) as visible file
overhead, which is another reason not to pick them.

---

## 5. What the host has to know before it can DMA the first byte

Six items. **Five are constants and only one is data.**

1. **Geometry.** `ROWS_IF = 48`, `BLK = 32`, `AXI_DW = 256`, hence
   `NLANE_W = 24`, `NLANE_S = 3`, `NLANE = 27`. The packer must be told all
   four rather than deriving `nports = rows_if`, which is
   `tools/pack_int4.py:203`'s hard-wired AXU3EG identity and would silently emit
   a 48-sub-region file that no FK33 design can read (audit finding F2).
2. **The arena base table** `CH(L)`, 27 entries, section 3.1. It is a build-time
   constant of the bitstream and must be reported by the ID register block so
   the host cannot pair a new image with an old bitstream.
3. **`ARENA_SIZE = 160 MiB`**, and the assertion `arena_bytes <= ARENA_SIZE`
   evaluated by the image builder, refusing to write if it fails.
4. **The stack rule.** `CH(L) < 16` means arena `L` must be written to
   `0x0_0000_0000 .. 0x0_FFFF_FFFF`; `CH(L) >= 16` means
   `0x1_0000_0000 .. 0x1_FFFF_FFFF`. A violation decodes and reads back
   correctly over the host port, and is only wrong when subsystem A's port tries
   to fetch it, at which point A reads whatever is at that address in its own
   stack. **This is the silent-wrong-answer of this design and it needs an
   explicit host-side assertion, not a comment.**
5. **Region bases** for KV, embedding and GDN state, section 3.2.
6. **The manifest**, one record per tensor, which is the only per-tensor data:

```
tensor_id      u32     index into the descriptor table
M, K           u32,u32 rows, true columns
w_exp          i32     signed
out_shift      i32
w_off          u64     byte offset inside EVERY arena; the same for all 27 lanes
n_beats        u32     = tiles x NB, beats per lane
codebook       16 x i8
```

`w_off` replaces spec 6.4's `w_sub_offset[0 .. NPORTS_W-1]` array and
`s_sub_offset[]`. The lane bases are `ARENA_BASE(L) + w_off` for the 24 weight
lanes and `ARENA_BASE(L) + w_off` for the 3 scale lanes as well, because scale
lanes are lanes: they carry the same beat count at the same offset. **The
`nsub_w + nsub_s` base array that `rtl/seq_desc_fetch.vhd:111-113` deliberately
does not fetch therefore does not need to exist.** That is a direct simplification
of N10.

**Address for lane `L`, tensor `T`:**

```
addr(L, T) = CH(L) x 0x1000_0000 + w_off(T)
n_beats(T) = tiles(T) x NB(T)          -- identical for all L
```

Two adds and a constant lookup. No per-lane arithmetic, no per-tensor table
walk, no 27-entry base array in the descriptor.

---

## 6. Port-local or through the switch: two maps, and why one is recommended

**Map A, port-local (recommended).** Arena `L` is pinned to the base of channel
`CH(L)` and never leaves it, because 158.3 MiB < 256 MiB. Port `L` therefore
issues only addresses whose top bits are its own channel index, which is
**exactly the access pattern that measured 288.0 GB/s at 100.0% of the
arithmetic ceiling** (`hw/fk33/results/hbmbw_30port_300mhz.txt`, and
`rtl/hbm_tg.vhd:20-25` states that this was measured because it is the pattern A
will use). Cost: KV is fragmented into per-channel tails.

**Map B, contiguous.** Arenas packed flat from address 0 at a 160 MiB stride, so
arena `L` spans channels `floor(L x 160 / 256)` upward and crosses boundaries
inside a job. KV becomes one contiguous region above 4,320 MiB, which is simpler
for C and for the host. Cost: A's reads traverse the stack switch, and **the
100% efficiency figure was not measured for this pattern.**

Map B is not obviously bad. The one adjacent measurement is the oversubscription
sweep, where all 30 ports were pointed at a single pseudo-channel and delivered
**9.60 GB/s in total, flat** -- the single-channel port ceiling, not a switch
collapse (`hbmbw_30port_300mhz.txt:358`). Under Map B each channel would host on
average `256/160 = 1.6` arenas, so `1.6 x 7.55 GB/s = 12.1 GB/s` of demand per
channel at `f_core = 236 MHz`, against 14.4 GB/s of DRAM supply: it fits, with
16% margin and with correlated hot spots wherever two lanes happen to be reading
the same channel at the same instant, which under lockstep lane consumption is
**always**, not sometimes.

**Recommendation: Map A**, because it is the measured pattern and because Map B's
margin depends on a hot-spot analysis that a lockstep consumer makes worst-case
by construction. Map B should not be adopted without running the measurement in
section 8 item 3, which the existing `hbmbw` bitstream can already do: `hbm_tg`
exposes `rgn_base` and `rgn_stride` as runtime registers
(`rtl/hbm_tg.vhd:313-317`), so a stride of 0 or a fractional overlap is a Tcl
change, not a rebuild.

**A correction to the audit falls out of this.** The audit's section 3 says
"a second address map exists and is different" and calls reconciling them "a
silent-wrong-answer class of bug". Inspecting `build_fk33_hbmbw.tcl:483-738`,
every `SAXI_nn` in the bandwidth build is assigned **all sixteen** of its stack's
segments at the same flat offsets the `pcieep` build uses. There is one address
map. The silent-wrong-answer risk is real but it is the **stack** rule of
section 5 item 4, not an address-encoding mismatch.

---

## 7. What this map does NOT solve

Recorded as problems rather than as results.

- **B and C get 3 engine ports between them, and they want 7.** B needs 4
  masters and C assumes 2 concurrent reads and 1 write (A spec section 13
  correction block; `rtl/hbm_tg.vhd:29-33`). A at `ROWS_IF = 48` takes 27 of the
  30. The only reason this is survivable is that **A, B and C are never
  simultaneously active** (D O13, quoted at
  `docs/superpowers/specs/2026-08-27-D-sequencer-skeleton.md:388`), so the
  remaining 3 ports carry B's and C's traffic serially at full rate. DERIVED
  check at `ctx = 2048`: C reads 0.036 GB of KV per token, which at
  `3 x 9.6 = 28.8 GB/s` is 1.25 ms against C's own 4.79 ms of compute. At
  `ctx = 32,768` it is 0.570 GB = 19.8 ms against 66.6 ms of compute. It fits at
  both, with the KV read fully hidden. **It does not fit if A, B or C ever
  overlap**, and nothing in this map prevents that; D's schedule does.
- **The 14/13 stack split of A's lanes is arbitrary.** It should be chosen to put
  B's and C's spare ports on the stacks their data lives in, which is a decision
  that belongs to B and C, not here.
- **KV striping is not designed.** Map A fragments KV into 27 tails of 96 MiB,
  one region of 224 MiB, one of 256 MiB and one of 222 MiB. C's addressing must
  stripe across those, which is natural for a per-(layer, head) map but is a real
  piece of design that this document does not do.
- **The embedding lookup path has no owner.** 545.6 MiB, read one row per token
  (2,304 B), so bandwidth is irrelevant; but nothing in the repo says which
  subsystem issues that read. It is parked in `MEM29..31` here on the assumption
  it is D's or E's.

---

## 8. What must be MEASURED before this map can be committed to

In descending order of how much of the map they would move.

1. **HBM read latency and its jitter under 27 concurrent port-local readers.**
   `hbm_tg` measured throughput and `arstall`, not latency
   (`rtl/hbm_tg.vhd:76-84`). Latency sizes the lane FIFOs and therefore the
   BRAM/URAM bill, and jitter across lanes sizes the drift margin. This is the
   single largest unknown in the streamer design and it is measurable with a
   small addition to the existing instrument.
2. **Whether the HBM SAXI ports close above 300 MHz with 27 real readers
   attached.** 300 MHz is MEASURED at 30 trivial generators with WNS +0.101 ns;
   350 MHz misses by 0.395 to 0.467 ns
   (`docs/debugging/2026-08-25_voltage-derate-on-hardware.md:244`). If ACLK ever
   reaches 2x the core clock the port count halves, which would make
   `ROWS_IF = 64` fit in 18 ports. That is the largest single prize on the table
   and it is currently ESTIMATE-only.
3. **Sustained bandwidth for cross-channel sequential reads (Map B).** Runnable
   today on the existing `hbmbw` bitstream via `rgn_stride`.
4. **The 9B tensor list, from a real GGUF.** No Qwen3.5-9B GGUF exists on this
   machine (audit section 5.1), so the 273-tensor list of section 4 is
   reconstructed and only its total is confirmed. The arena size inherits that.
5. **Whether the `72 x 4096` GDN b/a tensor is one tensor or several.** Affects
   the tensor count and hence 4 KiB alignment slack by at most 0.7% of an arena.

---

## 9. Corrections

None yet. Later findings that overturn anything above should be appended here
with a date, and the superseded claim marked withdrawn in place rather than
deleted.
