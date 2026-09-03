-- sim/tb_gdn_exp_mem.vhd -- `rtl/gdn_exp_mem.vhd`, and specifically the one
-- property that must not silently change: THE READ IS COMBINATIONAL.
--
-- `rtl/gdn_block.vhd` labels this port "state exponent table, COMBINATIONAL
-- read" (:317), drives `se_rhead`/`se_rcol` combinationally from the
-- recurrence address (:632-633) and consumes `se_rdata` on the SAME edge
-- (:1203).  If this memory ever acquires a registered read it still passes
-- any test that waits a cycle before looking, and `gdn_block` then samples
-- the PREVIOUS address's exponent -- a wrong number on every column, with no
-- handshake violated and nothing to see in a waveform unless you already
-- suspect it.
--
-- SO THE CHECK IS DELIBERATELY NOT CLOCK-ALIGNED: the address is driven, the
-- bench waits a DELTA (not an edge), and the data must already be right.  A
-- registered read fails that by construction.  The mutation table below
-- includes exactly that mutation and it is the reason this file exists.
--
-- The second property is the port priority.  The mover and the unit share one
-- array; `gdn_state_store` gates the unit off while the mover owns the store,
-- but the memory itself resolves a simultaneous write in favour of the mover
-- so that a caller bug is a lost write in ONE place rather than a race.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_gdn_exp_mem is
  generic(
    VAL_HEADS : positive := 4;
    DIM       : positive := 8
  );
end entity;

architecture sim of tb_gdn_exp_mem is
  constant N : positive := VAL_HEADS * DIM;

  signal clk : std_logic := '0';

  signal r_head : natural range 0 to VAL_HEADS-1 := 0;
  signal r_col  : natural range 0 to DIM-1 := 0;
  signal r_data : signed(7 downto 0);

  signal w_en   : std_logic := '0';
  signal w_head : natural range 0 to VAL_HEADS-1 := 0;
  signal w_col  : natural range 0 to DIM-1 := 0;
  signal w_data : signed(7 downto 0) := (others => '0');

  signal m_r_addr : natural range 0 to N-1 := 0;
  signal m_r_data : signed(7 downto 0);
  signal m_w_en   : std_logic := '0';
  signal m_w_addr : natural range 0 to N-1 := 0;
  signal m_w_data : signed(7 downto 0) := (others => '0');

  signal n_chk, n_bad : natural := 0;
  signal n_async : natural := 0;   -- reads checked WITHOUT a clock edge

  function pat(i : natural) return signed is
  begin
    return to_signed(((i*37 + 11) mod 256) - 128, 8);
  end function;
  function pat2(i : natural) return signed is
  begin
    return to_signed(((i*91 + 5) mod 256) - 128, 8);
  end function;
begin
  clk <= not clk after 5 ns;

  dut : entity work.gdn_exp_mem
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM, STYLE => "auto")
    port map(clk => clk,
             r_head => r_head, r_col => r_col, r_data => r_data,
             w_en => w_en, w_head => w_head, w_col => w_col,
             w_data => w_data,
             m_r_addr => m_r_addr, m_r_data => m_r_data,
             m_w_en => m_w_en, m_w_addr => m_w_addr, m_w_data => m_w_data);

  stim : process is
    -- `nt`, not `n`: VHDL identifiers are case-insensitive, so a parameter
    -- called `n` hides the constant `N` and GHDL warns on every build.
    procedure tick(nt : natural := 1) is
    begin
      for i in 1 to nt loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure chk(cond : boolean; msg : string) is
    begin
      n_chk <= n_chk + 1;
      if not cond then
        n_bad <= n_bad + 1;
        report "tb_gdn_exp_mem: " & msg severity error;
      end if;
      wait for 0 ns;
    end procedure;
  begin
    -- ---- fill through the MOVER port ----------------------------------
    for i in 0 to N-1 loop
      m_w_en <= '1'; m_w_addr <= i; m_w_data <= pat(i);
      tick;
    end loop;
    m_w_en <= '0';
    tick;

    -- ---- read through the UNIT port, COMBINATIONALLY --------------------
    -- No `tick` between driving the address and checking.  `wait for 0 ns`
    -- lets the concurrent assignment settle and advances no time at all, so
    -- a registered read cannot have happened.
    for i in 0 to N-1 loop
      r_head <= i / DIM;
      r_col  <= i mod DIM;
      wait for 0 ns; wait for 0 ns;
      n_async <= n_async + 1;
      chk(r_data = pat(i),
          "combinational unit read at " & integer'image(i) & " got "
          & integer'image(to_integer(r_data)) & " want "
          & integer'image(to_integer(pat(i))));
    end loop;

    -- ---- read through the MOVER port, also combinational -----------------
    for i in 0 to N-1 loop
      m_r_addr <= i;
      wait for 0 ns; wait for 0 ns;
      chk(m_r_data = pat(i),
          "combinational mover read at " & integer'image(i));
    end loop;

    -- ---- write through the UNIT port, read back both ways ----------------
    for i in 0 to N-1 loop
      w_en <= '1'; w_head <= i / DIM; w_col <= i mod DIM;
      w_data <= pat2(i);
      tick;
    end loop;
    w_en <= '0';
    tick;
    for i in 0 to N-1 loop
      m_r_addr <= i;
      wait for 0 ns; wait for 0 ns;
      chk(m_r_data = pat2(i),
          "unit write not visible on the mover port at " & integer'image(i));
    end loop;

    -- ---- PRIORITY: the mover wins a simultaneous write -------------------
    -- Not a race to be avoided in the bench: it is the memory's stated rule,
    -- and a rule nobody exercises is not a rule.
    m_w_en <= '1'; m_w_addr <= 3; m_w_data <= to_signed(99, 8);
    w_en   <= '1'; w_head <= 0; w_col <= 3; w_data <= to_signed(-99, 8);
    tick;
    m_w_en <= '0'; w_en <= '0';
    tick;
    m_r_addr <= 3;
    wait for 0 ns; wait for 0 ns;
    chk(m_r_data = to_signed(99, 8),
        "the mover port did not win a simultaneous write: got "
        & integer'image(to_integer(m_r_data)));

    report "tb_gdn_exp_mem: checks=" & integer'image(n_chk)
         & " bad=" & integer'image(n_bad)
         & " combinational reads=" & integer'image(n_async) severity note;

    assert n_async > 0
      report "tb_gdn_exp_mem: FAIL, no combinational read was ever checked, "
           & "so the property this file exists for is UNTESTED."
      severity failure;

    if n_bad = 0 then
      report "tb_gdn_exp_mem RESULT: PASS -- " & integer'image(n_chk)
           & " checks, of which " & integer'image(n_async)
           & " confirmed the read is combinational." severity note;
    else
      report "tb_gdn_exp_mem RESULT: FAIL -- " & integer'image(n_bad)
           & " of " & integer'image(n_chk) severity error;
    end if;
    finish;
  end process;
end architecture;
