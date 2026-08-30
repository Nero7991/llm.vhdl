# BITPREP: what is on the card, what is not, and the command that closes the gap

Date: 2026-08-30. Tree at start `c309572`, at write-up `b13d837` (HEAD moved
under this track twice; both are recorded because the second is the one the
build command below should be run from or after).

Hardware: SQRL FK33 `xcvu33p-fsvh2104-2L-e`. **No hardware was touched by this
track.** Nothing here ran `xsdb`, `hw_server`, `vivado ... program`, `pcieep.sh`,
`jtag.sh`, `flash.sh`, `tcl/program.tcl`, any `host/*` tool against the card, or
opened `/dev/xdma*`. No Vivado process was started at all.

---

## THE QUESTION, VERBATIM

> Tonight four separate RTL defects were found and fixed in the tree. The
> bitstream on the card predates every one of them. [...] Your job is to get the
> tree to a state where I can build and load a bitstream carrying all of them,
> and to tell me exactly what to run.

---

## THE ANSWER, UP FRONT

**The tree is ready. Nothing was blocking the build except the missing guard
entries, which are now in, and the machine, which is not free.**

1. **The loaded bitstream is `hw/fk33/bit/fk33_pcieep_eng.bit`**, sha256
   `6b12b3c4...64c6`, written by Vivado at **2026/08/29 14:38:06** (stamp read
   out of the file's own header). Its **netlist** was synthesised at ~06:56 that
   morning from `rtl/` at **`54b3c1a`** with `hw/fk33/` in a working state later
   committed as **`928ad9f`**. It is NOT `ed1ffe2`, which three documents in
   this repository claim: `ed1ffe2` landed at 14:42:42, four minutes AFTER
   `write_bitstream` finished, and it is the right commit for the bitstream's
   **constraints** and the wrong one for its **netlist**. No git SHA is stamped
   into the bitstream (`UserID=0XFFFFFFFF`), so this had to be reconstructed
   from logs and is DERIVED, not read off the artefact.

2. **Six commits since then change what a rebuild would contain, and four of
   those matter on silicon**: `0ff6828`, `75f95a8`, `3ecc729`, `a4a564c`. Twenty
   further `rtl/` commits landed in the same window and **none of them is in
   this design** -- the pcieep build consumes fifteen files and subsystems B, C
   and D are not among them. The rebuild's value is those four, not twenty-eight.

3. **TRACK THERMFIX's handoff is closed.** `gen_pcieep.py` now guards
   `G_HBM_MAX_DELTA`, both `C_HBM_DELTA_*` constants, both new elaboration-time
   asserts, and -- beyond the handoff -- the three expressions that carry
   THERMFIX's *third* fix (the reduction over both HBM dies). Nine new rows, all
   nine credited to this track under an attribution control against the guard at
   HEAD.

4. **`build_fk33_pcieep.tcl` IS generated** from `gen_pcieep.py` (its own line 1
   says so). Hand-editing it is the trap the brief warned about. Regenerating is
   the correct action -- and MEASURED, regenerating produces a file **byte-identical
   to the one already checked in**, so no regeneration commit is needed and this
   track's guard edit changes no generator output.

5. **The build command is `./hw/fk33/pcieep_build.sh` and nothing else.** No
   hand-driven place/route is required any more: the pblock and the placement
   directive that produced the loaded bitstream are both committed, and the
   standard flow has already been MEASURED end to end producing a routed,
   timing-clean design (WNS +0.069 ns, 0 routing errors) -- slightly *better*
   slack than the hand-driven run on the card (+0.045 ns).

6. **I did not run it.** MEASURED at the time of this write-up: load average
   6.09/6.94/8.19, 0 GB free RAM with 21 GiB of swap in use, root at 91%, and
   two Vivado jobs live -- TRACK COMPOSE4's `impl_dev` place-and-route (57 min
   in) and a `ooc_lutdiet_ports.tcl` scatter sweep with four parallel synthesis
   workers. A full pcieep build has a MEASURED cgroup peak of **25.0 GiB** on a
   31 GiB box. Starting it now would very likely kill COMPOSE4, this session, or
   both. The command list is in section 6; run it when the box is quiet.

---

## 1. PROVENANCE OF THE LOADED BITSTREAM

### What the file says about itself (MEASURED, `head -c 160 | strings`)

```
:bd_wrapper;COMPRESS=TRUE;UserID=0XFFFFFFFF;Version=2023.2
xcvu33p-fsvh2104-2L-e
2026/08/29
	14:38:06
```

```
$ sha256sum hw/fk33/bit/*.bit
6b12b3c46ee26396bcbc1f75cf240fe6231528a7a10c95ac91596b52bce164c6  fk33_pcieep_eng.bit
367d2990510620391ca83acbd5ffcb0e94f748713477e9f9158aeeb3d164ec10  fk33_pcieep_eng_asx_wns-0p077.bit
4baa572703c54416a65aaa92c814928aa6a592cc0946b873d121c36bbd5c6e47  fk33_pcieep.bit
499fdf498d226b4264aa575b2b28740106554c24e0f808b63b0da0970b13df1a  fk33_i2cprobe.bit
```

`docs/debugging/2026-08-29_first-engine-load-on-card.md:4-5` names the loaded
bitstream by the same size and the same sha256 prefix and suffix, and
`docs/debugging/2026-08-29_build-e2e-project-run.md:588` independently records
the same hash and states the later e2e build was deliberately NOT copied over
it. So the file on disk is the file on the card.

**None of the four `.bit` files under `hw/fk33/bit/` is tracked by git**
(`git ls-files hw/fk33/bit/` is empty). The only copy of the currently-loaded
artefact is that one file. Section 7 is about not losing it.

### The run that wrote it (MEASURED, `results/pblock_2026-08-29/`)

```
PBLOCK-STAMP 13:32:09 route session TAG=DX DCP=<scratch>/pblock/out/DX_placed.dcp
PBLOCK-STAMP 14:32:03 route_design done ok=1
PBLOCK-STAMP 14:35:24 write_bitstream start
PBLOCK-STAMP 14:38:18 write_bitstream done
```

`DX_route_status.rpt`: 282,090 of 282,090 routable nets fully routed, 0 with
routing errors. `DX_timing_routed.rpt`: **WNS +0.045 ns**, TNS 0, WHS +0.010 ns,
0 failing endpoints of 576,171.

It was **not** produced by `build_fk33_pcieep.tcl` end to end. `place_dx.tcl`
opened TRACK SHELL's post-`opt_design` checkpoint, deleted the inherited soft
pblock `pblock_bd_i`, created `pb_core` = `CLOCKREGION_X0Y0:CLOCKREGION_X6Y3`,
and re-placed with `place_design -directive ExtraPostPlacementOpt`. The scratch
tree it worked in no longer exists.

### The commit, stated plainly

**Not determinable from any artefact. Determinable to a named commit from three
independent write-ups, which agree.**

`shell-pblock.md:4-5`, `shell-congestion.md:4-5` and
`build-e2e-project-run.md` all say the checkpoint was synthesised at
**`928ad9f`** (2026-08-29 08:29:35, "FK33 shell: subsystem A on 28 HBM ports,
and the design does not route").

The complication is real: synthesis ran 06:56-07:47 but `928ad9f` was committed
at 08:29:35, ~42 min later, so the tree that was synthesised was `rtl/` at
**`54b3c1a`** (2026-08-28 22:57:01) plus an uncommitted `hw/fk33/` state that
became `928ad9f`. `928ad9f` touched only `hw/fk33/`, so the pair is consistent.

**The one genuine ambiguity is `0ff6828`** (2026-08-29 07:19:26, "matvec_core:
raw mode had no oracle, and it wrote past the end of ybuf"), which changed
`rtl/matvec_core.vhd` *during* the build window. Both readings give the same
answer: if the build read the detached worktree pinned at `54b3c1a`, `0ff6828`
is out; if it read the main checkout, `synth_design` ran ~06:58-07:09, still
before 07:19, so `0ff6828` is out either way.

**Best honest statement:** built from a working tree at 2026-08-29 ~06:56 whose
`rtl/` content is `54b3c1a` and whose `hw/fk33/` content is `928ad9f`.

---

## 2. WHAT A REBUILD WOULD ADD

### The files this design actually consumes (MEASURED, `build_fk33_pcieep.tcl:182-199`)

Fifteen, and only fifteen:

```
hw/fk33/rtl/fk33_aux.vhd          rtl/async_fifo.vhd        rtl/matvec_core.vhd
hw/fk33/rtl/fk33_thermal.vhd      rtl/axi_rd_fsm.vhd        rtl/matvec_int4.vhd
rtl/util_pkg.vhd                  rtl/axi_rd_port.vhd       rtl/matvec_int4_desc_axi.vhd
rtl/mv4i_arith_pkg.vhd            rtl/weight_streamer.vhd   hw/fk33/rtl/fk33_engine.vhd
rtl/matvec_int4_desc_pkg.vhd      rtl/act_mem_striped.vhd
rtl/stream_fifo.vhd
```

No `llama_top`, no `gdn_*`, no `attn_*`, no `rmsnorm_*`, no `l2norm_*`, no
`swiglu`, no `rope_*`. **Subsystems B, C and D are not in this bitstream at all.**

### The commits (MEASURED, `git log 54b3c1a..HEAD -- <those paths>`)

| sha | when | file | what it changes in hardware terms | in the loaded bit? |
|---|---|---|---|---|
| `0ff6828` | 08-29 07:19 | `matvec_core.vhd` | `if out_mode /= "10"` -> `if out_mode = "00"` on the `ybuf(re2_t) <= ynew` write. Stops an out-of-range accumulator write-back in non-accumulate modes | **NO** |
| `f1c4b5b` | 08-29 12:56 | `async_fifo.vhd` | one assert condition. **Simulation-only**, no synthesised logic | NO, and irrelevant |
| `d570899` | 08-29 13:47 | `async_fifo.vhd`, `axi_rd_port.vhd` | `attribute async_reg ... "TRUE"` on 8 + 6 synchroniser signals. Synthesis-affecting (stops the tools splitting 2FF pairs), not functional. Instantiated 28x | **NO** |
| `209d69e` | 08-29 19:28 | `util_pkg.vhd` | `clog2` no longer overflows above 2**30. Changes generated widths only above 2^30; subsystem A's generics are not | **NO**, no netlist delta expected here |
| `2149a94` | 08-29 20:44 | `matvec_int4_desc_axi.vhd`, `..._desc_pkg.vhd` | refusal error-info encoding; changes what STATUS/ERR reports | **NO** |
| **`75f95a8`** | 08-29 23:37 | `axi_rd_fsm.vhd`, `axi_rd_port.vhd` | **clamps `outst` at 0** (an unclamped wrap makes the port issue no further AR, forever -- the silent hang), plus `abort_c` so the run gate shuts on the core clock in `g_dc` | **NO** |
| **`3ecc729`** | 08-30 00:07 | `matvec_int4_desc_axi.vhd` | combinational `go_now` replaces the registered `go`; `job_done <= done_l and not go_now`, same mask in STATUS. Closes the three-clock window where STATUS reported the PREVIOUS job | **NO** |
| **`a4a564c`** | 08-30 00:40 | `hw/fk33/rtl/fk33_thermal.vhd` | +224/-23: the two HBM reads are two dies, not two copies. Removes the equality precondition whose spurious trips halted compute; and the halt/resume/warn/cause reductions now cover both stacks | **NO** |

**All four items the brief named are confirmed present and confirmed absent from
the bitstream.** One correction to the brief: **THERMFIX is exactly one RTL
commit, `a4a564c`, not several.** `git log -- hw/fk33/rtl/fk33_thermal.vhd`
returns two commits ever: `6b57c73` (08-28 15:56, the original guard -- that one
IS in the loaded bit) and `a4a564c`.

### What the rebuild does NOT add

`54b3c1a..HEAD` has **28 commits touching `rtl/`; only 8 touch a file this build
reads.** The other 20 are subsystem B/C/D: `912228c`, `e79ae31`, `e5e4fa5`,
`9a7f3c0`, `bfdae6b`, `d80d3a9`, `6c9aa09`, `e783363`, `51323ca`, `9d287f2`,
`bf99d39`, `8889cfa`, `3e93bed`, `a9792df`, `2d10f76`, `a77d181`, `b75d7a1`,
`9f690a0`, `c754e39`, `bb2230d`. Several are large LUT reductions. **None of
them would change a rebuild of this bitstream.** Of the 8 that do land,
`f1c4b5b` is assert-only and `209d69e` is inert at this geometry. **The genuine
functional deltas are four: `0ff6828`, `75f95a8`, `3ecc729`, `a4a564c`.**

### Build-flow commits since `928ad9f`

`ed1ffe2` (commits the pblock the bit already had, applied by hand),
`2febb2a` (e2e reproduction; two build checks were wrong), `0b692f0` (bound the
`launch_runs` wait). `gen_fk33_engine.py`, `rtl/fk33_engine.vhd` and
`hw/fk33/rtl/fk33_aux.vhd`: no commits since. So the build harness has moved
forward three times and the engine wrapper not at all.

---

## 3. THERMFIX'S HANDOFF, CLOSED

### What the guard is for

`gen_pcieep.py:main()` reads `hw/fk33/rtl/fk33_thermal.vhd` as text and refuses
to emit a build script if named literals are missing. It exists because the
thermal guard is the only thing standing between a long run and a cooked die,
and Vivado **silently ignores `assert ... severity failure` in synthesis** -- so
the RTL's own elaboration-time asserts are not a barrier to a bitstream, and the
negative-`natural` constants are. A generator that can emit a build whose guard
trips at 120 C is a generator that can cook the part.

THERMFIX asked for three literals. **Nine were added**, because the guard's
existing pattern covers both the synthesis constant *and* the elaboration assert
for every other threshold, and because THERMFIX's third fix -- `hbm_hot`,
`hbm_cool`, `warn` and `cause` reading stack 0 alone -- had nothing guarding it
at all. That third defect was accidentally safe ONLY while the equality
precondition existed; `a4a564c` removed the precondition, so it is now live logic
that a future edit could silently revert.

### Teeth check, with the attribution control (MEASURED)

Harness: `/mnt/storage/bitprep_scratch/teeth/teeth.py`. It runs `main()` from
two generators against a mutated copy of `fk33_thermal.vhd` -- **NEW** (this
track's edit) and **OLD** (`git show HEAD:hw/fk33/gen_pcieep.py`, i.e. the new
rows muted). A row is credited to this track only when NEW refuses and OLD does
not. Every output path is redirected; nothing in the repository is written.

```
BASELINE (unmutated RTL): NEW=PASSED  OLD=PASSED

row       NEW      OLD      attribution    reintroduces
----------------------------------------------------------------------------------
D-BOUND   REFUSED  PASSED   NEW ALONE      the divergence bound widened past its ceiling (40)
D-FLOOR   REFUSED  PASSED   NEW ALONE      the divergence bound collapsed towards the equality test
D-CEIL    REFUSED  PASSED   NEW ALONE      the synthesis-time ceiling constant deleted
D-FLR     REFUSED  PASSED   NEW ALONE      the synthesis-time floor constant deleted
D-ASRT    REFUSED  PASSED   NEW ALONE      the elaboration-time bracket on the bound deleted
D-COVER   REFUSED  PASSED   NEW ALONE      the stuck-sensor coverage assert deleted
S0-HALT   REFUSED  PASSED   NEW ALONE      defect 3: the HBM halt reads stack 0 alone again
S0-COOL   REFUSED  PASSED   NEW ALONE      defect 3: the HBM resume reads stack 0 alone again
S0-CAT    REFUSED  PASSED   NEW ALONE      defect 3: the CATTRIP term reads stack 0 alone again
C-DIE     REFUSED  REFUSED  both           control: die halt threshold moved to 120 C (old row)
C-FSAFE   REFUSED  REFUSED  both           control: the guard powers up released (old row)
N-NOBITE  REFUSED  PASSED   NEW ALONE      not claimed: the bound set to 21, one code off
----------------------------------------------------------------------------------
rows credited to this track's new entries: 10
TEETH PASS
```

Read three things off that table:

- **All nine claimed rows are NEW ALONE.** The old guard let every one of them
  through. Without the control, "nine kills" would have been the claim; the
  control is what makes it "nine kills that are this track's".
- **The two controls are `both`, as they must be.** `C-DIE` and `C-FSAFE`
  reintroduce defects the guard already covered. They measure that the harness
  can see a kill at all, and that the old guard is not simply broken -- without
  them, nine NEW-ALONE rows are equally consistent with a NEW generator that
  refuses everything.
- **`N-NOBITE` bit, and it is reported under its own name because it is the
  resolution floor.** These rows are literal-string matches, so
  `G_HBM_MAX_DELTA : natural := 20` pins the exact value 20, not a range. A
  legitimate retune of the bound to 21 will be refused until the guard row is
  updated too. That is the same contract the existing `G_DIE_HALT_C := 90` row
  has, so it is the house pattern rather than a defect -- but it is a cost, and
  the next person to retune the bound needs to know it is there.

### The generator's own selftest (MEASURED)

```
$ python3 hw/fk33/gen_pcieep.py --selftest
GUARD ALONE=8  both=0  NEITHER=0
SELFTEST PASS
```

Note what this does and does not cover: `--selftest` exercises the **Tcl**
guards it injects into the build script (`fk33_assert_run_started`,
`fk33_assert_run_done`, `fk33_bound`) plus whole-file `info complete`. It does
**not** touch the RTL literal-string guard at all. The table above is the only
evidence for that one, which is why it was built.

### `build_fk33_pcieep.tcl`: generated, not maintained beside

MEASURED. Line 1 of the file: `# GENERATED from hw/fk33/build_fk33_i2cprobe.tcl
by hw/fk33/gen_pcieep.py -- do not hand-edit; regenerate so the probe build's
fixes are not lost.` **Hand-editing it is the trap.** Regenerating is correct.

And MEASURED, regenerating changes nothing:

```
$ python3 gen_i2cprobe.py && python3 gen_fk33_engine.py && python3 gen_pcieep.py
$ git status --porcelain -- hw/fk33/build_fk33_i2cprobe.tcl hw/fk33/fk33_i2cprobe.xdc \
      hw/fk33/rtl/fk33_engine.vhd hw/fk33/build_fk33_pcieep.tcl hw/fk33/fk33_pcieep.xdc
(empty)
```

All five generated artefacts in the tree are already current. This track's guard
edit is a refusal check, not an emitter, so it changes no output -- confirmed by
regenerating `gen_pcieep.py`'s two outputs into a scratch directory and diffing:
**0 lines of difference on both.**

---

## 4. DOES THE COMPOSED DESIGN STILL ELABORATE?

**Yes, at the exact generics the build uses.** MEASURED, and bounded honestly
below.

MEASURED first: `build_fk33_pcieep.tcl` sets **no generic overrides** on either
`fk33_therm_0` or `eng` (the only `set_property CONFIG.*` on those cells are
clock/reset/busif associations). So the VHDL defaults ARE the built shape, and a
GHDL elaboration at defaults is an elaboration at the build's shape.

```
$ ghdl -a --std=08 ... 14 of the 15 files, in the build's order
ANALYSE OK
$ ghdl -r --std=08 fk33_engine  --stop-time=1ns   ->  rc=0
$ ghdl -r --std=08 fk33_thermal --stop-time=1ns   ->  rc=0
```

`-r`, not `-e`: GHDL here is the mcode backend, where `-e` produces no binary and
silently succeeds. Only `numeric_std` metavalue warnings at time 0, which is what
an undriven top produces; no assertion failure, no elaboration error.

`hw/fk33/rtl/fk33_aux.vhd` is the fifteenth file and is **out of GHDL's reach**:
it instantiates UNISIM primitives. It is also unchanged since `6b57c73`, i.e. it
is the same source that is already in the loaded bitstream.

The RTL-level behaviour of the two fk33 units, from the build's own gate:

```
$ ./hw/fk33/sim_aux.sh
Note: TB_FK33_AUX PASS
TB_FK33_AUX PASS
Note: die halt code = 745  resume code = 715
Note: TB_FK33_THERMAL PASS
TB_FK33_THERMAL PASS
```

Every board-free gate `pcieep_build.sh` runs before Vivado (MEASURED, each run
individually):

```
FK33_XDC_CHECK OK
FK33_HOST_COMPILE OK
FK33_HOST_SELFTEST OK
FK33CTL_TESTS OK
AUXPROBE_SELFTEST OK
AXISEL_SELFTEST OK 12 cases
```

### What this establishes, and what it does not

**Structure is not values, and elaboration is not synthesis.** What is
established: the fifteen-file set is analysable and elaborable together at the
build's generics, the thermal guard's own bench passes, and every board-free
gate in the build script is green -- so the build will not die in its first three
minutes on a source error or a gate.

What is **NOT** established, and only Vivado can establish it:

- that the design synthesises (elaboration in GHDL and elaboration in Vivado
  are different front ends, and `synth_design` is where a `severity failure`
  assert stops being a barrier);
- that it still places, routes and closes timing with the four fixes in;
- that it computes anything correct. **Nothing in this track ran a single
  matvec.** A green build is a loaded magazine.

### One timing risk to watch, flagged rather than measured

**ESTIMATE.** `3ecc729` replaces a registered `go` with a **combinational**
`go_now` decoded from the AXI-Lite write handshake, and feeds it into the FSM,
into STATUS and into the `job_done` port. That is a new combinational path from
the AXI-Lite write channel into the descriptor FSM which did not exist in the
loaded bitstream. The assumption behind calling it low-risk is that AXI-Lite is
not near the critical path -- the loaded design's WNS is +0.045 ns and its
critical paths are in the core datapath, not the register file. It is cheap to
check after the build and expensive to be surprised by, so section 6 says to
read `FK33_TIMING` rather than assume it.

---

## 5. TRAPS HIT, INCLUDING MY OWN

1. **My own `grep -n "library unisim"` returned nothing on a file whose line 134
   is `library unisim;`.** The pattern was right; the invocation across six
   files produced no output at all and I read that as "no dependency". GHDL
   then refused `fk33_aux.vhd` on exactly that. `grep -il unisim` over the same
   list found it immediately. **A grep that returns nothing is evidence of
   nothing until you have shown it returns something on a case you know is
   there.** That is the same defect class as a checker never shown to fail.

2. **Loading a generator from a copy silently corrupts its path table.** The
   first teeth harness copied `gen_pcieep.py` into scratch and overrode
   `THERM_RTL`, `SRC` and friends after import. It failed with `ABORT: the probe
   build script no longer contains: add_files -fileset constrs_1 -norecurse`,
   which reads exactly like a real defect in the tree. It was not: the module's
   `SUBS` table is built **at import time** from `HERE = dirname(__file__)`, so a
   copy in scratch bakes scratch paths into `SUBS` before any override can run.
   Fix: import from `hw/fk33/` (namespaced filenames, deleted afterwards by
   explicit literal path) and override only `THERM_RTL`, `DST`, `XDC_DST`.
   **The tell that it was my harness and not the tree: the same abort fired on
   the OLD generator too.**

3. **`git rev-parse HEAD` as its own step, twice.** HEAD moved from `c309572`
   to `b13d837` during this track. Both are recorded.

4. **`hw/fk33/bit/*.bit` is not tracked by git.** It is easy to assume a
   bitstream referenced by sha256 in three documents is under version control.
   It is not, and there is exactly one copy of it.

---

## 6. THE COMMANDS

`SAFE` = touches no hardware, runs anywhere. `CARD` = **you only**; a subagent
must never run these.

### Stage 0 -- SAFE, ~2 min. Preconditions. Run these first, every time.

```bash
cd /home/orencollaco/GitHub/llama.vhdl
git rev-parse HEAD                      # record it; HEAD moves under you here
df -h /mnt/storage                      # want > 60 G free
free -g                                 # want > 26 G of (free + reclaimable)
uptime                                  # want load < 2
ps -eo pid,etime,args | grep -E 'unwrapped/lnx64\.o/vivado' | grep -v grep
```

The last line must print **nothing**. A full pcieep build has a MEASURED cgroup
peak of **25.0 GiB** on a 31 GiB box; it cannot share the machine with COMPOSE4.
Do not use `pgrep -f`/`pkill -f` on a pattern that appears in your own command
line -- that has killed the shell four times in this project.

### Stage 1 -- SAFE, ~30 s. Protect the way back BEFORE anything can overwrite it.

```bash
mkdir -p /mnt/storage/fk33_bit_archive
cp -v hw/fk33/bit/fk33_pcieep_eng.bit \
      /mnt/storage/fk33_bit_archive/fk33_pcieep_eng_ROLLBACK_ed1ffe2-era.bit
cp -v hw/fk33/bit/fk33_i2cprobe.bit \
      /mnt/storage/fk33_bit_archive/fk33_i2cprobe.bit
sha256sum /mnt/storage/fk33_bit_archive/*.bit
```

Expect `6b12b3c46ee26396bcbc1f75cf240fe6231528a7a10c95ac91596b52bce164c6` for
the first. **Do this even though the build writes elsewhere.** The probe copy
matters as much as the endpoint one: without it `pcieep.sh` cannot raise VCCINT,
which powers up at 0.678 V against a 0.698 V floor on every power cycle.

### Stage 2 -- SAFE, ~3 min, ~3.4 GB peak. Block design only.

```bash
cd /home/orencollaco/GitHub/llama.vhdl/hw/fk33
BUILD_ROOT=/mnt/storage/fk33_pcieep_build ./pcieep_build.sh --bd-only 2>&1 \
  | tee /mnt/storage/fk33_pcieep_build/bdonly.report
```

Catches every class of error that is not a timing or placement result, at 1/20th
of the cost. **Read for**, not assume:

```
FK33_ENG portcheck bad=0 (must be 0)
FK33_THERM ...            (blind guard shows as FK33_THERM FAIL)
FK33_SYSMON ...
FK33_BD_VALIDATE / FK33_BD_ONLY_DONE
```

Note `BUILD_ROOT` is being overridden. Its default is under `/tmp`, which this
box clears at every boot and which lives on a root filesystem at 91%.

### Stage 3 -- SAFE, ~56 min, **25 GiB peak**. The build.

```bash
cd /home/orencollaco/GitHub/llama.vhdl/hw/fk33
BUILD_ROOT=/mnt/storage/fk33_pcieep_build \
  claude-tmux --mem 28G  # or: systemd-run --user --unit=fk33-bitprep --collect \
                         #     -p MemoryHigh=28G  bash -c '...'
./pcieep_build.sh 2>&1 | tee /mnt/storage/fk33_pcieep_build/build.report
```

Run it under `claude-tmux` or a transient user unit so a code-server restart or
a systemd-oomd cgroup kill cannot take it. **Do NOT arm a hard `MemoryMax`, and
do not arm `MemoryHigh` below ~26 G** -- PBLOCK's 18 GB guard would have killed
this build about six minutes in, because PBLOCK's own 8.62 GB peak was a
checkpoint flow that skipped synthesis; the 25 GiB is the 35 out-of-context IP
runs at `-jobs 4`.

Phase timings to expect (MEASURED, `impl_1/runme.log`, e2e run):

```
opt_design        cpu 00:10:20   elapsed 00:03:09
place_design      cpu 00:31:27   elapsed 00:10:37
phys_opt_design   cpu 00:02:03   elapsed 00:00:22
route_design      cpu 00:58:38   elapsed 00:19:50
write_bitstream   cpu 00:02:55   elapsed 00:01:39
```

The script ends by printing a block of checks. **Read them; they are not
assertions.** The ones that decide:

| line | must read | if it does not |
|---|---|---|
| `FK33_TIMING` | WNS >= 0 | the four fixes cost slack. Loaded bit is +0.045, e2e was +0.069 |
| `Designutils 20-1307` count | **0** | Vivado skipped an XDC block (an `if` in a constraint file) with only a CRITICAL WARNING |
| `12-584` count | 0 | unmatched constraints |
| `FK33_ENGI` | present | subsystem A after place and route |
| `FK33_THERM FAIL` | absent | the thermal guard is blind; do not run a sustained workload |
| `FK33_SYSMONI` | present | trip points in the routed netlist, not the requested ones |
| `FK33_BITSTREAM` | present | no artefact |
| BD 41-1377 after the last exclude | 0 | address-map overlap that is real (32 during the exclude sequence are expected) |

`FK33_ENG portcheck bad=` is emitted only by a `--bd-only` run; its absence in a
full build is normal and the script says so.

### Stage 4 -- SAFE, ~10 s. Save the artefact under a NEW name.

```bash
cd /home/orencollaco/GitHub/llama.vhdl/hw/fk33
BIT=/mnt/storage/fk33_pcieep_build/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper.bit
cp -v "$BIT" bit/fk33_pcieep_eng_4fix.bit
sha256sum bit/fk33_pcieep_eng_4fix.bit bit/fk33_pcieep_eng.bit
head -c 160 bit/fk33_pcieep_eng_4fix.bit | strings -n 4 | head -4
```

**Do not run `./save_bitstream.sh` for this.** It writes
`bit/fk33_pcieep.bit` -- the Aug-27 pre-engine build -- from a hard-coded `/tmp`
path, and it exits non-zero unless it finds both files there. It will not
clobber `fk33_pcieep_eng.bit`, but it will not save the new one either.

Record the sha256 and the embedded timestamp in the load write-up. And, for next
time: setting `BITSTREAM.CONFIG.USERID` to a short git sha in
`gen_pcieep.py` would make this whole section-1 reconstruction unnecessary, and
it is readable back over JTAG. Not done here; `gen_pcieep.py` is this track's
file but the change belongs with someone who can validate it on the card.

### Stage 5 -- CARD. **You only.**

```bash
cd /home/orencollaco/GitHub/llama.vhdl/hw/fk33
EP_BIT="$PWD/bit/fk33_pcieep_eng_4fix.bit" ./pcieep.sh
```

**`EP_BIT` is not optional and this is the trap.** `pcieep.sh` prefers
`bit/fk33_pcieep.bit` when it exists -- and it exists, and it is the **Aug-27
pre-engine bitstream**. Without `EP_BIT` the script will happily configure the
card with a design that has no engine in it and report success.

The sequence it runs, and why the order is fixed: configure the probe bitstream
(GPIO bit-bang available), step VCCINT 0.678 -> 0.717 V (volatile wiper, lost on
every power cycle), configure the endpoint (wiper survives a reconfigure), then
rescan PCIe. **Never take VCCINT to 0.85 V; stay at wiper 68.**

### Stage 6 -- ROLLBACK. **CARD. You only.**

```bash
cd /home/orencollaco/GitHub/llama.vhdl/hw/fk33
sha256sum /mnt/storage/fk33_bit_archive/fk33_pcieep_eng_ROLLBACK_ed1ffe2-era.bit
# must be 6b12b3c46ee26396bcbc1f75cf240fe6231528a7a10c95ac91596b52bce164c6
EP_BIT=/mnt/storage/fk33_bit_archive/fk33_pcieep_eng_ROLLBACK_ed1ffe2-era.bit \
  ./pcieep.sh
```

This is a **reconfigure, not a flash write.** Nothing in this document touches
the SPI flash. The card's factory flash was destroyed once in this project by an
agent crossing the hardware line; `flash.sh`, `tcl/flash_program.tcl` and
`tcl/flash_mcs.tcl` are not part of any procedure here.

Rolling back returns the card to the state every measurement of the last two
days was taken on -- which is also the state that trips the thermal guard 253
times in 1300 s. If the new bitstream is bad, roll back; if the new bitstream is
merely unmeasured, do not.

### Failure modes

| symptom | almost certainly | do |
|---|---|---|
| build dies in the first 3 min | a board-free gate, named in the output | fix the named thing; the gates are all reproducible without Vivado |
| `ABORT: ... rtl/fk33_thermal.vhd` from `gen_pcieep.py` | someone edited the thermal RTL and the guard caught it | read the ABORT text; it names which safety property went |
| build OOM / whole session killed | it shared the box | stage 0 again; run under `claude-tmux --mem 28G` |
| `Designutils 20-1307` count non-zero | an `if` reached an XDC file | Vivado skipped the whole block with only a CRITICAL WARNING; the constraint is silently absent |
| build "succeeds", `FK33_BITSTREAM` missing | impl run did not finish | `wait_on_run -timeout` returns rc 0 on expiry without raising; check `impl_1/runme.log` directly |
| WNS < 0 | the four fixes, or the run | first suspect: `3ecc729`'s combinational `go_now` on the AXI-Lite write path (section 4) |
| card configures, no PCIe link | configuration time budget | the script prints `FK33_CFGTIME`; budget is 100 ms T_PVPERL + 100 ms host wait |
| card configures, engine absent, everything else fine | `EP_BIT` was not set and `bit/fk33_pcieep.bit` was used | stage 5, set `EP_BIT` |

---

## 7. MEASURED AND REJECTED -- DO NOT RETRY

- **Do not hand-edit `hw/fk33/build_fk33_pcieep.tcl` or `hw/fk33/fk33_pcieep.xdc`.**
  MEASURED: both are generated, and regenerating reproduces the checked-in
  versions byte-for-byte. A hand edit is silently reverted by the first line of
  `pcieep_build.sh`, which runs all three generators before Vivado.
- **Do not commit a regeneration.** MEASURED: `git status --porcelain` over all
  five generated artefacts is empty after running `gen_i2cprobe.py`,
  `gen_fk33_engine.py` and `gen_pcieep.py`. There is nothing to commit.
- **Do not run a hand-driven place/route to reproduce the loaded bitstream's
  flow.** MEASURED: the standard `pcieep_build.sh` flow already carries the
  pblock (`fk33_pblock.xdc`, `ed1ffe2`, implementation-only) and the placement
  directive (`set_property strategy Performance_RefinePlacement`, which is
  `place_design -directive ExtraPostPlacementOpt` -- the same directive
  `place_dx.tcl` used), and it has already been MEASURED end to end producing
  WNS +0.069 ns with 0 routing errors, better than the hand-driven +0.045.
  `place_dx.tcl` and `route_two.tcl` were a one-off around an inherited pblock
  that is now deleted in the committed XDC.
- **Do not use `./save_bitstream.sh` to save the new artefact.** It targets
  `bit/fk33_pcieep.bit` from a hard-coded `/tmp` path and would not touch the
  engine bitstream at all.
- **Do not arm `MemoryHigh` at 18 GB for this build.** MEASURED: it would have
  killed the e2e run about six minutes in. 25.0 GiB is the real peak; the
  8.62 GB figure in PBLOCK's write-up is a checkpoint flow with no synthesis.
- **Do not trust `ghdl -e` as an elaboration proof.** mcode backend: it produces
  no binary and silently succeeds. Everything above used `ghdl -r`.
- **`gen_pcieep.py --selftest` does not exercise the RTL literal-string guard.**
  It covers the injected Tcl guards only. Do not read `SELFTEST PASS` as
  evidence about the thermal guard; the table in section 3 is that evidence.

---

## 8. OPEN, NOT YET ANSWERED

1. **Whether the SHELL build read a detached worktree or the main checkout.**
   The scratch tree is gone and the committed `build_fk33_pcieep.tcl` carries
   main-checkout absolute paths. It does not change the answer for `0ff6828`
   (excluded by the clock either way), but the netlist's `rtl/` content is
   asserted by a document, not proven by an artefact.
2. **Whether the design still synthesises, places, routes and closes timing with
   the four fixes in.** Not attempted -- the machine was not free. This is the
   whole of stage 3 and it is the real gate.
3. **Whether the four fixes are correct on silicon.** A green build establishes
   nothing about values. `75f95a8` and `3ecc729` were each verified against
   benches and mutation tables; neither has run on the card, and `a4a564c` has
   run only against `tb_fk33_thermal`.
4. **Whether `d570899`'s `ASYNC_REG` attributes change the placed result.** They
   are instantiated 28x and stop the tools splitting 2FF pairs. ESTIMATE: a
   small utilisation and slack shift is likely; nothing has measured it.
5. **Whether `0ff6828` is genuinely absent from the loaded bitstream.** Argued
   twice, both readings agreeing, from build timestamps. Not proven from an
   artefact. If it matters, the sha in `BITSTREAM.CONFIG.USERID` (section 6,
   stage 4) is the fix for next time.
6. **The teeth harness in section 3 lives only in scratch**
   (`/mnt/storage/bitprep_scratch/teeth/teeth.py`) and **nothing schedules it.**
   That is the same defect class this project has already found four times: a
   check that exists but that no gate runs. It should become
   `hw/fk33/teeth_thermal_guard.py` and a row in `pcieep_build.sh`'s board-free
   gate block, which is a one-line change beside `AXISEL_SELFTEST`. Not done
   here: `pcieep_build.sh` is not this track's file, and adding a new file under
   `hw/fk33/` while three tracks are running was not worth the collision. The
   harness is short enough to reconstruct from the table above if the scratch
   directory is cleared first.
7. **A correction to an existing document, found while doing this.**
   `docs/debugging/2026-08-29_build-e2e-project-run.md` (~line 490) attributes
   the `ASYNC_REG` attributes to `f1c4b5b`. MEASURED, `git log -S'async_reg' --
   rtl/async_fifo.vhd rtl/axi_rd_port.vhd` returns exactly one commit,
   **`d570899`**; `f1c4b5b`'s only non-comment change is one assert condition.
   The doc's *conclusion* stands -- the e2e netlist does differ from PBLOCK's
   because `ASYNC_REG` landed in between -- only the sha is wrong. Not edited
   here: that file belongs to another track.

---

## 9. CORRECTIONS TO THE BRIEF

- **"the THERMFIX commits" is one commit, `a4a564c`.** `git log --
  hw/fk33/rtl/fk33_thermal.vhd` returns two ever: `6b57c73` (the original guard,
  in the loaded bit) and `a4a564c`.
- **The brief attributes the loaded bitstream to nothing in particular, and the
  repository attributes it to `ed1ffe2`.** `ed1ffe2` is four minutes too late to
  be the netlist's commit. See section 1.
- **"Anything else in `git log` since the loaded bitstream" is 28 `rtl/` commits,
  of which 20 are not in this design.** The rebuild's value is four commits, not
  twenty-eight, and saying so is the point of section 2.
- **THERMFIX's handoff named three literals; nine were added.** The two extra
  elaboration asserts follow the guard's existing pattern for every other
  threshold; the three `hbm_max`/`syn_cat1` literals guard THERMFIX's third fix,
  which the handoff did not mention and which nothing else covers.
