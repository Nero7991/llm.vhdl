/* ref/embed_bf16.h -- read ONE ROW of a BF16 tensor straight out of a GGUF.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * The embedding row is an ACTIVATION, not a weight.  It is the input to the
 * whole model, and until now every rung of the 9B reference read it out of the
 * PACKED INT4 set (`token_embd.weight.mv4i`) simply because it happened to be
 * packed alongside the weight tensors.  MEASURED by TRACK HOSTEMB over 48
 * corner-forced rows, both packed to int16 BFP by the same rule and both scored
 * against the BF16 GGUF row:
 *
 *     packed INT4 -> BFP int16   mean relerr 0.086295   worst 0.126667
 *     GGUF BF16   -> BFP int16   mean relerr 0.000048   worst 0.000425
 *
 * a factor of 1,803.  This track re-measured 2,151x on a DIFFERENT 48
 * corner-forced rows, with identical worst cases (0.126667 and 0.000425), so
 * the ratio is a property of the sample: read it as roughly two thousand.
 * Oren took the decision to upgrade.  The ORDER is the
 * whole safety property: `ref/run9b.c` moves FIRST and the host second, so the
 * reference never trails the thing it certifies.  See
 * `docs/debugging/2026-08-29_host-embedding-gather.md` section 5.2, which
 * recorded exactly this sequence, and
 * `docs/debugging/2026-08-29_embedding-bf16-upgrade.md` for the move itself.
 *
 * WHAT IT IS, AND WHAT IT IS NOT
 * ------------------------------
 * A minimal, self-contained GGUF v2/v3 header walker plus a `pread` of one row.
 * It is NOT a GGUF library: it reads the tensor table, finds ONE tensor BY
 * NAME, refuses anything that is not BF16 and 2-D, and then does nothing but
 * `pread(fd, row, 2*ne0, data_start + tensor_off + row*2*ne0)`.
 *
 * `pread`, NOT `mmap`, for the same reason `server/embed_mv4i.c` gives: the
 * read shape is then literally the one contiguous burst a driver would issue,
 * the per-token cost is visible in a counter, and an SBC does not map 1.9 GiB
 * to answer an 8 KiB question.  MEASURED resident cost of the whole provider is
 * in the write-up; it is a few hundred KiB, not 2.03 GB.  The 2.03 GB is
 * STORAGE.
 *
 * BF16 -> f32 IS EXACT AND IS NOT A CONVERSION CHOICE.  bfloat16 is the top 16
 * bits of an IEEE binary32, so widening is `(uint32_t)bits << 16` and there is
 * no rounding mode to get wrong.  A row read here is bit-identical to what
 * llama.cpp's own loader produces for the same row, and that is checked:
 * `tools/check_embed_bf16.py` compares against `model.input_embed` in a rung-1
 * anchor stream, which llama.cpp produced through a loader nobody here wrote.
 *
 * NOT VERIFIED: nothing here has run against the card, and nothing in this
 * tree may open /dev/xdma*.
 */
#ifndef EMBED_BF16_H
#define EMBED_BF16_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct emb_bf16_s emb_bf16_t;

/* The tensor this project always means. */
#define EMB_BF16_TENSOR "token_embd.weight"

/* Open `path` and locate `tensor` (NULL means EMB_BF16_TENSOR).
 * Returns 0, or negative with a message on stderr. */
int  emb_bf16_open(const char *path, const char *tensor, emb_bf16_t **out);
void emb_bf16_close(emb_bf16_t *e);

/* Row `row` as `n` float64.  `n` must equal the tensor's ne0; a mismatch is
 * REFUSED rather than truncated, because a short embedding row is a
 * plausible-looking wrong answer.  Returns 0 or negative. */
int  emb_bf16_row(emb_bf16_t *e, int row, double *dst, int n);

/* The same row as the raw 16-bit patterns, for a bit-exact comparison that
 * does not go through float at all. */
int  emb_bf16_row_raw(emb_bf16_t *e, int row, uint16_t *dst, int n);

int      emb_bf16_ne0(const emb_bf16_t *e);          /* row length  */
int64_t  emb_bf16_ne1(const emb_bf16_t *e);          /* row count   */
uint64_t emb_bf16_data_off(const emb_bf16_t *e);     /* absolute file offset of row 0 */
uint64_t emb_bf16_bytes_read(const emb_bf16_t *e);
uint64_t emb_bf16_gathers(const emb_bf16_t *e);
const char *emb_bf16_describe(const emb_bf16_t *e);

/* --------------------------------------------------------------- mutants
 * Named, deliberate defects, compiled in only under -DEMBED_BF16_MUTANTS so a
 * shipped binary cannot select one.  Each is a defect a careful person would
 * plausibly write while porting a GGUF reader.  Returns 0, or -1 if this build
 * has no mutants (which is the normal build). */
#define EMB_BF16_MUT_NONE       0
#define EMB_BF16_MUT_HALFSWAP   1  /* bf16 taken as the LOW half of the f32   */
#define EMB_BF16_MUT_ROWOFF     2  /* row + 1                                 */
#define EMB_BF16_MUT_NOBASE     3  /* tensor offset treated as absolute       */
#define EMB_BF16_MUT_NOALIGN    4  /* data assumed to start right after the
                                    * tensor table, alignment ignored         */
#define EMB_BF16_MUT_COLMAJOR   5  /* row read with stride ne1, not 1         */
#define EMB_BF16_MUT_FIRSTTENSOR 6 /* the tensor found by index 0 instead of
                                    * by name.  In this checkpoint that is
                                    * `output.weight`: SAME dtype, SAME 4096 x
                                    * 248320 shape.  No structural check in
                                    * this tree can see it.                   */
#define EMB_BF16_MUT_NOSIGN     7  /* the bf16 sign bit dropped               */
#define EMB_BF16_MUT_COUNT      8

int         emb_bf16_set_mutant(emb_bf16_t *e, int mutant);
const char *emb_bf16_mutant_name(int mutant);

#ifdef __cplusplus
}
#endif

#endif /* EMBED_BF16_H */
