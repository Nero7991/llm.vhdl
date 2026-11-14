-- sim/axi_rd_mem_model.vhd -- an AXI read slave with its own word memory, random RVALID
-- gaps, random ARREADY, and optional long stalls.  Bench-side only (no UNISIM).
--
-- The bench fills the memory through wr_en/wr_addr/wr_data (one AXI_DW word per cycle,
-- word address = byte address / (AXI_DW/8)).  Bursts are queued in arrival order (up to
-- QD outstanding) and answered in order; RVALID, once raised, holds until RREADY, as AXI
-- requires.  GAPPCT is the percentage of cycles a beat is withheld; LONGPM is the
-- per-mille chance per cycle of starting a LONGLEN-cycle stall, which is what drains a
-- tile's credits in the composed bench.  An address outside the memory is a failure.
-- `hold` (optional, default '0'): while '1' no R beat is sent; ARs are still accepted and
-- queued.  It models an HBM that delivers bursts owed from before a master's reset late,
-- after the master has started again (a450 Task 7b fix round 1).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_rd_mem_model is
  generic(
    AXI_DW  : positive := 256;
    ADDR_W  : positive := 40;
    NWORDS  : positive := 1024;
    SEED    : positive := 1;
    GAPPCT  : natural  := 30;
    LONGPM  : natural  := 0;
    LONGLEN : natural  := 200;
    QD      : positive := 32
  );
  port(
    clk, rst : in  std_logic;
    arvalid  : in  std_logic;
    arready  : out std_logic;
    araddr   : in  std_logic_vector(ADDR_W-1 downto 0);
    arlen    : in  std_logic_vector(7 downto 0);
    rvalid   : out std_logic;
    rready   : in  std_logic;
    rdata    : out std_logic_vector(AXI_DW-1 downto 0);
    rlast    : out std_logic;
    wr_en    : in  std_logic;
    wr_addr  : in  natural;
    wr_data  : in  std_logic_vector(AXI_DW-1 downto 0);
    hold     : in  std_logic := '0'
  );
end entity;

architecture sim of axi_rd_mem_model is
  type mem_t is array(0 to NWORDS-1) of std_logic_vector(AXI_DW-1 downto 0);
  signal mem : mem_t := (others => (others => '0'));
  signal ar_r, rv_r, rl_r : std_logic := '0';
  signal rd_r : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
begin
  arready <= ar_r;
  rvalid  <= rv_r;
  rlast   <= rl_r;
  rdata   <= rd_r;

  p : process(clk)
    type q_t is array(0 to QD-1) of natural;
    variable qa, ql : q_t;
    variable qh, qt, qn : natural := 0;
    variable cur, left : natural := 0;
    variable busy : boolean := false;
    variable lf : unsigned(31 downto 0) := to_unsigned((SEED * 7919 + 12345) mod 2147483647, 32);
    variable stall : natural := 0;
    variable go : boolean;
    function nxt(v : unsigned(31 downto 0)) return unsigned is
      variable x : unsigned(31 downto 0) := v;
    begin
      x := x xor shift_left(x, 13);
      x := x xor shift_right(x, 17);
      x := x xor shift_left(x, 5);
      return x;
    end function;
  begin
    if rising_edge(clk) then
      if wr_en = '1' then
        assert wr_addr < NWORDS report "axi_rd_mem_model: bench write past NWORDS" severity failure;
        mem(wr_addr) <= wr_data;
      end if;
      if rst = '1' then
        qh := 0; qt := 0; qn := 0; busy := false; stall := 0;
        ar_r <= '0'; rv_r <= '0'; rl_r <= '0';
      else
        -- AR
        if arvalid = '1' and ar_r = '1' then
          qa(qt) := to_integer(unsigned(araddr)) / (AXI_DW/8);
          ql(qt) := to_integer(unsigned(arlen)) + 1;
          qt := (qt + 1) mod QD; qn := qn + 1;
        end if;
        lf := nxt(lf);
        if qn < QD - 1 and to_integer(lf(7 downto 0)) mod 100 >= GAPPCT / 2 then
          ar_r <= '1';
        else
          ar_r <= '0';
        end if;
        -- R: a beat leaves on the handshake
        if rv_r = '1' and rready = '1' then
          rv_r <= '0';
          if left = 0 then busy := false; end if;
        end if;
        if not busy and qn > 0 then
          cur := qa(qh); left := ql(qh);
          qh := (qh + 1) mod QD; qn := qn - 1; busy := true;
        end if;
        lf := nxt(lf);
        if stall > 0 then
          stall := stall - 1;
        elsif LONGPM > 0 and to_integer(lf(19 downto 10)) < LONGPM then
          stall := LONGLEN;
        end if;
        go := stall = 0 and to_integer(lf(29 downto 22)) mod 100 >= GAPPCT and hold = '0';
        if busy and left > 0 and go and not (rv_r = '1' and rready = '0') then
          assert cur < NWORDS report "axi_rd_mem_model: read past NWORDS" severity failure;
          rd_r <= mem(cur);
          rv_r <= '1';
          if left = 1 then rl_r <= '1'; else rl_r <= '0'; end if;
          cur := cur + 1; left := left - 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
