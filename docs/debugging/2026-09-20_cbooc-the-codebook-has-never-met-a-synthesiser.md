# The per-row codebook has never met a synthesiser: a pre-registered OOC A/B

TRACK CBOOC, 2026-09-20. Workstation `Oren-Dell-Ubuntu`, repo at `08cc17d`,
branch `fpga`. **No hardware. No Vivado was started by this track** -- the
workstation lane was held by build 11b (`/proc/387741/exe` and
`/proc/493310/exe`, cwd `/mnt/storage/fk33_builds/build11b/root/...`) and the
BC-250 lane by TRACK ELABCLASS. Scratch under
`/mnt/storage/fk33_builds/scratch/cbooc`, never `/tmp`.

---

## 1. The question, verbatim

> Build 11b placed at **WNS -5.136, TNS -236,998**, against build 9's
> +0.533/0.000 and build 10's +0.421/0.000. It carries exactly two changes over
> build 9: `FAST_POP` and CBFANOUT's per-row codebook. [...] `docs/LEVERBOARD.md`'s
> scope column for L-CB reads **"no synthesis at all"** and its `-19,344 FF` is
> **DERIVED**. **Build 11b is the first time that change has ever met a
> synthesiser.** [...] **This is a LEAD, not a conclusion, and your job is to
> make it testable rather than to confirm it.**

---

## 2. The answer

**NOT YET DETERMINED, deliberately. This file is a PRE-REGISTRATION, not a
result.** No synthesiser has run. What is settled is the instrument:

* The harness is `sim/ooc_cbooc.tcl` + `sim/ooc_cbooc_run.sh`, ready to run.
* **The smallest entity that closes build 10's failing PATH is
  `matvec_int4_desc_axi`, not `matvec_core`** (section 4).
* **`CB_STYLE=distributed` is load-bearing, and at the engine's default `regs`
  the two arms are provably the SAME NETLIST** (section 5). A draw at `regs`
  would have produced two full result rows and a zero delta, and the zero would
  have been a fact about the geometry.
* The prediction is written down in section 6 and will not be adjusted after a
  number is seen.

---

## 3. The procedure, in the order it runs, and what each step isolates

| # | step | what it isolates | needs a synthesiser? |
|---|---|---|---|
| 1 | build `old/rtl` and `new/rtl` from `git archive HEAD rtl`, then overwrite `old/rtl/matvec_core.vhd` with `git show 0b34200^:rtl/matvec_core.vhd` | the REAL pre-change RTL, not an imitation of it | no |
| 2 | assert `0b34200:rtl/matvec_core.vhd` == `HEAD:rtl/matvec_core.vhd` by sha256 | that `0b34200^` IS HEAD-minus-the-change and carries nobody else's edits | no |
| 3 | `diff -rq old/rtl new/rtl` must name exactly one file, and the hunk count must equal `git show 0b34200 -- rtl/matvec_core.vhd`'s | that the arms differ in exactly the intended file by exactly the intended hunks | no |
| 4 | GHDL `-r` both arms x {`matvec_core`, `matvec_int4_desc_axi`} at the card geometry; gate on the RTL's own announcement | that both arms ELABORATE at `ROWS_IF=48 / BLK=32 / CB_STYLE=distributed`, that the generic THREADS two hierarchy levels, and that the two trees really are the two arms | no |
| 5 | `synth_design -mode out_of_context` + `opt_design`, clocks created BEFORE synthesis | the area delta, the LUT/LUTRAM/DSP/BRAM controls | **yes** |
| 6 | object-level census by exact `REF_NAME`, cross-checked against `report_utilization` in the same run | the FF delta, attributed to `cbw_*` rather than to a total | yes |
| 7 | fanout census, twice: name-independent top-N nets by `FLAT_PIN_COUNT`, and the nets on the `cbw_*` D pins | **the number CBFANOUT's whole claim rests on and which no tool has ever counted** | yes |
| 8 | the path class ending at a `cbw_*` D pin, reported whether or not it is worst | build 10's actual failure mode, which a WNS comparison alone can only bound | yes |

Step 4 is the control that makes steps 5-8 attributable: without it, two copies
of one arm look exactly like a well-controlled experiment.

---

## 4. `matvec_core` does NOT close build 10's failing path. `matvec_int4_desc_axi` does.

MEASURED from the RTL, not from the prose:

```
rtl/matvec_core.vhd:81            cb_addr   : in  std_logic_vector(3 downto 0);   -- a PORT
rtl/matvec_int4.vhd:95            cb_addr   : in  std_logic_vector(3 downto 0);   -- still a PORT
rtl/matvec_int4_desc_axi.vhd:474  signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
rtl/matvec_int4_desc_axi.vhd:1002             cb_addr <= std_logic_vector(to_unsigned(cb_cnt, 4));
```

Build 10's ten worst paths were `cb_addr_reg[i]/C -> cbw_a_reg[c][i]/D`. The
ENDPOINT is inside `matvec_core`; the STARTPOINT is not. So:

* `matvec_core` closes the **fanout cone** (`cb`, `cbw_v`, `cbw_a`, `cbw_d` are
  all declared in its architecture) and is the cheaper draw.
* `matvec_int4_desc_axi` is the **smallest entity holding both endpoints** and
  is the default target.

Quote the `desc_axi` pair for anything about the path. **Do not add the two
contexts together** -- the parts do not sum across synthesis contexts.

---

## 5. `CB_STYLE=distributed` is load-bearing, and the obvious harness gets it wrong

DERIVED from `rtl/matvec_core.vhd:256-262` and `:225-235`:

```
CB_LANES_PER_COPY = cb_lpc_f(CB_STYLE, CB_ROWS_PER_COPY, BLK)
                  = 1                        if CB_STYLE = "distributed"
                  = CB_ROWS_PER_COPY * BLK   otherwise            (= 32)
CB_COPIES         = ceil(ROWS_IF*BLK / CB_LANES_PER_COPY)
CB_RANKS          = min(CB_COPIES, ROWS_IF)
cb_rank_of(c)     = (c * CB_RANKS) / CB_COPIES
```

| CB_STYLE | CB_LANES_PER_COPY | CB_COPIES | CB_RANKS | `cb_rank_of` |
|---|---|---|---|---|
| `regs` | 32 | **48** | **48** | `(c*48)/48 = c`, **the identity** |
| `distributed` | 1 | **1536** | **48** | 32 copies per rank |

**At `regs` the change is a no-op and the two arms are the same netlist.** The
card build is `FK33_CB_STYLE=distributed` (`docs/WORKLOG.md:17`; `:147` quotes
the 1,536 -> 48 fanout), so `distributed` is both the card's shape and the only
shape at which the experiment exists.

**`sim/ooc_levercost_run.sh`'s `AGEN` carries `CB_STYLE=regs`** -- correct for
TRACK LEVERCOST's question about `FAST_POP`, and fatal for this one. Reusing it
unmodified would have drawn two identical netlists, printed two full result
rows, and reported a zero delta that was a fact about the generic. This is
`docs/debugging/2026-09-20_the-shape-a-bench-runs-at.md` in a new place, and it
is why `sim/ooc_cbooc.tcl` **refuses** to draw at `regs` unless
`CBO_ALLOW_REGS=1` is set deliberately.

MEASURED by GHDL, both arms, both units, at the card geometry:

```
old  matvec_core          LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=1536  CB_LANES_PER_COPY=1                CB_WR_LAT=1
old  matvec_int4_desc_axi LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=1536  CB_LANES_PER_COPY=1                CB_WR_LAT=1
new  matvec_core          LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=1536  CB_LANES_PER_COPY=1  CB_RANKS=48   CB_WR_LAT=1
new  matvec_int4_desc_axi LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=1536  CB_LANES_PER_COPY=1  CB_RANKS=48   CB_WR_LAT=1
```

The `desc_axi` rows are the stronger two: they show the string generic arriving
through **two** hierarchy levels, which is the property TRACK LEVERC48 had to
establish separately for synthesis and which no simulation of `matvec_core`
alone can show.

---

## 6. THE PREDICTION, WRITTEN DOWN BEFORE ANY SYNTHESISER RUNS

All DERIVED from the RTL at `ROWS_IF=48, BLK=32, CB_STYLE=distributed`
(`CB_COPIES = 1536`, `CB_RANKS = 48`, command width 1 valid + 4 address +
8 data = 13 bits).

| quantity | OLD (`0b34200^`) | NEW (HEAD) | predicted delta |
|---|---|---|---|
| `cbw_*` flip-flops | 13 x 1536 = **19,968** | 13 x 48 = **624** | **-19,344** |
| CLB Registers, whole unit | | | **-19,344** |
| distinct nets on `cbw_*` D pins | **13** | **13** | **0** (a CONTROL) |
| max `FLAT_PIN_COUNT` on those nets | **1,537** (1,536 sinks) | **49** (48 sinks) | **1,536 -> 48 sinks** |
| CLB LUTs | | | **0** |
| LUT as Memory | | | **0** |
| `cb_reg*` RAM cells | > 0 | > 0, same | **0** (a CONTROL) |
| `cb_reg*` FF cells | 0 | 0 | **0** (a CONTROL) |
| DSP48E2 / RAMB36 / CARRY8 / MUXF7 / MUXF8 | | | **0** |

Why `LUT` is predicted at exactly zero: `cb_rank_of(c)` is called with the
for-generate loop constant `c`, so it is a compile-time integer and folds; no
mux and no address arithmetic is inferred. **If LUT moves, that reasoning is
wrong and the change is not what its commit message says it is.**

### What would FALSIFY the lead

The lead is "the per-row codebook is why build 11b collapsed". It is
**weakened** by, in descending order of force:

1. `delta FF = -19,344`, `delta LUT = 0`, max command fanout 1,537 -> 49, no new path
   class, and NEW's intra-clock WNS no worse than OLD's. Then the change makes
   the netlist strictly smaller and strictly lower-fanout, and no netlist
   mechanism it contains can add 5.7 ns.
2. The `cbw_*` path class being BETTER in NEW, which is the class build 10 died
   on.

It is **supported** by any of: `delta LUT` materially positive; a new high-fanout
net appearing in NEW's name-independent top-N; NEW's intra-clock WNS materially
worse; a `cbw_*` path class that is worse in NEW.

### And the prediction failing is the more interesting outcome

If `delta FF` is not -19,344, **CBFANOUT's central DERIVED number is wrong** and
`docs/LEVERBOARD.md`'s L-CB row must be withdrawn, independently of anything
about build 11b. That is a result this harness can produce and the lead cannot.

### What this harness CANNOT settle, stated in advance

**It cannot exonerate or convict the change on build 11b's WNS.** That number is
a PLACEMENT outcome at 99.81% CLB occupancy. CLAUDE.md records `phys_opt`
over-promising by 0.4-0.6 ns on this part and INVERTING the verdict between two
runs, and an OOC route would not transfer either, because OOC congestion is not
the card's congestion. The card question needs a re-implementation from build
11b's own checkpoint with the change reverted, which is a different and much
larger job. `sim/ooc_cbooc.tcl` writes a post-`opt_design` checkpoint per arm so
that anyone who disagrees can route from it for the price of a
`read_checkpoint` rather than a second synthesis.

**Synthesis suffices for the question this track asks**, and the justification
is not "area only": the mechanism CBFANOUT claims is a fanout COUNT and the
prediction it registered is a flip-flop COUNT. Both are netlist facts fixed at
synthesis. Routing would buy a number with nowhere to be quoted.

---

## 7. The exact command

**Prepare and validate (no Vivado, ~6 s, safe to run beside build 11b):**

```bash
cd /home/orencollaco/GitHub/llama.vhdl
CBO_PREPARE_ONLY=1 bash sim/ooc_cbooc_run.sh
```

**Draw both arms on a free lane:**

```bash
cd /home/orencollaco/GitHub/llama.vhdl
CBO_CAP=8G CBO_TARGET=matvec_int4_desc_axi bash sim/ooc_cbooc_run.sh
```

**On the BC-250, which has no `.git` and therefore cannot build its own arms.**
`~/GitHub/DevOps/bc250-sync-llama-vhdl.sh` rsyncs the git-TRACKED files only and
copies no `.git`, so `git archive HEAD` and `git show 0b34200^:...` both fail
there. Prepare here, ship the run directory, draw there:

```bash
# 0. resolve the address from the router; NEVER trust a hardcoded one
ssh labuser@192.0.2.1 "grep -i cachyos /var/lib/misc/dnsmasq.leases"
# 1. sync the tracked tree (the harness must be COMMITTED first)
bash ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh
# 2. prepare the arms HERE, where git lives
CBO_PREPARE_ONLY=1 bash sim/ooc_cbooc_run.sh      # note the run_... path it prints
# 3. ship that run directory
rsync -a /mnt/storage/fk33_builds/scratch/cbooc/run_<STAMP>/ \
    labuser@<IP>:/home/orencollaco/cbooc_run/
# 4. draw there.  Its shell is FISH, so wrap in bash -s.
ssh labuser@<IP> 'bash -s' <<'EOF'
cd /home/orencollaco/GitHub/llama.vhdl
CBO_IMPORT=/home/orencollaco/cbooc_run CBO_CAP=8G bash sim/ooc_cbooc_run.sh
EOF
```

Import mode re-asserts by sha256 the provenance that git would have asserted,
because a comparison needs both ends drawn from the same tree and internal
consistency cannot detect staleness.

**Gate on `CBOOC_DONE <tag>`, line-anchored, never on an exit code.** The
Vivado log contains this script's own source text; an unanchored grep has twice
in this project reported a finished synthesis seconds after launch.

**`CBO_CAP` MUST NOT EXCEED 11G ON THE BC-250.** A 12G cap on that 14 GB box
made it completely unreachable and it is on no WoL watchdog. 8G is what
LEVERCOST's identical draw already ran at, twice, to `rc=0`.

---

## 8. Expected memory and runtime, and its source

MEASURED, `hw/fk33/results/levercost_2026-09-20/arms/mem_apop_ctrl.txt` and
`mem_apop_fast.txt` -- **the same entity at the same card geometry**, on the
BC-250:

```
tag=apop_ctrl target=matvec_int4_desc_axi peak_rss_gb=10.02 cgroup_peak_mb=8195 cgroup_swap_mb=1024 at_cap=YES wall_s=713 rc=0
tag=apop_fast target=matvec_int4_desc_axi peak_rss_gb=10.08 cgroup_peak_mb=8194 cgroup_swap_mb=497  at_cap=YES wall_s=725 rc=0
```

**Every one of those `memory.peak` figures is the CAP and not the appetite**
(`at_cap=YES`). The only honest size figure in that batch is Vivado's own
`Memory (MB): peak` for this unit: **~4,050 MB**
(`hw/fk33/results/levercost_2026-09-20/README.md:640`). The 10.0 GB RSS sum
double-counts shared pages across the forked synthesis workers.

| | figure | label |
|---|---|---|
| true appetite, one arm | ~4.1 GB | MEASURED (Vivado's own accounting, `regs` arm) |
| safe cap | **8G** | MEASURED to complete twice at that cap |
| wall, one arm at `CB_STYLE=regs` | 713-725 s | MEASURED, BC-250, throttled at the cap |
| wall, one arm at `CB_STYLE=distributed` | **12-20 min** | **ESTIMATE**; the netlist differs (LEVERC48 measured `matvec_core` alone at -42,633 LUT and +12,288 LUTRAM between the two styles) and the OLD arm carries 19,968 extra flip-flops |
| both arms | **25-40 min** | ESTIMATE, from the row above |

**Which box: the BC-250.** LEVERCOST's identical draw ran there at 8G to `rc=0`
twice, and the workstation lane is build 11b. A capped job's wall time measures
the cap, so none of the above is a speed ratio between the machines.

---

## 9. Validated without a synthesiser, with the teeth

Everything below MEASURED on the workstation, beside build 11b, at
`free -g` 12-13 GiB available.

**The harness runs end to end.** `sim/ooc_cbooc.tcl` was executed under a Tcl
stub harness that replaces every Vivado command with a no-op returning a
plausible value (`/mnt/storage/fk33_builds/scratch/cbooc/stub_check.tcl`). It
reached `CBOOC_DONE`, read 110 VHDL files from the arm tree, excluded the four
`ooc_*_top.vhd` harness tops, and its Intra Clock Table parser correctly skipped
the table's own `-----` separator row -- the token that has twice taken a 735 s
draw down AFTER synthesis, `opt_design`, the census and the checkpoint all
succeeded. **This proves the control flow, not one number in it; every value the
stub returns is invented.**

**Tcl guards, each shown to FIRE and (where applicable) not to fire:**

| row | mutant | verdict |
|---|---|---|
| T1 | `CBO_TARGET` unset | ABORT `CBO_TARGET is unset` |
| T2 | `CBO_RTL` points at a directory with no `matvec_core.vhd` | ABORT, naming the directory |
| T3 | `CBO_GEN` carries `CB_STYLE=regs` | ABORT, with the identity-map argument in the message |
| T4 | same, plus `CBO_ALLOW_REGS=1` | proceeds to `CBOOC_DONE` -- the null control stays reachable **deliberately** |
| T5 | `get_cells` stubbed to return nothing | ABORT `that is not an answer, it is a broken filter` |

**Runner guards:**

| row | mutant | verdict |
|---|---|---|
| R1 | happy path, `CBO_PREPARE_ONLY=1` | 4 `CBOOC_GHDL PASS` rows, manifest written, 5.7 s |
| R2 | `CBO_BASECOMMIT=5dc3ee5` (whose parent already carries the change) | ABORT `the two arm trees differ in 0 files, expected 1` |
| R3 | the announcement discriminator run against the two REAL captured strings | OLD has no `CB_RANKS` at all; NEW has `CB_RANKS=48`; both have `CB_COPIES=1536` |
| R4 | `CBO_BASECOMMIT=0b34200^` (file moved since) | ABORT, printing both sha256s and the `git apply -R` recipe |
| R5 | `CBO_TARGET=matvec_int4` | ABORT rather than draw on entity defaults |
| R6 | `CBO_TARGET=matvec_core` | 2 `CBOOC_GHDL PASS` rows, correct generic set |
| I1 | valid `CBO_IMPORT` | `CBOOC_TREES ok (imported) ... sha256 both match` |
| I2 | one line appended to the imported OLD arm after the manifest | ABORT, printing both sha256s |
| I3 | `CBO_IMPORT` with no `MANIFEST.txt` | ABORT `its arms have no provenance` |

**The trees, MEASURED:**

```
$ diff -rq old/rtl new/rtl
Files .../old/rtl/matvec_core.vhd and .../new/rtl/matvec_core.vhd differ
$ diff -u old/rtl/matvec_core.vhd new/rtl/matvec_core.vhd | grep -c '^@@'
4
$ git show 0b34200 -- rtl/matvec_core.vhd | grep -c '^@@'
4
old sha256 ef401b6ff079e055...  ==  git show 0b34200^:rtl/matvec_core.vhd
new sha256 974734a743f73201...  ==  git show HEAD:rtl/matvec_core.vhd
md5 c3325ea1f418dcbcaa85f33e47e8c901 at 0b34200, at HEAD and in the working tree
```

**DID NOT BITE, under its own name.** The runner's "the one differing file is
not `matvec_core.vhd`" branch was NOT teeth-tested and is **unreachable by
construction**: the script only ever overwrites that one file. It is kept as a
belt-and-braces check and should not be counted as a guard with demonstrated
resolution.

---

## 10. Measured and REJECTED -- do not retry

* **Do not reuse `sim/ooc_levercost_run.sh` for this question.** Its `AGEN`
  carries `CB_STYLE=regs`, at which both arms are the identical netlist
  (section 5). It would have run to completion and reported a zero delta.
* **Do not draw this in `matvec_core` alone if the claim is about the PATH.**
  The startpoint `cb_addr_reg` is in `matvec_int4_desc_axi` (section 4). The
  `matvec_core` draw is still valid for the fanout and area deltas and is
  cheaper; it is kept as `CBO_TARGET=matvec_core`.
* **Do not gate the GHDL step on an exit code.** MEASURED on GHDL 1.0.0 mcode:
  BOTH arms elaborate and then fail at time 0 with `overflow detected in
  process .matvec_core(rtl).P7`, because `matvec_core` is being run as a TOP
  with unstimulated `integer` ports (`n_cols` et al. sit at `integer'left`).
  That is a property of running a datapath unit with no stimulus, it is
  IDENTICAL in both arms, and it is not an elaboration failure.
  `matvec_int4_desc_axi` exits 0 with 35 NUMERIC_STD metavalue warnings.
  The gate reads the RTL's own `LEVER C ACTIVE` announcement instead.
* **Do not put `if` in the pre-synthesis XDC.** Vivado's XDC reader forbids it
  and skips the block with only a CRITICAL WARNING, which would silently
  produce an UNCONSTRAINED synthesis -- the exact failure the pre-synthesis
  constraint exists to avoid, wearing the costume of a defensive check. The
  clocks are written unguarded and re-issued after `synth_design`, and a name
  that is not a port is reported as `CBOOC_CLKMISS`.
* **Do not route these arms to answer build 11b.** See section 6.

---

## 11. Measurement traps hit, including my own

* **The obvious harness was the wrong-shape harness, and it looked right.**
  `ooc_levercost` targets the same entity at the same geometry and is the
  natural thing to reuse. Its one differing generic turns the experiment into a
  null. Nothing in its output would have said so: two complete result rows and
  a zero delta read exactly like a careful negative result.
* **`ghdl -r` exiting non-zero is not a failure of the arm.** The first probe
  of `matvec_core` looked like a broken tree. It is a top-level datapath unit
  with no stimulus and both arms do it identically. Gating on the exit code
  would have failed both arms and looked like a real finding.
* **A per-object `get_property` loop over ~10^5 nets is minutes of pure Tcl.**
  The fanout census takes the batched list form and falls back to the loop only
  if that raises, so the cost is the tool's and not the script's.
* **`get_timing_paths -to <19,968 pins>` is wrapped in `catch`**, so a filter
  that Vivado dislikes degrades to a named `paths=0` line that explicitly says
  it is a fact about the filter, rather than to a slack of `NA` that reads like
  a pass.

---

## 12. Open, not determined

* **Everything in section 6.** No synthesiser has run. The numbers are DERIVED
  and the falsification criteria are pre-registered; neither is a measurement.
* **Whether `FAST_POP` costs area or timing at the card shape.** It is build
  11b's other change and is held CONSTANT (`true`, the card's value) across
  both arms here, so this harness says nothing about it. LEVERCOST measured it
  at `+1 CLB LUT` on this unit at `CB_STYLE=regs`; that is not a `distributed`
  number and the two contexts do not sum.
* **Whether build 11b's collapse is attributable to either lever at all.** The
  third candidate -- the placer's response to a netlist 19,344 flip-flops
  smaller at 99.81% CLB occupancy -- is invisible to every instrument here and
  to every instrument short of a re-implementation from build 11b's own
  checkpoint.
* **Build 11b's own placed utilization report** is the first measurement of
  whether removing those flip-flops frees CLBs at all, and it is item 1 of
  LEVERBOARD's read-list (`docs/WORKLOG.md:103`). This harness does not
  substitute for it: DERIVED there, FF occupancy is 35.14% and 5.63 of 16 per
  occupied CLB, so FF was never the binding row.
* **The runtime and memory at `CB_STYLE=distributed` are ESTIMATEs**
  extrapolated from `regs` draws on a different netlist. Read
  `cgroup_peak_mb`/`at_cap` from the actual run before quoting either.
