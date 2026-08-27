-- rtl/gdn_exp_capture.vhd
-- Subsystem B, section 2.1.2: the CAPTURED conv slot exponents.
--
-- WHY THIS EXISTS, in the spec's own words:
--
--   > **Captured, not re-read:** the conv slot exponents live in on-chip
--   > registers written when the slot is written. Reading A's `y_exp` port at
--   > *use* time would read the exponent of whatever job A ran last -- a
--   > per-token, per-segment power-of-two error, the C1/CR3-2 disease on a new
--   > seam.
--
-- `gdn_conv` already TAKES `e_t` (K packed int8 slot exponents) and `tvalid`.
-- Nothing produced them. This does.
--
-- THE HAZARD IS SPECIFIC AND WORTH RESTATING. A's BFP output exponent is
-- `y_exp = w_exp + x_exp - out_shift - ns` with `ns` data-dependent, so it is a
-- different value for every job. The causal conv reads K = 4 taps spanning the
-- current token and the three before it, and each of those taps was produced by
-- a DIFFERENT A job, at a different time, with a different `y_exp`. A design
-- that reads A's `y_exp` port when the conv runs gets the most recent job's
-- exponent for all four taps. The error is a power of two per tap, which is
-- silent: the conv still produces plausible numbers.
--
-- STRUCTURE. One word per (layer, segment) holding all K tap exponents packed
-- exactly as `gdn_conv` expects them -- tap `t` at bits `[(t+1)*8-1 : t*8]`,
-- so the CURRENT token is the top byte and tap 0 is the oldest. A capture is
-- therefore a shift:
--
--     new_word = cap_exp & old_word(K*8-1 downto 8)
--
-- which is a read-modify-write, hence the small FSM and the `ready` handshake.
--
-- WHY THE CURRENT TOKEN IS CAPTURED TOO, rather than passed live. Section 2.1.2
-- describes tap K-1 as "the live A y_exp for that segment", which invites an
-- implementation where K-1 comes straight from A's port and only taps 0..K-2
-- are captured. That mixes a live path with captured ones on the exact seam the
-- warning above is about, and it makes the correctness of tap K-1 depend on WHEN
-- the conv is started relative to A finishing. Capturing all K removes the live
-- path entirely, so the disease is structurally impossible rather than merely
-- avoided. The cost is one extra byte per entry.
--
-- TAP VALIDITY. `tvalid` masks taps that refer to tokens before the start of the
-- sequence. A per-entry counter saturating at K gives it: after `n` captures the
-- valid taps are the newest `n`, i.e. `tvalid(t) = '1'` for `t >= K - n`. At
-- token 0 exactly one tap is valid, which is the `tk = 0` case the spec's test
-- list calls for. `seq_rst` clears the counters at the start of a sequence; the
-- word memory is not cleared because every valid tap is overwritten before it
-- can be read.
--
-- SIZE. LAYERS * SEGS entries of K*8 bits. At 48 GDN layers and 3 segments per
-- card (q 1,024, k 1,024, v 3,072) that is 144 x 32 bits = 4,608 bits, which is
-- one small block RAM. The counters are LAYERS*SEGS * 3 bits in flops, since
-- they are read combinationally to build `tvalid` and a RAM would add a cycle to
-- the read path for 432 bits of storage.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity gdn_exp_capture is
  generic(
    LAYERS : positive := 48;   -- GDN layers (48 of the 64 blocks)
    SEGS   : positive := 3;    -- q, k, v
    K      : positive := 4     -- ssm.conv_kernel
  );
  port(
    clk     : in  std_logic;
    rst     : in  std_logic;
    -- Clears the tap-validity counters at the start of a sequence.  The word
    -- memory is deliberately NOT cleared; see the header.
    seq_rst : in  std_logic;

    -- ---- capture side: called when a slot is WRITTEN, not when it is used --
    cap_req   : in  std_logic;
    cap_layer : in  integer range 0 to LAYERS-1;
    cap_seg   : in  integer range 0 to SEGS-1;
    cap_exp   : in  signed(7 downto 0);      -- A's y_exp for THIS job
    cap_ready : out std_logic;               -- low while the RMW is in flight

    -- ---- read side: what gdn_conv consumes --------------------------------
    rd_req   : in  std_logic;
    rd_layer : in  integer range 0 to LAYERS-1;
    rd_seg   : in  integer range 0 to SEGS-1;
    rd_ack   : out std_logic;                -- e_t/tvalid stable from here
    e_t      : out std_logic_vector(K*8-1 downto 0);
    tvalid   : out std_logic_vector(K-1 downto 0)
  );
end entity;

architecture rtl of gdn_exp_capture is

  constant NENT : integer := LAYERS * SEGS;
  constant WW   : integer := K * 8;

  type mem_t is array (0 to NENT-1) of std_logic_vector(WW-1 downto 0);
  signal mem : mem_t;
  -- Pinned for the same reason gdn_head_emit and gdn_y_emit pin theirs: an
  -- inference that changes primitive with the generics makes resource tables
  -- incomparable, and distributed RAM is the primitive rmsnorm.vhd's S_RAW
  -- comment records producing non-deterministic output when inferred
  -- UNINITIALIZED.  Here the uninitialized-read argument is WEAKER than in
  -- those units -- a tap is only read when tvalid says it was written -- so
  -- pinning is doing real work rather than only tidying.
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";

  type cnt_t is array (0 to NENT-1) of integer range 0 to K;
  signal cnt : cnt_t := (others => 0);

  type state_t is (S_IDLE, S_CAP_RD, S_CAP_WR, S_RD);
  signal state : state_t := S_IDLE;

  signal cap_addr_r : integer range 0 to NENT-1 := 0;
  signal cap_exp_r  : signed(7 downto 0) := (others => '0');
  signal rd_addr_r  : integer range 0 to NENT-1 := 0;
  signal mem_q      : std_logic_vector(WW-1 downto 0) := (others => '0');

  signal e_t_r    : std_logic_vector(WW-1 downto 0) := (others => '0');
  signal tvalid_r : std_logic_vector(K-1 downto 0) := (others => '0');
  signal rd_ack_r : std_logic := '0';
  signal ready_r  : std_logic := '1';

  -- tvalid from a saturating count: after n captures the newest n taps are
  -- valid, i.e. tap t is valid for t >= K - n.
  function mask_of(n : integer; kk : integer) return std_logic_vector is
    variable v : std_logic_vector(kk-1 downto 0) := (others => '0');
  begin
    for t in 0 to kk-1 loop
      if t >= kk - n then v(t) := '1'; end if;
    end loop;
    return v;
  end function;

begin
  cap_ready <= ready_r;
  rd_ack    <= rd_ack_r;
  e_t       <= e_t_r;
  tvalid    <= tvalid_r;

  assert K >= 2 report "gdn_exp_capture: K must be at least 2" severity failure;

  process(clk)
    variable a : integer range 0 to NENT-1;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE; ready_r <= '1'; rd_ack_r <= '0';
        cnt <= (others => 0);
        e_t_r <= (others => '0'); tvalid_r <= (others => '0');
      else
        rd_ack_r <= '0';

        -- seq_rst during an in-flight capture is ambiguous: the clear below
        -- and the increment in S_CAP_WR both assign cnt, and VHDL's
        -- last-assignment-wins gives the increment, so the counter would
        -- survive the reset it was supposed to clear.  Rather than pick a
        -- winner silently, require the caller to quiesce first.  A sequence
        -- boundary is not a hot path.
        assert not (seq_rst = '1' and state /= S_IDLE)
          report "gdn_exp_capture: seq_rst asserted while a capture is in "
               & "flight; quiesce (cap_ready = '1') before starting a sequence"
          severity failure;
        if seq_rst = '1' then
          -- Only the counters.  Every tap that tvalid will report as valid is
          -- written before it can be read, so clearing the words would be
          -- 4,608 bits of reset fanout for nothing.
          cnt <= (others => 0);
        end if;

        case state is

          when S_IDLE =>
            -- Capture wins over read.  A read that collides with a capture is
            -- retried by the caller one cycle later; a capture that is DROPPED
            -- loses an exponent permanently and is exactly the failure this
            -- unit exists to prevent.
            if cap_req = '1' then
              a := cap_layer * SEGS + cap_seg;
              cap_addr_r <= a;
              cap_exp_r  <= cap_exp;
              mem_q      <= mem(a);
              ready_r    <= '0';
              state      <= S_CAP_RD;
            elsif rd_req = '1' then
              a := rd_layer * SEGS + rd_seg;
              rd_addr_r  <= a;
              mem_q      <= mem(a);
              state      <= S_RD;
            end if;

          when S_CAP_RD =>
            -- one cycle for the synchronous read to land in mem_q
            state <= S_CAP_WR;

          when S_CAP_WR =>
            -- The shift: the new exponent becomes tap K-1 (the top byte, the
            -- current token) and every existing tap moves down one.  Tap 0,
            -- the oldest, falls off.
            mem(cap_addr_r) <= std_logic_vector(cap_exp_r)
                             & mem_q(WW-1 downto 8);
            if cnt(cap_addr_r) < K then
              cnt(cap_addr_r) <= cnt(cap_addr_r) + 1;
            end if;
            ready_r <= '1';
            state   <= S_IDLE;

          when S_RD =>
            e_t_r    <= mem_q;
            tvalid_r <= mask_of(cnt(rd_addr_r), K);
            rd_ack_r <= '1';
            state    <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
