-- rtl/act_mem_dp.vhd -- subsystem A's activation memory with a write clock and a read
-- clock (a450 spec 2.2).  Same organisation and the same 1-cycle registered read as
-- rtl/act_mem_striped.vhd: word = BLK elements of W bits, element a lives in word a/BLK at
-- lane a mod BLK.  Written on the core clock by the existing load path, read on aclk_a by
-- rtl/mv_dist.vhd.  The sequencer loads x before it starts a job and does not write it
-- during one, so no address is ever read and written in the same cycle pair.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity act_mem_dp is
  generic(
    ELEMS : positive := 17408;
    BLK   : positive := 32;
    W     : positive := 16
  );
  port(
    wclk   : in  std_logic;
    we     : in  std_logic;
    waddr  : in  std_logic_vector(clog2(ELEMS)-1 downto 0);
    wdata  : in  std_logic_vector(W-1 downto 0);
    rclk   : in  std_logic;
    rbaddr : in  std_logic_vector(clog2((ELEMS+BLK-1)/BLK)-1 downto 0);
    rdata  : out std_logic_vector(BLK*W-1 downto 0)
  );
end entity;

architecture rtl of act_mem_dp is
  constant WORDS : positive := (ELEMS + BLK - 1) / BLK;
  type mem_t is array(0 to WORDS-1) of std_logic_vector(BLK*W-1 downto 0);
  signal mem : mem_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";
  signal rw : std_logic_vector(BLK*W-1 downto 0) := (others => '0');
begin
  wr : process(wclk)
    variable a, word, lane : integer;
  begin
    if rising_edge(wclk) then
      if we = '1' then
        a    := to_integer(unsigned(waddr));
        word := a / BLK;
        lane := a mod BLK;
        for j in 0 to BLK-1 loop
          if lane = j then
            mem(word)((j+1)*W-1 downto j*W) <= wdata;
          end if;
        end loop;
      end if;
    end if;
  end process;

  rd : process(rclk)
  begin
    if rising_edge(rclk) then
      rw <= mem(to_integer(unsigned(rbaddr)));
    end if;
  end process;
  rdata <= rw;
end architecture;
