# The fit answer omits the KV cache, and the KV cache is 16.6% of the device

**Date:** 2026-09-06
**Question:** `docs/debugging/2026-09-05_does-the-full-design-fit-on-the-card.md`
answers "does the full design fit" from `compose4_top`. Does `compose4_top`
contain the full design?

## The answer, up front

**No.** `compose4_top` instantiates `gdn_block` and `attn_block` **directly**.
It has no `gdn_state_store` and no `attn_kv_axi` -- the two blocks that the
`B_STATE_AXI` and `C_KV_AXI` generates instantiate inside `llama_top`, and the
two that own the HBM masters the whole port budget is written about.

`attn_kv_axi` had **never been measured**. It is:

```
RESULT attn_kv_axi lut=84252 ff=21147 dsp=45 ram=0 bram=0 uram=0 wns=-3.417
```

with the utilization census reading **LUT as Logic 73,050 = 16.61% of the
device**, LUT as Memory 0, 777 CARRY8, 0 BRAM, 0 URAM.

So the project's fit answer is missing a block that is one sixth of the part,
on a design already reported at **90.3% CLB occupancy**.

## What is and is not claimed

**MEASURED:** `attn_kv_axi` alone, out of context, at the composed shape
(HEAD_DIM 256, KV_BLOCK 32, N_KVH 4, LAYERS 8), on `xcvu33p-fsvh2104-2L-e`
with a 5.0 ns clock. 73,050 LUT-as-logic, 21,147 FF, 45 DSP, no memory
primitives at all.

**NOT CLAIMED: that the composed design plus this does not fit.** This file
does not do that arithmetic, deliberately. `CLAUDE.md` records the reason in
its own words -- *"the parts do not sum across synthesis contexts, so do not do
arithmetic on them"* -- and the measured case behind it: `gdn_block` alone
reports 22 BRAM tiles and 10,161 LUT-as-memory, while inside the composed block
the same RTL maps to 5,472 tiles and 35,078. A saving or a cost predicted by
adding one context's number to another's is two unrelated measurements, not a
prediction. **The way to answer the fit question is to put these two blocks
into the composed top and re-synthesise**, which is now a named work item
rather than an assumption.

**NOT A TIMING RESULT.** `wns=-3.417` is **post-synthesis**, and
`sim/ooc_attn_kv_axi.tcl` contains no `opt_design`, `place_design` or
`route_design`. `CLAUDE.md` records that C's mover went from **-4.008
post-synthesis to -1.438 routed**, a 2.57 ns improvement, and that both movers'
headline "blockers" were synthesis estimates quoted for a week. So the honest
statement is that this block has a large negative post-synthesis slack and its
real fmax is unknown. Do not quote 118.8 MHz.

## Two numbers that disagree, and both are right

The Tcl census reported `lut=84252` from
`get_cells -hier -filter {REF_NAME =~ LUT*}`; `report_utilization` reported
`LUT as Logic 73050`. The census counts **logical LUT primitives**; utilization
estimates **site usage**, and in an unplaced netlist two small LUTs can share
one site. The gap is 11,202, about 13%.

This is worth stating because `CLAUDE.md`'s rule is "when the census and
utilization disagree the census wins" -- and that rule is about a resource
being present or absent (`RAM=0 FF=1024` versus `RAM=4352 FF=0`), not about
site packing. **For a device-fraction claim the site number is the right one**,
which is why 16.61% is quoted above and 84,252 is not.

## What `gdn_state_store` contributes

`docs/PLAN_TO_FIRST_INFERENCE.md` records **4,028 CLB LUT, 2,004 FF, 32
URAM288, 12 RAMB36, 3 DSP, WNS +1.400**. Its default generics are already the
real card shape (VAL_HEADS 32, DIM 128, LAYERS 24, KEY_HEADS 16, KCONV 4),
confirmed against `llama_top`'s own generic map, so that figure is at the right
shape. It was **not** re-measured against this tree -- see the lane note below
-- and given that two quoted tables turned out stale earlier the same day, it
should be.

Note the 32 URAM288 there: URAM is fixed at synthesis and is available to a
store written at run time, which is exactly what this is. `attn_kv_axi` by
contrast uses **no** memory primitives, because the cache it manages lives in
HBM and this block is the interface, not the storage.

## Measurement traps hit

- **Reading the entity alone failed with a misleading error.**
  `attn_kv_axi.vhd:265` is `use work.util_pkg.all`, which is where `clog2`
  lives. Omitting `util_pkg.vhd` gives `[Synth 8-36] 'clog2' is not declared`
  and then **`[Synth 8-439] module 'attn_kv_axi' not found`** -- which reads as
  a missing or misnamed top, not a missing package. The anchored sentinel count
  was 0 and that is what prevented the failure being read as a result.
- **`ping` is not a lane check.** See below.

## Measured and REJECTED -- do not retry

- **Do not treat `compose4_top` as the full design for fit purposes.** It is a
  co-residency vehicle for A, B, C and D's compute, and it excludes both HBM
  memory subsystems.
- **Do not quote a post-synthesis WNS from these OOC harnesses as an fmax.**
  Check for `route_design` in the script first; it is not there.

## THE SECOND LANE WAS NOT FREE, AND `ping` SAID IT WAS

`CLAUDE.md` describes the BC-250 as provisioned for exactly this and records it
as *"up 3 days, load 0.07, 13 of 14 GB free"*. That was an observation on
2026-08-30, not a property.

MEASURED today, after the job had already been launched:

```
Mem:  14 total   11 used   3 available
re9.exe          2,245,144 kB   648 s
steamwebhelper     186,576 kB
steamwebhelper     185,616 kB
steamwebhelper     147,012 kB
```

**The box is in interactive use.** One Vivado there costs ~10.85 GB against
3.1 GB available, and `CLAUDE.md` already records that a `MemoryHigh=12G` run
on that 14 GB box left it **completely unreachable and needing a physical
power-cycle**, with no WoL watchdog. The job was stopped immediately;
`systemctl --user stop` returned `inactive`, a `/proc/PID/exe` scan confirmed
**0 Vivado processes**, and memory returned to 3.4 GB available with the user's
own session untouched.

**The lane check for that box is `free`, not `ping`.** Reachability says the
machine is on; it says nothing about whether the 10.85 GB a Vivado needs is
there. Add the memory read to the dispatch, before launch rather than after --
here the check ran three seconds late and the only reason that was harmless is
that synthesis had not yet grown past 779 MB.

## Open, not yet answered

- The composed design WITH `attn_kv_axi` and `gdn_state_store` has not been
  synthesised. That is the only thing that answers the fit question.
- `MAXCTX` was left at its default **2048**. The card's real `max_context` is
  **262,144**, and `POS_W = 16` caps MAXCTX at 65,536, so **the card
  configuration is not the one measured here** and the relationship between
  MAXCTX and this block's area is unmeasured.
- `gdn_state_store` was not re-measured against this tree.
