-- rtl/matvec_int4_axi.vhd -- AXI4-Lite control wrapper around matvec_int4.
--
-- Serves §10's bring-up sequence and §11's acceptance criteria:
--   step 4  AXI path in isolation -- the PS writes a blob to DDR, the streamer
--           reads it back, and BEATS/CYCLES here give the achieved GB/s that
--           §4's bandwidth premise depends on
--   step 5  end to end on board -- the PS programs a packed matrix, computes,
--           and compares against ref/matvec_int4.c built for the board's own
--           ARM cores, so no host is involved
--
-- The PS parses the 4 KB header (6.4) and programs the descriptor; nothing in
-- the fabric parses it.  It is read once per matrix on a path with no
-- throughput requirement, and a byte-field parser in RTL would only add a
-- second place for the byte-pinned layout to drift.
--
-- Register map (word-addressed, reg = addr[7:2]):
--   0x00 CTRL      W  bit0 = START
--   0x04 STATUS    R  bit0 done, bit1 busy, bit2 err, bit3 sat_event
--   0x08 N_ROWS    RW
--   0x0C N_COLS    RW    true K (6.3)
--   0x10 OUT_SHIFT RW
--   0x14 W_EXP     RW
--   0x18 X_EXP     RW
--   0x1C OUT_MODE  RW    00 BFP, 01 raw, 10 partial
--   0x20 W_BASE0   RW    sub-region bases from the header (6.4)
--   0x24 W_BASE1   RW
--   0x28 W_BASE2   RW
--   0x2C W_BASE3   RW
--   0x30 W_BEATS   RW    beats per weight sub-region
--   0x34 S_BASE    RW
--   0x38 S_BEATS   RW
--   0x3C CB        W  {idx = wdata[11:8], value = wdata[7:0]}   codebook entry
--   0x40 X_IDX     W  activation write index
--   0x44 X_DATA    W  x[X_IDX] = wdata[15:0], then X_IDX auto-increments, so
--                     loading K activations is K writes rather than 2K
--   0x48 Y_IDX     W  result read index (row)
--   0x4C Y_LO      R  result[Y_IDX][31:0]
--   0x50 Y_HI      R  result[Y_IDX][63:32]   PARTIAL's s48 lives up here (14.2)
--   0x54 Y_EXP     R
--   0x58 CYCLES    R  cycles busy, start to done
--   0x5C BEATS     R  weight words the array actually consumed
--   0x60 STARVED   R  cycles busy with no weight word available
--   0x64 ID        R  0x4D563449 "MV4I"

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity matvec_int4_axi is
  generic(
    BLK         : positive := 32;
    ROWS_IF     : positive := 4;
    NPORTS_W    : positive := 4;
    AXI_DW      : positive := 128;
    ADDR_W      : positive := 32;
    MAXCOLS     : positive := 17408;
    MAXROWS_BFP : positive := 17408;
    FIFO_DEPTH  : positive := 512;
    MAXB        : positive := 256;
    C_S_AXI_DATA_WIDTH : integer := 32;
    C_S_AXI_ADDR_WIDTH : integer := 8
  );
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
    s_axi_rready  : in  std_logic;

    -- AXI4 read masters to DDR (HP ports), flattened
    m_arvalid : out std_logic_vector(NPORTS_W downto 0);
    m_arready : in  std_logic_vector(NPORTS_W downto 0);
    m_araddr  : out std_logic_vector((NPORTS_W+1)*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector((NPORTS_W+1)*8-1 downto 0);
    m_arsize  : out std_logic_vector((NPORTS_W+1)*3-1 downto 0);
    m_arburst : out std_logic_vector((NPORTS_W+1)*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORTS_W downto 0);
    m_rready  : out std_logic_vector(NPORTS_W downto 0);
    m_rdata   : in  std_logic_vector((NPORTS_W+1)*AXI_DW-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORTS_W downto 0)
  );
end entity;

architecture rtl of matvec_int4_axi is
  constant ID_CODE : std_logic_vector(31 downto 0) := x"4D563449";  -- "MV4I"
  constant TILES   : positive := (MAXROWS_BFP + ROWS_IF - 1) / ROWS_IF;

  signal awready, wready, bvalid, arready, rvalid : std_logic := '0';
  signal rdata_r  : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_addr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0)
                    := (others => '0');

  signal rst      : std_logic;
  signal start    : std_logic := '0';
  signal busy     : std_logic := '0';
  signal done_l   : std_logic := '0';

  signal r_rows, r_cols, r_osh, r_wexp, r_xexp : std_logic_vector(31 downto 0)
         := (others => '0');
  signal r_wbeats, r_sbase, r_sbeats : std_logic_vector(31 downto 0)
         := (others => '0');
  signal r_mode  : std_logic_vector(1 downto 0) := "00";
  signal r_wbase : std_logic_vector(NPORTS_W*ADDR_W-1 downto 0)
         := (others => '0');

  signal cb_we   : std_logic := '0';
  signal cb_addr : std_logic_vector(3 downto 0)  := (others => '0');
  signal cb_data : std_logic_vector(7 downto 0)  := (others => '0');

  signal x_we    : std_logic := '0';
  signal x_waddr : std_logic_vector(15 downto 0) := (others => '0');
  signal x_wdata : std_logic_vector(15 downto 0) := (others => '0');
  signal x_idx   : unsigned(15 downto 0) := (others => '0');

  signal y_we    : std_logic;
  signal y_addr  : std_logic_vector(15 downto 0);
  signal y_data  : std_logic_vector(ROWS_IF*64-1 downto 0);
  signal y_mask  : std_logic_vector(ROWS_IF-1 downto 0);
  signal y_exp   : std_logic_vector(31 downto 0);
  signal core_done, err, sat_event : std_logic;
  signal dbg_wbeat, dbg_wstarve : std_logic;

  -- Result buffer, one whole tile per word so a beat is a single full-width
  -- write.  FLAT, and written whole: the same two rules that cost 256 BRAM
  -- tiles when they were broken in act_mem_striped and ybuf (7.9a).
  type res_t is array(0 to TILES-1) of std_logic_vector(ROWS_IF*64-1 downto 0);
  signal res   : res_t;
  attribute ram_style : string;
  attribute ram_style of res : signal is "block";
  signal res_q : std_logic_vector(ROWS_IF*64-1 downto 0) := (others => '0');
  signal y_idx   : unsigned(15 downto 0) := (others => '0');
  -- the index that produced res_q.  Without it the lane mux selects with the
  -- CURRENT index out of a word fetched for the PREVIOUS one, which agrees
  -- whenever consecutive rows share a tile and is wrong exactly when the tile
  -- changes -- so it reads correctly for the first ROWS_IF rows and then
  -- returns stale lanes.
  signal y_idx_d : unsigned(15 downto 0) := (others => '0');
  signal y_sel   : std_logic_vector(63 downto 0);

  signal c_cycles, c_beats, c_starve : unsigned(31 downto 0)
         := (others => '0');
begin
  rst <= not s_axi_aresetn;

  s_axi_awready <= awready; s_axi_wready  <= wready;
  s_axi_bvalid  <= bvalid;  s_axi_bresp   <= "00";
  s_axi_arready <= arready; s_axi_rvalid  <= rvalid;
  s_axi_rresp   <= "00";    s_axi_rdata   <= rdata_r;

  dut : entity work.matvec_int4
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W, MAXCOLS => MAXCOLS,
                MAXROWS_BFP => MAXROWS_BFP, FIFO_DEPTH => FIFO_DEPTH,
                MAXB => MAXB)
    port map(clk => s_axi_aclk, rst => rst, start => start,
             n_rows => r_rows, n_cols => r_cols, out_shift => r_osh,
             w_exp => r_wexp, x_exp => r_xexp, out_mode => r_mode,
             w_base => r_wbase, w_beats => r_wbeats,
             s_base => r_sbase, s_beats => r_sbeats,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
             m_arvalid => m_arvalid, m_arready => m_arready,
             m_araddr => m_araddr, m_arlen => m_arlen,
             m_arsize => m_arsize, m_arburst => m_arburst,
             m_rvalid => m_rvalid, m_rready => m_rready,
             m_rdata => m_rdata, m_rlast => m_rlast,
             y_we => y_we, y_addr => y_addr, y_data => y_data,
             y_mask => y_mask, y_exp => y_exp,
             done => core_done, err => err, sat_event => sat_event,
             dbg_wbeat => dbg_wbeat, dbg_wstarve => dbg_wstarve);

  -- ------------------------------------------------------------ write channel
  wrp : process(s_axi_aclk)
    variable reg : integer;
  begin
    if rising_edge(s_axi_aclk) then
      start <= '0'; cb_we <= '0'; x_we <= '0';

      if s_axi_aresetn = '0' then
        awready <= '0'; wready <= '0'; bvalid <= '0'; busy <= '0';
        done_l <= '0'; x_idx <= (others => '0');
      else
        if awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' then
          awready <= '1'; wready <= '1'; wr_addr <= s_axi_awaddr;
        else
          awready <= '0'; wready <= '0';
        end if;

        if awready = '1' and wready = '1' then
          reg := to_integer(unsigned(wr_addr(7 downto 2)));
          case reg is
            when 0 =>
              if s_axi_wdata(0) = '1' then
                start <= '1'; busy <= '1'; done_l <= '0';
                c_cycles <= (others => '0');
                c_beats  <= (others => '0');
                c_starve <= (others => '0');
              end if;
            when 2  => r_rows   <= s_axi_wdata;
            when 3  => r_cols   <= s_axi_wdata;
            when 4  => r_osh    <= s_axi_wdata;
            when 5  => r_wexp   <= s_axi_wdata;
            when 6  => r_xexp   <= s_axi_wdata;
            when 7  => r_mode   <= s_axi_wdata(1 downto 0);
            when 8|9|10|11 =>
              r_wbase((reg-8+1)*ADDR_W-1 downto (reg-8)*ADDR_W)
                <= s_axi_wdata(ADDR_W-1 downto 0);
            when 12 => r_wbeats <= s_axi_wdata;
            when 13 => r_sbase  <= s_axi_wdata;
            when 14 => r_sbeats <= s_axi_wdata;
            when 15 =>
              cb_addr <= s_axi_wdata(11 downto 8);
              cb_data <= s_axi_wdata(7 downto 0);
              cb_we   <= '1';
            when 16 => x_idx <= unsigned(s_axi_wdata(15 downto 0));
            when 17 =>
              x_waddr <= std_logic_vector(x_idx);
              x_wdata <= s_axi_wdata(15 downto 0);
              x_we    <= '1';
              x_idx   <= x_idx + 1;          -- K writes, not 2K
            when 18 => y_idx <= unsigned(s_axi_wdata(15 downto 0));
            when others => null;
          end case;
          bvalid <= '1';
        elsif bvalid = '1' and s_axi_bready = '1' then
          bvalid <= '0';
        end if;

        if core_done = '1' then busy <= '0'; done_l <= '1'; end if;

        -- performance counters, live only while busy
        if busy = '1' then
          c_cycles <= c_cycles + 1;
          if dbg_wbeat   = '1' then c_beats  <= c_beats + 1;  end if;
          if dbg_wstarve = '1' then c_starve <= c_starve + 1; end if;
        end if;
      end if;
    end if;
  end process;

  -- --------------------------------------------------------- result capture
  resp : process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if y_we = '1' then
        res(to_integer(unsigned(y_addr)) / ROWS_IF) <= y_data;
      end if;
      -- registered read, issued continuously so it infers a BRAM read port.
      -- The PS writes Y_IDX and then reads Y_LO many cycles later, so one cycle
      -- of latency is invisible on this path.
      res_q   <= res(to_integer(y_idx) / ROWS_IF);
      y_idx_d <= y_idx;
    end if;
  end process;

  -- combinational lane mux, aligned to the index that fetched res_q
  y_sel <= res_q(((to_integer(y_idx_d) mod ROWS_IF) + 1)*64 - 1
                 downto (to_integer(y_idx_d) mod ROWS_IF)*64);

  -- ------------------------------------------------------------- read channel
  rdp : process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        arready <= '0'; rvalid <= '0';
      else
        if arready = '0' and s_axi_arvalid = '1' then
          arready <= '1';
          case to_integer(unsigned(s_axi_araddr(7 downto 2))) is
            when 1  => rdata_r <= (31 downto 4 => '0') &
                                  sat_event & err & busy & done_l;
            when 2  => rdata_r <= r_rows;
            when 3  => rdata_r <= r_cols;
            when 4  => rdata_r <= r_osh;
            when 5  => rdata_r <= r_wexp;
            when 6  => rdata_r <= r_xexp;
            when 7  => rdata_r <= (31 downto 2 => '0') & r_mode;
            when 12 => rdata_r <= r_wbeats;
            when 13 => rdata_r <= r_sbase;
            when 14 => rdata_r <= r_sbeats;
            when 19 => rdata_r <= y_sel(31 downto 0);
            when 20 => rdata_r <= y_sel(63 downto 32);
            when 21 => rdata_r <= y_exp;
            when 22 => rdata_r <= std_logic_vector(c_cycles);
            when 23 => rdata_r <= std_logic_vector(c_beats);
            when 24 => rdata_r <= std_logic_vector(c_starve);
            when 25 => rdata_r <= ID_CODE;
            when others => rdata_r <= (others => '0');
          end case;
          rvalid <= '1';
        elsif rvalid = '1' and s_axi_rready = '1' then
          arready <= '0'; rvalid <= '0';
        else
          arready <= '0';
        end if;
      end if;
    end if;
  end process;
end architecture;
