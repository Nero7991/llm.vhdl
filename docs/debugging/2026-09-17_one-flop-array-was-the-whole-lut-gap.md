# One flop array was the whole LUT gap: card + A now routes

**Date:** 2026-09-17
**Build:** `hw/fk33/pcieep_build.sh`, `FK33_CARD=1 FK33_CB_STYLE=distributed
FK33_ENG_CORE_MHZ=75`, i.e. subsystems A, B, C, D, host seam, PCIe/HBM shell.

## The question

Oren, verbatim: *"What knobs do we have to get the subsystem A to fit? Because
I'd like to start testing the whole thing instead of omitting A"*.

## The answer

**One line of RTL.** `gen_vstub[2].gv.vproc.buf` was
`variable buf : buf_t(0 to REGMAX-1)` inside a clocked process: 12,288 x 16 =
196,608 bits in FLIP-FLOPS, 39% of the whole design's registers. Making it a
memory took the composed design from **109.15% LUT and a router that gave up**
to **79.06% LUT, routed clean, WNS +0.009 ns at 75 MHz, and a bitstream.**

| | before | after |
|---|---|---|
| post-synthesis CLB LUTs | 479,909 (109.15%) | **347,629 (79.06%)** |
| CLB registers | 500,677 | 310,597 (35.32%) |
| F7 / F8 muxes | ~50,845 / ~18,030 | 25,259 / 5,123 |
| route | gave up, global congestion **level 7** | 0 failed, 0 unrouted, 0 partially routed, 0 node overlaps |
| WNS / WHS at 75 MHz | never reached | **+0.009 / +0.010**, TNS/THS 0.000 |
| bitstream | none | 24,938,098 bytes |

The gap needing to be closed was 19,000-31,000 LUT. This was **132,280**.

## The procedure

1. `report_utilization -hierarchical -hierarchical_depth 6` on the PLACED
   card+A checkpoint. **Subtract the named children from the parent.** That is
   what surfaced `(u)` -- llama_top's OWN logic -- at 101,040 LUT and 202,077
   FF, a bucket bigger than any named subsystem and invisible in every previous
   area table, because every previous table listed BLOCKS.
2. Attribute those flops. **Do not guess.** See the rejected list below.
3. Read Vivado's own `Report RAM Utilization` for the twin array that DID
   infer, and compare the two structurally.
4. Change one thing per synthesis. Four arms, same script, same part.

## The evidence

```
FFO_TOTAL 357286
FFO 196608   vstub[2].gv.vproc.buf     <-- one signal, 39% of the design's FFs
FFO 94061    BLOCK:u_attn
FFO 32604    BLOCK:eal.u_gdn
```

Four card OOC arms, `hw/fk33/ooc_card_dcp.tcl`:

| arm | LUT | FF |
|---|---|---|
| baseline | 292,383 | 357,608 |
| single read site | 292,383 | 357,608 |
| `ram_style="distributed"` alone | 292,383 | 357,608 |
| **streaming magnitude + `ram_style`** | **209,814** | **160,847** |

Vivado's RAM table, after:

```
| gen_vstub[2].gv.vproc.buf_reg  | User Attribute | 16 K x 16 | RAM64M8 x 576 |
| gen_vstub[2].gv.vproc.buf2_reg | Implied        | 16 K x 16 | RAM64M8 x 576 |
```

## What actually blocked the inference

`buf`'s twin `buf2` -- same process, same write index, same read index -- was
ALREADY distributed RAM. The difference was a
`for i in 0 to REGMAX-1 loop ... buf(i) ...`: a **12,288-wide COMBINATIONAL
read of the entire array in one cycle**, the NORM_ANCHOR magnitude probe. It is
STATICALLY DEAD in the shipping arm (the card sets `NORM_REAL=true`, so only
the V_SWG arm generates) and it blocked inference anyway.

The probe now folds max and min AS THE VECTOR STREAMS, which is what the
block's own comment already said a real unit does. **Exact, not approximate:**
`max |x_i - m| = max(max_x - m, m - min_x)` for any constant `m`, with the same
truncation of `acc / n`. It could not simply be deleted: `NORM_ANCHOR` defaults
TRUE in `sim/tb_llama_top.vhd`.

## Measured and REJECTED -- do not retry

- **Hoisting the read to a single site.** `buf` had four textual read sites,
  `buf2` one, and this project has a recorded `region_mem` threshold (3 read
  sites refused, 2 accepted). Reducing to two changed **not one LUT and not one
  FF**. The threshold does not carry over.
- **`ram_style = "distributed"` on its own.** Also nothing. **The tell: NO
  `[Synth 8-6849] Infeasible attribute` message ever named `buf`.** Vivado was
  not refusing the request -- it never treated the array as a RAM candidate at
  all. *A request nothing reads is silence, not a refusal*, and the two look
  identical unless you grep for the refusal by name.
- **Guessing which signals held the flops.** `qg_buf`, `kin_buf`, `vin_buf`,
  `qkv_b`, `bet_b`, `alp_b`, `x_buf`, `res_buf`: **FF=0 on every row.** They are
  already memories. One Vivado run, ten rows of zero, no information. Derive
  owners from the netlist instead.
- **"DSP is 80% idle, trade LUTs for DSPs."** Read off the A-less build. With A
  present DSP is **2,121 of 2,880 (73.65%)**, so ~760 spare, not ~2,300.

## Measurement traps hit

- **A hand census's `REF_NAME =~ RAM*` counts BLOCK RAMs too, and counts
  PRIMITIVES rather than LUT SITES.** It reported `eng` LUTRAM 35,754 where the
  hierarchy report says 16,728. Use `report_utilization -hierarchical` for
  totals; a hand census is for ATTRIBUTION only.
- **`CARDOOC_AREA`'s `lut` counts `LUT*` primitives, so the 576 new `RAM64M8`
  cells are invisible to it** while occupying LUT sites. The OOC delta
  (-82,569) and the composed delta (-132,280) are NOT the same measurement, and
  the composed one is larger because collapsing the array also took the mux
  tree (F7 -25,586, F8 -12,907). **Do not project one from the other.**
- **Per-row bench CHECK COUNTS are load-dependent noise.** MEASURED by
  re-running each version unchanged: `normw` 73 vs 89, `bstate_seq` 380 vs 391,
  `seq` 300 vs 311, with the high samples from the run that overlapped a Vivado
  synthesis. A changed count is not evidence. The VERDICT and the landmark are.
- **`systemd-run --user` does not source Vivado's settings**, so the first
  census died instantly with `vivado: command not found` -- and the monitor
  filtered for `^ERROR|Killed|out of memory`, none of which match, so an hour
  passed looking exactly like a running job. **A watcher must report the unit's
  EXIT, whatever the reason.**
- **I edited the RTL for a mutation test while a synthesis was reading the same
  file.** That run was killed and redone rather than trusted.

## Verification

- **8/8 `llama_top` rows PASS**, landmark `R_X(0) = -16364 hash(R_X) = 91622`
  IDENTICAL across every arm.
- **TEETH:** the mutant `bq := buf(0)` instead of `buf(k)` is **KILLED** by
  `sim:tb_llama_top_real`. The green rows discriminate this code.
- **ATTRIBUTION, stated rather than assumed:** the rewrite is NECESSARY (the
  attribute alone did nothing). Whether it is SUFFICIENT without the attribute
  is **UNTESTED** -- the RAM table tags `buf_reg` "User Attribute".

## Open, not yet answered

- **The bitstream has NOT been on the card.** Programming needs a human.
- **A routed bitstream is not a working accelerator.** Whether subsystem A
  computes correctly in hardware is untested. `ga_desc` still has NO value
  coverage, and the `x_exp` divergence between the two A arms is unexplained.
- **`buf2` is still `Implied` LUTRAM and `buf` is now `User Attribute` LUTRAM**
  -- 1,152 `RAM64M8` between them. BRAM is at 66.89% and URAM at 10%, so
  moving either to block RAM or URAM is available if more LUTs are ever needed.
- The same question has not been asked of the OTHER subsystems: `u_arr` is
  still 50,523 LUT and `u_kv` 23,101 with zero LUTRAM.
