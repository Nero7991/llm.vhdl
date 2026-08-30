# Lever C: does moving the IQ4_NL codebook to LUTRAM raise CLB packing density enough to matter?

**Date:** 2026-08-30
**Track:** LEVERC
**Repo state at start:** `ebf57bf` ("reopen lever C: its stated trigger fired,
and its closure judged the wrong design"), branch `fpga`.
**Hardware:** none touched. No Vivado run of any kind (both lanes held by TRACK
TIMING). Everything below is GHDL-mcode simulation, or arithmetic on numbers
other tracks MEASURED.

---

## The question, verbatim

> The honest question you must answer is not "does lever C save LUTs" but
> "does removing 97.7% of the design's MUXF7 raise the packing density enough
> to matter, and by how much". If the answer is no, say so early and loudly.

---

## The answer, up front

**No, and the question contains two errors that both have to be corrected
before the number means anything.**

1. **97.7% / 98.8% are the A-ONLY SHELL build's figures, not the composed
   design's.** In A+B+C+D, the design that actually has to fit, the codebook is
   **37.7% of MUXF7 and 47.6% of MUXF8** (DERIVED below from TRACK TIMING's own
   MEASURED census). Roughly half the mux population belongs to `d_norm` and
   `c_attn`, which lever C does not touch. This is the same defect the reopen
   block itself named in the closure it was overturning -- a figure carried
   forward from a smaller design onto a bigger one -- and it is repeated inside
   the reopen block.

2. **Packing density is the wrong figure of merit, and its SIGN is not
   determined by any measurement that exists.** A MUXF8 shape occupies four
   LUT6 in one CLB half and wastes none of them, so a fully-paired mux region
   sits at exactly 8.00 LUT/CLB -- the maximum -- and removing it LOWERS the
   average. Bounded against the MEASURED totals, lever C moves whole-design
   density anywhere from **6.05 (down) to 6.66 (up)** from today's 6.324. The
   measurement cannot tell which.

**What IS determined is absolute CLB count, and that is what should have been
asked about:**

```
CLB saving from lever C           3,072 .. 8,946   (bounds, DERIVED, section 3)
composed overshoot to be closed          11,534
fraction of the overshoot closed     27% .. 78%
post-lever-C occupancy             104.7% .. 115.4%  of 54,960 CLB
```

**Lever C alone does not close the fit under EITHER bound.** It is a real and
large win -- at the midpoint it is about a tenth of the device -- but the
decision it should inform is "which second lever", not "is this enough".

TRACK TIMING reached the same top-level verdict in section 7a of
`docs/debugging/2026-08-30_timing-composed-a-b-c-d.md` ("LEVER C ALONE DOES NOT
CLOSE IT"). This document does not overturn that conclusion. It does correct
the number underneath it: 7a's `+0.5 LUT/CLB` is a **one-point calibration of a
one-parameter model** whose premise -- that mux shapes cause packing loss -- is
not physically right, and the same measurements admit the opposite sign.
See section 3.3.

**Separately, and independently of whether lever C is ever taken: `K2b` is
closed.** The standing hazard was that `P_CB_CHK`'s idle invariant watched the
command REGISTER, so deepening the codebook write path made it vacuous with
nothing noticing. `sim/mutate_matvec_cb.sh` K2b was exactly that mutant and it
SURVIVED all six columns. It now KILLS in all six, and the **attribution
control (new mode S) confirms nothing that existed before would have caught
it.** K2c, its mirror, likewise.

---

## 1. What was done

| file | change |
|---|---|
| `rtl/matvec_core.vhd` | `CB_STYLE` generic ("regs" default = the shipping design, "distributed" = lever C, one codebook copy per LANE); `CB_LANES_PER_COPY` replaces the row-granularity arithmetic and is provably the same integer at the default; `CB_WR_LAT` declares the write latency; new `P_CB_MODEL` process |
| `sim/tb_matvec_core.vhd` | `CB_STYLE` generic, default "regs", passed to the DUT |
| `sim/tb_matvec_cb_contract.vhd` | same |
| `sim/tb_matvec_cb_lockstep.vhd` | same |
| `sim/mutate_matvec_cb.sh` | mode **S** (the attribution control), `CBSTYLE` env to re-run the whole table under lever C, read-side anchors retargeted |

The default generic value is the shipping design. Nothing that instantiates
`matvec_core` today passes `CB_STYLE`, so the entity proven bit-exact on
silicon is untouched.

### 1.1 Why the read path changed spelling, and why that is not a change

The read was `cb(rr / CB_ROWS_PER_COPY)(idx)` and is now
`cb((rr*BLK + j) / CB_LANES_PER_COPY)(idx)`, with
`CB_LANES_PER_COPY = CB_ROWS_PER_COPY * BLK` at the default.

For `0 <= j < BLK` these are the same integer, not merely equal in practice:

```
rr*BLK + j  =  (rr div R)*R*BLK  +  ((rr mod R)*BLK + j)
with  0 <= (rr mod R)*BLK + j  <  R*BLK
so    (rr*BLK + j) div (R*BLK)  =  rr div R      identically
```

MEASURED, by reporting the elaborated constants (`tb_matvec_cb_contract`,
BLK=16, ROWS_IF=4):

```
regs                        CB_COPIES=4   CB_LANES_PER_COPY=16  CB_WR_LAT=1
distributed                 CB_COPIES=64  CB_LANES_PER_COPY=1   CB_WR_LAT=1
regs, CB_ROWS_PER_COPY=4    CB_COPIES=1   CB_LANES_PER_COPY=64  CB_WR_LAT=1
```

The old spelling still collapses the bank exactly as it did (`CB_COPIES=1`),
which is the check that this is a re-parameterisation and not a redesign.

---

## 2. The procedure

Each step isolates one thing, in this order:

1. **Baseline the gate rows before touching anything.** `tb_matvec_cb_contract`,
   `tb_matvec_cb_lockstep`, `tb_matvec_core`, `tb_matvec_core_ragsat` -- all
   PASS at `ebf57bf`. Without this a later PASS is not evidence.
2. **Change the RTL, re-run the same four.** Controls for "did the
   re-parameterisation change the shipping path".
3. **Report the elaborated `CB_COPIES` in both styles.** Controls for the
   failure mode where the whole exercise is a no-op and every result below is
   worthless.
4. **Run the value oracle under lever C.** `tb_matvec_core` against
   `ref/matvec_int4.c` on the committed `sim/tr.txt`, with
   `-gCB_STYLE=distributed`. This is the oracle at the level of the thing's
   OUTPUT. A codebook that reads back correctly is not a matvec that computes
   correctly; that distinction is why this step exists and why the two
   codebook-specific benches do not replace it.
5. **Run the full mutation table in the shipping style**, with the new
   attribution-control column. Measures whether the new checker earned anything.
6. **Run the full mutation table again under lever C.** Measures the 32x
   write-coherency surface with the same instrument rather than arguing about it.
7. **Re-run every bench in the tree that instantiates `matvec_core` or
   `matvec_int4`.**

---

## 3. The evidence: the fit arithmetic

### 3.1 The inputs, all MEASURED by other tracks

From `docs/debugging/2026-08-30_timing-composed-a-b-c-d.md`, composed A+B+C+D:

```
composed LUT                                        346,971
placed CLB                                           54,866
density                                               6.324 LUT/CLB
MUXF8                                                25,788
MUXF7 total                                          65,108   (51,576 under an F8 + 13,532 free)
LUTs locked into mux shapes  25,788*4 + 13,532*2 =  130,216   (37.5%)

TT_MUX by instance:   a_eng/eng          24,869 F7   12,399 F8
                      d_norm/gvr.u_rms   17,696 F7    8,736 F8
                      c_attn/u_arr       15,796 F7    2,448 F8
                      b_gdn/u_emit        2,507 F7       --
                      c_attn/u_norm       1,089 F7       --
```

From `docs/debugging/2026-08-29_shell-congestion.md`, the codebook itself:

```
per lane, exactly:   16.0 MUXF7    8.0 MUXF8    32.6 LUT
at ROWS_IF=48, BLK=32 -> 1,536 lanes:
   24,576 MUXF7    12,288 MUXF8    50,128 LUT (49,152 of them the mux itself)
```

From `docs/debugging/2026-08-29_build-e2e-project-run.md`, the device:

```
LUT as Memory available on xcvu33p                  205,440    (46.7% of 439,680)
```

### 3.2 CORRECTION 1 -- the 97.7% / 98.8% do not apply to the composed design

DERIVED:

```
codebook MUXF7 / composed MUXF7   24,576 / 65,108  =  37.7%     (not 97.7%)
codebook MUXF8 / composed MUXF8   12,288 / 25,788  =  47.6%     (not 98.8%)
```

The shell figures were correct for the shell: in an A-only build the codebook
IS essentially the entire mux population. In A+B+C+D, `d_norm/gvr.u_rms` alone
carries 17,696 MUXF7 / 8,736 MUXF8, and `c_attn/u_arr` another 15,796 F7. So
lever C removes under half the mux shapes, not nearly all of them.

TRACK TIMING's own section 7a states the equivalent ("subsystem A is 38.2% of
the composed MUXF7 and 48.1% of its MUXF8") two paragraphs before quoting
97.7% / 98.8% into the lever-C estimate. **The reopen block in `docs/WORKLOG.md`
and the LEVERC brief both carry the shell figures forward onto the composed
fit.** That is the same shape as the closure defect the reopen block was
written to record.

### 3.3 CORRECTION 2 -- MUXF7/F8 shapes are the DENSEST part of the design, not the loosest

The mechanism, from the UltraScale+ CLB: a MUXF8 combines two MUXF7s, each
combining two LUT6s, and all four LUT6 must sit in the SAME CLB half. A CLB has
two such half-sites. So a MUXF8 shape occupies exactly 4 of a CLB's 8 LUTs and
**wastes none of them**; two shapes fill a CLB completely at **8.00 LUT/CLB**,
which is the device maximum.

Indivisibility costs the placer FREEDOM -- wirelength, congestion, legality --
not LUT sites. TRACK TIMING's model (`packing loss = k * locked-LUT fraction`,
`k = 0.558` from one point) charges the loss to the shapes themselves. That
premise is not physically right, and the consequence is a predicted density
INCREASE where the geometry predicts a decrease.

**Both models fit the one measured point.** Each has a free parameter and there
is one observation, so this is not a discriminating test. What CAN be done is
bound the answer using only arithmetic and the physical maximum of 8 LUT/CLB:

```
let M = CLBs holding the 130,216 locked LUTs
non-mux LUTs                     346,971 - 130,216 = 216,755
non-mux CLBs must be >= 216,755 / 8              =  27,095
so                       M <= 54,866 - 27,095    =  27,771
and                      M >= 130,216 / 8        =  16,277

mux-region density   130,216 / [16,277 .. 27,771]  =  8.000 .. 4.689 LUT/CLB
```

The loosest case consistent with the data is 4.69, not the ~3.3 the fully
unpaired geometry would give -- that extreme is **refuted by arithmetic**,
because it would require the non-mux logic to sit at 13.9 LUT/CLB, above the
device maximum of 8.

The codebook is 49,152 of the 130,216 locked LUTs (37.7%). Assuming it packs at
the mux-region average:

```
codebook CLBs today        49,152 / [8.000 .. 4.689]  =   6,144 .. 10,482
LUTRAM replacement         12,288 LUTRAM, 8 per SLICEM CLB when they
                           share WCLK/WE (they do, per row)  =  1,536
                           if only 4 per CLB (fragmented)    =  3,072

CLB saving   = [6,144 .. 10,482] - [1,536 .. 3,072]
             = 3,072 (worst) .. 8,946 (best)
```

### 3.4 What that does to the fit

Using TRACK TIMING's frame (`420,240 LUT` total, `66,494` CLB wanted at 6.324,
against `54,960` on the part):

| | CLB wanted | of 54,960 | overshoot closed |
|---|---:|---:|---:|
| today | 66,494 | 121.0% | -- |
| lever C, worst bound (-3,072) | 63,422 | **115.4%** | 27% |
| lever C, best bound (-8,946) | 57,548 | **104.7%** | 78% |

And the density, which is what the question asked about:

| | LUT | CLB | LUT/CLB |
|---|---:|---:|---:|
| today | 420,240 | 66,494 | 6.324 |
| lever C, tight packing, LUTRAM 8/CLB | 383,376 | 61,886 | **6.19** (falls) |
| lever C, tight packing, LUTRAM 4/CLB | 383,376 | 63,422 | **6.05** (falls) |
| lever C, loose packing, LUTRAM 8/CLB | 383,376 | 57,548 | **6.66** (rises) |

**The sign of the density change is not determined by any measurement that
exists.** The CLB saving is positive under every bound, and that is the number
to carry.

### 3.5 The number the analysis actually points at

`d_norm/gvr.u_rms` is 17,696 MUXF7 + 8,736 MUXF8 for what TRACK TIMING's own
section 9 identifies as **1024:1 16-bit read muxes over 65,536-bit flat ports**,
and its section 7a costs the replacement at **14.4 URAM288 of 320 free**. That
is 26,432 mux shapes removed against lever C's 36,864, for a change that opens
no write-coherency surface at all and touches nothing that has ever been on
silicon. NOT MY SCOPE and not measured here; recorded because the mux census
above is the evidence for it and a reader of this document should not have to
re-derive it.

---

## 4. The evidence: verification

### 4.1 Latency neutrality -- MEASURED, not argued

The read is a combinational lookup feeding a registered product
(`tr(0)(...) <= resize(cb(...)(idx) * xw, 28)` inside the clocked process).
An asynchronous distributed-RAM read has exactly that shape, so the change is
latency-neutral by construction, and the benches confirm it: the value oracle
compares the same **464 stage + 343 output values** in both styles, and
`tb_matvec_cb_lockstep` passes **on the tightest legal load-then-start
schedule** in both. Nothing re-establishes an arithmetic because nothing moved.

`CB_WR_LAT` is 1 in both styles. It is a constant rather than a comment
precisely so that a future stage cannot be added without it moving.

### 4.2 The value oracle under lever C -- the one that matters

`ghdl -r tb_matvec_core -gTRACE=sim/tr.txt -gRI=4 -gSTALL=0
-gCB_STYLE=distributed`:

```
PASS 6 RAW full top tile: out_mode=01 n_rows=64
PASS 7 PARTIAL above MAXROWS_BFP: out_mode=10 n_rows=65
PASS 8 RAW above MAXROWS_BFP: out_mode=01 n_rows=65
PASS 9 BFP above MAXROWS_BFP must be REFUSED: out_mode=00 n_rows=65
TOTAL: 464 stage + 343 output values compared, 0 mismatches (BFP, PARTIAL, RAW,
  the top of the row range at n_rows = 64 and both no-buffer modes above it at
  n_rows = 65)
RTL matches ref/matvec_int4.c at every stage, in all three out_mode values
```

This is an **independent C implementation compared at the output**, not a round
trip. Nothing in the check reads the codebook back through the path that wrote
it; that is the `m7 mutant` shape and it is what this deliberately is not.

### 4.3 The mutation table, shipping style (`CBSTYLE=regs`)

`SCRATCH=... bash sim/mutate_matvec_cb.sh`. Columns are `<mode><bench>`;
**A** = all checks live, **N** = `P_CB_CHK` demoted, **S** = `P_CB_MODEL`
demoted (the attribution control -- the design exactly as it stood before this
change). Benches: **C** contract, **L** lockstep, **M** value oracle.

```
CTRL   SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv    SC:surv    SL:surv    SM:surv
K1a    KILLED    AC:KILL(a) AL:surv    AM:surv    NC:KILL(a) NL:surv    NM:surv    SC:KILL(a) SL:surv    SM:surv
K1b    SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv    SC:surv    SL:surv    SM:surv
K1c    KILLED    AC:KILL(a) AL:surv    AM:surv    NC:KILL(a) NL:surv    NM:surv    SC:KILL(a) SL:surv    SM:surv
K1d    KILLED    AC:KILL(a) AL:surv    AM:surv    NC:KILL(a) NL:surv    NM:surv    SC:KILL(v) SL:surv    SM:surv
K2a    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(a) NL:KILL(a) NM:KILL(a) SC:KILL(a) SL:KILL(a) SM:KILL(v)
K2b    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(a) NL:KILL(a) NM:KILL(a) SC:surv    SL:surv    SM:surv
K2c    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(a) NL:KILL(a) NM:KILL(a) SC:surv    SL:surv    SM:surv
K3a    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(a) NL:KILL(a) NM:KILL(a) SC:KILL(a) SL:KILL(a) SM:KILL(a)
K3b    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(a) NL:KILL(a) NM:KILL(a) SC:KILL(a) SL:KILL(a) SM:KILL(a)
K3c    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(a) NL:KILL(a) NM:KILL(a) SC:KILL(a) SL:KILL(a) SM:KILL(a)
K3d    SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv    SC:surv    SL:surv    SM:surv
K4a    KILLED    AC:KILL(a) AL:surv    AM:surv    NC:KILL(a) NL:surv    NM:surv    SC:KILL(a) SL:surv    SM:surv
K5a    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(a) NL:KILL(a) NM:KILL(a) SC:KILL(v) SL:surv    SM:surv
K5b    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(a) NL:KILL(a) NM:KILL(a) SC:KILL(v) SL:surv    SM:surv
K6a    KILLED    AC:KILL(a) AL:surv    AM:surv    NC:KILL(a) NL:surv    NM:surv    SC:KILL(v) SL:surv    SM:surv
K7a    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(a) NL:KILL(a) NM:KILL(a) SC:surv    SL:surv    SM:KILL(v)
K7b    KILLED    AC:KILL(a) AL:KILL(a) AM:KILL(a) NC:KILL(a) NL:KILL(a) NM:KILL(a) SC:surv    SL:surv    SM:KILL(v)
K8a    SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv    SC:surv    SL:surv    SM:surv
K8b    SURVIVED  AC:surv    AL:surv    AM:surv    NC:surv    NL:surv    NM:surv    SC:surv    SL:surv    SM:surv
K9a    KILLED    AC:KILL(v) AL:surv    AM:KILL(v) NC:KILL(v) NL:surv    NM:KILL(v) SC:KILL(v) SL:surv    SM:KILL(v)

kill ratio: 16 KILLED + 0 ABORTED = 16 of 20;  4 SURVIVED
ATTRIBUTION CONTROL -- killed in A and NOT in S, so P_CB_MODEL earned it: K2b K2c
```

### 4.4 The mutations that do NOT bite, under their own names

This is the most valuable line in the table and it is unchanged by this work,
except that **K2b and K2c have left it**.

| tag | what it changes | why it survives | did that change? |
|---|---|---|---|
| **K1b** | the reset gate on command capture is dropped | the trailing `if rst = '1' then cbw_v <= (others => '0')` already covers it. K1d is K1b with the redundancy also removed and it DOES bite, which is what proves K1b is a genuine equivalent mutant and not a hole | no |
| **K3d** | every replica writes off replica 0's command registers (master/follower) | a true equivalent mutant **today**, because all command registers hold the same command every cycle. It is named so the master/follower design the RTL rejects by construction cannot be reached silently | no |
| **K8a** | every lane reads copy 0 | equivalent while the replicas are coherent, which is the entire point of the row. Still equivalent under lever C, at 1,536 copies | no |
| **K8b** | the copy select is rotated by one | same reason. K8a and K8b together are the evidence that **no functional bench can test the copy select** -- only `P_CB_CHK`'s coherency assertion makes them equivalent rather than wrong | no |

**These four are the measured resolution floor of the codebook closure.**
K8a/K8b in particular mean that if replica coherency were ever actually broken,
the read-side select would be untestable behaviourally. That is why
`P_CB_CHK`'s equality assertion is not redundant with the new model process and
must not be deleted as such.

### 4.5 The same table under lever C (`CBSTYLE=distributed`)

**Every verdict in every one of the 20 rows and all nine columns is identical**,
CTRL included, at `CB_COPIES = 64` instead of 4. Kill ratio 16 of 20, survivors
`K1b K3d K8a K8b`, attribution `K2b K2c`. Full output:
`/mnt/storage/leverc-scratch/mut_dist.txt`.

That is the write-coherency surface measured rather than argued: the mutations
that model a stale copy (K3a/K3b/K3c), a stale single LANE (K9a), and a
divergent init (K5a/K5b) all still bite when there is one table per lane.

### 4.6 K2b, closed

WORKLOG, verbatim: *"`P_CB_CHK`'s idle invariant watches `cbw_v(0)`, the command
REGISTER, not the write. Any future change that deepens the codebook command
path makes the invariant vacuous with nothing in the tree noticing."*

The fix is not to watch a different register -- the next stage moves past that
one too. `P_CB_MODEL` does not watch a register at all. It **rebuilds the write
path from the entity's ports** (`cb_we`, `cb_addr`, `cb_data`, gated by `st` and
`rst`), delays it by the declared `CB_WR_LAT`, and requires the real `cb` to
equal it, every copy, every cycle. A path deeper than declared lags the model;
shallower leads it; a wrong address or value disagrees on content. One
assertion, three failure classes.

MEASURED:

```
K2b (a broadcast stage added BELOW the command register -- exactly the shape a
     1,536-copy command path would need):
   before:  surv in all six columns
   after:   AC/AL/AM/NC/NL/NM  KILL(a)      SC/SL/SM  surv
K2c (command registers bypassed, the write lands one cycle EARLY -- the fanout
     fix silently undone):
   before:  surv in all six columns
   after:   AC/AL/AM/NC/NL/NM  KILL(a)      SC/SL/SM  surv
```

The S column is the attribution control and it is the whole reason to trust the
row: with `P_CB_MODEL` demoted to `severity note`, both mutants survive again.
No pre-existing property catches them.

**The control also correctly DENIES credit where it is not due.** K2a, K3a-c,
K5a/b, K7a/b all kill in mode A and also in mode S -- `P_CB_CHK` or a bench's
value oracle already caught them, and the model only agreed. Without the S
column this table would have credited the model with **fifteen** detections
instead of **two**.

### 4.7 The rest of the tree

`REGRESS_SCRATCH=... bash sim/regress.sh --only <pat>`, workstation:

```
--only matvec           OVERALL PASS 12  FAIL 0  BUILD-ERROR 0
  including sim:tb_matvec_fk33_desc      "subsystem A is bit-exact with ref/matvec_int4.c"
            sim:tb_matvec_fk33_desc_dual "..."
            sim:tb_matvec_fk33_desc_xexp "..."
            sim:tb_matvec_fk33           "..."
--only a_geom           OVERALL PASS 1   (A_ROWS_IF = 48, the FK33 shape)
--only weight_streamer  OVERALL PASS 1
--only fk33_seam        OVERALL PASS 1   ("a whole token ran")
--only mv4i_desc_image  OVERALL PASS 1
```

All 16 benches in the tree that instantiate `matvec_core` or `matvec_int4`.

---

## 5. Measured and REJECTED -- do not retry

**1. A `CB_BCAST` broadcast-tree generic, implemented and then removed.**
At `CB_STYLE = "distributed"` and the FK33 geometry the write command reaches
1,536 copies, so `cb_addr`/`cb_data` carry **12,288 flop D-inputs on one net**
-- 32x what the shipping design carries, and the shipping design exists BECAUSE
of a fanout problem. A per-row intermediate rank cuts that to 48 then 32 and it
was written. It was then **reverted**, for two measured reasons:

* It is a synthesis-timing fix and **nothing has been synthesised**. There is no
  lane. Shipping an unmeasured mitigation for an unmeasured problem is the
  pattern this project punishes.
* Restructuring `P_CB` **breaks the anchors of the K1 class** in
  `sim/mutate_matvec_cb.sh`, which is a purpose-built harness whose own header
  says it exists to be run before and after this change. Invalidating it to add
  a speculative knob is a bad trade.

It is named in `rtl/matvec_core.vhd` beside `CB_WR_LAT` so it is not
rediscovered, and adding it is now SAFE in a way it was not this morning:
`P_CB_MODEL` catches a deepening that forgets to move `CB_WR_LAT`.

**2. Re-aiming `P_CB_CHK`'s invariant at "the last stage".** This is the
obvious reading of the K2b hazard note and it is wrong. Any named register is
the last stage only until someone adds another one. The mutation table shows
the difference: an invariant on a register catches K2a (which moves the watched
register) and misses K2b (which moves the write past it). Only a latency-
declared model catches both.

**3. Believing either packing-density model.** Both TRACK TIMING's `k = 0.558`
loss model and this document's 8.00-LUT/CLB geometric model fit the single
measured point exactly, because each has one free parameter and there is one
observation. Do not quote either as a measurement. The bounded range in section
3.3 is what the data supports.

**4. `attribute ram_style` / `dont_touch` from a function of the generic --
NOT rejected, NOT verified, and it is the top open item.** See section 7.

---

## 6. Measurement traps hit, including my own

**1. I nearly reported the density figure without checking its sign.** The
brief, the WORKLOG reopen block and TIMING's section 7a all treat "remove the
MUXF7 and packing improves" as the mechanism. It took working out what a MUXF8
shape physically occupies -- 4 LUT6 in one CLB half, none wasted -- to see that
the mux region is the design's DENSEST and that removing it lowers the average.
The trap is that "MUXF8 locks LUTs into a shape" is true and sounds like a cost,
but the cost is placer freedom, not LUT sites.

**2. The 97.7% / 98.8% figures were carried onto the wrong design by three
documents in a row**, including the one written specifically to record that the
previous closure had judged the wrong design. A figure that travels between
documents loses the sentence that says which build it came from.

**3. Two mutation anchors and one `--neuter` region are attached to text I
changed.** `K8a`, `K8b` and `K9a` anchor on the read-side expression and
reported `ANCHOR FAILED -- tested nothing` on the first full run. That is the
harness working correctly and it would have been easy to read as three rows
that had quietly become survivors. They were retargeted and re-run and give the
same verdicts the harness's own expectations predict.

**4. Extending `--neuter` to a second process needed the expected-assert count
per process, not a global one.** The original hard-errors if `P_CB_CHK` does not
contain exactly 3 asserts. `P_CB_MODEL` was deliberately written with exactly 3
so the pattern generalises, and the count is now a per-name dictionary; a region
that grows or shrinks is still a hard error and never a silent partial neuter.

**5. GHDL trap avoided, recorded for the next reader:** the shadow comparison in
`P_CB_MODEL` must happen BEFORE the model advances. `cb` is a signal and reads
its previous-edge value inside a clocked process; the model's table is a
variable and updates immediately. Comparing after advancing is off by one and
fires on every legal write. This produces a checker that looks like it has
excellent teeth and is in fact broken.

**6. Machine contention was avoided, not survived.** Two Vivados (TRACK TIMING)
were running throughout at load ~4.5 with 23 GB available. Every GHDL run here
was serialised, one bench at a time, and the **full 99-row gate was deliberately
NOT run** -- see the open list.

---

## 7. Open, not yet answered

1. **Whether Vivado infers LUTRAM here at all.** `cb` is an array-of-array-of-
   `signed`. Vivado's own note in this file (`[Synth 8-11357]`, "RAM from
   Record/Structs") records that a nested type does not infer BRAM. Whether it
   infers DISTRIBUTED RAM from this shape is unknown. If it does not, lever C
   produces a register bank with 1,536 copies -- strictly worse than today.
   **This must be the first thing a Vivado lane checks, before any area number.**
2. **Whether Vivado accepts `attribute ram_style of cb : signal is CB_RS`** where
   `CB_RS` is a constant returned by a function of a generic. Legal VHDL; GHDL
   analyses it. Vivado's attribute reader is stricter than the LRM in places. If
   it rejects it, the fallback is two sibling architectures.
3. **Whether adding `ram_style = "registers"` changes today's shipping build.**
   It should be a no-op alongside `dont_touch = "true"`, but it is a NEW
   attribute on the one entity proven bit-exact on silicon. The check is a
   default-generic synth diffed against the recorded baseline, and per TRACK
   SCATTER it needs **repeats**: a single area number is a draw.
4. **The actual CLB saving.** Section 3.3 bounds it at 3,072..8,946. Only a
   place run collapses that. The measurement is `report_utilization` CLB count
   on the composed design with `CB_STYLE` at each value, repeated.
5. **The 12,288-D-input write fanout.** Named, not measured, mitigation not
   built. See section 5 item 1.
6. **SLICEM locality.** 12,288 LUTRAM is only 6.0% of the part's 205,440
   LUT-as-memory sites, so aggregate capacity is not the issue. But only ~46.7%
   of CLB columns are SLICEM, and the copies want to sit inside subsystem A's
   existing cluster. Whether that fragments the row clusters the adder tree
   depends on is a placement question no simulation answers.
7. **Whether removing mux shapes helps ROUTING even where it does not help
   density.** 20,000 of the 20,000 worst composed endpoints are net-dominated
   (mean net 4.575 ns vs mean logic 0.670 ns), and F7/F8 indivisibility
   constrains placement legality. This is the one argument for lever C that this
   document neither supports nor refutes. It is also roughly halved by
   correction 1: lever C removes 37.7% of MUXF7, not 97.7%.
8. **The full 99-row gate was not run.** 16 benches were, covering everything
   that instantiates `matvec_core` or `matvec_int4`. The remainder was skipped
   because the box hung under concurrent load last night
   (`docs/debugging/2026-08-30_the-box-hung-under-my-own-dispatch.md`) and TRACK
   TIMING holds both Vivado lanes. **`BASELINE_PASS` is 99 and has not been
   re-established at this commit.**
9. **Whether `d_norm` should be in the composition at all**, which TIMING's own
   section 10 item 4 raises. It carries 34% of the composed MUXF7 for read
   muxes that section 7a costs at 14.4 URAM288. Not my scope; recorded because
   the census in section 3.1 is the evidence for it.
