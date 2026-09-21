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
- **Nine re-anchored rows have verified anchors and no verdict yet.**  The
  `tb_llama_top` rows cost about 13 minutes each and the budget for this track
  ran out: `llama_top_kv` R7, R7b, R8, VR7, VR7b, VN2 and `rmswire` R5b, R8 are
  re-anchored and replay-clean at HEAD and in the working tree, but have not
  been RUN.  Their dispositions are DERIVED from the legend and the RTL, not
  MEASURED.  See the per-row table in the WORKLOG entry for which is which.
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
