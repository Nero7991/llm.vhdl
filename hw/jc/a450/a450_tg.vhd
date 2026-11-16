-- hw/jc/a450/a450_tg.vhd -- a free-running AXI read (and optionally write) master for the
-- a450 A+HBM timing design (plan 2026-11-12-a450-per-port-tiles Task 9b).  It stands in
-- for the card's non-A HBM masters (the loader, the B/C grant's two pool ports, A's
-- descriptor fetch, the ctl and tok read masters), so the clock converters, register
-- slices and the smartconnect between them and the HBM are kept, placed and timed as the
-- card has them.  Synthesis only: no bench reads its values, and nothing here models a
-- real master's traffic pattern beyond being AXI-legal.
--
-- Legal AXI by construction: one read burst and one write burst outstanding at most,
-- 16 beats (ARLEN/AWLEN = 15, so it fits AXI3's 4 bits), 32-byte beats aligned to 512
-- bytes (no 4 KB crossing), INCR; AW is accepted before the first W beat; WLAST on beat 16.
-- Every input it is given reaches `obs` through registers (the read data is XOR-folded
-- into a 256-bit accumulator, which is reduced into `obs`), so synthesis cannot trim the
-- converters' read paths; the write data comes from the LFSR, so neither can it trim
-- their write paths.  VHDL-93 (it is under a module-reference top).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity a450_tg is
  generic(
    LEN_W : positive := 4;          -- 4: AXI3 ARLEN/AWLEN; 8: AXI4
    WR    : boolean  := true;       -- false: AW/W idle, BREADY high (a read-only master)
    SEED  : natural  := 1
  );
  port(
    clk     : in  std_logic;
    rstn    : in  std_logic;
    awvalid : out std_logic;
    awready : in  std_logic;
    awaddr  : out std_logic_vector(32 downto 0);
    awlen   : out std_logic_vector(LEN_W-1 downto 0);
    wvalid  : out std_logic;
    wready  : in  std_logic;
    wdata   : out std_logic_vector(255 downto 0);
    wlast   : out std_logic;
    bvalid  : in  std_logic;
    bready  : out std_logic;
    bresp   : in  std_logic_vector(1 downto 0);
    arvalid : out std_logic;
    arready : in  std_logic;
    araddr  : out std_logic_vector(32 downto 0);
    arlen   : out std_logic_vector(LEN_W-1 downto 0);
    rvalid  : in  std_logic;
    rready  : out std_logic;
    rdata   : in  std_logic_vector(255 downto 0);
    rlast   : in  std_logic;
    rresp   : in  std_logic_vector(1 downto 0);
    obs     : out std_logic
  );
end entity;

architecture rtl of a450_tg is
  signal lfsr  : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(SEED + 1, 32));
  signal arv   : std_logic := '0';
  signal rrdy  : std_logic := '0';
  signal acc   : std_logic_vector(255 downto 0) := (others => '0');
  signal side  : std_logic := '0';
  signal fold  : std_logic := '0';
  type wst_t is (W_IDLE, W_AW, W_DATA, W_RESP);
  signal wst   : wst_t := W_IDLE;
  signal wcnt  : unsigned(3 downto 0) := (others => '0');
  signal awa   : std_logic_vector(32 downto 0) := (others => '0');
  signal ara   : std_logic_vector(32 downto 0) := (others => '0');
  signal wd    : std_logic_vector(255 downto 0) := (others => '0');

  function xr (v : std_logic_vector) return std_logic is
    variable r : std_logic := '0';
  begin
    for i in v'range loop r := r xor v(i); end loop;
    return r;
  end function;
begin
  -- 32-bit Galois LFSR (taps 32, 22, 2, 1)
  p_lfsr : process(clk)
  begin
    if rising_edge(clk) then
      if lfsr(0) = '1' then
        lfsr <= ('0' & lfsr(31 downto 1)) xor x"80200003";
      else
        lfsr <= '0' & lfsr(31 downto 1);
      end if;
    end if;
  end process;

  -- read: one 16-beat burst outstanding; RREADY toggles with the LFSR
  p_rd : process(clk)
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        arv <= '0'; rrdy <= '0'; acc <= (others => '0'); side <= '0';
      else
        if arv = '0' and lfsr(0) = '1' then
          arv <= '1';
          ara <= lfsr(23 downto 0) & "000000000";
        elsif arv = '1' and arready = '1' then
          arv <= '0';
        end if;
        rrdy <= lfsr(1) or lfsr(5);
        if rvalid = '1' and rrdy = '1' then
          acc  <= acc xor rdata;
          side <= side xor rlast xor rresp(1) xor rresp(0);
        end if;
      end if;
    end if;
  end process;
  arvalid <= arv;
  araddr  <= ara;
  arlen   <= std_logic_vector(to_unsigned(15, LEN_W));
  rready  <= rrdy;

  g_wr : if WR generate
    p_wr : process(clk)
    begin
      if rising_edge(clk) then
        if rstn = '0' then
          wst <= W_IDLE; wcnt <= (others => '0');
        else
          case wst is
            when W_IDLE =>
              if lfsr(2) = '1' then
                awa <= lfsr(31 downto 8) & "000000000";
                wst <= W_AW;
              end if;
            when W_AW =>
              if awready = '1' then wst <= W_DATA; wcnt <= (others => '0'); end if;
            when W_DATA =>
              if wready = '1' then
                if wcnt = 15 then wst <= W_RESP; end if;
                wcnt <= wcnt + 1;
              end if;
            when W_RESP =>
              if bvalid = '1' then wst <= W_IDLE; end if;
          end case;
          -- the data of the next beat: a new LFSR word in every 32-bit lane
          if wst /= W_DATA or wready = '1' then
            for k in 0 to 7 loop
              wd(32*k + 31 downto 32*k) <= lfsr(31 - k downto 0) & lfsr(31 downto 32 - k);
            end loop;
          end if;
        end if;
      end if;
    end process;
    awvalid <= '1' when wst = W_AW else '0';
    awaddr  <= awa;
    awlen   <= std_logic_vector(to_unsigned(15, LEN_W));
    wvalid  <= '1' when wst = W_DATA else '0';
    wdata   <= wd;
    wlast   <= '1' when wst = W_DATA and wcnt = 15 else '0';
    bready  <= '1' when wst = W_RESP else '0';
  end generate;

  g_ro : if not WR generate
    awvalid <= '0';
    awaddr  <= (others => '0');
    awlen   <= (others => '0');
    wvalid  <= '0';
    wdata   <= (others => '0');
    wlast   <= '0';
    bready  <= '1';
  end generate;

  p_obs : process(clk)
  begin
    if rising_edge(clk) then
      fold <= xr(acc) xor side xor (bvalid and bresp(1)) xor (bvalid and bresp(0));
    end if;
  end process;
  obs <= fold;
end architecture;
