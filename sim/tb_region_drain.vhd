-- sim/tb_region_drain.vhd -- 2026-09-20.  TRACK DSIDE.
--
-- THE A-SIDE y DRAIN, NARROW AGAINST WIDE, ON ONE REGION-FILE MODEL EACH.
--
-- THE QUESTION this bench answers: does the LANES-way group write port
-- produce the SAME REGION FILE as the shipping one-element-per-cycle drain,
-- and in how many cycles?
--
-- WHAT IS AN ORACLE HERE AND WHAT IS NOT.  The two DUTs are compared to each
-- other, which alone would be a round trip and would pass for two wrong
-- implementations that are wrong the same way.  It is not: the NARROW arm of
-- `rtl/region_drain.vhd` is `rtl/llama_top.vhd`'s S_DRAIN, and the WIDE arm
-- is a different traversal (`ybw` word by word, LANES lanes at a time,
-- through a different memory port with per-lane enables) with no shared code
-- below the entity.  A THIRD, independent model is built here in the bench
-- from the descriptor alone -- `expect(reg, off + i) = ybw(i / ROWS_IF) lane
-- (i mod ROWS_IF)` -- and BOTH memories are checked against it, element by
-- element, over the WHOLE address space so a stray write outside the vector
-- is caught as loudly as a wrong one inside it.
--
-- THE MEMORY MODEL is `rtl/llama_top.vhd`'s `memp` (llama_top.vhd:1679-1700):
-- the element arm writes `mem(reg*REGMAX + addr)`, the group arm writes
-- `mem(reg*REGMAX + w_addr*LANES + i)` for each lane whose `w_be` is set and
-- whose address is in range.  Both arms are reproduced verbatim, because a
-- wide write that the real region file would not perform is not a saving.
--
-- THE POISON PREFILL.  Every location of both memories starts at a value no
-- test vector produces, so an element the drain FAILED to write is a
-- mismatch rather than a lucky zero.
--
-- SENTINEL: `DSIDE_CYCLES <case> narrow <n> wide <n>`, one line per case.
--
-- NO HARDWARE.  Simulation only.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_region_drain is
end entity;

architecture sim of tb_region_drain is
  constant ROWS_IF : positive := 48;
  constant MANT_W  : positive := 16;
  constant LANES   : positive := 8;
  constant YWORDS  : positive := 256;
  constant NREGION : positive := 4;
  constant REGMAX  : positive := 12288;
  constant GA_W    : positive := 12;     -- REGMAX/LANES = 1536 fits in 12

  constant PERIOD : time := 10 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  -- ---- the y tile buffer, shared by both DUTs -------------------------
  type ybw_t is array (0 to YWORDS-1)
    of std_logic_vector(ROWS_IF*MANT_W-1 downto 0);
  signal ybw : ybw_t := (others => (others => '0'));

  -- ---- descriptor -----------------------------------------------------
  signal d_rows : natural range 0 to REGMAX := 0;
  signal d_off  : natural range 0 to REGMAX := 0;
  signal d_reg  : natural range 0 to 127 := 0;
  signal start  : std_logic := '0';

  -- ---- DUT faces ------------------------------------------------------
  signal n_ra, w_ra : natural range 0 to YWORDS-1 := 0;
  signal n_rd, w_rd : std_logic_vector(ROWS_IF*MANT_W-1 downto 0);

  signal n_uwe, w_uwe : std_logic;
  signal n_ureg, w_ureg : natural range 0 to 127;
  signal n_uad, w_uad : natural range 0 to REGMAX-1;
  signal n_udat, w_udat : signed(MANT_W-1 downto 0);

  signal n_wwe, w_wwe : std_logic;
  signal n_wreg, w_wreg : natural range 0 to 127;
  signal n_wad, w_wad : unsigned(GA_W-1 downto 0);
  signal n_wbe, w_wbe : std_logic_vector(LANES-1 downto 0);
  signal n_wdat, w_wdat : std_logic_vector(LANES*MANT_W-1 downto 0);

  signal n_done, w_done : std_logic;
  signal n_wu, w_wu : std_logic;

  -- ---- the two region files -------------------------------------------
  constant POISON : signed(MANT_W-1 downto 0) := to_signed(-31337, MANT_W);
  type mem_t is array (0 to NREGION*REGMAX-1) of signed(MANT_W-1 downto 0);
  signal mem_n : mem_t := (others => POISON);
  signal mem_w : mem_t := (others => POISON);

  -- cycle counters, driven by the clocked counter process
  signal cyc : natural := 0;

  -- ONE DRIVER PER MEMORY.  The prefill is done BY the memory process on
  -- `clr`, not by the stimulus process: a second driver on `mem_n` resolves
  -- against the memory process's own 'U' driver and every location reads
  -- back as 'U', which `to_integer` reports as 0.  MEASURED here on the
  -- first run of this bench, and it looked exactly like a drain that never
  -- wrote anything.
  signal clr : std_logic := '0';

  -- A deterministic, position-dependent mantissa.  Distinct for every
  -- (word, lane) pair in the range this bench uses, and never POISON.
  function ycell(word, lane : natural) return signed is
    variable v : integer;
  begin
    v := ((word * 7919 + lane * 104729) mod 60013) - 30000;
    if v = -31337 then v := 1; end if;
    return to_signed(v, MANT_W);
  end function;

begin
  clk <= not clk after PERIOD/2 when running else '0';

  cntp : process(clk) is
  begin
    if rising_edge(clk) then cyc <= cyc + 1; end if;
  end process;

  -- Combinational y reads, one per DUT.  llama_top reads `ybw(rword)` in the
  -- same cycle it drives `uw_data`; the DUT's `yb_raddr` is that index.
  n_rd <= ybw(n_ra);
  w_rd <= ybw(w_ra);

  u_narrow : entity work.region_drain
    generic map(ROWS_IF => ROWS_IF, MANT_W => MANT_W, YWORDS => YWORDS,
                LANES => LANES, GA_W => GA_W, REGMAX => REGMAX,
                WIDE => false)
    port map(clk => clk, rst => rst, start => start,
             n_rows => d_rows, dst_off => d_off, dst_reg => d_reg,
             yb_raddr => n_ra, yb_rdata => n_rd,
             uw_en => n_uwe, uw_reg => n_ureg, uw_addr => n_uad,
             uw_data => n_udat,
             w_we => n_wwe, w_reg => n_wreg, w_addr => n_wad,
             w_be => n_wbe, w_data => n_wdat,
             done => n_done, o_wide_used => n_wu);

  u_wide : entity work.region_drain
    generic map(ROWS_IF => ROWS_IF, MANT_W => MANT_W, YWORDS => YWORDS,
                LANES => LANES, GA_W => GA_W, REGMAX => REGMAX,
                WIDE => true)
    port map(clk => clk, rst => rst, start => start,
             n_rows => d_rows, dst_off => d_off, dst_reg => d_reg,
             yb_raddr => w_ra, yb_rdata => w_rd,
             uw_en => w_uwe, uw_reg => w_ureg, uw_addr => w_uad,
             uw_data => w_udat,
             w_we => w_wwe, w_reg => w_wreg, w_addr => w_wad,
             w_be => w_wbe, w_data => w_wdat,
             done => w_done, o_wide_used => w_wu);

  -- ---- the region files.  llama_top.vhd:1679-1700, both write arms. ----
  memn : process(clk) is
    variable a : natural;
  begin
    if rising_edge(clk) then
      if clr = '1' then
        mem_n <= (others => POISON);
      end if;
      if n_uwe = '1' then
        mem_n(n_ureg*REGMAX + n_uad) <= n_udat;
      end if;
      if n_wwe = '1' then
        for i in 0 to LANES-1 loop
          if n_wbe(i) = '1' then
            a := n_wreg*REGMAX + to_integer(n_wad)*LANES + i;
            if a < NREGION*REGMAX then
              mem_n(a) <= signed(n_wdat((i+1)*MANT_W-1 downto i*MANT_W));
            end if;
          end if;
        end loop;
      end if;
    end if;
  end process;

  memw : process(clk) is
    variable a : natural;
  begin
    if rising_edge(clk) then
      if clr = '1' then
        mem_w <= (others => POISON);
      end if;
      if w_uwe = '1' then
        mem_w(w_ureg*REGMAX + w_uad) <= w_udat;
      end if;
      if w_wwe = '1' then
        for i in 0 to LANES-1 loop
          if w_wbe(i) = '1' then
            a := w_wreg*REGMAX + to_integer(w_wad)*LANES + i;
            if a < NREGION*REGMAX then
              mem_w(a) <= signed(w_wdat((i+1)*MANT_W-1 downto i*MANT_W));
            end if;
          end if;
        end loop;
      end if;
    end if;
  end process;

  stim : process is
    -- CHECKS ARE COUNTED IN VARIABLES.  A signal assigned twice in one delta
    -- keeps only the last value, so consecutive counts collapse to one.
    variable checks : natural := 0;
    variable fail   : natural := 0;
    variable tn, tw : natural := 0;      -- per-case cycle counts
    variable t0     : natural := 0;
    variable sum_n, sum_w : natural := 0;

    procedure tick is
    begin
      wait until rising_edge(clk);
    end procedure;

    procedure chk(c : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not c then
        fail := fail + 1;
        report "TB_REGION_DRAIN CHECK FAILED: " & msg severity error;
      end if;
    end procedure;

    -- Fill the y buffer and clear both memories to POISON.
    procedure prime is
    begin
      for wd in 0 to YWORDS-1 loop
        for ln in 0 to ROWS_IF-1 loop
          ybw(wd)((ln+1)*MANT_W-1 downto ln*MANT_W)
            <= std_logic_vector(ycell(wd, ln));
        end loop;
      end loop;
      clr <= '1';
      tick;
      clr <= '0';
      tick;
    end procedure;

    -- Run one descriptor through both DUTs, count cycles, then check BOTH
    -- memories against the independent model and against each other.
    procedure run_case(name : string; rows, off, reg : natural;
                       want_wide : std_logic) is
      variable ndone, wdone : boolean := false;
      variable exp : signed(MANT_W-1 downto 0);
      variable got_n, got_w : signed(MANT_W-1 downto 0);
      variable bad : natural := 0;
      variable lo, hi : natural;
    begin
      prime;
      d_rows <= rows; d_off <= off; d_reg <= reg;
      tick;
      t0 := cyc;
      start <= '1'; tick; start <= '0';
      ndone := false; wdone := false;
      tn := 0; tw := 0;
      while not (ndone and wdone) loop
        if n_done = '1' and not ndone then ndone := true; tn := cyc - t0; end if;
        if w_done = '1' and not wdone then wdone := true; tw := cyc - t0; end if;
        exit when cyc - t0 > 4*REGMAX + 64;
        tick;
      end loop;
      if n_done = '1' and not ndone then ndone := true; tn := cyc - t0; end if;
      if w_done = '1' and not wdone then wdone := true; tw := cyc - t0; end if;
      tick; tick;                        -- let the last write land
      chk(ndone, name & ": the narrow DUT must finish");
      chk(wdone, name & ": the wide DUT must finish");
      chk(w_wu = want_wide,
          name & ": o_wide_used must be " & std_logic'image(want_wide));
      -- THE INDEPENDENT MODEL, over the WHOLE address space of both memories.
      lo := 0; hi := NREGION*REGMAX - 1;
      bad := 0;
      for a in lo to hi loop
        if a >= reg*REGMAX + off and a < reg*REGMAX + off + rows then
          exp := ycell((a - reg*REGMAX - off) / ROWS_IF,
                       (a - reg*REGMAX - off) mod ROWS_IF);
        else
          exp := POISON;
        end if;
        got_n := mem_n(a);
        got_w := mem_w(a);
        if got_n /= exp or got_w /= exp then
          bad := bad + 1;
          if bad <= 4 then
            report "TB_REGION_DRAIN " & name & ": addr " & integer'image(a)
                 & " want " & integer'image(to_integer(exp))
                 & " narrow " & integer'image(to_integer(got_n))
                 & " wide " & integer'image(to_integer(got_w))
              severity error;
          end if;
        end if;
      end loop;
      chk(bad = 0, name & ": both memories must equal the model everywhere ("
                 & integer'image(bad) & " differ)");
      sum_n := sum_n + tn;
      sum_w := sum_w + tw;
      report "DSIDE_CYCLES " & name & " narrow " & integer'image(tn)
           & " wide " & integer'image(tw)
           & " rows " & integer'image(rows)
           & " off " & integer'image(off) severity note;
    end procedure;

  begin
    rst <= '1'; tick; tick; rst <= '0'; tick;

    -- ---- the shipping shapes.  Every one of the 311 A jobs of a 9B token
    -- has dst_off in {0, 2048, 4096} and n_rows in {32, 1024, 2048, 4096,
    -- 5056, 8192, 12288, 17376}; the ones that fit this bench's REGMAX are
    -- run here.  (MEASURED from tools/gen_layer_program.build_plan.)
    run_case("ffn_gate_12288", 12288, 0, 3, '1');
    run_case("hidden_4096",     4096, 0, 1, '1');
    run_case("qkv_2048_off2048", 2048, 2048, 2, '1');
    run_case("qkv_4096_off4096", 4096, 4096, 2, '1');
    run_case("ssm_beta_32",        32, 0, 1, '1');
    run_case("kv_1024",          1024, 0, 2, '1');

    -- ---- shapes the shipping schedule does not produce, which is exactly
    -- why they are here: the tail, the word boundary, and the misaligned
    -- offset that must FALL BACK rather than round.
    run_case("tail_100",          100, 0, 3, '1');   -- 100 mod 8 = 4
    run_case("one_word_48",        48, 0, 1, '1');
    run_case("cross_word_50",      50, 8, 2, '1');   -- straddles word 0/1
    run_case("single_1",            1, 0, 3, '1');
    run_case("misaligned_37",      37, 3, 1, '0');   -- FALLBACK
    run_case("misaligned_64",      64, 4, 2, '0');   -- FALLBACK, aligned rows

    report "DSIDE_CYCLES TOTAL narrow " & integer'image(sum_n)
         & " wide " & integer'image(sum_w) severity note;
    report "TB_REGION_DRAIN checks=" & integer'image(checks)
         & " fail=" & integer'image(fail);
    running <= false;
    if fail = 0 then
      report "TB_REGION_DRAIN PASS" severity note;
    else
      report "TB_REGION_DRAIN FAIL" severity failure;
    end if;
    wait;
  end process;
end architecture;
