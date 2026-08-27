# Subsystem B: an interface audit for the three defect classes found on 2026-08-27

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. Read-and-reason audit of the RTL as it
stands; no RTL was modified and no Vivado was run.
**Tools:** GHDL 1.0.0 mcode (`ghdl -r` direct, `--stop-time` on every run) for
the one simulated demonstration. Everything else is source reading.

## The question

Two integration defects were found this week, both in interfaces rather than
arithmetic, both silent, both invisible to unit-level bit-exactness:

* `gdn_emit_chain` / `rmsnorm_bf`: an unlatched `w_mant` read across a span
  longer than the producer's own block boundary
  (`2026-08-27_gdn-emit-chain-w-latch.md`).
* `gdn_head_emit`: a one-cycle `done` pulse with no handshake, silently
  discarding whole heads (`2026-08-27_gdn-head-emit-done-pulse.md`).

Plus a third, related shape already named in those notes: `gdn_recur_pipe` has
no ready input, so a consumer whose ready falls under it loses data rather than
delaying it.

The question here: **are there more instances of the same three classes
anywhere else in subsystem B's RTL?**

## The answer

**3 CONFIRMED, 5 PLAUSIBLE.** The rest of what was examined is
safe-by-construction and is recorded as such below so it does not get
re-audited.

The most serious is **B-3**: `gdn_conv` reads `tvalid` combinationally through
the whole of pass A while deriving `e_ref` and the four tap shifts from it once
at `S_PREP`, and its natural producer `gdn_exp_capture` presents `tvalid` as a
free-running level that changes on any other read request. That is the
`w_mant` defect exactly, on a different seam, and here the mask and the shifts
can disagree with each other rather than merely being one block stale.

A structural note that bounds all of this: **subsystem B has no top level.**
`gdn_emit_chain` is the only unit in B that instantiates other B units. Every
other seam named below is a seam between two units that are not yet wired
together, so "reachability" for those findings is a statement about the
contract, not about a build that exists. That does not make them less real --
the `w_mant` defect was written into `gdn_emit_chain` on the day the seam was
first made -- but it should be read that way.

---

## Per-unit port tables

Columns are the four questions from the method:
**span** (one cycle or many; what latches it), **pulse/level**,
**back-pressure**, **can the consumer refuse**.

### `rtl/gdn_emit_chain.vhd` (the reference for what a fixed version looks like)

| port | dir | span / latch | pulse or level | back-pressure | verdict |
|---|---|---|---|---|---|
| `w_mant`, `w_exp` | in | read once per head across all HEADS heads by `rmsnorm_bf` -- **latched** into `w_held`/`we_held` at head 0's pickup | level | none, but `w_taken` marks the safe instant | SAFE (this is the 2026-08-27 fix) |
| `col_valid/acc/e_o` | in | one cycle | level | `col_ready` exists, but the producer cannot use it | known class-3 defect, see B-8 |
| `col_ready` | out | -- | level | -- | SAFE as a signal; the producer is the problem |
| `z_mant`, `z_exp` | in | latched into `z_held`/`z_e_held` on `z_valid and not z_have` | level | `z_ready` | latched, but **never waited for** -- see **B-2** |
| `z_valid` / `z_ready` | in/out | -- | level | yes | handshake present, not honoured by the FSM |
| `y_valid/mant/last` | out | -- | level per element | **none** | see B-9 |
| `y_exp` | out | held from `gdn_y_emit`'s pass B until the next block's pass B | level | -- | SAFE, stable for the whole stream |
| `done` | out | 1 cycle from `gdn_y_emit`'s `S_DONE` | **pulse** | none | see B-9 |
| `y_sat` | out | held from `S_IDLE` of either emit unit | level | none | SAFE enough (status, not data) |
| `w_taken` | out | 1 cycle at the `w_held` latch | **pulse** | none | see B-6 |

Internal seam worth naming separately: the `S_SER` loop advances `ser_j` on
`ye_ready` alone, without requiring that a transfer occurred. See **B-1**.

### `rtl/gdn_head_emit.vhd`

| port | dir | span / latch | pulse or level | back-pressure | verdict |
|---|---|---|---|---|---|
| `in_valid/acc/e_o` | in | one cycle, written straight to `mem` | level | `in_ready` (combinational, correct) | SAFE |
| `in_ready` | out | -- | level | -- | SAFE |
| `done` | out | held in `S_DONE` until `o_ack` | **level** | `o_ack` | SAFE (this is the 2026-08-27 fix) |
| `o_ack` | in | sampled only while `S_DONE`, which is held | level | -- | SAFE: the unit cannot leave `S_DONE` unacked, so the ack cannot be missed |
| `o_mant`, `o_e_head` | out | must stand across `rmsnorm_bf`'s three passes | level, single-buffered | held by `S_DONE` until `o_ack` | SAFE, and the chain acks at `rn_done` precisely for this |
| `o_sat` | out | set in pass C, cleared at `S_IDLE` | level | none | SAFE (status) |

This unit is clean. Both hazards it had are fixed and the fixes are the right
shape: a held level plus an explicit ack, and a combinational ready.

### `rtl/rmsnorm_bf.vhd`

| port | dir | span / latch | pulse or level | back-pressure | verdict |
|---|---|---|---|---|---|
| `start` | in | sampled in `S_IDLE` only | pulse accepted | none | SAFE *only because* the chain sequences it; a `start` arriving while busy is silently ignored |
| `x_mant` | in | read at three points -- `S_ACC` (:325), `S_RAW` (:575), `S_EMIT` (:649) -- spanning ~142 cycles. **Not latched** | level | none | producer contract. SAFE as wired (head_emit holds it), see B-4 for the general shape |
| `x_exp` | in | latched into `xe` at `S_IDLE` | level | -- | SAFE |
| `w_mant` | in | read at `S_RAW` (:576) and `S_EMIT` (:650), ~100 cycles apart. **Not latched** | level | none | SAFE as wired (the chain latches), unsafe as a unit contract |
| `w_exp` | in | latched into `we` at `S_IDLE` | level | -- | SAFE |
| `done` | out | 1 cycle | **pulse** | none | see **B-5** (deadlock, not data loss) |
| `o_mant`, `o_exp` | out | held until the next `S_EMIT` / `S_SHIFT2` | level | none | SAFE, stable through the chain's whole `S_SER` |

Note the asymmetry that is the actual lesson of this unit: the two **exponent**
ports are latched at `S_IDLE` and the two **mantissa bus** ports are not. That
is exactly the split that made the `w_mant` defect hard to see -- the unit
looks like it latches its inputs.

### `rtl/gdn_y_emit.vhd`

| port | dir | span / latch | pulse or level | back-pressure | verdict |
|---|---|---|---|---|---|
| `in_valid`, `in_o`, `in_z` | in | one cycle | level | `in_ready` (combinational) | SAFE |
| `in_hfirst`, `in_e` | in | sampled on the accepted `in_hfirst` element | level | same | SAFE |
| `in_ready` | out | `not pending(wb)` | level | -- | SAFE as a signal; **its falling edge is what exposes B-1** |
| `o_valid/mant/last` | out | -- | level per element, 1 element/cycle for `HEADS*DIM` cycles | **none** | see B-9 |
| `y_exp` | out | settled at end of pass B, stable for the whole emit stream | level | none | SAFE, and documented |
| `done` | out | 1 cycle in `S_DONE` | **pulse** | none | see B-9 |
| `o_sat` | out | set during pass C, cleared at `S_IDLE` | level | none | SAFE (status) |

Internal: the two-bank fill/reduce interlock (`pending`, `wb`/`rb`) is correct.
`rb` and `wb` are never equal while a reduce runs, and `pending(rb)` is released
in `S_DONE` after the stream has drained, not at the end of pass C.

### `rtl/gdn_silu.vhd`

| port | dir | span / latch | pulse or level | back-pressure | verdict |
|---|---|---|---|---|---|
| `e_seg` | in | read combinationally at S0 for **every** beat of a segment; spans `SI_BEATS` cycles. Not latched | level | none | SAFE as wired: the chain drives `si_e_seg <= z_e_held` unconditionally in `S_GATE`, `z_e_held` cannot change while `z_have = '1'`, and every beat is inside `S_GATE`. Stated so it is not re-derived |
| `s_valid`, `s_data` | in | one cycle | level | **none** | fixed-latency II=1 pipeline; nothing can refuse, and nothing needs to |
| `o_valid`, `o_data` | out | -- | level | **none** | SAFE as wired: the chain's collector accepts unconditionally while `si_rd < SI_BEATS`, and silu emits exactly one group per group in |

Clean. This is the one unit in B where "no back-pressure anywhere" is the right
answer: it is a pure pipeline with a bounded, exactly-known output count.

### `rtl/gdn_recur_pipe.vhd`

| port | dir | span / latch | pulse or level | back-pressure | verdict |
|---|---|---|---|---|---|
| `kq_we`, `kq_wsel` | in | one cycle | pulse | none | see **B-7**: no output tells the producer when a bank is free |
| `eg`, `beta`, `k_n`, `q_s` | in | **latched** into `egbuf`/`betabuf`/`kbuf`/`qbuf` on `kq_we` | level | none | SAFE, and the `occ` shift-register assertion covers reuse |
| `s_valid`, `s_first`, `s_data` | in | one cycle each; per-column scalars latched into `cur_*` on `s_first` | level | **none at all -- no ready output exists** | see **B-8** |
| `c_tk0/hsel/se_j/e_v/v_j` | in | sampled on `s_first` into `cur_*` and `a_ctx(0)` | level | -- | SAFE, correctly latched |
| `o_valid/last/data` | out | -- | level per group | **none** | see B-9 |
| `o_res_valid`, `o_acc`, `o_e_o`, `o_se_new` | out | -- | 1-cycle valid per column | **none** | the known class-3 defect, B-8 |
| `o_err_se` | out | updated with `o_res_valid`, held until the next column | level | none | see **B-10**: nothing consumes it |

The three internal decoupling mechanisms -- per-slot parameter files with
`par1_v`/`par2_v` consume-clearing, per-column context carried down each
pipeline rather than held in single registers, and the `occ` occupancy window
on the double buffer -- are all the correct shape and are the reason this unit
is not full of class-1 defects despite having four concurrent columns in
flight. Do not re-audit them.

### `rtl/gdn_recur.vhd` (sequential twin; superseded by `gdn_recur_pipe`)

| port | dir | span / latch | verdict |
|---|---|---|---|
| `start` | in | sampled in `S_IDLE` only | pulse accepted; ignored if busy |
| `s_in` | in | pass A only (:289) | **nothing is latched at `start`** |
| `k_n` | in | pass A (:291) **and** pass B (:480) | span ~50 cycles, unlatched |
| `q_s` | in | pass C (:570), near the end | unlatched |
| `tk0` | in | :286, :391, :458, :500 -- four separate points | unlatched |
| `eg` | in | :300, :391, :458 | unlatched |
| `se_j` | in | :369/:373 and :454 | unlatched |
| `e_v` | in | :383, :413 | unlatched |
| `v_j` | in | :421 | unlatched |
| `beta` | in | :429 | unlatched |
| `s_out`, `se_new`, `o_acc`, `e_o`, `err_se` | out | levels, written at `S_FIN`, held | SAFE |
| `done` | out | 1-cycle pulse | see B-5 shape |

See **B-4**.

### `rtl/gdn_conv.vhd`

| port | dir | span / latch | pulse or level | back-pressure | verdict |
|---|---|---|---|---|---|
| `start` | in | `S_IDLE` only | pulse | none | ignored if busy |
| `nch` | in | **latched** into `nbr` at `S_IDLE` | level | -- | SAFE, and the header says why |
| `e_t` | in | read once at `S_PREP`, resolved into `e_ref`/`shf` | level | -- | SAFE |
| `tvalid` | in | read at `S_PREP` **and again combinationally at pass A stage 2 (:237) for every group**, spanning `nch/LANES + 5` cycles (384 for the v segment). **Not latched** | level | none | **B-3, CONFIRMED** |
| `cw_exp` | in | read once, at `S_FIN`, at the very **end** of the operation. Not latched | level | none | **B-3b** |
| `s_valid`, `x_in`, `w_in` | in | one cycle | level | `ready` | see **B-11**: `ready` is asserted 5 cycles longer than the unit accepts |
| `ready` | out | `state = S_A` | level | -- | **false ready during the pass-A drain**, B-11 |
| `o_valid`, `o_data` | out | -- | level | **none** | see B-9 |
| `o_done` | out | 1 cycle at `S_FIN` | **pulse** | none | mild: `e_seg`/`sh_seg`/`err_seg` are levels that survive it |
| `e_seg`, `sh_seg`, `err_seg` | out | held until the next `S_FIN` | level | none | SAFE |

### `rtl/gdn_scalar.vhd`

| port | dir | span / latch | verdict |
|---|---|---|---|
| `start` | in | `S_IDLE` only | pulse accepted |
| `al_m/al_e`, `dt_m/dt_e` | in | read at `S_CONV`, the first state after `S_IDLE` | unlatched, short span |
| `a_m` | in | read at `S_GMUL` | unlatched, ~15 states in |
| `a_e` | in | read at `S_GSH` | unlatched |
| `b_m`, `b_e` | in | read in the `if st = S_BCONV` tail, near the **end** of the FSM | unlatched, span is the whole invocation |
| `eg`, `beta` | out | registered, held until the next run | SAFE |
| `err_g` | out | set at `S_GCLAMP`, cleared at `start` | level | SAFE |
| `done` | out | 1-cycle pulse at `S_DONE` | see B-5 shape; `eg`/`beta` persist as levels so a missed pulse is not data loss |

See **B-4**.

### `rtl/gdn_exp_capture.vhd`

| port | dir | span / latch | pulse or level | back-pressure | verdict |
|---|---|---|---|---|---|
| `seq_rst` | in | one cycle | level | none | guarded by an assertion that the unit is idle |
| `cap_req` | in | sampled in `S_IDLE` | pulse | `cap_ready` | SAFE |
| `cap_layer/seg/exp` | in | **latched** at `S_IDLE` on `cap_req` | level | -- | SAFE |
| `cap_ready` | out | low during the RMW | level | -- | SAFE, but see B-12: it is still `'1'` in the cycle a read is refused |
| `rd_req` | in | sampled in `S_IDLE`, and **loses to `cap_req`** | pulse | **no ready output** | **B-12** |
| `rd_layer`, `rd_seg` | in | latched at `S_IDLE` | level | -- | SAFE |
| `rd_ack` | out | 1 cycle | **pulse** | none | B-12 |
| `e_t`, `tvalid` | out | held from one read until the next read | level | none | **B-3**: this is the level `gdn_conv` reads across its whole pass A |

### `rtl/l2norm_rs.vhd`

| port | dir | span / latch | verdict |
|---|---|---|---|
| `start` | in | `S_IDLE` only | pulse accepted |
| `x_mant` | in | read at `S_ACC` (:212) **and again** at `S_EMIT` (:367), separated by **two** full rsqrt chains. Not latched | **B-4** |
| `done` | out | 1-cycle pulse | see B-5 shape |
| `k_mant`, `q_mant` | out | `k_reg`/`q_reg`, held until the next `S_EMIT` | SAFE, and this is what makes the `l2norm_rs -> gdn_recur_pipe` seam work: `kq_we` latches them and `occ` guards reuse |

### `rtl/rmsnorm_rs.vhd`

Structurally identical to `rmsnorm_bf` on every interface question:
`x_exp`/`w_exp` latched at `S_IDLE` (:214); `x_mant` read at :234, :439, :513
and `w_mant` at :440, :514, all unlatched; `done` a 1-cycle pulse;
`o_mant`/`o_exp` held levels. Same verdicts as `rmsnorm_bf`. This unit is not
on B's path (B uses `rmsnorm_bf`); it is listed because it was in scope.

---

## Findings

### B-1 -- CONFIRMED. `gdn_emit_chain` `S_SER` duplicates an element if `ye_ready` is low at entry

**Unit / port:** `gdn_emit_chain`, the `S_SER` branch, against
`gdn_y_emit.in_ready`.

**Mechanism.** `S_SER` advances on `ye_ready` alone:

```vhdl
when S_SER =>
  if ser_j < DIM then
    ye_valid  <= '1';
    ...
    ye_o <= signed(rn_mant((ser_j+1)*16-1 downto ser_j*16));
    if ye_ready = '1' then
      ser_j <= ser_j + 1;
    end if;
```

In the FIRST cycle of `S_SER`, `ye_valid` is still `'0'` (cleared at the end of
the previous head). The advance taken in that cycle is therefore a **phantom**
one whose only purpose is to compensate for the one-cycle registration delay on
`ye_o`. The exact cycle sequence:

* cycle 0 (`state` becomes `S_SER`, `ser_j = 0`, `ye_valid = '0'`).
  If `ye_ready = '1'`: `ser_j -> 1`, `ye_o <- elem[0]`. The stream then runs
  `elem[0], elem[1], ... elem[DIM-1]`, exactly `DIM` transfers. Correct.
* If `ye_ready = '0'` in cycle 0: `ser_j` stays 0 and `ye_o <- elem[0]`.
* cycle 1: `ye_valid = '1'`, `elem[0]` on the bus, `ser_j = 0`. When `ye_ready`
  rises, `elem[0]` transfers **and** `ser_j -> 1` with `ye_o <- elem[ser_j] =
  elem[0]` again.
* cycle 2: `elem[0]` is presented a second time with `ye_valid = '1'` and
  transfers again.

`DIM + 1` elements are delivered for a head that has `DIM`. The stall length
does not matter; the duplicate is exactly one.

**Observable symptom in hardware.** `gdn_y_emit`'s fill counts `NTOT` accepted
elements before flipping banks, so from that head onward every element in the
bank sits one address early. Per-head exponents stay on the right `ep` index
(both `w_h` and `w_j` derive from the same accept counter), so the corruption is
**not** a whole-head exponent swap -- it is the first element of each subsequent
head being aligned with the *previous* head's exponent, plus the block's last
element spilling into the next bank, which offsets the following block by one
more. The result is a slow drift: the first affected block is wrong in
`HEADS` scattered elements, the next in `2*HEADS`, and so on. That reads as a
numeric artefact, not a wiring fault, which is the exact failure mode both of
this week's defects had.

**Evidence.** `sim/tb_b_audit_ser_handshake.vhd` transcribes the `S_SER` branch
verbatim and drives the real `rtl/gdn_y_emit.vhd`. `HEAD_GAP` models the
`S_IDLE + S_GATE + S_RMS` time the chain spends between heads.

```
HEAD_GAP=0   DIM=16  heads that moved more than DIM elements: 1  worst per-head transfer count: 17  S_SER entries with ye_ready low: 1
HEAD_GAP=8   DIM=16  heads that moved more than DIM elements: 1  worst per-head transfer count: 17  S_SER entries with ye_ready low: 1
HEAD_GAP=13  DIM=16  heads that moved more than DIM elements: 1
HEAD_GAP=14  DIM=16  heads that moved more than DIM elements: 0
HEAD_GAP=40  DIM=16  heads that moved more than DIM elements: 0  worst per-head transfer count: 16  S_SER entries with ye_ready low: 0
```

Reproduce (HEADS=4, DIM=16, 3 blocks; the whole sweep is seconds):

```
ghdl -a --std=08 rtl/gdn_y_emit.vhd
ghdl -a --std=08 sim/tb_b_audit_ser_handshake.vhd
ghdl -r --std=08 tb_b_audit_ser_handshake -gHEAD_GAP=0 --stop-time=3000ns
```

**Reachability, stated honestly.** `in_ready` can only fall at a block
boundary: `pending(wb)` changes only when a bank fills (end of block) or when a
reduce completes. So the precondition is "the chain finished filling a block
before `gdn_y_emit` finished reducing the previous one". The reduce is
`2*HEADS*DIM` plus a small fixed drain, i.e. **~2\*DIM cycles per head**; the
measured threshold above is a per-head period of 33 cycles at `DIM = 16`, which
is `2*DIM + 1`.

At `DIM = 128` that threshold is ~257 cycles per head. The shipped chain's own
floor is `1 (S_IDLE) + 9 (S_GATE at SILU_LANES=16) + 142 (S_RMS) + 129 (S_SER)
= 281` cycles, a **9% margin**, and in the shipped system the period is
actually set by column arrival at 512 cycles per head, a 2x margin. So this is
**not reachable as built** -- which is why it is written up rather than filed as
a bug against the current bitstream.

It becomes reachable if the chain's own service time drops below ~257 *and* the
producer can keep up. `RMS_LANES = 8` alone would take the floor to ~233
(derived by scaling the documented `3*NB + 46` shape from the measured 142 at
`RMS_LANES = 4`, not measured here), and the elastic buffer that
`2026-08-27_gdn-head-emit-done-pulse.md` prescribes for `LANES = 64` is exactly
what would let a producer feed it that fast. **The prescribed fix for the
LANES=64 column-drop problem is the thing that would expose this.** That
connection is the reason this finding is first.

The 9% margin is also an argument against ever "improving" `RMS_LANES` or
`SILU_LANES` upward on area grounds without re-checking this, which is
uncomfortably close to the `RMS_LANES = 2` trap the earlier note documents,
running in the opposite direction.

### B-2 -- CONFIRMED. `gdn_emit_chain` consumes `z_held` without ever checking `z_have`

**Unit / port:** `gdn_emit_chain`, `z_mant`/`z_exp`/`z_valid`.

**Mechanism.** The z handshake is complete and correct as far as it goes: z is
latched into `z_held`/`z_e_held` on `z_valid and not z_have`, and `z_ready`
reports `z_have = '0'`. But the head FSM never looks at `z_have`:

```vhdl
when S_IDLE =>
  if he_done = '1' then          -- z_have is NOT in this condition
    ...
    state <= S_GATE;
when S_GATE =>
  si_data <= z_held(...);        -- used unconditionally
```

Exact sequence: `z_have` is cleared at the end of head `h-1`'s `S_SER`. If the
z producer has not presented head `h`'s vector by the following cycle, and
`he_done` for head `h` is already high, the FSM enters `S_GATE` and gates head
`h` with **head `h-1`'s z**. Head `h`'s z is then latched during `S_RMS` or
`S_SER`, sits unused, and is cleared at the end of `S_SER`. The error is
permanent from that point: every head is gated with the previous head's silu
value, and head 0 of block 0 is gated with the reset value, all zeros.

The safe window is exactly **one cycle** wide, and it is not observable from
outside the unit.

**Observable symptom in hardware.** Every head's output multiplied by the wrong
gate. Because the gate is a per-element silu of a plausible vector, the result
is plausible: values of the right magnitude and sign distribution, wrong
everywhere. It would read as "the gate path is numerically off", not as a
handshake fault.

**Why the testbench does not see it.** `sim/tb_gdn_emit_chain.vhd`'s `stim_z`
process runs as far ahead as `z_ready` permits and always has the next head's z
waiting with `z_valid` asserted, so the latch fires in the first cycle
`z_have` is low, every time. The producer being maximally eager is what masks
this, and it is the same shape as the coupled-producer trap recorded in the
`gdn_head_emit` note: a testbench that is kinder than the real system reports a
clean result.

**Note the asymmetry with `w_mant`.** `w` got a latch *and* a `w_taken`
handshake. `z` got the latch but the consumer never waits on it. Half the fix
was applied.

### B-3 -- CONFIRMED. `gdn_conv` reads `tvalid` across all of pass A while its shifts are latched from `S_PREP`

**Unit / port:** `gdn_conv`, `tvalid`; producer `gdn_exp_capture`, `tvalid`
output.

**Mechanism.** `S_PREP` resolves `tvalid` once, into `e_ref` (the minimum over
valid taps) and `shf(t)` (the per-tap alignment shift, forced to 0 for invalid
taps). Those are latched. But pass A stage 2 re-reads the **live port** for
every group:

```vhdl
if tvalid(t) = '1' then
  p2(t)(ln) <= shift_right(p1(t)(ln), shf(t));
else
  p2(t)(ln) <= (others => '0');
end if;
```

Pass A runs `nch/LANES + 5` cycles -- 384 for the v segment at
`nch = 3072, LANES = 8`. If `tvalid` changes during that window, the channels
processed before the change and after it use different tap masks, and worse,
the mask and the shifts **disagree**: a tap that was invalid at `S_PREP` has
`shf(t) = 0`, so if it becomes valid mid-pass its product is summed
**unshifted**, on the wrong grid entirely.

The unit's own header already names this: *"Latched at start so a caller
changing nch mid-pass cannot split the two passes across two lengths -- the same
interface hazard tvalid already has."* The hazard was seen and `nch` was fixed;
`tvalid` was not.

**Why the producer makes it reachable.** `gdn_exp_capture` drives `e_t` and
`tvalid` as free-running levels held from one `rd_req` until the next. Nothing
in either unit says "do not issue the next read while the conv is running", and
`gdn_conv` publishes no signal a sequencer could use for that other than
`o_done`, which -- exactly as with `w_mant` and `done` -- arrives hundreds of
cycles too late to be the boundary. A sequencer that prefetches the next
segment's tap exponents while the current segment convolves is the natural
thing to write and it corrupts the current segment.

**Observable symptom in hardware.** A contiguous *tail* of channels within one
segment computed with a different tap set from the head of the same segment.
With the mask/shift disagreement, those channels are wrong by a power of two
per tap, or carry a whole extra tap. Per-channel, per-segment, silent, and
numerically plausible -- the C1/CR3-2 disease that `gdn_exp_capture` exists to
prevent, reintroduced on the seam immediately downstream of it.

**B-3b, same unit, PLAUSIBLE.** `cw_exp` is read **only** at `S_FIN`, the last
state of the invocation, and is never latched. A producer that presents
`cw_exp` with `start` and then moves on gets whichever value happens to be on
the port hundreds of cycles later. Symptom: the whole segment on a wrong
power-of-two grid. Rated PLAUSIBLE rather than CONFIRMED only because no
producer exists to establish that it changes; the mechanism itself is not in
doubt. A port read once, at the *end* of a long operation, is the least
obvious member of class 1 and is worth naming as its own pattern.

### B-4 -- PLAUSIBLE. `gdn_recur`, `gdn_scalar` and `l2norm_rs` latch nothing at `start`

**Units / ports:** `gdn_recur` (`s_in`, `k_n`, `q_s`, `tk0`, `se_j`, `eg`,
`beta`, `v_j`, `e_v` -- all of them); `gdn_scalar` (`al_*`, `dt_*`, `a_m`,
`a_e`, `b_m`, `b_e`); `l2norm_rs` (`x_mant`).

**Mechanism.** Each of these is a `start`/`done` unit that reads its inputs
combinationally at scattered points across the whole invocation and latches
none of them. The read points are tabulated above with line numbers. The
worst cases:

* `gdn_recur.k_n` is read in pass A (:291) **and** pass B (:480), ~50 cycles
  apart, and `q_s` not until pass C (:570).
* `gdn_scalar.b_m`/`b_e` are read in the `st = S_BCONV` tail, at the very end of
  a ~30-state FSM whose first input read is at `S_CONV`, the second state.
* `l2norm_rs.x_mant` is read at `S_ACC` and again at `S_EMIT`, separated by
  **two** complete Newton rsqrt chains.

The contract is "hold every input from `start` until `done`". It is correct,
it is cheap, and it is **written nowhere** -- not in the entity, not in the
port comments, not in an assertion. That is precisely the property that made
`w_mant` a defect rather than a documented constraint: a contract the producer
cannot see is a bug waiting on a schedule change.

**Observable symptom.** Whatever a partial input swap produces: for
`gdn_recur`, the state update computed from one column's `k_n` and a different
column's `q_s`; for `l2norm_rs`, a norm computed from one vector applied to
another. All numerically plausible.

**Rated PLAUSIBLE, not CONFIRMED**, because none of these three has a producer
in RTL yet, so no sequence of events can be narrated against a real driver.
`gdn_recur` in particular is superseded by `gdn_recur_pipe` on the shipping
path, and `gdn_recur_pipe` does this correctly -- it latches `k_n`/`q_s`/`eg`/
`beta` into banks on `kq_we` and carries every per-column scalar down the
pipeline in a context record. The contrast between the two is the clearest
statement in B of what "right" looks like.

### B-5 -- PLAUSIBLE. `rmsnorm_bf.done` is a pulse ANDed with an independent condition

**Unit / port:** `gdn_emit_chain` `S_RMS`, consuming `rmsnorm_bf.done`.

**Mechanism.** `done` is a one-cycle pulse (`done <= '1'` in `S_EMIT`, cleared
by the process default). The chain consumes it as:

```vhdl
when S_RMS =>
  if rn_done = '1' and si_rd = SI_BEATS then
```

If `si_rd < SI_BEATS` in the cycle the pulse fires, the pulse is gone and the
chain waits in `S_RMS` forever. This is not data loss; it is a **hard
deadlock**, and it is the same structural mistake the `gdn_head_emit` `done`
pulse was: a producer that proceeds regardless of whether the consumer was in a
position to observe the event.

**Why it does not fire today.** `gdn_silu` is a fixed-latency II=1 pipeline,
latency 6, fed `SI_BEATS` groups starting one cycle before `rn_start`. The last
silu output lands at ~`SI_BEATS + 6` cycles; `rn_done` at ~`SI_BEATS + 1 + 142`.
The margin is ~135 cycles, so `si_rd = SI_BEATS` is always true first. Safe by
a wide margin, but safe by arithmetic on two independent units' latencies rather
than by construction. Latching `rn_done` into a sticky bit cleared on exit from
`S_RMS` would make it structural for one flop.

**Observable symptom if it ever fires.** The chain freezes with
`state = S_RMS`, `col_ready` high, columns still arriving and being accepted by
`gdn_head_emit` until both banks fill, then `col_ready` low forever. Identical
to the frozen-state signature in the `gdn_head_emit` note, which is worth
knowing because it means that signature does **not** uniquely identify that
defect.

### B-6 -- PLAUSIBLE. `w_taken` is a pulse with no back-pressure

**Unit / port:** `gdn_emit_chain.w_taken`.

Already recorded as open in `2026-08-27_gdn-emit-chain-w-latch.md`; repeated
here because it is a class-2 instance and belongs in the list. It is a
one-cycle pulse. A producer that is not sampling it at that instant misses the
only signal that says its weights were consumed, and there is no assertion that
`w` was stable from the block's first column up to it. The failure mode is the
original `w_mant` defect, re-entered through the front door.

### B-7 -- PLAUSIBLE. `gdn_recur_pipe` has no "bank free" output for `kq_we`

**Unit / port:** `gdn_recur_pipe`, `kq_we`/`kq_wsel`.

The unit checks, with a genuinely good mechanism (the `occ` shift register),
that a bank being written has no columns in flight -- and **fails the
simulation** if it does. What it does not do is tell the producer when the bank
*is* free. The producer must model `DC + 2*NB` internally. An assertion is not
a handshake: it synthesizes to nothing, so in hardware an early `kq_we`
silently corrupts every column of the previous head that is still in engine B or
C. Symptom: the tail of each head computed with the next head's `k_n`/`q_s`/
`eg`/`beta` -- the *same shape* as the head-23 defect, one level up.

Rated PLAUSIBLE because at 128 columns per head the natural head boundary is
enormously wider than `DC + 2*NB`, and because no producer exists yet.

### B-8 -- PLAUSIBLE (mechanism already CONFIRMED elsewhere). `gdn_recur_pipe` accepts and emits with no ready in either direction

**Unit / ports:** `s_valid`/`s_first`/`s_data` in, `o_res_valid`/`o_valid` out.

The output side is the known class-3 defect and is fully documented in
`2026-08-27_gdn-head-emit-done-pulse.md`. Two things this audit adds:

1. **The input side has the same hole and is not documented at all.** There is
   no `s_ready`. Nothing bounds how fast columns may be offered, and nothing
   *checks* it either:
   * A column with fewer than `NB` groups never sets `redk_c(0).v` (that needs
     `grp = NB-1`), so it produces no result at all and no assertion fires.
   * `if dlyB(DB-1) = '1' then runB <= '1'; grpB <= 0;` -- a second start pulse
     arriving while `runB = '1'` resets `grpB` and silently truncates the
     in-flight column in engine B. Same for engine C.
   * The `par1_v`/`par2_v` assertions do catch a too-fast producer, but they are
     assertions: simulation only.

   The bound that must hold is "one `s_first` every `NB` cycles or slower, and
   exactly `NB` groups per column". **That bound is written down nowhere** --
   not in the entity, not in a comment, not in an assertion.

2. `STRICT_PRODUCER` on `gdn_emit_chain`, the only detector that exists for the
   output-side defect, **defaults to `false`**. The shipped generic has the
   check off.

### B-9 -- PLAUSIBLE. Every B unit's output stream is un-refusable

**Units / ports:** `gdn_emit_chain.y_valid/y_mant/y_last` and `done`;
`gdn_y_emit.o_valid` and `done`; `gdn_conv.o_valid`; `gdn_recur_pipe.o_valid`
and `o_res_valid`.

None of these has a ready input. `gdn_y_emit` in particular free-runs one
element per cycle for `HEADS*DIM = 3072` consecutive cycles once pass C starts,
and cannot be stopped. Its consumer is `ssm_out`, a matvec, which does not
exist in RTL yet. If that consumer can ever refuse -- for a weight-stream
stall, an HBM hiccup, an AXI backpressure event -- the elements are **lost, not
delayed**, and `done` is a one-cycle pulse that a busy consumer misses outright.

This is the same class-3 property that made throughput margin a correctness
property for the column path, promoted to the block output. It is listed as
one finding rather than five because the fix is one decision: either every B
output gets a ready, or every B output gets an elastic buffer at the boundary,
and that decision has not been made anywhere in the source.

`y_exp` is the one bright spot: it is a level, stable for the whole stream, and
its port comment says so explicitly.

### B-10 -- PLAUSIBLE. `o_err_se` and `err_seg` are reported on ports nobody reads

`gdn_recur_pipe.o_err_se` is a deliberately per-column, non-sticky flag,
correctly aligned with `o_res_valid`. `gdn_conv.err_seg` is a sticky level
cleared at `start`. `gdn_scalar.err_g` likewise. `gdn_emit_chain` has no error
input port at all and does not forward anything from `gdn_head_emit` beyond
`y_sat`, which is itself unconsumed (recorded as open in the earlier note).

So an int8 exponent overflow -- the thing section 2.1.6 says must never be
silently wrapped -- is currently reported into open air. This is not a
handshake defect; it is the observability half of the same problem, and it is
listed because a per-column pulse-aligned status output with no consumer will
be *harder* to wire up later than it is now.

### B-11 -- PLAUSIBLE. `gdn_conv.ready` stays high for ~5 cycles after the unit stops accepting

**Unit / port:** `gdn_conv`, `ready`.

```vhdl
ready <= '1' when state = S_A else '0';
...
when S_A =>
  if s_valid = '1' and idx < nbr then   -- the ACTUAL accept condition
```

`state` remains `S_A` for the `vf/v1/v2/v3/v4` drain after `idx` reaches `nbr`.
During those cycles `ready = '1'` while the accept condition is false, so a
group offered there is **acknowledged and discarded**. Classic false-ready.

Rated PLAUSIBLE rather than CONFIRMED because the framing protocol -- `start`
is only sampled in `S_IDLE`, and the caller must wait for `o_done` before the
next `start` -- means a well-behaved caller has no reason to offer a group in
that window. But `ready` is the only flow-control signal the unit has, it is
wrong for 5 of every `nch/LANES + 5` cycles, and a caller that trusts it (which
is the entire point of a ready) loses data with no indication. `ready` should
be `'1' when state = S_A and idx < nbr`.

### B-12 -- PLAUSIBLE. `gdn_exp_capture` silently refuses a read that collides with a capture

**Unit / port:** `gdn_exp_capture`, `rd_req`.

In `S_IDLE`, `cap_req` wins and `rd_req` is dropped with no acknowledgement of
any kind. The header states the intended recovery -- *"A read that collides
with a capture is retried by the caller one cycle later"* -- but there is no
signal that tells the caller a retry is needed:

* `rd_ack` simply does not pulse, and "no pulse yet" is indistinguishable from
  "still working".
* `cap_ready` is registered (`ready_r <= '0'` is assigned *in* `S_IDLE`), so in
  the very cycle the read is refused, `cap_ready` still reads `'1'`.

A caller that pulses `rd_req` for one cycle and then reads `e_t`/`tvalid` gets
the **previous** read's values -- held levels for a different (layer, segment).
Symptom: `gdn_conv` convolving one segment with another segment's tap
exponents. That is exactly the per-tap power-of-two error this unit was written
to eliminate.

The safe usage is "hold `rd_req` until `rd_ack`", which works, and which the
unit does not say. Rated PLAUSIBLE because no caller exists.

---

## SAFE-BY-CONSTRUCTION -- do not re-audit these

Recorded with the construction, so the next reader can skip them.

* **`gdn_head_emit`, whole unit.** `in_ready` is combinational off
  `pending(wb)` and the fill accepts only on `in_valid and in_ready`. `done` is
  held in `S_DONE` until `o_ack`, so the ack can never be missed and the single
  result register cannot be overwritten under the consumer. Both hazards this
  unit had are fixed and fixed in the right shape.
* **`gdn_emit_chain` `w_mant`/`w_exp`.** Latched into `w_held`/`we_held` at head
  0's pickup, with `w_taken` as the observable instant. This is the 2026-08-27
  fix; only the pulse nature of `w_taken` (B-6) remains.
* **`gdn_emit_chain` `he_ack` timing.** Acked at `rn_done`, not at pickup,
  because `rmsnorm_bf` re-reads `x_mant` across all three passes. Correct, and
  the reason is recorded in the source.
* **`gdn_silu.e_seg`.** Read combinationally for every beat, but the chain
  drives it unconditionally in `S_GATE` from `z_e_held`, which cannot change
  while `z_have = '1'`, and every beat is inside `S_GATE`. Safe.
* **`gdn_silu` output collection.** No ready in either direction, and none
  needed: fixed-latency II=1, exactly one output group per input group, and the
  chain's collector accepts unconditionally while `si_rd < SI_BEATS`.
* **`gdn_y_emit` two-bank interlock.** `rb` and `wb` are never equal while a
  reduce runs (the reduce only starts on `pending(rb)`, and `wb` has already
  flipped away). `pending(rb)` is released in `S_DONE`, after the emit stream
  has fully drained, not at the end of pass C.
* **`gdn_y_emit.y_exp`.** Settled at the end of pass B and cannot change until
  the next block's pass B, which cannot start before this block's `S_DONE`.
  Stable for the whole `o_valid` stream; a consumer may latch it on the first
  element.
* **`rmsnorm_bf.o_mant`/`o_exp` during the chain's `S_SER`.** Written in
  `S_EMIT`/`S_SHIFT2` and held; the next `rn_start` cannot occur until the chain
  has left `S_SER`. Stable.
* **`rmsnorm_bf.start` / `rmsnorm_rs.start` sampled only in `S_IDLE`.** A start
  arriving while busy is silently ignored, which would be a class-2 defect
  against an arbitrary producer -- but the chain issues `rn_start` only after
  `rn_done`, so the unit is always idle at that instant.
* **`gdn_recur_pipe` per-column context.** Every per-column scalar rides a
  record down each pipeline rather than sitting in a held register, because at
  `II = NB` two columns are in the SCAL1 chain at once. Slot-tagged parameter
  files with `par1_v`/`par2_v` cleared on consume turn "start offset too small"
  into an assertion instead of a stale read. This is the correct construction
  and it is not a class-1 site.
* **`gdn_recur_pipe` double-buffer `occ` window.** A shift register covering
  `DC + 2*NB`, not a counter, specifically because a slot-based retirement can
  be charged to the wrong bank. The bank reads (`kbuf` at engine B, `qbuf` at
  engine C, `betabuf` at SCAL1, `egbuf` at engine A) all fall inside the window.
* **`gdn_conv.nch`.** Latched into `nbr` at `S_IDLE` so the two passes cannot
  split across two lengths.
* **`gdn_exp_capture` capture side.** `cap_layer`/`cap_seg`/`cap_exp` latched at
  `S_IDLE`; `cap_ready` low for the whole RMW; capture deliberately wins over
  read because a dropped capture loses an exponent permanently.
* **`l2norm_rs` -> `gdn_recur_pipe` seam.** `k_mant`/`q_mant` are held
  registers, `kq_we` latches them into banks, and `occ` guards bank reuse. The
  only gap is that nothing tells the producer *when* to pulse `kq_we` (B-7).
* **`rmsnorm_bf` / `rmsnorm_rs` exponent ports.** `x_exp` and `w_exp` are
  latched at `S_IDLE`. Only the mantissa buses are not.

---

## What I did NOT audit, and why

* **Any subsystem other than B.** `engine_shared.vhd`, `attention_ml.vhd`,
  `matvec_int4*`, `swiglu`, `bfp_pack`, `divider_rs`, `vec_mem`, `stream_fifo`
  and the AXI layer were out of scope. `rmsnorm_rs` is included only because it
  was named in the task; it is on A's and C's path, not B's.
* **Arithmetic.** No recipe, bound, rounding mode, saturation rail, exponent
  derivation or width argument was checked. This audit assumes every unit
  computes the right value when its inputs are stable, which is what the
  existing unit testbenches establish.
* **Timing closure and area.** No Vivado was run, deliberately: two machines
  are running sweeps. Every Fmax, DSP, LUT and BRAM figure quoted above is
  transcribed from existing notes and source comments, not measured here.
* **Cycle counts.** The `142` for `rmsnorm_bf` at `RMS_LANES = 4`, the `268` for
  `gdn_head_emit`'s reduce and the `512` per head of column arrival are all
  taken from the existing documentation. The `~233` figure for
  `rmsnorm_bf` at `RMS_LANES = 8` in B-1 is **derived** by scaling the
  `3*NB + 46` state shape against the measured 142, not measured. If B-1 is
  ever acted on, measure it.
* **The reset domain.** Whether `rst` is synchronous everywhere, whether it is
  released cleanly across units, and the initial-value-versus-reset split were
  not examined. Several units rely on VHDL signal initialisers (`:= '0'`) that
  do not exist in hardware for non-FF elements; that is a separate audit.
* **`x`/`u`/metavalue propagation.** No check that an unwritten RAM location or
  an undriven port cannot reach an output. `gdn_head_emit` and `gdn_y_emit`
  argue this structurally in their headers; `gdn_exp_capture` argues it from
  `tvalid`. Those arguments were read but not tested.
* **Simulation of B-2 through B-12.** Only B-1 was demonstrated in simulation.
  B-2 could be demonstrated cheaply by adding a `Z_DELAY` generic to
  `sim/tb_gdn_emit_chain.vhd`, but that means editing an existing testbench,
  which the task rules out; a new one would need the whole vector-file
  scaffolding. The others need producers that do not exist.
* **`sim/` beyond `tb_gdn_emit_chain.vhd`.** I read that one testbench, to
  establish why B-2 is masked. The other twelve B testbenches were not
  reviewed, so this audit does not claim that any *other* finding is or is not
  covered by an existing test.

## Open, not yet answered

* **B-1's margin is 9% and nobody is watching it.** There is no assertion, no
  cycle counter and no note anywhere that says "the chain's per-head service
  time must exceed `2*DIM`". `CONSUME_BUDGET` watches a different deadline
  (head_emit's result register) and would not fire.
* **Is `z` in `gdn_emit_chain` meant to be per-head or per-block?** The port
  comment says "one head at a time" and `z_exp` is latched per head, but
  `sim/tb_gdn_emit_chain.vhd` reads a single `ze` per **block** and re-presents
  it for all 24 heads. If z_exp really is per-block, B-2's symptom changes
  (mantissas shift, exponent does not) but the defect does not.
* **Nothing establishes the intended `s_valid` cadence for `gdn_recur_pipe`.**
  B-8 names the bound; the spec section that should contain it was not located.
* **The `y_sat` / `err_seg` / `o_err_se` policy is still absent**, unchanged
  from the earlier notes.

## Artefacts

* `sim/tb_b_audit_ser_handshake.vhd` -- the B-1 demonstration. Transcribes
  `gdn_emit_chain`'s `S_SER` branch verbatim against the real
  `rtl/gdn_y_emit.vhd`. Bounded: `HEADS=4`, `DIM=16`, 3 blocks, seconds per
  run. It is an audit artefact, not a regression test, and it deliberately
  reports rather than fails.
