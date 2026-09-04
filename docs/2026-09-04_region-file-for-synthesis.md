# What the region file must become, and what it will cost

**Date:** 2026-09-04
**Blocks:** synthesis of `rtl/llama_top.vhd` at the 9B shape
**Status:** DESIGN NOTE. Nothing here is implemented.

## Why

`sim/ooc_llama_top.tcl` produced exactly one error
(`docs/debugging/2026-09-04_llama-top-9b-region-file.md`):

```
WARNING: [Synth 8-4767] Trying to implement RAM 'mem_reg' in registers.
  1: RAM has too many ports (16). Maximum supported = 16.
ERROR: [Synth 8-3391] ... the number of bits (2752512) is too large
```

`llama_top.vhd:1159` is `NREGION*REGMAX` elements of `signed(MANT_W-1 downto
0)` = 14 x 12,288 x 16 = 2,752,512 bits = 336 KiB, in one object.

## The port census, MEASURED from the RTL rather than from the error

Every access to `mem`, from `grep -n '\bmem\b' rtl/llama_top.vhd`:

| line | access | kind | count |
|---|---|---|---|
| 1415 | `mem(el_wreg*REGMAX + el_waddr) <= el_wdata` | sync write | 1 |
| 1423 | `mem(a) <= w_data(...)` inside `for i in 0 to LANES-1` | sync write | **8** |
| 1430 | `el_rdata <= mem(el_reg*REGMAX + el_addr)` | sync read | 1 |
| 1439 | `x_rdata(...) <= mem(a)` in the lane loop | sync read | **8** |
| 1446 | `e_rdata(...) <= mem(a)` in the lane loop | sync read | **8** |
| 1455 | `hr_data <= mem(hr_reg*REGMAX + hr_addr)` | **ASYNC read** | 1 |

Nine writes and eighteen reads. Two separate things make this un-inferable and
they need different fixes:

1. **The width.** 8 lanes wide on both the write and the two read groups.
2. **Line 1455 is asynchronous**, outside `memp`, so it is a distributed-RAM
   or register pattern by construction. **No block RAM has an asynchronous
   read port**, so this one line alone rules BRAM out for the whole object no
   matter what else is done.

## The structural fact that makes this easy: the lanes do not overlap

Every lane access is

    a = base*REGMAX + addr*LANES + i        for i in 0 .. LANES-1

so `a mod LANES = (base*REGMAX + i) mod LANES`. DERIVED:

    REGMAX mod LANES = 12288 mod 8 = 0

therefore `a mod LANES = i` **exactly**, for every base and every addr. **Lane
i touches only addresses congruent to i mod LANES, and no other lane ever
does.**

This is not an approximation or a common case. It is a consequence of REGMAX
being a multiple of LANES, and it should be ASSERTED at elaboration with the
out-of-range-`natural` idiom rather than assumed, because a future shape whose
`region_max` is not a multiple of 8 would silently break the banking:

```vhdl
constant bad_regmax_not_banked : natural := 0 - (REGMAX mod LANES);
```

## The shape

Split `mem` into `LANES` banks of `NREGION*REGMAX/LANES` words, bank i holding
the addresses with `a mod LANES = i`. The lane loops then become one access
per bank instead of eight into one object, and each bank sees:

| bank port | from |
|---|---|
| write | the lane-i write (line 1423) |
| write | the scalar `el_we` write, when its address lands in bank i |
| read | the lane-i `x_rdata` read |
| read | the lane-i `e_rdata` read |
| read | the scalar `el_ren` read |
| read | `hr_data` |

Two writes and four reads per bank, against a true-dual-port BRAM's two ports.
So the banks need **replication**: two copies of each bank, written
identically, serving two read ports each.

## The cost, DERIVED

Per bank: 21,504 words x 16 bits = 344,064 bits. A RAMB36 is 36,864 bits.

| configuration | tiles | of 672 |
|---|---|---|
| 8 banks, 1 replica | 74.7 | 11.1% |
| 8 banks, 2 replicas | **149.3** | **22.2%** |

For scale, the whole A-only endpoint bitstream built on 2026-09-04 uses 261.5
tiles, and the composed `compose4_top` route uses 48.74% of 672. **150 tiles is
affordable but it is not free**, and it must be added to any llama_top budget.

**This supersedes nothing measured** -- there has never been an area figure for
llama_top at any shape, because it has never synthesised.

## What to do about line 1455

`hr_data` is the host read window. Registering it is a ONE-CYCLE CHANGE TO A
CONTRACT, not a refactor, so it cannot be done silently: `sim/tb_fk33_seam.vhd`
and the host-window path read it, and `rtl/seq_desc_fetch.vhd:166`'s lesson
applies -- read the driver's stated contract, take the weaker one.

Two options, and the choice is a real one:

- **Register it** and move every reader one cycle later. Cheapest in area, and
  the host window is not a latency-critical path. Requires touching the seam
  bench.
- **Keep it asynchronous and serve it from a small distributed-RAM shadow.**
  No contract change, but it is a second copy of 336 KiB in LUTRAM, which is
  the resource the design is already tightest on.

**Registering is the recommendation**, because the host window is a debug and
bring-up path, and because a LUTRAM shadow spends the scarcer resource to
avoid a cycle nobody is counting.

## How to land it without breaking anything

The proven pattern in this tree is B's state store: a generic selecting
between the flat behavioural model and the synthesisable one, so every
existing bench keeps running the model it was verified against and the new
path gets its own rows. `B_STATE_AXI` did exactly this on 2026-09-03 and the
two tiers were pinned to the SAME landmarks, so a tier computing different
numbers fails rather than merely differing.

The same applies here: `REGFILE_BANKED : boolean := false`, the flat array
kept as the default, and a wrapper row per existing llama_top bench with the
generic true and the landmarks copied verbatim.

## Open, not yet answered

- **Whether llama_top FITS at 9B once this is done.** Unknown, and this note
  does not answer it: 150 tiles is the region file alone. There is still no
  area figure for llama_top at any shape.
- **Whether the two writes per bank actually conflict. PARTIALLY ANSWERED,
  and the answer is uncomfortable.** `llama_top.vhd:1554-1556` already assumes
  they do not:

  ```vhdl
  wr_we     <= w_we or el_we;
  wr_region <= v_reg_d when w_we = '1'
               else to_unsigned(el_wreg, 8);
  ```

  That mux PICKS ONE. If both were high in the same cycle the lock would be
  told about the `w_we` region and never about the `el_we` one, so a
  simultaneous scalar write would go unpoliced -- and `memp` would perform
  BOTH writes regardless, because they are separate `if` arms.

  **Nothing checks this.** `w_we` comes from `u_vres` (line 1624) and `el_we`
  from the element mux, whose write side is taken from `hw_we` -- THE HOST
  WRITE WINDOW -- in preference to any unit (lines 1378-1383). A host write is
  not sequenced by D at all, so the exclusivity is an assumption about how the
  host behaves, not a property of the design.

  This must be settled BEFORE the banking is sized, because it decides one
  write port per bank or two, i.e. 75 tiles or 150. The cheap first step is a
  counter in `memp` for `w_we = '1' and el_we = '1'` and a bench case that
  drives a host write during a D-vec write: either it proves the case
  unreachable, or it has found a live unpoliced-write defect. **Either outcome
  is worth more than the tile count.**
- **`hr_data`'s consumers.** Named as the seam bench and the host window; not
  enumerated exhaustively.
