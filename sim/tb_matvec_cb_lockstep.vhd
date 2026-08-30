-- sim/tb_matvec_cb_lockstep.vhd -- the codebook replicas, written and read.
--
-- WHY THIS EXISTS.  matvec_core's codebook is replicated per row so that the
-- 16-entry table is not one register file with ROWS_IF*BLK consumers spread
-- across the die (see the cb declaration in rtl/matvec_core.vhd, and
-- docs/debugging/2026-08-27_matvec-codebook-replication.md).  Replication
-- introduces a failure mode the single-copy version could not have: a set of
-- replicas that is half old and half new, or a set that is uniformly LATE.
-- Neither is a crash.  Both are a silently wrong codebook.
--
-- Divergence between replicas is caught structurally by P_CB_CHK inside the
-- core, in every testbench that instantiates it.  THIS testbench covers the
-- other half, which no assertion inside the core can see: whether a codebook
-- loaded on the TIGHTEST LEGAL SCHEDULE is visible to the lanes before the
-- first beat reads them.  It was written because the obvious candidate for
-- that job does not do it -- tb_matvec_core loads CB lines from the head of
-- its trace file and starts many cycles later, and MEASURABLY still passes
-- with the codebook write delayed by four cycles.
--
-- THE PROPERTY, and it needs no numeric model of the contract:
--
--   the same operation, with the same codebook, must give a BIT-IDENTICAL
--   result whether the codebook was loaded twenty cycles before start or one.
--
-- Run C is the teeth check inside the test.  A different codebook must give a
-- DIFFERENT result; without it, runs A and B could agree because the codebook
-- reaches nothing at all, and the test would pass while proving nothing.
-- Run D loads the first codebook back, so a write path that latches once and
-- then ignores later writes also fails.
--
-- Shape: one tile, one block, ROWS_IF = 4, BLK = 8, out_mode = "01" (raw).
-- Raw mode is deliberate -- it emits the int32 straight out of row end, with
-- no BFP normalisation that could map two different codebooks onto the same
-- mantissa and hide a difference run C depends on seeing.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_matvec_cb_lockstep is
  generic(
    BLK     : positive := 8;
    ROWS_IF : positive := 4;
    -- The core's default is 1 (one copy per row).  Overriding it here to
    -- ROWS_IF collapses the bank to a single copy, which is how you confirm
    -- this testbench is not passing because replication is absent.
    CB_ROWS_PER_COPY : positive := 1;
    -- LEVER C.  "regs" is the shipping register bank plus a 16:1 mux per lane;
    -- "distributed" is one table per LANE, the LUTRAM shape.  The DEFAULT IS
    -- THE SHIPPING VALUE on purpose: this bench is a gate row, and a gate row
    -- must measure what is on the card.  Drive the other value explicitly.
    CB_STYLE : string := "regs"
  );
end entity;

architecture tb of tb_matvec_cb_lockstep is
  constant TCK : time := 10 ns;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';
  signal running : boolean := true;

  signal n_rows, n_cols, out_shift, w_exp, x_exp, y_exp : integer := 0;
  signal out_mode : std_logic_vector(1 downto 0) := "01";

  signal cb_we   : std_logic := '0';
  signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
  signal cb_data : std_logic_vector(7 downto 0) := (others => '0');

  signal w_valid : std_logic := '0';
  signal w_ready : std_logic;
  signal w_data  : std_logic_vector(ROWS_IF*BLK*4-1 downto 0) := (others => '0');
  signal s_valid : std_logic := '0';
  signal s_ready : std_logic;
  signal s_data  : std_logic_vector(ROWS_IF*16-1 downto 0) := (others => '0');

  signal x_rbaddr : std_logic_vector(15 downto 0);
  signal x_rdata  : std_logic_vector(BLK*16-1 downto 0) := (others => '0');
  signal xword    : std_logic_vector(BLK*16-1 downto 0) := (others => '0');

  signal y_we   : std_logic;
  signal y_addr : std_logic_vector(15 downto 0);
  signal y_data : std_logic_vector(ROWS_IF*64-1 downto 0);
  signal y_mask : std_logic_vector(ROWS_IF-1 downto 0);
  signal done, err, sat_event : std_logic;

  -- captured result of the run in progress
  signal cap    : std_logic_vector(ROWS_IF*64-1 downto 0) := (others => '0');
  signal cap_n  : integer := 0;

  type cbv_t is array(0 to 15) of integer;
  -- Two codebooks that differ in EVERY entry, so no choice of weight nibbles
  -- can make runs A and C agree by only touching entries they share.
  constant CB1 : cbv_t := (-127, -104, -83, -65, -49, -35, -22, -10,
                             1,   13,  25,  38,  53,  69,  89, 113);
  constant CB2 : cbv_t := ( 113,   89,  69,  53,  38,  25,  13,   1,
                           -10,  -22, -35, -49, -65, -83,-104,-127);
begin

  clk <= (not clk) after TCK/2 when running else '0';

  ------------------------------------------------------------------ act mem
  -- One block, and the core's contract is a 1-cycle registered read.
  process(clk) begin
    if rising_edge(clk) then
      if to_integer(unsigned(x_rbaddr)) = 0 then x_rdata <= xword;
      else                                       x_rdata <= (others => '0'); end if;
    end if;
  end process;

  ------------------------------------------------------------------ capture
  process(clk) begin
    if rising_edge(clk) then
      if y_we = '1' then
        cap   <= y_data;
        cap_n <= cap_n + 1;
      end if;
    end if;
  end process;

  dut : entity work.matvec_core
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, MAXCOLS => 4096,
                MAXROWS_BFP => 256, CB_ROWS_PER_COPY => CB_ROWS_PER_COPY,
                CB_STYLE => CB_STYLE)
    port map(clk => clk, rst => rst, start => start,
             n_rows => n_rows, n_cols => n_cols, out_shift => out_shift,
             w_exp => w_exp, x_exp => x_exp, out_mode => out_mode,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             w_valid => w_valid, w_data => w_data, w_ready => w_ready,
             s_valid => s_valid, s_data => s_data, s_ready => s_ready,
             x_rbaddr => x_rbaddr, x_rdata => x_rdata,
             y_we => y_we, y_addr => y_addr, y_data => y_data,
             y_mask => y_mask, y_exp => y_exp, done => done, err => err,
             sat_event => sat_event,
             tp_v => open, tc_v => open, ta_v => open, tm_v => open,
             tp_r => open, tc_r => open, ta_r => open, tm_r => open,
             tp_b => open, tc_b => open,
             tp_val => open, tc_val => open, ta_val => open, tm_val => open,
             tap_ns => open);

  ------------------------------------------------------------------ stimulus
  process
    variable yA, yB, yC, yD : std_logic_vector(ROWS_IF*64-1 downto 0);
    variable nseen : integer;

    procedure tick(n : natural) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    -- Load all sixteen entries.  One cb_we per cycle, back to back, which is
    -- also the shape the AXI wrapper produces.
    procedure load_cb(cbv : cbv_t) is
    begin
      for a in 0 to 15 loop
        cb_addr <= std_logic_vector(to_unsigned(a, 4));
        cb_data <= std_logic_vector(to_signed(cbv(a), 8));
        cb_we   <= '1';
        wait until rising_edge(clk);
      end loop;
      cb_we <= '0';
      -- Deliberately NO settling delay here.  The caller decides the gap
      -- between the last write and start, and that gap is the subject.
    end procedure;

    -- gap = 0 is the tightest legal schedule: start is asserted on the very
    -- next edge after the last cb_we falls.  The core's cb_we arm is what
    -- makes that the tightest -- start on the SAME edge as a cb_we is ignored
    -- by construction, so gap 0 is the first edge that can take it.
    procedure run_op(gap : natural; res : out std_logic_vector) is
    begin
      if gap > 0 then tick(gap); end if;
      nseen := cap_n;
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      -- the operation is tiny; give it room and then require it finished
      for i in 1 to 400 loop
        wait until rising_edge(clk);
        exit when done = '1';
      end loop;
      assert done = '1'
        report "tb_matvec_cb_lockstep: the operation never raised done"
        severity failure;
      assert err = '0'
        report "tb_matvec_cb_lockstep: the core reported err"
        severity failure;
      tick(2);
      assert cap_n = nseen + 1
        report "tb_matvec_cb_lockstep: expected exactly one y beat, saw " &
               integer'image(cap_n - nseen)
        severity failure;
      res := cap;
    end procedure;
  begin
    -- descriptor: one tile, one block
    n_rows    <= ROWS_IF;
    n_cols    <= BLK;
    out_shift <= 0;
    w_exp     <= 0;
    x_exp     <= 0;
    out_mode  <= "01";

    -- weights: nibble (rr,j) = (rr*BLK + j) mod 16, so between them the lanes
    -- touch every codebook entry and no two rows use the same set in the same
    -- order.
    for rr in 0 to ROWS_IF-1 loop
      for j in 0 to BLK-1 loop
        w_data((rr*BLK + j)*4 + 3 downto (rr*BLK + j)*4) <=
          std_logic_vector(to_unsigned((rr*BLK + j) mod 16, 4));
      end loop;
      -- scales are uint15 in a 16-bit field, MSB must be 0 (spec 6.5)
      s_data(rr*16+15 downto rr*16) <=
        std_logic_vector(to_unsigned(4096 + rr*37, 16));
    end loop;
    for j in 0 to BLK-1 loop
      xword(j*16+15 downto j*16) <=
        std_logic_vector(to_signed(97 * (j + 1) - 300, 16));
    end loop;

    rst <= '1';
    tick(4);
    rst <= '0';
    tick(2);
    w_valid <= '1';
    s_valid <= '1';
    tick(1);

    -- A: relaxed load, twenty cycles of slack before start.  The reference.
    load_cb(CB1);
    run_op(20, yA);

    -- B: the same codebook, loaded on the tightest legal schedule.
    load_cb(CB1);
    run_op(0, yB);
    assert yB = yA
      report "tb_matvec_cb_lockstep: FAIL -- a codebook loaded one cycle " &
             "before start gave a different result from the same codebook " &
             "loaded twenty cycles before it.  The replicas are not visible " &
             "to the lanes in time."
      severity failure;

    -- C: a different codebook, same tight schedule.  This must CHANGE the
    -- answer, or run B proved nothing.
    load_cb(CB2);
    run_op(0, yC);
    assert yC /= yA
      report "tb_matvec_cb_lockstep: FAIL -- two codebooks that differ in " &
             "every entry gave identical results.  The codebook is not " &
             "reaching the lanes at all, and the run B comparison above is " &
             "vacuous."
      severity failure;

    -- D: back to the first codebook, tight again.  Catches a write path that
    -- takes one load and then ignores the rest.
    load_cb(CB1);
    run_op(0, yD);
    assert yD = yA
      report "tb_matvec_cb_lockstep: FAIL -- reloading the original codebook " &
             "did not restore the original result."
      severity failure;

    report "tb_matvec_cb_lockstep: PASS -- codebook replicas are written in " &
           "lockstep and are visible to the lanes on the tightest legal " &
           "load-then-start schedule (4 runs, CB_ROWS_PER_COPY=" &
           integer'image(CB_ROWS_PER_COPY) & ")"
      severity note;
    running <= false;
    wait;
  end process;

end architecture;
