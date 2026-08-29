# The `attn_block` <-> `attn_kv_axi` seam, and the first multi-token attention

2026-08-28. Track C-SEAM. Simulation only, no hardware.
Build: the `fpga` branch working tree at `c50a2b7`, GHDL 1.0.0 mcode,
`--std=08 -frelaxed`.

## 1. The question, verbatim

> `rtl/attn_kv_axi.vhd` is built and verified. `rtl/attn_block.vhd` is
> bit-exact against `ref/attn_block_vec.c`. **They cannot be connected.**
> TRACK C-KV measured why, from the RTL rather than the spec: the read issue is
> one beat per cycle with no ready and no gate, the capture is exactly two
> cycles after the issue, and an AXI master cannot serve that. Its stated
> closure: one new output per read stream (`kr_rdy` / `vr_rdy`), and the
> integration change is "drive `kr_head`/`kr_pos` one state earlier and gate
> P_RECK's issue on `kr_rdy`." Treat that as a strong hypothesis from the
> person who measured it, not as settled. Verify the timing claims yourself
> first. Then close the seam, keep `attn_block` bit-exact, and prove the thing
> neither unit can prove alone: multi-token attention.

## 2. The answer

**The diagnosis reproduced exactly, and it is worse than a stall: it is a
wrong answer with no error.** MEASURED by adding ONE cycle of read latency to
the KV memory model in `sim/tb_attn_block.vhd` and changing nothing else --
**64 of 64 output mantissas wrong against the oracle, on every run, with `err`
clear.** The block had no signal to wait on, so a late beat was not delayed,
it was mis-captured.

The seam is closed by **four new inputs on `attn_block`, all defaulting to
'1'** (`kr_rdy`, `vr_rdy`, `kw_rdy`, `kv_wr_idle`), plus **moving the read
request out of the issue cycle into a concurrent assignment** so it stands a
state earlier and keeps standing until the last beat of the record is
captured. `attn_block` is unchanged bit for bit: `sim/tb_attn_block.vhd` still
passes over the same 130 compared values and finishes at the **same simulation
time**, 81065 ns before and after, which is the strongest available statement
that the schedule did not move. `rtl/attn_kv_axi.vhd` needed **no change at
all** -- C-KV had already published `kr_rdy` / `vr_rdy` / `kw_rdy` / `wr_idle`
and the contract they satisfy.

**Multi-token attention now runs and is bit-exact.**
`sim/tb_attn_kv_seam.vhd` instantiates the block against the real cache over
three modelled AXI slaves at a 100-cycle read latency and runs a four-token
sequence at `cur_pos` 0, 1, 2, 3: **1,028 output values and 1,088 record bytes
in HBM, zero mismatches**, against a new sequence oracle
`ref/attn_block_seq_vec.c`.

Full gate **81 PASS / 0 FAIL**, up from the recorded floor of 80.

## 3. The procedure, in the order it was run

Each step says what it isolates.

1. **Re-derive the issue-to-capture timing by reading the RTL, before running
   anything.** `rtl/attn_block.vhd` P_RECK sets `kr_en`, the address and
   `rbv(1)` inside a CLOCKED process, so they are asserted in cycle *n+1* if
   the state is evaluated in cycle *n*. `rbv(2) <= rbv(1)` puts `rbv(2)` high
   in *n+2*, and the capture `if rbv(2) = '1'` executes at the edge ending
   *n+2*, sampling `kr_mant` as it stood during *n+2* -- the data for an
   address presented in *n+1*. That is a one-cycle synchronous read, exactly
   as C-KV stated. `blk` advances unconditionally, so the issue is back to
   back with no gate. **CONFIRMED, and the arithmetic is written out here
   because "two cycles" is ambiguous about which edge.**

2. **Falsify it rather than agree with it.** A reading of the RTL is a claim.
   The measurement is: take a scratch copy of `sim/tb_attn_block.vhd`, add one
   register stage to the KV memory model, change nothing else, and run. This
   isolates elasticity from everything else, because the DATA is identical and
   only its arrival is late by one cycle.

3. **Read `rtl/attn_kv_axi.vhd`'s residency logic before designing the fix**,
   to check that the published contract is the one the RTL implements: `q_rdy`
   is combinational in `q_head`/`q_pos` (`:592-621`), the beat is registered on
   `q_en and hit` (`:648`), and `err_rd` is raised only for an **enabled** read
   outside the range (`:658`). That last one is what makes it safe to publish
   the bypass position on the request wires.

4. **Check that a held request cannot lose residency under it**, or the gate
   would be a race rather than a fix. `lim_rec := c_max + RBUF - 2` bounds the
   fetcher, `c_max` tracks the consumer's own record, and slot
   `c_max mod RBUF` is therefore never the slot a straddle lands in. So once
   `kr_rdy` is high for a held request it stays high. This is why the gate can
   be evaluated one cycle before the issue it controls.

5. **Make the change, and re-run the oracle FIRST**, before writing any new
   bench. If `tb_attn_block` had moved by one bit the change would have been
   wrong regardless of what the seam did.

6. **Refactor the single-token oracle into a function and prove the refactor
   byte-identical** at three geometries by md5, before using it for anything.
   A sequence oracle that shares the arithmetic is the right design -- two
   copies of an oracle drift and nothing compares them -- but only if the
   split is provably inert.

7. **Write the sequence oracle so the cache is what the earlier tokens WROTE**,
   not a synthetic one. This is the only thing that can see the append, the
   two masters agreeing on the same address equation, and `v_ref` folding
   across tokens.

8. **Emit the record IMAGE as well as the y stream**, so the bench can check
   HBM bytes at the address C spec 2.2's equation gives. "The block computed
   the right numbers" and "the record landed at the right address" are
   different claims, and two masters agreeing on a WRONG address produces a
   perfect answer.

9. **Choose the bases and MAXCTX to break C spec 2.2's alignment rules on
   purpose**: `k_base = 16`, `v_base = 4064`, `MAXCTX = 8`. None is 4 KB
   aligned and MAXCTX is not a multiple of 256. If the design is right, this
   works; if the spec is right, it does not.

10. **Mutation-test the seam, with controls.** A mutation that only dies under
    an unusual slave setting has proved nothing unless the CLEAN design passes
    under that same setting, so four controls run alongside.

## 4. The evidence

### 4.1 The seam did not exist: one cycle of latency, 64 of 64 wrong

Scratch copy of the bench only; the RTL untouched.

```
:788:11:@80725ns:(report error): run 1 element 0 = 8667 against run 0's 9519.
    The consumer's stall pattern changed a value.
:788:11:@80725ns:(report error): run 2 element 0 = 8667 against run 0's 9519.
    The consumer's stall pattern changed a value.
:831:15:@80725ns:(report error): P8 -- run 0 element 0 = 9519, the oracle says
    8554.  MISMATCH against ref/attn_block_vec.c.
:843:11:@80725ns:(report error): P8 -- run 0, 64 of 64 mantissas differ
:843:11:@80725ns:(report error): P8 -- run 1, 64 of 64 mantissas differ
:910:7:@80725ns:(report failure): RESULT bad, 4 properties violated
```

`err` clear throughout. Not a stall and not a fault: a wrong answer.

**Read the property list, not the headline.** P8 (the values) fails, and so
does **P2 (handshake invariance)** -- the three consumer configurations no
longer agree with each other. P1, P3, P4, P5, P6 and P7 all still pass. So the
pre-seam design was not invisible to everything: a bench that varied the
consumer would have seen SOMETHING was skew-dependent. What it could not have
told anyone is WHAT, and only the value oracle says the numbers are wrong.
This is stated precisely because an earlier draft of this file said "all seven
structural properties still passing", which is what the first `tail` of the
log looked like and is not what the log says.

### 4.2 `attn_block` after the change, unchanged

Measured immediately after the seam change and before anything else was
touched:

```
before:  @81065ns: tb_attn_block: PASS -- 3 consumer configurations, 64
         elements each, ... BIT-EXACT against ref/attn_block_vec.c over 130
         compared values
after:   @81065ns: tb_attn_block: PASS -- 3 consumer configurations, 64
         elements each, ... BIT-EXACT against ref/attn_block_vec.c over 130
         compared values
```

Same values, same 130 comparisons, **same simulation end time to the
nanosecond**, which is what says the schedule did not move.

The committed bench ends at **81465 ns** rather than 81065 ns, and that is the
xorshift fix of 7.3, not the seam: configuration 2 stalls for the first time
(126 -> 166 stalled beats). The values and the 130 comparisons are unchanged
across that too, which is P2 doing the job it was written for.

### 4.3 The oracle refactor is inert

```
$ md5sum  (before the refactor)          (after)
4e9643516c76df0ca3718385f12d78b5  16/4/2/4/8   cur_pos 3   IDENTICAL
186d30f22bd48351471c95d03d4ccf4d  64/6/3/8/16  cur_pos 2   IDENTICAL
05a9dc9ac9d021b1a52eebb625cce07c  64/4/2/16/16 cur_pos 5   IDENTICAL
```

### 4.4 Four tokens through the real cache

```
tb_attn_kv_seam: PASS -- 4 tokens at cur_pos 0..3 through rtl/attn_kv_axi.vhd
over AXI at 100-cycle read latency, BIT-EXACT against ref/attn_block_seq_vec.c
over 1028 output values and 1088 record bytes in HBM, every returned beat
matched to the position it was requested for, k_base=16 v_base=4064 (neither
4 KB aligned), MAXCTX=8, longest quiet stretch 2137 cycles against a watchdog
of 20000
```

### 4.5 The 4 KB split fires, from a base that is not 4 KB aligned

Instrumented scratch copy of `attn_kv_axi`, V stream, `v_base = 4064`:

```
DBG s=1 OPEN hd=0 p0=0 a0=4064 ph=0
DBG s=1 AR a=4064 len=1
DBG s=1 AR a=4096 len=2
```

One run, split at the 4 KB boundary into 1 + 2 beats, from a base 32 bytes
below it. **C spec 2.2's requirement that `k_base`/`v_base` be 4 KB aligned
and that MAXCTX be a multiple of 256 is unnecessary, and this is the
measurement that says so.** The splitter works on the absolute beat address.

## 5. The seam change, file by file

`rtl/attn_block.vhd` only. `rtl/attn_kv_axi.vhd` is byte-identical to what
C-KV landed.

| site | change | why it is minimal |
|---|---|---|
| `:309` `kw_rdy : in std_logic := '1'` | new input | the sink drops `kw_hen`/`kw_en` silently while its buffer is full or it is flushing |
| `:323` `kr_rdy : in std_logic := '1'` | new input | residency, combinational in the held request |
| `:330` `vr_rdy : in std_logic := '1'` | new input | same, V side |
| `:339` `kv_wr_idle : in std_logic := '1'` | new input | C spec 2.7's BRESP term, which this block cannot derive |
| `:711-726` | `kr_head`/`kr_pos`/`vr_head`/`vr_pos` moved OUT of the FSM into four concurrent assignments from `kvh` and `pos_i` | this is what makes the request stand a state earlier and hold across P_HDR, the score, the rescale and P_RECV. It is four lines and it deletes four |
| P_RECK | the issue wrapped in `if kr_rdy = '1' then` | the only gate on the K read |
| P_RECV | the issue wrapped in `if vr_rdy = '1' then` | the only gate on the V read |
| P_KQW, P_VQW, P_WREC | `and kw_rdy = '1'` on the header, `if kw_rdy = '1'` on the beats | the header is gated too: a dropped header makes every following `kw_en` a no-op, so the whole record vanishes |
| P_DONE | `if kv_wr_idle = '1' then` around the existing body | C spec 2.7 |

Nothing else moved. No state was added, no counter changed, no arithmetic
touched. The defaults of '1' reproduce a memory that can never refuse, which
is why `tb_attn_block` and `tb_llama_top` are bit-identical without being
edited.

**The `pos_i` published during the bypass position is deliberate.** The
request carries `pos = cur_pos` while `is_byp` is set. The sink refuses that
by leaving `kr_rdy` low and raises `err` only for an ENABLED read, and P_RECK
never enables one while `is_byp` is set, so C spec 2.4's bypass stays a
property of the addresses and `tb_attn_block`'s P7 still means what it meant.

## 6. Mutation table

**19 mutations and 4 controls. 10 killed on a property, 2 killed as hangs by
the bench's own watchdog, 7 survivors -- every one of them analysed below
rather than assumed equivalent, and 3 of the 7 turned into kills by
strengthening the SLAVE MODEL rather than by weakening the mutation.**

Controls first, because the rest is only readable against them.

| # | mutation | outcome | killed by |
|---|---|---|---|
| C1 | CONTROL: clean, write slave refuses AW for 4000 cycles | SURVIVED (correct) | -- |
| C2 | CONTROL: clean, 2000-cycle read latency | SURVIVED (correct) | -- |
| C3 | CONTROL: clean, 4000-cycle BRESP latency | SURVIVED (correct) | -- |
| C4 | CONTROL: clean, cache told `cur_pos` is readable | SURVIVED (correct) | -- |
| S1 | `kr_rdy` ignored -- **this IS the pre-seam design** | KILLED | Q4 |
| S2 | `kr_rdy` withdrawn on ~25% of cycles | **SURVIVED** | see 6.1 |
| S3 | the cache asked for the NEXT POSITION's record | KILLED | Q3 |
| S4 | the cache asked for the neighbouring BLOCK | KILLED | Q3 |
| S5 | `done` not gated on BRESP, WR_LAT 12 | **SURVIVED** | see 6.2 |
| S5b | the same, at a 4000-cycle BRESP latency | KILLED | Q5 |
| S6 | `v_ref` reset per TOKEN, not per SEQUENCE | KILLED | Q1 |
| R1 | the `kr_rdy` gate removed from P_RECK in the RTL | KILLED | Q4 |
| R2 | the `vr_rdy` gate removed from P_RECV | KILLED | Q4 |
| R3 | the K request driven from the ISSUE cycle again, gate left in | KILLED (hang) | watchdog |
| R4 | the `kv_wr_idle` gate removed in the RTL, WR_LAT 12 | **SURVIVED** | see 6.2 |
| R4b | the same, at a 4000-cycle BRESP latency | KILLED | Q5 |
| R5 | the K bypass removed | KILLED (hang) | watchdog |
| R5b | the K bypass removed AND the cache told `cur_pos` is readable | KILLED | Q6 **and** Q1 |
| R6 | `attn_kv_axi` stops refusing `pos >= cur_pos` | **SURVIVED** | see 6.3 |
| R7 | `kw_rdy` stops covering the flush | **SURVIVED** | see 6.4 |
| R7b | the same, at 2000-cycle read latency | **SURVIVED** | see 6.4 |
| R7c | `kw_rdy` tied high, both terms | **SURVIVED** | see 6.4 |
| R7d | the same, write slave refusing AW for 4000 cycles | KILLED | Q5 |

**R3 is the result that settles the design question.** Putting the request
back inside the issue cycle while KEEPING the gate hangs. So "drive it one
state earlier" is not a stylistic half of the fix, it is load bearing: a
residency answer is only meaningful about a question that is already being
asked.

**R1 and S1 are the same defect expressed two ways** -- once as a wire and
once as an edit -- and both die on Q4. That is deliberate: it shows the
property is about the handshake and not about one file's text.

### 6.1 S2 survived, and the survival is the point

Withdrawing `kr_rdy` mid-record does not corrupt anything, because P_RECK does
not advance `blk` when the gate is closed: the block simply re-offers the same
beat next cycle. That is what a gated consumer is FOR, and it is the behaviour
a real cache needs, since a residency answer can go away when a run is
retargeted.

**This survivor is only worth anything because the mutation was strengthened
first.** The original form dropped `kr_rdy` for exactly one cycle and survived
trivially; a one-cycle withdrawal is a legal stall and measures nothing. The
strengthened form withdraws it on roughly a quarter of all cycles, which is
where the next trap was found (7.3).

### 6.2 S5 and R4 survived at WR_LAT 12, and S5b / R4b kill at WR_LAT 4000

The block writes both records in the first ~3% of a job and then spends the
rest of it on the sweep and the output stage, so at any BRESP latency short
compared with a job the write has retired long before `done` and the gate is
unobservable. It is not decorative -- it is a guard on a window this schedule
does not open at that latency. Raising the modelled BRESP latency to 4000
cycles opens it, and then both forms die on Q5 with the same message. Both
rows are kept, because "survives at 12, dies at 4000" is the actual shape of
the risk and reporting only the kill would overstate the check.

### 6.3 R6 survived: a guard against a consumer this consumer is not

`attn_kv_axi` refusing `pos >= cur_pos` protects against a consumer that asks
for the record it is currently writing. `attn_block` never asks, because it
bypasses. So removing the refusal alone changes nothing observable. R5 and R5b
are the complementary pair that show the guard is not dead code: with the
bypass removed, the refusal is what turns the defect into a hang (R5), and
when the cache is told `cur_pos` is readable so the refusal no longer covers
it, the read is served (R5b) and is caught by the address property. C4 is
R5b's other half run alone, and it passes -- so R5b's kill is the bypass and
not the descriptor skew.

### 6.4 R7, R7b, R7c survived: the write-side gate has no window at this schedule

`kw_rdy` has two terms. The flush term (R7, R7b) never bites because the
block's prologue -- a norm, a RoPE and a quantizer invocation -- outlasts the
drain even at a 2000-cycle read latency, so the first write of a job always
arrives after the flush has finished. The buffer-full term (R7c) never bites
because the K and V writes are separated by a whole V load and quantize. Tying
`kw_rdy` high is therefore invisible **at this write-side latency**, and R7d
is the strengthening that makes it visible: with the write slave refusing AW
for 4000 cycles the record buffer really does back up, records are dropped,
and Q5 fires. C1 is its control and passes.

### 6.5 What R5b showed that C-ORACLE's m14 did not

C-ORACLE recorded that removing the bypass is INVISIBLE to the value oracle
and caught only by the address property, because a memory model returns
exactly what was written. At the seam that is no longer true: R5b is caught by
**both** Q6 (the address property, 4 reports per record) and Q1 (50 of 256
mantissas on token 0, 255-256 of 256 on tokens 1-3). **Why the values move was
NOT determined** and is left open in section 9; the address property fired
first and is the one that matters.

## 7. Measurement traps hit, including three that cost real time

### 7.1 GHDL silently corrupts a signal driven from two processes on disjoint slices

Two processes inside a `for ... generate` each drove a different half of one
unresolved `std_logic_vector`. GHDL mcode reports **"several sources for
unresolved signal"** for a scalar, loudly and with the signal name -- and for
a COMPOSITE it reports nothing and delivers `'U'` on one half and `'0'` on the
other. Reduced to nine lines:

```vhdl
signal d : std_logic_vector(31 downto 0) := (others => '0');
g : for s in 0 to 1 generate
  p : process(clk) begin
    if rising_edge(clk) then
      for c in 0 to 1 loop
        d(s*16 + (c+1)*8-1 downto s*16 + c*8) <= <something non-zero>;
      end loop;
    end if;
  end process;
end generate;
-- reports: d = 0, plus a TO_INTEGER metavalue warning, for ever
```

It presented as "the cache returns zeros for a record that is demonstrably in
memory", and an hour went into instrumenting the DUT before the bench was
suspected. **Symptom to recognise: correct addresses, correct memory contents,
zeros on the wire, and NUMERIC_STD metavalue warnings.** Both read slaves are
now one process.

The same rule bites differently through an array: indexing one array signal
from a loop whose index is not static creates a driver for the **whole**
array, which then collides with any other process driving any element. Two
plain integer counters is the form that can do neither.

### 7.2 VHDL is case-insensitive, so a process variable can shadow a constant

`variable nb : integer` in the write slave shadowed `constant NB : integer :=
8192`, the size of the modelled memory, and the range check
`a + l*BEAT_B > NB` silently compared against 0 -- so every legal write
address was reported out of range. Renamed to `wbeats`. **A range check that
fires on everything is a shadowed bound, not a broken master.**

### 7.3 `x := x xor (x sll 13)` is not a random number generator

The single-term form leaves the **low 13 bits unchanged for ever**. Anything
selecting a low nibble out of it is a constant wearing the word
"pseudo-random". Found because `MUT_DROP_RDY` selects bits 5..4, which held
their seed value, so a stall mutation became a permanent one and the run hung.

**It was already in `sim/tb_attn_block.vhd`, and it had disabled that bench's
third consumer configuration.** `rnd_r(3 downto 0)` was the constant 13, the
test `< 6` never fired, and configuration 2 -- the one whose comment says
"pseudo-random" -- was a second copy of configuration 0. P2 was comparing two
never-stalling runs and one fixed-gap run. Fixed to a full xorshift32 in both
benches; `tb_attn_block`'s back-pressure count went **126 -> 166 stalled
beats** and the values are still bit-exact, which is P2 doing its job.

### 7.4 A per-token `v_ref` reset is unobservable at most stimuli

The seed matters and had to be CHOSEN. At seeds 1, 3, 7, 11, 42, 123, 999,
20260828 and 31337 the sequence oracle is **byte-identical** whether `v_ref`
is folded across the sequence or reset per token, because at those stimuli
every token's own record already carries the sequence minimum. At **seed 2**
it moves 358 of the vector file's 5,328 integers. The bench and
`sim/regress.sh` therefore pin seed 2, with the reason written at both sites.
**A mutation that does not bite may be measuring the stimulus, not the check.**

### 7.5 A bench whose write slave commits at W time cannot see a BRESP defect

The first version of the write slave wrote to the modelled memory when it
accepted a W beat. That makes a write visible to the read masters before its
BRESP, which is precisely what AXI does not promise, and it made S5 and R4
survive for the wrong reason. The slave now HOLDS accepted beats and commits
them at the instant BVALID is returned. **Model the ordering the spec
actually gives you, or the spec's own rule becomes untestable.**

### 7.6 `run_case` must not be used on the left of `&&`

Its exit status is that of the final `grep`, which finds nothing on a clean
kill, so `run_case ... || echo ANCHOR FAILED` printed a spurious ANCHOR FAILED
directly after a correct KILL. Rewritten as `if/then/else`. Same family as
"a check whose result you do not branch on is decoration": here the result
being branched on was not the result at all.

## 8. Measured and REJECTED -- do not retry

- **Adding elasticity to `attn_block`'s capture pipeline** (a FIFO, or a
  valid coming back with the beat). Rejected before it was written: it changes
  the schedule, and the schedule is what the bit-exact oracle pins. The gate
  costs nothing when the answer is '1', which is every cycle in
  `tb_attn_block`, and that is why the 130-value comparison and the 81065 ns
  end time did not move. Any design that touches the capture would have had to
  re-earn the oracle.

- **Making the `_rdy` inputs mandatory (no default).** Rejected because
  `rtl/llama_top.vhd` belongs to another track and instantiates this block; a
  port without a default would have broken it. The cost is recorded in the
  header and in section 9: an instantiation that leaves them open gets the
  pre-seam behaviour silently.

- **Composing the sequence oracle out of a second copy of the arithmetic.**
  Rejected. `ref/attn_block_seq_vec.c` INCLUDES `ref/attn_block_vec.c` and
  calls its `attn_token()`. Two copies of an oracle drift and nothing ever
  compares them to each other; what is new here is the CACHE, not the fixed
  point, so the cache is the only thing written twice.

- **Removing the five `oor` guards inside `attn_kv_axi` to make R5b serve the
  read.** Started, then rejected: `q_rdy`, the run-open condition, the retarget
  condition, the landing filter and the `lim_rec` bound would all have to go,
  and at that point the mutant is a different design rather than a mutation.
  Replaced by a bench generic that hands the CACHE a `cur_pos` one larger,
  which reaches the same state with one wire and has C4 as its control.

- **A one-cycle `kr_rdy` withdrawal as a mutation.** Measured, survived,
  and it deserved to: a gated consumer absorbs it. Do not report that form as
  evidence of anything.

## 9. Open, not yet answered

- **`rtl/llama_top.vhd` does not connect any of the four new inputs.** It
  cannot, today, because `attn_kv_axi` is not instantiated there; the block
  runs against `llama_top`'s own memory model with the '1' defaults, which is
  correct for that model and silently wrong for a cache with latency. Closing
  that is backlog item 3 and it is not this track's file.

- **Why R5b moves the VALUES and not only the addresses.** C-ORACLE's m14 was
  invisible to its value oracle; the same mutation at the seam moves 50 of 256
  mantissas on token 0. The mechanism was not chased. It does not affect the
  conclusion (Q6 fired first and fires on every offending read) but it is a
  difference between two benches that nobody has explained.

- **The shipping geometry.** This runs HEAD_DIM 64 / 4 query heads / 2 KV
  heads / KV_BLOCK 16 / N_ROT 16. The build is 256 / 12 / 2 / 32 / 64.
  KV_BLOCK 16 is the SMALLEST legal value for `attn_kv_axi` -- the record is a
  byte layout on a 16-byte granule -- so `sim/tb_attn_block.vhd`'s KV_BLOCK 4
  geometry cannot be used here at all, and the two benches are on different
  points.

- **Long context.** NTOK is 4. The s26 softmax denominator and the s36
  accumulator are the widths that would first bite at long context and neither
  is approached. `MAXCTX` is 8.

- **Two layers at once.** `LAYER_SEL` is a single layer. The `layer` term of
  the address equation is exercised only in that it is multiplied by something
  non-trivial, not by two layers interleaving in one sequence.

- **Real HBM.** The three slaves are a fixed-latency in-order model with a
  single ID. Reordering across IDs, refresh and bank conflicts are not
  modelled. **No hardware was touched at any point.**

- **Synthesis.** Nothing here was run through Vivado. The gate adds one
  comparison to three existing conditions and turns four registered outputs
  into combinational ones; the second of those is a real timing change on the
  `kr_pos` / `kr_head` paths and it is a DERIVATION that it is small, not a
  measurement.

- **Whether the seam has other defects.** Q1 is bit-exact on one descriptor at
  one geometry over four tokens. It is a strong check on that point and says
  nothing about any other.
