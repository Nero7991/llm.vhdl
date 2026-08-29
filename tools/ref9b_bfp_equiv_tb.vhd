-- tools/ref9b_bfp_equiv_tb.vhd
--
-- Drives the SHIPPING `rtl/bfp_pack.vhd` over a file of int32 vectors and
-- prints the (exponent, mantissa vector) it produces, one line per case.
--
-- WHY THIS EXISTS.  `docs/debugging/2026-08-29_9b-whole-model-reference.md`
-- section 9 records, as an explicitly unverified claim, that
-- `ref/run9b.c`'s `reg_put` is "VALUE-equivalent to `rtl/bfp_pack.vhd`, not
-- proven bit-identical to it ... but no test compares them".  This is that
-- test's RTL half.  Reading `bfp_pack.vhd` and transcribing it into C would
-- reproduce whatever I misread; the project rule is that the RTL wins, so the
-- RTL is RUN and the C transcription is scored against what it prints.
--
-- DELIBERATELY NOT UNDER sim/.  `sim/regress.sh` globs `sim/tb_*.vhd` and
-- `tb/tb_*.vhd` (regress.sh:783,790) and turns every match into a gate row.
-- A bench that needs a generated vector file would turn the shared gate red
-- for every concurrent track the moment the file is absent.  Under `tools/`
-- it is invisible to that glob, which was CHECKED by reading `SUITE_DIRS`,
-- not assumed.
--
-- The BRAM model here is the same read-ahead contract `rtl/vec_mem.vhd`
-- offers: the address presented at cycle k returns data at cycle k+1.
--
-- Usage (see tools/ref9b_bfp_equiv.sh):
--   ghdl -r --std=08 ref9b_bfp_equiv_tb -gN=16 -gQ=12 -gVEC=cases.txt

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity ref9b_bfp_equiv_tb is
  generic(
    N   : positive := 16;
    Q   : integer  := 12;
    VEC : string   := "cases.txt"
  );
end entity;

architecture sim of ref9b_bfp_equiv_tb is
  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';
  signal start   : std_logic := '0';
  signal o_raddr : std_logic_vector(clog2(N)-1 downto 0);
  signal i_rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal done    : std_logic;
  signal o_mant  : std_logic_vector(N*16-1 downto 0);
  signal o_exp   : integer;

  type mem_t is array(0 to N-1) of std_logic_vector(31 downto 0);
  signal mem : mem_t := (others => (others => '0'));

  signal running : boolean := true;
begin

  clk <= not clk after 5 ns when running else '0';

  -- vec_mem's contract: registered read, data valid the cycle after the
  -- address is presented.
  process(clk)
  begin
    if rising_edge(clk) then
      i_rdata <= mem(to_integer(unsigned(o_raddr)));
    end if;
  end process;

  dut : entity work.bfp_pack
    generic map(N => N, Q => Q)
    port map(clk => clk, rst => rst, start => start,
             o_raddr => o_raddr, i_rdata => i_rdata,
             done => done, o_mant => o_mant, o_exp => o_exp);

  stim : process
    file     fh   : text;
    variable ln   : line;
    variable ol   : line;
    variable st   : file_open_status;
    variable v    : integer;
    variable good : boolean;
    variable ncase: integer := 0;
    variable m16  : signed(15 downto 0);
  begin
    file_open(st, fh, VEC, read_mode);
    if st /= open_ok then
      report "ref9b_bfp_equiv_tb: cannot open " & VEC severity failure;
    end if;

    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    while not endfile(fh) loop
      readline(fh, ln);
      -- A blank or comment line is skipped.  A case line is exactly N
      -- whitespace-separated decimal integers.
      read(ln, v, good);
      if good then
        mem(0) <= std_logic_vector(to_signed(v, 32));
        for i in 1 to N-1 loop
          read(ln, v, good);
          if not good then
            report "ref9b_bfp_equiv_tb: short case line" severity failure;
          end if;
          mem(i) <= std_logic_vector(to_signed(v, 32));
        end loop;
        wait until rising_edge(clk);

        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
        wait until done = '1' and rising_edge(clk);

        write(ol, string'("OUT "));
        write(ol, ncase);
        write(ol, string'(" "));
        write(ol, o_exp);
        for i in 0 to N-1 loop
          m16 := signed(o_mant((i+1)*16-1 downto i*16));
          write(ol, string'(" "));
          write(ol, to_integer(m16));
        end loop;
        writeline(output, ol);
        ncase := ncase + 1;

        wait until rising_edge(clk);
      end if;
    end loop;

    file_close(fh);
    write(ol, string'("CASES "));
    write(ol, ncase);
    writeline(output, ol);
    running <= false;
    wait;
  end process;

end architecture;
