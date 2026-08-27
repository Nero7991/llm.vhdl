# gdn_silu: the 783-load shift-control net, and which call site actually had the lead

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`, on top of `7955326`. Changed:
`rtl/gdn_silu.vhd`, `rtl/gdn_emit_chain.vhd`.
**Tools:** GHDL 1.0.0 mcode, `ghdl -r` direct, `--stop-time` and
`--max-stack-alloc=0` on every run.
**Vivado was NOT run** and no Fmax claim is made here. The post-route numbers
quoted are the coordinator's measurements, restated so the reasoning can be
checked against them.

---

## The question

Verbatim, from the coordinator, 2026-08-27:

> MEASURED, post-route on `xcvu33p-fsvh2104-2LV-e` at the card's real 0.717 V,
> `gdn_emit_chain` at `HEADS=24 DIM=128 SILU_LANES=16 RMS_LANES=4 Q=12`, 3.3 ns
> target: [after `3c2789e`] Fmax **216.51**, WNS -1.320, logic **1.753**, net
> **2.812**, binding path
> `si_e_seg_reg[4]_replica/C -> u_silu/xq_reg[7][22]/D`. [...]
> **It is a ROUTING problem, not a logic-depth problem.** [...]
> `u_silu/xq[7][29]_i_19_n_0` has fanout **783** [...]
> THE TASK: cut that net delay.
>
> The constraint: that costs a cycle of lead time on `e_seg`, and your own
> straight-through change may have removed exactly that lead. In
> `gdn_emit_chain`, `si_e_seg` is assigned at `S_RMS`, well before any beat, so
> there is plenty. But in `gdn_block` you made `cs_eseg` freeze on the segment's
> FIRST output beat [...] a registered copy would be one cycle late for that
> beat.

---

## The answer

**The per-lane replication is done, and it is bit-exact at every lane count and
at both call sites.**

**The lead premise was backwards on both counts, and it is the finding.**
Measured by giving `gdn_silu` an assertion that fails if `e_seg` moves in the
same cycle as a beat, then running each site unchanged against it:

| site | expected by the brief | MEASURED | why |
|---|---|---|---|
| `gdn_emit_chain` `u_silu` (the z gate) | "plenty" of lead | **NO LEAD -- fails at 791.5 ns** | `si_e_seg <= z_e_held` was assigned in `S_GATE`, on the SAME edge as the first `si_valid`, not in `S_RMS` |
| `gdn_block` `u_silu_conv` (the 1.4(e) activation) | "may be one cycle late" | **LEAD PRESENT, 3 cycles, passes** | `cs_eseg` tracks `cv_eseg` and only FREEZES on the first beat; it has held the right value since `S_SH + 1`, three cycles earlier |
| `sim/tb_gdn_silu` | not considered | **LEAD PRESENT, 1 cycle, passes** | it already sets `e_seg`, waits a rising edge, then asserts `s_valid` |

So the site the brief said was safe was the broken one, and the site it warned
about was already correct. The straight-through change did not remove the lead;
it is the reason site 2 has three cycles of it.

`gdn_emit_chain` is fixed by moving one line: `si_e_seg <= z_e_held` is now
unconditional, ahead of the case statement, which gives at least two cycles of
lead and cannot be defeated by a state-order change later.

**No cycle was added to any data path.** The decode is a register in FRONT of
the pipeline, not a stage inside it, so `gdn_silu`'s latency, `SI_BEATS`
collection and the emit chain's per-head service are all unchanged. The
per-head deadline is therefore expected to stay at 368 dropped / 369 passing;
see the re-measurement below.

---

## The procedure

1. Read the actual `S0` of `rtl/gdn_silu.vhd` and the actual `S_GATE` of
   `rtl/gdn_emit_chain.vhd` rather than the brief's description of them. This
   is the step that produced the finding: `si_e_seg` is assigned in `S_GATE`,
   one line above `si_valid <= '1'`, not in `S_RMS`.
2. Decode the five-way branch once into `(mode, amount)` and hold it in `LANES`
   separate registers with `DONT_TOUCH`, so each lane's barrel shifter is
   driven by a register the placer can put beside it.
3. Add the lead assertion to `gdn_silu` and run each of the three call sites
   UNCHANGED against it. An assertion that has not been shown to fire is not
   evidence; each site was run before anything was fixed.
4. Distinguish the two `gdn_silu` instances inside `gdn_block` by the instance
   path in the failure, not by the line number -- both instances share one.
5. Fix `gdn_emit_chain`, then re-run: `tb_gdn_silu` at three lane counts,
   `tb_gdn_emit_chain` at `HEADS=24` in both overlap modes, the eleven-way
   `gdn_block` skew matrix, and the per-head deadline bisection.

---

## The evidence

### The assertion has teeth: both real sites run unchanged against it

Site 1, `gdn_emit_chain` standalone at `HEADS=4`:

```
rtl/gdn_silu.vhd:249:9:@791500ps:(assertion failure): gdn_silu: e_seg changed
in the same cycle as a beat.  The shift control is registered, so this beat is
converted on the PREVIOUS exponent's grid.
```

Site 2, inside `gdn_block`. The same line number fires, but the instance path
is what settles which instance it is:

```
in process .tb_gdn_block(sim).dut@gdn_block(rtl).u_emit@gdn_emit_chain(rtl).u_silu@gdn_silu(rtl).P1
```

`u_emit/u_silu` -- the z gate, i.e. site 1 again, reached later because the
block runs three conv segments and the L2 and scalar phases first. All three of
`u_silu_conv`'s segments had already streamed by 1085.5 ns with no failure.
**`u_silu_conv` has the lead; the gate did not.**

### After the fix

```
gdn_silu: bit-exact with the C reference on all 8192 groups (32768 elements), LANES=4 ARG_Q=12
gdn_silu: bit-exact with the C reference on all 4096 groups (32768 elements), LANES=8 ARG_Q=12
gdn_silu: bit-exact with the C reference on all 2048 groups (32768 elements), LANES=16 ARG_Q=12

tb_gdn_emit_chain: PASS -- 3 blocks x 24 heads x 128 bit-exact, OVERLAP=false COL_GAP=4 refused-column cycles=0 SILU_LANES=16 RMS_LANES=4
tb_gdn_emit_chain: PASS -- 3 blocks x 24 heads x 128 bit-exact, OVERLAP=true  COL_GAP=4 refused-column cycles=0 SILU_LANES=16 RMS_LANES=4
```

### The eleven-way gdn_block skew matrix, and the cycle counts

```
  z1: identical to ref        cvgap1:  identical to ref
  z7: identical to ref        cvgap3:  identical to ref
  z31: identical to ref       all:     identical to ref
  wmove: identical to ref     fastall: identical to fastref
  scmove: identical to ref
  cwmove: identical to ref
  capbusy: identical to ref
```

Every per-token cycle count is IDENTICAL to the pre-change run -- ref 2,217,
cvgap1 2,278, cvgap3 2,400, all 2,339, fastref/fastall 1,806 -- which is the
direct evidence that the decode register is in front of the pipeline and not a
stage inside it.

And across the change, not merely self-consistent within the run: the default
dump is byte-identical to the reference produced before the silu and emit-chain
edits.

```
ACROSS THE SILU CHANGE: dump identical to the pre-change reference
```

### Requirement 3: the per-head deadline is UNCHANGED

Same bisection, same shape (`DIM=128 SILU_LANES=16 RMS_LANES=4`,
`RECUR_LANES=64` plus `HEAD_GAP`), run against the changed RTL:

```
arrival 367 cycles/head: COLUMN DROPPED
arrival 368 cycles/head: COLUMN DROPPED
arrival 369 cycles/head: no column refused
arrival 370 cycles/head: no column refused
```

**368 dropped / 369 passing, exactly as before.** The fix takes NOTHING out of
the 143-cycle margin at `RECUR_LANES=32`, because it adds no cycle to any data
path: `gdn_silu`'s latency, `SI_BEATS` collection and the emit chain's per-head
service are all untouched. This was the expected answer and it is the one that
had to be checked rather than asserted, since cycles added inside that loop
land on the deadline one for one.

---

## Measured and REJECTED -- do not retry

### Do not reference `e_seg` or a shared `sh` inside the S0 lane loop

The whole construction is defeated by one such reference: it recreates the
shared high-fanout net, and the result is still BIT-EXACT, so no simulation
catches it. Only synthesis would, and only if someone re-read the fanout
report. The lane loop reads `c_mode(k)` and `c_amt(k)` and nothing else, and
the source says so at the loop.

### `DONT_TOUCH` is load bearing, and its cost is real

Sixteen registers with identical inputs are exactly what
equivalent-register-removal exists to merge, and a merged copy is the original
783-load net back with extra area. The cost, stated rather than hidden:
`DONT_TOUCH` also stops Vivado doing its OWN further replication -- the thing
that produced `si_e_seg_reg[4]_replica` in the measured run. If 783/LANES loads
per lane is still too many, this attribute is what stands in the way, and the
next step is per-lane-per-stage copies or swapping it for `MAX_FANOUT`. That is
a measurement and it has not been made.

### Reasoning about the lead from the brief's description -- do not retry

The brief's claim that `si_e_seg` is assigned at `S_RMS` is wrong, and acting
on it would have "fixed" the site that was already correct while leaving the
broken one. Two lines of `grep` settled it. Read the state, not the summary of
the state.

---

## Measurement traps hit

* **One line number, two instances.** `gdn_block` instantiates `gdn_silu`
  twice. The failure inside the block reported `rtl/gdn_silu.vhd:249` exactly
  as the standalone chain run did, which reads as "site 2 fails too". The
  instance path in the following line is the only thing that distinguishes
  them, and it changed the conclusion completely.
* **Timing of the first failure is not the timing of the first opportunity.**
  Site 2's `u_silu_conv` streams three whole segments before the sweep starts,
  so its clean run up to 1085.5 ns is positive evidence, not absence of
  evidence. Had the block failed at 40 ns the two sites would have been
  indistinguishable without the path.
* The vector generator must be regenerated per head count:
  `tb_gdn_emit_chain` at `HEADS=4` against a 24-head vector file fails with
  "vector shape does not match the generics" before any RTL runs.

---

## Open, not yet answered

* **No synthesis, so no Fmax result.** Whether one net of 783 loads becoming
  16 nets of about 49 actually recovers the 2.812 ns of net delay is
  unmeasured. The change is handed over for measurement, as agreed.
* **`ARG_Q` is a generic and the decode assumes the same five branches.** The
  bounds 62 and 40 are carried over unchanged from the original S0; they are
  not re-derived for other `ARG_Q`, and they were not before either.
* The 8-bit `e_seg` still fans out to the decode itself. That fanout is
  `LANES` x a few bits and is in front of a register, so it should not bind,
  but it has not been measured either.
