-- Jungle Cat loader: range CRC-32 over HBM (spec S4.5). Reads in AXI3 bursts of at most
-- 16 beats that never cross 4 KB, folds each 256-bit beat 32 bits per cycle (8 cycles a
-- beat, ~800 MB/s at 200 MHz). The result holds until the next request.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;

entity jc_hbm_crc is
  generic(ADDR_W : positive := 33);
  port(
    clk, rst  : in  std_logic;
    req       : in  std_logic;
    req_addr  : in  std_logic_vector(ADDR_W-1 downto 0);
    req_len   : in  unsigned(39 downto 0);
    req_seq   : in  std_logic_vector(31 downto 0);
    busy      : out std_logic;
    araddr    : out std_logic_vector(ADDR_W-1 downto 0);
    arlen     : out std_logic_vector(3 downto 0);
    arsize    : out std_logic_vector(2 downto 0);
    arburst   : out std_logic_vector(1 downto 0);
    arvalid   : out std_logic;
    arready   : in  std_logic;
    rdata     : in  std_logic_vector(255 downto 0);
    rresp     : in  std_logic_vector(1 downto 0);
    rlast     : in  std_logic;
    rvalid    : in  std_logic;
    rready    : out std_logic;
    res_valid : out std_logic;
    res_err   : out std_logic;
    res_crc   : out std_logic_vector(31 downto 0);
    res_seq   : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of jc_hbm_crc is
  type state_t is (S_IDLE, S_AR, S_R, S_PROC, S_DONE);
  signal st     : state_t := S_IDLE;
  signal cur    : unsigned(39 downto 0) := (others => '0');
  signal beats  : unsigned(34 downto 0) := (others => '0');   -- beats left in the range
  signal blen   : unsigned(4 downto 0);
  signal inb    : unsigned(4 downto 0) := (others => '0');    -- beats left in this burst
  signal beat_r : std_logic_vector(255 downto 0) := (others => '0');
  signal k      : unsigned(2 downto 0) := (others => '0');
  signal crc    : std_logic_vector(31 downto 0) := (others => '1');
  signal seq    : std_logic_vector(31 downto 0) := (others => '0');
  signal rv, rerr, arv : std_logic := '0';
  signal outcrc : std_logic_vector(31 downto 0) := (others => '0');

  function burst_len(a : unsigned(39 downto 0); r : unsigned(34 downto 0)) return unsigned is
    variable to4k, n : unsigned(7 downto 0);
  begin
    to4k := to_unsigned(128, 8) - resize(a(11 downto 5), 8);
    n := to_unsigned(16, 8);
    if r < 16 then n := resize(r, 8); end if;
    if to4k < n then n := to4k; end if;
    return n(4 downto 0);
  end function;
begin
  blen      <= burst_len(cur, beats);
  araddr    <= std_logic_vector(cur(ADDR_W-1 downto 0));
  arlen     <= std_logic_vector(resize(blen - 1, 4));
  arsize    <= "101";
  arburst   <= "01";
  arvalid   <= arv;
  rready    <= '1' when st = S_R else '0';
  busy      <= '0' when st = S_IDLE else '1';
  res_valid <= rv;
  res_err   <= rerr;
  res_crc   <= outcrc;
  res_seq   <= seq;

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st <= S_IDLE; rv <= '0'; rerr <= '0'; arv <= '0';
      else
        case st is
          when S_IDLE =>
            if req = '1' then
              cur <= resize(unsigned(req_addr), 40);
              beats <= resize(req_len(39 downto 5), 35);
              crc <= (others => '1'); seq <= req_seq; rv <= '0'; rerr <= '0';
              if req_len(39 downto 5) = 0 then st <= S_DONE; else st <= S_AR; end if;
            end if;
          when S_AR =>
            arv <= '1';
            if arv = '1' and arready = '1' then
              arv <= '0'; inb <= blen; st <= S_R;
            end if;
          when S_R =>
            if rvalid = '1' then
              beat_r <= rdata; k <= (others => '0');
              if rresp /= "00" then rerr <= '1'; end if;
              st <= S_PROC;
            end if;
          when S_PROC =>
            crc <= crc32_word(crc, beat_r(32 * to_integer(k) + 31 downto 32 * to_integer(k)));
            if k = 7 then
              beats <= beats - 1;
              cur <= cur + 32;
              if inb = 1 then
                if beats = 1 then st <= S_DONE; else st <= S_AR; end if;
              else
                inb <= inb - 1; st <= S_R;
              end if;
            else
              k <= k + 1;
            end if;
          when S_DONE =>
            outcrc <= crc xor x"FFFFFFFF"; rv <= '1'; st <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
