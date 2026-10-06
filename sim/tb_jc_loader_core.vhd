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
  -- Task 9b: the die identity. A made-up value with distinct halves (no real DNA is ever
  -- committed); sim/jc_dna_model.vhd stands in for DNA_PORTE2.
  constant SIM_DNA : std_logic_vector(95 downto 0) := x"0A1B2C3D4E5F60718293A4B5";
  signal dna_clk, dna_read, dna_shift, dna_dout : std_logic;
  signal dna_errors, dna_reads, dna_shifts : natural;
  -- fix round 1, I2: exercised partway through the final poll slots (hbm_cat_trip has no
  -- dedicated vector field; it is driven directly here, not read from the vector file).
  signal hbm_trip : std_logic := '0';
begin
  tck  <= not tck after TCK_P / 2 when not done else '0';
  aclk <= not aclk after CLK_P / 2 when not done else '0';

  dut : entity work.jc_loader_core
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, aclk => aclk, arst => arst, hbm_cat_trip => hbm_trip,
             dna_clk => dna_clk, dna_read => dna_read, dna_shift => dna_shift,
             dna_dout => dna_dout,
             m_awaddr => awaddr, m_awlen => awlen, m_awsize => awsize, m_awburst => awburst,
             m_awvalid => awvalid, m_awready => awready, m_wdata => wdata, m_wstrb => wstrb,
             m_wlast => wlast, m_wvalid => wvalid, m_wready => wready, m_bresp => bresp,
             m_bvalid => bvalid, m_bready => bready, m_araddr => araddr, m_arlen => arlen,
             m_arsize => arsize, m_arburst => arburst, m_arvalid => arvalid,
             m_arready => arready, m_rdata => rdata, m_rresp => rresp, m_rlast => rlast,
             m_rvalid => rvalid, m_rready => rready);

  -- T_MARGIN = one aclk period (the reader's own clock)
  dnam : entity work.jc_dna_model
    generic map(SIM_DNA => SIM_DNA, T_MARGIN => CLK_P, T_CLK_MIN => 40 ns)
    port map(clk => dna_clk, read => dna_read, shift => dna_shift, din => '0',
             dout => dna_dout, errors => dna_errors, reads => dna_reads,
             shifts => dna_shifts);

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
    variable st : std_logic_vector(JC_STATUS_BITS-1 downto 0);
    variable tail_zero : boolean := true;
    variable a : std_logic_vector(39 downto 0);
    variable w : std_logic_vector(255 downto 0);
    variable e32 : std_logic_vector(31 downto 0);
    variable e16 : std_logic_vector(15 downto 0);
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
          if i < JC_STATUS_BITS then
            st(i) := tdo;
          elsif tdo /= '0' then
            tail_zero := false;
          end if;
          wait until falling_edge(tck);
        end loop;
        nslot := nslot + 1;
        -- Task 9b fix round 1 (M4): the first slot's status was captured ~0.2 us after
        -- reset release, long before the DNA read can finish (97 dna_clk periods = 9.7
        -- us at DNA_DIV 10 and 200 MHz), so it must show a real status (magic) with
        -- dna_valid clear and the DNA field still zero.
        if nslot = 1 then
          chk(st(31 downto 0) = JC_MAGIC_STAT, "first status magic " & to_hstring(st(31 downto 0)));
          chk(st(352) = '0', "dna_valid must be clear in the first status");
          chk(st(351 downto 256) = (351 downto 256 => '0'),
              "DNA field must be zero before the read completes: " & to_hstring(st(351 downto 256)));
        end if;
        -- fix round 1, I2: slots 18-20 are the three trailing polls (17 real/control slots
        -- precede them). Slot 18's status was loaded at its own start, before hbm_trip is
        -- raised below, so it must still read clear; raising it here gives the CDC (2 aclk
        -- flops) and the status reload two full slots to reach slot 20's status, which the
        -- 'T' branch below checks.
        if nslot = 18 then
          chk(st(177) = '0', "HBM trip must read clear before it is driven");
          hbm_trip <= '1';
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
        chk(st(191 downto 181) = "00000000000", "status bits 191:181 must be zero");
        -- Task 9b: die identity in the final status, upper bits zero
        chk(st(351 downto 256) = SIM_DNA, "dna " & to_hstring(st(351 downto 256)) &
            " expected " & to_hstring(SIM_DNA));
        chk(st(352) = '1', "dna_valid must be set");
        chk(st(383 downto 353) = (383 downto 353 => '0'), "status bits 383:353 must be zero");
        -- fix round 1, I2: raised two slots ago (at nslot=18); must read set by now.
        chk(st(177) = '1', "HBM trip must read set in the final poll");
      end if;
    end loop;
    shift <= '0';
    chk(axi_errors = 0, "AXI3 rule violations: " & integer'image(axi_errors));
    chk(tail_zero, "TDO bits past 383 must be zero in every slot");
    chk(dna_errors = 0 and dna_reads = 1 and dna_shifts = 95,
        "DNA_PORTE2 model: errors " & integer'image(dna_errors) & " reads " &
        integer'image(dna_reads) & " shifts " & integer'image(dna_shifts));
    assert nslot = 20 report "expected 20 slots" severity failure;
    assert nmem > 100 report "too few memory checks: " & integer'image(nmem) severity failure;
    assert nT = 1 report "expected exactly 1 status line, got " & integer'image(nT) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_loader_core checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_loader_core errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
