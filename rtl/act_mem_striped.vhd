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

  -- FLAT, not an array of arrays.  A nested array here does not infer BRAM:
  -- Vivado warns [Synth 8-11357] "RAM from Record/Structs" and builds the whole
  -- thing out of registers -- 278,528 of them at ELEMS=17408, on a device with
  -- 141K.  Flattening also collapses the mapping arithmetic, because
  --     bank*(LANES*W) + lane*W  ==  W * (k mod BLK)
  -- identically once LANES divides BLK.  The bank/lane split of 7.8 is then the
  -- PHYSICAL arrangement Vivado derives for itself from a BLK*W-wide word; it
  -- does not need to be, and must not be, spelled out in the type.
  type mem_t is array(0 to WORDS-1) of std_logic_vector(BLK*W-1 downto 0);
  signal mem : mem_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";

  signal rw : std_logic_vector(BLK*W-1 downto 0) := (others => '0');
begin
  assert BLK mod LANES = 0
    report "act_mem_striped: BLK must be a whole number of LANES"
    severity failure;

  process(clk)
    variable a    : integer;
    variable word : integer;
    variable lane : integer;
  begin
    if rising_edge(clk) then
      if we = '1' then
        a    := to_integer(unsigned(waddr));
        word := a / BLK;
        lane := a mod BLK;            -- == bank*LANES + lane, see above
        -- CONSTANT slice bounds with a decoded enable: this is the byte-write-
        -- enable pattern Vivado recognises.  A variable-offset slice write --
        -- mem(word)(off+W-1 downto off) -- is NOT: Vivado decomposes it into
        -- PER-BIT write enables and reports
        --   [Synth 8-6841] byte width (1) is not a multiple of 8
        -- then emits one width-1 block RAM per data bit.  At BLK*W = 512 that
        -- is 512 RAMB18 for a 278 Kb memory, i.e. 256 of the ZU3EG's 216 tiles
        -- spent on one array.  Same stored bits, same behaviour in simulation.
        for j in 0 to BLK-1 loop
          if lane = j then
            mem(word)((j+1)*W-1 downto j*W) <= wdata;
          end if;
        end loop;
      end if;
      rw <= mem(to_integer(unsigned(rbaddr)));
    end if;
  end process;

  -- reassembly is pure wiring: element j of the block lives in bank j/LANES,
  -- lane j mod LANES, of the one word all BANKS banks were read at.
  -- element j of the block is at bit j*W, by the identity above
  rdata <= rw;
end architecture;
