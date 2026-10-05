-- Fix round 1 (I1): end-to-end FIFO-overflow bench for rtl/jc_loader_core.vhd. The AXI3 AW
-- channel is held closed (awvalid/awready gated to '0') across four frames -- long enough
-- that the 128-deep async_fifo genuinely overflows, not merely stalls (sim/tb_jc_loader_core.vhd
-- already covers ordinary stalling via jc_axi3_mem's STALL=>true, which never drops a beat).
-- Expected status/memory come from tools/jc/jc_model.py's FifoOverflowModel, an explicit,
-- independent simulation of the FIFO-drop and the writer's lost-verdict path (see that class's
-- docstring and tools/jc/gen_jc_vectors.py's gen_loader_ovf for the exact frame/gate schedule
-- and why each field has the value it has), never a value copied from the RTL's own output.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.jc_loader_pkg.all;

entity tb_jc_loader_ovf is
end entity;

architecture sim of tb_jc_loader_ovf is
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
  -- the AW gate: '0' forces the DUT's awready and the memory's awvalid both low, so the
  -- AW handshake cannot complete in either direction while this is held down.
  signal gate : std_logic := '1';
  signal awready_d, awvalid_m : std_logic;
begin
  tck  <= not tck after TCK_P / 2 when not done else '0';
  aclk <= not aclk after CLK_P / 2 when not done else '0';

  dut : entity work.jc_loader_core
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, aclk => aclk, arst => arst, hbm_cat_trip => '0',
             m_awaddr => awaddr, m_awlen => awlen, m_awsize => awsize, m_awburst => awburst,
             m_awvalid => awvalid, m_awready => awready_d, m_wdata => wdata, m_wstrb => wstrb,
             m_wlast => wlast, m_wvalid => wvalid, m_wready => wready, m_bresp => bresp,
             m_bvalid => bvalid, m_bready => bready, m_araddr => araddr, m_arlen => arlen,
             m_arsize => arsize, m_arburst => arburst, m_arvalid => arvalid,
             m_arready => arready, m_rdata => rdata, m_rresp => rresp, m_rlast => rlast,
             m_rvalid => rvalid, m_rready => rready);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 11, STALL => true)
    port map(clk => aclk, awaddr => awaddr, awlen => awlen, awsize => awsize,
             awburst => awburst, awvalid => awvalid_m, awready => awready, wdata => wdata,
             wstrb => wstrb, wlast => wlast, wvalid => wvalid, wready => wready,
             bresp => bresp, bvalid => bvalid, bready => bready, araddr => araddr,
             arlen => arlen, arsize => arsize, arburst => arburst, arvalid => arvalid,
             arready => arready, rdata => rdata, rresp => rresp, rlast => rlast,
             rvalid => rvalid, rready => rready, peek_addr => peek_addr,
             peek_data => peek_data, peek_hit => peek_hit, errors => axi_errors);

  awready_d <= awready and gate;
  awvalid_m <= awvalid and gate;

  driver : process
    file vf : text open read_mode is "jc_loader_ovf_vec.txt";
    variable l : line;
    variable c : character;
    variable slot : std_logic_vector(JC_SLOT_BITS-1 downto 0);
    variable st : std_logic_vector(255 downto 0);
    variable a : std_logic_vector(39 downto 0);
    variable w : std_logic_vector(255 downto 0);
    variable e32 : std_logic_vector(31 downto 0);
    variable e16 : std_logic_vector(15 downto 0);
    variable ovf_exp : integer;
    variable checks, errors, nslot, nmem, nT : natural := 0;
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
        -- the AW gate schedule from tools/jc/gen_jc_vectors.py's gen_loader_ovf docstring:
        -- closes right before seq1 (slot index 2, 1-based counting the filler), reopens
        -- right after seq4's slot (index 6) completes.
        if nslot = 2 then
          gate <= '0';
        elsif nslot = 6 then
          gate <= '1';
        end if;
      elsif c = 'M' then
        hread(l, a); hread(l, w);
        peek_addr <= a; wait for 1 ns;
        chk(peek_hit = '1' and peek_data = w, "memory at " & to_hstring(a));
        nmem := nmem + 1;
      else                                                -- 'T': status of the last slot
        nT := nT + 1;
        chk(st(31 downto 0) = JC_MAGIC_STAT, "status magic " & to_hstring(st(31 downto 0)));
        hread(l, e32); chk(st(63 downto 32) = e32, "last " & to_hstring(st(63 downto 32)));
        hread(l, e32); chk(st(95 downto 64) = e32, "committed " & to_hstring(st(95 downto 64)));
        hread(l, e16); chk(st(111 downto 96) = e16, "crc_fail " & to_hstring(st(111 downto 96)));
        hread(l, e16); chk(st(127 downto 112) = e16, "seq_err " & to_hstring(st(127 downto 112)));
        hread(l, e16); chk(st(175 downto 160) = e16, "dup " & to_hstring(st(175 downto 160)));
        hread(l, e16); chk(st(143 downto 128) = e16, "desync " & to_hstring(st(143 downto 128)));
        read(l, ovf_exp);
        if ovf_exp = 1 then
          chk(st(179) = '1', "overflow (bit 179) expected set, was 0");
        else
          chk(st(179) = '0', "overflow (bit 179) expected clear, was 1");
        end if;
        chk(st(176) = '0', "idle at the end");
        chk(st(177) = '0', "no HBM trip asserted in this bench");
        chk(st(178) = '0', "no range request was sent: range valid must stay clear");
        chk(st(180) = '0', "no range read error (no range request was sent)");
        chk(st(159 downto 144) = x"0000", "no BRESP errors");
        chk(st(191 downto 181) = "00000000000", "status bits 191:181 must be zero");
        chk(st(223 downto 192) = x"00000000", "range crc must stay at its reset default");
        chk(st(255 downto 224) = x"00000000", "range seq must stay at its reset default");
      end if;
    end loop;
    shift <= '0';
    chk(axi_errors = 0, "AXI3 rule violations: " & integer'image(axi_errors));
    assert nslot = 11 report "expected 11 slots" severity failure;
    assert nmem = 371 report "expected 371 memory checks: " & integer'image(nmem) severity failure;
    assert nT = 1 report "expected exactly 1 status line, got " & integer'image(nT) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_loader_ovf checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_loader_ovf errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
