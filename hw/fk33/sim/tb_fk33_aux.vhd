--------------------------------------------------------------------------------
-- tb_fk33_aux -- does the autonomous VCCINT controller actually put 68 in the pot
--------------------------------------------------------------------------------
-- This exists because the controller in rtl/fk33_aux.vhd moves a real power rail
-- on an ES1 die with no host in the loop and no opportunity to intervene, and
-- because the byte sequence it has to reproduce is the one in
-- tcl/vccint_step.tcl rather than one of its own invention.  Reading the VHDL is
-- not enough to be sure of an I2C bit order.
--
-- The model below is a behavioural MCP45xx: it acknowledges its own address,
-- accepts [addr+W][cmd][data] and returns [hi][lo] on a read.  It asserts, in
-- the testbench rather than in a comment, that:
--
--   * the address byte is 0x58 on a write and 0x59 on a read;
--   * the command byte is 0x00, the VOLATILE wiper;
--   * the data byte is 0x44 and nothing else, EVER, on any transaction;
--   * the controller reads the wiper BEFORE writing it;
--   * the controller reads it back AFTER writing and reports done;
--   * the bus is released when it finishes.
--
-- Generics are scaled down (2 MHz "aux clock") purely so the simulation is
-- seconds rather than minutes.  Every count in the design is derived from
-- G_CLK_HZ, so the sequence is identical.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fk33_aux is
end entity;

architecture sim of tb_fk33_aux is

  -- 2 MHz.  Low enough that the one-second REFCLK_HZ measurement window is
  -- 2,000,000 cycles and can be reached in simulation, and high enough that one
  -- I2C step is 10 clocks.  DO NOT LOWER IT FURTHER: at 200 kHz a step collapses
  -- to a single clock, the SDA synchroniser has not settled when the bit is
  -- sampled, and every read comes back skewed -- which presents as the pot
  -- NACKing.  rtl/fk33_aux.vhd now asserts against exactly that.
  constant CLK_HZ : natural := 2000000;
  constant TCK    : time := 500 ns;

  signal clk_free   : std_logic := '0';
  signal uclk       : std_logic := '0';
  signal perstn     : std_logic := '0';
  signal aresetn    : std_logic := '0';
  signal lnkup      : std_logic := '0';

  signal gpio_o     : std_logic_vector(1 downto 0) := "00";
  signal gpio_t     : std_logic_vector(1 downto 0) := "11";
  signal gpio_i     : std_logic_vector(1 downto 0);

  signal i2c        : std_logic_vector(1 downto 0);

  signal aux_clk    : std_logic;
  signal aux_rstn   : std_logic;
  signal s_magic, s_ver, s_ticks, s_hz, s_stat, s_pot, s_ms, s_pms
                    : std_logic_vector(31 downto 0);

  signal scl_x, sda_x : std_logic;
  signal sda_drv      : std_logic := 'Z';

  -- what the model believes its wiper is.  128 is the power-up default.
  signal wiper      : unsigned(8 downto 0) := to_unsigned(128, 9);
  signal n_writes   : natural := 0;
  signal n_reads    : natural := 0;
  signal uclk_on    : boolean := true;

begin

  clk_free <= not clk_free after TCK / 2;
  -- 1 MHz, standing in for xdma/axi_aclk.
  uclk     <= (not uclk) after 500 ns when uclk_on else '0';

  -- board pull-ups
  i2c <= "HH";
  i2c(1) <= sda_drv;

  scl_x <= to_x01(i2c(0));
  sda_x <= to_x01(i2c(1));

  dut : entity work.fk33_aux
    generic map (
      G_CLK_HZ     => CLK_HZ,
      G_START_MS   => 1,
      G_TIMEOUT_MS => 50,
      G_UCLK_HZ    => 1000000
    )
    port map (
      clk_free_in   => clk_free,
      xdma_aclk     => uclk,
      perstn        => perstn,
      xdma_aresetn  => aresetn,
      user_lnk_up   => lnkup,
      gpio_o        => gpio_o,
      gpio_t        => gpio_t,
      gpio_i        => gpio_i,
      i2c_io        => i2c,
      aux_clk       => aux_clk,
      aux_aresetn   => aux_rstn,
      stat_magic    => s_magic,
      stat_version  => s_ver,
      stat_uclkticks=> s_ticks,
      stat_uclkhz   => s_hz,
      stat_status   => s_stat,
      stat_pot      => s_pot,
      stat_ms       => s_ms,
      stat_perstms  => s_pms
    );

  ------------------------------------------------------------------------------
  -- Behavioural MCP45xx at 0x2c
  ------------------------------------------------------------------------------
  slave : process
    variable b       : std_logic_vector(7 downto 0);
    variable is_read : boolean;
    variable cmd     : std_logic_vector(7 downto 0);

    procedure rx_byte(v : out std_logic_vector(7 downto 0)) is
    begin
      for i in 7 downto 0 loop
        wait until scl_x'event and scl_x = '1';
        v(i) := sda_x;
      end loop;
    end procedure;

    procedure ack is
    begin
      wait until scl_x'event and scl_x = '0';
      sda_drv <= '0';
      wait until scl_x'event and scl_x = '0';
      sda_drv <= 'Z';
    end procedure;
  begin
    sda_drv <= 'Z';
    loop
      -- START: SDA falls while SCL is high
      wait until sda_x'event and sda_x = '0' and scl_x = '1';

      rx_byte(b);
      is_read := (b(0) = '1');
      assert b = x"58" or b = x"59"
        report "tb_fk33_aux: the controller addressed 0x" &
               integer'image(to_integer(unsigned(b))) &
               ", not the pot at 0x2c" severity failure;
      ack;

      if is_read then
        n_reads <= n_reads + 1;
        -- The MCP45xx returns the 9-bit wiper as [7 zeroes, bit8][bits 7..0],
        -- high byte first, the master ACKing the first and NAKing the second.
        for i in 7 downto 0 loop
          if i = 0 then sda_drv <= wiper(8); else sda_drv <= '0'; end if;
          wait until scl_x'event and scl_x = '0';
        end loop;
        sda_drv <= 'Z';
        wait until scl_x'event and scl_x = '0'; -- the master's ACK
        for i in 7 downto 0 loop
          sda_drv <= wiper(i);
          wait until scl_x'event and scl_x = '0';
        end loop;
        sda_drv <= 'Z';
        wait until scl_x'event and scl_x = '0'; -- the master's NAK
      else
        rx_byte(cmd);
        assert cmd = x"00"
          report "tb_fk33_aux: command byte is not 0x00 (volatile wiper 0)"
          severity failure;
        ack;
        rx_byte(b);
        -- THE safety assertion.  Nothing but 68 may ever reach the pot.
        assert b = x"44"
          report "tb_fk33_aux: the controller tried to write wiper " &
                 integer'image(to_integer(unsigned(b))) &
                 ", not 68.  This is the assertion the whole design exists to keep."
          severity failure;
        ack;
        wiper    <= resize(unsigned(b), 9);
        n_writes <= n_writes + 1;
      end if;
    end loop;
  end process;

  ------------------------------------------------------------------------------
  -- Stimulus and checks
  ------------------------------------------------------------------------------
  main : process
    variable t0 : unsigned(31 downto 0);
  begin
    wait for 1 us;   -- let the constant outputs propagate past time zero
    assert s_magic = x"41555831" report "magic wrong" severity failure;

    -- PERST# held for a while, then released, so PERST_MS has something to
    -- record and the "level at configuration" bit has to read 0.
    wait for 2500 us;
    perstn <= '1';

    -- Let the controller run.  1 ms start delay plus three transactions.
    wait for 20 ms;

    report "POT_STATUS = 0x" & to_hstring(s_pot);
    report "AUX_STATUS = 0x" & to_hstring(s_stat);
    report "AUX_MS     = " & integer'image(to_integer(unsigned(s_ms)));
    report "PERST_MS   = " & integer'image(to_integer(unsigned(s_pms)));
    report "UCLKTICKS  = " & integer'image(to_integer(unsigned(s_ticks)));

    assert n_reads = 2
      report "expected exactly 2 pot reads (before and after), got " &
             integer'image(n_reads) severity failure;
    assert n_writes = 1
      report "expected exactly 1 pot write, got " & integer'image(n_writes)
      severity failure;
    assert wiper = 68
      report "the pot did not end at 68" severity failure;

    assert s_pot(0) = '1' report "controller did not report done" severity failure;
    assert s_pot(1) = '0' report "controller reported failed" severity failure;
    assert s_pot(2) = '0' report "controller still owns the bus" severity failure;
    assert s_pot(31 downto 24) = x"44"
      report "the bitstream advertises a target other than 68" severity failure;
    assert s_pot(23 downto 16) = x"44"
      report "the read-back wiper is not 68" severity failure;

    -- the bus must be back with the AXI GPIO, released
    assert i2c(0) = 'H' and i2c(1) = 'H'
      report "the controller did not release the I2C lines" severity failure;

    -- PERST# observability
    assert s_stat(1) = '0' report "PERST# level at configuration should be 0"
      severity failure;
    assert s_stat(2) = '1' and s_stat(3) = '1'
      report "PERST# stickies did not both set" severity failure;
    assert s_stat(0) = '1' report "PERST# level should read 1 now" severity failure;
    assert s_stat(14) = '1' report "PERST_MS should be valid" severity failure;
    assert unsigned(s_pms) = 2
      report "PERST_MS should be 2 ms, got " &
             integer'image(to_integer(unsigned(s_pms))) severity failure;
    assert s_stat(7 downto 4) = "0001"
      report "PERST# deassertion count should be 1" severity failure;
    assert s_stat(31 downto 16) = x"A5A5" report "fixed field wrong" severity failure;

    -- the reference clock must be seen to tick, and must stop being seen when
    -- it stops.  This is the whole point of the register.
    assert unsigned(s_ticks) > 0
      report "the user-clock counter never advanced with a clock present"
      severity failure;
    t0 := unsigned(s_ticks);

    -- Reach the one-second measurement window, so UCLK_HZ is exercised and not
    -- merely present.  Read with the PERST# level this is the register that
    -- separates "the PCH gated the SRC clock", "we are held in reset" and
    -- "clocked but never trained", so it is worth the simulated second.
    wait until unsigned(s_ms) >= 1100;
    report "UCLK_HZ    = " & integer'image(to_integer(unsigned(s_hz)));
    assert unsigned(s_hz) > 950000 and unsigned(s_hz) < 1050000
      report "UCLK_HZ should read about 1000000 with a 1 MHz user clock, got "
             & integer'image(to_integer(unsigned(s_hz))) severity failure;
    assert s_stat(12) = '1' report "uclk-alive bit should be set" severity failure;

    -- Stop the user clock.  The ticks must stop immediately and the
    -- measurement must fall to zero at the next full window.
    uclk_on <= false;
    wait for 2 ms;
    assert unsigned(s_ticks) = t0 or unsigned(s_ticks) > t0
      report "tick counter went backwards" severity failure;
    t0 := unsigned(s_ticks);
    wait for 10 ms;
    assert unsigned(s_ticks) = t0
      report "the user-clock counter kept advancing after the clock stopped"
      severity failure;
    -- The window fires on whole seconds of aux clock from configuration, so the
    -- window that STRADDLES the moment the clock stopped reports a partial
    -- count. Wait for the first window that is entirely after it.
    wait until unsigned(s_ms) >= 3100;
    report "UCLK_HZ after the clock stopped = " &
           integer'image(to_integer(unsigned(s_hz)));
    assert unsigned(s_hz) = 0
      report "UCLK_HZ did not fall to zero after the user clock stopped"
      severity failure;
    assert s_stat(12) = '0'
      report "uclk-alive stayed set after the user clock stopped"
      severity failure;
    assert s_stat(13) = '1'
      report "the uclk-ever-ticked sticky must NOT clear" severity failure;

    report "TB_FK33_AUX PASS";
    std.env.finish;
  end process;

end architecture;
