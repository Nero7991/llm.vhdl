/* server/fk33_manifest.h -- read the HBM residency numbers out of a packed
 * set's `manifest.json`, so the host's scratch addresses are DERIVED from the
 * image that is actually loaded rather than typed in.
 *
 * WHY THIS EXISTS.  `pl_open_opts` used to carry three hardcoded bases:
 * `x_base = 0x00E0000000`, `l_base = 0x00E1000000`, `desc_ptr = 0x00E2000000`.
 * 0xE000_0000 is 3.5 GiB, and the weight image runs from 0 to `weights_end`,
 * which is 0x12F203000 in the shipped `qkvpad` set and 0x10C006000 in the
 * post-drop `noembd` set.  All three sat INSIDE the weights, in BOTH sets.
 * TRACK EMBDROP found this and reported it (its section 8 item 3); it is not
 * caused by the drop, the drop only changes the number they have to clear.
 *
 * The fix is not a bigger constant.  A hardcoded address that happened to be
 * wrong is being replaced, and a hardcoded address that happens to be right
 * today is not much better: `kv_base` moved 0x1_33A0_3000 -> 0x1_1080_6000 with
 * the drop, so every address downstream of the image moves when the image does.
 * So: the bases are DERIVED from the shape (n_embd, n_vocab, max_chunk) and the
 * HBM size, allocated top-down; and when a manifest is supplied they are also
 * CHECKED against the image's real extent, and an explicit base that overlaps
 * it is REFUSED at open time rather than silently corrupting weights.
 *
 * WHAT THIS PARSER IS.  A narrow, strict scanner for the top-level `"hbm"`
 * object of the manifest `tools/pack_model_fk33.py` writes.  It is NOT a JSON
 * library and does not try to be: it tracks string literals and escapes so
 * brace counting is correct, refuses anything it does not recognise, and
 * requires every key it needs to be present.  A general parser would be more
 * code and would still have to be told which keys matter.
 *
 * NO HARDWARE.  This opens one ordinary file read-only.
 */
#ifndef FK33_MANIFEST_H
#define FK33_MANIFEST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t size;                /* hbm.size, the whole device            */
    uint64_t align;
    uint64_t stack_bytes;         /* the 4 GiB stack line                  */
    uint64_t weights_bytes;
    uint64_t weights_end;         /* first byte past the weight image      */
    uint64_t gdn_state_base;
    uint64_t gdn_state_bytes;
    uint64_t kv_base;             /* first byte past GDN state             */
    uint64_t kv_bytes_per_token;
    uint64_t max_context_tokens;

    /* REQUIRED as of 2026-08-29.  The manifest is the AUTHORITY for the
     * subsystem A descriptor arena, and for the max_chunk the host blocks were
     * placed under.
     *
     * The collision TRACK WEIGHTS measured: `tools/gen_layer_program.py` and
     * `pl_derive_bases()` both anchored at the top of the device and neither
     * could see the other, so 153,664 B of the logits writeback sat under the
     * A descriptors and the symptom was a wrong token with no fault.  TRACK
     * ADDRARENA built one model of the address space and left the MECHANISM
     * open, implementing both.  Oren chose this one: a region block in the
     * manifest states every base, `tools/pack_model_fk33.py` writes it once at
     * pack time, and neither consumer invents an address.
     *
     * These were OPTIONAL for exactly one day, and the optionality was the
     * defect: a missing key read as zero, zero read as "no arena declared",
     * and "no arena declared" was protected by a printed warning.  A warning
     * that reads as "checked" is how the original collision survived.  They
     * are required now, so a set packed before the block existed is REFUSED
     * with a message naming the migration:
     *
     *     python3 tools/hbm_map.py <manifest> --write-manifest-hbm
     *
     * `host_max_chunk` is here because max_chunk comes from the card's CAPS
     * and a larger one drags x_base DOWN through a fixed arena.  Nothing
     * constrained it before; pinning it makes a mismatched card a refusal at
     * open time instead of an overlap discovered later. */
    uint64_t desc_arena_base;
    uint64_t desc_arena_bytes;
    uint64_t host_max_chunk;

    /* DERIVED here, not read: the first address the host may place a block at
     * without landing on something the card owns.  max of the three ends. */
    uint64_t reserved_end;

    char path[512];
} fk33_manifest;

/* Returns 0, or negative with a message on stderr.  Every field above except
 * `reserved_end` and `path` must be present in the file; a missing one is an
 * error, because a zero would read as "no constraint" and that is exactly the
 * failure this file exists to prevent. */
int fk33_manifest_read(const char *path, fk33_manifest *m);

/* Human-readable one-liner, into `buf`. */
const char *fk33_manifest_describe(const fk33_manifest *m, char *buf, size_t n);

#ifdef __cplusplus
}
#endif

#endif /* FK33_MANIFEST_H */
