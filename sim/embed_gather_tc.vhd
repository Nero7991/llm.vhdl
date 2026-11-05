-- sim/embed_gather_tc.vhd -- the embed_gather test body (plan 2026-11-04 Task 3), shared by
-- sim/tb_embed_gather.vhd (K 4096, the 9B) and sim/tb_embed_gather_27b.vhd (K 5120). Oracle:
-- the host's pl_embed_mv4i rows in the vector file. The HBM image is poked into
-- sim/jc_axi3_mem, which also enforces the AXI3 rules on every burst.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity embed_gather_tc is
  generic(N_EMBD : positive := 4096; VEC : string := "embed_gather_k4096_vec.txt";
          TB_NAME : string := "tb_embed_gather");
end entity;

architecture sim of embed_gather_tc is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal emb_base : unsigned(32 downto 0) := (others => '0');
  signal inval, req, exp_valid, err, m_valid, m_ready : std_logic := '0';
  signal tok : unsigned(31 downto 0) := (others => '0');
  signal exp_val : std_logic_vector(31 downto 0);
  signal err_code : std_logic_vector(3 downto 0);
  signal m_data : std_logic_vector(15 downto 0);
  signal araddr : std_logic_vector(32 downto 0);
  signal arlen : std_logic_vector(7 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst : std_logic_vector(1 downto 0);
  signal arvalid, arready, rlast, rvalid, rready : std_logic;
  signal rdata : std_logic_vector(255 downto 0);
  signal rresp : std_logic_vector(1 downto 0);
  signal poke_en : std_logic := '0';
  signal poke_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal poke_data : std_logic_vector(255 downto 0) := (others => '0');
  signal mem_errs : natural;
  signal arlen_hi_seen : natural := 0;
begin
  clk <= not clk after 2.5 ns;

  dut : entity work.embed_gather
    generic map(N_EMBD => N_EMBD, ADDR_W => 33)
    port map(clk => clk, rst => rst, emb_base => emb_base, invalidate => inval, req => req,
             tok => tok, exp_valid => exp_valid, exp_val => exp_val, err => err,
             err_code => err_code, m_valid => m_valid, m_data => m_data, m_ready => m_ready,
             m_axi_araddr => araddr, m_axi_arlen => arlen, m_axi_arsize => arsize,
             m_axi_arburst => arburst, m_axi_arvalid => arvalid, m_axi_arready => arready,
             m_axi_rdata => rdata, m_axi_rresp => rresp, m_axi_rlast => rlast,
             m_axi_rvalid => rvalid, m_axi_rready => rready);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 14, STALL => true)
    port map(clk => clk, awaddr => (others => '0'), awlen => "0000", awsize => "101",
             awburst => "01", awvalid => '0', awready => open, wdata => (others => '0'),
             wstrb => (others => '0'), wlast => '0', wvalid => '0', wready => open,
             bresp => open, bvalid => open, bready => '1',
             araddr => araddr, arlen => arlen(3 downto 0), arsize => arsize, arburst => arburst,
             arvalid => arvalid, arready => arready, rdata => rdata, rresp => rresp,
             rlast => rlast, rvalid => rvalid, rready => rready,
             poke_en => poke_en, poke_addr => poke_addr, poke_data => poke_data,
             peek_addr => (others => '0'), peek_data => open, peek_hit => open, errors => mem_errs);

  process(clk)
  begin
    if rising_edge(clk) then
      if arvalid = '1' and arlen(7 downto 4) /= "0000" then arlen_hi_seen <= arlen_hi_seen + 1; end if;
    end if;
  end process;

  main : process
    file f : text open read_mode is VEC;
    variable l : line;
    variable ch : character;
    variable a9 : std_logic_vector(35 downto 0);
    variable b256 : std_logic_vector(255 downto 0);
    variable n, nbeats, mcount, t, want_exp, m, bad : integer;
    variable e, c : natural := 0;
    variable lfsr : std_logic_vector(15 downto 0) := x"B00F";
    variable hdr0 : std_logic_vector(255 downto 0);
    type iv_t is array (0 to N_EMBD-1) of integer;
    variable want : iv_t;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report TB_NAME & ": " & msg severity error; end if;
    end procedure;
    procedure get_row(tk : natural; ok_exp : out boolean) is
    begin
      tok <= to_unsigned(tk, 32); req <= '1'; wait until rising_edge(clk); req <= '0';
      wait until rising_edge(clk);   -- let a stale err/err_code from the prior call clear (finding 7)
      n := 0;
      while exp_valid = '0' and err = '0' loop
        wait until rising_edge(clk); n := n + 1;
        assert n < 400000 report TB_NAME & ": no exponent" severity failure;
      end loop;
      ok_exp := exp_valid = '1';
    end procedure;
    variable okx : boolean;
  begin
    -- the image
    readline(f, l); while l(1) = '#' loop readline(f, l); end loop;
    read(l, ch); hread(l, a9); read(l, nbeats); read(l, mcount);
    emb_base <= unsigned(a9(32 downto 0));
    for k in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for k in 0 to nbeats - 1 loop
      readline(f, l); read(l, ch); hread(l, a9); hread(l, b256);
      if k = 0 then hdr0 := b256; end if;
      poke_en <= '1'; poke_addr <= "0000" & a9; poke_data <= b256;
      wait until rising_edge(clk);
    end loop;
    poke_en <= '0';
    wait until rising_edge(clk);
    inval <= '1'; wait until rising_edge(clk); inval <= '0';
    -- the rows
    while not endfile(f) loop
      readline(f, l); read(l, ch); read(l, t); read(l, want_exp);
      readline(f, l); read(l, ch);
      for k in 0 to N_EMBD - 1 loop read(l, m); want(k) := m; end loop;
      get_row(t, okx);
      chk(okx, "tok " & integer'image(t) & " no error");
      chk(to_integer(signed(exp_val)) = want_exp, "tok " & integer'image(t) & " exponent equals pl_embed_mv4i's");
      bad := 0;
      for k in 0 to N_EMBD - 1 loop
        while m_valid = '0' loop wait until rising_edge(clk); end loop;
        if to_integer(signed(m_data)) /= want(k) then
          if bad < 4 then
            report TB_NAME & ": tok " & integer'image(t) & " element " & integer'image(k) & " got " &
                   integer'image(to_integer(signed(m_data))) & " want " & integer'image(want(k)) severity error;
          end if;
          bad := bad + 1;
        end if;
        lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
        if lfsr(0) = '1' then wait until rising_edge(clk); end if;   -- consumer stalls
        m_ready <= '1'; wait until rising_edge(clk); m_ready <= '0';
        wait until rising_edge(clk);
      end loop;
      chk(bad = 0, "tok " & integer'image(t) & ": every mantissa equals pl_embed_mv4i's");
      wait until rising_edge(clk);
      chk(exp_valid = '0', "exp_valid drops after the last mantissa");
    end loop;
    -- token out of range: err code 2
    get_row(mcount, okx);
    chk(not okx and err_code = "0010", "token = M is refused with code 2");
    -- corrupted magic: err code 1 after invalidate
    poke_en <= '1'; poke_addr <= "0000000" & std_logic_vector(emb_base);
    poke_data <= hdr0(255 downto 32) & x"00000000";
    wait until rising_edge(clk); poke_en <= '0';
    inval <= '1'; wait until rising_edge(clk); inval <= '0';
    get_row(0, okx);
    chk(not okx and err_code = "0001", "a header without MV4I is refused with code 1");
    chk(mem_errs = 0, "every burst obeyed the AXI3 rules (jc_axi3_mem)");
    chk(arlen_hi_seen = 0, "ARLEN never above 15");
    if e = 0 then
      report "PASS: " & TB_NAME & " checks=" & integer'image(c) severity note;
    else
      report "FAIL: " & TB_NAME & " errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
