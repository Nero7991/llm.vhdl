-- rtl/attention_ml.vhd
-- MULTI-LAYER (banked KV) variant of rtl/attention.vhd for the SHARED-datapath
-- engine (rtl/engine_shared.vhd).
--
-- IDENTICAL compute (scores / softmax / V-weighted sum + all exponent
-- bookkeeping) to attention.vhd -- the ONLY change is that the on-chip KV cache
-- now holds NLAYERS independent banks, selected at RUNTIME by the `layer` port,
-- so ONE attention compute datapath is time-multiplexed across all 5 transformer
-- layers (each layer keeps its own persistent K/V history at bank[layer]).
--
--   write/read slot  = layer*MAXPOS + pos       (one KVDIM-wide word per pos)
--   per-slot exp     = layer*MAXPOS + pos        (K,V block exps)
--
-- `rst` clears the position/pointer state (NOT the BRAM banks -- see below).
--
-- KV cache is held in SYNCHRONOUS BRAM (rtl/kv_mem.vhd), not signal arrays, so
-- attention_ml fits the XCZU3EG.  Each cache uses ONE word per (layer,pos) that
-- is KVDIM*16 bits wide (a whole position's K or V vector), so a single BRAM
-- read returns everything needed for one position.  Depth = NLAYERS*MAXPOS.
-- Access is registered-read (1-cycle latency): the position-sequential score
-- (S_SCORE) and weighted-sum (S_WACC) loops issue the read address for the next
-- position and consume the registered data one cycle later (a read-ahead bubble,
-- like matmul_rt), so the math is bit-identical to the array version.
--
-- BRAM cannot be mass-reset, so there is NO (others=>0) cache clear.  Attention
-- only reads positions 0..cur_pos, and every one of those was written earlier in
-- THIS run (each token writes its own K/V at cur_pos in S_IDLE before the passes
-- read positions 0..cur_pos), so write-before-read holds and no clear is needed.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;   -- msb_pos, clog2

entity attention_ml is
  generic(
    DIM       : positive := 64;
    HEAD_SIZE : positive := 8;
    NHEADS    : positive := 8;
    NKVH      : positive := 4;
    KVDIM     : positive := 32;   -- = NKVH*HEAD_SIZE
    MAXPOS    : positive := 8;    -- static cache depth per bank (>= cur_pos+1)
    NLAYERS   : positive := 5;    -- number of independent KV banks
    Q         : integer  := 12;   -- softmax Q-format (probs = prob_q / 2^Q)
    -- PROBES: synthesize the per-head / per-lane DIAGNOSTIC probe registers
    -- (p_sums / p_amax / p_amax_idx / p_nmax / p_nmax_idx).  Compute is
    -- untouched either way; when false the probe update branches are statically
    -- dead and Vivado prunes the registers.  engine_shared maps this to its own
    -- DEBUG_TAPS generic.
    PROBES    : boolean  := true
  );
  port(
    clk        : in  std_logic;
    rst        : in  std_logic;
    start      : in  std_logic;
    layer      : in  integer;     -- which KV bank (0..NLAYERS-1)
    cur_pos    : in  integer;
    -- current-position post-rope query (BFP: q[i] = q_mant[i]*2^-q_exp)
    q_mant     : in  std_logic_vector(DIM*16-1 downto 0);
    q_exp      : in  integer;
    -- current-position K (post-rope) / V (pre-rope) to store at slot cur_pos
    k_new_mant : in  std_logic_vector(KVDIM*16-1 downto 0);
    k_new_exp  : in  integer;
    v_new_mant : in  std_logic_vector(KVDIM*16-1 downto 0);
    v_new_exp  : in  integer;
    done       : out std_logic;
    -- attention output xb (BFP: xb[i] = xb_mant[i]*2^-xb_exp)
    xb_mant    : out std_logic_vector(DIM*16-1 downto 0);
    xb_exp     : out integer;
    -- DEBUG taps (last-head values, for HW non-determinism localisation):
    dbg_sc     : out integer;   -- sum of packed scores (softmax input)
    dbg_sum    : out integer;   -- softmax sum_l (divider denominator)
    dbg_num    : out integer;   -- sum of num_s lanes (weighted sum, divider numerator)
    -- ---- PER-HEAD / PER-LANE DIAGNOSTIC PROBES ---------------------------
    -- The dbg_sum/dbg_num taps above are gated `hd = 0`, so only HEAD 0 has ever
    -- been observed on silicon (and it reads bit-correct).  The QCLAMP guard
    -- firing proves some lane of xb_acc reaches >= 2^40 (correct max ~2^30.8), so
    -- the oversized lane is in one of the OTHER SEVEN heads.  These probes cover
    -- ALL heads/lanes and split the two candidate mechanisms:
    --   p_sums     : sum_l(31:0) for EACH head -> a tiny/zero softmax denominator
    --                on some head makes num*2^WQ/sum_l explode with no glitch.
    --   p_nmax     : max |num_s| over all 64 lanes (+ p_nmax_idx) -> a huge
    --                numerator instead.
    --   p_amax     : the final running |xb_acc| max that sets the output block
    --                exponent (+ p_amax_idx = WHICH lane produced it).
    -- lane index l decodes as head = l / HEAD_SIZE, in-head lane = l mod HEAD_SIZE.
    p_sums     : out std_logic_vector(NHEADS*32-1 downto 0);
    p_amax     : out std_logic_vector(63 downto 0);
    p_amax_idx : out std_logic_vector(7 downto 0);
    p_nmax     : out std_logic_vector(63 downto 0);
    p_nmax_idx : out std_logic_vector(7 downto 0);
    -- ---- FAILING-DIVISION probe (S_WDIV) -----------------------------------
    -- The probes above proved every divide INPUT is bit-correct on silicon
    -- (all 8 sum_l exact, max|num_s| exact in value AND lane) while amax_s came
    -- back as EXACTLY 2^40-1 = QCLAMP, first reached at lane 1 -- arithmetically
    -- impossible from those operands (|num|<=2^28, sum>=2^12 => q<=2^32).  So the
    -- next question is whether the DIVIDER got different operands than the probes
    -- reported (a capture/sequencing problem -- e.g. a stale `ns_dout` read) or
    -- computed a wrong quotient from good ones.  These taps record, for the FIRST
    -- division whose PRE-CLAMP quotient exceeds QCLAMP (the event itself, no lane
    -- hardcoded), the operands AS CONSUMED plus the raw quotient:
    --   p_cd_qmag = qmag BEFORE the clamp  (is the raw quotient already impossible?)
    --   p_cd_nmag = the dividend magnitude actually divided
    --   p_cd_nsd  = the raw num_s BRAM read (ns_dout) that fed the dividend
    --   p_cd_sum  = the divisor actually used (sum_l(31:0))
    --   p_cd_meta = {seen, cnt[6:0], hd[7:0], t_idx[7:0], lane[7:0]}
    --               seen = a clamping division was observed this call;
    --               cnt  = how many divisions clamped (saturating at 127).
    -- and the SAME operand set UNCONDITIONALLY for hd=0 / t_idx=1 (the lane the
    -- sticky amax_s pointed at on silicon), so it is visible even if the clamp
    -- ordering surprises us:  p_l1_qmag / p_l1_nsd / p_l1_sum.
    p_cd_qmag  : out std_logic_vector(63 downto 0);
    p_cd_nmag  : out std_logic_vector(63 downto 0);
    p_cd_nsd   : out std_logic_vector(63 downto 0);
    p_cd_sum   : out std_logic_vector(31 downto 0);
    p_cd_meta  : out std_logic_vector(31 downto 0);
    p_l1_qmag  : out std_logic_vector(63 downto 0);
    p_l1_nsd   : out std_logic_vector(63 downto 0);
    p_l1_sum   : out std_logic_vector(31 downto 0);
    -- ---- nmag / running-max-quotient capture (2026-07-26) ------------------
    -- The 52/24 narrowed divider removed the impossible-arithmetic failure (META
    -- reads 0 on silicon: no quotient ever exceeds its dividend any more), but a
    -- SMALL residual error remains: at hd=0/t_idx=1 both ns_dout (37614048) and
    -- sum_l (6788) read BIT-EXACT vs sim, yet qmag came back 364,600,439 instead
    -- of 363,151,775 (+0.4%).  Integer division on identical operands cannot
    -- differ, so one of the two must actually differ AT DIVIDE TIME.  The gap in
    -- the old probe set: `nmag` (the DIVIDEND the divider actually consumed) was
    -- only latched on a clamp event, and clamps no longer fire.
    --   p_l1_nmag : nmag at hd=0/t_idx=1, UNCONDITIONAL.  Sim expects
    --               ns_dout*2^16 + sum_l/2 = 37614048*65536 + 3394
    --               = 2,465,074,253,122 = 0x23DF1E00D42.
    -- And, because the WORST lane is not lane 1 and MOVES between sim (lane 26)
    -- and silicon (lane 36), the second capture is EVENT-FREE and lane-agnostic:
    -- it tracks the LARGEST pre-clamp qmag over all 64 divides of this call and
    -- latches that division's full operand set.  That division is the one that
    -- sets the sticky amax_s and therefore the output block exponent (HW 10 vs
    -- sim 15), so its operands are exactly what must be explained.
    --   p_qx_qmag / p_qx_nmag / p_qx_nsd / p_qx_sum = the winning division's
    --   pre-clamp quotient, dividend magnitude, raw num_s BRAM read and divisor.
    --   p_qx_meta = {valid[31], clamp_cnt[30:24], hd[23:16], t_idx[15:8], lane[7:0]}
    --   (clamp_cnt is carried here so the "clamps stay at zero" evidence survives
    --    even though the clamp-event block itself is no longer read back.)
    p_l1_nmag  : out std_logic_vector(63 downto 0);
    p_qx_qmag  : out std_logic_vector(63 downto 0);
    p_qx_nmag  : out std_logic_vector(63 downto 0);
    p_qx_nsd   : out std_logic_vector(63 downto 0);
    p_qx_sum   : out std_logic_vector(31 downto 0);
    p_qx_meta  : out std_logic_vector(31 downto 0)
  );
end entity attention_ml;

architecture rtl of attention_ml is
  constant KV_MUL : integer := NHEADS / NKVH;
  -- round(2^15 / sqrt(8)) = 11585  (1/sqrt(HEAD_SIZE), HEAD_SIZE=8)
  constant INV_SQRT8_Q15 : integer := 11585;

  -- ---- banked KV cache in BRAM -------------------------------------------
  -- One KVDIM-wide word per (layer,pos): a whole position's K (or V) vector.
  constant KVWORDS  : integer := NLAYERS*MAXPOS;   -- depth (words)
  constant KVW      : integer := KVDIM*16;         -- word width (a full pos vec)
  constant KVADDR_W : integer := clog2(KVWORDS);

  component kv_mem is
    generic(WORDS : positive; W : positive := 16);
    port(clk : in std_logic; we : in std_logic;
         waddr, raddr : in std_logic_vector(clog2(WORDS)-1 downto 0);
         din  : in  std_logic_vector(W-1 downto 0);
         dout : out std_logic_vector(W-1 downto 0));
  end component;

  signal kv_we    : std_logic;
  signal kv_waddr : std_logic_vector(KVADDR_W-1 downto 0);
  signal kv_raddr : std_logic_vector(KVADDR_W-1 downto 0);
  signal fetch_pos: integer := 0;               -- clamped read position 0..MAXPOS-1
  signal kc_v_do  : std_logic_vector(KVW-1 downto 0);   -- K mantissa word out
  signal vc_v_do  : std_logic_vector(KVW-1 downto 0);   -- V mantissa word out
  signal kc_e_do  : std_logic_vector(31 downto 0);      -- K block-exp out
  signal vc_e_do  : std_logic_vector(31 downto 0);      -- V block-exp out
  signal kc_e_di  : std_logic_vector(31 downto 0);      -- K block-exp in
  signal vc_e_di  : std_logic_vector(31 downto 0);      -- V block-exp in

  -- ---- per-element attention accumulators (value = acc * 2^-(Q+vref)) -----
  type acc_arr is array(0 to DIM-1) of signed(63 downto 0);
  signal xb_acc : acc_arr := (others => (others => '0'));

  -- ---- latches / bookkeeping --------------------------------------------
  signal cp      : integer := 0;   -- latched cur_pos
  signal lyr     : integer := 0;   -- latched layer (bank select)
  signal hd      : integer := 0;   -- current head
  signal vref_s  : integer := 0;   -- min vc_e over 0..cp
  signal qmant_l : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal qexp_l  : integer := 0;

  -- ---- POSITION-SEQUENTIAL iteration state (registers, one t/cycle) -------
  -- t_idx now doubles as the BRAM read-ahead pointer: at t_idx it ISSUES the
  -- read for position t_idx (via the combinational kv_raddr) and CONSUMES the
  -- registered data for position t_idx-1 (see S_VREF/S_SCORE/S_WACC).
  signal t_idx     : integer := 0;                 -- read-ahead position pointer
  signal smax_s    : signed(63 downto 0) := (others => '0'); -- running |score| max
  type sfx_sig_arr is array(0 to MAXPOS-1) of signed(63 downto 0);
  signal sfx_s     : sfx_sig_arr := (others => (others => '0')); -- per-pos raw scores
  type shd_arr is array(0 to HEAD_SIZE-1) of signed(31 downto 0);
  -- re-BFP q/k heads as SIGNED vectors (not integer): the dot multiply reads these
  -- directly, avoiding to_signed(integer) which Vivado sign-drops (same class as the
  -- confirmed V-multiply bug).  qextra/kextra are always >=0 (16-bit mantissa), so
  -- the shift_left scaling is bit-exact with the old integer *2^extra.
  signal qhead_s   : shd_arr := (others => (others => '0'));
  signal khead_s   : shd_arr := (others => (others => '0'));
  signal qe_head_s : integer := 0;                 -- q head block exp
  signal amax_s    : signed(63 downto 0) := (others => '0');  -- running |xb_acc| max (S_PACK)

  -- ---- per-lane V-weighted sums (num_s) in a SYNCHRONOUS BLOCK RAM ------------
  -- WAS: an 8-element signed(63:0) register array ROTATED every cycle
  -- (`num_s(i) <= num_s(i+1)`; `num_s(7) <= num_s(0)+term`).  Vivado extracted that
  -- rotation into 64 SRL32 cells, and the SRL output arc
  -- `num_s_reg[2][*]_srl5 -> num_s_reg[1][*]` was the TIGHTEST hold path in the whole
  -- engine (+0.015 ns real).  SRL chains CANNOT be hold-fixed by the router, which is
  -- why every hold-guardband attempt failed on it and why one lane of xb_acc came out
  -- grossly oversized on silicon (the QCLAMP guard proved it).
  -- NOW: an 8-word x 64-bit simple-dual-port BRAM (rtl/vec_mem.vhd, ram_style="block",
  -- the same structure that removed the swiglu->bfp_pack non-determinism).  Exactly ONE
  -- lane is written per cycle, addresses are small and sequential, and the read is
  -- registered (1-cycle latency) and handled with the read-ahead pattern already used
  -- for the KV cache.  No shift register, no LUTRAM, nothing for SRL extraction.
  constant NSW : integer := clog2(HEAD_SIZE);      -- lane address width (3)
  signal ns_we    : std_logic;
  signal ns_waddr : std_logic_vector(NSW-1 downto 0);
  signal ns_raddr : std_logic_vector(NSW-1 downto 0);
  signal ns_din   : std_logic_vector(63 downto 0);
  signal ns_dout  : std_logic_vector(63 downto 0);
  signal ns_term  : signed(63 downto 0);            -- this cycle's (ei*V)>>sh
  signal ns_first : std_logic := '0';               -- first position -> overwrite

  component vec_mem is
    generic(WORDS : positive; W : positive);
    port(clk : in std_logic; we : in std_logic;
         waddr, raddr : in std_logic_vector(clog2(WORDS)-1 downto 0);
         din  : in  std_logic_vector(W-1 downto 0);
         dout : out std_logic_vector(W-1 downto 0));
  end component;

  -- (ei*V) >> sh, with the same round-half-up bias as the old in-process code.
  function wterm(ei : integer; v : signed; sh : integer) return signed is
    variable t : signed(63 downto 0);
    variable b : signed(63 downto 0);
  begin
    t := resize(to_signed(ei, 32) * v, 64);
    if sh > 0 then
      b := shift_left(to_signed(1, 64), sh - 1);
      t := shift_right(t + b, sh);
    end if;
    return t;
  end function;

  -- Force these indexed arrays to REGISTERS (not distributed LUTRAM).  Under the
  -- 93%+ engine congestion Vivado inferred them as UNINITIALIZED LUTRAM (349
  -- cells), giving non-deterministic HW reads -> wrong tokens.  Registers carry
  -- their init and are deterministic.
  attribute ram_style : string;
  attribute ram_style of xb_acc : signal is "registers";
  attribute ram_style of sfx_s  : signal is "registers";
  -- (num_s is now the u_nsmem BRAM -- see above.)

  -- ---- softmax interface -------------------------------------------------
  signal sm_start      : std_logic := '0';
  signal sm_done       : std_logic;
  signal sm_n          : integer := 0;
  signal sm_score_mant : std_logic_vector(MAXPOS*16-1 downto 0) := (others => '0');
  signal sm_score_exp  : integer := 0;
  signal sm_prob_q     : std_logic_vector(MAXPOS*32-1 downto 0);
  signal sm_e_out      : std_logic_vector(MAXPOS*32-1 downto 0);
  signal sm_sum_out    : std_logic_vector(63 downto 0);
  signal e_l           : std_logic_vector(MAXPOS*32-1 downto 0) := (others => '0');
  signal sum_l         : signed(63 downto 0) := to_signed(1, 64);

  -- Weighted-sum fixed-point headroom (see attention.vhd).
  constant WQ : integer := 16;

  -- Provable bound on |xb_acc|: num_s = sum_t (e_t*V_t)>>sh_t with e_t <= 2^12
  -- and |V| <= 2^15 over <= MAXPOS positions -> |num_s| < 2^32; sum_l >= 2^12;
  -- so |num_s*2^WQ/sum_l| < 2^36.  Clamp at 2^40-1: never reached by correct
  -- data, but it stops ANY single-bit upset from turning one lane into ~2^51
  -- and blowing the block exponent (the sticky S_PACK max makes one bad lane
  -- destroy the whole 64-element output).
  constant QCLAMP : unsigned(63 downto 0) := shift_left(to_unsigned(1, 64), 40) - 1;

  -- ---- NARROWED DIVIDER WIDTHS (2026-07-26) ---------------------------------
  -- PROVEN silicon bug: the 64/64 unsigned divide `nmag / unsigned(sum_l(63..0))`
  -- returned 27,470,576,744,311 for nmag=2,465,074,253,122 / sum_l=6788 -- a
  -- quotient 11x LARGER THAN ITS OWN DIVIDEND, i.e. arithmetically impossible for
  -- any divisor >= 1.  Operands were measured bit-exact vs sim, GHDL is 24/24 and
  -- the ISOLATED divider passed 98/98 netlist-funcsim vectors, and setup is met
  -- with +242 ns slack -- only the in-engine silicon is wrong.  The 64/64 divide
  -- synthesises to a ~627-logic-level / 564-CARRY8 combinational monster; the
  -- widths are wildly oversized for the real operand ranges, so narrow it.
  --
  -- DIVIDEND (NW): num96 = num_s*2^WQ +/- sum_l/2.
  --   |num_s| = |sum_t (e_t*V_t)>>sh_t| <= (sum_t e_t) * max|V/2^sh|
  --           <= (MAXPOS * 2^Q) * 2^15 = (24*2^12)*2^15 < 2^17 * 2^15 = 2^32.
  --   => |num96| < 2^32 * 2^16 + 2^16 = 2^48 + 2^16 < 2^49.
  --   Measured max on both sim and HW: max|num_s| = 0x1367B618 (2^28.3), giving
  --   nmag = 2.465e12 (2^41.2).  NW = 52 covers the PROVABLE 2^49 bound with 8x
  --   margin (and ~2000x over the measured value) while still being ~1/3 the
  --   area of the 64-bit dividend.
  --
  -- DIVISOR (DW): sum_l is the softmax denominator, >= 1 (softmax always has the
  --   max element contributing 2^Q) and <= MAXPOS * 2^Q = 24*4096 = 98304 < 2^17.
  --   Measured range across all 8 heads: 4741 .. 16340.  DW = 24 covers 2^17 with
  --   128x margin.
  --
  -- Cost: the restoring-divide array is ~NW*DW cells, so 52x24 = 1248 vs the old
  -- 64x64 = 4096 -- a 3.3x reduction in the divider's CARRY/logic-level cone.
  -- Bit-exactness: both slices are LOSSLESS inside the bounds above, so the
  -- narrowed quotient is identical to the 64/64 one (GHDL 24/24 proves it, and
  -- the synthesis-off assertions below fail loudly if a bound is ever exceeded).
  constant NW : integer := 52;   -- dividend width (bound 2^49)
  constant DW : integer := 24;   -- divisor  width (bound 2^17)

  -- ---- MULTI-CYCLE RESTORING DIVIDER (2026-07-26) ---------------------------
  -- The VHDL `/` operator is PROVEN UNRELIABLE at this site on silicon: with the
  -- dividend formation measured bit-perfect on two independent lanes, the
  -- quotient still came back wrong (lane 1: 363,118,079 vs 363,151,775; lane 63:
  -- 536,802,267 vs 856,520,062 = 37% too small), at BOTH 64/64 and the narrowed
  -- 52/24 widths.  It is replaced by rtl/divider_rs.vhd -- an explicit
  -- shift-subtract restoring divider, NW iterations of one (DW+1)-bit
  -- compare/subtract, written in pure MSB-shift form with NO variable-signal
  -- indices (the failure mode of the FIRST iterative attempt in this project).
  --
  -- SEQUENCING:  S_WDIV      -- form + REGISTER {nmag_n, sum_n, sign}, raise dv_go
  --              S_DIV_ITER  -- divider runs on the registered operands only
  --              S_DIV_FIN   -- qmag = quotient; probes (PRE-clamp), QCLAMP,
  --                             signed write-back into xb_acc, advance lane/head
  -- Registering the operands also removes any operand/divider sampling race.
  -- Cost: ~56 cycles per lane x 64 lanes = ~3.6k cycles per attention call
  -- (~+6% per token at 3 MHz) -- irrelevant, correctness is the point.
  component divider_rs is
    generic(NW : positive; DW : positive);
    port(clk   : in  std_logic;
         rst   : in  std_logic;
         start : in  std_logic;
         num   : in  std_logic_vector(NW-1 downto 0);
         den   : in  std_logic_vector(DW-1 downto 0);
         busy  : out std_logic;
         done  : out std_logic;
         quo   : out std_logic_vector(NW-1 downto 0));
  end component;

  signal dv_go    : std_logic := '0';                       -- 1-cycle start pulse
  signal dv_num_r : std_logic_vector(NW-1 downto 0) := (others => '0'); -- REGISTERED dividend
  signal dv_den_r : std_logic_vector(DW-1 downto 0) := (others => '0'); -- REGISTERED divisor
  signal dv_neg   : std_logic := '0';                       -- REGISTERED result sign
  signal dv_done  : std_logic;
  signal dv_busy  : std_logic;
  signal dv_quo   : std_logic_vector(NW-1 downto 0);
  -- operand snapshots taken at LOAD time, so the probes below report exactly what
  -- the divider consumed even though ns_dout advances during the iteration.
  signal dv_nmag_r : unsigned(63 downto 0) := (others => '0');            -- |num96| (probe)
  signal dv_nsd_r  : std_logic_vector(63 downto 0) := (others => '0');    -- raw ns_dout (probe)

  -- DEBUG tap registers (last-head values); drive dbg_sc/dbg_sum/dbg_num ports.
  signal dsc_r  : integer := 0;
  signal dsum_r : integer := 0;
  signal dnum_r : integer := 0;

  -- ---- per-head / per-lane PROBE registers (see the p_* ports) --------------
  -- pr_sums is ONE flat slv (not an array) so there is nothing for Vivado to
  -- infer as distributed LUTRAM: the per-head write is a 32-bit 8-way demux and
  -- all 8 words are read in parallel by the p_sums port.
  signal pr_sums    : std_logic_vector(NHEADS*32-1 downto 0) := (others => '0');
  signal pr_amaxidx : integer range 0 to DIM-1 := 0;  -- argmax lane of amax_s
  signal pr_nmax    : unsigned(63 downto 0) := (others => '0'); -- max |num_s|
  signal pr_nmaxidx : integer range 0 to DIM-1 := 0;  -- lane of that max

  -- ---- FAILING-DIVISION capture registers (see the p_cd_*/p_l1_* ports) -----
  -- All are plain unsigned/std_logic_vector (never routed through `integer`) and
  -- are written ONLY from S_WDIV, so they hold their value through S_PACK /
  -- S_PACK_EMIT / done / S_IDLE -- i.e. they are stable when engine_shared
  -- latches them on att_done, and stay stable for the AXI read after the run.
  signal pr_cd_qmag : unsigned(63 downto 0) := (others => '0');  -- PRE-clamp quotient
  signal pr_cd_nmag : unsigned(63 downto 0) := (others => '0');  -- dividend magnitude
  signal pr_cd_nsd  : std_logic_vector(63 downto 0) := (others => '0'); -- raw ns_dout
  signal pr_cd_sum  : std_logic_vector(31 downto 0) := (others => '0'); -- divisor
  signal pr_cd_hd   : unsigned(7 downto 0) := (others => '0');   -- head
  signal pr_cd_t    : unsigned(7 downto 0) := (others => '0');   -- in-head lane
  signal pr_cd_lane : unsigned(7 downto 0) := (others => '0');   -- hd*HEAD_SIZE+t_idx
  signal pr_cd_seen : std_logic := '0';                          -- first_clamp_seen
  signal pr_cd_cnt  : unsigned(6 downto 0) := (others => '0');   -- #clamped divisions
  -- unconditional capture of the known-suspect lane (hd=0, t_idx=1)
  signal pr_l1_qmag : unsigned(63 downto 0) := (others => '0');
  signal pr_l1_nsd  : std_logic_vector(63 downto 0) := (others => '0');
  signal pr_l1_sum  : std_logic_vector(31 downto 0) := (others => '0');
  -- NEW: the DIVIDEND actually consumed at hd=0/t_idx=1 (unconditional).  Was the
  -- one operand the old probe set never captured outside a clamp event.
  signal pr_l1_nmag : unsigned(63 downto 0) := (others => '0');
  -- NEW: RUNNING-MAX pre-clamp quotient over all 64 divides of this call, with
  -- the winning division's operands and lane.  No lane is hardcoded: the worst
  -- lane differs between sim (26) and silicon (36) and may move again.
  -- pr_qx_valid makes the FIRST division always latch (so a max of 0 is still a
  -- real, attributable capture rather than an unwritten register).
  signal pr_qx_qmag  : unsigned(63 downto 0) := (others => '0');
  signal pr_qx_nmag  : unsigned(63 downto 0) := (others => '0');
  signal pr_qx_nsd   : std_logic_vector(63 downto 0) := (others => '0');
  signal pr_qx_sum   : std_logic_vector(31 downto 0) := (others => '0');
  signal pr_qx_hd    : unsigned(7 downto 0) := (others => '0');
  signal pr_qx_t     : unsigned(7 downto 0) := (others => '0');
  signal pr_qx_lane  : unsigned(7 downto 0) := (others => '0');
  signal pr_qx_valid : std_logic := '0';

  -- FSM: the position loops of S_SETUP/S_HEAD/S_WSUM are multi-cycle sub-states
  -- iterating one position per clock (S_VREF, S_SCORE, S_SPACK, S_WACC), each
  -- with a 1-cycle BRAM read-ahead bubble (consume position t_idx-1).
  type state_t is (S_IDLE, S_SETUP, S_VREF, S_HEAD, S_SCORE, S_DOT, S_SCORE_B, S_SPACK,
                   S_SMWAIT, S_WSUM, S_WACC, S_WACC_L, S_WDIV, S_DIV_ITER, S_DIV_FIN,
                   S_PACK, S_PACK_EMIT);
  signal state : state_t := S_IDLE;
  signal dj    : integer range 0 to HEAD_SIZE := 0;   -- pipelined dot lane counter
  signal wj    : integer range 0 to HEAD_SIZE := 0;   -- pipelined weighted-sum lane counter
  signal v_word_r : std_logic_vector(KVW-1 downto 0) := (others=>'0');  -- latched V word
  signal ei_r  : integer := 0;   -- latched exp weight for the current position
  signal sh_r  : integer := 0;   -- latched V-exp shift for the current position
  signal kvh_r : integer := 0;   -- latched kv head
  -- Weighted-sum sequential-consumption shift registers (fixed-index reads only;
  -- replace the dynamic-index num_s RMW / v_word_r slice / e_l slice that
  -- mis-synthesised -> num_s=+806M on HW+funcsim vs sim -83.5M).
  signal vhead_r : std_logic_vector(HEAD_SIZE*16-1 downto 0) := (others=>'0'); -- head V sub-word, shifted 16/cycle
  signal e_sh    : std_logic_vector(MAXPOS*32-1 downto 0)    := (others=>'0'); -- e_l shifted 32/position

  component softmax is
    generic(NMAX : positive; Q : integer := 12);
    port(
      clk        : in  std_logic;
      rst        : in  std_logic;
      start      : in  std_logic;
      n          : in  integer;
      score_mant : in  std_logic_vector(NMAX*16-1 downto 0);
      score_exp  : in  integer;
      done       : out std_logic;
      prob_q     : out std_logic_vector(NMAX*32-1 downto 0);
      e_out      : out std_logic_vector(NMAX*32-1 downto 0);
      sum_out    : out std_logic_vector(63 downto 0)
    );
  end component;

  -- Highest set-bit index of a nonnegative signed value (0 for 0).
  function msb_pos64(v : signed) return integer is
    variable p : integer := 0;
  begin
    for i in 0 to v'length-2 loop
      if v(i) = '1' then p := i; end if;
    end loop;
    return p;
  end function;

  -- BFP shift g for a nonnegative max-abs (mirrors fx_bfp_from_float).
  function bfp_g(maxabs : signed) return integer is
    variable p : integer;
    variable g : integer;
    variable r : signed(63 downto 0);
    variable b : signed(63 downto 0);
    variable m : signed(63 downto 0);
  begin
    if maxabs = 0 then return 0; end if;
    m := resize(maxabs, 64);
    p := msb_pos64(m);
    g := 14 - p;
    if g >= 0 then
      r := shift_left(m, g);
    else
      b := shift_left(to_signed(1, 64), (-g) - 1);
      r := shift_right(m + b, -g);
    end if;
    if r > to_signed(32767, 64) then g := g - 1; end if;
    return g;
  end function;

  -- round(v * 2^g) saturated to int16.
  function pack1(v : signed; g : integer) return integer is
    variable r : signed(63 downto 0);
    variable b : signed(63 downto 0);
    variable m : signed(63 downto 0);
  begin
    m := resize(v, 64);
    if g >= 0 then
      r := shift_left(m, g);
    else
      b := shift_left(to_signed(1, 64), (-g) - 1);
      r := shift_right(m + b, -g);
    end if;
    if    r >  to_signed(32767, 64)  then return 32767;
    elsif r < to_signed(-32768, 64)  then return -32768;
    else                                  return to_integer(r);
    end if;
  end function;

begin
  -- ---- KV cache BRAMs (one KVDIM-wide word per (layer,pos)) --------------
  -- Read address is COMBINATIONAL from the read-ahead pointer t_idx (clamped so
  -- the trailing bubble read at t_idx=cp+1 stays in range); write address/enable
  -- are combinational off the ports so the S_IDLE write commits while the
  -- current-position K/V/exp inputs are still valid (start='1').
  fetch_pos <= t_idx when t_idx <= MAXPOS-1 else MAXPOS-1;
  dbg_sc  <= dsc_r;
  dbg_sum <= dsum_r;
  dbg_num <= dnum_r;
  -- Probe outputs.  amax_s is only cleared in S_WDIV (hd=NHEADS-1, last lane)
  -- just before S_PACK, so its FINAL value is stable from S_PACK_EMIT through
  -- `done` and all of S_IDLE -- i.e. valid at the moment engine_shared latches
  -- these on att_done.  Same for pr_* (cleared at the S_IDLE start handshake).
  p_sums     <= pr_sums;
  p_amax     <= std_logic_vector(amax_s);
  p_amax_idx <= std_logic_vector(to_unsigned(pr_amaxidx, 8));
  p_nmax     <= std_logic_vector(pr_nmax);
  p_nmax_idx <= std_logic_vector(to_unsigned(pr_nmaxidx, 8));
  -- failing-division capture (written only in S_WDIV -> stable at done/S_IDLE)
  p_cd_qmag  <= std_logic_vector(pr_cd_qmag);
  p_cd_nmag  <= std_logic_vector(pr_cd_nmag);
  p_cd_nsd   <= pr_cd_nsd;
  p_cd_sum   <= pr_cd_sum;
  p_cd_meta  <= pr_cd_seen & std_logic_vector(pr_cd_cnt) &
                std_logic_vector(pr_cd_hd) & std_logic_vector(pr_cd_t) &
                std_logic_vector(pr_cd_lane);
  p_l1_qmag  <= std_logic_vector(pr_l1_qmag);
  p_l1_nsd   <= pr_l1_nsd;
  p_l1_sum   <= pr_l1_sum;
  -- nmag at hd0/t1 + the running-max-quotient block (written only in S_WDIV, so
  -- stable through S_PACK/S_PACK_EMIT/done/S_IDLE, i.e. valid when engine_shared
  -- latches them on att_done and for the AXI read after the run).
  p_l1_nmag  <= std_logic_vector(pr_l1_nmag);
  p_qx_qmag  <= std_logic_vector(pr_qx_qmag);
  p_qx_nmag  <= std_logic_vector(pr_qx_nmag);
  p_qx_nsd   <= pr_qx_nsd;
  p_qx_sum   <= pr_qx_sum;
  -- clamp_cnt rides along so the "no clamps" evidence stays readable.
  p_qx_meta  <= pr_qx_valid & std_logic_vector(pr_cd_cnt) &
                std_logic_vector(pr_qx_hd) & std_logic_vector(pr_qx_t) &
                std_logic_vector(pr_qx_lane);
  kv_raddr  <= std_logic_vector(to_unsigned(lyr*MAXPOS + fetch_pos, KVADDR_W));
  kv_waddr  <= std_logic_vector(to_unsigned(layer*MAXPOS + cur_pos, KVADDR_W));
  kv_we     <= '1' when (state = S_IDLE and start = '1') else '0';
  kc_e_di   <= std_logic_vector(to_signed(k_new_exp, 32));
  vc_e_di   <= std_logic_vector(to_signed(v_new_exp, 32));

  u_kc_v : kv_mem generic map(WORDS => KVWORDS, W => KVW)
    port map(clk => clk, we => kv_we, waddr => kv_waddr, raddr => kv_raddr,
             din => k_new_mant, dout => kc_v_do);
  u_vc_v : kv_mem generic map(WORDS => KVWORDS, W => KVW)
    port map(clk => clk, we => kv_we, waddr => kv_waddr, raddr => kv_raddr,
             din => v_new_mant, dout => vc_v_do);
  u_kc_e : kv_mem generic map(WORDS => KVWORDS, W => 32)
    port map(clk => clk, we => kv_we, waddr => kv_waddr, raddr => kv_raddr,
             din => kc_e_di, dout => kc_e_do);
  u_vc_e : kv_mem generic map(WORDS => KVWORDS, W => 32)
    port map(clk => clk, we => kv_we, waddr => kv_waddr, raddr => kv_raddr,
             din => vc_e_di, dout => vc_e_do);

  -- ---- per-lane weighted-sum accumulators (num_s) in BRAM -------------------
  -- Read port: combinational address, registered data (1-cycle latency), exactly
  -- like the KV cache.
  --   S_WACC_L runs wj = 0..HEAD_SIZE: wj=0 is the read-ahead PRIME cycle and
  --   wj = 1..HEAD_SIZE processes lane wj-1 (whose accumulator is on ns_dout,
  --   requested at the previous cycle by ns_raddr = wj-1).  At wj=HEAD_SIZE the
  --   address wraps to 0, which also primes lane 0 for the next position AND for
  --   the first S_WDIV cycle.
  --   S_WDIV consumes lane t_idx from ns_dout and requests lane t_idx+1.
  -- Write port: also combinational, so the accumulate commits on the SAME edge
  -- that ends the lane's cycle.  ns_first selects overwrite-with-term for the very
  -- first position, so the RAM never has to be cleared and an uninitialised word is
  -- never read (stronger than the old S_WSUM zeroing).
  ns_raddr <= std_logic_vector(to_unsigned(wj mod HEAD_SIZE, NSW))
                when state = S_WACC_L else
              std_logic_vector(to_unsigned((t_idx + 1) mod HEAD_SIZE, NSW))
                when (state = S_WDIV or state = S_DIV_ITER or state = S_DIV_FIN) else
              (others => '0');
  ns_waddr <= std_logic_vector(to_unsigned((wj - 1) mod HEAD_SIZE, NSW));
  ns_we    <= '1' when (state = S_WACC_L and wj >= 1) else '0';
  ns_term  <= wterm(ei_r, signed(vhead_r(15 downto 0)), sh_r);
  ns_din   <= std_logic_vector(ns_term) when ns_first = '1'
              else std_logic_vector(signed(ns_dout) + ns_term);

  u_nsmem : vec_mem generic map(WORDS => HEAD_SIZE, W => 64)
    port map(clk => clk, we => ns_we, waddr => ns_waddr, raddr => ns_raddr,
             din => ns_din, dout => ns_dout);

  -- ---- the weighted-sum divide (replaces the unreliable '/' macro) ----------
  -- Consumes ONLY the registered operands dv_num_r / dv_den_r, loaded in S_WDIV.
  u_div : divider_rs generic map(NW => NW, DW => DW)
    port map(clk => clk, rst => rst, start => dv_go,
             num => dv_num_r, den => dv_den_r,
             busy => dv_busy, done => dv_done, quo => dv_quo);

  -- Shared softmax datapath (BFP scores in, Q12 probs out).
  u_softmax: softmax
    generic map(NMAX => MAXPOS, Q => Q)
    port map(
      clk        => clk,
      rst        => rst,
      start      => sm_start,
      n          => sm_n,
      score_mant => sm_score_mant,
      score_exp  => sm_score_exp,
      done       => sm_done,
      prob_q     => sm_prob_q,
      e_out      => sm_e_out,
      sum_out    => sm_sum_out
    );

  -- Main FSM (compute identical to attention.vhd; cache in BRAM bank `lyr`).
  process(clk)
    -- q-head re-BFP
    variable qh       : integer;
    variable qmax     : integer;
    variable qextra   : integer;
    variable qe_head  : integer;
    variable qhead    : integer_vector(0 to HEAD_SIZE-1);
    -- k-head re-BFP
    variable khead    : integer_vector(0 to HEAD_SIZE-1);
    variable kmax     : integer;
    variable kextra   : integer;
    variable ke_head  : integer;
    variable av       : integer;
    variable kv_h     : integer;
    variable p        : integer;   -- position being CONSUMED this cycle (t_idx-1)
    -- dot / score
    variable dot      : signed(63 downto 0);
    variable pr       : signed(63 downto 0);
    variable prod     : signed(95 downto 0);
    variable bias96   : signed(95 downto 0);
    variable tsh      : integer;
    variable sc64     : signed(63 downto 0);   -- this position's raw score
    variable g        : integer;
    -- weighted sum
    variable term     : signed(63 downto 0);
    variable bias64   : signed(63 downto 0);
    variable sh       : integer;
    variable ei       : integer;
    variable vval     : integer;
    variable num96    : signed(95 downto 0);
    variable qmag     : unsigned(63 downto 0);   -- floor(|num96|/sum_l) from u_div
    variable nabs96   : signed(95 downto 0);     -- |num96| as a SIGNED vector
    variable nmag     : unsigned(63 downto 0);   -- |num96| low 64 bits, unsigned (probe only)
    variable nneg     : std_logic;               -- explicit sign of num96
    -- narrowed divider operands (see NW/DW above); the quotient comes back from
    -- the multi-cycle u_div unit, NOT from the '/' operator.
    variable nmag_n   : unsigned(NW-1 downto 0); -- dividend, low NW bits of |num96|
    variable sum_n    : unsigned(DW-1 downto 0); -- divisor,  low DW bits of sum_l
    variable dbg_acc  : integer;                  -- debug checksum accumulator
    variable amax     : signed(63 downto 0);
    variable gx       : integer;
    variable nsabs    : signed(63 downto 0);      -- |num_s| for the p_nmax probe
  begin
    if rising_edge(clk) then
      done     <= '0';
      sm_start <= '0';
      -- dv_go defaults LOW every cycle (S_WDIV overrides it below), so the
      -- divider load is always a clean 1-cycle pulse and can never be left
      -- asserted across a reset.
      dv_go    <= '0';
      if rst = '1' then
        state    <= S_IDLE;
        xb_mant  <= (others => '0');
        xb_exp   <= 0;
        t_idx    <= 0;
        -- NOTE: the KV BRAM banks are NOT cleared (BRAM can't mass-reset).
        -- Write-before-read holds: every position read (0..cur_pos) is written
        -- earlier this run, so stale contents are never observed.
      else
        case state is
          -- ------------------------------------------------------------
          when S_IDLE =>
            if start = '1' then
              cp      <= cur_pos;
              lyr     <= layer;
              qmant_l <= q_mant;
              qexp_l  <= q_exp;
              -- current K/V + block exps are written into bank[layer] at slot
              -- cur_pos by the combinational kv_we/kv_waddr, committing on this
              -- edge while the inputs are still valid.
              -- PROBE: re-arm the per-call max trackers for this attention call.
              if PROBES then
                pr_nmax    <= (others => '0');
                pr_nmaxidx <= 0;
                -- re-arm the failing-division event capture for THIS call
                pr_cd_seen <= '0';
                pr_cd_cnt  <= (others => '0');
                -- re-arm the running-max-quotient capture for THIS call
                pr_qx_valid <= '0';
                pr_qx_qmag  <= (others => '0');
              end if;
              state <= S_SETUP;
            end if;

          -- ------------------------------------------------------------
          -- Prime the V-exp read-ahead scan for vref = min vc_e over 0..cp.
          when S_SETUP =>
            t_idx <= 0;
            state <= S_VREF;

          -- One position per cycle (read-ahead): at t_idx>=1 the data for
          -- position p=t_idx-1 is on vc_e_do; min-fold it into vref_s.
          when S_VREF =>
            if t_idx >= 1 then
              p := t_idx - 1;
              if p = 0 then
                vref_s <= to_integer(signed(vc_e_do));
              elsif to_integer(signed(vc_e_do)) < vref_s then
                vref_s <= to_integer(signed(vc_e_do));
              end if;
            end if;
            if t_idx = cp + 1 then
              hd    <= 0;
              state <= S_HEAD;
            else
              t_idx <= t_idx + 1;
            end if;

          -- ------------------------------------------------------------
          -- Per-head setup: q-head re-BFP (once, HEAD_SIZE-wide combinational),
          -- then prime the position-sequential score pass (read-ahead from 0).
          when S_HEAD =>
            qmax := 0;
            for j in 0 to HEAD_SIZE-1 loop
              qh := to_integer(signed(
                      qmant_l((hd*HEAD_SIZE+j+1)*16-1 downto (hd*HEAD_SIZE+j)*16)));
              qhead(j) := qh;
              av := qh; if av < 0 then av := -av; end if;
              if av > qmax then qmax := av; end if;
            end loop;
            if qmax = 0 then qextra := 0; else qextra := 14 - msb_pos(qmax); end if;
            qe_head := qexp_l + qextra;
            -- scale the SIGNED mantissa by 2^qextra (qextra>=0) -> signed vector.
            for j in 0 to HEAD_SIZE-1 loop
              qhead_s(j) <= shift_left(
                resize(signed(qmant_l((hd*HEAD_SIZE+j+1)*16-1 downto (hd*HEAD_SIZE+j)*16)), 32),
                qextra);
            end loop;
            qe_head_s     <= qe_head;
            smax_s        <= (others => '0');
            sm_score_mant <= (others => '0');
            t_idx         <= 0;
            state         <= S_SCORE;

          -- (b) read-ahead over cached positions: at t_idx>=1 the whole K word
          -- for position p=t_idx-1 is on kc_v_do (block exp on kc_e_do); q.k dot
          -- -> raw score sfx_s(p), tracking the running |score| max for the BFP
          -- pack.  The HEAD_SIZE-wide inner dot stays combinational (small).
          when S_SCORE =>
            kv_h := hd / KV_MUL;
            if t_idx >= 1 then
              p := t_idx - 1;
              -- DEBUG: cached K read (KV BRAM out) for position 0, head 0 -> dbg_sc.
              if hd = 0 and t_idx = 1 then dsc_r <= to_integer(signed(kc_v_do(15 downto 0))); end if;
              -- k-head re-BFP for this position (slice the KVDIM-wide word)
              kmax := 0;
              for j in 0 to HEAD_SIZE-1 loop
                khead(j) := to_integer(signed(
                  kc_v_do(((kv_h*HEAD_SIZE+j)+1)*16-1 downto (kv_h*HEAD_SIZE+j)*16)));
                av := khead(j); if av < 0 then av := -av; end if;
                if av > kmax then kmax := av; end if;
              end loop;
              if kmax = 0 then kextra := 0; else kextra := 14 - msb_pos(kmax); end if;
              ke_head := to_integer(signed(kc_e_do)) + kextra;
              -- (dsc_r/dsum_r now carry att-output chksum / sum_l; see engine_shared + S_SMWAIT.)
              -- scale the SIGNED k mantissa by 2^kextra (kextra>=0) -> signed vector.
              for j in 0 to HEAD_SIZE-1 loop
                khead_s(j) <= shift_left(
                  resize(signed(kc_v_do(((kv_h*HEAD_SIZE+j)+1)*16-1 downto (kv_h*HEAD_SIZE+j)*16)), 32),
                  kextra);
              end loop;
              -- integer dot Q.K (int64) using the persisted re-BFP'd q head.
              -- Registered here; the dot*INV_SQRT8 scaling is done in S_SCORE_B so
              -- the two multiply LEVELS (q*k then dot*scale) are NOT a cascaded-DSP
              -- combinational cone (the timing tool under-counts those -> wrong/
              -- non-deterministic on HW; same fix as rmsnorm's rsqrt/S_RAW).
              -- PIPELINED dot: one q*k multiply per cycle in S_DOT (the 8 combinational
              -- multiplies summed here were a cascaded-DSP cone -> non-deterministic
              -- score/attention output on HW).  khead/qhead_s/dot persist to S_DOT.
              dot := (others => '0');
              dj  <= 0;
              state <= S_DOT;
            else
              if t_idx = cp + 1 then t_idx <= 0; state <= S_SPACK;
              else t_idx <= t_idx + 1; end if;
            end if;

          -- One q*k multiply-accumulate per cycle (dj = 0..HEAD_SIZE-1).
          when S_DOT =>
            dot := dot + resize(qhead_s(dj) * khead_s(dj), 64);
            if dj = HEAD_SIZE-1 then
              state <= S_SCORE_B;           -- ke_head, dot, p persist
            else
              dj <= dj + 1;
            end if;

          -- Scale + BFP-pack the score for position p (2nd multiply level).
          when S_SCORE_B =>
            prod := dot * to_signed(INV_SQRT8_Q15, 32);
            tsh  := 15 + ke_head;
            if tsh > 0 then
              bias96 := shift_left(to_signed(1, 96), tsh - 1);
              sc64   := resize(shift_right(prod + bias96, tsh), 64);
            elsif tsh = 0 then
              sc64   := resize(prod, 64);
            else
              sc64   := resize(shift_left(prod, -tsh), 64);
            end if;
            sfx_s(p) <= sc64;
            if sc64 >= 0 then
              if sc64 > smax_s then smax_s <= sc64; end if;
            else
              if -sc64 > smax_s then smax_s <= -sc64; end if;
            end if;
            if t_idx = cp + 1 then
              t_idx <= 0;
              state <= S_SPACK;
            else
              t_idx <= t_idx + 1;
              state <= S_SCORE;
            end if;

          -- (c) one position per cycle: BFP-pack sfx_s(t) with the now-final
          -- shift g -> score_mant; on the last, kick softmax (exp = qe_head+g).
          when S_SPACK =>
            g := bfp_g(smax_s);
            -- DEBUG: raw score for pos 0 (head0), the softmax input -> dnum_r.
            sm_score_mant((t_idx+1)*16-1 downto t_idx*16) <=
              std_logic_vector(to_signed(pack1(sfx_s(t_idx), g), 16));
            if t_idx = cp then
              sm_score_exp <= qe_head_s + g;
              sm_n         <= cp + 1;
              sm_start     <= '1';        -- kick softmax (score signals settled)
              state        <= S_SMWAIT;
            else
              t_idx <= t_idx + 1;
            end if;

          -- ------------------------------------------------------------
          when S_SMWAIT =>
            if sm_done = '1' then
              e_l    <= sm_e_out;
              sum_l  <= signed(sm_sum_out);
              if hd = 0 then dsum_r <= to_integer(signed(sm_sum_out(31 downto 0))); end if; -- softmax sum
              -- PROBE: snapshot THIS head's softmax denominator (all 8 heads).
              -- Correct values are ~1e3..1e5 so the low 32 bits are exact; a value
              -- of ~0..1 here is the tiny-denominator failure mode.
              if PROBES then
                pr_sums((hd+1)*32-1 downto hd*32) <= sm_sum_out(31 downto 0);
              end if;
              state  <= S_WSUM;
            end if;

          -- ------------------------------------------------------------
          -- V-weighted sum: prime the read-ahead scan.  The lane accumulators are
          -- no longer cleared here -- the first position OVERWRITES them (ns_first),
          -- so no BRAM clear pass and no read of an uninitialised word.
          when S_WSUM =>
            e_sh  <= e_l;          -- prime sequential per-position exp-weight consumption
            t_idx <= 0;
            state <= S_WACC;

          -- Read-ahead: at t_idx>=1 the whole V word for position p=t_idx-1 is
          -- on vc_v_do (block exp on vc_e_do); accumulate prob(p)*V(p) into all
          -- HEAD_SIZE lanes (the HEAD_SIZE-wide inner loop stays combinational).
          when S_WACC =>
            kv_h := hd / KV_MUL;
            if t_idx >= 1 then
              -- Latch this position's ei / V head-word / shift, then accumulate the
              -- HEAD_SIZE lanes ONE multiply per cycle in S_WACC_L.  All reads here use
              -- FIXED indices (e_sh low slice; vhead_r assembled with j UNROLLED to
              -- constant slices, kv_h a small mux -> the proven-correct S_SCORE k-head
              -- pattern).  t_idx frozen so vc_v_do stays valid.
              p      := t_idx - 1;
              ei_r   <= to_integer(signed(e_sh(31 downto 0)));   -- was e_l(dynamic p slice)
              e_sh   <= x"00000000" & e_sh(MAXPOS*32-1 downto 32);
              sh_r   <= to_integer(signed(vc_e_do)) - vref_s;
              for j in 0 to HEAD_SIZE-1 loop
                vhead_r((j+1)*16-1 downto j*16) <=
                  vc_v_do(((kv_h*HEAD_SIZE+j)+1)*16-1 downto (kv_h*HEAD_SIZE+j)*16);
              end loop;
              wj     <= 0;
              -- t_idx=1 is the FIRST cached position (p=0): its lane products are
              -- written straight into the accumulator RAM instead of being added to
              -- it, which replaces the old S_WSUM clear.
              if t_idx = 1 then ns_first <= '1'; else ns_first <= '0'; end if;
              state  <= S_WACC_L;
            else
              t_idx <= t_idx + 1;   -- prime read-ahead (t_idx=0 -> 1)
            end if;

          -- One weighted-sum lane per cycle: num_s[wj-1] += (ei*V[wj-1]) >> sh.
          -- wj = 0 is the BRAM read-ahead PRIME cycle (nothing is written); lanes
          -- 0..HEAD_SIZE-1 are processed at wj = 1..HEAD_SIZE.  The multiply/shift
          -- (ns_term) and the accumulate + write-back (ns_din/ns_we/ns_waddr) are
          -- CONCURRENT statements above, so this branch only sequences.
          -- The V mantissa is multiplied as a SIGNED VECTOR directly (in wterm).
          -- Routing it through an integer (to_signed(to_integer(signed(...)),32))
          -- mis-synthesised in Vivado: a negative V (-45) was carried as the
          -- unsigned +131027 (2^17-45), dropping the sign.  GHDL tolerated it;
          -- silicon did not.  This was THE attention bug -- do not reintroduce it.
          when S_WACC_L =>
            if wj >= 1 then
              -- lane wj-1 consumed this cycle; shift the next lane's V down.
              vhead_r <= x"0000" & vhead_r(HEAD_SIZE*16-1 downto 16);
            end if;
            if wj = HEAD_SIZE then
              if t_idx = cp + 1 then
                t_idx <= 0;               -- prime the per-lane S_WDIV counter
                state <= S_WDIV;
              else
                t_idx <= t_idx + 1;
                state <= S_WACC;
              end if;
            else
              wj <= wj + 1;
            end if;

          -- Per-head finalise, one LANE at a time (t_idx = lane 0..HEAD_SIZE-1):
          -- acc[j] = round(num*2^WQ / sum), computed as a MULTI-CYCLE RESTORING
          -- DIVIDE (u_div, rtl/divider_rs.vhd) because the VHDL '/' operator is
          -- proven to return wrong quotients at this site on silicon even with
          -- bit-perfect operands (64/64 gave quotients larger than their own
          -- dividend; 52/24 gave -0.009%/-37% errors on the two probed lanes).
          --   S_WDIV     : form the biased dividend, REGISTER {|num|, sum, sign}
          --   S_DIV_ITER : NW restoring steps inside u_div (registers only)
          --   S_DIV_FIN  : probes (pre-clamp) -> QCLAMP -> signed xb_acc write
          -- The result is bit-exact floor(a/b), so the C-oracle rounding and the
          -- golden token stream are unchanged (GHDL tb_engine_shared 24/24).
          when S_WDIV =>
            -- DEBUG: num_s(0) (head0 lane0) = the divide NUMERATOR -> dnum_r; with
            -- dsum_r=sum_l (denominator) + 0xF0=att-output chksum, this splits whether
            -- the residual non-determinism is the weighted sum or the divide/pack.
            if hd = 0 then dnum_r <= to_integer(resize(signed(ns_dout), 32)); end if;
            -- PROBE: running max |num_s| over ALL 64 lanes (every head), with the
            -- lane index -- distinguishes a huge NUMERATOR from a tiny denominator.
            -- ns_dout is lane t_idx of head hd this cycle (same value the divide
            -- consumes below), so the index is exactly hd*HEAD_SIZE + t_idx.
            if PROBES then
              nsabs := signed(ns_dout);
              if nsabs < 0 then nsabs := -nsabs; end if;
              if unsigned(nsabs) > pr_nmax then
                pr_nmax    <= unsigned(nsabs);
                pr_nmaxidx <= hd*HEAD_SIZE + t_idx;
              end if;
            end if;
            -- lane t_idx, read-ahead from the accumulator BRAM (ns_raddr = t_idx+1)
            num96 := shift_left(resize(signed(ns_dout), 96), WQ);
            nneg := num96(95);                                -- explicit sign BIT
            if nneg = '1' then num96 := num96 - resize(shift_right(sum_l, 1), 96);
            else               num96 := num96 + resize(shift_right(sum_l, 1), 96);
            end if;
            -- NARROWED divide, NW=52 / DW=24 (was 64/64, which computed GARBAGE on
            -- silicon from bit-correct operands -- see the NW/DW block above).
            -- Bit-exact with the 96-bit divide but a fraction of the CARRY ->
            -- cuts the u_att routing congestion the wide divide caused.
            -- ONE unconditional divide on an explicitly-formed magnitude: the
            -- dividend is never a signed value reinterpreted as unsigned, and
            -- there is no branch wrapped around the divider macro.  A wrong
            -- branch on a negative numerator yields (2^64-|num|)/sum ~ 2^51,
            -- which is exactly the block exponent seen on silicon (xb_exp=-6/-7
            -- vs the correct +15); the sticky S_PACK max then latches that one
            -- bad lane and zeros all 64 output mantissas.  Removing the branch
            -- removes that failure mode; QCLAMP bounds any residual upset.
            nneg := num96(95);
            if nneg = '1' then nabs96 := -num96; else nabs96 := num96; end if;
            nmag := unsigned(nabs96(63 downto 0));   -- kept for the p_cd_nmag probe
            -- ---- NARROWED DIVIDE (NW x DW, see the NW/DW constants) ----------
            -- Plain SLICES of the already-formed magnitudes (never a resize of a
            -- signed value, never a value routed through `integer`).  Lossless
            -- inside the proven ranges, so bit-exact with the old 64/64 divide.
            -- synthesis translate_off
            assert nabs96 >= 0
              report "attention_ml: |num96| went negative" severity failure;
            assert nabs96 < shift_left(to_signed(1, 96), NW)
              report "attention_ml: DIVIDEND OVERFLOW -- |num96| >= 2^NW, widen NW"
              severity failure;
            assert sum_l > 0
              report "attention_ml: DIVISOR <= 0 -- sum_l must be >= 1"
              severity failure;
            assert sum_l < shift_left(to_signed(1, 64), DW)
              report "attention_ml: DIVISOR OVERFLOW -- sum_l >= 2^DW, widen DW"
              severity failure;
            -- synthesis translate_on
            nmag_n := unsigned(nabs96(NW-1 downto 0));
            sum_n  := unsigned(sum_l(DW-1 downto 0));
            -- ---- LOAD the multi-cycle restoring divider ----------------------
            -- The `/` operator is NOT used: it returns wrong quotients on silicon
            -- from bit-perfect operands (see the NW/DW + divider_rs headers).
            -- Both operands and the sign are REGISTERED here; u_div then consumes
            -- nothing but those registers for the whole NW-cycle iteration, so
            -- there is no operand/divider sampling race either.
            dv_num_r <= std_logic_vector(nmag_n);
            dv_den_r <= std_logic_vector(sum_n);
            dv_neg   <= nneg;
            dv_go    <= '1';                     -- 1-cycle start (process default clears it)
            -- operand snapshots for the probes (ns_dout advances during the divide)
            if PROBES then
              dv_nmag_r <= nmag;
              dv_nsd_r  <= ns_dout;
            end if;
            state <= S_DIV_ITER;

          -- The divider runs (NW restoring steps) on the registered operands.
          -- (dv_go already fell back to '0' via the process-level default.)
          when S_DIV_ITER =>
            if dv_done = '1' then
              state <= S_DIV_FIN;                -- dv_quo valid and holding
            end if;

          -- Finalise this lane: qmag = floor(|num96| / sum_l), then the SAME
          -- probe / QCLAMP / signed write-back / lane-advance logic that used to
          -- sit at the tail of S_WDIV (byte-identical behaviour, one state later).
          when S_DIV_FIN =>
            qmag := resize(unsigned(dv_quo), 64);
            -- PROBE (observation only -- the compute below is untouched): record the
            -- PRE-CLAMP quotient and the operands AS CONSUMED.  Placed BEFORE the
            -- clamp so p_cd_qmag/p_l1_qmag are the RAW divider result: if the raw
            -- quotient is already >= 2^40 the divider mis-computed from operands we
            -- can now read back; if the operands here differ from the p_sums/p_nmax
            -- probes then the divide consumed something else than we thought (stale
            -- ns_dout / sequencing).
            if PROBES then
              -- unconditional: the lane the sticky amax_s pointed at on silicon
              if hd = 0 and t_idx = 1 then
                pr_l1_qmag <= qmag;                                 -- pre-clamp
                pr_l1_nmag <= dv_nmag_r;  -- the DIVIDEND the divider consumed
                pr_l1_nsd  <= dv_nsd_r;
                pr_l1_sum  <= std_logic_vector(sum_l(31 downto 0));
              end if;
              -- RUNNING MAX of the pre-clamp quotient over all 64 divides, with
              -- the winning division's operands + lane.  This is the division
              -- that sets the sticky amax_s (and hence the output block exponent),
              -- and it is captured wherever it happens -- no lane hardcoded, since
              -- the worst lane is 26 in sim and 36 on silicon.
              if pr_qx_valid = '0' or qmag > pr_qx_qmag then
                pr_qx_valid <= '1';
                pr_qx_qmag  <= qmag;                                -- pre-clamp
                pr_qx_nmag  <= dv_nmag_r;
                pr_qx_nsd   <= dv_nsd_r;
                pr_qx_sum   <= std_logic_vector(sum_l(31 downto 0));
                pr_qx_hd    <= to_unsigned(hd, 8);
                pr_qx_t     <= to_unsigned(t_idx, 8);
                pr_qx_lane  <= to_unsigned(hd*HEAD_SIZE + t_idx, 8);
              end if;
              -- event-triggered: the FIRST division that exceeds the guard, plus a
              -- saturating count of how many divisions clamped in the whole call.
              if qmag > QCLAMP then
                if pr_cd_cnt /= to_unsigned(127, 7) then
                  pr_cd_cnt <= pr_cd_cnt + 1;
                end if;
                if pr_cd_seen = '0' then
                  pr_cd_seen <= '1';
                  pr_cd_qmag <= qmag;                               -- pre-clamp
                  pr_cd_nmag <= dv_nmag_r;
                  pr_cd_nsd  <= dv_nsd_r;
                  pr_cd_sum  <= std_logic_vector(sum_l(31 downto 0));
                  pr_cd_hd   <= to_unsigned(hd, 8);
                  pr_cd_t    <= to_unsigned(t_idx, 8);
                  pr_cd_lane <= to_unsigned(hd*HEAD_SIZE + t_idx, 8);
                end if;
              end if;
            end if;
            if qmag > QCLAMP then qmag := QCLAMP; end if;          -- range guard
            -- sign re-application uses the REGISTERED sign latched at load time.
            if dv_neg = '1' then xb_acc(hd*HEAD_SIZE + t_idx) <= -signed(qmag);
            else                 xb_acc(hd*HEAD_SIZE + t_idx) <=  signed(qmag);
            end if;
            -- (no rotation: ns_raddr walks the lanes; the next head's first position
            -- overwrites the RAM via ns_first, so no clear is needed either.)
            if t_idx = HEAD_SIZE-1 then
              t_idx <= 0;
              if hd = NHEADS-1 then
                amax_s <= (others => '0');   -- prime the S_PACK max scan
                if PROBES then pr_amaxidx <= 0; end if;
                state  <= S_PACK;
              else
                hd    <= hd + 1;
                state <= S_HEAD;
              end if;
            else
              t_idx <= t_idx + 1;            -- next lane -> back to S_WDIV
              state <= S_WDIV;
            end if;

          -- ------------------------------------------------------------
          -- BFP-pack acc vector (value = acc*2^-(Q+vref)) -> xb_mant/xb_exp.
          -- Max-abs scan: ONE element per cycle (t_idx = 0..DIM-1).
          when S_PACK =>
            -- PROBE: record WHICH lane sets the running max (pr_amaxidx).  amax_s
            -- is STICKY, so one oversized lane latches and shifts all 64 output
            -- mantissas to junk -- this says which one.
            if xb_acc(t_idx) >= 0 then
              if xb_acc(t_idx) > amax_s then
                amax_s <= xb_acc(t_idx);
                if PROBES then pr_amaxidx <= t_idx; end if;
              end if;
            else
              if -xb_acc(t_idx) > amax_s then
                amax_s <= -xb_acc(t_idx);
                if PROBES then pr_amaxidx <= t_idx; end if;
              end if;
            end if;
            if t_idx = DIM-1 then
              t_idx <= 0;
              state <= S_PACK_EMIT;
            else
              t_idx <= t_idx + 1;
            end if;

          -- Emit: pack ONE element per cycle with the now-final shift gx.
          when S_PACK_EMIT =>
            gx := bfp_g(amax_s);
            xb_mant((t_idx+1)*16-1 downto t_idx*16) <=
              std_logic_vector(to_signed(pack1(xb_acc(t_idx), gx), 16));
            xb_exp <= (vref_s + WQ) + gx;
            if t_idx = DIM-1 then
              done  <= '1';
              state <= S_IDLE;
            else
              t_idx <= t_idx + 1;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture rtl;
