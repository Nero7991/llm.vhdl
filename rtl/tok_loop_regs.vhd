-- rtl/tok_loop_regs.vhd -- the loop's AXI-Lite control slave (plan 2026-11-04 Task 2):
-- registers, the prompt RAM (PROMPT_ADDR/PROMPT_DATA), the OUT ring (OUT_ADDR/OUT_DATA,
-- read non-destructively, plan D10) and the host row RAM (ROW_ADDR/ROW_DATA). Config is
-- presented live on `cfg`; tok_loop_fsm latches what it must at START.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.tok_loop_pkg.all;

entity tok_loop_regs is
  generic(N_EMBD : positive := 4096; PROMPT_MAX : positive := 4096;
          OUT_DEPTH : positive := 1024; CAPS : std_logic_vector(31 downto 0) := x"00000000");
  port(
    clk, rst  : in  std_logic;
    s_awaddr  : in  std_logic_vector(15 downto 0);
    s_awvalid : in  std_logic;
    s_awready : out std_logic;
    s_wdata   : in  std_logic_vector(31 downto 0);
    s_wstrb   : in  std_logic_vector(3 downto 0);
    s_wvalid  : in  std_logic;
    s_wready  : out std_logic;
    s_bresp   : out std_logic_vector(1 downto 0);
    s_bvalid  : out std_logic;
    s_bready  : in  std_logic;
    s_araddr  : in  std_logic_vector(15 downto 0);
    s_arvalid : in  std_logic;
    s_arready : out std_logic;
    s_rdata   : out std_logic_vector(31 downto 0);
    s_rresp   : out std_logic_vector(1 downto 0);
    s_rvalid  : out std_logic;
    s_rready  : in  std_logic;
    cfg       : out tl_cfg_t;
    st        : in  tl_stat_t;
    lnk       : in  tl_lnk_t;
    pr_addr   : in  unsigned(11 downto 0);
    pr_data   : out unsigned(31 downto 0);
    out_we    : in  std_logic;
    out_waddr : in  unsigned(15 downto 0);
    out_wdata : in  std_logic_vector(31 downto 0);
    hr_addr   : in  unsigned(12 downto 0);
    hr_data   : out std_logic_vector(15 downto 0));
end entity;

architecture rtl of tok_loop_regs is
  type pram_t is array (0 to PROMPT_MAX-1) of std_logic_vector(31 downto 0);
  type oram_t is array (0 to OUT_DEPTH-1) of std_logic_vector(31 downto 0);
  type hram_t is array (0 to N_EMBD-1) of std_logic_vector(15 downto 0);
  signal pram : pram_t;
  signal oram : oram_t;
  signal hram : hram_t;
  signal c : tl_cfg_t := TL_CFG_RESET;
  signal paddr, raddr : unsigned(12 downto 0) := (others => '0');
  signal oaddr : unsigned(31 downto 0) := (others => '0');
  signal bv, rv, rph : std_logic := '0';
  signal ra : natural range 0 to 65535 := 0;
  signal p_q, o_q, rdata_r : std_logic_vector(31 downto 0) := (others => '0');
  signal w_go : std_logic;
  -- OUT_DEPTH must be a power of two no larger than 65536: the FSM writes slot n_gen(15:0)
  -- mod OUT_DEPTH and the host reads OUT_ADDR mod OUT_DEPTH, which agree across the 16-bit
  -- wrap only then. A violation is an out-of-range constant: elaboration fails.
  function pow2_bad(n : positive) return natural is
    variable k : positive := 1;
  begin
    while k < n loop k := 2 * k; end loop;
    if k = n and n <= 65536 then return 0; end if;
    return 1;
  end function;
  constant OUT_DEPTH_POW2 : natural range 0 to 0 := pow2_bad(OUT_DEPTH);
begin
  cfg <= c;
  w_go <= s_awvalid and s_wvalid and not bv;
  s_awready <= w_go;  s_wready <= w_go;
  s_bvalid <= bv;     s_bresp <= "00";
  s_arready <= '1' when rph = '0' and rv = '0' else '0';
  s_rvalid <= rv;     s_rresp <= "00";  s_rdata <= rdata_r;

  -- the FSM's ports into the three RAMs (registered read: one cycle)
  fsm_side : process(clk)
  begin
    if rising_edge(clk) then
      pr_data <= unsigned(pram(to_integer(pr_addr) mod PROMPT_MAX));
      hr_data <= hram(to_integer(hr_addr) mod N_EMBD);
      if out_we = '1' then oram(to_integer(out_waddr) mod OUT_DEPTH) <= out_wdata; end if;
    end if;
  end process;

  bus_side : process(clk)
    variable a : natural;
    variable d, rvv : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      c.start <= '0'; c.abort <= '0'; c.resend <= '0'; c.row_ready <= '0'; c.clear <= '0';
      if st.tok_take = '1' then c.next_tok_v <= '0'; end if;
      if bv = '1' and s_bready = '1' then bv <= '0'; end if;
      if rv = '1' and s_rready = '1' then rv <= '0'; end if;
      if rst = '1' then
        c <= TL_CFG_RESET; bv <= '0'; rv <= '0'; rph <= '0';
        paddr <= (others => '0'); raddr <= (others => '0'); oaddr <= (others => '0');
      else
        -- ---- writes ----
        if w_go = '1' then
          bv <= '1';
          a := to_integer(unsigned(s_awaddr(15 downto 2))) * 4;
          d := s_wdata;
          case a is
            when TL_CTRL =>
              c.start <= d(0); c.abort <= d(1); c.resend <= d(2); c.row_ready <= d(3); c.clear <= d(4);
              if d(0) = '1' and st.state /= 1 then
                -- finding 14: link_credit cleared alongside out_ack/next_tok_v, or a rerun
                -- without the host rewriting it could let A outrun B (Review Focus 5)
                c.out_ack <= (others => '0'); c.next_tok_v <= '0'; c.link_credit <= (others => '0');
              end if;
            when TL_PROMPT_LEN   => c.prompt_len <= unsigned(d);
            when TL_MAX_NEW      => c.max_new <= unsigned(d);
            when TL_ROW_SRC      => c.row_src <= unsigned(d(1 downto 0));
            when TL_ROLE         => c.role <= unsigned(d(1 downto 0));
            when TL_TMO_ENGINE   => c.tmo_engine <= unsigned(d);
            when TL_TMO_LINK     => c.tmo_link <= unsigned(d);
            when TL_RESEND_CAP   => c.resend_cap <= unsigned(d);
            when TL_NEXT_TOKEN   => c.next_tok <= unsigned(d); c.next_tok_v <= '1';
            when TL_ROW_EXP      => c.row_exp <= d;
            when TL_ROW_ADDR     => raddr <= unsigned(d(12 downto 0));
            when TL_ROW_DATA     =>
              hram(to_integer(raddr) mod N_EMBD) <= d(15 downto 0); raddr <= raddr + 1;
            when TL_PROMPT_ADDR  => paddr <= unsigned(d(12 downto 0));
            when TL_PROMPT_DATA  =>
              pram(to_integer(paddr) mod PROMPT_MAX) <= d; paddr <= paddr + 1;
            when TL_OUT_ACK      =>                    -- clamped: an ack past N_GEN would wrap
              if unsigned(d) > st.n_gen then c.out_ack <= st.n_gen; else c.out_ack <= unsigned(d); end if;
            when TL_OUT_ADDR     => oaddr <= unsigned(d);
            when TL_LINK_CREDIT  => c.link_credit <= unsigned(d);
            when TL_LINK_CTRL    => c.link_ctrl <= d;
            when TL_EMB_BASE_LO  => c.emb_base(31 downto 0) <= unsigned(d);
            when TL_EMB_BASE_HI  => c.emb_base(32) <= d(0);
            when others =>
              if a >= TL_STOP_ID0 and a < TL_STOP_ID0 + 32 then
                c.stop_id((a - TL_STOP_ID0) / 4) <= d;
              end if;
          end case;
        end if;
        -- ---- reads: accept, then answer one cycle later (RAM latency) ----
        if rph = '0' then
          if s_arvalid = '1' and rv = '0' then
            ra  <= to_integer(unsigned(s_araddr(15 downto 2))) * 4;
            p_q <= pram(to_integer(paddr) mod PROMPT_MAX);
            o_q <= oram(to_integer(oaddr(15 downto 0)) mod OUT_DEPTH);
            rph <= '1';
          end if;
        else
          rvv := (others => '0');
          case ra is
            when TL_ID          => rvv := TL_ID_MAGIC;
            when TL_VERSION     => rvv := x"00000001";
            when TL_CAPS        => rvv := CAPS;
            when TL_STATUS      =>
              rvv(1 downto 0) := std_logic_vector(st.state);
              rvv(2) := st.need_row;  rvv(3) := st.need_token;
              rvv(4) := lnk.status(LS_PAUSED);  rvv(5) := lnk.status(LS_BAD);
              rvv(6) := lnk.status(LS_DOWN);    rvv(7) := st.out_full;
              rvv(15 downto 8) := std_logic_vector(st.reason);
              rvv(16) := st.owns;  rvv(17) := st.tx_wait;  rvv(18) := st.link_wait;
            when TL_POS          => rvv := std_logic_vector(st.pos);
            when TL_N_GEN | TL_OUT_COUNT => rvv := std_logic_vector(st.n_gen);
            when TL_PROMPT_LEN   => rvv := std_logic_vector(c.prompt_len);
            when TL_MAX_NEW      => rvv := std_logic_vector(c.max_new);
            when TL_ROW_SRC      => rvv(1 downto 0) := std_logic_vector(c.row_src);
            when TL_ROLE         => rvv(1 downto 0) := std_logic_vector(c.role);
            when TL_TMO_ENGINE   => rvv := std_logic_vector(c.tmo_engine);
            when TL_TMO_LINK     => rvv := std_logic_vector(c.tmo_link);
            when TL_RESEND_CAP   => rvv := std_logic_vector(c.resend_cap);
            when TL_ERR_ADDR     => rvv := st.err_addr;
            when TL_ERR_STATUS   => rvv := st.err_status;
            when TL_ERR_INFO     => rvv := st.err_info;
            when TL_ROW_TOK      => rvv := std_logic_vector(st.row_tok);
            when TL_NEXT_TOKEN   => rvv := std_logic_vector(c.next_tok);
            when TL_ROW_EXP      => rvv := c.row_exp;
            when TL_ROW_ADDR     => rvv(12 downto 0) := std_logic_vector(raddr);
            when TL_PROMPT_ADDR  => rvv(12 downto 0) := std_logic_vector(paddr);
            when TL_PROMPT_DATA  => rvv := p_q; paddr <= paddr + 1;
            when TL_OUT_ACK      => rvv := std_logic_vector(c.out_ack);
            when TL_OUT_ADDR     => rvv := std_logic_vector(oaddr);
            when TL_OUT_DATA     => rvv := o_q; oaddr <= oaddr + 1;
            when TL_LAST_ARGMAX  => rvv := st.last_argmax;
            when TL_LINK_CREDIT  => rvv := std_logic_vector(c.link_credit);
            when TL_LINK_CONSUMED=> rvv := std_logic_vector(lnk.consumed);
            when TL_LINK_CTRL    => rvv := c.link_ctrl;
            when TL_LINK_STATUS  => rvv := lnk.status;
            when TL_FRAMES_SENT  => rvv := std_logic_vector(lnk.frames_sent);
            when TL_FRAMES_GOOD  => rvv := std_logic_vector(lnk.frames_good);
            when TL_CRC_FAILS    => rvv := std_logic_vector(lnk.crc_fails);
            when TL_SEQPOS_BAD   => rvv := std_logic_vector(lnk.seqpos_bad);
            when TL_LINK_DOWNS   => rvv := std_logic_vector(lnk.link_downs);
            when TL_RESENDS      => rvv := std_logic_vector(lnk.resends);
            when TL_OVERRUNS     => rvv := std_logic_vector(lnk.overruns);
            when TL_EMB_BASE_LO  => rvv := std_logic_vector(c.emb_base(31 downto 0));
            when TL_EMB_BASE_HI  => rvv(0) := c.emb_base(32);
            when TL_POS_CYCLES   => rvv := std_logic_vector(st.pos_cycles);
            when TL_KVMAX        => rvv := std_logic_vector(st.kvmax);
            when others =>
              if ra >= TL_STOP_ID0 and ra < TL_STOP_ID0 + 32 then
                rvv := c.stop_id((ra - TL_STOP_ID0) / 4);
              end if;
          end case;
          rdata_r <= rvv; rv <= '1'; rph <= '0';
        end if;
      end if;
    end if;
  end process;
end architecture;
