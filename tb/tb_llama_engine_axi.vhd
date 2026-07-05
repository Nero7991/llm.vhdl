-- tb/tb_llama_engine_axi.vhd
-- End-to-end testbench for rtl/llama_engine_axi.vhd (the AXI4-Lite wrapper around
-- engine_shared).  Drives the slave like the PS would: read ID, write CTRL START,
-- poll STATUS until done, read COUNT and the TOKEN[] buffer, and assert the token
-- stream matches mem/golden/fx_tokens_greedy.txt token-for-token (same golden as
-- tb_engine_shared).  PASS proves the AXI plumbing + token capture are correct.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_llama_engine_axi is end;

architecture sim of tb_llama_engine_axi is
  constant N     : integer := 24;   -- NGEN
  constant ADDRW : integer := 8;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal awaddr  : std_logic_vector(ADDRW-1 downto 0) := (others=>'0');
  signal awvalid : std_logic := '0';
  signal awready : std_logic;
  signal wdata   : std_logic_vector(31 downto 0) := (others=>'0');
  signal wstrb   : std_logic_vector(3 downto 0) := "1111";
  signal wvalid  : std_logic := '0';
  signal wready  : std_logic;
  signal bresp   : std_logic_vector(1 downto 0);
  signal bvalid  : std_logic;
  signal bready  : std_logic := '0';
  signal araddr  : std_logic_vector(ADDRW-1 downto 0) := (others=>'0');
  signal arvalid : std_logic := '0';
  signal arready : std_logic;
  signal rdata   : std_logic_vector(31 downto 0);
  signal rresp   : std_logic_vector(1 downto 0);
  signal rvalid  : std_logic;
  signal rready  : std_logic := '0';

  type intarr is array(natural range <>) of integer;
begin
  aclk <= not aclk after 5 ns;

  dut: entity work.llama_engine_axi
    generic map(MAXPOS => 24, NGEN => N, MAXTOK => 32, C_S_AXI_ADDR_WIDTH => ADDRW)
    port map(
      s_axi_aclk=>aclk, s_axi_aresetn=>aresetn,
      s_axi_awaddr=>awaddr, s_axi_awprot=>"000", s_axi_awvalid=>awvalid, s_axi_awready=>awready,
      s_axi_wdata=>wdata, s_axi_wstrb=>wstrb, s_axi_wvalid=>wvalid, s_axi_wready=>wready,
      s_axi_bresp=>bresp, s_axi_bvalid=>bvalid, s_axi_bready=>bready,
      s_axi_araddr=>araddr, s_axi_arprot=>"000", s_axi_arvalid=>arvalid, s_axi_arready=>arready,
      s_axi_rdata=>rdata, s_axi_rresp=>rresp, s_axi_rvalid=>rvalid, s_axi_rready=>rready);

  process
    -- AXI4-Lite single-beat write: address+data accepted together (matches slave).
    procedure axi_write(addr : integer; data : std_logic_vector(31 downto 0)) is
    begin
      awaddr  <= std_logic_vector(to_unsigned(addr, ADDRW));
      wdata   <= data; wstrb <= "1111";
      awvalid <= '1'; wvalid <= '1';
      loop wait until rising_edge(aclk); exit when awready='1' and wready='1'; end loop;
      awvalid <= '0'; wvalid <= '0';
      bready  <= '1';
      loop wait until rising_edge(aclk); exit when bvalid='1'; end loop;
      bready  <= '0';
    end procedure;

    procedure axi_read(addr : integer; res : out std_logic_vector(31 downto 0)) is
    begin
      araddr  <= std_logic_vector(to_unsigned(addr, ADDRW));
      arvalid <= '1';
      loop wait until rising_edge(aclk); exit when arready='1'; end loop;
      arvalid <= '0'; rready <= '1';
      loop wait until rising_edge(aclk); exit when rvalid='1'; end loop;
      res := rdata;
      rready  <= '0';
    end procedure;

    file f_gold : text;
    variable L    : line;
    variable v    : integer;
    variable gold : intarr(0 to N-1);
    variable rd   : std_logic_vector(31 downto 0);
    variable cnt  : integer;
    variable n_matched  : integer := 0;
    variable first_fail : integer := -1;
    variable got : intarr(0 to N-1);
  begin
    file_open(f_gold, "../mem/golden/fx_tokens_greedy.txt", read_mode);
    for i in 0 to N-1 loop readline(f_gold, L); read(L, v); gold(i) := v; end loop;
    file_close(f_gold);

    -- Reset the AXI slave.
    aresetn <= '0';
    for i in 0 to 4 loop wait until rising_edge(aclk); end loop;
    aresetn <= '1';
    for i in 0 to 2 loop wait until rising_edge(aclk); end loop;

    -- ID check.
    axi_read(16#20#, rd);
    assert rd = x"6C6C6D31"
      report "ID mismatch: got " & to_hstring(rd) severity failure;
    report "ID ok = " & to_hstring(rd) severity note;

    -- START.
    axi_write(16#00#, x"00000001");

    -- Poll STATUS.done (bit0) with a coarse interval so we don't do millions of
    -- reads while the engine runs its ~6.5M-cycle generation.
    for tries in 0 to 200000 loop
      axi_read(16#04#, rd);
      exit when rd(0)='1';
      wait for 5 us;
    end loop;
    assert rd(0)='1' report "engine did not finish (STATUS.done never set)" severity failure;

    -- COUNT then the tokens.
    axi_read(16#08#, rd);
    cnt := to_integer(unsigned(rd));
    assert cnt = N
      report "COUNT=" & integer'image(cnt) & " expected " & integer'image(N) severity failure;

    for i in 0 to N-1 loop
      axi_read(16#40# + 4*i, rd);
      got(i) := to_integer(signed(rd));
    end loop;

    for p in 0 to N-1 loop
      if got(p) = gold(p) then n_matched := n_matched + 1;
      else
        if first_fail = -1 then first_fail := p; end if;
        report "MISMATCH pos=" & integer'image(p) & " got=" & integer'image(got(p)) &
               " expected=" & integer'image(gold(p)) severity error;
      end if;
    end loop;

    if first_fail = -1 then
      report "PASS:llama_engine_axi " & integer'image(n_matched) & "/" & integer'image(N) &
             " tokens match" severity note;
    else
      report "FAIL:llama_engine_axi " & integer'image(n_matched) & "/" & integer'image(N) &
             " tokens; first mismatch pos=" & integer'image(first_fail) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
