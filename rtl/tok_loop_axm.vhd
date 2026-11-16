-- rtl/tok_loop_axm.vhd -- one AXI-Lite transaction at a time for tok_loop_fsm, with a
-- timeout (plan D6: the seam itself never answers SLVERR, so a hung slave is the case to
-- catch). A timeout ends the transaction with resp "11" and timed_out; the bus may then be
-- inconsistent, and the loop stops with SEAM_ERR (recovery is a reset).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tok_loop_axm is
  generic(AW : positive := 12);
  port(
    clk, rst  : in  std_logic;
    req       : in  std_logic;
    req_wr    : in  std_logic;
    req_addr  : in  unsigned(AW-1 downto 0);
    req_data  : in  std_logic_vector(31 downto 0);
    tmo_cyc   : in  unsigned(31 downto 0);
    done      : out std_logic;
    rdata     : out std_logic_vector(31 downto 0);
    resp      : out std_logic_vector(1 downto 0);
    timed_out : out std_logic;
    m_awaddr  : out std_logic_vector(AW-1 downto 0);
    m_awvalid : out std_logic;
    m_awready : in  std_logic;
    m_wdata   : out std_logic_vector(31 downto 0);
    m_wstrb   : out std_logic_vector(3 downto 0);
    m_wvalid  : out std_logic;
    m_wready  : in  std_logic;
    m_bresp   : in  std_logic_vector(1 downto 0);
    m_bvalid  : in  std_logic;
    m_bready  : out std_logic;
    m_araddr  : out std_logic_vector(AW-1 downto 0);
    m_arvalid : out std_logic;
    m_arready : in  std_logic;
    m_rdata   : in  std_logic_vector(31 downto 0);
    m_rresp   : in  std_logic_vector(1 downto 0);
    m_rvalid  : in  std_logic;
    m_rready  : out std_logic);
end entity;

architecture rtl of tok_loop_axm is
  type as_t is (A_IDLE, A_W, A_B, A_AR, A_R);
  signal s : as_t := A_IDLE;
  signal addr_r : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal d_r : std_logic_vector(31 downto 0) := (others => '0');
  signal aw_ok, w_ok : std_logic := '0';
  signal cnt : unsigned(31 downto 0) := (others => '0');
begin
  m_awaddr <= addr_r;  m_araddr <= addr_r;  m_wdata <= d_r;  m_wstrb <= "1111";
  m_awvalid <= '1' when s = A_W and aw_ok = '0' else '0';
  m_wvalid  <= '1' when s = A_W and w_ok = '0' else '0';
  m_bready  <= '1' when s = A_B else '0';
  m_arvalid <= '1' when s = A_AR else '0';
  m_rready  <= '1' when s = A_R else '0';

  process(clk)
  begin
    if rising_edge(clk) then
      done <= '0'; timed_out <= '0';
      if rst = '1' then
        s <= A_IDLE; aw_ok <= '0'; w_ok <= '0'; cnt <= (others => '0');
        resp <= "00"; rdata <= (others => '0');
      else
        if s /= A_IDLE then cnt <= cnt + 1; end if;
        case s is
          when A_IDLE =>
            cnt <= (others => '0');
            if req = '1' then
              addr_r <= std_logic_vector(req_addr); d_r <= req_data; aw_ok <= '0'; w_ok <= '0';
              if req_wr = '1' then s <= A_W; else s <= A_AR; end if;
            end if;
          when A_W =>
            if m_awready = '1' then aw_ok <= '1'; end if;
            if m_wready = '1' then w_ok <= '1'; end if;
            if (aw_ok = '1' or m_awready = '1') and (w_ok = '1' or m_wready = '1') then s <= A_B; end if;
          when A_B =>
            if m_bvalid = '1' then resp <= m_bresp; rdata <= (others => '0'); done <= '1'; s <= A_IDLE; end if;
          when A_AR =>
            if m_arready = '1' then s <= A_R; end if;
          when A_R =>
            if m_rvalid = '1' then resp <= m_rresp; rdata <= m_rdata; done <= '1'; s <= A_IDLE; end if;
        end case;
        if s /= A_IDLE and cnt >= tmo_cyc then
          resp <= "11"; done <= '1'; timed_out <= '1'; s <= A_IDLE;
        end if;
      end if;
    end if;
  end process;
end architecture;
