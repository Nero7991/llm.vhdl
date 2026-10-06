-- Bench for rtl/jc_frame_core.vhd: shifts the slots of sim/jc_frame_vec.txt through
-- one continuous Shift-DR (one Capture at the start, as the host does) and checks every
-- push, every verdict, the desync count and the status on TDO.
-- Task 9b: the status is 384 bits; every one of them is a nonzero-capable pattern bit
-- here (including [383:353], which jc_loader_core ties to zero but this unit must still
-- shift whatever it is given), and TDO must be zero for every slot bit past 383.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.jc_loader_pkg.all;

entity tb_jc_frame_core is
end entity;

architecture sim of tb_jc_frame_core is
  constant TCK_P : time := 37 ns;
  signal tck, sel, capture, shift, tdi, tdo : std_logic := '0';
  signal w_valid, ovf : std_logic;
  signal w_data  : std_logic_vector(JC_FIFO_W-1 downto 0);
  signal st_in   : std_logic_vector(JC_STATUS_BITS-1 downto 0) := (others => '0');
  signal desync  : unsigned(15 downto 0);
  signal done    : boolean := false;

  type push_t is record
    tag  : std_logic_vector(1 downto 0);
    word : std_logic_vector(255 downto 0);
  end record;
  type push_arr is array (0 to 127) of push_t;
  shared variable pushes : push_arr;     -- written by the monitor, read by the driver
  shared variable npush  : natural := 0;
begin
  dut : entity work.jc_frame_core
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, w_valid => w_valid, w_data => w_data, w_ready => '1',
             st_in => st_in, desync_cnt => desync, ovf_seen => ovf);

  tck <= not tck after TCK_P / 2 when not done else '0';

  -- a fixed, recognisable status pattern from the "aclk side"
  st_in <= x"A5C3E1F0" & x"0F1E2D3C" & x"4B5A6978" & x"8796A5B4" &       -- [383:256]
           x"CAFEF00D" & x"12345678" & x"00000000_00000000" & x"0000" & x"0000" &
           x"0000" & x"0000" & x"0000_0000" & x"00000000";

  monitor : process(tck)
  begin
    if rising_edge(tck) and w_valid = '1' then
      pushes(npush) := (tag => w_data(257 downto 256), word => w_data(255 downto 0));
      npush := npush + 1;
    end if;
  end process;

  driver : process
    file vf : text open read_mode is "jc_frame_vec.txt";
    variable l : line;
    variable c : character;
    variable ok, nw, ps : integer;
    variable seq : std_logic_vector(31 downto 0);
    variable slot : std_logic_vector(JC_SLOT_BITS-1 downto 0);
    variable tdo_bits : std_logic_vector(JC_STATUS_BITS-1 downto 0);
    variable exp_st : std_logic_vector(JC_STATUS_BITS-1 downto 0);
    variable tail_zero : boolean;
    variable checks, errors, nslot, exp_desync : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then
        errors := errors + 1;
        report "slot " & integer'image(nslot) & ": " & msg severity error;
      end if;
    end procedure;
  begin
    sel <= '1';
    wait until falling_edge(tck);
    capture <= '1';
    wait until falling_edge(tck);
    capture <= '0';
    shift <= '1';
    while not endfile(vf) loop
      readline(vf, l);
      read(l, c);                         -- 'S'
      read(l, ok); read(l, nw); read(l, ps);
      hread(l, seq);
      hread(l, slot);
      npush := 0;
      tail_zero := true;
      for i in 0 to JC_SLOT_BITS - 1 loop
        tdi <= slot(i);
        wait until rising_edge(tck);      -- the DUT samples tdi here
        if i < JC_STATUS_BITS then
          tdo_bits(i) := tdo;             -- tdo before the edge's update is bit i
        elsif tdo /= '0' then
          tail_zero := false;             -- every TDO bit past the status must be 0
        end if;
        wait until falling_edge(tck);
      end loop;
      -- every push for this slot has landed by now (the verdict is at bit 16159)
      if ok = 1 then
        chk(npush = nw + 2, "expected " & integer'image(nw + 2) & " pushes, got " & integer'image(npush));
        if npush = nw + 2 then
          chk(pushes(0).tag = TAG_HDR and pushes(0).word = slot(255 downto 0), "header push");
          for k in 1 to nw loop
            chk(pushes(k).tag = TAG_DATA and pushes(k).word = slot(256 * k + 255 downto 256 * k),
                "data word " & integer'image(k));
          end loop;
          if ps = 1 then
            chk(pushes(nw + 1).tag = TAG_PASS, "verdict should be PASS");
          else
            chk(pushes(nw + 1).tag = TAG_FAIL, "verdict should be FAIL");
          end if;
          chk(pushes(nw + 1).word(31 downto 0) = seq, "verdict seq");
        end if;
      else
        exp_desync := exp_desync + 1;
        chk(npush = 0, "a bad-magic slot must push nothing, pushed " & integer'image(npush));
      end if;
      chk(to_integer(desync) = exp_desync, "desync count " & integer'image(to_integer(desync)));
      -- TDO in this slot carried the status loaded at its start (desync before this slot)
      exp_st := st_in;
      exp_st(31 downto 0) := JC_MAGIC_STAT;
      exp_st(143 downto 128) := std_logic_vector(to_unsigned(exp_desync - (1 - ok), 16));
      exp_st(179) := '0';
      if nslot > 0 then
        chk(tdo_bits = exp_st, "status on TDO");
        chk(tail_zero, "TDO bits past " & integer'image(JC_STATUS_BITS - 1) & " must be zero");
      end if;
      nslot := nslot + 1;
    end loop;
    shift <= '0';
    chk(ovf = '0', "no overflow with w_ready held high");
    assert nslot = 17 report "expected 17 slots, ran " & integer'image(nslot) severity failure;
    assert checks > 100 report "too few checks: " & integer'image(checks) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_frame_core checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_frame_core errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
