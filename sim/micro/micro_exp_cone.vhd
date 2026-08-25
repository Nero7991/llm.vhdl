-- The exp cone from softmax.vhd, in its as-built STAGED form and in a properly
-- PIPELINED form, so the cost of the conversion can be measured rather than
-- guessed.
--
-- WHY THIS EXISTS.  softmax.vhd:63 calls S_EXP_A/B/C "PIPELINED", but the FSM
-- returns to S_EXP_A only after S_EXP_C, so exactly one element is ever in
-- flight: throughput is 1 exp per 3 cycles, and the spec records it that way
-- (C section 1.5, "the cone is a 3-state FSM, ~1 exp per 3 cycles, not a
-- pipeline").  At subsystem C's 27B geometry that is the binding constraint:
-- a position needs 6 exps (one per query head in the GQA group), so 18 cycles,
-- against 16 cycles of MAC work at MACS=192.  It puts a hard floor of ~3.93
-- ms/token on C REGARDLESS of lane count -- MACS=384 buys literally nothing
-- until it is fixed.
--
-- The three stages already register their data between states (they are process
-- variables written in one state and read in another), so the only thing
-- preventing 1-per-cycle is that there is a single copy of the inter-stage
-- data.  A true pipeline needs one copy per stage in flight.  That is the cost
-- this file measures.
--
-- Arithmetic is copied from softmax.vhd verbatim, including the 64-bit
-- intermediate widths, so that the two modes differ ONLY in control.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fixed_luts_pkg.all;

entity micro_exp_cone is
  generic(
    Q         : integer := 12;
    PIPELINED : boolean := false
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    iv     : in  std_logic;                      -- input valid
    z_q    : in  std_logic_vector(63 downto 0);  -- score_q - max_q
    ov     : out std_logic;                      -- output valid
    e_out  : out std_logic_vector(31 downto 0)
  );
end entity micro_exp_cone;

architecture rtl of micro_exp_cone is
  -- stage A -> B payload
  type a2b_t is record
    lo   : signed(63 downto 0);
    hd   : signed(63 downto 0);
    frac : signed(63 downto 0);
    uf   : std_logic;
    v    : std_logic;
  end record;
  -- stage B -> C payload
  type b2c_t is record
    lo   : signed(63 downto 0);
    prod : signed(127 downto 0);
    uf   : std_logic;
    v    : std_logic;
  end record;
  constant A2B0 : a2b_t := ((others=>'0'),(others=>'0'),(others=>'0'),'0','0');
  constant B2C0 : b2c_t := ((others=>'0'),(others=>'0'),'0','0');

  signal ab : a2b_t := A2B0;
  signal bc : b2c_t := B2C0;

  type st_t is (S_A, S_B, S_C);
  signal st : st_t := S_A;

  -- stage A, verbatim from softmax.vhd S_EXP_A (minus conv_q, which is score
  -- conversion rather than the cone).
  procedure stage_a(z : in signed(63 downto 0); o : out a2b_t) is
    variable ez, eoff, eidx : signed(63 downto 0);
    variable ek : integer;
  begin
    ez := z;
    o.uf := '0';
    if ez < shift_left(to_signed(-16, 64), Q) then o.uf := '1'; end if;
    if ez > 0 then ez := to_signed(0, 64); end if;
    eoff := ez + shift_left(to_signed(16, 64), Q);
    eidx := shift_left(eoff, 4);
    ek   := to_integer(shift_right(eidx, Q));
    if ek > 255 then ek := 255; end if;
    if ek <   0 then ek :=   0; end if;
    o.frac := eidx - shift_left(to_signed(ek, 64), Q);
    o.lo   := to_signed(EXP_ROM(ek), 64);
    o.hd   := to_signed(EXP_ROM(ek + 1), 64) - to_signed(EXP_ROM(ek), 64);
    o.v    := '1';
  end procedure;

  -- stage C, verbatim from softmax.vhd S_EXP_C (minus the e_arr store and the
  -- sum accumulation, which belong to softmax's own bookkeeping).
  function stage_c(s : b2c_t) return signed is
    variable etmp, einterp, er, ebias : signed(63 downto 0);
    variable esh : integer;
    variable e_i : signed(31 downto 0);
  begin
    etmp    := resize(shift_right(s.prod, Q), 64);
    einterp := s.lo + etmp;
    if Q <= 30 then
      esh := 30 - Q;
      if esh > 0 then
        ebias := shift_left(to_signed(1, 64), esh - 1);
        er    := shift_right(einterp + ebias, esh);
      else er := einterp; end if;
    else er := shift_left(einterp, Q - 30);
    end if;
    if    s.uf = '1'                       then e_i := to_signed(0, 32);
    elsif er < 0                           then e_i := to_signed(0, 32);
    elsif er > to_signed(2147483647, 64)   then e_i := to_signed(2147483647, 32);
    else                                        e_i := resize(er, 32);
    end if;
    return e_i;
  end function;
begin

  gen_pipe : if PIPELINED generate
    -- One element enters every cycle.  Each stage keeps its own copy of the
    -- inter-stage data, which is the entire difference from the staged form.
    process(clk)
      variable a : a2b_t;
    begin
      if rising_edge(clk) then
        if rst = '1' then
          ab <= A2B0; bc <= B2C0; ov <= '0';
        else
          a := A2B0;
          if iv = '1' then stage_a(signed(z_q), a); end if;
          ab <= a;
          bc.lo   <= ab.lo;
          bc.uf   <= ab.uf;
          bc.v    <= ab.v;
          bc.prod <= ab.hd * ab.frac;
          ov      <= bc.v;
          e_out   <= std_logic_vector(stage_c(bc));
        end if;
      end if;
    end process;
  end generate;

  gen_staged : if not PIPELINED generate
    -- As built: the FSM walks A -> B -> C and only then accepts the next
    -- element, so one element is in flight and throughput is 1 per 3 cycles.
    process(clk)
      variable a : a2b_t;
    begin
      if rising_edge(clk) then
        ov <= '0';
        if rst = '1' then
          st <= S_A; ab <= A2B0; bc <= B2C0;
        else
          case st is
            when S_A =>
              if iv = '1' then
                stage_a(signed(z_q), a);
                ab <= a;
                st <= S_B;
              end if;
            when S_B =>
              bc.lo   <= ab.lo;
              bc.uf   <= ab.uf;
              bc.v    <= ab.v;
              bc.prod <= ab.hd * ab.frac;
              st      <= S_C;
            when S_C =>
              e_out <= std_logic_vector(stage_c(bc));
              ov    <= '1';
              st    <= S_A;
          end case;
        end if;
      end if;
    end process;
  end generate;

end architecture rtl;
