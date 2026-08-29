# What does adding B, C and D to the FK33 actually cost? The first measurement

**Date:** 2026-08-29
**Track:** COMPOSE
**Tree:** pinned `git archive 8795aec1a07df70763a5aeae124af25071f95d67`, extracted
to a scratch directory and synthesised from there. HEAD moved twice during this
work (`99bfe85` at dispatch, `8795aec` when the archive was taken, `62743ce`
before it finished), which is exactly why the tree was pinned.
**Tools:** Vivado 2023.2 (Build 4029153), `xcvu33p-fsvh2104-2L-e`, synthesis
and `opt_design` only. **No hardware was touched.**
**Artefacts:** `hw/fk33/results/compose_2026-08-29/`
**Scripts:** `sim/ooc_compose_bcd.tcl`, `sim/ooc_compose_run.sh`

---

## 1. The question, verbatim

> Oren asked what remains for a 9B inference bitstream. The honest answer today
> is that the card carries subsystem A only [...] The binding unknown is
> RESOURCE. [...] The audit MODELS B+C+D at roughly +558 DSP, landing near 74%
> before the shell [...] **That +558 is a model, not a measurement, and it is
> the number the whole schedule rests on. Your job: replace it with a
> measurement.** Synthesise B, C and D out-of-context at the real 9B shape and
> report actual LUT / FF / DSP / BRAM / URAM per subsystem, then say what the
> composed total would be against the device and against what the shell leaves
> free.

## 2. The answer, up front

**The DSP model was right and DSP was never the problem. LUT is, and LUT was
never modelled at all.**

MEASURED, out-of-context, at the real 9B shape:

| subsystem | DSP | CLB LUT | CLB FF | BRAM tile | URAM |
|---|---:|---:|---:|---:|---:|
| **B** `gdn_block` | 253 | **438,340** | 248,948 | 43 | 0 |
| **C** `attn_block` | 298 | **157,200** | 101,561 | 11 | 0 |
| **D** five `seq_*` sequencer units | 0 | 6,614 | 5,079 | 0 | 0 |
| **D** norm engine, `rmsnorm_rs` N=4096 | 40 | **169,746** | 67,320 | 0 | 0 |
| **B+C+D** | **591** | **771,900** | 422,908 | 54 | **0** |

(Post-synthesis. `opt_design` moves the LUT total by 661, 0.09%; see 10.2.
The `rmsnorm_rs` row is D's arithmetic, which the five `seq_*` control units do
not contain; see 10.1. It is the row the audit's "D = 28 DSP" was pricing.)

Against what the routed A build leaves free on the whole device
(268,222 LUT, 1,295 DSP):

- **DSP: fits, comfortably.** 591 of 1,295 free, 45.6%. Composed die
  1,585 + 591 = 2,176 of 2,880 = **75.6%**, against the audit's modelled
  2,143 = 74.4%. **The model is accurate to 33 DSP, 1.5%.**
- **BRAM fits** (54 of 410.5 free, 13%) and **URAM is untouched** (0 of 320).
- **LUT: does not fit, and not marginally.** 771,900 needed against 268,222
  free is **2.88x over**. Inside the `pb_core` pblock the engine is actually
  constrained to, 233,765 are free and it is **3.30x over**. The composed
  whole-device LUT would be 943,358 against a device total of 439,680 =
  **214.6% of the part.**

**So B+C+D as they stand today do not fit alongside A on this device, and the
margin is a factor, not a percentage.** That is a schedule-changing result.

**But the cause is narrow, it is identified, and it is not "B and C are big".**
Sections 10.1 and 10.2b localise it:

- **82.3% of B's LUT (360,661 of 438,328) is `gdn_block`'s OWN GLUE**, not any
  of its seven leaf units. That glue carries 203,899 FF and **0 DSP, 0 BRAM,
  0 URAM**. All seven leaves together are 17.7%.
- The same signature appears standalone in D's norm engine: `rmsnorm_rs` at
  `N = 4096` is **169,746 LUT with 40 DSP, 0 BRAM, and F7/F8 mux counts of
  17,408 / 8,704** -- an exact 2:1 mux tree. Almost none of it is arithmetic.
- The common cause is a **flat whole-vector port**: a unit that takes the entire
  vector on one port and selects `LANES` elements per cycle pays a mux tree that
  scales with vector length. `rmsnorm_rs`'s port is 4096 x 16 = 65,536 bits.

**So the design is 2.9x over on the one resource it is spending in order not to
use the two it barely touches: composed B+C+D uses 0 of the device's 320 URAM
and 54 of its 672 BRAM tiles.** A whole-vector port selected `LANES` at a time
is a BRAM or URAM read in disguise.

**What this does NOT establish:** that the design is unbuildable, or how much of
the 360K is recoverable, or what it would cost in schedule. It establishes that
the current RTL synthesised as-is does not fit, by a factor, and that the
overage is concentrated in one identified structure rather than spread across
the arithmetic. That is a different and much better problem than "B is too big".

---

## 3. Corrections to the brief

| claim | verdict |
|---|---|
| A alone MEASURED 1,585 DSP (55.0%), 171,458 LUT (39.0%), 261.5 BRAM (38.9%), 0 URAM | **CONFIRMED**, all four, from `hw/fk33/results/build_e2e_2026-08-29/e2e_util_routed.rpt:36,109,114,125` |
| `hw/fk33/rtl/fk33_engine.vhd` instantiates exactly one thing, `matvec_int4_desc_axi` | **CONFIRMED**, `:1156`, and it is the only `entity work.` in the file |
| `llama_top` appears in NO file under `hw/` | **CONFIRMED**, `grep -rl llama_top hw/` returns nothing |
| the audit models B+C+D at "roughly +558 DSP" | **CONFIRMED and sourced.** The brief did not cite it; it is `docs/2026-08-27_9b-single-card-resource-envelope.md:540-553`, column "9B N=1, 27B parallelism": B 227 + C 303 + D 28 = 558 |
| "landing near 74% before the shell" | **CONFIRMED as arithmetic but the wording is backwards.** 1,585 + 558 = 2,143 = 74.4%, and the 1,585 figure is post-route WITH the shell already in it. The shell uses **0 DSP** (engine 1,585 = whole device 1,585), so on DSP the distinction is empty; on LUT it is not, and the shell costs 40,326 LUT |
| "on a device the envelope doc calls historically non-deterministic at high DSP" | **NOT FOUND.** No such phrase in `docs/2026-08-27_9b-single-card-resource-envelope.md`. The nearest real statement is `:798`, "~91% DSP", cited to `docs/2026-08-27_direction-review-fable.md:210-213` as a risk. Do not re-cite the brief's wording |
| the WORKLOG's own restatement, "modeled B+C+D adds ~558 more" (`docs/WORKLOG.md:717`) | **CONSISTENT** with the envelope doc. Note that a DIFFERENT model exists and disagrees: D spec §12 via `docs/2026-08-27_budgets-at-the-measured-clock.md:950` gives B 434 + C 148 + D 28 = 610 at the 27B shape. Both are DSP-only |

**One correction that changes the framing of the whole question.** The brief
compares against the device (2,880 DSP / 439,680 LUT). The engine is placed
inside a pblock, `pb_core`, which covers SLR0 only. Its availability is
**2,700 DSP / 388,800 LUT / 777,600 FF / 576 BRAM / 320 URAM**
(`e2e_pblock_util_routed.rpt`). Every "free" number is 7 to 14% smaller than the
device number, and any composed build inherits that unless the floorplan is
reopened.

---

## 4. The procedure, and what each step isolates

1. **Pin the tree.** `git archive <sha> | tar -x` into a scratch directory,
   synthesise from there. Isolates the measurement from the ~15 HEAD moves that
   happened during the day; two other tracks lost time to exactly this.
2. **Establish the baseline from artefacts, not from the brief.** Read
   `e2e_util_routed.rpt` (whole device), `e2e_engine_util_routed.rpt`
   (`bd_i/eng` only) and `e2e_pblock_util_routed.rpt` (the `pb_core` pblock).
   The three differ, and only the third answers "what does the shell leave
   free".
3. **Derive the 9B shape from `rtl/model_cfg_pkg.vhd`, not from comments.**
   `MODEL = QWEN35_9B`, `NCARDS = 1`. Section 5 lists every generic and where
   it came from.
4. **Synthesise each subsystem OOC, one Vivado at a time**, on a 31 GB box with
   a systemd-oomd history. Peak RSS sampled over the full descendant tree at
   5 s.
5. **Gate on an explicit end-of-script sentinel**, `COMPOSE_DONE <target>`, not
   on the last log line. A Vivado run can print full success and then die on a
   Tcl error afterwards.
6. **Run the two dominant leaves STANDALONE as controls**, at exactly the
   generics the parent maps onto them. This is the step that turned an
   unbelievable number into an attributable one, and it is the step the first
   pass did not have.
7. **Run `opt_design` as well as `synth_design`**, because the pre-existing
   `sim/ooc_micro` reports the leaves are checked against are
   `Design State: Optimized` while a fresh `synth_design` is `Synthesized`, and
   `report_utilization` prints its own warning that the synthesized LUT count
   is typically higher.

---

## 5. Shape provenance: exactly which generics, and from where

Every generic that DIFFERS from the RTL's own default is listed. A generic not
listed is at its default, and the default is already the 9B value.

`rtl/model_cfg_pkg.vhd:64-70`, `QWEN35_9B`: blocks 32, attn_interval 4,
hidden 4096, ffn 12288, lin_key_heads 16, lin_val_heads 32, lin_head_dim 128,
conv_kernel 4, attn_q_heads 16, attn_kv_heads 4, attn_head_dim 256.
`NCARDS = 1` (`:91`). `attn_layers = blocks/attn_interval = 8`,
`gdn_layers = 32 - 8 = 24` (`:112-119`).

| top | generics set | why |
|---|---|---|
| `gdn_block` (B) | **none** | its defaults ARE 9B on one card. `KEY_HEADS 16 / VAL_HEADS 32 / DIM 128 / KCONV 4 / LAYERS 24` all match `model_cfg_pkg` exactly. VERIFIED against the record, not against the file's header comment |
| `attn_block` (C) | `HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8` | its defaults are 27B on one of two cards (12/2/16). `KV_BLOCK=32` and `N_ROT=64` left at the file's defaults, which carry their own provenance (C spec 2.1.1 / one 256-bit HBM beat; GGUF `rope.dimension_count`). **`llama_top`'s `C_KV_BLOCK=4` / `C_N_ROT=8` are SIMULATION-scaled and were deliberately NOT used** |
| `seq_*` (D) | **none** | `NREG 14`, `STEP_W 11` (the file's own comment: "546 at 9B"), `REG_SIZE`'s 4096/12288 which are 9B `hidden`/`ffn`, `LANES 8` = `llama_top`'s `LANES`. All already 9B |
| `l2norm_rs` (control) | `N=128 LANES=4` | exactly `rtl/gdn_block.vhd:604-605` |
| `gdn_silu` (control) | `LANES=4 ARG_Q=12` | exactly `rtl/gdn_block.vhd:594-595` (`LANES => CONV_LANES`, `ARG_Q => Q`) |

**A check that the C shape is the one the audit priced.** `attn_block:377-378`
computes `NBLK = HEAD_DIM/KV_BLOCK = 8` and `G = N_QH/N_KVH = 4`, and `:832`
maps `QH_TILE => G, DIM_TILE => KV_BLOCK` onto `attn_mac_array`. So
`MACS = 4 x 32 = 128`, which is precisely the "MACS = 128, forced" configuration
the envelope doc prices at 303 DSP
(`docs/2026-08-27_9b-single-card-resource-envelope.md:482-493, 546`). The
measured 298 is 5 DSP under it. The comparison is like-for-like.

**Clock: 5.0 ns.** `hw/fk33/gen_pcieep.py:294` and `:800` put the engine's
`core_clk` on `clk_wiz_0/clk_out3`, and the routed build's clock summary
confirms `clk_out3_bd_clk_wiz_0_0` at 5.000 ns / 200.000 MHz.

---

## 6. The evidence

### 6.1 The baseline, from the routed A build

`hw/fk33/results/build_e2e_2026-08-29/e2e_util_routed.rpt` (whole device):

    | CLB LUTs                   | 171458 |     0 |          0 |    439680 | 39.00 |
    | CLB Registers              | 125006 |     0 |          0 |    879360 | 14.22 |
    | Block RAM Tile    | 261.5 |     0 |          0 |       672 | 38.91 |
    | URAM              |     0 |     0 |          0 |       320 |  0.00 |
    | DSPs           | 1585 |     0 |          0 |      2880 | 55.03 |

`e2e_engine_util_routed.rpt` (`-cells [get_cells bd_i/eng]`, i.e. A alone):

    | CLB LUTs                   | 131132 |     0 |          0 |    439680 | 29.82 |
    | CLB Registers              |  63720 |     0 |          0 |    879360 |  7.25 |
    | Block RAM Tile    | 192.5 |     0 |          0 |       672 | 28.65 |
    | DSPs           | 1585 |     0 |          0 |      2880 | 55.03 |

**DERIVED, the shell's own cost** (whole device minus engine): 40,326 LUT,
61,286 FF, 69 BRAM tile, **0 DSP**, 0 URAM.

`e2e_pblock_util_routed.rpt` (`pb_core`, SLR0):

    | CLB LUTs      | 117257 | 0 | 37780 | 155035 | 0 | 0 | 388800 | 39.88 |
    | CLB Registers |  52763 | 0 | 45823 |  98586 | 0 | 0 | 777600 | 12.68 |
    | Block RAM Tile|   21.5 | 0 | 203.5 |    225 | 0 | 0 |    576 | 39.06 |
    | URAM          |      0 | 0 |     0 |      0 | 0 | 0 |    320 |  0.00 |
    | DSPs          |   1584 | 0 |     1 |   1585 | 0 | 0 |   2700 | 58.70 |

**DERIVED, what is free:**

| | device total | used (shell+A) | free on device | `pb_core` total | used in `pb_core` | free in `pb_core` |
|---|---:|---:|---:|---:|---:|---:|
| CLB LUT | 439,680 | 171,458 | **268,222** | 388,800 | 155,035 | **233,765** |
| CLB FF | 879,360 | 125,006 | 754,354 | 777,600 | 98,586 | 679,014 |
| BRAM tile | 672 | 261.5 | 410.5 | 576 | 225 | 351 |
| URAM | 320 | 0 | 320 | 320 | 0 | 320 |
| DSP | 2,880 | 1,585 | **1,295** | 2,700 | 1,585 | **1,115** |

### 6.2 The measurement, raw

Verbatim `COMPOSE_RESULT` lines, post-synthesis, from
`hw/fk33/results/compose_2026-08-29/run_<target>.log`:

    gdn_block,253,438340,434239,4101,248948,36,14,43,0,2913,29025,9231,0.483,221.386,990
    attn_block,298,157200,157091,109,101561,3,16,11,0,2734,17853,3808,-3.111,123.289,220
    seq_desc_fetch,0,702,702,0,962,0,0,0,0,8,2,0,2.901,476.417,16
    seq_opdec,0,262,262,0,118,0,0,0,0,0,2,1,3.741,794.281,14
    seq_region_lock,0,736,736,0,1033,0,0,0,0,6,98,36,2.991,497.760,22
    seq_vec_issue,0,94,94,0,112,0,0,0,0,0,0,0,3.723,783.085,13
    seq_vec_res,0,4820,4802,18,2854,0,0,0,0,217,0,0,3.202,556.174,21

    columns: target,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,
             carry8,f7,f8,wns_ns,fmax_mhz,synth_s

**D's five units sum to 6,614 LUT / 5,079 FF / 0 DSP / 0 BRAM.**

### 6.3 Where B's LUT actually is

`synthonly_firstpass/util_hier_gdn_block.rpt`, verbatim:

    | Instance      | Module                   | Total LUTs | Logic LUTs | LUTRAMs | SRLs |   FFs  | RAMB36 | RAMB18 | URAM | DSP |
    | gdn_block     | (top)                    |     438340 |     434239 |    3774 |  327 | 248948 |     36 |     14 |    0 | 253 |
    |   (gdn_block) | (top)                    |      52450 |      52418 |      32 |    0 | 203918 |      0 |      0 |    0 |   0 |
    |   u_conv      | gdn_conv                 |       3656 |       3656 |       0 |    0 |   1390 |      4 |      0 |    0 |  16 |
    |   u_emit      | gdn_emit_chain           |      21711 |      21533 |      42 |  136 |  14388 |      8 |      9 |    0 |  57 |
    |   u_exp       | gdn_exp_capture          |        949 |        789 |     160 |    0 |    313 |      0 |      0 |    0 |   0 |
    |   u_l2        | l2norm_rs                |     203406 |     203406 |       0 |    0 |   4833 |      0 |      0 |    0 |  36 |
    |   u_recur     | gdn_recur_pipe           |      27828 |      24166 |    3540 |  122 |  23161 |     24 |      1 |    0 | 129 |
    |   u_scal      | gdn_scalar               |       4649 |       4649 |       0 |    0 |    495 |      0 |      0 |    0 |   7 |
    |   u_silu_conv | gdn_silu                 |     123695 |     123626 |       0 |   69 |    450 |      0 |      4 |    0 |   8 |

`u_l2` + `u_silu_conv` = 327,101 of 438,340 = **74.6%**.

### 6.4 The controls, and what they kill

Same Vivado, same part, same pinned tree, same script, same flow, and the exact
generics the parent maps on:

| unit | LUT in `gdn_block` | LUT standalone, post-synth | LUT standalone, post-`opt_design` | DSP either way | FF either way |
|---|---:|---:|---:|---:|---:|
| `l2norm_rs` N=128 LANES=4 | 203,406 | 14,920 | **14,321** | 36 / 36 | 4,833 / 4,826 |
| `gdn_silu` LANES=4 ARG_Q=12 | 123,695 | 4,191 | **4,191** | 8 / 8 | 450 / 455 |

Verbatim:

    COMPOSE_SYNTH_VS_OPT target=l2norm_rs synth_lut=14920 opt_lut=14321 \
      synth_ff=4826 opt_ff=4826 synth_dsp=36 opt_dsp=36 synth_bram=0 opt_bram=0
    COMPOSE_SYNTH_VS_OPT target=gdn_silu  synth_lut=4191  opt_lut=4191 \
      synth_ff=455  opt_ff=455  synth_dsp=8  opt_dsp=8  synth_bram=2 opt_bram=2

**Three things follow, and the third is the one that matters.**

1. **`opt_design` is NOT the explanation.** It moved `l2norm_rs` by 4% and
   `gdn_silu` by 0%. It cannot account for 13.6x or 29.5x. The
   post-synth-versus-post-opt worry that motivated running it is real but small.
2. **The pre-existing `sim/ooc_micro/util_l2norm_rs_N128_LANES4.rpt` figure of
   12,628 LUT REPRODUCES** to within RTL drift (14,321 here, from a tree three
   days newer that has since fixed OI-7 in that very file). The old
   measurements are sound.
3. **The extra 308,000 LUT is created by composition, at identical DSP, identical
   BRAM and identical FF.** Identical FF and DSP mean the sequential structure
   and the arithmetic are the same in both cases. So this is not "the unit is
   bigger at the real shape" -- the shape is the same in both runs. It is
   something the parent's context does to the same logic.

---

## 7. Measured and REJECTED -- do not retry

- **"The 438K LUT is a post-synthesis over-estimate that `opt_design` will
  remove."** MEASURED and rejected in section 6.4. `opt_design` moved the
  dominant leaf by 599 LUT out of 14,920 (4.0%) and the second by zero. Do not
  spend another run on the hypothesis that the synth-versus-implementation gap
  explains a factor of 13.
- **"The old `sim/ooc_micro` leaf measurements were wrong or stale."**
  MEASURED and rejected. `l2norm_rs` at the same generics reproduces 12,628 to
  14,321 across a three-day RTL gap that includes a real fix to the file.
- **`get_cells -hier -filter {PRIMITIVE_GROUP == LUT}` as a LUT count.**
  MEASURED to return **0** on a post-`synth_design` netlist for a design that
  `report_utilization` scores at 4,820 CLB LUTs. The same filter for
  `FLOP_LATCH` also returns 0. This is the counting method used by the existing
  `sim/ooc_gdn_scalar.tcl` and its siblings, and it silently reports 0 for LUT
  and FF at this stage while `REF_NAME =~ DSP48E2*` and `CARRY8*` work fine --
  so a run looks successful and its two most important columns are zero. Parse
  `report_utilization` instead. **This is a live defect in the existing OOC
  scripts and it is not mine to fix**; recorded here so the next track does not
  rediscover it.
- **`llama_top` as the composed-resource number.** Not run, and deliberately.
  It binds `matvec_int4` rather than the descriptor plane the card runs, and its
  `REGMAX = 4096` flat region model is disowned by its own header as "what a
  flat model costs and what a real build would not pay". Its total would be an
  upper bound on a design nobody intends to build, and it would not answer this
  question.

---

## 8. Measurement traps hit

- **A Vivado run can print full success and then die.** Gated on an explicit
  `COMPOSE_DONE <target>` sentinel emitted as the script's last action, checked
  by `sim/ooc_compose_run.sh`, which exits 9 if it is absent. All runs reported
  here cleared it.
- **`/usr/bin/time -v` and `ps --ppid` both understate Vivado's memory.** The
  `vivado` entry point is a shell script that execs a loader, so the process
  doing the work is a grandchild; `--ppid` alone reported **7 MiB** for a run
  that actually peaked at 13.9 GiB. The runner now sums RSS over the full
  descendant tree.
- **`report_utilization` on a synthesized netlist prints its own warning** that
  the count is typically higher than after implementation, and the reports this
  work compares against in `sim/ooc_micro` are `Design State: Optimized`. Both
  states are now captured. It turned out not to matter here, but it was not
  knowable in advance and it is why section 6.4 exists.
- **A hierarchical utilization row is not a measurement of that instance.**
  Vivado's default `-flatten_hierarchy rebuilt` flattens, optimises across every
  boundary, and rebuilds the hierarchy for reporting. This is the leading
  candidate mechanism for section 6.4's discrepancy and it is not yet settled;
  see section 9.
- **HEAD moved twice while this ran** (`99bfe85` -> `8795aec` -> `62743ce`).
  Every number here is from the pinned `8795aec` archive. The brief's own
  warning was correct.

---

## 9. Open, not yet answered

1. **RESOLVED, see 10.2b.** Hypothesis (a) is correct: it is real logic in
   `gdn_block`'s own glue, mis-attributed to the two children it drives by the
   default `-flatten_hierarchy rebuilt` reporting. The total is unchanged
   (438,328 against 438,340, 12 LUT apart) and the leaves are the size their
   standalone runs said they were.
2. **`attn_block` misses the 200 MHz engine clock by 3.111 ns** (post-synth
   WNS -3.111, Fmax 123.3 MHz). Post-synthesis timing is not post-route timing
   and this is not a verdict, but it is a 62% miss and it is not a rounding
   error. `gdn_block` meets it with +0.483 ns to spare (221.4 MHz), which is the
   useful control: the two were measured identically.
3. **D's arithmetic is not in D's number.** The five `seq_*` units are control
   only. The D-vec ops (`OP_VEC_NORM` / `RESIDUAL` / `SWIGLU`) are computed by
   units `llama_top` instantiates beside the sequencer, chiefly `rmsnorm_rs` at
   `N = SHAPE.hidden = 4096` (`rtl/llama_top.vhd:1835`), which takes the whole
   vector on one 65,536-bit port. **The audit's D row of 28 DSP prices those
   engines, not the sequencer**, so the measured 0 DSP and the modelled 28 are
   not in contradiction -- they are measurements of different things. A run of
   `rmsnorm_rs` at N=4096 was launched and its result is appended in section 10.
4. **Nothing here is a composed synthesis.** Every caveat in the script header
   stands: no inter-subsystem routing, no shared-resource merging (`rmsnorm_rs`
   is counted twice, once inside `attn_block` and once for D), no shell, no
   placement. An OOC sum is a lower bound on area in one respect and an upper
   bound in another, and it is not a routability result.
5. **RESOLVED while this ran, see 10.3.** TRACK REALSHAPE found the real 9B
   shape did NOT elaborate (`ghdl -r llama_top` died at 24.9 GB with
   `STORAGE_ERROR`, on B's per-layer state modelled as a 201,326,592-bit signal
   array), and TRACK REALFIX then fixed that and five other real-shape defects
   at `3e93bed`: it now elaborates in 2.12 s / 2.20 GB. **That dependency did
   not affect this work**: none of the six defects is in any cone measured here,
   and every top above synthesised in Vivado without an elaboration error before
   the fix landed. The two facts are consistent -- R2 was a simulator memory
   blow-up in a signal array, which synthesis never allocates.

---

## 10. Appendix: the second pass

Appended in place. Nothing above is edited.

### 10.1 D's arithmetic, and the mechanism identified

Section 9 item 3 left `rmsnorm_rs` at the D-vec shape unmeasured. It has now
been measured, STANDALONE, at `N = 4096 / LANES = 4`
(`rtl/llama_top.vhd:1835`, `NORM_LANES` default 4, `NN = SHAPE.hidden = 4096`):

    rmsnorm_rs,40,169746,169746,0,67320,0,0,0,0,252,17408,8704,1.675,300.752,611,21,...
    columns: target,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,
             carry8,f7,f8,wns_ns,fmax_mhz,synth_s,opt_s,...

**169,746 LUT, 67,320 FF, 40 DSP, 0 BRAM, 0 URAM, and it MEETS 200 MHz**
(WNS +1.675, Fmax 300.8). `opt_design` changed nothing at all: synth and opt
LUT are both 169,746.

**This revises D and it strengthens the verdict.**

| | LUT | FF | DSP | BRAM |
|---|---:|---:|---:|---:|
| D sequencer, five `seq_*` units | 6,614 | 5,079 | 0 | 0 |
| D norm engine, `rmsnorm_rs` N=4096 | 169,746 | 67,320 | 40 | 0 |
| **D total** | **176,360** | **72,399** | **40** | **0** |

| | LUT | FF | DSP | BRAM |
|---|---:|---:|---:|---:|
| B `gdn_block` | 438,340 | 248,948 | 253 | 43 |
| C `attn_block` | 157,200 | 101,561 | 298 | 11 |
| D total | 176,360 | 72,399 | 40 | 0 |
| **B+C+D** | **771,900** | **422,908** | **591** | **54** |
| free on device | 268,222 | 754,354 | 1,295 | 410.5 |
| **overage** | **2.88x** | fits (56%) | fits (45.6%) | fits (13%) |
| free in `pb_core` | 233,765 | 679,014 | 1,115 | 351 |
| **overage in `pb_core`** | **3.30x** | fits | fits (53.0%) | fits |

Composed whole-device LUT would be 171,458 + 771,900 = **943,358 against a
device total of 439,680 = 214.6% of the part.**

Composed DSP: 1,585 + 591 = **2,176 = 75.6% of 2,880**, against the audit's
modelled 2,143 = 74.4%. **The DSP model is accurate to 33 DSP, 1.5%, even after
adding the row it did not itself contain.**

**The mechanism is now identified and it is a FLAT WHOLE-VECTOR PORT.**
`rmsnorm_rs` "takes the WHOLE vector on one port, so N is fixed at elaboration"
(`rtl/llama_top.vhd`'s own `NORM_REAL` note). At N=4096 that port is
4096 x 16 = 65,536 bits, the vector is held in 67,320 flops, and `LANES = 4`
elements are selected from it per cycle. The primitive signature is
unmistakable: **F7 Muxes 17,408 and F8 Muxes 8,704, an exact 2:1 mux tree**,
against 252 CARRY8 and 40 DSP. Almost none of the 169,746 LUT is arithmetic;
it is a 4096-way selector.

That is the same shape as section 6.4's unexplained 308,000 LUT: `l2norm_rs`
costs 14,321 LUT standalone at N=128, and `gdn_block` drives its 2,048-bit
`l2_x` port from a vector it must marshal across 32 value heads. **The cost is
in the ports, it scales with vector length, and a DSP-denominated budget is
structurally incapable of seeing it.** Every subsystem budget in
`docs/2026-08-27_9b-single-card-resource-envelope.md` is denominated in DSP.

Two things this does NOT say. It does not say the design is unbuildable: a
whole-vector port selected LANES at a time is a BRAM or URAM read in disguise,
and **the composed B+C+D uses 0 of the device's 320 URAM and 54 of its 672 BRAM
tiles**, so the resource this design is 2.9x over on is the one it is spending
to avoid using the two it is barely touching. It also does not say which unit to
change first; that needs the section 9 item 1 probe and a schedule check.

### 10.2 `opt_design` on B and C: it changes nothing

    COMPOSE_SYNTH_VS_OPT target=gdn_block  synth_lut=438340 opt_lut=437676 \
      synth_ff=248948 opt_ff=248948 synth_dsp=253 opt_dsp=253 synth_bram=43 opt_bram=43
    COMPOSE_SYNTH_VS_OPT target=attn_block synth_lut=157200 opt_lut=157203 \
      synth_ff=101561 opt_ff=101561 synth_dsp=298 opt_dsp=298 synth_bram=11 opt_bram=11

**B: -664 LUT, 0.15%. C: +3 LUT.** DSP, FF and BRAM are bit-identical in both.
The synthesis-versus-implementation gap does not exist here at any scale that
matters, and section 2's headline stands post-`opt_design`. Peak RSS 12.09 GiB
for C, 13.88 GiB for B; every run stayed well inside the box.

The numbers in section 2 are the post-synthesis ones. Substituting the post-opt
figures moves B+C+D from 771,900 LUT to 771,239 and the overage from 2.878x to
2.876x.

### 10.2b The attribution probe: section 6.4's discrepancy is RESOLVED

`COMPOSE_FLATTEN=none` on `gdn_block`, same tree, same part, same generics.
Artefacts in `flatten_none_probe/`.

**The TOTAL is unchanged: 438,328 LUT against 438,340.** A difference of
**12 LUT, 0.003%**. DSP 253, BRAM 43, CARRY8 2,913, F7 29,025, F8 9,231 and
WNS +0.483 are all bit-identical between the two flows. **So B's 438K is real
and is not an artefact of `-flatten_hierarchy rebuilt`.**

**But the per-instance attribution changes completely**, which is exactly what
the probe was for:

| instance | LUT, `rebuilt` (default) | LUT, `none` | standalone |
|---|---:|---:|---:|
| `(gdn_block)` own glue | 52,450 | **360,661** | -- |
| `u_recur` `gdn_recur_pipe` | 27,828 | 27,816 | -- |
| `u_emit` `gdn_emit_chain` | 21,711 | 21,714 | -- |
| `u_l2` `l2norm_rs` | **203,406** | **14,928** | 14,920 |
| `u_silu_conv` `gdn_silu` | **123,695** | **4,688** | 4,191 |
| `u_scal` `gdn_scalar` | 4,649 | 4,634 | -- |
| `u_conv` `gdn_conv` | 3,656 | 3,162 | -- |
| `u_exp` `gdn_exp_capture` | 949 | 725 | -- |

**With the boundaries preserved, `u_l2` costs 14,928 LUT against its standalone
14,920 -- agreement to 8 LUT -- and `u_silu_conv` costs 4,688 against 4,191.**
The two leaves were never big. Section 6.4's 13.6x and 29.5x were an artefact of
reporting, and hypothesis (a) is confirmed over hypothesis (b).

**The real answer: 360,661 of B's 438,328 LUT -- 82.3% -- is `gdn_block`'s OWN
GLUE**, and it carries **203,899 FF, 0 DSP, 0 BRAM and 0 URAM**. That is the
same signature as `rmsnorm_rs` in 10.1: registers plus mux trees, no arithmetic,
no memory. Every one of B's seven leaf units together accounts for 77,667 LUT,
17.7%.

**This makes the finding sharper and more actionable, not weaker.** The thing to
fix is not `l2norm_rs`, and it is not `gdn_silu`; it is `gdn_block`'s
vector-marshalling layer, and the resource it is spending 360K LUT to avoid
using is the BRAM and URAM it is not touching at all.

### 10.3 Corrections arriving during the run

**Three corrections came in while this was measuring. Two are accepted, one is
based on a false premise and is rejected with evidence.**

1. **ACCEPTED.** The dispatcher's claim that `llama_top` "is in no synthesis
   flow" was falsified by this very track: `sim/ooc_compose_bcd.tcl` declares a
   `llama_top` target. The claim is now false and the file says so at length.
2. **REJECTED as stated: "R1 changes an existing `llama_top` OOC area number,
   and it is yours to re-measure."** There is no such number. **`llama_top` was
   declared as a target and never run** -- `ls hw/fk33/results/compose_2026-08-29/
   | grep -c llama_top` returns **0**, and section 7 records the decision not to
   run it, taken before the correction arrived and for reasons that included the
   `REGMAX` flat-region model specifically. So nothing needs re-measuring.
   REALFIX's `REGMAX` 4096 -> 12288 fix is right and is now cited in the script,
   but it invalidates no number in this document because no number here came
   from `llama_top`.
3. **ACCEPTED and CHECKED, with a result that matters: none of the measurements
   here need redoing at the new sha.** REALFIX (`3e93bed`) touched exactly two
   RTL files, `rtl/llama_top.vhd` and `rtl/attn_kv_axi.vhd`
   (`git diff --name-only 8795aec HEAD -- rtl/`). **Neither is in any cone
   measured here.** `gdn_block` and the five `seq_*` units mention neither.
   `attn_block` mentions both eleven times and instantiates **neither**: all
   eleven are comments, and its ten `entity work.` lines are `rmsnorm_rs`,
   `attn_twiddle`, `attn_rope`, `attn_kv_quant`, `attn_mac_array`,
   `attn_score_q12`, `attn_softmax`, `attn_recip`, `attn_gate`, `attn_emit`.
   `attn_kv_quant` is a different unit from `attn_kv_axi`. So every figure in
   this document is valid at HEAD as well as at the pinned `8795aec`.
4. **Also accepted, and it is why C was synthesised the way it was.** REALFIX
   escalated to Oren that C's KV memory-map generics are still scaled-shape and
   illegal at `attn_head_dim` 256. This work synthesised **`attn_block`
   directly**, at its own port-shape defaults, not through `llama_top`'s `C_*`
   generics, so it never reached them. That was chosen in section 5 for a
   different reason -- `llama_top`'s `C_KV_BLOCK=4` / `C_N_ROT=8` are
   simulation-scaled -- and it happens to be the same boundary.
5. **The disk warning: TRACK COMPOSE is not the source.** MEASURED at 17:40 with
   root at 97% / 39 G: this track's entire footprint is **41 MB** of pinned
   source tree plus **3.6 MB** of reports, 44.5 MB total. Root free did not move
   across any of the twelve Vivado runs. The 95 GB in the shared session
   scratchpad is other tracks' (`seamgate` 29 G, `geomut` 26 G, `mut` 11 G,
   `topkv` 4.0 G, `mirror`/`mirror2` 7.2 G), and was left untouched because
   those tracks may be live. A further 498 MB of stale `.Xil/Vivado-*` directories
   sits in the repo root from runs going back to 2026-08-27; it was also left
   alone, because deleting a live Vivado's `.Xil` directory breaks that run and
   two Vivados were in flight. **Both are worth a sweep by whoever can confirm
   nothing is running.**



