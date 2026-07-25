-- sim/sw_chain.vhd
-- Standalone wrapper for the FFN swiglu -> vec_mem(BRAM) -> bfp_pack chain,
-- wired EXACTLY as engine_shared.vhd (u_sw / u_swmem / u_hbpack) with a tiny
-- controller FSM that reproduces engine_shared's L_SW_S/L_SW_W/L_HBPACK_S/
-- L_HBPACK_W sequencing (pulse sw_start -> wait sw_done -> pulse hbp_start ->
-- wait hbp_done -> assert done).
--
-- All top ports are std_logic / std_logic_vector ONLY (no integer ports) so
-- write_vhdl -mode funcsim leaves the port signature untouched and the netlist
-- can be compared directly against this same wrapper compiled behaviorally.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;   -- clog2

entity sw_chain is
  generic(N : positive := 172; Q : integer := 12);
  port(
    clk, rst, start : in  std_logic;
    hb_mant  : in  std_logic_vector(N*16-1 downto 0);
    hb_exp   : in  std_logic_vector(31 downto 0);
    hb2_mant : in  std_logic_vector(N*16-1 downto 0);
    hb2_exp  : in  std_logic_vector(31 downto 0);
    done     : out std_logic;
    o_mant   : out std_logic_vector(N*16-1 downto 0);
    o_exp    : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of sw_chain is
  signal sw_start   : std_logic := '0';
  signal sw_done    : std_logic;
  signal sw_o_we    : std_logic;
  signal sw_o_waddr : std_logic_vector(clog2(N)-1 downto 0);
  signal sw_o_wdata : std_logic_vector(31 downto 0);
  signal hbp_raddr  : std_logic_vector(clog2(N)-1 downto 0);
  signal vm_dout    : std_logic_vector(31 downto 0);
  signal hbp_start  : std_logic := '0';
  signal hbp_done   : std_logic;
  signal hbp_o_exp_i: integer;
  signal hb_exp_i   : integer;
  signal hb2_exp_i  : integer;
  type cstate_t is (C_IDLE, C_SW_S, C_SW_W, C_HB_S, C_HB_W);
  signal cstate : cstate_t := C_IDLE;
begin
  hb_exp_i  <= to_integer(signed(hb_exp));
  hb2_exp_i <= to_integer(signed(hb2_exp));

  u_sw: entity work.swiglu
    generic map(N => N, Q => Q)
    port map(clk => clk, rst => rst, start => sw_start,
             hb_mant => hb_mant, hb_exp => hb_exp_i,
             hb2_mant => hb2_mant, hb2_exp => hb2_exp_i,
             done => sw_done, out_q => open,
             o_we => sw_o_we, o_waddr => sw_o_waddr, o_wdata => sw_o_wdata);

  u_swmem: entity work.vec_mem
    generic map(WORDS => N, W => 32)
    port map(clk => clk, we => sw_o_we,
             waddr => sw_o_waddr, raddr => hbp_raddr,
             din => sw_o_wdata, dout => vm_dout);

  u_hbpack: entity work.bfp_pack
    generic map(N => N, Q => Q)
    port map(clk => clk, rst => rst, start => hbp_start,
             o_raddr => hbp_raddr, i_rdata => vm_dout, done => hbp_done,
             o_mant => o_mant, o_exp => hbp_o_exp_i);

  o_exp <= std_logic_vector(to_signed(hbp_o_exp_i, 32));

  -- Controller: mirrors engine_shared's swiglu->bfp_pack handoff exactly.
  process(clk) begin
    if rising_edge(clk) then
      sw_start  <= '0';
      hbp_start <= '0';
      done      <= '0';
      if rst = '1' then
        cstate <= C_IDLE;
      else
        case cstate is
          when C_IDLE => if start = '1' then cstate <= C_SW_S; end if;
          when C_SW_S => sw_start <= '1'; cstate <= C_SW_W;
          when C_SW_W => if sw_done = '1' then cstate <= C_HB_S; end if;
          when C_HB_S => hbp_start <= '1'; cstate <= C_HB_W;
          when C_HB_W => if hbp_done = '1' then done <= '1'; cstate <= C_IDLE; end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
