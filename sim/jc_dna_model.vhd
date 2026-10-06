-- Behavioural stand-in for the UltraScale+ DNA_PORTE2 primitive, for GHDL benches only
-- (the gate is GHDL mcode and cannot elaborate UNISIM). Not a gate row: it has no tb_
-- prefix and is pulled into a bench's closure only by instantiation.
--
-- WHAT IS MODELLED, AND WHAT IS ASSUMED (ESTIMATE: AMD UG570 / DS923 are not in
-- docs/datasheets/, so none of the following is a datasheet figure):
--   * a 96-bit shift register; at a CLK rising edge READ = '1' loads SIM_DNA, else
--     SHIFT = '1' shifts it one place toward bit 0 with DIN entering at bit 95;
--   * DOUT presents bit 0 of the register at all times, so the FIRST bit out after a
--     READ is dna(0) and the k-th SHIFT brings dna(k) to DOUT (LSB first) -- the same
--     bit order rtl/jc_dna_reader.vhd assumes. ESTIMATE; Task 11 cross-checks it against
--     Vivado hardware manager's per-device DNA readout on silicon;
--   * READ wins over SHIFT if both are high (the reader never does that; it is counted
--     as an error here).
--
-- CHECKS (counted in `errors`, never asserted here; the bench asserts errors = 0):
--   * setup: READ or SHIFT changed less than T_MARGIN before a CLK rising edge;
--   * hold:  READ or SHIFT changed less than T_MARGIN after a CLK rising edge (a change
--            in the same delta cycle as the edge fails both);
--   * period: two CLK rising edges closer than T_CLK_MIN (default 40 ns = 25 MHz, the
--            brief's ceiling; ESTIMATE, the primitive's real limit is unverified);
--   * READ or SHIFT not '0'/'1' at a CLK rising edge, or both high at once.
-- T_MARGIN is set by the bench to one period of the reader's clock (aclk).
library ieee;
use ieee.std_logic_1164.all;

entity jc_dna_model is
  generic(
    SIM_DNA   : std_logic_vector(95 downto 0);
    T_MARGIN  : time := 2 ns;
    T_CLK_MIN : time := 40 ns
  );
  port(
    clk, read, shift, din : in  std_logic;
    dout                  : out std_logic;
    errors                : out natural;
    reads, shifts         : out natural
  );
end entity;

architecture beh of jc_dna_model is
  signal sr : std_logic_vector(95 downto 0) := (others => '0');
begin
  dout <= sr(0);

  reg : process(clk)
  begin
    if rising_edge(clk) then
      if read = '1' then
        sr <= SIM_DNA;
      elsif shift = '1' then
        sr <= din & sr(95 downto 1);
      end if;
    end if;
  end process;

  checker : process
    variable n_err, n_rd, n_sh : natural := 0;
    variable t_rise, t_ctl : time := 0 ns;
    variable have_rise, have_ctl : boolean := false;
  begin
    wait on clk, read, shift;
    if rising_edge(clk) then
      if have_ctl and now - t_ctl < T_MARGIN then
        n_err := n_err + 1;
        report "jc_dna_model: READ/SHIFT setup violation, changed " &
               time'image(now - t_ctl) & " before CLK" severity warning;
      end if;
      if have_rise and now - t_rise < T_CLK_MIN then
        n_err := n_err + 1;
        report "jc_dna_model: CLK period " & time'image(now - t_rise) &
               " below " & time'image(T_CLK_MIN) severity warning;
      end if;
      if (read /= '0' and read /= '1') or (shift /= '0' and shift /= '1') then
        n_err := n_err + 1;
        report "jc_dna_model: READ/SHIFT not 0/1 at CLK" severity warning;
      elsif read = '1' and shift = '1' then
        n_err := n_err + 1;
        report "jc_dna_model: READ and SHIFT both high" severity warning;
      elsif read = '1' then
        n_rd := n_rd + 1;
      elsif shift = '1' then
        n_sh := n_sh + 1;
      end if;
      t_rise := now; have_rise := true;
    end if;
    if read'event or shift'event then
      if have_rise and now - t_rise < T_MARGIN then
        n_err := n_err + 1;
        report "jc_dna_model: READ/SHIFT hold violation, changed " &
               time'image(now - t_rise) & " after CLK" severity warning;
      end if;
      t_ctl := now; have_ctl := true;
    end if;
    errors <= n_err;
    reads  <= n_rd;
    shifts <= n_sh;
  end process;
end architecture;
