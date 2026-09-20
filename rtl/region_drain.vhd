-- rtl/region_drain.vhd -- 2026-09-20.  TRACK DSIDE.
--
-- THE A-SIDE y DRAIN, EXTRACTED, WITH THE WIDE PATH BESIDE IT.
--
-- WHAT THIS IS.  `rtl/llama_top.vhd`'s unit-A adapter ends every job in
-- S_DRAIN (llama_top.vhd:4394-4413), which copies `j_rows` mantissas out of
-- the y tile buffer `ybw` into the region file ONE ELEMENT PER CYCLE over the
-- shared element write port (`uw_en` / `uw_addr` / `uw_data`).  MEASURED on
-- the card, 2026-09-20: that state is 1,426,944 cycles of a 30,115,280-cycle
-- lane-striped token (4.74%) and the same 1,426,944 of a 66.7 M-cycle flat
-- token (2.14%).  See docs/2026-09-20_d-side-vector-traffic.md.
--
-- WHY IT IS ONE PER CYCLE, AND WHY THAT IS NOT FORCED.  The element port is
-- 16 bits wide because it is the port every unit shares.  But the SOURCE is
-- already wide -- `ybw` is an array of `A_ROWS_IF*MANT_W`-bit words, 48
-- mantissas each (llama_top.vhd:4124-4126) -- and the SINK has a wide port
-- too: the region file's LANES-way group write port (`w_we` / `w_addr` /
-- `w_be` / `w_data`, llama_top.vhd:1327-1330, served by `memp` at
-- llama_top.vhd:1688-1699), which today has exactly one client,
-- `seq_vec_res`.  Nothing about the drain needs the narrow port; it uses it
-- because the adapter was written before the group port had a second client.
--
-- WIDE = false is the SHIPPING BEHAVIOUR, cycle for cycle and write for
-- write.  The body of the `gnarrow` arm below is llama_top's S_DRAIN with
-- `r` / `rword` / `rlane` moved from process VARIABLES to signals, which is
-- behaviour-preserving because llama_top reads `ybw(rword)` before it updates
-- `rword` in the same cycle -- a signal read gives exactly that pre-update
-- value.  The `r = 0` cursor reset (path-independent, for the reason
-- llama_top's own comment records) and the absence of a clamp on `rword` are
-- kept.  WIDE = true emits LANES lanes per cycle over the group port and
-- takes ceil(n / LANES) cycles.
--
-- THE ALIGNMENT FALLBACK IS RUNTIME, NOT AN ELABORATION PIN.  The group port
-- addresses the region file as `w_addr * LANES + i`, so a destination offset
-- that is not a multiple of LANES has no group address.  Every A job in the
-- shipping 9B program has `dst_off` in {0, 2048, 4096} and `n_rows` a
-- multiple of 8 (MEASURED from tools/gen_layer_program.build_plan over all
-- 311 A jobs of a token), so the wide path is exact for all of them -- but a
-- future schedule need not be, and an elaboration pin cannot see a run-time
-- descriptor field.  So WIDE = true falls back to the narrow path for such a
-- job: slower and correct rather than fast and wrong.  `o_wide_used`
-- publishes which path ran, so a bench asserts on it instead of inferring it
-- from a cycle count.
--
-- THE TAIL uses `w_be`, which the region file already honours per lane
-- (llama_top.vhd:1691).  A tail group therefore writes only the lanes the
-- vector has and never a neighbouring element.
--
-- NO HARDWARE.  Simulation and synthesis only.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity region_drain is
  generic(
    -- Lanes per y buffer word.  llama_top's A_ROWS_IF.
    ROWS_IF : positive := 48;
    MANT_W  : positive := 16;
    -- Words in the y buffer.  llama_top's A_YWORDS.
    YWORDS  : positive := 363;
    -- Region-file group width.  llama_top's LANES.
    LANES   : positive := 8;
    -- Width of the group address port.  llama_top's GA_W.
    GA_W    : positive := 12;
    -- Bound on the element address port.  llama_top's REGMAX.
    REGMAX  : positive := 17408;
    -- false is llama_top's S_DRAIN exactly.
    WIDE    : boolean  := false
  );
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;
    -- One cycle, on the edge that would enter S_DRAIN.
    start : in  std_logic;
    -- The latched descriptor fields S_DRAIN reads.
    n_rows  : in  natural range 0 to REGMAX;
    dst_off : in  natural range 0 to REGMAX;
    dst_reg : in  natural range 0 to 127;
    -- The y buffer read port.  COMBINATIONAL, which is what llama_top's
    -- `ybw(rword)` is in the same cycle it drives `uw_data`.
    yb_raddr : out natural range 0 to YWORDS-1;
    yb_rdata : in  std_logic_vector(ROWS_IF*MANT_W-1 downto 0);
    -- The element write port (the shipping path).
    uw_en   : out std_logic := '0';
    uw_reg  : out natural range 0 to 127 := 0;
    uw_addr : out natural range 0 to REGMAX-1 := 0;
    uw_data : out signed(MANT_W-1 downto 0) := (others => '0');
    -- The LANES-wide group write port (the wide path).
    w_we    : out std_logic := '0';
    w_reg   : out natural range 0 to 127 := 0;
    w_addr  : out unsigned(GA_W-1 downto 0) := (others => '0');
    w_be    : out std_logic_vector(LANES-1 downto 0) := (others => '0');
    w_data  : out std_logic_vector(LANES*MANT_W-1 downto 0) := (others => '0');
    -- One cycle, on the edge S_DRAIN would leave for S_DONE.
    done    : out std_logic := '0';
    -- OBSERVATION ONLY: '1' while the running job took the group path.
    o_wide_used : out std_logic := '0'
  );
end entity;

architecture rtl of region_drain is
  -- Two-sided elaboration pins (an out-of-range natural, because Vivado
  -- ignores `assert ... severity failure` in synthesis).
  constant bad_lanes_div_rows_if : natural := 0 - (ROWS_IF mod LANES);
  constant bad_lanes_le_rows_if  : natural := ROWS_IF - LANES;

  signal rword : natural range 0 to YWORDS-1 := 0;
  signal rlane : natural range 0 to ROWS_IF-1 := 0;
begin
  yb_raddr <= rword;

  -- ====================================================================
  -- THE SHIPPING PATH.  llama_top.vhd:4394-4413.
  -- ====================================================================
  gnarrow : if not WIDE generate
    p : process(clk) is
      variable st  : natural range 0 to 1 := 0;
      variable r   : natural := 0;
      variable n, off, reg : natural := 0;
    begin
      if rising_edge(clk) then
        uw_en <= '0';
        done  <= '0';
        if rst = '1' then
          st := 0; r := 0; rword <= 0; rlane <= 0;
          o_wide_used <= '0';
        elsif st = 0 then
          if start = '1' then
            n := n_rows; off := dst_off; reg := dst_reg;
            r := 0; rword <= 0; rlane <= 0;
            o_wide_used <= '0';
            if n_rows = 0 then done <= '1'; else st := 1; end if;
          end if;
        else
          -- PATH-INDEPENDENT RESET.  See llama_top's own comment.
          if r = 0 then rword <= 0; rlane <= 0; end if;
          uw_en   <= '1';
          uw_reg  <= reg;
          uw_addr <= off + r;
          uw_data <= signed(yb_rdata((rlane+1)*MANT_W-1 downto rlane*MANT_W));
          -- NO CLAMP on `rword`: it is a constrained natural range, so an
          -- overrun is a loud range error rather than a saturated read.
          if rlane = ROWS_IF-1 then
            rlane <= 0;
            if rword /= YWORDS-1 then rword <= rword + 1; end if;
          else
            rlane <= rlane + 1;
          end if;
          if r = n-1 then
            done <= '1';
            st   := 0;
          else
            r := r + 1;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ====================================================================
  -- THE GROUP PATH.  LANES lanes per cycle out of ONE `ybw` word, with the
  -- narrow body kept beside it for a misaligned offset.
  -- ====================================================================
  gwide : if WIDE generate
    p : process(clk) is
      variable st  : natural range 0 to 2 := 0;
      variable r   : natural := 0;
      variable n, off, reg : natural := 0;
    begin
      if rising_edge(clk) then
        uw_en <= '0';
        w_we  <= '0';
        done  <= '0';
        if rst = '1' then
          st := 0; r := 0; rword <= 0; rlane <= 0;
          o_wide_used <= '0';
        else
          case st is
            when 0 =>
              if start = '1' then
                n := n_rows; off := dst_off; reg := dst_reg;
                r := 0; rword <= 0; rlane <= 0;
                if n_rows = 0 then
                  done <= '1';
                  o_wide_used <= '0';
                elsif off mod LANES = 0 then
                  o_wide_used <= '1';
                  st := 1;
                else
                  -- THE FALLBACK.  No group address exists for this offset.
                  o_wide_used <= '0';
                  st := 2;
                end if;
              end if;

            when 1 =>
              -- `rlane` is the lane index of element `r` inside word
              -- `rword`; LANES divides ROWS_IF, so all LANES lanes of a
              -- group live in the SAME word and no group straddles two.
              w_we   <= '1';
              w_reg  <= reg;
              w_addr <= to_unsigned((off + r) / LANES, GA_W);
              for i in 0 to LANES-1 loop
                if r + i < n then
                  w_be(i) <= '1';
                  w_data((i+1)*MANT_W-1 downto i*MANT_W)
                    <= yb_rdata((rlane+i+1)*MANT_W-1 downto (rlane+i)*MANT_W);
                else
                  w_be(i) <= '0';
                  w_data((i+1)*MANT_W-1 downto i*MANT_W) <= (others => '0');
                end if;
              end loop;
              if rlane = ROWS_IF-LANES then
                rlane <= 0;
                if rword /= YWORDS-1 then rword <= rword + 1; end if;
              else
                rlane <= rlane + LANES;
              end if;
              if r + LANES >= n then
                done <= '1';
                st   := 0;
              else
                r := r + LANES;
              end if;

            when others =>
              -- The narrow body, for a misaligned offset.
              if r = 0 then rword <= 0; rlane <= 0; end if;
              uw_en   <= '1';
              uw_reg  <= reg;
              uw_addr <= off + r;
              uw_data <= signed(yb_rdata((rlane+1)*MANT_W-1 downto rlane*MANT_W));
              if rlane = ROWS_IF-1 then
                rlane <= 0;
                if rword /= YWORDS-1 then rword <= rword + 1; end if;
              else
                rlane <= rlane + 1;
              end if;
              if r = n-1 then
                done <= '1';
                st   := 0;
              else
                r := r + 1;
              end if;
          end case;
        end if;
      end if;
    end process;
  end generate;
end architecture;
