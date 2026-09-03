-- rtl/gdn_exp_mem.vhd -- ONE GDN layer's state EXPONENTS.
--
-- `VAL_HEADS x DIM` entries of 8 bits: 4,096 bytes at the 9B shape, which is
-- exactly `gdn_state_exp_bytes_per_layer` in the manifest arena.  This is
-- `semem` in `rtl/llama_top.vhd`, sized for ONE layer instead of all 24 for
-- the same reason the mantissa store is
-- (docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md).
--
-- IT CANNOT BE BRAM OR URAM, AND THAT IS NOT A CHOICE.  `rtl/gdn_block.vhd`
-- labels this port "state exponent table, COMBINATIONAL read" (:317) and means
-- it: `se_rhead`/`se_rcol` are driven combinationally from the recurrence
-- pipeline's own address (:632-633) and `se_rdata` is consumed on the SAME
-- edge (:1203, `rp_cse <= se_rdata` in the cycle `st_first_i` is high).  A
-- block RAM has a registered read and a URAM has a registered read; neither
-- can serve an asynchronous port.  This repository has the general lesson on
-- record at cost: `region_mem` inferred ZERO BRAM and 91,073 LUT because of a
-- single combinational read port, and the array's shape was never the cause.
--
-- So this is DISTRIBUTED RAM, deliberately, and the cost is real rather than
-- free.  `STYLE` is a generic so the census can be taken both ways rather
-- than the attribute being asserted to work -- Vivado's inference log has
-- been measured lying in both directions in this project, including
-- `[Synth 8-7186]` claiming `ram_style = "distributed"` was ignored for
-- objects that ARE `RAM32M16` in the same run's mapping report.
--
-- THE WRITE IS SYNCHRONOUS AND THE UNIT'S READ IS NOT.  That asymmetry is
-- what distributed RAM is, and it is also why read-during-write needs no
-- discussion here: an asynchronous read reflects the write the moment it
-- lands, which is the behaviour `llama_top`'s signal-based `semem` had.  The
-- MOVER's read is registered on the way out for a reason that has nothing to
-- do with the array; see the `m_r_data` port comment.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gdn_exp_mem is
  generic(
    VAL_HEADS : positive := 32;
    DIM       : positive := 128;
    -- "distributed" or "auto".  NOT "block" or "ultra": both have a
    -- registered read and cannot serve this port at all, so offering them
    -- would be offering a wrong answer.
    STYLE     : string   := "distributed"
  );
  port(
    clk : in std_logic;

    -- combinational read, matching gdn_block's se_* contract exactly
    r_head : in  natural range 0 to VAL_HEADS-1;
    r_col  : in  natural range 0 to DIM-1;
    r_data : out signed(7 downto 0);

    -- synchronous write
    w_en   : in  std_logic;
    w_head : in  natural range 0 to VAL_HEADS-1;
    w_col  : in  natural range 0 to DIM-1;
    w_data : in  signed(7 downto 0);

    -- the mover's port, 8-bit words, flat within the layer.  Separate from
    -- the unit's port because the caller arbitrates; see gdn_state_store.
    --
    -- `m_r_data` IS REGISTERED AND THE UNIT'S `r_data` IS NOT, AND THAT
    -- ASYMMETRY IS DELIBERATE.  `gdn_state_axi` registers the address it
    -- issues and then collects the word TWO edges later, because that is what
    -- `gdn_state_mem` (a block/ultra RAM) does.  Handing it an ASYNCHRONOUS
    -- read would present each word one edge EARLY, and since the mover walks
    -- a new address every cycle the word it collected would be the NEXT one:
    -- every saved exponent block shifted by exactly one byte, wrapping at the
    -- beat.  That is a wrong number, not a hang, and it is the same defect
    -- this project already paid for once on the mantissa path
    -- (docs/debugging/2026-09-02_gdn-state-dma.md, defect D2).
    --
    -- The flop costs 8 FF and changes nothing about the ARRAY: the read is
    -- still asynchronous out of the memory, with a register on the way out.
    -- The unit's port, which must stay asynchronous, is untouched.
    m_r_addr : in  natural range 0 to VAL_HEADS*DIM-1;
    m_r_data : out signed(7 downto 0);
    m_w_en   : in  std_logic;
    m_w_addr : in  natural range 0 to VAL_HEADS*DIM-1;
    m_w_data : in  signed(7 downto 0)
  );
end entity;

architecture rtl of gdn_exp_mem is
  constant N : positive := VAL_HEADS * DIM;

  type mem_t is array (0 to N-1) of signed(7 downto 0);
  signal mem : mem_t := (others => (others => '0'));

  -- Refuse a STYLE this port cannot honour, as an out-of-range `natural`
  -- rather than an assert: Vivado ignores `assert ... severity failure` in
  -- synthesis.  Assigned inside a branch rather than declared as a literal
  -- constant, because GHDL folds a literal at ANALYSIS time and then warns on
  -- every legal build.
  function chk_style(s : string) return string is
    variable bad : natural;
  begin
    if s = "distributed" or s = "auto" then
      return s;
    end if;
    bad := -s'length;
    return s;
  end function;

  constant STY : string(1 to STYLE'length) := chk_style(STYLE);

  attribute ram_style : string;
  attribute ram_style of mem : signal is STY;
begin
  -- The unit's read is asynchronous because gdn_block consumes it on the same
  -- edge it drives the address (:632-633 and :1203).  The mover's is
  -- registered because gdn_state_axi expects a two-edge memory; see the port
  -- comment.
  r_data   <= mem(r_head*DIM + r_col);

  p : process(clk) is
  begin
    if rising_edge(clk) then
      m_r_data <= mem(m_r_addr);
      -- The mover and the unit never write together: the caller gates the
      -- unit off while the mover owns the store, and gdn_state_store asserts
      -- that it does.  Written as elsif rather than as two ifs so that a
      -- violation is a lost write in ONE place rather than a race.
      if m_w_en = '1' then
        mem(m_w_addr) <= m_w_data;
      elsif w_en = '1' then
        mem(w_head*DIM + w_col) <= w_data;
      end if;
    end if;
  end process;
end architecture;
