-- gdn_recur_pipe: B 2.1.4's recurrence, COLUMN-PIPELINED.
--
-- Same arithmetic as rtl/gdn_recur.vhd, bit for bit.  Different control.
--
-- WHY THIS EXISTS.  gdn_recur runs passes A, B and C sequentially for one
-- column before starting the next, and measures 58 cycles per column at
-- LANES = 32.  Section 3.1's 589,824-cycle sweep assumes 4 -- one element per
-- lane per cycle, every one of the four per-element multiplies busy every
-- cycle.  A sequential unit cannot reach that at any lane count: each stage's
-- multiplier idles while the other stages run, and the per-column scalar chain
-- (two reductions, the site-7 normalize, the delta scalar, the sh derive) is
-- ~50 of the 58 cycles and does not shrink with LANES at all.  That is why the
-- miss gets WORSE with more lanes: 3.3x at 1, 14.5x at 32.
--
-- The fix is not tuning.  The columns are independent -- section 2.4's
-- column-locality, the property the whole streaming design rests on -- so
-- several can be in flight at once, each in a different stage, and the scalar
-- chain is amortized instead of paid per column.  Engine A works on column c
-- while engine B works on an earlier column and engine C on an earlier one
-- still; all four multipliers are then busy every cycle and the issue interval
-- is NB = DIM/LANES, which IS section 3.1's assumption.
--
-- HOW THE STAGES ARE DECOUPLED, and this is the part that makes it tractable.
-- The obvious construction aligns every engine to a cycle-exact offset
-- computed from the pipeline depths, which is brittle: one miscounted stage
-- and the unit reads a scalar one column early, silently.  Instead each
-- column owns a SLOT, the scalar pipelines write their results into per-slot
-- parameter files tagged with that slot, and the engines read by slot.  The
-- start offsets then only have to be large ENOUGH, not exact, and a valid bit
-- per slot turns "too small" into a loud assertion instead of wrong numbers.
--
-- MEMORIES ARE GROUP-WIDE, NOT ELEMENT-WIDE.  w18 and u are only ever accessed
-- a whole LANES-group at a time, so they are arrays of SLOTS*NB entries of
-- LANES*19 and LANES*35 bits -- 32 entries at LANES = 32 -- rather than
-- DIM-element register files behind a 128:1 mux.  The wide mux is the failure
-- mode that cost rmsnorm_rs 257 MHz until its fetch was registered.
--
-- The k_n and q_s vectors are per-head-per-token, NOT per column: a head's 128
-- columns all see the same ones, so they are held on the ports and every
-- engine selects a group with an NB:1 mux (4:1 at LANES = 32).  They are
-- deliberately not slotted; slotting them would be 2 Kbit per slot for values
-- that never change within a head.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;

entity gdn_recur_pipe is
  generic(
    DIM   : positive := 128;
    LANES : positive := 32;
    SLOTS : positive := 16;       -- power of two, >= columns in flight
    -- See rtl/gdn_recur.vhd for the full note.  shd = 16 reproduces the pinned
    -- recipe exactly, so this generic chooses shd and nothing else, and the
    -- two extra pipeline stages exist in BOTH configurations -- they cost
    -- latency, never issue interval, so the throughput result is unaffected.
    D_NORM : boolean := true;   -- ADOPTED 2026-08-26, see gdn_recur.vhd
    -- See rtl/gdn_recur.vhd for the full note and the measured table.
    TK0_ED : boolean := true    -- ADOPTED 2026-08-26, see gdn_recur.vhd
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    -- per head per token, held stable across the head's columns
    eg     : in  unsigned(15 downto 0);
    beta   : in  unsigned(15 downto 0);
    k_n    : in  std_logic_vector(DIM*16-1 downto 0);
    q_s    : in  std_logic_vector(DIM*16-1 downto 0);
    -- input stream: one LANES-group of the state column per cycle
    s_valid : in std_logic;
    s_first : in std_logic;                                -- group 0 of a column
    s_data  : in std_logic_vector(LANES*16-1 downto 0);
    -- per-column scalars, sampled on s_first
    c_tk0  : in  std_logic;
    c_se_j : in  signed(7 downto 0);
    c_e_v  : in  signed(7 downto 0);
    c_v_j  : in  signed(15 downto 0);
    -- output stream: the requantized state column, same group order
    o_valid : out std_logic;
    o_last  : out std_logic;
    o_data  : out std_logic_vector(LANES*16-1 downto 0);
    -- per-column results, valid with o_last
    o_se_new : out signed(7 downto 0);
    o_acc    : out signed(39 downto 0);
    o_e_o    : out signed(7 downto 0);
    -- The scalar results land AFTER the data stream: o_acc needs the output
    -- reduction, which runs past the last group.  Both are emitted in column
    -- order, so a consumer pairs them by order rather than by a shared strobe.
    o_res_valid : out std_logic;
    o_err_se : out std_logic
  );
end entity;

architecture rtl of gdn_recur_pipe is

  constant NB    : integer := DIM / LANES;
  constant LOG2L : integer := integer(ceil(log2(real(LANES))));
  constant LOG2S : integer := integer(ceil(log2(real(SLOTS))));

  -- Start offsets.  Only lower bounds matter (see the header): each is the
  -- worst-case latency of everything upstream, rounded up to a whole number of
  -- issue intervals so slot arithmetic stays integral.
  --   engine A: NB cycles of stream + 4 pipeline stages before the last
  --             accumulate lands
  --   SCAL1   : LOG2L reduction stages + 7 scalar stages
  --   engine B: NB + 4, then SCAL2 = LOG2L + 2
  function ceil_nb(x : integer) return integer is
  begin
    return ((x + NB - 1) / NB) * NB;
  end function;
  -- Counted, not guessed.  Engine A's last group reaches its accumulate at
  -- start + NB + 4; the sk reduction is LOG2L pipelined stages; SCAL1 is 8
  -- more; and par1 is visible one cycle after it is written.  Same shape for
  -- the B -> C leg with SCAL2's 2 stages.  One extra interval of margin on
  -- each, because the slot handshake makes margin free in correctness terms
  -- and only costs latency -- and because getting it one cycle short is
  -- exactly the failure the par1_v/par2_v assertions below caught.
  -- The "+ NB" terms are the margin, and they are EXPLICIT because an earlier
  -- version claimed margin in a comment while relying on ceil_nb's rounding to
  -- provide it.  That works at LANES = 32, where the rounding happens to add
  -- 2 cycles, and provides exactly ZERO at LANES = 64, where NB = 2 divides the
  -- requirement evenly -- so the one configuration §3.1's upside row depends on
  -- would have sat on the exact edge.
  constant DB : integer := ceil_nb(NB + LOG2L + 15 + NB);
  constant DC : integer := DB + ceil_nb(NB + LOG2L + 8 + NB);
  -- A slot is occupied from its column's issue until engine C has read its u.
  -- Reusing it sooner silently overwrites a column still in flight.
  constant SLOTS_MIN : integer := (DC + 2*NB + NB - 1) / NB;
  -- The reduction trees halve by two each stage and the slot index is a bit
  -- slice of the column counter, so both must be powers of two; NB must be
  -- whole.  gdn_recur asserts this and this unit did not, which would have let
  -- a non-power-of-two LANES silently drop lanes in the trees.
  constant SHAPE_OK : boolean :=
    (2**LOG2L = LANES) and (2**LOG2S = SLOTS) and (NB * LANES = DIM);

  type s16_arr is array (natural range <>) of signed(15 downto 0);
  type s19_arr is array (natural range <>) of signed(18 downto 0);
  type s33_arr is array (natural range <>) of signed(32 downto 0);
  type s35_arr is array (natural range <>) of signed(34 downto 0);
  type s42_arr is array (natural range <>) of signed(41 downto 0);
  type u35_arr is array (natural range <>) of unsigned(34 downto 0);

  -- group-wide memories, addressed slot*NB + group
  type wmem_t is array (0 to SLOTS*NB-1) of std_logic_vector(LANES*19-1 downto 0);
  type umem_t is array (0 to SLOTS*NB-1) of std_logic_vector(LANES*35-1 downto 0);
  signal w18_mem : wmem_t := (others => (others => '0'));
  signal u_mem   : umem_t := (others => (others => '0'));

  -- per-column context carried down a pipeline
  -- The per-column context is CARRIED down each pipeline rather than latched
  -- per column, because a column's tail stages overlap the next column's first
  -- ones: at II = NB the last group's stage 1 runs one cycle after the next
  -- column's stage F.  A single held register would already have been
  -- overwritten by then, silently, which is the pipeline-index defect class
  -- that hit l2norm_rs and which uniform test vectors cannot see.
  type ctx_t is record
    v    : std_logic;
    tk0  : std_logic;
    se_j : signed(7 downto 0);
    e_v  : signed(7 downto 0);
    v_j  : signed(15 downto 0);
    e_u  : signed(15 downto 0);
    d_m  : signed(17 downto 0);
    su   : integer range 0 to 63;
    sk2  : integer range 0 to 63;
    shq  : integer range 0 to 63;
    bias : signed(34 downto 0);
    slot : integer range 0 to SLOTS-1;
    grp  : integer range 0 to NB-1;
  end record;
  constant CTX0 : ctx_t := ('0','0',(others=>'0'),(others=>'0'),(others=>'0'),
                            (others=>'0'),(others=>'0'),0,0,0,(others=>'0'),0,0);
  type ctx_arr is array (natural range <>) of ctx_t;

  -- reduction trees: LOG2L fully-pipelined 2:1 stages
  type red_s_t is array (0 to LOG2L) of s42_arr(0 to LANES-1);
  type red_u_t is array (0 to LOG2L) of u35_arr(0 to LANES-1);
  signal redk, redo : red_s_t := (others => (others => (others => '0')));
  signal reda       : red_u_t := (others => (others => (others => '0')));
  signal redk_c, redo_c : ctx_arr(0 to LOG2L) := (others => CTX0);
  signal reda_c         : ctx_arr(0 to LOG2L) := (others => CTX0);

  -- engine A
  signal a_ctx : ctx_arr(0 to 4) := (others => CTX0);
  signal a_sf, a_kf, a_k1, a_k2 : s16_arr(0 to LANES-1) := (others => (others=>'0'));
  signal a_m1   : s33_arr(0 to LANES-1) := (others => (others=>'0'));
  signal a_w18  : s19_arr(0 to LANES-1) := (others => (others=>'0'));
  signal a_m2   : s42_arr(0 to LANES-1) := (others => (others=>'0'));
  signal a_acc  : s42_arr(0 to LANES-1) := (others => (others=>'0'));

  -- SCAL1: sk normalize and the delta scalar.
  --
  -- EVERY intermediate travels WITH its column.  The chain is 8 stages deep
  -- and the issue interval is NB, so at LANES = 32 two columns are inside it
  -- at once.  Holding ske/skm/diff/dmul in single registers -- which is what
  -- the sequential unit does correctly, because it only ever has one column --
  -- makes the second column overwrite the first mid-flight.  That produced
  -- exactly the symptom a pipeline-index bug always produces here: the first
  -- column's data right, the second half right, everything after it wrong.
  type sc1_t is record
    c     : ctx_t;
    sum   : signed(41 downto 0);
    absv  : unsigned(41 downto 0);
    sh    : integer range 0 to 63;
    bi    : signed(41 downto 0);
    ske   : signed(15 downto 0);
    skm   : signed(17 downto 0);
    ed    : signed(15 downto 0);
    ekd   : signed(15 downto 0);
    diff  : signed(17 downto 0);
    dmul  : signed(34 downto 0);
    dabs  : unsigned(34 downto 0);
    shd   : integer range 0 to 63;
    dbias : signed(34 downto 0);
  end record;
  constant SC1_0 : sc1_t := (CTX0,(others=>'0'),(others=>'0'),0,(others=>'0'),
                             (others=>'0'),(others=>'0'),(others=>'0'),
                             (others=>'0'),(others=>'0'),(others=>'0'),
                             (others=>'0'),16,to_signed(2**15, 35));
  type sc1_arr is array (0 to 9) of sc1_t;
  signal sc1 : sc1_arr := (others => SC1_0);

  -- SCAL2, same reasoning
  type sc2_t is record
    c    : ctx_t;
    amax : unsigned(34 downto 0);
  end record;
  constant SC2_0 : sc2_t := (CTX0, (others => '0'));
  type sc2_arr is array (0 to 2) of sc2_t;
  signal sc2 : sc2_arr := (others => SC2_0);

  -- per-slot parameter files
  type par1_t is record
    d_m : signed(17 downto 0);
    e_u : signed(15 downto 0);
    su  : integer range 0 to 63;
    sk2 : integer range 0 to 63;
    tk0 : std_logic;
  end record;
  type par1_arr is array (0 to SLOTS-1) of par1_t;
  constant PAR1_0 : par1_t := ((others=>'0'),(others=>'0'),0,0,'0');
  signal par1 : par1_arr := (others => PAR1_0);
  signal par1_v : std_logic_vector(SLOTS-1 downto 0) := (others => '0');

  type par2_t is record
    shq  : integer range 0 to 63;
    bias : signed(34 downto 0);
    e_u  : signed(15 downto 0);
  end record;
  type par2_arr is array (0 to SLOTS-1) of par2_t;
  constant PAR2_0 : par2_t := (0,(others=>'0'),(others=>'0'));
  signal par2 : par2_arr := (others => PAR2_0);
  signal par2_v : std_logic_vector(SLOTS-1 downto 0) := (others => '0');

  -- engine B
  signal b_ctx : ctx_arr(0 to 4) := (others => CTX0);
  signal b_kf  : s16_arr(0 to LANES-1) := (others => (others=>'0'));
  signal b_wf, b_w1 : s19_arr(0 to LANES-1) := (others => (others=>'0'));
  signal b_mkd : s35_arr(0 to LANES-1) := (others => (others=>'0'));
  signal b_ks, b_ws, b_u : s35_arr(0 to LANES-1) := (others => (others=>'0'));
  signal b_au  : u35_arr(0 to LANES-1) := (others => (others=>'0'));
  signal b_acc : u35_arr(0 to LANES-1) := (others => (others=>'0'));



  -- engine C
  signal c_ctx : ctx_arr(0 to 5) := (others => CTX0);
  signal c_uf  : s35_arr(0 to LANES-1) := (others => (others=>'0'));
  signal c_qf, c_q1, c_q2, c_q3 : s16_arr(0 to LANES-1) := (others => (others=>'0'));
  signal c_ub, c_us : s35_arr(0 to LANES-1) := (others => (others=>'0'));
  signal c_sm  : s16_arr(0 to LANES-1) := (others => (others=>'0'));
  signal c_m3  : s42_arr(0 to LANES-1) := (others => (others=>'0'));
  signal c_acc : s42_arr(0 to LANES-1) := (others => (others=>'0'));

  -- issue bookkeeping
  signal col_cnt, colB, colC : unsigned(31 downto 0) := (others => '0');
  signal startA  : std_logic := '0';
  signal dlyB    : std_logic_vector(DC downto 0) := (others => '0');
  signal slotB, slotC : integer range 0 to SLOTS-1 := 0;
  -- the column currently being fed into engine A, held across its NB groups
  signal gin      : integer range 0 to NB-1 := 0;
  signal cur_tk0  : std_logic := '0';
  signal cur_se_j : signed(7 downto 0) := (others => '0');
  signal cur_e_v  : signed(7 downto 0) := (others => '0');
  signal cur_v_j  : signed(15 downto 0) := (others => '0');
  signal cur_slot : integer range 0 to SLOTS-1 := 0;
  signal grpB, grpC : integer range 0 to NB-1 := 0;
  signal runB, runC : std_logic := '0';

  -- The reduction trees are wide ADDS, and Vivado maps a 42-bit add to a
  -- DSP48E2 by default.  Left alone that costs 2*(LANES-1) DSPs -- 62 at
  -- LANES = 32 -- for adders, taking the unit from 4*LANES+1 to 6*LANES-1 and
  -- blowing the section 2.8 budget on hardware that is not multiplying
  -- anything.  Forced to fabric: the trees are off the throughput path (one
  -- level per cycle, LOG2L levels per column) so CARRY8 is ample there, and
  -- DSPs are the scarce resource on this die, not LUTs.
  attribute use_dsp : string;
  attribute use_dsp of redk : signal is "no";
  attribute use_dsp of redo : signal is "no";
  attribute use_dsp of reda : signal is "no";

  function msb_pos(a : unsigned) return integer is
    variable p : integer := 0;
  begin
    for i in a'low to a'high loop
      if a(i) = '1' then p := i - a'low; end if;
    end loop;
    return p;
  end function;

  function sat16(v : signed) return signed is
  begin
    if    v >  32767 then return to_signed( 32767, 16);
    elsif v < -32768 then return to_signed(-32768, 16);
    else                  return resize(v, 16); end if;
  end function;

begin

  process(clk)
    variable nacc : signed(41 downto 0);
    variable nmax : unsigned(34 downto 0);
    variable half : integer;
    variable p, qv : integer;
    variable ev_i, ske_i, ed_i, ekd_i, eu_i, sej_i : integer;
    variable base : integer;
    variable gin_v : integer range 0 to NB-1;
    variable wpk  : std_logic_vector(LANES*19-1 downto 0);
    variable upk  : std_logic_vector(LANES*35-1 downto 0);
  begin
    if rising_edge(clk) then
      assert SHAPE_OK
        report "gdn_recur_pipe: LANES and SLOTS must be powers of two and "
             & "LANES must divide DIM"
        severity failure;
      assert SLOTS >= SLOTS_MIN
        report "gdn_recur_pipe: SLOTS=" & integer'image(SLOTS) & " is below the "
             & integer'image(SLOTS_MIN) & " columns in flight at this LANES; a "
             & "slot would be reused while its column is still live"
        severity failure;
      if rst = '1' then
        a_ctx <= (others => CTX0); b_ctx <= (others => CTX0);
        c_ctx <= (others => CTX0); sc1 <= (others => SC1_0);
        sc2 <= (others => SC2_0);
        redk_c <= (others => CTX0); reda_c <= (others => CTX0);
        redo_c <= (others => CTX0);
        dlyB <= (others => '0'); col_cnt <= (others => '0');
        runB <= '0'; runC <= '0'; grpB <= 0; grpC <= 0;
        par1_v <= (others => '0'); par2_v <= (others => '0');
        o_valid <= '0'; o_last <= '0'; o_err_se <= '0'; o_res_valid <= '0';
        colB <= (others => '0'); colC <= (others => '0');
      else
        o_valid <= '0'; o_last <= '0'; o_res_valid <= '0';

        -- ============ issue ============================================
        startA <= '0';
        if s_valid = '1' and s_first = '1' then
          startA  <= '1';
          col_cnt <= col_cnt + 1;
        end if;
        dlyB <= dlyB(DC-1 downto 0) & startA;

        -- ============ engine A =========================================
        -- F: capture the incoming group and the matching k group.  The group
        -- index is derived HERE, in a variable, and used in the same cycle for
        -- both the context and the k_n select.  An earlier version read it back
        -- out of the previous cycle's context and added one, which is correct
        -- only if the previous cycle was the previous group of the same column
        -- -- it is not, at a head boundary or after a gap, and it silently
        -- indexed the wrong k.
        a_ctx(0).v <= '0';
        if s_valid = '1' then
          if s_first = '1' then
            gin_v := 0;
            cur_tk0  <= c_tk0;  cur_se_j <= c_se_j;
            cur_e_v  <= c_e_v;  cur_v_j  <= c_v_j;
            cur_slot <= to_integer(col_cnt(LOG2S-1 downto 0));
          else
            gin_v := gin + 1;
          end if;
          gin <= gin_v;

          a_ctx(0).v   <= '1';
          a_ctx(0).grp <= gin_v;
          if s_first = '1' then
            a_ctx(0).tk0  <= c_tk0;  a_ctx(0).se_j <= c_se_j;
            a_ctx(0).e_v  <= c_e_v;  a_ctx(0).v_j  <= c_v_j;
            a_ctx(0).slot <= to_integer(col_cnt(LOG2S-1 downto 0));
          else
            a_ctx(0).tk0  <= cur_tk0; a_ctx(0).se_j <= cur_se_j;
            a_ctx(0).e_v  <= cur_e_v; a_ctx(0).v_j  <= cur_v_j;
            a_ctx(0).slot <= cur_slot;
          end if;

          base := gin_v * LANES;
          for k in 0 to LANES-1 loop
            -- tk0 masks the state READ, so w18 and the sk dot are structurally
            -- zero and the state term never enters e_u's minimum.
            if (s_first = '1' and c_tk0 = '1') or (s_first = '0' and cur_tk0 = '1') then
              a_sf(k) <= (others => '0');
            else
              a_sf(k) <= signed(s_data((k+1)*16-1 downto k*16));
            end if;
            a_kf(k) <= signed(k_n((base+k+1)*16-1 downto (base+k)*16));
          end loop;
        end if;

        a_ctx(1) <= a_ctx(0);
        for k in 0 to LANES-1 loop
          a_m1(k) <= resize(a_sf(k) * signed('0' & eg), 33);
          a_k1(k) <= a_kf(k);
        end loop;

        a_ctx(2) <= a_ctx(1);
        for k in 0 to LANES-1 loop
          a_w18(k) <= resize(shift_right(a_m1(k) + to_signed(2**12, 33), 13), 19);
          a_k2(k)  <= a_k1(k);
        end loop;

        a_ctx(3) <= a_ctx(2);
        for k in 0 to LANES-1 loop
          wpk((k+1)*19-1 downto k*19) := std_logic_vector(a_w18(k));
          a_m2(k) <= resize(a_w18(k) * a_k2(k), 42);
        end loop;
        if a_ctx(2).v = '1' then
          w18_mem(a_ctx(2).slot * NB + a_ctx(2).grp) <= wpk;
        end if;

        a_ctx(4) <= a_ctx(3);
        if a_ctx(3).v = '1' then
          for k in 0 to LANES-1 loop
            if a_ctx(3).grp = 0 then nacc := a_m2(k);
            else                     nacc := a_acc(k) + a_m2(k); end if;
            a_acc(k) <= nacc;
            redk(0)(k) <= nacc;
          end loop;
        end if;
        redk_c(0) <= CTX0;
        if a_ctx(3).v = '1' and a_ctx(3).grp = NB-1 then
          redk_c(0) <= a_ctx(3);
        end if;

        -- ============ sk reduction: LOG2L pipelined 2:1 stages ==========
        for r in 0 to LOG2L-1 loop
          half := LANES / (2**(r+1));
          for k in 0 to LANES-1 loop
            if k < half then
              redk(r+1)(k) <= redk(r)(k) + redk(r)(k + half);
            end if;
          end loop;
          redk_c(r+1) <= redk_c(r);
        end loop;

        -- ============ SCAL1 ============================================
        sc1(0).c   <= redk_c(LOG2L);
        sc1(0).sum <= redk(LOG2L)(0);

        sc1(1)      <= sc1(0);
        if sc1(0).sum < 0 then sc1(1).absv <= unsigned(-sc1(0).sum);
        else                   sc1(1).absv <= unsigned( sc1(0).sum); end if;

        sc1(2) <= sc1(1);
        p := msb_pos(sc1(1).absv);
        if p - 14 > 0 then
          sc1(2).sh  <= p - 14;
          sc1(2).bi  <= shift_left(to_signed(1, 42), p - 15);
          sc1(2).ske <= resize(sc1(1).c.se_j, 16) + 17 - (p - 14);
        else
          sc1(2).sh  <= 0;
          sc1(2).bi  <= (others => '0');
          sc1(2).ske <= resize(sc1(1).c.se_j, 16) + 17;
        end if;

        sc1(3)     <= sc1(2);
        sc1(3).skm <= resize(shift_right(sc1(2).sum + sc1(2).bi, sc1(2).sh), 18);

        sc1(4) <= sc1(3);
        ev_i  := to_integer(sc1(3).c.e_v);
        ske_i := to_integer(sc1(3).ske);
        if sc1(3).c.tk0 = '1' and TK0_ED then ed_i := ev_i;
        elsif ev_i < ske_i then               ed_i := ev_i;
        else                                  ed_i := ske_i; end if;
        sc1(4).ed  <= to_signed(ed_i, 16);
        sc1(4).ekd <= to_signed(15 + ed_i, 16);

        sc1(5) <= sc1(4);
        -- Clamped at BOTH ends.  Upper: 2.1.4's rule, and the C reference must
        -- clamp because 1LL << 64 is undefined behaviour there.  Lower: every
        -- stage here evaluates on every cycle, including on the invalid context
        -- between columns, where the difference can be negative and a negative
        -- shift_right is a bound-check failure rather than a wrong number.
        p  := to_integer(sc1(4).c.e_v - sc1(4).ed);
        if p  < 0 then p  := 0; elsif p  > 63 then p  := 63; end if;
        qv := to_integer(sc1(4).ske - sc1(4).ed);
        if qv < 0 then qv := 0; elsif qv > 63 then qv := 63; end if;
        sc1(5).diff <= resize(shift_right(resize(sc1(4).c.v_j, 18), p), 18)
                     - resize(shift_right(sc1(4).skm, qv), 18);

        sc1(6) <= sc1(5);
        assert not (sc1(5).c.v = '1'
                    and (sc1(5).diff >= 131072 or sc1(5).diff <= -131073))
          report "gdn_recur_pipe: diff outside s18 -- v[j] exceeded int16?"
          severity failure;
        sc1(6).dmul <= resize(sc1(5).diff * signed('0' & beta), 35);

        sc1(7) <= sc1(6);
        if sc1(6).dmul < 0 then sc1(7).dabs <= unsigned(-sc1(6).dmul);
        else                    sc1(7).dabs <= unsigned( sc1(6).dmul); end if;

        sc1(8) <= sc1(7);
        -- Its own stage, like site 7's: an msb scan in series with the
        -- round-shift that uses it is the pattern that costs the clock.
        if D_NORM then
          p := msb_pos(sc1(7).dabs);
          if p - 14 > 0 then
            sc1(8).shd   <= p - 14;
            sc1(8).dbias <= shift_left(to_signed(1, 35), p - 15);
          else
            sc1(8).shd   <= 0;
            sc1(8).dbias <= (others => '0');
          end if;
        else
          sc1(8).shd   <= 16;
          sc1(8).dbias <= to_signed(2**15, 35);
        end if;

        sc1(9) <= sc1(8);
        if sc1(8).c.v = '1' then
          sej_i := to_integer(sc1(8).c.se_j) + 2;
          -- e_kd = 15 + e_dm, and e_dm = e_d + 16 - shd.  With the pinned
          -- shd = 16 this is 15 + e_d, exactly the pinned form.
          ekd_i := 15 + to_integer(sc1(8).ed) + 16 - sc1(8).shd;
          if sc1(8).c.tk0 = '1' then eu_i := ekd_i;
          elsif sej_i < ekd_i then   eu_i := sej_i;
          else                       eu_i := ekd_i; end if;
          p  := sej_i - eu_i; if p  < 0 then p  := 0; elsif p  > 63 then p  := 63; end if;
          qv := ekd_i - eu_i; if qv < 0 then qv := 0; elsif qv > 63 then qv := 63; end if;
          par1(sc1(8).c.slot).d_m <= resize(shift_right(sc1(8).dmul + sc1(8).dbias,
                                                        sc1(8).shd), 18);
          par1(sc1(8).c.slot).e_u <= to_signed(eu_i, 16);
          par1(sc1(8).c.slot).su  <= p;
          par1(sc1(8).c.slot).sk2 <= qv;
          par1(sc1(8).c.slot).tk0 <= sc1(8).c.tk0;
          par1_v(sc1(8).c.slot)   <= '1';
        end if;

        -- ============ engine B =========================================
        -- Started by a DELAYED copy of the issue pulse.  The delay only has to
        -- be large enough: the parameters come from par1 by SLOT, and par1_v
        -- turns "not large enough" into an assertion instead of a column
        -- silently reading the previous one's d_m.
        if dlyB(DB-1) = '1' then
          runB <= '1'; grpB <= 0;
          slotB <= to_integer(colB(LOG2S-1 downto 0));
          colB  <= colB + 1;
          assert par1_v(to_integer(colB(LOG2S-1 downto 0))) = '1'
            report "gdn_recur_pipe: engine B started before SCAL1 finished -- "
                 & "DB is too small for this LANES/SLOTS"
            severity failure;
          -- CLEARED on consume.  Without this the bit stays set from whichever
          -- column used the slot last, and the assertion above passes while the
          -- engine reads a stale d_m -- a guard that cannot fail is not a guard.
          par1_v(to_integer(colB(LOG2S-1 downto 0))) <= '0';
        elsif runB = '1' then
          if grpB = NB-1 then runB <= '0'; else grpB <= grpB + 1; end if;
        end if;

        -- Driven purely off runB/grpB, never also off the start pulse: on the
        -- pulse cycle grpB still holds the PREVIOUS column's last index, so
        -- including it emits NB+1 groups with the first one mis-indexed.
        b_ctx(0).v <= '0';
        if runB = '1' then
          b_ctx(0).v    <= '1';
          b_ctx(0).slot <= slotB;
          b_ctx(0).grp  <= grpB;
          b_ctx(0).tk0  <= par1(slotB).tk0;
          b_ctx(0).e_u  <= par1(slotB).e_u;
          b_ctx(0).d_m  <= par1(slotB).d_m;
          b_ctx(0).su   <= par1(slotB).su;
          b_ctx(0).sk2  <= par1(slotB).sk2;
          base := grpB * LANES;
          for k in 0 to LANES-1 loop
            b_kf(k) <= signed(k_n((base+k+1)*16-1 downto (base+k)*16));
            b_wf(k) <= signed(w18_mem(slotB * NB + grpB)((k+1)*19-1 downto k*19));
          end loop;
        end if;

        b_ctx(1) <= b_ctx(0);
        for k in 0 to LANES-1 loop
          b_mkd(k) <= resize(b_kf(k) * b_ctx(0).d_m, 35);
          b_w1(k)  <= b_wf(k);
        end loop;

        b_ctx(2) <= b_ctx(1);
        for k in 0 to LANES-1 loop
          b_ks(k) <= shift_right(b_mkd(k), b_ctx(1).sk2);
          -- tk0: the state term is DROPPED, not shifted.  With e_u = e_kd the
          -- shift su would be negative, and a negative shift here is a left
          -- shift of a value that must not exist at all.
          if b_ctx(1).tk0 = '1' then b_ws(k) <= (others => '0');
          else b_ws(k) <= shift_right(resize(b_w1(k), 35), b_ctx(1).su); end if;
        end loop;

        b_ctx(3) <= b_ctx(2);
        for k in 0 to LANES-1 loop
          b_u(k) <= b_ks(k) + b_ws(k);
          upk((k+1)*35-1 downto k*35) := std_logic_vector(b_ks(k) + b_ws(k));
        end loop;
        if b_ctx(2).v = '1' then
          u_mem(b_ctx(2).slot * NB + b_ctx(2).grp) <= upk;
        end if;

        b_ctx(4) <= b_ctx(3);
        for k in 0 to LANES-1 loop
          if b_u(k) < 0 then b_au(k) <= unsigned(-b_u(k));
          else               b_au(k) <= unsigned( b_u(k)); end if;
        end loop;

        if b_ctx(4).v = '1' then
          for k in 0 to LANES-1 loop
            if b_ctx(4).grp = 0 then nmax := b_au(k);
            elsif b_au(k) > b_acc(k) then nmax := b_au(k);
            else nmax := b_acc(k); end if;
            b_acc(k)   <= nmax;
            reda(0)(k) <= nmax;
          end loop;
        end if;
        reda_c(0) <= CTX0;
        if b_ctx(4).v = '1' and b_ctx(4).grp = NB-1 then
          reda_c(0) <= b_ctx(4);
        end if;

        -- ============ amax reduction ===================================
        for r in 0 to LOG2L-1 loop
          half := LANES / (2**(r+1));
          for k in 0 to LANES-1 loop
            if k < half then
              if reda(r)(k + half) > reda(r)(k) then
                reda(r+1)(k) <= reda(r)(k + half);
              else
                reda(r+1)(k) <= reda(r)(k);
              end if;
            end if;
          end loop;
          reda_c(r+1) <= reda_c(r);
        end loop;

        -- ============ SCAL2 ============================================
        sc2(0).c    <= reda_c(LOG2L);
        sc2(0).amax <= reda(LOG2L)(0);

        sc2(1) <= sc2(0);
        p := msb_pos(sc2(0).amax);
        if sc2(0).c.v = '1' then
          if p - 14 > 0 then
            par2(sc2(0).c.slot).shq  <= p - 14;
            par2(sc2(0).c.slot).bias <= shift_left(to_signed(1, 35), p - 15);
          else
            -- bfp_pack semantics: no rounding bias at all when sh = 0
            par2(sc2(0).c.slot).shq  <= 0;
            par2(sc2(0).c.slot).bias <= (others => '0');
          end if;
          par2(sc2(0).c.slot).e_u <= sc2(0).c.e_u;
          par2_v(sc2(0).c.slot)   <= '1';
        end if;

        -- ============ engine C =========================================
        if dlyB(DC-1) = '1' then
          runC <= '1'; grpC <= 0;
          slotC <= to_integer(colC(LOG2S-1 downto 0));
          colC  <= colC + 1;
          assert par2_v(to_integer(colC(LOG2S-1 downto 0))) = '1'
            report "gdn_recur_pipe: engine C started before SCAL2 finished -- "
                 & "DC is too small for this LANES/SLOTS"
            severity failure;
          par2_v(to_integer(colC(LOG2S-1 downto 0))) <= '0';
        elsif runC = '1' then
          if grpC = NB-1 then runC <= '0'; else grpC <= grpC + 1; end if;
        end if;

        c_ctx(0).v <= '0';
        if runC = '1' then
          c_ctx(0).v    <= '1';
          c_ctx(0).slot <= slotC;
          c_ctx(0).grp  <= grpC;
          c_ctx(0).shq  <= par2(slotC).shq;
          c_ctx(0).bias <= par2(slotC).bias;
          c_ctx(0).e_u  <= par2(slotC).e_u;
          base := grpC * LANES;
          for k in 0 to LANES-1 loop
            c_qf(k) <= signed(q_s((base+k+1)*16-1 downto (base+k)*16));
            c_uf(k) <= signed(u_mem(slotC * NB + grpC)((k+1)*35-1 downto k*35));
          end loop;
        end if;

        c_ctx(1) <= c_ctx(0);
        for k in 0 to LANES-1 loop
          c_ub(k) <= c_uf(k) + c_ctx(0).bias;
          c_q1(k) <= c_qf(k);
        end loop;

        c_ctx(2) <= c_ctx(1);
        for k in 0 to LANES-1 loop
          c_us(k) <= shift_right(c_ub(k), c_ctx(1).shq);
          c_q2(k) <= c_q1(k);
        end loop;

        c_ctx(3) <= c_ctx(2);
        for k in 0 to LANES-1 loop
          c_sm(k) <= sat16(c_us(k));
          c_q3(k) <= c_q2(k);
        end loop;
        -- the requantized column streams out here, in group order
        o_valid <= c_ctx(2).v;
        if c_ctx(2).v = '1' then
          for k in 0 to LANES-1 loop
            o_data((k+1)*16-1 downto k*16) <= std_logic_vector(sat16(c_us(k)));
          end loop;
          if c_ctx(2).grp = NB-1 then o_last <= '1'; end if;
        end if;

        c_ctx(4) <= c_ctx(3);
        for k in 0 to LANES-1 loop
          -- stage 5 uses the REQUANTIZED mantissa, so the emitted output is
          -- bit-consistent with the stored state, as 2.1.4 requires.
          c_m3(k) <= resize(c_sm(k) * c_q3(k), 42);
        end loop;

        c_ctx(5) <= c_ctx(4);
        if c_ctx(4).v = '1' then
          for k in 0 to LANES-1 loop
            if c_ctx(4).grp = 0 then nacc := c_m3(k);
            else                     nacc := c_acc(k) + c_m3(k); end if;
            c_acc(k)   <= nacc;
            redo(0)(k) <= nacc;
          end loop;
        end if;
        redo_c(0) <= CTX0;
        if c_ctx(4).v = '1' and c_ctx(4).grp = NB-1 then
          redo_c(0) <= c_ctx(4);
        end if;

        -- ============ output dot reduction and result ==================
        for r in 0 to LOG2L-1 loop
          half := LANES / (2**(r+1));
          for k in 0 to LANES-1 loop
            if k < half then
              redo(r+1)(k) <= redo(r)(k) + redo(r)(k + half);
            end if;
          end loop;
          redo_c(r+1) <= redo_c(r);
        end loop;

        o_res_valid <= redo_c(LOG2L).v;
        if redo_c(LOG2L).v = '1' then
          o_acc    <= resize(redo(LOG2L)(0), 40);
          o_se_new <= resize(redo_c(LOG2L).e_u - redo_c(LOG2L).shq, 8);
          o_e_o    <= resize(redo_c(LOG2L).e_u - redo_c(LOG2L).shq + 18, 8);
          -- 2.1.6: the column exponent is int8; out of range is an error to be
          -- reported, never silently wrapped.
          -- 2.1.6 range-checks the column exponent.  e_o = se_new + 18 is a
          -- SEPARATE int8 output and was not checked: se_new in [110,127] is
          -- in range while e_o wraps silently.  Unreachable at the exponent
          -- ranges these vectors carry, which is exactly why it needs a check
          -- rather than a test.
          -- PER COLUMN, not sticky.  A latched flag says only that some
          -- column somewhere overflowed, which cannot be checked against a
          -- per-column reference and hides how many did.
          if (redo_c(LOG2L).e_u - redo_c(LOG2L).shq) > 127
             or (redo_c(LOG2L).e_u - redo_c(LOG2L).shq) < -128
             or (redo_c(LOG2L).e_u - redo_c(LOG2L).shq + 18) > 127
             or (redo_c(LOG2L).e_u - redo_c(LOG2L).shq + 18) < -128 then
            o_err_se <= '1';
          else
            o_err_se <= '0';
          end if;
        end if;

      end if;
    end if;
  end process;

end architecture;
