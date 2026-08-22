-- sim/tb_matvec_core.vhd
-- Validates rtl/matvec_core.vhd against ref/matvec_int4.c STAGE BY STAGE.
--
-- The stimulus AND every expected intermediate come from one file emitted by
--   ref/matvec_int4 --trace sim/matvec_trace.txt
-- so there is no hand-written expectation anywhere: a divergence localizes to
-- one stage (partial / contrib / acc / ydata / ns / ymant) on the first failing
-- vector, instead of appearing as a wrong output that has to be bisected.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_matvec_core is end entity;

architecture sim of tb_matvec_core is
  constant BLK : positive := 32;
  constant MAXR  : positive := 64;
  constant MAXB  : positive := 16;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal start : std_logic := '0';

  signal n_rows, n_cols, out_shift, w_exp, x_exp, y_exp : integer := 0;
  signal out_mode : std_logic_vector(1 downto 0) := "00";
  signal cb_we : std_logic := '0';
  signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
  signal cb_data : std_logic_vector(7 downto 0) := (others => '0');

  signal w_raddr, s_raddr : std_logic_vector(31 downto 0);
  signal w_rdata : std_logic_vector(BLK*4-1 downto 0) := (others => '0');
  signal s_rdata : std_logic_vector(15 downto 0) := (others => '0');
  signal x_rbaddr : std_logic_vector(15 downto 0);
  signal x_rdata : std_logic_vector(BLK*16-1 downto 0) := (others => '0');

  signal y_we : std_logic;
  signal y_addr : std_logic_vector(15 downto 0);
  signal y_data : std_logic_vector(31 downto 0);
  signal done, err, sat_event : std_logic;

  signal tap_valid : std_logic;
  signal tap_kind  : std_logic_vector(2 downto 0);
  signal tap_r, tap_b, tap_ns : integer;
  signal tap_val   : std_logic_vector(63 downto 0);

  -- memories built from the trace
  type wmem_t is array(0 to MAXR*MAXB-1) of std_logic_vector(BLK*4-1 downto 0);
  type smem_t is array(0 to MAXR*MAXB-1) of std_logic_vector(15 downto 0);
  type xmem_t is array(0 to MAXB-1)      of std_logic_vector(BLK*16-1 downto 0);
  signal wmem : wmem_t := (others => (others => '0'));
  signal smem : smem_t := (others => (others => '0'));
  signal xmem : xmem_t := (others => (others => '0'));

  -- expectations
  type exp_t is array(0 to MAXR*MAXB-1) of signed(63 downto 0);
  signal e_part, e_contrib : exp_t := (others => (others => '0'));
  type row_t is array(0 to MAXR-1) of signed(63 downto 0);
  signal e_acc, e_ydata, e_ymant : row_t := (others => (others => '0'));
  signal e_ns, e_yexp, nb_s : integer := 0;

  signal loaded : boolean := false;
  signal nbad   : integer := 0;
  signal nchk   : integer := 0;
begin
  clk <= not clk after 5 ns;

  w_rdata <= wmem(to_integer(unsigned(w_raddr))) when loaded else (others => '0');
  s_rdata <= smem(to_integer(unsigned(s_raddr))) when loaded else (others => '0');
  x_rdata <= xmem(to_integer(unsigned(x_rbaddr))) when loaded else (others => '0');

  dut : entity work.matvec_core
    generic map(BLK => BLK, MAXCOLS => 17408, MAXROWS_BFP => MAXR)
    port map(clk => clk, rst => rst, start => start,
             n_rows => n_rows, n_cols => n_cols, out_shift => out_shift,
             w_exp => w_exp, x_exp => x_exp, out_mode => out_mode,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             w_raddr => w_raddr, w_rdata => w_rdata,
             s_raddr => s_raddr, s_rdata => s_rdata,
             x_rbaddr => x_rbaddr, x_rdata => x_rdata,
             y_we => y_we, y_addr => y_addr, y_data => y_data, y_exp => y_exp,
             done => done, err => err, sat_event => sat_event,
             tap_valid => tap_valid, tap_kind => tap_kind,
             tap_r => tap_r, tap_b => tap_b, tap_val => tap_val,
             tap_ns => tap_ns);

  -- ---------------------------------------------------------------- loader
  load : process
    file     tf : text open read_mode is "../matvec_trace.txt";
    variable l  : line;
    variable tok : string(1 to 10);
    variable c  : character;
    variable slen, a, b, v : integer;
    variable hv : std_logic_vector(63 downto 0);
    variable h16 : std_logic_vector(15 downto 0);
    variable good : boolean;
    variable M, K, NB, osh, wev, xev : integer;
  begin
    -- The core gates cb_we on st = S_IDLE, and its reset branch takes priority,
    -- so codebook writes issued while rst is high are silently swallowed.
    wait until rst = '0';
    wait until rising_edge(clk);
    while not endfile(tf) loop
      readline(tf, l);
      if l'length = 0 then next; end if;
      read(l, c, good);
      if not good or c = '#' then next; end if;
      tok := (others => ' '); slen := 1; tok(1) := c;
      loop
        read(l, c, good);
        exit when not good or c = ' ';
        slen := slen + 1; tok(slen) := c;
      end loop;

      if tok(1 to 4) = "DIMS" then
        read(l, M); read(l, K); read(l, NB); read(l, osh); read(l, wev); read(l, xev);
        n_rows <= M; n_cols <= K; nb_s <= NB;
        out_shift <= osh; w_exp <= wev; x_exp <= xev;
      elsif tok(1 to 2) = "CB" then
        read(l, a); read(l, v);
        cb_addr <= std_logic_vector(to_unsigned(a, 4));
        cb_data <= std_logic_vector(to_signed(v, 8));
        cb_we <= '1'; wait until rising_edge(clk); cb_we <= '0';
      elsif tok(1 to 1) = "X" then
        read(l, a); hread(l, h16);
        xmem(a / BLK)((a mod BLK)*16+15 downto (a mod BLK)*16) <= h16;
      elsif tok(1 to 5) = "SCALE" then
        read(l, a); read(l, b); hread(l, h16);
        smem(a*nb_s + b) <= h16;
      elsif tok(1 to 3) = "IDX" then
        read(l, a); read(l, b); read(l, v);
        wmem(a*nb_s + b/BLK)((b mod BLK)*4+3 downto (b mod BLK)*4)
          <= std_logic_vector(to_unsigned(v, 4));
      elsif tok(1 to 7) = "PARTIAL" then
        read(l, a); read(l, b); hread(l, hv); e_part(a*nb_s + b) <= signed(hv);
      elsif tok(1 to 7) = "CONTRIB" then
        read(l, a); read(l, b); hread(l, hv); e_contrib(a*nb_s + b) <= signed(hv);
      elsif tok(1 to 3) = "ACC" then
        read(l, a); hread(l, hv); e_acc(a) <= signed(hv);
      elsif tok(1 to 5) = "YDATA" then
        read(l, a); hread(l, hv); e_ydata(a) <= signed(hv);
      elsif tok(1 to 5) = "YMANT" then
        read(l, a); hread(l, hv); e_ymant(a) <= signed(hv);
      elsif tok(1 to 2) = "NS" then
        read(l, a); e_ns <= a;
      elsif tok(1 to 4) = "YEXP" then
        read(l, a); e_yexp <= a;
      end if;
      wait for 0 ns;
    end loop;
    wait until rising_edge(clk);
    loaded <= true;
    wait;
  end process;

  -- ------------------------------------------------------------- stage check
  chk : process(clk)
    variable want : signed(63 downto 0);
    variable nm   : string(1 to 7);
  begin
    if rising_edge(clk) and tap_valid = '1' then
      case tap_kind is
        when "001" => want := e_part(tap_r*nb_s + tap_b);    nm := "PARTIAL";
        when "010" => want := e_contrib(tap_r*nb_s + tap_b); nm := "CONTRIB";
        when "011" => want := e_acc(tap_r);                  nm := "ACC    ";
        when "101" => want := e_ymant(tap_r);                nm := "YMANT  ";
        when others => want := (others => '0');              nm := "?      ";
      end case;
      nchk <= nchk + 1;
      if signed(tap_val) /= want then
        nbad <= nbad + 1;
        if nbad < 6 then
          report "STAGE MISMATCH " & nm & " r=" & integer'image(tap_r) &
                 " b=" & integer'image(tap_b) &
                 " got "  & integer'image(to_integer(resize(signed(tap_val),32))) &
                 " want " & integer'image(to_integer(resize(want,32)))
                 severity error;
        end if;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------ driver
  drv : process
  begin
    rst <= '1'; wait for 40 ns;
    rst <= '0';                       -- release BEFORE loading, see loader
    wait until loaded;
    wait until rising_edge(clk);
    out_mode <= "00";
    start <= '1'; wait until rising_edge(clk); start <= '0';
    wait until done = '1';
    wait until rising_edge(clk);

    assert tap_ns = e_ns
      report "NS MISMATCH got " & integer'image(tap_ns) &
             " want " & integer'image(e_ns) severity error;
    assert y_exp = e_yexp
      report "YEXP MISMATCH got " & integer'image(y_exp) &
             " want " & integer'image(e_yexp) severity error;

    report "stage checks: " & integer'image(nchk) & " compared, " &
           integer'image(nbad) & " mismatches, ns=" & integer'image(tap_ns) &
           " y_exp=" & integer'image(y_exp) severity note;
    assert nbad = 0 and tap_ns = e_ns and y_exp = e_yexp
      report "RTL DIVERGES FROM THE C REFERENCE" severity failure;
    report "RTL matches ref/matvec_int4.c at every stage" severity note;
    wait;
  end process;
end architecture;
