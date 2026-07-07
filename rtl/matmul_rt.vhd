-- rtl/matmul_rt.vhd -- Runtime-weight-addressed block-float matrix-vector block.
--
-- Same bit-exact algorithm as rtl/matmul.vhd (row-stream through a single shared
-- mac_array -> per-row scale_mul requant -> global integer-BFP re-pack via
-- msb_pos), but the weight matrix, its per-row MULT and SHFT are NO LONGER a
-- compile-time unconstrained-array GENERIC.  Instead ONE instance serves ALL 35
-- matmuls (7 matrices x 5 layers): the matrix is chosen at RUNTIME by `mat_sel`
-- and `layer`, and the weights are fetched from an on-chip ROM by a computed
-- address, read SYNCHRONOUSLY (registered address -> next-cycle data) so Vivado
-- infers Block RAM rather than baking a 3.6 Mbit distributed-LUT constant.
--
-- mat_sel : 0=WQ 1=WK 2=WV 3=WO 4=W1 5=W3 6=W2   (order matches the ROM layout)
-- layer   : 0..4
--
-- The per-matrix dims / clamp are looked up from a small constant table:
--   WQ 64x64  clamp   WK 32x64        WV 32x64        WO 64x64
--   W1 172x64 clamp   W3 172x64 clamp W2 64x172
--
-- ROM layout (three flat ROMs, all 0-based, concatenated in mat_sel order):
--   WROM   = WQ & WK & WV & WO & W1 & W3 & W2                (weight mantissas)
--   MROM   = *_MULT concatenated (per-row requant multiplier)
--   SROM   = *_SHIFT concatenated (per-row requant shift)
--   weight addr = MBASE_W(sel) + layer*STRIDE(sel) + row*COLS(sel) + col
--   mult/shift  = MBASE_S(sel) + layer*ROWS(sel)   + row
--
-- Because the ROM read has 1-cycle latency, a weight row is streamed one column
-- per cycle into a register file `wreg` (address issued a cycle ahead of the
-- capture), and only after the whole row is registered is the shared mac_array
-- pulsed -- so the MAC datapath is unchanged and the arithmetic stays bit-exact
-- with matmul.vhd.  Unused columns (col >= IN_COLS) contribute 0 because the
-- activation is masked to IN_COLS on load.
--
-- Synthesizable: no `real`, no TEXTIO.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;      -- msb_pos
use work.fixed_pkg.all;     -- scale_mul
use work.rom_init_pkg.all;  -- init_rom_hex (file-loaded BRAM)

entity matmul_rt is
  generic(
    MAXROWS : positive := 172;   -- largest OUT_ROWS (W1/W3)
    MAXCOLS : positive := 172;   -- largest IN_COLS  (W2)
    -- Directory holding the file-init ROMs (weights_mant/mult/shift.mem).
    -- Default resolves from sim/ for both GHDL and the OOC Vivado runs; a
    -- different build dir can override it.
    ROM_DIR : string := "../mem/rom/"
  );
  port(
    clk     : in  std_logic;
    rst     : in  std_logic;
    start   : in  std_logic;
    mat_sel : in  integer;                                   -- 0..6
    layer   : in  integer;                                   -- 0..4
    x_mant  : in  std_logic_vector(MAXCOLS*16-1 downto 0);
    x_exp   : in  integer;
    done    : out std_logic;
    o_mant  : out std_logic_vector(MAXROWS*16-1 downto 0);
    o_exp   : out integer
  );
end entity;

architecture rtl of matmul_rt is
  -- ---- Unified weight ROMs (concatenated in mat_sel order WQ,WK,WV,WO,W1,W3,W2)
  -- File-initialized BLOCK RAM.  Formerly one giant VHDL constant aggregate
  -- (WQ & WK & ... from work.weights_pkg) -- ~227K int16 + 2*3000 int32 literals
  -- that Vivado constant-folded, peaking ~25 GB during synth.  Now loaded at
  -- elaboration from mem/rom/*.mem (bit-identical, tools/gen_weight_mem.py) via
  -- rom_init_pkg.init_rom_hex -> Vivado infers file-init BRAM, light elaboration.
  constant WROM_N  : natural := 226560;  -- WQ..W2 mantissas, 5 layers each
  constant MSROM_N : natural := 3000;    -- *_MULT / *_SHIFT per-row scalars
  signal WROM : integer_vector(0 to WROM_N-1) :=
    init_rom_hex(ROM_DIR & "weights_mant.mem",  WROM_N,  16);
  signal MROM : integer_vector(0 to MSROM_N-1) :=
    init_rom_hex(ROM_DIR & "weights_mult.mem",  MSROM_N, 32);
  signal SROM : integer_vector(0 to MSROM_N-1) :=
    init_rom_hex(ROM_DIR & "weights_shift.mem", MSROM_N, 32);
  -- Force block-RAM inference (harmless user attribute under GHDL).
  attribute rom_style : string;
  attribute rom_style of WROM : signal is "block";
  attribute rom_style of MROM : signal is "block";
  attribute rom_style of SROM : signal is "block";

  -- ---- Per-matrix parameter tables (indexed by mat_sel) ----------------------
  type i7 is array(0 to 6) of integer;
  constant MBASE_W  : i7 := (0, 20480, 30720, 40960, 61440, 116480, 171520);
  constant MBASE_S  : i7 := (0,   320,   480,   640,   960,   1820,   2680);
  constant ROWS_T   : i7 := (64,   32,    32,    64,   172,    172,     64);
  constant COLS_T   : i7 := (64,   64,    64,    64,    64,     64,    172);
  constant STRIDE_T : i7 := (4096, 2048, 2048, 4096, 11008, 11008, 11008);
  constant CLAMP_T  : boolean_vector(0 to 6) :=
    (true, false, false, false, true, true, false);

  -- ---- Synchronous ROM read (registered addr + registered data -> BRAM) ------
  signal rom_addr  : integer range 0 to WROM'high := 0;
  signal ms_addr   : integer range 0 to MROM'high := 0;
  signal rom_data  : integer := 0;
  signal mult_data : integer := 0;
  signal shft_data : integer := 0;

  -- ---- Latched op parameters (stable across a pass) --------------------------
  signal xin      : std_logic_vector(MAXCOLS*16-1 downto 0) := (others=>'0');
  signal xexp_l   : integer := 0;
  signal wbase    : integer := 0;   -- MBASE_W(sel) + layer*STRIDE(sel)
  signal sbase    : integer := 0;   -- MBASE_S(sel) + layer*ROWS(sel)
  signal out_rows : integer range 1 to MAXROWS := 1;
  signal in_cols  : integer range 1 to MAXCOLS := 1;
  signal clampf   : boolean := false;

  -- ---- Weight-row register file + per-row requant scalars --------------------
  type wrarr is array(0 to MAXCOLS-1) of signed(15 downto 0);
  signal wreg   : wrarr := (others=>(others=>'0'));
  signal mult_r : integer := 0;
  signal shft_r : integer := 0;

  -- ---- Per-row int32 requant results + running max magnitude -----------------
  type i32arr is array(0 to MAXROWS-1) of integer;
  signal result_v : i32arr := (others=>0);

  -- Force to REGISTERS (not distributed LUTRAM): under engine congestion Vivado
  -- inferred these indexed arrays as uninitialized LUTRAM (non-deterministic HW).
  attribute ram_style : string;
  attribute ram_style of wreg     : signal is "registers";
  attribute ram_style of result_v : signal is "registers";
  signal max_abs  : integer := 0;

  -- ---- FSM -------------------------------------------------------------------
  type state_t is (S_IDLE, S_ROWSTART, S_LOAD, S_MAC_START, S_MAC_WAIT,
                   S_PACK, S_PACKR);
  signal state   : state_t := S_IDLE;
  signal cur_row : integer range 0 to MAXROWS-1 := 0;
  signal n       : integer range 0 to MAXCOLS := 0;
  signal pk      : integer range 0 to MAXROWS-1 := 0;
  signal sh_r    : integer := 0;   -- global BFP shift, computed once in S_PACK

  -- ---- Shared mac_array interface --------------------------------------------
  signal mac_start, mac_done : std_logic := '0';
  signal mac_acc : std_logic_vector(47 downto 0);
  signal w_row   : std_logic_vector(MAXCOLS*16-1 downto 0);
begin
  -- Drive the mac_array weight row combinationally from the registered wreg.
  gpack_w: for j in 0 to MAXCOLS-1 generate
    w_row((j+1)*16-1 downto j*16) <= std_logic_vector(wreg(j));
  end generate;

  mac: entity work.mac_array
    generic map(N=>MAXCOLS, P=>1, WW=>16, XW=>16, AW=>48)
    port map(clk=>clk, rst=>rst, start=>mac_start,
             x_vec=>xin, w_row=>w_row, done=>mac_done, acc=>mac_acc);

  -- Synchronous ROM reads: address is a registered FSM signal, data registered
  -- here -> classic block-ROM inference template.
  rom_rd: process(clk)
  begin
    if rising_edge(clk) then
      rom_data  <= WROM(rom_addr);
      mult_data <= MROM(ms_addr);
      shft_data <= SROM(ms_addr);
    end if;
  end process;

  fsm: process(clk)
    variable sel   : integer;
    variable ic    : integer;
    variable res32 : signed(31 downto 0);
    variable res_i : integer;
    variable av    : integer;
    variable p_msb : integer;
    variable sh    : integer;
    variable r32   : signed(31 downto 0);
    variable r64   : signed(63 downto 0);
    variable sat   : integer;
  begin
    if rising_edge(clk) then
      done      <= '0';
      mac_start <= '0';
      if rst = '1' then
        state   <= S_IDLE;
        cur_row <= 0;
        max_abs <= 0;
        o_exp   <= 0;
        o_mant  <= (others=>'0');
      else
        case state is
          when S_IDLE =>
            if start = '1' then
              sel := mat_sel;
              ic  := COLS_T(sel);
              -- latch op parameters
              out_rows <= ROWS_T(sel);
              in_cols  <= ic;
              clampf   <= CLAMP_T(sel);
              wbase    <= MBASE_W(sel) + layer*STRIDE_T(sel);
              sbase    <= MBASE_S(sel) + layer*ROWS_T(sel);
              xexp_l   <= x_exp;
              -- latch activation, masking columns >= IN_COLS to 0 so the
              -- fixed-width (MAXCOLS) MAC only sums the active columns.
              for j in 0 to MAXCOLS-1 loop
                if j < ic then
                  xin((j+1)*16-1 downto j*16) <= x_mant((j+1)*16-1 downto j*16);
                else
                  xin((j+1)*16-1 downto j*16) <= (others=>'0');
                end if;
              end loop;
              cur_row <= 0;
              max_abs <= 0;
              state   <= S_ROWSTART;
            end if;

          when S_ROWSTART =>
            -- Issue col-0 weight address and the per-row mult/shift address.
            rom_addr <= wbase + cur_row*in_cols;   -- col 0
            ms_addr  <= sbase + cur_row;
            n        <= 0;
            state    <= S_LOAD;

          when S_LOAD =>
            -- rom_data currently holds column (n-1); capture it. Requesting
            -- runs one column ahead of capture (col n+1 issued at counter n).
            if n >= 1 then
              wreg(n-1) <= to_signed(rom_data, 16);
            end if;
            if n = 1 then
              mult_r <= mult_data;   -- ms_addr data ready one cycle after issue
              shft_r <= shft_data;
            end if;
            if n < in_cols-1 then
              rom_addr <= wbase + cur_row*in_cols + (n+1);
            end if;
            if n = in_cols then
              state <= S_MAC_START;   -- wreg(0..in_cols-1) all registered
            else
              n <= n + 1;
            end if;

          when S_MAC_START =>
            mac_start <= '1';         -- w_row/xin stable -> kick shared MAC
            state     <= S_MAC_WAIT;

          when S_MAC_WAIT =>
            -- Sample acc in the SAME cycle mac_done pulses, then requant.
            if mac_done = '1' then
              res32 := scale_mul(signed(mac_acc),
                                 to_signed(mult_r, 32),
                                 shft_r);
              res_i := to_integer(res32);
              result_v(cur_row) <= res_i;
              av := res_i; if av < 0 then av := -av; end if;
              if av > max_abs then max_abs <= av; end if;
              if cur_row = out_rows-1 then
                state <= S_PACK;
              else
                cur_row <= cur_row + 1;
                state   <= S_ROWSTART;
              end if;
            end if;

          when S_PACK =>
            -- Compute the global BFP shift ONCE (max_abs holds the last row's
            -- contribution, folded in the previous delta -- as in matmul.vhd),
            -- clear the output, then re-pack ONE row per cycle in S_PACKR so a
            -- single requant datapath is time-multiplexed (NOT 172-wide unrolled).
            p_msb := msb_pos(max_abs);
            sh    := p_msb - 14;
            if clampf and sh < 0 then sh := 0; end if;
            sh_r   <= sh;
            o_exp  <= xexp_l - sh;
            o_mant <= (others=>'0');   -- rows >= out_rows stay 0
            pk     <= 0;
            state  <= S_PACKR;

          when S_PACKR =>
            -- Re-pack result_v(pk) with the shared shift/saturate datapath.
            if sh_r >= 0 then
              r32 := scale_mul(to_signed(result_v(pk), 64), to_signed(1, 32), sh_r);
              if    r32 >  32767 then sat :=  32767;
              elsif r32 < -32768 then sat := -32768;
              else                    sat := to_integer(r32);
              end if;
            else
              r64 := shift_left(to_signed(result_v(pk), 64), -sh_r);
              if    r64 >  32767 then sat :=  32767;
              elsif r64 < -32768 then sat := -32768;
              else                    sat := to_integer(r64);
              end if;
            end if;
            o_mant((pk+1)*16-1 downto pk*16) <= std_logic_vector(to_signed(sat, 16));
            if pk = out_rows-1 then
              done  <= '1';
              state <= S_IDLE;
            else
              pk    <= pk + 1;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
