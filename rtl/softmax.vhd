-- rtl/softmax.vhd
-- Softmax with integer exp (exp_q from fixed_pkg) and Q12 probability output.
-- Mirrors softmax_fx in ref/run_fx.c:
--   1. Convert BFP scores to Qq integers.
--   2. Find max over first n scores.
--   3. z_q[i] = score_q[i] - max_q  (always <= 0; required by exp_q).
--   4. e_i = exp_q(z_q[i], Q).
--   5. sum += e_i (int64).
--   6. prob_q[i] = (e_i << Q) / sum  (integer divide, Q12 probability).
--
-- Block-fp convention: score[j] = mant[j] * 2^(-score_exp).
-- Input: score_mant (16-bit mantissas), score_exp.
-- Output: prob_q (32-bit Q12 probabilities for the first n lanes).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_pkg.all;

entity softmax is
  generic(NMAX : positive; Q : integer := 12);
  port(
    clk        : in  std_logic;
    rst        : in  std_logic;
    start      : in  std_logic;
    n          : in  integer;
    score_mant : in  std_logic_vector(NMAX*16-1 downto 0);
    score_exp  : in  integer;
    done       : out std_logic;
    prob_q     : out std_logic_vector(NMAX*32-1 downto 0);
    -- Additive outputs (do not affect prob_q): the raw integer exp weights
    -- e_i and their sum, so a consumer (attention.vhd) can form a
    -- full-precision weighted sum  Sum(e_i*v_i)/sum  instead of the coarser
    -- per-element Q-truncated prob_q.  Unconnected by tb_softmax.
    e_out      : out std_logic_vector(NMAX*32-1 downto 0);
    sum_out    : out std_logic_vector(63 downto 0)
  );
end entity softmax;

architecture rtl of softmax is
begin
  process(clk)
    type s64_arr is array(natural range <>) of signed(63 downto 0);
    variable sq_arr  : s64_arr(0 to NMAX-1);
    variable e_arr   : s64_arr(0 to NMAX-1);

    variable sc_raw  : signed(15 downto 0);
    variable sc_ext  : signed(63 downto 0);
    variable max_q   : signed(63 downto 0);
    variable z_q     : signed(63 downto 0);
    variable e_i     : signed(31 downto 0);
    variable sum     : signed(63 downto 0);
    variable num     : signed(63 downto 0);
    variable p_i     : signed(63 downto 0);
    variable bias    : signed(63 downto 0);
    variable sh      : integer;
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        prob_q <= (others => '0');
      elsif start = '1' then

        -- Step 1: Convert BFP mantissas to Qq integers.
        -- score_q[i] = round(mant[i] * 2^(Q - score_exp))
        sh := Q - score_exp;
        for i in 0 to NMAX-1 loop
          sc_raw := signed(score_mant((i+1)*16-1 downto i*16));
          sc_ext := resize(sc_raw, 64);
          if sh >= 0 then
            sq_arr(i) := shift_left(sc_ext, sh);
          else
            -- right shift with round-half-up: add 2^(|sh|-1) then shift
            bias      := shift_left(to_signed(1, 64), (-sh) - 1);
            sq_arr(i) := shift_right(sc_ext + bias, -sh);
          end if;
        end loop;

        -- Step 2: Find max over first n scores.
        max_q := sq_arr(0);
        for i in 1 to NMAX-1 loop
          if i < n then
            if sq_arr(i) > max_q then max_q := sq_arr(i); end if;
          end if;
        end loop;

        -- Step 3+4+5: exp_q and accumulate sum.
        sum := to_signed(0, 64);
        for i in 0 to NMAX-1 loop
          if i < n then
            z_q      := sq_arr(i) - max_q;
            e_i      := exp_q(z_q, Q);
            e_arr(i) := resize(e_i, 64);
            sum      := sum + e_arr(i);
          else
            e_arr(i) := (others => '0');
          end if;
        end loop;
        if sum <= 0 then sum := to_signed(1, 64); end if;

        -- Step 6: Normalize.
        for i in 0 to NMAX-1 loop
          if i < n then
            num := shift_left(e_arr(i), Q);
            p_i := num / sum;
          else
            p_i := (others => '0');
          end if;
          prob_q((i+1)*32-1 downto i*32) <=
            std_logic_vector(resize(p_i, 32));
          -- Expose raw exp weights e_i (Q-scale) for the full-precision path.
          e_out((i+1)*32-1 downto i*32) <=
            std_logic_vector(resize(e_arr(i), 32));
        end loop;
        sum_out <= std_logic_vector(sum);

        done <= '1';
      end if;
    end if;
  end process;
end architecture rtl;
