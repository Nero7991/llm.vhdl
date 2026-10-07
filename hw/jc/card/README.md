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

## Task 10: OOC route of the 27B composition at 200 MHz

Written and dry-run tested only: no Vivado has run this either. The controller
runs it next (plan Task 10, step 2).

| File | What |
|---|---|
| `gen_ooc27_top.py` | Emits `jc_ooc27_top.vhd`: a co-residency + real-dataflow OOC top carrying `fk33_engine` + `fk33_seam` + `fk33_card` (the 27B wrapper) together, in the SAME placement/routing context |
| `ooc_card_200.tcl` | OOC `synth_design -mode out_of_context` + `opt`/`place`/`phys_opt`/`route_design` + reports on `jc_ooc27_top`, 200 MHz (`clk`, 5.000 ns), `xcvu35p-fsvh2104-2L-e` |
| `run_ooc27.sh` | Orchestration: location/root/Vivado-presence refusals, tracked-tree copy, the levers patch, the 27B `fk33_card.vhd` regeneration (not the BD), `gen_ooc27_top.py`, the capped Vivado run, report harvest, the nonce-gated sentinel |
| `test_ooc27.py` | Dry-run assertions on `run_ooc27.sh`, static assertions on `ooc_card_200.tcl` (route_design present, the `-2L` part, the 5.000 ns clock, the levers-patched tree, anchored sentinels, no source-list drift against `build_card.tcl`) |
| `test_gen_ooc27_top.py` | Runs `gen_ooc27_top.py` for real against this repo's own committed (9B) RTL as a smoke test, and two mutation tests proving its width/direction/double-wire checks actually abort |

**Why `jc_ooc27_top`, not `fk33_card` alone or `jc_card_top`'s BD wrapper.**
`docs/debugging/2026-09-30_27b-fits-vu35p-ooc-timing-artifact.md` measured
`fk33_card` ALONE (no engine, no block design, no floorplan) at 69.9 MHz OOC on
this exact part -- a standalone-OOC ARTIFACT (the identical path on the 9B
control gives 69.0 MHz OOC while the shipped 9B build runs that compute at
>=120 MHz in-context), not a real limiter. Re-running `fk33_card` alone here
would reproduce that known artifact under a new name. `jc_card_top`'s own BD
wrapper needs the full block design (HBM IP, clk_wiz, PCIe-less BD) and no
mechanism in this tree excludes the HBM IP from an OOC run of it.
`gen_ooc27_top.py` instead restores two of that note's three missing-context
items -- the engine, and the real dataflow between it and the card -- using
only the entities' own committed RTL: every wired net (the 41-pair "host seam,
`fk33_seam` <-> `card`" list and the 12-pair "A seam, `card` <-> `eng`" list) is
transcribed verbatim from `hw/jc/card/jc_card_bd.tcl`'s own `connect_bd_net`
calls and checked, pair by pair, against the entities' own parsed port widths
and directions before being emitted -- a mismatch aborts the generator
(`GENOOC27 ABORT`) rather than producing a file that fails first in Vivado,
hours in. The one exception is `card/a` onto `eng/s_axi`'s AW/W/B channels,
which the real BD arbitrates through a 2:1 smartconnect against the host's own
master; with no host here, this generator connects them directly (documented,
checked the same way) and ties off `eng/s_axi`'s AR/R channel, which only the
host ever drove. Every other port of all three instances -- the HBM AXI
masters, both host AXI4-Lite control slaves, `card`'s `bst_*`/`kv_*_*` ports
(`bcgrant`, the real BD's grant arbiter, is outside this task's three-instance
scope) -- is exported to the top level, uniquely prefixed, so nothing can be
optimised away as dead logic (the same reason `hw/fk33/gen_compose4_top.py`
exports rather than stimulates its own nine co-resident instances).

**What this does and does not establish.** A routed WNS from `jc_ooc27_top`
restores the engine and the real card<->engine dataflow the artifact run
lacked, with real area and real nets. It still has no floorplan, so a result
from it is OOC evidence towards the open "does the real composed design meet
200 MHz in-context" question (`docs/debugging/2026-09-30_...`'s own "Open, not
yet answered"), not an in-context answer to it -- that still needs the actual
Jungle Cat block design.

**The levers.** `build12_levers_off.patch` edits `FAST_POP`'s generic DEFAULT
in `fk33_engine.vhd` and the `NWIDE`/`SWEEP_PIPE`/`SCORE_EARLY` generic MAP
VALUES directly in `fk33_llama_top.vhd`'s/`llama_top.vhd`'s own text, so
applying it to the prepared tree (`run_ooc27.sh` step 2) is the entire lever
story for this flat, non-BD OOC flow -- `gen_ooc27_top.py` sets no lever
generic itself. `CB_STYLE` (lever C) is a true module-boundary generic on
`fk33_engine`, separate from the levers-off patch, and is set explicitly to
`"distributed"` to match `jc_card_bd.tcl`'s own `CONFIG.CB_STYLE` for build
27B-1, alongside `USE_XEXP_PORT => true` (`jc_card_bd.tcl:299`, fix round 1,
I1) -- `test_eng_generics_match_the_bd_exactly`/`test_seam_generics_match_
the_bd_exactly` diff every `CONFIG.*` the BD sets on `eng`/`fk33_seam_0`
against this generator's own dicts.

Fix round 1, I6 made the levers check two-layered: a FATAL grep of the
patched sources (`run_ooc27.sh`, before Vivado runs at all) for `FAST_POP`'s
default, `NWIDE`/`SWEEP_PIPE`/`SCORE_EARLY`'s values, and `PIPE`/`WIDE`/
`MAXOUT 8`'s own (unpatched) values -- this is the load-bearing guarantee.
On top of that, `run_ooc27.sh` also greps its own Vivado log for the
`Parameter <NAME> bound to:` trace line (via `jccard_levers.tcl`'s already-
tested parser) and prints `JCOOC27_LEVER` lines; this second opinion IS
fatal on an "on" or "mixed" verdict (the trace line is present and says the
lever is bound wrong -- not ambiguous), but stays non-fatal on "missing":
whether that trace line reaches a plain (non-project) `synth_design`'s
`-log` file at all is UNVERIFIED (`build_card.tcl`'s own finding was that a
PROJECT-MODE run writes it only to `<top>.vds`, never `runme.log`), so
"missing" is as likely to mean "this log is not where the trace lands" as
"the patch did not apply" -- and the pre-Vivado source grep already covers
the real failure mode either way.

**Memory.** Fix round 1, I3: the original 4-8 GB ESTIMATE (from "2.58 GiB
for the 9B `fk33_card` OOC on the VU35P") was extrapolated from the wrong
reference point -- a DIFFERENT, smaller OOC (`fk33_card` alone, no engine).
Vivado's own log from the real reference runs reports a peak of 11780 MB
for the 27B `fk33_card` OOC alone and 9008 MB for `fk33_engine` OOC alone
(`ooc27_vu35/{fk33_card,fk33_engine}/build.log`); this composition places
both together, so ESTIMATE 16-20 GB. `run_ooc27.sh` defaults `MemoryHigh` to
`22G` with a FIXED 4 GiB swap guard (not scaled to the cap), refuses if
`MemAvailable` is below cap+2G or another Vivado is already running, and
prints `MemAvailable`/`SwapFree` before dispatch either way.

**Fix round 1 (2026-10-07), summary.** CRITICAL C1: `gen_ooc27_top.py` used
to export every unwired port, including `card/obs_wsum` -- the exact debug
hash (`fk33_llama_top.vhd:8243`, a 60-level multiply-by-31-add) the 2026-09-
30 artifact note's "70 MHz" number traced to, and which the real build never
pays for (`jc_card_bd.tcl` never connects it; build 20's own log: `port
'obs_wsum' of module 'bd_card_0' is unconnected`). A port the BD never
connects to anything is now tied off (`open` for an output, a quiescent
constant for an input) instead of exported --
`bd_connected_ports()`, scanning `jc_card_bd.tcl`'s own `connect_bd_net`/
`connect_bd_intf_net` calls, decides which. See
`docs/debugging/2026-09-30_27b-fits-vu35p-ooc-timing-artifact.md`'s
CORRECTION section and
`.superpowers/sdd/2026-10-07-jc-engine-composition/task-10-fix-round-1-
report.md` for the full account, including I1-I6 and M1-M3.
