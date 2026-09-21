# The header tree does not synthesise, and no bench in this repository could have said so

TRACK HDRCOST, 2026-09-20. Part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, BC-250
lane (`cachyos-bc250`). No hardware. `synth_design`, `opt_design`,
`place_design`, `route_design` and `report_*` only; the card was live and
serving the user throughout and was never touched.

---

## 1. The question, verbatim

> TRACK SCOREHDR (`56d13e3`) added `SCORE_HDR_TREE` to
> `rtl/attn_score_q12.vhd` [...] **Its area and timing are UNMEASURED, and
> that is the only reason it is not in build 11.** [...] SCOREHDR's own
> ESTIMATE is +130 to +200 LUT and +34 FF per score unit, x4 in `attn_block`,
> so +520 to +800 LUT and +136 FF. [...] **If the tree measures cheap, it
> REPLACES `SCORE_EARLY` in build 11 rather than adding to it.**
>
> REPORT, and lead with the recommendation: **does `SCORE_HDR_TREE=1` replace
> `SCORE_EARLY` in build 11, or wait for build 12?**

Symptom numbers the question was framed against: the shipped card places at
**CLB 54,854 of 54,960 (99.81%, 106 free)** and routes at **WNS +0.061 ns**;
`SWEEP_PIPE`+`SCORE_HDR_TREE=1` measures **231.11** cycles per position against
`SWEEP_PIPE`+`SCORE_EARLY`'s **231.17**, i.e. the two are interchangeable.

---

## 2. The answer, up front

**NEITHER. `SCORE_HDR_TREE=1` DOES NOT SYNTHESISE, SO IT HAS NO AREA AND NO
TIMING TO MEASURE.** The first Vivado ever run on the generic killed
`synth_design` in **49 seconds**:

```
ERROR: [Synth 8-11324] array index 8 out of range [rtl/attn_score_q12.vhd:488]
ERROR: [Synth 8-285] failed synthesizing module 'attn_score_q12' [rtl/attn_score_q12.vhd:244]
ERROR: [Synth 8-285] failed synthesizing module 'attn_block' [rtl/attn_block.vhd:486]
```

at `HDR_TREE = 1`, `NBLK = 8`, the card's own geometry. The whole area and
timing question the brief posed is **unreachable**: there is no netlist.

**BUILD 11 KEEPS `SCORE_EARLY`, AND IT COSTS ALMOST NOTHING.** MEASURED, same
tree, same flow, one variable: `SCORE_EARLY` is **+5 CLB LUT and +2 flip-flops**
on an 86,891-LUT block, with CARRY8, F7, F8, block RAM, DSP48E2 and the entire
`attn_score_q12` cone **bit-identical**. That is the first measured number
either C lever has ever had, and the +2 FF confirms TRACK MIDGAP's DERIVED
"2 flip-flops plus control" exactly.

**THE DEFECT IS ONE LOOP BOUND AND THE FIX IS ONE LINE.** Line 488 is the
odd-level carry `wv(i) := wv(2*i)` inside `for i in 0 to NBLK-1 loop`. The
fix is `for i in 0 to TW-1 loop`, where `TW = (NBLK+1)/2` is already declared
in the file. MEASURED simulation-identical at all 20 points of SCOREHDR's own
grid, teeth-tested, and measured in Vivado; see sections 5 and 7.

---

## 3. Why no bench could have found it, and why that generalises

`wv` is `e_arr_t`, `array (0 to NBLK-1)`, so at `NBLK = 8` its legal indices
are 0..7. The fold loop runs `i` from 0 to `NBLK-1 = 7` and the odd-level
branch reads `wv(2*i)`, which reaches **wv(14)**.

It is unreachable at run time. `i` is guarded by `if i < nn`, and `nn` is at
most `ceil(wn/2) <= 4`, so no execution ever evaluates `wv(8)` or beyond.

**GHDL evaluates the branch a run actually takes. Vivado elaborates the whole
unrolled loop statically.** So the index that is never computed is never
checked in simulation and is always checked in synthesis. The two tools are
asking different questions and only one of them was ever asked.

**The sibling branch survives, and the contrast is the mechanism.** Lines
475-478 read `wv(2*i + 1)` and `wv(2*i)` under `if 2*i + 1 <= wn - 1`, and
Vivado folds that guard against `wn`'s subtype (`integer range 0 to NBLK`) to
bound the index into range. Vivado reported 488 and not 475, which is how we
know the guard is what saves the first branch. **The else branch carries no
relation between `i` and the array bound at all**, and that is the whole
defect.

**What the lever HAD passed while being unsynthesisable:** a 20-point
bit-exact grid (`NBLK` 3/5/6/7/8 x `HDR_TREE` 0/1/2/3), two independent C
oracles (`ref/attn_block_vec.c` over 130 values and
`ref/attn_block_seq_vec.c` over 2,056 outputs and 2,176 HBM record bytes), a
23-row mutation suite with an attribution control on every row and a ten-seed
sweep on every survivor, and five green gate groups. **None of them is a bad
test. Every one of them answers a question that is not this one.**

This is CLAUDE.md's own recorded rule arriving in a new place. That file
already says, of two block-design port errors, *"Neither error is reachable by
any bench, so no amount of simulation finds them"*, and prescribes `--bd-only`
at 3 minutes as the cheap discriminator. **The same argument applies one level
down to plain RTL and nothing scheduled it**: a generic that changes which
statements elaborate has a synthesis-reachable failure mode that no bench in
this repository can see, and `SCORE_HDR_TREE` is exactly such a generic.

**It also inverts one of SCOREHDR's own claims in place.** Its comment on the
very branch that fails says:

> ODD LEVEL: the last entry has no partner and is carried forward unchanged.
> **UNREACHABLE at any power-of-two NBLK**, which is every geometry this design
> is built at; see the teeth table [...] where it is **exercised by running
> this unit at NBLK = 5 and 7 rather than argued to be correct.**

Both halves are true and together they are the trap. The branch being
unreachable at `NBLK = 8` is exactly why simulation at `NBLK = 8` cannot see
the index, and running at `NBLK = 5` and 7 exercises the branch's **values**,
not its **elaboration**. The author did the more rigorous thing available
without a Vivado lane, wrote down that he had done it, and the defect sat in
the one gap the argument leaves open.

---

## 4. The procedure, in the order it ran, and what each step isolates

1. **Stage clean blobs, not a working tree.** 114 `rtl/*.vhd` from
   `git show HEAD:<path>` at `cc5f92f` into a standalone remote root
   (`/home/labuser/hdrcost`), manifest sha256 verified identical on both
   boxes before launch. Isolates: another track's in-flight edits.
   TRACK GSRWIDE had `rtl/llama_top.vhd` open at the time and none of it
   travelled.
2. **Three arms, each differing from a shared control in exactly one
   generic.** `base` = `SWEEP_PIPE=true`; `tree` = base + `SCORE_HDR_TREE=1`;
   `early` = base + `SCORE_EARLY=true`. Isolates: the five-variable
   comparison this project has already published and retracted once. `tree`
   and `early` are deliberately **not** compared to each other directly --
   they differ in two generics -- they are each compared to the control.
3. **Clock read BEFORE `synth_design`, not after.** Isolates: TRACK
   GDNSYNTH's finding an hour earlier that `ooc_gdnadapt` created its clock
   after synthesis, so synthesis was never timing-driven and the WNS read
   -4.008 to three decimals across four arms spanning 63,000 LUT.
4. **Object census with its filters validated in the same run against
   `report_utilization`.** Isolates: a census that is wrong in either
   direction. Section 6.
5. **`place_design` + `route_design`, in a SECOND Vivado process from the
   post-opt checkpoint.** Isolates: (a) nothing before `route_design` orders
   two runs correctly on this part; (b) the routing phase inheriting
   synthesis's peak memory.
6. **The score cone reported by name, separately from the headline.**
   Isolates: a headline WNS pinned by an unrelated path. Section 8 shows this
   was not a precaution -- **0 of the top 200 routed paths is in the cone, in
   both arms.**
7. **After the defect surfaced: a one-line candidate fix, proved
   simulation-identical over the same 20-point grid, then teeth-tested with
   an attribution control, then synthesised.** Isolates: a fix that changes
   behaviour, and a grid with no resolution on the thing changed.

---

## 5. The evidence, as raw output

### 5.1 The defect

```
Parameter HDR_TREE bound to: 1 - type: integer
ERROR: [Synth 8-11324] array index 8 out of range [/home/labuser/hdrcost/rtl/attn_score_q12.vhd:488]
ERROR: [Synth 8-285] failed synthesizing module 'attn_score_q12' [.../attn_score_q12.vhd:244]
ERROR: [Synth 8-285] failed synthesizing module 'attn_block' [.../attn_block.vhd:486]
ERROR: [Common 17-69] Command failed: Synthesis failed
```

`phase=synth tag=tree cgroup_peak_mb=2966 cgroup_swap_mb=0 at_cap=no wall_s=49 rc=1`

The generic bound correctly (`Parameter HDR_TREE bound to: 1`), so this is the
lever failing and not the harness ignoring it.

### 5.2 `base` against `early` -- one variable, `SCORE_EARLY`

Post-`opt_design`, object census and `report_utilization` agreeing:

| | base | early | delta |
|---|---:|---:|---:|
| CLB LUTs (sites) | 86,891 | 86,896 | **+5** |
| LUT as Logic | 86,798 | 86,803 | +5 |
| LUT as Memory | 93 | 93 | **0** |
| CLB Registers | 101,242 | 101,244 | **+2** |
| CARRY8 | 2,741 | 2,741 | **0** |
| F7 / F8 Muxes | 16,375 / 2,992 | 16,375 / 2,992 | **0 / 0** |
| Block RAM Tile | 11 | 11 | **0** |
| RAMB36E2 / RAMB18E2 | 3 / 16 | 3 / 16 | **0 / 0** |
| URAM288 | 0 | 0 | 0 |
| DSP48E2 | 298 | 298 | **0** |
| census LUT cells | 95,055 | 95,061 | +6 |
| census FD* | 101,242 | 101,244 | +2 |

Routed:

| | base | early | delta |
|---|---:|---:|---:|
| **CLB (sites)** | **20,377** | **20,276** | **-101** |
| LUT as Logic | 86,079 | 86,086 | +7 |
| CLB Registers | 101,241 | 101,244 | +3 |
| routed WNS (13.333 ns) | **3.101** | **2.735** | **-0.366** |
| failing endpoints | 0 of 250,281 | 0 of 250,285 | |
| place / route seconds | 505 / 911 | 500 / 776 | |

### 5.3 THE CONTROL, AND IT DID NOT MOVE

`SCORE_HDR_TREE` has exactly ONE functional occurrence in
`rtl/attn_block.vhd` -- `:1123`, `HDR_TREE => SCORE_HDR_TREE` in `u_sq`'s
generic map; `:287-310` are its declaration and comment. `SCORE_EARLY`, by
contrast, touches the block's own FSM at `:1486`, `:1947`, `:1948` and
`:2261`. So the prediction, registered before the runs: **`early` must move
the block and must NOT move the score cone.**

MEASURED, the `gen_head[*].u_sq` census, post-`opt_design`:

```
base   CARRY8=92 FDRE=1652 FDSE=128 GND=8 LUT1=8 LUT2=808 LUT3=296
       LUT4=228 LUT5=748 LUT6=1372 MUXF7=56 VCC=4   total=5404
early  CARRY8=92 FDRE=1652 FDSE=128 GND=8 LUT1=8 LUT2=808 LUT3=296
       LUT4=228 LUT5=748 LUT6=1372 MUXF7=56 VCC=4   total=5404
```

**Byte-identical, every REF_NAME.** So the cone census is shown to be
insensitive to a generic outside the cone, which is what makes it admissible
as evidence about a generic inside it.

### 5.4 The 20-point simulation identity for the fix

Pristine `HEAD:rtl/attn_score_q12.vhd` against the one-line fix, same
testbench, same vectors, stdout compared byte for byte:

```
NBLK=3  HDR_TREE=0..3  IDENTICAL PASS      NBLK=6  HDR_TREE=0..3  IDENTICAL PASS
NBLK=5  HDR_TREE=0..3  IDENTICAL PASS      NBLK=7  HDR_TREE=0..3  IDENTICAL PASS
NBLK=8  HDR_TREE=0..3  IDENTICAL PASS
GRID: identical=20 differ=0 of 20
```

The vectors are the generators' own, and `ref/attn_score_q12_vec` at
`64 8 4` reproduces `HEAD:sim/attn_score_q12_vec.txt` **byte-identically**, so
the golden is the committed one and not a local artefact.

### 5.5 The teeth for the fix, with the attribution control

A green grid across a change means the change is untested unless the grid can
be shown to see that class of change. Mutant **M1**, the same bound one too
small (`0 to TW-2`):

```
M1 NBLK=3 HDR_TREE=1/2/3   KILLED KILLED KILLED
M1 NBLK=5 HDR_TREE=1/2/3   KILLED KILLED KILLED
M1 NBLK=6 HDR_TREE=1/2/3   KILLED KILLED KILLED
M1 NBLK=7 HDR_TREE=1/2/3   KILLED SURVIVED SURVIVED
M1 NBLK=8 HDR_TREE=1/2/3   KILLED SURVIVED SURVIVED
M1 TEETH: KILLED=11 SURVIVED=4 of 15
ATTRIBUTION CONTROL, HDR_TREE=0 (the legacy scan; the loop is unreachable):
M1 NBLK=5 HDR_TREE=0  SURVIVED
M1 NBLK=8 HDR_TREE=0  SURVIVED
```

**KILLED at `HDR_TREE = 1` at every one of the five `NBLK`, which is the level
that ships.** Both attribution controls SURVIVE, so the kills belong to the
tree path and not to something the mutation happened to disturb elsewhere.

**The four survivors are reported under their own name because they measure
the grid's resolution floor and are the most useful line here.** At
`HDR_TREE >= 2` with `NBLK` 7 or 8 the mutant leaves `wv(TW-1)` holding
`e_l(TW-1)` instead of the partial minimum of the top pair, and the committed
64-case vector set never places the global minimum in the two blocks that
makes observable. **So this vector set cannot resolve a lost top-pair entry at
two or more folds per cycle.** That is a gap in the vectors, not in the fix,
and it is open.

---

## 6. The census filters, validated rather than assumed

CLAUDE.md records `REF_NAME =~ DSP*` as the working idiom. TRACK GDNSYNTH
measured it over-counting by 9x an hour before this run. Every filter used
here was checked against `report_utilization`'s own row **in the same run**:

```
SCOREHDR_FILTERCHK REF_NAME=~FD*      census=101242 report=101242 AGREE
SCOREHDR_FILTERCHK REF_NAME==DSP48E2  census=298    report=298    AGREE
SCOREHDR_FILTERCHK REF_NAME=~DSP*     census=2682   report=298    DIFFER
SCOREHDR_FILTERCHK REF_NAME==CARRY8   census=2741   report=2741   AGREE
SCOREHDR_FILTERCHK REF_NAME==MUXF7    census=16375  report=16375  AGREE
SCOREHDR_FILTERCHK REF_NAME==MUXF8    census=2992   report=2992   AGREE
SCOREHDR_FILTERCHK REF_NAME==RAMB36E2 census=3      report=3      AGREE
SCOREHDR_DSPRATIO  wildcard/exact = 9.0000
```

**`REF_NAME =~ DSP*` over-counts by EXACTLY 9.0000x on this unit too**, on a
completely different design from GDNSYNTH's and at a different DSP count
(298 against 191). Two independent units giving the identical ratio makes it
a structural property of the transform -- one `DSP48E2` plus its eight
internal primitives -- and not a coincidence of one netlist. **`REF_NAME ==
DSP48E2` is the filter; the wildcard is never quotable.**

The one row deliberately NOT asserted to agree is the LUT total: the census
counts LUT *cells* (95,055) and `CLB LUTs*` counts *sites* after LUT combining
(86,891). They measure different things and the site count is the one that
competes for CLBs.

---

## 7. What the fix measures, and the conclusion it forces

`treefix` is the pristine tree with that one line changed and nothing else:
113 of 114 `rtl/*.vhd` blobs `cmp`-identical, the 114th differing by one
functional line and a comment. It **synthesises, places and routes.**

| | base | treefix | delta |
|---|---:|---:|---:|
| CLB LUTs (sites), post-opt | 86,891 | 87,403 | **+512** |
| CLB Registers | 101,242 | 101,378 | **+136** |
| CARRY8 | 2,741 | 2,753 | +12 |
| F7 / F8 Muxes | 16,375 / 2,992 | 16,343 / 2,992 | **-32** / 0 |
| Block RAM / DSP48E2 / URAM288 | 11 / 298 / 0 | 11 / 298 / 0 | **0 / 0 / 0** |
| census LUT *cells* | 95,055 | 95,827 | **+772** |
| **routed CLB (sites)** | 20,377 | 20,519 | **+142** |
| **routed WNS (13.333 ns)** | **3.101** | **3.101** | **0.000** |
| failing endpoints | 0 of 250,281 | 0 of 250,542 | |
| fully routed / routable | 176,751 / 176,751 | 177,416 / 177,416 | 0 routing errors both |

### SCOREHDR's ESTIMATE was right to the flip-flop

| | ESTIMATE | MEASURED |
|---|---|---|
| FF per `attn_block` | **+136** | **+136 (exact)** |
| FF per score unit | +34 | +34 |
| of which `tv` | +32 per unit | `score_tv` cone = **128 cells** = 32 x 4 |
| LUT per `attn_block` | +520 to +800 | **+512 sites / +772 cells** |

The `tv` working set was sized `TW = ceil(NBLK/2) = 4` entries rather than
`NBLK`, deliberately, and the cone census finds exactly `4 x 8 x 4 = 128`
flip-flops named `tv_reg`. The structural derivation is confirmed object by
object.

### The attribution is exact: nothing moved outside the cone

* block LUT cells `+772`; `u_sq` cone LUT cells `4,232 - 3,460 = +772`.
* block FD\* `+136`; `u_sq` cone FD\* `1,916 - 1,780 = +136`.
* block CARRY8 `+12`; cone CARRY8 `104 - 92 = +12`.
* block MUXF7 `-32`; cone MUXF7 `24 - 56 = -32`.

**Every added and every removed cell is inside `gen_head[*].u_sq`**, which is
what the one-occurrence argument in section 5.3 predicted and is the
strongest form the control can take.

### Its own new path routes with 10.292 ns of slack

```
SCOREHDR_CONE_TO tag=treefix cone=score_emin wns=10.292 levels=5
  start=gen_head[0].u_sq/tl0_reg/C  end=gen_head[0].u_sq/e_min_reg[1]/D
SCOREHDR_CONE_TO tag=treefix cone=score_tv   wns=10.453 levels=5
  start=gen_head[0].u_sq/tl0_reg/C  end=gen_head[0].u_sq/tv_reg[0][5]/D
SCOREHDR_CONESHARE tag=treefix top=200 in_score_cone=0
```

`tl0_reg` -> `e_min_reg` at **5 logic levels** is precisely the path SCOREHDR
predicted the tree would add: register -> source mux -> compare -> mux ->
register. It routes at **10.292 ns of slack against a 3.101 ns headline**, so
**the tree's own deepest path has 7.19 ns more margin than this block's
critical path**, and the routed WNS is unchanged to three decimals.

### AND THAT IS WHY THE TREE SHOULD NOT REPLACE `SCORE_EARLY` EVEN WHEN FIXED

SCOREHDR's conclusion was:

> `SWEEP_PIPE`+`SCORE_HDR_TREE=1` (231.11) EQUALS `SWEEP_PIPE`+`SCORE_EARLY`
> (231.17). They are interchangeable, and **this is the smaller change** --
> one generic inside one leaf unit against new state and a new assert in the
> sweep FSM.

The cycle half is confirmed and is not in question. **The "smaller change"
half is now measured and it is false of the silicon:**

| lever | cycles/position | CLB LUT sites | flip-flops | routed WNS |
|---|---:|---:|---:|---:|
| `SCORE_EARLY` | 231.17 | **+5** | **+2** | (within noise) |
| `SCORE_HDR_TREE=1`, fixed | 231.11 | **+512** | **+136** | 0.000 |

**Same saving, 102x the LUT and 68x the flip-flops.** "Smaller change" was a
true statement about the source diff and a false one about the device, and
nothing in the cycle measurement could have distinguished them. On a card
whose binding constraint is CLB occupancy at 99.81%, the 0.06-cycle advantage
does not buy 507 LUT.

**So the recommendation does not change when the defect is fixed.** Build 11
takes `SCORE_EARLY`, and `SCORE_HDR_TREE` stays at 0. The fix is still worth
landing, because a released generic that cannot be synthesised is a trap for
whoever tries it next, and because the tree becomes the right answer if
`SCORE_EARLY` ever has to come out for an unrelated reason.

---

## 8. The headline WNS could never have answered this, and here is the number

```
SCOREHDR_CONESHARE tag=basereport top=200 in_score_cone=0
SCOREHDR_CONESHARE tag=early      top=200 in_score_cone=0
```

**Zero of the top 200 routed paths touches `u_sq` in either arm**, confirming
TRACK LEVERCOST's post-synthesis finding at the routed stage. The worst paths
are somewhere else entirely and are not even the same place in the two arms:

| arm | routed worst path | levels | WNS |
|---|---|---:|---:|
| base | `ar_rsb_reg[0]/C` -> `u_arr/p_reg_reg[22]/DSP_A_B_DATA_INST/A[16]` | 3 | 3.101 |
| early | `u_quant/raddr_r_reg[0]/C` -> `vs2_q_reg[15]/D` | 6 | 2.735 |

The cone's own worst path, by contrast:

| cone | base slack | early slack |
|---|---:|---:|
| all `u_sq` (into) | 9.355 | 9.514 |
| `e_min_reg` (into) | 10.333 | 10.006 |
| `shb_reg` (into) | 10.387 | 9.931 |
| `state_reg` (into) | 11.205 | 10.878 |

**The score cone carries about 6.3 ns MORE slack than the block's critical
path.** Whatever `HDR_TREE = 1` costs in depth, it starts 6 ns from mattering
*inside this block*. That is a statement about `attn_block` out of context and
**it is not a statement about the card**, whose +0.061 ns is a congestion
result at 99.81% CLB occupancy under `Congestion_SpreadLogic_high`.

### AND THE NOISE FLOOR OF THIS HARNESS IS ABOUT 0.4 ns, MEASURED

`base` and `early` differ by **+5 LUT and +2 FF** and their routed WNS differs
by **0.366 ns**, on entirely different critical paths in different modules.
A 5-LUT change cannot move a critical path in the quantiser. **So 0.366 ns is
placement-and-routing variance, and no WNS difference below roughly 0.4 ns in
this harness is a result.** Anyone reading two arms of this flow must clear
that bar before claiming a timing effect. It was worth 0.4 ns to find out, and
it was free: the pair had to be run anyway.

---

## 9. Measured and REJECTED -- do not retry

* **"Measure `SCORE_HDR_TREE=1`'s area on the existing `ooc_levercost`
  harness."** REJECTED: there is nothing to measure. `synth_design` dies in
  49 s. The harness is fine; the RTL does not build.
* **"The ESTIMATE of +520 to +800 LUT is the number to plan against."**
  REJECTED as untestable in its present form. It was an estimate of an object
  that cannot be built. It is not refuted -- it may well be right about the
  FIXED tree -- but nothing in it was ever checked, and the thing it described
  did not exist.
* **"Quote the block's routed WNS to order the two arms."** REJECTED with a
  measured number: 0 of 200 top paths in the cone, and a 0.366 ns swing
  between two arms differing by 5 LUT. The headline has no demonstrated
  resolution on this lever.
* **"`phys_opt_design` first, so the comparison is on the best netlist."**
  REJECTED before running: a phys_opt WNS on this part has over-promised by
  0.4 to 0.6 ns twice and once inverted the verdict, and it is
  directive-sensitive, so it adds a stage that can differ between arms for
  reasons unrelated to the generic. Both arms enter `place_design` from the
  same flow position with `opt_design` inside the checkpoint.
* **"Exercising the odd-level branch at `NBLK = 5` and 7 shows it is
  correct."** REJECTED by this incident. It exercises the branch's VALUES.
  Its static index range is a synthesis property that no `NBLK` makes visible
  to GHDL.
* **"Raise the BC-250 cap above 11G so the synthesis stops throttling."**
  NOT ATTEMPTED and must not be: a build at 12G on that 14 GB box once left it
  completely unreachable, and it is on no WoL watchdog, so recovery needs a
  physical power-cycle.

---

## 10. Measurement traps hit, including my own

1. **MY OWN REPORTING CODE KILLED A COMPLETED 1,416-SECOND ROUTE, AND IT DID
   IT AN HOUR AFTER I ADDED A GUARD AGAINST EXACTLY THAT.** `pathline` read
   `LOGIC_DELAY` and `NET_DELAY`, which sound like siblings of
   `DATAPATH_DELAY` and are not:
   `ERROR: [Common 17-54] The object 'timing_path' does not have a property
   'LOGIC_DELAY'.` It fired after `place_design`, `route_design` and both
   checkpoints had succeeded. **I had already wrapped every
   `get_timing_paths` in a catch, specifically because LEVERCOST lost two
   draws to post-expensive-phase reporting bugs -- and the call that failed
   was `get_property`, which the wrapper does not cover.** Guarding the call
   that has already failed says nothing about the call that has not. The
   route survived only because `write_checkpoint` runs BEFORE the reporting
   section, so re-reporting cost 5 minutes instead of 24.
2. **MY OWN SENTINEL COUNTER MATCHED MY OWN SCRIPT.** The runner prints
   `synth_8-10226=$(grep -c 'Synth 8-10226' log)`, and both arms reported
   **1**. The true count is **0**: the single match is the tcl's own line
   `foreach mid {{Synth 8-7186} {Synth 8-10226}}`, which Vivado echoes into
   the log. This is CLAUDE.md's unanchored-grep trap in a fourth place, and
   it reads as "one warning" rather than "none" -- the wrong direction, since
   it invents a warning that never happened.
3. **`report_route_status` HAS NO "unrouted nets" LINE WHEN THE DESIGN IS
   FULLY ROUTED**, so a regex looking for one returns `NA` and a completeness
   check built on it is vacuous. The line that carries the information is
   `# of fully routed nets` against `# of routable nets` plus
   `# of nets with routing errors`. MEASURED for `base`: 176,751 of 176,751
   routable, **0 routing errors**. Both arms fully routed.
4. **`remove_clock` IS NOT A COMMAND IN VIVADO 2023.2.**
   `SCOREHDR_PRMCLK clk : invalid command name "remove_clock"` in every
   place-and-route run. The intent was to drop the checkpoint's inherited
   constraints so each arm's clock is created identically. It failed, the
   catch reported it, and the consequence is benign **only because** phase 1
   created the same clock, on the same port, at the same period: the second
   `create_clock` replaces it. Identical in every arm, so the comparison
   holds, but the guard did not do what it said.
5. **AT `MemoryHigh=11G` EVERY SYNTHESIS ARM HIT ITS CAP, SO NO
   `memory.peak` HERE IS AN APPETITE.** `base` 11,266 MB resident with
   **7,064 MB** of swap beside it; `early` 11,267 MB with 6,680 MB. DERIVED
   true footprint at least ~18 GB, actual peak UNKNOWN. The place-and-route
   arms did NOT reach the cap and those figures are honest: `early`'s pnr
   peaked at **6,807 MB with 0 swap**, and `tree`'s failed synthesis at
   2,966 MB. **Routing this block is much cheaper than synthesising it**,
   which is the opposite of the intuition that put the cap where it is.

---

## 11. Open, not determined

* **Whether the FIXED tree fits the card.** No OOC number can answer it. The
  card's margin is congestion at 99.81% CLB under a spreading strategy; only
  a routed `FK33_CARD=1` build says whether anything more fits.
* **Whether `SCORE_HDR_TREE` at levels 2 and 3 synthesises.** Not tested. The
  same loop is involved and the same bound applies, so the fix should cover
  them, but "should" is not a measurement and no arm was drawn.
* **The four M1 survivors at `HDR_TREE >= 2`, `NBLK` 7 and 8.** The committed
  64-case vector set cannot resolve a lost top-pair entry at two or more folds
  per cycle. The vectors need a case that puts the global minimum in the top
  pair; nothing here added one.
* **Whether any OTHER generic in this repository has the same
  elaboration-only failure mode.** `SCORE_HDR_TREE` was found because someone
  finally ran Vivado on it. Nothing enumerates the class, and the cheap
  discriminator -- one OOC `synth_design` per generic arm -- is scheduled
  nowhere.
* **`SCORE_EARLY`'s -101 routed CLB against `base`.** It is almost certainly
  the same placement variance as the 0.366 ns, but it was not controlled for
  and must not be read as the lever making the block smaller.
* **`tb_csweep_rate` and `tb_attn_block` were NOT re-run against the fix.**
  Only `tb_attn_score_q12` was, over the 20-point grid. The fix is inside the
  unit and the grid is the unit's own oracle, but the block-level and
  rate-level benches are untouched by this track.
