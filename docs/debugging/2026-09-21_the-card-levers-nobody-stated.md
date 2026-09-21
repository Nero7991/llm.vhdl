// TRACK CBGUARD, 2026-09-21

# Make it impossible for a card build to silently pick a `CB_STYLE` nobody chose, and find out whether any other lever has the same shape

## 1. The question, verbatim

> **Make it impossible for a card build to silently pick a `CB_STYLE` nobody
> chose, and find out whether any other lever has the same shape.**
>
> [...] Establish first, by reading the code, exactly how the value flows: what
> `gen_pcieep.py` does with `FK33_CB_STYLE`, what default it applies, whether
> `hw/fk33/rtl/fk33_engine.vhd:72` (reported to default to `"regs"`) is a second
> independent default, and which of them actually decided build 11b. **Report
> what you find even if it contradicts the account above** - the account is
> secondhand and the code is authoritative.
>
> [...] For each environment variable read by `hw/fk33/gen_*.py` and
> `tools/gen_*.py`: its name, where it is read, and its default; whether that
> default is the value the SHIPPED build 9 used, or something else; whether the
> emitted file records the value (a GENSTAMP block) or not; whether any anchored
> sentinel reports it at build time. Sort the result by danger. [...] **That
> table is worth more than the guard.**

No Vivado started, no GHDL run, no hardware touched. Card build 12
(`card12-build.service`, `/mnt/storage/fk33_builds/build12`) was in synthesis
throughout and was not disturbed; the workstation was under a memory warning
and every measurement below is a Python process or a `grep`.

---

## 2. The answer, up front

**There are TWO defaults in series, not one, and the one that bound build 11b's
generic is the VHDL one.** `hw/fk33/gen_pcieep.py:601` defaults
`FK33_CB_STYLE` to `"regs"`, and at `"regs"` it emitted **no
`set_property CONFIG.CB_STYLE` at all** -- the whole lever-C block was inside
`if ENG_CB_STYLE != "regs":`. With no property set, the block-design cell keeps
`hw/fk33/rtl/fk33_engine.vhd`'s own `CB_STYLE : string := "regs"`. MEASURED,
from build 11b's own BUILD_ROOT copy of the Tcl:
`grep -c 'CONFIG.CB_STYLE' /mnt/storage/fk33_builds/build11b/root/build_fk33_pcieep.tcl`
is **0**, against **3** for build 10. So the generator's default decided that
*nothing overrode* the value; `fk33_engine.vhd` supplied it. The secondhand
account is right about the outcome and wrong about the mechanism, and the
difference matters: had the two defaults ever been made to disagree, an
**explicit** `FK33_CB_STYLE=regs` would have silently produced whatever the VHDL
said.

**AND BUILD 11b SILENTLY DEFAULTED A SECOND LEVER, WHICH NO WRITE-UP HAS
MENTIONED: IT RAN AT 200 MHz.** `FK33_ENG_CORE_MHZ` defaults to `200.000`
(`gen_pcieep.py:515`), the card has never closed above 75 MHz, and build 11b's
own routed timing report says
`clk_out3_bd_clk_wiz_0_0 {0.000 2.500} 5.000 200.000` where build 10's says
`{0.000 6.667} 13.333 75.000`. Its generated Tcl requested
`CLKOUT3_REQUESTED_OUT_FREQ {200.000}`; build 10's requested `{75.000}`.
**`hw/fk33/results/card_build11b_FAILED_2026-09-20/README.md`'s per-clock table
records `clk_out3 (core) | 13.333 ns` and that period is wrong**: the
`-9.762 ns` WNS is against a **5.000 ns** requirement, not 13.333.

**The whole silent condition reproduces from the generator in 70 ms with no
Vivado.** `FK33_CARD=1 python3 hw/fk33/gen_pcieep.py` against the committed
file's own stamped environment differs in exactly two functional places: the
core clock 75.000 -> 200.000, and the thirteen-line lever-C block deleted.

**The guard is a REFUSAL, not a changed default.** Under `FK33_CARD=1`,
`gen_pcieep.py` now exits non-zero unless `FK33_CB_STYLE` and
`FK33_ENG_CORE_MHZ` are both stated, and both are now announced by an anchored
sentinel on every build including when the stated value equals the default.

**The census's verdict: of the eleven environment variables read by any
generator in this tree, exactly the two now guarded have a default that differs
from what the shipping bitstream used. Everything else is already safe, and
three of them are safe for a reason worth copying -- their defaults are
card-aware (`"1" if CARD_ON else "4"`), which is the pattern these two were
missing.**

---

## 3. The procedure, in the order it was run, and what each step isolates

1. **Read the two prior write-ups and the failure README first**, so no
   measurement here re-derives what is already established. CBCENSUS owns the
   netlist evidence, CBREVERT owns the parameter-log evidence; this track owns
   the *harness*.
2. **Enumerate every environment read in every generator**, by
   `grep -nE 'os\.environ|getenv' hw/fk33/gen_*.py tools/gen_*.py`. Isolates
   the SIZE of the problem before any opinion about it: **only 2 of the 27
   generators read the environment at all.**
3. **Read the lever-C emission site, not the read site.** This is the step that
   found the two-defaults-in-series structure, and it is invisible from the
   `os.environ.get` line. The read site says what value the generator holds;
   the emission site says whether that value ever reaches the tool.
4. **Confirm from the BUILD'S OWN Tcl, not from the generator.**
   `grep -c 'CONFIG.CB_STYLE'` on `build10/root/` and `build11b/root/`. A claim
   about what a build contained is settled by the bytes that build read.
5. **Diff the two builds' requested clock configuration**, because step 4's
   command printed the CLKOUT3 line as a neighbour. This is how the second
   lever was found, and it was found by looking at the whole line rather than
   grepping for the name already under suspicion.
6. **Confirm the clock landed, from the routed timing report's Clock Summary**,
   not from the request. A `CONFIG.*` is a REQUEST; the achieved period is a
   result.
7. **Attribute the one unexplained line in CBCENSUS's parameter diff.**
   `CLKOUT2_DIVIDE 16 -> 6` had been listed as one of four differences and left
   unexplained; DERIVED against the MMCM's other parameters it IS the core-clock
   retarget.
8. **Census all twelve card implementation runs in `hw/fk33/results/card_*`**
   for the sentinel count, the bound generic and the clock, so the guard has
   more than two points. Every grep line-anchored.
9. **Reproduce the silent condition from the generator**, into a scratch
   directory via `--emit-to`, and diff it against a regeneration at the
   committed GENSTAMP's own values. No Vivado, no build root touched.
10. **Write the guard as a refusal in `main()`**, with the guarded set as data
    and the test as a function taking `env`, so the selftest and the build go
    down the same code path.
11. **Teeth: nine graded rows in-process plus three real subprocess runs**, and
    three rows that deliberately do not bite, reported under their own names.
12. **The attribution control: run the PRE-CHANGE generator** (from
    `git show HEAD:`) against the same conditions and grade it on the same
    criteria.

---

## 4. The evidence, as raw output

### 4.1 How the value flows. Four hops, and the third one is the defect

```
$ grep -n 'FK33_CB_STYLE' hw/fk33/pcieep_build.sh
                                        (no output -- the script never sets it)

$ sed -n 601p hw/fk33/gen_pcieep.py
ENG_CB_STYLE   = os.environ.get("FK33_CB_STYLE", "regs")

$ sed -n '1157,1158p' hw/fk33/gen_pcieep.py            # BEFORE this change
    if ENG_CB_STYLE != "regs":
        a("")                                          # the whole block is here

$ grep -n 'CB_STYLE : string' hw/fk33/rtl/fk33_engine.vhd
72:    CB_STYLE : string := "regs";
```

and then, from the two builds' own BUILD_ROOT copies of the Tcl, which is the
file Vivado actually sourced:

```
$ grep -c 'CONFIG.CB_STYLE' /mnt/storage/fk33_builds/build10/root/build_fk33_pcieep.tcl
3
$ grep -c 'CONFIG.CB_STYLE' /mnt/storage/fk33_builds/build11b/root/build_fk33_pcieep.tcl
0
```

**DERIVED: with zero `set_property` lines, the cell's generic came from
`fk33_engine.vhd:72`.** `gen_pcieep.py:601`'s default is what ensured nothing
overrode it. Both are `"regs"`, so the outcome is the same either way -- which
is exactly why the structure went unnoticed.

### 4.2 The second lever, MEASURED three ways

```
$ grep -n 'CLKOUT3_REQUESTED_OUT_FREQ' /mnt/storage/fk33_builds/build10/root/build_fk33_pcieep.tcl
369:set_property -dict [list CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {75.000}] [get_bd_cells clk_wiz_0]
$ grep -n 'CLKOUT3_REQUESTED_OUT_FREQ' /mnt/storage/fk33_builds/build11b/root/build_fk33_pcieep.tcl
393:set_property -dict [list CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {200.000}] [get_bd_cells clk_wiz_0]
$ grep -n 'CLKOUT3_REQUESTED_OUT_FREQ' /mnt/storage/fk33_builds/build11/root/build_fk33_pcieep.tcl
393:... {200.000} ...                        # build 11, the first attempt, also 200
```

The request became the achieved clock. From each build's own
`timing_summary_routed.rpt`, Clock Summary:

```
build 10   clk_out3_bd_clk_wiz_0_0   {0.000 6.667}   13.333    75.000
build 11b  clk_out3_bd_clk_wiz_0_0   {0.000 2.500}    5.000   200.000
```

and build 11b's Intra Clock Table, same report, same row:

```
  clk_out3_bd_clk_wiz_0_0   -9.762  -884240.500   494527   1147256   -0.022 ...
```

**So `-9.762` is against a 5.000 ns requirement.** DERIVED longest path
`5.000 + 9.762 = 14.76 ns`; at build 10's 13.333 ns requirement the same path
would have been roughly `-1.4`, not `-9.8`. No claim is made about what 11b
would have done at 75 MHz -- its route is illegal and this project already
records that nothing before a clean `route_design` orders two runs.

### 4.3 The one line CBCENSUS listed and did not explain

CBCENSUS's four-entry parameter diff includes
`CLKOUT2_DIVIDE bound to: 16` -> `6`. From the same two logs, all the MMCM's
parameters:

```
both builds:   CLKFBOUT_MULT_F 24.000000   DIVCLK_DIVIDE 5
               CLKOUT0_DIVIDE_F 12.000000  CLKOUT1_DIVIDE 6
build 10:      CLKOUT2_DIVIDE 16
build 11b:     CLKOUT2_DIVIDE  6
```

DERIVED: input 250 MHz / DIVCLK_DIVIDE 5 = 50 MHz, x CLKFBOUT_MULT_F 24 =
**VCO 1200 MHz**. Then 1200/12 = 100 (`clk_out1`), 1200/6 = 200 (`clk_out2`),
and **1200/16 = 75** against **1200/6 = 200** for `clk_out3`. Every figure
exact. **That parameter IS the core clock, it was in the diff the whole time,
and three tracks read it as noise.**

### 4.4 The census over every card implementation run with a log

Line-anchored throughout. `cbsent` is `grep -c '^FK33_CB_STYLE'`.

| results directory | cbsent | `Parameter CB_STYLE bound to` | `CLKOUT2_DIVIDE` | `^FK33_ENGI clock clk_out3` |
|---|---|---|---|---|
| `card_maxpos_grant_2026-09-18` | 1 | (not in this log) | (not in this log) | 13.333 ns, 75.00 MHz |
| `card_smp_bases_2026-09-18` | 1 | (not in this log) | (not in this log) | 13.333 ns, 75.00 MHz |
| `card_xexp_wdog_seam_2026-09-18` | 1 | (not in this log) | (not in this log) | 13.333 ns, 75.00 MHz |
| `card_bconst_qkn_2026-09-19` | 1 | distributed | 16 | 13.333 ns, 75.00 MHz |
| `card_seqrst_2026-09-19_ROUTEFAIL` | 1 | distributed | 16 | **(absent)** |
| `card_seqrst_bfnorm_2026-09-19` | 1 | distributed | 16 | 13.333 ns, 75.00 MHz |
| `card_kvreg_2026-09-20` (**build 9, shipping**) | 1 | distributed | 16 | 13.333 ns, 75.00 MHz |
| `card_build10_FAILED_2026-09-20` | 1 | distributed | 16 | 13.333 ns, 75.00 MHz |
| **`card_build11b_FAILED_2026-09-20`** | **0** | **regs** | **6** | **(absent)** |
| build 12 (running, from the coordinator) | -- | distributed x4, regs x0 | -- | -- |

**Eight of nine at `distributed`; seven of seven that produced a bitstream at
75 MHz. Build 11b is the sole outlier and it is the outlier on BOTH.**

And `^FK33_ENGI clock clk_out3` is absent in **exactly the two runs that failed
to route**, which is its resolution floor: it is a post-implementation
sentinel and cannot warn you during the 4 h 25 m before the failure.

### 4.5 The silent condition, reproduced from the generator with no Vivado

```
$ FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 \
      python3 hw/fk33/gen_pcieep.py --emit-to $S/base     # the committed stamp
$ sha256sum hw/fk33/build_fk33_pcieep.tcl $S/base/build_fk33_pcieep.tcl
a2dd2938521864069a225e03997755edb54872db6afa0ca42b428114da3d2a0a  hw/fk33/build_fk33_pcieep.tcl
a2dd2938521864069a225e03997755edb54872db6afa0ca42b428114da3d2a0a  .../base/build_fk33_pcieep.tcl

$ FK33_CARD=1 python3 hw/fk33/gen_pcieep.py --emit-to $S/post   # build 11b
$ diff -u $S/base/build_fk33_pcieep.tcl $S/post/build_fk33_pcieep.tcl
-#     FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 python3 hw/fk33/gen_pcieep.py
+#     FK33_CARD=1 python3 hw/fk33/gen_pcieep.py
-#     env  FK33_CB_STYLE      = distributed
+#     env  FK33_CB_STYLE      = (unset)
-#     env  FK33_ENG_CORE_MHZ  = 75
+#     env  FK33_ENG_CORE_MHZ  = (unset)
-...CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {75.000}...
+...CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {200.000}...
-# LEVER C, opt-in via FK33_CB_STYLE. [...13 lines...]
-set_property CONFIG.CB_STYLE {distributed} [get_bd_cells eng]
-set _cb [get_property CONFIG.CB_STYLE [get_bd_cells eng]]
-if {$_cb ne "distributed"} { error ... }
-puts "FK33_CB_STYLE $_cb"
```

Two functional differences and nothing else. Both are present in build 11b's
real Tcl (4.1, 4.2), so this is the condition and not a model of it.

### 4.6 THE SINGLE MOST DAMNING NUMBER: the two conditions were indistinguishable

Under the **pre-change** generator, an explicit
`FK33_CB_STYLE=regs FK33_ENG_CORE_MHZ=200` and stating nothing at all:

```
$ diff -u $S/old_regs/build_fk33_pcieep.tcl $S/old_11b/build_fk33_pcieep.tcl | grep -c '^[-+]'
8
```

and all eight lines are inside the GENSTAMP comment block. **Every byte Vivado
executes is identical.** So before this change, "someone chose `regs`" and
"nobody chose anything" differed only in a comment -- and in build 11b not even
that, because `wt11` predates the GENSTAMP commit
(`952e70a`, 2026-09-20 20:18, against build 11b's launch at 19:00:30) and
`grep -c GENSTAMP` on its BUILD_ROOT Tcl is **0**.

### 4.7 The attribution control. Does anything that already exists catch this?

The pre-change generator, from `git show HEAD:hw/fk33/gen_pcieep.py`, run under
each condition and graded on the same criteria. `cb_sent` and `mhz_sent` are
`grep -cE '^puts "FK33_CB_STYLE '` and `^puts "FK33_CORE_MHZ '`.

| generator | condition | rc | cb_sent | mhz_sent |
|---|---|---|---|---|
| **OLD** | build 11b (`FK33_CARD=1` only) | **0 ACCEPTED** | 0 | 0 |
| **OLD** | explicit `regs` / `200` | 0 accepted | **0** | 0 |
| **OLD** | ship `distributed` / `75` | 0 accepted | 1 | 0 |
| **NEW** | build 11b | **1 REFUSED** | -- | -- |
| **NEW** | explicit `regs` / `200` | 0 accepted | **1** | **1** |
| **NEW** | ship `distributed` / `75` | 0 accepted | 1 | 1 |

**The answer is NO, and it is worth being precise about what "no" covers:**

- **Nothing REFUSED.** Two instruments existed (`^FK33_CB_STYLE`, and Vivado's
  `Parameter CB_STYLE bound to`) and both are *records*. A record of a value
  nobody will read for a day is not a guard, and MEASURED, three tracks read
  these two logs before anyone noticed.
- **`hw/fk33/pcieep_build.sh` writes a `PROVENANCE.txt` containing
  `env | grep -E '^FK33_' | sort`, which WOULD have recorded the absence.**
  Two reasons it did not help: it was committed at `952e70a` on 2026-09-20
  **20:18**, after build 11b launched at 19:00:30 and in the live tree rather
  than `wt11` (`find hw/fk33/results -name PROVENANCE.txt` returns **0**
  files); and it records an unset variable as a **missing line**, which is the
  weakest signal there is and the one that already failed here.
- **`gen_pcieep.py --check` exists, is correct, and NOTHING SCHEDULES IT.** It
  reads the committed files' own GENSTAMP and regenerates under those values.
  It is not in `sim/regress.sh`'s `SELFCHECK_CMD`. See section 8.

So the guard is worth its maintenance: it is the only thing in the chain that
converts a record into a refusal, and it is the only thing that makes the
sentinel a positive signal.

### 4.8 Teeth. Twelve rows that bite, three that deliberately do not

`python3 hw/fk33/gen_pcieep.py --selftest`, which is gate row `sim:runguard`:

```
CARDLEVER guarded: FK33_CB_STYLE(ship distributed) FK33_ENG_CORE_MHZ(ship 75)
CARDLEVER ACCEPT  P1 builds 9/10/12, both stated
CARDLEVER ACCEPT  P2 both stated AT the defaults
CARDLEVER ACCEPT  P3 engine-only, no FK33_CARD at all
CARDLEVER ACCEPT  P4 FK33_CARD=0, explicitly off
CARDLEVER ACCEPT  P5 FK33_CARD=1 not the string 1
CARDLEVER REFUSE  N1 build 11b verbatim -> names FK33_CB_STYLE,FK33_ENG_CORE_MHZ
CARDLEVER REFUSE  N2 CB stated, clock not -> names FK33_ENG_CORE_MHZ
CARDLEVER REFUSE  N3 clock stated, CB not -> names FK33_CB_STYLE
CARDLEVER REFUSE  N4 present but EMPTY is unstated -> names FK33_CB_STYLE,FK33_ENG_CORE_MHZ
CARDLEVER NO-BITE M1 card at 200 MHz, STATED -- a stated value is accepted however unwise; this guard is not a reviewer
CARDLEVER NO-BITE M2 card at regs, STATED -- same: build 11b's mapping, chosen on purpose, is a decision
CARDLEVER NO-BITE M3 the other seven unstated -- FK33_ENG/FLATTEN/SYNTH_*/SPLIT_CLK/FAST_MHZ defaults equal the shipped values, so an unstated one is not a defect
CARDLEVER SUBPROC refused build 11b's environment, rc=1, both levers named
CARDLEVER SUBPROC accepted distributed/75   sentinels cb=1 mhz=1, CB_STYLE={distributed} CLKOUT3={75.000}
CARDLEVER SUBPROC accepted regs/200         sentinels cb=1 mhz=1, CB_STYLE={regs} CLKOUT3={200.000}
SELFTEST PASS
```

**The mutant is the THING.** Every row is a real environment mapping handed to
the same function `main()` calls, and the last three are real subprocess runs of
the generator graded on the process exit status and on the bytes it emitted. A
dict is a real environment; a subprocess is a real refusal. What a dict cannot
prove is that `main()` calls the guard at all, which is why N1 is also run as a
subprocess.

**The three NO-BITE rows are the resolution floor and are the most valuable
lines here.** M1 and M2 say that this guard checks whether a value was
**STATED**, never whether it was **WISE**: a card build explicitly at 200 MHz
or explicitly at `regs` is accepted. That is deliberate, and CBREVERT's own
words are the reason -- whether build 12 runs at `distributed` or `regs` *"is a
DECISION, not a finding"*. A guard that refused a decision would be refused in
turn, by someone setting an environment variable to get around it. M3 is the
scope boundary: the other seven stamped variables are not guarded because
MEASURED their defaults ARE what every routed card build used.

**`CARDLEVER SUBPROC accepted regs/200 sentinels cb=1 mhz=1` is the row that did
not hold before**, and 4.7 is its control: the same condition on the old
generator gives `cb=0 mhz=0`.

### 4.9 One teeth row was wrong when first written, and running it said so

The first draft graded "which lever did the refusal name" with
`name in refusal_text`. It reported **N2 naming both levers**, because the
refusal always ends with a re-launch command listing every guarded variable.
`name in text` is therefore true in every refusal, and the row would have agreed
with itself whatever the guard did. Re-anchored on the per-lever line
(`"%-18s unstated" % name`). **This is the self-match trap in a fifth place:
the haystack contained the needle because the helpful part of the message spells
out the thing being searched for.** It was caught by running the check, not by
reading it.

---

## 5. THE CENSUS. Every environment variable read by any generator, sorted by danger

**Only 2 of the 27 generators read the environment at all.** MEASURED:

```
$ for f in hw/fk33/gen_*.py tools/gen_*.py; do
      n=$(grep -cE 'os\.environ|getenv' $f); [ "$n" -gt 0 ] && echo "$f ($n)"; done
hw/fk33/gen_fk33_card.py (4)
hw/fk33/gen_pcieep.py (17)
```

All 25 others -- every `tools/gen_*.py` and five more `hw/fk33/gen_*.py` --
read **no** environment variable, so they cannot have this defect. That is the
census's first and most reassuring result and it took one command.

**Legend.** *ship* = the value the shipping card bitstream (build 9,
`card_kvreg_2026-09-20`) used. *recorded* = whether the generator's committed
output carries the value in a `tools/genstamp.py` block. *sentinel* = whether an
anchored line reports it at build time, and when.

### DANGER 1 -- default differs from the shipped value (the `CB_STYLE` shape)

| # | variable | read at | default | ship | recorded | sentinel | status |
|---|---|---|---|---|---|---|---|
| 1 | **`FK33_CB_STYLE`** | `gen_pcieep.py:601` | `regs` | **`distributed`** | yes | `^FK33_CB_STYLE`, **was emitted only when != regs** | **WAS THE DEFECT. Now refused if unstated; sentinel now unconditional.** |
| 2 | **`FK33_ENG_CORE_MHZ`** | `gen_pcieep.py:515` | `200.000` | **`75`** | yes | `^FK33_ENGI clock clk_out3`, **only after a successful route** | **THE SAME DEFECT, UNREPORTED UNTIL NOW. Build 11b took it. Now refused if unstated; new `^FK33_CORE_MHZ` fires at BD time.** |

These are the only two. Both are now guarded. Note how each was *almost*
instrumented: #1 had the right sentinel behind the wrong condition, #2 had the
right sentinel at the wrong stage. **Neither gap is visible from the
`os.environ.get` line, which is why a census of read sites is not a census of
risk.**

### DANGER 2 -- default matches the shipped value, and is card-aware. Copy this pattern

| # | variable | read at | default | ship | recorded | sentinel | why safe |
|---|---|---|---|---|---|---|---|
| 3 | `FK33_FLATTEN` | `gen_pcieep.py:3486` | `"none" if CARD_ON else ""` | `none` | yes | `^FK33_CARD FLATTEN_HIERARCHY = none`, MEASURED 1 in builds 9 AND 11b | the default is a function of `FK33_CARD`, so the card gets the card's value without stating it |
| 4 | `FK33_SYNTH_THREADS` | `gen_pcieep.py:3480` | `2 if CARD_ON else 8` | `2` | yes | `^FK33_CARD general.maxThreads = 2`, MEASURED 1 in builds 9 AND 11b | as above, plus a `>= 1` refusal |
| 5 | `FK33_SYNTH_JOBS` | `gen_pcieep.py:3474` | `1 if CARD_ON else 4` | `1` | yes | **none** | as above, plus a `>= 1` refusal. **Changes no netlist byte** -- it is a concurrency bound -- so an unnoticed value costs memory, not a design |

**This is the fix that was missing from #1 and #2 and it was already in the same
file, three times.** A card-aware default is strictly better than a refusal
where one exists, because it needs no discipline from the launcher; a refusal is
for the values where nobody wants the generator to choose.

### DANGER 3 -- default matches, and the lever is inert unless explicitly armed

| # | variable | read at | default | ship | recorded | sentinel | why safe |
|---|---|---|---|---|---|---|---|
| 6 | `FK33_ENG_SPLIT_CLK` | `gen_pcieep.py:544` | `""` (off) | off | yes | `^FK33_ENGSPLIT` (MEASURED 0 in build 9: correct, the split was off) | opt-in; `--selftest`'s `split_gate_teeth` asserts **none of 6 split fragments** appears in the text when off, so "off" is byte-checked rather than assumed. Refuses `=1` without `FK33_CARD=1` |
| 7 | `FK33_ENG_FAST_MHZ` | `gen_pcieep.py:545` | `200.000` | (inert) | yes | via `^FK33_ENGSPLIT` | read only when #6 is on; range-refused to 50..250 |
| 8 | `FK33_ENG` | `gen_pcieep.py:600` | `"1"` (on) | on | yes | `^FK33_ENG present=` -- MEASURED **0 in build 9**, it is a `--bd-only` line | the default is the shipped value, and an `FK33_ENG=0` build is unmistakable: no 28 HBM masters, no `eng` cell, and the generator's own header calls such a bitstream "NOT a working accelerator" |

### DANGER 4 -- the variable that SELECTS the configuration, so it is stated by construction

| # | variable | read at | default | ship | recorded | sentinel | why safe |
|---|---|---|---|---|---|---|---|
| 9 | `FK33_CARD` | `gen_pcieep.py:546,617,2141` | `""` (off) | **`1`** | yes | ~30 `^FK33_CARD *` lines, MEASURED present in builds 9 and 11b | its default differs from the card's value, but **you cannot get a card build by forgetting it**: unset yields an engine-only design with no B, C or D. It is the one variable whose omission is self-announcing, and it is the reason the *other* two were invisible -- setting it was the whole intent, so nobody looked further |

### DANGER 5 -- a second generator, already in the shape the first one should copy

| # | variable | read at | default | ship | recorded | sentinel | status |
|---|---|---|---|---|---|---|---|
| 10 | `FK33_C_KV_BLOCK` | `gen_fk33_card.py:490` | unset = keep the source literal | the literal | **yes, stamped**, and the value lands in the generated VHDL as `C_KV_BLOCK => N` | -- | **SAFE, and the best-engineered of the eleven.** Refuses a value outside the measured legal set `{16,32,64,128}` with the reason, refuses a non-positive integer, and refuses if the override matched anything other than exactly 1 generic. Gated two ways: `sim:fk33card` (`--check`) and `sim:kvmap`, which the file's own comment records as **complementary, neither redundant** |
| 11 | `FK33_A_ROWS_IF` | `gen_fk33_card.py:490` | unset = keep the source literal | the literal | yes, stamped | -- | **SAFE with one honest gap, which the file names**: it has no recorded legal set, and one was **deliberately not invented** -- *"a fabricated bound would be worse than none, because it would read as authoritative."* Agreed, and not changed here |

`gen_fk33_card.py` is not run by `pcieep_build.sh` at all -- only
`gen_i2cprobe.py`, `gen_fk33_engine.py` and `gen_pcieep.py` are -- so
`fk33_card.vhd` is read from the repo as committed. That makes #10 and #11
staleness risks rather than launch-time risks, and both staleness rows exist.

### What the census is NOT

- **It does not cover generators driven by `sys.argv`.** `hw/fk33/gen_hbmbw.py`
  takes positional arguments and CLAUDE.md already records it silently
  reproducing a file byte-identically while having exited on a range check. That
  is the same *class* -- an out-of-band input the output does not record -- by a
  different channel. Out of this brief's scope and **not measured here.**
- **It does not cover Tcl or shell variables.** `FK33_SYNTH_MAX_MIN`,
  `FK33_IMPL_MAX_MIN`, `FK33_STOP_AFTER_BD`, `FK33_BITTAG`,
  `FK33_REPORT_DIR`, `FK33_ABORT_ON_CONGESTION`, `FK33_TGROOT` and
  `BUILD_ROOT` are read by `pcieep_build.sh` or by the generated Tcl, never by
  a generator, so they change no committed byte. Bounds and reporting, not
  configuration -- but **none is stamped anywhere and this was not audited.**

---

## 6. Measured and REJECTED. Do not retry

- **"Change the default to the card's value."** REJECTED, on the generator's own
  recorded reason: `gen_pcieep.py:510` says the 200.000 default *"stays
  deliberately"* because *"the shipping shell+A bitstream met timing at 200 and
  must remain reproducible byte-for-byte; changing this constant in place would
  silently retarget it."* The same holds for `regs`, which is correct for the
  engine-only build that has produced bitstreams. **A changed default rewrites
  the meaning of every launch command already written down, including the ones
  in committed documents; a refusal rewrites the meaning of none.**
- **A guard in `hw/fk33/pcieep_build.sh`.** REJECTED. The GENSTAMP's own
  reproduce command invokes `gen_pcieep.py` directly, so a shell guard is
  bypassed by the documented way of regenerating. The generator is the only
  place the variable becomes Tcl.
- **A module-level `sys.exit` in `gen_pcieep.py`.** REJECTED, MEASURED:
  `hw/fk33/gen_fk33_regs.py` IMPORTS this file as a module to read the BAR map,
  so a module-level refusal would kill `gen_fk33_regs.py --check` whenever
  `FK33_CARD=1` happened to be exported in the ambient shell -- a gate row red
  for a reason unrelated to what it checks, which this file already records
  happening once to `sim:runguard`. With the refusal in `main()`,
  `FK33_CARD=1 python3 hw/fk33/gen_fk33_regs.py --check` is rc=0 (MEASURED).
  The cost is cosmetic: two `^FK33_CARDPINS`/`^FK33_CARDCLOSURE` lines print
  before the refusal.
- **Inventing a third instrument for `CB_STYLE`.** REJECTED per the brief and
  on the evidence: the existing `^FK33_CB_STYLE` sentinel was not missing, it
  was *conditional*. Moving it out of the `if` cost nothing and fixed both the
  sentinel and the two-defaults-in-series structure at once.
- **Grading "which lever did the refusal name" with `name in text`.** REJECTED,
  MEASURED failing: see 4.9.
- **Using `PROVENANCE.txt` as the guard.** REJECTED. It postdates build 11b, no
  committed results directory contains one, it is written by the harvest trap
  at the END of the build, and it reports an unset variable as an absent line.
- **Quoting `hw/fk33/results/card_build11b_FAILED_2026-09-20/README.md`'s
  `clk_out3 ... 13.333 ns`.** REJECTED: that period belongs to builds 9 and 10.
  Build 11b's own report says 5.000 ns. A correction belongs in that file and is
  noted in section 9 rather than edited here, because another track was editing
  it during this one.
- **Concluding anything about WHY build 11b failed to route.** Not attempted.
  This track adds a second uncontrolled variable to a comparison that already
  had four parameters and five RTL files differing; that makes the existing
  attributions weaker, never stronger. See section 7.

---

## 7. Measurement traps hit, including my own

1. **I went looking for one silent lever and there were two, and the second one
   was found by reading the LINE rather than grepping for the NAME.** The
   `CLKOUT3_REQUESTED_OUT_FREQ` difference appeared as a neighbour of the
   `CONFIG.CB_STYLE` count I had actually asked for. **A grep for the variable
   already under suspicion cannot find the variable that is not.** The cheap
   general form: when comparing two builds, diff the whole generated artefact
   once instead of grepping it n times.
2. **CBCENSUS's parameter diff contained the answer and labelled it noise.**
   `CLKOUT2_DIVIDE 16 -> 6` was printed, sorted, counted and published as one of
   four differences, in a document whose central point is that a multi-variable
   diff cannot attribute anything. The line was read as MMCM housekeeping.
   DERIVED in 4.3 it is a 2.67x clock retarget. **An enumeration of
   differences is only as good as the arithmetic done on each entry**, and the
   entries that look like tool internals are the ones nobody computes.
3. **THIS WEAKENS THE THREE EXISTING WRITE-UPS AND STRENGTHENS NONE OF THEM.**
   CBCENSUS, CBREVERT and the failure README all carefully refuse to attribute
   build 11b's outcome, and all three enumerate what differs. **None of the
   three lists the core clock.** The honest statement is now: builds 10 and 11b
   differ in `CB_STYLE`, `FAST_POP`, `HDR_TREE`, **the core clock period**, and
   five RTL files. Adding a fifth parameter to a comparison nobody was allowed
   to attribute anyway changes no conclusion -- but it does mean the congestion
   evidence sits beside a design being pushed at 2.67x the clock it has ever
   met, at 99.75% CLB occupancy, and **that is a first-order congestion
   mechanism which no document has considered.**
4. **The absent sentinel is a null result and I nearly read it as one again.**
   `grep -c '^FK33_CB_STYLE'` = 0 is compatible with "nobody chose", "someone
   chose regs", and "the sentinel does not exist in this version of the
   generator". 4.6 is what distinguishes them, and it needed the pre-change
   generator run as a subprocess. **An absence is only readable next to a
   presence from a comparable run** -- which is CBCENSUS's own recorded lesson,
   firing again one file later.
5. **The self-match trap, fifth occurrence, in my own teeth (4.9).** The helpful
   part of a refusal message spells out every variable it guards, so
   `name in message` is true in every refusal. Anchored on the per-lever line
   instead. Note the shape: the needle got into the haystack because the message
   was written to be *useful to a human*, which is not a mistake anyone would
   expect to invalidate a check.
6. **`^FK33_ENGI` is absent in exactly the two runs that failed to route**, so
   the one instrument that reports the core clock is silent precisely when the
   build goes wrong. MEASURED, 7 present of 7 bitstreams, 0 of 2 route failures.
   **An instrument that only fires on success measures the harness's happy
   path, not the job.**
7. **`grep -c 'GENSTAMP'` on build 11b's BUILD_ROOT Tcl is 0.** The stamp that
   would have recorded the two unset variables was committed 78 minutes after
   that build launched, into the live tree and not into `wt11`. **A record added
   after the fact does not retroactively record anything**, and I checked the
   date rather than assuming the mechanism had always been there -- which is the
   same check that CLAUDE.md records catching a stale area table.
8. **I did not run the gate.** Under a memory warning, `sim/regress.sh` peaks at
   2.13 GiB and the box had ~1 GB available beside a card build in synthesis.
   The gate row this track wants is handed over as a patch (section 8) and has
   been syntax-checked and `git apply --check`ed, not run. **A row that has been
   applied but not run is not a passing row, and this one is neither.**

---

## 8. The gate row, as a patch, NOT applied

`docs/debugging/2026-09-21_pcieep-stale-gate-row.patch`, verified with
`bash -n` on the edited copy and `git apply --check` against the current
`sim/regress.sh`. **It is not applied**: five tracks have queued row additions
and this project has MEASURED that editing `regress.sh` while a gate is live
corrupts the runner, because bash executes by byte offset.

**What it adds: `sim:pcieep`, running `python3 hw/fk33/gen_pcieep.py --check`.**
Four edits, in the three places `sim/regress.sh:2809` says a row needs plus the
row-purpose comment:

1. the `printf ... >> "$PLAN"` entry, after the `runguard` row (~line 1838)
2. `SELFCHECK_CMD[pcieep]` (~line 2835)
3. the dispatch case in `run_one` (~line 2977) -- the edit the old comment
   omitted and which silently sends a row down the testbench path
4. the comment block listing what each non-RTL row guards (~line 2803)

**Why it is worth a row.** `gen_pcieep.py --check` already exists, already
reads the committed files' own GENSTAMP and regenerates under exactly those
values, and **nothing in this tree runs it.** It is the
`compose4_top.vhd`-stale-since-`11bf64b` shape: a correct check with no
schedule. It costs one Python process and two files in a `tempfile.mkdtemp`; no
Vivado, no GHDL, no repo write. And it catches what `sim:runguard` structurally
cannot: `--selftest` grades the GENERATOR against its own properties, while
`--check` grades the COMMITTED OUTPUT against the generator. **MEASURED on this
very change: rewriting 22 lines of `build_fk33_pcieep.tcl` left `--selftest`
green throughout.**

---

## 9. Open, NOT determined

1. **Why build 11b failed to route is less settled than it was this morning,
   not more.** A fifth uncontrolled variable has been added to a comparison
   that already could not attribute anything, and it is a 2.67x clock retarget
   on a 99.75%-occupied design. **Nothing here identifies the cause and nothing
   here exonerates the codebook.** The one new thing worth registering: a
   200 MHz target is a plausible congestion mechanism, it has never been
   considered, and it is falsifiable by a re-implementation at 75 MHz from the
   preserved synthesis checkpoint -- except that the checkpoint was synthesised
   at 200 MHz, so the constraint difference is upstream of it and the control
   needs a fresh synthesis. **Not run, and not cheap.**
2. **Whether build 11 (the first attempt, not 11b) also ran at both defaults --
   YES for both, MEASURED from its BUILD_ROOT Tcl (`CLKOUT3 {200.000}`,
   `grep -c CONFIG.CB_STYLE` = 0) -- but what happened to that build was not
   investigated.**
3. **`hw/fk33/results/card_build11b_FAILED_2026-09-20/README.md` needs a
   correction**: its per-clock table gives `clk_out3` a 13.333 ns period and the
   report says 5.000 ns. **Not edited here**, because another track was editing
   that file during this one and a concurrent edit to a shared file is how this
   project loses work. Handed to the dispatcher.
4. **The three older card logs (`2026-09-18`) carry the `^FK33_CB_STYLE`
   sentinel but no `Parameter ... bound to` lines**, so their `CB_STYLE` is
   established from the sentinel alone and their `CLKOUT2_DIVIDE` not at all.
   Their `^FK33_ENGI` lines put them at 75 MHz. Two instruments, not three.
5. **`FK33_ENG_CORE_MHZ` is validated for range but not for card-legality.**
   `50..250` is the bound; nothing refuses 250 MHz on a card that has only ever
   closed 75. A card-aware default (`"75" if CARD_ON else "200"`) would be
   strictly better than the refusal and would match rows 3, 4 and 5 of the
   census -- **but it changes what an existing command means, which is exactly
   what section 6 rejects.** Whether the shipped card value should become a
   card-aware default is a DECISION for Oren, not a finding, and the refusal is
   the conservative half of it.
6. **The `sys.argv` generators were not audited** (section 5, "What the census
   is NOT"), nor were the eight `FK33_*` variables read only by
   `pcieep_build.sh` and the generated Tcl. Both are the same class through a
   different channel.
7. **Nothing here is a silicon measurement.** The card ran build 9's bitstream
   at 2.46 tok/s throughout and was not touched. No Vivado process was started
   by this track; card build 12 held the lane.
8. **The new `^FK33_CORE_MHZ` sentinel has never appeared in a real build.** It
   is present in the generated Tcl (MEASURED, `cb=1 mhz=1` in both accept
   rows) and its Tcl has not been executed by Vivado. The `get_property
   CONFIG.CLKOUT3_REQUESTED_OUT_FREQ` readback is the same idiom as the
   `CONFIG.CB_STYLE` readback beside it, which has run in eight builds, but
   **that is an argument by analogy and not a measurement.** The first card
   build after this change is its first real test, and if the property name is
   wrong it will `error` in the first minute rather than silently -- which is
   the failure direction to prefer, and is why it is written as a readback with
   an `error` rather than as a bare `puts`.

## 10. Reproduce

```
# the flow
grep -n 'FK33_CB_STYLE' hw/fk33/pcieep_build.sh          # no output
sed -n 601p hw/fk33/gen_pcieep.py
grep -n 'CB_STYLE : string' hw/fk33/rtl/fk33_engine.vhd  # :72
for b in build10 build11b; do
  grep -c 'CONFIG.CB_STYLE'            /mnt/storage/fk33_builds/$b/root/build_fk33_pcieep.tcl
  grep -n  'CLKOUT3_REQUESTED_OUT_FREQ' /mnt/storage/fk33_builds/$b/root/build_fk33_pcieep.tcl
done

# the achieved clock
cd hw/fk33/results
zcat card_build11b_FAILED_2026-09-20/timing_summary_routed.rpt.gz | grep -A12 'Clock Summary'
zcat card_build10_FAILED_2026-09-20/timing_summary_routed.rpt.gz  | grep -A12 'Clock Summary'
zgrep -ahE 'Parameter (CLKFBOUT_MULT_F|DIVCLK_DIVIDE|CLKOUT[0-9]_DIVIDE(_F)?) bound to' \
      card_build1*_FAILED_2026-09-20/build.stdout.full.gz | sort -u

# the silent condition, no Vivado
S=/mnt/storage/fk33_builds/scratch/cbguard_20260921
FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 \
    python3 hw/fk33/gen_pcieep.py --emit-to $S/base
FK33_CARD=1 python3 hw/fk33/gen_pcieep.py --emit-to $S/post
diff -u $S/base/build_fk33_pcieep.tcl $S/post/build_fk33_pcieep.tcl

# the attribution control
git show <this commit>^:hw/fk33/gen_pcieep.py > hw/fk33/.cbguard_oldgen.py
FK33_CARD=1 python3 hw/fk33/.cbguard_oldgen.py --emit-to $S/old_11b   # rc 0
FK33_CARD=1 FK33_CB_STYLE=regs FK33_ENG_CORE_MHZ=200 \
    python3 hw/fk33/.cbguard_oldgen.py --emit-to $S/old_regs
diff -u $S/old_regs/build_fk33_pcieep.tcl $S/old_11b/build_fk33_pcieep.tcl  # 8 lines, all GENSTAMP
rm -f /home/orencollaco/GitHub/llama.vhdl/hw/fk33/.cbguard_oldgen.py

# the guard and its teeth
FK33_CARD=1 python3 hw/fk33/gen_pcieep.py                # rc 1, the refusal
python3 hw/fk33/gen_pcieep.py --selftest | tail -18      # CARDLEVER rows
python3 hw/fk33/gen_pcieep.py --check                    # PASS, and unscheduled
```
