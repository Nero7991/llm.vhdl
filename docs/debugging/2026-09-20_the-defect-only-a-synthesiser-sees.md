# The defect only a synthesiser sees: enumerating the class, and scheduling the 49-second check

TRACK ELABCLASS, 2026-09-20. Branch `fpga`, HEAD `f58a075` throughout. Part
`xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, BC-250 lane (`cachyos-bc250`), released
by TRACK HDRCOST. No hardware: `synth_design -rtl` only -- no mapping, no
placement, no routing, no bitstream, no programming. The card was live and
serving the user throughout and was never touched. No Vivado on the
workstation; its lane was on build 11b.

---

## 1. The question, verbatim

TRACK HDRCOST's closing open item, quoted in this track's brief:

> "whether any other generic in the repo has the same elaboration-only failure
> mode -- **nothing enumerates the class and nothing schedules the 49-second
> discriminator**"

The observation behind it, MEASURED by HDRCOST the same evening: the first
Vivado ever aimed at `SCORE_HDR_TREE` killed `synth_design` in 49 seconds with
`ERROR: [Synth 8-11324] array index 8 out of range
[rtl/attn_score_q12.vhd:488]`, at `NBLK = 8`, the card's own geometry -- after
that lever had passed a 20-point bit-exact grid against two C oracles, a 23-row
mutation suite with attribution controls on every row, and five green gate
groups.

---

## 2. The answer, up front

**THE CLASS IS BOUNDED AND SMALL, AND THE CHECK THAT DISCRIMINATES IT COSTS 45
SECONDS TO 4 MINUTES A ROW.**

1. **Enumerated.** 98 entities in `rtl/` declare **869 generics**. The
   arm-selecting subset -- the generics that can change *which statements
   elaborate* -- is **43 boolean generic names** over `rtl/` and
   `hw/fk33/rtl/`. **22 of them have an arm that appears as a literal nowhere
   a synthesiser could have read it.** Four of the 22 sit on entities nothing
   instantiates (`attn_rescale_skel`, `attn_lane_skel`, `compose4_top`'s
   `CLK_BUFG`), and two more are bound by an OOC harness (`CONST_EN=true`,
   `USE_XEXP_PORT=true`), leaving **16 reachable arms that no synthesiser has
   ever been given.** Those numbers are not transcribed: they are the output of
   `sim/check_elab_rows.py`, which recomputes them from the RTL on every run.
   The integer generics are handled separately, by the one mechanism through
   which an integer *can* change elaboration: a loop bound feeding a statically
   folded index. **121 such sites exist, in 22 files**, and that number is a
   LEAD and not a defect count: **67 of them are already elaborated by the card
   build at the card's own values, and the other 54 are outside the card's
   entity closure entirely** -- 28 in `rtl/layer.vhd`, whose only instantiator
   is `rtl/seq_ctrl.vhd`, which nothing instantiates at all.

2. **Ranked, and the ranking is not by count.** The high-risk rows are the ones
   where a never-synthesised arm and a static-index site are in the same file:
   `SWG_WIDE`, `A_DRAIN_WIDE` and `NORM_ANCHOR` in
   `rtl/fk33_llama_top.vhd` (12 sites), and `WIDE_IO` in the unit `SWG_WIDE`
   drives. `gdn_recur_pipe.vhd` has 6 sites and its three never-synthesised
   booleans (`D_NORM`, `TK0_ED`, `EG0_ED`) rank **LOW anyway**, because reading
   the code shows they appear only in `if` conditions and in no loop bound and
   no array bound. That is the difference between counting and reading.

3. **Measured.** (Section 5.2 carries the table.)

4. **THE DELIVERABLE IS IN TWO HALVES, BECAUSE ONLY ONE OF THEM CAN BE A GATE
   ROW.**

   *The Vivado half*, `sim/elab_check.tcl` + `sim/elab_check_run.sh`: a
   fourteen-row table of `synth_design -rtl` runs at the card's geometry whose
   **first row is a teeth row that MUST FAIL**. It reproduces HDRCOST's exact
   error from the pre-fix blob at `e1d5898^`:
   `ERROR: [Synth 8-11324] array index 8 out of range [.../attn_score_q12.vhd:488]`,
   in **22 s of elaboration and 45 s of wall**, cgroup peak **3,001 MB** with
   the 11G cap never reached. **The cheap mode has teeth on the exact defect
   that created this track**, which was not assumed.

   *The gate half*, `sim/check_elab_rows.py`: it recomputes the census from the
   RTL and **fails when a reachable never-synthesised arm is neither in that
   row table nor in an EXEMPT list with a written reason.** It costs
   milliseconds and needs no Vivado. **The thing HDRCOST's lever needed someone
   to notice was an ABSENCE**, and a gate row cannot run Vivado but it can
   check that the absence has been acknowledged. Teeth in section 5.6.

5. **The Vivado half cannot run on every gate, and saying so is part of the
   deliverable.** MEASURED: the three `fk33_llama_top` rows cost **758 s** each
   and a DERIVED **about 33 GB** footprint (`memory.peak` 11,812,913,152 AT a
   `memory.high` of 11,811,160,064, so that figure is the CAP and not an
   appetite, beside `memory.swap.peak` 22,913,859,584). The leaf rows are
   **42-244 s** and **2.3-5.0 GB**, honest peaks well under the cap. So:
   **leaf rows nightly; the card-top rows before any `pcieep_build.sh` that
   changes a generic, and never beside another Vivado.**

**AND THE MECHANISM WAS ALREADY IN THIS REPOSITORY, TWICE, UNSCHEDULED.**
`sim/ooc_nwfix_elabcheck.tcl` (TRACK NWFIX, 2026-08-29) and
`sim/elab_cardtop.tcl` (TRACK CARDTOP, 2026-09-02) both already run
`synth_design -rtl` for exactly this reason, and `sim/ooc_compose4_run.sh` has
a `C4_STAGE=elab` mode documented as catching "every binding, width and
visibility error, in minutes rather than after an hour of synthesis". Each is
hard-wired to one top and one purpose, and **nothing schedules any of them.**
This track did not invent the check. It gave it a table and teeth.

---

## 3. What the class actually is, stated as a rule

A generic is in the class when changing its value changes **which statements
elaborate**, and the tool that elaborates is not the tool the gate runs.

* **GHDL evaluates the branch a run actually takes.** An index inside a branch
  no execution reaches is never computed and never checked.
* **Vivado unrolls every loop and folds every constant index statically**,
  whatever guards it.

So an index built only from loop variables and constants is checked by one tool
and not the other, and a run-time guard that makes it unreachable *protects the
simulation and not the synthesis*. That is HDRCOST's defect exactly, and it is
why its 20-point grid could not have seen it.

**The class has at least two distinct members, and only one of them is about
indices.** TRACK NWROM's 2026-08-29 finding is the other: at the real 9B shape
`rtl/llama_top.vhd`'s `NORM_W_IMAGE` loader failed elaboration on **Vivado's
per-loop-statement limit of 65,536 iterations**, which GHDL does not have at
all. Same shape of failure, different mechanism: *a real-shape property, in the
one tool that is not in the gate.* Anything that enumerates this class by
looking only for out-of-range indices is already one member short.

**And there is a third, recorded in CLAUDE.md, one level up:** a block-design
cell rejecting a `natural` port type and rejecting any function of a generic in
a port width. Neither is reachable by any bench either.

---

## 4. The procedure, in the order it ran, and what each step isolates

1. **Stage clean blobs, not a working tree.** 114 `rtl/*.vhd` from
   `git show HEAD:<path>` at `f58a075`, the two card image files
   (`norm_w_9b.hex`, `qkn_9b.hex`), and one deliberate mutant:
   `git show e1d5898^:rtl/attn_score_q12.vhd`, the pre-fix blob. Manifest
   sha256 **`dbf8f458c911fc22e53591fc4d662c28b6cacd12561caa2e6335950229eab274`**
   verified identical on both boxes before launch. Isolates: four other tracks'
   in-flight edits in the shared checkout.
2. **Enumerate the entity surface mechanically, not from documents.** 98
   entities, 869 generic declarations, parsed out of the staged `rtl/*.vhd`.
   Isolates: the recorded failure of searching for the word a document used
   (`a_job_index`) instead of the port the RTL declares (`u_index`).
3. **Census the BOOLEAN arms, because those are the ones that change what
   elaborates.** For each boolean generic name, the set of literal values it is
   bound to anywhere in `rtl/*.vhd` or `hw/fk33/rtl/*.vhd`, plus its declared
   default. Isolates: an arm that only *looks* covered.
4. **Guard the census against a FALSE NEGATIVE in the optimistic direction.**
   A map value that is another identifier (`C_KV_AXI => C_KV_AXI`) contributes
   NOTHING and is recorded as `passthru`; resolving it needs the hierarchy, and
   a wrong resolution toward "covered" is the error that matters. Section 6.
5. **Then widen the census with the OOC harnesses, separately and by hand**,
   because they are the other thing that has ever run `synth_design`. This step
   is what took the raw census's 22 down to 19, and it had to be a separate
   step: SHAPEAUDIT measured its own census over-reporting holes 2.5x for the
   mirror-image reason. 22 down to 20.
6. **Drop the arms on entities nothing instantiates.** The instantiation set is
   built from the same scan, so it is the RTL's own answer and not a grep for a
   name someone hoped existed. 20 down to **16**.
7. **Scan for the SHAPE, and treat the result as a LEAD.** A purely static
   index that grows faster than its loop variable. The filter's own control is
   `A_DRAIN_WIDE`'s group path, which indexes with `(rlane + i - lane0)` --
   both process variables -- and is correctly NOT in the class.
8. **Take the entity closure of the card's three tops** (`fk33_card`,
   `fk33_llama_top`, `fk33_engine`) and intersect it with the scan, because a
   site outside that closure is elaborated by no card build at any shape and
   must not be counted as covered. Isolates: the draft claim "every one of
   these sites already elaborates in the card build", which was wrong by 54 of
   121 and is corrected in section 5.4 rather than deleted.
9. **Run the discriminator on the top-ranked candidates, at the CARD's
   geometry**, with a teeth row and an attribution control BEFORE any candidate
   row, and with a row that must PASS in the same batch as every row whose
   verdict is the finding. Section 7.3 is why the last clause is not
   decoration.

---

## 5. The evidence, as raw output

### 5.1 The enumeration

```
ELABCLASS_ENTCOUNT entities_with_generics=98
ELABCLASS_GENCOUNT generic_declarations=869
ELABCLASS_STATIC   total_growing=266 purely_static=151 runtime_indexed=115
```

The boolean-arm census, verbatim from `python3 sim/check_elab_rows.py --list`.
It is not a transcription: the script recomputes it from `rtl/*.vhd` and
`hw/fk33/rtl/*.vhd` every run, which is what makes it a gate row rather than a
document.

```
generic                arm-unseen   status               entities
A_BEHAV                true         exempt               fk33_llama_top,llama_top
A_DESC                 -            both-arms-seen       fk33_llama_top
A_DRAIN_WIDE           true         elab-row             fk33_llama_top,llama_top
B_BEHAV                true         exempt               fk33_llama_top,llama_top,ooc_gdnadapt,ooc_gdnadapt_ss
B_CONST_HBM            -            both-arms-seen       fk33_llama_top,llama_top,ooc_gdnadapt
B_SRC_REAL             -            both-arms-seen       fk33_llama_top,llama_top,ooc_gdnadapt,ooc_gdnadapt_ss
B_STATE_AXI            -            both-arms-seen       fk33_llama_top,llama_top,ooc_gdnadapt
CHECK_JOB_INDEX        true         elab-row             fk33_engine,matvec_int4_desc_axi
CLAMP_NONNEG           -            both-arms-seen       matmul
CLK_BUFG               false        unreachable-entity   compose4_top
CONST_EN               true         ooc-covered          gdn_state_store
C_KV_AXI               -            both-arms-seen       fk33_llama_top,llama_top,ooc_cattnadapt_top
C_REAL                 -            both-arms-seen       fk33_llama_top,llama_top,ooc_cattnadapt_top
DEBUG                  true         exempt               rmsnorm
DEBUG_TAPS             true         exempt               engine_shared
DUAL_CLK               -            both-arms-seen       axi_rd_port,matvec_int4,matvec_int4_desc_axi,weight_streamer
D_NORM                 false        exempt               gdn_recur,gdn_recur_pipe
EG0_ED                 false        exempt               gdn_recur,gdn_recur_pipe
FAST_POP               -            both-arms-seen       async_fifo,axi_rd_port,fk33_engine,matvec_int4,matvec_int4_desc_axi,stream_fifo,weight_streamer
HOST_WINDOW            -            both-arms-seen       fk33_llama_top,region_mem
MUX_FLAT               false        unreachable-entity   attn_rescale_skel
NEOX                   true         exempt               rope
NORM_ANCHOR            true         elab-row             fk33_llama_top,llama_top
NORM_REAL              -            both-arms-seen       fk33_llama_top,llama_top,ooc_normadapt
NWIDE                  -            both-arms-seen       gdn_state_store
PIPE                   -            both-arms-seen       gdn_state_axi,gdn_state_store
PROBES                 false        exempt               attention_ml
REL_NAIVE              true         exempt               seq_opdec
RESCALE_ON_LANE        false        unreachable-entity   attn_lane_skel
SCORE_EARLY            -            both-arms-seen       attn_block
SEQ_MULT               true         unreachable-entity   attn_rescale_skel
SHOUT                  -            both-arms-seen       fk33_llama_top,llama_top,ooc_cattnadapt_top,ooc_normadapt
SMP_EN                 -            both-arms-seen       fk33_llama_top,llama_top
STRICT                 -            both-arms-seen       fk33_llama_top,fk33_seam,llama_top,ooc_cattnadapt_top,ooc_gdnadapt,ooc_gdnadapt_ss,seq_opdec,seq_region_lock,seq_vec_issue,seq_vec_res
STRICT_PRODUCER        -            both-arms-seen       attn_block,attn_c_ports_skel,attn_emit,attn_gate,attn_kv_quant,attn_mac_array,attn_recip,attn_rope,attn_score_q12,attn_softmax,attn_twiddle,gdn_block,gdn_emit_chain
STRICT_PROTO           true         exempt               seq_desc_fetch
SWEEP_PIPE             -            both-arms-seen       attn_block
SWG_REAL               -            both-arms-seen       fk33_llama_top,llama_top
SWG_WIDE               true         elab-row             fk33_llama_top,llama_top
TK0_ED                 false        exempt               gdn_recur,gdn_recur_pipe
USE_XEXP_PORT          true         ooc-covered          fk33_engine,matvec_int4_desc_axi
WIDE                   -            both-arms-seen       gdn_conv_tap_mem,gdn_conv_w_mem,gdn_exp_mem,gdn_state_axi,gdn_state_mem,gdn_state_store,region_drain
WIDE_IO                true         elab-row             swiglu_mem

ELABROWS PASS: 43 boolean generic names, 22 with an arm no synthesiser has been given, all accounted for (5 elaboration rows, 2 OOC-covered, 11 exempt, 4 on entities nothing instantiates).
```

**16 reachable never-synthesised boolean arms** = 22 with an unseen arm, minus
4 on entities nothing instantiates (`attn_rescale_skel`'s `MUX_FLAT` and
`SEQ_MULT`, `attn_lane_skel`'s `RESCALE_ON_LANE`, `compose4_top`'s
`CLK_BUFG`), minus 2 bound by an OOC harness.

**THE OOC-HARNESS STEP IS SEPARATE AND IS DONE BY HAND, DELIBERATELY.** Read
out of literals in the script text:

```
FAST_POP        both arms   sim/ooc_aidle.tcl, ooc_aidle_run.sh, ooc_levercost_run.sh
CONST_EN        =true       sim/ooc_bmover.tcl, ooc_bmover_run.sh, ooc_bnarrow_run.sh
USE_XEXP_PORT   =true       sim/ooc_levercost_run.sh, ooc_cbooc_run.sh
```

Without it `FAST_POP` reads as a hole, which it is not: TRACK POPCOVER
measured that arm on silicon-bound RTL and LEVERBOARD L-A carries its +1 LUT.
This is the mirror of the trap SHAPEAUDIT hit, whose census over-reported
holes 2.5x because bench entities used different generic names; here the
over-report would come from ignoring a different KIND of source. Every other
binding literal seen in a `sim/ooc_*` harness is recorded in
`hw/fk33/results/elabclass_2026-09-20/census/ooc_harness_bindings.txt` as a
LEAD -- several of those scripts take their top and their generics from argv or
env, so a literal there is not proof that any run ever used it.

### 5.2 The elaboration results

Every row is `synth_design -rtl` at the card's own generics, under
`systemd-run --user --scope -p MemoryHigh=11G` on the BC-250.

| row | top | what it binds beyond the shared control | expect | verdict | wall s | cgroup peak MB | at cap? | swap peak MB |
|---|---|---|---|---|---:|---:|---|---:|
| `teeth` | `attn_block` | SCORE_HDR_TREE=1, on the PRE-FIX blob `e1d5898^` | fail | **FAIL** | 45 | 3001 | no | not sampled |
| `c_base` | `attn_block` | SCORE_HDR_TREE=0 (the attribution control for `teeth`) | pass | **PASS** | 244 | 5025 | no | not sampled |
| `c_tree` | `attn_block` | SCORE_HDR_TREE=1, on HEAD (HDRCOST's one-line fix) | pass | **PASS** | 243 | 5028 | no | not sampled |
| `swg_base` | `swiglu_mem` | N=12288 LANES=1 WIDE_IO=false (control) | pass | **PASS** | 42 | 2403 | no | not sampled |
| `swg_w1` | `swiglu_mem` | N=12288 LANES=1 **WIDE_IO=true** | pass | **PASS** | 42 | 2402 | no | not sampled |
| `swg_w8` | `swiglu_mem` | N=12288 LANES=8 **WIDE_IO=true** | pass | **PASS** | 42 | 2380 | no | not sampled |
| `a_base` | `matvec_int4_desc_axi` | the engine cell's 12 generics, CHECK_JOB_INDEX=false (control) | pass | **PASS** | 123 | 3301 | no | not sampled |
| `a_chkjob` | `matvec_int4_desc_axi` | the engine cell's 12 generics, **CHECK_JOB_INDEX=true** | pass | **PASS** | 126 | 3308 | no | not sampled |
| `d_card` | `fk33_llama_top` | the card's 22 generics, exactly (the control every `d_*` row needs) | pass | **PASS** | 758 | 11265 | YES | not sampled |
| `d_hostwin` | `fk33_llama_top` | the card + **HOST_WINDOW=true** | pass | **PASS** | 785 | 11266 | YES | 21693 |
| `d_adw` | `fk33_llama_top` | the card + **A_DRAIN_WIDE=true** | pass | **PASS** | 779 | 11266 | YES | 21901 |
| `d_swgw1` | `fk33_llama_top` | the card + **SWG_WIDE=true SWG_LANES=1** | pass | **PASS** | 782 | 11265 | YES | 21726 |
| `d_swgw8` | `fk33_llama_top` | the card + **SWG_WIDE=true SWG_LANES=8** | pass | **PASS** | 777 | 11265 | YES | 21852 |
| `d_normanchor` | `fk33_llama_top` | the card + **NORM_ANCHOR=true** | pass | **PASS** | 798 | 11266 | YES | 21990 |

`at cap? = YES` means `cgroup memory.peak` reached `memory.high`
(11,811,160,064 B), so **that number is the throttle and not an appetite** and
is never quoted as a footprint. The six `fk33_llama_top` rows are all in that
state; add their swap and the DERIVED footprint is about **33 GB**. Every
other row finished well under the cap, so those peaks ARE appetites.

`swap peak` comes from each scope's own `memory.swap.peak`, sampled every 15 s
by `rows2/cgsample.log`, which started during batch 2 -- so the batch 1 rows
say **not sampled** rather than zero. `d_card`'s was read directly from its
live cgroup instead: `memory.swap.peak 22,913,859,584` beside
`memory.peak 11,812,913,152` and `memory.high 11,811,160,064`.

**EVERY ROW MATCHED ITS EXPECTATION, INCLUDING THE ONE THAT HAD TO FAIL.**
`ELABCLASS_ALLDONE rc=0`. The three `SWG_WIDE`/`A_DRAIN_WIDE` rows and the two
`WIDE_IO` rows are the ones LEVERBOARD records as having had **no synthesis of
any kind**; they elaborate. `d_hostwin` is a re-run, because my own first swap
guard killed the original (section 7.7).

### 5.3 The teeth row, verbatim

```
ELABCHK_BEGIN tag=teeth top=attn_block part=xcvu33p-fsvh2104-2L-e mode=rtl
ELABCHK_READ tag=teeth files=110 skipped=0 excluded=4 override=1
CRITICAL WARNING: [Synth 8-9872] overwriting existing secondary unit 'rtl' [/home/labuser/elabclass/mutant/attn_score_q12.vhd:244]
ERROR: [Synth 8-11324] array index 8 out of range [/home/labuser/elabclass/mutant/attn_score_q12.vhd:488]
ERROR: [Synth 8-285] failed synthesizing module 'attn_score_q12' [/home/labuser/elabclass/mutant/attn_score_q12.vhd:244]
ERROR: [Synth 8-285] failed synthesizing module 'attn_block' [/home/labuser/elabclass/rtl/attn_block.vhd:486]
ELABCHK_SECONDS tag=teeth elaborate=22 total=28
ELABCLASS_ROW row=teeth top=attn_block verdict=FAIL expect=fail wall_s=45 cgroup_peak_mb=3001 rc=1
```

This is HDRCOST's error, line for line, reproduced by a mode that stops after
elaboration. The `8-9872` CRITICAL WARNING is the override working as designed:
the mutant architecture displaces the clean one.

**Its attribution control is `c_base`: the same tree, the same geometry, the
lever OFF.** It PASSES. So the `teeth` failure belongs to the lever and not to
the harness, the mutant directory, or the card geometry.

### 5.4 The static-index scan, as a LEAD

```
ELABCLASS_STATIC total_growing=266 purely_static=151 runtime_indexed=115
```

121 distinct sites after de-duplication, by file:

```
28 rtl/layer.vhd          19 rtl/matvec_core.vhd     12 rtl/weight_streamer.vhd
12 rtl/fk33_llama_top.vhd  9 rtl/llama_top.vhd        9 rtl/attn_mac_array.vhd
 6 rtl/ooc_normadapt_top.vhd  6 rtl/gdn_recur_pipe.vhd  4 rtl/hbm_tg.vhd
 2 rtl/layer_fsm.vhd       2 rtl/engine_shared.vhd    2 rtl/attn_score_q12.vhd
 1 each: seq_top_skel seq_region_lock seq_ctrl gdn_state_store gdn_silu
         gdn_conv_w_mem bc_port_grant attn_softmax attn_gate async_fifo
```

**This is a lead and not a defect count**, and the split matters. Taking the
entity closure of the card's three tops (`fk33_card`, `fk33_llama_top`,
`fk33_engine`) -- 55 entities in 55 files:

```
# sites TOTAL=121 IN=67 OUTSIDE=54
rtl/layer.vhd                   28 no     rtl/matvec_core.vhd            19 YES
rtl/fk33_llama_top.vhd          12 YES    rtl/weight_streamer.vhd        12 YES
rtl/attn_mac_array.vhd           9 YES    rtl/llama_top.vhd               9 no
rtl/gdn_recur_pipe.vhd           6 YES    rtl/ooc_normadapt_top.vhd       6 no
rtl/hbm_tg.vhd                   4 no     rtl/attn_score_q12.vhd          2 YES
rtl/engine_shared.vhd            2 no     rtl/layer_fsm.vhd               2 no
```

**67 are elaborated by the card build at the card's values. The other 54 are
not**, and 28 of them are in `rtl/layer.vhd`, whose only instantiator is
`rtl/seq_ctrl.vhd`, which nothing instantiates at all -- so those have never
been elaborated by any Vivado at any shape, and never will be while they stay
unreachable. `rtl/llama_top.vhd`'s 9 are the simulation top, which
`sim/elab_cardtop.tcl` records CRASHING Vivado at the real 9B shape in
`HOptDfg::dissolveRam`; `rtl/engine_shared.vhd`'s 2 are reached through
`rtl/llama_engine_axi.vhd`, which `hw/fk33/gen_pcieep.py` and
`hw/fk33/pcieep_build.sh` do not mention at all (`grep -rn llama_engine_axi`
over both returns nothing) -- it is packaged as IP by
`ip_repo/package_llama_ip.tcl` and drawn by `sim/ooc_llama_engine_axi.tcl`, so
those two sites HAVE been elaborated by a Vivado, just not by a card build.

What the scan ranks is *which generic could move one of them*. Crossed with the
never-synthesised list:

```
file                       sites  NEVER-SYNTH boolean arms in the same file
rtl/fk33_llama_top.vhd        12  A_BEHAV,B_BEHAV,NORM_ANCHOR,SWG_WIDE,A_DRAIN_WIDE
rtl/llama_top.vhd              9  A_BEHAV,B_BEHAV,NORM_ANCHOR,SWG_WIDE,A_DRAIN_WIDE
rtl/gdn_recur_pipe.vhd         6  D_NORM,TK0_ED,EG0_ED
rtl/engine_shared.vhd          2  DEBUG_TAPS
```

**And then the reading, which changes the order.** `gdn_recur_pipe`'s three
booleans appear ONLY in `if` conditions inside the recurrence process --
`if (sc1(3).c.tk0 = '1' or (EG0_ED and sc1(3).c.eg0 = '1')) and TK0_ED`,
`if D_NORM` -- and in no loop bound and no array bound, so none of them can
move any of that file's six sites. They rank LOW despite the count. The six
sites are the `redk`/`reda`/`redo` reduction trees, whose bound is `LOG2L`,
derived from `LANES`, i.e. from `B_RECUR_LANES` -- and **that generic has been
synthesised at 4 and at 16** (`sim/ooc_gdnadapt.tcl` tier arm, LEVERBOARD L-B),
so its trees are proven elaborable at both.

### 5.5 The filter's own control

`A_DRAIN_WIDE`'s group path is what the narrow scan must NOT flag:

```vhdl
for i in 0 to LANES-1 loop
  if i >= lane0 and i < lane0 + A_DW_GRP and (r + i - lane0) < j_rows then
    aw_data((i+1)*MANT_W-1 downto i*MANT_W)
      <= ybw(rword)((rlane+i-lane0+1)*MANT_W-1 downto (rlane+i-lane0)*MANT_W);
```

`rlane`, `lane0` and `rword` are process VARIABLES, so the index is run-time
and Vivado builds a shifter rather than folding a constant. The scan classifies
it `runtime_indexed` and not `purely_static`, which is correct: its risk is
AREA (LEVERBOARD already flags "two 8-way 128-bit barrel shifters" as the
undrawn cost), not elaboration. A scan that flagged it would have no resolution
at all, because 115 of the 266 growing indices in this repository are of that
form.

### 5.6 Teeth for the gate half, with its resolution floor

`sim/check_elab_rows.py` run in a `git archive HEAD` scratch tree, never in the
repository, every case restored from the committed blob:

```
T0 CONTROL  pristine + the new files
            ELABROWS PASS: 43 boolean generic names, 22 with an arm no
            synthesiser has been given, all accounted for (5 elaboration rows,
            2 OOC-covered, 11 exempt, 4 on entities nothing instantiates).  rc=0

M1 a new one-armed boolean generic appears in rtl/attn_block.vhd
            rc=1   NEWLEVER_X   arm(s) never synthesised: true   on attn_block
M2 the d_adw elaboration row is deleted from the table
            rc=1   A_DRAIN_WIDE arm(s) never synthesised: true   on fk33_llama_top,llama_top
M3 an EXEMPT entry is deleted
            rc=1   NEOX         arm(s) never synthesised: true   on rope

M4 SURVIVES  a STALE EXEMPT entry naming a generic that does not exist   rc=0
M5 SURVIVES  a row whose TOP does not build the generic it names         rc=0
```

**M1, M2 and M3 are the three ways this check can matter and it kills all
three**: a new lever arriving, a scheduled row being dropped, and a decision
being deleted.

**The two survivors are reported under their own names because they are the
check's resolution floor, and M5 is the one that matters.** The row table is
read as a SET OF NAMES, so writing `NEOX=true` into a row whose top does not
instantiate `rope` satisfies this check while measuring nothing. **Being listed
is not evidence that the row elaborates that generic; only running the Vivado
half is.** M4 is the milder form: a stale exemption for a generic that has been
deleted is never noticed. Neither is fixed, and a fix for M5 would have to
elaborate, which is precisely what this half exists to avoid.

---

---

## 6. Measured and REJECTED -- do not retry

### 6.1 A string generic passed as `-generic {NAME="value"}`

MEASURED. The driver wrote the path in Tcl braces so the VHDL quotes would
survive list parsing. A brace is only special to Tcl at the START of a word, so
they survived as **data**:

```
Parameter NORM_W_IMAGE bound to: {"/home/labuser/elabclass/gen/norm_w_9b.hex"} - type: string
ERROR: [Synth 8-3302] unable to open file '{"/home/labuser/elabclass/gen/norm_w_9b.hex"}' in 'r' mode [.../fk33_llama_top.vhd:2885]
ERROR: [Synth 8-421] mismatched array sizes in rhs and lhs of assignment [.../fk33_llama_top.vhd:2921]
ERROR: [Synth 8-285] failed synthesizing module 'fk33_llama_top' [.../fk33_llama_top.vhd:1279]
```

**Pass the path BARE.** Vivado takes a bare value for a `string` generic;
quoting it is what breaks it. Do not retry the braced form. The two rows this
killed are kept in
`hw/fk33/results/elabclass_2026-09-20/rows/invalidated_quoting_trap/`.

### 6.2 The BROAD index scan as a defect list

MEASURED: the permissive scan finds **285 sites**; the growing-index filter
**266**; of those **115 are run-time indexed** and cannot fail this way at all,
and of the remaining **121 purely static sites, 67 already elaborate in the
card build at the card's own values and 54 are outside the card's entity
closure altogether** (section 5.4). A list of 285 "candidates" has no
resolution, and reading it as findings would have produced a document about a
repository-wide problem that does not exist. **Use it to rank which generic
could move a site; never as a count of anything.**

### 6.3 `sim/ooc_*.tcl` as coverage for a generic taken from argv or env

NOT retried, deliberately. SHAPEAUDIT already measured that
`ooc_micro`, `ooc_pnr`, `ooc_micro_pnr`, `ooc_mover_paths` and `ooc_levercost`
take their top and generics from the caller, so their shape is not knowable
from the file. Counting them would mark arms covered on the strength of a
script that may never have been run that way -- an error in the one direction
that matters. The three arms the OOC harnesses DO cover (`FAST_POP` both ways,
`CONST_EN=true`, `USE_XEXP_PORT=true`) were each read out of a literal in the
script text and are quoted as such.

### 6.4 Reading the card's generic map from `hw/fk33/gen_fk33_card.py`

Already recorded by SHAPEAUDIT and not retried: the generator applies `FK33_*`
trim overrides to its `ARGS` list AFTER construction, so the Python literals
are not what is built. Every card value in `sim/elab_check_run.sh` comes from
`hw/fk33/rtl/fk33_card.vhd:222-243`, and the engine cell's twelve from
`hw/fk33/gen_fk33_engine.py:83-95` -- which is the generator, and is therefore
the right source for THAT cell because its output has no other.

---

## 7. Measurement traps hit, including my own

### 7.1 The lane looked busy, and it was busy with my own corpse

The first launch printed
`ELABCLASS_WAIT ...: a Vivado is present here; re-check in 120 s`. The natural
reading is that another track took the lane. It was **my own smoke run**: the
harness's two-minute foreground timeout killed the ssh client, the remote
driver died, and its Vivado child did not. Identified by `/proc/PID/exe` and
`/proc/PID/cwd` (`cwd=/home/labuser/elabclass/out`), never by a command line.
Everything was killed by **explicit PID**, the output directory was deleted and
the batch restarted -- because two runs writing the same log names is the
recorded "a gate run that overlapped an edit proves nothing about either
version", and the cost of re-running eleven cheap rows is smaller than one
ambiguous table.

### 7.2 The 11G cap silently did not exist

MEASURED: over `ssh host 'bash -s'` there is no `XDG_RUNTIME_DIR` and no
`DBUS_SESSION_BUS_ADDRESS`, so `systemd-run --user --scope` fails, the driver
falls through to its uncapped path, and says so in **one line** that nothing
gates:

```
ELABCLASS_CGROUP systemd-run --user unavailable; plain run
```

Vivado then ran **uncapped on a 14 GB box that is on no WoL watchdog**. The
driver now sets both variables itself. **TRACK HDRCOST's driver has the same
shape**; its logs show cgroup peaks, so its launch path did carry them, but
nothing in either script would have raised an alarm if it had not.

### 7.3 A HARNESS failure that was indistinguishable from a DESIGN failure

Section 6.1's three lines are anchored `ERROR:`, name `rtl/fk33_llama_top.vhd`,
and carry line numbers. Nothing in that output says "harness". **The only thing
that caught it is that `d_card` is a row which MUST PASS.** Without that
control row, `d_adw`, `d_swgw1` and `d_swgw8` would have failed the same way
and been reported as unbuildable levers -- which is exactly the claim this
track exists to make, made wrongly, about three levers at once.

### 7.4 A manifest that verified itself

The first manifest listed `manifest.sha256` among its own entries, so
`sha256sum -c` reported `FAILED` on a tree that was byte-correct. A verifier
that can fail for a reason unrelated to the thing verified is worse than none,
because the next move is to distrust the tree.

### 7.5 The static scan's nested-loop tracking is wrong, and is not fixed

It collects every `for` in a 400-line window instead of the true enclosing
stack, so `rtl/layer.vhd`'s ranges print as forty-deep nonsense. It is harmless
for ranking by FILE, which is all it is used for here, and **useless for
reasoning about any individual site**. Stated rather than repaired, because
repairing it would invite exactly the site-by-site reading that 6.2 says not to
do.

### 7.6 MY OWN SWAP GUARD KILLED A HEALTHY ROW ON A TEN-SECOND AVERAGE

The BC-250 has 15.2 GB and 48 GB of swap, no WoL watchdog, and a physical
power-cycle is the only recovery, so a guard was put beside the card-top rows.
Its first version tripped on `/proc/pressure/memory`'s **`full avg10`**:

```
2026-09-20T23:00:22 GUARD TRIPPED swap_mb=11183 psi_full10=55.30 -- killing 2223164
ELABCLASS_ROW row=d_hostwin top=fk33_llama_top verdict=NORESULT expect=pass wall_s=373 rc=143
```

**That kill was wrong.** `avg10` is a ten-second average and is a transient by
construction; the row it killed was at **11 GB** of swap, and `d_card` -- which
had already COMPLETED -- peaked at **22.9 GB** of swap with `avg10` around 5.
A ten-second stall is what a large elaboration does while it faults a working
set in.

Replaced with a level-based guard: **swap in use above 34 GB** (of 48), with
`full avg60 > 85` as a much higher second bar. `d_hostwin` was re-run under it
and PASSED at 785 s with a 21.7 GB swap peak. **A guard whose threshold is a
transient is a random killer of long jobs**, and it fails in the direction that
looks like a result: `NORESULT` on a row whose verdict was the finding.

### 7.7 `elabfail_<tag>.txt` is not the error

`catch` around `synth_design` returns only
`ERROR: [Vivado_Tcl 4-5] Elaboration failed - please see the console for
details`. The real text is in the Vivado log, and the DRIVER greps it into
`batch.log`. Read `batch.log`, not the per-row capture.

---

## 8. Open, not determined

**This track elaborated 5 of the 16 reachable never-synthesised arms** (`A_DRAIN_WIDE`, `SWG_WIDE`, `WIDE_IO`, `NORM_ANCHOR`, `CHECK_JOB_INDEX`), plus `HOST_WINDOW=true` at the card's other 21 generics, which is a configuration nothing had built either. The
other 11 were ranked LOW by READING the code and were not run:
`A_BEHAV`, `B_BEHAV`, `DEBUG`, `DEBUG_TAPS`, `D_NORM`, `EG0_ED`, `NEOX`,
`PROBES`, `REL_NAIVE`, `STRICT_PROTO`, `TK0_ED`. Each carries its reason in
`sim/check_elab_rows.py`'s `EXEMPT` table. **A LOW rank is a judgement about
ONE failure mode** -- the statically folded index -- **and says nothing about a
width mismatch, an unconnected port, or the loop-iteration limit**, any of
which elaboration would also catch. They are cheap rows; nobody has run them.

**Only the BOOLEAN space is enumerated exhaustively.** An integer generic's
value space is unbounded, so there is no complementary list to build; the
integer side is covered only by the 121-site static scan, which is a LEAD.
**No integer generic was elaborated at a non-card value by this track.**

**`HOST_WINDOW=true` is measured only at the CARD's other 21 generics.**
`d_hostwin` PASSES there (785 s), after a re-run; `sim/elab_cardtop.tcl`
elaborates the same arm at ALL DEFAULTS, which is a third configuration and
neither is a substitute for the other. Nothing here says the arm is correct --
only that it elaborates.

**AN ELABORATION PASS IS NOT A SYNTHESIS PASS.** `-rtl` stops before mapping,
so every PASS in section 5.2 is a statement about elaboration and nothing else.
A configuration that elaborates can still fail at `[Synth 8-10226]`, exhaust a
resource, or miss timing. This check was built to be cheap enough to schedule,
and that is exactly what it gives up.

**`sim/elab_check_run.sh`'s `DCARD` string can go stale and nothing gates it.**
It transcribes `hw/fk33/rtl/fk33_card.vhd:222-243`'s twenty-two generics. If
the generator ever passes a twenty-third, the row table silently elaborates a
configuration the card does not build -- the same shape as the recorded
`compose4_top.vhd` staleness, which was wrong since `11bf64b` and surfaced by
luck. A `--check` comparing the two would close it and was not written.

**The teeth row rests on ONE defect.** `synth_design -rtl` is shown to fold a
statically out-of-range index because HDRCOST's blob was available to test it
with. Whether `-rtl` catches everything the full `synth_design` HDRCOST ran
would catch is NOT established, and the two modes are not interchangeable as
evidence about anything but elaboration.

**Whether the loop-iteration-limit member of the class is caught by these
rows** is not established here. TRACK NWFIX measured `synth_design -rtl`
catching it for `ooc_normadapt` on 2026-08-29; it was not re-measured, and no
row in this table is aimed at it.

**The 121 static-index sites were not read individually, deliberately.**
Section 6.2 says why. So the claim is "none of them is moved by a
never-synthesised BOOLEAN arm", not "none of them is wrong".
