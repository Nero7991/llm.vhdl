-- rtl/jc_link_pkg.vhd -- the die-to-die frame (spec 2026-11-04 section 1b.1; plan Task 4,
-- deviation D2: the header carries the X exponent and is 8 words). CRC-32 is
-- rtl/jc_loader_pkg.vhd's crc32_word (zlib polynomial, little-endian bytes), used unchanged.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;

package jc_link_pkg is
  constant LK_MAGIC     : std_logic_vector(31 downto 0) := x"4A4C4B31";   -- "JLK1"
  constant LK_HDR_WORDS : natural := 8;
  constant LK_CRC_INIT  : std_logic_vector(31 downto 0) := x"FFFFFFFF";
  function lk_pw(n_embd : positive) return natural;
  function lk_beats(n_embd : positive; w : positive) return natural;
  function lk_crc_beat(crc : std_logic_vector(31 downto 0); beat : std_logic_vector;
                       w : positive) return std_logic_vector;
  function lk_crc_final(crc : std_logic_vector(31 downto 0)) return std_logic_vector;
end package;

package body jc_link_pkg is
  function lk_pw(n_embd : positive) return natural is
  begin
    return n_embd / 2;
  end function;

  function lk_beats(n_embd : positive; w : positive) return natural is
  begin
    return (LK_HDR_WORDS + n_embd / 2) / w + 1;
  end function;

  function lk_crc_beat(crc : std_logic_vector(31 downto 0); beat : std_logic_vector;
                       w : positive) return std_logic_vector is
    variable b : std_logic_vector(beat'length - 1 downto 0) := beat;
    variable c : std_logic_vector(31 downto 0) := crc;
  begin
    for k in 0 to w - 1 loop
      c := crc32_word(c, b(32 * k + 31 downto 32 * k));
    end loop;
    return c;
  end function;

  function lk_crc_final(crc : std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    return crc xor x"FFFFFFFF";
  end function;
end package body;
