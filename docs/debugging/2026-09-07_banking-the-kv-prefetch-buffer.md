# Banking the KV prefetch buffer: 48,388 LUT out of a multiplexer

**Date:** 2026-09-07
**Question:** `attn_kv_axi`'s 73,050 LUT were traced to its prefetch-slot
multiplexer at ~21,000 LUT per slot. Can the slots be held in BRAM instead,
keeping `RBUF = 4`'s prefetch depth?

## The answer, up front

**The BRAM attribute alone does nothing, and it turned out not to be needed.**

`attribute ram_style of recbuf : signal is "block"` changed **nothing**:
identical 73,050 LUT, identical 21,147 FF, 0 BRAM, **and no warning at all**.
Vivado silently declined, because the array is written **twice** per cycle (the
capture loop runs `BEAT_CH = 2` times) and read **three** times (header plus
`MPB = 2` mantissa chunks). 2W/3R is not an inferrable RAM.

What worked was **splitting the array so the multiplexer disappears**, with no
BRAM at all:

| | LUT | FF | BRAM |
|---|---|---|---|
| before | 73,050 | 21,147 | 0 |
| `ram_style = "block"` | 73,050 | 21,147 | 0 |
| **banked** | **24,662** | 20,635 | 0 |

**-48,388 LUT, 66.2% of the block, 11.0% of the device**, at `RBUF = 4` --
so it beats the `RBUF = 2` option (-42,009) *and* keeps full prefetch depth.
FF barely moved, which confirms storage was never the cost.

## The split is an identity, and that is why it is safe

The read index was

```
hit_slot*CPR + 1 + q_blk*MPB + c,     c in 0 .. MPB-1
```

Substituting `mm = 1 + q_blk*MPB + c` gives `(mm-1) mod MPB = c` **exactly** and
`(mm-1)/MPB = q_blk` **exactly**, because `c < MPB`. So banking on
`(mm-1) mod MPB` sends each of the `MPB` reads to its own bank at index
`hit_slot*NBLK + q_blk`, and `CPR-1 = NBLK*MPB` makes that index range exact
rather than merely sufficient. The header (`mm = 0`) is kept in a small
register file because only `NBLK*EXP_W` of its bits are read and there are only
`RBUF` of them.

At the composed shape the flat array was **68 words x 128 bits = 8,704 bits per
read engine**. Two banks of 32 words plus 4 header words replace one 68-way
select, three times over, twice (K and V).

**No bank ever sees two writes in one cycle.** The two chunks arriving per cycle
have consecutive `mm`, and consecutive `mm` always differ in `(mm-1) mod MPB`
or land on the header.

## In context, the saving is larger than out of context

`compose4_mem` (A+B+C+D plus both HBM memory subsystems), placed:

| | before | after | change |
|---|---|---|---|
| CLB | 54,351 (**98.89%**) | 51,920 (**94.47%**) | -2,431 sites |
| CLB LUTs | 342,163 | 289,767 (65.90%) | **-52,396** |
| packing density | 6.30 LUT/CLB | 5.58 | -0.72 |
| placed WNS (NOT an fmax) | -5.136 | -4.383 | +0.753 |

The in-context saving of **52,396** exceeds the out-of-context **48,388**.
Worth noting against this project's standing rule that the parts do not sum
across synthesis contexts: here the context did not merely preserve the saving,
it amplified it, presumably because the placer no longer has to route a 68-way
select through a congested region.

## What this does and does not do for the fit

DERIVED, using the shell figure carried from 2026-09-05 (50,999 LUT):

| | total LUT | density needed device-wide |
|---|---|---|
| before | 393,162 (89.4%) | **7.15 LUT/CLB** |
| after | 340,766 (77.5%) | **6.20 LUT/CLB** |

**It does not make the design fit.** 6.20 is still well above the **5.72** that
the 2026-09-05 document already called *"essentially no freedom to spread"*.
This is a large step and not a solution, and the shell figure is still carried
from another tree rather than re-derived against this one.

## Verification

- **The four benches pass**: `tb_attn_kv_axi`, `tb_attn_kv_map`,
  `tb_attn_kv_quant`, `tb_attn_kv_seam`. They also passed BEFORE the change, so
  that on its own proves nothing -- hence:
- **Three purpose-built mutants, each killing 3 of the 4 benches**: write bank
  index and word index swapped (`mod` <-> `div`); read index using an `RBUF`
  stride instead of `NBLK`; header read from slot 0. The benches genuinely
  discriminate on the banking.
- **The block's own mutation script**: 21 killed of 29, 3 survivors, 2 aborts.
- **Full gate**: PASS 136, FAIL 0, BUILD-ERROR 0, unchanged from before.

## THE TRAP: the RTL change silently disabled two of the block's own mutations

`sim/mutate_attn_kv_axi.sh` anchors each mutation on **source text**. Two of
them (`O3`, `O4`) quoted the `recbuf` lines verbatim, so after the split they
stopped matching and were reported as *"never ran (anchor failure)"*.

MEASURED, and the attribution is exact:

| | killed | never ran |
|---|---|---|
| after the change, anchors untouched | 19 | **5** |
| after re-anchoring O3 and O4 | **21** | **3** |

**Nothing failed.** Every surviving row still passed, the four benches were
green, and the block's verification had quietly shrunk by two mutations. The
only tell was a count in the last four lines of the script's output.

`O3` was re-anchored keeping its INTENT rather than its text: its "+1" no
longer exists because the banking absorbed it, so the analogous defect is the
two mantissa chunks arriving from swapped banks (`MPB-1-c`), which is in bounds
by construction. Both re-anchored mutations are KILLED, so the new anchors have
teeth rather than merely matching.

**Generalise: a mutation anchored on source text is invalidated by the refactor
it is meant to survive, and it fails OPEN.** After any RTL change, read the
never-ran count, not just the kill count.

## Measured and REJECTED -- do not retry

- **`attribute ram_style = "block"` on `recbuf`.** MEASURED: byte-identical
  results, 0 BRAM, and no warning of any kind. 2W/3R is not inferrable and
  Vivado says nothing about it.
- **Reducing `RBUF` for area.** Superseded: banking gives more (-48,388 vs
  -42,009) and keeps the prefetch depth.

## Open, not yet answered

- The banks are still fabric, not BRAM. The design uses **0 of 672** BRAM
  tiles. Whether a further restructure into true 1W/1R banks would infer BRAM
  and save the remaining ~24,662 LUT is untested.
- Whether routing confirms the placed WNS improvement. Nothing here routes, and
  a placed WNS has been measured to mis-order two runs on this part.
- The shell has still not been re-derived against this tree.
