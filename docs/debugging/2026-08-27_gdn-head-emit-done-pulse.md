# gdn_head_emit: a one-cycle `done` silently threw away whole heads

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`, defect present since `870ace3`, fix at
`bf5278f`. GHDL mcode backend, `ghdl -r` direct.

## The question

Having verified `gdn_emit_chain` end-to-end (see
`2026-08-27_gdn-emit-chain-w-latch.md`), the remaining integration question was
whether the chain can be fed by its real producer. `gdn_recur_pipe` has **no
ready input** -- `o_res_valid` free-runs -- so a `col_ready` that falls under it
is a lost column, not a stall. The question was therefore: at what column
arrival rate does `col_ready` first fall?

Symptom found instead: at one column every 2 cycles the whole chain froze.
`stall_cyc` stuck at 22, `col_valid='0'`, `col_ready='1'`, `z_valid='1'`,
`z_ready='0'`, nothing advancing for the rest of the run.

## The answer

`gdn_head_emit`'s `done` was a **one-cycle pulse with no handshake**. The
reduce FSM ran on whatever bank was pending regardless of whether the consumer
was free, so if the chain happened to be in `S_GATE`/`S_RMS`/`S_SER` when the
pulse landed, the pulse was missed and the **entire head was discarded**.
head_emit then cleared the bank and moved on. Fixed by holding `done` high
until a new `o_ack` input fires.

## The procedure that produced it

1. **Decouple the testbench's two producers.** The single-process version fed z
   and then columns per head, blocking on `z_ready` first. That coupled the
   streams: the z handshake throttled the column path, `col_ready` was never
   stressed, and a COL_GAP sweep down to one column per cycle reported **zero
   refused columns**. A clean, confident, meaningless result. Two independent
   processes, each parsing the vector file separately, removed the coupling.
2. **Sweep the offered column rate** (`COL_GAP`). gap 4 and 3 passed; gap 2 and
   1 never terminated.
3. **Distinguish wedged from slow before diagnosing either.** gap=2 produced no
   output in 400 s while gap=4 finished in 18 s. That is suggestive, not
   conclusive -- gap=2 does genuinely more work per cycle. A `HEARTBEAT_US`
   generic settled it: at gap=2 the heartbeat reported *identical* state at
   5, 10, 15, 20, 25, 30, 35 and 40 us. Frozen, not slow.
4. **Make the experiment cheap before diagnosing it.** `HEADS` became a
   generic. The reduce-versus-arrival race is per-head and independent of how
   many heads a block has, so `HEADS=4` measures the same thing at a sixth of
   the sim time. This turned a two-hour probe into 15 seconds and is what made
   the next three steps affordable.
5. **Probe the producer, then the consumer.** A temporary reporting process in
   `gdn_head_emit` showed it idle with **both banks empty** waiting for input.
   A second in `gdn_emit_chain` showed it idle at `head=3` of 4, waiting for a
   `done` that had already come and gone.
6. **Count the heads.** 5 heads had been filled, 3 consumed, and head_emit
   holds 2 banks. Two heads unaccounted for. That arithmetic named the cause;
   nothing before it did.
7. **Ack at the right place, established by reading the consumer.**
   `rmsnorm_bf` reads `x_mant` at three separate points across its passes
   (`rmsnorm_bf.vhd:325, 575, 649`), so the result register must stand for the
   whole norm. The chain therefore acks at `rn_done`, not at pickup.

## The evidence

Frozen state at COL_GAP=2, sampled every 5 us and identical every time:

```
CH: state=s_idle head=3 ser_j=128 z_have='1' he_done='0' rn_done='0'
    si_wr=4 si_rd=4 ye_ready='1' consuming='0'
HE: state=s_idle wb=1 rb=1 pend0='0' pend1='0' wr_idx=0 rd_idx=128
    drain=0 in_valid='0' done='0'
```

Before and after, same testbench, 3 blocks x 4 heads x 128:

| COL_GAP | models | before | after |
|---|---|---|---|
| 4 | LANES=32 (real) | PASS, 0 refused | PASS, **0 refused** |
| 3 | -- | PASS, **0 refused** | PASS, 167 refused |
| 2 | LANES=64 | **WEDGED** | PASS, 810 refused |
| 1 | -- | **WEDGED** | PASS, 1516 refused |

**COL_GAP=3 is the row that matters.** It passed before the fix, with zero
back-pressure recorded, because heads were being dropped rather than stalled.
The lossy path reported a *cleaner* result than the correct one does.

Regression on the unmodified unit testbench, which leaves `o_ack` unconnected
and so takes its `'1'` default:

```
overlap phase: 4 heads back-to-back took 1202 cycles
overlap phase: back-pressure asserted at least once: true
tb_gdn_head_emit: PASS -- 64 cases x 128 bit-exact, plus 4 heads back-to-back
```

1202 cycles is the figure recorded when the double buffer was added, unchanged.

## Measured and REJECTED -- do not retry

- **The same-edge `pending` aliasing race.** The hypothesis was that the fill's
  `pending(wb) <= '1'` and `S_DONE`'s `pending(rb) <= '0'` could land on one
  edge with `wb = rb`, the later assignment winning and silently discarding a
  just-filled bank. It is a real VHDL hazard and the code shape invites it. A
  temporary assertion for exactly that condition **never fired**. Do not
  re-investigate; the ordering is safe because `wb` and `rb` are offset by
  construction.
- **The 24,576-element `y_got` signal array as the cost.** GHDL copies a signal
  array on update, so a large collector array was a plausible explanation for
  gap=2 being slow. Reducing `MAX_BLOCKS` from 8 to 2 changed the wall time by
  **nothing** (65 s versus 65 s at gap=4, still >300 s at gap=2). Array size is
  not the cost. Rejected.
- **"gap=2 is just doing more work per cycle."** Plausible -- at gap=2 the
  chain saturates instead of idling -- and it is why step 3 above exists. The
  heartbeat refuted it outright.

## Measurement traps hit

- **A silently lossy path scores BETTER than a correct one.** COL_GAP=3 went
  from "0 refused columns" to "167 refused columns" as a result of a bug FIX.
  Any metric that rewards the absence of back-pressure will prefer the broken
  design. Read a zero back-pressure count as a question, not a result.
- **`pkill -f <pattern>` matched this shell's own command line and killed it**,
  because the pattern appeared in the enclosing loop. Second occurrence in this
  project, after `pkill -f "regress/run.sh"`. **Kill by PID.**
- **A run producing no output is ambiguous between wedged and slow**, and the
  ambiguity is expensive: it cost roughly an hour of alternating theories. A
  heartbeat is cheap and settles it in one run. `HEARTBEAT_US` is now a
  permanent generic on this testbench for that reason.
- **Clearing a signal inside a conditional branch when the process already has
  a default clear** destroys the pulse whenever the condition is always true.
  Introduced while writing the fix (`done_r <= '0'` inside the `o_ack` branch),
  and caught **only** by running the pre-existing unit testbench, which ties
  `o_ack` high through its default and so hit exactly that case. Run the old
  tests, not just the new one.
- **Vivado tcl that derives `rtldir` from `[info script]`** silently targets the
  wrong tree when the script is copied elsewhere. A sweep launched from the
  scratchpad died on `util_pkg.vhd does not exist` and sat "running" for 50
  minutes as far as a `pgrep` was concerned. Run these from the repo.

## Consequence for the spec

The chain's per-head service time now sets a **minimum column arrival period**.
Section 3.1's sweep table contemplates `LANES = 64`, which is COL_GAP=2, and at
that rate `col_ready` falls. Since `gdn_recur_pipe` cannot be stalled, **LANES
= 64 requires an elastic buffer between it and the emit chain, or it will drop
columns.** `LANES = 32` shows zero back-pressure and is safe as built. This
does not change the 589,824-cycle figure, which is a LANES=32 result.

## Open, not yet answered

- **The chain's `CONSUME_BUDGET` watchdog did not catch this.** It counts only
  while `consuming = '1'`, and the failure mode leaves the chain idle with
  `consuming = '0'`. A watchdog that fires on "he_done asserted while not in
  S_IDLE" would have caught it on the first run; it does not exist.
- **HEADS=24 confirmation is still running** at the time of writing. All
  evidence above is at HEADS=4, which is sound for this race but is not the
  shipping configuration.
- **No assertion covers a producer that ignores `col_ready`.** That is now the
  documented failure mode for LANES=64 and nothing detects it.
