# Can the flat whole-vector ports become memory, and is that enough for B+C+D to fit?

**Date:** 2026-08-29
**Track:** LUTDIET
**Tree:** pinned `git archive 01a9e95e28fa0f0fd05b5aa7d09da8feb932ff08`, extracted
to `/mnt/storage/lutdiet/src` and synthesised from a copy of it. `01a9e95` is
TRACK COMPOSE's own landing commit, so everything here is at or after the result
it extends.
**Tools:** Vivado 2023.2 (Build 4029153), `xcvu33p-fsvh2104-2L-e`, 5.0 ns,
`synth_design -mode out_of_context -flatten_hierarchy none`, plus `opt_design`
where noted. GHDL (mcode) for equivalence and mutation.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `program_hw_devices`,
nothing under `hw/fk33/host` or `hw/fk33/tcl`, nothing opening `/dev/xdma*`.
**Artefacts:** `hw/fk33/results/lutdiet_2026-08-29/` (772 KB, see its `README.md`)
**Scripts:** `sim/ooc_lutdiet_ports.tcl`, `sim/ooc_lutdiet_run.sh`, and
`mkmem.py` / `mkhotw.py` / `project.py` / `shares.py` / `run_equiv.sh` /
`run_mutants.sh` in the artefact directory.

---

## 1. The question, verbatim

> TRACK COMPOSE landed [...] **82.3% of B's LUT (360,661 of 438,328) is
> `gdn_block`'s own glue** [...] The same signature appears standalone in
> `rmsnorm_rs` at N=4096 [...] Common cause is a **flat whole-vector port
> (65,536 bits) selected `LANES` at a time.** [...] **The design is 2.9x over on
> the resource it spends to avoid the two it barely touches: 0 of 320 URAM, 54
> of 672 BRAM.**
>
> That last sentence is the whole opportunity. Your job: **establish whether the
> flat whole-vector ports can become memory, and what that buys.**
>
> 1. **Confirm the mechanism.** [...] 2. **Measure what a memory-backed port
> costs and saves**, on at least one real case, by synthesising it. [...] State
> the cycle-count cost honestly [...] 3. **Say whether it is enough.** B+C+D need
> to lose roughly 500K LUT to fit the pblock. [...] **If it cannot, say so
> plainly with the numbers.** 4. Do NOT redesign the subsystems.

---

## 2. The answer, up front

**Yes, and by a wide margin -- but the cheapest fix is not the memory, and the
mechanism as COMPOSE described it points at the wrong fifth of the problem.**

Three measured results, then the projection.

**(a) The mechanism is confirmed, and refined.** `rmsnorm_rs`'s LUT count scales
with the flat port's width and with nothing else: at `LANES=4`, holding the
arithmetic, the pipeline and the DSP count fixed, it is 13,365 LUT at N=256,
43,548 at N=1,024 and 169,746 at N=4,096 -- about **41 CLB LUT per vector
element**, with DSP unchanged at 40 across a 16x change in N. **But the mux tree
COMPOSE named is 17.5% of it. 80.5% is the variable-index WRITE into the flat
register, and that structure uses no MUXF7 and no MUXF8 at all.** Anyone hunting
this cost by its F7/F8 signature finds one fifth of it.

**(b) A memory-backed port is a 98.4% LUT saving for 6 BRAM tiles, and it is
bit-exact.** MEASURED at the same interface, N=4096, LANES=4:

| | CLB LUT | CLB FF | BRAM tile | URAM | DSP | WNS at 5.0 ns |
|---|---:|---:|---:|---:|---:|---:|
| flat vectors + `rmsnorm_rs` | **299,030** | 198,472 | 0 | 0 | 40 | +1.675 |
| banked BRAM + `rmsnorm_rs_mem` | **4,798** | 1,700 | **6** | 0 | 40 | +0.971 |

**-294,232 LUT, -196,772 FF, +6 BRAM tiles**, and the compute schedule is
unchanged: the three element passes still run `3N/LANES` beats, because a block
RAM's output register substitutes exactly into the fetch register the RTL
already had. **The total cycle cost is +3 cycles on a 3,072-beat operation,
0.10%.** It gives up 0.70 ns of timing slack and still meets 200 MHz.

**(c) THE HEADLINE: 76% of it is available with no memory, no interface change
and no timing cost at all.** `rmsnorm_rs_hotw` keeps the flat register and the
original port list byte for byte and changes only how the write is decoded --
a per-word generate with a constant index instead of a slice assignment with a
runtime base. MEASURED: **169,746 -> 40,804 CLB LUT, -128,942, -76.0%**, at
**identical ports, identical FF (67,267 vs 67,320), identical WNS (+1.675), and
zero BRAM.** The write-decode root went from 162,276 LUT primitives to 1,052.
Both variants are GHDL-verified bit-exact against the original, over six input
classes, with a three-mutant teeth-check.

**(d) Is it enough? Yes, and the cheap lever alone is enough.** ESTIMATE, with
the shares MEASURED from the censuses and the efficiencies MEASURED on the one
converted case:

| | B | C | D | total | vs 268,222 free (device) | vs 233,765 free (`pb_core`) |
|---|---:|---:|---:|---:|---|---|
| today, MEASURED | 438,328 | 157,560 | 176,360 | **772,248** | 2.88x OVER | 3.30x OVER |
| write-decode fix only | 90,640 | 72,831 | 47,418 | **210,890** | FITS, +57,331 | **FITS, +22,874** |
| write fix + memory | 55,751 | 68,257 | 11,412 | **135,421** | FITS, +132,800 | FITS, +98,343 |

**DERIVED break-even: the conversion must recover 70.7% of the flat-storage cost
to fit the device and 77.9% to fit `pb_core`. The one case measured recovered
98.4% with memory and 99.4% of the write decode without it.** The margin between
what is needed and what was measured is not a rounding error.

**What this does NOT establish.** Nothing here is placed, routed, or composed;
the B and C rows above are projections from a coefficient measured on a
different module, and section 9 says why B's are the less credible of the two.
The measurement is that ONE unit went from 299,030 LUT to 4,798, or to 40,804
without touching its ports. The projection is that B and C behave the same way.

---

## 3. Corrections to the brief, and to COMPOSE

| claim | verdict |
|---|---|
| routed A leaves 268,222 LUT / 1,295 DSP / 410.5 BRAM / 320 URAM free on the device | **CONFIRMED** independently, recomputed by `project.py` from `build_e2e_2026-08-29/e2e_util_routed.rpt` |
| `pb_core` leaves 233,765 LUT free | **CONFIRMED**, `e2e_pblock_util_routed.rpt`, 388,800 - 155,035. It also leaves **351 BRAM tiles** and **320 URAM** |
| B+C+D = 771,900 LUT, 2.88x / 3.30x over | **CONFIRMED**; re-measured here as 772,248 with every row taken again at `-flatten_hierarchy none` |
| `rmsnorm_rs` N=4096 = 169,746 LUT / 40 DSP / 0 BRAM / F7 17,408 / F8 8,704 / WNS +1.675 | **CONFIRMED BIT-IDENTICALLY** in an independently written script |
| `gdn_block` = 438,328 LUT / 253 DSP / 43 BRAM / F7 29,025 / F8 9,231 / WNS +0.483 at `-flatten_hierarchy none` | **CONFIRMED BIT-IDENTICALLY** |
| `attn_block` misses 200 MHz by 3.111 ns (123.3 MHz) while `gdn_block` meets it at +0.483 | **CONFIRMED**, both, to the picosecond |
| `l2norm_rs` N=128 LANES=4 standalone is 14,920 LUT | **CONFIRMED**, 14,931 here, 11 LUT apart (0.07%). This is the attribution COMPOSE had to correct, and the control still holds |
| "B+C+D need to lose roughly 500K LUT to fit the pblock" | **CORRECTED, and the brief is the optimistic one.** 503,678 is the DEVICE figure. `pb_core` needs **538,135** |
| the mechanism is a flat port paying "a mux tree that scales with vector length", evidenced by F7/F8 = 17,408 / 8,704 | **HALF RIGHT, and the wrong half is the big one.** The flat port is the mechanism -- confirmed. But the mux tree is **17.5%** of the LUTs; **80.5% is the variable-index WRITE**, which uses zero F7 and zero F8. See 5.3 |
| the fix is to use the untouched BRAM and URAM | **TRUE BUT NOT NECESSARY FOR MOST OF IT.** 76% of `rmsnorm_rs`'s LUT comes off with no memory at all. See 6.5 |

**One correction that changes what to search for.** Because the dominant
structure carries no MUXF7 or MUXF8, F7/F8 is a lower-bound indicator and not a
measure. The reliable tell for a flat whole-vector port is **a large FF count
with zero BRAM and zero URAM in the same module**: `rmsnorm_rs` at N=4096 is
67,320 FF / 0 BRAM, `gdn_block`'s glue is 203,899 FF / 0 BRAM. That pair is
greppable across the tree; the F7/F8 pair is not.

---

## 4. The procedure, and what each step isolates

1. **Pin the tree at a sha and say which.** `git archive 01a9e95` onto
   `/mnt/storage`. HEAD moved ~35 times today.
2. **Re-derive the baselines from the routed artefacts, not from the brief.**
   Every "free" figure in section 3 is recomputed by `project.py`.
3. **Sweep N with everything else fixed.** N = 256, 1024, 4096 at `LANES=4`.
   The arithmetic, the pipeline depth, the state machine and the DSP count are
   identical at all three points, so anything that moves is a function of the
   PORT WIDTH and of nothing else.
4. **Census the netlist by cell name, not by hierarchy.**
   `report_utilization -hierarchical` cannot see inside a module's own glue,
   which is exactly where COMPOSE localised the problem. Vivado names an
   inferred cell after the RTL signal it drives, so tallying primitives by that
   root attributes area to a SIGNAL. Every run carries `-flatten_hierarchy none`.
5. **Cross-check against a standalone control.** `l2norm_rs` at `N=128 LANES=4`
   re-run alone, because that is the one attribution COMPOSE had to correct.
6. **Build the fix as a MECHANICAL transform, not a rewrite.** `mkmem.py` and
   `mkhotw.py` apply a fixed list of substitutions and abort if any one fires
   the wrong number of times. The diff is the measurement's definition.
7. **Prove bit-exactness before believing the area number.** `run_equiv.sh`,
   both units side by side in GHDL, six input classes including both saturating
   rails, element for element and on `o_exp`.
8. **Teeth-check the bench.** `run_mutants.sh` breaks the banked addressing
   three ways and requires all three to be caught.
9. **Compare at the SAME INTERFACE.** A memory-backed unit holds the vector; the
   flat unit does not, its parent does. `lutdiet_rms_flat` gives the flat unit
   the identical streaming port list by doing what `rtl/llama_top.vhd`'s D-vec
   norm adapter already does -- one word per cycle in at `:2024`, one word per
   cycle out in `S_WR` -- so the control is the shipping data path.
10. **Separate the two candidate causes.** `rmsnorm_rs_hotw` keeps the flat
    register and the original ports and changes only the write decode. If the
    cost is Vivado's variable-index slice inference rather than the flops, this
    finds it and no interface has to move. It was.
11. **One Vivado at a time**, peak RSS over the full descendant tree, and an
    explicit `LUTDIET_DONE` sentinel the runner exits 9 without. It fired once.

---

## 5. The mechanism, confirmed -- and the part of COMPOSE's description that is wrong

### 5.1 The control reproduces COMPOSE exactly

`result_rms_n4096.csv`, verbatim:

    rmsnorm_rs,"N=4096 LANES=4",40,169746,169746,0,67320,0,0,0,0,252,17408,8704,1.675,300.7518796992481,570,-1,169746,67320,40,0
    columns: target,gen,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,
             carry8,f7,f8,wns_ns,fmax_mhz,synth_s,opt_s,synth_lut,synth_ff,synth_dsp,synth_bram

`result_gdn_none.csv`, verbatim:

    gdn_block,"",253,438328,434229,4099,248972,36,14,43,0,2913,29025,9231,0.483,221.3858755811379,406,-1,...

**169,746 / 67,320 / 40 DSP / 17,408 F7 / 8,704 F8 / WNS +1.675** and
**438,328 / 253 DSP / 43 BRAM / 29,025 F7 / 9,231 F8 / WNS +0.483** are
bit-identical to COMPOSE's sections 10.1 and 10.2b. The flows agree, so
everything below is comparable to COMPOSE's numbers without adjustment.

### 5.2 It scales with the PORT WIDTH and with nothing else

| N | LUT | FF | F7 | F8 | DSP | CARRY8 | LUT/element | FF/element |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 13,365 | 5,874 | 1,024 | 512 | 40 | 250 | 52.2 | 22.9 |
| 1,024 | 43,548 | 18,124 | 4,352 | 2,176 | 40 | 252 | 42.5 | 17.7 |
| 4,096 | **169,746** | 67,320 | 17,408 | 8,704 | 40 | 252 | **41.4** | 16.4 |

**DERIVED: a flat whole-vector port costs about 41 CLB LUT per vector element**
at `LANES=4`, asymptotically. **DSP does not move by one across a 16x change in
vector length and CARRY8 moves by two: none of the growth is arithmetic.**
FF/element converges on 16, exactly the mantissa width -- the flops are the
vector and nothing else.

### 5.3 What the LUTs actually ARE, and this corrects the brief

`census_rms_n4096.txt`, top rows verbatim:

    root                                     LUT   MUXF7   MUXF8       FF  CARRY8  example_cell
    o                                     162276       0       0        0       0  o_reg[10062]_i_3
    ARG                                    22281   10880    5440        0      11  ARG__23_i_55
    sq                                     13107    6528    3264        0       0  sq_reg[1]_i_19
    max_raw                                 1046       0       0       63      56  max_raw[15]_i_11
    rq_shifted                               506       0       0       64       2  rq_shifted[63]_i_1
    shifted_r                                405       0       0       64       0  shifted_r[0]_i_2
    # LUT primitives accounted: 201651 of 201651

Read back to the RTL:

- **`o` is `o_reg`, the flat OUTPUT register, and its variable-index WRITE.**
  `rtl/rmsnorm_rs.vhd`'s emit stage does
  `o_reg((base+k+1)*16-1 downto (base+k)*16) <= ...` with `base := idx3 * LANES`
  -- a runtime variable. **162,276 of 201,651 LUT primitives, 80.5%.**
- **`ARG` is the read of `x_mant` and `w_mant`** in the `S_RAW`/`S_EMIT` fetch
  stage (`ARG__nn` is Vivado's name for the sliced expression). 22,281.
- **`sq` is the read of `x_mant`** in the `S_ACC` fetch stage. 13,107.
- Everything else -- the rsqrt, the Newton iteration, the priority encoders, the
  saturation, the whole state machine -- is **3,987 LUT, 2.0%**.

`ARG` + `sq` = 35,388 LUT and **all 17,408 F7 and all 8,704 F8**. Those are the
read mux trees, exactly where COMPOSE's signature pointed.

**But they are the MINORITY.** COMPOSE described the mechanism as "a mux tree
that scales with vector length" and cited F7/F8 as "an exact 2:1 mux tree". That
is right about what the F7/F8 are and wrong about where the area is. **The read
mux is 17.5%. The write DEMUX is 80.5% and consumes no F7 or F8 at all.**

An independent check on the mux model: the flat wrapper's output read is a
4096:1 mux of 16 bits, and a hand count of a 16:1-per-MUXF8 tree gives
16 x 273 = 4,368 F8, 16 x 546 = 8,736 F7 and 16 x 1,092 = 17,472 LUT.
`census_flat_n4096.txt` reports `ord` at **17,472 LUT, 8,736 F7, 4,368 F8**.
Exact, on all three.

### 5.4 The same structure in B, attributed to signals

`census_gdn_none.txt`, `-flatten_hierarchy none`, top rows:

    qsb                                   147456       0       0    32768       0  qsb[0]_i_3
    knb                                   131072       0       0    32768       0  knb[0]_i_4
    vbuf                                  100912       0       0    65536       0  vbuf[10000]_i_1
    kbuf                                   34841       0       0    32768       0  kbuf[32767]_i_7
    qbuf                                   33280       0       0    32768       0  qbuf[0]_i_1
    l2_x                                   18433    8192       0     2048       0  l2_x[2047]_i_1
    rp_cvj                                 17473    8736    4368       16       0  rp_cvj[15]_i_1
    q                                       8354       0       0        0       0  u_l2/q_reg[1999]_i_46
    rp_qs                                   8193    4096    2048     2048       0  rp_qs[2047]_i_1
    rp_kn                                   8192    4096    2048     2048       0  rp_kn[0]_i_4
    # LUT primitives accounted: 585430 of 585430

Every one of the top five is a flat staging register declared at
`rtl/gdn_block.vhd:374-378`, written with a variable base, and the next four are
the variable-index reads off them. `SHARES.txt` sums them with each root traced
to its RTL line:

| | LUT primitives | share |
|---|---:|---:|
| **B** flat storage + variable-index access | **519,342** | **88.7%** of 585,430 |
| of which the WRITE demux | 467,051 | 79.8% |
| of which the READ mux | 52,291 | 8.9% |
| **C** flat storage + variable-index access | **97,297** | **57.6%** of 168,880 |
| of which the WRITE demux | 91,396 | 54.1% |
| of which the READ mux | 5,901 | 3.5% |

**Two independent cross-checks that this is the same structure.** The FF in B's
flat roots is 202,768, against COMPOSE's independently measured glue FF of
203,899 -- 0.6% apart. And `rp_cvj`, the 4096:1 read off `vbuf`, is 17,473 LUT /
8,736 F7 / 4,368 F8, within one LUT of the flat wrapper's `ord` and of the hand
count in 5.3, on a different module.

---

## 6. What a memory-backed port costs and saves -- measured on the real case

### 6.1 What was built, and how

`rmsnorm_rs_mem` is `rtl/rmsnorm_rs.vhd` with **one change**: the three flat
whole-vector ports (3 x 65,536 bits at N=4096) become word streams into and out
of `LANES`-way banked block RAM held inside the unit. Word `i` lives in bank
`i mod LANES` at offset `i / LANES`, which is exactly the order the element
passes walk it. The RAM is `rtl/vec_mem.vhd`, the repo's existing forced-block
SDP RAM, instantiated `3 x LANES` times.

`mkmem.py` applies thirteen named substitutions and **aborts if any one fires
the wrong number of times**. The arithmetic, the state machine, the pipeline
depth, the narrowed multiplies, the MREG idiom and the accumulation order are
untouched, and nobody has to take that on trust: the transform is the diff.

The comparison is at the **same interface**, because a memory-backed unit holds
the vector and the flat unit does not -- its parent does. `lutdiet_rms_flat`
wraps the unmodified `rmsnorm_rs` in that storage behind the identical streaming
port list, and it is not a straw man: it is what `rtl/llama_top.vhd`'s D-vec
norm adapter already does, one word per cycle into `xv` at `:2024` and one word
per cycle out of `ov` in `S_WR`.

### 6.2 The result

| tag | top | CLB LUT | CLB FF | BRAM tile | URAM | DSP | F7 | F8 | WNS | synth s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `flat_n4096` | `lutdiet_rms_flat` | **299,030** | 198,472 | 0 | 0 | 40 | 26,144 | 13,072 | +1.675 | 781 |
| `mem_n4096` | `rmsnorm_rs_mem` | **4,798** | 1,700 | **6** | 0 | 40 | **0** | **0** | +0.971 | 21 |
| `rms_n4096` | `rmsnorm_rs` (bare) | 169,746 | 67,320 | 0 | 0 | 40 | 17,408 | 8,704 | +1.675 | 570 |
| `hotw_n4096` | `rmsnorm_rs_hotw` | **40,804** | 67,267 | 0 | 0 | 40 | 17,408 | 8,704 | +1.675 | 74 |

**DERIVED: -294,232 LUT (-98.4%), -196,772 FF, +6 BRAM tiles (12 RAMB18).**
The mux tree is gone completely: F7 and F8 both go to zero.

**A number worth its own line: the bare unit is 169,746 but the same function
with its vector storage is 299,030.** COMPOSE booked D's norm engine at 169,746,
which is the unit WITHOUT the 129,284 LUT of storage `llama_top` must add around
it, while B's and C's rows DO include their own staging. **So the composition is
understated, not overstated: B+C+D as `llama_top` would instantiate it is on the
order of 901,000 LUT, not 772,000.** (ESTIMATE: `lutdiet_rms_flat` models the
adapter's x-write demux and o-read mux exactly; `llama_top` additionally selects
`w_mant` from a constant ROM rather than a written register, so the two are the
same in kind and not identical.)

### 6.3 The cycle cost, stated honestly

A mux is combinational and a memory read is not. Every cycle it moves:

- **The three element passes are UNCHANGED, exactly `3N/LANES` beats in both.**
  This is not luck. `rmsnorm_rs` already registered the output of its bus mux --
  `xa`/`xf`/`wf` exist because "putting it in the same stage as the multiply
  made idx -> mux -> DSP the critical path at 257.0 MHz"
  (`rtl/rmsnorm_rs.vhd:154-158`). **A block RAM's own output register IS that
  register**, same one-cycle latency, same address source. The memory
  substitutes into a pipeline stage that was already there.
- **`done` fires ONE cycle later**: the last bank write is a registered write,
  so the completion condition gains `and o_we = '0'`.
- **The output read pass needs 2 cycles of priming** (RAM output register plus
  the lane-select register), once, not per word.
- **The input load pass is UNCHANGED.** `llama_top` already streams the vector
  in and the result out one word per cycle. Nothing in the parent's schedule
  moves.

**Total: +3 cycles on a 3,072-beat operation. DERIVED: +0.10%.**

**Timing is a margin cost, not a miss.** MEASURED WNS at 5.0 ns: flat
**+1.675 ns (300.8 MHz)**, memory-backed **+0.971 ns (248.2 MHz)**. It gives up
0.70 ns and still meets 200 MHz with 0.97 to spare. Post-synthesis timing is not
post-route timing and neither number is a verdict.

**It is bit-exact.** `equiv.log`, verbatim:

    LUTDIET trial 0 o_exp 13 nonzero_out 0/256
    (assertion error): LUTDIET TOOTH: trial produced an all-zero output, so it proves nothing
    LUTDIET trial 1 o_exp 6 nonzero_out 256/256
    LUTDIET trial 2 o_exp 13 nonzero_out 0/256
    (assertion error): LUTDIET TOOTH: trial produced an all-zero output, so it proves nothing
    LUTDIET trial 3 o_exp 13 nonzero_out 0/256
    (assertion error): LUTDIET TOOTH: trial produced an all-zero output, so it proves nothing
    LUTDIET trial 4 o_exp 3 nonzero_out 197/256
    LUTDIET trial 5 o_exp 2 nonzero_out 256/256
    (report note): LUTDIET EQUIV PASS: rmsnorm_rs_mem is bit-exact with rmsnorm_rs

**Read that carefully: three of the six trials proved nothing and said so.**
`rmsnorm_rs` has a silent all-zeros rail outside `rms(x) in [2^-6, 2^12]`, which
`rtl/llama_top.vhd` already documents, and the full-range and both
saturating-rail trials land on it. The claim rests on trials 1, 4 and 5 --
256/256, 197/256 and 256/256 non-zero -- and the `nonzero_out` assertion is the
only reason that is visible rather than hidden behind "6 of 6 passed".

**The checker has teeth.** `mutants.log`, three broken addressings, all caught
on the first non-degenerate trial:

    === MUTANT bankswap ===   (write-bank index from the HIGH bits of the word index)
    LUTDIET FAIL trial 1 o_exp 6 vs 5
    LUTDIET FAIL trial 1 i 0 flat 22130 mem 16368
    === MUTANT addroff ===    (output bank write address off by one)
    LUTDIET FAIL trial 1 i 0 flat 22130 mem -1674
    === MUTANT selxor ===     (read-side lane select perturbed)
    LUTDIET FAIL trial 1 i 0 flat 22130 mem 659

A fourth was not planted; it happened, and the bench caught it as 709
mismatches. See section 7.

### 6.4 This transform has already been done once in this repo, and measured

`rtl/vec_mem.vhd` is not new. Its header records the same finding from
2026-07-27 on subsystem A's FFN:

> swiglu used to emit its N*32-bit result as one wide `out_q` register and
> bfp_pack read it back with a variable index in BOTH its S_MAX and S_PACK
> passes. Synth turned that into a 172-way 32-bit DEMUX (swiglu) plus two
> 172-way 32-bit MUXes (bfp_pack) -- several K LUTs on a LUT-bound (~82%)
> design.

and commit `4914751` measured the outcome on the shipping ZU3EG build:

> Results: CLB LUT 91.15 -> 80.51 percent across the two increments; the route
> went from congestion-cliff (3 rip-up passes) to single-pass clean.

Three things carry over. **The DEMUX is named first there too**, on a 5,504-bit
register, one twelfth the width of `rmsnorm_rs`'s `o_reg`. **The routing win was
reported as larger than the area win**, and nothing here measures congestion, so
that is un-quantified upside. And the verification pattern is the same one used
here, negative control included: that work's `tb_bfp_stress` carried "a
one-element-shift negative control that fails", which is what the `addroff`
mutant is.

### 6.5 The cheap lever: 76% with no memory and no interface change

`rmsnorm_rs_hotw` is `rtl/rmsnorm_rs.vhd` with the flat register and the port
list kept **byte for byte**, and one thing changed: the emit stage presents
`{enable, word address, LANES data words}` as it would to a RAM, and a per-word
generate with a **constant** index decodes it.

    169,746 -> 40,804 CLB LUT     -128,942, -76.0%
    67,320  -> 67,267 CLB FF      the register is still there
    0       -> 0     BRAM         no memory
    +1.675  -> +1.675 ns WNS      identical, 300.8 MHz both
    570 s   -> 74 s   synth       7.7x faster to synthesise

`census_hotw_n4096.txt`: the write-decode root falls from **162,276 to 1,052**
LUT primitives, a 154x reduction, and the two read-mux roots (`ARG` 17,916 and
`sq` 17,474) are untouched and now dominate the unit.

**So four fifths of this cost is not the flops and is not the interface. It is
Vivado's inference for a slice assignment whose base is a runtime variable**, and
it comes off with a local coding change that alters no port, no schedule, no
timing and no resource other than LUT. `mkhotw.py` is a four-substitution
transform, and `tb_lutdiet_hotw.vhd` verifies it bit-exact.

**Both variants are MEASUREMENT ARTEFACTS in
`hw/fk33/results/lutdiet_2026-08-29/rtl/`. Neither is in `rtl/` and neither has
been through the project's gate.**

---

## 7. Measured and REJECTED -- do not retry

- **`get_cells -hier -filter {PRIMITIVE_GROUP == LUT}` as a LUT count.** Not
  re-tested; this script never uses it. `REF_NAME == LUT6` and friends DO work
  post-synth, and every census total is cross-checked against
  `report_utilization`'s own Primitives table. They agree in every run.
- **`opt_design` as an explanation for any of this.** COMPOSE measured it moving
  `gdn_block` by 0.15%, `attn_block` by +3 LUT, `rmsnorm_rs` at N=4096 by
  exactly 0. It was run again here on the three runs the headline pair depends
  on, and moved **exactly zero LUT on all three**: `lutdiet_rms_flat`
  299,030 -> 299,030, `rmsnorm_rs_mem` 4,798 -> 4,798, `rmsnorm_rs_hotw`
  40,804 -> 40,804 (`LUTDIET_SYNTH_VS_OPT` lines in the run logs). The other
  runs were deliberately `LUTDIET_NOOPT=1`, so their `synth_lut == opt_lut` is
  trivially true and is **not** evidence about `opt_design`. Do not spend
  another run on the hypothesis.
- **`lsort -stride` in a Vivado Tcl script.** Vivado 2023.2 embeds Tcl 8.5,
  which does not have it. The failure mode is the one the sentinel exists for:
  `synth_design completed successfully`, a full utilization report, then a Tcl
  error. `ooc_lutdiet_run.sh` exited 9 and the run was correctly discarded.
  Cost: one 52-second run.
- **A per-word generate that writes `o_reg` with a for-loop variable in the
  slice bounds.** MEASURED in GHDL: the output is `X` on every bit. A process
  creates its driver over the longest STATIC prefix of the target, so with
  `o_reg((wi*LANES+k+1)*16-1 downto (wi*LANES+k)*16)` and `k` a loop variable,
  all NB generated processes drive every bit of `o_reg` and the resolution
  function returns `X`. The fix is a fully static slice target
  (`o_reg((wi+1)*LANES*16-1 downto wi*LANES*16) <= o_wd`) with the LANES words
  flattened on the driving side. **This is recorded because the broken form
  SYNTHESISES cleanly and only simulation catches it.**
- **Waiting on `done_a = '1' and done_b = '1'` in an equivalence bench.**
  `rmsnorm_rs` clears `done` every cycle by default, so it is a ONE-CYCLE PULSE,
  and both variants assert it one cycle later than the original. The conjunction
  is never true and the bench deadlocks. Latch each `done` and clear at `start`.
- **Naming Vivado report files after the TOP rather than after the run tag.**
  Three N points of the same top silently overwrite each other's reports, so an
  N sweep leaves only the last census on disk. The CSVs were already tag-named
  and survived; the reports were not.

## 8. Measurement traps hit

- **The teeth-check fired on the bench's own inputs, not on the design.** Three
  of six trial classes produce an all-zero output from `rmsnorm_rs` ITSELF.
  Without the explicit `nonzero_out > 0` assertion, three of six trials would
  have "passed" comparing zero against zero. See 6.3.
- **The census's FF column was silently empty for exactly the thing being
  measured.** The first version iterated the LUT tally's roots only, so a root
  with flops and no LUTs never printed -- and a flat storage register is
  precisely that. `rmsnorm_rs`'s 65,536-flop `o_reg` vanished from its own
  census while its 162,276 write-decode LUTs were attributed correctly under
  `o`. The LUT columns were never wrong; the FF column was. Fixed to iterate the
  union of all primitive kinds. **The `rms_n256` / `rms_n1024` / `rms_n4096`
  censuses in the artefact directory predate the fix and their FF columns are
  incomplete; every later census does not.**
- **A hierarchical utilization row is still not a measurement of an instance.**
  Inherited from COMPOSE; every run here is `-flatten_hierarchy none`.
- **The census root is a HEURISTIC**, derived by stripping `[n]`, `_i_n`, `__n`,
  `_repn` and `_reg` off the leaf cell name. Every row carries a raw example
  cell so it can be audited, and the accounted total is printed against the
  primitive count so nothing hides in a remainder. `ARG__nn` is Vivado's own
  name for a sliced expression, not an RTL signal; it is attributed to the RTL
  by reading the file, not by the tool.
- **`ps --ppid` understates Vivado.** Inherited; the runner sums RSS over the
  full descendant tree. Peaks 3.5 to 14.5 GiB, in `mem_<tag>.txt`.

---

## 9. Open, not yet answered

1. **Nothing here is placed, routed, or composed.** Every caveat in
   `sim/ooc_compose_bcd.tcl`'s header stands. An OOC sum is not a routability
   result, and a design that fits on paper does not necessarily route.
2. **The B and C rows of the projection are ESTIMATES and they are the weakest
   numbers in this document.** They apply an efficiency measured on
   `rmsnorm_rs`'s access pattern to modules whose access patterns differ. The
   write-demux side is the more credible half, because it is literally the same
   RTL idiom in all three modules (a slice assignment with a runtime base) and
   the fix is local. The read side is less credible.
3. **Converting B's READS is a bigger change than converting D's.**
   `rmsnorm_rs`'s parent already streams word by word, so the memory port is a
   drop-in. `gdn_block`'s `qbuf`/`kbuf` are read `DIM = 128` WORDS IN ONE CYCLE
   into `l2_x`, and `knb`/`qsb` are written 128 words at once from
   `l2norm_rs`'s flat output. Making those memories requires `l2norm_rs` to take
   a streaming port too -- the same transform one level down, at unchanged cycle
   count since `l2norm_rs` already consumes `L2_LANES = 4` per cycle internally.
   That is a second interface change and it is Oren's call. **Note this affects
   only the 8.9% read share; B's 79.8% write share needs none of it.**
4. **`attn_block` still misses 200 MHz** (WNS -3.111, 123.3 MHz), re-measured
   here as a cross-check on COMPOSE, not investigated.
5. **URAM was never exercised.** Everything landed in BRAM and BRAM was ample.
   320 URAM remain an untouched reserve.
6. **No congestion, no routing-resource and no power number.** The one prior
   instance of this transform in this repo reported the congestion effect as the
   bigger win. That is upside this document does not measure.
7. **`gdn_head_emit`'s and `l2norm_rs`'s own flat output registers** (`u_l2/q`,
   `u_l2/k`, `u_emit/u_head/o`, 19,490 LUT primitives together) are the same
   idiom inside B's leaves and would take the same local fix. Not measured
   separately.

---

## 10. Machine and disk, as asked

MEASURED at the start of the run, from each `run_<tag>.log`'s own header:

    /dev/nvme1n1p6  1.3T  1.2T   39G  97% /
    /dev/nvme0n1p1  916G  481G  389G  56% /mnt/storage
                   total        used        free      shared  buff/cache   available
    Mem:              31           3           8           0          19          27

**Everything this track built lives on `/mnt/storage/lutdiet`. Root free did not
move.** What lands in the repo is this write-up, two scripts under `sim/`, and
`hw/fk33/results/lutdiet_2026-08-29/` at 772 KB. No checkpoints, no netlists.

**The 95 GB COMPOSE reported is still there and is still not this track's.**
Re-measured: `seamgate` 29 G, `geomut` 26 G, `mut` 11 G, `topkv` 4.0 G,
`mirror` + `mirror2` 7.2 G, `pblock` 1.8 G, `e2e` 1.8 G, `eng_full` 1.7 G,
`cdone` 1.4 G, `new` 1.3 G, plus the rest. Left alone for COMPOSE's reason:
other tracks may be live, and a Vivado process that has now been running over 26
hours still holds a directory in that tree. The 498 MB of stale `.Xil/Vivado-*`
in the repo root is also still there and also untouched. **Both are worth a
sweep by whoever can confirm nothing is running; neither is safe for a track
that cannot confirm it.**

One Vivado at a time throughout; peak RSS per run is in `mem_<tag>.txt`.
