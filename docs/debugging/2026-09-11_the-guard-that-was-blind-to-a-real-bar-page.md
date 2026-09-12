# The address-map guard was blind to a real BAR page, and its teeth measured nothing

**Date:** 2026-09-11
**Subject:** `sim:runguard` / `check_bar_map` / `parse_address_map` in
`hw/fk33/gen_pcieep.py`, graded against a card-on
`hw/fk33/build_fk33_pcieep.tcl`.

## The question, verbatim

Why does the full gate fail with `SELFTEST FAIL: the address-map guard does
not discriminate as claimed`, and is it a regression from today's work?

## The answer, up front

**Not a regression.** Three separate defects, one symptom. The guard was
correct for the configuration it was written against and went blind **exactly
when the card was introduced**, while a broken attribution arm hid that by
refusing everything.

1. **The needle arm refused everything.** `_ADDR_NEW_NEEDLES` pinned the
   engine-only spelling of the seam's `d_err` wiring. With `FK33_CARD=1` that
   literal does not exist, so `_arm_new` reported a missing needle for EVERY
   row **including the unmutated control**. A0 "refused the shipping address
   map", three legal maps were reported as wrongly refused, and `MAP ALONE=0`
   was an **artifact**: an arm that refuses everything leaves nothing
   attributable to `check_bar_map` alone.
2. **That masked a real blind spot.** With the arm honest, A5 was **accepted
   by everything**. `parse_address_map` skipped every line carrying
   `-target_address_space` on the assumption they are all HBM master views.
   They are not: with the card on, `eng/s_axi/reg0` is assigned at 0x12000
   inside a `foreach sp {jtag_axil/Data xdma/M_AXI_LITE}` loop and carries
   that flag because it is given to two named masters. **A5 is the engine
   control page moved onto the 8 KB scratch, the exact collision the emitted
   file's own comment says cost a `--bd-only` run.**
3. **The tie-off teeth graded the wrong configuration**, producing
   `SELFTEST VOID: the d_err tie anchor occurs 0 times` on a card-on file.

## The procedure

1. **Read the SELFTEST CONFIGURATION line before reading the verdict.** It
   says `FK33_CARD=1, three-cell`, and the selftest grades a file a previous
   invocation wrote. This was already documented in the source and is the
   first thing to check.
2. **Test each needle against the file by hand.** Two present, one MISSING.
   That is the whole of defect 1 and it took one command.
3. **Fix the arm first, then re-read the table.** Defect 2 is INVISIBLE until
   defect 1 is gone, because the broken arm was refusing A5 too.
4. **Dump `parse_address_map`'s rows for the mutant** rather than reasoning
   about why the overlap check "should" fire. Nothing appeared at 0x11000,
   which says the parser never saw the page, not that the check was wrong.
5. **Run the OLD and NEW guard against a REAL engine-only file** from git
   (`1380dbf`), not a synthesised one.

## The evidence

Needle arm, against the card-on file:

```
PRESENT 'assign_bd_address -offset 0x0000E000'
PRESENT 'create_bd_cell -type module -reference fk33_seam fk33_seam_0'
MISSING '[get_bd_pins seam_h1/dout] [get_bd_pins fk33_seam_0/d_err]'
```

The page the parser could not see, and the two assignments that explain why:

```
# in card/a's space, 0x0 range 256          <- an INTERNAL master's view
assign_bd_address -offset 0x00000000 -range 256 \
    -target_address_space [get_bd_addr_spaces card/a] \
    [get_bd_addr_segs {eng/s_axi/reg0}]

# in the HOST masters' spaces, 0x12000      <- the BAR page, previously invisible
foreach sp {jtag_axil/Data xdma/M_AXI_LITE} {
    assign_bd_address -offset 0x00012000 -range 4K \
        -target_address_space [get_bd_addr_spaces $sp] \
        [get_bd_addr_segs {eng/s_axi/reg0}]
}
```

Before and after, same file, same mutation:

```
BEFORE   A0 REFUSED (wrong)   A5 REFUSED by the broken needle arm only   MAP ALONE=0
MIDDLE   A0 accepted          A5 ACCEPTED by everything   <-- the real defect, exposed
AFTER    A0 accepted          A5 REFUSED: "in the BAR address space,
                                fk33_scratch/S_AXI/Mem0 occupies 0x10000..0x11fff
                                and OVERLAPS eng/s_axi/reg0"
         A1-A8 refused, A0/A9/A10/A11 accepted, MAP ALONE=4, NEITHER=0, PASS
```

The control, on the real engine-only file from `1380dbf`:

```
OLD  BAR rows=10  check_bar_map=accepted
NEW  BAR rows=10  check_bar_map=accepted      (identical segment lists)
```

## Measured and REJECTED -- do not retry

- **"It is a regression from today's seam work."** REFUTED. Nothing in this
  session touches the bar map; the needle literal has been engine-only since
  it was written, and the blind spot arrives with the card cell.
- **"`check_bar_map` does not pay for its own maintenance"** (the selftest's
  own conclusion, `MAP ALONE=0`). REFUTED once the arm is honest: `MAP
  ALONE=4`. That verdict was an artifact of the broken control.
- **Filtering assignments by the `-target_address_space` FLAG.** It is not a
  synonym for "HBM". Filter by what the line ADDRESSES.
- **Keying the segment collapse by segment name alone.** One segment may hold
  two legitimate addresses in two different masters' spaces, and
  `eng/s_axi/reg0` genuinely does. Doing this reports normal AXI as a
  contradiction and aborts.

## Measurement traps hit

- **Fixing the broken control made the result look WORSE before better.**
  A5 went from "refused" to "accepted". A reviewer stopping at that point
  would conclude the fix caused a regression, when it removed a false pass.
- **A guard can be blind in one configuration only.** The engine-only file
  reaches the same page through a plain assignment and was always covered, so
  every card-off run was genuinely green. Testing one configuration proves
  nothing about the other.
- I patched twice before getting it right: first admitting all non-HBM
  `-target_address_space` lines (which aborted on the legitimate two-address
  segment), then filtering to host masters (which still failed, because the
  master is the Tcl variable `$sp`).

## Open, not yet answered

- **The selftest is still not hermetic.** It grades whatever file the last
  invocation wrote, so its verdict depends on an environment variable set
  elsewhere. Defects 1 and 3 are both consequences of that. The documented
  right fix is to build its own text per configuration and grade both; this
  change makes the existing test correct for both, which is not the same
  thing.
- `seam_tieoff_teeth()` now reports NOT APPLICABLE on a card-on file. That is
  honest but it means the tie-off guard is ungraded whenever the card is the
  build target, which is currently always.

---

## CORRECTION, appended 2026-09-11 (same day): a fourth defect, and the
## "NOT APPLICABLE" fix above was the wrong one

The section above closes with an open item saying the tie-off guard is now
"ungraded whenever the card is the build target, which is currently always."
Chasing that turned up a **fourth defect, worse than the three above**, and
the NOT APPLICABLE skip has been **replaced**. That part of the write-up is
withdrawn as a fix, though it is accurate as a description of what was wrong.

**`check_seam_tieoff`'s verdict was a property of the caller's shell.** It
took subsystem D's presence from `CARD_ON`, read from `FK33_CARD` at import.
MEASURED on the same card-on file, same bytes:

```
FK33_CARD unset  ->  the SHIPPING file is REFUSED, re-adding the tie is ACCEPTED
FK33_CARD=1      ->  the shipping file is accepted, re-adding the tie is REFUSED
```

Exactly inverted. During generation the environment and the emitted text
always agree, so it never fired there. It bites a checker pointed at a file
some OTHER invocation wrote, which is precisely what the selftest and the
gate do. **The anchor VOID was hiding it**: the teeth died on a missing
engine-only literal before ever calling the guard, so the guard that would
have refused the shipping file was never reached.

Fixed by deriving D's presence from the TEXT as well as `CARD_ON`, and by
grading the card-on invariant rather than skipping it:

```
C0   accepted  the UNMUTATED card-on script (the control)
C1   REFUSED   the tie-off re-added beside a present subsystem D
```

Control, engine-only file from `1380dbf`: OLD and NEW identical under both
`FK33_CARD` unset and `FK33_CARD=1`.

**The reusable lesson, and it is the sharpest one here:** a VOID is not a
neutral outcome. This project's convention is that VOID is not a pass, which
is right, but a VOID also STOPS THE TEST, and everything downstream of it goes
ungraded. Three of the four defects in this file were downstream of a check
that aborted early. **When a selftest reports VOID, ask what it did not get to
run, not only why it stopped.**

Still open: the selftest remains non-hermetic. It grades whatever file the
last invocation wrote, and both the "wrong anchor" and "wrong environment"
defects grow from that root. Making it build its own text per configuration
would remove the class, not just these instances. The generator writes into
the repo and reads `FK33_CARD` at import, so that rework needs a quiet tree.
