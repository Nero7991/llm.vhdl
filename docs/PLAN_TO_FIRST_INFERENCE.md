# Plan: what remains between here and 9B inference on the card

**Written 2026-08-30 for a second harness.** Every figure is MEASURED unless
labelled. Where this document and the RTL disagree, the RTL wins.

Read `CLAUDE.md` first, then `docs/WORKLOG.md`. This file is the ordered plan;
the WORKLOG is the live board.

---

## 1. Where we actually are

**Proven on silicon, with an oracle:**

| result | evidence |
|---|---|
| Subsystem A computes correctly | 311 of 311 jobs, **1,675,264 result rows element-exact** against `ref/run9b`, `TOKEN card argmax 2614, reference 2614` |
| The HBM address map was the throughput bound, and it is fixed | **22.49 to 2.03 cycles/beat, 11.09x**, inside a pre-registered 1.60-3.0 band, `trips=0` on all 8 jobs |
| The card boots itself | `fk33_pcieep.mcs` in SPI flash; FPGA configures at power-on, trains inside the PERST window, BIOS enumerates `00:1d.0` unaided at `8GT/s x4 (ok)` |
| 9B weights are resident and correct | 4,487,442,432 B written and verified against a pack-time `blake2b_128` |
| Subsystem C closes 200 MHz standalone | `vref_r` min-fold reassociated: WNS **-3.122 to +0.825**, Fmax 123.1 to 239.5 MHz |

**The load-bearing caveat, in the token document's own words:**

> **This is the matvec skeleton of a token, not a token the card computed by
> itself.** The chain was re-anchored 32 times, once per layer, because
> subsystems B and C are not on this silicon.

**MEASURED: `hw/fk33/rtl/fk33_engine.vhd` instantiates `matvec_int4_desc_axi`
and nothing else.** There is no B, no C and no D on the card. The host is
currently doing every non-matvec step.

## 2. The gap, in one sentence

**A synthesisable, functionally wired card top carrying A+B+C+D does not exist,
and neither of the two candidates is one.**

- **`rtl/llama_top.vhd`** wires all four correctly and is the functional
  reference, but it is a SIMULATION top: `A_BEHAV`, `B_BEHAV`, `C_REAL`,
  `C_KV_AXI`, `NORM_REAL`, `B_SRC_REAL` all default FALSE, and its region
  scratch at `:1085` is a flat `buf_t(0 to NREGION*REGMAX-1)` with 16 access
  ports. At 9B that is **14 x 12288 x 16 = 2,752,512 bits**, which Vivado cannot
  infer as RAM, cannot dissolve, and **SEGFAULTS attempting** (`[Synth 8-3391]`,
  then SIGSEGV in `HOptDfg::dissolveRam`). MEASURED 2026-08-30.
- **`hw/fk33/rtl/compose4_top.vhd`** synthesises at the real shape and is
  placed/routed, but its own header says: **"THE SUBSYSTEMS ARE NOT WIRED TO
  EACH OTHER."** It is a fit vehicle, not a design.

Everything below is in service of closing that.

---

## 3. The critical path, ordered

### STEP 1 -- Land the two area levers. Both are measured; neither is composed.

Nothing else can proceed until the design plausibly fits.

**1a. `rmsnorm_rs_mem` (TRACK RMSMUX, `ce7b836`).** Built, verified, drawn
against its own same-session control on the BC-250:

| | `rmsnorm_rs` control | `rmsnorm_rs_mem` |
|---|---:|---:|
| CLB LUT | 40,934 | **4,825** |
| CLB FF | 67,196 | **1,629** |
| MUXF7 / MUXF8 | 17,408 / 8,704 | **0 / 0** |
| BRAM tile | 0 | 6 |
| WNS @ 5.0 ns | +1.675 | +0.971 |

Scatter is `1.0000x` (two identical-command draws byte-identical including
census hashes), so **SCATTER's 1.55x must NOT be applied to the 4,825**.

**Work: wire it into `llama_top` in place of the flat unit.** Not yet done.

**1b. The norm gain image to BRAM (TRACK NORMURAM, `c479ae8`).** Landed in
`llama_top`'s `gvr` generate: **89,970 to 67,318 LUT, 171 BRAM, WNS unchanged**,
two identical draws agreeing on the entire utilization report.

**Charge it in BRAM, not URAM.** `[Synth 8-10226]`: URAM on this device cannot
hold a table with non-zero initialisation, and the "114 URAM" three documents
carried was the **BRAM column** of a run whose URAM request was refused.
**171 BRAM is 25.45% of the device** and nobody is holding a BRAM budget.

**1c. Lever C, the IQ4_NL codebook to LUTRAM.** CONFIRMED VIABLE (TRACK CBINFER,
`0d24f7d`): Vivado does infer distributed RAM from `cb`'s array-of-array shape;
every copy becomes a `RAM32M16`, 8 LUTRAM per lane at all three geometries, MUXF7
-16/lane, MUXF8 -8/lane. The `ram_style` attribute **earns nothing** (attribution
control byte-identical with it deleted), so the two-sibling-architecture fallback
is not needed.

**NOT YET DRAWN at the FK33 geometry `ROWS_IF=48`** -- ROWS_IF=16 already peaked
at **14.38 GB** summed Vivado RSS on the BC-250's 14 GB, so 48 must run on the
workstation. Total saving is an **ESTIMATE of 36,000-39,000 LUT** (per-lane
saving falls with lane count: 29.11 / 27.71 / 26.05, and two models disagree);
**+13,200 FF is DERIVED and exact**.

**THE COMPOSITION OF 1a AND 1b IS NOT FREE.** TRACK NORMURAM's finding,
re-derived independently by RMSMUX: the gain loader's word stream is free in
ORDER and GRANULARITY but **not in RATE**. Today the margin is `GW = 4.0x` and
**shape-invariant**; composed onto the bank port it becomes `1 + 1/LANES` --
1.26x at the shipping `NORM_LANES = 4`, 1.07x at 16. Worse, the deadline moves
from `r_go` (which `gvr` sees and `wbusy` checks) to the unit's internal `S_RAW`
(which it cannot). **A bench at hidden 64 sees 1.79x where the build has 1.26x,
so a composed test that passes small is not evidence about the real shape.**

`tb_rmsnorm_rs_mem` loads both vectors before `start` and has **zero coverage of
the concurrent-load race**. That gap must be closed by whoever composes them.

**Done when:** a composed OOC draw at the real shape reports CLB, BRAM and WNS
together, with a same-session control, and the load-race is covered by a bench
at the real shape.

### STEP 1d -- BRAM MAY BIND BEFORE LUT. Added 2026-08-30 after the plan was written.

**Nobody has added BRAM up across the composition and the levers, and the sum
does not obviously fit.**

| term | tiles | source |
|---|---:|---|
| composed A+B+C+D | 246.5 of 672 | MEASURED, `hw/fk33/results/compose4_2026-08-29/util_c4_synth.rpt` |
| + norm gain image | 171 | MEASURED standalone, TRACK NORMURAM |
| + `rmsnorm_rs_mem` vectors | 6 | MEASURED standalone, TRACK RMSMUX |
| **needed** | **423.5** | DERIVED |
| **available inside `pb_core`** | **372.5** | MEASURED, see below |

`hw/fk33/results/build_e2e_2026-08-29/e2e_pblock_util_routed.rpt` shows `pb_core`
holds **576** Block RAM Tiles, of which **203.5 are "Non-Assigned"** -- shell
cells physically inside the region. `576 - 203.5 = 372.5` for our logic against
**423.5** needed: **short by about 51 tiles.** Device-wide it is 627 of 672,
93.3%, which is also uncomfortably tight.

**DERIVED, and its load-bearing assumption is that separately-measured units do
not share.** That is exactly the assumption this project keeps getting burned
by, so treat it as a hypothesis a composed draw can test, not a fact.
**Falsified by:** a composed draw reporting the total under 372.5.

**The gain image is the dominant term at 171 tiles, 45.9% of everything
available.** TRACK NORMURAM already named the fallback: *"171 BRAM is 25.45% of
the device -- a `GW = 2` point is the obvious next measurement if BRAM binds."*
That measurement has not been taken.

**Do not trade LUT for BRAM without stating the BRAM cost.** `rmsnorm_rs_mem`
converts a 40,934-LUT mux tree into 6 tiles, which is an excellent trade at 6
and a different question if BRAM is the binding resource.

### STEP 2 -- Answer whether it ROUTES. This is the real unknown.

**Fit by CLB count is not the same claim as builds, and only the first has
moved.** With RMSMUX measured and the squeeze-measured density (6.553, not the
free-die 5.617):

| configuration | CLB |
|---|---:|
| RMSMUX alone | 92.1% |
| lever C alone | 92.9% |
| **both** | **84.1%** |

**But the router already failed at a LOOSER density.** MEASURED: placed
occupancy 54,866 of 54,960 CLB (99.83%), congestion level 7, **33,767 failing
endpoints after placement**, 20,000 of the 20,000 worst net-dominated (mean net
4.575 ns against mean logic 0.670 ns), and Vivado said so unprompted:

```
[Route 35-447] Congestion is preventing the router from routing all nets.
iteration 1  69,858 -> 183,525 -> 111,513   (RISING -- the router is thrashing)
```

The pblock squeeze reached 84%-class density only by paying **0.602 ns of WNS**
(-3.056 to -3.658) on a design whose observed failure mode is congestion, not
area. **At 7.029 LUT/CLB there is less routing resource per cell, not more.**

**Done when:** `compose4_top` with both levers reaches `route_design` with 0
nets with routing errors and a reported WNS. **Anything short of that leaves
every schedule below unfalsifiable.**

**If it does not route**, the two-card split is already scoped and MEASURED
(TRACK TWOCARD): TP-small is **355,395 LUT = 56,233 CLB = 102.3%** per card, so
a naive split does not fit either; `gdn_recur_pipe` halved cleanly (27,910 to
17,114, DSP exactly halved) but `gdn_emit_chain` moved by **10 LUT** because its
lane count is a separate generic blocked on timing at `rtl/gdn_block.vhd:210`.
Aurora over the PCIe edge GTYs is the interconnect, and the PCB work is in
`~/GitHub/pcie-llm-hardware`.

### STEP 3 -- Build the card top (row N3). It does not exist.

**INHERITED DEADLINE, added 2026-08-30. MEASURED by TRACK RMSWIRE: there is a
1,030-cycle window `[977, 2006]` in which the norm unit reads the PREVIOUS
operation's gain vector -- up to 1,373 of 4,096 elements -- and EVERY OUTPUT WORD
IS BIT-IDENTICAL to the oracle.** `tb_llama_top`'s `EXP_*` landmarks are token
hashes and pass throughout it. The width is exactly
`S_EMIT arrival - S_RAW arrival = 2097 - 1067`.

**A value-based check cannot see this.** The card top MUST honour the deadline
structurally, and the only thing that makes it visible from outside the unit is
`rmsnorm_rs_mem`'s `w_active` output: first rise is `S_RAW`, rise-after-fall is
`S_EMIT`. **Wire it and assert on it.**

Neither candidate is usable, so this is new work, not a wiring change.

**It must:**
1. Instantiate the REAL units (`C_REAL`, `C_KV_AXI`, `NORM_REAL`, `B_SRC_REAL`
   true; `A_BEHAV`, `B_BEHAV` false) and bind `matvec_int4_desc_axi`, which is
   what the card's `fk33_engine` already uses and what takes 27 arbitrary
   descriptor-supplied bases.
2. **Replace `llama_top`'s flat region scratch.** The 16-port flat array is the
   thing that crashes elaboration and it is a simulation convenience. It needs a
   real memory with an arbiter. Note `llama_top:1079` already warns that D
   "issues at most one unit at a time -- `cur_unit` in `seq_desc_fetch` is a
   scalar -- so no second unit can be reading. **When D grows overlap, this
   becomes a real arbiter and this comment becomes wrong.**"
3. Preserve the numeric behaviour of `llama_top` exactly. **`llama_top` is the
   oracle**; a card top that computes differently is wrong even if it fits.

**Done when:** the card top elaborates in Vivado at the real 9B shape, and a
bench proves it token-identical to `llama_top` on the `ref/run9b` stream.

### STEP 3b -- B's RECURRENT STATE DOES NOT FIT ON-CHIP. Added 2026-09-02, and it enlarges STEP 3.

**This step was not in the plan and has to be, because STEP 3 point 1 requires
`B_SRC_REAL => true` and that mode cannot be built from what exists.**
Write-up: `docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md`.

**MEASURED** by elaborating this repository's own shape functions against
`QWEN35_9B` (GHDL, not hand arithmetic):

| store | MB | note |
|---|---:|---|
| `stmem`, all 24 GDN layers -- what `gb_real` holds today | **24.000** | does not fit |
| `stmem`, ONE layer | 1.000 | 29 URAM288, or 228 BRAM36 |
| conv tap history, all layers | 1.125 | 48 KB resident |
| `semem`, all layers | 0.094 | |
| **device BRAM + URAM, everything the part has** | **14.203** | 672 tiles + 320 URAM288 |

**24.0 MB against 14.2 MB is 1.69x the entire on-chip memory of the device,
with nothing left over.** So the previous plan-of-record framing -- "port
`gb_real`'s 635 lines" -- is **withdrawn**. It was written from a line count
and not from a sizing, and nothing in the source signals that one of its five
arrays outweighs the part.

**The lane count cannot fix it.** `stmem` is `NLY*VH*DM*NBR` words of
`B_RECUR_LANES*16` bits with `NBR = DM/B_RECUR_LANES`, so the lane term
cancels and the extent is `NLY*VH*DM*DM*16` regardless. `llama_top`'s own
comment says the same thing independently. **Do not sweep the generic.**

**What has to be built instead**, per GDN job, 24 per token:

1. load layer L's recurrent state, 1.0 MB, HBM to on-chip URAM;
2. load its conv tap history (48 KB) and state exponents (4 KB);
3. run `gdn_block` against the on-chip copies, which `gb_real` already does
   correctly and IS worth porting;
4. store the updated state and history back.

DERIVED traffic: **50.4 MB per token**, read plus write. Not a throughput
concern at HBM bandwidth; it is new RTL, a new AXI master and new seam rules.

**Follow `rtl/attn_kv_axi.vhd` rather than reinventing it.** Subsystem C's KV
cache already solves this exact problem -- on-chip working set in front of an
HBM-backed store, own AXI3 master, selected by `C_KV_AXI` -- and its generics
(`AXI_DW = 256`, `ADDR_W = 33`, `MAXB = 16` with the AXI3 `ARLEN` cap named)
are the template for a `gdn_state_axi`.

**URAM IS legal for this store, unlike the norm gain image.** `[Synth 8-10226]`
refuses `ram_style = ultra` only for a table with non-zero INITIALISATION;
`stmem` is written at run time and starts at zero. The two cases look alike
and are not. This is the first use found for the 320 idle URAM288.

**A second piece of new RTL is required independently of the fit question: the
conv tap history buffer.** `llama_top` holds none and says so in an assert that
refuses rather than computing a wrong number, so **`B_SRC_REAL` has never
executed past token 0 anywhere in this repository.**

**MEASURED 2026-09-02, and `auto` is the trap:** `rtl/gdn_state_mem.vhd`, one
layer, OOC on the FK33 part.

| `ram_style` | URAM288 | RAMB36 |
|---|---:|---:|
| `"ultra"` | **32** (10.0% of 320) | 0, WNS +2.549 at 5.0 ns |
| `"block"` | 0 | **228** (33.9% of 672) |
| `"auto"` (no attribute) | 0 | **228** |

**Vivado never reaches for URAM on its own.** Without the explicit attribute
this store costs 228 tiles, which on top of the wired top's 327.5 is 82.7% of
the device before the 171-tile gain image would take it over. The attribute is
the difference between fitting and not.

**THE HBM SIDE ALREADY EXISTS, which is the one piece of good news here.**
`tools/hbm_map.py::arena_sizes()` derives, and `tools/pack_model_fk33.py`
already reserves in the manifest, `gdn_state_mant_bytes_per_layer = 1,048,576`
and `gdn_state_exp_bytes_per_layer = 4,096`, 24 layers, 25,264,128 bytes total.
**1,048,576 bytes is 8,388,608 bits: the same figure measured above, to the
byte, derived independently by a different tool for a different purpose.**
`server/fk33_manifest.c` already enforces `gdn_state_base >= weights_end`. So
the mover writes into an address map that exists; it does not have to allocate
one.

**But nothing reserves the conv tap history**: `(KCONV-1) * qkv_dim * 16 bits`
= 49,152 B per layer, 1.125 MB total. It must be added to
`hbm_map.arena_sizes()` and not quietly placed -- this address space has
already had one silent collision between two allocators that could not see each
other, and the symptom was a wrong token.

**Done when:** the per-job load and store move a layer between HBM and
`gdn_state_mem`, and a bench shows `gdn_block` producing identical output
across a save-and-restore, against a token stream longer than one token.

### STEP 4 -- Wire the seam to D and retire the refusal.

`rtl/fk33_seam.vhd` exists and **is addressable at `0xE000`** (TRACK SEAMMAP,
`1e46fb3`; the base was verified against the emitted BAR map, not inherited from
the header that proposed it).

**Today its D face is constants and `d_err` is tied HIGH**, so every GO refuses
one cycle later with `EC_DESC` and `ERR_INFO[3:0] = 0xF`, a code `llama_top`
cannot produce. That was deliberate: `rtl/fk33_seam.vhd:549` runs the completion
arm only `if running = '1'`, and `running` clears only on `d_err`, `d_tok_done`
or ABORT -- **so tying both low hangs the host forever.**

**Work:** connect `d_go`/`d_tok_done`/`d_err` to the real D, drop the tie-off,
and make `CAPS_VOCAB` report truthfully. Also `CAPS_FLAGS_V = 0x5` currently
sets `FK33_CAP_SAMPLER` in a bitstream with no sampler.

**Done when:** `server/pl_backend.c` -- whose third line still says *"Nothing
here has ever run against the card"* -- drives a token end to end through the
seam with no host step loop. **Oren's decision, verbatim: "we don't want host
controlling, let's get D working."**

### STEP 5 -- The real token, and what it must be compared against

The current 17.814 s token is the matvec skeleton with 32 host re-anchors. The
target is the same argmax with **zero re-anchors**.

**The oracle already exists** (`ref/run9b`, and `tools/dprog_oracle.py` at 956
lines). Compare element-for-element as the existing run does; a token that only
matches on argmax is not verified.

---

## 4. Things that are DONE and must not be redone

- **Striping.** Six emitters fixed (`d7f96cd`, `6ca385f`), measured on silicon.
  `hw/fk33/host/fk33_stripe_experiment.py run` is idempotent and re-runnable.
- **The card's flash.** It boots itself. Do not reflash without reading
  `docs/debugging/2026-08-30_restoring-the-card-after-a-power-cycle.md`.
- **The full gate is GREEN** at `32a7b47`: `OVERALL PASS 105 FAIL 0`.
  **`BASELINE_PASS` is deliberately still 99**; the floor measures 101 and a row
  landed after that archive, so 102 would be arithmetic over a row nobody ran.
  Close it with one clean run.

## 5. Traps specific to THIS work

- **Vivado's inference log lies in BOTH directions.** `[Synth 8-10226]` claimed
  a resource never granted; `[Synth 8-7186]` denied one that WAS granted (every
  object it named is a `RAM32M16` in the same run's mapping report). **Only the
  mapping report and an object-level `get_cells` census are authoritative.**
- **A capped job's `memory.peak` is the CAP, not the peak.**
- **ONE Vivado per box.** The workstation has ~13 GiB beside `llama-server`; the
  BC-250 has 14 GB total and one tool there peaks at 10.85 GB. Use both lanes.
- **Read `/proc/PID/exe`, never `ps ... args=`**, to check whether a lane is
  busy. The argv filter matches sibling `bash` and `grep` processes.
- **NO HARDWARE ACCESS FOR SUBAGENTS.** Two cards are on the JTAG chain and card
  2 holds the only surviving SQRL factory image. Every hardware script must be
  given `FK33_TARGET` **and** `FK33_XSDB_TARGET`; they are different variables
  read by different halves.

## 6. Open, not yet answered

1. **Does the composed design route?** The single most important unknown.
2. **The BRAM budget.** 171 tiles for the gain image plus 6 for RMSMUX's vectors
   against 672 on the part, with nothing tracking the total.
3. **Lever C at `ROWS_IF=48`.** Structural per-lane figures are exact; the total
   is an ESTIMATE and two models disagree.
4. **The rate coupling** if 1a and 1b are composed, and the uncovered load race.
5. **THERM-255.** The thermal guard trips roughly once every three minutes for
   reasons that are not heat, and each trip halts the compute domain. The trip
   counter **saturates at 255** (`fk33_thermal.vhd:1166`) and six host consumers
   read it as unbounded -- two give a false PASS, three under-report, and
   `therm_selftest.py` is INVERTED. Enumerated in `729df43`; **the fix is
   designed but NOT landed**, because the obvious one breaks
   `fk33_run_token.py`'s retry wrapper into a phantom trip on every job.
6. **`tb_attn_block` passed a broken tree** on a degenerate oracle stimulus,
   fixed in `1e18ce3` -- but `ref/attn_block_seq_vec.c:214` still carries the
   untapered line, giving a minimum over a constant vector on half the design.
