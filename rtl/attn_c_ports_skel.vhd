-- rtl/attn_c_ports_skel.vhd -- SKELETON, NOT AN IMPLEMENTATION.
--
-- WHAT THIS IS.  Subsystem C's top-level interface, written out so the
-- handshake discipline can be reviewed before any datapath exists.  The
-- architecture ties every output off; it computes nothing and must never be
-- instantiated in a build.  Its only job is to make the CONTRACT reviewable.
--
-- It exists because subsystem B lost two days to two integration defects that
-- were both interface defects, both invisible to synthesis, and both
-- invisible to a value check:
--
--   docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md
--     A one-cycle `done` with no acknowledgement.  The producer ran its next
--     reduce regardless of whether the consumer was free, so a consumer busy
--     elsewhere when the pulse landed lost an ENTIRE HEAD.  The unit then went
--     idle with both banks empty, looking perfectly healthy.  Worse, the lossy
--     path scored BETTER on the obvious metric: the configuration that dropped
--     heads reported zero back-pressure, and the FIX made 167 refused columns
--     appear.  A zero back-pressure count is a question, not a result.
--
--   docs/debugging/2026-08-27_gdn-emit-chain-w-latch.md
--     A shared per-block configuration input (`w_mant`, the layer's norm
--     weight) read combinationally over a window that spanned a
--     producer-visible boundary.  The producer presented the NEXT block's
--     weights while the chain was still normalising the LAST head of the
--     current one, so head 23 of every block was wrong and heads 0..22 were
--     bit-exact.  The rejected fix was "document the timing contract": a safe
--     window did exist, but it was not OBSERVABLE from outside the unit, and a
--     contract a producer cannot see is a bug waiting on a schedule change.
--     The accepted fix latches at pickup and emits a `w_taken` pulse.
--
-- The two rules this entity applies everywhere, as a result:
--
--   RULE 1  No completion or result signal is a bare pulse.  It is held until
--           an explicit acknowledgement, and the ack input DEFAULTS TO '1' so
--           that a testbench which leaves it unconnected reproduces the old
--           pulse semantics exactly (the gdn_head_emit convention).
--
--   RULE 2  Every input C reads for longer than one cycle is LATCHED by C at a
--           named instant, and that instant is made observable to the producer
--           by a `_taken` pulse.  This covers the per-layer norm weights, the
--           three input exponents, and the whole job descriptor.
--
-- BACK-PRESSURE IS A CORRECTNESS PROPERTY HERE.  Stated per port below, in the
-- form the project now requires: for every interface, whether the producer can
-- be stalled, and if it cannot, what bounds the consumer's service time.
-- Subsystem B's `gdn_recur_pipe` has no ready input at all -- `o_res_valid`
-- free-runs -- so a consumer whose ready falls under it LOSES data rather than
-- delaying it.  C has two interfaces of that shape and one of them is at the
-- top level, on `y`.
--
-- GEOMETRY.  Qwen3.8-27B, verified against the target GGUF's own metadata and
-- tensor shapes on 2026-08-27, NOT taken from prose:
--   qwen35.block_count 64, qwen35.full_attention_interval 4  -> 16 attention
--     layers at indices 3, 7, ... 63; the other 48 are Gated DeltaNet
--   qwen35.attention.head_count 24, head_count_kv 4
--   qwen35.attention.key_length 256, value_length 256        -> head_dim 256
--   blk.3.attn_q.weight [5120, 12288] = 24 heads x 256 x 2   -> fused gate
--   blk.3.attn_k.weight [5120, 1024]  = 4 heads x 256
--   blk.3.attn_output.weight [6144, 5120]                    -> wo in = 6144
-- At N = 2 tensor parallel each card owns 12 query heads and 2 KV heads.
--
-- The `head_v_dim = 128` and `16 key heads` figures that circulate with this
-- model are the GATED DELTANET dimensions (qwen35.ssm.state_size 128,
-- qwen35.ssm.group_count 16) and do NOT apply to the attention layers.  Both
-- head types being 128 wide is a true statement about subsystem B and a false
-- one about subsystem C.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity attn_c_ports_skel is
  generic(
    HEAD_DIM  : positive := 256;    -- GGUF attention.key_length / value_length
    N_HEAD    : positive := 12;     -- 24 query heads / N=2 cards
    N_KVH     : positive := 2;      -- 4 KV heads / N=2 cards
    N_ROT     : positive := 64;     -- GGUF rope.dimension_count
    KV_BLOCK  : positive := 32;     -- quantization granularity, C spec 2.1.1
    MAXLAYERS : positive := 16;     -- GGUF block_count / full_attention_interval
    MAXCTX    : positive := 2048;   -- MUST be a multiple of 256, C spec 2.2
    -- MACS = QH_TILE x DIM_TILE.  DIM_TILE is fixed at 32 by the HBM AXI beat
    -- (256 b = 32 int8 = exactly one KV_BLOCK), and QH_TILE must divide the
    -- GQA group of 6, so the legal ladder is 32 / 64 / 96 / 192 and nothing
    -- between.  192 is the largest rung that fits the die.  See the DSP
    -- budget in docs/superpowers/specs/2026-08-27-C-gated-attention-skeleton.md.
    QH_TILE   : positive := 6;
    DIM_TILE  : positive := 32;
    -- Simulation-only.  Asserts that a producer which cannot be stalled is
    -- never refused, and that a latched input is stable across its window.
    -- Synthesizes to nothing, so it costs no area and is worth leaving on.
    -- The gdn_emit_chain STRICT_PRODUCER precedent: this class of defect is
    -- invisible to a value check and invisible to synthesis, and an assertion
    -- is the only thing that catches it.
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ================= job descriptor, from subsystem D ==================
    -- start is a one-cycle pulse.  C samples the ENTIRE descriptor on it and
    -- holds its own copy for the job: layer, cur_pos, ctx_len, k_base, v_base.
    -- RULE 2.  Without the latch, D advancing the layer pointer while C is
    -- still sweeping corrupts exactly the tail of the job and nothing else --
    -- the head-23 shape.  cfg_taken makes the safe instant observable.
    start     : in  std_logic;
    layer     : in  unsigned(4 downto 0);   -- ATTENTION ORDINAL 0..15, not the
                                            -- model layer index.  D owns the
                                            -- 3,7,...,63 -> 0..15 mapping.
    cur_pos   : in  unsigned(15 downto 0);
    ctx_len   : in  unsigned(15 downto 0);
    k_base    : in  std_logic_vector(31 downto 0);
    v_base    : in  std_logic_vector(31 downto 0);
    cfg_taken : out std_logic;              -- one cycle, at the latch instant

    -- Per-SEQUENCE reset of the v_ref min-fold registers (C spec 2.1.4).
    -- A level from D, not a per-token pulse.  seq_rst_taken exists for the
    -- same reason cfg_taken does: the fold's init value is +127 and is NOT
    -- neutral -- an init of 0 right-shifts every V block by its full exponent
    -- and silently destroys the cache's precision while passing every
    -- structural check -- so the producer needs to see when it took effect.
    kv_seq_rst     : in  std_logic;
    seq_rst_taken  : out std_logic;

    -- ============ activation-memory reads, from subsystem A ==============
    -- act_mem_striped semantics: block address out, 512-bit data in, 1-cycle
    -- registered read (C spec 3.10, D O25).
    --
    -- BACK-PRESSURE: C is the MASTER on all three.  The producer is a memory
    -- and cannot refuse; C simply does not issue an address it is not ready to
    -- consume.  No loss is possible in this direction and no ready is needed.
    -- The hazard on these ports is RULE 2, not back-pressure: qg is read in
    -- TWO widely separated phases (Q marshalling early, the gate re-read at
    -- the end of the t-passes), so the region must not be written by anyone
    -- until C asserts done.  That is C spec 2.6's normative requirement 1 on
    -- subsystem D and it is the reason the 32,768 FF gate buffer was deleted.
    qg_rbaddr : out std_logic_vector(7 downto 0);
    qg_rdata  : in  std_logic_vector(511 downto 0);
    k_rbaddr  : out std_logic_vector(3 downto 0);
    k_rdata   : in  std_logic_vector(511 downto 0);
    v_rbaddr  : out std_logic_vector(3 downto 0);
    v_rdata   : in  std_logic_vector(511 downto 0);

    -- The three exponents are three INDEPENDENT subsystem A jobs with three
    -- independent y_exp values (C spec 1.4, defect C2).  They are sampled with
    -- their vectors and latched; qg_exp is shared by Q and the gate because
    -- both are views of one wq output.
    qg_exp : in signed(7 downto 0);
    k_exp  : in signed(7 downto 0);
    v_exp  : in signed(7 downto 0);

    -- ================= per-layer QK-norm weights =========================
    -- RULE 2, and this is the exact gdn_emit_chain w_mant case.  C runs 14
    -- norms per layer (12 Q heads + 2 K heads) on ONE shared rmsnorm_rs
    -- instance, so the read window spans thousands of cycles.  If D presents
    -- the next layer's weights while the last head is still normalising, that
    -- head alone is wrong.  C latches both weights AND both exponents at the
    -- start of the layer and pulses wn_taken.
    --
    -- The weights are read through a port rather than latched as a parallel
    -- bus because HEAD_DIM x 16 = 4,096 bits x 2 is a bus the project's own
    -- A-side rule prohibits at the top level; the latch is internal.
    qn_raddr : out std_logic_vector(7 downto 0);
    qn_rdata : in  std_logic_vector(15 downto 0);
    kn_raddr : out std_logic_vector(7 downto 0);
    kn_rdata : in  std_logic_vector(15 downto 0);
    qn_exp   : in  signed(7 downto 0);
    kn_exp   : in  signed(7 downto 0);
    wn_taken : out std_logic;   -- one cycle, at the latch instant

    -- ================= gated result, to A's activation memory ============
    -- 3,072 entries (12 query heads x 256), one element per cycle.
    --
    -- BACK-PRESSURE: y_ready IS NEW.  The C spec as written (1.4, 3.10)
    -- declares y_we / y_addr / y_data / y_exp with NO ready, which makes C a
    -- producer that cannot be stalled -- structurally identical to
    -- gdn_recur_pipe, and therefore a LOSS path rather than a stall path if
    -- the consumer is ever busy.  Today it happens to be safe because
    -- subsystem D guarantees A is idle while C runs (C spec 2.7: A and C are
    -- never active simultaneously).  That is a schedule property, not an
    -- interface property, and it is exactly the kind of invisible contract the
    -- w_mant defect punished.
    --
    -- y_ready DEFAULTS TO '1', so a consumer that genuinely cannot stall is
    -- unaffected and no existing testbench changes behaviour.  With
    -- STRICT_PRODUCER the unit asserts if y_ready ever falls, which converts a
    -- silent loss into a loud simulation failure.
    y_we    : out std_logic;
    y_addr  : out std_logic_vector(11 downto 0);   -- 12 b: 3,072 entries.
                                                   -- C spec 1.4 declares 10
                                                   -- downto 0, an 0.8B count;
                                                   -- 3.10 already flags it.
    y_data  : out std_logic_vector(15 downto 0);
    y_exp   : out signed(7 downto 0);
    y_ready : in  std_logic := '1';

    -- ================= completion and events =============================
    -- RULE 1.  done is HELD HIGH until done_ack, not pulsed.  C spec 1.4 says
    -- "one-cycle pulse"; that is the gdn_head_emit shape, and the reason it
    -- failed there was not that the consumer was badly written but that the
    -- producer ran on regardless of whether the consumer was listening.  D's
    -- sequencer is believed to be always waiting at this point, which is
    -- exactly the "safe window that is not observable" argument that was
    -- rejected for w_mant.
    --
    -- done_ack DEFAULTS TO '1', which reproduces the one-cycle pulse exactly,
    -- so this is strictly a widening of the contract.
    --
    -- done pulses even on abort so D's FSM cannot hang (the A 7.6 convention).
    -- done must not assert until every outstanding write has completed
    -- (BRESP received): token T's write of K/V[cur_pos] is read by token T+1
    -- through a DIFFERENT master, and AXI orders nothing between masters
    -- (C spec 2.7).
    done     : out std_logic;
    done_ack : in  std_logic := '1';

    -- Sticky, cleared at the next start.
    err : out std_logic;

    -- Quality events, NOT errors.  Valid from done to the next start.
    -- rope_sat: IMROPE int16 saturation on the K or Q path.  It clips the
    --   VALUE but does not corrupt the exponent chain, and the C reference
    --   saturates identically, so bit-exactness is unaffected (C spec 3.4).
    -- rescale_max: the maximum number of online-softmax rescale events over
    --   the job's group sweeps.  C spec 3.3 has an error bound that is
    --   comfortable at the expected R (~8 per head) and unacceptable at the
    --   adversarial worst case (R = cur_pos), with OBSERVABILITY and no
    --   mitigation.  This counter is that observability.
    rope_sat    : out std_logic;
    rescale_max : out unsigned(15 downto 0);

    -- ================= HBM, two read masters + one write =================
    -- Elided.  Shapes are pinned in C spec 2.2 and 3.0: 256-bit AXI, K and V
    -- in separate regions with one read master each, 272 B records = 8.5
    -- beats, bursts split at 4 KB boundaries independent of record boundaries
    -- (272 does not divide 4096, so ~6% of records straddle one).
    --
    -- BACK-PRESSURE: standard AXI, both directions stallable.  The one
    -- non-obvious requirement is that flushing the read FIFOs on start is
    -- INSUFFICIENT on its own: R beats from ARs issued near the end of the
    -- previous job land after a naive flush and corrupt the next one.  Stop
    -- issuing ARs, count RLASTs until outstanding reaches zero, THEN flush.
    axi_elided : out std_logic
  );
end entity;

-- The architecture is deliberately empty of function.  A skeleton that
-- computes something is a unit nobody verified; this one cannot be mistaken
-- for one.
architecture skel of attn_c_ports_skel is
begin
  cfg_taken     <= '0';
  seq_rst_taken <= '0';
  wn_taken      <= '0';
  qg_rbaddr     <= (others => '0');
  k_rbaddr      <= (others => '0');
  v_rbaddr      <= (others => '0');
  qn_raddr      <= (others => '0');
  kn_raddr      <= (others => '0');
  y_we          <= '0';
  y_addr        <= (others => '0');
  y_data        <= (others => '0');
  y_exp         <= (others => '0');
  done          <= '0';
  err           <= '0';
  rope_sat      <= '0';
  rescale_max   <= (others => '0');
  axi_elided    <= '0';
end architecture;
