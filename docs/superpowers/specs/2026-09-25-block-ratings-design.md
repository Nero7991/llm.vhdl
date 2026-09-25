# Block ratings: rate every building block once per part, predict the card's clocks

2026-09-25. Status: **design approved section by section in conversation; spec awaiting
Oren's review.** No implementation yet.

## The request

Oren: "Let's design an architecture for easier scaling to both XCVU33P and 35P parts (and
maybe other future parts) so that we don't have to keep retesting. All of the building
blocks for the Qwen3.5 architecture should be independently tested to reach the higher
clocks we're targeting. To determine the highest clocks we can reach, we can look at how
complex the design is for that block, and what clock it should support technically and
with optimization effort."

Decisions taken in the brainstorm (Oren's answers):

| question | answer |
|---|---|
| which retest to stop paying for | **both**: full card builds per change, and re-closing per part |
| how the card uses per-block fmax | **a few clock tiers**, crossings only at tier boundaries |
| how far "future parts" reaches | **the UltraScale+ HBM family** (VU31P/33P/35P/37P/45P/47P/57P) |
| approach | **A: rated blocks + tier budget, re-rate only on change; C (depth model) inside as a checked predictor; B (locked floorplanned reuse) deferred** |

Assumption, not Oren's words: "retesting" means timing and area. Functional verification
(the GHDL oracles) is already part-independent and is not changed here.

## Why

- The part string is hardcoded in 78 hand-written `sim/ooc_*.tcl` harnesses, in
  `sim/elab_check.tcl` and in the build generators.
- Only 5 of those 78 run `route_design`, so most per-block fmax figures are synthesis
  estimates, which CLAUDE.md records are not timing results (C's mover: -4.008 ns quoted
  for a week, -1.438 implemented).
- A card build is about 7.5 hours alone on the workstation (builds 19, 20). Each design
  change, and each part, currently finds its clock by building the card.

## Goal and success criteria

1. Every rated block carries, per part, three numbers: **ceiling**, **structural**,
   **achieved** (section 3), each reproducible from a committed record.
2. A block is re-rated **only when its cache key changes**; a stale rating is red in the
   gate, never silently current.
3. Before any card build, the tier clocks are **predicted** from the ratings and a
   measured per-part composition derate `k`; after the first card build on a part,
   the card build is a check of that prediction.
4. Adding a part in the family is one device-table row plus a refresh, then ratings.

## 1. Device table, block manifest, rating shell

### Device table (`hw/targets/devices.json`)

One row per part. **Hand-written:** part string, speed grade, operating voltage, and the
board's pin and HBM-stack placement. **Read from Vivado, never typed:** every resource count
(`get_property` on `get_parts`: LUTs, FFs, BRAM, URAM, DSP, HBM stacks), by
`rate devices --refresh`.

**Operating voltage is a PART VARIANT, not an operating-condition command.** MEASURED and
recorded in `sim/ooc_micro_pnr.tcl:49`: at reduced VCCINT Vivado reloads the part as the
`-2LV` variant (`[Vivado 12-4441]`, `[Device 21-403] Loading part xcvu33p-fsvh2104-2LV-e`),
and that reload mid-flow is why `set_operating_conditions -voltage {VCCINT 0.72}` fails in a
place-and-route flow (and the most likely reason it crashed on routed card checkpoints on
2026-09-24). So a row's rating part is the variant that matches the voltage the card runs at:

| row | build part | rating part | runs at |
|---|---|---|---|
| `vu33p_fk33` | `xcvu33p-fsvh2104-2L-e` | `xcvu33p-fsvh2104-2LV-e` | 0.715 V (wiper 68) |
| `vu35p_jc` | `xcvu35p-fsvh2104-<grade>-e` | same, per candidate grade | unknown until the unit is characterised |

`-2LV` exists only for the `-2L` grade. A VU35P of another grade is rated at its own
nominal voltage. The Jungle Cat's grade is unknown (not electronically readable), so its
row is rated at each candidate grade and the right one is chosen once the part is
characterised.

A generated, genstamped `rtl/device_pkg.vhd` exposes only what RTL genuinely needs (HBM
stack and port count). Nothing else in RTL may name a part.

### Block manifest (`hw/targets/blocks.json`)

One row per rated block, from the entities `llama_top` and `fk33_engine` instantiate today:

| row | entities |
|---|---|
| `a_engine` | `matvec_int4_desc_axi` (with `axi_rd_port`, `matvec_int4`) |
| `b_gdn` | `gdn_block` (conv, emit chain, exp capture, recur pipe, scalar, silu, `l2norm_rs`) |
| `b_seq` | `gdn_job_seq`, `gdn_state_store` |
| `c_attn` | `attn_block` (emit, gate, kv_quant, mac_array, recip, rope, score_q12, softmax, twiddle, `rmsnorm_rs`) |
| `c_kv` | `attn_kv_axi` |
| `d_seq` | `seq_desc_fetch`, `seq_opdec`, `seq_vec_issue`, `seq_vec_res`, `seq_region_lock` |
| `vec_ops` | `rmsnorm_bf_mem`, `swiglu_mem`, `sampler_stream` |
| `glue` | `region_mem`, `bc_port_grant` |

Each row names: the top entity; its generics, **derived from `model_cfg_pkg` for a named
model** (9B, 27B) so a block is rated at the shape it is built at; its tier; and **every
lever explicitly**. A row that leaves a lever to its default is refused (build 19: a dropped
patch turned four levers on silently). Sub-units get their own rows when a parent's worst
path lands in them (e.g. `attn_score_q12`, `gdn_recur_pipe`, `gdn_emit_chain`), because that
is where optimization effort is spent.

### Rating shell

A generated wrapper registers every input and every output of the block, one flop each
side, so the block is timed register to register as it sits in the card rather than
against unconstrained out-of-context pins.

## 2. Rating flow, record, cache key

### Flow, per (block, part, model)

1. OOC synthesis of the shell on the row's **rating part**, then `opt_design`,
   `place_design`, `phys_opt_design`, **`route_design`**. Nothing before routing is a
   rating: placed and phys_opt WNS have inverted verdicts three times (CLAUDE.md).
2. Achieved fmax = 1 / (target period - routed WNS).
3. Results closer than the measured noise floor are marked so. The floor is 0.4-0.75 ns
   today and unmeasured for a single configuration; one draw per row by default, and a
   periodic repeat of one row measures it.

### Record (`hw/targets/ratings/<part>/<block>.json`, committed)

Routed WNS/WHS at the target, failing endpoints, worst path start/end and its logic levels,
the logic-level distribution (`report_design_analysis`), resources from
`report_utilization` cross-checked by a validated census, cgroup `memory.peak` beside
`memory.swap.current`, wall time, directives, tool version, lane.

### Cache key

sha256 over: the content of **every source file Vivado actually read** (the tool's own
used-file list after synthesis, not a grep, so a package such as `util_pkg` cannot be
missed); generics; lever values; part, grade and voltage variant; target clock; Vivado
version; the harness script's own hash.

- **A block is re-rated only when its key changes.**
- Gate row **`sim:ratestale`**: red when a committed rating's key no longer matches the
  tree. A stale rating counts as no rating.

### Lanes

Each rating is one Vivado. Ratings queue on the two lanes (workstation, BC-250), each job
chained on the sentinel of the one ahead with presence by `/proc/PID/exe` as the safety net.
A row's recorded peak decides its lane against the BC-250's `MemoryHigh=11G`; rows over it
(e.g. `c_attn`, 10.85 GB MEASURED) take the workstation.

## 3. Ceiling, structural, achieved

1. **Ceiling (the silicon's limit):** from `report_pulse_width` on the routed block, the
   minimum period of each clocked primitive (BRAM, URAM, DSP, global buffers) at that part,
   grade and voltage; the ceiling is the lowest. It is configuration-sensitive: a DSP
   without its pipeline registers, or a BRAM without its output register, reports a lower
   limit, so the ceiling names the cheapest lever.
2. **Structural (what the current depth allows):** a **per-part calibration table**, not a
   fit to the blocks. A micro-benchmark (built on `sim/ooc_micro_pnr.tcl`, which already
   routes and takes the part as an argument) routes, per part and voltage variant, chains of
   1-12 LUT levels, carry chains, DSP cascades and BRAM-to-logic paths in the shell. A
   block's structural fmax is that table at its worst post-synthesis path. Its error against
   achieved is tracked per block; it is quoted only where it has held.
3. **Achieved:** the routed fmax of section 2.

| pattern | meaning | lever |
|---|---|---|
| achieved ~ structural, well under ceiling | depth-limited | pipeline the named worst paths; the table predicts the gain per level removed |
| achieved well under structural, path mostly net delay | placement, fanout or congestion | replicate fanout, cut area, floorplan |
| structural ~ ceiling | at the silicon limit | only primitive configuration helps |

**Depth pre-gate:** the table gives, per tier clock, a maximum logic-level count. The flow
checks each block's post-synthesis depth against its tier's limit before routing (minutes).
A block that fails is neither routed nor built.

## 4. Tiers, composition, the card build

### Tiers

- **Stream:** A's engine and read ports (the split behind `FK33_ENG_SPLIT_CLK`, `clk_out4`).
- **Core:** B, C, D, vector ops, regions, port grant.
- **HBM/XDMA:** 250 MHz, fixed by the IP.

**Boundary rule:** a tier boundary may sit only on an interface that is already a FIFO or
stream (today A's descriptor and result path, and `axi_rd_port`'s async FIFOs). Moving a
block between tiers is a manifest change plus that check, never a new crossing in a loop.

### Predicted tier clock

`f_tier = k_part x min(achieved fmax over the tier's blocks)`.

- `k_part` is MEASURED: card routed tier fmax / the tier's slowest block rating, recorded
  with the build's CLB utilization. VU33P at 99.8% CLB and a VU35P near 50% will not share a
  `k`.
- **The first card build on a new part is the calibration of `k`.** After it, card builds
  are checks. For the VU33P, builds 18, 20 and 21 are the calibration points.
- `k` keeps its spread; the prediction uses the worst observed.

### A card build becomes

1. **Pre-flight (cheap):** `sim:ratestale` green; every block passed its depth pre-gate; the
   lever table explicit; the predicted tier clocks written into the launch environment
   (`FK33_ENG_CORE_MHZ`, `FK33_ENG_FAST_MHZ`) from the ratings, not typed.
2. **Area:** ratings are **not summed** into a fit claim (CLAUDE.md: parts do not add across
   synthesis contexts). The composed synthesis is the area check; ratings only flag an obvious
   overrun early.
3. **A miss is data:** a worst path inside a block means its rating was optimistic in
   context (record a per-block context derate); a worst path between blocks becomes a new
   `glue` row; `k` is updated either way.

### Levers

Each lever in the manifest carries **rated** (timing) and **silicon-proven** (the
position-32 instrument, 60 runs, and the N=500 pair and single tests). A card build may turn
on only silicon-proven levers, except the build that proves one (as build 21 does for
`SWEEP_PIPE`/`SCORE_EARLY`). Today all four levers are unproven; `build12_levers_off.patch`
is their current encoding and is replaced by the manifest.

## 5. Testing the flow, migration, cost, non-promises

### Teeth, before any rating is quoted

- **Cache key:** editing a file the block reads changes the key; editing one it does not
  read does not (the control). A comment edit changes it, deliberately.
- **Staleness gate:** edit a rated block, `sim:ratestale` red; revert, green.
- **Voltage variant:** the same block on `-2L` and `-2LV` must differ (2026-08-24 measured
  a -22.9% mean derate on one design).
- **Depth pre-gate:** a deliberate 20-level combinational mutant fails; the same function
  pipelined passes and rates higher.
- **Cross-lane:** one row on both lanes gives identical routed results.
- **Anchors:** `a_engine` on the VU33P must reach at least 200 MHz at 0.85 V (the engine-only
  build closed there); `c_kv` must land near its implemented 155.3 MHz. A rating that
  contradicts an anchor stops the rollout until explained.

### Migration

No existing harness is deleted. Where one of the 5 routed harnesses covers a block on the
same tree, the new rating must agree with it. An old harness retires only when its row is
rated and agrees.

### Order of work

1. Device table and `rate devices --refresh`.
2. Shell generator and `a_engine` on the VU33P, checked against the 200 MHz anchor.
3. The `-2LV` rating part, with its teeth check.
4. The per-part depth calibration table.
5. Cache key and `sim:ratestale`.
6. The remaining rows.
7. VU35P rows at each candidate grade.
8. `k` from VU33P builds 18, 20, 21.

### Cost (ESTIMATE)

About 20 rows at 30-90 minutes each per part: 20-60 Vivado hours for the first pass, 1-2
days on two lanes. After that only rows whose keys changed are re-rated.

### What this does not promise

- That a card closes: `k` is measured, and the first build on each part is still required.
- Anything functional: build 19's hang was not a timing failure and no rating would have
  found it; the silicon-proven lever state covers that.
- Composed area.
- Differences below the routed noise floor.

### Deferred

**Approach B, locked floorplanned block reuse** (implement each block into a pblock, lock
placement and routing, reuse in the card): the strongest guarantee, infeasible at the
VU33P's 99.8% CLB, possible on a VU35P. Revisit after the VU35P's first card build.
