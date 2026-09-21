# The shape a bench runs at, and where it is not the card's

TRACK SHAPEAUDIT, 2026-09-20. Branch `fpga`, HEAD `38d2f79` at start.
No hardware. No Vivado anywhere (workstation lane on build 11b, BC-250 on
TRACK HDRCOST). Every GHDL run in this file was executed in an ISOLATED tree
at `/mnt/storage/fk33_builds/scratch/shapeaudit/tree` (`git archive HEAD`),
never in the shared working tree, because three other tracks were gating.

---

## 1. THE QUESTION, VERBATIM

> **Which benches and harnesses run at a configuration the card build does not
> use, and where does that matter?**

The prompting observation, from two tracks on one evening: TRACK GDNSYNTH found
`sim/ooc_gdnadapt.tcl` defaulting `B_STATE_AXI` and `B_CONST_HBM` to false when
`hw/fk33/gen_fk33_card.py` passes both true, so its recorded **5,472 RAMB36**
and **WNS -4.008** describe an arm the card does not build; and TRACK GAINTEETH
closed by flagging that two of its nine teeth rows are only meaningful at a
bench shape nothing verifies.

## 2. THE ANSWER, UP FRONT

**Two levers that the card ships are named in ZERO `sim/tb_*.vhd` files:
`FAST_POP` and `HOST_WINDOW`.** For `FAST_POP` this was carried to a
demonstration: the card sets `FAST_POP => true`
(`hw/fk33/rtl/fk33_engine.vhd:139`), every RTL default is `false`, and a
deliberate off-by-two defect planted in the `FAST_POP` arm of
`rtl/async_fifo.vhd` **passes five benches including `tb_async_fifo`, the
unit's own dedicated testbench, and fails instantly at the card's value.**
The arm the shipping bitstream runs is functionally unverified.

**The second finding is the SHAPE OF THE COVERAGE, not a single hole.** No
harness in the project runs the card's combination of arm-selecting booleans.
In particular the three `tb_llama_top_*` benches that take the card's
`C_KV_AXI=true` arm (`_seq`, `_bstate_seq`, `_kvport`) all run `NORM_REAL=false`
and `SWG_REAL=false`, while the benches that exercise the real norm and the
real SwiGLU all run C's KV path in the behavioural arm. `tb_llama_top_real`,
whose own gate comment says *"EVERY computing unit real"*, runs
`C_KV_AXI=false` and therefore does not instantiate `rtl/attn_kv_axi.vhd` at
all.

**The third finding is a correction to my own delegated sweep**, recorded in
section 7, because it is the same defect class this audit is about: a
subagent reported `gdn_state_store`'s wide/pipe arms as the largest divergence
in the tree after explicitly not opening `sim/tb_bmover_phases.vhd`, which
defaults `PIPE`, `WIDE` and `NWIDE` all true and is an oracle. The card's B
mover arms ARE covered.

**Most shape differences are BENIGN and saying so is half the result.** A
bench at `HEAD_DIM=16` instead of 256 is correct engineering. What matters is
a difference that selects a different generate arm, changes an inferred
primitive, or makes a mutation a no-op.

## 3. THE CARD'S CONFIGURATION, READ FROM THE GENERATORS

MEASURED from the generated file, not from any document.
`hw/fk33/rtl/fk33_card.vhd:222-243` is the generic map on `fk33_llama_top`:

```
A_DESC => true,          B_STATE_AXI => true,     B_SRC_REAL => true,
B_CONST_HBM => true,     C_KV_AXI => true,        HOST_WINDOW => false,
C_REAL => true,          NORM_REAL => true,       SWG_REAL => true,
NORM_W_IMAGE => ".../hw/fk33/gen/norm_w_9b.hex",
C_QKN_IMAGE  => ".../hw/fk33/gen/qkn_9b.hex",
SMP_EN => true,          C_N_ROT => 64,           C_KV_BLOCK => 32,
C_KV_ADDR_W => 33,       C_K_BASE_CH => 282672640, C_V_BASE_CH => 318324224,
C_MAXPOS => 65536,       C_CTXLEN => 65536,       WDOG_LIMIT => 4000000,
A_ROWS_IF => 48,         A_JOB_STRIDE => 16#40000#
```

Twenty-two generics. **Everything else takes `rtl/fk33_llama_top.vhd`'s own
declared default**, and those defaults are the simulation-scaled values, so an
unset generic is not a neutral choice: `C_KV_BLOCK` defaults to **4**, which
`hw/fk33/gen_fk33_card.py`'s own `LEGAL` table records as ILLEGAL when
`C_KV_AXI` is true. Notable un-set defaults the card therefore runs:
`LANES=8, MANT_W=16, A_BLK=32, C_CM_W=8, C_KV_AXI_DW=256, C_KV_MAXB=16,
C_KV_MAXOUT=4, C_KV_RBUF=4, NORM_LANES=4, NORM_Q=12, NORM_W_EXP=12,
SWG_LANES=1, SWG_WIDE=false, B_CONV_LANES=4, B_RECUR_LANES=4,
B_RECUR_SLOTS=16, B_L2_LANES=4, B_SILU_LANES=8, B_RMS_LANES=4, SMP_FIFO=8,
NORM_ANCHOR=false, A_N_JOBS=311`.

The engine cell is a SEPARATE job with its own pins,
`hw/fk33/gen_fk33_engine.py:79-99`: `BLK=32, ROWS_IF=48, NPORTS_W=24,
NPORTS_S=3, AXI_DW=256, ADDR_W=40, MAXCOLS=17408, MAXROWS_BFP=17408,
FIFO_DEPTH=512, MAXB=16, MAXOUT=16, DESC_MAXB=16`, plus
`FAST_POP_DEFAULT = True` and `DUAL_CLK => true`.

The model shape is a PACKAGE CONSTANT, not a generic:
`rtl/model_cfg_pkg.vhd:85` is `constant MODEL : model_cfg_t := QWEN35_9B`,
giving `attn_head_dim=256, attn_q_heads=16, attn_kv_heads=4, lin_head_dim=128,
lin_key_heads=16, lin_val_heads=32`. So every bench that instantiates
`llama_top` inherits the 9B model shape; the per-bench divergence is entirely
in the explicitly-set generics.

## 4. THE PROCEDURE

Each step isolates one thing.

1. **Read the card's generic map from the GENERATED VHDL, not the generator's
   Python.** `hw/fk33/gen_fk33_card.py` applies `FK33_*` trim overrides to its
   `ARGS` list after construction, so the Python literals are not what is
   built. The generated file is.
2. **Read `rtl/fk33_llama_top.vhd`'s entity to get the defaults**, because a
   generic absent from the map is a value, not a blank.
3. **Map each `sim/tb_*.vhd` to its DUT** by `entity work.<name>`, then extract
   the generic map. Controls for benches that wrap a parametrised bench entity
   (the whole `tb_llama_top_*` family instantiates `tb_llama_top`, not
   `llama_top`, so the card's generic names are not the bench's generic names).
4. **Census the arm-selecting booleans directly.** For each generic the card
   sets, count benches mentioning it and sites setting it true. This is what
   found `FAST_POP`, and it found it because the count was ZERO rather than
   because anything looked wrong.
5. **Confirm the structural claim before running anything.** `grep -n` for the
   generate header proves `attn_kv_axi` is instantiated only at
   `rtl/llama_top.vhd:6875` inside `gkvaxi : if C_KV_AXI generate`.
6. **Demonstrate with a 2x2, not a 1x1.** Mutation off/on crossed with the
   arm false/true. The two baseline cells are the attribution control that
   CLAUDE.md requires: without the `baseline x card-arm` cell, a FAIL at the
   card arm could be the arm flip rather than the mutation.

## 5. THE EVIDENCE

### 5.1 The coverage census (MEASURED)

`grep -rn "FAST_POP" sim/` returns hits in `ooc_aidle.tcl`,
`ooc_aidle_run.sh`, `ooc_levercost.tcl`, `ooc_levercost_run.sh` and
`ooc_levercost_timing.tcl` and **in no `.vhd` file at all**. Those five are
Vivado area and timing harnesses with no functional check.

Per-generic count over `sim/tb_*.vhd`:

```
FAST_POP           benches_mentioning=0    set_true_sites=0
HOST_WINDOW        benches_mentioning=0    set_true_sites=0
DUAL_CLK           benches_mentioning=6    set_true_sites=2
USE_XEXP_PORT      benches_mentioning=3    set_true_sites=0   (covered under another name)
CHECK_JOB_INDEX    benches_mentioning=1    set_true_sites=1   (card is FALSE; bench is true)
A_DESC             benches_mentioning=2    set_true_sites=0   (covered via A_DESC_G)
SMP_EN             benches_mentioning=5    set_true_sites=2
C_KV_AXI           benches_mentioning=4    set_true_sites=0   (covered under the name KV_AXI)
SWG_REAL           benches_mentioning=4    set_true_sites=3
NORM_REAL          benches_mentioning=10   set_true_sites=8
B_CONST_HBM        benches_mentioning=4    set_true_sites=2
B_SRC_REAL         benches_mentioning=3    set_true_sites=2
B_STATE_AXI        benches_mentioning=5    set_true_sites=5
C_REAL             benches_mentioning=13   set_true_sites=13
```

**The `set_true_sites=0` column is NOT by itself evidence of a hole.** Four of
its rows are naming differences that the follow-up resolved: `C_KV_AXI` is
`KV_AXI` on the bench entity, `USE_XEXP_PORT` is `XEXP_PORT`, `A_DESC` is
`A_DESC_G` at `sim/tb_fk33_cardtop_adesc.vhd:56`. Only the
`benches_mentioning=0` rows survived checking.

### 5.2 THE DEMONSTRATED CASE: the FAST_POP 2x2 (MEASURED)

The mutation, in `rtl/async_fifo.vhd:382`, touching the `FAST_POP` arm ONLY
and leaving the `not FAST_POP` arm byte-identical:

```
   do_rd    <= '1' when empty_r = '0' and clr_r_s2 = '0'
-                   and ((FAST_POP and after_e < 2) or
+                   and ((FAST_POP and after_e < 4) or
                         ((not FAST_POP) and (ocnt + inflight) < 2))
               else '0';
```

The arm is flipped the way the card flips it, by the RTL default on
`rtl/matvec_int4_desc_axi.vhd:202`, which is what
`hw/fk33/rtl/fk33_engine.vhd:1356` overrides to true. Bench:
`sim/tb_matvec_fk33_desc_dual.vhd`, the only A bench at the card's
`DUAL_CLK=true` geometry, so the FIFO under test is `async_fifo` as on the
card. All four cells are single `sim/regress.sh --only ... --jobs 1` runs.

| | `FAST_POP=false` (**every bench in the project**) | `FAST_POP=true` (**the card**) |
|---|---|---|
| **baseline** | `OVERALL PASS 1 FAIL 0` (A) | `OVERALL PASS 1 FAIL 0` (D, attribution control) |
| **mutant `after_e < 4`** | **`OVERALL PASS 1 FAIL 0` (B)** | **`OVERALL PASS 0 FAIL 1` (C)** |

Cell C, verbatim:

```
FAIL  sim:tb_matvec_fk33_desc_dual   2s  exit 1: /usr/bin/ghdl-mcode:error:
      bound check failure at .../rtl/async_fifo.vhd:431
 OVERALL     PASS 0   FAIL 1   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 REGRESSION: FAIL
```

Cell D is the cell that makes the table mean anything: the bench is
**capable** of running the card's arm and passes there. It simply never does.

The no-op widened, mutant still in place, `FAST_POP` back at the default:

```
tb_axi_rd_port_dual     OVERALL  PASS 1  FAIL 0
tb_axi_rd_port_stray    OVERALL  PASS 1  FAIL 0
tb_async_fifo           OVERALL  PASS 1  FAIL 0
tb_mv4i_desc_image      OVERALL  PASS 1  FAIL 0
```

**`tb_async_fifo` is the line that matters.** The dedicated testbench for the
very file carrying the defect does not detect it, because it too leaves
`FAST_POP` at false.

### 5.3 The `C_KV_AXI` arm split (MEASURED structurally, DERIVED for the table)

`rtl/llama_top.vhd` has `gkvmem : if not C_KV_AXI generate` at :6694 and
`gkvaxi : if C_KV_AXI generate` at :6750, with the sole
`u_kv : entity work.attn_kv_axi` at :6875 inside the latter. The arm matrix
over the eleven `tb_llama_top_*` benches, extracted from their generic maps:

| bench | `KV_AXI` | `NORM_REAL` | `SWG_REAL` | `B_SRC_REAL` | `B_CONST_HBM` | `ATTN_HD` | `KV_BLOCK` | `N_ROT` | `MAXPOS` |
|---|---|---|---|---|---|---|---|---|---|
| **card** | **true** | **true** | **true** | **true** | **true** | **256** | **32** | **64** | **65536** |
| `_seq` | true | false | false | false | false | 64 | 16 | 16 | 8 |
| `_bstate_seq` | true | false | false | false | false | 64 | 16 | 16 | 8 |
| `_kvport` | true | false | false | false | false | 64 | 16 | 16 | 8 |
| `_real` | false | true | false | false | false | 16 | 4 | 8 | 4 |
| `_normw` | false | true | false | false | false | 16 | 4 | 8 | 4 |
| `_qkn` | false | true | false | false | false | 16 | 4 | 8 | 8 |
| `_swg` | false | true | **true** | false | false | 16 | 4 | 8 | 8 |
| `_swgw` | false | true | true* | false | false | 16 | 4 | 8 | 8 |
| `_bconst` | false | true | false | **true** | **true** | 16 | 4 | 8 | 8 |
| `_bstate` | false | true | false | false | false | 16 | 4 | 8 | 4 |
| `_wdrain` | false | true | false | false | false | 16 | 4 | 8 | 4 |

`*` `_swgw` additionally sets `SWG_LANES=8, SWG_WIDE=true`, which takes
`rtl/swiglu_mem.vhd`'s `gwide`+`gord` arms. **The card takes
`gnarrow`+`gsel1`.** `_swgw` is a lever draw, not a card row, and that is
fine as long as nobody quotes it as the card's SwiGLU.

**The top-left block is empty: no bench sets `KV_AXI` and `NORM_REAL`
together, and none sets `KV_AXI` and `SWG_REAL` together.** `SWG_REAL` landed
2026-09-19 and the card sets it; the card's KV arm has never been simulated
beside it.

Nothing here says any of these benches is wrong. It says the gate is a set of
single-lever draws around a baseline, and the card is at none of the draws.

### 5.4 Position width (MEASURED, no consequence established)

`rtl/llama_top.vhd:6375` is `constant POSW : positive := clog2(C_MAXPOS + 1)`.
At the card's `C_MAXPOS=65536`, **POSW = 17**. Bench values: `MAXPOS=4` gives
3, `MAXPOS=8` gives 4. The two standalone C harnesses that are otherwise
card-shaped sit either side without landing on it:
`sim/ooc_attn_kv_axi.tcl` leaves `POS_W=16`, and `sim/ooc_attn_kv_axi_card.tcl`
deliberately uses `MAXCTX=131072 / POS_W=18`. `sim/tb_attn_twiddle.vhd`
defaults `POS_W=16`.

**No harness in the project runs POSW=17.** I did not establish that this
matters and am not asserting that it does; it is listed in section 9.

### 5.5 What IS card-shaped, which is most of it

Reported because the audit is worthless if it only lists holes.
`sim/tb_swiglu_mem_9b.vhd` runs `N=12288, LANES=1, WIDE_IO=false`, an exact
match to the card's SwiGLU. `sim/tb_attn_twiddle.vhd` runs `NPAIR=32`, the
card's rope table in full, so my initial hypothesis that `IMROPE_W(8..31)` was
dark was WRONG and is recorded as rejected in section 6.
`sim/tb_attn_kv_map.vhd`, `sim/tb_attn_kv_axi.vhd`, `sim/tb_attn_kv_quant.vhd`
and `sim/tb_csweep_rate.vhd` all run `HEAD_DIM=256 / KV_BLOCK=32`, and
`tb_csweep_rate` additionally matches `N_QH=16, N_KVH=4, N_ROT=64`, i.e. the
card's full C geometry. `sim/tb_l2norm_rs.vhd`, `sim/tb_rmsnorm_bf.vhd`,
`sim/tb_gdn_head_emit.vhd` and `sim/tb_gdn_scalar.vhd` match the card exactly.
`sim/realshape_gate.sh` already exists and already elaborates `llama_top` and
`attn_kv_axi` at the card's KV geometry to check the guards fire.

## 6. MEASURED AND REJECTED -- DO NOT RETRY

- **"The RoPE twiddle table above index 7 is dark."** REJECTED. The reasoning
  was sound as far as it went: every `tb_llama_top_*` bench runs `N_ROT` at 8
  or 16, so `NPAIR` is 4 or 8, and the card's 64 gives 32, leaving
  `IMROPE_W(8..31)` unreached by any integration bench. **But
  `sim/tb_attn_twiddle.vhd:53` defaults `NPAIR := 32`**, and its header records
  that `ref/attn_twiddle_vec.c` RECOMPUTES the constants from libm rather than
  reading `rtl/imrope_pkg.vhd`, so a drift is a bit-exact failure on the first
  vector. The unit bench covers what the integration benches cannot. Do not
  plant a mutation in `imrope_pkg` expecting it to survive.
- **"Mutate `rtl/attn_kv_axi.vhd` to demonstrate the `C_KV_AXI` no-op."**
  REJECTED as a demonstration, though the claim is true. The module is not
  instantiated at all in the `gkvmem` arm, so the "mutation survives" result is
  a tautology that `grep` establishes for free at
  `rtl/llama_top.vhd:6750,6875`. Spending two 300-second bench runs to
  re-derive a one-line grep is not evidence, it is theatre. `FAST_POP` was
  chosen instead precisely because it is a plain boolean condition INSIDE a
  process shared by both arms, where the no-op is not obvious.
- **"`sim/tb_gdn_state_store.vhd` running `PIPE=false, WIDE=false,
  NWIDE=false` is the largest uncovered divergence in the tree."** REJECTED,
  see section 7.
- **The 2.13 GiB full-gate figure as a budget.** Not retried and not needed.
  Every run in this file is a targeted `--only` row; the largest, the
  `tb_llama_top_seq` baseline, is a 302-second row.

## 7. CORRECTIONS

### CORRECTION, same day, to my own delegated sweep

A subagent I dispatched to sweep the B and A benches reported as its headline
finding that `sim/tb_gdn_state_store.vhd` "runs the opposite arm on four
sub-memories at once" (`PIPE=false, WIDE=false, NWIDE=false` against the
card's three trues at `rtl/fk33_llama_top.vhd:6172-6175`), calling it "the
largest divergence in the whole audit". In the same report it listed
`sim/tb_bmover_phases.vhd` under "things I could not determine cheaply",
with the note *"references `B_STATE_AXI`/`B_CONST_HBM` but I did not open
it"*.

**I opened it. MEASURED, `sim/tb_bmover_phases.vhd:73,74,80`: `PIPE := true`,
`WIDE := true`, `NWIDE := true`, and `CONST_EN := true` at :65.** Its header
states it composes `gdn_job_seq` + `gdn_state_store` *"at the 9B geometry,
exactly as `rtl/llama_top.vhd`'s `gen_st_tier` wires them"*, and that the
stand-in `gdn_block` *"reads back every state word, exponent, tap and constant
the load delivered and checks them against the images the slave was
initialised with"*, i.e. it is an ORACLE and not only a stopwatch. **The
card's B mover arms are covered.** The residual difference is `MAXOUT=4`
against the card's 8.

The claim is withdrawn. It is left here rather than deleted because it is an
instance of the exact failure this audit is about, committed by this audit:
**a conclusion about coverage drawn from the set of files that were read,
reported with the unread file named on the same page.** The unread file was
the one that overturned it. Ruling out one candidate promotes nothing, and
"I did not open it" is not a small caveat when the finding is an absence.

The other subagent finding that did survive checking is that `FAST_POP` is
false in every A bench, which is section 5.2, and `DUAL_CLK` is false in all
but three.

## 8. MEASUREMENT TRAPS HIT

- **`set_true_sites=0` over-reported holes by a factor of two and a half.**
  Four of the ten zero rows in section 5.1 are the bench entity using a
  DIFFERENT NAME for the card's generic (`KV_AXI` for `C_KV_AXI`, `XEXP_PORT`
  for `USE_XEXP_PORT`, `A_DESC_G` for `A_DESC`). This is CLAUDE.md's recorded
  `a_job_index` trap exactly: a null grep for one spelling is not evidence
  about the design. Every zero was followed up by reading the entity before it
  was reported, and six of ten did not survive.
- **The generator's Python literals are not the card's configuration.**
  `hw/fk33/gen_fk33_card.py` rewrites its own `ARGS` list from `FK33_*`
  environment overrides after the literals are declared, and its own comments
  say `check_kv_map.py` then validates the DEFAULTS while the build uses the
  trimmed values. Reading the generated `hw/fk33/rtl/fk33_card.vhd` sidesteps
  this entirely, and the generator itself recommends exactly that grep.
- **A bench that wraps a parametrised bench entity hides the comparison.**
  `sim/tb_llama_top_seq.vhd` instantiates `work.tb_llama_top`, not
  `work.llama_top`, so grepping the bench for `C_KV_AXI` finds nothing while
  the bench does set it, under the name `KV_AXI`, at `sim/tb_llama_top.vhd:1473`.
- **Mutating a file in the shared working tree would have corrupted three
  other tracks' gates.** The whole demonstration ran in a `git archive HEAD`
  copy under `/mnt/storage`, and `git status --porcelain` on
  `rtl/async_fifo.vhd`, `rtl/matvec_int4_desc_axi.vhd`, `rtl/stream_fifo.vhd`
  and `sim/regress.sh` was empty at the end.
- **Scratch is on `/mnt/storage`, not `/tmp`**, per the 2026-09-20 incident in
  CLAUDE.md.

## 9. OPEN, NOT DETERMINED

- **`HOST_WINDOW` has no bench and probably cannot have one at `llama_top`
  level.** The card sets it false; the default is true; zero benches name it.
  `rtl/region_mem.vhd`'s comment says the false arm lets the banks infer BRAM
  and makes `hr_data` read zero, and `sim/tb_llama_top.vhd` reads its results
  THROUGH `hr_data`. So the card's arm may be structurally unobservable to the
  existing bench design. **Not established either way**, and not attempted.
- **Whether the `FAST_POP` no-op has already cost anything on silicon.** The
  lever is ON in build 11b right now. This audit shows the arm is unverified;
  it does NOT show it is wrong. `sim/ooc_aidle_run.sh` prices its area and says
  nothing about its values.
- **POSW = 17 is run by no harness** (section 5.4). No consequence established.
- **The `sim/*.tcl` table is DERIVED, not MEASURED.** It was read out of the
  scripts; nothing was synthesised, because no Vivado was permitted. In
  particular `ooc_micro.tcl`, `ooc_pnr.tcl`, `ooc_micro_pnr.tcl`,
  `ooc_mover_paths.tcl` and `ooc_levercost.tcl` take their top and generics
  entirely from argv or env, so their shape is NOT KNOWABLE from the file, and
  most of the project's quoted card leaf numbers came from `ooc_micro`.
- **`sim/elab_cardtop.tcl` elaborates `fk33_llama_top` at ALL DEFAULTS** -- all
  nine arm booleans false, `HOST_WINDOW` true, the scaled KV geometry. DERIVED
  from reading it. Whether any currently-quoted number came from it was not
  traced.
- **Cell B of the 2x2 is one mutation at one site.** It establishes that THIS
  defect is invisible, not that every `FAST_POP` defect is.
- No `tb_*` coverage claim here was checked against `sim/*.sh` wrappers that
  might pass `-g` overrides; `sim/Makefile` has none, which is not the same as
  none existing.

---

# TRACK POPCOVER, 2026-09-20 -- the FAST_POP arm now has coverage, and it is SOUND

Branch `fpga`, HEAD `92ba3ec` (this file's own commit) at start. No hardware.
No Vivado anywhere: the workstation lane was on build 11b and the BC-250 on
TRACK HDRCOST. Every mutation ran in an ISOLATED `git archive HEAD` tree at
`/mnt/storage/fk33_builds/scratch/popcover/tree`, never in the shared working
tree; the bench edit itself landed in the repo and was gated there.

## 10. THE QUESTION, VERBATIM

> **Give the `FAST_POP = true` arm real coverage, at the lowest level that
> closes the cone, and report honestly whether it is sound -- build 11b ships
> `FAST_POP = true` and Oren will load it onto the live card.**

Section 9 above left it open: *"Whether the `FAST_POP` no-op has already cost
anything on silicon ... This audit shows the arm is unverified; it does NOT
show it is wrong."*

## 11. THE ANSWER, UP FRONT

**THE `FAST_POP` ARM IS SOUND. Nothing found here argues against loading build
11b's bitstream.** MEASURED: with the arm instantiated at all eight clock
ratios, every property the bench has -- the value-and-order oracle, the
`w_level >= occupancy` safety guarantee, occupancy within `DEPTH + OUT_MARGIN`,
no beat accepted during a clear, the four-phase clear with residue resident,
write-only / read-only / skewed reset recovery, the full drain accounting, and
both coverage asserts -- passes at `FAST_POP = true` exactly as it does at
false, on a first run, with **zero** changes to `rtl/async_fifo.vhd`.

Two numbers carry most of that. `maxocc` is **18/16** in BOTH arms, so the fast
arm reaches the same `DEPTH + 2` capacity and no more; and `minslack` is **0**
in both arms with **zero** `w_level UNDER-STATES` reports, so the AR throttle's
one safety guarantee still holds with exactly zero slack under the faster
cadence. That was the one thing that could have broken, because `OUT_MARGIN`
and the `+1` were DERIVED against the shipping arm's `(ocnt + inflight) < 2`.

**The equivalence claim holds and the lever works.** MEASURED, on all seven
ratios at `DEPTH >= 16`, with no scatter at all: the shipping arm takes **15**
read cycles to deliver 10 beats and the `FAST_POP` arm takes **10**. Same
values, same order, 1.5x the rate -- which is the silicon slope
(1.5101 core cycles per weight word, section 4.1 of
`docs/2026-09-20_d-side-vector-traffic.md`) reproduced in simulation.

**But the arm was unverified by a much wider margin than section 5.2 showed.**
Ten mutations of the read-issue logic were planted. **NINE of the ten survived
the bench as it stood at `92ba3ec`**; the single exception (P8) is not
arm-specific. After this track, nine of the ten are caught and the tenth is a
provable no-op.

**And one defect was found that is not about `FAST_POP` at all** (section 15):
the clear was only ever entered with nothing in flight, so a mutation that
strands an in-flight read across the park survived every arm. Under `FAST_POP`
a read is in flight on essentially every read cycle, so that is the card's
normal state.

## 12. THE LEVEL, AND WHY

`sim/tb_async_fifo.vhd` was EXTENDED; no bench file was added.

- It is the dedicated bench for the file that carries the arm, so it is the
  lowest level at which the cone closes. A composed bench would have paid the
  27-port geometry to observe one boolean.
- **The gate-row hazard decided it.** A new `sim/tb_*.vhd` is auto-discovered
  and becomes a row for every track on every run. Extending an existing row
  adds none. MEASURED cost of the extension as a gate row: **1 s**
  (`PASS sim:tb_async_fifo 1s`), against 0 s before, and the honest end time
  moved 76.03 us -> **83.44 us**, still 24x inside the row's `--stop-time=2ms`.
- The bench already had the right oracle. It writes a strictly increasing
  counter and checks it against an independently maintained counter in the read
  domain, with drop / duplicate / reorder as three separate diagnostics. That is
  a value-AND-order oracle and not a round trip, so the equivalence claim needed
  the arm instantiated, not a new checker.

The eight ratios were factored into one `af_ratios` block and instantiated
twice, **same ratios, same seeds, both arms**. `sim/regress.sh` was NOT touched.

## 13. THE ORACLE, AND THE SECOND ONE THAT HAD TO BE ADDED

**Oracle 1, values and order: already there, now run on both arms.** "The same
values in the same order come out of either arm" is checked beat by beat
against a counter the FIFO never supplied.

**Oracle 2, the cadence: new, and it is the one that earns its keep.** A value
oracle can only ever prove the lever HARMLESS; it can never prove it PRESENT,
because `FAST_POP` changes no value by construction. `cadence_probe` stocks the
FIFO, STOPS the writer, waits for it to be idle, opens the reader flat out and
times the drain from the FIRST beat consumed. With the writer stopped the window
contains nothing but the read side's own issue condition -- no write clock, no
clock ratio, no stimulus density.

DERIVED, from the two conditions: with `q_ready` high and the FIFO non-empty,
`(ocnt + inflight) < 2` settles into a period-3 orbit with two pops in it,
because the beat leaving the output stage this edge is still counted as
resident; `after_e < 2`, where `after_e` IS the post-edge occupancy, holds
`ocnt` at 1 with one read always in flight and pops every cycle. So CAD_N = 10
beats take 15 and 10 read cycles.

MEASURED, and it is a CONSTANT and not a mean -- **10 and 15 exactly, on all
seven eligible ratios**, including coincident edges, a quarter-period offset,
the 7000/6999 slide and the throttled case. The thresholds (fast must be <= 11,
slow must be >= 13) sit in that five-cycle gap. The check is **TWO-SIDED**, so
both "the lever is not threaded" and "the lever is wired on unconditionally"
fail, and neither is visible to any value oracle.

It is skipped below `DEPTH` 16: at `DEPTH` 4 the FIFO holds 6 beats, CAD_N must
fall to 3, and 3 against 4.5 does not separate the arms. **`tiny` is a value row
in both arms and a cadence row in neither**, stated so it is not mistaken for
coverage.

## 14. THE MUTATION TABLE, WITH TEETH AND THE ATTRIBUTION CONTROL

Fifteen mutations, class `POP` in `sim/mutate_async_fifo.sh`. Three columns were
run during the investigation and two of them are now STANDING in the harness:

- **A** -- the bench at `92ba3ec` (one arm, no cadence). The attribution control
  for "did the old bench already catch this".
- **B** -- the new bench with `-gCADENCE=false`: both arms, every pre-existing
  property, the cadence check REMOVED. This is the attribution control CLAUDE.md
  requires and the harness runs it on every class-`POP` row, printing the credit
  on its own line.
- **C** -- the new bench as the gate runs it.

| row | what it breaks | A (`92ba3ec`) | B (both arms, no cadence) | C (gate) | credit |
|---|---|---|---|---|---|
| Z0 | impossible anchor (self-teeth) | BADMUT | BADMUT | BADMUT | required outcome |
| A0 | a no-op edit inside a string literal | SURV | SURV | SURV | must survive |
| P1 | SHAPEAUDIT's `after_e < 4` | **SURV** | ABORT `:431` | ABORT | pre-existing |
| P2 | `after_e < 3` (O1's fast twin) | **SURV** | ABORT `:431` | ABORT | pre-existing |
| P3 | `after_e < 1` -- safe, and SLOWER than the arm it beats | **SURV** | KILL (coverage) | KILL (cadence) | **pre-existing** |
| P4 | **the lever INVERTED** | **SURV** | **SURV** | KILL | **the cadence check** |
| P5 | **the lever NOT THREADED** | **SURV** | **SURV** | KILL | **the cadence check** |
| P6 | **the lever WIRED ON** | **SURV** | **SURV** | KILL | **the cadence check** |
| P7 | `after_e` drops `inflight` | **SURV** | ABORT `:431` | ABORT | pre-existing |
| P8 | `after_e` drops its `ocnt > 0` guard | ABORT `:379` | ABORT | ABORT | pre-existing |
| P9 | `after_e` drops `q_ready` | **SURV** | ABORT `:431` | ABORT | pre-existing |
| P10 | `do_rd` drops the clear term | **SURV** | **SURV** | **SURV** | survivor, see 16 |
| P11 | the clear strands an in-flight read | **SURV** | KILL | KILL | **the new phase 5b** |
| P12 | `q_data` from the WRITE pointer | KILL | KILL | KILL | pre-existing |
| P13 | `rp` advances on LAND, not ISSUE | KILL | KILL | KILL | pre-existing |
| P14 | the memory read gated on `do_rd` | **SURV** | **SURV** | **SURV** | survivor, see 16 |
| P15 | the output stage collapses to one entry | KILL | KILL | KILL | pre-existing |

**Read column A first.** Eleven of fifteen survived the bench this file's own
section 5.2 was measured against; restricted to the read-issue logic proper
(P1..P10) it is **nine of ten**. That is the size of the hole, and it is much
larger than one mutation at one site.

**Read the credit column second, because it is the honest part.** The cadence
check is credited with **three** rows and not four. P3 dies in column B as well,
under the pre-existing `max_occ < DEPTH + 2` coverage assert, so without the
control this table would have claimed four detections for a check that earns
three. The three it does earn -- P4, P5, P6 -- are the pure lever-wiring
defects. They change no value in either arm, and **every other oracle in the
file, including the value-and-order oracle and the arm instantiation itself,
reports 0 errors on all three.**

**Attribution for the ARM as distinct from the CHECK**, read out of which case
names appear in the diagnostics. On P3 every firing case is `fast/*` (8 of 8),
so the arm is what makes it visible. On P11 the firing cases are 7 of 8 `fast/*`
and 3 of 8 `slow/*`, so the new PHASE catches it and the arm roughly doubles
the detection rate.

**Teeth on the harness itself, both directions** (MEASURED in a scratch copy,
never in the repo):

```
honest                       Z0 BADMUT ... kill ratio 37 of 49   exit 0
Z0 given a REAL anchor       Z0 SURVIVED ... HARNESS FAILURE: row Z0 was run
                             and did NOT report BADMUT              exit 1
O5 given an impossible one   O5 BADMUT ... HARNESS FAILURE: 1 anchor(s)
                             matched zero times                     exit 1
```

Harness totals: **37 of 49 (27 KILLED + 10 ABORT), 11 SURVIVED**, 29 s,
exit 0. Before this track it was 33 rows with row O1 dead.

## 15. THE DEFECT THAT WAS NOT ABOUT FAST_POP: A CLEAR WITH NOTHING IN FLIGHT

Row **P11** leaves `mem_q_v` SET across the read side's park -- the narrow half
of the existing row C3 -- so a read still in flight when the clear arrives lands
AFTER the park and strands a stale beat. **It survived every arm.**

The reason is the bench's own phase 4: it stocks the FIFO with the reader
STOPPED (`r_dens <= 0`), so the output stage is saturated, `do_rd` has been low
for many cycles when the park arrives, and **nothing is ever in flight across
it**. The only clear the bench had ever run was the one shape in which P11 is
inert.

`PHASE 5b` was added: both sides run flat out INTO the clear, with the reader
NOT stopped first. P11 is now killed in both arms, at 7 of 8 fast ratios and
3 of 8 slow ones. **Under `FAST_POP` a read is in flight on essentially every
read cycle, so the card runs the state this bench had never entered** -- which
is the same finding as section 5.2 in a different place: a coverage hole hiding
behind a configuration nobody ran.

## 16. MEASURED AND REJECTED -- DO NOT RETRY, AND THE SURVIVORS

**Two mutations do NOT bite and BOTH are reported under their own names,
because they measure this bench's resolution floor and both turn out to be
PROOFS rather than gaps.**

- **P10 -- `do_rd` drops its `clr_r_s2 = '0'` term. SURVIVES, correctly.**
  `do_rd` is consumed ONLY inside `rproc`'s ELSE branch, which is exactly the
  branch `clr_r_s2 = '1'` takes over, so the term is redundant by construction.
  This is the same shape as the existing row F5. Do not add a check for it; it
  is not a defect and a check that killed it would be wrong.
- **P14 -- the memory read is gated on `do_rd` instead of issued every cycle.
  SURVIVES, correctly.** `mem_q` is consumed only under `mem_q_v`, which is
  `do_rd` one cycle late, so the ungated read is dead work and the two forms are
  equivalent. It is an area/power question, not a functional one.

**REJECTED: extending the cadence probe to `DEPTH = 4`.** At `DEPTH` 4 the FIFO
holds 6 beats, so CAD_N falls to 3 and the two arms are 3 cycles against 4.5.
That gap is smaller than the start-up jitter the probe deliberately excludes,
and a threshold inside it would fire on honest RTL. `tiny` stays a value row.

**REJECTED: a paired two-DUT comparator** (one FIFO per arm, same stimulus,
outputs compared beat for beat). It sounds like the sharper equivalence test and
it is weaker: the stimulus is back-pressure-driven, so the two arms diverge in
their offer pattern within a few cycles and the comparator would be comparing
two different input sequences. The monotone-counter oracle already compares each
arm against an independent model, which is the stronger form and is
stimulus-independent.

**REJECTED: touching `rtl/async_fifo.vhd`.** Nothing needed changing; the file's
md5 is unchanged at both ends of every gate window in this section.

## 17. CORRECTION, and it is to a claim in `sim/tb_async_fifo.vhd`

The coverage-assert comment said the `DEPTH + 2` bound is what resolves
mutations F3 and G6. **For F3 that is WRONG, and it was wrong before this
track touched anything.** MEASURED at `92ba3ec`, in an unmodified `git archive`
tree: `ONLY=F3 bash sim/mutate_async_fifo.sh` reports `1 SURVIVED`, with
`maxocc=18/16` on every `DEPTH`-16 ratio. G6 is killed as claimed.

DERIVED reason: `full_r` is REGISTERED and computed from `used_w(n)`. Moving its
threshold from `DEPTH` to `DEPTH-1` without also moving the look-ahead arm still
leaves `full_r` low in the cycle `used_w = DEPTH-2`, so that cycle's write
carries `used_w` to `DEPTH-1` and the next one to `DEPTH`. **F3 costs no
capacity at all, which is why nothing sees it.** The claim was self-consistent,
was never re-run, and is corrected in place rather than deleted.

## 18. MEASUREMENT TRAPS HIT

- **A mutation anchor had already gone dead under this exact lever, silently.**
  Row **O1**'s anchor was `and (ocnt + inflight) < 2 else '0';`, which stopped
  existing the moment `do_rd` grew its `FAST_POP` arm. It reported
  `ANCHOR FAILED -- tested nothing` from that commit onward -- honest, and still
  a row that measured nothing. `sim/mutation_harness_wiring.tsv` (TRACK MUTWIRE)
  recorded it as `DEADROWS O1` the same day, independently. It is repaired here
  and its anchor is now **scoped in CODE**: the `(not FAST_POP)` guard is part
  of the matched text, so it cannot silently start matching the other arm.
- **An exit-code guard gated on the wrong variable passes for the wrong
  reason.** The Z0 verdict was first gated on `[ -z "$ONLY" ]`, so
  `ONLY=Z0 bash sim/mutate_async_fifo.sh` with Z0's anchor made REAL exited
  **0** -- the teeth test for the guard reported success while the guard was
  inert. It is now gated on `Z0TRIED`, recorded before the patch is attempted,
  and the teeth test above is the run that shows it discriminates.
- **A backtick in a bash description string runs a command.** P10's description
  originally contained `` `else` `` inside a double-quoted argument; bash ran it
  as a command substitution, printed a syntax error to stderr and silently
  deleted the word from the table. Caught only by reading the run's stderr.
- **`regress.sh`'s recorded honest end time for this row is now stale.** It says
  `tb_async_fifo 76.03 us`; the two-arm bench ends at **83.44 us**. The
  `--stop-time=2ms` backstop is still 24x that, so no action is required and
  `sim/regress.sh` was deliberately NOT edited -- three tracks were gating and
  bash re-seeks a running script by byte offset.
- **Scratch is on `/mnt/storage`, never `/tmp`.**

## 19. OPEN, NOT DETERMINED

- **This is the FIFO in isolation.** It says nothing about `axi_rd_port`,
  `weight_streamer` or `matvec_int4_desc_axi` behaving correctly against the
  faster cadence, and nothing at all about the 27-port composition where the
  array accepts a word only when all 27 ports present a beat in the same cycle.
  `sim/tb_matvec_fk33_desc_dual` is the only A bench at `DUAL_CLK = true` and it
  still runs `FAST_POP` at its default of false. **Not attempted here** -- it is
  a different file and a different track's cone.
- **`HOST_WINDOW` is still uncovered** (section 9), and nothing here touched it.
- **POSW = 17 is still run by no harness** (section 5.4).
- **Whether `FAST_POP` has ALREADY cost anything on silicon is still not
  answered, and cannot be answered from here.** What IS now established is that
  the arm computes the same values in the same order as the shipping arm, at
  1.5x the rate, with the throttle's safety guarantee intact. A silicon
  discrepancy, if one appears, is not in this FIFO's read-issue logic.
- **The cadence thresholds are calibrated on seven points that all gave the
  identical pair (10, 15).** That is a constant, not a fit, and the two-sided
  bound has 1 and 2 cycles of slack. A future `OUT_MARGIN` or output-stage
  change would move it; the check would then fail loudly rather than silently,
  which is the intended direction.

---

# TRACK POPPORT, 2026-09-20 -- the 27-PORT RENDEZVOUS is sound at the card's arm

Branch `fpga`, HEAD `fbac64e` (TRACK POPCOVER) at start. No hardware, no
Vivado anywhere: the workstation lane was on build 11b and the BC-250 lane on
TRACK ELABCLASS. `free -g` before every run showed **14 GiB available, swap
13-14 of 31**, and the largest thing this track ran was a 1.6 s GHDL bench.
Scratch under `/mnt/storage/fk33_builds/scratch/popport`, never `/tmp`.

## 20. THE QUESTION, VERBATIM

> "Give the `FAST_POP = true` arm coverage at the port and stream level ...
> **The property to test is the RENDEZVOUS, not the port.** Per-port
> equivalence is POPCOVER's result. What is unverified is whether the 27-way
> simultaneous-beat condition still holds, whether any port can starve or run
> ahead, and whether the accept rate improves as the lever claims."

Section 19 above is where it came from: *"nothing at all about the 27-port
composition where the array accepts a word only when all 27 ports present a
beat in the same cycle."*

## 21. THE ANSWER, UP FRONT

**THE COMPOSITION IS SOUND. No defect was found, and build 11b's bitstream is
not implicated by anything in this section.**

MEASURED at the card's exact shape -- `ROWS_IF=48 / AXI_DW=256`, so
`NPORTS_W=24 + NPORTS_S=3 = 27` masters, `DUAL_CLK=true` so the per-port FIFO
is `async_fifo` with the real clock domain crossing, `FAST_POP=true`:

- **Values are unchanged.** Every word and every scale group is bit-exact
  against the two independent encodings of spec 6.5a the bench already had,
  under random per-port AXI stalls and random consumer back-pressure. Same at
  `FAST_POP=false` with `DUAL_CLK=true`, which is the attribution control that
  makes the pair mean anything.
- **The 24-way rendezvous costs NOTHING.** 21 accepts span **20 core cycles**
  at `FAST_POP=true` and **30** at false. 20 is EXACTLY one word per cycle
  over the 20 gaps and 30 is EXACTLY POPCOVER's 1.5 core cycles per beat. The
  ports do not drift out of phase -- a 24-way AND of ports that are
  individually two-cycles-in-three could have been far worse than 1.5, and
  that is the question a per-port result cannot answer.
- **The 3-way scale rendezvous follows, on its own different pop condition**
  (`s_take`, not `pop_w`): **20** fast, **29** slow.
- **No scatter at all.** The dual-clock and single-clock branches gave
  identical numbers on every arm. This is the "structural, not a mean" shape
  again: a constant, not something to fit.

**THE COVERAGE HOLE WAS REAL AND IS NOW CLOSED. Eight of seventeen mutations
are killed by the new cadence probe AND BY NOTHING ELSE** -- not by the
pre-POPPORT bench, and not by the new bench with its cadence bounds
neutralised. Three of those eight are the lever dropped at a single
forwarding site, which is what "a generic dropped anywhere between
`fk33_engine` and `async_fifo`" actually looks like in this tree.

## 22. THE LEVEL, AND WHY IT IS NOT `tb_matvec_fk33_desc_dual`

The brief named `sim/tb_matvec_fk33_desc_dual` as the starting point. It is
at the right geometry (27 masters) and the right `DUAL_CLK`, and it is where
section 5.2 demonstrated the 2x2. It is the wrong level for the RATE
property, and the reason is structural rather than a matter of taste:

- it is a value oracle end to end, and **a value oracle can only ever prove
  the lever harmless, never present**, because `FAST_POP` changes no value by
  construction (POPCOVER's phrasing; its table is the proof);
- its consumer is `matvec_core`, which cannot be shut and then opened flat
  out, so any cadence measured there is a property of the array's acceptance
  pattern rather than of the rendezvous;
- its window is the whole descriptor control plane.

The level actually chosen is **`weight_streamer`**, established from the RTL
and not from any document. It is the SMALLEST entity whose cone contains all
three of the things the property is about:

| thing | where | why it has to be inside |
|---|---|---|
| the per-port FIFO | `axi_rd_port` -> `async_fifo` / `stream_fifo` | the lever's mechanism |
| the fan-out to all 27 ports | `rtl/weight_streamer.vhd:207` and `:228` | "applied to some and not the others buys nothing" |
| the rendezvous | `all_v` (`:252`) and `s_allv` (`:284`) | the property itself |

`rtl/axi_rd_port.vhd` forwards `FAST_POP` at **two** sites, `:276` into
`stream_fifo` and `:397` into `async_fifo`, and the two are NOT textually
identical -- the second also carries `OUT_MARGIN`. A generic dropped from one
of them is invisible at the other's `DUAL_CLK`, so both branches are probed.
The card is the dual-clock one.

And `sim/tb_weight_streamer.vhd` already existed, already ran geometry A at
27 masters, and already had `ws_check` factored as a re-instantiable block.
**Extending it adds NO gate row**, which is the thing the brief was most
insistent about.

## 23. THE PROPERTY, STATED BEFORE IT WAS TESTED

Written into the bench header before any of it was run:

- **P1 VALUES.** Every accepted word is the 24 slices of the SAME word index
  in order, every scale group the 3 slices of the same superword, under the
  card's `FAST_POP=true` exactly as under false.
- **P2 RATE, WEIGHT SIDE.** With all 24 weight FIFOs stocked and the consumer
  flat out, the `all_v` rendezvous delivers one word per core cycle at true
  and one per 1.5 at false.
- **P3 RATE, SCALE SIDE, TIMED SEPARATELY.** The 3 scale ports pop on
  `s_take`, a different condition, so the lever reaching the weight ports is
  no evidence it reached the scale ports.

Timing the two streams separately is what gives "forwarded to every one of the
27" any teeth, and **row T2 below is the row that proves it was worth doing.**

## 24. THE CADENCE ORACLE, AND ITS TWO-SIDEDNESS

POPCOVER's shape, lifted directly. Phase 1 shuts the consumer and lets all 27
FIFOs stock to at least PN beats; phase 2 opens it flat out and times the
drain. **Nothing refills during the window** -- every port already holds what
it will deliver -- so the number contains the read side's own issue condition
and the rendezvous, and contains no AXI latency, no slave stall and no AR
throttle.

Three details that are not decoration:

- **The R-beat census that gates phase 1 runs in the AXI DOMAIN**, via the
  same `if DUAL then wait until rising_edge(aclk)` trick the slaves use.
  Sampling it on `clk` would miss or double-count beats at the 1.67x ratio
  and would open the window on a FIFO that was not stocked.
- **The error count lives in a VARIABLE**, because two `chk`-style increments
  in one delta collapse to one -- the recorded bench that reported 13 checks
  for a body containing 60.
- **The consumer is shut or flat out, never random**, or the stall
  generator's period would be inside the measured cadence.

**THE CHECK IS TWO-SIDED.** The fast instance fails if it is slow; the slow
instance fails if it is fast. One-sided would pass a build where the lever
does nothing (row P3) AND a build where it is wired on (row T6), and those
are two of the three defects POPCOVER showed no value oracle in this project
reports a single error on.

Bounds, MEASURED FIRST with the bounds off and only then written down:

```
dual   slow  weight 30  scale 29      dual   fast  weight 20  scale 20
single slow  weight 30  scale 29      single fast  weight 20  scale 20
```

- `FAST_MAX = PN-1 = 20` is the ideal EXACTLY, not a fitted number: a FIFO
  cannot emit more than one beat per cycle, so 20 is a hard floor and
  `<= 20` means `= 20`.
- `SLOW_MIN = 25` is deliberately NOT the measured 29/30. The question it
  asks is "is the shipping arm fast", and any threshold in (20, 29) answers
  it. 25 sits 5 above the fast ideal and 4 below the slower measurement.
- The scale side's **29 rather than 30** is explained (DERIVED; the 29 is
  MEASURED): `s_hold` is PRE-LOADED during the shut phase, because `s_take`
  fires once on `s_hv = '0'` with `s_ready` still low, so the window's first
  accept needs no pop and the first pop overlaps it.

## 25. THE MUTATION TABLE, WITH A STANDING TWO-LAYER ATTRIBUTION CONTROL

`sim/mutate_ws_fastpop.sh`, new, a `.sh` and not a `tb_*.vhd` so it adds no
gate row. **Every row is run against THREE benches**, because two things were
added on 2026-09-20 and a kill could belong to either:

- **OLD** -- the newest committed revision of the bench WITHOUT POPPORT's
  extension, found by walking back until the marker string is gone. Never
  `HEAD~`: a fixed offset would make OLD equal to NEW the day this commit
  lands, and every cadence row would then read "pre-existing". The control
  failing open is exactly the failure mode this file is about.
- **NOCAD** -- the new bench with the four cadence bounds neutralised. The
  card's arm is instantiated and its values are checked; nothing times it.
- **NEW** -- the whole thing.

MEASURED, 17 rows, 1 m 44 s wall clock, `free -g` 14 GiB available throughout:

| tag | file | OLD | NOCAD | NEW | credit | what the new bench saw |
|---|---|---|---|---|---|---|
| T1 | weight_streamer | SURV | SURV | KILL | **CADENCE** | dual fast **30**/20 -- the 24 weight ports lost the lever, the 3 scale ports kept it |
| T2 | weight_streamer | SURV | SURV | KILL | **CADENCE** | dual fast 20/**29** -- the mirror image, and only the SEPARATE scale timing sees it |
| T3 | axi_rd_port `:397` | SURV | SURV | KILL | **CADENCE** | dual fast **30/29**, single fast 20/20 -- THE CARD'S BRANCH alone |
| T4 | axi_rd_port `:276` | SURV | SURV | KILL | **CADENCE** | dual fast 20/20, single fast **30/29** -- the other branch alone |
| T5 | weight_streamer | SURV | SURV | KILL | **CADENCE** | lever INVERTED at both sites: slow arm 20/20, fast arm 30/29 |
| T6 | weight_streamer | SURV | SURV | KILL | **CADENCE** | lever WIRED ON: every arm 20/20. Caught by `SLOW_MIN` ONLY |
| R1 | weight_streamer | KILL | KILL | KILL | pre-existing | 24-way AND drops port 0: 7 words wrong |
| R2 | weight_streamer | KILL | KILL | KILL | pre-existing | pop ignores `w_ready`: wrong word 2, then hung |
| R3 | weight_streamer | KILL | KILL | KILL | pre-existing | 3-way scale AND drops a slice: 20 wrong |
| R4 | weight_streamer | KILL | KILL | KILL | pre-existing | `s_take` loses `s_ready`: wrong group 0, then hung |
| P1 | async_fifo | SURV | KILL | KILL | card-arm | SHAPEAUDIT's `after_e < 4`: bound check failure |
| P3 | async_fifo | SURV | SURV | KILL | **CADENCE** | fast arm commits ONE: dual fast **40/39**, SLOWER than the shipping arm it exists to beat |
| P5 | stream_fifo | SURV | SURV | KILL | **CADENCE** | the same undoing in the other FIFO: single fast **40/39** |
| P6 | async_fifo | SURV | KILL | KILL | card-arm | SHIPPING arm widened to three: bound check failure |
| S1 | async_fifo | SURV | KILL | KILL | card-arm | POPCOVER's P2 (`after_e < 3`): bound check failure |
| S2 | axi_rd_port `:397` | SURV | SURV | **SURV** | **SURVIVES** | `OUT_MARGIN + 1` in g_dc only |
| S3 | async_fifo | SURV | SURV | **SURV** | **SURVIVES** | shipping arm made SLOWER: dual slow **60/58**, reported and deliberately not failed |

```
 rows 17   pre-existing 4   card-arm 3   CADENCE 8   SURVIVED 2
```

**WHAT THE CONTROL COST, which is the reason to run it.** Seven rows would
have been credited to the cadence probe on a naive reading -- they all fail
the NEW bench. Four (R1-R4) were already caught by the pre-POPPORT bench and
the probe is worth nothing on them; three (P1, P6, S1) are caught by merely
INSTANTIATING the card's arm, with no timing involved at all. Without the
NOCAD column, "eight cadence kills" would have been written as fifteen.

**T6 is the row that justifies two-sidedness on its own.** Every arm reads
20/20, every value is correct, and a one-sided "is the fast arm fast" check
passes it cleanly. What it describes is a build where every non-FK33
instantiation silently changed cadence.

**T2 is the row that justifies timing the two streams separately.** The
weight side reads a perfect 20 and only the scale side's 29 gives it away.

## 26. THE SURVIVORS, UNDER THEIR OWN NAMES

CLAUDE.md: *"Report mutations that do NOT bite under their own names -- they
measure your check's resolution floor and are the most valuable line in the
table. Never discard one."* Neither of these should be given a check here.

- **S3, `(not FAST_POP) and (ocnt + inflight) < 1` -- A PROOF, not a gap.**
  It makes the SHIPPING arm slower, and the bench MEASURED it: `dual slow
  60/58` against the honest 30/29, printed in the summary line and
  deliberately not failed. The two-sided check asks "is the shipping arm
  FAST", never "is it exactly 1.5". **A check that killed this row would be
  asserting a cadence nobody has argued for**, and would turn every future
  latency change in the shipping arm into a red gate for no stated reason.
  The row exists to pin that the omission is a decision.
- **S2, `OUT_MARGIN + 1` in the g_dc branch only -- A GAP, and a scoped
  one.** It breaks the agreement `rtl/axi_rd_port.vhd:144` states outright,
  that `LVL_MARGIN` is "stated once here and passed to BOTH the FIFO and the
  FSM ... so they cannot drift apart". This bench cannot see it because this
  bench is **never capacity-bound**: 24 beats into a 64-deep FIFO, so the AR
  throttle never binds and an over-stated `w_level` never matters. **Making
  it capacity-bound to catch S2 would change what the bench measures**, and
  the instrument for that defect already exists and already runs both arms --
  POPCOVER's `minslack` in `sim/tb_async_fifo.vhd`, MEASURED at 0 with zero
  under-statement reports. Left alone on purpose.

## 27. WHAT CHANGED

- **`sim/tb_weight_streamer.vhd`, EXTENDED, not replaced.** `ws_check` gains
  `DUAL`, `FASTP`, `PROBE` and `PN` generics plus an `aclk` port, all
  defaulted so the two original instances are bit-identical. Six new
  instances, all at geometry A's 27 masters: two value arms at
  `DUAL_CLK=true` (`FAST_POP` false and true, the second being the card), and
  four cadence probes (dual and single clock, slow and fast).
  **No new gate row.** The only `sim/tb_*.vhd` this track touched is
  MODIFIED, not added -- `git status` shows ` M sim/tb_weight_streamer.vhd`
  and no new `tb_` file from POPPORT -- and rows are discovered from
  `sim/tb_*.vhd`, so the row set cannot have moved. The new harness is a
  `.sh`: `regress.sh --only mutate_ws_fastpop` returns `OVERALL PASS 0`,
  which is what a pattern matching nothing looks like.
- **The dual-clock arm cost five lines, not a duplicated process.** Every
  clock reference in the AXI slave already went through one `tick` procedure,
  so `if DUAL then wait until rising_edge(aclk); else ...` inside it is the
  whole change. No `sclk <= aclk when DUAL else clk` anywhere -- that costs a
  delta, and a delta-skewed clock is what silently broke
  `sim/tb_matvec_int4_ip` when `axi_rd_port` was first written.
- **`sim/mutate_ws_fastpop.sh`, new.** Four-file mutator with the three-bench
  attribution control. It is a separate harness from
  `sim/mutate_weight_streamer.sh` because that one mutates a single file and
  its parser reads the two original instances by name; a four-file mutator
  bolted on would have meant rewriting its parser, and a rewritten parser is
  a rewritten oracle.
- **Nothing in `rtl/` was touched.** MD5s of `weight_streamer.vhd`,
  `axi_rd_port.vhd`, `async_fifo.vhd` and `stream_fifo.vhd` are identical at
  both ends of the window, and so is `sim/regress.sh`.

**RUNTIME.** MEASURED, same machine, same command, `--stop-time=200us`:
**0.267 s before, 1.601 s after** -- `+1.33 s` on one gate row, which
`regress.sh` reports as `0s` -> `1s`. That buys four extra 27-master
instances and the whole cadence instrument.

## 28. MEASUREMENT TRAPS HIT

- **`--only` takes a SUBSTRING and a pattern matching nothing still prints
  `REGRESSION: PASS`.** Used deliberately here as the proof that the new
  `.sh` is not a gate row -- `--only mutate_ws_fastpop` gives `OVERALL PASS
  0`. The count is the only tell and it was read every time.
- **`regress.sh` checks the exit code BEFORE the pass marker** (`if [ "$rc"
  != "0" ]` precedes the marker scan). That is load-bearing here: the bench
  prints `0 reassembly errors across both geometries` and THEN asserts the
  cadence bounds, so a cadence failure still scores FAIL and not PASS. The
  marker string was not changed, and `sim/regress.sh` was not edited at all.
- **A cadence miss is never folded into the "reassembly errors" counter.**
  Calling it a reassembly error would be a lie, and it would also have made
  the marker line the verdict for two different properties.
- **The OLD control cannot be `HEAD~`.** Written that way first; it would
  have silently become NEW the moment this work committed. It walks back for
  the marker instead, and refuses to run rather than print a credit column it
  cannot stand behind.
- **The bounds were MEASURED with the bounds off before being written.**
  Setting them from the ideal first and then discovering the scale side reads
  29 rather than 30 would have produced a red gate attributed to the RTL.

## 29. OPEN, NOT DETERMINED

- **The DESCRIPTOR port's `FAST_POP` is outside this bench's cone entirely.**
  `rtl/matvec_int4_desc_axi.vhd` forwards the lever at `:628` and `:690`; only
  one of those is `weight_streamer`. Nothing here says anything about the
  other.
- **`sim/tb_matvec_fk33_desc_dual` still runs `FAST_POP` at its default of
  false**, and this track did not change that. Section 5.2's cell D is
  MEASURED evidence that the bench PASSES at `FAST_POP=true` -- but it was a
  manual run, not a gate row, so the full descriptor plane at the card's arm
  is demonstrated and not gated. Closing it means a new wrapper entity and
  therefore a new gate row at ~50 s, which is a deliberate cost somebody
  should decide on rather than a track absorbing quietly.
- **The real consumer is not modelled.** The probe's consumer is flat out;
  `matvec_core`'s is not. The claim is "the rendezvous can deliver one word
  per cycle", never "subsystem A will".
- **No AR-throttle or capacity-bound behaviour is reachable here**, by
  construction -- see survivor S2.
- **Nothing here is a silicon measurement.** It says the composition computes
  the same values at the card's arm and that the lever measurably reaches all
  27 ports. It does not say what build 11b achieves on the card.
- **The 27 ports were never made to starve.** The probe stocks every FIFO
  equally and the value arms stall them at random; no case deliberately holds
  one port empty for a long time while the other 26 are full. The rendezvous
  is a pure AND so this is believed safe, and "believed" is the right word
  for it.
