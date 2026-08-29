# The stale lm_head encoding, and who fills R_X

**Date:** 2026-08-29
**Track:** TOKIO
**Tree:** `fk33` branch. Baselines snapshotted at `c754e39` (TRACK EGRESS's
logits-egress landing); HEAD advanced to `0db9034` during the work, and the
three commits in between touched `docs/` only (`git diff --name-only
c754e39..HEAD`), so every baseline in section 4 is still the right one. Two other tracks had
uncommitted work in the tree during the gate run: `tools/ref9b/**`, which no
VHDL row reads, and a hunk in the SHARED `sim/regress.sh` adding
`tb_vector_args` rows for `attn_kv_quant_vec.txt` and
`attn_score_q12_vec.txt` (which regenerates those two committed vectors, and
which its author states and verified is byte-identical). That hunk is in the
gate run reported in section 11 and is deliberately NOT in this track's commit:
`git diff -- sim/regress.sh` was read as its own step before staging, and only
the `BASELINE_PASS` hunk was staged, with the commit made with no pathspec.
**Tools:** GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6) mcode, `--std=08 -frelaxed
--max-stack-alloc=0`; `python3` for `tools/gen_layer_program.py`.
**No hardware was touched.** Nothing in this file ran against the FK33.

---

## 1. The questions, verbatim

> `sim/seq_tbl_pkg.vhd:341` encodes the lm_head as a **single 248,320-row job**.
> TRACK LMHEAD proved with the RTL as judge that the gateware **refuses**
> exactly that descriptor [...] **Fix it, and manage the landmark consequence
> explicitly.** [...] LMHEAD MEASURED that all ten scaled shapes keep their D
> table and release mask **byte-identical** under the 15-window schedule [...]
> **Verify that claim yourself before relying on it.**

> `lm_head` and `embed` are still the 512-entry, 64-dimension **stories260K
> ROMs**. The residency map gives the embedding an HBM home and says the lookup
> path has **no owner**. [...] Two known shapes for it [...] an **opcode** that
> makes the sequencer fetch the embedding row itself, or the **host writes
> `R_X` directly** before releasing the token. **Investigate, and if the
> decision is genuinely still open, bring it back to me with the costed
> comparison rather than choosing.** If the tree has effectively already
> decided it [...] say so with file:line and proceed.

---

## 2. The answers, up front

**PART 1.** LMHEAD's byte-identity claim is CORRECT and is now independently
VERIFIED: all ten scaled shapes keep `llama_sched_pkg`'s table AND its release
mask byte-identical under windowing, and the real 9B table's first difference
is at word 3913 (step 489, word 1, the `n_rows` field), `0x3CA00 -> 0x43E0`,
with all 3,913 preceding words unchanged. The fix is landed in both VHDL
generators. **`seq_tbl_pkg.TBL_STEPS` moves 491 -> 505 and `TBL_WORDS` moves
3928 -> 4040. Nothing else moves.** The corrected table is now BYTE IDENTICAL
to `tools/gen_layer_program.py`'s independent Python output, which it was not
before.

**PART 2. The decision is not open. The tree decided it, and built the RTL for
it.** The host writes `R_X` over the region-file write port before releasing
the token. This is not an inference from a document; it is three separate
pieces of shipping RTL that exist for no other purpose:

- `rtl/llama_top.vhd:544-547` -- the `hw_we / hw_reg / hw_addr / hw_data` host
  write port, whose own comment at `:542-543` says "The token embedding is
  written into R_X before `go`".
- `rtl/llama_top.vhd:1054-1058` -- that write overrides every unit port in the
  element mux; `:1239` exempts it, alone, from the region lock's
  dropped-write error.
- `rtl/seq_opdec.vhd:611-665` -- a six-state FSM (`T_IDLE -> T_RST -> T_REQ ->
  T_CMT -> T_PUB -> T_GO`) that intercepts `go`, publishes the host's write to
  the lock manager as if it were a descriptor, and stamps `cmp_y_exp <=
  host_x_exp`. Its generics are literally `HOST_REG => R_X, HOST_ROWS =>
  SHAPE.hidden` (`rtl/llama_top.vhd:1180`). Its own header, `:128-150`, is
  titled "**A FOURTH FINDING: NOBODY PUBLISHED THE HOST'S X**" and says "D
  section 3.2 leaves the embedding on the host [...] the host's write has no
  descriptor".

The opcode route is not merely unbuilt, it is fenced at four places and blocked
by a resource the design does not have. **No new RTL was written for the
embedding, and none should be.** The costs of both routes are in section 6.

**One sub-decision IS still Oren's and is NOT taken here:** whether
`token_embd.weight.mv4i` -- 572,207,104 bytes, 6.66% of the 8 GiB -- stays
loaded and hash-verified on a card where nothing reads it. That question was
already raised by `docs/2026-08-28_token-io-path.md:340-345` and is restated in
section 8.

---

## 3. The procedure

Each step names what it controls for.

**P1. Snapshot HEAD before touching anything.** `git show HEAD:<path>` for the
five files the table derives from, into a private scratch tree. Controls for
the recorded failure mode where another track live-edits a file mid-analysis
and invalidates the landmark (`rtl/llama_top.vhd` grew 254 lines under another
track's measurement on 2026-08-29).

**P2. Dump both VHDL generators at HEAD.** A scratch GHDL entity writes
`seq_tbl_pkg.build_table` (real 9B), `llama_sched_pkg.build_table` and
`llama_sched_pkg.build_plan`'s release mask, one hex word per line, for ten
scaled shapes. This is the BASELINE. Isolates: what the tables were before the
edit, measured rather than quoted from LMHEAD's write-up.

**P3. Reproduce LMHEAD's Python comparison at HEAD.**
`tools/gen_layer_program.py --token --stamp seq_tbl --one-lmhead-job` must be
byte-identical to HEAD's `seq_tbl_pkg` dump. Isolates: whether the Python tool
is a valid oracle for this VHDL at all. If this had failed, every later
comparison against the Python would have been meaningless.

**P4. Edit both generators.** Derive `LM_STRIDE` and `LM_WINDOWS` in
`seq_tbl_pkg`, emit one A job per window, and correct the tail arithmetic in
both packages.

**P5. Re-dump and diff, three ways.** (a) scaled shapes, edited vs HEAD -- must
be byte-identical, which is the claim under test; (b) real 9B, edited vs HEAD
-- locates the divergence exactly; (c) real 9B, edited vs the Python's WINDOWED
output -- this is the ORACLE step, because the Python derives its windows in
`tools/gen_lmhead_windows.py::plan` on a completely separate path.

**P6. Cross-check the release mask against the Python too.** The scaled-shape
release masks are compared VHDL-vs-Python after normalising a formatting
difference (Python writes 14 binary digits, VHDL `hwrite` writes 4 hex
nibbles). Isolates: whether the liveness pass agrees between the two
implementations, which the HEAD-vs-edited comparison alone cannot show because
both sides are the same code.

**P7. Give the fix teeth.** A new gate row, `sim/tb_seq_tbl_shape.vhd`, that
asks whether the emitted table is LEGAL and whether the windows COVER, plus
`sim/mutate_seq_tbl_shape.sh`, which mutates `sim/seq_tbl_pkg.vhd` -- the
generator, not the bench -- and scores each mutation against a written-down
prediction.

**P8. Survey the embedding path** across `rtl/`, `sim/`, `server/`, `ref/`,
`tools/` and `docs/` for file:line evidence of what exists, what is half-built,
and what forecloses each route.

**P9. Run the affected rows, then the whole gate unfiltered.**

---

## 4. The evidence, as captured output

### 4.1 P3 -- the Python is a valid oracle for this VHDL (at HEAD)

```
$ python3 tools/gen_layer_program.py --token --stamp seq_tbl --one-lmhead-job \
      --d-table $SP/py/t_one.hex
$ python3 tools/gen_layer_program.py --token --stamp seq_tbl --d-table $SP/py/t_win.hex
  3928 t_one.hex
  4040 t_win.hex
$ cmp t_one.hex base/out/seq9b_b1_a4_h32.txt
BYTE IDENTICAL
```

Note both Python invocations print a message about `--x-exp` being required for
the A descriptors; the D table is still emitted. That is expected and not an
error (`--no-a` suppresses the message).

### 4.2 P5(a) -- the claim under test: ten scaled shapes, table AND release mask

```
b1_a4_h32      words=152   table_diff=0     rel_diff=0
b2_a4_h32      words=280   table_diff=0     rel_diff=0
b4_a4_h32      words=512   table_diff=0     rel_diff=0
b8_a4_h32      words=1000  table_diff=0     rel_diff=0
b16_a4_h32     words=1976  table_diff=0     rel_diff=0
b32_a4_h32     words=3928  table_diff=0     rel_diff=0
b4_a4_h16      words=512   table_diff=0     rel_diff=0
b32_a4_h16     words=3928  table_diff=0     rel_diff=0
b8_a2_h32      words=952   table_diff=0     rel_diff=0
b9_a3_h32      words=1104  table_diff=0     rel_diff=0
scaled-shape byte identity: ALL IDENTICAL
```

**LMHEAD's claim is VERIFIED, including the 491-step `blocks=32` shape.** The
reason is arithmetic and not luck: `mk_shape_scaled` sets `vocab_shard = 128`
(`rtl/llama_map_pkg.vhd:264, 277`) and one stride is 17,376, so `lm_windows`
returns 1 and the emitted sequence is what it was.

### 4.3 P5(b) -- the real 9B table, edited vs HEAD

```
$ cmp base/out/seq9b_b1_a4_h32.txt new/out/seq9b_b1_a4_h32.txt
... differ: byte 66533, line 3914
3914c3914
< 000010000003CA00
---
> 00001000000043E0
changed lines before word 3913: 0
```

Word 3913 is `489*8 + 1`: step 489, word 1, the `n_rows | n_cols` word.
`0x3CA00 = 248320` becomes `0x43E0 = 17376`; `n_cols` stays `0x1000 = 4096`.
**Every one of the 3,913 preceding words is unchanged**, so the divergence is
exactly and only the lm_head, exactly as LMHEAD reported.

### 4.4 P5(c) -- THE ORACLE: the fixed VHDL against the independent Python

```
$ cmp new/out/seq9b_b1_a4_h32.txt py/t_win.hex
BYTE IDENTICAL (4040 words)
```

This is the load-bearing measurement. Before the edit the VHDL matched the
Python only with `--one-lmhead-job`, the flag whose own help text says it emits
"the lm_head as ONE A job over the whole vocabulary". After the edit it matches
the DEFAULT, windowed output. Two implementations that derive the window plan
separately -- `sim/seq_tbl_pkg.vhd`'s `LM_STRIDE`/`LM_WINDOWS` constants and
`tools/gen_lmhead_windows.py::plan` -- now agree on all 4,040 words.

### 4.5 P6 -- the release mask, VHDL against Python

```
blocks=4 attn_int=4    rows=64   mismatches=0
blocks=8 attn_int=2    rows=119  mismatches=0
blocks=9 attn_int=3    rows=138  mismatches=0
blocks=32 attn_int=4   rows=491  mismatches=0
```

The raw `cmp` reports DIFF on every one of these, and that is a FORMAT
difference, not a content one: `tools/gen_layer_program.py --rel-file` writes 14
binary digits per row and the VHDL `hwrite` writes 4 hex nibbles for the same
14-bit vector. Compared as integers, zero mismatches. This is pre-existing and
not introduced here; it is recorded in section 7 as a trap because the bare
`cmp` reads as a real disagreement.

### 4.6 P7 -- the new gate row, on the corrected table

```
tb_seq_tbl_shape: 505 steps, 4040 words, LM_WINDOWS = 15, LM_STRIDE = 17376
tb_seq_tbl_shape: 1016 checks, 15 lm_head windows covering 248320 of 248320 rows
tb_seq_tbl_shape: PASS
```

```
PASS       sim:tb_seq_tbl_shape                   0s
 OVERALL     PASS 1   FAIL 0 ...
```

### 4.7 P7 -- the mutation table

Every mutation edits `sim/seq_tbl_pkg.vhd`, the generator. The BRANCH column is
the `if NCARDS = 1` arm that elaborates it; this build is `NCARDS = 1`
(`rtl/model_cfg_pkg.vhd:91`), so an `N>1` row is a permanent non-biter for this
configuration and measures the harness's reach, not the checker's resolution.
Every result matched its written-down prediction.

```
control: PASS (a mutation table against a red control measures nothing)

TAG  BRANCH  MUTATION                                                   RESULT
---- ------- --------                                                   ------
M1   N=1     the historical defect: one job over the whole vocabulary   KILLED
       first: step 489 is an A job with n_rows 248320; S_CHECK bounds it to 1 .. 17408
M2   always  stride is MAXROWS_BFP, not floored to a tile               KILLED
       first: LM_STRIDE 17408 is not a whole number of ROWS_IF tiles
M3   always  stride rounded UP to a tile instead of down                KILLED
       first: LM_STRIDE 17424 exceeds MAXROWS_BFP 17408
M4   always  window count floored, so the tail of the vocab is dropped  KILLED
       first: LM_WINDOWS 14 x LM_STRIDE cannot reach VOCAB_SH 248320
M5   always  one window too many, running past the tensor               KILLED-LANG
M6   N=1     windows emitted in BFP instead of raw                      KILLED
       first: lm_head step 489 is out_mode 0, not raw (1)
M7   N=1     windows given a destination region                         KILLED
       first: step 489 writes region 13 at offset 0 for 17376 rows, past its capacity 4096
M8   N=1     windows given per-window dst_off, manufacturing segments   KILLED
       first: lm_head step 490 has dst_off 17376
M9   N=1     the sampler route flag dropped from every window           KILLED
       first: found 0 lm_head windows, LM_WINDOWS says 15
M10  N=1     FFN gate job overruns region R_G by one row                KILLED
       first: step 11 writes region 10 at offset 0 for 12289 rows, past its capacity 12288
M11  N=1     the third QKV segment starts one element late              KILLED
       first: step 3 writes region 2 at offset 4097 for 4096 rows, past its capacity 8192
N1   N=1     nsub_w and nsub_s swapped on every A job                   SURVIVED
N2   N=1     the tail norm ordinal changed from 0 to 7                  SURVIVED
N3   N=1     the w_exp stamping sequence changed                        SURVIVED
N4   N=1     FFN gate and up destinations swapped (both size FFN)       SURVIVED
N9   N>1     the collective FFN down-projection's row count (DEAD BRANCH) SURVIVED

killed-by-checker 10   killed-by-language 1   survived 5   not-a-measurement 0
```

**M1 is the defect this bench exists for**, reproduced by putting the old
`n_rows => VOCAB_SH` back, and it is killed at step 489 with the RTL's own
error code named in the message.

**M5 is scored separately and must not be counted as a checker kill.** It is
killed by a `bound check failure` in `natural` when `VOCAB_SH - w*LM_STRIDE`
goes negative in the emitter, before `tb_seq_tbl_shape` runs at all:

```
ghdl-mcode:error: bound check failure at .../M5/seq_tbl_pkg.vhd:414
  from: work.seq_tbl_pkg.build_table at seq_tbl_pkg.vhd:413
ghdl-mcode:error: error during elaboration
```

That is worth knowing -- the generator physically cannot build an over-covering
table -- but it says nothing about the checker's resolution, because a checker
that could not see the defect would produce the identical transcript.

**THE FIVE SURVIVORS, NAMED.** They are the bench's resolution floor.

- **N1, `nsub_w`/`nsub_s` swapped on every A job.** This bench does not read
  those fields at all. They are range-checked against `NSUB_MAX` by
  `rtl/seq_desc_fetch.vhd` and their VALUES have no oracle anywhere in the
  tree. Permanent for this bench by design; closing it needs the descriptor
  plane as judge.
- **N2, the tail norm's `ordinal` changed 0 -> 7.** Not read here. Worth noting
  that `tools/gen_layer_program.py:407-409` records that the two VHDL
  generators already DISAGREE about this field (`seq_tbl_pkg` passes 0,
  `llama_sched_pkg` stamps `blk mod 64`), so a checker for it would have to
  decide which is right first. Not this track's question.
- **N3, the `w_exp` stamping sequence.** Deliberately not checked: the whole
  point of the stamping is that the values are arbitrary but distinct, and
  `tb_seq_desc_fetch`'s `ord_chk` is the checker for it.
- **N4, FFN gate and up destinations swapped.** A genuine and interesting blind
  spot: R_G and R_U are both `FFN` elements, so the group-3 capacity check
  cannot separate them, and this bench has no model of what a step MEANS. The
  checker for this is the schedule oracle in `sim/tb_llama_top.vhd`, which
  compares against `llama_sched_pkg.build_plan` step by step.
- **N9, the `NCARDS > 1` collective branch.** A permanent structural non-biter
  at this build. Kept as the harness's reach measurement.

### 4.8 P9 -- the affected rows

The four benches that walk `seq_tbl_pkg.build_table` take `TBL_STEPS` from the
package, so they follow the change automatically. Confirmed:

```
 suite sim   PASS 5   FAIL 0 ...     (--only tb_seq_)
```

`llama_sched_pkg` is the generator `llama_top` executes, so its rows were run
separately:

```
PASS       sim:tb_llama_top                     110s  ... PASS -- 64 descriptors, 4 bl
PASS       sim:tb_llama_top_real                 75s  ... PASS -- 64 descriptors, 4 bl
PASS       sim:tb_llama_top_seq                 284s  ... PASS -- 61 descriptors, 4 b
PASS       sim:tb_llama_top_smp                   1s  ... PASS.  2 tokens, 64 logits each
PASS       sim:tb_llama_top_smp_beh               1s  ... PASS.  2 tokens, 64 logits each
 OVERALL     PASS 5   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
```

Full unfiltered gate: see section 9.

---

## 5. The landmark movement, stated exactly

| landmark | before | after | moves? |
|---|---|---|---|
| `seq_tbl_pkg.TBL_STEPS` (real 9B) | 491 | **505** | **YES, +14** |
| `seq_tbl_pkg.TBL_WORDS` | 3928 | **4040** | **YES, +112** |
| `seq_tbl_pkg` A jobs in the token | 297 | **311** | **YES, +14** |
| `llama_sched_pkg` table, ten scaled shapes | -- | -- | NO, byte-identical |
| `llama_sched_pkg` release mask, ten scaled shapes | -- | -- | NO, byte-identical |
| `n_steps(mk_shape_scaled(32,4,32))` = 491 | 491 | 491 | NO |
| `tb_llama_top` "64 descriptors, 4 blocks" | -- | -- | NO |
| `tb_llama_top_real` `R_X(0) = -16339 hash 92903` | -- | -- | NO (row PASSes) |
| `tb_llama_top_seq` "61 descriptors" | -- | -- | NO |
| `tb_llama_top_smp` "2 tokens, 64 logits each" | -- | -- | NO |
| `llama_map_pkg.n_steps` | unchanged | unchanged | NO (see below) |
| `probe_abc_ports` A_JOB census | 297 | **311** | **YES, +14** (MEASURED, 9) |
| `probe_abc_ports` jobs issued | 490 | **504** | **YES, +14** (MEASURED, 9) |
| `probe_abc_ports` A/B/C overlap, both window kinds | 0 | 0 | NO (MEASURED, 9) |
| `regress.sh BASELINE_PASS` | 85 | **86** | **YES, +1** |

**Stale comments this change creates, listed rather than swept.**
`sim/probe_abc_ports.vhd:297, 316` both say "297 of the 490 jobs are A"; on the
9B table those become **311 of 504**. `sim/probe_abc_ports.vhd:14, 47` say
"491-descriptor". Not edited: that file is not this track's, and the reasoning
those comments support (A follows A, so the probe cannot see an A/A overlap) is
unaffected by the count. `sim/tb_llama_top.vhd:156` and `:427` also name 297 and
490, and those are CORRECT and must not be "fixed": they describe the SCALED
32-block shape, whose `vocab_shard` is 128 and whose lm_head is still one job.

**Every recorded "491" outside `sim/` is now stale.** In particular
`docs/2026-08-27_hbm-port-contention.md:32, 80, 135, 197, 547`,
`docs/2026-08-27_budgets-at-the-measured-clock.md:359` and
`rtl/llama_top.vhd:361` describe a 491-step token. They were not edited: the
first two are dated measurement records whose numbers were correct when taken,
and `rtl/llama_top.vhd` belongs to another track this session. The cycle-budget
consequence is small and DERIVED, not measured: +14 descriptor fetches at 312 B
each plus 14 job start/drain latencies on a token that already runs 491 steps,
so under 3% more control-plane steps and no change at all to the weight bytes
read (`docs/debugging/2026-08-29_lmhead-window-schedule.md:431` shows the
windows read each tile exactly once: `14 x 362 + 106 = 5174 = tiles(248320)`).

**`llama_map_pkg.n_steps` was deliberately NOT changed.** It counts the token
tail as 3, which assumes a one-job lm_head. `llama_sched_pkg` now computes
`n_steps(s) - 1 + lm_windows(s)` instead, which is identically `n_steps(s)`
for every shape any bench in this tree elaborates. The reason for not fixing it
at source: `rtl/llama_map_pkg.vhd` is RTL that `rtl/llama_top.vhd` reads, the
windowing constants are a property of the descriptor plane's BUILD rather than
of the shape, and `rtl/llama_top.vhd` was under another track's measurement.
**This is a latent inconsistency and it is listed in section 10.**

---

## 6. Measured and REJECTED -- do not retry

### R1. An `OP_EMBED` opcode and an on-card gather unit. REJECTED.

Not because it is impossible -- the D spec itself calls it "a ~1-DSP dequant of
one packed row into X" (`docs/superpowers/specs/2026-08-24-transformer-sequencer-design.md:1100-1105`)
-- but because of what it costs on THIS build, and because the alternative is
already built.

| | opcode + on-card unit | host writes R_X (TAKEN) |
|---|---|---|
| HBM read port | needs a 28th master. **A already holds 27 of 30** at `ROWS_IF = 48`, B wants 4, C wants 2 reads + 1 write, 3 remain (`docs/2026-08-28_token-io-path.md:323-326`) | **none** |
| fabric | new unit, on a design that already fails `route_design` at global congestion level 7 with no bitstream (OI-12) | **none** |
| descriptor format | opcode byte is free (`rtl/seq_desc_fetch.vhd:95`), but `:474` `if op > OP_END_TOKEN then bad := '1'` rejects 8..255 | no change |
| downstream opcode width | `job_opcode`/`chk_opcode` are 4 bits (`seq_desc_fetch.vhd:203, 228`; `seq_opdec.vhd:220`; `seq_vec_issue.vhd:151`; `llama_top.vhd:746, 758, 612`). 8..15 are free, but `unit_of`'s `when others => return 0` (`seq_desc_fetch.vhd:424`) would silently aim an unknown opcode at unit A | no change |
| `seq_opdec` tables | `assert OPC_CONS'length = 8 ... severity failure` (`seq_opdec.vhd:366-368`), mirrored by `llama_map_pkg.vhd:97-98` `integer_vector(0 to 7)`; `opc_mask` silently returns an EMPTY consume mask above 7 (`seq_opdec.vhd:344-347`) | no change |
| error code for a new failure class | **none free.** The 4-bit space is full: `matvec_int4_desc_pkg.vhd:52-57` says "A further A-specific code needs the field widened, not another value" (OI-9) | not needed |
| host-side work | still needed for prefill | one C function behind an existing typedef |
| HBM read latency | **never measured** (`docs/2026-08-27_hbm-residency-map.md:421-426`), so the latency argument for it cannot even be evaluated | irrelevant |
| already built | nothing | `llama_top.vhd:544-547, 1054-1058, 1239`; `seq_opdec.vhd:611-665`; `llama_top.vhd:1180-1185` |

The four opcode fences are each a one-line change, so **the cost is not the
opcode -- it is the read port and the fabric.** Do not re-cost this on the
opcode encoding; that is the cheap part and re-deriving it wastes a session.

### R2. Fixing the step count in `llama_map_pkg.n_steps`. REJECTED for now.

It is the tidier place, and it is the wrong file to touch from this track: it is
RTL, `rtl/llama_top.vhd` reads it, another track was measuring against
`llama_top` at the time, and the constants are a build property rather than a
shape property. The local correction is exact wherever it differs. Listed as
open in section 10 rather than done badly.

### R3. Editing the "491" out of the dated measurement documents. REJECTED.

`docs/2026-08-27_hbm-port-contention.md` and
`docs/2026-08-27_budgets-at-the-measured-clock.md` are records of measurements
taken on a 491-step table. Rewriting them would make them claim measurements
that were never run. The house rule is corrections appended, never history
edited. Section 5 is the correction; the documents stand.

### R4. Making `tb_seq_tbl_shape` instantiate the real descriptor plane. REJECTED.

That would turn group 1 from a restatement into a real oracle, and it is the
wrong bench for it: `sim/tb_mv4i_desc_image` already puts descriptors through
`matvec_int4_desc_axi`'s `S_CHECK`, and it is what LMHEAD used to get the
`err_code 0x3 err_info 1` result in the first place. Duplicating it here would
cost a 27-slave harness for a bench that currently runs in under a second, and
would still not judge arithmetic. The limitation is stated in the bench's own
header instead.

---

## 7. Measurement traps hit, including my own

**T1. `cover` is a reserved word in VHDL-2008, and GHDL's error does not say
so.** A `variable cover : natural` produced

```
part.vhd:105:14: ':' is expected instead of 'cover'
part.vhd:105:14: type mark expected in a subtype indication
```

and then a cascade ending in `281:1: missing entity, architecture, package or
configuration` at the END of the file -- which reads as an unbalanced `end`,
not as a bad identifier 176 lines earlier. VHDL-2008 pulled the PSL keywords
(`cover`, `assume`, `restrict`, `sequence`, `property`, `strong`, ...) into the
reserved set. **Do not chase a brace-balance bug when GHDL points at the last
line of the file; bisect with `head -n` and read the FIRST error, not the
loudest one.** Cost: about ten minutes.

**T2. A bare `cmp` on the release-mask files reads as a disagreement and is
not one.** `tools/gen_layer_program.py --rel-file` writes 14 binary digits per
row; the VHDL dump writes 4 hex nibbles for the same 14-bit vector. `cmp`
reports DIFF on all four shapes; compared as integers, zero mismatches (4.5).
Anyone re-running P6 must normalise the radix first.

**T3. The bench cannot be run against the PRE-fix package, so "does it catch
the historical defect" is NOT answered by pointing it at HEAD.** The bench
references `LM_STRIDE` and `LM_WINDOWS`, which do not exist in the old package,
so GHDL says `no declaration for "lm_stride"` and nothing elaborates. A
mutation that does not analyze has tested nothing. The question is answered by
M1 instead, which reintroduces the defect INTO the fixed package.

**T4. My own: a language kill looked like a checker kill.** M5 was first scored
KILLED alongside the other ten, and the transcript was indistinguishable. It is
a `bound check failure` in the emitter, before the checker runs. The harness now
scores `KILLED-LANG` under its own name and the summary line reports the two
counts separately. **A mutation table that does not separate these two overstates
its checker's resolution**, and this one would have claimed 11 of 11.

**T5. The `--x-exp is required` message on `gen_layer_program.py --token
--d-table` is not a failure.** The D table is still written; the message is
about the A descriptors, which `--d-table` does not need. Two of the four P3/P5
runs print it and both produced correct output.

**T7. My own, and the worse of the two: one of my checks could not fail.** The
first version of `tb_seq_tbl_shape` compared each lm_head window's start
against the running cover. `row_start` is not a descriptor field -- `mk_desc`
has no argument for it and `tools/gen_layer_program.py` carries it outside the
header -- so the start can only BE the running cover, and the comparison was
true by construction. It was reported inside a "971 checks" figure, which is
exactly how a decoration check launders itself into a coverage number. Removed,
with the reason left in the file so it is not re-added; the honest figure is
1016 and the falsifiable property in that spot is whether the cover lands on a
ROWS_IF tile. **Neither the mutation table nor the PASS changed**, which is the
point: a check that cannot fail also cannot be caught by mutating the thing it
watches.

**T6. The scratchpad already contained a `dump_tables.vhd` from an earlier
track in the same session.** It was read, understood and reused rather than
rewritten, which saved time but means P2's tool is not independent of LMHEAD's.
That does not weaken P5(c), the load-bearing comparison, because the ORACLE
there is the Python and not the dump tool: a broken dumper would have to be
broken identically on both sides of a `cmp` against a file it did not produce.

---

## 8. The one decision left for Oren

**`token_embd.weight.mv4i` is 572,207,104 bytes of HBM that nothing on the card
reads**, once the host owns the gather. That is 6.66% of the 8 GiB, loaded and
hash-verified per boot for nothing. `docs/2026-08-28_token-io-path.md:340-345`
raised it, explicitly declined to choose, and it is still unchosen:

- **Drop it from the load set** and recover 546 MiB. Costs a change to the load
  manifest and forecloses an on-card gatherer without a re-pack.
- **Keep it** as pre-positioning. Costs the space and the per-boot verify.

Nothing in this track chose. Note also that the manifest and the residency map
already disagree about WHERE it lives (`hbm_offset = 572,207,104` in the
manifest vs `0x1_D000_0000` in `docs/2026-08-27_hbm-residency-map.md:182`),
flagged at `docs/2026-08-28_token-io-path.md:486` -- so if it is kept, that
contradiction has to be resolved by whoever writes the loader.

---

## 9. The full gate, and the port-contention probe

**Full unfiltered both-suite run**, `REGRESS_SCRATCH=... bash sim/regress.sh`,
with `BASELINE_PASS` raised to 86 in the same tree:

```
 suite sim   PASS 60   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 86   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 86 passing, matches the recorded floor of 86
 REGRESSION: PASS
```

The five NOCHECK rows are the pre-existing declared ones (`sim:tb_attn_beh`,
`sim:tb_gdn_conv_cycles`, `sim:tb_rms_sweep`, `sim:tb_swchain_beh`,
`tb:tb_engine_dbg`), all observation-only by design and unrelated to this
change.

**A second full regression was running concurrently on the box** (8 `ghdl-mcode`
processes against this run's 2 jobs), which is exactly the contention condition
the worklog warns produces spurious reds. It produced none here: FAIL 0 and
TIMEOUT 0, so nothing in the result needs discounting for it. The
`tb_engine_dbg` row took 437 s against a 900 s timeout, which is the closest
anything came.

**`sim/probe_abc_ports.vhd` is not a gate row and was run separately**, because
it is the artefact that carries the A-job census. It walks the 505-descriptor
table and still reports zero overlap:

```
probe_abc_ports: model = 32 blocks (24 GDN + 8 attention, interval 4), NCARDS = 1, table = 505 descriptors
  token 1: steps_done=505 err='0' cyc=134234
---- phase census, one token ----
  A_JOB     = 311
  B_JOB     = 24
  C_JOB     = 8
  VEC_NORM  = 65
  VEC_RES   = 64
  VEC_SWG   = 32
  jobs issued = 504 (table is 505 descriptors, END_TOKEN starts nobody)
---- overlap, COMPUTE windows (cycles) ----
  A&B = 0    A&C = 0    B&C = 0
---- overlap, PORT windows (cycles) ----
  A&B = 0    A&C = 0    B&C = 0
  A ports live while B or C computes = 0
  ok  zero cycles of A/B/C COMPUTE overlap over 1 token(s)
PASS probe_abc_ports
```

**A_JOB is 311, not 297, and jobs issued is 504, not 490.** Those are the two
landmarks in `docs/2026-08-27_hbm-port-contention.md:135` and in
`sim/probe_abc_ports.vhd`'s own comments, and 311 is the same number LMHEAD
measured independently through the Python generator ("311 of 311 A jobs
emitted, 0 refused"). The port-contention CONCLUSION is unchanged: still zero
overlap in both compute and port windows, and still a minimum inter-job gap of
4 cycles.

---

## 10. NOT verified -- the explicit list

1. **No hardware.** Nothing here ran on the FK33, and there is no bitstream in
   any case (OI-12).
2. **The corrected table has never been EXECUTED.** `seq_tbl_pkg`'s 505
   descriptors are walked by `tb_seq_desc_fetch`, `tb_seq_opdec`,
   `tb_seq_region_lock` and `probe_abc_ports`, none of which starts a real
   matvec; its own header says a real run is "tens of millions of
   element-cycles". So "the gateware accepts these 15 descriptors" rests on
   LMHEAD's `tb_mv4i_desc_image` measurement, not on anything run here.
3. **`tb_seq_tbl_shape` group 1 is a RESTATEMENT of `S_CHECK`, not an oracle
   for it.** It compares against the same two literals `seq_tbl_pkg` derives
   the plan from, so it cannot catch a wrong `MAXROWS_BFP` or a wrong
   `ROWS_IF` -- only a table that ignores the ones it was given. If the FK33
   build changes either generic, both files must change together and nothing
   checks that they did.
4. **Nothing checks that `A_ROWS_IF`/`A_MAXROWS_BFP` in `sim/seq_tbl_pkg.vhd`
   still match `rtl/matvec_int4_desc_axi.vhd:102,108`.** They are literals in
   two files. This is the same class as item 3 and is the most likely way this
   fix rots.
5. **`llama_map_pkg.n_steps` remains wrong for any shape with a windowed
   lm_head** (R2). No shape any bench elaborates has one, so nothing fails
   today. A future bench at the real 9B shape would trip it, and the local
   correction in `llama_sched_pkg` would keep `build_plan` and `build_table`
   consistent with each other but not with `n_steps`.
6. **The embedding gather itself is unimplemented in C.** `pl_embed_fn`
   (`server/pl_backend.h:70-71`) has exactly one implementation and it is
   `pl_embed_synthetic`, a hash (`server/pl_backend.c:50-62`). The reference
   recipe is Python (`tools/embed_gather.py`). Writing the C one is `server/**`
   and was not this track's to touch.
7. **The `wide`-vs-`d32` dequantize correction is still unapplied.**
   `docs/2026-08-28_token-io-path.md:361-370` MEASURED the normative spec
   recipe as 2.641x mean relative error against the `wide` one and deliberately
   did not change the normative document. Nothing here revisited it.
8. **No timing or area consequence of the +14 steps was measured**, only
   derived (section 5).
9. **The N4 survivor is a real blind spot that was not closed** -- two A jobs
   writing different regions of the same size are interchangeable to this
   bench.
10. **Only the FIRST of `sim/run_abc_ports.sh`'s configurations was re-run**
    (section 9). The slow-descriptor-memory, two-token and negative-control
    configurations were not, so "the negative control still reports overlap"
    is asserted on the old table only. The one run here has no negative
    control of its own, which is worth remembering before quoting its zero.
11. **The `ordinal` disagreement between the two VHDL generators** on the tail
    norm (`tools/gen_layer_program.py:407-409`) is recorded and NOT resolved.


---

## 11. CORRECTION, appended 2026-08-29: the `BASELINE_PASS` hunk landed under another track's commit

**What section 9 and the commit message would otherwise imply is wrong.** This
track's `sim/regress.sh` change -- `BASELINE_PASS` 85 -> 86 with its comment --
is NOT in this track's commit. It was swept into **`75a1c28` ("regress.sh:
never delete a scratch tree we did not create")** by a pathspec commit while it
sat uncommitted in the working tree. MEASURED:

```
$ git show 75a1c28 -- sim/regress.sh | grep -c "BASELINE_PASS=86"
1
$ git diff -- sim/regress.sh
(empty)
```

Nothing was lost and the floor is correct at HEAD. The defect is a commit whose
message describes only its own change while carrying someone else's. **This is
the fourth recorded instance of `git commit -m msg -- <path>` capturing the
working tree rather than the index in this repo, and the first where this track
was the victim rather than the author.** The mitigation this track had prepared
-- extract only my own hunk into a patch, `git apply --cached` it, commit with
no pathspec -- was written and ready, and was overtaken by the other commit
landing first. Preparing the right procedure does not help if another agent
commits the shared file in the window between reading the diff and staging it.

The intended patch is preserved at `regress_mine.patch` in this session's
scratchpad, and is now a no-op.

**Also checked, because `75a1c28` is about scratch-tree deletion and the track
that wrote it found its own gate run had been invalidated by exactly that:**
this track's gate log is intact. One banner, one `OVERALL` line, `REGRESSION:
PASS` as the final line of the file, and zero occurrences of "No such file or
directory" or "produced no result file".

```
$ grep -c "llama.vhdl regression" rg_full.log   -> 1
$ grep -n "OVERALL" rg_full.log                 -> 156: OVERALL PASS 86 FAIL 0 ...
$ grep -n "REGRESSION:" rg_full.log             -> 160: REGRESSION: PASS
$ grep -c "No such file or directory\|produced no result file" rg_full.log -> 0
```

**The trap that track recorded is worth repeating here: a `grep` over a
regression log returns every candidate verdict line, and only the LAST one is
the verdict.** This track's log has exactly one of each, so reading the first
match was safe -- but it was safe by luck of having only one block, not by
method. The check above counts the blocks before trusting the line.
