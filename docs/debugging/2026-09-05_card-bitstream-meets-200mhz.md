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
