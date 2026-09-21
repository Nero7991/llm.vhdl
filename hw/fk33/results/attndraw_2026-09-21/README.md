# TRACK ATTNDRAW -- drawing the two attention levers that are ON at HEAD and had no same-tree baseline

Date 2026-09-21. Part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, **BC-250 lane only**
(`cachyos-bc250`, 15.2 GB + 32 GB swapfile + 14.8 GB zram). **No hardware.** The
workstation lane was never given a Vivado: it held `card12-build.service`
throughout, MEASURED at four Vivado processes and 23.3 GB summed VmRSS by
`/proc/PID/exe`, one worker at 17.4 GB.

Tree **`3e344a2`**, staged into a standalone remote root by
`git archive`, manifest sha256
`188ea744beb0389ac510113543795feaad77c635bfed42ff395796fb14a668e7`
over **119 files**, `sha256sum -c` clean on the BC-250 (0 FAILED) before launch.

**HEAD MOVED FIVE COMMITS DURING THE RUN (`3e344a2` -> `e3d8835`) AND THE
MEASUREMENT IS STILL OF HEAD'S RTL, asserted rather than assumed.** MEASURED:
`git diff --stat 3e344a2 e3d8835 -- rtl/` is **empty**, and so is the same diff
restricted to `rtl/attn_block.vhd rtl/attn_score_q12.vhd rtl/llama_top.vhd
rtl/fk33_llama_top.vhd`. A number measured against a stale tree is
indistinguishable from a real one, so this is checked, not inferred from the
run having been launched recently.

A standalone root was used rather than the synced working tree deliberately:
`bash ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh` has **no `--delete`**, so the
synced tree can carry leftover `rtl/*.vhd` from earlier sessions that
`read_vhdl` would pick up. The sync was still run first, as the standing rule
requires (2,829 tracked files).

Harness: the committed `sim/ooc_scorehdr.tcl` (synth + opt + validated census +
DCP) and `sim/ooc_scorehdr_pnr.tcl` (place + route + cone timing), **byte-identical
from HEAD**, driven by `run_attndraw.sh` in this directory -- a copy of the
committed `sim/ooc_scorehdr_run.sh` differing only in three `arm_gen` lines, the
`ROOT` default and a `memory.high` readback. `driver.diff` in this directory is
that diff, 40 lines. `sim/` was not edited.

---

## The answer, up front

**BOTH LEVERS SYNTHESISE, AND THE PAIR ROUTES.** `SWEEP_PIPE=true
SCORE_EARLY=true` -- HEAD's setting at `rtl/llama_top.vhd:6997` and
`rtl/fk33_llama_top.vhd:7621` -- costs **+69 CLB LUT sites and +23 flip-flops**
on `attn_block` at the card's 9B generics, against a matched
`SWEEP_PIPE=false SCORE_EARLY=false` baseline drawn from the same tree through
the same script. Every other resource is **exactly 0**. It routes at
**WNS 2.735 ns on a 13.333 ns clock (the card's 75 MHz core period), 0 failing
endpoints of 250,285, 0 routing errors.**

**AREA IS EXACTLY ADDITIVE, AND CYCLES ARE NOT.** The three-arm decomposition,
one tree and one script: `SWEEP_PIPE` alone **+64 LUT / +21 FF**, `SCORE_EARLY`
on top of it **+5 LUT / +2 FF**, and the two sum to the pair's **+69 / +23** in
**every** resource -- LUT sites, LUT as Logic, CLB Registers, census LUT cells
and F7 -- with no residual. `4e9915b` MEASURED the same two generics as
**SUPERADDITIVE in cycles** (80.06 + 32.00 = 112.06 against a measured 124.00)
and instructed "quote the pair, never the singles added". **That instruction is
right for cycles and unnecessary for area**, and the two facts have to be kept
apart because one document applied the cycles rule to area and another added
area singles anyway.

**A MATCHING DRAW PARTLY EXISTED AND THE BRIEF'S PREMISE WAS TOO STRONG.**
TRACK HDRCOST's `early` arm (2026-09-20, tree `cc5f92f`) is **generic-identical
to HEAD's setting** and was already synthesised, placed and routed. This track
reproduces it **to the digit on all 15 validated area rows, to three decimals
on the routed WNS (2.735), and to the endpoint on the timed count (250,285)**.
So "no synthesiser has ever drawn this RTL" was **false for the pair-ON arm**
before this track started. What genuinely did not exist is any arm with
`SWEEP_PIPE=false` through a routing harness -- every HDRCOST arm pins it true
(`sim/ooc_scorehdr_run.sh:67-70`) -- so there was **no same-tree baseline and
therefore no pair delta**. That is what this track adds.

**TIMING IS REPORTED AS A BOUND, NOT AS A DELTA, AND THAT WAS PRE-REGISTERED.**
The routed WNS difference between the arms is **0.379 ns**, below this
harness's MEASURED ~0.4 ns noise floor, **in the favourable direction**, with
the two arms' worst paths **in different modules**. A +69 LUT change cannot
speed up a quantiser path. The usable timing statement is the absolute one
above plus the cone bound below.

---

## 1. Was there already a draw? Searched for the GENERIC NAMES, not the words a document used

`git grep -c -E "SWEEP_PIPE|SCORE_EARLY"` over **all tracked files** (so `.py`,
`.tcl`, `.sh` and `.vhd` together, since `hw/fk33/gen_*.py` and `tools/gen_*.py`
are part of the RTL surface and a `*.vhd` grep cannot see a generated port):

| harness | arms | `SWEEP_PIPE` | routes? | what it gives |
|---|---|---|---|---|
| `sim/ooc_levercost_run.sh` | `cswp_off`, `cswp_on` | **false and true** | **NO** -- `grep -cE route_design` = 0 | `SWEEP_PIPE` alone, +64 LUT / +23 FF, tree `bc4156f`, **synthesis only** |
| `sim/ooc_scorehdr_run.sh` | `base`, `tree`, `early`, `treefix` | **true in every arm** | yes | `SCORE_EARLY` on top of `SWEEP_PIPE`, +5 LUT / +2 FF, tree `cc5f92f`, **routed** |
| `rtl/ooc_cattnadapt_top.vhd` + `sim/ooc_cattnadapt.tcl` | n/a | **passes neither generic** | **NO** -- `grep -cE 'opt_design\|place_design\|route_design'` = 0 | instantiates `attn_block` at `:707` and takes both defaults, i.e. the OFF arm, synthesis only |
| `sim/mutate_attn_sweep_pipe.sh`, `sim/mutate_attn_score_early.sh` | both arms | both | n/a | **GHDL only** (no `vivado`, no `synth_design`); nothing schedules them |

So: the pair-ON netlist HAD been drawn and routed; the pair DELTA had not, and
no arm in the repository had ever set `SWEEP_PIPE=false` with a router behind it.

**Neither auto-discovered bench covers the ON arm**: `sim/tb_attn_block.vhd:177,183`
and `sim/tb_csweep_rate.vhd:190,195` both default the generics to `false` and pass
them through, so the gate exercises only the OFF schedule -- as WORKLOG:335 records.

---

## 2. The arms, and what had to differ before a delta was admissible

| arm | `SWEEP_PIPE` | `SCORE_EARLY` | what it is |
|---|---|---|---|
| `coff` | false | false | the baseline. What every card build to date synthesised, and what build 12 is synthesising now (`build12_levers_off.patch`). |
| `con` | **true** | **true** | HEAD. |
| `spon` | true | false | the decomposition point, in ONE tree. |

Shared generics, from `rtl/fk33_llama_top.vhd`'s `u_attn` map resolved against
`QWEN35_9B`: `HEAD_DIM=256 N_QH=16 N_KVH=4 KV_BLOCK=32 N_ROT=64 LAYERS=8
POS_W=17 MANT_W=16 CM_W=8 EXP_W=8 NORM_LANES=1 STRICT_PRODUCER=true`, giving
`G = 4` score units and `NBLK = 8`. Passing them is load-bearing:
`attn_block`'s own `POS_W` default is 16 and the card passes 17.

**The arms are not secretly one netlist.** Registered in `PREDICTIONS.md`
before launch as the thing that would void the table, because two arms that
were the identical netlist have been measured twice in this project in the
preceding two days. MEASURED: +69 LUT sites, +23 FF, +85 census LUT cells, and
the LUT-input histogram moves (`lut2` 8,919 -> 8,931, `lut3` 9,154 -> 9,176).

---

## 3. Area, post-`opt_design`, same tree, same script

| | `coff` | `spon` | `con` | SP alone | SE on top | **PAIR** |
|---|---:|---:|---:|---:|---:|---:|
| **CLB LUTs (sites)** | 86,827 | 86,891 | 86,896 | +64 | +5 | **+69** |
| LUT as Logic | 86,734 | 86,798 | 86,803 | +64 | +5 | **+69** |
| LUT as Memory | 93 | 93 | 93 | 0 | 0 | **0** |
| **CLB Registers** | 101,221 | 101,242 | 101,244 | +21 | +2 | **+23** |
| CARRY8 | 2,741 | 2,741 | 2,741 | 0 | 0 | **0** |
| F7 Muxes | 16,374 | 16,375 | 16,375 | +1 | 0 | **+1** |
| F8 Muxes | 2,992 | 2,992 | 2,992 | 0 | 0 | **0** |
| Block RAM Tile | 11 | 11 | 11 | 0 | 0 | **0** |
| RAMB36E2 / RAMB18E2 | 3 / 16 | 3 / 16 | 3 / 16 | 0 | 0 | **0 / 0** |
| URAM288 | 0 | 0 | 0 | 0 | 0 | **0** |
| DSP48E2 | 298 | 298 | 298 | 0 | 0 | **0** |
| census LUT cells | 94,976 | 95,055 | 95,061 | +79 | +6 | **+85** |
| census LUTRAM / SRL | 133 / 29 | 133 / 29 | 133 / 29 | 0 | 0 | **0 / 0** |

**`SP alone` + `SE on top` = `PAIR` in every row, exactly, with no residual.**
That is the additivity result, and it is a same-tree one-script measurement
rather than a sum of two harnesses.

**`spon` reproduces HDRCOST's `base` on every row** (86,891 / 86,798 / 101,242 /
95,055 / 16,375), which together with `con` reproducing `early` makes **two of
three arms independently confirmed against a different tree and a different
track.**

### The attribution is exact, and it is the whole point

`report_utilization -hierarchical`, both arms. **All 15 sub-instances are
identical** -- `gen_head[0..3].u_sq` 715 LUT / 445 FF each, `gen_head[0..3].u_sm`
340 / 399 each, `u_arr` 50,531 / 39,465, `u_emit` 459 / 390, `u_gate` 789 / 890,
`u_norm` 5,471 / 5,306, `u_quant` 227 / 314, `u_recip` 154 / 306, `u_rope`
253 / 150, `u_tw` 105 / 200. The entire change is in `(attn_block)`, the top
level's own logic:

| | `coff` | `con` | delta |
|---|---:|---:|---:|
| `(attn_block)` Total LUTs | 24,618 | 24,687 | **+69** |
| `(attn_block)` FFs | 50,824 | 50,847 | **+23** |

**Block delta = cone delta, for both resources, with nothing leaking into any
submodule.** That is where both levers' state lives: the phase FSM, the
`pk_*`/`pv_*` counters and `rbs` (`SWEEP_PIPE`), and `se_rdy`/`se_sent`
(`SCORE_EARLY`).

### The census filter was validated in-run, and it reproduces the recorded 9x

`dsp48_exact = 298` against `dsp_wildcard = 2682`, and **2,682 / 298 = 9.0
exactly** -- the DSP58 sub-primitive over-count CLAUDE.md records for
`REF_NAME =~ DSP*` -- anchored against `report_utilization`'s DSP row of 298.
`uram288 = 0` in all three arms: nothing requested, nothing refused.

### But the harness's OWN message counter is still contaminated, and it was diagnosed a day ago

The driver prints `HDRCOST_LOGMSG synth <arm> synth_8-10226=1 synth_8-7186=1`
for **all three of my arms**. MEASURED, the matching line:

```
$ grep -an 'Synth 8-10226' vivado_synth_coff.log
32:# foreach mid {{Synth 8-7186} {Synth 8-10226}} {
$ grep -an 'Synth 8-7186' vivado_synth_coff.log
32:# foreach mid {{Synth 8-7186} {Synth 8-10226}} {
```

**One line -- the tcl's own source, echoed into its own log -- matches BOTH
patterns.** Anchored to a real message line, all three arms are **0 and 0**:

```
coff: 8-10226=0 8-7186=0
con:  8-10226=0 8-7186=0
spon: 8-10226=0 8-7186=0
```

**TRACK LEVERCOST found exactly this and wrote it up**
(`hw/fk33/results/levercost_2026-09-20/README.md:417-427`: *"the extra match is
line 36 of the log, which is this script's own `foreach mid ...` echoed into
it ... 1 unanchored and 0 anchored -- a message that never occurred, counted
once, because the script that counts it names it"*). It called it the
haystack-contains-your-own-needle trap in a fourth place. **The harness was not
changed.** TRACK HDRCOST ran it the next day and its committed
`driver_sentinels.txt` carries `synth_8-10226=1 synth_8-7186=1` for both arms,
uncorrected and unmentioned in its README; this track is the third reproduction.

**The lesson is not the trap, which was already known. It is that writing a
trap down is not fixing the instrument**, and the instrument goes on emitting
the wrong number into committed evidence where the next reader will take
`8-10226=1` to mean a URAM request was refused. The one-line fix is to anchor
the driver's two `grep -c` to `^(WARNING|INFO|CRITICAL WARNING|ERROR): \[Synth `.
**Not applied here: `sim/ooc_scorehdr_run.sh` is not this track's file**, and the
patch is offered in section 9 rather than made.

---

## 4. Timing, routed. Reported as a bound

`place_design` + `route_design` in a separate Vivado process from the post-opt
checkpoint. **No `phys_opt_design`**, deliberately.

| | `coff` | `con` |
|---|---:|---:|
| **routed WNS (13.333 ns)** | **2.356** | **2.735** |
| TNS | 0.000 | 0.000 |
| failing endpoints | **0** of 250,250 | **0** of 250,285 |
| routed nets | 479,859 | 479,965 |
| routing errors | **0** | **0** |
| CLB (sites) | 20,162 | 20,276 |
| CLB LUTs (sites, routed) | 86,110 | 86,171 |
| place / route seconds | 512 / 723 | 501 / 769 |
| worst path | `ar_rsb_reg[1]/C` -> `u_arr/p_reg_reg[6]0/DSP_A_B_DATA_INST/A[7]`, 3 levels | `u_quant/raddr_r_reg[0]/C` -> `vs2_q_reg[15]/D`, 6 levels |

`con`'s 2.735 ns on 13.333 ns is a **91.1 MHz bound for this block in
isolation** at the card's 75 MHz core period. It is a BLOCK bound, not a card
figure: a card-top OOC has never cleared RTL elaboration here (0 of 12
attempts, two machines), so nothing in this track speaks to card placement or
congestion.

### Why the 0.379 ns is not a result, with the numbers that show it

* It is **below the ~0.4 ns noise floor HDRCOST measured** on this harness.
* Its **sign is favourable** -- the arm with 69 more LUTs and 23 more
  flip-flops routes 0.379 ns BETTER. A change of that size cannot speed up a
  path in the quantiser.
* The two arms' **worst paths are in different modules** (MAC array vs
  quantiser), so the two WNS values are not measurements of the same thing.
* The cross-TREE spread on arms that should be close is larger still: my `coff`
  2.356 against HDRCOST's `base` 3.101 is **0.745 ns**, roughly twice the
  recorded floor.

### The cone bound, which is the instrument HDRCOST did not have

HDRCOST's cones cover only `u_sq`, so they could bound `SCORE_EARLY` and said
**nothing** about `SWEEP_PIPE`, whose state is in `attn_block` itself. Built
here from the top-200 routed path distributions the harness already writes, at
no extra Vivado cost:

```
coff: paths=200 worst=2.356 best=4.103  sweep_state_paths=0  score_early_state_paths=0  u_sq_paths=0
con:  paths=200 worst=2.735 best=4.106  sweep_state_paths=0  score_early_state_paths=0  u_sq_paths=0
```

matching on `pk_cnt|pk_blk|pk_en|pk_got|pk_pend|pk_act|pv_cnt|pv_blk|pv_en|pv_got|rbs_reg`
and `se_rdy|se_sent`. **No path in either lever's own state appears anywhere in
the top 200 of either arm, so both cones carry more than 4.106 ns of slack --
at least 1.371 ns more margin than `con`'s critical path.**

And the top-200 composition is the same story in both arms: **186 vs 185** of
200 end in `u_arr` and 14 vs 15 in `vs2_q_reg[*]`. The exact-endpoint overlap
is only 30 of 200 (15%) because the individual DSP pins shuffle, which is what
placement variance looks like at pin granularity while the module-level
distribution is unchanged.

---

## 5. Memory, and which figures are honest

Cap `MemoryHigh=11G`, **read back out of each scope's own cgroup** rather than
asserted (`high_*.txt`): every phase reports `memory.high=11811160064`, which
is 11 GiB exactly. The pre-flight probe (`preflight.sh`) ran the identical
readback through the same `ssh 'bash -s'` channel and printed the value from a
FILE, not a `bash -c` string, with a **no-scope control reading `max`** -- so
the probe is shown to discriminate rather than to print a value that would
appear either way.

| arm / phase | cgroup `memory.peak` | at cap? | max `memory.swap.current` | wall |
|---|---:|---|---:|---:|
| `coff` synth | 11,266 MB | **YES** | 6,416 MB | 960 s |
| `coff` pnr | **6,292 MB** | no | **0 MB** | 1,412 s |
| `con` synth | 11,267 MB | **YES** | 6,572 MB | 975 s |
| `con` pnr | **6,427 MB** | no | 134 MB | 1,443 s |

**Neither synthesis figure is an appetite** -- both sat at the throttle, and
`memory.peak` records the cap. They reproduce HDRCOST's 11,266 / 11,267 MB to
the megabyte, which is evidence the cap worked and nothing about the job's size.
**The place-and-route figures ARE appetites**, and routing this block costs
about 57% of what synthesising it costs.

---

## 6. Predictions, scored under their own names

Registered in `PREDICTIONS.md` before the first Vivado started.

| | prediction | outcome |
|---|---|---|
| **P1** | both levers synthesise, 0 `^ERROR` | **HIT** |
| **P2** | `con - coff` FF = **+25 exactly** | **MISS. Measured +23.** Section 7 is the root cause, and `spon` confirms it: `SWEEP_PIPE` alone is **+21 FF** at HEAD, not the +23 the sum used. Labelled in advance as the assumption most likely to be wrong, and it was. |
| **P3** | `con - coff` LUT sites = +69, ESTIMATE, LOW confidence | **HIT, exactly.** And see section 7: the caution attached to this term was pointing at the term that survived. |
| **P4** | DSP, BRAM, RAMB36/18, URAM deltas all exactly 0 | **HIT**, and wider than predicted: CARRY8, F8, LUT-as-Memory, LUTRAM and SRL are 0 too. Only F7 moved, by +1. |
| **P5** | `con` reproduces HDRCOST's `early` (86,896 / 101,244) | **HIT, and stronger.** All 15 validated rows identical, the opt-stage `u_sq` cone identical at 5,404, the routed WNS identical at 2.735, and the timed endpoint count identical at 250,285. |
| **P6** | routed WNS delta lands below the ~0.4 ns floor, i.e. **I predicted I could not measure a timing effect** | **HIT.** 0.379 ns, favourable sign, different modules. |
| **P7** | synthesis at cap, pnr not, pnr near 6,800 MB | **HIT** on the structure; the pnr appetite is 6,292 / 6,427 MB, about 400 MB under the predicted figure. |

### A derivation registered against the flip-flop count, and it is high by 3

Before `spon` ran I derived the registers that exist only under `SWEEP_PIPE` at
`NBLK = 8` from the declarations at `rtl/attn_block.vhd:778-799`:
`rbs`(2) + `pk_en`(1) + `pk_blk`(4) + `pk_cnt`(4) + `pk_got`(1) + `pk_pend`(1)
+ `pk_act`(1) + `pv_en`(1) + `pv_blk`(4) + `pv_cnt`(4) + `pv_got`(1) = **24
declared bits**. `cap_v`, `cidx_k` and `cidx_v` are combinational and present in
both arms, so they are correctly excluded.

MEASURED: **+21.** So the declaration count is an **upper bound** and is high by
3, which is what one expects when synthesis narrows counters whose full declared
range is unreachable. CSWEEP's original pre-registration was "~23 FF plus a
4-bit mux" and LEVERCOST measured exactly 23 on `bc4156f`; at HEAD the same
declarations give 21. **A declared-bit count is not a flip-flop count, and the
gap is not constant across trees** -- which is the same lesson as section 7 from
the other direction.

---

## 7. What was root-caused: the provenance of `+25 FF`

`docs/WORKLOG.md:299` and `docs/LEVERBOARD.md:610` both carry the C pair as
**"+69 LUT and +25 FF MEASURED"**. The LUT half is right to the digit. The FF
half is wrong by 2, and the reason is provenance, not arithmetic.

**MEASURED:** `SCORE_EARLY` has **zero occurrences** in `rtl/attn_block.vhd` at
LEVERCOST's tree `bc4156f`
(`git show bc4156f:rtl/attn_block.vhd | grep -c SCORE_EARLY` = 0, and zero
`signal se_rdy` / `signal se_sent`), against 20 at HEAD. `4e9915b`, the commit
that introduced the lever, added 310 lines to that file. So LEVERCOST's
`+23 FF` for `SWEEP_PIPE` was drawn on a block **that did not contain the other
lever's code at all**, and the sum `+23 + 2 = +25` combines two deltas that
were never measurable in one netlist.

**MEASURED, same tree: `SWEEP_PIPE` alone is +64 LUT and +21 FF.** So
LEVERCOST's LUT figure **reproduces exactly** (+64 both times, and +79 census
cells both times) while its FF figure **does not** (+23 there, +21 here). That
is the whole explanation of why the published sum was half right: `+64 + 5 = +69`
survived because `+64` survived, and `+23 + 2 = +25` failed because `+23`
became `+21`.

**The 11 `SWEEP_PIPE` state declarations are identical in both trees**
(`rbs`, `pk_en`, `pk_blk`, `pk_cnt`, `pk_got`, `pk_pend`, `pk_act`, `pv_en`,
`pv_blk`, `pv_cnt`, `pv_got`), so the 2-flip-flop shift is a sharing or
optimisation effect in the surrounding logic. **The mechanism is NOT determined
by anything this track ran** -- only that the number moved, and by how much.

**AND THE ADDITIVITY THAT MAKES THE SUM LEGITIMATE WAS NEVER ESTABLISHED
BEFORE.** `+64 + 5` and `+21 + 2` land on the pair exactly, so adding the
singles IS valid for area here -- but that is a RESULT of this draw, not a
licence that existed when the sum was published. `4e9915b` had MEASURED the
same two generics superadditive in CYCLES and said so in its own message. The
sum was published against a standing warning about these exact two levers, and
it happened to be right about LUTs for a reason nobody had checked.

**And LEVERBOARD's own caution was aimed at the surviving term.** Its
CORRECTION 1 warned specifically about the LUT half, MEASURING the
cross-harness gap on the same configuration at 167 LUT, "2.6x the +64 being
quoted". That half is exactly right. The FF half, which nobody flagged, is the
wrong one. **A caution can correctly establish that a sum is unsafe and still
point at the wrong addend**, and being right about the unsafety is what makes
it feel discharged.

**The recommendation does not change.** DERIVED: +69 of build 10's 78,319 free
LUT sites (WORKLOG:85) is **0.088%**, i.e. the 0.09% already recorded. The
correction is for the record, not for the decision.

---

## 8. Measured and REJECTED -- do not retry

* **Do not quote a placed WNS, on this part, for these arms.** MEASURED here,
  same tree, same script, one variable: **the placed stage inverts the
  verdict.** Placed says `coff` is better by 0.784 ns (4.558 vs 3.774); routed
  says `con` is better by 0.379 ns (2.356 vs 2.735). The over-promise is
  **+2.202 ns** for `coff` and **+1.039 ns** for `con` -- the larger of those is
  **3.5x** the biggest case CLAUDE.md records for `phys_opt`. Both routes are
  clean with 0 failing endpoints. This is a second measured pre-route inversion
  and the first on a one-variable same-tree pair.
* **Do not use `sim/ooc_cattnadapt.tcl` to price these levers.** It passes
  neither generic (`rtl/ooc_cattnadapt_top.vhd:707` takes both defaults) and it
  contains zero of `opt_design`, `place_design`, `route_design`.
* **Do not treat the `pnr_*.csv` `lut_sites` column as the routed LUT figure.**
  It is `NA` in every arm, in this track and in HDRCOST, because the tcl looks
  up `CLB LUTs*` while the ROUTED report labels that row `CLB LUTs` without the
  asterisk. The value is in `routeutil_*.rpt`. A silent missing column, not an
  error.
* **Do not compare `cone_byinst_synth_*` against a table built at opt stage.**
  My synth-stage cone reads 5,408 against HDRCOST's 5,404 and I nearly wrote
  that up as a tree difference. It is a **stage effect**: `opt_design` removes
  exactly one cell per head, and my own opt-stage cone is 5,404, matching
  exactly. Compare at the same stage.

---

## 9. One patch offered, not applied

`sim/ooc_scorehdr_run.sh`'s last line of `runviv` counts two Vivado message ids
unanchored and therefore counts its own tcl's source. Not my file; here is the
change, for whoever owns it:

```diff
-  echo "HDRCOST_LOGMSG $phase $tag synth_8-10226=$(grep -c 'Synth 8-10226' "$OUT/vivado_${phase}_$tag.log") synth_8-7186=$(grep -c 'Synth 8-7186' "$OUT/vivado_${phase}_$tag.log")"
+  # ANCHORED.  Unanchored, ONE line -- this tcl's own `foreach mid {{Synth
+  # 8-7186} {Synth 8-10226}}` echoed into the log -- matches BOTH patterns, so
+  # every arm reports 1 for a message that never fired.  MEASURED by LEVERCOST
+  # 2026-09-20 and again by ATTNDRAW 2026-09-21; the count is 0 anchored.
+  _mc() { grep -acE "^(WARNING|INFO|CRITICAL WARNING|ERROR): \[$1\]" "$2"; }
+  echo "HDRCOST_LOGMSG $phase $tag synth_8-10226=$(_mc 'Synth 8-10226' "$OUT/vivado_${phase}_$tag.log") synth_8-7186=$(_mc 'Synth 8-7186' "$OUT/vivado_${phase}_$tag.log")"
```

---

## 10. What this track did NOT determine

1. **Whether these levers should go on a card build.** Out of scope by the
   brief, and unanswerable from here regardless: an OOC `attn_block` draw
   cannot answer a placement or congestion question, and the card-top OOC that
   could has never cleared elaboration.
2. **The mechanism of the `+23` -> `+21`/`+23` FF shift between trees.** Only
   that the state declarations did not change.
3. **Any silicon effect.** No hardware was touched. The cycle savings these
   levers buy (slope 355.17 -> 231.17 per position per C job) are inherited
   from MIDGAP's bench arithmetic and are **not** confirmed on silicon.
4. **Whether the ~0.4 ns noise floor is the right figure.** The cross-tree
   spread I measured is 0.745 ns, so the floor may be larger than recorded. The
   same-tree arms cannot settle it: separating placement variance from a real
   floor needs repeated runs of the SAME arm, which this track did not do.
5. **`SCORE_HDR_TREE`.** Untouched, left at 0 in every arm.

---

# COMPLETED BY THE DISPATCHER, 2026-09-21: the decomposition, from the arms this track left on disk

TRACK ATTNDRAW was terminated by an API weekly-limit error before it could
commit, and before it could report the `spon` decomposition it listed as
outstanding. **Its artefacts were untracked on disk and are committed here
unchanged**; this section is the only thing added, and it is the dispatcher's
work, not the track's.

`spon` completed `synth_design` and `opt_design` and never routed, so the
decomposition below is an AREA result only. There is no `tsum_spon.rpt` and the
timing decomposition remains open.

## Opt-stage census, all three arms, same tree `3e344a2`, same script

| | LUT cells | FF | vs `coff` |
|---|---:|---:|---|
| `coff` (both levers off) | 94,976 | 101,221 | baseline |
| `spon` (`SWEEP_PIPE` only) | 95,055 | 101,242 | **+79 LUT, +21 FF** |
| `con` (both on, = HEAD) | 95,061 | 101,244 | **+85 LUT, +23 FF** |

**THE AREA IS EXACTLY ADDITIVE WITHIN THIS TREE** (DERIVED from the three
censuses above):

```
LUT cells:  79 + 6 = 85     exact
FF:         21 + 2 = 23     exact
```

So `SCORE_EARLY` costs **+6 LUT cells and +2 FF** on top of `SWEEP_PIPE`, and
`SWEEP_PIPE` carries essentially the whole (tiny) cost of the pair.

Every other resource is identical to the digit in all three arms: `dsp48_exact`
298, `dsp_wildcard` 2,682, `uram288` 0, `ramb36` 3, `ramb18` 16, `lutram` 133,
`carry8` 2,741, `f8` 2,992, `srl` 29, `fdse` 683, `fdce` 0, `fdpe` 0. Only the
`lut*` and `ff` rows move, and `f7` by +1.

## Why this does NOT resolve the earlier +25 confusion by itself

The pair's `+23 FF` measured here equals LEVERCOST's figure for `SWEEP_PIPE`
ALONE on tree `bc4156f`. That is a coincidence of two different quantities and
not a cross-check: ATTNDRAW MEASURED that `SCORE_EARLY` has **zero occurrences
in `rtl/attn_block.vhd` at `bc4156f`**, so LEVERCOST drew `SWEEP_PIPE` on a block
that did not contain the other lever's code at all. Within-tree additivity says
nothing about whether two measurements from DIFFERENT trees may be summed, and
the evidence here is that they may not: `SWEEP_PIPE`'s own FF term reads +23 on
`bc4156f` and +21 here.

**The rule that survives: a decomposition is additive only inside one netlist,
and the parts must be drawn in the tree that contains all of them.**

## Not determined

- **The timing decomposition.** `spon` never routed. Only `coff` (2.356) and
  `con` (2.735) have routed WNS, and ATTNDRAW reported that 0.379 ns delta as
  NOT a result, pre-registered, because it is below the harness's noise floor.
- Whether these levers belong on a card build. An OOC draw cannot answer it.
- The mechanism of the FF shift between trees. ATTNDRAW established the 11
  `SWEEP_PIPE` state declarations are identical in both trees, so it is a sharing
  effect, and explicitly declined to claim more.
