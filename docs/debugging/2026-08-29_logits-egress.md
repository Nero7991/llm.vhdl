# The logits egress seam: the one output the design threw away

**Date:** 2026-08-29
**Track:** EGRESS
**Tree:** `885420c` plus this track's changes.
**Tools:** GHDL 1.0.0 mcode (Ubuntu 1.0.0+dfsg-6), `sim/regress.sh`,
`sim/mutate_llama_top_smp.sh`. Vivado was NOT run by this track; every fabric
number below is quoted from a report another track produced and is cited to it.
**No hardware was touched:** no `xsdb`, no `hw_server`, no `vivado ... program`,
no `hw/fk33/pcieep.sh`, `jtag.sh`, `flash.sh` or `tcl/program.tcl`, no
`/dev/xdma*`.

---

## 1. The question, verbatim

> **TRACK REF9B (finding D1):** `sim/seq_tbl_pkg.vhd:341` routes the lm_head job
> with `FLG_TO_SMP`. **That flag appears nowhere in `rtl/llama_top.vhd`**, whose
> own banner at `:133-134` admits it and discards the final A job with
> `dst = R_NONE`. So `LOGITS` is the one seam the design cannot produce, and
> REF9B's whole-model reference therefore cannot be compared at the only place a
> token is decided.
>
> **TRACK SERVER (its one unsettled item):** subsystem A's only numeric egress
> today is `Y_IDX` / `Y_LO` / `Y_HI` / `Y_EXP`, which at 248,320 rows is roughly
> **1 to 2 seconds per token**. A `y`-to-HBM writeback is required and does not
> exist.
>
> These are the same hole seen from two sides. **The design cannot emit a
> token.**
>
> **Part 1: survey, from the RTL.** What does `FLG_TO_SMP` mean where it is set,
> what would have to consume it, what is `rtl/sampler_stream.vhd`, and what
> exactly happens to the final A job today.
>
> **Part 2: implement the part that is uncontroversial.** Make `llama_top` stop
> silently discarding the lm_head result [...] behind a generic defaulting to the
> current behaviour.
>
> **Part 3: the seam decision, which is OREN'S and not yours.** SERVER framed it
> precisely:
>
> > Whether a `y`-to-HBM writeback fits in the fabric decides whether "decode
> > returning logits" is the right seam at all; if not, the fallback is on-card
> > top-k and the host loses `top_p`.
>
> **Measure what you can and bring the decision back with numbers. Do NOT
> choose.**

---

## 2. The answer, up front

**The logits were never missing. They were produced, and dropped, one line
apart.** With RAW `out_mode` -- which both schedule generators already emit on
the lm_head step -- `matvec_core` puts a sign-extended s32 result on
`y_data(rr*64+31 downto rr*64)` and pulses `y_we`, and `rtl/llama_top.vhd`'s A
adapter accepted the beat and then discarded it, because its only routing
predicate was `j_dst < NREGION` and `R_NONE` is 255. `FLG_TO_SMP` reached
`job_flags` at `:1029` and was read by NOBODY in the whole file. So the missing
piece was not arithmetic, not a unit and not a memory: it was a two-line route.

**`SMP_EN` (default FALSE) now routes it.** The A adapter latches `FLG_TO_SMP`
with the rest of the descriptor, serialises A's raw s32 rows one per cycle
through a beat FIFO, publishes them on new `smp_*` output ports carrying a
VOCABULARY index that accumulates across a token's windows, and folds them into
`rtl/sampler_stream.vhd` -- the same streaming argmax `rtl/engine_shared.vhd:652`
already uses on the AXU3EG. **MEASURED, two new gate rows:** 64 logits per token,
two lm_head windows, two tokens, real `matvec_int4` in raw out_mode AND the
behavioural A against a full independent value oracle, both PASS. 13 of 16
mutations killed; the three survivors are named in section 6 and none is a
resolution gap I can close from inside this configuration.

**MEASURED, the landmarks did not move.** `tb_llama_top_real` prints
`R_X(0) = -16339 hash(R_X) = 92903` and `tb_llama_top` prints
`R_X(0) = -12049 hash(R_X) = 86767` with this track's `rtl/llama_top.vhd` and
with `git show HEAD:rtl/llama_top.vhd`, byte for byte, under the SAME
working-tree bench.

**Part 3, and this is the part that is a decision and not a result:** the
writeback is not a throughput problem and it is not close. One HBM write port
carries the whole vocabulary in **124 us against a 38.27 ms token budget
(0.32%)** and is **32x oversupplied** relative to the rate `matvec_int4` can
produce logits at. Two 256-bit HBM pseudo-channels are already reserved and
idle. The surprise is the fabric direction: **on-card top-k is NOT the cheaper
option in the fabric.** Its logic (ESTIMATE 3-5K LUT for k=64) lands INSIDE
`matvec_core`, which is 72-81% of every level-6 and level-7 congestion window in
the build that fails to route; the writeback's logic (ESTIMATE 1.5-2.5K LUT)
lands at the die edge on a port that is already reserved. What top-k actually
costs is capability, and the list is longer than `top_p`: it also loses
repetition/frequency penalties and `logit_bias` on any token outside k,
speculative-decoding verification, and REF9B's oracle at the only seam that
decides a token. Section 7 has the costed table, a third option neither track
named, and the one measurement that would change the answer.

---

## 3. Part 1: the survey, from the RTL

### 3.1 Where `FLG_TO_SMP` is set

| what | where | value |
|---|---|---|
| the constant | `rtl/llama_map_pkg.vhd:102` | `FLG_TO_SMP : natural := 2` (bit 1) |
| the constant, again | `sim/seq_tbl_pkg.vhd:44` | `-- bit 1, route y to sampler (raw mode)` |
| the real 9B table | `sim/seq_tbl_pkg.vhd:341` | `mk_desc(OP_A_JOB, flags => FLG_TO_SMP, src => R_XN, dst => R_NONE, n_rows => VOCAB_SH, n_cols => HID, out_mode => 1)` |
| the scaled table | `sim/llama_sched_pkg.vhd:276-278` | `if p(i).opcode = OP_A_JOB and p(i).dst = R_NONE then fl := FLG_TO_SMP; om := 1;` |
| the wire format | `rtl/seq_desc_fetch.vhd:95` | word 0, `[15:8] flags` |

Both generators agree, and both pair it with `out_mode = 1`, RAW.

### 3.2 What already CHECKS it

`rtl/seq_desc_fetch.vhd:490-505`, in `desc_chk`, and this is the strongest
evidence that the encoding was always intended to mean something:

```vhdl
if f_dst(pf_w) = NO_REGION then
  if f_flags(pf_w)(0) = '0' and f_flags(pf_w)(1) = '0' then
    bad := '1'; why := ERR_DESC;
  end if;
else
  if f_dst(pf_w) >= NREG then bad := '1'; why := ERR_DESC; end if;
  -- And the converse: a named destination with a route flag set would
  -- claim a region AND an external sink at once.
  if f_flags(pf_w)(0) = '1' or f_flags(pf_w)(1) = '1' then
    bad := '1'; why := ERR_DESC;
  end if;
end if;
```

`dst = 0xFF` is legal ONLY with a route flag, and a named destination WITH a
route flag is refused. So the descriptor plane has a checked, two-sided property
saying "this job's result leaves the region file" -- and the gateware one level
up did nothing with it.

### 3.3 What did NOT consume it

`grep -n job_flags rtl/llama_top.vhd` before this track: exactly two hits, the
signal declaration at `:645` and the port map at `:1029`. **Zero reads.**

The discard was two predicates in the A adapter, both on `j_dst`, where
`j_dst := to_integer(job_dst(6 downto 0))` = 127 for `R_NONE` = 255:

- the y sink, `rtl/llama_top.vhd:1968` (pre-change numbering): the beat is
  ACCEPTED -- seam rule (3), `y_we` has no ready -- and then
  `if j_dst < NREGION then yb(a) := ... end if;` stores nothing;
- `S_RUN`, `:2048`: `if j_dst < NREGION then st := S_DRAIN; else st := S_DONE;`
  so the writeback state is skipped entirely.

The file's own banner said so, at `:133-134`:

> `* There is no sampler and no lm_head output.  The final A job is issued with
> dst = R_NONE and its result is discarded.`

**The RTL and the banner agree, so there is nothing to adjudicate here.** What
IS stale is `sim/seq_tbl_pkg.vhd:341` itself: TRACK LMHEAD measured that a
248,320-row job is refused `err_code 0x3` by `matvec_int4_desc_axi`'s `S_CHECK`
in every out_mode, so that single-step encoding is a job the gateware refuses
(`docs/debugging/2026-08-29_lmhead-window-schedule.md` section 2). This track did
NOT fix that -- see section 9.

### 3.4 What the result actually looks like in RAW mode

`rtl/matvec_core.vhd`, the `re3` stage:

- `:829` `y_data(rr*64+63 downto rr*64) <= std_logic_vector(resize(a32, 64));`
  where `a32 := sat32(re2_shv(rr))`. **The logit is bits 31..0; bits 63..32 are
  sign extension, not payload.**
- `:832-835` `y_mask(rr)` is `rbase + rr < n_rows`, so the last tile of a job
  whose row count is not a multiple of `ROWS_IF` carries pad rows.
- `:865` `if out_mode = "00" then ybuf(re2_t) <= ynew; end if;` -- BFP alone is
  buffered. `:867` `if out_mode /= "00" then y_we <= '1'; end if;` -- raw
  STREAMS, one beat per row-tile, and is never buffered inside A.
- `:1032` `y_exp <= ... (w_exp + x_exp - os_r);` for raw. **No per-job term.**
  That is the property that lets 15 windows feed one comparator, and it is the
  reason LMHEAD chose raw over BFP: BFP's `ns` is a max over the job's rows, so
  15 BFP windows carry 15 different exponents into a sampler whose only input is
  a bare 32-bit integer.

So the s32 logits were on a bus, one row-tile per beat, with a validity mask and
a job-constant exponent, and the adapter dropped them.

### 3.5 `rtl/sampler_stream.vhd`

67 lines, `entity` at `:17`. A streaming argmax:

- `clr` resets, `in_valid` folds one s32 `in_v` at the running index, `token` is
  the running argmax.
- `:57` `elsif cur > best_v then` -- a STRICT `>`, so the FIRST max wins on
  ties, matching `sample_argmax()` in the C oracle (its header says so at
  `:2-4`).
- `VOCAB` is declared at `:19` and **referenced nowhere in the architecture** --
  it keeps a running index, not an array. So it does not scale with vocabulary
  and its value is documentation.
- Its only instantiation is `rtl/engine_shared.vhd:652`, the AXU3EG whole-loop
  engine. It had never been instantiated in `llama_top`.

The one recorded area figure is **69 LUT / 129 FF**
(`sim/util_engine_shared_hier.rpt:43`) -- and that is `xczu3eg-sfvc784-1-e` at
`Design State: Synthesized`, i.e. **the wrong part**. `sim/post_sampler.tcl`
synthesises it but runs no `report_utilization`. There is **no FK33 area number
for `sampler_stream` anywhere in this tree.**

---

## 4. Part 2: what was implemented

All of it in `rtl/llama_top.vhd`, additive, behind `SMP_EN : boolean := false`.
`sim/tb_llama_top.vhd` was NOT touched (TRACK BISECT owns it).

**Generics added:** `SMP_EN` (default false) and `SMP_FIFO` (default 8).

**Ports added, ALL OUTPUTS:** `smp_valid`, `smp_v(31:0)`, `smp_idx(31:0)`,
`smp_exp`, `smp_token(31:0)`, `smp_done`, `smp_n(31:0)`, `err_smp_ovf`. Outputs
because VHDL permits an unassociated output port and does not permit an
unassociated input without a default -- so **an existing instantiation needs no
change at all**, which is what keeps TRACK BISECT's in-flight bench work valid.
Tied off in a `gsmptie` branch when not `SMP_EN`.

**The producer half**, in BOTH `ga_real` and `ga_behav`:

- `j_smp <= job_flags(1)` latched at `job_issue`, never read live. Seam rule (1)
  applied to a ROUTE rather than to a shape.
- a per-token `smp_base`, zeroed on `go`, advanced by `n_rows` when a
  `FLG_TO_SMP` job finishes -- AFTER its last beat has been pushed with the old
  base, so a window boundary cannot renumber beats still in flight.
- a new `S_SDRAIN` state: a `FLG_TO_SMP` job does not report `done` until the
  sampler has seen every logit it produced.

**The consumer half**, `gsmp`: a beat FIFO, a lane serialiser that emits one
VALID lane per cycle in index order and skips masked lanes at no cycle cost, and
one `sampler_stream`.

**Two new gate rows**, and they check DISJOINT things:

| row | A | value evidence |
|---|---|---|
| `sim/tb_llama_top_smp.vhd` | the real `matvec_int4`, raw out_mode | a ROUTE COMPARISON: the same job written to a region, low 16 bits. NOT an oracle |
| `sim/tb_llama_top_smp_beh.vhd` | the behavioural A | a full INDEPENDENT recomputation of every logit, its index and the argmax |

`sim/regress.sh`: `BASELINE_PASS` 83 -> 85, raised in the same edit as the rows.
Neither row needs a vector file. MEASURED 0.70 s and 0.45 s standalone, so
neither belongs in `SLOW_TBS`.

### 4.1 What is checked

P1 the logit COUNT and the DUT's own `smp_n`; P2 the vocabulary INDEX sequence,
exactly `0 .. NLOG-1`; P3 (behavioural only) every VALUE against the oracle;
P4 (real only) the route comparison; P5 the ARGMAX with first-max-on-ties;
P6 **a check on the BENCH** -- that the argmax lies in the SECOND window, so the
stimulus can still see a missing window base; P7 one `smp_done` per FLG_TO_SMP
job and ONE shared exponent for the whole token; P8 `err_smp_ovf` and
`err_lost_beat` clear.

---

## 5. The evidence, as raw captured output

### 5.1 The two new rows

```
sim/tb_llama_top_smp.vhd:559:5:@0ms:(report note): tb_llama_top_smp: A_BEHAV=true windows 30+34 = 64 logits, 2 tokens
sim/tb_llama_top_smp.vhd:746:7:@5405ns:(report note): tb_llama_top_smp: token 0: 64 logits, exponent 3, argmax 40 value 218667
sim/tb_llama_top_smp.vhd:746:7:@10805ns:(report note): tb_llama_top_smp: token 1: 64 logits, exponent 3, argmax 40 value 114543
sim/tb_llama_top_smp.vhd:765:7:@10825ns:(report note): tb_llama_top_smp: PASS.  2 tokens, 64 logits each, two lm_head windows, A_BEHAV=true

sim/tb_llama_top_smp.vhd:559:5:@0ms:(report note): tb_llama_top_smp: A_BEHAV=false windows 30+34 = 64 logits, 2 tokens
sim/tb_llama_top_smp.vhd:746:7:@8375100ps:(report note): tb_llama_top_smp: token 0: 64 logits, exponent 3, argmax 60 value 2233467
sim/tb_llama_top_smp.vhd:746:7:@16745100ps:(report note): tb_llama_top_smp: token 1: 64 logits, exponent 3, argmax 60 value 1199035
sim/tb_llama_top_smp.vhd:765:7:@16765ns:(report note): tb_llama_top_smp: PASS.  2 tokens, 64 logits each, two lm_head windows, A_BEHAV=false
```

### 5.2 The landmarks, this track's RTL against `HEAD`'s, same bench

Procedure: two GHDL libraries, identical in every file except
`rtl/llama_top.vhd`, one from `git show HEAD:rtl/llama_top.vhd` and one from the
working tree. The BENCH is the working-tree `sim/tb_llama_top.vhd` in both, so
TRACK BISECT's in-flight edits are controlled for rather than avoided.

```
== tb_llama_top_real, HEAD's llama_top
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run, 2 descriptor-latency points, R_X bit-identical across all of them, R_X(0) = -16339 hash(R_X) = 92903
== tb_llama_top_real, this track's llama_top
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run, 2 descriptor-latency points, R_X bit-identical across all of them, R_X(0) = -16339 hash(R_X) = 92903

== tb_llama_top, HEAD's llama_top
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run, 4 descriptor-latency points, R_X bit-identical across all of them, R_X(0) = -12049 hash(R_X) = 86767
== tb_llama_top, this track's llama_top
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run, 4 descriptor-latency points, R_X bit-identical across all of them, R_X(0) = -12049 hash(R_X) = 86767
```

`R_X(0) = -16339 hash 92903` is the recorded `tb_llama_top_real` landmark and it
is byte-identical.

**The 32-block landmark (`R_X(0) = -14110 hash 52347`, 491 descriptors, 65 log2
rms samples) was NOT re-measured and CANNOT be from this tree.** The only
committed weight image is `sim/llama_top_w_b4_pool.hex`, which is BLOCKS=4, and
`sim/tb_llama_top.vhd`'s loader REFUSES a short or long image rather than
truncating -- correctly. The 32-block image needs the 18 GB GGUF that is not in
git. See section 9.

### 5.3 The full unfiltered gate

`bash sim/regress.sh`, no `--only`, no `--quick`, no `--suite`, 2026-08-29:

```
PASS       sim:tb_llama_top                     113s  ... RESULT: PASS -- 64 descriptors, 4 bl
PASS       sim:tb_llama_top_real                 80s  ... RESULT: PASS -- 64 descriptors, 4 bl
PASS       sim:tb_llama_top_seq                 293s  ... RESULT: PASS -- 61 descriptors, 4 b
PASS       sim:tb_llama_top_smp                   2s  ... tb_llama_top_smp: PASS.  2 tokens, 64 logits each
PASS       sim:tb_llama_top_smp_beh               1s  ... tb_llama_top_smp: PASS.  2 tokens, 64 logits each

 OVERALL     PASS 85   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 85 passing, matches the recorded floor of 85
 REGRESSION: PASS
```

83 -> 85, and the floor was raised in the same edit as the two rows.

**Measurement note.** Another track was running its own full gate on the same
box while this one ran, so the wall times above are contended and are not
comparable with any earlier recorded figure. The verdicts are not affected;
the timings are.

---

## 6. Teeth: `sim/mutate_llama_top_smp.sh`, 16 mutations

Every mutation is well-formed VHDL and in bounds. Each row is tagged with the
GENERATE BRANCH it edits, **and reading the table without that tag will mislead
you**: `ga_real` and `ga_behav` are mutually exclusive, so a `[ga_real]`
mutation is not present in the elaborated design of `tb_llama_top_smp_beh` and
its "SURVIVED" there measures nothing at all. That is the pattern that has
produced three false clean sweeps in this project already.

```
C0  -- CONTROL, unmutated
  tb_llama_top_smp_beh  SURVIVED
  tb_llama_top_smp  SURVIVED
M1  -- [ga_real] smp_be_idx drops the window base (per-job row index)
  tb_llama_top_smp  KILLED   -- token 0, 34 of 64 logits carried the wrong vocabulary index
M2  -- [ga_real] the producer marks every lane valid, so pad rows are folded
  tb_llama_top_smp  KILLED   -- token 0 streamed 68 logits; the two windows are 30 + 34 = 64 rows
M3  -- [gsmp] the serialiser walks lanes highest-first
  tb_llama_top_smp  KILLED   -- token 0 streamed 17 logits; the two windows are 30 + 34 = 64 rows
M4  -- [ga_real] j_smp read live from job_flags instead of latched
  tb_llama_top_smp  SURVIVED
M5  -- [gsmp] s_clr on every FLG_TO_SMP job instead of on go
  tb_llama_top_smp_beh  KILLED   -- the DUT's own smp_n says 34 and 64 logits were streamed
  tb_llama_top_smp  KILLED   -- the DUT's own smp_n says 34 and 64 logits were streamed
M6  -- [gsmp] the FIFO pops off an occupancy that counts this cycle's push
  tb_llama_top_smp_beh  KILLED   -- token 0 streamed 0 logits
  tb_llama_top_smp  KILLED   -- token 0 streamed 0 logits
M7  -- [ga_real] the logit is taken from the upper half of the y lane
  tb_llama_top_smp  KILLED   -- token 0, 64 of 64 streamed logits DIVERGES from the region-routed twin
M8  -- [ga_real] smp_base advances by the tile-rounded row count
  tb_llama_top_smp  KILLED   -- token 0, 34 of 64 logits carried the wrong vocabulary index
M9  -- [ga_real] S_SDRAIN does not wait for the FIFO to drain
  tb_llama_top_smp  SURVIVED
M10 -- [gsmp] SMP_FIFO reduced to 1 beat
  tb_llama_top_smp_beh  SURVIVED
  tb_llama_top_smp  SURVIVED
M11 -- [sampler_stream] argmax ties broken on the LAST max
  tb_llama_top_smp_beh  KILLED   -- token 0, the sampler returned 55 and the argmax of the stream it was fed is 40
  tb_llama_top_smp  SURVIVED
M12 -- [ga_real] smp_exp published as the descriptor w_exp, not A's y_exp
  tb_llama_top_smp  KILLED   -- 34 logits carried an exponent other than 4
M13 -- [ga_real] smp_base is not cleared on go, index runs across tokens
  tb_llama_top_smp  KILLED   -- token 1, 64 of 64 logits carried the wrong vocabulary index
M14 -- [ga_real] smp_run is never asserted, so smp_done never pulses
  tb_llama_top_smp  KILLED   -- token 0, the sampler returned -1 and the argmax of the stream it was fed is 60
M15 -- [ga_behav] the streamed logit is narrowed to the region's 16 bits
  tb_llama_top_smp_beh  KILLED   -- token 0, 26 of 64 logits DIVERGES from the oracle
M16 -- [ga_behav] the beat index drops the window base
  tb_llama_top_smp_beh  KILLED   -- token 0, 34 of 64 logits carried the wrong vocabulary index
```

**13 killed on the row that elaborates them. THREE SURVIVORS, all analysed:**

**M4, `j_smp` read live from `job_flags` instead of latched. SURVIVED, and it is
genuinely equivalent under this machine.** `job_flags` decodes the LIVE
descriptor bank and only changes at the next `job_issue`; `seq_desc_fetch` is
single-issue and refuses to issue while `u_done` is high (`:787`), so no second
job can be issued while A is running and the live flags cannot move inside a
job's y window. The latch is still right -- it is seam rule (1), and rule (1)
exists because `u_start` leads `job_issue` -- but nothing in this design can
currently observe its absence. **It becomes observable the moment D issues to
another unit while A runs.** Do not delete the latch on the strength of this
survivor.

**M9, `S_SDRAIN` does not wait for the FIFO to drain. SURVIVED, and it is a
RATE-dependent survivor, not an equivalent one.** M10 shows the peak FIFO
occupancy at this shape is ONE beat, so at most four logits are in flight when
the job reports `done`, and `tok_done` arrives more than four cycles later. At a
shape where the FIFO actually fills, this mutation loses logits silently -- `y_we`
has no ready, so nothing counts them. The bench cannot produce that shape (see
M10). **This is the one survivor that is a real coverage gap.**

**M10, `SMP_FIFO` reduced to 1 beat. SURVIVED on both rows, with `err_smp_ovf`
clear.** So the peak occupancy at the simulated shape is one beat: the real
`matvec_int4` does not in fact deliver a row-tile every `ceil(n_cols/BLK)` = 2
cycles, whatever the arithmetic says it could. **The FIFO's default depth of 8
is therefore MARGIN, not a measured requirement, and the RTL now says so in its
own comment.** At the FK33 geometry the DERIVED rate is 48 rows per >= 128
cycles = 0.375 logits/cycle against a 1/cycle sink, so a shallow buffer is
enough there too. A build that needs the area back can take it.

Two rows that bite only one configuration, and both are informative rather than
weak: **M11** (tie-break) kills the behavioural row and survives the real one,
because whether there is a tie AT the maximum is a property of the DATA, not of
the design; **M15** (narrowing to 16 bits) survives at logits under 32,767, which
is why the bench's embedding magnitude was raised to +/-20,000 -- see section 8.

---

## 7. Part 3: the seam decision, costed. THIS IS NOT A CHOICE I MADE

### 7.1 The quantities

| quantity | value | label |
|---|---|---|
| `n_vocab` | 248,320 | MEASURED, llama.cpp's loader on this GGUF; `rtl/model_cfg_pkg.vhd:70` agrees |
| logit width, RAW out_mode | s32 | MEASURED, `rtl/matvec_core.vhd:829` |
| full-logits payload per token | 993,280 B | DERIVED, 248,320 x 4 |
| per-token budget | 38.27 ms | quoted, `docs/debugging/2026-08-29_host-seam-v2.md:445` |
| lm_head MACs | 1.017e9 | DERIVED, 248,320 x 4,096 |
| A's MAC rate at FK33 geometry | 1,536/cycle (ROWS_IF 48 x BLK 32) | from `gen_fk33_engine.py`; core clock 200 MHz MEASURED, `build_fk33_pcieep.tcl:248` |
| lm_head compute time | 3.31 ms | DERIVED, 1.017e9 / 1,536 / 200e6 |
| logits PRODUCTION rate | 0.375 rows/cycle = 300 MB/s | DERIVED |
| one HBM SAXI write port | 32 B/beat, 9.6 GB/s | MEASURED on this card, `hw/fk33/results/hbmbw_readwrite.txt:12` |
| free HBM pseudo-channels | **2** (`SAXI_30`, `SAXI_31`), 256-bit, already reserved | MEASURED, `build_fk33_pcieep.tcl:236` |
| C2H DMA rate | 1.11 GB/s (H2C is 3.27) | MEASURED, `docs/debugging/2026-08-28_fk33-first-light.md:141` |
| free LUTs in the failing build | 265,986 of 439,680 (60.5%) | MEASURED, `bd_wrapper_utilization_placed.rpt` |
| free SLICES -- the binding one | 27,171 of 54,960 (49.4%) | MEASURED, same |
| free URAM | 320 of 320, untouched | MEASURED, same |
| route status | **FAILS. Global congestion level 7; 282,428 of 282,451 nets unrouted** | MEASURED, `runme.log:3168` + `report_route_status` |
| what is congested | `matvec_core` is **72-81%** of every level-6 and level-7 window; `pcie2hbm` is 6% | MEASURED, `report_design_analysis -congestion` |

### 7.2 Option A: full logits to HBM, then C2H

**Time.** 993,280 B / 32 B per beat = 31,040 beats; at the 250 MHz HBM AXI clock
and one beat per cycle, **124.2 us**, which is **0.32% of the 38.27 ms budget**
and **3.7% of the lm_head's own 3.31 ms compute time**. Against the production
rate of 300 MB/s, one 9.6 GB/s port is **32x oversupplied**. DERIVED throughout.
The AXI3 4-bit `AWLEN` caps a burst at 16 beats, so this is 1,940 bursts, and
that cap costs nothing at this volume.

**C2H back to the host:** 993,280 B at 1.11 GB/s = **895 us, 2.3% of budget**.
That rate was MEASURED on a 1 GB transfer; **no small-transfer latency has ever
been measured on this card** and the estimate is optimistic by an unknown amount
(SERVER's open item, unchanged).

**Fabric.** A 256-bit AXI write master plus an s32-to-256-bit packer. **There is
no measured OOC number for ANY AXI write master in this tree** -- not
`attn_kv_axi`, not `hbm_tg`, not `hbm_tg_ip`. The nearest MEASURED comparable is
`axi_rd_port` at `DUAL_CLK=1, MAXOUT=16`, 256-bit: **550 LUT / 287 FF / 4
BRAM36** (`sim/ooc_fk33a/results.csv`). A write port is that plus a W-channel
datapath and a B counter. **ESTIMATE 1.5-2.5K LUT, 4-8 BRAM36**, assuming the
packer is a 1,536-bit-to-256-bit shifter with a small FIFO. That is ~0.9% of the
free LUTs.

**What it does to the descriptor plane.** Nothing, if the base address is an
AXI-Lite register written once per token and the offset is derived from a row
counter -- which works because the 15 windows are contiguous and in order. It
grows a descriptor field only if the base must be per-job, and that field would
move `tools/gen_layer_program.py`, both VHDL generators, and D-PROG's byte
identity. **Recommend the register, and say so in the plan.**

**The congestion risk, stated honestly.** The writeback must tap `y_data`, which
at `ROWS_IF = 48` is 3,072 bits leaving `matvec_core`. Those pins already exist
and already land inside `eng` (they feed `matvec_int4_desc_axi`'s 43-BRAM36
result buffer), so the bus is not new. What IS new is a path from there to a
port at the die edge. If the packer is placed next to the result buffer, only a
256-bit W channel crosses; if it is placed at the port, 1,536 bits cross. **The
second shape is the same class as the 6,912-bit `w_data` merge the congestion
doc names as a suspected cause. Put the packer next to the buffer.** Neither
version has been placed and nobody can say what either costs without running it.

### 7.3 Option B: on-card top-k

**Fabric.** A k-stage streaming insertion array at 1 element/cycle: each stage
holds (s32 value, u32 index), compares, keeps the max, passes the min down.
ESTIMATE ~50 LUT + 64 FF per stage, so **k=64 is ~3.2K LUT / 4.1K FF**, k=16 is
~800 LUT, k=8 is ~400 LUT. Cross-check: `sampler_stream` is k=1 and measures 69
LUT / 129 FF (on the WRONG PART, `xczu3eg`, at Synthesized state), and 64 x 69 =
4,416 LUT is the same order.

**Time.** k x 8 bytes. For k=64 that is 512 B = 128 AXI-Lite reads at the 1-2 us
per BAR read the token-I/O document estimates = **128-256 us, inside budget**.
**It needs no new AXI master, no HBM port, no DMA, and no descriptor field.** It
reuses the `Y_IDX`/`Y_LO`/`Y_HI` keyhole class that already exists.

**And this is where the comparison inverts.** Option B's logic sits in the
engine, next to `matvec_core` -- the block that is 72-81% of every level-6 and
level-7 congestion window in the build that does not route. Option A's logic
sits at the die edge on a pseudo-channel that is already reserved and idle.
**Measured by where the fabric is actually in trouble, the "cheap" option is the
more expensive one.** I cannot prove that without a place-and-route run, and I
did not do one; but the direction is the opposite of the intuition, and it is
the single most decision-relevant thing in this section.

### 7.4 What each forecloses

**Option A forecloses nothing.** temperature, `top_p`, `min_p`, typical-p,
repetition/frequency/presence penalties over the whole vocabulary, `logit_bias`
on arbitrary tokens, beam search, and speculative-decoding verification all
remain host-side and changeable without a rebuild. It also gives REF9B its
oracle: card logits against `ref/run9b`, per token, at the only seam that
decides a token -- which is REF9B's finding D1 and the reason this track exists.

**Option B's losses are broader than `top_p`:**

- **`top_k`** for any k' <= k: exact.
- **temperature**: works, renormalised over the k.
- **`top_p`**: becomes an approximation **whose error the host cannot detect**.
  Without the softmax denominator over all 248,320 logits, the host cannot tell
  whether the true nucleus fits inside k. For a peaked distribution it does; for
  a flat one it does not; **the host sees the same k numbers either way.** That
  is the sharp form of SERVER's "the host loses `top_p`".
- **repetition / frequency / presence penalties and `logit_bias`**: LOST for any
  token outside the top k -- which is the normal case, since a penalised token is
  by definition one the model already emitted and may now rank low.
- **speculative-decoding verification**: LOST. The verifier needs the target's
  logit at an arbitrary DRAFTED token id.
- **the REF9B oracle**: reduced to the top-k ordering.

**7.4.1 A cheap middle that neither track named: top-k PLUS the exact
normaliser.** If the card also returns `max_logit` and `sum(exp2(logit - max))`
over all rows, `top_p` becomes EXACT whenever the nucleus fits in k and, more
importantly, **DETECTABLE when it does not**. The exp2 is the expensive part and
this project already has streaming exp2 in `rtl/attn_softmax.vhd` /
`fixed_luts_pkg`. It converts "the host loses `top_p`" into "the host loses
`top_p` only when the nucleus exceeds k, and knows when that happened". It does
NOT recover the penalties, `logit_bias`, spec-decode verification or the oracle.

### 7.5 Option C, which neither track named: C2H from the EXISTING result buffer

`rtl/matvec_int4_desc_axi.vhd:936-937` writes `res(w_tile) <= y_data_i` on every
`y_we` **unconditionally, in every out_mode** -- so the raw logits are ALREADY
buffered on-card, in 43 BRAM36 (MEASURED, `congest_hier_util.rpt:384`), 17,424
rows deep, which is one window. Fifteen windows is fifteen buffer-fulls of
69,632 B each.

- **No HBM port, no AXI write master, no packer.** The buffer exists and is
  already written.
- What it needs: a DMA-reachable view of that BRAM (a new AXI slave on the
  engine, or a copy into the existing `fk33_dmabram`), plus a per-window
  handshake so the host drains window n while the card computes window n+1.
- What it costs: **15 C2H transfers per token instead of one**, and the host is
  now serialised against the card inside the 38.27 ms budget. Per-transfer
  latency has never been measured, so this is the option most exposed to the
  open item in section 9.
- It is the cheapest option in FABRIC and the most exposed in SOFTWARE.

### 7.6 The one measurement that would change the answer

**None of this matters if `route_design` keeps failing.** The build aborts at
global congestion 7 with 282,428 of 282,451 nets unrouted, and the congestion is
`matvec_core`'s -- 72-81% of every level-6 and level-7 window, with an
8,448-fanout net driven by a bare LUT6 inside a block smeared across all eight
clock-region columns. **Neither egress option addresses that, and neither is
worth building until a routable checkpoint exists.** TRACK CONGEST owns it.

The second measurement that would change it is **small-transfer C2H latency**,
which decides between A (one 993 KB transfer) and C (fifteen 68 KB transfers)
and has never been taken on this card.

---

## 8. Measured and REJECTED. Do not retry these

**Push-before-pop in the logits FIFO.** The first implementation computed
occupancy, pushed, then popped off the post-push occupancy. `fd`/`fm`/`fi` are
SIGNALS, so a beat written this cycle is not readable until the next, and the
pop therefore read the array's PREVIOUS contents at that slot. **MEASURED
consequence: token 0 folded ZERO logits** (the stale slot's mask was all zeros,
so the serialiser retired the beat without folding anything) **and token 1
folded 64 logits carrying TOKEN 0's VALUES.** Both tokens completed, `err`
stayed clear, no fault counter moved, and the argmax was a plausible number.
Kept permanently as mutation M6. **The pop must precede the push.**

**A serialiser that spends `A_ROWS_IF` cycles per beat regardless of the mask.**
The behavioural A emits one row per beat with mask `0..01`; a fixed-cost
serialiser would consume at 1/`A_ROWS_IF` of the production rate and overflow
any depth. The serialiser FINDS the next valid lane.

**Making `smp_done` a per-TOKEN pulse.** Considered and rejected on RTL
evidence: the descriptor plane has no field saying "this is the last window",
and the machine cannot know it is looking at window 15 of 15 rather than window
3. A per-token pulse would be a claim the design cannot support. It is per-JOB,
the port comment says so, and P7 checks `2*(t+1)` rather than `t+1` deliberately.

**Splitting the lm_head inside `llama_sched_pkg.build_plan`.** Rejected: it
would change `llama_map_pkg.n_steps`, which lives in `rtl/` and is what every
existing landmark's 491-descriptor count is measured against. The bench builds
its own four-step table with `seq_tbl_pkg.mk_desc` instead, so the wire format
cannot drift while the step count does not move.

**Two windows at the same output scale.** MEASURED: the argmax landed at index 5
and 4 for the two tokens, i.e. inside window 0 both times, so the vocabulary
offset never entered the answer and P5 could not have seen a sampler numbering
window 1 from zero. The windows are now four binary places apart in `out_shift`
with `w_exp - out_shift` held constant, and P6 fails the run if the argmax ever
drifts back into window 0.

**An embedding magnitude of +/-200.** MEASURED: logits came out around 5,000 and
mutation M15 -- narrowing the streamed value to the region's 16 bits -- was
INVISIBLE. Raised to +/-20,000, logits are now 218,667 and 2,233,467, and M15
kills.

**A `y`-to-region twin at a DIFFERENT step index for the route comparison.** The
A adapter derives A's weight base from `j_step`
(`base := A_MEM_BASE + j_step * A_JOB_STRIDE`), so with `tb_llama_top`'s weight
image the streamed job and its region-routed twin would read DIFFERENT weights
and the comparison would fail for a legitimate reason -- and then be "fixed" by
loosening it. **This bench's weight memory answers on `addr mod A_JOB_STRIDE`
and is step-invariant, which is the only reason P4 is sound.**

---

## 9. Measurement traps hit, including my own

**A generic-guarded mutation is not on the path.** `ga_real` and `ga_behav` are
mutually exclusive generate branches. Eleven of the sixteen mutations edit
`ga_real`, and every one of them "SURVIVED" on `tb_llama_top_smp_beh` -- not
because the behavioural row is weak but because **the mutated line is not in its
elaborated design at all**. The first version of the mutation table did not tag
the branch and read like a 3-of-16 kill rate on that row. Every row is now
tagged, and `sim/mutate_llama_top_smp.sh`'s header says the trap by name.

**`to_unsigned` of an unconstrained `integer` output before its first reset.**
`sampler_stream`'s `token` is `out integer`, whose default initial value is
`integer'left` -- negative. `to_unsigned(s_tok, 32)` aborted the run at
elaboration with `bound check failure at rtl/llama_top.vhd`, which reads like a
sizing error and is a default-value error. The port assignment is guarded.

**`ghdl -a` on `rtl/*.vhd` in glob order re-obsoletes packages.** Analysing the
directory repeatedly makes `llama_map_pkg` obsolete `model_cfg_pkg` and then
reports `entity 'llama_top' was not analysed`, which reads exactly like a syntax
error in the file you just edited. The fix is to retry only the files that
FAILED, not all of them.

**The landmark comparison had to control for another track's edits.**
`sim/tb_llama_top.vhd` is modified in the working tree by TRACK BISECT. Running
this track's RTL against the committed bench and HEAD's RTL against the
committed bench would have compared two different things. Both sides use the
WORKING-TREE bench and differ only in `rtl/llama_top.vhd`.

**A landmark that cannot be reproduced is not a landmark you have checked.** The
32-block `R_X(0) = -14110 hash 52347` figure needs a weight image that is not in
git. I did not reproduce it and I am not claiming it is unchanged on the
strength of the 4-block runs; what I claim is section 5.2's two measured
identities plus the structural fact that `SMP_EN` is false by default, so `gsmp`
does not elaborate and `j_smp` is driven to `'0'` unconditionally.

---

## 10. NOT verified. Read this before quoting anything above

- **No hardware. No synthesis. No place and route.** Every fabric number in
  section 7 is either quoted from another track's report (cited) or an ESTIMATE
  whose basis is stated. **No area figure for the new logic has been measured on
  any part.** `sim/post_sampler.tcl` produces a funcsim netlist and runs no
  `report_utilization`, and there is no OOC script for `llama_top`.
- **The 32-block real-weight landmark was not re-measured.** Section 9.
- **The real lm_head geometry was never simulated.** These rows run 30+34 rows
  against 64 columns with `ROWS_IF = 4`. The FK33 lm_head is 15 windows of
  17,376 rows against 4,096 columns with `ROWS_IF = 48`. Nothing here exercises
  15 windows, a 4,096-column job, or a 48-lane beat.
- **`matvec_int4_desc_axi` is not in the loop.** `llama_top` instantiates
  `matvec_int4` directly, so the `S_CHECK` bound that forces the 15-window split
  is not present in this bench. The windowing is exercised as a SCHEDULE
  property, not as a refusal.
- **The FIFO is never filled.** M10 shows depth 1 suffices here, so the overflow
  path, `err_smp_ovf`, and mutation M9's failure mode are all UNEXERCISED. The
  overflow `report` has never fired in a passing configuration.
- **The argmax INDEX does not move between the two tokens** (40 and 40
  behavioural, 60 and 60 real) even though every logit VALUE does. Both weight
  images are fixed across tokens and one row dominates the row norm. **A defect
  that froze the argmax at a constant would not be caught by comparing tokens.**
- **Nothing here says the logits are RIGHT.** The real-A row's value check is a
  route comparison against the same hardware; A's arithmetic is
  `sim/run_matvec.sh`'s claim against a C oracle. The behavioural row's oracle
  checks a synthetic closed form, not inference.
- **`sim/seq_tbl_pkg.vhd:341` still encodes the single-step lm_head that TRACK
  LMHEAD proved the gateware refuses** (`err_code 0x3`). This track did not fix
  it: correcting it moves `TBL_STEPS` from 491 to 505 and that is a change to a
  number several other tracks measure against. It is flagged, not fixed.
- **`smp_token` is an argmax, not a sample.** There is no temperature, no
  `top_p` and no RNG on the card, and this track added none.
- **No host-side anything.** `server/**` was not touched. Nothing consumes the
  `smp_*` ports outside the two new benches.

---

## 11. Open, not yet answered

- **Does the composed design route with any of this in it?** It does not route
  WITHOUT it. TRACK CONGEST owns the answer and it gates everything in section 7.
- **What is the real per-transfer C2H latency for a 68 KB and a 993 KB
  transfer?** It decides between option A and option C and has never been
  measured on this card.
- **Is one shared logits exponent enough dynamic range across 248,320 rows?**
  Forced by RAW `out_mode`, relied on by the 15-window split, checked here as an
  INVARIANT (P7) and not as a sufficiency claim. Nothing measures the resulting
  quantization of the softmax at temperature. Unchanged from SERVER's list.
- **Where does the writeback base address come from?** Recommended as an
  AXI-Lite register rather than a descriptor field (section 7.2), but only
  `hw/fk33/gen_pcieep.py` can say what BAR offset is free.
- **Should `matvec_int4_desc_axi` grow the write master, or should it sit in
  `fk33_engine`?** The result bus already lands inside `eng`; the placement
  decides whether 256 or 1,536 bits cross to the die edge, and that is the whole
  congestion argument.

---

## 12. Corrections

None yet. Later findings that overturn anything above must be appended here as a
dated CORRECTION section with the superseded claim marked withdrawn, never by
editing the text above.
