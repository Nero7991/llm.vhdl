-- Bench for rtl/jc_ctl_frame_core.vhd (Jungle Cat USER3 control frame core, plan Task 2).
--
-- Drives TCK, CAPTURE and SHIFT with BSCAN timing: TCK pulses only while the host walks the
-- TAP (two Idle/Select edges, the Capture-DR edge, one edge per shifted bit, two
-- Exit1/Update edges) and is stopped otherwise. Slots come from sim/jc_ctl_frame_vec.txt
-- (format at the top of that file; written by sim/gen_jc_ctl_vec.py, whose expected values
-- come from zlib and a protocol model, not the RTL). For every slot it checks:
--   * every FIFO push (tag and 256-bit word) against the vector, and the push count;
--   * TDO bits 0..383 against st_in with the core's own fields merged in;
--   * TDO bits 384.. against the stub response RAM (word k = address k, LSB first) for the
--     expected number of words, and zero for every bit after that;
--   * rsp_ack_tgl: exactly one toggle at the edge that shifts bit 383 + 32*nrsp when the
--     vector says so, none otherwise (including the edges between scans);
--   * desync_cnt / crcf_cnt against the counts the next slot must show.
-- st_in changes to the next slot's value in the middle of every slot, so a core that
-- shifts the live status instead of the copy latched at slot start is visible. Between
-- scans a foreign scan (sel = 0, random TDI) must change nothing.
-- The response RAM stub is a one-cycle synchronous read on TCK, as Task 4's BRAM will be.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.jc_loader_pkg.all;
use work.jc_ctl_pkg.all;

entity tb_jc_ctl_frame_core is
end entity;

architecture sim of tb_jc_ctl_frame_core is
  constant TCK_P  : time := 37 ns;
  constant MAXS   : natural := 48;      -- slots
  constant MAXP   : natural := 64;      -- pushes per slot
  signal tck, sel, capture, shift, tdi, tdo : std_logic := '0';
  signal w_valid, ovf, ack_tgl : std_logic;
  signal w_ready : std_logic := '1';
  signal w_data  : std_logic_vector(JC_FIFO_W-1 downto 0);
  signal st_in   : std_logic_vector(JC_CTL_STATUS_BITS-1 downto 0) := (others => '0');
  signal rsp_addr : std_logic_vector(JC_CTL_RSP_AW-1 downto 0);
  signal rsp_q   : std_logic_vector(31 downto 0) := (others => '0');
  signal desync, crcf : unsigned(15 downto 0);

  type push_t is record
    tag  : std_logic_vector(1 downto 0);
    word : std_logic_vector(255 downto 0);
  end record;
  type push_arr is array (0 to 127) of push_t;
  shared variable pushes : push_arr;     -- written by the monitor, read by the driver
  shared variable npush  : natural := 0;

  -- the stub response RAM's contents: distinct, address-dependent, every bit position used
  function ram_word(a : natural) return std_logic_vector is
    variable p : unsigned(63 downto 0);
  begin
    p := to_unsigned(a + 1, 32) * unsigned'(x"9E3779B9");
    return std_logic_vector(p(31 downto 0) xor p(63 downto 32) xor x"A5000000");
  end function;
begin
  dut : entity work.jc_ctl_frame_core
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, w_valid => w_valid, w_data => w_data, w_ready => w_ready,
             st_in => st_in, rsp_addr => rsp_addr, rsp_q => rsp_q,
             rsp_ack_tgl => ack_tgl, desync_cnt => desync, crcf_cnt => crcf,
             ovf_seen => ovf);

  ram : process(tck)
  begin
    if rising_edge(tck) then
      rsp_q <= ram_word(to_integer(unsigned(rsp_addr)));
    end if;
  end process;

  monitor : process(tck)
  begin
    if rising_edge(tck) and w_valid = '1' then
      pushes(npush) := (tag => w_data(257 downto 256), word => w_data(255 downto 0));
      npush := npush + 1;
    end if;
  end process;

  driver : process
    file vf : text open read_mode is "jc_ctl_frame_vec.txt";
    type nat_arr is array (0 to MAXS-1) of natural;
    type st_arr  is array (0 to MAXS-1) of std_logic_vector(JC_CTL_STATUS_BITS-1 downto 0);
    type slot_arr is array (0 to MAXS-1) of std_logic_vector(JC_SLOT_BITS-1 downto 0);
    type exp_arr is array (0 to MAXS-1, 0 to MAXP-1) of push_t;
    variable v_nbits, v_end, v_wr, v_ack, v_rspv, v_nrsp, v_des, v_crcf, v_ovf, v_np
      : nat_arr;
    variable v_st   : st_arr;
    variable v_slot : slot_arr;
    variable v_push : exp_arr;
    variable e_des, e_crcf, e_ovf : natural := 0;
    variable nslots : natural := 0;
    variable l : line;
    variable c : character;
    variable n, t : integer;
    variable w256 : std_logic_vector(255 downto 0);
    variable tdo_b : std_logic;
    variable tdo_bits : std_logic_vector(JC_SLOT_BITS-1 downto 0);
    variable exp_st : std_logic_vector(JC_CTL_STATUS_BITS-1 downto 0);
    variable prev_ack : std_logic;
    variable nack, ack_at, first_bad, rsp_end : integer;
    variable checks, errors : natural := 0;
    variable cur : natural := 0;
    variable lfsr : unsigned(31 downto 0) := x"1234ABCD";

    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then
        errors := errors + 1;
        report "slot " & integer'image(cur) & ": " & msg severity error;
      end if;
    end procedure;

    -- one TCK cycle: inputs settle in the low half, TDO is sampled just before the rising
    -- edge (the bit the host receives), outputs are read after the edge.
    procedure edge(cap, sh, d : std_logic; variable smp : out std_logic) is
    begin
      capture <= cap; shift <= sh; tdi <= d;
      wait for TCK_P / 2;
      smp := tdo;
      tck <= '1';
      wait for TCK_P / 2;
      tck <= '0';
    end procedure;

    -- an edge outside a slot: nothing may toggle the ack
    procedure quiet_edge(cap, sh, d : std_logic) is
      variable dummy : std_logic;
    begin
      edge(cap, sh, d, dummy);
      if ack_tgl /= prev_ack then
        nack := nack + 1;
        prev_ack := ack_tgl;
      end if;
    end procedure;

    procedure start_scan is
    begin
      quiet_edge('0', '0', '0');           -- Run-Test/Idle -> Select-DR
      quiet_edge('0', '0', '0');           -- Select-DR -> Capture-DR
      quiet_edge('1', '0', '0');           -- Capture-DR -> Shift-DR (CAPTURE sampled)
    end procedure;

    procedure end_scan is
    begin
      quiet_edge('0', '0', '0');           -- Exit1-DR -> Update-DR
      quiet_edge('0', '0', '0');           -- Update-DR -> Run-Test/Idle
    end procedure;
  begin
    -- ---- read the whole vector file first (st_in must lead the slot it belongs to) ----
    while not endfile(vf) loop
      readline(vf, l);
      next when l'length = 0;
      read(l, c);
      next when c = '#';
      if c = 'E' then
        read(l, e_des); read(l, e_crcf); read(l, e_ovf);
        exit;
      end if;
      assert c = 'S' report "bad vector line tag" severity failure;
      assert nslots < MAXS report "too many slots for MAXS" severity failure;
      read(l, v_nbits(nslots)); read(l, v_end(nslots)); read(l, v_wr(nslots));
      read(l, v_ack(nslots));   read(l, v_rspv(nslots)); read(l, v_nrsp(nslots));
      read(l, v_des(nslots));   read(l, v_crcf(nslots)); read(l, v_ovf(nslots));
      hread(l, v_st(nslots));
      for k in 0 to JC_SLOT_BITS / 256 - 1 loop
        hread(l, w256);
        v_slot(nslots)(256 * k + 255 downto 256 * k) := w256;
      end loop;
      read(l, v_np(nslots));
      assert v_np(nslots) <= MAXP report "too many pushes for MAXP" severity failure;
      for k in 0 to v_np(nslots) - 1 loop
        read(l, t);
        hread(l, w256);
        v_push(nslots, k) := (tag => std_logic_vector(to_unsigned(t, 2)), word => w256);
      end loop;
      nslots := nslots + 1;
    end loop;
    assert nslots >= 20 report "vector file too short" severity failure;

    -- ---- run ----
    wait for TCK_P;                        -- let the DUT's initial values settle
    prev_ack := ack_tgl;
    nack := 0;
    sel <= '1';
    st_in <= v_st(0);
    w_ready <= '1';
    start_scan;
    chk(nack = 0, "ack toggled outside a slot");
    for j in 0 to nslots - 1 loop
      cur := j;
      w_ready <= '1' when v_wr(j) = 1 else '0';
      npush := 0;
      nack := 0; ack_at := -1;
      tdo_bits := (others => '0');
      for i in 0 to v_nbits(j) - 1 loop
        edge('0', '1', v_slot(j)(i), tdo_b);
        tdo_bits(i) := tdo_b;
        if ack_tgl /= prev_ack then
          nack := nack + 1;
          ack_at := i;
          prev_ack := ack_tgl;
        end if;
        if i = 0 then
          -- the latched copy is in use now: present the next slot's status
          if j + 1 < nslots then st_in <= v_st(j + 1); end if;
          chk(to_integer(desync) = v_des(j), "desync_cnt port " & integer'image(to_integer(desync)));
          chk(to_integer(crcf) = v_crcf(j), "crcf_cnt port " & integer'image(to_integer(crcf)));
        end if;
      end loop;

      -- pushes
      chk(npush = v_np(j), "expected " & integer'image(v_np(j)) & " pushes, got " & integer'image(npush));
      if npush = v_np(j) then
        for k in 0 to npush - 1 loop
          chk(pushes(k).tag = v_push(j, k).tag and pushes(k).word = v_push(j, k).word,
              "push " & integer'image(k) & " (tag/word)");
        end loop;
      end if;

      -- TDO: status
      exp_st := v_st(j);
      exp_st(31 downto 0)    := JC_CTL_MAGIC_STAT;
      exp_st(112)            := '1' when v_rspv(j) = 1 else '0';
      exp_st(163 downto 148) := std_logic_vector(to_unsigned(v_des(j), 16));
      exp_st(164)            := '1' when v_ovf(j) = 1 else '0';
      exp_st(180 downto 165) := std_logic_vector(to_unsigned(v_crcf(j), 16));
      if v_nbits(j) >= JC_CTL_STATUS_BITS then
        chk(tdo_bits(JC_CTL_STATUS_BITS-1 downto 0) = exp_st, "status on TDO");
      end if;
      -- TDO: response words, then zero
      rsp_end := JC_CTL_STATUS_BITS + 32 * v_nrsp(j);
      first_bad := -1;
      for i in JC_CTL_STATUS_BITS to v_nbits(j) - 1 loop
        if i < rsp_end then
          if tdo_bits(i) /= ram_word((i - JC_CTL_STATUS_BITS) / 32)((i - JC_CTL_STATUS_BITS) mod 32)
             and first_bad < 0 then
            first_bad := i;
          end if;
        elsif tdo_bits(i) /= '0' and first_bad < 0 then
          first_bad := i;
        end if;
      end loop;
      chk(first_bad < 0, "TDO response/zero region wrong from bit " & integer'image(first_bad)
                         & " (" & integer'image(v_nrsp(j)) & " response words)");
      -- the ack
      if v_ack(j) = 1 then
        chk(nack = 1 and ack_at = rsp_end - 1,
            "ack: " & integer'image(nack) & " toggles, last at bit " & integer'image(ack_at)
            & ", expected one at bit " & integer'image(rsp_end - 1));
      else
        chk(nack = 0, "ack must not toggle, toggled " & integer'image(nack) & " times");
      end if;

      if v_end(j) = 1 then
        nack := 0;
        end_scan;
        -- a foreign scan (another instruction selected): nothing may change
        npush := 0;
        sel <= '0';
        start_scan;
        for i in 0 to 299 loop
          lfsr := lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
          quiet_edge('0', '1', lfsr(0));
        end loop;
        end_scan;
        sel <= '1';
        chk(npush = 0 and nack = 0, "a foreign scan pushed or acked");
        if j + 1 < nslots then
          start_scan;
          chk(nack = 0, "ack toggled outside a slot");
        end if;
      end if;
    end loop;
    end_scan;
    shift <= '0';
    cur := nslots;
    chk(to_integer(desync) = e_des, "final desync " & integer'image(to_integer(desync)));
    chk(to_integer(crcf) = e_crcf, "final crcf " & integer'image(to_integer(crcf)));
    chk((ovf = '1') = (e_ovf = 1), "final ovf_seen");
    assert checks > 200 report "too few checks: " & integer'image(checks) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_ctl_frame_core checks=" & integer'image(checks)
             & " slots=" & integer'image(nslots);
    else
      report "FAIL: tb_jc_ctl_frame_core errors=" & integer'image(errors) severity failure;
    end if;
    wait;
  end process;
end architecture;
