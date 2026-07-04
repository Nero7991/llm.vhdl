-- tb/tb_matvec_engine.vhd
-- GHDL testbench for rtl/matvec_engine.vhd (autonomous AXI4-Lite matvec engine).
--
-- Reads the bit-exact golden mem/golden/fx_matvec_wq_l0.txt:
--   line1: "d n"                     (=64 64)
--   line2: "EXP xe"                  (activation shared exponent; unused here)
--   line3: n int16 activation mantissas
--   then d rows: <n int16 weight mantissas> <int64 acc>
-- The weights live in the DUT's on-chip ROM (rtl/wq_l0_rom_pkg.vhd), so the TB
-- ignores the per-row weight columns and only uses the activations + the int64
-- golden acc.  It loads the activation vector over AXI, pulses START, polls
-- STATUS.done, then for each row selects it via ROW_IDX and reads ACC_LO/ACC_HI,
-- asserting it equals the golden int64 acc.  Prints "PASS:matvec_engine  64/64".
--
-- AXI read/write procedures modelled on tb/tb_mac_axi.vhd.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_matvec_engine is end;

architecture sim of tb_matvec_engine is
  constant AW_ADDR : integer := 8;
  constant OUT_DIM : integer := 64;
  constant IN_DIM  : integer := 64;

  signal clk  : std_logic := '0';
  signal rstn : std_logic := '0';
  -- AXI-Lite signals
  signal awaddr : std_logic_vector(AW_ADDR-1 downto 0) := (others=>'0');
  signal awvalid, awready : std_logic := '0';
  signal wdata : std_logic_vector(31 downto 0) := (others=>'0');
  signal wstrb : std_logic_vector(3 downto 0) := "1111";
  signal wvalid, wready : std_logic := '0';
  signal bresp : std_logic_vector(1 downto 0); signal bvalid : std_logic; signal bready : std_logic := '0';
  signal araddr : std_logic_vector(AW_ADDR-1 downto 0) := (others=>'0');
  signal arvalid, arready : std_logic := '0';
  signal rdata : std_logic_vector(31 downto 0); signal rresp : std_logic_vector(1 downto 0);
  signal rvalid : std_logic; signal rready : std_logic := '0';
begin
  clk <= not clk after 5 ns;

  uut: entity work.matvec_engine
    generic map(OUT_DIM=>OUT_DIM, IN_DIM=>IN_DIM, WW=>16, XW=>16, AW=>48)
    port map(s_axi_aclk=>clk, s_axi_aresetn=>rstn,
      s_axi_awaddr=>awaddr, s_axi_awprot=>"000", s_axi_awvalid=>awvalid, s_axi_awready=>awready,
      s_axi_wdata=>wdata, s_axi_wstrb=>wstrb, s_axi_wvalid=>wvalid, s_axi_wready=>wready,
      s_axi_bresp=>bresp, s_axi_bvalid=>bvalid, s_axi_bready=>bready,
      s_axi_araddr=>araddr, s_axi_arprot=>"000", s_axi_arvalid=>arvalid, s_axi_arready=>arready,
      s_axi_rdata=>rdata, s_axi_rresp=>rresp, s_axi_rvalid=>rvalid, s_axi_rready=>rready);

  process
    -- ---- AXI helpers (mirror tb_mac_axi) ----
    procedure axi_write(addr : integer; data : integer) is
    begin
      awaddr <= std_logic_vector(to_unsigned(addr, AW_ADDR));
      wdata  <= std_logic_vector(to_signed(data, 32));
      awvalid <= '1'; wvalid <= '1'; bready <= '1';
      wait until rising_edge(clk) and awready='1' and wready='1';
      awvalid <= '0'; wvalid <= '0';
      wait until rising_edge(clk) and bvalid='1';
      bready <= '0'; wait until rising_edge(clk);
    end procedure;
    procedure axi_read(addr : integer; result : out std_logic_vector(31 downto 0)) is
    begin
      araddr <= std_logic_vector(to_unsigned(addr, AW_ADDR));
      arvalid <= '1'; rready <= '1';
      wait until rising_edge(clk) and arready='1';
      arvalid <= '0';
      wait until rising_edge(clk) and rvalid='1';
      result := rdata; rready <= '0'; wait until rising_edge(clk);
    end procedure;

    -- Read the next whitespace-delimited signed decimal token from line L as a
    -- signed(63:0) (golden acc exceeds 32-bit integer range).
    procedure read_s64(variable L : inout line; variable r : out signed(63 downto 0)) is
      variable ch  : character;
      variable ok  : boolean;
      variable neg : boolean := false;
      variable acc : signed(63 downto 0) := (others=>'0');
      variable started : boolean := false;
    begin
      -- skip leading whitespace
      loop
        read(L, ch, ok);
        exit when not ok;
        exit when ch = '-' or (ch >= '0' and ch <= '9');
      end loop;
      if not ok then r := (others=>'0'); return; end if;
      if ch = '-' then neg := true;
      else acc := to_signed(character'pos(ch) - character'pos('0'), 64); started := true;
      end if;
      loop
        read(L, ch, ok);
        exit when not ok;
        exit when ch < '0' or ch > '9';
        acc := resize(acc * to_signed(10, 8), 64)
               + to_signed(character'pos(ch) - character'pos('0'), 64);
        started := true;
      end loop;
      if neg then acc := -acc; end if;
      r := acc;
    end procedure;

    file     gf   : text;
    variable L    : line;
    variable status : file_open_status;
    variable d_r, n_r : integer;
    variable itmp : integer;
    variable rd   : std_logic_vector(31 downto 0);
    type ivec is array(0 to IN_DIM-1) of integer;
    variable act  : ivec;
    type s64vec is array(0 to OUT_DIM-1) of signed(63 downto 0);
    variable gold : s64vec;
    variable acc48 : signed(47 downto 0);
    variable errors : integer := 0;
  begin
    -- ---- parse the golden file ----
    file_open(status, gf, "../mem/golden/fx_matvec_wq_l0.txt", read_mode);
    assert status = open_ok report "cannot open fx_matvec_wq_l0.txt" severity failure;
    readline(gf, L); read(L, d_r); read(L, n_r);          -- "d n"
    assert d_r = OUT_DIM and n_r = IN_DIM
      report "golden dims mismatch" severity failure;
    readline(gf, L);                                      -- "EXP xe" (skip)
    readline(gf, L);                                      -- activation mantissas
    for j in 0 to IN_DIM-1 loop read(L, itmp); act(j) := itmp; end loop;
    for i in 0 to OUT_DIM-1 loop                          -- rows: weights (skip) + acc
      readline(gf, L);
      for j in 0 to IN_DIM-1 loop read(L, itmp); end loop;
      read_s64(L, gold(i));
    end loop;
    file_close(gf);

    -- ---- reset ----
    rstn <= '0'; wait for 40 ns; wait until rising_edge(clk); rstn <= '1'; wait until rising_edge(clk);

    -- ---- ID sanity ----
    axi_read(16#20#, rd);
    assert rd = x"6D415631"
      report "ID mismatch got "&integer'image(to_integer(unsigned(rd))) severity failure;

    -- ---- load activation vector ----
    for j in 0 to IN_DIM-1 loop
      axi_write(16#0C#, j);          -- LOAD_IDX
      axi_write(16#10#, act(j));     -- LOAD_ACT
    end loop;

    -- ---- start + poll STATUS.done ----
    axi_write(16#00#, 1);            -- CTRL START
    loop
      axi_read(16#04#, rd);          -- STATUS
      exit when rd(0) = '1';
    end loop;

    -- ---- read every row's accumulator, compare to golden ----
    for i in 0 to OUT_DIM-1 loop
      axi_write(16#14#, i);          -- ROW_IDX
      axi_read(16#18#, rd);          -- ACC_LO
      acc48(31 downto 0) := signed(rd);
      axi_read(16#1C#, rd);          -- ACC_HI (sign-extended [47:32])
      acc48(47 downto 32) := signed(rd(15 downto 0));
      if resize(acc48, 64) /= gold(i) then
        errors := errors + 1;
        if errors <= 3 then
          report "FAIL:matvec_engine row "&integer'image(i)
                 &" got 0x"&to_hstring(std_logic_vector(acc48))
                 &" expect 0x"&to_hstring(std_logic_vector(gold(i)(47 downto 0)))
            severity error;
        end if;
      end if;
    end loop;

    if errors = 0 then
      report "PASS:matvec_engine  "&integer'image(OUT_DIM)&"/"&integer'image(OUT_DIM)
        severity note;
    else
      report "FAIL:matvec_engine  "&integer'image(OUT_DIM-errors)&"/"&integer'image(OUT_DIM)
             &" rows correct" severity failure;
    end if;
    finish;
  end process;
end;
