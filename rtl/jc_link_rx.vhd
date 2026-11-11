-- rtl/jc_link_rx.vhd -- die B's deframer (spec 1b.3, 3; plan Task 4). Takes a beat every
-- cycle it is offered one (Aurora RX has no backpressure). A frame is committed to a slot
-- only if it is well formed, its CRC matches, its magic and word count are right, and its
-- seq and position are the next expected; anything else is dropped and counted, and sets
-- `bad` (die B pauses, spec 3). A chan_up fall counts a link-down, sets `down`, and
-- returns the deframer to a header: beats are ignored while chan_up is low, so the first beat
-- after the channel returns is parsed as a header (final review I3, 2026-11-11). Discarding
-- to the next tlast instead hung die B when its RX dropped alone (simplex: A's TX never sees
-- it and the cut frame's tail is lost): the first RESEND frame was swallowed as the
-- terminator, B stayed paused and no counter moved. Now a resumed tail (A's framer stalled on
-- tready and resumed the cut frame) is shorter than a frame, ends in tlast before the CRC
-- beat, and is refused and COUNTED as a CRC failure; the host's RESEND recovers either way
-- (spec 3). The next good frame clears both flags.
-- The slot store has DEPTH + 1 slots for DEPTH frames: an incoming payload always lands in
-- the one slot no committed frame holds, and whether the frame fits is decided at commit
-- (occupancy then, net of a pop that cycle), so a pop during the frame frees room for it
-- (Task 4 review finding, folded into Task 6).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_link_pkg.all;

entity jc_link_rx is
  generic(N_EMBD : positive := 5120; W : positive := 2; DEPTH : positive := 2);
  port(
    clk, rst    : in  std_logic;
    run_start   : in  std_logic;
    chan_up     : in  std_logic;
    s_tdata     : in  std_logic_vector(32*W-1 downto 0);
    s_tlast     : in  std_logic;
    s_tvalid    : in  std_logic;
    head_valid  : out std_logic;
    head_pos    : out unsigned(31 downto 0);
    head_exp    : out std_logic_vector(31 downto 0);
    rd_idx      : in  unsigned(11 downto 0);
    rd_data     : out std_logic_vector(31 downto 0);
    pop         : in  std_logic;
    bad, down   : out std_logic;
    frames_good, crc_fails, seqpos_bad, link_downs, overruns, consumed : out unsigned(31 downto 0));
end entity;

architecture rtl of jc_link_rx is
  constant PW  : natural := N_EMBD / 2;
  constant HB  : natural := LK_HDR_WORDS / W;
  constant PB  : natural := PW / W;
  constant CHK : natural range 0 to 0 := (LK_HDR_WORDS mod W) + (PW mod W);
  constant NSLOT : natural := DEPTH + 1;   -- one spare: the slot an arriving payload fills
  type ram_t is array (0 to NSLOT * PB - 1) of std_logic_vector(32*W-1 downto 0);
  type hdr_t is array (0 to LK_HDR_WORDS - 1) of std_logic_vector(31 downto 0);
  type u32_arr is array (0 to NSLOT - 1) of unsigned(31 downto 0);
  type s32_arr is array (0 to NSLOT - 1) of std_logic_vector(31 downto 0);
  type rs_t is (R_HDR, R_PAY, R_CRC, R_DISC);
  signal ram : ram_t;
  signal rs : rs_t := R_HDR;
  signal hdr : hdr_t := (others => (others => '0'));
  signal crc : std_logic_vector(31 downto 0) := LK_CRC_INIT;
  signal bi : natural range 0 to HB + PB := 0;
  signal wslot, hslot : natural range 0 to NSLOT - 1 := 0;
  signal occ : natural range 0 to DEPTH := 0;
  signal spos : u32_arr := (others => (others => '0'));
  signal sexp : s32_arr := (others => (others => '0'));
  signal exp_seq, exp_pos : unsigned(31 downto 0) := (others => '0');
  signal c_good, c_crc, c_sp, c_down, c_ovr, c_cons : unsigned(31 downto 0) := (others => '0');
  signal bad_r, down_r, up_d : std_logic := '0';
  signal rq : std_logic_vector(32*W-1 downto 0) := (others => '0');
  signal rsel : natural range 0 to W - 1 := 0;
begin
  head_valid <= '1' when occ > 0 else '0';
  head_pos <= spos(hslot);  head_exp <= sexp(hslot);
  bad <= bad_r;  down <= down_r;
  frames_good <= c_good;  crc_fails <= c_crc;  seqpos_bad <= c_sp;
  link_downs <= c_down;  overruns <= c_ovr;  consumed <= c_cons;
  rd_data <= rq(32 * rsel + 31 downto 32 * rsel);

  process(clk)
    variable commit : boolean;
    variable occ_n : natural range 0 to DEPTH;
    procedure restart is
    begin
      rs <= R_HDR; bi <= 0; crc <= LK_CRC_INIT;
    end procedure;
  begin
    if rising_edge(clk) then
      rq <= ram(hslot * PB + to_integer(rd_idx) / W);
      rsel <= to_integer(rd_idx) mod W;
      commit := false;
      up_d <= chan_up;
      if rst = '1' then
        restart; occ <= 0; wslot <= 0; hslot <= 0; bad_r <= '0'; down_r <= '0';
        exp_seq <= (others => '0'); exp_pos <= (others => '0');
      elsif run_start = '1' then
        if rs /= R_HDR or bi /= 0 then rs <= R_DISC; bi <= 0; crc <= LK_CRC_INIT; end if;
        occ <= 0; wslot <= 0; hslot <= 0; bad_r <= '0'; down_r <= '0';
        exp_seq <= (others => '0'); exp_pos <= (others => '0');
        c_good <= (others => '0'); c_crc <= (others => '0'); c_sp <= (others => '0');
        c_down <= (others => '0'); c_ovr <= (others => '0'); c_cons <= (others => '0');
      else
        if up_d = '1' and chan_up = '0' then
          c_down <= c_down + 1; down_r <= '1';
          restart;                                     -- the next beat after chan_up returns is a header
        elsif s_tvalid = '1' and chan_up = '1' then
          case rs is
            when R_HDR =>
              for j in 0 to W - 1 loop hdr(bi * W + j) <= s_tdata(32 * j + 31 downto 32 * j); end loop;
              crc <= lk_crc_beat(crc, s_tdata, W);
              if s_tlast = '1' then
                c_crc <= c_crc + 1; bad_r <= '1'; restart;
              elsif bi = HB - 1 then
                rs <= R_PAY; bi <= bi + 1;
              else
                bi <= bi + 1;
              end if;
            when R_PAY =>
              ram(wslot * PB + bi - HB) <= s_tdata;
              crc <= lk_crc_beat(crc, s_tdata, W);
              if s_tlast = '1' then
                c_crc <= c_crc + 1; bad_r <= '1'; restart;
              elsif bi = HB + PB - 1 then
                rs <= R_CRC;
              else
                bi <= bi + 1;
              end if;
            when R_CRC =>
              if s_tlast = '0' then
                c_crc <= c_crc + 1; bad_r <= '1'; rs <= R_DISC; bi <= 0; crc <= LK_CRC_INIT;
              else
                if lk_crc_final(crc) /= s_tdata(31 downto 0) then
                  c_crc <= c_crc + 1; bad_r <= '1';
                elsif hdr(0) /= LK_MAGIC or unsigned(hdr(3)) /= PW then
                  c_sp <= c_sp + 1; bad_r <= '1';
                elsif unsigned(hdr(1)) /= exp_seq or unsigned(hdr(2)) /= exp_pos then
                  c_sp <= c_sp + 1; bad_r <= '1';
                elsif occ = DEPTH and pop = '0' then          -- no room at commit time
                  c_ovr <= c_ovr + 1; bad_r <= '1';
                else
                  commit := true;
                  spos(wslot) <= unsigned(hdr(2)); sexp(wslot) <= hdr(4);
                  wslot <= (wslot + 1) mod NSLOT;
                  exp_seq <= exp_seq + 1; exp_pos <= exp_pos + 1; c_good <= c_good + 1;
                  bad_r <= '0'; down_r <= '0';
                end if;
                restart;
              end if;
            when R_DISC =>
              if s_tlast = '1' then restart; end if;
          end case;
        end if;
        occ_n := occ;
        if commit then occ_n := occ_n + 1; end if;
        if pop = '1' and occ > 0 then
          occ_n := occ_n - 1; hslot <= (hslot + 1) mod NSLOT; c_cons <= c_cons + 1;
        end if;
        occ <= occ_n;
      end if;
    end if;
  end process;
end architecture;
