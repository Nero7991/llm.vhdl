# TRACK CBRAM, 2026-09-20: the evidence that the codebook stopped being RAM

The analysis is `docs/debugging/2026-09-20_the-codebook-stopped-being-ram.md`.
This directory holds only the captures it reads, committed because **they were
the only copies and `BUILD_ROOT` is reused**.

| file | what it is | why it is here |
|---|---|---|
| `ram_inference_8-5859.txt` | the `[Synth 8-5859] Recognized 3D RAM` lines from **three** builds, verbatim, plus the `cb_reg` mapping rows | **the whole finding.** The recognizer fires on `cb_reg` in builds 9 and 10 and not in build 11b. Build 9's rows also carry `FK33_CB_STYLE distributed` and `WNS=0.061 / TNS=0.000`, which is the control that decides the repair |
| `control_sets_codebook.txt` | the codebook control sets from both builds, extracted and read | what `cb` became: 1,536 x 16 LUTRAM bels -> 48 x 128 flip-flops |
| `build10_control_sets_placed.rpt.gz` | build 10's `report_control_sets -verbose`, placed, complete | md5 `29ab2f06723a34efb752d2df01e1e90c`, round-trip verified |
| `build11b_control_sets_placed.rpt.gz` | build 11b's, complete | md5 `b90562b649b0446ee4d43fe6aa9350d4`, round-trip verified |

**And one file was added to a neighbouring directory:**
`hw/fk33/results/card_build10_FAILED_2026-09-20/build.stdout.full.gz`, md5 of
the uncompressed stream `e938341e8ee6c5dbb932a18ead4996ca`, 5,327,098 bytes,
256 KB compressed. The `build.stdout.tail.gz` already in that directory is a
**tail that never reaches synthesis** and holds no `8-5859` and no mapping
report, so this comparison was not makeable from the committed record. It is
now.

Provenance: build 10's root records `HEAD =
b71a6d98212ee9ebc6fdde6d5a3802154dabd232`, whose `rtl/matvec_core.vhd` is
md5 `b616c7822f93154b08200f9418489012`, **byte-identical to `0b34200^`**.
Build 11b's is `5dc3ee5`, md5 `c3325ea1f418dcbcaa85f33e47e8c901`, identical to
`HEAD` and to the working tree. So for this one file the two builds differ by
exactly `0b34200`'s four hunks.

No Vivado was started to produce any of this. No hardware. Nothing was written
inside `/mnt/storage/fk33_builds/build11b/`.
