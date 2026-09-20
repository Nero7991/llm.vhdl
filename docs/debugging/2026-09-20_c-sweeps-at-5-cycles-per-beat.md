# C does not sweep at 5 cycles per beat. It spends 84% of the position on the score chain and 0 on the cache.

Date: 2026-09-20. TRACK CSWEEP. Simulation only; no hardware was touched.
RTL at `rtl/attn_block.vhd` and `rtl/attn_kv_axi.vhd`, bench
`sim/tb_csweep_rate.vhd` (new), GHDL 1.0.0 mcode.

## The question, verbatim

"Find where the 5.14 cycles per beat go, from the RTL, with quoted code and
line numbers: `rtl/attn_kv_axi.vhd`'s read engine (the realignment mux on the
16-byte `CH_B` granule around :365, the per-job config latch at :632, the
burst issue, outstanding reads, the FIFO) and `rtl/attn_block.vhd`'s sweep
loop (`cpos_r + 1` positions, around :1665-1673). State whether the cost is
per BEAT (a handshake or a narrow unpack) or per POSITION (a setup, a restart,
a burst that cannot span positions). **This is the whole question and the two
have different fixes.** Today's three other findings were all the same shape,
a wide memory reached one item per cycle; do not assume this is a fourth, and
if it is NOT, say so plainly, because that is the more useful result."

The symptom it starts from, MEASURED on silicon the same day
(`docs/debugging/2026-09-20_token-cost-grows-2793-cycles-per-position.md`,
commit `9ab1f41`): a token costs `30,115,217 + 2,793.4 * p` core cycles, 100%
of the slope is subsystem C, and `664,852 / 8 C jobs / 238 positions = 349.2`
cycles per position per C job.

## The answer

**It is NOT a fourth narrow-mover finding, and the 5.14 cycles per beat is an
artefact of dividing a per-POSITION cost by the beats that happen to move
inside it.** The cost is per position and it lives entirely in
`rtl/attn_block.vhd`'s sweep loop. `rtl/attn_kv_axi.vhd` contributes **zero**
cycles: its residency answer is never low inside a record at any position, at
a modelled HBM read latency of 100 cycles, and replacing the whole cache with
a memory that cannot refuse reproduces every span in the breakdown **to the
integer**.

MEASURED, `sim/tb_csweep_rate.vhd` at the real 9B geometry (HEAD_DIM 256,
N_QH 16, N_KVH 4, KV_BLOCK 32, NBLK 8, REC_B 272, AXI_DW 256, MAXB 16,
MAXOUT 4, RBUF 4, RD_LAT 100), one KV head, one position:

| span | cycles | what it is |
|---|---|---|
| KSPAN  | 7.00  | the 8 K beats, one per cycle |
| MIDGAP | 56.42 | P_HDR, P_SCORE, the score drain (P_SCW) and the softmax (P_EPW) |
| VSPAN  | 7.00  | the 8 V beats, one per cycle |
| LOOP   | 17.00 | the two record tails, P_PV's 8 write-backs, P_POSN's drain |
| total  | 87.42 | x N_KVH 4 = **349.7 cycles per position per job** |

against the card's **349.2**: a **0.14%** agreement between a bench and a
silicon measurement that share no arithmetic. The 16 beats of actual data
movement are **16.0%** of the position; 64.5% is the score-and-softmax chain
with nothing overlapped onto it.

**Three independent confirmations that the cache contributes nothing**, and
they fail in different ways so they are not one argument in three costumes:

1. the per-pair breakdown reproduces the card's 349.2 to **0.14%**, and only
   14 of the 87.42 cycles are beats;
2. `krdy_low` and `vrdy_low` are **identically zero** at every position
   measured, counted only inside a record the block has already started;
3. `IDEAL_CACHE` (the cache deleted, `_rdy` tied high) and an RD_LAT sweep
   from 0 to 100 leave **every span unchanged to the integer** -- a per-beat
   cost cannot be invariant under a 100-cycle change in the memory it is
   supposedly bound by.

**So the lever is not a wider memory port and not a deeper burst.** It is that
the sweep loop does one thing at a time.

The fix landed here, `SWEEP_PIPE` (OFF by default), moves WHEN a record beat
is issued and nothing else: the V record of the current position is fetched
while the score and the softmax drain, and the K record of the NEXT position
is fetched during P_PV and P_POSN. Values are bit-identical with it on and
off, checked against `ref/attn_block_vec.c` and `ref/attn_block_seq_vec.c`.

## Procedure

1. **Read the RTL first and predict the spans**, so the bench was checked
   against a model rather than used to form one. `rtl/attn_block.vhd:1702`
   (P_RECK, line numbers are POST-change) issues NBLK beats one per cycle
   while `kr_rdy` stands, then waits `rbi = NBLK`, which is 3 more cycles
   because the capture is a fixed two cycles behind the issue
   (`rbv(1)` -> `rbv(2)` -> `rbi`, :1306-1335). P_PV (:1849) is NBLK
   write-backs plus one, P_POSN (:1862) is `blk < 3` plus the transition.
   Predicted LOOP = 3 + 9 + 4 + 1 = 17. MEASURED LOOP = 17.00 at every
   position from 8 upward.
2. **Build a rate bench at the REAL 9B geometry**, not a scaled one, because
   the quantity in question is `349.2 / 68 beats` and both numerator and
   denominator are geometry. `sim/tb_csweep_rate.vhd` runs one C job at four
   `cur_pos` and prints `CSWEEP_CYCLES <pos> <n>` plus the four spans.
3. **Fit the slope from the two ENDPOINTS and test it on the two interior
   points**, which is the method the card's own measurement used. Fitting to
   all four would not be a test: with two free parameters and four points a
   good fit is nearly guaranteed.
4. **The control that makes the attribution stick: `IDEAL_CACHE`.** It
   replaces `attn_kv_axi` with a memory that can never refuse -- `kr_rdy` /
   `vr_rdy` tied high and a one-cycle registered read, bit for bit the model
   `sim/tb_attn_block.vhd` uses. Everything else is identical. The difference
   between the two runs is the cache and only the cache.
5. **Sweep RD_LAT** on top of that, so "the cache costs nothing" is a
   measurement across latencies rather than one observation at one latency.
6. **Sweep SPREAD**, because `attn_block`'s schedule is data-dependent in
   exactly one place: the softmax rescale pass (P_RSPASS / P_RSACK) fires when
   a position produces a new running maximum. A flat record image would
   under-count that pass and a wild one over-count it, so the size of the term
   had to be measured rather than assumed. **It was, and the answer was not
   the expected one** -- see below.
7. **Implement `SWEEP_PIPE`, then prove the values did not move**, against the
   two independent C oracles, and mutate it with every row run ON and OFF so
   each kill has its own attribution control.

## Evidence

### The bench against the card

```
CSWEEP_CONFIG hd=256 nqh=16 nkvh=4 kvblk=32 nblk=8 rec_b=272 axi_dw=256 maxb=16 maxout=4 rbuf=4 rd_lat=100 stall=0 spread=0 ideal=false sweep_pipe=false
CSWEEP_CYCLES 1 60415
CSWEEP_BREAK 1 pairs=4 kspan=28 midgap=332 vspan=28 loop=0 nloop=0 krdy_low=0 vrdy_low=0 ar=8 rbeat=72
CSWEEP_CYCLES 8 63190
CSWEEP_BREAK 8 pairs=32 kspan=224 midgap=1900 vspan=224 loop=476 nloop=28 krdy_low=0 vrdy_low=0 ar=62 rbeat=598
CSWEEP_CYCLES 16 66087
CSWEEP_BREAK 16 pairs=64 kspan=448 midgap=3692 vspan=448 loop=1020 nloop=60 krdy_low=0 vrdy_low=0 ar=136 rbeat=1194
CSWEEP_CYCLES 64 82791
CSWEEP_BREAK 64 pairs=256 kspan=1792 midgap=14444 vspan=1792 loop=4284 nloop=252 krdy_low=0 vrdy_low=0 ar=540 rbeat=4458
CSWEEP_PER_PAIR 64 kspan_x100=700 midgap_x100=5642 vspan_x100=700 loop_x100=1700
CSWEEP_SLOPE_X100 35517
CSWEEP_TEST 8 measured=63190 predicted=62901 residual=289
CSWEEP_TEST 16 measured=66087 predicted=65742 residual=345
CSWEEP_STATUS err='0' kv_err='0' slv_bad=0
CSWEEP: PASS
```

Two independent readings of the same run, and they agree with the card
differently:

* the endpoint slope, **355.17** cycles per position per job, is **+1.71%**
  on the card's 349.2;
* the asymptotic per-pair sum at position 64, `(7.00 + 56.42 + 7.00 + 17.00)
  * 4 = 349.68`, is **+0.14%**.

The slope is the larger of the two because the job total is slightly convex:
`midgap` falls from 83.00 at position 1 to 59.37, 57.68 and 56.42 and is still
falling, so a two-point fit through position 1 over-states the asymptote.

**I first wrote that the convexity was the softmax rescale pass becoming rarer
as the running maximum settles, and the SPREAD control below REFUTES it**: a
record image that varies with the address produces a schedule identical to a
flat one in every span. Whatever the convexity is, it is not data-dependent,
which leaves a start-up effect in the first position or two after the bypass
as the remaining candidate -- **and that is a candidate, not a measurement.**
The mechanism is OPEN. What is not open is which number to quote: the
asymptotic per-pair sum, because the card's 238-position measurement is
overwhelmingly made of positions in the flat region. Two other benches this
week landed 2.5% and 3.2% from the card with the residual unexplained; this
one lands at 0.14% with a named but unverified residual.

### `krdy_low` and `vrdy_low` are ZERO at every position

Counted only INSIDE a record the block has already started, which is the only
window in which a low `_rdy` is a stall rather than an idle answer. At RD_LAT
100, MAXOUT 4, RBUF 4, four positions: `krdy_low=0 vrdy_low=0` on every row
above. **The cache never refuses a beat the sweep asks for.**

### The IDEAL_CACHE control: identical to the integer

```
### IDEAL_CACHE=true (attn_kv_axi removed; kr_rdy/vr_rdy tied high), SWEEP_PIPE=false
CSWEEP_BREAK 64 pairs=256 kspan=1792 midgap=14444 vspan=1792 loop=4284 nloop=252 krdy_low=0 vrdy_low=0 ar=0 rbeat=0
CSWEEP_PER_PAIR 64 kspan_x100=700 midgap_x100=5642 vspan_x100=700 loop_x100=1700
CSWEEP_SLOPE_X100 34800
### IDEAL_CACHE=true, SWEEP_PIPE=true
CSWEEP_PER_PAIR 64 kspan_x100=700 midgap_x100=695 vspan_x100=700 loop_x100=4642
CSWEEP_SLOPE_X100 26800
```

The second row is the same control applied to the FIX, and it says the saving
is a schedule saving and not a memory one: with the cache deleted, the
per-pair spans with `SWEEP_PIPE` on are `700 / 695 / 700 / 4642`, the SAME
INTEGERS as with the real AXI cache at 100 cycles of latency. The slopes
differ by 7.1 cycles per position (268.00 against 275.11) and that whole
difference is again the per-JOB cost of opening a run once per KV head.

PROVENANCE, because a number taken from a different tree is a failure this
project has recorded: this control was FIRST run against `rtl/attn_block.vhd`
before `SWEEP_PIPE` existed, and was then RE-RUN on the shipped tree with
`SWEEP_PIPE=false`. Both give `kspan=1792 midgap=14444 vspan=1792 loop=4284`
and `CSWEEP_SLOPE_X100 34800`, identical to the digit, so no cross-tree
borrowing is being done here. Every number in this document is from the
committed tree.

`kspan`, `midgap`, `vspan` and `loop` are the SAME INTEGERS -- 1792, 14444,
1792, 4284 -- as the run with the real AXI cache at 100 cycles of read
latency. The endpoint slope differs by 0.7 cycles per position (348.00 against
355.17) and all of that sits in the FIXED part: the cache has to open a run
and pay one read latency at the first position of each head, which is a
per-JOB cost of about 8 x 100 cycles and not a per-position one.

### RD_LAT sweep

Same generics, `SWEEP_PIPE=false`, only the modelled HBM read latency moves.
Per-pair spans at position 64:

| RD_LAT | KSPAN | MIDGAP | VSPAN | LOOP | endpoint slope |
|---|---|---|---|---|---|
| 0   | 7.00 | 56.42 | 7.00 | 17.00 | 348.82 |
| 40  | 7.00 | 56.42 | 7.00 | 17.00 | 351.36 |
| 100 | 7.00 | 56.42 | 7.00 | 17.00 | 355.17 |
| 200 | 7.00 | 56.42 | 7.00 | **29.52** | 411.61 |
| 400 | 7.00 | 56.42 | 7.00 | **96.19** | 690.98 |

**This is the per-beat / per-position discriminator and it answers both
halves.** From 0 to 100 cycles of read latency every span is the SAME NUMBER:
the cache is completely transparent and only the per-JOB constant (opening a
run once per KV head) moves the slope at all. A per-beat cost could not be
invariant under a 100-cycle change in the memory it is supposedly bound by.

**But it is transparent up to a limit, and the limit is worth writing down.**
The fetcher may run `RBUF - 1 = 3` records ahead, which is two positions, so
DERIVED it can hide about `2 x 87.42 = 175` cycles of round trip. At RD_LAT
200 that runway is exceeded and the excess lands in LOOP -- the wait for the
next position's K record -- exactly where the model says it should. So "the
cache costs zero" is a statement about RD_LAT up to roughly 150, not a
universal one.

The card's real read latency in CORE cycles has never been measured. What IS
measured is that the card's 349.2 matches this bench at RD_LAT 0, 40 and 100
alike, because those three are the same number; the card is somewhere in that
flat region and the bench cannot say where.

### The rescale term, SPREAD

`SPREAD` controls the record image: 0 is a flat one, 8 makes every mantissa a
function of the byte address. The point was to bound the one data-dependent
term in the schedule, the softmax rescale pass.

```
CSWEEP_CONFIG ... rd_lat=100 stall=0 spread=8 ideal=false sweep_pipe=false
CSWEEP_PER_PAIR 64 kspan_x100=700 midgap_x100=5642 vspan_x100=700 loop_x100=1700
CSWEEP_SLOPE_X100 35517
CSWEEP_CONFIG ... rd_lat=100 stall=0 spread=8 ideal=false sweep_pipe=true
CSWEEP_PER_PAIR 64 kspan_x100=700 midgap_x100=695 vspan_x100=700 loop_x100=4642
CSWEEP_SLOPE_X100 27511
```

**Identical to SPREAD=0 in every span and in the slope, to the digit, in BOTH
arms.** 355.17 with the generic off and 275.11 with it on, the same two
numbers as the flat image, so the **-22.5% is not an artefact of the
stimulus** either.

That is a NEGATIVE result about the bench, not a reassurance about the design,
and it is worth being precise about which. It does NOT show the rescale pass
is cheap. It shows **this stimulus does not move it**: either the pass is not
firing in either configuration, or varying the record mantissas does not move
the running maximum enough to change how often it fires. The bench therefore
does NOT bound the rescale term, and the earlier claim in this document that
the convexity at low positions was the rescale pass is **WITHDRAWN** -- it was
an inference, this was the experiment that could have supported it, and it did
not.

What it does establish is narrower and still useful: **the 349.7 figure is
insensitive to the one axis on which this bench's made-up data could plausibly
have distorted it.**

## What the RTL says, with line numbers

**Per POSITION, in `rtl/attn_block.vhd`:**

All line numbers are POST-change; `git show HEAD:rtl/attn_block.vhd` has the
sweep states about 170 lines earlier.

* `:1702` P_RECK issues `kr_en` with `kr_blk` one beat per cycle while
  `kr_rdy` stands, `blk` 0..NBLK-1. That is the 7-cycle KSPAN.
* `:1306-1335` the capture is a fixed two cycles behind the issue
  (`rbv(1) <= '1'` at issue, `rbv(2) <= rbv(1)`, `rbi <= rbi + 1` on
  `rbv(2)`), and P_RECK cannot leave until `rbi = NBLK`. That is 3 cycles
  after the last issue, paid twice per position (K and V).
* `:1735` P_HDR, `:1743` P_SCORE (NBLK issues), `:1755` P_SCW
  (`all_zero(sq_busy)`, the `attn_score_q12` drain), `:1763` P_EPW (every
  head's `e_p`, the `attn_softmax` state machine). Together with the tail and
  the header these are the 56.42-cycle MIDGAP, and **none of it overlaps
  anything.**
* `:1849` P_PV issues NBLK write-backs, `:1862` P_POSN burns
  `blk < 3` "to let the PV write-backs land" and then advances `pos_i`. With
  the two tails these are the 17-cycle LOOP.

**Per BEAT, in `rtl/attn_kv_axi.vhd`, and none of it binds:**

* `:365` `CH_B = 16`, the record granule, and the realignment is a chunk
  index `k = n*BEAT_CH + c - PH_CH` evaluated on the beat as it lands
  (the R-beat branch of `P_RD`, `rtl/attn_kv_axi.vhd:777-818`). It is combinational, it
  handles `BEAT_CH = 2` chunks per beat in one cycle, and `r_rready` is tied
  to `"11"` for the life of the design (`:569`), so a beat is never refused
  and the unpack costs nothing.
* `:632` the per-job config latch is reached once per `start`, after the
  drain, and not per position.
* `:857-884` the AR generator issues along the run, capped by `MAXB` (16,
  the AXI3 cap), by the 4 KB rule and by the slot window
  `lim_rec := c_max + RBUF - 2`. MEASURED at position 64: 540 ARs for 4,458
  beats, i.e. 8.26 beats per burst, and 1.05 ARs per record pair. The
  prefetch window (RBUF 4 slots, 3 usable, about 25 beats) is deep enough to
  cover 100 cycles of latency at the rate this consumer actually asks, which
  is 16 beats per 87 cycles.

### The AXI3 constraint, before anyone proposes a burst change

`rtl/hbm_tg_ip.vhd:1036-1039` truncates `arlen(3 downto 0)` at the pin, so
**ARLEN is 4 bits and 16 beats is the hard cap**, not AXI4's 128. A 17-beat
burst does not fail on a 4-bit ARLEN, it silently becomes a 1-beat burst, so
`sim/tb_csweep_rate.vhd`'s read slave checks the cap, the 4 KB rule and beat
alignment explicitly and counts violations into `slv_bad`, which fails the
row. `slv_bad=0` on every run above.

**And it does not matter here.** A deeper burst would move beats that are
already arriving faster than they are consumed. Raising MAXB is not the fix
and neither is raising MAXOUT or RBUF.

## The fix: `SWEEP_PIPE`

`rtl/attn_block.vhd`, generic `SWEEP_PIPE : boolean := false`. **The
dispatcher sets exactly one thing, at `rtl/llama_top.vhd:6621`, the
`u_attn : entity work.attn_block` instance:**

```vhdl
        NORM_LANES => 1, STRICT_PRODUCER => true)     -- before
        NORM_LANES => 1, STRICT_PRODUCER => true,     -- after
        SWEEP_PIPE => true)
```

**`rtl/llama_top.vhd` is NOT this track's file and was NOT edited.** It is
also the INPUT to `tools/gen_cardtop.py`, which emits
`rtl/fk33_llama_top.vhd`, and nothing on the source says so -- that is this
project's recorded generator trap, and it has turned the gate red before for
a comment-only edit. So the sequence is: edit `llama_top.vhd`, regenerate,
`git diff` the generated file and confirm it contains that change and nothing
else, then run `sim/regress.sh --only cardtop`.

What it changes, and it is only WHEN a beat is issued:

* the V record of THIS position is fetched while the score and the softmax
  drain, instead of after them. `vrec` is not read until P_PV.
* the K record of the NEXT position is fetched during P_PV and P_POSN.
  `krec` is read only by P_SCORE, which for this position is over, and the
  quantizer -- the only other writer of `krec` -- runs in P_KQW / P_VQW,
  which cannot be concurrent with the sweep. **No double buffer is needed and
  none is added.**

What it does not change: the beats, their order within a record, the capture,
the addresses, the arithmetic, or any handshake. A beat is still issued only
while that stream's `_rdy` stands.

Two supporting changes were needed and both are inert with the generic false:

* the capture destination is carried WITH the issue (`rbs(1)` / `rbs(2)`)
  instead of read from `ph` two cycles later. In the shipping schedule the
  two are the same fact because a V beat is only ever issued in P_RECV and
  P_RECV cannot be left until the record is captured; under SWEEP_PIPE they
  are not. `cap_v` falls back to `'1' when ph = P_RECV else '0'` when the
  generic is false, which is the expression the capture used inline before.
* `pk_pend`, which says a K request is outstanding. `pk_en` falls on the LAST
  ISSUE while two captures are still in flight, so `pk_en = '0'` alone is true
  for a window in which the record is already on its way.

### What it saves, MEASURED

Same bench, same generics, RD_LAT 100, only the generic moves. The BASE column
is `git show HEAD:rtl/attn_block.vhd` built into its own work library with the
generic added but inert, so it is the pre-change file and not a claim about it.

```
### AB BASE (HEAD attn_block, generic inert)
CSWEEP_CYCLES 64 82791
CSWEEP_PER_PAIR 64 kspan_x100=700 midgap_x100=5642 vspan_x100=700 loop_x100=1700
CSWEEP_SLOPE_X100 35517
### AB NEW SWEEP_PIPE=false
CSWEEP_CYCLES 64 82791
CSWEEP_PER_PAIR 64 kspan_x100=700 midgap_x100=5642 vspan_x100=700 loop_x100=1700
CSWEEP_SLOPE_X100 35517
### AB NEW SWEEP_PIPE=true
CSWEEP_CYCLES 64 77711
CSWEEP_PER_PAIR 64 kspan_x100=700 midgap_x100=695 vspan_x100=700 loop_x100=4642
CSWEEP_SLOPE_X100 27511
```

**`SWEEP_PIPE=false` is IDENTICAL to the pre-change file on every number**, at
all four positions and in all four spans, which is what "OFF by default keeps
the shipping schedule bit for bit" has to mean to be worth saying.

| | per pair | x N_KVH | endpoint slope |
|---|---|---|---|
| off | 87.42 | 349.68 | 355.17 |
| on  | 67.37 | 269.48 | 275.11 |
| saved | **20.05** | **80.20** | **80.06 (-22.5%)** |

The spans re-partition rather than shrink one by one: MIDGAP falls 56.42 ->
6.95 because the V record is now fetched during the score drain instead of
after it, and LOOP rises 17.00 -> 46.42 because the span from the last V beat
to the next K beat now CONTAINS that drain. KSPAN and VSPAN are 7.00 in both,
which is the check that the beats themselves did not move.

### DERIVED on the card

Scaling the card's 349.2 by the MEASURED per-pair ratio 67.37/87.42 = 0.77065:

* per position per C job **349.2 -> 269.1**, i.e. **-80.1 cycles**
* token slope **2,793.4 -> 2,152.7** cycles per position
* the intercept does not move: at p = 0 the sweep has only the bypass
  position and reads no record at all.

| position | now | with SWEEP_PIPE | |
|---|---|---|---|
| 0      | 2.4904 tok/s | 2.4904 tok/s | +0.0% |
| 2,048  | 2.0929 | 2.1724 | +3.8% |
| 8,192  | 1.4151 | 1.5707 | +11.0% |
| 32,768 | 0.6165 | 0.7451 | +20.9% |
| 65,536 | 0.3518 | 0.4381 | **+24.5%** |

The last supported token costs **5.68x** the first instead of 7.08x. That is a
real improvement and it is NOT a fix for long context: the slope is still
2,152.7 cycles a position and 84% of what remains is the score-and-softmax
chain this track did not open.

## Values are bit-identical, against an independent oracle

Not a round trip. Both oracles are C references that share none of the RTL's
machinery.

```
### tb_attn_block SWEEP_PIPE=false
tb_attn_block: PASS -- 3 consumer configurations, 64 elements each, y stream
bit-identical across all of them, y_exp tracks vin_exp exactly, the current
position was never read back, y_exp(run 0) = 15, and BIT-EXACT against
ref/attn_block_vec.c over 130 compared values
### tb_attn_block SWEEP_PIPE=true
tb_attn_block: PASS -- 3 consumer configurations, 64 elements each, y stream
bit-identical across all of them, y_exp tracks vin_exp exactly, the current
position was never read back, y_exp(run 0) = 15, and BIT-EXACT against
ref/attn_block_vec.c over 130 compared values

### tb_attn_kv_seam SWEEP_PIPE=false     (@457945ns)
tb_attn_kv_seam: PASS -- 4 tokens at cur_pos 0..3 x 2 layers INTERLEAVED
token-major (8 jobs) through rtl/attn_kv_axi.vhd over AXI at 100-cycle read
latency, BIT-EXACT against ref/attn_block_seq_vec.c over 2056 output values
and 2176 record bytes in HBM, every returned beat matched to the layer and
position it was requested for, k_base=16 v_base=4064 (neither 4 KB aligned),
MAXCTX=8, longest quiet stretch 2137 cycles against a watchdog of 20000
### tb_attn_kv_seam SWEEP_PIPE=true      (@455905ns)
tb_attn_kv_seam: PASS -- ... identical text ...
```

`tb_attn_kv_seam` is the one that matters, because Q2 checks the RECORD IMAGE
in HBM at C spec 2.2's address and Q3 matches every returned beat to the
`(layer, head, position, block)` it was requested for. "The block computed the
right numbers" and "the record came from the right address" are different
claims, and a prefetch that fetched the wrong position could satisfy the first
alone. The same run is also 2,040 ns faster with the generic on, which is the
saving showing up at a geometry four times smaller than the card's.

The recorded `attn_kv_axi` trap is untouched and still bites: a base one byte
off is quantised away by the READ engine (`ph_ch = low_bits(a0,BEAT_LW)/CH_B`,
an integer divide by 16) and honoured by the WRITE engine, so the record lands
late and the reader cannot see why. The refusal lives in `P_JOB` at
`rtl/attn_kv_axi.vhd:619` and **nothing in this change touches any address
arithmetic in either file.** `sim:kvmap` is green
(`check_kv_map: 40 rows, 0 refused, 0 not run`) and `sim:tb_attn_kv_map` and
`sim:tb_attn_kv_seam` both run with `k_base=16 v_base=4064`, neither 4 KB
aligned.

## Teeth

`sim/mutate_attn_sweep_pipe.sh`, oracle `sim/tb_attn_kv_seam.vhd` against
`ref/attn_block_seq_vec.c`. **Every row is run twice** -- the same edit with
the generic ON and with it OFF -- and the OFF run is the attribution control:
for a mutation of the new path it must SURVIVE, which says the kill belongs to
`SWEEP_PIPE` and not to an older property the edit happened to trip.

Verdicts are `sim/mutverdict.py`'s three, not two. **KILLED means the CHECKER
noticed and said so; ABORT means the run never reached a verdict the checker
owns**, and an ABORT is NOT counted as a kill.

| row | what it breaks | ON | OFF | reading |
|---|---|---|---|---|
| `A` | nothing, the anchors | PASS | PASS | both anchors clean |
| `P1` | capture destination read from `ph` instead of carried with the issue | **ABORT:LANG** | PASS | see below |
| `P2` | the K request stops leading `pos_i`, so the prefetch re-reads THIS position | **KILLED** | PASS | the one clean, fully attributed kill |
| `P3` | the V capture index reversed inside the record | **ABORT:LANG** | PASS | see below |
| `P4` | `pv_got` not cleared when the V prefetch is armed | PASS | PASS | **DID NOT BITE** -- see below |
| `P5` | K and V prefetch armed together | ABORT:DUTASSERT | PASS | the new assert fires |
| `P5c` | **P5 with the new assert DISABLED** (attribution control) | **KILLED** | -- | see below |
| `P6` | the SHARED capture index `cidx_k` pinned to 0 | PASS | **KILLED** | see below |
| `P7` | V prefetch armed one state later | ABORT:LANG | -- | **UNREACHABLE mutant, see below** |
| `P8` | `pk_pend` guard removed -- **the defect that actually happened** | ABORT:DUTASSERT | PASS | the assert fires |

```
 TOTAL 18   KILLED 3   SURVIVED 10   ABORT 5
   A_on PASS   A_off PASS   P1_on ABORT:LANG   P1_off PASS
   P2_on KILLED  P2_off PASS   P3_on ABORT:LANG   P3_off PASS
   P4_on PASS    P4_off PASS   P5_on ABORT:DUTASSERT   P5_off PASS
   P5c_on KILLED P6_on PASS    P6_off KILLED
   P7_on ABORT:LANG   P8_on ABORT:DUTASSERT   P8_off PASS
```

```
P2_on  KILLED     -- P2 K request does not lead pos_i, SWEEP_PIPE=true
        tb_attn_kv_seam: Q1 -- token 4 element 0 = 2023, the oracle says 2162.
        MISMATCH against ref/attn_block_seq_vec.c
P6_off KILLED     -- P6 same edit, SWEEP_PIPE=false
        tb_attn_kv_seam: Q1 -- token 2 element 0 = -4740, the oracle says -5945.
```

**This is a weak mutation result and it is reported as one.** Of four
mutations aimed at the new path, exactly ONE (`P2`) produced a clean
attributable kill by the value oracle. Row by row:

* **`P1` and `P3` ABORT on a GHDL bound check before the checker speaks.** A
  misrouted capture drives `pk_cnt` / `pv_cnt` past their `0 to NBLK` range,
  and the LANGUAGE notices first. **The value oracle was NOT shown to catch a
  misrouted capture**, and it must not be credited with it. Worse, the abort
  is hiding what silicon would do: in gates the counter wraps and the answer
  is silently wrong. The fix is to saturate the increment rather than let it
  overflow, so simulation behaves the way the hardware will and the oracle
  gets to judge. **That change was prepared and deliberately NOT applied**,
  because applying it would have invalidated every A/B and oracle run above
  and there was no lane left to re-run them. It is the first item of open
  work below.
* **`P4` DID NOT BITE, and the reason is that the edit is a no-op.** It
  removes `pv_got <= '0'` from the ARM, but P_RECV already clears `pv_got`
  when it CONSUMES it, so the arm's clear is redundant. **A mutant that
  changes nothing has tested nothing**; this is not a gap in the checker, it
  is a gap in the mutant, and the row is kept under its own name rather than
  quietly dropped. The load-bearing clear is the one in P_RECV and it has no
  row.
* **`P5c` is the attribution control for the new assert, and the answer is
  the unflattering one.** With the assert disabled, the SAME mutant is
  **KILLED by the value oracle**. So the assert is a faster and better-located
  DIAGNOSTIC -- it names the cycle and the cause instead of a wrong number
  four tokens later -- but it is **not a new detection**, and it must not be
  counted as one. It is kept because it found `P8` during development, before
  any value run existed, and because the argument it checks is exactly the one
  I had got wrong.
* **`P6` is a one-mode mutant by construction**, which the "expected" block in
  the script got wrong before the run. `cidx_k` reduces to `pk_cnt` under
  `SWEEP_PIPE`, so pinning the `else` arm to 0 is unreachable with the generic
  on. The load-bearing row is `P6_off`, and it is KILLED: **the refactor that
  replaced a literal `rbi` in the capture with `cidx_k` did not quietly retire
  the check that was already there.**
* **`P7` was UNREACHABLE and is recorded rather than deleted.** It armed
  `pv_en` without resetting its counters, so the run died on a bound check and
  the checker never spoke. **A mutant that cannot be reached proves nothing
  about the checker** -- it was meant to be the honest non-biting row showing
  that a value oracle cannot see a pure schedule change, and it failed to be
  even that. The replacement (issue on alternate cycles: same beats, same
  order, half the rate) is written and unrun.

**`P8` is the row worth the most and it is not a constructed mutant.** It is
the state this change was actually in when it was first run: `pk_en` falls on
the LAST ISSUE while two captures are still in flight, so `pk_en = '0'` alone
is true for a window in which the record is already on its way, and P_RECK
re-armed the same fetch inside that window. The re-arm was still running when
P_RECK consumed the original and armed V -- the one state the shared `rbv` /
`rbs` pipe cannot represent. It was found by the assert on the first
`tb_attn_block` run with the generic on, at
`rtl/attn_block.vhd:1362:11:(assertion failure): attn_block: SWEEP_PIPE issued
a K beat and a V beat in the same cycle`. `P8_off` PASSES, so it is confined
to the new path. **`P8` has no `P8c` attribution control** -- it was written
and not run -- so by the same standard applied to `P5c` above, whether an
older property would also have caught `P8` is NOT established.

## The gate rows, every OVERALL line verbatim

All five were run AFTER the last edit to `rtl/attn_block.vhd`, against the
committed tree, one group per `regress.sh` invocation with its own
`REGRESS_SCRATCH` under `/mnt/storage`. An earlier `--only tb_attn` run that
overlapped two RTL edits was discarded rather than quoted: this project's own
record says a gate run that overlapped an edit proves nothing about either
version.

```
########## --only tb_csweep_rate
 suite sim   PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## --only tb_attn
 suite sim   PASS 16   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 16   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1   SKIPPED 4
 REGRESSION: PASS
########## --only seamgate
 suite sim   PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## --only tb_llama_top_kv
 suite sim   PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## --only kvmap
 suite sim   PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

`--only` takes a SUBSTRING, not a regex, and `PASS 0` would mean the pattern
matched nothing; every group above has a non-zero PASS. `--only tb_attn`
reports `NOCHECK 1` and `SKIPPED 4`, which is its standing shape (the
`library beh` netlist-compare rows need xsim + UNISIM) and is unchanged by
this work.

The `sim:tb_csweep_rate` row is new and it is a row for every track from now
on, whether its author meant it or not. Its defaults are deliberately small
(positions 1/8/16/64) so it runs in about three minutes, and its teeth are
`SLOPE_MAX_X100`, a ceiling on the measured cycles per position. The
1/64/256/1024 sweep the finding needed is driven from the command line.

## Measured and REJECTED -- do not retry

* **"C is a fourth narrow mover; widen the port."** REJECTED. The 16 beats a
  position moves occupy 14 of its 87.42 cycles and the cache never refuses
  one. A wider port cannot remove a cycle that is not being spent on the
  port. The 5.14 cycles per beat is `349.2 / 68` and 68 is not a rate, it is
  the number of beats that happen to fall inside a per-position cost.
* **Raise `MAXB` above 16.** REJECTED twice over: the FK33 HBM slave is AXI3
  and `rtl/hbm_tg_ip.vhd:1036` truncates ARLEN to 4 bits, so 16 IS the cap;
  and MEASURED, bursts already average 8.26 beats because the slot window,
  not the cap, is what bounds them.
* **Raise `MAXOUT` or `RBUF`.** REJECTED. `krdy_low = vrdy_low = 0` at
  RD_LAT 100, so there is no stall for a deeper window to hide.
* **Blame the 16-byte realignment mux.** REJECTED. `r_rready` is tied `"11"`
  for the life of the design (`rtl/attn_kv_axi.vhd:569`), both chunks of a
  beat are placed in the same cycle, and removing the entire cache changes no
  span by one cycle.
* **Blame the per-job config latch at `:632`.** REJECTED. It is reached once
  per `start`. A per-job cost cannot produce a per-position slope, and the
  slope is what the card measured.

## Measurement traps hit

1. **A signal assigned twice in one delta keeps only the last value.** The
   bench's `n_ar <= n_ar + 1` and `n_beat <= n_beat + 1` sat inside a
   `for s in 0 to 1` loop over the two read masters, so any cycle on which
   both masters acted counted ONE event. MEASURED before the fix: `rbeat=2229`
   for a sweep that moves 4,352 beats, i.e. almost exactly half. This is the
   project's recorded bench-counter trap in a new place; the fix is to
   accumulate in a VARIABLE and assign once. **It did not affect the finding**
   -- the spans are taken from `kr_en`/`vr_en`, which are scalars -- but a
   number that is silently halved is one nobody can reason from.
2. **`ghdl -r` refuses a work library whose source has changed, and a
   backgrounded batch then produces NOTHING at all.** Two full A/B batches
   were lost because the bench was edited while they were queued. The output
   is not an error the operator sees; it is an empty section under a heading
   that looks like it ran. Make every edit before launching a batch, and
   check that each section of a batch log is non-empty before reading it.
3. **A pipe through `grep` is block-buffered, so a long batch looks stalled.**
   The same shape as this project's recorded "a buffered log's line count is
   not a progress signal". Count completed sections, not elapsed time.
4. **The seam bench's read slave re-arms its latency timer AFTER each burst
   completes**, so two outstanding bursts cost `2*RD_LAT` rather than
   overlapping. That is correct for a correctness bench and WRONG for a rate
   one: it would have charged the design about 62 cycles per record for the
   model's own choice, which is most of the per-position cost, and the wrong
   answer would have looked like a confirmation of the narrow-mover theory.
   `sim/tb_csweep_rate.vhd` stamps each accepted AR with `now + RD_LAT` and
   serves in order.
5. **The new assert caught a defect in its own change on the first run**, and
   the reading of the schedule that made me write the assert was wrong in
   exactly the way the assert was for: I had convinced myself the K and V
   prefetches could never be armed together, and they were, because `pk_en`
   falls one cycle before the record is captured. Written down because the
   argument FELT airtight, and the only reason it was caught is that it was
   made checkable instead of being left as a comment.
6. **A bench with no ceiling is decoration.** `sim/tb_csweep_rate.vhd`
   initially printed the slope and passed whatever it was. A schedule
   regression in the sweep loop would have raised the number and left the row
   green. `SLOPE_MAX_X100` is the teeth.
7. **I matched a process by its COMMAND LINE and killed my own shell.** The
   project's CLAUDE.md records this as the `pgrep -f` self-match trap and says
   the bracket trick does not save you, because the text belongs to a SIBLING
   process. I hit it anyway, in a hand-rolled `/proc` loop, exactly as the
   fifth recorded instance did: the loop scanned `/proc/PID/cmdline` for
   `phase2.sh`, and the shell interpreting that loop CARRIED the string
   `phase2.sh` in its own `cmdline`. The kill landed on the shell. **The rule
   that would have worked is the one already written down: identify a process
   by `/proc/PID/exe` or `/proc/PID/cwd`, which a command line cannot spoof,
   or -- as here, where the target is `bash <script>` and `exe` is just bash
   -- keep the PID from the launch and kill that.** Nothing was lost because
   the target scripts were the ones being killed, but the same command with a
   different target is how a session ends.
8. **Chaining work on a sentinel is right, and chaining an RTL EDIT on one is
   not.** Two follow-on scripts were armed to wait for the sweep's sentinel
   and then patch `rtl/attn_block.vhd`. That is a queued edit with no operator
   in the loop: had it fired, every A/B and oracle result above would have
   been measured against a file that no longer existed, and nothing in the
   output would have said so. They were killed unfired and the patch was NOT
   applied, which is why the committed RTL is byte-for-byte the version every
   number here was taken from. **Queue measurements behind a sentinel; never
   queue a change to the thing being measured.**

## Open, not determined

* **`pk_cnt` / `pv_cnt` should SATURATE rather than overflow, and they do
  not yet.** MEASURED by mutants `P1` and `P3`: a misrouted capture runs them
  past their `0 to NBLK` range and GHDL aborts before the value oracle can
  speak, so the oracle has never been shown to catch that defect class -- and
  in gates the counter wraps and the answer is silently wrong instead. The
  one-line guard (`if pk_cnt < NBLK then ... end if;`) is written. It was NOT
  applied here because applying it would invalidate every A/B and oracle run
  in this document and there was no lane left to re-run them. **Whoever picks
  this up: apply it, re-run `sim/mutate_attn_sweep_pipe.sh`, and expect `P1`
  and `P3` to turn from ABORT into KILLED. If they do not, the oracle really
  cannot see a misrouted capture and that is a bigger finding than this one.**
* **`P7`'s replacement and `P8c` are written and unrun**, so "a value oracle
  cannot see a pure schedule change" is stated here as a construction
  argument and not as a measurement, and whether an older property would also
  have caught `P8` is not established.
* **`SWEEP_PIPE` at RD_LAT 200 and 400 was not run.** The fix cuts the
  per-position budget from 87.42 to 67.37 cycles, and the runway the prefetch
  window buys is DERIVED as about two positions of that budget -- so the
  latency the cache can hide falls with it, from roughly 175 cycles to roughly
  135. **The fix may therefore make the design MORE latency-sensitive**, and
  the RD_LAT 200 row with the generic on is the measurement that would say. It
  was queued and cancelled. Until it is run, do not assume the -22.5% survives
  a card whose real read latency is above ~135 core cycles -- a number nobody
  has measured either.
* **The AREA and TIMING cost of `SWEEP_PIPE` is UNMEASURED.** No Vivado was
  run: the box's one lane was on a card build for the whole of this track.
  DERIVED from the diff, the added state is about 23 flip-flops
  (`pk_en/pk_blk/pk_cnt/pk_got/pk_act/pk_pend`, `pv_en/pv_blk/pv_cnt/pv_got`,
  `rbs`) plus a 4-bit mux on the `krec`/`vrec` write-decode compare. That is
  an ESTIMATE and the project's own record says an estimate of this kind has
  been wrong by 12 percentage points before. **Do not set the generic on a
  build without an OOC run.**
* **`MIDGAP`'s 56.42 cycles have not been split** into P_HDR, P_SCORE, P_SCW
  and P_EPW. `attn_block`'s `ph` is a locally-declared enumeration so it
  cannot be reached by a VHDL external name, and no port exposes it. About 40
  of those cycles are the `attn_score_q12` drain plus the `attn_softmax` state
  machine, DERIVED by subtracting the countable parts (4 tail + ~3 header +
  8 score issues + 1), not measured. **That is where the remaining 64% of the
  position is and this track did not open it.**
* **Whether the score of position p+1 can be computed while the softmax of
  position p drains** is the obvious next lever and it is NOT answered here.
  The running maximum is a genuine serial dependency; the SCORE is not. A
  depth-2 software pipeline of the sweep would hide the K fetch, the header
  and the score issue inside the drain. It is a much larger change to a
  bit-exact block than `SWEEP_PIPE` and it was not attempted.
* **The bench's stimulus is not the card's data.** Records and activations are
  deterministic functions of the address. The one place this can matter is the
  rescale pass; its size is measured by the `SPREAD` rows above rather than
  assumed, but "the card's rescale rate equals SPREAD=n's rescale rate" is not
  established for any n.
* **`SWEEP_PIPE` has not been run at any geometry between the seam bench's
  (HEAD_DIM 64, NBLK 4) and the card's (HEAD_DIM 256, NBLK 8).** Both were
  run; nothing in between was.
* **No `llama_top` / `fk33_llama_top` row runs with the generic on**, because
  this track does not own those files. The one-line change is in "The fix"
  above.
