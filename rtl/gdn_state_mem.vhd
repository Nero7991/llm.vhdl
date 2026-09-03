-- rtl/gdn_state_mem.vhd -- ONE GDN layer's recurrent state, as a real memory.
--
-- WHY THIS EXISTS.  `rtl/llama_top.vhd`'s `gb_real` holds the recurrent state
-- for EVERY layer at once, in a process variable `stmem` of `NLY*VH*DM*NBR`
-- words.  MEASURED 2026-09-02 by elaborating this repository's own shape
-- functions against `QWEN35_9B`: that is 201,326,592 bits = 24.0 MB, against
-- 14.2 MB of BRAM plus URAM on the whole `xcvu33p`.  It overruns every
-- on-chip memory the part has, by 1.69x, with nothing left for anything else.
-- See docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md.
--
-- ONE layer is 8,388,608 bits = 1.0 MB and does fit.  The card therefore has
-- to hold one layer resident and stream it to and from HBM per job; this is
-- the resident half.  The HBM half is not written yet.
--
-- THE LANE COUNT CANNOT SHRINK THIS.  The array is `VH*DM*NBR` words of
-- `RECUR_LANES*16` bits with `NBR = DIM/RECUR_LANES`, so the lane term
-- cancels and the extent is `VH*DIM*DIM*16` however it is sliced.  Do not
-- sweep the generic hoping for a fit.
--
-- URAM IS LEGAL HERE, AND THAT IS NOT OBVIOUS GIVEN THIS PROJECT'S HISTORY.
-- `[Synth 8-10226]` refuses `ram_style = ultra` on this device only for a
-- table with NON-ZERO INITIALISATION, which is why the norm gain image is
-- charged in BRAM and why three documents once carried a "114 URAM" that was
-- really the BRAM column.  This store is written at run time and starts at
-- zero, so the refusal does not apply.  It is still not a claim: STYLE is a
-- generic precisely so the census can be taken both ways, and the census
-- wins over anything the inference log says in either direction.
--
-- PORT CONTRACT.  Mirrors `rtl/gdn_block.vhd`'s `st_*` ports exactly, which
-- are a registered read one cycle after the address and a plain write.  A
-- same-address, same-edge access returns the PRE-edge value, matching
-- `llama_top`'s `stmem`.
--
-- THE STATEMENT ORDER BELOW IS NOT WHAT MAKES THAT TRUE HERE, AND AN EARLIER
-- DRAFT OF THIS COMMENT SAID IT WAS.  `mem` is a SIGNAL, so `mem(a) <= w_data`
-- does not take effect until the next delta and the read in the same process
-- sees the pre-edge value whichever way round the two blocks are written.
-- MEASURED: mutant M1 in `sim/tb_gdn_state_mem.vhd` swaps them and the bench
-- does not move -- 2,825 checks, 0 mismatches, including 64 deliberate
-- same-edge collisions.  Read-old is STRUCTURAL here, not a discipline.
-- It IS a discipline in `llama_top`, where `stmem` is a process VARIABLE and
-- the order genuinely decides the answer; that is where the rule belongs and
-- it does not transfer to this file.  Keeping the read first anyway, because
-- it costs nothing and it is what the inference templates expect.
--
-- OPEN, AND IT IS A HARDWARE QUESTION SIMULATION CANNOT SETTLE: whether the
-- URAM implementation preserves read-old on a same-address, same-edge
-- collision.  GHDL says read-old because of the signal semantics above, and
-- Vivado infers a collision mode from the same RTL, but URAM288's
-- read-during-write behaviour is not BRAM's and has NOT been checked here.
-- If `gdn_block` ever reads and writes one state word on one edge, this must
-- be settled against the primitive, not against this file.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gdn_state_mem is
  generic(
    VAL_HEADS   : positive := 32;
    DIM         : positive := 128;
    RECUR_LANES : positive := 4;
    -- "ultra", "block" or "auto".  Not a preference: a knob for the census.
    STYLE       : string   := "ultra"
  );
  port(
    clk    : in  std_logic;

    r_en   : in  std_logic;
    r_head : in  natural range 0 to VAL_HEADS-1;
    r_col  : in  natural range 0 to DIM-1;
    r_grp  : in  natural range 0 to DIM/RECUR_LANES-1;
    r_data : out std_logic_vector(RECUR_LANES*16-1 downto 0);

    w_en   : in  std_logic;
    w_head : in  natural range 0 to VAL_HEADS-1;
    w_col  : in  natural range 0 to DIM-1;
    w_grp  : in  natural range 0 to DIM/RECUR_LANES-1;
    w_data : in  std_logic_vector(RECUR_LANES*16-1 downto 0)
  );
end entity;

architecture rtl of gdn_state_mem is
  constant NBR   : positive := DIM / RECUR_LANES;
  constant WORDS : positive := VAL_HEADS * DIM * NBR;
  constant WBITS : positive := RECUR_LANES * 16;

  type mem_t is array (0 to WORDS-1) of std_logic_vector(WBITS-1 downto 0);
  signal mem : mem_t := (others => (others => '0'));

  -- A generic that is not one of the three legal strings must not silently
  -- become "auto".  Vivado ignores `assert ... severity failure` in synthesis,
  -- so the refusal is an out-of-range `natural`, which it does evaluate.
  --
  -- IT IS ASSIGNED INSIDE A BRANCH, NOT DECLARED AS A CONSTANT, and that is
  -- deliberate.  The first version was `constant bad_style : natural := -1;`
  -- inside a dead generate, and GHDL folds that at ANALYSIS time: it printed
  -- `static expression violates bounds` on every legal build, so the refusal
  -- announced itself loudest exactly when nothing was wrong.  A warning that
  -- fires on every correct compile is noise that trains you to ignore it.
  function chk_style(s : string) return string is
    variable bad : natural;
  begin
    if s = "ultra" or s = "block" or s = "auto" then
      return s;
    end if;
    bad := -s'length;   -- reached only for an illegal STYLE.  NOT the literal
                        -- -1: GHDL folds a literal at ANALYSIS time and warns
                        -- on every legal build.  s'length is a parameter, so
                        -- it cannot be folded, and it is negative for any
                        -- non-empty string, which is every legal call site.
    return s;
  end function;

  constant STY : string(1 to STYLE'length) := chk_style(STYLE);

  attribute ram_style : string;
  attribute ram_style of mem : signal is STY;

  signal rq : std_logic_vector(WBITS-1 downto 0) := (others => '0');
begin
  r_data <= rq;

  p : process(clk) is
    variable a : natural;
  begin
    if rising_edge(clk) then
      -- READ FIRST.  See the header: read-old is the contract.
      if r_en = '1' then
        a := (r_head*DIM + r_col)*NBR + r_grp;
        rq <= mem(a);
      end if;
      if w_en = '1' then
        a := (w_head*DIM + w_col)*NBR + w_grp;
        mem(a) <= w_data;
      end if;
    end if;
  end process;
end architecture;
