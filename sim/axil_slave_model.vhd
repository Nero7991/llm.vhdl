-- AXI-Lite slave recorder for the Jungle Cat control executor bench (plan Task 3).
-- Independent of the executor: it knows nothing of frames, ops or the response RAM.
--   * a 64 KB register array (16,384 x 32), byte offset addr[15:2]; reads return it;
--   * every completed transaction is appended to a log, in completion order: kind
--     (0 write, 1 read), address, data (written, or returned), response;
--   * SLVERR ("10") on a write or read at SLVERR_ADDR (the write is not applied);
--   * DECERR ("11") on any address >= 0x10000 (nothing applied);
--   * a stateful register at CNT_ADDR: each read returns the number of reads of it so far
--     (1, 2, 3, ...), so a read executed twice is visible as a skipped value;
--   * random AWREADY/WREADY/ARREADY/BVALID/RVALID stalls (LFSR), AW and W accepted
--     independently in either order;
--   * protocol checks counted on `errors`: a VALID dropped or its payload changed before its
--     handshake, and a partial WSTRB. AxPROT is not an input (the bench checks it).
-- Peek ports read the log and the register array combinationally.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axil_slave_model is
  generic(SLVERR_ADDR : std_logic_vector(31 downto 0) := x"0000_F000";
          CNT_ADDR    : std_logic_vector(31 downto 0) := x"0000_F100";
          LOG_N       : positive := 4096;
          SEED        : std_logic_vector(15 downto 0) := x"B5AD");
  port(
    clk     : in  std_logic;
    awaddr  : in  std_logic_vector(31 downto 0);
    awvalid : in  std_logic;
    awready : out std_logic := '0';
    wdata   : in  std_logic_vector(31 downto 0);
    wstrb   : in  std_logic_vector(3 downto 0);
    wvalid  : in  std_logic;
    wready  : out std_logic := '0';
    bresp   : out std_logic_vector(1 downto 0) := "00";
    bvalid  : out std_logic := '0';
    bready  : in  std_logic;
    araddr  : in  std_logic_vector(31 downto 0);
    arvalid : in  std_logic;
    arready : out std_logic := '0';
    rdata   : out std_logic_vector(31 downto 0) := (others => '0');
    rresp   : out std_logic_vector(1 downto 0) := "00";
    rvalid  : out std_logic := '0';
    rready  : in  std_logic;
    -- observation
    log_count : out natural;
    log_idx   : in  natural;
    log_kind  : out natural;            -- 0 write, 1 read
    log_addr  : out std_logic_vector(31 downto 0);
    log_data  : out std_logic_vector(31 downto 0);
    log_resp  : out std_logic_vector(1 downto 0);
    reg_addr  : in  std_logic_vector(31 downto 0);
    reg_data  : out std_logic_vector(31 downto 0);
    errors    : out natural
  );
end entity;

architecture sim of axil_slave_model is
  type reg_t is array (0 to 16383) of std_logic_vector(31 downto 0);
  type a32_t is array (0 to LOG_N-1) of std_logic_vector(31 downto 0);
  type a2_t  is array (0 to LOG_N-1) of std_logic_vector(1 downto 0);
  type n_t   is array (0 to LOG_N-1) of natural;
  signal regs : reg_t := (others => (others => '0'));
  signal l_kind : n_t := (others => 0);
  signal l_addr, l_data : a32_t := (others => (others => '0'));
  signal l_resp : a2_t := (others => "00");
  signal nlog : natural := 0;
  signal nerr : natural := 0;
begin
  log_count <= nlog;
  errors    <= nerr;
  log_kind  <= l_kind(log_idx) when log_idx < LOG_N else 0;
  log_addr  <= l_addr(log_idx) when log_idx < LOG_N else (others => 'X');
  log_data  <= l_data(log_idx) when log_idx < LOG_N else (others => 'X');
  log_resp  <= l_resp(log_idx) when log_idx < LOG_N else "XX";
  reg_data  <= regs(to_integer(unsigned(reg_addr(15 downto 2))));

  process(clk)
    variable lfsr : std_logic_vector(15 downto 0) := SEED;
    variable aw_have, w_have, b_pend, r_pend : boolean := false;
    variable aw_a, w_d, ar_a : std_logic_vector(31 downto 0);
    variable p_awv, p_wv, p_arv : std_logic := '0';
    variable p_awa, p_wd, p_ara : std_logic_vector(31 downto 0) := (others => '0');
    variable p_awr, p_wr, p_arr : std_logic := '0';
    variable n : natural;
    variable e : natural;
    variable resp : std_logic_vector(1 downto 0);
    variable rd : std_logic_vector(31 downto 0);
    variable cnt_reads : natural := 0;
    variable aw_rdy, w_rdy, ar_rdy : std_logic;
    impure function rnd return std_logic is
    begin
      lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      return lfsr(0) and lfsr(5);   -- stall about one cycle in four
    end function;
    procedure log_it(k : natural; a, d : std_logic_vector(31 downto 0);
                     r : std_logic_vector(1 downto 0)) is
    begin
      if n < LOG_N then
        l_kind(n) <= k; l_addr(n) <= a; l_data(n) <= d; l_resp(n) <= r;
      end if;
      n := n + 1;
    end procedure;
  begin
    if rising_edge(clk) then
      n := nlog;
      e := nerr;
      -- stability checks: a VALID that was high without a handshake on the previous edge
      -- must still be high with the same payload
      if p_awv = '1' and p_awr = '0' and (awvalid /= '1' or awaddr /= p_awa) then
        e := e + 1; report "axil: AWVALID/AWADDR changed before AWREADY" severity error;
      end if;
      if p_wv = '1' and p_wr = '0' and (wvalid /= '1' or wdata /= p_wd) then
        e := e + 1; report "axil: WVALID/WDATA changed before WREADY" severity error;
      end if;
      if p_arv = '1' and p_arr = '0' and (arvalid /= '1' or araddr /= p_ara) then
        e := e + 1; report "axil: ARVALID/ARADDR changed before ARREADY" severity error;
      end if;

      -- handshakes on this edge (the READY outputs are the registered values)
      aw_rdy := '0'; w_rdy := '0'; ar_rdy := '0';
      if awvalid = '1' and awready = '1' then
        aw_have := true; aw_a := awaddr;
      end if;
      if wvalid = '1' and wready = '1' then
        w_have := true; w_d := wdata;
        if wstrb /= "1111" then
          e := e + 1; report "axil: partial WSTRB" severity error;
        end if;
      end if;
      if bvalid = '1' and bready = '1' then
        bvalid <= '0'; b_pend := false;
      end if;
      if rvalid = '1' and rready = '1' then
        rvalid <= '0'; r_pend := false;
      end if;
      if arvalid = '1' and arready = '1' then
        ar_a := araddr;
        if unsigned(ar_a) >= 16#10000# then
          resp := "11"; rd := (others => '0');
        elsif ar_a = SLVERR_ADDR then
          resp := "10"; rd := (others => '0');
        elsif ar_a = CNT_ADDR then
          cnt_reads := cnt_reads + 1;
          resp := "00"; rd := std_logic_vector(to_unsigned(cnt_reads, 32));
        else
          resp := "00"; rd := regs(to_integer(unsigned(ar_a(15 downto 2))));
        end if;
        log_it(1, ar_a, rd, resp);
        r_pend := true;
        rdata <= rd; rresp <= resp;
      end if;
      -- complete a write once both halves are in
      if aw_have and w_have and not b_pend then
        if unsigned(aw_a) >= 16#10000# then
          resp := "11";
        elsif aw_a = SLVERR_ADDR then
          resp := "10";
        else
          resp := "00";
          regs(to_integer(unsigned(aw_a(15 downto 2)))) <= w_d;
        end if;
        log_it(0, aw_a, w_d, resp);
        aw_have := false; w_have := false; b_pend := true;
        bresp <= resp;
      end if;
      -- responses, possibly delayed
      if b_pend and bvalid = '0' and rnd = '0' then
        bvalid <= '1';
      end if;
      if r_pend and rvalid = '0' and rnd = '0' then
        rvalid <= '1';
      end if;
      -- readies for the next edge: one outstanding transaction per channel
      if not aw_have and not b_pend and awvalid = '1' and awready = '0' and rnd = '0' then
        aw_rdy := '1';
      end if;
      if not w_have and not b_pend and wvalid = '1' and wready = '0' and rnd = '0' then
        w_rdy := '1';
      end if;
      if not r_pend and arvalid = '1' and arready = '0' and rnd = '0' then
        ar_rdy := '1';
      end if;
      awready <= aw_rdy; wready <= w_rdy; arready <= ar_rdy;

      p_awv := awvalid; p_awa := awaddr; p_awr := awready;
      p_wv := wvalid;   p_wd := wdata;   p_wr := wready;
      p_arv := arvalid; p_ara := araddr; p_arr := arready;
      nlog <= n;
      nerr <= e;
    end if;
  end process;
end architecture;
