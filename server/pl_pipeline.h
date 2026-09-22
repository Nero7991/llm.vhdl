/* server/pl_pipeline.h -- two cards, one model, the host carries R_X.
 *
 * 2026-09-21, docs/superpowers/specs/2026-09-21-two-card-pipeline-design.md.
 * Card 0 runs blocks 0..k-1 of the model and ends with the residual in R_X;
 * card 1 runs blocks k..N-1 plus the LM head.  Per position the host pushes
 * the embedding into card 0, runs it, reads R_X and its block exponent back
 * (pl_read_xout), pushes that row into card 1 (pl_decode_row) and takes
 * card 1's argmax.  Card 0's argmax is meaningless (no LM head) and ignored.
 *
 * Phase 0 is SERIAL: the overlap of card 0's position p+1 with card 1's
 * position p during prefill needs a non-blocking GO in pl_backend
 * (pl_go_async/pl_wait), which does not exist yet.  The loop below is the
 * measurable baseline, and the hop is timed so its share of the token is a
 * number and not an estimate. */
#ifndef PL_PIPELINE_H
#define PL_PIPELINE_H
#include "pl_backend.h"

typedef struct plp_ctx plp_ctx;

/* Both contexts must be open, v2, and agree on n_embd.  Ownership stays with
 * the caller: plp_close frees only the pipeline's own buffers. */
int  plp_open(pl_ctx *card0, pl_ctx *card1, plp_ctx **out);
void plp_close(plp_ctx *p);

int  plp_seq_reset(plp_ctx *p);          /* both cards */
int  plp_seq_pos(const plp_ctx *p);      /* card 1's position (== card 0's) */

/* Same return contract as pl_prefill / pl_decode: n (or 1) on success, a
 * negative pl_backend code on failure, -6 if the two cards' positions have
 * diverged (a hop was skipped or repeated).  argmax is card 1's. */
int  plp_prefill(plp_ctx *p, const int *ids, int n, int *argmax);
int  plp_decode(plp_ctx *p, int id, int *argmax);

/* Hop accounting since process start: seconds spent reading card 0's R_X,
 * seconds spent pushing it into card 1 (the GO is NOT included), hops. */
void plp_hop_timing(double *read_s, double *write_s, unsigned long *hops);

#endif
