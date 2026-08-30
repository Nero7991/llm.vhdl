# The gate floor after four rows landed, and three small defects

**Track:** TRACK FLOOR. **Date:** 2026-08-29. **Tree:** `b6c5004` measured,
landed on top of it.

---

## 1. The question, verbatim

> Tonight added at least **four** new gate rows -- `sim:graygate` (TRACK GRAY1),
> `sim:runguard`, `sim:ipsync`, `sim:descrule` (TRACK NOGUARD) -- plus two
> OPTIONAL rows from TRACK ACOV. **Every one of those tracks deliberately left
> `BASELINE_PASS` at 93, and every one was right to** [...] **The consequence is
> that the floor is now well below the ceiling, and a floor that low cannot
> detect a regression.**
>
> 1. Wait for the box to be quiet, then run ONE clean full gate and measure the
>    real ceiling. 2. Measure BOTH numbers. 3. Raise `BASELINE_PASS` to the
>    measured clean ceiling. 4. Note `regress.sh` refuses to let OPTIONAL rows
>    raise the floor.

Plus three defects found and flagged, not fixed: the two IP packaging scripts
that exit non-zero after succeeding; the stale comment in
`tools/lmhead_window_check.py`; and the dead `frst <= rst;` in
`rtl/axi_rd_port.vhd`, which this track was told to record and NOT fix.

---

## 2. The answer, up front

**The clean ceiling is 98, not the 97 that tonight's accounting implies, and
`BASELINE_PASS` is now 98** (`b60591d`). MEASURED on a clean `git archive` of
`b6c5004` with `MV4I_FK33_FILE=/nonexistent`, `--jobs 2`, GHDL 1.0.0 mcode:
`OVERALL PASS 98 FAIL 0 NOVERDICT 0 TIMEOUT 0 BUILD-ERROR 0 NOCHECK 4
SKIPPED 10`, 102 rows selected, so 98 is the ceiling and not merely the score.

**FIVE floor-eligible rows landed tonight, not four.** The fifth is
`sim:tb_attn_kv_map`, a committed 1076-line bench from TRACK CKVMAP (`6c9aa09`)
that appears in no floor accounting, including the brief for this track. It was
found only because 93 + 4 = 97 disagreed with the measured 98 by exactly one.
**Had the floor been reasoned to instead of measured, it would have been set at
97 -- one below the ceiling, with nothing able to reveal the miss.**

**TRACK ACOV's two new rows correctly cannot raise the floor.** `tb_prereq`
classes all four `sim:tb_matvec_fk33*` rows OPTIONAL because they need a `.mv4i`
from the GGUF model set. They SKIP on a clone, which is exactly why `SKIPPED`
went 8 -> 10 while the floor went 93 -> 98.

**The box never became quiet, and waiting for it was the wrong plan.** Section 4
records why. The run was taken under load 6.4-10.1 and that is defensible in one
direction only: contention can starve a row into `TIMEOUT`, but it cannot make a
failing row pass, so a contended clean run is a valid LOWER BOUND on the ceiling
-- conservative, never unreachable, which is the precise defect `101` had. Here
`TIMEOUT 0` and `FAIL 0`, so the bound is tight.

The three flagged defects: the two packaging scripts are FIXED and their exit
status is now verified in both directions; the stale comment is WITHDRAWN in
place; the dead `frst` is CONFIRMED still dead and RECORDED, not fixed, because
`rtl/**` was outside this track's ownership. A fourth defect was created by
fixing the first and is likewise recorded rather than reached for.

---

## 3. The three defects

### 3.1 Both IP packaging scripts exited non-zero AFTER writing a correct IP

`hw/package_mac_axi.tcl:21` and `hw/package_matvec_engine.tcl:23` both ended in

```tcl
puts "CLOCK_ASSOC: [get_property CONFIG.ASSOCIATED_BUSIF [ipx::get_bus_interfaces s_axi_aclk -of_objects $core]]"
```

placed **after** `ipx::save_core`. TRACK NOGUARD measured that this raises
`Unknown property 'CONFIG.ASSOCIATED_BUSIF' on bus_interface` and could not edit
the two files.

**The cause: two different spellings for the same concept, and only one of them
is an `ipx` property.** In a BLOCK DESIGN the association is a `CONFIG.*`
property of a pin, and `hw/fk33/build_fk33_pcieep.tcl:904` reads it correctly
that way with `get_bd_pins`. In the IP PACKAGER the same thing is an IP-XACT
**bus parameter** on the clock's bus interface. It is visible as such in the
packaged artefact:

```
$ grep -n -A2 'ASSOCIATED_BUSIF' ip_repo/mac_axi_1_0/component.xml
209:          <spirit:name>ASSOCIATED_BUSIF</spirit:name>
210:          <spirit:value spirit:id="BUSIFPARAM_VALUE.S_AXI_ACLK.ASSOCIATED_BUSIF">s_axi</spirit:value>
```

**MEASURED**, Vivado 2023.2, by packaging `mac_axi` into a scratch root and
reading the value back three ways in one run (`catch` around each, so all three
report rather than the first aborting):

```
PROBE_A_OBJ: bus_interface component_1 s_axi_aclk
PROBE_B_CONFIG rc=1 res=ERROR: [Common 17-69] Command failed: Unknown property 'CONFIG.ASSOCIATED_BUSIF' on bus_interface
PROBE_C_BUSPARAM_VALUE rc=0 res=s_axi
PROBE_D_BARE rc=1 res=ERROR: [Common 17-69] Command failed: Unknown property 'ASSOCIATED_BUSIF' on bus_interface
PROBE_DONE
```

So the correct read is

```tcl
get_property VALUE [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $clkif]
```

**Teeth check, same harness, exit status this time** (the probe above used
`catch` and so could not have observed the non-zero exit that is the actual
defect). Both scripts run with `set root` redirected into a throwaway
`git archive` tree, so the real `ip_repo/` was never written:

```
===== NEGATIVE CONTROL: pre-fix package_mac_axi.tcl =====
OLD_RC=1
41:Unknown property 'CONFIG.ASSOCIATED_BUSIF' on bus_interface
42:ERROR: [Common 17-69] Command failed: Unknown property 'CONFIG.ASSOCIATED_BUSIF' on bus_interface
===== FIXED: package_mac_axi.tcl =====
FIXED_MAC_RC=0
47:CLOCK_ASSOC: s_axi
49:PACKAGE_DONE 1

FIXED_MV_RC=0
51:CLOCK_ASSOC: s_axi
53:PACKAGE_DONE 1
```

The negative control is the load-bearing row: it shows the pre-fix script
reaching neither `CLOCK_ASSOC` nor `PACKAGE_DONE` and exiting 1, which is
exactly the shape that makes a success look like a failure.

**The fix is a refusal, not just a corrected `puts`.**
`ipx::associate_bus_interfaces` is precisely the kind of call that can do
nothing quietly, and if it does, every AXI interface downstream defaults to
100 MHz. So the readback now `error`s unless the value is `s_axi`, matching what
`build_fk33_pcieep.tcl:906` already does for the block-design spelling. Before
this change the line was decoration that could only ever abort the script;
now it is a check with teeth, on the healthy path as well as the broken one.

**Confirmed the real `ip_repo/` was not touched:** `git status --porcelain
ip_repo/` empty, and both `component.xml` mtimes are 21:39/21:40, predating
this track's first Vivado invocation at ~22:00.

### 3.2 `tools/lmhead_window_check.py` documented a defect that had been fixed

The comment at `:66-80` said `check_bases` "refuses every C-packed file",
because rule 2 (`sub_offsets_from_layout`) encoded the TIGHT layout while
`ref/matvec_int4.c`'s `pack_geom` 4 KB-aligns every sub-region.

That was true when written and is false now: TRACK NOGUARD's `3f23a46` gave
rule 2 its own `layout_strides`, which applies `align4k` and gives the scale
region its own stride.

**MEASURED** by running the `sim:descrule` gate row's own command,
`python3 tools/gen_mv4i_desc.py --selftest`:

```
row           expect   corrected  old-rule2  attribution
--------------------------------------------------------------------
COINCIDE      agree    agree      agree      BOTH (this is the coincidence)
COINCIDE_BIG  agree    agree      agree      BOTH (this is the coincidence)
COINCIDE_K3   agree    agree      agree      BOTH (this is the coincidence)
NONALIGN      agree    agree      refuse     CORRECTED RULE ONLY
GRP2          agree    agree      refuse     CORRECTED RULE ONLY
SWAP          REFUSE   refuse     refuse     both refuse
SHIFT_W       REFUSE   refuse     refuse     both refuse
SHIFT_S       REFUSE   refuse     refuse     both refuse
UNPADDED      REFUSE   refuse     agree      CORRECTED RULE ONLY
RAISES        4        4          -          check_bases stops rather than merely disagreeing
VD            VOID     VOID       -          not an .mv4i at all
--------------------------------------------------------------------
CORRECTED RULE ALONE=2  (rows the old tight rule got wrong)
SELFTEST PASS
```

`NONALIGN` and `GRP2` are exactly the unaligned geometries the stale comment
described, and they are now `agree`.

**Corrected in place rather than deleted**, because a note describing a fixed
defect reads as a live limitation and would tell the next reader the guard is
weaker than it is. The replacement states what is still true (the tool is
exercised against `pack_int4.py` tensors) and, explicitly, what is **NOT**
verified: only the stated OBSTACLE to using `--emit` has been measured away.
Nobody has tried `--emit`, and the new comment says so rather than implying the
route is now open.

### 3.3 `frst <= rst;` in `rtl/axi_rd_port.vhd`'s `g_sc` generate is dead -- RECORDED, NOT FIXED

`rtl/**` was outside this track's ownership, so this was verified and written
down rather than touched.

**RE-MEASURED** by enumerating every occurrence of the signal in the file:

```
$ grep -n 'frst' rtl/axi_rd_port.vhd
157:  signal frst    : std_logic;
203:    frst    <= rst;
241:    frst  <= rst_s2;
282:      port map(clk => aclk, rst => frst, start => start_f,
292:      port map(wclk => aclk, wrst => frst,
```

`:203` is inside `g_sc : if not DUAL_CLK generate`; `:241`, `:282` and `:292`
are all inside `g_dc : if DUAL_CLK generate`. **Both reads are in `g_dc`.**
Exactly one generate elaborates, so under `DUAL_CLK = false` the signal is
driven and never read. The `g_sc` FSM and FIFO both take `rst => rst` directly
(`:210`, `:223`).

Harmless to the netlist -- synthesis drops a dangling driver -- but it reads as
though the single-clock branch has a FIFO reset that is used, and it is a
mutation site no bench can cover, which is why TRACK ACOV scored it as row `B1`.

**This is the third time it has been found** (ACOV, then the dispatcher's brief,
now here), which is why it is on the board's Open-issues table as `AXIRD-FRST`
rather than only in a write-up. The entry carries the warning that the safe
deletion is `:203`; deleting `:241` instead breaks the dual-clock path.

### 3.4 A fourth defect, created by fixing the first, and also recorded not fixed

`ip_repo/check_ip_sync.py`'s docstring cites the packaging-script defect of 3.1
as a live worked example of what that checker cannot catch. Fixing 3.1 makes
that example stale -- the same trap as 3.2, one hour later and self-inflicted.
`ip_repo/**` was outside this track's ownership, so it is recorded on the board
as `IPSYNC-DOC`. The surrounding "honest weakness" paragraph is still correct
and must NOT be deleted with the example.

---

## 4. The floor: procedure and evidence

### 4.1 What each step controls for

1. **`bash sim/regress.sh --list` on the working tree, first.** Runs no
   simulation, ~2 s, and prints the NOT-IN-GIT section. This answers "is my
   gate reproducible?" before spending 25 minutes finding out that it is not.
   It measured **18 untracked rows and 3 untracked sources** on this
   workstation, which is why the working tree cannot set the floor.
2. **`SHA=$(git rev-parse HEAD)` as its own step**, then `git archive $SHA`.
   The archive is the control: it is frozen, so no other track's in-flight edit
   can reach it, which removes the single most common false-failure mode on
   this box.
3. **`MV4I_FK33_FILE=/nonexistent`.** Forces the four OPTIONAL rows to SKIP, so
   the number does not depend on whether the machine happens to have the GGUF
   model set. This is what makes the figure portable.
4. **Verify `REGRESS_REPO` on the LIVE process**, not by reading the script.
   See the trap in section 6 -- this was the one step that could have silently
   turned the whole measurement into a working-tree number.
5. **Itemise the delta against the previous floor's sha** rather than accepting
   the total. This is the step that found the fifth row.

### 4.2 The clean archive -- the number the floor is set from

Unfiltered last `OVERALL` line and the two lines after it:

```
 suite sim   PASS 72   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 3
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 98   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4   SKIPPED 10
 baseline: 98 passing, above the recorded floor of 93 -- raise BASELINE_PASS in this script
 REGRESSION: PASS
```

The wording of the `baseline:` line is itself evidence. The gate emits the
SUGGESTION only when `UNTRACKED_ROWS`, `IGNORED_ROWS` and `OPTIONAL_ROWS` are
all empty; otherwise it emits the refusal that begins "DO NOT raise
BASELINE_PASS from this run". Getting the suggestion is therefore an
independent confirmation that this tree was clean, obtained without trusting
the `--list` output from step 1.

### 4.3 The five rows, and finding the fifth

All five are tracked, all five PASSED on the clean archive:

```
PASS       sim:tb_attn_kv_map                     1s  .../arch/sim/tb_attn_kv_map.vhd
PASS       sim:graygate                           1s  GRAY_CHECK: PASS  (13 widths, pointer 2..14 bits, all exhaustive)
PASS       sim:runguard                           0s  SELFTEST PASS
PASS       sim:ipsync                             0s  IPSYNC: PASS
PASS       sim:descrule                           1s  SELFTEST PASS
```

The prediction was 93 + 4 = **97**. The measurement was **98**. Chasing the
one-row disagreement:

```
$ git diff --stat 9ad4c14..b6c5004 -- 'sim/tb_*.vhd'
 sim/tb_attn_kv_map.vhd           | 1076 ++++++++++++++++++++++++++++++++++++++
 ...
$ git log --oneline --diff-filter=A -1 -- sim/tb_attn_kv_map.vhd
6c9aa09 attn_kv_axi: the real KV map did not work, and to_integer of a 4.5 GB address is why
```

**A new `sim/tb_*.vhd` becomes a gate row whether its author intended it or
not**, because the planner globs the filesystem. TRACK CKVMAP added a bench as
part of an RTL fix and, entirely reasonably, was not thinking about the floor.
Nothing in the process would have caught this: the row was green, so it never
announced itself.

### 4.4 The OPTIONAL set, confirmed rather than assumed

```
tb_prereq() {   # <suite:name> -> a path that must be readable, or the row skips
  case "$1" in
    sim:tb_matvec_fk33|sim:tb_matvec_fk33_desc|\
    sim:tb_matvec_fk33_desc_dual|sim:tb_matvec_fk33_desc_xexp)
      echo "${MV4I_FK33_FILE:-/mnt/storage/llama-models/qwen35-9b-mv4i/blk.11.attn_k.weight.mv4i}" ;;
    *) : ;;
  esac
}
```

The OPTIONAL set is exactly these four. Both of ACOV's new rows
(`_desc_dual`, `_desc_xexp`) are in it and neither can raise the floor.
Tonight's other four rows have no prereq and are floor-eligible. `SKIPPED`
moving 8 -> 10 is the arithmetic tell that both ACOV rows skipped as intended.

### 4.5 The working tree -- measured, and deliberately NOT used for the floor

Second run, same HEAD, no `MV4I_FK33_FILE` override, against the live shared
tree with three other tracks' files dirty in it. Unfiltered last `OVERALL`:

```
 suite sim   PASS 80   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 106   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 106 passing, above the floor of 98 -- but this tree has rows a clean checkout does not get: sim:tb_attn_cmp2 sim:tb_attn_fix_beh sim:tb_attn_probe_cmp sim:tb_attn_replay sim:tb_attn_replay_beh sim:tb_divprobe_cmp sim:tb_embed_ps sim:tb_engine_dump sim:tb_lm_head_ps sim:tb_matmul_rt_ps sim:tb_rms_real sim:tb_rms_sweep sim:tb_rmsnorm_ps sim:tb_rope_ps sim:tb_sm_cmp sim:tb_sm_cmp24 sim:tb_softmax_ps sim:tb_swiglu_ps sim:tb_matvec_fk33 sim:tb_matvec_fk33_desc sim:tb_matvec_fk33_desc_dual sim:tb_matvec_fk33_desc_xexp.  DO NOT raise BASELINE_PASS from this run: the floor is a CLEAN-CHECKOUT number, and a floor raised to include rows that depend on your working tree or your model set is unreachable for everybody else, including you after a clean clone.
 REGRESSION: PASS
```

**This is the refusal working exactly as GATEHYGIENE designed it**, and it is
the reason 98 and not 106 is the floor. Note the new floor is already in force
in that line: "above the floor of 98".

**The 8-row surplus decomposes exactly, which is how you know nothing is
unexplained.** MEASURED from the run's own per-row lines:

```
untracked rows that PASSED (4):
  sim:tb_attn_fix_beh        2s   PASS:attn_replay netlist matches behavioral
  sim:tb_attn_replay_beh     1s   PASS:attn_replay netlist matches behavioral
  sim:tb_engine_dump       103s   PASS:engine_shared 6/6 tokens match
  sim:tb_rope_ps             1s   PASS:rope  max_dev=1
OPTIONAL rows that PASSED, this box having the model set (4):
  sim:tb_matvec_fk33            10s
  sim:tb_matvec_fk33_desc       49s
  sim:tb_matvec_fk33_desc_dual  53s
  sim:tb_matvec_fk33_desc_xexp  54s
```

98 + 4 + 4 = **106**. The remaining named rows SKIP, and the one untracked
`NOCHECK` (`sim:tb_rms_sweep`) is why `NOCHECK` reads 5 here against 4 on the
archive. `SKIPPED` 19 = the archive's 10, minus the 4 `mv4i` rows that now run,
plus 13 untracked rows that cannot resolve.

**`FAIL 0` on the working tree is worth noting given what was in it.** This run
was taken against the live shared tree with `rtl/gdn_block.vhd`,
`sim/tb_matvec_int4.vhd` and `hw/design_mv_generated.tcl` dirty from three other
tracks, under load 8-9, and nothing went red. That is a data point about tonight
specifically, **not** a general licence to gate on the working tree.

---

## 5. Measured and REJECTED -- do not retry

**Waiting for a quiet box. REJECTED as a plan, not merely as a preference.**
The brief said to wait for quiet and, if quiet could not be had, to say so.
MEASURED at 22:01 by reading `/proc` and `ps`: TRACK NWROM had started a VU33P
synthesis 3m50s earlier (`/mnt/storage/nwrom/out/vivado_nw_bnd65.log`, a
`parallel_synth_helper` with four `task_worker` children), and **two other full
regressions were already running against the real repo** -- confirmed by reading
`REGRESS_REPO` out of `/proc/<pid>/environ` for every live `regress-self`
process:

```
pid 1859570:  REGRESS_REPO=/home/orencollaco/GitHub/llama.vhdl
pid 2473849:  MV4I_FK33_FILE=/nonexistent
              REGRESS_REPO=/tmp/.../TRACK_FLOOR/arch      <- this track
pid 2536074:  REGRESS_REPO=/home/orencollaco/GitHub/llama.vhdl
```

Load never dropped below 5.7 and rose to 10.1 during the run. On an overnight
four-track session the box is quiet only by accident, so "wait for quiet" is
not a schedulable step. **Use the asymmetry argument instead** (section 2): a
contended CLEAN-ARCHIVE run bounds the ceiling from below, which is the safe
direction for a floor. Do not spend a night waiting.

**`get_property CONFIG.ASSOCIATED_BUSIF` on an `ipx` bus_interface.**
rc=1, `Unknown property`. This is the block-design spelling. Do not retry.

**Bare `get_property ASSOCIATED_BUSIF` on an `ipx` bus_interface.** rc=1,
`Unknown property`. Tried because it is the obvious next guess after the
`CONFIG.` prefix fails. Do not retry.

**Raising the floor from a working-tree run.** The gate refuses, and the
refusal is correct: 18 untracked rows on this workstation. The refusal was not
worked around and must not be.

---

## 6. Measurement traps hit, including my own

**I nearly measured the working tree and called it the archive.** `regress.sh`
re-execs itself from a private temp copy, so `${BASH_SOURCE[0]}` inside the
running process is `/tmp/regress-self.XXXX.sh` and tells you nothing about which
repo is under test. Had `REGRESS_REPO` been resolved after the re-exec, or
inherited from the environment, invoking the archive's copy would have silently
tested the real tree and produced a number that looked clean and was not. It is
resolved before the re-exec and exported, which is correct -- but I confirmed it
by reading `/proc/2473849/environ` on the live process rather than by reading
the source, because this is precisely the class of thing where the code and the
running reality can differ. **Check what the process is doing, not what the
script says it does.**

**My prediction was wrong and I nearly did not check it.** 93 + 4 = 97 was
derived from the brief and from `tb_prereq`, both of which I had verified, so
the reasoning felt closed. The measurement said 98. The house rule -- when a
measurement supports a conclusion you already hold, find the cheapest thing that
could refute it -- applies with more force in reverse: **when a measurement
disagrees with you by a small amount, that is the finding, not noise.** One row
is exactly the size of discrepancy that is easiest to wave away.

**`regress.sh` prints its table only at the end.** The log sat at four lines for
twenty-five minutes. Progress was tracked by counting `res.*` files in the
scratch directory (39 at 1 min, 74 at 15 min, 102 at exit), which is the only
usable liveness signal.

**I used `pgrep -f` on a pattern that appeared in my own command line.** The
house rule names `pkill -f` as the killer and I did not use it, but `pgrep -f
'regress-self'` from a command line containing that string is the same mistake
one step short of damage. It happened to be harmless because the result was only
used to read `/proc`. Recording it because the near-miss is the warning.

**A `git archive` tree is immune to one whole class of false failure and not to
another.** It cannot pick up another track's dirty file, so the "~15 MB RSS
analysis failure" tell will never fire in it. It is still fully exposed to
`TIMEOUT` from CPU starvation. Knowing which of the two you are protected from
is what makes a contended run interpretable rather than merely fast.

**A probe using `catch` cannot observe the defect that IS the exit status.** The
first Vivado probe wrapped all three property reads in `catch` so that one run
could report all three. That was right for identifying the correct idiom and
useless for the actual complaint, which was that the script exits non-zero. The
teeth check in 3.1 had to be a separate run with no `catch`, reading `$?`.

---

## 7. What was NOT verified

- **The floor was measured at `b6c5004`, and HEAD is now `b60591d`.** The two
  intervening commits (`d2adbcd`, `b60591d`) touch only `hw/*.tcl`, a Python
  comment, `docs/`, and `BASELINE_PASS` itself. MEASURED that none is a gate row
  or a gate input: `grep -n 'lmhead_window_check\|package_mac_axi\|package_matvec_engine' sim/regress.sh`
  returns nothing. So the row set is unchanged, DERIVED rather than re-measured.
  A confirming run at `b60591d` was not made.
- **Whether `ref/matvec_int4.c --emit` now works as a synthetic source** for
  `lmhead_window_check.py`. Only the stated obstacle was measured away. Nobody
  has tried it, and the corrected comment says so.
- **The two fixed packaging scripts were never run against the real
  `ip_repo/`**, deliberately: `ip_repo/**` was outside this track's ownership
  and the scripts begin `file delete -force`. They were exercised end to end
  against a throwaway `git archive` tree instead. **The regenerated IP was
  therefore never byte-compared with the committed one**, so this track has not
  shown that the fix leaves the packaged output identical -- only that the
  script now succeeds and reports the correct association.
- **`sim:ipsync` was not re-run after the packaging fix**, because the fix
  changes no packaged bytes. It passed on the clean archive before the change.
- **The dead `frst` was verified statically, not by mutation.** ACOV's `B1` row
  is the empirical evidence that no bench catches it; this track re-derived the
  same conclusion by enumerating every read of the signal. Both agree, but no
  mutant was run here.
