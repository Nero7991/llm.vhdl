-- sim/seq_tbl_pkg.vhd
-- Testbench support for subsystem D: the descriptor encoder and a real
-- per-token descriptor table for the build target in `model_cfg_pkg`.
--
-- WHY THIS IS A REAL TABLE AND NOT A TOY.  `seq_desc_fetch` walks a table the
-- HOST generates; the gateware never computes the schedule.  A testbench that
-- walks four hand-written descriptors verifies the handshake and nothing about
-- the format, and the format is where two conforming generators are supposed
-- to produce byte-identical output.  So this package builds the whole token
-- for Qwen3.5-9B at NCARDS = 1 -- 24 Gated DeltaNet blocks, 8 attention
-- blocks, the final norm, lm_head and END_TOKEN -- from `model_cfg_pkg` and
-- from nothing else.  Change `MODEL` there and this table follows.
--
-- Every dimension below is `MODEL.<field>` or a function of it.  None is a
-- literal copied out of spec prose, which is the failure the model package
-- exists to prevent (the 16-versus-24 head confusion cost a wrong cycle model,
-- a wrong BRAM table and a wrong norm-overlap conclusion).
--
-- THE N = 1 STEP COUNTS.  At NCARDS = 1 there is no collective, so the two
-- E_COLL steps of each block are absent and the row-parallel matvecs write
-- their region directly in BFP mode instead of streaming s48 partials.  That
-- is the design property that makes N = 1 a configuration rather than a
-- variant: the schedule is data, so a single card is a shorter table and not
-- different gateware.  18 -> 16 steps for a GDN block, 15 -> 13 for attention.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;

package seq_tbl_pkg is

  -- ---- opcodes, D design spec section 6.1 --------------------------------
  constant OP_A_JOB     : natural := 0;
  constant OP_B_JOB     : natural := 1;
  constant OP_C_JOB     : natural := 2;
  constant OP_E_COLL    : natural := 3;
  constant OP_VEC_NORM  : natural := 4;
  constant OP_VEC_RES   : natural := 5;
  constant OP_VEC_SWG   : natural := 6;
  constant OP_END_TOKEN : natural := 7;

  -- ---- flags -------------------------------------------------------------
  constant FLG_TO_E   : natural := 1;   -- bit 0, route y to E (partial mode)
  constant FLG_TO_SMP : natural := 2;   -- bit 1, route y to sampler (raw mode)
  constant FLG_CB     : natural := 4;   -- bit 2, load the codebook first
  constant FLG_E_NEXT : natural := 8;   -- bit 3, an E step follows this job

  -- ---- the region map, D design spec section 5.1 -------------------------
  -- Named, not addressed: O8 and part of O9 are discharged by the fact that
  -- no descriptor can express an overlap between two named regions.
  constant R_X     : natural := 0;   -- residual stream
  constant R_XN    : natural := 1;   -- post-norm activations
  constant R_QKV   : natural := 2;   -- GDN q | k | v, in that channel order
  constant R_Z     : natural := 3;   -- GDN gate
  constant R_BETA  : natural := 4;
  constant R_ALPHA : natural := 5;
  constant R_QG    : natural := 6;   -- attention Q + gate, interleaved
  constant R_KIN   : natural := 7;
  constant R_VIN   : natural := 8;
  constant R_Y     : natural := 9;   -- B's y or C's y
  constant R_G     : natural := 10;  -- FFN gate
  constant R_U     : natural := 11;  -- FFN up
  constant R_H     : natural := 12;  -- FFN hidden, post-swiglu
  constant R_ER    : natural := 13;  -- reduced collective result, or direct BFP at N=1
  constant NREGION : natural := 14;
  constant R_NONE  : natural := 255; -- 0xFF, "no region"

  -- ---- shapes, all derived from model_cfg_pkg ----------------------------
  constant HID      : natural := MODEL.hidden;
  constant FFN      : natural := MODEL.ffn;
  constant VAL_H    : natural := val_heads_per_card(MODEL, NCARDS);
  constant KEY_H    : natural := key_heads_per_card(MODEL, NCARDS);
  constant HDIM     : natural := MODEL.lin_head_dim;
  constant KEY_DIM  : natural := KEY_H * HDIM;          -- GDN key width, this card
  constant VAL_DIM  : natural := VAL_H * HDIM;          -- GDN value width, this card
  constant QKV_DIM  : natural := 2*KEY_DIM + VAL_DIM;   -- q | k | v, contiguous
  constant AQ_H     : natural := MODEL.attn_q_heads / NCARDS;
  constant AKV_H    : natural := MODEL.attn_kv_heads;
  constant AHD      : natural := MODEL.attn_head_dim;
  constant ATT_Q    : natural := AQ_H * AHD;            -- attention Q width
  constant ATT_QG   : natural := 2 * ATT_Q;             -- Q and gate interleaved
  constant ATT_KV   : natural := AKV_H * AHD;
  constant VOCAB_SH : natural := MODEL.vocab / NCARDS;  -- lm_head shard

  -- ---- region capacities, used by the lock manager -----------------------
  -- Sized to the largest tenant of each region across both block types.
  function region_sizes return integer_vector;

  -- ---- step counts -------------------------------------------------------
  -- 18 and 15 at NCARDS > 1; the two E_COLL steps per block vanish at N = 1.
  constant NSTEP_GDN  : natural := 16 + (2 * boolean'pos(NCARDS > 1));
  constant NSTEP_ATTN : natural := 13 + (2 * boolean'pos(NCARDS > 1));
  constant TBL_STEPS  : natural := gdn_layers(MODEL)  * NSTEP_GDN
                                 + attn_layers(MODEL) * NSTEP_ATTN
                                 + 3;   -- final norm, lm_head, END_TOKEN
  constant TBL_WORDS  : natural := TBL_STEPS * 8;

  type desc_t is array (0 to 7) of std_logic_vector(63 downto 0);
  type tbl_t  is array (0 to TBL_WORDS-1) of std_logic_vector(63 downto 0);

  -- Encode one 64-byte header.  Pad bytes are written as 0x00 because the
  -- decoder CHECKS them; a generator that leaves junk there is telling the
  -- gateware it writes a field the gateware does not know about.
  function mk_desc(
    opcode     : natural;
    flags      : natural := 0;
    src        : natural := R_NONE;
    src2       : natural := R_NONE;
    dst        : natural := R_NONE;
    dst_off    : natural := 0;
    n_rows     : natural := 0;
    n_cols     : natural := 0;
    w_exp      : integer := 0;
    out_shift  : integer := 0;
    out_mode   : natural := 0;
    ordinal    : natural := 0;
    nsub_w     : natural := 0;
    nsub_s     : natural := 0;
    const_base : natural := 0;
    const_exp  : integer := 0) return desc_t;

  function build_table return tbl_t;

  -- True for a block that is full attention rather than Gated DeltaNet.
  function is_attn(i : natural) return boolean;

end package;

package body seq_tbl_pkg is

  function is_attn(i : natural) return boolean is
  begin
    return ((i + 1) mod MODEL.attn_interval) = 0;
  end function;

  function region_sizes return integer_vector is
    variable s : integer_vector(0 to NREGION-1);
  begin
    s(R_X)     := HID;
    s(R_XN)    := HID;
    s(R_QKV)   := QKV_DIM;
    s(R_Z)     := VAL_DIM;
    s(R_BETA)  := VAL_H;
    s(R_ALPHA) := VAL_H;
    s(R_QG)    := ATT_QG;
    s(R_KIN)   := ATT_KV;
    s(R_VIN)   := ATT_KV;
    -- Y holds B's y (VAL_DIM) or C's y (ATT_Q), whichever is larger.
    if VAL_DIM > ATT_Q then s(R_Y) := VAL_DIM; else s(R_Y) := ATT_Q; end if;
    s(R_G)     := FFN;
    s(R_U)     := FFN;
    s(R_H)     := FFN;
    s(R_ER)    := HID;
    return s;
  end function;

  function mk_desc(
    opcode     : natural;
    flags      : natural := 0;
    src        : natural := R_NONE;
    src2       : natural := R_NONE;
    dst        : natural := R_NONE;
    dst_off    : natural := 0;
    n_rows     : natural := 0;
    n_cols     : natural := 0;
    w_exp      : integer := 0;
    out_shift  : integer := 0;
    out_mode   : natural := 0;
    ordinal    : natural := 0;
    nsub_w     : natural := 0;
    nsub_s     : natural := 0;
    const_base : natural := 0;
    const_exp  : integer := 0) return desc_t is
    variable d : desc_t := (others => (others => '0'));
  begin
    d(0)(7 downto 0)   := std_logic_vector(to_unsigned(opcode, 8));
    d(0)(15 downto 8)  := std_logic_vector(to_unsigned(flags, 8));
    d(0)(23 downto 16) := std_logic_vector(to_unsigned(src, 8));
    d(0)(31 downto 24) := std_logic_vector(to_unsigned(dst, 8));
    d(0)(63 downto 32) := std_logic_vector(to_unsigned(dst_off, 32));
    d(1)(31 downto 0)  := std_logic_vector(to_unsigned(n_rows, 32));
    d(1)(63 downto 32) := std_logic_vector(to_unsigned(n_cols, 32));
    d(2)(31 downto 0)  := std_logic_vector(to_signed(w_exp, 32));
    d(2)(63 downto 32) := std_logic_vector(to_signed(out_shift, 32));
    d(3)(7 downto 0)   := std_logic_vector(to_unsigned(out_mode, 8));
    d(3)(15 downto 8)  := std_logic_vector(to_unsigned(ordinal, 8));
    d(3)(31 downto 16) := std_logic_vector(to_unsigned(nsub_w, 16));
    d(3)(47 downto 32) := std_logic_vector(to_unsigned(nsub_s, 16));
    d(3)(55 downto 48) := std_logic_vector(to_unsigned(src2, 8));
    -- d(3)(63 downto 56) is PAD and stays 0x00.
    d(4)(31 downto 0)  := std_logic_vector(to_unsigned(const_base, 32));
    d(4)(63 downto 32) := std_logic_vector(to_signed(const_exp, 32));
    -- d(5), d(6) are the codebook, zero unless cb_load; d(7) is PAD.
    return d;
  end function;

  function build_table return tbl_t is
    variable t   : tbl_t := (others => (others => '0'));
    variable p   : natural := 0;    -- descriptor index
    variable d   : desc_t;
    variable go  : natural;         -- GDN ordinal, 0 .. gdn_layers-1
    variable ao  : natural;         -- attention ordinal
    variable nsw : natural := 29;   -- weight bases per A job, D section 2.2-J
    variable nss : natural := 4;    -- scale bases per A job

    procedure emit(dd : desc_t) is
    begin
      for w in 0 to 7 loop
        t(p*8 + w) := dd(w);
      end loop;
      p := p + 1;
    end procedure;

    -- The FFN half, identical in both block types (D section 4.2 steps 12-18
    -- and section 4.3 steps 9-15).  At N = 1 the down projection writes ER
    -- directly instead of streaming partials to E.
    procedure emit_ffn(blk : natural) is
    begin
      emit(mk_desc(OP_VEC_NORM, src => R_X, dst => R_XN, n_rows => HID,
                   const_base => blk, ordinal => blk mod 64));
      emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_G, n_rows => FFN,
                   n_cols => HID, nsub_w => nsw, nsub_s => nss, out_mode => 0));
      emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_U, n_rows => FFN,
                   n_cols => HID, nsub_w => nsw, nsub_s => nss, out_mode => 0));
      emit(mk_desc(OP_VEC_SWG, src => R_G, src2 => R_U, dst => R_H,
                   n_rows => FFN));
      if NCARDS = 1 then
        emit(mk_desc(OP_A_JOB, src => R_H, dst => R_ER, n_rows => HID,
                     n_cols => FFN, nsub_w => nsw, nsub_s => nss, out_mode => 0));
      else
        emit(mk_desc(OP_A_JOB, flags => FLG_TO_E + FLG_E_NEXT, src => R_H,
                     dst => R_NONE, n_rows => HID, n_cols => FFN,
                     nsub_w => nsw, nsub_s => nss, out_mode => 2));
        emit(mk_desc(OP_E_COLL, src => R_NONE, dst => R_ER, n_rows => HID));
      end if;
      emit(mk_desc(OP_VEC_RES, src => R_X, src2 => R_ER, dst => R_X,
                   n_rows => HID));
    end procedure;

  begin
    for blk in 0 to MODEL.blocks-1 loop
      if is_attn(blk) then
        ao := (blk - (MODEL.attn_interval-1)) / MODEL.attn_interval;
        -- 1 attn_norm
        emit(mk_desc(OP_VEC_NORM, src => R_X, dst => R_XN, n_rows => HID,
                     const_base => blk, ordinal => blk mod 64));
        -- 2 wq, Q and gate interleaved per head
        emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_QG, n_rows => ATT_QG,
                     n_cols => HID, nsub_w => nsw, nsub_s => nss));
        -- 3 wk, 4 wv
        emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_KIN, n_rows => ATT_KV,
                     n_cols => HID, nsub_w => nsw, nsub_s => nss));
        emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_VIN, n_rows => ATT_KV,
                     n_cols => HID, nsub_w => nsw, nsub_s => nss));
        -- 5 attention itself
        emit(mk_desc(OP_C_JOB, src => R_QG, dst => R_Y, n_rows => ATT_Q,
                     ordinal => ao));
        -- 6 wo
        if NCARDS = 1 then
          emit(mk_desc(OP_A_JOB, src => R_Y, dst => R_ER, n_rows => HID,
                       n_cols => ATT_Q, nsub_w => nsw, nsub_s => nss));
        else
          emit(mk_desc(OP_A_JOB, flags => FLG_TO_E + FLG_E_NEXT, src => R_Y,
                       dst => R_NONE, n_rows => HID, n_cols => ATT_Q,
                       nsub_w => nsw, nsub_s => nss, out_mode => 2));
          emit(mk_desc(OP_E_COLL, src => R_NONE, dst => R_ER, n_rows => HID));
        end if;
        -- 7 residual
        emit(mk_desc(OP_VEC_RES, src => R_X, src2 => R_ER, dst => R_X,
                     n_rows => HID));
        emit_ffn(blk);
      else
        go := blk - (blk + 1) / MODEL.attn_interval;
        -- 1 attn_norm
        emit(mk_desc(OP_VEC_NORM, src => R_X, dst => R_XN, n_rows => HID,
                     const_base => blk, ordinal => blk mod 64));
        -- 2, 3, 4: wqkv as THREE jobs at fixed offsets in one region, so each
        -- segment gets its own y_exp.  q | k | v, the channel order B's single
        -- read port expects.
        emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_QKV, dst_off => 0,
                     n_rows => KEY_DIM, n_cols => HID,
                     nsub_w => nsw, nsub_s => nss));
        emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_QKV, dst_off => KEY_DIM,
                     n_rows => KEY_DIM, n_cols => HID,
                     nsub_w => nsw, nsub_s => nss));
        emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_QKV,
                     dst_off => 2*KEY_DIM, n_rows => VAL_DIM, n_cols => HID,
                     nsub_w => nsw, nsub_s => nss));
        -- 5 gate, 6 beta, 7 alpha
        emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_Z, n_rows => VAL_DIM,
                     n_cols => HID, nsub_w => nsw, nsub_s => nss));
        emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_BETA, n_rows => VAL_H,
                     n_cols => HID, nsub_w => nsw, nsub_s => nss));
        emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_ALPHA, n_rows => VAL_H,
                     n_cols => HID, nsub_w => nsw, nsub_s => nss));
        -- 8 the GDN sweep
        emit(mk_desc(OP_B_JOB, src => R_QKV, dst => R_Y, n_rows => VAL_DIM,
                     ordinal => go));
        -- 9 ssm_out
        if NCARDS = 1 then
          emit(mk_desc(OP_A_JOB, src => R_Y, dst => R_ER, n_rows => HID,
                       n_cols => VAL_DIM, nsub_w => nsw, nsub_s => nss));
        else
          emit(mk_desc(OP_A_JOB, flags => FLG_TO_E + FLG_E_NEXT, src => R_Y,
                       dst => R_NONE, n_rows => HID, n_cols => VAL_DIM,
                       nsub_w => nsw, nsub_s => nss, out_mode => 2));
          emit(mk_desc(OP_E_COLL, src => R_NONE, dst => R_ER, n_rows => HID));
        end if;
        -- 10 residual
        emit(mk_desc(OP_VEC_RES, src => R_X, src2 => R_ER, dst => R_X,
                     n_rows => HID));
        emit_ffn(blk);
      end if;
    end loop;

    -- Token tail: final norm, lm_head in raw mode straight into the sampler,
    -- then END_TOKEN.  lm_head is the one job whose destination is 0xFF with
    -- the sampler route flag, which is exactly the case the decoder checks.
    emit(mk_desc(OP_VEC_NORM, src => R_X, dst => R_XN, n_rows => HID,
                 const_base => MODEL.blocks, ordinal => 0));
    emit(mk_desc(OP_A_JOB, flags => FLG_TO_SMP, src => R_XN, dst => R_NONE,
                 n_rows => VOCAB_SH, n_cols => HID,
                 nsub_w => nsw, nsub_s => nss, out_mode => 1));
    emit(mk_desc(OP_END_TOKEN));

    assert p = TBL_STEPS
      report "seq_tbl_pkg: emitted " & integer'image(p) & " descriptors but "
           & "TBL_STEPS says " & integer'image(TBL_STEPS)
      severity failure;
    return t;
  end function;

end package body;
