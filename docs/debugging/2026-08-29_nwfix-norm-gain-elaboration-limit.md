# The committed `NORM_W_IMAGE` loader does not synthesise at the real 9B shape. Is the fix the tool parameter or the loader, and should the gain be a ROM at all?

**Date:** 2026-08-29
**Track:** NWFIX
**Baseline, pinned as its own step before `git archive`:** see
`hw/fk33/results/nwfix_2026-08-29/PINNED_SHA.txt`. `rtl/llama_top.vhd` in that
archive is `md5 d55fa9024c14960449c8627234f76f67`, which is the SAME md5 TRACK
NWROM recorded for its own pinned tree, so the before-side of every number
below is bit-for-bit the design NWROM measured. `rtl/rmsnorm_rs.vhd` is
`md5 e8226805f8222720e9f200b35506ef64` and `git diff 3853650 <pin> --
rtl/rmsnorm_rs.vhd rtl/llama_top.vhd` is EMPTY, so TRACK DISTRAM had not yet
moved the one file that would move these numbers under me.
**Tools:** Vivado 2023.2 for every area number, through TRACK LUTDIET's
`sim/ooc_lutdiet_run.sh` and `sim/ooc_lutdiet_ports.tcl` **unmodified**,
`xcvu33p-fsvh2104-2L-e`, 5.0 ns, `-mode out_of_context -flatten_hierarchy none`,
`LUTDIET_NOOPT=1`, `LUTDIET_CENSUS=1`. GHDL 1.0.0 (mcode) for the values oracle
and for the gate row. Python 3 + `gguf` to rebuild the gain image.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `program_hw_devices`,
nothing under `hw/fk33/host` or `hw/fk33/tcl`, nothing opening `/dev/xdma*`.
**Machine at start:** root 91% (120 G free), `/mnt/storage` 388 G free, 31 G RAM
with 5 G of swap in use, load average 6.25, **zero** other Vivado processes.
**Artefacts:** `hw/fk33/results/nwfix_2026-08-29/`

---

## 1. The question, verbatim

> **At the real 9B shape the committed `NORM_W_IMAGE` loader does not synthesise
> at all. It fails elaboration.**
>
> ```
> ERROR: [Synth 8-403] loop limit (65536) exceeded [...:187]
> ERROR: [Synth 8-421] mismatched array sizes in rhs and lhs of assignment [...:199]
> ```
>
> 1. **Make the real shape synthesise.** ... **Decide deliberately whether
>    [`maxLoopLimit 4000000`] is the fix or a crutch.**
> 2. **Make it DETECTABLE.** Whatever the fix, add something that would have
>    caught this.
> 3. **Evaluate moving the gain to HBM** ... **Make that MEASURED or report why
>    it cannot be.**

---

## 2. The answer, up front

**Four answers. The third was not asked for and is the one that changes the
schedule picture.**

1. **The tool parameter is a crutch; the fix belongs in the loop.** Vivado's
   elaboration limit is PER LOOP STATEMENT, so `nw_count` can be made compliant
   instead of the tool made permissive. `rtl/llama_top.vhd` now counts in
   groups of `NN`. No flow, script, format or producer changes.
2. **It is now detectable, by the tool that can see it.**
   `sim/ooc_nwfix_elabcheck.sh` runs a free geometry guard and then a
   `synth_design -rtl` at the real shape with the DEFAULT limit;
   MEASURED verdict `NWFIX_ELABCHECK PASS`. Both guards were teeth-checked.
3. **THE AREA NUMBER THE BOARD IS CARRYING DOES NOT REPRODUCE.** Five draws of
   the populated ROM span **82,597 to 128,065 LUT**, two of them from the same
   command. 306,787 is the best draw, not the value.
4. **The HBM route is MEASURED at 67,059 LUT / 0 BRAM, it repeats
   BIT-IDENTICALLY, and it is the only one of the two whose area can be quoted
   at all.** Composition 291,249.

---

**(a) The tool parameter is a crutch, and the reason is a fact NWROM had in its
own output and did not draw out: Vivado's elaboration loop limit is PER LOOP
STATEMENT, not cumulative over nesting.**

MEASURED, and it is in NWROM's own artefacts: its `nw_bnd65` point synthesised
the full 65-op table with **no `maxLoopLimit` override at all**
(`grep -l NWROM_LOOPLIMIT_RAISED` matches only the three `lf*` logs). That
point's `nw_load` runs the identical 65 x 4096 = 266,240 body executions as two
NESTED loops of 65 and 4096, and it elaborated. So the 266,240-iteration
`while not endfile(fh) loop` in `nw_count` was never a limit on the WORK; it was
a limit on one loop's trip count, and the cure is to give `nw_count` the same
nested shape `nw_load` already had.

**NWROM's own bracket cannot distinguish the two hypotheses** -- `NW_N = 9`
elaborates and `NW_N = 17` does not is equally consistent with "per loop" and
"cumulative over nesting", because both loops in both functions scale together.
That is why the fact had to be recovered from the run provenance rather than
from the sweep.

**(b) The fix taken is in `rtl/llama_top.vhd` and in no flow, no script and no
tool setting.** `nw_count` now counts in groups of `NN` through an outer loop
over norm ops and an inner loop over elements, so no single loop statement
exceeds `max(NW_N, NN)` -- 65 and 4096 at the 9B shape, against a limit of
65,536. The image format is unchanged, the producer is unchanged, and the
refusals are unchanged in force and better in wording.

**(c) MEASURED: with that edit and the tool at its DEFAULT loop limit, the real
9B image elaborates and synthesises. Read (c2) before quoting the LUT column --
it is not reproducible and this table shows two draws of the same point.**

| tag | RTL | image | loop limit | CLB LUT | adapter's own | `gvr.u_rms` | CLB FF | DSP | BRAM | CARRY8 | WNS | Fmax | synth s |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `nf_empty` | fixed | none | default | **49,654** | 25,523 | 24,131 | 133,197 | 41 | 0 | 268 | +1.675 | 300.752 | 164 |
| `nf_pre65` | **pinned** | real 9B | default | **ELABORATION FAILURE** | | | | | | | | | 15 |
| `nf_fix65` | fixed | real 9B | **default** | **87,254** | 47,487 | 39,767 | 166,937 | 41 | 0 | 268 | +1.675 | 300.752 | 396 |
| `nf_pre65lf` | pinned | real 9B | raised | **103,302** | 61,980 | 41,322 | 175,810 | 41 | 0 | 268 | +1.675 | 300.752 | 450 |
| `nf_fix65lf` | fixed | real 9B | raised | **103,435** | 62,401 | 41,034 | 176,502 | 41 | 0 | 268 | +1.675 | 300.752 | 431 |
| `nf_fix65b` | fixed | real 9B | default | **128,065** | -- | -- | 194,242 | 41 | 0 | 268 | +1.675 | 300.752 | 497 |
| `nf_hbm` | **HBM probe** | none | default | **67,059** | 25,561 | 41,498 | 198,698 | 41 | **0** | 268 | +1.675 | 300.752 | 197 |
| `nf_hbmb` | HBM probe (repeat) | none | default | **67,059** | 25,561 | 41,498 | 198,698 | 41 | **0** | 268 | +1.675 | 300.752 | 203 |

`nf_fix65` and `nf_fix65b` are the SAME COMMAND run twice. Everything except the
LUT and FF columns is stable across every row: DSP 41, BRAM 0, CARRY8 268, WNS
`+1.675` and Fmax `300.7518796992481` are bit-identical in all of them.

`nf_empty` reproduces NWROM's `nw_empty` on ALL ELEVEN COLUMNS
(49,654 / 25,523 / 24,131 / 133,197 / 41 / 0 / 0 / 268 / 18,208 / 8,944 /
+1.675), so the two tracks' numbers are on the same scale without adjustment.
`nf_pre65` reproduces the defect at the same three line numbers (187, 199, 63)
on an independently pinned tree and an independently rebuilt image, so the base
of this fix sweep is a base whose verdict was printed before anything was
scored.

**(c2) AND A CORRECTION THAT MATTERS MORE THAN THE FIX: NO SINGLE LUT NUMBER
FOR THIS BLOCK MEANS ANYTHING. RUNNING THE IDENTICAL COMMAND TWICE MOVES IT BY
46.8%.**

This was found by re-running NWROM's `nw_lf65` -- the pinned committed loader
(`md5 d55fa90...`, NWROM's own recorded md5), the real 9B image (stats
byte-identical to NWROM's artefact), through `sim/ooc_nwrom_loopfix_run.sh`
UNMODIFIED, same part, period and flags. It measured **103,302, not 82,597**.
The cheapest thing that could refute "then my environment differs from NWROM's"
was to run MY OWN point twice, so `nf_fix65b` is a byte-for-byte repeat of
`nf_fix65`: same directory, same image, same invocation, same hour, same box.

    nf_fix65    87254 LUT   ff 166937   synth 396 s
    nf_fix65b  128065 LUT   ff 194242   synth 497 s

**+40,811 LUT (+46.8%) from re-running the same command.** Every measurement of
the populated 65-op table, from both tracks, in one place:

| build | source | loader | loop limit | CLB LUT | `gvr.wsel` LUT | `gvr.wsel` FF |
|---|---|---|---|---:|---:|---:|
| `nw_lf65` | NWROM | committed | raised | **82,597** | 18,954 | 28,958 |
| `nf_fix65` | NWFIX | fixed | default | 87,254 | 22,677 | 33,673 |
| `nw_bnd65` | NWROM | bounded probe | default | 103,081 | 37,611 | 45,871 |
| `nf_pre65lf` | NWFIX | committed | raised | 103,302 | 37,552 | 42,555 |
| `nf_fix65lf` | NWFIX | fixed | raised | 103,435 | -- | -- |
| `nf_fix65b` | NWFIX | fixed | default | **128,065** | 62,461 | 60,967 |

**Range 82,597 to 128,065 over SIX draws, a factor of 1.55.** And the loop-limit
override is NOT the explanatory variable: the raised-limit draws are
82,597 / 103,302 / 103,435 and the default-limit draws are
87,254 / 103,081 / 128,065, which interleave. `nf_pre65lf` (pinned loader) and
`nf_fix65lf` (fixed loader), both under the override, differ by **133 LUT** --
so the NWFIX edit itself is worth nothing measurable either, which is the
correct answer for an elaboration-time function that contributes no hardware. And the scatter is LOCALISED:
every other census row is stable across all five builds -- `gvr.uw_data` is
19,872 in four of them, `sq` is 17,475 in all five, `ARG` is 15,567 to 17,916 --
while **`gvr.wsel` alone spans 18,954 to 62,461, a factor of 3.3.** That is the
65:1 select over a 65,536-bit constant, and NWROM's section 5.4 already named
the mechanism: Vivado folds each output bit into logic of the seven `nidx` bits
and then merges equivalent flops. **How much it merges is not reproducible.**

NWROM's section 5.7 had the shape of this right -- "the same design synthesised
twice down a slightly different elaboration path ... treat any single LUT number
for this block as carrying a spread of that order" -- and then quoted 82,597 as
the answer anyway. The board's 306,787 composition inherited it. **82,597 is the
lowest of five draws, not a value.**

Consequences, stated plainly:

- The `NORM_W_IMAGE` premium over the empty control is **+32,943 to +78,411 LUT**
  depending on the draw, not +32,943.
- **NWROM's rejection of its own bounded probe is withdrawn.** It rejected
  `nw_bnd65` = 103,081 as "20,484 LUT MORE than the committed RTL" and told
  readers to quote `nw_lf65`. The committed RTL under the override measures
  103,302 here, within 221 LUT of the probe it rejected. The probe was never the
  outlier.
- **The one thing this does NOT change is the elaboration defect or its fix.**
  `nf_pre65` fails and `nf_fix65`/`nf_fix65b` both succeed; that is a binary
  outcome and it does not scatter.

**(c3) MEASURED, and it is the answer to part 3 of the brief: moving the gain to
HBM costs 67,059 CLB LUT and 0 BRAM, which is BELOW every populated-ROM
measurement and below NWROM's own ~72,000 ESTIMATE -- AND, unlike the ROM, it
is REPRODUCIBLE.**

`nf_hbm` and `nf_hbmb` are the same point run twice and are **bit-identical on
all eleven columns**: 67,059 LUT / 198,698 FF / 41 DSP / 0 BRAM / 0 URAM /
268 CARRY8 / 26,640 F7 / 13,264 F8 / WNS +1.675 / Fmax 300.7518796992481. The
censuses `diff` clean over their first twelve lines. Only wall time moved
(197 s against 203 s). Set that against the ROM's five draws spanning 82,597 to
128,065: **the scatter is a property of the 65:1 select over a 65,536-bit
constant, not of this measurement setup**, and removing that structure removes
the scatter along with the area.

That is the strongest argument for the HBM route and it is not the one NWROM
made. The route is not merely smaller; it is the only one of the two whose area
can be quoted at all.

`sim/ooc_nwfix_hbmprobe.py` deletes `nw_count`, `nw_load`, `NW_N`, `NW_TBL`,
`nidx` and `novf` and streams the gain into `wsel` as in-order 256-bit beats
(the FK33 HBM pseudo-channel width), refusing if any of those six names survives
in its output. The census reads the result cleanly:

| root | `nf_empty` | `nf_hbm` | `nf_fix65` | what it is |
|---|---:|---:|---:|---|
| adapter's own (hier) | 25,523 | **25,561** | 47,487 | the adapter |
| `gvr.wsel` | absent | **absent from the census** | 22,677 | the table and its select |
| `ARG` (inside `rmsnorm_rs`) | 480 | **17,916** | 16,386 | `w_mant`'s own read mux |
| `gvr.u_rms` (hier) | 24,131 | 41,498 | 39,767 | `rmsnorm_rs` |

Two things fall out, and both are checks rather than claims:

- **The adapter with a STREAMED gain costs what the adapter with a CONSTANT gain
  costs**: 25,561 against 25,523, a difference of 38 LUT. The entire table cost
  is removed, and the shift-register write contributes no LUT row at all -- it
  is 65,536 flops and an enable.
- **`ARG` is 17,916, to the LUT the standalone figure TRACK LUTDIET measured for
  `rmsnorm_rs` at N = 4096 and the figure NWROM reproduced in `nw_lfura65`.**
  Three independent builds agree, which is what makes NWROM's claim -- that this
  17,916 is the price of a real gain AT ALL and is independent of where the
  table lives -- a MEASUREMENT rather than an argument. It is now measured with
  no table anywhere in the design.

DERIVED from those rows: of `nf_hbm`'s 17,405 LUT over `nf_empty`, **17,367 is
`rmsnorm_rs` losing its constant fold** and 38 is the adapter. None of it is the
gain's storage.

**(c4) The composition, and the honest way to book it.** B, C and `D_seq` are
TRACK WRITEDEC's and COMPOSE's numbers used verbatim; this track adds no
independent evidence for them, and their sum (224,190) reproduces NWROM's totals
exactly, which is the check that the arithmetic is on the same basis.

| `D_norm` booking | value | total | vs 268,222 free (device) | vs 233,765 free (`pb_core`) |
|---|---:|---:|---|---|
| `NORM_W_IMAGE` **empty** -- no real build can use it | 49,654 | 273,844 | OVER by 5,622 (1.02x) | OVER by 40,079 (1.17x) |
| **HBM route, MEASURED and REPRODUCIBLE** | **67,059** | **291,249** | **OVER by 23,027 (1.086x)** | **OVER by 57,484 (1.246x)** |
| ROM, best of five draws (NWROM's `nw_lf65`) | 82,597 | 306,787 | OVER by 38,565 (1.144x) | OVER by 73,022 (1.312x) |
| ROM, **median of five draws** | 103,302 | 327,492 | OVER by 59,270 (1.221x) | OVER by 93,727 (1.401x) |
| ROM, worst of five draws | 128,065 | 352,255 | OVER by 84,033 (1.313x) | OVER by 118,490 (1.507x) |

**The board's 306,787 is the BEST of five draws of a quantity whose draws span
45,468 LUT.** If one number has to be carried for the ROM route it should be the
median, 327,492, and it should be carried with the range attached. **The HBM
route's 291,249 is the only row here whose `D_norm` is reproducible**, and it is
36,243 LUT better than the ROM median and 15,538 better than even the ROM's best
draw.

DERIVED, and worth stating because it changes what the remaining levers have to
find: at 291,249 the design is 23,027 LUT over the device and 57,484 over
`pb_core`. TRACK DISTRAM's B lever and the READCONV read conversion are being
asked for a smaller number than the board thought.

**(d) The values loaded are the file's values, and that is now checked by an
oracle rather than asserted.** NWROM's section 8 says "Nothing here checks that
the table Vivado loaded holds the values the file holds." The GHDL half of that
is now closed: `hw/fk33/results/nwfix_2026-08-29/nwfix_oracle.vhd` elaborates
`nw_load` VERBATIM at the real 4096-wide, 65-op shape and emits a plain sum, a
position-weighted sum, and the first and last element of every norm op;
`nwfix_oracle.py` computes the same from the same file with a reader that
shares no code with the writer. **67 rows each, identical.** Six mutations,
base verdict printed first, all six caught -- and one that was NOT caught until
the oracle was strengthened is reported under its own name in section 6.

**The Vivado half is NOT closed and is stated as an open item in section 8.**

---

## 3. What is a crutch and what is a fix: the trade, stated

| | `set_param synth.elaboration.rodinMoreOptions {rt::set_parameter maxLoopLimit 4000000}` | restructure `nw_count` |
|---|---|---|
| touches shipping RTL | no | **yes**, and it needs re-verification |
| touches the image format | no | no |
| touches the producer | no | no |
| where it must be remembered | **every present and future synthesis flow that reads `llama_top`** -- `sim/ooc_compose_bcd.tcl`, the FK33 build, `hw/package_*.tcl`, any new one | nowhere |
| cost of forgetting it | a twenty-minute synthesis that fails pointing at a `while` loop, not at the omission | not applicable |
| what it is | an undocumented internal parameter reached through a string handed to `rodinMoreOptions`; nothing guarantees a Vivado bump keeps it | ordinary VHDL |
| does it remove the cause | **no** -- the loader still has a loop whose trip count is `hidden x norm_ops` | **yes** -- both loops are bounded by one dimension each |
| behaviour at a bigger model | 27B (hidden 5120, 129 ops) needs 660,480; the number must be raised again or re-justified | 5120 and 129, both three orders under the limit; nothing changes |
| elaboration cost | one pass over the image | **two** passes (count then load) |

The one real cost of the restructure is that column's last row: `nw_count` and
`nw_load` each walk the file, so the fixed loader does 532,480 `readline` calls
where the old one did 532,480 as well (the old `nw_count` also read every line;
it simply did so in one loop). **So the double pass is not new** -- it was
already there, and the edit changes its shape and not its work.

**A third option, considered and not taken: a denser image format.** One packed
word per norm op makes the file 65 lines and removes the inner loop entirely.
It was rejected because it changes `tools/gen_llama_top_weights.py --norm-out`
and `sim/ooc_nwrom_gen_image.py`, which are the producers, and because the RTL's
stated reason for one value per line is sound and nothing else currently guards
it: "a packed word has to be written MSB-first, i.e. element NN-1 first, which
is the ordering easiest to get silently backwards, and a reversed gain vector is
a wrong number with no structural symptom." Mutation **T3** in section 5.3 is
exactly that failure, and it is caught only by the `first`/`last` fields of the
new oracle -- the plain checksum is blind to it. Changing to the hazardous
format at the same moment the only check on it is a day old was not a trade
worth taking for an elaboration-time speedup.

**The producer, named as the brief asks.** The gain image is written by
`tools/gen_llama_top_weights.py` (`--norm-out`), whose `build_plan`,
`reduce_gain` and `quantize_gain` define the schedule order, the tensor names
and the quantiser; `sim/ooc_nwrom_gen_image.py` is the full-width variant that
IMPORTS those three rather than restating them, because `--norm-out` reduces to
`hidden = 64` for the bench. **Neither changed in this track.**

---

## 4. The procedure, and what each step isolates

1. **Recover the provenance of NWROM's `nw_bnd65` point before designing
   anything.** `grep -l NWROM_LOOPLIMIT_RAISED /mnt/storage/nwrom/out/*.log`
   returns only `lf65`, `lfblk65` and `lfura65`, and `run_nw_bnd65.log`'s first
   line shows it sourcing `ooc_lutdiet_ports.tcl` directly. *What this isolates:*
   whether the limit is per-loop or cumulative. Everything else in the fix
   depends on that answer, and no measurement in NWROM's sweep distinguishes it.
2. **Rebuild the gain image from the gguf and check it against NWROM's
   artefact.** `sim/ooc_nwrom_gen_image.py` unchanged; the resulting
   `norm_w_9b_stats.csv` is **byte-identical** to
   `hw/fk33/results/nwrom_2026-08-29/norm_w_9b_stats.csv`. *What this isolates:*
   that the two tracks' area numbers are on the same file. The image itself was
   deleted when NWROM cleaned its scratch tree, so this had to be re-established
   and not assumed.
3. **Pin the tree with `git archive` and take the before-side from the pin, not
   from the working tree.** `SHA=$(git rev-parse HEAD)` as its own step; HEAD
   moved from `fc7dea9` to `0d14a70` while this track was running. The pinned
   `llama_top.vhd` md5 matches NWROM's recorded md5.
4. **Generate BOTH synthesis tops with `sim/ooc_normadapt_extract.py`, one from
   the pinned file and one from the edited working tree, and diff them.** The
   diff is `nw_count` and its comments and nothing else. *What this isolates:*
   the before/after attribution is only valid if the two harnesses differ by
   exactly the edit under test.
5. **GHDL-analyse every generated top before spending a Vivado run on it.**
6. **Run the BASE FIRST and print its verdict.** `nf_pre65` is the pinned loader
   with the real image at the tool's default limit, and it reproduces the exact
   failure at the exact lines. *What this isolates:* a fix sweep whose base
   silently works scores everything as a success.
7. **Reproduce the empty-image control in the same session with the same
   script**, and require it to match NWROM on all eleven columns before reading
   anything else.
8. **Build the values oracle against an independent reader, and teeth-check it
   with six mutations, base verdict first.**
9. **One Vivado at a time**, on NWROM's wait rule, from a SNAPSHOT of the runner
   in the scratch tree that is never edited while it is running.

---

## 5. The evidence, as raw output

### 5.1 The provenance that decides the whole design

    $ grep -l "NWROM_LOOPLIMIT_RAISED" /mnt/storage/nwrom/out/*.log
    /mnt/storage/nwrom/out/run_nw_lfblk65.log
    /mnt/storage/nwrom/out/vivado_nw_lfblk65.log
    /mnt/storage/nwrom/out/vivado_nw_lfura65.log
    /mnt/storage/nwrom/out/run_nw_lf65.log
    /mnt/storage/nwrom/out/vivado_nw_lf65.log
    /mnt/storage/nwrom/out/run_nw_lfura65.log

    $ head -16 /mnt/storage/nwrom/out/run_nw_bnd65.log | tail -3
    source /home/orencollaco/GitHub/llama.vhdl/sim/ooc_lutdiet_ports.tcl -notrace
    LUTDIET_BEGIN target=ooc_nwrom_bnd part=xcvu33p-fsvh2104-2L-e period=5.0 ...
    Command: synth_design -mode out_of_context -top ooc_nwrom_bnd ...

`nw_bnd65` is not in the first list. It ran at the DEFAULT loop limit, with
`nw_load`'s 65 x 4096 nested loops, and it produced a result CSV.

### 5.2 The image, re-established

    $ wc -l /mnt/storage/nwfix/img/norm_w_9b.hex
    266240
    $ cmp norm_w_9b_stats.csv hw/fk33/results/nwrom_2026-08-29/norm_w_9b_stats.csv
    (no output -- byte identical)
    $ md5sum /mnt/storage/nwfix/img/norm_w_9b.hex
    69f614a1515e1160f5dc9e8a9e72fdc3

### 5.3 The values oracle and its teeth

    BASE PASS  VHDL NW_TBL == independent python reader, 67 rows each
    t1 CAUGHT  (1 row(s) differ)
    t2 CAUGHT  (2 row(s) differ)
    t3 CAUGHT  (1 row(s) differ)
    t6 CAUGHT  (1 row(s) differ)
    t4 REFUSED by the shipping nw_count (rc=1)
    t5 REFUSED by the shipping nw_count (rc=1)

| id | mutation | what it would mean in the field |
|---|---|---|
| t1 | one hex value replaced by `0000` | a corrupted or truncated write |
| t2 | norm ops 0 and 1 swapped | `build_plan`'s schedule order wrong |
| t3 | element order reversed inside op 0 | the MSB-first packing hazard the format comment names |
| t4 | one line removed | an image built for a different `BLOCKS` |
| t5 | one line added | the same, in the other direction |
| t6 | elements 100 and 200 of op 0 swapped | an interior permutation |

The refusals, verbatim, from the SHIPPING function (the old function is skipped
so the new one is the thing being tested):

    (assertion failure): oracle(new): m_t4.hex holds 64 complete norm ops of
    4096 elements plus 4095 leftover lines.
    (assertion failure): oracle(new): m_t5.hex holds 65 complete norm ops of
    4096 elements plus 1 leftover lines.

### 5.4 The base that must fail, and does

    == nf_pre65 start 2026-08-29T22:58:01-06:00 rtl=rtl_base image=.../norm_w_9b.hex
    ERROR: [Synth 8-403] loop limit (65536) exceeded [.../ooc_normadapt_top.vhd:187]
    ERROR: [Synth 8-421] mismatched array sizes in rhs and lhs of assignment [...:199]
    ERROR: [Synth 8-285] failed synthesizing module 'ooc_normadapt' [...:63]
    ERROR: [Common 17-69] Command failed: Vivado Synthesis failed
    SENTINEL MISSING for nf_pre65 -- the run did NOT reach the end of the script.
    == nf_pre65 rc=9

Same message, same three line numbers (187, 199, 63) as NWROM reported, on a
tree pinned independently and an image rebuilt independently.

### 5.5 The HBM probe's result CSV and hierarchy, verbatim

    target,gen,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,carry8,f7,f8,wns_ns,fmax_mhz,synth_s,opt_s,...
    ooc_nwfix_hbm,"",41,67059,67059,0,198698,0,0,0,0,268,26640,13264,1.675,300.7518796992481,197,-1,...

    | ooc_nwfix_hbm     |      (top) |      67059 | ... | 198698 | ... | 41 |
    |   (ooc_nwfix_hbm) |      (top) |      25561 | ... | 131524 | ... |  1 |
    |   gvr.u_rms       | rmsnorm_rs |      41498 | ... |  67174 | ... | 40 |

    nf_hbm census, top rows
    gvr.uw_data                            19728    9232    4560       16       0
    ARG                                    17916    8704    4352        0      11
    sq                                     17475    8704    4352        0       0
    gvr.xw                                  5985       0       0    65536       0
    gow.o                                   2879       0       0        0       0

There is no `gvr.wsel` row: the shift register is 65,536 flops and an enable,
and contributes no LUT group at all.

### 5.6 The shipped elaboration guard, run end to end

    $ bash sim/ooc_nwfix_elabcheck.sh /mnt/storage/nwfix/img/norm_w_9b.hex \
           4096 /mnt/storage/nwfix/rtl_fix ooc_normadapt /mnt/storage/nwfix/elabchk
    NWFIX_GEOM image=/mnt/storage/nwfix/img/norm_w_9b.hex lines=266240 nn=4096 ops=65 limit=65536
    NWFIX_GEOM_NOTE 266240 lines is over the 65536 limit, so a loader
    NWFIX_GEOM_NOTE that reads ONE LINE PER ITERATION of a single loop
    NWFIX_GEOM_NOTE cannot elaborate this image.  llama_top's does not;
    NWFIX_GEOM_NOTE it counts in groups of NN.  If [Synth 8-403] appears
    NWFIX_GEOM_NOTE below, that structure has been reintroduced.
    NWFIX_GEOM_PASS both loop bounds are under 65536

    (from the Vivado half, elabcheck_vivado.log)
    NWFIX_ELAB_BEGIN top=ooc_normadapt part=xcvu33p-fsvh2104-2L-e rtl=.../rtl_fix
                     gen=NORM_W_IMAGE=.../norm_w_9b.hex
    NWFIX_ELAB_PASS ooc_normadapt

**No `maxLoopLimit` anywhere in that run.** `synth_design -rtl` stops after
elaboration, so it costs about three minutes rather than the seven a full
synthesis costs, and elaboration is precisely the phase that was failing.

Its geometry half was teeth-checked separately, base first, and both refusal
branches were reached under their own names:

    $ ooc_nwfix_elabcheck.sh norm_w_9b.hex 4096 --geometry-only
    NWFIX_GEOM image=norm_w_9b.hex lines=266240 nn=4096 ops=65 limit=65536
    NWFIX_GEOM_NOTE 266240 lines is over the 65536 limit, so a loader
    NWFIX_GEOM_NOTE that reads ONE LINE PER ITERATION of a single loop
    NWFIX_GEOM_NOTE cannot elaborate this image. [...]
    NWFIX_GEOM_PASS both loop bounds are under 65536         rc=0

    $ ... m_t4.hex 4096 --geometry-only        (one line short)
    NWFIX_GEOM_FAIL 'm_t4.hex' has 266239 lines, which is not a whole number
    NWFIX_GEOM_FAIL of 4096-element norm ops.  llama_top refuses this.   rc=2

    $ ... norm_w_9b.hex 133120 --geometry-only  (inner-loop branch)
    NWFIX_GEOM_FAIL the inner loop would run 133120 times, at or over 65536.
    NWFIX_GEOM_FAIL geometry alone rules this image out.                 rc=2

    $ ... norm_w_9b.hex 1 --geometry-only       (outer-loop branch)
    NWFIX_GEOM_FAIL the outer loop would run 266240 times, at or over 65536.
    NWFIX_GEOM_FAIL geometry alone rules this image out.                 rc=2

### 5.7 The unfiltered table of every point attempted, failures included

    tag          top                   lut       own     u_rms       ff    dsp   bram   uram  carry8      f7       f8        wns    fmax  synth_s
    nf_empty     ooc_normadapt       49654     25523     24131   133197     41      0      0     268   18208     8944      1.675   300.7519      164
    nf_fix65     ooc_normadapt       87254     47487     39767   166937     41      0      0     268   24268    11504      1.675   300.7519      396
    nf_fix65b    ooc_normadapt      128065     86525     41540   194242     41      0      0     268   26763    13167      1.675   300.7519      497
    nf_fix65lf   ooc_normadapt      103435     62401     41034   176502     41      0      0     268   25437    12552      1.675   300.7519      431
    nf_hbm       ooc_nwfix_hbm       67059     25561     41498   198698     41      0      0     268   26640    13264      1.675   300.7519      197
    nf_pre65     ERROR: [Synth 8-403] loop limit (65536) exceeded [...ooc_normadapt_top.vhd:187]
    nf_pre65lf   ooc_normadapt      103302     61980     41322   175810     41      0      0     268   24505    12038      1.675   300.7519      450
    nf_hbmb      ooc_nwfix_hbm       67059     25561     41498   198698     41      0      0     268   26640    13264      1.675   300.7519      203

Note the `own` column, which is the adapter without `rmsnorm_rs`: 25,523 with
the gain folded to a constant, **25,561 with it streamed**, and 47,487 / 62,401
/ 86,525 with the 65-entry table -- three draws of the same design.

### 5.8 The gate row, unfiltered last `OVERALL`

`sim/tb_llama_top_normw` is the row that pins this feature, run against the
EDITED `rtl/llama_top.vhd` on an otherwise quiet box:

    PASS       sim:tb_llama_top_normw                76s  ... tb_llama_top RESULT: PASS -- 64 descriptors, 4 bl
     suite sim   PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
     suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
     OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
     REGRESSION: PASS

**That is ONE row and it is stated as one row.** `--only` takes a substring, so
`PASS 1` is the number to read, not the word PASS. A broader
`--only tb_llama_top` run covering `_seq` and `_real` as well was started and
**this track STOPPED it** to relieve the memory pressure in 7.7; it produced no
verdict and is NOT a result. See section 8.

---

## 6. Measured and REJECTED -- do not retry

- **`set_param synth.elaboration.rodinMoreOptions {rt::set_parameter
  maxLoopLimit 4000000}` as the FIX.** It works -- NWROM measured that, and this
  track does not dispute it -- and it is rejected for the reasons tabulated in
  section 3, of which the decisive one is MEASURED rather than argued: the limit
  is per loop statement, so the loop can be made compliant instead of the tool
  made permissive. Keep the file `sim/ooc_nwrom_loopfix.tcl` as the record of
  what was measured; do not add the line to any flow.
- **A denser image format (one packed word per norm op).** Not measured, and
  deliberately so. See section 3 for the trade. It would work and it is the
  right move ONLY together with a check on element order, which mutation T3
  shows is a real and silent failure mode.
- **A VHDL-side guard on the image geometry.** MEASURED by NWROM over three OOC
  runs and not re-run here: Vivado silently ignores `assert ... severity
  failure` in synthesis, and an out-of-range `natural` constant fails with no
  message beyond `bound check failure at <file>:<line>`. A guard written in the
  file it is guarding cannot speak in the tool where the fault appears. The
  guard therefore lives in `sim/ooc_nwfix_elabcheck.sh`, outside the RTL.
- **A plain checksum as the values oracle.** MEASURED, mutation **T6**: swapping
  elements 100 and 200 of one norm op leaves the sum, the first element and the
  last element all unchanged, so the first version of the oracle scored it **NOT
  CAUGHT**. That is this track's own resolution floor and it is reported because
  it is the most useful line in the table. Fixed by adding a position-weighted
  sum, after which T6 is caught. **An oracle that has only ever been run on a
  correct file has not been shown to work.**
- **Quoting ANY single LUT number for the populated `NORM_W_IMAGE` ROM.**
  MEASURED over five draws, two of them the same command: 82,597 / 87,254 /
  103,081 / 103,302 / 128,065. Do not re-run this expecting to find "the"
  value; there is not one. If a number is needed, run at least three draws and
  quote the median with the range. **The HBM probe, by contrast, repeated
  BIT-IDENTICALLY on all eleven columns**, so the instability is a property of
  the 65:1 select and not of the harness.
- **Blaming the loop-limit override for the area difference.** MEASURED and
  refuted: raised-limit draws are 82,597 / 103,302 / 103,435, default-limit
  draws are 87,254 / 103,081 / 128,065, and they interleave. `nf_pre65lf`
  (pinned loader) and `nf_fix65lf` (fixed loader), both under the override,
  differ by **133 LUT** -- so the NWFIX edit costs nothing measurable either,
  which is the right answer for an elaboration-time function.
- **Putting the loader's `.vhd` oracle in `sim/`.** `sim/regress.sh` line 901
  globs `sim/*.vhd` into the SOURCE closure of every gate row -- not only
  `tb_*.vhd`, which is the row glob at line 975. A new non-testbench `.vhd`
  there is compiled into every row. The oracle therefore lives in
  `hw/fk33/results/nwfix_2026-08-29/`.

---

## 7. Measurement traps hit, including this track's own

### 7.1 NWROM's bracket does not prove what it was read as proving, and this track nearly inherited that

`NW_N = 9` elaborates and `NW_N = 17` does not was read as evidence about
`nw_count`'s single `while` loop. It is equally consistent with `nw_load`'s
NESTED loops hitting a cumulative limit, because both scale with `NW_N`
together. Had the cumulative reading been right, the fix taken here would have
failed at the first synthesis. **The refutation was already in NWROM's output**
-- one `grep -l` over its own logs -- and cost under a minute. This is the
brief's own instruction applied to the brief: when a measurement supports a
conclusion you already hold, find the cheapest thing that could refute it.

### 7.2 GHDL mcode cannot elaborate the real-shape table without two limits raised, and neither failure names the table

MEASURED, and it is why no bench has ever held a real-shape gain:

    ghdl-mcode:error: declaration of a too large object
                      (4160 > --max-stack-alloc=128 KB)
      from: work.nwfix_oracle(beh).nw_load

and then, with `--max-stack-alloc=0`:

    Segmentation fault (core dumped)

`nw_load`'s local `variable r : nw_t` is 65 x 65,536 bytes on the function
stack. Both are fixed by `ulimit -s unlimited` plus `--max-stack-alloc=0`.
`sim/elab9b_run.sh` already says "a deep stack is not optional" for its own
reasons; this is a second, independent instance of the same wall.

### 7.3 A guard whose message contains the words it is guarding against

`sim/ooc_nwfix_hbmprobe.py` ends by refusing if `NW_TBL`, `NW_N`, `nidx`,
`novf`, `nw_count` or `nw_load` still appear in its output. It refused on its
first run -- correctly, and on **its own comment text**, because the replacement
comment it inserts said "`nw_count` / `nw_load` / `NW_N` / `NW_TBL` deleted".
A whitelist-free string guard cannot tell a mention from a use. Fixed by
rewording the inserted comments. The guard is kept: a false positive it can be
talked out of is better than the silent `str.replace` no-op that cost NWROM two
measurement points (its section 7.4), and every substitution in this script is
checked for exactly one match, including the entity rename.

### 7.4 The one anchor that was wrong was the one copied from a doc string rather than from the file

`ooc_nwfix_hbmprobe.py`'s architecture anchor was written as
`architecture beh of ooc_normadapt is` from memory of the extractor's
convention. The generated file says `architecture rtl of ooc_normadapt is`.
The script refused with `anchor 'architecture decl' matched 0 times`, which is
the behaviour that was designed in, and the cost was one second rather than one
Vivado run.

### 7.5 The measurement that mattered most was one nobody asked for, and it cost one run

The brief asked for a fix, a detector and an HBM number. It did not ask whether
NWROM's headline reproduced, and neither did NWROM. Re-running `nw_lf65`
verbatim -- one synthesis -- returned 103,302 instead of 82,597, and re-running
this track's OWN point verbatim returned 128,065 instead of 87,254. **Both were
cheaper than any of the measurements that were asked for, and both changed the
conclusion more.** The rule the brief states -- "when a measurement supports a
conclusion you already hold, find the cheapest thing that could refute it" --
applies with equal force to a measurement INHERITED from another track, and
that is the case where nobody is looking.

### 7.6 Peak-RSS budgeting on this box has to account for a service nobody in this project owns

MEASURED at 23:10, mid-run: `ps -eo comm=,rss= --sort=-rss | head -1` was
**`llama-server 18848624`**, 17.98 GiB, the box's own llama.cpp service, and the
Vivado log filled with

    # Minor page faults: 4.52269e+06 Major page faults: 277047
    # Thrashing Detected!

NWROM's rule -- "peak RSS 15.27 GiB, one Vivado at a time" -- was honoured and
the box thrashed anyway, because 15.27 GiB is measured against 31 GB of RAM that
an 18 GiB resident service had already taken. **The rule that holds is
HEADROOM, checked with `ps --sort=-rss` and `free -g`, and the Vivado count is
only a proxy for it.** Applied in the other direction later the same hour: the
HBM repeat was run alongside another track's 4.60 GiB Vivado, deliberately,
because 4.60 + 11.93 fits in the 22 G that was actually free -- rather than
waiting out a 45-minute patience timer on a count.

### 7.7 This track made that worse, and then nearly made it much worse

A `sim/regress.sh` row set was started concurrently with a Vivado point. That
was this track's error and the run was stopped. **Three of the four surviving
`ghdl` processes turned out not to be this track's** -- this track's used
`REGRESS_SCRATCH=/mnt/storage/nwfix/regress2`, the survivors used
`--workdir=/tmp/claude-1000/.../329968a0-...`, the SESSION scratchpad, i.e.
another track's concurrent gate run. Reading each parent's `args` before
killing anything is what caught it. **A `pkill` on any pattern loose enough to
match "ghdl" would have taken another track's gate out from under it**, and the
CLAUDE.md rule about `pkill -f` is usually stated as a self-match hazard; this
is the other half of it.

### 7.8 `HEAD` moved under the track, exactly as the brief warned

`git rev-parse HEAD` was run as its own step and returned `0d14a70`, not the
`fc7dea9` the brief named. The intervening commit (`asurv`, a comment
correction in `sim/regress.sh`) touches neither `rtl/llama_top.vhd` nor
`rtl/rmsnorm_rs.vhd`, and both were verified unchanged by `git diff --stat`
before the archive was trusted.

### 7.9 A results directory that reads `-` is a broken extractor, not a missing number

The first summariser printed `-` in the `own` column for every point. The cause
was an awk field pattern, not an absent report. State the extractor's teeth by
requiring a known-good point to reproduce a known-good number: `nf_empty` had to
print 25,523 before any other row was read.

---

## 8. What was NOT verified

**Nothing here is placed or routed.** Every caveat in
`sim/ooc_compose_bcd.tcl`'s header stands. An OOC synthesis sum is not a
routability result.

**The Vivado half of the values oracle is OPEN.** The GHDL half is closed: the
elaborated `NW_TBL` holds the file's values, cross-checked against an
independent reader, teeth-checked with six mutations. Nothing here reads back
what VIVADO's `hread` loaded. The available circumstantial evidence is NWROM's
section 5.5, where the flop count of the OLD loader is predicted to within 0.1%
by the varying-bit count of this same image -- which shows Vivado's table
depends on the file's contents, and does not show it holds the right ones.
Closing it needs a probe that exposes a checksum of `NW_TBL` through the
synthesised netlist, which is not attempted here.

**NORMADAPT's `m_nidx_at_accept` blind spot is RESTATED and NOT closed, and this
track can now say precisely what closing it costs.** The gain-index sequencing
(`nsel`, `nidx`, `novf`) is untested by any bench. NWROM said it was untestable
through `tb_llama_top_normw` near the real shape without confronting the
elaboration limit; that half is now fixed, so Vivado is no longer the obstacle.
**GHDL is.** Section 7.2 measures the remaining one: a real-shape table needs
`ulimit -s unlimited` and `--max-stack-alloc=0`, and neither is set by
`sim/regress.sh`. The sequencing can be tested at a MODERATE `NW_N > 1` -- which
`tb_llama_top_normw` already has at 9 ops of 64 elements -- and what is missing
there is not shape but an assertion on WHICH gain each norm op used. That is an
equivalence question and it is not answered here.

**The HBM number is a FLOOR and not a price.** The probe deletes the table and
streams the gain into `wsel` as in-order beats. It contains no address
generation, no AXI read master, no burst logic, and no schedule deciding which
gain to fetch, so the region read path NWROM called unmeasured is still
unmeasured. The shift register is also the cheapest legal write structure: if
beats ever needed to land out of order, WRITEDEC's measured barrel-shifter
penalty applies instead.

**`rtl/rmsnorm_rs.vhd` was not edited and its `ARG` row dominates the residual.**
TRACK DISTRAM owns it and is changing it. A `rmsnorm_rs` that moves changes
every total here in a direction this track cannot predict.

**The broader `tb_llama_top` gate rows were STARTED AND STOPPED and are not a
result.** `tb_llama_top_normw`, the row that pins this feature, PASSED on a
quiet box (`OVERALL PASS 1 FAIL 0`). A run covering `_seq` and `_real` as well
was started, contributed to the memory pressure in 7.6, and was killed by this
track before producing any verdict. **Nothing here shows those two rows still
pass**, and they should be run on a quiet box before the change is relied on --
though note the edit is confined to an elaboration-time function whose return
value is verified equal to the old one at both the bench shape and the real
shape by the oracle in 5.3.

**Only ONE repeat was taken of the HBM point and only two of the `nf_fix65`
point.** "Bit-identical on two draws" is much stronger than one draw and is not
a proof of determinism. A third HBM draw was queued and dropped for time.

**No non-monotonicity sweep was run on the new numbers.** NWROM measured that
the `NW_N` sweep is not monotonic and that `NW_N = 33` costs more than the real
65. Every number here is at `NW_N = 65` or at `NW_N = 1`, which are the two
configurations a real build can have, so the sweep's spread does not apply to
them -- but it does mean **no number here should be extrapolated to another
`NW_N`.**

---

## 9. The gate row this track would add, handed off rather than added

`sim/regress.sh` is TRACK FLOOR's file right now, so nothing was edited there.
**And on inspection the right home is not `regress.sh` at all**, which is the
useful part of this handoff:

- **`sim/regress.sh` cannot host this check.** Its rows are GHDL simulations,
  and GHDL has no elaboration loop limit. A row there would have passed
  throughout the defect's life, exactly as `tb_llama_top_normw` did.
- **`sim/elab9b_run.sh` (TRACK KVVALUE) is the real-shape elaboration gate and
  it is also GHDL**, so it is structurally unable to see this defect class
  either. That is worth writing on the board: **the project has a real-shape
  elaboration gate, in the one tool that cannot see the failure that gate would
  most obviously be expected to catch.** A useful row for it all the same is one
  that sets `NORM_W_IMAGE` to a real-shape image, because it would catch value
  and refusal regressions in the loader -- and it needs the two stack settings
  in section 7.2, which that script already half-provides.
- **The Vivado-side check ships here as `sim/ooc_nwfix_elabcheck.sh`**, with a
  free geometry guard that runs first and a `synth_design -rtl` that runs
  second. Suggested wiring, for whoever owns the nightly: run it on
  `hw/fk33/results/nwfix_2026-08-29/`'s image before any FK33 build that has
  `NORM_REAL = true`, and fail the build on `NWFIX_ELABCHECK FAIL`.

---

## 10. Corrections to the brief and to NWROM

| claim | verdict |
|---|---|
| the brief: "NWROM measured a one-line workaround that works ... **Decide deliberately whether that is the fix or a crutch.**" | **Crutch.** The decisive fact is that the limit is per loop statement, which makes the loop fixable; the tool parameter is global, undocumented, must be remembered by every flow, and does not survive a bigger model without being raised again |
| NWROM: "Line 187 is `nw_count`'s `while not endfile(fh) loop`. The image is one 4-hex-digit int16 per line, so 65 ops x 4096 elements is 266,240 lines against Vivado's default limit of 65,536" | **Correct, and incomplete in the way that matters.** The line count is not the binding quantity; the per-loop TRIP COUNT is. NWROM's own `nw_bnd65` point proves it by running the same 266,240 body executions as 65 x 4096 with no override |
| NWROM: "The threshold was bracketed by measurement, not assumed: `NW_N = 9` elaborates, `NW_N = 17` does not" | **The bracket is real and it does not isolate what it was used for.** Both functions scale with `NW_N`, so the bracket is silent on which loop hit the limit. See 7.1 |
| NWROM section 8: "Nothing here checks that the table Vivado loaded holds the file's values" | **Half closed.** The GHDL side is now an oracle against an independent reader with six teeth-checked mutations. The Vivado side is still open and is stated as such |
| the brief: "the cheapest honest option is probably a check on the image's line count against the elaboration limit" | **Adopted with a correction.** A line-count check would have been right for the OLD loader and is the WRONG invariant for the fixed one: the guard in `sim/ooc_nwfix_elabcheck.sh` checks the two LOOP BOUNDS (`ops` and `NN`) and reports the line count only as a note |
| the brief: "`NW_N = 33` ... margin is 9,383 LUT rather than 43,670 ... Any number you produce should be checked for the same non-monotonicity" | **Superseded by something worse.** The non-monotonicity across `NW_N` is real, and it is not the main problem: the value does not reproduce at a FIXED `NW_N` either. Every number here is at `NW_N = 1` or `NW_N = 65` and none is extrapolated across `NW_N`, but the ROM ones still carry a 45,468 LUT spread |
| the brief: "realistic B+C+D is **306,787 LUT** -- over the device by 38,565 (1.14x)" | **That is the BEST of five draws.** The median booking is 327,492 (over by 59,270, 1.221x) and the HBM booking is 291,249 (over by 23,027, 1.086x) |
| NWROM: "**ESTIMATE ~72,000 LUT, 0 BRAM, plus an unmeasured region read path**" for the HBM route | **MEASURED at 67,059 LUT and 0 BRAM, twice, bit-identically.** The estimate was 7.4% high. The "unmeasured region read path" caveat STANDS and is restated in section 8 |
| NWROM section 6: "Editing `nw_count` and quoting the result as the shipping cost ... MEASURED at 103,081, which is 20,484 MORE than the committed RTL ... **Quote `nw_lf65`**" | **WITHDRAWN.** The committed RTL under the override measures 103,302 here, within 221 LUT of the probe that entry rejects. `nw_bnd65` was never the outlier; `nw_lf65` was the low draw |
