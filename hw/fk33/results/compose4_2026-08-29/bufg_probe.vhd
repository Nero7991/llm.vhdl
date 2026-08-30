library ieee; use ieee.std_logic_1164.all;
entity c4_bufg_probe is
  port( clk : in std_logic; rst : in std_logic;
        d : in std_logic_vector(31 downto 0);
        q : out std_logic_vector(31 downto 0) );
end entity;
architecture rtl of c4_bufg_probe is
  signal r : std_logic_vector(31 downto 0) := (others=>'0');
begin
  process(clk) begin
    if rising_edge(clk) then
      if rst='1' then r <= (others=>'0'); else r <= d; end if;
    end if;
  end process;
  q <= r;
end architecture;
