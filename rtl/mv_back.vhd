-- rtl/mv_back.vhd -- the a450 A back end, in clk_core (spec 2.3, 2.4).
--
-- Everything of rtl/matvec_core.vhd that needs the whole matrix or talks to the outside
-- lives here, unchanged in meaning:
--   * the spec 7.6 start checks (bad n_rows / n_cols / out_shift, BFP above MAXROWS_BFP):
--     err and done, and the fast side is never started;
--   * the codebook, written in idle exactly as before (a cb_we cycle ignores start);
--   * the job values the fast side reads (j_*), held from the start pulse to the next
--     start, and the one-cycle j_go that rtl/mv_tsync.vhd carries to aclk_a;
--   * the result words from the crossing, NT per row-tile in tile order, assembled into
--     one ROWS_IF-row beat, then the y outputs: raw and partial beats go out at once,
--     BFP beats go to ybuf and the masked max fold, then SCAN and EMIT as before;
--   * sat_event (sticky, cleared by an accepted start), err, done, y_exp;
--   * w_beat / w_words, so the descriptor plane's BEATS still reads tiles * nb.
-- Rows past n_rows are masked (y_mask, and out of the BFP max) exactly as before.  The
-- tiles compute sat on every row, pad rows included, as matvec_core does.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mv4i_arith_pkg.all;
use work.util_pkg.all;

entity mv_back is
  generic(
    BLK         : positive := 32;
    ROWS_IF     : positive := 48;
    MAXCOLS     : positive := 17408;
    MAXROWS_BFP : positive := 17408
  );
  port(
    clk, rst  : in  std_logic;
    start     : in  std_logic;
    n_rows    : in  integer;
    n_cols    : in  integer;
    out_shift : in  integer;
    w_exp     : in  integer;
    x_exp     : in  integer;
    out_mode  : in  std_logic_vector(1 downto 0);
    cb_we     : in  std_logic;
    cb_addr   : in  std_logic_vector(3 downto 0);
    cb_data   : in  std_logic_vector(7 downto 0);
    j_go      : out std_logic;
    j_nb      : out natural;
    j_rows    : out natural;
    j_lastv   : out natural;
    j_os      : out std_logic_vector(5 downto 0);
    j_mode    : out std_logic_vector(1 downto 0);
    j_cb      : out std_logic_vector(127 downto 0);
    q_valid   : in  std_logic;
    q_data    : in  std_logic_vector(96 downto 0);
    q_ready   : out std_logic;
    y_we      : out std_logic;
    y_addr    : out std_logic_vector(15 downto 0);
    y_data    : out std_logic_vector(ROWS_IF*64-1 downto 0);
    y_mask    : out std_logic_vector(ROWS_IF-1 downto 0);
    y_exp     : out integer;
    done      : out std_logic;
    err       : out std_logic;
    sat_event : out std_logic;
    -- one pulse per row-tile beat taken, and the weight words it stands for (nb):
    -- matvec_int4_desc_axi's BEATS register adds w_words on each w_beat
    w_beat    : out std_logic;
    w_words   : out natural
  );
end entity;

architecture rtl of mv_back is
  constant NT    : positive := ROWS_IF / 2;
  constant TILES : positive := (MAXROWS_BFP + ROWS_IF - 1) / ROWS_IF;
  function ybuf_addr(t : integer) return integer is
  begin
    if t >= TILES then return TILES - 1; else return t; end if;
  end function;
  function lvl_of(r : positive) return positive is
    variable c : natural := clog2(r);
  begin
    if c = 0 then return 1; else return c; end if;
  end function;
  constant LVLR   : positive := lvl_of(ROWS_IF);
  constant MAXPOW : positive := 2 ** LVLR;
  constant HALF   : positive := MAXPOW / 2;

  type st_t is (B_IDLE, B_RUN, B_DRAIN, B_SCAN, B_EMIT, B_DONE);
  signal st : st_t := B_IDLE;
  signal cbk : std_logic_vector(127 downto 0) := (others => '0');
  signal go_r : std_logic := '0';
  signal nb_r, rows_r, lastv_r : natural := 0;
  signal os_r : natural range 0 to 63 := 0;
  signal md_r : std_logic_vector(1 downto 0) := "00";
  signal sat_r, err_r : std_logic := '0';
  -- assembly
  type asm_t is array(0 to NT-1) of std_logic_vector(95 downto 0);
  signal asm  : asm_t := (others => (others => '0'));
  signal wi   : natural range 0 to NT-1 := 0;
  signal asat : std_logic := '0';
  signal bt_v, bt_sat : std_logic := '0';
  signal bt_rows : std_logic_vector(ROWS_IF*48-1 downto 0) := (others => '0');
  signal rows_left, rbase : integer := 0;
  -- Plain integers, as matvec_core's t_iss/tiles_r: a raw or partial job may have far
  -- more than MAXROWS_BFP rows (the LM head), and only a BFP job indexes ybuf with them.
  signal t_cnt, tiles_r : integer := 0;
  -- BFP
  type ybuf_t is array(0 to TILES-1) of std_logic_vector(ROWS_IF*32-1 downto 0);
  signal ybuf : ybuf_t;
  attribute ram_style : string;
  attribute ram_style of ybuf : signal is "block";
  signal ybuf_q : std_logic_vector(ROWS_IF*32-1 downto 0) := (others => '0');
  type mag_arr is array(0 to ROWS_IF-1) of unsigned(35 downto 0);
  signal re3_v : std_logic := '0';
  signal re3_mag : mag_arr := (others => (others => '0'));
  signal re3_ok : std_logic_vector(ROWS_IF-1 downto 0) := (others => '0');
  type wide_mag is array(0 to MAXPOW-1) of unsigned(35 downto 0);
  type fold_arr is array(0 to LVLR*HALF-1) of unsigned(35 downto 0);
  signal fold   : fold_arr := (others => (others => '0'));
  signal fold_v : std_logic_vector(LVLR-1 downto 0) := (others => '0');
  signal amax   : unsigned(35 downto 0) := (others => '0');
  signal ns_r   : natural range 0 to 63 := 0;
  signal rd_t, rd_td : integer range 0 to TILES := 0;
  signal rd_v, em_v : std_logic := '0';
  signal em_t : integer := 0;
  type em_arr is array(0 to ROWS_IF-1) of signed(31 downto 0);
  signal em_shv : em_arr := (others => (others => '0'));
begin
  j_go <= go_r; j_nb <= nb_r; j_rows <= rows_r; j_lastv <= lastv_r;
  j_os <= std_logic_vector(to_unsigned(os_r, 6)); j_mode <= md_r; j_cb <= cbk;
  q_ready <= '1' when st = B_RUN else '0';
  w_beat  <= bt_v;
  w_words <= nb_r;

  process(clk)
    variable v48  : signed(47 downto 0);
    variable a32  : signed(31 downto 0);
    variable ynew : std_logic_vector(ROWS_IF*32-1 downto 0);
    variable wm   : wide_mag;
    variable ymn  : signed(15 downto 0);
    variable rb   : integer;
    variable fv   : std_logic;
  begin
    if rising_edge(clk) then
      y_we <= '0'; done <= '0'; go_r <= '0'; bt_v <= '0'; re3_v <= '0';

      if rst = '1' then
        st <= B_IDLE; sat_r <= '0'; err_r <= '0'; wi <= 0; asat <= '0';
        fold_v <= (others => '0');
      else
        -- assembly: NT words, tile order, per row-tile
        if st = B_RUN and q_valid = '1' then
          if wi = NT-1 then
            for k in 0 to NT-2 loop
              bt_rows(k*96+95 downto k*96) <= asm(k);
            end loop;
            bt_rows(ROWS_IF*48-1 downto (NT-1)*96) <= q_data(95 downto 0);
            bt_sat <= asat or q_data(96);
            bt_v <= '1';
            wi <= 0; asat <= '0';
          else
            asm(wi) <= q_data(95 downto 0);
            asat <= asat or q_data(96);
            wi <= wi + 1;
          end if;
        end if;

        -- one beat: raw/partial out now, BFP to ybuf and the fold
        if bt_v = '1' then
          if bt_sat = '1' then sat_r <= '1'; end if;
          for rr in 0 to ROWS_IF-1 loop
            v48 := signed(bt_rows(rr*48+47 downto rr*48));
            a32 := v48(31 downto 0);
            ynew(rr*32+31 downto rr*32) := std_logic_vector(a32);
            y_data(rr*64+63 downto rr*64) <= std_logic_vector(resize(v48, 64));
            re3_mag(rr) <= unsigned(abs(resize(a32, 36)));
            if rbase + rr < n_rows then
              y_mask(rr) <= '1'; re3_ok(rr) <= '1';
            else
              y_mask(rr) <= '0'; re3_ok(rr) <= '0';
            end if;
          end loop;
          y_addr <= std_logic_vector(to_unsigned(rbase, 16));
          if md_r = "00" then
            ybuf(ybuf_addr(t_cnt)) <= ynew;
            re3_v <= '1';
          else
            y_we <= '1';
          end if;
          t_cnt <= t_cnt + 1; tiles_r <= t_cnt + 1;
          rbase <= rbase + ROWS_IF;
          if rows_left <= ROWS_IF then
            if md_r = "00" then st <= B_DRAIN; else st <= B_DONE; end if;
          else
            rows_left <= rows_left - ROWS_IF;
          end if;
        end if;

        -- the masked max fold, one register stage per level (matvec_core's)
        fold_v(0) <= re3_v;
        if re3_v = '1' then
          for rr in 0 to ROWS_IF-1 loop
            if re3_ok(rr) = '1' then wm(rr) := re3_mag(rr); else wm(rr) := (others => '0'); end if;
          end loop;
          for rr in ROWS_IF to MAXPOW-1 loop wm(rr) := (others => '0'); end loop;
          for i in 0 to HALF-1 loop
            if wm(2*i+1) > wm(2*i) then fold(i) <= wm(2*i+1); else fold(i) <= wm(2*i); end if;
          end loop;
        end if;
        for sg in 1 to LVLR-1 loop
          fold_v(sg) <= fold_v(sg-1);
          if fold_v(sg-1) = '1' then
            for i in 0 to (MAXPOW / (2**(sg+1))) - 1 loop
              if fold((sg-1)*HALF + 2*i+1) > fold((sg-1)*HALF + 2*i) then
                fold(sg*HALF + i) <= fold((sg-1)*HALF + 2*i+1);
              else
                fold(sg*HALF + i) <= fold((sg-1)*HALF + 2*i);
              end if;
            end loop;
          end if;
        end loop;
        if fold_v(LVLR-1) = '1' and fold((LVLR-1)*HALF) > amax then
          amax <= fold((LVLR-1)*HALF);
        end if;

        ybuf_q <= ybuf(ybuf_addr(rd_t));

        case st is
          when B_IDLE =>
            if cb_we = '1' then
              cbk(to_integer(unsigned(cb_addr))*8+7 downto to_integer(unsigned(cb_addr))*8)
                <= cb_data;
            elsif start = '1' then
              if n_rows <= 0 or n_cols <= 0 or n_cols > MAXCOLS
                 or out_shift < 0 or out_shift > 40
                 or (out_mode = "00" and n_rows > MAXROWS_BFP) then
                err_r <= '1'; st <= B_DONE;
              else
                nb_r    <= (n_cols + BLK - 1) / BLK;
                lastv_r <= n_cols - ((n_cols - 1) / BLK) * BLK;
                rows_r  <= n_rows;
                rows_left <= n_rows;
                os_r    <= out_shift;
                md_r    <= out_mode;
                rbase <= 0; t_cnt <= 0; tiles_r <= 0;
                wi <= 0; asat <= '0';
                amax <= (others => '0');
                sat_r <= '0'; err_r <= '0';
                go_r <= '1';
                st <= B_RUN;
              end if;
            end if;

          when B_RUN =>
            null;

          when B_DRAIN =>
            fv := re3_v or bt_v;
            for i in 0 to LVLR-1 loop fv := fv or fold_v(i); end loop;
            if fv = '0' then st <= B_SCAN; end if;

          when B_SCAN =>
            if msb_pos_u(amax) > 14 then ns_r <= msb_pos_u(amax) - 14;
            else ns_r <= 0; end if;
            rd_t <= 0; rd_v <= '0'; em_v <= '0';
            st <= B_EMIT;

          when B_EMIT =>
            if rd_t < tiles_r then
              rd_v <= '1'; rd_td <= rd_t; rd_t <= rd_t + 1;
            else
              rd_v <= '0';
            end if;
            em_v <= rd_v; em_t <= rd_td;
            if rd_v = '1' then
              for rr in 0 to ROWS_IF-1 loop
                em_shv(rr) <= resize(round_shift(signed(ybuf_q(rr*32+31 downto rr*32)), ns_r), 32);
              end loop;
            end if;
            if em_v = '1' then
              rb := em_t * ROWS_IF;
              y_we <= '1';
              y_addr <= std_logic_vector(to_unsigned(rb, 16));
              for rr in 0 to ROWS_IF-1 loop
                ymn := sat16(em_shv(rr));
                y_data(rr*64+63 downto rr*64) <= std_logic_vector(resize(ymn, 64));
                if rb + rr < n_rows then y_mask(rr) <= '1'; else y_mask(rr) <= '0'; end if;
              end loop;
              if em_t = tiles_r - 1 then st <= B_DONE; end if;
            end if;

          when B_DONE =>
            done <= '1';
            st <= B_IDLE;
        end case;
      end if;
    end if;
  end process;

  y_exp <= (w_exp + x_exp)               when out_mode = "10" else
           (w_exp + x_exp - os_r - ns_r) when out_mode = "00" else
           (w_exp + x_exp - os_r);
  err       <= err_r;
  sat_event <= sat_r;
end architecture;
