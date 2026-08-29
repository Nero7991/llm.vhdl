-- rtl/async_fifo.vhd -- dual-clock stream FIFO, gray-pointer, with an explicit
-- two-sided CLEAR handshake.
--
-- WHY THIS EXISTS.  rtl/weight_streamer.vhd's own header says, and spec 14.5
-- item 3 records, that the streamer is SINGLE-CLOCK while the FK33's HBM AXI
-- clock is not the core clock.  That is not a tidiness issue: the 27-master
-- feasibility note (docs/2026-08-28_can-27-read-masters-be-served.md) puts the
-- demand at 204.0 GB/s against a 259.2 GB/s supply only because the AXI side
-- runs FASTER than the core.  Run the AXI side at the core clock instead and
-- the duty is exactly 100% with zero margin, which is not a design.  So the
-- CDC is what buys the margin, and it belongs per port, in the one place that
-- already has a FIFO between the R channel and the consumer.
--
-- THE CLEAR IS THE HARD PART, NOT THE POINTERS.  A gray-pointer FIFO is
-- standard.  What is not standard is that 7.7 requires the FIFO to be FLUSHED
-- on start (see rtl/axi_rd_port.vhd's header: sub-regions are padded to whole
-- 4 KB bursts, so the final burst delivers padding beats that stay resident,
-- and the residue differs per port).  A synchronous `flush` input works in one
-- clock domain and is meaningless across two: clearing one side's pointer while
-- the other side's synchroniser still holds the old value makes the FIFO report
-- an occupancy that never existed, in whichever direction is unlucky.
--
-- So the clear is a FOUR-PHASE handshake, and the caller must run all four:
--
--   1. caller raises `clr` (write domain) and HOLDS it
--   2. the write side parks wp at 0 and passes the request to the read domain;
--      the read side parks rp at 0, empties its output stage, and acknowledges
--   3. the acknowledgement comes back as `clr_done`; BOTH pointers are now 0
--      and both are being HELD there, so there is no window in which one side
--      is running against the other's stale pointer
--   4. the caller drops `clr`; the read side releases, and `clr_done` falls.
--      Only then may traffic resume.
--
-- The caller must wait for `clr_done` to FALL as well as to rise.  Dropping
-- `clr` and immediately resuming would let the write side move wp while the
-- read side is still forcing rp to 0, and the read side would then see beats
-- appear before it had released -- the same class of one-beat misalignment that
-- axi_rd_port's S_FLUSH state was added to prevent, just spread over a CDC.
--
-- `w_level` is a WRITE-SIDE occupancy and it is deliberately CONSERVATIVE: the
-- read pointer reaches this domain two synchroniser stages late, and the beats
-- sitting in the read side's output stage have already retired rp but have not
-- been consumed.  It therefore reports at least the true occupancy, plus a
-- fixed margin for the output stage.  An AR-issue throttle that believes it is
-- an over-estimate is safe; one that believes it is exact overruns the FIFO by
-- up to three beats.
--
-- 0 DSP, and the memory is a simple dual-port array so it infers BRAM.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity async_fifo is
  generic(
    W     : positive := 256;
    -- MUST be a power of two.  Gray coding of a non-power-of-two pointer is
    -- not a single-bit-change encoding, which is the entire premise.
    DEPTH : positive := 256;
    -- Extra beats the write side pretends are resident, covering the read
    -- side's output stage plus the in-flight memory read.  3 is exactly that
    -- stage's capacity; it is a generic only so a caller can prove it matters.
    OUT_MARGIN : natural := 3
  );
  port(
    -- ------------------------------------------------------- write domain
    wclk     : in  std_logic;
    wrst     : in  std_logic;           -- synchronous in wclk
    w_valid  : in  std_logic;
    w_data   : in  std_logic_vector(W-1 downto 0);
    w_ready  : out std_logic;
    w_level  : out integer;             -- conservative occupancy, see header
    clr      : in  std_logic;           -- LEVEL; hold until clr_done, then drop
    clr_done : out std_logic;           -- LEVEL; falls after clr falls

    -- -------------------------------------------------------- read domain
    rclk     : in  std_logic;
    rrst     : in  std_logic;           -- synchronous in rclk
    q_valid  : out std_logic;
    q_data   : out std_logic_vector(W-1 downto 0);
    q_ready  : in  std_logic
  );
end entity;

architecture rtl of async_fifo is
  constant AW : positive := clog2(DEPTH);

  type mem_t is array(0 to DEPTH-1) of std_logic_vector(W-1 downto 0);
  signal mem : mem_t;
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";

  -- Pointers are AW+1 bits: the extra bit is what distinguishes full from
  -- empty when the low bits agree.
  subtype ptr_t is unsigned(AW downto 0);

  function bin2gray(b : ptr_t) return ptr_t is
  begin
    return b xor shift_right(b, 1);
  end function;

  function gray2bin(g : ptr_t) return ptr_t is
    variable b : ptr_t := (others => '0');
  begin
    -- b(msb) = g(msb); b(i) = b(i+1) xor g(i)
    b(AW) := g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor g(i);
    end loop;
    return b;
  end function;

  signal wp, rp           : ptr_t := (others => '0');
  signal wp_g, rp_g       : ptr_t := (others => '0');
  -- 2FF synchronisers.  Named, not inlined, so a constraint file can find them.
  signal wp_g_s1, wp_g_s2 : ptr_t := (others => '0');
  signal rp_g_s1, rp_g_s2 : ptr_t := (others => '0');

  -- clear handshake
  signal clr_r_s1, clr_r_s2   : std_logic := '0';   -- clr, in the read domain
  signal clr_ack_r            : std_logic := '0';   -- read side has parked
  signal clr_a_s1, clr_a_s2   : std_logic := '0';   -- ack, back in the write domain

  -- read-side output stage, same shape as rtl/stream_fifo.vhd and for the same
  -- reason: the memory read is REGISTERED so it infers BRAM, and a 2-entry
  -- stage hides the resulting cycle so the interface stays first-word-
  -- fall-through.
  type ob_t is array(0 to 1) of std_logic_vector(W-1 downto 0);
  signal ob           : ob_t := (others => (others => '0'));
  signal ob_wp, ob_rp : integer range 0 to 1 := 0;
  signal ocnt         : integer range 0 to 2 := 0;
  signal mem_q        : std_logic_vector(W-1 downto 0) := (others => '0');
  signal mem_q_v      : std_logic := '0';

  signal rp_bin_w : ptr_t;     -- read pointer, decoded, in the write domain
  signal wp_bin_r : ptr_t;     -- write pointer, decoded, in the read domain
  signal used_w   : ptr_t;
  signal empty_r  : std_logic;
  signal do_rd    : std_logic;
  signal inflight : integer range 0 to 1;
begin
  assert 2**AW = DEPTH
    report "async_fifo: DEPTH must be a power of two (gray coding is not a " &
           "single-bit-change encoding otherwise); DEPTH = " &
           integer'image(DEPTH)
    severity failure;

  -- ===================================================== write domain
  rp_bin_w <= gray2bin(rp_g_s2);
  used_w   <= wp - rp_bin_w;
  w_level  <= to_integer(used_w) + OUT_MARGIN;
  w_ready  <= '0' when clr = '1' or used_w = to_unsigned(DEPTH, AW+1) else '1';
  clr_done <= clr_a_s2;

  wproc : process(wclk)
  begin
    if rising_edge(wclk) then
      rp_g_s1 <= rp_g;  rp_g_s2 <= rp_g_s1;
      clr_a_s1 <= clr_ack_r; clr_a_s2 <= clr_a_s1;

      if wrst = '1' then
        wp <= (others => '0'); wp_g <= (others => '0');
        rp_g_s1 <= (others => '0'); rp_g_s2 <= (others => '0');
        clr_a_s1 <= '0'; clr_a_s2 <= '0';
      elsif clr = '1' then
        wp   <= (others => '0');
        wp_g <= (others => '0');
      else
        if w_valid = '1' and used_w /= to_unsigned(DEPTH, AW+1) then
          mem(to_integer(wp(AW-1 downto 0))) <= w_data;
          wp   <= wp + 1;
          wp_g <= bin2gray(wp + 1);
        end if;
        -- A write into a full FIFO would silently lose a beat and present as a
        -- per-port stream misalignment, which is the exact defect 7.7's flush
        -- rule exists to prevent.  The throttle above axi_rd_port makes it
        -- unreachable; this says so out loud if it ever is not.
        assert not (w_valid = '1' and used_w = to_unsigned(DEPTH, AW+1))
          report "async_fifo: WRITE INTO A FULL FIFO -- a beat was dropped"
          severity failure;
      end if;
    end if;
  end process;

  -- ====================================================== read domain
  wp_bin_r <= gray2bin(wp_g_s2);
  empty_r  <= '1' when rp = wp_bin_r else '0';
  inflight <= 1 when mem_q_v = '1' else 0;
  do_rd    <= '1' when empty_r = '0' and clr_r_s2 = '0'
                   and (ocnt + inflight) < 2 else '0';

  q_valid <= '1' when ocnt > 0 else '0';
  q_data  <= ob(ob_rp);

  rproc : process(rclk)
    variable o : integer;
  begin
    if rising_edge(rclk) then
      wp_g_s1 <= wp_g; wp_g_s2 <= wp_g_s1;
      clr_r_s1 <= clr; clr_r_s2 <= clr_r_s1;

      if rrst = '1' then
        rp <= (others => '0'); rp_g <= (others => '0');
        wp_g_s1 <= (others => '0'); wp_g_s2 <= (others => '0');
        clr_r_s1 <= '0'; clr_r_s2 <= '0'; clr_ack_r <= '0';
        ob_wp <= 0; ob_rp <= 0; ocnt <= 0; mem_q_v <= '0';
      elsif clr_r_s2 = '1' then
        -- Parked.  Pointer at 0, output stage empty, and the acknowledgement
        -- is raised only from HERE, so `clr_done` proves the read side saw it.
        rp        <= (others => '0');
        rp_g      <= (others => '0');
        ob_wp     <= 0; ob_rp <= 0; ocnt <= 0;
        mem_q_v   <= '0';
        clr_ack_r <= '1';
      else
        clr_ack_r <= '0';
        o := ocnt;

        mem_q   <= mem(to_integer(rp(AW-1 downto 0)));
        mem_q_v <= do_rd;
        if do_rd = '1' then
          rp   <= rp + 1;
          rp_g <= bin2gray(rp + 1);
        end if;

        if mem_q_v = '1' then
          ob(ob_wp) <= mem_q;
          ob_wp <= (ob_wp + 1) mod 2;
          o := o + 1;
        end if;

        if ocnt > 0 and q_ready = '1' then
          ob_rp <= (ob_rp + 1) mod 2;
          o := o - 1;
        end if;

        ocnt <= o;
      end if;
    end if;
  end process;
end architecture;
