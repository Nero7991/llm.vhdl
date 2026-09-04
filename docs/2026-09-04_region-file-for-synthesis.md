# What the region file must become, and what it will cost

**Date:** 2026-09-04
**Blocks:** synthesis of `rtl/llama_top.vhd` at the 9B shape
**Status: SUPERSEDED. READ THIS BOX BEFORE THE REST.**

> **THIS NOTE DESIGNS SOMETHING THAT ALREADY EXISTS.** `rtl/region_mem.vhd`
> implements the substitution, `sim/tb_region_mem.vhd` holds it with six
> mutations, and `tools/gen_cardtop.py` applies it to the card top as decision
> **D3**, taken 2026-09-02. `llama_top` keeps the flat array on purpose, under
> decision **D1**, because it is the untouched oracle the card top is tested
> against. `sim/elab_cardtop.tcl` had already recorded the same crash, with
> the same 2,752,512-bit figure.
>
> The note was written from a careful reading of `llama_top.vhd` and no search
> of `rtl/` for an existing region memory, which is the exact failure
> CLAUDE.md describes: *"BEFORE WRITING A MODULE, GREP THE ENTITY
> DECLARATIONS FOR THE SHAPE YOU ARE ABOUT TO BUILD."*
>
> **What survives, because it was measured rather than assumed:** the
> `REGMAX mod LANES = 0` result and the lane-alias argument; the two
> corrections to my own tile arithmetic (depth granularity, and a replica
> costing one write plus one read); and the port-count conclusion that two
> writes plus a read exceeds a primitive's two ports, so the host-write
> exclusivity is a precondition rather than an optimisation. Those apply to
> `region_mem` too and were not stated there.
>
> **What is withdrawn:** the recommendation to build any of it. It is built.
> See `docs/debugging/2026-09-04_llama-top-9b-region-file.md`, CORRECTION 3,
> for the blocker that is actually next on the card top.

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

## ANSWERED: two write ports per bank, not one

**The exclusivity is a HOST USAGE CONVENTION, not a property of the design.**
MEASURED 2026-09-04 with a `wcollide` assert added to `llama_top.vhd` (same
shape as the existing `onehot` guard, so Vivado ignores it in synthesis).

Across all eight llama_top gate rows the assert never fires. **That result is
vacuous**, and instrumenting `tb_llama_top_real` says why:

```
WCOLL_PROBE hw_we=128  w_we=128  el_we=8959  both=0  hw_while_busy=0
```

The bench DOES drive the host write window, 128 times -- and **not once while
the machine is busy**. Every host write happens before `go`. So the collision
is UNTESTED, not impossible, and nothing in the RTL prevents it: `elmux` takes
`hw_we` in preference to any unit, and a host write is not sequenced by D.

**The check is armed, which had to be shown separately.** Teeth: weakening the
condition to `w_we = '1'`, reached 128 times, fires it at 5.09 ns. So a green
run means the condition was not reached, not that the assert is dead code.

Therefore the banked region file must budget **two write ports per bank,
149.3 tiles of 672**, and the 74.7 figure is not available. Halving it requires
the RTL to ENFORCE the convention -- refusing or stalling a host write while
`busy` -- which is a contract change, not a refactor, and would need the seam
to report the refusal.

**Taking the 74.7 number on the strength of `both=0` would have been the exact
failure this project keeps hitting**: a guard that has never been shown to
discriminate, used as evidence.

## CORRECTION 2026-09-04: the hazard runs the other way

The section above, and commit `444a357`, described a coincident scalar write
as reaching the region file **"unpoliced by the lock"**. **That claim is
withdrawn.** It is not the hazard, and it misreads `gatechk`:

```vhdl
elsif wr_we = '1' and wr_gate /= '1' and hw_we = '0' then
```

**A host write is DELIBERATELY exempt from the lock check, always** -- not only
when it collides. Nothing was ever policing it, so a collision cannot make it
unpoliced.

The real hazard is the reverse. When `hw_we` and `w_we` are high in the same
cycle, that `hw_we = '0'` term makes the whole condition FALSE, so **a D-vec
write that is genuinely outside its lock window is not flagged**. A host write
MASKS a D-vec lock violation. `f_gate` stays low, `err_gate_drop` stays low,
and nothing reports it.

This is a **detection hole in a guard**, which is a different defect class from
an unpoliced write, and it is the class this project keeps rediscovering: the
check is correct for the case it was written for and silently absent for one it
was not.

**What does NOT change:** the collision is still untested (`hw_while_busy=0`),
the exclusivity is still a host convention rather than a design property, and
the banked region file still needs two write ports per bank unless the RTL
enforces the convention. The tile numbers stand.

**What this adds:** enforcing the convention is now worth more than the 74.7
tiles. It would close the detection hole as a side effect, because with the
two writes made mutually exclusive the `hw_we = '0'` term can no longer
suppress a D-vec check that would otherwise have fired.

## CORRECTION 2026-09-04 (second): the tile numbers above are WRONG, and the
## banking was the wrong structure

**The 74.7 and 149.3 tile figures are withdrawn.** They are wrong in two
independent ways, and the second one changes the design rather than the price.

**Error 1: depth granularity ignored.** A bank of 21,504 words is not
`344064/36864 = 9.33` tiles. A RAMB36 is 1024x36, 2048x18 or 4096x9, so a
21,504-deep by 16-wide bank costs **11 tiles at 2048x18** (and 21 at 1024x36).
Dividing total bits by total bits per tile assumes a packing the primitive
cannot do.

**Error 2: a replica was costed as free of ports.** A block RAM has TWO ports.
In simple-dual-port a replica serves **one write and one read**. The bank needs
three reads (lane `x`, lane `e`, and the scalar `el_ren`/`hr_data` pair muxed),
so it needs **three replicas, not two**.

Corrected, at 2048x18: 8 x 11 x 3 = **264 tiles, 39.3% of 672.**

**AND A PRECONDITION FALLS OUT OF THE PORT COUNT.** Two writes plus one read is
three ports on a replica that has two. So **no BRAM implementation exists at
all while the host write can coincide with the D-vec write** -- enforcing the
exclusivity is not an optimisation that halves the cost, it is a
**precondition**. That is a stronger statement than the section above makes and
it supersedes it.

### The banking was the wrong structure: the lanes are ONE WIDE WORD

The lane write writes all `LANES` elements in one cycle under `w_be`, and both
lane reads read all `LANES` in one cycle. So the eight lanes are not eight
banks to be accessed independently -- **they are one 128-bit word**, and the
natural memory is

    21,504 words x (LANES * MANT_W) = 21,504 x 128

which is the same 2,752,512 bits arranged the way the accesses actually use
them. The `a mod LANES = i` result above is still exactly right; it is what
proves the eight elements at one `r_addr` are contiguous and never alias, which
is what makes the wide word legal. It just is not a reason to build eight
separate memories.

### With the wide word, URAM is the right resource

`URAM288` is 4096x72 and this device has **320 of them, idle**. CLAUDE.md
records that URAM cannot hold an initialised table -- but the region file is
written at run time and initialised to zero, so that restriction does not
apply here.

| structure | per replica | x3 replicas | of the device |
|---|---|---|---|
| BRAM 2048x18, 8 banks x 16b | 88 tiles | **264** | 39.3% of 672 |
| URAM 4096x72, one 128b word | 12 URAM | **36** | **11.3% of 320** |

The wide word needs 2 URAMs across (2 x 72 = 144 >= 128) and 6 deep
(21,504 / 4096 = 5.25 -> 6). **36 URAM against 264 BRAM tiles**, on a resource
nothing else in the design is using.

**The cost that buys it:** the scalar writes (`el_we`, and the host write
behind it) write ONE element into a 128-bit word. URAM has byte-write enables,
so a 16-bit lane is two of them and this is expressible -- but it is the part
of the design that has to be got right, and it is where a read-modify-write
would creep in if the enables are handled carelessly.

**None of this is implemented.** It is arithmetic and a structure, checked
against the primitive geometries, and it replaces the arithmetic above rather
than refining it.

## Open, not yet answered




- **Whether llama_top FITS at 9B once this is done.** Unknown, and this note
  does not answer it: 150 tiles is the region file alone. There is still no
  area figure for llama_top at any shape.
- **[ANSWERED 2026-09-04, see the section above. Kept for the record.]**
  **Whether the two writes per bank actually conflict. The answer is
  uncomfortable.** `llama_top.vhd:1554-1556` already assumes
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
