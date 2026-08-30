# The board against the tree: nine of fourteen backlog rows were already done, and the open work is not what the table said

**Date:** 2026-08-29. Branch `fpga`. Track BOARDAUDIT.
**Audited against `git rev-parse HEAD` = `5a19f9840bed61d0d7727faf75d39885c321516c`**,
pinned as its own step before any other command, because HEAD moved roughly
sixty times during the day and two other tracks had straddled a concurrent
commit doing this exact thing.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado` in any mode,
nothing under `hw/fk33/host/` or `hw/fk33/tcl/`, nothing opening `/dev/xdma*`.
No simulation was run and no gate was run; the one machine measurement taken was
`df`/`free`. Nothing outside `docs/WORKLOG.md` and this file was edited.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

> `docs/WORKLOG.md` is the board this project dispatches from. **It is wrong
> often enough to have wasted three agent dispatches today**, and the failure is
> always the same shape: a row is completed, the work lands, and nobody strikes
> the row.
>
> [...] **Your job is to make the board true, once, thoroughly, so it stops
> happening.**
>
> 1. **Audit EVERY row of the BACKLOG table against the actual tree.** [...] A
>    row is DONE if the work exists, regardless of whether anyone said so. Check
>    by reading the tree and `git log`, never by reading another document -- a
>    document is what has been wrong every time.
> 2. **Audit EVERY entry in "Open issues"** the same way.
> 3. **Audit the "Decisions taken" table**: does each decision's stated trigger
>    still make sense, and has any trigger already fired?
> 4. **Audit "File ownership, right now"**, which is visibly stale.
> 5. **Rewrite the board so it is true.**
> 6. **Then say what is ACTUALLY ready to dispatch**, ordered.
>
> **Do not just tidy. Find what is genuinely open and undone.** [...] The
> question behind every row is: **what stands between this project and 9B
> inference running correctly on the card?**

## 2. The answer, up front

**Nine of the fourteen backlog rows were already done. Four had never been
struck by anyone, and the audit found three of those four itself** -- rows 5, 8
and 9, which nobody had reported, bringing the day's tally from six unstruck
rows to nine. Two Open issues (OI-4, OI-12) were stale and closable. Three
Decisions had triggers that had already fired.

**But the tidy-up is not the finding. The finding is what the board never said
at all:**

> **The card carries subsystem A alone, and no tool in this repository can start
> a job on it. The engine's register map is at BAR offset `0x00012000` and
> nothing host-side references that address. The host seam that WAS written
> drives a register block that no RTL implements. So nothing has verified what
> the card computes, and nothing currently can.**

**And the board has lost most of the project's own record.** Of **91** write-ups
dated 2026-08-28 or 2026-08-29, only about **18** have a row in the Landed
table. Eighteen more are named only by a bare comma-separated sentence with no
commit and no result; roughly **35 appear nowhere at all** -- including
`thermal-guard-255-trips.md`, **an OPEN hardware defect on the card that is
tripping the compute halt roughly once every three minutes.** Three of the day's
four wasted dispatches were onto work whose write-up was sitting in
`docs/debugging/` unreferenced.

## 3. The procedure, and what each step isolates

The whole method is one rule: **judge every claim against the tree, never
against another document.** Each of the seven historical failures came from
believing a document, and the board is a document.

| # | probe | what it isolates |
|---|---|---|
| 1 | `git rev-parse HEAD` as its OWN command, before anything else | Pins the tree. Two tracks today straddled a concurrent commit by chaining this into a `git archive`. |
| 2 | For each backlog row, `ls`/`grep` for the ARTEFACT the row asks for | Separates "the row is open" from "nobody struck the row". A row asking for a mutation script is answered by the script existing, not by any prose. |
| 3 | `head -30` of each candidate write-up in `docs/debugging/` | The write-ups declare their own TRACK and backlog item number in their headers. This is the cheapest possible mapping from artefact to row, and it is the step nobody had run. |
| 4 | `git merge-base --is-ancestor <sha> HEAD` per cited commit | A commit named on the board may not be on this branch. Twenty were checked; all twenty are ancestors. |
| 5 | `grep -ci <write-up filename> docs/WORKLOG.md` for each write-up | The direct measurement of "the board lost this". Returned 0 for fifteen files. |
| 6 | Read the RTL for each Open issue's claim (delegated, read-only) | Where a document and the RTL disagree, the RTL wins. Five RESOLVED claims confirmed, two entries found stale. |
| 7 | Trace the on-card path: `fk33_engine.vhd` instantiations, then `gen_pcieep.py`'s address constants, then `grep` those constants across `hw/fk33/host/`, `server/`, `tools/` | **The load-bearing probe.** Each step is a fact the board states somewhere; the composition is the gap, and no single track's write-up could see it because each owned one end. |
| 8 | `grep -rln 'LLM2\|4C4C4D32\|SEAM_ID' rtl/ hw/fk33/rtl/` | Separates "the host seam is written" from "the host seam has something to talk to". |

Step 7 is the one worth reusing. **Every fact in it was already recorded on the
board or in a write-up; the defect was that no one had composed them.** That is
the same failure the project's own verification discipline names at the unit
level -- a column of well-verified units is jointly compatible with a broken
composition -- reproduced at the level of the board itself.

## 4. The evidence, as raw output

### 4.1 The card carries subsystem A alone

```
$ grep -nE 'entity work\.' hw/fk33/rtl/fk33_engine.vhd
1156:  eng : entity work.matvec_int4_desc_axi

$ grep -rn 'llama_top' hw/ --include=*.vhd --include=*.py --include=*.tcl
hw/fk33/results/lutdiet_2026-08-29/rtl/lutdiet_rms_flat.vhd:11:-- by doing what rtl/llama_top.vhd's D-vec norm adapter already does at
```

One instantiation. No B, no C, no D. The only mention of `llama_top` under
`hw/` is inside a comment in a results artefact.

### 4.2 Nothing host-side can reach the engine

```
$ grep -n 'ENG_CTL_BASE\|ENG_XW_BASE' hw/fk33/gen_pcieep.py
308:ENG_CTL_BASE   = 0x00012000    # 4 KB, the engine's own register map.
309:ENG_XW_BASE    = 0x00013000    # 4 KB, the activation writer

$ grep -rn '0x12000\|0x00012000\|0x13000\|0x00013000\|ENG_CTL\|ENG_XW' \
      hw/fk33/host/ server/ tools/ hw/*.c
(end)
```

`hw/fk33/host/fk33_regs.h` defines `FK33_ID_BASE`, `FK33_SCRATCH_BASE`,
`FK33_DMABRAM_BASE`, `FK33_THERM_*` and the PCI ids. **There is no engine
block.** `fk33ctl.py`'s commands are `sysmon thermal id scratch gpio vccint
selftest bench load verify`; none starts an operation.

### 4.3 The host seam drives a contract with no gateware

```
$ grep -n 'FK33_SEAM_BASE_PROPOSED\|FK33_SEAM_ID_MAGIC' server/fk33_seam.h
179:#define FK33_SEAM_BASE_PROPOSED   0x0000E000u
202:#define FK33_SEAM_ID_MAGIC        0x4C4C4D32u

$ grep -rln 'LLM2\|4C4C4D32\|4c4c4d32\|SEAM_ID\|seam_id' \
      rtl/ hw/fk33/rtl/ hw/fk33/gen_pcieep.py hw/fk33/gen_fk33_engine.py
(end)

$ grep -n '0x0000E000\|0xE000' hw/fk33/gen_pcieep.py
(end)
```

And the file's own header, verbatim, lines 1 to 3 of `server/pl_backend.c`:

```c
/* server/pl_backend.c -- v2 of the host seam.  See pl_backend.h, then
 * fk33_seam.h.  Nothing here has ever run against the card.
 */
```

`server/fk33_seam.h:171` says it about itself too: **"BASE IS PROPOSED, NOT
DECIDED."**

### 4.4 `llama_top` composes everything and is not what ships

```
$ grep -nE 'entity work\.[a-z_0-9]+' rtl/llama_top.vhd | sed 's/.*entity work\./  /' | sort | uniq -c
      1   attn_block          1   attn_kv_axi         1   gdn_block
      1   matvec_int4         1   rmsnorm_rs          1   sampler_stream
      1   seq_desc_fetch      1   seq_opdec           1   seq_region_lock
      1   seq_vec_issue       1   seq_vec_res

$ grep -nE 'C_REAL|C_KV_AXI|NORM_REAL|B_SRC_REAL' rtl/llama_top.vhd | grep ':='
255:    B_SRC_REAL : boolean := false;
351:    NORM_REAL  : boolean  := false;
465:    C_REAL      : boolean  := false;
493:    C_KV_AXI    : boolean  := false;
```

All four real paths default FALSE, and it binds `matvec_int4`, which has no
descriptor plane. (Line numbers in this file are unstable; the content is the
citation.)

### 4.5 The board has lost fifteen tracks

```
$ for t in capture-llama-top-r9bs c-seam-layer-interleave first-engine-load \
           embedding-bf16-upgrade host-embedding-gather ref-token-automatic-verdict \
           logits-seam-model second-fk33-verify shell-pblock gdn-block-oracle; do
    printf "%-32s %s\n" "$t" "$(grep -ciE "$t" docs/WORKLOG.md)"; done
capture-llama-top-r9bs           0
c-seam-layer-interleave          0
first-engine-load                0
embedding-bf16-upgrade           0
host-embedding-gather            0
ref-token-automatic-verdict      0
logits-seam-model                0
second-fk33-verify               0
shell-pblock                     0
gdn-block-oracle                 0
```

### 4.6 The three rows nobody had reported

```
$ head -5 docs/debugging/2026-08-29_host-seam-v2.md
# The host seam v2: moving prefill/decode off the AXU3EG's shape, and wiring the C tokenizer
**Track:** SERVER, backlog item 5

$ head -4 docs/debugging/2026-08-29_gdn-recur-coverage-and-dm.md
# The 8.955 LSB is not the d_m grid defect, and the gate that held it fires on the honest unit
Track: B-RECUR (backlog item 8)

$ head -3 docs/debugging/2026-08-29_spec-reconciliation.md
# Subsystem C's spec against its RTL, and a staleness sweep of the documents that brief agents
**Date:** 2026-08-29. Branch `fpga`. TRACK SPECREC, backlog item 9 widened.
```

Each names its own backlog row in its own header. Row 9 is the sharpest case:
the Landed table has carried a SPECREC row the whole time, so **the board
contradicted itself in two sections and neither reader noticed.**

### 4.7 Three decision triggers had already fired

| decision | stated trigger | state |
|---|---|---|
| Congestion fallback is lever C | "If TRACK PBLOCK routes the design, the fallback is not needed" | **FIRED.** `ed1ffe2`; `ASX_route_status.rpt` = 0 nets with routing errors, 288,506 fully routed |
| Cross-stack read measurement | deprioritised because "the design does not route, so there is no engine bitstream to measure with" | **PREMISE FALSIFIED.** The design routes and the bitstream is loaded on card 1 |
| Card 2's factory flash: DUMP IT | "Needs Oren at the bench" | **DONE.** Two reads, both `dcb97432538b9c7d2855b1d9c93658f7` |

### 4.8 The card-2 backup, verified but unprotected

```
$ md5sum hw/fk33/bit/fk33_factory_backup_153300001366.bin \
         hw/fk33/bit/fk33_factory_backup_153300001366_read2.bin
dcb97432538b9c7d2855b1d9c93658f7  ..._153300001366.bin
dcb97432538b9c7d2855b1d9c93658f7  ..._153300001366_read2.bin

$ git ls-files hw/fk33/bit/
(end)

$ df -h /
/dev/nvme1n1p6  1.3T  1.2T  121G  91% /
```

Two independent reads agreeing is the right teeth-check for a flash readback,
and the write-up did it. **But the only surviving SQRL factory image is
untracked, on a filesystem at 91%, with no off-disk copy.**

## 5. Measured and REJECTED -- do not retry

* **Auditing the board by reading `docs/debugging/` write-ups as the source of
  truth.** They are documents, and a document is what has been wrong every
  time. They are excellent for the MAPPING (a write-up declares its own track
  and backlog row in its header, which is step 3 above and is cheap and
  reliable), and they must not be trusted for STATE. Two write-ups on this tree
  contain findings their own later addenda withdraw; one is the on-card memory
  path, which was reported as broken and is fine.
* **Reconstructing the fifteen lost tracks into Landed-table rows.** Attempted,
  abandoned. The write-ups already are the artefact, at higher fidelity than any
  row could restate, and re-summarising them creates a second document to go
  stale. The board now names the fifteen filenames and stops there. **A pointer
  that resolves beats a summary that drifts.**
* **Concluding that backlog row 2 is fully closed because it routes.** Its own
  last sentence says "Nothing has verified what it computes; it was never
  loaded." Half of that is now false (it HAS been loaded) and half is still
  true and is the most important open fact on the board. Striking the row
  wholesale would have deleted the finding. It was split instead: the routing
  half closes, the computation half becomes row N1.
* **Treating `rtl/llama_top.vhd` as the shipping composition** because it
  instantiates all four subsystems. It binds `matvec_int4`, not
  `matvec_int4_desc_axi`, and every real path defaults FALSE. TRACK SHELL had
  already recorded this ("backlog 2's `llama_top` is a sim top") and the note
  did not survive into any row.
* **Running the full gate.** Not run, deliberately, and this is stated because
  the brief asked. The audit's claims are about what EXISTS in the tree, which
  `ls`, `grep` and `git` answer; no claim here depends on a pass count. The
  gate was measured by BGATE2 at `1216a5e` as `OVERALL PASS 99 FAIL 0` and
  `BASELINE_PASS=93` was confirmed present at HEAD by reading `sim/regress.sh`.

## 6. Measurement traps hit, including my own

* **I nearly wrote up "the on-card memory path does not work" as an open
  blocker.** `docs/debugging/2026-08-29_first-engine-load-on-card.md` states it
  as answer 2 in its own "answers up front" -- and **withdraws it in an addendum
  further down the same file**. Reading the first section and stopping would
  have put a fixed defect at the top of a board being rewritten for accuracy.
  **The correction was appended in place rather than editing history, exactly as
  house style requires, which is what made the trap survivable: the withdrawal
  is IN the file. It is also what makes the file's own summary unsafe to quote.
  Read every addendum before quoting any "answer up front".**
* **The session's own `gitStatus` snapshot named five commits (`8ba48e4` and
  four ancestors) that appear nowhere in `git log --oneline -30`.** They are
  genuine ancestors of HEAD, just far behind it: HEAD moved about sixty times
  after the snapshot. **A harness-supplied git snapshot is a document like any
  other, and this one is a snapshot of a tree that no longer exists.** Verified
  with `git merge-base --is-ancestor`, which is the only cheap way to tell a
  stale sha from a foreign one.
* **A backlog row can be simultaneously done, undone and self-contradicting.**
  Row 2 is done for routing, open for computation, and its own closing sentence
  is half-false. Rows are not booleans and forcing them to be is how the
  computation half nearly got struck.
* **The delegated Open-issues check reported OI-3 as "likely fixed".** It was
  right to refuse to call it fixed: the OI3B gate plausibly kills both named
  mutations, but **no mutate script and no line of OI3B's teeth table names
  either one.** A gate that ought to catch a defect and has never been shown to
  is the project's oldest recurring defect class. It is recorded as OPEN (row
  N6) with the reasoning, not as closed with an argument.

## 6a. The defect the audit found that nobody was looking for

**`docs/debugging/2026-08-29_thermal-guard-255-trips.md` (`0540c35`) is an OPEN
write-up, it describes a live hardware defect, and it is referenced nowhere on
the board.** It was found by the write-up inventory, not by any of the targeted
probes, which is the argument for doing the inventory at all.

MEASURED on card 1 running `fk33_pcieep_therm.bit`: the thermal trip counter was
cleared to 0 and read **255** about fourteen hours later. 255 is the saturating
maximum of an 8-bit field, so the true count is 255 or more, and the rate is
**about one trip every three minutes**. It is not heat:

| | reading | halt threshold |
|---|---|---|
| die | 35.3 C, peak 37.3 C | 90 C |
| HBM code | 37 / 37, peak 38 / 38 | 85 |
| SYSMON user alarm sticky | **0**, never fired | 90 C |
| SYSMON OT sticky | 0 | 101 C |

`trip_cause` was **0** on a saturated counter. What WAS set is `THERM_STATUS`
bit 30: **the two HBM temperature copies disagreed, a CDC fault.** The
hypothesis in the file, explicitly not confirmed, is the HBM staleness path
declaring the sensor invalid after `G_STALE_MS` = 250 ms and correctly failing
safe by treating an invalid sensor as HOT.

**Why this mattered enough to interrupt the audit and put it on the board.**
Each trip halts the compute domain. Oren is authorised to run on card 1 tonight
in order to answer backlog row N1, which is the first arithmetic ever checked on
this silicon. A stall or a wrong answer from that run, with a non-zero trip
count, **is not evidence about subsystem A** -- and the write-up's own words are
that this is "precisely the class of fault that gets attributed to the wrong
subsystem for a week". The board now says so at row N1 and as open issue
THERM-255.

**Carry this measurement trap with it:** twelve consecutive clean five-second
samples were taken after clearing the counter and proved nothing. **A
sixty-second clean sample is not evidence of absence at a three-minute mean
interval.**

## 7. Open, not yet answered

* **Whether the OI3B gate actually kills OI-3's two mutations.** Not measured
  here; it needs GHDL and `sim/tb_llama_top.vhd`, which TRACK KVVALUE owns.
  Backlog row N6.
* **Whether the ~35 unrecorded tracks left any OTHER finding the board never
  recorded.** All 91 headers were read; the bodies were not, except for about
  eight. The audit measured that they are absent from the board and did not
  measure what is inside them. **This is the largest thing this audit did not
  do, and THERM-255 is the proof that it matters: one open hardware defect
  surfaced from a header alone, and nothing rules out others.** The cheap next
  step is to read the ~35 Bucket-C headers' "Open, not yet answered" sections
  specifically, which is where an unrecorded defect would be.
* **Whether backlog row N1 is even runnable as described.** It asserts that a
  descriptor job can be built against a resident `.mv4i` and started at
  `0x12000`. The address is MEASURED; that the descriptor plane is correctly
  wired to it in the routed build is NOT, and the only way to find out is to
  try.
* **What `rtl/llama_top.vhd` would cost as a synthesis top.** N3 assumes it is
  the starting point for the card's composition. Nobody has synthesised it, at
  any shape. `hw/fk33/results/` contains no `llama_top` artefact of any kind.
* **The 9.8% LUT margin.** LUTDIET's projection, not a measurement. Row N5.

## 8. Corrections to the brief that dispatched this track

* The brief listed **six** confirmed unstruck-row instances plus the In flight
  table. The audit found **three more** (rows 5, 8, 9), so the count is nine
  rows plus the table. The brief's own framing anticipated this: *"a brief's
  numbers are a snapshot of a document, not of the tree."*
* The brief said the board "does not clearly" reflect that nothing has verified
  what the design computes. Measured, it is stronger than that: **the board
  states the fact once, in the last sentence of backlog row 2, immediately after
  a clause that is now false** ("it was never loaded"). A true fact adjacent to
  a false one in a struck row is not a record.
* The brief's ground-truth list of tonight's landings is accurate; all seven
  named commit groups were verified as ancestors of HEAD.
* The brief asked for the state of the board and got it, but **the audit's own
  first estimate of the lost-track count was 15 and the measured figure is
  about 53 of 91** (18 name-dropped without a row, ~35 absent entirely). The 15
  came from a hand-picked sample of filenames, which is exactly the "coverage
  of the input space is not coverage of the output space" trap this project has
  written down twice. The full enumeration was worth its cost and is what
  surfaced THERM-255.
