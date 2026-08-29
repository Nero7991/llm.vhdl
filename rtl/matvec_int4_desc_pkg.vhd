-- rtl/matvec_int4_desc_pkg.vhd -- the byte-pinned layout of subsystem A's
-- in-memory descriptor, in one place.
--
-- Spec: docs/2026-08-28_matvec-descriptor-format.md
--
-- The layout is subsystem D's (rtl/seq_desc_fetch.vhd): 64-bit little-endian
-- words, a 64-byte header at 0x00, and the base array at 0x40 -- the array D
-- deliberately does not fetch.  Subsystem A adds a four-word EXTENSION
-- immediately AFTER the base array, which is the one region D never reads, so
-- a descriptor written to this package's layout is still a valid D descriptor.
--
-- Everything here is a constant or a pure function of the geometry, so the
-- gateware and the testbench that builds a descriptor image compute the same
-- offsets from the same source.  A testbench that recomputed them from the
-- document would agree with a wrong document just as happily.

library ieee;
use ieee.std_logic_1164.all;

package matvec_int4_desc_pkg is

  -- "MV4I", the same code ref/matvec_int4.c uses for the packed file's magic
  -- and the same value the AXI-Lite ID register returns.
  constant MV4I_MAGIC : std_logic_vector(31 downto 0) := x"4D563449";

  -- Version of the A EXTENSION block.  D's own header carries no version
  -- field, so this is the only one, and it covers exactly the words this
  -- package adds.
  constant MV4I_DESC_VER : natural := 1;

  -- D's opcode for a subsystem A job (rtl/seq_desc_fetch.vhd:253).
  constant OP_A_JOB : natural := 0;

  -- Word indices.  Header 0..7; base array from 8; extension after that.
  constant DESC_HDR_WORDS : natural := 8;
  constant DESC_EXT_WORDS : natural := 4;
  constant DESC_BASE0     : natural := DESC_HDR_WORDS;   -- = 8, byte 0x40

  -- Error codes.  D uses 0x1..0x8 (ERR_UNIT, ERR_LOCK, ERR_DESC, ERR_WDOG,
  -- ERR_GRANT, ERR_CTX, ERR_EPOCH, ERR_ABORT).  ERR_DESC and ERR_WDOG mean
  -- the same things here and keep D's values; everything A-specific starts at
  -- 0x9 so the two spaces can be merged later without a renumbering.
  constant EC_NONE  : std_logic_vector(3 downto 0) := x"0";
  constant EC_DESC  : std_logic_vector(3 downto 0) := x"3";
  constant EC_WDOG  : std_logic_vector(3 downto 0) := x"4";
  constant EC_GEOM  : std_logic_vector(3 downto 0) := x"9";
  constant EC_MAGIC : std_logic_vector(3 downto 0) := x"A";
  constant EC_VER   : std_logic_vector(3 downto 0) := x"B";
  constant EC_ALIGN : std_logic_vector(3 downto 0) := x"C";
  constant EC_ADDR  : std_logic_vector(3 downto 0) := x"D";
  constant EC_CORE  : std_logic_vector(3 downto 0) := x"E";

  -- ERR_INFO's "the pointer itself, not a descriptor word" sentinel.
  constant EI_PTR : natural := 16#FFFF#;

  -- Word index of the first extension word, i.e. byte 0x40 + 8*(npw+nps).
  function desc_ext0 (npw, nps : positive) return natural;

  -- Total descriptor length in 64-bit words.
  function desc_words(npw, nps : positive) return positive;

  -- Beats the fetch reads at a given AXI data width, rounded up.  Trailing
  -- words in the last beat are ignored.
  function desc_beats(npw, nps : positive; axi_dw : positive) return positive;

end package;

package body matvec_int4_desc_pkg is

  function desc_ext0 (npw, nps : positive) return natural is
  begin
    return DESC_BASE0 + npw + nps;
  end function;

  function desc_words(npw, nps : positive) return positive is
  begin
    return DESC_BASE0 + npw + nps + DESC_EXT_WORDS;
  end function;

  function desc_beats(npw, nps : positive; axi_dw : positive) return positive is
    constant wpb : positive := axi_dw / 64;
  begin
    return (desc_words(npw, nps) + wpb - 1) / wpb;
  end function;

end package body;
