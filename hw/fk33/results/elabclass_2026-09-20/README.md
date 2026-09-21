# TRACK ELABCLASS -- the generic values no synthesiser has ever been given

Date: 2026-09-20. Part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, BC-250 lane
(`cachyos-bc250`, 15.2 GB + 48 GB swap). **No hardware**: `synth_design -rtl`
only -- elaboration, then stop. No mapping, no placement, no routing, no
bitstream, no programming. The card was live and serving the user throughout.
The workstation lane was never given a Vivado; it was on build 11b.

Tree: 114 `rtl/*.vhd` blobs from `git show HEAD:<path>` at **`f58a075`**, plus
`hw/fk33/gen/{norm_w_9b,qkn_9b}.hex` and ONE mutant
(`git show e1d5898^:rtl/attn_score_q12.vhd`, the pre-fix blob), staged into a
standalone remote root and manifest-verified sha256-identical on both boxes
before every launch.

Harness: `sim/elab_check.tcl` (one elaboration, one anchored verdict) and
`sim/elab_check_run.sh` (the row table, the presence gate, the memory cap).
Full analysis:
`docs/debugging/2026-09-20_the-defect-only-a-synthesiser-sees.md`.

---

## The question

TRACK HDRCOST's closing open item: *"whether any other generic in the repo has
the same elaboration-only failure mode -- nothing enumerates the class and
nothing schedules the 49-second discriminator"*.

## The answer, up front

**THE TEETH ROW REPRODUCES HDRCOST'S DEFECT IN 45 SECONDS, AND EVERY OTHER
CANDIDATE ELABORATES.** The full row table is in the debugging document; the
headline is that `synth_design -rtl` -- a mode that stops after elaboration --
prints HDRCOST's error line for line from the pre-fix blob:

```
ERROR: [Synth 8-11324] array index 8 out of range [.../mutant/attn_score_q12.vhd:488]
ERROR: [Synth 8-285] failed synthesizing module 'attn_score_q12' [.../mutant/attn_score_q12.vhd:244]
ERROR: [Synth 8-285] failed synthesizing module 'attn_block' [.../rtl/attn_block.vhd:486]
ELABCHK_SECONDS tag=teeth elaborate=22 total=28
```

so the cheap check has teeth on the exact defect that created this track, and
that was demonstrated rather than assumed.

---

## Files

* `rows/batch.log` -- batch 1 (the `attn_block` and `swiglu_mem` rows, plus the
  teeth row and its attribution control). Read THIS for a failing row's error
  text: the per-row `elabfail_*.txt` carries only Vivado's generic
  `[Vivado_Tcl 4-5] Elaboration failed` and never the cause.
* `rows/elab_<row>.log` -- the driver's per-row stdout.
* `rows/vivado_anchored_batch1.txt` -- every `^ERROR`, `^CRITICAL WARNING`,
  `^ELABCHK_` and `Parameter <lever> bound to` line from batch 1's Vivado logs.
  The full Vivado logs are hundreds of KB of `INFO` and are not committed.
* `rows2/` -- batch 2 (the `matvec_int4_desc_axi` and `fk33_llama_top` rows),
  same layout, plus `cgsample.log` (per-scope `memory.peak` AND
  `memory.swap.peak`, sampled every 15 s, because the driver that ran this
  batch predated its own swap column) and `swapguard.log` / `swapguard2.log`.
  **`swapguard.log` ends in `GUARD TRIPPED`, and that kill was WRONG**: the
  first guard tripped on `/proc/pressure/memory`'s `full avg10`, a ten-second
  average, and killed `d_hostwin` while it was at 11 GB of swap -- a row that
  had already COMPLETED peaked at 22.9 GB with avg10 around 5. `swapguard2.log`
  is the level-based replacement.
* `rows3/` -- the `d_hostwin` re-run, chained on batch 2's own
  `ELABCLASS_ALLDONE` sentinel and then gated on Vivado PRESENCE. A sentinel
  says the work ahead finished; presence says nothing else took the lane
  meanwhile; neither alone is enough.
* `rows/invalidated_quoting_trap/` -- **kept deliberately.** Batch 1's `d_card`
  and `d_hostwin` rows failed with three anchored `ERROR:` lines naming
  `rtl/fk33_llama_top.vhd`, and the cause was the HARNESS: a string generic
  written as `NAME={"path"}` put the braces in the string. Nothing in the output
  says "harness"; the only thing that caught it is that `d_card` is a row which
  must pass. See section 7.3 of the debugging document.
* `census/` -- the enumeration: the entity/generic count, the boolean-arm
  census, and the static-index scan. All three are inputs to the RANKING and
  none of them is a finding on its own.
