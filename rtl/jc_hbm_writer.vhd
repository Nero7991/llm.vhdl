-- Jungle Cat loader: 200 MHz HBM writer. Spec S4.3; plan rulings 4 and 6.
-- Buffers one frame, commits it only on a PASS verdict with the expected seq, then
-- writes it in AXI3 bursts of at most 16 beats that never cross 4 KB.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;

entity jc_hbm_writer is
  generic(ADDR_W : positive := 33);
  port(
    clk, rst  : in  std_logic;
    q_valid   : in  std_logic;
    q_data    : in  std_logic_vector(JC_FIFO_W-1 downto 0);
    q_ready   : out std_logic;
    awaddr    : out std_logic_vector(ADDR_W-1 downto 0);
    awlen     : out std_logic_vector(3 downto 0);
    awsize    : out std_logic_vector(2 downto 0);
    awburst   : out std_logic_vector(1 downto 0);
    awvalid   : out std_logic;
    awready   : in  std_logic;
    wdata     : out std_logic_vector(255 downto 0);
    wstrb     : out std_logic_vector(31 downto 0);
    wlast     : out std_logic;
    wvalid    : out std_logic;
    wready    : in  std_logic;
    bresp     : in  std_logic_vector(1 downto 0);
    bvalid    : in  std_logic;
    bready    : out std_logic;
    crc_req   : out std_logic;
    crc_addr  : out std_logic_vector(ADDR_W-1 downto 0);
    crc_len   : out unsigned(39 downto 0);
    crc_seq   : out std_logic_vector(31 downto 0);
    crc_busy  : in  std_logic;
    last_seq  : out std_logic_vector(31 downto 0);
    committed : out unsigned(31 downto 0);
    crc_fail  : out unsigned(15 downto 0);
    seq_err   : out unsigned(15 downto 0);
    dup_cnt   : out unsigned(15 downto 0);
    bresp_err : out unsigned(15 downto 0);
    busy      : out std_logic
  );
end entity;

architecture rtl of jc_hbm_writer is
  type state_t is (S_HDR, S_COLLECT, S_DECIDE, S_CRCREQ, S_AW, S_W, S_B);
  signal st : state_t := S_HDR;
  type buf_t is array (0 to 63) of std_logic_vector(255 downto 0);
  signal buf : buf_t;
  signal cnt      : unsigned(6 downto 0) := (others => '0');
  signal h_seq    : unsigned(31 downto 0) := (others => '0');
  signal h_addr   : unsigned(39 downto 0) := (others => '0');
  signal h_nw     : unsigned(15 downto 0) := (others => '0');
  signal h_flags  : std_logic_vector(15 downto 0) := (others => '0');
  signal h_rlen   : unsigned(39 downto 0) := (others => '0');
  signal v_ok     : std_logic := '0';
  signal last     : unsigned(31 downto 0) := (others => '1');
  signal n_commit : unsigned(31 downto 0) := (others => '0');
  signal n_crc, n_seq, n_dup, n_bresp : unsigned(15 downto 0) := (others => '0');
  signal cur      : unsigned(39 downto 0) := (others => '0');
  signal remain   : unsigned(6 downto 0) := (others => '0');
  signal rd_idx   : unsigned(5 downto 0) := (others => '0');
  signal beat     : unsigned(4 downto 0) := (others => '0');
  signal blen     : unsigned(4 downto 0);
  signal awv, wv  : std_logic := '0';
  signal creq     : std_logic := '0';

  -- beats in the next burst: min(16, remain, beats left before the 4 KB boundary)
  function burst_len(a : unsigned(39 downto 0); r : unsigned(6 downto 0)) return unsigned is
    variable to4k : unsigned(7 downto 0);
    variable n    : unsigned(7 downto 0);
  begin
    to4k := to_unsigned(128, 8) - resize(a(11 downto 5), 8);
    n := to_unsigned(16, 8);
    if resize(r, 8) < n then n := resize(r, 8); end if;
    if to4k < n then n := to4k; end if;
    return n(4 downto 0);
  end function;
begin
  blen      <= burst_len(cur, remain);
  q_ready   <= '1' when st = S_HDR or st = S_COLLECT else '0';
  awaddr    <= std_logic_vector(cur(ADDR_W-1 downto 0));
  awlen     <= std_logic_vector(resize(blen - 1, 4));
  awsize    <= "101";
  awburst   <= "01";
  awvalid   <= awv;
  wdata     <= buf(to_integer(rd_idx));
  wstrb     <= (others => '1');
  wlast     <= '1' when beat = blen - 1 else '0';
  wvalid    <= wv;
  bready    <= '1' when st = S_B else '0';
  crc_req   <= creq;
  crc_addr  <= std_logic_vector(h_addr(ADDR_W-1 downto 0));
  crc_len   <= h_rlen;
  crc_seq   <= std_logic_vector(h_seq);
  last_seq  <= std_logic_vector(last);
  committed <= n_commit;
  crc_fail  <= n_crc;
  seq_err   <= n_seq;
  dup_cnt   <= n_dup;
  bresp_err <= n_bresp;
  busy      <= '0' when st = S_HDR else '1';

  process(clk)
    variable tag  : std_logic_vector(1 downto 0);
    variable d    : std_logic_vector(255 downto 0);
    variable diff : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      creq <= '0';
      if rst = '1' then
        st <= S_HDR; last <= (others => '1'); n_commit <= (others => '0');
        n_crc <= (others => '0'); n_seq <= (others => '0'); n_dup <= (others => '0');
        n_bresp <= (others => '0'); awv <= '0'; wv <= '0';
      else
        tag := q_data(257 downto 256);
        d   := q_data(255 downto 0);
        case st is
          when S_HDR =>
            if q_valid = '1' and tag = TAG_HDR then
              h_seq <= unsigned(d(63 downto 32)); h_addr <= unsigned(d(103 downto 64));
              h_nw <= unsigned(d(119 downto 104)); h_flags <= d(135 downto 120);
              h_rlen <= unsigned(d(175 downto 136)); cnt <= (others => '0');
              st <= S_COLLECT;
            end if;
          when S_COLLECT =>
            if q_valid = '1' then
              if tag = TAG_DATA then
                if cnt < JC_MAX_PAYLOAD then buf(to_integer(cnt)) <= d; end if;
                cnt <= cnt + 1;
              elsif tag = TAG_HDR then          -- a frame lost its verdict: count, restart
                n_crc <= n_crc + 1;
                h_seq <= unsigned(d(63 downto 32)); h_addr <= unsigned(d(103 downto 64));
                h_nw <= unsigned(d(119 downto 104)); h_flags <= d(135 downto 120);
                h_rlen <= unsigned(d(175 downto 136)); cnt <= (others => '0');
              else
                if tag = TAG_PASS and unsigned(d(31 downto 0)) = h_seq
                   and resize(cnt, 16) = h_nw then
                  v_ok <= '1';
                else
                  v_ok <= '0';
                end if;
                st <= S_DECIDE;
              end if;
            end if;
          when S_DECIDE =>
            diff := h_seq - (last + 1);
            if v_ok = '0' then
              n_crc <= n_crc + 1; st <= S_HDR;
            elsif h_nw = 0 and h_flags(0) = '0' then
              st <= S_HDR;                                -- status poll
            elsif diff = 0 then
              if h_flags(0) = '1' then
                st <= S_CRCREQ;
              else
                cur <= h_addr; remain <= resize(h_nw, 7); rd_idx <= (others => '0');
                st <= S_AW;
              end if;
            elsif diff(31) = '1' then
              n_dup <= n_dup + 1; st <= S_HDR;
            else
              n_seq <= n_seq + 1; st <= S_HDR;
            end if;
          when S_CRCREQ =>
            if crc_busy = '0' then
              creq <= '1'; last <= h_seq; n_commit <= n_commit + 1; st <= S_HDR;
            end if;
          when S_AW =>
            awv <= '1';
            if awv = '1' and awready = '1' then
              awv <= '0'; beat <= (others => '0'); wv <= '1'; st <= S_W;
            end if;
          when S_W =>
            if wv = '1' and wready = '1' then
              rd_idx <= rd_idx + 1;
              if beat = blen - 1 then
                wv <= '0'; st <= S_B;
              else
                beat <= beat + 1;
              end if;
            end if;
          when S_B =>
            if bvalid = '1' then
              if bresp /= "00" then n_bresp <= n_bresp + 1; end if;
              cur <= cur + resize(blen & "00000", 40);
              remain <= remain - resize(blen, 7);
              if remain = resize(blen, 7) then
                last <= h_seq; n_commit <= n_commit + 1; st <= S_HDR;
              else
                st <= S_AW;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
