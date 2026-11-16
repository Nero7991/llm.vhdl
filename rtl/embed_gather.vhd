-- rtl/embed_gather.vhd -- one embedding row from the packed .mv4i table in HBM, dequantized
-- and BFP-packed exactly as server/embed_mv4i.c's pl_embed_mv4i (recipe wide). Plan
-- 2026-11-04 Task 3; the layout read is the plan's (whole file at EMB_BASE). AXI3: 16-beat
-- bursts, 32-byte beats, 512-byte aligned (no 4 KB crossing).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity embed_gather is
  generic(N_EMBD : positive := 4096; ADDR_W : positive := 33);
  port(
    clk, rst      : in  std_logic;
    emb_base      : in  unsigned(ADDR_W-1 downto 0);
    invalidate    : in  std_logic;
    req           : in  std_logic;
    tok           : in  unsigned(31 downto 0);
    exp_valid     : out std_logic;
    exp_val       : out std_logic_vector(31 downto 0);
    err           : out std_logic;
    err_code      : out std_logic_vector(3 downto 0);
    m_valid       : out std_logic;
    m_data        : out std_logic_vector(15 downto 0);
    m_ready       : in  std_logic;
    m_axi_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m_axi_arlen   : out std_logic_vector(7 downto 0);
    m_axi_arsize  : out std_logic_vector(2 downto 0);
    m_axi_arburst : out std_logic_vector(1 downto 0);
    m_axi_arvalid : out std_logic;
    m_axi_arready : in  std_logic;
    m_axi_rdata   : in  std_logic_vector(255 downto 0);
    m_axi_rresp   : in  std_logic_vector(1 downto 0);
    m_axi_rlast   : in  std_logic;
    m_axi_rvalid  : in  std_logic;
    m_axi_rready  : out std_logic);
end entity;

architecture rtl of embed_gather is
  constant NB   : natural := N_EMBD / 32;
  constant NBUR : natural := NB / 16;
  constant ROWB : natural := NB * 32;
  constant CHK  : natural range 0 to 0 := N_EMBD mod 512;    -- whole 16-beat bursts
  constant MAGIC : std_logic_vector(31 downto 0) := x"4D563449";
  type hdr_t is array (0 to 8) of std_logic_vector(255 downto 0);
  type off_t is array (0 to 26) of unsigned(32 downto 0);
  type cb_t  is array (0 to 15) of signed(7 downto 0);
  type sc_t  is array (0 to NB-1) of std_logic_vector(15 downto 0);
  type wb_t  is array (0 to NB-1) of std_logic_vector(127 downto 0);
  type val_t is array (0 to N_EMBD-1) of std_logic_vector(24 downto 0);
  type gs_t is (G_IDLE, G_HAR, G_HR, G_HCHK, G_DIV, G_ADDR, G_AR, G_R, G_DEQ, G_EXP,
                G_EM1, G_EM2, G_EMIT, G_ERR);
  signal gs : gs_t := G_IDLE;
  signal hdr : hdr_t := (others => (others => '0'));
  signal offs : off_t := (others => (others => '0'));
  signal cb : cb_t := (others => (others => '0'));
  signal sc : sc_t;
  signal wb : wb_t;
  signal vals : val_t;
  signal m_cnt : unsigned(31 downto 0) := (others => '0');
  signal w_exp : signed(31 downto 0) := (others => '0');
  signal hdr_ok, rerr, phase_w, va : std_logic := '0';
  signal tok_r : unsigned(17 downto 0) := (others => '0');
  signal tok32 : unsigned(31 downto 0) := (others => '0');
  signal q_r : unsigned(17 downto 0) := (others => '0');
  signal rem_r : unsigned(5 downto 0) := (others => '0');
  signal dbit : natural range 0 to 17 := 17;
  signal half : natural range 0 to 1 := 0;
  signal kk : natural range 0 to 15 := 0;
  signal w_addr, s_addr : unsigned(32 downto 0) := (others => '0');
  signal bur : natural range 0 to 63 := 0;
  signal bi : natural range 0 to 15 := 0;
  signal hcnt : natural range 0 to 8 := 0;
  signal ea, eb, ee : natural range 0 to N_EMBD := 0;
  signal ja : natural range 0 to 31 := 0;
  signal wq : std_logic_vector(127 downto 0) := (others => '0');
  signal scq : std_logic_vector(15 downto 0) := (others => '0');
  signal amax : unsigned(24 downto 0) := (others => '0');
  signal sh_r : integer range -14 to 10 := 0;
  signal vq : std_logic_vector(24 downto 0) := (others => '0');
  signal araddr_r : unsigned(32 downto 0) := (others => '0');
  signal arlen_r : std_logic_vector(7 downto 0) := (others => '0');
  signal arv : std_logic := '0';

  impure function hb(i : natural) return std_logic_vector is
  begin
    return hdr(i / 32)(8 * (i mod 32) + 7 downto 8 * (i mod 32));
  end function;
  impure function h16(i : natural) return unsigned is
    variable v : std_logic_vector(15 downto 0);
  begin
    v := hb(i + 1) & hb(i);
    return unsigned(v);
  end function;
  impure function h32(i : natural) return unsigned is
    variable v : std_logic_vector(31 downto 0);
  begin
    v := hb(i + 3) & hb(i + 2) & hb(i + 1) & hb(i);
    return unsigned(v);
  end function;
  function abs_u(v : signed(24 downto 0)) return unsigned is
  begin
    return unsigned(abs(v));
  end function;
begin
  m_axi_araddr  <= std_logic_vector(araddr_r(ADDR_W-1 downto 0));
  m_axi_arlen   <= arlen_r;
  m_axi_arsize  <= "101";
  m_axi_arburst <= "01";
  m_axi_arvalid <= arv;
  m_axi_rready  <= '1' when gs = G_HR or gs = G_R else '0';

  process(clk)
    variable ok : boolean;
    variable o : natural;
    variable r : unsigned(6 downto 0);
    variable rr : natural range 0 to 47;
    variable b : natural range 0 to NB - 1;
    variable byte : std_logic_vector(7 downto 0);
    variable nib : std_logic_vector(3 downto 0);
    variable prod : signed(24 downto 0);
    variable a : unsigned(24 downto 0);
    variable msb : natural range 0 to 24;
    variable t26, m26 : signed(25 downto 0);
  begin
    if rising_edge(clk) then
      if invalidate = '1' then hdr_ok <= '0'; end if;
      if rst = '1' then
        gs <= G_IDLE; arv <= '0'; exp_valid <= '0'; m_valid <= '0'; err <= '0'; hdr_ok <= '0';
      else
        case gs is
          when G_IDLE =>
            if req = '1' then
              err <= '0'; err_code <= "0000"; rerr <= '0';
              tok_r <= tok(17 downto 0); tok32 <= tok;
              if hdr_ok = '0' or invalidate = '1' then
                if emb_base(11 downto 0) /= 0 then
                  err_code <= "0001"; gs <= G_ERR;
                else
                  araddr_r <= resize(emb_base, 33); arlen_r <= x"08"; arv <= '1'; hcnt <= 0; gs <= G_HAR;
                end if;
              elsif tok >= m_cnt then
                err_code <= "0010"; gs <= G_ERR;
              else
                rem_r <= (others => '0'); dbit <= 17; gs <= G_DIV;
              end if;
            end if;
          when G_HAR =>
            if m_axi_arready = '1' then arv <= '0'; gs <= G_HR; end if;
          when G_HR =>
            if m_axi_rvalid = '1' then
              hdr(hcnt) <= m_axi_rdata;
              if m_axi_rresp /= "00" then rerr <= '1'; end if;
              if m_axi_rlast = '1' then gs <= G_HCHK; else hcnt <= hcnt + 1; end if;
            end if;
          when G_HCHK =>
            ok := rerr = '0' and h32(0) = unsigned(MAGIC) and h32(16#0C#) = N_EMBD
                  and h16(16#18#) = 48 and h16(16#1A#) = 24 and h16(16#1C#) = 32
                  and h16(16#1E#) = 256 and h32(16#34#) = 3
                  and h32(16#08#) /= 0 and h32(16#08#) < 262144;
            for k in 0 to 26 loop
              o := 16#38# + 8 * k;
              ok := ok and h32(o + 4)(31 downto 1) = 0 and h32(o)(8 downto 0) = 0;
              offs(k) <= h32(o + 4)(0) & h32(o);
            end loop;
            for k in 0 to 15 loop cb(k) <= signed(hb(16#20# + k)); end loop;
            m_cnt <= h32(16#08#);
            w_exp <= signed(h32(16#10#));
            if not ok then
              err_code <= "0001"; gs <= G_ERR;
            elsif tok32 >= h32(16#08#) then
              hdr_ok <= '1'; err_code <= "0010"; gs <= G_ERR;
            else
              hdr_ok <= '1'; rem_r <= (others => '0'); dbit <= 17; gs <= G_DIV;
            end if;
          when G_DIV =>                                  -- tok / 48, MSB first
            r := rem_r & tok_r(dbit);
            if r >= 48 then r := r - 48; q_r(dbit) <= '1'; else q_r(dbit) <= '0'; end if;
            rem_r <= r(5 downto 0);
            if dbit = 0 then gs <= G_ADDR; else dbit <= dbit - 1; end if;
          when G_ADDR =>
            rr := to_integer(rem_r);
            half <= rr mod 2; kk <= rr mod 16;
            w_addr <= resize(emb_base, 33) + offs(rr / 2) + resize(q_r * to_unsigned(ROWB, 15), 33);
            s_addr <= resize(emb_base, 33) + offs(24 + rr / 16) + resize(q_r * to_unsigned(ROWB, 15), 33);
            phase_w <= '0'; bur <= 0; gs <= G_AR;
          when G_AR =>
            if arv = '0' then
              if phase_w = '0' then araddr_r <= s_addr + to_unsigned(bur * 512, 33);
              else araddr_r <= w_addr + to_unsigned(bur * 512, 33); end if;
              arlen_r <= x"0F"; arv <= '1';
            elsif m_axi_arready = '1' then
              arv <= '0'; bi <= 0; gs <= G_R;
            end if;
          when G_R =>
            if m_axi_rvalid = '1' then
              b := bur * 16 + bi;
              if m_axi_rresp /= "00" then rerr <= '1'; end if;
              if phase_w = '0' then sc(b) <= m_axi_rdata(16 * kk + 15 downto 16 * kk);
              else wb(b) <= m_axi_rdata(128 * half + 127 downto 128 * half); end if;
              if m_axi_rlast = '1' then
                if bur = NBUR - 1 then
                  if phase_w = '0' then
                    phase_w <= '1'; bur <= 0; gs <= G_AR;
                  elsif rerr = '1' or m_axi_rresp /= "00" then
                    err_code <= "0011"; gs <= G_ERR;
                  else
                    ea <= 0; eb <= 0; va <= '0'; amax <= (others => '0'); gs <= G_DEQ;
                  end if;
                else
                  bur <= bur + 1; gs <= G_AR;
                end if;
              else
                bi <= bi + 1;
              end if;
            end if;
          when G_DEQ =>                                   -- one element per cycle, two stages
            if ea < N_EMBD then
              wq <= wb(ea / 32); scq <= sc(ea / 32); ja <= ea mod 32; va <= '1'; ea <= ea + 1;
            else
              va <= '0';
            end if;
            if va = '1' then
              byte := wq(8 * (ja / 2) + 7 downto 8 * (ja / 2));
              if ja mod 2 = 1 then nib := byte(7 downto 4); else nib := byte(3 downto 0); end if;
              prod := resize(cb(to_integer(unsigned(nib))) * signed('0' & scq), 25);
              vals(eb) <= std_logic_vector(prod);
              a := abs_u(prod);
              if a > amax then amax <= a; end if;
              if eb = N_EMBD - 1 then gs <= G_EXP; else eb <= eb + 1; end if;
            end if;
          when G_EXP =>
            msb := 0;
            for k in 24 downto 0 loop
              if amax(k) = '1' then msb := k; exit; end if;
            end loop;
            sh_r <= msb - 14;
            if amax = 0 then exp_val <= std_logic_vector(w_exp + 15);
            else exp_val <= std_logic_vector(w_exp + 15 - (msb - 14)); end if;
            exp_valid <= '1'; ee <= 0; gs <= G_EM1;
          when G_EM1 =>
            vq <= vals(ee); gs <= G_EM2;
          when G_EM2 =>
            if sh_r > 0 then
              t26 := resize(signed(vq), 26) + shift_left(to_signed(1, 26), sh_r - 1);
              m26 := shift_right(t26, sh_r);
            elsif sh_r < 0 then
              m26 := shift_left(resize(signed(vq), 26), -sh_r);
            else
              m26 := resize(signed(vq), 26);
            end if;
            if m26 > 32767 then m_data <= x"7FFF";
            elsif m26 < -32768 then m_data <= x"8000";
            else m_data <= std_logic_vector(m26(15 downto 0)); end if;
            m_valid <= '1'; gs <= G_EMIT;
          when G_EMIT =>
            if m_ready = '1' then
              m_valid <= '0';
              if ee = N_EMBD - 1 then exp_valid <= '0'; gs <= G_IDLE;
              else ee <= ee + 1; gs <= G_EM1; end if;
            end if;
          when G_ERR =>
            err <= '1'; gs <= G_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
