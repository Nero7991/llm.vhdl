-- AXI3 slave memory for the Jungle Cat loader benches. Holds 2**IDX_W 256-bit words,
-- indexed by address bits [IDX_W+4:5] with the full address stored as a tag, so a
-- bench that aliases two addresses is caught rather than silently passing.
-- Checks every burst against the HBM AXI3 rules and counts violations on `errors`.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jc_axi3_mem is
  generic(ADDR_W : positive := 33; IDX_W : positive := 11; STALL : boolean := true;
          BAD_BRESP_ADDR : std_logic_vector(39 downto 0) := (others => '1'));
  port(
    clk       : in  std_logic;
    awaddr    : in  std_logic_vector(ADDR_W-1 downto 0);
    awlen     : in  std_logic_vector(3 downto 0);
    awsize    : in  std_logic_vector(2 downto 0);
    awburst   : in  std_logic_vector(1 downto 0);
    awvalid   : in  std_logic;
    awready   : out std_logic;
    wdata     : in  std_logic_vector(255 downto 0);
    wstrb     : in  std_logic_vector(31 downto 0);
    wlast     : in  std_logic;
    wvalid    : in  std_logic;
    wready    : out std_logic;
    bresp     : out std_logic_vector(1 downto 0);
    bvalid    : out std_logic;
    bready    : in  std_logic;
    araddr    : in  std_logic_vector(ADDR_W-1 downto 0);
    arlen     : in  std_logic_vector(3 downto 0);
    arsize    : in  std_logic_vector(2 downto 0);
    arburst   : in  std_logic_vector(1 downto 0);
    arvalid   : in  std_logic;
    arready   : out std_logic;
    rdata     : out std_logic_vector(255 downto 0);
    rresp     : out std_logic_vector(1 downto 0);
    rlast     : out std_logic;
    rvalid    : out std_logic := '0';
    rready    : in  std_logic;
    poke_en   : in  std_logic := '0';
    poke_addr : in  std_logic_vector(39 downto 0) := (others => '0');
    poke_data : in  std_logic_vector(255 downto 0) := (others => '0');
    peek_addr : in  std_logic_vector(39 downto 0) := (others => '0');
    peek_data : out std_logic_vector(255 downto 0);
    peek_hit  : out std_logic;
    errors    : out natural
  );
end entity;

architecture sim of jc_axi3_mem is
  constant N : natural := 2 ** IDX_W;
  type mem_t is array (0 to N-1) of std_logic_vector(255 downto 0);
  type tag_t is array (0 to N-1) of std_logic_vector(39 downto 0);
  signal mem  : mem_t := (others => (others => '0'));
  signal tags : tag_t := (others => (others => '1'));       -- all ones = empty
  signal lfsr : std_logic_vector(15 downto 0) := x"ACE1";
  signal nerr : natural := 0;

  function idx(a : std_logic_vector(39 downto 0)) return natural is
  begin
    return to_integer(unsigned(a(IDX_W + 4 downto 5)));
  end function;
  function burst_ok(a : std_logic_vector; len : std_logic_vector(3 downto 0);
                    sz : std_logic_vector(2 downto 0); bt : std_logic_vector(1 downto 0))
    return boolean is
    variable off : natural := to_integer(unsigned(a(11 downto 0)));
  begin
    return sz = "101" and bt = "01" and a(4 downto 0) = "00000"
           and off + (to_integer(unsigned(len)) + 1) * 32 <= 4096;
  end function;
begin
  errors <= nerr;
  peek_data <= mem(idx(peek_addr));
  peek_hit  <= '1' when tags(idx(peek_addr)) = peek_addr else '0';

  process(clk)
    variable wa, ra : std_logic_vector(39 downto 0);
    variable wleft, rleft : integer := -1;
    variable bad_b : boolean;
    variable do_stall : std_logic;
  begin
    if rising_edge(clk) then
      lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      do_stall := '0';
      if STALL then do_stall := lfsr(0) and lfsr(3); end if;

      if poke_en = '1' then
        mem(idx(poke_addr))  <= poke_data;
        tags(idx(poke_addr)) <= poke_addr;
      end if;

      -- write address
      awready <= '0';
      if awvalid = '1' and wleft < 0 and do_stall = '0' then
        awready <= '1';
        wa := std_logic_vector(resize(unsigned(awaddr), 40));
        if not burst_ok(wa, awlen, awsize, awburst) then nerr <= nerr + 1;
          report "AXI3 write burst breaks a rule at " & to_hstring(wa) severity error; end if;
        wleft := to_integer(unsigned(awlen));
        bad_b := wa = BAD_BRESP_ADDR;
      end if;
      -- write data
      wready <= '0';
      if wleft >= 0 and wvalid = '1' and do_stall = '0' then
        wready <= '1';
      end if;
      if wleft >= 0 and wvalid = '1' and wready = '1' then
        if wstrb /= x"FFFFFFFF" then nerr <= nerr + 1;
          report "partial write strobe" severity error; end if;
        if (wleft = 0) /= (wlast = '1') then nerr <= nerr + 1;
          report "WLAST on the wrong beat" severity error; end if;
        if tags(idx(wa)) /= wa and tags(idx(wa)) /= x"FFFFFFFFFF" then nerr <= nerr + 1;
          report "bench address alias at " & to_hstring(wa) severity error; end if;
        mem(idx(wa)) <= wdata; tags(idx(wa)) <= wa;
        wa := std_logic_vector(unsigned(wa) + 32);
        if wleft = 0 then
          bvalid <= '1';
          if bad_b then bresp <= "10"; else bresp <= "00"; end if;
        end if;
        wleft := wleft - 1;
        wready <= '0';
      end if;
      if bvalid = '1' and bready = '1' then bvalid <= '0'; end if;

      -- read address and data
      arready <= '0';
      if arvalid = '1' and rleft < 0 and do_stall = '0' then
        arready <= '1';
        ra := std_logic_vector(resize(unsigned(araddr), 40));
        if not burst_ok(ra, arlen, arsize, arburst) then nerr <= nerr + 1;
          report "AXI3 read burst breaks a rule at " & to_hstring(ra) severity error; end if;
        rleft := to_integer(unsigned(arlen));
      end if;
      if rvalid = '1' and rready = '1' then
        rvalid <= '0';
        ra := std_logic_vector(unsigned(ra) + 32);
        rleft := rleft - 1;
      elsif rleft >= 0 and arready = '0' and (rvalid = '0') and do_stall = '0' then
        rvalid <= '1'; rdata <= mem(idx(ra)); rresp <= "00";
        if rleft = 0 then rlast <= '1'; else rlast <= '0'; end if;
      end if;
    end if;
  end process;
end architecture;
