-- Testbench for gdn_emit_chain, the site 12 -> rmsnorm_bf -> silu -> site 13
-- sequencer.  Vectors from ref/gdn_emit_chain_vec.c, whose own oracle is
-- double precision, so this is a check of the RTL against a reference that was
-- itself checked against a different number system.
--
-- WHY IT EXISTS.  Commit 72f5c8d shipped the chain with the note "the chain has
-- a reference and analyzes clean; it is not yet verified against the RTL".
-- Four seams are only compatible BY INSPECTION until this runs:
--
--   seam 1  head_emit's (o_mant, o_e_head)  -> rmsnorm_bf's (x_mant, x_exp)
--   seam 2  rmsnorm_bf's o_mant             -> y_emit's in_o
--   seam 3  silu's o_data                   -> y_emit's in_z
--   seam 4  rn_exp + z_e_held               -> y_emit's in_e
--
-- Seam 4 is the one that cannot be checked by inspection at all: it is an
-- exponent SUM, and an error in it is a clean power-of-two scaling of the whole
-- block, which looks like a plausible answer rather than a broken one.
--
-- BLOCK SERIALIZATION, deliberate.  This testbench waits for `done` before it
-- starts the next block's columns.  That is NOT how the chain is meant to run
-- (S_WAITBLK returns to S_IDLE immediately so blocks overlap), and it is not a
-- simplification for convenience: `w_mant` is a single unlatched port read
-- combinationally by rmsnorm_bf all block long, so a producer that changed w
-- on `done` would corrupt the next block, which starts its first rmsnorm
-- thousands of cycles BEFORE `done`.  See the header note in
-- rtl/gdn_emit_chain.vhd.  Overlapped blocks are covered separately once the
-- chain latches w.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_gdn_emit_chain is end entity;

architecture sim of tb_gdn_emit_chain is
  constant HEADS : integer := 24;
  constant DIM   : integer := 128;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal w_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal w_exp  : integer := 0;

  signal col_valid : std_logic := '0';
  signal col_acc   : signed(39 downto 0) := (others => '0');
  signal col_e_o   : signed(7 downto 0)  := (others => '0');
  signal col_ready : std_logic;

  signal z_mant  : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal z_exp   : signed(7 downto 0) := (others => '0');
  signal z_valid : std_logic := '0';
  signal z_ready : std_logic;

  signal y_valid : std_logic;
  signal y_mant  : signed(15 downto 0);
  signal y_last  : std_logic;
  signal y_exp   : signed(7 downto 0);
  signal done    : std_logic;
  signal y_sat   : std_logic;

  -- Collected block output.  Driven ONLY by the collector process; the
  -- stimulus process reads it.  Two drivers on one signal elaborate with no
  -- line number in ghdl, which cost real time twice in this project.
  type yarr_t is array (0 to HEADS*DIM-1) of integer;
  signal y_got   : yarr_t := (others => 0);
  signal y_cnt   : integer := 0;
  signal y_n     : integer := 0;
  signal y_e_got : integer := 0;
  signal blk_got : integer := 0;
begin

  clk <= (not clk) after 0.5 ns when running else '0';

  dut : entity work.gdn_emit_chain
    generic map ( HEADS => HEADS, DIM => DIM,
                  SILU_LANES => 32, RMS_LANES => 4, Q => 12, EPS => 1.0e-6 )
    port map ( clk => clk, rst => rst,
               w_mant => w_mant, w_exp => w_exp,
               col_valid => col_valid, col_acc => col_acc, col_e_o => col_e_o,
               col_ready => col_ready,
               z_mant => z_mant, z_exp => z_exp,
               z_valid => z_valid, z_ready => z_ready,
               y_valid => y_valid, y_mant => y_mant, y_last => y_last,
               y_exp => y_exp, done => done, y_sat => y_sat );

  -- ------------------------------------------------------------------ --
  -- collector
  -- ------------------------------------------------------------------ --
  collect : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        y_cnt <= 0; blk_got <= 0;
      else
        if y_valid = '1' then
          assert y_cnt < HEADS*DIM
            report "tb_gdn_emit_chain: more outputs than a block holds"
            severity failure;
          y_got(y_cnt) <= to_integer(y_mant);
          y_e_got <= to_integer(y_exp);
          y_cnt <= y_cnt + 1;
        end if;
        -- `done` closes the block: latch how many values it produced and
        -- rearm the counter.  Latching rather than leaving y_cnt standing is
        -- what makes the count checkable at all -- a bare reset here would
        -- hand the stimulus a zero and read as agreement.
        if done = '1' then
          blk_got <= blk_got + 1;
          if y_valid = '1' then y_n <= y_cnt + 1; else y_n <= y_cnt; end if;
          y_cnt <= 0;
        end if;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------ --
  -- stimulus
  -- ------------------------------------------------------------------ --
  stim : process
    file     vf : text;
    variable l  : line;
    variable ok : file_open_status;

    -- 64-bit decimal read.  textio's integer read is 32 bit and o_acc reaches
    -- 2^36, so it cannot be used here.  Silent truncation of the top bits
    -- would look like a chain error, not a testbench error.
    procedure rd64(variable ln : inout line; variable v : out signed(63 downto 0)) is
      variable c    : character;
      variable good : boolean;
      variable neg  : boolean := false;
      variable acc  : signed(63 downto 0) := (others => '0');
      variable started : boolean := false;
    begin
      loop
        read(ln, c, good);
        exit when not good;
        if c = ' ' or c = HT then
          if started then exit; end if;
        elsif c = '-' then
          neg := true; started := true;
        elsif c >= '0' and c <= '9' then
          started := true;
          acc := resize(acc * 10 + character'pos(c) - character'pos('0'), 64);
        else
          exit;
        end if;
      end loop;
      assert started report "tb_gdn_emit_chain: expected a number" severity failure;
      if neg then v := -acc; else v := acc; end if;
    end procedure;

    procedure rdi(variable ln : inout line; variable v : out integer) is
      variable t : signed(63 downto 0);
    begin
      rd64(ln, t); v := to_integer(t);
    end procedure;

    variable NB, HDR_H, HDR_D : integer;
    variable b_i, ye_i, sat_i, we_i, ze_i : integer;
    variable t64 : signed(63 downto 0);
    variable ti  : integer;

    type i64arr_t is array (0 to 511) of signed(63 downto 0);
    variable oacc : i64arr_t;
    variable eo   : yarr_t;
    variable yexp_arr : yarr_t;
    variable nbad : integer := 0;
    variable e    : integer;
  begin
    file_open(ok, vf, "gdn_emit_chain_vec.txt", read_mode);
    assert ok = open_ok
      report "tb_gdn_emit_chain: cannot open gdn_emit_chain_vec.txt"
      severity failure;

    readline(vf, l); rdi(l, NB); rdi(l, HDR_H); rdi(l, HDR_D);
    assert HDR_H = HEADS and HDR_D = DIM
      report "tb_gdn_emit_chain: vector shape does not match the generics"
      severity failure;

    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    for b in 0 to NB-1 loop
      readline(vf, l);
      rdi(l, b_i); rdi(l, ye_i); rdi(l, sat_i); rdi(l, we_i); rdi(l, ze_i);

      -- ssm_norm for this block
      readline(vf, l);
      for i in 0 to DIM-1 loop
        rdi(l, ti);
        w_mant((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(ti, 16));
      end loop;
      w_exp <= we_i;
      z_exp <= to_signed(ze_i, 8);
      wait until rising_edge(clk);

      for h in 0 to HEADS-1 loop
        readline(vf, l);
        for j in 0 to DIM-1 loop rd64(l, oacc(j)); end loop;
        readline(vf, l);
        for j in 0 to DIM-1 loop rdi(l, eo(j)); end loop;
        readline(vf, l);
        for j in 0 to DIM-1 loop
          rdi(l, ti);
          z_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(ti, 16));
        end loop;

        -- hand this head's gate vector over first; the chain latches it
        -- whenever it holds none, and releases it at the end of the previous
        -- head's serialization, so this is where back-pressure shows up.
        z_valid <= '1';
        loop
          wait until rising_edge(clk);
          exit when z_ready = '1';
        end loop;
        z_valid <= '0';

        -- then stream the head's DIM columns
        col_valid <= '1';
        for j in 0 to DIM-1 loop
          col_acc <= resize(oacc(j), 40);
          col_e_o <= to_signed(eo(j), 8);
          loop
            wait until rising_edge(clk);
            exit when col_ready = '1';
          end loop;
        end loop;
        col_valid <= '0';
      end loop;

      -- expected output for the block
      readline(vf, l);
      for i in 0 to HEADS*DIM-1 loop rdi(l, yexp_arr(i)); end loop;

      -- wait for the block to finish streaming out
      while blk_got < b+1 loop wait until rising_edge(clk); end loop;
      wait until rising_edge(clk);

      assert y_n = HEADS*DIM
        report "tb_gdn_emit_chain: block " & integer'image(b) & " emitted "
             & integer'image(y_n) & " values, expected "
             & integer'image(HEADS*DIM)
        severity failure;

      assert y_e_got = ye_i
        report "tb_gdn_emit_chain: block " & integer'image(b)
             & " y_exp is " & integer'image(y_e_got)
             & ", reference says " & integer'image(ye_i)
             & ".  A wrong block exponent is seam 4: it scales the whole "
             & "block by a power of two and still looks plausible."
        severity failure;

      for i in 0 to HEADS*DIM-1 loop
        e := y_got(i) - yexp_arr(i);
        if e /= 0 then
          nbad := nbad + 1;
          if nbad <= 8 then
            report "tb_gdn_emit_chain: block " & integer'image(b)
                 & " element " & integer'image(i)
                 & " head " & integer'image(i / DIM)
                 & " lane " & integer'image(i mod DIM)
                 & " got " & integer'image(y_got(i))
                 & " expected " & integer'image(yexp_arr(i))
              severity error;
          end if;
        end if;
      end loop;

      report "tb_gdn_emit_chain: block " & integer'image(b)
           & " checked, y_exp=" & integer'image(y_e_got)
           & ", mismatches so far " & integer'image(nbad);
    end loop;

    file_close(vf);

    if nbad = 0 then
      report "tb_gdn_emit_chain: PASS -- " & integer'image(NB)
           & " blocks x " & integer'image(HEADS) & " heads x "
           & integer'image(DIM) & " bit-exact against the reference"
        severity note;
    else
      report "tb_gdn_emit_chain: FAIL -- " & integer'image(nbad)
           & " mismatched elements"
        severity failure;
    end if;

    running <= false;
    wait;
  end process;

end architecture;
