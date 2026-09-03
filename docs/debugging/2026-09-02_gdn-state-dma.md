# The GDN state mover, and the nine defects its bench found (four in the design, five in the bench)

**Date:** 2026-09-02
**Modules:** `rtl/gdn_state_axi.vhd`, `sim/tb_gdn_state_axi.vhd`
**Depends on:** `docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md`

---

## 1. The question

The GDN recurrent state is 24.0 MB against 14.2 MB of on-chip memory, so one
layer is resident and the rest lives in HBM. `rtl/gdn_state_mem.vhd` is the
resident half, measured at 32 URAM288. **What moves a layer between HBM and
that store, and does it work?**

## 2. The answer

`rtl/gdn_state_axi.vhd`: a bulk DMA, not a cache, because `gdn_block`'s
`st_rdata` is a registered read one cycle after the address and no amount of
prefetching lets that port reach HBM. Load before `start`, save after `busy`
falls, 24 times per token.

**It passes 393 checks per run across six geometries, and all five mutations
bite. It did not work at any point before the bench existed**, and the first
version failed in four independent ways that no amount of reading would have
caught.

## 3. The procedure

The oracle is deliberately **not** a load-then-save round trip. A DMA that
byte-swaps, drops the last word of every beat, or addresses the store
transposed round-trips perfectly. Instead:

1. write pattern A into the slave's memory, LOAD, read the store back through
   its own second port, compare against A;
2. write a DIFFERENT pattern B into the store, SAVE, compare the slave's
   memory against B.

Neither direction is checked by replaying the other, and the two patterns
differ in every 16-bit lane so a swapped or dropped lane inside a word shows.

The slave is deliberately awkward: configurable read latency, configurable
write-response latency, pseudo-random deassertion of ARREADY/AWREADY/WREADY,
queue-depth backpressure. **A DMA tested against an always-ready slave is
tested against a bus that does not exist**, and the bench refuses to pass if
the stall counters are zero.

## 4. The evidence

```
=== MUTATION TABLE ===
  CTRL  RESULT: PASS   bad=0
  M1    RESULT: FAIL   bad=192     one-edge collect instead of two
  M2    RESULT: FAIL   bad=1       BRESP not awaited ("write responses retired")
  M3    RESULT: FAIL   bad=256     layer offset dropped from the base
  M4    KILLED                     last beat dropped ("never asserted `done`")
  M5    KILLED                     WLAST always ("WLAST asserted mid-burst")

=== GEOMETRY SWEEP ===
  VH=2  DIM=8   RL=2  DW=128  MAXB=4   OUT=2  RLAT=7   BLAT=6  checks=393  bad=0
  VH=4  DIM=8   RL=2  DW=256  MAXB=4   OUT=3  RLAT=5   BLAT=0  checks=777  bad=0
  VH=2  DIM=16  RL=4  DW=128  MAXB=4   OUT=2  RLAT=3   BLAT=9  checks=777  bad=0
  VH=8  DIM=8   RL=2  DW=128  MAXB=4   OUT=2  RLAT=2   BLAT=1  checks=1545 bad=0
  VH=2  DIM=8   RL=2  DW=128  MAXB=8   OUT=4  RLAT=13  BLAT=4  checks=393  bad=0
  VH=4  DIM=16  RL=4  DW=256  MAXB=4   OUT=2  RLAT=11  BLAT=6  checks=1545 bad=0
```

## 5. The nine defects, and which side each was on

**This is the reusable part. Five of the nine were in the BENCH, and every one
of those presented as a design bug.** A bench is not an oracle until it has
been debugged as hard as the thing it tests.

### In the design

| # | defect | how it presented |
|---|---|---|
| D1 | emitted a FLAT word index; `gdn_state_mem` takes `(head, col, grp)` | every loaded word read back as **zero** |
| D2 | collected the store read after ONE edge; it is **two** | every saved layer shifted by exactly one word, `got(i) = want(i-1)` |
| D3 | accepted a `LAYER_STRIDE` that is not a whole number of beats | **layer 2 wrong, layers 0 and 1 correct** |
| D4 | unbounded outstanding AW; only reads honoured `MAXOUT` | died against any slave with a finite queue |

**D1 is the interesting one architecturally.** The fix was not to decompose in
the mux but to make the DMA emit `(head, col, grp)` itself, so `gdn_state_axi`,
`gdn_state_mem` and `gdn_block` all speak the same shape and the mux is a plain
2:1 with no arithmetic. Arithmetic in a mux is where an integration error hides.

**D2 is a rule this repository already wrote down and I broke anyway.**
`llama_top.vhd:1066`: *"An element whose address is issued at edge k is
therefore readable at edge k+2. Consuming it at k+1 reads whatever the port
held from the PREVIOUS unit's last access."* The fix is a two-deep valid shift
register rather than an index comparison, because the comparison form also has
to handle the request index saturating and gets the LAST word of every beat
wrong when it does.

**D3 was found ONLY by the parameter sweep and cannot fire in the shipping
configuration.** At the real numbers `1,052,672 / 32 = 32,896` exactly, so the
stride is aligned and the bug is unreachable. It took a bench stride of
`MANT_BYTES + 16` at `AXI_DW = 256` to expose it. **A defect that the shipping
parameters happen to avoid is still a defect**, because the next shape change
reaches it silently: layers 0 and 1 were correct.

### In the bench

| # | defect | how it presented |
|---|---|---|
| B1 | `while busy = '1' loop` after the start pulse | **384 of 390 checks failed, store all zeros** |
| B2 | stimulus and slave both drove `smem` | every loaded word came back **'X'** |
| B3 | slave incremented `addr` then read `smem(addr + 1)` | clean one-beat shift from word 4 |
| B4 | slave modelled a single outstanding AW | "WLAST asserted mid-burst", a false design failure |
| B5 | `B_LAT = 0`, so BRESP always arrived before `done` | **mutant M2 survived a check written specifically to kill it** |

**B1 is the trap this repository documents by name.** `rtl/llama_top.vhd`'s
S_ARM comment: *"`busy` does not rise on the same edge as `start`, so waiting
for it to FALL without first seeing it RISE completes instantly."* I read that
comment earlier the same day, while sizing `gb_real`, and then wrote the bug.
The fix is to wait on the `done` pulse and never on `busy` falling.

**B2 is the same multi-driver defect fixed in `llama_top`'s `f_lost` earlier
the same day.** Two processes driving one resolved signal do not take turns;
they resolve. Twice in one session is a good indication of how easy it is.

**B3 and B4 both presented as DUT bugs and were the model's.** B3 in
particular -- a one-beat shift from exactly word 4 with WPB = 4 -- is precisely
what a real DMA bug looks like. The tell was that variables update immediately
and signals do not: `rq(tail).addr := rq(tail).addr + 1` had already taken
effect by the time the next line read `rq(tail).addr + 1`.

**B5 is the most valuable and the least visible.** The BRESP-completeness check
was written specifically to kill M2, added, and M2 **still passed**, because
with a one-cycle write response every BRESP was in hand by the time `done`
reached the stimulus anyway. The check existed and did not discriminate.
Giving the slave a 6-cycle write-response latency is what turned it into a
check. **A check written for a mutant, that the mutant survives, is the exact
shape of a guard that passes for the wrong reason** -- and it is only visible
because the mutant was run after the check was added, rather than the check
being assumed to work.

## 6. Measured and REJECTED -- do not retry

- **An index-comparison collect (`got_i < req_i`) for the two-edge read.** It
  cannot express a two-cycle lag once the request index saturates at WPB, and
  it silently drops the last word of every beat. Use the valid shift register.
- **Decomposing the flat address in the integration mux.** Rejected in favour
  of the DMA emitting `(head, col, grp)`: it puts the arithmetic where all
  three modules agree instead of in the one place nothing tests.
- **A slave with a single outstanding AW.** It is not a simplification, it is
  a different bus, and it reports the master as broken.

## 7. Measurement traps hit

- **Five of nine defects were in the test equipment, and every one looked like
  a design defect.** Zeros, X's, a one-beat shift, a WLAST violation: each is a
  plausible DMA bug and none of them was.
- **A check can be added for a specific mutant and still not kill it.** See B5.
  The only way to know is to re-run the mutant after adding the check.
- **The parameter sweep found two defects the default geometry could not.**
  D3 and D4 both pass at `AXI_DW = 128, VH = 2` and both fail elsewhere. A
  single-geometry bench would have shipped them.
- **`BURSTS : positive` refusing a bad geometry gave "bound check failure at
  line 155" with no name.** Changed to `natural` with a NAMED refusal
  (`bad_fewer_beats_than_one_burst`) beside the others, because the diagnostic
  is the whole point of that idiom.

## 7b. The wrapper, and the property that actually matters

`rtl/gdn_state_store.vhd` composes the store, the mover and the arbiter so
that whoever drives `gdn_block` instantiates ONE thing. The arbiter is a plain
2:1 with **no arithmetic in it** -- that is the whole reason the DMA emits
`(head, col, grp)` rather than a flat index (defect D1).

`sim/tb_gdn_state_store.vhd` tests the thing neither component bench can:
**that a layer's recurrent state survives being evicted by every other layer,
across tokens.** It runs tokens rather than transfers. Token 0 writes a value
that is a function of `(layer, token)` through the UNIT's port. Token 1 reads
back what token 0 left, checks it, and writes its own. Token 2 checks token 1.

```
tb_gdn_state_store RESULT: PASS -- 536 checks; every layer's state survived
3 evictions per token across 3 tokens.
```

Mutations, all three bite:

| mutant | verdict |
|---|---|
| S1 the arbiter passes the unit's read port through while the mover owns it | FAIL 512, "lost its state" |
| S2 the layer index dropped on the way to the mover | FAIL 512, "lost its state" |
| S3 `save_start` never reaches the mover | KILLED, "never asserted `done`" |

**A store that merely moves bytes correctly does not pass this by accident,
and a design that kept all 24 layers on-chip would pass it trivially --
which is exactly the design that does not fit.**

## 7c. MEASURED: the parts do NOT sum, and the census disagrees with the table

Composed OOC census of `gdn_state_store` at the shipping geometry, BC-250
lane, 5.0 ns, `STYLE = "ultra"`:

| | mover alone | store alone | **composed** | sum of parts |
|---|---:|---:|---:|---:|
| CLB LUTs (sites) | 269 | ~0 | **497** | 269 |
| CLB Registers | 703 | 3 | **708** | 706 |
| URAM288 | 0 | 32 | **32** | 32 |
| DSP48E2 | 1 | 0 | **1** | 1 |
| WNS at 5.0 ns | +2.670 | +2.549 | **+1.400** | -- |

**The arbiter costs about +228 LUT and 1.15 ns of slack, and neither is
visible in either component.** This is the assumption this project keeps
getting burned by -- that separately-measured units sum -- being tested and
coming back NO. It is small in absolute terms (0.11% of the device, and
+1.400 ns is still comfortable at 5.0 ns) but it is not zero, and a budget
built from the two component numbers would have been 228 LUT short. The cost
is the 2:1 mux itself: at `RECUR_LANES = 4` the data path alone is 64 bits
each way, plus head, col and grp on both ports.

**THE TWO MEASUREMENT METHODS DISAGREE AND BOTH ARE RIGHT.** The object census
`get_cells -hier -filter {REF_NAME =~ LUT*}` reports **548**;
`report_utilization`'s `CLB LUTs` row reports **497**. They are not measuring
the same thing: the census counts LUT PRIMITIVES, the table counts LUT SITES,
and two small LUTs can share one site. This repository's rule is "when they
disagree the census wins" -- that rule is about a census versus a *resource*
claim, and it does not apply here, because neither number is wrong.

**The device budget is the SITE count**, since sites are what the composition
competes for, so **497 is the number to carry** and 548 is the primitive
count. The earlier per-module figures in this document (269 LUT for the mover)
are also site counts, taken from the same table, so they are directly
comparable. Quoting 548 against them would have overstated the composition by
10%.

## 7d. Generalised over word shape, so ONE mover can carry the exponents too

The per-layer state EXPONENTS are `VAL_HEADS x DIM` bytes -- 4,096 at the 9B
shape, exactly `gdn_state_exp_bytes_per_layer` in the manifest. Moving them
needs a different word width (8 bits, not `RECUR_LANES*16`) and no group
dimension.

**The obvious options were both bad.** A second copy of this module duplicates
~250 lines of AXI logic. A second *instance* of it would need a second pair of
HBM masters, and **master count is a real constraint on this card** -- spending
a read and a write master on 4 KB per layer is the wrong trade when a mux costs
a few LUTs.

So `WORD_BITS` and `N_GRP` were added as generics **defaulted to exactly what
the module already computed**:

```vhdl
WORD_BITS : positive := RECUR_LANES * 16;
N_GRP     : positive := DIM / RECUR_LANES;
```

mantissas keep the defaults; exponents will pass `WORD_BITS => 8, N_GRP => 1`,
whereupon `WORDS = 32*128*1 = 4096` bytes and the existing
`bad_mant_bytes_vs_shape` refusal checks that against the arena figure it is
handed. Each instance derives its own beats, bursts and byte count.

**A defaulted generic that reproduces the previous behaviour exactly is what
makes this safe to add to a module that already has a passing bench: if the
bench still passes UNCHANGED, the generalisation is behaviour-preserving.** It
does -- 393 checks, 0 bad, the same bench with no edits -- and a narrower-word
geometry (`RECUR_LANES = 1`, so `WORD_BITS = 16, N_GRP = 8`) also passes at 777
checks. The composed `tb_gdn_state_store` is unchanged and still passes at 536.

**AND THE SYNTHESIS IS BYTE-IDENTICAL.** Re-running the composed OOC census
on the BC-250 after the generalisation, same script, same generics:

```
before:  CENSUS gdn_state_store LUT=548 FF=708 URAM288=32 DSP=1 WNS=1.400
after:   CENSUS gdn_state_store LUT=548 FF=708 URAM288=32 DSP=1 WNS=1.400
```

Every column matches. That is a same-session control on the refactor and it
also settles the one thing worth checking about the mechanism: **Vivado accepts
a generic whose default is an expression over an earlier generic in the same
list.** It is legal VHDL, but "legal" and "the synthesiser does what you meant"
are different claims in this project, and only one of them had been checked.

**NOT YET DONE, and the module does not pretend otherwise:** nothing
instantiates it at the exponent shape. That needs an 8-bit store, a sequencer
in `gdn_state_store` to run mantissa then exponent phases, and a mux sharing
the one master pair between them.

## 7e. The exponent store, and a census method that was wrong by 4.5x

`rtl/gdn_exp_mem.vhd` holds one layer's state exponents: `VAL_HEADS x DIM`
entries of 8 bits, 4,096 bytes at the 9B shape, exactly
`gdn_state_exp_bytes_per_layer` in the arena.

**IT CANNOT BE BRAM OR URAM AND THAT IS NOT A PREFERENCE.**
`rtl/gdn_block.vhd:317` labels the port "state exponent table, COMBINATIONAL
read", drives the address combinationally from the recurrence pipeline
(:632-633) and consumes `se_rdata` on the SAME edge (:1203). Block RAM and
URAM both have registered reads. This is the `region_mem` lesson again -- one
combinational read port turned that store into 91,073 LUT and zero BRAM, and
the array's shape was never the cause.

`sim/tb_gdn_exp_mem.vhd` checks the read **without advancing time**: the
address is driven, the bench waits two deltas, and the data must already be
right. A registered read cannot pass that. 97 checks, 32 of them
combinational, and all three mutations bite:

| mutant | verdict |
|---|---|
| E1 the unit read made registered | FAIL 31, "combinational unit read" |
| E2 the address transposed | FAIL 30 |
| E3 the two write ports' priority swapped | FAIL 1, "did not win a simultaneous" |

### MEASURED, and the two methods disagree by 4.5x this time

| | object census | `report_utilization` |
|---|---:|---:|
| LUT | **550** | **2,466** (`CLB LUTs`) |
| of which logic | 550 | 546 |
| of which memory | 384 `RAM64M8` | **1,920** |
| FF / BRAM / URAM | 0 / 0 / 0 | 0 / 0 / 0 |
| WNS at 5.0 ns | +3.450 | -- |

**`get_cells -hier -filter {REF_NAME =~ LUT*}` DOES NOT SEE DISTRIBUTED RAM AT
ALL.** It counted 550 logic LUTs and missed the memory entirely. The separate
`RAM64M8` count was 384 -- correct as a primitive count, and useless as a
budget number, because **each RAM64M8 occupies FIVE LUT sites**
(1,920 / 384 = 5).

So the honest cost of this 4 KB table is **2,466 LUT sites, not 550**. Still
negligible against 439,680 (0.56%), but the method was wrong by 4.5x and would
have been wrong by 4.5x on anything larger.

**This is the third census-method defect found today and the worst.** The
earlier two were a filter returning literal zero, and a 10% primitive-versus-
site gap on ordinary logic. The rule that survives all three: **`CLB LUTs`
from `report_utilization` is the budget number; an object census is for
answering "which primitive did I get", not "what does it cost".** The two
answer different questions and only one of them is the device budget.

The per-module figures elsewhere in this document (269 for the mover, 497 for
the composed store) are `report_utilization` site counts and are therefore
sound; none of those designs contains distributed RAM.

### The attribute earns nothing here, unlike the URAM case

`STYLE = "distributed"` and `STYLE = "auto"` give **byte-identical** results:
550 / 384 / +3.450 both ways. Vivado infers distributed RAM unaided from a
combinational read, because there is nothing else it could infer. That is the
exact opposite of `gdn_state_mem`, where `auto` gave 228 BRAM and the `ultra`
attribute was the difference between fitting and not. **Two stores in the same
subsystem, opposite answers on whether the attribute matters, and neither is
guessable from the other.**

## 8. Open, not yet answered

- **The exponents.** `gdn_state_exp_bytes_per_layer = 4096` is reserved in the
  arena and this module does NOT move it. `semem` in `llama_top` is the
  corresponding store. Named, not built.
- **The conv tap history.** No arena reservation and no mover. 49,152 B per
  layer.
- ~~Area and timing.~~ **MEASURED, BC-250 lane, shipping geometry**
  (VAL_HEADS 32, DIM 128, RECUR_LANES 4, LAYERS 24, LAYER_STRIDE 1,052,672,
  MANT_BYTES 1,048,576, AXI_DW 256, MAXB 16, MAXOUT 4), 5.0 ns:

  | | |
  |---|---:|
  | CLB LUTs | **269** (0.06%) |
  | CLB Registers | **703** (0.08%) |
  | DSP48E2 | **1** |
  | CARRY8 | 18 |
  | BRAM / URAM | 0 / 0 |
  | WNS | **+2.670 ns**, 434 MHz |

  The mover is free next to the store it feeds (32 URAM288). **The single DSP
  is `layer * LAYER_STRIDE`**, a multiply by a constant that a shift-and-add
  would remove if a DSP is ever the binding resource -- it is not today, at
  2,177 of 2,880 used by the composition, but the composition is DSP-bound and
  this is worth knowing.

  **The census script reported `LUT=0 FF=0` for this run and that was a FILTER
  BUG, not a measurement.** `get_cells -hier -filter {PRIMITIVE_GROUP == LUT}`
  and `== FLOP_LATCH` both return 0 in this Vivado, on a design whose own
  `report_utilization` said 269 and 703 in the same run. Fixed to `REF_NAME =~
  LUT*` / `FD*`. **A census that reports zero looks like a tiny module rather
  than like a broken filter**, which is the worst way for a measurement to
  fail, and it is exactly why this project's rule is to cross-check the census
  against `report_utilization` rather than to trust either alone. The same
  script also counted `REF_NAME =~ RAM*` as LUT-as-memory, which matches
  `RAMB36E2` and reported the BRAM total twice under two names.
- **The 50-cycle HBM read latency** used to derive the 31-vs-127 tok/s
  outstanding-burst argument is an ESTIMATE and has never been measured on this
  card. The ratio is what the argument rests on, not the figure.
- **Nothing has connected this to `gdn_block`.** The mux between the DMA's
  store ports and the unit's `st_*` ports is described and not written.
