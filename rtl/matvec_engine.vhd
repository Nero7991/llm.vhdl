-- rtl/matvec_engine.vhd -- Autonomous matvec engine (AXI4-Lite peripheral).
--
-- Computes y[i] = sum_j WQ_L0[i][j] * x[j]  for i in 0..OUT_DIM-1, where the
-- weight mantissas WQ_L0 live in an on-chip ROM (rtl/wq_l0_rom_pkg.vhd, no
-- TEXTIO) and the activation vector x[0..IN_DIM-1] is loaded over AXI.
--
-- One time-multiplexed mac_array (N=IN_DIM, P=1, WW=XW=16, AW=48) is reused
-- across all OUT_DIM rows.  An internal FSM walks the rows, drives the
-- mac_array with the loaded activations and the ROM row, waits for `done`,
-- and latches the accumulator into acc_store[i].
--
-- The mac_array publishes its final `acc` in the SAME delta as `done` (its own
-- comment: a combinational acc<=accr would lag one delta and drop the last
-- chunk).  So we sample `acc` on the cycle `mac_done='1'` -- see S_WAIT below.
--
-- Register map (C_S_AXI_ADDR_WIDTH=8, word-addressed reg = addr[7:2]):
--   0x00 CTRL     : write bit0=1 -> START a full matvec pass
--   0x04 STATUS   : read  bit0=done (all rows latched), bit1=busy
--   0x08 DIMS     : read  {OUT_DIM[31:16], IN_DIM[15:0]}
--   0x0C LOAD_IDX : write activation write index (0..IN_DIM-1)
--   0x10 LOAD_ACT : write x[LOAD_IDX] = wdata[15:0] (int16)
--   0x14 ROW_IDX  : write output-row select for ACC read-back (0..OUT_DIM-1)
--   0x18 ACC_LO   : read  acc_store[ROW_IDX][31:0]
--   0x1C ACC_HI   : read  sign-extended acc_store[ROW_IDX][47:32]
--   0x20 ID       : read  0x6D415631  ("mAV1")
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;
use work.wq_l0_rom_pkg.all;
entity matvec_engine is
  generic(OUT_DIM:positive:=64; IN_DIM:positive:=64;
          WW:positive:=16; XW:positive:=16; AW:positive:=48;
          C_S_AXI_DATA_WIDTH:integer:=32; C_S_AXI_ADDR_WIDTH:integer:=8);
  port(
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;
    s_axi_awaddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_awprot  : in  std_logic_vector(2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    s_axi_wstrb   : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_arprot  : in  std_logic_vector(2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic);
end;
architecture rtl of matvec_engine is
  -- AXI handshake regs
  signal awready,wready,bvalid,arready,rvalid : std_logic := '0';
  signal rdata_r : std_logic_vector(31 downto 0) := (others=>'0');
  signal wr_addr : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);

  -- activation store
  type i16arr is array(0 to IN_DIM-1) of signed(15 downto 0);
  signal act_store : i16arr := (others=>(others=>'0'));
  signal load_idx  : integer range 0 to IN_DIM-1 := 0;
  signal row_idx   : integer range 0 to OUT_DIM-1 := 0;

  -- accumulator store (one int48 per output row)
  type accarr is array(0 to OUT_DIM-1) of std_logic_vector(AW-1 downto 0);
  signal acc_store : accarr := (others=>(others=>'0'));

  -- control / status
  signal start_pulse : std_logic := '0';
  signal status_done : std_logic := '0';

  -- FSM
  type state_t is (S_IDLE, S_START, S_WAIT, S_DONE);
  signal state   : state_t := S_IDLE;
  signal cur_row : integer range 0 to OUT_DIM-1 := 0;

  -- mac_array interface
  signal mac_start, mac_done : std_logic := '0';
  signal mac_acc : std_logic_vector(AW-1 downto 0);
  signal x_vec : std_logic_vector(IN_DIM*XW-1 downto 0);
  signal w_row : std_logic_vector(IN_DIM*WW-1 downto 0);
begin
  s_axi_awready<=awready; s_axi_wready<=wready; s_axi_bvalid<=bvalid; s_axi_bresp<="00";
  s_axi_arready<=arready; s_axi_rvalid<=rvalid; s_axi_rresp<="00"; s_axi_rdata<=rdata_r;

  -- pack the loaded activations into the mac_array x_vec (stable across a pass)
  gpack_x: for j in 0 to IN_DIM-1 generate
    x_vec((j+1)*XW-1 downto j*XW) <= std_logic_vector(act_store(j));
  end generate;

  -- drive w_row from the ROM row selected by cur_row (combinational ROM mux)
  gpack_w: for j in 0 to IN_DIM-1 generate
    w_row((j+1)*WW-1 downto j*WW) <=
      std_logic_vector(to_signed(WQ_L0(cur_row*IN_DIM + j), WW));
  end generate;

  mac: entity work.mac_array
    generic map(N=>IN_DIM, P=>1, WW=>WW, XW=>XW, AW=>AW)
    port map(clk=>s_axi_aclk, rst=>not s_axi_aresetn, start=>mac_start,
             x_vec=>x_vec, w_row=>w_row, done=>mac_done, acc=>mac_acc);

  -- ------------------------------------------------------------------
  -- AXI write channel (address+data accepted together, like mac_axi)
  -- ------------------------------------------------------------------
  process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      start_pulse <= '0';
      if s_axi_aresetn='0' then
        awready<='0'; wready<='0'; bvalid<='0';
      else
        if awready='0' and s_axi_awvalid='1' and s_axi_wvalid='1' then
          awready<='1'; wready<='1'; wr_addr<=s_axi_awaddr;
        else awready<='0'; wready<='0'; end if;

        if awready='1' and wready='1' then
          case to_integer(unsigned(wr_addr(7 downto 2))) is
            when 0 => if s_axi_wdata(0)='1' then start_pulse<='1'; end if;      -- CTRL START
            when 3 => load_idx <= to_integer(unsigned(s_axi_wdata(clog2(IN_DIM)-1 downto 0)));  -- LOAD_IDX
            when 4 => act_store(load_idx) <= signed(s_axi_wdata(15 downto 0));  -- LOAD_ACT
            when 5 => row_idx  <= to_integer(unsigned(s_axi_wdata(clog2(OUT_DIM)-1 downto 0))); -- ROW_IDX
            when others => null;
          end case;
          bvalid<='1';
        elsif bvalid='1' and s_axi_bready='1' then
          bvalid<='0';
        end if;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- Matvec FSM: reuse one mac_array across OUT_DIM rows
  -- ------------------------------------------------------------------
  process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      mac_start <= '0';
      if s_axi_aresetn='0' then
        state<=S_IDLE; cur_row<=0; status_done<='0';
      else
        case state is
          when S_IDLE =>
            if start_pulse='1' then
              cur_row     <= 0;
              status_done <= '0';
              state       <= S_START;
            end if;

          when S_START =>
            -- w_row is now valid for cur_row; kick the mac (1-cycle pulse).
            mac_start <= '1';
            state     <= S_WAIT;

          when S_WAIT =>
            -- Sample acc in the SAME cycle done pulses (mac_array publishes the
            -- final sum with done; a later sample would read the next state).
            if mac_done='1' then
              acc_store(cur_row) <= mac_acc;
              if cur_row = OUT_DIM-1 then
                state <= S_DONE;
              else
                cur_row <= cur_row + 1;
                state   <= S_START;
              end if;
            end if;

          when S_DONE =>
            status_done <= '1';
            state       <= S_IDLE;
        end case;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- AXI read channel
  -- ------------------------------------------------------------------
  process(s_axi_aclk)
    variable busy_v : std_logic;
    variable acc_sel : std_logic_vector(AW-1 downto 0);
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn='0' then arready<='0'; rvalid<='0';
      else
        if arready='0' and s_axi_arvalid='1' then
          arready<='1';
          if state=S_IDLE then busy_v:='0'; else busy_v:='1'; end if;
          acc_sel := acc_store(row_idx);
          case to_integer(unsigned(s_axi_araddr(7 downto 2))) is
            when 1 => rdata_r <= (31 downto 2 => '0') & busy_v & status_done;   -- STATUS
            when 2 => rdata_r <= std_logic_vector(to_unsigned(OUT_DIM,16))
                                 & std_logic_vector(to_unsigned(IN_DIM,16));    -- DIMS
            when 3 => rdata_r <= std_logic_vector(to_unsigned(load_idx,32));    -- LOAD_IDX
            when 5 => rdata_r <= std_logic_vector(to_unsigned(row_idx,32));     -- ROW_IDX
            when 6 => rdata_r <= acc_sel(31 downto 0);                          -- ACC_LO
            when 7 => rdata_r <= std_logic_vector(resize(signed(acc_sel(AW-1 downto 32)),32)); -- ACC_HI
            when 8 => rdata_r <= x"6D415631";                                   -- ID "mAV1"
            when others => rdata_r <= (others=>'0');
          end case;
        else arready<='0'; end if;
        if arready='1' then rvalid<='1';
        elsif rvalid='1' and s_axi_rready='1' then rvalid<='0'; end if;
      end if;
    end if;
  end process;
end;
