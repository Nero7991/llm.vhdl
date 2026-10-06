-- Jungle Cat loader: die identity reader (Task 9b, Oren 2026-10-05). Drives the pins of an
-- UltraScale+ DNA_PORTE2 from aclk logic and holds the 96-bit value for the status word
-- (bits 351:256, dna_valid at 352). Pure VHDL, no primitives: the DNA_PORTE2 instance
-- lives in the synthesis-only wrapper Task 10 builds (DIN tied '0' there), and GHDL
-- benches use sim/jc_dna_model.vhd in its place.
--
-- WHY: if both dies of a Jungle Cat run the loader, (die=A, chain=AB) and (die=B,
-- chain=BA) put identical traffic on the wire, so a wrong --chain loads the other die
-- with nothing noticing. The host compares this value against a record taken once at
-- bring-up (coe_load.py identify) on every scan open.
--
-- dna_clk: a register-divided clock, one period = 2 * DIV aclk cycles (high for DIV, low
-- for DIV). The DEFAULT DIV = 10 gives 22.5 MHz at a 450 MHz aclk and 10 MHz at 200 MHz;
-- the brief's ceiling is 25 MHz at 450 MHz (DIV >= 9). The 25 MHz figure is the brief's,
-- NOT a datasheet value: the primitive's real maximum CLK is in AMD UG570/DS923, which
-- are not in docs/datasheets/ -- ESTIMATE until Task 10 constrains dna_clk and Task 11
-- reads a die on silicon.
--
-- TIMING OF THE PINS: dna_clk rises on the aclk edge that takes ph from DIV-1 to DIV and
-- falls on the edge that takes it from 2*DIV-1 to 0. dna_read and dna_shift change ONLY
-- on that falling edge, so each is stable for DIV aclk cycles before and DIV after every
-- dna_clk rising edge (>= 1 aclk of setup and hold for any DIV >= 1). dna_dout is
-- sampled on the same falling edge, DIV aclk cycles after the rising edge that moved it.
-- A synchronous reset clears ph and dna_clk together, so a reset can never place a
-- rising edge next to a control change.
--
-- BIT ORDER (ESTIMATE, the same one sim/jc_dna_model.vhd assumes): after the READ edge
-- DOUT already presents dna(0); each SHIFT edge brings the next bit, dna(k) after the
-- k-th. So the sequence is one READ period, then 95 SHIFT periods, sampling DOUT after
-- the READ and after each SHIFT: 96 samples, 95 shifts (a 96th shift would only move
-- DIN into the register, which nothing reads). Samples enter at bit 95 and move down, so
-- the first sample ends in dna(0). If silicon shows the opposite order (the first bit
-- out is dna(95)), Task 11's cross-check against Vivado hardware manager catches it and
-- the fix is the one assembly line marked below.
--
-- After the 96th sample the value is latched, dna_valid rises and stays high until
-- reset, and dna_clk stops (the primitive is never clocked again). dna reads zero until
-- dna_valid.
library ieee;
use ieee.std_logic_1164.all;

entity jc_dna_reader is
  generic(DIV : positive := 10);
  port(
    clk, rst  : in  std_logic;
    dna_clk   : out std_logic;
    dna_read  : out std_logic;
    dna_shift : out std_logic;
    dna_dout  : in  std_logic;
    dna       : out std_logic_vector(95 downto 0);
    dna_valid : out std_logic
  );
end entity;

architecture rtl of jc_dna_reader is
  type state_t is (S_START, S_READ, S_SHIFT, S_DONE);
  signal st   : state_t := S_START;
  signal ph   : natural range 0 to 2 * DIV - 1 := 0;
  signal ck   : std_logic := '0';
  signal rd   : std_logic := '0';
  signal sh   : std_logic := '0';
  signal vld  : std_logic := '0';
  signal nsmp : natural range 0 to 95 := 0;      -- samples taken so far, minus one
  signal sr   : std_logic_vector(95 downto 0) := (others => '0');
  signal val  : std_logic_vector(95 downto 0) := (others => '0');
  -- the one aclk edge per dna_clk period on which READ/SHIFT change and DOUT is sampled:
  -- the dna_clk falling edge, DIV aclk cycles from either neighbouring rising edge
  constant STEP_PH : natural := 2 * DIV - 1;
begin
  dna_clk   <= ck;
  dna_read  <= rd;
  dna_shift <= sh;
  dna       <= val;
  dna_valid <= vld;

  process(clk)
    variable nxt : std_logic_vector(95 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st <= S_START; ph <= 0; ck <= '0'; rd <= '0'; sh <= '0'; vld <= '0';
        nsmp <= 0; sr <= (others => '0'); val <= (others => '0');
      else
        if ph = 2 * DIV - 1 then
          ph <= 0;
        else
          ph <= ph + 1;
        end if;
        if ph = DIV - 1 and st /= S_DONE then
          ck <= '1';                                  -- dna_clk rising edge
        end if;
        if ph = 2 * DIV - 1 then
          ck <= '0';                                  -- dna_clk falling edge
        end if;
        if ph = STEP_PH then
          -- the bit-order assumption (see header): samples enter at the top
          nxt := dna_dout & sr(95 downto 1);
          case st is
            when S_START =>                           -- no edge with READ yet
              rd <= '1';
              st <= S_READ;
            when S_READ =>                            -- READ edge done: DOUT = dna(0)
              rd <= '0'; sh <= '1';
              sr <= nxt; nsmp <= 1;
              st <= S_SHIFT;
            when S_SHIFT =>                           -- SHIFT edge nsmp done
              sr <= nxt;
              if nsmp = 95 then
                sh <= '0';
                val <= nxt;
                vld <= '1';
                st <= S_DONE;
              else
                nsmp <= nsmp + 1;
              end if;
            when S_DONE =>
              null;
          end case;
        end if;
      end if;
    end if;
  end process;
end architecture;
