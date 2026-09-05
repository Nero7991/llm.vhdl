# The card bitstream MEETS 200 MHz: WNS +0.001 ns, and the margin is 1 ps

**Date:** 2026-09-05 (built overnight 2026-09-04)
**Build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, `hw/fk33/pcieep_build.sh`
**Change:** `FK33_IMPL_STRATEGY=Performance_ExplorePostRoutePhysOpt`

## The question, verbatim

The endpoint bitstream built 2026-09-04 missed 200 MHz by 0.203 ns (192.2 MHz)
and `docs/debugging/2026-09-04_first-pcieep-bitstream.md` left open *"whether
200 MHz is required at all ... at 192.2 MHz the bitstream is usable as built,
and the entire timing problem disappears if the target moves."* Before moving
the target, exhaust the tooling.

## The answer

**It closes. The bitstream meets 200 MHz.**

```
FK33_TIMING    WNS=0.001 ns   WHS=0.009 ns
Post Physical Optimization Timing Summary | WNS=0.001 | TNS=0.000 | WHS=0.009 | THS=0.000
FK33_BITSTREAM bd_wrapper.bit (21,647,330 bytes)
FK33_IMPL_STRATEGY Performance_ExplorePostRoutePhysOpt
0 anchored errors
```

`TNS=0.000` and `THS=0.000`: **not one failing endpoint, setup or hold.**

**AND THE MARGIN IS ONE PICOSECOND.** `WNS = +0.001 ns` on a 5.000 ns period
is 0.02%. This is met, and it is met by the smallest amount the tool reports.
**Do not treat this as headroom.** A different seed, a tool version, or any
RTL change can put it back under, and the correct reading is "the target is
exactly reachable", not "the design is comfortable".

## What did it, and it is one step

The log shows the crossing:

```
Post Routing Timing Summary          WNS=-0.006
Physopt Current Timing Summary       WNS=-0.006
Physopt Current Timing Summary       WNS=-0.006
Physopt Current Timing Summary       WNS=+0.001   <- crosses zero
Post Physical Optimization Summary   WNS=+0.001
```

**Routing alone left it at -0.006. POST-ROUTE `phys_opt_design` closed it.**
`Performance_RefinePlacement`, the strategy this build used before, does NOT
include a post-route physical-optimisation step, so that lever was
structurally unavailable to it.

This was predicted from an independent measurement rather than found by
guessing: on the composed top the same day
(`2026-09-04_composed-top-routed.md`), directives moved a routed design
-0.402 -> -0.110 and post-route `phys_opt` was worth a further 0.051 ns. The
card's gap was 0.203 ns, inside that range.

## Progression

| build | strategy | WNS | fmax |
|---|---|---|---|
| 2026-09-04 | `Performance_RefinePlacement` | -0.203 | 192.2 MHz |
| **2026-09-05** | `Performance_ExplorePostRoutePhysOpt` | **+0.001** | **200.0 MHz** |

Bitstream 21,647,330 bytes against the previous 20,630,206: a different
placement and routing, not a different design.

## What this does NOT mean

- **It is not a correctness result.** `llama_top:4316` still refuses
  `B_SRC_REAL` past token 0. A bitstream that meets timing and computes the
  wrong token is a bitstream that meets timing.
- **Nothing has run on the card.** `pcieep.sh` and `save_bitstream.sh` were
  NOT run. This is a build-only result, per the hardware boundary.
- **It is one build.** No seed sweep. At +0.001 ns the run-to-run
  distribution certainly straddles zero, so a rebuild is NOT guaranteed to
  close.
- **The default is unchanged.** `FK33_IMPL_STRATEGY` defaults to
  `Performance_RefinePlacement`; this result requires the variable to be set.
  Whether to change the default is a judgement about reproducibility against
  4% of clock, and it is Oren's.

## Measured and REJECTED -- do not retry

- **Moving the 200 MHz target.** It was the leading option for two days and it
  is now unnecessary for THIS build: the tooling closes the gap. (The composed
  top is a separate question and still sits at -0.041.)
- **Hand-editing `hw/fk33/build_fk33_pcieep.tcl`.** It is GENERATED; line 2
  says so. An edit there was silently reverted by the next build, and a
  `--bd-only` run then reported SUCCESS while the change no longer existed.
  Edit `gen_pcieep.py`.
- **Validating an implementation-stage change with `--bd-only`.** It returns
  BEFORE implementation setup, so `FK33_IMPL_STRATEGY` never prints and the
  run says nothing about the strategy. It looks like a pass.

## Measurement traps hit

- **The build log echoes the build script's own source, so an unanchored grep
  reports events that never happened.** MEASURED here: a monitor matching
  `FK33_IMPL_STRATEGY` and `FK33_STRATEGY FAIL` fired BOTH, and both matched
  lines began with `#`. Anchored: 1 real strategy line, 0 failures.
  Unanchored: 4 matches, 3 of them echo. **This is the fourth instance of this
  trap in this project** and it was hit minutes after the rule was quoted.
- **A silently-accepted `set_property strategy` is indistinguishable from an
  applied one** without a readback. The build now prints
  `FK33_IMPL_STRATEGY <readback>` and errors if it disagrees, because the
  failure mode reads as "the strategy did not help" rather than "the strategy
  never ran" -- and costs a whole build to discover.
- **Both mistakes above were caught by a BLANK FIELD**, not an error: the
  strategy line printing nothing where it should have printed something.

## Open, not yet answered

- **1 ps of margin.** A seed sweep would establish the distribution; nothing
  here says this is reproducible.
- **Whether to make the strategy the default.** Costs build time, buys the
  clock. Not decided.
- **The composed top is still at -0.041 (198.4 MHz)** and has NOT been rebuilt
  with this strategy; only `phys_opt` directives were tried there.
- **Correctness on hardware, and hardware access.** Unchanged and outside what
  any build can settle.

---

## WHERE THE ARTIFACT ACTUALLY IS (added 2026-09-05, after nearly losing it)

**This document recorded the bitstream's SIZE and its TIMING and not its
LOCATION, and the only copy was in the session scratchpad under `/tmp`**,
which does not survive the session. A reader following this write-up would
have found every number in it reproducible and the artifact itself gone.

Preserved to, and MEASURED byte-identical by md5 (`201b6206...`):

```
hw/fk33/bit/fk33_pcieep_eng_epr_wns+0p001.bit          21,647,330 bytes
hw/fk33/bit/pcieep_eng_epr_2026-09-05/
    timing_summary_postroute_physopted.rpt
    route_status.rpt
    utilization_placed.rpt
```

**`hw/fk33/bit/` is gitignored** (`.gitignore:134`), which is deliberate --
bitstreams live on disk, not in git. **So this paragraph is the only tracked
record that the file exists**, and a `git clean -x` would remove it with no
warning and nothing to point at what was lost.

### The verification, re-read from the reports rather than from memory

Both figures below were re-derived from the copied reports, not carried
forward from the build log:

```
WNS(ns)  TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints   WHS(ns)
  0.001    0.000                      0               672531     0.009

All user specified timing constraints are met.

# of routable nets ..... : 286806
# of fully routed nets . : 286806
# of nets with routing errors : 0
```

So: **0 failing endpoints of 672,531, hold met at +0.009, every routable net
routed, 0 routing errors.** The 1 ps margin noted above is real and is the
whole margin; nothing here makes it reproducible.

### Measurement trap this nearly repeated

**A size recorded in a document is not a located artifact.** The size was the
only thing that made it findable at all -- it was recovered with
`find -size 21647330c` after `find hw -name '*.bit'` returned nothing newer
than 2026-08-29, because the newest bitstream in the repo tree predated this
build by a week. **Record the path at the moment the artifact is produced**,
and if the path is under `/tmp`, that is not a record.
