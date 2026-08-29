-- rtl/llama_map_pkg.vhd
-- The build-time map that `rtl/llama_top.vhd` is wired against: opcode
-- numbering, unit numbering, region numbering, the per-opcode extra-consume
-- mask, and the model shape reduced to the handful of derived widths the top
-- level actually instantiates against.
--
-- WHY THIS EXISTS, AND WHY IT IS IN rtl/ RATHER THAN sim/.
--
-- `sim/seq_tbl_pkg.vhd` already carries a copy of the opcode and region
-- numbering, because it is the host-side table generator and the table is
-- DATA.  `rtl/seq_opdec.vhd` says in its own header, finding (1), that the
-- region map nevertheless "leaks out of the table and into the build": the
-- consume mask `OPC_CONS` is a GENERIC, so the gateware knows which regions a
-- B job or a C job reads.  That leak is real and it is not this file's to fix.
-- What this file fixes is the SECOND-ORDER hazard it creates: with the map in
-- sim/ only, an rtl/ top level that needs it either duplicates it silently or
-- makes rtl/ depend on sim/.  Both are worse than one named copy with an
-- equality assertion pointing at it.
--
-- `sim/tb_llama_top.vhd` asserts, at elaboration, that every constant here
-- equals the `seq_tbl_pkg` constant of the same name.  If somebody renumbers a
-- region on one side the run stops with a named mismatch rather than
-- addressing the wrong BRAM for a token.
--
-- NOTHING HERE IS HARDCODED TO 9B.  `shape_t` is derived from
-- `model_cfg_pkg.MODEL` by `mk_shape`, and every width the top level needs is
-- a function of it.  A scaled-down shape for simulation is built with
-- `mk_shape_scaled`, which keeps every RATIO the schedule depends on and
-- shrinks only the counts -- so a 4-block sim exercises the same descriptor
-- sequence per block that a 32-block token does.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;

package llama_map_pkg is

  -- ---- opcodes.  MUST equal sim/seq_tbl_pkg.vhd -------------------------
  constant OP_A_JOB     : natural := 0;   -- INT4 matvec, subsystem A
  constant OP_B_JOB     : natural := 1;   -- Gated DeltaNet block, subsystem B
  constant OP_C_JOB     : natural := 2;   -- gated attention, subsystem C
  constant OP_E_COLL    : natural := 3;   -- tensor-parallel collective, N>1 only
  constant OP_VEC_NORM  : natural := 4;   -- D-vec: rmsnorm
  constant OP_VEC_RES   : natural := 5;   -- D-vec: residual add, IN PLACE
  constant OP_VEC_SWG   : natural := 6;   -- D-vec: swiglu
  constant OP_END_TOKEN : natural := 7;

  -- ---- units, as indexed by `job_unit` and the u_* vectors ---------------
  constant U_A    : natural := 0;
  constant U_B    : natural := 1;
  constant U_C    : natural := 2;
  constant U_E    : natural := 3;
  constant U_V    : natural := 4;
  constant NUNIT  : positive := 5;

  -- ---- the three engines behind the D-vec adapter ------------------------
  -- Index = opcode - OP_VEC_NORM, which is the contract `seq_vec_issue`
  -- implements with its OP_BASE generic.
  constant V_NORM : natural := 0;
  constant V_RES  : natural := 1;
  constant V_SWG  : natural := 2;
  constant NVOP   : positive := 3;

  -- Subsystem A's AXI master count: NPORTS_W weight ports plus one dedicated
  -- scale port.  A build-time constant rather than a generic because the port
  -- LIST of `llama_top` depends on it, and because `weight_streamer.vhd`
  -- pins NPORTS_W = ROWS_IF = 4 at BLK 32 / AXI_DW 128 anyway.
  constant A_NPORTS : positive := 5;

  -- ---- regions.  MUST equal sim/seq_tbl_pkg.vhd -------------------------
  constant R_X     : natural := 0;   -- residual stream.  THE SPINE.
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
  constant R_ER    : natural := 13;  -- reduced collective result, or direct at N=1
  constant NREGION : natural := 14;
  constant R_NONE  : natural := 255;

  -- ---- the per-opcode EXTRA consume mask, `seq_opdec` generic OPC_CONS ---
  -- The descriptor has two region bytes; B reads four regions and C reads
  -- three, so the remainder is a build-time constant.  See seq_opdec finding
  -- (1).  Bit i = region i.
  --   OP_B_JOB  : Z | BETA | ALPHA          = 8 + 16 + 32   = 56
  --   OP_C_JOB  : KIN | VIN                 = 128 + 256     = 384
  --   OP_VEC_RES: ER                        = 8192
  --   OP_VEC_SWG: U                         = 2048
  constant OPC_CONS_MAP : integer_vector(0 to 7) :=
    (0, 56, 384, 0, 0, 8192, 2048, 0);

  -- ---- descriptor flag bits ---------------------------------------------
  constant FLG_TO_E   : natural := 1;
  constant FLG_TO_SMP : natural := 2;
  constant FLG_CB     : natural := 4;
  constant FLG_E_NEXT : natural := 8;

  -- ======================================================================
  -- THE SHAPE
  -- ======================================================================
  type shape_t is record
    blocks        : positive;
    attn_interval : positive;
    hidden        : positive;
    ffn           : positive;
    key_heads     : positive;   -- GDN linear key heads, THIS card
    val_heads     : positive;   -- GDN linear value heads, THIS card
    head_dim      : positive;   -- GDN key head dim = value head dim
    conv_kernel   : positive;
    attn_q_heads  : positive;   -- THIS card
    attn_kv_heads : positive;
    attn_head_dim : positive;
    vocab_shard   : positive;
  end record;

  function mk_shape(m : model_cfg_t; ncards : positive) return shape_t;

  -- A shape for simulation.  Every RATIO the schedule depends on is preserved
  -- -- attention every `attn_interval` blocks, q|k|v contiguous in that order,
  -- FFN wider than hidden -- and only the counts shrink.  `blocks` is an
  -- explicit argument so a 4-block run and a 32-block run differ in ONE place.
  -- `attn_hd` exists ONLY because `rtl/attn_block.vhd` and `rtl/attn_emit.vhd`
  -- refuse to run at the 2 query heads / 1 KV head / head dim 32 this function
  -- used to hardcode.  Three separate constraints, each of which produces a
  -- failure rather than a wrong number:
  --   * attn_block folds `kq_scale = 1/sqrt(HEAD_DIM)` into an exponent, which
  --     is exact only for an EVEN power of two.  32 is 2**5.
  --   * attn_mac_array needs a GQA group of at least 2, which holds either way.
  --   * attn_emit assigns `grp <= 1` at S_IDLE with `grp` ranged 0 to NGRP-1,
  --     so NGRP = 1 -- one KV head -- is a bound check failure.  That is a
  --     latent defect in a verified unit and it is NOT fixed here; the shape
  --     avoids it.
  --
  -- THE ATTENTION REGION SIZES DO NOT MOVE, and that is the point.  Only the
  -- SPLIT changes: `attn_q_heads * attn_head_dim` stays 64 and
  -- `attn_kv_heads * attn_head_dim` stays 32 at every legal `attn_hd`, so
  -- att_q, att_qg and att_kv -- and therefore every descriptor, every region
  -- size and every published landmark -- are IDENTICAL at 32 and at 16.
  function mk_shape_scaled(blocks : positive; attn_interval : positive;
                           attn_hd : positive := 32)
    return shape_t;

  -- derived widths.  Every caller uses these; nobody re-derives them.
  function key_dim  (s : shape_t) return positive;  -- GDN key width
  function val_dim  (s : shape_t) return positive;  -- GDN value width
  function qkv_dim  (s : shape_t) return positive;  -- 2*key_dim + val_dim
  function att_q    (s : shape_t) return positive;
  function att_qg   (s : shape_t) return positive;  -- Q and gate interleaved
  function att_kv   (s : shape_t) return positive;

  function region_sizes (s : shape_t) return integer_vector;
  function region_max   (s : shape_t) return positive;

  function is_attn_block(s : shape_t; i : natural) return boolean;
  function n_gdn_blocks (s : shape_t) return natural;
  function n_attn_blocks(s : shape_t) return natural;

  -- Steps per block and steps per token, at NCARDS=1.  Stated as functions
  -- because every hand-derivation of these in this repo has been wrong once.
  constant NSTEP_GDN_N1  : natural := 16;
  constant NSTEP_ATTN_N1 : natural := 13;
  function n_steps(s : shape_t) return natural;

end package;

package body llama_map_pkg is

  function mk_shape(m : model_cfg_t; ncards : positive) return shape_t is
  begin
    return (blocks        => m.blocks,
            attn_interval => m.attn_interval,
            hidden        => m.hidden,
            ffn           => m.ffn,
            key_heads     => key_heads_per_card(m, ncards),
            val_heads     => val_heads_per_card(m, ncards),
            head_dim      => m.lin_head_dim,
            conv_kernel   => m.conv_kernel,
            attn_q_heads  => m.attn_q_heads / ncards,
            attn_kv_heads => m.attn_kv_heads,
            attn_head_dim => m.attn_head_dim,
            vocab_shard   => m.vocab / ncards);
  end function;

  function mk_shape_scaled(blocks : positive; attn_interval : positive;
                           attn_hd : positive := 32)
    return shape_t is
  begin
    -- THE GDN NUMBERS ARE NOT ARBITRARY.  key_heads 2, val_heads 4,
    -- head_dim 32 is the exact shape `sim/tb_gdn_block.vhd` defaults to and
    -- `sim/run_gdn_block.sh` actually runs, so the real `gdn_block` can be
    -- dropped into this shape without inventing a generic set that merely
    -- passes the elaboration assertions.  `gdn_recur_pipe`'s SLOTS_MIN is
    -- shape-dependent, so a smaller DIM can silently need a larger
    -- RECUR_SLOTS -- the project's stated failure mode for exactly this kind
    -- of shortcut is a wrong number, not an elaboration error.
    --
    --   key_dim 64, val_dim 128, qkv_dim 256, hidden 64, ffn 128.
    --   attention: att_q 64, att_qg 128, att_kv 32, at EVERY legal attn_hd.
    --              attn_hd = 32 -> 2 q heads, 1 kv head (the default, and the
    --              shape every published landmark was measured at).
    --              attn_hd = 16 -> 4 q heads, 2 kv heads (what the real
    --              `attn_block` needs; see the declaration).
    --
    -- attn_hd = 64 IS A THIRD POINT AND IT IS NOT A CONTINUATION OF THE
    -- FORMULA.  64/attn_hd and 32/attn_hd give ONE q head and ZERO kv heads
    -- at attn_hd = 64, which is not a shape.  The reason 64 has to exist at
    -- all is `rtl/attn_kv_axi.vhd`: its record is a byte layout on a 16-byte
    -- granule, so `KV_BLOCK*CM_W/8` must be a multiple of 16 -- KV_BLOCK >= 16
    -- at the mandatory CM_W = 8 -- while `attn_block` needs
    -- HEAD_DIM/KV_BLOCK >= 2 and HEAD_DIM an EVEN power of two.  The smallest
    -- head dim satisfying all three is 64.  So above 32 the HEAD COUNTS are
    -- pinned at the minimum both blocks accept (4 q, 2 kv, GQA group 2) and
    -- the ATTENTION REGION WIDTHS grow with the head dim instead:
    -- att_q 256, att_qg 512, att_kv 128.  Every landmark measured at
    -- attn_hd 16 or 32 is at a DIFFERENT SHAPE from one measured at 64 and
    -- the two are not comparable.
    if attn_hd > 32 then
      return (blocks        => blocks,
              attn_interval => attn_interval,
              hidden        => 64,
              ffn           => 128,
              key_heads     => 2,
              val_heads     => 4,
              head_dim      => 32,
              conv_kernel   => 4,
              attn_q_heads  => 4,
              attn_kv_heads => 2,
              attn_head_dim => attn_hd,
              vocab_shard   => 128);
    end if;
    return (blocks        => blocks,
            attn_interval => attn_interval,
            hidden        => 64,
            ffn           => 128,
            key_heads     => 2,
            val_heads     => 4,
            head_dim      => 32,
            conv_kernel   => 4,
            attn_q_heads  => 64 / attn_hd,
            attn_kv_heads => 32 / attn_hd,
            attn_head_dim => attn_hd,
            vocab_shard   => 128);
  end function;

  function key_dim(s : shape_t) return positive is
  begin return s.key_heads * s.head_dim; end function;

  function val_dim(s : shape_t) return positive is
  begin return s.val_heads * s.head_dim; end function;

  function qkv_dim(s : shape_t) return positive is
  begin return 2*key_dim(s) + val_dim(s); end function;

  function att_q(s : shape_t) return positive is
  begin return s.attn_q_heads * s.attn_head_dim; end function;

  function att_qg(s : shape_t) return positive is
  begin return 2 * att_q(s); end function;

  function att_kv(s : shape_t) return positive is
  begin return s.attn_kv_heads * s.attn_head_dim; end function;

  function region_sizes(s : shape_t) return integer_vector is
    variable r : integer_vector(0 to NREGION-1);
  begin
    r(R_X)     := s.hidden;
    r(R_XN)    := s.hidden;
    r(R_QKV)   := qkv_dim(s);
    r(R_Z)     := val_dim(s);
    r(R_BETA)  := s.val_heads;
    r(R_ALPHA) := s.val_heads;
    r(R_QG)    := att_qg(s);
    r(R_KIN)   := att_kv(s);
    r(R_VIN)   := att_kv(s);
    if val_dim(s) > att_q(s) then r(R_Y) := val_dim(s);
    else                          r(R_Y) := att_q(s); end if;
    r(R_G)     := s.ffn;
    r(R_U)     := s.ffn;
    r(R_H)     := s.ffn;
    r(R_ER)    := s.hidden;
    return r;
  end function;

  function region_max(s : shape_t) return positive is
    constant r : integer_vector := region_sizes(s);
    variable m : positive := 1;
  begin
    for i in r'range loop
      if r(i) > m then m := r(i); end if;
    end loop;
    return m;
  end function;

  function is_attn_block(s : shape_t; i : natural) return boolean is
  begin
    return ((i + 1) mod s.attn_interval) = 0;
  end function;

  function n_attn_blocks(s : shape_t) return natural is
  begin
    return s.blocks / s.attn_interval;
  end function;

  function n_gdn_blocks(s : shape_t) return natural is
  begin
    return s.blocks - n_attn_blocks(s);
  end function;

  function n_steps(s : shape_t) return natural is
  begin
    return n_gdn_blocks(s)  * NSTEP_GDN_N1
         + n_attn_blocks(s) * NSTEP_ATTN_N1
         + 3;   -- final norm, lm_head, END_TOKEN
  end function;

end package body;
