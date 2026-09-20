# bnarrow_ooc_2026-09-20: `gdn_state_store` at 9B, OOC, `NWIDE` priced four ways

TRACK BNARROWSYN, 2026-09-20. Four out-of-context synthesis draws of
`rtl/gdn_state_store.vhd` on the workstation (`Oren-Dell-Ubuntu`, Vivado
2023.2, `xcvu33p-fsvh2104-2L-e`), one Vivado at a time under
`systemd-run --user --same-dir --scope -p MemoryHigh=10G`, by
`sim/ooc_bnarrow_run.sh` driving `sim/ooc_bnarrow.tcl`. Repo HEAD `b0a28b6`.
No hardware was touched: `synth_design` / `opt_design` / `report_*` only.

## The question

TRACK BNARROW (`748ff91`) added the generic `NWIDE` to `gdn_state_store`: the
three NARROW movers -- exponents, conv taps, layer constants -- get a
beat-wide port, which needs `gdn_exp_mem` banked 32 ways and the two conv
memories banked on a three-axis (slot, lane, sub-group) scheme giving 48 and
64 banks of 512 x 16. MEASURED in GHDL it takes a 9B B job from 307,784 to
222,805 cycles. **No Vivado ran in that track.** Its area claim was DERIVED
at **+28 BRAM tiles** and the placed card
(`hw/fk33/results/card_swg_2026-09-20/bd_wrapper_utilization_placed.rpt`) has
**105 free tiles of 672** and **106 free CLBs of 54,960**, so the census is
the gate. It also explicitly REJECTED a 12-bank wider-word alternative,
without measuring it.

## The answer

1. **`NWIDE => true` FITS, and it is not only a cost.** MEASURED: **+28 BRAM
   tiles** -- the DERIVED figure, to the tile -- and **-368 LUT, -1,659 FF**,
   with URAM, DSP and the worst-path timing estimate all unchanged to the
   digit. The three narrow movers lose more logic than the banking adds.
2. **URAM is a better home, and it does not cost the BRAM, it REFUNDS it.**
   With `CONV_STYLE => "ultra"` the two conv memories map to **112 URAM288**
   and the unit's Block RAM Tile count goes to **ZERO** -- 28 tiles BELOW
   today's card path, not 28 above. `[Synth 8-10226]` and `[Synth 8-7186]`
   are absent and the object census names all 112. One open risk, below: the
   URAM mapping report carries **no write-mode column**, where the BRAM one
   says `READ_FIRST`.
3. **The rejected 12-bank arm was rejected for the wrong reason, and it is
   still the worst of the three.** Built and bench-verified, it infers
   **12 RAMB36** (not the zero BRAM its refusal predicted, and not the "same
   tile count" its header claims -- it is HALF the tiles of the shipping WIDE
   arm), but it costs **+650 LUT** against `nw` and is dominated by `nwu` on
   every axis.

## The table (MEASURED, post-`opt_design`, `report_utilization`; WNS is a synthesis ESTIMATE, unplaced, unrouted)

All four arms carry `PIPE=true WIDE=true MAXOUT=8` -- the levers already on
the card -- plus the 9B generic map below. `ctrl` is therefore the CARD PATH
TODAY, and the deltas are what the dispatcher would be buying.

| arm | change against ctrl | LUT | LUT logic | LUTRAM | FF | BRAM tile | RAMB36 | RAMB18 | URAM | DSP | CARRY8 | F7 | F8 | WNS @13.333 | WNS @5.0 | levels |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **ctrl** | none (the card path) | 5,479 | 3,411 | 2,068 | 6,511 | **28** | 28 | 0 | 32 | 4 | 49 | 232 | 96 | +10.096 | +1.763 | 7 |
| **nw** | `NWIDE=true` | 5,111 | 3,387 | 1,724 | 4,852 | **56** | 0 | 112 | 32 | 4 | 46 | 32 | 0 | +10.096 | +1.763 | 7 |
| **nwu** | `NWIDE=true` + `CONV_STYLE="ultra"` | 5,100 | 3,376 | 1,724 | 4,852 | **0** | 0 | 0 | **144** | 4 | 46 | 32 | 0 | +10.096 | +1.763 | 7 |
| **d12** | `NWIDE=true`, tap store 12 banks of 64 bits | 5,761 | 4,037 | 1,724 | 4,852 | **44** | 12 | 64 | 32 | 4 | 46 | 32 | 0 | +10.139 | +1.806 | 7 |

Deltas against `ctrl` (DERIVED): `nw` **-368 LUT / -1,659 FF / +28 tiles**;
`nwu` **-379 LUT / -1,659 FF / -28 tiles / +112 URAM**; `d12`
**+282 LUT / -1,659 FF / +16 tiles** (and `d12` converts only the TAP store,
see the caveat under its heading).

Peak memory, cgroup `memory.peak` of each draw's own scope against a 10 GiB
cap, with `memory.swap.current` read at the same instant:

| arm | cgroup peak MB | cgroup swap MB | at cap | /proc RSS peak GB | wall s |
|---|---|---|---|---|---|
| ctrl | 3,437 | 0 | **no** | 3.46 | 68 |
| nw | 3,138 | 0 | **no** | 3.53 | 63 |
| nwu | 3,158 | 0 | **no** | 3.52 | 63 |
| d12 | 3,101 | 0 | **no** | 3.49 | 91 |

None reached its cap, so each figure is the job's appetite and not the
throttle's (CLAUDE.md: a capped job's `memory.peak` IS the cap). Zero swap in
every scope.

The generics, on every draw, are `llama_top`'s `u_state` generic map at 9B
(`rtl/llama_top.vhd:5125`; `BST_*` from `SHAPE`;
`hw/fk33/rtl/fk33_card.vhd:223` sets `B_STATE_AXI => true` and
`B_CONST_HBM => true`): `VAL_HEADS=32 DIM=128 RECUR_LANES=4 LAYERS=24
KEY_HEADS=16 KCONV=4 CONV_LANES=4 MANT_BYTES=1048576 EXP_BYTES=4096
CONV_BYTES=49152 LAYER_STRIDE=1101824 MAXB=16 CONST_EN=true
CONST_STRIDE=66048 CONST_BYTES=66048 PIPE=true WIDE=true MAXOUT=8`.
`-flatten_hierarchy none` on all four.

### Why `ctrl` is re-drawn here and not taken from `bmover_ooc_2026-09-20`

TRACK BMOVERSYN's `wp8` is the same configuration and reports **5,425 LUT /
6,509 FF / 28 BRAM / 32 URAM**. This tree's `ctrl` is **5,479 / 6,511 / 28 /
32**: **+54 LUT / +2 FF**, which is what `NWIDE` costs at `NWIDE => false`.
That draw was taken before `748ff91`, which changed four of the seven files
the closure reads, so quoting it as this experiment's control would have
charged those 54 LUT to `NWIDE => true`. Both ends of every comparison in
this document come from HEAD `b0a28b6` (CLAUDE.md: a comparison needs both
ends from one tree, and internal consistency cannot detect staleness).

## Where the delta is (MEASURED, `util_hier_*.rpt`, Total LUTs / FFs / RAMB36 / RAMB18 / URAM)

| instance | ctrl | nw | nwu | d12 |
|---|---|---|---|---|
| `u_mem` (mantissas) | 210 / 2 / - / - / 32 | 210 / 2 / - / - / 32 | 210 / 2 / - / - / 32 | 210 / 2 / - / - / 32 |
| `u_dma` (mantissa mover) | 370 / 397 | 368 / 397 | 368 / 397 | 368 / 397 |
| `u_exp` (`gdn_exp_mem`) | 2,458 / 8, LUTRAM 1,920 | 2,026 / 256, LUTRAM 1,280 | same as nw | same as nw |
| `u_edma` (exp mover) | 546 / 1,141 | **248 / 333** | 248 / 333 | 248 / 333 |
| `u_conv` (`gdn_conv_tap_mem`) | 253 / 8, **12 RAMB36** | 737 / 10, **48 RAMB18** | 737 / 10, **48 URAM** | **1,387** / 10, **12 RAMB36** |
| `u_cdma` (tap mover) | 473 / 1,165 | **290 / 359** | 290 / 359 | 290 / 359 |
| `gconst.u_cw` (`gdn_conv_w_mem`) | 25 / 0, **16 RAMB36** | 410 / 2, **64 RAMB18** | 399 / 2, **64 URAM** | 410 / 2, 64 RAMB18 |
| `gconst.u_kdma` (const mover) | 522 / 647 | **149 / 350** | 149 / 350 | 149 / 350 |

The mechanism is legible in one line per column. **`NWIDE` moves work out of
the three movers and into the memories**: `u_edma` -298 LUT / -808 FF,
`u_cdma` -183 / -806, `u_kdma` -373 / -297, because a mover that hands over a
whole beat per cycle no longer carries the per-word unpack counter and the
256-bit staging register. The memories pay some of it back -- `u_conv` +484
LUT, `u_cw` +385 -- in bank decode and the GS:1 post-register select. Net
**-368 LUT / -1,659 FF.** `u_exp` is a third case: 32-way banking *reduces*
its LUT-as-memory from 1,920 `RAMD64E` to 1,280 (shallower banks) while
adding 248 FF.

## URAM: the log, the census and the RAM report, reconciled

**`[Synth 8-10226]` (URAM request refused): 0 occurrences in all four logs.
`[Synth 8-7186]` (`ram_style` ignored): 0 in all four.** There is nothing to
reconcile against the census, because the census agrees with
`report_utilization` exactly in every arm:

| arm | `report_utilization` URAM / RAMB36 / RAMB18 | census `REF_NAME =~ URAM*` / `RAMB36*` / `RAMB18*` |
|---|---|---|
| ctrl | 32 / 28 / 0 | 32 / 28 / 0 |
| nw | 32 / 0 / 112 | 32 / 0 / 112 |
| nwu | 144 / 0 / 0 | 144 / 0 / 0 |
| d12 | 32 / 12 / 64 | 32 / 12 / 64 |

Census attribution (`census_opt_*.txt`, listed by name):

- **nwu**: `u_mem` 32 URAM288, `u_conv` 48, `gconst.u_cw` 64 = 144.
- **nw**: `u_conv` 48 RAMB18, `gconst.u_cw` 64 RAMB18 = 112 halves = 56 tiles.
- **ctrl**: `u_conv` 12 RAMB36, `gconst.u_cw` 16 RAMB36 = 28 tiles.

`ram_nwu.rpt` names each one: `gconst.u_cw/gwide.gbank[0].m` is
`RAM_SDP 512x16` in `gconst.u_cw/gwide.gbank[0].m_reg_uram_0`, one URAM288
per bank, `Matrix Shape 1x1`. `ram_nw.rpt` has the identical objects as
`..._bram_0`. `ram_d12.rpt` has `u_conv/gwide.gbank[0].m` as `RAM_SDP
512x64` in one `m_reg`, i.e. one RAMB36 per bank.

The messages that DID fire under `ultra` say the request was honoured, not
refused, which is the opposite of the `8-10226` case CLAUDE.md records:

```
WARNING: [Synth 8-5790] Small sized RAM "gdn_conv_tap_mem:/gwide.gbank[0].m_reg"
  will be implemented using URAM because of explicit ram_style = "ultra" attribute.
WARNING: [Synth 8-6057] Memory: "gwide.gbank[23].m_reg" defined in module:
  "\gconst.u_cw " implemented as Ultra-Ram has no pipeline registers.
  It is recommended to use pipeline registers to achieve high performance.
INFO: [Synth 8-7052] The timing for the instance
  gconst.u_cw/gwide.gbank[23].m_reg_uram_0 (implemented as a Ultra RAM) might be
  sub-optimal as no optional output register could be merged into the ram block.
```

**`8-6057` and `8-7052` are the price of the refund and they are timing
cautions, not correctness ones.** The URAM is unpipelined here, exactly as
`u_mem`'s 32 URAM288 already are on the shipping card (`ctrl` carries 8
occurrences of `8-6057`, all naming `u_mem`).

## Timing (ESTIMATE: post-`opt_design`, no placement, no routing)

CLAUDE.md records `phys_opt` over-promising by 0.4 to 0.6 ns on this part,
once inverting a verdict, and a synthesis estimate is worse than that. These
numbers order the four arms against EACH OTHER and say nothing about a routed
card.

| arm | WNS @13.333 | WNS @5.0 | datapath | levels | startpoint | endpoint |
|---|---|---|---|---|---|---|
| ctrl | +10.096 | +1.763 | 3.062 (logic 2.789, route 0.273) | 7 (URAM288=7) | `u_mem/gwide.gb[3].bank_reg_uram_0/CLK` | `u_dma/wfifo_reg_0_3_196_209/RAMF/I` |
| nw | +10.096 | +1.763 | 3.062 | 7 | identical | identical |
| nwu | +10.096 | +1.763 | 3.062 | 7 | identical | identical |
| d12 | +10.139 | +1.806 | 3.062 | 7 | identical | identical |

**In all four arms the worst path is the MANTISSA memory's own URAM read
cascade** -- `cascade_height 8`, so 7 `CAS_IN -> CAS_OUT` hops, about 2.8 ns
of logic -- landing on the mantissa mover's LUTRAM FIFO write data. It is a
property of `u_mem`, which none of these arms touches, and it is why three
arms give the same slack to the digit. `nwu`'s second and third worst paths
are the same family (`gb[1]`, `gb[2]`), so the conv memories in URAM do not
enter the top three: their internal paths are under 3.062 ns, which is a
bound and not a measurement of them.

`d12`'s +0.043 ns is the one real difference and it is small enough to be
draw scatter; the startpoint and endpoint are identical, so it is a routing
estimate on a path neither arm changed.

**WHAT THIS DRAW DOES NOT TIME AT ALL.** `check_timing` on every arm reports
**`no_output_delay (3971)`** and **`no_input_delay (563)`**. Out of context
with no `set_output_delay`, the path from the conv memory's read register to
`cv_x`/`cw_w` and on to `gdn_block` is NOT in any of these numbers. That is
exactly where the unpipelined URAM's slower clock-to-out would show up, so
the URAM arm's timing is bounded here only on its INTERNAL paths. The card is
at 75 MHz (13.333 ns) with 10 ns of estimated slack, which is an argument for
expecting it to hold and not a measurement of it.

## The rejected 12-bank arm (`d12`), built and measured

`gdn_conv_tap_mem.vhd`'s header refuses this option in its own words:

> EVERY WRITE IN THE WIDE ARM IS STILL A WHOLE 16-BIT WORD, and that is the
> whole reason the bank count is `NTAP*CONV_LANES*GS` rather than
> `NTAP*CONV_LANES` with a GS-times-wider word. The wider-word form has the
> same bit count and **the same tile count**, and it makes the UNIT's write a
> sub-word slice at a computed offset -- refusal 1 in the list above, the one
> that MEASURED zero BRAM and 8% of the part on this very file.

The source built to test it is `gdn_conv_tap_mem_d12.vhd`, in this
directory. It is the repository file with only the `gwide` generate replaced:
12 banks of `512 x 64`, bank `(slot, lane)` at depth `d` holding groups
`d*GS .. d*GS+GS-1`.

**The refusal names a variable-offset slice, and this arm does not write
one.** Refusal 1 was `m(a)(off+15 downto off)` with `off` an expression.
Here the sub-group index is DECODED into `GS` static slices, each under its
own enable -- the ordinary byte-write-enable template, which a RAMB does have
a primitive for. MEASURED:

- **12 RAMB36E2, zero LUT-as-memory growth.** Not the 28,160 LUT-as-memory
  blowup the refusal predicts, and **not the "same tile count"** it asserts
  either: 12 tiles against the shipping WIDE arm's 24 for the same store.
- **And it loses anyway: +650 LUT against `nw`** (`u_conv` 737 -> 1,387),
  which is the GS:1 read select and the GS-way write decode now living in
  fabric instead of in the bank index. `nwu` beats it on BRAM (0 against 44),
  on LUT (5,100 against 5,761) and on URAM pressure at equal DSP and FF.

**CAVEAT, and it is why `d12`'s 44 tiles is not a complete option price.**
Only `gdn_conv_tap_mem` was converted -- the file whose header carries the
refusal and the 28,160-LUT measurement. `gdn_conv_w_mem` adopted the same
three-axis scheme and still contributes its 64 RAMB18 (32 tiles) in this arm.
DERIVED, not measured: converting it the same way would take those 32 tiles
to about 16, for a `d12`-complete total near 28 tiles -- `NWIDE` at no net
BRAM cost. That arithmetic is a bank-count-to-primitive mapping observed in
the half that WAS measured, and CLAUDE.md's rule that the parts do not sum
across synthesis contexts applies to it.

### `d12` is functionally verified, and the bench has teeth on the part that changed

MEASURED, `ghdl -r sim/tb_gdn_conv_tap_mem`, at the bench shape
(`CONV_LANES=2`, `WPB=4`, so `GS=2`):

| build | `-gWIDE=true` | `-gWIDE=false` |
|---|---|---|
| repository `gdn_conv_tap_mem.vhd` | PASS 107/107 | PASS 107/107 |
| `gdn_conv_tap_mem_d12.vhd` | **PASS 107/107** | PASS 107/107 |

**The attribution control**, because a green bench across a rewrite means the
bench is insensitive until shown otherwise (CLAUDE.md). Two mutations of the
d12 arm, each removing exactly the sub-word decode that is the whole
difference from the shipping arm:

| mutation | result |
|---|---|
| M1: the UNIT write ignores `(wa_s mod GS) = j` and writes every sub-word | **FAIL, 45 of 107 bad** |
| M2: the NARROW MOVER write ignores `(mwg_s mod GS) = j` | **FAIL, 4 of 107 bad** |

So the PASS is a statement about the sub-word write and not an accident.
**What it does NOT cover:** the bench shape has `GS = 2` and the 9B shape has
`GS = 4`, so the three-of-four-sub-words-untouched case is never exercised;
and the bench does not drive the `ww_*`/`wr_*` beat ports at the store's
`WPB = 16`.

## Against the real placed budget (`hw/fk33/results/card_swg_2026-09-20/bd_wrapper_utilization_placed.rpt`, MEASURED, placed)

```
Block RAM Tile   567 of 672  (84.38%)   105 free    RAMB36E2 540   RAMB18 54
URAM              32 of 320  (10.00%)   288 idle
CLB           54,854 of 54,960 (99.81%)  106 free
LUT          363,095 of 439,680 (82.58%)
```

DERIVED, and CLAUDE.md's rule that the parts do not sum across synthesis
contexts means these are the right order of magnitude and not the card's
exact numbers:

| arm | BRAM tiles | free tiles | URAM | LUT | FF |
|---|---|---|---|---|---|
| card today (= `ctrl`) | 567 (84.38%) | 105 | 32 (10.0%) | 363,095 | 308,981 |
| `+ nw` | **595 (88.54%)** | **77** | 32 | 362,727 | 307,322 |
| `+ nwu` | **539 (80.21%)** | **133** | **144 (45.0%)** | 362,716 | 307,322 |
| `+ d12` (tap only) | 583 (86.76%) | 89 | 32 | 363,377 | 307,322 |

**106 free CLBs is the tightest number on the card, and every arm moves it
the right way**: LUT down 368 to 379 and FF down 1,659, so nothing here adds
CLB pressure. No arm touches DSP (4 in the unit, 2,087 on the card).

## Verdict

**`NWIDE => true` FITS and should go into the next card build together with
`PIPE`, `WIDE` and `MAXOUT 8`.** +28 BRAM tiles against 105 free, -368 LUT,
-1,659 FF, URAM and DSP unchanged, and a synthesis-stage WNS identical to the
control at both 13.333 and 5.0 ns on the same worst path. The change is one
line in `rtl/llama_top.vhd`'s `u_state` generic map, which this track does not
own:

```diff
--- a/rtl/llama_top.vhd
+++ b/rtl/llama_top.vhd
@@ u_state : entity work.gdn_state_store generic map(
                     MAXOUT       => 8,
                     PIPE         => true,
-                    WIDE         => true)
+                    WIDE         => true,
+                    -- TRACK BNARROW 748ff91; area MEASURED by TRACK
+                    -- BNARROWSYN, hw/fk33/results/bnarrow_ooc_2026-09-20:
+                    -- +28 BRAM tiles, -368 LUT, -1,659 FF, URAM/DSP and the
+                    -- synthesis WNS estimate unchanged.  -84,979 cycles a
+                    -- 9B B job in GHDL.
+                    NWIDE        => true)
```

then `python3 tools/gen_cardtop.py` to regenerate `rtl/fk33_llama_top.vhd`
(the card's top, whose `u_state` map at `:5749` is copied from this one and
is checked by the `sim:cardtop` gate row).

**URAM IS THE BETTER HOME AND IT IS A SEPARATE LEVER.** It is not "pay the 28
tiles somewhere cheaper": it takes the unit's Block RAM Tile count to zero,
which is 28 tiles BELOW what the card spends on these two memories today, for
112 of the 288 idle URAM288. It needs three one-line changes in two files
this track does not own, and `rtl/llama_top.vhd`:

```diff
--- a/rtl/gdn_conv_tap_mem.vhd
+++ b/rtl/gdn_conv_tap_mem.vhd
@@ generic(
-    STYLE      : string   := "block"; -- "block" or "auto".  NOT "distributed".
+    STYLE      : string   := "block"; -- "block", "ultra" or "auto".  NOT
+                                      -- "distributed": the unit's read is
+                                      -- registered, which block and ultra do
+                                      -- and distributed does not.
@@ function chk_style
-    if s = "block" or s = "auto" then
+    if s = "block" or s = "auto" or s = "ultra" then

--- a/rtl/gdn_conv_w_mem.vhd
+++ b/rtl/gdn_conv_w_mem.vhd
@@ (the identical two hunks, same line text)

--- a/rtl/llama_top.vhd
+++ b/rtl/llama_top.vhd
@@ u_state : entity work.gdn_state_store generic map(
+                    CONV_STYLE   => "ultra",
                     NWIDE        => true)
```

**Take `NWIDE` now and hold `ultra` until the one open question below is
answered**, because `NWIDE` alone fits with 77 tiles to spare and does not
change any memory's collision semantics, while `ultra` changes the primitive
under an array whose read-during-write behaviour the mapping report declines
to state.

## Open, not determined

- **THE URAM COLLISION SEMANTICS, and it is the reason `ultra` is not an
  unconditional recommendation.** The BRAM mapping report states a write mode
  per port -- `512 x 16(WRITE_FIRST) | W | | 512 x 16(READ_FIRST) | | R` for
  every bank in `nw` and `ctrl`. **The Ultra RAM mapping report has no
  write-mode column at all.** The RTL is read-first by VHDL semantics
  (`rqw(b) <= m(radw)` reads the pre-write value), and the unit can read one
  group while writing another in the same cycle, so a same-address collision
  is reachable in principle. Nothing measured here says what a URAM288 returns
  in that cycle, and neither GHDL nor any OOC synthesis can tell you: GHDL
  simulates the RTL regardless of `ram_style`. **Settle it by reading UG573's
  URAM port-ordering rule and by an instrumented bench that counts collisions
  at the 9B shape, before `CONV_STYLE => "ultra"` goes into a build.**
- **Routed timing on the card.** Everything here is post-`opt_design`. The
  conv memories' output path to `gdn_block` is not timed at all (`no_output_delay
  (3971)`), which is where an unpipelined URAM's clock-to-out would land.
- **The B-job cycle count on silicon.** GHDL says 222,805 per job with
  `NWIDE`; the card is the measurement, and the 2.5% bench-to-card residual
  from TRACK BMOVER is still carried rather than absorbed.
- **`d12` completed.** Only the tap store was converted; `gdn_conv_w_mem`'s
  32 tiles in that arm are unconverted. The option's true price is unmeasured
  and it is dominated by `nwu` on the half that was measured, so completing it
  is pricing a third-place option.
- **`d12` at `GS = 4`.** The bench shape gives `GS = 2`; the 9B shape's
  three-untouched-sub-words case is not covered by the 107 checks.
- **Whether 112 small URAM288 place well.** 45% of the URAM columns holding
  2.8% of their bits each, spread across `u_conv` and `gconst.u_cw`, is a
  placement question no OOC draw can answer.

## Measurement traps hit

- **A VIVADO MESSAGE COUNT OF EXACTLY 100 IS THE MESSAGE LIMIT, NOT A
  CENSUS.** `8-7129`, `8-7030`, `8-7052`, `8-6057` and `8-5790` each report
  exactly 100 in at least one arm, and `8-5790`'s unique object names
  de-duplicate to 50 against a census of 112 URAM banks. The runner's
  `grep -c` of `8-10226` and `8-7186` is still sound because both are ZERO,
  which is below the cap -- but a count near 100 from that line must not be
  read as a quantity. This is the same shape as CLAUDE.md's capped
  `memory.peak`: the number you read is the limiter, not the thing.
- **`REF_NAME =~ DSP*` under `-hier` counts each DSP48E2 NINE times** (the
  macro plus its eight `DSP_*` leaves): every arm reports `dsp=36` and
  `dsp48=4` for the same four DSPs. Recorded by TRACK BMOVERSYN and carried
  forward as a separate `REF_NAME == DSP48E2` census row here.
- **THE d12 SOURCE MUST NOT LIVE IN `sim/`, AND THAT IS NOT TIDINESS.**
  `sim/regress.sh`'s planner globs `('rtl/*.vhd', 'sim/*.vhd',
  'sim/micro/*.vhd', 'tb/*.vhd')` into ONE pool with a single `provider` slot
  per design unit (`sim/regress.sh:1472`). A second `gdn_conv_tap_mem` there
  would silently re-point every gate row that reaches this memory at the
  rejected arm, with no error. It lives in this results directory, which
  nothing globs.
- **The `ctrl` control had to be re-drawn.** Quoting BMOVERSYN's `wp8` would
  have charged `NWIDE => false`'s own +54 LUT / +2 FF to `NWIDE => true`. The
  stale-table failure CLAUDE.md records is the same shape and would have
  passed every arithmetic check.
- **`run_<tag>.log` is block-buffered.** Reading the runner's stdout mid-draw
  showed a draw apparently stalled for four minutes that had in fact finished
  in 63 seconds. The `BNARROW_DONE <tag>` sentinel is line-anchored and the
  per-draw `vivado_<tag>.log` is unbuffered; both were read instead.
- **`d12` alone carries `CRITICAL WARNING: [Power 33-333] The Vccint supply
  current exceeds the maximum limit of the selected package.`** It is a power
  ESTIMATE emitted during `opt_design` on a 12-RAMB36 netlist with no
  placement and no real activity, it appears in no other arm, and it is not a
  design error. It is recorded because a `^ERROR|^CRITICAL WARNING` gate would
  fire on it.

## Files

`result_<tag>.csv` (one row each), `util_<tag>.rpt`, `util_hier_<tag>.rpt`,
`synthutil_*` (pre-`opt_design`), `ram_<tag>.rpt`,
`census_{synth,opt}_<tag>.txt`, `timing_{13p333,5p0}_<tag>.rpt`,
`worst_{13p333,5p0}_<tag>.rpt`, `mem_<tag>.txt`, `cgroup_<tag>.txt`,
`run_<tag>.log` (stdout), `vivado_<tag>.log`, `runner_abc.log` (`ctrl nw
nwu`), `runner_d12.log`, and `gdn_conv_tap_mem_d12.vhd` (the rejected arm's
source, NOT for use, see the trap above).

Reproduce with:

```
BN_OUT_DIR=<scratch> BN_CAP=10G BN_ONLY="ctrl nw nwu d12" \
  bash sim/ooc_bnarrow_run.sh
```
