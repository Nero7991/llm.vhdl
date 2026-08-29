# Subsystem C's spec against its RTL, and a staleness sweep of the documents that brief agents

**Date:** 2026-08-29. Branch `fpga`. TRACK SPECREC, backlog item 9 widened.
**Reading commit:** `abbd2ed` (`docs: PCIe reconfiguration options costed`).
HEAD advanced to `0db9034` mid-session; MEASURED, that commit touches
`docs/WORKLOG.md` and nothing else, so every file:line below still resolves.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/` scripts, nothing opening `/dev/xdma*`. No simulation was run
and no code was edited.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

> **Part 1: subsystem C spec reconciliation (the original item 9).**
>
> Six spec-named units do not exist -- `attn_lane`, `attn_score_tree`,
> `attn_acc`, `attn_qk_norm`, `attn_ctrl`, and `attn_kv_axi` was absent until it
> was built. The design took a different decomposition and the spec was never
> updated. **Reconcile the spec to the RTL, not the other way round.** Where the
> spec describes a unit that does not exist, say what actually implements that
> responsibility, with file:line.
>
> **Part 2: a staleness sweep of the load-bearing documents.**
>
> `docs/2026-08-28_9b-completeness-audit.md` is the project's map. Its own
> section 8 correction was appended **56 commits stale**, and roughly **forty
> more have landed since**, several of which overturn its remaining verdicts
> (`attn_kv_axi` now exists; the layer program generator exists; the logits
> egress exists as of `c754e39`). An independent review flagged this as the
> reason the whole-model-reference task fell through the cracks: **its section 5
> items never migrated to the backlog.**
>
> Sweep the documents that briefs are actually drawn from. Find the claims that
> are now false, and correct them **in place with dated CORRECTION sections,
> never by silent deletion**.
>
> Prioritise by blast radius: a wrong number in a document that briefs agents is
> worse than a wrong number in a debugging writeup nobody reads. Say how you
> prioritised.
>
> **Part 3: name what should have become work and did not.**

---

## 2. The answer, up front

**Part 1. All thirteen spec-named responsibilities are implemented. Six are
implemented inside files with other names, and one real unit is on no spec list
at all.** The "six absent units" verdict was an absent NAME read as an absent
RESPONSIBILITY.

| spec name | implemented by, at `abbd2ed` |
|---|---|
| `attn_qk_norm` | `rtl/rmsnorm_rs.vhd:59`, instantiated directly at `rtl/attn_block.vhd:772`. No wrapper written, deliberately |
| `attn_lane` | `rtl/attn_mac_array.vhd:431-433` (the `LANES` multiply loop) |
| `attn_score_tree` | **split**: `rtl/attn_mac_array.vhd:441-456` (multiply + per-head adder tree) and `rtl/attn_score_q12.vhd:128` (alignment, s32 sum, Q12 conversion) |
| `attn_acc` | `rtl/attn_mac_array.vhd:242,247` (the file), `:457-470` (one shared adder per lane), `:492` (readback) |
| `attn_ctrl` | `rtl/attn_block.vhd:586-597`, a 36-state `ph_t`; `case ph is` at `:1140` |
| `attn_kv_axi` | `rtl/attn_kv_axi.vhd:267`, instantiated ONE LEVEL UP at `rtl/llama_top.vhd:3420` under `C_KV_AXI` (`:405`), not inside `attn_block` |
| the other seven | present under their own names, all instantiated by `rtl/attn_block.vhd` at `:779, 790, 806, 823, 861, 875, 885, 901` |
| **not on the spec's list** | `rtl/attn_score_q12.vhd`, 504 lines, bit-exact against three double oracles. It is half of `attn_score_tree` |

**Part 2. Fourteen documented claims were false at `abbd2ed`**, corrected in
place across **five** files with dated CORRECTION sections (twelve in the audit,
one in the C design spec, one carried by two port-budget documents). The four
highest-blast-radius:
`attn_kv_axi` does not exist (it does); nothing emits a descriptor program (two
tools do); the regression floor is 72/78 (it is 85); subsystem A needs 27 AXI
read masters (the shipping entity needs **28**, which takes the free HBM port
count for B and C from 3 to 2).

**Part 3. Nine analyses concluded that something needed doing and produced no
backlog row.** The two with the highest value are `ref/gdn_block_vec.c`, which
does not exist and is exactly the artefact class that found `attn_block`
computing 64 of 64 mantissas wrong, and **subsystem A having zero mutation
scripts** while being the only subsystem running on silicon. Listed in section 7,
NOT added to the backlog.

**The generalisable finding, and it is the one worth carrying:** the audit's own
section 8.1 already recorded that a per-unit evidence class says nothing about
the composition. This sweep found the same shape one level up. **A document's
correction section goes stale exactly as fast as the document did**, and section
8.3, the part headed "what the audit got RIGHT", was the single most-wrong
paragraph in the file. A reader trusts a correction section MORE than the body,
so a stale correction is worse than no correction.

---

## 3. The procedure, in the order it was run

Each step names what it controls for.

1. **Read `CLAUDE.md` and `docs/WORKLOG.md` first.** Controls for: editing a
   file another track owns, and for re-deriving something already recorded in
   Open issues.

2. **Pin the reading commit and prove the paths are quiescent.**
   `git rev-parse HEAD` then `git status --porcelain rtl/`. Controls for the
   trap that five live tracks make a working-tree read meaningless. This step
   is what caught trap 8.1 below and is the reason `505` is not in this document
   as a fact.

3. **Locate the spec text, not the spec's reputation.**
   `grep -rn "attn_lane\|attn_score_tree\|..." docs/` over all of `docs/`.
   Controls for reconciling the wrong document: two C specs exist
   (`2026-08-21-gated-attention-design.md`, the numeric contract, and
   `2026-08-27-C-gated-attention-skeleton.md`, which carries the thirteen-unit
   table). Only the second names the six units.

4. **Enumerate what `attn_block` actually instantiates**, by grep for
   `entity work.` rather than by reading prose. Controls for a unit that exists
   as a file and is wired to nothing, which is the exact defect the audit found
   in `seq_top_skel`.

5. **For each spec name with no file, find the arithmetic.** Read
   `rtl/attn_mac_array.vhd`'s declarations and its S1/S2 pipeline stages, and
   `rtl/attn_block.vhd`'s `ph_t`. Controls for declaring a responsibility
   "implemented" on the strength of a header comment. The header was read
   afterwards, as corroboration, not as the finding.

6. **Check the skeletons are still skeletons.**
   `grep -rl "entity work.<skel>" rtl sim tb hw`. Controls for the build hazard
   the audit named: a `rtl/*.vhd` glob synthesising five files that compute
   nothing.

7. **Sweep the audit claim by claim**, taking each against a tool rather than
   against another document: `ls`, `git ls-files`, `grep -n`, `git show
   <commit>:<path>`. Controls for the failure mode named in the brief -- a tidy
   set of documents that agree with each other and not with the RTL.

8. **Prioritise before writing.** Ranking below.

9. **Write corrections in place, append-only.** No claim was deleted; each is
   marked withdrawn where it is.

### 3.1 How blast radius was ranked

The ranking is **how likely a wrong sentence is to end up inside an agent's
brief**, times how expensive the resulting wrong action is.

| tier | document | why | acted |
|---|---|---|---|
| 1 | `docs/2026-08-28_9b-completeness-audit.md` | It is the project's map, it is written to be quoted, and its section 8 is a correction section, which readers trust more than a body | **yes**, new section 9 |
| 1 | `docs/superpowers/specs/2026-08-27-C-gated-attention-skeleton.md` | Its section 2 table is the literal source of backlog item 9's claim | **yes**, new section 2.1 |
| 1 | `docs/superpowers/specs/2026-08-21-gated-attention-design.md` | Called "the authority on C's numeric contract", and its section 1.4 dimensions table is Qwen3.5-**0.8B**. Every head count is wrong by 2x to 4x, and section 4 supersedes it 1,800 lines later | **yes**, top-of-file correction plus a marker above the table |
| 2 | `docs/2026-08-28_can-27-read-masters-be-served.md` | "27 masters" is quoted in the worklog twice and in three other docs; the real count is 28 and it changes the free-port budget | **yes**, appended correction |
| 2 | `docs/2026-08-28_token-io-path.md` | Carries the same 27-of-30 arithmetic in two places, and it is where the LM head question gets read | **yes**, section 12 |
| 3 | debugging write-ups from 2026-08-23 to 2026-08-27 | Rarely quoted into briefs; several are already superseded by their own successors, and each carries a "Measured and REJECTED" section that must not be disturbed | **no**, deliberately |
| 3 | `docs/2026-08-27_weight-path-audit.md` | Already corrected by the audit's section 7 items 1-3, so a second correction layer adds a hop rather than removing one | **no** |

**Tier 3 was left alone on purpose.** The brief's failure condition is a tidy
document set; touching a superseded analysis for tidiness is that failure.

---

## 4. Evidence, as captured output

All at `abbd2ed` unless stated.

### 4.1 The commit and the quiescent tree

```
$ git rev-parse HEAD
abbd2edaafc6809210f9458ff03fe2953dede602

$ git status --porcelain rtl/
(empty)
```

### 4.2 What `attn_block` instantiates -- ten units, and the array is one of them

```
$ grep -n "entity work\." rtl/attn_block.vhd
772:  u_norm : entity work.rmsnorm_rs
779:  u_tw : entity work.attn_twiddle
790:  u_rope : entity work.attn_rope
806:  u_quant : entity work.attn_kv_quant
823:  u_arr : entity work.attn_mac_array
845:    u_sq : entity work.attn_score_q12
861:    u_sm : entity work.attn_softmax
875:  u_recip : entity work.attn_recip
885:  u_gate : entity work.attn_gate
901:  u_emit : entity work.attn_emit

$ grep -n "entity work.attn_kv_axi\|entity work.attn_block" rtl/llama_top.vhd
3420:      u_kv : entity work.attn_kv_axi
3513:    u_attn : entity work.attn_block
```

This one command refutes `docs/2026-08-28_9b-completeness-audit.md:73`'s
*"No `rtl/` file instantiates a single C unit."*

### 4.3 The skeletons are still instantiated by nothing

```
$ for e in attn_lane_skel attn_c_ports_skel; do grep -rl "entity work.$e" rtl sim tb hw; done
(no hits)
```

`attn_rescale_skel` has exactly one parent, `sim/tb_attn_rescale.vhd`, which is
its functional bench and not a design instantiation.

### 4.4 `attn_mac_array` is three spec names

```
$ sed -n '13,18p' rtl/attn_mac_array.vhd
-- This file is attn_lane + attn_score_tree + attn_acc from the C skeleton's
-- section 2 table, as ONE unit.  They are one unit here and three names there
-- because the accumulator file cannot be separated from the lane that writes
-- it: C spec 2.6 measures the read mux going non-linear above 16 entries per
-- lane precisely because the file is INSIDE the lane, and a decomposition that
-- put a port between them would be pricing a structure nobody builds.
```

The arithmetic, read independently of that header:

```
$ sed -n '431,433p;441,443p;457,459p' rtl/attn_mac_array.vhd
        for l in 0 to LANES-1 loop
          p_reg(l) <= a_reg(l) * b_reg(l);
        end loop;
          when M_SCORE =>
            for h in 0 to QH_TILE-1 loop
              t := (others => '0');
          when M_PV =>
            -- ONE shared adder per lane; see the header's MEASURED note.
            for h in 0 to QH_TILE-1 loop

$ sed -n '242p;247p' rtl/attn_mac_array.vhd
  type acc_arr is array (0 to NACC-1) of signed(ACC_W-1 downto 0);
  signal acc   : acc_arr := (others => (others => '0'));
```

### 4.5 `attn_ctrl` is `attn_block`'s phase machine, 36 states

```
$ sed -n '586,598p' rtl/attn_block.vhd
  type ph_t is (P_IDLE,
                P_KLOAD, P_NORMGO, P_NORMW,
                P_ROPEGO, P_ROPEW,
                P_KQGO, P_KQW,
                P_VQGO, P_VQW, P_WREC,
                P_QN,
                P_SWGO, P_RECK, P_HDR, P_SCORE, P_SCW,
                P_EPW, P_RSPASS, P_RSACK,
                P_RECV, P_PV, P_POSN,
                P_SFW, P_RCP, P_RCW, P_GATEGO,
                P_GAT1, P_GAT2, P_GAT3, P_GAT4, P_GATEW, P_GN,
                P_HN, P_EMITGO, P_EMITW, P_DONE);
  signal ph : ph_t := P_IDLE;
```

### 4.6 The audit's numbers, re-measured

```
$ git ls-files 'sim/mutate_*.sh' | wc -l
30                              # audit says 17

$ git show abbd2ed:sim/regress.sh | grep -n "^BASELINE_PASS"
377:BASELINE_PASS=85            # audit says 72; its section 8.2 says 78

$ ls rtl/*.vhd | wc -l
91                              # audit says 82

$ git ls-files hw/fk33/bit | wc -l
0                               # audit section 6.9 STANDS

$ ls ref/ | grep -E "gdn_block|l2norm|run9b"
l2norm_rs_vec.c                 # audit 5.4 CLOSED
run9b
run9b.c                         # audit 5.1 CLOSED
                                # ref/gdn_block_vec.c ABSENT: audit 5.6 STANDS
```

Mutation census by family, at `abbd2ed`: 9 `attn`, 8 `gdn`, 5 `seq`, 5 `ref_*`,
2 `llama_top`, 1 `rmsnorm_bf`. **Zero for subsystem A.**

### 4.7 Section 4 item 2's six files are all still absent, and A reaches HBM anyway

```
ABSENT  rtl/hbm_rd_lane.vhd
ABSENT  rtl/hbm_weight_streamer.vhd
ABSENT  rtl/fk33_arena_pkg.vhd
ABSENT  rtl/matvec_int4_hbm.vhd
ABSENT  ref/hbm_weight_streamer.c
ABSENT  sim/tb_hbm_weight_streamer.vhd

$ grep -n "entity work\.\|matvec" hw/fk33/rtl/fk33_engine.vhd | head -3
4:-- Board-facing wrapper around rtl/matvec_int4_desc_axi.vhd (subsystem A's
1156:  eng : entity work.matvec_int4_desc_axi
```

The plan was superseded, not executed. A brief that reads item 2 literally
commissions six files that are not the design.

### 4.8 The 28th master

```
$ sed -n '7,8p' hw/fk33/rtl/fk33_engine.vhd
--   27 weight/scale AXI read masters + 1 descriptor master = 28
--   masters, each on its own HBM SAXI port, each 256 bits wide.

$ sed -n '169,174p' rtl/matvec_int4_desc_axi.vhd
    d_arvalid : out std_logic;
    d_arready : in  std_logic;
    d_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    d_arlen   : out std_logic_vector(7 downto 0);
    d_arsize  : out std_logic_vector(2 downto 0);
    d_arburst : out std_logic_vector(1 downto 0);
```

`m_ar*` at `:182-191` is a separate `NPORTS_W + NPORTS_S` = 27-wide array
(`:103-104`). **DERIVED: 27 + 1 = 28 of 30 usable HBM ports, leaving 2 for B and
C, not 3.**

### 4.9 The packer no longer refuses the FK33 geometry

```
$ sed -n '175p' rtl/weight_streamer.vhd
  -- describes a different file.  This replaces the old "AXI_DW >= SW and
```

`NPORTS_S` is a generic at `:70`. `tools/pack_int4.py:109-139` lists three
refusals and the FK33 geometry is not among them. Packed sets exist:
`/mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad`, 250 `.mv4i`. The audit's
"accepted set is `ROWS_IF in {1,2,4,8}`" is dead.

### 4.10 The 9B checkpoint exists

```
$ ls -la /mnt/storage/llama-models/qwen35-9b/
-rw-rw-r-- 1 orencollaco orencollaco 17920697312 Aug 28 07:52 Qwen3.5-9B-BF16.gguf
```

`n_tokens = 248320` from that file
(`docs/debugging/2026-08-28_qwen35-tokenizer.md:90`), equal to
`rtl/model_cfg_pkg.vhd:70`. Audit 5.3 and 6.7 both close.

---

## 5. Measured and REJECTED -- do not retry

1. **Reading the GGUF metadata directly with a hand-written Python parser.
   REJECTED, it does not terminate in a useful time.** The script seeks past
   `tokenizer.ggml.tokens` one length-prefixed string at a time; at 248,320
   entries it exceeded a 120 s timeout and was killed (`Exit code 143`). Use
   `tools/extract_tokenizer.py --summary`, which already exists, or read the
   number out of `docs/debugging/2026-08-28_qwen35-tokenizer.md:90`, which
   already recorded it. Do not write a fourth GGUF parser.

2. **Trusting `docs/debugging/2026-08-28_subsystem-c-top-and-mac-array.md`'s
   own unit table as the reconciliation. REJECTED as a source.** That file's
   table (`:56-72`) is correct and I checked it, but it is a document, and the
   brief's whole point is that documents brief agents wrongly. Every row in
   section 2 above was taken from the RTL first and compared to that table
   afterwards. They agree; that agreement is a corroboration and is not what the
   claim rests on. **Do not shortcut this next time: the fact that it agreed is
   not evidence that reading it first would have been safe.**

3. **Rewriting the audit's section 1 tables to be current. REJECTED.** They are
   dated per-unit evidence classes at `b66c4b4`, and the audit's own section 8.1
   is the finding that those classes do not compose. Editing them destroys the
   dated record that made 8.1 findable and replaces it with a snapshot that will
   be stale within a day. Section 9 corrects the specific claims and says
   explicitly which tables were NOT re-run.

4. **Recording `505` as the 9B descriptor step count. REJECTED, it is not
   committed.** `sim/seq_tbl_pkg.vhd`'s working tree says 505 and its header
   says 491 is superseded; `git show abbd2ed:sim/seq_tbl_pkg.vhd` says 491 at
   `:206`. The file is `M` in `git status` and belongs to a live track. Both
   numbers are recorded in the audit's new section 9.5 as a warning, and neither
   as a fact.

5. **Running `sim/regress.sh` to confirm the 85. REJECTED on contention
   grounds.** Four other agents were running; the worklog records that a full
   gate under contention fakes failures for other tracks. `BASELINE_PASS` read
   out of the committed file is the stronger evidence anyway -- it is the floor
   the gate enforces, not one run's outcome.

6. **Fixing the stale in-code comments found (section 8). REJECTED by
   ownership.** Five tracks are live in `rtl/`. They are listed for the
   dispatcher to sequence.

---

## 6. Measurement traps hit, including my own

**6.1 I read `sim/seq_tbl_pkg.vhd` from the working tree and nearly wrote 505
into the audit as MEASURED.** The number is real, the file is uncommitted, and
the header sentence *"Comments and documents elsewhere that say 491 predate
this"* reads exactly like a settled fact. What caught it was running
`git show HEAD:<path>` as a separate step and finding 491. **A reading not taken
against a named commit is not a reading**, and this project has now been bitten
by working-tree drift three separate ways: a file that grew 254 lines
mid-analysis, a pathspec commit that swept another track's edits, and this.

**6.2 HEAD moved under me.** `git rev-parse HEAD` returned `abbd2ed` at the
start and `0db9034` an hour later. MEASURED, `git diff --stat abbd2ed..HEAD`
shows one file, `docs/WORKLOG.md`, +16 lines, so nothing cited here moved. The
trap is that I only knew that because I re-ran the command; had I not, every
`file:line` in five documents would be cited against a commit that was no longer
HEAD, and silently.

**6.3 Two documents both called "the C spec", and only one has the unit table.**
`2026-08-21-gated-attention-design.md` is 1,900 lines and is the numeric
contract; `2026-08-27-C-gated-attention-skeleton.md` is the DSP skeleton and
owns the thirteen-unit decomposition. The backlog item says "the spec" without
saying which. Reconciling the wrong one would have produced a correct-looking
document that answered nothing.

**6.4 A correction section is trusted more than a body, and goes stale just as
fast.** The audit's section 8.3 is headed "What the audit got RIGHT and is worth
repeating" and three of its four sentences are now false. It is the paragraph
most likely to be copied into a brief precisely because it looks like the
survivor. **Corrections need dates in their sentences, not only in their
headings**, so a reader can tell how old a "still true" is.

**6.5 "The unit is absent" and "the responsibility is absent" are different
claims, and the audit's own method could not tell them apart.** Its section 1.4
checks each spec NAME against `rtl/`. That is a sound check for the question
"does a file of this name exist" and an unsound one for "is this computed". The
same method applied to `attn_qk_norm` would report ABSENT forever, because the
correct implementation of that row is to instantiate `rmsnorm_rs` and write no
file at all. **Ask what would compute the thing, not what would be named after
it.**

**6.6 Two BRAM figures, two builds -- the trap the SHELL track already
recorded.** 192.5 BRAM36 is `matvec_int4_desc_axi` (28 masters); 145.5 is
`matvec_int4` (27 masters). They are not a before/after of one build. Recorded
again here because it is the same 27-versus-28 confusion as section 4.8, one
layer down, and it has now cost two tracks time.

---

## 7. What should have become work and did not

**Reported, NOT added to the backlog.** Sequencing is the dispatcher's.

The known case is the audit's section 5, which has no route into
`docs/WORKLOG.md`'s BACKLOG table. Section 5.1 became backlog item 12 only
because an independent reviewer went looking, a day later. The remaining
section-5 items are still in prose only. Alongside them are items from Open
issues and from other analyses that concluded work and stopped.

| # | what concluded it needed doing | where it was concluded | why it is not just a nice-to-have |
|---|---|---|---|
| 1 | **`ref/gdn_block_vec.c`.** `gdn_block` has no oracle at the level of its own OUTPUT; its bench proves determinism under producer skew, not that it computes Gated DeltaNet | audit 5.6 | This is EXACTLY the artefact class that found `attn_block` computing 64 of 64 mantissas wrong after every unit under it was rated V-. B is the most complete subsystem and the least falsifiable at the block level. MEASURED: `ref/gdn_block_vec.c` absent at `abbd2ed` |
| 2 | **Subsystem A has zero mutation scripts.** 30 exist; 9 attn, 8 gdn, 5 seq, 5 ref, 2 llama, 1 rmsnorm, **0 A** | audit 5.5, re-measured today | A is the only subsystem running on real silicon and the only one in the FK33 shell. Its checkers are demonstrated to pass and never demonstrated to fail |
| 3 | **`tb_gdn_block`'s four printed checks.** `err_conv`, `err_g`, `err_se`, `y_sat` reported with no severity at `sim/tb_gdn_block.vhd:647-650`, so a run in which conv errored still prints PASS | audit 5.6a | Two other B benches were already caught in this exact shape and promoted to `severity failure`. This is the third instance and the only one not fixed. Backlog 11 covers five OTHER B units and does not cover this |
| 4 | **`sim/tb_bfp_cmp.vhd` cannot elaborate**, port-mapping an `in_q` bus `rtl/bfp_pack.vhd:53` says was replaced. It is skipped for the unrelated `library beh` reason, so the rot is invisible to the gate | audit section 3 | `bfp_pack`'s netlist-versus-behavioural check has not run since that interface moved, and nothing will ever tell you |
| 5 | **The epsilon-class harness was run on 27B and four sites are unbuilt** (recurrence, conv, scalar path, l2norm), and the perplexity figure does not resolve without the full 655-chunk corpus | audit 5.2 | The 9B checkpoint now exists, so the blocker named in that document is gone. Backlog 12 mentions the re-run in a parenthetical and item 12 has LANDED, so the re-run has no owner |
| 6 | **`rtl/llama_top.vhd`'s RMS norm uses a fabricated weight.** `:1615-1626` builds `W_CONST` as `2**NORM_W_EXP + ((i*37) mod 512) - 256` and `:1672` passes it to the only `rmsnorm_rs` instance. MEASURED: `attn_norm` appears **0 times** in the file | `docs/debugging/2026-08-29_9b-whole-model-reference.md` finding 2 | Every "real weights" claim about `llama_top` is real for A's INT4 tensors and synthetic for the norms. No per-layer norm weight is wired anywhere |
| 7 | **OI-1's compute-phase watchdog.** A `w_beats` too small starves the array and the job never completes and never errors; `WDOG_LIMIT` covers the descriptor FETCH only. A driver polling `done or err` waits forever | worklog OI-1 | Explicitly left for Oren because the limit is a per-geometry number. It is a decision with a one-line trigger and no row |
| 8 | **OI-13: nothing proves the per-port CDC is asynchronous rather than timed**, and no per-clock WNS exists for a design containing subsystem A. The enumeration does not terminate | worklog OI-13 | If the clock group did NOT apply, every WNS quoted for the shell build is pessimistic rather than optimistic, which changes what OI-12's congestion verdict means |
| 9 | **C and D cannot be sized independently.** C at `MACS = 192` needs D to land at 28 DSP rather than its worst case of 52; C is 61-64% of the remaining headroom | C skeleton section 6 item 9 | D has no RTL, so the number gating C's parallelism is the worst case of a subsystem nobody has built. Backlog 13 (composed synthesis with stubs) would measure it, and does not currently say so |

**A structural note that outranks any individual row.** Items 1, 2, 3 and 4 are
all the same defect: **an analysis names a missing CHECK, and a missing check
generates no artefact, so nothing reminds anyone.** A missing unit is visible
every time someone greps `rtl/`. A missing oracle is visible to nobody. If one
process change comes out of this track, it should be that **an audit's section 5
is emitted as backlog rows, not as prose.**

---

## 8. Stale in-code comments found, deliberately NOT fixed

`rtl/`, `sim/` and `tools/` are owned by other tracks. All read at `abbd2ed`
against a clean working tree for each path.

| file:line | says | at `abbd2ed` |
|---|---|---|
| `rtl/matvec_core.vhd:292-294` | "At the FK33's **ROWS_IF = 58** that is a single register driving 58 lanes ... spread across whatever the placer does with **1,914 DSPs and 135k LUTs**" | The build is `ROWS_IF = 48`. MEASURED, `sim/ooc_sweep/results.csv` line 8: `48, dsp 1584, lut 112712`. Line 7 is the 58 row: `1914, 134675` -- the comment quotes that row exactly. In the shell the core is 118,068 LUT / 1,584 DSP (`docs/debugging/2026-08-29_shell-congestion.md:131`). 58 is separately recorded as NOT BUILDABLE. Already flagged by `docs/debugging/2026-08-29_shell-congestion.md:668` and still unfixed |
| `rtl/attn_block.vhd:184-185` | "`rtl/llama_top.vhd` leaves them open today and runs one token at cur_pos = 0, where nothing is ever read" | False since `5d0253f`. `rtl/llama_top.vhd:3387-3430` connects the four `_rdy` handshakes in the `gkvaxi` branch, and `:3577` drives `c_cpos` from `tok_pos` |
| `rtl/llama_top.vhd:144` | "There is no KV cache, no position, no RoPE at this level" | KV cache and position are both false under `C_KV_AXI` / `C_REAL`. RoPE is arguably still true, since it lives inside `attn_block`. The neighbouring bullets at `:133` and `:341` were corrected in place on 2026-08-29 and this one was missed |
| `rtl/llama_top.vhd:126` | "There is no attention. See the C banner." | The C banner at `:282` IS corrected; this pointer sentence is not, and it is the one a skimmer reads |
| `rtl/model_cfg_pkg.vhd:82-83` | "about 4.5 GB against 8 GB HBM" | Drops the scales. The residency map says 5.036 GB stored; the packed `qkvpad` set is 5,059,649,536 bytes. Flagged by audit section 7 item 4 on 2026-08-28 and still unfixed |
| `rtl/matvec_int4.vhd:15-20` | "The DESCRIPTOR is driven by the PS, which parses the 4 KB header" | A VU33P has no PS, and `rtl/matvec_int4_desc_axi.vhd` now parses the descriptor in fabric. Flagged by audit section 7 item 5 and still unfixed |
| `rtl/seq_desc_fetch.vhd:148` | "1,106 steps/token at 27B, **546 at 9B**" | `sim/seq_tbl_pkg.vhd:206` at `abbd2ed` says **491**, and an uncommitted working tree says **505**. Three numbers, one quantity. 11 bits covers all three so nothing is broken; one will be quoted wrongly |
| `sim/probe_abc_ports.vhd:8` | "the repo's published verdict today is **69 PASS / 0 FAIL** ... takes the suite to 70" | `BASELINE_PASS = 85` at `abbd2ed`. Flagged as 72 by audit section 7 item 8; now doubly stale |
| `sim/probe_abc_ports.vhd:14` | "the REAL **491**-descriptor Qwen3.5-9B N=1 token table" | Same 491/505 question as `seq_desc_fetch.vhd:148`. Whichever lands, this line and the two `docs/2026-08-27_hbm-port-contention.md` sites (`:80`, `:135`) move together |

---

## 9. Explicitly NOT verified

An "unverified" marker is worth more than a confident sentence nobody checked.

1. **The audit's sections 1.2, 1.3, 1.5 and 1.6 were not re-run.** The per-unit
   evidence classes for A, B, D and E are as of `b66c4b4`. Several are certainly
   stale.
2. **The audit's section 2 seam table was not re-enumerated row by row.**
3. **The audit's section 4 items 1, 5, 6, 8, 9, 10, 11 were not re-checked.**
4. **The audit's sections 5.2, 5.7, 5.8, 5.9, 5.10 were not re-checked.** 5.9's
   208.8 MHz die clock in particular predates the shell build and OI-12.
5. **Whether `attn_block` computes attention CORRECTLY at the 9B geometry.**
   This track establishes only that the responsibilities are implemented and
   where. The correctness evidence is `ref/attn_block_vec.c` at the geometries
   its bench drives, and that is a separate claim.
6. **Whether the three live deviations in section 2.1 of the skeleton spec (no
   PV lag, G exp cones, element-at-a-time gate re-read) change the DSP budget.**
   They change the CYCLE budget by construction; whether they change DSP was not
   derived.
7. **Whether the descriptor-fetch master could share an HBM port with a scale
   master.** That is the only obvious route back from 2 free ports to 3, and
   nobody has costed it.
8. **No simulation, no synthesis, no hardware.** Every reading in this document
   is `git show`, `git ls-files`, `grep`, `sed` or `ls`.
9. **The 9B GGUF's own attention metadata was not read directly** -- the
   attempt is REJECTED item 1. The 9B geometry cited here comes from
   `rtl/model_cfg_pkg.vhd:64-70`, which
   `docs/debugging/2026-08-29_9b-whole-model-reference.md` states was checked
   field by field against that GGUF. That is one hop of trust and it is
   declared.

---

## 10. Corrections

Appended in place, never by editing history.

### 2026-08-29: this track's six files landed inside another track's commit

**`686fd97`, "subsystem C's R_Y gets an oracle, and its v_ref fold is missing a
dimension", contains all six of this track's documents.** Its message describes
only TRACK C-ORACLE's R_Y work. Nothing was lost: MEASURED, all six files in
`686fd97` are byte-identical to what this track wrote (`md5sum` against
`git show 686fd97:<path>`, six of six IDENTICAL). The defect is a commit message
that describes half its contents, and it is recorded here rather than fixed by
an amend, because amending would rewrite another track's tip and re-run the same
race.

**The mechanism is the mirror image of the one the worklog already records**,
and it is worth stating because the worklog's version has only ever been
described from the sweeping side. The recorded trap is
`git commit -m msg -- <path>`, which commits the WORKING TREE at that path. This
was the other half: I ran `git add <my six paths>`, which is the prescribed safe
form, and then `git diff --cached --name-only` as its own gating step, exactly
as CLAUDE.md requires. **The gate fired.** It printed twelve paths, six of them
mine and six belonging to a track editing `ref/` and `tools/ref9b/`. Before I
could act on that reading, that track committed, and a pathspec-free commit
takes the whole index.

**So the lesson is not "run the check".** I ran it, and it worked, and it was
still too late. **The index is shared mutable state between concurrent agents,
and there is no atomic read-then-commit through it.** The only forms that do not
have this race are ones that never put a file in the shared index:
`git commit -m msg -- <paths>` on files ONLY your track owns (its documented
danger, that it commits the working tree at those paths, is harmless when the
paths are yours and clean), or `git stash` plus a private index. Between the two
traps, **the pathspec form is the safer one for files you exclusively own, and
the `git add` form is the safer one for a shared file** -- which is the opposite
of how the two rules read in isolation, and is why they keep fighting.

**Corollary for the dispatcher, not for me to act on:** the WORKLOG's rule
"stage the hunk, then commit with NO pathspec" is correct for a SHARED FILE and
is actively harmful for an exclusively-owned one while other agents are running,
because it parks your work in a structure any of them can commit. Four instances
of the pathspec trap and now one of its inverse.

**Also superseded by this:** section 6.2's note that HEAD moved from `abbd2ed`
to `0db9034` during the session. It moved twice more, to `e27a9ad` and then
`686fd97`. MEASURED: none of those touches a path cited in this document except
the six this track wrote, so every `file:line` above still resolves at
`abbd2ed`, which remains the correct citation commit.
