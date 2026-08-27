# gdn_conv: which of the spec's two conv cycle models is right

Date: 2026-08-26. Unit `rtl/gdn_conv.vhd` at commit `bc0a030` (subsystem B,
spec `docs/superpowers/specs/2026-08-21-gated-deltanet-design.md`).
Simulator GHDL 1.0.0 mcode, `--std=08`. No synthesis was run.

## 1. The question, verbatim

> the subsystem B design spec `docs/superpowers/specs/2026-08-21-gated-deltanet-design.md`
> gives the causal-conv cycle model TWO DIFFERENT WAYS, in section 3.3 and
> section 3.6, and they differ by a factor of 2. Nobody has established which is
> right. Settle it BY MEASUREMENT against the actual RTL, not by re-reading the
> prose.

The two claims, quoted from the spec as it stood before this document.

**Section 3.3**, in the "Budget with fused 4-lane norms and 4/cycle silu" table:

> | conv, depthwise k=4 over 5,120/layer at `LANES = 32` | 30,720 | 0.10 |

As a formula, the only derivation that produces 30,720 from the quantities the
row itself names (`5,120` channels per layer, 48 GDN layers, `k = 4`,
`LANES = 32`) is

```
cycles/token = K * N_ch / LANES = 4 * 5,120 * 48 / 32 = 983,040 / LANES = 30,720
```

**Section 3.6**, in the `gdn_conv` closure bullet:

> **Which lane count the schedule needs is now arithmetic rather than
> guesswork.** Per card the conv is 5,120 channels over 48 GDN layers, two
> passes each, so `491,520 / LANES` cycles per token:
>
> | `LANES` | cycles | ms @ 300 MHz | fraction of the 589,824 sweep | DSP |
> |---|---|---|---|---|
> | 2 | 245,760 | 0.82 | 41.7% | 8 |
> | **4** | **122,880** | **0.41** | **20.8%** | **16** |
> | 8 | 61,440 | 0.21 | 10.4% | 32 |

As a formula:

```
cycles/token = 2 * N_ch / LANES = 2 * 5,120 * 48 / LANES = 491,520 / LANES
```

They differ by exactly `K / 2 = 2`.

## 2. The answer

**Section 3.6 is right and section 3.3 is wrong.** Measured on the RTL, one
invocation of `gdn_conv` costs

```
cycles(start -> o_done) = 2 * (nch / LANES) + 16 + max(1, log2(LANES))
```

exact on all 136 measured points, so the per-token term is `2 * N_ch / LANES`
plus a fixed per-invocation overhead that neither section counts. B issues 144
invocations per token (3 segments x 48 layers), so section 3.6's 122,880 at
`LANES = 4` should read **125,472 cycles**, +2.1%. Section 3.3's row is
**2.00x** the two-pass term and **1.67x** the full measured cost at the
`LANES = 32` it names.

The mechanism is two errors of opposite sign: section 3.3 charged the KERNEL
dimension to time (`K = 4` cycles per channel-group) where the RTL charges it
to DSP (`DSP = 4 * LANES`, all four taps in one cycle), and it did not count
pass B, the block-floating requantize, at all. `4 / 2 = 2`, which is why the
disagreement is a clean factor of two and would not have been for any other
kernel size.

## 3. The procedure

Each step, and what it isolates.

1. **Read the FSM, not the prose** (`rtl/gdn_conv.vhd`, the `state_t` case).
   Establishes what the candidate terms even are: `S_A` streams one group per
   cycle, `S_B` streams the same groups again, and everything else
   (`S_IDLE` -> `S_PREP`, the `S_ADR`/`S_AMRED` amax reduction, `S_SH`,
   `S_BDR`, `S_FIN`, plus the two pipeline drains) is fixed or logarithmic in
   `LANES`. This says the model has the shape `a * nch/LANES + b(LANES)` and
   nothing else; it does NOT say what `a` is, because miscounting drains is
   exactly the kind of thing reading produces and counting does not.

2. **Count cycles on the CORRECTNESS testbench** (`sim/tb_gdn_conv.vhd`, new
   `cyc_mon` process). This is the control for "the unit you measured is the
   unit that computes the right answer": the same run that emits the cycle
   count also runs the 128-case bit-exactness check against
   `ref/gdn_conv_vec.c` and the double-precision oracle. Nothing in that
   testbench's assertions or tolerance was touched; the monitor drives nothing.
   It only reaches one shape (`nch = CH_MAX = 256`, the vector file's) per
   `LANES`, so it cannot fit a model on its own.

3. **Sweep the shape on a separate testbench** (`sim/tb_gdn_conv_cycles.vhd`,
   new). Drives `nch` over 15 group counts on one instance, so `nch/LANES`
   moves across three decades independently of `LANES`. Synthetic data,
   deliberately no checking -- see the trap in section 6 about why that is safe
   here and how it was verified rather than assumed.

4. **Fit, and test the fit where it can fail.** The group-count list is
   `1,2,3,4,5,8,13,16,32,64,128,192,256,384,768` -- the non-powers-of-two are
   there so a model that only fits `2^n` cannot pass, and `g = 1` is there
   because the pipeline drains are the whole of the constant term and a
   1-group segment is where they dominate.

5. **Re-derive both spec formulas at the measured rate** and put the answer
   into the phase budget both sections share.

Measurement definition, stated so it is reproducible: `t0` is the rising edge
on which the DUT samples `start` high (the edge that leaves `S_IDLE`); `t1` is
the rising edge whose `S_FIN` body asserts `o_done`; `cycles = (t1 - t0)/TCLK`.
Channel groups are streamed back to back with no producer bubbles, so every
number below is the unit's best case -- a caller that cannot feed a group per
cycle measures more, never less.

## 4. The evidence

### 4.1 Cycle counts from the bit-exact run

Raw, from `ghdl -r tb_gdn_conv -gLANES=<L>` (workdir elided). Each run emits one
`CYC,lanes,nch,groups,cycles` line per case; all 128 cases in a run emit the
IDENTICAL count, which is itself a result -- the cycle count is data-independent
across the whole vector set, including the `0001`/`0011`/`0111` sequence-start
valid masks and the all-zero segments.

```
CYC,4,256,64,146
tb_gdn_conv.vhd:220:7:@190766ns:(report note): gdn_conv: bit-exact with the C recipe on all 128 cases; worst vs the double ORACLE 4.99999999998181e-1 LSB
CYC,8,256,32,83
tb_gdn_conv.vhd:220:7:@110126ns:(report note): gdn_conv: bit-exact with the C recipe on all 128 cases; worst vs the double ORACLE 4.99999999998181e-1 LSB
CYC,16,256,16,52
tb_gdn_conv.vhd:220:7:@70446ns:(report note): gdn_conv: bit-exact with the C recipe on all 128 cases; worst vs the double ORACLE 4.99999999998181e-1 LSB
CYC,32,256,8,37
tb_gdn_conv.vhd:220:7:@51246ns:(report note): gdn_conv: bit-exact with the C recipe on all 128 cases; worst vs the double ORACLE 4.99999999998181e-1 LSB
```

### 4.2 Shape sweep

`ghdl -r tb_gdn_conv_cycles -gLANES=<L> -gCH_MAX=<C>`, 136 distinct points over
`LANES` in {1,2,4,8,16,32,64} and `CH_MAX` in {256, 1024, 3072}. Full set in
`sim/gdn_conv_cycles.csv`. Extract, `LANES = 4`, `CH_MAX = 3072` (the instance
size B actually builds, since the v segment is 3,072):

```
CYC,4,3072,4,1,20
CYC,4,3072,8,2,22
CYC,4,3072,12,3,24
CYC,4,3072,16,4,26
CYC,4,3072,20,5,28
CYC,4,3072,32,8,34
CYC,4,3072,52,13,44
CYC,4,3072,64,16,50
CYC,4,3072,128,32,82
CYC,4,3072,256,64,146
CYC,4,3072,512,128,274
CYC,4,3072,768,192,402
CYC,4,3072,1024,256,530
CYC,4,3072,1536,384,786
CYC,4,3072,3072,768,1554
```

`cycles - 2*groups`, over every one of the 136 points, grouped by `LANES`
(count, `LANES`, residual):

```
     13 1	17
     11 2	17
     23 4	18
     34 8	19
     20 16	20
     16 32	21
      4 64	22
```

The residual is constant in `nch` and in `CH_MAX` and rises by exactly one per
doubling of `LANES`, so

```
cycles = 2 * (nch / LANES) + 16 + max(1, log2(LANES))
```

with **zero mismatches on 136/136 points**. The `16` is the fixed FSM cost
(`S_IDLE` exit, `S_PREP`, the two pipeline drains, `S_ADR`, `S_SH`, `S_BDR`,
`S_FIN`, and the 2-cycle `ready` handshake the caller must wait out); the
`log2(LANES)` is the `S_AMRED` amax reduction tree, one cycle per halving, with
a floor of one cycle at `LANES` 1 and 2.

### 4.3 The two formulas against the measurement

Per card per token: 3 segments per layer (q 1,024, k 1,024, v 3,072 = 5,120)
over 48 GDN layers = **144 invocations, 245,760 channels**.

| `LANES` | §3.3 model `4*N/LANES` | §3.6 model `2*N/LANES` | MEASURED | §3.3 / measured | §3.6 / measured |
|---|---|---|---|---|---|
| 2 | 491,520 | 245,760 | **248,208** | 1.980 | 0.990 |
| **4** | 245,760 | 122,880 | **125,472** | 1.959 | 0.979 |
| 8 | 122,880 | 61,440 | **64,176** | 1.915 | 0.957 |
| 16 | 61,440 | 30,720 | **33,600** | 1.829 | 0.914 |
| 32 | 30,720 | 15,360 | **18,384** | 1.671 | 0.835 |

Section 3.6 is right to within the per-invocation overhead it omits (2.1% at
the decided `LANES = 4`). Section 3.3 is high by a factor of two.

### 4.4 Mechanism

`gdn_conv` spends its cycles on **passes over channels**, not on taps:

- Pass A (`S_A`) computes all `K` products for all `LANES` channels in ONE
  cycle -- `p1(t)(ln) <= xf(t)(ln) * wf(t)(ln)` is a doubly-nested loop inside a
  single clocked branch. That is why the synthesized cost is `DSP = 4 * LANES`
  (the spec's own measured row, 16 DSP at `LANES = 4`). The kernel dimension is
  paid in silicon, not in time.
- Pass B (`S_B`) exists because `amax` cannot be known until every accumulator
  exists, so the block-floating requantize has to re-stream the whole segment.
  The unit's own header says so: *"The unit is two passes because amax cannot be
  known until every acc exists."* This pass is unconditional and is the second
  `nch/LANES`.

Section 3.3's row prices a unit that does the opposite of both: `K` cycles per
channel-group (tap-serial, so `LANES` multipliers, not `4 * LANES`) and one pass
(no requantize). Two independent errors, `x4` and `/2`, netting `x2`.

Two things corroborate that this is what happened rather than a transcription
slip:

1. **The row names `k = 4` at all.** A cycle count that does not depend on the
   kernel size has no reason to mention it. Section 3.6's phrasing, by contrast,
   names the thing its formula actually depends on: "two passes each".
2. **The implied multiplier count matches the spec's other assumption.** A
   tap-serial unit at `LANES = 32` needs 32 multipliers, and section 2.8's aux
   row assumed exactly *"32 dedicated"* conv MACs before the RTL measured 16.
   A tap-parallel unit at `LANES = 32` would need 128 DSP, a number that appears
   nowhere in B's budget. So section 3.3's cycles row and section 2.8's DSP row
   are two views of the same wrong unit, and the RTL refutes both together.

### 4.5 Does the error class extend to the spec's other cycle models?

**Yes, to one of them, and it has already been caught once there.** The
distinguishing feature of the bad row is that it was priced from an ASSUMED
multiplier count rather than read off an FSM. Exactly one other row in the two
section 3 tables is of that kind: the state sweep's *"4 cycles per column at
`LANES = 32`"*, and section 3.6 already flags it in those words -- *"treat the
4-cycles-per-column figure as an ASSUMPTION, not a measurement: it is the
arithmetic ideal of the DSP count"* -- after `gdn_recur` measured 58 cycles per
column against it, a 14.5x miss. That one was then rescued by a redesign
(`gdn_recur_pipe`, II = `NB` exactly), so the number survived; the conv row was
not rescued, because nothing about `gdn_conv` can remove pass B.

The other rows are **not** of that kind and do not share the error:

- output `rmsnorm` + L2, 213,120: derived from an FSM state-by-state reading
  (`5N + ~15`, then `3N`), and since superseded by a measured `rmsnorm_rs`
  (142 cycles at `LANES = 4`).
- silu, 98,304: `393,216 / 4`. `rtl/gdn_silu.vhd`'s header states *"Fully
  pipelined: one LANES-group per cycle, II = 1, latency 7"*, so one group per
  cycle at 4 lanes is the built structure, not an assumed one. Its
  per-invocation drain is uncounted, the same omission as the conv's, and is
  the same order (tens of cycles x invocations).

## 5. Effect on B's per-token latency budget

The sweep is **589,824 cycles**, 1.97 ms at the 299.04 MHz measured for
`gdn_recur_pipe`. The conv has to hide under it together with the output norm,
the L2 and silu. Bundles, all in cycles so no Fmax rides along.

**Read every ratio in this section as carrying that denominator, which is
itself disputed as of the same night.** Commit `bf54847` withdraws the 589,824
figure pending resolution: section 2.6 derives it at `LANES = 8` and section
3.1 quotes it at `LANES = 32`, which cannot both hold, and the per-layer
formula it comes from (`S*S*H/LANES = 262,144/LANES`) uses `H = 16`, the stale
KEY head count, where the state is per VALUE head and there are 24 per card
(`128*128*24 = 393,216`, 1.5x larger). Everything measured in this document is
in absolute cycles and is unaffected; only the "sweep / total" column moves,
and it moves in the safe direction if the sweep turns out to be larger.

| bundle | rmsnorm | L2 | silu | conv | total | sweep / total |
|---|---|---|---|---|---|---|
| §3.3 as written (conv at `LANES = 32`) | 213,120 (both) | | 98,304 | 30,720 | 342,144 | 1.72 (+72%) |
| §3.3's own 2026-08-26 correction (§3.6 conv at `LANES = 4`) | 213,120 (both) | | 98,304 | 122,880 | 434,304 | 1.36 (+36%) |
| §3.6's rmsnorm bullet ("401,664, +47%") | 163,584 | 109,056 | 98,304 | 30,720 | 401,664 | 1.47 (+47%) |
| the parallel spec audit's rebuild, every unit at its own CLOSING rate | 163,584 | 142,080 | 98,304 | 122,880 | 526,848 | 1.120 (+12%) |
| **the same, with the MEASURED conv** | 163,584 | 142,080 | 98,304 | **125,472** | **529,440** | **1.114 (+11.4%)** |
| counterfactual: if §3.3's conv model had been RIGHT | 163,584 | 142,080 | 98,304 | 245,760 | 649,728 | **0.908 -- does NOT fit** |

The fourth row is not this document's work: `docs/debugging/2026-08-26_gdn-spec-audit.md`,
written the same night, rebuilds the bundle with `l2norm_rs` at its own closing
point (`LANES = 2`, 185 cycles, because `LANES = 4` reaches only 285.8 MHz and
misses B's 299.04) instead of at the output norm's rate. That audit reaches the
same VERDICT on the conv model by reading `rtl/gdn_conv.vhd`'s header and the
`DSP = 4 x LANES` row; what is new here is the measurement, the per-invocation
overhead neither model has, and the fit that rules out a third model.

Three things follow.

1. **The verdict does not move the budget; it protects it.** Settling in favour
   of section 3.6 and then adding the measured overhead changes the bundle by
   +2,592 cycles, 0.5%: +11.4% margin rather than +12.0%. Every larger number
   still printed in section 3.3 (+72%, +36%) and in section 3.6's rmsnorm bullet
   (+47%) is stale for reasons that are mostly not about the conv.

2. **Had section 3.3 been right, the conv would NOT have hidden.** At the
   decided `LANES = 4` a `4*N/LANES` conv is 245,760 cycles and the bundle
   exceeds the sweep on its own, before anything else is added. The two models
   straddle the fit/no-fit line at the lane count B has actually chosen, which
   is the reason this was worth settling rather than left as a documentation
   discrepancy.

3. **The conv is now a small term in a budget that the same night's audit says
   does not close anyway.** That audit adds the two emit stages (sites 12 and
   13, both built and both absent from every section 3 budget) at 605,952
   cycles, which alone exceeds the sweep. Nothing in this document contradicts
   that or rescues it: halving the conv term from a wrong 245,760 to a measured
   125,472 does not matter to a bundle that is over by 605,952 elsewhere. The
   honest summary is that the conv row was one of several wrong terms, it was
   wrong in the SAFE direction, and correcting it neither creates nor solves
   the schedule problem.

Conv alone, measured, as a fraction of the sweep: `LANES = 2` 42.1%,
**`LANES = 4` 21.3%**, `LANES = 8` 10.9%, `LANES = 16` 5.7%, `LANES = 32` 3.1%.
Section 3.6's 20.8% at `LANES = 4` should read 21.3%. The `LANES = 4` decision
and its 16 DSP are unaffected.

## 6. Measured and REJECTED -- do not retry

- **`cycles = K * nch / LANES` (section 3.3's model). REJECTED.** At
  `LANES = 4, nch = 64` it predicts 64 streaming cycles; the measurement is 50
  total, of which 18 is the fixed FSM cost, so 32 streaming -- half. Per token
  at `LANES = 4` it predicts 245,760; measured 125,472. Wrong at every one of
  the 136 points, and wrong in a way no constant term can absorb, because the
  slope itself is wrong: 4 per group against a measured 2.
- **"The kernel dimension costs cycles." REJECTED.** All `K` products are issued
  in one cycle (`rtl/gdn_conv.vhd`, the `p1` assignment in `S_A`), and the
  measured slope is 2 per group regardless of `K`. `K` costs DSP: the spec's own
  synthesis rows read `DSP = 4 * LANES`.
- **"There is a third pass, or a per-tap drain." REJECTED.** The constant term
  is 17 to 22 cycles across `LANES` 1 to 64 and does not scale with `nch` at
  all; a third pass would add a third `nch/LANES`. At `nch = 3072, LANES = 4`
  the measurement is 1,554 = `2*768 + 18`, and `3*768 + 18 = 2,322`.
- **"The cycle count is data-dependent, so the sweep needs the real vectors."
  REJECTED, and this was checked rather than assumed:** all 128 vector cases at
  each of `LANES` in {4,8,16,32} produce the identical count (146 / 83 / 52 /
  37). The case set spans every valid mask including the sequence-start
  prefixes and the all-zero segments, which is where `msb_pos` and `sh_seg` take
  their extreme values. `S_SH` is one cycle either way.
- **"Section 3.3's 30,720 might be the two-pass model at `LANES = 16`,
  mislabelled." NOT REFUTED, but not the leading explanation.** `491,520/16` is
  also 30,720, so the arithmetic is ambiguous on its own. It is rejected as the
  explanation only because it requires the row's `LANES = 32` label to be wrong
  AND leaves the row's `k = 4` unexplained, whereas the tap-serial reading makes
  both labels true and matches section 2.8's independent "32 dedicated" MAC
  assumption. Recorded as ambiguity, not as a finding -- see section 8.
- **Running any of this through Vivado. NOT DONE, deliberately.** Both machines
  were synthesizing on the night this was measured and Vivado has OOM'd this box
  before. Nothing here needs synthesis: cycle counts are simulator ground truth
  and the DSP/Fmax rows quoted are the spec's own existing measurements.

## 7. Measurement traps hit

1. **`ghdl -e` produces no binary on the mcode backend and exits 0.** Known in
   this repo; `ghdl -r <entity>` directly is the only path. Analysis order
   `fixed_luts_pkg` -> `fixed_pkg` -> `util_pkg` -> unit -> testbench.

2. **A free-running clock plus a trailing `wait;` means the simulation never
   ends.** The first cycle-sweep runs printed every result and then sat at 100%
   CPU forever, which is indistinguishable from a hang -- twelve of them at once,
   on a box that was already synthesizing. `tb_gdn_conv_cycles` now calls
   `std.env.finish`. `sim/tb_gdn_conv.vhd` still ends in `wait;` and was left
   that way on purpose (changing the correctness testbench's termination is not
   this document's business), so its runs must be killed after the final report
   line.

3. **Piping a long GHDL run through `tail` hides all of it.** Combined with trap
   2 this cost the first hour: a run that had actually finished looked like a run
   that had produced nothing. Redirect to a file, then poll the file.

4. **Reading a registered output at the clock edge counts one cycle too many.**
   `o_done` is assigned in `S_FIN`, so a process that wakes on `rising_edge(clk)`
   and reads it high is one edge LATE; the monitor subtracts one `TCLK` for
   exactly this. One cycle is 0.6% at the shapes here and would have been
   invisible inside a 2x argument -- but the same slip on the `start` end, where
   `start` IS sampled at the edge, would have shifted the constant term and made
   the `g = 1` points disagree with the fit. The fit passing at `g = 1` is what
   says the endpoints are right.

5. **`seed * 1103515245` overflows GHDL's 32-bit `integer`** and aborts with
   `overflow detected`, not with a wrong number. Harmless here (a data
   generator), but worth knowing that VHDL `integer` arithmetic traps rather
   than wraps.

6. **The correctness testbench drives `nch = CH_MAX` only**, because the vector
   file is generated at `CH_MAX`. Fitting a model on it alone would have given
   one point per `LANES` and no way to separate the slope from the constant.
   That is the whole reason for the second testbench, and the reason the second
   one is deliberately check-free: a file that both counts cycles and asserts
   correctness invites someone to weaken an assertion to get a timing number.

## 8. Open, not yet answered

- **The sweep denominator, 589,824 cycles.** Withdrawn by `bf54847` the same
  night for the reasons quoted in section 5. Until it is resolved, every
  percentage-of-sweep figure here and in section 3 of the spec is provisional.
  The conv cycle model is not: it is absolute.
- **Which of the two arithmetic paths to 30,720 the author actually took.**
  The tap-serial reading is argued in 4.4 and is the parsimonious one, but
  `491,520/16` reaches the same number and cannot be excluded from the document
  alone. This matters only for how far the error class is expected to reach; the
  verdict on the formula does not depend on it.
- **Whether the conv hides under the sweep AT ALL.** Nothing here is a schedule.
  Section 3.3's own note already says no overlap has been exhibited and that
  section 2.1.3's two-pass structure resists the intra-layer overlap that decode
  makes available, because `e_seg` -- and therefore `e_v` and the L2 inputs --
  exists only after a whole segment's pass A completes. This measurement makes
  the conv term smaller than the wrong figure; it does not make it overlappable.
- **The per-invocation overhead in the real caller.** 16 to 22 cycles is the
  measured floor with a caller that asserts `s_valid` the cycle after `ready`
  and never bubbles. A DDR-fed caller will not do that, and the conv's operands
  come from the conv-state slots over AXI (section 2.6). The honest statement is
  that 125,472 is a LOWER bound at `LANES = 4`.
- **silu's per-invocation drain.** 98,304 counts elements only, the same
  omission this document found in the conv row. `gdn_silu`'s header says
  latency 7 at II = 1, so the drain is small, but the number of silu invocations
  per token is not stated anywhere and so the total is not derivable from the
  spec as written.
- **Whether `LANES = 4` is still the right conv choice.** `LANES = 8` costs 16
  more DSP and takes the measured conv term from 125,472 to 64,176, i.e. the
  audit's rebuilt bundle from 529,440 to 468,144 (+26% margin instead of
  +11.4%). Not a recommendation -- the DSP budget is contested elsewhere in
  section 2.8, this document did not price it, and the emit stages dominate
  whatever is decided here.

## 9. Reproducing

```
cd sim
ghdl -a --std=08 --workdir=<wd> ../rtl/fixed_luts_pkg.vhd ../rtl/fixed_pkg.vhd \
     ../rtl/util_pkg.vhd ../rtl/gdn_conv.vhd tb_gdn_conv.vhd tb_gdn_conv_cycles.vhd

# shape sweep, terminates on its own
ghdl -r --std=08 --workdir=<wd> tb_gdn_conv_cycles -gLANES=4 -gCH_MAX=3072

# cycle count alongside the bit-exactness check; kill it after the report line
ghdl -r --std=08 --workdir=<wd> tb_gdn_conv -gLANES=4
```

Collected output: `sim/gdn_conv_cycles.csv`.
