-- rtl/jc_seam_mux.vhd -- exclusive 2:1 owner switch in front of rtl/fk33_seam.vhd's
-- AXI-Lite slave (spec 2026-11-04 section 1.2). NOT an arbiter: one source owns the
-- seam; the other source's transactions complete here with SLVERR and never reach it.
-- One transaction at a time, store-and-forward, so a write and the read after it keep
-- their order (the WIN_ADDR-then-WIN_DATA pattern depends on it). Ownership follows
-- loop_own only in S_IDLE: it never changes with a transaction in flight.
library ieee;
use ieee.std_logic_1164.all;

entity jc_seam_mux is
  generic(AW : positive := 12);
  port(
    clk          : in  std_logic;
    rst          : in  std_logic;
    loop_own     : in  std_logic;
    owner        : out std_logic;
    host_refused : out std_logic;
    s_h_awaddr   : in  std_logic_vector(AW-1 downto 0);
    s_h_awvalid  : in  std_logic;
    s_h_awready  : out std_logic;
    s_h_wdata    : in  std_logic_vector(31 downto 0);
    s_h_wstrb    : in  std_logic_vector(3 downto 0);
    s_h_wvalid   : in  std_logic;
    s_h_wready   : out std_logic;
    s_h_bresp    : out std_logic_vector(1 downto 0);
    s_h_bvalid   : out std_logic;
    s_h_bready   : in  std_logic;
    s_h_araddr   : in  std_logic_vector(AW-1 downto 0);
    s_h_arvalid  : in  std_logic;
    s_h_arready  : out std_logic;
    s_h_rdata    : out std_logic_vector(31 downto 0);
    s_h_rresp    : out std_logic_vector(1 downto 0);
    s_h_rvalid   : out std_logic;
    s_h_rready   : in  std_logic;
    s_l_awaddr   : in  std_logic_vector(AW-1 downto 0);
    s_l_awvalid  : in  std_logic;
    s_l_awready  : out std_logic;
    s_l_wdata    : in  std_logic_vector(31 downto 0);
    s_l_wstrb    : in  std_logic_vector(3 downto 0);
    s_l_wvalid   : in  std_logic;
    s_l_wready   : out std_logic;
    s_l_bresp    : out std_logic_vector(1 downto 0);
    s_l_bvalid   : out std_logic;
    s_l_bready   : in  std_logic;
    s_l_araddr   : in  std_logic_vector(AW-1 downto 0);
    s_l_arvalid  : in  std_logic;
    s_l_arready  : out std_logic;
    s_l_rdata    : out std_logic_vector(31 downto 0);
    s_l_rresp    : out std_logic_vector(1 downto 0);
    s_l_rvalid   : out std_logic;
    s_l_rready   : in  std_logic;
    m_awaddr     : out std_logic_vector(AW-1 downto 0);
    m_awvalid    : out std_logic;
    m_awready    : in  std_logic;
    m_wdata      : out std_logic_vector(31 downto 0);
    m_wstrb      : out std_logic_vector(3 downto 0);
    m_wvalid     : out std_logic;
    m_wready     : in  std_logic;
    m_bresp      : in  std_logic_vector(1 downto 0);
    m_bvalid     : in  std_logic;
    m_bready     : out std_logic;
    m_araddr     : out std_logic_vector(AW-1 downto 0);
    m_arvalid    : out std_logic;
    m_arready    : in  std_logic;
    m_rdata      : in  std_logic_vector(31 downto 0);
    m_rresp      : in  std_logic_vector(1 downto 0);
    m_rvalid     : in  std_logic;
    m_rready     : out std_logic);
end entity;

architecture rtl of jc_seam_mux is
  type st_t is (S_IDLE, S_MW, S_MB, S_MA, S_MR, S_SB, S_SR);
  signal st     : st_t := S_IDLE;
  signal own    : std_logic := '0';
  signal src    : std_logic := '0';                 -- '0' host, '1' loop
  signal a_r    : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal d_r    : std_logic_vector(31 downto 0) := (others => '0');
  signal s_r    : std_logic_vector(3 downto 0) := (others => '0');
  signal resp_r : std_logic_vector(1 downto 0) := "00";
  signal rd_r   : std_logic_vector(31 downto 0) := (others => '0');
  signal aw_ok, w_ok : std_logic := '0';
  signal hw_go, hr_go, lw_go, lr_go : std_logic;
begin
  -- the one decision, in S_IDLE only: owner's write, owner's read, other's write, other's read
  process(all)
    variable hw, hr, lw, lr : std_logic;
  begin
    hw := s_h_awvalid and s_h_wvalid;  hr := s_h_arvalid;
    lw := s_l_awvalid and s_l_wvalid;  lr := s_l_arvalid;
    hw_go <= '0'; hr_go <= '0'; lw_go <= '0'; lr_go <= '0';
    if st = S_IDLE then
      if own = '1' then
        if lw = '1' then lw_go <= '1';
        elsif lr = '1' then lr_go <= '1';
        elsif hw = '1' then hw_go <= '1';
        elsif hr = '1' then hr_go <= '1';
        end if;
      else
        if hw = '1' then hw_go <= '1';
        elsif hr = '1' then hr_go <= '1';
        elsif lw = '1' then lw_go <= '1';
        elsif lr = '1' then lr_go <= '1';
        end if;
      end if;
    end if;
  end process;

  s_h_awready <= hw_go;  s_h_wready <= hw_go;  s_h_arready <= hr_go;
  s_l_awready <= lw_go;  s_l_wready <= lw_go;  s_l_arready <= lr_go;
  s_h_bvalid <= '1' when st = S_SB and src = '0' else '0';
  s_l_bvalid <= '1' when st = S_SB and src = '1' else '0';
  s_h_rvalid <= '1' when st = S_SR and src = '0' else '0';
  s_l_rvalid <= '1' when st = S_SR and src = '1' else '0';
  s_h_bresp <= resp_r;  s_l_bresp <= resp_r;
  s_h_rresp <= resp_r;  s_l_rresp <= resp_r;
  s_h_rdata <= rd_r;    s_l_rdata <= rd_r;
  m_awaddr  <= a_r;  m_araddr <= a_r;  m_wdata <= d_r;  m_wstrb <= s_r;
  m_awvalid <= '1' when st = S_MW and aw_ok = '0' else '0';
  m_wvalid  <= '1' when st = S_MW and w_ok = '0' else '0';
  m_bready  <= '1' when st = S_MB else '0';
  m_arvalid <= '1' when st = S_MA else '0';
  m_rready  <= '1' when st = S_MR else '0';
  owner <= own;

  process(clk)
    variable refuse : boolean;
  begin
    if rising_edge(clk) then
      host_refused <= '0';
      if rst = '1' then
        st <= S_IDLE; own <= '0'; src <= '0'; aw_ok <= '0'; w_ok <= '0'; resp_r <= "00";
      else
        case st is
          when S_IDLE =>
            own <= loop_own;
            if hw_go = '1' or lw_go = '1' then
              if hw_go = '1' then
                src <= '0'; a_r <= s_h_awaddr; d_r <= s_h_wdata; s_r <= s_h_wstrb;
              else
                src <= '1'; a_r <= s_l_awaddr; d_r <= s_l_wdata; s_r <= s_l_wstrb;
              end if;
              refuse := (hw_go = '1' and own = '1') or (lw_go = '1' and own = '0');
              if refuse then
                resp_r <= "10"; st <= S_SB;
                if hw_go = '1' then host_refused <= '1'; end if;
              else
                aw_ok <= '0'; w_ok <= '0'; st <= S_MW;
              end if;
            elsif hr_go = '1' or lr_go = '1' then
              if hr_go = '1' then src <= '0'; a_r <= s_h_araddr;
              else src <= '1'; a_r <= s_l_araddr; end if;
              refuse := (hr_go = '1' and own = '1') or (lr_go = '1' and own = '0');
              if refuse then
                resp_r <= "10"; rd_r <= (others => '0'); st <= S_SR;
                if hr_go = '1' then host_refused <= '1'; end if;
              else
                st <= S_MA;
              end if;
            end if;
          when S_MW =>
            if (aw_ok = '1' or m_awready = '1') and (w_ok = '1' or m_wready = '1') then
              st <= S_MB;
            end if;
            if m_awready = '1' then aw_ok <= '1'; end if;
            if m_wready = '1' then w_ok <= '1'; end if;
          when S_MB =>
            if m_bvalid = '1' then resp_r <= m_bresp; st <= S_SB; end if;
          when S_MA =>
            if m_arready = '1' then st <= S_MR; end if;
          when S_MR =>
            if m_rvalid = '1' then rd_r <= m_rdata; resp_r <= m_rresp; st <= S_SR; end if;
          when S_SB =>
            if (src = '0' and s_h_bready = '1') or (src = '1' and s_l_bready = '1') then
              st <= S_IDLE;
            end if;
          when S_SR =>
            if (src = '0' and s_h_rready = '1') or (src = '1' and s_l_rready = '1') then
              st <= S_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
