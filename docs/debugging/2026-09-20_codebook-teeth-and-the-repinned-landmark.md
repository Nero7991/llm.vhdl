# The norm-gain codebook gets teeth, and the landmark that guards it can be re-pinned over a wrong design

TRACK GAINTEETH, 2026-09-20.  Workstation, git `da9a1aa` on branch `fpga`,
with the control repeated at `9cdf13b`.  No hardware, no Vivado.  GHDL
(mcode) only.

---

## 1. The question, verbatim

> TRACK REANCHOR, closing out: *"**Nothing in the tree has teeth on the
> codebook.**  `grep -l 'cbrom|CBMAP|CBMARK|ixrom'` over all 62
> `sim/mutate_*.sh` returns **nothing**.  `c094867` made the gain store an
> 11-bit index ROM plus a 1,567-entry codebook -- a packer/unpacker pair, the
> recorded `m7 mutant` shape, exactly what U2/U3 attacked.  Retiring
> `normuram` did not create the hole; it made it visible."*
>
> The brief: find the structure from the RTL rather than from those words;
> decide what an ORACLE for it looks like and say why a round trip is not
> one; write a new `sim/mutate_gain*.sh` with an `__ANCHOR_FAIL__`-class
> sentinel, a distinct BADMUT verdict, a `Z0` self-teeth row, a nonzero exit
> when a row did not run, and a per-tag ledger; teeth plus an attribution
> control on every row; report every mutation that does NOT bite.

---

## 2. The answer, up front

**The structure is as described and the hole was real: `sim/mutate_gain.sh`
is the first harness in the tree that mutates it.**  Nine mutations, two
self-teeth rows, and a two-run ablation on every row.  **Six of the nine
bite, three do not, and the three that do not are the result worth keeping.**

**The finding that generalises beyond this structure: on THIS pair the
pre-existing STRUCTURAL gate is blind to every value fault but one, so the
whole burden falls on the P14 landmark -- and a landmark can be re-pinned.**
MEASURED, row G1R: take the m7 mutant, read the four landmark values it
prints, pin THOSE, and `tb_llama_top` reports **PASS** while
`tools/norm_w_bisect.py` still reports **0 of 9 seams match the model**.
That is exactly what would have happened had the codebook been wrong on the
day `c094867` landed: the landmarks would have been measured against the
wrong design and pinned to it, and every gate since would have been green.
**The oracle is the only check in this path that can say the design was ever
RIGHT rather than UNCHANGED.**

**Second finding, and it is why a round trip is not the test here.**  A
codebook RELABELLING is unobservable at the store's output: row G2 applies
the same reversal to the packer (`CBMAP` consumer) and the unpacker
(`cb_rom`) and the design is not merely PASSING but **bit-identical -- R_X(0)
= -16350, hash(R_X) = 90889, the control's own numbers**.  So there is
nothing about the labelling itself for any test to check, and a self-test
over the codec would spend its resolution there.  What DOES matter is the
composition, and rows G4, G7, G8 and G9 are faults a `decode(encode(v)) = v`
check cannot see at all because the codec is intact and the ADDRESSING or the
DOMAIN is wrong.

**Third: this track's own Z0 self-teeth row passed for the wrong reason on
its first run**, and the fix is recorded in section 6.  A self-teeth row
whose REQUIRED verdict is BADMUT is the hardest kind of row to notice has
stopped measuring, because the expected output and the broken output are the
same word.

---

## 3. Which codebook this is, and how it was told apart from subsystem A's

Two things in this tree are called "the codebook".  They were separated
before anything was written, by PORT and by FILE rather than by the word:

| | norm gain (THIS track) | subsystem A's IQ4_NL |
|---|---|---|
| file | `rtl/llama_top.vhd`, inside `gvr : if NORM_REAL and vi = V_NORM generate` | `rtl/matvec_core.vhd` |
| written by | VHDL elaboration, from the `NORM_W_IMAGE` generic | the host at run time |
| ports | **none** | `cb_we`, `cb_addr`, `cb_data` (spec 6.1) |
| index | `IXW`, derived from the image | 4 bits, fixed (an INT4 nibble) |
| entries | `NCB`, derived from the image | 16 |
| existing teeth | **none before this track** | `sim/mutate_matvec_cb.sh`, `sim/mutate_matvec_core.sh` class CB |
| owner today | this track | TRACK CBFANOUT |

`rtl/matvec_core.vhd` was not opened, edited or analysed by this track.

---

## 4. The structure, read from the RTL and not from the brief

MEASURED at `da9a1aa`, `rtl/llama_top.vhd` lines 3157-3374, all inside the
`gvr` generate:

```
type cbmark_t is array (0 to 2**MANT_W-1) of boolean;       -- 65,536 flags
type cbmap_t  is array (0 to 2**MANT_W-1) of natural ...;   -- value -> index
constant CBMARK : cbmark_t := cb_mark;    -- marks every value the image uses
constant NCB    : positive := cb_count;   -- how many distinct values
constant CBMAP  : cbmap_t  := cb_map;     -- THE PACKER
constant IXW    : positive := ixw_of(NCB);-- index width, >= 1
type cbrom_t  is array (0 to NCB-1) of std_logic_vector(MANT_W-1 downto 0);
type ixrom_t  is array (0 to NW_N*NWORD-1) of std_logic_vector(IXW-1 downto 0);
signal ixrom : ixrom_t := ixrom_flat;  attribute rom_style ... "block";
signal cbrom : cbrom_t := cb_rom;      attribute rom_style ... "distributed";
...
wix   <= ixrom(nidx*NWORD + (wel / GW));   -- registered, in `wload`
nw_wd <= cbrom(to_integer(unsigned(wix))); -- combinational, in `wsubsel`
```

So: **the reader is `wload` plus `wsubsel`, the writer is elaboration, and
there is no other writer.**  `MANT_W` is 16 (the top-level generic at line
210) and `GW` is 1 since `21db25b`, so `NWORD = NN`.

The two shapes, both MEASURED here rather than taken from `c094867`'s commit
message, by reading the images directly:

```
$ python3 -c "... hw/fk33/gen/norm_w_9b.hex ..."
9B image:    elements 266240  distinct 1567  max 0x2fe0  IXW 11
   md5 69f614a1515e1160f5dc9e8a9e72fdc3   (the md5 c094867 quotes)
$ python3 -c "... sim/llama_top_nw_b4_mean.hex ..."
bench image: elements 576     distinct 406   max 0x22d9  IXW 9
```

**The bench exercises a 406-entry codebook with a 9-bit index, not the
build's 1,567 and 11.**  That is a real limit on every row below and is
stated again in section 8.

---

## 5. The oracle, and why a round trip is not one

The oracle is `tools/norm_w_bisect.py`, which already existed for
`sim/mutate_normw.sh`.  For each of the 9 `OP_VEC_NORM` steps of a captured
token it compares, BIT FOR BIT,

```
expected = rmsnorm_bf(the machine's own R_X, the machine's own x_exp,
                      the gain read from the image by its own reader)
```

against the `R_XN` the machine wrote.  **Both halves come from outside the
design**: the arithmetic is `tools/ref9b/vec_oracle.norm_bf`, transcribed
from `ref/rmsnorm_bf_vec.c`, and the gain is read from
`sim/llama_top_nw_b4_mean.hex` by `read_gains()`.

**It is shown to discriminate rather than assumed to.**  `--also-ramp`
repeats the same comparison with the OLD synthetic ramp in place of the
image's gain, on the same capture:

```
# 9 of 9 R_XN seams match the model bit for bit
# 0 of 9 R_XN seams match the ramp
```

A comparison that passed with either gain would not be checking the gain.

**Why a round trip would not do.**  `decode(encode(v)) = v` is the check the
`m7 mutant` passed while being wrong.  Here it is worse than insufficient, it
is mis-aimed:

- it PASSES for G2, G3 and G6 -- and so does the design, because those three
  are genuinely equivalent (section 7);
- it would FAIL for G1, which is the one row where the codec itself drifts;
- and it is BLIND to G4, G8 and G9, where the codec is untouched and the
  store is addressed wrongly, and to G7, where the DOMAIN the codec is built
  over is wrong.

So a codec self-test buys one row of the nine, and that row is the one the
single-source construction was designed to make impossible.

---

## 6. The procedure, in the order it was run

1. **Read `git show c094867` and then the RTL**, not the brief's prose.  The
   entity, the two ROM signals, their `rom_style` attributes, their writers
   and their single reader are section 4.
2. **Re-derive the image statistics from the images**, so the shape numbers
   are this track's measurement and not a quotation.
3. **Replay every anchor against THREE tree states** before writing any row:
   the worktree at `da9a1aa`, `git show HEAD:` (which moved to `9cdf13b`
   under this track, when TRACK GSRWIDE landed), and the dirty working tree.
   All nine anchors matched exactly once inside the `gvr` scope in all three.
   **The `gvr` region is byte-identical in all three** (70,648 bytes, md5
   `26bc256e5a2fd712bd7a28ea28cdff92`), which is what makes a table measured
   at `da9a1aa` a statement about HEAD.
4. **Run the teeth from a detached `git worktree`**, not the shared checkout:
   `rtl/llama_top.vhd` was dirty from a concurrent track the whole time.
5. **Two runs per row, not one classification.**  `struct` is
   `tb_llama_top` with the four P14 landmarks UNSET; `land` is the same
   mutant with them pinned as `sim/tb_llama_top_normw.vhd` pins them.  The
   oracle runs on the `struct` run's capture.
6. **Repeat the control at today's HEAD** after GSRWIDE landed:
   `G0  SURVIVES  SURVIVES  9/9`, identical to `da9a1aa`.

---

## 7. The evidence, as raw output

### 7.1 The table (MEASURED, `da9a1aa`, `sim/mutate_gain.sh`, rc 0)

```
TAG   struct    land      oracle  WHAT
----- --------- --------- ------- ----
G0    SURVIVES  SURVIVES  9/9     CONTROL: clean tree.
        ORACLE TEETH: # 9 of 9 match the model / # 0 of 9 match the ramp
Z0    BADMUT    BADMUT    BADMUT  SELF-TEETH: impossible anchor inside a real scope
        WHY: ANCHOR MATCHED 0 TIMES IN SCOPE, REQUIRED 1:
Z1    BADMUT    BADMUT    BADMUT  SELF-TEETH: impossible SCOPE header, real anchor
        WHY: SCOPE BEGIN MATCHED 0 TIMES, REQUIRED 1:
G1    SURVIVES  K:land    0/9     m7, UNPACKER HALF ONLY: cbrom's index convention reversed against CBMAP's
G2    SURVIVES  SURVIVES  9/9     m7, BOTH HALVES: the same relabelling on packer and unpacker.  EXPECTED TO SURVIVE
G3    SURVIVES  SURVIVES  9/9     cb_mark walks the gain vector element-REVERSED.  EXPECTED TO SURVIVE: it builds a set
G4    SURVIVES  K:land    0/9     ixrom_flat packs the gain vector element-REVERSED
G5    SURVIVES  K:land    6/9     IXW one bit too narrow: the index truncates and high codewords alias
G6    SURVIVES  SURVIVES  9/9     cb_count returns 2*NCB.  EXPECTED TO SURVIVE
G7    K:struct  K:land    0/9     cb_mark marks v mod 256: the codebook loses most of its values
G8    SURVIVES  K:land    0/9     the lookup ignores wix: every element decodes to codeword 0
G9    SURVIVES  K:land    1/9     every norm op reads gain 0 (nidx ignored).  Carries mutate_normw.sh's dead M3
G1R   (G1)      SURVIVES  0/9     G1's mutant with the landmarks RE-PINNED to its own output
```

### 7.2 The attribution, stated as an ablation and not as a classification

**The structural gate earns ONE kill in nine, and it is incidental.**  Every
other biting row is `SURVIVES` in the `struct` column: with the landmarks
unset, `tb_llama_top` reports PASS over a design whose every norm output is
wrong.  The one exception, G7, is not caught as a gain fault either --

```
tb_llama_top: the residual at step 48 has operand exponents 11 and 30, 19
  apart against a 16-bit mantissa.  One operand shifts out ENTIRELY
tb_llama_top: schedule mismatches=0 skew differences=0 degenerate
  residuals=14 token position faults=0 KV sticky errors=0 KV faults=0
```

-- it is the DEGENERATE RESIDUAL check noticing that the gain collapsed far
enough to break the residual's exponent alignment.  A smaller error of the
same kind would pass it.

**The landmark earns the other five, and here is what it saw:**

```
G1   EXP_X0 => -17691, EXP_XSUM => 92699, EXP_STEPH => 53832   (4 moved)
G4   EXP_X0 => -16338, EXP_XSUM => 35049, EXP_STEPH => 12801   (4 moved)
G5   EXP_X0 => -16256, EXP_XSUM => 60781, EXP_STEPH => 62868   (4 moved)
G7   EXP_X0 => -32000, EXP_XSUM => 41943, EXP_STEPH => 59275   (4 moved)
G8   EXP_X0 => -16210, EXP_XSUM => 37594, EXP_STEPH => 24776   (4 moved)
G9   EXP_X0 => -16350, EXP_XSUM => 90069, EXP_STEPH => 82738   (3 moved)
```

**G9 moves only THREE**, and the one that does not move is the sharp part:
`EXP_X0` is still the control's `-16350` because norm op 0 legitimately reads
gain 0, so the first capture is correct and the divergence starts at the
second.  The oracle says the same thing at seam resolution:

```
R_XN-0       MATCH
R_XN.ffn-0   64 of 64 mantissas differ  first at element 0: expected -24668, captured -29111
... 8 seams differ ...
# 1 of 9 R_XN seams match the model bit for bit
```

**G5 is the partial one and it is the most informative kill in the table.**
One bit off the index width does not break everything, it breaks exactly the
seams whose gain vectors use a codeword above 255:

```
R_XN-0       MATCH
R_XN.ffn-0   MATCH
R_XN-1       MATCH
R_XN.ffn-1   MATCH
R_XN-2       59 of 64 mantissas differ  first at element 0: expected -30511, captured -24393
R_XN.ffn-2   MATCH
R_XN-3       exp 13 vs 14  64 of 64 mantissas differ
R_XN.ffn-3   MATCH
R_XN.final   exp 13 vs 14  64 of 64 mantissas differ
# 6 of 9 R_XN seams match the model bit for bit
```

A three-of-nine kill is still a kill, and a harness that only printed
PASS/FAIL would have reported it identically to G7's nine-of-nine.

### 7.3 G1R, the row that says what a landmark is worth (MEASURED)

`G1` is the m7 mutant: the unpacker's index convention reversed while the
packer's is not.  Re-run it with the landmarks pinned to the numbers **it
printed**, exactly as anyone would have pinned them on the day:

```
G1R  (G1)  SURVIVES  0/9
     -gEXP_X0=-17691 -gEXP_XSUM=92699 -gEXP_XALL=92699 -gEXP_STEPH=53832
```

**`tb_llama_top RESULT: PASS`, and the oracle still refuses the design.**
The bench's own header already says *"A LANDMARK IS A CHANGE DETECTOR, NOT AN
ORACLE"*; this is that sentence measured on a structure that had no oracle
row at all until today.

### 7.4 The three rows that do NOT bite, under their own names

These are the resolution floor of the whole table and they are not failures.

**G2 -- the mirror pair.**  `cb_rom` writes `r(NCB-1-CBMAP(v))` and
`ixrom_flat` stores `NCB-1-CBMAP(v)`: both halves relabelled the same way.
Not merely PASS -- **bit-identical to the control**:

```
G2: tb_llama_top RESULT: PASS ... R_X(0) = -16350 hash(R_X) = 90889
G0: tb_llama_top RESULT: PASS ... R_X(0) = -16350 hash(R_X) = 90889
```

This is the single-source construction `c094867` argued for, MEASURED: the
labelling is private to the pair and unobservable outside it.  **It also
bounds what any future test of this structure can be worth** -- a check that
claims to verify the codebook's labelling is checking something with no
observable consequence.

**G3 -- `cb_mark` walks the gain vector element-reversed.**  Also
bit-identical (hash 90889).  `cb_mark` builds a SET, and a set does not
remember the order it was filled in.  The row exists because that site LOOKS
exactly like the packing-order hazard the RTL's own comment warns about two
functions later, and provably is not one.

**G6 -- `cb_count` returns twice NCB.**  Also bit-identical (hash 90889).
The codebook is allocated at 812 entries instead of 406 and `IXW` widens from
9 to 10; the entries above 405 are never addressed.  In a build this is pure
area, and **no simulation row in this project can see it** -- it is a
synthesis-only cost.

---

## 8. Measured and REJECTED -- do not retry

- **A round-trip/codec self-test as the check for this structure.**  Measured
  against the table: it duplicates G1 and is blind to G4, G7, G8, G9 --
  and it spends its resolution on the labelling, which G2 shows has no
  observable consequence.  The oracle is `tools/norm_w_bisect.py`; use it.
- **`NRUNS=1` to halve the run cost.**  Tried during setup and it works (the
  four landmarks are unchanged at `NRUNS=1`, MEASURED), but the gate row is
  `NRUNS=2` and the `struct` column is supposed to BE the pre-existing
  structural gate, which includes the descriptor-latency skew check.  Running
  the ablation against a weaker gate than the real one would credit the
  oracle with kills the gate row might have made.  Kept at `NRUNS=2`; the
  whole 13-row table costs about 26 minutes.
- **Mutating `cb_rom`'s loop ORDER to break the mirror.**  `cb_rom` writes by
  `CBMAP` index, so reversing its `for a`/`for b` loops changes nothing at
  all -- it would have been a NOEDIT-class no-op row wearing an m7 name.  The
  mirror has to be broken on the INDEX EXPRESSION (`NCB-1-CBMAP(...)`), which
  is what G1 does.
- **`grep -l 'cbrom\|CBMAP\|CBMARK\|ixrom' sim/mutate_*.sh` as the detector
  for this hole.**  It returned nothing when REANCHOR ran it and it returns
  `sim/mutate_llama_top_normuram.sh` TODAY -- because REANCHOR's own
  retirement tombstone quotes the four names in a COMMENT.  **A substring
  grep counts comments**, which is the third recorded instance of that trap
  in this project (a presence guard satisfied by a comment; a count guard
  inflated by a comment; now a hole-detector satisfied by the note saying the
  hole exists).  The substantive claim was still correct: no harness
  MUTATED any of them.

---

## 9. Measurement traps hit, including this track's own

- **THE Z0 SELF-TEETH ROW PASSED FOR THE WRONG REASON ON ITS FIRST RUN.**
  MEASURED 2026-09-20: `mut()` was written
  `local tag="$1" dir="$RUNDIR/${tag}_src"`, and bash declares BOTH names
  local before evaluating either right-hand side, so `${tag}` was the new
  empty local and `set -u` aborted the function.  Every mutant directory was
  `/llama_top.vhd`, every row reported BADMUT -- **including Z0, whose
  REQUIRED verdict is BADMUT.**  The table looked like a harness working
  perfectly at its self-teeth and broken everywhere else; the only tell was a
  `FileNotFoundError` on stderr, detached from the row.
  Three fixes, all kept: two `local` statements; a **NOMUT/NOEDIT** pair of
  verdicts in `row()` (the mutant source must exist AND must differ from the
  clean file); and the mutator's stderr captured per tag so every BADMUT row
  prints a `WHY:` line naming its own cause.  The re-run shows
  `WHY: ANCHOR MATCHED 0 TIMES IN SCOPE` for Z0 and
  `WHY: SCOPE BEGIN MATCHED 0 TIMES` for Z1, which is the evidence that the
  two rows now fail for the two different reasons they are named for.
- **A row whose expected verdict is BADMUT is the hardest row to notice has
  stopped working**, because its correct output and its broken output are the
  same word.  The `WHY:` line is the cheap fix and it should be in every
  harness that has a Z0.
- **`sim/mutate_normw.sh`'s M3 has been dead since `47c9d9c`.**  Found by
  replaying its anchors: `wsel <= NW_TBL(nidx);` matches zero times, because
  TRACK RMSWIRE deleted that assignment.  It is SAFE -- `mrow` reads the rc
  and prints BADMUT -- so that harness currently exits 1 with one dead row.
  The property is "every norm op uses gain 0"; it is carried here as **G9**,
  re-anchored onto `wix <= ixrom(nidx*NWORD + ...)`, which is where `nidx`
  entered the gain path when `wsel` left it.  `sim/mutate_normw.sh` was NOT
  edited by this track (it is another owner's file and the brief said to
  write a new harness rather than extend one).
- **`ONLY` filters ROWS, not MUTATIONS.**  The substitutions still run, so
  the ledger lists `Z0` and `Z1` even on `ONLY="G0"`.  Harmless -- no GHDL
  runs -- but the ledger's line count is not a count of selected rows.

---

## 10. Open, not determined

- **Every number here is at the BENCH shape: 4 blocks, hidden 64, a 406-entry
  codebook with a 9-bit index.**  The build's codebook is 1,567 entries and
  11 bits.  G5 (one bit narrow) and G6 (double size) in particular are
  shape-sensitive by construction, and nothing here says what either does at
  `IXW = 11`.
- **No row measures the codebook's AREA claim.**  `c094867`'s case is 99
  RAMB36 against 135, i.e. a synthesis result, and this is a simulation
  harness.  G6 doubles the table and is invisible to every row in the table
  BECAUSE the cost is in tiles.  A `rom_style` or `NCB` regression would land
  silently.
- **The `struct` column's blindness is established for THIS structure only.**
  It says the structural gate does not see a wrong gain; it says nothing
  about what the structural gate is worth against the faults it was written
  for.
- **G1R was run for G1 only.**  The re-pinning argument is general and was
  measured once; the other five landmark kills were not re-pinned.
- **The oracle checks `R_XN` seams of ONE token (`--tok 0`).**  A fault that
  only appears at token 1 or later -- a reload that does not restart, say --
  is outside its reach here; `sim/mutate_rmswire.sh`'s R9 is the row that
  covers that property, on the loader rather than on the codebook.
- **Nothing in this table is a gate row.**  `sim/mutate_gain.sh` is run by
  hand, like every other `sim/mutate_*.sh`.  It is registered in
  `sim/mutation_harness_audit.tsv` as SELFTEETH so
  `sim/check_mutation_harness.py` will notice if it loses its Z0.
