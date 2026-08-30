# OI-9: subsystem A's 4-bit error code is full, so subdivide through `ERR_INFO`

TRACK ERRINFO, row N12. Started at `3d5cba9614d41f454f3d080cdf93968335adee28`.

## The question, verbatim

> **OI-9: subsystem D's descriptor error-code space is FULL.** Oren decided the
> route on 2026-08-29: **subdivide via `ERR_INFO`.** Not widening the code
> field, not raiding a reserved D value. [...] the descriptor's byte layout MUST
> NOT MOVE. [...] the deliverable is not "the codes are subdivided", it is **"a
> refusal now names which of the nine sites raised it, and here is the
> measurement proving it."**

## The answer, up front

`ERR_INFO` now carries **both** meanings at once: `[10:0]` is still the failing
descriptor word index, `[15:11]` is a sub-case namespaced per `err_code`. No
descriptor byte moved, the register's offset and width did not move, and
`0xFFFF` still means "the pointer itself" -- it falls out of the scheme as
sub-case 31, word 2047. Thirteen sub-cases separate `EC_DESC`'s nine check
arms, two separate `EC_GEOM`'s, three separate `EC_SHAPE`'s.

**Four findings that change the shape of the problem as stated:**

1. **The collision count was seven, not two.** MEASURED: at `3d5cba9`, seven
   distinct `(err_code, ERR_INFO)` values were each raised by two or more
   different checks. OI-9 had two of them on record. The other five were found
   the moment the claim was made executable, not by looking harder.
2. **`EC_DESC` is nine *sites* but thirteen *conditions*.** Four of the nine
   sites are multi-way `or`s (the shape range is four conditions, the beat
   check two, the extension pads two, `EC_GEOM` two). Counting sites
   under-reports what a host needs to be told.
3. **The extension-pad site named the WRONG WORD**, and it is a defect the
   sub-case field cannot fix: ext word 2 and ext word 3 are different *words*,
   not different checks. `sim/mv4i_desc_cases.py` had written this down as a
   case note -- "ERR_INFO names EXT0+2, not +3" -- rather than as a defect. It
   now names whichever word was actually nonzero.
4. **The host decoder is NOT `server/pl_backend.c`.** That file decodes the
   `FK33_SEAM_ERR_*` space, which `server/fk33_seam.h:227` says in its own
   comment is deliberately disjoint from A's. **The A-space decoder is
   `hw/fk33/host/fk33_run_job.py`, which this track is forbidden to touch.**
   That leaves a live defect; see "Not done, and why" below.

## The procedure

Each step isolates one thing, and the control is named.

### 1. Enumerate the raise sites at HEAD, from the RTL

`grep -n 'EC_\|err_info' rtl/matvec_int4_desc_axi.vhd`, then read every arm.
Not from the format document and not from OI-9's summary: where a document and
the RTL disagree the RTL wins, and here they did disagree.

Nine `EC_DESC` arms carrying seven distinct `ERR_INFO` values:

| # | condition | `ERR_INFO` at HEAD |
|---|---|---|
| 1 | `ext_flags` nonzero | `EXT0` = 35 |
| 2 | `opcode /= OP_A_JOB` | 0 |
| 3 | word 3's pad byte nonzero | 3 |
| 4 | word 7 nonzero | 7 |
| 5 | ext word 2 hi half **or** ext word 3 nonzero | 37 (`EXT0+2`) for both |
| 6 | `out_mode > 2` | 3 |
| 7 | `n_rows`/`n_cols` zero or over max (four conditions) | 1 for all four |
| 8 | `w_beats = 0` **or** `s_beats = 0` | 36 (`EXT0+1`) for both |
| 9 | `cb_load = 0` with no codebook loaded | 0 |

So sites 2 and 9 collide, and 3 and 6 collide -- the two OI-9 recorded --
leaving **five of nine sites uniquely attributable**, not six. Sites 5, 7 and 8
are each internally ambiguous on top of that, which the site count hides.

### 2. Make "attributable" an executable claim, and run it on HEAD first

`sim/mv4i_desc_cases.py` already pins `(err_code, ERR_INFO)` on all 40-odd
refuse cases and already ran green, so its expectations were not the
instrument -- the missing claim was about the *relation between* cases.

Added a `site` column naming the one RTL arm each case must land on, and
`check_sites()`, which refuses to emit a suite unless:

* every case sharing a site expects the same pair (one check, one diagnosis --
  this is what stops the "fix" being "give every case its own number"), and
* no two different sites expect the same pair.

**Control / teeth-check, run first:** a copy of the file with `ei()` reduced to
`return word` and the ext-3 pad restored to `EXT0+2`, i.e. exactly HEAD's
reporting. It must fail. It does, at twelve reports over **seven** distinct
values. Raw output in section "Evidence" below.

### 3. Split the arms in the RTL, preserving first-match order

Every `err_info <= std_logic_vector(to_unsigned(X, 16))` became `ei(SUB, X)`,
and every multi-way `or` whose disjuncts are different checks became a chain of
`elsif` in the same slot and the same internal order. `EI_PTR` sites became the
constant `EI_PTR_V = x"FFFF"`, unchanged bit for bit.

### 4. Notice what the split newly makes wrong, and cover it

Turning one `or` into a chain creates something that could not be wrong before:
**the order of the new arms.** Every existing case sets exactly one field, so it
reaches its arm whichever order the arms are in. MEASURED: reversing the two
`EC_GEOM` arms kills no case in the 57-case suite.

Five cases added, one per split, each setting *both* fields and pinned to the
arm that must win: `R_GEOM_BOTH`, `R_PAD_EXT_BOTH`, `R_SHAPE_ALLBAD`,
`R_SHAPE_OVERBOTH`, `R_BEATS_BOTH0`. Suite goes 57 -> 62.

### 5. Give the second judge teeth it did not have

`sim/tb_matvec_fk33_desc.vhd` **printed** `ERR_INFO` on every refusal and
**checked** it on none. Ten of its twenty refuse cases were pinned to `err_code
0x3` and nothing else, so any two of them could have swapped verdicts and every
one would still have passed. Added a `CASE_INFO` expectation per case plus a
cross-case check over what was OBSERVED (not over the expectations, which would
pass with the gateware removed): no two EXP_ERR cases may report the same pair.

### 6. Retarget the mutation table, which the split broke

14 of 82 rows in `sim/mv4i_desc_mutations.py` anchor on text the split rewrote.
A stale anchor prints `ANCHOR` and is skipped -- loud, but still a mutation that
measures nothing. All 14 retargeted; one new row (`S8`) became expressible
because the beat check is now two arms; six new `EI*` rows swap one sub-case for
another, and every one of those was **inexpressible before this change** because
the two sites they confuse reported the same pair.

## Evidence

### HEAD's reporting, judged by the new gate (the teeth-check)

```
$ python3 <copy of sim/mv4i_desc_cases.py with ei() returning the bare word> outdir
SITE GATE: (err_code 9, ERR_INFO 0x0003) is reported by TWO different sites, R_GEOM_NPW and R_GEOM_NPS -- a refusal there cannot be attributed (OI-9)
SITE GATE: (err_code 3, ERR_INFO 0x0003) is reported by TWO different sites, R_W3PAD and R_OUTMODE -- a refusal there cannot be attributed (OI-9)
SITE GATE: (err_code 3, ERR_INFO 0x0001) is reported by TWO different sites, R_ROWS0 and R_ROWSOVER -- a refusal there cannot be attributed (OI-9)
SITE GATE: (err_code 3, ERR_INFO 0x0001) is reported by TWO different sites, R_ROWS0 and R_COLS0 -- a refusal there cannot be attributed (OI-9)
SITE GATE: (err_code 3, ERR_INFO 0x0001) is reported by TWO different sites, R_ROWS0 and R_COLSOVER -- a refusal there cannot be attributed (OI-9)
SITE GATE: (err_code 3, ERR_INFO 0x0024) is reported by TWO different sites, R_WBEATS0 and R_SBEATS0 -- a refusal there cannot be attributed (OI-9)
SITE GATE: (err_code 3, ERR_INFO 0x0025) is reported by TWO different sites, R_PAD_EXT2 and R_PAD_EXT3 -- a refusal there cannot be attributed (OI-9)
SITE GATE: (err_code 3, ERR_INFO 0x0000) is reported by TWO different sites, R_OPCODE and R_CBNEVER -- a refusal there cannot be attributed (OI-9)
SITE GATE: (err_code 15, ERR_INFO 0x0024) is reported by TWO different sites, R_SHAPE_WB and R_SHAPE_SB_LO -- a refusal there cannot be attributed (OI-9)
SITE GATE: (err_code 15, ERR_INFO 0x0024) is reported by TWO different sites, R_SHAPE_WB and R_SHAPE_SB_HI -- a refusal there cannot be attributed (OI-9)
12 (err_code, ERR_INFO) collisions -- refusing to emit a suite that cannot attribute a refusal
```

(12 reports, 7 distinct values: `(9,3)`, `(3,3)`, `(3,1)`, `(3,0x24)`,
`(3,0x25)`, `(3,0)`, `(15,0x24)`. Two of the twelve lines are duplicates from
sites that legitimately carry two cases.)

### The same gate after the change

```
62 cases written to <outdir>; site gate: 30 sites, no (err_code, ERR_INFO) shared between two of them
== rtl/matvec_int4_desc_axi.vhd mutation table ==
   judge      sim/tb_mv4i_desc_image.vhd, FK33 geometry
   cases      62 (sim/mv4i_desc_cases.py)
   classifier sim/mutverdict.py, three verdicts

baseline: all 62 cases pass on the unmutated design
```

### What the gateware actually reports, per site

MEASURED, `ghdl -r tb_mv4i_desc_image`, one run per case, values read back
through the AXI-Lite map at `0x10`. DERIVED column shown so the encoding can be
checked by hand: `ERR_INFO = sub*2048 + word`.

| case | err_code | ERR_INFO | = sub | word |
|---|---|---|---|---|
| `R_OPCODE` | 0x3 | 4096 | 2 | 0 |
| `R_CBNEVER` | 0x3 | 26624 | 13 | 0 |
| `R_W3PAD` | 0x3 | 6147 | 3 | 3 |
| `R_OUTMODE3` | 0x3 | 12291 | 6 | 3 |
| `R_OUTMODE255` | 0x3 | 12291 | 6 | 3 |
| `R_GEOM_NPW` | 0x9 | 2051 | 1 | 3 |
| `R_GEOM_NPS` | 0x9 | 4099 | 2 | 3 |
| `R_ROWS0` | 0x3 | 14337 | 7 | 1 |
| `R_ROWSOVER` | 0x3 | 16385 | 8 | 1 |
| `R_COLS0` | 0x3 | 18433 | 9 | 1 |
| `R_COLSOVER` | 0x3 | 20481 | 10 | 1 |
| `R_WBEATS0` | 0x3 | 22564 | 11 | 36 |
| `R_SBEATS0` | 0x3 | 24612 | 12 | 36 |
| `R_XEXPPAD` | 0x3 | 10277 | 5 | 37 |
| `R_EXT3PAD` | 0x3 | 10278 | 5 | **38** |
| `R_EXTFLAGS` | 0x3 | 2083 | 1 | 35 |
| `R_W7PAD` | 0x3 | 8199 | 4 | 7 |
| `R_WB_LOW` | 0xF | 2084 | 1 | 36 |
| `R_SB_LOW` | 0xF | 4132 | 2 | 36 |
| `R_SB_HIGH` | 0xF | 6180 | 3 | 36 |
| `P_ALIGN` | 0xC | 65535 | 31 | -- |
| `W_DEAD` | 0x4 | 65535 | 31 | -- |

`R_XEXPPAD` and `R_EXT3PAD` are the case the design was written to make: **one
sub-case, two word indices.** That is the "coexist rather than replace" claim
in executable form -- the sub-case says which check, the word says which word,
and neither can be recovered from the other.

### The second judge, before and after

`sim/tb_matvec_fk33_desc.vhd`, 22 cases, real `.mv4i` bytes, bit-exact against
`ref/matvec_int4.c`.

After (this tree):

```
attribution: 22 cases, 0 pairs of DIFFERENT checks sharing one (err_code, ERR_INFO)
tb_matvec_fk33_desc: 22 cases run, 0 failures
subsystem A is bit-exact with ref/matvec_int4.c through the descriptor control plane, and every checked mutation is refused
```

Before -- the identical bench run against a copy of
`rtl/matvec_int4_desc_axi.vhd` with every sub-case collapsed to `EI_SUB_NONE`
and the ext-3 pad restored to `EXT0+2`:

```
CASE 3 nsub_w = 23 (build has 24)  -> refused with the right err_code and the WRONG ERR_INFO: got 3 want 2051
CASE 5 opcode = 4 (VEC_NORM...)    -> refused with the right err_code and the WRONG ERR_INFO: got 0 want 4096
CASE 9 n_rows = 0                  -> refused with the right err_code and the WRONG ERR_INFO: got 1 want 14337
...
CASES 3 (nsub_w = 23) and 4 (nsub_s = 2)                BOTH refuse with err_code 9 ERR_INFO 3
CASES 5 (opcode = 4) and 14 (cb_load clear, no codebook) BOTH refuse with err_code 3 ERR_INFO 0
CASES 6 (word 3 pad) and 8 (out_mode = 3)                BOTH refuse with err_code 3 ERR_INFO 3
CASES 9 (n_rows = 0) and 10 (n_cols = MAXCOLS+1)         BOTH refuse with err_code 3 ERR_INFO 1
attribution: 22 cases, 4 pairs of DIFFERENT checks sharing one (err_code, ERR_INFO)
tb_matvec_fk33_desc: 22 cases run, 17 failures
SUBSYSTEM A'S DESCRIPTOR CONTROL PLANE FAILED 17 CASES
```

**Four pairs, and the comment in the bench originally predicted three.** The
fourth (cases 9 and 10) is one of the five collisions OI-9 did not know about.
The prediction was corrected in place rather than quietly matched to the run.

### The third judge, and the one gate row this nearly turned red

`tools/verify_mv4i_desc.py --rtl --teeth` is a separate judge again: it builds
the descriptor with `tools/gen_mv4i_desc.py` from the REAL 2.4 MB packed
tensor and pins `(err_code, ERR_INFO)` on 26 mutations plus the two pointer
cases. Its expectations were stale after this change; retargeted, then run:

```
RTL under test: HEAD f149731 PLUS uncommitted edits:
  M rtl/matvec_int4_desc_axi.vhd
   M rtl/matvec_int4_desc_pkg.vhd
PASS  4 nsub_w = 23 (build has 24)   RTL: 0x9 info 2051    expected 0x9 info 2051
PASS  5 nsub_s = 2 (build has 3)     RTL: 0x9 info 4099    expected 0x9 info 4099
PASS  9 ext word 2 pad half nonzero  RTL: 0x3 info 10277   expected 0x3 info 10277
PASS 10 ext word 3 nonzero           RTL: 0x3 info 10278   expected 0x3 info 10278
...
PASS  P DESC_PTR misaligned by 8 B   RTL: 0xC info 65535   expected 0xC info 65535
SILENT PASSES (5): the gateware accepts these and they are wrong.
VERIFY: PASS
```

**`sim/tb_a_geom.vhd` is the one that nearly went red, and it is a gate row.**
It pins `err_info = 1` on the `MAXROWS_BFP+1` bracket and `err_info = 3` on
three `EC_GEOM` brackets. MEASURED, before it was fixed:

```
tb_a_geom: CHECK FAILED -- n_rows = A_MAXROWS_BFP+1 (17409) was NOT refused at descriptor word 1 (err_code 3 err_info 16385)
tb_a_geom: CHECK FAILED -- nsub_w = A_NPORTS_W+1 (25) was NOT refused EC_GEOM at word 3 (err_code 9 err_info 2051)
tb_a_geom: CHECK FAILED -- nsub_s = A_NPORTS_S+1 (4) was NOT refused EC_GEOM at word 3 (err_code 9 err_info 4099)
tb_a_geom: CHECK FAILED -- the pre-2026-08-29 nsub pair (29,4) was NOT refused EC_GEOM at word 3 (err_code 9 err_info 2051)
tb_a_geom RESULT: FAIL -- 4 of 10 checks failed
```

It is **not** in this track's ownership list, and neither is
`tools/verify_mv4i_desc.py`. Both are "matvec benches", free per the board, and
both had to move with the package. The ownership brief named the files this
track would *edit*; the files that *pin* the value it changed are a different
and larger set, and the only way to find them was `grep -rln 'ERR_INFO\|EI_PTR'`
over the whole tree and then run each one. After the fix:

```
tb_a_geom RESULT: PASS -- 10 checks, A_ROWS_IF = 48, A_MAXROWS_BFP = 17408,
A_NPORTS_W = 24 and A_NPORTS_S = 3 agree with the descriptor plane's own generic defaults
```

`tb_a_geom` got **stronger**, not merely repaired: its `nsub_w+1` and
`nsub_s+1` brackets were previously refused identically, so the two RTL
conditions could have been swapped without failing anything there. They now
differ, and its `(29,4)` row additionally pins which arm wins when both fields
are wrong.

### The RTL-side teeth: six mutations that were inexpressible yesterday

`bash sim/mutate_mv4i_desc.sh <scratch> -j 8 --only EI`, judged by
`sim/tb_mv4i_desc_image.vhd` over the 62-case suite. Each row swaps one
sub-case for another, or reverses one pair of new arms. **Every one of these
was invisible to every case in the suite before this change**, because the two
sites it confuses reported the same `(err_code, ERR_INFO)`.

```
baseline: all 62 cases pass on the unmutated design

NAME  BRANCH VERDICT   NAMING CASE            NOTE
----- ------ --------  ---------------------- ----
EI1   IMG    KILLED    R_OPCODE (1/62)        the opcode refusal reports the CODEBOOK sub-case
EI2   IMG    KILLED    R_W3PAD (1/62)         word 3's pad refusal reports the OUT_MODE sub-case
EI3   IMG    KILLED    R_GEOM_NPS (1/62)      the nsub_s refusal reports the nsub_w sub-case
EI4   IMG    KILLED    R_EXT3PAD (1/62)       the ext-word-3 pad names word EXT0+2, as it did before OI-9
EI5   IMG    KILLED    R_SB_HIGH (1/62)       the s_beats UPPER-bound refusal reports the LOWER sub-case
EI6   IMG    KILLED    R_BEATS_BOTH0 (1/62)   the two beat-count arms are in the opposite order

TOTAL 6 mutations: 6 KILLED, 0 ABORT, 0 SURVIVED
```

**Read the `(1/62)`, not the KILLED.** Each mutation is caught by exactly ONE
case and passes the other 61, which is the right shape: it changes the report of
one site and nothing else, so a suite that killed it broadly would be telling
you the cases are entangled rather than that the check is sharp. `EI4` is the
pre-OI-9 behaviour restored, so that row is also a direct measurement that the
wrong-word defect was real and is now covered. `EI6` is caught only by
`R_BEATS_BOTH0`, one of the five order cases added in step 4 -- without it that
mutation survives, which is exactly why they were added.

## The scheme, and what it cost

```
ERR_INFO[15:11]  sub-case, namespaced PER err_code   (0 = none, 31 = the pointer)
ERR_INFO[10:0]   failing descriptor word index
```

* **Word index capped at 2047.** DERIVED: `desc_words(24,3) = 8+24+3+4 = 39` at
  the FK33, so the cap is 52x the longest descriptor this build produces and it
  binds only past `NPORTS_W + NPORTS_S = 2036`. `matvec_int4_desc_axi` carries
  `constant EI_WORD_FITS : natural := EI_WORD_MAX - (DWORDS - 1);` as the
  elaboration guard -- a `natural`, because Vivado silently ignores
  `assert ... severity failure` in synthesis.
* **30 sub-cases per code.** `EC_DESC` uses 13, `EC_GEOM` 2, `EC_SHAPE` 3.
* **Sub-case 0 leaves the value numerically unchanged.** Every unsubdivided site
  reports the same integer it always did, so a host that has not been taught the
  split still reads the right word for those, and reads a conspicuously large
  number for the rest -- visible, not silently wrong.
* **`0xFFFF` is unchanged**, as sub-case 31 / word 2047.
* **Nothing in the descriptor moved.** `ERR_INFO` is a register field. That is
  the whole reason this route was chosen over widening `err_code`.

Why 5/11 and not 4/12: `EC_DESC` needs 13 sub-cases today. A 4-bit sub field
gives 14 usable values (0 and 15 reserved), which is one spare on the very code
whose pressure caused OI-9. 5/11 gives 30 and still leaves 2047 words.

### Everything that pins an `ERR_INFO` value, swept

`grep -rln 'err_info\|ERR_INFO\|EI_PTR'` over `rtl sim tb tools hw server ref
docs`, then classified by hand:

| file | pins a value? | action |
|---|---|---|
| `rtl/matvec_int4_desc_axi.vhd` | raises | changed |
| `sim/mv4i_desc_cases.py` | 62 pins | changed |
| `sim/tb_matvec_fk33_desc.vhd` | 0 pins (printed only) | pins added |
| `sim/tb_a_geom.vhd` | 4 pins | changed, was FAILING |
| `sim/mv4i_desc_mutations.py` | 14 stale anchors | retargeted, +7 rows |
| `tools/verify_mv4i_desc.py` | 28 pins | changed, re-run, PASS |
| `sim/tb_mv4i_desc_image.vhd` | compares a generic, pins nothing | untouched |
| `hw/fk33/gen_fk33_regs.py`, `hw/fk33/host/fk33_regs.h` | `EI_PTR` only | `--check` still passes, header byte-identical |
| `hw/fk33/host/fk33_run_job.py` | decodes `0xFFFF` vs "word index" | **NOT DONE, handed off** |
| `sim/seq_tbl_pkg.vhd`, `sim/tb_seq_tbl_shape.vhd` | the string `"err_code 0x3 err_info 1"` in a MESSAGE, not a comparison | untouched |
| `server/**`, `rtl/seq_*` | the `FK33_SEAM_*` / subsystem D spaces | out of scope |

## Measured and REJECTED -- do not retry

* **`server/pl_backend.c` as the host decoder.** MEASURED: it reads
  `FK33_SEAM_STATUS`/`FK33_SEAM_ERR_INFO` and decodes `FK33_SEAM_ERR_*`
  (0x0..0x8). `grep -rn 'EC_\|0x12000\|ENG_CTL' server/` returns nothing. Its
  own header, `server/fk33_seam.h:227`, says the seam codes are "deliberately
  NOT overlapping subsystem A's 0x0..0xF space, because A's is FULL (OI-9)".
  Editing it would have invented a decoder for a space it does not read, on a
  seam row N2 has not decided. Not done.
* **Editing `hw/fk33/host/fk33_regs.h` directly.** It is GENERATED by
  `hw/fk33/gen_fk33_regs.py` and says so; an edit would be deleted by the next
  build. MEASURED: `python3 hw/fk33/gen_fk33_regs.py --check` still passes after
  this change and the header is byte-identical, because the sub-cases are
  `natural` constants and the generator's `EC_*` regex matches only
  `std_logic_vector(3 downto 0)`. So the header is INCOMPLETE, not broken.
* **A 4-bit sub-case field (`[15:12]`).** Rejected on arithmetic, not taste:
  `EC_DESC` needs 13 of the 14 usable values on day one.
* **Widening `err_code`, or taking one of D's reserved `0x1,0x2,0x5..0x8`.**
  Both were ruled out by Oren before this track started; recorded here only so
  the file is self-contained.
* **Giving every REFUSE case its own sub-case number.** That passes the
  distinctness half of the gate vacuously while separating reports rather than
  checks. It is why `check_sites()` asserts the *converse* too: cases sharing a
  site must share a pair. `R_OUTMODE3` and `R_OUTMODE255` are the same check and
  must report the same thing.

## Measurement traps hit, including my own

* **`--apply` on a duplicate mutation name is silent.** I added six mutations as
  `N1..N6` and `sim/mv4i_desc_mutations.py` already had an `N1` and an `N2` in
  its GEN branch. Nothing complained: `--list` emitted both rows, and `--apply`
  returns on the FIRST match, so two edits would never have been tested and two
  would have been tested twice -- with a full-looking table either way. Caught
  by a `Counter` on the names, only because I happened to run `--only N` to see
  what it would match. Renamed to `EI1..EI6`, and a uniqueness gate now runs at
  import. **The first full mutation run was killed and restarted because of
  this**; its results are discarded.
* **`ghdl -r ... | grep` reports the PIPELINE's rc.** I wrote `echo "rc=$?"`
  after a pipeline twice and read the grep's status as the tool's. Quote
  `${PIPESTATUS[0]}`. This is on the standing trap list and I hit it anyway.
* **A grep-derived file list is alphabetical, not dependency-ordered.** Building
  a GHDL analysis order with `grep -o 'rtl/.*\.vhd' <script>` produced 23
  "unit not found" errors that looked exactly like my change breaking the
  package. They were ordering. Take the `FILES=` line from the script.
* **`sim/tb_mv4i_desc_image.vhd` prints `err_code 0x15` for `EC_SHAPE`.** It
  concatenates the literal `"0x"` with `integer'image`, which is decimal. So
  `0x12` in that log means 12 = `EC_ALIGN` and `0x15` means 15 = `EC_SHAPE`.
  Cosmetic, in a file this track does not own, and it will mislead anyone
  reading a log for a hex code.
* **`setsid nohup ... & ; $!` does NOT give you the long-running pid.** `setsid`
  forks, so `$!` is the launcher, which exits at once. A wait loop written as
  `until <cond> || ! kill -0 $PID` therefore returns immediately and reports the
  job finished when it had barely started. The standing trap list says
  `nohup ... &` reports the LAUNCHER's rc; this is the same defect one layer
  further out and it is not on the list. Poll the log for the job's own final
  line instead.
* **`kill -TERM -$!` after `setsid` kills NOTHING, and the job keeps running.**
  Same root cause as the trap above. I "killed" two long mutation runs and
  started a third; `ps` later showed **all three alive** and the load average at
  26 on a box already running another track's Vivado. Every timing number I
  took in that window is contended and I am not quoting any of them. Kill by
  the pgid of the process `ps` actually shows, not by `$!`.
* **The ownership brief named the files to EDIT, not the files that PIN.**
  Three benches outside this track's list pinned the value being changed and one
  of them, `sim/tb_a_geom.vhd`, is a gate row that went red. Nothing in the
  brief or the board would have surfaced them; only a tree-wide grep did.
* **The site count is not the condition count.** Reading OI-9's "nine sites" as
  "nine things a host needs told" under-reports by four. The `or` is what hides
  them.

## Not done, and why -- a live defect, handed off

`hw/fk33/host/fk33_run_job.py:833` decodes `ERR_INFO` as:

```python
"the pointer itself" if bar.rd(R["FK33_ENG_ERR_INFO"]) == 0xFFFF
else "descriptor word index"
```

After this change an opcode refusal reports `0x1000`, and that line prints
**"descriptor word index"** for the value 4096. That is a wrong diagnosis
printed confidently, which is worse than the ambiguity it replaces. The fix is
small and is written out ready to apply, but `hw/fk33/host/**` is outside this
track's ownership and a track is active in that directory. **Handed off rather
than done.** Patch text: the "HANDOFF" section of this track's report, and the
scratch file it names.

## What was NOT verified

* **Nothing was run on hardware.** No `xsdb`, no `vivado ... program`, no
  `/dev/xdma*`. Card 1 was untouched.
* **No synthesis run.** The `EI_WORD_FITS` elaboration guard is verified to be
  a correctly-signed `natural` expression and to elaborate under GHDL; it has
  **not** been shown to fail a Vivado build, because no OOC run was made. The
  technique is the project's recorded one, but this instance is unmeasured.
* **`EC_CORE` (0xE) is still reachable by no bench in the tree** -- that is row
  N7's finding and is unchanged here. Its sub-case is `EI_SUB_PTR` by
  construction and no case exercises it.
* **The `EC_ADDR` / `EC_ALIGN` base-array arms have no sub-case** (0). They are
  already separated by two codes and by the word index, and no case in the suite
  needs more. If a third base-class check is ever added, it needs one.
* **The relative order of the four shape arms was verified for two pairs only**
  (`R_SHAPE_ALLBAD` covers rows-zero before cols-zero, `R_SHAPE_OVERBOTH` covers
  rows-max before cols-max). The cross pairs -- rows-zero against cols-max, and
  rows-max against cols-zero -- are not covered by any case.
* **The full 89-row mutation table was NOT run end to end.** Only the six new
  `EI*` rows were, above. The 14 retargeted anchors were verified to RESOLVE
  (each matches exactly once in the RTL, checked by string count) but were NOT
  re-verified to still KILL anything. One full run is ~89 x 5 min because each
  mutation re-analyses 13 files serially before its 62 cases, and the box was
  carrying another track's Vivado throughout. **This is the largest single gap
  in this write-up.** The three judges that WERE run cover the same checks from
  three directions, but a mutation table is a different claim from a case suite
  and it has not been re-made.

## Corrections to the brief this track was given

Appended, not edited into the text above.

1. "`EC_DESC` (0x3) is raised at NINE sites, with two confirmed collisions" --
   the nine is right. The two is a floor: **seven** distinct `(err_code,
   ERR_INFO)` values were shared, across `EC_DESC`, `EC_GEOM` and `EC_SHAPE`.
2. "'refused for the right reason' is currently recoverable for only 6 of 9
   codes" -- MEASURED, it is **5 of 9** sites (sites 1, 4, 5, 7, 8 are unique;
   2 and 9 collide, 3 and 6 collide). And three of those five "unique" sites are
   internally ambiguous, so the number of *conditions* a host could name was 7
   of 13.
3. "Update the host decoder in the same change [...] That is
   `server/pl_backend.c`" -- it is not. See "Measured and REJECTED".
4. The brief warns the name is `EC_GEOM`, not `ERR_GEOM`. Confirmed in the RTL.
   Note the *document* `docs/2026-08-28_matvec-descriptor-format.md` uses
   `ERR_GEOM` in its table; both names are in the tree for the same value.
