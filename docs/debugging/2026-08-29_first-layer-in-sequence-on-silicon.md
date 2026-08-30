# A whole layer, in sequence, on the card, bit-exact

**Date:** 2026-08-29, 23:28
**Who:** dispatcher, on card 1 under Oren's one-night authorisation. Not a
subagent. TRACK LAYERRUN wrote the tool (`e82ae0e`) and was forbidden to run
it. VCCINT untouched (wiper 68), no flash write, card 2 never addressed.
**Tools:** `hw/fk33/host/fk33_run_layer.py`, `ref/run9b`, `fk33ctl.py`.
**Bitstream:** the routed engine build, core clock 200 MHz.

---

## 1. The question

Every one of tonight's 30+ bit-exact card results was a **single job** with the
host supplying the activation vector. Nothing had ever run a **sequence** on
this silicon: no layer, no chained jobs, no output of one job feeding the next.

## 2. The answer, up front

**Layer 0's ten subsystem-A matvecs ran in program order on one open device and
every one reproduced `ref/run9b`'s seam bit-exactly. 45,120 result rows
compared element for element, twice.**

And the stronger of the two modes passed:

```
LAYER OUTPUT R_X-0: 0 of 4096 mantissas differ from ref/run9b, exp 12 vs 12
```

In `chained` mode only the layer INPUT comes from the reference; every other
activation is **the card's own output from the previous job**. So errors had a
path to accumulate across ten jobs and did not.

**Zero thermal trips across both runs** (counter cleared 23:28:2x, `LATCHED
TRIP none since the last clear` afterwards), so neither result is confounded by
THERM-255.

## 3. SCOPE -- what this is NOT

The tool prints this itself and it must not be lost in the retelling:

> subsystem A only. The two RMS norms, the residual adds, the SwiGLU and the
> whole Gated DeltaNet block ran on the **HOST**; B, C and D are not on this
> silicon.

Ten A jobs for a Gated DeltaNet layer. The chain is **re-anchored once, by
name**, at `R_Y-0`, because subsystem B does not exist on the card. That is a
structural gap, not an oversight, and the tool refuses to hide it.

## 4. THE PCIe NUMBER, MEASURED -- and it replaces a claim I withdrew

Earlier tonight I published "~150 ms host round trip per job, 37.4 s/token,
67x slower than the compute" and then **withdrew it**: that 150 ms was
`fk33_run_job.py` rebuilding its oracle every invocation, not PCIe. See
`2026-08-29_first-throughput-numbers.md` CORRECTION 1.

This tool amortises setup -- oracle compiled once, manifest parsed once, device
opened once -- so what remains IS the PCIe cost. MEASURED, one Gated DeltaNet
layer:

| traffic | count | per access | total |
|---|---:|---:|---:|
| activation writes (posted) | 49,152 | 0.85 us | 0.042 s |
| status polls (reads) | 4,463 | 2.34 us | 0.010 s |
| **result readback (reads)** | **90,240** | **2.88 us** | **0.260 s** |
| compute | -- | -- | 0.486 s |

Layer wall: **0.540 s** anchored, **0.355 s** chained.

**TRACK LAYERRUN predicted this before any card ran and was right:** "the Y
readback -- one read pair per row -- is the thing, not the 150 ms you
withdrew." At 90,240 reads it is the single largest traffic term and **25x the
count of the status polls**.

A read is a full PCIe round trip; a write is posted. The two are reported
apart, and the asymmetry (0.85 us vs 2.88 us) is why.

## 5. The procedure

1. `ref/run9b --packed ... --embed mv4i --tokens 760 --layers 4` -- the
   reference stream, 62 records, 3.55 s. `--embed mv4i` avoids loading the
   17.9 GB BF16 GGUF.
2. **`teeth`** (no card) -- prove the checks bite BEFORE trusting a card
   result. Nine rows, all bit. It also names two holes it CANNOT close, which
   is the reason to trust the other nine.
3. **`plan`** (no card) -- 10 of 10 jobs re-run on the host and compared, 0
   differ; 5 of 5 host non-matvec steps reproduce the reference bit for bit;
   1 structural gap named.
4. `fk33ctl.py thermal --clear`, so any trip is attributable.
5. **`run --mode anchored`** -- every activation from the reference. Localises
   a failure to one job.
6. **`run --mode chained`** -- only the input anchored. This is the real test.
7. `fk33ctl.py thermal` -- confirm nothing tripped.

Steps 1-3 need no hardware and were run first on purpose: a green card result
whose checker has not been shown to bite is worth nothing.

## 6. Measured and REJECTED -- do not retry

- **Judging a sequence by its per-job column.** LAYERRUN built the layer-output
  comparison precisely because "a green job column with a wrong layer output is
  a FAIL, not a footnote." Ten passing jobs would not have established the
  chained result.
- **Timing a sequence with a per-job process.** One Python process per job
  measures Python, which is the error I made and withdrew.

## 7. Measurement traps

- **`stale` detection is BLIND on same-shape adjacencies.** The tool detects a
  stale completion through the engine's BEATS counter, so two adjacent jobs of
  the SAME shape are indistinguishable -- and **in a 9B layer `ffn_gate` and
  `ffn_up` are exactly that pair.** This is defect DONE-1, now dispatched:
  `rtl/matvec_int4_desc_axi.vhd` clears `done_l` at the next `S_IDLE`, not on
  the GO write, so after a GO the status register briefly reports the PREVIOUS
  job's completion. **A single-job tool can never meet it; a sequence meets it
  on every job after the first.** PCIe ordering plus AXI-Lite latency probably
  closes the window -- by ~10x, ESTIMATE, not by construction.
- **Every `teeth` row runs against a model that replays the reference.** None
  of them is evidence that any FPGA computes anything. Only sections 2 and 4
  are card measurements.

## 8. Open, not yet answered

- **One layer, one token, one shape.** Layer 0 is Gated DeltaNet; layer 3 is
  attention and was not run. Nothing here is a whole token.
- **B, C and D have never run on this silicon.** The host did five of the six
  non-matvec steps and could not do the sixth.
- **DONE-1 is unfixed** and its blind spot is real for `ffn_gate`/`ffn_up`.
- **The 2.88 us readback is one measurement on one layer.** Whether it is
  latency-bound (and so fixable by batching) or bandwidth-bound is not
  established, and it is now the largest single term in the wall time.


---

## 9. BOTH layer types now pass, chained. Added 00:07, 2026-08-30.

Section 8 listed "one layer, one token, one shape -- layer 0 is Gated DeltaNet;
layer 3 is attention and was not run" as open. Layer 3 has now been run, in
`chained` mode, thermal cleared first:

```
result      7 of 7 jobs run; 7 PASS, 0 FAIL/REFUSED, 0 INCONCLUSIVE
            43008 result rows compared against ref/run9b's stream, element for element
            layer wall 0.331 s
            anchored from the reference: R_X-2, R_Y-3
            RE-ANCHORED (the chain was broken here):
              R_Y-3            the gated attention block -- subsystem C, which is not on this silicon
            LAYER OUTPUT R_X-3: 0 of 4096 mantissas differ from ref/run9b, exp 10 vs 10

VERDICT     PASS
```

So **both layer topologies in the 9B model now run in sequence on the card and
produce bit-exact layer outputs**: layer 0 (Gated DeltaNet, **10** A jobs,
45,120 rows) and layer 3 (attention, **7** A jobs, 43,008 rows). **88,128
result rows in total, element for element, zero differ.**

The re-anchor point differs and is named differently in each -- `R_Y-0` for
"the Gated DeltaNet block -- subsystem B" and `R_Y-3` for "the gated attention
block -- subsystem C" -- which is the tool correctly reporting **two different
structural gaps**, not one generic one.

**`LAYER OUTPUT ... exp 10 vs 10`** against layer 0's `exp 12 vs 12`: the
exponents differ between the two layers and both match the reference, so this
is not a case where a constant would have passed.

### What is still NOT established by this

- **Still one token.** Both runs are token id 760, position 0.
- **Still subsystem A only.** Seven of the layer's steps ran on the host and
  the eighth -- the attention block itself -- is the structural gap. **B and C
  have never run on this silicon.**
- **Layers 1 and 2 (also Gated DeltaNet) were not run**, and no layer beyond 3
  exists in this reference stream (`--layers 4`).
- **The `done_l` stale-completion race (DONE-1) is unfixed**, and its detection
  through BEATS is blind on same-shape adjacencies -- which both of these
  layers contain in `ffn_gate`/`ffn_up`. Neither run is evidence against it.
