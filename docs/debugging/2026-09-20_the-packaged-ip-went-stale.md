# The packaged IP went stale, and the thing that guarded it was the only thing that could

**Date:** 2026-09-20
**Track:** IPSYNC
**Hardware/build:** no hardware. Vivado 2023.2 on the BC-250
(`labuser@192.0.2.133`, 14 GB unified) under
`systemd-run --user --scope -p MemoryHigh=10G`. No Vivado on the workstation:
its lane was on a `FK33_CARD=1` `route_design` throughout. GHDL 1.0.0
(Ubuntu, mcode) on the workstation for the analysis rows.
**Commits:** `ed3b0d8` (the re-package), `de77c9a` (the gdnadapt seam).

---

## 1. The question, verbatim

> THE JOB, and it is the only genuinely red gate row in the tree. TRACK GATEDAY
> found `sim:ipsync` failing and bisected it; TRACK PATHFREE re-confirmed it by
> hashing. The packaged copy under `ip_repo/` is **20,045 B** against `rtl/`'s
> **20,328 B**. They are IDENTICAL at `cb2600f` and differ from **`09f68a0`
> ("GHDL 6.0 portability", 2026-09-19)** onward: the RTL was edited (a
> `prompt_len_i` rewire) and the packager was never re-run. [...] Confirm the
> diagnosis yourself before changing anything [...] If it is NOT a stale
> package but a real divergence someone intended, stop and report that instead.

And, as a second item:

> TRACK LEVERCOST found that **`rtl/ooc_gdnadapt_top.vhd` does not compile at
> HEAD**: it uses `B_CONST_HBM` at six lines and never declares it. [...]
> Diagnose whether the generator drops a generic it should carry, fix the
> GENERATOR rather than the output [...] and say whether `sim:gdnstale` should
> gain a compile step.

---

## 2. The answer, up front

**It is a stale package, exactly as diagnosed, and nothing was intended.** The
two copies are the same git blob at `cb2600f`; `09f68a0` moved `rtl/` and left
`ip_repo/` behind. Re-packaging on the BC-250 fixed it and `sim:ipsync` is
green.

**The attribution control is the part worth keeping: nothing else in the tree
catches this, and the honest answer is "nothing else ever could".**
`check_ip_sync.py` invoked by the `ipsync` row is the ONLY reader of
`ip_repo/*/src` in the whole repository. Zero other gate rows name it, and zero
`ghdl` lines compile it. GATEDAY's observation that the gate stayed green over
the divergence for a day is not a gap in coverage that was later closed -- it
is the structural situation, and the `ipsync` row is the entire defence.

**On the second item: yes, `sim:gdnstale` needed teeth, and a compile step is
not the way to give them today.** `rtl/ooc_gdnadapt_top.vhd` used
`B_CONST_HBM` at six sites and declared it nowhere, because the extraction
copies `gb_real`'s BODY verbatim from `llama_top` while its generic clause is a
HARDCODED TEMPLATE in the generator. **`--check` could not see it because
`--check` regenerates and diffs TEXT, and the generator faithfully reproduced
the same broken file it had written before.** That is a round trip, not an
oracle. Fixed in the generator, and `undeclared_generics()` now gates the class
from inside `emit()` -- the one choke point both the write path and `--check`
share -- so the existing row gained the teeth with `sim/regress.sh` untouched.

---

## 3. The procedure, in order, and what each step isolates

1. **Hash both copies across the tree, not just the named file.** Isolates
   "one file drifted" from "the packagers have been unrun for months". Result:
   1 of 32 packaged `.vhd` differs.
2. **Confirm the bisection with `git rev-parse <commit>:<path>`, not with
   sizes.** A byte count can coincide; a blob hash is the identity. This is
   what turns "they differ" into "they were the same object and one moved".
3. **Read the diff.** Isolates stale-package from intended-divergence. If the
   packaged copy held edits ABSENT from `rtl/`, it would be someone's
   hand-edit and the job would be to stop and report. It does not: the delta is
   exactly `09f68a0`'s rewire, in the `rtl/` direction only.
4. **Enumerate the packager's inputs and check every one against
   `git status`.** Isolates the repackage from the five dirty RTL files two
   other tracks hold. This is the step that decided HOW to sync.
5. **Presence-gate the remote Vivado lane by `/proc/PID/exe`**, then run the
   packager capped, then read a LINE-ANCHORED sentinel.
6. **Diff the regenerated IP against the committed one file by file**, with
   structural controls (bus-interface count, port names, `.vhd` reference
   count) that should NOT move. This is what caught the `versal` difference.
7. **Teeth**: run the gate row on the pre-fix package and on the fixed one.
8. **Attribution control**: ask what ELSE would have caught it, by reading the
   tree rather than by running the whole gate.

---

## 4. The evidence

### 4.1 The bisection, by blob identity

```
== blob hashes at cb2600f ==
ac8d35c7c811b5f54d3b5f237b35579bd6d58e62     rtl/llama_engine_axi.vhd
ac8d35c7c811b5f54d3b5f237b35579bd6d58e62     ip_repo/.../llama_engine_axi.vhd
== blob hashes at 09f68a0 ==
f88381a0784546d8b68a781b13692100a96d0190     rtl/llama_engine_axi.vhd
ac8d35c7c811b5f54d3b5f237b35579bd6d58e62     ip_repo/.../llama_engine_axi.vhd
== blob hashes at HEAD ==
f88381a0784546d8b68a781b13692100a96d0190     rtl/llama_engine_axi.vhd
ac8d35c7c811b5f54d3b5f237b35579bd6d58e62     ip_repo/.../llama_engine_axi.vhd
```

`git log --oneline cb2600f..HEAD -- rtl/llama_engine_axi.vhd` returns exactly
one commit, `09f68a0`. The whole delta is three hunks adding
`signal prompt_len_i : integer := 5;`, switching the port association
`prompt_len => prompt_len_reg` to `prompt_len_i`, and driving it.

### 4.2 The sync decision

```
=== dirty rtl files (GSRWIDE, SCOREHDR) ===
 M rtl/attn_block.vhd      M rtl/attn_score_q12.vhd
 M rtl/fk33_llama_top.vhd  M rtl/llama_top.vhd
 M rtl/swiglu_mem.vhd

=== any packager input dirty or missing? ===
(no MISSING/DIRTY lines: every one of the 27 inputs is clean at HEAD)
```

**None of the five dirty files is a packager input**, so the repackage could
not capture another track's in-flight edits. Even so, the working-tree sync
script was NOT used: the 27 inputs were rsynced into a standalone remote root
(`/home/labuser/ipsync_root`), which is possible only because TRACK PATHFREE
made `package_llama_ip.tcl` derive its repo root from `info script`. That
choice also means nothing already on the shared BC-250 tree was clobbered --
TRACK LEVERCOST had left `rtl/attn_block.vhd` there at HEAD's committed copy
rather than the working tree, and a blanket sync would have overwritten it.

```
=== do the hash SETS match? ===
INPUTS_IDENTICAL_ACROSS_BOXES          (28 files: 27 rtl + the .tcl)
```

### 4.3 The packaging run

```
PRESENCE_GATE_CLEAR          (VIVADO_PROCS=0 by /proc/PID/exe)
VIVADO_RC=0
SWAP_AFTER=823 MB            (823 MB before, so flat)

PACKAGE_DONE anchored count : pkg.stdout:1  pkg.log:1
PACKAGE_DONE UNanchored cnt : pkg.stdout:1  pkg.log:1
AXI_IFS: bus_interface component_1 s_axi
         bus_interface component_1 s_axi_aresetn
         bus_interface component_1 s_axi_aclk
^ERROR (line-anchored)            : 0 0
^CRITICAL WARNING (line-anchored) : 1 1
  [IP_Flow 19-5655] Packaging a component with a VHDL-2008 top file is not
  fully supported.
INFO: [Ipptcl 7-1486] check_integrity: Integrity check passed.
peak_max = 1321.4 MB
```

The one CRITICAL WARNING is structural and pre-existing: the packaged top IS
VHDL-2008 and the script's own header says so deliberately. **The cap was
never approached** -- 1,321 MB against `MemoryHigh=10G`, with swap flat -- so
this is an honest peak and not a capped one.

### 4.4 What came back, and the controls that should not have moved

```
=== files present in old vs new ===   SAME_FILE_SET
=== which files differ in content ===
  DIFFERS ./component.xml
  DIFFERS ./src/llama_engine_axi.vhd

=== controls ===
busInterface count                 3   ->   3
s_axi* port names                 22   ->  22   (identical sets)
src/*.vhd references in component  50  ->  50
```

`component.xml`'s diff is 11 lines: four checksum values, one
`coreCreationDateTime`, **and one line that is not metadata** (section 6).

### 4.5 Teeth and attribution, `sim:ipsync`

```
PRE-FIX   OVERALL PASS 0  FAIL 1     NOT GREEN:  - sim:ipsync
                                     REGRESSION: FAIL
POST-FIX  OVERALL PASS 1  FAIL 0     REGRESSION: PASS

md5 window   sim/regress.sh  91f5619ad8796867bf6e23c077906992  (start)
                             91f5619ad8796867bf6e23c077906992  (end)
             check_ip_sync.py b75cb96c426654bbf8fc8a57943ba95d (both)
   moved:    component.xml   39c270aa -> 61675a35
             src/...vhd      0a448eba -> 1e69a9fd  (== rtl/, 1e69a9fd)
```

Attribution control, read off the tree rather than by running the gate:

```
ghdl/analyze lines in regress.sh mentioning ip_repo : 0
gate-row commands naming ip_repo                    : 1
  2836:  [ipsync]="python3 $REPO/ip_repo/check_ip_sync.py"
gate-row commands naming ip_repo, EXCLUDING ipsync  : 0
```

**Nothing else catches it.** Note the first count of `1` is the `ipsync` row
matching itself -- the self-match trap in miniature, and the reason the
excluding count is printed separately rather than reasoned about.

`check_ip_sync.py --selftest` re-run for its own resolution floor:
9 rows, `CHECK ALONE=6`, `SELFTEST PASS`, with `CLEAN` and `NONVHD` correctly
not firing.

### 4.6 The gdnadapt seam

Scan of all 61 `llama_top` generics against the extraction: **exactly one**
used-but-undeclared name, `B_CONST_HBM`.

GHDL, same minimal library both sides (three packages only; the three
`unit not found` messages are the harness and are IDENTICAL on both sides,
which is what makes the delta attributable):

```
---- pre-fix (rc=1) ----
  b_const_hbm undeclared errors : 5
  missing-unit errors (control) : 3
  any OTHER message             : 1
      ooc_gdnadapt_top.before:377:30: bad attribute parameter
      (the boolean'pos site -- a derived consequence of the same name)
---- post-fix (rc=1) ----
  b_const_hbm undeclared errors : 0
  missing-unit errors (control) : 3
  any OTHER message             : 0
```

Teeth and attribution on the TRUE historical tree (generator and output both
from HEAD, so the text diff cannot fire for an unrelated reason):

```
new check ABSENT    GDNADAPT_CHECK ok                      rc=0
new check PRESENT   GENERIC NOT CARRIED ... B_CONST_HBM    rc=1   CHECK ALONE
```

**The pre-existing row printed `ok` over a file that does not compile.** That
is the whole finding.

---

## 5. Measured and REJECTED -- do not retry

- **Do not copy back only `src/*.vhd` and keep the committed
  `component.xml`.** MEASURED: the old `component.xml` carries
  `viewChecksum 21b19a24` (twice) and `CHECKSUM_752134c8` computed over the
  OLD source bytes. Keeping it beside new sources yields an internally
  inconsistent package, which is exactly the hand-edit
  `check_ip_sync.py` warns against in the finding text it prints. The
  regenerated pair is consistent; take both or neither.
- **Do not add a "regenerate and diff" row to the gate for `ip_repo/`.**
  Already measured and rejected by TRACK NOGUARD, and re-confirmed here:
  repackaging with no RTL change at all still rewrites `component.xml`
  (this run moved 4 checksums and a timestamp), so such a row would report a
  diff on EVERY run. Worse, all three packagers open with
  `file delete -force <ipdir>`, so an interrupted gate would DESTROY the
  artefact it is checking.
- **Do not run `bash ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh` for a job whose
  inputs are all clean.** It pushes the WORKING TREE. It was unnecessary here
  (27 clean inputs) and would have overwritten the committed-copy state
  LEVERCOST deliberately left on that box. Targeted rsync into a standalone
  root cost one extra command.
- **Do not add a `ghdl -a` compile step to `sim:gdnstale` today.** MEASURED:
  `ooc_gdnadapt_top` instantiates `gdn_block` and `gdn_state_store`, and
  NEITHER analyses under this box's GHDL 1.0 (rc=1 each, their own dependency
  closure failing; a fixpoint pass over `rtl/*.vhd` reaches 94 of 112 and
  stalls). The row could not be made green. The generic-closure check needs no
  compiler and catches the class that has actually bitten twice. **This is a
  deferral, not a refutation** -- a compile step remains the stronger check and
  is listed as open.
- **Do not trust `grep -c PACKAGE_DONE` unanchored.** It happened to agree
  here (1 and 1), which is luck: the sentinel is emitted by a `puts` in a
  script Vivado does not echo. The anchored form was used anyway and the
  agreement is reported as a control, not as permission.

---

## 6. Measurement traps hit, including my own

- **The attribution control fired for the wrong reason, twice, before it was
  readable.** Running the mutant generator from the scratch directory made
  `emit()`'s `os.path.relpath` normalisation derive the repo root from
  `__file__` in `/mnt/storage/...`, so the embedded source path came out as
  `../../../../home/orencollaco/GitHub/llama.vhdl/rtl/llama_top.vhd` and the
  text diff fired on line 3 of the header. **This is the exact trap
  `emit()` already documents in its own comment**, met from a direction that
  comment did not anticipate: it was written about the caller's *cwd and path
  style*, and it bites equally on the *script's own location*. The control only
  became readable once the mutants were copied into `sim/`. A control that
  fires is not a control that discriminated.
- **The first mutant was confounded by my own comment.** Removing only the
  `B_CONST_HBM` declaration while leaving the 14-line explanatory comment in
  the template produced a 31-line text diff, so the "historical" run was not
  historical. Rebuilt from `git show HEAD:...`. **Construct the control from
  the THING (the tree as it was), not from your edit minus one line.**
- **A pipe truncated a hash list silently.** `md5sum ... | tee file | head -3`
  gave `head` three lines and SIGPIPE'd `md5sum`, so the file recorded 3 of 28
  entries and looked complete. The `wc -l` that follows every hash dump here
  exists because of that.
- **The first `grep` for other consumers counted the row it was excluding.**
  `gate-row commands naming ip_repo` returned 1, which is `[ipsync]` itself.
  Reported as two separate counts rather than interpreted.
- **A 20,045-vs-20,328 byte comparison is not a diagnosis.** It is consistent
  with a stale package, an intended divergence, and a truncated file. The blob
  hashes are what distinguish them, and the diff is what rules out the third.

---

## 7. Open, not determined

- **The `versal` supportedFamilies difference is NOT root-caused.** The
  BC-250-packaged `component.xml` lists 23 supported families to the
  workstation-packaged one's 24, dropping `versal`. MEASURED against the
  obvious explanations and they do not hold: both boxes run Vivado **2023.2**
  (`xilinx:xilinxVersion` in both files), and both installs carry all **29**
  device-family directories under `data/parts/xilinx/`, `versal` included. It
  does not touch the RTL, the interfaces or the port set, and
  **`virtexuplusHBM` -- the FK33's own family -- is absent from BOTH lists**,
  so the target is unaffected either way and nothing in this repository
  consumes `ip_repo/` at all.
  **The reason to record it: CLAUDE.md's "bit-identical across the two
  machines" property was established for OOC synthesis and for a full
  place-and-route bitstream. It does NOT extend to IP-XACT packaging
  metadata, and this is the counter-example.** A number measured on either box
  is still quotable; a packaged `component.xml` is not byte-reproducible
  across them.
- **Whether the other two packaged IPs would survive a repackage.**
  `mac_axi_1_0` and `matvec_engine_1_0` are in sync by bytes and were
  deliberately NOT re-run (their packagers live in `hw/`, and running them
  would rewrite two more `component.xml` files for no gain). Whether they
  would come back clean is untested.
- **A compile step for `sim:gdnstale`.** Blocked on `gdn_block` and
  `gdn_state_store` not analysing under GHDL 1.0. Nobody has established
  whether that is a GHDL-1.0 limitation or a real defect in those files; the
  BC-250 now has GHDL 6.0.0 and is the obvious place to find out.
  `undeclared_generics()` is explicitly narrower than a compile step and says
  so in its docstring.
- **Whether `rtl/ooc_gdnadapt_top.vhd` now SYNTHESISES.** Only the undeclared
  name was removed, verified by analysis. No Vivado run was made against it,
  so LEVERCOST's harness is unblocked in the sense that the known error is
  gone, not in the sense that it has been shown to complete.
- **How long `ip_repo/` had been unguarded before the `ipsync` row existed.**
  Not investigated.

---

## 8. Corrections

None yet. Append dated CORRECTION sections here rather than editing the above.
