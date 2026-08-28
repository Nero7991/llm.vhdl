-- sim/llama_sched_pkg.vhd
-- The host-side descriptor-table generator for `rtl/llama_top.vhd`, at an
-- ARBITRARY shape.
--
-- WHY THIS EXISTS ALONGSIDE sim/seq_tbl_pkg.vhd, WHICH ALREADY BUILDS A TABLE.
--
-- `seq_tbl_pkg.build_table` emits the real 491-descriptor Qwen3.5-9B token and
-- every dimension in it is a constant folded off `model_cfg_pkg.MODEL`.  That
-- is exactly right for what it is for, and it is unusable for an integration
-- simulation: 491 steps at hidden 4096 and FFN 12288 is tens of millions of
-- element-cycles, which GHDL will not finish inside a working day.
--
-- So this package emits the SAME STEP SEQUENCE from a `shape_t`, which can be
-- the real 9B shape or a scaled one.  What is preserved is everything the
-- integration is about:
--
--   * the per-block step sequence, descriptor for descriptor, in order;
--   * the region each step reads and writes, including the three-way `dst_off`
--     split of R_QKV that `seq_opdec`'s MSEG mechanism infers segments from;
--   * the IN-PLACE residual, R_X + R_ER -> R_X, twice per block;
--   * the interleaving of GDN and attention blocks at `attn_interval`.
--
-- What is NOT preserved is the element counts.  A step that moves 4,096
-- elements at 9B moves 32 here.  That is a deliberate and stated limitation:
-- this table exercises SEQUENCING, not throughput.
--
-- THE ENCODING IS NOT REIMPLEMENTED.  Every descriptor is built by
-- `seq_tbl_pkg.mk_desc`, the same function the real table uses, so every field
-- lands in the byte `rtl/seq_desc_fetch.vhd` reads.  A change to the wire
-- format therefore cannot make this table and the real one disagree.
--
-- THE RELEASE MASK IS COMPUTED HERE, and that is a finding rather than a
-- convenience.  `rtl/seq_opdec.vhd` finding (3) says the release mask is a
-- LIVENESS property of the whole table -- "is this the last step that reads
-- region R before something re-produces it" -- which only a whole-table pass
-- knows, which means the host generator knows it, and the section 6.1
-- descriptor format has no field for it.  So it arrives on the `rel_mask`
-- port, and this package is the whole-table pass that computes it.  If the
-- format ever grows the field, `build_rel` is the reference for what belongs
-- in it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.llama_map_pkg.all;
use work.seq_tbl_pkg.mk_desc;
use work.seq_tbl_pkg.desc_t;

package llama_sched_pkg is

  -- Big enough for the real 9B token (491) with room; the table is sized once
  -- and the live length is `n_steps(shape)`.
  constant SCHED_MAX_STEPS : natural := 640;
  constant SCHED_MAX_WORDS : natural := SCHED_MAX_STEPS * 8;

  type sched_tbl_t is array (0 to SCHED_MAX_WORDS-1)
                      of std_logic_vector(63 downto 0);

  -- One row per step, for the testbench to check the issue sequence against.
  -- This is the ORACLE FOR THE SCHEDULE: the property "the machine issued
  -- exactly this sequence of units, in this order" needs no arithmetic
  -- reference and is checkable today.
  type plan_step_t is record
    opcode : natural;
    unit   : natural;
    src    : natural;
    src2   : natural;
    dst    : natural;
    dst_off: natural;
    n_rows : natural;
    n_cols : natural;
    blk    : natural;                 -- which transformer block this step is in
    rel    : std_logic_vector(NREGION-1 downto 0);
  end record;
  type plan_t is array (0 to SCHED_MAX_STEPS-1) of plan_step_t;

  constant PLAN_STEP_CLR : plan_step_t :=
    (opcode => OP_END_TOKEN, unit => U_A, src => R_NONE, src2 => R_NONE,
     dst => R_NONE, dst_off => 0, n_rows => 0, n_cols => 0, blk => 0,
     rel => (others => '0'));

  function unit_of(opcode : natural) return natural;

  -- The plan first; the table is an encoding of the plan.
  function build_plan (s : shape_t) return plan_t;
  function build_table(s : shape_t) return sched_tbl_t;

end package;

package body llama_sched_pkg is

  function unit_of(opcode : natural) return natural is
  begin
    case opcode is
      when OP_A_JOB     => return U_A;
      when OP_B_JOB     => return U_B;
      when OP_C_JOB     => return U_C;
      when OP_E_COLL    => return U_E;
      when OP_END_TOKEN => return U_A;   -- starts nobody; value is unused
      when others       => return U_V;   -- the three D-vec opcodes
    end case;
  end function;

  -- The set of regions a step CONSUMES: its two region bytes plus the
  -- per-opcode extra mask, which is exactly what `seq_opdec` computes.
  function cons_of(p : plan_step_t) return std_logic_vector is
    variable m : std_logic_vector(NREGION-1 downto 0) := (others => '0');
    variable e : natural;
  begin
    if p.opcode = OP_END_TOKEN then return m; end if;
    if p.src  < NREGION then m(p.src)  := '1'; end if;
    if p.src2 < NREGION then m(p.src2) := '1'; end if;
    e := OPC_CONS_MAP(p.opcode);
    for i in 0 to NREGION-1 loop
      if (e / (2**i)) mod 2 = 1 then m(i) := '1'; end if;
    end loop;
    return m;
  end function;

  function prod_of(p : plan_step_t) return std_logic_vector is
    variable m : std_logic_vector(NREGION-1 downto 0) := (others => '0');
  begin
    if p.opcode /= OP_END_TOKEN and p.dst < NREGION then m(p.dst) := '1'; end if;
    return m;
  end function;

  -- THE LIVENESS PASS.  For step i and region R consumed by i, set rel(R) iff
  -- no step strictly after i consumes R before some step re-produces it.
  -- Scanning forward from i+1: the first step that either consumes or produces
  -- R decides.  Consume first -> i is not the last reader.  Produce first, or
  -- end of table -> i is.
  --
  -- The IN-PLACE residual is the case that makes this non-obvious: step i has
  -- R_X in BOTH sets.  It is handled by starting the scan at i+1, so a step
  -- never treats its own production as the thing that ends its own liveness.
  procedure build_rel(variable p : inout plan_t; nst : natural) is
    variable c, q : std_logic_vector(NREGION-1 downto 0);
    variable done : boolean;
  begin
    for i in 0 to nst-1 loop
      c := cons_of(p(i));
      p(i).rel := (others => '0');
      for r in 0 to NREGION-1 loop
        if c(r) = '1' then
          done := false;
          for j in i+1 to nst-1 loop
            if not done then
              if cons_of(p(j))(r) = '1' then
                done := true;                      -- a later reader exists
              elsif prod_of(p(j))(r) = '1' then
                p(i).rel(r) := '1';                -- re-produced, i was last
                done := true;
              end if;
            end if;
          end loop;
          if not done then p(i).rel(r) := '1'; end if;  -- last step of token
        end if;
      end loop;
    end loop;
  end procedure;

  function build_plan(s : shape_t) return plan_t is
    variable p   : plan_t := (others => PLAN_STEP_CLR);
    variable n   : natural := 0;
    variable blk : natural := 0;

    procedure emit(opcode : natural;
                   src : natural := R_NONE; src2 : natural := R_NONE;
                   dst : natural := R_NONE; dst_off : natural := 0;
                   n_rows : natural := 0; n_cols : natural := 0) is
    begin
      p(n) := (opcode => opcode, unit => unit_of(opcode),
               src => src, src2 => src2, dst => dst, dst_off => dst_off,
               n_rows => n_rows, n_cols => n_cols, blk => blk,
               rel => (others => '0'));
      n := n + 1;
    end procedure;

    -- The FFN tail, identical for a GDN block and an attention block.  Five
    -- steps at N=1: norm, gate matvec, up matvec, swiglu, down matvec,
    -- residual.  Six.  Counting it as five is the arithmetic slip that makes
    -- 16 look like 15, so it is written out rather than summarised.
    procedure emit_ffn is
    begin
      emit(OP_VEC_NORM, src => R_X,  dst => R_XN, n_rows => s.hidden);
      emit(OP_A_JOB,    src => R_XN, dst => R_G,  n_rows => s.ffn,
           n_cols => s.hidden);
      emit(OP_A_JOB,    src => R_XN, dst => R_U,  n_rows => s.ffn,
           n_cols => s.hidden);
      emit(OP_VEC_SWG,  src => R_G, src2 => R_U, dst => R_H,
           n_rows => s.ffn);
      emit(OP_A_JOB,    src => R_H,  dst => R_ER, n_rows => s.hidden,
           n_cols => s.ffn);
      emit(OP_VEC_RES,  src => R_X, src2 => R_ER, dst => R_X,
           n_rows => s.hidden);
    end procedure;

  begin
    for b in 0 to s.blocks-1 loop
      blk := b;
      if is_attn_block(s, b) then
        emit(OP_VEC_NORM, src => R_X,  dst => R_XN,  n_rows => s.hidden);
        emit(OP_A_JOB,    src => R_XN, dst => R_QG,  n_rows => att_qg(s),
             n_cols => s.hidden);
        emit(OP_A_JOB,    src => R_XN, dst => R_KIN, n_rows => att_kv(s),
             n_cols => s.hidden);
        emit(OP_A_JOB,    src => R_XN, dst => R_VIN, n_rows => att_kv(s),
             n_cols => s.hidden);
        emit(OP_C_JOB,    src => R_QG, dst => R_Y,   n_rows => att_q(s));
        emit(OP_A_JOB,    src => R_Y,  dst => R_ER,  n_rows => s.hidden,
             n_cols => att_q(s));
        emit(OP_VEC_RES,  src => R_X, src2 => R_ER, dst => R_X,
             n_rows => s.hidden);
        emit_ffn;
      else
        emit(OP_VEC_NORM, src => R_X,  dst => R_XN, n_rows => s.hidden);
        -- q, k, v into ONE region at three offsets.  The offsets are what
        -- seq_opdec's MSEG mechanism turns into exponent segments 0, 1, 2, so
        -- they are load-bearing and not cosmetic.
        emit(OP_A_JOB, src => R_XN, dst => R_QKV, dst_off => 0,
             n_rows => key_dim(s), n_cols => s.hidden);
        emit(OP_A_JOB, src => R_XN, dst => R_QKV, dst_off => key_dim(s),
             n_rows => key_dim(s), n_cols => s.hidden);
        emit(OP_A_JOB, src => R_XN, dst => R_QKV, dst_off => 2*key_dim(s),
             n_rows => val_dim(s), n_cols => s.hidden);
        emit(OP_A_JOB, src => R_XN, dst => R_Z,     n_rows => val_dim(s),
             n_cols => s.hidden);
        emit(OP_A_JOB, src => R_XN, dst => R_BETA,  n_rows => s.val_heads,
             n_cols => s.hidden);
        emit(OP_A_JOB, src => R_XN, dst => R_ALPHA, n_rows => s.val_heads,
             n_cols => s.hidden);
        emit(OP_B_JOB, src => R_QKV, dst => R_Y, n_rows => val_dim(s));
        emit(OP_A_JOB, src => R_Y,  dst => R_ER, n_rows => s.hidden,
             n_cols => val_dim(s));
        emit(OP_VEC_RES, src => R_X, src2 => R_ER, dst => R_X,
             n_rows => s.hidden);
        emit_ffn;
      end if;
    end loop;

    blk := s.blocks;
    emit(OP_VEC_NORM, src => R_X, dst => R_XN, n_rows => s.hidden);
    emit(OP_A_JOB,    src => R_XN, dst => R_NONE, n_rows => s.vocab_shard,
         n_cols => s.hidden);
    emit(OP_END_TOKEN);

    assert n = n_steps(s)
      report "llama_sched_pkg: emitted " & integer'image(n)
           & " steps but llama_map_pkg.n_steps says "
           & integer'image(n_steps(s))
           & ".  The two disagree about the block schedule."
      severity failure;

    build_rel(p, n);
    return p;
  end function;

  function build_table(s : shape_t) return sched_tbl_t is
    constant p : plan_t  := build_plan(s);
    constant n : natural := n_steps(s);
    variable t : sched_tbl_t := (others => (others => '0'));
    variable d : desc_t;
    variable fl : natural;
    variable om : natural;
  begin
    assert n <= SCHED_MAX_STEPS
      report "llama_sched_pkg: shape needs " & integer'image(n)
           & " steps, SCHED_MAX_STEPS is " & integer'image(SCHED_MAX_STEPS)
      severity failure;

    for i in 0 to n-1 loop
      fl := 0;
      om := 0;
      -- The lm_head step routes to the sampler in raw mode; it is the only
      -- step with dst = R_NONE that is not END_TOKEN.
      if p(i).opcode = OP_A_JOB and p(i).dst = R_NONE then
        fl := FLG_TO_SMP;
        om := 1;
      end if;
      d := mk_desc(opcode  => p(i).opcode,
                   flags   => fl,
                   src     => p(i).src,
                   src2    => p(i).src2,
                   dst     => p(i).dst,
                   dst_off => p(i).dst_off,
                   n_rows  => p(i).n_rows,
                   n_cols  => p(i).n_cols,
                   out_mode=> om,
                   ordinal => p(i).blk mod 64,
                   -- The base array past the header is range-checked against
                   -- NSUB_MAX by seq_desc_fetch and NOT yet fetched (see its
                   -- header, "Fetching it is remaining work").  The counts are
                   -- the real ones so the check is exercised.
                   nsub_w  => 29,
                   nsub_s  => 4,
                   const_base => p(i).blk);
      -- w_exp / out_shift / const_exp, derived from the step index so that a
      -- stale or shared capture is a WRONG NUMBER and not a repeat of the
      -- right one.
      --
      -- `out_shift` IS NOT FREE TO VARY THE WAY seq_tbl_pkg's IS.
      -- `matvec_core.vhd:850-867` rejects `out_shift < 0` or `out_shift > 40`
      -- at `start` and raises `err` instead of computing.  seq_tbl_pkg emits
      -- `(p mod 23) - 11`, which is negative for eleven steps in every
      -- twenty-three -- fine for a walker testbench that never starts a real
      -- matvec, and an immediate ERR_UNIT for a top level that does.  This
      -- table is walked by the real unit, so the host emits a legal shift.
      -- Stated here rather than clamped in the adapter, because clamping a
      -- descriptor field in gateware is how a schedule and a build come to
      -- disagree silently.
      --
      -- The RANGE is `i mod 5` and not `i mod 17` for a second reason,
      -- measured: at `mod 17` a shift of 16 drives every element of the
      -- scaled shape to zero, and a residual stream of zeros passes a
      -- skew-invariance test perfectly.  A test whose data is all zero is not
      -- a test.
      d(2)(31 downto 0)  := std_logic_vector(to_signed(((i * 7) mod 61) - 30, 32));
      d(2)(63 downto 32) := std_logic_vector(to_signed(i mod 5, 32));
      d(4)(63 downto 32) := std_logic_vector(to_signed(((i * 5) mod 41) - 20, 32));
      for w in 0 to 7 loop
        t(i*8 + w) := d(w);
      end loop;
    end loop;
    return t;
  end function;

end package body;
