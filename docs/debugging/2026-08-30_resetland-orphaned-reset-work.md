# TRACK RESETLAND: rescuing TRACK RESETGUARD's interrupted work

2026-08-30. Base commit `3a2d0d0`. No hardware was touched, no Vivado was run.

## 1. The question, verbatim

> TRACK RESETGUARD was dispatched last night and killed mid-flight when the
> workstation hung. It never reported. It left 235 lines UNCOMMITTED in the
> working tree [...] Your job: read it, verify it, teeth-check it, and land it
> -- or report that part of it should not land, with reasons.
>
> **Do not assume it is correct because it looks finished.** It was
> interrupted, so it may be half-done in ways its own comments do not admit.

## 2. The answer, up front

**All of it lands, plus one file the brief did not know about, plus teeth the
interrupted track never wrote.**

| change | verdict |
|---|---|
| `rtl/axi_rd_port.vhd` -- delete the dead `frst <= rst;` in `g_sc` and move the `signal frst` declaration into `g_dc` | **LAND AS-IS.** Re-verified at HEAD: no reader of `frst` exists outside `g_dc`, anywhere in the repo. |
| `hw/fk33/gen_pcieep.py` -- `check_reset_topology`, `_bd_net_peers`, `_RESET_WHY` | **LAND AS-IS.** It refuses all 7 dangerous wirings tried and accepts both safe ones, and no pre-existing guard in the file catches any of the 7. |
| `sim/mutate_axi_rd_port.sh` -- delete mutation row `B1` and replace it with the lesson | **LAND. CORRECTION TO THE BRIEF: this is a THIRD orphaned file and it is not optional.** |
| `hw/fk33/build_fk33_pcieep.tcl`, `hw/fk33/fk33_pcieep.xdc` | **UNCHANGED.** MEASURED byte-identical after regeneration. The guard alters no artefact. |
| NEW, added by this track | `reset_topology_teeth()` in `gen_pcieep.py`, 10 rows, wired into `--selftest`. RESETGUARD shipped a checker with no evidence that it discriminates. |

**The interrupted work was not half-done. It was un-teeth-checked**, which is a
different and more specific defect: it is exactly the shape CLAUDE.md names as
its own class, a guard that has never been shown to fail on the thing it
guards.

### The exclusion in the guard is sound, and it is not a skip list

The brief asked whether excluding `hbm/AXI_00_ARESET_N` and
`hbm/AXI_16_ARESET_N` is a hole. It is not, for a reason better than the one
the code comment gives.

There is **no skip list in the code**. The scan iterates `ENG_PORT_MAP`, and
`0` and `16` are absent from it because a module-level `assert` at
`gen_pcieep.py:326` forbids them ("SAXI_00 and SAXI_16 belong to the host").
So the two excluded pins are excluded *by not being engine ports*, and the
failure mode for any future port that becomes branch-dependent is an **abort,
not a silent pass** -- `len(got) != 1` appends to `bad` and calls
`_reset_abort`. MEASURED (section 4.1): exactly two `ARESET_N` pins in the
emitted Tcl have two drivers, and they are exactly `00` and `16`; all 28
engine ports have exactly one. The exclusion is co-extensive with the
branch-dependent set today, and fail-closed if that ever changes.

## 3. The procedure

Each step and what it isolates.

1. **Read the diff before anything else**, from `git diff`, not from the
   comments. Both files are working-tree state, so every command below states
   which side of the `HEAD` line it reads.
2. **Re-verify AXIRD-FRST at HEAD, by content and not by line number.**
   Isolates: whether RESETGUARD's premise still held at the commit it was
   working from. The WORKLOG's own line numbers are stale twice over.
3. **Grep the whole repo for `frst`**, including `.xdc`, `.tcl`, `.py`, `.sh`.
   Isolates: a reader outside the RTL -- a constraint, a probe, a hierarchical
   reference -- that a VHDL-only check would miss.
4. **Anchor-count diff of all three mutation harnesses against HEAD.**
   Isolates: whether the RTL edit silently voids a mutation row. A voided row
   prints `VOID ANCHOR FAILED`, not `SURVIVED`, so this is about coverage loss,
   not a false green.
5. **Regenerate the artefacts and `md5sum -c` all 676 tracked files in
   `hw/fk33/`.** Isolates: whether the guard changes any emitted byte.
6. **`gen_pcieep.py --selftest`.** Covers the injected Tcl guards only, per
   BITPREP. Run as a regression, not as evidence about the reset guard.
7. **Mutate the GENERATOR SOURCE, 13 rows, each run twice** -- once as shipped
   and once with `check_reset_topology` neutered. The second run is the
   attribution control: it answers "would any pre-existing guard have caught
   this anyway?".
8. **`regress.sh --only axi_rd_port`**, reading the `OVERALL PASS n` line.
9. **Teeth for the teeth**: neuter the guard and confirm the new selftest rows
   all go WRONG. A row that passes with the guard removed measures nothing.

### Where the mutant generator ran, and why it could not run in scratch

`build_fk33_i2cprobe.tcl` embeds the **absolute** path of
`fk33_i2cprobe.xdc`, and `gen_pcieep.py` refuses to proceed if that exact
string is absent. So `HERE` is pinned to the repo and a scratch copy of the
generator aborts before it starts:

```
ABORT: the probe build script no longer contains:
add_files -fileset constrs_1 -norecurse /mnt/storage/resetland_scratch/hw/fk33/fk33_i2cprobe.xdc
```

The mutant therefore ran **in `hw/fk33/` under a distinct filename**, with
`DST` and `XDC_DST` rewritten to point into scratch, so no mutant ever wrote a
repo artefact. The file was removed afterwards and its absence verified.

## 4. The evidence

### 4.1 Every reset driver in the emitted Tcl (MEASURED, python3 over `build_fk33_pcieep.tcl`)

```
clk_wiz_0/resetn                 <- ['xdma/axi_aresetn']
eng/core_aresetn                 <- ['core_reset/peripheral_aresetn']
hbm/AXI_00_ARESET_N              <- ['xdma/axi_aresetn', 'hbm_reset/peripheral_aresetn']
hbm/AXI_01_ARESET_N              <- ['xdma/axi_aresetn']
   ... AXI_02 .. AXI_15, all ['xdma/axi_aresetn'] ...
hbm/AXI_16_ARESET_N              <- ['xdma/axi_aresetn', 'hbm_reset/peripheral_aresetn']
hbm/AXI_17_ARESET_N              <- ['xdma/axi_aresetn']
   ... AXI_18 .. AXI_29, all ['xdma/axi_aresetn'] ...
```

Exactly two pins have two drivers (the two `EnablePCIe` branches); they are
exactly the two the scan does not visit; all 28 engine ports have one.

The same scan reported six `connect_bd_net` lines it could not parse. **None
of them is a reset.** Four are line-continuations into `system_management_wiz_0`
and two use a Tcl variable (`$lnk`, `$auxlnk`) for the source pin:

```
NON-2 ENDPOINT LINE: connect_bd_net $lnk [get_bd_pins led_cat/In1]
NON-2 ENDPOINT LINE: connect_bd_net $auxlnk [get_bd_pins fk33_aux_0/user_lnk_up]
NON-2 ENDPOINT LINE: connect_bd_net [get_bd_pins system_management_wiz_0/temp_out] \
   ... 3 more sysmon continuations ...
```

### 4.2 AXIRD-FRST re-verified at HEAD (MEASURED, `git show HEAD:` + grep)

```
$ git show HEAD:rtl/axi_rd_port.vhd | grep -n frst
157:  signal frst    : std_logic;
239:    frst    <= rst;
309:    frst  <= rst_s2;
357:      port map(clk => aclk, rst => frst, start => start_f,
367:      port map(wclk => aclk, wrst => frst,

$ git show HEAD:rtl/axi_rd_port.vhd | grep -n 'generate\|^begin\|^end architecture'
176:begin
236:  g_sc : if not DUAL_CLK generate
273:  end generate;
276:  g_dc : if DUAL_CLK generate
372:  end generate;
373:end architecture;
```

Driven at `:239` inside `g_sc` (236-273) and at `:309` inside `g_dc`
(276-372); read only at `:357` and `:367`, **both inside `g_dc`**. RESETGUARD's
premise reproduces exactly. Repo-wide grep over `*.vhd *.sh *.tcl *.py *.md`
and separately over `*.xdc` finds no other reader: every remaining hit is
either inside `g_dc`, inside a mutation harness anchoring on the `g_dc` lines,
or prose in `docs/`.

### 4.3 Mutation harness anchors survive the RTL edit (MEASURED)

Every double-quoted VHDL fragment in `sim/mutate_axi_rd_port.sh`,
`sim/mutate_axi_rd_port_dual.sh` and `sim/cdc_teeth.sh`, counted in HEAD's RTL
and in the working tree's:

```
anchor-count deltas between HEAD and working tree: 0
```

The one anchor that does change is `B1`'s, and it changes in lockstep:

```
B1 anchor in HEAD script      : True
B1 anchor in WORKING script   : False
B1 anchor in HEAD rtl         : 1
B1 anchor in WORKING rtl      : 0
```

**This is why `sim/mutate_axi_rd_port.sh` is not optional.** Landing the RTL
change alone leaves `B1` anchored on a line that no longer exists. It would not
fake a pass -- `mutate()` prints `VOID ANCHOR FAILED -- TESTED NOTHING` -- but
it would turn a row into noise for no reason. The two land together.

### 4.4 Artefacts unchanged (MEASURED, `md5sum -c` over 676 tracked files)

```
$ python3 gen_pcieep.py
FK33_RESETGUARD eng/core_aresetn descends from xdma/axi_aresetn via core_reset, and so do all 28 engine hbm/AXI_nn_ARESET_N
wrote .../build_fk33_pcieep.tcl
wrote .../fk33_pcieep.xdc  (48 lane constraints superseded, 2 debug-hub lines superseded, sysref kept)

$ md5sum -c before.md5 | grep -v ': OK$'
gen_pcieep.py: FAILED
```

`gen_pcieep.py` is the only file that differs, and that is this track's own
edit. BITPREP's byte-identical property holds.

### 4.5 The reset guard, 13 mutations, each with its attribution control (MEASURED)

`GUARD OFF` = `check_reset_topology(text)` replaced by `pass`, everything else
identical.

```
ROW   GUARD ON    GUARD OFF   ATTRIBUTION
------------------------------------------------------------------------------
BASE  PASS        PASS        NEITHER                                as expected
R1    ABORT rc=1  PASS        NEW GUARD ALONE                        as expected
R2    ABORT rc=1  PASS        NEW GUARD ALONE                        as expected
R3    ABORT rc=1  PASS        NEW GUARD ALONE                        as expected
R4    ABORT rc=1  PASS        NEW GUARD ALONE                        as expected
R5    ABORT rc=1  PASS        NEW GUARD ALONE                        as expected
R6    ABORT rc=1  PASS        NEW GUARD ALONE                        as expected
R7    ABORT rc=1  PASS        NEW GUARD ALONE                        as expected
S1    PASS        PASS        NEITHER                                as expected
S2    PASS        PASS        NEITHER                                as expected
N1    PASS        PASS        NEITHER                                as expected
N2    ABORT rc=1  PASS        NEW GUARD ALONE                        *** UNEXPECTED ***
N3    ABORT rc=1  PASS        NEW GUARD ALONE                        *** UNEXPECTED ***
```

| row | mutation | result |
|---|---|---|
| `R1` | `core_reset/ext_reset_in` re-rooted onto `fk33_aux_0/aux_aresetn`, making the engine reset a SIBLING of the slave's | refused |
| `R2` | `core_reset/aux_reset_in` driven from the aux reset | refused |
| `R3` | `eng/core_aresetn` driven straight from the aux reset, bypassing `core_reset` | refused |
| `R4` | one engine master port (`SAXI_01`) reset from `hbm_reset/peripheral_aresetn` | refused |
| `R5` | `dcm_locked` moved onto a new MMCM whose own reset is free-running | refused |
| `R6` | `core_reset` created as `util_vector_logic:2.0` instead of `proc_sys_reset:5.0` | refused |
| `R7` | the `eng/core_aresetn` connection deleted | refused |
| `S1` | SAFE: `eng/core_aresetn` wired straight to `xdma/axi_aresetn` | accepted, and reports the `SAME net` variant of the message |
| `S2` | SAFE: the `ext_reset_in` net written sink-first | accepted |

**`GUARD OFF` is `PASS` on every single dangerous row.** No pre-existing guard
in `gen_pcieep.py` -- and there are many -- catches any of them. The new check
earns all seven kills alone. That is the attribution control CLAUDE.md
requires, and it came out unambiguous.

### 4.6 Mutations that did NOT bite, under their own names

These are the resolution floor and they are the most useful rows here.

**`N1` -- `core_reset/slowest_sync_clk` moved to the free-running aux clock.
NOT REFUSED, and correctly so.** `proc_sys_reset` synchronises
`peripheral_aresetn` release to that clock, so this is a genuine CDC hazard on
the engine's reset release, and the guard says nothing about it. It is
nonetheless **not** the guarded property: it introduces no reset SOURCE the
HBM slave does not share, so it cannot open the STRAY-NEXTJOB window. Recorded
so that nobody reads this guard as covering the reset's clocking.

**`N2` -- the `ext_reset_in` connection rewritten with a Tcl line
continuation. REFUSED, and my prediction was wrong, not the guard.** I expected
a silent pass, because `_bd_net_peers` scans line by line and cannot see a
two-line `connect_bd_net`. It aborts instead, because an unparseable
connection leaves `ext_reset_in` with zero peers and the guard treats that as a
missing driver. **The floor here is fail-CLOSED**: a hardware-identical
restyling of the emitter breaks the build with a frightening message rather
than passing. That is a maintenance cost, not a safety hole, and it is the
right direction. It is written down because the code comment claims
line-comment awareness and says nothing about continuations, and the next
person to reformat that emission will hit it.

**`N3` -- `ext_reset_in` driven via a Tcl variable holding the same pin
(`set xrst [get_bd_pins ...]`). REFUSED, same mechanism, same correction to my
prediction.** The pattern is already live elsewhere in the file (`$lnk`,
`$auxlnk` in 4.1), so this is a realistic future edit and it will abort.

**`B1` in `sim/mutate_axi_rd_port.sh` -- the mutation that did not bite for
five months.** Recorded here because RESETGUARD's own edit to that file makes
the point better than a table row: `B1` mutated `frst <= rst;`, survived, and
was labelled an EQUIVALENT MUTANT with a correct justification. **The
justification was the defect report, filed as an expected result.** An expected
result is not something anyone re-reads.

### 4.7 The RTL rows (MEASURED, `regress.sh --only axi_rd_port`)

```
 suite sim   PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

**What those three rows cover, and what the PASS is and is not evidence for.**
The rows are `tb_axi_rd_port` (`DUAL_CLK` defaulted false, so `g_sc`),
`tb_axi_rd_port_dual` (`:177`, `DUAL_CLK => true`, so `g_dc`) and
`tb_axi_rd_port_stray` (`:326`, `DUAL_CLK => true`, the reset-topology rows).
Both generate branches therefore elaborate and run.

**This PASS is evidence that the change broke nothing. It is NOT evidence that
the change is correct**, and it could not be: the deleted statement was dead,
so no simulation can distinguish before from after. The evidence for
correctness is 4.2 (no reader outside `g_dc`) and 4.3 (no harness anchor lost).
`sim/tb_axi_rd_port_stray.vhd` was not touched and its row count is unchanged
at three (`sfast`, `sslow`, `snear` at `:167`, alongside the earlier rows).

### 4.8 The new permanent teeth, and the teeth for the teeth

`gen_pcieep.py --selftest` now ends with:

```
RESET-TOPOLOGY TEETH (check_reset_topology)
ROW  RESULT    MUTATION
--------------------------------------------------------------
T1   REFUSED   ext_reset_in re-rooted onto a free-running reset: ...
T2   REFUSED   aux_reset_in driven: proc_sys_reset ORs it into peripheral_aresetn, ...
T3   REFUSED   core_aresetn driven straight from an unrelated net
T4   REFUSED   one engine master port reset from a different net, ...
T5   REFUSED   core_reset is no longer a proc_sys_reset, ...
T6   REFUSED   the core_aresetn connection deleted entirely
T7   REFUSED   dcm_locked moved onto an MMCM whose own reset is free-running: ...
T8   accepted  SAFE: core_aresetn wired straight to the slaves' own reset net, ...
T9   accepted  SAFE: the same net written sink-first. ...
T0   accepted  the UNMUTATED emitted engine wiring (the control: ...)
--------------------------------------------------------------
SELFTEST PASS
```

**The base of these rows is `ENGINE_BLOCK`, the real emitted engine wiring, not
hand-written Tcl.** That matters: a fake base would be the classic
guard-passes-for-the-wrong-reason shape, green against text no build emits. If
the emitter moves, the anchor count goes to zero and the row prints
`VOID ANCHOR x0 -- TESTED NOTHING` and fails the selftest, rather than
quietly passing.

Attribution control for the new rows -- `check_reset_topology` replaced by a
no-op, `reset_topology_teeth()` re-run:

```
exit: SELFTEST FAIL: the reset-topology guard does not discriminate as claimed.
rows marked WRONG: 7
  FAIL T1: expected a refusal, got acceptance -- ...
  FAIL T2..T7: same
```

Seven of the ten rows die when the guard is removed, and the three that do not
are the three that must not (`T8`, `T9`, `T0` are the must-accept rows). The
teeth are not decoration.

## 5. Measured and REJECTED -- do not retry

* **Running the mutant generator from a scratch directory. REJECTED.**
  `build_fk33_i2cprobe.tcl` hardcodes the absolute path of
  `fk33_i2cprobe.xdc`, and `gen_pcieep.py`'s own guard aborts on it. Symlinking
  the inputs into a scratch tree does not help, because the pinned string is
  inside the input, not in the layout. The working method is the mutant living
  in `hw/fk33/` with `DST`/`XDC_DST` redirected out.
* **Trusting the WORKLOG's `frst` line numbers. REJECTED, twice already.**
  They are stale as of `75f95a8`, stale again after the fix, and were stale
  when TRACK FLOOR wrote them down. Identify the two assignments by content and
  by which generate they sit in.
* **`gen_pcieep.py --selftest` as evidence about the reset guard. REJECTED**,
  and BITPREP said so first. Before this track's change it exercised the
  injected Tcl guards and nothing else; `check_reset_topology` was called from
  exactly one place, `main()`, and `--selftest` does not call `main()`. It does
  now, and only because this track wired it in.
* **Reading `CONFIG.*` on a block-design pin to establish the reset tree.
  NOT ATTEMPTED, deliberately.** CLAUDE.md records that reading a `CONFIG.*`
  reads a REQUEST and not an answer. The guard reads `connect_bd_net` lines,
  which are the thing that is executed.
* **Deleting the `g_dc` assignment `frst <= rst_s2;` instead of the `g_sc` one.
  REJECTED** -- it is the live one, it feeds the FSM and the FIFO, and the
  WORKLOG has warned about this specific mis-deletion since the second sighting.

## 6. Measurement traps hit, including my own

* **I predicted `N2` and `N3` would pass and they aborted.** My mental model of
  `_bd_net_peers` was right (it cannot parse either form) and my conclusion
  from it was wrong, because I reasoned about the parser and not about what the
  caller does with an empty result. Writing the expected outcome into the table
  *before* running is what made the mistake visible instead of invisible; had I
  filled the column in afterwards, both rows would have been recorded as
  ordinary kills and the fail-closed property would never have been noticed.
* **`git status` at the start showed a THIRD modified file that the brief did
  not list**, `sim/mutate_axi_rd_port.sh`, and it is the one that makes the
  RTL change coherent. The brief's "235 lines in two files" is exact for the
  two files it names and incomplete for the change. **A diffstat scoped to the
  files you were told about cannot reveal a file you were not told about.**
* **Three other tracks have uncommitted hunks in this tree right now**
  (`rtl/llama_top.vhd`, `hw/design_mv_generated.tcl`, two `docs/debugging/`
  files). Every measurement above states whether it read `HEAD` or the working
  tree, because the subject of this track *is* working-tree state and the
  usual "snapshot from `git show HEAD:`" rule would have measured the wrong
  thing.
* **`REGRESSION: PASS` is printed for a pattern that matches nothing.** The
  `OVERALL PASS 3` line is the one that was read. `--only axi_rd_port` is a
  substring and it matched all three benches.
* **`ghdl` was run inside `systemd-run --user --scope -p MemoryHigh=9G`** while
  another track held Vivado on this box (`free -g` showed 0 free, 6 GiB swap in
  use, load 6.0). A soft throttle, not a cap: it slows the run rather than
  killing it. Given 2026-08-30 01:25, an unbounded `ghdl-mcode` beside a live
  Vivado was not worth the risk.

## 7. Open, not yet answered

* **The guard checks the block design and cannot see the RTL.** If anyone adds
  a reset path INSIDE `hw/fk33/rtl/fk33_engine.vhd` or `rtl/llama_top.vhd` --
  a soft-reset register bit, the gateware-timed abort A7 asked for -- that
  resets the read ports without descending from `xdma/axi_aresetn`, this guard
  stays green and STRAY-NEXTJOB is live. **MEASURED that no such path exists
  today**: `llama_top` is instantiated with `s_axi_aresetn => core_aresetn` and
  has no second reset input, and `core_aresetn` is the engine's only reset.
  That is a fact about today, not a property anything enforces. **This is the
  largest remaining hole and it is a fail-OPEN one**, unlike `N2`/`N3`.
* **`hw/fk33/rtl/compose4_top.vhd` is out of scope for this guard entirely.**
  `ENG_CELL` is the string `"eng"`, so the check knows about exactly one
  engine instance. STRAYREACH already flagged that a four-engine composition is
  "exactly the kind of change that would break it"; the guard does not close
  that, and TRACK TIMING owns the composed top.
* **The guard's trace depth is one.** Its own comment says so. A renaming or
  buffering cell between `xdma/axi_aresetn` and either sink makes it abort
  (fail-closed, as `N2`/`N3` show), so this costs refusals of safe changes
  rather than acceptances of unsafe ones -- but it has not been measured
  against a real intermediate-cell topology, only reasoned about.
* **Nothing here was synthesised and nothing ran on the card.** Both boxes were
  held by other tracks. The claim is about generated Tcl and about VHDL
  elaboration, not about a bitstream. In particular, that the moved `frst`
  declaration produces an identical netlist is DERIVED (one dead concurrent
  assignment removed from a branch that does not elaborate) and not MEASURED.
* **`sim/mutate_axi_rd_port.sh:318` does `rm -rf "$SCRATCH/$tag"`**, a shell
  variable inside a path passed to `rm`, which is the exact form CLAUDE.md
  forbids. It is pre-existing and this track did not introduce it; it is
  flagged rather than fixed because rewriting that harness is not this track's
  work and a half-rewrite is worse than a flag.
* **`--selftest` still does not run the emitter end to end.** The new teeth
  mutate `ENGINE_BLOCK`; the shipping topology's acceptance is proven by
  `main()` calling the guard on every real generation. Those two together are
  complete, but they are two facts and not one test, and a future refactor
  could sever the link without either complaining.
