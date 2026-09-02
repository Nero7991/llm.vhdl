-- sim/tb_region_mem.vhd
-- TRACK CARDTOP, 2026-08-31.  The differential bench for rtl/region_mem.vhd:
-- the DUT against llama_top's flat region array (`memp`, rtl/llama_top.vhd
-- :1297-1341, copied VERBATIM below as the oracle), driven with identical
-- stimulus and compared every cycle.
--
-- WHAT IS COVERED: element write/read across all 14 regions; group
-- write/read across region pairs; the one-cycle read latency; same-cycle
-- read/write collisions in every combination (element/element,
-- element/group, group/group), whose expected result is PRE-WRITE data;
-- the group-write-wins same-word tie; out-of-range reads (zero in both);
-- the combinational host window; and a few thousand randomized cycles.
--
-- WHAT IS DELIBERATELY NOT COMPARED: a WRITE past a region's real size.
-- llama_top's padded array stores it; region_mem drops it by design (its
-- header documents why: a pad write is a defect llama_top cannot see, and
-- the pad's only legal content is zero).  The fuzz constrains writes to
-- in-range addresses and reads stay unrestricted.
--
-- VERDICT: prints "tb_region_mem: PASS -- <n> checks, 0 mismatches" on
-- success, and fails the run otherwise.  Self-contained; no vectors.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_region_mem is
end entity;

architecture sim of tb_region_mem is

  constant NREGION : positive := 14;
  constant REGMAX  : positive := 12288;
  constant LANES   : positive := 8;
  constant MANT_W  : positive := 16;
  constant GA_W    : positive := 11;
  constant LOG2L   : natural := 3;

  -- the REAL 9B region sizes (rtl/llama_map_pkg.vhd:298-318 at QWEN35_9B)
  constant SZ : integer_vector(0 to NREGION-1) := (
    0 => 4096, 1 => 4096, 2 => 8192, 3 => 4096, 4 => 32, 5 => 32,
    6 => 8192, 7 => 1024, 8 => 1024, 9 => 4096, 10 => 12288,
    11 => 12288, 12 => 12288, 13 => 4096);

  signal clk : std_logic := '0';
  signal stop : boolean := false;

  -- shared stimulus
  signal el_ren   : std_logic := '0';
  signal el_reg   : natural range 0 to NREGION-1 := 0;
  signal el_addr  : natural range 0 to REGMAX-1 := 0;
  signal el_we    : std_logic := '0';
  signal el_wreg  : natural range 0 to NREGION-1 := 0;
  signal el_waddr : natural range 0 to REGMAX-1 := 0;
  signal el_wdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal r_en     : std_logic := '0';
  signal r_rega   : unsigned(7 downto 0) := (others => '0');
  signal r_regb   : unsigned(7 downto 0) := (others => '0');
  signal r_addr   : unsigned(GA_W-1 downto 0) := (others => '0');
  signal w_we     : std_logic := '0';
  signal w_regd   : unsigned(7 downto 0) := (others => '0');
  signal w_addr   : unsigned(GA_W-1 downto 0) := (others => '0');
  signal w_be     : std_logic_vector(LANES-1 downto 0) := (others => '0');
  signal w_data   : std_logic_vector(LANES*MANT_W-1 downto 0) := (others => '0');
  signal hr_reg   : natural range 0 to NREGION-1 := 0;
  signal hr_addr  : natural range 0 to REGMAX-1 := 0;

  -- DUT outputs
  signal d_el_rdata : signed(MANT_W-1 downto 0);
  signal d_x_rdata  : std_logic_vector(LANES*MANT_W-1 downto 0);
  signal d_e_rdata  : std_logic_vector(LANES*MANT_W-1 downto 0);
  signal d_hr_data  : signed(MANT_W-1 downto 0);

  -- REFERENCE outputs (llama_top's flat array)
  signal o_el_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal o_x_rdata  : std_logic_vector(LANES*MANT_W-1 downto 0) := (others => '0');
  signal o_e_rdata  : std_logic_vector(LANES*MANT_W-1 downto 0) := (others => '0');
  signal o_hr_data  : signed(MANT_W-1 downto 0);

  -- the reference's flat array, llama_top's types
  type buf_t is array (natural range <>) of signed(MANT_W-1 downto 0);
  subtype mem_t is buf_t(0 to NREGION*REGMAX-1);
  signal mem : mem_t := (others => (others => '0'));

  signal n_checks : natural := 0;
  signal n_mismatch : natural := 0;

  -- LFSR for the fuzz
  signal lfsr : unsigned(31 downto 0) := x"1ACE_B00C";

begin

  clk <= not clk after 5 ns when not stop;

  dut : entity work.region_mem
    generic map(NREGION => NREGION, REGMAX => REGMAX, LANES => LANES,
                MANT_W => MANT_W, GA_W => GA_W, SZ => SZ)
    port map(
      clk => clk,
      el_ren => el_ren, el_reg => el_reg, el_addr => el_addr,
      el_rdata => d_el_rdata,
      el_we => el_we, el_wreg => el_wreg, el_waddr => el_waddr,
      el_wdata => el_wdata,
      r_en => r_en, r_rega => r_rega, r_regb => r_regb, r_addr => r_addr,
      x_rdata => d_x_rdata, e_rdata => d_e_rdata,
      w_we => w_we, w_regd => w_regd, w_addr => w_addr, w_be => w_be,
      w_data => w_data,
      hr_reg => hr_reg, hr_addr => hr_addr, hr_data => d_hr_data);

  -- ==================================================================
  -- THE ORACLE: rtl/llama_top.vhd's `memp` and hr_data, VERBATIM apart
  -- from the signal renames (d_/o_ suffixing).  :1297-1343 at b86dfe0.
  -- ==================================================================
  memp : process(clk) is
    variable a : natural;
  begin
    if rising_edge(clk) then
      -- write-first, so an in-place overtake is visible rather than hidden
      if el_we = '1' then
        mem(el_wreg*REGMAX + el_waddr) <= el_wdata;
      end if;
      if w_we = '1' then
        for i in 0 to LANES-1 loop
          if w_be(i) = '1' then
            a := to_integer(unsigned(w_regd(6 downto 0)))*REGMAX
                 + to_integer(w_addr)*LANES + i;
            if a < NREGION*REGMAX then
              mem(a) <= signed(w_data((i+1)*MANT_W-1 downto i*MANT_W));
            end if;
          end if;
        end loop;
      end if;

      if el_ren = '1' then
        o_el_rdata <= mem(el_reg*REGMAX + el_addr);
      end if;

      -- The D-vec group read: ONE address, TWO operand regions.
      if r_en = '1' then
        for i in 0 to LANES-1 loop
          a := to_integer(unsigned(r_rega(6 downto 0)))*REGMAX
               + to_integer(r_addr)*LANES + i;
          if a < NREGION*REGMAX then
            o_x_rdata((i+1)*MANT_W-1 downto i*MANT_W) <= std_logic_vector(mem(a));
          else
            o_x_rdata((i+1)*MANT_W-1 downto i*MANT_W) <= (others => '0');
          end if;
          a := to_integer(unsigned(r_regb(6 downto 0)))*REGMAX
               + to_integer(r_addr)*LANES + i;
          if a < NREGION*REGMAX then
            o_e_rdata((i+1)*MANT_W-1 downto i*MANT_W) <= std_logic_vector(mem(a));
          else
            o_e_rdata((i+1)*MANT_W-1 downto i*MANT_W) <= (others => '0');
          end if;
        end loop;
      end if;
    end if;
  end process;

  o_hr_data <= mem(hr_reg*REGMAX + hr_addr);

  -- ==================================================================
  -- THE COMPARISON.  Every cycle, after the registered outputs settle.
  -- ==================================================================
  chk : process is
    variable bad : boolean;
  begin
    wait until rising_edge(clk);
    if not stop then
      wait for 1 ns;
      bad := false;
      n_checks <= n_checks + 1;
      if d_el_rdata /= o_el_rdata then
        report "tb_region_mem MISMATCH el_rdata: dut="
             & integer'image(to_integer(d_el_rdata))
             & " ref=" & integer'image(to_integer(o_el_rdata))
             & " reg=" & integer'image(el_reg)
             & " addr=" & integer'image(el_addr)
             severity error;
        bad := true;
      end if;
      if d_x_rdata /= o_x_rdata then
        report "tb_region_mem MISMATCH x_rdata"
             severity error;
        bad := true;
      end if;
      if d_e_rdata /= o_e_rdata then
        report "tb_region_mem MISMATCH e_rdata"
             severity error;
        bad := true;
      end if;
      if d_hr_data /= o_hr_data then
        report "tb_region_mem MISMATCH hr_data: dut="
             & integer'image(to_integer(d_hr_data))
             & " ref=" & integer'image(to_integer(o_hr_data))
             & " reg=" & integer'image(hr_reg)
             & " addr=" & integer'image(hr_addr)
             severity error;
        bad := true;
      end if;
      if bad then n_mismatch <= n_mismatch + 1; end if;
    end if;
  end process;

  lfsr_p : process(clk) is
  begin
    if rising_edge(clk) then
      lfsr <= lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
    end if;
  end process;

  -- ==================================================================
  -- THE STIMULUS
  -- ==================================================================
  stim : process is
    variable seed : unsigned(31 downto 0) := x"0BAD_F00D";

    procedure idle is
    begin
      el_ren <= '0'; el_we <= '0'; r_en <= '0'; w_we <= '0';
      wait until rising_edge(clk);
    end procedure;

    procedure step is
    begin
      wait until rising_edge(clk);
    end procedure;

    -- one element write at (rg, ad), then idle
    procedure ewrite(rg, ad : natural; v : integer) is
    begin
      el_we <= '1'; el_wreg <= rg; el_waddr <= ad;
      el_wdata <= to_signed(v, MANT_W);
      step; el_we <= '0';
    end procedure;

    -- one element read at (rg, ad)
    procedure eread(rg, ad : natural) is
    begin
      el_ren <= '1'; el_reg <= rg; el_addr <= ad;
      step; el_ren <= '0';
    end procedure;

    -- one group write of LANES lanes at region rg, word wa
    procedure gwrite(rg, wa : natural; be : std_logic_vector(LANES-1 downto 0);
                     base : integer) is
      variable d : std_logic_vector(LANES*MANT_W-1 downto 0);
    begin
      for i in 0 to LANES-1 loop
        d((i+1)*MANT_W-1 downto i*MANT_W) :=
          std_logic_vector(to_signed(base + i*257, MANT_W));
      end loop;
      w_we <= '1'; w_regd <= to_unsigned(rg, 8); w_addr <= to_unsigned(wa, GA_W);
      w_be <= be; w_data <= d;
      step; w_we <= '0'; w_be <= (others => '0');
    end procedure;

    -- one group read, operand regions ra/rb, word wa
    procedure gread(ra, rb, wa : natural) is
    begin
      r_en <= '1'; r_rega <= to_unsigned(ra, 8); r_regb <= to_unsigned(rb, 8);
      r_addr <= to_unsigned(wa, GA_W);
      step; r_en <= '0';
    end procedure;

    procedure rnd(variable s : inout unsigned(31 downto 0)) is
    begin
      s := s(30 downto 0) & (s(31) xor s(21) xor s(1) xor s(0));
    end procedure;

  begin
    -- settle
    for i in 0 to 3 loop step; end loop;

    -- PHASE 1: element fill + readback across all regions
    for rg in 0 to NREGION-1 loop
      for k in 0 to 7 loop
        ewrite(rg, (k * SZ(rg) / 8 + k*k) mod SZ(rg),
               rg*1000 + k*37 - 5000);
      end loop;
    end loop;
    for rg in 0 to NREGION-1 loop
      for k in 0 to 7 loop
        eread(rg, (k * SZ(rg) / 8 + k*k) mod SZ(rg));
      end loop;
    end loop;

    -- PHASE 2: group fill + readback on region pairs
    for wa in 0 to 15 loop
      gwrite(0, wa, (others => '1'), 1000 + wa);
      gwrite(13, wa, (others => '1'), -2000 + wa);
      gwrite(2, wa, "10101010", 777 + wa);
    end loop;
    for wa in 0 to 15 loop
      gread(0, 13, wa);
      gread(2, 0, wa);
    end loop;

    -- PHASE 3: collisions.  Each block drives read and write in the SAME
    -- cycle; both designs must return PRE-WRITE data.
    -- 3a: element write + element read, same address
    ewrite(1, 100, 1111);
    el_we <= '1'; el_wreg <= 1; el_waddr <= 100; el_wdata <= to_signed(2222, MANT_W);
    el_ren <= '1'; el_reg <= 1; el_addr <= 100;
    step;
    el_we <= '0'; el_ren <= '0';
    -- 3b: element write + group read, same word (region 0 word 4 covers
    -- elements 32..39; write element 35, read the word)
    el_we <= '1'; el_wreg <= 0; el_waddr <= 35; el_wdata <= to_signed(9999, MANT_W);
    r_en <= '1'; r_rega <= to_unsigned(0, 8); r_regb <= to_unsigned(13, 8);
    r_addr <= to_unsigned(4, GA_W);
    step;
    el_we <= '0'; r_en <= '0';
    -- 3c: group write + element read, same word
    w_we <= '1'; w_regd <= to_unsigned(0, 8); w_addr <= to_unsigned(6, GA_W);
    w_be <= (others => '1'); w_data <= (others => '1');
    el_ren <= '1'; el_reg <= 0; el_addr <= 6*LANES+3;
    step;
    w_we <= '0'; w_be <= (others => '0'); el_ren <= '0'; w_data <= (others => '0');
    -- 3d: group write + group read, same word
    w_we <= '1'; w_regd <= to_unsigned(2, 8); w_addr <= to_unsigned(9, GA_W);
    w_be <= (others => '1');
    for i in 0 to LANES-1 loop
      w_data((i+1)*MANT_W-1 downto i*MANT_W) <= std_logic_vector(to_signed(4242+i, MANT_W));
    end loop;
    r_en <= '1'; r_rega <= to_unsigned(2, 8); r_regb <= to_unsigned(0, 8);
    r_addr <= to_unsigned(9, GA_W);
    step;
    w_we <= '0'; w_be <= (others => '0'); r_en <= '0'; w_data <= (others => '0');
    -- 3e: element write AND group write, same word: the GROUP write wins
    el_we <= '1'; el_wreg <= 3; el_waddr <= 64; el_wdata <= to_signed(111, MANT_W);
    w_we <= '1'; w_regd <= to_unsigned(3, 8); w_addr <= to_unsigned(8, GA_W);
    w_be <= (others => '1');
    for i in 0 to LANES-1 loop
      w_data((i+1)*MANT_W-1 downto i*MANT_W) <= std_logic_vector(to_signed(7777, MANT_W));
    end loop;
    step;
    el_we <= '0'; w_we <= '0'; w_be <= (others => '0'); w_data <= (others => '0');
    eread(3, 64);
    gread(3, 3, 8);

    -- PHASE 4: out-of-range reads return 0 in both.  NOTE the constraint:
    -- group words must stay inside the region's PADDED slot (REGMAX/LANES
    -- words).  Past that, llama_top's flat array leaks the NEXT region's
    -- data while region_mem returns 0 -- a layout artifact no adapter can
    -- reach (all adapters address within their region), documented in
    -- region_mem's header, and deliberately not compared here.
    for rg in 0 to NREGION-1 loop
      if SZ(rg) < REGMAX then
        eread(rg, SZ(rg));        -- first address past the region
      end if;
      eread(rg, REGMAX-1);        -- last padded address
    end loop;
    gread(4, 5, (SZ(4)+LANES-1)/LANES + 3);   -- small regions, into the pad
    gread(4, 5, REGMAX/LANES - 1);            -- last padded word

    -- PHASE 5: the host window over filled regions
    for rg in 0 to NREGION-1 loop
      for k in 0 to 3 loop
        hr_reg <= rg; hr_addr <= (k * SZ(rg) / 4 + 7) mod SZ(rg);
        step;
      end loop;
    end loop;

    -- PHASE 6: the fuzz.  Writes stay in range; reads go anywhere.
    for k in 0 to 4999 loop
      rnd(seed); rnd(seed);
      -- element write, ~25%
      if seed(3 downto 0) < 4 then
        el_we <= '1';
        el_wreg <= to_integer(seed(7 downto 4)) mod NREGION;
        el_waddr <= to_integer(seed(20 downto 8)) mod SZ(to_integer(seed(7 downto 4)) mod NREGION);
        el_wdata <= signed(seed(15 downto 0));
      else
        el_we <= '0';
      end if;
      -- element read, ~50%
      if seed(1) = '1' then
        el_ren <= '1';
        el_reg <= to_integer(seed(11 downto 8)) mod NREGION;
        el_addr <= to_integer(seed(27 downto 14)) mod REGMAX;
      else
        el_ren <= '0';
      end if;
      -- group write, ~15%
      if seed(6 downto 4) = 5 then
        w_we <= '1';
        w_regd <= to_unsigned(to_integer(seed(11 downto 8)) mod NREGION, 8);
        w_addr <= to_unsigned(
          to_integer(seed(22 downto 12)) mod ((SZ(to_integer(seed(11 downto 8)) mod NREGION)+LANES-1)/LANES), GA_W);
        w_be <= std_logic_vector(seed(LANES+15 downto 16));
        for i in 0 to LANES-1 loop
          rnd(seed);
          w_data((i+1)*MANT_W-1 downto i*MANT_W) <= std_logic_vector(seed(15 downto 0));
        end loop;
      else
        w_we <= '0'; w_be <= (others => '0');
      end if;
      -- group read, ~40%.  The word address is kept INSIDE both operand
      -- regions: past a region's words the two designs diverge BY DESIGN
      -- (flat-array cross-region leak vs region_mem's zero), documented in
      -- phase 4 above.
      if seed(5 downto 3) < 3 then
        r_en <= '1';
        r_rega <= to_unsigned(to_integer(seed(15 downto 12)) mod NREGION, 8);
        r_regb <= to_unsigned(to_integer(seed(19 downto 16)) mod NREGION, 8);
        r_addr <= to_unsigned(
          to_integer(seed(30 downto 20)) mod
            minimum((SZ(to_integer(seed(15 downto 12)) mod NREGION)+LANES-1)/LANES,
                    (SZ(to_integer(seed(19 downto 16)) mod NREGION)+LANES-1)/LANES),
          GA_W);
      else
        r_en <= '0';
      end if;
      -- host window, ~20%
      if seed(9 downto 8) = 2 then
        hr_reg <= to_integer(seed(15 downto 12)) mod NREGION;
        hr_addr <= to_integer(seed(29 downto 16)) mod REGMAX;
      end if;
      step;
    end loop;

    -- drain and verdict
    for i in 0 to 3 loop step; end loop;
    wait for 1 ns;
    if n_mismatch = 0 then
      report "tb_region_mem: PASS -- " & integer'image(n_checks)
           & " cycles compared, 0 mismatches"
        severity note;
    else
      report "tb_region_mem: FAIL -- " & integer'image(n_mismatch)
           & " mismatching cycles of " & integer'image(n_checks)
        severity failure;
    end if;
    stop <= true;
    wait;
  end process;

end architecture;
