-- rtl/mv_tile.vhd -- subsystem A at 450 MHz: one tile per weight port.
--
-- Spec: docs/superpowers/specs/2026-11-12-a450-per-port-tiles-design.md 1.2.
--
-- A tile owns ONE HBM weight port and the TWO rows that port carries (lane split 6.5a:
-- bits [BLK*4-1:0] of a beat are row 0's BLK nibbles, bits [2*BLK*4-1:BLK*4] row 1's).
-- It computes exactly what rtl/matvec_core.vhd computes for those two rows, with no
-- signal shared with any other tile: a stall stops only this tile's own FIFO pops.
--
-- FLITS.  Everything else a tile needs arrives in order through one flit FIFO fed by the
-- distribution tree (rtl/mv_xbcast.vhd):
--   kind 10  PARAM  x[5:0] out_shift, x[7:6] out_mode; also pulses the weight port's start
--   kind 01  CB     x[3:0] codebook address, x[11:4] the int8 entry (16 of them per job)
--   kind 00  ITEM   x = one block of BLK activations (pad columns already zero),
--                   s[15:0] row 0's scale, s[31:16] row 1's, first/last of the row-tile
-- An ITEM pops together with one weight beat.  PARAM and CB pop alone.  Because the three
-- kinds share one FIFO, a codebook write can never overtake the items it precedes.
--
-- ROOM.  `room` is '1' while the flit FIFO's level is below XD - SLACK, registered.  The
-- distributor sends only while every tile's room is '1' (a registered AND tree), so SLACK
-- must cover every flit in flight between a tile's room falling and the distributor seeing
-- it.  rtl/mv_afast.vhd derives SLACK from the two tree depths; an overrun is a failure
-- assertion here, never a silent drop.
--
-- PIPELINE (e0 = the cycle the popped flit sits in the p0 registers):
--   lane j's x and its two nibbles are delayed j cycles (SRL), then
--   e0+j+1  codebook lookup (per-lane LUTRAM) and x, registered      DSP A/B regs
--   e0+j+2  product cb*x, s24                                        DSP M reg
--   e0+j+3  c(j) = c(j-1) + product, 48 bits                         DSP P reg, PCIN cascade
--   e0+BLK+2  partial = c(BLK-1) mod 2^28: the old adder tree's s28 wrap, bit for bit
--   S   sprod = partial * ('0' & scale)          s45
--   C   contrib = floor_shr(sprod, 15)           s29
--   ACC acc = first ? contrib : acc + contrib    s48
--   E2..E6 (on last) round_shift by out_shift, sat32, the sat flag, the out-mode select
-- Nothing in the pipeline has a shared enable: data registers load every cycle and a valid
-- bit travels beside them.
--
-- RESULT.  One 97-bit word per row-tile: [47:0] row 0, [95:48] row 1, [96] sat.  The value
-- is the raw accumulator in mode 10, else sat32(round_shift(acc, out_shift)) sign-extended
-- to 48.  sat is set for modes 00/01 when sat32 clamped, on BOTH rows whatever the row
-- count (matvec_core's re2 loop does the same).  The BFP scan and the row mask are the back
-- end's (rtl/mv_back.vhd), because they need every row of the matrix.
--
-- RESULT CREDIT.  A last ITEM pops only while `outst` (row-tiles issued and not yet taken
-- by the result chain) is below RD, so the RD-deep result FIFO can never overflow.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mv4i_arith_pkg.all;

entity mv_tile is
  generic(
    BLK    : positive := 32;
    AXI_DW : positive := 256;   -- must be 2*BLK*4
    ADDR_W : positive := 40;
    DEPTH  : positive := 512;   -- weight FIFO, beats
    MAXB   : positive := 16;    -- HBM is AXI3: 16-beat bursts
    MAXOUT : positive := 16;
    XD     : positive := 32;    -- flit FIFO depth
    SLACK  : positive := 12;    -- room falls at level XD - SLACK
    RD     : positive := 4      -- result FIFO depth
  );
  port(
    clk, rst : in  std_logic;
    w_base   : in  std_logic_vector(ADDR_W-1 downto 0);
    w_beats  : in  integer;
    arvalid  : out std_logic;
    arready  : in  std_logic;
    araddr   : out std_logic_vector(ADDR_W-1 downto 0);
    arlen    : out std_logic_vector(7 downto 0);
    arsize   : out std_logic_vector(2 downto 0);
    arburst  : out std_logic_vector(1 downto 0);
    rvalid   : in  std_logic;
    rready   : out std_logic;
    rdata    : in  std_logic_vector(AXI_DW-1 downto 0);
    rlast    : in  std_logic;
    f_v      : in  std_logic;
    f_kind   : in  std_logic_vector(1 downto 0);
    f_x      : in  std_logic_vector(BLK*16-1 downto 0);
    f_s      : in  std_logic_vector(31 downto 0);
    f_first  : in  std_logic;
    f_last   : in  std_logic;
    room     : out std_logic;
    r_v      : out std_logic;
    r_d      : out std_logic_vector(96 downto 0);
    r_rdy    : in  std_logic
  );
end entity;

architecture rtl of mv_tile is
  constant XW   : positive := BLK*16;
  constant FW   : positive := XW + 36;
  constant B_F  : natural  := XW + 32;
  constant B_L  : natural  := XW + 33;
  constant B_K  : natural  := XW + 34;
  constant LAT  : positive := BLK + 2;
  constant NTAP : natural  := BLK*(BLK-1)/2;
  -- AXI_DW must be exactly two rows of BLK nibbles; an out-of-range natural stops both
  -- GHDL and Vivado at elaboration (Vivado ignores a failing assert in synthesis).
  constant CHK_DW : natural := 1 - abs(AXI_DW - 2*BLK*4);

  function tbase(j : natural) return natural is
  begin
    return j*(j-1)/2;
  end function;

  -- flit FIFO
  signal fq_d  : std_logic_vector(FW-1 downto 0);
  signal fq_in : std_logic_vector(FW-1 downto 0);
  signal fq_v, fq_ir, pop, is_item : std_logic;
  signal fq_lvl : integer;
  signal room_r : std_logic := '0';
  -- weight port
  signal wq_v, wq_r : std_logic;
  signal wq_d : std_logic_vector(AXI_DW-1 downto 0);
  signal port_start : std_logic := '0';
  -- p0
  signal p0_v : std_logic := '0';
  signal p0_x : std_logic_vector(XW-1 downto 0) := (others => '0');
  signal p0_w : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
  signal p0_s : std_logic_vector(31 downto 0) := (others => '0');
  signal p0_f, p0_l : std_logic := '0';
  -- codebook: one LUTRAM per lane, written in lockstep from one command per row
  type cb_t   is array(0 to 15) of std_logic_vector(7 downto 0);
  type cbl_t  is array(0 to 2*BLK-1) of cb_t;
  signal cbl : cbl_t := (others => (others => (others => '0')));
  attribute ram_style : string;
  attribute ram_style of cbl : signal is "distributed";
  type cmd_a_t is array(0 to 1) of std_logic_vector(3 downto 0);
  type cmd_d_t is array(0 to 1) of std_logic_vector(7 downto 0);
  signal cbw_v : std_logic_vector(1 downto 0) := (others => '0');
  signal cbw_a : cmd_a_t := (others => (others => '0'));
  signal cbw_d : cmd_d_t := (others => (others => '0'));
  attribute dont_touch : string;
  attribute dont_touch of cbw_v : signal is "true";
  attribute dont_touch of cbw_a : signal is "true";
  attribute dont_touch of cbw_d : signal is "true";
  -- params
  signal os_r   : natural range 0 to 63 := 0;
  signal hi_r   : natural range 0 to 7 := 0;
  signal lo_r   : natural range 0 to 7 := 0;
  signal mode_r : std_logic_vector(1 downto 0) := "00";
  signal bias_r : signed(48 downto 0) := (others => '0');
  -- skew: lane j's {row1 nibble, row0 nibble, x} delayed j cycles
  type tap_arr is array(0 to NTAP) of std_logic_vector(23 downto 0);
  signal tap : tap_arr := (others => (others => '0'));
  -- DSP columns
  type s8_arr  is array(0 to 2*BLK-1) of signed(7 downto 0);
  type s16_arr is array(0 to BLK-1) of signed(15 downto 0);
  type s24_arr is array(0 to 2*BLK-1) of signed(23 downto 0);
  type s48_arr is array(0 to 2*BLK-1) of signed(47 downto 0);
  signal a_cb : s8_arr  := (others => (others => '0'));
  signal a_x  : s16_arr := (others => (others => '0'));
  signal m    : s24_arr := (others => (others => '0'));
  signal c    : s48_arr := (others => (others => '0'));
  -- tag delay: valid (with reset) and first/last/scale (no reset, SRL)
  type td_t is array(0 to LAT-1) of std_logic_vector(33 downto 0);
  signal vd : std_logic_vector(LAT-1 downto 0) := (others => '0');
  signal td : td_t := (others => (others => '0'));
  -- per-row stages
  type s45_2 is array(0 to 1) of signed(44 downto 0);
  type s29_2 is array(0 to 1) of signed(28 downto 0);
  type s48_2 is array(0 to 1) of signed(47 downto 0);
  type s49_2 is array(0 to 1) of signed(48 downto 0);
  type s32_2 is array(0 to 1) of signed(31 downto 0);
  signal s_v, c_v, e1_v, e2_v, e3_v, e4_v, e5_v, e6_v : std_logic := '0';
  signal s_f, s_l, c_f, c_l : std_logic := '0';
  signal s_sp : s45_2 := (others => (others => '0'));
  signal c_ct : s29_2 := (others => (others => '0'));
  signal acc, e1_acc, e2_acc, e3_acc, e4_acc, e5_acc : s48_2 := (others => (others => '0'));
  signal e2_w, e3_w : s49_2 := (others => (others => '0'));
  signal e4_rs, e5_rs : s48_2 := (others => (others => '0'));
  signal e5_a32 : s32_2 := (others => (others => '0'));
  signal e6_d : std_logic_vector(96 downto 0) := (others => '0');
  -- result FIFO and its credit
  signal rq_ir : std_logic;
  signal outst : integer range 0 to RD := 0;
begin
  fq_in(XW-1 downto 0)  <= f_x;
  fq_in(XW+31 downto XW) <= f_s;
  fq_in(B_F) <= f_first;
  fq_in(B_L) <= f_last;
  fq_in(B_K+1 downto B_K) <= f_kind;

  flitq : entity work.mv_lfifo
    generic map(W => FW, DEPTH => XD)
    port map(clk => clk, rst => rst,
             i_valid => f_v, i_data => fq_in, i_ready => fq_ir,
             q_valid => fq_v, q_data => fq_d, q_ready => pop, level => fq_lvl);

  wport : entity work.axi_rd_port
    generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH, MAXB => MAXB,
                MAXOUT => MAXOUT, DUAL_CLK => false, FAST_POP => true)
    port map(clk => clk, rst => rst, start => port_start,
             base => w_base, n_beats => w_beats,
             arvalid => arvalid, arready => arready, araddr => araddr, arlen => arlen,
             arsize => arsize, arburst => arburst,
             rvalid => rvalid, rready => rready, rdata => rdata, rlast => rlast,
             q_valid => wq_v, q_data => wq_d, q_ready => wq_r);

  is_item <= '1' when fq_d(B_K+1 downto B_K) = "00" else '0';
  pop  <= '1' when fq_v = '1' and (is_item = '0' or
                   (wq_v = '1' and (fq_d(B_L) = '0' or outst < RD))) else '0';
  wq_r <= pop and is_item;
  room <= room_r;

  overrun : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '0' then
        assert not (f_v = '1' and fq_ir = '0')
          report "mv_tile: a flit arrived with the flit FIFO full (room/credit overrun)"
          severity failure;
      end if;
    end if;
  end process;

  -- p0, the codebook command, the params, room
  front : process(clk)
    variable osv : natural range 0 to 63;
  begin
    if rising_edge(clk) then
      p0_x <= fq_d(XW-1 downto 0);
      p0_s <= fq_d(XW+31 downto XW);
      p0_f <= fq_d(B_F);
      p0_l <= fq_d(B_L);
      p0_w <= wq_d;
      for r in 0 to 1 loop
        cbw_a(r) <= fq_d(3 downto 0);
        cbw_d(r) <= fq_d(11 downto 4);
      end loop;
      if fq_lvl < XD - SLACK then room_r <= '1'; else room_r <= '0'; end if;
      if pop = '1' and fq_d(B_K+1 downto B_K) = "10" then
        osv    := to_integer(unsigned(fq_d(5 downto 0)));
        os_r   <= osv;
        hi_r   <= osv / 8;
        lo_r   <= osv mod 8;
        mode_r <= fq_d(7 downto 6);
        if osv = 0 then
          bias_r <= (others => '0');
        else
          bias_r <= shift_left(to_signed(1, 49), osv - 1);
        end if;
      end if;
      if rst = '1' then
        p0_v <= '0'; cbw_v <= "00"; port_start <= '0'; room_r <= '0';
      else
        p0_v <= pop and is_item;
        if pop = '1' and fq_d(B_K+1 downto B_K) = "01" then cbw_v <= "11";
        else cbw_v <= "00"; end if;
        if pop = '1' and fq_d(B_K+1 downto B_K) = "10" then port_start <= '1';
        else port_start <= '0'; end if;
      end if;
    end if;
  end process;

  -- the codebook write, every lane of a row from that row's command copy
  cbwr : process(clk)
  begin
    if rising_edge(clk) then
      for r in 0 to 1 loop
        if cbw_v(r) = '1' then
          for j in 0 to BLK-1 loop
            cbl(r*BLK + j)(to_integer(unsigned(cbw_a(r)))) <= cbw_d(r);
          end loop;
        end if;
      end loop;
    end if;
  end process;

  -- skew, lookup, multiply, cascade
  mac : process(clk)
    variable ln : std_logic_vector(23 downto 0);
  begin
    if rising_edge(clk) then
      for j in 0 to BLK-1 loop
        if j > 0 then
          tap(tbase(j)) <= p0_w(BLK*4 + j*4 + 3 downto BLK*4 + j*4)
                         & p0_w(j*4 + 3 downto j*4) & p0_x(j*16 + 15 downto j*16);
          for d in 1 to j-1 loop
            tap(tbase(j) + d) <= tap(tbase(j) + d - 1);
          end loop;
        end if;
      end loop;
      for j in 0 to BLK-1 loop
        if j = 0 then
          ln := p0_w(BLK*4 + 3 downto BLK*4) & p0_w(3 downto 0) & p0_x(15 downto 0);
        else
          ln := tap(tbase(j) + j - 1);
        end if;
        a_x(j) <= signed(ln(15 downto 0));
        a_cb(j)       <= signed(cbl(j)(to_integer(unsigned(ln(19 downto 16)))));
        a_cb(BLK + j) <= signed(cbl(BLK + j)(to_integer(unsigned(ln(23 downto 20)))));
      end loop;
      for r in 0 to 1 loop
        for j in 0 to BLK-1 loop
          m(r*BLK + j) <= a_cb(r*BLK + j) * a_x(j);
          if j = 0 then
            c(r*BLK) <= resize(m(r*BLK), 48);
          else
            c(r*BLK + j) <= c(r*BLK + j - 1) + resize(m(r*BLK + j), 48);
          end if;
        end loop;
      end loop;
    end if;
  end process;

  -- tags, scale, accumulate, row end
  tail : process(clk)
    variable an : signed(47 downto 0);
    variable sc : std_logic_vector(31 downto 0);
    variable vv : signed(47 downto 0);
    variable sat : std_logic;
    variable s17 : std_logic_vector(16 downto 0);
  begin
    if rising_edge(clk) then
      td(0) <= p0_l & p0_f & p0_s;
      for i in 1 to LAT-1 loop
        td(i) <= td(i-1);
      end loop;
      sc := td(LAT-1)(31 downto 0);
      -- S
      s_f <= td(LAT-1)(32);
      s_l <= td(LAT-1)(33);
      for r in 0 to 1 loop
        -- through a variable: GHDL 1.0.0 crashes on a concatenation directly in signed()
        s17 := '0' & sc(r*16 + 15 downto r*16);
        s_sp(r) <= signed(c(r*BLK + BLK - 1)(27 downto 0)) * signed(s17);
      end loop;
      -- C
      c_f <= s_f; c_l <= s_l;
      for r in 0 to 1 loop
        c_ct(r) <= resize(floor_shr(s_sp(r), 15), 29);
      end loop;
      -- ACC
      for r in 0 to 1 loop
        if c_f = '1' then an := resize(c_ct(r), 48);
        else              an := acc(r) + resize(c_ct(r), 48); end if;
        if c_v = '1' then acc(r) <= an; end if;
        e1_acc(r) <= an;
      end loop;
      -- E2: bias.  E3: shift by 8*os(5:3).  E4: by os(2:0), back to 48.  E5: sat32.
      for r in 0 to 1 loop
        e2_w(r)   <= resize(e1_acc(r), 49) + bias_r;
        e2_acc(r) <= e1_acc(r);
        e3_w(r)   <= shift_right(e2_w(r), 8*hi_r);
        e3_acc(r) <= e2_acc(r);
        e4_rs(r)  <= resize(shift_right(e3_w(r), lo_r), 48);
        e4_acc(r) <= e3_acc(r);
        e5_a32(r) <= sat32(e4_rs(r));
        e5_rs(r)  <= e4_rs(r);
        e5_acc(r) <= e4_acc(r);
      end loop;
      -- E6: the out-mode select and the sat flag
      sat := '0';
      for r in 0 to 1 loop
        if mode_r = "10" then
          vv := e5_acc(r);
        else
          vv := resize(e5_a32(r), 48);
          if e5_rs(r) /= resize(e5_a32(r), 48) then sat := '1'; end if;
        end if;
        e6_d(r*48 + 47 downto r*48) <= std_logic_vector(vv);
      end loop;
      e6_d(96) <= sat;

      if rst = '1' then
        vd <= (others => '0');
        s_v <= '0'; c_v <= '0'; e1_v <= '0'; e2_v <= '0'; e3_v <= '0';
        e4_v <= '0'; e5_v <= '0'; e6_v <= '0';
      else
        vd  <= vd(LAT-2 downto 0) & p0_v;
        s_v <= vd(LAT-1);
        c_v <= s_v;
        e1_v <= c_v and c_l;
        e2_v <= e1_v; e3_v <= e2_v; e4_v <= e3_v; e5_v <= e4_v; e6_v <= e5_v;
      end if;
    end if;
  end process;

  resq : entity work.mv_lfifo
    generic map(W => 97, DEPTH => RD)
    port map(clk => clk, rst => rst,
             i_valid => e6_v, i_data => e6_d, i_ready => rq_ir,
             q_valid => r_v, q_data => r_d, q_ready => r_rdy, level => open);

  credit : process(clk)
    variable o : integer range -1 to RD + 1;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        outst <= 0;
      else
        o := outst;
        if pop = '1' and is_item = '1' and fq_d(B_L) = '1' then o := o + 1; end if;
        if r_v = '1' and r_rdy = '1' then o := o - 1; end if;
        outst <= o;
      end if;
      if rst = '0' then
        assert not (e6_v = '1' and rq_ir = '0')
          report "mv_tile: a row-tile result reached a full result FIFO (outst credit broken)"
          severity failure;
      end if;
    end if;
  end process;
end architecture;
