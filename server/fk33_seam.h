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
 * UPDATED 2026-08-30, TRACK DSEAM.  One line of that has changed and no
 * more: THE REGISTER BLOCK NOW HAS RTL.  `rtl/fk33_seam.vhd` implements
 * VERSION 2 of the contract below and `sim/tb_fk33_seam.vhd` runs a whole
 * token through it with `rtl/llama_top.vhd`'s host face driven by nothing
 * else.  Everything else in this list still stands: there is no bitstream
 * containing a transformer, `hw/fk33/rtl/fk33_engine.vhd` is still subsystem
 * A alone, the base address below is still assigned nowhere in
 * `hw/fk33/gen_pcieep.py`, and NOTHING HERE HAS RUN ON SILICON.
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
 * "THE LOOP" IS TWO LOOPS AND THIS TABLE MEANT ONLY ONE OF THEM.  Corrected
 * 2026-08-30 because board row N2 turned on the distinction.  The TOKEN loop
 * -- sample, decide, feed the next position -- is the host's, for the reasons
 * below.  The STEP loop -- the 546 descriptors inside one token -- is the
 * CARD's, and Oren decided that explicitly on 2026-08-30: "we don't want host
 * controlling, let's get D working".  A reader who took the row below to mean
 * the host drives every job would be reading the option N2 REJECTED.
 *
 *   AXU3EG                            FK33
 *   -----------------------------     ------------------------------------
 *   PS on the same die                no PS at all; the host is a real host
 *   engine ran the whole loop         host owns the TOKEN loop; subsystem D
 *                                     owns the step loop inside a token
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
 * THE BASE ADDRESS IS DECIDED AND ASSIGNED.  UPDATED 2026-08-30, TRACK
 * SEAMMAP.  Board row N2 was resolved by Oren on 2026-08-30 in favour of
 * option (a) -- build this block in front of subsystem D -- and
 * `hw/fk33/gen_pcieep.py` now carries `SEAM_BASE = 0x0000E000`, instantiates
 * `rtl/fk33_seam.vhd` as `fk33_seam_0` and emits
 * `assign_bd_address -offset 0x0000E000 -range 4K`.  The macro below was
 * called `FK33_SEAM_BASE_PROPOSED` until that happened; the rename is the
 * condition the old comment set for itself, and gen_pcieep.py now REFUSES to
 * emit a build while the old name survives here.
 *
 * 0xE000 is the lowest free 4 KB page below the scratch BRAM.  MEASURED
 * occupancy of the 128 KB BAR, from `grep assign_bd_address
 * hw/fk33/build_fk33_pcieep.tcl` -- the emitted script, not a document:
 * 0x3000 (SYSMON), 0x9000 (GPIO), 0xA000 (ID), 0xB000/0xC000/0xD000
 * (thermal), 0x10000+0x2000 (scratch), 0x12000/0x13000 (subsystem A).
 * CORRECTED in the same commit: this comment previously said "0x3400
 * (SYSMON)".  0x3400 is SYSMON's temperature REGISTER; the block occupies
 * 0x3000..0x3FFF.  The answer does not change, but the map is no longer
 * hand-maintained here -- `check_bar_map()` in gen_pcieep.py parses the
 * emitted build script and refuses on overlap, on a non-4 KB-aligned base,
 * on anything running past the 128 KB BAR, and on the seam being absent.
 *
 * WHAT IS AT 0xE000 IN THE BITSTREAM TODAY, AND WHAT IS NOT.  The seam is
 * real and its host-facing half works: ID, VERSION, CAPS, CTRL, STATUS,
 * ERR_INFO and both indirect windows.  SUBSYSTEM D IS NOT THERE --
 * `hw/fk33/rtl/fk33_engine.vhd` is still subsystem A alone, which is board
 * row N3 -- so gen_pcieep.py drives the seam's D face from constants with
 * `d_err` tied HIGH.  Two consequences a host must expect:
 *
 *   * FK33_SEAM_CAPS_VOCAB reads 0, and so do CAPS_EMBD and CAPS_CTX.  That
 *     is the honest report of a bitstream with no model behind the seam.
 *   * every GO is refused one cycle later with FK33_SEAM_ERR_DESC in STATUS
 *     and 0xF in ERR_INFO[3:0].  0xF is not a code `rtl/llama_top.vhd` can
 *     produce, so it means "there is no subsystem D in this bitstream" and
 *     never a real descriptor fault.  The refusal is deliberate: with d_err
 *     LOW instead, a GO would set `running` and nothing would ever clear it,
 *     and the poll loop this header prescribes would hang forever.
 * ------------------------------------------------------------------------- */
#define FK33_SEAM_BASE            0x0000E000u
#define FK33_SEAM_SPAN            0x1000u
/* ERR_INFO[3:0] when the bitstream has no subsystem D behind the seam. */
#define FK33_SEAM_DINFO_ABSENT    0xFu

#define FK33_SEAM_ID              0x00u   /* R   0x4C4C4D32 = "LLM2" */
#define FK33_SEAM_VERSION         0x04u   /* R   contract version.
                                           * rtl/fk33_seam.vhd reports 2. */
#define FK33_SEAM_CAPS_VOCAB      0x08u   /* R   n_vocab */
#define FK33_SEAM_CAPS_EMBD       0x0Cu   /* R   [15:0] n_embd [31:16] n_layer */
#define FK33_SEAM_CAPS_CTX        0x10u   /* R   KV capacity, in tokens */
#define FK33_SEAM_CTRL            0x14u   /* W   see FK33_CTRL_* */
#define FK33_SEAM_STATUS          0x18u   /* R   see FK33_ST_* */
#define FK33_SEAM_ERR_INFO        0x1Cu   /* R   */
#define FK33_SEAM_SEQ_POS         0x20u   /* RW  position of this GO's step 0 */
#define FK33_SEAM_N_STEP          0x24u   /* RW  positions this GO advances */
/* THE FOUR HBM POINTERS BELOW ARE VERSION-3 REGISTERS.  They are the right
 * long-term shape and `rtl/fk33_seam.vhd` DOES NOT IMPLEMENT THEM: fetching a
 * block out of HBM needs an HBM master the seam does not have, subsystem A
 * already takes 27 of the 30 engine ports, and the port assignment lives in
 * a file this contract cannot change.  In v2 they must be ZERO at GO and a
 * non-zero one raises FK33_SEAM_ERR_RSVD -- deliberately loud, because a host
 * that thinks it handed the card a pointer and gets a token back was lied to.
 * Read FK33_SEAM_CAPS_FLAGS bit 1 rather than assuming. */
#define FK33_SEAM_X_BASE_LO       0x28u   /* W   v3, must be 0 in v2 */
#define FK33_SEAM_X_BASE_HI       0x2Cu   /* W   v3, must be 0 in v2 */
#define FK33_SEAM_L_BASE_LO       0x30u   /* W   v3, must be 0 in v2 */
#define FK33_SEAM_L_BASE_HI       0x34u   /* W   v3, must be 0 in v2 */
#define FK33_SEAM_DESC_PTR_LO     0x38u   /* W   v3, must be 0 in v2 */
#define FK33_SEAM_DESC_PTR_HI     0x3Cu   /* W   v3, must be 0 in v2 */
#define FK33_SEAM_CYCLES          0x40u   /* R   core cycles, GO to done */
#define FK33_SEAM_ARGMAX          0x44u   /* R   argmax of the LAST step */
#define FK33_SEAM_LOGIT_EXP       0x48u   /* R   its shared block exponent */

/* ---------------------------------------------------------------------------
 * VERSION 2, added 2026-08-30 by TRACK DSEAM.
 *
 * WHY THESE EXIST AND WHY THEY ARE NOT OPTIONAL.  Version 1 was written
 * against a card that would fetch its own program out of HBM, so it carried
 * no register for the two things subsystem D actually needs from a host every
 * token.  MEASURED against `rtl/llama_top.vhd`'s port list:
 *
 *   TBL_LEN   `tbl_len`, the descriptor count INCLUDING the END_TOKEN
 *             descriptor.  `rtl/seq_desc_fetch.vhd` checks the walk against
 *             it two-sidedly -- reaching it without an END_TOKEN is ERR_DESC,
 *             and an END_TOKEN before it is also ERR_DESC -- so a card that
 *             does not know it cannot run a token at all.
 *   X_EXP     `host_x_exp`, the BFP block exponent of the activation row.
 *             v1 carried this only as a FIELD INSIDE the HBM block at X_BASE,
 *             which is a block v2 does not fetch.
 *
 * And the windows, which are what replace the HBM fetch:
 *
 *   WIN_SEL   0 = the descriptor program (32-bit halves, low half first)
 *             1 = the RELEASE MASK table, one entry per step
 *             2 = the activation row, one int16 mantissa per write
 *             3 = readback of the residual region, read-only
 *   WIN_ADDR  index into the selected window.  AUTO-INCREMENTS on every
 *             WIN_DATA access, read or write, so a host streams.
 *   WIN_DATA  the port.
 *
 * THE RELEASE-MASK TABLE IS THE ONE THAT CLOSES N2, and it is worth being
 * explicit about why a whole window exists for 14 bits per step.  D's region
 * lock needs to know, per step, which regions that step is the LAST reader
 * of.  Lifetime is a property of the SCHEDULE, so the generator is what knows
 * it -- and `rtl/seq_region_lock.vhd`'s own header records that the D spec's
 * section 6.1 descriptor format HAS NO FIELD FOR IT.  So until 2026-08-30 the
 * mask arrived on a per-step wire that a TESTBENCH drove
 * (`sim/tb_llama_top.vhd:1923`).  A host driving that over PCIe would be
 * inside the inner loop, which is exactly what N2 ruled out.
 * `tools/gen_layer_program.py` already emits the table as a separate file
 * (`--rel-file`, `write_rel()`), so nothing new has to be computed: it is
 * written to WIN_SEL 1 once per model and the card indexes it itself.
 * ------------------------------------------------------------------------- */
#define FK33_SEAM_CAPS_FLAGS      0x4Cu   /* R   see FK33_CAP_* */
#define FK33_SEAM_TBL_LEN         0x50u   /* RW  descriptors, END_TOKEN incl. */
#define FK33_SEAM_X_EXP           0x54u   /* RW  i32, the row's block exponent */
#define FK33_SEAM_WIN_SEL         0x58u   /* RW  see FK33_WIN_* */
#define FK33_SEAM_WIN_ADDR        0x5Cu   /* RW  auto-increments on DATA */
#define FK33_SEAM_WIN_DATA        0x60u   /* RW  the window port */
#define FK33_SEAM_SMP_N           0x64u   /* R   logits folded since GO */
#define FK33_SEAM_FAULTS          0x68u   /* R   see FK33_FAULT_* */

#define FK33_WIN_DESC             0u
#define FK33_WIN_REL              1u
#define FK33_WIN_XIN              2u
#define FK33_WIN_XOUT             3u

/* CAPS_FLAGS.  What the BITSTREAM implements, so a host does not discover it
 * by trying.  `rtl/fk33_seam.vhd:383` reports **0xD**: windows, sampler and
 * logits egress; no HBM fetch.  (This comment read 0x5 until 2026-09-17 and
 * was one commit stale: `e62fded` enabled the sampler and set CAPS_FLAGS_V to
 * x"0000000D".  Where a document and the RTL disagree, the RTL wins -- read
 * the constant, not this line.) */
#define FK33_CAP_WINDOWS          (1u << 0)
#define FK33_CAP_HBM_FETCH        (1u << 1)
#define FK33_CAP_SAMPLER          (1u << 2)
#define FK33_CAP_LOGITS           (1u << 3)

/* FAULTS.  Every bit is a DEFECT, not a statistic, and every one is SILENT in
 * the arithmetic -- which is the whole reason they get a register rather than
 * a log line.  Sourced from `rtl/llama_top.vhd`'s five sticky seam counters
 * plus `attn_kv_axi`'s.  A token whose numbers look fine and whose FAULTS is
 * non-zero has not computed what it claims. */
#define FK33_FAULT_SMP_OVF        (1u << 0)  /* the logits FIFO lost beats */
#define FK33_FAULT_LOST_BEAT      (1u << 1)  /* an unstallable producer beat */
#define FK33_FAULT_GATE_DROP      (1u << 2)  /* the region lock refused a write */
#define FK33_FAULT_UNIT_STUB      (1u << 3)  /* a STUB unit produced a result */
#define FK33_FAULT_E_COLL         (1u << 4)  /* OP_E_COLL issued at NCARDS=1 */
#define FK33_FAULT_KV             (1u << 5)  /* attn_kv_axi's sticky error */

#define FK33_SEAM_ID_MAGIC        0x4C4C4D32u
#define FK33_SEAM_VERSION_1       1u
#define FK33_SEAM_VERSION_2       2u

/* TWO IMPLEMENTATIONS OF THIS HEADER EXIST AND THEY CAN REPORT DIFFERENT
 * VERSIONS.  Said here rather than left to be discovered:
 *
 *   rtl/fk33_seam.vhd   reports 2.  Windows, no HBM fetch, no logits egress.
 *   server/fk33_sim.c   reports whichever `fk33_sim_opts.version` asks for.
 *                       DEFAULT 1, the v1 shape -- X_BASE, L_BASE, DESC_PTR
 *                       and a sparse AXI space -- because that is what the
 *                       84 checks of seam_selftest.c and server_e2e.py are
 *                       written against, and changing a model underneath a
 *                       passing suite turns it into a suite that passes for
 *                       a different reason.  `version = 2` gets the window
 *                       seam; T13 in seam_selftest.c drives it.
 *
 * UPDATED 2026-09-17.  This block previously said reconciling fk33_sim.c to
 * v2 was "open work with no owner", and it was open for long enough to
 * matter: the RTL had been v2 since TRACK DSEAM and, MEASURED on 2026-09-17,
 * NOTHING ANYWHERE DROVE IT.  Not this model, not pl_backend.c (which still
 * writes a block at X_BASE and GOes), and not the Python tooling under
 * hw/fk33/host/ (which talks to the ENGINE at 0x12000, never to the seam).
 * The model is now the half that exists; **pl_backend.c is still a v1 host
 * and is the remaining half.**
 *
 * So a host must BRANCH ON THE VERSION REGISTER, not on this header.  A v2
 * card ignores the pointers and refuses a non-zero one; a v1 model ignores
 * the windows. */

/* CTRL, write-only, every bit self-clearing. */
#define FK33_CTRL_GO              (1u << 0)
#define FK33_CTRL_SEQ_RESET       (1u << 1)  /* invalidate KV, seq pos -> 0 */
#define FK33_CTRL_LOGITS_ALL      (1u << 2)  /* write logits for EVERY step,
                                              * not only the last one.
                                              * NOT IMPLEMENTED in v2: there
                                              * is no logits egress at all.
                                              * Check FK33_CAP_LOGITS. */
#define FK33_CTRL_ABORT           (1u << 3)  /* v2.  Drops the current token. */
#define FK33_CTRL_TOK_ACK         (1u << 4)  /* v2.  RESERVED, and the reason
                                              * is worth stating: D's own
                                              * `tok_done` is a LEVEL held
                                              * until `tok_ack`, and
                                              * rtl/fk33_seam.vhd raises that
                                              * ack ITSELF.  A host round trip
                                              * to acknowledge a completion it
                                              * is already polling for would
                                              * buy nothing. */
#define FK33_CTRL_CLR_ERR         (1u << 5)  /* v2.  Clears the sticky error. */

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

/* ERR_INFO, v2.  Three fields, and the third is the one worth polling on a
 * clean run too: `steps_done` MUST equal TBL_LEN at a clean completion.  That
 * is `rtl/seq_desc_fetch.vhd`'s own counting identity, and an accounting
 * identity is what named the gdn head-emit defect that a throughput metric
 * had missed.
 *
 * D_ERRCODE IS NOT A SEAM ERROR CODE.  D reports in its own 4-bit space and
 * subsystem A's is full (OI-9); a shared field with two meanings per value is
 * how an error report becomes fiction.  A D failure surfaces as seam code
 * FK33_SEAM_ERR_DESC in STATUS, with D's own code HERE. */
#define FK33_EI_D_ERRCODE(v)      ((v) & 0xFu)
#define FK33_EI_ERR_STEP(v)       (((v) >> 4) & 0x7FFu)
#define FK33_EI_STEPS_DONE(v)     (((v) >> 16) & 0x7FFu)

/* Error codes.  Deliberately NOT overlapping subsystem A's 0x0..0xF space,
 * because A's is FULL (OI-9) and a shared field with two meanings per value is
 * how an error report becomes fiction.  These live in their own register. */
#define FK33_SEAM_ERR_NONE        0x0u
#define FK33_SEAM_ERR_POS         0x1u  /* OUT OF RANGE.  Two senses, deliberately
                                        * one code: SEQ_POS + N_STEP past the KV
                                        * capacity, and a block extending past
                                        * the top of HBM.  Both mean "the host
                                        * asked for an address or a position the
                                        * card does not have", and splitting
                                        * them would spend a code from a 4-bit
                                        * field for no host-visible difference:
                                        * the fix is the same. */
#define FK33_SEAM_ERR_NSTEP       0x2u  /* N_STEP = 0, or above the chunk cap */
#define FK33_SEAM_ERR_ALIGN       0x3u  /* X_BASE or L_BASE not 64-B aligned */
#define FK33_SEAM_ERR_STACK       0x4u  /* a block straddles the HBM stack line */
#define FK33_SEAM_ERR_RSVD        0x5u  /* a reserved field was not zero */
#define FK33_SEAM_ERR_DESC        0x6u  /* the D program was refused */
#define FK33_SEAM_ERR_HALT        0x7u  /* thermal guard refused the GO */
#define FK33_SEAM_ERR_SEQ         0x8u  /* SEQ_POS is not the card's next pos */

/* WHICH OF THE NINE `rtl/fk33_seam.vhd` CAN ACTUALLY RAISE, said because a
 * code nothing can produce is a code nothing tests.  v2 raises NONE, POS,
 * NSTEP, RSVD, DESC and SEQ.  It cannot raise ALIGN or STACK -- both are
 * properties of the HBM pointers, which v2 refuses outright as RSVD before
 * either check would apply -- and it cannot raise HALT, because the thermal
 * guard's `compute_halt` is not wired to this block.  Wiring it is open work:
 * `docs/debugging/2026-08-30_therm255-is-two-stacks-not-two-copies.md` is why
 * a GO refused for heat has to be distinguishable from one refused for a bad
 * request. */

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

    /* Add this to the argmax written to the row header AND to the register,
     * so the two AGREE with each other and both disagree with the row's own
     * contents.  That is the shape of a wrong per-shard base in the card's
     * sampler (the `smp_base` accumulator makes the argmax a GLOBAL vocab
     * index across the lm_head's 15 shards, and getting that offset wrong
     * yields a plausible id with no fault raised anywhere).  pl_backend's
     * header-against-register check CANNOT see it -- both copies are wrong
     * together -- so detecting it requires recomputing the argmax from the
     * row, which is what run_prompt --check-argmax does.  The index wraps
     * into [0, n_vocab). */
    int fault_argmax_bias;

    /* ------------------------------------------------------------ VERSION 2
     * The contract version this model presents.  0 or 1 -> the v1 card the
     * host has always been tested against: X_BASE/L_BASE/DESC_PTR in HBM, no
     * windows, no TBL_LEN, no X_EXP.  2 -> the card `rtl/fk33_seam.vhd`
     * ACTUALLY IS: the activation row and the descriptor program arrive
     * through the WIN_SEL/WIN_ADDR/WIN_DATA port and no host block is fetched
     * from HBM at all.
     *
     * WHY THIS IS A SWITCH RATHER THAN A REPLACEMENT.  The v1 behaviour is
     * what server/tests/seam_selftest.c's 84 checks and server_e2e.py are
     * written against, and silently changing the model underneath them would
     * turn a passing suite into a suite that passes for a different reason --
     * the exact shape this project keeps recording.  So v1 stays exactly as
     * it was, byte for byte, and v2 is reached only by asking for it.
     *
     * MEASURED 2026-09-17, and it is why this exists: the RTL has been v2
     * since TRACK DSEAM, `rtl/fk33_seam.vhd:859` reports VERSION2 and :383
     * reports CAPS_FLAGS 0xD -- and NOTHING on the host drives it.  This
     * model was v1-only, pl_backend.c writes HBM at X_BASE and GOes, and the
     * Python tooling under hw/fk33/host/ talks to the ENGINE at 0x12000
     * rather than to the seam.  A simulator that cannot present the card the
     * bitstream implements is a simulator no v2 driver can be written
     * against, so this is the first of the two pieces. */
    int version;            /* 0/1 -> v1 (default), 2 -> the window seam */
    uint32_t caps_flags;    /* 0 -> derive from `version`; else reported as-is */

    /* v2 window sizes, in ENTRIES.  0 -> the RTL's own generics.  They are
     * options rather than constants so a test can construct an overflow
     * without allocating the real thing.
     *
     * The defaults come from `rtl/fk33_seam.vhd:204-206`: DESC_WORDS = 4608
     * SIXTY-FOUR-bit words, which a host writes as 9,216 32-bit halves (low
     * half first), and REL_ENT = 576 entries. */
    int win_desc_words;     /* 32-bit halves; 0 -> 9216 = 2 * DESC_WORDS */
    int win_rel_words;      /* one per descriptor; 0 -> 576 = REL_ENT */

    /* CHECKS THE MODEL MAKES THAT THE CARD DOES NOT.  Default OFF, so the
     * model's default behaviour is the CARD's behaviour and a driver cannot
     * come to depend on a refusal that only exists here.  Turning it on is
     * how a test shows what the card will NOT catch:
     *
     *   TBL_LEN set with fewer descriptor halves actually written
     *   an activation row shorter than n_embd
     *
     * `rtl/fk33_seam.vhd:746-761` bounds TBL_LEN against the window CAPACITY
     * (REL_ENT, and DESC_WORDS/8) and never against what a host wrote, and it
     * has no row-length check at all.  Both failures therefore reach the
     * arithmetic on real hardware and present as an ordinary wrong answer. */
    int model_strict;

    /* v2 fault injection. */
    int fault_win_no_incr;  /* WIN_ADDR does not auto-increment on DATA */
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
