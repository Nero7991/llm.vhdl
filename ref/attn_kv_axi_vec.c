/* ref/attn_kv_axi_vec.c -- the independent oracle for rtl/attn_kv_axi.vhd.
 *
 * WHAT THIS IS, AND WHAT MAKES IT INDEPENDENT
 * -------------------------------------------
 * A behavioural AXI slave that returns address-derived data proves the
 * ADDRESSING and nothing else: every burst split, every beat order and every
 * realignment phase would still return a self-consistent answer.  So this file
 * does not model AXI at all.  It models the two things AXI is the transport
 * for:
 *
 *   (a) the RECORD, as structured data -- NBLK int8 block exponents and
 *       HEAD_DIM int8 mantissas, built from a seeded LCG and held in an array
 *       indexed by (sel, layer, head, pos);
 *   (b) the LAYOUT, C spec 2.2's one equation, which places record
 *       (sel, layer, head, pos) at
 *           base[sel] + ((layer*N_KVH + head)*MAXCTX + pos) * REC_B
 *       with REC_B = 16 + HEAD_DIM (the 8 exponents padded to a 16-byte
 *       granule, then the mantissas) = 272 at the build geometry.
 *
 * It emits the memory IMAGE produced by (a) through (b), and -- separately,
 * from (a) alone -- the record contents the read port must deliver.  The RTL
 * gets only the image and must reconstruct (a).  That is the asymmetry: this
 * file owns the layout equation, the RTL owns the transport, and a transport
 * defect (wrong phase, wrong beat order, wrong burst split, wrong slot,
 * dropped beat) changes the reconstruction and is caught.
 *
 * The write side is checked the same way and in the opposite direction: the
 * bench hands the RTL four records as structured data through the kw_* port,
 * and this file emits the image those records MUST produce, byte for byte,
 * including the pad bytes and including every byte the write must NOT touch.
 * A write that used full strobes on the partially covered first or last beat
 * would corrupt a neighbouring record, and at 16-byte phase the neighbour is
 * real data, so that comparison is not decoration.
 *
 * WHAT IT DOES NOT COVER, stated here rather than discovered later:
 *   * the layout equation itself is SHARED with the RTL.  If C spec 2.2 were
 *     misread, both would be wrong together.  It is transcribed from the spec
 *     text, and the spec's own worked number (272 bytes per record) is
 *     re-derived here rather than copied.
 *   * the record's internal order (header chunk first, mantissas ascending,
 *     element d at byte d) is shared for the same reason.  It is pinned
 *     against rtl/attn_block.vhd's own packing: e_of(v,i) reads byte i of the
 *     header, and krec places element d at byte d.
 *   * byte order inside a 16-byte chunk is little-endian, matching AXI byte
 *     lanes.  Shared.
 *   * nothing here says anything about AXI timing, outstanding depth, or the
 *     drain rule.  Those are bench properties, not oracle properties.
 *
 * Usage:  attn_kv_axi_vec <file> [HEAD_DIM KV_BLOCK N_KVH LAYERS MAXCTX
 *                                 LAYER CUR_POS SEED]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned long long lcg_s;
static void lcg_seed(unsigned long long s){ lcg_s = s ? s : 1; }
static unsigned lcg_u32(void){
  lcg_s = lcg_s * 6364136223846793005ULL + 1442695040888963407ULL;
  return (unsigned)(lcg_s >> 33);
}
/* int8 in [-128, 127] */
static int rnd8(void){ return (int)(lcg_u32() & 0xFF) - 128; }

int main(int argc, char **argv)
{
  int HEAD_DIM = 256, KV_BLOCK = 32, N_KVH = 2, LAYERS = 2, MAXCTX = 32;
  int LAYER = 1, CUR_POS = 20;
  unsigned long long SEED = 20260828ULL;
  const char *out = (argc > 1) ? argv[1] : "attn_kv_axi_vec.txt";

  if (argc > 2) HEAD_DIM = atoi(argv[2]);
  if (argc > 3) KV_BLOCK = atoi(argv[3]);
  if (argc > 4) N_KVH    = atoi(argv[4]);
  if (argc > 5) LAYERS   = atoi(argv[5]);
  if (argc > 6) MAXCTX   = atoi(argv[6]);
  if (argc > 7) LAYER    = atoi(argv[7]);
  if (argc > 8) CUR_POS  = atoi(argv[8]);
  if (argc > 9) SEED     = strtoull(argv[9], 0, 0);

  const int NBLK  = HEAD_DIM / KV_BLOCK;
  const int CH_B  = 16;                     /* the record granule */
  const int REC_B = CH_B + HEAD_DIM;        /* 272 at the build geometry */
  const int CTX   = CUR_POS + 1;            /* ctx_len */

  if (HEAD_DIM % KV_BLOCK) { fprintf(stderr, "HEAD_DIM %% KV_BLOCK\n"); return 2; }
  if (NBLK > CH_B)         { fprintf(stderr, "NBLK > 16\n"); return 2; }
  if (HEAD_DIM % CH_B)     { fprintf(stderr, "HEAD_DIM %% 16\n"); return 2; }
  if (CUR_POS >= MAXCTX)   { fprintf(stderr, "CUR_POS >= MAXCTX\n"); return 2; }
  if (LAYER >= LAYERS)     { fprintf(stderr, "LAYER >= LAYERS\n"); return 2; }

  /* ---- (a) the records, as STRUCTURED data --------------------------- */
  const int NREC = 2 * LAYERS * N_KVH * MAXCTX;
  signed char *hdr  = malloc((size_t)NREC * NBLK);
  signed char *mant = malloc((size_t)NREC * HEAD_DIM);
  if (!hdr || !mant) { fprintf(stderr, "oom\n"); return 2; }

  lcg_seed(SEED);
  for (int i = 0; i < NREC; i++) {
    for (int b = 0; b < NBLK; b++)     hdr[(size_t)i*NBLK + b]  = (signed char)rnd8();
    for (int d = 0; d < HEAD_DIM; d++) mant[(size_t)i*HEAD_DIM + d] = (signed char)rnd8();
  }
#define RIDX(sel,lay,hd,ps) \
  ((((sel)*LAYERS + (lay))*N_KVH + (hd))*MAXCTX + (ps))

  /* ---- (b) the layout, C spec 2.2 ------------------------------------ */
  const long long KREG   = (long long)LAYERS * N_KVH * MAXCTX * REC_B;
  const long long KBASE  = 0x20030LL;            /* 16-aligned, NOT 4 KB */
  const long long VBASE  = KBASE + KREG + CH_B;  /* the other 32-byte phase */
  const long long IMGB   = KBASE - 32;           /* slack for a beat-aligned
                                                    burst below record 0 */
  const long long IMGEND = VBASE + KREG + 32;
  const long long IMGB_B = IMGEND - IMGB;
  const int NCH = (int)(IMGB_B / CH_B);

  unsigned char *img = calloc((size_t)IMGB_B, 1);
  unsigned char *exp = 0;
  if (!img) { fprintf(stderr, "oom\n"); return 2; }

  /* record byte offsets: [0 .. NBLK)   block exponents
   *                      [NBLK .. 16)  pad, zero
   *                      [16 .. 16+HEAD_DIM)  mantissas, element d at byte d
   * matching rtl/attn_block.vhd's own packing (e_of reads byte i of the
   * header; krec places element d at byte d).                              */
  for (int sel = 0; sel < 2; sel++)
    for (int lay = 0; lay < LAYERS; lay++)
      for (int hd = 0; hd < N_KVH; hd++)
        for (int ps = 0; ps < MAXCTX; ps++) {
          long long a = (sel ? VBASE : KBASE)
                      + (long long)(((lay*N_KVH + hd)*MAXCTX) + ps) * REC_B;
          int i = RIDX(sel, lay, hd, ps);
          unsigned char *p = img + (a - IMGB);
          for (int b = 0; b < NBLK; b++)     p[b]         = (unsigned char)hdr[(size_t)i*NBLK + b];
          for (int b = NBLK; b < CH_B; b++)  p[b]         = 0;
          for (int d = 0; d < HEAD_DIM; d++) p[CH_B + d]  = (unsigned char)mant[(size_t)i*HEAD_DIM + d];
        }

  /* ---- the four records the bench WRITES through kw_* ----------------- */
  /* They are the current position's K and V for each KV head, which is what
   * attn_block writes: one quantized record per (KV head, K|V) per token.  */
  const int NW = 2 * N_KVH;
  signed char *whdr  = malloc((size_t)NW * NBLK);
  signed char *wmant = malloc((size_t)NW * HEAD_DIM);
  int *wsel = malloc((size_t)NW*sizeof(int)), *whd = malloc((size_t)NW*sizeof(int));
  if (!whdr || !wmant || !wsel || !whd) { fprintf(stderr, "oom\n"); return 2; }
  {
    int w = 0;
    for (int hd = 0; hd < N_KVH; hd++)
      for (int sel = 0; sel < 2; sel++) {
        wsel[w] = sel; whd[w] = hd;
        for (int b = 0; b < NBLK; b++)     whdr[(size_t)w*NBLK + b]      = (signed char)rnd8();
        for (int d = 0; d < HEAD_DIM; d++) wmant[(size_t)w*HEAD_DIM + d] = (signed char)rnd8();
        w++;
      }
  }
  exp = malloc((size_t)IMGB_B);
  if (!exp) { fprintf(stderr, "oom\n"); return 2; }
  memcpy(exp, img, (size_t)IMGB_B);
  for (int w = 0; w < NW; w++) {
    long long a = (wsel[w] ? VBASE : KBASE)
                + (long long)(((LAYER*N_KVH + whd[w])*MAXCTX) + CUR_POS) * REC_B;
    unsigned char *p = exp + (a - IMGB);
    for (int b = 0; b < NBLK; b++)     p[b]        = (unsigned char)whdr[(size_t)w*NBLK + b];
    for (int b = NBLK; b < CH_B; b++)  p[b]        = 0;
    for (int d = 0; d < HEAD_DIM; d++) p[CH_B + d] = (unsigned char)wmant[(size_t)w*HEAD_DIM + d];
  }

  /* ---- the read request list ------------------------------------------ */
  /* The sweep C spec 3.1 pins: for each KV head, positions 0 .. cur_pos-1 in
   * ASCENDING order, K then V at each position.  cur_pos itself is bypassed
   * from registers by attn_block and is never read (C spec 2.4), so it does
   * not appear here.  Four backward jumps are appended: they are NOT part of
   * the sweep, and they exist to force the retarget path.                  */
  const int NR = 2*N_KVH*CUR_POS + 4;
  int *rsel = malloc((size_t)NR*sizeof(int));
  int *rhd  = malloc((size_t)NR*sizeof(int));
  int *rps  = malloc((size_t)NR*sizeof(int));
  if (!rsel || !rhd || !rps) { fprintf(stderr, "oom\n"); return 2; }
  {
    int r = 0;
    for (int hd = 0; hd < N_KVH; hd++)
      for (int ps = 0; ps < CUR_POS; ps++) {
        rsel[r]=0; rhd[r]=hd; rps[r]=ps; r++;
        rsel[r]=1; rhd[r]=hd; rps[r]=ps; r++;
      }
    int bj[4][3] = { {0,0,3}, {1,0,3}, {0,N_KVH-1,7}, {1,N_KVH-1,7} };
    for (int k = 0; k < 4; k++) {
      if (bj[k][2] >= CUR_POS) bj[k][2] = 0;
      rsel[r]=bj[k][0]; rhd[r]=bj[k][1]; rps[r]=bj[k][2]; r++;
    }
  }

  /* ---- emit ------------------------------------------------------------ */
  FILE *f = fopen(out, "w");
  if (!f) { perror(out); return 2; }
  fprintf(f, "KVAXI 1\n");
  fprintf(f, "%d %d %d %d %d\n", HEAD_DIM, KV_BLOCK, N_KVH, LAYERS, MAXCTX);
  fprintf(f, "%d %d %d\n", LAYER, CUR_POS, CTX);
  fprintf(f, "%lld %lld %lld %d\n", IMGB, KBASE, VBASE, NCH);

  fprintf(f, "IMG\n");
  for (int c = 0; c < NCH; c++) {
    for (int b = CH_B-1; b >= 0; b--) fprintf(f, "%02x", img[(size_t)c*CH_B + b]);
    fputc('\n', f);
  }
  fprintf(f, "EXPIMG\n");
  for (int c = 0; c < NCH; c++) {
    for (int b = CH_B-1; b >= 0; b--) fprintf(f, "%02x", exp[(size_t)c*CH_B + b]);
    fputc('\n', f);
  }

  fprintf(f, "NW %d\n", NW);
  for (int w = 0; w < NW; w++) {
    fprintf(f, "%d %d %d\n", wsel[w], whd[w], CUR_POS);
    for (int b = 0; b < NBLK; b++) fprintf(f, "%d ", whdr[(size_t)w*NBLK + b]);
    fputc('\n', f);
    for (int b = 0; b < NBLK; b++) {
      for (int e = 0; e < KV_BLOCK; e++)
        fprintf(f, "%d ", wmant[(size_t)w*HEAD_DIM + b*KV_BLOCK + e]);
      fputc('\n', f);
    }
  }

  fprintf(f, "NR %d\n", NR);
  for (int r = 0; r < NR; r++) {
    int i = RIDX(rsel[r], LAYER, rhd[r], rps[r]);
    fprintf(f, "%d %d %d\n", rsel[r], rhd[r], rps[r]);
    for (int b = 0; b < NBLK; b++) fprintf(f, "%d ", hdr[(size_t)i*NBLK + b]);
    fputc('\n', f);
    for (int b = 0; b < NBLK; b++) {
      for (int e = 0; e < KV_BLOCK; e++)
        fprintf(f, "%d ", mant[(size_t)i*HEAD_DIM + b*KV_BLOCK + e]);
      fputc('\n', f);
    }
  }
  fprintf(f, "END\n");
  fclose(f);

  fprintf(stderr,
    "attn_kv_axi_vec: HEAD_DIM=%d KV_BLOCK=%d NBLK=%d REC_B=%d "
    "N_KVH=%d LAYERS=%d MAXCTX=%d layer=%d cur_pos=%d ctx_len=%d\n"
    "  k_base=%lld v_base=%lld img_base=%lld chunks=%d bytes=%lld\n"
    "  %d records written, %d records read (%d mantissa blocks, %d elements)\n",
    HEAD_DIM, KV_BLOCK, NBLK, REC_B, N_KVH, LAYERS, MAXCTX, LAYER, CUR_POS, CTX,
    KBASE, VBASE, IMGB, NCH, IMGB_B,
    NW, NR, NR*NBLK, NR*HEAD_DIM);
  return 0;
}
