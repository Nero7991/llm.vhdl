-- sim/tb_mv_tile.vhd -- rtl/mv_tile.vhd against tools/mv_tile_model.py.
--
-- Vectors: sim/mv_tile_vec.txt (tools/mv_tile_model.py --write; --check proves it is
-- current).  Every expected value comes from that model, which is checked against
-- ref/matvec_int4.c by `tools/mv_tile_model.py --selftest`; nothing here computes one.
--
-- Per case: the weight beats go into an AXI read model (random RVALID gaps), then the
-- bench plays the distributor: a PARAM flit (which starts the tile's weight port), 16 CB
-- flits, then one ITEM flit per (row-tile, block).  Flits travel through LF bench
-- registers and `room` comes back through LR, the depths of the real trees, and a random
-- gate withholds flits so the tile drains and refills.  The result side takes words
-- under a random RDY.  Checks, counted in variables: every row-tile's two 48-bit values
-- and its sat bit (CHECK_VALUES), and the number of results per case (always).
--
-- CHECK_VALUES = false is the attribution control for the mutation rows
-- (sim/mutants/mv_tile_attr.json): a value mutant must survive it, a dropped-valid mutant
-- must not.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_mv_tile is
  generic(
    VEC          : string   := "mv_tile_vec.txt";
    XD           : positive := 32;
    SLACK        : positive := 12;
    LF           : positive := 5;
    LR           : positive := 3;
    FGAP         : natural  := 20;   -- percent of cycles the bench withholds a flit
    RGAP         : natural  := 30;   -- percent of cycles result RDY is low
    CHECK_VALUES : boolean  := true;
    -- NO_DRAIN: skip the inter-case wait-for-every-result and the 80-cycle flush, and
    -- move to the next case's PARAM as soon as this case's flits are all SENT.  Default
    -- false reproduces the normal bench exactly.  Exists only to demonstrate that
    -- mv_tile's job-serialisation assertion (rtl/mv_tile.vhd, process `serialize`) has
    -- teeth: sim/mutants/mv_tile.json row J1 flips this generic's default to true.
    NO_DRAIN     : boolean  := false
  );
end entity;

architecture sim of tb_mv_tile is
  constant BLK : positive := 32;
  constant TCK : time := 1.111 ns;
  constant MAXB : positive := 1024;    -- beats per case the bench can hold
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal done_sim : boolean := false;

  signal arvalid, arready, rvalid, rready, rlast : std_logic;
  signal araddr : std_logic_vector(39 downto 0);
  signal arlen  : std_logic_vector(7 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst : std_logic_vector(1 downto 0);
  signal rdata  : std_logic_vector(255 downto 0);
  signal wr_en  : std_logic := '0';
  signal wr_addr : natural := 0;
  signal wr_data : std_logic_vector(255 downto 0) := (others => '0');

  signal w_beats : integer := 0;
  signal f_v : std_logic := '0';
  signal f_kind : std_logic_vector(1 downto 0) := "00";
  signal f_x : std_logic_vector(BLK*16-1 downto 0) := (others => '0');
  signal f_s : std_logic_vector(31 downto 0) := (others => '0');
  signal f_first, f_last : std_logic := '0';
  signal room : std_logic;
  signal r_v, r_rdy : std_logic := '0';
  signal r_d : std_logic_vector(96 downto 0);
begin
  clk <= not clk after TCK when not done_sim else '0';

  dut : entity work.mv_tile
    generic map(BLK => BLK, AXI_DW => 256, ADDR_W => 40, DEPTH => 64, MAXB => 16,
                MAXOUT => 16, XD => XD, SLACK => SLACK, RD => 4)
    port map(clk => clk, rst => rst, w_base => (others => '0'), w_beats => w_beats,
             arvalid => arvalid, arready => arready, araddr => araddr, arlen => arlen,
             arsize => arsize, arburst => arburst, rvalid => rvalid, rready => rready,
             rdata => rdata, rlast => rlast,
             f_v => f_v, f_kind => f_kind, f_x => f_x, f_s => f_s,
             f_first => f_first, f_last => f_last, room => room,
             r_v => r_v, r_d => r_d, r_rdy => r_rdy);

  mem : entity work.axi_rd_mem_model
    generic map(AXI_DW => 256, ADDR_W => 40, NWORDS => MAXB, SEED => 7, GAPPCT => 25)
    port map(clk => clk, rst => rst, arvalid => arvalid, arready => arready,
             araddr => araddr, arlen => arlen, rvalid => rvalid, rready => rready,
             rdata => rdata, rlast => rlast,
             wr_en => wr_en, wr_addr => wr_addr, wr_data => wr_data);

  run : process
    file fv : text;
    variable l : line;
    variable tok : string(1 to 8);
    variable ch : character;
    variable good : boolean;
    type x_arr is array(0 to MAXB-1) of std_logic_vector(BLK*16-1 downto 0);
    type s_arr is array(0 to MAXB-1) of std_logic_vector(31 downto 0);
    type b_arr is array(0 to MAXB-1) of std_logic;
    type v_arr is array(0 to 63) of std_logic_vector(96 downto 0);
    variable xs : x_arr;
    variable ss : s_arr;
    variable fs, ls : b_arr;
    variable ev : v_arr;
    variable cbv : integer;
    type cb_arr is array(0 to 15) of integer;
    variable cbs : cb_arr;
    variable cid, osh, mode, nb, nt, t, b, fi, la, sat, nflit, nres : integer;
    variable w256 : std_logic_vector(255 downto 0);
    variable x512 : std_logic_vector(BLK*16-1 downto 0);
    variable s32 : std_logic_vector(31 downto 0);
    variable v48a, v48b : std_logic_vector(47 downto 0);
    variable checks, fails, ncase, waitc : natural := 0;
    -- flit pipeline (the tree) and room pipeline
    type fl_t is record
      v : std_logic; k : std_logic_vector(1 downto 0);
      x : std_logic_vector(BLK*16-1 downto 0); s : std_logic_vector(31 downto 0);
      f, l : std_logic;
    end record;
    type fp_t is array(0 to LF-1) of fl_t;
    variable fp : fp_t;
    variable rp : std_logic_vector(LR-1 downto 0);
    variable nxt : fl_t;
    variable rng : unsigned(31 downto 0) := x"1234ABCD";
    variable sent, total : integer;

    procedure rnd is
    begin
      rng := rng xor shift_left(rng, 13);
      rng := rng xor shift_right(rng, 17);
      rng := rng xor shift_left(rng, 5);
    end procedure;
    procedure skip(variable ln : inout line) is
      variable c : character;
    begin
      while ln'length > 0 and (ln(ln'left) = ' ' or ln(ln'left) = HT) loop
        read(ln, c);
      end loop;
    end procedure;
    procedure rhex(variable ln : inout line; v : out std_logic_vector) is
      variable c : character;
      variable n : integer;
      variable r : std_logic_vector(v'length-1 downto 0);
    begin
      skip(ln);
      for i in v'length/4 - 1 downto 0 loop
        read(ln, c);
        case c is
          when '0' to '9' => n := character'pos(c) - character'pos('0');
          when 'A' to 'F' => n := character'pos(c) - character'pos('A') + 10;
          when 'a' to 'f' => n := character'pos(c) - character'pos('a') + 10;
          when others => n := 0;
            report "tb_mv_tile: bad hex character in " & VEC severity failure;
        end case;
        r(i*4 + 3 downto i*4) := std_logic_vector(to_unsigned(n, 4));
      end loop;
      v := r;
    end procedure;
    procedure rword(variable ln : inout line; w : out string) is
      variable c : character;
      variable s : string(1 to 8) := (others => ' ');
      variable i : natural := 0;
    begin
      skip(ln);
      while ln'length > 0 and ln(ln'left) /= ' ' loop
        read(ln, c);
        i := i + 1;
        if i <= 8 then s(i) := c; end if;
      end loop;
      w := s;
    end procedure;
    procedure tick is
    begin
      wait until rising_edge(clk);
    end procedure;
  begin
    file_open(fv, VEC, read_mode);
    for i in 0 to LF-1 loop fp(i).v := '0'; end loop;
    rp := (others => '0');
    rst <= '1';
    for i in 1 to 8 loop tick; end loop;
    rst <= '0';
    tick;
    while not endfile(fv) loop
      readline(fv, l);
      if l'length = 0 then next; end if;
      if l(l'left) = '#' then next; end if;
      rword(l, tok);
      if tok(1 to 4) = "DONE" then
        read(l, cid);
        assert cid = ncase report "tb_mv_tile: DONE count disagrees with the cases read"
          severity failure;
        exit;
      end if;
      assert tok(1 to 4) = "CASE" report "tb_mv_tile: expected CASE, got " & tok severity failure;
      read(l, cid); read(l, osh); read(l, mode); read(l, nb); read(l, nt);
      readline(fv, l); rword(l, tok);
      for i in 0 to 15 loop read(l, cbv); cbs(i) := cbv; end loop;
      -- the B lines: weights straight into the AXI model, the rest kept for the flits
      for i in 0 to nt*nb - 1 loop
        readline(fv, l); rword(l, tok);
        read(l, t); read(l, b);
        rhex(l, w256); rhex(l, x512); rhex(l, s32); read(l, fi); read(l, la);
        assert t*nb + b = i report "tb_mv_tile: B lines out of order" severity failure;
        xs(i) := x512; ss(i) := s32;
        if fi = 1 then fs(i) := '1'; else fs(i) := '0'; end if;
        if la = 1 then ls(i) := '1'; else ls(i) := '0'; end if;
        wr_en <= '1'; wr_addr <= i; wr_data <= w256;
        tick;
      end loop;
      wr_en <= '0';
      for i in 0 to nt - 1 loop
        readline(fv, l); rword(l, tok);
        read(l, t); rhex(l, v48a); rhex(l, v48b); read(l, sat);
        ev(i)(47 downto 0) := v48a; ev(i)(95 downto 48) := v48b;
        if sat = 1 then ev(i)(96) := '1'; else ev(i)(96) := '0'; end if;
      end loop;
      readline(fv, l); rword(l, tok);
      assert tok(1 to 3) = "END" report "tb_mv_tile: expected END" severity failure;
      w_beats <= nt * nb;

      -- play the flits; collect the results
      total := 17 + nt*nb; sent := 0; nres := 0; waitc := 0;
      while nres < nt and not (NO_DRAIN and sent >= total) loop
        -- result side: the handshake happened at the edge we just passed
        rnd;
        -- send decision on the room seen LR cycles ago
        nxt.v := '0';
        if sent < total and rp(LR-1) = '1' and to_integer(rng(7 downto 0)) mod 100 >= FGAP then
          nxt.v := '1'; nxt.x := (others => '0'); nxt.s := (others => '0');
          nxt.f := '0'; nxt.l := '0';
          if sent = 0 then
            nxt.k := "10";
            nxt.x(5 downto 0) := std_logic_vector(to_unsigned(osh, 6));
            nxt.x(7 downto 6) := std_logic_vector(to_unsigned(mode, 2));
          elsif sent <= 16 then
            nxt.k := "01";
            nxt.x(3 downto 0) := std_logic_vector(to_unsigned(sent - 1, 4));
            nxt.x(11 downto 4) := std_logic_vector(to_signed(cbs(sent - 1), 8));
          else
            nxt.k := "00";
            nxt.x := xs(sent - 17); nxt.s := ss(sent - 17);
            nxt.f := fs(sent - 17); nxt.l := ls(sent - 17);
          end if;
          sent := sent + 1;
        end if;
        f_v <= fp(LF-1).v; f_kind <= fp(LF-1).k; f_x <= fp(LF-1).x; f_s <= fp(LF-1).s;
        f_first <= fp(LF-1).f; f_last <= fp(LF-1).l;
        for i in LF-1 downto 1 loop fp(i) := fp(i-1); end loop;
        fp(0) := nxt;
        if to_integer(rng(15 downto 8)) mod 100 >= RGAP then r_rdy <= '1'; else r_rdy <= '0'; end if;
        tick;
        rp := rp(LR-2 downto 0) & room;
        if r_v = '1' and r_rdy = '1' then
          checks := checks + 1;
          if CHECK_VALUES and r_d /= ev(nres) then
            fails := fails + 1;
            report "tb_mv_tile: MISMATCH case " & integer'image(cid) & " row-tile "
                 & integer'image(nres) & " got " & to_hstring(r_d) & " want "
                 & to_hstring(ev(nres)) severity error;
          end if;
          nres := nres + 1;
        end if;
        waitc := waitc + 1;
        assert waitc < 200000 report "tb_mv_tile: case " & integer'image(cid)
          & " timed out with " & integer'image(nres) & " of " & integer'image(nt)
          & " results" severity failure;
      end loop;
      f_v <= '0'; r_rdy <= '0';
      if not NO_DRAIN then
        -- flush the tree model; no stray result may follow
        for i in 0 to LF-1 loop fp(i).v := '0'; end loop;
        for i in 1 to 80 loop
          tick;
          rp := rp(LR-2 downto 0) & room;
          assert r_v = '0' report "tb_mv_tile: an extra result after the case's last row-tile"
            severity failure;
        end loop;
      end if;
      checks := checks + 1;
      ncase := ncase + 1;
    end loop;
    assert ncase > 0 report "tb_mv_tile: no cases read" severity failure;
    assert fails = 0 report "tb_mv_tile: FAIL " & integer'image(fails) & " mismatches"
      severity failure;
    report "PASS: tb_mv_tile checks=" & integer'image(checks) & " cases="
         & integer'image(ncase) severity note;
    done_sim <= true;
    wait;
  end process;
end architecture;
