# gdn_emit_chain: why head 23 of every block was wrong

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`, chain at commit `72f5c8d`, testbench added
at `03d83a1`, fix at `5c1a4b2`.
**Tools:** GHDL mcode backend (`ghdl -r` direct, no `-e`), Vivado 2023.2,
`xcvu33p-fsvh2104-2L-e`.

## The question

Commit `72f5c8d` shipped `gdn_emit_chain` with a note in its own message: *"NOT
yet done: sim/tb_gdn_emit_chain.vhd. The chain has a reference and analyzes
clean; it is not yet verified against the RTL."* The question was simply
whether the four seams that were compatible **by inspection** were compatible
in fact.

Symptom, once the testbench existed and was run in the configuration the chain
is actually designed for (overlapped blocks):

```
block 0 element 2944 head 23 lane 0 got 0   expected 7
block 0 element 2945 head 23 lane 1 got -39 expected -53
block 0 element 2946 head 23 lane 2 got -15 expected -7
```

Heads 0 through 22 were bit-exact. Head 23 was wrong. Every block.

## The answer

`w_mant` was a single unlatched input port, read combinationally by
`rmsnorm_bf` once per head for all 24 heads of a block, while blocks OVERLAP by
design. Block b's head 23 normalizes **after** the producer has already
presented block b+1's `ssm_norm`, so head 23 alone is normalized with the wrong
weights. Fixed by latching w at head 0's pickup and pulsing a new `w_taken`
output so the producer has an observable safe instant.

## The procedure that produced it

Each step isolates one thing. The order matters: the chain has four units and
four seams, and a single end-to-end failure identifies none of them.

1. **Generate reference vectors from a double-precision oracle.**
   `ref/gdn_emit_chain_vec.c` computes the chain twice, once in the fixed-point
   model and once in double, and refuses to emit if they disagree by more than
   8.0 LSB of the output grid (measured 1.21 to 1.53 over 6 blocks). This is
   the double-oracle rule: a golden sharing machinery with the DUT certifies
   broken units.

2. **Write the testbench BLOCK-SERIALIZED first**, waiting for `done` between
   blocks. This is the deliberately weaker configuration. It passed 6 blocks x
   24 heads x 128 bit-exact, which established that all four seams and the
   whole datapath are correct in isolation, so any later failure is a
   concurrency property and not arithmetic. **Bisecting the two apart before
   running the harder case is the step that made the head-23 result readable.**

3. **Mutation-test the serialized testbench before trusting its pass.** Five
   non-equivalent mutations, one per seam plus two control paths. All five
   killed. Table below.

4. **Read the state machine for the block boundary**, specifically
   `S_WAITBLK`, which returns to `S_IDLE` unconditionally on the next cycle.
   That is what makes blocks overlap, and it is what makes the w read window
   span a producer-visible boundary.

5. **Add the OVERLAP mode and run it.** Head 23 of every block failed. The
   *shape* of the failure -- one head, always the last, all blocks -- named the
   cause without further probing.

6. **Confirm the fix is load-bearing rather than coincidental** by reverting
   ONLY the port map (`w_mant => w_held` back to `w_mant => w_mant`), leaving
   the latch registers and `w_taken` in place, and re-running. The head-23
   corruption reproduced exactly. A fix that is not shown to be necessary is
   not shown to be the fix.

### Why head 23 and not head 0

Worth stating because the intuition runs the other way. The producer presents
block b+1's w at the moment it starts feeding block b+1's columns. At that
instant the chain is still finishing block b -- `gdn_head_emit` runs one head
ahead of the norm, so the last head fed is not the last head normalized. Head
23's `S_RMS` therefore lands after the change. Head 0 of the next block is
fine, because by then w is correct for it.

## The evidence

Serialized mode, before the OVERLAP mode existed:

```
tb_gdn_emit_chain: block 0 checked, y_exp=10, mismatches so far 0
tb_gdn_emit_chain: block 1 checked, y_exp=10, mismatches so far 0
...
tb_gdn_emit_chain: PASS -- 6 blocks x 24 heads x 128 bit-exact, OVERLAP=false
```

Mutation results on the serialized testbench:

| mutation | seam | result |
|---|---|---|
| drop `z_e_held` from `ep_r` | 4 | killed: `y_exp is -2, reference says 10` |
| `x_exp + 1` into `rmsnorm_bf` | 1 | killed: element 0 head 0 |
| reverse the gate lane index | 3 | killed: element 0 head 0 lane 0 |
| `ye_hfirst` never asserted | ctrl | killed: `y_exp is -15, reference says 10` |
| `si_e_seg` forced to zero | ctrl | killed: element 0 head 0 lane 0 |
| swap `ye_o` and `ye_z` | 2/3 | **SURVIVED -- equivalent mutant, see below** |

Overlapped mode with the unlatched w (the bug, reproduced deliberately):

```
block 0 element 2944 head 23 lane 0 got 0   expected 7
block 0 element 2945 head 23 lane 1 got -39 expected -53
block 0 element 2946 head 23 lane 2 got -15 expected -7
```

Both modes after the fix:

```
PASS -- 6 blocks x 24 heads x 128 bit-exact against the reference, OVERLAP=false
PASS -- 6 blocks x 24 heads x 128 bit-exact against the reference, OVERLAP=true
```

Overlap is worth measuring while it is in front of you: 103,516,500 ps
overlapped against 134,321,500 ps serialized for the same 6 blocks, at a 1 ns
clock. **~23% of wall time, and 17,253 cycles per block against 22,386.**

## Measured and REJECTED -- do not retry

- **"Just document the timing contract instead of latching."** Rejected. The
  safe window does exist -- the chain is never in `S_RMS` for two blocks at
  once -- but it is not observable from outside the unit. `done` is thousands
  of cycles too late and nothing else marked the boundary. A contract a
  producer cannot *see* is a bug waiting on a schedule change.
- **"Change w on `done`."** This is the specific thing that fails, and it is
  the obvious thing to do. `done` fires after `gdn_y_emit` streams the block
  out; block b+1's head 0 reached its norm roughly `DIM + 268` cycles after its
  columns started, thousands of cycles earlier.
- **Swapping `ye_o` and `ye_z` as a seam-2/3 mutation.** Do not read its
  survival as test blindness. `rtl/gdn_y_emit.vhd:274` is `a_prod <= in_o *
  in_z`, the sole use of either signal, same width and same signedness, so the
  swap is a no-op by construction. This was checked by reading the unit, not
  inferred from the fact that multiplication commutes -- the two operands could
  have differed in width or in how their exponents were applied. Use a lane
  skew instead; the in-bounds version (reverse the index) kills on values
  rather than on a bounds trap.

## Measurement traps hit

- **An out-of-bounds slice is a weak kill.** The first seam-3 mutation used
  `(ser_j+2)*16-1 downto (ser_j+1)*16`, which runs off the end of `z_buf` at
  `ser_j = DIM-1`. The run "failed", but it failed on a VHDL bounds check, so
  it demonstrated that *VHDL* noticed, not that the *testbench* did. Redone as
  an in-bounds lane reversal, which produced actual wrong values. **A mutation
  that trips a language check has not tested your checker.**
- **The collector never reset between blocks** and asserted "more outputs than
  a block holds" on block 1. Harmless here because it failed loudly, but the
  tempting fix -- reset `y_cnt` to 0 on `done` -- would have handed the
  stimulus a zero count to compare against and read as agreement. The count is
  latched into `y_n`/`cnt_got` on `done` instead. Same failure class as the
  `gdn_exp_capture` testbench that compared unwritten `'U'` taps and passed
  because `to_integer` returns 0 for both sides.
- **VHDL is case-insensitive, and GHDL reports the collision as a `-Whide`
  warning, not an error.** A loop variable `h` silently shadowed the header
  variable `H` holding the vector file's head count. It would have read the
  right value anyway here; it is listed because the warning is easy to scroll
  past and the failure mode is a silently wrong shape check.
- **`y_exp` is 10 for all six blocks**, because `gdn_y_emit` renormalizes each
  block to a common grid. The exponent check is therefore comparing against a
  constant. It still has teeth -- the seam-4 mutation moved it to -2 and the
  `ye_hfirst` mutation to -15 -- but it is not a varying-exponent test, and a
  bug that happened to preserve the grid would slip past it.
- **A 2-minute tool timeout truncated a 3-block run** that needed ~90 s of wall
  clock, and the truncation looked like a hang. 6 blocks overlapped is ~103 ms
  of sim time; budget several minutes and pass an explicit long timeout.

## Open, not yet answered

- **`w_taken` is a pulse with no back-pressure.** If a producer changes w
  before it fires, nothing complains. An assertion that w is stable from the
  first column of a block to `w_taken` would catch that, and does not exist.
- **The 2048 FF cost of the latch remains an estimate from `DIM*16`.** The
  assembled chain measures 14,518 FF total at the adopted SILU_LANES=16 /
  RMS_LANES=4, but no pre-latch build exists to difference against, so the
  latch's share is still inferred rather than measured. The chain's Fmax is
  now known: **300.75 MHz**, above B's 299.04 MHz target. See
  `2026-08-27_gdn-head-emit-done-pulse.md` for the sweep that got it there.
- **`y_sat` is still unconsumed** with no policy, unchanged from `72f5c8d`.
- **Only 6 blocks and one seed.** The overlap depth exercised is whatever the
  natural rates produce; a producer running faster than `col_ready` allows is
  covered by `gdn_head_emit`'s own back-pressure test, not by this one.
