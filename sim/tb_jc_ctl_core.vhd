-- End-to-end bench for rtl/jc_ctl_core.vhd (Jungle Cat USER3 control core, plan Task 4).
--
-- Everything between TDI/TDO and the AXI ports is the REAL composition: jc_ctl_frame_core,
-- async_fifo (258 x 128), jc_ctl_exec, jc_status_sync, the rsp_ack_tgl 2-FF synchroniser
-- and the dual-clock response RAM. TCK is 27 MHz (37 ns) and runs ONLY while the host walks
-- the TAP (BSCAN timing: Idle->Select, Select->Capture, the Capture-DR edge, one edge per
-- shifted bit, Exit1->Update, Update->Idle), with the clock stopped for GAP between scans.
-- aclk is 200 MHz and free-running. The AXI-Lite side is sim/axil_slave_model.vhd (an
-- independent recorder); the HBM side is sim/jc_axi3_mem.vhd's read side, seeded by poke.
--
-- Frames are built here (bench builder, bench bytewise CRC-32 known-answer checked against
-- "123456789" = 0xCBF43926). First, every slot in sim/jc_ctl_core_vec.txt (written by
-- sim/gen_jc_ctl_core_vec.py from the HOST library tools/jc/jc_ctl.py) is rebuilt by the
-- bench builder and must match bit for bit.
--
-- On EVERY slot's TDO: status magic; st_crc [383:352] = CRC-32 of TDO bits 0..351 as
-- received; [351:213] zero; desync / crc-fail / ovf as expected; rsp_count = 0 when
-- rsp_valid = 0; every bit after the response region zero; when rsp_valid = 1, rsp_crc
-- [212:181] = CRC-32 of the response words as received (a mismatch is allowed only in the
-- slot that carried the ack, and is then counted as a DETECTED tear); last_done_seq never
-- goes back; a seq the host has acked is never presented valid again.
--
-- Cases:
--   A  (brief) WR_INC 496 at 0x1000, then RD_INC 496 read back: the slave log holds the 496
--      writes then the 496 reads in order, and TDO carries the 496 words with rsp_crc and
--      st_crc checked. Acked by a NOP.
--   B  (brief) a WR_INC with one payload bit flipped: FAIL, crc-fail count +1 on TDO, no
--      transaction; the SAME frame (same seq) resent intact executes exactly once.
--   C1 ack carried on the next read's frame (RD_FIX of the slave's read counter acks the
--      previous RD_INC): the counter is read exactly once per item (1, 2, 3).
--   C2 ack crossing long BEFORE its frame's PASS word is consumed: the executor is held in a
--      write (mute_b holds the B response); the next read carries the ack. The ack clears
--      rsp_valid while the write is still pending (visible on TDO), then the read runs.
--   C3 ack AFTER the PASS word crossed: a read sent with a response still presented waits
--      (no transaction, response still intact on TDO over two slots); a NOP acking a
--      different seq changes nothing; then a NOP with the right ack releases it.
--   C4 a write carrying the ack.
--   D  FIFO depth: the executor waits on a read while a 62-word write (64 pushes) and a
--      NOP (2 pushes) queue behind it; ovf must stay 0 and the write must execute whole.
--   E  ack-slot tail overwrite: MEM_RD 496 presented, then the next MEM_RD 496 carries the
--      ack, so the executor rewrites the response RAM while the ack slot is still shifting
--      the acked response's tail. E1 runs the ack slot at 27 MHz and reports how many words
--      were overwritten (a tear would have to be detected). E2 runs it at 5 MHz, where the
--      bench REQUIRES the tail to be overwritten with the new data and the shown rsp_crc not
--      to match it (detected, not silent). At 27 MHz the tear cannot happen with this
--      executor: it writes one word per aclk in address order and reaches word 495 at
--      >= 2.48 us, while the frame core reads word 495 63 TCK (2.33 us) after the ack.
--   F  two slots in one Shift-DR: the second slot's status shows the first slot's write done.
--   G  reset: arst pulsed while the executor waits on a read with a write queued in the
--      FIFO: the waiting read is dropped, the queued write executes exactly once after the
--      reset, the status shows the reset values; a read afterwards works.
--   S  status-sync stress: a SECOND jc_status_sync on the same TCK and aclk, whose live word
--      changes on every aclk (twelve 32-bit lanes, each a different function of one
--      counter). At every TCK-side update: all lanes from the same counter value
--      (coherent); the value strictly newer than the last (monotonic, never older); the
--      time from the aclk edge that wrote the snapshot to the TCK edge that captured it
--      >= one TCK period (the set_max_delay the timing script puts on snap -> st_r); the
--      next snapshot written strictly after the previous capture; and, while TCK has run
--      continuously for 8+ edges, the captured snapshot no older than 4 TCK periods.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_jc_ctl_core is
end entity;

architecture sim of tb_jc_ctl_core is
  constant TCK_P  : time := 37 ns;
  constant ACLK_P : time := 5 ns;
  constant GAP    : time := 10 us;
  constant TMO    : positive := 2**21;     -- longer than case C2's muted-B window
  constant SB     : natural := 16384;
  constant NONE   : std_logic_vector(31 downto 0) := x"FFFFFFFF";
  constant CNT_A  : std_logic_vector(31 downto 0) := x"0000F100";
  constant HX     : unsigned(39 downto 0) := x"0100000000";
  constant HY     : unsigned(39 downto 0) := x"0100001000";

  subtype slv32 is std_logic_vector(31 downto 0);
  subtype slot_t is std_logic_vector(SB-1 downto 0);

  signal running : boolean := true;
  signal aclk    : std_logic := '0';
  signal arst    : std_logic := '1';
  signal tck, capture, shift, tdi, tdo : std_logic := '0';
  signal sel     : std_logic := '1';

  signal l_awaddr, l_wdata, l_araddr, l_rdata : slv32;
  signal l_awprot, l_arprot : std_logic_vector(2 downto 0);
  signal l_wstrb : std_logic_vector(3 downto 0);
  signal l_bresp, l_rresp : std_logic_vector(1 downto 0);
  signal l_awvalid, l_awready, l_wvalid, l_wready, l_bvalid, l_bready : std_logic;
  signal l_arvalid, l_arready, l_rvalid, l_rready : std_logic;
  signal h_araddr : std_logic_vector(32 downto 0);
  signal h_arlen  : std_logic_vector(7 downto 0);
  signal h_arsize : std_logic_vector(2 downto 0);
  signal h_arburst, h_rresp : std_logic_vector(1 downto 0);
  signal h_arvalid, h_arready, h_rvalid, h_rready, h_rlast : std_logic;
  signal h_rdata : std_logic_vector(255 downto 0);

  signal log_count, log_idx, log_kind, axil_err, hbm_err : natural := 0;
  signal log_addr, log_data : slv32;
  signal log_resp : std_logic_vector(1 downto 0);
  signal mute_b : std_logic := '0';
  signal poke_en   : std_logic := '0';
  signal poke_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal poke_data : std_logic_vector(255 downto 0) := (others => '0');

  -- status-sync stress
  signal scnt     : unsigned(31 downto 0) := (others => '0');
  signal t_one    : time := 0 ns;              -- when scnt became 1
  signal live_x, st_x : std_logic_vector(383 downto 0);
  signal last_tck : time := 0 ns;
  signal run_edges : natural := 0;
  signal s_ncap, s_coh, s_mono, s_marg, s_hold, s_fresh : natural := 0;
  signal s_min_marg, s_min_hold, s_max_age_run : time := 0 ns;

  function lane(c : unsigned(31 downto 0); j : natural) return std_logic_vector is
  begin
    return std_logic_vector(rotate_left(c, 3 * j) xor to_unsigned(j * 16#1111#, 32));
  end function;

  -- payload items, the same function as sim/gen_jc_ctl_core_vec.py
  function item(salt, i : natural) return slv32 is
    variable p : unsigned(63 downto 0);
  begin
    p := to_unsigned(salt * 65536 + i + 1, 32) * unsigned'(x"9E3779B9");
    return std_logic_vector(p(31 downto 0) xor p(63 downto 32)) xor x"3C000000";
  end function;

  -- the HBM seed: one 256-bit word per 32-byte address (as tb_jc_ctl_exec)
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

  -- bench-local CRC-32 (reflected, poly 0xEDB88320): one byte, bit 0 first
  function crc_byte(c : slv32; b : std_logic_vector(7 downto 0)) return slv32 is
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

  -- CRC-32 (init ones, final xor ones) of nbytes bytes of v starting at bit 8*b0
  function crc_bytes(v : std_logic_vector; b0, nbytes : natural) return slv32 is
    variable c : slv32 := (others => '1');
  begin
    for b in b0 to b0 + nbytes - 1 loop
      c := crc_byte(c, v(v'low + 8*b + 7 downto v'low + 8*b));
    end loop;
    return c xor x"FFFFFFFF";
  end function;

  function s32(n : natural) return slv32 is
  begin
    return std_logic_vector(to_unsigned(n, 32));
  end function;

  -- one TDI slot: header word 0, payload words 1..62, CRC-32 of bits 0..16127 at 16128
  function frame(seq, op : natural; addr : unsigned(63 downto 0); count, ack_seq, ack_v,
                 salt : natural) return slot_t is
    variable s  : slot_t := (others => '0');
    variable nw : natural := 0;
  begin
    s(31 downto 0)    := x"4A435431";
    s(63 downto 32)   := s32(seq);
    s(71 downto 64)   := std_logic_vector(to_unsigned(op, 8));
    s(87 downto 72)   := std_logic_vector(to_unsigned(count, 16));
    if op = 1 or op = 2 then
      nw := (count + 7) / 8;
      for i in 0 to count - 1 loop
        s(256 + 32*i + 31 downto 256 + 32*i) := item(salt, i);
      end loop;
    end if;
    s(119 downto 104) := std_logic_vector(to_unsigned(nw, 16));
    s(183 downto 120) := std_logic_vector(addr);
    s(215 downto 184) := s32(ack_seq);
    if ack_v = 1 then s(216) := '1'; end if;
    s(16159 downto 16128) := crc_bytes(s, 0, 2016);
    return s;
  end function;

  function a64(n : natural) return unsigned is
  begin
    return to_unsigned(n, 64);
  end function;
begin
  aclk <= not aclk after ACLK_P / 2 when running else '0';

  dut : entity work.jc_ctl_core
    generic map(TMO_CYC => TMO)
    port map(aclk => aclk, arst => arst,
             tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi, tdo => tdo,
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
             m_axi_rvalid => h_rvalid, m_axi_rready => h_rready);

  axil : entity work.axil_slave_model
    generic map(CNT_ADDR => CNT_A)
    port map(clk => aclk, awaddr => l_awaddr, awvalid => l_awvalid, awready => l_awready,
             wdata => l_wdata, wstrb => l_wstrb, wvalid => l_wvalid, wready => l_wready,
             bresp => l_bresp, bvalid => l_bvalid, bready => l_bready,
             araddr => l_araddr, arvalid => l_arvalid, arready => l_arready,
             rdata => l_rdata, rresp => l_rresp, rvalid => l_rvalid, rready => l_rready,
             log_count => log_count, log_idx => log_idx, log_kind => log_kind,
             log_addr => log_addr, log_data => log_data, log_resp => log_resp,
             reg_addr => (others => '0'), reg_data => open, errors => axil_err,
             mute_b => mute_b, mute_r => '0');

  hbm : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 11, STALL => true)
    port map(clk => aclk,
             awaddr => (others => '0'), awlen => "0000", awsize => "101", awburst => "01",
             awvalid => '0', awready => open, wdata => (others => '0'),
             wstrb => (others => '1'), wlast => '0', wvalid => '0', wready => open,
             bresp => open, bvalid => open, bready => '1',
             araddr => h_araddr, arlen => h_arlen(3 downto 0), arsize => h_arsize,
             arburst => h_arburst, arvalid => h_arvalid, arready => h_arready,
             rdata => h_rdata, rresp => h_rresp, rlast => h_rlast, rvalid => h_rvalid,
             rready => h_rready, poke_en => poke_en, poke_addr => poke_addr,
             poke_data => poke_data, peek_addr => (others => '0'), peek_data => open,
             peek_hit => open, errors => hbm_err);

  -- ================= status-sync stress (case S) =================
  scnt_p : process(aclk)
  begin
    if rising_edge(aclk) then
      scnt <= scnt + 1;
      if scnt = 0 then
        t_one <= now;
      end if;
    end if;
  end process;

  live_g : for j in 0 to 11 generate
    live_x(32*j+31 downto 32*j) <= lane(scnt, j);
  end generate;

  ssx : entity work.jc_status_sync
    generic map(W => 384)
    port map(aclk => aclk, live => live_x, tck => tck, st_tck => st_x);

  tck_run : process(tck)
  begin
    if rising_edge(tck) then
      if now - last_tck <= TCK_P + TCK_P / 2 then
        run_edges <= run_edges + 1;
      else
        run_edges <= 0;
      end if;
      last_tck <= now;
    end if;
  end process;

  smon : process(st_x)
    variable c, prev : unsigned(31 downto 0);
    variable have : boolean := false;
    variable t_w, marg, t_cap : time;
    variable ok : boolean;
  begin
    if now > 0 ns and st_x /= (st_x'range => '0') then
      c := unsigned(st_x(31 downto 0));
      ok := true;
      for j in 1 to 11 loop
        if st_x(32*j+31 downto 32*j) /= lane(c, j) then ok := false; end if;
      end loop;
      if not ok then
        s_coh <= s_coh + 1;
        report "STRESS: incoherent status snapshot" severity error;
      end if;
      -- the snapshot holding counter value c was written on the aclk edge where scnt
      -- became c + 1, i.e. t_one + c * ACLK_P
      t_w  := t_one + to_integer(c) * ACLK_P;
      marg := now - t_w;
      if have then
        if c <= prev then
          s_mono <= s_mono + 1;
          report "STRESS: snapshot not newer than the previous one" severity error;
        end if;
        if t_w - t_cap < ACLK_P then
          s_hold <= s_hold + 1;
          report "STRESS: snapshot written " & time'image(t_w - t_cap) &
                 " after the previous capture" severity error;
        end if;
        if s_ncap = 1 or t_w - t_cap < s_min_hold then s_min_hold <= t_w - t_cap; end if;
      end if;
      if marg < TCK_P then
        s_marg <= s_marg + 1;
        report "STRESS: snapshot captured " & time'image(marg) & " after it was written"
          severity error;
      end if;
      if s_ncap = 0 or marg < s_min_marg then s_min_marg <= marg; end if;
      if run_edges >= 8 then
        if marg > s_max_age_run then s_max_age_run <= marg; end if;
        if marg > 4 * TCK_P then
          s_fresh <= s_fresh + 1;
          report "STRESS: snapshot " & time'image(marg) & " old in a running scan"
            severity error;
        end if;
      end if;
      prev  := c;
      t_cap := now;
      have  := true;
      s_ncap <= s_ncap + 1;
    end if;
  end process;

  -- ================= the host =================
  driver : process
    type slot_arr is array (0 to 1) of slot_t;
    type w_arr is array (0 to 495) of slv32;
    type s_arr is array (0 to 63) of slv32;
    file vf : text open read_mode is "jc_ctl_core_vec.txt";
    variable tx, rx : slot_arr;
    variable expw : w_arr;
    variable acked : s_arr;
    variable nacked : natural := 0;
    variable checks, errors, nslots : natural := 0;
    variable e_crcf : natural := 0;
    variable prev_done : slv32 := NONE;
    variable last_torn : boolean := false;
    variable nlog : natural := 0;
    variable nopseq : natural := 1000;
    variable ntear_det : natural := 0;
    variable l : line;
    variable c : character;
    variable vname : string(1 to 8);
    variable vn, v_seq, v_op, v_cnt, v_aseq, v_av, v_salt : natural;
    variable v_addr : std_logic_vector(63 downto 0);
    variable w256 : std_logic_vector(255 downto 0);
    variable vslot : slot_t;
    variable nvec : natural := 0;
    variable crc_ka : slv32;
    variable f : slot_t;
    variable tail_x, tail_y : natural;
    variable tckp : time := TCK_P;            -- the host's TCK period (case E2 slows it)

    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then
        errors := errors + 1;
        report "CHECK FAILED: " & msg severity error;
      end if;
    end procedure;

    procedure fatal(msg : string) is
    begin
      report "CHECK FAILED: " & msg & " (abandoning the run)" severity failure;
    end procedure;

    -- one TCK cycle: inputs settle in the low half, TDO is sampled just before the rising
    -- edge (the bit the host receives on that edge)
    procedure edge(cap, sh, d : std_logic; smp : out std_logic) is
    begin
      capture <= cap; shift <= sh; tdi <= d;
      wait for tckp / 2;
      smp := tdo;
      tck <= '1';
      wait for tckp / 2;
      tck <= '0';
    end procedure;

    procedure qedge(cap : std_logic) is
      variable x : std_logic;
    begin
      edge(cap, '0', '0', x);
    end procedure;

    function fld(t : slot_t; hi, lo : natural) return std_logic_vector is
    begin
      return t(hi downto lo);
    end function;

    function n_of(t : slot_t) return natural is
    begin
      return to_integer(unsigned(t(111 downto 96)));
    end function;

    -- the checks every slot's TDO gets (header comment)
    procedure status_check(t : slot_t; allow_tear : boolean; tag : string) is
      variable n : natural;
      variable cc : slv32;
      variable z : boolean;
    begin
      nslots := nslots + 1;
      chk(t(31 downto 0) = x"4A435354", tag & ": status magic " & to_hstring(t(31 downto 0)));
      cc := crc_bytes(t, 0, 44);
      chk(cc = t(383 downto 352), tag & ": st_crc " & to_hstring(t(383 downto 352)) &
          ", CRC of TDO bits 0..351 is " & to_hstring(cc));
      chk(unsigned(t(351 downto 213)) = 0, tag & ": status [351:213] not zero");
      chk(unsigned(t(163 downto 148)) = 0, tag & ": desync count " &
          integer'image(to_integer(unsigned(t(163 downto 148)))));
      chk(t(164) = '0', tag & ": FIFO overflow seen");
      chk(to_integer(unsigned(t(180 downto 165))) = e_crcf, tag & ": crc-fail count " &
          integer'image(to_integer(unsigned(t(180 downto 165)))) & ", expected " &
          integer'image(e_crcf));
      n := n_of(t);
      chk(n <= 496, tag & ": rsp_count over 496");
      if n > 496 then n := 496; end if;
      if t(112) = '0' then
        chk(n = 0, tag & ": rsp_count " & integer'image(n) & " with rsp_valid 0");
        n := 0;
      end if;
      z := true;
      for b in 384 + 32 * n to SB - 1 loop
        if t(b) /= '0' then z := false; end if;
      end loop;
      chk(z, tag & ": TDO not zero after the response region");
      last_torn := false;
      if t(112) = '1' then
        cc := crc_bytes(t, 48, 4 * n);
        last_torn := cc /= t(212 downto 181);
        if not allow_tear then
          chk(not last_torn, tag & ": rsp_crc " & to_hstring(t(212 downto 181)) &
              " but the CRC of the " & integer'image(n) & " words on TDO is " & to_hstring(cc));
        end if;
        for i in 0 to nacked - 1 loop
          chk(t(95 downto 64) /= acked(i), tag & ": acked seq " & to_hstring(acked(i)) &
              " presented valid again");
        end loop;
      end if;
      if t(63 downto 32) /= NONE then
        if prev_done /= NONE then
          chk(unsigned(t(63 downto 32)) >= unsigned(prev_done), tag & ": last_done_seq " &
              to_hstring(t(63 downto 32)) & " went back from " & to_hstring(prev_done));
        end if;
        prev_done := t(63 downto 32);
      end if;
    end procedure;

    -- one scan of n back-to-back slots tx(0..n-1), TDO into rx(0..n-1), then the gap
    procedure scan(n : natural) is
      variable b : std_logic;
    begin
      qedge('0');                          -- Run-Test/Idle -> Select-DR
      qedge('0');                          -- Select-DR -> Capture-DR
      qedge('1');                          -- Capture-DR -> Shift-DR
      for s in 0 to n - 1 loop
        for i in 0 to SB - 1 loop
          edge('0', '1', tx(s)(i), b);
          rx(s)(i) := b;
        end loop;
      end loop;
      qedge('0');                          -- Exit1-DR -> Update-DR
      qedge('0');                          -- Update-DR -> Run-Test/Idle
      wait for GAP;
    end procedure;

    procedure xfer(s : slot_t; allow_tear : boolean; tag : string) is
    begin
      tx(0) := s;
      scan(1);
      status_check(rx(0), allow_tear, tag);
    end procedure;

    -- a PASS frame; an ack it carries must have been presented in its own slot
    procedure send(seq, op : natural; addr : unsigned(63 downto 0); count, ack_seq, ack_v,
                   salt : natural; tag : string) is
    begin
      xfer(frame(seq, op, addr, count, ack_seq, ack_v, salt), ack_v = 1, tag);
      if ack_v = 1 then
        chk(rx(0)(112) = '1' and rx(0)(95 downto 64) = s32(ack_seq),
            tag & ": the acked seq was not presented in the ack slot");
        acked(nacked) := s32(ack_seq);
        nacked := nacked + 1;
      end if;
    end procedure;

    procedure nop(ack_seq, ack_v : natural; tag : string) is
    begin
      nopseq := nopseq + 1;
      send(nopseq, 0, a64(0), 1, ack_seq, ack_v, 0, tag & " NOP");
    end procedure;

    procedure poll_done(seq : natural; tag : string) is
    begin
      for k in 1 to 12 loop
        nop(0, 0, tag & " poll");
        if rx(0)(63 downto 32) = s32(seq) then
          return;
        end if;
      end loop;
      fatal(tag & ": last_done_seq never reached " & to_hstring(s32(seq)) & " (shows " &
            to_hstring(rx(0)(63 downto 32)) & ")");
    end procedure;

    -- poll until seq is presented, then check it against expw(0..n-1)
    procedure get_rsp(seq, n : natural; tag : string) is
      variable cc : slv32 := (others => '1');
      variable bad : integer := -1;
    begin
      for k in 1 to 12 loop
        nop(0, 0, tag & " poll");
        if rx(0)(112) = '1' and rx(0)(95 downto 64) = s32(seq) then
          chk(n_of(rx(0)) = n, tag & ": rsp_count " & integer'image(n_of(rx(0))));
          for i in 0 to n - 1 loop
            if rx(0)(384 + 32*i + 31 downto 384 + 32*i) /= expw(i) and bad < 0 then
              bad := i;
            end if;
            for b in 0 to 3 loop
              cc := crc_byte(cc, expw(i)(8*b+7 downto 8*b));
            end loop;
          end loop;
          chk(bad < 0, tag & ": response word " & integer'image(bad) & " on TDO wrong");
          chk(rx(0)(212 downto 181) = (cc xor x"FFFFFFFF"), tag & ": rsp_crc " &
              to_hstring(rx(0)(212 downto 181)) & ", bench CRC of the expected words " &
              to_hstring(cc xor x"FFFFFFFF"));
          return;
        end if;
      end loop;
      fatal(tag & ": seq " & to_hstring(s32(seq)) & " never presented");
    end procedure;

    -- the slave log from entry nlog: n entries of one kind at addr0 + step*i
    procedure chk_log(n, kind : natural; addr0 : slv32; step : natural; tag : string) is
    begin
      for i in 0 to n - 1 loop
        log_idx <= nlog + i;
        wait for 1 ns;
        chk(log_kind = kind and log_addr = std_logic_vector(unsigned(addr0) + step * i)
            and log_data = expw(i) and log_resp = "00",
            tag & ": slave log[" & integer'image(nlog + i) & "] kind " &
            integer'image(log_kind) & " addr " & to_hstring(log_addr) & " data " &
            to_hstring(log_data) & ", expected " & integer'image(kind) & " " &
            to_hstring(std_logic_vector(unsigned(addr0) + step * i)) & " " & to_hstring(expw(i)));
      end loop;
      nlog := nlog + n;
    end procedure;

    procedure log_total(tag : string) is
    begin
      wait for 1 ns;
      chk(log_count = nlog, tag & ": " & integer'image(log_count) &
          " AXI-Lite transactions, expected " & integer'image(nlog));
    end procedure;

    procedure exp_items(salt, n : natural) is
    begin
      for i in 0 to n - 1 loop expw(i) := item(salt, i); end loop;
    end procedure;

    procedure exp_hbm(base : unsigned(39 downto 0); n : natural) is
      variable w : std_logic_vector(255 downto 0);
    begin
      for i in 0 to n - 1 loop
        w := memw(base + to_unsigned(32 * (i / 8), 40));
        expw(i) := w(32 * (i mod 8) + 31 downto 32 * (i mod 8));
      end loop;
    end procedure;
  begin
    -- ---- the bench CRC, known answer ----
    crc_ka := (others => '1');
    for k in 0 to 8 loop
      crc_ka := crc_byte(crc_ka, std_logic_vector(to_unsigned(character'pos('1') + k, 8)));
    end loop;
    chk((crc_ka xor x"FFFFFFFF") = x"CBF43926", "bench CRC-32 known answer");

    -- ---- the host library's slots must equal the bench builder's ----
    while not endfile(vf) loop
      readline(vf, l);
      next when l'length = 0;
      read(l, c);
      next when c = '#';
      assert c = 'V' report "bad vector line tag" severity failure;
      read(l, c);                         -- the space
      vn := 0; vname := (others => ' ');
      loop
        read(l, c);
        exit when c = ' ';
        vn := vn + 1; vname(vn) := c;
      end loop;
      read(l, v_seq); read(l, v_op); hread(l, v_addr); read(l, v_cnt);
      read(l, v_aseq); read(l, v_av); read(l, v_salt);
      for k in SB / 256 - 1 downto 0 loop
        hread(l, w256);
        vslot(256 * k + 255 downto 256 * k) := w256;
      end loop;
      f := frame(v_seq, v_op, unsigned(v_addr), v_cnt, v_aseq, v_av, v_salt);
      chk(f = vslot, "host library slot '" & vname(1 to vn) & "' differs from the bench builder");
      nvec := nvec + 1;
    end loop;
    chk(nvec = 5, "host-library vector slots: " & integer'image(nvec) & ", expected 5");

    -- ---- seed HBM regions X and Y (62 words each) ----
    for i in 0 to 61 loop
      poke_addr <= std_logic_vector(HX + to_unsigned(32 * i, 40));
      poke_data <= memw(HX + to_unsigned(32 * i, 40));
      poke_en <= '1';
      wait until rising_edge(aclk);
      poke_addr <= std_logic_vector(HY + to_unsigned(32 * i, 40));
      poke_data <= memw(HY + to_unsigned(32 * i, 40));
      wait until rising_edge(aclk);
    end loop;
    poke_en <= '0';
    for k in 1 to 20 loop wait until rising_edge(aclk); end loop;
    arst <= '0';
    wait for 1 us;

    -- ======== A: WR_INC 496, then RD_INC 496 read back on TDO ========
    send(1, 1, a64(16#1000#), 496, 0, 0, 1, "A wr496");
    poll_done(1, "A wr496");
    chk(rx(0)(113) = '0', "A wr496: axi_err");
    exp_items(1, 496);
    chk_log(496, 0, x"00001000", 4, "A wr496");
    send(2, 3, a64(16#1000#), 496, 0, 0, 0, "A rd496");
    get_rsp(2, 496, "A rd496");
    chk_log(496, 1, x"00001000", 4, "A rd496");
    nop(2, 1, "A ack");
    log_total("A");

    -- ======== B: CRC fail, then a retry with the same seq ========
    f := frame(4, 1, a64(16#2000#), 3, 0, 0, 3);
    f(256 + 37) := not f(256 + 37);
    xfer(f, false, "B corrupt");
    e_crcf := 1;
    nop(0, 0, "B after fail");
    nop(0, 0, "B after fail");
    chk(rx(0)(63 downto 32) = s32(2), "B: last_done_seq moved after a FAIL frame");
    log_total("B after fail");
    send(4, 1, a64(16#2000#), 3, 0, 0, 3, "B retry");
    poll_done(4, "B retry");
    exp_items(3, 3);
    chk_log(3, 0, x"00002000", 4, "B retry");
    log_total("B retry");

    -- ======== C1: the ack rides on the next read's frame ========
    send(10, 3, a64(16#2000#), 3, 0, 0, 0, "C1 rd10");
    get_rsp(10, 3, "C1 rd10");
    chk_log(3, 1, x"00002000", 4, "C1 rd10");
    send(11, 4, resize(unsigned(CNT_A), 64), 3, 10, 1, 0, "C1 rdfix11 acks 10");
    for i in 0 to 2 loop expw(i) := s32(i + 1); end loop;
    get_rsp(11, 3, "C1 rdfix11");
    chk_log(3, 1, CNT_A, 0, "C1 rdfix11");
    log_total("C1");

    -- ======== C2: ack crosses while the executor is held in a write ========
    mute_b <= '1';
    send(12, 2, a64(16#3000#), 1, 0, 0, 4, "C2 wr12 (B held)");
    nop(0, 0, "C2 held");
    nop(0, 0, "C2 held");
    chk(rx(0)(63 downto 32) = s32(11) and rx(0)(112) = '1' and rx(0)(95 downto 64) = s32(11),
        "C2: before the ack, 11 is not still presented with last_done 11");
    send(13, 3, a64(16#2000#), 2, 11, 1, 0, "C2 rd13 acks 11");
    nop(0, 0, "C2 acked, write held");
    nop(0, 0, "C2 acked, write held");
    chk(rx(0)(63 downto 32) = s32(11) and rx(0)(112) = '0',
        "C2: the ack did not clear rsp_valid while the write was held (last_done " &
        to_hstring(rx(0)(63 downto 32)) & ", rsp_valid " & std_logic'image(rx(0)(112)) & ")");
    exp_items(4, 1);
    chk_log(1, 0, x"00003000", 0, "C2 wr12 (applied, B held)");
    log_total("C2 held");
    mute_b <= '0';
    poll_done(13, "C2");
    exp_items(3, 2);
    get_rsp(13, 2, "C2 rd13");
    chk_log(2, 1, x"00002000", 4, "C2 rd13");
    log_total("C2");

    -- ======== C3: the read crosses first, the ack later ========
    send(14, 3, a64(16#2008#), 1, 0, 0, 0, "C3 rd14 (no ack)");
    for k in 1 to 2 loop
      nop(0, 0, "C3 waiting");
      chk(rx(0)(112) = '1' and rx(0)(95 downto 64) = s32(13) and rx(0)(63 downto 32) = s32(13),
          "C3: 13 not presented intact while 14 waits");
    end loop;
    log_total("C3 waiting");
    -- an ack of a seq that is not the one presented (12) must be ignored
    nopseq := nopseq + 1;
    xfer(frame(nopseq, 0, a64(0), 1, 12, 1, 0), false, "C3 wrong-seq ack NOP");
    for k in 1 to 2 loop
      nop(0, 0, "C3 after wrong ack");
      chk(rx(0)(112) = '1' and rx(0)(95 downto 64) = s32(13) and rx(0)(63 downto 32) = s32(13),
          "C3: an ack of seq 12 released 13 (rsp_valid " & std_logic'image(rx(0)(112)) &
          ", last_done " & to_hstring(rx(0)(63 downto 32)) & ")");
    end loop;
    log_total("C3 after wrong ack");
    nop(13, 1, "C3 ack");
    expw(0) := item(3, 2);
    get_rsp(14, 1, "C3 rd14");
    chk_log(1, 1, x"00002008", 0, "C3 rd14");

    -- ======== C4: a write carries the ack ========
    send(15, 1, a64(16#3100#), 2, 14, 1, 5, "C4 wr15 acks 14");
    poll_done(15, "C4");
    exp_items(5, 2);
    chk_log(2, 0, x"00003100", 4, "C4 wr15");
    chk(rx(0)(112) = '0', "C4: 14 still presented after the write that acked it");
    log_total("C4");

    -- ======== D: a read waits while 66 words queue behind it ========
    send(16, 3, a64(16#3100#), 2, 0, 0, 0, "D rd16");
    get_rsp(16, 2, "D rd16");
    chk_log(2, 1, x"00003100", 4, "D rd16");
    send(17, 3, a64(16#1000#), 1, 0, 0, 0, "D rd17 (waits)");
    send(18, 1, a64(16#4000#), 496, 0, 0, 6, "D wr18 (queued)");
    nop(16, 1, "D ack 16 (queued)");
    expw(0) := item(1, 0);
    get_rsp(17, 1, "D rd17");
    chk_log(1, 1, x"00001000", 0, "D rd17");
    poll_done(18, "D wr18");
    exp_items(6, 496);
    chk_log(496, 0, x"00004000", 4, "D wr18");
    nop(17, 1, "D ack 17");
    log_total("D");

    -- ======== E: the ack slot's tail and the next MEM_RD ========
    -- E1 at 27 MHz: measured and reported (a tear here would also have to be detected).
    -- E2 at 5 MHz: the tail MUST be overwritten while it shifts, and rsp_crc must show it.
    send(16#2F#, 5, resize(HX, 64), 496, 0, 0, 0, "E1 memrd 2F");
    exp_hbm(HX, 496);
    get_rsp(16#2F#, 496, "E1 memrd 2F");
    send(16#30#, 5, resize(HY, 64), 496, 16#2F#, 1, 0, "E1 memrd 30 acks 2F (27 MHz)");
    tail_x := 0;
    for i in 0 to 495 loop
      if rx(0)(384 + 32*i + 31 downto 384 + 32*i) /= expw(i) then tail_x := tail_x + 1; end if;
    end loop;
    chk(tail_x = 0 or last_torn, "E1: a torn ack slot at 27 MHz was not detected by rsp_crc");
    if last_torn then ntear_det := ntear_det + 1; end if;
    report "E1: ack slot at 27 MHz: " & integer'image(tail_x) & " response words overwritten";
    exp_hbm(HY, 496);
    get_rsp(16#30#, 496, "E1 memrd 30");
    tckp := 200 ns;
    send(16#31#, 5, resize(HX, 64), 496, 16#30#, 1, 0, "E2 memrd 31 acks 30 (5 MHz)");
    tckp := TCK_P;
    tail_x := 0; tail_y := 0;
    for i in 0 to 495 loop
      if rx(0)(384 + 32*i + 31 downto 384 + 32*i) /= expw(i) then
        tail_x := tail_x + 1;
        chk(i >= 492, "E2: ack slot word " & integer'image(i) & " torn (only the tail may be)");
      end if;
    end loop;
    exp_hbm(HX, 496);
    for i in 492 to 495 loop
      if rx(0)(384 + 32*i + 31 downto 384 + 32*i) = expw(i) then tail_y := tail_y + 1; end if;
    end loop;
    chk(tail_x > 0 and tail_y = tail_x, "E2: the ack slot's tail was not overwritten by the " &
        "next MEM_RD (" & integer'image(tail_x) & " words differ, " & integer'image(tail_y) &
        " equal the new data)");
    chk(last_torn, "E2: a torn ack slot was not detected by rsp_crc");
    if last_torn then ntear_det := ntear_det + 1; end if;
    report "E2: ack slot at 5 MHz: " & integer'image(tail_x) & " response words overwritten";
    get_rsp(16#31#, 496, "E2 memrd 31");
    nop(16#31#, 1, "E ack 31");
    log_total("E");

    -- ======== F: two slots in one Shift-DR ========
    tx(0) := frame(16#33#, 1, a64(16#5000#), 3, 0, 0, 7);
    nopseq := nopseq + 1;
    tx(1) := frame(nopseq, 0, a64(0), 1, 0, 0, 0);
    scan(2);
    status_check(rx(0), false, "F slot 0");
    status_check(rx(1), false, "F slot 1");
    chk(rx(1)(63 downto 32) = s32(16#33#), "F: the second slot of the scan does not show " &
        "the first slot's write done (shows " & to_hstring(rx(1)(63 downto 32)) & ")");
    exp_items(7, 3);
    chk_log(3, 0, x"00005000", 4, "F wr31");
    log_total("F");

    -- ======== G: reset with a read waiting and a write queued ========
    send(16#40#, 3, a64(16#1000#), 1, 0, 0, 0, "G rd40");
    expw(0) := item(1, 0);
    get_rsp(16#40#, 1, "G rd40");
    chk_log(1, 1, x"00001000", 0, "G rd40");
    send(16#41#, 3, a64(16#1004#), 1, 0, 0, 0, "G rd41 (waits)");
    send(16#42#, 1, a64(16#6000#), 2, 0, 0, 8, "G wr42 (queued)");
    log_total("G before reset");
    wait until rising_edge(aclk);
    arst <= '1';
    for k in 1 to 10 loop wait until rising_edge(aclk); end loop;
    arst <= '0';
    wait for 1 us;
    poll_done(16#42#, "G after reset");
    chk(rx(0)(112) = '0' and rx(0)(95 downto 64) = NONE and rx(0)(147 downto 116) = NONE
        and rx(0)(113) = '0', "G: status after the reset is not the reset value");
    exp_items(8, 2);
    chk_log(2, 0, x"00006000", 4, "G wr42 after reset");
    log_total("G after reset (the waiting read must not run)");
    send(16#43#, 3, a64(16#6000#), 2, 0, 0, 0, "G rd43");
    get_rsp(16#43#, 2, "G rd43");
    chk_log(2, 1, x"00006000", 4, "G rd43");
    nop(16#43#, 1, "G ack 43");
    nop(0, 0, "G final");
    log_total("end");

    -- ======== end ========
    wait for 1 us;
    chk(axil_err = 0, "AXI-Lite protocol errors: " & integer'image(axil_err));
    chk(hbm_err = 0, "jc_axi3_mem rule violations: " & integer'image(hbm_err));
    chk(s_ncap >= 1000, "STRESS: only " & integer'image(s_ncap) & " TCK-side updates");
    chk(s_coh = 0 and s_mono = 0 and s_marg = 0 and s_hold = 0 and s_fresh = 0,
        "STRESS: incoherent " & integer'image(s_coh) & ", not newer " & integer'image(s_mono) &
        ", margin under one TCK " & integer'image(s_marg) & ", hold " & integer'image(s_hold) &
        ", stale in a running scan " & integer'image(s_fresh));
    chk(s_min_marg >= TCK_P, "STRESS: minimum snap-to-capture margin " & time'image(s_min_marg));
    report "STRESS: captures " & integer'image(s_ncap) & ", min snap-to-capture " &
           time'image(s_min_marg) & ", min capture-to-next-snap " & time'image(s_min_hold) &
           ", max snapshot age in a running scan " & time'image(s_max_age_run);
    report "tears detected by rsp_crc: " & integer'image(ntear_det) & "; slots " &
           integer'image(nslots) & "; AXI-Lite transactions " & integer'image(nlog);
    running <= false;
    if errors = 0 then
      report "PASS: tb_jc_ctl_core checks=" & integer'image(checks) & " slots=" &
             integer'image(nslots);
    else
      report "FAIL: tb_jc_ctl_core errors=" & integer'image(errors) & " checks=" &
             integer'image(checks) severity failure;
    end if;
    wait;
  end process;
end architecture;
