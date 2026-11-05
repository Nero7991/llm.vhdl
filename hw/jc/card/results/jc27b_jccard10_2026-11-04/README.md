# jccard10 on silicon: first-token residuals, 2026-11-04

Bitstream: `hw/jc/card/results/jccard10_2026-10-10/jc_card.bit` (sha256 d00e237e...), both dies,
125 MHz, levers off. Images reloaded after power cycles (die A 7,170 pieces, die B 6,750, both
JCVERIFY_PASS 0 bad); side images regenerated from the tree (token programs byte-identical to
2026-10-09; image record differs only in its timestamp and checksum).

Runs: `run_prompt --jc --jc-die A --jc-die2 B --seq-reset --v2 ... --max-new 1 --dump-xout
--dump-xout2`, GDN re-zeroed before each (`jc_bc_lane.sh rezero`). Reference:
`/mnt/storage/fk33_builds/jc27b_silicon_2026-10-09/ref27_lout.r9bs` (llama.cpp CPU, 2026-10-09).
Comparator `../jc27b_first_token_2026-10-09/xout_vs_lout.py CARD REF LAYER TOK`.

| run | die | jccard8 corr / rel_rms (2026-10-09) | jccard10 corr / rel_rms |
|---|---|---|---|
| k=1, pos 0 | A (l_out-32) | 0.99885 / 0.183 | 0.99921 / 0.089 |
| k=1, pos 0 | B (l_out-63) | 0.98671 / 0.675 | 0.99595 / 0.090 |
| k=4, pos 3 | A | 0.95381 / 0.360 | 0.99359 / 0.125 |
| k=4, pos 3 | B | 0.97424 / 0.486 | 0.99522 / 0.102 |
| k=23, pos 22 | A | 0.94470 / 0.354 | 0.99419 / 0.115 |
| k=23, pos 22 | B | 0.87032 / 0.585 | 0.97304 / 0.248 |

First argmax: k=1 8678, k=4 264, k=23 1206 (llama.cpp: 7732).
CPU lm_head from the card's k=23 die-B row (`lmhead_card.txt`): 1206 -0.81, 7732 -1.46,
2064 -2.01. llama.cpp's own: 7732 -1.02, 5449 -1.25, 1206 -1.76. 7732 moved from rank 5
(jccard8) to rank 2.

Wall time with the bulk R_X read (commit 619127c7, first silicon use): k=1 4.75 s, k=4 7.2 s,
k=23 22.7 s (2026-10-09: about 54 s per hop).
