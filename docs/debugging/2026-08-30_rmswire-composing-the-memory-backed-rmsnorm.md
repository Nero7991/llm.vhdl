# TRACK RMSWIRE: composing `rmsnorm_rs_mem` into `llama_top`, and the race it inherits

**2026-08-30.** Written at the moment the composition was root-caused, not at
the end. Every figure is MEASURED unless labelled DERIVED or ESTIMATE.

---

## 1. The question, verbatim

> **Wire `rtl/rmsnorm_rs_mem.vhd` into `rtl/llama_top.vhd` in place of the flat
> `rmsnorm_rs`, and draw the result.** This is the single largest measured area
> lever on the project and it is built, verified and NOT composed.
>
> [...] **So: closing the load-race coverage gap at the REAL SHAPE is part of
> this task, not optional.** A composed area number with an uncovered race is
> not a result.

And, added mid-track by the dispatcher:

> **BRAM may bind before LUT, and nobody has been adding it up.** [...] needed
> 423.5, available inside `pb_core` 372.5, **short by about 51 tiles.**
> Report the BRAM total from your composed draw as a first-class result.

---

## 2. The answer, up front

### THE RESULT IS NOT THE AREA NUMBER. IT IS A 1,030-CYCLE WINDOW IN WHICH THE DESIGN IS WRONG AND EVERY VALUE IS RIGHT.

`rmsnorm_rs_mem` reads its gain in **TWO** element passes, not one, and they
fail differently. MEASURED at `N = 4096, LANES = 4` off the unit's new
`w_active` tap:

| pass | arrives | earliest safe start | what a stale gain does there |
|---|---:|---:|---|
| `S_RAW` | `start + 1067` | **2007** | feeds `max\|raw\|` only, which sets `shift_total` and `o_exp`. **Changes the output ONLY IF a corrupted element was the maximum.** |
| `S_EMIT` | `start + 2097` | **977** | is the output word. Wrong, element for element, always. |

Both boundaries are MEASURED to the cycle: `start_at = 2006` is corrupt and
`2007` is clean; `976` is corrupt and `977` is clean.

**Between them lies a window `[977, 2006]`, 1,030 cycles wide, in which the
gain load is LATE, the unit multiplies by the previous norm op's gain while
taking its maximum, and the output is BIT-IDENTICAL to the oracle.** The width
is not a coincidence: it is exactly the separation between the two arrivals,
`2097 - 1067 = 1030`.

MEASURED, 17 sample points across that window, ordinary previous-op stale gain,
compared element by element against `rmsnorm_rs` fed the correct gain
(`hw/fk33/results/rmswire_2026-08-30/invisible_window.txt`):

```
start_at  raw_rise  stale_raw  differing verdict
977       2044      1373       0        INVISIBLE
1000      2067      1342       0        INVISIBLE
1200      2267      1075       0        INVISIBLE
1400      2467      809        0        INVISIBLE
1600      2667      542        0        INVISIBLE
1800      2867      275        0        INVISIBLE
1900      2967      142        0        INVISIBLE
1950      3017      75         0        INVISIBLE
1991      3058      21         0        INVISIBLE
2000      3067      9          0        INVISIBLE
2006      3073      1          0        INVISIBLE
```

**Up to 1,373 of 4,096 elements read from the wrong gain vector, and not one
output word moves, at any point in the window.**

Three consequences, and they are the reason this matters more than the area:

1. **No check that compares values can catch this.** That is the inverse of
   this project's usual failure. Normally the structure looks right and the
   numbers are wrong; here the numbers are right and the design is wrong.
   `sim/tb_llama_top`'s four `EXP_*` landmarks are hashes of the TOKEN, so
   **they would pass throughout the entire 1,030-cycle window.** So would
   `tb_rmsnorm_rs_mem`, `ref/run9b` and any element-exact card-versus-host
   comparison.
2. **The deadline is not visible from outside the unit.** It is `S_RAW`, an
   internal state 1,067 cycles after `start`, with no external landmark. TRACK
   NORMURAM refused this composition on exactly that ground and was right; what
   was missing was a number for it.
3. **The tap now exists.** `rtl/rmsnorm_rs_mem.vhd` has an output port
   **`w_active`**, a combinational decode of the state register: high through
   `S_RAW` AND through `S_EMIT`, low in the `S_SHIFT1`/`S_SHIFT2` gap between
   them. One pin therefore times BOTH deadlines -- the first rise is `S_RAW`,
   the rise after the fall is `S_EMIT` -- and that is how every number above
   was measured rather than derived. It drives nothing inside the unit, costs
   the build nothing (Vivado ignores `severity failure`), and every existing
   port map uses named association so it may be left unassociated.
   **Whoever builds the card top inherits this deadline and needs this pin.**

**And the composed design does not rely on the window at all: it gates.**
`llama_top`'s S_GO holds `r_go` until `wbusy` clears, so full residency is
structural rather than arithmetical. MEASURED cost: **zero cycles** -- mutation
row R1 removes the gate, leaves TRACK NORMURAM's `wbusy`-at-`r_go` assertion in
place, and SURVIVES, which is direct evidence that the load always finishes
before S_GO would have fired anyway. It finishes about three cycles early. Three
cycles is not a margin; it is a coincidence that happens to hold today, and
mutation row R2 shows what the gate buys: a load made **four times slower** is
a stall and the design still passes.

### The rest of the answer

**The wiring is landed and the numeric oracle is unchanged.** All six
`sim:tb_llama_top*` gate rows PASS with `rmsnorm_rs_mem` in the D-vec norm,
including `tb_llama_top_normw`, the only wrapper that populates
`NORM_W_IMAGE` and therefore the only one that exercises the gain loader at
all. None of the token landmarks moved.

**The composed area and BRAM numbers are in section 6.**

---

## 3. What was actually changed

`rtl/llama_top.vhd`, the `gvr : if NORM_REAL and vi = V_NORM generate` block:

| before | after |
|---|---|
| `u_rms : entity work.rmsnorm_rs` | `entity work.rmsnorm_rs_mem` |
| `xw` (NN words) + flat view `xv` -> `x_mant` | `x_we`/`x_wa`/`x_wd`, written by S_RD |
| `ov` (NN*16 flat) read by S_WR | `o_ra`/`o_rd`, two-deep valid pipeline in S_WR |
| `wsel` (65,536 bits) <- `gwc` register OR `gwm.wreg` shift register | `nw_we`/`nw_wa`/`nw_wd`, one 16-bit word per cycle |
| `gwc` / `gwm` two branches | ONE loader; `nw_count` returns 1 and `nw_load` returns `(others => W_CONST)` when the image is empty |
| S_GO fires `r_go` unconditionally | S_GO fires `r_go` only when `wbusy = '0'` |
| -- | `wact_chk`, a simulation-only assertion on the unit's new `w_active` tap |

`rtl/rmsnorm_rs_mem.vhd` gained ONE output port, `w_active`, a combinational
decode of a state register that already exists: high through `S_RAW` and
`S_EMIT`, low between them. It drives nothing inside the unit. Every existing
port map uses named association, so leaving it unassociated is legal and no
other instantiation had to change.

**The 65,536-flop `gwm.wreg` is gone with `wsel`.** TRACK NWFIX recorded that
the shift-register write "contributes no LUT row at all -- it is 65,536 flops
and an enable". Those flops are what this change deletes on top of what TRACK
RMSMUX measured standalone.

---

## 4. The procedure, in the order it was run

1. **Read the refusal before re-deciding it.** TRACK NORMURAM's section 8 and
   the WORKLOG ruling. Its four coupled consequences were re-derived here and
   three of them held; the fourth (that the deadline is `S_RAW`) is corrected
   in section 5.
2. **Wire it, at the real shape, and run the existing gate.** Six
   `sim:tb_llama_top*` rows, GHDL. This is the numeric oracle: `llama_top` is
   the reference implementation for the whole design, so a composed top that
   computes differently is wrong even if it is smaller.
3. **Build the OOC pair.** `git archive HEAD` into a control tree, the same
   tree plus exactly two transplanted files into the composed tree, then
   `sim/ooc_normadapt_extract.py` on each. The extractor copies the `gvr` block
   VERBATIM, so the diff between the two generated tops IS the diff between the
   two `llama_top.vhd` files, restricted to the block.
4. **Elaborate both OOC tops in GHDL before spending an hour of Vivado on
   them.** This caught `clog2` (section 8.2).
5. **Write `sim/tb_rmswire_loadrace.vhd` at `N=4096 LANES=4`,** with a model of
   the deadline that PREDICTS new points rather than reproducing the one it was
   calibrated on. The first version's prediction was wrong and the bench said
   so; that is section 5.
6. **Map both boundaries with `PROBE_S`,** correct the model, and re-verify it
   against six points it was not fitted to.
7. **Run the mutation matrix with three attribution columns.**
8. **Draw the composed pair on the BC-250, one tool at a time, same session.**

---

## 5. The finding: two deadlines, and the strict one is invisible

### 5.1 What the first model said, and how it was told it was wrong

The bench's first version derived ONE boundary from the MEASURED `S_RAW`
arrival:

```
element j is written at the end of trial cycle j
vec_mem is READ-FIRST, so a read at the edge ending cycle c sees writes <= c-1
element j is read during cycle T_raw + j/LANES
safe  <=>  j <= T_raw + j/LANES - 1  <=>  T_raw >= N - N/LANES + 1
crit  = N - N/LANES + 1 - (T_raw - S) = 2006
```

It then predicted a difference at `S = crit - 16 = 1990` and got an EXACT
match instead:

```
ROW C inside-unsafe: start_at=1990 differing_elements=0 first=-1
                     o_exp=14/14 reproduces_oracle=true expected=false
(report failure): row C reproduced the oracle although the gain was still
streaming in when the unit read it.
```

**The bench went red on its own model, which is the only reason the finding
exists.** A bench that had only checked "resident -> matches" would have been
green and would have carried a wrong mental model into the design.

### 5.2 The mechanism

`rmsnorm_rs_mem` reads `w` in TWO element passes:

* **`S_RAW`** computes `raw = (x*inv)*w` only to take `max|raw|`, which sets
  `shift_total` and hence `o_exp`. A stale gain here changes the output **only
  if it changes the maximum.**
* **`S_EMIT`** recomputes `raw` and emits it. A stale gain here is a wrong
  output word, always.

MEASURED: `S_EMIT` arrives 1,030 cycles after `S_RAW`, so its deadline is
1,030 cycles slacker. **A bench that only compares outputs measures the wrong
boundary** -- it measures `S_EMIT`'s, which is the loose one.

### 5.3 The corrected model, and the six points it was NOT fitted to

The corrected condition is `j <= T + j/LANES - 2`: `vec_mem` is read-first AND
the unit consumes the word one stage after presenting the address
(`p1_wm <= w_q`). So

```
crit_raw  = N - N/LANES + 2 - (T_raw  - S) = 4096 - 1024 + 2 - 1067 = 2007
crit_emit = N - N/LANES + 2 - (T_emit - S) = 4096 - 1024 + 2 - 2097 =  977
```

MEASURED with the ORDINARY stale gain, which maps the `S_EMIT` (observable)
boundary. Predicted first-differing index and count in brackets:

```
PROBE start_at=960  emit_rise=3057 differing=22 first=4074   [4074, 22]
PROBE start_at=970  emit_rise=3067 differing=9  first=4087   [4087,  9]
PROBE start_at=976  emit_rise=3073 differing=1  first=4095   [4095,  1]
PROBE start_at=982  emit_rise=3079 differing=0  first=-1     [none]
PROBE start_at=1000 emit_rise=3097 differing=0  first=-1     [none]
ROW B start_at=0    emit_rise=2097 differing=1301 first=2794 [2794, 1302]
```

Every first-differing index is exact. The only discrepancy is row B's count,
1301 against 1302: one of the 1,302 corrupted elements happened to give the
same 16-bit output with the wrong gain.

MEASURED with the TAIL-HEAVY probe gain, which maps the `S_RAW` boundary:

```
PROBE tail=true start_at=2004 raw_rise=3071 differing=4096 first=0
PROBE tail=true start_at=2005 raw_rise=3072 differing=4096 first=0
PROBE tail=true start_at=2006 raw_rise=3073 differing=4096 first=0
PROBE tail=true start_at=2007 raw_rise=3074 differing=0    first=-1
PROBE tail=true start_at=2008 raw_rise=3075 differing=0    first=-1
PROBE tail=true start_at=2009 raw_rise=3076 differing=0    first=-1
```

and the other boundary pinned to the cycle as well:

```
PROBE tail=false start_at=976 emit_rise=3073 differing=1 first=4095   [UNSAFE]
PROBE tail=false start_at=977 emit_rise=3074 differing=0 first=-1     [SAFE]
```

**BOTH boundaries are exactly what the corrected model predicts: `crit_raw`
= 2007 and `crit_emit` = 977, with 2006 and 976 measured unsafe and 2007 and
977 measured safe.** Two boundaries 1,030 cycles apart, pinned to the cycle,
from the same two measured parameters. `- 1` predicts `start_at = 976` to be
clean and it is not.

Full map: `hw/fk33/results/rmswire_2026-08-30/boundary_map.txt`.

This project has a recorded case of a one-parameter model fitted to one point
being quoted about another and being wrong by twelve percentage points with the
sign of its own mechanism backwards. The discipline that avoids it is not
"label it ESTIMATE"; it is to make the model predict points it was not fitted
to and to let it go red when it misses. This one missed, was corrected, and
now reproduces ten measured points.

### 5.4 The invisible window, and a correction to the dispatcher's figure for it

```
ROW G raw-unsafe ordinary-gain (REPORTED, NOT JUDGED): start_at=1991
  differing_elements=0 first=-1 o_exp=14/14 reproduces_oracle=true
```

Row G of the gate bench is ONE point inside the window. The full sweep is
`hw/fk33/results/rmswire_2026-08-30/invisible_window.txt` and it is quoted in
section 2: **17 sample points across `[977, 2006]`, up to 1,373 of 4,096
elements read from the previous norm op's gain, ZERO differing output words at
every point.**

Row G is REPORTED and NOT JUDGED even though it came out invisible at every
point tested, because invisibility is a property of the DATA -- specifically of
whether a corrupted element happens to be `argmax|raw|` -- and asserting a
coincidence is how a check ends up passing for the wrong reason. Row E is the
judged version: it uses a stale gain whose tail is railed at +32767, which
makes a stale tail element necessarily the maximum, and it kills, moving
`o_exp` from 14 to 11 (three extra bits of `shift_total`, exactly the 8x gain
ratio).

**CORRECTION, dispatcher 2026-08-30.** The message that prompted this section
put the invisible window at *"116 cycles wide (2007 to 2123)"*. MEASURED, it is
**`[977, 2006]`, 1,030 cycles wide**, and 2007 is its first SAFE cycle rather
than its start. The width is exactly the separation between the two arrivals,
`2097 - 1067 = 1030`, which is what it has to be: the window opens when
`S_EMIT` becomes safe and closes when `S_RAW` does, and the two passes are
1,030 cycles apart.

**This row is the whole argument for the S_GO gate.** A design whose
correctness depends on "the corrupted elements were not the maximum" is not
correct; it is lucky, and nothing downstream would ever notice.

### 5.5 Why the margin was never going to be the answer

DERIVED, and it agrees with TRACK NORMURAM's independent derivation:

| | load | budget to `r_go` | margin |
|---|---|---|---|
| before (`GW = 4` words/cycle into a shift register) | `NN/GW + 1` | `NN + 4` | **`GW` = 4.0000x, SHAPE-INVARIANT** |
| after (1 element/cycle into the bank) | `NN + 2` | `NN + 4` | **3 CYCLES, at every shape** |

Extending the budget to the unit's first `w` read recovers only about
`1 + 1/LANES` -- 1.26x at `NORM_LANES = 4`, 1.07x at 16, which the unit's own
sweep covers as legal -- and it is no longer shape-invariant. The gate replaces
all of that with a single bit.

---

## 6. The composed draw

Two points, ONE SESSION, one tool at a time, on the BC-250, both through TRACK
LUTDIET's `sim/ooc_lutdiet_ports.tcl` and `ooc_lutdiet_run.sh` **unmodified**
with the flags NORMADAPT, NWROM, NWFIX and NORMURAM used, so the numbers sit on
their scale. `xcvu33p-fsvh2104-2L-e`, 5.0 ns, `-flatten_hierarchy none`, no
`opt_design`. Both reached `LUTDIET_DONE`. Artefacts and the runner:
`hw/fk33/results/rmswire_2026-08-30/`. Pinned tree `d49b385`, gain image
`norm_w_9b.hex` md5 `69f614a1515e1160f5dc9e8a9e72fdc3` (verified identical on
both boxes before the run).

The subject is `llama_top`'s `gvr` block extracted VERBATIM by
`sim/ooc_normadapt_extract.py`, from HEAD for the control and from this tree
for the composed point, so the diff between the two synthesised tops IS the
diff between the two `llama_top.vhd` files.

| | `ctl_flat` (HEAD) | `mem_bank` (composed) | delta |
|---|---:|---:|---:|
| **CLB LUT** | 67,318 | **5,265** | **-62,053, -92.2%** |
| **CLB FF** | 191,664 | **2,149** | **-189,515, -98.9%** |
| MUXF7 | 26,736 | **0** | -100% |
| MUXF8 | 13,296 | **0** | -100% |
| **Block RAM tile** | **171** | **177** | **+6** |
| RAMB36 | 171 | 171 | **0** |
| RAMB18 | 0 | 12 | +12 |
| URAM | 0 | 0 | 0 |
| DSP | 41 | 41 | 0 |
| CARRY8 | 268 | 279 | +11 |
| WNS @ 5.0 ns | +1.675 | **+0.971** | -0.704 ns |
| Fmax | 300.8 MHz | **248.2 MHz** | still over the 200 MHz target |
| synth time | 1,625 s | 425 s | 3.8x faster |

### 6.1 The control reproduced NORMURAM's number on a different machine

`ctl_flat` is the same configuration TRACK NORMURAM drew as `nu_u1` on the
WORKSTATION. Every field is identical: `lut 67318`, `ff 191664`, `bram 171`,
`f7 26736`, `f8 13296`, `carry8 268`, `dsp 41`, `wns 1.675`. Only the wall time
differs (1,625 s against 641 s). **That is the largest job on which CLAUDE.md's
"results are bit-identical between the boxes" claim has been checked**, and it
holds.

### 6.2 The composed saving is 72% LARGER than the standalone one, and the census says why

TRACK RMSMUX measured the UNIT standalone at `-36,109` LUT. The composed block
saves **`-62,053`**. The extra 25,944 is not scatter; it is two structures that
live in the ADAPTER and exist only because the unit's ports were flat.
MEASURED, object-level `get_cells` census, `census_ctl_flat.txt`:

```
root                  LUT   MUXF7   MUXF8       FF  example_cell
gvr.uw_data         19728    9328    4592       16  gvr.uw_data[5][0]_i_17
ARG                 17916    8704    4352        0  gvr.u_rms/ARG__18_i_57
sq                  17475    8704    4352        0  gvr.u_rms/sq_reg[1]_i_19
gvr.xw               5954       0       0    65536  gvr.xw[0][15]_i_4
gow.o                2887       0       0        0  gvr.u_rms/gow[1018].o_reg[65215]_i_1
# LUT primitives accounted: 68599 of 68599
```

* **`gvr.uw_data`, 19,728 LUT and 9,328 MUXF7 and 4,592 MUXF8, is the
  ADAPTER'S OWN read mux** -- `uw_data <= signed(ov((k+1)*MANT_W-1 downto
  k*MANT_W))`, a 4,096-to-1 16-bit select on the write-back pass. **It is
  absent from every standalone draw of either unit, so nobody had measured
  it.** It is the second-largest single root in the control and the memory
  port deletes it outright.
* `gvr.xw` is the staging array: 5,954 LUT and 65,536 flops.
* `ARG` and `sq` are the unit's own read muxes, 17,916 and 17,475, agreeing
  with RMSMUX's standalone census to the LUT.

The composed census is 6,038 LUT primitives fully accounted, **no root above
1,148, and not one MUXF7 or MUXF8 anywhere in the design**. `ARG` falls from
17,916 to 442 against RMSMUX's standalone 443.

`report_utilization` and the census agree in direction and magnitude at both
points (68,599 and 6,038 LUT primitives against 67,318 and 5,265 CLB LUTs, the
difference being packing), so there is no case here where the census has to
overrule the report.

### 6.3 THE BRAM TOTAL, which is what was asked for

**The gain image did not move: 171 RAMB36 in both points, to the tile.** This
lever's entire BRAM cost is **12 RAMB18 = 6 tiles**, exactly what TRACK RMSMUX
measured for the unit standalone. The two terms are additive and that is now
MEASURED rather than assumed.

DERIVED total, with the arithmetic shown:

```
composed A+B+C+D (compose4_2026-08-29/util_c4_synth.rpt)      246.5 tiles
  + the gvr block, composed, MEASURED here                    177.0
  =                                                           423.5 tiles

pb_core Block RAM Tile available                              576.0
  - Non-Assigned (shell cells inside the pblock)              203.5
  =                                                           372.5 tiles

deficit                                                        51.0 tiles
```

**Short by 51 tiles, which confirms the dispatcher's figure with the 177 now
measured instead of assumed.** Two things must travel with it:

1. **51 of the 423.5 is NOT this lever.** 171 tiles are TRACK NORMURAM's gain
   image and 6 are mine. Removing this composition would leave the deficit at
   45 tiles and cost 62,053 LUT.
2. **The 246.5 is an ASSUMPTION as much as a measurement.** It was drawn from
   `compose4_top`, whose own header says *"THE SUBSYSTEMS ARE NOT WIRED TO EACH
   OTHER"*, with `NORM_W_IMAGE` empty and the FLAT norm unit -- so its `gvr`
   contributes 0 BRAM and adding 177 is right only if nothing else in that
   draw already accounts for a gain store. Nothing does. What would falsify the
   sum is a single draw containing both, which does not exist.

**The obvious place to find 51 tiles is the gain image itself, and it is TRACK
NORMURAM's lever, not this one.** See open item 3.

### 6.4 Timing

WNS improves nothing and costs 0.704 ns: `+1.675` to `+0.971` at 5.0 ns, i.e.
300.8 MHz to 248.2 MHz. **Still comfortably over the 200 MHz target**, and
identical to RMSMUX's standalone `+0.971` -- which says the memory-backed unit
itself now sets the composed block's critical path and the adapter has come off
it. In the control the adapter and the unit were both on it.

### 6.5 What this draw does NOT cover

Stated plainly, because an OOC synthesis number is routinely read as a fit
result and it is not one.

* **It is not placement and it is not routing.** No placer ran, no router ran,
  and **the fit question is about ROUTING**. MEASURED on the composed design:
  placed occupancy 54,866 of 54,960 CLB, congestion level 7, 33,767 failing
  endpoints after placement, 20,000 of the 20,000 worst net-dominated, and the
  router thrashing (`iteration 1  69,858 -> 183,525 -> 111,513`). **Nothing in
  this document moves that.** At 7.029 LUT/CLB there is LESS routing resource
  per cell, not more.
* **It is one generate block, alone.** No shell, no other subsystem, no
  inter-subsystem nets, and no cross-subsystem resource merging. A block that
  is 92% smaller alone may merge differently in context.
* **It is `synth_design` with `-flatten_hierarchy none` and no `opt_design`.**
  That is deliberate and matches every number it is compared against, but it
  means the figures are pre-optimisation.
* **Two points, one session, one box.** No scatter measurement was taken here.
  RMSMUX measured scatter at `1.0000x` for the memory-backed unit (two
  identical-command draws byte-identical including census hashes) and that is
  the basis for not repeating it, but it was measured on the UNIT and not on
  this block. The control reproducing NORMURAM's `nu_u1` field for field across
  two machines is indirect evidence in the same direction.
* **Vivado's memory footprint here is the GAIN IMAGE, not the design.** Peak
  allocation 17,691 MB for the control and 17,696 MB for the composed point --
  the same, despite a 92% LUT difference. Anyone sizing a machine for this
  synthesis is sizing it for a 4.26 Mbit elaboration-time constant.

---

## 7. Teeth, with the attribution control

`sim/mutate_rmswire.sh`, full output in
`hw/fk33/results/rmswire_2026-08-30/mutation_matrix.txt`. Every row is run
three ways so that a kill can be ATTRIBUTED rather than credited to the newest
check by default: FULL, then with this track's new `wact_chk` assertion
neutralised, then with TRACK NORMURAM's pre-existing `wbusy`-at-`r_go`
assertion neutralised as well, leaving only the token landmarks
`sim/tb_llama_top_normw` has always had.

```
TAG    FULL          noWACT        noASRT        WHAT
R0     SURVIVES      -             -             CONTROL: clean tree
R1     SURVIVES      -             -             GATE REMOVED, load at full rate
R2     SURVIVES      -             -             LOAD 4x SLOWER, gate INTACT
R3     K:loadassert  K:loadassert  K:landmarks   LOAD 4x SLOWER AND GATE REMOVED
R4     K:landmarks   K:landmarks   K:landmarks   w: sub-word select reversed (m7)
R5     K:landmarks   K:landmarks   K:landmarks   w: bank write address off by one
R6     K:landmarks   K:landmarks   K:landmarks   x: read pass writes one address high
R7     K:landmarks   K:landmarks   K:landmarks   o: bank output consumed one cycle early
R8     K:landmarks   K:landmarks   K:landmarks   o: region write address off by one
R9     K:landmarks   K:landmarks   K:landmarks   the load never restarts
R11    SURVIVES      -             -             GW forced to 1 (resolution floor)
```

and the fourth column, the mirror of `noWACT`, run separately on the only row
where an assertion fires at all:

```
R3     onlyWA = K:wact      (NORMURAM's r_go assertion OFF, wact_chk ON)
```

### 7.1 The rows that do NOT bite are the important ones

**R1 and R2 are the whole argument that the S_GO gate is structural rather than
a cycle-count coincidence, and they are both SURVIVES.**

* **R1 removes the gate and leaves NORMURAM's `r_go` assertion in place, and
  survives.** That assertion fires exactly when the gate would have had to
  stall. Its silence over a two-token run is direct evidence that **the gate
  costs zero cycles**: the load always finishes before S_GO would have fired
  anyway, about three cycles early.
* **R2 makes the load FOUR TIMES SLOWER with the gate intact, and survives.**
  A blown budget becomes a stall instead of a wrong number.
* **R3 is R1 and R2 together, and it is killed.** The pair is the measurement:
  neither the gate alone nor a slow load alone is a fault, and the composition
  of them is.
* **R11 forces `GW` to 1 and survives**, as it must -- the values do not depend
  on the ROM's aspect ratio. It is the resolution floor, and it also confirms
  that the `GW = 1` variant discussed in open item 3 is functionally equivalent.

### 7.2 `wact_chk` EARNS ZERO KILLS, and that is stated rather than hidden

Reading the columns honestly:

* **R4 to R9 are earned entirely by the pre-existing token landmarks.**
  `K:landmarks` in all three columns. This track's checks contribute nothing to
  any of them, and neither does NORMURAM's.
* **R3's kill is also ultimately the landmarks'.** `noASRT` still kills. What
  the assertions buy on R3 is EARLIER detection with a message that names the
  fault, not detection.
* **`wact_chk` does discriminate** -- `onlyWA = K:wact` proves it fires when
  given the chance -- **but it never earns a kill another check would not have
  made.** Across eleven rows it is credited with nothing.

**So why keep it?** Because there is an answer to "what would it take for this
check to fail", and it is a change somebody is likely to make.
`wbusy` only ever CLEARS within an operation, so `wbusy = 1` at `S_RAW` implies
`wbusy = 1` at `r_go`; that is exactly why `wact_chk` cannot fire where
NORMURAM's does not, TODAY. The moment anyone relaxes the S_GO gate to reclaim
the `1 + 1/LANES` margin -- a plausible optimisation, and the one this
composition was originally expected to take -- the `r_go` assertion has to be
relaxed with it, and `wact_chk` becomes the only check standing on the real
deadline. It is a guard against a specific future edit, and it is labelled as
one rather than counted as detection it did not do.

### 7.3 The tap has teeth, and they are on the bench that uses it

Three mutations of `w_active`, judged by `sim/tb_rmswire_loadrace.vhd`, each
re-run with the value check and the exponent check disabled:

```
TAG    FULL        noVAL       noEXP       WHAT
T0     SURVIVES    -           -           CONTROL: the clean unit
T1     KILLED      KILLED      KILLED      tap blind to S_RAW (reports only S_EMIT)
T2     KILLED      KILLED      KILLED      tap tied high (no second rise)
T3     KILLED      KILLED      KILLED      tap tied low (no rise at all)
```

T1 is the interesting one: a tap that reports only the LATER pass makes the
derived safe boundary 1,030 cycles too generous, and the bench catches it
because row F -- which sits just inside what the tap now claims is safe -- stops
reproducing the oracle. It survives both attribution columns, so neither the
value check nor the exponent check alone is what earns it; the structural
`temit > traw` gate and the row predictions do.

**`sim/tb_llama_top_normw` cannot see any of T1 to T3**, because in a correct
design `wact_chk` never fires and the tap drives nothing else. That is the
division of labour: the gate row guards the values, this bench guards the
timing model, and neither substitutes for the other.

---

## 8. Measured and REJECTED -- do not retry

* **Relying on the cycle margin instead of gating.** MEASURED and DERIVED. The
  margin to `r_go` after the composition is **3 cycles at every shape**, and
  extending the budget to the unit's first `w` read buys only `1 + 1/LANES`
  (1.26x at `NORM_LANES = 4`, 1.07x at 16, both inside what the unit's own
  sweep declares legal). Worse, mutation row R2 shows what the alternative
  buys: with the gate present, a load made **four times slower** is a STALL
  and the design still passes; without it (row R3) it is a wrong number. Do
  not re-derive the margin and do not remove the gate to reclaim it. If it
  ever is removed, `wact_chk` is the check that has to stay.

* **Trusting an output comparison to police the `S_RAW` deadline.** MEASURED,
  row G: at `start_at = 1991`, 21 elements are read from the previous norm
  op's gain and the output is BIT-IDENTICAL to the oracle. Any future bench,
  assertion or review that concludes "the values match, so the timing is fine"
  is measuring the `S_EMIT` boundary, which is 1,030 cycles slacker. It needs a
  stimulus whose stale tail moves `max|raw|`, or a check on the deadline
  itself.

* **A bench for this at a small shape.** The old margin was `GW = 4.0000x` and
  SHAPE-INVARIANT, so a bench at `hidden = 64` genuinely exercised the ratio a
  build at 4096 had. The composed one is not: `crit_raw` and `crit_emit` both
  depend on `N`, `LANES` and the unit's fixed overhead, and small shapes are
  flattered. `sim/tb_rmswire_loadrace.vhd` runs at `N = 4096, LANES = 4` for
  that reason and takes 11 s; there is no cost to justify shrinking it.

* **Widening `sim/ooc_normadapt_extract.py` so the `gvr` block can use
  `work.util_pkg.clog2`.** Evaluated and rejected. The extractor's value is
  that "the diff between two generated files IS the diff between two
  `llama_top.vhd` files"; every area number this block has ever been given --
  NORMADAPT's, NWROM's, NWFIX's, NORMURAM's and this track's -- rests on that.
  Keeping the block self-contained with a local `log2c` costs eleven lines and
  touches no other track's file.

* **Sending this draw to the BC-250 without checking its peak.** See 8.1. It
  was sent there because the brief assigned that lane; Vivado's own report says
  the point peaks at **17.1 GB** on a **14 GB** box. It survived only because
  it was run inside a `MemoryHigh` scope with 46 GB of swap behind it. Do not
  repeat it: this point belongs on the workstation.

* **`sim/ooc_normadapt_extract.py --shift`.** It now aborts (`EXTRACT ABORT:
  --shift needs exactly one xw(k-2) write`) against this tree, because `xw` no
  longer exists. That is the correct behaviour -- it refuses rather than
  producing a probe that does not correspond to the design -- but the `na_shift`
  probe in TRACK NORMADAPT's write-up is no longer reproducible from HEAD. Its
  numbers stand for the trees they were measured on.

---

## 9. Measurement traps hit, including my own

### 9.1 The lane I was given could not hold the job resident, and THREE different memory numbers disagree

The composed `ooc_normadapt` at the real 9B shape with the populated gain image
was sent to the BC-250 because the brief assigned that lane. Three figures for
the SAME point, all MEASURED, all meaning different things:

| figure | value | what it is |
|---|---:|---|
| Vivado's own `Memory (MB): peak` | **17,691 MB = 17.3 GiB** | the tool's peak ALLOCATION. Swap can absorb it, and did. |
| summed `/proc/PID/VmRSS` over the tree (`ooc_lutdiet_run.sh`) | **11.94 GiB** | sampled RESIDENT set. Double-counts pages shared between forked workers, and misses whatever peaks between 5 s samples. |
| the cgroup's `memory.peak` | **not obtained** for `ctl_flat` | the scope had already exited when it was asked, and `systemd` reports `[not set]` on an inactive scope. |

**The summed-RSS figure is 5.4 GiB BELOW Vivado's own peak, and neither error
has a known sign.** TRACK NORMURAM's 14.03 GiB for this point was the
summed-RSS kind; my brief's 10.58-10.85 GB was for a UNIT draw, a different and
much smaller job. Vivado's own line is free, is printed at every phase, and
nothing in this project was reading it.

**It swapped; it did not thrash.** The box has 46 GB of swap and the job ran
inside `systemd-run --user --scope -p MemoryHigh=11G`, which reclaims and
throttles rather than killing. At the peak, 18.2 GB of swap was in use and
Vivado reported `free physical = 224 MB`; at completion the box was back to
12.8 GB free and 1.2 GB of swap. Load stayed near 1.2, no OOM killer fired, and
none of the compaction-thrash failure mode that hung the workstation on
2026-08-30 appeared. The cost was time: **synth 1,625 s here against
NORMURAM's 641 s on the workstation, 2.53x** -- roughly the box's own 2.3x plus
the swapping.

**And the cgroup figure reproduced CLAUDE.md's warning exactly.** Sampled every
30 s on the SECOND point while it ran:

```
MemoryHigh  = 11,811,160,064 bytes  (11.0000 GiB, the cap)
MemoryPeak  = 11,812,794,368 bytes  (11.0015 GiB)
over cap    =      1,634,304 bytes  (1.6 MB)
```

**That is the cap, not the peak.** `MemoryHigh` is a soft limit: the cgroup is
reclaimed and throttled rather than killed, so a job that wants more sits just
above the ceiling for as long as it wants more, and `memory.peak` records the
ceiling. Quoting 11.00 GiB as this point's footprint would be quoting the belt
back. It is reported here as evidence the belt WORKED and for no other purpose.
The honest sizing figures for this point are Vivado's own 17.3 GiB allocation
peak and the 11.94 GiB sampled resident set, and they disagree by 5.4 GiB.

### 9.2 The extraction harness has a narrower scope than the file it extracts

`clog2` is in scope inside `llama_top.vhd` and is NOT in scope inside the top
`sim/ooc_normadapt_extract.py` generates. So `constant LOG2N : natural :=
clog2(NN);` compiled, simulated and passed the whole gate, and failed only when
the extractor ran:

```
/mnt/storage/rmswire/tree_mem/ooc_normadapt_top.vhd:327:35: no declaration for "clog2"
```

Caught because both OOC tops were GHDL-elaborated BEFORE Vivado was asked to
spend an hour on them. That step cost forty seconds and would otherwise have
cost an hour of the assigned lane.

### 9.3 The source closure grew, and only the CONTROL rows could see it

`llama_top` now instantiates `rmsnorm_rs_mem`, which instantiates `vec_mem`.
`sim/regress.sh` computes its closure and stayed green throughout. The three
mutation harnesses read a HAND-MAINTAINED list out of
`sim/mutate_llama_top_kv.sh`, and every row of `mutate_rmswire.sh`'s first run
came back `NOBUILD`, the reason buried in a per-row `analyze.log`:

```
rtl/llama_top.vhd:2190:27: unit "rmsnorm_rs_mem" not found in library "work"
```

**The tell was that the CONTROL row failed.** A matrix whose control fails
measures nothing, and without a control row the eleven `NOBUILD`s would have
read as eleven survivors -- eleven mutations "the checks did not catch". Fixed
in `sim/mutate_llama_top_kv.sh` so all three harnesses get it.

### 9.4 A bench that only compares outputs measures the wrong deadline

Section 5, and it is the trap most likely to be repeated. The first model was
not sloppy: it was derived from the RTL, used a measured parameter, and was
correct about the mechanism it modelled. It was simply pointed at the wrong one
of two passes. The thing that caught it was making it predict a point it had
not been fitted to and letting the bench go red.

### 9.5 `regress.sh` reads the words in your report text

`FAIL_RE` matches `MISMATCH`, `\bFAIL\b`, `FAILED`, `DIVERGES`, `IS NOT`,
`IS WRONG` and `OUT OF TOLERANCE` anywhere in the output. This bench has rows
that are SUPPOSED to differ, so every such row is worded
`reproduces_oracle=false` and never with any of those tokens, and the expected
differences are `severity note`. A row reported honestly in the wrong words
turns the gate red for the right behaviour.

---

## 10. Open, not yet answered

1. **Does it route?** Unchanged and still the most important unknown. This is
   an OOC SYNTHESIS number for ONE generate block. It has no placement, no
   routing, no shell, no inter-subsystem nets and no cross-subsystem resource
   merging. **The fit claim is about routing and nothing here moves it.**
   `compose4_top` with both levers reaching `route_design` with zero nets with
   routing errors is the only thing that does.

2. **The BRAM total.** Section 6 gives what the composed `gvr` block costs. The
   dispatcher's DERIVED deficit assumed separately-measured units do not share;
   this draw tests that assumption for the two terms it contains and not for
   the composition with A+B+C+D.

3. **`GW = 2` for the gain image.** TRACK NORMURAM named it as the next
   measurement if BRAM binds, and it is that track's lever. **A `GW = 1` point
   is now also interesting and was NOT measured here**: the composed loader
   consumes one element per cycle regardless of `GW`, so `GW` no longer buys
   any load-rate margin at all -- it only sets the ROM's aspect ratio.
   ESTIMATE, assumption stated: at `GW = 1` the same 4.26 Mbit becomes
   266,240 x 16, which maps to about 130 RAMB36 in 2Kx18 mode against the
   171 measured at `GW = 4`; what would falsify it is a draw. It was not taken
   here because reshaping the gain ROM changes NORMURAM's measured 171 and is
   that track's number to move, and because the 266,240-entry constant is a
   4x larger elaboration on a lane that already does not fit.

4. **Whether the `wbusy` gate ever stalls -- ANSWERED for the bench shape,
   open for the build shape.** MEASURED: mutation row R1 REMOVES the gate and
   leaves TRACK NORMURAM's `wbusy`-at-`r_go` assertion in place, and it
   SURVIVES. That assertion fires exactly when the gate would have had to
   stall, so its silence over a whole two-token run is direct evidence that
   the load always completes before S_GO fires, i.e. the gate costs zero
   cycles. That is measured at `tb_llama_top_normw`'s shape (`hidden = 64`).
   At `hidden = 4096` it is DERIVED from `NN + 2` against `NN + 4`, which is
   the same three-cycle margin at every shape -- and three cycles is exactly
   why the gate exists rather than the margin. There is still no stall
   COUNTER, so nothing would report a stall that was non-zero but harmless.

5. **`NORM_LANES > 4`.** The unit's sweep covers 16 and the composed margin at
   16 is 1.07x, but nothing in this project has drawn or simulated the composed
   adapter at any lane count other than 4. The gate makes it safe by
   construction; the CYCLE COST of the stall at 16 is unmeasured.

6. **The `x` stream's residency is argued, not measured.** Its last word lands
   two edges before pass 1 reads address 0 and the margin grows with `N`, so it
   is not a race at any shape -- but no row of any bench perturbs `x` load
   timing, and `sim/tb_rmswire_loadrace.vhd` preloads `x` fully. If the read
   pass is ever made slower or the unit's pass 1 ever made earlier, nothing
   would notice.

7. **`nw_empty` is retired as a control on this tree.** The 49,654 LUT anchor
   that NORMADAPT, NWROM, NWFIX and NORMURAM all quote was a draw of a
   configuration -- flat port, foldable constant gain -- that `llama_top` no
   longer contains. Their conclusions stand for the trees they measured; the
   anchor is simply not reproducible from HEAD any more. Nothing has replaced
   it as a cross-track scale.
