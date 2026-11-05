-- sim/seam_beh_model.vhd -- a behavioural rtl/fk33_seam.vhd for the loop benches (plan
-- 2026-11-04 Task 2): the registers the loop touches, the v2 GO-time checks in the RTL's
-- order (fk33_seam.vhd:943-977: N_STEP, SEQ, POS, busy), and server/fk33_sim.c's argmax
-- arithmetic (fk33_sim.c:123-171) so its ids equal run_prompt's over jc_sim_broker. Window
-- 3 reads back window 2 and XEXP_OUT echoes X_EXP (the sim's hop model, fk33_sim.c:418-430).
-- Every completed write is published on wr_ev for sim/seam_trace_chk.vhd. Fault inputs:
-- f_err_pos (GO at that position ends in ERR code 6), f_hang_pos (never completes),
-- f_slverr_off (SLVERR at that offset; the real seam never does this, plan D6),
-- f_tokpos_stuck (TOK_POS reads cur_pos + 1).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity seam_beh_model is
  generic(N_EMBD : positive := 4096; NV : positive := 248320; SEED : std_logic_vector(15 downto 0) := x"ACE1");
  port(
    clk, rst       : in  std_logic;
    awaddr         : in  std_logic_vector(11 downto 0);
    awvalid        : in  std_logic;
    awready        : out std_logic := '0';
    wdata          : in  std_logic_vector(31 downto 0);
    wvalid         : in  std_logic;
    wready         : out std_logic := '0';
    bresp          : out std_logic_vector(1 downto 0) := "00";
    bvalid         : out std_logic := '0';
    bready         : in  std_logic;
    araddr         : in  std_logic_vector(11 downto 0);
    arvalid        : in  std_logic;
    arready        : out std_logic := '0';
    rdata          : out std_logic_vector(31 downto 0) := (others => '0');
    rresp          : out std_logic_vector(1 downto 0) := "00";
    rvalid         : out std_logic := '0';
    rready         : in  std_logic;
    wr_ev          : out std_logic := '0';
    wr_addr        : out std_logic_vector(11 downto 0) := (others => '0');
    wr_data        : out std_logic_vector(31 downto 0) := (others => '0');
    maxpos         : in  natural := 16384;
    go_lat         : in  natural := 40;
    f_err_pos      : in  integer := -1;
    f_hang_pos     : in  integer := -1;
    f_slverr_off   : in  integer := -1;
    f_tokpos_stuck : in  std_logic := '0';
    cur_pos_o      : out natural := 0;
    n_go_o         : out natural := 0);
end entity;

architecture sim of seam_beh_model is
  constant FNV_B : unsigned(31 downto 0) := x"811C9DC5";
  constant FNV_P : unsigned(31 downto 0) := x"01000193";
  type xin_t is array (0 to N_EMBD-1) of std_logic_vector(15 downto 0);
  function fnv(h, v : unsigned(31 downto 0)) return unsigned is
  begin
    return resize((h xor v) * FNV_P, 32);
  end function;
begin
  process(clk)
    variable xin : xin_t := (others => (others => '0'));
    variable seq_pos, n_step, x_exp, win_sel, win_addr, argmax, lexp, err_info : unsigned(31 downto 0) := (others => '0');
    variable st_done, st_err : std_logic := '0';
    variable code : unsigned(3 downto 0) := (others => '0');
    variable cur_pos, ngo : natural := 0;
    variable hist : unsigned(31 downto 0) := (others => '0');
    variable busy_left : integer := -1;          -- -1 idle, >= 0 cycles left, -2 hung
    variable go_err : boolean := false;
    variable aw_have, w_have, b_pend, r_pend : boolean := false;
    variable aw_a, ar_a : natural := 0;
    variable w_d, rv : std_logic_vector(31 downto 0) := (others => '0');
    variable lfsr : std_logic_vector(15 downto 0) := SEED;
    variable fx, pick : unsigned(31 downto 0);
    impure function stall return boolean is
    begin
      lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      return (lfsr(0) and lfsr(3)) = '1';
    end function;
  begin
    if rising_edge(clk) then
      wr_ev <= '0';
      if rst = '1' then
        busy_left := -1; st_done := '0'; st_err := '0'; aw_have := false; w_have := false;
        b_pend := false; r_pend := false; bvalid <= '0'; rvalid <= '0';
        awready <= '0'; wready <= '0'; arready <= '0';
      else
        -- a GO in flight
        if busy_left > 0 then
          busy_left := busy_left - 1;
        elsif busy_left = 0 then
          busy_left := -1;
          if go_err then
            st_err := '1'; code := to_unsigned(6, 4); err_info := x"0000DEAD";
          else
            fx := FNV_B;
            for k in 0 to N_EMBD - 1 loop fx := fnv(fx, resize(unsigned(xin(k)), 32)); end loop;
            hist := fnv(hist, to_unsigned(0, 32));          -- v2: no token id (fk33_sim.c:338-346)
            hist := fnv(hist, to_unsigned(cur_pos, 32));
            hist := fnv(hist, fx);
            pick := resize(hist * 31, 32) + resize(to_unsigned(cur_pos, 32) * 7, 32) + fx;
            argmax := pick mod to_unsigned(NV, 32);
            lexp := x_exp - 3;
            st_done := '1'; cur_pos := cur_pos + 1;
          end if;
        end if;
        -- handshakes
        if awvalid = '1' and awready = '1' then aw_have := true; aw_a := to_integer(unsigned(awaddr(11 downto 2))) * 4; end if;
        if wvalid = '1' and wready = '1' then w_have := true; w_d := wdata; end if;
        if bvalid = '1' and bready = '1' then bvalid <= '0'; b_pend := false; end if;
        if rvalid = '1' and rready = '1' then rvalid <= '0'; r_pend := false; end if;
        if aw_have and w_have and not b_pend then
          aw_have := false; w_have := false; b_pend := true;
          if aw_a = f_slverr_off then
            bresp <= "10";
          else
            bresp <= "00";
            wr_ev <= '1'; wr_addr <= std_logic_vector(to_unsigned(aw_a, 12)); wr_data <= w_d;
            case aw_a is
              when 16#14# =>
                if w_d(1) = '1' and busy_left = -1 then
                  cur_pos := 0; seq_pos := (others => '0'); hist := FNV_B;
                end if;
                if w_d(0) = '1' then
                  st_done := '0'; st_err := '0'; code := (others => '0');
                  if n_step /= 1 then st_err := '1'; code := to_unsigned(2, 4);
                  elsif seq_pos /= cur_pos then st_err := '1'; code := to_unsigned(8, 4);
                  elsif cur_pos >= maxpos then st_err := '1'; code := to_unsigned(1, 4);
                  elsif busy_left /= -1 then st_err := '1'; code := to_unsigned(8, 4);
                  else
                    ngo := ngo + 1; go_err := (cur_pos = f_err_pos);
                    if cur_pos = f_hang_pos then busy_left := -2; else busy_left := go_lat; end if;
                  end if;
                end if;
              when 16#20# => seq_pos := unsigned(w_d);
              when 16#24# => n_step := unsigned(w_d);
              when 16#54# => x_exp := unsigned(w_d);
              when 16#58# => win_sel := unsigned(w_d);
              when 16#5C# => win_addr := unsigned(w_d);
              when 16#60# =>
                if win_sel = 2 and win_addr < N_EMBD then xin(to_integer(win_addr)) := w_d(15 downto 0); end if;
                win_addr := win_addr + 1;
              when others => null;
            end case;
          end if;
        end if;
        if arvalid = '1' and arready = '1' then
          ar_a := to_integer(unsigned(araddr(11 downto 2))) * 4; r_pend := true;
          rv := (others => '0');
          case ar_a is
            when 16#18# =>
              rv(0) := st_done; rv(2) := st_err; rv(11 downto 8) := std_logic_vector(code);
              if busy_left /= -1 then rv(1) := '1'; end if;
            when 16#1C# => rv := std_logic_vector(err_info);
            when 16#20# => rv := std_logic_vector(seq_pos);
            when 16#44# => rv := std_logic_vector(argmax);
            when 16#48# => rv := std_logic_vector(lexp);
            when 16#54# | 16#A4# => rv := std_logic_vector(x_exp);
            when 16#58# => rv := std_logic_vector(win_sel);
            when 16#5C# => rv := std_logic_vector(win_addr);
            when 16#60# =>
              if win_sel = 3 and win_addr < N_EMBD then rv(15 downto 0) := xin(to_integer(win_addr)); end if;
              win_addr := win_addr + 1;
            when 16#8C# =>
              if f_tokpos_stuck = '1' then rv := std_logic_vector(to_unsigned(cur_pos + 1, 32));
              else rv := std_logic_vector(to_unsigned(cur_pos, 32)); end if;
            when 16#A0# => rv := std_logic_vector(to_unsigned(maxpos, 32));
            when others => null;
          end case;
          rdata <= rv;
          if ar_a = f_slverr_off then rresp <= "10"; else rresp <= "00"; end if;
        end if;
        if b_pend and bvalid = '0' and not stall then bvalid <= '1'; end if;
        if r_pend and rvalid = '0' and not stall then rvalid <= '1'; end if;
        awready <= '0'; wready <= '0'; arready <= '0';
        if not aw_have and not b_pend and awvalid = '1' and awready = '0' and not stall then awready <= '1'; end if;
        if not w_have and not b_pend and wvalid = '1' and wready = '0' and not stall then wready <= '1'; end if;
        if not r_pend and arvalid = '1' and arready = '0' and not stall then arready <= '1'; end if;
        cur_pos_o <= cur_pos; n_go_o <= ngo;
      end if;
    end if;
  end process;
end architecture;
