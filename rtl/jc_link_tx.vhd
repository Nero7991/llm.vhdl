-- rtl/jc_link_tx.vhd -- die A's framer (spec 1b.1, 3; plan Task 4). tok_loop_fsm fills the
-- payload buffer with R_X (two mantissas per word), then pulses send. The frame is kept for
-- RESEND until the next fill begins (plan D3 guarantees that frame is the one die B waits
-- for); a resend at resends >= resend_cap sets the sticky `exhausted` instead (spec 3).
-- A RESEND that arrives while busy is latched (`resend_pend`) and served the next time the
-- framer reaches T_IDLE with a frame still held; it is not dropped (finding 4, 2026-11-05:
-- the host's recovery write can land mid-transmission, e.g. tb_tok_loop_pair's P3).
-- One word per cycle at most (payload words every 3 cycles): 2,568 words for the 27B,
-- about 62 us at the card's 125 MHz clk_core (ESTIMATE; the link carries it in ~8 us).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;
use work.jc_link_pkg.all;

entity jc_link_tx is
  generic(N_EMBD : positive := 5120; W : positive := 2);
  port(
    clk, rst    : in  std_logic;
    run_start   : in  std_logic;
    fill_we     : in  std_logic;
    fill_idx    : in  unsigned(11 downto 0);
    fill_data   : in  std_logic_vector(31 downto 0);
    send        : in  std_logic;
    send_pos    : in  unsigned(31 downto 0);
    send_exp    : in  std_logic_vector(31 downto 0);
    resend      : in  std_logic;
    resend_cap  : in  unsigned(31 downto 0);
    busy        : out std_logic;
    exhausted   : out std_logic;
    frames_sent : out unsigned(31 downto 0);
    resends     : out unsigned(31 downto 0);
    m_tdata     : out std_logic_vector(32*W-1 downto 0);
    m_tkeep     : out std_logic_vector(4*W-1 downto 0);
    m_tlast     : out std_logic;
    m_tvalid    : out std_logic;
    m_tready    : in  std_logic);
end entity;

architecture rtl of jc_link_tx is
  constant PW  : natural := N_EMBD / 2;
  constant FW  : natural := LK_HDR_WORDS + PW;
  constant CHK : natural range 0 to 0 := (FW mod W) + (N_EMBD mod 2);
  type buf_t is array (0 to PW-1) of std_logic_vector(31 downto 0);
  type words_t is array (0 to W-1) of std_logic_vector(31 downto 0);
  type ts_t is (T_IDLE, T_GEN, T_RD, T_RD2);
  signal buf : buf_t;
  signal ts : ts_t := T_IDLE;
  signal asm : words_t := (others => (others => '0'));
  signal nw : natural range 0 to W := 0;
  signal asm_last, bv, olast, held, exh : std_logic := '0';
  signal resend_pend : std_logic := '0';   -- a RESEND that arrived while busy (finding 4)
  signal obeat : std_logic_vector(32*W-1 downto 0) := (others => '0');
  signal k : natural range 0 to FW := 0;
  signal crc : std_logic_vector(31 downto 0) := LK_CRC_INIT;
  signal rd_a : natural range 0 to PW-1 := 0;
  signal rq : std_logic_vector(31 downto 0) := (others => '0');
  signal seq_next, seq_r, nsent, nres, pos_r : unsigned(31 downto 0) := (others => '0');
  signal exp_r : std_logic_vector(31 downto 0) := (others => '0');
begin
  m_tdata <= obeat;  m_tkeep <= (others => '1');  m_tlast <= olast;  m_tvalid <= bv;
  busy <= '0' when ts = T_IDLE and nw = 0 and bv = '0' else '1';
  exhausted <= exh;  frames_sent <= nsent;  resends <= nres;

  ram : process(clk)
  begin
    if rising_edge(clk) then
      if fill_we = '1' then buf(to_integer(fill_idx) mod PW) <= fill_data; end if;
      rq <= buf(rd_a);
    end if;
  end process;

  main : process(clk)
    variable wd : std_logic_vector(31 downto 0);
    procedure push(x : std_logic_vector(31 downto 0)) is
    begin
      asm(nw) <= x; nw <= nw + 1; crc <= crc32_word(crc, x);
    end procedure;
  begin
    if rising_edge(clk) then
      if bv = '1' and m_tready = '1' then bv <= '0'; end if;
      if nw = W and (bv = '0' or m_tready = '1') then
        for j in 0 to W - 1 loop obeat(32 * j + 31 downto 32 * j) <= asm(j); end loop;
        olast <= asm_last; bv <= '1'; nw <= 0; asm_last <= '0';
      end if;
      if fill_we = '1' then held <= '0'; end if;
      if rst = '1' then
        ts <= T_IDLE; bv <= '0'; nw <= 0; held <= '0'; exh <= '0'; resend_pend <= '0';
        seq_next <= (others => '0'); nsent <= (others => '0'); nres <= (others => '0');
      else
        if run_start = '1' then
          seq_next <= (others => '0'); held <= '0'; exh <= '0'; resend_pend <= '0';
          nsent <= (others => '0'); nres <= (others => '0');
        end if;
        if resend = '1' and held = '1' then resend_pend <= '1'; end if;
        if fill_we = '1' then resend_pend <= '0'; end if;   -- a new fill retires the old RESEND
        case ts is
          when T_IDLE =>
            if send = '1' then
              pos_r <= send_pos; exp_r <= send_exp; seq_r <= seq_next; seq_next <= seq_next + 1;
              held <= '1'; nsent <= nsent + 1; k <= 0; crc <= LK_CRC_INIT; ts <= T_GEN;
            elsif (resend = '1' or resend_pend = '1') and held = '1' then
              resend_pend <= '0';
              if nres >= resend_cap then
                exh <= '1';
              else
                nres <= nres + 1; nsent <= nsent + 1; k <= 0; crc <= LK_CRC_INIT; ts <= T_GEN;
              end if;
            end if;
          when T_GEN =>
            if nw < W then
              if k < LK_HDR_WORDS then
                case k is
                  when 0 => wd := LK_MAGIC;
                  when 1 => wd := std_logic_vector(seq_r);
                  when 2 => wd := std_logic_vector(pos_r);
                  when 3 => wd := std_logic_vector(to_unsigned(PW, 32));
                  when 4 => wd := exp_r;
                  when others => wd := (others => '0');
                end case;
                push(wd); k <= k + 1;
              elsif k < FW then
                rd_a <= k - LK_HDR_WORDS; ts <= T_RD;
              else
                asm(0) <= lk_crc_final(crc);
                for j in 1 to W - 1 loop asm(j) <= (others => '0'); end loop;
                nw <= W; asm_last <= '1'; ts <= T_IDLE;
              end if;
            end if;
          when T_RD  => ts <= T_RD2;
          when T_RD2 => push(rq); k <= k + 1; ts <= T_GEN;
        end case;
      end if;
    end if;
  end process;
end architecture;
