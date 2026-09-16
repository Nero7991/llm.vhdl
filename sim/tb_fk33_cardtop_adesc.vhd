-- sim/tb_fk33_cardtop_adesc.vhd
--
-- THE FIRST ELABORATION OF THE CARD'S A BINDING, AND A DRIVEN-NESS CHECK ON
-- THE PORTS THAT BINDING LEAVES BEHIND.
--
-- WHY THIS EXISTS.  WORKLOG 9b4477a records that `ga_desc` -- the branch the
-- card actually builds -- has never been simulated.  Every landmark this
-- project quotes for the card top was measured on `ga_real`, a branch the card
-- excludes.  Closing that gap FOR VALUES needs a descriptor-plane engine model
-- in the bench and is real work.  This file does NOT do that, and must not be
-- read as doing it.
--
-- What it does is the part that needs no engine at all: set `A_DESC` true,
-- elaborate, and ask whether every OUTPUT port of the top has a driver.  That
-- is a property of the generate conditions, not of the arithmetic, so no
-- stimulus is required and none is supplied.
--
-- WHAT IT CAUGHT, on the run that introduced it.  `ga_tie` was guarded
-- `if A_BEHAV generate` and `ga_real` `if not A_BEHAV and not A_DESC`, so the
-- card configuration -- A_BEHAV false, A_DESC true -- matched NEITHER, and the
-- six weight-master outputs had no driver in the only configuration that ships.
-- In simulation they read 'U'; in synthesis they are undriven ports into the
-- smartconnect, where an undriven `m_arvalid` is a weight read request that may
-- or may not be issued.  Fixed in tools/gen_cardtop.py.
--
-- TEETH.  This bench FAILS against the pre-fix generator output, which is the
-- only evidence that it checks anything.  MEASURED, and recorded in
-- docs/debugging/ under the dated file for this fix: regenerating the card top
-- from the generator at HEAD~ and running this bench against it reports the six
-- m_* ports undriven.  A check never shown to fail has not been shown to work.
--
-- WHAT IT DELIBERATELY DOES NOT CHECK.  It does not run a job, does not issue
-- `go`, and reads no arithmetic.  `a_awvalid` and friends are checked for a
-- DRIVER, not for protocol: the adapter's AXI-Lite behaviour is
-- `sim/tb_a_desc_adapter`'s subject, and the engine's is
-- `sim/tb_matvec_fk33_desc`'s.  The gap between "driven" and "correct" is the
-- gap WORKLOG 9b4477a names, and this file narrows it by exactly one step.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- A_NPORTS comes from the map package, NOT from a constant restated here.  A
-- bench that restates a width is a second place for it to be wrong, and the
-- widths are exactly what this bench is reading.
use work.llama_map_pkg.all;

entity tb_fk33_cardtop_adesc is
end entity;

architecture tb of tb_fk33_cardtop_adesc is

  -- The card's A binding.  A_BEHAV must be FALSE alongside it: with both set
  -- `ga_behav` wins and this bench would elaborate the arm it is not about,
  -- passing for the wrong reason.
  constant A_DESC_G  : boolean := true;
  constant A_BEHAV_G : boolean := false;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal finished : boolean := false;

  -- ---- the outputs under test ------------------------------------------
  signal m_arvalid : std_logic_vector(A_NPORTS-1 downto 0);
  signal m_araddr  : std_logic_vector(A_NPORTS*32-1 downto 0);
  signal m_arlen   : std_logic_vector(A_NPORTS*8-1 downto 0);
  signal m_arsize  : std_logic_vector(A_NPORTS*3-1 downto 0);
  signal m_arburst : std_logic_vector(A_NPORTS*2-1 downto 0);
  signal m_rready  : std_logic_vector(A_NPORTS-1 downto 0);

  -- The a_* outputs, which `gnd_a` covers.  Checked in the SAME run and by the
  -- same rule, so that the m_* result has a positive control beside it: if
  -- both sets read 'U' the bench is broken, not the RTL.
  signal a_awaddr   : std_logic_vector(11 downto 0);
  signal a_awvalid  : std_logic;
  signal a_wdata    : std_logic_vector(31 downto 0);
  signal a_wstrb    : std_logic_vector(3 downto 0);
  signal a_wvalid   : std_logic;
  signal a_bready   : std_logic;
  signal a_x_we     : std_logic;

  -- `driven` is the whole test.  'U' is the undriven case; 'X' would be a
  -- multiple-driver conflict, which is a different defect and equally fatal,
  -- so both are refused rather than only the one this fix was about.
  function driven(v : std_logic_vector) return boolean is
  begin
    for i in v'range loop
      if v(i) /= '0' and v(i) /= '1' then return false; end if;
    end loop;
    return true;
  end function;

  function driven(s : std_logic) return boolean is
  begin
    return s = '0' or s = '1';
  end function;

begin

  clk <= not clk after 5 ns when not finished else '0';

  dut : entity work.fk33_llama_top
    generic map(
      A_BEHAV => A_BEHAV_G,
      A_DESC  => A_DESC_G)
    port map(
      clk => clk, rst => rst,
      -- THE 18 DEFAULTLESS INPUTS, associated with literals rather than with
      -- declared signals.  The aggregate takes its width from the FORMAL, so
      -- this cannot drift when a generic changes -- which a sized signal
      -- declared here could, silently, in the direction of still compiling.
      go => '0', abort => '0', tok_ack => '0',
      tbl_len => (others => '0'), host_x_exp => (others => '0'),
      rel_mask => (others => '0'),
      d_rdata => (others => '0'), d_rvalid => '0',
      hw_we => '0', hw_reg => 0, hw_addr => 0, hw_data => (others => '0'),
      hr_reg => 0, hr_addr => 0,
      m_rdata => (others => '0'),
      kv_rdata => (others => '0'),
      m_arvalid => m_arvalid, m_araddr => m_araddr, m_arlen => m_arlen,
      m_arsize => m_arsize, m_arburst => m_arburst, m_rready => m_rready,
      a_awaddr => a_awaddr, a_awvalid => a_awvalid,
      a_wdata => a_wdata, a_wstrb => a_wstrb, a_wvalid => a_wvalid,
      a_bready => a_bready, a_x_we => a_x_we);

  drv : process
    -- COUNTED IN VARIABLES, never in signals: consecutive checks inside one
    -- delta collapse to a single signal assignment, and a bench reporting far
    -- fewer checks than it contains passes while measuring nothing.
    variable checks : natural := 0;
    variable bad    : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then
        bad := bad + 1;
        report "FAIL: " & msg severity error;
      end if;
    end procedure;
  begin
    rst <= '1';
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    -- Settle.  A tie-off is combinational and needs no cycles at all, but a
    -- registered default would need one, and waiting costs nothing.
    for i in 1 to 8 loop wait until rising_edge(clk); end loop;

    -- THE CHECK THE FIX IS ABOUT.
    chk(driven(m_arvalid), "m_arvalid has no driver with A_DESC true");
    chk(driven(m_araddr),  "m_araddr has no driver with A_DESC true");
    chk(driven(m_arlen),   "m_arlen has no driver with A_DESC true");
    chk(driven(m_arsize),  "m_arsize has no driver with A_DESC true");
    chk(driven(m_arburst), "m_arburst has no driver with A_DESC true");
    chk(driven(m_rready),  "m_rready has no driver with A_DESC true");

    -- THE POSITIVE CONTROL.  `gnd_a` does not drive these when A_DESC is true
    -- -- `ga_desc` itself does -- so this set being driven says the A binding
    -- elaborated and produced drivers, which is what makes the m_* verdict
    -- above attributable to the tie-off rather than to a dead generate.
    chk(driven(a_awvalid), "a_awvalid has no driver with A_DESC true");
    chk(driven(a_wvalid),  "a_wvalid has no driver with A_DESC true");
    chk(driven(a_bready),  "a_bready has no driver with A_DESC true");
    chk(driven(a_x_we),    "a_x_we has no driver with A_DESC true");
    chk(driven(a_awaddr),  "a_awaddr has no driver with A_DESC true");
    chk(driven(a_wdata),   "a_wdata has no driver with A_DESC true");
    chk(driven(a_wstrb),   "a_wstrb has no driver with A_DESC true");

    report "TB_FK33_CARDTOP_ADESC checks=" & integer'image(checks)
         & " bad=" & integer'image(bad) severity note;
    finished <= true;
    if bad = 0 then
      report "TB_FK33_CARDTOP_ADESC PASS" severity note;
    else
      report "TB_FK33_CARDTOP_ADESC FAIL" severity failure;
    end if;
    wait;
  end process;

end architecture;
