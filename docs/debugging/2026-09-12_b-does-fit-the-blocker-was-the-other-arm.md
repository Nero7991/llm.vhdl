# B's 5,472-BRAM blocker is the arm the card does not build

**Date:** 2026-09-12
**Subject:** `sim/ooc_gdnadapt.tcl` / `rtl/ooc_gdnadapt_top.vhd`, subsystem B's
data mover, BC-250, `xcvu33p-fsvh2104-2L-e`.

## The question, verbatim

Is "B does not fit" -- 5,472 RAMB36 against 672 on the part -- a property of
the design the card builds?

## The answer, up front

**No.** That figure comes from `B_STATE_AXI = false`, and
`hw/fk33/rtl/fk33_card.vhd` passes **true**. The generic selects between two
mutually exclusive generates:

```
gen_st_flat : if not B_STATE_AXI generate   -- flat all-layers state array
gen_st_tier : if     B_STATE_AXI generate   -- state over AXI to HBM
```

One variable, both arms `GDNADAPT_MAXROWS=2048`, both 0 errors:

| `B_STATE_AXI` | LUT | FF | BRAM | URAM | DSP |
|---|---|---|---|---|---|
| false (every prior B figure) | 148,995 | 77,973 | **5,472** | 0 | 191 |
| **true (the card)** | 85,255 | 69,783 | **50** | **32** | 194 |

**50 of 672 BRAM and 32 of 320 URAM288. B fits, with room.**

## The procedure

1. **Audit harness generic defaults against WHAT THE CARD PASSES**, not
   against `llama_top`. The two questions differ: a harness and `llama_top`
   can agree on a default that the card overrides.
2. Read what the differing generic GATES, in the RTL, not in prose. Here it
   selects between two generates, which is the strongest possible form of
   "this changes what gets built".
3. Run both arms with every other generic held equal.
4. **Check the control reproduces the known number.** It did, exactly: 5,472.
   Without that the treatment arm proves nothing.
5. Look for an independent corroboration of the treatment arm. The recorded
   standalone `gdn_state_store` figure is **32 URAM288**, and 32 URAM288
   appears only on the tiered arm, because `gen_st_tier` instantiates it.

## Measured and REJECTED -- do not retry

- **"B does not fit."** Not established. It rests on the flat arm.
- **"The harness is broken at HEAD."** WRONG, and it was mine.
  `rtl/ooc_gdnadapt_top.vhd:69-79` documents that synthesis at the **9B**
  shape fails because `zb`/`yb` are process VARIABLES of `buf_t(0 to
  A_MAXROWS-1)` = 12,288 x 16 bits each, and `MAXROWS_OVR` is the provided
  control. 196,608 bits is exactly 12,288 x 16.
- **"`C_MAXPOS=131072` causes the failure."** Refuted: `maxpos=4` fails
  identically.
- **"The harness and the card disagree about `zb_reg`."** Built on the above.

## Measurement traps hit

- **Ruling out one cause promotes nothing.** A control run of the pre-edit
  script correctly showed my edit was innocent, and I converted "not my edit"
  into "already broken" without reading the header that names the error
  verbatim. This project has recorded that exact error shape before, about a
  BRAM attribution, and it recurred here.
- **I varied TWO generics at once** (`B_STATE_AXI` and `C_MAXPOS`) on the
  first attempt, which made the wrong diagnosis look plausible.
- **The 9B default is the failing configuration**, so the natural "just run it
  with defaults" is the one case that cannot work.

## What this changes

**Both subsystems believed to be area blockers were measured in
configurations the card does not build.** C measured 74% of the part with
`C_KV_RBUF=64` at a 4-position context; at the card's shape it is 112,519 LUT,
25.6%, with the area in the MAC array. B measured 5,472 BRAM on the flat arm;
on the card's arm it is 50.

This is the seventh instance in two days of the same shape: **a generic whose
default is the simulation value, so leaving it alone looks conservative and is
wrong for the card** (`C_REAL`, `C_KV_BLOCK`, `C_N_ROT`, `NORM_W_IMAGE`, the C
harness trio, `B_STATE_AXI`).

## Open, not yet answered

- **9B magnitudes for B.** `maxrows=2048` here; the 9B shape cannot be
  synthesised in this harness at all. The BRAM result should carry because the
  flat array is sized by LAYERS (`NLY*STLY`) not `MAXROWS` -- that is
  reasoning, not measurement.
- Whether the composed design fits. Only a composed synthesis answers it.
- `zb`/`yb` as process variables is a real synthesis limitation of the
  EXTRACTED block. The card path elaborates B cleanly (`cardooc`: 0 errors, no
  `zb_reg` mention), so it constrains the harness, not the card.
