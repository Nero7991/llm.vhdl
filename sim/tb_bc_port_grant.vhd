-- sim/tb_bc_port_grant.vhd -- does the B/C grant's DRAIN INTERLOCK actually
-- discriminate, or is it decoration?
--
-- The property under test is NOT "the FSM has a guard".  It is the thing the
-- guard exists to prevent, stated so that a bench can see it:
--
--   EVERY completion must be delivered to the SAME requester that issued it.
--
-- So the monitor stamps the owner at each AR/AW handshake on each shared port,
-- and compares it against the owner in force when the matching RLAST/BVALID
-- comes back.  A mis-delivery is a direct observation of the corruption, not
-- an inspection of the mechanism -- which matters because the failure mode
-- here is silent: nothing errors, both requesters simply compute on the other
-- one's data.
--
-- MUTATION CONTROL, run by sim/tb_bc_port_grant_mut.sh:  the same bench against
-- a grant whose interlock is removed (switch on request rather than on quiet).
-- If that does not fail, this bench proves nothing about the interlock.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_bc_port_grant is end entity;

architecture sim of tb_bc_port_grant is
  constant AW : positive := 33;
  constant DW : positive := 256;
  constant NP : positive := 2;   -- the pool is 2: HBM has 32 SAXI, 2 host + 28 subsystem A

  signal clk  : std_logic := '0';
  signal rstn : std_logic := '0';
  signal done : boolean := false;

  signal b_req, c_req, b_gnt, c_gnt : std_logic := '0';

  signal b_arvalid, b_arready, b_rvalid, b_rlast, b_rready : std_logic := '0';
  signal b_awvalid, b_awready, b_wvalid, b_wlast, b_wready : std_logic := '0';
  signal b_bvalid, b_bready : std_logic := '0';
  signal b_araddr, b_awaddr : std_logic_vector(AW-1 downto 0) := (others=>'0');
  signal b_arlen, b_awlen   : std_logic_vector(7 downto 0) := (others=>'0');
  signal b_rdata, b_wdata   : std_logic_vector(DW-1 downto 0) := (others=>'0');

  signal c_arvalid, c_arready, c_rvalid, c_rlast, c_rready
       : std_logic_vector(1 downto 0) := (others=>'0');
  signal c_araddr : std_logic_vector(2*AW-1 downto 0) := (others=>'0');
  signal c_arlen  : std_logic_vector(15 downto 0) := (others=>'0');
  signal c_rdata  : std_logic_vector(2*DW-1 downto 0) := (others=>'0');
  signal c_awvalid, c_awready, c_wvalid, c_wlast, c_wready : std_logic := '0';
  signal c_bvalid, c_bready : std_logic := '0';
  signal c_awaddr : std_logic_vector(AW-1 downto 0) := (others=>'0');
  signal c_awlen  : std_logic_vector(7 downto 0) := (others=>'0');
  signal c_wdata  : std_logic_vector(DW-1 downto 0) := (others=>'0');

  signal m_arvalid, m_arready, m_rvalid, m_rlast, m_rready : std_logic_vector(NP-1 downto 0);
  signal m_awvalid, m_awready, m_wvalid, m_wlast, m_wready : std_logic_vector(NP-1 downto 0);
  signal m_bvalid, m_bready : std_logic_vector(NP-1 downto 0);
  signal m_araddr, m_awaddr : std_logic_vector(NP*AW-1 downto 0);
  signal m_arlen,  m_awlen  : std_logic_vector(NP*8-1 downto 0);
  signal m_rdata,  m_wdata  : std_logic_vector(NP*DW-1 downto 0);

  signal owner_is_c, draining, err_switch_busy : std_logic;

  -- monitor results, published at the end
  signal n_checks, n_fail, n_switch, n_rd, n_wr : natural := 0;

  -- PER-PORT traffic.  The aggregate counters above cannot see WHICH port
  -- carried a transfer, so they cannot see that the pool shrank from 3 to 2 by
  -- putting C's write on port 0's idle WRITE channels.  That fact is what the
  -- block design now depends on -- port 0 is wired to a real SAXI's AW/W/B --
  -- so it is pinned here rather than left as a reading of the source.
  type natvec is array (0 to NP-1) of natural;
  signal n_prd, n_pwr : natvec := (others => 0);
begin
  clk <= '0' when done else not clk after 2.5 ns;
  rstn <= '1' after 40 ns;

  dut : entity work.bc_port_grant
    generic map (ADDR_W=>AW, DATA_W=>DW, NPORT=>NP)
    port map (
      clk=>clk, rstn=>rstn, b_req=>b_req, c_req=>c_req, b_gnt=>b_gnt, c_gnt=>c_gnt,
      b_arvalid=>b_arvalid, b_araddr=>b_araddr, b_arlen=>b_arlen, b_arready=>b_arready,
      b_rvalid=>b_rvalid, b_rdata=>b_rdata, b_rlast=>b_rlast, b_rready=>b_rready,
      b_awvalid=>b_awvalid, b_awaddr=>b_awaddr, b_awlen=>b_awlen, b_awready=>b_awready,
      b_wvalid=>b_wvalid, b_wdata=>b_wdata, b_wlast=>b_wlast, b_wready=>b_wready,
      b_bvalid=>b_bvalid, b_bready=>b_bready,
      c_arvalid=>c_arvalid, c_araddr=>c_araddr, c_arlen=>c_arlen, c_arready=>c_arready,
      c_rvalid=>c_rvalid, c_rdata=>c_rdata, c_rlast=>c_rlast, c_rready=>c_rready,
      c_awvalid=>c_awvalid, c_awaddr=>c_awaddr, c_awlen=>c_awlen, c_awready=>c_awready,
      c_wvalid=>c_wvalid, c_wdata=>c_wdata, c_wlast=>c_wlast, c_wready=>c_wready,
      c_bvalid=>c_bvalid, c_bready=>c_bready,
      m_arvalid=>m_arvalid, m_araddr=>m_araddr, m_arlen=>m_arlen, m_arready=>m_arready,
      m_rvalid=>m_rvalid, m_rdata=>m_rdata, m_rlast=>m_rlast, m_rready=>m_rready,
      m_awvalid=>m_awvalid, m_awaddr=>m_awaddr, m_awlen=>m_awlen, m_awready=>m_awready,
      m_wvalid=>m_wvalid, m_wdata=>m_wdata, m_wlast=>m_wlast, m_wready=>m_wready,
      m_bvalid=>m_bvalid, m_bready=>m_bready,
      owner_is_c=>owner_is_c, draining=>draining, err_switch_busy=>err_switch_busy);

  -- ---- slave model: variable latency, one burst outstanding per port -----
  -- Latency VARIES per port so that a switch request can land at any point in
  -- a burst; a fixed latency would let the design pass by luck of alignment.
  slaves : for i in 0 to NP-1 generate
    process(clk) is
      variable rbeats : natural := 0;
      variable rlat   : natural := 0;
      variable wlat   : natural := 0;
      variable wseen  : boolean := false;
      variable lfsr   : unsigned(7 downto 0) := to_unsigned(37 + 11*i, 8);
    begin
      if rising_edge(clk) then
        if rstn = '0' then
          rbeats := 0; rlat := 0; wlat := 0; wseen := false;
          m_arready(i) <= '0'; m_rvalid(i) <= '0'; m_rlast(i) <= '0';
          m_awready(i) <= '0'; m_wready(i) <= '0'; m_bvalid(i) <= '0';
        else
          lfsr := lfsr(6 downto 0) & (lfsr(7) xor lfsr(5));

          -- read
          m_arready(i) <= '0';
          if rbeats = 0 and rlat = 0 and m_rvalid(i) = '0' then
            if m_arvalid(i) = '1' and m_arready(i) = '0' then
              m_arready(i) <= '1';
              rbeats := to_integer(unsigned(m_arlen(i*8+7 downto i*8))) + 1;
              rlat   := 1 + to_integer(lfsr(2 downto 0));
            end if;
          end if;
          if m_rvalid(i) = '1' and m_rready(i) = '1' then
            m_rvalid(i) <= '0'; m_rlast(i) <= '0';
            if rbeats > 0 then rbeats := rbeats - 1; end if;
            if rbeats > 0 then rlat := 1; end if;
          end if;
          if rbeats > 0 and m_rvalid(i) = '0' then
            if rlat > 0 then rlat := rlat - 1; end if;
            if rlat = 0 then
              m_rvalid(i) <= '1';
              if rbeats = 1 then m_rlast(i) <= '1'; end if;
            end if;
          end if;

          -- write
          m_awready(i) <= '0'; m_wready(i) <= '1';
          if not wseen and m_awvalid(i) = '1' and m_awready(i) = '0' then
            m_awready(i) <= '1';
          end if;
          if m_awvalid(i) = '1' and m_awready(i) = '1' then wseen := true; end if;
          if m_wvalid(i) = '1' and m_wready(i) = '1' and m_wlast(i) = '1' then
            wlat := 1 + to_integer(lfsr(1 downto 0));
          end if;
          if wlat > 0 and m_bvalid(i) = '0' then
            wlat := wlat - 1;
            if wlat = 0 then m_bvalid(i) <= '1'; end if;
          end if;
          if m_bvalid(i) = '1' and m_bready(i) = '1' then
            m_bvalid(i) <= '0'; wseen := false;
          end if;
        end if;
      end if;
    end process;
  end generate;

  m_rdata <= (others => '0');

  -- ---- requesters.  Both ask often and overlap, so switches are frequent.
  reqs : process(clk) is
    variable t : natural := 0;
  begin
    if rising_edge(clk) then
      if rstn = '0' then t := 0; b_req <= '0'; c_req <= '0';
      else
        t := t + 1;
        if (t mod 140) < 90 then b_req <= '1'; else b_req <= '0'; end if;
        if (t mod 100) < 70 then c_req <= '1'; else c_req <= '0'; end if;
      end if;
    end if;
  end process;

  -- ---- B master: one read burst and one write burst per grant window -----
  bmast : process(clk) is
    variable st : natural := 0;
    variable gap : natural := 0;
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        st := 0; gap := 0;
        b_arvalid<='0'; b_rready<='0'; b_awvalid<='0'; b_wvalid<='0';
        b_wlast<='0'; b_bready<='0';
      else
        b_rready <= '1'; b_bready <= '1';
        case st is
          when 0 =>
            b_arvalid<='0'; b_awvalid<='0'; b_wvalid<='0'; b_wlast<='0';
            if gap > 0 then gap := gap - 1;
            elsif b_gnt = '1' then
              b_araddr <= std_logic_vector(to_unsigned(16#1000#, AW));
              b_arlen  <= x"03"; b_arvalid <= '1'; st := 1;
            end if;
          when 1 =>
            if b_arready = '1' then b_arvalid <= '0'; st := 2; end if;
          when 2 =>
            if b_rvalid = '1' and b_rlast = '1' then st := 3; end if;
          when 3 =>
            if b_gnt = '1' then
              b_awaddr <= std_logic_vector(to_unsigned(16#2000#, AW));
              b_awlen  <= x"01"; b_awvalid <= '1'; st := 4;
            end if;
          when 4 =>
            if b_awready = '1' then b_awvalid<='0'; b_wvalid<='1'; st := 5; end if;
          when 5 =>
            if b_wready = '1' then b_wlast <= '1'; st := 6; end if;
          when 6 =>
            if b_wready = '1' then b_wvalid<='0'; b_wlast<='0'; st := 7; end if;
          when others =>
            if b_bvalid = '1' then gap := 6; st := 0; end if;
        end case;
      end if;
    end if;
  end process;

  -- ---- C master: two concurrent reads plus a write -----------------------
  cmast : process(clk) is
    variable st : natural := 0;
    variable gap : natural := 0;
    variable r0d, r1d : boolean := false;
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        st := 0; gap := 0; r0d := false; r1d := false;
        c_arvalid<="00"; c_rready<="00"; c_awvalid<='0'; c_wvalid<='0';
        c_wlast<='0'; c_bready<='0';
      else
        c_rready <= "11"; c_bready <= '1';
        case st is
          when 0 =>
            c_arvalid<="00"; c_awvalid<='0'; c_wvalid<='0'; c_wlast<='0';
            r0d := false; r1d := false;
            if gap > 0 then gap := gap - 1;
            elsif c_gnt = '1' then
              c_araddr <= std_logic_vector(to_unsigned(16#4000#, AW))
                        & std_logic_vector(to_unsigned(16#3000#, AW));
              c_arlen  <= x"01" & x"02";
              c_arvalid <= "11"; st := 1;
            end if;
          when 1 =>
            if c_arready(0) = '1' then c_arvalid(0) <= '0'; end if;
            if c_arready(1) = '1' then c_arvalid(1) <= '0'; end if;
            if c_arvalid = "00" then st := 2; end if;
          when 2 =>
            if c_rvalid(0)='1' and c_rlast(0)='1' then r0d := true; end if;
            if c_rvalid(1)='1' and c_rlast(1)='1' then r1d := true; end if;
            if r0d and r1d then st := 3; end if;
          when 3 =>
            if c_gnt = '1' then
              c_awaddr <= std_logic_vector(to_unsigned(16#5000#, AW));
              c_awlen  <= x"00"; c_awvalid <= '1'; st := 4;
            end if;
          when 4 =>
            if c_awready = '1' then
              c_awvalid<='0'; c_wvalid<='1'; c_wlast<='1'; st := 5;
            end if;
          when 5 =>
            if c_wready = '1' then c_wvalid<='0'; c_wlast<='0'; st := 6; end if;
          when others =>
            if c_bvalid = '1' then gap := 5; st := 0; end if;
        end case;
      end if;
    end if;
  end process;

  -- ---- THE MONITOR.  Stamp owner at issue, compare at completion. --------
  mon : process(clk) is
    type own_arr is array (0 to NP-1) of integer;
    variable rd_own, wr_own : own_arr := (others => -1);
    variable cur : integer;
    variable prev : integer := -1;
    variable chk, bad, sw, nrd, nwr : natural := 0;
    variable prd, pwr : natvec := (others => 0);
  begin
    if rising_edge(clk) then
      if rstn = '1' then
        if owner_is_c = '1' then cur := 1;
        elsif b_gnt = '1' then cur := 0;
        else cur := -1; end if;
        if cur /= prev then sw := sw + 1; end if;

        -- The interlock property, observed directly rather than inspected.
        for i in 0 to NP-1 loop
          if (m_arvalid(i) and m_arready(i)) = '1' then rd_own(i) := cur; end if;
          if (m_rvalid(i) and m_rlast(i) and m_rready(i)) = '1' then
            chk := chk + 1; nrd := nrd + 1; prd(i) := prd(i) + 1;
            if rd_own(i) /= cur then
              bad := bad + 1;
              report "MISDELIVERED READ port=" & integer'image(i)
                   & " issued_by=" & integer'image(rd_own(i))
                   & " delivered_to=" & integer'image(cur) severity error;
            end if;
          end if;
          if (m_awvalid(i) and m_awready(i)) = '1' then wr_own(i) := cur; end if;
          if (m_bvalid(i) and m_bready(i)) = '1' then
            chk := chk + 1; nwr := nwr + 1; pwr(i) := pwr(i) + 1;
            if wr_own(i) /= cur then
              bad := bad + 1;
              report "MISDELIVERED WRITE port=" & integer'image(i)
                   & " issued_by=" & integer'image(wr_own(i))
                   & " delivered_to=" & integer'image(cur) severity error;
            end if;
          end if;
        end loop;

        -- A VALID must never be pulled low without a handshake.
        prev := cur;
      end if;
      n_checks <= chk; n_fail <= bad; n_switch <= sw;
      n_rd <= nrd; n_wr <= nwr; n_prd <= prd; n_pwr <= pwr;
    end if;
  end process;

  drive : process is
    variable verdict  : boolean := false;
    variable pool_ok  : boolean := false;
    function verdict_s(b : boolean) return string is
    begin
      if b then return "PASS"; else return "FAIL"; end if;
    end function;
  begin
    wait for 400 us;
    if err_switch_busy = '1' then
      report "err_switch_busy asserted: the owner moved while the pool was busy"
        severity error;
    end if;
    -- EVERY port must have carried BOTH a read and a write.  With the pool at
    -- 2 this is only satisfiable if C's write really does ride port 0, beside
    -- the reads that port already carries.  Move it back onto port 1 and
    -- n_pwr(0) is zero, which the aggregate n_wr cannot show.
    pool_ok := true;
    for i in 0 to NP-1 loop
      if n_prd(i) = 0 then
        pool_ok := false;
        report "POOL PORT " & integer'image(i) & " CARRIED NO READ" severity error;
      end if;
      if n_pwr(i) = 0 then
        pool_ok := false;
        report "POOL PORT " & integer'image(i) & " CARRIED NO WRITE" severity error;
      end if;
    end loop;
    if n_fail = 0 and err_switch_busy = '0' and n_switch >= 8
       and n_rd >= 40 and n_wr >= 20 and pool_ok then
      verdict := true;
    end if;
    report "tb_bc_port_grant RESULT: "
         & verdict_s(verdict)
         & " -- checks=" & integer'image(n_checks)
         & " misdeliveries=" & integer'image(n_fail)
         & " switches=" & integer'image(n_switch)
         & " reads=" & integer'image(n_rd)
         & " writes=" & integer'image(n_wr)
         & " p0rd=" & integer'image(n_prd(0)) & " p0wr=" & integer'image(n_pwr(0))
         & " p1rd=" & integer'image(n_prd(1)) & " p1wr=" & integer'image(n_pwr(1))
         & " err_switch_busy=" & std_logic'image(err_switch_busy);
    done <= true;
    wait;
  end process;
end architecture;
