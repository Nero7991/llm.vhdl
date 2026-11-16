-- sim/tb_jc_seam_mux.vhd -- rtl/jc_seam_mux.vhd against sim/axil_slave_model.vhd as the
-- seam (plan 2026-11-04 Task 1). Oracle: the model's own transaction log (what reached
-- the seam) and the response each source saw.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axil_bfm_pkg.all;

entity tb_jc_seam_mux is
end entity;

architecture sim of tb_jc_seam_mux is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal hm, lm : axil_m2s_t := AXIL_M2S_IDLE;
  signal hs, ls : axil_s2m_t;
  signal loop_own, owner, host_refused : std_logic := '0';
  signal m_awaddr, m_araddr : std_logic_vector(11 downto 0);
  signal m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready : std_logic;
  signal m_arvalid, m_arready, m_rvalid, m_rready : std_logic;
  signal m_wdata, m_rdata : std_logic_vector(31 downto 0);
  signal m_wstrb : std_logic_vector(3 downto 0);
  signal m_bresp, m_rresp : std_logic_vector(1 downto 0);
  signal sl_aw, sl_ar : std_logic_vector(31 downto 0);
  signal log_count, log_kind, model_errs : natural := 0;
  signal log_idx : natural := 0;
  signal log_addr, log_data, reg_data : std_logic_vector(31 downto 0);
  signal log_resp : std_logic_vector(1 downto 0);
  signal mute_r : std_logic := '0';
  signal refused_n : natural := 0;
  signal phase : natural := 0;
  signal l_done : natural := 0;
  signal l_errs, l_checks : natural := 0;
begin
  clk <= not clk after 2.5 ns;

  dut : entity work.jc_seam_mux
    generic map(AW => 12)
    port map(clk => clk, rst => rst, loop_own => loop_own, owner => owner,
             host_refused => host_refused,
             s_h_awaddr => hm.awaddr(11 downto 0), s_h_awvalid => hm.awvalid,
             s_h_awready => hs.awready, s_h_wdata => hm.wdata, s_h_wstrb => hm.wstrb,
             s_h_wvalid => hm.wvalid, s_h_wready => hs.wready, s_h_bresp => hs.bresp,
             s_h_bvalid => hs.bvalid, s_h_bready => hm.bready,
             s_h_araddr => hm.araddr(11 downto 0), s_h_arvalid => hm.arvalid,
             s_h_arready => hs.arready, s_h_rdata => hs.rdata, s_h_rresp => hs.rresp,
             s_h_rvalid => hs.rvalid, s_h_rready => hm.rready,
             s_l_awaddr => lm.awaddr(11 downto 0), s_l_awvalid => lm.awvalid,
             s_l_awready => ls.awready, s_l_wdata => lm.wdata, s_l_wstrb => lm.wstrb,
             s_l_wvalid => lm.wvalid, s_l_wready => ls.wready, s_l_bresp => ls.bresp,
             s_l_bvalid => ls.bvalid, s_l_bready => lm.bready,
             s_l_araddr => lm.araddr(11 downto 0), s_l_arvalid => lm.arvalid,
             s_l_arready => ls.arready, s_l_rdata => ls.rdata, s_l_rresp => ls.rresp,
             s_l_rvalid => ls.rvalid, s_l_rready => lm.rready,
             m_awaddr => m_awaddr, m_awvalid => m_awvalid, m_awready => m_awready,
             m_wdata => m_wdata, m_wstrb => m_wstrb, m_wvalid => m_wvalid,
             m_wready => m_wready, m_bresp => m_bresp, m_bvalid => m_bvalid,
             m_bready => m_bready, m_araddr => m_araddr, m_arvalid => m_arvalid,
             m_arready => m_arready, m_rdata => m_rdata, m_rresp => m_rresp,
             m_rvalid => m_rvalid, m_rready => m_rready);

  sl_aw <= x"00000" & m_awaddr;
  sl_ar <= x"00000" & m_araddr;
  seam : entity work.axil_slave_model
    generic map(SLVERR_ADDR => x"0000_0F00", CNT_ADDR => x"0000_0F10", LOG_N => 4096,
                SEED => x"5EA1")
    port map(clk => clk, awaddr => sl_aw, awvalid => m_awvalid, awready => m_awready,
             wdata => m_wdata, wstrb => m_wstrb, wvalid => m_wvalid, wready => m_wready,
             bresp => m_bresp, bvalid => m_bvalid, bready => m_bready,
             araddr => sl_ar, arvalid => m_arvalid, arready => m_arready,
             rdata => m_rdata, rresp => m_rresp, rvalid => m_rvalid, rready => m_rready,
             log_count => log_count, log_idx => log_idx, log_kind => log_kind,
             log_addr => log_addr, log_data => log_data, log_resp => log_resp,
             reg_addr => x"00000000", reg_data => reg_data, errors => model_errs,
             mute_b => '0', mute_r => mute_r);

  process(clk)
  begin
    if rising_edge(clk) then
      if host_refused = '1' then refused_n <= refused_n + 1; end if;
    end if;
  end process;

  -- the loop-side master: phases 3, 4, 6, 7 (it may run concurrently with the host)
  lp : process
    variable resp : std_logic_vector(1 downto 0);
    variable d : std_logic_vector(31 downto 0);
    variable e, c : natural := 0;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "loop side: " & msg severity error; end if;
    end procedure;
  begin
    if phase /= 3 then wait until phase = 3; end if;
    axil_wr(clk, lm, ls, 16#108#, x"00001234", resp); chk(resp = "00", "owned write OKAY");
    axil_rd(clk, lm, ls, 16#108#, d, resp);
    chk(resp = "00" and d = x"00001234", "owned read returns the write");
    l_done <= 3;
    if phase /= 4 then wait until phase = 4; end if;
    axil_wr(clk, lm, ls, 16#10C#, x"0000BEEF", resp); chk(resp = "10", "non-owner loop write SLVERR");
    l_done <= 4;
    if phase /= 6 then wait until phase = 6; end if;
    for i in 0 to 19 loop
      axil_wr(clk, lm, ls, 16#200# + 4 * i, u32(i), resp); chk(resp = "00", "phase 6 loop write");
    end loop;
    l_done <= 6;
    if phase /= 7 then wait until phase = 7; end if;
    for i in 0 to 19 loop
      axil_wr(clk, lm, ls, 16#500# + 4 * i, u32(i), resp); chk(resp = "10", "phase 7 loop write refused");
    end loop;
    l_errs <= e; l_checks <= c;
    l_done <= 7;
    wait;
  end process;

  main : process
    variable resp : std_logic_vector(1 downto 0);
    variable d : std_logic_vector(31 downto 0);
    variable e, c, n0, n : natural := 0;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "host side: " & msg severity error; end if;
    end procedure;
    procedure peek(k : natural) is
    begin
      log_idx <= k; wait for 1 ps;
    end procedure;
  begin
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);
    -- 1: host owns by default
    axil_wr(clk, hm, hs, 16#100#, x"A5A50001", resp); chk(resp = "00", "host write OKAY");
    chk(log_count = 1, "host write reached the seam");
    peek(0); chk(log_kind = 0 and log_addr = x"00000100" and log_data = x"A5A50001", "logged write");
    axil_rd(clk, hm, hs, 16#100#, d, resp); chk(resp = "00" and d = x"A5A50001", "host read back");
    -- 2: the loop takes the seam; host accesses are refused and never reach it
    loop_own <= '1';
    n := 0;
    while owner = '0' loop wait until rising_edge(clk); n := n + 1; exit when n > 8; end loop;
    chk(owner = '1', "owner follows loop_own when idle");
    n0 := log_count;
    axil_wr(clk, hm, hs, 16#104#, x"DEAD0002", resp); chk(resp = "10", "refused host write SLVERR");
    axil_rd(clk, hm, hs, 16#100#, d, resp);
    chk(resp = "10" and d = x"00000000", "refused host read SLVERR, RDATA 0");
    chk(log_count = n0, "refused host accesses did not reach the seam");
    wait until rising_edge(clk);   -- let the counter process register both refusals (finding 5)
    chk(refused_n = 2, "host_refused pulsed once per refusal");
    -- 3: owned loop accesses pass
    phase <= 3; if l_done /= 3 then wait until l_done = 3; end if;
    -- 4: the host owns again; the loop is refused
    loop_own <= '0';
    n := 0;
    while owner = '1' loop wait until rising_edge(clk); n := n + 1; exit when n > 8; end loop;
    n0 := log_count;
    phase <= 4; if l_done /= 4 then wait until l_done = 4; end if;
    chk(log_count = n0, "refused loop write did not reach the seam");
    -- 5: ownership never changes with a transaction in flight
    mute_r <= '1';
    hm.araddr <= x"00000100"; hm.arvalid <= '1'; hm.rready <= '1';
    wait until rising_edge(clk) and hs.arready = '1';
    hm.arvalid <= '0';
    loop_own <= '1';
    for i in 1 to 20 loop
      wait until rising_edge(clk);
      chk(owner = '0', "owner held while a host read is in flight");
    end loop;
    mute_r <= '0';
    wait until rising_edge(clk) and hs.rvalid = '1';
    chk(hs.rresp = "00" and hs.rdata = x"A5A50001", "in-flight read completes OKAY");
    hm <= AXIL_M2S_IDLE;
    n := 0;
    while owner = '0' loop wait until rising_edge(clk); n := n + 1; exit when n > 8; end loop;
    chk(owner = '1', "owner switches after the read");
    -- 6: concurrent: loop owns; host 20 refused, loop 20 logged in order
    n0 := log_count;
    phase <= 6;
    for i in 0 to 19 loop
      axil_wr(clk, hm, hs, 16#300# + 4 * i, u32(i), resp); chk(resp = "10", "phase 6 host refused");
    end loop;
    if l_done /= 6 then wait until l_done = 6; end if;
    chk(log_count = n0 + 20, "exactly the loop's 20 writes reached the seam");
    for i in 0 to 19 loop
      peek(n0 + i);
      chk(log_addr = u32(16#200# + 4 * i) and log_data = u32(i), "loop write " & integer'image(i) & " in order");
    end loop;
    -- 7: host owns; the reverse
    loop_own <= '0';
    n := 0;
    while owner = '1' loop wait until rising_edge(clk); n := n + 1; exit when n > 8; end loop;
    n0 := log_count;
    phase <= 7;
    for i in 0 to 19 loop
      axil_wr(clk, hm, hs, 16#400# + 4 * i, u32(i), resp); chk(resp = "00", "phase 7 host write");
    end loop;
    if l_done /= 7 then wait until l_done = 7; end if;
    chk(log_count = n0 + 20, "exactly the host's 20 writes reached the seam");
    for i in 0 to 19 loop
      peek(n0 + i);
      chk(log_addr = u32(16#400# + 4 * i) and log_data = u32(i), "host write " & integer'image(i) & " in order");
    end loop;
    -- 8: a seam SLVERR passes through to the owner (and IS logged: it reached the seam)
    n0 := log_count;
    axil_wr(clk, hm, hs, 16#F00#, x"00000001", resp); chk(resp = "10", "seam SLVERR on write passes through");
    axil_rd(clk, hm, hs, 16#F00#, d, resp); chk(resp = "10", "seam SLVERR on read passes through");
    chk(log_count = n0 + 2, "the two SLVERR accesses reached the seam");
    chk(model_errs = 0, "no AXI protocol violation at the seam");
    e := e + l_errs; c := c + l_checks;
    if e = 0 then
      report "PASS: tb_jc_seam_mux checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_jc_seam_mux errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
