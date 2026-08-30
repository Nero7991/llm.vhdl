# Subsystem A's 23 surviving mutations, worked one at a time

**Date:** 2026-08-29
**Track:** ASURV, following TRACK ACOV (`b39c389`, `337b5fd`, `578c546`, `164024e`, `298217d`)
**Baseline:** `298217d`
**Tools:** GHDL 1.0.0 mcode, `sim/regress.sh`, `cc` for `ref/matvec_int4.c`.
No hardware. No Vivado. Nothing under `hw/fk33/`.

---

## 1. The question, verbatim

> TRACK ACOV built subsystem A's two missing mutation scripts. **It left 23
> surviving mutations, and subsystem A is the ONE part of this design proven on
> silicon tonight.** A survivor is a defect the checking cannot see in the part
> that is actually running.
>
> * `sim/mutate_axi_rd_port.sh`: 22 mutations, **11 caught, 11 SURVIVED**, 0 VOID.
> * `sim/mutate_matvec_int4.sh`: 26 mutations, **14 caught, 12 SURVIVED**, 0 VOID.
>
> **Your job is to work the survivors, one at a time, and for EACH produce one
> of three outcomes:** a stimulus that kills it, with the attribution control
> showing which detector fired; a proof it is an equivalent mutant; or a named,
> recorded reason it is unreachable.
>
> **Do NOT chase the count.**
>
> Also yours: board row N7. **`EC_CORE` (0xE) is reachable by no bench in the
> tree.** If that stimulus cannot be produced without editing `rtl/`, say so and
> stop.

---

## 2. The answer, up front

**Nine of the 23 are killed. The other fourteen are each closed with an
argument, ten of them as proved equivalent mutants and four with a named
reason. Board row N7 is closed: `EC_CORE` is reachable, by exactly one
descriptor class, with no RTL edit.**

| | before | after |
|---|---|---|
| `sim/mutate_axi_rd_port.sh` | 11 caught, **11 survived** | 13 caught, **9 survived** |
| `sim/mutate_matvec_int4.sh` | 14 caught, **12 survived** | 21 caught, **5 survived** |
| board row N7 `EC_CORE` | produced by no bench | `tb_matvec_fk33_desc` case 21, refused with `err_code = 0xE` |

**The single most important result is a correction, not a kill.** TRACK ACOV
added a `QSTALL` consumer-backpressure generic, measured that it killed zero
rows, and concluded that `DEPTH`/`MAXOUT`/`LVL_MARGIN` "are throughput
parameters of this unit, not correctness ones, and no amount of stimulus makes
them correctness ones". It also tried a witness on `rvalid and not rready`,
found it reads 0, and wrote it off as "measuring something the design makes
impossible".

Both halves are backwards. The witness reads 0 **because the design is
correct** -- that is what makes it an invariant rather than a dead probe -- and
the stimulus ACOV built is exactly what a *drifted* `DEPTH` needs.

* Row `C2` (FIFO built half the depth the FSM throttles against) dies at
  **`brim`**, ACOV's own configuration, with 34 refused R beats.
* Row `C1` (FSM told the FIFO is twice as deep) dies at a new configuration
  `starve` with 5 refused R beats.

Both die with `nbad = 0`: **no beat is ever lost, and the throttle's guarantee
is broken anyway.** What was missing was a detector, not a stimulus.

Three other things found on the way, none of which were in the brief:

1. **`sim/tb_axi_rd_port.vhd`'s FIFO high-water witness over-reports**, and
   ACOV's write-up quotes its numbers as occupancy. MEASURED: the unmutated
   port reports `occ_hi = 41` at `DEPTH = 32`, which a 32-deep `stream_fifo`
   cannot hold (its true maximum is `mcnt(32) + ocnt(2) + inflight(1) = 35`).
   The counter's `track` window is raised immediately after `start` and the
   drain -- which accepts and DISCARDS beats with `rready` forced high --
   happens immediately after `start`. Corrected in place, kept as a witness,
   deliberately not made a check.
2. **`LVL_MARGIN` was never a throughput parameter in the single-clock
   configuration.** It appears nowhere in the throttle. Inside
   `rtl/axi_rd_fsm.vhd` its only occurrence is the declared range of the
   `f_level` port. Rows `A8` and `A9` are therefore *provably* equivalent
   mutants, not "throughput" ones.
3. **Row `A7` (`f_qr` losing its `run_c` gate) is a real defect under
   `DUAL_CLK` and nothing in the tree catches it.** In `g_dc`,
   `run_c <= run_s2` rises up to two core cycles after `run_f`, and the async
   FIFO may already hold job data in that window; an ungated `f_qr` pops those
   words while `q_valid` is suppressed and they are lost. `rtl/axi_rd_port.vhd`'s
   own header argues "late is the safe direction" for `q_valid`, and that
   argument holds only because `f_qr` carries the same late gate. MEASURED: row
   `P8` of `sim/mutate_axi_rd_port_dual.sh` is exactly this edit and SURVIVES
   all three clock ratios. **Reported, not fixed** -- that bench is not this
   track's, and this track does not edit `rtl/`.

---

## 3. What each of the 23 became

`K` = killed by a new stimulus or check (attribution control run, section 5).
`E` = proved equivalent -- it cannot change behaviour.
`N` = named reason it is unreachable here.

### `sim/mutate_axi_rd_port.sh`

| row | | what it is, and the argument |
|---|---|---|
| `C1` | **K** | FSM told `2*DEPTH`. Dies at `starve` on the throttle invariant, 5 refused beats. |
| `C2` | **K** | FIFO built `DEPTH/2`. Dies at `brim` on the same, 34 refused beats. |
| `A4` | E | `f_iv` ungated. `S_DRAIN`'s only exit is `S_CLR`, which holds `clr`, and `rtl/stream_fifo.vhd:73` clears the whole FIFO on `flush`. Whatever the drain writes is gone before `S_RUN`. Attribution: row `B4`, which disables the flush outright, is KILLED by all six configurations -- the residue detector exists and bites. |
| `A5` | E | ACOV's proof, unchanged and re-confirmed: the throttle guarantees `f_ir` is never low, so `rvalid and rready_i` and `rvalid` are the same function on every legal trace. |
| `A7` | E* | `f_qr` ungated. Equivalent **in `g_sc` only**, where `run_c <= run_f` is a plain wire, so the ungated window is exactly the window in which `f_iv` is gated off and the FIFO can hold only residue the flush is about to discard; `rtl/stream_fifo.vhd:99` makes a pop on an empty FIFO a no-op. **NOT equivalent under `DUAL_CLK` -- see finding 3 above.** |
| `A8` | E | `LVL_MARGIN 3 -> 0` in both. See finding 2: it is a range declaration. `stream_fifo` drives `level <= mcnt + ocnt + inflight <= DEPTH + 3`, below `2*DEPTH` for every `DEPTH >= 3` and for all six configurations, so no bound check can fire. |
| `A9` | E | The same edit on the FSM generic alone. Same proof. |
| `B1` | E | `frst` tied low in `g_sc`. `frst` is read only at `rtl/axi_rd_port.vhd:281` and `:291`, both inside `g_dc`. The assignment is dead code. ACOV reported it; confirmed independently, still **not fixed**. |
| `B7` | E | `clr_done` combinational rather than registered. `clr_r` is already high when the FSM first evaluates `S_CLR`, so the FIFO still sees `flush = '1'` at a rising edge and still clears; `S_CLR2` then leaves immediately because `clr_done` follows `clr` down. Net effect: the clear completes one to two cycles early. The resolution is visible in the table itself -- `B5` (`clr_done` stuck high) and `B6` (stuck low) both ABORT. |
| `C3` | N | `MAXOUT => 64`. `sim/tb_axi_rd_port.vhd`'s slave is one sequential process: wait for `arvalid`, accept one AR, return every beat, loop. At most one burst is ever outstanding. MEASURED: `MAXOUT` = 2, 4, 16, 64 all finish at `@3395ns` with identical occupancy; `MAXOUT = 1` finishes at `@3235ns`. **The knob is live and saturates at 2** -- so this is a slave-model limit, not a dead parameter. Reaching it needs a slave that accepts ARs while still returning data, i.e. a new model. |
| `C4` | N | `MAXB => 1`. `ARLEN = 0` is legal AXI3 and AXI4, every beat arrives in order, and the occupancy witness drops from 26 to 4. It is 16x the AR traffic -- a real cost across 27 FK33 masters, and a cost, not a defect. Killing it would need an arbitrary AR-count threshold, which is what "weakening the notion of a kill" means. |

### `sim/mutate_matvec_int4.sh`

| row | | what it is, and the argument |
|---|---|---|
| `T1` | **K** | `dbg_wbeat <= wv` (offered, not accepted). Dies on `n_wbeat = w_beats` at `nostall` and `wide`. |
| `T2` | **K** | `dbg_wstarve <= wv`. Dies on the mutual-exclusion invariant in all six `tb_matvec_int4` configurations. |
| `C1` | **K** | `n_rows` as `unsigned`. Dies at `badrows` (`n_rows = -1` must be REFUSED). |
| `C2` | **K** | `out_shift` as `unsigned`. Dies at `badosh` (`out_shift = -1` must be REFUSED). |
| `C3` | **K** | `w_exp` as `unsigned`. Dies at `negexp` (`WEXP_BIAS = -5`). |
| `C4` | **K** | `x_exp` as `unsigned`. Dies at `negexp` (`XEXP_BIAS = -9`). |
| `S1` | **K** | `XB` loses its ceiling. Dies at `wide` (`MAXCOLS = 520`, `K = 520`). |
| `W1` | E | `w_ready`/`s_ready` swapped at the streamer. `rtl/matvec_core.vhd:567-568` is `w_ready <= accept; s_ready <= accept;` -- **one signal drives both ports**, so swapping the destinations delivers `accept` to both either way. No stimulus at any geometry can distinguish them. |
| `W2` | E | `w_valid`/`s_valid` swapped at the core. Those two ports occur in `rtl/matvec_core.vhd` at exactly three places: the declarations at lines 80 and 84, and line 565, `accept <= '1' when st = S_RUN and w_valid = '1' and s_valid = '1' and xq_cnt > 0`. Exchanging the two operands of an `and` cannot change it, and the DATA ports are not swapped. |
| `G4` | E | `LANES 4 -> 2`. `rtl/act_mem_striped.vhd:60-61` states that `bank*(LANES*W) + lane*W == W * (k mod BLK)` identically once `LANES` divides `BLK`, and line 71 asserts that precondition. Both 4 and 2 divide 32, so this is a re-partition of the same storage into 16x32 rather than 8x64 -- a BRAM-shape result whose only detector is a synthesis resource report. |
| `G6` | N | `DEPTH => FIFO_DEPTH/4`. Forwarded consistently -- one value reaches the FIFO and the FSM together -- so it creates none of the drift that `C1`/`C2` of the axi table create. The throttle's guarantee holds at the smaller number; the job is slower. |
| `G7` | N | `MAXOUT => 1`. Same. |

---

## 4. The procedure, in the order it was run

Each step states what it controls for.

1. **Reproduce both baseline tables at HEAD before touching anything.**
   `sim/mutate_axi_rd_port.sh` reproduced 11 caught / 11 survived exactly; the
   dual script reproduced 6 of 20. *Controls for working against a table that
   has already moved.*
2. **Read the RTL for each survivor before designing any stimulus, and ask
   first whether it CAN differ.** This is what turned `W1`, `W2`, `A8`, `A9`
   and `B1` into proofs rather than stimulus hunts, and it cost nothing --
   three greps. *Controls for building a bench feature for a mutation that
   cannot bite.*
3. **For every proposed oracle, measure the CONTROL across a spread of
   configurations before making it a check.** This is what caught the one
   proposal that was wrong: an occupancy check `occ <= DEPTH` looked right and
   killed `C1`, and then the UNMUTATED port reached `occ_hi = 41` at
   `DEPTH = 32` in a harsher configuration. *Controls for shipping a flaky
   check, and it is why the occupancy witness is now documented as an upper
   bound instead.*
4. **Run every kill with its own knob at the default as the attribution
   control**, and for the two-knob rows, with the OTHER knob as a cross-control.
   *Controls for the failure GRAY1 recorded: a 12-row table that would have
   claimed five kills instead of one.*
5. **Score an elaboration or analysis failure honestly.** `S1` can only ever be
   an elaboration failure, because `act_mem_striped`'s `rbaddr` width comes
   from `ELEMS` and not from `XB`; that is stated in the row rather than
   presented as a value mismatch.
6. **Append corrections in place; never delete a superseded claim.** ACOV's
   rejected-hypothesis block is left standing in `sim/mutate_axi_rd_port.sh`
   with a `CORRECTION` section under it saying which half is withdrawn.

---

## 5. The evidence, as raw output

### 5.1 `sim/mutate_axi_rd_port.sh`, after -- 13 caught, 9 survived

```
=== control: the UNMUTATED rtl/axi_rd_port.vhd, all six configurations ===
  gate   SURV|0 bad beats
  deep   SURV|0 bad beats
  tight  SURV|0 bad beats
  brim   SURV|0 bad beats
  brim2  SURV|0 bad beats
  starve SURV|0 bad beats

A4   RUN   SURVIVED 0 bad beats                        by[ none]
A5   RUN   SURVIVED 0 bad beats                        by[ none]
A7   RUN   SURVIVED 0 bad beats                        by[ none]
A8   LVL   SURVIVED 0 bad beats                        by[ none]
A9   LVL   SURVIVED 0 bad beats                        by[ none]
B1   SC    SURVIVED 0 bad beats                        by[ none]
B7   SC    SURVIVED 0 bad beats                        by[ none]
C1   GEN   KILLED   THE THROTTLE DID NOT HOLD: the port refused an offered R by[ starve]
C2   GEN   KILLED   THE THROTTLE DID NOT HOLD: the port refused an offered R by[ brim]
C3   GEN   SURVIVED 0 bad beats                        by[ none]
C4   GEN   SURVIVED 0 bad beats                        by[ none]

 22 mutations: 9 KILLED, 4 ABORT (13 caught), 9 SURVIVED, 0 VOID
 SURVIVORS (this bench's resolution floor, do not delete): A4 A5 A7 A8 A9 B1 B7 C3 C4
```

Before: `7 KILLED, 4 ABORT (11 caught), 11 SURVIVED`. **`C1` is caught by
`starve` alone and `C2` by `brim` alone** -- the first rows in this table whose
caught-by column is not unanimous, which is the column ACOV said was the useful
part and which had until now said nothing.

### 5.2 The attribution control for those two kills

Same mutant, same configuration, `CHK_FLOW` at `true` and at `false`:

```
=== C2 at brim ===
  CHK_FLOW=true  rc=1 axi_rd_port: 0 bad beats (QSTALL=3, occupancy upper bound 23 of DEPTH 32, R beats refused 34)
  CHK_FLOW=false rc=0 axi_rd_port: 0 bad beats (QSTALL=3, occupancy upper bound 23 of DEPTH 32, R beats refused 34)
=== C1 at starve ===
  CHK_FLOW=true  rc=1 axi_rd_port: 0 bad beats (QSTALL=9, occupancy upper bound 42 of DEPTH 16, R beats refused 5)
  CHK_FLOW=false rc=0 axi_rd_port: 0 bad beats (QSTALL=9, occupancy upper bound 42 of DEPTH 16, R beats refused 5)
```

**`NEW CHECK ALONE = 2, both = 0, NEITHER = 0.`** `nbad` is 0 in all four rows:
not one beat is lost in either mutant, and the throttle is broken in both.

### 5.3 The control sweep that REFUTED the check I nearly shipped

The first proposal was an occupancy check, `occ <= DEPTH`. It kills `C1` at
`brim`. Then the UNMUTATED port, across eight configurations:

```
-gMAXOUT=2  -gDEPTH=64  -gSTALL=3 -gSEED=1             refused=0 occ_hi=26
-gMAXOUT=16 -gDEPTH=512 -gSTALL=0 -gSEED=7             refused=0 occ_hi=43
-gMAXOUT=1  -gDEPTH=32  -gSTALL=5 -gSEED=3             refused=0 occ_hi=11
-gMAXOUT=4  -gDEPTH=32  -gSTALL=0 -gQSTALL=3 -gSEED=5  refused=0 occ_hi=25
-gMAXOUT=2  -gDEPTH=32  -gSTALL=2 -gQSTALL=2 -gSEED=8  refused=0 occ_hi=30
-gMAXOUT=16 -gDEPTH=32  -gSTALL=0 -gQSTALL=7 -gSEED=2  refused=0 occ_hi=41   <-- 41 > DEPTH
-gMAXOUT=16 -gDEPTH=16  -gSTALL=0 -gQSTALL=9 -gSEED=4  refused=0 occ_hi=12
-gMAXOUT=8  -gDEPTH=17  -gSTALL=7 -gQSTALL=5 -gSEED=6  refused=0 occ_hi=9
```

Row six kills the idea. `occ_hi = 41` at `DEPTH = 32` is not an occupancy a
32-deep `stream_fifo` can have (`mcnt 32 + ocnt 2 + inflight 1 = 35`), so the
counter is wrong, not the design. `refused` is 0 in all eight, which is what
made it safe to assert on.

### 5.4 `MAXOUT` is live and saturates at 2 -- the `C3` measurement

Unmutated port, gate configuration, sweeping only `MAXOUT`:

```
MAXOUT=1   @3235ns  0 bad beats (FIFO high-water 13 of DEPTH 64)
MAXOUT=2   @3395ns  0 bad beats (FIFO high-water 26 of DEPTH 64)
MAXOUT=4   @3395ns  0 bad beats (FIFO high-water 26 of DEPTH 64)
MAXOUT=16  @3395ns  0 bad beats (FIFO high-water 26 of DEPTH 64)
MAXOUT=64  @3395ns  0 bad beats (FIFO high-water 26 of DEPTH 64)
```

1 differs from 2; 2, 4, 16 and 64 are indistinguishable to the last picosecond.
So `C3` is not a dead parameter, it is a slave the bench never asks for more
than one outstanding AR.

### 5.5 The tap oracles, measured over twelve (M, K, STALL) combinations

`ctl` is the unmutated port, `T1` is `dbg_wbeat <= wv`:

```
M=8  K=96  STALL=0   ctl wbeat=6   w_beats=6     T1 wbeat=7
M=8  K=96  STALL=3   ctl wbeat=6   w_beats=6     T1 wbeat=6      <-- historical stimulus, T1 SURVIVES
M=32 K=96  STALL=0   ctl wbeat=24  w_beats=24    T1 wbeat=25
M=32 K=96  STALL=3   ctl wbeat=24  w_beats=24    T1 wbeat=24     <-- survives here too
M=8  K=256 STALL=0   ctl wbeat=16  w_beats=16    T1 wbeat=17
M=8  K=256 STALL=3   ctl wbeat=16  w_beats=16    T1 wbeat=17
M=32 K=256 STALL=0   ctl wbeat=64  w_beats=64    T1 wbeat=65
M=32 K=256 STALL=3   ctl wbeat=64  w_beats=64    T1 wbeat=65
M=8  K=512 STALL=0   ctl wbeat=32  w_beats=32    T1 wbeat=33
M=8  K=512 STALL=3   ctl wbeat=32  w_beats=32    T1 wbeat=34
M=32 K=512 STALL=0   ctl wbeat=128 w_beats=128   T1 wbeat=129
M=32 K=512 STALL=3   ctl wbeat=128 w_beats=128   T1 wbeat=130
```

**`n_wbeat = w_beats` exactly in all twelve for the correct RTL**, so the oracle
is geometry-independent. `T1` exceeds it in ten of twelve -- and the two it does
not are `M=8 K=96 STALL=3`, which is the configuration the gate row runs. That
is why the `nostall` judge exists.

`both = 0` in all twelve; under `T2` it is 6, one per accepted word.

### 5.6 The five new judges, and each kill with its own attribution control

```
### C3  bias  (WEXP_BIAS=-5 XEXP_BIAS=-9)       rc=1
### C3  ATTRIBUTION CONTROL: same mutant, bias 0 rc=0  ...packed bytes up
### C4  bias                                    rc=1
### C4  ATTRIBUTION CONTROL: same mutant, bias 0 rc=0  ...packed bytes up
### S1  MAXCOLS=520 K=520                       rc=1  bound check failure at .../mv.vhd:170
### S1  ATTRIBUTION CONTROL: MAXCOLS=512 K=96    rc=0  ...packed bytes up
### T1  STALL=0 taps on                         rc=1  TAP COUNT: dbg_wbeat was high on 7 cycles but the job consumed 6 weight words
### T1  ATTRIBUTION CONTROL: STALL=0 taps OFF    rc=0  ...packed bytes up
### T1  second control: STALL=3 taps ON          rc=0  ...packed bytes up
### T2  taps on                                 rc=1  TAP CONTRADICTION: dbg_wbeat and dbg_wstarve were both high on 6 cycles
### T2  ATTRIBUTION CONTROL: taps OFF            rc=0  ...packed bytes up
### C1 ERRINJ=2 (n_rows=-1)                     rc=1  overflow detected
### C1 ATTRIBUTION CONTROL ERRINJ=0              rc=0  ...packed bytes up
### C2 ERRINJ=1 (out_shift=-1)                  rc=1  overflow detected
### C2 ATTRIBUTION CONTROL ERRINJ=0              rc=0  ...packed bytes up
### C1 under ERRINJ=1 (the OTHER knob)           rc=0  refused, err=1, 0 rows emitted
### C2 under ERRINJ=2 (the OTHER knob)           rc=0  refused, err=1, 0 rows emitted
```

The last two are cross-controls: each mutation dies under its own knob and
survives the other, so the two `ERRINJ` modes are independent rather than one
detector counted twice.

The unmutated RTL under every new knob:

```
-gWEXP_BIAS=-5 -gXEXP_BIAS=-9   0 mismatches, y_exp=-16
(default)                       0 mismatches, y_exp=-2
-gMAXCOLS=520 (K=520)           0 mismatches, y_exp=-2, dbg_wbeat 34 of w_beats 34
-gERRINJ=1                      the illegal descriptor was refused, err=1, 0 rows emitted
-gERRINJ=2                      the illegal descriptor was refused, err=1, 0 rows emitted
```

`-16 = -2 + (-5) + (-9)` exactly, which is the arithmetic the bias is DERIVED
from (`ref/matvec_int4.c:426` and `rtl/matvec_core.vhd:1031` compute the same
expression, and nothing else reads either exponent).

### 5.7 Board row N7 -- `EC_CORE` is now produced

```
CASE 20 w_beats halved to 192              -> refused, err_code = 15, ERR_INFO = 2084
CASE 21 out_shift = 41, above 7.4's cap    -> refused, err_code = 14, ERR_INFO = 65535
CASE 22 descriptor slave never answers     -> refused, err_code = 4,  ERR_INFO = 65535
attribution: 23 cases, 0 pairs of DIFFERENT checks sharing one (err_code, ERR_INFO)
tb_matvec_fk33_desc: 23 cases run, 0 failures [DUAL=false XEXP_PORT=false]
```

`err_code = 14` is `0xE`, `EC_CORE`. **No RTL was edited**, and the stimulus is
one field: `out_shift = 41`.

**Why that is the only stimulus there is.** `rtl/matvec_int4_desc_axi.vhd:543`
is `v_osh <= hi32(dw(2))` and the engine validates every other descriptor field
it forwards. `rtl/matvec_core.vhd:946` rejects
`n_rows <= 0 or n_cols <= 0 or n_cols > MAXCOLS or out_shift < 0 or
out_shift > 40 or (out_mode = "00" and n_rows > MAXROWS_BFP)`. Line by line, the
engine already refuses `n_rows = 0` (`ED_ROWS_ZERO`), `n_rows > MAXROWS_BFP`
(`ED_ROWS_MAX`, in every mode, so stricter than the core), `n_cols = 0`
(`ED_COLS_ZERO`) and `n_cols > MAXCOLS` (`ED_COLS_MAX`); negatives arrive as
large `unsigned` values and are caught by the same two upper bounds. **The
`out_shift` range is the one core guard the engine does not duplicate, and it
is therefore the entire reachable set of `EC_CORE`.** `41` is one over the cap,
so the row pins the cap and not "a large out_shift".

---

## 6. Measured and REJECTED -- do not retry

### 6.1 `occ <= DEPTH` as a check. It is not an invariant.

It looks exactly right -- it is the throttle's guarantee restated -- and it
kills `C1`. The unmutated port reaches `occ_hi = 41` at `DEPTH = 32` (section
5.3). The counter, not the design, is wrong: `track` is raised immediately after
`start`, and the drain that `start` triggers accepts and DISCARDS beats with
`rready` forced high. Those beats are counted in and never counted out.

**Do not build a check on that counter.** An honest occupancy needs
`stream_fifo`'s own `level`, which `axi_rd_port` does not expose.

### 6.2 Killing `T1` on the gate row's own stimulus. It cannot be done there.

`rtl/matvec_core.vhd:566` is
`accept <= '1' when st = S_RUN and w_valid = '1' and s_valid = '1' and xq_cnt > 0`,
and `w_ready <= accept`. So `wv and wr` and `wv` differ only on a cycle where a
word is offered and the core cannot take it. At `M=8 K=96 STALL=3` there is no
such cycle in the whole run (section 5.5) -- the weight supply is the bottleneck
end to end. A stall rate does not create one; **removing** the slave stalls does.
That is counter-intuitive and is why `nostall` is `STALL=0` and not `STALL=9`.

### 6.3 Reaching `S1` at a geometry where `K` is a multiple of `BLK`. Impossible.

DERIVED. `clog2(ceil(MAXCOLS/BLK))` and `clog2(floor(MAXCOLS/BLK))` differ only
when `floor = 2^k` and `ceil = 2^k + 1`, i.e. `MAXCOLS = 2^k*BLK + r` with
`1 <= r <= BLK-1`. To use the extra bit the job must reach block index `2^k`,
i.e. `K > 2^k*BLK`; and `K <= MAXCOLS < (2^k+1)*BLK`. That open interval
contains no multiple of `BLK`. **Both `MAXCOLS` and `K` have to be off-grid at
once**, which is why this needed the reference to support a partial last block.
It does, and the unmutated RTL is bit-exact there -- MEASURED at `K = 104` and
`K = 520` before the judge was added.

### 6.4 Killing `C3` (`MAXOUT => 64`) with a configuration. Not possible here.

Section 5.4. It needs a slave that accepts ARs while still returning data, which
is a new model, not a new generic value.

### 6.5 Counting `C4` (`MAXB => 1`) as caught. Deliberately not done.

`ARLEN = 0` is legal on AXI3 and AXI4, every beat arrives in order, `nbad = 0`,
and the occupancy witness drops from 26 to 4. It is 16x the AR traffic, which on
27 FK33 masters is a real cost -- and a cost is not a defect. Killing it needs an
arbitrary AR-count threshold, and a table of kills obtained that way is worth
less than the survivor.

### 6.6 Appending the `EC_CORE` case at the end of `tb_matvec_fk33_desc`.

It works, and then the run dies -- see trap 3 in section 7. The case is inserted
at index 21, before the watchdog case, and the per-case reset is lengthened.

---

## 7. Measurement traps hit, including my own

1. **My own, and it is 6.1: I had the check written before I swept the
   control.** The occupancy check killed the mutant I cared about on the first
   configuration I tried, which is exactly the moment to go looking for the
   cheapest refutation. Two more configurations of the UNMUTATED port refuted
   it. Had I shipped it, it would have been a gate row that fails on a
   correct design at a generic nobody had tried yet.
2. **A survivor's stated reason can be right about the measurement and wrong
   about the conclusion.** ACOV's `QSTALL` section is careful, honest, and
   arrives at "no amount of stimulus makes them correctness ones" from a
   measurement that only showed "the checks I have do not see it". The tell was
   that the same document also described a witness that reads 0 -- and a witness
   that reads 0 on a correct design is a candidate invariant, not a dead probe.
3. **A new case at the END of a table is not the same as a new case in the
   MIDDLE.** `tb_matvec_fk33_desc`'s watchdog case leaves an AR outstanding at a
   deliberately deaf slave, and the bench's per-case recovery is `aresetn` --
   i.e. it resets the master while a read is outstanding at a slave that AXI
   gives no way to cancel and that this bench does not model as reset-aware.
   Appending anything after it died with
   `bound check failure at rtl/axi_rd_fsm.vhd:231`. **MEASURED with a mutated
   case AND with a clean one**, which is what showed it was the position and not
   the content. The new `EC_CORE` case has the same property for a different
   reason (the core refuses AFTER `start`, so the weight streamer is left
   mid-fetch), so BOTH of the last two cases poison a successor and there is
   only one last slot. Fixed by lengthening the reset to 512 cycles, which lets
   the ports drain (`rready_i` is forced high outside `S_RUN`). Cost: 1.5 s on a
   50 s row.
4. **`ghdl -r ... | head` reports the pipeline's rc.** Used `${PIPESTATUS[0]}`
   throughout; the `S1` and `C1`/`C2` verdicts would otherwise all have read 0.
5. **An elaboration-time width failure is not a value mismatch, and `S1` can
   only ever be the former.** `act_mem_striped`'s `rbaddr` width comes from
   `ELEMS`, not from `XB`, so a narrowed `XB` cannot produce a wrong number --
   it produces a port that does not fit. Stated in the row rather than dressed
   up. Note also that `sim/mutate_matvec_int4.sh`'s scorer classes
   `bound check failure` as ABORT and only a message containing
   `width|length|port|bound of|not constrained` as VOID -- **and it matches
   against a line that includes the SCRATCH PATH**, so a scratch directory whose
   name contains "port" would silently reclassify a kill as VOID. Pre-existing,
   not introduced here, and worth fixing.
6. **`sim/regress.sh` was never opened.** Nothing in this track needed it, which
   removed the shared-file race entirely. No new `sim/tb_*.vhd` was created
   either, so no gate row was added and `BASELINE_PASS` stays 93 by
   construction.

---

## 8. Open, NOT determined here

* **Can subsystem A be re-armed after `EC_CORE`?** Not answered, and now
  askable for the first time. `EC_CORE` is the ONLY error code raised AFTER
  `core_start`, so it is the only one that leaves the weight streamer mid-fetch
  with outstanding AXI reads and full FIFOs. `S_ERR` is sticky by design ("only
  a reset leaves this state"), so the design's own recovery is a reset -- with
  reads outstanding, which AXI cannot cancel. In simulation the bench gets away
  with it by holding reset until the slaves run dry. On the FK33, whether the
  HBM controller is reset with the design decides whether that is safe, and
  nothing in this repository says.
* **Row `A7` under `DUAL_CLK` is a real defect that nothing catches.** See
  finding 3 of section 2. Fixing the bench is
  `sim/tb_axi_rd_port_dual.vhd`'s owner's; fixing nothing may be right, since
  the RTL is correct -- what is missing is the check that keeps it correct.
* **`frst <= rst;` in `axi_rd_port`'s `g_sc` is still dead code.** Third
  independent report. Not fixed, because this is a coverage track.
* **`sim/tb_axi_rd_port.vhd`'s occupancy witness is still an over-count.**
  Documented and left as a witness. A correct one needs `stream_fifo`'s `level`
  brought out of `axi_rd_port`, which is an RTL change.
* **`G4` (`LANES 4 -> 2`) has no simulation detector by construction.** The only
  thing that could see it is a synthesis resource report. Nothing in the
  mutation-testing flow reads one, and building that is a different kind of
  tool.
* **The `xexp` and `dual` wrappers now run 23 cases each, `EC_CORE` included,
  but the cross product with `USE_XEXP_PORT` and `DUAL_CLK` is still
  incidental** -- no row exists because that combination was reasoned about.
* **No full-tree gate run was performed.** A Vivado synthesis from another track
  was live throughout (load average 12.4 at the time of the last measurement),
  and `CLAUDE.md` forbids two concurrent full gates. What was run is in
  section 5 and the row-level regressions in section 9.

---

## 9. The gate rows, run

`sim/regress.sh --only tb_axi_rd_port`:

```
PASS       sim:tb_axi_rd_port                     0s  ...:@3395ns:(report note): axi_rd_port: 0 bad beats (QSTALL=0, occupancy upper ...
PASS       sim:tb_axi_rd_port_dual                0s  ...:@9947ns:(report note): PASS: tb_axi_rd_port_dual
 OVERALL     PASS 2   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

`@3395ns` is the same end time the row had before this track, so the gate row's
stimulus is unchanged and `CHK_FLOW` costs it nothing.

`sim/regress.sh --only tb_matvec` (the third field is elapsed SECONDS):

```
PASS       sim:tb_matvec_axi                      2s
PASS       sim:tb_matvec_cb_contract              1s
PASS       sim:tb_matvec_cb_lockstep              0s
PASS       sim:tb_matvec_core                     2s
PASS       sim:tb_matvec_core_ragsat              2s
PASS       sim:tb_matvec_fk33                    11s
PASS       sim:tb_matvec_fk33_desc               51s
PASS       sim:tb_matvec_fk33_desc_dual          56s
PASS       sim:tb_matvec_fk33_desc_xexp          51s
PASS       sim:tb_matvec_int4                     1s
PASS       sim:tb_matvec_int4_ip                  1s
PASS       tb:tb_matvec_engine                    0s
 OVERALL     PASS 12   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

The three descriptor rows were 47 / 52 / 47 s before this track and are 51 / 56
/ 51 s after, i.e. the 23rd case plus the 512-cycle reset cost about 4 s each,
and all three are OPTIONAL rows (they need the `.mv4i` model set, which is not
in git). `sim:tb_matvec_int4` ends at `@1675ns`, exactly where it ended before
the new generics were added -- every one of them defaults to the historical
value.

**`BASELINE_PASS` stays 93.** No new `sim/tb_*.vhd` was created, so no gate row
was added, and `sim/regress.sh` was not opened at all.

## 10. Machine, as measured

```
/dev/nvme1n1p6  1.3T  1.2T  120G  91% /
/dev/nvme0n1p1  916G  483G  388G  56% /mnt/storage
Mem: total 31  used 4  free 6  buff/cache 19  available 25
load average at start 3.43, at the last check 12.42 with one Vivado synthesis
from another track live
```
