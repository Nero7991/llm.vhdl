# The conv tap history: three rewrites to get the BRAM the bit count promised

2026-09-02. `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2 OOC at 5.0 ns, GHDL 1.0.0
mcode. No hardware. Files: `rtl/gdn_conv_tap_mem.vhd`,
`sim/tb_gdn_conv_tap_mem.vhd`, `sim/ooc_gdn_conv_tap_mem.tcl`.

## 1. The question, verbatim

"What does one GDN layer's conv tap history cost on this device?" -- asked
because `gdn_conv` is a causal depthwise convolution of kernel 4, so the
previous 3 columns of the whole qkv width have to survive from token to token,
and `rtl/llama_top.vhd`'s stub returns ZERO for every stored tap. That stub is
why `B_SRC_REAL` has never been run past token 0 anywhere in this repository.

Arithmetic first: `(conv_kernel-1) * qkv_dim * 16 bits` =
`3 * 8,192 * 16` = **393,216 bits = 49,152 bytes per layer**, which "is 12
RAMB36" against the 672 on the part.

## 2. The answer, up front

**12 RAMB36, 317 CLB LUT, 8 FF, WNS +3.831 ns (261 MHz).** 1.79% of the
device's BRAM and 0.07% of its LUTs.

**It took three rewrites to get there, each stopped by a DIFFERENT Vivado
refusal, and the first version cost 35,726 CLB LUT and ZERO BRAM.** The bit
count was right about the storage and predicted none of it. That is the
finding: `49 KB is 12 RAMB36` is a statement about bits, and what the tool
builds is a statement about the ACCESS PATTERN.

| version | structure | CLB LUT | BRAM |
|---|---|---:|---:|
| 1 | one array of 192-bit words, variable-offset partial writes | **35,726** | **0** |
| 2 | array-of-array of 16-bit banks, whole-word writes | -- | **0** |
| 3 | banks inside a `for ... generate`, true dual port | -- | **0** |
| 4 | banks in a generate, SIMPLE dual port | **317** | **12** |

## 3. The procedure

1. Size it from the repository's own scrapers, not by hand. `qkv_dim` is
   `2*key_dim + val_dim`, the identity `gen_layer_program.Shape` and
   `llama_map_pkg` already use; the element width comes off `gdn_block`'s own
   `cv_x` port. Reserve it in `tools/hbm_map.py::arena_sizes()` INSIDE
   `gdn_state_bytes_per_layer`, so there is one base and one stride.
2. Write the module and a bench whose oracle is the TOKEN SEQUENCE.
3. Mutate.
4. OOC census. **Read the census, not the intention.**
5. Rewrite, re-run the bench to prove the rewrite is behaviour-preserving,
   re-census. Three times.

## 4. The evidence

**Version 1** -- `ram_style = "block"` on one array of 192-bit words:

```
CENSUS gdn_conv_tap_mem LUT=7605 FF=214 RAMB36=0 RAMB18=0 URAM288=0
                        RAM64=3584 DSP=0 WNS=3.453
| CLB LUTs*      | 35726 | ... |  8.13 |
|   LUT as Logic |  7566 |
|   LUT as Memory| 28160 |
| Block RAM Tile |     0 |
```

**Version 2** -- one `array (0 to NBANK-1) of array (0 to NGRP-1) of
std_logic_vector(15 downto 0)`, every write a whole 16-bit word:

```
WARNING: [Synth 8-11357] Potential Runtime issue for 3D-RAM or RAM from
         Record/Structs for RAM mem_reg with 393216 registers
WARNING: [Synth 8-7186] Applying attribute ram_style = "block" is ignored,
         object 'mem[0][83]' is not inferred as ram due to incorrect usage
         ... x100 ...
```

**Version 3** -- each bank declared inside a `for b in 0 to NBANK-1 generate`,
so every array is plainly two-dimensional, with the unit on port A and the
mover on port B of one process:

```
WARNING: [Synth 8-4767] Trying to implement RAM 'gbank[11].m_reg' in registers.
Block RAM or DRAM implementation is not possible; see log for reasons.
Reason is one or more of the following :
        1: RAM has multiple writes via different ports in same process.
           If RAM inferencing intended, write to one port per process.
RAM "gbank[11].m_reg" dissolved into registers
```

**Version 4** -- SIMPLE dual port: ONE write port and ONE read port, each
muxed between the unit and the mover:

```
CENSUS gdn_conv_tap_mem LUT=359 FF=8 RAMB36=12 RAMB18=0 URAM288=0
                        RAM64=0 DSP=0 WNS=3.831
| CLB LUTs*         |  317 | ... | 0.07 |
|   LUT as Logic    |  317 |
|   LUT as Memory   |    0 |
| Block RAM Tile    |   12 | ... | 1.79 |
|     RAMB36E2 only |   12 |
```

The bench reported `PASS -- 107 checks, of which 48 confirmed the taps are
columns T-3..T-1 oldest first across 6 tokens` at every one of the four
versions, which is what makes each rewrite provably behaviour-preserving
rather than hopefully so.

## 5. Why version 4 is sound and not a compromise

The unit and the mover **never operate in the same cycle**:
`gdn_state_store`'s ownership rule gates `gdn_block` off whenever a mover owns
the tier, and a sim-only assertion says so. So one read port and one write
port are sufficient, and the muxes are free next to what they buy.

It also makes the **mover-wins rule STRUCTURAL**. In version 3 that rule was a
priority term in the port-A write condition, and no bench could see whether it
was there: in simulation port B assigns second within the same delta and
simply overwrites, so a mutation removing the term PASSED 107 of 107 -- while
being an UNDEFINED same-address dual-port write in hardware. With one write
port there is no collision to resolve; a mover write is a unit write that does
not happen.

## 6. The mutation table

Bench: `sim/tb_gdn_conv_tap_mem.vhd`, 107 checks, 6 tokens.

| # | mutation | result |
|---|---|---|
| T1 | rotation direction reversed | FAIL 48/107 |
| T2 | `phase` never advances | FAIL 88/107 |
| T3 | the unit writes the slot AFTER the one being retired | FAIL 88/107 |
| T4 | rotate by the live `phase` instead of the captured one | **PASS -- NO BITE** |
| T5 | the bank read made combinational | FAIL 1/107 |
| T6 | mover addressing group-major instead of slot-major | FAIL 54/107 |
| T7 | segment 1 (k) aliased onto segment 0 (q) | FAIL 36/107 |
| T8 | mover write address ignored, unit's used instead | FAIL 7/107 |
| T9 | mover read address ignored, unit's used instead | FAIL 43/107 |

**Eight of nine bite. T4 does not, and it is reported under its own name.**
The RTL comment justifying `rq_ph` originally claimed the capture "makes the
read correct across the `tok_adv` boundary", implying a reachable case. There
is none: `tok_adv` fires only after every layer has both read and written for
the token, so no conv read can be in flight on that edge. The 2 FF are kept as
defence against a future caller that overlaps them, and the comment now says
UNTESTED rather than justified.

**T5 is worth its own line.** It bites on exactly ONE check -- the pair that
drives a new address and asserts the data has NOT moved before the clock edge.
Every one of the other 106 checks passes against a combinational memory. A
bench that only verified the value after the edge would have accepted the
wrong primitive entirely, which is how `region_mem` cost 91,073 LUT.

## 7. Measurement traps hit

- **VHDL IDENTIFIERS ARE CASE-INSENSITIVE, so `for t` nested inside `for T` is
  the SAME name and silently shadows.** All 48 tap-order checks failed on the
  first bench run and **the DUT was correct**. The only warning was one
  `-Whide` line that reads like pedantry:
  `declaration of "t" hides constant "t"`. It cost a wrong hypothesis and a
  debug pass; the tell was that the printed `want` values were the ones for a
  DIFFERENT token index. Inner loops are now `k`, and the model function's
  parameter is `tok` so no call site can collide again.
- **The bit count predicted the tile count and nothing else.** 393,216 bits
  "is 12 RAMB36" was true in versions 1, 2 and 3 as well, and all three got
  zero. Never quote a memory's cost from its size.
- **`[Synth 8-7186]` fired on an object that WAS getting the attribute honoured
  in a different run**, which is the same message this project has already
  recorded lying in the other direction. Both times the mapping report settled
  it. The warning is a hint about where to look, never an answer.
- **A rewrite that "obviously" fixes the inference may fix a DIFFERENT thing.**
  Version 2 removed the variable-offset partial write -- a real defect -- and
  the BRAM count stayed zero because a second, unrelated cause was in the way.
  Two more rewrites, two more causes. Re-census after every one.

## 8. Measured and REJECTED -- do not retry

- **Do NOT store the taps as one wide word per group with the mover writing a
  lane inside it.** That is version 1: 35,726 LUT, 0 BRAM. A bit slice whose
  bounds are expressions is not a byte-enable.
- **Do NOT use `array of array of std_logic_vector` for a memory.** Version 2.
  Vivado calls it a 3D-RAM and dissolves it into registers whatever
  `ram_style` says. Declare the array inside a generate.
- **Do NOT write the true-dual-port template from one VHDL process.** Version
  3. Vivado wants one process per port; two VHDL processes cannot drive one
  signal; a shared variable would be needed. Not worth it here, because the
  two users are mutually exclusive by construction.
- **Do NOT make `phase` per-layer.** Every GDN layer is visited exactly once
  per token, so all layers rotate in lockstep and `phase` is
  `token_index mod (KCONV-1)`, a single global counter. Per-layer would have
  needed HBM storage it has nowhere to live: `LAYER_STRIDE` is
  `1,048,576 + 4,096 + 49,152` with no slack, and the arena would have had to
  grow a second time.

## 9. Open, not yet answered

- **NOTHING MOVES THIS TO OR FROM HBM.** The arena reserves it and the memory
  exists and is verified; there is no third phase in `gdn_state_store` and no
  `gdn_state_axi` instance at `WORD_BITS => 16, N_GRP => 1`. Until there is,
  `B_SRC_REAL` still cannot run past token 0 and the module's header says so.
- **Nothing writes the taps in anger either.** The unit write port expects
  this token's qkv column from A, one group at a time, and no sequencer feeds
  it. That is the same job as the B job sequencer.
- **`tok_adv` has no owner.** It is an input because only the caller knows
  where a token ends; nothing currently pulses it.
- **T4 is untested** and so is read-during-write on a bank. Both are
  unreachable by construction in the current caller, and "unreachable by
  construction" is a property of the CALLER, not of this module.
- **The 12 tiles are an OOC number.** Whether they survive next to a
  composition already at 48.7% BRAM has not been measured.
