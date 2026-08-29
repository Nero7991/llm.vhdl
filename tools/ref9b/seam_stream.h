/* tools/ref9b/seam_stream.h -- the one on-disk format every 9B reference,
 * simulation capture and hardware capture writes.
 *
 * WHY A SHARED FORMAT AND NOT A DIFF SCRIPT PER PRODUCER.  The whole point of
 * this track is that when the card is wrong, the FIRST wrong seam is located
 * rather than guessed.  A bisect can only be written once if every producer
 * emits records that are comparable without knowing which producer wrote them.
 * So the format carries the seam identity (token, layer, name), the numeric
 * kind, and nothing about who wrote it.
 *
 * DELIBERATELY NOT A FLOAT-ONLY FORMAT.  Subsystem A's output is block
 * floating point: an int16 mantissa vector plus one shared exponent, and the
 * value is `mant * 2^-exp` (note the SIGN: tools/pack_int4.py:14 defines
 * `w = cb * (scale/2^15) * 2^-w_exp`, so the exponents in this project are
 * NEGATIVE powers).  A BFP seam recorded as float has already thrown away the
 * only thing that can be compared bit-exactly.  So a record is either F32 or
 * BFP16, the reader knows which, and a BFP-to-BFP comparison is exact while a
 * BFP-to-F32 comparison degrades to a tolerance and SAYS SO.
 *
 * Layout, little-endian throughout (every machine in this project is x86-64 or
 * a GHDL run on one; the format asserts the magic rather than claiming
 * portability it has not been tested for):
 *
 *   file   := "R9BS" u32ver=1 record*
 *   record := u32 name_len          (bytes, no NUL)
 *             u32 n                 (element count)
 *             i32 tok               (token index within the sequence)
 *             i32 layer             (-1 for whole-model seams)
 *             i32 kind              (0 = F32, 1 = BFP16)
 *             i32 exp               (BFP: value = mant * 2^-exp; F32: 0)
 *             char name[name_len]
 *             payload               (kind 0: n * f32; kind 1: n * i16)
 *
 * No padding and no alignment guarantee: the reader memcpys.
 */
#ifndef REF9B_SEAM_STREAM_H
#define REF9B_SEAM_STREAM_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define R9BS_MAGIC   "R9BS"
#define R9BS_VERSION 1u

enum { R9BS_KIND_F32 = 0, R9BS_KIND_BFP16 = 1 };

typedef struct {
    uint32_t name_len, n;
    int32_t  tok, layer, kind, exp;
} r9bs_rec_hdr;

static inline int r9bs_write_header(FILE *fp)
{
    uint32_t v = R9BS_VERSION;
    if (fwrite(R9BS_MAGIC, 1, 4, fp) != 4) return -1;
    if (fwrite(&v, sizeof v, 1, fp) != 1)  return -1;
    return 0;
}

static inline int r9bs_write_f32(FILE *fp, const char *name, int tok, int layer,
                                 const float *v, uint32_t n)
{
    r9bs_rec_hdr h;
    h.name_len = (uint32_t)strlen(name);
    h.n = n; h.tok = tok; h.layer = layer;
    h.kind = R9BS_KIND_F32; h.exp = 0;
    if (fwrite(&h, sizeof h, 1, fp) != 1) return -1;
    if (fwrite(name, 1, h.name_len, fp) != h.name_len) return -1;
    if (n && fwrite(v, sizeof(float), n, fp) != n) return -1;
    return 0;
}

static inline int r9bs_write_bfp(FILE *fp, const char *name, int tok, int layer,
                                 const int16_t *m, uint32_t n, int exp)
{
    r9bs_rec_hdr h;
    h.name_len = (uint32_t)strlen(name);
    h.n = n; h.tok = tok; h.layer = layer;
    h.kind = R9BS_KIND_BFP16; h.exp = exp;
    if (fwrite(&h, sizeof h, 1, fp) != 1) return -1;
    if (fwrite(name, 1, h.name_len, fp) != h.name_len) return -1;
    if (n && fwrite(m, sizeof(int16_t), n, fp) != n) return -1;
    return 0;
}

#endif /* REF9B_SEAM_STREAM_H */
