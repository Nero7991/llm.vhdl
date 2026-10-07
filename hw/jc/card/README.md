# Jungle Cat (VU35P, no PCIe) 27B card: bitstream build

Plan Task 9 (`.superpowers/sdd/2026-10-07-jc-engine-composition/task-9-brief.md`).
Written and dry-run tested only: nothing in this directory opens a hardware target,
and this brief's implementer never ran Vivado.

## Files

| File | What |
|---|---|
| `gen_jc_card.py` | Emits `jc_card_bd.tcl`, `jc_card.xdc`, `jc_card_top.vhd` and the 27B package (Task 8) |
| `jc_card_bd.tcl` | Block design `jcc`: generated, do not hand-edit (Task 8) |
| `jc_card.xdc` | Pins and the board clock: generated, do not hand-edit (Task 8) |
| `jc_card_top.vhd` | Synthesis top: `jcc_wrapper` + `jc_ctl_rx` (USER3): generated, do not hand-edit (Task 8) |
| `build_card.tcl` | Full build: project sources, BD, synth_1, in-process implementation, every check, bitstream (this task) |
| `jccard_levers.tcl` | Pure parsing of a `Parameter <NAME> bound to: <value>` trace line (0/1/false/true), runnable under plain `tclsh` with no Vivado (fix round 1, C1) |
| `run_card.sh` | Orchestration: location/root/process-presence refusals, tracked-tree copy, levers patch, provenance, regeneration, the capped Vivado run, report harvest, the nonce-gated sentinel (this task) |
| `test_run_card.py` | Dry-run assertions on `run_card.sh`, static assertions on `build_card.tcl` |
| `test_jccard_levers.py` | Runs `jccard_levers.tcl` under `tclsh` against real log excerpts (`testdata/`) |
| `testdata/` | Verbatim excerpts of three real builds' `bd_wrapper.vds` (off/mixed/on), plus a synthetic missing-line case |
| `check_pcieep_arms.sh` | Task 8's four-arm proof that `gen_pcieep.py` emits identical FK33 text after refactors |

## Build

    # one Vivado per box; budget stated before dispatch (CLAUDE.md measured card-build
    # shape: ~47 GB including swap under a tighter cap than this one -- watch the guard)
    bash hw/jc/card/run_card.sh /mnt/storage/fk33_builds/<tag>
    # to accept a routed design with WNS < 0 (never WHS < 0, which is always refused):
    bash hw/jc/card/run_card.sh /mnt/storage/fk33_builds/<tag> xcvu35p-fsvh2104-2L-e allow_neg
    # prove the commands and bindings without touching git, Vivado or the filesystem
    # (a dry run's root is never the real build tree, so --allow-scratch-root is
    # mandatory for it; part/allow_neg are optional exactly as in a real run):
    bash hw/jc/card/run_card.sh --dry-run --allow-scratch-root <root> [part] [allow_neg]

`<root>` must be under `/mnt/storage/fk33_builds/` (pass `--allow-scratch-root` to
build somewhere else -- a test or a dry run only) and must not exist yet, or be
empty: a stale `build.log` left in a reused root could otherwise read as done when
Vivado never started this run, so `run_card.sh` refuses outright instead (fix round
1, I3/I4). `run_card.sh` creates `<root>/src` (the tracked tree, `git archive HEAD`,
patched), `<root>/proj` (the Vivado project) and `<root>/results` (the harvested
reports and bitstream). The part defaults to, and is refused unless it equals,
`xcvu35p-fsvh2104-2L-e` (pass `--allow-other-part` to build for a different one).
Before launching Vivado, `run_card.sh` also refuses if another Vivado is already
running anywhere on the box, or if `llama-server` is running (pass
`--allow-llama-server` to override), identified by `/proc/PID/exe`, never `pgrep -f`
or a `cmdline` match (CLAUDE.md: both have matched a script's own text and done
damage on this project); none of these three refusals is enforced under `--dry-run`.
It prints the memory budget (`MemAvailable`, `SwapFree`) before doing anything.

Gate on the anchored sentinel in `<root>/build.log`: `grep -qE '^JCCARD_DONE'`. A
failure is `grep -qE '^JCCARD_FAIL' <root>/build.log` (or `run_card.sh`'s own stdout,
which prints the same line) -- never the process exit code alone and never a
timeout, per CLAUDE.md ("a completion signal that also fires on failure is not
one"): the swap guard killing the unit and a hung waiter both exit non-zero with no
`JCCARD_DONE` line, and the absence is what every caller gates on. The DONE line
must also come AFTER this run's own `JCCARD_NONCE` line in the same log (fix round
1, I3): `build_card.tcl` prints its nonce (passed by `run_card.sh` on `-tclargs`)
before doing anything else, so a log that somehow survived from an earlier run in a
reused root cannot satisfy both conditions in order. A dry run never prints a line
starting with `JCCARD_DONE` (fix round 1, minor 9): it prints
`DRYRUN would write: JCCARD_DONE` instead, so an automated caller greping the two
scripts' combined output can never mistake a dry run for a real one.

Part: `xcvu35p-fsvh2104-2L-e` (the silicon in hand; global-constraints.md). Clock:
`clk_core` = 200 MHz, the one clock for the engine, every HBM AXI port, the card, the
grant, the loader and the ctl core (no AXI clock converter anywhere) -- `build_card.tcl`
refuses the build if the aclk it finds does not read back 5.000 ns.

## What `run_card.sh` does

1. `git archive HEAD | tar -x` into `<root>/src` -- the TRACKED tree, never the
   working copy (another track's half-edited file must never reach a build).
2. Applies `hw/fk33/results/card_build20_2026-09-24/build12_levers_off.patch` there
   (`git apply --check` first; refuses on anything but a clean apply). This is
   build 20's lever set: FAST_POP, NWIDE, SWEEP_PIPE, SCORE_EARLY off; PIPE, WIDE,
   MAXOUT 8 on -- load-bearing until a lever is shown safe on silicon
   (hw/fk33/CLAUDE.md).
3. Records `git rev-parse HEAD` and the patch's sha256 into `<root>/PROVENANCE.txt`.
4. Regenerates, IN `<root>/src`: `hw/fk33/gen_fk33_card.py` under
   `gen_jc_card.JC_CARD_ENV` (`FK33_C_KV_BLOCK=16 FK33_C_MAXPOS=16384
   FK33_MODEL=QWEN38_27B`, matching build 27B-1's generics), which makes
   `hw/fk33/rtl/fk33_card.vhd`'s GENSTAMP equal `JC_CARD_ENV`; then
   `hw/jc/card/gen_jc_card.py` (`JC_CLK_CORE_MHZ=200`), which now runs IN PLACE
   (`card_is_jc()` is true) and rewrites `jc_card_bd.tcl`, `jc_card.xdc`,
   `jc_card_top.vhd` and the 27B package in that tree. Both are checked: non-zero
   exit fails the build, and the four output files must exist afterward.
5. Runs `vivado -mode batch -source <root>/src/hw/jc/card/build_card.tcl` under
   `hw/jc/loader/run_capped.sh`, `MemoryHigh=24G`, a 30 GiB swap guard (the same
   30 GiB constant the loader and pinfinder builds use).
6. Harvests `utilization(_hier)`, `timing_summary`, `cdc(_summary)`,
   `route_status`, `clock_interaction`, `clocks`, `exceptions(_ignored)`,
   `bus_skew`, `methodology`, `drc`, `pulse_width`, `check_timing` and the
   bitstream (`jc_card.bit` / `.ltx`) into `<root>/results`.
7. Writes the sentinel: `JCCARD_DONE` only if Vivado's own log contains that
   anchored line; otherwise `JCCARD_FAIL <reason>`, taken from Vivado's own
   `JCCARD_FAIL` line when there is one.

## What `build_card.tcl` checks (every one a hard error, never a warning)

- Every VHDL-2008 source reads back as `VHDL 2008` (the FK33 lesson: a path that
  does not match leaves the file at the Vivado default and the failure surfaces
  hundreds of lines later, naming neither the file nor the standard).
- The 27B package (`hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd`) is in `sources_1`
  exactly once, added by `jc_card_bd.tcl` itself before `create_bd_design` (Task 8
  fix round 1); `build_card.tcl` never adds `rtl/model_cfg_pkg.vhd` (the 9B
  binding), because `jc_card_bd.tcl` refuses the build if it is present.
- Every one of the six module-reference cells' input pins carries a net (no
  constant-tied or open input), after `open_run synth_1`.
- The levers not visible to the BD -- NWIDE, SWEEP_PIPE, SCORE_EARLY -- are read
  from the synthesis log's `Parameter <NAME> bound to:` lines and refused unless
  every occurrence is `false`. A MISSING bind line is refused exactly like a wrong
  value (hw/fk33/CLAUDE.md: "a lever's absence from the log proves nothing", so an
  absence here is not read as a silent pass). FAST_POP is checked at BD-generation
  time instead (`gen_jc_card.py`'s own readback), because it is a generic on the
  `fk33_engine` module-reference cell and visible there.
- `aclk` reads back as 5.000 ns (200 MHz, `clk_core`'s one domain).
- The CDC bounds and audits from `hw/jc/loader/jc_loader_timing.tcl` (the loader's
  own crossings, unchanged RTL, reused with its leading-wildcard hierarchy
  patterns) and `hw/jc/ctl/jc_ctl_timing.tcl` (the ctl core's crossings, including
  `jctl_cdc_audit`'s hard gate on any aclk<->TCK endpoint that is not one of the
  six named synchronisers).
- CATTRIP -> `eng/compute_halt`: RULED asynchronous (no 2-FF synchroniser module
  exists for it; task-8 report concern 1), constrained with `set_false_path` from
  the `halt_or` OR cell's `Res` pin, the same treatment the loader gives its own
  `hbm_cat_trip`.
- `report_cdc`'s own text is scanned for a `Critical` row outside the named
  synchronisers (best-effort; UNVERIFIED against a real report_cdc run, so
  `jctl_cdc_audit`'s structural gate is the one this task actually trusts).
- The BSCAN census (`jccard_bscan_check`, run twice: right after `opt_design`, cheap
  and early, and again right before `write_bitstream`) is exactly one chain-3 BSCANE2
  (`u_jc_ctl_rx/u_jc_ctl_bscan`, ours), one chain-4 BSCANE2 (`u_jc_frx/u_jc_bscan`,
  the loader's, unchanged), and AT MOST ONE debug hub, which must be on chain 1.
  `jtag_hbm` (a `jtag_axi` IP core) makes Vivado insert exactly one debug hub on
  chain 1, exactly as it does for the loader's own `jtag_axi_0`/`jtag_hbm`
  (`hw/jc/loader/README.md`: "Debug cores (ltx): ... both on user chain 1"); a hub
  anywhere else, or more than one, is still refused.
- WHS is never allowed negative. WNS < 0 fails unless `allow_neg` is given on
  `-tclargs`.

## Concerns (open, not yet determined)

1. **No Vivado has run this.** Every line above is written against the proven
   shape of `hw/jc/loader/build_loader.tcl` and `hw/fk33/build_fk33_pcieep.tcl`,
   and the report_cdc text scan is explicitly labelled best-effort for that
   reason. The controller's `--bd-only` run (not available to this task's file
   list) is the next real test.
2. **The loader's own internal CDC has no generalised audit proc** analogous to
   `jctl_cdc_audit`; `build_card.tcl` applies its named bounds (`jcl_cdc`, `jcl_tdi`,
   `jcl_dna_mcp`) but the only hard CDC gate across the loader's own crossings is
   `report_cdc`'s text scan, not a structural one.
3. **The six module-reference cell names** (`loader ctl eng fk33_seam_0 card
   bcgrant`) are read from `gen_jc_card.py`'s own text and the task-8 report, not
   from a synthesised netlist; a BD change that renames one silently breaks the
   netlist-input check with a clear `cell $cname not found` message, not silently.
