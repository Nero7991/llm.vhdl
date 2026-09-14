# The 52-hour synthesis wall is a 3D RAM that Vivado warned about by name

**Date:** 2026-09-14
**Build:** `hw/fk33/ooc_card_dcp.tcl`, `-top fk33_card`, `-flatten_hierarchy none`,
part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2.
**Runs:** `cardooc` (workstation, full shape, 54 h and counting) and
`cardsmall4096` (BC-250, `C_MAXPOS=C_CTXLEN=4096`, launched 01:00:05 EDT).

## CORRECTION, 2026-09-14 06:30 EDT: THE TITLE'S CLAIM IS WITHDRAWN. `mbank` IS NOT THE CAUSE.

**The attribution control ran and refuted it.** Two variants that remove
`attn_kv_axi` entirely -- so their logs contain no `8-11357` and no `mbank_reg`
at all -- go silent just the same:

| variant | change | last write | then silent | stop |
|---|---|---|---|---|
| `ctl` | ctx=4096 only | 44 s | 6 min | the `mbank`/`hdr_r` line |
| `noC` | `C_REAL=false` | **34 s** | 6 min | `8-6014` message cap |
| `noKV` | `C_KV_AXI=false` | **45 s** | 6 min | `8-6014` message cap |
| `noN` | `NORM_REAL=false` | 33 s | 6 min | the `mbank`/`hdr_r` line |
| `noB` | `B_STATE_AXI=false` | 47 s | 6 min | the `mbank`/`hdr_r` line |
| `noA` | `A_DESC=false` | 31 s | (exited) | **5 ERRORS, invalid variant** |

**Removing the object Vivado named does not clear the wall.** The `8-11357`
warning is real, the object is real, the register count matched exactly -- and
it is still not the cause. It is a warning that happens to sit one line above
where output stops, which is a fact about message ordering, not about causation.

**Subsystem A is NOT TESTABLE through the card's generics, and that is a
finding in itself.** `A_DESC=false`, `A_ROWS_IF=4` and `A_ROWS_IF=1` all fail
identically: 5 errors at 31 s, `[Synth 8-549] port width mismatch for port
'm_arvalid': port width = 49, actual width = 5`. A's width is fixed elsewhere in
the hierarchy, so the generic cannot move it. This is this repository's recorded
"a generic that must agree with a derived value is a new way to be silently
wrong" trap, except here it is loudly wrong.

So generic-space bisection is **exhausted**: context, C, KV, NORM and B have no
effect, and A cannot be varied at all.

### Two more traps, both mine

- **MY PASS CONDITION COULD NOT DISCRIMINATE.** I defined PROGRESSED as "the log
  grows past 71,325 bytes". **Removing a subsystem REMOVES log output**, so
  `noC` came in at 62,223 bytes and `noKV` at 69,299 -- smaller than baseline
  whether or not synthesis advanced. It is the cross-context-arithmetic error in
  a new place: comparing byte counts between runs that do not emit the same
  things. The verdicts happened to be right, by luck, not by design.
- **I NEVER CALIBRATED THE WINDOW AGAINST A HEALTHY RUN**, because no healthy
  run of this design has ever existed. "STUCK in 7 minutes" could have meant
  "legitimately still working". **The metric that actually works is SILENCE**:
  a healthy Vivado emits continuously, and every walled run here stops emitting
  at 31-47 s and never resumes -- for 6 minutes, for 4 h 08 m, and for 56 h.
  That signature is shape-independent and window-independent, and it is what
  every table above should have measured from the start.

**What survives from the original write-up below:** the procedure, the null
result on the context axis, the unthrottled 7.97 GiB figure, and the rejection
of `llama_top`'s flat `mem`. **What does not: the title, and the identification
of `mbank` as the cause.**

## SECOND CORRECTION, 08:36 EDT: SIX ROUNDS, NOTHING MOVES IT. AND `-flatten_hierarchy none` IS REFUTED AS THE FLOW'S RATIONALE.

### Everything that does NOT change the wall (all MEASURED tonight)

| axis | values tried | result |
|---|---|---|
| `C_MAXPOS` / `C_CTXLEN` | 131072 -> 4096 (32x) | byte-identical stop |
| `C_REAL` | false | silent at 34 s |
| `C_KV_AXI` | false | silent at 45 s |
| `NORM_REAL` | false | silent at 33 s |
| `B_STATE_AXI` | false | silent at 47 s |
| `A_DESC`, `A_ROWS_IF` | false, 4, 1 | **all ERROR**, `8-549` port width; A not variable |
| `HOST_WINDOW` | true vs false, on `fk33_llama_top` | **identical**, 33 s both, `8-11357` absent in both |
| `-flatten_hierarchy` | `none` / `rebuilt` / `full` | **identical**: 44 / 43 / 44 s, peak 6.71 / 6.69 / 6.70 GiB |

### Everything that DOES synthesise, in seconds

| top | outcome |
|---|---|
| `matvec_int4_desc_axi` | emitted to 166 s, `Finished Part Resource Summary` |
| `fk33_engine` | emitted to 170 s, `Finished Part Resource Summary` |
| `vec_mem` | **completed**, 17 s, 18 phase lines |
| `sampler_stream` | **completed**, 17 s, 16 phase lines |
| `seq_vec_issue` | **completed**, 17 s, 16 phase lines |

**Only the COMPOSITIONS wall.** `fk33_card` and `fk33_llama_top` both stop at
33-45 s and never reach `Finished Synthesize`; every individual entity that can
be synthesised standalone finishes in under three minutes. `fk33_engine`
contains subsystem A and completes, so **A is cleared too.**

### `-flatten_hierarchy none` was the flow's entire justification, and it does nothing

`ooc_card_dcp.tcl`'s header says two earlier card OOC runs did not finish, that
its own rule is "do not launch a third without a reason to expect a different
outcome", and that **the reason is `-flatten_hierarchy none`**. That claim had
never been tested. It is now: `none`, `rebuilt` and `full` are indistinguishable
to within one second and 0.02 GiB. **The third run was launched on a
justification that does not hold, and it has now burned 58 hours.**

### A confound in my own metric, stated

Both `fk33_llama_top` runs and the `noC`/`noKV` variants go silent **exactly at
the `8-6014` message-cap line** (*"appears 100 times and further instances of the
messages will be disabled"*). Output may therefore be stopping because messages
are SUPPRESSED, not because work stopped. CPU stays at 100-102% and memory keeps
growing, so work does continue. **"Silent" means "not emitting", which is weaker
than "stuck"** -- though 58 hours without reaching `Finished Synthesize` settles
the practical question regardless.

### What this means

**Monolithic OOC synthesis of the card does not work, and no knob reachable from
the card's generics or from `synth_design` changes that.** Three runs have now
failed this way: two recorded in
`2026-09-08_card-ooc-synthesis-does-not-finish.md` and this one.

**The per-block compose path demonstrably DOES work** -- `attn_block`
(dsp=298 lut=87340 ff=101319 wns=0.825) and `gdn_block` (dsp=253 lut=75246
ff=52203 wns=0.483) both have real `COMPOSE_RESULT` numbers from runs that
completed in minutes. That is the route with evidence behind it.

### Still open

- **Why** a composition of entities that each synthesise in seconds does not
  synthesise at all. Not answered, and not answerable from the generics.
- Whether `region_mem` and `rmsnorm_rs_mem` wall. **Untested** -- both have
  generics with NO defaults (`SZ`, `N`), so they cannot be a standalone top
  without supplying them, and both failed with `[Synth 8-78] a value must be
  associated with generic`.

## ROUND 7, 09:06 EDT: EVERY UNIT COMPLETES. THE WALL IS THE COMPOSITION ITSELF.

The two units round 4 could not test are now tested. Both have generics with no
defaults; `region_mem`'s `SZ` is an `integer_vector`, which `-generic` cannot
carry, so it needed a scratch wrapper copying the bindings from
`rtl/fk33_llama_top.vhd:1641-1660` (GHDL-analysed clean; the repo is untouched).

| top | outcome | area |
|---|---|---|
| `region_mem`, `HOST_WINDOW=false` | **completed, 46 s** | lut=4038 ff=27 **ramb=100** |
| `region_mem`, `HOST_WINDOW=true` | **completed, 118 s** | lut=11214 ff=3611 **ramb=0** |
| `rmsnorm_rs_mem`, `N=12288` | **completed, 58 s** | lut=5591 ff=1634 dsp=360 ramb=24 |

**`region_mem` is not the wall**, in either configuration. Neither is
`rmsnorm_rs_mem`.

**Bonus, and it CONFIRMS `region_mem.vhd`'s header by measurement:** the
combinational host read port costs the whole BRAM inference. `HOST_WINDOW=false`
gets **100 BRAM tiles and 4,038 LUT**; `HOST_WINDOW=true` gets **0 BRAM and
11,214 LUT plus 3,611 FF**. The header said "a memory with a combinational read
port CANNOT be a BRAM" and that is exactly what the two runs show. The card's
`HOST_WINDOW => false` is correct and worth 100 tiles and 7,176 LUT.

### The complete picture

**Everything that synthesises standalone, all of it, in seconds to minutes:**
`vec_mem` (17 s), `sampler_stream` (17 s), `seq_vec_issue` (17 s),
`region_mem` (46 s / 118 s), `rmsnorm_rs_mem` (58 s), `matvec_int4_desc_axi`
(166 s), `fk33_engine` (170 s).

**Everything that walls:** `fk33_card`, `fk33_llama_top`. Nothing else.

So the wall is **not attributable to any single entity**. Every part completes;
only the whole does not. `fk33_engine` is itself a large composition (subsystem
A) and completes, so it is not simply "big compositions fail" either -- but
`fk33_llama_top` adds B, C, D, the norm path, `region_mem` and the glue, and
that is where it stops.

**This is a negative result and it is complete at the unit level.** Further
generic or entity bisection has nowhere left to go. The remaining hypotheses are
about the COMPOSITION -- instance count, cross-module connectivity, or a
Vivado-version behaviour -- none of which is reachable by the axes used here.

### What to do instead

**The per-block compose path is the one with evidence.** `attn_block`
(dsp=298 lut=87340 ff=101319 ramb=11 wns=0.825 fmax=239.5) and `gdn_block`
(dsp=253 lut=75246 ff=52203 bram=43 wns=0.483 fmax=221.4) both have real
`COMPOSE_RESULT` lines from runs that completed in minutes. Synthesise blocks
out of context and compose checkpoints, rather than elaborating the whole card
in one `synth_design`.

## ROUND 8, 10:06 EDT: THE WALL IS INSIDE `RTL Elaboration`, AND THE TRIGGER IS THE INTER-SUBSYSTEM WIRING

### Where it is: elaboration, settled by `synth_design -rtl`

`synth_design -rtl` builds the RTL netlist and stops, before inference,
optimisation and technology mapping. With `fk33_engine` as the control, because
`-rtl` is cheaper for EVERY design and a fast result alone would prove nothing:

| top | `-rtl` | last phase line |
|---|---|---|
| `fk33_engine` (CONTROL) | **completed, 115 s**, 5 phase lines | `Finished RTL Optimization Phase 1` |
| `fk33_llama_top` | **WALLS**, silent from 37 s | `Starting RTL Elaboration` |
| `fk33_card` | **WALLS**, silent from 48 s | `Starting RTL Elaboration` |

Both walling tops print `Starting RTL Elaboration` at t = 4 s and **never print
`Finished RTL Elaboration`**.

**THIS IS THE THIRD AND FINAL CORRECTION TO WHERE THE WALL IS.** It was first
written up as a "post-elaboration wall"; then the `Starting Synthesize` line at
t = 2 s was read as proof it was 2 s INTO synthesis. Both were wrong, and in
opposite directions. `Starting Synthesize` is printed BEFORE elaboration runs,
so it was never evidence about elaboration at all. The wall is IN elaboration.

That is a material distinction, not a pedantic one: elaboration is where VHDL is
turned into a netlist, so the cause is a **structural construct** -- a mux, a
generate, a constant-folding blow-up -- and NOT RAM inference, mapping, or any
`ram_style`/`8-11357` question. Every object-level hypothesis pursued tonight
(`mbank`, `region_mem`, `HOST_WINDOW`, `llama_top`'s `mem`) was looking in the
wrong PHASE, which is why none of them moved it.

### What triggers it: the wiring, not the parts

`hw/fk33/gen_compose4_top.py`'s docstring states what `compose4_top` is:

> "It is a CO-RESIDENCY top. The nine instances share `core_clk` and
> `core_rst` ...; every other port of every instance is brought out to the top
> level." and it does NOT measure "inter-subsystem nets. **The subsystems are
> not wired to each other**, because HOW they are wired is board row N2."

So there are **two tops carrying A+B+C+D at the real 9B shape**:

| top | subsystems wired to each other? | outcome |
|---|---|---|
| `compose4_top` | **NO** (co-residency, ports to top level) | synthesises, places, **ROUTES** (WNS -0.422, 286,806 nets) |
| `fk33_llama_top` | **YES** (sequencer glue, region-file client muxing) | **never finishes RTL Elaboration** |

Same four subsystems, same shape, same part, opposite outcomes. **The
difference is the interconnect**, and that is consistent with every other result:
each unit elaborates alone, the unwired composition elaborates, only the wired
one does not.

### The named suspect, as a LEAD

`rtl/fk33_llama_top.vhd` around the region file describes "**Per-CLIENT element
ports, muxed below**", where a client is not a unit -- "unit V is an ADAPTER in
front of NVOP engines, and each engine needs its own port". A combinational mux
across clients x `NREGION` x `REGMAX` is exactly the shape that stalls
elaboration. **This is a lead and has not been measured.** The way to test it is
to reduce the client count or the mux width and re-run `-rtl`, which now costs
five minutes rather than a day.

### Why this reframes the whole investigation

Rounds 0-7 varied generics and entity boundaries and found nothing, because
**every one of those axes acts on WHAT is instantiated, and the trigger is HOW
the instances are connected.** Generic-space bisection could not have found this
no matter how many rounds it ran. The discriminator was not another variant; it
was noticing that a top which already routes and a top which never elaborates
differ by exactly one property, and that property is stated in a docstring.

## ROOT CAUSE, round 10, 08:41 MDT: `gb_real.bp.zb_reg`, AND IT WAS ALREADY IN THE REPO

`synth_design -rtl -top fk33_llama_top` on the WORKSTATION errors at **224 s**:

    ERROR: [Synth 8-3391] Unable to infer a block/distributed RAM for
    'gb_real.bp.zb_reg' because the memory pattern used is not supported.
    Failed to dissolve the memory into bits because the number of bits
    (196608) is too large.

**196,608 = 12,288 x 16.** `rtl/fk33_llama_top.vhd:4892-4897`, inside
`gb_real : if not B_BEHAV generate`:

    bp : process(clk) is
      variable zb : buf_t(0 to A_MAXROWS-1);
      variable yb : buf_t(0 to A_MAXROWS-1);

`A_MAXROWS` is a CONSTANT at `:1423` (`region_max(SHAPE)` = 12288), not a
generic. Two more `yb : buf_t(0 to A_MAXROWS-1)` exist at `:3697` and `:3963`.

### THE ANSWER WAS WRITTEN DOWN IN THIS REPOSITORY THE WHOLE TIME

`rtl/ooc_gdnadapt_top.vhd:69-79` names **the identical object and the identical
error**:

> "It exists because the block declares `zb` and `yb` as process VARIABLES of
> `buf_t(0 to A_MAXROWS-1)`, and at the 9B shape that is 12,288 x 16 bits EACH.
> Synthesis of the extracted block at the default shape fails:
> `ERROR: [Synth 8-3391] Unable to infer a block/distributed RAM for
> 'gb_real.bp.zb_reg' because the memory pattern used is not supported`
> and Vivado then terminates abnormally (signal 11)."

**I read that header hours earlier and quoted it for a different purpose**, to
establish that B's harness was not broken at HEAD. It contained the answer to
the 60-hour question and I did not connect it, because I was searching for a
hung PHASE rather than for a named OBJECT that this project had already hit.

### THE WALL IS NOT INFINITE

It terminates in a named error. Every earlier run looked like a hang for two
compounding reasons: the full `synth_design` path takes far longer to reach it
than `-rtl` does, and **the BC-250 is 2.3x slower, so a 300 s window never got
there**. On the workstation with `-rtl` the answer costs **224 seconds**.

That also retires "silence" as the metric. Silence was the right discriminator
for "is this the same defect", and it was WRONG as a model of what was
happening: Vivado was not stalled, it was grinding toward an error it would
eventually print.

### What is refuted, by direct control

- **`gen_vstub` / the client-muxing lead: REFUTED.** A scratch copy with
  `gv : if false generate` (exactly 1 line changed, asserted) produced the
  **identical error on the identical object**. The mux is not the cause. This
  was my named lead and it was wrong.
- **`REGMAX` cannot be lowered**, exactly as `:1085` pins it:
  `ERROR: [Synth 8-11323] assigned value '-12160' out of range` from
  `CHK_REGMAX : natural := REGMAX - region_max(SHAPE)`.

### Open

- Whether this is "unsynthesisable" or "unsynthesisable AT THIS SIZE" --
  round 11 runs the scratch `A_MAXROWS := 512` control that
  `ooc_gdnadapt_top.vhd` describes.
- Whether `yb` at `:3697` and `:3963` fail the same way once `zb` is fixed.
  The error names only the first object reached.
- The fix. Expected direction is to move `zb`/`yb` out of process variables into
  a memory, the pattern this repo already uses in `gdn_state_mem`,
  `gdn_exp_mem` and `region_mem`. **NOT** the `dissolveMemorySizeLimit` param
  the error message suggests -- that permits the dissolve into 196,608
  individual bits, which is the catastrophe, not the cure.

## The question, verbatim

> "Start tonight at 1am ET on BC-250, I'm gonna be using it before that"

being the scheduling of this probe, whose own question was: the full-shape card
OOC has been in a silent phase for over 45 hours with no log output and no
phase markers. **Does that phase terminate at a smaller context, and how does it
scale?**

Symptom numbers at dispatch: 54 h elapsed, CPU 102%, log frozen at 71,492 bytes,
`memory.current` 24,575 MiB pinned against a 24,576 MiB cap, `memory.events
high=7215`, 0 errors.

## The answer, up front

**The context axis was the wrong axis, and the wall is a 3D RAM that Vivado
named in a warning one line before it went silent.**

    WARNING: [Synth 8-11357] Potential Runtime issue for 3D-RAM or RAM from
    Record/Structs for RAM  mbank_reg with 16384 registers

`mbank` is declared at `rtl/attn_kv_axi.vhd:667-668` as an array **of an array**
of `std_logic_vector` -- `mbanks_t is array (0 to MPB-1) of mbank_t`, where
`mbank_t is array (0 to RBUF*NBLK-1) of std_logic_vector(CH_W-1 downto 0)`. At
the card's geometry that is `MPB=2`, `RBUF*NBLK=4*8=32`, `CH_W=128`, so 8,192
bits per `GEN_RD` instance and **16,384 across the two**, which is exactly the
register count Vivado prints.

**Its size does not depend on `C_MAXPOS` or `C_CTXLEN` at all** -- it is a
function of `KV_BLOCK`, `RBUF` and `HEAD_DIM` -- which is precisely why a 32x
context reduction moved the wall by zero bytes.

**Status: STRONG CANDIDATE, NOT YET CONFIRMED.** The decisive attribution
control (below) had not run when this was written. Do not treat this as settled.

## The procedure that produced it

1. **Reduce the context 32x and re-run.** `C_MAXPOS=C_CTXLEN=131072 -> 4096`,
   everything else byte-identical, inputs derived from the synced tree by `sed`
   with the diff asserted to be exactly 2 lines. **Isolates: is the wall a
   function of context size?** Answer: no.
2. **Compare the two logs' STOPPING POINT, not their length.** Both end on the
   byte-identical line. This is the step that converts "still slow" into "same
   defect".
3. **Read the last substantive warning before the stop**, rather than the last
   line. The last line is a RAM that COMPLETED; the warning above it is the one
   naming a runtime hazard.
4. **Confirm the warning is invariant across the two runs.** Same message, same
   object, same 16,384 registers at both shapes -- which both corroborates the
   identification and explains step 1's null result.
5. **Pending: the attribution control.** A variant sweep forcing each subsystem
   generic false in turn (`bisect.sh`), pass condition "log grows past byte
   71,325 within 7 minutes", with an unmodified ctx=4096 control that MUST
   reproduce STUCK or the window is wrong and every verdict is void.

## The evidence, raw

`cardooc.log` is 693 lines and ends at line 693. Lines 681-693:

    681: WARNING: [Synth 8-11357] Potential Runtime issue for 3D-RAM or RAM from Record/Structs for RAM  mbank_reg with 16384 registers
    682: WARNING: [Synth 8-4767] Trying to implement RAM 'GEN_RD[0].hdr_r_reg' in registers. Block RAM or DRAM implementation is not possible; see log for reasons.
    687: RAM "GEN_RD[0].hdr_r_reg" dissolved into registers
    688: WARNING: [Synth 8-4767] Trying to implement RAM 'GEN_RD[1].hdr_r_reg' in registers. Block RAM or DRAM implementation is not possible; see log for reasons.
    693: RAM "GEN_RD[1].hdr_r_reg" dissolved into registers
    <end of file, 54 hours ago>

`cardsmall.log` (ctx=4096), 694 lines, the same warning at line 682:

    682: WARNING: [Synth 8-11357] Potential Runtime issue for 3D-RAM or RAM from Record/Structs for RAM  mbank_reg with 16384 registers

Phase markers, both runs:

    89: Starting synth_design
    96: Starting Synthesize : Time (s): cpu = 00:00:02 ; elapsed = 00:00:02 . Memory (MB): peak = 1761.844

So the job entered `Synthesize` at **t = 2 seconds** and has been inside that one
phase ever since. The ctx=4096 run reached the identical stop at **t = 45
seconds** and had produced nothing further 2 h 06 m later, at 100% CPU with
`MemoryPeak` climbing 7.75 -> 7.97 GiB.

Unthrottled memory, ctx=4096 (`memory.events` `high 0, max 0, oom 0`, swap 0):

    MemoryPeak = 7.97 GiB

This is the first card-OOC memory figure in this project that is a real peak
rather than a cap.

## Measured and REJECTED -- do not retry

- **Reducing `C_MAXPOS` / `C_CTXLEN`.** 32x, and the wall did not move by one
  byte. Both runs stop on the identical line. Do not run the ctx=16384 point;
  it is on the same dead axis.
- **`rtl/llama_top.vhd`'s flat `mem` array is NOT the culprit for THIS build.**
  It is 2,752,512 bits (`NREGION=14 x REGMAX=12288 x MANT_W=16`, evaluated by
  GHDL, not by hand), which matches a `[Synth 8-3391]` error seen in a DIFFERENT
  job (`ooc_bb2`) to the digit. **The exact match is a coincidence of a shared
  model dimension, and `rtl/llama_top.vhd` is not in this build's source list at
  all** -- `ooc_card_dcp.tcl:149` reads `rtl/fk33_llama_top.vhd`, whose flat
  array was already replaced by `region_mem`. An exact numeric match is not
  attribution when the object is not in the build.

## Measurement traps hit

- **I REJECTED THE CORRECT OBJECT BY ARGUING FROM ITS TOTAL.** Two hours before
  finding the warning I computed `mbank` at 8,192 bits per instance, called it
  "trivial", and wrote it up under "Measured and REJECTED". The size was right;
  the inference was wrong. **The hazard is not the bit count, it is the 3D
  array-of-array-of-vector shape**, and Vivado said so explicitly in a message
  that was sitting in the log the whole time. This repository already carries
  the rule -- *when a report names the object, no argument about the total is
  admissible* -- and I broke it while quoting it.
- **A CHECK THAT COULD NEVER FIRE, REPORTED HOURLY.** My phase-line grep was
  `^(Start|Finished) ` with a trailing space. Vivado prints "**Starting**". It
  returned 0 every time and I reported "0 phase lines" for hours as though it
  were evidence. The true count is 2, and the second line is the one that
  reframes the whole problem: synthesis was entered at t=2 s, so this was never
  a "post-elaboration" wall.
- **THE LAST LINE OF A LOG NAMES WHAT FINISHED, NOT WHAT IS RUNNING.** Reading
  the final `dissolved into registers` line pointed at `hdr_r`, a 4-word signal
  that completed successfully. The diagnostic content was one line ABOVE the
  RAM section, not at the bottom.
- **An earlier probe's error message is not this probe's evidence.** The
  `[Synth 8-3391]` / 2,752,512 figure came from `ooc_bb2`. I had written that
  caveat into `docs/WORKLOG.md` myself two hours earlier and then chased the
  number anyway because it matched exactly.

## Open, not yet answered

- **The attribution control has not run.** Until a variant that removes
  `attn_kv_axi` progresses past byte 71,325 while the control stays STUCK, this
  is a candidate, not a cause.
- **Whether the phase terminates at all**, at any shape. Nothing has yet been
  observed to exit it.
- **What the fix costs.** `attn_kv_axi.vhd:645-668` documents the bank split as
  a deliberate area optimisation worth ~21,000 LUT per prefetch slot, MEASURED
  2026-09-06. Flattening `mbanks_t` into a single 2D array with a computed index
  should preserve that saving while removing the 3D shape, but that is an
  ESTIMATE and has not been synthesised.
- Whether any OTHER `8-11357` object exists elsewhere in the design that has
  simply not been reached yet. **PARTIALLY ANSWERED, as a LEAD not a
  measurement** -- see the census below.

## What else has this shape (a LEAD, not a measurement)

A scan of the card's REAL source closure -- the 66 files parsed out of
`ooc_card_dcp.tcl`'s own `read_vhdl` lines, not a hand-picked list -- finds
**10 array-of-array types**:

| file:line | type | element |
|---|---|---|
| `rtl/matvec_core.vhd:263` | `cb_bank_t` | `cb_t` |
| `rtl/matvec_core.vhd:384` | `lvl_arr` | `node_arr` |
| `rtl/matvec_core.vhd:404` | `scp_t` | `sc_arr` |
| **`rtl/attn_kv_axi.vhd:667`** | **`mbanks_t`** | **`mbank_t`** |
| `rtl/gdn_conv.vhd:150` | `pk_arr` | `s32_arr` |
| `rtl/gdn_conv.vhd:151` | `xk_arr` | `s16_arr` |
| `rtl/rmsnorm_bf.vhd:360` | `tree_t` | `u63a` |
| `rtl/gdn_recur_pipe.vhd:206` | `red_s_t` | `s42_arr` |
| `rtl/gdn_recur_pipe.vhd:207` | `red_u_t` | `u35_arr` |
| `rtl/seq_desc_fetch.vhd:281` | `bank_arr` | `word_arr` |

**Only `mbanks_t` has been OBSERVED to trigger `8-11357`.** The rest are
unmeasured, and most are probably harmless: `lvl_arr`, `scp_t`, `tree_t`,
`red_s_t`, `red_u_t`, `pk_arr` and `xk_arr` are reduction-tree and pipeline
stages indexed by LOOP CONSTANTS, and Vivado only attempts RAM inference on a
structure addressed by a non-constant index.

**The two worth watching are `cb_bank_t` and `bank_arr`**, which are
RAM-shaped. Note that `cb_bank_t` is the codebook broadcast already on this
project's radar as `CB_BCAST` (the named timing suspect, and the object behind
the stale `CB_STYLE="distributed"` -42,633 LUT figure).

**Do not read this table as a list of defects.** It is a list of places to look
IF fixing `mbank` moves the wall rather than removing it. Synthesis has never
got past `mbank`, so nothing downstream of it has been exercised at all, and a
shape census cannot tell you which of these Vivado will treat as a RAM.
