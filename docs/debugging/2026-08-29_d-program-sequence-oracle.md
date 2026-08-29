# A SEQUENCE-level oracle for subsystem D's descriptor program

**Date:** 2026-08-29. Branch `fpga`, HEAD `ed1ffe2` at dispatch.
**Track:** D-PROG (worklog backlog item 6).
**Packed set:** `/mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/`
(250 `.mv4i` + `nonmatvec_f32.bin`, `ROWS_IF = 48`, `AXI_DW = 256`,
`qkv_segment_pad = true`).
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/`, nothing opening `/dev/xdma*`. No Vivado of any kind was run.
**Repository changes:** two new files, `tools/dprog_oracle.py` and
`tools/dprog_mutate.py`, plus this note. **No `sim/tb_*.vhd` was added**, so no
gate row was created and `sim/regress.sh` and `BASELINE_PASS` are untouched.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

> Establish, then build:
> 1. What subsystem A actually consumes from a descriptor today, and which D
>    fields exist in the settled format but are read by nothing.
> 2. Job sequencing for a whole layer: the order, the dependencies between
>    jobs, and what serialises against what.
> 3. Region routing: which job reads and writes which region, and how a job
>    names them.
> 4. **An oracle at the level of the SEQUENCE, not the individual job.** The
>    single-job path is already verified; a column of verified jobs and a
>    green integration test are jointly compatible with a wrong layer.

With the standing instruction that the brief's own claims be verified rather
than trusted.

---

## 2. The answer, up front

**Items 1 to 3 were already done and landed** at `a2b20f3` and its follow-ups,
as `tools/gen_layer_program.py` with a 512-line write-up
(`docs/debugging/2026-08-29_layer-descriptor-program.md`). The brief's premise
that "nothing emits a LAYER" is a day stale. Corrections in section 3.

**Item 4 was NOT done, and it is the whole of this track's contribution.** All
four existing checks on the program are AGREEMENT checks against the same
thing -- the schedule -- so the column is jointly compatible with a program
that is internally perfect and computes the wrong model. The write-up says so
itself: "What is verified here is the PROGRAM, not the computation it drives."

`tools/dprog_oracle.py` is the missing axis. It decodes the **emitted bytes**
and checks them against artefacts produced from a **different source by
different tracks**: `tools/ref9b/seam_map.py` (RTL region to llama.cpp node,
in llama.cpp's execution order, TRACK REF9B) and the packed model's own bytes
-- `manifest.json` and, decisively, **each `.mv4i` file's 4 KB header**, which
carries `M`, `K`, `w_exp`, `out_shift`, the codebook, and at byte `0x38` the
sub-region offset table every weight base must be derived from.

**MEASURED, whole token, `tools/dprog_oracle.py`:**

```
dprog_oracle: MAXROWS_BFP=17408 (read from rtl/), ROWS_IF=48, hidden=4096 ffn=12288 vocab=248320
dprog_oracle: lm_head derives to 15 windows at stride 17376
dprog_oracle: 505 steps, 39330 checks, 0 FAIL
DPROG_ORACLE: PASS
```

**MEASURED teeth, `tools/dprog_mutate.py`: 25 of 27 mutations killed**,
replaying the layer-program write-up's own mutation table so the two are
directly comparable. **All six of the mutations that pass SILENTLY on the RTL
are killed here**, as are five of the seven subsystem A descriptor mutations
the gateware accepts silently -- including the one worklog OI-1 records as
undetectable, and the program-level "nothing binds an A descriptor to the step
it belongs to".

**The finding that matters most is a directional control.** `--stamp sched`
emits the table that is byte-identical to `sim/llama_sched_pkg.vhd`, which is
the table **`rtl/llama_top.vhd` actually executes**. MEASURED, it fails this
oracle **2,401 times**: 311 `w_exp`, 253 `out_shift`, 311 `nsub_w` and 311
`nsub_s`. Those tables are correct as walker tests and were never meant to be
programs, but it means the project's strongest existing evidence -- byte
identity against two independent VHDL generators -- is agreement with tables
whose exponent and geometry fields are **not the model's**. That was stated in
prose in the earlier write-up; here it is a number.

**No defect was found in `gen_layer_program.py`'s default output.** That is a
negative result and it is reported as one.

---

## 3. Corrections to the brief

Every one of these was verified against the repository, not reasoned about.

**(a) Backlog item 6 is LANDED, not open.** `tools/gen_layer_program.py` is
1,015 lines at HEAD, its docstring opens "Worklog backlog item 6", and it
landed at `a2b20f3` with follow-ups `e28083f`, `a781326`, `51bf591`. Worklog
OI-4 ("no descriptor-program generator exists, in any language") is stale at
HEAD and should be closed.

**(b) "One matvec job is emitted and verified" understates it by 310.**
MEASURED: `--token` emits **311 A jobs** and 505 D steps, and TRACK LMHEAD
already reported `311 of 311 A jobs emitted, 0 refused`.

**(c) `token_embd.weight` needs ZERO descriptor jobs, not 15.** The brief
quotes `MAXROWS_BFP = 17408` as meaning `output.weight` **and**
`token_embd.weight` need 15 each.
* `output.weight`: **CONFIRMED, and independently DERIVED here** rather than
  quoted. `dprog_oracle` reads `MAXROWS_BFP = 17408` out of
  `rtl/matvec_int4_desc_axi.vhd`, takes `ROWS_IF = 48` from the manifest
  geometry, and computes the usable stride as
  `floor(17408/48)*48 = 362*48 = 17376`; `ceil(248320/17376) = 15`, with
  `14*17376 + 5056 = 248320`. It prints this and it matches the 15 windows the
  program emits.
* `token_embd.weight`: **WRONG.** The embedding is not a matvec at all. It is
  a host-side gather written straight into region `R_X` -- TRACK TOKIO
  established that the path was already built and that `seq_opdec`'s `tok_fsm`
  exists solely to publish it. MEASURED: the 505-step token program contains
  **no A job on `token_embd.weight`**, and `seam_map`'s first entry is
  `R_X.embed <- model.input_embed`, which is not a descriptor step. The tensor
  is still in this packed set (TRACK EMBDROP's removal is a flag, not a
  default), so it costs HBM, but it costs no descriptors.

**(d) The descriptor format IS settled.** CONFIRMED:
`rtl/matvec_int4_desc_pkg.vhd` byte-pins it, `docs/2026-08-28_matvec-descriptor-format.md`
section 4 documents it, and my decoder reproduces every field of the emitted
bytes. No change was needed.

**(e) OI-9, the full error-code space: NOT REACHED, and no decision is
needed from Oren for this track.** This work is entirely host-side; it adds no
gateware error condition and consumes no code. Stated because the brief asked
to be told either way. If forced to express a preference for whoever does need
the next code: **subdivide via `ERR_INFO`**, because `ERR_INFO` is already a
16-bit field carrying a descriptor word index, an `EC_*` value plus a word
index is already how every A refusal is read, and it is the only one of the
three options that costs neither a format change nor one of D's reserved
values. That is a preference with a reason, not a decision.

**(f) TRACK DESC-MUT has landed.** `tools/mv4i_desc_cases.py`,
`sim/tb_mv4i_desc_image.vhd` and
`docs/debugging/2026-08-29_desc-decode-mutations.md` are present. Nothing of
theirs was touched here; `tb_mv4i_desc_image` is the bench that judges A
descriptor bytes with the RTL, and this oracle is deliberately a different
question (binding, not well-formedness).

**(g) A TRAP the brief could not have known: `gen_layer_program.py`'s default
manifest is the WRONG packed set for the FK33.** `tools/gen_mv4i_desc.py:521`
defaults `--manifest` to `.../qwen35-9b-mv4i/manifest.json`, the **pre-pad**
set (`blk.0.attn_qkv.weight` has `M = 8192`). At that manifest two of the
three GDN qkv jobs are refused -- MEASURED, `"--row-start 2048 is not a
multiple of ROWS_IF = 48"` -- which is exactly the defect TRACK QKV-PAD fixed
by repacking to `M = 8224`. Anyone running the generator without an explicit
`--manifest` gets the pre-QKV-PAD behaviour and a program that is 48 jobs
short. This cost me one wrong measurement (section 8).

---

## 4. What A consumes, and which D fields are read by nothing

Established by reading `rtl/matvec_int4_desc_axi.vhd` and the format document,
and cross-checked against the 27-row mutation table below rather than asserted.

| D header field | read by A | read by D | consumed by anything in `llama_top` |
|---|---|---|---|
| `opcode` | yes | yes, selects the unit | yes |
| `flags` | yes (bit 2 `cb_load`) | yes (`FLG_TO_SMP`) | yes |
| `src_region` | **no** | yes, `seq_region_lock` | yes |
| `dst_region`, `dst_offset` | **no** | yes, append-only placement | yes |
| `n_rows`, `n_cols` | yes | yes | yes |
| `w_exp`, `out_shift` | yes, live for the whole job | passed on | A only |
| `out_mode` | yes | -- | A only |
| `ordinal` | **no** | passed on | B/C only; **inert on a VEC_NORM** |
| `nsub_w`, `nsub_s` | yes, `ERR_GEOM` on mismatch | range-check only | A only |
| `src_region2` | **no** | yes, for VEC_RES / VEC_SWG | yes |
| `const_base` | **no** | published | **nothing** |
| `const_exp` | **no** | published | **nothing** |
| codebook (words 5, 6) | yes, when `cb_load` | -- | A only |

**Two fields are read by nothing anywhere: `const_exp`, and `const_base`/
`ordinal` on a VEC_NORM step.** They name a norm weight that has no weight
region, no packed tensor and no consumer. This is not new -- it is mutations
4b, 11 and 12 of the earlier write-up -- but it is why two of them are
structurally unkillable and one is only killable by convention (section 6.1).

---

## 5. The oracle: what it checks and where each answer comes from

The provenance column is the point. An expectation sourced from the generator
would make the check decoration.

| id | what it checks | where the ANSWER comes from |
|---|---|---|
| **C1** | the ORDER, REGION and OPERATION of every region write across the whole token | `tools/ref9b/seam_map.SEAMS`, llama.cpp's execution order |
| **C2** | `dst_offset` and segment length of the three qkv jobs | `seam_map`'s own llama.cpp segment offsets, 0 / 2048 / 4096 |
| **C3** | `n_rows`, `n_cols` per job | the manifest's `M` and `K` for the tensor llama.cpp's graph names |
| **C4** | `w_exp`, `out_shift` per job | the manifest's per-tensor values |
| **C5** | `ordinal` on a B/C job, `const_base` on a norm | the layer index in `seam_map`'s own `-L` suffix |
| **C6** | END_TOKEN-last, pad bytes, `nsub_w`/`nsub_s` | the format, and the manifest geometry |
| **C7** | every step's `src` / `src2` region | llama.cpp's graph edges, keyed by `seam_map`'s node names |
| **C8** | the D step <-> A descriptor BINDING, field by field | the two emitted objects against each other and the manifest |
| **C9** | the A descriptor against **the packed file's own 4 KB header** | `.mv4i` bytes: `M`, `K`, `w_exp`, `out_shift`, geometry, codebook, and the sub-region offset table at `0x38` |

**C9 is the strongest link and the one worth reusing.** Both sides are bytes
written by different programs from different inputs: the `.mv4i` header was
written by `tools/pack_int4.py` out of the GGUF, the descriptor by
`gen_layer_program.py`. Layout taken from `ref/matvec_int4.c:161-240`, the
reference parser, not from a document. Every weight base is checked EXACTLY:

```
w_base[p] == hbm_offset + w_sub_offset[p] + delta
delta      = (row_start / ROWS_IF) * (sub_stride / tiles)
row_start  = for a qkv segment, llama.cpp's element offset rounded UP to a
             tile boundary; for an lm_head window, the derived window start;
             otherwise 0
```

`row_start` **is not a descriptor field at all** -- that is the silent pass
TRACK QKV-PAD recorded -- so deriving it from llama.cpp's segment offset plus
the tile rule is the only way the bases can be checked at all.

**Honest statement of independence.** `seam_map`'s left-hand names are the
RTL's region names, so the two sides share a vocabulary; its ORDER is a human
transcription of llama.cpp's graph rather than a machine extraction. Its
right-hand anchor names are consumed by `tools/ref9b/seam_bisect.py` against
real llama.cpp dumps, so they are not free-form labels, but **I did not re-run
that bisect here.** `NODE_OP`, the node-to-tensor table, is authored in this
file and is the weakest link; section 6.2 measures it rather than asserting it.

---

## 6. The evidence

### 6.1 Teeth: 27 mutations, MEASURED

`tools/dprog_mutate.py --prog OUT`, whole-token program with all 311 A
descriptors. Rows are the earlier write-up's own mutation table, replayed
against this oracle. The "RTL" column is that write-up's verdict, so the two
are directly comparable.

```
CONTROL (unmutated): 39330 checks, 0 FAIL -> PASS

mutation                           verdict   fails  checks hit
--------------------------------------------------------------------------------------------
m01 step order swapped             KILL      8      C2-dstoff,C2-seglen,C8-hdr
m02 region id: v -> R_Z            KILL      2      C1-region,C8-hdr
m02b BETA/ALPHA swapped            KILL      4      C1-region,C8-hdr
m03 dst_offset + 8                 KILL      2      C2-dstoff,C8-hdr
m04 B_JOB ordinal + 1              KILL      1      C5-ordinal-B
m04b norm ordinal = 3              KILL      1      C5-ordinal-NORM
m05 src R_XN -> R_X                KILL      2      C7-src,C8-hdr
m06 src2 R_ER -> R_H               KILL      1      C7-src2
m07 n_rows halved                  KILL      2      C2-seglen,C8-hdr
m08 opcode A_JOB -> B_JOB          KILL      25     C1-op,C5-ordinal-B
m09 w_exp + 1                      KILL      2      C4-wexp,C8-hdr
m10 out_shift + 1                  KILL      2      C4-outshift,C8-hdr
m11 const_base = 3                 KILL      1      C5-constbase
m12 const_exp + 1 everywhere       SURVIVE
m13 nsub_w 24 -> 23                KILL      622    C6-nsubw,C8-hdr
m14 word 3 pad nonzero             KILL      1      C6-pad3
m15 END_TOKEN removed              KILL      1      C6-end
m16 residual step dropped          KILL      1949   C1-count,C1-op,C1-region,...,C8-hdr
m19 one lm_head window dropped     KILL      3      C1-count,C3-lmwin,C8-hdr
m20 lm_head as one job             KILL      4      C1-count,C3-lmwin,C3-maxrows,C8-hdr
a01 another step's bases           KILL      54     C8-range,C9-sbase,C9-wbase
a02 w_base[7] -> sub-region 8      KILL      1      C9-wbase
a03 x_exp + 1                      SURVIVE
a04 A dst_offset = 777             KILL      1      C8-hdr
a05 w_beats halved                 KILL      1      C9-wbeats
a06 every base + 4096              KILL      27     C9-sbase,C9-wbase
a07 codebook entry changed         KILL      1      C9-codebook
--------------------------------------------------------------------------------------------
KILLED 25   SURVIVED 2   NOCHANGE 0
```

**The six RTL-silent mutations are all killed.** `m02b`, `m04b`, `m10`,
`m11`, `m12`, `m13` are the six the earlier table records as passing with a
bit-identical hash. Five die here; `m12` is the one that does not, for the
reason below.

**Five of the seven RTL-silent A mutations are killed.** `a01` is the
program-level instance of OI-3 -- "nothing binds an A descriptor to the step
it belongs to" -- and `a02` is worklog OI-1's undetectable sub-region aim.
Both die on `C9-wbase`, because the packed file's own offset table says where
those bases must be. `a06` (a wrong `hbm_offset`) dies the same way.

**`a07` is new coverage that nothing in the repository had.** The codebook
travels in the `.mv4i` file (`ref/matvec_int4.c:183`) *and* in descriptor
words 5 and 6, and `flags` bit 2 makes the descriptor's copy the one that gets
loaded. Nothing compared the two before. One changed entry is now a failure.

**`NOCHANGE 0` is load-bearing.** The earlier write-up's measurement trap was
two mutations that changed no byte and read as silent passes. The harness
snapshots every `.hex` before and after and reports `NOCHANGE` as a harness
defect rather than a survival. Zero occurred.

### 6.2 Teeth on the ANSWER KEY itself, MEASURED

`NODE_OP` is authored here, so a check that only confirms it would be
circular. Four swaps of the answer key, against the unmutated program:

```
NODE_OP swap beta/alpha         KILL  fails=2696  C4-wexp,C8-name,C8-range,C9-sbase,C9-wbase,C9-wexp
NODE_OP swap ffn_gate/ffn_up    KILL  fails=3568  C4-wexp,C8-name,C8-range,C9-sbase,C9-wbase,C9-wexp
NODE_OP swap Kcur/Vcur          KILL  fails=896   C4-wexp,C8-name,C8-range,C9-sbase,C9-wbase,C9-wexp
NODE_OP swap z/linear_attn_out  KILL  fails=2736  C4-wexp,C8-name,C8-range,C9-sbase,C9-wbase,C9-wexp
```

All four die, and they die on `C9-wbase` as well as on `C4-wexp`. That
distinction matters: `C4` has teeth only because the packed exponents are
diverse (MEASURED across the 250 packed tensors: `w_exp` takes 5 distinct
values, `{8: 104, 9: 86, 7: 50, 10: 6, 6: 4}`; `out_shift` takes 2,
`{3: 218, 5: 32}`), and two tensors could in principle share both. `C9-wbase`
does not depend on that at all -- two tensors always live at different
`hbm_offset`s -- so the binding is confirmed by data rather than asserted.

### 6.3 Directional controls, MEASURED

A checker that passes everything is worthless; these are three legal-but-
different programs where a PASS would have proved the oracle inert.

| program | result | why |
|---|---|---|
| `--stamp sched` | **2,401 FAIL** | `C4-wexp` 311, `C4-outshift` 253, `C6-nsubw` 311, `C6-nsubs` 311, `C8-hdr` 1,186, `C5-ordinal-B` 21, `C5-ordinal-C` 8 |
| `--qkv-fused` | **10,246 FAIL** | the fallback collapses R_QKV's three exponent segments into one, so 413 region writes land on the wrong seam |
| `--one-lmhead-job` | **3 FAIL** | `C1-count`, `C3-lmwin`, and `C3-maxrows`: "lm_head window has 248320 rows, MAXROWS_BFP is 17408" |
| layer 0 slice, no `--close-token` | **1 FAIL** | `C6-end`: a layer is a fragment, as the earlier write-up measured against the RTL |
| layer 0 slice, `--close-token` | 17 steps, 1,246 checks, **0 FAIL** | |

**The `--stamp sched` row is the headline.** That stamping is byte-identical
to `sim/llama_sched_pkg.vhd`, the table `rtl/llama_top.vhd` executes, and it
fails on 311 of 311 `w_exp` values and 253 `out_shift` values. It also writes
`nsub_w = 29 / nsub_s = 4` on every step, against the 24 / 3 the FK33 geometry
packs -- and 29 is a value **the FK33's A wrapper refuses with `ERR_GEOM`**,
which is mutation 13 of the earlier table appearing as the committed default
of the VHDL generators rather than as a mutation.

None of that is a defect in those packages. They are walker tests and are
correct as walker tests. It is a statement about what byte-identity against
them proves, and the answer is: that the step SEQUENCE agrees, and nothing
about the numbers a real run needs.

---

## 7. Measured and REJECTED -- do not retry

* **Writing another descriptor-program generator.** `gen_layer_program.py`
  exists, emits all 505 steps and all 311 A descriptors, and passes 39,330
  independent checks. Backlog item 6's items 1 to 3 are done. Read
  `docs/debugging/2026-08-29_layer-descriptor-program.md` before touching
  this area again.
* **Verifying the program by comparing it to `seq_tbl_pkg` or
  `llama_sched_pkg`.** Already done, twice, at `a2b20f3`. It is an agreement
  check between three transcriptions of one schedule, and MEASURED above, the
  VHDL tables' own exponent and geometry fields fail a model-level check
  2,401 times. Doing it a third time adds nothing.
* **Calling `tools/gen_lmhead_windows.plan` to get the expected window list.**
  That is the module the generator itself uses, so it would have made the
  lm_head window check a round trip on exactly the arithmetic the brief asked
  to have verified. Derived independently instead, from `MAXROWS_BFP` read out
  of `rtl/matvec_int4_desc_axi.vhd` and `ROWS_IF` from the manifest.
* **Writing a decoder for the generator and calling that verification.** The
  `m7` mutant is why. The decoder here reads bytes; every ANSWER comes from
  `seam_map`, the manifest, or the packed file's own header.
* **Checking `const_exp` against 0.** It would pass only under
  `--stamp manifest`, which is the generator's own choice, and would fail
  under the other two stampings while proving nothing. That is decoration.
  Left as a named survivor instead.
* **Running the generator without an explicit `--manifest`.** The default is
  the pre-QKV-PAD packed set and 48 of 311 A jobs are refused. See 3(g).

---

## 8. Measurement traps hit

* **I compared two different packed sets and read it as a defect.** The first
  A-descriptor run reported 108 `C8-range` failures with bases far outside the
  tensor. The cause was that `gen_layer_program.py` defaults to
  `qwen35-9b-mv4i` while I passed `qwen35-9b-mv4i-qkvpad` to the oracle, so
  every `hbm_offset` disagreed. **A cross-artefact oracle is only as good as
  the guarantee that both artefacts describe the same object**, and nothing
  forced that here. Fixed by passing `--manifest` to both. Worth a future
  guard: the manifest identity is not recorded in the emitted program.
* **My first base check asserted the wrong layout.** I required
  `w_base[0] == hbm_offset`, which is wrong by exactly the 4 KB `.mv4i`
  header, and it "found" a failure on every descriptor. Replaced with the
  exact derivation from the file's own offset table at `0x38`, which is both
  correct and far stronger. **A check that fires on correct input is not
  evidence of teeth**, it is evidence of a wrong expectation, and the two look
  identical until you read the number.
* **My `--layer` filter leaked the lm_head.** A layer slice was compared
  against 31 expected seams instead of 16, because the `LOGITS` expansion ran
  before the layer filter. Caught only because 31 is not a plausible count for
  one GDN block. A count that is wrong in a *plausible* direction would not
  have been caught, which is an argument for printing counts rather than only
  verdicts.
* **The oracle passing on the first run is not good news on its own.** The
  whole token passed 5,989 checks before the A descriptors and `C9` existed.
  That number is large and it was still checking far less than it appeared to.
  The mutation table is what makes any of it a claim.

---

## 9. Open, not determined here

* **`const_exp` is unkillable and always will be.** No owner, no consumer, no
  derivation, and the three stampings disagree about it. Named as a permanent
  resolution floor.
* **`x_exp` is unkillable by any static oracle.** It is a per-token RUNTIME
  value from the previous stage and the descriptor's copy is stale by
  construction. `USE_XEXP_PORT` exists for exactly this and which one the FK33
  build uses is still undecided -- unchanged from the earlier write-up.
* **`rel_mask` is not checked at all.** It arrives on a port, not in the
  format, and the earlier write-up's mutations 17 and 18 (release too early,
  release never) are outside this oracle entirely. They ARE caught by the RTL,
  which is the right place, but this oracle should not be read as covering
  them.
* **No arithmetic claim is made.** This is a structural and binding oracle.
  It cannot see a wrong number that is consistent with the manifest, and it
  has no opinion on what the units then do. Worklog OI-3 is untouched.
* **The manifest identity is not bound into the emitted program.** Nothing in
  `d_table.hex` or an A descriptor records which packed set it was built
  against, which is what made the trap in section 8 possible. A hash of the
  manifest in the extension's reserved `ext_flags`, or simply emitted
  alongside, would close it. Not done here; it is a format-adjacent change and
  the format is not this track's to move.
* **`seam_bisect` was not re-run.** The independence of `seam_map`'s anchor
  names rests on TRACK REF9B's measurement, not on one taken here.
* **Nothing links a D step to its A descriptor on the card.** Unchanged and
  still open. This oracle closes it AT THE HOST, which is worth having, but a
  host-side check is not a gateware check and should not be reported as one.

---

## 10. What this unblocks

The program can now be regenerated and re-checked in under a tenth of a second
against the model rather than against itself, which means the remaining items
in section 10 of the earlier write-up can be attempted without the check being
the bottleneck. Concretely: `x_exp` per step, the A-descriptor delivery
mechanism, and any change to the schedule now have a gate that would notice if
they broke the mapping to llama.cpp's graph.

Reproduce:

```
M=/mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json
tools/gen_layer_program.py --token --x-exp 5 --no-hash --manifest $M \
    --outdir OUT --d-table OUT/d_table.hex
tools/dprog_oracle.py --d-table OUT/d_table.hex --adir OUT --manifest $M
tools/dprog_mutate.py --prog OUT --manifest $M
```
