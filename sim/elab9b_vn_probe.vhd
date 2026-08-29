-- sim/elab9b_vn_probe.vhd -- TRACK REALSHAPE, 2026-08-29.
--
-- NOT a `tb_*.vhd`, deliberately.  `sim/regress.sh` auto-discovers `tb_*.vhd`
-- into the shared gate; this file is a one-question probe run by
-- `sim/elab9b_run.sh` and it must not become a gate row.
--
-- THE ONE QUESTION.  `rtl/llama_top.vhd`'s D-vec element-count width `VN_W`
-- defaults to 13, so `rtl/seq_vec_issue.vhd:376` refuses any D-vec job with
-- `n_rows >= 2**13 = 8192`.  The 9B schedule's `OP_VEC_SWG` step carries
-- `n_rows => s.ffn` (sim/llama_sched_pkg.vhd:238), and `MODEL.ffn` is 12288.
-- Every published measurement of the composed top level is at
-- `mk_shape_scaled`, whose ffn is 128, so this has never been reachable.
--
-- The probe issues ONE `OP_VEC_SWG` job at `MODEL.ffn` rows, at VN_W = 13 and
-- again at the smallest width that admits it, and reports `err_code`.  x"2" is
-- `EC_NROWS` (rtl/seq_vec_issue.vhd:220).  The count comes from
-- `model_cfg_pkg`, not from a literal, so it follows a retarget.
--
-- It is a RUN-TIME check, which is the finding: nothing refuses this
-- combination at elaboration, so the real shape elaborates clean and then
-- errors on the first FFN of the first block.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.llama_map_pkg.all;

entity elab9b_vn_probe is
  generic(
    VN_W  : positive := 13;   -- llama_top's default
    NROWS : natural  := 0     -- 0 = use MODEL.ffn
  );
end entity;

architecture tb of elab9b_vn_probe is
  function pick(n : natural) return natural is
  begin
    if n = 0 then return MODEL.ffn; else return n; end if;
  end function;
  constant N : natural := pick(NROWS);

  constant EXP_W   : positive := 16;
  constant EPOCH_W : positive := 4;
  constant STEP_W  : positive := 11;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal run : boolean := true;

  signal job_issue : std_logic := '0';
  signal job_unit   : unsigned(2 downto 0) := to_unsigned(U_V, 3);
  signal job_opcode : unsigned(3 downto 0) := to_unsigned(OP_VEC_SWG, 4);
  signal job_epoch  : unsigned(EPOCH_W-1 downto 0) := (others => '0');
  signal job_src    : unsigned(7 downto 0) := to_unsigned(R_G, 8);
  signal job_src2   : unsigned(7 downto 0) := to_unsigned(R_U, 8);
  signal job_dst    : unsigned(7 downto 0) := to_unsigned(R_H, 8);
  signal job_dst_off: unsigned(31 downto 0) := (others => '0');
  signal job_n_rows : unsigned(31 downto 0) := (others => '0');
  signal job_step   : unsigned(STEP_W-1 downto 0) := (others => '0');

  signal u_start, u_ack : std_logic := '0';
  signal u_ready, u_done, u_err : std_logic;
  signal u_done_epoch : unsigned(EPOCH_W-1 downto 0);
  signal u_y_exp : signed(EXP_W-1 downto 0);

  signal exp_rd_region : unsigned(7 downto 0);
  signal exp_rd_seg    : unsigned(1 downto 0);
  signal exp_rd_data   : signed(EXP_W-1 downto 0) := to_signed(12, EXP_W);
  signal exp_rd_valid  : std_logic := '1';

  signal v_start : std_logic_vector(NVOP-1 downto 0);
  signal v_ready : std_logic_vector(NVOP-1 downto 0) := (others => '1');
  signal v_taken : std_logic_vector(NVOP-1 downto 0) := (others => '0');
  signal v_done  : std_logic_vector(NVOP-1 downto 0) := (others => '0');
  signal v_ack   : std_logic_vector(NVOP-1 downto 0);
  signal v_err   : std_logic_vector(NVOP-1 downto 0) := (others => '0');
  signal v_y_exp : std_logic_vector(NVOP*EXP_W-1 downto 0) := (others => '0');
  signal v_n     : unsigned(VN_W-1 downto 0);
  signal v_exp_a, v_exp_b : signed(EXP_W-1 downto 0);
  signal v_reg_a, v_reg_b, v_reg_d : unsigned(7 downto 0);
  signal err_code : std_logic_vector(3 downto 0);
begin
  clk <= (not clk) after 5 ns when run else '0';

  dut : entity work.seq_vec_issue
    generic map(NVOP => NVOP, OP_BASE => OP_VEC_NORM, MY_UNIT => U_V,
                NREG => NREGION, EXP_W => EXP_W, VN_W => VN_W,
                EPOCH_W => EPOCH_W, STEP_W => STEP_W, STRICT => false)
    port map(clk => clk, rst => rst,
             job_issue => job_issue, job_unit => job_unit,
             job_opcode => job_opcode, job_epoch => job_epoch,
             job_src => job_src, job_src2 => job_src2, job_dst => job_dst,
             job_dst_off => job_dst_off, job_n_rows => job_n_rows,
             job_step => job_step,
             u_start => u_start, u_ack => u_ack, u_ready => u_ready,
             u_done => u_done, u_err => u_err,
             u_done_epoch => u_done_epoch, u_y_exp => u_y_exp,
             exp_rd_region => exp_rd_region, exp_rd_seg => exp_rd_seg,
             exp_rd_data => exp_rd_data, exp_rd_valid => exp_rd_valid,
             v_start => v_start, v_ready => v_ready, v_taken => v_taken,
             v_done => v_done, v_ack => v_ack, v_err => v_err,
             v_y_exp => v_y_exp, v_n => v_n,
             v_exp_a => v_exp_a, v_exp_b => v_exp_b,
             v_reg_a => v_reg_a, v_reg_b => v_reg_b, v_reg_d => v_reg_d,
             iss_lat => open, exp_lat => open, err_code => err_code);

  stim : process
  begin
    report "elab9b_vn_probe: VN_W=" & integer'image(VN_W)
         & "  2**VN_W=" & integer'image(2**VN_W)
         & "  OP_VEC_SWG n_rows=" & integer'image(N)
         & "  (MODEL.ffn=" & integer'image(MODEL.ffn)
         & ", MODEL.hidden=" & integer'image(MODEL.hidden) & ")";
    wait for 40 ns; wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);

    job_n_rows <= to_unsigned(N, 32);
    u_start    <= '1';
    wait until rising_edge(clk);
    job_issue  <= '1';
    wait until rising_edge(clk);
    job_issue  <= '0';
    u_start    <= '0';

    for i in 0 to 9 loop wait until rising_edge(clk); end loop;

    if u_err = '1' and err_code = x"2" then
      report "elab9b_vn_probe: REFUSED, err_code=EC_NROWS(2).  "
           & "A D-vec job of " & integer'image(N)
           & " elements does not fit VN_W=" & integer'image(VN_W) & "."
        severity note;
    elsif u_err = '1' then
      report "elab9b_vn_probe: REFUSED with err_code="
           & integer'image(to_integer(unsigned(err_code)))
        severity note;
    else
      report "elab9b_vn_probe: ACCEPTED.  v_start=" & std_logic'image(v_start(V_SWG))
           & " v_n=" & integer'image(to_integer(v_n))
        severity note;
    end if;

    run <= false;
    wait;
  end process;
end architecture;
