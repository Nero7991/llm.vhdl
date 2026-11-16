-- sim/tok_loop_tb_pkg.vhd -- the loop benches' vector loader and helpers (plan 2026-11-04
-- Task 2). Vector format: tools/jc/gen_tok_loop_vec.py's header.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

package tok_loop_tb_pkg is
  constant MAX_CASES : natural := 16;
  constant MAX_OPS   : natural := 4096;
  constant MAX_INTS  : natural := 2048;
  type op_t is record
    kind : character;
    die, off, cnt : natural;
    val : std_logic_vector(31 downto 0);
  end record;
  type op_arr is array (0 to MAX_OPS-1) of op_t;
  type int_arr is array (0 to MAX_INTS-1) of integer;
  type case_t is record
    plen, max_new, n_ids, p0, i0, op0, op1 : natural;
    stop : integer;
    pair : boolean;
    gather : boolean;
  end record;
  type case_arr is array (0 to MAX_CASES-1) of case_t;
  type vec_t is record
    n_cases, n_ops, n_ints : natural;
    cs : case_arr;
    ops : op_arr;
    ints : int_arr;
  end record;
  type row16_arr is array (natural range <>) of std_logic_vector(15 downto 0);
  constant FNV_BASIS : std_logic_vector(31 downto 0) := x"811C9DC5";
  impure function load_vec(fname : string) return vec_t;
  function fnv_step(h, v : std_logic_vector(31 downto 0)) return std_logic_vector;
  procedure synth_row(tok : natural; row : out row16_arr; xexp : out std_logic_vector(31 downto 0));
end package;

package body tok_loop_tb_pkg is
  function fnv_step(h, v : std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    return std_logic_vector(resize((unsigned(h) xor unsigned(v)) * unsigned'(x"01000193"), 32));
  end function;

  procedure synth_row(tok : natural; row : out row16_arr; xexp : out std_logic_vector(31 downto 0)) is
    variable h : unsigned(31 downto 0) := x"811C9DC5" xor to_unsigned(tok, 32);
  begin
    for k in row'range loop
      h := h xor to_unsigned(k - row'low, 32);
      h := resize(h * x"01000193", 32);
      row(k) := std_logic_vector(h(31 downto 16)) xor x"8000";
    end loop;
    xexp := x"FFFFFFF8";
  end procedure;

  impure function load_vec(fname : string) return vec_t is
    file f : text open read_mode is fname;
    variable l : line;
    variable ch : character;
    variable v : vec_t;
    variable n : integer;
    variable cur : natural := 0;
    variable h12 : std_logic_vector(11 downto 0);
    variable h32 : std_logic_vector(31 downto 0);
  begin
    v.n_cases := 0; v.n_ops := 0; v.n_ints := 0;
    while not endfile(f) loop
      readline(f, l);
      if l'length > 0 then
        read(l, ch);
        case ch is
          when 'C' =>
            cur := v.n_cases; v.n_cases := v.n_cases + 1;
            read(l, n); v.cs(cur).plen := n;
            read(l, n); v.cs(cur).max_new := n;
            read(l, n); v.cs(cur).stop := n;
            read(l, n); v.cs(cur).n_ids := n;
            read(l, n); v.cs(cur).pair := (n = 1); v.cs(cur).gather := (n = 2);
            v.cs(cur).op0 := v.n_ops; v.cs(cur).op1 := v.n_ops;
          when 'P' =>
            v.cs(cur).p0 := v.n_ints;
            for j in 1 to v.cs(cur).plen loop
              read(l, n); v.ints(v.n_ints) := n; v.n_ints := v.n_ints + 1;
            end loop;
          when 'I' =>
            v.cs(cur).i0 := v.n_ints;
            for j in 1 to v.cs(cur).n_ids loop
              read(l, n); v.ints(v.n_ints) := n; v.n_ints := v.n_ints + 1;
            end loop;
          when 'W' =>
            read(l, n); v.ops(v.n_ops).die := n; v.ops(v.n_ops).kind := 'W';
            hread(l, h12); v.ops(v.n_ops).off := to_integer(unsigned(h12));
            hread(l, h32); v.ops(v.n_ops).val := h32; v.ops(v.n_ops).cnt := 1;
            v.n_ops := v.n_ops + 1; v.cs(cur).op1 := v.n_ops;
          when 'D' =>
            read(l, n); v.ops(v.n_ops).die := n; v.ops(v.n_ops).kind := 'D';
            read(l, n); v.ops(v.n_ops).cnt := n; v.ops(v.n_ops).off := 16#60#;
            hread(l, h32); v.ops(v.n_ops).val := h32;
            v.n_ops := v.n_ops + 1; v.cs(cur).op1 := v.n_ops;
          when others => null;
        end case;
      end if;
      deallocate(l);
    end loop;
    return v;
  end function;
end package body;
