# The wall is RTL Elaboration, and the trim I chose to get past it was illegal

**Date:** 2026-09-11
**Builds:** `card13` (workstation, full 9B, `MemoryMax=26G`), `cardtrim`
(BC-250, `C_KV_BLOCK=4`, `MemoryHigh=11G`), `cardtrim16` (BC-250, `C_KV_BLOCK=16`)
**Part:** xcvu33p-fsvh2104-2L-e

## The question

> Is it done?

and, once it was not: what exactly is the card build stuck ON, and can a smaller
geometry get past it?

## The answers, up front

1. **The wall is `synth_design` RTL Elaboration of the card top.** Not
   synthesis, not optimisation, not placement. **No surviving log in this
   repository has ever contained `Finished RTL Elaboration` for the card**,
   across twelve attempts and two machines.
2. **The trim I chose to test that was ILLEGAL and the build was doomed from
   launch.** `C_KV_BLOCK=4` violates a constraint stated in `rtl/llama_top.vhd`.
   Relaunched at 16, the smallest legal value.

## The procedure

1. `grep -aE '^(Starting|Finished)' runme.log | tail` on both builds. Both end
   at `Starting RTL Elaboration` and nothing after. **This is the step that
   named the wall**, and it had not been run before: earlier sessions read the
   log's last LINE, which is an unrelated `gtwizard` warning.
2. `grep -c 'Finished RTL Elaboration'` across every surviving `runme.log`.
   Zero. Turns "this build is slow" into "this phase has never completed".
3. `grep -ao "synthesizing module '[A-Za-z0-9_]*'"` to ask which modules were
   begun. `card13`: 148 modules, **`fk33_card` never begun**. `cardtrim`: 197,
   including `fk33_card`, `fk33_llama_top`, `gdn_block`.
4. CPU-tick delta and `/proc/PID/fd/1` on the live processes: both alive, both
   computing, neither thrashing.
5. **Reading the generic's constraints before trusting the trim -- done LAST,
   which is the error.** `rtl/llama_top.vhd` and `rtl/attn_kv_axi.vhd:412`.

## The evidence

Both builds, same phase, hours apart:

```
card13     Starting RTL Elaboration ... free physical = 16721     07:32:45
cardtrim   Starting RTL Elaboration ... free physical =  6778     13:23:27
grep -c 'Finished RTL Elaboration'  ->  0        (every surviving log)
```

The constraint I violated, `rtl/llama_top.vhd`, in the block I was reading:

```
C_KV_BLOCK  : positive := 4;    -- correct ONLY when C_KV_AXI is false
...
"attn_kv_axi demands CM_W = 8, a record on a 16-byte granule (so
 KV_BLOCK*CM_W/8 must be a multiple of 16, i.e. KV_BLOCK >= 16)"
"C_KV_BLOCK 32   legal set at head_dim 256 is {16,32,64,128}"
```

And `rtl/attn_kv_axi.vhd:412` had already MEASURED my exact case:

```
MEASURED 2026-08-29, Vivado 2023.2 ... with HEAD_DIM 256 / KV_BLOCK 4 the
constant is "ERROR: [Synth 8-11323] assigned value '-48' out of range" and
synthesis FAILS
```

## Measured and REJECTED -- do not retry

- **`C_KV_BLOCK=4` as a trim for the card.** ILLEGAL at head_dim 256, which is
  the shape at BOTH 9B and 27B, so it does not relax anywhere. Refused by
  `gen_fk33_card.py` from `e819c3f`.
- **"The memory cap is what holds the card build back."** REJECTED: +6 GiB of
  cap bought 0.10 GiB of growth. See the companion write-up of the same date.
- **Memory direction as a progress signal.** REJECTED. `card13` went +1.17,
  then -1.32, then +1.17 GiB/hr with the log frozen at one byte offset
  throughout. It OSCILLATES; it is global reclaim, not progress.
- **Module count as a cross-build progress metric.** NOT ESTABLISHED. It is
  unproven whether `synthesizing module` lines track elaboration or an earlier
  parse pass, and the two designs differed, so 148 vs 197 is not a like-for-like
  comparison. The qualitative form -- one began `fk33_card`, the other never did
  -- is the only part that survives, and even that came from an illegal build.

## Measurement traps hit

- **A generic's DEFAULT is not a legal value for every configuration.**
  `C_KV_BLOCK : positive := 4` is the declared default and is illegal for the
  card, because the card sets `C_KV_AXI=true`. Choosing the default LOOKS
  conservative and is not. **Read what the default is conditional on.**
- **I had the constraint on screen and did not read it.** The legal set is in
  the comment block containing the generic I was editing. I was reading for
  instance counts and generate loops, and the rule was three lines away.
- **A guard existing is not a guard firing early.** The out-of-range-`natural`
  idiom WOULD have caught this -- it is used in `attn_kv_axi.vhd` precisely
  because it survives Vivado where `assert ... severity failure` does not. But
  it fires deep in elaboration, hours in. A cheap check at the point of CHOICE
  is worth more than a correct check at the point of USE.
- **Quoting a measurement taken from an invalid configuration.** I reported the
  illegal build's "3.7x smaller dominant process" as evidence the trim bit. It
  measured a design that cannot be built. WITHDRAWN.

## Open, not yet answered

- **Why does the card top never finish RTL Elaboration?** Unknown. Known: B
  (`gdn_block`, 221.4 MHz) and C (`attn_block`, 239.5 MHz) each synthesise
  standalone in 3-4 minutes; with both black-boxed the card top CLEARS
  elaboration and stalls in optimisation instead. So the cost is B/C content in
  the composition, not B or C alone, and not the wrapper alone.
- **Whether `C_KV_BLOCK=16` is enough of a reduction.** It is 2x, not the 8x I
  wrongly attempted. `cardtrim16` is the test.
- **Whether GHDL's ability to elaborate the real 9B shape (TRACK REALFIX) means
  the design is sound and the problem is Vivado-specific.** Untested.
