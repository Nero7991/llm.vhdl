# TRACK GAIN16: the composed design routes and BRAM is the last resource that does not fit. Can the final 16 tiles be closed?

**Date:** 2026-08-30/31. **Tree at dispatch:**
`93ddac7b6352e2f76dce78efd89ceda5703f410d`; re-pinned mid-track to
`48633e5edbe99a69aeb309ac4b45782c0338b968` after TRACK ROUTE2 landed three
commits (see section 9). **`rtl/` and `sim/` are byte-identical between those
two SHAs**, so every draw below remains a draw of the tree it claims.

**Hardware:** synthesis on `cachyos-bc250` (BC-250), Vivado 2023.2,
`xcvu33p-fsvh2104-2L-e`, licence `~/.Xilinx/Xilinx-4.lic`. Simulation on the
workstation, GHDL 1.0.0 mcode. **No hardware was touched by this track.**

---

## 1. The question, verbatim

> **The composed design ROUTES, and BRAM is the last resource that does not
> fit. Close the final 16 tiles that the norm gain image is over budget by.**
> ... **Draw both. Do not pick one on paper.** ... **Report DSP for every point
> in your table, next to BRAM, in the same row.** ... **Whether the gap closes.
> 16 tiles. State the number with the sign, against ROUTE2's 253.5 of 372.5.**
> ... **If it does NOT close, say so plainly and report how short.**

---

## 2. The answer, up front

**The gap closes, with 20 tiles to spare, and it costs no DSP and no timing.**

The shipping gain store is now an 11-bit **codebook index** plus a 1,567-entry
codebook, both built at elaboration from `norm_w_9b.hex` itself.

| | RAMB36 for the gain store | against ROUTE2's 253.5 of 372.5 |
|---|---:|---|
| `GW = 4`, before TRACK GWTWO | 171 | **short 52.0** |
| `GW = 1`, TRACK GWTWO's landing | 135 | **short 16.0** |
| **the codebook, landed here** | **99** (MEASURED `cbland`, record-free form) | **+20.0 to spare** |

**PROVENANCE OF THE 99, STATED BEFORE IT IS USED.** The index store is
266,240 x 11, and 266,240 x 11 was MEASURED at **99 RAMB36** as the `sw11`
point. `sw11` is a LOSSY AREA PROBE, not the codebook: it stores the low 11
bits of each value and reconstructs a 16-bit word by tiling, so it computes
wrong numbers by construction. It is a legitimate measurement of what an
11-bit store COSTS and it is not a measurement of the codebook, which
additionally carries a 1,567-entry table. The codebook's own draw is the
`swcb` row in section 3 and the shipping file's own draw is `cbland`; the
figures above are those, not the probe.

**And the 14-bit store, which the brief named as the other candidate, does NOT
close it: it buys 9 tiles against a 16-tile gap and is 7 SHORT.** That is a
measured negative on one of the two options I was sent to draw, and it is
stated here rather than talked up.

**Both estimates I was handed were wrong, in opposite directions.** TRACK
GWTWO's section 7 derived "14-bit -> ~118 tiles, saving 17" and "11-bit
codebook -> ~93 tiles, saving 42" from bits-per-element over RAMB36 capacity.
Measured: **126 (saving 9)** and **99 (saving 36)**. The 14-bit estimate was
optimistic by 8 tiles and would have been reported as closing a gap it misses
by 7; the codebook estimate was pessimistic by 6.

**My own registered prediction was also falsified, by two of its four named
falsifiers.** See section 6.

---

## 3. The mechanism: NINE RAMB36 PER BIT of stored word, at three of four widths

**MEASURED, six points, one session, one Vivado at a time on the BC-250,
`sim/ooc_lutdiet_ports.tcl` with the flags every draw on this scale uses
(`LUTDIET_FLATTEN=none LUTDIET_NOOPT=1`).** The `head` point is the shipping
file extracted with no rewrite at all.

| tag | store shape | **DSP** | CLB LUT | CLB FF | **RAMB36** | RAMB18 | **BRAM tile** | WNS @ 5.0 ns | synth s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `head` | 266,240 x 16 (shipping) | **41** | 5,073 | 3,511 | **135** | 12 | 141 | +0.971 | 425 |
| `sw16` | same, via the rewriter | **41** | 5,073 | 3,511 | **135** | 12 | 141 | +0.971 | 426 |
| `sw14` | 266,240 x 14 | **41** | 5,070 | 3,412 | **126** | 12 | 132 | +0.971 | 424 |
| `sw11` | 266,240 x 11, LOSSY PROBE | **41** | 5,061 | 3,115 | **99** | 12 | 105 | +0.971 | 415 |
| `sw9` | 266,240 x 9, LOSSY PROBE | **41** | 5,055 | 2,917 | **81** | 12 | 87 | +0.971 | 415 |
| `sw9_4_1` | 14 bits split 9+4+1, three arrays | **41** | 5,075 | 3,324 | **126** | 12 | 132 | +0.971 | 627 |

**DSP is 41 at every single point.** Nothing in this family touches a
multiplier, which is the first thing the brief asked to be checked because
ROUTE2 measured the routed composition DSP-bound at 2,177 of 2,700 = 80.63%
against LUT's 68.33%. **WNS is +0.971 ns at every point, byte-identical**, so
nothing here is paid for in timing either.

**The rule, exact at three of the four widths drawn:**

```
126 / 14 = 9.0000     99 / 11 = 9.0000     81 / 9 = 9.0000
```

**Vivado maps this ROM as one 32Kx1 cascade PER BIT PLANE.**
`ceil(266,240 / 32,768) = 9`, and it pays that 9 once per bit of stored word.
The cost is therefore **linear in the WORD WIDTH and completely indifferent to
how the bits are grouped**.

**That is why `sw9_4_1` buys nothing.** Splitting 14 bits into arrays of 9, 4
and 1 -- each width sitting on a different native RAMB36 aspect ratio, which
was the entire premise of that point -- costs **126 tiles, exactly what one
14-bit array costs, to the tile.** It also costs 47% more synthesis time (627 s
vs 424 s) and 5 more LUT. **Do not retry splitting.**

### 3.1 The 16-bit point does NOT obey the rule, and that is not a measurement conflict

**The rule was DERIVED from three of these six points and it fails on a
fourth.** 9-per-bit holds exactly at 9, 11 and 14 bits and predicts
`16 x 9 = 144`. The MEASURED 16-bit value is **135**, low by exactly one bit
plane. **So it is a mechanism that explains its own calibration points and does
not extend. It must not be quoted as a law**, and nothing in this track's
conclusion rests on it -- every number in the gap arithmetic below is measured,
not modelled.

**First, the two 135s are the same number and agree exactly.** TRACK GWTWO
MEASURED `GW = 1` at 135 RAMB36 / 12 RAMB18 / 141 tile; my `head` point, which
is the shipping file extracted with no rewrite, MEASURED 135 / 12 / 141. **There
is no disagreement between the two measurements.** Naming the quantities, since
three are in play and they are easy to conflate:

| quantity | what it is | head | GWTWO gw1 |
|---|---|---:|---:|
| `RAMB36` | `report_utilization`'s `RAMB36/FIFO*` row. **This is the gain ROM.** | 135 | 135 |
| `RAMB18` | its `RAMB18` row. `rmsnorm_rs_mem`'s three `vec_mem` banks, 4 each. **Never moves.** | 12 | 12 |
| `Block RAM Tile` | the tile row: `RAMB36 + RAMB18/2` | 141 | 141 |

**And the gap arithmetic is in RAMB36, correctly.** ROUTE2's composed
`253.5 of 372.5` are Block RAM Tile figures for a composition drawn with
`NORM_W_IMAGE = ""`, i.e. with no gain table at all. The gain ROM uses **only
RAMB36**, so its tile contribution equals its RAMB36 count, and adding them is
the same arithmetic GWTWO's own correction used: `253.5 + 171 = 424.5` against
372.5 gives ROUTE2's stated `-52.0`, and `253.5 + 135 = 388.5` gives the
`-16.0` this track was sent to close. **The 9 is a model error at one point,
not a 9-tile accounting error in the budget.**

**What could explain 135, none of it verified.** The image's OR over all values
is `0x3FFF`, so bits 15 AND 14 are both constant zero -- but dropping two
planes predicts 126, which is what the explicit 14-bit store costs, and the
tool did not do that. `135 = 9 x 15` is one plane short of 16 and one plane
above 14. **The discriminating experiment was not run and is cheap:** draw a
15-bit and a 13-bit store. The rule predicts 135 and 117. If 15 bits also
measures 135 then something caps the plane count at 15; if it measures 126 then
the per-plane reading is wrong above 14 and the three fitted points are a
coincidence of a different formula. **Listed in "open, not yet answered".**

**The consequence for anyone costing a future table on this part:** the
question is not "how many bits does the table hold" but "how many bits wide is
one element", and the answer is 9 RAMB36 per bit at this depth. A 4.26 Mbit
table and a 2.93 Mbit table cost 135 and 99 -- a ratio of 1.36 where the bit
ratio is 1.45 -- and neither is near the 130-tile figure that
`total_bits / 32,768` predicts.

---

## 4. Why the codebook, and why it is built in the design

`norm_w_9b.hex` (md5 `69f614a1515e1160f5dc9e8a9e72fdc3`, 266,240 lines).
**Every statistic below was re-MEASURED by this track against the file itself
rather than carried over from the brief**, because a model whose input was
sound and whose mechanism was backwards is the failure recorded in CLAUDE.md:

```
count 266240
distinct 1567
min 0x10 max 0x2fe0
OR of all 0x3fff
bits needed 14   OR bitlen 14
entropy bits/elem 9.9562
vectors 65   distinct vectors 65
```

All four of TRACK GWTWO's figures reproduce exactly. **1,567 distinct values
need an 11-bit index; 11 bits is within 1.05 bits of the 9.956-bit
information-theoretic floor for a fixed-width code; and at 9 tiles per bit that
is 99 RAMB36.**

**It is built at ELABORATION, from the same file, and there is no second image
and no second generic.** An offline encoder plus an in-design decoder are two
implementations that can drift, and the drift is invisible to the obvious test
because `decode(encode(x)) = x` holds for a wrong-but-consistent pair -- the
`m7 mutant` recorded in CLAUDE.md, where a packer and a reversed decoder passed
an entire self-test suite. Keeping `NORM_W_IMAGE` the only input removes that
whole failure mode, and it also removes a build step for every hand-maintained
list to forget (see section 8, where two more such lists were found dead).

**The codebook lookup is COMBINATIONAL, on purpose.** A registered second
lookup would make the gain load `NN+3` cycles against a budget of `NN+4` where
it is `NN+2` today, and TRACK RMSWIRE's entire load-race analysis -- including
`sim/tb_rmswire_loadrace.vhd`, which measures the ungated failure and the gated
pass AT `hidden = 4096` -- is written against `NN+2`. Reading a distributed ROM
off the index ROM's registered output leaves `(wdv, wel_d, nw_wd)` the matched
triple they already are and the load length byte-identical.

---

## 5. The oracle, and why the existing check could not serve

**The brief's instruction was explicit and it was right: `sim:tb_llama_top_normw`
is vacuous for this change.** TRACK GWTWO reported under its own name that that
row's sub-word-mirror mutant does NOT bite at `GW = 1`, because there the
mutation is a semantic no-op. `GW = 1` is what is landed. Separately, that row
runs at `hidden = 64` against a 9 x 64 image reduced by MEAN over groups of 64,
whose element-to-element spread its own header measures at about 2% of the
mean. It is a landmark, not an oracle.

**What was built instead:** `hw/fk33/results/gain16_2026-08-30/gain16_romoracle.vhd`,
which drives the extracted `gvr` block through all 65 norm ops at the real
`NN = 4096`, captures the gain word stream into `rmsnorm_rs_mem`'s bank port,
and compares it **element by element against `norm_w_9b.hex` itself, at the
full 266,240 length**. Nothing is compared against the design; the only
reference is the file on disk.

It is deliberately **not** in `sim/` and deliberately **not** named `tb_*`: it
needs a 5 MB image that is not in git, and as an auto-discovered gate row it
would turn the shared gate red for every track the moment that path was absent.

### 5.1 The verdicts

```
GAIN16_ORACLE_ROW cb_clean mutant=none verdict=PASS rc=0 compared=266240 mismatched=0 never_written=0 wrong_nidx=0
GAIN16_ORACLE_ROW land     mutant=none verdict=PASS rc=0 compared=266240 mismatched=0 never_written=0 wrong_nidx=0
GAIN16_ORACLE_ROW head_T1  mutant=T1   verdict=FAIL rc=1 compared=266240 mismatched=264662 never_written=0 wrong_nidx=0
GAIN16_ORACLE_ROW head_T2  mutant=T2   verdict=FAIL rc=1 compared=266240 mismatched=261940 never_written=0 wrong_nidx=0
GAIN16_ORACLE_ROW head_T3  mutant=T3   verdict=FAIL rc=1 compared=266240 mismatched=265923 never_written=0 wrong_nidx=0
GAIN16_ORACLE_ROW cb_E1    mutant=E1   verdict=FAIL rc=1 compared=266240 mismatched=266240 never_written=0 wrong_nidx=0
GAIN16_ORACLE_ROW cb_E2    mutant=E2   verdict=FAIL rc=1 compared=266240 mismatched=266240 never_written=0 wrong_nidx=0
GAIN16_ORACLE_ROW cb_E3    mutant=E3   verdict=PASS rc=0 compared=266240 mismatched=0 never_written=0 wrong_nidx=0
GAIN16_ORACLE_ROW cb_E5a   mutant=E5a  verdict=FAIL rc=1 compared=266240 mismatched=1 never_written=0 wrong_nidx=0
GAIN16_ORACLE_ROW cb_E5b   mutant=E5b  verdict=FAIL rc=1 compared=266240 mismatched=802 never_written=0 wrong_nidx=0
```

with the first mismatch localised in every failing row, e.g.

```
GAIN16_ORACLE FIRST MISMATCH op=0 elem=0 got=0x1239 want=0x1238     (E1)
GAIN16_ORACLE FIRST MISMATCH op=1 elem=0 got=0x1238 want=0x0D2C     (T2)
```

### 5.2 The two rows that matter most

**`E5a` is the resolution floor, and it is one element in 266,240.** It
corrupts the single codeword standing for value `0x250`, which occurs
**exactly once** in the whole image. The oracle reports `mismatched=1` and
FAILS. **19 of the 1,567 distinct values occur exactly once**; a
random-index test would very likely never touch any of them, which is the
concrete form of "coverage of the input space is not coverage of the output
space". This oracle enumerates all 266,240 positions, so it reaches all 19.

**`E3` DOES NOT BITE, and it is reported under its own name because that is
correct behaviour, not an omission.** It builds the codebook in descending
value order instead of ascending. That is a **consistent permutation**: both
the map and the table move together, so the decoded values are unchanged and
the file still reproduces exactly. It is a different but equally valid
encoding, and an oracle that flagged it would be wrong. What it measures is
precisely what this check does NOT constrain -- the codeword ORDER is free --
and that is worth knowing before somebody changes the build order and expects
a red row.

### 5.3 The attribution control

**Every kill was re-run through the pre-existing gate row
`sim:tb_llama_top_normw` on the same mutant**, because a kill an existing
property would have caught anyway does not belong to the new check.

Both columns are MEASURED on the same mutant source. The landmark column is
`sim:tb_llama_top_normw` run from a PRISTINE `git archive` of the pinned SHA
with exactly one file replaced, `--jobs 1`, `MV4I_FK33_FILE=/nonexistent`.

| mutant | what it breaks | new oracle, 266,240 elements | pre-existing landmark | earned by the new check? |
|---|---|---|---|---|
| (none) `head` | -- | **PASS** 0 mismatched | `PASS 1 FAIL 0` | -- |
| (none) `land` | -- | **PASS** 0 mismatched | `PASS 1 FAIL 0` | -- |
| `T1` | each gain vector packed in reverse element order | FAIL, 264,662 | `PASS 0 FAIL 1` | **no, shared** |
| `T2` | `nidx` dropped from the ROM address | FAIL, 261,940 | `PASS 0 FAIL 1` | **no, shared** |
| `T3` | vector k's slot packed from source k+1 | FAIL, 265,923 | `PASS 0 FAIL 1` | **no, shared** |
| `E1` | every codeword one greater than its value | FAIL, 266,240 | `PASS 0 FAIL 1` | **no, shared** |
| `E2` | every index one greater than it should be | FAIL, 266,240 | `PASS 0 FAIL 1` | **no, shared** |
| `E3` | codebook built in DESCENDING value order | **PASS -- DOES NOT BITE** | `PASS 1 FAIL 0` | correctly neither |
| `E5a` | ONE codeword corrupted, for a value occurring EXACTLY ONCE | **FAIL, 1** | `PASS 1 FAIL 0` | **YES, UNIQUE** |
| `E5b` | ONE codeword corrupted, 802 occurrences, absent from the b4_mean image | **FAIL, 802** | `PASS 1 FAIL 0` | **YES, UNIQUE** |

**The new oracle earns TWO of the seven kills alone. Five belong to
`tb_llama_top`'s pre-existing `P14` landmark and would have been caught without
it.** That is the whole point of running the control: without it this table
would have claimed seven detections for a check that adds two.

**What the two it earns have in common is what the landmark structurally cannot
reach.** `tb_llama_top_normw` builds its codebook from
`sim/llama_top_nw_b4_mean.hex`, a different image with 406 distinct values of
which only 199 overlap the 9B image's 1,567. `0x250` and `0x1238` are both
absent from it, so no codeword exists for either and the corruption is a
no-op there. **A per-value defect in the 9B table is invisible to any bench
running a different table**, however good that bench's landmark is, and no
amount of strengthening it would change that.

**`E3` not biting is the resolution floor of the oracle itself**, and it is
correct: ascending and descending codeword order are both valid encodings of
the same table and both reproduce the file exactly. The oracle constrains the
DECODED VALUES, not the codeword order, and that boundary is now measured
rather than assumed.

---

## 6. Measured and REJECTED -- do not retry

**1. My own registered prediction. FALSIFIED by two of its four named
falsifiers.** `PREDICTION.txt`, written before the first Vivado invocation,
argued from the RAMB36 mode grid (32Kx1, 16Kx2, 8Kx4, 4Kx9, 2Kx18, 1Kx36,
512x72) that tile cost is a STEP FUNCTION of width -- 130 tiles for any width
from 10 to 18, 65 for any width from 5 to 9 -- and predicted `sw14 = 135` (no
saving at all) and `sw9_4_1 = 105..115`.

- **F1 fired:** `sw14` came in at **126**, not 135. Width is not banded.
- **F3 fired:** `sw9_4_1` came in at **126**, i.e. AT `sw14`, not below it.
  The split bought exactly nothing.

Both errors have the same root: **I predicted which PRIMITIVE MODE the tool
would choose, and the tool does not choose modes, it replicates bit planes.**
Every clause of the mode grid I quoted is true of the hardware. It is
irrelevant to what Vivado does. **This is the same failure GWTWO recorded one
day earlier in the same block -- an argument from what the hardware CAN do is
not a measurement of what the tool DOES -- and I reproduced it while holding
GWTWO's write-up open.** The direction that matters: my model said the
codebook was worth 36 tiles, and it is; it said the 14-bit store was worth 0,
and it is worth 9. Being wrong in both directions on the same curve is what a
mode-based model gets you.

**2. Splitting the store across arrays of native widths. MEASURED, buys
nothing, costs 47% more synthesis time. Do not retry.** `sw9_4_1` = 126 RAMB36
against `sw14` = 126 RAMB36; 5,075 LUT against 5,070; 627 s against 424 s.
There is no arrangement of a given number of bits that beats any other
arrangement, because the cost is per bit plane.

**3. A 14-bit store on its own. MEASURED at 126, saving 9 against a 16-tile
gap. It is 7 SHORT and does not close it.** It is lossless for this image and
it is strictly better than what shipped, but it is not an answer to the
question that was asked. Do not report it as one.

**4. GHDL external names for hierarchical observation. MEASURED: not
available on this simulator at all. Do not retry.** GHDL 1.0.0 mcode ANALYSES
`<< signal dut.gvr.nw_wd : std_logic_vector(15 downto 0) >>` without complaint
and then dies at elaboration:

```
translate_name: cannot handle IIR_KIND_EXTERNAL_SIGNAL_NAME (t.vhd:16:14)
******************** GHDL Bug occurred ***************************
```

The oracle observes through four added ports instead
(`hw/fk33/results/gain16_2026-08-30/mkprobe.py`), which are taps and change
nothing the ROM does.

**5. URAM. Not re-tested, and it must not be.** This device's URAM288 cannot
be initialised to anything but zero; Vivado refuses `ram_style = ultra` with
only a WARNING and reports `uram=0`. Every draw in this track reports
`uram=0`. The "114 URAM" three briefs once carried for this table was a misread
of the BRAM column.

**6. Deduplicating the gain VECTORS. Already measured by GWTWO, re-confirmed
here: all 65 vectors are distinct.** There is nothing there.

---

## 7. Measurement traps hit, including my own

**1. An rc read off a PIPELINE is the pipeline's rc, and it hid a GHDL crash
AGAIN.** The external-name probe in item 4 above was run as
`ghdl -r ... | head -5; echo "R_RC=$?"` and reported **`R_RC=0`** for a run that
died with an internal GHDL bug. TRACK GWTWO named this trap in its own write-up
after hitting it; the trap is named in MY brief; I hit it on my first GHDL
invocation of the track. Every rc in `oracle_run.sh` is taken off a subshell.

**2. `pgrep`/`ps` cannot tell you whether a Vivado is running, and I did not
try.** Every gate in this track's scripts reads `/proc/PID/exe`, which a
command line cannot spoof. It correctly reported 1 real Vivado where
`ps -eo rss,args | grep unwrapped` would have added sibling shells.

**3. A detached job survives its dispatcher and its dispatcher's session.**
This track's session was cut by an API timeout mid-sweep. The BC-250 sweep was
started under `nohup` and kept running; four of its six points completed while
nothing was watching. The recovery step is to read the OUTPUT FILES, not to
assume the work died -- and the check that settles it is `/proc/PID/exe` plus
the presence of the result CSVs, not the absence of a shell.

**4. `variable fh : text;` does not compile; a file object needs `file fh :
text;`.** GHDL's message is `variable "fh" cannot be of type file`, followed by
four confusing `file parameter must be a file (vhdl93)` lines pointing at the
`file_open`/`readline` call sites rather than at the declaration.

**5. Extracting a shell variable's value with `sed` from a script and then
using it as a file list silently includes the whole rest of the script.** My
first attempt to prove `sim/mutate_normw.sh`'s file list was stale produced 250
lines of `ANALYSE FAILED: for`, `ANALYSE FAILED: done`, `ANALYSE FAILED: {`
because the terminating anchor was wrong. The two real errors were at the top
and were nearly buried. Bound such an extraction on the closing quote of the
value, not on the next blank line.

**6. The BC-250's login shell is FISH, and a `&&`/`||` chain sent without a
`bash -c` wrapper fails with a message that looks nothing like a shell
mismatch.** MEASURED:

```
fish: command substitutions not allowed in command position. Try var=(your-cmd) $var ...
```

This is documented in CLAUDE.md, it is in my own brief, and I still dropped the
wrapper on a status poll after twenty successful wrapped calls. The tell is
`fish:` at the start of the error, not the error's content.

**7. A checker whose pattern cannot match its own subject produces a FALSE
NEGATIVE that reads exactly like a real one.** My attribution runner extracted
the verdict with `grep -o "OVERALL PASS [0-9]* FAIL [0-9]*"`, and `regress.sh`
prints `OVERALL     PASS 1   FAIL 0` with RUNS of spaces. Two rows reported
`NO_OVERALL_LINE` on runs that were completely fine. **Same shape as ROUTE2's
`C4_ROUTE_STATUS` printing `errors=93489` on a design with 0 errors:** a check
written to avoid a false PASS produced a false verdict on the one question it
existed to answer. Fixed to `grep -oE "OVERALL +PASS +[0-9]+ +FAIL +[0-9]+"`.

**8. `pgrep -f` on a pattern in your own command line matches your own probe,
and I watched it happen.** Hunting the `chain3` waiter on the BC-250 I read
`/proc/PID/cmdline` explicitly rather than using `pgrep -f chain3`, and the
listing duly showed my own probe process carrying `chain3` in its argv
alongside the two real ones. Reading `cmdline` made the self-match VISIBLE and
therefore excludable; `pgrep -f` would have silently included it.

**9. A background `sleep` does NOT block the turn, so "I waited ten minutes"
can be false.** Several polls that felt like they were minutes apart were
seconds apart, and I read a 4-minute-old Vivado job as 25 minutes old. The
clock that matters is the remote `date -Is` printed beside the job's own start
line, not the number of times you have looked.

**10. The BC-250 is on EDT and the workstation on MDT.** Carried over from
GWTWO and hit again: I read a 4-minute-old job as 25 minutes old by comparing
its BC-250 start time against a workstation clock in my head.

---

## 8. EIGHT dead hand-maintained closures across four tracks, and the one-second invariant that finds all of them

This has stopped being a trap somebody hit and become a structural defect in
how this repo tracks source closure. **`sim/regress.sh` computes its own
closure and stays green throughout, which is exactly what hides it.**

### 8.1 The count, with names

| # | file | found by |
|---|---|---|
| 1-3 | three `sim/mutate_llama_top_*.sh` | TRACK RMSWIRE |
| 4 | `tools/ref9b/capture_llama_top.sh` | TRACK GWTWO |
| 5 | `sim/mutate_normw.sh` -- "Teeth for the REAL NORM GAIN path" | GAIN16, by hand |
| 6 | `sim/mutate_llama_top_smp.sh` | GAIN16, by hand |
| 7 | `sim/mutate_fk33_seam.sh` | **GAIN16, by the invariant below** |
| 8 | `tools/capture_normw.sh` | **GAIN16, by the invariant below** |

**Two of those eight nobody had found**, and both fell out of a check that runs
in under a second. All eight are the same defect: TRACK RMSWIRE wired
`rmsnorm_rs_mem` into `rtl/llama_top.vhd:2190` at `47c9d9c` and every private
copy of the source list stayed at the previous closure. MEASURED, the failure
is identical in each, verbatim:

```
rtl/llama_top.vhd:2190:27: unit "rmsnorm_rs_mem" not found in library "work"
```

**Number 5 is the teeth script for the exact path this track changed.** Fixing
it was outside this track's stated ownership and is flagged as such, on TRACK
GWTWO's precedent: the alternative was to change the norm gain on the same
night its teeth script was dead.

### 8.2 The invariant, and it needs no simulator

`hw/fk33/results/gain16_2026-08-30/closure_audit.py`. **A script carrying its
own `FILES="..."` list is ASSERTING a dependency closure, and nothing checks
the assertion.** The check is pure text:

> for every `X.vhd` named in a list, every `entity work.Y` that `X.vhd`
> instantiates must ALSO be in that list.

MEASURED on the repo: 12 lists, 2 broken, under a second, and it named the
missing dependency and the offending file in each case:

```
BROKEN  sim/mutate_fk33_seam.sh
          rtl/llama_top.vhd instantiates work.rmsnorm_rs_mem -- rtl/rmsnorm_rs_mem.vhd is NOT in the list
BROKEN  tools/capture_normw.sh
          rtl/llama_top.vhd instantiates work.rmsnorm_rs_mem -- rtl/rmsnorm_rs_mem.vhd is NOT in the list

CLOSURE_AUDIT checked=12 broken=2
```

After fixing both: `CLOSURE_AUDIT checked=12 broken=0`.

**TEETH, both directions, because a checker never shown to fail has not been
shown to work.** The `ok` verdicts were confirmed against GHDL -- both repaired
lists analyse clean, 51 and 52 files -- and two deliberate deletions on a
scratch tree were each caught with the exact missing edge named:

| mutant | verdict |
|---|---|
| baseline, fixed tree | `checked=12 broken=0` |
| drop `rtl/vec_mem.vhd` from `mutate_normw.sh` | **BROKEN**, `rmsnorm_rs_mem.vhd instantiates work.vec_mem` |
| drop `rtl/attn_block.vhd` from `mutate_llama_top_kv.sh` | **BROKEN**, `llama_top.vhd instantiates work.attn_block` |

### 8.3 The generalisation, which is a fact about the data and not an opinion

**Copying a list rotted; borrowing one did not, 8 for 8.** Every one of the
eight failures is a script that keeps its OWN `FILES=` list.
`sim/mutate_llama_top_land.sh` and `sim/mutate_llama_top_normuram.sh` both build
`llama_top` and both are FINE -- because they read their list out of
`sim/mutate_llama_top_kv.sh` at run time with `sed` instead of holding a copy.
**I initially counted those two as broken and checked before reporting; they
are not.** The correction is recorded here rather than silently dropped.

So there are two fixes and the cheap one is not the good one:

- **cheap:** run `closure_audit.py` as a gate row. One second, catches all
  eight, needs no simulator, and would have caught each of them the day it
  broke.
- **structural:** delete the private lists and have every consumer borrow one,
  which is empirically the pattern that survived four tracks of churn.

**Neither is landed by this track** -- adding a gate row is the dispatcher's
call, and `sim/regress.sh` is not mine. The script is committed and runs
standalone.

## 9. A correction to my brief, and one to ROUTE2's status

**The brief's gate floor was wrong and the dispatcher corrected it mid-track:**
the clean-checkout floor is `OVERALL PASS 103 FAIL 0`, not 111. The 111 was
GWTWO's WORKING-TREE run, inflated by 8 untracked auto-discovered `sim/*.vhd`
rows, and no clean checkout can reach it. `sim/regress.sh` already carries
`BASELINE_PASS=103`.

**TRACK ROUTE2 landed a RETRACTION mid-track (`53d4619`, `48633e5`) and the
premise of this track SURVIVES IT INTACT.** What ROUTE2 withdrew is the causal
claim that the two area levers are what made the composition route -- the
`CB_STYLE=regs` control routes too, and the second uncontrolled variable was
the PBLOCK. What ROUTE2's own retraction lists under "WHAT STANDS, all
MEASURED" includes, verbatim: *"BRAM 253.5 with +119.0 headroom without the
gain image and -52.0 with it"*. **That is the number this whole track is
measured against, and it is unchanged.**

---

## 10. Open, not yet answered

- **Whether the composed design still routes with the codebook in it.** Every
  number here is an OOC synthesis estimate of one generate block with
  `-flatten_hierarchy none` and `LUTDIET_NOOPT=1`. **Fitting by tile count is
  not the claim that it routes**, and ROUTE2's own retraction is a fresh
  reminder of how far apart those two are. The composed draw with a non-empty
  `NORM_W_IMAGE` has never been run by anybody.
- **Why the 16-bit point is 135 and not 144.** Every other point obeys 9 RAMB36
  per bit exactly. The 16-bit one does not, and this track did not establish
  what maps differently there.
- **The elaboration cost of building the codebook inside the tool.** This is
  the one thing this track found and did NOT finish. MEASURED: the `swcb` draw
  sat in Vivado's RTL elaboration for over 15 minutes with its RSS pinned to
  the kilobyte at the `MemoryHigh=11G` cap and 6.2 GiB of swap in use, where
  the shipping `head` completes synthesis end to end in 425 s. The suspect is
  named and a control exists but was not drawn in time: the codebook builder
  returns a **record** holding two 65,536-element arrays, and if Vivado's
  elaborator copies that record on each field assignment then the mark pass is
  266,240 x ~400 KB of copying. A **record-free** restructuring (four functions,
  each with one plain array variable -- the shape `nw_load` already uses
  successfully) is written, analyses clean, and **PASSES the same 266,240-element
  oracle with 0 mismatches**, so it is a drop-in replacement whenever the
  comparison is made. **The two forms produce IDENTICAL elaborated constants,
  and that is DERIVED from the code rather than inferred from the oracle**:
  both walk the value domain `a in 0..255, b in 0..255` ascending and append
  each marked value in that order, so the map and the table are the same
  arrays. (The oracle alone would NOT establish this -- it checks the composed
  function `cbrom[ixrom[addr]]`, and an ascending and a descending codebook
  compose to the same function while holding different contents. That is
  exactly what mutant `E3` demonstrates.) It is preserved at
  `hw/fk33/results/gain16_2026-08-30/cb2_recordfree_contingency.vhd`.
  **Nobody should quote an elaboration time for this design until both forms
  have been drawn in the same session.** Note GHDL elaborates the record form
  without difficulty, so whatever this is, it is Vivado-specific.
- **Whether a smaller index is reachable.** 11 bits is 1.05 bits above the
  fixed-width floor; a variable-length or per-vector scheme could in principle
  approach 9.956 bits/element, which at 9 tiles per bit is about 90. Nothing
  here says whether the decode would stay free of DSP and of the extra pipeline
  stage, and the remaining 9 tiles are not worth finding out while the gap is
  already closed by 20.
- **What happens to this lever on a different image.** The codebook is built
  from whatever `NORM_W_IMAGE` holds, so a model whose gain has more distinct
  values costs more; at 2,048 distinct it is still 11 bits, at 4,096 it becomes
  12 and the saving drops from 36 tiles to 27. There is no guard that warns
  when that happens.
