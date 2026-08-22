-- rtl/act_mem_striped.vhd -- banked activation memory for subsystem A.
--
-- Spec: docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md  7.8
--
-- WHY THIS EXISTS.  vec_mem.vhd is 32 bits wide with a single read port, so it
-- cannot serve a whole BLOCK per cycle; rev 1 of the spec claimed the activation
-- port followed vec_mem's convention and that was wrong.  matvec_core consumes
-- BLOCK activations every cycle, shared across all ROWS_IF rows -- which is
-- exactly why the design scales to ROWS_IF=80 on the FK33 without an activation
-- bandwidth problem: this read width does NOT grow with ROWS_IF.
--
-- MAPPING (normative, 7.8).  "element k in bank k mod 8" does not pin this down,
-- so all three coordinates are stated:
--
--     bank = (k mod BLOCK) / LANES      word = k / BLOCK      lane = k mod LANES
--
-- A block of BLOCK consecutive elements therefore occupies ONE word in each of
-- the BANKS banks, so the whole block is read in a single cycle with no muxing:
-- the read address is simply the block index.
--
-- Producers (rmsnorm, swiglu, ...) emit one W-bit element per cycle, so the
-- write side is a lane-granular write into a LANES*W-bit word.  With W a
-- multiple of 8 this infers the SDP BRAM36 byte-write-enable natively.
--
-- Read latency is 1 CYCLE (registered), matching vec_mem and kv_mem, so the
-- consumer issues rbaddr one cycle ahead exactly as matmul_rt does.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity act_mem_striped is
  generic(
    ELEMS : positive := 17408;   -- spec 14.1, 27B FFN
    BLK   : positive := 32;      -- must match matvec_core's BLK
    LANES : positive := 4;       -- elements per BRAM word
    W     : positive := 16
  );
  port(
    clk    : in  std_logic;
    -- producer side: one element per cycle
    we     : in  std_logic;
    waddr  : in  std_logic_vector(clog2(ELEMS)-1 downto 0);
    wdata  : in  std_logic_vector(W-1 downto 0);
    -- consumer side: one whole block per cycle, addressed BY BLOCK INDEX
    rbaddr : in  std_logic_vector(clog2((ELEMS+BLK-1)/BLK)-1 downto 0);
    rdata  : out std_logic_vector(BLK*W-1 downto 0)
  );
end entity;

architecture rtl of act_mem_striped is
  constant BANKS : positive := BLK / LANES;
  constant WORDS : positive := (ELEMS + BLK - 1) / BLK;

  type word_t is array(0 to BANKS-1) of std_logic_vector(LANES*W-1 downto 0);
  type mem_t  is array(0 to WORDS-1) of word_t;
  signal mem : mem_t := (others => (others => (others => '0')));

  signal rw : word_t := (others => (others => '0'));
begin
  assert BLK mod LANES = 0
    report "act_mem_striped: BLK must be a whole number of LANES"
    severity failure;

  process(clk)
    variable a    : integer;
    variable bank : integer;
    variable word : integer;
    variable lane : integer;
  begin
    if rising_edge(clk) then
      if we = '1' then
        a    := to_integer(unsigned(waddr));
        bank := (a mod BLK) / LANES;
        word := a / BLK;
        lane := a mod LANES;
        mem(word)(bank)((lane+1)*W-1 downto lane*W) <= wdata;
      end if;
      rw <= mem(to_integer(unsigned(rbaddr)));
    end if;
  end process;

  -- reassembly is pure wiring: element j of the block lives in bank j/LANES,
  -- lane j mod LANES, of the one word all BANKS banks were read at.
  wire : for j in 0 to BLK-1 generate
    rdata((j+1)*W-1 downto j*W) <=
      rw(j / LANES)(((j mod LANES)+1)*W-1 downto (j mod LANES)*W);
  end generate;
end architecture;
