-- Jungle Cat loader: status crossing from aclk to TCK by toggle handshake. aclk publishes a
-- snapshot and flips `pub` only after TCK has acknowledged the previous one, so the
-- snapshot is stable whenever TCK samples it. TCK runs only while shifting, so TCK-side
-- progress happens only then; that is enough because status is read only while shifting.
--
-- Task 9b: the width is a generic, default 384 (the status word grew from 256 to 384 bits
-- for the DNA die identity); the handshake is unchanged.
library ieee;
use ieee.std_logic_1164.all;

entity jc_status_sync is
  generic(W : positive := 384);
  port(
    aclk   : in  std_logic;
    live   : in  std_logic_vector(W-1 downto 0);
    tck    : in  std_logic;
    st_tck : out std_logic_vector(W-1 downto 0)
  );
end entity;

architecture rtl of jc_status_sync is
  signal snap   : std_logic_vector(W-1 downto 0) := (others => '0');
  signal pub    : std_logic := '0';
  signal ack_s1, ack_s2 : std_logic := '0';
  signal tgl_s1, tgl_s2 : std_logic := '0';
  signal ack    : std_logic := '0';
  signal st_r   : std_logic_vector(W-1 downto 0) := (others => '0');
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of ack_s1, ack_s2, tgl_s1, tgl_s2 : signal is "TRUE";
begin
  st_tck <= st_r;

  a_side : process(aclk)
  begin
    if rising_edge(aclk) then
      ack_s1 <= ack;
      ack_s2 <= ack_s1;
      if ack_s2 = pub then
        snap <= live;
        pub  <= not pub;
      end if;
    end if;
  end process;

  t_side : process(tck)
  begin
    if rising_edge(tck) then
      tgl_s1 <= pub;
      tgl_s2 <= tgl_s1;
      if tgl_s2 /= ack then
        st_r <= snap;
        ack  <= tgl_s2;
      end if;
    end if;
  end process;
end architecture;
