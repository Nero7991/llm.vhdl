-- Bench for rtl/jc_hbm_writer.vhd: feeds the FIFO-side events of sim/jc_writer_vec.txt,
-- serves AXI3 through sim/jc_axi3_mem.vhd (which checks every burst rule), then compares
-- memory and counters against the Python model's final state.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.jc_loader_pkg.all;

entity tb_jc_hbm_writer is
end entity;

architecture sim of tb_jc_hbm_writer is
  constant CLK_P : time := 5 ns;
  signal clk, rst : std_logic := '0';
  signal done : boolean := false;
  signal q_valid, q_ready : std_logic := '0';
  signal q_data : std_logic_vector(JC_FIFO_W-1 downto 0) := (others => '0');
  signal awaddr : std_logic_vector(32 downto 0);
  signal awlen : std_logic_vector(3 downto 0);
  signal awsize : std_logic_vector(2 downto 0);
  signal awburst, bresp : std_logic_vector(1 downto 0);
  signal awvalid, awready, wlast, wvalid, wready, bvalid, bready : std_logic;
  signal wdata : std_logic_vector(255 downto 0);
  signal wstrb : std_logic_vector(31 downto 0);
  signal crc_req : std_logic;
  signal crc_addr : std_logic_vector(32 downto 0);
  signal crc_len : unsigned(39 downto 0);
  signal crc_seq, last_seq : std_logic_vector(31 downto 0);
  signal committed : unsigned(31 downto 0);
  signal crc_fail, seq_err, dup_cnt, bresp_err : unsigned(15 downto 0);
  signal busy : std_logic;
  signal peek_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal peek_data : std_logic_vector(255 downto 0);
  signal peek_hit : std_logic;
  signal axi_errors : natural;
begin
  clk <= not clk after CLK_P / 2 when not done else '0';

  dut : entity work.jc_hbm_writer
    port map(clk => clk, rst => rst, q_valid => q_valid, q_data => q_data, q_ready => q_ready,
             awaddr => awaddr, awlen => awlen, awsize => awsize, awburst => awburst,
             awvalid => awvalid, awready => awready, wdata => wdata, wstrb => wstrb,
             wlast => wlast, wvalid => wvalid, wready => wready, bresp => bresp,
             bvalid => bvalid, bready => bready, crc_req => crc_req, crc_addr => crc_addr,
             crc_len => crc_len, crc_seq => crc_seq, crc_busy => '0', last_seq => last_seq,
             committed => committed, crc_fail => crc_fail, seq_err => seq_err,
             dup_cnt => dup_cnt, bresp_err => bresp_err, busy => busy);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 11, STALL => true, BAD_BRESP_ADDR => x"0000000600")
    port map(clk => clk, awaddr => awaddr, awlen => awlen, awsize => awsize,
             awburst => awburst, awvalid => awvalid, awready => awready, wdata => wdata,
             wstrb => wstrb, wlast => wlast, wvalid => wvalid, wready => wready,
             bresp => bresp, bvalid => bvalid, bready => bready,
             araddr => (others => '0'), arlen => "0000", arsize => "101", arburst => "01",
             arvalid => '0', arready => open, rdata => open, rresp => open, rlast => open,
             rvalid => open, rready => '0', peek_addr => peek_addr, peek_data => peek_data,
             peek_hit => peek_hit, errors => axi_errors);

  driver : process
    file vf : text open read_mode is "jc_writer_vec.txt";
    variable l : line;
    variable c : character;
    variable w : std_logic_vector(255 downto 0);
    variable a : std_logic_vector(39 downto 0);
    variable s32, e32 : std_logic_vector(31 downto 0);
    variable e16a, e16b, e16c, e16d : std_logic_vector(15 downto 0);
    variable checks, errors, nmem : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then errors := errors + 1; report msg severity error; end if;
    end procedure;
    procedure push(tag : std_logic_vector(1 downto 0); d : std_logic_vector(255 downto 0)) is
    begin
      q_data <= tag & d; q_valid <= '1';
      wait until rising_edge(clk) and q_ready = '1';
      q_valid <= '0';
    end procedure;
  begin
    rst <= '1'; wait for 4 * CLK_P; wait until rising_edge(clk); rst <= '0';
    while not endfile(vf) loop
      readline(vf, l);
      read(l, c);
      case c is
        when 'B' => null;                                   -- configured by the generic
        when 'H' => hread(l, w); push(TAG_HDR, w);
        when 'D' => hread(l, w); push(TAG_DATA, w);
        when 'P' => hread(l, s32); push(TAG_PASS, std_logic_vector(resize(unsigned(s32), 256)));
        when 'F' => hread(l, s32); push(TAG_FAIL, std_logic_vector(resize(unsigned(s32), 256)));
        when 'M' =>
          if nmem = 0 then                                  -- drain before the first check
            for i in 0 to 2000 loop wait until rising_edge(clk); exit when busy = '0'; end loop;
            wait for 20 * CLK_P;
          end if;
          hread(l, a); hread(l, w);
          peek_addr <= a; wait for 1 ns;
          chk(peek_hit = '1' and peek_data = w, "memory at " & to_hstring(a));
          nmem := nmem + 1;
        when 'C' =>
          hread(l, s32); chk(last_seq = s32, "last_seq " & to_hstring(last_seq));
          hread(l, e32); chk(std_logic_vector(committed) = e32, "committed");
          hread(l, e16a); chk(std_logic_vector(crc_fail) = e16a, "crc_fail");
          hread(l, e16b); chk(std_logic_vector(seq_err) = e16b, "seq_err");
          hread(l, e16c); chk(std_logic_vector(dup_cnt) = e16c, "dup");
          hread(l, e16d); chk(std_logic_vector(bresp_err) = e16d, "bresp_err");
        when others => report "bad vector line" severity failure;
      end case;
    end loop;
    chk(axi_errors = 0, "AXI3 rule violations: " & integer'image(axi_errors));
    chk(crc_req = '0', "no range CRC was requested");
    assert nmem = 97 report "expected 97 memory checks, did " & integer'image(nmem) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_hbm_writer checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_hbm_writer errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
