# JC 27B: where a decode token's cycles go with A at 450 MHz

## 1. The question

2026-11-15. Oren, after A moved to 450 MHz: "we need to scale other block to higher cap as well
correct?" and "does our architecture utilize the full FPGA at once?" Card `jccard_a450s1`
(commit 1d662c24, A tiled on aclk_a 450 MHz, core 125 MHz), both VU35P dies, own-PC 27B images.
A decode token costs 22,913,148 core cycles on die A and 22,634,813 on die B (position 0). Which
subsystem owns them?

## 2. The answer

B (Gated DeltaNet) is half the token: 459,400 cycles per B job, 50.1% on die A and 46.7% on die B.
A is 29% but only 11% is A's own compute window; the other 18% is per-A-job control around the
window (13,500 cycles per job: x copy-in, y emit, descriptor work). SwiGLU is 12.5%, C (attention)
3.7% at position 0, norms 4%, and die B spends 4.1% on 66 pad norms that do no useful work.
All MEASURED on silicon; per-class totals close against the full-token counter to 0.007%.

| class (die A) | steps | cycles | share | per step |
|---|---|---|---|---|
| B job | 25 | 11,485,306 | 50.13% | 459,412 |
| A, compute window | 306 | 2,554,328 | 11.15% | 8,347 |
| A, control around the window | 306 | 4,134,381 | 18.04% | 13,511 |
| SwiGLU | 33 | 2,873,673 | 12.54% | 87,081 |
| RMS norm | 66 | 936,453 | 4.09% | 14,188 |
| C job | 8 | 842,568 | 3.68% | 105,321 |
| residual | 66 | 86,724 | 0.38% | 1,314 |

Die B: B 46.68%, A 27.71% (window 10.59%, control 17.12%), SwiGLU 11.93%, norms 3.95%, pad norms
4.14%, C 3.72%, LM head 1.49%. Per layer: a GDN block costs 785,230 cycles, an attention block
410,332.

## 3. Procedure

Plan: `/mnt/storage/fk33_builds/breakdown_2026-11-15/` (`breakdown_plan_2026-11-15.md` beside it).
1. Truncated token programs, `gen_layer_program.py --upto N --close-token --no-a`, N = 1..504 (die
   A) and 1..555 (die B), each checked byte for byte as a prefix of the silicon program (0
   mismatches); the full-length ones equal `silicon/card{0,1}/token.{dtbl,rel}`. No arena reload:
   the prefixes issue the same A jobs in the same order against the resident arena.
2. Dry run of the whole driver on `jc_sim_broker --shape 27b --step-model`: recovers the modelled
   step durations exactly.
3. Board: control (full program, single die) must reproduce the pair run's CYCLES within 0.1%; then
   one GO at position 0 per N, reading CYCLES, ISSUE_CYC, STEPS_ISS, TBL_LEN and the engine's
   CYCLES (0x12034, A's compute window) via `jc_seam.py brk`; a row is refused unless tbl_len ==
   N+1 and steps_iss == N. Step N-1's duration is CYCLES - ISSUE_CYC from one run.
4. Restore: GDN re-zero, K1 anchor.

## 4. Evidence (raw, `runs/analysis.txt`, `runs/sweep.log`)

    CONTROL_OK die A cycles 22913133 pair 22913148 diff -15
    CONTROL_OK die B cycles 22634786 pair 22634813 diff -27
    K1_ANCHOR_OK id 8678, x-out A and B identical to /mnt/storage/fk33_builds/jc27b_ownpc_2026-11-11
    SWEEP_DONE (1,067 accepted rows)
    BRK_CLOSURE die A start 34 + steps 22913433 + tail 1 = 22913468 vs control run CYCLES 22913133: diff +335 (0.0015%) -> OK
    BRK_CLOSURE die B start 34 + steps 22636327 + tail -2 = 22636359 vs control run CYCLES 22634786: diff +1573 (0.0069%) -> OK
    BRK_JITTER die A n 1 spread 0 (2 runs) n 100 spread 115 (2 runs) n 504 spread 94 (3 runs)
    BRK_JITTER die B n 1 spread 0 (2 runs) n 100 spread 40 (2 runs) n 555 spread 363 (3 runs)
    BRK_IDENTITY die A tail median 1 spread 827 (min -404 max 423) bound 230 -> FAIL
    BRK_IDENTITY die B tail median -2 spread 1249 (min -623 max 626) bound 726 -> FAIL
    BRKBLK die A GDN  blocks 25 mean 785230 min 785185 max 785307
    BRKBLK die A attn blocks  8 mean 410332 min 410300 max 410381

Per-step CSVs: `runs/steps_A.csv`, `runs/steps_B.csv`.

## 5. Measured and REJECTED (do not retry)

- The FK33 method (`fk33_step_profile.py`, polling the seam during a token): on the JC each register
  read costs 5.4 to 46.6 ms against a mean step of 364 us, and the broker serves one client.
- "A is about 11% of the token" read as A's whole cost: true for A's compute window only. A's
  per-job control costs more than its compute (13.5k vs 8.3k cycles per job).

## 6. Measurement traps hit

- `env.sh` (the 2026-11-04 silicon env) exports `MAN0`/`MAN1` for the old striped layout and `REPO`
  for the main checkout; the sweep inherited both and aborted at preflight twice (image MISMATCH,
  then `jc_seam` without `UTIL_NONE`). Set `MAN0`, `MAN1`, `REPO` explicitly.
- The identity gate failed on both dies. The tail term varies by about +-400 (A) and +-620 (B)
  cycles from run to run, above the gate's bound; repeated runs of the same N spread by up to 363
  cycles. Read every single-step duration as +-~600 cycles. Class totals are unaffected (closure
  0.007%, and B jobs vary by 20 cycles across 25 instances).

## 7. Open

- What A's 13.5k-cycle per-job control is made of (x copy-in, y emit, descriptor fetch, done
  handshake) is not split by this sweep.
- Cost per position (C grows with context): two points only (position 0 and 499, about 4,380 cycles
  per position per die, DERIVED), not swept.
- Die-to-die hand-off and host time per token are not in these numbers (per-die seam cycles only).
