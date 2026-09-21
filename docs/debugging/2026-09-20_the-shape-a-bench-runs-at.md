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
