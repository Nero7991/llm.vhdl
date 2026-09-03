# The GDN recurrent state does not fit on this device, and that changes what the B data mover is

**Date:** 2026-09-02
**Part:** `xcvu33p-fsvh2104-2L-e` (SQRL FK33), 8 GiB HBM
**Model:** Qwen3.5-9B, `NCARDS = 1`
**Raised by:** sizing `rtl/llama_top.vhd`'s `gb_real` block before porting it into
the card composition.

---

## 1. The question, verbatim

Before extracting `llama_top`'s `gb_real` block (635 lines) into a reusable
entity for the card top, I asked what its five memories cost at the real 9B
shape. Specifically: **can `stmem`, the Gated DeltaNet recurrent state, be an
on-chip memory on this part?**

The plan of record (`docs/PLAN_TO_FIRST_INFERENCE.md`, and my own note at the
end of the previous session) said the remaining work for B was "port the ~635
lines of `gb_real`". That framing assumed the answer was yes.

## 2. The answer

**No, and not by a small margin. The full-depth recurrent state is 24.0 MB
against 14.2 MB of BRAM plus URAM on the entire device: it overruns every
on-chip memory the part has, by 1.69x, with nothing left for anything else.**

So the B data mover is **not** a port of `gb_real`. `gb_real`'s `stmem` is a
process variable holding all 24 GDN layers at once, which is a legitimate
simulation model and cannot become hardware. The card needs a **state
streaming tier that does not exist in this repository**: one layer resident
on-chip, moved to and from HBM per job.

**One layer is 1.0 MB and fits comfortably: 29 URAM288 of the 320 idle ones,
or 228 BRAM36 of 672.** URAM is legal for this store, unlike the norm gain
image, because it is written at run time and needs no initialisation (see
"measurement traps" below).

## 3. The procedure

Sizes were not hand-derived. The repository's own shape functions were
elaborated by GHDL against the shipping model config, so the numbers come from
the same source the RTL uses.

```
ghdl -a --std=08 rtl/model_cfg_pkg.vhd rtl/llama_map_pkg.vhd sz.vhd
ghdl -r --std=08 sz
```

where `sz.vhd` computes `mk_shape(QWEN35_9B, 1)` and reports each memory's
extent. What each line isolates:

1. **the shape** -- confirms `NLY`, `VH`, `DM`, `KC`, `QKVN` come from
   `mk_shape` and not from a hardcoded guess.
2. **`stmem` per layer** -- the quantity a per-layer streaming design has to
   hold on-chip.
3. **`stmem` all layers** -- the quantity `gb_real` holds today.
4. **`semem` and the conv history** -- the other two per-layer stores, to see
   whether they change the conclusion. They do not.
5. **the device totals** -- BRAM and URAM in the same units, as the control.

## 4. The evidence

Raw GHDL output, 2026-09-02:

```
9B shape: blocks=32 KH=16 VH=32 DM=128 KC=4 NLY=24 QKVN=8192
stmem: words/layer=131072 word_bits=64 bits/layer=8388608 MB/layer=1.0
stmem ALL LAYERS: bits=8388608 x 24 MB=2.4e1
semem ALL LAYERS bits=786432 MB=9.375e-2
conv history (KC-1)*QKVN*16 per layer bits=393216  ALL LAYERS MB=1.125
DEVICE: BRAM 672 tiles x 36864 bits = 2.953125 MB;  URAM 320 x 294912 bits = 1.125e1 MB
```

Tabulated, all MEASURED except the final column which is DERIVED arithmetic on
the two preceding ones:

| store | bits | MB | fits on-chip? |
|---|---:|---:|---|
| `stmem`, all 24 layers | 201,326,592 | 24.000 | **no** |
| `stmem`, ONE layer | 8,388,608 | 1.000 | yes, 29 URAM288 |
| `semem`, all layers | 786,432 | 0.094 | yes |
| conv history, all layers | 9,437,184 | 1.125 | yes |
| **device BRAM total** | 24,772,608 | 2.953 | -- |
| **device URAM total** | 94,371,840 | 11.250 | -- |
| **device BRAM + URAM** | 119,144,448 | 14.203 | -- |

**Cross-check, and it is an independent one.** `rtl/llama_top.vhd`'s own
declaration comment on `stmem` states the extent as
`24*32*128*128*16 = 201,326,592`. That figure was written for a different
purpose -- explaining why the array had to become a process variable to stop
`ghdl-mcode` dying at 24.9 GB -- and it agrees exactly with the number measured
here. Two independent derivations, one of them predating the question.

**The lane count cannot be tuned out of this.** `stmem` is
`NLY*VH*DM*NBR` words of `B_RECUR_LANES*16` bits, and `NBR = DM/B_RECUR_LANES`,
so the product is `NLY*VH*DM*DM*16` bits with the lane term cancelled. The
file says so itself: *"the lane count cancels, so no generic can shrink it."*
Confirmed by inspection, not assumed.

## 5. What this means for the B data mover

The shape of the work changes, and it grows.

**What a port would have given.** `gb_real` reads its five memories through
plain array indices with one-cycle registered reads. `gdn_block`'s `st_rdata`
contract is a registered read one cycle after the address, so HBM latency
cannot serve that port directly under any arrangement.

**What is actually needed**, per GDN job (there are 24 per token):

1. **load** layer L's recurrent state, 1.0 MB, HBM to on-chip URAM;
2. **load** layer L's conv tap history, 48 KB, and its state exponents, 4 KB;
3. run `gdn_block` against the on-chip copies, which is what `gb_real` already
   does correctly;
4. **store** the updated state and history back to HBM.

DERIVED traffic: `24 x 2 x (1.0 + 0.047 + 0.004) MB = 50.4 MB per token`, read
plus write. That is not a throughput concern at HBM bandwidth, but it is a new
AXI master, a new DMA sequencer, and a new set of seam rules.

**There is a precedent in this repository and it should be followed rather
than reinvented: `rtl/attn_kv_axi.vhd`.** Subsystem C's KV cache is exactly
this problem already solved -- an on-chip working set in front of an HBM-backed
store, with its own AXI3 master, selected by `C_KV_AXI`. Its generic list
(`AXI_DW = 256`, `ADDR_W = 33`, `MAXB = 16` with the AXI3 `ARLEN` cap called
out by name, `MAXOUT`, `RBUF`) is the template for a `gdn_state_axi`.

**A second, independent piece of new RTL is required regardless of the fit
question: the conv tap history.** `llama_top` holds none. Its own code refuses
rather than pretending:

> `assert not (B_SRC_REAL and tok_pos > 0) ... this file holds no conv tap
> HISTORY -- every tap but the newest is zero (cvdata_p). From token 1
> gdn_exp_capture's tvalid marks those slots VALID, so the conv would sum zeros
> at a real exponent. Refusing rather than producing a plausible wrong number.`

So `B_SRC_REAL` -- the mode the card must run in -- **has never executed past
token 0 anywhere**, and the buffer that would let it is unwritten. That is
1.125 MB across layers, 48 KB resident.

## 5b. MEASURED: what one layer actually costs, and the attribute is load-bearing

Added after the write-up's first version, from an OOC census on the BC-250
lane (`sim/ooc_gdn_state.tcl` against `rtl/gdn_state_mem.vhd`,
`xcvu33p-fsvh2104-2L-e`, 5.0 ns). Predictions were pre-registered in the
script's header BEFORE the run, and one of them was wrong.

```
CENSUS STYLE=ultra URAM288=32 RAMB36=0 RAMB18=0 WNS=2.549 FMAX=408.0
CENSUS STYLE=block URAM288=0 RAMB36=228 RAMB18=0 WNS=(not measured, see below)
CENSUS STYLE=auto  URAM288=0 RAMB36=228 RAMB18=0 WNS=(not measured, see below)
```

| `ram_style` | URAM288 | RAMB36 | share of that resource |
|---|---:|---:|---|
| `"ultra"` | **32** | 0 | 10.0% of 320 URAM |
| `"block"` | 0 | **228** | 33.9% of 672 BRAM |
| `"auto"` (no attribute) | 0 | **228** | 33.9% of 672 BRAM |

**THE HEADLINE IS THE THIRD ROW: `auto` picks BRAM, not URAM.** Vivado does not
reach for URAM on its own, so without an explicit `ram_style = "ultra"` this
store silently costs **228 BRAM tiles**. Against the wired `compose4_top`'s
measured 327.5, that is 555.5 of 672 = 82.7% **before** the 171-tile norm gain
image, which would take it to 726.5 and over the device. With `ultra` it is
327.5 BRAM unchanged plus 32 of 320 idle URAM. **The attribute is not a
preference here, it is the difference between fitting and not.**

**Cross-checked against `report_utilization`, per this project's rule that the
census wins but must be corroborated:** `URAM | 32 | 320 | 10.00`,
`Block RAM Tile | 0`, plus a primitive line `URAM288 | 32 | BLOCKRAM`. The two
agree.

**My predictions, scored honestly.** `ultra = 32 URAM288` was **exact**, from
`4096 x 72` tiles cascading 32 deep with 64 of 72 bits used. `block = 256
RAMB36` was **wrong**; the answer is 228, which is the naive
`ceil(8,388,608 / 36,864)` bit-count I had explicitly predicted would be wrong.
So width quantisation bit the URAM case and did **not** bite the BRAM case, and
I had no way to tell which was which in advance. **The lesson is not that
bit-counts work; it is that neither rule is reliable and the census is the only
thing that settles it.** Two predictions, opposite methods, one right each.

## 5c. The new memory has an oracle, and three of the first four mutants survived

`sim/tb_gdn_state_mem.vhd` compares `gdn_state_mem` against an **independent
model** coded from `llama_top`'s `stmem_p` rather than from the DUT, because a
round trip is not an oracle and this repository has the `m7 mutant` on record
as the case that proves it.

**First version: 2,825 checks, 0 mismatches, and it was nearly worthless.**

| mutant | what it breaks | first bench | hardened bench |
|---|---|---|---|
| M1 | write ordered BEFORE read | **SURVIVED** | **SURVIVED** |
| M2 | read address transposed to `(col*VAL_HEADS + head)` | FAIL 2,645 | FAIL 3,926 |
| M3 | read not gated on `r_en` | **SURVIVED** | FAIL 1,460 |
| M4 | write not gated on `w_en` | **SURVIVED** | FAIL 1,952 |
| control | unmutated | PASS | PASS 4,323 checks |

**M1 SURVIVES AND SHOULD, AND FINDING OUT WHY CORRECTED THE RTL.** The header
of `gdn_state_mem.vhd` originally claimed the read-before-write statement order
was load-bearing, copied across from `llama_top` where it is. It is not, here:
`mem` is a SIGNAL, so the write does not take effect until the next delta and
the read sees the pre-edge value whichever order the two blocks are in.
Read-old is **structural** in this file and a **discipline** in `llama_top`,
and the rule does not transfer. 64 deliberate same-address same-edge collisions
do not move the result by one check. **The comment was corrected in the RTL;
the mutation is kept and reported under its own name because a mutation that
cannot bite is the measurement that establishes it.**

**M3 and M4 survived for two different and both embarrassing reasons.**
M3 (an unwanted read) was invisible because the comparison only looked at
cycles where the reference had also read -- **a read the reference never made
cannot be seen by only checking the cycles where it did.** M4 (an unwanted
write) was invisible because the stimulus let the write address and data HOLD
while `w_en` was low, so the extra write rewrote the same word with the same
data and was a no-op. **A stimulus that holds its inputs cannot see a missing
enable.**

**HOW BIG A SHAPE THE BENCH ACTUALLY REACHES, measured rather than assumed.**
The gate row runs the default small shape, so the reach was swept separately
under a `ulimit -v` cap so that a bench cannot threaten the box (a `ghdl-mcode`
run has OOM-killed this workstation before):

| VAL_HEADS | DIM | RECUR_LANES | words | 6 GB cap |
|---:|---:|---:|---:|---|
| 4 | 8 | 2 | 128 | PASS, 523 checks |
| 8 | 32 | 4 | 2,048 | PASS, 2,443 |
| 16 | 64 | 4 | 16,384 | PASS, 16,779 |
| 32 | 64 | 4 | 32,768 | PASS, 33,163 |
| **16** | **128** | **4** | **65,536** | **PASS, 65,931** |
| 32 | 128 | 4 | 131,072 (the real 9B store) | **died at an 8 GB cap** |

**So the bench is verified at exactly HALF the real depth, with `DIM` and
`RECUR_LANES` at their real values and only the head count halved.** The real
shape was NOT attempted at a larger cap, deliberately: a full gate was running
on the same box, and the remaining question at 131,072 words is a synthesis
question the census already answered, not a protocol question. `mem` is a
signal array, which is what makes GHDL expensive here and is also what makes
the memory inferable, so this ceiling is a property of the simulator and not of
the design. **Stated as a limit rather than papered over: no simulation in this
repository has exercised this memory at the 9B head count.**

**ATTRIBUTION CONTROL, run because "the kill" is not the same as "which change
earned it".** Two half-hardened benches: A = every-cycle comparison, no port
scrambling; B = port scrambling, comparison still gated.

| | bench A (compare only) | bench B (scramble only) | both |
|---|---|---|---|
| M3 | **FAIL 130** | PASS | FAIL 1,460 |
| M4 | PASS | **FAIL 1,325** | FAIL 1,952 |

**The two changes are orthogonal and each is necessary: neither alone catches
both, and neither is redundant.** Had only one been made, the bench would have
looked improved while still passing one of the two mutants.

## 5d. THE HBM SIDE IS ALREADY ALLOCATED, AND IT AGREES TO THE BYTE

Found after the sizing, and it changes the risk of the remaining work.
`tools/hbm_map.py::arena_sizes()` already derives a **GDN state arena** from
`rtl/model_cfg_pkg.vhd`, and `tools/pack_model_fk33.py` already reserves it in
the manifest at pack time:

```
gdn_layers                           24
gdn_state_mant_bytes_per_layer  1048576
gdn_state_exp_bytes_per_layer      4096
gdn_state_bytes_per_layer       1052672
gdn_state_bytes                25264128
```

**1,048,576 bytes per layer is 8,388,608 bits: the same figure this document
measured from the shape functions, to the byte.** 4,096 bytes of exponents per
layer is likewise exactly `VAL_HEADS * DIM` at 8 bits. So there are now **three
independent derivations of the same number** -- this write-up's GHDL probe,
`llama_top`'s own `stmem` declaration comment, and the packer's arena, which
was derived by a separate tool from the same RTL constants for a different
purpose.

**This is the good news in an otherwise expensive finding: the architecture was
always "the GDN state lives in HBM", the host tooling already reserves 24.09 MB
for it, and `server/fk33_manifest.c` already enforces
`gdn_state_base >= weights_end`. What is missing is only the RTL that moves
it.** The remaining work is a mover against an address map that exists, not a
new allocation.

**ONE GAP IN THAT ALLOCATION, and it is the conv history again.**
`gdn_state_bytes_per_layer` is `1,048,576 + 4,096` -- mantissas and exponents
only. The conv tap history is `(KCONV-1) * qkv_dim * 16 bits = 49,152 bytes per
layer`, **1.125 MB across 24 layers, and nothing reserves it.** Whoever builds
the mover has to add it to `hbm_map.arena_sizes()` rather than quietly placing
it, because this address space has already had one silent collision between two
allocators that could not see each other and the symptom was a wrong token.

## 6. Measured and REJECTED -- do not retry

- **URAM for an initialised table.** Not retried here, and recorded so it is
  not: `[Synth 8-10226]` on this device refuses `ram_style = ultra` on any ROM
  with non-zero initialisation and silently gives BRAM while reporting
  `uram=0`. That is why the norm gain image is charged in BRAM. **It does not
  apply to `stmem`,** which is written at run time and initialised to zero, so
  URAM is available to it. The two cases look alike and are not.
- **Shrinking `stmem` with `B_RECUR_LANES`.** Algebraically impossible, shown
  above: the lane term cancels. Do not sweep it hoping for a fit.
- **Holding all layers in BRAM by dropping the gain image.** The gain image is
  171 tiles, worth 0.75 MB. Reclaiming all of it still leaves 24.0 MB wanted
  against 14.2 MB available. The deficit is not in that class.

## 7. Measurement traps hit

- **"Port the 635 lines" was a plan written from a line count, not from a
  sizing.** The line count is accurate and irrelevant. Nothing in `gb_real`'s
  text signals that one of its five arrays is 1.69x the whole device; the
  array is three lines long. **A data mover's cost is in what it moves, and
  that is not visible in its source.**
- **`gb_real`'s `stmem` comment describes a SIMULATION problem and reads like
  a solved one.** It explains at length why the array had to be a process
  variable rather than a signal, with a measured 46 GB against 206 MB. That
  discussion is about `ghdl-mcode`'s cost per scalar and settles nothing about
  hardware; having read a long, careful, correct note about the array, it is
  easy to come away believing the array itself had been dealt with.
- **I nearly used my own arithmetic.** The numbers above came from elaborating
  the repository's shape functions instead, which is what caught that `NLY` is
  24 and not 32 -- attention blocks are not GDN blocks, and `n_gdn_blocks`
  subtracts them.
- **A FAILED REGEX PRODUCED A NUMBER, NOT AN ERROR, AND IT REACHED THE CSV.**
  `sim/ooc_gdn_state.tcl` initialises `wns` to `0.0` and overwrites it only if
  a `regexp` matches `report_timing_summary`'s output. It matched for `ultra`
  (a real +2.549) and did NOT match for `block` or `auto`, so those two rows
  carry `wns 0.0, fmax 200.0` -- **the script's default wearing the shape of a
  measurement**, sitting in the same column as a real one. Only the `ultra`
  timing figure in this document is measured; the other two are **unmeasured**
  and must not be quoted. Same failure shape as `wait_on_run -timeout` and the
  completion signal that also fires on failure: the harness reported that it
  finished, not what it found.
- **Two columns of that census are filter bugs and are not reported here.**
  `REF_NAME =~ RAM*` was meant to count LUT-as-memory and also matches
  `RAMB36E2`, so the `block` row's "LUTasRAM=228" is the same 228 BRAMs counted
  twice under two names. `PRIMITIVE_GROUP == LUT` and `== FLOP_LATCH` both
  returned 0 while `report_utilization` showed `FDRE | 3` in the same run. The
  URAM and RAMB columns are corroborated by the utilization table; the LUT, FF
  and LUTasRAM columns are not, and were discarded rather than reported.

## 8. Open, not yet answered

- ~~Whether one layer's state should be URAM or BRAM.~~ **ANSWERED, see 5b:
  32 URAM288 with `ram_style = "ultra"`, against 228 BRAM without it. The
  default is the expensive one.**
- The `block` and `auto` timing figures. The census script's regex did not
  match on those two runs, so their WNS is unmeasured, not 0.0.
- **Whether URAM288 preserves read-old on a same-address, same-edge
  collision.** GHDL says read-old, but only because `mem` is a signal (5c);
  that is a simulation semantic and says nothing about the primitive. BRAM has
  a selectable collision mode and URAM's read-during-write behaviour is not
  BRAM's. If `gdn_block` ever reads and writes one state word on one edge,
  this has to be settled against the primitive. **Not checked.**
- Whether `gdn_block` in fact ever issues `st_ren` and `st_wen` to the same
  address on the same edge. **Looked at, NOT settled.** The read is driven from
  a `(vh, col, grp)` walk in `P_COL` (`rtl/gdn_block.vhd:1157-1174`) and the
  write from a separate `(wh, wc, wg)` walk advanced by `rp_ovalid` (:889-905).
  Both walk the same address space in the same nesting order and the write
  trails the read by the recurrence pipeline's latency, so within one pass they
  cannot coincide. What is NOT established is whether a second pass's reads can
  catch a first pass's outstanding writes at the wrap. That needs either an
  FSM argument or a counter in a bench, and neither exists. **Do not record
  this as safe on the strength of the within-a-pass argument alone.**
- Whether the load and store can overlap the compute, or whether the job
  serialises as load-run-store. Affects tokens per second, not fit.
- Where in HBM the state lives, and whether it collides with the weight image
  already resident and verified.
- Whether `attn_kv_axi` can be parameterised to serve both, or whether B needs
  its own master. Not investigated.
