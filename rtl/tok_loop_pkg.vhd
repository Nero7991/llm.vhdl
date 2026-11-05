-- rtl/tok_loop_pkg.vhd -- offsets, reasons and records for the on-fabric token loop
-- (plan 2026-11-04-jc-on-fabric-loop-and-link, Task 2). Seam offsets are
-- server/fk33_seam.h:238-377 = rtl/fk33_seam.vhd:365-479; the loop map is the plan's table.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package tok_loop_pkg is
  -- the seam (12-bit offsets)
  constant SM_CTRL      : natural := 16#14#;
  constant SM_STATUS    : natural := 16#18#;
  constant SM_ERR_INFO  : natural := 16#1C#;
  constant SM_SEQ_POS   : natural := 16#20#;
  constant SM_N_STEP    : natural := 16#24#;
  constant SM_ARGMAX    : natural := 16#44#;
  constant SM_X_EXP     : natural := 16#54#;
  constant SM_WIN_SEL   : natural := 16#58#;
  constant SM_WIN_ADDR  : natural := 16#5C#;
  constant SM_WIN_DATA  : natural := 16#60#;
  constant SM_TOK_POS   : natural := 16#8C#;
  constant SM_KV_MAXPOS : natural := 16#A0#;
  constant SM_XEXP_OUT  : natural := 16#A4#;
  constant CTRL_GO        : natural := 1;
  constant CTRL_SEQ_RESET : natural := 2;
  constant WIN_XIN        : natural := 2;
  constant WIN_XOUT       : natural := 3;

  -- the loop (16-bit offsets)
  constant TL_ID           : natural := 16#000#;
  constant TL_VERSION      : natural := 16#004#;
  constant TL_CAPS         : natural := 16#008#;
  constant TL_CTRL         : natural := 16#00C#;
  constant TL_STATUS       : natural := 16#010#;
  constant TL_POS          : natural := 16#014#;
  constant TL_N_GEN        : natural := 16#018#;
  constant TL_PROMPT_LEN   : natural := 16#01C#;
  constant TL_MAX_NEW      : natural := 16#020#;
  constant TL_ROW_SRC      : natural := 16#024#;
  constant TL_ROLE         : natural := 16#028#;
  constant TL_TMO_ENGINE   : natural := 16#02C#;
  constant TL_TMO_LINK     : natural := 16#030#;
  constant TL_RESEND_CAP   : natural := 16#034#;
  constant TL_ERR_ADDR     : natural := 16#038#;
  constant TL_ERR_STATUS   : natural := 16#03C#;
  constant TL_ERR_INFO     : natural := 16#040#;
  constant TL_ROW_TOK      : natural := 16#044#;
  constant TL_NEXT_TOKEN   : natural := 16#048#;
  constant TL_ROW_EXP      : natural := 16#04C#;
  constant TL_ROW_ADDR     : natural := 16#050#;
  constant TL_ROW_DATA     : natural := 16#054#;
  constant TL_PROMPT_ADDR  : natural := 16#058#;
  constant TL_PROMPT_DATA  : natural := 16#05C#;
  constant TL_OUT_COUNT    : natural := 16#060#;
  constant TL_OUT_ACK      : natural := 16#064#;
  constant TL_OUT_ADDR     : natural := 16#068#;
  constant TL_OUT_DATA     : natural := 16#06C#;
  constant TL_LAST_ARGMAX  : natural := 16#070#;
  constant TL_LINK_CREDIT  : natural := 16#074#;
  constant TL_LINK_CONSUMED: natural := 16#078#;
  constant TL_LINK_CTRL    : natural := 16#07C#;
  constant TL_LINK_STATUS  : natural := 16#080#;
  constant TL_FRAMES_SENT  : natural := 16#084#;
  constant TL_FRAMES_GOOD  : natural := 16#088#;
  constant TL_CRC_FAILS    : natural := 16#08C#;
  constant TL_SEQPOS_BAD   : natural := 16#090#;
  constant TL_LINK_DOWNS   : natural := 16#094#;
  constant TL_RESENDS      : natural := 16#098#;
  constant TL_OVERRUNS     : natural := 16#09C#;
  constant TL_EMB_BASE_LO  : natural := 16#0A0#;
  constant TL_EMB_BASE_HI  : natural := 16#0A4#;
  constant TL_POS_CYCLES   : natural := 16#0A8#;
  constant TL_KVMAX        : natural := 16#0AC#;
  constant TL_STOP_ID0     : natural := 16#0C0#;
  constant TL_ID_MAGIC     : std_logic_vector(31 downto 0) := x"544C5031";

  constant R_NONE : natural := 0;            constant R_MAX_NEW : natural := 1;
  constant R_STOP_ID : natural := 2;         constant R_MAXPOS : natural := 3;
  constant R_ABORT : natural := 4;           constant R_ENGINE_ERR : natural := 5;
  constant R_ENGINE_TIMEOUT : natural := 6;  constant R_SEAM_ERR : natural := 7;
  constant R_LINK_TIMEOUT : natural := 8;    constant R_LINK_RETRY_EXHAUSTED : natural := 9;
  constant R_BAD_CONFIG : natural := 10;     constant R_SEQ_RESET_FAIL : natural := 11;
  constant R_GATHER_ERR : natural := 12;

  constant ROLE_SINGLE : natural := 0;  constant ROLE_A : natural := 1;  constant ROLE_B : natural := 2;
  constant SRC_GATHER  : natural := 0;  constant SRC_HOST : natural := 1; constant SRC_LINK : natural := 2;

  constant LS_TX_UP : natural := 0;   constant LS_RX_UP : natural := 1;
  constant LS_GTG_LOCK : natural := 2; constant LS_PLL_LOCK : natural := 3;
  constant LS_PAUSED : natural := 8;  constant LS_BAD : natural := 9;
  constant LS_DOWN : natural := 10;   constant LS_TX_EXH : natural := 11;
  constant LS_RX_OVF : natural := 12;

  constant TMO_DEFAULT : natural := 180000000;   -- plan D13

  type slv32_arr8 is array (0 to 7) of std_logic_vector(31 downto 0);
  type tl_cfg_t is record
    prompt_len, max_new : unsigned(31 downto 0);
    row_src, role       : unsigned(1 downto 0);
    tmo_engine, tmo_link, resend_cap : unsigned(31 downto 0);
    stop_id             : slv32_arr8;
    start, abort, resend, row_ready, clear : std_logic;
    next_tok            : unsigned(31 downto 0);
    next_tok_v          : std_logic;
    row_exp             : std_logic_vector(31 downto 0);
    out_ack, link_credit : unsigned(31 downto 0);
    link_ctrl           : std_logic_vector(31 downto 0);
    emb_base            : unsigned(32 downto 0);
  end record;
  type tl_stat_t is record
    state               : unsigned(1 downto 0);
    reason              : unsigned(7 downto 0);
    pos, n_gen          : unsigned(31 downto 0);
    need_row, need_token, out_full, owns, tx_wait, link_wait, tok_take : std_logic;
    err_addr, err_status, err_info, last_argmax : std_logic_vector(31 downto 0);
    row_tok, pos_cycles, kvmax : unsigned(31 downto 0);
    row_src, role       : unsigned(1 downto 0);
  end record;
  type tl_lnk_t is record
    frames_sent, frames_good, crc_fails, seqpos_bad : unsigned(31 downto 0);
    link_downs, resends, overruns, consumed : unsigned(31 downto 0);
    status              : std_logic_vector(31 downto 0);
  end record;

  constant TL_CFG_RESET : tl_cfg_t := (
    prompt_len => (others => '0'), max_new => (others => '0'),
    row_src => "00", role => "00",
    tmo_engine => to_unsigned(TMO_DEFAULT, 32), tmo_link => to_unsigned(TMO_DEFAULT, 32),
    resend_cap => to_unsigned(3, 32),
    stop_id => (others => x"FFFFFFFF"),
    start => '0', abort => '0', resend => '0', row_ready => '0', clear => '0',
    next_tok => (others => '0'), next_tok_v => '0', row_exp => (others => '0'),
    out_ack => (others => '0'), link_credit => (others => '0'),
    link_ctrl => (others => '0'), emb_base => (others => '0'));
  constant TL_LNK_ZERO : tl_lnk_t := (
    frames_sent => (others => '0'), frames_good => (others => '0'),
    crc_fails => (others => '0'), seqpos_bad => (others => '0'),
    link_downs => (others => '0'), resends => (others => '0'),
    overruns => (others => '0'), consumed => (others => '0'), status => (others => '0'));

  function tl_u32(n : natural) return std_logic_vector;
end package;

package body tok_loop_pkg is
  function tl_u32(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n, 32));
  end function;
end package body;
