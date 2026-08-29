-- sim/tb_matvec_fk33_desc.vhd -- subsystem A at the FK33 geometry, driven
-- through the DESCRIPTOR-IN-MEMORY control plane, from a REAL .mv4i file,
-- checked bit-exactly against ref/matvec_int4.c -- and then MUTATED.
--
-- WHAT THIS ADDS OVER sim/tb_matvec_fk33.vhd.  That file proves the DATAPATH
-- is bit-exact at ROWS_IF=48 / AXI_DW=256 over 27 AXI masters, but it drives
-- `matvec_int4` directly: it hands the bases, the beat counts, the codebook and
-- the shape to the core as ports, from the trace.  Nothing between the trace
-- and the core is under test.  This file replaces all of that with the real
-- control path:
--
--   * it BUILDS the 39-word descriptor image (docs/2026-08-28_matvec-
--     descriptor-format.md) and serves it over a 28th AXI4 read master,
--   * the DUT fetches it, checks it, loads the codebook out of it and starts
--     itself,
--   * the result comes back through the AXI-Lite map, row by row.
--
-- So the claim it supports is "the same bit-exact answer, through the control
-- plane that will exist on the card", not "the datapath is right".
--
-- THE MUTATION MATRIX IS HALF THE POINT.  A control plane whose only test is
-- the happy path is a control plane with no teeth: every check in
-- matvec_int4_desc_axi's S_CHECK could be deleted and the clean run would
-- still pass.  So the bench runs a TABLE of cases in one simulation, resetting
-- between them, and each case declares what must happen:
--
--   EXP_OK    the reference answer, bit for bit, every row
--   EXP_ERR c the design must REFUSE: err set, err_code = c, done NOT set,
--             and no result produced
--   EXP_WRONG the design is EXPECTED not to detect this, so it must produce
--             something that is NOT the reference answer (or hang).  A case
--             that lands here and returns the CORRECT answer is a bench bug,
--             not a pass, and is reported as such -- a mutation that changes
--             nothing observable is not evidence about anything.
--
-- The EXP_WRONG rows are the honest part: they name, in executable form, the
-- two things this design cannot see -- a base that is well formed but points
-- at the wrong sub-region, and a beat count that does not match the shape.
--
-- THE SHAPE SWEEP IS THE OTHER HALF OF THE TEETH.  Case 20 (w_beats halved)
-- used to HANG and is now refused with EC_SHAPE, which is only half a result:
-- a shape check that is too strict is WORSE than the hang, because it refuses
-- work that is legal.  So BEFORE the case table (case 21 leaves the descriptor
-- slave holding an AR it was told to ignore, so the two must not be adjacent)
-- this bench sweeps a table of
-- LEGAL (n_rows, n_cols) shapes -- including n_rows that are not multiples of
-- ROWS_IF, an n_cols that is not a multiple of BLK, and the single-tile and
-- single-block corners -- computes w_beats and s_beats for each by an
-- INDEPENDENT divide (the bench divides; the RTL is forbidden to, which is
-- the whole point of the identity), and requires every one to be ACCEPTED.
-- Each legal shape is then mutated four ways -- w_beats +/- 1, s_beats +/- 1
-- -- and every mutant must be REFUSED with EC_SHAPE.
--
-- A SECOND DUT AT THE AXU3EG GEOMETRY IS INSTANTIATED FOR ONE REASON: GRP.
-- GRP = NPORTS_S*AXI_DW/(ROWS_IF*16) is 1 at the FK33 shape, where
-- s_beats = w_beats and the ceil in s_beats = ceil(w_beats/GRP) is invisible.
-- At ROWS_IF=4 / AXI_DW=128 / NPORTS_S=1 -- the AXU3EG build -- GRP is 2 and
-- the ceil is load-bearing.  That DUT has NO weight slaves: its masters are
-- tied off, so an ACCEPTED descriptor leaves it busy forever and a REFUSED
-- one raises err.  That is exactly the property under test and it needs no
-- weight data to observe.
--
-- DUAL CLOCK.  With -gDUAL=true the 27 weight masters, the descriptor master
-- and the whole AXI side run on a SEPARATE, FASTER clock, and axi_rd_port's
-- CDC (rtl/async_fifo.vhd) carries every weight word across.  The arithmetic
-- claim is then the same claim about the same bytes with a real clock domain
-- crossing in the path, which is the only way to know the CDC did not drop,
-- duplicate or reorder a beat.  Both clocks are driven from generate-selected
-- processes rather than from a `sclk <= aclk when DUAL else clk` signal: that
-- costs a delta, and a delta-skewed clock is exactly what silently broke
-- sim/tb_matvec_int4_ip when axi_rd_port was first written that way.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;
use work.matvec_int4_desc_pkg.all;

entity tb_matvec_fk33_desc is
  generic(
    TRACE   : string   := "mv_fk33_tr.txt";
    RI      : positive := 48;
    NPW     : positive := 24;
    NPS     : positive := 3;
    AXI_DW  : positive := 256;
    BLK     : positive := 32;
    MAXBEAT : positive := 384;
    MAXROWS : positive := 192;
    MAXCOLS : positive := 4096;
    STALL   : natural  := 3;
    -- 40, not 64.  A base above 4 GB must still be representable (the FK33 has
    -- 8 GB of HBM and BASE_HI puts every sub-region past the 4 GB line), but
    -- ADDR_W must be BELOW 64 or the ERR_ADDR check is vacuous: at 64 no bit
    -- is out of range and the mutation that tests it cannot be built.
    ADDR_W  : positive := 40;
    BASE_HI : natural  := 1;
    -- Run the AXI side on its own faster clock, through axi_rd_port's CDC.
    DUAL    : boolean  := false;
    -- AXI half-period when DUAL, in PICOSECONDS.  An integer, not a `time`:
    -- ghdl -r refuses a generic override of a physical type ("unhandled type
    -- for generic override"), so a `time` generic here could not be swept.
    -- 3000 ps against the core's 5000 ps is 1.67x, the direction the FK33 has
    -- (HBM AXI faster than f_core) and the direction that makes the CDC
    -- load-bearing rather than decorative.
    ACLK_HALF_PS : positive := 3000
  );
end entity;

architecture sim of tb_matvec_fk33_desc is
  constant NP_ALL : positive := NPW + NPS;
  constant PORT_B : positive := AXI_DW / 8;
  constant BSEL   : positive := clog2(MAXBEAT);
  constant LSB    : positive := clog2(PORT_B);
  constant MAXB   : positive := 16;         -- AXI3 ARLEN is 4 bits
  constant WPB    : positive := AXI_DW / 64;
  constant DWORDS : positive := desc_words(NPW, NPS);
  constant DBEATS : positive := desc_beats(NPW, NPS, AXI_DW);
  constant EXT0   : natural  := desc_ext0(NPW, NPS);

  -- Where the descriptor lives.  A multiple of DESC_MAXB*AXI_DW/8 (512 bytes
  -- here), which is what matvec_int4_desc_axi's DESC_ALIGN requires, and well
  -- past the 2.4 MB tensor so a stray fetch into the weight image is
  -- impossible by address rather than by luck.
  constant DESC_OFF : natural := 16#300000#;

  -- GRP of spec 6.5a for THIS geometry: how many scale groups one superword
  -- carries, and therefore the divisor in s_beats = ceil(w_beats / GRP).
  -- 1 at the FK33 shape.  Computed here rather than read from the trace's
  -- GEOM line so the sweep's expectation is independent of the trace.
  constant GRP_A : positive := (NPS * AXI_DW) / (RI * 16);

  -- ------------------------------------------------- the AXU3EG arm (GRP=2)
  -- ROWS_IF=4 / AXI_DW=128 / NPORTS_S=1 is spec 14.4's AXU3EG pinning, and it
  -- is the geometry at which GRP is 2.  Only the shape gate is exercised here,
  -- so the weight masters are tied off and MAXROWS_BFP is kept small.
  constant B_RI     : positive := 4;
  constant B_NPW    : positive := 4;
  constant B_NPS    : positive := 1;
  constant B_DW     : positive := 128;
  constant B_ROWS   : positive := 64;      -- MAXROWS_BFP: TILES = 16
  constant B_COLS   : positive := 4096;    -- MAXCOLS
  constant B_NPALL  : positive := B_NPW + B_NPS;
  constant B_WORDS  : positive := desc_words(B_NPW, B_NPS);
  constant B_BEATS  : positive := desc_beats(B_NPW, B_NPS, B_DW);
  constant B_EXT0   : natural  := desc_ext0(B_NPW, B_NPS);
  constant B_WPB    : positive := B_DW / 64;
  constant B_PORTB  : positive := B_DW / 8;
  constant B_GRP    : positive := (B_NPS * B_DW) / (B_RI * 16);
  -- DESC_MAXB * AXI_DW/8 = 16 * 16 = 256, so the pointer must be 256-aligned.
  constant B_DOFF   : natural  := 16#400000#;

  -- ------------------------------------------------------ the shape sweep
  -- LEGAL shapes.  Chosen, not arbitrary: rows that are and are not multiples
  -- of ROWS_IF, the one-row and one-block corners, an n_cols that is not a
  -- multiple of BLK, and the largest shape the served image can back.  For
  -- the FK33 arm w_beats = tiles*nblk must stay within MAXBEAT, because the
  -- weight slaves police it and only MAXBEAT beats of image exist; the
  -- AXU3EG arm serves no weights at all and is unconstrained.
  --
  -- THE TOP OF THE ROW RANGE IS REACHED, AND UNTIL `cbb0457` IT COULD NOT BE.
  -- rtl/matvec_core.vhd read `ybuf(rd_t)` unconditionally while S_EMIT let
  -- rd_t reach tiles_r, and ybuf is indexed `0 to TILES-1`, so index TILES was
  -- an out-of-bounds read whenever ceil(n_rows/ROWS_IF) = TILES -- i.e. for
  -- every n_rows in the top ROWS_IF rows of MAXROWS_BFP.  MEASURED then:
  -- n_rows = 145 and n_rows = 192 each aborted this bench with
  --   index (4) out of bounds (0 to 3) at rtl/matvec_core.vhd:835
  -- at MAXROWS_BFP = 192 / ROWS_IF = 48.  Harmless in synthesis (rd_v is '0'
  -- in that cycle) and fatal in simulation, so the sweep had to stay below it,
  -- which left the top corner of the row range unverified -- and that corner is
  -- exactly where an off-by-one in `tiles` would show.  Worklog OI-8, fixed by
  -- clamping the read address; the ceiling is lifted here as the second half of
  -- that fix.
  --
  -- BOTH TOP-CORNER SHAPES ARE PRESENT, not just the round one: 192 is an exact
  -- multiple of ROWS_IF and 145 is not, and they are the two the finder
  -- measured aborting.  A ceil/floor error in `tiles` separates them.
  -- w_beats = tiles*nblk must still stay within MAXBEAT on this arm, because
  -- the weight slaves police it and only MAXBEAT beats of image exist: at
  -- tiles = 4 that caps n_cols at 96*BLK = 3072, which both new pairings
  -- respect (128 beats and 4 beats).
  constant NSHAPE : integer := 10;
  type shp_t is array(0 to NSHAPE-1) of integer;
  --                       six of the ten have an n_rows that is NOT a multiple
  --                       of ROWS_IF (1, 47, 49, 97, 145, 49), which is the
  --                       case a floor-instead-of-ceil check gets wrong.
  constant SH_ROWS : shp_t := (  1,  47,  48,  49,  96,  97, 100, 192, 145,  49);
  constant SH_COLS : shp_t := ( 32, 128, 4095, 33, 1024, 64, 4096, 1024, 32, 4096);

  -- The AXU3EG arm's shapes.  THREE of the nine give an ODD w_beats -- 1, 1
  -- and 3 -- and those are the only ones where ceil(w_beats/2) differs from
  -- floor(w_beats/2), so they are what pins the ceil rather than the divide.
  -- At the FK33 arm's GRP = 1 s_beats and w_beats are equal and neither is
  -- observable.  The top two entries reach B_ROWS itself, 64 = 16*B_RI and
  -- 61 = 15*B_RI + 1, for the same reason the FK33 arm carries 192 and 145.
  -- This arm ties off the weight masters and never reaches the emit pass, so
  -- what it lifts is the SHAPE CHECK's top corner, not OI-8's.
  constant NSHAPB : integer := 9;
  type shpb_t is array(0 to NSHAPB-1) of integer;
  constant BS_ROWS : shpb_t := (   1,  3,    4,  5,  8,  9,   33, 61,   64);
  constant BS_COLS : shpb_t := (  32, 32, 4096, 96, 33, 32, 1024, 64, 4095);

  -- ------------------------------------------------------------ the cases
  constant EXP_OK    : integer := -1;
  constant EXP_WRONG : integer := -2;
  constant NCASE     : integer := 21;

  type name_t is array(0 to NCASE) of string(1 to 34);
  constant CASE_NAME : name_t := (
    0  => "clean descriptor                  ",
    1  => "ext magic corrupted               ",
    2  => "ext version = 2                   ",
    3  => "nsub_w = 23 (build has 24)        ",
    4  => "nsub_s = 2 (build has 3)          ",
    5  => "opcode = 4 (VEC_NORM, not A_JOB)  ",
    6  => "word 3 pad byte nonzero           ",
    7  => "word 7 (D reserved) nonzero       ",
    8  => "out_mode = 3                      ",
    9  => "n_rows = 0                        ",
    10 => "n_cols = MAXCOLS+1                ",
    11 => "w_beats = 0                       ",
    12 => "ext word 2 pad half nonzero       ",
    13 => "ext_flags nonzero                 ",
    14 => "cb_load clear, no codebook loaded ",
    15 => "w_base[7] misaligned by 64 B      ",
    16 => "s_base[1] bit at/above ADDR_W     ",
    17 => "DESC_PTR misaligned by 8 B        ",
    18 => "DESC_PTR_HI above ADDR_W          ",
    19 => "w_base[7] aims at sub-region 8    ",
    20 => "w_beats halved to 192             ",
    21 => "descriptor slave never answers    ");

  type exp_t is array(0 to NCASE) of integer;
  -- The expected err_code, or EXP_OK / EXP_WRONG.  Codes are the constants in
  -- rtl/matvec_int4_desc_pkg.vhd.
  constant CASE_EXP : exp_t := (
    0  => EXP_OK,
    1  => 16#A#,   -- EC_MAGIC
    2  => 16#B#,   -- EC_VER
    3  => 16#9#,   -- EC_GEOM
    4  => 16#9#,   -- EC_GEOM
    5  => 16#3#,   -- EC_DESC
    6  => 16#3#,
    7  => 16#3#,
    8  => 16#3#,
    9  => 16#3#,
    10 => 16#3#,
    11 => 16#3#,
    12 => 16#3#,
    13 => 16#3#,
    14 => 16#3#,
    15 => 16#C#,   -- EC_ALIGN
    16 => 16#D#,   -- EC_ADDR
    17 => 16#C#,   -- EC_ALIGN, on the pointer
    18 => 16#D#,   -- EC_ADDR, on the pointer
    19 => EXP_WRONG,
    20 => 16#F#,   -- EC_SHAPE.  Was EXP_WRONG, and specifically was the one
                   -- EXP_WRONG row that HUNG: the array starved and the job
                   -- never completed and never errored.  The shape gate in
                   -- matvec_int4_desc_axi's S_SHAPE now refuses it before
                   -- `start`, so the hang is unreachable rather than merely
                   -- observable.  Case 19 is still EXP_WRONG and still is
                   -- not this track's: nothing in the descriptor says what a
                   -- sub-region should CONTAIN.
    21 => 16#4#);  -- EC_WDOG

  -- ------------------------------------------------------------- clocking
  signal clk, mclk : std_logic := '0';
  signal aresetn   : std_logic := '0';
  signal finished  : boolean   := false;

  -- ------------------------------------------------------------- AXI-Lite
  signal awaddr, araddr_l : std_logic_vector(7 downto 0) := (others => '0');
  signal wdata, rdata_l   : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb  : std_logic_vector(3 downto 0) := "1111";
  signal awvalid, awready, wvalid, wready, bvalid, bready : std_logic := '0';
  signal arvalid_l, arready_l, rvalid_l, rready_l : std_logic := '0';
  signal bresp, rresp : std_logic_vector(1 downto 0);

  -- --------------------------------------------------- descriptor master
  signal d_arvalid, d_arready, d_rvalid, d_rready, d_rlast : std_logic := '0';
  signal d_araddr  : std_logic_vector(ADDR_W-1 downto 0);
  signal d_arlen   : std_logic_vector(7 downto 0);
  signal d_arsize  : std_logic_vector(2 downto 0);
  signal d_arburst : std_logic_vector(1 downto 0);
  signal d_rdata   : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
  -- case 21: the descriptor slave refuses to answer AR, so the fetch must
  -- time out rather than wait forever
  signal d_deaf    : std_logic := '0';

  -- ------------------------------------------------- weight/scale masters
  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast :
    std_logic_vector(NP_ALL-1 downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector(NP_ALL*ADDR_W-1 downto 0);
  signal m_arlen   : std_logic_vector(NP_ALL*8-1 downto 0);
  signal m_arsize  : std_logic_vector(NP_ALL*3-1 downto 0);
  signal m_arburst : std_logic_vector(NP_ALL*2-1 downto 0);
  signal m_rdata   : std_logic_vector(NP_ALL*AXI_DW-1 downto 0)
                     := (others => '0');

  -- --------------------------------------------------------- activations
  signal x_we    : std_logic := '0';
  signal x_waddr : std_logic_vector(15 downto 0) := (others => '0');
  signal x_wdata : std_logic_vector(15 downto 0) := (others => '0');

  -- -------------------------------------------------------------- result
  signal y_we   : std_logic;
  signal y_addr : std_logic_vector(15 downto 0);
  signal y_data : std_logic_vector(RI*64-1 downto 0);
  signal y_mask : std_logic_vector(RI-1 downto 0);
  signal y_exp_o : std_logic_vector(31 downto 0);
  signal job_done, job_err : std_logic;

  -- --------------------------------------------- the trace, as loaded data
  type beat_v is array(0 to MAXBEAT-1) of std_logic_vector(AXI_DW-1 downto 0);
  type beat_a is array(0 to NP_ALL-1) of beat_v;
  shared variable img : beat_a := (others => (others => (others => '0')));

  type xm_t is array(0 to MAXCOLS-1) of std_logic_vector(15 downto 0);
  shared variable xv : xm_t := (others => (others => '0'));

  type row_t is array(0 to MAXROWS-1) of std_logic_vector(63 downto 0);
  shared variable e_ymant : row_t := (others => (others => '0'));

  type cb_t is array(0 to 15) of std_logic_vector(7 downto 0);
  shared variable cbv : cb_t := (others => (others => '0'));

  type off_t is array(0 to NP_ALL-1) of integer;
  shared variable suboff : off_t := (others => 0);

  signal t_rows, t_cols, t_osh, t_wexp, t_xexp : integer := 0;
  signal t_wbeats, t_sbeats : integer := 0;
  signal e_yexp  : integer := 0;
  signal e_satev : integer := 0;
  signal loaded  : boolean := false;

  -- ---------------------------------------- the descriptor image, per case
  type dword_arr is array(0 to DWORDS-1) of std_logic_vector(63 downto 0);
  signal dimg : dword_arr := (others => (others => '0'));
  -- Where each master's data actually comes from, so a "wrong base" mutation
  -- can be SERVED rather than tripping the slave's own region assert.  Without
  -- this the bench would abort on its own check instead of letting the design
  -- compute the wrong answer the mutation is asking about.
  type src_t is array(0 to NP_ALL-1) of integer;
  signal psrc  : src_t := (others => 0);
  type pb_t is array(0 to NP_ALL-1) of unsigned(ADDR_W-1 downto 0);
  signal pbase : pb_t := (others => (others => '0'));
  signal p_wbeats, p_sbeats : integer := 0;

  -- ----------------------------------------------------- per-case results
  signal nchk, nbad : integer := 0;
  -- The counters have exactly ONE driver, the capture process.  The driver
  -- process asks for a clear with `cap_clr` rather than assigning them: two
  -- processes driving one unresolved signal does not merely misbehave, GHDL
  -- refuses to elaborate it.
  signal cap_clr    : std_logic := '0';
  signal cap_en     : std_logic := '0';
  signal nfail      : integer := 0;
  signal ncase_run  : integer := 0;

  function lift (off : integer) return unsigned is
  begin
    return to_unsigned(off, ADDR_W)
         + shift_left(to_unsigned(BASE_HI, ADDR_W), 32);
  end function;

  function tokis (t : string; s : string) return boolean is
  begin
    if s'length > t'length then return false; end if;
    if t(t'low to t'low + s'length - 1) /= s then return false; end if;
    if t'length = s'length then return true; end if;
    return t(t'low + s'length) = ' ';
  end function;

  function u32(v : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(v, 32));
  end function;

  -- ------------------------------------------------- the AXU3EG arm's wires
  signal b_awaddr, b_araddr : std_logic_vector(7 downto 0) := (others => '0');
  signal b_wdata, b_rdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal b_awvalid, b_awready, b_wvalid, b_wready : std_logic := '0';
  signal b_bvalid, b_bready : std_logic := '0';
  signal b_arvalid, b_arready, b_rvalid, b_rready : std_logic := '0';
  signal b_bresp, b_rresp : std_logic_vector(1 downto 0);

  signal bd_arvalid, bd_arready, bd_rvalid, bd_rready, bd_rlast : std_logic := '0';
  signal bd_araddr  : std_logic_vector(ADDR_W-1 downto 0);
  signal bd_arlen   : std_logic_vector(7 downto 0);
  signal bd_arsize  : std_logic_vector(2 downto 0);
  signal bd_arburst : std_logic_vector(1 downto 0);
  signal bd_rdata   : std_logic_vector(B_DW-1 downto 0) := (others => '0');

  -- Weight/scale masters, TIED OFF.  An accepted descriptor therefore leaves
  -- this DUT busy for ever and a refused one raises err, which is precisely
  -- the distinction the shape sweep is asking about.
  signal bm_arvalid, bm_rready : std_logic_vector(B_NPALL-1 downto 0);
  signal bm_araddr  : std_logic_vector(B_NPALL*ADDR_W-1 downto 0);
  signal bm_arlen   : std_logic_vector(B_NPALL*8-1 downto 0);
  signal bm_arsize  : std_logic_vector(B_NPALL*3-1 downto 0);
  signal bm_arburst : std_logic_vector(B_NPALL*2-1 downto 0);
  signal b_ywe      : std_logic;
  signal b_yaddr    : std_logic_vector(15 downto 0);
  signal b_ydata    : std_logic_vector(B_RI*64-1 downto 0);
  signal b_ymask    : std_logic_vector(B_RI-1 downto 0);
  signal b_yexp     : std_logic_vector(31 downto 0);
  signal b_done, b_err : std_logic;

  type bword_arr is array(0 to B_WORDS-1) of std_logic_vector(63 downto 0);
  signal bimg : bword_arr := (others => (others => '0'));
begin
  -- =====================================================================
  -- Clocks.  Two generate arms, never a clock through a signal assignment.
  -- =====================================================================
  g_one_clk : if not DUAL generate
    ck : process
    begin
      while not finished loop
        clk <= '0'; mclk <= '0'; wait for 5 ns;
        clk <= '1'; mclk <= '1'; wait for 5 ns;
      end loop;
      wait;
    end process;
  end generate;

  g_two_clk : if DUAL generate
    ckc : process
    begin
      while not finished loop
        clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
      end loop;
      wait;
    end process;
    ckm : process
    begin
      while not finished loop
        mclk <= '0'; wait for ACLK_HALF_PS * 1 ps;
        mclk <= '1'; wait for ACLK_HALF_PS * 1 ps;
      end loop;
      wait;
    end process;
  end generate;

  -- =====================================================================
  dut : entity work.matvec_int4_desc_axi
    generic map(BLK => BLK, ROWS_IF => RI, NPORTS_W => NPW, NPORTS_S => NPS,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXCOLS => MAXCOLS, MAXROWS_BFP => MAXROWS,
                FIFO_DEPTH => 256, MAXB => MAXB, MAXOUT => 16,
                DESC_MAXB => 16, WDOG_LIMIT => 4096,
                DUAL_CLK => DUAL, C_S_AXI_ADDR_WIDTH => 8)
    port map(
      s_axi_aclk => clk, s_axi_aresetn => aresetn, m_aclk => mclk,
      s_axi_awaddr => awaddr, s_axi_awprot => "000",
      s_axi_awvalid => awvalid, s_axi_awready => awready,
      s_axi_wdata => wdata, s_axi_wstrb => wstrb,
      s_axi_wvalid => wvalid, s_axi_wready => wready,
      s_axi_bresp => bresp, s_axi_bvalid => bvalid, s_axi_bready => bready,
      s_axi_araddr => araddr_l, s_axi_arprot => "000",
      s_axi_arvalid => arvalid_l, s_axi_arready => arready_l,
      s_axi_rdata => rdata_l, s_axi_rresp => rresp,
      s_axi_rvalid => rvalid_l, s_axi_rready => rready_l,

      d_arvalid => d_arvalid, d_arready => d_arready, d_araddr => d_araddr,
      d_arlen => d_arlen, d_arsize => d_arsize, d_arburst => d_arburst,
      d_rvalid => d_rvalid, d_rready => d_rready, d_rdata => d_rdata,
      d_rlast => d_rlast,

      m_arvalid => m_arvalid, m_arready => m_arready,
      m_araddr => m_araddr, m_arlen => m_arlen,
      m_arsize => m_arsize, m_arburst => m_arburst,
      m_rvalid => m_rvalid, m_rready => m_rready,
      m_rdata => m_rdata, m_rlast => m_rlast,

      x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
      x_exp_in => (others => '0'),

      y_we => y_we, y_addr => y_addr, y_data => y_data, y_mask => y_mask,
      y_exp_o => y_exp_o, job_done => job_done, job_err => job_err);

  -- =====================================================================
  -- The descriptor slave.  One contiguous DBEATS-beat region at DESC_OFF.
  -- It checks the high address half and the offset, so a truncated or
  -- wandering pointer is caught here rather than being served silently.
  -- =====================================================================
  dslv : process
    variable a  : unsigned(ADDR_W-1 downto 0);
    variable n, idx : integer;
    variable b  : std_logic_vector(AXI_DW-1 downto 0);
  begin
    d_arready <= '0'; d_rvalid <= '0'; d_rlast <= '0';
    wait until aresetn = '1';
    loop
      d_arready <= '0';
      while d_arvalid = '0' or d_deaf = '1' loop
        wait until rising_edge(mclk);
      end loop;
      a := unsigned(d_araddr);
      n := to_integer(unsigned(d_arlen)) + 1;

      assert d_arburst = "01"
        report "descriptor master: burst IS NOT INCR" severity failure;
      assert to_integer(shift_right(a, 32)) = BASE_HI
        report "descriptor master: address high half is " &
               integer'image(to_integer(shift_right(a, 32))) &
               ", expected " & integer'image(BASE_HI) &
               " -- DESC_PTR was truncated" severity failure;
      assert a(LSB-1 downto 0) = to_unsigned(0, LSB)
        report "descriptor master: address IS NOT beat aligned"
        severity failure;
      idx := to_integer(a - lift(DESC_OFF)) / PORT_B;
      assert idx >= 0 and idx + n <= DBEATS
        report "descriptor master: burst of " & integer'image(n) &
               " from beat " & integer'image(idx) &
               " runs outside the " & integer'image(DBEATS) &
               "-beat descriptor -- MISMATCH" severity failure;

      d_arready <= '1'; wait until rising_edge(mclk); d_arready <= '0';
      for i in 0 to n-1 loop
        b := (others => '0');
        for j in 0 to WPB-1 loop
          if (idx + i) * WPB + j < DWORDS then
            b((j+1)*64-1 downto j*64) := dimg((idx + i) * WPB + j);
          end if;
        end loop;
        d_rdata  <= b;
        d_rvalid <= '1';
        if i = n-1 then d_rlast <= '1'; else d_rlast <= '0'; end if;
        loop
          wait until rising_edge(mclk);
          exit when d_rready = '1';
        end loop;
      end loop;
      d_rvalid <= '0'; d_rlast <= '0';
    end loop;
  end process;

  -- =====================================================================
  -- One AXI slave per weight/scale master.  Same structure and the same
  -- three structural checks as sim/tb_matvec_fk33.vhd, with `psrc` added so
  -- that a deliberately wrong base can be SERVED instead of aborting the run.
  -- =====================================================================
  slaves : for p in 0 to NP_ALL-1 generate
    slv : process
      variable lf : unsigned(15 downto 0) := to_unsigned(4919 + p*277, 16);
      variable a  : unsigned(ADDR_W-1 downto 0);
      variable d  : unsigned(ADDR_W-1 downto 0);
      variable n, idx, lim : integer;
      procedure tick is
      begin
        wait until rising_edge(mclk);
        lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
      end procedure;
    begin
      m_arready(p) <= '0'; m_rvalid(p) <= '0'; m_rlast(p) <= '0';
      wait until aresetn = '1';
      loop
        m_arready(p) <= '0';
        while m_arvalid(p) = '0' loop tick; end loop;
        if STALL > 1 then
          while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
        end if;
        a := unsigned(m_araddr((p+1)*ADDR_W-1 downto p*ADDR_W));
        n := to_integer(unsigned(m_arlen((p+1)*8-1 downto p*8))) + 1;
        if p < NPW then lim := p_wbeats; else lim := p_sbeats; end if;

        assert m_arburst((p+1)*2-1 downto p*2) = "01"
          report "port " & integer'image(p) & ": burst IS NOT INCR"
          severity failure;
        assert to_integer(shift_right(a, 32)) = BASE_HI
          report "port " & integer'image(p) & ": address high half is " &
                 integer'image(to_integer(shift_right(a, 32))) &
                 ", expected " & integer'image(BASE_HI) &
                 " -- the base was truncated" severity failure;

        d := a - pbase(p);
        assert d(LSB-1 downto 0) = to_unsigned(0, LSB)
          report "port " & integer'image(p) &
                 ": address IS NOT beat aligned" severity failure;
        assert to_integer(shift_right(d, LSB + BSEL)) = 0
          report "port " & integer'image(p) &
                 ": read address is outside its own sub-region -- MISMATCH"
          severity failure;
        idx := to_integer(d(LSB + BSEL - 1 downto LSB));
        assert idx + n <= lim
          report "port " & integer'image(p) & ": burst of " &
                 integer'image(n) & " from beat " & integer'image(idx) &
                 " runs past the " & integer'image(lim) &
                 " beats programmed -- MISMATCH" severity failure;

        m_arready(p) <= '1'; tick; m_arready(p) <= '0';
        for i in 0 to n-1 loop
          if STALL > 1 then
            m_rvalid(p) <= '0';
            while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
          end if;
          m_rdata((p+1)*AXI_DW-1 downto p*AXI_DW) <= img(psrc(p))(idx + i);
          m_rvalid(p) <= '1';
          if i = n-1 then m_rlast(p) <= '1'; else m_rlast(p) <= '0'; end if;
          loop
            tick;
            exit when m_rready(p) = '1';
          end loop;
        end loop;
        m_rvalid(p) <= '0'; m_rlast(p) <= '0';
      end loop;
    end process;
  end generate;

  -- =====================================================================
  -- THE AXU3EG ARM.  Same entity, ROWS_IF=4 / AXI_DW=128 / NPORTS_S=1, which
  -- is the geometry where GRP = 2.  It exists ONLY so the shape sweep can
  -- exercise the ceil in s_beats = ceil(w_beats/GRP); it is never given a
  -- weight byte and never expected to compute anything.
  -- =====================================================================
  dutb : entity work.matvec_int4_desc_axi
    generic map(BLK => BLK, ROWS_IF => B_RI, NPORTS_W => B_NPW,
                NPORTS_S => B_NPS, AXI_DW => B_DW, ADDR_W => ADDR_W,
                MAXCOLS => B_COLS, MAXROWS_BFP => B_ROWS,
                FIFO_DEPTH => 64, MAXB => MAXB, MAXOUT => 2,
                DESC_MAXB => 16, WDOG_LIMIT => 4096,
                DUAL_CLK => false, C_S_AXI_ADDR_WIDTH => 8)
    port map(
      s_axi_aclk => clk, s_axi_aresetn => aresetn, m_aclk => clk,
      s_axi_awaddr => b_awaddr, s_axi_awprot => "000",
      s_axi_awvalid => b_awvalid, s_axi_awready => b_awready,
      s_axi_wdata => b_wdata, s_axi_wstrb => "1111",
      s_axi_wvalid => b_wvalid, s_axi_wready => b_wready,
      s_axi_bresp => b_bresp, s_axi_bvalid => b_bvalid, s_axi_bready => b_bready,
      s_axi_araddr => b_araddr, s_axi_arprot => "000",
      s_axi_arvalid => b_arvalid, s_axi_arready => b_arready,
      s_axi_rdata => b_rdata, s_axi_rresp => b_rresp,
      s_axi_rvalid => b_rvalid, s_axi_rready => b_rready,

      d_arvalid => bd_arvalid, d_arready => bd_arready, d_araddr => bd_araddr,
      d_arlen => bd_arlen, d_arsize => bd_arsize, d_arburst => bd_arburst,
      d_rvalid => bd_rvalid, d_rready => bd_rready, d_rdata => bd_rdata,
      d_rlast => bd_rlast,

      m_arvalid => bm_arvalid, m_arready => (others => '0'),
      m_araddr => bm_araddr, m_arlen => bm_arlen,
      m_arsize => bm_arsize, m_arburst => bm_arburst,
      m_rvalid => (others => '0'), m_rready => bm_rready,
      m_rdata => (others => '0'), m_rlast => (others => '0'),

      x_we => '0', x_waddr => (others => '0'), x_wdata => (others => '0'),
      x_exp_in => (others => '0'),

      y_we => b_ywe, y_addr => b_yaddr, y_data => b_ydata, y_mask => b_ymask,
      y_exp_o => b_yexp, job_done => b_done, job_err => b_err);

  -- The AXU3EG arm's descriptor slave.  Same structure and the same three
  -- structural checks as the FK33 one above, at B_DW and B_BEATS.
  bdslv : process
    variable a  : unsigned(ADDR_W-1 downto 0);
    variable n, idx : integer;
    variable b  : std_logic_vector(B_DW-1 downto 0);
  begin
    bd_arready <= '0'; bd_rvalid <= '0'; bd_rlast <= '0';
    wait until aresetn = '1';
    loop
      bd_arready <= '0';
      while bd_arvalid = '0' loop wait until rising_edge(clk); end loop;
      a := unsigned(bd_araddr);
      n := to_integer(unsigned(bd_arlen)) + 1;
      assert bd_arburst = "01"
        report "AXU3EG arm descriptor master: burst IS NOT INCR"
        severity failure;
      assert to_integer(shift_right(a, 32)) = BASE_HI
        report "AXU3EG arm descriptor master: address high half IS WRONG"
        severity failure;
      idx := to_integer(a - lift(B_DOFF)) / B_PORTB;
      assert idx >= 0 and idx + n <= B_BEATS
        report "AXU3EG arm descriptor master: burst of " & integer'image(n) &
               " from beat " & integer'image(idx) & " runs outside the " &
               integer'image(B_BEATS) & "-beat descriptor -- MISMATCH"
        severity failure;
      bd_arready <= '1'; wait until rising_edge(clk); bd_arready <= '0';
      for i in 0 to n-1 loop
        b := (others => '0');
        for j in 0 to B_WPB-1 loop
          if (idx + i) * B_WPB + j < B_WORDS then
            b((j+1)*64-1 downto j*64) := bimg((idx + i) * B_WPB + j);
          end if;
        end loop;
        bd_rdata  <= b;
        bd_rvalid <= '1';
        if i = n-1 then bd_rlast <= '1'; else bd_rlast <= '0'; end if;
        loop
          wait until rising_edge(clk);
          exit when bd_rready = '1';
        end loop;
      end loop;
      bd_rvalid <= '0'; bd_rlast <= '0';
    end loop;
  end process;

  -- =====================================================================
  -- The trace loader.  Identical parse to sim/tb_matvec_fk33.vhd, except the
  -- codebook and the sub-region offsets are STORED rather than driven: they
  -- are descriptor fields now, not ports.
  -- =====================================================================
  load : process
    file     tf : text open read_mode is TRACE;
    variable l  : line;
    variable tok : string(1 to 12);
    variable c  : character;
    variable slen, a, b, v : integer;
    variable h16 : std_logic_vector(15 downto 0);
    variable h64 : std_logic_vector(63 downto 0);
    variable hbe : std_logic_vector(AXI_DW-1 downto 0);
    variable good, saw_end : boolean;
    variable gRI, gNPW, gNPS, gDW, gBLK, gGRP : integer;
    variable M, K, NB, osh, wev, xev : integer;
    variable nimg : integer := 0;
  begin
    saw_end := false;
    while not endfile(tf) loop
      readline(tf, l);
      if l'length = 0 then next; end if;
      read(l, c, good);
      if not good or c = '#' then next; end if;
      tok := (others => ' '); slen := 1; tok(1) := c;
      loop
        read(l, c, good);
        exit when not good or c = ' ';
        slen := slen + 1; tok(slen) := c;
      end loop;

      if tokis(tok, "GEOM") then
        read(l, gRI); read(l, gNPW); read(l, gNPS);
        read(l, gDW); read(l, gBLK); read(l, gGRP);
        assert gRI = RI and gNPW = NPW and gNPS = NPS
               and gDW = AXI_DW and gBLK = BLK
          report "trace GEOMETRY IS WRONG for this testbench"
          severity failure;
      elsif tokis(tok, "DIMS") then
        read(l, M); read(l, K); read(l, NB);
        read(l, osh); read(l, wev); read(l, xev);
        assert M <= MAXROWS and K <= MAXCOLS
          report "trace shape does not fit this testbench's arrays"
          severity failure;
        t_rows <= M; t_cols <= K;
        t_osh <= osh; t_wexp <= wev; t_xexp <= xev;
      elsif tokis(tok, "CB") then
        read(l, a); read(l, v);
        cbv(a) := std_logic_vector(to_signed(v, 8));
      elsif tokis(tok, "X") then
        read(l, a); hread(l, h16); xv(a) := h16;
      elsif tokis(tok, "WSUB") then
        read(l, a); read(l, v); suboff(a) := v;
      elsif tokis(tok, "SSUB") then
        read(l, a); read(l, v); suboff(NPW + a) := v;
      elsif tokis(tok, "WBEATS") then
        read(l, v);
        assert v <= MAXBEAT report "WBEATS exceeds MAXBEAT" severity failure;
        t_wbeats <= v;
      elsif tokis(tok, "SBEATS") then
        read(l, v);
        assert v <= MAXBEAT report "SBEATS exceeds MAXBEAT" severity failure;
        t_sbeats <= v;
      elsif tokis(tok, "IMG") then
        read(l, a); read(l, b); hread(l, hbe);
        img(a)(b) := hbe;
        nimg := nimg + 1;
      elsif tokis(tok, "YMANT") then
        read(l, a); hread(l, h64); e_ymant(a) := h64;
      elsif tokis(tok, "YEXP") then
        read(l, a); e_yexp <= a;
      elsif tokis(tok, "SATEV") then
        read(l, a); e_satev <= a;
      elsif tokis(tok, "END") then
        saw_end := true;
      end if;
    end loop;
    assert saw_end
      report "the trace has no END line: it IS NOT complete, so nothing " &
             "below this point means anything"
      severity failure;
    report "loaded " & integer'image(nimg) & " sub-region beats from " & TRACE
      severity note;
    wait for 1 ns;
    loaded <= true;
    wait;
  end process;

  -- =====================================================================
  -- Result capture off the core's own y bus.  Enabled per case so a mutation
  -- that is supposed to produce nothing is caught producing something.
  -- =====================================================================
  ycap : process(clk)
    variable r  : integer;
    variable nc, nb : integer;
    variable got, want : std_logic_vector(63 downto 0);
  begin
    if rising_edge(clk) then
      nc := nchk; nb := nbad;
      if cap_clr = '1' then
        nc := 0; nb := 0;
      end if;
      if y_we = '1' and cap_en = '1' then
        for rr in 0 to RI-1 loop
          if y_mask(rr) = '1' then
            r    := to_integer(unsigned(y_addr)) + rr;
            got  := y_data(rr*64+63 downto rr*64);
            if r < MAXROWS then want := e_ymant(r);
            else want := (others => '0'); end if;
            nc := nc + 1;
            if got /= want then nb := nb + 1; end if;
          end if;
        end loop;
      end if;
      nchk <= nc; nbad <= nb;
    end if;
  end process;

  -- =====================================================================
  -- The driver: build, program, run, judge -- once per case.
  -- =====================================================================
  drv : process
    variable rd : std_logic_vector(31 downto 0);
    variable ec : integer;
    variable st : std_logic_vector(31 downto 0);
    variable tmo : integer;
    variable nerr : integer := 0;
    variable ok  : boolean;
    variable ptr : unsigned(63 downto 0);
    variable lo, hi : std_logic_vector(31 downto 0);
    variable got, want : std_logic_vector(63 downto 0);
    variable nrb, nrbad : integer;
    -- the shape sweep
    variable rw, cl, wbx, sbx, wbm, sbm : integer;
    variable n_legal, n_teeth : integer := 0;
    variable bst : std_logic_vector(31 downto 0);

    procedure awr(addr : natural; d : std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      awaddr <= std_logic_vector(to_unsigned(addr, 8));
      wdata  <= d; awvalid <= '1'; wvalid <= '1'; bready <= '1';
      loop
        wait until rising_edge(clk);
        exit when awready = '1' and wready = '1';
      end loop;
      awvalid <= '0'; wvalid <= '0';
      loop
        wait until rising_edge(clk);
        exit when bvalid = '1';
      end loop;
      bready <= '0';
    end procedure;

    procedure ard(addr : natural; d : out std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      araddr_l <= std_logic_vector(to_unsigned(addr, 8));
      arvalid_l <= '1'; rready_l <= '1';
      loop
        wait until rising_edge(clk);
        exit when rvalid_l = '1';
      end loop;
      d := rdata_l;
      arvalid_l <= '0'; rready_l <= '0';
      wait until rising_edge(clk);
    end procedure;

    -- Build the descriptor image for case `mut`, and set up whatever the
    -- SLAVE side of that mutation needs.  Everything the DUT is told comes
    -- from here; nothing is passed to it any other way.
    -- AXI-Lite to the AXU3EG arm.  A second pair rather than a parameterised
    -- one: the two DUTs have separate signal sets and VHDL has no signal
    -- parameters, so this is the honest way to write it.
    procedure bawr(addr : natural; d : std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      b_awaddr <= std_logic_vector(to_unsigned(addr, 8));
      b_wdata  <= d; b_awvalid <= '1'; b_wvalid <= '1'; b_bready <= '1';
      loop
        wait until rising_edge(clk);
        exit when b_awready = '1' and b_wready = '1';
      end loop;
      b_awvalid <= '0'; b_wvalid <= '0';
      loop
        wait until rising_edge(clk);
        exit when b_bvalid = '1';
      end loop;
      b_bready <= '0';
    end procedure;

    procedure bard(addr : natural; d : out std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      b_araddr  <= std_logic_vector(to_unsigned(addr, 8));
      b_arvalid <= '1'; b_rready <= '1';
      loop
        wait until rising_edge(clk);
        exit when b_rvalid = '1';
      end loop;
      d := b_rdata;
      b_arvalid <= '0'; b_rready <= '0';
      wait until rising_edge(clk);
    end procedure;

    -- The AXU3EG arm's descriptor.  Clean in every respect except the shape
    -- and the beat counts, which are what the sweep varies.
    procedure bbuild(o_rows, o_cols, o_wb, o_sb : integer) is
      variable w : std_logic_vector(63 downto 0);
    begin
      for i in 0 to B_WORDS-1 loop bimg(i) <= (others => '0'); end loop;

      w := (others => '0');
      w(7 downto 0)   := x"00";                       -- OP_A_JOB
      w(15 downto 8)  := x"04";                       -- flags bit 2 = cb_load
      w(23 downto 16) := x"FF";
      bimg(0) <= w;
      bimg(1) <= u32(o_cols) & u32(o_rows);
      bimg(2) <= u32(t_osh) & u32(t_wexp);

      w := (others => '0');
      w(7 downto 0)   := x"00";                       -- out_mode BFP
      w(31 downto 16) := std_logic_vector(to_unsigned(B_NPW, 16));
      w(47 downto 32) := std_logic_vector(to_unsigned(B_NPS, 16));
      w(55 downto 48) := x"FF";
      bimg(3) <= w;

      for j in 0 to 7 loop
        bimg(5)(8*j+7 downto 8*j) <= cbv(j);
        bimg(6)(8*j+7 downto 8*j) <= cbv(j+8);
      end loop;

      for p in 0 to B_NPALL-1 loop
        bimg(DESC_BASE0 + p)
          <= std_logic_vector(resize(lift(16#800000# + p*16#10000#), 64));
      end loop;

      w := (others => '0');
      w(31 downto 0)  := MV4I_MAGIC;
      w(47 downto 32) := x"0001";
      bimg(B_EXT0)     <= w;
      bimg(B_EXT0 + 1) <= u32(o_sb) & u32(o_wb);
      w := (others => '0');
      w(31 downto 0) := u32(t_xexp);
      bimg(B_EXT0 + 2) <= w;
      bimg(B_EXT0 + 3) <= (others => '0');
    end procedure;

    -- `ovr` replaces the trace's shape and beat counts, for the shape sweep.
    -- Everything else -- bases, codebook, magic, pads -- stays exactly as the
    -- clean case builds it, so a refusal during the sweep can only be about
    -- the shape.
    procedure build(mut : integer;
                    ovr : boolean := false;
                    o_rows : integer := 0; o_cols : integer := 0;
                    o_wb   : integer := 0; o_sb   : integer := 0) is
      variable w : std_logic_vector(63 downto 0);
      variable flags : std_logic_vector(7 downto 0);
      variable nw, ns : integer;
      variable om : integer;
      variable rows, cols, wb, sb : integer;
      variable bse : unsigned(63 downto 0);
    begin
      for i in 0 to DWORDS-1 loop
        dimg(i) <= (others => '0');
      end loop;

      flags := x"04";                                  -- bit 2 = cb_load
      if mut = 14 then flags := x"00"; end if;
      if mut = 13 then null; end if;

      nw := NPW; ns := NPS;
      if mut = 3 then nw := NPW - 1; end if;
      if mut = 4 then ns := NPS - 1; end if;

      om := 0;                                          -- BFP
      if mut = 8 then om := 3; end if;

      rows := t_rows; cols := t_cols;
      if mut = 9  then rows := 0; end if;
      if mut = 10 then cols := MAXCOLS + 1; end if;

      wb := t_wbeats; sb := t_sbeats;
      if mut = 11 then wb := 0; end if;
      if mut = 20 then wb := t_wbeats / 2; end if;

      if ovr then
        rows := o_rows; cols := o_cols; wb := o_wb; sb := o_sb;
      end if;

      -- word 0: opcode, flags, src/dst regions, dst_offset
      w := (others => '0');
      if mut = 5 then w(7 downto 0) := x"04";           -- OP_VEC_NORM
      else            w(7 downto 0) := x"00"; end if;   -- OP_A_JOB
      w(15 downto 8)  := flags;
      w(23 downto 16) := x"FF";                         -- src_region  = none
      w(31 downto 24) := x"00";                         -- dst_region  = 0
      dimg(0) <= w;

      -- word 1: n_rows, n_cols
      dimg(1) <= u32(cols) & u32(rows);

      -- word 2: w_exp, out_shift
      dimg(2) <= u32(t_osh) & u32(t_wexp);

      -- word 3: out_mode, ordinal, nsub_w, nsub_s, src_region2, pad
      w := (others => '0');
      w(7 downto 0)   := std_logic_vector(to_unsigned(om, 8));
      w(31 downto 16) := std_logic_vector(to_unsigned(nw, 16));
      w(47 downto 32) := std_logic_vector(to_unsigned(ns, 16));
      w(55 downto 48) := x"FF";                         -- src_region2 = none
      if mut = 6 then w(63 downto 56) := x"01"; end if; -- D's pad byte
      dimg(3) <= w;

      -- word 4: const_base / const_exp -- D's, unused by A
      dimg(4) <= (others => '0');

      -- words 5, 6: the codebook, entry j at bits 8j+7:8j
      for j in 0 to 7 loop
        dimg(5)(8*j+7 downto 8*j) <= cbv(j);
        dimg(6)(8*j+7 downto 8*j) <= cbv(j+8);
      end loop;

      -- word 7: D's reserved word
      if mut = 7 then dimg(7) <= x"0000000000000001";
      else            dimg(7) <= (others => '0'); end if;

      -- the base array at 0x40
      for p in 0 to NP_ALL-1 loop
        bse := resize(lift(suboff(p)), 64);
        if mut = 15 and p = 7 then
          bse := bse + 64;                             -- not 4 KB aligned
        end if;
        if mut = 16 and p = NPW + 1 then
          bse(ADDR_W) := '1';                          -- a bit ADDR_W cannot reach
        end if;
        if mut = 19 and p = 7 then
          bse := resize(lift(suboff(8)), 64);          -- another sub-region
        end if;
        dimg(DESC_BASE0 + p) <= std_logic_vector(bse);
      end loop;

      -- the A extension
      w := (others => '0');
      if mut = 1 then w(31 downto 0) := x"4D563448";    -- magic off by one
      else            w(31 downto 0) := MV4I_MAGIC; end if;
      if mut = 2 then w(47 downto 32) := x"0002";
      else            w(47 downto 32) := x"0001"; end if;
      if mut = 13 then w(63 downto 48) := x"0001"; end if;
      dimg(EXT0) <= w;

      dimg(EXT0 + 1) <= u32(sb) & u32(wb);

      w := (others => '0');
      w(31 downto 0) := u32(t_xexp);
      if mut = 12 then w(63 downto 32) := x"00000001"; end if;
      dimg(EXT0 + 2) <= w;

      dimg(EXT0 + 3) <= (others => '0');

      -- ------------------------------------------------ slave-side setup
      for p in 0 to NP_ALL-1 loop
        psrc(p)  <= p;
        pbase(p) <= lift(suboff(p));
      end loop;
      if mut = 19 then
        psrc(7)  <= 8;
        pbase(7) <= lift(suboff(8));
      end if;
      -- the beat counts the SLAVE polices, which must follow the descriptor
      p_wbeats <= wb; p_sbeats <= sb;
      if mut = 11 then p_wbeats <= t_wbeats; end if;   -- 0 is rejected anyway

      d_deaf <= '0';
      if mut = 21 then d_deaf <= '1'; end if;
    end procedure;

  begin
    wait until loaded;

    -- ------------------------------------------------- one reset, one load
    aresetn <= '0';
    for i in 0 to 7 loop wait until rising_edge(clk); end loop;
    aresetn <= '1';
    wait until rising_edge(clk);

    -- Activations go in once: act_mem_striped is a RAM and is not cleared by
    -- reset, so every case below runs against the same x vector.
    for k in 0 to t_cols-1 loop
      x_we    <= '1';
      x_waddr <= std_logic_vector(to_unsigned(k, 16));
      x_wdata <= xv(k);
      wait until rising_edge(clk);
    end loop;
    x_we <= '0';
    wait until rising_edge(clk);

    -- --------------------------------------------- identity of the build
    ard(16#14#, rd);
    assert rd = MV4I_MAGIC
      report "ID register IS WRONG" severity failure;
    ard(16#18#, rd);
    assert to_integer(unsigned(rd)) = ADDR_W
      report "ADDR_CAP reports " & integer'image(to_integer(unsigned(rd))) &
             ", build is " & integer'image(ADDR_W) severity failure;
    ard(16#1C#, rd);
    assert to_integer(unsigned(rd(7 downto 0)))   = NPW
       and to_integer(unsigned(rd(15 downto 8)))  = NPS
       and to_integer(unsigned(rd(23 downto 16))) = RI
       and to_integer(unsigned(rd(31 downto 24))) = AXI_DW/8
      report "CAPS IS WRONG" severity failure;
    ard(16#20#, rd);
    assert to_integer(unsigned(rd)) = DWORDS
      report "DESC_WORDS reports " & integer'image(to_integer(unsigned(rd))) &
             ", package says " & integer'image(DWORDS) severity failure;

    -- ==================================================== the shape sweep
    -- It runs FIRST, and not for a stylistic reason: case 21 leaves the
    -- descriptor slave holding an AR it was told to ignore, and restarting
    -- the fetch port on top of that dangling burst is a testbench artefact,
    -- not a design property.  Sweeping before the case table keeps them apart.
    --
    -- The teeth on the OTHER side of case 20.  Refusing a bad w_beats is only
    -- half a result; a check that also refuses LEGAL work is worse than the
    -- hang it replaced.  Every legal shape here must be ACCEPTED, and every
    -- one-off mutation of its beat counts must be REFUSED with EC_SHAPE.
    --
    -- The expectation is computed by DIVIDING -- ceil(rows/RI)*ceil(cols/BLK)
    -- -- which is exactly what the RTL is forbidden to do.  That asymmetry is
    -- the point: the bench divides down, the design multiplies up, and the
    -- sweep is the statement that the two agree.
    for i in 0 to NSHAPE-1 loop
      rw  := SH_ROWS(i); cl := SH_COLS(i);
      wbx := ((rw + RI - 1) / RI) * ((cl + BLK - 1) / BLK);
      sbx := (wbx + GRP_A - 1) / GRP_A;

      for k in 0 to 4 loop
        wbm := wbx; sbm := sbx;
        if    k = 1 then wbm := wbx - 1;
        elsif k = 2 then wbm := wbx + 1;
        elsif k = 3 then sbm := sbx - 1;
        elsif k = 4 then sbm := sbx + 1; end if;
        -- w_beats/s_beats = 0 is a DIFFERENT check (EC_DESC) and is already
        -- case 11, so a one-off that lands on zero is skipped rather than
        -- being judged against the wrong code.
        next when wbm = 0 or sbm = 0;

        aresetn <= '0';
        for j in 0 to 7 loop wait until rising_edge(clk); end loop;
        aresetn <= '1';
        wait until rising_edge(clk);
        cap_en <= '0'; cap_clr <= '1';
        build(0, true, rw, cl, wbm, sbm);
        wait until rising_edge(clk);
        cap_clr <= '0';
        wait until rising_edge(clk);

        ptr := resize(lift(DESC_OFF), 64);
        awr(16#00#, std_logic_vector(ptr(31 downto 0)));
        awr(16#04#, std_logic_vector(ptr(63 downto 32)));
        cap_en <= '1';
        awr(16#08#, x"00000001");

        tmo := 0;
        loop
          ard(16#0C#, st);
          exit when st(0) = '1' or st(2) = '1';
          tmo := tmo + 1;
          exit when tmo > 40000;
        end loop;
        ec := to_integer(unsigned(st(11 downto 8)));

        if k = 0 then
          n_legal := n_legal + 1;
          if st(2) = '1' then
            nerr := nerr + 1;
            report "SHAPE n_rows=" & integer'image(rw) & " n_cols=" &
                   integer'image(cl) & " w_beats=" & integer'image(wbx) &
                   " s_beats=" & integer'image(sbx) &
                   " is LEGAL and was REFUSED, err_code = " &
                   integer'image(ec) severity error;
          elsif st(0) /= '1' then
            nerr := nerr + 1;
            report "SHAPE n_rows=" & integer'image(rw) & " n_cols=" &
                   integer'image(cl) &
                   " is LEGAL and never completed (timeout " &
                   integer'image(tmo) & ")" severity error;
          end if;
        else
          n_teeth := n_teeth + 1;
          if st(2) /= '1' or ec /= 16#F# then
            nerr := nerr + 1;
            report "SHAPE n_rows=" & integer'image(rw) & " n_cols=" &
                   integer'image(cl) & " with w_beats=" &
                   integer'image(wbm) & " s_beats=" & integer'image(sbm) &
                   " (correct is " & integer'image(wbx) & "/" &
                   integer'image(sbx) & ") was NOT refused with EC_SHAPE: " &
                   "err=" & std_logic'image(st(2)) & " code=" &
                   integer'image(ec) severity error;
          end if;
        end if;
        cap_en <= '0';
        wait until rising_edge(clk);
      end loop;
    end loop;
    report "shape sweep, FK33 arm (ROWS_IF=" & integer'image(RI) &
           ", GRP=" & integer'image(GRP_A) & "): " &
           integer'image(n_legal) & " legal shapes accepted, " &
           integer'image(n_teeth) & " one-off beat-count mutations refused"
      severity note;

    -- ------------------------------------------- the same sweep at GRP = 2
    -- The FK33 arm cannot see the ceil in s_beats = ceil(w_beats/GRP),
    -- because GRP is 1 there and the two are equal.  This arm has GRP = 2, so
    -- a check that dropped the ceil refuses every shape with w_beats > 1, and
    -- one that used floor refuses the three shapes whose w_beats is odd.
    n_legal := 0; n_teeth := 0;
    for i in 0 to NSHAPB-1 loop
      rw  := BS_ROWS(i); cl := BS_COLS(i);
      wbx := ((rw + B_RI - 1) / B_RI) * ((cl + BLK - 1) / BLK);
      sbx := (wbx + B_GRP - 1) / B_GRP;

      for k in 0 to 4 loop
        wbm := wbx; sbm := sbx;
        if    k = 1 then wbm := wbx - 1;
        elsif k = 2 then wbm := wbx + 1;
        elsif k = 3 then sbm := sbx - 1;
        elsif k = 4 then sbm := sbx + 1; end if;
        next when wbm = 0 or sbm = 0;
        -- Belt and braces.  A one-off on s_beats provably leaves the
        -- bracket at any GRP >= 1 -- (sb-1)*GRP <= w-1 < w kills sb-1, and
        -- sb*GRP >= w kills sb+1 -- so this guard is not expected to fire.
        -- It is here so that a future GRP cannot turn a NON-error into an
        -- expected error and be scored as a pass.
        next when k = 3 and (sbm * B_GRP >= wbx) and ((sbm-1) * B_GRP < wbx);
        next when k = 4 and (sbm * B_GRP >= wbx) and ((sbm-1) * B_GRP < wbx);

        aresetn <= '0';
        for j in 0 to 7 loop wait until rising_edge(clk); end loop;
        aresetn <= '1';
        wait until rising_edge(clk);
        bbuild(rw, cl, wbm, sbm);
        wait until rising_edge(clk);

        ptr := resize(lift(B_DOFF), 64);
        bawr(16#00#, std_logic_vector(ptr(31 downto 0)));
        bawr(16#04#, std_logic_vector(ptr(63 downto 32)));
        bawr(16#08#, x"00000001");
        -- An ACCEPTED descriptor starts a core with no weight slaves, so it
        -- stays busy for ever: the verdict is read after a fixed, generous
        -- window rather than by polling for done.  The window covers the
        -- 9-beat fetch, the shape loop's max(TILES, NBMAX) = 128 cycles and
        -- the 16-cycle codebook load -- about 180 cycles in all -- four times
        -- over.
        for j in 0 to 800 loop wait until rising_edge(clk); end loop;
        bard(16#0C#, bst);
        ec := to_integer(unsigned(bst(11 downto 8)));

        if k = 0 then
          n_legal := n_legal + 1;
          if bst(2) = '1' then
            nerr := nerr + 1;
            report "AXU3EG SHAPE n_rows=" & integer'image(rw) & " n_cols=" &
                   integer'image(cl) & " w_beats=" & integer'image(wbx) &
                   " s_beats=" & integer'image(sbx) &
                   " is LEGAL and was REFUSED, err_code = " &
                   integer'image(ec) severity error;
          end if;
        else
          n_teeth := n_teeth + 1;
          if bst(2) /= '1' or ec /= 16#F# then
            nerr := nerr + 1;
            report "AXU3EG SHAPE n_rows=" & integer'image(rw) & " n_cols=" &
                   integer'image(cl) & " with w_beats=" &
                   integer'image(wbm) & " s_beats=" & integer'image(sbm) &
                   " (correct is " & integer'image(wbx) & "/" &
                   integer'image(sbx) & ") was NOT refused with EC_SHAPE: " &
                   "err=" & std_logic'image(bst(2)) & " code=" &
                   integer'image(ec) severity error;
          end if;
        end if;
      end loop;
    end loop;
    report "shape sweep, AXU3EG arm (ROWS_IF=" & integer'image(B_RI) &
           ", GRP=" & integer'image(B_GRP) & "): " &
           integer'image(n_legal) & " legal shapes accepted, " &
           integer'image(n_teeth) & " one-off beat-count mutations refused"
      severity note;

    -- ======================================================= the case loop
    for mut in 0 to NCASE loop
      -- a fresh reset per case: err / err_code / err_addr are sticky by
      -- design, so a case that inherited them would judge the previous one
      aresetn <= '0';
      for i in 0 to 7 loop wait until rising_edge(clk); end loop;
      aresetn <= '1';
      wait until rising_edge(clk);

      cap_en <= '0'; cap_clr <= '1';
      build(mut);
      wait until rising_edge(clk);
      cap_clr <= '0';
      wait until rising_edge(clk);

      ptr := resize(lift(DESC_OFF), 64);
      if mut = 17 then ptr := ptr + 8; end if;         -- not 64 B aligned
      if mut = 18 then ptr(ADDR_W) := '1'; end if;     -- above ADDR_W

      awr(16#00#, std_logic_vector(ptr(31 downto 0)));
      awr(16#04#, std_logic_vector(ptr(63 downto 32)));

      -- ERR_ADDR is checked at WRITE time, so it must already be set here for
      -- case 18 and clear for every other case.  That is the tooth the old
      -- register map had and the one this map had to keep.
      ard(16#0C#, st);
      if mut = 18 then
        if st(4) /= '1' then
          nerr := nerr + 1;
          report "CASE 18: ERR_ADDR did NOT latch at DESC_PTR_HI write time"
            severity error;
        end if;
      else
        if st(4) /= '0' then
          nerr := nerr + 1;
          report "CASE " & integer'image(mut) &
                 ": ERR_ADDR latched on a legal pointer" severity error;
        end if;
      end if;

      cap_en <= '1';
      awr(16#08#, x"00000001");                        -- GO

      -- ------------------------------------------------------- wait it out
      tmo := 0;
      loop
        ard(16#0C#, st);
        exit when st(0) = '1' or st(2) = '1';
        tmo := tmo + 1;
        exit when tmo > 40000;
      end loop;
      ec := to_integer(unsigned(st(11 downto 8)));
      ncase_run <= mut + 1;

      -- ----------------------------------------------------------- judge
      if CASE_EXP(mut) = EXP_OK then
        ok := true;
        if st(2) = '1' then
          ok := false;
          report "CASE 0 (" & CASE_NAME(mut) & "): REJECTED, err_code = " &
                 integer'image(ec) severity error;
        end if;
        if st(0) /= '1' then
          ok := false;
          report "CASE 0: never reported done (timeout " &
                 integer'image(tmo) & ")" severity error;
        end if;
        -- every element, as a full 64-bit vector, off the core's own bus
        if nchk /= t_rows then
          ok := false;
          report "CASE 0: expected " & integer'image(t_rows) &
                 " rows, saw " & integer'image(nchk) &
                 " -- the row count IS WRONG" severity error;
        end if;
        if nbad /= 0 then
          ok := false;
          report "CASE 0: " & integer'image(nbad) &
                 " element MISMATCHes against ref/matvec_int4.c"
            severity error;
        end if;
        -- and again through the AXI-Lite map, which is the path a driver uses
        nrb := 0; nrbad := 0;
        for r in 0 to t_rows-1 loop
          awr(16#24#, std_logic_vector(to_unsigned(r, 32)));
          ard(16#28#, lo);
          ard(16#2C#, hi);
          got  := hi & lo;
          want := e_ymant(r);
          nrb := nrb + 1;
          if got /= want then nrbad := nrbad + 1; end if;
        end loop;
        if nrbad /= 0 then
          ok := false;
          report "CASE 0: " & integer'image(nrbad) & " of " &
                 integer'image(nrb) &
                 " rows read back through the AXI-Lite map MISMATCH"
            severity error;
        end if;
        ard(16#30#, rd);
        if to_integer(signed(rd)) /= e_yexp then
          ok := false;
          report "CASE 0: Y_EXP MISMATCH got " &
                 integer'image(to_integer(signed(rd))) & " want " &
                 integer'image(e_yexp) severity error;
        end if;
        if (st(3) = '1') /= (e_satev = 1) then
          ok := false;
          report "CASE 0: SAT_EVENT MISMATCH" severity error;
        end if;
        if ok then
          report "CASE  0 " & CASE_NAME(mut) & " OK -- " &
                 integer'image(nchk) & " elements bit-exact on the core bus, " &
                 integer'image(nrb) & " rows bit-exact through AXI-Lite, y_exp=" &
                 integer'image(e_yexp) severity note;
        else
          nerr := nerr + 1;
        end if;

      elsif CASE_EXP(mut) = EXP_WRONG then
        -- The design is not expected to see this.  What it must NOT do is
        -- produce the right answer, because then the mutation proved nothing.
        if st(2) = '1' then
          report "CASE " & integer'image(mut) & " " & CASE_NAME(mut) &
                 " -> DETECTED, err_code = " & integer'image(ec) severity note;
        elsif st(0) /= '1' then
          report "CASE " & integer'image(mut) & " " & CASE_NAME(mut) &
                 " -> NO COMPLETION (stalled; " & integer'image(nchk) &
                 " elements emitted). Not silently wrong, but not an error " &
                 "either -- this is a liveness gap" severity note;
        elsif nbad = 0 and nchk = t_rows then
          nerr := nerr + 1;
          report "CASE " & integer'image(mut) & " " & CASE_NAME(mut) &
                 " -> SILENT PASS: the mutated descriptor produced the " &
                 "REFERENCE answer, so this mutation tests NOTHING"
            severity error;
        else
          report "CASE " & integer'image(mut) & " " & CASE_NAME(mut) &
                 " -> UNDETECTED but wrong: " & integer'image(nbad) &
                 " of " & integer'image(nchk) &
                 " elements differ from the reference" severity note;
        end if;

      else
        -- must refuse, with exactly this code, and must not compute
        ok := true;
        if st(2) /= '1' then
          ok := false;
          report "CASE " & integer'image(mut) & " " & CASE_NAME(mut) &
                 " -> NOT DETECTED: no err after " & integer'image(tmo) &
                 " polls (done=" & std_logic'image(st(0)) & ")" severity error;
        elsif ec /= CASE_EXP(mut) then
          ok := false;
          report "CASE " & integer'image(mut) & " " & CASE_NAME(mut) &
                 " -> wrong err_code: got " & integer'image(ec) &
                 " want " & integer'image(CASE_EXP(mut)) severity error;
        end if;
        if st(0) = '1' then
          ok := false;
          report "CASE " & integer'image(mut) & " " & CASE_NAME(mut) &
                 " -> reported DONE as well as err" severity error;
        end if;
        if nchk /= 0 then
          ok := false;
          report "CASE " & integer'image(mut) & " " & CASE_NAME(mut) &
                 " -> emitted " & integer'image(nchk) &
                 " result elements despite being rejected" severity error;
        end if;
        if ok then
          ard(16#10#, rd);
          report "CASE " & integer'image(mut) & " " & CASE_NAME(mut) &
                 " -> refused, err_code = " & integer'image(ec) &
                 ", ERR_INFO = " &
                 integer'image(to_integer(unsigned(rd(15 downto 0))))
            severity note;
        else
          nerr := nerr + 1;
        end if;
      end if;

      cap_en <= '0';
      d_deaf <= '0';
      wait until rising_edge(clk);
    end loop;

    nfail <= nerr;
    wait until rising_edge(clk);

    report "tb_matvec_fk33_desc: " & integer'image(NCASE + 1) &
           " cases run, " & integer'image(nerr) & " failures" severity note;
    assert nerr = 0
      report "SUBSYSTEM A'S DESCRIPTOR CONTROL PLANE FAILED " &
             integer'image(nerr) & " CASES" severity failure;
    report "subsystem A is bit-exact with ref/matvec_int4.c through the " &
           "descriptor control plane, and every checked mutation is refused"
      severity note;
    finished <= true;
    wait;
  end process;
end architecture;
