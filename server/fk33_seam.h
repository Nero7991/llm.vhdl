/* fk33_seam.h -- THE HOST/CARD SEAM.  What crosses the PCIe boundary, in
 * which direction, in what units, and who owns each piece of state.
 *
 * The prose version, with the derivations and the rejected alternatives, is
 * docs/2026-08-29_host-card-seam.md.  This file is the machine-readable half
 * and the two must agree; where they do not, this file wins, because this one
 * is compiled.
 *
 * =====================================================================
 * READ THIS FIRST: THE ENGINE DESCRIBED BELOW DOES NOT EXIST
 * =====================================================================
 * Everything in this header is a CONTRACT, not a report.  As of 2026-08-29:
 *
 *   * The composed FK33 design does not route (OI-12, global congestion
 *     level 7).  There is no bitstream that contains a transformer.
 *   * `rtl/llama_top.vhd:133-134` says in its own words that there is no
 *     sampler and no lm_head output: the final A job is issued with
 *     `dst = R_NONE` and its result is DISCARDED.  Nothing anywhere returns
 *     logits to a host.
 *   * The only numeric egress that exists on the card today is subsystem A's
 *     `Y_IDX`/`Y_LO`/`Y_HI`/`Y_EXP` MMIO readback, one result row per four
 *     non-posted BAR reads.  At the 9B vocabulary that is 248,320 rows ~=
 *     993,280 MMIO reads per token; at the 1-2 us per BAR read the token-I/O
 *     document estimates, that is 1.0-2.0 SECONDS per token against a 38.27 ms
 *     token budget.  It is not a slow seam, it is not a seam.
 *   * `rtl/embed.vhd` and `rtl/lm_head.vhd` are still the 512-entry, 64-dim
 *     stories260K ROMs.
 *
 * So this header defines the boundary the card must meet, and
 * server/fk33_sim.c implements a model of it so the host side can be built,
 * mutated and gated now.  A register offset below marked PROPOSED is a
 * request to `hw/fk33/gen_pcieep.py`, which this track does not own and which
 * is the only file that can actually decide it.
 *
 * =====================================================================
 * THE SHAPE OF THE SEAM, AND WHY IT MOVED
 * =====================================================================
 * The AXU3EG seam (server/pl_backend.h before this commit) was
 * GENERATION-level: hand the card a prompt, get a token stream back.  That
 * was correct there and it is wrong here, and the reason is not preference:
 *
 *   AXU3EG                            FK33
 *   -----------------------------     ------------------------------------
 *   PS on the same die                no PS at all; the host is a real host
 *   engine ran the whole loop         host must own the loop
 *   argmax in the fabric, no logits   a sampler still cannot see top_p
 *   MAXPOS 24 positions, 512 vocab    198,415-token KV capacity, 248,320 vocab
 *   /dev/mem mmap, ~ns per access     PCIe, ~1-2 us per non-posted BAR read
 *
 * The last row is the one that forces the shape.  On the AXU3EG a per-token
 * host round trip cost nothing, so putting the loop in the fabric bought
 * nothing and cost the sampler.  Over PCIe a round trip is ~20-40 us against a
 * 38.27 ms token, i.e. ~0.1%, so the host CAN own the loop -- and once it
 * does, temperature, top_p, seeds, stop strings, logit bias, speculative
 * decoding and multi-sequence batching are all free, in software, where they
 * can be tested.
 *
 * So: PREFILL, then DECODE RETURNING LOGITS.
 *
 * =====================================================================
 * OWNERSHIP.  Every piece of state has exactly one owner.
 * =====================================================================
 * HOST owns, and the card never sees:
 *   the text, the chat template rendering, the token ids, the sampler
 *   (temperature/top_p/seed/logit bias), stop-string matching, detokenization,
 *   the request queue, and the SEQUENCE POSITION BOOKKEEPING -- which position
 *   each step occupies, when a sequence is abandoned, and when the KV cache
 *   must be reset.  The host also owns the EMBEDDING GATHER: it reads the
 *   packed embedding row for a token id, dequantizes and BFP-packs it, and
 *   DMAs the result in.  (`docs/2026-08-28_token-io-path.md` costs this at
 *   6-35 us per token, 0.016%-0.091% of a token, and decides it on the HBM
 *   port budget -- A already takes 27 of the 30 engine ports -- not on
 *   latency.)
 *
 * CARD owns, and the host never sees:
 *   the weights, the descriptor program's execution, the 32 transformer
 *   blocks, and THE KV CACHE.  KV never crosses PCIe: 17,408 bytes per token
 *   per the residency map, and moving it would be the whole link budget.  The
 *   host's only KV verb is "reset", and its only KV noun is a position index.
 *
 * CROSSES, per decoded position:
 *   host -> card   one BFP-packed activation row: n_embd int16 mantissas plus
 *                  one i32 block exponent.  8,208 bytes at n_embd 4096.
 *   card -> host   n_vocab int32 logits plus one i32 shared block exponent,
 *                  993,296 bytes at n_vocab 248,320.  OR, when the caller
 *                  wants greedy only, four bytes: the argmax id the card's
 *                  running sampler produced anyway.
 *
 * DERIVED, at the measured link rates (H2C 3.27 GB/s, C2H 1.11 GB/s, both
 * from `docs/debugging/2026-08-28_fk33-first-light.md:141`):
 *   host -> card   8,208 B / 3.27e9 B/s  = 2.51 us
 *   card -> host   993,296 B / 1.11e9 B/s = 894.9 us
 * against the 38.27 ms/token budget in `docs/2026-08-28_token-io-path.md`:
 *   full logits    2.34% of a token
 *   argmax only    ~0%
 * So returning full logits is affordable and returning them is the default.
 * ESTIMATE, and the assumption is stated: it treats the 1 GB-transfer rate as
 * the 1 MB-transfer rate.  NO SMALL-TRANSFER LATENCY HAS EVER BEEN MEASURED
 * ON THIS CARD (`docs/2026-08-28_token-io-path.md` says so explicitly), so the
 * per-transfer setup cost is unmodelled and the real figure is worse.  It is
 * the first thing to measure when a card can answer.
 *
 * =====================================================================
 * TWO BLOCKS IN HBM, AND THEIR BYTE LAYOUTS
 * =====================================================================
 * The activation block, at X_BASE.  N_STEP entries, stride FK33_X_STRIDE:
 *
 *     +0x00  i32   x_exp        the row's BFP block exponent
 *     +0x04  u32   token_id     informational.  The card does NOT gather;
 *                               this is here so a card-side trace can be
 *                               correlated with a host-side one, and so a
 *                               mismatched sequence is detectable.
 *     +0x08  u64   0            reserved, MUST be zero
 *     +0x10  i16 * n_embd       mantissas, little-endian
 *
 * The logits block, at L_BASE.  1 entry (or N_STEP with FK33_CTRL_LOGITS_ALL),
 * stride FK33_L_STRIDE:
 *
 *     +0x00  i32   logit_exp    ONE shared exponent for the whole row.  This
 *                               is not a simplification: `matvec_core.vhd`
 *                               gives `y_exp = w_exp + x_exp - out_shift` in
 *                               RAW out_mode with no per-job term, which is
 *                               exactly why the lm_head's 15 row windows must
 *                               run in RAW and why a plain signed int32
 *                               compare is a correct argmax across them.
 *     +0x04  i32   argmax       the card's own running argmax over the row.
 *     +0x08  u64   0            reserved, MUST be zero
 *     +0x10  i32 * n_vocab      logits
 *
 * Both strides are round_up(16 + elem_bytes, 64).  64 rather than 4096: these
 * are not subsystem-A weight bases (whose 4096-byte alignment is
 * `rtl/axi_rd_port.vhd`'s contract and is checked as ERR_ALIGN), they are
 * ordinary activation traffic, and 64 is two 256-bit AXI beats.
 *
 * BOTH BLOCKS MUST LIE IN ONE HBM STACK.  A port on SAXI_01..15 reaches only
 * 0x0_0000_0000..0x0_FFFF_FFFF and one on SAXI_17..31 only the upper half,
 * with no cross-stack path, and the residency map records that putting bytes
 * in the wrong half is a SILENT WRONG ANSWER -- it reads back correctly over
 * the host port and is wrong only when the engine's port fetches it.
 * fk33_seam_check_blocks() below is the explicit host-side assertion that
 * document asks for.
 *
 * =====================================================================
 * WHAT THIS SEAM DELIBERATELY DOES NOT DO
 * =====================================================================
 *  * It does not sample on the card.  `rtl/sampler_stream.vhd` exists and is
 *    verified, and its argmax is exposed above as a fast path, but the seam
 *    does not depend on it.
 *  * It does not batch.  N_STEP > 1 is a PREFILL CHUNK of one sequence, not
 *    independent sequences.  Multi-sequence batching needs a KV partition
 *    concept the card does not have.
 *  * It does not carry the descriptor program.  DESC_PTR points at a program
 *    already resident in HBM; building that program is OI-4 and belongs to
 *    `tools/gen_layer_program.py`, not here.
 *  * It does not move weights.  Those are loaded once at cold start by
 *    mem_write and never again.
 */
#ifndef FK33_SEAM_H
#define FK33_SEAM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * The seam register block.
 *
 * BASE IS PROPOSED, NOT DECIDED.  `hw/fk33/gen_pcieep.py` configures the block
 * design and therefore owns every BAR offset; this track does not own that
 * file.  0xE000 is chosen because it is the largest 4 KB hole below the
 * scratch BRAM that is not already taken: MEASURED occupancy of the 128 KB BAR
 * from hw/fk33/host/fk33_regs.h and the bring-up procedure is 0x3400 (SYSMON),
 * 0x9000 (GPIO), 0xA000 (ID), 0xB000/0xC000/0xD000 (thermal) and
 * 0x10000+0x2000 (scratch).
 * ------------------------------------------------------------------------- */
#define FK33_SEAM_BASE_PROPOSED   0x0000E000u
#define FK33_SEAM_SPAN            0x1000u

#define FK33_SEAM_ID              0x00u   /* R   0x4C4C4D32 = "LLM2" */
#define FK33_SEAM_VERSION         0x04u   /* R   contract version, = 1 */
#define FK33_SEAM_CAPS_VOCAB      0x08u   /* R   n_vocab */
#define FK33_SEAM_CAPS_EMBD       0x0Cu   /* R   [15:0] n_embd [31:16] n_layer */
#define FK33_SEAM_CAPS_CTX        0x10u   /* R   KV capacity, in tokens */
#define FK33_SEAM_CTRL            0x14u   /* W   see FK33_CTRL_* */
#define FK33_SEAM_STATUS          0x18u   /* R   see FK33_ST_* */
#define FK33_SEAM_ERR_INFO        0x1Cu   /* R   */
#define FK33_SEAM_SEQ_POS         0x20u   /* RW  position of this GO's step 0 */
#define FK33_SEAM_N_STEP          0x24u   /* RW  positions this GO advances */
#define FK33_SEAM_X_BASE_LO       0x28u   /* W   */
#define FK33_SEAM_X_BASE_HI       0x2Cu   /* W   */
#define FK33_SEAM_L_BASE_LO       0x30u   /* W   */
#define FK33_SEAM_L_BASE_HI       0x34u   /* W   */
#define FK33_SEAM_DESC_PTR_LO     0x38u   /* W   the D program for one token */
#define FK33_SEAM_DESC_PTR_HI     0x3Cu   /* W   */
#define FK33_SEAM_CYCLES          0x40u   /* R   core cycles, GO to done */
#define FK33_SEAM_ARGMAX          0x44u   /* R   argmax of the LAST step */
#define FK33_SEAM_LOGIT_EXP       0x48u   /* R   its shared block exponent */

#define FK33_SEAM_ID_MAGIC        0x4C4C4D32u
#define FK33_SEAM_VERSION_1       1u

/* CTRL, write-only, every bit self-clearing. */
#define FK33_CTRL_GO              (1u << 0)
#define FK33_CTRL_SEQ_RESET       (1u << 1)  /* invalidate KV, seq pos -> 0 */
#define FK33_CTRL_LOGITS_ALL      (1u << 2)  /* write logits for EVERY step,
                                              * not only the last one */

/* STATUS.
 *
 * `done` is LATCHED and cleared by the next GO, exactly as subsystem A's
 * STATUS does, and the same trap applies: ON ANY ERROR `done` IS NEVER SET.
 * `docs/2026-08-28_matvec-descriptor-format.md` states this for A and says a
 * done-only poller hangs forever.  POLL (done | err), NEVER done ALONE.
 * fk33_seam_wait() below is the only correct spelling of that wait and every
 * caller in this tree uses it. */
#define FK33_ST_DONE              (1u << 0)
#define FK33_ST_BUSY              (1u << 1)
#define FK33_ST_ERR               (1u << 2)
#define FK33_ST_ERRCODE(v)        (((v) >> 8) & 0xFu)

/* Error codes.  Deliberately NOT overlapping subsystem A's 0x0..0xF space,
 * because A's is FULL (OI-9) and a shared field with two meanings per value is
 * how an error report becomes fiction.  These live in their own register. */
#define FK33_SEAM_ERR_NONE        0x0u
#define FK33_SEAM_ERR_POS         0x1u  /* SEQ_POS + N_STEP > KV capacity */
#define FK33_SEAM_ERR_NSTEP       0x2u  /* N_STEP = 0, or above the chunk cap */
#define FK33_SEAM_ERR_ALIGN       0x3u  /* X_BASE or L_BASE not 64-B aligned */
#define FK33_SEAM_ERR_STACK       0x4u  /* a block straddles the HBM stack line */
#define FK33_SEAM_ERR_RSVD        0x5u  /* a reserved field was not zero */
#define FK33_SEAM_ERR_DESC        0x6u  /* the D program was refused */
#define FK33_SEAM_ERR_HALT        0x7u  /* thermal guard refused the GO */
#define FK33_SEAM_ERR_SEQ         0x8u  /* SEQ_POS is not the card's next pos */

/* ---------------------------------------------------------------------------
 * Block geometry.  Derived from CAPS, so a host that reads CAPS cannot
 * disagree with the bitstream about a stride.
 * ------------------------------------------------------------------------- */
#define FK33_BLOCK_ALIGN          64u
#define FK33_SEAM_HDR_BYTES       16u

static inline uint64_t fk33_round_up(uint64_t v, uint64_t a)
{ return (v + a - 1u) / a * a; }

static inline uint64_t fk33_x_stride(int n_embd)
{ return fk33_round_up(FK33_SEAM_HDR_BYTES + 2ull * (uint64_t)n_embd, FK33_BLOCK_ALIGN); }

static inline uint64_t fk33_l_stride(int n_vocab)
{ return fk33_round_up(FK33_SEAM_HDR_BYTES + 4ull * (uint64_t)n_vocab, FK33_BLOCK_ALIGN); }

/* The HBM stack boundary.  A port reaches one side of this and not the other,
 * with no cross-stack path (docs/2026-08-27_hbm-residency-map.md).  Note the
 * shipped manifest ALREADY violates this for blk.7.ffn_gate.weight, which
 * straddles it -- that is a live defect in the weight image, recorded in
 * docs/2026-08-28_token-io-path.md section 7.3, and it is not this file's to
 * fix.  It is the reason this check exists at all. */
#define FK33_HBM_STACK_LINE       0x100000000ull
#define FK33_HBM_TOP              0x200000000ull

/* Returns 0, or a FK33_SEAM_ERR_* code.  The host runs this BEFORE the DMA,
 * because a block in the wrong stack half reads back correctly over the host
 * port and is wrong only when the engine's port fetches it. */
int fk33_seam_check_blocks(uint64_t x_base, uint64_t x_bytes,
                           uint64_t l_base, uint64_t l_bytes);

/* Human-readable form of a FK33_SEAM_ERR_* code. */
const char *fk33_seam_strerror(unsigned code);

/* ---------------------------------------------------------------------------
 * The simulated card.  server/fk33_sim.c.
 *
 * WHAT IT IS: a model of the register block and the two byte layouts above,
 * plus a sparse AXI address space.  It exists so the HOST code -- the polling
 * discipline, the byte layouts, the stack check, the KV bookkeeping, the
 * sampler, the streaming -- can be executed and mutated today.
 *
 * WHAT IT IS NOT, AND THIS MATTERS MORE THAN WHAT IT IS:
 *
 *   IT IS NOT A NUMERIC REFERENCE FOR THE MODEL.  It does not run a
 *   transformer.  Its logits come from `logits_fn` below, and the built-in
 *   default is a deterministic synthetic function of (position, token id,
 *   vocabulary index) with NO relationship to Qwen3.5-9B.  A test that passes
 *   against it has shown the plumbing works and has shown NOTHING about
 *   whether a token is the right token.
 *
 *   IT DOES NOT MODEL SUBSYSTEM A.  The descriptor program is checked for
 *   presence and alignment and is otherwise not executed.  A's control plane
 *   already has a bit-exact bench (`sim/tb_matvec_fk33_desc.vhd`, 100 of 100
 *   elements against `ref/matvec_int4.c`); a second, unverified C model of it
 *   here would be a competing claim, not a check.
 *
 * A whole-model 9B numeric reference is backlog item 12 and TRACK REF9B is
 * building it.  `logits_fn` IS the interface this track would consume: give it
 * a function that returns the reference logits for (position, token id) and
 * the simulated card becomes a numeric oracle for the whole host path.  That
 * connection is deliberately not made here.
 * ------------------------------------------------------------------------- */
typedef struct {
    int n_vocab;
    int n_layer;
    int n_embd;
    int max_ctx;
    int max_chunk;          /* largest legal N_STEP; 0 -> 512 */

    /* Called once per step to fill `logits` (n_vocab int32) and set the row's
     * shared block exponent.  `x_mant`/`x_exp` are the activation row the host
     * DMA'd in, so a caller CAN make the model depend on its input, which is
     * what makes an end-to-end plumbing check have teeth.  Return 0, or
     * non-zero to make the card report FK33_SEAM_ERR_DESC. */
    int (*logits_fn)(void *user, int position, int token_id,
                     const int16_t *x_mant, int32_t x_exp,
                     int32_t *logits, int32_t *logit_exp);
    void *user;

    /* Fault injection, so the host's error paths can be shown to fire.
     * Every one of these makes the model behave like a card that is wrong in
     * a specific, named way; see server/tests/. */
    int fault_never_done;   /* accept GO, never set done -- the hang trap */
    int fault_err_on_go;    /* set err (and NOT done) on the next GO */
    int fault_short_logits; /* write only half the logits row */
    int fault_stale_argmax; /* leave the previous step's argmax in place */
} fk33_sim_opts;

/* Build a default opts for the Qwen3.5-9B shape.  MEASURED shape numbers:
 * n_vocab 248,320 and n_layer 32 are `rtl/model_cfg_pkg.vhd`'s QWEN35_9B,
 * n_embd 4,096 is the manifest's K for output.weight.  NOTE the audit flags
 * the vocabulary as UNVERIFIED (section 5.3): model_cfg_pkg says 248,320, the
 * shipped Qwen3 tokenizer said 151,936, and nothing derives the number.  The
 * C tokenizer's own artefact now reports it and pl_backend cross-checks the
 * two at open time rather than trusting either. */
void fk33_sim_opts_default(fk33_sim_opts *o);

#ifdef __cplusplus
}
#endif

#endif /* FK33_SEAM_H */
