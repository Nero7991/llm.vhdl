# The C seam already closed; what it could not see was the LAYER

**Date:** 2026-08-29. Branch `fpga`. Track C-SEAM.
**Design under test:** the bench work landed as **`c6fef87`**, on top of
`3070fab`. Four files: `ref/attn_block_seq_vec.c`, `sim/tb_attn_kv_seam.vhd`,
`sim/mutate_attn_kv_seam.sh` and one hunk of the shared `sim/regress.sh`
(`BASELINE_PASS` untouched at 94). **`rtl/attn_block.vhd` and
`rtl/attn_kv_axi.vhd` are UNCHANGED by this track**; every RTL mutation below
is a scratch copy, and the two integration runs in section 7.6 are `git
archive HEAD` snapshots with one file replaced. Measurements taken before the
commit were taken on that working tree, which held no other track's edits to
any of the four paths -- verified by `git diff -- sim/regress.sh` as its own
step before staging.

**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado ... program`,
nothing under `hw/fk33/`, nothing opening `/dev/xdma*`. No Vivado at all: every
number here comes from GHDL (mcode) or from `gcc`.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

From this track's brief:

> **THE TASK: backlog item 1.** Wire the KV interface into `attn_block` and
> prove multi-token attention.
>
> Backlog wording: "`attn_block` <-> `attn_kv_axi` seam. Wire the KV interface
> into the block and prove multi-token attention." Its dependency (TRACK C-KV)
> has landed, and TRACK C1 has just released `rtl/attn_block.vhd`.

and, as the standing warning it turned out to be aimed at exactly:

> **Beware a bench that hardwires a dimension.** `tb_attn_block` hardwiring
> `layer => 0` is precisely what hid defect C1 for months. Multi-token is your
> subject here, so make sure the bench actually varies token index, layer AND
> KV block, and say which of those it does not.

---

## 2. The answer, up front

**Backlog item 1 was already done, and had been for sixteen hours.** It landed
in commit **`e7e7ae5`** (2026-08-28 22:48:43 -0600), "attn_block <->
attn_kv_axi: close the seam, and the first multi-token attention", with
`sim/tb_attn_kv_seam.vhd`, `ref/attn_block_seq_vec.c`,
`sim/mutate_attn_kv_seam.sh` and a write-up at
`docs/debugging/2026-08-28_attn-block-kv-seam.md`. **The backlog row was never
struck through**, which is the same table defect the worklog's In-flight
section has its own rule about and which TRACK REF9B hit on row 12.

**What the landed seam could not see was the LAYER.** Its own header said so:

>     --   * NOT more than one layer at a time.  LAYER_SEL is one layer; the
>     --     address equation's `layer` term is exercised only in that it is
>     --     non-trivially multiplied, not by two layers interleaving.

That is exactly the blind spot the brief names, one level up. So this track's
real work was to make the multi-token seam bench interleave **two layers**, and
the headline result is a measurement, not an opinion:

> **MEASURED: the pre-change single-layer seam bench PASSES with defect C1
> fully restored in `rtl/attn_block.vhd` at all four of its sites**, printing
> `PASS ... BIT-EXACT against ref/attn_block_seq_vec.c over 1028 output values
> and 1088 record bytes in HBM`. **The interleaved bench kills the same mutant
> on Q1, the value oracle.**

Four properties were unfalsifiable before this change and are falsifiable now.
Properties are tagged **LPn** in the bench header; the MUTATIONS that kill them
are tagged **Ln** in `sim/mutate_attn_kv_seam.sh`, and the numbers deliberately
do not line up:

| property | what it says | mutation that kills it |
|---|---|---|
| **LP1** | `v_ref` is folded per **(layer, KV head)**, C spec 2.1.4 / defect C1 | L1 |
| **LP2** | the address equation's `layer` term, agreed by two different masters | L4, L5 |
| **LP3** | the QK-norm weights are **latched per layer** (SEAM 1) | L7 |
| **LP4** | `kv_layer` tracks the configured layer, as `llama_top` asserts | L6 |

LP4's checker, `Q8`, needed a mutation written specifically for it: L2..L5 all
die on `Q5` before `Q8` is consulted, and under L3 the block genuinely IS
configured for layer 0, so `Q8` is right to stay quiet. See 7.4.

**`rtl/attn_block.vhd` and `rtl/attn_kv_axi.vhd` are correct on all four.** The
extended bench passed on its first run and every layer mutation dies.

**A second finding, from asking whether the work was redundant.**
`sim/tb_llama_top_seq.vhd` already interleaves two attention layers and says so
in its own header, so the honest question was whether it covered this already.
It does not, and the reason is not the schedule:

> **MEASURED: `tb_llama_top_seq` PASSES with defect C1 restored, and PASSES
> again with `v_ref` collapsed to a SINGLE register shared across every layer
> and every KV head** -- strictly worse than C1. Its R_X landmark is
> `report`ed, never `assert`ed, so its gate is self-consistency across three KV
> read latencies and a deterministic defect is consistent with itself.

**Interleaving the layers is necessary and nowhere near sufficient.** What
makes the seam bench able to see C1 is the schedule **plus** an independent
value oracle at the level of the output. The integration bench has the first
and not the second; the pre-change seam bench had the second and not the
first. Only both together kill L1. Raised as **OI-3b** in section 11; this
track does not own that file and has not touched it.

---

## 3. Corrections to the brief

Reported under their own heading because the brief asked for it.

1. **"Backlog item 1 ... Its dependency (TRACK C-KV) has landed."** The item
   itself had also landed, at `e7e7ae5`, and the backlog row is unstruck.
   MEASURED: `git log --format='%h %ad' --date=iso -- rtl/attn_block.vhd
   rtl/attn_kv_axi.vhd sim/tb_attn_kv_seam.vhd`.
2. **"`vref_r` ... indexed `lay_r*N_KVH + kvh` at four sites" is correct on the
   count and imprecise on the spelling, and the imprecision has teeth.**
   MEASURED, `grep -n 'vref_r' rtl/attn_block.vhd`: the four indexed sites are
   `:952`, `:1314`, `:1318`, spelled `lay_r*N_KVH + kvh`, and `:1618`, spelled
   `lay_r*N_KVH + h` -- plus the declaration at `:430` and two whole-array
   resets. A mutation anchored on the `kvh` spelling alone therefore changes
   three of four and yields a design that is neither correct nor the defect,
   so a kill would say nothing. `mutate_rtl_n` was added to this track's
   harness with a REQUIRED occurrence count for exactly that reason.
3. **`sim/regress.sh` is at `BASELINE_PASS 94` and this track does not move
   it.** No `sim/tb_*.vhd` is added; the existing `tb_attn_kv_seam` row is
   changed in place.
4. Not a correction, an addition: **`sim/tb_attn_kv_seam.vhd` and
   `sim/mutate_attn_kv_seam.sh` already existed** and are owned by this track
   per the brief, so no new gate row appears.

---

## 4. The procedure, in the order it was run

Each step says what it isolates.

1. **Read the git history of the owned files before anything else.** This is
   what found that the item had landed. Isolates "is there work here at all"
   from "is the work good".
2. **Run the existing bench at HEAD, unmodified.** `REGRESS_SCRATCH=... bash
   sim/regress.sh --only tb_attn_kv_seam --keep`. Establishes the baseline and
   proves the machine is quiet. Controls for the standing "a full-gate run
   showing failures you cannot have caused is machine contention" trap.
3. **Read the bench's own "WHAT THIS DOES NOT ESTABLISH" section.** It named
   the gap. Cheaper than deriving it.
4. **Extend the ORACLE first, in C, and measure the defect there before
   touching any VHDL.** A shared-`v_ref`-across-layers mutant of
   `ref/attn_block_seq_vec.c` moves 371 of 10,645 integers. Isolates "is the
   schedule capable of exposing this at all" from "does the RTL have it". If
   the C oracle had not moved, no amount of VHDL work would have helped.
5. **Extend the bench, run it, and distrust the first-run PASS.**
6. **The resolution-floor measurement.** Restore defect C1 in a scratch
   `rtl/attn_block.vhd` and run it against the **pre-change** bench and oracle,
   recovered with `git show HEAD:`. This is the step that turns "the new bench
   kills it" into "the new bench kills something the old one could not".
7. **Mutation, six rows for the layer plus one for the axis itself.** L7 is
   not a defect mutation: it asks whether the per-layer weight axis reaches the
   DUT at all, because if the bench had wired layer 0's weights to every job
   then L3 would still kill and the axis would be dead with nothing saying so.
8. **Re-run the whole pre-existing mutation harness**, to check the refactor
   did not weaken a check that already worked. Isolates "the new rows work"
   from "the old rows still work", which are different claims.
9. **Ask whether the work was redundant, and measure the answer rather than
   argue it.** `sim/tb_llama_top_seq.vhd` already interleaves two layers, so
   run the same C1 mutant through it -- and then, because a PASS is equally
   consistent with the mutant never reaching the checker, run a strictly worse
   mutant as the negative control. This step is the one that produced the more
   important of the two findings, and it exists only because the redundancy
   question was asked out loud instead of assumed away.
10. **Full gate.**

---

## 5. The design of the schedule, and why the obvious one is wrong

The run is `NTOK*NLAY` jobs in **token-major, layer-minor** order:

    step s -> token t = s/NLAY, layer l = s mod NLAY

so (tok 0, lay 0), (tok 0, lay 1), (tok 1, lay 0), ... This is the order a
transformer runs, and it is the only order in which the per-layer state is
contended.

**Running layer 0's whole sequence and then layer 1's would have been the
obvious cheap change and it is measurably weaker.** With the fold shared, layer
0 would be untouched (layer 1 has not run yet), and layer 1 would be wrong from
its first token -- so half the defect is invisible and the other half looks
like a first-token effect rather than a layer effect. **DERIVED**, from the
same measurement that gives the table in section 7.2: defect C1 moves layer 1's
outputs at **every** token including token 0, and never moves layer 0's,
precisely because layer 0 runs first at each token.

Three quantities were made per-layer, and each is a distinct claim:

* **the norm weights**, so the latch has something to latch;
* **the activations**, hashed with `1013*t + 7717*l`, so no step's vector is a
  shifted copy of another's -- a shifted copy makes a read at the wrong layer
  look almost right;
* **the `v_ref` fold**, `NLAY*N_KVH` entries reset once per sequence.

MEASURED that the axis is live rather than assumed: the two layers' `qnw`
differ at **64 of 64** elements, their `knw` at **64 of 64**, and at token 0
layer 0's and layer 1's step blocks differ at **1280 of 1297** integers, of
which **256 of 257** are the output `y_exp` plus `y_mant`.

---

## 6. What the bench now varies, and what it still does not

The brief asked for this explicitly.

**Varies:** token index (0..3, and `cur_pos` with it), **layer** (0..1,
interleaved), KV head (0..1), KV block (0..3 within a record), record phase
(REC_B = 80 is not a multiple of the 32-byte beat, so the 16-byte phase
alternates with the parity of `pos`), and the 4 KB split (V_BASE = 4064 puts
layer 0's first V record across 4096).

**Does NOT vary, and each is a real hole:**

* **NLAY is 2.** A defect needing three distinct layers is not covered.
* **`ctx_len` is the same for every layer.** A design that latched `ctx_len`
  from the wrong layer's job is invisible here.
* **The geometry is not the shipping one.** HEAD_DIM 64 / 4 query heads /
  2 KV heads / KV_BLOCK 16 / N_ROT 16, against a build of 256 / 12 / 2 / 32 /
  64.
* **The context is short.** NTOK 4. The s26 softmax denominator and the s36
  accumulator are the widths that would first bite at long context and neither
  is approached.
* **The HBM is a fixed-latency in-order model** with a single ID. No
  reordering across IDs, no refresh, no bank conflicts.
* **The layers are independent random streams**, not layer 0's output feeding
  layer 1. That is deliberate -- it maximises value diversity between the two
  layers -- but it means no inter-layer dataflow is checked here.

---

## 7. The evidence, as raw output

### 7.1 Baseline at HEAD, before any change

    PASS       sim:tb_attn_kv_seam                   10s
      tb_attn_kv_seam: PASS -- 4 tokens at cur_pos 0..3 ...
     OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
     REGRESSION: PASS

### 7.2 The oracle moves before any VHDL was touched

Positional comparison of the flat integer streams, 10,645 integers each:

    S6 (v_ref reset per STEP)          differs at 358 positions
    C1 (v_ref shared across layers)    differs at 371 positions

and where those positions are, by (token, layer), split into the output block
and the record block:

    S6 [((1, 0), [110, 0]), ((2, 0), [122, 0]), ((3, 0), [126, 0])]
    C1 [((0, 1), [57, 0]), ((1, 1), [84, 0]), ((2, 1), [114, 0]), ((3, 1), [116, 0])]

Read that table carefully, because it carries three findings:

* **The two `v_ref` mutations bite in DISJOINT places.** The per-token reset
  moves only layer 0; the shared fold moves only layer 1. Neither row makes
  the other redundant.
* **The per-token reset is carried by ONE layer at this seed.** Layer 1 does
  not move at all: its token-0 record already carries its own sequence
  minimum.
* **Neither mutation moves a single RECORD byte** (every second element of
  each pair is 0). So **Q2, the record image in HBM, cannot see either one.**
  The value oracle Q1 is the only check with teeth against the fold. This is
  the concrete form of "structure is not values": the records land at the
  right addresses with the right contents, and the numbers are still wrong.

### 7.3 THE RESOLUTION FLOOR: the old bench cannot see defect C1

Scratch tree with `sim/tb_attn_kv_seam.vhd` and `ref/attn_block_seq_vec.c`
recovered by `git show HEAD:`, and `rtl/attn_block.vhd` mutated at all four
`vref_r` sites to drop the layer term:

    C1 mutant written, 4 sites
    analyzed
    rc=0
    .../old/src/tb_attn_kv_seam.vhd:1251:7:@228615ns:(report note):
      tb_attn_kv_seam: PASS -- 4 tokens at cur_pos 0..3 through
      rtl/attn_kv_axi.vhd over AXI at 100-cycle read latency, BIT-EXACT
      against ref/attn_block_seq_vec.c over 1028 output values and 1088
      record bytes in HBM, every returned beat matched to the position it was
      requested for, k_base=16 v_base=4064 (neither 4 KB aligned), MAXCTX=8,
      longest quiet stretch 2137 cycles against a watchdog of 20000

**A bench reporting "BIT-EXACT" over 1028 values and 1088 record bytes, on a
design carrying the defect a whole track had just been spent fixing.** That is
the single most useful line in this document.

### 7.4 The layer mutations

Seven rows. Six are in `sim/mutate_attn_kv_seam.sh` as the new **L** family;
L7 was added after the full run and measured on its own.

    L2  KILLED     -- the CACHE is configured for layer 0 while the block runs the schedule's layer
            Q5 -- token 0 layer 1 signalled done, but its K record (head 0) block exponent 0 is not in memory yet
    L3  KILLED     -- the BLOCK is run at layer 0 while the cache is configured for the schedule's layer
            Q5 -- token 0 layer 1 signalled done, but its K record (head 1) block exponent 2 is not in memory yet
    L1  KILLED     -- defect C1 restored: the v_ref fold indexed by KV HEAD ALONE, at all four sites
            Q1 -- token 1 element 0 = 16829, the oracle says 16974.  MISMATCH against ref/attn_block_seq_vec.c
    L4  KILLED     -- the address equation's layer term DROPPED in attn_kv_axi, for both masters at once
            Q5 -- token 0 layer 1 signalled done, but its K record (head 0) block exponent 0 is not in memory yet
    L5  KILLED     -- attn_kv_axi MIRRORS the layer: both masters agree, every read is served
            Q5 -- token 0 layer 0 signalled done, but its K record (head 0) block exponent 0 is not in memory yet
    L6  KILLED     -- attn_block publishes kv_layer = 0 regardless of the layer it was configured for
            Q8 -- attn_block is writing layer 0 and it was configured for layer 1
    L7  KILLED     -- the block is handed the OTHER layer's QK-norm weights, everything else correct
            Q5 -- token 0 layer 1 signalled done, but its K record (head 1) block exponent 2 is not in memory yet

**L6 exists only because of a teeth check that failed.** After L1..L5 all
killed, `Q8` -- the `kv_layer` property, lifted from `rtl/llama_top.vhd`'s own
assert -- **had never fired**, because L2..L5 all die on Q5 first and under L3
the block genuinely IS configured for layer 0 so Q8 is correct to stay quiet.
A checker never shown to fail has not been shown to work, so L6 was written to
be the one shape Q8 owns: correct arithmetic, correct addresses, and only the
published layer ordinal wrong. It kills on Q8, which is the line above.

**L7 is not a defect row.** It asks whether the per-layer weight axis reaches
the DUT at all. Had the bench wired layer 0's weights to every job, L3 would
still have killed, the axis would have been dead, and nothing would have said
so.

### 7.5 The full pre-existing harness, re-run

Twenty-nine rows, of which twenty-three predate this track.

    verdicts: 18 killed by the checker, 0 aborted before the
      checker reached a verdict, 11 survived, of 29 attempted.

**Every one of the twenty-three pre-existing rows returns the verdict
`docs/debugging/2026-08-28_attn-block-kv-seam.md` section 6 recorded for it**,
including all seven survivors and both watchdog kills:

    S1 KILLED     S2 SURVIVED   S3 KILLED     S4 KILLED     S5 SURVIVED
    S5b KILLED    S6 KILLED     R1 KILLED     R2 KILLED     R3 KILLED(HANG)
    R4 SURVIVED   R4b KILLED    R5 KILLED(HANG)             R5b KILLED
    R6 SURVIVED   R7 SURVIVED   R7b SURVIVED  R7c SURVIVED  R7d KILLED
    C1 SURVIVED   C2 SURVIVED   C3 SURVIVED   C4 SURVIVED
    L1 KILLED     L2 KILLED     L3 KILLED     L4 KILLED     L5 KILLED
    L6 KILLED

12 kills before, 18 after; 7 survivors plus 4 controls before and after.
**DERIVED:** the six added rows are the whole of the difference, so the
refactor neither weakened nor accidentally strengthened an existing check.

**The seven survivors are NOT new and are not re-litigated here.** They are
analysed in section 6 of the 2026-08-28 write-up: S2/S5/R4 are killed once the
slave model is strengthened (S5b, R4b), R6 is covered by the block's own
bypass, and R7/R7b/R7c are the flush cases that R7d kills. Reporting them
again under their own names is the point of this paragraph -- they measure the
harness's resolution floor and dropping them would hide it.

### 7.6 Does the INTEGRATION bench already cover this?

`sim/tb_llama_top_seq.vhd` (TRACK TOP-KV, landed 2026-08-29) runs **two
attention layers in one token** and its own header says so, naming
`sim/tb_attn_kv_seam.vhd` as the bench that runs one layer. So the honest
question is whether the seam bench's new capability is unique or duplicative.

MEASURED by running that bench, unmodified, over a `git archive HEAD` snapshot
whose only changed file is `rtl/attn_block.vhd` with defect C1 restored at all
four sites. The snapshot's bench runs `C_REAL => true`, `KV_AXI => true`,
`ATTN_INT => 2`, so the real `attn_block` and the real `attn_kv_axi` are in
the path and two attention layers interleave:

    PASS       sim:tb_llama_top_seq                 299s
     OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
     REGRESSION: PASS

**A PASS is not yet a finding.** It is equally consistent with the mutation
never reaching anything the bench checks. So, negative control: collapse
`vref_r` to the single index 0, sharing ONE fold register across every layer
**and** every KV head -- strictly more destructive than C1, which keeps the
head dimension:

    NEGATIVE CONTROL written: v_ref collapsed to index 0, both layer AND head
    PASS       sim:tb_llama_top_seq                 319s
     OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
     REGRESSION: PASS

### 7.7 The finding that came out of asking

**`sim/tb_llama_top_seq.vhd` has NO value gate over `attn_block`'s output.**
Interleaving two layers did not give it the ability to see a layer defect,
because its properties are self-consistency and structure: R_X bit-identical
per token across three KV read latencies, 0 KV faults, no degenerate
residuals. A change that is deterministic across latencies passes all of them.

Its numbers ARE published -- `R_X(0)` and `hash(R_X)` -- but as a `report`,
never an `assert`. MEASURED: `grep -nE 'assert.*(xsum|results\(0\))'
sim/tb_llama_top.vhd` returns nothing.

**The bench's own header already recorded this fact from the other side and
nobody read it as a gap.** `sim/tb_llama_top.vhd:221-231`, written by TRACK C1
the same day:

>     -- THAT 32-BLOCK LANDMARK MOVED ON 2026-08-29 AND THE MOVE IS THE FIX, NOT A
>     -- REGRESSION.  ... With the fold given its missing `LAYERS` dimension the
>     -- same configuration reads
>     --                                  R_X(0) = -14035 hash(R_X) = 43861 at 32
>     -- and NOTHING ELSE about the run changes: still 491 descriptors, still 0
>     -- degenerate residuals, still PASS.

"Still PASS" before the fix and after it is the same sentence as "this bench
cannot tell the two apart". It is a correct and careful note; it simply was
not a defect claim, and it should have been.

This is a third member of the class **OI-3** already names ("the two defect
classes `tb_llama_top` cannot see ... both change every element and no
property can observe either"), found from the other direction. It is backlog
item 7's subject and it is **NOT** fixed here -- this track does not own
`sim/tb_llama_top.vhd`. It is raised, with a reproducible mutant, in section
11.

**The generalisation is the one this project keeps paying for:** interleaving
the layers is necessary and nowhere near sufficient. What makes the seam bench
able to see C1 is not the schedule on its own, it is the schedule **plus an
independent value oracle at the level of the thing's output**. The integration
bench has the first and not the second; the pre-change seam bench had the
second and not the first; only both together kill L1.

### 7.8 The gate

Full unfiltered run, no `--only`:

     OVERALL     PASS 94   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
     baseline: 94 passing, matches the recorded floor of 94
     REGRESSION: PASS

`BASELINE_PASS` is unchanged at 94, which is correct: no `sim/tb_*.vhd` is
added, so no gate row appears. The rows this track can affect:

    PASS       sim:tb_attn_block                      1s
    PASS       sim:tb_attn_kv_seam                   11s
    PASS       sim:tb_llama_top_seq                 305s

The 5 NOCHECK and 19 SKIPPED rows are pre-existing categories and are not
this track's; the `OVERALL PASS n` line was read rather than the word PASS,
per the standing rule about `--only` and about `REGRESSION: PASS` printing on
zero matches.

**Stated precisely rather than rounded up:** this gate ran against the tree as
of `c6fef87`. The one-line follow-up `984ca54` (section 9 item 5) landed
after it started. That change alters only back-pressure scheduling inside
`sim/tb_attn_kv_seam.vhd` and no other file, and the seam row was separately
re-run after it: `OVERALL PASS 1 FAIL 0`, ending at 457,945 ns against the
pre-fix 458,295 ns. The remaining 93 rows cannot see that file.

---

## 8. Measured and REJECTED -- do not retry

**8.1 `NLAY = 1`, i.e. leaving the schedule as it was. REJECTED, and the
generator now refuses it.** MEASURED in section 7.3: the single-layer bench
passes with defect C1 restored at all four sites, reporting "BIT-EXACT" over
1028 output values and 1088 record bytes. Adding more tokens, more heads, more
KV blocks or a longer context to a one-layer stream cannot recover this: the
defect is a leak BETWEEN layers and a one-layer stream has nothing to leak
from. **Do not "simplify" `NLAY` back out to save runtime.**

**8.2 Layer-major order -- run layer 0's whole sequence, then layer 1's.
REJECTED.** It is the cheaper edit and it is measurably weaker. **DERIVED**
from 7.2: under a shared fold, defect C1 moves layer 1's outputs at every
token including token 0 and never moves layer 0's, because layer 0 runs first
at each token. Layer-major would leave layer 0 clean for its whole sequence
and make layer 1 wrong from its first token, which reads as a first-token
effect rather than a layer effect and would have sent the next reader looking
at the wrong thing.

**8.3 Relying on Q2, the record image in HBM, to catch the `v_ref` defects.
REJECTED, MEASURED.** Section 7.2's table shows a `0` in the record-block
column for **every** differing position under both `v_ref` mutations: 358 and
371 integers move and not one of them is a record byte. `v_ref` changes the
READ-TIME alignment shift, not what is written. Q1, the value oracle, is the
only check with teeth against the fold -- which is the concrete instance of
this project's standing "structure is not values" rule.

**8.4 Assuming L3 (`MUT_BLK_LAY0`) covers the per-layer QK-norm weights.
REJECTED.** L3 deliberately feeds layer 0's weights along with layer 0's
layer index, precisely so that the mutant tests the layer ordinal and not the
weights. Without L7 the weight axis could have been dead. **Do not delete L7
as redundant with L3; it is the opposite of redundant with it.**

**8.5 Assuming Q8 was exercised because L2..L5 all killed. REJECTED,
MEASURED.** Q8 fired on none of them. See 7.4.

**8.6 Relying on `sim/tb_llama_top_seq.vhd` to cover the layer dimension
because it interleaves two layers. REJECTED, MEASURED, section 7.6.** It
passes with defect C1 and with a strictly worse collapse of the fold. Do not
retry this as a substitute for the seam bench, and do not read "the
integration bench interleaves N layers" as "the layer dimension is covered"
for any bench whose numbers are reported rather than asserted.

**8.7 A `diff`-based count of how many integers a mutation moves. REJECTED.**
It disagrees with the truth by exactly the amount a resynchronising diff
absorbs: `diff | grep -c '^<'` reported **370** and **357** where the correct
positional comparison gives **371** and **358**. Compare position by position.

---

## 9. Measurement traps hit

1. **The `diff` trap, 8.6.** Both files have the same length and the same
   layout, so the comparison must be positional. `diff` aligns and undercounts.
   Caught because the old regress.sh note recorded 358 for the per-token reset
   and the diff-based number came out 357; the discrepancy was the tell.
2. **A first-run PASS on a bench extension is not a result.** The interleaved
   bench passed the first time it ran. That is compatible with the extension
   being inert -- e.g. the weights wired to layer 0 for every job, or the
   layer ports still tied to a constant. What settles it is 7.3 (the old bench
   cannot see the defect the new one kills) and the L family, not the PASS.
3. **The mutation harness prints only the FIRST matching diagnostic**, so
   "L4 KILLED ... Q5" does not mean Q5 is the only property that fired. Q5
   uses `severity error`, so the run continues and Q1/Q2/Q3 also report. Do
   not read the harness output as a property attribution.
4. **`--only` takes a SUBSTRING**, and the shipping gate row and this bench
   share a prefix. `--only tb_attn_kv_seam` also matches nothing else here,
   but the `OVERALL PASS n` line was read on every run rather than the word
   PASS, per the standing rule.
5. **A REFACTOR CAN COUPLE TWO AXES SILENTLY, and the bench still passes.**
   Found by auditing my own diff, not by a failure. The back-pressure
   generator chose its configuration on `tok_i mod 2`, and `tok_i` had just
   become the STEP index -- so at NLAY = 2 the parity of the step IS the
   layer, and layer 0 would have run the never-stall consumer for the whole
   sequence while layer 1 ran the stalling one. Neither layer would ever have
   seen the other configuration. **The bench passes either way**; what is lost
   is half the consumer coverage per layer, on an axis that had full coverage
   before. Fixed to `pos_i mod 2` in `984ca54`. MEASURED: still PASS, and the
   run ends at 457,945 ns where it ended at 458,295 ns, so the schedule moved
   and the values did not.
   **Generalisation: when an index changes meaning, grep for every use of it,
   including the ones that only affect coverage rather than correctness.**
   Those are the ones no check can fail on.
6. **The tool's file cache goes stale when a file is edited by a script rather
   than by the edit tool.** Several edits here were applied with `python3 -` for
   multi-site replacements; the resulting "changed on disk" notices are that,
   not another track.

---

## 10. Open, not yet answered

* **NLAY = 2 only.** Nothing here covers a defect that needs three distinct
  layers. The oracle and the bench are both general in `NLAY`; only the gate
  row's argument is 2.
* **`ctx_len` does not vary per layer**, so a design latching it from the
  wrong layer's job is invisible. This is a NEW hole created by the change:
  before it, there was one layer and the question did not arise.
* **The shipping geometry has still never run this bench.** 64/4/2/16/16
  against a build of 256/12/2/32/64. This is backlog 13's subject, not this
  track's.
* **Saturation is not explored.** The brief's warning that saturation
  coverage and value diversity are opposed applies: the per-layer activations
  here are chosen for DIVERSITY (`1013*t + 7717*l` into the hash seed), and no
  adversarial all-rail layer stream was run. The trade was taken deliberately
  and the other side of it is unmeasured.
* **No inter-layer dataflow.** Layer 1's input is an independent random
  stream, not layer 0's output. Nothing here checks that the sequencer would
  feed one to the other.
* **`Q8` is checked only while a record write beat is offered.** A `kv_layer`
  that was wrong only during the read phase would not be seen. L6 holds it
  wrong throughout, so the mutation does not distinguish the two.

---

## 11. Raised for the dispatcher, not fixed here

**OI-3b: `sim/tb_llama_top_seq.vhd` passes with `attn_block`'s `v_ref` fold
destroyed.** Two runs, section 7.6: defect C1 restored at all four sites, and
the strictly worse collapse of the fold to a single register shared across
every layer and every KV head. Both PASS with `OVERALL PASS 1 FAIL 0`. The
bench runs `C_REAL => true, KV_AXI => true, ATTN_INT => 2`, so the mutant is
genuinely in the path.

The cause is not the schedule -- that bench already interleaves two attention
layers, which is what prompted the check. The cause is that its R_X landmark
is `report`ed and never `assert`ed, so its gate rests on self-consistency
across KV read latencies, and a deterministic defect is consistent with
itself.

This is the same class as **OI-3** and the same subject as **backlog item 7**.
This track does not own `sim/tb_llama_top.vhd` and has not touched it. The
reproduction is two commands and takes 5 minutes:

    git archive HEAD | tar -x -C <scratch>
    # replace <scratch>/rtl/attn_block.vhd's four `vref_r(lay_r*N_KVH + ...)`
    # index expressions with `vref_r(0)`
    cd <scratch> && REGRESS_SCRATCH=<scratch>/scr bash sim/regress.sh \
        --only tb_llama_top_seq --keep

**A second item, smaller: the BACKLOG's row 1 is unstruck and item 1 landed at
`e7e7ae5` on 2026-08-28.** This is the third recorded instance of a landed row
left unstruck (row 12 was the second, found by TRACK REF9B). This track cannot
edit `docs/WORKLOG.md`.

---

## 12. What this track did NOT verify

Stated plainly because a tidy conclusion that overstates its evidence is worth
less than an explicit list.

* **Nothing was synthesised.** No Vivado ran. Whether the interleaved bench's
  demands are met by hardware is untouched, and this track changed no RTL.
* **`rtl/attn_block.vhd` and `rtl/attn_kv_axi.vhd` were not reviewed.** They
  were mutated and run. A defect neither the L family nor the pre-existing 23
  rows names is not excluded by anything here.
* **The seven pre-existing survivors were not re-analysed**, only re-run and
  confirmed unchanged. Their analysis stands in the 2026-08-28 write-up.
* **No claim is made about the 9B shape**, about long context, or about real
  HBM behaviour. See section 6.
* **`sim/tb_attn_block.vhd` was not extended.** It runs one job, so it cannot
  hold two layers at all; making it do so would duplicate the seam bench with
  a weaker cache model. Considered and deliberately not done.
