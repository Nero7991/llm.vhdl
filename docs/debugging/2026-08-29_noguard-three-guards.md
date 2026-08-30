# Three guards that passed for the wrong reason

TRACK NOGUARD, 2026-08-29. Board rows **BUILD-HANG**, **IPREPO-DRIFT**,
**DESC-RULE2**.

## The question, verbatim

> CLAUDE.md now names this class, because tonight produced four instances:
> **guards that pass for the wrong reason.** The tell is always the same -- the
> check has never been shown to discriminate on the thing it guards. Three are
> still open and unowned. They are small, independent, and each is genuinely
> dangerous in a different way.
>
> 1. BUILD-HANG (board row N4) -- the most expensive one. [...] Fix in
>    `hw/fk33/gen_pcieep.py`: a **bounded** wait, and a post-`launch_runs`
>    assertion that the run directory actually exists. [...] You cannot run a
>    real synthesis for this -- construct the check so it is testable without
>    one, and say how.
> 2. IPREPO-DRIFT -- the silent one. [...] Two candidate fixes, **not
>    equivalent** -- choose deliberately and say why.
> 3. DESC-RULE2 -- the one that has never discriminated. [...] prove the bases
>    are unchanged for every geometry in the shipping model.

Hardware, date, symptom numbers: workstation `Oren-Dell-Ubuntu`, root at 91%
(120 G free), `/mnt/storage` 388 G, RAM 31 G with 18-21 G available and two
Vivado syntheses in flight, load average 4.8-5.7. Vivado 2023.2 at
`/tools/Xilinx/2023.2`. GHDL not used by any of this work. **No hardware was
touched.**

## The answers, up front

**BUILD-HANG.** Two independent defects, not one. `wait_on_run` accepts
`-timeout <minutes>` and **returns rc 0 with an empty message on expiry** -- it
does not raise -- so the bound is only a bound if an explicit PROGRESS check
follows it. Separately, `get_runs`/`get_property DIRECTORY` succeed and return
a path **before the run has ever been launched**, so `file isdirectory` on that
path is an exact discriminator for the hang state. Both are now emitted by
`gen_pcieep.py`, and both are teeth-checked under `tclsh` with no synthesis and
no Vivado. Commit **`0b692f0`**.

**IPREPO-DRIFT.** The drift was **five files, not three** -- the three
`util_pkg.vhd`, plus `llama_engine_axi_1_0`'s `fixed_luts_pkg.vhd` (no `SP_ROM`
at all) and `rope.vhd`, whose packaged copy **predates the `NEOX` generic and
so has a different entity interface from `rtl/rope.vhd`**. All three IPs were
regenerated with Vivado; drift is now 0 of 32 packaged `.vhd`. The **cheap
checker** was chosen over a regenerate-and-diff gate, on three measurements
(below), and regeneration is deliberately **not** part of any gate. Commit
**`a9392ca`**.

**DESC-RULE2.** Rule 2 omitted `align4k()` **and** used one stride where the
scale sub-regions have their own. Corrected. **Every base for all 249 shipping
`.mv4i` tensors is byte-identical before and after** -- verified by dumping
them for all 249 files and diffing, not by argument. AJOBRUN's probe flipped
from DISAGREE to AGREE. Landed in the commit that carries this
write-up.

---

## PART 1 -- BUILD-HANG

### The procedure, in the order it was run

Each step isolates one thing the fix depends on. None of them is a synthesis of
the real design.

1. **`help wait_on_runs` in a bare `vivado -mode batch`.** Isolates: does a
   bounded wait exist at all in 2023.2? Answer: yes, `-timeout <minutes>`,
   default `-1` = no limit.
2. **Option-parse probe with no project open.** Isolates: is `-timeout`
   accepted by `wait_on_run` specifically, or only by `wait_on_runs`? The
   control is a deliberately bogus option in the same call shape. This matters
   because `wait_on_run` is a prefix alias and `help wait_on_run` prints the
   `wait_on_runs` topic, which is not proof.
3. **`list_property [get_runs synth_1]` on a throwaway project with nothing
   launched.** Isolates: is `DIRECTORY` a real run property, and what does it
   return when the run has never started? This is the whole basis of the
   assertion, and a guard built on a property that does not exist would fail
   every build.
4. **A real, trivial synthesis** (one flip-flop, `xcvu33p`, `-jobs 1`), sampled
   immediately after `launch_runs` returns and again after `wait_on_run`.
   Isolates: **which marker file is safe to require**. Requiring the wrong one
   breaks every healthy build, which is a worse defect than the one being
   fixed.
5. **A timeout-semantics probe**: relaunch the finished run and
   `wait_on_run -timeout 0`. Isolates: does an expired bound raise or return?
6. **Twelve mutations of the generator**, each run first against the generator
   (does an emit-time check refuse?) and then against `--selftest` (does the
   behavioural check refuse?), with a base run first to prove the harness works
   at all.

### The evidence, raw

Option parse (step 2). The bogus-option control is what makes the first line
mean anything:

```
###T1
ERR1: ERROR: [Common 17-53] User Exception: No open project. Please create or open a project before executing this command.
###T2
ERR2: ERROR: [Common 17-170] Unknown option '-bogusopt', please type 'wait_on_runs -help' for usage info.
###T3
ERR3: ERROR: [Common 17-53] User Exception: No open project. Please create or open a project before executing this command.
```

Run properties before any launch (step 3):

```
###DIR
DIRECTORY=/.../probe/p/p.runs/synth_1
STATUS=Not started
PROGRESS=0%
###EXISTS
isdir=0
```

Marker files on a real launch (step 4). Note that `runme.log` and
`.vivado.begin.rst` are in the SECOND listing only:

```
###BEFORE isdir=0 status=Not started
###JUSTAFTER isdir=1 status=Queued...
###FILES . .. .Vivado_Synthesis.queue.rst ISEWrap.js ISEWrap.sh gen_run.xml htr.txt project.wdf rundef.js runme.bat runme.sh t.tcl
###AFTERWAIT isdir=1 status=synth_design Complete! progress=100%
###FILES2 . .. .Vivado_Synthesis.queue.rst .Xil .vivado.begin.rst .vivado.end.rst ISEWrap.js ISEWrap.sh __synthesis_is_complete__ gen_run.xml htr.txt project.wdf rundef.js runme.bat runme.log runme.sh t.dcp t.tcl t.vds t_utilization_synth.pb t_utilization_synth.rpt vivado.jou vivado.pb
###DONE
```

Timeout semantics (step 5). **`rc=0`, empty message, run still `Queued...`:**

```
###LAUNCHED status=Queued...
###WAIT0 rc=0 elapsed=0 msg=
###AFTER status=Queued... progress=0%
###WAIT20 rc=0 progress=100%
###DONE
```

The selftest table as it stands (`python3 hw/fk33/gen_pcieep.py --selftest`):

```
row        expect    guard     muted     attribution
--------------------------------------------------------------
NODIR      RAISED    RAISED    PASSED    GUARD ALONE
NODIR_MSG  RAISED    RAISED    PASSED    GUARD ALONE
NOSCRIPT   RAISED    RAISED    PASSED    GUARD ALONE
OK_QUEUED  PASSED    PASSED    PASSED    n/a (must not refuse)
OK_DONE    PASSED    PASSED    PASSED    n/a (must not refuse)
TIMEOUT    RAISED    RAISED    PASSED    GUARD ALONE
SYNTHFAIL  RAISED    RAISED    PASSED    GUARD ALONE
DONE_OK    PASSED    PASSED    PASSED    n/a (must not refuse)
BOUND_NEG  RAISED    RAISED    PASSED    GUARD ALONE
BOUND_ZERO RAISED    RAISED    PASSED    GUARD ALONE
BOUND_JUNK RAISED    RAISED    PASSED    GUARD ALONE
BOUND_OK   PASSED    PASSED    PASSED    n/a (must not refuse)
VD         VOID      VOID      -         unparseable guard
PARSE      PASSED    PASSED    -         info complete on the whole file
--------------------------------------------------------------
GUARD ALONE=8  both=0  NEITHER=0
SELFTEST PASS
```

The twelve-mutation sweep, run against a base that was verified to generate and
selftest cleanly first:

```
BASE: generate OK, selftest PASS
mut  mutation                           caught-by    detail
m1   drop -timeout on synth wait        GENERATOR    an UNBOUNDED wait_on_run survived into the build script
m2   drop run-started call              GENERATOR    synthesis is launched without the run-started assertion
m3   test runme.log not runme.sh        GENERATOR    the run-started assertion no longer tests for runme.sh
m4   drop run-done call                 GENERATOR    nothing converts an expired synthesis bound into a stop
m5   neuter isdirectory test            SELFTEST     NODIR_MSG: expected RAISED, guard gave WRONGMSG
m6   neuter runme.sh test               GENERATOR    the run-started assertion no longer tests for runme.sh
m7   run-done never refuses             SELFTEST     TIMEOUT: expected RAISED, guard gave PASSED
m8   reword the NODIR message           SELFTEST     NODIR_MSG: expected RAISED, guard gave WRONGMSG
m9   synth bound literal -1             GENERATOR    FK33_SYNTH_MAX_MIN is -1 ... treats any non-positive value as NO LIMIT
m10  fk33_bound accepts anything        SELFTEST     BOUND_NEG: expected RAISED, guard gave PASSED
m11  bypass fk33_bound on env           GENERATOR    the FK33_SYNTH_MAX_MIN environment override does not go through fk33_bound
m12  impl wait unbounded                GENERATOR    an UNBOUNDED wait_on_run survived into the build script
```

Gate-row teeth, on the live tree (mutate, run, restore, verify md5):

```
=== row against the MUTATED guard (m7: run-done never refuses):
FAIL       sim:runguard                           0s  SELFTEST FAIL
 OVERALL     PASS 0   FAIL 1   ...
 REGRESSION: FAIL
=== restored: f882e5074cb7625383ef5bd73bfae2dd vs f882e5074cb7625383ef5bd73bfae2dd
=== row against the restored guard:
 OVERALL     PASS 1   FAIL 0   ...
 REGRESSION: PASS
```

### How the guard is testable without a synthesis

`--selftest` extracts the three procs **from the emitted
`build_fk33_pcieep.tcl`**, not from a copy in the generator, and sources them
in `tclsh` with `get_runs` and `get_property` replaced by stubs that return
values from a table. Everything the guard decides on is a stubbed property plus
the real filesystem, so the whole of its logic is covered. The synthetic run
directories are built to match the shapes measured in step 4: one holding
`runme.sh`, one holding only `.Vivado_Synthesis.queue.rst`, and one that does
not exist.

### Two things found by mutation that were not in the plan

**`-timeout -1` is Vivado's documented "no limit".** So setting the bound to
`-1` reinstates the original 27.6-hour defect *while satisfying every textual
check on the script*, including the one that refuses a bare `wait_on_run`. That
is the same class of defect as the one being fixed, introduced by the fix. It
is now closed by `fk33_bound`, which refuses a non-positive or non-integer
limit on the default **and** on the environment override; mutation `m11` proves
the override path is separately checked, because routing only the default was
not enough.

**The two checks in `fk33_assert_run_started` are NOT independent.** When the
directory is absent, `file exists [file join $dir runme.sh]` is also false, so
the `runme.sh` test alone already refuses the BUILD-HANG state. Neutering the
`file isdirectory` test to `if {0}` changes no verdict and is caught by nothing
on verdict alone (`m5`). What that check actually buys is that the refusal
**says** "NO run directory at all" rather than "no runme.sh in it" -- and since
the entire 27.6-hour cost of BUILD-HANG was misdiagnosis, the message is the
value. `NODIR_MSG` tests the message. Without that row the check would be
decoration with no teeth of any kind, which is precisely this track's subject.

---

## PART 2 -- IPREPO-DRIFT

### The decision, and why it is not the obvious one

The board offered a gate row that **regenerates and diffs**, or a **cheap
byte checker**. Three measurements decided it, and the first is the one that
matters:

1. **MEASURED: nothing in this repository consumes `ip_repo/`.** `grep -rn
   ip_repo` over every `.tcl`, `.sh`, `.py` and `.md`, excluding `ip_repo/`
   itself and `.claude/worktrees`, returns the packaging script's own comment
   and documentation references. There is no `set_property ip_repo_paths`
   anywhere in the live tree; the single occurrence is in a `.claude/worktrees`
   copy of `hw/build_bringup.tcl` pointing at a **different repository**
   (`~/GitHub/axu3eg-pwm-ip/ip_repo`). So the artefact being protected is a
   published package, not a live build input.
2. **MEASURED: repackaging with no RTL change still rewrites
   `component.xml`.** The `mac_axi` diff after regeneration was 4 lines: two
   `viewChecksum` values and `coreCreationDateTime`. A regenerate-and-diff gate
   would therefore report a diff on **every** run, from ipx metadata rather
   than from drift. Narrowing it to `src/*.vhd` is exactly what the checker
   does, minus Vivado.
3. **All three packagers begin `file delete -force <ipdir>`.** A gate that
   regenerates can **destroy the artefact it is checking** if interrupted. A
   gate must not be able to damage what it inspects.

That same `component.xml` diff also makes the "do not hand-edit the copies"
rule MEASURED rather than stylistic: the file carries checksums computed over
the sources, so a hand-edited `src/*.vhd` desynchronises the package.

**Regeneration is not part of any gate, and this work does not make it one.**
It stays a manual Vivado step (`ip_repo/package_llama_ip.tcl`,
`hw/package_mac_axi.tcl`, `hw/package_matvec_engine.tcl`). The gate row only
refuses to let the output drift from `rtl/`.

### The evidence, raw

Drift before regeneration, measured over all 32 packaged `.vhd`:

```
DIFFERS  ip_repo/llama_engine_axi_1_0/src/fixed_luts_pkg.vhd
DIFFERS  ip_repo/llama_engine_axi_1_0/src/rope.vhd
DIFFERS  ip_repo/llama_engine_axi_1_0/src/util_pkg.vhd
DIFFERS  ip_repo/mac_axi_1_0/src/util_pkg.vhd
DIFFERS  ip_repo/matvec_engine_1_0/src/util_pkg.vhd
```

`rope.vhd` is the one that matters most and is not mentioned on the board: the
packaged copy has

```
     KVDIM : positive := 32
```

where `rtl/rope.vhd` has

```
     KVDIM : positive := 32;
     [the NEOX generic and its 15 lines of pairing rationale]
```

so the IP carries a **different entity interface**, not a stale comment.
`fixed_luts_pkg.vhd` is missing `SP_ROM` (a 257-entry table) entirely.

After regeneration, `differing=0` over 32 files, and `git status` shows only
modifications -- **no additions and no deletions**, so the packaged file set is
unchanged.

Checker teeth (`python3 ip_repo/check_ip_sync.py --selftest`):

```
row        expect      rules-on   rules-off  attribution
------------------------------------------------------------------
CLEAN      no finding  -          -          n/a (must not fire)
STALE      STALE       STALE      -          CHECK ALONE
NOSRC      NOSRC       NOSRC      -          CHECK ALONE
NOSCRIPT   NOSCRIPT    NOSCRIPT   -          CHECK ALONE
UNLISTED   UNLISTED    UNLISTED   -          CHECK ALONE
RENAMED    NOSCRIPT    NOSCRIPT   -          CHECK ALONE
WSPACE     STALE       STALE      -          CHECK ALONE
NONVHD     no finding  -          -          n/a (must not fire)
VD         VOID        VOID       -          no ip_repo/ present
------------------------------------------------------------------
CHECK ALONE=6
SELFTEST PASS
```

Row teeth on the live tree, by restoring the pre-regeneration copy from `HEAD`:

```
IPSYNC STALE    ip_repo/mac_axi_1_0/src/util_pkg.vhd: differs from rtl/util_pkg.vhd (386 vs 4612 bytes). ...
IPSYNC: FAIL -- ip_repo/ is not the bytes of rtl/. ...
[restored]
IPSYNC: 3 IP(s), 32 packaged .vhd, 0 finding(s)
IPSYNC: PASS
```

### The honest limit, and a defect it cannot see

The checker compares outputs to sources. It **cannot see a packaging script
that is itself wrong**. Rules `UNLISTED` and `NOSCRIPT` narrow that without
Vivado -- they refuse a packaged file no script names, and an IP directory no
script targets -- but they do not close it.

A MEASURED instance, found only by running the packagers and not catchable by
the checker: **`hw/package_mac_axi.tcl` and `hw/package_matvec_engine.tcl` both
end in an error.**

```
BUSIFS: bus_interface component_1 s_axi bus_interface component_1 s_axi_aresetn bus_interface component_1 s_axi_aclk
ERROR: [Common 17-69] Command failed: Unknown property 'CONFIG.ASSOCIATED_BUSIF' on bus_interface
```

The failing line is the final `puts CLOCK_ASSOC`, **after `ipx::save_core` has
already run**, so the IP is written correctly and the script still exits
non-zero and never prints `PACKAGE_DONE` or reaches `close_project`. A caller
that checked the exit status would conclude packaging had failed. Those two
files are not this track's to edit. `ip_repo/package_llama_ip.tcl` does not
have this defect and printed `PACKAGE_DONE`.

---

## PART 3 -- DESC-RULE2

### The defect, and why it had never discriminated

`tools/gen_mv4i_desc.py` computes every sub-region base twice and refuses to
emit if the two rules disagree. That cross-check is the **only** guard against
a base aimed at the wrong sub-region, which is the one descriptor corruption
the gateware cannot see: it computes wrong data and reports success. Rule 2 was
wrong in two ways at once:

1. It omitted the 4 KB padding both packers apply --
   `ref/matvec_int4.c:474` `sub_pad = align4k(tiles*NB*port_b)` and
   `tools/pack_int4.py:477` `sub_sz = align4k(tiles*NB*port_b)`.
2. It used one stride for both kinds of sub-region. The scale region is
   `ceil(tiles*nb/GRP)` **superwords**, so `ref/matvec_int4.c:478` and
   `tools/pack_int4.py:482` give it its own `align4k(nsuper*port_b)`. That
   equals the weight stride only when `GRP == 1`.

**Why it was invisible, DERIVED.** On the FK33 the file geometry is
`BLOCK = 32` and `AXI_DW = 256`, so `port_b = 32` and `nb = K/32`, giving
`nb*port_b = K` exactly. Every shipping tensor has `K` in `{4096, 12288}`, both
exact multiples of 4096, so `tiles*nb*port_b = tiles*K` is always 4 KB-aligned
and `align4k` is the identity; and `GRP = 1` throughout, so the two strides
coincide. The board's statement of the coincidence was right; this is its
arithmetic.

### Proof that no shipping base moved

Every one of the 249 `.mv4i` files in
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd` was parsed and its full
`check_bases()` output dumped, before and after the change, and the two dumps
diffed. **IDENTICAL, 258 lines each, 0 refused and 0 missing.** The line counts
are stated because `diff <(a) <(b) && echo IDENTICAL` is true when both files
are empty or missing, and that trap has bitten this project before.

The eight distinct shapes, MEASURED rather than taken from the board:

```
MV4I FILES: 249   DISTINCT (M,K) SHAPES: 8
  M=32      K=4096    48 file(s), e.g. blk.0.ssm_alpha.weight.mv4i
  M=1024    K=4096    16 file(s), e.g. blk.11.attn_k.weight.mv4i
  M=4096    K=4096    56 file(s), e.g. blk.0.attn_gate.weight.mv4i
  M=4096    K=12288   32 file(s), e.g. blk.0.ffn_down.weight.mv4i
  M=8192    K=4096    8 file(s), e.g. blk.11.attn_q.weight.mv4i
  M=8224    K=4096    24 file(s), e.g. blk.0.attn_qkv.weight.mv4i
  M=12288   K=4096    64 file(s), e.g. blk.0.ffn_gate.weight.mv4i
  M=248320  K=4096    1 file(s), e.g. output.weight.mv4i
```

All eight have `GRP = 1`, `nports_w = 24`, `n_scale_sub = 3`, `port_b = 32`.

### The acceptance test flipping

AJOBRUN's probe in `hw/fk33/host/fk33_run_job.py selfcheck` measures and prints
the discrepancy without asserting on it, so its verdict flips when the defect
is fixed. That file was **run, not modified**. `selfcheck` is documented "No
card, no model, nothing under /dev" and reaches only `SimBar`/`FileHbm`;
`open_transport` is called from `cmd_job` alone.

Before:

```
  M=96 K=128 nb=4 tiles=2 port_b=32 -> sub_bytes()=256, 4 KB-aligned=False
  rule 1 (file offset table) w[0:2]=[4096, 8192]  rule 2 (layout) w[0:2]=[4096, 4352]
  the two base rules DISAGREE.  gen_mv4i_desc.py's rule 2 omits the align4k() that ...
```

After:

```
  M=96 K=128 nb=4 tiles=2 port_b=32 -> sub_bytes()=256, 4 KB-aligned=False
  rule 1 (file offset table) w[0:2]=[4096, 8192]  rule 2 (layout) w[0:2]=[4096, 8192]
  the two base rules AGREE -- the defect below appears to have been fixed
```

The rest of that selfcheck is unchanged across the fix:
`32 mutations, 17 expected-refusal rows bit, 0 rows disagreed with their
expected verdict`, both before and after.

### Teeth

`python3 tools/gen_mv4i_desc.py --selftest`. Headers are synthesised in Python,
deliberately **not** by `ref/matvec_int4.c`: that file is the oracle this tool
is checked against, and a teeth test that called it would be checking the
oracle against itself -- the same reason `Mv4iHeader` is an independent parse.

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

Read the three `BOTH` rows as the point of the exercise: they are the shipping
geometry, and the old rule passes them, which is exactly why nobody saw the
defect. The three `both refuse` rows measure that the guard bites **at all**;
they say nothing about the correction and are labelled so. `RAISES` exists
because a disagreement is only a guard if something stops on it, and
`check_bases` merely returning a mismatch would satisfy the other rows.

`UNPADDED` is worth its own line: the OLD rule **accepted** a tightly packed
file that neither packer writes. So the old rule 2 was not merely too strict on
padded files; it was also too permissive on unpadded ones, and would have
accepted a second, undocumented layout.

---

## Measured and REJECTED -- do not retry

- **Requiring `runme.log` or `.vivado.begin.rst` in the run-started
  assertion.** REJECTED. MEASURED on a real trivial synthesis: immediately
  after `launch_runs` returns, the directory holds `runme.sh`, `runme.bat`,
  `rundef.js` and `.Vivado_Synthesis.queue.rst` and nothing else; `runme.log`
  and both `.vivado.*.rst` markers appear later. A guard requiring them would
  refuse **every correct launch**. The generator now refuses to emit such a
  guard, and mutation `m3` is the row that proves it.

- **Polling for the run directory after `launch_runs`.** REJECTED as
  unnecessary, MEASURED: the directory and `runme.sh` exist the instant
  `launch_runs` returns (`###JUSTAFTER isdir=1 status=Queued...`), so the check
  cannot race and a poll loop would only delay a real failure.

- **Relying on `wait_on_run -timeout` alone to bound the build.** REJECTED,
  MEASURED: it returns `rc=0` with an **empty message** on expiry. It is not an
  error path. Without `fk33_assert_run_done` after it, the bound is decoration.

- **`-timeout -1` as a "disable the bound" escape hatch.** REJECTED. It is
  Vivado's documented "no limit", so it silently reinstates the original
  defect. `fk33_bound` refuses it on both the literal and the environment
  override.

- **Running the mutation sweep from a scratch directory of symlinks.**
  REJECTED, and it is a measurement trap this track walked into. See below.

- **A gate row that regenerates the IPs and diffs.** REJECTED on three
  measurements: nothing in the tree consumes `ip_repo/`; repackaging with no
  RTL change still rewrites `component.xml`, so the diff is never empty; and
  every packager starts with `file delete -force`, so an interrupted gate
  destroys the artefact.

- **Hand-editing the packaged `src/*.vhd` copies.** REJECTED, and now MEASURED
  rather than asserted: `component.xml` carries `viewChecksum` values computed
  over the sources, so a hand-edit desynchronises the package.

- **Changing `Mv4iHeader.sub_bytes()` to return the padded stride.** REJECTED.
  `tools/gen_lmhead_windows.py:147` and `tools/embed_gather.py:196` both use it
  as the **live** byte extent of a sub-region, which is what window tiling is
  checked against. The padded stride is a separate quantity and is added as
  `layout_strides()` instead.

- **Using `ref/matvec_int4.c --emit` to build the DESC-RULE2 teeth fixtures.**
  REJECTED: it is the oracle this tool is checked against, and a fixture from
  it would check the oracle against itself.

## Measurement traps hit, including my own

- **A mutation sweep whose BASE does not work scores everything CAUGHT.** The
  first run of the generator mutation sweep reported `m1`-`m4` all CAUGHT, and
  every one was spurious: the scratch directory used a **symlink** to
  `build_fk33_i2cprobe.tcl`, whose contents carry the absolute path of the real
  `hw/fk33/`, while the generator computed `XDC_SRC` from its own location. The
  substitution therefore failed for the base too, with `ABORT: the probe build
  script no longer contains: ...`. Four mutants "caught" by a file the tool
  could not use. Fixed by copying the source and rewriting the path prefix, and
  by **running the base first and printing its verdict** before any mutant.
  This is the recorded trap "a mutant script once scored all seven CAUGHT
  because ghdl could not open a file", reproduced in a new tool inside an hour.

- **A harness that reads the FIRST line of output scores a passing guard as a
  refusal.** The guard `puts "FK33_RUNSTART ..."` on its healthy path, so the
  first output line is not the verdict. Three healthy rows came out WRONG on
  the first run of the selftest. That is a harness defect that reads exactly
  like a guard defect. The harness now takes the **last** marker line.

- **A badly-formed mutant is VOID, not a kill, and must be recognised as
  such.** An early `m5` inserted `if 0 {` without a closing brace, which left
  the whole proc unparseable; the selftest reported `SELFTEST VOID: could not
  extract ...`. Correct, but it did not test what was intended. The real `m5`
  neuters the condition to `if {0}` and keeps the braces balanced -- and it is
  the mutant that found the message-only check.

- **`diff <(a) <(b) && echo IDENTICAL` is TRUE when both files are missing.**
  The 249-tensor base comparison reports the line counts (258/258) and the
  refused/missing count (0) alongside the verdict for exactly this reason.

- **`git status --porcelain` on `hw/fk33` is 60 lines of untracked JTAG logs.**
  Reading it for "did my change land cleanly" invites staging something
  unrelated. Every commit here staged explicit paths and re-read
  `git diff --cached --name-only` as its own step before committing.

- **Both `hw/package_*.tcl` exit non-zero after succeeding.** A caller that
  gated on the exit status would report a packaging failure that did not
  happen. Recorded above; not fixed here.

## What was NOT verified

- **No FK33 shell build was run**, so the run guards have never executed inside
  a real `build_fk33_pcieep.tcl`. What has been measured is that the emitted
  Tcl is `info complete`, that all three procs parse and behave correctly under
  `tclsh`, and that every Vivado behaviour they depend on
  (`-timeout` acceptance, `-timeout` expiry semantics, `DIRECTORY` on an
  unlaunched run, the marker files after a real `launch_runs`) is measured
  rather than assumed.
- **The regenerated IPs have not been instantiated in any design.** Nothing in
  the tree does, which is part of why the cheap checker was chosen; but it also
  means "the IP still works" is untested. What is tested is that its sources
  are `rtl/`'s bytes.
- **`llama_engine_axi_1_0`'s packaged set excludes `sampler.vhd`**, which
  `ip_repo/package_llama_ip.tcl` lists in `rtlfiles`. This is unchanged by the
  regeneration (identical before and after) and is most likely
  `-import_files` importing the compile-order-reachable set only. **Not
  confirmed**, and the checker's `UNLISTED` rule cannot see it because it looks
  the other way round.
- **`tools/lmhead_window_check.py:66-80` is now stale.** Its comment says
  `check_bases` "refuses every C-packed file" and that
  `sub_offsets_from_layout` "encodes the TIGHT layout". Both were true and are
  now false. That file is not this track's; the correction is a follow-up.
- **No clean full gate was run**, so `BASELINE_PASS` is deliberately left at
  93 by all three commits even though three rows were added.
- The `--only` runs reported here are substring filters. The unfiltered
  `OVERALL` line for a full gate was not produced by this track.

## Corrections to the brief

- The brief says IPREPO-DRIFT is **three** copies of `util_pkg.vhd`. MEASURED:
  **five** files were stale across the three IPs, and one of them (`rope.vhd`)
  differs in its **entity interface**, not only in a package body.
- The brief says the fix is "a bounded wait, and a post-`launch_runs`
  assertion". Both are necessary and neither is sufficient: the bounded wait
  does not raise on expiry, and the run-directory assertion is subsumed by the
  `runme.sh` test on verdict alone. The working guard is three checks, and the
  third (`fk33_bound`) was found by mutation, not by the plan.
