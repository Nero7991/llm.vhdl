# Where do subsystem A's 0.53 cycles per weight word go?

TRACK AIDLE, 2026-09-20. Workstation, MAIN checkout, branch `fpga`, tree at
`8771f32` plus this track's two commits. **No hardware was touched.** No
Vivado was run on the workstation; the two area draws ran on the BC-250
(`cachyos-bc250`, 192.0.2.133), whose lane was idle.

Tools named: `ghdl-mcode 1.0.0`, `python3` over
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json`,
Vivado 2023.2 on the BC-250, `git`.

Labels: **MEASURED** (a named tool ran), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement with its assumption stated).

---

## 1. The question, verbatim

> A's multiplier array is **exactly one weight word wide**, an identity rather
> than a ratio: `NPORTS_W * AXI_DW = 24*256 = 6144 bits = ROWS_IF*BLK*4 =
> 48*32*4`. So the structural floor is **1.000 core cycles per weight word**.
> The lane-striped card MEASURES **1.5298**. The array is busy **65.4%** of
> core cycles and idle the rest. [...]
>
> **YOUR JOB: find where the 0.53 cycles per word go, and close as much of it
> as the RTL allows.** [...] PREFILL noted the 0.53 could be per-job overhead
> OR a per-word stall and that its conclusion held either way; for YOUR
> purposes the distinction is the whole question, so settle it. A per-job
> fixed cost and a per-word stall have completely different fixes.

---

## 2. The answer, up front

**It is a per-word stall, 96.7% of it, and it is ONE LINE in
`rtl/stream_fifo.vhd` and the identical line in `rtl/async_fifo.vhd`:**

```vhdl
do_rd <= '1' when mcnt > 0 and (ocnt + inflight) < 2 else '0';
```

That condition counts the beat **leaving** the two-entry output stage at this
same edge as if it were staying. With a producer offering a beat every cycle
and a consumer holding `q_ready` high, the FIFO settles into a three-cycle
cadence -- pop, pop, `q_valid` LOW -- and sustains **2 beats per 3 cycles**.
`matvec_core` accepts a weight word only when all 24 weight FIFOs and all 3
scale FIFOs present a beat in the **same** cycle
(`rtl/matvec_core.vhd:860-863`), so 1.5 in the FIFO is 1.5 in the array
whatever the memory does.

**MEASURED, with no AXI and no array in the loop** (`tb_fifo_rate`, section
4.1): **1.501 cycles per beat, `q_valid` low 1,003 of 3,003 cycles.** The
card's own fitted slope is **1.51010** (TRACK DSIDE over all 311 A_JOB steps).
The gap between those two numbers, 0.0101 cycles per word, is everything the
HBM, the address map, the CDC, `MAXOUT`, `MAXB` and the AR throttle contribute
put together.

**The fix is one term**, behind `FAST_POP`, defaulting to the old behaviour:

```vhdl
after_e <= ocnt + inflight - 1 when (ocnt > 0 and q_ready = '1')
           else ocnt + inflight;
do_rd   <= '1' when mcnt > 0 and after_e < 2 else '0';
```

Same invariant, evaluated one pop later. It cannot overrun the two entries and
`ocnt`'s `0 to 2` range is the proof. **Order and values are untouched**: both
arms read `mem` at `rp` and advance `rp` by one per read; only the issue cycle
moves.

**MEASURED end to end** on a real A shape (100 x 4096, ideal memory):

| | CYCLES | ACCEPT | W-stall | S-stall | control states | cycles/word |
|---|---:|---:|---:|---:|---:|---:|
| `FAST_POP=false` | 613 | 384 | **202** | 1 | 26 | **1.5963** |
| `FAST_POP=true` | 422 | 384 | **10** | 1 | 27 | **1.0989** |

**DERIVED saving on the card, at the fitted slope:**
`5,187,328 words x (1.5101 - 1.0101) = 2,593,664 cycles per token`, **8.61% of
the 30,115,246-cycle lane-striped token, for zero DSPs, on generation as well
as prefill.** That is **94.4%** of the 2,746,816 cycles TRACK PREFILL
identified as the entire prize, and PREFILL's row 5 -- full batching of A --
buys the same cycles for 1,536 DSP48E2 that do not exist.

**The one thing that could still stop it is TIMING, not area**, and it is
named in section 7 because the new term puts `q_ready` into `do_rd`, and
`q_ready` is the AND of all 27 ports' `q_valid`.

---

## 3. Settling per-job against per-word, before anything else

The brief said the distinction is the whole question, so it is settled first
and from numbers that already existed.

TRACK DSIDE fitted all 311 unfolded `A_JOB` steps of the lane-striped
token-0 profile (`docs/2026-09-20_d-side-vector-traffic.md` section 4.1):

```
fit  engine = 294.07 + 1.51010 * beats        n = 311
residual mean -0.0, sd 51.5, min -197, max +81
sum engine 7,924,852
```

and this track re-derived the word count independently from the striped
manifest rather than inheriting it:

```
words = sum over the 249 matvec tensors of ceil(M/48) * ceil(K/32)
      = 5,187,328        (python3 over
                          qwen35-9b-mv4i-noembd-striped/manifest.json)
```

**DERIVED:**

| term | cycles | share of the excess |
|---|---:|---:|
| floor, one word per core cycle | 5,187,328 | |
| engine-side MEASURED | 7,924,852 | |
| **excess over the floor** | **2,737,524** | 100% |
| per-job constant, `311 x 294.07` | 91,456 | **3.34%** |
| per-word, `5,187,328 x 0.51010` | 2,646,056 | **96.66%** |

**So it is a per-word stall and the per-job constant is noise.** The two sum
to 2,737,512 against 2,737,524, i.e. the fit's two parameters account for the
whole excess with 12 cycles left over across a token.

**And it does not matter which per-job cost you name**, which is why chasing
the descriptor fetch, `S_CHECK`, the 17-cycle codebook load or the `S_EMIT`
epilogue was never going to be worth anything: all of them together are
capped at 91,456 cycles, 0.30% of the token. Section 6 of the earlier
PREFILL document guessed "about 8,832 cycles per job"; the fit says 294, and
the difference is that 8,832 was the whole excess divided by 311 on the
assumption it was per-job. **It is not.**

---

## 4. The procedure, in the order it was run, and what each step isolates

### 4.1 A FIFO alone, with a perfect producer and a perfect consumer

This is the step that settled it, it took three seconds, and it contains no
AXI, no memory model, no array and no clock-domain crossing. `tb_fifo_rate`
(in this track's scratch; section 11 says how to rebuild it) drives `stream_fifo` with
`i_valid` high until N beats are pushed and `q_ready` tied high, counts the
cycles to drain N beats, counts the cycles `q_valid` is low, and asserts that
every popped word equals a counter -- so a rate result and an order result
come out of the same run.

**MEASURED, the shipping RTL:**

```
FIFORATE tag=stream_OLD N=2000 cycles_to_drain=3003 qvalid_low=1003 cycles_per_beat_x1000=1501
```

**1.501 cycles per beat. `q_valid` low 33.4% of the time.** The trace, with
`(ocnt, mem_q_v)` read pre-edge and `mcnt` large:

```
(1,1): ocnt + inflight = 2, no read issued;  a beat lands, one pops -> (1,0)
(1,0): ocnt + inflight = 1, read issued;     nothing lands, one pops -> (0,1)
(0,1): ocnt + inflight = 1, read issued;     a beat lands, NONE pops -> (1,1)
                                             ^ q_valid was LOW this cycle
```

**What it isolates.** Everything outside the FIFO. If the number had come
back 1.000 the cause would have been upstream and this would have been the
control that said so.

### 4.2 The same line is in `async_fifo`, which is the FIFO the card runs

`hw/fk33/gen_fk33_engine.py` passes `DUAL_CLK => true`, so all 27 of A's
ports and the descriptor master instantiate `rtl/async_fifo.vhd`, not
`stream_fifo`. Its read domain carries the identical condition
(`async_fifo.vhd:350-351` before this change):

```vhdl
  do_rd    <= '1' when empty_r = '0' and clr_r_s2 = '0'
                   and (ocnt + inflight) < 2 else '0';
```

with the identical two-entry stage and the identical `mem_q`/`mem_q_v`
registered read. **The two files' output stages were written from each other
and the comment in `async_fifo` says so** ("same shape as
rtl/stream_fifo.vhd and for the same reason"). So the single-clock
measurement transfers, and the whole-engine bench below is run single-clock
for the same reason TRACK COUNTERS ran its bench single-clock.

### 4.3 Where it reaches the array: the accept port

`rtl/matvec_core.vhd:860-863`:

```vhdl
  accept <= '1' when st = S_RUN and w_valid = '1' and s_valid = '1'
                     and xq_cnt > 0 else '0';
  w_ready  <= accept;
  s_ready  <= accept;
```

and `rtl/weight_streamer.vhd`'s pop gate, which is the AND over all 24
weight ports:

```vhdl
  agg : process(qv)
  begin
    a := '1';
    for p in 0 to NPORTS_W-1 loop a := a and qv(p); end loop;
    all_v <= a;
  end process;
  pop_w   <= all_v and w_ready;
  w_valid <= all_v;
```

plus the same lockstep over the 3 scale ports at `s_agg`. **A word is
accepted only when 27 FIFOs present a beat in the same cycle**, so a cadence
that holds any one of them low one cycle in three holds the array at 1.5.

### 4.4 The three stall reasons, separated at the port

`STARVED` sees only `not w_valid`. `rtl/matvec_int4_desc_axi.vhd`'s header
has said since 2026-08-30 that it "does NOT see the SCALE path, so a cycle
with every weight FIFO full and the scale superword missing counts as
neither BEATS nor STARVED", and
`docs/debugging/2026-08-30_counters-cycles-beats-starved.md` section 8 left
that residual open because nothing observed it. This track added the
observable -- `dbg_sstarve <= wv and not sv` in `rtl/matvec_int4.vhd`, one
AND gate, unassociated at every existing instantiation -- and the bench
partitions every cycle of the CYCLES window into exactly four buckets with
an assertion that they sum to CYCLES.

**MEASURED, and the answer is that the scale path is not the problem:**

```
AIDLE_STALL W 202        weight FIFOs: at least one empty
AIDLE_STALL S 1          weights present, the scale superword was not
AIDLE_STALL XCTRL 26     activation queue empty, or a control state
AIDLE_STALL ACCEPT 384
```

One cycle. The scale path has `GRP = NPORTS_S*AXI_DW / (ROWS_IF*16) = 1` at
this geometry, so `s_take` refills `s_hold` in the same cycle the chunk is
consumed and the holding register never bubbles. **The 10% to 47% residual
the engine's header warns about is real on silicon and is not this.**

### 4.5 The whole-engine bench, and its calibration against the card

`tb_aidle_rate` is TRACK COUNTERS' `tb_ctr_rate` with `FAST_POP` plumbed
through, the stall split by reason, and the `y` stream dumped to a file so
value identity is a `cmp` rather than an argument. **Its first run
reproduces TRACK COUNTERS' run A exactly, all four counters** -- 613 / 384 /
202 / 27 -- which is what makes the before-number admissible rather than a
new bench agreeing with itself.

**And it lands on the card.** At the real shape `M = 2048, K = 4096` (48 jobs
per token), with an ideal memory:

| | cycles | cycles/word |
|---|---:|---:|
| this bench, `FAST_POP=false` | 8,333 | 1.5139 |
| **the card, same shape** (DSIDE per-shape table, mean engine) | **8,601** | **1.5627** |
| residual | **+3.2%** | |

TRACK BMOVER's equivalent bench sat 2.5% off the card and that residual is
still unexplained; this one is 3.2% off, in the same direction (the card is
slower than the ideal-memory bench), and it is not explained here either.
**What the 3.2% bounds is how much of the card's 1.5101 can belong to
anything other than the FIFO: at most 0.05 cycles per word.**

---
## 5. The evidence, as raw output

### 5.1 The FIFO alone (`tb_fifo_rate`, `rtl/stream_fifo.vhd`, no AXI, no array)

```
FIFORATE tag=FP_false N=2000 cycles_to_drain=3003 qvalid_low=1003 bp=0  cycles_per_beat_x1000=1501
FIFORATE tag=FP_true  N=2000 cycles_to_drain=2004 qvalid_low=4    bp=0  cycles_per_beat_x1000=1002
FIFORATE tag=FP_false N=2000 cycles_to_drain=3896 qvalid_low=802  bp=30 cycles_per_beat_x1000=1948
FIFORATE tag=FP_true  N=2000 cycles_to_drain=3035 qvalid_low=4    bp=30 cycles_per_beat_x1000=1517
```

`bp=30` is a consumer that drops `q_ready` on about 30% of cycles; the rate
falls in both arms, as it must, and the lever still buys 22%.

### 5.2 `tb_aidle_rate`, the whole engine, ideal memory, sweep of read latency

Read latency in this bench's memory model is now PIPELINED per outstanding
burst, not serialised at the head of each port's queue -- see section 7,
trap 2, which is the parent bench's own recorded trap and had to be fixed
before any `MAXOUT` or latency row meant anything.

| shape | LAT | `FAST_POP` | CYCLES | ACCEPT | W | S | XCTRL | cycles/word |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| 100x4096 | 0 | false | 613 | 384 | 202 | 1 | 26 | 1.5963 |
| 100x4096 | 0 | **true** | **422** | 384 | **10** | 1 | 27 | **1.0989** |
| 100x4096 | 40 | false | 652 | 384 | 241 | 1 | 26 | 1.6979 |
| 100x4096 | 40 | **true** | **461** | 384 | **49** | 1 | 27 | **1.2005** |
| 100x4096 | 80 | false | 692 | 384 | 281 | 0 | 27 | 1.8020 |
| 100x4096 | 80 | **true** | **501** | 384 | **89** | 0 | 28 | **1.3046** |
| 2048x4096 | 0 | false | 8,333 | 5,504 | 2,762 | | 67 | 1.5139 |
| 2048x4096 | 0 | **true** | **5,582** | 5,504 | **10** | | 68 | **1.0141** |
| 2048x4096 | 80 | false | 8,412 | 5,504 | 2,841 | | 67 | 1.5283 |
| 2048x4096 | 80 | **true** | **5,661** | 5,504 | **89** | | 68 | **1.0285** |

**The saving is a constant 191 cycles at 384 words and 2,751 at 5,504 words,
independent of latency**, which is what a per-word stall looks like and what
a per-job cost does not. On the big real shape it is **-33.0%**.

### 5.3 `MAXOUT` sweep at LAT = 80, and it is inert until the FIFO is fixed

```
MO2_L80  fast_pop=false  CYCLES=692   MO2_L80  fast_pop=true  CYCLES=533
MO4_L80  fast_pop=false  CYCLES=692   MO4_L80  fast_pop=true  CYCLES=501
MO8_L80  fast_pop=false  CYCLES=692   MO8_L80  fast_pop=true  CYCLES=501
MO16_L80 fast_pop=false  CYCLES=692   MO16_L80 fast_pop=true  CYCLES=501
MO32_L80 fast_pop=false  CYCLES=692   MO32_L80 fast_pop=true  CYCLES=501
```

**With the shipping FIFO, `MAXOUT` from 2 to 32 makes NO difference at all --
five identical numbers.** With the lever on, `MAXOUT = 2` is finally
distinguishable from 4 (533 against 501) and 4 is already enough. This
independently re-confirms TRACK COUNTERS' rejection of the outstanding-read
hypothesis and adds the reason: the port was never the thing that was late.

### 5.4 Value identity, `FAST_POP` false against true

Every `y_we` cycle of a job, in order, with its address, its 48-bit mask and
the whole 3,072-bit payload, written as hex and compared with `cmp`:

| shape | LAT | verdict | lines | bytes |
|---|---:|---|---:|---:|
| 32 x 4096 | 0 | **BIT_IDENTICAL** | 1 | 789 |
| 100 x 4096 | 0 | **BIT_IDENTICAL** | 3 | 2,367 |
| 100 x 4096 | 80 | **BIT_IDENTICAL** | 3 | 2,367 |
| 192 x 4096 | 40 | **BIT_IDENTICAL** | 4 | 3,156 |
| 2048 x 4096 | 0 | **BIT_IDENTICAL** | 43 | 33,927 |
| 2048 x 4096 | 80 | **BIT_IDENTICAL** | 43 | 33,927 |

The last row was first recorded as **DIFFER**, and it was not: its `_true`
member was a ZERO-BYTE file written 1.3 s after its partner by a superseded
process still holding the path (trap 1). **It was re-run clean rather than
explained away**, and the re-run's dump has the same sha256 prefix
`61b0ead2e473fa13` as the `LAT = 0` pair, which is what it must have, since
read latency cannot change a value.

**This is not the value oracle and does not pretend to be.** Bit-identity
across the lever says the lever changed nothing; it says nothing about
whether the numbers are right. The oracle is `sim/tb_matvec_core.vhd` against
`ref/matvec_int4.c` and the `seamgate` rows against
`tools/ref9b/mv_step_oracle`, run in section 6 both with the lever off and
with it on.

### 5.5 Area, MEASURED on the BC-250 (Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`)

Three OOC draws of `weight_streamer` at the FK33 geometry, one Vivado at a
time, `MemoryHigh=8G`, `sim/ooc_aidle_run.sh`:

```
AIDLE_RESULT tag=base lut=10192 ff=8275 carry=540 muxf=0 ram=8613 bram=108 wns=1.103 synth_s=54
AIDLE_RESULT tag=ctrl lut=10192 ff=8275 carry=540 muxf=0 ram=8613 bram=108 wns=1.103 synth_s=54
AIDLE_RESULT tag=fast lut=10192 ff=8275 carry=540 muxf=0 ram=8613 bram=108 wns=1.103 synth_s=56
```

Peak, from the cgroup and NOT at the cap so it is the appetite and not the
throttle: `base` 4,381 MB, `ctrl` 3,219 MB, `fast` 3,162 MB; 123 to 127 s
each.

**`base` equals `ctrl` on every number**, which is the control for "the
default-off path costs nothing": `after_e` is computed unconditionally in the
source and Vivado prunes it entirely when the generic is false.

**`fast` equals `ctrl` on every headline number too, and the difference is
only visible in the census:**

```
< CENSUS opt   LUT4 1702      (ctrl)
< CENSUS opt   LUT5 1866
> CENSUS opt   LUT4 1675      (fast)
> CENSUS opt   LUT5 1893
```

**27 LUT4 become LUT5 -- one per read port -- and the LUT TOTAL does not
move.** `do_rd` gains one input and a LUT6 site has room for it. **The area
cost of this lever on `weight_streamer` is zero LUT, zero FF, zero CARRY8,
zero BRAM**, against a card placed at 99.81% CLB where that was the binding
constraint.

**Timing, per clock, and this is the number that matters:**

| draw | `aclk` WNS (4.000 ns) | `clk` WNS (13.333 ns) |
|---|---:|---:|
| ctrl | 1.103 | **11.709** |
| fast | 1.103 | **11.285** |

The binding path is in the AXI domain and is the AR-throttle FSM
(`gen_s[0].scale_port/g_dc.fsm/st_reg[2]` to `this_len_reg[0]/CE`); it does
not move. The core-clock path -- where the change lives -- gives up
**0.424 ns** and keeps 11.285 ns of slack on a 13.333 ns period. **That
0.424 ns is a LOWER BOUND and section 8 says why.**

---
## 6. Teeth: every mutant, including the ones that do NOT bite

Each row is a deliberate defect in the code this track added, run against the
checks this track added. `M?c` rows are the **attribution control**: the same
mutant with the candidate check disabled, which is what says whether the kill
belongs to the new check or to one that was already there.

**Configuration matters and the table says so.** `BP=0` is a consumer with
`q_ready` tied high; `BP=30` drops it on about 30% of cycles.

| mutant | what it changes | `FP=false` `BP=0` | `FP=true` `BP=0` | `FP=false` `BP=30` | `FP=true` `BP=30` | killed by |
|---|---|---|---|---|---|---|
| **M0** control | nothing | pass 1.501 | pass 1.002 | pass 1.948 | pass 1.517 | -- |
| **M1** | threshold one too PERMISSIVE, `after_e < 3` | pass | **pass** | pass | **KILLED** bound check | `after_e`'s `0 to 3` range |
| **M2** | threshold one too CONSERVATIVE, `after_e < 1` | pass | **pass 2.001** | pass | **pass 2.531** | **nothing but the RATE** |
| **M3** | pop term unguarded, drop `ocnt > 0` | **KILLED** | **KILLED** | **KILLED** | **KILLED** | `after_e`'s `0 to 3` range |
| **M4** | pop term ignores `q_ready` | pass | **pass** | pass | **KILLED** bound check | `after_e`'s range |
| **M1c** | M1, `ocnt` range widened to unconstrained, `ob_t` to 8 | pass | pass | pass | **KILLED** bound check | **still `after_e`'s range** |
| **M1cc** | M1, BOTH ranges removed, `ob_t` 8 wide | pass | pass | pass | **KILLED** `OUT OF ORDER` | **the bench's value/order assert** |
| **M3c** | M3 with `after_e`'s range removed | **pass** | **pass** | **pass** | **pass** | **NOTHING** |
| **M2c** | M2 with the rate row suppressed | pass | pass | pass | pass | **NOTHING** |

**Rows that do NOT bite, under their own names, because they are the useful
ones:**

- **M1 and M4 both SURVIVE at `BP=0`, the configuration the bench was written
  in.** With `q_ready` tied high the output stage never holds a beat that is
  not leaving, so the overrun state M1 creates is unreachable, and `ocnt > 0`
  and `ocnt > 0 and q_ready = '1'` are literally the same expression, so M4
  is not a mutation at all. **The backpressure case is what gives this bench
  any mutation sensitivity, and it was added only after M1 and M4 survived.**
  That is coverage of the input space mistaken for coverage of the output
  space, caught by running the mutants rather than by inspection.
- **M2 is killed by NOTHING except the rate number.** A threshold that is too
  conservative loses half the lever and every value is still correct, in
  order, with no bound check anywhere. `M2c` confirms it: suppress the rate
  line and the mutant is invisible. **There is no value-based detector for a
  performance regression, so the rate row is load-bearing and must not be
  dropped from the bench.**
- **M3c PASSES in all four configurations.** So the `after_e : integer range
  0 to 3` declaration is not decoration: without it, dropping the `ocnt > 0`
  guard produces a design that runs at the right rate with the right values
  in simulation, and in synthesis the subtraction wraps.
- **M1c still dies, and NOT for the reason the control was testing.**
  Widening `ocnt` and `ob_t` does not save M1, because `after_e` itself then
  reaches 4. **The kill belongs to `after_e`'s range and not to `ocnt`'s**,
  which is exactly the attribution the control exists to establish and the
  opposite of what the row was expected to show.
- **M1cc pins the last detector.** With both ranges gone and the array
  widened, `ob_wp`/`ob_rp` still wrap `mod 2` -- that is the real two-entry
  stage -- so the third beat overwrites the first and the bench's value/order
  assertion fires. So M1 has **three independent detectors** in a defined
  order: `after_e`'s range, then `ocnt`'s range, then value loss.

**Engine-level mutants**, run through `tb_aidle_rate` against the new
`dbg_sstarve` observable and the new partition assertion:

| mutant | what it changes | result | killed by |
|---|---|---|---|
| **E0** control | nothing | 613 / 422, `S=1` | -- |
| **M7** | `FAST_POP` forwarded to the 24 WEIGHT ports and not the 3 scale ports | **KILLED.** `FAST_POP=true` gives **613 cycles, no gain at all**, and the stall MOVES: `W` 202 -> 10 while **`S` 1 -> 193** | the rate row detects it; **`dbg_sstarve` NAMES it** |
| **M7c** | M7 with `dbg_sstarve` tied to `'0'` | still 613, still no gain, but `S = 0` and all 219 residual cycles land in `XCTRL` | the rate row alone. **The reason is lost.** |
| **M5** | `dbg_sstarve` drops the `wv and`, becomes `not sv` | **DOES NOT BITE.** Identical counters, partition holds | **nothing** |
| **M5c** | M5 with the partition assertion disabled | identical | nothing |
| **M6** | AR issued one beat early, `f_level + pr + want <= DEPTH + 1` | **DOES NOT BITE** at 384 words | nothing |
| **M6big** | the same mutant at 5,504 words, **10.75x the FIFO depth** | **STILL DOES NOT BITE.** 8,333 / 5,582 exactly as the control, and the `y` stream matches the reference byte for byte in both arms | **nothing** |

**The non-biting engine rows, under their own names:**

- **M5 cannot be detected by this bench and the `wv and` term is redundant
  for its only consumer.** The bench reads `dbg_sstarve` inside the branch
  `dbg_wstarve = '0' and dbg_wbeat = '0'`, which already guarantees `wv = '1'`,
  so `not sv` and `wv and not sv` are the same expression there. **The
  partition assertion has NO teeth against this mutant**, and saying so is
  the point of running it: the `wv and` earns its place only for a consumer
  that reads the port unconditionally, such as a hardware counter beside
  `STARVED`, and no such consumer exists yet. **A reader who deletes the
  `wv and` will break nothing today.**
- **M6 does not bite even at a job 10.75x the FIFO depth.** Over-committing
  the AR throttle by ONE beat is absorbed by `LVL_MARGIN = 3`, which exists
  precisely to cover the output stage plus the in-flight read, so the FIFO
  never actually reaches `mcnt = DEPTH` with a beat arriving. **This measures
  this bench's resolution floor against that class of defect, and the floor
  is somewhere above one beat.** A mutant of `+ MAXB` rather than `+ 1` would
  presumably reach it; it was not run. The real guard for AR over-commit is
  `rtl/async_fifo.vhd`'s `WRITE INTO A FULL FIFO` assertion, which this
  single-clock bench does not instantiate, and the value oracles in the gate.
  **M6 is a mutant of code this track did not change**, run because the brief
  asked for it; the conclusion is that nothing here would catch it, not that
  it is safe.

**And the AREA harness has its own teeth test, because three draws agreeing
to the digit is exactly what a harness that ignores `-generic` looks like.**
A fourth draw with `NPORTS_W=12` and nothing else changed:

```
AIDLE_RESULT tag=fast    lut=10192 ff=8275 carry=540 ram=8613 bram=108
AIDLE_RESULT tag=probe12 lut= 5663 ff=4939 carry=300 ram=4785 bram= 60
```

The harness moves when the design moves. The synth command line was also
read back from the log and carries `-generic FAST_POP=true` verbatim. **So
"zero extra LUTs" is a measurement and not a silence.**


## 6b. The gate, run twice: with the lever off and with the lever ON

Bit-identity of the `y` stream (section 5.4) says the lever changed nothing.
It does NOT say the numbers are right. The oracles that say that are
`sim/tb_matvec_core.vhd` against `ref/matvec_int4.c`,
`sim/tb_matvec_fk33{,_desc,_desc_dual,_desc_xexp}.vhd` whose verdict line is
literally *"subsystem A is bit-exact with ref/matvec_int4.c"*, and the
`seamgate` rows against `tools/ref9b/mv_step_oracle` -- and none of them has
a `FAST_POP` generic to set.

**So the gate was run twice: once on the MAIN checkout, and once in a
detached `git worktree` at the same commit with the `FAST_POP` DEFAULT
flipped to `true` in all six files.** That is what a card build with
`FAST_POP_DEFAULT = True` will elaborate, so it is the configuration under
test and not a proxy for it.

**Every OVERALL line, verbatim:**

```
########## GATE MAIN --only tb_matvec ##########
 OVERALL     PASS 12   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE MAIN --only tb_axi_rd ##########
 OVERALL     PASS 4   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE MAIN --only tb_weight_streamer ##########
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE MAIN --only tb_async_fifo ##########
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE MAIN --only tb_a_geom ##########
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE MAIN --only mv_step ##########
 OVERALL     PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE MAIN --only seamgate ##########
 OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

**`--only mv_step` is `PASS 0`, and that is the substring trap, not a
result.** The brief named it as a gate row; there is no row whose key
contains `mv_step`. `mv_step_oracle` is a C program built and run INSIDE
`tools/ref9b/seamgate.sh` (`:240-246`), so it is exercised by the six
`seamgate` rows and by nothing with that name. CLAUDE.md's rule is exactly
this: `--only` takes a SUBSTRING, a miss still prints `REGRESSION: PASS`, and
the only tell is `PASS 0`.

**The same seven groups in the `FAST_POP = true` worktree:**

```
########## GATE FASTPOP --only tb_matvec ##########
 OVERALL     PASS 12   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE FASTPOP --only tb_axi_rd ##########
 OVERALL     PASS 4   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE FASTPOP --only tb_weight_streamer ##########
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE FASTPOP --only tb_async_fifo ##########
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE FASTPOP --only tb_a_geom ##########
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE FASTPOP --only mv_step ##########
 OVERALL     PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## GATE FASTPOP --only seamgate ##########
 OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

**26 rows, both trees, 0 FAIL.** The three `tb_matvec_fk33*` rows and the six
`seamgate` rows are the ones with an independent implementation behind them:
`ref/matvec_int4.c` and `tools/ref9b/mv_step_oracle`.

The row that matters most is `sim:tb_matvec_fk33_desc_dual`, because
`DUAL_CLK => true` is the configuration the card builds and it is the only
one that puts `rtl/async_fifo.vhd` -- not `stream_fifo` -- in the weight
path. It passes with the lever on, against `ref/matvec_int4.c`.

---

---

## 7. Measurement traps hit, including my own

1. **A stale background job kept writing into a re-truncated log, and the
   result read as a legitimate mixed set of verdicts.** Two earlier runs of
   the identity script were superseded; one was killed and one died on a
   VHDL overflow, and both still held the log's file descriptor at a stale
   offset. After `> ident.log` truncated the file, their buffered lines
   landed *inside* the new run's lines -- producing, among other things,
   `AIDLERATE tag=ident_100x4096_L0 ... RESID=28 AIDLERATE tag=ident_2048...`
   on one line and a spurious `2048x4096 L80 EMPTY` row from a run that had
   been superseded twenty minutes earlier. **The verdict was re-derived from
   the `y/` FILES on disk rather than from the log**, and that is where the
   real state was: five pairs bit-identical, one pair whose `_true` member
   was a ZERO-BYTE file written 1.3 s after its partner by the superseded
   process. Re-running it cleanly is the only thing that settles it, and the
   log could not have told you which run wrote which line. **Name scratch and
   log files per run; a killed job is not a stopped writer.**
2. **The first identity check compared two EMPTY files and reported
   BIT_IDENTICAL.** `file_open` without `file_close` before `std.env.stop`
   leaves GHDL's buffered lines unwritten, so both runs produced a zero-byte
   dump and `cmp -s` agreed. **A checker printing PASS over an object it
   never read** -- the defect class CLAUDE.md names -- and it passed on the
   first attempt with nothing visibly wrong. The fix is two things and it
   needs both: `file_close`, and a runner that **refuses a zero-line
   comparison** and prints `lines=` and `bytes=` beside every verdict so the
   pass cannot be believed without reading how much was compared. That guard
   then fired twice more, for a different reason, which is trap 3.
3. **`to_integer` over a 48-bit mask and a 64-bit lane is a runtime-fatal
   overflow, and the parent bench had already written the warning down.**
   `docs/debugging/2026-08-30_counters-cycles-beats-starved.md` trap 1 says
   "VHDL `integer` is 32-bit signed; that is an elaboration-time-legal,
   runtime-fatal overflow". The dump process was written with
   `to_integer(unsigned(y_mask))` anyway, the simulation died AFTER the rate
   report and BEFORE any line was written, and the only thing that caught it
   was the zero-line refusal from trap 2. `to_hstring` is lossless and has no
   range. **Reading the trap list is not the same as applying it.**
4. **The inherited memory model applies read latency to the HEAD of each
   port's burst queue, so a `MAXOUT` sweep measures the model.** This is the
   parent bench's own recorded trap 2 and it reproduced exactly: at `LAT=40`,
   `MAXOUT` 2, 4 and 8 all gave **1389 cycles, identical to the digit**,
   which reads as "outstanding reads do not help" and is really "this model
   has no outstanding reads". Fixed here by giving every queued burst its own
   countdown started at AR acceptance. The control that the fix is sound is
   that `LAT=0` is unchanged at 613; after it, `LAT=40` costs 39 cycles and
   `LAT=80` costs 79, once per job, which is a latency being hidden.
5. **A presence check by `/proc/PID/exe` alone said the GHDL lane was busy
   when it was two other tracks' GHDL.** CLAUDE.md records TRACK NORMURAM
   sitting in a sleep loop for eleven minutes against a free Vivado lane; the
   same shape here, with the same fix -- `/proc/PID/cwd`, which says WHOSE
   process it is, not just what binary it runs. A wait loop that cannot name
   the owner is a wait on the whole box.
6. **Three OOC draws agreeing to the digit is indistinguishable from a
   harness that ignores its generics.** `base`, `ctrl` and `fast` returned
   identical LUT, FF, CARRY8, RAM, BRAM and WNS. That is the correct answer
   here, but nothing in it says so. The fourth draw with `NPORTS_W=12` and
   the synth command line read back from the log are what make it a result.
7. **A per-clock WNS is not the reported WNS.** `get_timing_paths -max_paths
   1` returns the worst path on the part, which here is in the 4.000 ns
   `aclk` domain and is untouched by this change, so all three draws printed
   `wns=1.103` and the lever looked free of timing cost. The core-clock
   number, which is the one the change can move, is in the `report_timing_
   summary` clock table and it DID move, 11.709 to 11.285. **Ask which clock
   the claim lives on before quoting a WNS.**

---
## 8. Measured and REJECTED -- do not retry

| hypothesis | how it died | do not retry |
|---|---|---|
| **The 0.53 is per-job overhead -- descriptor fetch, `S_CHECK`, the 17-cycle codebook load, the `S_EMIT` epilogue, the flush-on-start drain** | TRACK DSIDE's two-parameter fit over 311 steps puts the whole per-job constant at **294 cycles**, i.e. **91,456 per token, 3.34% of the excess**. Section 3. | Settled. Every per-job cost in subsystem A added together is capped at 0.30% of the token. Do not open a per-job item against this number again. |
| **`MAXOUT` / outstanding-read depth** | Section 5.3: with the shipping FIFO, `MAXOUT` 2, 4, 8, 16 and 32 give **692 cycles, five identical numbers**. TRACK COUNTERS rejected it in August for a different reason and was right. | It is not merely unhelpful, it is INERT until the FIFO is fixed, and after the fix 4 is already enough. |
| **`MAXB` / the AXI3 4-bit `ARLEN` cap of 16 beats** | Same sweep. A port that consumes a beat every 1.5 cycles is not limited by how many arrive in one burst; at `LAT=80` the whole 384-beat sub-region is resident before the array is a third of the way through it. | Real constraint, not this constraint. |
| **FIFO depth / the AR throttle `f_level + pr + want <= DEPTH`** | Never reached in any run of section 5.2. At `DEPTH=512` and a 384-beat job the FIFO holds the entire sub-region. | |
| **The scale path (3 ports, the `s_hold` superword)** | `dbg_sstarve` was added to observe exactly this, and it MEASURES **1 cycle of 613**. `GRP = 1` at this geometry, so `s_take` refills in the same cycle the chunk is consumed and the holding register cannot bubble. | The engine header's warning that STARVED misses the scale path is correct in principle and the residual is 0.16% here. |
| **The activation prefetch queue `xq_cnt > 0`** | Folded into `XCTRL` at 26 to 28 cycles per job, and those cycles are almost all `S_IDLE`/`S_DRAIN`/`S_SCAN`/`S_EMIT`/`S_DONE`. The 2-deep queue refills one per cycle whenever `occ < 2` and sustains full rate. | |
| **HBM pseudo-channel contention on the STRIPED image** | DERIVED from the striped manifest: all 249 tensors place their 27 lanes across **25 distinct 256 MiB segments with a worst case of 2 lanes on one**, so the busiest pseudo-channel owes 2 beats per weight word against 3.333 AXI cycles available. It does not bind even at the floor. This is the flat image's problem, and striping already took 2.056x of it. | Do not re-open the address map for the striped image. TRACK COUNTERS' finding was about the FLAT one and is still true of it. |
| **Making the array wider, or batching K positions (PREFILL row 5)** | Buys the same 2.7 M cycles for 1,536 DSP48E2 against 793 free. | PREFILL settled it; this track removes its reason to exist. |

---

## 9. Open, NOT determined

- **The in-context core-clock timing of the new `q_ready -> do_rd` path.**
  This is the one thing that could stop the lever and it is NOT measured.
  Out of context `weight_streamer` gives up 0.424 ns and keeps 11.285 ns of
  slack, but out of context `q_ready` is a port with a default input delay.
  **In the card it is the AND of 24 weight FIFOs' `q_valid`, ANDed with the
  3 scale ports and `xq_cnt > 0` in `matvec_core`, fanning back out to all 27
  FIFOs' read enables.** That is a 27-way gather and a 27-way scatter that
  previously was not in the `do_rd` cone at all. The OOC 0.424 ns is a LOWER
  BOUND on what it costs. **Only a routed `FK33_CARD=1` build answers it**,
  and the shipped build already routes at WNS +0.001 with 99.81% CLB
  occupancy, so there is no slack to spend carelessly. If it does not close,
  the fallback is to register `q_ready` into `do_rd` for one cycle of
  latency, which costs one FF per port and gives back part of the lever --
  **that variant has not been designed or measured.**
- **The card-side effect has not been simulated at the card's geometry in
  the DUAL_CLK configuration.** Every rate number here is single-clock, for
  the same reason TRACK COUNTERS' were; `async_fifo` carries the identical
  line and the identical output stage, and that is an argument, not a
  measurement.
- **The 3.2% bench-to-card residual.** At `M = 2048, K = 4096` this bench
  gives 8,333 engine cycles against the card's 8,601. TRACK BMOVER's
  equivalent bench sat 2.5% off in the same direction and that residual is
  also unexplained. What it bounds is useful -- at most 0.05 cycles per word
  of the card's 1.5101 can belong to anything other than the FIFO -- but it
  is not explained.
- **Whether the memory can actually supply one word per core cycle on
  silicon.** DERIVED from the striped manifest it can, with the busiest
  pseudo-channel at 60% duty rather than today's 39%. Nobody has measured an
  HBM pseudo-channel's sustained read rate on this card, and a 60% duty
  assumes the refresh and row-activate overheads are free. **If the memory
  binds at, say, 1.2 cycles per word, the lever delivers 0.31 rather than
  0.50 and is still worth having.**
- **The 28th FIFO.** `matvec_int4_desc_axi`'s descriptor master carries the
  same generic and is not in the OOC draw. **DERIVED at one LUT4 -> LUT5 by
  proportion, i.e. zero extra LUTs**, but not measured.
- **`rtl/fk33_eng_cdc.vhd`'s two `async_fifo` instances are untouched** and
  are another track's file. They move D's x elements and y beats across the
  same domain boundary at the same 2-in-3 cadence. **Nobody has asked whether
  that matters**; `S_XRD` and `S_DRAIN` are 2,963,566 cycles of the token
  (TRACK DSIDE) and if any part of that is this cadence it is a second
  helping of the same lever. Not investigated here.
- **The `M = 32, K = 4096` shape is 3.85 cycles per word on the card** and
  the fit's residual is worst there. 48 of the 311 jobs have that shape and
  they are only 128 words each, so it is 0.4% of the token; it is the one
  shape where the per-job constant dominates and it is not modelled.

---

## 10. What the dispatcher must set for the next build

**One line.** `hw/fk33/gen_fk33_engine.py`:

```python
FAST_POP_DEFAULT = False      ->      FAST_POP_DEFAULT = True
```

then `python3 hw/fk33/gen_fk33_engine.py` and `git diff` the output, which
must show exactly `FAST_POP : boolean := false` becoming `true` in
`hw/fk33/rtl/fk33_engine.vhd` and nothing else.

It is a generic on `fk33_engine` rather than a hard-coded `true` for the
reason `CB_STYLE` is one: **`-generic` on the `synth_design` line reaches the
TOP's generics only, never a deep instance**, so a lever this entity does not
carry is unreachable from the card build and from `compose4_top`. A build
driven through the block design can instead set `CONFIG.FAST_POP` on the
`module_ref` cell, exactly as `hw/fk33/gen_pcieep.py` sets
`CONFIG.USE_XEXP_PORT` under `FK33_CARD=1` -- **that hook does not exist yet
and `gen_pcieep.py` is not this track's file.**

**What to check in the resulting build, in this order:**

1. `report_timing_summary`'s clock table for the CORE clock, not the global
   WNS. The global WNS on this design lives in the AXI domain and will not
   move; the core-clock number is where the risk is (section 9).
2. CLB occupancy. It should not move at all -- 27 LUT4 became LUT5 and the
   LUT total did not change -- and if it does, something other than this
   lever moved with it.
3. The engine's `CYCLES` and `BEATS` registers per job, read by the host.
   **Expected `CYCLES/BEATS` about 1.01 against today's 1.51.** Nobody has
   ever read those two registers per job on the card and it is the cheapest
   confirmation that exists.

---

## 11. How to reproduce

**The three-second version, which is the one that settles it.** No AXI, no
array, no memory model:

```bash
SD=$(mktemp -d)
cd "$SD"
ghdl -a --std=08 --work=work <repo>/rtl/stream_fifo.vhd tb_fifo_rate.vhd
ghdl -r --std=08 --work=work tb_fifo_rate -gFP=false -gBP=0   # 1.501 cyc/beat
ghdl -r --std=08 --work=work tb_fifo_rate -gFP=true  -gBP=0   # 1.002 cyc/beat
ghdl -r --std=08 --work=work tb_fifo_rate -gFP=true  -gBP=30  # mutation-sensitive
```

Both benches are committed beside this document as
`2026-09-20_a-accept-port-tb_fifo_rate.vhd` and
`2026-09-20_a-accept-port-tb_aidle_rate.vhd`.

`tb_fifo_rate` is 110 lines: push a beat every cycle until N are pushed, hold
`q_ready` per `BP`, count cycles to drain N and cycles with `q_valid` low, and
assert every popped word equals a counter. Peak RSS **15,396 KiB MEASURED**
(`/usr/bin/time -v`). Anyone can rewrite it in ten minutes, and that is the
point -- the defect needed no instrumentation of the engine to find.

**The whole-engine version**, `tb_aidle_rate`, is TRACK COUNTERS'
`docs/debugging/2026-08-30_counters-tb_ctr_rate.vhd` with `FAST_POP` plumbed
in, the stall split by reason via the new `dbg_sstarve`, the memory model's
latency pipelined per outstanding burst, and a hex `y` dump. It needs

```
rtl/{util_pkg,mv4i_arith_pkg,stream_fifo,async_fifo,axi_rd_fsm,axi_rd_port,
     weight_streamer,act_mem_striped,matvec_core,matvec_int4}.vhd
```

analysed into one library, then

```bash
ghdl -r --std=08 --work=work tb_aidle_rate \
  -gTAG=t -gFAST_POP=false -gUNLIM=true -gLAT=0 -gMAXOUT=16 \
  -gN_ROWS=100 -gN_COLS=4096 -gMAXROWS=192 --stop-time=90ms
```

Peak RSS **1,548,392 KiB MEASURED**, 9.4 s at the 384-word shape and about
110 s at the 5,504-word one. **One at a time.** Both benches live in this
track's scratch rather than in `sim/` for the reason TRACK COUNTERS recorded:
`sim/regress.sh` globs `sim/tb_*.vhd` off the filesystem, and dropping a new
bench there while three tracks are running turns the shared gate red until
`BASELINE_PASS` moves.

**The area draws:**

```bash
bash ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh          # commit FIRST
ssh labuser@<bc250> 'bash -c "cd ~/GitHub/llama.vhdl && \
  AIDLE_OUT=~/aidle_ooc AIDLE_BASE_DIR=~/aidle_base AIDLE_CAP=8G \
  bash sim/ooc_aidle_run.sh"'
```

`AIDLE_BASE_DIR` is needed there and only there: the synced tree is
git-TRACKED FILES ONLY, with no `.git`, so the runner's `git show` of the
pre-change RTL reads nothing. Copy the four files over beside the sync.
Each draw: **3.1 to 4.4 GB cgroup peak, not at the 8G cap, 123 to 127 s.**
