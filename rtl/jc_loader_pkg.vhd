-- Jungle Cat JTAG-to-HBM loader: shared constants and CRC-32.
-- Spec: docs/superpowers/specs/2026-10-05-jc-jtag-hbm-loader-design.md (S4, S10).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package jc_loader_pkg is
  constant JC_SLOT_BITS   : natural := 16384;
  constant JC_WORD_BITS   : natural := 256;
  constant JC_MAX_PAYLOAD : natural := 62;
  constant JC_CRC_FIRST   : natural := 63 * 256;           -- 16128
  constant JC_CRC_LAST    : natural := JC_CRC_FIRST + 31;  -- 16159
  constant JC_FIFO_W      : natural := 258;
  -- Task 9b: status word width (was 256). [351:256] DNA, [352] dna_valid, [383:353] zero.
  constant JC_STATUS_BITS : natural := 384;
  constant JC_MAGIC_FRAME : std_logic_vector(31 downto 0) := x"4A4C4431";
  constant JC_MAGIC_STAT  : std_logic_vector(31 downto 0) := x"4A4C5354";
  constant TAG_DATA : std_logic_vector(1 downto 0) := "00";
  constant TAG_HDR  : std_logic_vector(1 downto 0) := "01";
  constant TAG_PASS : std_logic_vector(1 downto 0) := "10";
  constant TAG_FAIL : std_logic_vector(1 downto 0) := "11";

  -- Reflected CRC-32 (IEEE, zlib), one bit, LSB first.
  function crc32_bit(crc : std_logic_vector(31 downto 0); b : std_logic)
    return std_logic_vector;
  -- 32 bits, bit 0 first (= four bytes in little-endian address order).
  function crc32_word(crc : std_logic_vector(31 downto 0);
                      w   : std_logic_vector(31 downto 0))
    return std_logic_vector;
end package;

package body jc_loader_pkg is
  function crc32_bit(crc : std_logic_vector(31 downto 0); b : std_logic)
    return std_logic_vector is
    variable c : std_logic_vector(31 downto 0);
  begin
    c := '0' & crc(31 downto 1);
    if (crc(0) xor b) = '1' then
      c := c xor x"EDB88320";
    end if;
    return c;
  end function;

  function crc32_word(crc : std_logic_vector(31 downto 0);
                      w   : std_logic_vector(31 downto 0))
    return std_logic_vector is
    variable c : std_logic_vector(31 downto 0) := crc;
  begin
    for i in 0 to 31 loop
      c := crc32_bit(c, w(i));
    end loop;
    return c;
  end function;
end package body;
