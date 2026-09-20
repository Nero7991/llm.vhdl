/* server/fk33_imglock.h -- WHICH PACKED IMAGE IS ON THE CARD, read back out
 * of HBM, so the host cannot drive a manifest that does not describe it.
 *
 * WHY THIS EXISTS.  MEASURED 2026-09-20, and it cost 35 weight objects.  The
 * card held the lane-striped image; the chat script defaulted to the FLAT
 * one.  Both manifests declare `desc_arena_base = 0x1ffadd000`, the SAME
 * address, so the flat descriptor table overwrote the striped one; and
 * `pl_open()` programmed the FLAT `kv_base = 0x10d93e000` into the KV seam
 * register, so subsystem C wrote 24 positions of KV records into the striped
 * WEIGHT image.  Intersecting the flat KV slot grid at C_MAXPOS = 65536
 * against the striped pieces predicts those 35 objects exactly: 0 missed, 0
 * extra.
 *
 * Until that morning a mismatched manifest only MISADDRESSED READS.  Making
 * C's KV base a host-programmed register is what made the striped image
 * runnable and delivered 2.04x, and it is also what turned this class from a
 * wrong answer into data loss.  This header is the guard that change needed.
 *
 * THE RECORD.  `hw/fk33/host/fk33_load_weights.py load` writes 512 bytes into
 * the last 512 bytes of the descriptor arena extent the manifest declares --
 * `desc_arena_base + desc_arena_bytes - 512` -- after every object has been
 * written and hashed, and ZEROES it before the first byte moves.  So a load
 * that dies half way leaves "no image", which is a refusal, rather than a
 * record describing an image that is only partly there.
 *
 * That address is already RESERVED (tools/hbm_map.py carries the arena as a
 * region and checks it disjoint from all four allocators) and NOTHING WRITES
 * IT: subsystem A reads descriptor i at base + i*stride for i < jobs, and the
 * arena image the host loads is exactly jobs*stride bytes.  See the long
 * argument, including the alternatives that were measured and rejected, in
 * `hw/fk33/host/fk33_imgfp.py`.
 *
 * WHAT THIS FILE CHECKS AND WHAT IT DOES NOT.  It compares the eleven REGION
 * numbers -- the ones `fk33_manifest_read()` already parses -- field by
 * field, so the error names the field that disagrees.  It does NOT recompute
 * the placement fingerprint over the 250 file entries; that needs a JSON
 * walk this host has no reason to carry, and `fk33_imgfp.py check` does it on
 * the Python side.  The two halves are not redundant: the region block is
 * what separates the two STRIPED images (which place every weight piece
 * identically and differ only in the GDN state and KV regions), and the piece
 * list is what separates flat from striped without reading HBM.
 *
 * NO HARDWARE.  Nothing here opens anything; the caller hands it 512 bytes it
 * already read through its own transport.
 */
#ifndef FK33_IMGLOCK_H
#define FK33_IMGLOCK_H

#include <stddef.h>
#include <stdint.h>

#include "fk33_manifest.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FK33_IMGLOCK_BYTES     512u
#define FK33_IMGLOCK_VERSION   1u
#define FK33_IMGLOCK_PATH_MAX  240u

/* The eleven region numbers, in the record's own order.  The same order and
 * the same names live in hw/fk33/host/fk33_imgfp.py::REGION_FIELDS, and
 * `fk33_imgfp.py selfcheck` compiles THIS FILE and makes it answer, because a
 * mirror is not evidence. */
typedef struct {
    uint32_t version;
    unsigned char fp[16];          /* the placement fingerprint, carried not checked */
    uint64_t size;
    uint64_t weights_end;
    uint64_t gdn_state_base;
    uint64_t gdn_state_bytes;
    uint64_t kv_base;
    uint64_t kv_bytes_per_token;
    uint64_t gdn_const_base;
    uint64_t gdn_const_bytes;
    uint64_t desc_arena_base;
    uint64_t desc_arena_bytes;
    uint64_t host_max_chunk;
    uint64_t when;                 /* unix time of the load that wrote it */
    uint32_t objs_loaded;
    uint32_t objs_total;
    uint64_t bytes_loaded;
    char     manifest_path[FK33_IMGLOCK_PATH_MAX];
} fk33_imglock_rec;

/* Where the record lives for this manifest.  Returns 0 if the manifest does
 * not reserve enough arena to hold one, which is a refusal, not an address. */
uint64_t fk33_imglock_addr(const fk33_manifest *m);

/* Parse FK33_IMGLOCK_BYTES of HBM.  Returns 0, or:
 *   -1 the 512 bytes are all zero: NO IMAGE has been recorded here
 *   -2 the magic is not a record at all
 *   -3 a version this host does not speak
 *   -4 the checksum or the tail magic disagrees: a TORN or PARTIAL write
 * Every non-zero return is ABSENT, and absent is a refusal wherever it
 * matters.  There is no partial success. */
int fk33_imglock_parse(const unsigned char *buf, size_t len,
                       fk33_imglock_rec *r);

/* Human-readable form of a fk33_imglock_parse() return code. */
const char *fk33_imglock_why(int rc);

/* The inverse of fk33_imglock_parse: lay `r` out as FK33_IMGLOCK_BYTES of
 * record, magic, checksum and tail included.  `len` must be
 * FK33_IMGLOCK_BYTES; returns 0 or -1.
 *
 * IT EXISTS FOR THE TESTS AS MUCH AS FOR ANY TOOL, and that is the point:
 * `hw/fk33/host/fk33_imgfp.py selfcheck` runs the cross-check BOTH WAYS --
 * Python packs and C parses, then C packs and Python compares the bytes --
 * so neither side can drift into a layout the other does not read. */
int fk33_imglock_pack(const fk33_imglock_rec *r, unsigned char *buf,
                      size_t len);

/* Fill `r` from a manifest: the eleven region numbers and nothing else.  The
 * placement fingerprint is NOT computable here (it is over the 250 file
 * entries) and is left zero for the caller to fill. */
void fk33_imglock_from_manifest(const fk33_manifest *m, fk33_imglock_rec *r);

/* Compare the resident record with the manifest this host was handed.
 * Returns the number of fields that disagree (0 = the same image), and
 * writes a multi-line, human-readable account into `why` naming each one. */
int fk33_imglock_compare(const fk33_imglock_rec *r, const fk33_manifest *m,
                         char *why, size_t nwhy);

/* FNV-1a 64 over `len` bytes.  TEAR DETECTION ONLY, and deliberately the
 * simplest thing that is identical in C and in Python: a real digest on both
 * sides would be a second implementation that can disagree, which is this
 * project's recorded `m7 mutant` failure. */
uint64_t fk33_imglock_fnv1a64(const unsigned char *p, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* FK33_IMGLOCK_H */
