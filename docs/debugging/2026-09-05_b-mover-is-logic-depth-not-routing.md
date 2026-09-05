# B's mover fits at last, and its -4.008 is 31 logic levels, not routing

**2026-09-05.** `sim/ooc_gdnadapt_extract.py` at commit `f2bbd50`, OOC
synthesis, `xcvu33p-fsvh2104-2L-e`, 5.000 ns constraint, Vivado 2023.2.

## The question

> B's data mover is the project's headline blocker at `-4.008 ns` (111 MHz
> against a 200 MHz target). That figure was taken at `e9beec9` against an
> extraction that went stale three hours later and then would not build at
> all. Does it still hold, does the block fit, and what actually limits it?

## The answers, up front

1. **`-4.008` REPRODUCES EXACTLY**, five commits and 225 body lines later.
2. **The mover FITS** once the state tier is enabled: BRAM **5,472 tiles
   (814% of the device) -> 50 (7.44%)**, via a generic, not a text hack.
3. **The critical path is LOGIC DEPTH, not routing: 31 levels, 77.7% logic.**
   No implementation directive can fix it, and the arithmetic says so.
4. **It is invariant to the memory architecture** -- bit-identical `-4.008` in
   all three configurations -- but failing endpoints collapse **110,298 -> 858**,
   so it is now nearly isolated instead of pervasive.

## The matrix

`GDNADAPT_MAXROWS` at the sizes the original figure was taken at, crossed with
the generic that `5f1db1a` introduced:

| | 64, flat | **64, state tier** | 256, flat |
|---|---|---|---|
| CLB LUTs | 127,260 | **65,044** | 129,224 |
| LUT as Logic | 91,883 | 52,931 | 93,751 |
| LUT as Memory | 35,377 | 12,113 | 35,473 |
| CLB Registers | 46,279 | 37,997 | 49,317 |
| CARRY8 | 2,074 | 2,125 | 2,074 |
| **Block RAM tile** | **5,472 (814%)** | **50 (7.44%)** | **5,472 (814%)** |
| URAM | 0 | **32** | 0 |
| DSP | 191 | 194 | 191 |
| **WNS** | **-4.008** | **-4.008** | **-4.008** |
| TNS | -16,291.768 | **-2,627.843** | -16,291.755 |
| failing endpoints | 110,298 | **858** | 110,298 |
| total endpoints | 688,996 | 198,064 | 693,024 |

Against the 2026-09-03 record (`MAXROWS` 64: 127,260 / 91,883 / 46,279 / 5,472
/ -4.008; 256: 129,224 / 93,751 / 49,317 / 5,472 / -4.008) every figure agrees.

**The URAM row confirms the project's existing rule from the other side.**
`CLAUDE.md` records that URAM cannot hold an initialised table, so a ROM
request is refused and silently served from BRAM. Here the state store is
written at RUN TIME, and it takes 32 URAM without complaint. URAM is available
to a store, not to a constant.

## The critical path

```
Slack (VIOLATED):  -4.008ns
Source:       a0/DSP_A_B_DATA_INST/CLK
Destination:  gb_real.u_gdn/u_conv/p1_reg[3][3]/DSP_A_B_DATA_INST/A[24]
Data Path Delay: 8.674ns  (logic 6.739ns = 77.692%,  route 1.935ns = 22.308%)
Logic Levels: 31  (CARRY8=4 DSP_A_B_DATA=2 DSP_ALU=5 DSP_M_DATA=3
                   DSP_MULTIPLIER=3 DSP_OUTPUT=5 DSP_PREADD_DATA=3
                   LUT1=1 LUT2=2 LUT5=2 LUT6=1)
```

Five DSP tiles chained COMBINATIONALLY through `PCOUT`, inside `gdn_conv`:

```
0.585  1.507 f  a0/DSP_ALU_INST/ALU_OUT[47]
0.122  1.629 r  a0/DSP_OUTPUT_INST/PCOUT[47]
0.546  2.189 r  a/DSP_ALU_INST/ALU_OUT[7]
...
0.505  3.303 f  ARG__17/DSP_MULTIPLIER_INST/U[28]
0.585  3.935 f  ARG__17/DSP_ALU_INST/ALU_OUT[47]
0.122  4.057 r  ARG__17/DSP_OUTPUT_INST/PCOUT[47]
0.546  4.617 r  ARG__18/DSP_ALU_INST/ALU_OUT[2]
0.037  5.026 r  gb_real.u_gdn/u_conv/ARG__16_i_22/O          (LUT1)
0.170  5.228 r  gb_real.u_gdn/u_conv/ARG__16_i_18/CO[7]      (CARRY8)
0.505  6.504 f  ARG__16/DSP_MULTIPLIER_INST/U[18]
```

## Why this matters more than the number

**77.7% of the delay is LOGIC.** Every timing lever this project has pulled --
`Performance_NetDelay_high`, `ExtraTimingOpt`, `AggressiveExplore`,
`NoTimingRelaxation`, the post-route phys_opt chain -- moves ROUTING. Routing
is 1.935 ns of an 8.674 ns path. **Even driving route delay to zero leaves
6.739 ns against a 5.000 ns period, i.e. WNS -1.739 and still failing.**

That is a closed-form refutation, not an estimate: no directive, no seed, no
strategy and no placement can close this gap. It has to be pipelined.

`gdn_conv` IS pipelined at the RTL level -- `xf/wf` -> `p1` (multiply) -> `p2`
(shift) -> `accr` (sum), four stages, `rtl/gdn_conv.vhd:280-325`. The cascade
above is Vivado chaining the adder tree at :320-324 (`sum := sum + resize(...)`)
into DSP ALUs through PCOUT, together with the exponent/shift arithmetic at
:263-270, and arriving at `p1`'s A input. The stages exist; the work BETWEEN
two of them is five DSPs deep.

## Measured and REJECTED -- do not retry

- **Implementation directives on this block.** Refuted by arithmetic above, not
  by trial. Route is 22% of the path.
- **Blaming the 5,472-tile array for the timing.** The BRAM count changes by a
  factor of 109 between columns and WNS does not move one picosecond.
- **`--state-store` to get the fitting configuration.** Superseded; it emits
  unbalanced generates and now refuses. Use `-generic B_STATE_AXI=true`.
- **Running the extraction without `GDNADAPT_MAXROWS`.** Vivado dies with
  SIGNAL 11, not an error: `[Synth 8-3391] ... number of bits (196608) is too
  large`. Measured again today by forgetting it, twice.

## Measurement traps hit

- **A waiter's status is not the job's.** Two waiters were killed by the
  harness; both times the job was fine and finished. Gated on
  `BMOVER2_DONE`, a sentinel the work writes, and on `rc`.
- **`memory.peak` of a capped job is the cap.** The cgroup read
  `memory.current = memory.peak = memory.high = 13.00 GB` exactly. That says
  the throttle works, not what the job wants.
- **I explained the reproduction with a mechanism I had not checked.** I wrote
  that the 225 lines of drift "were almost entirely the inactive state tier".
  MEASURED: of 172 added CODE lines, **49%** are state-tier or tap; the rest
  are real logic from three other commits (a `min4` function, a `gb_start`
  signal). **Why those cost exactly zero LUT, zero FF and zero picoseconds is
  NOT established.** The tidy explanation was wrong and the invariance is more
  surprising than it made it sound.

## Open, not yet answered

- **Which expression to pipeline.** The path crosses the adder tree and the
  exponent/shift arithmetic; attributing the 31 levels to specific source
  lines needs an object-level census, not inference from one report.
- **What the fix costs.** Adding a stage changes `gdn_conv`'s latency, and
  every consumer of its handshake has to tolerate that. Not free.
- **Whether 858 failing endpoints are one path or many.**
  `report_timing_summary` printed one. `-max_paths` would say.
- **Subsystem C's 151.3 MHz** has had no equivalent analysis. Its extractor is
  in sync (measured, body drift 0) so the measurement is available cheaply.


---

## LEAD, 2026-09-05, not yet confirmed: the path may be SYNTHETIC WEIGHTS

Traced by reading, after the write-up above. Recorded as a LEAD, not a result,
because the discriminating run had not returned when this was written.

The path ends at `p1_reg[3][3]/DSP_A_B_DATA_INST/A[24]`. `p1` is
`xf * wf` (`rtl/gdn_conv.vhd:300`), and both operands are registered, so
Vivado absorbs them into the DSP's own A/B registers -- which means the delay
arriving at that pin is the combinational path computing `x_in`/`w_in`, from
OUTSIDE `gdn_conv`.

`cv_w` and `cv_x` are produced by `cvdata_p` in `llama_top`'s `gb_real`, and
that process is deliberately combinational (`rtl/llama_top.vhd:4106`: *"the
producers are separate processes: `cv_x` has to be combinational"*). Its first
act is to build the conv WEIGHTS:

```vhdl
wv(b+15 downto b) :=
  std_logic_vector(m12(cvq_seg*65537 + cvq_grp*13, t*101 + ln + 5));
```

`m12` is a 32-bit LCG:

```vhdl
t := to_unsigned(a mod 1048576, 32) * to_unsigned(1103515245, 32);
x := t(31 downto 0) + to_unsigned((b mod 100000) * 12345, 32);
x := x xor shift_right(x, 15);
t := x * to_unsigned(668265261, 32);
x := x xor shift_right(x, 13);
```

**TWO SERIAL 32x32 MULTIPLIES, combinational.** A 32x32 does not fit one
DSP48E2 (27x18), so each becomes a cascade of tiles -- which is exactly the
observed shape: `DSP_MULTIPLIER=3`, `DSP_ALU=5`, `DSP_OUTPUT=5`, chained
through `PCOUT`, ending at the conv multiply's operand pin.

**If this holds, B's headline blocker is measuring a TEST-PATTERN GENERATOR.**
The comment above the loop says it outright -- *"The conv WEIGHTS are learned
constants in every configuration"* -- meaning in the shipping design they come
from memory, and this hash exists only to supply them in simulation and OOC.
It would generalise the project's existing finding that `B_SRC_REAL`'s
degenerate-residual rise is a property of the STIMULUS rather than the design:
the synthetic weights would distort not just VALUES but TIMING and AREA.

**WHY IT IS NOT YET A RESULT.** The evidence is circumstantial: a shape match
between the primitive histogram and what two serial 32x32 multiplies should
produce, plus the path terminating on the operand pin those weights feed. That
is a hypothesis about which cells are on the path, and this project's record on
attributing a number by resemblance is bad -- the `gdn_block` BRAM
misattribution was exactly this, and it came with an agreeing cross-check.

**THE DISCRIMINATING RUN**, launched rather than argued: a DSP census
(`get_cells -hier -filter {PRIMITIVE_GROUP == DSP}`) plus the 15 worst paths
with start and end pins. If the DSPs on those paths sit in the weight
generator and not in `gdn_conv`'s MAC, it is confirmed; if they are the MAC's,
the logic-depth conclusion stands as written and this lead is dead.

Either way the headline conclusion above -- that no implementation directive
can fix a path that is 77.7% logic -- is unaffected. What changes is WHAT has
to be pipelined, and whether it is in the shipping design at all.


---

## CONFIRMED, 2026-09-05: the path IS the synthetic weight hash. And C is the OPPOSITE.

The discriminating run returned. The lead above is **confirmed**, by two
independent pieces of evidence, and the same run attributed C's path for the
first time since 2026-08-31.

### B: confirmed, by bit index and by fan-out shape

**1. Bit indices a 16x16 multiply cannot produce.** The path traverses

```
a0/DSP_MULTIPLIER_INST/U[43]
a0/DSP_ALU_INST/ALU_OUT[47]
```

`gdn_conv`'s MAC is `signed(16) * signed(16)` (`rtl/gdn_conv.vhd:300`), whose
product is 32 bits. **Bit 43 and bit 47 are unreachable from it.** The only
multiplies wide enough are `m12`'s two 32x32, which build a 64-bit `t`. This
is decisive on its own and it was sitting in the first timing report.

**2. All 15 worst paths share ONE startpoint**, `a0/DSP_A_B_DATA_INST/CLK`,
at a constant 31 levels, fanning out to `p1_reg[t][ln]`'s **A** input across
`[1][1] [1][3] [2][0] [2][2] [3][1] [3][3]`:

```
B PATH  1 slack -4.008 levels 31 start a0/...CLK end .../p1_reg[3][3]/...A[24]
B PATH  4 slack -3.989 levels 31 start a0/...CLK end .../p1_reg[3][1]/...A[24]
B PATH  5 slack -3.983 levels 31 start a0/...CLK end .../p1_reg[1][1]/...A[24]
```

That is the signature of a **shared subexpression**. In
`m12(cvq_seg*65537 + cvq_grp*13, t*101+ln+5)` the first argument is IDENTICAL
for all sixteen `(t,ln)`, so Vivado computes `(a mod 1048576)*1103515245` once
-- that is `a0` -- and every lane continues from it. One source, sixteen
destinations, constant depth. The conv MAC has no such shared term.

### What this means, stated carefully

**B's `-4.008` / 111 MHz does NOT characterise the shipping design.** The
critical path is a test-pattern generator. `cvdata_p`'s own comment says the
conv weights "are learned constants in every configuration"; in the shipping
design they come from memory, and this combinational LCG exists only to supply
them in simulation and OOC.

**It does NOT follow that B is fast.** Removing the hash means sourcing weights
from memory, which this harness does not do. **B's real fmax is UNKNOWN, not
acceptable.** The correct statement is that the number three documents quote as
the headline blocker is measuring something that will not be built.

This generalises the recorded `B_SRC_REAL` finding from VALUES to TIMING AND
AREA: synthetic stimulus distorts both, and the distortion is large enough to
have set the project's priorities.

### C: 151.3 MHz attributed, and it is ROUTE-bound

`sim/ooc_cattnadapt.tcl` extracts WNS by regexp and never printed a path, so
this figure had been quoted for five days with nothing behind it.

```
Slack -1.611ns
Source:       gcr.u_attn/vhdr_reg[0]/C
Destination:  gcr.u_attn/vref_r_reg[10][6]/D
Data Path Delay: 6.593ns  (logic 2.361ns (35.8%)  route 4.232ns (64.2%))
Logic Levels: 23  (CARRY8=7 LUT2=1 LUT3=3 LUT4=2 LUT5=4 LUT6=6)
```

Seven of the fifteen worst paths are the same source to `vref_r_reg[N][6]`
with N = 2, 6, 10, 14, 18, 22, 26 -- one per head, all at exactly -1.611.

**C is the MIRROR IMAGE of B: 64.2% ROUTE against B's 77.7% LOGIC.** So the
implementation-directive lever, which arithmetic forbids for B, is precisely
the right lever for C. And an OOC route estimate with an unconstrained boundary
is systematically pessimistic, so 4.232 ns is an upper bound rather than a
measurement of the final design.

**Both headline blockers are therefore much weaker than recorded**, for
opposite reasons, and neither was ever attributed before today.

## Measurement trap hit in this run

**`get_cells -hier -filter {PRIMITIVE_GROUP == DSP}` matched NOTHING** --
`WARNING: [Vivado 12-180] No cells matched`. The census printed zero lines and
the run still reported success, so a reader counting `BDSP` lines would have
concluded the design has no DSPs while `report_utilization` says 194. The
recorded idiom in `CLAUDE.md` is `REF_NAME =~ RAM*`; the DSP equivalent is
`REF_NAME =~ DSP*`, not `PRIMITIVE_GROUP`. **A `get_cells` filter that matches
nothing is a WARNING, not an error**, which is the same silent-empty-result
shape as the residency checker that printed PASS over an object it never read.

The attribution did not depend on it: the bit indices and the fan-out pattern
settled the question from the timing paths alone.


## AND NEITHER NUMBER IS A ROUTED RESULT

MEASURED: `grep -cE 'opt_design|place_design|route_design' sim/ooc_cattnadapt.tcl`
returns **0**. That harness calls `synth_design`, `create_clock`, and reports.
So does the B harness. **Both `-4.008` and `-1.611` are POST-SYNTHESIS
estimates with ESTIMATED routing**, quoted as blockers for a week.

**This caveat weakens the two numbers by very different amounts, and the split
above says by how much:**

- **B is barely affected.** 77.7% of its path is LOGIC delay -- primitive
  propagation through DSP tiles, which synthesis models well because it is a
  property of the cells, not of where they land. The 6.739 ns is close to real,
  and the conclusion that no directive can fix it survives regardless.
- **C is badly affected.** 64.2% of its path is ROUTE, which is exactly what a
  pre-placement estimate models WORST. A post-synthesis WNS on a route-bound
  path is not a result; it is a guess about placement that has not happened.

An implementation run for C is in flight to replace the estimate with a routed
number, reporting WNS at synth / opt / placed / physopt / routed so the size of
the estimate's error is measured rather than asserted.

---

## C IMPLEMENTED: 155.3 MHz routed, and my prediction about the estimate was WRONG

`ooc_cattnadapt_top`, same generics, taken all the way through routing.

```
CIMPL_WNS synth   -1.611     151.3 MHz
CIMPL_WNS opt     -1.611     151.3 MHz
CIMPL_WNS placed  -0.964     167.7 MHz
CIMPL_WNS physopt -0.805     172.3 MHz
CIMPL_WNS routed  -1.438     155.3 MHz
route status: 140,959 routable, 140,959 fully routed, 0 with routing errors
```

**WITHDRAWN: "a post-synthesis WNS on a route-bound path is not a result, and
4.232 ns of route is an upper bound."** I wrote that an hour ago, reasoning
that a route-bound path must be badly modelled before placement. MEASURED: the
synthesis estimate was pessimistic by **0.173 ns** -- 151.3 against 155.3 MHz.
The estimate was good. The reasoning predicted a large error and the
measurement shows a small one, so the mechanism I proposed was not the one
operating. **A plausible mechanism is not a measurement, even when the
direction it predicts turns out to be right.**

### phys_opt over-promised again, and this is now a PATTERN with two observations

| design | phys_opt (pre-route) | routed | given back |
|---|---|---|---|
| composed top, this morning | **+0.006** | -0.422 | **0.428 ns** |
| C's mover, this run | **-0.805** | -1.438 | **0.633 ns** |

Both clean routes, both on this device, both large enough to invert a verdict.
**Do not read a `phys_opt_design` WNS as a result on this part.** The composed
run would have been reported as "meets 200 MHz" on its pre-route number.

### C's path, attributed

```
Slack -1.438ns   gcr.u_attn/vhdr_reg[312]/C -> gcr.u_attn/vref_r_reg[14][2]/D
Data Path Delay 6.419ns  logic 2.730 (42.5%)  route 3.689 (57.5%)
Logic Levels 23  (CARRY8=7 LUT2=1 LUT3=5 LUT4=1 LUT5=3 LUT6=6)
```

**THIS PATH HAS ALREADY BEEN FIXED ONCE.** `rtl/attn_block.vhd:662-685` records
TRACK TIMING (2026-08-30) rebuilding the SEAM 2 write-time fold from a SERIAL
compare-select chain seeded on `vref_r` into the balanced `emin_tree`, because
the serial form was **28 logic levels** and "every one of the forty worst paths"
in the composed design. That fix is real and it worked: the path is now **23**.
It did not go far enough.

What remains is `vhdr` -> the balanced min-tree over `NBLK` block exponents ->
the subtract against `vref_r` at `:1018`
(`s := to_integer(e_of(vhdr, opb)) - to_integer(vref_r(...))`) -> back into
`vref_r`. The seven CARRY8 are the 8-bit compares and that subtract.

Unlike B's, **this is the real design and the number is a routed one.** C is
genuinely 155.3 MHz against a 200 MHz target, and closing 1.438 ns needs the
reduction split across a cycle rather than re-bracketed again -- re-bracketing
is the lever TRACK TIMING already pulled.

---

## THE STIMULUS DOMINATES THE WHOLE BLOCK, not one path

400 worst paths pulled from the same synthesis, to find the worst path that is
NOT the weight hash. There isn't one in 400.

```
BNS_DSP_COUNT 1746            (= 194 DSP tiles x ~9 sub-cells; report_utilization says 194)
400 paths pulled, slack range -4.008 .. -3.226
startpoints:  373  a0/DSP_A_B_DATA_INST/CLK
               27  a[-1111111108]/C
```

Both are Vivado-generated arithmetic cells, not datapath registers, and the
second group ends in `gb_real.u_gdn/u_scal/...` -- `gdn_scalar`, a DIFFERENT
sub-block from the conv. So this is not one cascade feeding one place.

`llama_top`'s own header says why: at the default generics B's **conv taps,
conv weights AND scalars** are all *"deterministic functions of index"*. Every
input the block has is manufactured by combinational hash arithmetic, so that
arithmetic owns the entire top of the timing report.

**Therefore the OOC extraction cannot measure B's datapath timing at all.**
Not "measures it pessimistically" -- cannot measure it. The 400 worst paths
belong to a test-pattern generator that the shipping design will not contain.

**The one bound this does give:** B's datapath worst path is better than
**-3.226 ns**, i.e. **> 121.6 MHz**, because nothing in the 400 worst belongs
to it. That is weak, and it is still better than the -4.008 / 111 MHz the
project has been quoting as B's blocker.

**What a real measurement needs:** a harness that drives the block's taps,
weights and scalars from REGISTERS or memory rather than from index functions.
That does not exist. Building it is the actual prerequisite for knowing whether
B meets 200 MHz, and it is a smaller job than pipelining a path that may not
be in the design.

**The census filter, retried and reconciled.** `REF_NAME =~ DSP*` returns 1746
where `PRIMITIVE_GROUP == DSP` returned 0 with only a WARNING; 1746/9 = 194,
matching `report_utilization` exactly. The arithmetic is the check that the
filter is now right, rather than merely non-empty.

---

## THE ANSWER: B's compute MEETS timing. The blocker was stimulus, end to end.

Startpoints restricted to sequential cells inside `gb_real.u_gdn` -- the real
`gdn_block` -- so the reported paths BEGIN in the datapath rather than in a
generator. The set is 52,045 cells, so the empty-set abort did not fire.

```
BDP_INNER_SEQ_CELLS 52045
Slack (MET) : 0.837ns
  Source:       gb_real.u_gdn/u_exp/e_t_r_reg[9]/C
  Destination:  gb_real.u_gdn/u_conv/shf_reg[0][0]/R
  Data Path Delay: 4.046ns  (logic 1.286ns (31.8%)  route 2.760ns (68.2%))
  Logic Levels: 14  (CARRY8=5 LUT3=1 LUT4=3 LUT5=3 LUT6=2)
25 worst restricted paths span +0.837 .. +1.161, all from the same startpoint
```

**POSITIVE SLACK. 0.837 ns of margin at 5.000 ns = 240.2 MHz**, against the
111 MHz quoted as B's blocker in three documents.

### Cross-validated against a measurement the repo already had

| method | result |
|---|---|
| 2026-09-03, `gdn_block` synthesised ALONE | **+0.483 -> 221 MHz** |
| today, startpoints restricted to `gdn_block` INSIDE the mover | **+0.837 -> 240 MHz** |

Two independent methods, both positive, both comfortably past 200 MHz.
`docs/debugging/2026-09-03_b-mover-does-not-fit.md:41-44` had already written
*"Everything else in the block is fine ... The mover's `-4.008` therefore
belongs to the mover, not to the compute."*

**That conclusion was right and it stopped one step short.** It established
WHERE the -4.008 lives; nothing established WHAT it is. Today: it is the
synthetic input generation -- `m12`'s two serial 32x32 multiplies for the conv
weights, and the index functions for the taps and scalars -- all of which the
shipping design replaces with memory reads.

### What is and is not established

**ESTABLISHED.** B's compute block meets 200 MHz with margin, twice over. The
-4.008 / 111 MHz figure measures test-pattern generation and does not describe
anything that will be built. **B has no demonstrated timing blocker.**

**NOT ESTABLISHED.** The mover's OWN logic -- address generation, handshakes,
buffering, the region-file port -- is still unmeasured, because it sits in
`gb_real` alongside the generators and the generators own all 400 worst paths.
Its worst path is somewhere better than -3.226 ns and that is all this run can
say. **"B has no demonstrated blocker" is not "B is finished."**

**THE NEXT MEASUREMENT** is therefore a harness that drives taps, weights and
scalars from registers or memory, which would expose the mover's real logic in
the ordinary timing report. That is a smaller job than pipelining `gdn_conv`,
and pipelining `gdn_conv` would have been work spent on a path that is not in
the design -- which is exactly where the -4.008 was pointing.

---

## CORRECTION, same session: "B has no demonstrated timing blocker" NEEDS THE CONTEXT CAVEAT

**WITHDRAWN as written.** It is true of `gdn_block` in ISOLATION and false of
the composed design, and the composed number is the one a bitstream depends on.

`hw/fk33/rtl/compose4_top.vhd` instantiates `gdn_block` DIRECTLY and its
`cv_x`/`cv_w` are top-level PORTS (`:945-946`, `:2176-2177`), so nothing in it
manufactures inputs. Checked by DEFINITION, not by name: `function m12` occurs
**0** times there and the constants `1103515245` / `668265261` occur **0**
times.

**A trap on the way, worth recording because I nearly published it.** A first
grep for `m12` in `compose4_top.vhd` returned **58 hits** and I briefly took
that as the hash being present. They are `a_eng_m12_axi_*` -- **AXI master 12**
of the A engine. A substring, not the function. *Grep for the thing, not for
the word that names it* -- the same rule this project already carries about
searching for a port of the right width rather than for a spelling.

So the composed per-block census stands, uncontaminated:

| hierarchy | failing endpoints | worst slack |
|---|---|---|
| `c_attn` | 990 | -0.401 |
| `b_gdn` | 986 | **-0.402** |
| `a_eng` | 319 | -0.338 |
| `d_norm` | 66 | -0.168 |

### The honest three-line summary of B

| measurement | result | real? |
|---|---|---|
| `gdn_block` alone, and restricted-startpoint inside the mover | +0.483 / +0.837 | yes, and it MEETS |
| OOC mover total, `-4.008` / 111 MHz | stimulus generators | **no, discard it** |
| composed `b_gdn`, routed, in context | **-0.402** | **yes, and this is the blocker** |

**B's real problem is CONTEXT, worth 0.885 ns** (+0.483 alone to -0.402
composed): placement pressure, fanout and congestion inside a 267k-LUT design,
not the block's own logic and not the mover's stimulus.

That is a different problem from the one the project has been carrying, and it
has a different shape: a context penalty responds to floorplanning, placement
directives and congestion relief, whereas the block's own arithmetic depth
would not have. It is also **shared** -- `c_attn` -0.401, `a_eng` -0.338 and
`d_norm` -0.168 sit alongside, three independent subsystems within 0.064 ns,
which is the signature of a global effect rather than four separate defects.

**What today changed** is that two of B's three numbers are now known to be
either fine or fictitious, leaving exactly one real target instead of three.

---

## C's number is measured 8x off its own spec value. Run in flight.

The composed `c_attn` (-0.401) and the OOC `ooc_cattnadapt` (-1.438) differ by
**1.037 ns on the same internal path** (`u_attn/vhdr_reg` -> `u_attn/vref_r_reg`).
For a register-to-register path inside the same block that gap needs a cause.
It is not context. **They are different design points.**

| | HEAD_DIM | KV_BLOCK | NBLK = HD/KV_BLOCK | LAYERS |
|---|---|---|---|---|
| composed `c_attn` | 256 | **32** (by omission = block default) | **8** | 8 |
| OOC `ooc_cattnadapt` | `SHAPE.attn_head_dim` (9B) | **4** | **8x larger** | `nlay(SHAPE)` |

`rtl/attn_block.vhd:223`:

```vhdl
KV_BLOCK  : positive := 32;   -- C spec 2.1.1, and one 256-bit HBM beat
```

**32 is the spec value.** `sim/ooc_cattnadapt.tcl:40-41` defaults to
`($kv eq "true" ? 16 : 4)`, so every C measurement to date -- the 151.3 MHz
quoted since 2026-08-31 and today's 155.3 MHz routed -- was taken at **4**.

`NBLK` sizes the `emin_tree` reduction, which is **exactly the structure on C's
critical path**. KV_BLOCK 4 makes NBLK eight times larger, i.e. three more
levels of the reduction TRACK TIMING rebuilt in the first place. So C's number
is measured on a tree three levels deeper than the composed design builds.

**This is the same shape as B's finding**: the OOC harness measures a
configuration that is not the shipping one. B's was manufactured inputs;
C's is a generic default 8x off spec. Neither is a defect in the design.

A fully implemented run at `KV_BLOCK=32` is in flight. **What it cannot
settle**: whether 32 or 4 is right for the 9B shape at the FULL layer count --
the composed top runs LAYERS=8 and HEAD_DIM=256, which is not the 9B shape
either. Two variables differ between the two measurements and this run pins
only one.
