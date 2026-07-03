-- rtl/mac_axi.vhd  — AXI4-Lite MAC accelerator wrapping mac_array.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;
entity mac_axi is
  generic(N:positive:=64; P:positive:=8; WW:positive:=16; XW:positive:=16; AW:positive:=48;
          C_S_AXI_DATA_WIDTH:integer:=32; C_S_AXI_ADDR_WIDTH:integer:=8);
  port(
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;
    s_axi_awaddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_awprot  : in  std_logic_vector(2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    s_axi_wstrb   : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_arprot  : in  std_logic_vector(2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic);
end;
architecture rtl of mac_axi is
  signal awready,wready,bvalid,arready,rvalid : std_logic := '0';
  signal rdata_r : std_logic_vector(31 downto 0) := (others=>'0');
  -- stores
  type i16arr is array(0 to N-1) of signed(15 downto 0);
  signal act_store, w_store : i16arr := (others=>(others=>'0'));
  signal load_idx : integer range 0 to N-1 := 0;
  signal n_reg : std_logic_vector(31 downto 0) := (others=>'0');
  -- mac control
  signal start_pulse, busy, mac_done : std_logic := '0';
  signal status_done : std_logic := '0';
  signal acc : std_logic_vector(AW-1 downto 0);
  -- packed vectors
  signal x_vec : std_logic_vector(N*XW-1 downto 0);
  signal w_row : std_logic_vector(N*WW-1 downto 0);
  signal wr_addr : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
begin
  s_axi_awready<=awready; s_axi_wready<=wready; s_axi_bvalid<=bvalid; s_axi_bresp<="00";
  s_axi_arready<=arready; s_axi_rvalid<=rvalid; s_axi_rresp<="00"; s_axi_rdata<=rdata_r;

  -- pack stores into mac_array ports
  gpack: for i in 0 to N-1 generate
    x_vec((i+1)*XW-1 downto i*XW) <= std_logic_vector(act_store(i));
    w_row((i+1)*WW-1 downto i*WW) <= std_logic_vector(w_store(i));
  end generate;

  uut: entity work.mac_array
    generic map(N=>N, P=>P, WW=>WW, XW=>XW, AW=>AW)
    port map(clk=>s_axi_aclk, rst=>not s_axi_aresetn, start=>start_pulse,
             x_vec=>x_vec, w_row=>w_row, done=>mac_done, acc=>acc);

  -- AXI write channel
  process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      start_pulse <= '0';
      if s_axi_aresetn='0' then
        awready<='0'; wready<='0'; bvalid<='0'; busy<='0';
      else
        -- address/data accept (both valid)
        if awready='0' and s_axi_awvalid='1' and s_axi_wvalid='1' then
          awready<='1'; wready<='1'; wr_addr<=s_axi_awaddr;
        else awready<='0'; wready<='0'; end if;
        -- perform the write on the accept cycle
        if awready='1' and wready='1' then
          case to_integer(unsigned(wr_addr(7 downto 2))) is
            when 0 => if s_axi_wdata(0)='1' then start_pulse<='1'; busy<='1'; end if;   -- CTRL START
            when 2 => n_reg <= s_axi_wdata;                                            -- N (reserved)
            when 3 => load_idx <= to_integer(unsigned(s_axi_wdata(clog2(N)-1 downto 0)));-- LOAD_IDX
            when 4 => act_store(load_idx) <= signed(s_axi_wdata(15 downto 0));          -- LOAD_ACT
            when 5 => w_store(load_idx)   <= signed(s_axi_wdata(15 downto 0));          -- LOAD_W
            when others => null;
          end case;
          bvalid<='1';
        elsif bvalid='1' and s_axi_bready='1' then
          bvalid<='0';
        end if;
        -- MAC completion tracking
        if start_pulse='1' then busy<='1'; end if;
        if mac_done='1' then busy<='0'; end if;
      end if;
    end if;
  end process;

  -- latch DONE (set on mac_done, cleared on START)
  process(s_axi_aclk)
    variable done_l : std_logic := '0';
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn='0' then done_l:='0';
      else
        if start_pulse='1' then done_l:='0';
        elsif mac_done='1' then done_l:='1'; end if;
      end if;
      status_done <= done_l;
    end if;
  end process;

  -- AXI read channel
  process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn='0' then arready<='0'; rvalid<='0';
      else
        if arready='0' and s_axi_arvalid='1' then
          arready<='1';
          case to_integer(unsigned(s_axi_araddr(7 downto 2))) is
            when 1 => rdata_r <= (31 downto 2 => '0') & busy & status_done;    -- STATUS
            when 2 => rdata_r <= n_reg;
            when 3 => rdata_r <= std_logic_vector(to_unsigned(load_idx,32));
            when 6 => rdata_r <= acc(31 downto 0);                             -- RESULT_LO
            when 7 => rdata_r <= std_logic_vector(resize(signed(acc(AW-1 downto 32)), 32)); -- RESULT_HI
            when 8 => rdata_r <= x"6D414331";                                  -- ID
            when others => rdata_r <= (others=>'0');
          end case;
        else arready<='0'; end if;
        if arready='1' then rvalid<='1';
        elsif rvalid='1' and s_axi_rready='1' then rvalid<='0'; end if;
      end if;
    end if;
  end process;
end;
