# Does the -22.9% voltage derate apply to a real design on the card?

**Date:** 2026-08-25
**Hardware:** SQRL FK33, xcvu33p-fsvh2104-2L-e, VCCINT measured 0.717 V
**Design:** `hw/fk33/build_fk33_hbmbw.tcl`, 15 HBM AXI3 ports, `rtl/hbm_tg.vhd`
**Prior claim under test:** `2026-08-24_vccint-derate-and-exp-cone.md` CR-1

## The question

Every Fmax figure in every spec is Vivado's 0.85 V analysis. The card runs at
0.717 V. `2026-08-24_vccint-derate-and-exp-cone.md` measured **-22.9% mean**
(-24.0% worst) by re-analysing subsystem A's matvec core at 0.72 V, and every
budget since has applied it as a whole-die constant: "a 300 MHz design runs at
231 MHz on the card", "everything takes +30% more time".

That was a **Vivado timing-analysis result, not a hardware result** -- one
netlist analysed twice at two voltages. No design had ever been run on the
card at a frequency where the derate predicted failure. This is that test.

## The answer

**The -22.9% derate does NOT transfer to this design.** A 300 MHz build whose
exercised critical path has 0.528 ns of slack at 0.85 V ran 48 million beats
on the card with zero miscounts at 100.0% of the arithmetic ceiling.

- The exercised path's delay is **2.805 ns**; the period is 3.333 ns, so it
  tolerates a delay increase of **up to 18.8%** before missing.
- **-22.9% on Fmax is +29.7% on delay** (1/0.771). That would have broken it.
- It did not break. So at 0.717 V this design's delay increase is
  **<= 18.8%**, i.e. its Fmax derate is **no worse than -15.8%**.

This is a **bound, not a measurement**: the design passed, so all we learn is
that the true derate is smaller than the margin we had. Section 6 pushes the
frequency up to find where it actually breaks.

Treating -22.9% as a whole-die constant is not safe **in either direction** --
it is not conservative here, it is simply not this design's number.

## The procedure

1. **Build at the target frequency and confirm signoff timing.** 300 MHz,
   routed WNS **+0.499 ns**. Positive, so the design closes at 0.85 V.

2. **Try Vivado's own 0.72 V prediction first.** This is the technique that
   produced -22.9%, and it is far cheaper than hardware. It **does not work
   on this design**:

   ```
   set_operating_conditions -voltage {VCCINT 0.72}
   ERROR: [Timing 38-246] Caught exception 'vector::_M_range_check: __n
     (which is 18446744072723252823) >= this->size() (which is 224510)'
     while reading timing library and applying constraints.
   ```

   An internal delay-calculator crash, repeated per path, ending the session.
   The -22.9% was measured on an **out-of-context** matvec core with no hard
   IP. Adding HBM makes the 0.72 V library unusable. **So there is no analysis
   prediction available for any HBM-facing design, and hardware is the only
   way to answer this.** That is worth knowing on its own: the cheap technique
   silently does not extend to the designs that matter most.

3. **Find the path the test actually exercises -- not the reported WNS.**
   This is the step that decides whether the result means anything. The
   reported WNS path is:

   ```
   slack +0.499 ns   clk_out1 (100 MHz) -> clk_out3 (300 MHz)
     from bd_i/hbm_reset/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N_replica_8/C
     to   bd_i/tg/inst/u/gen[14].arstall_reg[14][12]/R
   ```

   That is a **reset** path, into an `R` pin, crossing 100 -> 300 MHz. It is
   exercised **once, at reset**, not during the run. A violation there would
   show up as a skewed reset release, not as a sustained counting error, so a
   clean 3.2-million-cycle run says almost nothing about it.

   The path that runs every cycle is the worst **synchronous** path within the
   300 MHz domain:

   ```
   slack +0.528 ns   delay 2.805 ns   -> Fmax 356.5 MHz at 0.85 V
     from bd_i/hbm/.../HBM_SNGLBLI_INTF_AXI<2>_INST/ACLK
     to   bd_i/tg/inst/u/gen[1].aoff_reg[12]/CE
   ```

   Query it explicitly with `-from $c3 -to $c3`; the default `get_timing_paths`
   will hand you the reset path and you will draw a conclusion about a wire the
   experiment never stressed.

4. **Run the design hard enough that a timing failure must show.** 200,000
   bursts x 16 beats per port, 15 ports, with a beat-count self-check that
   knows the exact expected total. A marginal path corrupts a counter and the
   count stops matching.

5. **Confirm the clock is what you think.** Every GB/s figure is
   `beats * 32 * FCLK / cycles`, and beat counts are clock-INDEPENDENT, so a
   wrong FCLK scales the whole result while every self-check still passes.
   Here the MMCM is 200 MHz in, MULT_F 6.000 -> VCO 1200, CLKOUT3 divide 4 ->
   **300.000 MHz exactly**, so the constant is right by construction.
   `gen_hbmbw.py` now refuses any frequency the MMCM cannot hit exactly.

## Evidence

```
generator OK, NPORT=15, AXI clock 300.00 MHz
ceiling at NPORT ports = 144.0 GB/s
die temperature before: 28.2 C   stack codes: 29 29 29 29

 ports      beats       cycles         GB/s   %ceiling    die_C stacks
     1    3200000      3200065          9.6     100.0%     28.7 29 29 29 29
     2    6400000      3200065         19.2     100.0%     28.7 29 29 29 29
     4   12800000      3200158         38.4     100.0%     27.7 29 29 29 29
     8   25600000      3200157         76.8     100.0%     27.7 30 30 30 30
    15   48000000      3200172        144.0     100.0%     27.7 32 32 32 32

die temperature after: 28.2 C   stack codes: 32 32 32 32
```

Every count is exactly `n * 200000 * 16`. Cycles are ~3.2 M at every port
count, i.e. one beat per cycle per port sustained with all 15 concurrent.

## Secondary results

- **HBM is not the limiter below 144 GB/s** -- but read what that does and
  does not say. See the CORRECTION section at the end: 100% of ceiling at
  300 MHz was arithmetically guaranteed rather than discovered, and the
  460.8 GB/s premise remains untested.
- **The stack temperature codes track something real.** Flat at 29 through
  4 ports, 30 at 8 ports, 32 at 15 ports, returning to 29 at idle, while the
  die sensor stayed at 27.7-28.7 C. The code-to-Celsius mapping is still
  uncalibrated, so the soft ceiling stays disabled and CATTRIP remains the
  hard protection.
- **The design's WNS is set by an unsynchronised reset CDC**, 100 -> 300 MHz
  into `R` pins. It is only 0.029 ns worse than the real limiter here so it
  costs nothing today, but a reset crossing into a fast domain should be
  synchronised in the destination domain rather than timed as a data path.

## Measured and REJECTED -- do not retry

- **`set_operating_conditions -voltage {VCCINT 0.72}` on a design containing
  HBM.** Crashes Vivado's delay calculator (step 2). Works fine
  out-of-context without hard IP, which is why it worked for subsystem A.
- **Reading the derate conclusion off the reported WNS.** The WNS path here is
  a reset path the workload does not exercise (step 3). It happens to be close
  to the real limiter in this build; that is luck, not method.
- **Assuming the requested MMCM frequency is the achieved one.** Not wrong
  here, but unchecked until now, and unfalsifiable by any self-check the
  instrument has (step 5).
- **"The HBM IP cannot be clocked above ~300 MHz."** Formed on the 350 MHz
  TNS and refuted by bucketing the endpoints (section 6). The HBM interface
  was never the limiter. Do not resurrect this from a TNS figure alone.

## Measurement traps hit

- **A passing test bounds the derate, it does not measure it.** The instinct
  on seeing a clean 100%-of-ceiling run is to say "the derate is refuted".
  What is actually established is `derate <= 15.8%`. The true value could be
  0%. Only a failing point brackets it.
- **The reported WNS and the exercised WNS are different numbers**, and
  nothing in the flow tells you which one you are holding.

## 6. Pushing the frequency up: what the 350 MHz attempt actually found

The plan was to raise the clock until the design broke on the card, turning
`derate <= 15.8%` into a number. The 350 MHz build did not close at 0.85 V --
routed WNS **-1.229 ns, TNS -330 ns** -- so it was useless as a card test: a
failure there could not be attributed to voltage rather than to a netlist
that never met timing in the first place.

**The tempting conclusion was wrong.** TNS -330 ns spread over many endpoints,
on a design dominated by HBM hard IP, reads as "the HBM AXI interface has its
own frequency ceiling". That would have been a significant claim: it would cap
the 460.8 GB/s premise (32 ports x 32 B x 450 MHz) at roughly 307 GB/s
regardless of voltage, since the interface simply could not be clocked there.

Bucketing the failing endpoints by structure refuted it in one query:

```
failing endpoints (placed): 34
  HBM ACLK -> tg fabric      34
worst:  slack -0.492 ns
  from bd_i/hbm/inst/.../HBM_SNGLBLI_INTF_APB_INST/PCLK
  to   bd_i/tg/inst/u/therm_stop_reg/D
```

All 34 are **one structure, and it is ours**: `hbm_temp[6:0]` and
`hbm_cattrip` leave the HBM IP in its **APB status domain** and were being
compared **combinationally** in the AXI domain with no synchroniser. Not an
HBM ceiling -- our own unsynchronised status path, which happened to fit at
300 MHz and did not at 350. Fixed in `72838ca`; see that commit for why the
7-bit code also needs a hold filter and why CATTRIP deliberately does not.

**The generalisable lesson:** a large TNS spread across many endpoints looks
like a distributed problem and is usually ONE replicated structure. Bucket the
failing endpoints by start/end hierarchy before forming any hypothesis about
the cause; the count is a property of how many instances the structure has,
not of how hard the problem is. This is the second time this instrument has
produced that exact pattern -- the earlier 450 MHz attempt failed on 4,597
endpoints that were 15 generators x their counters, one structural problem.

That also means **the derate sweep never actually reached a voltage-limited
point.** Both attempts to exceed 300 MHz were stopped by design defects, not
by the card. The bound in section 2 still stands and is still only a bound.

## Open, not yet answered

- **The actual derate for this design.** Still unmeasured. Two attempts to
  clock past 300 MHz were both stopped by design defects rather than by the
  card, so no voltage-limited point has been observed yet.
- **Whether the derate is path-type dependent.** -22.9% came from DSP and
  carry-chain-heavy matvec logic; this path is HBM-ACLK-to-fabric-CE. Two
  different numbers for two different path mixes is a perfectly ordinary
  result and would mean neither is a die constant. Not established either way.
- **Whether subsystem A's -22.9% is still right for subsystem A.** Nothing
  here challenges it. What is challenged is its use as a whole-die constant.
- **The stack temperature code to Celsius mapping.**


## CORRECTION, 2026-08-25 (same day), on what the 144 GB/s figure means

Two problems with how this document and `9811d8b` presented the bandwidth
result. Neither changes a measured number; both change what the number is
evidence FOR. Recorded here rather than by editing the claims above, so the
overstatement stays visible.

### 1. 100% of ceiling at 300 MHz was guaranteed, not discovered

A 256-bit AXI port at 300 MHz demands `32 B x 300 MHz = 9.6 GB/s`. An HBM2
pseudo-channel on this device supplies `460.8 / 32 = 14.4 GB/s`. The port
therefore asks for **two thirds** of what the channel can deliver, so absent
port-to-port contention a stall is arithmetically impossible. Every sweep
point reaching exactly 100.0% is what that predicts; it is not evidence that
HBM has headroom, because the experiment could not have produced any other
answer.

This is also why 450 MHz is in the premise at all: `32 B x 450 MHz` is
14.4 GB/s, i.e. 450 MHz is precisely the clock at which a 256-bit port
matches one pseudo-channel. **Below ~450 MHz the memory is never under
pressure at any port count**, and adding ports scales the total linearly
without testing anything new about the memory.

Consequence: the frequency work is not a side quest to the bandwidth
question, it IS the bandwidth question. And the practical position is worse
than it looked -- with both CDCs fixed the design still misses 350 MHz by
0.467 ns, so the instrument cannot currently be clocked anywhere near the
frequency at which HBM would start to push back.

What the run does establish, stated correctly:
- 15 ports sustain one beat per cycle each, concurrently: MEASURED.
- HBM is not the limiter below 144 GB/s: MEASURED, as a lower bound.
- HBM's actual ceiling: NOT measured, and not measurable at 300 MHz.
- The 460.8 GB/s premise: untested.

### 2. The instrument counted beats without checking read responses

`hbm_tg` had no `rresp` port at all, and `hbm_tg_ip.vhd` **declared**
`m..._axi_rresp` on all 15 masters and connected none of them. SLVERR and
DECERR beats were counted as memory traffic.

The failure direction is what makes this serious: the interconnect returns an
error response FASTER than HBM returns data, so a mis-decoded address or a
disabled pseudo-channel would have reported **higher** bandwidth than a
working design. An instrument whose failure mode is a better-looking number
cannot be trusted by inspection of its output.

The 144 GB/s run has one piece of independent corroboration, and it is
physical rather than logical: the stack temperature codes rose 29 -> 32 under
the 15-port load and returned to 29 at idle. An interconnect refusing
requests does not heat HBM stacks. That makes it very likely the traffic was
real -- but "very likely, on thermal grounds" is not the standard this
instrument was built to meet.

> **RESOLVED the same day.** The 300 MHz sweep was re-run on a rebuild
> carrying the response counter (`hw/fk33/results/hbmbw_300mhz_validated.txt`,
> build WNS +0.455 ns): **zero non-OKAY responses at all five port counts**,
> and the numbers reproduce exactly. The 48,000,000 beats were real memory
> reads. The thermal inference was right, and is now backed by the direct
> check rather than standing in for it.
>
> Problem 1 below is NOT resolved by this and is not resolvable at 300 MHz.

Fixed in `c98c7cc`: per-port non-OKAY counter at 0x1000, checked by the sweep
before the beat and thermal checks, and the testbench now proves the counter
fires (zero on a clean run, exactly `nburst*(arlen+1)` under injected
SLVERR) rather than assuming it is connected. A counter never made to fire is
indistinguishable from one wired to nothing, which is the state this design
was in.

**Also checked and cleared while investigating this:** the build's
`USER_MC_ENABLE_01..07 {FALSE}` / `09..15 {FALSE}` lines, which would have
left only one memory controller per stack enabled, are inside the
`if {$HBMGlobalSwitch == 0}` branch and `HBMGlobalSwitch` is **1**. They are
dead code in this configuration; the controllers are enabled and the global
address switch is on. Do not re-raise this from grepping the tcl.
