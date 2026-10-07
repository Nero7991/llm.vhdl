-- Bench for rtl/jc_ctl_exec.vhd (plan Task 3): the clk_core-domain executor of the USER3
-- control core. The DUT is driven with the frame core's FIFO word stream (TAG & word) and a
-- toggle-level rsp_ack_tgl, and observed through:
--   * sim/axil_slave_model.vhd: an independent AXI-Lite recorder (64 KB registers, a
--     transaction log in order, SLVERR at 0xF000, DECERR at >= 0x10000, a read-counting
--     register at 0xF100 so a read executed twice shows as a skipped value);
--   * sim/jc_axi3_mem.vhd (read side, seeded by poke): HBM AXI3 rules counted on `errors`;
--   * a bench AR monitor that records every HBM burst (address, length) and checks
--     4 KB / 16-beat / size / burst type independently of the memory model;
--   * a bench copy of the response RAM (rsp_we), and a monitor that counts every RAM write
--     made while rsp_valid = 1 (the response being presented must never be overwritten);
--   * a publication monitor: every rising rsp_valid must carry an rsp_seq different from the
--     previous publication's;
--   * an ack-order monitor: a frame that carries the ack of the presented response must not
--     reach last_done_seq while rsp_valid is still 1.
-- The bench models the frame core's ack decision: a PASS frame with ack_valid = 1 and
-- ack_seq = the rsp_seq presented (rsp_valid = 1, not already acked) toggles rsp_ack_tgl,
-- with the toggle placed before, with, or (caller-controlled) long after the PASS word.
-- The response CRC is checked with a bench-local CRC-32 (bytewise, reflected, written here,
-- known-answer checked against "123456789" = 0xCBF43926), not the loader package function.
-- All checks are counted in variables.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;
use work.jc_ctl_pkg.all;

entity tb_jc_ctl_exec is
end entity;

architecture sim of tb_jc_ctl_exec is
  constant TCLK      : time := 5 ns;
  constant SLVERR_A  : std_logic_vector(31 downto 0) := x"0000F000";
  constant CNT_A     : std_logic_vector(31 downto 0) := x"0000F100";
  constant BAD_HBM   : std_logic_vector(39 downto 0) := x"0180003000";
  constant NONE      : std_logic_vector(31 downto 0) := x"FFFFFFFF";
  constant TMO       : positive := 2000;   -- the DUT's response timeout, cycles

  signal clk     : std_logic := '0';
  signal running : boolean := true;
  signal rst     : std_logic := '1';

  signal q_valid, q_ready : std_logic := '0';
  signal q_data  : std_logic_vector(JC_FIFO_W-1 downto 0) := (others => '0');
  signal ack_tgl : std_logic := '0';
  constant QN : natural := 4096;
  type qm_t is array (0 to QN-1) of std_logic_vector(JC_FIFO_W-1 downto 0);
  signal qmem : qm_t := (others => (others => '0'));
  signal q_wp, q_rp : natural := 0;

  signal l_awaddr, l_wdata, l_araddr, l_rdata : std_logic_vector(31 downto 0);
  signal l_awprot, l_arprot : std_logic_vector(2 downto 0);
  signal l_wstrb : std_logic_vector(3 downto 0);
  signal l_awvalid, l_awready, l_wvalid, l_wready, l_bvalid, l_bready : std_logic;
  signal l_arvalid, l_arready, l_rvalid, l_rready : std_logic;
  signal l_bresp, l_rresp : std_logic_vector(1 downto 0);

  signal h_araddr : std_logic_vector(32 downto 0);
  signal h_arlen  : std_logic_vector(7 downto 0);
  signal h_arsize : std_logic_vector(2 downto 0);
  signal h_arburst, h_rresp : std_logic_vector(1 downto 0);
  signal h_arvalid, h_arready, h_rvalid, h_rready, h_rlast : std_logic;
  signal h_rdata  : std_logic_vector(255 downto 0);

  signal rsp_we    : std_logic;
  signal rsp_waddr : std_logic_vector(8 downto 0);
  signal rsp_wdata : std_logic_vector(31 downto 0);
  signal st        : std_logic_vector(383 downto 0);
  signal busy      : std_logic;

  -- slave model observation
  signal log_count, log_idx, log_kind, axil_err : natural := 0;
  signal log_addr, log_data, reg_addr, reg_data : std_logic_vector(31 downto 0) := (others => '0');
  signal log_resp : std_logic_vector(1 downto 0);
  -- HBM model
  signal poke_en   : std_logic := '0';
  signal poke_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal poke_data : std_logic_vector(255 downto 0) := (others => '0');
  signal hbm_err   : natural;
  signal h_rvalid_m : std_logic;                     -- the model's RVALID, before the mute gate
  signal h_rresp_m  : std_logic_vector(1 downto 0);  -- the model's RRESP, before the override
  signal hmute      : std_logic := '0';               -- HBM stops delivering R beats
  signal mute_b, mute_r : std_logic := '0';           -- AXI-Lite stops answering B / R
  signal bad_b      : boolean := false;               -- the current burst is the RRESP-error one
  signal bad_n      : natural := 0;                   -- R beats received in it

  -- monitors
  type ram_t is array (0 to 511) of std_logic_vector(31 downto 0);
  signal ram       : ram_t := (others => (others => '0'));
  signal n_ramwr   : natural := 0;
  signal n_ovw     : natural := 0;     -- RAM writes while rsp_valid = 1
  signal n_pub     : natural := 0;
  signal n_dup     : natural := 0;     -- publications repeating the previous rsp_seq
  signal ackfrm    : std_logic_vector(31 downto 0) := NONE;  -- a frame carrying the ack
  signal n_ackord  : natural := 0;     -- that frame done while rsp_valid still 1
  type ba_t is array (0 to 255) of std_logic_vector(32 downto 0);
  type bl_t is array (0 to 255) of natural;
  signal b_addr    : ba_t := (others => (others => '0'));
  signal b_len     : bl_t := (others => 0);
  signal n_burst   : natural := 0;
  signal n_bviol   : natural := 0;

  function s32(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n, 32));
  end function;
  -- the HBM seed: one 256-bit word per 32-byte address
  function memw(a : unsigned(39 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(255 downto 0);
    variable p : unsigned(63 downto 0);
  begin
    for k in 0 to 7 loop
      p := resize(a(39 downto 5) * to_unsigned(8, 4) + k + 1, 32) * unsigned'(x"9E3779B9");
      r(32*k+31 downto 32*k) := std_logic_vector(p(31 downto 0) xor p(63 downto 32))
                                xor x"5A000000";
    end loop;
    return r;
  end function;
  -- bench-local CRC-32: bytes in little-endian order, each byte LSB first, poly 0xEDB88320
  function crc_byte(c : std_logic_vector(31 downto 0); b : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable r : unsigned(31 downto 0) := unsigned(c);
  begin
    for i in 0 to 7 loop
      if (r(0) xor b(i)) = '1' then
        r := shift_right(r, 1) xor x"EDB88320";
      else
        r := shift_right(r, 1);
      end if;
    end loop;
    return std_logic_vector(r);
  end function;
begin
  clk <= not clk after TCLK / 2 when running else '0';

  dut : entity work.jc_ctl_exec
    generic map(ADDR_W => 33, TMO_CYC => TMO)
    port map(clk => clk, rst => rst,
             q_valid => q_valid, q_data => q_data, q_ready => q_ready,
             rsp_ack_tgl => ack_tgl,
             m_axil_awaddr => l_awaddr, m_axil_awprot => l_awprot, m_axil_awvalid => l_awvalid,
             m_axil_awready => l_awready, m_axil_wdata => l_wdata, m_axil_wstrb => l_wstrb,
             m_axil_wvalid => l_wvalid, m_axil_wready => l_wready, m_axil_bresp => l_bresp,
             m_axil_bvalid => l_bvalid, m_axil_bready => l_bready,
             m_axil_araddr => l_araddr, m_axil_arprot => l_arprot, m_axil_arvalid => l_arvalid,
             m_axil_arready => l_arready, m_axil_rdata => l_rdata, m_axil_rresp => l_rresp,
             m_axil_rvalid => l_rvalid, m_axil_rready => l_rready,
             m_axi_araddr => h_araddr, m_axi_arlen => h_arlen, m_axi_arsize => h_arsize,
             m_axi_arburst => h_arburst, m_axi_arvalid => h_arvalid, m_axi_arready => h_arready,
             m_axi_rdata => h_rdata, m_axi_rresp => h_rresp, m_axi_rlast => h_rlast,
             m_axi_rvalid => h_rvalid, m_axi_rready => h_rready,
             rsp_we => rsp_we, rsp_waddr => rsp_waddr, rsp_wdata => rsp_wdata,
             st_out => st, busy => busy);

  axil : entity work.axil_slave_model
    generic map(SLVERR_ADDR => SLVERR_A, CNT_ADDR => CNT_A)
    port map(clk => clk, awaddr => l_awaddr, awvalid => l_awvalid, awready => l_awready,
             wdata => l_wdata, wstrb => l_wstrb, wvalid => l_wvalid, wready => l_wready,
             bresp => l_bresp, bvalid => l_bvalid, bready => l_bready,
             araddr => l_araddr, arvalid => l_arvalid, arready => l_arready,
             rdata => l_rdata, rresp => l_rresp, rvalid => l_rvalid, rready => l_rready,
             log_count => log_count, log_idx => log_idx, log_kind => log_kind,
             log_addr => log_addr, log_data => log_data, log_resp => log_resp,
             reg_addr => reg_addr, reg_data => reg_data, errors => axil_err,
             mute_b => mute_b, mute_r => mute_r);

  hbm : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 11, STALL => true, BAD_RRESP_ADDR => BAD_HBM)
    port map(clk => clk,
             awaddr => (others => '0'), awlen => "0000", awsize => "101", awburst => "01",
             awvalid => '0', awready => open, wdata => (others => '0'),
             wstrb => (others => '1'), wlast => '0', wvalid => '0', wready => open,
             bresp => open, bvalid => open, bready => '1',
             araddr => h_araddr, arlen => h_arlen(3 downto 0), arsize => h_arsize,
             arburst => h_arburst, arvalid => h_arvalid, arready => h_arready,
             rdata => h_rdata, rresp => h_rresp_m, rlast => h_rlast, rvalid => h_rvalid_m,
             rready => h_rready and not hmute, poke_en => poke_en, poke_addr => poke_addr,
             poke_data => poke_data, peek_addr => (others => '0'), peek_data => open,
             peek_hit => open, errors => hbm_err);

  -- HBM R gate (a memory that stops delivering beats) and an RRESP override: in the burst
  -- that starts at BAD_HBM the memory answers SLVERR on every beat; the second beat is turned
  -- into DECERR so the executor must keep the FIRST error's code
  h_rvalid <= h_rvalid_m and not hmute;
  h_rresp  <= "11" when bad_b and bad_n = 1 and h_rresp_m = "10" else h_rresp_m;

  -- the bench FIFO's read side: presents queued words to the DUT with random gaps
  feed : process(clk)
    variable g  : std_logic_vector(15 downto 0) := x"3C1D";
    variable rp : natural;
    variable v  : std_logic;
  begin
    if rising_edge(clk) then
      g  := g(14 downto 0) & (g(15) xor g(13) xor g(12) xor g(10));
      v  := q_valid;
      rp := q_rp;
      if q_valid = '1' and q_ready = '1' then
        rp := q_rp + 1; q_rp <= rp; v := '0';
      end if;
      if v = '0' then
        if rp < q_wp and not (g(0) = '1' and g(3) = '1') then
          q_valid <= '1'; q_data <= qmem(rp);
        else
          q_valid <= '0';
        end if;
      end if;
    end if;
  end process;

  -- monitors
  mon : process(clk)
    variable prev_v    : std_logic := '0';
    variable prev_pub  : std_logic_vector(31 downto 0) := NONE;
    variable first_pub : boolean := true;
    variable prev_done : std_logic_vector(31 downto 0) := NONE;
    variable a         : unsigned(32 downto 0);
    variable nb        : natural;
  begin
    if rising_edge(clk) then
      if rsp_we = '1' then
        ram(to_integer(unsigned(rsp_waddr))) <= rsp_wdata;
        n_ramwr <= n_ramwr + 1;
        if st(JC_S_RSPVALID) = '1' then
          n_ovw <= n_ovw + 1;
          report "MONITOR: response RAM written while rsp_valid = 1 (rsp_seq "
                 & to_hstring(st(JC_S_RSPSEQ_HI downto JC_S_RSPSEQ_LO)) & ")" severity error;
        end if;
      end if;
      if st(JC_S_RSPVALID) = '1' and prev_v = '0' then
        n_pub <= n_pub + 1;
        if not first_pub and st(JC_S_RSPSEQ_HI downto JC_S_RSPSEQ_LO) = prev_pub then
          n_dup <= n_dup + 1;
          report "MONITOR: rsp_seq " & to_hstring(prev_pub) & " published twice in a row"
            severity error;
        end if;
        first_pub := false;
        prev_pub  := st(JC_S_RSPSEQ_HI downto JC_S_RSPSEQ_LO);
      end if;
      prev_v := st(JC_S_RSPVALID);
      if st(JC_S_DONE_HI downto JC_S_DONE_LO) /= prev_done then
        if st(JC_S_DONE_HI downto JC_S_DONE_LO) = ackfrm and st(JC_S_RSPVALID) = '1' then
          n_ackord <= n_ackord + 1;
          report "MONITOR: frame " & to_hstring(ackfrm)
                 & " done before its ack cleared rsp_valid" severity error;
        end if;
        prev_done := st(JC_S_DONE_HI downto JC_S_DONE_LO);
      end if;
      if h_rvalid = '1' and h_rready = '1' then
        bad_n <= bad_n + 1;
      end if;
      if h_arvalid = '1' and h_arready = '1' then
        bad_b <= h_araddr = BAD_HBM(32 downto 0);
        bad_n <= 0;
        a  := unsigned(h_araddr);
        nb := to_integer(unsigned(h_arlen)) + 1;
        if n_burst < 256 then
          b_addr(n_burst) <= h_araddr;
          b_len(n_burst)  <= nb;
        end if;
        n_burst <= n_burst + 1;
        if nb > 16 or h_arsize /= "101" or h_arburst /= "01" or a(4 downto 0) /= "00000"
           or to_integer(a(11 downto 0)) + nb * 32 > 4096 then
          n_bviol <= n_bviol + 1;
          report "MONITOR: illegal HBM burst at " & to_hstring(h_araddr) & " beats "
                 & integer'image(nb) severity error;
        end if;
      end if;
    end if;
  end process;

  main : process
    type item_t is array (0 to 495) of std_logic_vector(31 downto 0);
    variable its     : item_t;
    variable checks  : natural := 0;
    variable errors  : natural := 0;
    variable lfsr    : std_logic_vector(31 downto 0) := x"1234ABCD";
    variable gap     : std_logic_vector(15 downto 0) := x"6A5F";
    variable acked_s : std_logic_vector(31 downto 0) := NONE;
    variable stale_p : boolean := false;
    variable late_pending : boolean := false;
    variable lc0     : natural;
    variable rw0     : natural;
    variable nb0     : natural;
    variable st0     : std_logic_vector(383 downto 0);
    variable c       : std_logic_vector(31 downto 0);
    variable w       : std_logic_vector(255 downto 0);
    variable okb     : boolean;

    constant ACK_SAME   : natural := 0;
    constant ACK_BEFORE : natural := 1;
    constant ACK_LATE   : natural := 2;   -- the caller fires it with fire_ack

    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then
        errors := errors + 1;
        report "CHECK FAILED: " & msg severity error;
      end if;
    end procedure;
    procedure tick(n : natural := 1) is
    begin
      for i in 1 to n loop
        wait until rising_edge(clk);
      end loop;
    end procedure;
    impure function rnd32 return std_logic_vector is
    begin
      for i in 0 to 31 loop
        lfsr := lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
      end loop;
      return lfsr;
    end function;
    procedure fill(n : natural) is
    begin
      for i in 0 to n - 1 loop
        its(i) := rnd32;
      end loop;
    end procedure;
    function hdr(seq : std_logic_vector(31 downto 0); op, count, nwords : natural;
                 addr : unsigned(63 downto 0); ackv : std_logic;
                 ackseq : std_logic_vector(31 downto 0)) return std_logic_vector is
      variable h : std_logic_vector(255 downto 0) := (others => '0');
    begin
      h(31 downto 0)    := JC_CTL_MAGIC;
      h(63 downto 32)   := seq;
      h(71 downto 64)   := std_logic_vector(to_unsigned(op, 8));
      h(87 downto 72)   := std_logic_vector(to_unsigned(count, 16));
      h(119 downto 104) := std_logic_vector(to_unsigned(nwords, 16));
      h(183 downto 120) := std_logic_vector(addr);
      h(215 downto 184) := ackseq;
      h(216)            := ackv;
      return h;
    end function;
    impure function dword(j, count : natural) return std_logic_vector is
      variable d : std_logic_vector(255 downto 0) := (others => '0');
    begin
      for k in 0 to 7 loop
        if 8 * j + k < count then
          d(32*k+31 downto 32*k) := its(8 * j + k);
        end if;
      end loop;
      return d;
    end function;
    -- one FIFO word into the bench FIFO (the async FIFO's model: the frame core pushes
    -- whether or not the executor is popping), one word per cycle with random gaps
    procedure push(tag : std_logic_vector(1 downto 0); wd : std_logic_vector(255 downto 0)) is
    begin
      gap := gap(14 downto 0) & (gap(15) xor gap(13) xor gap(12) xor gap(10));
      if gap(0) = '1' and gap(4) = '1' then
        tick(to_integer(unsigned(gap(7 downto 5))) + 1);
      end if;
      assert q_wp < QN report "bench FIFO full" severity failure;
      qmem(q_wp) <= tag & wd;
      q_wp <= q_wp + 1;
      tick;
    end procedure;
    procedure toggle_ack is
    begin
      ack_tgl <= not ack_tgl;
    end procedure;
    procedure fire_ack is
    begin
      chk(late_pending, "fire_ack with no late ack pending");
      late_pending := false;
      toggle_ack;
      tick;
    end procedure;
    -- a whole frame: HDR, nwords DATA words (items from `its`), then PASS or FAIL. The
    -- frame core's ack decision is modelled from the presented status at frame start.
    procedure frame(seq : std_logic_vector(31 downto 0); op, count, nwords : natural;
                    addr : unsigned(63 downto 0); ackv : std_logic := '0';
                    ackseq : std_logic_vector(31 downto 0) := NONE;
                    fail : boolean := false; mode : natural := ACK_SAME) is
      variable sv   : std_logic;
      variable ss   : std_logic_vector(31 downto 0);
      variable doit : boolean;
    begin
      sv := st(JC_S_RSPVALID);
      ss := st(JC_S_RSPSEQ_HI downto JC_S_RSPSEQ_LO);
      if sv = '0' or ss /= acked_s then
        stale_p := false;
      end if;
      doit := not fail and ackv = '1' and ackseq = ss and sv = '1'
              and not (stale_p and ss = acked_s);
      push(TAG_HDR, hdr(seq, op, count, nwords, addr, ackv, ackseq));
      for j in 0 to nwords - 1 loop
        push(TAG_DATA, dword(j, count));
      end loop;
      if doit then
        acked_s := ss;
        stale_p := true;
        if mode = ACK_BEFORE then
          toggle_ack;
          tick(3);
        end if;
      end if;
      if fail then
        push(TAG_FAIL, std_logic_vector(resize(unsigned(seq), 256)));
      else
        if doit and mode = ACK_SAME then
          toggle_ack;                         -- with the PASS word
        end if;
        push(TAG_PASS, std_logic_vector(resize(unsigned(seq), 256)));
      end if;
      if doit and mode = ACK_LATE then
        late_pending := true;
      end if;
    end procedure;
    impure function f_done return std_logic_vector is
    begin
      return st(JC_S_DONE_HI downto JC_S_DONE_LO);
    end function;
    impure function f_rseq return std_logic_vector is
    begin
      return st(JC_S_RSPSEQ_HI downto JC_S_RSPSEQ_LO);
    end function;
    procedure wait_done(seq : std_logic_vector(31 downto 0); what : string) is
      variable n : natural := 0;
    begin
      tick(2);
      while (f_done /= seq or busy = '1' or q_rp /= q_wp) and n < 40000 loop
        tick; n := n + 1;
      end loop;
      chk(f_done = seq and busy = '0', what & ": last_done_seq never reached "
          & to_hstring(seq) & " (shows " & to_hstring(f_done) & ")");
      tick(2);
    end procedure;
    procedure wait_idle is
      variable n : natural := 0;
    begin
      tick(2);
      while (busy = '1' or q_rp /= q_wp) and n < 40000 loop
        tick; n := n + 1;
      end loop;
      tick(20);
    end procedure;
    procedure chk_err(e : std_logic; resp : std_logic_vector(1 downto 0);
                      eseq : std_logic_vector(31 downto 0); what : string) is
    begin
      chk(st(JC_S_AXIERR) = e, what & ": axi_err " & std_logic'image(st(JC_S_AXIERR)));
      chk(st(JC_S_AXIRESP_HI downto JC_S_AXIRESP_LO) = resp,
          what & ": axi_resp " & to_hstring(st(JC_S_AXIRESP_HI downto JC_S_AXIRESP_LO)));
      chk(st(JC_S_ERRSEQ_HI downto JC_S_ERRSEQ_LO) = eseq,
          what & ": err_seq " & to_hstring(st(JC_S_ERRSEQ_HI downto JC_S_ERRSEQ_LO)));
    end procedure;
    procedure chk_log(i, kind : natural; a, d : std_logic_vector(31 downto 0);
                      r : std_logic_vector(1 downto 0); what : string) is
    begin
      log_idx <= i;
      wait for 0 ns; wait for 0 ns;
      chk(log_kind = kind and log_addr = a and log_data = d and log_resp = r,
          what & ": log[" & integer'image(i) & "] kind " & integer'image(log_kind)
          & " addr " & to_hstring(log_addr) & " data " & to_hstring(log_data)
          & " resp " & to_hstring(log_resp) & ", expected kind " & integer'image(kind)
          & " addr " & to_hstring(a) & " data " & to_hstring(d) & " resp " & to_hstring(r));
    end procedure;
    -- the published response: valid, seq, count, the RAM contents (from expected words in
    -- `its`) and rsp_crc against the bench CRC of those words
    procedure chk_rsp(seq : std_logic_vector(31 downto 0); n : natural; what : string) is
      variable cc  : std_logic_vector(31 downto 0) := x"FFFFFFFF";
      variable bad : integer := -1;
    begin
      chk(st(JC_S_RSPVALID) = '1', what & ": rsp_valid not set");
      chk(f_rseq = seq, what & ": rsp_seq " & to_hstring(f_rseq));
      chk(to_integer(unsigned(st(JC_S_RSPCNT_HI downto JC_S_RSPCNT_LO))) = n,
          what & ": rsp_count " & integer'image(to_integer(unsigned(st(JC_S_RSPCNT_HI downto JC_S_RSPCNT_LO)))));
      for i in 0 to n - 1 loop
        if ram(i) /= its(i) and bad < 0 then
          bad := i;
        end if;
        for b in 0 to 3 loop
          cc := crc_byte(cc, its(i)(8*b+7 downto 8*b));
        end loop;
      end loop;
      if bad >= 0 then
        chk(false, what & ": response RAM word " & integer'image(bad) & " = "
            & to_hstring(ram(bad)) & ", expected " & to_hstring(its(bad)));
      else
        chk(true, "");
      end if;
      chk(st(JC_S_RSPCRC_HI downto JC_S_RSPCRC_LO) = (cc xor x"FFFFFFFF"),
          what & ": rsp_crc " & to_hstring(st(JC_S_RSPCRC_HI downto JC_S_RSPCRC_LO))
          & ", bench CRC " & to_hstring(cc xor x"FFFFFFFF"));
    end procedure;
    procedure chk_top(what : string) is
    begin
      chk(unsigned(st(383 downto JC_S_ZERO_LO)) = 0, what & ": st_out[383:213] not zero");
      chk(unsigned(st(JC_S_CRCF_HI downto JC_S_DESYNC_LO)) = 0
          and unsigned(st(JC_S_MAGIC_HI downto 0)) = 0,
          what & ": frame-core-owned fields not zero");
    end procedure;
    -- ack the presented response with a NOP (seq NONE)
    procedure ack_nop(seq : std_logic_vector(31 downto 0); what : string) is
    begin
      frame(NONE, JC_OP_NOP, 1, 0, x"0000000000000000", '1', seq);
      tick(10);
      chk(st(JC_S_RSPVALID) = '0', what & ": rsp_valid still 1 after the ack");
    end procedure;
    procedure seed_hbm(a0 : unsigned(39 downto 0); nbeats : natural) is
      variable a : unsigned(39 downto 0) := a0;
    begin
      for i in 0 to nbeats - 1 loop
        poke_en <= '1'; poke_addr <= std_logic_vector(a); poke_data <= memw(a);
        tick;
        a := a + 32;
      end loop;
      poke_en <= '0';
      tick;
    end procedure;
    procedure expect_hbm(a0 : unsigned(39 downto 0); nbeats : natural) is
      variable a : unsigned(39 downto 0) := a0;
      variable d : std_logic_vector(255 downto 0);
    begin
      for i in 0 to nbeats - 1 loop
        d := memw(a);
        for k in 0 to 7 loop
          its(8 * i + k) := d(32*k+31 downto 32*k);
        end loop;
        a := a + 32;
      end loop;
    end procedure;
    procedure chk_burst(i : natural; a : std_logic_vector(32 downto 0); n : natural;
                        what : string) is
    begin
      chk(b_addr(i) = a and b_len(i) = n, what & ": burst " & integer'image(i) & " at "
          & to_hstring(b_addr(i)) & " x" & integer'image(b_len(i)) & ", expected "
          & to_hstring(a) & " x" & integer'image(n));
    end procedure;
    procedure chk_nothing(lc, rw : natural; what : string) is
    begin
      chk(log_count = lc, what & ": " & integer'image(log_count - lc)
          & " AXI-Lite transactions, expected none");
      chk(n_ramwr = rw, what & ": response RAM written");
    end procedure;
  begin
    -- the bench CRC's own known answer: "123456789" -> 0xCBF43926
    c := x"FFFFFFFF";
    for i in 1 to 9 loop
      c := crc_byte(c, std_logic_vector(to_unsigned(character'pos(character'val(48 + i)), 8)));
    end loop;
    chk((c xor x"FFFFFFFF") = x"CBF43926", "bench CRC known answer");

    seed_hbm(x"0180000F80", 8);       -- (e) 64 items across 0x1_8000_1000
    seed_hbm(x"0180001F40", 62);      -- (e) 496 items: 6 + 16 + 16 + 16 + 8 beats
    seed_hbm(x"0180003000", 2);       -- (e) RRESP error region
    seed_hbm(x"01FFFFFFE0", 1);       -- the last 32 bytes below 2^33 (R4 boundary)
    tick(5);
    rst <= '0';
    tick(5);
    chk(f_done = NONE and f_rseq = NONE and st(JC_S_RSPVALID) = '0' and st(JC_S_AXIERR) = '0',
        "reset status: last_done/rsp_seq none, rsp_valid 0, axi_err 0");
    chk(st(JC_S_ERRSEQ_HI downto JC_S_ERRSEQ_LO) = NONE, "reset err_seq none");
    chk_top("reset");

    ------------------------------------------------------------------ (a)
    fill(5);
    lc0 := log_count;
    frame(s32(10), JC_OP_WR_INC, 5, 1, x"0000000000000100");
    wait_done(s32(10), "(a) WR_INC 5");
    chk(log_count = lc0 + 5, "(a) 5 writes logged, got " & integer'image(log_count - lc0));
    for i in 0 to 4 loop
      chk_log(lc0 + i, 0, s32(16#100# + 4 * i), its(i), "00", "(a) write");
    end loop;
    chk_err('0', "00", NONE, "(a) after the write");
    chk(st(JC_S_RSPVALID) = '0', "(a) a write publishes no response");
    frame(s32(11), JC_OP_RD_INC, 5, 0, x"0000000000000100");
    wait_done(s32(11), "(a) RD_INC 5");
    chk(log_count = lc0 + 10, "(a) 5 reads logged");
    for i in 0 to 4 loop
      chk_log(lc0 + 5 + i, 1, s32(16#100# + 4 * i), its(i), "00", "(a) read");
    end loop;
    chk_rsp(s32(11), 5, "(a) RD_INC response");
    chk_top("(a)");
    -- (c) ruling: a NOP with the ack clears rsp_valid and changes nothing else
    st0 := st;
    ack_nop(s32(11), "(a) ack");
    st0(JC_S_RSPVALID) := '0';
    chk(st = st0, "(a) the ack NOP changed a field other than rsp_valid");

    ------------------------------------------------------------------ (b)
    fill(300);
    lc0 := log_count;
    frame(s32(12), JC_OP_WR_FIX, 300, 38, x"0000000000000200");
    wait_done(s32(12), "(b) WR_FIX 300");
    chk(log_count = lc0 + 300, "(b) 300 writes logged, got " & integer'image(log_count - lc0));
    for i in 0 to 299 loop
      chk_log(lc0 + i, 0, x"00000200", its(i), "00", "(b) WR_FIX");
    end loop;
    reg_addr <= x"00000200"; tick;
    chk(reg_data = its(299), "(b) register 0x200 holds the last item");
    -- the largest frame: 496 items in 62 payload words, then read back
    fill(496);
    lc0 := log_count;
    frame(s32(13), JC_OP_WR_INC, 496, 62, x"0000000000001000");
    wait_done(s32(13), "(b) WR_INC 496");
    chk(log_count = lc0 + 496, "(b) 496 writes logged");
    okb := true;
    for i in 0 to 495 loop
      log_idx <= lc0 + i; wait for 0 ns; wait for 0 ns;
      if log_kind /= 0 or log_addr /= s32(16#1000# + 4 * i) or log_data /= its(i) then
        okb := false;
      end if;
    end loop;
    chk(okb, "(b) the 496 writes are in order at 0x1000 + 4i with the items");
    frame(s32(14), JC_OP_RD_INC, 496, 0, x"0000000000001000");
    wait_done(s32(14), "(b) RD_INC 496");
    chk_rsp(s32(14), 496, "(b) RD_INC 496 response");
    ack_nop(s32(14), "(b) ack");

    ------------------------------------------------------------------ (c)
    fill(3);
    lc0 := log_count; rw0 := n_ramwr; st0 := st;
    frame(s32(15), JC_OP_WR_INC, 3, 1, x"0000000000000300", fail => true);
    frame(s32(15), JC_OP_RD_INC, 3, 0, x"0000000000000300", fail => true);
    frame(s32(15), JC_OP_MEM_RD, 8, 0, x"0000000180000F80", fail => true);
    wait_idle;
    chk_nothing(lc0, rw0, "(c) FAIL frames");
    chk(st = st0, "(c) FAIL frames changed the status");
    reg_addr <= x"00000300"; tick;
    chk(reg_data = x"00000000", "(c) the FAIL frame's write landed");

    ------------------------------------------------------------------ (d)
    fill(4);
    lc0 := log_count;
    frame(s32(16), JC_OP_WR_INC, 4, 1, x"000000000000EFF8");
    wait_done(s32(16), "(d) WR_INC into SLVERR");
    chk(log_count = lc0 + 3, "(d) the op stops at the error: "
        & integer'image(log_count - lc0) & " writes, expected 3");
    chk_log(lc0, 0, x"0000EFF8", its(0), "00", "(d)");
    chk_log(lc0 + 1, 0, x"0000EFFC", its(1), "00", "(d)");
    chk_log(lc0 + 2, 0, x"0000F000", its(2), "10", "(d)");
    chk_err('1', "10", s32(16), "(d) SLVERR");
    -- fix round 1, I3: a mid-frame error leaves the earlier items written (no rollback)
    reg_addr <= x"0000EFF8"; tick;
    chk(reg_data = its(0), "(d) item 0 before the error not written");
    reg_addr <= x"0000EFFC"; tick;
    chk(reg_data = its(1), "(d) item 1 before the error not written");
    -- ruling (c): NOPs (with and without an ack of nothing) change no status field
    st0 := st;
    frame(NONE, JC_OP_NOP, 1, 0, x"0000000000000000");
    frame(NONE, JC_OP_NOP, 1, 0, x"0000000000000000", '1', s32(14));
    wait_idle;
    chk(st = st0, "(d) a NOP changed the status (axi_err must stay sticky)");
    fill(2);
    lc0 := log_count;
    frame(s32(17), JC_OP_WR_INC, 2, 1, x"0000000000000400");
    wait_done(s32(17), "(d) a later write");
    chk(log_count = lc0 + 2, "(d) later ops still run");
    chk_err('0', "00", NONE, "(d) the next non-NOP frame clears axi_err");
    -- a read whose second item is DECERR: stops, no response published
    lc0 := log_count;
    reg_addr <= x"0000FFFC"; tick;
    its(0) := reg_data;
    frame(s32(18), JC_OP_RD_INC, 3, 0, x"000000000000FFFC");
    wait_done(s32(18), "(d) RD_INC into DECERR");
    chk(log_count = lc0 + 2, "(d) read stops at the error");
    chk_log(lc0 + 1, 1, x"00010000", x"00000000", "11", "(d) DECERR read");
    chk_err('1', "11", s32(18), "(d) DECERR");
    chk(st(JC_S_RSPVALID) = '0', "(d) an errored read publishes no response");
    -- a read error (SLVERR) on the first item
    frame(s32(19), JC_OP_RD_FIX, 2, 0, x"000000000000F000");
    wait_done(s32(19), "(d) RD_FIX at SLVERR");
    chk_err('1', "10", s32(19), "(d) read SLVERR");
    chk(st(JC_S_RSPVALID) = '0', "(d) no response after a read SLVERR");
    fill(1);
    frame(s32(23), JC_OP_WR_FIX, 1, 1, x"0000000000000404");
    wait_done(s32(23), "(d) clear");
    chk_err('0', "00", NONE, "(d) cleared again");
    -- fix round 1 (R22): a write answered DECERR is an error, axi_resp "11"
    fill(2);
    lc0 := log_count;
    frame(s32(101), JC_OP_WR_FIX, 1, 1, x"0000000000010000");
    wait_done(s32(101), "(d) write DECERR");
    chk(log_count = lc0 + 1, "(d) write DECERR: one transaction");
    chk_log(lc0, 0, x"00010000", its(0), "11", "(d) write DECERR");
    chk_err('1', "11", s32(101), "(d) write DECERR");
    -- (R25) FIX ops are not wrap-checked: 2 items at 0xFFFFFFFC are legal and run (the slave
    -- answers DECERR, so each stops after one transaction with "11", not a "10" rejection)
    lc0 := log_count;
    frame(s32(102), JC_OP_WR_FIX, 2, 1, x"00000000FFFFFFFC");
    wait_done(s32(102), "(d) WR_FIX at the top");
    chk(log_count = lc0 + 1, "(d) WR_FIX at the top ran");
    chk_log(lc0, 0, x"FFFFFFFC", its(0), "11", "(d) WR_FIX at the top");
    chk_err('1', "11", s32(102), "(d) WR_FIX at the top");
    lc0 := log_count;
    frame(s32(103), JC_OP_RD_FIX, 2, 0, x"00000000FFFFFFFC");
    wait_done(s32(103), "(d) RD_FIX at the top");
    chk(log_count = lc0 + 1, "(d) RD_FIX at the top ran");
    chk_log(lc0, 1, x"FFFFFFFC", x"00000000", "11", "(d) RD_FIX at the top");
    chk_err('1', "11", s32(103), "(d) RD_FIX at the top");
    -- (R3) the INC bound is inclusive: addr + 4*count = 2^32 runs, one item more is rejected
    lc0 := log_count;
    frame(s32(104), JC_OP_WR_INC, 1, 1, x"00000000FFFFFFFC");
    wait_done(s32(104), "(d) WR_INC ending at 2^32");
    chk(log_count = lc0 + 1, "(d) WR_INC ending exactly at 2^32 ran");
    chk_err('1', "11", s32(104), "(d) WR_INC ending at 2^32 (DECERR, not rejected)");
    lc0 := log_count;
    frame(s32(105), JC_OP_WR_INC, 2, 1, x"00000000FFFFFFFC");
    wait_done(s32(105), "(d) WR_INC past 2^32");
    chk(log_count = lc0, "(d) WR_INC past 2^32 ran");
    chk_err('1', "10", s32(105), "(d) WR_INC past 2^32 rejected");
    -- (I2, R24) FIX ops above 32 bits: rejected (the wrap check cannot catch these)
    lc0 := log_count; rw0 := n_ramwr;
    frame(s32(106), JC_OP_WR_FIX, 1, 1, x"0000000100000200");
    wait_done(s32(106), "(d) WR_FIX above 32 bits");
    chk_err('1', "10", s32(106), "(d) WR_FIX above 32 bits");
    frame(s32(107), JC_OP_RD_FIX, 1, 0, x"0000000100000200");
    wait_done(s32(107), "(d) RD_FIX above 32 bits");
    chk_err('1', "10", s32(107), "(d) RD_FIX above 32 bits");
    chk_nothing(lc0, rw0, "(d) FIX ops above 32 bits");
    reg_addr <= x"00000200"; tick;
    chk(reg_data /= its(0), "(d) WR_FIX above 32 bits landed at 0x200");
    -- fix round 1, item 5: a write with seq 0xFFFFFFFF is rejected "01" and last_done_seq
    -- does not become "none"
    lc0 := log_count;
    frame(NONE, JC_OP_WR_INC, 1, 1, x"0000000000000404");
    wait_idle;
    chk(log_count = lc0, "(d) a write with seq none ran");
    chk_err('1', "01", NONE, "(d) a write with seq none");
    chk(f_done = s32(107), "(d) last_done_seq changed by a seq-none frame");
    frame(s32(100), JC_OP_WR_FIX, 1, 1, x"0000000000000404");
    wait_done(s32(100), "(d) clear again");
    chk_err('0', "00", NONE, "(d) cleared");

    ------------------------------------------------------------------ (e)
    nb0 := n_burst; lc0 := log_count;
    frame(s32(20), JC_OP_MEM_RD, 64, 0, x"0000000180000F80");
    wait_done(s32(20), "(e) MEM_RD 64 across 4 KB");
    chk(n_burst = nb0 + 2, "(e) 2 bursts, got " & integer'image(n_burst - nb0));
    chk_burst(nb0, '1' & x"80000F80", 4, "(e)");
    chk_burst(nb0 + 1, '1' & x"80001000", 4, "(e)");
    expect_hbm(x"0180000F80", 8);
    chk_rsp(s32(20), 64, "(e) MEM_RD 64");
    chk(log_count = lc0, "(e) MEM_RD touched AXI-Lite");
    ack_nop(s32(20), "(e) ack");
    nb0 := n_burst;
    frame(s32(21), JC_OP_MEM_RD, 496, 0, x"0000000180001F40");
    wait_done(s32(21), "(e) MEM_RD 496");
    chk(n_burst = nb0 + 5, "(e) 5 bursts, got " & integer'image(n_burst - nb0));
    chk_burst(nb0,     '1' & x"80001F40", 6, "(e)");
    chk_burst(nb0 + 1, '1' & x"80002000", 16, "(e)");
    chk_burst(nb0 + 2, '1' & x"80002200", 16, "(e)");
    chk_burst(nb0 + 3, '1' & x"80002400", 16, "(e)");
    chk_burst(nb0 + 4, '1' & x"80002600", 8, "(e)");
    expect_hbm(x"0180001F40", 62);
    chk_rsp(s32(21), 496, "(e) MEM_RD 496");
    chk(h_arlen(7 downto 4) = "0000", "(e) ARLEN upper bits");
    ack_nop(s32(21), "(e) ack");
    frame(s32(22), JC_OP_MEM_RD, 16, 0, x"0000000180003000");
    wait_done(s32(22), "(e) MEM_RD RRESP error");
    chk_err('1', "10", s32(22), "(e) RRESP SLVERR");
    chk(st(JC_S_RSPVALID) = '0', "(e) no response after an HBM read error");
    -- fix round 1 (I1, R20): the error burst was drained, so the next MEM_RD gets its own data
    nb0 := n_burst;
    frame(s32(24), JC_OP_MEM_RD, 64, 0, x"0000000180000F80");
    wait_done(s32(24), "(e) MEM_RD after the error");
    chk_err('0', "00", NONE, "(e) MEM_RD after the error");
    chk(n_burst = nb0 + 2, "(e) MEM_RD after the error: 2 bursts");
    expect_hbm(x"0180000F80", 8);
    chk_rsp(s32(24), 64, "(e) MEM_RD after the error");
    ack_nop(s32(24), "(e) ack");
    -- (R4) the MEM_RD bound is inclusive: the last 32 bytes below 2^33 are readable
    nb0 := n_burst;
    frame(s32(25), JC_OP_MEM_RD, 8, 0, x"00000001FFFFFFE0");
    wait_done(s32(25), "(e) MEM_RD ending at 2^33");
    chk_err('0', "00", NONE, "(e) MEM_RD ending exactly at 2^33 accepted");
    chk(n_burst = nb0 + 1, "(e) MEM_RD ending at 2^33: 1 burst");
    chk_burst(nb0, '1' & x"FFFFFFE0", 1, "(e) MEM_RD ending at 2^33");
    expect_hbm(x"01FFFFFFE0", 1);
    chk_rsp(s32(25), 8, "(e) MEM_RD ending at 2^33");
    ack_nop(s32(25), "(e) ack");

    ------------------------------------------------------------------ (f)
    lc0 := log_count;
    frame(s32(30), JC_OP_RD_FIX, 4, 0, x"000000000000F100");
    wait_done(s32(30), "(f) read A");
    for i in 0 to 3 loop its(i) := s32(i + 1); end loop;
    chk_rsp(s32(30), 4, "(f) read A");
    chk_err('0', "00", NONE, "(f) read A clears axi_err");
    lc0 := log_count; rw0 := n_ramwr;
    frame(s32(31), JC_OP_RD_FIX, 3, 0, x"000000000000F100");     -- read B, A not acked
    tick(400);
    chk_nothing(lc0, rw0, "(f) read B before A's ack");
    chk(busy = '1', "(f) read B is held");
    chk(f_done = s32(30), "(f) last_done moved while B waits");
    for i in 0 to 3 loop its(i) := s32(i + 1); end loop;
    chk_rsp(s32(30), 4, "(f) A still presented while B waits");
    ack_nop(s32(30), "(f) ack A");
    wait_done(s32(31), "(f) read B after the ack");
    for i in 0 to 2 loop its(i) := s32(i + 5); end loop;
    chk_rsp(s32(31), 3, "(f) read B");
    chk(log_count = lc0 + 3, "(f) B read 3 times");

    ------------------------------------------------- ruling (b): ack in the same frame
    -- read C carries the ack of B, and the toggle arrives 300 cycles after C's PASS
    lc0 := log_count; rw0 := n_ramwr;
    frame(s32(32), JC_OP_RD_FIX, 2, 0, x"000000000000F100", '1', s32(31), mode => ACK_LATE);
    tick(300);
    chk_nothing(lc0, rw0, "(b-ruling) read C before its own frame's ack arrived");
    chk(f_done = s32(31) and st(JC_S_RSPVALID) = '1', "(b-ruling) B still presented");
    fire_ack;
    wait_done(s32(32), "(b-ruling) read C");
    its(0) := s32(8); its(1) := s32(9);
    chk_rsp(s32(32), 2, "(b-ruling) read C");
    -- read D carries C's ack, toggle BEFORE its PASS word
    fill(2);
    reg_addr <= x"00000100"; tick; its(0) := reg_data;
    reg_addr <= x"00000104"; tick; its(1) := reg_data;
    frame(s32(33), JC_OP_RD_INC, 2, 0, x"0000000000000100", '1', s32(32), mode => ACK_BEFORE);
    wait_done(s32(33), "(b-ruling) read D");
    chk_rsp(s32(33), 2, "(b-ruling) read D");
    -- read E carries D's ack with the PASS word
    frame(s32(34), JC_OP_RD_INC, 2, 0, x"0000000000000100", '1', s32(33));
    wait_done(s32(34), "(b-ruling) read E");
    chk_rsp(s32(34), 2, "(b-ruling) read E");
    -- a write carrying E's ack, toggle late: the write waits for the ack
    fill(1);
    ackfrm <= s32(35);
    lc0 := log_count;
    frame(s32(35), JC_OP_WR_INC, 1, 1, x"0000000000000500", '1', s32(34), mode => ACK_LATE);
    tick(300);
    chk(log_count = lc0, "(b-ruling) write ran before its frame's ack was applied");
    chk(f_done = s32(34), "(b-ruling) write done before its frame's ack");
    fire_ack;
    wait_done(s32(35), "(b-ruling) write after the ack");
    chk(log_count = lc0 + 1, "(b-ruling) the write ran once");
    chk(st(JC_S_RSPVALID) = '0', "(b-ruling) ack applied");
    ackfrm <= NONE;
    -- a write carrying an ack of a seq that is not presented does not wait
    lc0 := log_count;
    frame(s32(36), JC_OP_WR_INC, 1, 1, x"0000000000000504", '1', s32(34));
    wait_done(s32(36), "(b-ruling) write with a stale ack");
    chk(log_count = lc0 + 1, "(b-ruling) stale-ack write ran");

    ------------------------------------------------- ruling (e): header validation
    lc0 := log_count; rw0 := n_ramwr; nb0 := n_burst;
    frame(s32(50), 6, 1, 0, x"0000000000000100");
    wait_done(s32(50), "(e-ruling) op 6");
    chk_err('1', "10", s32(50), "(e-ruling) op 6");
    frame(s32(51), 255, 1, 0, x"0000000000000100");
    wait_done(s32(51), "(e-ruling) op 255");
    chk_err('1', "10", s32(51), "(e-ruling) op 255");
    frame(s32(52), JC_OP_WR_INC, 0, 0, x"0000000000000100");
    wait_done(s32(52), "(e-ruling) WR count 0");
    chk_err('1', "10", s32(52), "(e-ruling) WR count 0");
    fill(16);
    frame(s32(53), JC_OP_WR_INC, 9, 1, x"0000000000000100");
    wait_done(s32(53), "(e-ruling) WR count 9 nwords 1");
    chk_err('1', "10", s32(53), "(e-ruling) WR count 9 nwords 1");
    frame(s32(54), JC_OP_WR_FIX, 8, 2, x"0000000000000100");
    wait_done(s32(54), "(e-ruling) WR count 8 nwords 2");
    chk_err('1', "10", s32(54), "(e-ruling) WR count 8 nwords 2");
    frame(s32(55), JC_OP_RD_INC, 4, 1, x"0000000000000100");
    wait_done(s32(55), "(e-ruling) RD nwords 1");
    chk_err('1', "10", s32(55), "(e-ruling) RD nwords 1");
    frame(s32(56), JC_OP_MEM_RD, 8, 0, x"0000000180000F90");
    wait_done(s32(56), "(e-ruling) MEM_RD misaligned");
    chk_err('1', "10", s32(56), "(e-ruling) MEM_RD misaligned");
    frame(s32(57), JC_OP_MEM_RD, 12, 0, x"0000000180000F80");
    wait_done(s32(57), "(e-ruling) MEM_RD count 12");
    chk_err('1', "10", s32(57), "(e-ruling) MEM_RD count 12");
    frame(s32(58), JC_OP_RD_INC, 0, 0, x"0000000000000100");
    wait_done(s32(58), "(e-ruling) RD count 0");
    chk_err('1', "10", s32(58), "(e-ruling) RD count 0");
    frame(s32(59), JC_OP_MEM_RD, 0, 0, x"0000000180000F80");
    wait_done(s32(59), "(e-ruling) MEM_RD count 0");
    chk_err('1', "10", s32(59), "(e-ruling) MEM_RD count 0");
    frame(s32(60), JC_OP_WR_INC, 1, 1, x"0000000100000100");
    wait_done(s32(60), "(e-ruling) AXI-Lite addr above 32 bits");
    chk_err('1', "10", s32(60), "(e-ruling) AXI-Lite addr above 32 bits");
    frame(s32(61), JC_OP_WR_INC, 1, 1, x"0000000000000102");
    wait_done(s32(61), "(e-ruling) AXI-Lite addr unaligned");
    chk_err('1', "10", s32(61), "(e-ruling) AXI-Lite addr unaligned");
    frame(s32(62), JC_OP_MEM_RD, 8, 0, x"0000000200000000");
    wait_done(s32(62), "(e-ruling) MEM_RD above ADDR_W");
    chk_err('1', "10", s32(62), "(e-ruling) MEM_RD above ADDR_W");
    frame(s32(63), JC_OP_RD_INC, 2, 0, x"00000000FFFFFFFC");
    wait_done(s32(63), "(e-ruling) RD_INC wraps 32 bits");
    chk_err('1', "10", s32(63), "(e-ruling) RD_INC wraps 32 bits");
    frame(s32(66), JC_OP_MEM_RD, 16, 0, x"00000001FFFFFFE0");
    wait_done(s32(66), "(e-ruling) MEM_RD past the top of HBM");
    chk_err('1', "10", s32(66), "(e-ruling) MEM_RD past the top of HBM");
    chk_nothing(lc0, rw0, "(e-ruling) invalid headers");
    chk(n_burst = nb0, "(e-ruling) an invalid MEM_RD issued a burst");
    -- the same rsp_seq never twice in a row: a read reusing the presented/acked seq is
    -- rejected with axi_resp "01"
    frame(s32(64), JC_OP_WR_INC, 1, 1, x"0000000000000508", '1', s32(34));
    wait_done(s32(64), "(e-ruling) clear");
    chk_err('0', "00", NONE, "(e-ruling) clear");
    reg_addr <= x"00000100"; tick; its(0) := reg_data;
    frame(s32(65), JC_OP_RD_INC, 1, 0, x"0000000000000100");
    wait_done(s32(65), "(a-ruling) read 65");
    chk_rsp(s32(65), 1, "(a-ruling) read 65");
    -- fix round 1 (R18): a write acking a seq other than the presented one does not wait
    lc0 := log_count;
    fill(1);
    frame(s32(108), JC_OP_WR_INC, 1, 1, x"000000000000050C", '1', s32(64));
    wait_done(s32(108), "(b-ruling) write acking another seq");
    chk(log_count = lc0 + 1, "(b-ruling) write acking another seq ran");
    chk(st(JC_S_RSPVALID) = '1' and f_rseq = s32(65),
        "(b-ruling) response 65 no longer presented after a write acking another seq");
    reg_addr <= x"00000100"; tick; its(0) := reg_data;
    ack_nop(s32(65), "(a-ruling) ack 65");
    lc0 := log_count; rw0 := n_ramwr;
    frame(s32(65), JC_OP_RD_INC, 1, 0, x"0000000000000100");
    wait_done(s32(65), "(a-ruling) read 65 again");
    tick(20);
    chk_err('1', "01", s32(65), "(a-ruling) repeated rsp_seq rejected");
    chk(st(JC_S_RSPVALID) = '0', "(a-ruling) repeated rsp_seq published");
    frame(NONE, JC_OP_RD_INC, 1, 0, x"0000000000000100");
    wait_idle;
    chk_err('1', "01", NONE, "(a-ruling) read with seq none rejected");
    chk(f_done = s32(65), "(a-ruling) last_done_seq changed by a seq-none read");
    chk(st(JC_S_RSPVALID) = '0', "(a-ruling) seq none published");
    chk_nothing(lc0, rw0, "(a-ruling) rejected reads");

    ------------------------------------------------- ruling (f): cut and damaged frames
    fill(8);
    lc0 := log_count; rw0 := n_ramwr;
    -- a header and one data word, then a new header: the first frame is discarded
    push(TAG_HDR, hdr(s32(70), JC_OP_WR_INC, 3, 1, x"0000000000000600", '0', NONE));
    push(TAG_DATA, dword(0, 3));
    frame(s32(71), JC_OP_WR_INC, 2, 1, x"0000000000000700");
    wait_done(s32(71), "(f-ruling) frame after a cut one");
    chk(log_count = lc0 + 2, "(f-ruling) only the complete frame ran: "
        & integer'image(log_count - lc0) & " writes");
    chk_log(lc0, 0, x"00000700", its(0), "00", "(f-ruling)");
    chk_log(lc0 + 1, 0, x"00000704", its(1), "00", "(f-ruling)");
    reg_addr <= x"00000600"; tick;
    chk(reg_data = x"00000000", "(f-ruling) the cut frame's write landed");
    -- a header with no data words before the next header (a read, cut after HDR)
    lc0 := log_count;
    st0 := st;
    push(TAG_HDR, hdr(s32(72), JC_OP_RD_FIX, 1, 0, x"000000000000F100", '0', NONE));
    -- short payload: nwords 2, one DATA word, PASS
    push(TAG_HDR, hdr(s32(73), JC_OP_WR_INC, 16, 2, x"0000000000000800", '0', NONE));
    push(TAG_DATA, dword(0, 16));
    push(TAG_PASS, std_logic_vector(resize(unsigned(s32(73)), 256)));
    -- PASS carrying another frame's seq
    push(TAG_HDR, hdr(s32(74), JC_OP_WR_INC, 1, 1, x"0000000000000800", '0', NONE));
    push(TAG_DATA, dword(0, 1));
    push(TAG_PASS, std_logic_vector(resize(unsigned(s32(99)), 256)));
    -- orphan DATA and PASS with no header
    push(TAG_DATA, dword(0, 1));
    push(TAG_PASS, std_logic_vector(resize(unsigned(s32(74)), 256)));
    -- an extra DATA word (nwords 1, two received)
    push(TAG_HDR, hdr(s32(75), JC_OP_WR_INC, 8, 1, x"0000000000000800", '0', NONE));
    push(TAG_DATA, dword(0, 8));
    push(TAG_DATA, dword(0, 8));
    push(TAG_PASS, std_logic_vector(resize(unsigned(s32(75)), 256)));
    -- fix round 1 (R21): 65 DATA words for nwords 1 (a count that wraps 6 bits back to 1)
    push(TAG_HDR, hdr(s32(109), JC_OP_WR_INC, 1, 1, x"0000000000000800", '0', NONE));
    for j in 0 to 64 loop
      push(TAG_DATA, dword(0, 8));
    end loop;
    push(TAG_PASS, std_logic_vector(resize(unsigned(s32(109)), 256)));
    -- a header with a read, then a FAIL of another seq: still nothing
    push(TAG_HDR, hdr(s32(76), JC_OP_RD_FIX, 1, 0, x"000000000000F100", '0', NONE));
    push(TAG_FAIL, std_logic_vector(resize(unsigned(s32(76)), 256)));
    wait_idle;
    chk_nothing(lc0, rw0, "(f-ruling) cut and damaged frames");
    chk(f_done = s32(71), "(f-ruling) last_done moved on a discarded frame");
    chk(st = st0, "(f-ruling) a cut, damaged, orphan or FAIL frame changed the status");
    -- a cut frame (HDR, no verdict) left open while idle: no status change, no execution
    lc0 := log_count; rw0 := n_ramwr; st0 := st;
    push(TAG_HDR, hdr(s32(78), JC_OP_RD_FIX, 1, 0, x"000000000000F100", '0', NONE));
    wait_idle;
    tick(200);
    chk_nothing(lc0, rw0, "(f-ruling) an open cut header");
    chk(st = st0, "(f-ruling) an open cut header changed the status");
    -- alive afterwards
    frame(s32(77), JC_OP_RD_FIX, 1, 0, x"000000000000F100");
    wait_done(s32(77), "(f-ruling) alive");
    its(0) := s32(10);
    chk_rsp(s32(77), 1, "(f-ruling) the counter was read exactly 9 times before");
    ack_nop(s32(77), "(f-ruling) ack");

    ------------------------------------------------- fix round 1, item 6: timeouts
    -- AXI-Lite B never arrives: the frame ends after TMO cycles with axi_err = 1 and
    -- axi_resp = "00" (the timeout code), busy clears; AXI-Lite ops are refused the same way
    -- until the late B has been drained
    fill(1);
    mute_b <= '1';
    lc0 := log_count;
    frame(s32(110), JC_OP_WR_FIX, 1, 1, x"0000000000000900");
    wait_done(s32(110), "(tmo) B never arrives");
    chk_err('1', "00", s32(110), "(tmo) B timeout");
    chk(log_count = lc0 + 1, "(tmo) the timed-out write reached the slave");
    frame(s32(111), JC_OP_WR_FIX, 1, 1, x"0000000000000904");
    wait_done(s32(111), "(tmo) write while B is owed");
    chk_err('1', "00", s32(111), "(tmo) write refused while B is owed");
    chk(log_count = lc0 + 1, "(tmo) a write was issued while B is owed");
    mute_b <= '0';
    tick(50);
    lc0 := log_count;
    frame(s32(112), JC_OP_WR_FIX, 1, 1, x"0000000000000904");
    wait_done(s32(112), "(tmo) write after the late B");
    chk_err('0', "00", NONE, "(tmo) write after the late B");
    chk(log_count = lc0 + 1, "(tmo) write after the late B: one transaction");
    chk_log(lc0, 0, x"00000904", its(0), "00", "(tmo) write after the late B");
    -- AXI-Lite R never arrives (the counter register: 11 is owed, the next read must see 12)
    mute_r <= '1';
    lc0 := log_count; rw0 := n_ramwr;
    frame(s32(113), JC_OP_RD_FIX, 1, 0, x"000000000000F100");
    wait_done(s32(113), "(tmo) R never arrives");
    chk_err('1', "00", s32(113), "(tmo) R timeout");
    chk(st(JC_S_RSPVALID) = '0' and f_rseq = s32(77), "(tmo) a timed-out read published");
    frame(s32(114), JC_OP_RD_FIX, 1, 0, x"000000000000F100");
    wait_done(s32(114), "(tmo) read while R is owed");
    chk_err('1', "00", s32(114), "(tmo) read refused while R is owed");
    chk_nothing(lc0 + 1, rw0, "(tmo) reads while R is owed");
    mute_r <= '0';
    tick(50);
    frame(s32(115), JC_OP_RD_FIX, 1, 0, x"000000000000F100");
    wait_done(s32(115), "(tmo) read after the late R");
    its(0) := s32(12);
    chk_rsp(s32(115), 1, "(tmo) read after the late R gets its own data, not the late R");
    ack_nop(s32(115), "(tmo) ack");
    -- HBM R beats never arrive: the 2 owed beats are drained when they come, never taken by
    -- the next MEM_RD (which reads a different address, so stale data would show)
    hmute <= '1';
    nb0 := n_burst; rw0 := n_ramwr;
    frame(s32(116), JC_OP_MEM_RD, 16, 0, x"0000000180001F40");
    wait_done(s32(116), "(tmo) HBM beats never arrive");
    chk_err('1', "00", s32(116), "(tmo) HBM R timeout");
    chk(n_burst = nb0 + 1, "(tmo) HBM burst issued");
    frame(s32(117), JC_OP_MEM_RD, 8, 0, x"0000000180000F80");
    wait_done(s32(117), "(tmo) MEM_RD while beats are owed");
    chk_err('1', "00", s32(117), "(tmo) MEM_RD refused while beats are owed");
    chk(n_burst = nb0 + 1, "(tmo) a burst was issued while beats are owed");
    chk(n_ramwr = rw0, "(tmo) response RAM written by a timed-out MEM_RD");
    hmute <= '0';
    tick(50);
    frame(s32(118), JC_OP_MEM_RD, 64, 0, x"0000000180000F80");
    wait_done(s32(118), "(tmo) MEM_RD after the late beats");
    chk_err('0', "00", NONE, "(tmo) MEM_RD after the late beats");
    expect_hbm(x"0180000F80", 8);
    chk_rsp(s32(118), 64, "(tmo) MEM_RD after the late beats gets its own data");
    ack_nop(s32(118), "(tmo) ack");

    ------------------------------------------------- global monitors
    tick(50);
    chk(n_ovw = 0, "response RAM written while presented: " & integer'image(n_ovw));
    chk(n_dup = 0, "rsp_seq republished: " & integer'image(n_dup));
    chk(n_ackord = 0, "ack applied after the op: " & integer'image(n_ackord));
    chk(n_bviol = 0, "illegal HBM bursts: " & integer'image(n_bviol));
    chk(hbm_err = 0, "jc_axi3_mem rule violations: " & integer'image(hbm_err));
    chk(axil_err = 0, "AXI-Lite protocol violations: " & integer'image(axil_err));
    chk(l_awprot = "000" and l_arprot = "000", "AxPROT");
    chk(n_pub = 15, "publications: " & integer'image(n_pub));
    chk_top("end");

    assert checks > 500 report "too few checks: " & integer'image(checks) severity failure;
    running <= false;
    if errors = 0 then
      report "PASS: tb_jc_ctl_exec checks=" & integer'image(checks)
             & " pubs=" & integer'image(n_pub) & " bursts=" & integer'image(n_burst);
    else
      report "FAIL: tb_jc_ctl_exec errors=" & integer'image(errors)
             & " checks=" & integer'image(checks) severity failure;
    end if;
    wait;
  end process;
end architecture;
