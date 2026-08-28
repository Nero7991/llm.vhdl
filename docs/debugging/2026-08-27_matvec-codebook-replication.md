# Replicating the IQ4_NL codebook, and what actually tests a replicated table

Date: 2026-08-27
Design: `rtl/matvec_core.vhd`, subsystem A datapath core
Build: FK33, VU33P `-2LV`, 0.717 V measured, 3.300 ns constraint
Symptom: post-route 187.2 MHz, WNS -2.041, logic 2.212, net 2.775, 55.6% route

---

## The question

Verbatim from the coordinator brief:

> **THE NEXT PATH, and it is the third instance of the same shape today:**
>
> ```
> cb_reg[4][6]_replica_1/C -> tr_reg[0][1220]/DSP_OUTPUT_INST/ALU_OUT[10]
> slack -2.041   logic 2.212   net 2.775      (55.6% ROUTE)
> ```
>
> [...] At `ROWS_IF = 48, BLK = 32` that is **1,536 consumers of one 16-entry
> table**. Each consumer is a 16:1 8-bit mux feeding a DSP. [...]
>
> 1. **Replicate the codebook, not just its output.** [...] Pick the
>    granularity you can defend and say why.
> 2. **`cb` is runtime-loadable [...] explicitly illegal outside idle.**
>    Replicas must all be written, and they must all be written before any lane
>    reads them. That write path is the correctness risk in this change: a
>    partially-updated set of replicas is a silently wrong codebook, not a
>    failure. Say how you guarantee it, and test it -- a load-then-read sequence
>    that would fail if one replica lagged.
> 3. **Cycle cost must be zero or justified.**

---

## The answer

One copy per row, `CB_ROWS_PER_COPY = 1`, as a **generic** rather than a
constant so the granularity can be swept without another RTL change. Fanout per
codebook bit falls from `ROWS_IF*BLK` to `BLK`, 1,536 to 32 at the FK33 shape,
for `ROWS_IF * 128` flops -- 6,144 at `ROWS_IF = 48`, against 56,100 used and
879,360 available. **Zero cycles in the multiply path**; one cycle of write
latency, spent in `S_IDLE` where the spec already confines codebook writes.

**The granularity defence is the adder tree, not the codebook.** The `BLK` lanes
of row `rr` feed a shared tree -- `tr(1)(rr*BLK+i) <= tr(0)(rr*BLK+2i) +
tr(0)(rr*BLK+2i+1)` -- so the placer already keeps a row together for a reason
that has nothing to do with `cb`. Replicating on a boundary the tree does not
respect would split one copy's consumers across two clusters and buy less than
it costs. The row is the smallest boundary that is free.

**On the write path, the replicas are peers, not followers.** There is no master
copy that the replicas chase. `cbw_v/a/d` are per-copy registered copies of ONE
command, loaded on the same edge from the same source, and every copy writes off
its own replica on the next edge. A partially-updated set is therefore not
merely unlikely, it has no cycle in which to exist.

**The thing that actually tests this is an assertion inside the core, not a
testbench**, and that conclusion is measured rather than argued. See the traps
section: a codebook write delayed by four cycles -- all copies still in perfect
lockstep -- **passes `tb_matvec_core` AND passes the testbench written for this
job**. The invariant `not (cbw_v(0) = '1' and st /= S_IDLE)` fails it in both,
at 245 ns and 815 ns respectively.

**Expected headroom.** Achieved 5.342 ns at 187.2 MHz with WNS -2.041 gives a
3.301 ns constraint and 0.355 ns of clocking overhead, so with the logic term
unchanged **net must come in under 0.733 ns** for this to close. That is more
room than the `ns` path had (0.550), so this one has a real chance. At a net of
0.5 ns the path is 3.067 ns, 326 MHz; at 1.0 ns it is 3.567 ns, 280 MHz. Either
is a large move from 187.2.

---

## The procedure

1. Classify the consumers. `cb` has exactly two: the write at the old `:409` and
   the product stage at the old `:478`. Nothing else touches it.
2. Choose the granularity from the DATAPATH's own clustering, not from a flop
   budget -- the flop budget only says which choices are affordable.
3. Design the write path so divergence is structurally impossible, then check
   that the design did not simply move the broadcast (it nearly did -- see the
   768-flop trap below).
4. Establish the invariants, then **break each one and confirm something fails**.
   Three mutations were run: one replica lagging, all replicas lagging, and the
   granularity swept.
5. `sim/regress.sh` as the gate, and raise its `BASELINE_PASS` floor for the
   added testbench as its own header instructs.

---

## The evidence

Measured by the coordinator, post-route at 0.717 V, for context:

| config | DSP | LUT | Fmax | WNS | logic | net |
|---|---|---|---|---|---|---|
| `ROWS_IF=58` pre-ns-fix | 1,914 | 134,874 | 172.6 | -2.495 | 2.543 | 3.045 |
| `ROWS_IF=48` pre-ns-fix | 1,584 | 112,989 | 179.7 | -2.265 | 2.487 | 3.032 |
| `ROWS_IF=48` post-ns-fix | 1,584 | 115,766 | 187.2 | -2.041 | 2.212 | 2.775 |

Teeth check 1, ONE replica lagging (copy 1 skips a write when copy 0 takes one):

```
FAIL  sim:tb_matvec_core  exit 1: rtl/matvec_core.vhd:475:9:@75ns:
      (assertion failure): matvec_core: codebook replica 1 diverged from
      replica 0.
```

Caught at 75 ns, the first codebook write of the run.

Teeth check 2, ALL replicas lagging by four cycles, perfect lockstep preserved.
First WITHOUT the `st` invariant:

```
PASS  sim:tb_matvec_cb_lockstep
PASS  sim:tb_matvec_core
```

Then with it:

```
FAIL  sim:tb_matvec_cb_lockstep  rtl/matvec_core.vhd:506:7:@815ns
FAIL  sim:tb_matvec_core         rtl/matvec_core.vhd:506:7:@245ns
      matvec_core: a codebook write landed after the operation had already
      left idle.
```

Teeth check 3, granularity swept against the C reference. `tb_matvec_core`
compares the RTL to `ref/matvec_int4.c` at EVERY stage, so this is bit-exactness
and not just a matching output:

```
core default CB_ROWS_PER_COPY=1 -> RTL matches ref/matvec_int4.c at every stage
core default CB_ROWS_PER_COPY=2 -> RTL matches ref/matvec_int4.c at every stage
core default CB_ROWS_PER_COPY=4 -> RTL matches ref/matvec_int4.c at every stage
```

and the new testbench passes at all three granularities, including
`CB_ROWS_PER_COPY = ROWS_IF`, which collapses the bank to a single copy and is
therefore the control.

---

## Measured and REJECTED -- do not retry

* **Trusting a behavioural testbench to cover the write timing.** Measured
  twice, in the strongest form available: with the codebook write delayed four
  cycles and all copies in lockstep, `tb_matvec_core` PASSES and
  `tb_matvec_cb_lockstep` -- written specifically to catch this -- also PASSES.
  The reason is structural and it will not go away by writing a better
  testbench: the tightest legal schedule still leaves the activation prefetch
  queue several cycles to fill before the first beat can be accepted, so a late
  write has time to land before any lane reads it. **Do not delete the
  `st /= S_IDLE` assertion on the grounds that a testbench covers it.** Nothing
  does.
* **A master copy with replicas that chase it.** Rejected by construction, and
  named because it is the design most people reach for. A master-then-broadcast
  arrangement has a cycle in which the master has taken the write and the
  replicas have not, so the invariant "all copies agree" is FALSE for one cycle
  on every write and cannot be asserted at all. Peers written together have no
  such window, and that is what makes the check possible.
* **One copy per LANE.** `ROWS_IF * BLK * 128` flops = 196,608 at the FK33
  shape, 22.4% of the device's 879,360 FF, to serve a mux each. Rejected on
  cost. The row boundary gets 48x of the fanout reduction for 3% of the flops.
* **Writing every copy directly from `cb_data`.** This is the trap that nearly
  turned the fix into a no-op: 16 entries x `CB_COPIES` copies means `cb_data`
  drives 768 flop D-inputs at `ROWS_IF = 48`. Removing a 1,536-consumer
  broadcast by adding a 768-consumer one is not progress. The write COMMAND is
  replicated for exactly this reason, so `cb_data` reaches 48 registers and each
  copy's local command register drives its own 16 entries.
* **Deleting the now-empty `elsif cb_we = '1' and st = S_IDLE` arm.** It looks
  like dead code once the write moves to `P_CB`, and it is not: its presence is
  what stops `start` being honoured on the same edge as the last `cb_we`, which
  is the one schedule where the registered write has not landed. The empty arm
  IS the interlock, and it is commented as such in the source.

---

## Measurement traps hit

* **`_replica_N` in a timing report is the tool telling you it already tried.**
  Third instance today: `si_e_seg_reg[4]_replica`, `ns_r_reg[1]_rep__7`, now
  `cb_reg[4][6]_replica_1`. Vivado replicates a high-fanout source by itself
  during physical optimisation, but it does so AFTER placement, when the sinks
  are already fixed. Source-level replication with `DONT_TOUCH` exists to place
  the copies before that is decided, not to do something the tool cannot.
* **A smaller design ran faster by 4% for a 17% area cut**, `ROWS_IF` 58 to 48,
  with the critical path keeping its identity and both delay terms essentially
  unchanged. That is the measurement that says A's problem was never congestion,
  and it is why attacking the broadcast rather than the area was right. Worth
  remembering the next time a timing failure invites a "make it smaller" reflex.
* **The new testbench needed a teeth check of its own, and failed it.** It was
  written to catch a late write, and it does not. Its value is the properties it
  DOES cover -- bit-identical results across load schedules, a different
  codebook producing a different answer, a reload restoring the original -- and
  the run C teeth check inside it, without which runs A and B could agree
  because the codebook reaches nothing at all.
* **`sim/regress.sh` has a `BASELINE_PASS` floor**, currently raised 70 to 71
  here. Its header asks for this whenever a testbench is added. It is a floor
  and not an equality, so forgetting it prints a note rather than failing, which
  means it can be forgotten silently.

---

## Open, not yet answered

* **No Vivado, so no Fmax.** The FK33 bitstream build owns the machine and the
  card goes into the slot tomorrow. Handed over.
* **The granularity sweep is set up but not run.** `CB_ROWS_PER_COPY` = 1, 2, 4,
  and `ROWS_IF` are all bit-exact in simulation; only placement can say which is
  right. `= ROWS_IF` is exactly the pre-fix design and is the free control point.
* **After this, the logic term is the floor and it is a DSP.** 2.212 ns of logic
  with 0.355 ns of overhead caps this path at 1/(2.567 ns) = 389 MHz even with
  zero routing. That logic is the 16:1 mux plus the DSP's multiply and ALU with
  no MREG -- `tr(0)` registers at P, and the level-1 adder is deliberately fused
  onto the multiplier via PCIN. If the codebook fix lands and the path is still
  binding, the next move is an MREG in the product stage: it costs ONE cycle per
  OPERATION, not per beat, because the pipeline is non-stalling, so it is nearly
  free in throughput terms. It has not been attempted here and it is a larger
  change than it looks -- `PIPE`, `P_PART`, `P_SPROD` and `P_CONTRIB` all move.
