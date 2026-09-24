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
