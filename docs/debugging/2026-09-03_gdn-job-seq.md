# The B job sequencer, and the two-edge read that is not one edge

**Date:** 2026-09-03
**Build:** `xcvu33p-fsvh2104-2L-e`, GHDL 1.0.0 mcode, Vivado 2023.2
**Files:** `rtl/gdn_job_seq.vhd`, `sim/tb_gdn_job_seq.vhd`, `sim/ooc_gdn_job_seq.tcl`

## The question, verbatim

From the session's standing blocker list: *"(2) B job sequencer doesn't exist
('nothing feeds the tap write port from A's qkv stream and nothing pulses
tok_adv')."*

The three-region resident state tier for subsystem B landed on 2026-09-02
(`gdn_state_store`, `gdn_state_axi`, `gdn_exp_mem`, `gdn_conv_tap_mem`). Every
unit was verified and the store composed at 4,028 CLB LUT / 32 URAM288 / 12
RAMB36. Nothing drove it. This file is the driver for ONE layer of ONE token.

## The answer

`rtl/gdn_job_seq.vhd`, 39 CLB LUT and 146 FF at the shipping shape, fmax
916 MHz. It sequences **load -> run `gdn_block` -> refill the conv taps ->
save**, and it does **not** pulse `tok_adv`.

Two things in that sentence are the whole content of the file, and both were
wrong in the first version:

1. **The refill comes AFTER the unit, not before or during.** The taps hold the
   previous `KCONV-1` columns while `gdn_block` reads them. Refilling earlier
   feeds the unit this token's own column; refilling during is a same-address
   collision in a simple-dual-port BRAM. Neither raises anything.
2. **The qkv read takes TWO edges, not one.** The module registers the address,
   so the source does not see it until the next cycle, and a registered source
   presents data a cycle after that. A one-stage pipeline pairs every write
   with its neighbour's data.

`tok_adv` is deliberately absent from this module's ports. It advances the tap
rotation and belongs to whoever knows where a TOKEN ends; this module is one
LAYER. Pulsing it here would advance the rotation `LAYERS` times per token, and
every layer but the last would then read its taps in the wrong order.

## The procedure

Written as a self-contained module against MODELS of `gdn_state_store` and
`gdn_block`, not against the real ones. That is the point: the property being
checked is a SCHEDULE, and a model lets the bench vary the latencies the
schedule must not depend on. The real units have their own benches.

The bench models three things and observes four:

| modelled | why |
|---|---|
| the store, with `busy` rising a cycle after start and `done` a one-cycle pulse with busy ALREADY LOW | reproduces `gdn_state_store.vhd:334` exactly, including its `guard` process that FAILS on a `cvw_en` inside the mover's window |
| `gdn_block`, with a settable rise latency and run length | `busy` does not rise on the start edge; a waiter that does not arm on the rise completes instantly |
| the qkv source, as a registered read | makes the two-edge contract observable |

Observed: the flat index of every conv write in order, its data, whether it
landed inside the modelled busy window, and four cycle stamps (load done,
`b_busy` fall, first write, last write).

`qval(seg, grp)` returns a DISTINCT value per group, so a walk shifted by one
group, or one visiting the segments in the wrong order, cannot reproduce it.

## The evidence

Final run, unmutated:

```
sim/tb_gdn_job_seq.vhd:479:@10175ns:(report note): TB_GDN_JOB_SEQ checks=79 fail=0 mut=0
sim/tb_gdn_job_seq.vhd:483:@10175ns:(report note): TB_GDN_JOB_SEQ PASS
```

Gate, full both-suite run at `--jobs 1`:

```
PASS       sim:tb_gdn_job_seq                    64s  ... TB_GDN_JOB_SEQ PASS
 OVERALL     PASS 122   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 REGRESSION: PASS
```

OOC synthesis, shipping shape (`VAL_HEADS=32 DIM=128 KEY_HEADS=16 KCONV=4
CONV_LANES=4 LAYERS=24`), 5.0 ns:

```
| CLB LUTs*               |   39 |     0 |          0 |    439680 | <0.01 |
|   LUT as Logic          |   39 |     0 |          0 |    439680 | <0.01 |
|   LUT as Memory         |    0 |     0 |          0 |    205440 |  0.00 |
| CLB Registers           |  146 |     0 |          0 |    879360 |  0.02 |
RESULT gdn_job_seq lut=58 ff=146 ram=0 carry=0 wns=3.909 fmax=916.6
```

`NG_K` and `2*NG_K` are elaboration constants, so the segment split costs two
compares and two subtracts and does not scale with `QKVN`. Note `lut=58` is the
PRIMITIVE census and `39` is the SITE number from `report_utilization`; the
site number is the budget one.

Refill cost: `QKVN/CONV_LANES` = 2,048 cycles at the shipping shape, pipelined
one group per cycle, against `gdn_block`'s ~16,384-cycle state sweep. About
12%.

## Mutation testing, with the attribution control

Seven DUT mutants, each a patched copy of the RTL in scratch. Every one was run
against the full bench AND against a control bench identical except that the
three phase-order checks are deleted. The control is what says which check
earned the kill.

| mutant | what it breaks | full bench | control |
|---|---|---|---|
| D1 | pairs the write with `di1`, the address on the wires, instead of `di2` | fail=14 | fail=14 |
| **D2** | **refills the taps BEFORE `gdn_block` runs** | **fail=9** | **fail=0** |
| D3 | drives `ss_layer` from the live `layer` port, not the latch | fail=1 | fail=1 |
| D4 | skips `S_ARM`, so it never waits for `b_busy` to rise | fail=13 | fail=5 |
| D5 | drops `dv2` from the walk's exit condition | **fail=0** | fail=0 |
| D6 | ignores `ss_err` on both load and save | fail=2 | fail=2 |
| D7 | swaps the q and v segment numbering in the split | fail=5 | fail=5 |

Three model mutants, applied to the bench's environment rather than the DUT:

| mutant | what it models | result |
|---|---|---|
| M1 | the store's `busy` lingers one cycle past `done` | **fail=0, does not bite** |
| M2 | `b_busy` never rises (a unit that refuses the job) | fail=39, killed |
| M3 | `b_busy` rises on the same edge as `b_start` (latency 0) | fail=0, correctly passes |

### What the control changed

**D2 is the row the control exists for.** A sequencer that refills before the
unit runs satisfies every other ordering check in the bench: it still writes
every group exactly once, in order, with correct data, after the load and
before the save. It fails only `t_w_first > t_bfall`. Without the control the
table would have shown "D2 killed, 9 fails" and credited nothing in particular.
With it, the phase-order check has a **unique** kill.

D4 is the softer version of the same story: 13 with, 5 without. Both benches
catch it, the new check adds 8.

### The two rows that did not bite, under their own names

**D5 survives, and it is a PROVABLY EQUIVALENT MUTANT, not a gap.** The walk's
exit condition is `wi = NG and dv1 = '0' and dv2 = '0'`; D5 drops the `dv2`
term. It changes nothing because `cvw_en` is assigned in the same clocked
process and the same cycle as the state transition, so the final write is
registered on the edge the FSM leaves on. The mutation changes WHEN the FSM
leaves, not WHAT it wrote. The `dv2` term is kept because it is
self-documenting, not because it is load-bearing.

**M1 does not bite, and the reason is structural.** M1 extends the store's busy
window one cycle past `done`, aimed at a sequencer that starts writing taps in
the done cycle. This sequencer cannot: it runs `gdn_block` between the load and
the refill, so the first write is hundreds of cycles after the load's `done`.
M1 measures the bench's resolution floor against a defect this ORDERING makes
unreachable. It would bite a design that refilled straight after the load,
which is exactly what D2 is.

## Measured and REJECTED -- do not retry

- **A one-stage refill pipeline.** MEASURED: 31 of 32 data checks failed with
  the write count and the walk order both green. The read is two edges. An
  ASYNCHRONOUS qkv source would need one stage, so this is not a free
  substitution if the source is ever changed.
- **Counting bench checks in a SIGNAL.** MEASURED: the first green run reported
  `checks=13` for a body containing 60. A signal assigned twice in one delta
  keeps the last value, so consecutive `chk` calls with no `wait` between them
  collapse to one increment. Counted in process VARIABLES now. A check that
  does not count is indistinguishable from a check that did not run.
- **`get_cells -hier -filter {PRIMITIVE_GROUP == LUT}` as the area census.**
  MEASURED: reported `lut=0 ff=0` on a design with a 1.09 ns critical path.
  A filter that matches nothing reports as a design that contains nothing. The
  tell is zero cells with a real timing path. `report_utilization` is
  authoritative; the census is the cross-check.
- **Naming the bench's mutation generic `MUT`.** VHDL identifiers are
  CASE-INSENSITIVE, so it collided with the signal `mut` and the entity would
  not analyse. Renamed `MUTSEL`. Same trap as the `for t` inside `for T` that
  cost the conv tap bench an afternoon on 2026-09-02.

## Measurement traps hit

- **Two processes driving one unresolved signal is an elaboration error, not a
  warning.** The bench's first version cleared its observation counters from
  `main` while the observer also drove them. Fixed by routing the clear through
  a `clr` request that only the observer acts on. Worth stating because the
  error text (`several sources for unresolved signal`) names the signal and not
  the second driver.
- **The gate refused to let me raise its floor, correctly.** The run showing
  `PASS 122` also printed `DO NOT raise BASELINE_PASS from this run`, naming
  `sim:tb_gdn_job_seq` among 23 rows a clean checkout does not get. The floor
  is a clean-checkout number and this tree is not one.

## The port contract, checked mechanically rather than by eye

The bench proves the SCHEDULE against models. It says nothing about whether the
module can actually be connected to the real `gdn_state_store` and `gdn_block`,
which have 59 and 65 ports respectively -- too many to hand-wire a probe for
quickly, and reading two port lists side by side is exactly the check that
looks done and is not.

So the entity declarations were parsed and the eleven connecting ports compared
programmatically: subtype string identical, direction opposite.

```
job_seq port     dir    type                                         peer
ss_load_start    out    std_logic                                    load_start     OK
ss_save_start    out    std_logic                                    save_start     OK
ss_layer         out    integer range 0 to LAYERS-1                  layer          OK
ss_done          in     std_logic                                    done           OK
ss_err           in     std_logic                                    err            OK
cvw_en           out    std_logic                                    cvw_en         OK
cvw_seg          out    integer range 0 to 2                         cvw_seg        OK
cvw_grp          out    natural range 0 to (VAL_HEADS*DIM)/CONV_LANES-1  cvw_grp    OK
cvw_data         out    std_logic_vector(CONV_LANES*16-1 downto 0)   cvw_data       OK
b_start          out    std_logic                                    start          OK
b_busy           in     std_logic                                    busy           OK
MISMATCHES: 0
```

**WHAT THIS DOES NOT ESTABLISH, and it matters.** The subtypes are written in
terms of generics -- `LAYERS`, `VAL_HEADS`, `DIM`, `CONV_LANES` -- and they
match only because both entities spell those generics the same way. **If the
two are instantiated with different generic VALUES the strings still match and
the design is still wrong**, silently, because a `natural range 0 to N-1` on
each side simply resolves to two different ranges. This check compares
declarations, not elaborated instances. An actual structural elaboration of the
three together is the thing that would close it, and it has not been done.

## Open, not yet answered

- **Nothing instantiates this module.** It is verified against models; wiring it
  into `llama_top` alongside the real `gdn_state_store` and `gdn_block` is
  separate work and has not been done.
- **The qkv source does not exist yet.** The port contract is stated and
  checked, but what actually drives `q_data` from A's output is unbuilt.
- **`tok_adv` still has no owner.** Deliberately not this module's; no module
  currently pulses it.
- **The refill's 12% cycle cost is MEASURED as a ratio of two figures, not as a
  wall-clock.** `gdn_block`'s ~16,384-cycle sweep is a shape calculation, not a
  simulated number for this configuration.
