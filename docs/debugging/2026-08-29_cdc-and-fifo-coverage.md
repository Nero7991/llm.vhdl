# The clock domain crossing in the weight path had no bench at all

**Date:** 2026-08-29
**Track:** CDC-BENCH
**Tooling:** GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6), mcode backend; `cc -O2`; no hardware
**Files added:** `sim/tb_async_fifo.vhd`, `sim/tb_axi_rd_fsm.vhd`,
`sim/mutate_async_fifo.sh`, `sim/mutate_axi_rd_fsm.sh`,
`sim/tb_matvec_core_ragsat.vhd`, `sim/tr_ragsat.txt`
**Files changed:** `rtl/async_fifo.vhd` (ONE defect, see section 2),
`sim/mutate_matvec_core.sh` (a fourth trace and its self-check),
`sim/regress.sh` (three rows, their stop-times, and BASELINE_PASS 88 -> 91)

---

## 1. The question, verbatim

> TRACK A-MUT's closing list of what still has NO coverage names your target,
> and flags it as the top risk itself:
>
> > `matvec_int4.vhd`, `matvec_int4_desc_axi.vhd` (1012 lines, the descriptor
> > decode), `axi_rd_port.vhd`, and -- highest risk -- **`axi_rd_fsm.vhd` and
> > `async_fifo.vhd`, which have no dedicated bench at all** and are only
> > reached through `axi_rd_port`. **A CDC with no direct bench is the top item
> > on that list.**
>
> **Part 1 (priority): a direct bench plus mutation coverage for
> `rtl/async_fifo.vhd` and `rtl/axi_rd_fsm.vhd`.**
>
> **Part 2: the gate-row decision A-MUT left, but decide it with measurement.**
> Eight mutations are invisible to the committed gate ... **Add gate coverage
> for those eight.** ... find the cheapest row or rows that close the gap.

---

## 2. The answer, up front

**`rtl/async_fifo.vhd` carried a defect that made it IMPOSSIBLE to fill in
simulation, and it was found by the first run the new bench ever made.**

`rtl/async_fifo.vhd:276`'s write-into-full guard read

```vhdl
assert not (w_valid = '1' and used_w = to_unsigned(DEPTH, AW+1))
  report "async_fifo: WRITE INTO A FULL FIFO -- a beat was dropped"
  severity failure;
```

That is not "a beat was dropped". It is "a producer is OFFERING while the FIFO
is full", which is ordinary backpressure, and a conforming stream producer holds
`w_valid` until `w_ready` -- so filling this FIFO from one killed the simulation
at **severity failure** with nothing wrong. MEASURED: it fired at 172500 ps on
the first run, and with the assert downgraded to a probe it fired **34,362 times
across eight clock ratios with `w_ready = '0'`, `full_r = '1'` and
`wr_now = '0'` EVERY single time**. Not one beat was ever dropped.

Fixed by testing `wr_now` -- the RTL's own single write-enable term -- instead
of `w_valid`. Synthesis ignores asserts, so **nothing in hardware changes**;
what changes is that the FIFO can now be filled in simulation, which is the one
state the +123.88 MHz flag restructuring of 2026-08-28 most needed a bench to
reach. Teeth: mutation `F2` in `sim/mutate_async_fifo.sh` breaks `full_r` so a
write really does land at `used_w = DEPTH`, and the corrected guard fires.

**Both units are otherwise in good shape.** No other defect was found in
`rtl/async_fifo.vhd` or `rtl/axi_rd_fsm.vhd`.

| harness | result |
|---|---|
| `sim/mutate_async_fifo.sh` | **24 of 33** (19 KILLED + 5 ABORT), 9 survivors |
| `sim/mutate_axi_rd_fsm.sh` | **25 of 33** (21 KILLED + 4 ABORT), 8 survivors |

**Part 2: ONE new gate row closes the whole gap, not two.** A-MUT's eight
blind spots split four-and-four between "needs a ragged shape" and "needs
saturation", which reads as two rows. It is one: `--trace t 6 1000 4 1` is
ragged in BOTH dimensions (M = 6 is not a multiple of ROWS_IF = 4, K = 1000 is
not a multiple of BLK = 32) **and** still reaches `SATEV 1`, because the
adversarial mode only needs NB > 16 and NB = 32 here. MEASURED against all 57
mutations: trace X alone kills 34 of 57 and kills all eight of the
gate's blind spots.

---

## 3. The procedure, in the order it was run

Each step says what it controls for. This is the reusable part.

1. **Establish that the units are not on the gate at all, rather than weakly
   on it.** `grep -n DUAL_CLK` over `rtl/` and `sim/`: every instantiation of
   `axi_rd_port` in a gate row takes `DUAL_CLK = false`, which selects
   `rtl/stream_fifo.vhd`; the only elaboration of `async_fifo` in the tree is
   `sim/tb_matvec_fk33_desc.vhd`, whose `DUAL` generic defaults to FALSE, and
   `sim/regress.sh`'s own `tb_args` comment says the `DUAL=true` configuration
   is a MANUAL run. So `async_fifo`'s architecture was not merely under-tested
   on a gate run -- it was never elaborated. Controls for writing a bench for
   something that turns out to be covered elsewhere.

2. **Ask what a simulator can and cannot observe about a CDC, BEFORE writing
   anything.** Gray coding is an MTBF property; an RTL simulator samples
   atomically, so binary pointers cross just as cleanly. Tried and rejected:
   VHDL-2008 external names to watch the pointers directly -- GHDL 1.0.0 mcode
   has no such support (see 5). The conclusion shaped the whole design: the
   bench pursues what IS observable (ordering, occupancy, flags, the clear,
   resets) and the mutation table NAMES the unobservable part rather than
   pretending to cover it.

3. **Write the bench so it FILLS.** The single most important design decision.
   `rtl/async_fifo.vhd`'s header records that `w_ready` and `w_level` were both
   pulled out of a combinational gray-decode-and-subtract on 2026-08-28 for
   +123.88 MHz, and that `full_r` is now computed one cycle AHEAD. Restructured
   flag logic is exactly where an off-by-one hides, so the writer holds
   `w_valid` until accepted and the fill phase is asserted to have reached full
   capacity. That decision found the defect in section 2 immediately.

4. **Make the FSM's modelled FIFO refuse to backpressure.** The equivalent
   decision on the other bench. `rtl/axi_rd_fsm.vhd`'s comment claims "an
   accepted burst can never overrun the FIFO"; a model that pushed back would
   absorb an overrun and the claim would pass by construction. With `rready`
   tied high the throttle is the ONLY thing holding the level inside DEPTH.

5. **Run the honest RTL first, every time, and treat a failure as the bench's
   until proved otherwise.** Four of the five traps in section 6 are bench
   defects caught this way.

6. **Assert coverage rather than printing it.** A run in which the FIFO never
   filled, or never emptied, or in which MAXOUT was never the binding limit,
   FAILS. Two mutations (`F3`, `G6`) were caught by nothing else, and tightening
   one coverage bound from DEPTH to DEPTH+2 converted `G6` from a survivor to a
   kill.

7. **Choose per-instance coverage from the GENERICS, not from the stimulus.**
   `rtl/axi_rd_port.vhd`'s own MAXOUT comment states that MAXOUT "simply stops
   being reachable once MAXOUT*MAXB > DEPTH". Asserting MAXOUT coverage on an
   instance where it is inert is noise, so each instance asserts only the limit
   that can bind for it, and the two instances are chosen so that between them
   both limits are covered.

8. **Explain every survivor by name, then act only where the explanation is a
   stimulus gap.** Three classes came out, and only the third justified touching
   a bench: unobservable-by-construction (`G1`, `G3`, `G4`, `C6`, `L3`), true
   equivalents (`F5`, `R2`, `D2`(fifo), `A2`, `A4`, `A7`, `D4`, `D5`, `T4`,
   `T8`, `R1`), and genuine stimulus gaps (`G6`, `F3`, `D2`(fsm)).

9. **When two guards each survive alone, mutate them TOGETHER.** `A7` (AR issue
   not gated on S_RUN) and `D4` (a start no longer stops the old job) are each
   individually unobservable, because either one alone still leaves
   `ar_left = 0` during the drain. The PAIR is killed at once. A table that
   reported only the singletons would have said two guards were dead code; they
   are one guard expressed twice.

10. **Decide the gate row by measuring a candidate trace, not by counting the
    blind spots.** Four needing raggedness and four needing saturation looks
    like two rows. It is one, and only a measurement says so.

---

## 4. The evidence

### 4.1 GHDL 1.0.0 mcode has no external-name support (MEASURED)

```
alias ip is << signal .tb_extn.u.p : unsigned(3 downto 0) >>;
```

```
translate_name: cannot handle IIR_KIND_EXTERNAL_SIGNAL_NAME (extn.vhd:14:15)
******************** GHDL Bug occurred ***************************
Exception TYPES.INTERNAL_ERROR raised
```

So the gray pointers cannot be watched from a bench even to check the
single-bit-change property directly. This is why `G1` is a survivor by
construction rather than by omission.

### 4.2 The defect, as first seen (MEASURED, against untouched RTL)

```
rtl/async_fifo.vhd:276:9:@172500ps:(assertion failure): async_fifo: WRITE INTO A FULL FIFO -- a beat was dropped
/usr/bin/ghdl-mcode:error: assertion failed
in process .tb_async_fifo(sim).c6@af_case(beh).dut@async_fifo(rtl).wproc
```

`c6` is the `tiny` case (DEPTH = 4), which fills first.

### 4.3 The defect, with the guard downgraded to a probe (MEASURED)

```
PROBE lines: 34362
diag/async_fifo_probe.vhd:277:11:@172500ps:(report note): PROBE: used_w=DEPTH with w_valid=1 :: w_ready='0' full_r='1' wr_now='0'
distinct probe states:
  34362 w_ready='0' full_r='1' wr_now='0'
--- verdict ---
async_fifo: 0 errors across 8 clock ratios
PASS: tb_async_fifo
```

**Every one of the 34,362 occurrences has `w_ready = '0'` and `wr_now = '0'`.**
The guard could not distinguish backpressure from a dropped beat, and no beat
was ever dropped.

DERIVED, which is why the old form could never have been right:
`used_w(n) = DEPTH` implies `used_w(n-1) >= DEPTH-1`; if `used_w(n-1) = DEPTH-1`
then `wp` must have advanced, so `wr_now(n-1) = '1'` and the look-ahead arm sets
`full_r(n) = '1'`; if `used_w(n-1) >= DEPTH` the first arm sets it. So
`w_ready` is ALWAYS low when `used_w = DEPTH`, and `w_valid` at that moment
carries no information whatsoever.

### 4.4 `sim/tb_async_fifo` on the honest RTL, final (MEASURED, 0.42 s)

```
eq_ph0:  nw=795  nr=722 maxocc=18/16 wstall=1508  rstall=1214 minslack=0 err=0
eq_ph90: nw=791  nr=718 maxocc=18/16 wstall=1467  rstall=1290 minslack=0 err=0
slide:   nw=800  nr=727 maxocc=18/16 wstall=1569  rstall=1022 minslack=0 err=0
fastr:   nw=776  nr=742 maxocc=18/16 wstall=168   rstall=4726 minslack=0 err=0
thrott:  nw=762  nr=704 maxocc=16/16 wstall=0     rstall=395  minslack=0 err=0
tiny:    nw=717  nr=693 maxocc=6/4   wstall=4645  rstall=681  minslack=1 err=0
fastw:   nw=777  nr=703 maxocc=18/16 wstall=6566  rstall=432  minslack=0 err=0
deep:    nw=1021 nr=755 maxocc=66/64 wstall=20914 rstall=229  minslack=0 err=0
async_fifo: 0 errors across 8 clock ratios
PASS: tb_async_fifo
```

Two numbers in that block are worth more than the verdict.

**`minslack = 0`.** That is `min(w_level - true occupancy)` over the whole run.
The RTL header DERIVES that `w_level >= occupancy + OUT_MARGIN` and that the +1
"pays for" the register's staleness in full. MEASURED, it holds with **exactly
zero slack** on seven of the eight ratios (and with one beat to spare on
`tiny`, DEPTH = 4): the derivation is not conservative, it
is tight, and any change that removes a term from it is immediately unsafe.
Mutation `L1` (drop the +1) is caught for exactly that reason.

**`thrott` has `wstall = 0`.** With the writer gated on `w_level < DEPTH`, the
way `rtl/axi_rd_fsm.vhd` gates AR issue, the FIFO was NEVER ONCE refused a beat
over 762 writes. That is the property the AR throttle rests on, measured
end-to-end rather than argued.

### 4.5 `sim/mutate_async_fifo.sh`, final run (MEASURED)

```
---- class GRAY: the pointer encoding and its synchronisers -----------
G1   GRAY   SURVIVED 0 errors across 8 clock ratios                           -- BOTH bin2gray and gray2bin become the identity: the pointers cross as plain BINARY.  THE RESOLUTION FLOOR -- expected to survive, and it must
G2   GRAY   KILLED   eq_ph90: w_level 7 UNDER-STATES occupancy 8 -- the throt -- TEETH-CHECK for G1: only the DECODER becomes the identity, so encoder and decoder disagree
G3   GRAY   SURVIVED 0 errors across 8 clock ratios                           -- the read pointer crosses through ONE flop, not two (MTBF only -- expected to survive)
G4   GRAY   SURVIVED 0 errors across 8 clock ratios                           -- the write pointer crosses through ONE flop, not two (MTBF only -- expected to survive)
G5   GRAY   KILLED   eq_ph0: DRAIN STALLED with 1 beats still inside          -- the gray encode of the NEXT write pointer uses the CURRENT one, so the pointer the read side sees lags by a beat
G6   GRAY   KILLED   eq_ph0: COVERAGE -- the FIFO never reached its full capa -- the read pointer's gray encode lags the same way

---- class FULL: the flag the +123.88 MHz restructuring rewrote --------
F1   FULL   ABORT    async_fifo: WRITE INTO A FULL FIFO -- a beat was dropped -- full_r loses its LOOK-AHEAD arm, so it rises one cycle late and exactly one beat overruns the memory
F2   FULL   ABORT    async_fifo: WRITE INTO A FULL FIFO -- a beat was dropped -- TEETH-CHECK for the write-into-full guard this track fixed: full asserts one slot LATE, so wr_now is high with used_w = DEPTH
F3   FULL   SURVIVED 0 errors across 8 clock ratios                           -- full asserts one slot EARLY: the FIFO silently holds DEPTH-1 and the coverage assert is the only thing that can see it
F4   FULL   KILLED   eq_ph0: A BEAT WAS ACCEPTED DURING THE CLEAR and will be -- w_ready forgets its clr term, so beats are accepted during the clear and thrown away
F5   FULL   SURVIVED 0 errors across 8 clock ratios                           -- wr_now forgets its clr term while w_ready keeps it.  EXPECTED TO SURVIVE: the memory write lives in the branch the clear takes over, so during a clear it is not reached at all
F6   FULL   KILLED   fastr: phase1 fill STALLED -- 8 of 40 beats consumed     -- the empty comparison drops the MSB of the pointer pair, so a FULL FIFO reads as EMPTY (the classic reason the pointers are AW+1 bits)

---- class LVL: the registered occupancy the AR throttle reads ---------
L1   LVL    KILLED   eq_ph90: w_level 7 UNDER-STATES occupancy 8 -- the throt -- w_level_r loses the +1 that pays for its own staleness -- the exact unsafe direction the RTL header derives
L2   LVL    KILLED   eq_ph90: w_level 1 UNDER-STATES occupancy 2 -- the throt -- w_level_r loses the OUT_MARGIN term entirely: the read side's output stage becomes invisible to the throttle
L3   LVL    SURVIVED 0 errors across 8 clock ratios                           -- w_level goes back to the COMBINATIONAL pre-2026-08-28 form.  Safe, and 123.88 MHz slower -- a functional bench cannot see timing
L4   LVL    KILLED   eq_ph90: COVERAGE -- the FIFO never reached its full cap -- the occupancy subtraction is reversed

---- class CLR: the four-phase handshake ------------------------------
C1   CLR    KILLED   thrott: FIFO NOT EMPTY AFTER THE CLEAR -- residue surviv -- clr_done is the caller's own clr fed straight back: the acknowledgement no longer proves the READ side saw anything
C2   CLR    KILLED   eq_ph0: clr_done NEVER FELL                              -- the read side acknowledges from the RUNNING branch as well, so the ack can precede the parking
C3   CLR    KILLED   eq_ph0: FIFO NOT EMPTY AFTER THE CLEAR -- residue surviv -- the clear no longer empties the read side's OUTPUT STAGE, so up to three beats of residue survive it
C4   CLR    KILLED   eq_ph0: FIFO NOT EMPTY AFTER THE CLEAR -- residue surviv -- the clear no longer parks the READ pointer
C5   CLR    KILLED   eq_ph0: FIFO NOT EMPTY AFTER THE CLEAR -- residue surviv -- the clear no longer parks the WRITE pointer
C6   CLR    SURVIVED 0 errors across 8 clock ratios                           -- the clear request crosses through ONE flop into the read domain, not two (MTBF only -- expected to survive)

---- class OUT: the read-side output stage ----------------------------
O1   OUT    ABORT    bound check failure at /tmp/claude-1000/-home-orencollac -- the output stage is allowed a third beat in flight, one more than it can hold
O2   OUT    ABORT    bound check failure at /tmp/claude-1000/-home-orencollac -- the in-flight memory read is not counted, so a read is issued against a stage that is already committed
O3   OUT    KILLED   eq_ph90: q_valid HIGH OUT OF RESET                       -- the memory read is marked valid unconditionally, so every cycle pushes a beat into the output stage
O4   OUT    KILLED   slide: BEAT 1 got 0 want 1 -- A BEAT WAS DUPLICATED OR R -- the output stage's read pointer follows its WRITE pointer, so beats come out in the wrong order once both are in use
O5   OUT    KILLED   slide: BEAT 2 got 0 want 2 -- A BEAT WAS DUPLICATED OR R -- q_valid is asserted whenever anything is in flight, one cycle before the data is in the stage
O6   OUT    KILLED   slide: BEAT 0 got 1 want 0 -- BEATS WERE DROPPED         -- the read pointer advances on the memory read being ISSUED but the memory is addressed from the OLD pointer -- an off-by-one in the fetch

---- class RST: reset behaviour in each domain ------------------------
R1   RST    KILLED   eq_ph0: RESIDUE SURVIVED THE SKEWED RESET -- q_valid is  -- the read-domain reset no longer clears the output stage, so residue survives a reset
R2   RST    SURVIVED 0 errors across 8 clock ratios                           -- the write-domain reset no longer clears the synchronised read pointer (expected to survive: those two flops track rp_g, which the read reset holds at 0 anyway)
R3   RST    KILLED   eq_ph0: RESIDUE SURVIVED THE SKEWED RESET -- q_valid is  -- the read-domain reset no longer parks the read pointer

---- class GUARD: the elaboration guard -------------------------------
D1   GUARD  ABORT    async_fifo: DEPTH must be a power of two (gray coding is -- TEETH-CHECK: the power-of-two guard is inverted, so the correct DEPTH violates it
D2   GUARD  SURVIVED 0 errors across 8 clock ratios                           -- the power-of-two guard is REMOVED (expected to survive: a removed guard cannot change a conforming design -- read it together with D1)

=======================================================================
kill ratio: 19 KILLED + 5 ABORT = 24 of 33;  9 SURVIVED
survivors: G1 G3 G4 F3 F5 L3 C6 R2 D2
scratch dir with every mutant and its log: /tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/mutaf2
```

**Survivors, every one under its own name.** These are the most valuable rows
in the table: they measure the checker's resolution floor. None is discarded.

| tag | class | why it survives | closable? |
|---|---|---|---|
| `G1` | **unobservable by construction** | BOTH the gray encoder and decoder become the identity, so the pointers cross as plain BINARY. Gray coding is an MTBF property and an RTL simulator samples atomically. `G2` mutates only the decoder and is killed instantly, which is what proves the bench watches the pointers at all. | never in simulation. Needs Vivado `report_cdc`, ASYNC_REG, and asynchronous clock groups in the XDC |
| `G3` | **unobservable by construction** | the read pointer crosses through one flop instead of two. 2FF vs 1FF is an MTBF number. | as `G1` |
| `G4` | **unobservable by construction** | the same, for the write pointer. | as `G1` |
| `C6` | **unobservable by construction** | the clear request crosses through one flop instead of two. The read side parks one cycle earlier and still acknowledges only from the parked branch, so the handshake is unchanged. | as `G1` |
| `L3` | **timing only, and documented in the RTL** | `w_level` reverts to the pre-2026-08-28 COMBINATIONAL form. Functionally identical and 123.88 MHz slower. A functional bench does not measure timing. | never. Needs STA |
| `F3` | **near-equivalent, precisely characterised** | `full_r`'s FIRST arm asserts at `used_w >= DEPTH-1` instead of `>= DEPTH`. The LOOK-AHEAD arm already covers the `DEPTH-1` plus a write case, so capacity is unchanged at DEPTH; the only difference is a spurious one-cycle refusal when `used_w = DEPTH-1` and nothing is being offered. It costs a stall cycle, not a slot. | needs a throughput oracle, not a value one |
| `F5` | **true equivalent** | `wr_now` loses its `clr` term while `w_ready` keeps it. The memory write lives inside the `else` branch that the `elsif clr = '1'` arm takes over, so during a clear it is not reached at all and `wr_now` has nothing to enable. | never |
| `R2` | **true equivalent** | the write reset no longer clears the synchronised read pointer. Those two flops track `rp_g` unconditionally, and the read reset holds `rp_g` at 0, so they reach 0 anyway. | never |
| `D2` | **guard removal on a conforming design** | the power-of-two DEPTH guard is deleted, and every DEPTH here is a power of two. Read it together with `D1`, which INVERTS the same guard so the correct DEPTH violates it and aborts at elaboration -- that is what proves the guard is live and correctly wired. | only with a non-conforming generic, which is a different contract |

Two survivors were CLOSED during the run rather than explained away, and both
by the same change: the capacity coverage bound moved from DEPTH to DEPTH + 2.
`G6` (the read pointer's gray encode lags by one beat) and `F3` each silently
cost one slot of capacity, which is safe but is a real regression. `G6` is now
KILLED; `F3` is not, for the reason in its row above.

### 4.6 `sim/tb_axi_rd_fsm` on the honest RTL, final (MEASURED, 0.07 s)

```
ack7: clears=11 maxout=16/16 maxlvl=79/512 err=0
ack1: clears=11 maxout=4/16  maxlvl=61/64  err=0
axi_rd_fsm: 0 errors across 2 acknowledgement latencies
PASS: tb_axi_rd_fsm
```

The two instances cover different limits ON PURPOSE: `ack1` has
MAXOUT*MAXB = 256 against DEPTH = 64, so the FIFO-space throttle binds
(61 of 64) and MAXOUT is inert (4 of 16); `ack7` is at the FK33's own
DEPTH = 512 / MAXOUT = 16, where MAXOUT*MAXB = 256 is BELOW DEPTH, so MAXOUT
binds (16 of 16) and the space throttle is inert (79 of 512).

### 4.7 `sim/mutate_axi_rd_fsm.sh`, final run (MEASURED)

```
---- class AR: address arithmetic and burst length --------------------
A1   AR     KILLED   ack1: ARLEN carries 15 beats, want min(left,MAXB) = 16   -- a full burst is MAXB-1 beats, so the bursts no longer tile the sub-region
A2   AR     SURVIVED 0 errors across 2 acknowledgement latencies              -- the address advances by a FULL burst even when the burst was short
A3   AR     KILLED   ack1: AR ADDRESS 4112 want 4352                          -- the address advances in BEATS, not bytes -- the AXI_DW scaling is dropped
A4   AR     SURVIVED 0 errors across 2 acknowledgement latencies              -- the beats-remaining counter is decremented by a full burst
A5   AR     KILLED   ack1: ARLEN carries 17 beats, want min(left,MAXB) = 16   -- arlen carries the beat count itself, not count-1
A6   AR     ABORT    bound check failure at /tmp/claude-1000/-home-orencollac -- the AR guard admits ar_left = 0, so a zero-beat burst is issued
A7   AR     SURVIVED 0 errors across 2 acknowledgement latencies              -- AR issue is no longer gated on S_RUN, so the port asks for beats while it is draining

---- class THR: the two limits this FSM exists to enforce --------------
T1   THR    ABORT    bound check failure at /tmp/claude-1000/-home-orencollac -- the throttle forgets beats ALREADY REQUESTED, which is the whole point of promised
T2   THR    KILLED   ack1: THE AR THROTTLE OVERRAN THE FIFO -- occupancy 65 w -- the throttle forgets the FIFO's own occupancy
T3   THR    KILLED   ack1: THE AR THROTTLE OVERRAN THE FIFO -- occupancy 65 w -- the throttle is one whole burst too generous
T4   THR    SURVIVED 0 errors across 2 acknowledgement latencies              -- the throttle is one beat too CONSERVATIVE (expected to survive: it costs one slot and cannot overrun)
T5   THR    KILLED   ack7: OUTSTANDING BURSTS 17 exceeds MAXOUT 16            -- the outstanding-burst limit is off by one, so MAXOUT+1 bursts are in flight
T6   THR    KILLED   ack1: THE AR THROTTLE OVERRAN THE FIFO -- occupancy 65 w -- an accepted burst no longer adds to promised
T7   THR    KILLED   ack1: J1 slow consumer STALLED -- 48 of 133 beats reques -- a retiring beat no longer removes its promise
T8   THR    SURVIVED 0 errors across 2 acknowledgement latencies              -- the negative clamp on promised is removed -- the transient the header names is then written to a 0..DEPTH+MAXB signal
T9   THR    ABORT    bound check failure at /tmp/claude-1000/-home-orencollac -- an accepted burst no longer counts as outstanding
TA   THR    ABORT    bound check failure at /tmp/claude-1000/-home-orencollac -- a burst retires on EVERY beat, not on rlast

---- class DRN: the drain that 7.7's flush rule is not sufficient without
D1   DRN    KILLED   ack1: run ROSE without a clear                           -- a start goes straight to S_RUN: no drain, no clear -- 7.7's flush alone, which the FSM's own comment calls necessary but NOT sufficient
D2   DRN    KILLED   ack7: clr ROSE with arvalid still high                   -- the drain ends without waiting for an AR already asserted to be accepted
D3   DRN    KILLED   ack7: clr ROSE with 5 bursts still outstanding -- the dr -- the drain ends without waiting for outstanding bursts to return
D4   DRN    SURVIVED 0 errors across 2 acknowledgement latencies              -- a start no longer stops the OLD job's AR issue (expected to survive: AR issue is gated on S_RUN and S_CLR2 reloads ar_left anyway)
D5   DRN    SURVIVED 0 errors across 2 acknowledgement latencies              -- a start no longer zeroes promised (expected to survive for the same reason: S_CLR2 zeroes it again)

---- class CLR: the four phases, and the order they must happen in ----
C1   CLR    KILLED   ack7: clr FELL before clr_done rose -- phase 2 was skipp -- S_CLR does not wait for the acknowledgement: phase 2 is skipped
C2   CLR    KILLED   ack7: run ROSE before clr_done FELL -- the read side may -- S_CLR2 does not wait for clr_done to FALL: the port runs while the read side may still be parked
C3   CLR    KILLED   ack1: J1 slow consumer STALLED -- 0 of 133 beats request -- the clear request is never dropped, so phase 4 never happens
C4   CLR    KILLED   ack1: AR ADDRESS 0 want 4096                             -- S_CLR2 forgets to reload the base address, so the new job reads the old one's
C5   CLR    KILLED   ack1: J1 slow consumer STALLED -- 0 of 133 beats request -- S_CLR2 forgets to reload the beat count, so the new job asks for nothing
C6   CLR    KILLED   ack1: J1 slow consumer STALLED -- 0 of 133 beats request -- the job parameters are never latched at start, so every job runs the first one's base
C7   CLR    KILLED   ack1: J1 slow consumer STALLED -- 0 of 133 beats request -- the clear is requested from S_DRAIN but the state does not move, so the request is re-issued forever
AD   PAIR   KILLED   ack7: arvalid was RAISED while run was low               -- A7 AND D4 TOGETHER: AR issue is not gated on S_RUN *and* a start no longer stops the old job.  Each is unobservable ALONE (both survive above); the pair is not

---- class RST: what the FSM comes out of reset as ---------------------
R1   RST    SURVIVED 0 errors across 2 acknowledgement latencies              -- reset enters S_CLR instead of S_IDLE -- exactly what the RTL comment says would run the port into S_RUN before any job was programmed
R2   RST    KILLED   ack1: arvalid was RAISED while run was low               -- reset leaves arv set, so an AR is offered out of reset with no job
R3   RST    KILLED   ack1: run was HIGH before any job was programmed         -- reset enters S_CLR *with the request already asserted*, which is the scenario the RTL comment describes -- unlike R1, this one really does reach S_RUN with no job

=======================================================================
kill ratio: 21 KILLED + 4 ABORT = 25 of 33;  8 SURVIVED
survivors: A2 A4 A7 T4 T8 D4 D5 R1
scratch dir with every mutant and its log: /tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/mutfsm3
```

**Survivors, every one under its own name.**

| tag | class | why it survives | closable? |
|---|---|---|---|
| `A2` | **true equivalent** | the address advances by a full burst even on a short one. `this_len /= MAXB` happens ONLY on a job's final burst -- `want = min(ar_left, MAXB)`, and `ar_left < MAXB` only at the end -- after which `ar_addr` is never read again. | never |
| `A4` | **true equivalent** | `ar_left` is decremented by MAXB rather than by `this_len`, for the same reason: it differs only on the final burst, after which it goes to a negative number instead of 0 and `ar_left > 0` is false either way. | never |
| `A7` | **redundant guard, ALONE** | AR issue is no longer gated on S_RUN. It cannot fire, because a `start` sets `ar_left <= 0` and S_CLR2 sets it back only in the same cycle it enters S_RUN. **Not equivalent in combination:** see `AD`. | closed by `AD` |
| `D4` | **redundant guard, ALONE** | a `start` no longer zeroes `ar_left`. It cannot fire, because AR issue is gated on S_RUN. The mirror image of `A7`, and the same pair closes it. | closed by `AD` |
| `D5` | **true equivalent** | a `start` no longer zeroes `promised`. S_CLR2 zeroes it again before S_RUN is entered, and nothing reads it in between. | never |
| `T4` | **conservative by one beat** | the throttle uses `<` where the design uses `<=`. It costs one slot of FIFO occupancy and cannot overrun. | needs a throughput oracle |
| `T8` | **guard against a state the drain already excludes** | the negative clamp on `promised` is removed. `pr` dips to -1 only if a beat retires in S_RUN against a zero promise count, and the drain waits for `os = 0` before the clear, so no stale burst can return after S_RUN is re-entered. The clamp is unreachable by construction on a conforming FSM. | only in combination with `D3` |
| `R1` | **the RTL comment is wrong, not the bench** | reset enters S_CLR instead of S_IDLE. `clr_r` is reset to '0' at the same time, so S_CLR waits for a `clr_done` that never arrives and the FSM sits there until the first `start`. It does NOT reach S_RUN with no job. See section 8.1; `R3` is the mutation that really does, and it is killed. | closed by `R3` |

### 4.8 Part 2: the matvec_core gate gap, and the one trace that closes it

The whole 57-row table is in the harness's own output (`bash
sim/mutate_matvec_core.sh`, now with a fourth column). What decides the gate
row is the four per-trace kill sets, DERIVED from it by counting `KILL` and
`ABRT`:

```
trace A alone kills: 36 of 57      <- what sim/regress.sh saw before this track
trace P alone kills: 40 of 57
trace S alone kills: 30 of 57
trace X alone kills: 34 of 57      <- the new row, `--trace t 6 1000 4 1`
A union X            44 of 57
A union P union S    44 of 57      <- IDENTICAL
A union P union S union X  44 of 57

blind spots of the committed gate (killed by P or S but not by A):
    A5 B10 B13 D1 D16 D18 D2 R3
of those, killed by X:  A5 B10 B13 D1 D16 D18 D2 R3   (ALL EIGHT)
of those, missed by X:  (none)
X kills nothing that A, P and S do not already kill between them.
```

**So one row, not two, and it loses nothing.** Adding
`sim/tb_matvec_core_ragsat.vhd` alongside the existing `tb_matvec_core` row
takes the gate from 36 of 57 to **44 of 57**, which is everything three
separate traces reach together.

The eight, individually, and what each one is:

| tag | what the mutation does | why the committed gate cannot see it |
|---|---|---|
| `D1` | the spec 6.2 COLUMN MASK is removed | K = 96 = 3*32, so there is not one masked column in the whole gate run |
| `D2` | the column mask is off by one at the top | same |
| `D18` | `nb_r` truncates instead of ceiling | K is an exact multiple of BLK, so there is no partial last block |
| `B13` | the emit `y_mask` admits one pad row | M = 8 and PASS 3's 64 are both tile-aligned at RI = 4, so no BFP pass has a ragged tile |
| `D16` | **`sat32` at row end is removed** | `SATEV 0`: the accumulator never approaches 2^31 |
| `B10` | `sat16` on the emitted mantissa is removed | same |
| `R3` | the `sat_event` sticky no longer excludes PARTIAL | same |
| `A5` | `sat16`'s positive rail is one low | same |

**AND THE ROW MUST BE ADDED, NOT SUBSTITUTED.** MEASURED: ten mutations that
`sim/tr.txt` kills SURVIVE trace X --

```
killed by A but NOT by X: A1 A2 A3 B4 B7 D5 D11 D14 D17 R7
```

-- for exactly the reason A-MUT recorded for trace S. The adversarial mode puts
the same number in every product, so a rounding-mode change is invisible
(everything is already at the rail) and a structural adder-tree change is
invisible by symmetry. Saturation coverage and value diversity are opposed.
A-MUT measured this for S; it is now confirmed for X, on a different shape.

**Cost, MEASURED as a gate row:** 3 s, against `tb_matvec_core`'s 1 s. Total
gate cost of this track is 3 + 1 + 0 = 4 s for three new rows.

---

## 5. Measured and REJECTED -- do not retry

- **Do NOT try to reach a DUT's internal signals with VHDL-2008 external
  names.** MEASURED on GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6), mcode backend:
  `alias ip is << signal .tb.u.p : unsigned(3 downto 0) >>;` analyses fine and
  then raises `translate_name: cannot handle IIR_KIND_EXTERNAL_SIGNAL_NAME`
  plus a GHDL bug box at elaboration. There is no way to watch the gray
  pointers, `full_r` or `used_w` from a bench on this toolchain. The only
  routes to them are a temporary probe copy of the RTL (which is what produced
  4.3) or a real debug port, and the second is an RTL change.

- **Do NOT expect a functional bench to test the GRAY CODING.** MEASURED,
  mutation `G1`: replacing BOTH `bin2gray` and `gray2bin` with the identity --
  i.e. crossing the domains with plain BINARY pointers -- survives every one of
  the eight clock ratios, including the 7000/6999 ps pair whose phase sweeps
  through every alignment. This is not a gap in this bench; it is a property of
  RTL simulation, which samples signals atomically. `G2` mutates only the
  decoder and is killed instantly, which proves the bench does watch the
  pointers. Closing `G1` needs Vivado `report_cdc` or an explicit per-bit skew
  model. The same applies to `G3`/`G4`/`C6`, which cut a 2FF synchroniser to
  1FF: an MTBF statement is not a functional one.

- **Do NOT bound the FIFO's occupancy at DEPTH.** The read side's output stage
  holds beats that have already retired `rp` but have not been consumed, so the
  real capacity is DEPTH + 2 (`do_rd` is gated on `ocnt + inflight < 2`).
  MEASURED honest maxima: 18/16, 18/16, 18/16, 18/16, 6/4, 66/64 -- DEPTH + 2
  every time. A checker written against DEPTH fires on correct RTL.

- **Do NOT assert MAXOUT coverage on an instance where MAXOUT cannot bind.**
  `rtl/axi_rd_port.vhd`'s own comment states the boundary: the AR throttle is
  against FIFO free space including beats already requested, so MAXOUT "simply
  stops being reachable once MAXOUT*MAXB > DEPTH". At the FK33's DEPTH = 512 /
  MAXB = 16 / MAXOUT = 16, MAXOUT*MAXB = 256 is BELOW DEPTH, so the SPACE
  throttle is inert there and MAXOUT is the limit; at DEPTH = 64 it is the other
  way round. MEASURED before this was understood: `ack7` reported "the modelled
  FIFO peaked at 79 of 512, so the FIFO-space throttle was never the binding
  limit" -- a true statement about a limit that instance cannot reach.

- **Do NOT model the FSM's FIFO with backpressure.** It makes the one property
  the throttle exists for untestable, because the backpressure absorbs the
  overrun. `rready` is tied high in `sim/tb_axi_rd_fsm.vhd` deliberately.

- **Do NOT read a single survivor as "this guard is dead code" when a second
  guard covers the same condition.** `A7` and `D4` each survive alone; the pair
  is killed at once (`AD`). Same shape for `T8`, whose clamp is unreachable only
  because the drain already excludes the state it guards against.

---

## 6. Measurement traps hit, including my own

**6.1 The bench that could not be quiesced.** The first version held `w_valid`
until accepted -- correct stream semantics -- and then waited for the writer to
go idle before a clear. With the FIFO full and the reader stopped, that offer
can never complete, so `stop_both` looped forever. **Seven of the eight cases
hung; the one that finished was the THROTTLED one, which by construction never
fills.** That asymmetry is what identified it. The fix is to WITHDRAW an
unaccepted offer at a controlled quiesce point, which loses nothing because no
handshake happened.

**6.2 `w_level >= occupancy` holds with ZERO slack, so sampling matters.**
`nr` lives in the read domain; read AT a write edge it returns its pre-edge
value and over-states the occupancy by one beat, which is enough to produce a
false failure on correct RTL. The checker therefore samples one delta AFTER the
write edge. DERIVED: at that point `w_level(n+1) = wp(n) - rp_seen(n) + 4` and
`occ(n+1) = wp(n) + wr(n) - nr`, and `nr >= rp_seen(n) - 3` gives the property
with `wr <= 1` to spare.

**6.3 DEPTH is the wrong capacity bound** -- see section 5.

**6.4 A clear and a reset DESTROY beats, so a global write/read accounting
check is meaningless across one.** The first version reported
`w_level 4 UNDER-STATES occupancy 16` on correct RTL for the entire window
between a clear and the next traffic phase, because the segment counters still
carried the residue the clear had thrown away. The counters are now re-zeroed
at every rebase and the property checker is parked across every destructive
window. **This is the shape of false failure that gets a good defect report
thrown away**, and it appeared in the same run as a real defect.

**6.5 `w_ready` is also low for the whole of a clear**, so counting those
cycles as full-flag stalls made the THROTTLED case report a throttle failure it
did not have (6 spurious stalls, all inside phase 4's clear).

**6.6 An AXI handshake completes at the edge where both sides are high, so the
stability check needs `arready` from the PREVIOUS edge too.** Comparing against
`arready` sampled at the current edge reports **every completed AR** as
"arvalid was WITHDRAWN without arready". Dozens of false failures on correct
RTL, on the first run of the FSM bench.

**6.7 An AR ACCEPTED while `run` is low is legal; an AR RAISED while `run` is
low is not.** AXI forbids withdrawing an asserted `arvalid`, so an AR
outstanding when a `start` arrives is allowed to complete and is drained -- the
FSM's own S_DRAIN comment says exactly that. The first version checked the
wrong one of the two, and it never fired only because no stimulus had ever had
an AR pending at a start. The moment one did (phase J9/J10, added to give
mutation `D2` teeth), it fired five times per instance on correct RTL. **A
check that has never fired is a check that has never been shown to work**, and
this one had been silently wrong since it was written an hour earlier.

**6.8 A `mutate` description in a bash harness must not contain backticks.**
Both new harnesses printed `line 296: clr: command not found` and a description
with the word silently deleted, because a backtick inside a double-quoted
string is command substitution. Cosmetic, but it corrupts the one artefact the
table exists to produce. Likewise `'"'"'` does NOT escape a quote inside a
double-quoted string -- it terminates it -- and that turned mutation `R3` into
an ANCHOR FAILED row, i.e. a mutation that tested nothing while looking like a
result.

**6.9 The trace loader spends one delta per line.** `sim/tr_ragsat.txt` is
7,805 lines against ghdl's 5000 default `--stop-delta`, so the new gate row
stopped at 205 ns having loaded nothing and was scored NOVERDICT -- which looks
like a broken bench and is a missing argument. The existing `tb_matvec_core`
row already carries `--stop-delta=1000000` for the same reason.

---

## 7. What is NOT verified

An explicit list, because a tidy conclusion that overstates the evidence is
worth less than an honest gap.

1. **Metastability, and therefore the entire reason the gray code and the 2FF
   synchronisers exist.** `G1`, `G3`, `G4` and `C6` are survivors by
   construction. Nothing in simulation can close them. **The right next step is
   `report_cdc` on a synthesised build**, plus confirming the synchroniser
   flops carry `ASYNC_REG` and that the two clocks are declared asynchronous in
   the XDC -- none of which this track looked at.

2. **`rtl/axi_rd_port.vhd` itself at `DUAL_CLK = true`.** This track benched the
   two units the port instantiates, not the port's own dual-clock generate: the
   `start` toggle synchroniser, the `run` level crossing back to the core
   domain, and the `rst` synchroniser are still covered only by
   `sim/tb_matvec_fk33_desc.vhd` at `DUAL = true`, which is a MANUAL run and not
   a gate row. **That is the obvious next item and it is not closed here.**

3. **The `base`/`n_beats` crossing.** `rtl/axi_rd_port.vhd` states that these
   are levels "held stable by the descriptor engine around `start`" and "must
   not be changed between `start` and the job completing". Nothing checks that
   the caller honours it, in either bench or in the RTL.

4. **Clock ratios and occupancy states this bench cannot reach.** Ratios: eight
   are run (3.25x each way, 1:1 coincident, 1:1 at 90 degrees, 1.00014x,
   10.33x, 2.2x, 2.4x throttled), all with a FIXED period. **A ratio that
   DRIFTS (spread spectrum, or a real MMCM's jitter) is not modelled, and
   neither is any duty cycle other than 50%.** Occupancy: the fill phase reaches
   DEPTH + 2, the drain reaches 0, and both boundaries are asserted -- but the
   FIFO is never held full for longer than a few hundred cycles, and there is
   no test of a pointer WRAP under a clear (a clear parks both pointers at 0, so
   the wrap-with-residue case does not arise).

5. **DEPTH values other than 4, 16 and 64.** The FK33 uses 512. The gate row
   does not run 512 because the fill phase would dominate the runtime; the
   properties are depth-independent, but that is an argument, not a measurement.

6. **`W` other than 32.** The FK33 uses 256. The data path is a plain vector
   copy, so this is low risk, but it is untested.

7. **Whether `full_r`'s one-cycle-stale '1' is truly unreachable in the real
   caller.** The RTL says the AR throttle exists "precisely so the FIFO never
   reaches DEPTH", and the throttled case here MEASURED `wstall = 0` over 762
   writes, which supports it at DEPTH = 16. It is not proved at the FK33's
   DEPTH = 512 / MAXB = 16 / MAXOUT = 16.

8. **Timing.** `L3` (the combinational `w_level`) is a survivor and always will
   be: it is a 123.88 MHz question, and only STA answers it.

9. **No hardware was touched.** Nothing in this file has been observed on the
   card.

---

## 8. Two RTL comments the measurements do not support

Recorded as corrections to the RTL's prose, not as defects. Where a document
and the RTL disagree, the RTL wins -- but here the RTL's COMMENT and the RTL's
BEHAVIOUR disagree, and the behaviour wins.

**8.1 `rtl/axi_rd_fsm.vhd`'s reset comment overstates its case.** It says the
reset enters S_IDLE "not S_CLR: both FIFO flavours clear from their own reset,
so the handshake has nothing to do here, and entering it would run the port
into S_RUN before any job was programmed." MEASURED (mutation `R1`): entering
S_CLR out of reset does NOT run the port into S_RUN. `clr_r` is reset to '0' at
the same time, so S_CLR waits for a `clr_done` that never comes and the FSM
sits there harmlessly until the first `start` moves it to S_DRAIN. `R1`
survives. The comment's scenario requires the reset to enter S_CLR **with the
request already asserted**, which is mutation `R3` -- and that one IS killed, by
the new "run was HIGH before any job was programmed" check. So the concern is
real but its stated mechanism is not.

**8.2 `rtl/async_fifo.vhd`'s `OUT_MARGIN` default of 3 is one more than the
stage can hold.** The generic's comment says "3 is exactly that stage's
capacity". DERIVED from `do_rd`'s own gate `ocnt + inflight < 2`: the read side
holds at most TWO beats outside the memory, not three. MEASURED: peak occupancy
is DEPTH + 2 on every ratio and every depth. The margin is therefore one beat
more conservative than described, which is the safe direction and costs one
slot of throttled capacity. Not changed -- `LVL_MARGIN` in
`rtl/axi_rd_port.vhd` is passed to both the FIFO and the FSM precisely so they
cannot drift apart, and 3 bounds `stream_fifo`'s `ocnt + inflight` as well.

---

## 9. Corrections

None yet. Append dated CORRECTION sections here rather than editing history.
