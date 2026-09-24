# Build 18 pair: per-step profile of one token, and a 2,320-id prefill (2026-09-24)

MEASURED with `hw/fk33/host/fk33_step_profile.py` on both cards during one GO
(`fk33_chat2.sh`, 1-id prompt, pad norms on, the `-nh` halves), 75 MHz core.

| op | card 0 (blocks 0-15) | card 1 (blocks 16-31 + head) |
|---|---|---|
| A_JOB | 148 steps, 65.5 ms (46.9%) | 164 steps, 79.8 ms (50.2%), of which the LM head 16 x ~74.2k cycles = 15.8 ms |
| B_JOB | 12 x 324,211 cycles, 51.9 ms (37.1%) | 12 x 324,215, 51.9 ms (32.6%) |
| VEC_SWG | 13.1 ms | 13.1 ms |
| VEC_NORM | 32, 4.8 ms | 65 (32 are pad norms), 9.8 ms |
| C_JOB | 4, 4.0 ms (position 0) | 4, 4.0 ms |
| total | 10,483,555 cycles, 139.8 ms | 11,925,925 cycles, 159.0 ms |

B's job is 324k cycles, down from 660,601 on 2026-09-20: the WIDE/PIPE/NWIDE
mover levers are on the card, matching that document's ~324k ADDITIVE
projection.

A 2,320-id web prompt (`rfobserver_2320_prompt_stdout.txt`): first token
after 423.6 s, i.e. 0.183 s per prompt token, against the slower card's
0.159 s, so ~24 ms per token is host and hop time not hidden by the overlap.
Decode of 936 ids at positions 2320-3255 took 386.6 s, 0.413 s per token.

## CORRECTION 2026-09-24 (same day): the "~24 ms per token of host time" is WITHDRAWN

The 0.183 s per prompt token is an AVERAGE over positions 0..2319, and C's
cost grows with position: 2,793.4 cycles per position per token on one card
(`docs/debugging/2026-09-20_token-cost-grows-2793-cycles-per-position.md`),
so ~0.0186 ms per position on each card of the pair (DERIVED). At the
prompt's mean position 1,160 that adds 21.6 ms to card 1's 159.0 ms,
giving 180.6 ms against the measured 182.6 ms. The same model predicts the
256-id ctxtest prefill (161.4 against ~164 ms) and decode at positions ~25
(308 against ~310 ms) and 2,320-3,255 (411 against 413 ms). **So the host
time NOT hidden by the prefill overlap is about 2-3 ms per token, not 24.**
In DECODE the hop is serial: 7.3 ms R_X read + 1.1 ms push per token.
