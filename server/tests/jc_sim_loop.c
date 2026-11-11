/* server/tests/jc_sim_loop.c -- see jc_sim_loop.h. Register offsets and reasons are
 * rtl/tok_loop_pkg.vhd's; the per-position sequence is tok_loop_fsm's state list. */
#include <stdlib.h>
#include <string.h>
#include "jc_sim_loop.h"
#include "../fk33_seam.h"

enum { S_IDLE, S_RUN, S_STOPPED };
enum { W_NONE, W_ROW, W_LINK, W_CREDIT, W_TOKEN, W_OUT };
enum { R_NONE, R_MAX_NEW, R_STOP_ID, R_MAXPOS, R_ABORT, R_ENGINE_ERR, R_ENGINE_TIMEOUT,
       R_SEAM_ERR, R_LINK_TIMEOUT, R_RETRY_EXH, R_BAD_CONFIG, R_SEQ_RESET_FAIL, R_GATHER_ERR };
#define SB FK33_SEAM_BASE          /* 0xE000, server/fk33_seam.h:227 */
#define OUT_DEPTH 1024u
#define MAXP 4096u

typedef struct { uint32_t pos, exp, seq; int bad; uint16_t *m; } frame;
struct jc_loop {
  fk33_transport *t;
  unsigned n;
  int state, wait, owns;
  uint32_t reason, pos, n_gen, plen, max_new, row_src, role, resend_cap, stop[8];
  uint32_t next_tok, next_v, row_exp, row_addr, prompt_addr, out_ack, out_addr, credit;
  uint32_t kvmax, g, row_ready, consumed, frames_sent, frames_good, crc_fails, resends, cleared;
  uint32_t seqpos_bad, overruns;
  uint32_t prompt[MAXP], out[OUT_DEPTH];
  uint16_t *hrow;
  jc_loop *peer;                   /* a -> b */
  frame q[2]; int qn;              /* RXDEPTH 2 */
  frame held; int has_held;
  unsigned long drop_nth, sent_total;
};

static int sw(jc_loop *L, uint32_t off, uint32_t v) { return L->t->reg_write32(L->t->ctx, SB + off, v); }
static int sr(jc_loop *L, uint32_t off, uint32_t *v) { return L->t->reg_read32(L->t->ctx, SB + off, v); }
static void stop_(jc_loop *L, uint32_t r) { L->reason = r; L->state = S_STOPPED; L->owns = 0; L->wait = W_NONE; }

jc_loop *jc_loop_new(fk33_transport *t, unsigned n_embd)
{
  jc_loop *L = calloc(1, sizeof *L);
  int k;
  if (!L) return NULL;
  L->t = t; L->n = n_embd; L->resend_cap = 3;
  for (k = 0; k < 8; k++) L->stop[k] = 0xFFFFFFFFu;
  L->hrow = calloc(n_embd, sizeof *L->hrow);
  L->held.m = calloc(n_embd, sizeof(uint16_t));
  for (k = 0; k < 2; k++) L->q[k].m = calloc(n_embd, sizeof(uint16_t));
  return L;
}
void jc_loop_pair(jc_loop *a, jc_loop *b) { a->peer = b; }
void jc_loop_drop(jc_loop *a, unsigned long nth) { a->drop_nth = nth; }
int jc_loop_owns_seam(const jc_loop *L) { return L->owns; }

static void deliver(jc_loop *a, const frame *f)
{
  jc_loop *b = a->peer;
  a->frames_sent++; a->sent_total++;
  if (!b) return;
  if (a->drop_nth && a->sent_total == a->drop_nth) { b->crc_fails++; return; }   /* corrupted */
  if (f->pos != b->consumed + (uint32_t)b->qn) { b->seqpos_bad++; return; }     /* stale (rx verdict order) */
  if (b->qn >= 2) { b->overruns++; return; }
  b->q[b->qn].pos = f->pos; b->q[b->qn].exp = f->exp;
  memcpy(b->q[b->qn].m, f->m, b->n * sizeof(uint16_t));
  b->qn++; b->frames_good++;
}

static int start(jc_loop *L)
{
  uint32_t st, tp, sp;
  L->pos = 0; L->n_gen = 0; L->reason = 0; L->out_ack = 0; L->next_v = 0; L->qn = 0;
  L->has_held = 0; L->consumed = 0; L->frames_sent = L->frames_good = L->crc_fails = L->resends = 0;
  L->cleared = 0; L->seqpos_bad = 0; L->overruns = 0;
  L->sent_total = 0; L->state = S_RUN;
  if (!L->plen || L->plen > MAXP || !L->max_new || L->role > 2 || L->row_src > 2
      || ((L->row_src == 2) != (L->role == 2)) || L->row_src == 0) { stop_(L, R_BAD_CONFIG); return 0; }
  L->owns = 1;
  if (sw(L, FK33_SEAM_CTRL, 2) || sr(L, FK33_SEAM_STATUS, &st)) { stop_(L, R_SEAM_ERR); return 0; }
  if (st & 4) { stop_(L, R_SEQ_RESET_FAIL); return 0; }
  if (sr(L, FK33_SEAM_TOK_POS, &tp) || sr(L, FK33_SEAM_SEQ_POS, &sp) || tp || sp) { stop_(L, R_SEQ_RESET_FAIL); return 0; }
  if (sr(L, FK33_SEAM_KV_MAXPOS, &L->kvmax)) { stop_(L, R_SEAM_ERR); return 0; }
  return 0;
}

/* one position from row-in-hand to token; returns 1 when it blocked */
static int position(jc_loop *L, const uint16_t *row, uint32_t exp)
{
  uint32_t st, v, k;
  sw(L, FK33_SEAM_X_EXP, exp); sw(L, FK33_SEAM_WIN_SEL, 2); sw(L, FK33_SEAM_WIN_ADDR, 0);
  for (k = 0; k < L->n; k++) sw(L, FK33_SEAM_WIN_DATA, row[k]);
  sw(L, FK33_SEAM_SEQ_POS, L->pos); sw(L, FK33_SEAM_N_STEP, 1); sw(L, FK33_SEAM_CTRL, 1);
  do { if (sr(L, FK33_SEAM_STATUS, &st)) { stop_(L, R_SEAM_ERR); return 1; } } while (!(st & 5));
  if (st & 4) { stop_(L, R_ENGINE_ERR); return 1; }
  if (L->role == 1) {
    sw(L, FK33_SEAM_WIN_SEL, 3); sw(L, FK33_SEAM_WIN_ADDR, 0);
    for (k = 0; k < L->n; k++) { sr(L, FK33_SEAM_WIN_DATA, &v); L->held.m[k] = (uint16_t)v; }
    sr(L, FK33_SEAM_XEXP_OUT, &L->held.exp);
    L->held.pos = L->pos; L->has_held = 1;
    deliver(L, &L->held);
  }
  return 0;
}

void jc_loop_tick(jc_loop *L)
{
  int guard;
  for (guard = 0; guard < 4 && L->state == S_RUN; guard++) {
    uint32_t k;
    if (L->wait == W_OUT) { if (L->n_gen - L->out_ack >= OUT_DEPTH) return; L->wait = W_NONE; goto push; }
    if (L->wait == W_TOKEN) { if (!L->next_v) return; L->g = L->next_tok; L->next_v = 0; L->wait = W_NONE; goto push; }
    if (L->wait == W_CREDIT) { if (L->credit < L->pos) return; L->wait = W_NONE; }
    if (L->pos >= L->kvmax) { stop_(L, R_MAXPOS); return; }
    /* plan D3. The RTL waits after GO, before reading R_X; waiting before the position
     * delivers the same frames in the same order, which is all the host can observe. */
    if (L->role == 1 && L->credit < L->pos) { L->wait = W_CREDIT; return; }
    if (L->row_src == 1) {
      if (!L->row_ready) { L->wait = W_ROW; return; }
      L->row_ready = 0; L->wait = W_NONE;
      if (position(L, L->hrow, L->row_exp)) return;
    } else {
      if (!L->qn) { L->wait = W_LINK; return; }
      L->wait = W_NONE;
      if (position(L, L->q[0].m, L->q[0].exp)) return;
      { uint16_t *m0 = L->q[0].m; L->q[0] = L->q[1]; L->q[1].m = m0; }
      L->qn--; L->consumed++;
    }
    if (L->pos + 1 < L->plen) { L->pos++; continue; }
    if (L->role == 1) { L->wait = W_TOKEN; return; }
    sr(L, FK33_SEAM_ARGMAX, &L->g);
push:
    if (L->n_gen - L->out_ack >= OUT_DEPTH) { L->wait = W_OUT; return; }
    L->out[L->n_gen % OUT_DEPTH] = L->g; L->n_gen++;
    for (k = 0; k < 8; k++) if (L->stop[k] == L->g) { stop_(L, R_STOP_ID); return; }
    if (L->n_gen >= L->max_new) { stop_(L, R_MAX_NEW); return; }
    L->pos++;
  }
}

int jc_loop_rd(jc_loop *L, uint32_t off, uint32_t *v)
{
  uint32_t s;
  switch (off) {
  case 0x000: *v = 0x544C5031u; break;
  case 0x004: *v = 1; break;
  case 0x008: *v = (2u << 24) | (1u << 20) | (1u << 17) | (L->n & 0xFFFF); break;
  case 0x010:
    s = (uint32_t)L->state | (L->reason << 8) | ((uint32_t)L->owns << 16);
    if (L->wait == W_ROW) s |= 1u << 2;
    if (L->wait == W_TOKEN) s |= 1u << 3;
    if (L->crc_fails > L->cleared && L->wait == W_LINK) s |= (1u << 4) | (1u << 5);
    if (L->wait == W_OUT) s |= 1u << 7;
    if (L->wait == W_CREDIT) s |= 1u << 17;
    if (L->wait == W_LINK) s |= 1u << 18;
    *v = s; break;
  case 0x014: *v = L->pos; break;
  case 0x018: case 0x060: *v = L->n_gen; break;
  case 0x01C: *v = L->plen; break;
  case 0x020: *v = L->max_new; break;
  case 0x024: *v = L->row_src; break;
  case 0x028: *v = L->role; break;
  case 0x034: *v = L->resend_cap; break;
  case 0x044: *v = L->pos < L->plen ? L->prompt[L->pos] : L->g; break;
  case 0x048: *v = L->next_tok; break;
  case 0x064: *v = L->out_ack; break;
  case 0x068: *v = L->out_addr; break;
  case 0x06C: *v = L->out[L->out_addr % OUT_DEPTH]; L->out_addr++; break;
  case 0x074: *v = L->credit; break;
  case 0x078: *v = L->consumed; break;
  case 0x080: *v = 3u | (1u << 2) | (1u << 3); break;
  case 0x084: *v = L->frames_sent; break;
  case 0x088: *v = L->frames_good; break;
  case 0x08C: *v = L->crc_fails; break;
  case 0x090: *v = L->seqpos_bad; break;
  case 0x09C: *v = L->overruns; break;
  case 0x098: *v = L->resends; break;
  case 0x0AC: *v = L->kvmax; break;
  default:
    if (off >= 0x0C0 && off <= 0x0DC) { *v = L->stop[(off - 0x0C0) / 4]; break; }
    *v = 0;
  }
  return 0;
}

int jc_loop_wr(jc_loop *L, uint32_t off, uint32_t v)
{
  switch (off) {
  case 0x00C:
    if ((v & 1) && L->state != S_RUN) start(L);
    if ((v & 2) && L->state == S_RUN) stop_(L, R_ABORT);
    if ((v & 4) && L->has_held) {
      if (L->resends >= L->resend_cap) { stop_(L, R_RETRY_EXH); break; }
      L->resends++; L->sent_total = 0; L->drop_nth = 0; deliver(L, &L->held);
      if (L->peer) L->peer->cleared = L->peer->crc_fails;   /* B's pause clears on the good frame */
    }
    if ((v & 8) && L->wait == W_ROW) L->row_ready = 1;
    break;
  case 0x01C: L->plen = v; break;
  case 0x020: L->max_new = v; break;
  case 0x024: L->row_src = v & 3; break;
  case 0x028: L->role = v & 3; break;
  case 0x034: L->resend_cap = v; break;
  case 0x048: L->next_tok = v; L->next_v = 1; break;
  case 0x04C: L->row_exp = v; break;
  case 0x050: L->row_addr = v; break;
  case 0x054: if (L->row_addr < L->n) L->hrow[L->row_addr] = (uint16_t)v; L->row_addr++; break;
  case 0x058: L->prompt_addr = v; break;
  case 0x05C: if (L->prompt_addr < MAXP) L->prompt[L->prompt_addr] = v; L->prompt_addr++; break;
  case 0x064: L->out_ack = v; break;
  case 0x068: L->out_addr = v; break;
  case 0x074: L->credit = v; break;
  default:
    if (off >= 0x0C0 && off <= 0x0DC) L->stop[(off - 0x0C0) / 4] = v;
  }
  return 0;
}
