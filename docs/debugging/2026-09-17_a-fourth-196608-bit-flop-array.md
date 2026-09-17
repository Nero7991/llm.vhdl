# A FOURTH 196,608-bit process variable, and it owns 39% of the design's flops

**Date:** 2026-09-17
**Design:** card + subsystem A, placed (`spread/placed.dcp`), 414,793 LUT (94.3%)
**Symptom:** the card with A synthesises at 109.15% LUT and the router gives up
at global congestion level 7. Reaching a routable ~90% needs 19,000-31,000 LUT
removed and every published lever is spent.

## The question

Asked by Oren, verbatim: *"What knobs do we have to get the subsystem A to fit?
Because I'd like to start testing the whole thing instead of omitting A"*.

## The answer

**`vstub[2].gv.vproc.buf` is a `variable buf : buf_t(0 to REGMAX-1)` inside a
clocked process -- 12,288 x 16 = 196,608 bits held in FLIP-FLOPS. It owns
196,608 of the design's 500,677 registers (39%), and 196,608 of the 202,077
that sit in llama_top's own logic (97%).** It is 1W/1R (written at `buf(k-2)`,
read at `buf(i)`), which is the exact shape already moved to block RAM three
times in this project.

The FF saving is EXACT and MEASURED: 196,608. **The LUT saving is UNKNOWN and
must be measured, not projected.** What is known is that llama_top's own logic
holds 89,584 logic LUTs, 28,629 MUXF7 and 14,256 MUXF8 that no named subsystem
owns, and that this array is the dominant structure there.

`docs/WORKLOG.md` says "All three 196,608-bit process variables are gone".
That is true of the three it names. This is a fourth, in `gen_vstub`, and only
ONE generate arm kept it -- the others were optimised away, which is why it
never showed up in a per-block area table.

## The procedure

1. `report_utilization -hierarchical -hierarchical_depth 6` on the PLACED
   checkpoint. Gives Total/Logic/LUTRAM/FF/DSP per instance. This is the
   authoritative view; see the trap below for what happens without it.
2. Subtract the named children from the parent to get the parent's OWN logic.
   That is what surfaced `(u)` at 101,040 LUT / 202,077 FF -- a bucket larger
   than any named subsystem and invisible in every previous area table, because
   every previous table listed the blocks.
3. A GUESSED list of suspect signals. **This failed and is worth recording:**
   `qg_buf`, `kin_buf`, `vin_buf`, `qkv_b`, `bet_b`, `alp_b`, `x_buf`,
   `res_buf` all returned **FF=0**. They are already memories. Ten rows of
   zero, one Vivado run, no information.
4. DERIVE the owners from the netlist instead: aggregate every `FD*` cell under
   `card/inst/u` by the signal its name carries. One answer, first try.

## The evidence

```
FFO_TOTAL 357286
FFO 196608   vstub[2].gv.vproc.buf     <-- one signal, 39% of the design's FFs
FFO 94061    BLOCK:u_attn
FFO 32604    BLOCK:eal.u_gdn
FFO 20549    BLOCK:gkvaxi.u_kv
FFO 2856     BLOCK:es
FFO 2048     eal.bp.zstg
FFO 2048     eal.z_mant
```

Hierarchy, placed card+A (Total LUT / Logic / LUTRAM / FF / DSP):

| instance | TotLUT | Logic | LUTRAM | FF | DSP |
|---|---|---|---|---|---|
| `(u)` llama_top's OWN logic | 101,040 | 89,584 | 11,456 | 202,077 | 51 |
| `gcr.u_attn` | 84,586 | 84,481 | 76 | 94,061 | 298 |
| `u_arr` (inside it) | 50,523 | 50,523 | 0 | 39,322 | 256 |
| `eng` | 89,640 | 72,498 | 16,728 | 76,923 | 1,585 |
| `gb_real.u_gdn` | 53,896 | 43,869 | 9,826 | 32,604 | 141 |
| `gcr.gkvaxi.u_kv` | 23,101 | 23,101 | 0 | 20,549 | 3 |
| top | 414,793 | 366,590 | 47,106 | 500,677 | 2,121 |

The RTL, `rtl/llama_top.vhd:1772`:

```vhdl
vproc : process(clk) is
  variable buf  : buf_t(0 to REGMAX-1);
  variable buf2 : buf_t(0 to REGMAX-1);
```

with `REGMAX : positive := region_max(SHAPE)` = 12,288 and `MANT_W` = 16.
`buf2` does not appear in the census: it is written in one branch and never
read in the surviving arm, so it was optimised away.

## Measured and REJECTED -- do not retry

- **The guessed-signal census.** `qg_buf` and seven others: FF=0 on every row.
  They are already memories. Derive owners from the netlist.
- **"DSP is 80% idle, trade LUTs for DSPs."** That was read off the
  subsystem-A-less build. **With A present DSP is 2,121 of 2,880 = 73.6%**, so
  there are ~760 spare, not ~2,300. The knob is a third of the size it looked.
- **Implementation directives.** `ExploreWithRemap`, `AltSpreadLogic_high` and
  congestion-directed placement all reach the IDENTICAL congestion level 7.
- **`CB_STYLE=distributed`, `desc_ram` to BRAM, 200 -> 75 MHz.** All already
  applied in the failing build. No saving remains in them.

## Measurement traps hit

- **`REF_NAME =~ RAM*` COUNTS BLOCK RAMS TOO.** My first census labelled that
  column "LUTRAM" and reported 35,754 for `eng` and 39,083 for `card`. The
  hierarchy report says 16,728 and 23,278. Two separate errors in one column:
  it includes `RAMB36E2`/`RAMB18E2`, and a PRIMITIVE count is not a LUT count
  (one `RAM32M16` is one primitive and several LUT sites). **Use
  `report_utilization -hierarchical`'s columns; a hand census is for ATTRIBUTION,
  not for totals.**
- **`systemd-run --user` does not source Vivado's settings.** The first census
  died instantly with `vivado: command not found`, and the monitor watching it
  filtered for `^ERROR|Killed|out of memory` -- none of which match -- so an
  hour of wall time passed looking exactly like a running job. **A monitor must
  report the unit's EXIT, whatever the reason, not only patterns guessed in
  advance.**
- Two placements of the SAME design report 414,793 and 426,882 LUT. Quote the
  run, and derive the gap from the run you are comparing against.

## Open, not yet answered

- **What the conversion is actually worth in LUTs.** Unknown. The honest next
  step is to do it and re-synthesise the card OOC (745 s, measured) and compare
  LUT, MUXF7 and MUXF8 -- not to scale anything from the FF count.
- Whether BRAM or URAM is the right target. 196,608 bits is ~6 RAMB36 or 1
  URAM288; BRAM is at 424/672 with A present, URAM at 32/320.
- The read is `buf(i)` inside the same cycle it is used, so a BRAM's 1-cycle
  read latency needs the state machine adjusted. That is exactly what the
  `ybs` and `ybw` conversions had to do, and both have benches that killed
  index mutants.
