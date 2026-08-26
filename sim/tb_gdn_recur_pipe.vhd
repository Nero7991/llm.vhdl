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
          -- Case count, checked against the vector file's own header so a
          -- mismatch is a loud assertion rather than a silent short run.
          NCASE : positive := 384;
          GRP   : positive := 8;      -- columns per head group in the vectors
          -- Flip together with VECS; a mismatch is a loud bit-exact failure.
          D_NORM : boolean := true;   -- ADOPTED 2026-08-26, matches the DUT
          TK0_ED : boolean := true;   -- ADOPTED 2026-08-26, matches the DUT
          EG0_ED : boolean := true;   -- ADOPTED 2026-08-26, matches the DUT
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
  signal c_hsel : std_logic := '0';
  signal kq_we  : std_logic := '0';
  signal kq_wsel : std_logic := '0';
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
    tk0, se_j, e_v, v_j, eg, beta, se_new, e_o, gid, err : integer;
    oacc : real;
  end record;
  type col_arr is array (natural range <>) of col_rec;
  type big_arr is array (natural range <>) of i_arr(0 to DIM-1);

  shared variable v_col  : col_arr(0 to NCASE-1);
  shared variable v_sm   : big_arr(0 to NCASE-1);
  shared variable v_kn   : big_arr(0 to NCASE-1);
  shared variable v_qs   : big_arr(0 to NCASE-1);
  shared variable v_snew : big_arr(0 to NCASE-1);

  shared variable nfail  : integer := 0;
  shared variable ncheck : integer := 0;
  shared variable last_last : integer := -1;
  shared variable ii_min, ii_max : integer := 0;
  -- Worst gap ACROSS a head boundary, kept separate from ii_max because it is
  -- the quantity the double buffer exists to remove.  ii_max deliberately
  -- filters gaps >= 100 so that the within-group number stays meaningful; this
  -- one filters nothing.
  shared variable ii_head : integer := 0;

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
    generic map(DIM => DIM, LANES => LANES, SLOTS => SLOTS, D_NORM => D_NORM,
                TK0_ED => TK0_ED, EG0_ED => EG0_ED)
    port map(clk => clk, rst => rst,
             kq_we => kq_we, kq_wsel => kq_wsel,
             eg => eg, beta => beta,
             k_n => k_n, q_s => q_s,
             s_valid => s_valid, s_first => s_first, s_data => s_data,
             c_tk0 => c_tk0, c_hsel => c_hsel,
             c_se_j => c_se_j, c_e_v => c_e_v, c_v_j => c_v_j,
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
      read(ln, iv); v_col(c).err := iv;
      readline(fh, ln);                      -- oracle u, not used here
      readline(fh, ln);                      -- oracle o, not used here
    end loop;
    file_close(fh);
    loaded <= true;
    wait;
  end process;

  drive : process
    variable base, c : integer;
    -- bank alternates per head; prev_end / prev2_end are the column counts
    -- through the previous head and the one before it, which is the head that
    -- last used the bank about to be overwritten.
    variable bank : std_logic := '0';
    variable prev_end, prev2_end : integer := 0;
    -- Cycles actually spent waiting for a bank to free, which is what the old
    -- unconditional 200-cycle drain has been replaced by.  Reported as a total
    -- and as a worst case, split by whether the head that last used the bank
    -- was long enough to cover the pipe (DC + 2*NB cycles ~ 15 columns at
    -- II = NB).  Production heads are 128 columns and always are.
    variable stall, stall_tot, stall_max, stall_max_long : integer := 0;
    variable nhead : integer := 0;
    variable prev_len : integer := 0;
  begin
    wait until loaded;
    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);

    c := 0;
    while c < NCASE loop
      -- a head runs until the group id changes; heads are 8 columns in the
      -- mixed set and 128 in the long one, and the driver must not assume
      base := c;
      -- The unit double-buffers k_n/q_s/eg/beta, so this head loads into the
      -- bank the PREVIOUS head is not using and issue never has to stop.  The
      -- old version of this loop drained 200 cycles here, which is precisely
      -- the 11.7% the buffer removes.
      --
      -- What still has to be waited for: the head that used THIS bank two heads
      -- ago must have fully retired, or its columns finish against the new
      -- vectors.  With production 128-column heads the pipe (DC + NB ~ 56
      -- cycles) has always drained long before, so the wait is free; it only
      -- bites in this vector set, whose mixed heads are 8 columns.  The unit
      -- asserts the same invariant from the inside, so a testbench that got
      -- this wrong would fail loudly rather than produce wrong numbers -- which
      -- is the point, because the previous failure mode here was silent: only
      -- o_acc wrong, only on the last column(s) of each head, state perfect,
      -- because the state does not depend on q_s at all.
      stall := 0;
      while ncheck < prev2_end loop
        wait until rising_edge(clk); stall := stall + 1;
      end loop;
      stall_tot := stall_tot + stall;
      if stall > stall_max then stall_max := stall; end if;
      if prev_len >= 16 and stall > stall_max_long then stall_max_long := stall; end if;
      kq_wsel <= bank;
      eg   <= to_unsigned(v_col(base).eg, 16);
      beta <= to_unsigned(v_col(base).beta, 16);
      for i in 0 to DIM-1 loop
        k_n((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v_kn(base)(i), 16));
        q_s((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v_qs(base)(i), 16));
      end loop;
      wait until rising_edge(clk);
      kq_we <= '1';
      wait until rising_edge(clk);
      kq_we <= '0';

      while c < NCASE and v_col(c).gid = v_col(base).gid loop
        for gi in 0 to NB-1 loop
          s_valid <= '1';
          if gi = 0 then
            s_first <= '1';
            c_tk0   <= '1' when v_col(c).tk0 = 1 else '0';
            c_hsel  <= bank;
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
      nhead := nhead + 1;
      prev_len := c - prev_end;
      prev2_end := prev_end; prev_end := c;
      bank := not bank;
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
           & ", worst gap ACROSS a head boundary " & integer'image(ii_head)
           severity note;
      report "gdn_recur_pipe: bank-free wait totals " & integer'image(stall_tot)
           & " cycles over " & integer'image(nhead) & " head boundaries, worst "
           & integer'image(stall_max) & "; worst after a head of >= 16 columns "
           & integer'image(stall_max_long)
           & " (the old unconditional drain was 200 per boundary)"
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
          -- Issue interval: spacing of consecutive column completions.  The
          -- within-group max keeps its < 100 filter so it stays comparable with
          -- the pre-double-buffer runs; the head-boundary gap is now measured
          -- SEPARATELY and unfiltered, because that gap is the whole point of
          -- the buffer and hiding it behind a filter is how it went unnoticed.
          if last_last >= 0 then
            if ii_min = 0 or (tick - last_last) < ii_min then ii_min := tick - last_last; end if;
            if ncol_d > 0 and v_col(ncol_d).gid /= v_col(ncol_d-1).gid then
              if (tick - last_last) > ii_head then ii_head := tick - last_last; end if;
            elsif (tick - last_last) > ii_max and (tick - last_last) < 100 then
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
        -- 2.1.6: an out-of-int8 exponent must be REPORTED; the value is then
        -- meaningless by definition, so the check is that err_se fires.
        if v_col(ncol_r).err = 1 then
          if o_err_se /= '1' then bad := bad + 1; end if;
        else
          if to_integer(o_se_new) /= v_col(ncol_r).se_new then bad := bad + 1; end if;
          if to_integer(o_e_o)    /= v_col(ncol_r).e_o    then bad := bad + 1; end if;
        end if;
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
