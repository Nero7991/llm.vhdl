# The host seam in front of subsystem D: what D needs, what exists, what is missing

**Date** 2026-08-30. **Track** DSEAM. **Board row** N2, resolved by Oren the
same day. **Hardware** none: everything below is GHDL 1.0.0 (mcode) on the
workstation. **Nothing in this document has run on silicon.**

---

## 1. The question, verbatim

From the dispatch brief, which is itself carrying Oren's decision:

> Oren, today, verbatim: **"we don't want host controlling, let's get D
> working"**.
>
> That resolves open decision N2 [...] It selects **option (a): build an
> `fk33_seam` AXI-Lite block in front of subsystem D**, and explicitly rejects
> option (b), which was to let the host own the step loop.

and the four deliverables it asked for:

> 1. An honest integration map, before any code. What does D need to run one
>    layer with no host in the loop [...] and which of those exist today?
>    **Name the gaps.**
> 2. The `fk33_seam` AXI-Lite register block in RTL [...]
> 3. A bench that runs D through a whole layer with no host, comparing against
>    `ref/run9b`'s stream.
> 4. Say what is still host-side after your change, precisely.

---

## 2. The answer, up front

**D needed six things from a host and had a wire for each; two of them were
being driven PER STEP, and those two are what made "the host owns the step
loop" the default rather than a choice.** They are the release mask and the
descriptor memory. `rtl/fk33_seam.vhd` now owns both, so a token runs from one
AXI-Lite `GO` with nothing else touching `rtl/llama_top.vhd`'s host face.
`sim/tb_fk33_seam.vhd` runs two such tokens beside a directly-driven copy of
the same design and every element of `R_X`, the completion accounting and the
card's own position are identical on both. Fourteen mutations of the seam, all
killed, none of them by a property that predates this bench.

**Six gaps remain, and only one of them is inside D itself.** Named in
section 4. The largest is that D has never been connected to the subsystem-A
unit that is actually on the card: `llama_top`
binds `matvec_int4`, which has no descriptor plane, and fabricates each job's
weight base as `A_MEM_BASE + step * A_JOB_STRIDE`. The card's weights are at
manifest addresses that expression cannot produce.

**D is not a speedup and this document is not a performance result.** The
card's own counters fit `CYCLES = 21.67 * BEATS + 215` over a 6x range of job
size. The 215-cycle intercept is 1.07 us, so the per-job setup D amortises is
worth 0.33 ms across a 311-job token, and the 21.67 cycles per beat is
per-beat and does not amortise. What D removes is the ~8.4 s of MMIO in a
17.8 s token, not the engine's internal rate.

---

## 3. The integration map

### 3.1 What D actually is, measured

`rtl/seq_top_skel.vhd` is 32,673 bytes of carefully written skeleton and
**nothing instantiates it**. `sim/regress.sh`'s own coverage report lists it
among five files "REACHED BY NO TESTBENCH IN EITHER SUITE". Do not read it as
the design.

The real D core is five entities, and the only thing that composes them is
`rtl/llama_top.vhd`:

| unit | instantiated by |
|---|---|
| `rtl/seq_desc_fetch.vhd` | `rtl/llama_top.vhd`, `hw/fk33/rtl/compose4_top.vhd`, 3 benches |
| `rtl/seq_opdec.vhd` | same |
| `rtl/seq_region_lock.vhd` | same |
| `rtl/seq_vec_issue.vhd` | same |
| `rtl/seq_vec_res.vhd` | same |
| `rtl/seq_top_skel.vhd` | **nothing** |
| `rtl/seq_ctrl.vhd` | `tb/tb_e2e.vhd` only -- the stories260K path, not this one |

`hw/fk33/rtl/compose4_top.vhd` is a FIT VESSEL, not an integration: its own
header says "THE SUBSYSTEMS ARE NOT WIRED TO EACH OTHER". `grep -c seq_
hw/fk33/rtl/fk33_engine.vhd` is **0** -- the thing on the card contains no D
at all.

So: **`rtl/llama_top.vhd` is subsystem D's only integration, and it is a
simulation top.**

### 3.2 The six host inputs, and where each came from before this track

Taken from `rtl/llama_top.vhd`'s port list, not from a spec.

| # | wire | rate | driven by, before 2026-08-30 |
|---|---|---|---|
| 1 | `go` / `abort` / `tok_ack` | per token | a bench process |
| 2 | `tbl_len` | per model | a bench constant |
| 3 | `host_x_exp` | per token | a bench constant |
| 4 | **`rel_mask`** | **PER STEP** | `sim/tb_llama_top.vhd:1923`, `PLAN(n_chk).rel`, advanced on `obs_issue` |
| 5 | **`d_raddr`/`d_ren`/`d_rdata`/`d_rvalid`** | **PER FETCH** | a bench descriptor-memory model |
| 6 | `hw_*` in, `hr_*` out | per token | a bench preload / dump loop |

Rows 4 and 5 are the finding. Row 4 in particular: a 14-bit mask, one per
step, that must be stable while D's internal `chk_req` is high. At the 9B
shape that is 505 masks per token. **A host publishing those over PCIe is
the inner loop N2 rejected**, and until today nothing but a testbench had
ever published them.

### 3.3 Why the release mask is a separate table and not a descriptor field

This is not an oversight and it is recorded in the RTL that needs it.
`rtl/seq_region_lock.vhd`'s header, on the `iss_rel` port:

> WHY THIS PORT EXISTS, AND A GAP IN THE D DESIGN SPEC. Section 5.3 says "the
> consumer's `done` returns R to FREE and clears `fill_ptr`", which is written
> for B and C -- one consumer per region per block. It contradicts the spec's
> OWN schedule: section 4.2 has region XN read by SIX consecutive A jobs
> (steps 2 to 7). [...] Lifetime is a property of the schedule, so the host
> generator is what knows it, so it belongs in the descriptor -- and the
> section 6.1 descriptor format has no field for it.

`tools/gen_layer_program.py` already computes it (`build_rel()`, line 471) and
already writes it out (`write_rel()`, `--rel-file`, default `rel_mask.txt`) as
a step-indexed table, separate from the descriptor image, because `d[7] = 0`
is D's reserved word and the generator keeps it zero.

**So the seam carries the table the generator already emits.** No descriptor
format change, no edit to `gen_layer_program.py` (which this track does not
own), and nothing new computed anywhere.

### 3.4 What `rtl/fk33_seam.vhd` provides

An AXI4-Lite slave, 32-bit, 4 KB span, no AXI master of any kind.

* registers: ID / VERSION / CAPS / CAPS_FLAGS / CTRL / STATUS / ERR_INFO /
  SEQ_POS / N_STEP / TBL_LEN / X_EXP / CYCLES / ARGMAX / LOGIT_EXP / SMP_N /
  FAULTS
* four indirect windows behind WIN_SEL / WIN_ADDR / WIN_DATA, with WIN_ADDR
  auto-incrementing on every DATA access: the descriptor program, the release
  table, the activation row in, the residual region out
* the GO-time refusals: `N_STEP /= 1`, `TBL_LEN` zero or over capacity, a
  non-zero reserved HBM pointer, `SEQ_POS` not equal to the card's own next
  position, and a GO while busy
* `tok_ack` raised by the block itself, because a host round trip to
  acknowledge a completion it is already polling for buys nothing

**Why indirect windows and not the HBM pointers `server/fk33_seam.h` v1
declared.** Fetching a block out of HBM needs an HBM master, subsystem A
already takes 27 of the 30 engine ports, and the port assignment lives in
`hw/fk33/gen_pcieep.py` -- a file this track does not own and was told to stop
at. So X_BASE / L_BASE / DESC_PTR stay in the header as version-3 registers,
must be zero at GO in v2, and a non-zero one raises `FK33_SEAM_ERR_RSVD`
rather than being ignored. `CAPS_FLAGS` bit 1 reports the absence so a host
does not have to discover it by trying.

The cost that buys: the program and the release table are written ONCE PER
MODEL (at 9B, 505 descriptors = 4,040 64-bit words = 8,080 posted writes, plus
505 mask writes), and the activation row ONCE PER TOKEN (4,096 mantissas =
2,048 posted writes). **ESTIMATE, and the assumption is stated: posted writes
pipeline, so this is a bandwidth cost and not 2,048 x the 1-2 us non-posted
BAR READ latency. `docs/2026-08-28_token-io-path.md` says explicitly that no
small-transfer latency has ever been measured on this card, so treat it as
UNMEASURED rather than small.**

---

## 4. The gaps. Named, in the order they block things

**G1. The seam has no base address.** `grep -c '0xE000\|0x0000E000'
hw/fk33/gen_pcieep.py` is **0**. One line in a file this track was told not to
touch. Until it lands, no bitstream decodes this block at any address.
`server/fk33_seam.h` therefore still spells the constant `_PROPOSED`;
renaming it before the grep returns a line would make every caller read as
though the address were real. **This is the one item to hand back.**

**G2. D has never been connected to the subsystem-A unit that is on the
card.** `rtl/llama_top.vhd:2532` instantiates `matvec_int4`;
`hw/fk33/rtl/fk33_engine.vhd:1156` instantiates `matvec_int4_desc_axi`. They
are different units and only the second has a descriptor plane. Board row N3
says this; this track confirms it and adds the consequence below.

**G3. The weight base is FABRICATED, not fetched.** `rtl/llama_top.vhd:2694`:

```vhdl
base := A_MEM_BASE + j_step * A_JOB_STRIDE;
```

a linear function of the step index, with `A_MEM_BASE = 0x100000` and
`A_JOB_STRIDE = 0x8000` as elaboration-time generics. The D descriptor format
reserves a base array of `nsub_w + nsub_s` 64-bit words at offset 0x40 for
exactly this, and `rtl/seq_desc_fetch.vhd`'s header says in its own words that
the array "is NOT fetched here [...] Fetching it is remaining work". So on the
card every A job would read the wrong bytes, and it would read them
successfully. **This is the single largest hole between a passing simulation
and a correct token, and no row in `docs/WORKLOG.md` names it.**

**G4. There is no logits egress.** The seam publishes the sampler's running
argmax and its shared exponent, and that is all. 248,320 s32 logits is 993,280
non-posted BAR reads through this window. A greedy host is served; a host that
wants temperature or top_p is not. That needs the C2H DMA N3 has to build.

**G5. There is no HBM path for the activation.** v2 pushes the row through the
BAR. The v1 design (host DMAs to X_BASE, card fetches) is the right shape and
needs G1's port budget conversation first.

**G6. The codebook load is unimplemented.** Descriptor flags bit 2 (`FLG_CB`)
and words 5 and 6 carry it; `seq_desc_fetch` does not fetch them. Same class
as G3, smaller.

---

## 5. The procedure, in the order it was run

1. **Establish what is integrated.** `grep -rln 'entity work.<unit>' rtl/ sim/
   tb/ hw/` for each of the ten D-related entities. Isolates "D exists" from
   "D is composed", which the WORKLOG's superseded text conflates.
2. **Read the host face off the RTL, not the spec.** `sed -n '/^ port(/,/^end
   entity/p' rtl/llama_top.vhd`. Produced the six-row table in 3.2.
3. **Find every driver of each host input.** `grep -rn rel_mask --include=*.vhd`
   over the whole tree. This is what found that the mask is per-step and
   bench-driven, which is the finding.
4. **Read the generator before designing a format.** `tools/gen_layer_program.py`
   already emits the release table separately; the seam consumes what exists
   rather than proposing a descriptor field.
5. **Build the block, then run it beside the old drive.** Two `llama_top`
   instances on one clock, one driven through AXI-Lite only, one driven the way
   every existing gate row drives it. Isolates "the seam works" from "the design
   works": the second is not this bench's question and it says so.
6. **Mutate the seam and run the attribution control.** Section 7.

---

## 6. The evidence

### 6.1 The gate row

```
PASS       sim:tb_fk33_seam                      56s  sim/tb_fk33_seam.vhd:861:7:
  @25562500ps:(report note): tb_fk33_seam: PASS -- a whole token ran with
  llama_top's host face driven by fk33_seam and by nothing else, ...
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
```

### 6.2 The run's own report lines

```
tb_fk33_seam: shape blocks=2 hidden=64 ffn=128 -> 35 descriptors, regmax 256
tb_fk33_seam: token 0 seam STATUS 1 after 1720 polls.
tb_fk33_seam: token 0 R_X(0) = -17280 hash(R_X) = 53529 (seam hash 53529)
tb_fk33_seam: token 1 seam STATUS 1 after 1720 polls.
tb_fk33_seam: token 1 R_X(0) = -8973 hash(R_X) = 65346 (seam hash 65346)
tb_fk33_seam: P1 value 0  P2 accounting 0  P3 poll 0  P4 readback 0
              P5 landmark 0  P6 go-gate 0
```

The two hashes on each line are the two DUTs; they are equal, which is P1.
Token 1's hash DIFFERS from token 0's on both sides, which is the check that
the two tokens are a sequence and not two independent runs: the same
activation row goes in both times, so any difference is cross-token state --
here subsystem B's recurrence, whose per-token behaviour was defect B-TOP-1.

### 6.3 The seam grep that row N2 quoted as zero

Before: `grep -rln 'LLM2\|4C4C4D32\|SEAM_ID' rtl/ hw/fk33/rtl/
hw/fk33/gen_pcieep.py` returned **zero files**. Now:

```
rtl/fk33_seam.vhd
```

and `grep -c '0xE000\|0x0000E000' hw/fk33/gen_pcieep.py` is still **0**. Both
halves of that sentence matter: the register block exists, the address does
not.

---

## 7. Teeth, and the attribution control

`sim/mutate_fk33_seam.sh`. Seventeen rows plus an unmutated anchor. Every
mutation is well-formed VHDL and in bounds, so a KILL is the bench noticing
and not the language noticing.

**Four verdicts, not two.** `sim/mutverdict.py` separates KILLED (the checker
said so) from ABORT (the run died before the checker reached a verdict), and
this script adds a fourth: **KILLED(PRIOR)**, where the run also produced a
diagnostic whose source file is NOT `sim/tb_fk33_seam.vhd`. That is the
attribution control the project's own rule demands -- a kill an older property
would have made anyway is not evidence that the new bench works.

MEASURED 2026-08-30, snapshot from git HEAD `9e3348e`, GHDL 1.0.0 mcode,
`SCRATCH=/mnt/storage/dseam-scratch/mut6`:

```
=== TOTAL 17   KILLED 14   KILLED(PRIOR) 0   SURVIVED 3   ABORT 0 ===
```

| tag | mutation | verdict | which property fired |
|---|---|---|---|
| M0 | ANCHOR, no mutation | SURVIVED (required) | -- |
| M1 | rel index starts at 1: every step gets the NEXT step's mask | KILLED | P3 then P1 (128 elements), STATUS 0x604 = ERR_DESC |
| M2 | rel index never advances: every step gets step 0's mask | KILLED | P3, P1, P2 |
| M3 | rel mask published as all zeros: nothing is ever released | KILLED | P3, P1, P2 |
| M4 | descriptor 32-bit halves swapped on the write path | KILLED | P4 (the read-back check), then P1/P2/P3 |
| M5 | descriptor read one 64-bit word early | KILLED | P3, P1, P2 |
| M6 | TBL_LEN latched one short: the walker never reaches END_TOKEN | KILLED | P3, P2; P1 only at token 1 |
| M7 | the X window writes one element high | KILLED | **P1 alone**, `R_X(0)` -17280 vs 21442 |
| M8 | host_x_exp forced to zero | KILLED | **P1 alone**, `R_X(0)` -17280 vs 13076 |
| M9 | `tok_ack` never raised | KILLED **only at NTOK 2** | P1 at token 1, `R_X(0)` -8973 vs -125 |
| M10 | STATUS.done wired high | KILLED | **P6 alone** ("DONE is set on a REFUSED go") |
| M11 | steps_done reported one short in ERR_INFO | KILLED | **P4 alone**, 34 vs 35 |
| M12 | the TBL_LEN = 0 refusal deleted | KILLED | P6, then P1/P2/P3 |
| M13 | the reserved-HBM-pointer refusal deleted | KILLED | P6, then P1/P2/P3 |
| M14 | the SEQ_POS refusal deleted | KILLED | P6, then P1/P2/P3 |
| F1 | CYCLES counter frozen | **SURVIVED, expected** | nothing reads CYCLES |
| F2 | FAULTS bit order permuted | **SURVIVED, expected** | this shape raises no fault |

**The attribution control fired on nothing: KILLED(PRIOR) is 0 for all
fourteen.** No DUT assertion, region-lock violation or language bound check
fired on any of them, so every kill belongs to a property in
`sim/tb_fk33_seam.vhd` and not to something that predates it. Four of the
fourteen were caught by exactly ONE property (M7, M8 by P1; M10 by P6; M11 by
P4), which is the case where a missing check would have been a silent
survivor.

**M9 IS THE VALUABLE ROW AND IT IS THE ONE THAT NEARLY GOT AWAY.** At NTOK = 1
it SURVIVED every property this bench has: a seam that never acknowledges D's
completion still latches DONE, still advances its own position, and still
reports the right numbers, because nothing in a one-token run ever asks D to
start again. `sim/tb_llama_top.vhd` had recorded the same lesson when NTOK was
added there -- "a bench that cannot tell an N-token sequence from N one-token
runs has not tested a sequence" -- and this bench had to relearn it. The
default is now NTOK = 2 and the row kills at token 1, where the seam DUT's
`R_X(0)` is still the raw embedding (-125) because its second token never ran.
The measured cost of the fix is 28 s to 56 s.

**F1 and F2 measure the floor and they are real.** `CYCLES` and `FAULTS` are
published by the seam and read by nothing -- not by this bench and not by
`server/pl_backend.c`, which predates them. A fault register nothing polls is
decoration, and this table is where that is visible.

---

## 8. Measured and REJECTED -- do not retry

* **`hw/fk33/rtl/fk33_seam.vhd` as the file's home.** MEASURED: the first run
  reported `SKIPPED sim:tb_fk33_seam -- unresolved design unit(s): fk33_seam`
  and `sim/regress.sh` still printed `REGRESSION: PASS` with `PASS 0`. The
  planner globs design units out of `rtl/`, `sim/`, `sim/micro/` and `tb/` and
  nowhere else. A block in `hw/fk33/rtl/` cannot be a gate row. The file lives
  in `rtl/`.
* **`ref/run9b` as this bench's oracle.** The brief asked for it. It is not
  reachable and the correction is the one TRACK BISECT already recorded:
  `ref/run9b` is the 9B model and a GHDL run at that shape is ~35,650x the
  arithmetic of the scaled shape, about fifteen days per token. The oracle
  that exists at this shape is `tools/ref9b/bisect_scaled.py` through
  `tools/ref9b/seamgate.sh`.
* **A verdict line reading `OVERALL PASS 1 FAIL 0`.** MEASURED: the row came
  back `FAIL sim:tb_fk33_seam` quoting its own passing line. `FAIL_RE` matches
  a bare `\bFAIL\b` and the zero-counter neutraliser only strips `FAIL = 0` or
  `FAIL: 0`, with a separator. The house form is `RESULT: PASS`.
* **A descriptor-format field for the release mask.** Rejected without
  measuring, and the reason is ownership rather than design: word 7 is free,
  but the producer is `tools/gen_layer_program.py`, which this track does not
  own, and it already emits the table separately. Changing the format would
  have made a contested edit mandatory for no capability gained.
* **An HBM master in the seam** (for DESC_PTR / X_BASE / L_BASE). Not
  attempted. A 31st HBM port is a claim on `hw/fk33/gen_pcieep.py`'s port
  budget, and A already takes 27 of 30.

---

## 9. Measurement traps hit, including my own

* **`wait until <level> = '1'` needs an EVENT.** `tok_done` is a level held
  until `tok_ack`, and by the time the bench got to it the seam poll had taken
  1,720 AXI reads, so it was already high. The unguarded wait sat for its
  entire 1 ms timeout -- 1,000,000 idle cycles -- on a PASSING run, and the
  only symptom was a 36 MB log. Guard the wait with a level test.
* **A 36 MB log is a gate cost, not cosmetics.** 273,150 `NUMERIC_STD`
  metavalue warnings, from two idle DUTs churning on uninitialised regions
  while the AXI programming ran. Fixed by giving the DUTs their own reset and
  holding it through the programming phase, which is also what the card does
  (the compute domain's reset is separate: see `2d07c3c`). The count dropped
  to 92,522 and the log to 12 MB.
* **Comparing `R_X` over `REGMAX` compares metavalues.** Every region is
  allocated the widest region's size, so `R_X` elements `hidden..REGMAX-1` are
  never written and read back `'U'` on both sides. `to_integer` turns both
  into 0 and the comparison passes for the wrong reason. The loop runs to
  `SHAPE.hidden`.
* **This bench's landmark is NOT comparable with `sim/tb_llama_top.vhd`'s.**
  Same hash function, different `BLOCKS`, and the behavioural subsystem A
  against the real one.
* **A mutation table read straight off the working tree reports the other
  tracks' edits as its own ABORTs.** MEASURED: the first full run of
  `sim/mutate_fk33_seam.sh` returned `DID NOT ANALYZE ... rtl/matvec_core.vhd:
  216:12: identifier "cb_lanes_per_copy" already used for a declaration` on six
  consecutive rows, in a file this track cannot touch, because a concurrent
  track was mid-edit in it. The table read `TOTAL 17 KILLED 2 SURVIVED 1
  ABORT 14`. **ABORT and SURVIVED are the two verdicts a reader over-interprets
  most**, so this is not a cosmetic failure. Fixed by snapshotting all 50
  sources into the mutation scratch once, before the first row, and analysing
  only from the snapshot -- which also makes the table internally consistent,
  since without it row M1 and row F2 can be judged against different trees.
* **A one-token bench cannot see an unacknowledged completion, and this bench
  shipped that way for one full mutation table.** M9 SURVIVED all six
  properties at NTOK = 1. The tell was not in the bench, it was in the
  mutation table -- which is what the table is for. NTOK = 2 is now the
  default and M9 dies at token 1.
* **The 9B descriptor count is 505, not 546.** The dispatch brief says 546 and
  so does `rtl/seq_desc_fetch.vhd`'s own header. DERIVED from the RTL:
  `llama_map_pkg.n_steps` at `QWEN35_9B` is `24*16 + 8*13 + 3 = 491`, and
  `llama_sched_pkg.build_table` runs `n_steps - 1 + lm_windows = 491 - 1 + 15 =
  505` because the lm_head is fifteen row windows.
  `sim/llama_sched_pkg.vhd:88` says the same thing in its own words. Every
  per-token figure in this document uses 505.

---

## 10. What is still host-side. Precisely.

1. **The token loop.** One GO is one position. Sampling, templating,
   detokenization, stop strings and the decision to run another position stay
   with the host, by design: `server/fk33_seam.h`'s own derivation puts a PCIe
   round trip at ~0.1% of a 38.27 ms token.
2. **The embedding gather.** The card does not read the embedding table. The
   host dequantizes, BFP-packs and pushes `n_embd` mantissas plus one
   exponent.
3. **The logits.** Argmax only. See G4.
4. **Everything B and C do, on the card.** `hw/fk33/rtl/fk33_engine.vhd` is
   still subsystem A alone. `hw/fk33/host/fk33_run_token.py` re-anchors 32
   times per token for exactly that reason, and **this track has changed that
   number by zero.** A reader who takes "D works" to mean the card now runs a
   token by itself is reading something this document does not say.
5. **The weight addresses**, until G3 is closed.

---

## 11. Open, not yet answered

* **Does D drive `matvec_int4_desc_axi` correctly?** Unknown, untested,
  unwired. G2.
* **Where does the base array come from?** G3 has no owner and no row.
* **What does one AXI-Lite write cost on this card?** Unmeasured. Every
  per-token figure in section 3.4 is an ESTIMATE resting on it.
* **Does the seam meet timing in the composed design?** Not synthesised. No
  Vivado was run by this track, deliberately: TRACK TIMING holds the one slot
  on this workstation and was closing WNS -3.259 ns on `compose4_top` while
  this ran.
* **Is `N_STEP > 1` (a prefill chunk) reachable?** v2 refuses it with
  `FK33_SEAM_ERR_NSTEP`. Whether D can run a chunk at all is untested.
* **Is the 4 KB span right?** The register file uses 0x00..0x68. Nothing has
  argued that 4 KB is the correct BAR allocation rather than the largest
  convenient hole.
* **`server/fk33_sim.c` still models VERSION 1 and this track did not change
  it.** So two implementations of `server/fk33_seam.h` now exist and they
  report different versions: the RTL says 2 and the C model says 1. A host must
  branch on the VERSION register, not on the header. Reconciling the model has
  no owner. Said in the header itself, beside the version constants, rather
  than left to be discovered.
* **Does anything downstream read the FAULTS register?** `server/pl_backend.c`
  does not, because it predates it. A fault register nothing polls is
  decoration.
* **Three of the nine seam error codes are unreachable in v2.** `ERR_ALIGN`
  and `ERR_STACK` are properties of the HBM pointers, which v2 refuses as
  `ERR_RSVD` before either check applies; `ERR_HALT` needs the thermal guard's
  `compute_halt` wired to this block, and it is not. So `sim/tb_fk33_seam.vhd`
  exercises three of the six reachable codes (NSTEP, RSVD, SEQ) and none of
  the unreachable three. Recorded in the header beside the codes. Same class
  as open issue N7, where `EC_CORE` is reachable by no bench in the tree.
