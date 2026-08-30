# Does LUTDIET's write-decode fix survive contact with the real modules, and does B+C+D fit?

**Date:** 2026-08-29
**Track:** WRITEDEC
**Tree:** pinned `git archive c64f47ba018724a61ea1caa8dd2d49b7160a2df5`, extracted
to `/mnt/storage/writedec/src`. `c64f47b` is at or after TRACK BTOP1's `bf99d39`,
so B's recurrence fix is included. The sha was taken as its OWN step before
`git archive`, because a one-command `git archive HEAD` straddled a concurrent
commit earlier today and yielded an ancestor tree.
**Tools:** Vivado 2023.2 (Build 4029153), `xcvu33p-fsvh2104-2L-e`, 5.0 ns,
`synth_design -mode out_of_context -flatten_hierarchy none`, `LUTDIET_NOOPT=1`.
GHDL (mcode) for equivalence and mutation. Every synthesis run went through
TRACK LUTDIET's own `sim/ooc_lutdiet_run.sh` and `sim/ooc_lutdiet_ports.tcl`,
**unmodified**, so the before-numbers are directly comparable to LUTDIET's and
to COMPOSE's without adjustment. That was the point of reusing them.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `program_hw_devices`,
nothing under `hw/fk33/host` or `hw/fk33/tcl`, nothing opening `/dev/xdma*`.
**Artefacts:** `hw/fk33/results/writedec_2026-08-29/`
**Commits:** `51323ca` (`rtl/rmsnorm_rs.vhd`), `e783363` (`rtl/gdn_block.vhd`),
`bfdae6b` (`rtl/attn_block.vhd`), and this file with `hw/fk33/results/writedec_2026-08-29/`.

---

## 1. The question, verbatim

> TRACK LUTDIET (`4950666`, write-up in `docs/debugging/` dated 2026-08-29,
> find it and **read it first**) answered whether B+C+D can fit one FK33. It
> measured the fix. **It did not apply it to the real modules.** That is you.
>
> **The finding, which you must verify before building on it:**
> > **76% comes off with no memory and no interface change.** Decoding the
> > variable-index write with a per-word generate and a **constant** index gives
> > `rmsnorm_rs` 169,746 -> **40,804 LUT** at identical ports, identical FF,
> > identical WNS and zero BRAM. The write-decode root falls 162,276 -> 1,052
> > primitives.
>
> And the reason this is schedule-critical:
> > The write-decode fix by itself projects B+C+D at **210,890 LUT against
> > 233,765 free in `pb_core`**. TRACK COMPOSE had measured B+C+D at **2.88x the
> > device**.
>
> That margin is **22,875 LUT, 9.8%**. It is positive and it is thin. Your job
> is to turn a projection built on a coefficient measured on one module into
> MEASURED numbers on the real ones. [...] **The hard part is that this must be
> bit-exact.**

---

## 2. The answer, up front

**The fix is real and it lands on all three modules -- B+C+D goes from 772,248
LUT to 265,124, a factor of 2.9. But it is NOT enough: that fits the DEVICE with
3,098 LUT spare and is still 31,359 OVER `pb_core`, and on the booking LUTDIET
itself corrected COMPOSE to, it is 161,236 over. The projection of 210,890 was
optimistic on every module row. The read conversion this track was told to hold
back IS still needed, and section 8 now says so with numbers instead of a
coefficient.**

**(a) LUTDIET's before-numbers all reproduce, to the digit, four commits later.**
`rmsnorm_rs` N=4096 at 169,746 / 67,320 FF / 40 DSP / 0 BRAM / F7 17,408 /
F8 8,704 / WNS +1.675; `gdn_block` at 438,328 / 248,972 / 253 / 43 / 29,025 /
9,231 / +0.483; `attn_block` at 157,560 / 101,190 / 298 / 11 / 17,853 / 3,808 /
WNS -3.111. Nothing downstream rests on an unverified number.

**(b) MEASURED, the three modules:**

| module | generics | before LUT | after LUT | delta | FF before/after | DSP | BRAM | WNS before/after |
|---|---|---:|---:|---:|---|---:|---:|---|
| `rmsnorm_rs` | N=4096 LANES=4 | 169,746 | **40,934** | -128,812 (-75.9%) | 67,320 / 67,196 | 40 | 0 / 0 | +1.675 / +1.675 |
| `gdn_block` | defaults (9B, one card) | 438,328 | **131,760** | -306,568 (-69.9%) | 248,972 / 248,873 | 253 | 43 / 43 | +0.483 / +0.483 |
| `attn_block` | HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8 | 157,560 | **85,816** | -71,744 (-45.5%) | 101,190 / 101,014 | 298 | 11 / 11 | -3.111 / -3.122 |

DSP does not move on any of the three. BRAM does not move on any of the three.
WNS does not move on `rmsnorm_rs` or `gdn_block` at all. On `attn_block` it moves
**eleven picoseconds**, -3.111 to -3.122, on a path whose source and destination
are the same registers in both builds (`kvh_reg[2]` -> `vref_r_reg[*][*]`) and
which has nothing to do with the write decode. `attn_block` missed 200 MHz before
this track existed and still does; that is placement variation on an
already-violated path, not a regression and not a fix.

**(c) THE SCHEDULE DOES NOT MOVE AT ALL, which is not what LUTDIET's probe did.**
LUTDIET's `rmsnorm_rs_hotw` registered `{o_we, o_wa, o_wd}` inside the FSM and
paid **one extra cycle on `done`**. `done` is what `rtl/llama_top.vhd` and the
pinned `seq` landmarks wait on, so that is not free. Every change here is
**combinational in the enable and cycle-exact**: the write decode reads the
same signals the original write sat under, and the only thing that changed is
that the assignment TARGET is a constant slice instead of a runtime one. The
price is 130 LUT on `rmsnorm_rs` (40,934 against the registered probe's 40,804)
and the equivalence benches assert `done` on the same cycle, not one later.

**(d) The composition. MEASURED, replacing the projection:**

| booking | B | C | D_seq | D_norm | total | vs 268,222 free (device) | vs 233,765 free (`pb_core`) |
|---|---:|---:|---:|---:|---:|---|---|
| COMPOSE's, before | 438,328 | 157,560 | 6,614 | 169,746 | **772,248** | 2.88x OVER | 3.30x OVER |
| COMPOSE's, **after** | 131,760 | 85,816 | 6,614 | 40,934 | **265,124** | **FITS, 3,098 spare** | **OVER by 31,359 (1.13x)** |
| LUTDIET's corrected, before | 438,328 | 157,560 | 6,614 | 299,030 | **901,532** | 3.36x OVER | 3.86x OVER |
| LUTDIET's corrected, **after** | 131,760 | 85,816 | 6,614 | 170,811 | **395,001** | 1.47x OVER | 1.69x OVER |

Every one of those eight numbers is MEASURED here, including `D_seq` (the five
`seq_*` leaves, unchanged by this track, re-measured so the sum is built from
this track's own runs) and both `D_norm` bookings. The two bookings differ only
in whether D's norm is the bare `rmsnorm_rs` (which does NOT hold the vector) or
`lutdiet_rms_flat` (which does, exactly as `rtl/llama_top.vhd`'s D-vec norm
adapter must). LUTDIET's correction that COMPOSE understated the composition is
CONFIRMED and it is the booking that matters for a real build.

**So the honest verdict is: the write decode alone does NOT close the fit.**
It takes B+C+D from 2.88x to under the device on COMPOSE's booking, which is a
factor of 2.9 and by far the largest single reduction available, and it leaves
`pb_core` **31,359 LUT short on the optimistic booking and 161,236 short on the
realistic one**. LUTDIET's projection of 210,890 was optimistic on all three
module rows, by 41,120 on B, 12,985 on C and 6,614 on D.

**(e) The read conversion IS still needed, and this is now evidence rather than
a projection.** Both it and the BRAM trade were reserved as fallbacks to be
raised only if the write decode failed to close the fit. It did not close it
against `pb_core`. Section 8 says exactly where the remaining excess is and what
the cheapest next lever is; the short version is that **B's read muxes alone
(52,290 LUT primitives) are larger than the 31,359 CLB LUT `pb_core` is short
on the optimistic booking**, and `llama_top`'s own D-vec norm adapter is
**129,877 CLB LUT of the same idiom one level up**, which is the single biggest
remaining item and belongs to whoever owns `rtl/llama_top.vhd`.

**What this does NOT establish.** Nothing here is placed, routed, or composed
into one netlist; every caveat in `sim/ooc_compose_bcd.tcl`'s header stands. An
OOC sum is not a routability result. Section 10 lists what was not verified.

---

## 3. Corrections, under their own heading

### 3.1 Corrections to LUTDIET

| LUTDIET claim | verdict |
|---|---|
| `rmsnorm_rs` N=4096 = 169,746 LUT / 67,320 FF / 40 DSP / 0 BRAM / F7 17,408 / F8 8,704 / WNS +1.675 | **CONFIRMED BIT-IDENTICALLY**, on `c64f47b` |
| `gdn_block` = 438,328 / 248,972 / 253 / 43 / 29,025 / 9,231 / +0.483 | **CONFIRMED BIT-IDENTICALLY** |
| `attn_block` = 157,560 / 101,190 / 298 / 11 / 17,853 / 3,808 / -3.111 | **CONFIRMED BIT-IDENTICALLY** |
| the write decode gives `rmsnorm_rs` 169,746 -> 40,804 at identical ports and WNS | **CONFIRMED IN KIND, 40,934 here.** The 130 LUT difference is the price of not registering the write, and it buys back the cycle LUTDIET's probe spent |
| the fix projects **B at 90,640 LUT** | **CORRECTED. MEASURED 131,760**, 41,120 higher. That projection applied a 99.4% recovery to B's WHOLE write share including the 19,490 primitives inside `l2norm_rs`'s and `gdn_head_emit`'s own output registers, which are a level down and are untouched here. LUTDIET's own section 9 item 7 named them |
| the fix projects **C at 72,831 LUT** | **CORRECTED. MEASURED 85,816**, 12,985 higher. C's write share was 54.1% and the remaining roots (`u_arr/acc` 22,203, `od_r` 9,829, `p_reg` 15,429) are the MAC array and the read side, not storage |
| the fix projects **D at 47,418 LUT** (`D_seq` 6,614 + `rmsnorm_rs` 40,804) | **CONFIRMED on that booking**: MEASURED 47,548 (6,614 + 40,934). But that booking is the one LUTDIET itself corrected: D's norm AS `llama_top` INSTANTIATES IT is 170,811 after this change, so D is really 177,425 |
| the mux tree is 17.5% and the variable-index WRITE is 80.5%, carrying zero MUXF7 and zero MUXF8 | **CONFIRMED on all three modules.** After the fix the census's top roots in `gdn_block` are exactly the read muxes (`l2_x`, `rp_cvj`, `rp_qs`, `rp_kn`) and the leaf flat registers; the write roots are gone |
| the reliable tell is a large FF count with zero BRAM in the same module | not re-tested; nothing here contradicts it |

### 3.2 Corrections to the brief

| brief claim | verdict |
|---|---|
| "the write-decode fix by itself projects B+C+D at 210,890 LUT" | that is LUTDIET's projection, correctly quoted. **MEASURED it is 265,124** on the same booking, 54,234 higher |
| "That margin is 22,875 LUT, 9.8%. It is positive and it is thin." | **the margin is not thin, it is NEGATIVE.** MEASURED, B+C+D is 265,124 against 233,765 free in `pb_core`: 31,359 OVER on the optimistic booking and 161,236 over on the realistic one. It fits the DEVICE with 3,098 spare and does not fit the pblock |
| "LUTDIET measured the fix at 169,746 -> 40,804 ... at identical ports, identical FF, identical WNS" | **incomplete, and the omission matters.** That variant also fires `done` ONE CYCLE LATER. LUTDIET's own `mkhotw.py` adds `and o_we = '0'` to the completion condition and its section 6.3 says so for the memory variant; the `hotw` summary in 6.5 does not repeat it. Applying `hotw` as written would have moved a schedule the pinned landmarks measure |
| "`attn_block` ... note its WNS was -3.111 ns, already failing before you touch it" | **CONFIRMED**, and it is -3.122 after: eleven picoseconds, same path, same source and destination registers. Neither a regression nor a fix |
| "`rmsnorm_rs` has a SILENT ALL-ZEROS RAIL ... only an explicit `nonzero_out > 0` assertion turned '6 of 6 passed' into the truth" | **CONFIRMED AND STRENGTHENED.** With LUTDIET's six input classes verbatim, trials 0, 2 and 3 are degenerate here too. Retuning `x_exp` per class moved this bench to **11 of 11 non-degenerate** at every shape, so nothing rests on a zero-against-zero comparison |

---

## 4. The procedure, and what each step isolates

1. **Pin the sha as its own step, then `git archive`.** HEAD moved under this
   track five times while it ran.
2. **Reproduce the before-number before believing anything.** Run 1 was
   `rmsnorm_rs` N=4096 on the pinned tree through LUTDIET's own unmodified
   scripts. If it had not matched, everything downstream was void.
3. **Change ONE module, measure it, land it, then move on.** Three separate
   before/after pairs and three separate commits. A batched change would have
   made a per-module attribution impossible.
4. **Build the equivalence oracle against the PRE-CHANGE RTL, never against
   the new one.** `rmsnorm_rs_ref` is `rtl/rmsnorm_rs.vhd` from the pinned tree
   with the entity and architecture names changed and **nothing else** -- which
   is checked mechanically, by renaming it back and diffing against the pinned
   file.
5. **Assert non-triviality on EVERY trial.** An all-zero output compares zero
   against zero. Here it is a hard `severity failure`, so a degenerate trial is
   a failure of the bench, not evidence.
6. **Cover the index corners the generate creates.** Index 0, index N-1, a
   positional ramp where every element is distinct, a reset taken mid-emit, and
   six shapes including `NB = 1` (N=8 LANES=8) and `LANES = 1`.
7. **For the two big modules, compare WHOLE SIMULATIONS, not verdicts.** Run
   the existing benches against the pre-change tree and against the changed
   tree, dump every signal GHDL's VCD reaches, and compare signal by signal by
   NAME at every timestamp. This is a far stronger oracle than "the bench still
   passes", and section 6.4 shows a mutation that the bench passes and the VCD
   catches.
8. **Teeth-check every oracle, and report the mutations that do NOT bite under
   their own names.** Seventeen mutations across the three modules.
9. **Run a CLEAN-DESIGN CONTROL for `attn_block`.** Another track had
   `rtl/attn_kv_axi.vhd` modified in the working tree while this ran, so the
   `attn_block` comparison was repeated on a tree carrying ONLY this track's
   `attn_block.vhd` against the pinned rest.
10. **One Vivado at a time**, peak RSS over the full descendant tree.

---

## 5. The change, in one paragraph per module

**`rmsnorm_rs`.** The emit stage wrote `o_reg((base+k+1)*16-1 downto
(base+k)*16)` with `base := idx3 * LANES`. The saturate-and-place is now a
combinational `o_wd` driven by a process sensitive to `p3_sum` and
`shift_total` -- the same expression, evaluated in the same cycle -- and a
`for wi in 0 to NB-1` generate writes `o_reg((wi+1)*LANES*16-1 downto
wi*LANES*16) <= o_wd` under `rst = '0' and state = S_EMIT and v3 = '1' and
idx3 = wi`. The `rst = '0'` term is load-bearing: `rst` does not clear `v3`,
and `state` still reads `S_EMIT` on the cycle reset is taken.

**`gdn_block`.** `qbuf`, `kbuf`, `vbuf` (written at `base := obeat*CONV_LANES*16`)
and `qsb`, `knb` (written at `base := kh*DIM*16`) become five generates whose
enable is the SAME condition the write sat under, read from the same signals --
`co_valid`, `ph`, `cv_seg_i`, `obeat`, `co_data` for the first three,
`ph = P_L2WAIT`, `l2_done`, `l2_qk`, `kh`, `l2_q`/`l2_k` for the other two.
Nothing new is registered; the sequencer keeps the pointer advance and the
bound assert.

**`attn_block`.** `qplane` (a `for i` loop whose slice base carries the runtime
`qh`), and `krec`/`vrec`, which have THREE writers at three granularities: an
element write at `to_integer(unsigned(kq_mi))`, a block write at
`rbi*KV_BLOCK`, and a whole-register bypass write. All three move into one
element-granularity generate per register, as an `if/elsif` chain **ordered by
the original process's assignment order**, because inside a process the last
assignment on an edge wins: bypass outranks block outranks element. Whether any
two of them can be true on one edge is not assumed either way; the ordering
reproduces the original whether they can or not. `vs2` is flattened by a
separate concurrent generate so `qplane`'s slice target is static.

**The trap all three had to avoid, and it is invisible to synthesis.** LUTDIET
recorded it and it is repeated in each file's comment: a per-word generate whose
slice bounds contain a **for-loop variable** creates a driver over the WHOLE
signal in every generated process. All NB of them resolve against each other and
the signal simulates as `X` -- while synthesising cleanly. Every slice target
here is static in the generate index alone.

---

## 6. The evidence, as raw output

### 6.1 The before/after CSVs, verbatim

    target,gen,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,carry8,f7,f8,wns_ns,fmax_mhz,synth_s,opt_s,...
    rmsnorm_rs,"N=4096 LANES=4",40,169746,169746,0,67320,0,0,0,0,252,17408,8704,1.675,300.7518796992481,679,-1,...
    rmsnorm_rs,"N=4096 LANES=4",40,40934,40934,0,67196,0,0,0,0,252,17408,8704,1.675,300.7518796992481,103,-1,...
    gdn_block,"",253,438328,434229,4099,248972,36,14,43,0,2913,29025,9231,0.483,221.3858755811379,457,-1,...
    gdn_block,"",253,131760,127661,4099,248873,36,14,43,0,2913,29025,13327,0.483,221.3858755811379,236,-1,...
    attn_block,"HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8",298,157560,157451,109,101190,3,16,11,0,2734,17853,3808,-3.111,123.28936012822092,207,-1,...
    attn_block,"HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8",298,85816,85707,109,101014,3,16,11,0,2734,18146,3776,-3.122,123.12238364934746,214,-1,...

### 6.2 The census, before and after, `rmsnorm_rs` N=4096

Before (`census_wd_rms_before_n4096.txt`):

    root                                     LUT   MUXF7   MUXF8       FF  CARRY8  example_cell
    o                                     162276       0       0        0       0  o_reg[10062]_i_3
    ARG                                    22281   10880    5440        0      11  ARG__23_i_55
    sq                                     13107    6528    3264        0       0  sq_reg[1]_i_19

After (`census_wd_rms_after_n4096.txt`):

    root                                     LUT   MUXF7   MUXF8       FF  CARRY8  example_cell
    ARG                                    17916    8704    4352        0      11  ARG__18_i_57
    sq                                     17474    8704    4352        0       0  sq_reg[0]_i_1
    gow.o                                   2356       0       0        0       0  gow[1007].o_reg[64511]_i_2

**The write-decode root falls 162,276 -> 2,356**, a 69x reduction, and the two
read-mux roots now dominate the unit. LUTDIET's registered probe reached 1,052;
the extra 1,304 is the comparator on `idx3` that the registered form did not
need, and it is what the cycle costs.

### 6.3 The census, `gdn_block`, after

    root                                     LUT   MUXF7   MUXF8       FF  CARRY8  example_cell
    l2_x                                   18433    8192    4096     2048       0  l2_x[0]_i_1
    rp_cvj                                 17473    8736    4368       16       0  rp_cvj[15]_i_1
    q                                       8354       0       0        0       0  u_l2/q_reg[1999]_i_46
    rp_qs                                   8192    4096    2048     2048       0  rp_qs[0]_i_4
    rp_kn                                   8192    4096    2048     2048       0  rp_kn[0]_i_4
    xq                                      7626     155       0      384     221  u_emit/u_silu/xq[0][31]_i_180
    k                                       6710       0       0        0       0  u_l2/k_reg[1999]_i_68

`qsb` (147,456), `knb` (131,072), `vbuf` (100,912), `kbuf` (34,841) and `qbuf`
(33,280) were the top five before. All five are gone. What is left at the top is
exactly the READ side (`l2_x`, `rp_cvj`, `rp_qs`, `rp_kn`) plus `l2norm_rs`'s and
`gdn_head_emit`'s own flat output registers (`u_l2/q`, `u_l2/k`), which are one
level down and untouched. Census total 585,430 -> 140,431 LUT primitives.

### 6.4 Equivalence

`rmsnorm_rs`, `run_final_n4096_l4.log`, verbatim:

    WRITEDEC trial 0 o_exp 2 nonzero 4094/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC trial 1 o_exp 6 nonzero 4070/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC trial 2 o_exp 5 nonzero 4096/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC trial 3 o_exp 4 nonzero 4096/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC trial 4 o_exp 3 nonzero 3071/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC trial 5 o_exp 2 nonzero 4095/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC trial 6 o_exp 7 nonzero 4077/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC trial 7 o_exp 10 nonzero 4096/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC trial 8 o_exp 9 nonzero 4096/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC trial 9 o_exp 8 nonzero 4096/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC trial 10 o_exp 5 nonzero 4091/4096 saturated 0 done_cyc ref 3126 new 3126
    WRITEDEC saturated elements over all trials 0
    WRITEDEC EQUIV PASS: rmsnorm_rs is bit-exact with rmsnorm_rs_ref, N=4096 LANES=4

Read the `done_cyc` column: **3126 on both sides, every trial.** That is the
cycle-exactness claim, measured rather than argued. Six shapes all PASS:

    N=256   LANES=4 : WRITEDEC EQUIV PASS
    N=256   LANES=1 : WRITEDEC EQUIV PASS
    N=32    LANES=8 : WRITEDEC EQUIV PASS
    N=8     LANES=8 : WRITEDEC EQUIV PASS      (NB = 1, the single-word generate)
    N=1024  LANES=4 : WRITEDEC EQUIV PASS
    N=64    LANES=2 : WRITEDEC EQUIV PASS

`gdn_block` and `attn_block`, whole-simulation VCD comparison by signal name:

    tb_gdn_block      VCDCMP PASS: all 487 common signals identical over   831,627 value changes
    tb_gdn_block_vec  VCDCMP PASS: all 482 common signals identical over   205,881 value changes
    tb_attn_block     VCDCMP PASS: all 686 common signals identical over   320,698 value changes
    tb_attn_kv_seam   VCDCMP PASS: all 780 common signals identical over 2,048,052 value changes

plus, for `gdn_block`, the bench's own value dump `gdn_block_out.txt` (1024
elements) byte-identical and the per-invocation `CYCLES` lines reading 2267 on
both sides for all eight invocations.

The clean-design control, `attn_block` alone against the pinned rest:

    signals: 686 in A, 687 in B, 686 common
      only in B (introduced by the change, excluded): vs2_flat[255:0]
    VCDCMP PASS: all 686 common signals identical over 320698 value changes

### 6.4b The gate, unfiltered last lines

Full run on the working tree with all three changes in it:

     suite sim   PASS 74   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
     suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
     OVERALL     PASS 100   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
     REGRESSION: PASS

TRACK GATEHYGIENE measured the working-tree ceiling at 99 and TRACK BGATE2
reported `OVERALL PASS 99 FAIL 0` at `1216a5e`. This run is 100, one higher,
and nothing here added a `sim/tb_*.vhd` row -- the equivalence benches live in
`hw/fk33/results/` precisely so they do not become gate rows. The extra row is
another track's, not this one's, and **no floor was raised**: `sim/regress.sh`
was not touched by this track at all.

`sim/regress.sh --only llama_top` separately: PASS 6 of 6, including
`tb_llama_top_seq`, whose landmarks TRACK BTOP1 re-pinned today. That row is the
single best check that the schedule did not move.

### 6.5 Teeth

`rmsnorm_rs`, 7 mutations of the new decode:

| mutation | what it breaks | verdict |
|---|---|---|
| `idx_off` | word address off by one | CAUGHT |
| `lane_rev` | lane order reversed inside the word | CAUGHT |
| `lastword` | last generate instance dropped | CAUGHT, and it fails exactly at elements N-4..N-1 |
| `no_rst` | `rst = '0'` qualifier dropped | CAUGHT, by the idle-after-reset comparison only |
| `no_state` | `state = S_EMIT` qualifier dropped | CAUGHT, same check |
| **`no_v3`** | `v3 = '1'` qualifier dropped | **NOT CAUGHT** |
| **`sat_hi`** | positive saturation constant 32767 -> 32766 | **NOT CAUGHT** |

`gdn_block`, 5 mutations:

| mutation | verdict |
|---|---|
| `vbuf_off` (word address off by one) | CAUGHT, value dump AND VCD |
| `qsb_off` (head address off by one) | CAUGHT, value dump AND VCD |
| `no_seg` (`cv_seg_i = 0` qualifier dropped) | CAUGHT, value dump AND VCD |
| `qk_swap` (q and k paths swapped) | CAUGHT, value dump AND VCD |
| **`no_ph`** (`ph /= P_IDLE` qualifier dropped) | **NOT CAUGHT** |

`attn_block`, 5 mutations, all CAUGHT: `qplane_off`, `krec_blkoff`, `vrec_isv`,
`krec_nobyp`, `qpl_nolsel`.

**`qpl_nolsel` is the most useful row in this document.** Dropping the
`lsel /= 0` qualifier from the `qplane` generate leaves `sim/tb_attn_block`
**PASSING** -- `OVERALL PASS 1 FAIL 0` -- and the VCD comparison catches it. A
verdict-level oracle would have called that mutation clean.

---

## 7. Measured and REJECTED -- do not retry

- **LUTDIET's `hotw` form as written, i.e. registering `{o_we, o_wa, o_wd}`.**
  It was implemented first here, verified bit-exact, and then WITHDRAWN, because
  it fires `done` one cycle later and `done` is what `llama_top` and the pinned
  `seq` landmarks wait on. The combinational form costs 130 LUT more on
  `rmsnorm_rs` (40,934 vs 40,804) and moves no schedule. Do not "optimise" it
  back into the registered form for that 130 LUT.
- **The BRAM trade (`rmsnorm_rs_mem`, LUTDIET's 299,030 -> 4,798 for +6 BRAM).**
  Not taken, by decision, and now not needed: see section 8. It changes the
  interface; the write decode does not.
- **The `l2norm_rs` streaming port (converting B's READ side).** Not taken, by
  decision, and now MEASURED as not needed. B's read share was 8.9%; the write
  decode alone takes B from 438,328 to 131,760.
- **`rm -rf "$VAR"` in any teeth-check driver.** One was written and deleted
  before it ever ran, on Oren's standing instruction. Every deletion in
  `hw/fk33/results/writedec_2026-08-29/scripts/` is a literal path.
- **Counting `unwrapped/lnx64.o/vivado` processes as a concurrency check.** It
  reported FIVE Vivados during a single run and triggered a false alarm.
  Vivado 2023.2 forks `SYNTH_DESIGN_PARENT<pid>_n` task workers; they are
  children of the one run and `ooc_lutdiet_run.sh`'s RSS sampler already sums
  them. Count `ooc_lutdiet_run.sh` instead.
- **Running a synthesis without checking that the changed file is IN the tree
  you are synthesising.** The first `wd_attn_after` run measured `attn_block`
  from the PRE-change file, because only `rmsnorm_rs.vhd` and `gdn_block.vhd`
  had been copied into `/mnt/storage/writedec/rtl_new`. It produced a
  plausible, different number (147,263 LUT) that would have been reported as
  the `attn_block` result. It is kept, renamed `wd_attn_rmsonly`, because it
  turns out to be the ONLY measurement that isolates what the `rmsnorm_rs` fix
  alone buys inside C: **157,560 -> 147,263, -10,297 LUT**, from the embedded
  `u_norm` and nothing else. The guard is now an explicit
  `cmp` of every file between `rtl_base` and `rtl_new` before a run.
- **`pgrep -f "regress.sh --only llama_top"` as a "wait for the gate" guard.**
  The pattern matched this session's own waiting shells, whose command lines
  contain that string, so a launcher gated on it waited forever and the run it
  was supposed to start never began. This is the `pgrep -f` trap in CLAUDE.md,
  in a form that does not kill anything and merely deadlocks silently.

## 8. Is it enough? The composition

### 8.1 The measurement

The table in section 2(d) is the answer. Repeating the two rows that matter:

    COMPOSE's booking, after : 131,760 + 85,816 + 6,614 + 40,934 = 265,124
      vs 268,222 free on the device : FITS, 3,098 spare
      vs 233,765 free in pb_core    : OVER by 31,359  (1.13x)

    LUTDIET's corrected booking, after : 131,760 + 85,816 + 6,614 + 170,811 = 395,001
      vs 268,222 free on the device : OVER by 126,779 (1.47x)
      vs 233,765 free in pb_core    : OVER by 161,236 (1.69x)

**The write decode is a factor of 2.9 on the composition and it is not enough.**

### 8.2 Where the remaining excess is, MEASURED, in priority order

1. **`rtl/llama_top.vhd`'s D-vec norm adapter: 129,877 CLB LUT**, and it is the
   SAME IDIOM one level up. `lutdiet_rms_flat` is 170,811 after this change
   against the bare unit's 40,934, and its census names the residual exactly:

       wv    88640   0   0   65536   0   wv[0]_i_1
       xv    88640   0   0   65536   0   xv[0]_i_1
       ord   17472  8736 4368  16    0   ord[0]_i_100

   `xv` and `wv` are the adapter's own variable-index WRITE of the incoming
   vector, word by word, and `ord` is its variable-index read. This is the
   single largest remaining item in B+C+D and it is a local fix of exactly the
   kind landed here. **It belongs to whoever owns `rtl/llama_top.vhd`**, which
   is why this track did not take it.
2. **B's read muxes: 52,290 LUT primitives** -- `l2_x` 18,433, `rp_cvj` 17,473,
   `rp_qs` 8,192, `rp_kn` 8,192. This is the conversion LUTDIET flagged as
   needing `l2norm_rs` to take a streaming port. It was deliberately NOT taken.
   It is now the cheapest lever that closes `pb_core` on the optimistic booking:
   at the 1.336 primitives-per-CLB-LUT ratio this module measures, 52,290
   primitives is of order 39,000 CLB LUT against a 31,359 shortfall.
3. **B's leaf flat output registers: 19,490 LUT primitives** -- `u_l2/q` 8,354,
   `u_l2/k` 6,710, `u_emit/u_head/o` 4,426. Same idiom, one level down inside
   `l2norm_rs` and `gdn_head_emit`. LUTDIET's open item 7. Untouched here, and
   the reason B measured 131,760 rather than the projected 90,640.
4. **The BRAM trade**, LUTDIET's measured 98.4% saving for +6 BRAM tiles and
   +3 cycles on 3,072 beats. `pb_core` has 351 BRAM tiles and 320 URAM free and
   the design uses 43 + 11. This is the lever with the most headroom left and it
   is the one that changes an interface.

### 8.3 What this does not settle

`pb_core` is a floorplan constraint, not the device. B+C+D now fits the DEVICE
on the optimistic booking with 3,098 LUT spare, which is 1.2% and is not a
margin anyone should build on. Whether the answer is another lever or a larger
pblock is a decision, not a measurement, and it is Oren's.

## 9. Measurement traps hit, including this track's own

- **A teeth-check that scored every mutant CAUGHT because the tool never ran.**
  The first `run_mutants_rms.sh` used relative source paths after a `cd`, so
  `ghdl -a` could not open a single file, every mutant exited non-zero, and all
  seven were reported CAUGHT. A teeth-check that passes because the compiler
  failed is worse than none. The script now scores an analysis failure as VOID,
  never as CAUGHT, and says so in its header.
- **A VCD comparison that reported IDENTICAL over two files that did not exist.**
  `diff <(strip a) <(strip b) && echo IDENTICAL` is true when both sides are
  empty. Every comparison now refuses to score unless both files exist and are
  non-empty.
- **A plain `diff` of two VCDs is NOT an equivalence test.** GHDL assigns
  identifier codes in declaration order, so adding ONE signal (`vs2_flat`)
  renumbered every code after it and the entire file differed while every value
  was identical. `scripts/vcdcmp.py` maps id -> name in each file and compares
  the value stream per name, reports signals that only exist in the new file,
  and treats a DISAPPEARED signal as a failure rather than ignoring it.
- **The all-zeros rail is N-dependent for spike stimuli.** Classes 7, 8 and 9
  put a single large element in an otherwise flat vector, so `mean(x^2)` scales
  as `1/N`, and a fixed `x_exp` that is off the rail at N=256 is on it at N=32.
  The bench derives an `EADJ = (log2(N) - 8) / 2` correction for exactly those
  three classes. The random classes have an N-independent mean square and need
  none.
- **`ghdl -r` on `tb_gdn_block_vec` and `tb_attn_block` needs `-frelaxed`.**
  Without it elaboration fails on shared variables and no VCD is produced, which
  the guard above turns into VOID rather than a false PASS.
- **The working tree and a clean `git archive` do not run the same gate rows.**
  `--only attn` is `PASS 15 SKIPPED 4` in the working tree and `PASS 13
  SKIPPED 1` on the archive; the extra rows are `tb_attn_fix_beh` and
  `tb_attn_replay_beh`, which need netlist and vector files a clone does not
  get. This is TRACK GATEHYGIENE's finding, met again from the other side.
- **The same `wd_attn_rmsonly` run also moved WNS from -3.111 to -3.449** with
  `attn_block`'s own RTL unchanged, which looked like a 0.338 ns regression
  caused by the `rmsnorm_rs` change. It is not: the failing path is
  `kvh_reg[2] -> vref_r_reg[N][7]` in both, the same source and destination
  registers, and the final `attn_block` build with all three changes measures
  -3.122. The WNS of an already-violated path moves with placement between
  runs; do not read a delta on it as a causal result.
- **Another track's in-flight edit sat in the comparison tree.**
  `rtl/attn_kv_axi.vhd` was modified by another track while the `attn_block`
  VCD comparison ran, so the comparison was repeated against a tree carrying
  only this track's file. It made no difference, but that is a measurement, not
  an assumption.

## 10. Open, not yet answered

1. **Nothing here is placed or routed.** An OOC sum is not a routability result,
   and `-flatten_hierarchy none` forbids cross-boundary optimisation a real
   build would take, so every total is an upper bound in that respect and not
   comparable to a post-route figure.
2. **The emit saturation branch of `rmsnorm_rs` is never exercised**, MEASURED:
   the `sat_hi` mutation does not bite and the bench counts zero saturated
   elements over 11 trials at every shape. `shift_total = max(0, msb_p - 14)` is
   chosen so `max|raw|` fits 15 bits, so only a rounding carry can reach the
   clamp. The clamp code is byte-identical before and after -- only its
   assignment target moved -- so the risk is structural, not numeric, but it is
   an uncovered output region and it is stated rather than hidden.
3. **`attn_block` still misses 200 MHz at WNS -3.111 ns (123.3 MHz).** Not
   investigated, not caused here, and unchanged by this track.
4. **`l2norm_rs`'s and `gdn_head_emit`'s own flat output registers** (`u_l2/q`
   8,354, `u_l2/k` 6,710, `u_emit/u_head/o` 4,426 LUT primitives) are the same
   idiom one level down inside B and are untouched. They are LUTDIET's open item
   7 and they are why B measured 131,760 rather than the projected 90,640.
5. **B's and C's READ muxes are now the largest remaining roots** and this track
   deliberately did not touch them. In `gdn_block` they are `l2_x` (18,433),
   `rp_cvj` (17,473), `rp_qs` (8,192) and `rp_kn` (8,192).
6. **No congestion, routing-resource or power number.** The one prior instance
   of this transform in this repo (`4914751`, subsystem A's FFN) reported the
   ROUTING win as larger than the area win. That is unmeasured upside.
7. **`llama_top`'s own D-vec norm adapter is not touched**, because
   `rtl/llama_top.vhd` belongs to another track. MEASURED, it is the biggest single remaining
   item in the whole composition: `lutdiet_rms_flat` (LUTDIET's artefact that
   models that adapter exactly) is 299,030 -> 170,811 with this change, and the
   residual 129,877 is the adapter's OWN `xv`/`wv` write demux and `ord` read
   mux. See 8.2 item 1.

## 11. Machine and disk, as asked

MEASURED at the start of the run, from `run_wd_rms_before_n4096.log`'s header:

    /dev/nvme1n1p6  1.3T  1.2T   39G  97% /
    /dev/nvme0n1p1  916G  482G  388G  56% /mnt/storage
                   total        used        free      shared  buff/cache   available
    Mem:              31           3           8           0          19          27

Root free rose to 121 G partway through, which is another track's cleanup, not
this one's. **Everything this track built lives on `/mnt/storage/writedec`**
(under 1 GB, and the mutant trees are deleted as they are scored). What lands in
the repo is this write-up plus `hw/fk33/results/writedec_2026-08-29/`.

Peak RSS per synthesis run, from `mem_wd_*.txt`: `rms_before` 13.98 GiB,
`rms_after` 12.53, `gdn_before` 13.6, `gdn_after` 13.67, `attn_before` 13.55.
One Vivado at a time throughout.
