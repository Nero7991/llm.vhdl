-- Jungle Cat loader: TCK-domain frame receiver (pure VHDL; the BSCANE2 wrapper is
-- hw/jc/loader/rtl/jc_frame_rx.vhd). Spec S4.1, S4.4 and S10; plan rulings 2, 3, 5.
--
-- One continuous Shift-DR carries back-to-back 16,384-bit slots. Capture resets the bit
-- counter. TCK runs only while bits shift, so everything a slot owes (the verdict push)
-- completes inside its own 224 pad bits.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;

entity jc_frame_core is
  port(
    tck        : in  std_logic;
    sel        : in  std_logic;
    capture    : in  std_logic;
    shift      : in  std_logic;
    tdi        : in  std_logic;
    tdo        : out std_logic;
    w_valid    : out std_logic;
    w_data     : out std_logic_vector(JC_FIFO_W-1 downto 0);
    w_ready    : in  std_logic;
    st_in      : in  std_logic_vector(255 downto 0);
    desync_cnt : out unsigned(15 downto 0);
    ovf_seen   : out std_logic
  );
end entity;

architecture rtl of jc_frame_core is
  signal bitcnt : natural range 0 to JC_SLOT_BITS - 1 := 0;
  signal sr     : std_logic_vector(255 downto 0) := (others => '0');
  signal crc    : std_logic_vector(31 downto 0) := (others => '1');
  signal rx_crc : std_logic_vector(31 downto 0) := (others => '0');
  signal good   : std_logic := '0';
  signal nwords : unsigned(15 downto 0) := (others => '0');
  signal seq    : std_logic_vector(31 downto 0) := (others => '0');
  signal st_sr  : std_logic_vector(255 downto 0) := (others => '0');
  signal desync : unsigned(15 downto 0) := (others => '0');
  signal ovf    : std_logic := '0';
  signal wv     : std_logic := '0';
  signal wd     : std_logic_vector(JC_FIFO_W-1 downto 0) := (others => '0');

  function merged(st : std_logic_vector(255 downto 0); d : unsigned(15 downto 0);
                  o  : std_logic) return std_logic_vector is
    variable v : std_logic_vector(255 downto 0) := st;
  begin
    v(31 downto 0)    := JC_MAGIC_STAT;
    v(143 downto 128) := std_logic_vector(d);
    v(179)            := o;
    return v;
  end function;
begin
  tdo        <= st_sr(0);
  w_valid    <= wv;
  w_data     <= wd;
  desync_cnt <= desync;
  ovf_seen   <= ovf;

  process(tck)
    variable word   : std_logic_vector(255 downto 0);
    variable widx   : natural range 0 to 63;
    variable crc_rx : std_logic_vector(31 downto 0);
  begin
    if rising_edge(tck) then
      wv <= '0';
      if wv = '1' and w_ready = '0' then
        ovf <= '1';
      end if;
      if sel = '1' and capture = '1' then
        bitcnt <= 0;
        crc    <= (others => '1');
        good   <= '0';
        st_sr  <= merged(st_in, desync, ovf);
      elsif sel = '1' and shift = '1' then
        word  := tdi & sr(255 downto 1);
        sr    <= word;
        st_sr <= '0' & st_sr(255 downto 1);
        if bitcnt < JC_CRC_FIRST then
          crc <= crc32_bit(crc, tdi);
        elsif bitcnt <= JC_CRC_LAST then
          rx_crc <= tdi & rx_crc(31 downto 1);
        end if;
        if bitcnt < JC_CRC_FIRST and (bitcnt mod 256) = 255 then
          widx := bitcnt / 256;
          if widx = 0 then
            if word(31 downto 0) = JC_MAGIC_FRAME
               and unsigned(word(119 downto 104)) <= JC_MAX_PAYLOAD then
              good   <= '1';
              nwords <= unsigned(word(119 downto 104));
              seq    <= word(63 downto 32);
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
          if crc_rx = (crc xor x"FFFFFFFF") then
            wd <= TAG_PASS & std_logic_vector(resize(unsigned(seq), 256));
          else
            wd <= TAG_FAIL & std_logic_vector(resize(unsigned(seq), 256));
          end if;
        end if;
        if bitcnt = JC_SLOT_BITS - 1 then
          bitcnt <= 0;
          crc    <= (others => '1');
          good   <= '0';
          st_sr  <= merged(st_in, desync, ovf);
        else
          bitcnt <= bitcnt + 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
