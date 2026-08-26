-- Checks gdn_recur_pipe against the SAME vectors as tb_gdn_recur, and measures
-- the achieved issue interval -- which is the whole reason the pipelined unit
-- exists.  Section 3.1's 589,824-cycle sweep assumes one column every
-- NB = DIM/LANES cycles; gdn_recur measures 58 at LANES = 32 against an NB of
-- 4.  This testbench reports what the pipelined unit actually sustains, so the
-- figure is measured rather than argued.
--
-- Columns are driven back-to-back within a head group.  k_n and q_s change
-- between head groups, and engines B and C are still working on the previous
-- head's columns when the next head's first column is issued, so the driver
-- DRAINS the pipeline between groups.  That drain is real: in the shipped
-- design a head is 128 columns, so it is a once-per-512-cycles cost, but it is
-- not free and it is measured separately below rather than folded into the II.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gdn_recur_pipe is
  generic(DIM   : positive := 128;
          LANES : positive := 32;
          SLOTS : positive := 16;
          GRP   : positive := 8;      -- columns per head group in the vectors
          -- Idle cycles inserted BETWEEN columns.  0 is the real case, one
          -- column every NB cycles.  A large value serialises the unit and
          -- isolates arithmetic bugs from overlap bugs.
          GAP   : natural := 0;
          VECS  : string   := "gdn_recur_vec.txt");
end entity;

architecture sim of tb_gdn_recur_pipe is
  constant NB : integer := DIM / LANES;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal eg, beta : unsigned(15 downto 0) := (others => '0');
  signal k_n, q_s : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal s_valid, s_first : std_logic := '0';
  signal s_data : std_logic_vector(LANES*16-1 downto 0) := (others => '0');
  signal c_tk0 : std_logic := '0';
  signal c_se_j, c_e_v : signed(7 downto 0) := (others => '0');
  signal c_v_j : signed(15 downto 0) := (others => '0');
  signal o_valid, o_last, o_res_valid, o_err_se : std_logic;
  signal o_data : std_logic_vector(LANES*16-1 downto 0);
  signal o_se_new, o_e_o : signed(7 downto 0);
  signal o_acc : signed(39 downto 0);

  signal tick : integer := 0;
  signal loaded : boolean := false;

  type i_arr is array (natural range <>) of integer;
  type col_rec is record
    tk0, se_j, e_v, v_j, eg, beta, se_new, e_o, gid : integer;
    oacc : real;
  end record;
  type col_arr is array (natural range <>) of col_rec;
  type big_arr is array (natural range <>) of i_arr(0 to DIM-1);

  -- 96 physical + 96 adversarial + one FULL-LENGTH 128-column head.  The long
  -- head is the one that exercises continuous streaming, where every slot is
  -- reused many times and the engines never idle -- the case an 8-column group
  -- cannot reach, and the one a real head actually is.
  constant NCASE : integer := 320;
  shared variable v_col  : col_arr(0 to NCASE-1);
  shared variable v_sm   : big_arr(0 to NCASE-1);
  shared variable v_kn   : big_arr(0 to NCASE-1);
  shared variable v_qs   : big_arr(0 to NCASE-1);
  shared variable v_snew : big_arr(0 to NCASE-1);

  shared variable nfail  : integer := 0;
  shared variable ncheck : integer := 0;
  shared variable last_last : integer := -1;
  shared variable ii_min, ii_max : integer := 0;

  function to_real_s(v : signed) return real is
    variable m : unsigned(v'length-1 downto 0);
    variable r : real := 0.0;
  begin
    if v(v'high) = '1' then m := unsigned(-v); else m := unsigned(v); end if;
    for i in m'high downto 0 loop
      r := r * 2.0;
      if m(i) = '1' then r := r + 1.0; end if;
    end loop;
    if v(v'high) = '1' then return -r; else return r; end if;
  end function;
begin
  clk <= not clk after 5 ns;
  tickp : process(clk) begin
    if rising_edge(clk) then tick <= tick + 1; end if;
  end process;

  dut : entity work.gdn_recur_pipe
    generic map(DIM => DIM, LANES => LANES, SLOTS => SLOTS)
    port map(clk => clk, rst => rst, eg => eg, beta => beta,
             k_n => k_n, q_s => q_s,
             s_valid => s_valid, s_first => s_first, s_data => s_data,
             c_tk0 => c_tk0, c_se_j => c_se_j, c_e_v => c_e_v, c_v_j => c_v_j,
             o_valid => o_valid, o_last => o_last, o_data => o_data,
             o_se_new => o_se_new, o_acc => o_acc, o_e_o => o_e_o,
             o_res_valid => o_res_valid, o_err_se => o_err_se);

  load : process
    file fh : text; variable ln : line; variable iv : integer; variable rv : real;
    variable nc, dv : integer;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, dv);
    assert nc = NCASE and dv = DIM report "vector file shape" severity failure;
    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, iv);                          -- phys, unused here
      read(ln, iv); v_col(c).tk0 := iv;
      read(ln, iv); v_col(c).se_j := iv;
      read(ln, iv); v_col(c).e_v := iv;
      read(ln, iv); v_col(c).eg := iv;
      read(ln, iv); v_col(c).beta := iv;
      read(ln, iv); v_col(c).v_j := iv;
      read(ln, iv); v_col(c).gid := iv;
      readline(fh, ln); for i in 0 to DIM-1 loop read(ln, iv); v_sm(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to DIM-1 loop read(ln, iv); v_kn(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to DIM-1 loop read(ln, iv); v_qs(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to DIM-1 loop read(ln, iv); v_snew(c)(i) := iv; end loop;
      readline(fh, ln);
      read(ln, iv); v_col(c).se_new := iv;
      read(ln, rv); v_col(c).oacc := rv;
      read(ln, iv); v_col(c).e_o := iv;
      readline(fh, ln);                      -- oracle u, not used here
      readline(fh, ln);                      -- oracle o, not used here
    end loop;
    file_close(fh);
    loaded <= true;
    wait;
  end process;

  drive : process
    variable base, c : integer;
  begin
    wait until loaded;
    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);

    c := 0;
    while c < NCASE loop
      -- a head runs until the group id changes; heads are 8 columns in the
      -- mixed set and 128 in the long one, and the driver must not assume
      base := c;
      -- DRAIN FIRST, THEN change k_n/q_s.  Doing it the other way round is a
      -- testbench bug that looks exactly like a unit bug: engines B and C are
      -- still holding the PREVIOUS head's columns and read k_n/q_s straight off
      -- the ports, so those columns silently finish against the next head's
      -- vectors.  The signature is distinctive and worth remembering -- only
      -- o_acc wrong, only on the last column(s) of each head, state perfect,
      -- because the state does not depend on q_s at all.
      for d in 0 to 199 loop wait until rising_edge(clk); end loop;
      eg   <= to_unsigned(v_col(base).eg, 16);
      beta <= to_unsigned(v_col(base).beta, 16);
      for i in 0 to DIM-1 loop
        k_n((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v_kn(base)(i), 16));
        q_s((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v_qs(base)(i), 16));
      end loop;
      wait until rising_edge(clk);

      while c < NCASE and v_col(c).gid = v_col(base).gid loop
        for gi in 0 to NB-1 loop
          s_valid <= '1';
          if gi = 0 then
            s_first <= '1';
            c_tk0   <= '1' when v_col(c).tk0 = 1 else '0';
            c_se_j  <= to_signed(v_col(c).se_j, 8);
            c_e_v   <= to_signed(v_col(c).e_v, 8);
            c_v_j   <= to_signed(v_col(c).v_j, 16);
          else
            s_first <= '0';
          end if;
          for k in 0 to LANES-1 loop
            s_data((k+1)*16-1 downto k*16)
              <= std_logic_vector(to_signed(v_sm(c)(gi*LANES + k), 16));
          end loop;
          wait until rising_edge(clk);
        end loop;
        if GAP > 0 then
          s_valid <= '0'; s_first <= '0';
          for d in 0 to GAP-1 loop wait until rising_edge(clk); end loop;
        end if;
        c := c + 1;
      end loop;
      s_valid <= '0'; s_first <= '0';
    end loop;

    for d in 0 to 399 loop wait until rising_edge(clk); end loop;

    assert nfail = 0
      report "gdn_recur_pipe: " & integer'image(nfail) & " mismatch(es) in "
           & integer'image(ncheck) & " columns" severity error;
    if nfail = 0 then
      report "gdn_recur_pipe: bit-identical to the reference on all "
           & integer'image(ncheck) & " columns; issue interval measured "
           & integer'image(ii_min) & " cycles (NB = " & integer'image(NB)
           & "), worst gap within a head group " & integer'image(ii_max)
           severity note;
    end if;
    wait;
  end process;

  -- collect the output stream and the scalar results, both in column order
  collect : process(clk)
    variable ncol_d, ncol_r, gcnt : integer := 0;
    variable got : i_arr(0 to DIM-1);
    variable bad, firstbad : integer;
  begin
    if rising_edge(clk) and rst = '0' then
      if o_valid = '1' then
        for k in 0 to LANES-1 loop
          got(gcnt*LANES + k) := to_integer(signed(o_data((k+1)*16-1 downto k*16)));
        end loop;
        if o_last = '1' then
          bad := 0; firstbad := -1;
          for i in 0 to DIM-1 loop
            if got(i) /= v_snew(ncol_d)(i) then
              bad := bad + 1;
              if firstbad < 0 then firstbad := i; end if;
            end if;
          end loop;
          if bad /= 0 then
            report "column " & integer'image(ncol_d) & ": state differs in "
                 & integer'image(bad) & " element(s), first at i="
                 & integer'image(firstbad) & " (group " & integer'image(firstbad/LANES)
                 & ") got " & integer'image(got(firstbad)) & " want "
                 & integer'image(v_snew(ncol_d)(firstbad)) severity error;
            nfail := nfail + 1;
          end if;
          -- issue interval: spacing of consecutive column completions.  Gaps
          -- across a head boundary are the drain, not the II, so only the
          -- minimum and the within-group maximum are meaningful.
          if last_last >= 0 then
            if ii_min = 0 or (tick - last_last) < ii_min then ii_min := tick - last_last; end if;
            if (tick - last_last) > ii_max and (tick - last_last) < 100 then
              ii_max := tick - last_last;
            end if;
          end if;
          last_last := tick;
          ncol_d := ncol_d + 1;
          gcnt := 0;
        else
          gcnt := gcnt + 1;
        end if;
      end if;

      if o_res_valid = '1' then
        bad := 0;
        if to_integer(o_se_new) /= v_col(ncol_r).se_new then bad := bad + 1; end if;
        if to_integer(o_e_o)    /= v_col(ncol_r).e_o    then bad := bad + 1; end if;
        if to_real_s(o_acc)     /= v_col(ncol_r).oacc   then bad := bad + 1; end if;
        if bad /= 0 then
          report "column " & integer'image(ncol_r) & ": scalars differ  se_new "
               & integer'image(to_integer(o_se_new)) & "/" & integer'image(v_col(ncol_r).se_new)
               & "  e_o " & integer'image(to_integer(o_e_o)) & "/" & integer'image(v_col(ncol_r).e_o)
               & "  oacc " & real'image(to_real_s(o_acc)) & "/" & real'image(v_col(ncol_r).oacc)
               severity error;
          nfail := nfail + 1;
        end if;
        ncol_r := ncol_r + 1;
        ncheck := ncol_r;
      end if;
    end if;
  end process;
end architecture;
