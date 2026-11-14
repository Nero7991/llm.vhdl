-- rtl/a450_stub_seq.vhd -- the stub sequencer of the a450 A+HBM timing design (plan
-- Task 7, spec 3.2 gate 2).  It keeps every path of rtl/mv4i_tiled.vhd alive without a
-- host: it loads 64 activations and a codebook from an LFSR, starts a legal job (random
-- shape, out_shift and mode, per-port bases and beat counts consistent with the shape, all
-- registers loaded at T_GO), waits for done, and folds every y beat, y_exp, err and sat
-- into `obs`, which drives an LED, so synthesis can trim nothing.  It computes nothing
-- anyone checks; it is timing harness.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity a450_stub_seq is
  generic(
    NPORTS_W : positive := 24;
    NPORTS_S : positive := 3;
    ADDR_W   : positive := 40;
    ROWS_IF  : positive := 48
  );
  port(
    clk, rst  : in  std_logic;
    start     : out std_logic;
    n_rows    : out std_logic_vector(31 downto 0);
    n_cols    : out std_logic_vector(31 downto 0);
    out_shift : out std_logic_vector(31 downto 0);
    w_exp     : out std_logic_vector(31 downto 0);
    x_exp     : out std_logic_vector(31 downto 0);
    out_mode  : out std_logic_vector(1 downto 0);
    w_base    : out std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats   : out std_logic_vector(31 downto 0);
    s_base    : out std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats   : out std_logic_vector(31 downto 0);
    cb_we     : out std_logic;
    cb_addr   : out std_logic_vector(3 downto 0);
    cb_data   : out std_logic_vector(7 downto 0);
    x_we      : out std_logic;
    x_waddr   : out std_logic_vector(15 downto 0);
    x_wdata   : out std_logic_vector(15 downto 0);
    y_we      : in  std_logic;
    y_data    : in  std_logic_vector(ROWS_IF*64-1 downto 0);
    y_exp     : in  std_logic_vector(31 downto 0);
    done      : in  std_logic;
    err       : in  std_logic;
    sat_event : in  std_logic;
    jobs      : out std_logic_vector(31 downto 0);
    obs       : out std_logic
  );
end entity;

architecture rtl of a450_stub_seq is
  type st_t is (T_X, T_CB, T_SET, T_GO, T_WAIT);
  signal st  : st_t := T_X;
  signal lf  : unsigned(31 downto 0) := x"ACE11234";
  signal cnt : natural range 0 to 63 := 0;
  signal tl, nbk : natural range 1 to 8 := 1;
  signal acc : std_logic_vector(63 downto 0) := (others => '0');
  signal fold : std_logic_vector(7 downto 0) := (others => '0');
  signal o : std_logic := '0';
  signal nj : unsigned(31 downto 0) := (others => '0');
  -- the per-job HBM bases, REGISTERS loaded at T_GO (Task 7 review): on the card they are
  -- descriptor-loaded registers, and constant bases would let synthesis fold every read
  -- port's address adder.  Port k (weight ports 0..NPORTS_W-1, then the scale ports) gets
  -- region (r * NPORTS + k) of 4 MiB, r = lf(26:24) the same for every port of a job, so
  -- the regions stay distinct; inside it a 4 KiB-aligned offset lf(21:12).  A job reads at
  -- most 64 beats x 32 B = 2 KiB per port, so it never leaves its region.
  constant NPORTS : positive := NPORTS_W + NPORTS_S;
  signal wb_r : std_logic_vector(NPORTS_W*ADDR_W-1 downto 0) := (others => '0');
  signal sb_r : std_logic_vector(NPORTS_S*ADDR_W-1 downto 0) := (others => '0');
  function port_base(r : natural; k : natural; off : unsigned(9 downto 0)) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(r * NPORTS + k, ADDR_W - 22)) & std_logic_vector(off)
           & (11 downto 0 => '0');
  end function;
begin
  jobs <= std_logic_vector(nj);
  obs  <= o;
  w_base <= wb_r;
  s_base <= sb_r;

  seq : process(clk)
    variable v : std_logic_vector(63 downto 0);
  begin
    if rising_edge(clk) then
      lf <= lf(30 downto 0) & (lf(31) xor lf(21) xor lf(1) xor lf(0));
      start <= '0'; cb_we <= '0'; x_we <= '0';
      -- observe everything the DUT emits
      if y_we = '1' then
        v := acc;
        for r in 0 to ROWS_IF-1 loop v := v xor y_data(r*64+63 downto r*64); end loop;
        acc <= v xor (x"00000000" & y_exp);
      end if;
      for i in 0 to 7 loop
        fold(i) <= acc(i*8) xor acc(i*8+1) xor acc(i*8+2) xor acc(i*8+3)
                 xor acc(i*8+4) xor acc(i*8+5) xor acc(i*8+6) xor acc(i*8+7);
      end loop;
      o <= fold(0) xor fold(1) xor fold(2) xor fold(3) xor fold(4) xor fold(5)
         xor fold(6) xor fold(7) xor err xor sat_event;
      case st is
        when T_X =>
          x_we <= '1';
          x_waddr <= std_logic_vector(to_unsigned(cnt, 16));
          x_wdata <= std_logic_vector(lf(15 downto 0));
          if cnt = 63 then cnt <= 0; st <= T_CB; else cnt <= cnt + 1; end if;
        when T_CB =>
          cb_we <= '1';
          cb_addr <= std_logic_vector(to_unsigned(cnt, 4));
          cb_data <= std_logic_vector(lf(7 downto 0));
          if cnt = 15 then cnt <= 0; st <= T_SET; else cnt <= cnt + 1; end if;
        when T_SET =>
          tl  <= to_integer(lf(2 downto 0)) + 1;
          nbk <= to_integer(lf(5 downto 3)) + 1;
          st  <= T_GO;
        when T_GO =>
          n_rows    <= std_logic_vector(to_unsigned(tl * ROWS_IF - to_integer(lf(3 downto 0)), 32));
          n_cols    <= std_logic_vector(to_unsigned(nbk * 32 - to_integer(lf(8 downto 4)), 32));
          out_shift <= std_logic_vector(to_unsigned(to_integer(lf(13 downto 9)) mod 41, 32));
          w_exp     <= std_logic_vector(resize(signed(lf(17 downto 14)), 32));
          x_exp     <= std_logic_vector(resize(signed(lf(21 downto 18)), 32));
          if lf(23 downto 22) = "11" then out_mode <= "00";
          else out_mode <= std_logic_vector(lf(23 downto 22)); end if;
          w_beats   <= std_logic_vector(to_unsigned(tl * nbk, 32));
          s_beats   <= std_logic_vector(to_unsigned(tl * nbk, 32));
          for k in 0 to NPORTS_W-1 loop
            wb_r((k+1)*ADDR_W-1 downto k*ADDR_W) <= port_base(to_integer(lf(26 downto 24)), k, lf(21 downto 12));
          end loop;
          for q in 0 to NPORTS_S-1 loop
            sb_r((q+1)*ADDR_W-1 downto q*ADDR_W) <= port_base(to_integer(lf(26 downto 24)), NPORTS_W + q, lf(21 downto 12));
          end loop;
          start <= '1';
          nj <= nj + 1;
          st <= T_WAIT;
        when T_WAIT =>
          if done = '1' then st <= T_X; end if;
      end case;
      if rst = '1' then
        st <= T_X; cnt <= 0; acc <= (others => '0'); nj <= (others => '0');
      end if;
    end if;
  end process;
end architecture;
