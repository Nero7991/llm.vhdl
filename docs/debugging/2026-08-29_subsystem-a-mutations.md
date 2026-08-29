# Subsystem A has zero mutation scripts while being the only subsystem on silicon

**Date:** 2026-08-29
**Track:** A-MUT
**Tooling:** GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6), mcode backend; `cc -O2`; no hardware
**Files added:** `sim/mutate_matvec_core.sh`, `sim/mutate_weight_streamer.sh`
**Files changed:** `sim/tb_matvec_core.vhd` (two strengthenings, both derived
from a measured survivor)

---

## 1. The question, verbatim

> **Subsystem A has ZERO mutation scripts, while being the only subsystem on
> silicon.**
>
> Count it yourself: `ls sim/mutate_*.sh`. Subsystem B has thirty. Subsystem A
> has none. And A is: the only arithmetic that has ever been put into an FK33
> bitstream (`hw/fk33/rtl/fk33_engine.vhd`), 67.98% of the design's LUT and
> 99.94% of its DSP, and 69 to 88% of the cells in every congested window of
> the build that will not route, and the subsystem every other track's oracle
> leans on, because `ref/matvec_int4.c` is treated as trusted throughout the
> tree.

MEASURED at the start of this track: `ls sim/mutate_*.sh | wc -l` = **31**, of
which **0** name any subsystem-A unit.

---

## 2. The answer, up front

**`sim/tb_matvec_core.vhd`'s CHECKER is strong. Its STIMULUS is the limit, and
the limit is one committed file.**

MEASURED over 57 mutations of `rtl/matvec_core.vhd` and
`rtl/mv4i_arith_pkg.vhd`, each run against three traces:

| trace | what it is | kills |
|---|---|---|
| **A** | `sim/tr.txt`, the file `sim/regress.sh:778` actually gates on (M=8, K=96, SATEV 0) | **36 of 57** |
| **P** | `--trace t 6 100 4 0`: M not a multiple of ROWS_IF, K not a multiple of BLK | **40 of 57** |
| **S** | `--trace t 8 1024 4 1`: the reference's own adversarial saturating mode | **30 of 57** |
| union | all three | **44 of 57** (36 KILLED + 8 ABORT), 13 survivors |

Three findings follow, in descending order of consequence.

**(a) Eight mutations are invisible to the committed gate.** Four need a
ragged shape (`D1`, `D2`, `D18`, `B13`) and four need saturation (`D16`,
`B10`, `R3`, `A5`). `sim/tr.txt` has K = 96 = 3x32 exactly, M = 8 = 2x4
exactly, and `SATEV 0`, so **spec 6.2's column mask, the `nb_r` ceiling, the
BFP emit mask and every saturation rail are unexercised by the gate as it
stands.** `D16` is "sat32 at row end is removed"; that is the clamp that keeps
a 48-bit accumulator inside an int32 output, and today's gate does not test it.

**(b) The adversarial trace is the WEAKEST of the three, not the strongest.**
It kills 30 where the plain one kills 36, and ten mutations the plain trace
kills survive it outright. Its construction sets every weight to codebook
index 0, every scale to 32767 and every activation to -32768, so **every
product in the array is the same number.** A structural datapath error is
then invisible by symmetry: `D5` drops the odd operand of an adder-tree node,
and `2*p` equals `p+p`. Saturation coverage and value diversity are opposed
here, and one trace cannot supply both.

**(c) Two survivors were stimulus gaps that could be closed inside the bench,
and both were closed.** `B13` (the emit `y_mask` admits one pad row) and `I1`
(the BFP row bound is deleted from the S_IDLE check) both survived all three
traces. Neither is an equivalent mutant; both are now killed. `I1` is the more
serious of the two: with the bound gone, a legal-looking BFP descriptor walks
`ybuf` off its end, and MEASURED it now aborts with
`index (16) out of bounds (0 to 15)`.

**No defect was found in `rtl/matvec_core.vhd` or `rtl/weight_streamer.vhd`.**
Both are in better shape than the surrounding stimulus. The RTL was not edited.

For `rtl/weight_streamer.vhd`, judged by `sim/tb_weight_streamer.vhd`:
**19 of 21 killed** (14 KILLED + 5 ABORT), the 2 survivors being guard
REMOVALS whose asserts were then separately proved live.

---

## 3. The procedure, in the order it was run

Each step is listed with what it controls for. This is the reusable part.

1. **Read the bench before mutating anything.** `sim/tb_matvec_core.vhd` is a
   stage-level value oracle: every expected intermediate comes from
   `ref/matvec_int4 --trace`, and it ends in `assert nbad = 0 and ybad = 0` at
   severity failure. Controls for the commonest false start, which is building
   a mutation table against a checker that turns out to have no gate.

2. **Decode the committed stimulus, not the bench.** `head -2 sim/tr.txt` gives
   `DIMS 8 96 3 3 2 5 4`, and `grep SATEV` gives 0. This is the step that
   produced the whole result: the shape numbers, not the checker, are what
   bound the gate.

3. **Prove the oracle reproduces the committed fixture byte for byte.**
   `cc -O2 -w -I ref -o mv4i ref/matvec_int4.c && ./mv4i --trace t 8 96 4 0 &&
   cmp t sim/tr.txt`. Controls for the possibility that the "A" column is a
   statement about some other file. The harness re-runs this check on every
   invocation and **refuses to run if it fails**.

4. **Generate alternate traces and run the HONEST RTL against each first.**
   Controls for scoring a bench limitation as an RTL kill. This immediately
   caught one (see trap 6.1): a 64x1024 trace makes the correct core report
   `STAGE MISMATCH PARTIAL r=61`, because the bench's shape-override passes
   score rows at and above the trace's M against zero and therefore require
   `M <= MAXR - RI`.

5. **Mutate, three traces per mutant, three verdicts.** KILLED / SURVIVED /
   **ABORT**, ABORT counted as a kill but reported separately and worth less:
   it is the language noticing, not the checker, and the same mutation in
   hardware would silently read a neighbouring array entry.

6. **Tag every mutation with the branch that elaborates it.** `matvec_core`'s
   `out_mode` branches are mutually exclusive; `weight_streamer`'s two
   geometries select different generate depths. An untagged table would read
   as a poor result where the real statement is per-branch.

7. **Explain every survivor by name, then act only where the explanation is a
   stimulus gap.** Three classes came out: true equivalent mutants (`D4`,
   `B2`), documented timing-only fixes (`B8`, `B9`), and genuine stimulus gaps
   (`B13`, `I1`). Only the third class justified touching the bench.

8. **Teeth-check the guards.** A guard REMOVAL that survives on a conforming
   configuration says nothing at all. `G5` and `G6` invert the same two
   `weight_streamer` asserts so the correct geometry violates them; both fire.
   Without that pair, `G1` and `G3`'s survival would have been unreadable.

9. **Re-run the whole sweep after every bench change**, and re-run the honest
   RTL against all three traces first. Controls for a strengthening that kills
   mutants by breaking the bench.

---

## 4. The evidence

### 4.1 The oracle self-test, and the three traces (MEASURED, every run)

```
=== building ref/matvec_int4.c (READ ONLY -- compiled from a copy) ===
trace A byte-identical to sim/tr.txt  (MEASURED, this run)
trace A  DIMS 8 96 3 3 2 5 4  SATEV 0
trace P  DIMS 6 100 4 3 2 5 4  SATEV 0
trace S  DIMS 8 1024 32 0 0 0 4  SATEV 1
```

`DIMS` is `M K NB out_shift w_exp x_exp ROWS_IF`.

Note trace S needed **K = 1024**, not the reference's default. MEASURED:
`--trace t 8 96 4 1` still yields `SATEV 0` because NB = 3 cannot reach 2^31;
only NB > 16 does. The adversarial mode exists in `ref/matvec_int4.c`
specifically so `sat_event` is compared against something other than zero --
its own comment says *"Without it the flag was wired through three testbenches
and never once compared, which is how the RTL came to assert it in PARTIAL
mode ... undetected"* -- and the gate does not use it.

### 4.2 `sim/mutate_matvec_core.sh`, final run (MEASURED)

```
---- class ALL: the shared datapath.  Every pass reaches these --------
D1    ALL    KILLED    A:surv  P:KILL  S:surv   -- the spec 6.2 COLUMN MASK is removed
D2    ALL    KILLED    A:surv  P:KILL  S:surv   -- the column mask is off by one at the top (k <= n_cols)
D3    ALL    ABORT     A:ABRT  P:ABRT  S:ABRT   -- the product resize truncates one bit (28 -> 23)
D4    ALL    SURVIVED  A:surv  P:surv  S:surv   -- adder-tree level 1's two operands are swapped (commutative)
D5    ALL    KILLED    A:KILL  P:KILL  S:surv   -- adder-tree level 1 drops its odd operand (a half-sum)
D6    ALL    KILLED    A:KILL  P:KILL  S:KILL   -- the fabric levels read tr instead of trn
D7    ALL    KILLED    A:KILL  P:KILL  S:KILL   -- the scale multiply reads the wrong tree root
D8    ALL    KILLED    A:KILL  P:KILL  S:KILL   -- the scale is read one pipeline stage early
D9    ALL    ABORT     A:ABRT  P:ABRT  S:ABRT   -- the uint15 scale is taken as SIGNED
D10   ALL    KILLED    A:KILL  P:KILL  S:KILL   -- SITE 1's shift is 14, not 15
D11   ALL    KILLED    A:KILL  P:KILL  S:surv   -- SITE 1 rounds instead of flooring
D12   ALL    KILLED    A:KILL  P:KILL  S:KILL   -- the accumulator never restarts on the tag first bit
D13   ALL    KILLED    A:KILL  P:KILL  S:KILL   -- row end fires on the FIRST block of a tile
D14   ALL    KILLED    A:KILL  P:KILL  S:surv   -- row end stage 2 FLOORS instead of rounding
D15   ALL    KILLED    A:KILL  P:KILL  S:KILL   -- row end stage 2 shifts by os_rep + 1
D16   ALL    KILLED    A:surv  P:surv  S:KILL   -- sat32 at row end is removed
D17   ALL    KILLED    A:KILL  P:KILL  S:surv   -- the activation prefetch wraps one block late
D18   ALL    KILLED    A:surv  P:KILL  S:surv   -- nb_r truncates instead of ceiling
D19   ALL    KILLED    A:KILL  P:KILL  S:KILL   -- the last tile is detected one tile early
D20   ALL    ABORT     A:ABRT  P:ABRT  S:ABRT   -- accept no longer requires a prefetched activation

---- class BFP: out_mode = "00" only (PASS 1 and PASS 3 ONLY) ---------
B1    BFP    KILLED    A:KILL  P:KILL  S:KILL   -- ns is one too small
B2    BFP    SURVIVED  A:surv  P:surv  S:surv   -- the ns threshold is >= 14 rather than > 14
B3    BFP    SURVIVED  A:surv  P:surv  S:surv   -- the amax scan domain loses its PAD MASK
B4    BFP    KILLED    A:KILL  P:KILL  S:surv   -- the amax fold takes the MINIMUM of each pair
B5    BFP    KILLED    A:KILL  P:KILL  S:KILL   -- amax keeps the LAST magnitude, not the running max
B6    BFP    SURVIVED  A:surv  P:surv  S:surv   -- the fold stages are dropped from inflight
B7    BFP    KILLED    A:KILL  P:KILL  S:surv   -- the emit shift is floor, not round (SITE 4)
B8    BFP    SURVIVED  A:surv  P:surv  S:surv   -- the emit shift reads the MASTER ns_r
B9    ALL    SURVIVED  A:surv  P:surv  S:surv   -- the row-end shift reads the LIVE out_shift port
B10   BFP    KILLED    A:surv  P:surv  S:KILL   -- sat16 on the emitted mantissa is removed
B11   BFP    ABORT     A:ABRT  P:ABRT  S:ABRT   -- the emit pointer runs one tile too far
B12   BFP    ABORT     A:ABRT  P:ABRT  S:ABRT   -- S_EMIT never terminates (hung: reached --stop-time)
B13   BFP    KILLED    A:surv  P:KILL  S:surv   -- the emit y_mask admits one pad row
B14   BFP    ABORT     A:ABRT  P:ABRT  S:ABRT   -- OI-8 reintroduced: ybuf_addr no longer clamps

---- class RAW / PART: the no-buffer modes ----------------------------
R1    RAW    ABORT     A:ABRT  P:ABRT  S:ABRT   -- OI-10 reintroduced: ybuf written in RAW mode too
R2    PART   KILLED    A:KILL  P:KILL  S:KILL   -- PARTIAL emits the ROUNDED, SATURATED value
R3    PART   KILLED    A:surv  P:surv  S:KILL   -- the sat_event sticky no longer excludes PARTIAL
R4    NOTBFP KILLED    A:KILL  P:KILL  S:KILL   -- the no-buffer modes never raise y_we
R5    NOTBFP KILLED    A:KILL  P:KILL  S:KILL   -- the row-end y_mask admits one pad row
R6    ALL    KILLED    A:KILL  P:KILL  S:KILL   -- y_exp for BFP forgets the ns term
R7    PART   KILLED    A:KILL  P:KILL  S:surv   -- y_exp for PARTIAL carries an out_shift term
R8    RAW    KILLED    A:KILL  P:KILL  S:KILL   -- y_exp for RAW carries an ns term

---- class IDLE: the spec 7.6 descriptor check ------------------------
I1    IDLE   ABORT     A:ABRT  P:ABRT  S:ABRT   -- the BFP row bound is dropped
I2    IDLE   KILLED    A:KILL  P:KILL  S:KILL   -- the row bound applies to EVERY mode
I3    IDLE   SURVIVED  A:surv  P:surv  S:surv   -- the out_shift bound is off by one (> 41)
I4    IDLE   KILLED    A:KILL  P:KILL  S:KILL   -- os_r latches out_shift + 1
I5    IDLE   SURVIVED  A:surv  P:surv  S:surv   -- amax is not cleared between operations

---- class CB: the codebook write path --------------------------------
C1    CB     KILLED    A:KILL  P:KILL  S:KILL   -- per-copy delay: replica 1 lags replica 0
C2    CB     SURVIVED  A:surv  P:surv  S:surv   -- codebook writes are accepted outside idle
C3    CB     SURVIVED  A:surv  P:surv  S:surv   -- the S_IDLE cb_we interlock is deleted
C4    CB     SURVIVED  A:surv  P:surv  S:surv   -- every row reads codebook replica 0

---- class ARITH: rtl/mv4i_arith_pkg.vhd ------------------------------
A1    ALL    KILLED    A:KILL  P:KILL  S:surv   -- round_shift loses its round-half-up bias
A2    ALL    KILLED    A:KILL  P:KILL  S:surv   -- round_shift rounds half toward -infinity
A3    ALL    KILLED    A:KILL  P:KILL  S:surv   -- floor_shr rounds toward zero
A4    ALL    SURVIVED  A:surv  P:surv  S:surv   -- sat32's negative rail is one high
A5    BFP    KILLED    A:surv  P:surv  S:KILL   -- sat16's positive rail is one low
A6    BFP    SURVIVED  A:surv  P:surv  S:surv   -- msb_pos_u(0) returns 1, not 0

kill ratio: 36 KILLED + 8 ABORT = 44 of 57;  13 SURVIVED
survivors: D4 B2 B3 B6 B8 B9 I3 I5 C2 C3 C4 A4 A6
```

Per-trace, DERIVED from the table above by counting `KILL` and `ABRT`:

```
  trace A alone kills: 36 of 57      <- what sim/regress.sh sees today
  trace P alone kills: 40 of 57
  trace S alone kills: 30 of 57
killed by P but NOT by the committed gate trace A: D1 D2 D18 B13
killed by S but NOT by the committed gate trace A: D16 B10 R3 A5
killed by A but SURVIVING the adversarial trace S: D5 D11 D14 D17 B4 B7 R7 A1 A2 A3
```

### 4.3 Every survivor, under its own name and with its reason

Survivors are the most valuable rows: they measure the resolution floor.
None is discarded.

| tag | class | why it survives | closable? |
|---|---|---|---|
| `D4` | **true equivalent** | integer addition is commutative; swapping an adder node's operands cannot change any value. Present deliberately: a table in which every mutation dies is a table whose oracle is suspect. | never |
| `B2` | **true equivalent** | `>= 14` vs `> 14` differ only at `msb_pos_u(amax) = 14`, where both arms assign `ns = 0` (`14 - 14 = 0`). No stimulus can separate them. | never |
| `B8` | **timing-only, documented in the RTL** | `ns_rep` is the per-lane fanout fix. `ns_r` is constant for the whole of S_EMIT and the replica is one cycle behind, so master and replica agree wherever either is read. `rtl/matvec_core.vhd` says so at the declaration: *"To attribute the two fixes separately, put ns_r back HERE and nowhere else."* A functional bench does not measure timing. | never (needs STA) |
| `B9` | **timing-only + unreachable stimulus** | `os_rep` latches `out_shift` once. It buys protection against a caller that MOVES `out_shift` mid-operation. This bench drives `out_shift` from the trace's DIMS and holds it, so the defect class is not generated. | needs a hostile-caller bench |
| `C4` | **true equivalent under this config** | `CB_ROWS_PER_COPY = 1` at every geometry the benches use, so `rr / 1 = rr` and every replica holds the same table. What makes the replicas correct is `P_CB_CHK`, not the select. | only at `CB_ROWS_PER_COPY > 1` |
| `A6` | **unreachable value** | `msb_pos_u(0) = 0` is normative, but `amax = 0` requires every emitted magnitude to be zero, which no trace produces. | needs an all-zero-weight trace |
| `A4` | **unreachable sign** | sat32's NEGATIVE rail. In trace S every weight is codebook index 0 = -127 and every activation is -32768, so every product is POSITIVE and the accumulator only ever clamps at `+2^31-1`. **No trace produces a negative saturation.** | yes: needs an adversarial trace of the opposite sign |
| `B3` | **guard against a non-conforming file** | Pad rows fold into `amax` only if they carry a nonzero magnitude. MEASURED at `ref/matvec_int4.c:482`, the packer is `calloc(1, len)` with the comment `/* PAD FILL = 0x00 */`, so pad-row scales are ZERO in any conforming packed file; contrib is 0, magnitude is 0, and the mask is redundant. Same shape as the `min(0,g)` guard in `gdn_scalar` R7. | only with a deliberately non-conforming stimulus, which is a different contract |
| `B6` | **stimulus gap, precisely characterised** | Dropping the fold stages from `inflight` loses the LAST tile's magnitudes. That changes `amax` only if the maximum is strictly in the last tile. MEASURED over the YDATA lines of all three traces (see 4.4): trace A's max is at row 2 (tile 0), trace P's at row 3 (tile 0), and trace S ties every row so tile 0 has already set the running maximum. | yes: needs a trace with a strictly monotone magnitude profile. Blocked here -- it needs a new generator mode in `ref/`, which TRACK RY-ORACLE owns. |
| `I3` | **stimulus gap** | `out_shift > 41` vs `> 40`. The traces drive `out_shift` = 3 or 0; nothing goes near 40. | yes: needs a descriptor-rejection pass sweeping `out_shift` |
| `I5` | **equivalent on this pass sequence** | `amax` is not cleared between operations. PASS 3 is BFP at n_rows = 64 with rows 8..63 all zero, so its maximum equals PASS 1's maximum over 8 rows and the stale value is the correct value. | yes: needs two BFP passes whose maxima differ, the later one smaller |
| `C2` | **stimulus gap** | `P_CB_CHK` asserts `not (cbw_v(0) = '1' and st /= S_IDLE)`, which has real teeth -- but this bench writes the whole codebook during the trace load, before the first `start`, so `cb_we` is never asserted outside idle and the mutated branch is never taken. | yes: needs a bench that writes the codebook mid-operation. `sim/tb_matvec_cb_lockstep.vhd` is the natural home |
| `C3` | **stimulus gap, same root as C2** | The empty `cb_we` arm is an interlock against `start` on the same edge as the last `cb_we`. The bench leaves many cycles between the two. | yes, same bench as C2 |

### 4.4 The `B6` measurement, in full

DERIVED from the `YDATA` lines of each trace, which are the reference's own
per-row pre-normalisation values:

```
trace A: M=8 tiles=2  amax=1283277 at rows [2]   last tile = tile 1 rows [4,5,6,7], its max 619760    MAX IN LAST TILE: False
trace P: M=6 tiles=2  amax=2145596 at rows [3]   last tile = tile 1 rows [4,5],     its max 197535    MAX IN LAST TILE: False
trace S: M=8 tiles=2  amax=2147483647 at rows [0..7]  last tile max 2147483647      MAX IN LAST TILE: True (but tied, so tile 0 already set it)
```

`amax` is a RUNNING maximum, so "tied" is the same as "not in the last tile"
for this purpose. The mutation is real and the RTL comment describing it
(*"the last rows' magnitudes would never reach amax ... a silently wrong
exponent on some shapes, not a crash"*) is correct; it is the stimulus that
cannot demonstrate it.

### 4.5 The two bench strengthenings, with the mutation that motivated each

Both are in `sim/tb_matvec_core.vhd`. Both leave the honest RTL passing on all
three traces (MEASURED before and after), and neither changes any expected
value, so `BASELINE_PASS` is untouched.

**(i) `xmem` is POISONED, not zeroed.** The trace emits an `X k <value>` line
only for `k < K`, so with the old `(others => '0')` default every pad column
carried a ZERO ACTIVATION -- and spec 6.2's column mask is multiplying
`cb(0) = -127` by that activation. Zero made the mask a no-op. It was also the
wrong model of the hardware: `x` comes from `act_mem_striped`, a plain RAM
nothing clears between operations, so the tail of the last block holds
whatever the previous layer left.

```
BEFORE: D1 SURVIVED  A:surv P:surv S:surv     -- the spec 6.2 COLUMN MASK is removed
        D2 SURVIVED  A:surv P:surv S:surv     -- the column mask is off by one
AFTER:  D1 KILLED    A:surv P:KILL S:surv     ("RTL DIVERGES FROM THE C REFERENCE")
        D2 KILLED    A:surv P:KILL S:surv
```

The `A:surv` is not a residual failure: trace A's K = 96 is an exact multiple
of BLK, so it has **no pad column to mask**. That column is a statement about
the committed gate, not about the fix.

**(ii) A port-level coverage assert in PASS 1, and a new PASS 9.**

`B13` corrupts the emit `y_mask` so one pad row leaves the port masked-in.
It survived because `nmant` counts the `tm_val` STAGE TAP, which is not gated
by `y_mask`, and because the extra row carries zero and therefore compares
equal to the zero expectation. The `nemit` coverage assert that would have
caught it ran only in the RAW and PARTIAL passes, and PASS 3 could not catch
it either -- `n_rows = MAXR = 64` is tile-aligned at RI = 4, so `rbase + rr`
never reaches `n_rows`. It takes a RAGGED BFP tile.

`I1` deletes the BFP row bound from the S_IDLE check. Every pass in the file
asserted that `err` stays LOW, so **nothing asserted that it ever goes HIGH**:
the guard on a buffer overrun was itself unguarded. PASS 8 does not cover it,
because 7.6 makes that same row count LEGAL in raw.

```
BEFORE: B13 SURVIVED A:surv P:surv S:surv
        I1  SURVIVED A:surv P:surv S:surv
AFTER:  B13 KILLED   A:surv P:KILL S:surv   "COVERAGE: y_mask admitted 7 rows out of the PORT, expected 6"
        I1  ABORT    A:ABRT P:ABRT S:ABRT   "index (16) out of bounds (0 to 15)"
```

`I1`'s abort is the point: with the bound gone, PASS 9 runs the job and `ybuf`
is indexed one tile past its end. That is the same buffer and the same family
as worklog OI-8 and OI-10.

### 4.6 `sim/mutate_weight_streamer.sh` (MEASURED)

```
M1    both   KILLED   FK33+AXU  FK33 15 wrong, AXU 15 wrong   -- weight sub-region p placed at slice NPORTS_W-1-p
M2    both   KILLED   FK33+AXU  FK33 15 wrong, AXU 15 wrong   -- the weight merge takes data from the SCALE ports
M3    both   KILLED   FK33+AXU  FK33 15 wrong, AXU 15 wrong   -- the all-valid POP GATE is dropped
M4    both   KILLED   FK33+AXU  FK33 15 wrong, AXU 15 wrong   -- the pop gate ORs the port valids
M5    both   KILLED   FK33+AXU  FK33 15 wrong, AXU 14 wrong   -- w_valid asserted whenever ANY beat is present
M6    both   KILLED   AXU       WEIGHT word 2 (then hung)     -- FIFOs popped without waiting for w_ready
S1    FK33   KILLED   FK33      FK33 15 wrong, AXU 0 wrong    -- superword slices assembled in reverse order
S2    FK33   KILLED   FK33      FK33 15 wrong, AXU 0 wrong    -- every superword slice filled from sub-region 0
S3    FK33   KILLED   FK33      FK33 15 wrong, AXU 0 wrong    -- scale ports popped INDEPENDENTLY
S4    AXU    KILLED   AXU       FK33 0 wrong, AXU 14 wrong    -- the chunk pointer never advances
S5    AXU    KILLED   AXU       FK33 0 wrong, AXU 15 wrong    -- s_data reads the chunk ABOVE the pointer
S6    AXU    KILLED   AXU       SCALE group 1 (then hung)     -- superword refilled after every chunk
S7    both   KILLED   AXU       SCALE group 1 (then hung)     -- s_take ignores s_ready
S8    both   KILLED   FK33+AXU  FK33 15 wrong, AXU 15 wrong   -- s_valid tied high
S9    both   ABORT    -         hung: reached --stop-time     -- chunk pointer not reset on a new superword
G1    GUARD  SURVIVED both      0 reassembly errors           -- the 6.5 invariant is no longer asserted
G2    GUARD  ABORT    elab      NPORTS_S is not the minimal n -- nss_min returns one too many
G3    GUARD  SURVIVED both      0 reassembly errors           -- the 4 KB burst guard admits 8 KB
G4    GUARD  ABORT    elab      6.5a superword ...            -- divisibility guard inverted
G5    GUARD  ABORT    elab      6.5 invariant ...             -- TEETH-CHECK for G1
G6    GUARD  ABORT    elab      MAXB*AXI_DW/8 exceeds 4096    -- TEETH-CHECK for G3

kill ratio: 14 KILLED + 5 ABORT = 19 of 21;  2 SURVIVED (G1, G3)
```

**The branch column is load-bearing here, not decoration.** `S1..S3` mutate a
`for q in 0 to NPORTS_S-1` loop that has ONE iteration at the AXU3EG geometry,
so `AXU 0 wrong` is not a miss: no stimulus at that geometry can reach them.
`S4..S6` mutate the `GRP` chunk pointer, which is 1-deep at the FK33 geometry,
so `FK33 0 wrong` is the same statement mirrored. Reported as a flat table,
these six would look like six half-results; they are six full results on the
only branch that elaborates them.

**`G1` and `G3` survive because they REMOVE a guard, and a removed guard
cannot change a design that does not violate it.** That is the expected result
and, alone, says nothing. `G5` and `G6` INVERT the same two conditions so the
correct geometry violates them, and both abort at elaboration -- so both
asserts are live, reachable, and correctly wired to the generics.

---

## 5. Measured and REJECTED -- do not retry

- **Do NOT use a trace with `M > MAXR - RI` (i.e. M > 60 at the bench's
  MAXR=64, RI=4).** MEASURED with `--trace t 64 1024 4 0`: the HONEST,
  unmutated core reports `STAGE MISMATCH PARTIAL r=61 got 4465320 want
  2033446`, and 60-odd more. This is the BENCH, not the RTL: its
  shape-override passes score rows at and above the trace's M against ZERO,
  and PASS 5 drives `n_rows = MAXR - RI + 1 = 61`, so with M = 64 the rows the
  bench calls pad are rows the trace filled with real data. Nearly logged as a
  defect in `matvec_core`.

- **Do NOT expect `--trace out M K RI 1` to exercise saturation at the default
  K.** MEASURED: `8 96 4 1` yields `SATEV 0`. The construction needs NB > 16 to
  reach 2^31; `8 1024 4 1` yields `SATEV 1`. The reference's own comment says
  each block contributes ~1.33e8, so 16 blocks reach 2.13e9, just under the
  s32 limit.

- **Do NOT treat the adversarial trace as strictly stronger.** MEASURED: it
  kills 30 of 57 against the plain trace's 36, and TEN mutations the plain
  trace kills survive it (`D5 D11 D14 D17 B4 B7 R7 A1 A2 A3`). Every product in
  the array is the same number there, so a rounding-mode change is invisible
  (all values are already at the rail) and a structural adder-tree change is
  invisible by symmetry (`2*p = p+p`). It is a saturation probe, not a
  datapath probe, and it must be run ALONGSIDE a diverse trace, never instead
  of one.

- **Do NOT set `--stop-time=200ms` on this bench.** MEASURED: two mutations
  (`B11`, `B12`) hang, and at 200 ms simulated each burned the 600 s wall-clock
  timeout, three traces each -- 30 minutes for one row. The honest runs finish
  at 4.905 us (A), 5.785 us (P) and 30.425 us (S), so `--stop-time=2ms` is 65x
  margin and catches a hang in seconds. Same for `tb_weight_streamer`: honest
  run 535 ns, `--stop-time=100us`.

- **Do NOT parse the ghdl epilogue before the bench's own diagnostics.**
  See trap 6.2. Scoring a caught mutation as an ABORT is the same class of
  error as scoring a dead run as a survivor, one square over.

- **`ghdl -e` is not a build step here** (mcode backend); `ghdl -r` directly.
  Not re-learned this session, but the harnesses are written that way.

---

## 6. Measurement traps hit, including my own

### 6.1 A bench limitation misread as an RTL kill (caught before it was written down)

The first alternate trace was `64 1024 4 0`, chosen to get NB = 32 and a full
row range at once. The honest core "failed" it. Ten minutes went into reading
`matvec_core`'s pad handling before the log was read properly: the mismatches
start at `r=61`, which is exactly `MAXR - RI + 1`, the row count PASS 5 drives.
**A failure whose row index equals a constant from the bench is a bench
problem.** Fixed by splitting the intent in two: trace P for raggedness at
M = 6, trace S for saturation at K = 1024.

### 6.2 My own harness scored real kills as ABORT (one wasted full run)

The first verdict parser tested for `ghdl:error:` before testing for the
bench's own `(assertion failure)` line. A severity-failure assert STOPS the
simulation, so `done` is absent, the TOTAL line is absent, and ghdl prints its
own epilogue -- which the parser reached first. MEASURED on `D5`, whose log
contains all three of:

```
BFP: 64 stage values compared, 64 mismatches
(assertion failure): RTL DIVERGES FROM THE C REFERENCE
ghdl-mcode:error: assertion failed
```

and which was reported `ABORT`. It is the mirror of the trap three tracks hit
on 2026-08-28 (scoring a dead run as a survivor): here a run the CHECKER caught
was scored as the language catching it, which understates the bench. The fix is
ordering, and the ordering is now commented in the script as the reason.

Also note ghdl writes `(assertion failure)` for a bare `assert` and
`(report failure)` for `report ... severity failure`; matching only one of the
two forms silently misses half the bench's diagnostics.

### 6.3 Backticks in a bash description string are command substitution

Three mutation descriptions contained `` `first` ``, `` `accept` ``,
`` `inflight` `` for emphasis. bash executed them: the run printed
`line 441: first: command not found` and the word vanished from the table. The
mutation results were unaffected, but a table row silently lost a word. No
backticks in harness strings.

### 6.4 Editing a running harness -- the self-isolation earned its keep

Both harnesses copy themselves to a private temp path, `bash -n` the copy in
case the original was mid-write, and re-exec that, exactly as
`sim/regress.sh:287` does. This was not theoretical: the backtick fix in 6.3
and the `--stop-time` retune were both applied to `sim/mutate_matvec_core.sh`
**while an instance was running**, with no effect on the running copy.

### 6.5 A "who killed it" column that reads `?`

`tb_weight_streamer`'s per-instance summary line never prints when the checker
loop cannot complete, which is the normal shape for a mutation that DROPS
words (`while nw < NWORD or ns < NWORD` never terminates, then `--stop-time`
fires). The first version reported `?` for the geometry on `M6`, `S6`, `S7`.
Fixed by taking the geometry from the diagnostic itself and appending
`(then hung)`. Worth stating because the naive fix -- reading the hang first --
would have downgraded three caught mutations to ABORT, i.e. trap 6.2 again.

### 6.6 `lastvalid` is dead code (noted, not a defect)

`rtl/matvec_core.vhd:256` declares `lastvalid` and `:958` assigns it. **Nothing
reads it.** It computes `n_cols - ((n_cols - 1) / BLK) * BLK`, the number of
valid columns in the last block, which reads like the column-mask bound -- but
the real mask is `k < n_cols` at `:699` and does not use it. Synthesis prunes
it, so this is not a defect; it is a signal whose name invites a future editor
to believe the mask goes through it. Left alone: this track does not own
`rtl/`.

---

## 7. What is NOT verified

Stated explicitly so the next track does not have to infer it.

**Subsystem A units with NO mutation coverage after this work:**

| unit | dedicated bench | mutation script |
|---|---|---|
| `rtl/matvec_core.vhd` | `sim/tb_matvec_core.vhd` | **YES, this track** |
| `rtl/weight_streamer.vhd` | `sim/tb_weight_streamer.vhd` | **YES, this track** |
| `rtl/mv4i_arith_pkg.vhd` | `sim/tb_mv4i_arith` + vectors | partial: 6 mutations, judged only through `tb_matvec_core` |
| `rtl/matvec_int4.vhd` | `sim/tb_matvec_int4.vhd` | **NO** |
| `rtl/matvec_int4_desc_axi.vhd` | `sim/tb_matvec_fk33_desc.vhd` | **NO** (1012 lines, the descriptor decode, and it has a mutation-refusal bench that is not a mutation SCRIPT) |
| `rtl/axi_rd_port.vhd` | `sim/tb_axi_rd_port.vhd` | **NO** |
| `rtl/axi_rd_fsm.vhd` | **none** | **NO** -- only reached through `axi_rd_port` |
| `rtl/async_fifo.vhd` | **none** | **NO** -- the CDC, only reached through `axi_rd_port`; a CDC with no direct bench is the highest-risk item on this list |

**Not verified by this track, beyond the above:**

- **Anything about timing.** `B8` and `B9` are the fanout and latching fixes
  and are unkillable by any functional bench. They need STA, not simulation.
- **The negative saturation rail** (`A4`). No trace reaches it.
- **`msb_pos_u(0)`** (`A6`). No trace produces `amax = 0`.
- **The `inflight` fold-drain margin** (`B6`). Characterised exactly (4.4) but
  not demonstrated; needs a trace whose maximum magnitude is strictly in the
  last tile.
- **Codebook writes outside idle** (`C2`, `C3`). `P_CB_CHK` has the teeth;
  no bench in the closure generates the stimulus.
- **`out_shift` near its 40 bound** (`I3`).
- **`amax` staleness across operations with DECREASING maxima** (`I5`).
- **The pad-row scale mask** (`B3`) against a non-conforming packed file.
- **`CB_ROWS_PER_COPY > 1`** (`C4`). Every bench uses the default of 1.
- **Any hardware behaviour.** No hardware was touched, per the standing
  boundary.
- **Whether `sim/regress.sh` should gate on trace P or S.** The harness proves
  they would each catch four mutations the committed trace cannot. Adding a
  second `tb_matvec_core` row is a gate-cost decision, not a correctness one,
  and is left for the dispatcher rather than taken unilaterally.

---

## 8. Corrections

None yet. Append here rather than editing above.
