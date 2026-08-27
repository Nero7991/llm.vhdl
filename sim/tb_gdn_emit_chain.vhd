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
-- TWO MODES, and the second is the one that matters.  With OVERLAP false the
-- testbench waits for `done` before starting the next block's columns.  With
-- OVERLAP true it does not, which is how the chain is actually designed to run:
-- S_WAITBLK returns to S_IDLE immediately, so block b+1's head 0 reaches its
-- norm thousands of cycles BEFORE block b's `done`, and gdn_y_emit's second
-- bank has to carry block b's output out from under it.
--
-- Overlapped mode is only meaningful because the chain now LATCHES w at head 0
-- and pulses `w_taken`.  Before that, w was a single unlatched port that
-- rmsnorm_bf read combinationally for every head of the block, and a producer
-- had no observable instant at which changing it was safe.  The testbench
-- honours the handshake -- it holds w until w_taken -- so it is testing the
-- protocol, not working around its absence.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_gdn_emit_chain is
  generic( OVERLAP : boolean := true );
end entity;

architecture sim of tb_gdn_emit_chain is
  constant HEADS : integer := 24;
  constant DIM   : integer := 128;
  -- Sized for the vector file, not for the design.  An overlapped run cannot
  -- check block b before block b+1 is already in flight, so every block's
  -- output is retained and checked at the end.
  constant MAX_BLOCKS : integer := 8;

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
  signal w_taken : std_logic;

  -- Collected block output.  Driven ONLY by the collector process; the
  -- stimulus process reads it.  Two drivers on one signal elaborate with no
  -- line number in ghdl, which cost real time twice in this project.
  type yarr_t  is array (0 to HEADS*DIM-1) of integer;
  type yall_t  is array (0 to MAX_BLOCKS*HEADS*DIM-1) of integer;
  type barr_t  is array (0 to MAX_BLOCKS-1) of integer;
  signal y_got   : yall_t := (others => 0);
  signal y_idx   : integer := 0;
  signal ye_got  : barr_t := (others => 0);
  signal cnt_got : barr_t := (others => 0);
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
               y_exp => y_exp, done => done, y_sat => y_sat,
               w_taken => w_taken );

  -- ------------------------------------------------------------------ --
  -- collector
  -- ------------------------------------------------------------------ --
  collect : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        y_idx <= 0; blk_got <= 0;
      else
        if y_valid = '1' then
          assert blk_got < MAX_BLOCKS and y_idx < MAX_BLOCKS*HEADS*DIM
            report "tb_gdn_emit_chain: more output than MAX_BLOCKS holds"
            severity failure;
          y_got(y_idx)   <= to_integer(y_mant);
          y_idx          <= y_idx + 1;
          -- blk_got does not advance until the cycle after `done`, so a value
          -- landing on the same edge as `done` is still attributed to the
          -- block it belongs to.
          ye_got(blk_got)  <= to_integer(y_exp);
          cnt_got(blk_got) <= cnt_got(blk_got) + 1;
        end if;
        if done = '1' then
          blk_got <= blk_got + 1;
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
    variable yexp_all : yall_t;
    variable ye_ref   : barr_t;
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

    -- ---- feed every block --------------------------------------------
    for b in 0 to NB-1 loop
      readline(vf, l);
      rdi(l, b_i); rdi(l, ye_i); rdi(l, sat_i); rdi(l, we_i); rdi(l, ze_i);
      ye_ref(b) := ye_i;

      -- ssm_norm for this block.  It is presented BEFORE the block's columns
      -- and held until w_taken, which is the contract the latch establishes.
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

        -- The weight latch fires on head 0.  Waiting for it here rather than
        -- assuming it keeps the testbench honest about the handshake: if
        -- w_taken never pulsed, this hangs rather than passing.
        if h = 0 then
          while w_taken = '0' loop wait until rising_edge(clk); end loop;
        end if;
      end loop;

      -- expected output for the block, stashed rather than checked, because in
      -- overlapped mode block b is still streaming out while b+1 is fed.
      readline(vf, l);
      for i in 0 to HEADS*DIM-1 loop rdi(l, yexp_all(b*HEADS*DIM + i)); end loop;

      if not OVERLAP then
        while blk_got < b+1 loop wait until rising_edge(clk); end loop;
      end if;
    end loop;

    -- ---- drain -------------------------------------------------------
    while blk_got < NB loop wait until rising_edge(clk); end loop;
    wait until rising_edge(clk);

    -- ---- check -------------------------------------------------------
    for b in 0 to NB-1 loop
      assert cnt_got(b) = HEADS*DIM
        report "tb_gdn_emit_chain: block " & integer'image(b) & " emitted "
             & integer'image(cnt_got(b)) & " values, expected "
             & integer'image(HEADS*DIM)
        severity failure;

      assert ye_got(b) = ye_ref(b)
        report "tb_gdn_emit_chain: block " & integer'image(b)
             & " y_exp is " & integer'image(ye_got(b))
             & ", reference says " & integer'image(ye_ref(b))
             & ".  A wrong block exponent is seam 4: it scales the whole "
             & "block by a power of two and still looks plausible."
        severity failure;

      for i in 0 to HEADS*DIM-1 loop
        if y_got(b*HEADS*DIM + i) /= yexp_all(b*HEADS*DIM + i) then
          nbad := nbad + 1;
          if nbad <= 8 then
            report "tb_gdn_emit_chain: block " & integer'image(b)
                 & " element " & integer'image(i)
                 & " head " & integer'image(i / DIM)
                 & " lane " & integer'image(i mod DIM)
                 & " got " & integer'image(y_got(b*HEADS*DIM + i))
                 & " expected " & integer'image(yexp_all(b*HEADS*DIM + i))
              severity error;
          end if;
        end if;
      end loop;

      report "tb_gdn_emit_chain: block " & integer'image(b)
           & " checked, y_exp=" & integer'image(ye_got(b))
           & ", mismatches so far " & integer'image(nbad);
    end loop;

    file_close(vf);

    if nbad = 0 then
      report "tb_gdn_emit_chain: PASS -- " & integer'image(NB)
           & " blocks x " & integer'image(HEADS) & " heads x "
           & integer'image(DIM) & " bit-exact against the reference, OVERLAP="
           & boolean'image(OVERLAP)
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
