-- Jungle Cat USER3 control core: TCK-domain frame core (pure VHDL; the BSCANE2 USER3 wrapper
-- is Task 4's hw/jc/ctl/rtl/jc_ctl_rx.vhd). Plan Task 2; spec 2026-10-07 S3.
--
-- RECEIVE is rtl/jc_frame_core.vhd's logic, COPIED, not shared: the loader is frozen byte
-- for byte. Differences: the magic is JC_CTL_MAGIC ("JCT1"); the header is accepted only if
-- count [87:72] <= 496 and nwords [119:104] <= 62; a FAIL verdict is also counted here
-- (crcf_cnt). One continuous Shift-DR carries back-to-back 16,384-bit slots; Capture resets
-- the bit counter; pushes are TAG & word(256), exactly the loader's FIFO word.
--
-- TRANSMIT, per slot:
--   bits 0..383        the status word: st_in latched at slot start, with [31:0] "JCST",
--                      [111:96] rsp_count = n (the words shifted below), [112] rsp_valid
--                      masked to 0 when the latched status is STALE (below), [163:148]
--                      desync, [164] ovf, [180:165] crc-fail count (the counts as they
--                      stood at slot start), [212:181] rsp_crc passed through from the
--                      executor, [351:213] forced to zero, and [383:352] st_crc (fix
--                      round 2): CRC-32 (crc32_bit, init ones, final xor ones) over bits
--                      0..351 exactly as shifted, accumulated SERIALLY from the TDO bit
--                      on the edges that shift bits 0..351 and loaded into the bottom of
--                      the (by then empty) shift register on the edge that shifts bit 351;
--   bits 384..         n response words, word k = response RAM address k, LSB first, where
--                      n = min(rsp_count, 496) if the shown rsp_valid is 1, else 0;
--   the rest           zero.
-- The response RAM is outside this unit: rsp_addr (9 bits) out, rsp_q (32 bits) in, a
-- synchronous read on TCK with one cycle of latency. Word k is loaded into the 32-bit
-- output register on the edge that shifts bit 383 + 32*k; rsp_addr was set to k on the
-- previous load edge (32 edges earlier; 0 at slot start), so rsp_q has long been valid.
--
-- ACK (fix round 1: host-driven). TDO carries no CRC of its own except rsp_crc, and a read
-- cannot safely be re-executed (WIN_DATA reads auto-increment), so a response is acked
-- only by the host, after it has checked rsp_crc: rsp_ack_tgl toggles on the rising TCK
-- edge that shifts bit 16159 (the CRC verdict) of a PASS frame whose header carries
-- ack_valid [216] = 1 and ack_seq [215:184] equal to the rsp_seq presented in this slot
-- (the latched status, shown rsp_valid = 1). An ack of a seq that is not being presented,
-- including one already acked, is ignored. A valid unacked response is presented again in
-- every slot until it is acked.
-- STALE: after an ack the acked rsp_seq is remembered; a later slot whose latched status
-- still has rsp_valid = 1 with that rsp_seq (the executor's clear has not crossed into TCK
-- yet) is shown with rsp_valid = 0 and no words, and cannot be acked. The memory is dropped
-- at the first slot whose latched status has rsp_valid = 0 or a different rsp_seq.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;
use work.jc_ctl_pkg.all;

entity jc_ctl_frame_core is
  port(
    tck         : in  std_logic;
    sel         : in  std_logic;
    capture     : in  std_logic;
    shift       : in  std_logic;
    tdi         : in  std_logic;
    tdo         : out std_logic;
    w_valid     : out std_logic;
    w_data      : out std_logic_vector(JC_FIFO_W-1 downto 0);
    w_ready     : in  std_logic;
    st_in       : in  std_logic_vector(JC_CTL_STATUS_BITS-1 downto 0);
    rsp_addr    : out std_logic_vector(JC_CTL_RSP_AW-1 downto 0);
    rsp_q       : in  std_logic_vector(31 downto 0);
    rsp_ack_tgl : out std_logic;
    desync_cnt  : out unsigned(15 downto 0);
    crcf_cnt    : out unsigned(15 downto 0);
    ovf_seen    : out std_logic
  );
end entity;

architecture rtl of jc_ctl_frame_core is
  constant ST_LAST  : natural := JC_CTL_STATUS_BITS - 1;                    -- 383
  constant RSP_LAST : natural := ST_LAST + 32 * (JC_CTL_MAX_ITEMS - 1);     -- last load edge

  -- receive (copied from jc_frame_core)
  signal bitcnt : natural range 0 to JC_SLOT_BITS - 1 := 0;
  signal sr     : std_logic_vector(255 downto 0) := (others => '0');
  signal crc    : std_logic_vector(31 downto 0) := (others => '1');
  signal rx_crc : std_logic_vector(31 downto 0) := (others => '0');
  signal good   : std_logic := '0';
  signal nwords : unsigned(15 downto 0) := (others => '0');
  signal seq    : std_logic_vector(31 downto 0) := (others => '0');
  signal desync : unsigned(15 downto 0) := (others => '0');
  signal crcf   : unsigned(15 downto 0) := (others => '0');
  signal ovf    : std_logic := '0';
  signal wv     : std_logic := '0';
  signal wd     : std_logic_vector(JC_FIFO_W-1 downto 0) := (others => '0');
  -- transmit
  signal st_sr    : std_logic_vector(JC_CTL_STATUS_BITS-1 downto 0) := (others => '0');
  signal rsp_sr   : std_logic_vector(31 downto 0) := (others => '0');
  signal in_st    : std_logic := '1';
  signal rsp_a    : unsigned(JC_CTL_RSP_AW-1 downto 0) := (others => '0');
  signal lat_v    : std_logic := '0';
  signal lat_n    : natural range 0 to JC_CTL_MAX_ITEMS := 0;
  signal lat_seq  : std_logic_vector(31 downto 0) := (others => '0');
  signal ack_t    : std_logic := '0';
  signal ack_pend : std_logic := '0';
  signal ack_seq  : std_logic_vector(31 downto 0) := (others => '0');
  signal scrc     : std_logic_vector(31 downto 0) := (others => '1');   -- st_crc running
  signal h_ack_v  : std_logic := '0';                                -- this frame's ack
  signal h_ack_seq : std_logic_vector(31 downto 0) := (others => '0');

  function merged(st : std_logic_vector(JC_CTL_STATUS_BITS-1 downto 0); d : unsigned(15 downto 0);
                  o  : std_logic; c : unsigned(15 downto 0); v : std_logic;
                  n  : natural) return std_logic_vector is
    variable r : std_logic_vector(JC_CTL_STATUS_BITS-1 downto 0) := st;
  begin
    r(JC_S_MAGIC_HI downto 0)              := JC_CTL_MAGIC_STAT;
    r(JC_S_RSPCNT_HI downto JC_S_RSPCNT_LO) := std_logic_vector(to_unsigned(n, 16));
    r(JC_S_RSPVALID)                       := v;
    r(JC_S_DESYNC_HI downto JC_S_DESYNC_LO) := std_logic_vector(d);
    r(JC_S_OVF)                            := o;
    r(JC_S_CRCF_HI downto JC_S_CRCF_LO)     := std_logic_vector(c);
    r(JC_S_ZERO_HI downto JC_S_ZERO_LO)     := (others => '0');
    r(JC_S_STCRC_HI downto JC_S_STCRC_LO)   := (others => '0');  -- filled in while shifting
    return r;
  end function;
begin
  tdo         <= st_sr(0) when in_st = '1' else rsp_sr(0);
  w_valid     <= wv;
  w_data      <= wd;
  rsp_addr    <= std_logic_vector(rsp_a);
  rsp_ack_tgl <= ack_t;
  desync_cnt  <= desync;
  crcf_cnt    <= crcf;
  ovf_seen    <= ovf;

  process(tck)
    variable word   : std_logic_vector(255 downto 0);
    variable widx   : natural range 0 to 63;
    variable crc_rx : std_logic_vector(31 downto 0);
    variable k      : natural range 0 to JC_CTL_MAX_ITEMS;
    variable start  : boolean;
    variable stale  : boolean;
    variable v      : std_logic;
    variable cnt    : unsigned(15 downto 0);
    variable n      : natural range 0 to JC_CTL_MAX_ITEMS;
    variable pass   : boolean;
    variable sb     : std_logic;
    variable nc     : std_logic_vector(31 downto 0);
  begin
    if rising_edge(tck) then
      start := false;
      wv <= '0';
      if wv = '1' and w_ready = '0' then
        ovf <= '1';
      end if;
      if sel = '1' and capture = '1' then
        start := true;
      elsif sel = '1' and shift = '1' then
        -- ---------------- receive ----------------
        word  := tdi & sr(255 downto 1);
        sr    <= word;
        if bitcnt < JC_CRC_FIRST then
          crc <= crc32_bit(crc, tdi);
        elsif bitcnt <= JC_CRC_LAST then
          rx_crc <= tdi & rx_crc(31 downto 1);
        end if;
        if bitcnt < JC_CRC_FIRST and (bitcnt mod 256) = 255 then
          widx := bitcnt / 256;
          if widx = 0 then
            if word(31 downto 0) = JC_CTL_MAGIC
               and unsigned(word(JC_H_COUNT_HI downto JC_H_COUNT_LO)) <= JC_CTL_MAX_ITEMS
               and unsigned(word(JC_H_NWORDS_HI downto JC_H_NWORDS_LO)) <= JC_CTL_MAX_PAYLOAD then
              good   <= '1';
              nwords <= unsigned(word(JC_H_NWORDS_HI downto JC_H_NWORDS_LO));
              seq    <= word(JC_H_SEQ_HI downto JC_H_SEQ_LO);
              h_ack_v   <= word(JC_H_ACKVALID);
              h_ack_seq <= word(JC_H_ACKSEQ_HI downto JC_H_ACKSEQ_LO);
              wv     <= '1';
              wd     <= TAG_HDR & word;
            else
              good   <= '0';
              desync <= desync + 1;
            end if;
          elsif good = '1' and widx <= to_integer(nwords) then
            wv <= '1';
            wd <= TAG_DATA & word;
          end if;
        end if;
        if bitcnt = JC_CRC_LAST and good = '1' then
          crc_rx := tdi & rx_crc(31 downto 1);
          wv <= '1';
          pass := crc_rx = (crc xor x"FFFFFFFF");
          if pass then
            wd <= TAG_PASS & std_logic_vector(resize(unsigned(seq), 256));
          else
            wd <= TAG_FAIL & std_logic_vector(resize(unsigned(seq), 256));
            crcf <= crcf + 1;
          end if;
          -- the host's ack of the response presented in this slot
          if pass and h_ack_v = '1' and h_ack_seq = lat_seq and lat_v = '1' then
            ack_t    <= not ack_t;
            ack_pend <= '1';
            ack_seq  <= lat_seq;
          end if;
        end if;
        -- ---------------- transmit ----------------
        st_sr <= '0' & st_sr(JC_CTL_STATUS_BITS-1 downto 1);
        if bitcnt < JC_S_STCRC_LO then
          sb := st_sr(0);                  -- the bit on TDO for this edge
          nc := crc32_bit(scrc, sb);
          scrc <= nc;
          if bitcnt = JC_S_STCRC_LO - 1 then
            -- bits 352..383 are next: positions 31..0 of the register after this shift
            st_sr(31 downto 0) <= nc xor x"FFFFFFFF";
          end if;
        end if;
        if bitcnt = ST_LAST then
          in_st <= '0';
        end if;
        if bitcnt >= ST_LAST and bitcnt <= RSP_LAST and ((bitcnt - ST_LAST) mod 32) = 0 then
          k := (bitcnt - ST_LAST) / 32;
          if k < lat_n then
            rsp_sr <= rsp_q;
          else
            rsp_sr <= (others => '0');
          end if;
          rsp_a <= to_unsigned(k + 1, JC_CTL_RSP_AW);
        else
          rsp_sr <= '0' & rsp_sr(31 downto 1);
        end if;
        if bitcnt = JC_SLOT_BITS - 1 then
          start := true;
        else
          bitcnt <= bitcnt + 1;
        end if;
      end if;

      -- slot start (Capture-DR, or the last bit of the previous slot): latch the status
      if start then
        bitcnt <= 0;
        crc    <= (others => '1');
        good   <= '0';
        stale  := ack_pend = '1' and st_in(JC_S_RSPVALID) = '1'
                  and st_in(JC_S_RSPSEQ_HI downto JC_S_RSPSEQ_LO) = ack_seq;
        if stale then
          v := '0';
        else
          v := st_in(JC_S_RSPVALID);
          ack_pend <= '0';
        end if;
        cnt := unsigned(st_in(JC_S_RSPCNT_HI downto JC_S_RSPCNT_LO));
        if v = '0' then
          n := 0;
        elsif cnt > JC_CTL_MAX_ITEMS then
          n := JC_CTL_MAX_ITEMS;
        else
          n := to_integer(cnt);
        end if;
        st_sr   <= merged(st_in, desync, ovf, crcf, v, n);
        lat_v   <= v;
        lat_seq <= st_in(JC_S_RSPSEQ_HI downto JC_S_RSPSEQ_LO);
        lat_n   <= n;
        in_st  <= '1';
        scrc   <= (others => '1');
        rsp_sr <= (others => '0');
        rsp_a  <= (others => '0');
      end if;
    end if;
  end process;
end architecture;
