# Mutation coverage for subsystem A's descriptor gatekeeper

**Date:** 2026-08-29
**Track:** DESC-MUT
**Unit under test:** `rtl/matvec_int4_desc_axi.vhd` (1,012 lines), unchanged by
this work
**Tools:** GHDL 1.0.0 mcode (`ghdl-mcode`), `--std=08 -frelaxed`; no hardware
was touched at any point

---

## 1. The question, verbatim

> **Mutation coverage for `rtl/matvec_int4_desc_axi.vhd`** [...]
>
> **Aim at the accept/refuse boundary specifically.** The interesting mutations
> are the ones that make it accept something it should refuse, because that
> class is what reaches silicon: a refused job is loud and an accepted-but-wrong
> job is silent. For each error code, ask whether any bench can distinguish
> "refused for the right reason" from "refused for a different reason" [...]
>
> Specifically: which mutations make it ACCEPT something it should refuse, and
> whether any bench catches them.

---

## 2. The answer, up front

**Of the 36 mutations that WEAKEN a check -- that make the gatekeeper ADMIT
something the unmutated design refuses -- 34 are killed by the new case suite
through the existing `sim/tb_mv4i_desc_image.vhd`, and the other 2 are stopped
by a VHDL range check rather than by any checker.** No weakening mutation gets
through silently, but the two `ABORT:LANG` rows are the honest qualification:
a declared integer range is a bit width in synthesis, not a check, so those two
are caught by the SIMULATOR and would not be caught on the card.

The measured table, at the FK33 geometry the card will carry
(`ROWS_IF = 48`, `AXI_DW = 256`, `NPORTS_W/S = 24/3`, `ADDR_W = 40`):

| judge | KILLED | ABORT | SURVIVED | of |
|---|---|---|---|---|
| `tb_mv4i_desc_image` + 57 cases, **branch IMG only** | **68** | 3 | **4** | 75 |
| the same, counting the RUN and GEN rows it cannot reach | 68 | 3 | 11 | 82 |
| `tb_matvec_fk33_desc`, unmodified, as a second judge | 60 | 5 | 17 | 82 |
| **killed by at least one judge** | **73** | 5 | **4** | 82 |

The four that survive everything are `K5` (an equivalent mutant -- proved
unable to change behaviour, section 10), `R1` (`EC_CORE`, below), and `N1`/`N2`
(behind generics nothing sets). Every one is named with its reason; none is a
row that was quietly dropped.

**Both judges are deterministic.** The second judge was run twice, two hours
apart, under different machine load, and the 82 verdicts were byte-identical.

Three findings are worth acting on, and **none of them is a defect in the
RTL**; all three are holes in what was being checked:

1. **`S_ERR` stickiness was verified by nothing.** The file's own comment calls
   it load-bearing -- "a design that could be re-armed by another GO would let a
   driver that ignores STATUS keep running descriptors past a rejected one" --
   and mutation `E2`, which adds a re-arm, survived all 56 cases of the first
   suite AND all 22 cases of `sim/tb_matvec_fk33_desc.vhd`, which still does not
   catch it. **Closed here**, with teeth (section 5.2). The observable is not a
   status bit; it is a second descriptor AR burst.
2. **"Refused" was never separated from "refused and NOT done".** Mutation
   `E3`, which sets `done_l` alongside `err`, survived the image bench. A driver
   polling `done or err` would then read results the design never computed.
   **Closed here.**
3. **`EC_CORE` (0xE) is unreachable in every bench in the tree.** Mutation `R1`
   removes the `core_err -> EC_CORE` path and survives BOTH judges. Nothing
   makes `matvec_int4` assert `err`, so the one error code that reports a
   failure of the array itself has zero coverage. **Not closed** -- it needs a
   stimulus no bench in the closure produces.

On the reporting question: **"refused for the right reason" is distinguishable
for 6 of the 9 error codes and NOT for 3 of them.** `EC_DESC` (0x3) is raised
at nine different sites and two pairs of them are indistinguishable even with
`ERR_INFO` pinned; `EC_GEOM` cannot say whether it was `NPORTS_W` or `NPORTS_S`;
and `EC_SHAPE` cannot say which of its three clauses fired. Full table in
section 6.

---

## 3. The procedure, in the order it was run

Each step names what it isolates. The measuring instrument is the **case
suite**, not the mutation list: a mutation is only observable through a case
whose expected verdict it moves, so the cases were built first and their teeth
established before any mutation was applied.

1. **Read the RTL, not the spec.** Enumerated every refusal site in
   `S_IDLE`, `S_R`, `S_CHECK`, `S_SHAPE_C` and the `bchk` process, with the
   `(err_code, ERR_INFO)` pair each one produces. Isolates: what the suite has
   to cover. This is where the two indistinguishable `EC_DESC` pairs were
   found, before any simulation.
2. **Build the case suite from the COMMITTED image** (`sim/mv4i_desc_cases.py`,
   57 cases), one edit away from bytes already known to be accepted.
   Deliberately NOT from `tools/gen_mv4i_desc.py`: that generator is the thing
   `tb_mv4i_desc_image` exists to judge, and using it to produce the cases that
   judge the judge would make the two agree by construction (the project's `m7`
   mutant is the recorded case for that error).
   Isolates: the accept/refuse boundary, one legal extreme and one illegal
   neighbour at a time.
3. **Establish the baseline.** All 57 cases must PASS on the unmutated design.
   Isolates: a case that cannot pass is measuring nothing, and a case that
   passes for the wrong reason is worse. THREE separate baseline failures were
   seen before it went clean and every one of them was the harness's fault,
   not the design's (section 8). Each presented as "the design does not
   elaborate".
4. **Extend the bench only where a check did not exist**
   (`EXPECT_EADDR`, `DSLV_DEAD`, `DSLV_STALL`, `POLL_MAX`), each one added
   because a specific mutation had no case that could see it.
   Isolates: the write-time `ERR_ADDR` latch, `EC_WDOG`, and the difference
   between a watchdog REMOVED and a watchdog made SMALLER.
5. **Run 82 mutations x 57 cases through
   `sim/mutverdict.py`**, three verdicts, never two.
   Isolates: a checker that noticed (KILLED) from a run that never reached a
   verdict (ABORT), which is the distinction that makes a kill ratio readable.
6. **Run the SAME 82 mutations through a second judge**,
   `sim/tb_matvec_fk33_desc.vhd`, unmodified.
   Isolates: the branch the image bench structurally cannot reach. Its 27
   weight and scale slaves never assert `arready`, so **no job in that harness
   ever completes** and everything from `S_WAIT` onward is elaborated and never
   run.
7. **Close the survivors that are closable, and demonstrate the teeth.**
   Re-ran each closed row and recorded the kill.
8. **Full unfiltered `sim/regress.sh`.**

### 3.1 Branch tags, and why the table is unreadable without them

| tag | meaning | rows |
|---|---|---|
| `IMG` | reached by `tb_mv4i_desc_image` at the FK33 geometry | 75 |
| `RUN` | `S_WAIT` onward: elaborated, NEVER reached by that bench | 5 |
| `GEN` | behind `USE_XEXP_PORT` / `DUAL_CLK`, NOT elaborated here | 2 |

Reported as one number, the image harness reads **68 of 82 = 83%**. Split, it
is **68 of 75 = 91% on the rows it can reach**, and all seven `RUN`/`GEN` rows
survive it by construction, measuring the harness rather than the design. That
is exactly the distortion the brief warned about, and it is 8 percentage points
wide here.

---

## 4. The evidence

### 4.1 Baseline, MEASURED

```
== rtl/matvec_int4_desc_axi.vhd mutation table ==
   judge      sim/tb_mv4i_desc_image.vhd, FK33 geometry
   cases      57 (sim/mv4i_desc_cases.py)
   classifier sim/mutverdict.py, three verdicts

baseline: all 57 cases pass on the unmutated design
```

### 4.2 The mutation table, judge = `tb_mv4i_desc_image` + 57 cases

MEASURED, `bash sim/mutate_mv4i_desc.sh <scratch> -j 8`. "NAMING CASE" is the
first case that killed it and, in brackets, how many of the 57 killed it. **The
bracket is the interesting number**: a row killed by 1 case of 57 is a
knife-edge check that exactly one case can see, and a row killed by 57 of 57 is
a mutation that broke everything and says nothing about resolution. Eleven rows
here are killed by exactly one case, and each of those cases is the only thing
standing between that check and silence.

```
NAME  BRANCH VERDICT   NAMING CASE              NOTE
----- ------ --------  ------------------------ ----
P1    IMG    KILLED    P_ADDR (2/57)            weaken: the DESC_PTR range check removed entirely
P2    IMG    KILLED    P_ALIGN_HALF (2/57)      weaken: the DESC_PTR alignment check removed entirely
P3    IMG    KILLED    P_ALIGN_HALF (2/57)      weaken: DESC_ALIGN halved, so a half-aligned pointer passes
P4    IMG    KILLED    P_ADDR (2/57)            the DESC_PTR range check reads the LOW half, not the high
X1    IMG    KILLED    R_MAGIC_AND_OP (2/57)    weaken: the extension MAGIC is not checked
X2    IMG    KILLED    A_COLS1BLK (50/57)       the MAGIC is read from the WRONG half of its word
X3    IMG    KILLED    R_VER (1/57)             weaken: the extension VERSION is not checked
X4    IMG    KILLED    A_COLS1BLK (50/57)       the VERSION field is read one bit high
X5    IMG    KILLED    R_EXTFLAGS (1/57)        weaken: the extension's reserved ext_flags are not checked
X6    IMG    SURVIVED  -                        the extension is decoded at word EXT0-1 throughout
H1    IMG    KILLED    R_GEOM_NPW (1/57)        weaken: NPORTS_W is not checked against the descriptor
H2    IMG    KILLED    R_GEOM_NPS (1/57)        weaken: NPORTS_S is not checked against the descriptor
H3    IMG    KILLED    R_OPCODE (1/57)          weaken: the opcode is not checked, so any D job runs as an A job
H4    IMG    KILLED    R_W3PAD (1/57)           weaken: word 3's reserved pad is not checked
H5    IMG    KILLED    R_W7PAD (1/57)           weaken: word 7, D's reserved word, is not checked
H6    IMG    KILLED    R_EXT3PAD (2/57)         weaken: the extension's own pad words are not checked
H7    IMG    KILLED    R_EXT3PAD (1/57)         weaken: only the FIRST of the two extension pads is checked
H8    IMG    KILLED    R_OUTMODE3 (1/57)        weaken: out_mode 3 is admitted (the bound moved by one)
H9    IMG    KILLED    A_COLS1BLK (44/57)       the opcode is read from the wrong byte of word 0
S1    IMG    KILLED    R_ROWS0 (1/57)           weaken: n_rows = 0 is admitted
S2    IMG    KILLED    R_ROWSOVER_AND_BASE (1/57) weaken: the n_rows ceiling is one too high
S3    IMG    KILLED    A_ROWSMAX (2/57)         tighten: the n_rows ceiling excludes MAXROWS_BFP itself
S4    IMG    KILLED    R_COLS0 (1/57)           weaken: n_cols = 0 is admitted
S5    IMG    ABORT     R_COLSOVER=ABORT:LANG    weaken: the n_cols ceiling is one too high
S6    IMG    KILLED    A_COLS1BLK (15/57)       n_rows and n_cols are read from each other's half
S7    IMG    KILLED    R_SBEATS0 (2/57)         weaken: a zero w_beats or s_beats is admitted
B1    IMG    KILLED    R_BASE_ADDR_HI (10/57)   weaken: the base array's verdict is ignored entirely
B2    IMG    KILLED    R_BASE_ADDR_HI (4/57)    weaken: bases are not range checked
B3    IMG    KILLED    R_BASE_ALIGN_1 (6/57)    weaken: bases are not alignment checked
B4    IMG    KILLED    R_BASE_ALIGN_2K (1/57)   weaken: base alignment is checked to 2 KB, not 4 KB
B5    IMG    KILLED    R_BASE_ALIGN_2K (5/57)   weaken: base alignment is checked to 256 bytes
B6    IMG    KILLED    P_ADDR (4/57)            weaken: a base bit exactly AT ADDR_W is admitted
B7    IMG    KILLED    R_BASE_ALIGN_SLAST (1/57) weaken: the LAST base is never checked
B8    IMG    KILLED    R_BASE_ADDR_HI (6/57)    weaken: the FIRST base is never checked
B9    IMG    KILLED    R_BASE_ADDR_S0 (2/57)    weaken: only the WEIGHT bases are checked, not the scales
B10   IMG    KILLED    R_BASE_ADDR_HI (4/57)    ERR_INFO names the port, not the descriptor word
B11   IMG    KILLED    R_BASE_ADDR_HI (4/57)    EC_ADDR and EC_ALIGN are swapped on the base array
B12   IMG    KILLED    R_BASE_ORDER (1/57)      the base checker LAST match wins instead of the first
G1    IMG    KILLED    A_RAGGED (1/57)          the tile accumulator steps by ROWS_IF + 1
G2    IMG    KILLED    A_COLSMAX (14/57)        the block accumulator steps by BLK * 2
G3    IMG    KILLED    A_ROWSEXACT (1/57)       the loop exits one step late on the ROW dimension
G4    IMG    KILLED    A_COLS1BLK (20/57)       the loop exits one step late on the COLUMN dimension
G5    IMG    KILLED    A_COLS1BLK (15/57)       the loop exits when EITHER dimension is covered
G6    IMG    KILLED    A_ROWSEXACT (1/57)       the row accumulator keeps running past its dimension
G7    IMG    KILLED    A_COLS1BLK (3/57)        the column accumulator keeps running past its dimension
G8    IMG    KILLED    A_COLS1BLK (15/57)       the one multiply is off by one tile-row
C1    IMG    KILLED    R_SHAPE_TOP (4/57)       weaken: w_beats is no longer required to equal tiles*nblk
C2    IMG    KILLED    R_WB_HIGH (2/57)         weaken: the w_beats equality becomes a lower bound only
C3    IMG    KILLED    R_SB_LOW (1/57)          weaken: the s_beats LOWER bound is dropped (starvation)
C4    IMG    KILLED    R_SB_HIGH (1/57)         weaken: the s_beats UPPER bound is dropped (over-read)
C5    IMG    KILLED    A_COLS1BLK (15/57)       the s_beats bracket loses its -1, so the exact value is refused
C6    IMG    KILLED    A_COLS1BLK (15/57)       GRP is one too large, so every legal s_beats is refused
C7    IMG    KILLED    R_SB_HIGH (6/57)         S_SHAPE_C is skipped: the shape gate never renders a verdict
F1    IMG    KILLED    A_COLS1BLK (34/57)       the fetch stops one beat early, so the tail is stale
F2    IMG    KILLED    A_COLS1BLK (50/57)       the beat-to-word index is off by one word
F3    IMG    ABORT     W_DEAD=ABORT:LANG        weaken: the descriptor fetch watchdog never fires
F4    IMG    KILLED    A_STALL_WDOG (1/57)      the watchdog fires at a sixteenth of its limit
F5    IMG    ABORT     A_COLS1BLK=ABORT:LANG    the word-capture bound admits one word past the array
K1    IMG    KILLED    R_CBNEVER (1/57)         weaken: a job may reuse a codebook that was never loaded
K2    IMG    KILLED    A_COLS1BLK (21/57)       the cb_load flag is read one bit low
K3    IMG    SURVIVED  -                        the codebook load stops one entry short
K4    IMG    SURVIVED  -                        the codebook's high half is loaded from the low word
K5    IMG    SURVIVED  -                        cb_valid is set even when nothing was loaded
W1    IMG    KILLED    A_COLS1BLK (57/57)       GO is taken from the wrong CTRL bit
W2    IMG    KILLED    P_ADDR (1/57)            weaken: the WRITE-TIME ERR_ADDR check is one bit too loose
W3    IMG    KILLED    P_ADDR (2/57)            weaken: the WRITE-TIME ERR_ADDR check is removed
W4    IMG    KILLED    A_COLS1BLK (57/57)       GO is not captured into the sticky bit
W5    IMG    KILLED    A_COLS1BLK (57/57)       STATUS reports err and busy in each other's bit
W6    IMG    KILLED    P_ADDR (40/57)           ERR_INFO is reported from the wrong register
W7    IMG    KILLED    P_ADDR (42/57)           err_code is reported shifted by one bit
W8    IMG    KILLED    A_COLS1BLK (57/57)       DESC_WORDS reports one word too many
W9    IMG    KILLED    A_COLS1BLK (57/57)       CAPS reports NPORTS_W and NPORTS_S swapped
E1    IMG    KILLED    A_COLS1BLK (15/57)       `start` is never pulsed: no descriptor can ever run
E2    IMG    KILLED    R_BASE_ADDR_HI (37/57)   S_ERR is no longer sticky: another GO re-arms the design
E3    IMG    KILLED    R_MAGIC_AND_OP (2/57)    a refused descriptor also reports DONE
R1    RUN    SURVIVED  -                        the core's own error is not turned into EC_CORE
R2    RUN    SURVIVED  -                        the result tile counter never advances
R3    RUN    SURVIVED  -                        the Y_IDX quotient loop stops one subtraction early
R4    RUN    SURVIVED  -                        Y_LO / Y_HI answer without waiting for the divide
R5    RUN    SURVIVED  -                        the busy->done transition never happens
N1    GEN    SURVIVED  -                        USE_XEXP_PORT takes x_exp from the descriptor either way
N2    GEN    SURVIVED  -                        the descriptor read master is given the CORE clock as m_aclk

TOTAL 82 mutations, 57 cases: 68 KILLED, 3 ABORT, 11 SURVIVED
BRANCH IMG ONLY (75 rows): 68 KILLED, 3 ABORT, 4 SURVIVED
```

### 4.3 The same 82 mutations, judge = `tb_matvec_fk33_desc` (unmodified)

MEASURED, `bash sim/mutate_mv4i_desc_run.sh <scratch> -j 5`, 75 s per row.

```
NAME  BRANCH VERDICT   NOTE
----- ------ --------  ----
BASE  -      PASS      unmutated baseline
P1    IMG    KILLED    weaken: the DESC_PTR range check removed entirely
P2    IMG    KILLED    weaken: the DESC_PTR alignment check removed entirely
P3    IMG    PASS      weaken: DESC_ALIGN halved, so a half-aligned pointer passes
P4    IMG    KILLED    the DESC_PTR range check reads the LOW half, not the high
X1    IMG    KILLED    weaken: the extension MAGIC is not checked
X2    IMG    KILLED    the MAGIC is read from the WRONG half of its word
X3    IMG    KILLED    weaken: the extension VERSION is not checked
X4    IMG    KILLED    the VERSION field is read one bit high
X5    IMG    KILLED    weaken: the extension's reserved ext_flags are not checked
X6    IMG    KILLED    the extension is decoded at word EXT0-1 throughout
H1    IMG    KILLED    weaken: NPORTS_W is not checked against the descriptor
H2    IMG    KILLED    weaken: NPORTS_S is not checked against the descriptor
H3    IMG    KILLED    weaken: the opcode is not checked, so any D job runs as an A job
H4    IMG    KILLED    weaken: word 3's reserved pad is not checked
H5    IMG    KILLED    weaken: word 7, D's reserved word, is not checked
H6    IMG    KILLED    weaken: the extension's own pad words are not checked
H7    IMG    PASS      weaken: only the FIRST of the two extension pads is checked
H8    IMG    KILLED    weaken: out_mode 3 is admitted (the bound moved by one)
H9    IMG    KILLED    the opcode is read from the wrong byte of word 0
S1    IMG    KILLED    weaken: n_rows = 0 is admitted
S2    IMG    PASS      weaken: the n_rows ceiling is one too high
S3    IMG    KILLED    tighten: the n_rows ceiling excludes MAXROWS_BFP itself
S4    IMG    PASS      weaken: n_cols = 0 is admitted
S5    IMG    ABORT:LANG weaken: the n_cols ceiling is one too high
S6    IMG    KILLED    n_rows and n_cols are read from each other's half
S7    IMG    KILLED    weaken: a zero w_beats or s_beats is admitted
B1    IMG    KILLED    weaken: the base array's verdict is ignored entirely
B2    IMG    KILLED    weaken: bases are not range checked
B3    IMG    KILLED    weaken: bases are not alignment checked
B4    IMG    PASS      weaken: base alignment is checked to 2 KB, not 4 KB
B5    IMG    PASS      weaken: base alignment is checked to 256 bytes
B6    IMG    KILLED    weaken: a base bit exactly AT ADDR_W is admitted
B7    IMG    PASS      weaken: the LAST base is never checked
B8    IMG    PASS      weaken: the FIRST base is never checked
B9    IMG    KILLED    weaken: only the WEIGHT bases are checked, not the scales
B10   IMG    PASS      ERR_INFO names the port, not the descriptor word
B11   IMG    KILLED    EC_ADDR and EC_ALIGN are swapped on the base array
B12   IMG    PASS      the base checker LAST match wins instead of the first
G1    IMG    KILLED    the tile accumulator steps by ROWS_IF + 1
G2    IMG    KILLED    the block accumulator steps by BLK * 2
G3    IMG    KILLED    the loop exits one step late on the ROW dimension
G4    IMG    KILLED    the loop exits one step late on the COLUMN dimension
G5    IMG    KILLED    the loop exits when EITHER dimension is covered
G6    IMG    KILLED    the row accumulator keeps running past its dimension
G7    IMG    KILLED    the column accumulator keeps running past its dimension
G8    IMG    KILLED    the one multiply is off by one tile-row
C1    IMG    KILLED    weaken: w_beats is no longer required to equal tiles*nblk
C2    IMG    KILLED    weaken: the w_beats equality becomes a lower bound only
C3    IMG    KILLED    weaken: the s_beats LOWER bound is dropped (starvation)
C4    IMG    KILLED    weaken: the s_beats UPPER bound is dropped (over-read)
C5    IMG    KILLED    the s_beats bracket loses its -1, so the exact value is refused
C6    IMG    KILLED    GRP is one too large, so every legal s_beats is refused
C7    IMG    KILLED    S_SHAPE_C is skipped: the shape gate never renders a verdict
F1    IMG    KILLED    the fetch stops one beat early, so the tail is stale
F2    IMG    KILLED    the beat-to-word index is off by one word
F3    IMG    ABORT:LANG weaken: the descriptor fetch watchdog never fires
F4    IMG    PASS      the watchdog fires at a sixteenth of its limit
F5    IMG    ABORT:LANG the word-capture bound admits one word past the array
K1    IMG    KILLED    weaken: a job may reuse a codebook that was never loaded
K2    IMG    KILLED    the cb_load flag is read one bit low
K3    IMG    KILLED    the codebook load stops one entry short
K4    IMG    KILLED    the codebook's high half is loaded from the low word
K5    IMG    PASS      cb_valid is set even when nothing was loaded
W1    IMG    KILLED    GO is taken from the wrong CTRL bit
W2    IMG    KILLED    weaken: the WRITE-TIME ERR_ADDR check is one bit too loose
W3    IMG    KILLED    weaken: the WRITE-TIME ERR_ADDR check is removed
W4    IMG    KILLED    GO is not captured into the sticky bit
W5    IMG    KILLED    STATUS reports err and busy in each other's bit
W6    IMG    PASS      ERR_INFO is reported from the wrong register
W7    IMG    KILLED    err_code is reported shifted by one bit
W8    IMG    KILLED    DESC_WORDS reports one word too many
W9    IMG    KILLED    CAPS reports NPORTS_W and NPORTS_S swapped
E1    IMG    KILLED    `start` is never pulsed: no descriptor can ever run
E2    IMG    PASS      S_ERR is no longer sticky: another GO re-arms the design
E3    IMG    KILLED    a refused descriptor also reports DONE
R1    RUN    PASS      the core's own error is not turned into EC_CORE
R2    RUN    ABORT:DUTASSERT(matvec_int4_desc_axi.vhd) the result tile counter never advances
R3    RUN    ABORT:LANG the Y_IDX quotient loop stops one subtraction early
R4    RUN    KILLED    Y_LO / Y_HI answer without waiting for the divide
R5    RUN    KILLED    the busy->done transition never happens
N1    GEN    PASS      USE_XEXP_PORT takes x_exp from the descriptor either way
N2    GEN    PASS      the descriptor read master is given the CORE clock as m_aclk

TOTAL 82 mutations: 60 KILLED, 5 ABORT, 17 SURVIVED
```

### 4.4 What each judge sees that the other does not

**Killed by the image bench, NOT by `tb_matvec_fk33_desc` (13):**

| mutation | branch | fk33 verdict | what it breaks |
|---|---|---|---|
| `P3` | IMG | PASS | weaken: DESC_ALIGN halved, so a half-aligned pointer passes |
| `H7` | IMG | PASS | weaken: only the FIRST of the two extension pads is checked |
| `S2` | IMG | PASS | weaken: the n_rows ceiling is one too high |
| `S4` | IMG | PASS | weaken: n_cols = 0 is admitted |
| `B4` | IMG | PASS | weaken: base alignment is checked to 2 KB, not 4 KB |
| `B5` | IMG | PASS | weaken: base alignment is checked to 256 bytes |
| `B7` | IMG | PASS | weaken: the LAST base is never checked |
| `B8` | IMG | PASS | weaken: the FIRST base is never checked |
| `B10` | IMG | PASS | ERR_INFO names the port, not the descriptor word |
| `B12` | IMG | PASS | the base checker LAST match wins instead of the first |
| `F4` | IMG | PASS | the watchdog fires at a sixteenth of its limit |
| `W6` | IMG | PASS | ERR_INFO is reported from the wrong register |
| `E2` | IMG | PASS | S_ERR is no longer sticky: another GO re-arms the design |

**Killed by `tb_matvec_fk33_desc`, NOT by the image bench (5):**

| mutation | branch | image verdict | what it breaks |
|---|---|---|---|
| `X6` | IMG | SURVIVED | the extension is decoded at word EXT0-1 throughout |
| `K3` | IMG | SURVIVED | the codebook load stops one entry short |
| `K4` | IMG | SURVIVED | the codebook's high half is loaded from the low word |
| `R4` | RUN | SURVIVED | Y_LO / Y_HI answer without waiting for the divide |
| `R5` | RUN | SURVIVED | the busy->done transition never happens |

**Killed by NEITHER (9):**

| mutation | branch | image | fk33 | what it breaks |
|---|---|---|---|---|
| `S5` | IMG | ABORT | ABORT:LANG | weaken: the n_cols ceiling is one too high |
| `F3` | IMG | ABORT | ABORT:LANG | weaken: the descriptor fetch watchdog never fires |
| `F5` | IMG | ABORT | ABORT:LANG | the word-capture bound admits one word past the array |
| `K5` | IMG | SURVIVED | PASS | cb_valid is set even when nothing was loaded |
| `R1` | RUN | SURVIVED | PASS | the core's own error is not turned into EC_CORE |
| `R2` | RUN | SURVIVED | ABORT:DUTASSERT(matvec_int4_desc_axi.vhd) | the result tile counter never advances |
| `R3` | RUN | SURVIVED | ABORT:LANG | the Y_IDX quotient loop stops one subtraction early |
| `N1` | GEN | SURVIVED | PASS | USE_XEXP_PORT takes x_exp from the descriptor either way |
| `N2` | GEN | SURVIVED | PASS | the descriptor read master is given the CORE clock as m_aclk |

---

## 5. The accept/refuse boundary, which is the question that was asked

### 5.1 Every weakening mutation, and what caught it

A "weakening" mutation is one that makes the gatekeeper ADMIT something the
unmutated design REFUSES. That is the class that reaches silicon quietly, and
it is the reason the table is weighted this way: 36 of the 82 rows are in it.

Read the last column too. **Thirteen mutations are killed by the image bench
and NOT by `sim/tb_matvec_fk33_desc.vhd`, and eight of those thirteen are
weakenings**: `P3`, `H7`, `S2`, `S4`, `B4`, `B5`, `B7`, `B8`. That bench was
the only coverage this file had before today. Every base-array weakening
except `B1`, `B2`, `B3`, `B6` and `B9` walks straight past it, because it
BUILDS its descriptors in VHDL and therefore never builds a badly-aligned or
out-of-range base -- the exact shape of blindness that a bench which is also
the generator of its own stimulus always has.

| mutation | what it now ADMITS | image bench | fk33 bench |
|---|---|---|---|
| `P1` | the DESC_PTR range check removed entirely | KILLED by P_ADDR | KILLED |
| `P2` | the DESC_PTR alignment check removed entirely | KILLED by P_ALIGN_HALF | KILLED |
| `P3` | DESC_ALIGN halved, so a half-aligned pointer passes | KILLED by P_ALIGN_HALF | PASS |
| `X1` | the extension MAGIC is not checked | KILLED by R_MAGIC_AND_OP | KILLED |
| `X3` | the extension VERSION is not checked | KILLED by R_VER | KILLED |
| `X5` | the extension's reserved ext_flags are not checked | KILLED by R_EXTFLAGS | KILLED |
| `H1` | NPORTS_W is not checked against the descriptor | KILLED by R_GEOM_NPW | KILLED |
| `H2` | NPORTS_S is not checked against the descriptor | KILLED by R_GEOM_NPS | KILLED |
| `H3` | the opcode is not checked, so any D job runs as an A job | KILLED by R_OPCODE | KILLED |
| `H4` | word 3's reserved pad is not checked | KILLED by R_W3PAD | KILLED |
| `H5` | word 7, D's reserved word, is not checked | KILLED by R_W7PAD | KILLED |
| `H6` | the extension's own pad words are not checked | KILLED by R_EXT3PAD | KILLED |
| `H7` | only the FIRST of the two extension pads is checked | KILLED by R_EXT3PAD | PASS |
| `H8` | out_mode 3 is admitted (the bound moved by one) | KILLED by R_OUTMODE3 | KILLED |
| `S1` | n_rows = 0 is admitted | KILLED by R_ROWS0 | KILLED |
| `S2` | the n_rows ceiling is one too high | KILLED by R_ROWSOVER_AND_BASE | PASS |
| `S4` | n_cols = 0 is admitted | KILLED by R_COLS0 | PASS |
| `S5` | the n_cols ceiling is one too high | ABORT | ABORT:LANG |
| `S7` | a zero w_beats or s_beats is admitted | KILLED by R_SBEATS0 | KILLED |
| `B1` | the base array's verdict is ignored entirely | KILLED by R_BASE_ADDR_HI | KILLED |
| `B2` | bases are not range checked | KILLED by R_BASE_ADDR_HI | KILLED |
| `B3` | bases are not alignment checked | KILLED by R_BASE_ALIGN_1 | KILLED |
| `B4` | base alignment is checked to 2 KB, not 4 KB | KILLED by R_BASE_ALIGN_2K | PASS |
| `B5` | base alignment is checked to 256 bytes | KILLED by R_BASE_ALIGN_2K | PASS |
| `B6` | a base bit exactly AT ADDR_W is admitted | KILLED by P_ADDR | KILLED |
| `B7` | the LAST base is never checked | KILLED by R_BASE_ALIGN_SLAST | PASS |
| `B8` | the FIRST base is never checked | KILLED by R_BASE_ADDR_HI | PASS |
| `B9` | only the WEIGHT bases are checked, not the scales | KILLED by R_BASE_ADDR_S0 | KILLED |
| `C1` | w_beats is no longer required to equal tiles*nblk | KILLED by R_SHAPE_TOP | KILLED |
| `C2` | the w_beats equality becomes a lower bound only | KILLED by R_WB_HIGH | KILLED |
| `C3` | the s_beats LOWER bound is dropped (starvation) | KILLED by R_SB_LOW | KILLED |
| `C4` | the s_beats UPPER bound is dropped (over-read) | KILLED by R_SB_HIGH | KILLED |
| `F3` | the descriptor fetch watchdog never fires | ABORT | ABORT:LANG |
| `K1` | a job may reuse a codebook that was never loaded | KILLED by R_CBNEVER | KILLED |
| `W2` | the WRITE-TIME ERR_ADDR check is one bit too loose | KILLED by P_ADDR | KILLED |
| `W3` | the WRITE-TIME ERR_ADDR check is removed | KILLED by P_ADDR | KILLED |

**36 weakening mutations, 34 killed by the image bench's own checker.**

**The two that are not are `S5` and `F3`, and both are `ABORT:LANG`.** They are
stopped by a declared integer range, not by a check:

* `S5` admits `n_cols = MAXCOLS + 1`, so `sh_nb` reaches 545 against its
  declared `0 to NBMAX` = 544 and the simulator aborts.
* `F3` removes the fetch watchdog's terminating comparison, so `wdog`
  increments past its declared `0 to WDOG_LIMIT` and the simulator aborts.

**Neither mechanism exists in synthesis.** A range declaration becomes a bit
width; 545 fits in the 10 bits `0 to 544` needs, and `wdog` simply wraps. So on
the card `S5` would compute a wrong `sh_prod` (most likely still refusing, with
a misleading `EC_SHAPE`) and `F3` would hang the fetch forever. They are
counted as ABORT and not as kills because **nothing in either bench noticed**;
the simulator did.

### 5.2 The two that were NOT caught, and now are

Both were found by this work, both are holes in the CHECKING and not defects in
the RTL, and both are now closed inside `sim/tb_mv4i_desc_image.vhd`.

#### `E2` -- `S_ERR` is no longer sticky

The mutation adds one line to the terminal state:

```vhdl
          when S_ERR =>
            busy  <= '0';
            err_l <= '1';
            if go_p = '1' then go_p <= '0'; st <= S_IDLE; end if;   -- E2
```

That is exactly the behaviour the file's own comment on `S_ERR` says must not
exist. It survived all 56 cases of the first suite AND all 22 cases of
`sim/tb_matvec_fk33_desc.vhd`.

**Why every status bit is blind to it.** `err`, `err_code` and `err_info` are
cleared by nothing but reset, so a re-armed design carries the old error
forward and reads identically over AXI-Lite. `busy` does go high again, but
only for the handful of cycles the re-run takes, which no polling loop is
guaranteed to sample. **The observable is on the AXI READ CHANNEL, not in the
register map: a re-armed design FETCHES THE DESCRIPTOR AGAIN.** The bench now
counts `d_arvalid and d_arready` handshakes and asserts the count does not move.

**One GO is not enough, and this cost a measurement.** The first probe wrote
`CTRL.GO` once and E2 still came back SURVIVED. `go_p` is a sticky capture bit
that `S_IDLE` CONSUMES; the re-armed design consumes it on the way OUT of
`S_ERR`, lands in `S_IDLE` with `go_p` already clear, and sits there. The
re-arm has happened and nothing observable has. Two GOs make it run:

```
sim/tb_mv4i_desc_image.vhd:445:7:@4265ns:(assertion failure): S_ERR IS NOT
STICKY: a second GO after err_code 10 re-fetched the descriptor (1 -> 2 AR
handshakes)
```

#### `E3` -- a refused descriptor also reports DONE

```vhdl
                err_code <= EC_MAGIC; done_l <= '1';                 -- E3
```

A driver polling `done or err` -- the pattern the register map's own header
recommends over polling `done` alone -- would then read a result the design
never computed. The bench now asserts `STATUS bit 0 = 0` in the same status
word that first showed `err`, so it is that instant and not a later one.

#### `F4` -- the watchdog fires at a sixteenth of its limit

Not a weakening; a tightening, and it is the one the first suite could not see
because `W_DEAD` (a slave that never answers) kills a watchdog that has been
REMOVED and a watchdog that has been made SMALLER alike. Separating them needs
a LEGAL stall longer than the shrunken limit: `A_STALL_WDOG` stalls the
descriptor slave 10,000 cycles, which is inside `WDOG_LIMIT` = 65,536 and
outside `WDOG_LIMIT/16` = 4,096.

MEASURED after the case was added: `F4 IMG KILLED A_STALL_WDOG (1/57)` -- one
case out of 57, which is what a knife-edge resolution case looks like.

---

## 6. "Refused at all" against "refused for the right reason"

Per error code, MEASURED by running one case per site with `EXPECT_INFO`
pinned. A pair marked NOT distinguishable was confirmed by two cases that both
pass with the same pinned `(code, info)`.

| err_code | raised at | ERR_INFO values | "which check" recoverable? |
|---|---|---|---|
| `EC_DESC` 0x3 | **9 sites** in `S_CHECK` | 0, 1, 3, 7, 35, 36, 37 | **PARTLY** -- see below |
| `EC_WDOG` 0x4 | 1 site (`S_R`) | 0xFFFF | yes |
| `EC_GEOM` 0x9 | 1 site, **2 clauses** | 3 | **NO** -- `NPORTS_W` and `NPORTS_S` are indistinguishable |
| `EC_MAGIC` 0xA | 1 site | 35 | yes |
| `EC_VER` 0xB | 1 site | 35 | yes |
| `EC_ALIGN` 0xC | 2 sites (pointer, base array) | 0xFFFF / 8..34 | yes, and it names WHICH base |
| `EC_ADDR` 0xD | 2 sites (pointer, base array) | 0xFFFF / 8..34 | yes, and it names WHICH base |
| `EC_CORE` 0xE | 1 site (`S_WAIT`) | 0xFFFF | yes in principle; **never exercised by any bench** |
| `EC_SHAPE` 0xF | 1 site, **3 clauses** | 36 | **NO** -- w_beats, s_beats-low and s_beats-high are indistinguishable |

**6 of the 9 codes are fully attributable. 3 are not.**

The `EC_DESC` collisions, each MEASURED as two cases that both pass with the
same pinned `(code, info)`:

| pair | pinned as | cases |
|---|---|---|
| opcode != OP_A_JOB **vs** codebook never loaded | (3, 0) | `R_OPCODE`, `R_CBNEVER` |
| word 3's reserved pad **vs** out_mode > 2 | (3, 3) | `R_W3PAD`, `R_OUTMODE3` |
| n_rows = 0 / over **vs** n_cols = 0 / over | (3, 1) | `R_ROWS0`, `R_ROWSOVER`, `R_COLS0`, `R_COLSOVER` |
| w_beats = 0 **vs** s_beats = 0 | (3, 36) | `R_WBEATS0`, `R_SBEATS0` |
| x_exp pad **vs** the last extension word | (3, 37) | `R_XEXPPAD`, `R_EXT3PAD` |

The first two are the ones that matter, because they are collisions between
DIFFERENT CHECKS rather than between clauses of one check: a driver that gets
`(3, 0)` cannot tell whether it sent a non-A opcode or forgot the codebook, and
those have different fixes.

**This is not fixable by renumbering.** `EC_SHAPE = 0xF` took the last value in
the 4-bit field (worklog OI-9), and `ERR_INFO` is a WORD INDEX by construction,
so two checks on the same word cannot be separated without either widening
`err_code` or giving `ERR_INFO` a sub-word field. Recorded, not fixed: it is a
register-map decision, not a repair.

---

## 7. Measured and REJECTED -- do not retry

Each of these was tried, measured, and abandoned. The numbers are why.

**Do not "fix" the `err_code 0x<decimal>` print in
`sim/tb_mv4i_desc_image.vhd` on its own.** The RESULT line is
`"...err_code 0x" & integer'image(verdict)`, so `EC_SHAPE` = 15 prints as
`0x15`, which reads as 21. It is genuinely misleading and it was NOT changed,
because `tools/verify_mv4i_desc.py` parses that line with

```python
RESULT_RE = re.compile(r"RESULT (accept|reject: err_code 0x(\d+) err_info (\d+)"
                       r"|timeout)")
```

`(\d+)` matches the DECIMAL digits after the literal `0x`, and
`int(m.group(2))` then reads them as decimal -- so the tool is correct only
BECAUSE the print is wrong. Printing real hex breaks every code from 0xA up;
dropping the `0x` breaks the regex outright. The two have to move together and
`tools/` is not this track's to edit. Instead a second, unambiguous line was
ADDED (`tb_mv4i_desc_image: PASS -- verdict 15 info 36 err_addr 0`) and the
original left byte-identical.

**A single `CTRL.GO` write is NOT a probe for `S_ERR` stickiness.** MEASURED:
mutation `E2` survives it, because `go_p` is consumed on the way out of
`S_ERR`. Two GOs are required. Anyone re-deriving this check will write one GO
first; do not.

**`-gDESC_ADDR_HI=2147483648` does not express "bit 63 set".** A VHDL `natural`
tops out at 2**31-1 and ghdl refuses the override during elaboration, which the
classifier honestly reports as `ABORT:ELAB` and which reads exactly like a
broken design. Use `1 << 30`; it is still far above `ADDR_W` = 40.

**Do not pass the mutation NOTE through `xargs -I{}`.** MEASURED: two notes in
`sim/mv4i_desc_mutations.py` contain backticks (E1's "`start` is never
pulsed"), the substituted text is evaluated as shell, and the run printed
`runmut.sh: line 1: start: command not found` while silently truncating that
row's note. Only the NAME crosses the boundary now; branch and note are looked
up inside the runner.

**Do not assume `sim/mutverdict.py` recognises a bench's PASS line.** Its
`pass_re` is `<entity>\s*:?\s*PASS`. `tb_mv4i_desc_image` printed
`PASS: descriptor image judged as expected (-1)` with no entity prefix, so a
clean run classified as `ABORT:NOVERDICT` -- a survivor reported as a crash.
`tb_matvec_fk33_desc` prints `N cases run, 0 failures` and has no PASS token at
all. Check the spelling against the actual log before trusting a single row.

**A new `sim/tb_mv4i_desc_run.vhd` for the RUN branch was NOT written.**
`sim/tb_matvec_fk33_desc.vhd` already completes jobs bit-exactly and, used
unmodified as a second judge, kills `X6`, `K3`, `K4`, `R4`, `R5` and `E3`. A
new bench would have duplicated that, become an auto-discovered gate row, and
moved `BASELINE_PASS` for coverage that already exists. Cost of the existing
judge, MEASURED: 75 s for ONE run of it against about 40 s for a whole 57-case
sweep of the image bench at `-j 8`, and it needs the packed tensor that is not
in git -- which is why it is a separate script, not a column.

---

## 8. Measurement traps hit, including my own

**My own, in the order they bit.**

1. **`ghdl -r` run from the wrong directory reads as a broken design.** The
   bench opens `-gDESC` as a RELATIVE path. The first harness ran ghdl from the
   scratch root, every case died with `cannot open file "A_GOLDEN.hex"`, and
   the classifier -- correctly -- reported `ABORT:ELAB` on all 56. The failure
   presents as "the design does not elaborate", which is about as far from the
   truth as a diagnosis can get. The runner now `cd`s into the case directory.

2. **A classifier invoked by a path that does not resolve produces EMPTY
   verdicts, not errors.** The first runner resolved `mutverdict.py` relative
   to the run directory. python3 wrote `can't find '__main__' module` to
   STDERR, the command substitution captured STDOUT which was empty, and the
   baseline gate read 56 blank verdicts as "not clean". The two streams never
   met. Pass the classifier by absolute path.

3. **A scratch log was CLOBBERED mid-run by a concurrent writer.** The first
   82-row table was written to `<scratchpad>/full.log`; partway through, a
   `sim/regress.sh` FULL run belonging to another track truncated that same
   path and wrote its own header over the first 40 rows. My process kept
   writing at its own file offset, so the result looked like a table that
   started at row 41. **Nothing was lost only because the harness also writes
   one TSV per mutation**, and the table was reconstructed from those. Write
   harness output INSIDE its own scratch directory, not next to it.

4. **`--only` is a SUBSTRING.** `--only E` runs E1, E2 and E3; `--only R_`
   matches nothing at all and still prints a clean `TOTAL 0 mutations`. Same
   trap as `sim/regress.sh --only`; the only tell is the count.

5. **A `tail -4` hid the assertion that proved the check worked.** The
   `(assertion failure)` line with the diagnostic text is printed BEFORE
   ghdl-mcode's own three-line epilogue, so a short tail shows only
   `error: assertion failed` with no message and reads as a checker that fired
   without saying why. This is the same shape as the trap TRACK A-MUT recorded:
   reading ghdl's epilogue instead of the bench's diagnostics.

6. **Machine contention.** The 82 x 57 matrix at `-j 10` ran alongside another
   track's full gate. Wall times in this document are therefore upper bounds
   and should not be used for budgeting.

**Traps in the unit under test that a future measurement will hit.**

7. **A mutation whose line is not on the harness's path is not a survivor, it
   is unmeasured.** Seven of the 14 first-run survivors were `RUN` or `GEN`
   rows. Reported untagged, the harness would have claimed 79% where the honest
   figure for the rows it can reach is higher and the figure for the rows it
   cannot is zero.

8. **Some kills come from VHDL, not from the checker.** `S5` (n_cols ceiling
   one too high) and `F5` (word-capture bound one too far) are stopped by
   `sh_nb` and `dw`'s declared ranges, and `F3` (watchdog removed) by the same
   mechanism further down. Those are `ABORT:LANG`, counted apart from kills,
   and **they do not exist in synthesis** -- the range declaration becomes a
   bit width, not a check. A design that relies on them is relying on
   simulation.

---

## 9. What subsystem A still has no coverage of

This section replaces the corresponding row of
`docs/debugging/2026-08-29_subsystem-a-mutations.md` section 7, which listed
`rtl/matvec_int4_desc_axi.vhd` as having **NO** mutation script.

| unit | dedicated bench | mutation script |
|---|---|---|
| `rtl/matvec_core.vhd` | `sim/tb_matvec_core.vhd` | YES (TRACK A-MUT) |
| `rtl/weight_streamer.vhd` | `sim/tb_weight_streamer.vhd` | YES (TRACK A-MUT) |
| `rtl/mv4i_arith_pkg.vhd` | `sim/tb_mv4i_arith` + vectors | partial, judged only through `tb_matvec_core` |
| **`rtl/matvec_int4_desc_axi.vhd`** | `sim/tb_mv4i_desc_image.vhd` + `sim/tb_matvec_fk33_desc.vhd` | **YES, THIS TRACK** -- `sim/mutate_mv4i_desc.sh` (82 x 57) and `sim/mutate_mv4i_desc_run.sh` (82, second judge) |
| `rtl/matvec_int4.vhd` | `sim/tb_matvec_int4.vhd` | **NO** |
| `rtl/axi_rd_port.vhd` | `sim/tb_axi_rd_port.vhd` | **NO** |
| `rtl/axi_rd_fsm.vhd` | `sim/tb_axi_rd_fsm.vhd` | YES (TRACK CDC-BENCH, `sim/mutate_axi_rd_fsm.sh`) |
| `rtl/async_fifo.vhd` | `sim/tb_async_fifo.vhd` | YES (TRACK CDC-BENCH, `sim/mutate_async_fifo.sh`) |

**The two that are left are `rtl/matvec_int4.vhd` and `rtl/axi_rd_port.vhd`.**
`matvec_int4` is the wrapper the descriptor plane instantiates, so this track
exercised it heavily and mutated none of it; `axi_rd_port` is the only path by
which any descriptor word or weight beat arrives, and it now has two mutated
neighbours on either side of it and none of its own.

---

## 10. NOT verified

Stated so the next track does not have to infer it.

- **`EC_CORE` (0xE) is produced by no bench.** Mutation `R1` deletes the
  `core_err -> EC_CORE` transition and survives BOTH judges. Nothing in the
  closure makes `matvec_int4` assert `err`, so the whole `S_WAIT` error path is
  untested. This is the largest single hole left in this file.
- **The `GEN` branch is not elaborated anywhere in the gate.**
  `USE_XEXP_PORT = true` appears in NO bench and in no `.tcl` (the FK33 shell
  sets it `false`), and `DUAL_CLK = true` is reachable only through
  `sim/tb_matvec_fk33_desc -gDUAL=true`, which `sim/regress.sh` deliberately
  does not run as a gate row. Mutations `N1` and `N2` therefore survive by
  construction, and the CDC in the DESCRIPTOR path -- the one whose absence was
  MEASURED to break 17 of 22 cases before `axi_rd_port` was adopted -- is not
  covered by any automatic run.
- **The result readback path is covered only by the slow judge.** `R2`, `R3`
  and `R4` are reached only through `sim/tb_matvec_fk33_desc.vhd`, which needs
  a 4.7 GiB model set that is not in git. On a machine without it, the Y_IDX
  divider, the tile counter and the `Y_LO`/`Y_HI` stall have no coverage at all.
- **`K5` is an EQUIVALENT MUTANT, not a coverage hole.** Setting `cb_valid`'s
  declared initial value to `'1'` cannot change behaviour, because the control
  process assigns `cb_valid <= '0'` in its reset branch and every bench asserts
  reset first. Named rather than dropped: it is the measured floor below which
  no case can help.
- **`X6`, `K3` and `K4` survive the image bench BY DESIGN.** They move values
  that only arithmetic can see (`w_beats` into the core, the codebook
  contents), and the image bench deliberately has no arithmetic oracle -- its
  27 weight slaves never answer. All three are killed by the second judge. Not
  a hole; a division of labour, now measured rather than assumed.
- **No timing claim.** Nothing here says anything about the Y_IDX critical path
  the file's header documents, or about `DESC_ALIGN`'s interaction with a real
  HBM slave. That needs STA and hardware, and no hardware was touched.
- **The generator is not re-verified.** `sim/mv4i_desc_cases.py` edits the
  COMMITTED image; if `tools/gen_mv4i_desc.py` regressed tomorrow, nothing here
  would move. That remains `tools/verify_mv4i_desc.py`'s claim.
- **`sim/regress.sh` was NOT changed and `BASELINE_PASS` was NOT moved.** Both
  new scripts are `mutate_*.sh`, which the gate does not run, and the one bench
  touched (`sim/tb_mv4i_desc_image.vhd`) keeps its committed default vector and
  its existing single gate row.

---

## 11. The full gate, unfiltered

MEASURED after every change in this track had landed,
`REGRESS_SCRATCH=<scratch> bash sim/regress.sh --jobs 4`, no `--only`.
**These are the LAST `OVERALL` and `REGRESSION` lines of the log, not the
first match.**

```
 suite sim   PASS 68   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 94   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
================================================================================
 baseline: 94 passing, matches the recorded floor of 94
================================================================================
 REGRESSION: PASS
```

`BASELINE_PASS` was 88 when this track started and 94 when it finished; the
six between are other tracks', and this track did not touch `sim/regress.sh`
at all. The two rows that exercise the unit under test:

```
PASS       sim:tb_matvec_fk33_desc               47s  ... subsystem A is bit-exact with ref/matvec_int4
PASS       sim:tb_mv4i_desc_image                 3s  ... PASS: descriptor image judged as expected (-1)
```

`tb_mv4i_desc_image` still runs on its COMMITTED default vector with `EXPECT`
at its default of -1, so the gate row exercises the ACCEPT path and the three
checks added here (`done` clear on refusal, `S_ERR` sticky, `ERR_ADDR`) are
skipped there by construction -- they run in the mutation harness, which is
where the 57 cases live. That is deliberate: the gate row stays a 3-second
smoke test of real generator bytes and does not become a second mutation suite.

---

## 12. Corrections

None yet. Append here rather than editing above.
