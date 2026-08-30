-- readconv_probe.vhd -- TRACK READCONV, 2026-08-29.
--
-- THE QUESTION THIS EXISTS TO ANSWER.  The track was dispatched to convert
-- subsystem B's flat whole-vector READ ports to a streaming interface, on
-- TRACK LUTDIET's finding that B's read muxes are 8.9% of its LUT primitives.
-- Before rewriting gdn_block and l2norm_rs for it, the premise itself is
-- measured: DOES NARROWING THE READ PORT MAKE THE READ CHEAPER?
--
-- The two shapes, at IDENTICAL total storage and an identical write decode:
--
--   readconv_flat  SELW = 128   one whole 128-element head per beat  (l2_x)
--   readconv_flat  SELW = 4     LANES per beat, the streaming form
--   readconv_flat  SELW = 1     one element per beat
--   readconv_dram  WLANES       the same streaming form, but with the store
--                               declared as an array and forced to LUT-based
--                               distributed RAM instead of a flat register
--
-- The write decode is TRACK WRITEDEC's per-word generate with a CONSTANT slice
-- index in EVERY variant, so the write cost is the same in all of them and
-- cannot confound the read comparison.  The read output is a registered PORT,
-- so the mux cannot be optimised into a consumer that is not there.
--
-- gdn_block's real numbers are the defaults here: KEY_HEADS = 16, DIM = 128,
-- so qbuf and kbuf are 2,048 x 16b = 32,768 bits each and l2_x selects
-- 128 words of them.
--
-- NO HARDWARE.  Synthesis only.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

-- ---------------------------------------------------------------------------
-- The flat-register store, exactly gdn_block's qbuf.
-- ---------------------------------------------------------------------------
entity readconv_flat is
  generic(
    NW     : positive := 2048;   -- 16-bit words in the store
    WLANES : positive := 4;      -- words written per beat
    SELW   : positive := 128     -- words presented on the read port
  );
  port(
    clk     : in  std_logic;
    rst     : in  std_logic;
    w_valid : in  std_logic;
    w_idx   : in  integer range 0 to NW/WLANES-1;
    w_data  : in  std_logic_vector(WLANES*16-1 downto 0);
    r_idx   : in  integer range 0 to NW/SELW-1;
    r_data  : out std_logic_vector(SELW*16-1 downto 0)
  );
end entity;

architecture rtl of readconv_flat is
  signal buf : std_logic_vector(NW*16-1 downto 0) := (others => '0');
begin
  -- WRITEDEC's write decode, identical in every variant.
  gw : for wi in 0 to NW/WLANES-1 generate
    process(clk) begin
      if rising_edge(clk) then
        if rst = '0' and w_valid = '1' and w_idx = wi then
          buf((wi+1)*WLANES*16-1 downto wi*WLANES*16) <= w_data;
        end if;
      end if;
    end process;
  end generate;

  -- THE READ UNDER TEST.  A variable-index slice of a flat register.
  process(clk) begin
    if rising_edge(clk) then
      r_data <= buf((r_idx+1)*SELW*16-1 downto r_idx*SELW*16);
    end if;
  end process;
end architecture;

-- ---------------------------------------------------------------------------
-- The same contract, streamed, with the store as LUT-based distributed RAM.
-- This is the variant a streaming read port makes POSSIBLE and a whole-vector
-- port does not: a memory can only present one word per cycle.
-- ---------------------------------------------------------------------------
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity readconv_dram is
  generic(
    NW     : positive := 2048;
    WLANES : positive := 4
  );
  port(
    clk     : in  std_logic;
    rst     : in  std_logic;
    w_valid : in  std_logic;
    w_idx   : in  integer range 0 to NW/WLANES-1;
    w_data  : in  std_logic_vector(WLANES*16-1 downto 0);
    r_idx   : in  integer range 0 to NW/WLANES-1;
    r_data  : out std_logic_vector(WLANES*16-1 downto 0)
  );
end entity;

architecture rtl of readconv_dram is
  type ram_t is array(0 to NW/WLANES-1) of std_logic_vector(WLANES*16-1 downto 0);
  signal ram : ram_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of ram : signal is "distributed";
begin
  process(clk) begin
    if rising_edge(clk) then
      if rst = '0' and w_valid = '1' then
        ram(w_idx) <= w_data;
      end if;
      r_data <= ram(r_idx);
    end if;
  end process;
end architecture;
