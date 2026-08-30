# A7: the dual-clock run gate, and what is actually wrong with it

**Date:** 2026-08-29
**Track:** A7, following TRACK ASURV (`028829e`, `0d14a70`)
**Baseline:** `0d14a70`
**Tools:** GHDL 1.0.0 mcode, `sim/regress.sh`, `sim/mutate_axi_rd_port.sh`,
`sim/mutate_axi_rd_port_dual.sh`. No hardware. No Vivado. Nothing under
`hw/fk33/` was executed; two files there were READ and neither was edited.
**Machine at start:** MEASURED `df -h /` 91% used, 120 G free; `/mnt/storage`
56%, 387 G free; `free -g` 31 G total / 26 G available / 5 G swap in use;
`uptime` load average 4.57 5.52 7.14 at 22:54.

---

## 1. The question, verbatim

> TRACK ASURV found this and reported it without fixing it:
>
> > **`A7` is a real defect under `DUAL_CLK` and nothing catches it** -- `run_c`
> > is two cycles late there, so an ungated `f_qr` loses words.
> > `mutate_axi_rd_port_dual`'s `P8` survives all three ratios.
>
> **I have since MEASURED that the shipping build uses it:**
> `hw/fk33/rtl/fk33_engine.vhd:1171` and its generator
> `hw/fk33/gen_fk33_engine.py:532` both set `DUAL_CLK => true`. So this is not a
> latent configuration -- **it is in the bitstream currently loaded on card 1.**
>
> **Tonight I ran 30+ jobs through that bitstream and every one was bit-exact
> against `ref/matvec_int4.c`** [...] **So either the defect cannot manifest in
> the configuration the card runs, or my 30+ jobs never reached the condition
> that triggers it.** [...] **Do not assume the reassuring branch.**

Plus, mid-track, from the coordinator:

> A gate row is failing on a file you own, at the exact line ASURV flagged [...]
> `OVERALL PASS 105 FAIL 1` on **`sim:tb_matvec_fk33_desc`**, with a **bound
> check in `rtl/axi_rd_fsm.vhd:231`** -- your file. [...] If it turns out to be
> the same root cause as `A7`, that is a significantly bigger finding than
> either alone.

---

## 2. The answer, up front

**`A7` is not in the shipping RTL, and as a hypothetical defect it is not a
defect at all. ASURV's finding 3 is WITHDRAWN, with the RTL argument and the
measurement that withdraw it. But the neighbourhood ASURV pointed at contains
TWO other things that ARE in the bitstream and neither is the one that was
reported: a measured leak whose harm is currently held off only by an invariant
nothing asserts, and a counter underflow that is a silent permanent stall in
hardware. Both are fixed here.**

**Nothing here says the card computed anything wrong.** One of the two is a
hang, not a wrong answer, and it needs a reset mid-job to reach; the other needs
a `start` onto a non-empty FIFO, which the shipping flow does not produce
(section 4). Read the two as "the margin was thinner than anyone had written
down", not as "your results are suspect".

Taking the three questions in the order they matter:

**(a) Can `A7` manifest on the card? No, and not for the reason anyone assumed.**
`A7`/`P8` is a MUTATION -- `rtl/axi_rd_port.vhd` gates `f_qr` on `run_c` and
always has. As a hypothetical, its harm requires `f_qv = '1'` while `run_c` is
still low at the RISE of a job. That is unreachable **at every clock ratio**, by
construction: both are two-flop core-domain synchronisers, `run_c`'s starts from
`run_f` at the aclk edge entering `S_RUN`, and `f_qv`'s starts from the FIFO's
write pointer, which cannot move until the first R beat lands at least two aclk
edges LATER (`rtl/async_fifo.vhd:360` syncs `wp_g` on `rclk`, and
`rtl/async_fifo.vhd:353` adds an output-register stage on top). `run_c` therefore
rises at or before `f_qv`, always. **MEASURED**: the exact `0d14a70` RTL plus
`P8`, run against a deliberately absurd **20:1** aclk:clk ratio, produced ZERO
value errors (control `F` in section 5.4). The FK33's own ratio is 250 MHz : 200
MHz = **1.25:1**, nowhere near even the ratio that was already not enough.

**Your 30+ bit-exact jobs are not narrowed by `A7`.** No correction is needed to
`docs/debugging/2026-08-29_first-arithmetic-on-the-silicon.md` on this account.

**(b) What is real at that gate is the FALLING edge, not the rising one, and it
IS in the bitstream.** Under `DUAL_CLK` the output gate stays OPEN for
roughly five core cycles after a core-domain `start`, because `run_f` does not
drop until the toggle has crossed and `run_s2` not until two core edges after
that. In the single-clock configuration the gate shuts on the cycle after
`start`. **MEASURED at `0d14a70`**: 2, 3 and 4 beats **of an abandoned job were
delivered to the consumer** at the three clock ratios. That is a delivered word,
not an internal transient. Fixed by closing the gate on the core clock
(`abort_c`); residue is now 0 at all four ratios.

**Whether it can do damage today is a separate question and the answer is no,
for a reason nothing in the tree states.** The leak needs a FIFO that is not
empty when `start` fires, and in the shipping flow every job either drains its
FIFOs exactly or ends in `S_ERR`, which is exit-by-reset-only. Section 4 works
that through, and names the one open item that would break it. So the `abort_c`
change is **defence in depth against a measured leak**, not the repair of an
observed miscomputation, and I would rather say that than let a green fix imply
a red bug.

**(c) The gate row failing at `rtl/axi_rd_fsm.vhd:231` is a THIRD thing, it is
real, it is a hardware hang and not just a simulation trap, and it is
independent of `A7`.** Line 231 is `outst <= os`, and the bound violation is
`os = -1`: an `rlast` beat retiring a burst the FSM does not think is
outstanding. A conforming AXI slave produces exactly that after a local reset,
because **a reset cannot cancel an outstanding read** and the FSM zeroes `outst`
in its reset branch. In simulation that is a bound check; **in synthesis there is
no bound check** -- `outst` is `clog2(MAXOUT+2)` bits, `-1` wraps to all-ones,
the `os < MAXOUT` guard then reads FALSE, and **that port issues no further AR
for the rest of time**. Fixed by clamping `os` at 0, symmetrically with the
`pr` clamp that was already there on the line above.

**Is (c) the same root cause as `A7`? No.** They share a neighbourhood -- both
concern what the port does across an abort -- and nothing more. `A7` is about the
core-domain output gate; (c) is about the AXI-domain burst counter. I am saying
so plainly rather than claiming the bigger finding.

**Answer to the coordinator's gate question: I did not reproduce the gate ROW,
but I did reproduce the MECHANISM, deterministically, and the clamp fixes it.**
`sim/regress.sh --only tb_matvec_fk33_desc` at `0d14a70` in the shared dirty
tree gives `OVERALL PASS 3 FAIL 0 / REGRESSION: PASS` (section 5.8). Separately,
controls `H`/`I` (section 5.9) make the bench's slave NOT reset-aware and cut the
reset to one core cycle, which is what a real AXI slave on a separate reset net
looks like: **without the clamp,
`bound check failure at ...axi_rd_fsm.vhd:250`, which is `outst <= os` -- the
same statement as the gate's `:231`. With the clamp, PASS.**

| | before | after |
|---|---|---|
| `sim/mutate_axi_rd_port_dual.sh` | 6 caught, **14 survived** (of 20) | 12 caught, **10 survived** (of 22) |
| `sim/mutate_axi_rd_port.sh` | 13 caught, **9 survived** (of 22) | 14 caught, **8 survived** (of 22) |
| dual-bench clock ratios | 3 | 4 (`awild`, 20:1) |
| honest residue past the run gate | 2 / 3 / 4 beats | **0 / 0 / 0 / 0** |
| `rtl/axi_rd_fsm.vhd:231` on a stray `rlast` | bound check / silent AR hang | clamped |

---

## 3. The procedure, in the order it was run

Each step states what it controls for.

1. **Read the RTL before believing the report.** `rtl/axi_rd_port.vhd:197` gates `f_qr` on `run_c`, and
   `rtl/axi_rd_port.vhd:195` gates `q_valid` on the same level. `A7` is a mutation row, not shipped code. *Controls for spending a
   track fixing a defect that does not exist.* This is also the correction to
   the brief: the brief's premise ("it is in the bitstream currently loaded")
   is true of `DUAL_CLK`, not of `A7`.
2. **Reproduce the dual mutation table at HEAD before touching anything.**
   6 caught / 14 survived, control PASSES, honest residue 2/3/4. *Controls for
   working against a table that has already moved, and against a base that does
   not work -- which scores everything CAUGHT.*
3. **Ask what would have to be true for `A7` to lose a word, then look for the
   structural reason it cannot be.** This is what produced the answer, and it
   cost two greps of `rtl/async_fifo.vhd`. *Controls for the failure mode where a
   stimulus hunt runs for hours against an equivalent mutant.*
4. **Then test the structural argument at a ratio far past anything real.**
   `awild` = aclk 0.5 ns against clk 10.0 ns. *Controls for an argument that is
   merely plausible.* A ratio that beats the card's 1.25:1 by 16x and still shows
   nothing is worth more than the argument alone.
5. **Trace the FALLING edge into the actual consumer, not just to the port
   boundary.** `rtl/weight_streamer.vhd:292` clears the scale holding register's
   valid bit on `start`, and `s_take` (`rtl/weight_streamer.vhd:279`) is then
   `s_allv` with no downstream ready term in it at all. *Controls for calling a port-level leak harmless because the
   port's own bench tolerates it.*
6. **Establish WHY it is harmless today before fixing it, so the fix is not sold
   as a bug fix.** The FIFOs are provably empty at every `start` the shipping
   flow reaches -- see section 4. *Controls for overstating the finding.*
7. **Run every kill with an attribution control** -- the same mutant with the new
   check disabled, and where two things changed, with each one reverted
   separately. Seven controls, section 5.4. *Controls for the GRAY1 failure
   ASURV recorded.*
8. **Confirm the single-clock path is untouched by construction, then by the
   gate.** The executable diff is three items and one of them is inside
   `g_dc`, section 5.6.

---

## 4. Why the falling-edge leak is harmless TODAY, stated as an argument that
can be checked

This is the part that decides whether the fix is a bug fix or defence in depth.
It is the second, and I want that on the record.

The leak needs a FIFO with words in it at the moment `start` is asserted. In the
shipping flow there are exactly three consumers of `axi_rd_port`, and each one
empties its FIFO exactly:

* **the descriptor port** (`rtl/matvec_int4_desc_axi.vhd:521`). `d_qr` is high
  for the whole of `S_R` and the fetch is exactly `DBEATS` beats, all of which
  `S_R` captures before leaving.
* **the `NPORTS_W` weight ports.** `w_beats = tiles*nblk` per sub-region
  (`rtl/matvec_int4_desc_axi.vhd:260`, and `S_SHAPE` REFUSES a descriptor whose
  `w_beats` is not exactly that), and `pop_w` fires once per tile word, so pops
  equal beats.
* **the `NPORTS_S` scale ports.** `s_beats = ceil(tiles*nblk / GRP)`, and the
  core pops one superword per `GRP` chunks, so again pops equal beats. A trailing
  partial superword leaves `s_hv = '1'` with unused chunks, but the FIFO itself
  is empty.

and the only way to leave a job WITHOUT emptying them is an error, every one of
which lands in `S_ERR`, which `rtl/matvec_int4_desc_axi.vhd:890` documents as
exit-by-reset-only -- and a reset clears the FIFOs.

**So the invariant is: at every `start` the shipping flow reaches, the FIFO is
empty. Nothing asserts it, it is not stated anywhere, and one open item would
break it the moment it is answered "yes"** -- ASURV's *"whether subsystem A can
be re-armed after `EC_CORE`"*. `EC_CORE` is raised in `S_WAIT`
(`rtl/matvec_int4_desc_axi.vhd:875`), i.e. **after** `core_start`, so it is the
one error that leaves the streamer mid-fetch with beats resident. Re-arming
without a reset makes the leak live on the next descriptor, and the damage would
be in the SCALES: `s_hv` is cleared by `start` and `s_take` has no downstream
ready term, so a residue superword is latched into `s_hold` and every scale of
the new job is shifted by one superword. That is a wrong-numbers failure, not a
hang, and no existing check would see it.

**MEASURED, not assumed, for `run_c`'s late fall:** the numbers in section 5.2
are beats the bench's own consumer accepted, from a job that had been abandoned.

---

## 5. The evidence, as raw output

### 5.1 The shipping configuration and its clocks

```
$ grep -n "DUAL_CLK" hw/fk33/rtl/fk33_engine.vhd
1171:      DUAL_CLK      => true,

hw/fk33/gen_pcieep.py:291:#   HBM AXI  xdma/axi_aclk, 250 MHz, the same net that already clocks SAXI_00
hw/fk33/gen_pcieep.py:294:#   core     clk_wiz_0/clk_out3, 200 MHz.
```

DERIVED: aclk:clk = 250:200 = **1.25**. `run_c` rises two core cycles = 10.0 ns
= 2.5 aclk cycles after `run_f`. HBM read latency is tens of aclk cycles, so the
FIFO is empty throughout that window by an enormous margin -- but the structural
argument in section 2(a) is the one that does not depend on this number.

### 5.2 The dual bench, honest RTL, BEFORE the fix (`0d14a70`)

```
anear: beats=384 stall=183 bp=1431 rrefuse=0 residue=3 err=0
aslow: beats=364 stall=260 bp=1417 rrefuse=0 residue=4 err=0
afast: beats=388 stall=164 bp=1431 rrefuse=0 residue=2 err=0
axi_rd_port_dual: 0 errors across 3 clock ratios
PASS: tb_axi_rd_port_dual
```

`residue` = beats of the ABANDONED job that the consumer accepted after the
`start`. The old bound was `RES_MAX = 8`, so this passed.

### 5.3 The dual bench, honest RTL, AFTER the fix

```
anear: beats=381 stall=186 bp=1431 rrefuse=0 residue=0 resarm_qv='1' err=0
aslow: beats=360 stall=264 bp=1417 rrefuse=0 residue=0 resarm_qv='1' err=0
afast: beats=386 stall=166 bp=1431 rrefuse=0 residue=0 resarm_qv='1' err=0
awild: beats=394 stall=132 bp=1434 rrefuse=0 residue=0 resarm_qv='1' err=0
axi_rd_port_dual: 0 errors across 4 clock ratios
PASS: tb_axi_rd_port_dual
```

`resarm_qv='1'` is the NON-VACUITY WITNESS and it replaces the old
`res_cnt_o = 0` coverage assert, which the fix would otherwise have made
self-defeating: with residue legitimately 0, "residue was found" can no longer
prove the FIFO held anything. What is asserted instead is that the port was
OFFERING a beat on the edge the abandon was armed -- the same fact one step
earlier, and one that does not move when the gate is tightened.

### 5.4 The seven attribution controls

Each varies ONE thing against the committed tree.

```
G_honest_ctl    SURVIVED/PASS      residue 0/0/0/0   -- pure control
E_honest_prefix NOT-PASS           residue 2/3/4/2   -- honest RTL, run_c reverted to 0d14a70
A_p8_noassert   SURVIVED/PASS      residue 0/0/0/0   -- P8 + fix, ASSERT DISABLED
B_p8_prefix     ABORT(rtl assert)                    -- P8 + assert, run_c reverted to 0d14a70
C_p7_oldbound   SURVIVED/PASS      residue 5/6/7/3   -- P7 + fix, RES_MAX back to 8
D_pg_no_awild   SURVIVED/PASS      residue 0/0/0     -- PG + fix, awild ratio removed
F_p8_0d14a70    NOT-PASS           residue 2/3/4/2   -- EXACTLY 0d14a70 + P8, no assert
```

Read them as five separate statements:

* **`A` says the assert is what kills `P8`, not the fix.** Disable the assert and
  `P8` walks again. So the kill is attributed to the detector.
* **`B` says the assert ALONE would have killed `A7` at `0d14a70`.** This is
  ASURV's own correction of ACOV, arriving a second time: *the stimulus had been
  right all along; the detector was missing.* Three benches had `P8` in front of
  them and none had anything that could see it.
* **`F` is the important NEGATIVE and it is why section 2(a) reads the way it
  does.** `F` is the shipped RTL plus `P8` with no new detector at all, at a 20:1
  ratio. The value oracle -- which prints `BEAT got X want Y` on a dropped,
  duplicated, reordered or wrong-address beat -- **said nothing**. The only error
  is my own new residue bound, which is about the falling edge. **`P8` loses no
  words at any ratio.** ASURV's *"an ungated `f_qr` loses words"* is withdrawn.
* **`C` says `P7`'s new kill belongs to the tightened `RES_MAX`,** which in turn
  is only tightenable because of the fix: at `RES_MAX = 8`, `P7` measures 5/6/7/3
  and survives, which is exactly what it did at `0d14a70`.
* **`D` says `PG`'s new kill belongs to the `awild` ratio and to nothing else.**
  Remove the fourth ratio and the `OUT_MARGIN`-vs-FSM mismatch is invisible
  again. That kill was a side effect of a stimulus added for another reason.

`E` is the fix's own teeth-check performed on the HONEST design, and it is the
measurement that the shipped RTL leaks: revert `run_c` and the honest port fails
the new bound at all four ratios.

### 5.5 The dual mutation table, before and after

Before (`0d14a70`), 20 rows:

```
kill ratio: 6 KILLED + 0 ABORT = 6 of 20;  14 SURVIVED
survivors: P1 P5 P6 P7 P8 P9 PA PB PC PD PE PP PF PG
```

After, 22 rows (`PK` and `PL` are new, and are the fix's own teeth-check):

```
P7   RUN    KILLED   anear: RESIDUE 6 beats of the ABANDONED job leaked past the
P8   RUN    ABORT    axi_rd_port: the FIFO was POPPED while the stream output was
PK   RUN    KILLED   anear: RESIDUE 3 beats of the ABANDONED job leaked past the
PL   RUN    KILLED   anear: J1 STALLED -- 20 of 20 beats never arrived
PF   GATE   KILLED   anear: RESIDUE 2 beats of the ABANDONED job leaked past the
PG   WIRE   KILLED   awild: THE PORT REFUSED AN OFFERED R BEAT on 39 cycles
kill ratio: 11 KILLED + 1 ABORT = 12 of 22;  10 SURVIVED
survivors: P1 P5 P6 P9 PA PB PC PD PE PP
```

**The ten survivors are the resolution floor and are not to be deleted.** `P1`,
`P5`, `P6`, `P9`, `PA`, `PB` all cut a synchroniser down and survive because an
RTL simulator samples atomically -- `sim/cdc_teeth.sh` is the flow that reaches
them, not this one. `PC`, `PD`, `PE`, `PP` all change behaviour only on a cycle
where the port REFUSES an offered R beat, and `rrefuse=0` on every run says that
cycle does not exist on a conforming design; `PJ` is their teeth-check and it
still bites.

### 5.6 The executable diff, comments stripped

```
+        if os < 0 then os := 0; end if;      -- nor do retired bursts        [axi_rd_fsm]
+  gate_chk : process(clk) ... assert not (f_qv='1' and f_qr='1' and run_c='0')  [simulation only]
+    signal abort_c : std_logic := '0';                                       [inside g_dc]
-    run_c <= run_s2;
+    run_c <= run_s2 and not abort_c;                                         [inside g_dc]
-        if rst = '1' then run_s1 <= '0'; run_s2 <= '0';
+        if rst = '1' then run_s1 <= '0'; run_s2 <= '0'; abort_c <= '0';
+          if start = '1' then abort_c <= '1';
+          elsif run_s2 = '0' then abort_c <= '0';
+          end if;                                                            [inside g_dc]
```

**Single-clock bit-exactness is structural, not measured-and-hoped:** three of
the five hunks are inside `g_dc`, which `DUAL_CLK = false` does not elaborate;
the assert is simulation-only and is a tautology of two lines that did not
change; and the `os` clamp cannot fire on a trace where `rlast` only ever
retires a burst the FSM issued. Everything in every gate row and every AXU3EG
build takes `g_sc`.

### 5.6b The full gate, unfiltered last OVERALL line

```
 OVERALL     PASS 106   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 REGRESSION: PASS
```

`BASELINE_PASS` is 98 (TRACK FLOOR, `b60591d`); this run is 106 and adds no row.
The two rows that matter most here both PASS: **`sim:tb_matvec_fk33_desc`**, the
row DISTRAM's 22:23 gate reported failing, and **`sim:tb_matvec_fk33_desc_dual`**,
which is `DUAL_CLK = true` end to end through the descriptor engine, the weight
streamer and the core -- the closest thing in the tree to the card, and the row
that exercises `abort_c` and the new assert in the shipping configuration.

MEASURED runtimes, third field of the result rows: `sim:tb_axi_rd_port` 0 s,
`sim:tb_axi_rd_port_dual` **1 s** (the fourth clock ratio costs about a second),
`sim:tb_matvec_fk33_desc` 50 s, `sim:tb_matvec_fk33_desc_dual` 56 s.

### 5.7 The SINGLE-clock mutation table also moves, and only by one row

```
before (ASURV, 0d14a70):  22 mutations: 9 KILLED, 4 ABORT (13 caught), 9 SURVIVED, 0 VOID
after:                    22 mutations: 9 KILLED, 5 ABORT (14 caught), 8 SURVIVED, 0 VOID

A7   RUN   ABORT    axi_rd_port: the FIFO was POPPED while the stream output
                    by[ gate deep tight brim brim2 starve]
 SURVIVORS: A4 A5 A8 A9 B1 B7 C3 C4
```

**Exactly one row moved, and I want it classified honestly.** ASURV proved `A7`
is an OUTPUT-equivalent mutant in `g_sc` -- the words it pops are residue the
flush is about to discard, and `rtl/stream_fifo.vhd:99` makes a pop on an empty
FIFO a no-op. That proof still stands; I did not overturn it. What the new
assert does is catch an output-equivalent mutant on an INTERNAL invariant, at
all six configurations. That is a real strengthening, it is NOT the same thing
as finding a defect, and the row should be read that way. No other row moved in
either direction, which is the attribution: the assert is specific to the one
line it is about.

### 5.8 The gate row the coordinator asked about

```
$ REGRESS_SCRATCH=... bash sim/regress.sh --only tb_matvec_fk33_desc --keep
 OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

at `0d14a70` in the shared dirty working tree, i.e. the same tree DISTRAM's
22:23 full gate failed in. **The row is not reproduced.** The mechanism is,
below.

### 5.9 The `os` underflow, reproduced from first principles (controls `H`, `I`)

ONE thing is varied against the committed tree in `I`, and two in `H`. The bench
copy has the slave's `if rst = '1' then ... qc := 0; busy := false; end if;`
block DELETED, so bursts it has already queued keep returning across the port's
local reset -- which is what the FK33's HBM does, since the streamer's `rst` is
`core_aresetn` and the slave is reset by the XDMA's `axi_aresetn`. J7's reset
hold is cut from 20 core cycles to 1.

```
--- H_stray_noclamp   (the clamp line REMOVED)     rc=1
/usr/bin/ghdl-mcode:error: bound check failure at .../axi_rd_fsm.vhd:250
/usr/bin/ghdl-mcode:error: simulation failed
        # line 250 in that copy is `outst    <= os;`

--- I_stray_clamp     (the committed clamp)        rc=0
PASS: tb_axi_rd_port_dual
```

`axi_rd_fsm.vhd:250` in the copy is `outst <= os;`. In the pre-fix file that is
`:231` -- the line DISTRAM's gate named. Same statement, same violation,
`os = -1`.

---

## 6. Measured and REJECTED -- do not retry

* **"`A7`/`P8` loses words under `DUAL_CLK`."** REJECTED. Control `F`: the exact
  `0d14a70` RTL plus `P8` at a **20:1** aclk:clk ratio produced zero value
  errors. The structural reason is in section 2(a) and it holds at every ratio.
  Do not go looking for a clock ratio that makes it bite; there isn't one.
  ASURV's finding 3 is withdrawn to this extent, and the withdrawal is recorded
  in `sim/mutate_axi_rd_port_dual.sh`'s header rather than by editing ASURV's
  document.
* **"Kill `P8` with a value-level stimulus."** REJECTED, and this is the same
  statement from the other side. There is no stimulus, because the mutation is
  behaviourally different but harmless. The right closure is the invariant, and
  the invariant is a tautology of the correct design -- which is what makes it
  worth asserting rather than a reason to discard it.
* **"The `os = -1` bound check is a bench artefact."** REJECTED. It is reachable
  from a conforming AXI slave (a reset cannot cancel an outstanding read) and in
  synthesis it is not a trap but a silent permanent AR stall. ASURV's 512-cycle
  inter-case reset in `sim/tb_matvec_fk33_desc.vhd` is a valid bench workaround
  and should stay, but it is not the fix.
* **"Preserve `outst`/`arv` across `rst` so `S_DRAIN` waits for the stray
  beats."** REJECTED for now, and this one is a genuine fork rather than a dead
  end -- see the open item in section 8. It is correct if the slave does NOT
  share the reset (the FK33 case: `core_aresetn` vs the XDMA's `axi_aresetn`)
  and it HANGS if the slave does (the case `sim/tb_axi_rd_port_dual.vhd`'s J7
  models, where the slave resets alongside). Not a change to make on one track's
  judgement.
* **"Add the fourth clock ratio only for `P8`."** It did not help `P8` at all
  (control `F`). It killed `PG`, which nothing had ever killed. Keep it for that
  reason, not the one it was added for.

---

## 7. Measurement traps hit, including my own

* **The FIRST version of controls `H`/`I` passed BOTH arms and proved nothing.**
  I kept the bench's own 20-core-cycle reset hold; every outstanding burst had
  drained before the reset was released, so no stray beat existed to underflow
  anything and the unclamped arm passed cleanly. A control that passes on the
  arm you expect to fail is not a negative result, it is a stimulus that did not
  reach the condition -- and it looks identical to "the mechanism is not real"
  until you check what the stimulus actually did. Cutting the hold to one cycle
  is what made it bite.
* **The one I walked into: I had the fix designed before I had the negative.**
  I read ASURV's "real defect under `DUAL_CLK`", derived the rising-edge harm,
  designed a gate change for it, and only then ran the 20:1 control that says
  the rising-edge harm does not exist. The fix survives because a DIFFERENT
  measurement (the falling edge, 2/3/4 delivered beats) justifies it -- but if
  that measurement had come out zero as well I would have been holding a fix
  with no defect under it, having already written the reasons. This is ASURV's
  own trap (*"I had the check written before I swept the control"*) with the
  roles of check and fix exchanged. **Run the control that could make the work
  unnecessary FIRST.**
* **The mutation scorer had `3` hardcoded** in `axi_rd_port_dual: (\d+) errors
  across 3 clock ratios`. Adding a fourth ratio would have scored all 22 rows
  `ABORT|no verdict line and no error at all` -- a table reading 22 of 22 caught,
  which is exactly the shape of a spectacular result. Now read out of the bench.
* **A mutation anchor is a silent no-op when the RTL moves under it.** Changing
  `run_c <= run_s2;` broke the `P5` and `P6` anchors; the script prints
  `ANCHOR FAILED -- tested nothing` rather than failing, which is the right
  behaviour and is easy to skim past in a 22-row table.
* **`nohup ... &` from a tool-invoked shell did NOT survive**: the first full
  gate reached 82 of 106 result files and then died with the shell. `setsid` was
  needed. A truncated gate leaves a scratch directory that looks like a
  completed run.
* **The old coverage assert would have inverted under the fix.** `res_cnt_o = 0`
  meant "tested vacuously" before and means "correct" after. A coverage check
  written against a quantity the fix drives to zero fails closed in the wrong
  direction; it had to be re-expressed against something upstream of the change.

---

## 8. Open, not yet answered

* **Stray R beats after a reset can still be written into the NEXT job's FIFO.**
  The `os` clamp stops the counter underflow and the AR stall; it does NOT stop
  the beats. After a reset with bursts outstanding, `S_DRAIN`'s exit condition
  (`arv = '0' and os = 0`) is satisfied immediately, the clear runs, and beats
  from the pre-reset bursts then land in `S_RUN` and are written to the FIFO as
  if they were the new job's. That is silent misalignment. On the FK33 the
  streamer's `rst` is `core_aresetn` while the HBM slave is reset by the XDMA's
  `axi_aresetn`, so the two are NOT the same net and the case is reachable.
  **This is a design decision, not a fix, and I stopped rather than make it.**
  The options and their costs are in section 6.
* **Whether subsystem A can be re-armed after `EC_CORE` without a reset.**
  Unchanged from ASURV. It now has a second reason to matter: it is the one path
  that would make section 4's unasserted "the FIFO is empty at `start`"
  invariant false. The `abort_c` fix removes the consequence in the port; it
  does not answer the question.
* **The `tb_matvec_fk33_desc` gate failure is not reproduced and therefore not
  explained.** I have a mechanism that fits the line number and a fix that
  removes it, and no reproduction. Do not treat the clamp as confirmed to be the
  cause.
* **`abort_c` has not been through synthesis, and `sim/cdc_teeth.sh` has not
  been re-run.** DERIVED cost: one FF and one LUT per port, 28 ports on the
  FK33. DERIVED, not measured: `abort_c` is set by a core-domain signal and
  released by `run_s2`, which is already synchronised, so it introduces no new
  clock crossing and `report_cdc`'s summary should be unchanged. **No Vivado
  was run on this track and neither claim is MEASURED.**
* **Nothing here was run on hardware.** The card experiment that would settle
  section 8's first item is written out in section 9.

---

## 8b. The gate row I would add, handed off rather than added

TRACK FLOOR owns `sim/regress.sh` and a new `sim/tb_*.vhd` becomes a gate row
whether or not anyone meant it to, so I did not create the file. What I ran as
controls `H`/`I` should be a permanent row:

**`sim/tb_axi_rd_port_stray.vhd`** -- `axi_rd_port` at `DUAL_CLK = true` against
a slave that is **deliberately NOT reset-aware**, with a ONE-core-cycle reset
asserted while bursts are outstanding, followed by a further job whose value
oracle must still hold. It is `sim/tb_axi_rd_port_dual.vhd` with two edits (both
shown in section 5.9's harness) and it takes about one second.

* It fails at `rtl/axi_rd_fsm.vhd`'s `outst <= os` without the clamp, so it is
  the row that would have caught tonight's gate failure at its own level rather
  than four layers up in `tb_matvec_fk33_desc`.
* Its value oracle is what would catch the OPEN item in section 8 -- stray beats
  written into the next job's FIFO -- the moment anyone changes the reset
  handling. Today it passes, so it would go in green.
* **`BASELINE_PASS` would go 98 -> 99.**

I have NOT created it. Whoever picks it up should note that the interesting
stimulus is the one-cycle reset: with the bench's own 20-cycle hold, every
outstanding burst drains before the release and the row passes vacuously (see
section 7).

---

## 9. The card experiment I am asking for

**Purpose: decide whether the stray-beat path in section 8 is real on silicon,
without needing an answer to the re-arm question.** It is a hang/misalignment
test, not an arithmetic one, and it needs no new gateware.

Precondition: the current bitstream, weights resident, and a job you have
already run bit-exact so you have a known-good reference output.

1. Run one known-good job. Record the output and confirm bit-exact. *(Control:
   the board is healthy before the experiment.)*
2. Start a LONG job -- the largest `(M, K)` in the 9B set, so the weight
   streamer is certainly mid-fetch -- and **while `busy` is still high**, assert
   the engine reset (`core_aresetn` via whatever `fk33ctl.py` exposes; if
   nothing does, this experiment is blocked and that is itself worth knowing).
3. Deassert the reset, wait 1 ms, and run the SAME known-good job from step 1.
4. Compare against step 1's output.

   * **bit-exact** -> the stray beats either did not arrive or were discarded;
     the path is not reachable this way.
   * **wrong numbers** -> the misalignment in section 8 is real and the fix is
     not optional.
   * **never completes / `busy` stuck high** -> that is the `outst` underflow
     stall, and it would confirm section 2(c) on silicon. Note this outcome is
     what the committed clamp removes, so it can only be observed on the
     CURRENTLY LOADED bitstream, before any rebuild.
5. Repeat step 2-4 twice more. The window is a few tens of nanoseconds wide
   against a host-timed reset, so a single negative is weak evidence.

**Do not rebuild the bitstream before running this.** The interesting outcome in
step 4 is only observable on the build that is loaded now.

---

## 10. Corrections to the brief

* **"`A7` is a defect that is live in the bitstream on the card."** Withdrawn.
  `DUAL_CLK = true` is live; `A7` is a mutation of a line that is correct in the
  shipped RTL, and section 2(a) shows it would be harmless even if applied.
* **ASURV's finding 3, *"an ungated `f_qr` pops those words while `q_valid` is
  suppressed and they are lost"*.** Withdrawn as to "lost". The pops are real and
  the mutation is not equivalent, but the popped words are residue the flush is
  about to discard, and no word of a live job can be popped -- `f_qv` cannot lead
  `run_c`. ASURV's document is left standing; this section is the correction.
* **"`rtl/axi_rd_port.vhd`'s own header argues 'late is the safe direction' for
  `q_valid`, and that argument holds only because `f_qr` carries the same late
  gate."** Half right, and the wrong half is the interesting one. The rise is
  safe because `f_qv` cannot lead `run_c`, not because `f_qr` carries the gate.
  The FALL is what the shared gate was actually protecting, and it was
  protecting it badly.
