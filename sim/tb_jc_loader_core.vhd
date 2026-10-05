-- End-to-end bench for rtl/jc_loader_core.vhd: TCK at 27 MHz, aclk at 200 MHz, one Capture
-- then every slot of sim/jc_loader_vec.txt back to back. Checks HBM contents against the
-- Python model and the status word returned on TDO in the final poll slot.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.jc_loader_pkg.all;

entity tb_jc_loader_core is
end entity;

architecture sim of tb_jc_loader_core is
  constant TCK_P : time := 37 ns;
  constant CLK_P : time := 5 ns;
  signal tck, aclk : std_logic := '0';
  signal arst : std_logic := '1';
  signal sel, capture, shift, tdi, tdo : std_logic := '0';
  signal done : boolean := false;
  signal awaddr, araddr : std_logic_vector(32 downto 0);
  signal awlen, arlen : std_logic_vector(3 downto 0);
  signal awsize, arsize : std_logic_vector(2 downto 0);
  signal awburst, arburst, bresp, rresp : std_logic_vector(1 downto 0);
  signal awvalid, awready, wlast, wvalid, wready, bvalid, bready : std_logic;
  signal arvalid, arready, rlast, rvalid, rready : std_logic;
  signal wdata, rdata : std_logic_vector(255 downto 0);
  signal wstrb : std_logic_vector(31 downto 0);
  signal peek_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal peek_data : std_logic_vector(255 downto 0);
  signal peek_hit : std_logic;
  signal axi_errors : natural;
begin
  tck  <= not tck after TCK_P / 2 when not done else '0';
  aclk <= not aclk after CLK_P / 2 when not done else '0';

  dut : entity work.jc_loader_core
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, aclk => aclk, arst => arst, hbm_cat_trip => '0',
             m_awaddr => awaddr, m_awlen => awlen, m_awsize => awsize, m_awburst => awburst,
             m_awvalid => awvalid, m_awready => awready, m_wdata => wdata, m_wstrb => wstrb,
             m_wlast => wlast, m_wvalid => wvalid, m_wready => wready, m_bresp => bresp,
             m_bvalid => bvalid, m_bready => bready, m_araddr => araddr, m_arlen => arlen,
             m_arsize => arsize, m_arburst => arburst, m_arvalid => arvalid,
             m_arready => arready, m_rdata => rdata, m_rresp => rresp, m_rlast => rlast,
             m_rvalid => rvalid, m_rready => rready);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 11, STALL => true)
    port map(clk => aclk, awaddr => awaddr, awlen => awlen, awsize => awsize,
             awburst => awburst, awvalid => awvalid, awready => awready, wdata => wdata,
             wstrb => wstrb, wlast => wlast, wvalid => wvalid, wready => wready,
             bresp => bresp, bvalid => bvalid, bready => bready, araddr => araddr,
             arlen => arlen, arsize => arsize, arburst => arburst, arvalid => arvalid,
             arready => arready, rdata => rdata, rresp => rresp, rlast => rlast,
             rvalid => rvalid, rready => rready, peek_addr => peek_addr,
             peek_data => peek_data, peek_hit => peek_hit, errors => axi_errors);

  driver : process
    file vf : text open read_mode is "jc_loader_vec.txt";
    variable l : line;
    variable c : character;
    variable slot : std_logic_vector(JC_SLOT_BITS-1 downto 0);
    variable st : std_logic_vector(255 downto 0);
    variable a : std_logic_vector(39 downto 0);
    variable w : std_logic_vector(255 downto 0);
    variable e32 : std_logic_vector(31 downto 0);
    variable e16 : std_logic_vector(15 downto 0);
    variable checks, errors, nslot, nmem : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then errors := errors + 1; report msg severity error; end if;
    end procedure;
  begin
    wait for 20 * CLK_P; arst <= '0'; wait for 20 * CLK_P;
    sel <= '1';
    wait until falling_edge(tck); capture <= '1';
    wait until falling_edge(tck); capture <= '0'; shift <= '1';
    while not endfile(vf) loop
      readline(vf, l);
      read(l, c);
      if c = 'S' then
        hread(l, slot);
        for i in 0 to JC_SLOT_BITS - 1 loop
          tdi <= slot(i);
          wait until rising_edge(tck);
          if i < 256 then st(i) := tdo; end if;
          wait until falling_edge(tck);
        end loop;
        nslot := nslot + 1;
      elsif c = 'M' then
        hread(l, a); hread(l, w);
        peek_addr <= a; wait for 1 ns;
        chk(peek_hit = '1' and peek_data = w, "memory at " & to_hstring(a));
        nmem := nmem + 1;
      else                                                -- 'T': status of the last slot
        chk(st(31 downto 0) = JC_MAGIC_STAT, "status magic " & to_hstring(st(31 downto 0)));
        hread(l, e32); chk(st(63 downto 32) = e32, "last " & to_hstring(st(63 downto 32)));
        hread(l, e32); chk(st(95 downto 64) = e32, "committed " & to_hstring(st(95 downto 64)));
        hread(l, e16); chk(st(111 downto 96) = e16, "crc_fail");
        hread(l, e16); chk(st(127 downto 112) = e16, "seq_err");
        hread(l, e16); chk(st(175 downto 160) = e16, "dup");
        hread(l, e16); chk(st(143 downto 128) = e16, "desync");
        hread(l, e32); chk(st(223 downto 192) = e32, "range crc " & to_hstring(st(223 downto 192)));
        hread(l, e32); chk(st(255 downto 224) = e32, "range seq");
        chk(st(178) = '1', "range valid");
        chk(st(176) = '0', "idle at the end");
        chk(st(179) = '0' and st(180) = '0', "no overflow, no read error");
        chk(st(159 downto 144) = x"0000", "no BRESP errors");
      end if;
    end loop;
    shift <= '0';
    chk(axi_errors = 0, "AXI3 rule violations: " & integer'image(axi_errors));
    assert nslot = 20 report "expected 20 slots" severity failure;
    assert nmem > 100 report "too few memory checks: " & integer'image(nmem) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_loader_core checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_loader_core errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
