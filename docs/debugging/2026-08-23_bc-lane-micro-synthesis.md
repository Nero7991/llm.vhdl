# B and C single-lane micro-synthesis: DSP and fabric cost on the real FK33 part

Date: 2026-08-23
Part: `xcvu33p-fsvh2104-2L-e` (the FK33's actual low-power grade, per
`docs/fpga-hardware-recon.md:418`), Vivado 2023.2, OOC, 3.333 ns target (300 MHz)

## The question

Two specs assert per-lane DSP costs that the whole FK33 allocation rests on, and
neither had been synthesized:

- **C §2.6:** one gated-attention lane is **2 DSP48E2**, because the 36 x 13
  rescale exceeds the 27-bit A port and needs a pair, and the 8 x 16 score MAC
  and 13 x 8 PV MAC then ride along in DSPs the rescale already paid for. If the
  real answer is 3, the claim is 50% light, and across the 64-288 lanes now in
  play that is a 128-288 DSP error on a 2,880-DSP device.
- **B §2.8:** one Gated DeltaNet lane is **4 DSP48E2**, on the claim that the
  site-6 prescale and site-7 normalize were engineered so all four products
  (s16xu16, s19xs16, s18xu16, s16xs18) fit a single 27x18 DSP each.

C also carries a fabric estimate: 1,024 accumulators in FF because PV does 64
read-modify-writes per cycle, "about 10-13K LUT" of read muxing and 36,864 FF.

## The answer

**Both DSP claims are correct, measured, on the real part and grade.** C is 2
DSP/lane and B is 4 DSP/lane, and the utilisation report and an independent
DSP48E2 census agree in every run.

C's **FF** estimate is exact. C's **LUT** estimate is incomplete rather than
wrong: 10-13K covers the fixed register-file term and omits a per-lane term
the spec never counted. The measured split is

```
C per lane:   LUT = 158 + 10.0 x ACC_N        FF = 182 + 36.4 x ACC_N
B per lane:   LUT = 50                        FF = 118        DSP = 4
```

`ACC_N` is the lane's share of the accumulator file. The 36.4 is `ACC_W = 36`:
one FF per accumulator bit, which is why §2.6's 1,024 x 36 = 36,864 FF is right
on the nose. Because the file is a **fixed 1,024 entries** (4 query heads x 256
dims) regardless of `MACS`, the two terms scale differently and must not be
collapsed into a single per-lane figure:

| MACS | ACC_N | DSP | LUT | FF |
|---|---|---|---|---|
| 64 (spec today) | 16 | **128** | 20,352 | 48,960 |
| 192 (corrected geometry) | 6 | **384** | 40,576 | 71,808 |
| 288 (corrected geometry) | 4 | **576** | 55,744 | 89,280 |

At `MACS = 64` the DSP figure is **exactly** the 128 C §2.8 derived.

## The procedure

Four probes, each isolating one thing. Files: `sim/micro/*.vhd`,
`sim/ooc_micro.tcl`, `sim/run_micro.sh`.

1. **C lane, naive RMW.** One time-shared multiply with muxed operands, plus a
   16-entry x 36-bit accumulator file. Isolates: does the shared unit land on 2
   DSPs or 3.
2. **C lane, hand-shared accumulator adder.** Identical arithmetic; the only
   change is that the read-modify-write adds **once** into a muxed addend
   instead of once per decoded entry. Isolates the cost of the coding
   discipline alone, with the arithmetic held fixed.
3. **`ACC_N` sweep, 2/4/8/16/32** on the shared variant. Isolates the fixed
   per-lane term from the per-accumulator term. This is the probe that makes
   the result usable at a `MACS` other than 64 - without it there is one point
   and no way to know which way it scales.
4. **B lane, the full four-stage §2.1.4 chain.** Isolates whether every product
   fits one DSP, and whether the s41 sk accumulate spills to fabric.

Discipline applied to all four, each item chosen against a specific way this
class of experiment lies:

- every operand arrives on a **top-level port** and is registered once, so
  nothing constant-folds into a shifter or a KCM;
- every result is **XOR-folded into a `digest` output**, so no cone is pruned
  with only a quiet log line;
- the C mode select is a **free-running counter**, never a port and never a
  constant. This one decides the answer: give synthesis a constant mode and it
  strength-reduces each mode separately, reports 1 DSP, and "2 DSP shared" is
  confirmed by an experiment that never tested sharing;
- **one** multiply expression with muxed operands, never three expressions,
  which would infer three multipliers and answer a different question;
- the register file is written out explicitly, because `acc(i) <= acc(i) + a*b`
  invites Vivado to pack the add into the DSP's own accumulator and the file
  into distributed RAM - precisely the FF and LUT being measured;
- **no `DONT_TOUCH`** (blocks register-into-DSP packing, inflates FF), **no
  `use_dsp`** (forcing it asserts the answer instead of measuring it);
- clock constrained **before** synthesis, report after `opt_design`;
- DSP48E2 **census** cross-checked against the utilisation number, with
  `USE_MULT` to separate a real multiplier from a DSP recruited as a wide adder.

Hand counts were written down **before** running, and both were right on DSP
and both wrong on LUT - which is the reason for recording them.

## The evidence

```
MICRO micro_c_lane             DSP=2 (census 2)  LUT=1110  FF=727   CARRY8=80  WNS=0.290  Fmax=328.6 MHz
MICRO micro_c_lane_sh          DSP=2 (census 2)  LUT=318   FF=765   CARRY8=5   WNS=0.290  Fmax=328.6 MHz
MICRO micro_c_lane_sh_ACC_N2   DSP=2 (census 2)  LUT=176   FF=255   CARRY8=5   WNS=0.483  Fmax=350.9 MHz
MICRO micro_c_lane_sh_ACC_N4   DSP=2 (census 2)  LUT=198   FF=329   CARRY8=5   WNS=0.416  Fmax=342.8 MHz
MICRO micro_c_lane_sh_ACC_N8   DSP=2 (census 2)  LUT=238   FF=475   CARRY8=5   WNS=0.328  Fmax=332.8 MHz
MICRO micro_c_lane_sh_ACC_N16  DSP=2 (census 2)  LUT=318   FF=765   CARRY8=5   WNS=0.290  Fmax=328.6 MHz
MICRO micro_c_lane_sh_ACC_N32  DSP=2 (census 2)  LUT=543   FF=1347  CARRY8=5   WNS=0.296  Fmax=329.3 MHz
MICRO micro_b_lane             DSP=4 (census 4)  LUT=50    FF=118   CARRY8=3   WNS=1.092  Fmax=446.2 MHz
```

DSP48E2 census, C (both variants identical) - the 36-bit operand split across a
pair, both halves real multipliers, neither a recruited adder:

```
NAME       USE_MULT   AREG  BREG  PREG
prod0      MULTIPLY   0     0     0
prod_reg   MULTIPLY   0     0     1
```

DSP48E2 census, B - four multipliers, and note `sk_acc_reg` `PREG=1`: the s41
accumulate folded into the DSP's own 48-bit P register rather than spilling to
fabric, which is why B's LUT is 50 and not several hundred:

```
NAME         USE_MULT   AREG  BREG  PREG
ARG          MULTIPLY   1     1     0
ARG__0       MULTIPLY   1     1     0
kd_reg       MULTIPLY   1     1     1
sk_acc_reg   MULTIPLY   2     1     1
```

The `ACC_N` fit, on 2 through 16 (`LUT = 158 + 10 x ACC_N`): predicts 178 / 198
/ 238 / 318 against measured 176 / 198 / 238 / 318. At `ACC_N = 32` it predicts
478 against 543 measured - the 32:1 read mux exhausts the F7/F8 mux chain and
needs a third fabric level, so **the fit is linear only to 16** and a design
putting more than 16 accumulators behind one lane pays a superlinear penalty.

## Measured and REJECTED - do not retry

**The naive read-modify-write. 1110 LUT and 80 CARRY8 per lane, against 318 and
5 for identical arithmetic.** Writing the accumulator update as

```vhdl
for i in 0 to ACC_N-1 loop
  if to_integer(i_r) = i then acc(i) <= acc(i) + prod; end if;
end loop;
```

builds **sixteen** 36-bit adders, one per entry, where the design needs one.
Vivado does not share them: only one branch can ever be active, but proving the
enables one-hot is not something synthesis attempts. 80 CARRY8 is exactly 16
adders x 5. The cost of not knowing this is 792 LUT per lane - **152K to 228K
LUT at 192-288 lanes, 35-52% of the VU33P's 439,680**, for hardware that does
nothing. Fix is in `micro_c_lane_sh.vhd`: read through the mux that already
exists, add once into a muxed addend, write back under a decoded enable.

**Predicting C's LUT from the read mux alone.** My own hand count said 250-350
LUT/lane from "36 bits x a 16:1 mux", and the naive lane measured 1110. The read
mux was right (72 F7 + 36 F8 + ~144 LUT, as predicted); what it missed was the
**write side**, where every entry needs its own input mux and, in the naive
form, its own adder. §2.6 makes the same omission - it prices "16:1 read muxes"
and stops there.

## Measurement traps hit

**A single-lane OOC Fmax is optimistic and must not be quoted as the
subsystem's.** 328.6 MHz for C and 446.2 for B are one lane with no fanout. In
the real design `k`, `v_aligned` and the rescale factor broadcast to all 64-288
lanes, and that net is the thing that will set Fmax, not the lane. For scale:
subsystem A on this same part and grade managed 276 MHz at `ROWS_IF=48` - below
the 300 these lanes clear comfortably in isolation. **These numbers say the lane
arithmetic is not the critical path. They do not say the subsystem closes at
300 MHz.**

**`ACC_N` had to become a generic before the sweep meant anything.** The first
version hardcoded a 4-bit index. Sweeping depth against a fixed index width
leaves dead decode in the small configurations and understates the slope.

## Open, not yet answered

- **Neither skeleton covers its subsystem's auxiliary logic**, which is exactly
  the row both specs flag as unverified. C's excludes softmax/exp, the score
  reduction tree, alignment barrel shifters, Q BRAM striping, bypass records and
  control. B's excludes the cross-lane sk reduction tree, sigma/silu
  interpolation, the L2 sum-of-squares, conv MACs and the state feed. The aux
  ranges (C 15-40 DSP, B 10-24) are **still estimates**.
- **The broadcast fanout above** is the next thing worth synthesizing, and it
  needs a multi-lane skeleton rather than a single lane.
- **C's blocking-geometry defect is not fixed by this work.** The table above
  prices `MACS` at 192 and 288 because those are the legal values under the
  corrected geometry, but choosing between them is a separate open decision.
