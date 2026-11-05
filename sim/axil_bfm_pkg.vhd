-- sim/axil_bfm_pkg.vhd -- AXI4-Lite master procedures for GHDL benches (plan
-- 2026-11-04-jc-on-fabric-loop-and-link, Task 1). VALID is raised without waiting
-- for READY, as AXI requires; a slave that never answers fails the bench.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package axil_bfm_pkg is
  type axil_m2s_t is record
    awaddr  : std_logic_vector(31 downto 0);
    awvalid : std_logic;
    wdata   : std_logic_vector(31 downto 0);
    wstrb   : std_logic_vector(3 downto 0);
    wvalid  : std_logic;
    bready  : std_logic;
    araddr  : std_logic_vector(31 downto 0);
    arvalid : std_logic;
    rready  : std_logic;
  end record;
  type axil_s2m_t is record
    awready : std_logic;
    wready  : std_logic;
    bresp   : std_logic_vector(1 downto 0);
    bvalid  : std_logic;
    arready : std_logic;
    rdata   : std_logic_vector(31 downto 0);
    rresp   : std_logic_vector(1 downto 0);
    rvalid  : std_logic;
  end record;
  constant AXIL_M2S_IDLE : axil_m2s_t :=
    (awaddr => (others => '0'), awvalid => '0', wdata => (others => '0'), wstrb => "1111",
     wvalid => '0', bready => '0', araddr => (others => '0'), arvalid => '0', rready => '0');
  constant AXIL_TMO : natural := 200000;

  function u32(n : natural) return std_logic_vector;
  function s32(n : integer) return std_logic_vector;
  procedure axil_wr(signal clk : in std_logic; signal m : out axil_m2s_t;
                    signal s : in axil_s2m_t; addr : in natural;
                    data : in std_logic_vector(31 downto 0);
                    resp : out std_logic_vector(1 downto 0); w_delay : in natural := 0);
  procedure axil_rd(signal clk : in std_logic; signal m : out axil_m2s_t;
                    signal s : in axil_s2m_t; addr : in natural;
                    data : out std_logic_vector(31 downto 0);
                    resp : out std_logic_vector(1 downto 0));
end package;

package body axil_bfm_pkg is
  function u32(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n, 32));
  end function;

  function s32(n : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(n, 32));
  end function;

  procedure axil_wr(signal clk : in std_logic; signal m : out axil_m2s_t;
                    signal s : in axil_s2m_t; addr : in natural;
                    data : in std_logic_vector(31 downto 0);
                    resp : out std_logic_vector(1 downto 0); w_delay : in natural := 0) is
    variable v : axil_m2s_t := AXIL_M2S_IDLE;
    variable aw_done, w_done : boolean := false;
    variable n : natural := 0;
  begin
    v.awaddr := u32(addr); v.awvalid := '1';
    v.wdata := data; v.wstrb := "1111";
    if w_delay = 0 then v.wvalid := '1'; end if;
    v.bready := '1';
    m <= v;
    loop
      wait until rising_edge(clk);
      if v.awvalid = '1' and s.awready = '1' then aw_done := true; v.awvalid := '0'; end if;
      if v.wvalid = '1' and s.wready = '1' then w_done := true; v.wvalid := '0'; end if;
      if s.bvalid = '1' then
        resp := s.bresp;
        assert aw_done and w_done report "axil_wr: B before AW and W" severity error;
        exit;
      end if;
      n := n + 1;
      if not w_done and v.wvalid = '0' and n >= w_delay then v.wvalid := '1'; end if;
      assert n < AXIL_TMO report "axil_wr: no response at " & integer'image(addr) severity failure;
      m <= v;
    end loop;
    m <= AXIL_M2S_IDLE;
  end procedure;

  procedure axil_rd(signal clk : in std_logic; signal m : out axil_m2s_t;
                    signal s : in axil_s2m_t; addr : in natural;
                    data : out std_logic_vector(31 downto 0);
                    resp : out std_logic_vector(1 downto 0)) is
    variable v : axil_m2s_t := AXIL_M2S_IDLE;
    variable n : natural := 0;
  begin
    v.araddr := u32(addr); v.arvalid := '1'; v.rready := '1';
    m <= v;
    loop
      wait until rising_edge(clk);
      if v.arvalid = '1' and s.arready = '1' then v.arvalid := '0'; end if;
      if s.rvalid = '1' then
        data := s.rdata; resp := s.rresp;
        exit;
      end if;
      n := n + 1;
      assert n < AXIL_TMO report "axil_rd: no response at " & integer'image(addr) severity failure;
      m <= v;
    end loop;
    m <= AXIL_M2S_IDLE;
  end procedure;
end package body;
