-- Bench for rtl/jc_hbm_crc.vhd: preloads sim/jc_axi3_mem.vhd, issues range requests and
-- compares each result with the zlib CRC in sim/jc_crcunit_vec.txt.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_jc_hbm_crc is
end entity;

architecture sim of tb_jc_hbm_crc is
  constant CLK_P : time := 5 ns;
  signal clk, rst : std_logic := '0';
  signal done : boolean := false;
  signal req, busy, res_valid, res_err : std_logic := '0';
  signal req_addr, araddr : std_logic_vector(32 downto 0) := (others => '0');
  signal req_len : unsigned(39 downto 0) := (others => '0');
  signal req_seq, res_crc, res_seq : std_logic_vector(31 downto 0) := (others => '0');
  signal arlen : std_logic_vector(3 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst, rresp : std_logic_vector(1 downto 0);
  signal arvalid, arready, rlast, rvalid, rready : std_logic;
  signal rdata : std_logic_vector(255 downto 0);
  signal poke_en : std_logic := '0';
  signal poke_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal poke_data : std_logic_vector(255 downto 0) := (others => '0');
  signal axi_errors : natural;
begin
  clk <= not clk after CLK_P / 2 when not done else '0';

  dut : entity work.jc_hbm_crc
    port map(clk => clk, rst => rst, req => req, req_addr => req_addr, req_len => req_len,
             req_seq => req_seq, busy => busy, araddr => araddr, arlen => arlen,
             arsize => arsize, arburst => arburst, arvalid => arvalid, arready => arready,
             rdata => rdata, rresp => rresp, rlast => rlast, rvalid => rvalid,
             rready => rready, res_valid => res_valid, res_err => res_err,
             res_crc => res_crc, res_seq => res_seq);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 11, STALL => true,
                BAD_RRESP_ADDR => x"0000002100")
    port map(clk => clk, awaddr => (others => '0'), awlen => "0000", awsize => "101",
             awburst => "01", awvalid => '0', awready => open, wdata => (others => '0'),
             wstrb => (others => '1'), wlast => '0', wvalid => '0', wready => open,
             bresp => open, bvalid => open, bready => '0', araddr => araddr, arlen => arlen,
             arsize => arsize, arburst => arburst, arvalid => arvalid, arready => arready,
             rdata => rdata, rresp => rresp, rlast => rlast, rvalid => rvalid,
             rready => rready, poke_en => poke_en, poke_addr => poke_addr,
             poke_data => poke_data, peek_data => open, peek_hit => open,
             errors => axi_errors);

  driver : process
    file vf : text open read_mode is "jc_crcunit_vec.txt";
    variable l : line;
    variable c : character;
    variable a : std_logic_vector(39 downto 0);
    variable n : std_logic_vector(39 downto 0);
    variable w : std_logic_vector(255 downto 0);
    variable s32, e32 : std_logic_vector(31 downto 0);
    variable experr : integer;
    variable exp_err_sl : std_logic;
    variable checks, errors, nreq : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then errors := errors + 1; report msg severity error; end if;
    end procedure;
  begin
    rst <= '1'; wait for 4 * CLK_P; wait until rising_edge(clk); rst <= '0';
    while not endfile(vf) loop
      readline(vf, l);
      read(l, c);
      if c = 'M' then
        hread(l, a); hread(l, w);
        poke_addr <= a; poke_data <= w; poke_en <= '1';
        wait until rising_edge(clk); poke_en <= '0';
      else
        hread(l, a); hread(l, n); hread(l, s32); hread(l, e32); read(l, experr);
        if experr = 1 then exp_err_sl := '1'; else exp_err_sl := '0'; end if;
        req_addr <= a(32 downto 0); req_len <= unsigned(n); req_seq <= s32; req <= '1';
        wait until rising_edge(clk); req <= '0';
        wait until rising_edge(clk);
        for i in 0 to 20000 loop
          exit when busy = '0';
          wait until rising_edge(clk);
        end loop;
        chk(busy = '0', "request " & to_hstring(s32) & " never finished");
        chk(res_valid = '1' and res_seq = s32, "result seq " & to_hstring(res_seq));
        chk(res_crc = e32, "crc " & to_hstring(res_crc) & " expected " & to_hstring(e32));
        chk(res_err = exp_err_sl, "res_err " & std_logic'image(res_err) & " expected " &
            std_logic'image(exp_err_sl) & " for seq " & to_hstring(s32));
        nreq := nreq + 1;
      end if;
    end loop;
    chk(axi_errors = 0, "AXI3 rule violations: " & integer'image(axi_errors));
    assert nreq = 7 report "expected 7 requests" severity failure;
    if errors = 0 then
      report "PASS: tb_jc_hbm_crc checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_hbm_crc errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
