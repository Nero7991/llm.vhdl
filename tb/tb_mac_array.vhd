library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
entity tb_mac_array is end;
architecture sim of tb_mac_array is
  constant N : positive := 64; constant P : positive := 16;
  signal clk : std_logic := '0'; signal rst : std_logic := '1';
  signal start, done : std_logic := '0';
  signal x_vec : std_logic_vector(N*16-1 downto 0);
  signal w_row : std_logic_vector(N*8-1 downto 0);
  signal acc   : std_logic_vector(31 downto 0);
begin
  clk <= not clk after 5 ns;
  uut: entity work.mac_array generic map(N=>N,P=>P)
       port map(clk=>clk,rst=>rst,start=>start,x_vec=>x_vec,w_row=>w_row,done=>done,acc=>acc);
  process
    file fh : text open read_mode is "../mem/golden/matvec_layer0_wq.txt";
    variable L : line; variable nn, rows, v, expv : integer;
    variable xv : integer_vector(0 to N-1);
  begin
    readline(fh,L); read(L,nn); read(L,rows);
    assert nn=N report "N mismatch" severity failure;
    readline(fh,L);
    for j in 0 to N-1 loop read(L,v); xv(j):=v;
      x_vec((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(v,16)); end loop;
    rst <= '0'; wait for 20 ns;
    for i in 0 to rows-1 loop
      readline(fh,L);
      for j in 0 to N-1 loop read(L,v);
        w_row((j+1)*8-1 downto j*8) <= std_logic_vector(to_signed(v,8)); end loop;
      read(L,expv);
      wait until rising_edge(clk); start<='1'; wait until rising_edge(clk); start<='0';
      wait until done='1';
      assert to_integer(signed(acc))=expv
        report "row "&integer'image(i)&" got "&integer'image(to_integer(signed(acc)))
              &" exp "&integer'image(expv) severity failure;
    end loop;
    report "PASS:mac_array" severity note; std.env.finish;
  end process;
end;
