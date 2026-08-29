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
--
-- THE TOKEN IS 505 STEPS, NOT 491.  It was 491 until 2026-08-29, and 491 was
-- wrong: the tail encoded the lm_head as ONE 248,320-row A job, which
-- `matvec_int4_desc_axi`'s S_CHECK refuses in every out_mode.  It is 15 row
-- windows at a stride of 17,376.  See the LM_WINDOWS block below for the
-- derivation and `docs/debugging/2026-08-29_token-input-and-table.md` for the
-- measurement.  Comments and documents elsewhere that say 491 predate this and
-- are describing a table the gateware would not execute.
--
-- WHAT FILLS R_X, AND WHY NO STEP HERE DOES.  The first step of the token is
-- `OP_VEC_NORM` reading R_X, and nothing in this table produces R_X.  That is
-- deliberate and it is the settled design point, not a gap: the HOST writes
-- the embedding row into R_X before releasing the token, and the descriptor
-- program never sees the lookup.  The RTL exists on both halves of that seam
-- -- `rtl/llama_top.vhd:544-547` is the host write port, `:1054-1058` is the
-- write path that overrides every unit and `:1239` exempts it from the region
-- lock, and `rtl/seq_opdec.vhd:611-665` is a whole FSM whose only job is to
-- publish that write into the lock and exponent plane so the first norm does
-- not consume a FREE region.  `rtl/seq_opdec.vhd:128-150` states the reason in
-- its own words.  The alternative -- an `OP_EMBED` opcode and an on-card
-- gather unit -- is recorded as REJECTED, with its costs, in
-- `docs/debugging/2026-08-29_token-input-and-table.md`; the short version is
-- that A already holds 27 of the engine's 30 HBM read ports.  A reader looking
-- for the missing first step should stop looking: there is no opcode for it
-- and there is not meant to be one.

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

  -- ---- the lm_head does NOT fit one A job --------------------------------
  -- This table used to encode the lm_head as a single VOCAB_SH-row job, and
  -- the gateware REFUSES exactly that descriptor.  `matvec_int4_desc_axi`'s
  -- S_CHECK bounds `n_rows` against `MAXROWS_BFP` with NO out_mode test
  -- (`rtl/matvec_int4_desc_axi.vhd:721-726`), because `sh_rows` is
  -- `integer range 0 to MAXROWS_BFP` (`:309`).  A 248,320-row descriptor is
  -- answered `err_code 0x3 err_info 1` in raw AND in BFP, MEASURED with the
  -- RTL as judge in `docs/debugging/2026-08-29_lmhead-window-schedule.md`
  -- section 4.3.  So a one-job lm_head is not a schedule choice; it is an RTL
  -- change nobody has made.
  --
  -- THE STRIDE IS NOT MAXROWS_BFP.  A row window is expressed as a byte offset
  -- on all 27 bases and a sub-region's beats run tile-major, so a window may
  -- only begin on a ROWS_IF tile boundary -- and 17408 mod 48 = 32, so
  -- MAXROWS_BFP is not one.  Flooring to a tile is what makes the two
  -- constraints compatible, and it is also what keeps every job one tile below
  -- OI-8's corner (STRIDE/ROWS_IF = 362 < TILES = 363).  The derivation lives
  -- in `tools/gen_lmhead_windows.py::plan` and is restated, not re-invented,
  -- here.
  --
  -- Both numbers are the FK33 descriptor plane's generics
  -- (`rtl/matvec_int4_desc_axi.vhd:102,108`).  They are literals here because
  -- this package's whole point is to derive the schedule from the MODEL and
  -- from nothing else, and these two are properties of the BUILD, not of the
  -- model.  If the build changes them, this is the line to change.
  constant A_ROWS_IF     : natural := 48;
  constant A_MAXROWS_BFP : natural := 17408;
  -- `positive`, not `natural`: a MAXROWS_BFP below one tile leaves no legal
  -- window at all, and a constraint error at elaboration is a better answer
  -- than an infinite loop or a silent zero-row job.
  constant LM_STRIDE  : positive := (A_MAXROWS_BFP / A_ROWS_IF) * A_ROWS_IF;
  constant LM_WINDOWS : positive := (VOCAB_SH + LM_STRIDE - 1) / LM_STRIDE;

  -- ---- region capacities, used by the lock manager -----------------------
  -- Sized to the largest tenant of each region across both block types.
  function region_sizes return integer_vector;

  -- ---- step counts -------------------------------------------------------
  -- 18 and 15 at NCARDS > 1; the two E_COLL steps per block vanish at N = 1.
  constant NSTEP_GDN  : natural := 16 + (2 * boolean'pos(NCARDS > 1));
  constant NSTEP_ATTN : natural := 13 + (2 * boolean'pos(NCARDS > 1));
  -- The tail is the final norm, the lm_head, and END_TOKEN -- but the lm_head
  -- is LM_WINDOWS A jobs, not one, so the tail is 2 + LM_WINDOWS and not 3.
  -- At the 9B vocabulary on the FK33 build that is 16, and TBL_STEPS is 505.
  -- It was 491 while the table encoded the one job the gateware refuses.
  constant TBL_STEPS  : natural := gdn_layers(MODEL)  * NSTEP_GDN
                                 + attn_layers(MODEL) * NSTEP_ATTN
                                 + 2 + LM_WINDOWS;
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
    out_mode   : natural := 0;
    ordinal    : natural := 0;
    nsub_w     : natural := 0;
    nsub_s     : natural := 0;
    const_base : natural := 0) return desc_t;

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
    out_mode   : natural := 0;
    ordinal    : natural := 0;
    nsub_w     : natural := 0;
    nsub_s     : natural := 0;
    const_base : natural := 0) return desc_t is
    variable d : desc_t := (others => (others => '0'));
  begin
    d(0)(7 downto 0)   := std_logic_vector(to_unsigned(opcode, 8));
    d(0)(15 downto 8)  := std_logic_vector(to_unsigned(flags, 8));
    d(0)(23 downto 16) := std_logic_vector(to_unsigned(src, 8));
    d(0)(31 downto 24) := std_logic_vector(to_unsigned(dst, 8));
    d(0)(63 downto 32) := std_logic_vector(to_unsigned(dst_off, 32));
    d(1)(31 downto 0)  := std_logic_vector(to_unsigned(n_rows, 32));
    d(1)(63 downto 32) := std_logic_vector(to_unsigned(n_cols, 32));
    -- d(2) is w_exp | out_shift and d(4)(63:32) is const_exp.  All three are
    -- STAMPED BY `emit` from the step index, not passed in here; see the
    -- comment there.
    d(3)(7 downto 0)   := std_logic_vector(to_unsigned(out_mode, 8));
    d(3)(15 downto 8)  := std_logic_vector(to_unsigned(ordinal, 8));
    d(3)(31 downto 16) := std_logic_vector(to_unsigned(nsub_w, 16));
    d(3)(47 downto 32) := std_logic_vector(to_unsigned(nsub_s, 16));
    d(3)(55 downto 48) := std_logic_vector(to_unsigned(src2, 8));
    -- d(3)(63 downto 56) is PAD and stays 0x00.
    d(4)(31 downto 0)  := std_logic_vector(to_unsigned(const_base, 32));
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

    -- THE THREE SCALARS THAT QUALIFY A JOB'S OUTPUT ARE STAMPED FROM THE STEP
    -- INDEX, and that is not decoration.  `w_exp`, `out_shift` and
    -- `const_exp` are published by `seq_desc_fetch` alongside `job_valid` and
    -- are read by the started unit for the WHOLE job, so they are exactly the
    -- gdn_conv `e_seg` shape one level up: a scalar that qualifies a stream.
    -- They were all identically ZERO in the first version of this table, and a
    -- zero that is shared by all 505 steps makes every value check on them
    -- vacuous -- a stale scalar, a scalar published one cycle late, and a
    -- scalar that was never driven are all indistinguishable from the correct
    -- one.  `tb_seq_desc_fetch`'s `ord_chk` guard passed against a
    -- deliberately broken DUT for precisely that reason
    -- (`sim/ord_teeth_seq.sh`, break D1b).
    --
    -- Stamped so that a stale or shared value is a WRONG NUMBER and not merely
    -- a repeat, which is the discipline `tb_seq_region_lock` already uses for
    -- `cmp_y_exp`.  The three sequences are coprime-ish and signed, so no two
    -- adjacent steps agree on all three, and none is a function of the others.
    -- Nothing in the gateware range-checks these fields, so any value is legal
    -- table content.
    procedure emit(dd : desc_t) is
      -- NOT `d`: `build_table` already has a `variable d : desc_t` and VHDL is
      -- case-insensitive, so that name would hide it for the whole procedure
      -- (GHDL says so with -Whide, one line above wherever it next goes wrong).
      variable ds : desc_t := dd;
    begin
      ds(2)(31 downto 0)  := std_logic_vector(to_signed(((p * 7) mod 61) - 30, 32));
      ds(2)(63 downto 32) := std_logic_vector(to_signed((p mod 23) - 11, 32));
      ds(4)(63 downto 32) := std_logic_vector(to_signed(((p * 5) mod 41) - 20, 32));
      for w in 0 to 7 loop
        t(p*8 + w) := ds(w);
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

    -- Token tail: final norm, the lm_head in raw mode straight into the
    -- sampler, then END_TOKEN.  The lm_head steps are the ones whose
    -- destination is 0xFF with the sampler route flag, which is exactly the
    -- case the decoder checks.
    emit(mk_desc(OP_VEC_NORM, src => R_X, dst => R_XN, n_rows => HID,
                 const_base => MODEL.blocks, ordinal => 0));

    -- ONE A JOB PER ROW WINDOW, ascending, and every field below is the same
    -- on every window except `n_rows`.
    --
    --   `dst` is R_NONE and `FLG_TO_SMP` is set on EVERY window, not only the
    --   first or the last: each window streams its own slice of the logits and
    --   there is no region write to attribute to one of them.
    --
    --   `dst_off` stays 0 for the same reason.  `seq_opdec` infers an exponent
    --   SEGMENT from a non-zero `dst_offset`, and a stream into the sampler has
    --   no segments; giving the windows offsets would manufacture 15 of them.
    --
    --   `out_mode` is RAW (1) on every window, and that is load-bearing rather
    --   than inherited.  Raw's `y_exp = w_exp + x_exp - out_shift`
    --   (`rtl/matvec_core.vhd:959-961`) carries no per-job term, so all
    --   LM_WINDOWS jobs publish ONE exponent and their s32 payloads are
    --   directly comparable by a running argmax.  BFP's `ns` is a max over the
    --   JOB's rows, so windowing in BFP would hand a sampler whose only input
    --   is a bare 32-bit integer (`rtl/sampler_stream.vhd:27`) fifteen
    --   different exponents.
    --
    -- The last window is the remainder, VOCAB_SH - (LM_WINDOWS-1)*LM_STRIDE,
    -- which is 5,056 at the 9B vocabulary.  Written as a min so a vocabulary
    -- that happens to be a whole multiple of the stride does not emit a
    -- zero-row job, which S_CHECK also refuses.
    for w in 0 to LM_WINDOWS-1 loop
      emit(mk_desc(OP_A_JOB, flags => FLG_TO_SMP, src => R_XN, dst => R_NONE,
                   n_rows => minimum(LM_STRIDE, VOCAB_SH - w*LM_STRIDE),
                   n_cols => HID,
                   nsub_w => nsw, nsub_s => nss, out_mode => 1));
    end loop;

    emit(mk_desc(OP_END_TOKEN));

    assert p = TBL_STEPS
      report "seq_tbl_pkg: emitted " & integer'image(p) & " descriptors but "
           & "TBL_STEPS says " & integer'image(TBL_STEPS)
      severity failure;
    return t;
  end function;

end package body;
