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

---

## MEASURED, same day: the design WITH both memory subsystems, and a control

`gen_compose4_top.py --mem` (added 9b3e49f) instantiates `gdn_state_store` and
`attn_kv_axi` alongside the five compute blocks. Both tops were synthesised
**from the same tree through the same script with one variable changed**, which
is the control this project failed to run twice earlier the same day.

| resource | without mem | with mem | delta | device | % with |
|---|---|---|---|---|---|
| CLB LUTs | 267,202 | **343,712** | +76,510 | 439,680 | **78.17** |
| CLB Registers | 237,905 | 261,044 | +23,139 | 879,360 | 29.69 |
| CARRY8 | 12,505 | 13,327 | +822 | 54,960 | 24.25 |
| Block RAM Tile | 253.5 | 265.5 | +12 | 672 | 39.51 |
| URAM288 | 0 | **32** | +32 | 320 | 10.00 |
| DSP48E2 | 2,177 | 2,185 | +8 | 2,880 | **75.87** |

**The control validates itself three ways**, which is what makes the delta
attributable rather than merely plausible:

- DSP48E2 without `--mem` is **2,177**, reproducing the figure the 2026-09-05
  fit document already carried. A control that lands on a previously published
  number is the strongest available evidence that the flow is the same one.
- URAM goes **0 -> 32**, matching `gdn_state_store`'s recorded 32 URAM288 to the
  digit. URAM is fixed at synthesis, so this also proves the resource was
  GRANTED rather than refused -- see `[Synth 8-10226]`, which refuses a URAM
  request and only WARNS.
- BRAM goes **253.5 -> 265.5**, matching its recorded 12 RAMB36 exactly.

### The answer on hard resources

**They fit.** LUT 78.17%, DSP 75.87%, BRAM 39.51%, URAM 10.00%, and none of
these move under implementation directives. The design that the port budget and
the grant are written about -- A, B, C, D plus both HBM memory subsystems --
does not exceed the part on any resource fixed at synthesis.

**CLB OCCUPANCY IS STILL UNANSWERED AND IT IS THE BINDING ONE.** The
2026-09-05 fit document found the composed design at **90.3% CLB** while LUT sat
at 71.5%, because CLB is a placement outcome and the one row in
`report_utilization` that does not sum. Nothing here places anything. A LUT
figure under 100% is necessary and not sufficient, and the honest state is that
the fit question has been answered for five resources and not for the sixth.

### CORRECTION: attn_kv_axi has 5 DSPs, not 45

The measurement above says `attn_kv_axi lut=84252 ... dsp=45`. **The DSP count
is wrong.** `get_cells -hier -filter {REF_NAME =~ DSP*}` matches the DSP's
SUB-CELLS -- `DSP_MULTIPLIER`, `DSP_ALU`, `DSP_OUTPUT` -- not whole DSP48E2s.
`report_utilization` for the same run says **DSP48E2 = 5**.

The composed run made the same error much more loudly: its census reported
`dsp=19665` on a part that has **2,880**, which is impossible on its face and
is what exposed the filter.

With 5 rather than 45, the predicted delta from summing the parts becomes
`3 + 5 = 8`, and the measured delta is **exactly 8**.

**This qualifies `CLAUDE.md`'s "the parts do not sum across synthesis
contexts".** Here they summed, to within 0.74% on LUT, 0.05% on FF, and exactly
on BRAM, URAM and DSP:

| resource | predicted | measured | error |
|---|---|---|---|
| LUT | 77,078 | 76,510 | +0.74% |
| FF | 23,151 | 23,139 | +0.05% |
| URAM | 32 | 32 | 0.00% |
| BRAM | 12 | 12 | 0.00% |
| DSP | 8 | 8 | exact |

The rule is real and it is CONDITIONAL. Its recorded counter-example is
`gdn_block` reporting 22 BRAM tiles alone against 5,472 in context -- a block
whose memory INFERENCE changed with what surrounded it. These two blocks are
port-isolated: every one of their ports is exported, so Vivado cannot merge
their logic with anything, and there is nothing for the context to change.
**Ask whether the block shares anything with its surroundings before deciding
which case you are in** -- and note that even here the prediction was made
AFTER the measurement, so it is a consistency check and not a forecast.

`REF_NAME =~ DSP*` was chosen because `CLAUDE.md` records `REF_NAME =~ RAM*` as
the working idiom against a `PRIMITIVE_GROUP == DSP` filter that silently
matched nothing. That fix was right for the empty-result failure and wrong
here: **`RAM*` has no sub-cell problem and `DSP*` does.** For DSP, read
`report_utilization`'s `DSP48E2` row.

---

## PLACED, and this is the answer: 98.89% CLB for the ENGINE ALONE

`place_design` on `compose4_mem`, out of context, no shell:

```
| CLB   |  54351 |     0 |     0 |  54960 | 98.89 |
|   CLBL|  28912
|   CLBM|  25439
| CLB LUTs | 342163 | ... | 439680 | 77.82 |
C4P_RESULT top=compose4_mem clb=54351 clb_avail=54960 placed_wns_NOT_AN_FMAX=-5.136
```

**609 CLB sites spare, at a packing density of 6.30 LUT/CLB.**

For contrast the composed design WITHOUT the two memory subsystems placed at
**49,620 CLB (90.3%) at 5.31 LUT/CLB**. So the placer absorbed the extra 76,510
LUT largely by packing harder -- density rose 19% -- rather than by spreading,
because there was nowhere to spread to.

### And the shell still has to go somewhere

| | LUT | CLB | density |
|---|---|---|---|
| engine + both memory subsystems (MEASURED, placed) | 342,163 | 54,351 (98.89%) | 6.30 |
| PCIe/HBM shell (2026-09-05, same-stage derived) | 50,999 | 10,446 | 4.88 |
| **whole card** | **393,162 (89.4% LUT)** | naive 64,797 = **117.9%** | **7.15 needed** |

The naive CLB sum is **not** a valid figure -- CLB is a placement outcome and
does not add -- which is exactly the trap the 2026-09-05 document flagged. The
valid form of the question is the one that document used: **what packing
density would the placer need device-wide?**

- Without the memory subsystems: **5.72 LUT/CLB**, which that document called
  *"achievable, since the architectural maximum is 8, but it means the placer is
  left with essentially no freedom to spread."*
- With them: **7.15 LUT/CLB**, 89% of the architectural maximum, device-wide,
  including a shell that measured 4.88 and shows no sign of packing to 7.

**No run has demonstrated 7.15 device-wide on this part, and the engine alone
needed 6.30 with 609 sites to spare.** The honest statement is that the full
card design as currently structured does not have a credible fit, and that this
is a NEW conclusion: every prior fit answer was taken on a top containing
neither HBM memory subsystem.

### The cause is nameable and it is one block

`attn_kv_axi` is **73,050 LUT-as-logic, 16.61% of the device**, against
`gdn_state_store`'s 4,028. It is 95% of the +76,510 LUT that moved the engine
from 90.3% to 98.89% CLB.

It contains **no memory primitives at all** -- 0 BRAM, 0 URAM, 0 LUT-as-memory
-- because the cache it manages lives in HBM and this block is the address
generation, the record packing and the burst logic. 73,050 LUT of pure
combinational logic for an AXI interface is the number to be suspicious of, and
nobody has ever looked at it, because until today nobody had synthesised it.

### What is NOT concluded

- **That it cannot be made to fit.** Nothing here has tried `-directive` options
  on placement, and no attempt has been made to reduce `attn_kv_axi`.
- **Any timing statement.** `placed_wns = -5.136` is recorded for the log and is
  not an fmax: `CLAUDE.md` records a composed run placing at -0.406, reading
  +0.006 after phys_opt, and routing at -0.422. Nothing before `route_design`
  orders two runs correctly.
- **That the shell figure is same-tree with this one.** It is carried from the
  2026-09-05 document. Given that a stale table cost this project a wrong
  conclusion earlier the same day, the shell should be re-derived against this
  tree before the 7.15 figure is treated as final.

## Open, not yet answered

- Why is `attn_kv_axi` 73,050 LUT? No breakdown exists. That is the single
  highest-value question this measurement raises.
- `MAXCTX` is 2048 here against the card's real 262,144, and `POS_W = 16` caps
  it at 65,536. The card configuration is still not the one measured.
- The shell has not been re-derived against this tree.
