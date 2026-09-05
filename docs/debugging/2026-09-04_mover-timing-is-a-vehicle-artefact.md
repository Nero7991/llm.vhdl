# The movers' timing numbers describe three DIFFERENTLY CONFIGURED designs

**Date:** 2026-09-04
**Build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, synthesis only (no P&R)
**Files:** `sim/ooc_mover_paths.tcl` (new), `rtl/ooc_gdnadapt_top.vhd`,
`rtl/ooc_cattnadapt_top.vhd`, `hw/fk33/gen_compose4_top.py`, `rtl/llama_top.vhd`

## The question, verbatim

From the standing blocker list, quoted in every summary this session:
*"B's mover at 111 MHz and C's at 151.3 MHz against a 200 MHz target, with
neither critical path attributed."* Attribute them.

## The answer

**They are attributed, and the attribution invalidates the comparison that
made them a blocker.** The three vehicles that have ever measured B and C
configure them DIFFERENTLY, and numbers from one have been quoted for the
others.

| generic | `llama_top` (and the extracted movers) | `compose4_top` |
|---|---|---|
| B `RECUR_LANES` | **4** | **32** (instantiated with `{}`, so `gdn_block`'s own default) |
| C `KV_BLOCK` | **4** | **32** |
| C `N_ROT` | **8** | **64** |
| C `POS_W` | **3** (`clog2(C_MAXPOS+1)`, `C_MAXPOS=4`) | **16** |

Everything else matches: B's CONV/SLOTS/L2/SILU/RMS lanes are 4/16/4/8/4 in
both, and the SHAPE generics agree everywhere (13 of 13, see
`2026-09-04_composed-top-9b-shape.md`). **The divergence is entirely in
generics that are NOT the model shape**, which is exactly why the shape
checker added the same day does not catch it: it checks
`HEAD_DIM/N_QH/N_KVH/LAYERS` and the GDN head counts, not lane counts or
KV blocking.

`NBR = DIM / RECUR_LANES` is **32** in the shipping configuration and **4** in
the composed one, and that term sits directly in the state address
arithmetic. Likewise `N_BLK = HEAD_DIM / KV_BLOCK` is 64 against 8.

## The measurements

All at 200 MHz (5.000 ns), synthesis, out of context.

| vehicle | configuration | WNS | failing endpoints |
|---|---|---|---|
| `compose4_top` `--wire` (DCP census) | composed defaults | **+0.346** | **0** of a 20,000 cap |
| `gdn_block` ALONE (`ooc_gdn_block.tcl`) | `RECUR_LANES=4`, matched to the mover | **+0.483** | -- |
| `ooc_gdnadapt` | `RECUR_LANES=4`, `MAXROWS_OVR=64` | **-4.008** | **>= 5,000 (CAP HIT)** |
| `ooc_cattnadapt_top` | `KV_BLOCK=4`, `N_ROT=8`, `POS_W=3` | **-1.611** | **256** |
| `ooc_cattnadapt_top` | card generics | **DOES NOT SYNTHESISE** | -- |

### C is fully attributed, and it is ONE array

All **256 of 256** failing endpoints are `gcr.u_attn/vref_r_reg[i][j]`
(32 x 8 = 256, the whole array and nothing else). Worst path:

```
Slack (VIOLATED) :        -1.611ns
  Source:                 gcr.u_attn/vhdr_reg[0]/C
  Destination:            gcr.u_attn/vref_r_reg[10][6]/D
  Data Path Delay:        6.593ns (logic 2.361ns 35.8%, route 4.232ns 64.2%)
  Logic Levels:           23  (CARRY8=7 LUT2=1 LUT3=3 LUT4=2 LUT5=4 LUT6=6)
```

**Both ends are inside `u_attn`.** The mover glue owns NO failing endpoint. So
"C's MOVER misses timing" is wrong as stated: the block it carries does, at
these generics.

### B is attributed to the block too, but the census was TRUNCATED

`gb_real.u_gdn` holds 858 endpoints at the worst slack `-4.008`. The many
`gb_real.stmem_p.stmem_reg_bram_*` buckets hold 7 endpoints each at `-0.217`,
i.e. marginal. **The run hit the 5,000-path cap, so this tally is the worst
5,000 and NOT the complete population.** The 858 figure is a lower bound and
the bucket ranking below the top one is not trustworthy. Re-run with a higher
cap before quoting any number here except `u_gdn`'s worst slack.

### The C extraction CANNOT be run at the card's configuration

```
ERROR: [Synth 8-421] mismatched array sizes in rhs and lhs of assignment
  [rtl/ooc_cattnadapt_top.vhd:443]  and :442
```

Those lines are the behavioural KV cache, `kvhdr` and `kvmem`, sized
`C_LAY*2*C_NKVH*C_MAXPOS[*C_NBLK]`. The file's own comment says they cost
**29.8 MB of elaboration per cache position**, which is why `C_MAXPOS`
defaults to 4. **So C's `-1.611` was measured on a four-position context and
that vehicle can never measure the card**, with or without this fix. The
`C_KV_AXI=true` arm exists to replace that cache and does not synthesise
either (`recbuf_reg`).

## What this does and does not license

**DOES:** the claim "B's mover runs at 111 MHz and C's at 151.3 MHz, therefore
the card misses 200 MHz" is WITHDRAWN. Those numbers are from configurations
the composed top does not use, and in C's case from one nothing can use.

**DOES NOT:** the composed top's `+0.346` does NOT establish that the SHIPPING
configuration meets timing, because `compose4_top` configures `b_gdn` with
`RECUR_LANES=32` while `llama_top` uses 4. It is a green number for a design
that is 8x more parallel in the recurrence than the one `llama_top` describes.
**Nothing measured today runs the shipping B configuration inside the composed
top.**

**ALSO DOES NOT:** say anything about correctness. `llama_top:4316` still
refuses `B_SRC_REAL` past token 0, and none of this is a token check.

**AND IT IS SYNTHESIS, NOT ROUTED.** ROUTE3 is the routed comparison. A
synthesis WNS of +0.346 is not a routed +0.346.

## Measured and REJECTED -- do not retry

- **"gdn_block alone passes, so the mover's glue is the problem."** REJECTED.
  `ooc_gdn_block.tcl` IS configuration-matched to the mover (same lanes, same
  shape), and the census puts 858 of the worst endpoints inside `u_gdn`, the
  block instance. Alone it is +0.483, inside the mover -4.008, at the same
  generics. That is a genuine CONTEXT effect for B, and it is the one place
  today where context rather than configuration is the explanation.
- **"attn_block fails extracted and passes composed, therefore context."**
  REJECTED, and this was nearly written up. The two instances are DIFFERENT
  DESIGNS: `KV_BLOCK` 4 against 32, `N_ROT` 8 against 64, `POS_W` 3 against
  16. Context was not tested because configuration was never held constant.
- **Quoting `report_timing_summary`'s WNS as an attribution.** It is one
  number and names nothing. Both movers had carried theirs for days.

## Measurement traps hit

- **`get_timing_paths -max_paths N` silently truncates.** B returned exactly
  5,000 against a 5,000 cap, which is the tell. A census that hits its cap is
  a ranking of the worst N, not a population, and summing or ranking its
  buckets is wrong. C's 256 against the same cap is a real total.
- **`-nworst 1` is load-bearing.** Without it an endpoint reachable ten ways
  appears ten times and reads as ten problems.
- **The route share is not evidence pre-placement.** 64.2% of C's worst path
  is ESTIMATED route in an OOC synthesis with no placement. Only the 23 logic
  levels and the 7-deep CARRY8 are solid.
- **A generic left at its default is a silent choice.** `compose4_top` passes
  `b_gdn` an empty generic dict, which reads as "unconfigured" and IS
  "`RECUR_LANES=32`". The divergence from `llama_top`'s 4 is invisible at the
  call site.

## Open, not yet answered

- **Which configuration is the card's?** For B, `llama_top` says 4 and the
  composed top says 32, and nothing states which is intended. For C,
  `llama_top`'s `C_MAXPOS=4` is explicitly a simulation model size, and the
  AXI arm needs `KV_BLOCK >= 16`, so `compose4`'s 32 may be the more realistic
  one. **This is a design decision, not a measurement.**
- **B's composed timing at `RECUR_LANES=4` has never been measured.** That is
  the run that would actually answer whether the shipping B configuration
  meets 200 MHz.
- **B's census needs re-running with a cap above 5,000.**
- **Neither `stmem`'s `-0.217` bucket nor the 858 in `u_gdn` is attributed to
  a named array** the way C's `vref_r` is. Depth-2 output for B was not
  inspected.
- Whether `recbuf` is fixable the way `stmem` was.

---

## FOLLOW-UP, same day: the shipping B configuration was MEASURED, and it passes

The "open" item above -- *"B's composed timing at `RECUR_LANES=4` has never
been measured"* -- is now closed.

**First attempt FAILED, and the failure is a stronger finding than the run.**
Patching only the instance generic gave:

```
ERROR: [Synth 8-549] port width mismatch for port 'st_rdata':
       port width = 64, actual width = 512
ERROR: [Synth 8-549] port width mismatch for port 'st_wdata':
       port width = 64, actual width = 512
	Parameter RECUR_LANES bound to: 4
```

`st_rdata`/`st_wdata` are `RECUR_LANES*16` wide. **So `RECUR_LANES=32` is baked
into `compose4_top`'s generated ENTITY, not merely left as a default**: the
card top exports a 512-bit B state interface where `llama_top`'s is 64-bit.
Anything designed against `b_gdn_st_rdata` -- the HBM state mover above all --
has been sized against 8x the shipping width. This is not "a generic left at
its default"; it is a structural commitment in the card top.

Regenerating THROUGH the generator sizes the ports correctly
(`(4)*16-1 downto 0`), which also confirms the width derivation follows the
generic properly. Nobody had ever passed one.

### Area: the shipping configuration is cheaper on EVERY resource

Trees differing in exactly one file, same tool, same device:

| | `RECUR_LANES=32` (composed default) | `RECUR_LANES=4` (shipping) | delta |
|---|---|---|---|
| CLB LUT | 270,125 | 252,622 | **-17,503** |
| LUT as logic | 242,283 | 224,808 | -17,475 |
| CLB Registers | 237,896 | 218,971 | **-18,925** |
| CARRY8 | 12,514 | 11,130 | -1,384 |
| Block RAM tile | 327.5 | 306.5 | **-21** |
| DSP | 2,177 | 2,065 | **-112** |

**DSP is the binding resource on this part (75.59% at 2,177), so the 112 DSPs
matter more than the 17.5k LUT.** Every area figure in
`2026-08-31_cardtop-design-note.md` sections 14 and 15 is for `RECUR_LANES=32`
and therefore OVERSTATES the shipping configuration.

Section 15's unit-V DELTA is unaffected -- both of its arms used 32, so the
comparison is still like-for-like. Its ABSOLUTES are not the shipping design.

### Timing: it passes, and the identical slack is the informative part

| configuration | WNS | failing endpoints |
|---|---|---|
| `RECUR_LANES=32` | **+0.346** | 0 of a 20,000 cap |
| `RECUR_LANES=4` (shipping) | **+0.346** | 0 of a 20,000 cap |

**Identical to the digit across two designs 17,503 LUT and 112 DSP apart.**
That is not two measurements: it says the binding path lies in a structure
NEITHER configuration changes, so the composed top's critical path does not
involve B's recurrence at all. This is the same inference this project used to
exonerate `stmem` when B's `-4.008` repeated across four runs, with the sign
reversed.

### So the blocker is withdrawn

**"B's mover runs at 111 MHz and C's at 151.3 MHz, therefore the card misses
200 MHz" is WITHDRAWN in full.** B meets 200 MHz in the composed top at the
shipping configuration AND at the composed default, and `gdn_block` alone
meets it at `+0.483`. The only vehicle in which B fails is the extracted
mover, whose worst path starts at `a0` -- a synthesis-generated cell present
in NEITHER source file, living in the extraction wrapper outside `gb_real`.

### A defect in this file's own census script, found by running it

`sim/ooc_mover_paths.tcl` and the DCP census both RETURN EARLY when zero paths
fail, so the one design that MET timing reported nothing about why it only
just met it. **A met constraint still has a critical path, and that is exactly
when you want to see it.** A guard that suppresses the answer in the good case
is a bad guard. Recovered by a separate query over both checkpoints.

## Still open after this follow-up

- **Which lane count is intended.** `llama_top` says 4, `compose4_top` emits
  32 and bakes 512-bit ports around it. Nothing states which the card wants.
  **A design decision, not a measurement**, and deliberately not settled here.
- **What owns the composed top's `+0.346`.** Whatever it is, it is not B, and
  it is what the card's frequency actually rests on.
- **The movers' own glue is still unmeasured at card scale.** The composed top
  carries `gdn_block` and `attn_block`, not `gb_real`/`gcr`.
- **B's census hit its 5,000 cap** and needs re-running higher before any
  bucket below the top one is quoted.
- **Nothing here is a correctness claim.** `llama_top:4316` still refuses
  `B_SRC_REAL` past token 0.
- Still synthesis, not placed-and-routed.

### MEASURED: what owns the composed top's +0.346, and a CORRECTION

```
WORST RECUR32 slack=0.346  b_gdn/sp_b_e_reg[5]/C -> b_gdn/u_scal/ip_z_reg[23]/CE  levels=20
WORST RECUR32 slack=0.346  b_gdn/sp_b_e_reg[5]/C -> b_gdn/u_scal/ip_z_reg[24]/CE  levels=20
WORST RECUR32 slack=0.346  b_gdn/sp_b_e_reg[5]/C -> b_gdn/u_scal/ip_z_reg[25]/CE  levels=20
WORST RECUR4  slack=0.346  b_gdn/sp_b_e_reg[5]/C -> b_gdn/u_scal/ip_z_reg[23]/CE  levels=20
WORST RECUR4  slack=0.346  b_gdn/sp_b_e_reg[5]/C -> b_gdn/u_scal/ip_z_reg[24]/CE  levels=20
WORST RECUR4  slack=0.346  b_gdn/sp_b_e_reg[5]/C -> b_gdn/u_scal/ip_z_reg[25]/CE  levels=20
```

**CORRECTION, same day.** On seeing the identical `+0.346` this file concluded
the binding path "does not involve B's recurrence at all", and the author
additionally stated that the composed top's critical path "is not B". **The
second half is WITHDRAWN: the path IS inside `b_gdn`.** It runs from
`sp_b_e_reg[5]` into `u_scal/ip_z_reg[23..25]`, 20 logic levels, the same
three endpoints in both configurations.

What the identical slack licensed was narrower than what was claimed from it.
`u_scal` and the `sp_b_*` scalar/exponent registers are not the recurrence
lanes, so "`RECUR_LANES` does not change this path" is sound and was borne out
exactly -- the same startpoint, the same three endpoints, the same 20 levels,
the same slack. "Therefore not B" did not follow, and the inference should
have stopped at the structure it actually identified. An invariance argument
says what a quantity is NOT sensitive to; this file already records that
ruling one candidate out promotes nothing, and the same error was made again
one section later.

**The useful fact, stated correctly: B's `u_scal` owns the composed top's
critical path at 200 MHz, with 0.346 ns of margin, in both configurations.**
That is where any frequency headroom on this design has to come from, and it
is 20 logic levels deep. Note `u_scal` also appeared in the EXTRACTED mover's
census as the second-largest bucket (54 endpoints, worst `-3.329`, behind
`u_conv`'s 768), so the same unit is prominent in both vehicles even though
their verdicts differ.

**This does NOT make B a blocker again.** The design MEETS 200 MHz; owning the
critical path with positive slack is not a failure. It identifies where the
next nanosecond is, not a defect.

---

## CORRECTION, 2026-09-04 (later): the +0.346 was SYNTHESIS and did not survive routing

This file reports `WNS +0.346` with zero failing endpoints and uses it to
withdraw the movers-miss-timing blocker. **The withdrawal stands** -- the
movers' own numbers really were measured on configurations the card does not
use, and one of those vehicles cannot be built at the card's configuration at
all.

**But `+0.346` is a SYNTHESIS number and the routed result is `-0.402`**, a
0.748 ns swing, i.e. 185.1 MHz against the 200 MHz target. See
`2026-09-04_composed-top-routed.md`. Two specific claims made from `+0.346`
are withdrawn:

- *"B's `u_scal` owns the composed top's critical path ... that is where any
  frequency headroom has to come from."* The path DID carry over, same
  startpoint and destination array. But routed, `c_attn` fails at -0.401
  against `b_gdn`'s -0.402: **990 and 986 failing endpoints respectively, plus
  319 in `a_eng`**. There is no single owner and no single fix.
- The session's statement that the 200 MHz retarget pressure came from the
  A-only endpoint bitstream "not from the composed logic". The composed top
  routed is the WORSE of the two.

What this file got right and is worth keeping: the vehicle-configuration
finding, the 512-bit-versus-64-bit state interface, the 112-DSP cost of
`RECUR_LANES=32`, and the rule that an invariance argument says only what a
quantity is NOT sensitive to.
