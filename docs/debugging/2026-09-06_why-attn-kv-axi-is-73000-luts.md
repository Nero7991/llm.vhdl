# Why `attn_kv_axi` is 73,050 LUT, and the 42,009 that are a tuning knob

**Date:** 2026-09-06
**Question:** `attn_kv_axi` measures **73,050 LUT-as-logic, 16.61% of the
device**, and it is 95% of what takes the engine from 90.3% to 98.89% CLB
occupancy. It contains no memory primitives at all. Where does it go?

## The answer, up front

**Into the prefetch buffer's slot multiplexer, and `RBUF` controls it.**

| RBUF | prefetch depth | LUT | FF | per-slot LUT | per-slot FF |
|---|---|---|---|---|---|
| 2 | 0 | 31,041 | 12,377 | -- | -- |
| 3 | 1 | 51,473 | 16,759 | +20,432 | +4,382 |
| **4 (current default)** | **2** | **73,050** | **21,147** | +21,577 | +4,388 |

**Each prefetch slot costs about 21,000 LUT.** Dropping `RBUF` from 4 to 2
saves **42,009 LUT, 9.6% of the whole device**, and `RBUF` is a pure
performance knob: `rtl/attn_kv_axi.vhd:537` asserts only `RBUF >= 2`, and its
message says *"Prefetch depth is RBUF-2 records beyond the current one."*

## The mechanism, read from the RTL rather than inferred

```vhdl
signal recbuf : ch_arr(0 to RBUF*CPR-1);          -- :646  a REGISTER array
signal sv     : std_logic_vector(RBUF-1 downto 0);-- :647  slot valid
type   sh_t is array (0 to RBUF-1) of unsigned(AW_H-1 downto 0);
signal hit_slot : integer range 0 to RBUF-1;      -- :667  associative lookup
```

The buffer is a **register file with an associative lookup**: `hit_slot` is
chosen by comparing the wanted record against every slot's tag, and the read
path then muxes the selected slot's data out combinationally.

The arithmetic says this is the mux and not the storage. A record at
`HEAD_DIM = 256`, `CM_W = 8` is about 2,048 bits, so ~21,000 LUT per slot is
roughly **10 LUT per stored bit**. Storage in fabric costs about 1 LUT per bit
at worst (LUTRAM), and this design reports **LUT as Memory = 0**, so none of it
is even LUTRAM. Ten LUT per bit is a wide multiplexer whose width grows with
the number of slots, which is exactly what an N-way associative buffer built in
logic produces.

## The full generic sensitivity

One variable at a time from the composed-shape baseline
(HEAD_DIM 256, KV_BLOCK 32, N_KVH 4, LAYERS 8, RBUF 4, MAXOUT 4):

| variant | LUT | delta | FF |
|---|---|---|---|
| baseline | 73,050 | -- | 21,147 |
| HEAD_DIM = 128 | 27,267 | **-45,783 (-62.7%)** | 11,836 |
| RBUF = 2 | 31,041 | **-42,009 (-57.5%)** | 12,377 |
| KV_BLOCK = 16 | 64,132 | -8,918 (-12.2%) | 21,086 |
| N_KVH = 2 | 72,421 | -629 (-0.9%) | 21,139 |
| MAXOUT = 2 | 75,820 | **+2,770 (BIGGER)** | 21,144 |

**`HEAD_DIM` is the largest lever and it is not available**: 256 is the model's
own `attn_head_dim` in `rtl/model_cfg_pkg.vhd`. It is listed because it
identifies the cost as scaling with the record WIDTH, which is what makes the
per-slot mux expensive, and because it is the control that makes the RBUF
result interpretable rather than isolated.

**`MAXOUT = 2` made the design BIGGER by 2,770 LUT.** Halving the bursts in
flight per read master does not halve anything; it costs. That is a measured
non-monotonicity and it is recorded so nobody "optimises" it downward. It also
matches this project's standing rule that a saving is not proportional to its
parameter -- here it is not even the right SIGN.

**`N_KVH` is nearly free at -0.9%**, which is the strongest evidence that the
cost is per-slot-width and not per-stream.

## What this is worth on the fit question

DERIVED, and flagged as such. Taking the placed engine at 342,163 LUT and
subtracting the OOC RBUF 4->2 saving:

| | LUT | + shell 50,999 | density needed device-wide |
|---|---|---|---|
| as built, RBUF = 4 | 342,163 | 393,162 | **7.15 LUT/CLB** |
| RBUF = 3 | ~320,600 | ~371,600 | ~6.76 |
| RBUF = 2 | ~300,150 | ~351,150 | **~6.39** |

against an architectural maximum of 8, and against the **5.72** that the
2026-09-05 fit document already described as *"essentially no freedom to
spread."*

**This arithmetic crosses synthesis contexts and is therefore a lead, not a
result.** It happens that the same crossing was checked earlier today and held
to 0.74% for these port-isolated blocks, which is why it is written down at
all -- but the honest form is that RBUF is worth measuring in the composed
context, not that the numbers above are the answer.

**And none of this makes the design fit.** 6.39 is still far above 5.72.
RBUF is a large, cheap, immediately available lever; it is not a solution.

## The fix that costs nothing, and is untested

`recbuf` is a register array. If the slots were held in **BRAM** and INDEXED
rather than muxed, the per-slot LUT cost should largely disappear while
prefetch depth is retained -- the design uses **0 of 672 BRAM tiles** today and
the composed design with both memory subsystems sits at 39.51%, so the tiles
exist. `CLAUDE.md` records that asking for a memory style gets a WARNING rather
than an error when refused, and that only the mapping report and an
object-level census settle whether it was granted, so this must be MEASURED and
not assumed.

**Not attempted here.** It is an RTL change to a block with four benches
(`tb_attn_kv_axi`, `tb_attn_kv_map`, and two more) and a mutation script
(`sim/mutate_attn_kv_axi.sh`), and it must be made behind those.

## Measured and REJECTED -- do not retry

- **Do not reduce `MAXOUT`.** MEASURED: `MAXOUT = 2` is 2,770 LUT LARGER.
- **Do not reduce `N_KVH` for area.** MEASURED: worth 0.9%, and it is a model
  parameter besides.
- **Do not read the hierarchy for a breakdown.** `report_utilization
  -hierarchical` shows `attn_kv_axi (top) 73050` and nothing else: the entity
  is flat, with no sub-instances. The breakdown had to come from a generic
  sweep.

## Open, not yet answered

- Whether `RBUF = 2` (no prefetch) costs throughput, and how much. It is legal
  and it is the minimum the assert allows; nothing has measured its effect on
  the token rate.
- Whether `recbuf` in BRAM retains RBUF 4's depth at a fraction of the logic.
- The composed-context value of any of these. All six points are OOC.
