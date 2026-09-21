# 2026-09-21 -- the per-row codebook is reverted, and build 11b was built at `CB_STYLE=regs`, which accounts for every number attributed to the revert's subject

TRACK CBREVERT. No hardware. No Vivado started. GHDL (mcode) only.
Workstation, branch `fpga`, HEAD `c189722` at the start and `166a32d` by the
end (one foreign commit landed mid-track and touched none of this track's
files).

---

## 1. The question, verbatim

> **Oren has chosen build 12 = revert the per-row codebook + FAST_POP +
> SWEEP_PIPE + SCORE_EARLY, with the OOC controls run first.** TRACK CBRUN is
> running those controls on the BC-250 now. **Your job is to stage the revert
> so build 12 can launch the moment CBRUN confirms -- and to be ready to
> abandon it if CBRUN refutes the mechanism.**
>
> [...] **`rtl/matvec_core.vhd` is YOURS.** [...] **CBANCHOR's nine
> re-anchored rows are the hard part** [...] **If CBRUN reports that `bcast`
> does NOT restore the inference, stop and say so.**

---

## 2. The answer, up front

**Two answers, and the second one was not asked for.**

**(a) The revert is staged, exact, and green.** `rtl/matvec_core.vhd` is
restored to `0b34200^` byte for byte (md5 `b616c7822f93154b08200f9418489012`,
which is the file build 10 and build 9 were built from), the nine mutation
rows CBANCHOR re-anchored onto the per-row form are back on their pre-change
anchors and are **verdict-preserving over 20 rows x 9 columns against the
pre-CBANCHOR harness on the same tree**, two rows whose subject the revert
DELETES are retired under their own names, and eleven gate rows pass with
`FAIL 0` and every `PASS n` non-zero.

**(b) AND THE REASON EVERYONE HAS FOR REVERTING IS CONFOUNDED. BUILD 11b WAS
SYNTHESISED AT `CB_STYLE=regs`; BUILDS 9 AND 10 WERE SYNTHESISED AT
`distributed`.** MEASURED, from the three builds' own logs:

| build | `^FK33_CB_STYLE` sentinel | `Parameter CB_STYLE bound to` | outcome |
|---|---|---|---|
| 9 (`card_kvreg_2026-09-20`, shipping) | **1**, `distributed` | **4 x `distributed`** | routed WNS **+0.061** |
| 10 (`build10`, FAILED timing) | **1**, `distributed` | **4 x `distributed`** | legal route, WNS **-5.819** |
| **11b** (`build11b`, FAILED to route) | **0** | **4 x `regs`** | 146,948 nets in conflict |

At `CB_STYLE=regs` the RTL computes `CB_LANES_PER_COPY = CB_ROWS_PER_COPY *
BLK = 32` and `CB_COPIES = 48`, and `cb` carries no `ram_style`. At
`distributed` it computes `CB_LANES_PER_COPY = 1` and `CB_COPIES = 1,536`.
**So `0b34200` -- the commit under discussion -- is the IDENTITY in build 11b**,
because `CB_RANKS = min(CB_COPIES, ROWS_IF) = min(48,48) = 48 = CB_COPIES` and
`cb_rank_of(c) = (c*48)/48 = c`. `sim/ooc_cbooc.tcl` already refuses to draw
its A/B at `regs` for exactly this reason, in its own words: *"BOTH ARMS ARE
THE SAME NETLIST and the experiment measures nothing while printing two full
result rows."*

**And `regs` predicts every "exact" fingerprint that was attributed to
`0b34200`:**

| fingerprint, build 10 -> 11b | attributed to `0b34200` by | what `distributed -> regs` predicts |
|---|---|---|
| `MUXF8 +12,288` | PLACEDIFF, CBRAM, `166a32d` | 1,536 lanes x 8 bits of 16:1 read mux = **12,288** |
| `MUXF7 +24,600` | same | 1,536 x 16 = **24,576** |
| `RAMD32 -21,528` | same | 1,536 `RAM32M16` x 14 = **21,528** |
| `RAMS32 -3,080` | same | 1,536 x 2 = **3,072** |
| `cbw_v` control sets `1,536 -> 48` | CBRAM's headline | `CB_COPIES` **1,536 -> 48** |
| `cb` storage `LUTRAM -> 48 x 128 FF` | CBRAM | 48 copies x 16 x 8 = **6,144 FF** |
| `[Synth 8-5859] cb_reg` fires -> absent | CBRAM's gate | no `ram_style = distributed` is requested at all |

**Every one.** The read at `rtl/matvec_core.vhd:1002` is
`cb((rr*BLK + j) / CB_LANES_PER_COPY)(idx)` with `idx` dynamic, so at `regs`
each of the 1,536 lanes builds its own 16:1 eight-bit mux out of registers;
`166a32d`'s routing evidence -- 38 of the 40 named contending nets being
`core/cb[][][]` into `core/tr_reg[...]_i_NN` -- is that mux tree, and it is
what `regs` builds whether or not `0b34200` is applied.

**What this does and does not overturn.** It does NOT show `0b34200` is
harmless; it shows that **no measurement exists that attributes anything to
it**, because no build has ever drawn it at `distributed`. It does NOT make
build 11b's failure mysterious: the mux tree is real, Vivado named it, and it
is `regs`. And it does NOT make the revert wrong -- see section 6.

---

## 3. The procedure, in the order it was run, and what each step isolates

1. **`git log --oneline 0b34200^..HEAD -- rtl/matvec_core.vhd`** -- isolates
   whether a revert can be a checkout. **One commit**, so it can.
2. **`git checkout 0b34200^ -- rtl/matvec_core.vhd`**, then
   **`git show 0b34200 -- rtl/matvec_core.vhd | git apply --check -`** --
   isolates *exactness*. A clean forward apply proves the working file is
   `0b34200`'s pre-image byte for byte, which an md5 comparison against a
   remembered value does not (it proves agreement with a memory).
3. **Anchor census on the reverted tree** -- isolates whether the pre-change
   anchors are unique, and whether CBANCHOR's `@P_CB@` scopes are still doing
   work. Counted in the whole file AND inside `P_CB`.
4. **Re-anchor, with `count == 1` asserted per edit before it is applied** --
   isolates a silently-zero-match edit, which is the failure mode this whole
   harness class exists to catch.
5. **The reverse of CBANCHOR's verdict-preserving control**: the
   **pre-CBANCHOR harness** (`9cdf13b`) run against **the reverted tree**, and
   the **new harness** run against **the same tree**, diffed column for
   column. This is the only step that can distinguish "my anchors matched"
   from "my anchors mean what the old ones meant".
6. **Three teeth tests on the machinery CBANCHOR added and this track kept** --
   the ledger, the scope, and mode P. A check never shown to fail has not been
   shown to work, and all three had to be re-shown on the reverted tree rather
   than inherited.
7. **Eleven gate rows**, md5 window at both ends.
8. **Build-12 launch reconstruction from the RUN's OWN recorded parameters**
   (`systemctl --user show fastpop-build.service`) rather than from what the
   build was for. **This is the step that found (b)**, and it found it by
   accident: the unit's `Environment=` line carries `BUILD_ROOT` and
   `FK33_CARD=1` and nothing else, and `FK33_CB_STYLE` had to be somewhere.
9. **Three independent instruments on the `CB_STYLE` question**, because one
   absent sentinel is a null result: the `^FK33_CB_STYLE` sentinel, the
   `Parameter CB_STYLE bound to` lines Vivado prints while elaborating
   `matvec_core` itself, and the RTL's own `LEVER C ACTIVE` announcement. The
   third is a **null instrument** and is reported as one in section 5.

---

## 4. The evidence, as raw output

### 4.1 The revert is exact

```
$ git log --oneline 0b34200^..HEAD -- rtl/matvec_core.vhd
0b34200 A: the codebook command net had 1,536 sinks; replicate it per ROW, not per copy

$ git checkout 0b34200^ -- rtl/matvec_core.vhd
$ md5sum rtl/matvec_core.vhd
b616c7822f93154b08200f9418489012  rtl/matvec_core.vhd      <- build 10's file
$ git diff HEAD -- rtl/matvec_core.vhd | grep -c '^@@'
4
$ git show 0b34200 -- rtl/matvec_core.vhd | grep -c '^@@'
4
$ git show 0b34200 -- rtl/matvec_core.vhd | git apply --check - && echo CLEAN
CLEAN
```

`b616c782` is the md5 CBRAM recorded for `b71a6d9:rtl/matvec_core.vhd`, which
is the file build 10 synthesised. Nothing committed since `0b34200` touched
the file, so nothing was discarded.

### 4.2 The anchor census on the reverted tree

```
K2b/K2c/K3a/K3b/K3c write block (3 lines)    whole_file=1  in_P_CB=1
K3d/K7a/K7b write line (1 line)              whole_file=1  in_P_CB=1
K2a cb_we gate                               whole_file=1  in_P_CB=1
K2a rst comment                              whole_file=1  in_P_CB=1
decl cbw_v CB_COPIES                         whole_file=1  in_P_CB=0
loop header "for c in 0 to CB_COPIES-1 loop" whole_file=2  in_P_CB=1
CB_RANKS present at all                      whole_file=0  in_P_CB=0
CHK_CB_RANKS decl                            whole_file=0  in_P_CB=0
```

Two readings, and both matter. **Every restored anchor is unique in the whole
file, so CBANCHOR's scopes change no verdict today** -- they are insurance, and
they were kept on that basis rather than because they were load-bearing.
**But the bare loop header matches TWICE** (`P_CB` and `P_CB_MODEL`), so the
hazard CBANCHOR wrote them for is one careless anchor away, and the scope
teeth test in 4.5 uses exactly that string.

**CB_RANKS count 0 is the fact that decides class K10's disposition.**

### 4.3 The verdict-preserving control, in reverse

Same tree (reverted, `b616c782`), same environment, two harness versions:

```
NEW harness (this track)          CBSTYLE=distributed MODES="A N S"  rc=0
  kill ratio: 16 KILLED + 0 ABORTED = 16 of 20;  4 SURVIVED
  survivors: K1b K3d K8a K8b
  P_CB_MODEL earned: K2b K2c
  === every anchor matched; no row was skipped ===

OLD harness (9cdf13b, pre-CBANCHOR), same tree, same env        rc=0
  kill ratio: 16 KILLED + 0 ABORTED = 16 of 20;  4 SURVIVED
  survivors: K1b K3d K8a K8b
  P_CB_MODEL earned: K2b K2c

$ diff -u v_old.txt v_new.txt        # 20 verdict lines, 9 columns each
<no output>                          # IDENTICAL
```

Repeated at `CBSTYLE=regs` (the harness default): also **IDENTICAL**, 20 rows.
So the restoration is verdict-preserving at both geometries, which is the
mirror of CBANCHOR's own nine-row twenty-seven-column control.

The tallies also *add up* -- `16 + 0 + 4 = 20 of 20` -- which is the arithmetic
CBANCHOR built the ledger to make visible.

### 4.4 Eleven gate rows

md5 identical at both ends of the window (`06:47:11` and `06:58:58`):
`rtl/matvec_core.vhd` `b616c782...`, `sim/regress.sh`
`91f5619ad8796867bf6e23c077906992` (never edited), `sim/tb_matvec_core.vhd`
`5522a105...`, `tb_matvec_cb_contract` `be5fc1e8...`, `tb_matvec_cb_lockstep`
`877fb15b...`.

```
--only tb_matvec_cb    OVERALL PASS 2  FAIL 0  NOVERDICT 0  TIMEOUT 0  BUILD-ERROR 0  NOCHECK 0  SKIPPED 0
--only tb_matvec_core  OVERALL PASS 2  FAIL 0  ...
--only tb_matvec_int4  OVERALL PASS 2  FAIL 0  ...
--only tb_matvec_axi   OVERALL PASS 1  FAIL 0  ...
--only runguard        OVERALL PASS 1  FAIL 0  ...
--only cardtop         OVERALL PASS 3  FAIL 0  ...
--only graygate        OVERALL PASS 1  FAIL 0  ...
--only seamgate        OVERALL PASS 6  FAIL 0  ...
```

The first four reproduce `5dc3ee5`'s and CBANCHOR's figures (2 / 2 / 2 / 1)
exactly, which is the control that the revert changed no value. Every `PASS n`
is non-zero: `--only` takes a SUBSTRING and a pattern matching nothing still
prints `REGRESSION: PASS` with `PASS 0`.

### 4.5 Teeth, three ways, on the machinery that was KEPT

| test | what it attacks | result |
|---|---|---|
| **T1 ledger** | K7b's anchor broken to match 0 times | `rc=1`, `K7b ANCHOR FAILED -- tested nothing`, `=== ROWS THAT DID NOT RUN:1 ===`, and `15 of 20` so the tallies deliberately do not add up |
| **T2a scope, unscoped** | a genuinely ambiguous anchor (`for c in 0 to CB_COPIES-1 loop`, count 2) with no scope | `rc=1`, `ANCHOR 0 MATCHED 2 TIMES, expected 1` |
| **T2b scope, scoped** | the same anchor as `@P_CB@...` | `rc=0`, the row runs |
| **T2c scope, bad name** | `@P_NOSUCH@...` | `rc=1`, `ANCHOR 0 NAMES UNKNOWN SCOPE P_NOSUCH` |
| **T3 mode P** | `MODES="A P"` on the reverted tree | `rc=1`, `NEUTER: CHK_CB_RANKS declaration matched 0 times`, row in the ledger |

T3 is why the mode-P branch was **kept rather than deleted**. CBANCHOR's own
recorded trap is that *"an unknown mode is not an error, it is mode A"* -- it
lost a run to exactly that. Deleting the branch would make `MODES="A P S"`
silently print a plausible third column; keeping it makes that column fail
loudly.

### 4.6 `CB_STYLE`, the three instruments

```
$ systemctl --user show fastpop-build.service -p ExecStart -p MemoryHigh -p MemoryMax \
                                              -p WorkingDirectory -p Environment
ExecStart={ argv[]=/usr/bin/bash -c hw/fk33/pcieep_build.sh > /mnt/storage/fk33_builds/build11b/build.stdout 2>&1 ;
            start_time=[Sun 2026-09-20 19:00:30 MDT] ; status=1 }
MemoryHigh=25769803776          # 24 GiB
MemoryMax=27917287424           # 26 GiB
Environment=BUILD_ROOT=/mnt/storage/fk33_builds/build11b/root FK33_CARD=1
WorkingDirectory=/mnt/storage/fk33_builds/wt11

$ grep -n 'FK33_CB_STYLE' hw/fk33/pcieep_build.sh
                         (no output -- the script does not set it)
$ sed -n 601p hw/fk33/gen_pcieep.py
ENG_CB_STYLE   = os.environ.get("FK33_CB_STYLE", "regs")
```

Instrument 1, the line-anchored sentinel `gen_pcieep.py` emits:

```
build 9  (card_kvreg_2026-09-20/build.stdout)   grep -c '^FK33_CB_STYLE'  1   distributed
build 10 (/mnt/storage/fk33_builds/build10/...)                          1   distributed
build 11b                                                               0
```

Instrument 2, Vivado's own generic binding, which is a fact about the netlist
rather than about the flow:

```
build 9    Parameter CB_STYLE bound to: distributed   x4
build 10   Parameter CB_STYLE bound to: distributed   x4   (regs x0)
build 11b  Parameter CB_STYLE bound to: regs          x4

build11b/build.stdout:6788  Parameter CB_STYLE bound to: regs - type: string
build11b/build.stdout:6789  INFO: [Synth 8-256] done synthesizing module 'matvec_core'
                            [/mnt/storage/fk33_builds/wt11/rtl/matvec_core.vhd:120]
```

The last two lines are adjacent: `matvec_core` **itself** was elaborated at
`regs` in build 11b.

Instrument 3, the RTL's own announcement, **which measured nothing** -- see
section 6.

### 4.7 The arithmetic, DERIVED from the RTL

```
rtl/matvec_core.vhd (reverted and at HEAD, identical in this function):
  function cb_lpc_f(style; rpc, blk_g) return positive is
    if style = "distributed" then return 1; else return rpc * blk_g; end if;
  :258  CB_LANES_PER_COPY := cb_lpc_f(CB_STYLE, CB_ROWS_PER_COPY, BLK)
  :260  CB_COPIES         := (ROWS_IF*BLK + CB_LANES_PER_COPY - 1) / CB_LANES_PER_COPY
  :1002 ... cb((rr*BLK + j) / CB_LANES_PER_COPY)(idx) ...      idx is DYNAMIC

  distributed : LPC = 1  -> CB_COPIES = 48*32     = 1,536
  regs        : LPC = 32 -> CB_COPIES = 48*32/32  =    48

  At regs, 0b34200 gives CB_RANKS = min(48,48) = 48 = CB_COPIES,
  so cb_rank_of(c) = (c*48)/48 = c : THE IDENTITY.
```

---

## 5. Measured and REJECTED -- do not retry

- **"The revert reopens build 10's 1,536-sink fanout failure."** REJECTED by
  CBRAM against build 9 and not re-derived here. Restated because it is the
  claim most likely to be re-invented from build 10's worst-path list.
- **Re-anchoring class K10 onto the reverted tree.** IMPOSSIBLE, MEASURED:
  `CB_RANKS`, `cb_rank_of`, `cb_ranks_f`, `cb_rank_chk_f` and `CHK_CB_RANKS`
  all have grep count **0** in `rtl/matvec_core.vhd` after the revert. K10a and
  K10b mutate a constant declaration that no longer exists. **RETIRE is the
  only honest disposition** and it is the disposition no amount of anchor
  repair substitutes for. Both rows are kept commented out with their anchors
  verbatim, because CBANCHOR measured them green and they are a working pair
  waiting for their RTL, not a draft.
- **Deleting the mode-P branch along with the rows it served.** REJECTED by T3:
  with the branch present, `MODES="A P"` exits 1 and names the missing pin.
  Without it, P becomes a silent duplicate of mode A. CBANCHOR lost a labelled
  run to that exact behaviour.
- **The RTL's `LEVER C ACTIVE` report as a `CB_STYLE` instrument.** MEASURED:
  `grep -c 'LEVER C ACTIVE'` is **0** in builds 9, 10 AND 11b. Vivado does not
  surface a `severity note`. So it discriminates nothing, in either direction,
  and a reader reaching for it gets a null that looks like evidence of `regs`
  in all three builds -- including the two that were `distributed`.
- **Reading `Environment=` as the whole environment.** It is what was passed
  with `--setenv`; a variable exported in the launching shell would not appear
  there. That is why instrument 2 exists and why it, not the unit definition,
  is the evidence. Build 11b's `regs` is established by Vivado's generic
  binding, not by the absence of a `--setenv`.
- **The three "exact" fits as attribution for `0b34200`.** `MUXF8 = 1,536 x 8`,
  `MUXF7 = 1,536 x 16` and `RAMD32 = 1,536 x 14` are exactly what
  `distributed -> regs` produces, and `CB_STYLE` differs between the two builds
  compared. **An exact numeric fit identifies the SHAPE of a change, never its
  CAUSE, when two candidate causes make the same shape.**

---

## 6. Measurement traps hit, including mine

1. **I nearly wrote the build-12 launch command with `FK33_CB_STYLE`
   omitted, because the unit definition omits it.** Copying a recorded
   invocation is the right instinct and it would have reproduced build 11b's
   defect exactly. What saved it was asking where the sentinel in build 9's log
   came from, which is a question about a variable rather than about a command.
2. **THE WHOLE FILE ABOVE IS THE CLAUDE.md ENTRY "ENUMERATE WHAT DIFFERS
   BETWEEN TWO RUNS FROM THE RUNS' OWN RECORDED PARAMETERS, NEVER FROM THE
   INTENT OF WHOEVER LAUNCHED THEM", FIRING AGAIN, TWO WEEKS AFTER IT WAS
   WRITTEN.** `166a32d` had already found and recorded TWO uncontrolled
   variables between build 10 and build 11b (`FAST_POP`, and five changed RTL
   files) and explicitly refused to call `+44,073 LUT` the codebook's cost.
   **`CB_STYLE` is a third, it is the one that makes `0b34200` a no-op, and
   both builds print it on a line of their own.** Three tracks read these two
   logs and none of them grepped for the parameter whose name is in the lever's
   own title. **The reason is instructive: everyone was looking for what the
   change DID, and `CB_STYLE` is a statement about whether the change was
   PRESENT.**
3. **My own line-anchoring failure, caught by my own scan.** The K10
   retirement banner I wrote contained the literal words a reader greps for to
   find dead rows, so `grep -c 'ANCHOR FAILED'` on a perfectly green run
   returned 1. This is the recorded self-match trap in a fourth place -- after
   `pgrep -f`, a `/proc` loop matching the script searching it, and a log
   holding the Tcl that wrote it. Fixed **in the message rather than in the
   grep**: the narrative no longer spells the strings, so the haystack cannot
   hold the needle. The anchored scan
   `^K[0-9]+[a-z]? +(ANCHOR FAILED|NEUTER FAILED|DID NOT ANALYZE)` returns 0
   on all four runs and 1 on T1.
4. **`git worktree list` told me HEAD had moved; `git rev-parse` at the start
   of the session had not.** A foreign commit (`166a32d`) landed mid-track. It
   touched none of this track's files (verified per path, not by reading the
   diffstat), and it carries evidence that CORROBORATES the mux tree and is
   itself confounded by finding (b).
5. **CBRAM's `8-5859` differential is a good measurement of a real difference
   and a bad measurement of its cause, and it said so.** Its own "open, not
   determined" item 2 reads *"whether `[Synth 8-5859]` is the only gate ... that
   it is sufficient is an inference from two runs"*. The two runs differ in
   `CB_STYLE`. **The file's honesty about what it had not established is what
   makes it correctable rather than wrong.**

---

## 7. What was restored, and what was preserved

**Restored to the pre-`0b34200` form:**

- `rtl/matvec_core.vhd` in full, byte for byte (4 hunks reversed, nothing else).
- The nine mutation rows' ANCHORS: `K2a` `K2b` `K2c` `K3a` `K3b` `K3c` `K3d`
  `K7a` `K7b`. `K2b` and `K3c` go from two anchors each back to **one**, which
  is the loop split CBANCHOR identified, undone.
- `K3d`'s description wording (`rank 0's` -> `replica 0's`), which is why the
  verdict lines in 4.3 are byte-identical rather than merely equivalent.

**Preserved from CBANCHOR, deliberately, because it is orthogonal to the RTL
form:**

- The `@P_CB@` **scope** machinery and every body anchor's use of it.
- The `DEAD_TAGS` **ledger** and the nonzero exit.
- The per-process **neuter** with its assert census (`EXPECT`), and the
  `CHK_CB_RANKS` branch, now as a loud-failure guard (T3).
- The **corrected `K2b`/`K2c` legends**. CBANCHOR measured both as KILLED on
  the OLD tree as well as the new one, so the correction is a property of
  `P_CB_MODEL`'s existence and not of `0b34200`; it survives the revert
  unchanged, and 4.3 confirms it (`P_CB_MODEL earned: K2b K2c`).
- Every class note, with dated CORRECTION paragraphs appended rather than
  deletions.

**Retired, not re-anchored:** `K10a`, `K10b`, and mode `P` in practice.

---

## 8. Open, not determined

1. **`0b34200`'s actual cost is still UNKNOWN, and no build has ever measured
   it.** Builds 9 and 10 predate it; build 11b drew it at `regs` where it is
   the identity. **TRACK CBRUN's OOC A/B at `CB_STYLE=distributed` is now the
   only instrument that can attribute it at all**, and it should continue for
   that reason rather than as a confirmation step.
2. **Whether build 12 should run at `distributed` or at `regs` is a DECISION,
   not a finding.** `distributed` is what shipped (build 9, +0.061) and what
   `docs/WORKLOG.md` and CLAUDE.md record as the card's configuration. `regs`
   is what build 11b accidentally built and it does not route. This track did
   not evaluate the third possibility, that `regs` would route with some other
   composition.
3. **The syntactic-vs-semantic question CBRAM left open is untouched**, and its
   `fan` / `bcast` arms remain the way to settle it.
4. **`SWEEP_PIPE` and `SCORE_EARLY` have never been in a card build.**
   `166a32d` MEASURED zero occurrences of either in `wt11`'s `llama_top.vhd`
   and `fk33_llama_top.vhd`, and this track MEASURED both present at HEAD
   (`rtl/llama_top.vhd:6997`, `rtl/fk33_llama_top.vhd:7621`). So build 12
   from HEAD carries RTL that no `FK33_CARD=1` synthesis has drawn, which is
   precisely what `docs/WORKLOG.md:68` says not to do. **Whether an OOC draw
   of `attn_block` at `SWEEP_PIPE=true SCORE_EARLY=true` exists was not
   established here.**
5. **`FAST_POP=true` HAS been in a card build** -- build 11b -- and is not
   implicated by anything in this file.
6. **Nothing here is a silicon measurement, and no Vivado was started.** The
   card was live and serving throughout and was not touched. The workstation
   Vivado lane held a CBOOC draw (`/proc/1473886/cwd` =
   `.../cbooc_descaxi_main/run_20260921_065042_1471846/out_old`, 5.86 GB
   VmRSS) and the BC-250 lane held CBRUN; neither was disturbed.
7. **Whether committing the revert breaks a FUTURE `sim/ooc_cbooc_run.sh`
   prepare: YES, loudly, and it is not fixed here.** That script asserts
   `sha256(0b34200:matvec_core.vhd) == sha256(HEAD:matvec_core.vhd)` and dies
   with instructions if not. Both live runs are safe -- MEASURED, their arm
   trees are materialised on disk and their `MANIFEST.txt` sha256s match git
   (`sha256_old=ef401b6f...`, `sha256_new=974734a7...`, both `repo_head=
   c189722`) -- but the next prepare will abort. The file belongs to
   CBOOC/CBRUN and was not edited.
