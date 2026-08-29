# What is still missing before Qwen3.5-9B runs end to end on one SQRL FK33

**Date:** 2026-08-28. Branch `fpga`, at `b66c4b4`.
**Part:** `xcvu33p-fsvh2104-2L-e` / `-2LV-e`, SQRL FK33, 8 GiB HBM, VCCINT 0.717 V MEASURED.
**Model:** Qwen3.5-9B, `NCARDS = 1` (`rtl/model_cfg_pkg.vhd:85,91`).

**Status: AUDIT ONLY. No RTL was written and no Vivado was run.** Evidence is
source reading, `sim/regress.sh`, GHDL simulation already committed to the tree,
and reports already in `docs/`.

**Labelling discipline**, as in every document this one cites: **MEASURED** (a
tool was run or a committed artefact was read, and it is named), **DERIVED**
(arithmetic or logic shown here from MEASURED or RTL-normative inputs),
**ESTIMATE** (a judgement, with its assumption stated).

**Method note, and it is the reason this document says different things from
the specs.** Where a document and the RTL disagree, the RTL wins. That rule
changed the verdict on three subsystems: A (the specs say `ROWS_IF = 48`, the
RTL says 4 and two assertions refuse 48), C (the specs describe thirteen units,
six of them including the entire multiply array do not exist), and D (the specs
describe a sequencer, `rtl/seq_top_skel.vhd` instantiates nothing).

---

## 0. The answer, in one paragraph

**Nothing on the card can produce a token, and the dominant category of
remaining work is units that do not exist rather than units that are
unverified.** `rtl/` holds two disjoint codebases: a complete, silicon-validated
stories260K engine at `DIM = 64` / `VOCAB = 512`, and four unwired islands of
Qwen3.5-9B work. Of the four, only B has a top level. A's top level is real,
bit-exact and running on real silicon, but it is built for the wrong device --
DDR4 on the AXU3EG at `ROWS_IF = 4`, `AXI_DW = 128`, five hard-named AXI
masters, and two `severity failure` assertions that refuse the FK33 shape
outright; the six files that would give it an HBM front end do not exist. C has
eight good auxiliary units and **no multiply array at all**: six of the thirteen
units its own spec names are absent, including every replicated one, the KV
HBM interface and the control FSM. D has five real units, all mutation-tested and two
of them bit-exact against independent C oracles, but no top level, one of its
three vector operators, no region fabric, and no tool in any language that
emits its descriptor program. **No
entity anywhere in `rtl/`, `sim/` or `tb/` instantiates two of
{`matvec_int4*`, `gdn_*`, `attn_*`, `seq_*`}** (MEASURED), so seven of the
eight subsystem pairs have never met. Off-chip, nothing in the fabric reads
HBM and hands bytes to A, no packed image exists in FK33 geometry (the packer
now refuses that geometry, honestly and loudly), the embedding table and LM
head are 512-entry ROMs, and the FK33 has never enumerated on PCIe. E is
genuinely not needed at `NCARDS = 1`, and that is confirmed in the RTL rather
than assumed. The project has excellent parts and no machine.

---

## 1. Subsystem verdicts

Evidence classes used throughout:

| class | meaning |
|---|---|
| **V** | verified bit-exact against an independent oracle, **with** a committed, re-runnable `mutate_*.sh` that demonstrates the checker fails on injected defects |
| **V-** | bit-exact against an independent oracle, mutation testing performed and recorded **in prose only**, with no committed harness that reproduces it |
| **B** | bit-exact against an independent oracle, no mutation testing of any kind |
| **S** | simulated against self-consistent or tolerance checks, no independent oracle |
| **E** | elaborates / analyses only |
| **P** | pricing skeleton: computes nothing real, exists to be synthesised for area or timing |
| **X** | absent |

### 1.1 The headline table

| Subsystem | Verdict | What specifically is missing |
|---|---|---|
| **A** INT4 streaming matvec | **Built and silicon-validated for the WRONG DEVICE** | The HBM front end. `weight_streamer` is DDR4/AXU3EG and two of its own assertions refuse the FK33 shape. All six proposed FK33 files absent. `ROWS_IF = 48` exists in no RTL. No mutation testing anywhere in A. |
| **B** Gated DeltaNet | **Most complete subsystem. Integrated, but not oracle-checked as a block and not mutation-covered at all** | State memory, conv-tap memory and the elastic state feed are outside `gdn_block` and do not exist. No block-level C oracle. No committed mutation harness anywhere in B. `gdn_recur_pipe`, the shipping recurrence, discards its accuracy oracle. `l2norm_rs` is tolerance-checked, not bit-exact, and has no C model at all. Phases run strictly sequentially, so the built cost is not the budgeted cost. |
| **C** gated attention | **Auxiliary path only, verified to the highest standard in the repo. The array does not exist** | 6 of 13 spec-named units absent, including `attn_lane`, `attn_score_tree`, `attn_acc` (the whole replicated array), `attn_kv_axi` (the HBM KV interface), `attn_qk_norm` and `attn_ctrl`. **No `rtl/` file instantiates a single C unit.** Built at `MAXCTX = 2048`. |
| **D** transformer sequencer | **Control core real and well verified. No top, no operators, no program** | `seq_top_skel` instantiates nothing. 2 of 3 D-vec operators absent. Region banks absent. AXI grant mux absent. Base-array fetch and codebook load absent. No host descriptor generator in any language. |
| **E** TP collective | **Correctly out of scope at N = 1** | Nothing, for this target. `tp_collective_skel` computes nothing and is instantiated by nothing, and that is fine. |
| **Weight path** (non-RTL) | **Front half built, back half absent** | No fabric HBM weight reader, no FK33-geometry packed image, no whole-model image builder, no manifest, no descriptor image, no driver loaded, no PCIe link ever trained. |
| **Token I/O** | **stories260K placeholders** | Embedding (545.6 MiB), LM head (248,320 x 4,096) and tokenizer are 512-entry / 64-dim ROMs. The residency map assigns the embedding an HBM home and says in its own words that the lookup path has no owner. |

### 1.2 Subsystem A, per unit

MEASURED, all runs re-executed for this audit against the committed tree.

| unit | class | oracle | mutation |
|---|---|---|---|
| `mv4i_arith_pkg.vhd` | **B** | `sim/arith_vectors.txt` from `tools/gen_arith.py` (Python is the authority; it emits the C and the VHDL, so both are compared to a third implementation) | none |
| `matvec_core.vhd` | **B** | `ref/matvec_int4.c`, compared **stage by stage** (partial / contrib / acc / ns / ymant / y_exp / sat_event), 13 shape cases incl. two adversarial saturation vectors | none |
| `matvec_int4.vhd` | **B** | `ref/matvec_int4.c`, serving the **real packed image** over AXI so the sub-region layout, lane order, nibble order and scale interleave are covered here and nowhere else | none |
| `matvec_int4_axi.vhd` | **B** | same, through the AXI-Lite register map; `ERR_ADDR` negative control fires | none |
| `matvec_int4_ip.vhd` | **S** | none. Differential bijection against `matvec_int4_axi` only | none |
| `weight_streamer.vhd` | **S** | indirect only. **There is no `tb_weight_streamer.vhd`** | none |
| `axi_rd_port.vhd` | **S** | none. Behavioural slave returns address-derived data; 7-point (MAXOUT, DEPTH, STALL) sweep | none |
| `bfp_pack.vhd` | **S** | hand-computed reference in `tb/tb_bfp_stress.vhd`. **`sim/tb_bfp_cmp.vhd` is dead**: it port-maps an `in_q` bus that `rtl/bfp_pack.vhd` no longer has, and `sim/regress.sh` skips it unconditionally on `library beh` | none |

**MEASURED: not one of the 17 `sim/mutate_*.sh` scripts touches any A file.**
All mutation coverage in the repo is C (7 scripts) and D (5 scripts) plus 5
reference-side mutators. A's checkers are demonstrated to pass and never
demonstrated to fail, with the honourable exception of two deliberate `ADDR_W`
negative controls, which do fire.

**MEASURED: `bfp_pack` is not on the INT4 matvec path at all.** Its only
structural parent is `rtl/engine_shared.vhd:667`, the old stories260K engine.

### 1.3 Subsystem B, per unit

| unit | class | evidence |
|---|---|---|
| `gdn_conv` | **V-** | bit-exact vs `ref/gdn_conv_vec.c` **and** a real-valued double oracle, both asserted (`sim/tb_gdn_conv.vhd:221-224`), tolerance 0.75 set from a measured 0.4999999. Second seam bench `sim/tb_gdn_conv_tvalid_skew.vhd` with an independent in-testbench model |
| `gdn_silu` | **V-** | bit-exact, no tolerance by design (`sim/tb_gdn_silu.vhd:3-10`, assert `:94-96`) |
| `gdn_head_emit` | **V-** | bit-exact, no tolerance, plus a real throughput bound (`sim/tb_gdn_head_emit.vhd:232-238`) |
| `gdn_y_emit` | **V-** | bit-exact plus throughput bound; extra handshake audit in `sim/tb_b_audit_ser_handshake.vhd`, now at `severity failure` after that file recorded being cited as evidence while exiting 0 at `severity note` |
| `gdn_emit_chain` | **V-** | end-to-end bit-exact over 6 blocks x 24 heads x 128 (`sim/tb_gdn_emit_chain.vhd:406-419`). Its oracle computes the chain twice and refuses to emit above 8.0 LSB divergence |
| `rmsnorm_bf` | **V-** | bit-exact, no tolerance, with vector-header/generic cross-checks. This unit is the fix for the missing RMSNorm epsilon (spec finding F1) |
| `gdn_recur` | **V-**, and **not wired into the block** | bit-exact asserted; oracle accuracy asserted only when `CORRECTED`, which is true by default |
| `gdn_recur_pipe` | **B, transcription only** | same committed vectors, but the oracle columns are **explicitly discarded**: `sim/tb_gdn_recur_pipe.vhd:147-148` reads and drops the oracle `u` and `o`. **The shipping recurrence unit has no accuracy check at all** -- only equality with `gdn_recur`'s recipe |
| `gdn_scalar` | **B for transcription, S for accuracy** | bit-exactness asserted at `severity failure`, but the double oracle is unconditionally *"reported, not asserted"* (`sim/tb_gdn_scalar.vhd:95`, figures at `:107-108`). No tolerance constant and no accuracy gate anywhere in the file |
| `gdn_exp_capture` | **S**, by design | independent behavioural model **inside** the testbench (`sim/tb_gdn_exp_capture.vhd:4-11`). Defensible: the unit does no arithmetic |
| `l2norm_rs` | **S (tolerance)** | `sim/tb_l2norm_rs.vhd` compares against `x/||x||` in `math_real`, **within 0.75 output LSB**. Not bit-exact. **`ref/` contains no l2norm model at all** |
| `gdn_block` (top) | **S** | see below |
| state memory, conv-tap memory, elastic state feed | **X** | left outside `gdn_block` by design |

**MEASURED: 11 of the 12 B files are reachable from `gdn_block`** -- seven
instantiated directly (`rtl/gdn_block.vhd:567-629`) and four more inside
`gdn_emit_chain` (`:289-312`). The one not wired in is `rtl/gdn_recur.vhd`, the
sequential twin, deliberately superseded by `gdn_recur_pipe`. **B is genuinely
integrated**, and it is the only subsystem of which that is true.

**MEASURED: B is the only subsystem whose RTL generic defaults are Qwen3.5-9B**
(`rtl/gdn_block.vhd:186-190`: `KEY_HEADS = 16`, `VAL_HEADS = 32`, `DIM = 128`,
`KCONV = 4`, `LAYERS = 24`).

**`tb_gdn_block` is a skew-invariance test, not an oracle check, and in the
regression it is weaker still.** MEASURED: the file's only `file_open` is
write-mode (`:653`); its stimulus is a deterministic in-testbench hash. Its
header says so: *"this testbench does not re-check arithmetic. It checks the
property that would have caught all four: THE BLOCK'S OUTPUT MUST BE
BIT-IDENTICAL UNDER EVERY PRODUCER SKEW."* The four in-file assertions are a
collector overflow guard, a total element count, a per-token count, and
`dbg_col_drop = '0'`. `err_conv`, `err_g`, `err_se` and `y_sat` are printed
with **no severity and no assert**, so a run in which conv errored or the
output saturated still prints PASS. The real value comparison is external and
cross-run (`sim/run_gdn_block.sh:79-94` diffs each skew point against a
reference dump) -- but **`sim/regress.sh:639` runs the bench once at default
generics, with every skew knob at its default**, so the gate's PASS for B's top
level rests entirely on those four structural asserts. The skew property is
only exercised by invoking `run_gdn_block.sh` separately.

**MEASURED: there is no mutation harness for B.** `ls sim/mutate_*.sh` returns
17 scripts: 7 `mutate_attn_*`, 3 `mutate_ref_attn_*`, 5 `mutate_seq_*`, 2
`mutate_ref_seq_*`. **Zero `mutate_gdn_*`, zero `mutate_l2norm_*`, zero
`mutate_rmsnorm_*`.** Mutation was done for B, by hand, during the sessions and
recorded in prose -- the spec's status table cites "3 mutations caught",
"5 mutations caught", "4 mutations caught", and **nothing in the repo can
reproduce any of them.** This is the largest structural asymmetry between B and
C: C's mutation evidence is executable, B's is a claim in a document.

**Two testbenches in B's list do not test B RTL at all.** MEASURED:
`sim/tb_exp_cone.vhd:28-32` drives `micro_exp_cone` and
`sim/tb_silu_cone.vhd:31-37` drives `micro_sig_cone` against
`micro_silu_narrow`. Both subjects live in `sim/micro/` and are pricing
benchmarks, not `rtl/gdn_silu.vhd`. `tb_exp_cone` is also the weakest check in
the set: mismatches are `severity error` with no aggregate assert, and its
`VALUES AGREE` marker prints even if the comparison loop runs zero times.

**Five open items in B that are not verification gaps but design gaps:**

1. **The phase schedule.** conv, silu, L2, scalars and sweep run **strictly
   sequentially**, with only the sweep and the emit chain concurrent. That is
   deliberate -- each overlap is a new seam -- but it means B's cycle cost as
   built is not the cost the spec's budget assumes.
2. **Staging is 196,608 flat flip-flops, not BRAM** (`rtl/gdn_block.vhd:172-184`),
   because `l2norm_rs`, `gdn_recur_pipe` and `rmsnorm_bf` all take `N*16`
   parallel buses. The spec books these rows as BRAM36. Untested alternative.
3. **`o_sat` exists on both emit units and nothing consumes it.** There is no
   policy for what happens when saturation fires.
4. **The state-drift bound over a 2,048-token sequence is untouched**, and it
   is what decides whether int16 state mantissas plus Q15 decay survive.
5. **A known first-token quantization defect sits one generic away.**
   `docs/debugging/2026-08-26_gdn-first-token-dm-grid.md`: at `tk = 0` the whole
   state is `k_n * d_m`, and `d_m` is quantized on `e_d = min(e_v, ske)` rather
   than on its own magnitude, so at `beta = 2.4e-4` it **rounds to zero in 7.0%
   of draws** -- the first token's state is identically zero. The `D_NORM` fix
   defaults `true` in both recurrence units, so the shipping path has it. But
   `gdn_recur_pipe`'s testbench discards the oracle columns, so **nothing in
   the regression would notice if it regressed.**

**MEASURED, and it is the one open throughput-correctness item**
(`docs/debugging/2026-08-27_gdn-block-top-level.md:175-190`): the emit chain's
per-head deadline at the shipping datapath shape is **367 cycles**. At
`RECUR_LANES = 32` the column arrival period is 512, so the margin is 145
cycles (28%). At `RECUR_LANES = 64` the period is 256 and the chain is
**111 cycles per head too slow in steady state** -- a rate limit, not a burst
limit, so "add an elastic buffer" does not fix it, and the earlier
prescription to do so is withdrawn by that document.

### 1.4 Subsystem C, per unit

**The decisive fact, MEASURED.** `docs/superpowers/specs/2026-08-27-C-gated-attention-skeleton.md:311-325`
decomposes C into thirteen units. Checking each against `rtl/`:

| spec unit | in `rtl/`? |
|---|---|
| `attn_qk_norm` | **ABSENT** |
| `attn_twiddle` | present |
| `attn_rope` | present |
| `attn_kv_quant` | present |
| `attn_kv_axi` | **ABSENT** |
| `attn_lane` | **ABSENT** (only `attn_lane_skel.vhd`, a pricing shell) |
| `attn_score_tree` | **ABSENT** |
| `attn_acc` | **ABSENT** |
| `attn_softmax` | present |
| `attn_recip` | present |
| `attn_gate` | present |
| `attn_emit` | present |
| `attn_ctrl` | **ABSENT** (only `attn_c_ports_skel.vhd`, outputs tied off) |

plus `attn_score_q12.vhd`, which is not on the spec's list and does the
alignment and Q12 conversion **downstream** of `attn_score_tree`.

**Six of thirteen absent, and they are the load-bearing six.**
`attn_lane` + `attn_score_tree` + `attn_acc` are, in the spec's own words, "the
replicated array; everything else is a fixed cost". So the eight units that
exist are the auxiliary and scalar path **around a multiply array that does not
exist**. This is independently visible in the RTL: `rtl/attn_score_q12.vhd`'s
port list **consumes** `p_valid` / `p_data`, "one query head's per-block partial
dot products", and nothing in the repo produces them.

| unit | class | oracle | mutation harness | recorded result |
|---|---|---|---|---|
| `attn_twiddle` | **V** | `ref/attn_twiddle_vec.c` | `mutate_attn_twiddle.sh` + `mutate_ref_attn_twiddle.sh` | RTL **22/22 killed**, ref **15/15**, no survivors |
| `attn_rope` | **V** | `ref/attn_rope_vec.c` | `mutate_attn_rope.sh` + `mutate_ref_attn_rope.sh` | RTL **30/30**, ref **13/13**, no survivors |
| `attn_softmax` | **V** | `ref/attn_softmax_vec.c` | `mutate_attn_softmax.sh` | 14 of 16 killed, both survivors read and shown equivalent. Found a real RTL defect (an offset narrowed with `resize`) |
| `attn_recip` | **V** | `ref/attn_recip_vec.c` | `mutate_attn_recip.sh` | 11/15 then **13/15**, both survivors proven equivalent; one survivor was a real **testbench coverage gap**, since fixed |
| `attn_gate` | **V** | `ref/attn_gate_vec.c` | `mutate_attn_gate.sh` | 3 survivors, all read. Exposed a sigmoid witness set of **2 points out of 131,071** |
| `attn_emit` | **V** | `ref/attn_emit_vec.c` | `mutate_attn_emit.sh` | RTL 21/22, ref 12/13. Reference mutation found **two vacuous oracles**: `y_exp` was an emitted golden no oracle read, and the peak-window oracle read the path's own `amax` |
| `attn_kv_quant` | **V-** | `ref/attn_kv_quant_vec.c` | **no script** | M1-M12 documented and killed in prose, plus 5 reference mutations. Strong evidence, not reproducible |
| `attn_score_q12` | **V-** | `ref/attn_score_q12_vec.c`, itself checked against **three** double oracles | **no script, no write-up** | mutation used ad hoc to build the case set; nothing reproduces it |
| `attn_lane_skel` | **P** | its own header: "it prices the lane and nothing else: it computes no attention, it has no accumulator file, and its outputs are a digest" | n/a, correctly | **Was synthesised and produced a real number**: `RESCALE_ON_LANE = true` reproduces the independently measured 2 DSP (the acceptance test), `false` gives 1 DSP at 507.4 MHz at 0.717 V |
| `attn_c_ports_skel` | **P**, pure | "The architecture ties every output off; it computes nothing and must never be instantiated in a build". The whole architecture is 19 constant assignments (`:251-270`) | n/a | documentary only: it encodes the two handshake rules derived from B's defects |
| `attn_rescale_skel` | **P by intent, hybrid in fact** | its `SEQ_MULT = true` branch implements a chunk decomposition **that is not in the spec**, so it has a real functional bench (`sim/tb_attn_rescale.vhd`, bit-exact vs `ref/attn_rescale_vec.c`, five properties incl. a poisoned read mux) | `mutate_attn_rescale.sh` + `mutate_ref_attn_rescale.sh` | **Its DSP numbers are unmeasured.** `docs/debugging/2026-08-27_shared-rescale-pricing-skeleton.md:221`: *"Every DSP figure in this file is a HYPOTHESIS, not a measurement."* The question it exists to answer is still open |

**Six of the eight real C units carry a committed, re-runnable mutation
harness; `attn_kv_quant` and `attn_score_q12` carry none.** The
`mutate_X` / `mutate_ref_X` split is the discipline that makes this evidence
worth more than any other in the repo: the reference mutants are run **before
the RTL exists**, on the stated ground that *"if the generator is wrong, the
RTL gets made wrong to match it and every run is green"*. That is what caught
the two vacuous `attn_emit` oracles.

**C's eight real units are the best-verified arithmetic in the repo.** Six of
eight carry mutation testing on both the RTL and its reference, and that
process found five gaps in the checks themselves
(`docs/debugging/2026-08-27_attn-gate-emit-oracle-gaps.md`). That quality does
not extend to the array, because the array is not written.

**MEASURED: C is built at `MAXCTX = 2048`** (`rtl/attn_softmax.vhd:224-225`,
`:273`). The denominator width and the overflow-unreachability argument are
stated at 2,048 only.

**`rtl/attention.vhd` and `rtl/attention_ml.vhd` are NOT subsystem C.**
MEASURED from headers and generics: `attention.vhd:8-9` is
`DIM = 64, HEAD_SIZE = 8, NHEADS = 8, NKVH = 4, KVDIM = 32, MAXPOS = 8`, and
re-implements the attention of `ref/run_fx.c`, the stories260K reference.
`attention_ml.vhd:1-9,35-44` is the multi-layer banked-KV variant of it,
time-multiplexed across five layers, and it is the live attention in the old
engine (`rtl/engine_shared.vhd:603`). The same pairing holds for
`rtl/rope.vhd` against `rtl/attn_rope.vhd` and `rtl/softmax.vhd` against
`rtl/attn_softmax.vhd`: in each pair the unprefixed file is stories260K and the
`attn_` file is the new one.

**`rtl/kv_mem.vhd` is not C's KV cache and was never meant to be.** MEASURED:
the file is a 27-line generic RAM primitive, `generic(WORDS, W)`, so it is
model-agnostic. Its **only** instantiations are the four inside
`attention_ml.vhd:543-552`, at `WORDS = NLAYERS*MAXPOS = 40` and
`W = KVDIM*16 = 512` -- 40 positions across five layers, the stories260K
geometry. C's cache is HBM-resident in the 272-byte block-floating record
`attn_kv_quant` produces, and it is reached through `attn_kv_axi`, **which does
not exist**.

**One thing to watch in C's own skeleton.** `rtl/attn_c_ports_skel.vhd:57-71`
verifies its geometry against GGUF metadata and lands on `head_count 24`,
`head_count_kv 4`, `head_dim 256`. Those are the **27B** attention dimensions;
9B is 16 query heads (`rtl/model_cfg_pkg.vhd:69`). The head dim and KV head
count carry across, the query head count does not. That same block records the
trap worth keeping: the `head_v_dim = 128` and `16 key heads` figures that
circulate with this model are the **Gated DeltaNet** dimensions and do not
apply to the attention layers at all.

### 1.5 Subsystem D, per unit

| unit | class | evidence |
|---|---|---|
| `seq_desc_fetch` | **S + mutation** | `sim/tb_seq_desc_fetch.vhd`, 14 skewed configurations on the real 491-descriptor 9B table. Mutation 6 of 8 killed; M7/M8 survive as equivalent mutants only because `S_GRANT` does not exist. **No independent oracle**: the golden is `sim/seq_tbl_pkg.vhd`, same language, same author |
| `seq_region_lock` | **S + mutation** | 10 configurations, 7 of 7 mutations killed. Same oracle caveat |
| `seq_opdec` | **S + mutation** | 22 configurations; 11 of 11 mutations killed. First real three-unit integration, and connecting the units found **4 defects neither unit testbench could reach**, one of which was that nothing published the host-written X region, i.e. the token could not start |
| `seq_vec_res` | **V** | `ref/seq_vec_res_vec.c` (6 oracles, shares no arithmetic). 12 configurations, bit-exact on every element of 64 cases, 15/15 reference mutations and 19/20 RTL mutations killed. **Reference was mutation-tested before the RTL existed** |
| `seq_vec_issue` | **V** | `ref/seq_vec_chain_vec.c`, 22 configurations with five real units in the loop. Reference 11/13, RTL 11/16 killed, survivors read and explained |
| `seq_top_skel` | **P** | zero `port map` in 691 lines (MEASURED). Header: "never been simulated, never been synthesised, and implements no behaviour: the descriptor decode, the region address generation, the AXI grant mux and D-vec are all absent" |
| `OP_VEC_NORM` engine | **X** | testbench stub only, `sim/tb_seq_vec_seam.vhd:797-826` |
| `OP_VEC_SWG` engine | **X** | testbench stub only, same generate block |
| region banks / region fabric | **X** | modelled in both D benches, not built |
| AXI grant mux, `S_GRANT`, outstanding counters | **X** | `rtl/axi_rd_port.vhd` exposes no outstanding-transaction count for a gate to read |
| base-array fetch and codebook load | **X** | `rtl/seq_desc_fetch.vhd:113-115`: range-checked only, "Fetching it is remaining work" |
| host descriptor generator | **X** | see 1.7 |

**`rtl/swiglu.vhd`, `rtl/rmsnorm.vhd` and `rtl/seq_ctrl.vhd` are NOT the D-vec
operators.** MEASURED from generics and instantiation graph: all three are
stories260K units (`DIM = 64`, `HIDDEN = 172`, `VOCAB = 512`) whose only parents
are `engine_shared`, `engine`, `layer_ar`, `layer_fsm` and `seq_ctrl`. At 9B
their wide-bus interfaces are not merely wrong but unbuildable: FFN = 12,288, so
a `swiglu` port would be 196,608 bits. `rtl/rmsnorm_rs.vhd` is a narrowed
replacement for the old `rmsnorm`, verified A/B against it, and **has no design
parent anywhere** -- `sim/tb_rmsnorm_rs.vhd` is its only instantiation.
`rtl/seq_vec_issue.vhd:57-76` defines an abstract three-engine bus carrying
**region numbers and no vector data**, and exactly one real operator implements
it: `seq_vec_res`, slot 1.

**MEASURED: no D or E file has ever been synthesised.** Against roughly forty
`sim/ooc_*.tcl` scripts for A, B, C and the old engine, none names any `seq_*`
or `tp_*` file. Every D resource figure in the docs is a count read off the RTL,
not a utilisation report, and **there is no Fmax for any D or E unit**.

### 1.6 Subsystem E: confirmed out of scope, not assumed

`rtl/tp_collective_skel.vhd` is class **P**: its FSM walks
`S_ALIGN -> S_REDUCE -> S_RECHECK` with those three transitions written as bare
`TODO` lines, every data output is tied to zero, and `use_dsp` is set to `"no"`.
Nothing instantiates it.

**Confirmed at `NCARDS = 1` from four independent RTL sites, not from a spec:**

- `rtl/model_cfg_pkg.vhd:91` -- `constant NCARDS : positive := 1;`
- `rtl/seq_vec_res.vhd:168-173` -- "AT NCARDS = 1 THERE IS NO E SEAM ... B7 returns at NCARDS > 1"
- `rtl/seq_opdec.vhd:449` -- "END_TOKEN and E_COLL at NCARDS = 1 touch nothing"
- `sim/seq_tbl_pkg.vhd:91-92` -- `NSTEP_GDN := 16 + (2 * boolean'pos(NCARDS > 1))`; the two `E_COLL` steps per block vanish at N = 1

**MEASURED: no entity in `rtl/` has an `NCARDS` generic**, so there is nothing
to tie off. `NCARDS` is a package constant consumed only by `sim/`.

**One trap worth recording.** `tp_collective_skel` does not read `NCARDS` at
all. It carries its own `N_PEERS := 2` and `MAXROWS := 5120`, which is the
**27B** `d_model`, not 9B's 4,096. If it is ever instantiated, both defaults are
wrong for the declared target.

### 1.7 The non-RTL path, re-checked against today's tree

`docs/2026-08-27_weight-path-audit.md` traced eleven hops. Re-verified, not
quoted. **Two hops have moved; nothing has regressed.**

| # | hop | audit said | **today** |
|---|---|---|---|
| 1 | host packed image | partial | unchanged. `tools/pack_int4.py` emits one tensor per file. No whole-model image builder, no manifest anywhere in `tools/`, `hw/`, `server/` |
| 2 | host DMA program | exists, never powered | unchanged. No card on the bus, no `/dev/xdma*`, `xdma.ko` never built here |
| 3 | XDMA endpoint bitstream | in the BD, not built | **CLOSED.** `hw/fk33/bit/fk33_pcieep.bit`, 12,227,950 bytes, 2026-08-27 22:58, routed, `WNS = +0.275 ns`, `WHS = +0.010 ns`. Neither PCIe document reflects this |
| 4 | `pcie2hbm` smartconnect | exists | built, unpowered |
| 5 | HBM controller, 2 of 32 ports | exists | unchanged |
| 6 | 32 pseudo-channels, flat map | exists | unchanged, and the audit's "two address maps" worry is **withdrawn** by `docs/2026-08-27_hbm-residency-map.md` section 6: there is one map |
| 7 | **fabric weight reader** | **ABSENT** | **still absent.** `docs/2026-08-27_hbm-weight-streamer-design.md` designs it and writes no RTL, deliberately |
| 8 | **28 more HBM ports for A** | **ABSENT** | **still absent.** 30 ports proven buildable only in `hbmbw`, a bandwidth instrument |
| 9 | **descriptor source on the card** | **ABSENT** | **still absent** |
| 10 | 64-bit weight bases | **ABSENT** | **CLOSED** at `a1f315b`. `matvec_int4_axi` gained LO/HI base pairs, `ERR_ADDR` at `STATUS` bit 4, `ADDR_CAP` at `0x7C`, with a negative control that requires truncation to be detected. `ADDR_W` default stays 32 so the AXU3EG bitstream does not silently change |
| 11 | **FK33-geometry packed file** | **ABSENT** | **still absent, but now fails loudly.** `check_geometry()` refuses; MEASURED by running it |

**The two facts that matter most in that table.**

First, the packer and the architecture now point at **incompatible
geometries**. MEASURED by running `tools/pack_int4.py`: the accepted set is
`BLOCK = 32`, `AXI_DW = 128`, `ROWS_IF` in {1, 2, 4, 8}, and nothing else. The
binding constraint is the scale path, not the weight path:
`rtl/weight_streamer.vhd:107-110` asserts
`AXI_DW >= ROWS_IF*16 and AXI_DW mod ROWS_IF*16 = 0` with `severity failure`, so
`ROWS_IF = 16` already fails and 48 is far outside. The refusal is honest; the
consequence is that the settled operating point cannot be packed for or
consumed today.

Second, **`ROWS_IF = 48` is a documented allocation decision, not an RTL
state.** MEASURED defaults: `matvec_core.vhd:55` = 4, `matvec_int4.vhd:30-31` =
4/4, `matvec_int4_axi` = 4/4, `matvec_int4_ip.vhd:26` = 4 with `NP := ROWS_IF`
and exactly five hard-named masters `m00..m04`, `weight_streamer.vhd:32,35` =
4/4. Neither 48 nor 58 is a default anywhere in `rtl/`. 48 lives in
`sim/ooc_core_sweep.tcl:81`, which sweeps **`matvec_core` alone** and says in
its own header that it does so precisely to avoid inventing a streamer
configuration, and in the AXI-Lite register ABI it lives as `W_BASE0..W_BASE3`
plus `S_BASE`. Every downstream figure that reads as measured-at-48 -- the die
allocation, the 27-of-30 port budget, the residency map, D's cycle budgets --
rests on one OOC synthesis row plus one post-route point.

**Token I/O is stories260K.** MEASURED: `rtl/embed.vhd` is `DIM := 64`,
`VOCAB := 512`; `rtl/embed_rom_pkg.vhd` and `rtl/lmhead_rom_pkg.vhd` are
generated `integer_vector(0 to 511)` constant arrays; `rtl/lm_head.vhd` is
`VOCAB := 512` and tied to the embedding ROM; `ref/tok512.bin` is a 512-entry
tokenizer. `rtl/sampler_stream.vhd` is the one piece that carries over: a
generic streaming argmax, first-max-on-ties, matching the C oracle. For 9B the
residency map parks the embedding in HBM at `MEM29..31` and makes the LM head a
streamed A job, and then says in its own section 7 that **the embedding lookup
path has no owner**.

### 1.8 What actually runs today

MEASURED. Two things, both on the AXU3EG, neither on the FK33.

1. **Full stories260K, end to end**, `rtl/llama_engine_axi.vhd` +
   `engine_shared.vhd` + the ROMs, driven by `hw/llama_hw.c` over `/dev/mem`.
   It is autonomous and frozen: the prompt is synthesised into the bitstream,
   so every run prints the same story.
2. **Subsystem A single-matvec bring-up**, `ROWS_IF = 4` / `NPORTS_W = 4` /
   `AXI_DW = 128` / 200 MHz, on a real 27B tensor
   (`blk.0.ffn_gate.weight`, M = 17,408, K = 5,120, 50.14 MB at 4.50 bpw):
   **bit-exact, 0 of 17,408 rows differ**, 8.50 GB/s sustained, six
   consecutive runs. `hw/README.md:29-32` records that this bitstream
   **replaced** the v1.0 engine, so (1) and (2) are never loaded together.

On the FK33 itself: `firstlight`, `i2cprobe` and `hbmbw` have all run on
silicon over JTAG, and `hbmbw` is a real measurement -- 30 ports, 300 MHz,
288.0 GB/s, 100.0% of ceiling, zero non-OKAY beats. **PCIe has never trained,
and no A/B/C/D RTL has ever been in an FK33 bitstream.**

---

## 2. Seams: which pairs have never been connected

Every integration defect this project has found came from a seam. The two
seams closed so far each produced four findings that neither unit's own
testbench could reach.

**MEASURED, by grep over `rtl/`, `sim/` and `tb/`: no file instantiates two or
more of {`matvec_int4*`, `gdn_*`, `attn_*`, `seq_*`}. Not two. Zero.**

> **NOTE ADDED DURING THIS AUDIT, and it does not change the verdict.** At
> 07:12 on 2026-08-28, while this document was being written, an **untracked,
> uncommitted** `rtl/llama_top.vhd` (1,192 lines) appeared in the working tree,
> together with `rtl/llama_map_pkg.vhd`, `sim/llama_sched_pkg.vhd` and
> `sim/tb_llama_top.vhd`. It is another workstream's integration top level, in
> progress. MEASURED, by grep on that file: it instantiates **five entities,
> all of them D** -- `seq_desc_fetch`, `seq_opdec`, `seq_region_lock`,
> `seq_vec_issue`, `seq_vec_res`. A, B and C enter through **unit adapters**,
> and its own banner says *"unit C always *** ATTENTION IS A STUB. SEE THE
> BANNER. ***"* and *"THE LANE ARRAY `attn_lane_skel` IS A PRICING SKELETON AND
> COMPUTES NOTHING. C cannot produce an attention output."* It also carries an
> `err_unit_stub` output. So the statement above stands as written for both the
> committed tree and that file: **no entity instantiates two of the four
> subsystem families.** What the file does change is the ordering advice in
> section 4 item 10 -- the adapter layer that item calls for is being written
> now, and its author has already independently reached this document's
> conclusions about C and about `seq_top_skel`. Every other measurement in this
> document is against the committed tree at `b66c4b4` and is unaffected.

| pair | status |
|---|---|
| A <-> B | **NEVER** |
| A <-> C | **NEVER** |
| A <-> D | **NEVER**. A is a behavioural stub in every D bench (`sim/tb_seq_vec_seam.vhd:692-715`) |
| B <-> C | **NEVER** |
| B <-> D | **NEVER**. B is a stub |
| C <-> D | **NEVER**. C is a stub |
| D <-> E | **NEVER**. E is a stub and `tp_collective_skel` is instantiated by nothing |
| A <-> `weight_streamer` | **CONNECTED**, structurally inside A, over a behavioural AXI slave fed from the real packer image |
| A <-> HBM | **NEVER** |
| B <-> HBM | **NEVER**. `gdn_block` has no AXI master |
| C <-> HBM | **NEVER**. No C top exists |
| anything <-> `hbm_tg` | **NEVER**. `hbm_tg_ip` has no parent; the whole HBM branch is orphaned |
| D-ctrl <-> D-vec | **CONNECTED**, the one real seam |
| D-ctrl internal (fetch / opdec / lock) | **CONNECTED** |
| D <-> region banks | **NEVER -- the region banks do not exist** |

**ESTIMATE, from the project's own base rate.** Two seams closed, four findings
each. Seven subsystem-level seams remain plus the region fabric, so roughly
**25 to 30 integration findings should be expected**, none of which any current
testbench can reach.

**`sim/probe_abc_ports.vhd` is not a counter-example.** MEASURED: it
instantiates `seq_desc_fetch` and nothing else (`:187`). Its A, B and C are stub
responders. It is a control-level measurement over the real 491-descriptor
table, and a good one, but it is not an integration.

---

## 3. Regression state, and the difference between passing and verified

MEASURED, `bash sim/regress.sh --jobs 4`, 2026-08-28, GHDL 1.0.0 mcode:

```
 suite sim   PASS 46   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 72   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 72 passing, matches the recorded floor of 72
 REGRESSION: PASS
```

**The gate is green and the gate is honest.** It lists its 5 NOCHECK and 19
SKIPPED entries individually with a reason each, rather than folding them into
the pass count. But the headline 72 covers less than it appears to, and three
things about the remainder matter here.

**MEASURED, `bash sim/regress.sh --coverage`: 82 files in `rtl/`, 62 reached by
the `sim/` suite, 38 by `tb/`, 23 by both. Five are reached by no testbench in
either suite:** `attn_c_ports_skel.vhd`, `attn_lane_skel.vhd`, `hbm_tg_ip.vhd`,
`seq_top_skel.vhd`, `tp_collective_skel.vhd`. Four of the five are pricing
skeletons that compute nothing, which is the correct reason to have no
testbench; the fifth is a generated wrapper.

**All 19 skips are post-synthesis netlist-versus-behavioural comparisons that
need xsim and UNISIM, and all of them belong to the old design.** They are the
gate-level half of the stories260K verification. Nothing on the 9B path is
skipped -- but nothing on the 9B path has a gate-level check either, because no
9B netlist exists.

**One of those skips is hiding a rotted testbench.** MEASURED:
`sim/tb_bfp_cmp.vhd:11,17,18` port-maps an `in_q : std_logic_vector(N*32-1
downto 0)` bus onto `bfp_pack`, and `rtl/bfp_pack.vhd:3-13` has no `in_q` port
-- that bus was replaced by the `o_raddr` / `i_rdata` read-ahead. The bench
cannot elaborate against the current RTL. It is skipped for the unrelated
`library beh` reason, so **the rot is invisible in the gate and `bfp_pack`'s
netlist-versus-behavioural check has not run since that interface moved.**

**A build hazard that follows from the skeletons.** Five of the 82 files in
`rtl/` compute nothing, distinguished from real RTL only by a `_skel` suffix.
A build script that globs `rtl/*.vhd` will synthesise all five into a design
that reports zero errors and produces zero results.

**"Has a passing testbench" and "is verified" are different claims, and on the
9B path the gap breaks down as:** six units with a committed mutation harness
(all in C), five with one in D, roughly fourteen bit-exact against an
independent C oracle without a reproducible harness, and the rest
self-consistency or tolerance checks. `gdn_recur_pipe` -- the shipping
recurrence unit -- passes by discarding its oracle. `gdn_scalar` passes with
its accuracy oracle reported rather than asserted. `gdn_block` passes on four
structural asserts because the regression runs it at default skew.

## 4. Ordered work to a FIRST token, shortest path first

"First token" means: the card produces one token identifier that came from
9B weights in its own HBM, by whatever route, correct or not. Correctness is
section 5.

The ordering is by dependency, and the first three items are gates on
everything after them.

**0. Put the card in the slot and train the link.** MEASURED: this is the only
step whose tooling is finished. `hw/fk33/bit/fk33_pcieep.bit` is built and
meets timing, `hw/fk33/host/fk33_go.sh` is the single command, and
`hw/fk33/host/pci_baseline.txt` is the pre-insertion snapshot that makes a
silent card diagnosable. Remaining: build `xdma.ko`
(`hw/fk33/host/build_xdma_driver.sh`, never run, and it warns that kernel 6.x
API breakage is unknown), enumerate, and run `fk33ctl.py load`/`verify` against
HBM. **Nothing downstream can be tested on hardware until this is done, and
nothing downstream depends on its outcome**, so it is both first and
parallelisable.

**1. Decide `ROWS_IF`, once, explicitly.** It gates the streamer, the packer and
the image builder together, and writing any of the three first risks writing
all three twice. The evidence is now in: A post-route at `ROWS_IF = 48` at
0.717 V is **208.77 MHz** (MEASURED, `sim/ooc_micro/pnr_results.csv:27`),
`NPORT = ROWS_IF x 9/16` is exact with 30 ports available, and 48 is the
largest legal value. The remaining unknown that could still move it is whether
ACLK can reach twice `f_core`; that is measurable on the card that is about to
be in the slot.

**2. Write the HBM weight front end.** Six files, none of which exist:
`rtl/hbm_rd_lane.vhd`, `rtl/hbm_weight_streamer.vhd`, `rtl/fk33_arena_pkg.vhd`,
`rtl/matvec_int4_hbm.vhd`, `ref/hbm_weight_streamer.c`,
`sim/tb_hbm_weight_streamer.vhd`. This is a **rewrite, not a
parameterisation**, and the design document says so
(`docs/2026-08-27_hbm-weight-streamer-design.md:534-536`): `AXI_DW` doubles to
256 so the lane-equals-row coincidence dies, the module becomes dual-clock
(300 MHz HBM ACLK against a 208.8 MHz core), and the per-lane bases collapse to
one offset plus a constant arena table. `weight_streamer.vhd` and
`matvec_int4.vhd` are explicitly not modified: they are the AXU3EG's validated
path.

**3. Repack the model in FK33 geometry, and build a whole-model image.**
`tools/pack_int4.py` needs a 256-bit `AXI_DW` byte layout and multi-sub-region
scales, plus an image builder and a manifest, neither of which exists. **A
Qwen3.5-9B checkpoint does not exist on this machine** (MEASURED: nothing under
`/mnt/storage/llama-models` matches 9B or Qwen3.5), so obtaining it is a
prerequisite that no document has yet listed.

**4. Write the host descriptor generator.** The consumer is written, byte-pinned
and well tested; the producer does not exist in any language. `sim/seq_tbl_pkg.vhd`
already emits the real 491-descriptor 9B token table from `rtl/model_cfg_pkg.vhd`
and is the reference implementation to port. The sequencer spec asks for **two**
generators producing byte-identical tables; there is one, and it is in the DUT's
own language.

**5. Build D's missing middle.** In dependency order: the region banks and
region fabric, `seq_top` as real RTL replacing `seq_top_skel`, the base-array
fetch and codebook load, and the AXI grant mux with the outstanding-transaction
counters that `axi_rd_port` does not currently expose.

**6. Build the two missing D-vec operators**, `OP_VEC_NORM` and `OP_VEC_SWG`,
to the `seq_vec_issue` bus contract. `swiglu.vhd` and `rmsnorm.vhd` cannot be
reused: their interfaces are unbuildable at 9B widths. `rmsnorm_rs.vhd` is the
closest existing arithmetic but keeps the old wide-bus interface and has no
design parent.

**7. Build C's array.** `attn_lane`, `attn_score_tree`, `attn_acc`,
`attn_qk_norm`, `attn_kv_axi` and `attn_ctrl`. This is the largest single
block of unwritten RTL in the project and the pricing skeletons have already
answered the two questions that gate its shape.

**8. Give B its memories and its schedule.** The recurrent state (2 MiB per
layer at 9B), the conv taps, and the elastic state feed with its drain
interlock. Then overlap the phases, which currently run strictly sequentially,
and re-check the 367-cycle per-head deadline against the real feed rather than
a testbench producer. Decide the `o_sat` policy while doing it.

**9. Solve the embedding lookup.** 545.6 MiB in HBM, one row read per token,
and the descriptor program has **no opcode for it** (MEASURED:
`rtl/seq_opdec.vhd:283-290` lists eight opcodes and none is an embedding
lookup; `sim/seq_tbl_pkg.vhd`'s table starts at `OP_VEC_NORM` on region `R_X`
and nothing fills `R_X`). Either the host writes `R_X` over PCIe before each
token, or an opcode and a unit are added. Nobody owns this.

**10. Integrate, in seam order.** A <-> D first (it is the highest-traffic seam
and the one whose stub has been most exercised), then B <-> D, then C <-> D,
then the whole. Budget the seam-defect base rate from section 2. **This item is
already under way in an uncommitted `rtl/llama_top.vhd`** -- see the note in
section 2 -- which builds the adapter layer with A, B and C behind stubs. That
is the right shape: it makes the seams observable before the units behind them
exist, and it will keep working as each stub is replaced.

**11. Build the composed die and close timing on it.** No composed netlist has
ever been synthesised. Every DSP, LUT, BRAM and Fmax figure in the project is
per-unit and out-of-context.

**ESTIMATE, stated as a range because the project has no velocity data for
work of this kind:** items 2, 4, 5, 6 and 7 are each multi-day pieces of new
RTL with the project's own standard attached (an independent C reference,
bit-exact verification, and mutation testing of the reference before the RTL).
Item 7 alone is comparable in size to all of B. **A first token is weeks of
work, not days, and the critical path runs through C's array and D's middle,
not through A.**

---

## 5. What a CORRECT token additionally needs

A token that is merely produced is not the goal. These items do not block a
first token and do block a right one.

**5.1 There is no whole-model reference for Qwen3.5-9B.** MEASURED: `ref/`
holds per-unit C oracles and exactly one whole-model reference,
`ref/run_fx.c` for stories260K. Nothing in the repo can say what the right
answer for a 9B token is. Without it, "the card produced a token" and "the card
produced the right token" cannot be distinguished at all.

**5.2 The numeric-fidelity measurement is built, validated and not finished, and
it was run on the wrong model.** `docs/2026-08-27_epsilon-class-measurement-plan.md`
substitutes fixed-point arithmetic into a live llama.cpp forward pass through
`cb_eval`. It ruled out the named catastrophic class for B's emit chain
(5.34e-4 relative RMS, +0.0035 perplexity at 20 chunks) -- but **on
Qwen3.8-27B**, because that is the checkpoint present on this machine. Four
sites remain unbuilt (the recurrence, the conv, the scalar path, and the
l2norm, which has no C model at all), and the perplexity number does not
resolve inside the +/-0.02 scatter band without the full 655-chunk corpus.

**One result from that document must not be forgotten: the cheap proxy is
refuted.** The noise-calibration curve is flat -- 1e-6 through 1e-1
multiplicative noise all land in the same band, with 3% noise scoring better
than baseline. Relative error cannot be converted to a perplexity cost. The
proxy catches catastrophe and ranks variants; it cannot price them.

**5.3 The vocabulary is unverified.** `rtl/model_cfg_pkg.vhd:70` says 248,320.
The shipped Qwen3 tokenizer is 151,936. D's own spec lists this as
undetermined and notes that lm_head is 342,560 cycles per token, so a 1.6x
error is real time as well as a wrong answer. **Nothing in any spec derives the
number and it has not been checked against a 9B GGUF, because there is no 9B
GGUF here.**

**5.4 `l2norm_rs` is tolerance-checked, not bit-exact, and has no C model.**
This is the site the direction review singles out as having no visibility of
any kind, and the l2norm recipe has already collapsed once
(`docs/debugging/2026-08-25_l2norm-recipe-collapse.md`), certified by a
testbench that computed its golden from the same recipe the DUT implements.
Writing `ref/l2norm_vec.c` is the single highest-value piece of reference work
outstanding.

**5.5 Mutation coverage is C and D only, and B's is unreproducible.**
MEASURED: 17 `sim/mutate_*.sh`, all C or D. No A file and no B file has one.
`attn_kv_quant` and `attn_score_q12` are bit-exact with no script. B's spec
cites mutation kill counts -- "3 mutations caught", "5", "4" -- that **nothing
in the repo can reproduce**; the work was done by hand in-session and recorded
in prose. The project's own experience is that mutation testing finds gaps in
the *checks* about as often as it confirms them: five in one session on
`attn_gate` and `attn_emit` alone, two of which were oracles that read a value
the DUT itself produced.

**5.5a `gdn_recur_pipe` is the shipping recurrence unit and has no accuracy
check.** MEASURED: `sim/tb_gdn_recur_pipe.vhd:147-148` reads the oracle `u` and
`o` columns and discards them, so the bench proves only that the pipelined unit
transcribes `gdn_recur`'s recipe. One generic away sits a known defect that
zeroes the entire first-token state in 7.0% of draws. The fix defaults on; the
regression could not tell you if it stopped.

**5.6 `gdn_block` has no oracle, and in the gate it does not even run its own
property.** Its skew-invariance check is strong and found three seam defects,
but it proves the block is deterministic under producer timing, not that it
computes Gated DeltaNet. MEASURED: `sim/regress.sh:639` runs the bench once at
default generics, so the skew sweep happens only under `sim/run_gdn_block.sh`.
Two fixes are owed and they are cheap: run the sweep in the gate, and write
`ref/gdn_block_vec.c`. The second is the same artefact 5.2 needs.

**5.6a Four checks in B print rather than assert.** `err_conv`, `err_g`,
`err_se` and `y_sat` are reported with no severity in `tb_gdn_block`, so a run
in which the conv errored or the output saturated still prints PASS. Two other
B benches have already been caught in this exact shape and promoted to
`severity failure` (`tb_gdn_conv_tvalid_skew`, `tb_b_audit_ser_handshake`);
this is the third instance and it has not been.

**5.7 C is built at `MAXCTX = 2048`.** Beyond that the softmax denominator
width and the reciprocal width are outside their stated ranges. This is a
correctness cliff, not a performance one.

**5.8 The rescale regime is unmeasured on real scores.** C's expected rescale
count assumes exchangeable score sequences; the worst case costs an
unacceptable 0.25 L1 weight distortion. No measurement of real 9B or 27B score
sequences exists, and the stories260K analog does not transfer. There is
observability and no mitigation.

**5.9 The die clock is A-bound at 208.8 MHz and every budget in the repo
predates it.** MEASURED post-route at 0.717 V, `ROWS_IF = 48`:
`sim/ooc_micro/pnr_results.csv:27` gives **208.77 MHz**, with the path now
70.7% route, so the next fix will not be another logic narrowing. B at
`SILU_LANES = 8` is 231.9 MHz. Separately,
`docs/2026-08-27_verdicts-at-0.717V.md` records that **none of fourteen
measured configurations reaches 237.8 MHz**, and that the 16.5% voltage derate
generalised across the project is the smallest number in the measured set
(the range is 16.5% to 28.0%), so every scaled estimate built on it is
optimistic.

**5.10 `rtl/rmsnorm.vhd` as shipped runs at 138.4 MHz.** It misses everywhere it
is instantiated, and D reuses its arithmetic for the layer norms. Whichever
unit becomes `OP_VEC_NORM` must not be that one.

---

## 6. What I could not determine

Stated plainly, because a tidy conclusion that overstates completeness is the
failure this document exists to avoid.

1. **How long any of section 4 takes.** There is no velocity data in the repo
   for writing a new subsystem to the project's verification standard. The
   "weeks not days" in section 4 is an ESTIMATE from the size of C's array
   against the observed size of B, and nothing more.

2. **Whether the composed die closes timing at all.** No composed netlist
   exists. A is 208.8 MHz alone, out of context, without its streamer. The
   die-wide BRAM sum has never been added by anyone, and the DSP sum is
   90.5% to 91.9% at `ROWS_IF = 58` and roughly 75% at 48 -- but both are sums
   of out-of-context measurements.

3. **Whether the region banks can deliver the 1-element write and 1-cycle
   512-bit read simultaneously** once the three-region read mux is in the path.
   D's spec asserts the mux adds no pipeline stage. That is exactly the class
   of claim this project's timing rule exists to catch, and no synthesis has
   tested it. If it needs a stage, A's port timing changes.

4. **Whether ACLK can reach twice `f_core`.** It would halve the port count and
   let `ROWS_IF = 64` fit in 18 ports. 350 MHz misses by 0.395 to 0.467 ns
   today. Unattempted, and measurable on the card.

5. **HBM read latency and its jitter across 27 concurrent readers.** It sizes
   `DEPTH` and `MAXOUT`, hence roughly 108 BRAM. `hbm_tg` measured throughput
   and `arstall`, never latency. Small to add, runnable on the existing card.

6. **The real per-block cost of B.** The published range is 12,288 to 35,942
   cycles, a factor of 2.9, and it resolves only when the state feed and the
   double banking exist.

7. **Whether the 9B numbers are right at all.** Every 9B figure in every
   document is reconstructed from `rtl/model_cfg_pkg.vhd`, whose 9B row comes
   from an HF `config.json` rather than from a checkpoint on this machine.
   **No Qwen3.5-9B checkpoint exists here.** The 27B row is verified against a
   shipped GGUF; the 9B row is not.

8. **How many descriptors a 9B token actually is.** `sim/seq_tbl_pkg.vhd:93-97`
   computes `TBL_STEPS = 24 x 16 + 8 x 13 + 3 = 491`, and that is the table the
   only executable evidence walks -- `sim/probe_abc_ports.vhd:14` and
   `docs/2026-08-27_hbm-port-contention.md:80,135` all say 491.
   `rtl/seq_desc_fetch.vhd:148` says **546 at 9B** in a comment sizing the step
   index width. The two do not reconcile at either `NCARDS` value (N > 1 gives
   `24 x 18 + 8 x 15 + 3 = 555`). Eleven bits covers both, so nothing is broken
   today, but one of the two numbers is wrong and the wrong one will be quoted.
   Applying this document's own rule -- believe the executable artefact over
   the comment -- **491 is the number**, but I did not determine where 546 came
   from.

9. **Whether `hw/fk33/bit/` survives.** MEASURED: it is untracked in git. The
   one bitstream whose build is the closed blocker of the last week is not
   under version control.

---

## 7. Corrections this audit makes to existing documents

Recorded here rather than by editing history, per the project's convention.

1. **`docs/2026-08-27_weight-path-audit.md` hop 3 is stale.** It says the XDMA
   endpoint bitstream is "in the block design, not built". It was built,
   routed and saved at 2026-08-27 22:58 with `WNS = +0.275 ns`.
   `docs/2026-08-27_fk33-pcie-bringup-procedure.md`'s BLOCKER section is stale
   for the same reason.

2. **`docs/2026-08-27_weight-path-audit.md` hop 10 is closed** by `a1f315b`,
   and hop 11 now fails loudly rather than silently.

3. **The weight-path audit's section 4.2 claim that "the RTL has never consumed
   a file that `pack_int4.py` wrote" is false for gateware.** `hw/README.md:160-170`
   documents the flow, and the 2026-08-23 board acceptance run consumed a named
   GGUF tensor that only `pack_int4.py` could have produced. The statement is
   true of simulation and false of the board.

4. **`rtl/model_cfg_pkg.vhd:82-83` still says "about 4.5 GB against 8 GB HBM".**
   That drops the scales. The residency map's figure is 5.036 GB stored.

5. **`rtl/matvec_int4.vhd:14-20` still says the descriptor is driven by the PS.**
   A VU33P has no PS. This is the same sentence that hop 9 of the weight-path
   audit is about.

6. **The "add an elastic buffer in front of the emit chain" prescription in
   `docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md` is withdrawn** for
   the `RECUR_LANES = 64` case by the measurement in
   `docs/debugging/2026-08-27_gdn-block-top-level.md:175-190`: the shortfall is
   a steady-state rate deficit of 111 cycles per head, and no finite buffer
   fixes a rate deficit.

7. **`docs/superpowers/specs/2026-08-21-gated-deltanet-design.md`'s mutation
   kill counts cannot be reproduced.** The status table cites "3 mutations
   caught", "5 mutations caught", "4 mutations caught" for B units. MEASURED:
   there is no `mutate_gdn_*`, `mutate_l2norm_*` or `mutate_rmsnorm_*` script
   in `sim/`. The work was done by hand in-session and recorded in prose. The
   counts should be read as historical notes, not as reproducible evidence.

8. **`sim/probe_abc_ports.vhd:8` records the published verdict as
   "69 PASS / 0 FAIL".** It is now **72 PASS / 0 FAIL** (MEASURED today). The
   file's own note that promoting it to `sim/tb_seq_abc_exclusive.vhd` is "the
   whole of the promotion" still stands, and would take the suite to 73.

---

## 8. CORRECTION, appended 2026-08-28 evening: 56 commits later

This audit was written at `b66c4b4`. It is now 56 commits stale and several of
its headline verdicts are wrong. Nothing above is edited out; this section says
what changed and, more usefully, **what the audit's METHOD got wrong.**

### 8.1 The method correction, which matters more than any verdict

The audit classifies each unit by evidence class (V, V-, B, S, E, P, X) and
sums those into a subsystem verdict. Subsystem C was rated *"Auxiliary path
only, verified to the highest standard in the repo"*, and every one of its
eight existing units genuinely was.

**Those units were then composed into `attn_block`, and the block did not
compute attention.** The first block-level oracle (`ref/attn_block_vec.c`,
commit `8baa413`) found 64 of 64 mantissas wrong and bisected to two
independent defects. The bench that existed at the time ran seven properties
and passed all of them; its own header said the quiet part outright,
*"WHAT IS DELIBERATELY NOT CHECKED: the VALUES"*, and **of 17 wiring mutations,
13 passed all seven.**

So: **a per-unit evidence class says nothing about the composition.** A column
of V- entries and a green integration test are jointly compatible with a block
that computes wrong numbers. Any future audit in this shape needs a separate
column for "is there an oracle at the level of this thing's OUTPUT", and X in
that column should outrank every V beneath it.

The same shape recurred four more times today, which is why it is stated as a
rule rather than an anecdote:

- `gdn_recur_pipe`, the SHIPPING recurrence, was checked only for equality with
  `gdn_recur`'s recipe; its bench read the oracle's accuracy columns and threw
  them away. Restored (`d64c0b6`): it passes, to the same sixteen digits as the
  unit that was already asserted. The hole was in the checking, not the maths.
- `l2norm_rs` was tolerance-checked with no C model at all. Now bit-exact over
  182 cases and 46,592 elements, and the sweep found `l2norm_rs` **rejects its
  own maximum legal input** (worklog OI-7).
- The Python tokenizer was verified over 53,411 strings AND an exhaustive
  1.1M-codepoint sweep, and was still wrong on 243 of 248,320 token ids,
  because every one of those checks drives it from the INPUT side and UNUSED
  tokens are unreachable from encode. Coverage of the input space is not
  coverage of the output space (`c8a57d8`).
- Subsystem A was bit-exact at the FK33 geometry **at a burst length the
  hardware cannot issue**: the bench used AXI4's 4 KB rule, but the HBM slave
  is AXI3 with a 4-bit ARLEN, so 16 beats is the cap, not 128 (`809ada7`). A
  module's own assert bounds what THAT MODULE permits and says nothing about
  what the slave on the other end accepts.

### 8.2 Verdicts that are now wrong

| audit said | now |
|---|---|
| **A** "built for the WRONG DEVICE", `ROWS_IF = 48` exists in no RTL, "no `tb_weight_streamer.vhd`" | Bit-exact at `ROWS_IF=48 / AXI_DW=256` over 27 AXI masters from real `.mv4i` bytes (`055b6ed`), at the legal AXI3 burst (`809ada7`). `tb_weight_streamer` exists. Descriptor control plane, HBM-to-core CDC and `MAXOUT` 2 -> 16 all landed (`a4f7e17`) |
| **C** "no multiply array at all", 6 of 13 units absent | `attn_mac_array` and `attn_block` exist and the block is bit-exact against a new independent oracle **after two real defects were fixed** (`1719ae3`, `8baa413`). The six spec-named units are still absent BY THOSE NAMES: the design took a different decomposition and the spec was never updated |
| **D** "`seq_top_skel` instantiates nothing", no descriptor program | `seq_top_skel` still instantiates nothing and `llama_top` is the de-facto top. But the descriptor format is settled and byte-pinned, and it is D's own descriptor plus an extension in the one region `seq_desc_fetch` never reads (`a4f7e17`) |
| "**seven of the eight subsystem pairs have never met**" | `llama_top` now instantiates A, B, C and D's control core together, and a 32-block token passes with real weights |
| "no packed image exists in FK33 geometry" | 250 tensors, 4.7099 GiB, packed, DMA'd to HBM and verified hash-identical **on silicon** |
| "the FK33 has never enumerated on PCIe" | It enumerates at Gen3 x4, `EqualizationComplete+`, and its thermal guard has been observed to halt, latch and release |
| Token I/O "stories260K placeholders" | Still true for embedding and LM head. But the tokenizer now exists in Python AND C, bit-exact against llama.cpp over the corpus, every one of 248,320 ids, a 1.1M-codepoint sweep and 20,051 malformed-byte strings |
| Regression floor | 73 at audit time, **78 now** |

### 8.3 What the audit got RIGHT and is worth repeating

Its central claim survives intact: **"the dominant category of remaining work is
units that do not exist rather than units that are unverified."** Still true.
`attn_kv_axi` (the HBM KV interface) does not exist, so subsystem C cannot read
a KV cache. Nothing emits a descriptor program. The embedding and LM head are
still 512-entry ROMs. And its verdict on E, that it is correctly out of scope at
`NCARDS = 1`, needed no revision.

Its insistence that **where a document and the RTL disagree, the RTL wins** is
what made today's corrections findable, and it should be read as applying to
this audit too.
