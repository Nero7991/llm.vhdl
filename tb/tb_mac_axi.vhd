-- tb/tb_mac_axi.vhd
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_mac_axi is end;
architecture sim of tb_mac_axi is
  constant AW_ADDR : integer := 8;
  signal clk : std_logic := '0';
  signal rstn : std_logic := '0';
  -- AXI-Lite signals
  signal awaddr : std_logic_vector(AW_ADDR-1 downto 0) := (others=>'0');
  signal awvalid, awready : std_logic := '0';
  signal wdata : std_logic_vector(31 downto 0) := (others=>'0');
  signal wstrb : std_logic_vector(3 downto 0) := "1111";
  signal wvalid, wready : std_logic := '0';
  signal bresp : std_logic_vector(1 downto 0); signal bvalid : std_logic; signal bready : std_logic := '0';
  signal araddr : std_logic_vector(AW_ADDR-1 downto 0) := (others=>'0');
  signal arvalid, arready : std_logic := '0';
  signal rdata : std_logic_vector(31 downto 0); signal rresp : std_logic_vector(1 downto 0);
  signal rvalid : std_logic; signal rready : std_logic := '0';
  constant N : integer := 64;
  type ivec is array(0 to N-1) of integer;
begin
  clk <= not clk after 5 ns;
  uut: entity work.mac_axi
    generic map(N=>N, P=>8, WW=>16, XW=>16, AW=>48)
    port map(s_axi_aclk=>clk, s_axi_aresetn=>rstn,
      s_axi_awaddr=>awaddr, s_axi_awprot=>"000", s_axi_awvalid=>awvalid, s_axi_awready=>awready,
      s_axi_wdata=>wdata, s_axi_wstrb=>wstrb, s_axi_wvalid=>wvalid, s_axi_wready=>wready,
      s_axi_bresp=>bresp, s_axi_bvalid=>bvalid, s_axi_bready=>bready,
      s_axi_araddr=>araddr, s_axi_arprot=>"000", s_axi_arvalid=>arvalid, s_axi_arready=>arready,
      s_axi_rdata=>rdata, s_axi_rresp=>rresp, s_axi_rvalid=>rvalid, s_axi_rready=>rready);

  process
    procedure axi_write(addr : integer; data : integer) is
    begin
      awaddr <= std_logic_vector(to_unsigned(addr, AW_ADDR));
      wdata  <= std_logic_vector(to_signed(data, 32));
      awvalid <= '1'; wvalid <= '1'; bready <= '1';
      wait until rising_edge(clk) and awready='1' and wready='1';
      awvalid <= '0'; wvalid <= '0';
      wait until rising_edge(clk) and bvalid='1';
      bready <= '0'; wait until rising_edge(clk);
    end procedure;
    procedure axi_read(addr : integer; result : out std_logic_vector(31 downto 0)) is
    begin
      araddr <= std_logic_vector(to_unsigned(addr, AW_ADDR));
      arvalid <= '1'; rready <= '1';
      wait until rising_edge(clk) and arready='1';
      arvalid <= '0';
      wait until rising_edge(clk) and rvalid='1';
      result := rdata; rready <= '0'; wait until rising_edge(clk);
    end procedure;
    variable act, w : ivec;
    variable rd : std_logic_vector(31 downto 0);
    variable expect : integer;
    variable acc_lo, acc_hi : std_logic_vector(31 downto 0);
    variable acc : signed(47 downto 0);
  begin
    -- reset
    rstn <= '0'; wait for 40 ns; wait until rising_edge(clk); rstn <= '1'; wait until rising_edge(clk);
    -- ID sanity
    axi_read(16#20#, rd);
    assert rd = x"6D414331" report "ID mismatch got "&integer'image(to_integer(unsigned(rd))) severity failure;
    -- build a known vector (mix of signs), compute expected
    expect := 0;
    for i in 0 to N-1 loop
      act(i) := (i mod 7) - 3;            -- -3..3 (signed)
      w(i)   := (i mod 5) + 1;            -- 1..5 (positive, keeps the sum from cancelling to 0)
      expect := expect + act(i)*w(i);
    end loop;
    -- Guard: a zero expected sum would let a stuck-at-0 datapath pass. Make the
    -- gate meaningful by requiring a non-zero golden value.
    assert expect /= 0 report "test vector sums to 0 - weak gate, change the vector" severity failure;
    -- load
    axi_write(16#08#, N);                 -- N (reserved)
    for i in 0 to N-1 loop
      axi_write(16#0C#, i);               -- LOAD_IDX
      axi_write(16#10#, act(i));          -- LOAD_ACT
      axi_write(16#14#, w(i));            -- LOAD_W
    end loop;
    -- start + poll DONE
    axi_write(16#00#, 1);                 -- CTRL START
    loop
      axi_read(16#04#, rd);               -- STATUS
      exit when rd(0) = '1';
    end loop;
    -- read result
    axi_read(16#18#, acc_lo); axi_read(16#1C#, acc_hi);
    acc := signed(acc_hi(15 downto 0) & acc_lo);
    assert to_integer(acc) = expect
      report "MAC mismatch got "&integer'image(to_integer(acc))&" expect "&integer'image(expect) severity failure;
    report "PASS:mac_axi  acc="&integer'image(to_integer(acc)) severity note;
    std.env.finish;
  end process;
end;
