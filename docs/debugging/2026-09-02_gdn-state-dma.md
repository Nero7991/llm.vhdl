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

## 7f. The exponent phase, sequenced through the ONE pair of masters

**The question.** The mover was generalised over word shape in 7d so that one
module could carry the state exponents as well as the mantissas, and 7e built
the 8-bit store they land in -- but nothing instantiated the mover at that
shape. Can both phases share one pair of HBM masters, and what does the whole
tier then cost?

**The answer, up front.** Yes. `gdn_state_store` now holds two instances of
`gdn_state_axi` -- one at `WORD_BITS => RECUR_LANES*16, N_GRP => DIM/LANES`
and one at `WORD_BITS => 8, N_GRP => 1` -- a four-state sequencer that runs
them in turn, and a 2:1 on the masters selected by a `sel_e` held for a whole
phase. One `load_start` moves 1,052,672 bytes in two transfers and pulses
`done` once. MEASURED, shipping shape, `xcvu33p`, 5.0 ns:

| | | device |
|---|---:|---:|
| CLB LUTs | **3,310** | 0.75% |
| -- LUT as logic | 1,390 | |
| -- LUT as memory | 1,920 | 0.93% |
| CLB Registers | **1,355** | 0.15% |
| URAM288 | **32** | 10.00% |
| Block RAM Tile | **0** | 0.00% |
| DSP48E2 | **2** | 0.07% |
| CARRY8 / F7 / F8 | 30 / 224 / 96 | |
| WNS | **+1.400 ns**, 278 MHz | |

**The parts sum to 2,963 and the composition is 3,310**, so the second mover,
the sequencer and the two AXI muxes cost **347 CLB LUT, +11.7%** over the naive
sum of the mantissa-only store (497) and the standalone exponent store (2,466).
That is the number the composed draw exists to produce: it is neither free, as
a reader might assume from "it is the same module again", nor full price, which
would have been another 269.

**The two DSPs are the two `layer * LAYER_STRIDE` multiplies**, one per mover
instance -- the same constant multiply flagged in section 8 as removable by a
shift-and-add if DSP ever binds. It now costs two.

### The procedure

1. `tb_gdn_exp_mem` extended with a check that DISCRIMINATES on the mover
   port's latency, then mutated.
2. `tb_gdn_state_store` re-shaped so the exponent phase is more than one burst,
   and extended to move exponents through the unit's `se_*` ports on every
   token alongside the mantissas.
3. Eight mutants, each run against the full bench AND against the bench with
   the exponent checks removed -- the attribution control.
4. One composed OOC synthesis for the census above.

### The design defect: the mover's read of the exponent store must be REGISTERED

`gdn_state_axi` issues an address, registers it, and collects the word TWO
edges later, because `gdn_state_mem` is a block or ultra RAM with a registered
read. `gdn_exp_mem` is distributed RAM and its unit-facing read is
ASYNCHRONOUS by requirement -- `gdn_block` consumes an exponent on the same
edge it drives the address. Handing that asynchronous port to the mover
presents each byte one edge EARLY, and since the mover walks a new address
every cycle, the byte it collects is the NEXT one: every saved exponent block
shifted by one, wrapping at the beat.

The fix is 8 flip-flops on the mover port only. The unit port is untouched, so
the array keeps one style and one behaviour.

**This is defect D2 from section 5 recurring on a second port**, which is the
argument for writing it down rather than fixing it quietly: the two-edge rule
is a property of the MOVER, and it is now been violated once by each memory it
has been connected to.

### The bench defect: 767 of 768 wrong, and the cause was in neither module

The first run of the extended store bench failed 511 of 512 exponent checks,
every one shifted by exactly one entry. That is the exact signature of the
latency defect above, which had already been fixed -- so the obvious reading
was that the fix was wrong or incomplete.

**PROBE A settled it in one run.** A loop inserted between the unit's writes
and the `save_start` pulse, reading the exponents straight back through the
unit port with NO DMA in between: 767 of 768 mismatched. The mover had not run
yet. The defect was on the unit's own read path.

The cause was a relay inside the DUT. `se_rdata <= ex_r_data`, with
`ex_r_data` driven by the memory instance, is free in hardware and is NOT free
in a bench: it inserts a delta cycle, and the bench checked the combinational
read after a fixed `wait for 0 ns; wait for 0 ns;`. Two deltas were enough
before the relay existed and one short after it.

Two things changed, and both are the lesson:

- **The DUT drives `se_rdata` directly from the instance.** A relay signal
  that exists only to be renamed is a delta with no purpose.
- **The bench no longer counts deltas.** `unit_eread` positions itself at a
  FALLING edge, drives the address, and waits a real 1 ns -- half a clock
  period, so no rising edge can occur and the read is still proven
  combinational, but the check survives any amount of internal rewiring. **A
  fixed delta count encodes a private detail of the DUT's wiring in the
  bench**, and when that detail changes the bench reports a data error in the
  wrong module. It cost an hour, and every minute of it was spent reading the
  mover.

### The mutation table, WITH the attribution control

Every mutant was run twice: against the bench as it now stands, and against
the same bench with the exponent write, read and check loops removed -- i.e.
against what the bench was before this work. The control column is what stops
the new checks being credited with kills that already belonged to something
else.

| # | mutation | full bench | control (no exponent checks) | credit |
|---|---|---|---|---|
| e1 | `gdn_exp_mem` mover read made asynchronous again | **FAIL 448/4632** | PASS 4120 | **new** |
| s1 | `sel_e` never asserted: the exponent mover never gets the bus | **FAIL, `done` never asserted** | dies in the mover | pre-existing |
| s2 | exponent phase skipped, `Q_MANT -> Q_DONE` | **FAIL 512/4632** | PASS 4120 | **new** |
| s3 | `exp_base = state_base`: exponents written over the mantissas | **FAIL 128/4632** | FAIL 128/4120 | pre-existing |
| s4 | load and save swapped for the exponent phase only | **FAIL 509/4632** | PASS 4120 | **new** |
| s5 | the idle mover's `arready`/`rvalid` broadcast instead of forced low | PASS | PASS | **NO BITE** |
| s6 | the unit's exponent write no longer gated by `busy` | PASS | PASS | **NO BITE** |
| s7 | `done` reported after the mantissa phase, exponents still in flight | **dies: `outst` underflow in the mover** | dies | pre-existing |

**Three of the six kills belong to the new checks and three do not.** Without
the control this table would have claimed six, and s3 in particular reads like
an exponent bug while being caught by the MANTISSA checks -- writing the
exponents at the layer base corrupts 128 mantissa words, and the exponent
checks then pass because the exponents themselves round-trip correctly to the
wrong address.

**s5 and s6 do not bite, and they are reported under their own names because
that is the honest resolution floor of this bench.** Both are defensive:

- **s5** forces the idle mover's ready and valid inputs low. It is
  unobservable here because an idle `gdn_state_axi` holds `arvalid` low, so
  broadcasting a ready to it changes nothing. The gating is kept anyway: a
  design that is correct only because of what another module happens not to do
  is the shape of bug this project keeps paying for. But it is UNTESTED, and
  no mutation of this bench can test it.
- **s6** removes the `and not bsy` from the unit's exponent write. The bench
  never violates the ownership rule, so there is nothing to suppress. The
  sim-only `guard` process is what would catch a caller that did, and the guard
  reads the RAW `se_wen` port rather than the gated copy precisely so that
  gating the write does not also silence the report. Neither is exercised.

### Two refusals that only this file can make

`bad_exp_bytes_vs_shape` and `bad_stride_below_mant_plus_exp` live in
`gdn_state_store`, not in the mover. **Each mover checks its own byte count
against `LAYER_STRIDE` and neither can see the other**, so nothing inside them
would notice the mantissa and exponent regions OVERLAPPING inside one layer.
This is the only place both figures are visible at once. The third,
`bad_mant_bytes_not_beat_aligned`, is true at the shipping shape as a
consequence of the mantissa geometry -- and a check that holds by consequence
is not a check, so it is stated independently.

### A measurement trap, in the control itself

The control build prints `PASS -- 4120 checks, of which 0 exponents; every
layer's mantissas AND exponents survived ...`. That sentence is false in the
control, and it is false because the control is the bench with its
`assert n_exp > 0` removed. In the shipping bench that assertion is what stops
a run that moved no exponents from claiming it did. **The control is a
deliberately weakened bench and its PASS line should not be quoted as
evidence about anything except the mutants.**

## 8. Open, not yet answered

- ~~**The exponents.**~~ **DONE, see section 7f.** `gdn_state_store` runs a
  second `gdn_state_axi` at `WORD_BITS => 8, N_GRP => 1` after the mantissa
  phase, over the same pair of masters. 4,632 checks in
  `tb_gdn_state_store`, of which 512 are exponents.
- **The conv tap history.** ~~No arena reservation and no mover.~~ 49,152 B per
  layer. **RESERVED 2026-09-02** inside `gdn_state_bytes_per_layer` -- derived
  by `hbm_map.arena_sizes()` from `conv_kernel`, the
  `qkv_dim = 2*key_dim + val_dim` identity, and the element width scraped off
  `gdn_block`'s `cv_x` port; the stride went 1,052,672 -> 1,101,824. **The
  on-chip store is built and measured** (`rtl/gdn_conv_tap_mem.vhd`, 12 RAMB36
  / 317 CLB LUT, four versions and three different failed BRAM inferences --
  `docs/debugging/2026-09-02_conv-tap-history.md`). **STILL NO MOVER**: nothing
  instantiates `gdn_state_axi` at `WORD_BITS => 16, N_GRP => 1`, nothing feeds
  the tap write port from A's qkv, and nothing pulses `tok_adv`.
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
- **Nothing has connected this to `gdn_block`.** The mux between the movers'
  store ports and the unit's `st_*` and `se_*` ports IS written and measured
  (`gdn_state_store`, 3,310 CLB LUT), but no instance of `gdn_block` is wired
  to it and no sequencer issues `load_start`/`save_start` per layer. That job
  sequencer is the next piece, and until it exists the tier is verified and
  unused.
- **`s5` and `s6` are untestable by this bench** (section 7f). The AXI input
  gating and the busy-gate on the unit's exponent write are both defensive and
  neither has ever been shown to discriminate.
