-- sim/seam_trace_chk.vhd -- compares one die's seam writes with the vector file's ops for
-- the armed case (plan 2026-11-04 Task 2). The ops are run_prompt's own writes captured over
-- jc_sim_broker (tools/jc/gen_tok_loop_vec.py), so this is the host as oracle.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.tok_loop_tb_pkg.all;

entity seam_trace_chk is
  generic(VEC : string := "tok_loop_vec.txt"; DIE : natural := 0);
  port(
    clk      : in  std_logic;
    arm      : in  std_logic;
    case_sel : in  natural;
    wr_ev    : in  std_logic;
    wr_addr  : in  std_logic_vector(11 downto 0);
    wr_data  : in  std_logic_vector(31 downto 0);
    errs     : out natural := 0;
    at_end   : out boolean := false;
    n_writes : out natural := 0);
end entity;

architecture sim of seam_trace_chk is
begin
  process(clk)
    variable V : vec_t := load_vec(VEC);
    variable j, last, run_n, e, nw : natural := 0;
    variable h : std_logic_vector(31 downto 0) := FNV_BASIS;
    procedure skip is
    begin
      while j < last and V.ops(j).die /= DIE loop j := j + 1; end loop;
    end procedure;
  begin
    if rising_edge(clk) then
      if arm = '1' then
        j := V.cs(case_sel).op0; last := V.cs(case_sel).op1; run_n := 0; h := FNV_BASIS; skip;
      elsif wr_ev = '1' then
        nw := nw + 1;
        if j >= last then
          e := e + 1; report "trace: write past the case's end, off " & to_hstring(wr_addr) severity error;
        elsif V.ops(j).kind = 'W' then
          if to_integer(unsigned(wr_addr)) /= V.ops(j).off or wr_data /= V.ops(j).val then
            e := e + 1;
            report "trace MISMATCH op " & integer'image(j) & ": got " & to_hstring(wr_addr) & "=" &
                   to_hstring(wr_data) & ", host wrote " & integer'image(V.ops(j).off) & "=" &
                   to_hstring(V.ops(j).val) severity error;
          end if;
          j := j + 1; skip;
        elsif to_integer(unsigned(wr_addr)) /= 16#60# then
          e := e + 1;
          report "trace MISMATCH op " & integer'image(j) & ": a WIN_DATA run ended early at " &
                 integer'image(run_n) severity error;
          run_n := 0; h := FNV_BASIS; j := j + 1; skip;
        else
          h := fnv_step(h, wr_data); run_n := run_n + 1;
          if run_n = V.ops(j).cnt then
            if h /= V.ops(j).val then
              e := e + 1; report "trace MISMATCH op " & integer'image(j) & ": WIN_DATA row hash" severity error;
            end if;
            run_n := 0; h := FNV_BASIS; j := j + 1; skip;
          end if;
        end if;
      end if;
      errs <= e; at_end <= (j >= last); n_writes <= nw;
    end if;
  end process;
end architecture;
