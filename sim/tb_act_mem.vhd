-- sim/tb_act_mem.vhd -- act_mem_striped against its 7.8 mapping.
--
-- Writes a distinct value into every element, then reads every block and checks
-- each of the BLK lanes lands where the mapping says it should.  The value
-- written to element k is k itself, so a mis-wired bank or lane shows up as a
-- specific wrong index rather than as generic corruption -- which is the point,
-- since "element k in bank k mod 8" is ambiguous and a plausible-looking wrong
-- mapping still reads back BLK values, just permuted.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity tb_act_mem is
  generic(ELEMS : positive := 544; BLK : positive := 32; LANES : positive := 4);
end entity;

architecture sim of tb_act_mem is
  constant W     : positive := 16;
  constant WORDS : positive := (ELEMS + BLK - 1) / BLK;

  signal clk    : std_logic := '0';
  signal we     : std_logic := '0';
  signal waddr  : std_logic_vector(clog2(ELEMS)-1 downto 0) := (others => '0');
  signal wdata  : std_logic_vector(W-1 downto 0) := (others => '0');
  signal rbaddr : std_logic_vector(clog2(WORDS)-1 downto 0) := (others => '0');
  signal rdata  : std_logic_vector(BLK*W-1 downto 0);
  signal finished : boolean := false;
  signal nbad, nchk : integer := 0;
begin
  clkgen : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  dut : entity work.act_mem_striped
    generic map(ELEMS => ELEMS, BLK => BLK, LANES => LANES, W => W)
    port map(clk => clk, we => we, waddr => waddr, wdata => wdata,
             rbaddr => rbaddr, rdata => rdata);

  drv : process
    variable got, want : integer;
    variable nb, nc : integer := 0;
  begin
    -- fill: element k carries the value k
    for k in 0 to ELEMS-1 loop
      wait until rising_edge(clk);
      we    <= '1';
      waddr <= std_logic_vector(to_unsigned(k, waddr'length));
      wdata <= std_logic_vector(to_unsigned(k mod 65536, W));
    end loop;
    wait until rising_edge(clk);
    we <= '0';

    -- read every block; the address is issued one cycle ahead, so the data for
    -- block b is valid on the edge after b was presented
    for b in 0 to WORDS-1 loop
      rbaddr <= std_logic_vector(to_unsigned(b, rbaddr'length));
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      for j in 0 to BLK-1 loop
        if b*BLK + j < ELEMS then
          got  := to_integer(unsigned(rdata((j+1)*W-1 downto j*W)));
          want := (b*BLK + j) mod 65536;
          nc := nc + 1;
          if got /= want then
            nb := nb + 1;
            if nb < 6 then
              report "ACT MISMATCH block=" & integer'image(b) &
                     " lane=" & integer'image(j) &
                     " got "  & integer'image(got) &
                     " want " & integer'image(want) severity error;
            end if;
          end if;
        end if;
      end loop;
    end loop;
    nchk <= nc; nbad <= nb;
    wait until rising_edge(clk);
    report "act_mem_striped: " & integer'image(nchk) & " elements checked, " &
           integer'image(nbad) & " mismatches (ELEMS=" & integer'image(ELEMS) &
           " BLK=" & integer'image(BLK) & " LANES=" & integer'image(LANES) & ")"
           severity note;
    assert nbad = 0 report "act_mem_striped MAPPING IS WRONG" severity failure;
    finished <= true;
    wait;
  end process;
end architecture;
