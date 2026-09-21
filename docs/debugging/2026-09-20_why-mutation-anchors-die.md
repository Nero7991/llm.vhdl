# Why mutation anchors die, and the two causes you cannot see by reading the anchor

TRACK REANCHOR, 2026-09-20.  Workstation, git `00d92f1` on branch `fpga`.
No hardware, no Vivado.  GHDL (mcode) only.

---

## 1. The question, verbatim

> TRACK MUTAUDIT found 22 rows across six harnesses whose anchors are dead, in
> the SAFE class -- meaning the row VANISHES rather than lying, which is better
> but still means the evidence is not there.  [...] MUTAUDIT deliberately did
> NOT re-anchor them, and its reason is the brief for this track, verbatim:
> *"what each mutation should mean against refactored RTL belongs to its
> owner."*  You are now that owner.  For each of the dead rows: establish what
> the row was FOR; decide between RE-ANCHOR, RETIRE and CANNOT DECIDE; every
> re-anchored row needs its teeth AND its attribution control.  [...] if a
> pattern emerges in WHY anchors die, that is worth more than the 22 fixes.

---

## 2. The answer, up front

**There are 27 dead rows, not 22, and the per-harness attribution in the brief
was wrong in both directions** (MEASURED by anchor replay at `00d92f1`:
`attn_kv_seam` has 4 and not 5; `rmswire` has 4 and not 2; and the two rows the
brief names for `rmswire`, R3 and R9, are both ALIVE).  Disposition: **21
RE-ANCHOR, 6 RETIRE, 0 CANNOT DECIDE.**

**The pattern, and it is the part worth keeping: FIVE of the 27 died with
NOTHING INSIDE THE ANCHOR EDITED.**  Two mechanisms, neither visible from the
anchor, the mutation, or the file the anchor points into:

- **A second, textually identical copy of the block appeared.**
  `rtl/llama_top.vhd`'s `gsr` (the SWG_REAL adapter) is a byte-identical copy
  of `gvr`'s write-back state machine.  At `00d92f1` the two differ **only in
  the comment above them**.  So `if rav_d = '1' then` went from one match to
  two and `uw_addr(NUNIT+vi) <= kw;` likewise, and four rows -- `rmswire` R7
  and R8, `llama_top_kv` N2 and VN2 -- went dead at once. **Uniqueness is a
  property of the FILE, not of the anchor**, and no amount of care in writing
  the anchor buys it.
- **A comment quoting the code inflated a count.**  `9e3348e` added two comment
  lines quoting `vref_r(lay_r*N_KVH + kvh)`, so `mutate_rtl_n`'s required count
  of 3 became a measured 5 and row L1 voided.  The guard fired correctly and
  the guard is the wrong instrument: **a substring count counts comments**, and
  raising the count to 5 would have edited two comments and let a future
  removal of a real site be masked by the addition of another comment.

**The third finding is the one that cost real evidence: an anchor must name
only what the mutation changes.**  `llama_top_kv` N1 mutates `w_exp` and
anchored on `"          w_mant => wsel,    w_exp => NORM_W_EXP,"`.  It has now
been broken **twice, by two different edits to `w_mant`, a port it never
touched** -- `9f690a0` (re-anchored 2026-08-29, in the file, with a comment
explaining the breakage) and then `47c9d9c`.  The 2026-08-29 re-anchor
reproduced the defect it was fixing.

**And one defect of the same class as MUTAUDIT's was found one level down and
is MEASURED in both directions: a PARTIAL mutant reported as a kill.**
`mutate_attn_kv_seam.sh`'s L1 applies its fourth site with `add_mut`, whose rc
was never read.  `add_mut`'s python exits before writing on a bad anchor, so
the file keeps sites 1-3 and the row runs.  With site 4's anchor deliberately
broken, the pre-fix script prints `MUTATION ANCHOR MATCHED 0 TIMES` on stderr
and then `L1  KILLED`.  A three-of-four mutant under the full row's name, with
a green verdict.

---

## 3. The procedure, in the order it was run

1. **Replay every anchor with the row functions stubbed.**  A copy of each
   harness under `/mnt/storage/fk33_builds/scratch/reanchor/replay/`, with
   `run_case`/`run_row`/`run_cap`/`row` given an immediate `return 0`, so only
   the substitutions execute and no `ghdl` runs.  Cost: seconds.  This is
   MUTAUDIT's replay, reused.
2. **Tag the failures.**  The mutator's diagnostic goes to stderr above the row
   and is detached from it, so the replay copy was patched to print
   `DEADANCHOR <tag>` alongside.  Without this the counts are known and the
   rows are not.
3. **Find the breaking commit per anchor** with `git log -S '<anchor text>' --
   <file>`.  The first hit going back is the commit that removed it.
4. **Read the row's LEGEND, not its anchor**, and decide what the mutation
   meant.  Then look for that property in today's RTL.
5. **Check every proposed anchor against BOTH `git show HEAD:` and the working
   tree.**  This is not ceremony: `rtl/llama_top.vhd` is +368 lines dirty from
   a concurrent track (GSRWIDE), and **three anchors that look unique in the
   working tree match TWICE at HEAD**.  An anchor tuned to an uncommitted state
   is dead the moment that state lands differently.
6. **Run the teeth in a `git worktree` at HEAD**, not in the shared checkout,
   so a concurrent track's in-flight edit to `rtl/llama_top.vhd` cannot move
   the design underneath a 13-minute run.
7. **Teeth both ways per row**: the real anchor must KILL (or survive for a
   stated reason), and an impossible anchor must produce the harness's
   anchor-failure row and NOT a verdict.

---

## 4. The evidence, as raw output

### 4.1 The dead-row inventory (MEASURED, anchor replay at `00d92f1`)

```
mutate_llama_top_kv        R6 R7 R7b R8(A) N1 N2 VN2 VR7 VR7b        9
mutate_llama_top_normuram  U1 U2 U3 U4 U6 U6x U6b U6bx U7            9
mutate_attn_kv_seam        R3 R5 R5b L1                              4
mutate_rmswire             R4 R7 R8 R11                              4
mutate_fk33_seam           M9                                        1
                                                                    27
```

The brief (from MUTAUDIT's counts) said `attn_kv_seam` R3 R4 R5 R5b L1 and
`rmswire` R3 R9.  MEASURED: `attn_kv_seam` R4's anchor matches once and the row
runs; `rmswire` R3 and R9 both match and run, and the four that do not are R4,
R7, R8, R11.  MUTAUDIT counted anchor-failure LINES, which is not a count of
rows -- `mutate_rtl2` prints one line per failing half, a row can contribute
two, and a `run_case` that prints its own `ANCHOR FAILED` contributes a third.

### 4.2 The two invisible causes (MEASURED)

```
$ grep -c "                if rav_d = '1' then" rtl/llama_top.vhd      # working tree
3
$ git show HEAD:rtl/llama_top.vhd | grep -c "                if rav_d = '1' then"
2
```

and the two blocks, diffed at HEAD:

```
--- gvr's S_WR                          +++ gsr's S_WR
-              -- THE WRITE-BACK, NOW A TWO-DEEP READ PIPELINE.  TRACK RMSWIRE.
...
+              -- The write-back: the same two-deep read pipeline as `gvr`'s
+              -- S_WR.  `rav_d` and `o_rd` derive from the same cycle's
               when S_WR =>
                 if k < n then
                   o_ra <= std_logic_vector(to_unsigned(k, LOG2N));
```

**Every line of code is identical.  The only discriminator is the comment.**

The comment-inflated count:

```
$ grep -n "vref_r(" rtl/attn_block.vhd
1218:      s := to_integer(e_of(vhdr, opb)) - to_integer(vref_r(lay_r*N_KVH + kvh));
1764:              --     ev := vref_r(lay_r*N_KVH + kvh);        <- COMMENT
1768:              --     vref_r(lay_r*N_KVH + kvh) <= ev;        <- COMMENT
1770:              ev  := vref_r(lay_r*N_KVH + kvh);
1772:              vref_r(lay_r*N_KVH + kvh) <= ev;
2197:                  <= std_logic_vector(vref_r(lay_r*N_KVH + h)
```

```
MUTATION ANCHOR MATCHED 5 TIMES, expected 3
L1 ANCHOR FAILED
```

### 4.3 The partial mutant, in both directions (MEASURED)

The PRE-FIX script, count naively bumped 3 -> 5 and site 4's anchor broken:

```
MUTATION ANCHOR MATCHED 0 TIMES, expected 1
L1  KILLED     -- defect C1 restored: the v_ref fold indexed by KV HEAD ALONE, with no layer term, at all four sites
```

A three-of-four mutant, a green kill, and the only diagnostic on stderr above
the row.  The SAME broken site-4 anchor after this track's fix:

```
MUTATION ANCHOR MATCHED 0 TIMES, expected 1
L1 ANCHOR FAILED (a later site, so the mutant was PARTIAL and was NOT run)
```

`mutate_llama_top_kv.sh`'s R8 had the identical shape (a second `attn_block`
edit applied with an unread rc) and is gated the same way.

### 4.4 `sim/mutate_fk33_seam.sh` M9, teeth both ways (MEASURED)

Control, then the row, then the impossible anchor:

```
M0  SURVIVED   -- ANCHOR: no mutation at all.  Must SURVIVE.
        tb_fk33_seam: P1 value 0  P2 accounting 0  P3 poll 0  P4 readback 0  P5 landmark 0  P6 go-gate 0  P7 ack 0

M9  KILLED     -- tok_ack never raised: D holds tok_done and the position sticks
        tb_fk33_seam.vhd:1228:7:@17485500ps:(report error): tb_fk33_seam: P7 -- the seam DUT still holds tok_done aft
        tb_fk33_seam: P1 value 64  P2 accounting 0  P3 poll 1  P4 readback 2  P5 landmark 0  P6 go-gate 0  P7 ack 2

M9  ANCHOR FAILED (the mutation was not applied)   -- tok_ack never raised: ...
=== TOTAL 1   KILLED 0   KILLED(PRIOR) 0   SURVIVED 0   ABORT 1 ===
```

**Attribution:** the verdict is `KILLED`, not `KILLED(PRIOR)`.  That column is
this harness's built-in attribution control -- it reports `KILLED(PRIOR)` when
the first diagnostic comes from a file that is not `sim/tb_fk33_seam.vhd`, i.e.
when an older property caught the mutant.  It did not fire, and the diagnostic
names P7, which is the property in the row's own legend.

The anchor was broken by `9fbb5c0` (2026-09-18), which took `ack_r <= '1'` out
of the `d_tok_done` branch and made it an unconditional `ack_r <= d_tok_done`.
**The row had been silently absent for two days, over a fix to the ack path
itself** -- which is the worst possible moment for its teeth to be gone.

### 4.5 `sim/mutate_attn_kv_seam.sh`, four rows, teeth both ways (MEASURED)

```
S1   KILLED       -- kr_rdy ignored (the pre-seam design)    [control for the lane]
        tb_attn_kv_seam.vhd:1006: kr_en was raised while kr_rdy was low.

R3   KILLED(HANG) -- the K request driven from the ISSUE cycle again
        tb_attn_kv_seam.vhd:646: 20000 cycles with the block busy and no cache traffic
R5   KILLED(HANG) -- the K bypass removed: the sweep asks the cache for cur_pos
        tb_attn_kv_seam.vhd:646: 20000 cycles with the block busy and no cache traffic
R5b  KILLED       -- the K bypass removed AND the cache told cur_pos is readable
        tb_attn_kv_seam.vhd:1028: the sweep read pos 0 with cur_pos 0.  C spec 2.4
L1   KILLED       -- defect C1 restored: the v_ref fold indexed by KV HEAD ALONE
        tb_attn_kv_seam.vhd:1286: Q1 -- token 1 element 0 = 16829, the oracle says 16974
```

Impossible anchors, one per row:

```
R3   MUTATION ANCHOR 3 MATCHED 0 TIMES, expected 1   ->  R3  ANCHOR FAILED
R5   MUTATION ANCHOR 5 MATCHED 0 TIMES, expected 1   ->  R5  ANCHOR FAILED
R5b  MUTATION ANCHOR 5 MATCHED 0 TIMES, expected 1   ->  R5b ANCHOR FAILED
L1   MUTATION ANCHOR   MATCHED 0 TIMES, expected 1   ->  L1 ANCHOR FAILED (PARTIAL, NOT run)
```

**Attribution, per row, by which check spoke:** R5b is killed by the ADDRESS
property at `tb_attn_kv_seam.vhd:1028` and not by the value oracle, which is
exactly what its legend claims ("invisible to a value oracle, and caught only
by the property stated over the ADDRESSES").  L1 is killed by Q1, the value
oracle against `ref/attn_block_vec.c`, which is what a restored defect C1 must
be caught by.  R3 and R5 are both `KILLED(HANG)` -- the bench's residency
watchdog, a coarse mechanism, not a seam property.  That is the harness's own
attribution label and it is reported rather than folded into `KILLED`.

### 4.6 `sim/mutate_llama_top_kv.sh` R6 and `sim/mutate_rmswire.sh` R7 (MEASURED)

Both run from the detached worktree at `00d92f1`.  Controls first:

```
C0  SURVIVED   -- CONTROL: clean, the shipping KV configuration            (llama_top_kv)
R0  SURVIVES   -- CONTROL: clean tree                                      (rmswire)
```

`llama_top_kv` R6, the K/V base swap, re-anchored onto the seam registers
`109dc27` introduced:

```
R6  KILLED     -- the K and V bases are swapped
sim/tb_llama_top.vhd:3220:7:(report failure): tb_llama_top RESULT: FAIL
sim/tb_llama_top.vhd:3158:5:(report note): tb_llama_top: schedule mismatches=0
  skew differences=0 degenerate residuals=0 token position faults=0
  KV sticky errors=0 KV faults=5440 (write placement 0, read placement 5440,
  served bytes 0, coverage 0, ...
```

**Attribution, exactly: `read placement 5440`, every other counter ZERO.**  A
swapped base leaves writes going where the (swapped) configuration says and
sends every read into the other region, so the READ PLACEMENT property is the
only one that can see it.  It is not the value oracle, not the schedule
checks, not the sticky error latch -- all four report 0 on the same run.

`rmswire` R7, the `o`-stream latency mutant, re-anchored by scope:

```
TAG    FULL          noWACT        noASRT        onlyWA        WHAT
R7     K:landmarks   K:landmarks   K:landmarks   K:landmarks   o STREAM: the write-back consumes the bank output ONE CYCLE EARLY
```

**Attribution, and it is the full four-column control this harness was built
for: the kill belongs to the TOKEN LANDMARKS and to neither assertion.**  It
survives into `noASRT`, where both `wact_chk` and TRACK NORMURAM's
`wbusy`-at-`r_go` assertion are `assert true`.  Reported under its own name:
**this row earns nothing for either assertion**, which is what the columns
exist to say.

### 4.6b The rows that landed after section 4.6 (MEASURED)

```
N1   KILLED     -- the real rmsnorm's learned-gain exponent is 20 octaves out
        tb_llama_top: ... degenerate residuals=16 ... (every other counter 0)
N1x  SURVIVED   -- the SAME mutation against the DEFAULT gate row, which does
                   not elaborate the NORM_REAL adapter at all
N2   KILLED     -- the real rmsnorm's writeback drops its last element
        tb_llama_top.vhd:3092: P14 -- hash of the 64-completion step trace is
        56838 and the recorded landmark is 17333
        tb_llama_top: schedule mismatches=0 skew differences=0 degenerate
        residuals=0 token position faults=0 KV sticky errors=0 KV faults=0
N2x  SURVIVED   -- the SAME mutation against the DEFAULT gate row
        tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run
```

**N1's attribution is the harness's own designed control and it now works on
the re-anchored row: N1 KILLED, N1x SURVIVED.**  The kill belongs to
`tb_llama_top_real` and the default gate row is blind to it, which is the
reason the N rows were added in the first place.  The discriminating check is
`degenerate residuals=16` with every other counter at zero.

**N2's attribution is sharper and is worth recording on its own: every
STRUCTURAL counter is ZERO and only the P14 landmark hash fired**, and its own
control `N2x SURVIVED` on the default gate row.  Dropping
the last element of the norm write-back moves no schedule, no position, no
KV placement and produces no degenerate residual.  The value landmark is the
only thing in the bench that can see it.

```
TAG    FULL          noWACT        noASRT        onlyWA        WHAT
R5b    K:landmarks   K:landmarks   K:landmarks   K:landmarks   w STREAM, m7 hazard: the bank write address REVERSED
R8     K:landmarks   K:landmarks   K:landmarks   K:landmarks   o STREAM: the region write address off by one against the bank read address
```

**R5b is the row ADDED to carry the retired `normuram` U3, and it bites.**  The
m7 reversal on the form that ships is caught -- and the four-column control
says by the pre-existing token landmarks, not by `wact_chk` and not by TRACK
NORMURAM's `wbusy` assertion.  So retiring U3 costs no coverage: the property
is held, and it is held by the landmarks rather than by either assertion.

**R8, the last row of the track, is the same verdict and the same attribution.**
Both `o`-stream and `w`-stream address mutants are caught, and all three
re-anchored `rmswire` rows (R7, R8, R5b) are `K:landmarks` in every column.

**THAT UNIFORMITY IS ITSELF A RESULT AND IT IS NOT A FLATTERING ONE.**  Across
the three rows this track re-anchored, NEITHER assertion earned a single kill:
`wact_chk` (TRACK RMSWIRE's) and the `wbusy`-at-`r_go` assertion (TRACK
NORMURAM's) are both `assert true` in the `noASRT` column and every row still
dies.  That is what `onlyWA` was built to expose and it is consistent with what
`mutate_rmswire.sh`'s own header already predicted in prose -- *"it earns NO
kill of its own"*.  It does NOT follow that either assertion is worthless:
these three mutants are all VALUE faults, and both assertions are SCHEDULE
checks aimed at a load race the value rows do not create.  What follows is
narrower and should be stated as such: **no row re-anchored here discriminates
on either assertion, so this track re-earned nothing for them.**

### 4.7 The vanished-row ledger, teeth both ways (MEASURED)

`mutation_harness_audit.tsv` classifies `llama_top_kv` and `rmswire` SAFE and
that is correct -- no false `SURVIVED` is printed.  But
`[ -n "$D" ] && run_case ...` **skips the row silently**, and nine rows were
absent from `llama_top_kv` for up to twenty-one days with nothing saying so.
Both harnesses now record every mutator failure by tag, print it in a block of
its own, and exit nonzero:

```
clean tree:          === every anchor matched; no row was skipped ===      rc 0
R6 anchor broken:    === ROWS THAT DID NOT RUN: 1 ===  ...  R6             rc 1
N1 anchor broken:    === ROWS THAT DID NOT RUN: 1 ===  ...  N1             rc 1
N2 anchor broken:    === ROWS THAT DID NOT RUN: 1 ===  ...  N2             rc 1
R7 anchor broken:    === ROWS THAT DID NOT RUN: 1 ===  ...  R7             rc 1
rmswire R7 broken:   === ROWS THAT DID NOT RUN: 1 ===  ...  R7             rc 1
rmswire R8 broken:   === ROWS THAT DID NOT RUN: 1 ===  ...  R8             rc 1
rmswire R5b broken:  === ROWS THAT DID NOT RUN: 1 ===  ...  R5b            rc 1
```

Each is the stubbed replay (no GHDL), with exactly one anchor made impossible
and every other anchor left alone, so the ledger is shown to name the right
row and not merely to fire.

---

## 5. Measured and REJECTED -- do not retry

- **Raising `mutate_rtl_n`'s L1 count from 3 to 5.**  It is the obvious fix and
  it is wrong twice over: two of the five matches are COMMENT text, so the
  mutant would edit comments, and a count that includes comments can be
  satisfied by adding one, which is exactly how `gen_pcieep.py`'s
  `\bllama_top\b` D-presence guard was satisfied and the pcieep build stayed
  dead for weeks.  Replaced by four per-site anchors, each required exactly
  once.
- **Disambiguating `gvr` from `gsr` by anchoring on the comment above the
  block.**  It works today, it is the only textual discriminator at HEAD, and
  it makes a mutation row depend on prose.  Replaced by a SCOPE stated in code
  (`mutate_rtl_scoped` / `sub_scope`): two generate headers, each required
  exactly once, with the anchor required N times between them.
- **Re-anchoring `mutate_llama_top_normuram.sh`'s nine rows.**  Every one maps
  onto a row that `sim/mutate_rmswire.sh` already runs against the store that
  actually ships, with the SAME wrapper, the SAME `G_NORMW` generics, the SAME
  `LAND_NORMW` landmarks and the same `FILES` closure read from the same owner
  -- and with four attribution columns where normuram had one three-way
  verdict.  Re-anchoring would have produced a second harness mutating the same
  lines of the same file.  RETIRED as a tombstone with a per-row successor map.
- **Keeping `rmswire` R4 and R11 (and normuram U2 and U7).**  R4/U2 reverse a
  GW sub-word select that does not exist: `21db25b` made `gw_pick` return 1
  unconditionally and `c094867` deleted the mux, and `rtl/llama_top.vhd`'s
  `wsubsel` comment says so in the RTL.  R11/U7 force GW to 1, which IS the
  shipping value, so the mutation is the identity and the row is a second copy
  of the control.
- **Running the teeth in the shared checkout.**  `rtl/llama_top.vhd` is +368
  lines dirty from TRACK GSRWIDE.  A `tb_llama_top` row is 13 minutes and the
  file can move inside it.  All `llama_top` teeth were run from a detached
  `git worktree` at `00d92f1`, verified by `md5sum` against
  `git show HEAD:rtl/llama_top.vhd`.

---

## 6. Measurement traps hit

- **An anchor verified only against the working tree is not verified.**  Three
  of this track's proposed anchors (`N2`/`VN2` in `llama_top_kv`, `R7`/`R8` in
  `rmswire`) matched exactly once in the dirty tree and TWICE at HEAD, because
  GSRWIDE's uncommitted edit had already wrapped `gsr`'s copy in an extra
  `else`.  Anchoring on the working tree would have produced rows that are
  alive today and dead the moment GSRWIDE lands differently -- and the only
  tell would have been the rows vanishing again.
- **A stubbed replay tells you HOW MANY anchors are dead, not WHICH.**  The
  mutator's diagnostic is on stderr, above the row and detached from it, so the
  first replay gave `9`, `9`, `4`, `4`, `1` and no tags.  Patching the replay
  copy to print the tag alongside cost two minutes and is the difference
  between a count and an inventory.  This is why MUTAUDIT's hand-off named the
  wrong rows for two harnesses: the number was right and the attribution was a
  guess.
- **`ONLY` did not exist in `mutate_attn_kv_seam.sh`.**  Running it to re-check
  one row runs all 25, and the first attempt timed out at two minutes with
  nothing to show.  An `ONLY` filter taking EXACT tags was added -- exact,
  because a substring filter cannot select R5 without R5b nor R7 without
  R7b/R7c/R7d.
- **A buffered log is not a progress signal** (recorded already, hit again).
  `nohup ... > log` on a `tb_llama_top` row shows the header echoes and then
  nothing for the whole run.  Count the row directories in the scratch tree, or
  read `/proc/PID/cwd` of the running `ghdl`.

---

## 6b. A LATENT GATE FAILURE FOUND ON THE WAY OUT: the manifest names a file that was never committed

**MEASURED 2026-09-20, after this track's work was committed.**
`sim/check_mutation_harness.py` -- the checker TRACK MUTAUDIT built and
proposed to wire as the `sim:mutaudit` gate row -- **passes on this workstation
and FAILS on a fresh clone of the very tree it was committed in.**

```
$ git clone --no-hardlinks <repo> freshclone && cd freshclone && git checkout da9a1aa
$ ls sim/mutate_*.sh | wc -l
61
$ python3 sim/check_mutation_harness.py
FAIL R1: the manifest names sim/mutate_swg_wide.sh, which does not exist.
checked 61 harnesses; 1 finding(s)
```

Against 62 harnesses and 0 findings in the working checkout.

**The cause is one line of the checker, and it is this track's own theme in a
new place.**  R1 builds its list of harnesses from a DISK GLOB, not from git:

```python
here = sorted(f for f in os.listdir(os.path.join(REPO, "sim"))
              if f.startswith("mutate_") and f.endswith(".sh"))
```

So the manifest is reconciled against whatever happens to be sitting in `sim/`,
including UNTRACKED files.  `sim/mutate_swg_wide.sh` is **TRACK GSRWIDE's**
(its own header, line 6: *"TRACK GSRWIDE, lever L2"*), it was on disk
uncommitted when MUTAUDIT swept the tree, MUTAUDIT audited it and recorded it
in `sim/mutation_harness_audit.tsv` with a MEASURED verdict -- and the manifest
was committed while the file it names was not.  **A committed file now
references an uncommitted one.**  It is the ONLY such entry: a check of all 62
manifest rows against `git ls-files` finds exactly one untracked.

**Nobody did anything wrong at the time and that is the point.**  MUTAUDIT's
sweep was correct, its audit of that harness was MEASURED and real, and the
manifest row is accurate about the file's behaviour.  The defect is that the
CHECKER cannot tell "a harness exists" from "a harness exists in this working
directory", so the completeness rule it enforces is relative to the machine it
runs on.  That is the same failure shape as every other finding in this
document: **a check that passes for an environment-specific reason.**

**NOT FIXED HERE, DELIBERATELY.**  The obvious fix -- commit
`sim/mutate_swg_wide.sh` -- would capture a live track's in-flight file under
this track's message, which is the exact cross-track hazard `CLAUDE.md` records
and which has already caught four tracks in one day.  The file is GSRWIDE's and
GSRWIDE should commit it.  The second fix -- making R1 read `git ls-files`
rather than `os.listdir` -- is a change to MUTAUDIT's checker, is not obviously
right (a harness legitimately under development is untracked and SHOULD still
be audited), and belongs with whoever wires the gate row.

**What this does mean, concretely: `sim:mutaudit` MUST NOT be wired as a gate
row until this is resolved, or it goes red on its first CI run** -- and it
would go red naming a file nobody had touched, which is the least debuggable
possible first failure for a new gate.

---

## 7. Open, not determined

- **The codebook has NO mutation coverage at all.**  MEASURED 2026-09-20:
  `grep -l 'cbrom\|CBMAP\|CBMARK\|ixrom' sim/mutate_*.sh` over all 62 harnesses
  returns NOTHING.  TRACK GAIN16 (`c094867`) replaced the gain value ROM with
  an 11-bit index ROM plus a 1,567-entry codebook -- a packer and an unpacker
  that can be wrong in mirror-image ways and agree with each other, which is
  this project's recorded `m7 mutant` shape and is precisely what normuram's U2
  and U3 existed to attack.  Retiring normuram does not create this hole; the
  hole arrived with `c094867` and normuram's rows had been dead since then.  It
  is now visible.  **Nobody has teeth on `CBMAP`.**
- **Six re-anchored rows have verified anchors and no verdict.**  The
  `tb_llama_top` rows cost 13 minutes or more each and the budget for this
  track ran out: `llama_top_kv` R7, R7b, R8, VR7, VR7b and VN2 are
  re-anchored, replay-clean at HEAD **and** in the working tree, and have
  their impossible-anchor teeth, but the row itself has not been RUN.  Their
  verdicts are DERIVED from the legend and the RTL, not MEASURED.
  (`rmswire` R8 landed after this section was first written and is MEASURED;
  see 4.6b.)
- **`rmswire`'s T0-T3 tap rows were never run by this track.**  They are
  filtered out by `ONLY` and judged by a different bench
  (`sim/tb_rmswire_loadrace.vhd`), so the `w_active` half of that harness is
  untouched and unverified here in either direction.
- **`sim/mutate_swg_wide.sh` is untracked and the manifest names it** (section
  6b).  Owner is TRACK GSRWIDE.  Until it is committed, or R1 is changed,
  `sim:mutaudit` fails on any fresh clone.  Deliberately NOT fixed here: the
  file belongs to a live track.
- **Whether R1 SHOULD read git rather than the disk is not settled.**  A
  harness under active development is untracked and arguably still needs
  auditing, so switching to `git ls-files` trades one blind spot for another.
  Stated as a question for whoever wires the gate, not as a recommendation.
- **R7/VR7 and R7b/VR7b carry a PREDICTION that was not tested here.**  Their
  own legends, written by TRACK C1, say R7 survives on the fixed design
  (`cmp` of the clean and R7 captures is IDENTICAL at NTOK 3, 5 and 8) and
  R7b is KILLED(ABORT) by `attn_block`'s `vsh_neg`.  Those statements predate
  `1b8d28f`, which is the commit that broke the anchor, and nothing here
  re-establishes them.
- **`gsr` is a copy-paste of `gvr` and nothing says so to a tool.**  The fix
  here scopes around it.  The underlying condition -- two identical state
  machines in one file, distinguished only by a comment -- will break the next
  anchor written into either one.
- **No per-property ablation was run.**  The attribution claims above are "which
  check spoke first", read from each harness's own built-in classification
  (`KILLED(PRIOR)`, `KILLED(HANG)`, the four `rmswire` columns).  That is
  weaker than disabling the credited check and re-running, which is what would
  settle whether an OLDER property would have caught the mutant anyway.  It was
  not done for any row here.

---

# 8. TRACK CBANCHOR, 2026-09-20: a FOURTH cause, and it cannot be repaired by substitution

Appended per the project rule rather than opened as a second file about the
same phenomenon.  Workstation, branch `fpga`, starting at `5dc3ee5`.  No
hardware, no Vivado (build 11 held the workstation lane and TRACK HDRCOST held
the BC-250).  GHDL (mcode) only.

## 8.1 The question

> TRACK CBFANOUT changed `rtl/matvec_core.vhd` to replicate the codebook write
> COMMAND per ROW (`CB_RANKS = 48`) rather than per COPY (`CB_COPIES = 1536`)
> [...] It handed over one item explicitly: *"`sim/mutate_matvec_cb.sh` anchors
> on text this change moves and will print `ANCHOR FAILED` on some rows.  Not
> fixed here -- mechanical replacements are in the write-up, including that the
> W1 write and W0 capture are now two separate loops."*

## 8.2 The answer, up front

**Nine rows were dead, not "some": K2a K2b K2c K3a K3b K3c K3d K7a K7b.
Disposition: 9 RE-ANCHOR, 0 RETIRE, 0 CANNOT DECIDE.**  All nine were
re-anchored, all nine now run, and the re-anchor is **verdict-preserving**:
measured against the OLD harness on the OLD tree, every column is identical.

**The new cause is a LOOP SPLIT, and it is different in kind from the two this
document already records.**  Section 2's causes are both cases where the anchor
TEXT is still in the file and something else changed around it.  Here the text
is gone because the code's SHAPE changed:

```
BEFORE (one loop, per COPY)              AFTER (two loops, different bounds)
  for c in 0 to CB_COPIES-1 loop           for c in 0 to CB_COPIES-1 loop
    -- W1: write cb(c) from cbw_*(c)         -- W1: write cb(c) from cbw_*(rank)
    -- W0: capture cbw_*(c)                end loop;
  end loop;                                for r in 0 to CB_RANKS-1 loop
                                             -- W0: capture cbw_*(r)
                                           end loop;
```

**A row that mutated both halves at once had ONE anchor spanning both, and no
string in the new file is that anchor's successor.**  `mutate_rtl_n`-style
count repair cannot fix this and neither can a scope: the row has to be
re-expressed as TWO anchors, one at the write and one at the tail of the W0
loop.  K2b and K3c are both of that shape.  **The tell is that the mechanical
`CB_COPIES -> CB_RANKS` substitution CBFANOUT supplied repairs seven of the
nine rows and silently cannot repair two**, and nothing distinguishes the two
cases without reading the mutation's intent.

## 8.3 A near-miss that is the same shape as section 2's duplicate block

`rtl/matvec_core.vhd` contains `if cb_we = '1' and st = S_IDLE and rst = '0'
then` **twice**: in `P_CB` at eight spaces of indent and in `P_CB_MODEL` at
six.  Rows K1a-K1d anchor on the eight-space form and are ALIVE **only because
of whitespace**.  That is exactly section 2's "distinguished only by the
comment above them", one notch worse: the discriminator is invisible.

**And the twin is the ORACLE.**  `P_CB_MODEL` is the independent model of the
write path that K2b and K2c are killed by.  A future re-indent that made the
eight-space form ambiguous would, on the obvious repair, mutate the model
instead of the design -- and a mutated oracle that stops disagreeing with a
correct design scores as **SURVIVED**.  A row that tests nothing and says so is
the SAFE class; a row that mutates its own oracle and prints `surv` is the
UNSAFE one, and it is reachable from here by an edit nobody would think twice
about.

MEASURED, the same file, same day:

```
"for c in 0 to CB_COPIES-1 loop"   matches TWICE   (P_CB:804, P_CB_MODEL:929)
```

So the fix is this document's own prescription, applied before it was needed:
every body anchor in the nine re-anchored rows is scoped `@P_CB@`, and a scope
is two CODE landmarks (a process header required exactly once in the file, and
the first `end process;` after it).  Nothing depends on a comment or on an
indent.

**The scope was teeth-tested in three directions, MEASURED:**

```
ZZunsc  ANCHOR 0 MATCHED 2 TIMES, expected 1          -> ANCHOR FAILED
ZZsc    the SAME anchor, scoped @P_CB@                -> applied, row ran
ZZbad   ANCHOR 0 NAMES UNKNOWN SCOPE P_NOT_A_PROCESS  -> ANCHOR FAILED
```

`ZZunsc` and `ZZsc` differ only by the scope prefix, which is what makes this a
discrimination test rather than a smoke test.

## 8.4 The harness was NOT one of the ones this track fixed

MEASURED at `5dc3ee5`, `sim/mutate_matvec_cb.sh` unmodified:

```
ANCHOR 0 MATCHED 0 TIMES, expected 1
K2a    ANCHOR FAILED -- tested nothing -- the command capture is one cycle late ...
   ... (nine of these) ...
kill ratio: 0 KILLED + 0 ABORTED = 0 of 20;  11 SURVIVED
survivors (nothing in the closure watches these): K1a K1b K1c K1d K4a K5a K5b K6a K8a K8b K9a
$ echo $?
0
```

It is **better than the harnesses section 4.7 fixed** -- the tag is printed
alongside `ANCHOR FAILED`, so this is an inventory rather than a count -- and
it is **worse in the one way that matters for CI**: rc is 0 and there is no
ledger.  The only arithmetic tell is that `KILLED + ABORTED + SURVIVED = 11`
against a total of `20`, and **nobody computes that**.  It now carries the same
ledger the other two got:

```
clean tree:        === every anchor matched; no row was skipped ===   rc 0
K2b  broken:       === ROWS THAT DID NOT RUN:1 ===  K2b               rc 1
K3c  broken:       === ROWS THAT DID NOT RUN:1 ===  K3c               rc 1
K7a  broken:       === ROWS THAT DID NOT RUN:1 ===  K7a               rc 1
K10a broken:       === ROWS THAT DID NOT RUN:1 ===  K10a              rc 1
```

each with exactly one anchor made impossible and every other anchor left alone.

## 8.5 THE CONTROL THAT SEPARATES "THE RE-ANCHOR WORKED" FROM "THE RE-ANCHOR CHANGED THE ROW"

This is the part worth reusing and it is not in sections 1-7.

A re-anchored row that KILLS proves the anchor matched.  It does **not** prove
the row still means what it meant, because a re-anchor is an opportunity to
write a different, easier mutation -- the failure mode the brief names as "do
not re-anchor a row by making its mutation trivial enough to kill".

**The control is the OLD harness against the OLD tree**, in a detached
`git worktree` at `0b34200^`, column for column against the new one.  MEASURED,
`CBSTYLE=distributed`, `MODES="A N S"`:

```
                OLD harness @ 0b34200^          NEW harness @ HEAD
K2a   AC:KILL(a) AL:KILL(a) AM:KILL(a) ... SC:KILL(a) SL:KILL(a) SM:KILL(v)   IDENTICAL
K2b   AC:KILL(a) AL:KILL(a) AM:KILL(a) ... SC:surv    SL:surv    SM:surv      IDENTICAL
K2c   AC:KILL(a) AL:KILL(a) AM:KILL(a) ... SC:surv    SL:surv    SM:surv      IDENTICAL
K3a   AC:KILL(a) ...                       SC:KILL(a) SL:KILL(a) SM:KILL(a)   IDENTICAL
K3b   AC:KILL(a) ...                       SC:KILL(a) SL:KILL(a) SM:KILL(a)   IDENTICAL
K3c   AC:KILL(a) ...                       SC:KILL(a) SL:KILL(a) SM:KILL(a)   IDENTICAL
K3d   surv in all nine                                                        IDENTICAL
K7a   AC:KILL(a) AL:KILL(a) AM:KILL(a) ... SC:surv    SL:surv    SM:KILL(v)   IDENTICAL
K7b   AC:KILL(a) AL:KILL(a) AM:KILL(a) ... SC:surv    SL:surv    SM:KILL(v)   IDENTICAL
```

Nine rows, twenty-seven columns each, no difference.  **The re-anchor is
verdict-preserving, and that is a measurement rather than an intention.**

## 8.6 AND THE CONTROL FOUND SOMETHING ELSE: TWO LEGENDS HAD BEEN WRONG FOR WEEKS WHILE THE ROWS RAN GREEN

K2b's legend said **"SURVIVE -- and that is the finding"**.  K2c's said
**"SURVIVE: the write lands one cycle EARLIER, which is still legal"**.  Both
rows are **KILLED**, and the control above shows they were killed on the OLD
tree too.

The cause is `P_CB_MODEL`, an independent model of the write path built from
the ports and delayed by `CB_WR_LAT`.  It was added after those legends were
written and it sees both mutations.  **Nothing noticed**, because the harness
prints `expected:` under each row as prose and no check compares it to the
verdict.

**A row that RUNS is not a row whose legend is true.**  This document's
sections 1-7 are about rows that vanished; this is the complementary failure --
a row that is present, green, and describes a property the design no longer
has.  It is strictly harder to see, because the output looks like evidence.
Both legends are corrected in place, with the original quoted, so the change is
visible rather than absorbed.

## 8.7 Teeth and attribution, per re-anchored row (MEASURED)

`CBSTYLE=distributed MODES="A N S P"`, 22 rows, `rc 0`,
`=== every anchor matched; no row was skipped ===`.
A = everything live; N = `P_CB_CHK` demoted; S = `P_CB_MODEL` demoted;
P = TRACK CBFANOUT's elaboration pin `CHK_CB_RANKS` neutered (new here).

| row | verdict | A | N | S | P | attribution |
|---|---|---|---|---|---|---|
| CTRL | SURVIVED | surv | surv | surv | surv | control, all twelve columns |
| K2a | KILLED | KILL(a) | KILL(a) | KILL(a) | KILL(a) | **neither check earned it** -- both see it |
| K2b | KILLED | KILL(a) | KILL(a) | **surv** | KILL(a) | **`P_CB_MODEL` EARNED it** |
| K2c | KILLED | KILL(a) | KILL(a) | **surv** | KILL(a) | **`P_CB_MODEL` EARNED it** |
| K3a | KILLED | KILL(a) | KILL(a) | KILL(a) | KILL(a) | neither earned it |
| K3b | KILLED | KILL(a) | KILL(a) | KILL(a) | KILL(a) | neither earned it |
| K3c | KILLED | KILL(a) | KILL(a) | KILL(a) | KILL(a) | neither earned it |
| K3d | **SURVIVED** | surv | surv | surv | surv | equivalent mutant, by design |
| K7a | KILLED | KILL(a) | KILL(a) | SC/SL surv, **SM:KILL(v)** | KILL(a) | the **value oracle on bench M**, exactly as its legend claims |
| K7b | KILLED | KILL(a) | KILL(a) | SC/SL surv, **SM:KILL(v)** | KILL(a) | same |

**The honest reading of four of those rows is that this track re-earned nothing
for either check.**  K2a, K3a, K3b and K3c die in every column: `P_CB_CHK` and
`P_CB_MODEL` both catch them, so neither is the sole witness and an older
property would have caught each one anyway.  That is reported rather than
folded into a kill count, and it is the same verdict shape section 4.6b records
for `rmswire`.

**K7a and K7b are the opposite and are the more useful rows.**  With
`P_CB_MODEL` demoted they survive on benches C and L and die only on M -- which
is the pre-existing legend, written in 2026-08, reproduced unchanged at the new
structure: *"C and L are RELATIONAL [...] only an ABSOLUTE oracle has an
opinion about what the table should contain."*

## 8.8 Mutations that did NOT bite, under their own names

Kept per the standing rule; these measure the resolution floor.

- **K3d SURVIVED all twelve columns.**  Every copy writes off rank 0's command
  registers -- the master/follower design `matvec_core.vhd` rejects by
  construction -- and nothing in the functional closure can tell it from the
  replicated design.  **This is not a gap to be closed; it is the measured form
  of TRACK CBFANOUT's central claim**, and the reason the elaboration pin had to
  exist.
- **K10a and K10b SURVIVE at `CBSTYLE=regs`, which is the harness's DEFAULT.**
  MEASURED: `tb_matvec_core` runs `ROWS_IF=4 BLK=32`, so `regs` gives
  `CB_COPIES=4` and `CB_RANKS` is already 4 -- K10a (`CB_RANKS := CB_COPIES`)
  is **literally the identity**, and K10b (`CB_RANKS := 1`) still satisfies
  both halves of the fanout bound (`1 <= ROWS_IF=4` and `4/1 <= BLK=32`).  The
  pin is behaving correctly: at four copies there is no fanout problem to have.
  **It is recorded because a reader running the harness with no environment set
  sees two SURVIVED rows and could conclude the pin has no teeth.**  Now stated
  in the class header and in both row legends.
- **K1b, K8a, K8b** survive as they always did; not this track's rows, listed so
  the survivor line is not read as new.

## 8.9 Verifying TRACK CBFANOUT's `M2_percopy` claim independently

CBFANOUT's commit says: *"M2_percopy -- the fix undone, i.e. exactly what build
10 built -- fires the pin in A and S and SURVIVES ALL THREE BENCHES in P, so
the pin earned that kill and nothing else in the project can see it."*

**CONFIRMED, and the check was needed, because CBFANOUT's teeth table was NOT
REPRODUCIBLE FROM THE REPO.**  `git show 0b34200 --stat` lists three files --
`docs/WORKLOG.md`, the write-up, and `rtl/matvec_core.vhd`.  The M-rows lived in
a scratch harness that was never committed, so the decisive evidence for the
change that is going into build 12 existed only in a document.

Reconstructed here as committed rows `K10a` (= M2_percopy) and `K10b`
(= M1_collapse), with `CHK_CB_RANKS` neutering added to the harness as mode P.
MEASURED, `CBSTYLE=distributed`:

```
K10a  ABORTED  AC:ABRT AL:ABRT AM:ABRT  NC:ABRT NL:ABRT NM:ABRT
               SC:ABRT SL:ABRT SM:ABRT  PC:surv PL:surv PM:surv
K10b  ABORTED  (identical)
```

The abort is the pin and nothing else:

```
/usr/bin/ghdl-mcode:error: bound check failure at .../K10a/A/matvec_core.vhd:371
  from: work.matvec_core(rtl).DECL_ELAB at matvec_core.vhd:371
```

`matvec_core.vhd:371` is `constant CHK_CB_RANKS : natural := cb_rank_chk_f;`.
And with the pin neutered the mutant runs to completion and passes:

```
.../K10a/P/matvec_core.vhd:763: matvec_core: LEVER C ACTIVE  CB_STYLE=distributed
    CB_COPIES=64  CB_LANES_PER_COPY=1  CB_RANKS=64  CB_WR_LAT=1
tb_matvec_cb_contract: PASS -- 9 runs, 0 failures. ...
```

`CB_RANKS=64 = CB_COPIES` is the fix undone, and every bench passes.  **So the
claim holds: the pin is the sole witness, and without it a regression to the
structure that failed build 10 at WNS -5.819 ns is invisible to every test in
this project.**

**CBFANOUT's own measurement trap reproduced exactly**: the harness scores these
as `ABORTED`, not `KILLED`, because an out-of-range `natural` fails at
`ghdl -r` elaboration and no bench log contains an assertion.  Read the
elaboration diagnostic; do not read the verdict word.

## 8.10 Open item 4 of CBFANOUT's write-up is now ANSWERED, from past runs

> *"Whether Vivado evaluates the new elaboration function.  `cb_rank_chk_f`
> loops `CB_COPIES-1` times (1,535 at the card) over constant folding.  GHDL
> does it.  Vivado's VHDL front end is not tested here and no Vivado ran."*

**It does, and the evidence is already in the tree.**  `rtl/fk33_llama_top.vhd`
(and `rtl/llama_top.vhd`, its source) declares

```vhdl
function cb_map return cbmap_t is ...
  for a in 0 to 255 loop
    for b in 0 to 255 loop        -- 65,536 iterations
constant CBMAP : cbmap_t := cb_map;
```

a **65,536-iteration** nested constant-folding loop building a 65,536-element
constant array, introduced by `c094867` on 2026-08-31.  MEASURED:
`hw/fk33/gen_pcieep.py` lists `rtl/fk33_llama_top.vhd` in the card source set,
`hw/fk33/rtl/fk33_card.vhd:220` instantiates it, and every `FK33_CARD=1` build
since then has synthesised it -- build 9 (`card_kvreg_2026-09-20`) to a shipped
bitstream at WNS +0.061, and build 10 to a **routed** timing summary.

`cb_rank_chk_f` is **1,535 iterations of integer arithmetic with an early
return and no array construction**, 43x smaller than a loop Vivado has folded
in this tree on every card build for three weeks.  **The folding risk is
retired.**  DERIVED from those runs; no Vivado ran for this track.

**What is NOT settled, and it is the other half of the idiom**: whether Vivado
STOPS on the out-of-range `natural` when the pin should fire.  `CHK_CB_STYLE`
in the same file uses the identical idiom and has been through every card
build -- but it has never FIRED in one, so passing through synthesis is no
evidence that a violation would be caught.  That half rests on `CLAUDE.md`'s
recorded rule, not on any measurement here.

## 8.11 Measured and REJECTED -- do not retry

- **Repairing K2b and K3c by substitution into a single anchor.**  There is no
  single anchor.  The one loop became two with different bounds and different
  induction variables; the v2 pipeline assignments must go in the W0 **rank**
  loop while the write stays in the W1 **copy** loop.  Any repair that keeps
  one anchor has either moved the capture into the copy loop (which changes the
  fanout the row exists to model) or mutated only half the stage.
- **Making K3c skew RANKS instead of COPIES** (which is what the mechanical
  `c -> cb_rank_of(c)` substitution suggests).  What `P_CB_CHK` guards is that
  no two **copies** of `cb` hold different tables, so the mutation that attacks
  it must skew copies.  A rank skew is a different mutation -- CBFANOUT's
  `M4_rankskew` -- and putting it under K3c's name would retire K3c's property
  while appearing to keep it.
- **Making K3d collapse `cb_rank_of` instead of the write site.**  That is
  CBFANOUT's `M1_collapse`, it fires the elaboration pin, and no bench would
  ever run.  K3d's whole value is that it is a mutation the pin CANNOT see, so
  it measures the functional closure rather than the pin.  Both are kept, under
  separate names (K3d and K10b), and the difference is stated in the file.
- **Retiring any of the nine.**  Each names a property that still exists in
  today's RTL and that some column still discriminates on, so RETIRE was not
  reachable for any of them.  0 RETIRE is a result, not an omission.
- **Adding a Z0 self-teeth row to promote the harness to SELFTEETH class.**  The
  ledger plus `rc 1` already makes a skipped row impossible to miss, and a Z0
  row would be a fifth place for an anchor to rot.

## 8.12 Measurement traps hit, including this track's own

- **A `cd` into the control worktree persisted across the next command, and the
  run labelled "NEW tree, CBSTYLE=regs" was the OLD tree.**  MEASURED: the
  table it printed looked entirely plausible, including a `P` column -- because
  the old harness does not know mode `P` and silently ran it as a duplicate of
  mode `A` with no neuter.  **The only tell was that class K10 was absent from
  the output**, 20 rows where 22 were expected.  Had the control worktree been
  at a commit that already had K10, nothing would have looked wrong.  This is
  `CLAUDE.md`'s "a fact about the harness reported as a fact about the job", in
  the plainest possible form.  The re-run used an absolute path to the script
  and printed `pwd` and the md5 of both files first.
- **An unknown mode is not an error, it is mode A.**  `MODES="A N S P"` against
  a harness with no `P` sets `neut=""` and prints a full column of results that
  mean something other than their heading.  Any harness with a mode list should
  refuse a mode it does not know; this one now has `P` but still does not
  refuse an unknown one.  Stated as open.
- **`sim/check_mutation_harness.py` still FAILS, and not on anything here.**
  `FAIL R1: sim/mutate_gain.sh is not in sim/mutation_harness_audit.tsv` --
  TRACK GAINTEETH's untracked harness, which is section 6b's defect in a new
  instance: R1 reconciles the manifest against a **disk glob**, so another
  track's in-flight file fails the check for everyone.  Deliberately not fixed
  here; the file belongs to a live track.
- **The GHDL footprint of this whole harness is 175 MB, not 2.13 GiB.**
  MEASURED by `/usr/bin/time -v` on a three-row three-mode run:
  `Maximum resident set size 175,628 kbytes`, 6.4 s wall.  The 2.13 GiB figure
  in `CLAUDE.md` is the FULL BOTH-SUITE gate and does not transfer to a
  targeted mutation run.  Quoting it would have refused work that fit in a
  fortieth of the budget -- the same shape as the 25.0 GiB Vivado figure that
  `CLAUDE.md` already records as the expensive refusal.

## 8.13 Open, not determined

- **Whether Vivado stops on an out-of-range `natural` constant when it should
  fire** (section 8.10).  Never observed for `CHK_CB_STYLE` or for
  `CHK_CB_RANKS`.  One deliberately-broken OOC synthesis would settle it.
- **The timing benefit of the per-row command is still entirely unmeasured.**
  Inherited from CBFANOUT unchanged.  No Vivado ran for this track either.
- **`CB_ROWS_PER_COPY > 1` is still untested**, by CBFANOUT and by this track.
  The pin admits it; no bench runs at that setting and no K-row reaches it.
- **K10a and K10b have no `regs`-geometry teeth.**  They are equivalent mutants
  at `CB_COPIES=4`.  A bench at `ROWS_IF=48` would give them teeth at `regs`
  too; `sim/tb_matvec_fk33*` is that geometry and was not run here (200 ms
  stop-time, optional rows needing a `.mv4i`).
- **The harness does not refuse an unknown mode** (section 8.12).
- **`sim/mutate_matvec_cb.sh` is still not wired to any gate row**, so nothing
  schedules the nine rows this track restored.  `sim:mutaudit` is the natural
  home and section 6b says it must not be wired until the `mutate_gain.sh`
  manifest question is resolved.

---

# 9. TRACK MUTWIRE, 2026-09-20: none of the sixty-three harnesses is scheduled, and one has been dead since the commit that created it

Appended per the project rule rather than opened as a second file, because this
is the same phenomenon one level out: sections 1-8 are about rows inside a
harness going dead unnoticed; this section is about the harnesses themselves.
Workstation, branch `fpga`, at `9435942`.  No hardware, no Vivado (the
workstation lane held build 11b and the BC-250 lane held TRACK HDRCOST).
GHDL (mcode) only.  `sim/regress.sh` was NOT edited (md5
`91f5619ad8796867bf6e23c077906992` at both ends).

## 9.1 The question

> TRACK CBANCHOR restored nine dead mutation rows in `sim/mutate_matvec_cb.sh`,
> then reported: *"`sim/mutate_matvec_cb.sh` is still wired to no gate row, so
> nothing schedules the nine rows restored here."*  That is one harness.  **The
> question is how many of the 63 are in the same state.**

## 9.2 The answer, up front

**All 63.  SCHEDULED 0, UNSCHEDULED 63, UNCERTAIN 0** (MEASURED; the method and
its false-negative control are in 9.3).  Not one `sim/mutate_*.sh` is reachable
from any row of `sim/regress.sh`, directly or through any script a row runs.
The checker built to audit them, `sim/check_mutation_harness.py`, is unscheduled
too.

**And the cost of that is not hypothetical.  `sim/mutate_mv4i_desc_stale.sh`
exits 2 having run ZERO rows -- at HEAD, and at `3ecc729`, the commit that
CREATED it on 2026-08-30.  It has never run, in its entire twenty-one-day
existence.**  Every prior finding in this document is a row that stopped
working; this is a whole harness that never started, and the only reason nobody
knew is that nothing ever invoked it.

**The second result is the one that decides what to do about it, and it argues
AGAINST wiring most of them: 48 of the 63 have no non-zero exit anywhere in
their last 40%, and the last executable statement of 49 of them is an `echo`.**
A gate row reads an exit code, so those 48 cannot be a gate row at all until
someone writes them an exit contract -- and of the 15 that do exit non-zero, 8
report only that a row failed to RUN (a dead anchor), one is a retired tombstone,
and one fires only when the UNMUTATED control fails.  **Six harnesses in the
whole set go red when a mutant survives that should have died, and one of the six
is another track's untracked file.**

**A 30-second sweep of all 63 then found FIFTEEN more dead rows in six other
harnesses, plus the one dead harness above** (9.5b).  Every one of those six
exits 0 or times out, so nothing reports them.  TRACK MUTAUDIT inventoried six
harnesses, TRACK REANCHOR replayed five, TRACK CBANCHOR one; nobody had ever
replayed the rest, because the manifest they shared audits the MECHANISM by
which a harness reports a dead anchor and never whether it has one.

Disposition: **2 harnesses WIRE, 60 MANUAL, 1 already a tombstone**, plus one
non-harness row (`sim:mutaudit`, the text checker) recommended with a stated
precondition.  Per harness, with the evidence:
`sim/mutation_harness_wiring.tsv`.

## 9.3 The procedure, and the false-negative control

The naive method is `grep -n mutate sim/regress.sh`.  It returns 20 hits and
every one is a comment, which is suggestive and proves nothing: a harness could
be reached by a wrapper, or by a row whose name does not resemble the file's.

What settles it is that **`regress.sh`'s dispatch is a closed set of four
paths**, all inside `run_one`:

```
run_one() {
  case "${key#*:}" in
    seamgate_*) run_seam "$key"; return ;;          # -> tools/ref9b/seamgate.sh
    graygate)   run_graygate "$key"; return ;;      # -> sim/gray_check.sh
    runguard|ipsync|...|imglock) run_selfcheck ;;   # -> SELFCHECK_CMD, 21 fixed commands
  esac
  ... $GHDL -a / $GHDL -r ...                       # everything else
}
```

so the enumeration is:

1. **The row universe.** `bash sim/regress.sh --list` -> **218 rows, 0 matching
   `mutate`** (MEASURED).  This is the plan the gate actually builds, not a
   guess about what it discovers.
2. **The command universe.** Every external command any row can run is the 21
   `SELFCHECK_CMD` entries plus `seamgate.sh` and `gray_check.sh`.  `grep -c
   "mutate_"` over all 23: **three hits, in `seamgate.sh` (2), `gray_check.sh`
   (3) and `logit_compare.py` (1), and every one is a comment** (MEASURED,
   quoted in 9.4).
3. **Repo-wide, who EXECUTES a harness at all.** `git grep -nE
   "(bash|sh|source|\./|exec|subprocess|check_call|run\()[^#]{0,40}mutate_[a-z0-9_]*\.sh"`
   outside `docs/` and `sim/mutate_*`: **nine hits, all usage comments or
   prose** (MEASURED).  `sim/check_mutation_harness.py` names two harnesses but
   only ever reads them, through `git show`.
4. **The empirical check, on two of the four paths, by execve trace.**

**Step 4 is the part that matters, and it is a discrimination test rather than a
smoke test**, because the harness under suspicion and its scheduled sibling live
in the same directory.  `sim/gray_check.sh` IS scheduled (`sim:graygate`) and
`sim/mutate_gray.sh` is the harness whose rows `gray_check.sh`'s own header
discusses.  One trace must see the first and not the second:

```
$ strace -f -qq -s 300 -e trace=execve -o T env REGRESS_SCRATCH=... \
      bash sim/regress.sh --only graygate
 OVERALL     PASS 1   FAIL 0   ...
$ grep -c gray_check T          -> 25
$ grep -c mutate     T          -> 0
```

and the plain-bench path, for the `run_one` branch:

```
$ strace ... bash sim/regress.sh --only tb_a_job_counter
 OVERALL     PASS 1   ...
   distinct executables:  basename 62, ln 45, dirname 23, grep 13, awk 7,
                          git 5, ghdl-mcode 4, ghdl 4, ...
$ grep -c mutate T              -> 0
```

**No UNCERTAIN class arose, and that is a property of the dispatcher rather than
of the care taken**: the four paths are exhaustive and three of them run a
literal, enumerable command, so there is nowhere for an indirect invocation to
hide.  Had `regress.sh` built a command from a glob or from a row name, the
answer for every harness would have been UNCERTAIN.

## 9.4 THE MEASUREMENT TRAP, AND IT PRODUCED EXACTLY THE ANSWER I EXPECTED

The FIRST execve trace of `--only graygate` reported **`gray_check` 0, `mutate`
0** -- a clean confirmation of the hypothesis, and wrong.

`strace` truncates string arguments to 32 characters by default, and the repo
path is longer than that:

```
execve("/usr/bin/env", ["env", "REGRESS_SCRATCH=/mnt/storage/fk3"..., "bash", ...])
```

so `"/home/orencollaco/GitHub/llama.v"...` never reaches the word
`gray_check.sh`.  **The positive control was the only thing that caught it**:
the trace was supposed to see a scheduled script and did not, which is the one
outcome the method forbids.  With `-s 300` the same command gives 25 hits.

This is `CLAUDE.md`'s "a fact about the harness reported as a fact about the
job" in a shape that is specifically dangerous, because **the false negative
agreed with the expected answer**.  A control that can only fail in the
direction you are hoping for is not a control; this one worked because it was
chosen to fail in the other direction.

## 9.5 `sim/mutate_mv4i_desc_stale.sh` has never run, MEASURED at two commits

```
$ cd <shared checkout @ 9435942>
$ bash sim/mutate_mv4i_desc_stale.sh <scratch>
mutate_mv4i_desc_stale: M2 patch matched nothing -- the prefix file moved
rc=2

$ git worktree add --detach <wt> 3ecc729     # the commit that ADDED the harness
$ cd <wt> && bash sim/mutate_mv4i_desc_stale.sh <scratch>
mutate_mv4i_desc_stale: M2 patch matched nothing -- the prefix file moved
rc=2
```

The harness reads the RTL out of git (`git show HEAD:rtl/matvec_int4_desc_axi.vhd`)
and M2 seds

```
if go = '1' then go_p <= '1'; end if;
```

into a form that also clears `done_l`.  At `3ecc729` that file already read

```
683:        if go_now = '1' then go_p <= '1'; done_l <= '0'; end if;
```

-- the trigger renamed AND the clear already present, both by `3ecc729` itself.
**The harness was written against the pre-fix text and committed alongside the
fix that removed it.**  It is a hard error rather than a silent pass, exactly as
designed, and `sim/mutation_harness_audit.tsv` records it correctly as GUARD:
*"the two prefix patches are `cmp -s`-checked against the pre-image and a no-op
exits 2 outright."*

**TRACK MUTAUDIT's audit of this harness is TRUE and the harness is DEAD, and
those are compatible because the audit read the MECHANISM and never ran the
thing.**  That is the same gap as "a per-unit evidence class says nothing about
the composition", one level up: a correct statement about how a harness would
report a failure is not a statement that the harness runs.  Nothing in the
manifest's shape can close it; only invoking the harness can, and nothing does.

## 9.5b A 30-SECOND SWEEP OF ALL 63 FINDS FIFTEEN MORE DEAD ROWS THAT THREE TRACKS MISSED

Having found one harness dead by running it, the obvious next question is how
many of the others are.  MEASURED 2026-09-20: every `sim/mutate_*.sh` run with
`timeout 30`, scratch on `/mnt/storage`, serial, and its output scanned for
`ANCHOR FAILED` / `MATCHED 0 TIMES` / `BADMUT` / `NOSUB`.  Z0 and Z0_on rows are
DELIBERATE impossible anchors (self-teeth) and are excluded.

```
harness                     rc   dead rows            since
sim/mutate_gdn_block.sh     124  M01 M02 M03 M04 M05  (ANCHOR-FAILED printed in the VERDICT column)
sim/mutate_gdn_scalar.sh      0  B2 B3 B4 B5          (the C-model anchor, not the RTL one)
sim/mutate_attn_kv_axi.sh     0  B3 P1 P2             6c9aa09, 2026-08-29
sim/mutate_async_fifo.sh      0  O1
sim/mutate_seq_tbl_shape.sh   0  N1
sim/mutate_matvec_core.sh   124  D3                   (LOWER BOUND, timed out)
sim/mutate_mv4i_desc_stale.sh 2  the whole harness    3ecc729, 2026-08-30
```

**Fifteen dead rows in six harnesses, plus one harness dead outright, and every
one of those harnesses exits 0 or times out -- so nothing anywhere says so.**
TRACK MUTAUDIT's inventory covered six harnesses; TRACK REANCHOR's anchor replay
covered five; TRACK CBANCHOR's covered one.  **None of the three ever replayed
the other fifty-odd**, and the manifest they all worked from audits the
MECHANISM by which a harness reports a dead anchor, never whether it has one.

`attn_kv_axi`'s three are the cheapest to fix and the most instructive.  `6c9aa09`
("the real KV map did not work, and `to_integer` of a 4.5 GB address is why")
replaced `to_integer(x) mod N` with `low_bits(x, k)` throughout:

```
B3 anchors on   to4k := (4096 - (to_integer(a) mod 4096))/BEAT_B;
today's RTL     to4k := (4096 - low_bits(a, 12))/BEAT_B;                 (:445)
P1 anchors on   ph_ch   <= (to_integer(a0) mod BEAT_B)/CH_B;
today's RTL     ph_ch   <= low_bits(a0, BEAT_LW)/CH_B;                   (:848)
P2 anchors on   ar_addr <= a0 - to_unsigned(to_integer(a0) mod BEAT_B, ADDR_W);
today's RTL     ar_addr <= a0 - to_unsigned(low_bits(a0, BEAT_LW), ADDR_W);  (:849)
```

**Three rows guarding the 4 KB burst boundary and the record-phase alignment
have been absent for twenty-two days, killed by the commit that fixed the
address arithmetic they exist to guard** -- which is section 4.4's `fk33_seam`
M9 finding exactly (*"the row had been silently absent for two days, over a fix
to the ack path itself"*), in a second place, and found only by invoking the
script.

**THE COUNT IS A LOWER BOUND AND THE SWEEP'S OWN LIMITS ARE THE REASON.**
32 of the 63 did not finish in 30 s, so any dead row they would have printed
later is not in this table; `matvec_core` and `gdn_block` are both in that state
AND already showing dead rows.  One harness, `sim/mutate_a_wbase.sh`, was NOT run
at all: it takes a snapshot directory and a scratch directory as `$1 $2`, so the
sweep's single argument produced `line 37: 2: scratch dir` -- **a usage error
that the first pass of this table recorded as DEAD.**  A sweep that invokes 63
heterogeneous scripts one way will mis-call the ones that want another, and the
mis-call looks exactly like the finding you are hunting.

## 9.6 Why most of these must NOT become gate rows

The obvious reading of 9.2 is "wire them".  The measurements say otherwise, and
the decisive one is free to take:

```
$ for f in sim/mutate_*.sh; do grep -vE '^[[:space:]]*(#|$)' "$f" | tail -1; done

mutate_attn_emit.sh       echo "scratch dir with every mutant and every log: $SCRATCH"
mutate_gdn_recur.sh       echo "scratch dir with every mutant, its vectors and its log: $SCRATCH"
mutate_seq_opdec.sh       echo "scratch dir with every mutant and every log: $SCRATCH"
... 49 of 63 end this way ...
mutate_rmsnorm_rs_mem.sh  exit $(( fails > 0 ))
mutate_rmsnorm_bf_mem.sh  exit $(( fails > 0 ))
mutate_swiglu_mem.sh      exit $(( fails > 0 ))
mutate_rmswire.sh         exit ${RW_RC:-0}
mutate_gain.sh            exit $RC
```

**A script whose last statement is `echo` exits 0 whatever it printed.**  Forty-
nine of the sixty-three are in that state, and 48 have no non-zero exit in their
last 40% at all, so for them "wire it" is not a `regress.sh` edit at all -- it is "write an exit contract, teeth-test it, then
wire it", and the exit contract is the whole job.

Of the fifteen with a late non-zero exit, **eight of them exit on a dead ANCHOR,
not on a wrong VERDICT**.  Quoted, because the distinction is invisible from the
exit code:

```
mutate_matvec_cb.sh:842     "=== ROWS THAT DID NOT RUN:$n ==="        ... exit 1
mutate_llama_top_kv.sh:826  "=== ROWS THAT DID NOT RUN: $n ==="       ... exit 1
mutate_attn_block.sh:361    "Z0 SELF-TEETH DID NOT FIRE"              ... exit 1
mutate_attn_block.sh:366    "$NBAD row(s) BADMUT"                     ... exit 1
mutate_normw.sh:212,216     the same two                              ... exit 1
mutate_a_geom.sh:153,158    the same two                              ... exit 1
mutate_attn_score_hdr.sh, mutate_attn_score_early.sh,
mutate_attn_sweep_pipe.sh   the same two                              ... exit 1
```

against a VERDICT exit:

```
mutate_rmsnorm_rs_mem.sh:78  if [ "$exp" != UNKNOWN ] && [ "$v" != "$exp" ]; then
                               v="$v!EXP=$exp"; fails=$((fails+1)); fi
mutate_rmsnorm_rs_mem.sh:83  exit $(( fails > 0 ))
```

**So a gate row on `mutate_matvec_cb.sh` would catch the nine dead anchors TRACK
CBANCHOR fixed and would NOT catch a property being lost** -- which is worth
having, and is worth having under its own name rather than under the name
"mutation coverage in CI".

## 9.7 Measured runtimes, and the selection rule that follows

MEASURED 2026-09-20, `/usr/bin/time -v`, serial, one at a time:

| harness | wall | peak RSS | rc | exit contract |
|---|---|---|---|---|
| `mutate_ref_seq_vec_res.sh` | 1.9 s | 30,336 kB | 0 | none (ends in echo) |
| `mutate_ref_attn_rope.sh` | 2.0 s | 35,052 kB | 0 | none |
| `mutate_kv_map.sh` | 6.9 s | 24,596 kB | 0 | none |
| `mutate_a_geom.sh` | 13.0 s | **2,237,328 kB** | 0 | anchor-ledger |
| `mutate_eng_cdc.sh` | 17.8 s | 66,304 kB | 0 | none |
| `mutate_rmsnorm_bf_mem.sh` | **46.0 s** | 18,192 kB | 0 | **verdict** |
| `mutate_rmsnorm_rs_mem.sh` | **56.3 s** | 18,272 kB | 0 | **verdict** |
| `mutate_swiglu_mem.sh` | 495.8 s | 18,408 kB | 0 | **verdict** |
| `mutate_mv4i_desc_stale.sh` | 0.01 s | 5,184 kB | **2** | hard error, section 9.5 |
| `sim/check_mutation_harness.py` | 0.02 s | 11,712 kB | **1** | see 9.8 |

Two things in that table are worth reading twice.

**`mutate_a_geom.sh` peaks at 2.24 GB in thirteen seconds.**  `CLAUDE.md` gives
2.13 GiB as the figure for the FULL both-suite gate, and TRACK CBANCHOR measured
its own three-row mutation run at 175 MB and recorded that a targeted run does
not inherit the gate's number.  Both remain true and **a single 13-second
harness exceeds the whole gate's peak**, so neither figure bounds an arbitrary
harness.  Measure the one you are about to run.

**`mutate_swiglu_mem.sh` is 496 s for the same contract that costs 46 s next
door.**  It is a LANES matrix (1, 2, 4) over 19 rows; the two rmsnorm harnesses
are one geometry over 10 and 14.  Identical shape, an order of magnitude apart,
and nothing on the outside says so.

The selection rule, stated so it can be argued with: **a harness earns a gate
row when it has a VERDICT-derived exit code, runs in under 60 s, peaks under
100 MB, and guards RTL that ships.**  Exactly two of the 63 satisfy all four:
`mutate_rmsnorm_rs_mem.sh` and `mutate_rmsnorm_bf_mem.sh`.  Total 102.3 s, which
is +2.1% on the MEASURED 82m09s full run recorded in `regress.sh`'s own
`BASELINE_PASS` comment.

The third recommended row is `sim/check_mutation_harness.py` at 0.02 s, which
covers all 63 at the text level and is the only cheap thing that could have
caught section 9.5 -- had it been looking for that, which it is not (9.8).

## 9.8 `sim:mutaudit` STILL must not be wired, and now it FAILS on the workstation and PASSES on a clean tree

Section 6b recorded this checker passing on the workstation and failing on a
fresh clone.  Today it is the other way round, at the SAME commit:

```
$ cd <shared checkout @ 9435942> && python3 sim/check_mutation_harness.py
FAIL R1: sim/mutate_gain.sh is not in sim/mutation_harness_audit.tsv.
checked 63 harnesses; 1 finding(s)                                    rc 1

$ git worktree add --detach <wt> 9435942 && cd <wt> && python3 sim/check_mutation_harness.py
checked 62 harnesses; 0 finding(s)                                    rc 0
```

Same commit, same code, opposite verdict, decided entirely by whether an
UNTRACKED file is sitting in `sim/`.  R1 builds its list with `os.listdir`.
`sim/mutate_gain.sh` is TRACK GAINTEETH's and was being written while this ran
(mtime 18:57 on the day).  **Deliberately not fixed here, for the reason
sections 6b and 8.12 both give: the file belongs to a live track**, and this is
now the third consecutive track to decline it, which is itself the finding.  The
two exits are stated in the patch header; (b), making R1 read `git ls-files` and
report an untracked harness as a NOTE, fixes the class rather than the day.

**And note what it would NOT have caught.**  `check_mutation_harness.py` audits
the MECHANISM by which a harness reports a zero-match anchor.  It read
`sim/mutate_mv4i_desc_stale.sh`, classified it GUARD correctly, and has no way
to notice that the harness exits 2 on every invocation.  **A text audit of an
error path cannot tell you the error path is the only path.**

## 9.9 Two committed gate rows are RED at HEAD, and one of them is red because of a single word in a comment

Found while checking whether the rows that ARE wired exercise what they claim.
Both reproduce in a clean detached worktree at `9435942`, so neither is another
track's dirty working tree:

```
c4stale    rc=1  COMPOSE4_STALE hw/fk33/rtl/compose4_top.vhd differs from a fresh
                 generation (31 diff lines)
shapechk   rc=1  SHAPE_FAIL no generic clause on entity attn_block in rtl/attn_block.vhd
```

`c4stale` is a true staleness: `56d13e3` added `dbg_sw_ph` and `dbg_sw_aux` to
`attn_block` and `compose4_top.vhd` was not regenerated.  It belongs to C's
owner.

**`shapechk` is not.**  `rtl/attn_block.vhd` has a perfectly good generic
clause; the checker's entity regex is

```python
re.search(r"\bentity\s+" + entity + r"\s+is\b(.*?)\bend\b", src, re.S | re.I)
```

and `56d13e3` added a comment INSIDE the generic clause, at line 293:

```
    -- end: SCORE_EARLY moves the pass earlier, this SHORTENS it.
```

`\bend\b` matches that comment, the entity body is truncated before the generic
clause closes, and the generic regex then finds nothing.  MEASURED both ways, in
the clean worktree, changing ONE WORD OF ONE COMMENT and no code:

```
committed text:  SHAPE_FAIL no generic clause on entity attn_block            rc 1
`end:` -> `:`    SHAPE_OK 13 literals agree with model_cfg_pkg (MODEL at
                 NCARDS=1): attn 16x4 hd=256 layers=8, gdn 16/32 hd=128 ...    rc 0
restored:        SHAPE_FAIL no generic clause on entity attn_block            rc 1
```

This is section 2's second cause -- *"a comment quoting the code inflated a
count"* -- in a new instrument: a comment containing a VHDL keyword truncates a
checker's parse.  **The design is correct, the row is red, and the red is
worth exactly nothing to anyone reading it.**  Same family as `gen_pcieep.py`'s
`\bllama_top\b` guard being satisfied by a comment, in the opposite direction:
there a comment made a check PASS, here a comment makes one FAIL.

Not fixed here: `sim/check_model_shape.py` is not this track's file and the RTL
belongs to a live track.  The fix is to strip `--` comments BEFORE the entity
search, which the same function already does one line later for the generic
body.

## 9.10 A row that is the identity at every geometry, not just at the default

TRACK CBANCHOR found `K10a` to be literally the identity at the harness's
default (`CB_RANKS := CB_COPIES` with `CB_COPIES=4`).  The same class, found by
reading a SURVIVED row:

`xwswap` in `sim/mutate_rmsnorm_rs_mem.sh` and `sim/mutate_rmsnorm_bf_mem.sh`
swaps x and w across the two pipeline registers:

```
p1_xinv(k) <= resize(x_q(k) * inv32, 48);   ->   resize(w_q(k) * inv32, 48);
p1_wm(k)   <= resize(w_q(k), 17);           ->   resize(x_q(k), 17);
```

and the very next stage is `p2_raw(k) <= resize(p1_xinv(k) * p1_wm(k), 64)`.
`x_q` and `w_q` are BOTH `signed(15 downto 0)` (`rtl/rmsnorm_rs_mem.vhd:269`),
so both resizes are sign extensions and both products are exact.  **The mutant
computes `w*inv*x` where the design computes `x*inv*w`.  It is the identity by
commutativity, at every geometry, and no bench can ever kill it.**

It is NOT a defect of the harness: both rows are declared `UNKNOWN`, and line 78
skips `UNKNOWN` rows when counting failures, so neither contributes to the exit
code.  **It IS a defect of any kill-ratio read off the table**, which counts
them in the denominator: `mutate_rmsnorm_rs_mem.sh` is 7 pinned rows of 10, and
`mutate_rmsnorm_bf_mem.sh` 10 of 14.  Recorded so the three UNKNOWN and four
UNKNOWN rows are read as the resolution floor rather than as misses.

## 9.11 Measured and REJECTED -- do not retry

- **Wiring all 63, or even all of the cheap ones.**  52 have no exit contract,
  so 48 of those rows would be green forever.  The gate is 82m09s of shared cost
  paid by every track on every run; a row that cannot go red is pure cost.
- **Reading `grep -n mutate sim/regress.sh` as the answer.**  It gives the right
  verdict for the wrong reason: 20 hits, all comments, and it cannot see an
  indirect invocation.  The closed dispatch set is what proves it.
- **Trusting an execve trace at strace's default string length** (9.4).  It
  reported the expected answer and was wrong.  `-s 300` or better.
- **Wiring `sim:mutaudit` today.**  It is RED on this workstation right now,
  because of another track's untracked file, and would go red on its first CI
  run naming a file nobody touched.  Third track to decline this; see 9.8.
- **Fixing `sim/check_model_shape.py`'s regex here** (9.9).  It is not this
  track's file, the gate was live for two other tracks, and the RTL that
  triggers it belongs to a third.  Reported with the one-word discriminator so
  the owner does not have to re-derive it.
- **A generic anchor-liveness gate row over all 63.**  This is the thing that
  would actually have caught 9.5 and every finding in sections 1-8, and it is
  NOT buildable as a `regress.sh` line today: TRACK REANCHOR's stubbed replay
  works by sed-ing each harness's own row function to `return 0`, and the
  function is called `run_case` in one harness, `run_row` in another, `row`,
  `run_cap`, `mrow` elsewhere.  Doing it for 63 heterogeneous harnesses is a
  track, not a patch hunk.  Named here as the highest-value follow-on rather
  than sketched as if it were free.

## 9.12 Open, not determined

- **How many dead rows the other 32 harnesses hold.**  The 30 s sweep (9.5b)
  found fifteen, and 32 of 63 harnesses did not finish inside it, so fifteen is a
  floor and not a count.  `sim/mutation_harness_wiring.tsv` records which is
  which; `TIMEOUT(30s)` is NOT evidence that a harness is alive.
- **`sim/mutate_a_wbase.sh` was never run** (9.5b).  It needs a snapshot tree
  containing `rtl/llama_top.vhd`, which is TRACK ATTNWIRE's file today.
- **The runtime of 54 harnesses is unmeasured.**  Nine were timed; the rest are
  classified by the bench they drive, which is DERIVED and, as `swiglu_mem`
  shows at 496 s against `rmsnorm_bf_mem`'s 46 s, a weak predictor.
- **Whether the two recommended harness rows actually go red when they should.**
  Both exit on `fails > 0` and both printed `: 0` on a clean tree, so the zero
  branch is MEASURED and the one branch is not.  The teeth test is written into
  the patch header and was not run here, because breaking an anchor in a shared
  file while four tracks are live is the hazard this project has recorded.
- **Whether `sim:c4stale` being red at HEAD is known to C's owner.**  Not
  communicated by this track beyond this document and the WORKLOG.
- **`sim/mutate_a_wbase.sh` takes a SNAPSHOT directory as `$1` and restores from
  a `.basefab_pristine` file inside it that is created only `if [ ! -f ]`.**  It
  never touches the repo, so it is safe -- but a snapshot directory reused
  across sessions restores a stale `llama_top.vhd` into itself.  Noticed while
  checking whether any harness writes into the working tree (none does); not
  investigated further.
