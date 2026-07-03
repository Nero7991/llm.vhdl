library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;
entity mac_array is
  generic(N:positive; P:positive; WW:positive:=8; XW:positive:=16; AW:positive:=32);
  port(clk,rst,start:in std_logic;
       x_vec:in std_logic_vector(N*XW-1 downto 0);
       w_row:in std_logic_vector(N*WW-1 downto 0);
       done:out std_logic; acc:out std_logic_vector(AW-1 downto 0));
end;
architecture rtl of mac_array is
  constant STEPS : natural := (N + P - 1)/P;
  signal accr : signed(AW-1 downto 0);
  signal step : natural range 0 to STEPS;
  signal busy : std_logic := '0';
begin
  process(clk) variable s : signed(AW-1 downto 0); variable idx : natural;
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst='1' then busy<='0'; step<=0; accr<=(others=>'0');
      elsif start='1' and busy='0' then busy<='1'; step<=0; accr<=(others=>'0');
      elsif busy='1' then
        s := accr;
        for k in 0 to P-1 loop
          idx := step*P + k;
          if idx < N then
            s := s + resize(
                   signed(w_row((idx+1)*WW-1 downto idx*WW)) *
                   signed(x_vec((idx+1)*XW-1 downto idx*XW)), AW);
          end if;
        end loop;
        accr <= s;
        if step = STEPS-1 then
          busy <= '0'; done <= '1';
          acc  <= std_logic_vector(s);   -- final sum, published in the same
                                         -- delta as done (a combinational
                                         -- acc<=accr lags one delta and drops
                                         -- the last accumulated chunk)
        end if;
        step <= step + 1;
      end if;
    end if;
  end process;
end;
