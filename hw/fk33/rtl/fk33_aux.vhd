--------------------------------------------------------------------------------
-- fk33_aux -- observability and autonomy on a clock that does not depend on PCIe
--------------------------------------------------------------------------------
-- WHY THIS EXISTS
-- ---------------
-- In the fk33_pcieep endpoint bitstream the ENTIRE AXI fabric is clocked by
-- xdma/axi_aclk and reset by xdma/axi_aresetn, both of which come out of the
-- PCIe hard block.  With the link down, every AXI-Lite transaction fails and
-- returns -1, so the card is indistinguishable over JTAG from a dead card.
--
-- A first-fit handoff (docs/2026-08-28_fk33-first-fit-handoff.md) assumed the
-- ILA debug hub survived that, on the strength of this XDC line:
--
--     connect_debug_port dbg_hub/clk \
--         [get_nets bd_i/hbm/inst/TWO_STACK.u_hbm_top/APB_0_PCLK]
--
-- THAT ASSUMPTION IS WRONG, and reading the generator settles it without a
-- card.  In build_fk33_i2cprobe.tcl, inside the EnablePCIe == 1 branch:
--
--     connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins clk_wiz_0/clk_in1]
--     connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins clk_wiz_0/resetn]
--     connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_0_PCLK]
--
-- so APB_0_PCLK is an MMCM output whose REFERENCE is xdma/axi_aclk and whose
-- MMCM is held in reset by xdma/axi_aresetn.  It is not free-running at all.
-- There is no clock in the shipped endpoint design that survives the link
-- being down.  This module creates one.
--
-- WHERE THE FREE-RUNNING CLOCK COMES FROM
-- ---------------------------------------
-- The FK33 carries a 200 MHz board oscillator on BC26/BC27 (sysref_clk).  Every
-- EnablePCIe == 0 bitstream in this repository -- first light, the HBM
-- bandwidth sweeps, the I2C probe -- is clocked from nothing else, and all of
-- them have been configured and exercised on this card with no host and no PCIe
-- link.  So that oscillator is EMPIRICALLY known to run with the slot dead.
-- The endpoint build simply never used it.  This module takes it, buffers it
-- with a plain BUFG (no MMCM, so nothing to lock and nothing to hold in reset),
-- and everything below runs on it.
--
-- WHAT IT MEASURES, AND WHY EACH ONE SEPARATES A REAL PAIR OF HYPOTHESES
-- ---------------------------------------------------------------------
--   UCLK_TICKS /      Is the PCIe hard block clocked at all?  UCLK_HZ is a real
--   UCLK_HZ           frequency measurement of xdma/axi_aclk, not a liveness
--                     bit, so 250 MHz, a wrong rate and dead are three distinct
--                     readings.  Read WITH the PERST# level it answers the
--                     question the task actually asked -- is the host supplying
--                     a reference clock -- by elimination:
--                       PERST# high AND UCLK_HZ 0  -> the block is out of reset
--                         and still has no clock.  The host is not driving the
--                         reference clock; a PCH that disabled the root port
--                         also gates its SRC clock.
--                       PERST# low  AND UCLK_HZ 0  -> we are simply being held
--                         in reset.  Says nothing about the reference clock.
--                       UCLK_HZ ~250 MHz           -> reference clock present,
--                         PLL locked, block running.  A down link is then a
--                         TRAINING failure, not a missing clock.
--
--                     A DIRECT measurement of pcie_refclk was designed, built
--                     and REJECTED: it needs a second BUFG_GT on the
--                     IBUFDS_GTE4 ODIV2 tap, and DRC BFGTL-1 forbids that
--                     because two BUFG_GTs sharing one GT clock source must
--                     have identical CE and CLR nets -- xdma drives its own
--                     from an internal BUFG_GT_SYNC that is not exposed.  See
--                     the debugging note; do not retry it.
--   PERST/PERSTMS     Is the host holding us in reset, or did it release us and
--                     we failed to train?  PERSTMS additionally timestamps the
--                     first deassertion against configuration, which is the
--                     only way to measure the flash-boot configuration-time
--                     race from inside the part.
--   AXI_ARESETN       The fabric's own reset state, so "the fabric is held" is
--                     directly observable rather than inferred from -1 reads.
--   USER_LNK_UP       The PCIe block's link-up output.
--
-- LTSSM is deliberately NOT here: xdma 4.1 exposes no LTSSM pin unless
-- CONFIG.enable_ltssm_dbg (or CONFIG.en_debug_ports) is turned on, which is a
-- change to the IP configuration.  See the debugging note.
--
-- WHAT IT DOES AUTONOMOUSLY
-- -------------------------
-- Raises VCCINT.  The rail powers up at 0.678 V, under the 0.698 V floor of the
-- -2L grade, and the fix is a VOLATILE digital-pot wiper lost on every power
-- cycle.  Until now that fix needed the probe bitstream's GPIO over JTAG, and
-- the probe bitstream has no PCIe -- the chicken and egg the handoff calls
-- Obstacle 2.  On a free-running clock the state machine below bit-bangs the
-- same I2C sequence with no AXI, no JTAG and no host, a few milliseconds after
-- configuration, so a flash-booted card is in spec before it tries to train.
--
-- SAFETY, ENFORCED BY CONSTRUCTION RATHER THAN BY CARE
--   * The wiper value is the constant C_WIPER_BYTE.  It is the ONLY byte this
--     machine can ever put in the data position of a pot write.  There is no
--     register holding a target, nothing computes it and nothing outside can
--     set it, so this controller is structurally incapable of writing any other
--     value and therefore incapable of overshooting.  68 measures 0.717 V, well
--     inside the 0.698..0.742 V window that is in spec for BOTH -2L and -2LV.
--     It is NOT SQRL's 0.850 V and must never become it.
--   * It reads the wiper BEFORE writing and refuses to write unless the device
--     acknowledges and the current wiper is inside 60..128, the same sanity
--     band tcl/vccint_step.tcl enforces.
--   * It reads the wiper back AFTER writing and reports a mismatch.
--   * Every intermediate wiper between the 128 power-up default and 68 is a
--     LOWER voltage than 68 gives, so a single direct write cannot transit
--     through an overvoltage; the stepping in the Tcl script existed to
--     characterise dV/dwiper, which is now measured and known.
--   * A hard timeout releases the bus whatever happens, so a wedged state
--     machine cannot sit on the board's I2C bus forever.
--   * The bus is open-drain exactly as the Tcl does it: the output value is
--     always '0' and only the tristate moves, so no line is ever driven high.
--   * At reset the controller does not own the bus, and it hands it back the
--     moment it is done, so host/fk33ctl.py vccint over the AXI GPIO keeps
--     working unchanged once a link is up.
--
-- CLOCK DOMAIN CROSSINGS
-- ----------------------
-- Every crossing into the aux domain is a SINGLE BIT through a two-stage
-- ASYNC_REG synchroniser.  There is deliberately no multi-bit CDC anywhere:
-- the user-clock counter is NOT transported across, a divided single-bit
-- toggle is, and the counting happens on this side.
--
-- NOTE ON WHAT "the read path must not touch xdma/axi_aclk" MEANS HERE.  The
-- divider that measures the user clock is, necessarily, clocked by it.  That is
-- a MEASURED SIGNAL, not part of the read path: if axi_aclk stops, the divider
-- stops, the synchronised toggle goes static, the counters read zero, and every
-- register in this module still reads out normally over jtag_aux.  Nothing
-- between the JTAG chain and a register value is clocked by anything xdma
-- drives.  That is why a plain
-- asynchronous clock group is a sufficient and correct constraint here, with no
-- bus-skew obligation.  See the set_clock_groups line in fk33_pcieep.xdc.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity fk33_aux is
  generic (
    -- Frequency of the free-running board oscillator, in Hz.  Everything timed
    -- in this module is derived from it, so it must match the real clock.
    G_CLK_HZ     : natural := 200000000;
    -- HARDCODED VCCINT target.  See the safety note above.  Do not parameterise
    -- this from the build script: the whole point is that the bitstream can
    -- only ever write one value.
    G_POT_WIPER  : natural := 68;
    G_POT_ADDR   : natural := 44;          -- 0x2C, the MCP45xx digital pot
    -- Delay from configuration to the first I2C edge.  The PMIC has been alive
    -- since the board powered up, hundreds of milliseconds before the FPGA
    -- finished configuring, so this only has to cover the aux clock settling.
    G_START_MS   : natural := 10;
    G_TIMEOUT_MS : natural := 200;
    -- Expected xdma/axi_aclk rate, used only to decide the UCLK_ALIVE bit.
    -- The measured value is reported regardless.
    G_UCLK_HZ    : natural := 250000000
  );
  port (
    -- Free-running 200 MHz sysref, straight off the IBUFDS.  Unbuffered: the
    -- BUFG is instantiated in here so the buffered net has a name the XDC can
    -- find for connect_debug_port.
    clk_free_in   : in    std_logic;
    -- The PCIe USER clock, xdma/axi_aclk.  Measured, not used: it clocks the
    -- divider below and NOTHING else, and its only route out of that divider is
    -- a single-bit toggle through a synchroniser.  If it stops, the divider
    -- stops, the counters read zero and every register here still reads out
    -- normally over jtag_aux.  See the header note on why this is not the
    -- reference clock.
    xdma_aclk     : in    std_logic;

    -- Asynchronous status inputs.  None of these is used as a clock or a reset.
    perstn        : in    std_logic;   -- PCIe PERST#, active low, from BE24
    xdma_aresetn  : in    std_logic;   -- the AXI fabric's own reset
    user_lnk_up   : in    std_logic;   -- xdma link-up

    -- Channel 1 of axi_gpio_0, the host/JTAG I2C bit-bang path.  Bit 0 is SCL
    -- (BB24), bit 1 is SDA (BA24), tristate 1 = released.
    gpio_o        : in    std_logic_vector(1 downto 0);
    gpio_t        : in    std_logic_vector(1 downto 0);
    gpio_i        : out   std_logic_vector(1 downto 0);

    -- The two I2C balls themselves.  The IOBUFs live in here so the arbitration
    -- between the GPIO and the autonomous controller is explicit and visible in
    -- one place rather than spread across the block design.
    i2c_io        : inout std_logic_vector(1 downto 0);

    -- The aux domain, published for the rest of the block design.
    aux_clk       : out   std_logic;
    aux_aresetn   : out   std_logic;

    -- Status words.  All are in the aux domain and are read over a JTAG-AXI
    -- master that touches nothing clocked by xdma.
    stat_magic    : out   std_logic_vector(31 downto 0);
    stat_version  : out   std_logic_vector(31 downto 0);
    stat_uclkticks: out   std_logic_vector(31 downto 0);
    stat_uclkhz   : out   std_logic_vector(31 downto 0);
    stat_status   : out   std_logic_vector(31 downto 0);
    stat_pot      : out   std_logic_vector(31 downto 0);
    stat_ms       : out   std_logic_vector(31 downto 0);
    stat_perstms  : out   std_logic_vector(31 downto 0)
  );
end entity fk33_aux;

architecture rtl of fk33_aux is

  ------------------------------------------------------------------------------
  -- Compile-time constants
  ------------------------------------------------------------------------------
  -- "AUX1".  Recognisable in a hex dump and impossible to confuse with a bus
  -- returning all-zeroes or all-ones, which is what an unanswered read gives.
  constant C_MAGIC       : std_logic_vector(31 downto 0) := x"41555831";
  constant C_VERSION     : std_logic_vector(31 downto 0) := x"20260828";

  constant C_WIPER_BYTE  : std_logic_vector(7 downto 0) :=
      std_logic_vector(to_unsigned(G_POT_WIPER, 8));
  constant C_ADDR_W      : std_logic_vector(7 downto 0) :=
      std_logic_vector(to_unsigned(G_POT_ADDR * 2, 8));         -- 0x58
  constant C_ADDR_R      : std_logic_vector(7 downto 0) :=
      std_logic_vector(to_unsigned(G_POT_ADDR * 2 + 1, 8));     -- 0x59
  constant C_WIPER_LO    : natural := 60;    -- sanity band, same as the Tcl
  constant C_WIPER_HI    : natural := 128;

  -- One "lines" step, the unit tcl/vccint_step.tcl moves the bus in.  Three
  -- steps make one bit, so 5 us per step is a ~67 kHz SCL: comfortably inside
  -- the MCP45xx's rating with no reliance on edge rates.
  constant C_STEP_CYCLES : natural := G_CLK_HZ / 200000;
  constant C_MS_CYCLES   : natural := G_CLK_HZ / 1000;

  constant C_UCLK_LO     : natural := G_UCLK_HZ - G_UCLK_HZ / 10;
  constant C_UCLK_HI     : natural := G_UCLK_HZ + G_UCLK_HZ / 10;

  ------------------------------------------------------------------------------
  -- The free-running clock and its power-on reset
  ------------------------------------------------------------------------------
  -- fk33_freeclk is the net the XDC hunts for with get_nets -hier when it moves
  -- dbg_hub/clk off the dead MMCM output.  KEEP and DONT_TOUCH so the name
  -- survives synthesis; the build fails loudly in the XDC if it does not.
  signal fk33_freeclk : std_logic;
  attribute keep       : string;
  attribute dont_touch : string;
  attribute keep       of fk33_freeclk : signal is "true";
  attribute dont_touch of fk33_freeclk : signal is "true";

  signal por_sr : std_logic_vector(15 downto 0) := (others => '0');

  ------------------------------------------------------------------------------
  -- PCIe user-clock domain: a divider only.  Nothing else lives here, because
  -- this clock is exactly the thing that may not exist.
  ------------------------------------------------------------------------------
  signal uclk_g  : std_logic;
  signal uclk_div   : unsigned(7 downto 0) := (others => '0');
  signal uclk_tgl   : std_logic;

  ------------------------------------------------------------------------------
  -- Synchronisers.  Every one of these is a single bit.
  ------------------------------------------------------------------------------
  signal syn_uclk   : std_logic_vector(2 downto 0) := (others => '0');
  -- Three stages, not two: (0) and (1) are the ASYNC_REG synchroniser and (1)
  -- is the level, (2) is a delayed copy of (1) so the edge detector compares
  -- two FULLY SYNCHRONISED samples.  Comparing (0) with (1) would detect the
  -- edge a cycle earlier off a single-stage sample, which is exactly the thing
  -- a synchroniser exists to stop anyone doing.
  signal syn_perst : std_logic_vector(2 downto 0) := (others => '0');
  signal syn_arst  : std_logic_vector(1 downto 0) := (others => '0');
  signal syn_lnk   : std_logic_vector(1 downto 0) := (others => '0');
  signal syn_sda   : std_logic_vector(1 downto 0) := (others => '0');

  attribute async_reg : string;
  attribute async_reg of syn_uclk   : signal is "TRUE";
  attribute async_reg of syn_perst : signal is "TRUE";
  attribute async_reg of syn_arst  : signal is "TRUE";
  attribute async_reg of syn_lnk   : signal is "TRUE";
  attribute async_reg of syn_sda   : signal is "TRUE";

  ------------------------------------------------------------------------------
  -- Aux-domain state
  ------------------------------------------------------------------------------
  signal ms_div    : unsigned(19 downto 0) := (others => '0');
  signal ms_cnt    : unsigned(31 downto 0) := (others => '0');
  signal ms_tick   : std_logic := '0';

  signal uclkticks  : unsigned(31 downto 0) := (others => '0');
  signal win_cnt   : unsigned(31 downto 0) := (others => '0');
  signal win_edges : unsigned(24 downto 0) := (others => '0');
  signal uclkhz     : unsigned(31 downto 0) := (others => '0');
  signal uclk_ever  : std_logic := '0';
  signal uclk_alive : std_logic := '0';

  signal perst_init  : std_logic := '0';
  signal perst_seen  : std_logic := '0';   -- has perst_init been captured yet
  signal perst_ev0   : std_logic := '0';
  signal perst_ev1   : std_logic := '0';
  signal perst_rise  : unsigned(3 downto 0) := (others => '0');
  signal perst_ms    : unsigned(31 downto 0) := (others => '0');
  signal perst_ms_ok : std_logic := '0';

  signal arst_ever : std_logic := '0';
  signal lnk_ever  : std_logic := '0';

  ------------------------------------------------------------------------------
  -- The I2C sequencer
  ------------------------------------------------------------------------------
  type t_st is (ST_WAIT, ST_SETUP, ST_COND, ST_BIT, ST_STAGE_DONE,
                ST_XACT_DONE, ST_DONE, ST_FAIL);
  signal st : t_st := ST_WAIT;

  -- 0 = read the wiper, 1 = write the wiper, 2 = read it back
  signal xact  : unsigned(1 downto 0) := (others => '0');
  signal stage : unsigned(2 downto 0) := (others => '0');
  signal ph    : unsigned(1 downto 0) := (others => '0');
  signal bidx  : unsigned(3 downto 0) := (others => '0');

  signal step_cnt : unsigned(19 downto 0) := (others => '0');
  signal step_end : std_logic;

  signal sh    : std_logic_vector(7 downto 0) := (others => '0');
  signal rxb   : std_logic_vector(7 downto 0) := (others => '0');
  signal wip_hi : std_logic_vector(7 downto 0) := (others => '0');
  signal wip_lo : std_logic_vector(7 downto 0) := (others => '0');
  signal nack  : std_logic := '0';

  signal attempts : unsigned(3 downto 0) := (others => '0');
  signal fail_why : unsigned(2 downto 0) := (others => '0');
  signal pot_own  : std_logic := '0';
  signal scl_r    : std_logic := '1';
  signal sda_r    : std_logic := '1';

  -- stage opcodes
  constant OP_IDLE  : integer := 0;   -- hold both lines released
  constant OP_START : integer := 1;
  constant OP_STOP  : integer := 2;
  constant OP_WBYTE : integer := 3;
  constant OP_RACK  : integer := 4;   -- read a byte, then ACK it
  constant OP_RNAK  : integer := 5;   -- read a byte, then NAK it
  constant OP_END   : integer := 6;

  signal op_now   : integer range 0 to 6;
  signal data_now : std_logic_vector(7 downto 0);

  -- pin plumbing
  signal pin_i : std_logic_vector(1 downto 0);
  signal pin_o : std_logic_vector(1 downto 0);
  signal pin_t : std_logic_vector(1 downto 0);

begin

  ------------------------------------------------------------------------------
  -- A controller that can only ever write one value cannot overshoot.  If this
  -- generic is ever changed the build stops here rather than producing a
  -- bitstream that quietly moves the rail somewhere else.
  ------------------------------------------------------------------------------
  assert G_POT_WIPER = 68
    report "fk33_aux: G_POT_WIPER must be 68 (0.717 V). Refusing to build."
    severity failure;

  -- One I2C step has to be several clocks longer than the SDA synchroniser is
  -- deep, or the bit sampled at the end of the SCL-high phase is data from the
  -- PREVIOUS phase and every read comes back skewed.  Found by simulating at
  -- 200 kHz, where C_STEP_CYCLES collapses to 1 and the pot appears to NACK.
  -- At the real 200 MHz this is 1000.
  assert C_STEP_CYCLES >= 8
    report "fk33_aux: G_CLK_HZ is too low; one I2C step must be at least 8 "
           & "clocks so the SDA synchroniser settles inside a phase."
    severity failure;

  ------------------------------------------------------------------------------
  -- Free-running clock.  A plain BUFG, so there is no MMCM to lock, no LOCKED
  -- to wait for, and nothing that a dead PCIe block can hold in reset.
  ------------------------------------------------------------------------------
  u_bufg : BUFG
    port map (I => clk_free_in, O => fk33_freeclk);

  aux_clk <= fk33_freeclk;

  -- Power-on reset for the aux AXI branch only.  Everything in this module uses
  -- flip-flop initial values instead, so the measurements start at
  -- configuration and not at some later reset release.
  process (fk33_freeclk)
  begin
    if rising_edge(fk33_freeclk) then
      por_sr <= por_sr(14 downto 0) & '1';
    end if;
  end process;
  aux_aresetn <= por_sr(15);

  ------------------------------------------------------------------------------
  -- PCIe user-clock divider.  xdma/axi_aclk is already a buffered fabric clock,
  -- so no buffer is instantiated here -- and deliberately so: see the header.
  -- A second BUFG_GT on the IBUFDS_GTE4 ODIV2 tap, which would have measured the
  -- raw reference clock, is FORBIDDEN by DRC BFGTL-1 because it cannot share
  -- xdma's BUFG_GT_SYNC.  If this clock never toggles the counters simply stay
  -- at zero, which is the reading we want.
  ------------------------------------------------------------------------------
  uclk_g <= xdma_aclk;

  process (uclk_g)
  begin
    if rising_edge(uclk_g) then
      uclk_div <= uclk_div + 1;
    end if;
  end process;
  uclk_tgl <= uclk_div(7);   -- one transition every 128 axi_aclk cycles

  ------------------------------------------------------------------------------
  -- Synchronisers into the aux domain.  All single-bit.
  ------------------------------------------------------------------------------
  process (fk33_freeclk)
  begin
    if rising_edge(fk33_freeclk) then
      syn_uclk   <= syn_uclk(1 downto 0) & uclk_tgl;
      syn_perst <= syn_perst(1 downto 0) & perstn;
      syn_arst  <= syn_arst(0) & xdma_aresetn;
      syn_lnk   <= syn_lnk(0) & user_lnk_up;
      -- to_x01 so a simulation pull-up ('H') compares equal to '1'.  It is a
      -- no-op in synthesis, and without it a testbench reads back 'H' bits that
      -- never match the wiper constant.
      syn_sda   <= syn_sda(0) & to_x01(pin_i(1));
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Millisecond time base
  ------------------------------------------------------------------------------
  process (fk33_freeclk)
  begin
    if rising_edge(fk33_freeclk) then
      ms_tick <= '0';
      if ms_div = to_unsigned(C_MS_CYCLES - 1, ms_div'length) then
        ms_div  <= (others => '0');
        ms_tick <= '1';
        ms_cnt  <= ms_cnt + 1;
      else
        ms_div <= ms_div + 1;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- PCIe user-clock liveness and frequency.
  --
  -- UCLK_TICKS counts transitions of the divided toggle and never clears, so two
  -- JTAG reads a few seconds apart are a completely independent cross-check on
  -- UCLK_HZ.  UCLK_HZ counts those transitions over exactly one second of aux
  -- clock and scales by 128, giving xdma/axi_aclk in Hz directly: expect
  -- 250,000,000, and 0 means the PCIe hard block is not clocked at all.
  ------------------------------------------------------------------------------
  process (fk33_freeclk)
    variable edge : std_logic;
    variable hz_v : unsigned(31 downto 0);
  begin
    if rising_edge(fk33_freeclk) then
      edge := syn_uclk(2) xor syn_uclk(1);
      -- one transition of uclk_tgl is 128 axi_aclk cycles, so scaling the
      -- one-second edge count by 128 gives xdma/axi_aclk in Hz
      hz_v := shift_left(resize(win_edges, 32), 7);

      if edge = '1' then
        uclkticks  <= uclkticks + 1;
        win_edges <= win_edges + 1;
        uclk_ever  <= '1';
      end if;

      if win_cnt = to_unsigned(G_CLK_HZ - 1, win_cnt'length) then
        win_cnt <= (others => '0');
        uclkhz   <= hz_v;
        if edge = '1' then
          win_edges <= to_unsigned(1, win_edges'length);
        else
          win_edges <= (others => '0');
        end if;
        if hz_v > to_unsigned(C_UCLK_LO, 32) and hz_v < to_unsigned(C_UCLK_HI, 32) then
          uclk_alive <= '1';
        else
          uclk_alive <= '0';
        end if;
      else
        win_cnt <= win_cnt + 1;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- PERST#, the fabric reset and link-up.
  --
  -- perst_init is the level a handful of aux clocks after configuration.  Taken
  -- together with PERSTMS it answers the flash-boot question directly:
  --   perst_init = 0, PERSTMS valid   -> we were configured and READY before
  --                                      the host released reset.  In time.
  --   perst_init = 1, PERSTMS invalid -> the host had already released reset
  --                                      when we finished configuring.  Too
  --                                      late, and this is exactly the failure
  --                                      that presents as a hidden root port.
  ------------------------------------------------------------------------------
  process (fk33_freeclk)
  begin
    if rising_edge(fk33_freeclk) then
      if perst_seen = '0' and por_sr(15) = '1' then
        perst_init <= syn_perst(1);
        perst_seen <= '1';
      end if;

      if syn_perst(1) = '0' then
        perst_ev0 <= '1';
      else
        perst_ev1 <= '1';
      end if;

      if syn_perst(1) = '1' and syn_perst(2) = '0' then
        -- rising edge on the synchronised level, i.e. PERST# deasserted
        if perst_rise /= "1111" then
          perst_rise <= perst_rise + 1;
        end if;
        if perst_ms_ok = '0' then
          perst_ms    <= ms_cnt;
          perst_ms_ok <= '1';
        end if;
      end if;

      if syn_arst(1) = '1' then
        arst_ever <= '1';
      end if;
      if syn_lnk(1) = '1' then
        lnk_ever <= '1';
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Stage decode.  This is the whole I2C "program", and it is the same byte
  -- sequence tcl/vccint_step.tcl is known to work with:
  --
  --   read  : START, 0x59,                  read hi, read lo(NAK), STOP
  --   write : START, 0x58, 0x00, C_WIPER,                          STOP
  --
  -- C_WIPER_BYTE appears exactly once, in one stage, and nothing can substitute
  -- for it.
  ------------------------------------------------------------------------------
  process (xact, stage)
  begin
    op_now   <= OP_END;
    data_now <= (others => '0');
    case to_integer(stage) is
      when 0 => op_now <= OP_IDLE;
      when 1 => op_now <= OP_START;
      when 2 =>
        op_now <= OP_WBYTE;
        if xact = 1 then
          data_now <= C_ADDR_W;
        else
          data_now <= C_ADDR_R;
        end if;
      when 3 =>
        if xact = 1 then
          op_now   <= OP_WBYTE;
          data_now <= x"00";              -- command 0x00 = VOLATILE wiper 0
        else
          op_now <= OP_RACK;
        end if;
      when 4 =>
        if xact = 1 then
          op_now   <= OP_WBYTE;
          data_now <= C_WIPER_BYTE;       -- the only wiper this design can write
        else
          op_now <= OP_RNAK;
        end if;
      when 5 => op_now <= OP_STOP;
      when others => op_now <= OP_END;
    end case;
  end process;

  step_end <= '1' when step_cnt = to_unsigned(C_STEP_CYCLES - 1, step_cnt'length)
              else '0';

  ------------------------------------------------------------------------------
  -- The sequencer itself
  ------------------------------------------------------------------------------
  process (fk33_freeclk)
    variable bit_is_read : boolean;
    variable bit_val     : std_logic;
    variable wip         : integer;
  begin
    if rising_edge(fk33_freeclk) then

      -- default line state when the controller does not own the bus
      if pot_own = '0' then
        scl_r <= '1';
        sda_r <= '1';
      end if;

      -- one free-running step timer for the whole machine
      if st = ST_COND or st = ST_BIT then
        if step_end = '1' then
          step_cnt <= (others => '0');
        else
          step_cnt <= step_cnt + 1;
        end if;
      else
        step_cnt <= (others => '0');
      end if;

      -- hard timeout: whatever else happens, the bus is handed back
      if (st /= ST_DONE) and (st /= ST_FAIL) and (st /= ST_WAIT) then
        if ms_cnt > to_unsigned(G_START_MS + G_TIMEOUT_MS, ms_cnt'length) then
          st       <= ST_FAIL;
          fail_why <= to_unsigned(6, 3);
          pot_own  <= '0';
        end if;
      end if;

      case st is

        when ST_WAIT =>
          pot_own <= '0';
          if ms_cnt >= to_unsigned(G_START_MS, ms_cnt'length) then
            pot_own <= '1';
            xact    <= to_unsigned(0, 2);    -- read the wiper first
            stage   <= (others => '0');
            nack    <= '0';
            st      <= ST_SETUP;
          end if;

        when ST_SETUP =>
          ph   <= (others => '0');
          bidx <= (others => '0');
          sh   <= data_now;
          rxb  <= (others => '0');
          case op_now is
            when OP_IDLE | OP_START | OP_STOP =>
              st <= ST_COND;
            when OP_WBYTE | OP_RACK | OP_RNAK =>
              st <= ST_BIT;
            when others =>
              st <= ST_XACT_DONE;
          end case;

        when ST_COND =>
          case op_now is
            when OP_IDLE =>
              scl_r <= '1'; sda_r <= '1';
            when OP_START =>
              -- released, then SDA low with SCL high, then SCL low
              case to_integer(ph) is
                when 0      => scl_r <= '1'; sda_r <= '1';
                when 1      => scl_r <= '1'; sda_r <= '0';
                when others => scl_r <= '0'; sda_r <= '0';
              end case;
            when others =>   -- OP_STOP
              case to_integer(ph) is
                when 0      => scl_r <= '0'; sda_r <= '0';
                when 1      => scl_r <= '1'; sda_r <= '0';
                when others => scl_r <= '1'; sda_r <= '1';
              end case;
          end case;
          if step_end = '1' then
            if ph = 2 then
              st <= ST_STAGE_DONE;
            else
              ph <= ph + 1;
            end if;
          end if;

        when ST_BIT =>
          -- Which way this bit goes, and what SDA must hold for it.
          if op_now = OP_WBYTE then
            bit_is_read := (bidx = 8);
            if bidx = 8 then
              bit_val := '1';                 -- release so the slave can ACK
            else
              bit_val := sh(7);
            end if;
          else
            bit_is_read := (bidx /= 8);
            if bidx /= 8 then
              bit_val := '1';                 -- release so the slave can drive
            elsif op_now = OP_RACK then
              bit_val := '0';                 -- we ACK
            else
              bit_val := '1';                 -- we NAK
            end if;
          end if;

          sda_r <= bit_val;
          if ph = 1 then
            scl_r <= '1';
          else
            scl_r <= '0';
          end if;

          if step_end = '1' then
            if ph = 1 and bit_is_read then
              -- sample while SCL is high, exactly where the Tcl reads it
              if bidx = 8 then
                nack <= nack or syn_sda(1);
              else
                rxb <= rxb(6 downto 0) & syn_sda(1);
              end if;
            end if;
            if ph = 2 then
              ph <= (others => '0');
              if bidx = 8 then
                st <= ST_STAGE_DONE;
              else
                bidx <= bidx + 1;
                sh   <= sh(6 downto 0) & '0';
              end if;
            else
              ph <= ph + 1;
            end if;
          end if;

        when ST_STAGE_DONE =>
          -- capture the two bytes a read transaction produces
          if op_now = OP_RACK then
            wip_hi <= rxb;
          elsif op_now = OP_RNAK then
            wip_lo <= rxb;
          end if;
          if stage = 5 then
            st <= ST_XACT_DONE;
          else
            stage <= stage + 1;
            st    <= ST_SETUP;
          end if;

        when ST_XACT_DONE =>
          wip := to_integer(unsigned(wip_lo));
          if xact = 0 or xact = 2 then
            if nack = '1' then
              -- the pot did not acknowledge.  Retry a bounded number of times,
              -- then give up WITHOUT writing: if we cannot confirm we are
              -- talking to the pot, we must not move the rail.
              if attempts < 2 then
                attempts <= attempts + 1;
                stage    <= (others => '0');
                nack     <= '0';
                st       <= ST_SETUP;
              else
                fail_why <= to_unsigned(1, 3);
                pot_own  <= '0';
                st       <= ST_FAIL;
              end if;
            elsif xact = 0 then
              if wip_hi /= x"00" or wip < C_WIPER_LO or wip > C_WIPER_HI then
                -- outside the sane band; the same refusal tcl/vccint_step.tcl
                -- makes.  Do not write.
                fail_why <= to_unsigned(2, 3);
                pot_own  <= '0';
                st       <= ST_FAIL;
              else
                xact  <= to_unsigned(1, 2);
                stage <= (others => '0');
                nack  <= '0';
                st    <= ST_SETUP;
              end if;
            else
              if wip_hi = x"00" and wip_lo = C_WIPER_BYTE then
                pot_own <= '0';
                st      <= ST_DONE;
              else
                fail_why <= to_unsigned(5, 3);
                pot_own  <= '0';
                st       <= ST_FAIL;
              end if;
            end if;
          else
            -- the write transaction
            if nack = '1' then
              fail_why <= to_unsigned(3, 3);
              pot_own  <= '0';
              st       <= ST_FAIL;
            else
              xact  <= to_unsigned(2, 2);
              stage <= (others => '0');
              nack  <= '0';
              st    <= ST_SETUP;
            end if;
          end if;

        when others =>       -- ST_DONE, ST_FAIL
          pot_own <= '0';

      end case;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Pin arbitration and the IOBUFs.
  --
  -- Open drain in both directions: the output value is hardwired to '0' while
  -- the controller owns the bus, and the GPIO's own C_DOUT_DEFAULT is 0, so
  -- nothing here can ever drive a line high.  When the controller is idle the
  -- GPIO owns the pins exactly as before, which is what keeps
  -- host/fk33ctl.py vccint and tcl/vccint_step.tcl working unchanged.
  ------------------------------------------------------------------------------
  pin_t(0) <= scl_r when pot_own = '1' else gpio_t(0);
  pin_t(1) <= sda_r when pot_own = '1' else gpio_t(1);
  pin_o(0) <= '0'   when pot_own = '1' else gpio_o(0);
  pin_o(1) <= '0'   when pot_own = '1' else gpio_o(1);
  gpio_i   <= pin_i;

  g_iobuf : for i in 0 to 1 generate
    u_buf : IOBUF
      port map (
        I  => pin_o(i),
        O  => pin_i(i),
        T  => pin_t(i),
        IO => i2c_io(i)
      );
  end generate;

  ------------------------------------------------------------------------------
  -- Status words
  ------------------------------------------------------------------------------
  stat_magic    <= C_MAGIC;
  stat_version  <= C_VERSION;
  stat_uclkticks<= std_logic_vector(uclkticks);
  stat_uclkhz   <= std_logic_vector(uclkhz);
  stat_ms       <= std_logic_vector(ms_cnt);
  stat_perstms  <= std_logic_vector(perst_ms);

  stat_status(0)            <= syn_perst(1);
  stat_status(1)            <= perst_init;
  stat_status(2)            <= perst_ev0;
  stat_status(3)            <= perst_ev1;
  stat_status(7 downto 4)   <= std_logic_vector(perst_rise);
  stat_status(8)            <= syn_arst(1);
  stat_status(9)            <= arst_ever;
  stat_status(10)           <= syn_lnk(1);
  stat_status(11)           <= lnk_ever;
  stat_status(12)           <= uclk_alive;
  stat_status(13)           <= uclk_ever;
  stat_status(14)           <= perst_ms_ok;
  stat_status(15)           <= por_sr(15);
  stat_status(31 downto 16) <= x"A5A5";   -- fixed, so a stuck bus is obvious

  stat_pot(0)             <= '1' when st = ST_DONE else '0';
  stat_pot(1)             <= '1' when st = ST_FAIL else '0';
  stat_pot(2)             <= pot_own;
  stat_pot(3)             <= nack;
  stat_pot(5 downto 4)    <= std_logic_vector(xact);
  stat_pot(6)             <= '0';
  stat_pot(7)             <= '0';
  stat_pot(10 downto 8)   <= std_logic_vector(fail_why);
  stat_pot(11)            <= '0';
  stat_pot(15 downto 12)  <= std_logic_vector(attempts);
  stat_pot(23 downto 16)  <= wip_lo;        -- last wiper actually read back
  stat_pot(31 downto 24)  <= C_WIPER_BYTE;  -- what this bitstream can write

end architecture rtl;
