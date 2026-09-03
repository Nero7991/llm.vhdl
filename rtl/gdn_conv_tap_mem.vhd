-- rtl/gdn_conv_tap_mem.vhd -- ONE GDN layer's CONV TAP HISTORY.
--
-- `gdn_conv` implements section 1.4(e) literally: a depthwise causal
-- convolution of kernel KCONV over the qkv stream.  Causal means the previous
-- KCONV-1 columns of the WHOLE qkv width have to survive from one token to the
-- next, exactly like the recurrent state does.  At the 9B shape that is
-- `3 x 8,192 x 16 bits = 49,152 bytes per layer`, and
-- `tools/hbm_map.py::arena_sizes()` reserves it as
-- `gdn_state_conv_bytes_per_layer` (added 2026-09-02).
--
-- WHAT IT REPLACES.  `rtl/llama_top.vhd`'s stub, which returns ZERO for every
-- stored tap and says so in its own comment: "Older than the first token.
-- `gdn_exp_capture`'s tvalid mask excludes these; zero is what they are, not a
-- stand-in."  That is correct for token 0 and WRONG for every token after it,
-- which is why `B_SRC_REAL` has never been run past token 0 anywhere in this
-- repository.
--
-- THE READ IS "REGISTERED ADDRESS, COMBINATIONAL DATA", which is a plain
-- synchronous-read BRAM and not the distributed RAM the exponent store needs.
-- `gdn_block`'s port comment (:269-272) states the contract: "cv_ren/cv_grp/
-- cv_seg are registered outputs; cv_x/cv_w must be valid in the cycle AFTER
-- the one in which cv_ren is high, i.e. exactly what a registered-output BRAM
-- does."  So this is BRAM, deliberately.
--
-- **AND ASKING FOR BRAM IS NOT GETTING IT.  MEASURED 2026-09-02, the FIRST
-- version of this file, `ram_style = "block"` set on the array:**
--
--   CLB LUTs 35,726 (8.13% of the device), of which 28,160 LUT as MEMORY
--   Block RAM Tile 0        URAM 0        RAM64M8 3,584
--
-- Zero BRAM and 8% of the part for 49 KB.  Two things defeated the inference
-- and both had to go:
--
--   1. A VARIABLE-OFFSET PARTIAL WRITE.  The mover writes ONE 16-bit lane
--      inside a 192-bit word at a computed bit offset.  BRAM writes whole
--      words, or bytes under a byte-enable with a STATIC structure; a slice
--      whose bounds are expressions is neither.
--   2. TWO READ ADDRESSES ON ONE ARRAY.  The unit reads a group, the mover
--      reads a word, and with no port structure to bind them to Vivado
--      duplicated the storage instead.
--
-- **AND THE FIRST TWO REWRITES STILL DID NOT GET BRAM, WHICH IS THE POINT.**
-- Rewrite 2 split the store into NTAP*CONV_LANES banks of whole 16-bit words,
-- one array-of-arrays.  Vivado:
--   [Synth 8-11357] Potential Runtime issue for 3D-RAM or RAM from
--   Record/Structs for RAM mem_reg with 393216 registers
-- then a hundred `[Synth 8-7186] ... object 'mem[0][83]' is not inferred as
-- ram due to incorrect usage`, and 0 BRAM again.  A THREE-dimensional object
-- is not a memory to this engine whatever the attribute says.
-- Rewrite 3 moved each bank inside a `for ... generate`, so every array is
-- plainly two-dimensional, and gave a DIFFERENT refusal:
--   [Synth 8-4767] Trying to implement RAM 'gbank[11].m_reg' in registers ...
--   1: RAM has multiple writes via different ports in same process.
-- -- the true-dual-port template needs one process PER PORT, and two VHDL
-- processes cannot drive one signal.
--
-- So this is a SIMPLE dual-port memory: ONE write port and ONE read port,
-- each muxed between the unit and the mover.  That is sound because they
-- never overlap -- `gdn_state_store` gates the unit off while a mover owns
-- the tier -- and it makes the mover-wins rule STRUCTURAL rather than
-- defensive: there is one port, so there is nothing to collide.
--
-- **THREE REWRITES, THREE DIFFERENT REFUSALS, AND THE BIT COUNT PREDICTED
-- NONE OF THEM.** 49 KB "is 12 RAMB36" was true of the storage and said
-- nothing about what the tool would build.
--
-- This is `region_mem` again -- the case this repository already has on
-- record: ZERO BRAM and 91,073 LUT from a single combinational read port,
-- where the array's shape was never the cause.  **The bit count never told
-- anyone anything about the tiles.**
--
-- SO THE STORE IS NTAP*CONV_LANES SEPARATE BANKS, each `NGRP` deep and 16
-- bits wide, addressed by GROUP.  The unit's read wants all of them at one
-- group in one cycle, which is exactly what parallel banks give; every write
-- is a WHOLE 16-bit word into one bank; and the unit and the mover get port A
-- and port B of a true dual-port BRAM rather than competing for one address.
-- The rotation and the mover's word mux are then plain logic OUTSIDE the
-- memory.
--
-- THE COLUMNS ROTATE; THEY ARE NOT SHIFTED.  A shift would mean reading and
-- rewriting all `QKV_DIM/CONV_LANES` groups once per layer per token -- 2,048
-- reads AND 2,048 writes at the 9B shape, on top of the 2,048-cycle conv pass
-- itself.  Instead each group holds KCONV-1 SLOTS and a counter names which
-- slot is oldest; a token overwrites only that one.  Same write count, no
-- reads, and no read-modify-write to get wrong.
--
-- **`phase` IS GLOBAL AND NOT PER-LAYER, AND THAT IS WHY IT NEEDS NO HBM
-- STORAGE.** Every GDN layer is visited exactly once per token, so every
-- layer's rotation advances in lockstep: `phase = token_index mod (KCONV-1)`.
-- Had it been per-layer it would have been a KCONV-1-valued field with nowhere
-- to live -- `LAYER_STRIDE` is 1,048,576 + 4,096 + 49,152 with no slack -- and
-- the arena would have had to grow again.  The mover therefore moves the raw
-- bytes and knows nothing about rotation, which is the property that keeps
-- `gdn_state_axi` unchanged.
--
-- THE CALLER CONCATENATES THE CURRENT COLUMN.  This memory holds KCONV-1
-- taps, not KCONV.  The newest element of `cv_x` is THIS token's qkv, which
-- comes from A and is not state at all; putting it in here would mean writing
-- it before the conv reads it, in the same cycle, for no gain.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gdn_conv_tap_mem is
  generic(
    KCONV      : positive := 4;      -- model_cfg_pkg conv_kernel
    CONV_LANES : positive := 4;      -- gdn_block CONV_LANES
    KEY_CH     : positive := 2048;   -- KEY_HEADS*DIM: the q and the k segment
    VAL_CH     : positive := 4096;   -- VAL_HEADS*DIM: the v segment
    STYLE      : string   := "block" -- "block" or "auto".  NOT "distributed".
  );
  port(
    clk : in std_logic;

    -- ---- the unit's port, shaped exactly like gdn_block's cv_* -----------
    -- `r_seg`/`r_grp` are sampled on the rising edge and `r_x` is valid in the
    -- following cycle, which is what gdn_block's contract asks for.  The
    -- channel is `seg_base(seg) + grp*CONV_LANES + lane`, the same
    -- decomposition llama_top's `cvdata_p` performs today.
    r_seg  : in  integer range 0 to 2;
    r_grp  : in  natural range 0 to VAL_CH/CONV_LANES-1;
    -- OLDEST FIRST: element t of this vector is tap t of gdn_conv's `cv_x`,
    -- for t in 0 .. KCONV-2.  The caller appends the current column as
    -- t = KCONV-1.
    r_x    : out std_logic_vector((KCONV-1)*CONV_LANES*16-1 downto 0);

    -- ---- the unit's write: THIS token's column, one group at a time ------
    -- Lands in the slot the rotation is about to retire, so it is readable as
    -- the NEWEST stored tap from the next token onward.
    w_en   : in  std_logic;
    w_seg  : in  integer range 0 to 2;
    w_grp  : in  natural range 0 to VAL_CH/CONV_LANES-1;
    w_data : in  std_logic_vector(CONV_LANES*16-1 downto 0);

    -- ---- the rotation ----------------------------------------------------
    -- Pulsed ONCE per token, after every layer has both read and written.
    -- The caller owns it because only the caller knows where a token ends.
    tok_adv : in std_logic;

    -- ---- the mover's port, flat 16-bit words within the layer ------------
    -- Registered read, because `gdn_state_axi` collects a word TWO edges after
    -- issuing its address.  Handing it an asynchronous port shifts every saved
    -- block by one element; that is defect D2 of
    -- docs/debugging/2026-09-02_gdn-state-dma.md and it has now been made
    -- twice in this file's siblings.
    -- `m_r_en` SELECTS THE SHARED READ PORT, and it exists because this is a
    -- SIMPLE dual-port memory and not a true one: one write port and one read
    -- port, both muxed between the unit and the mover.  They never overlap --
    -- `gdn_state_store` gates the unit off while a mover owns the tier -- so
    -- one of each is sufficient, and it is what BRAM infers from.
    -- `gdn_state_axi` already drives `m_r_en`; the sibling stores leave it
    -- unconnected and this one does not.
    m_r_en   : in  std_logic;
    m_r_addr : in  natural range 0 to (KCONV-1)*(2*KEY_CH+VAL_CH)-1;
    m_r_data : out std_logic_vector(15 downto 0);
    m_w_en   : in  std_logic;
    m_w_addr : in  natural range 0 to (KCONV-1)*(2*KEY_CH+VAL_CH)-1;
    m_w_data : in  std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of gdn_conv_tap_mem is
  constant NTAP  : positive := KCONV - 1;             -- stored columns
  constant QKVN  : positive := 2*KEY_CH + VAL_CH;     -- total conv channels
  constant NGRP  : positive := QKVN / CONV_LANES;     -- groups in the store
  constant GW    : positive := CONV_LANES * 16;       -- bits in one group
  constant NBANK : positive := NTAP * CONV_LANES;     -- one 16-bit bank each
  constant WORDS : positive := NTAP * QKVN;           -- 16-bit words in a layer

  -- ---- REFUSALS THAT RUN DURING ELABORATION ---------------------------
  -- Out-of-range `natural`s, not asserts: Vivado ignores
  -- `assert ... severity failure` in synthesis.  The NAME is the diagnostic.
  --
  -- A kernel of 1 has no history at all and every width below becomes zero.
  constant bad_kconv_below_two : natural := KCONV - 2;
  -- Each segment must tile into whole groups, or `seg_base/CONV_LANES` is not
  -- an integer and the q, k and v regions overlap by a fraction of a group.
  constant bad_key_ch_not_group_aligned : natural := 0 - (KEY_CH mod CONV_LANES);
  constant bad_val_ch_not_group_aligned : natural := 0 - (VAL_CH mod CONV_LANES);
  -- The v segment is the widest, so `r_grp`'s declared range is v's.  A q or k
  -- segment WIDER than v would index past the end of the store, silently.
  constant bad_key_wider_than_val : natural := VAL_CH - KEY_CH;

  function chk_style(s : string) return string is
    variable bad : natural;
  begin
    if s = "block" or s = "auto" then
      return s;
    end if;
    -- NOT the literal -1: GHDL folds a literal at ANALYSIS time and then warns
    -- on every legal build.  `s'length` is a parameter and cannot be folded.
    bad := -s'length;
    return s;
  end function;

  -- The bank arrays and the `ram_style` attribute are declared INSIDE the
  -- `gbank` generate below, not here: see the comment there for the
  -- measurement that forced it.  `STY` is shared because it is the checked
  -- STYLE string and nothing more.
  constant STY : string(1 to STYLE'length) := chk_style(STYLE);

  signal phase : natural range 0 to NTAP-1 := 0;

  type word_arr_t is array (0 to NBANK-1) of std_logic_vector(15 downto 0);
  -- ONE set of read registers, because there is one read port.
  signal rq    : word_arr_t := (others => (others => '0'));
  signal rq_ph : natural range 0 to NTAP-1 := 0;
  signal mb_q  : natural range 0 to NBANK-1 := 0;   -- which bank the mover read

  -- The flat group of a (segment, group) pair.  `seg_base` is 0, KEY_CH and
  -- 2*KEY_CH, which is the SAME decomposition llama_top's `cvdata_p` does and
  -- the same channel order `seq_opdec`'s MSEG mechanism uses: q | k | v.
  function gidx(seg : integer; grp : natural) return natural is
  begin
    if seg = 0 then
      return grp;
    elsif seg = 1 then
      return KEY_CH/CONV_LANES + grp;
    else
      return 2*KEY_CH/CONV_LANES + grp;
    end if;
  end function;

  -- The mover's flat word address, decomposed.  SLOT-MAJOR, so a layer is one
  -- contiguous extent in HBM: `addr = slot*QKVN + channel`.
  --
  -- THE DIVISIONS ARE BY CONSTANTS, and at the shipping shape both divisors
  -- are powers of two (QKVN 8,192 and CONV_LANES 4) so they fold to shifts.
  -- Written as divisions rather than as shifts because the module must stay
  -- correct at a non-power-of-two width, and the OOC census is what decides
  -- whether they cost anything -- not an argument here.
  function m_slot(a : natural) return natural is begin return a / QKVN; end;
  function m_grp (a : natural) return natural is
  begin return (a mod QKVN) / CONV_LANES; end;
  function m_lane(a : natural) return natural is
  begin return (a mod QKVN) mod CONV_LANES; end;
  function m_bank(a : natural) return natural is
  begin return m_slot(a) * CONV_LANES + m_lane(a); end;

  signal ra_s, gb_s, wa_s : natural range 0 to NGRP-1 := 0;
  signal mwg_s : natural range 0 to NGRP-1 := 0;
  signal mwb_s : natural range 0 to NBANK-1 := 0;
  signal rad_s : natural range 0 to NGRP-1 := 0;   -- the shared read address
begin
  -- Addresses computed ONCE, outside the bank generate, so the divisions are
  -- shared rather than replicated NBANK times.
  ra_s  <= gidx(r_seg, r_grp);
  wa_s  <= gidx(w_seg, w_grp);
  gb_s  <= m_grp(m_r_addr);
  mwg_s <= m_grp(m_w_addr);
  mwb_s <= m_bank(m_w_addr);

  -- THE ONE READ ADDRESS.  The mover owns it while it is reading and the unit
  -- owns it otherwise; they never both need it, so there is one read port and
  -- BRAM has something it can infer.
  rad_s <= gb_s when m_r_en = '1' else ra_s;

  -- ---- ONE BRAM PER BANK, AS A GENERATE, AND THAT IS NOT A STYLE CHOICE ---
  -- Declaring the array inside the generate is what makes each bank plainly
  -- TWO-dimensional; as one `array of array of vector` in the architecture it
  -- was a "3D-RAM" and Vivado dissolved it into 393,216 registers.  See the
  -- header for the full sequence of refusals.
  gbank : for b in 0 to NBANK-1 generate
    -- Bank b holds slot `b / CONV_LANES`, lane `b mod CONV_LANES`.  BOTH are
    -- static in this scope, so the lane slice of `w_data` below is a constant
    -- range and not a mux.
    constant SLOT : natural := b / CONV_LANES;
    constant LANE : natural := b mod CONV_LANES;

    type bank_t is array (0 to NGRP-1) of std_logic_vector(15 downto 0);
    signal m : bank_t := (others => (others => '0'));
    attribute ram_style : string;
    attribute ram_style of m : signal is STY;

    signal we  : std_logic;
    signal wad : natural range 0 to NGRP-1;
    signal wdt : std_logic_vector(15 downto 0);
  begin
    -- THE MOVER WINS, STRUCTURALLY.  There is ONE write port; the mux below
    -- hands it to the mover whenever `m_w_en` is high, so a simultaneous unit
    -- write is not a collision to resolve, it is a write that does not
    -- happen.  The earlier true-dual-port draft needed an explicit priority
    -- term for this, and no bench could see whether it was there: in
    -- simulation the second assignment in the process simply overwrote, so a
    -- mutation removing the term PASSED 107 of 107 while being undefined in
    -- hardware.  One port removes the question rather than guarding it.
    we  <= '1' when (m_w_en = '1' and mwb_s = b)
                 or (m_w_en = '0' and w_en = '1' and SLOT = phase) else '0';
    wad <= mwg_s when m_w_en = '1' else wa_s;
    wdt <= m_w_data when m_w_en = '1'
           else w_data((LANE+1)*16-1 downto LANE*16);

    pb : process(clk) is
    begin
      if rising_edge(clk) then
        if we = '1' then
          -- INTO THE SLOT ABOUT TO BE RETIRED, for a unit write.  After
          -- `tok_adv` that slot becomes tap NTAP-1, the NEWEST stored column,
          -- which is what the next token must see.
          m(wad) <= wdt;
        end if;
        rq(b) <= m(rad_s);
      end if;
    end process;
  end generate;

  -- ---- the unit read: NBANK words, then rotate ---------------------------
  -- The ROTATION IS OUTSIDE THE MEMORY, on its registered outputs, so every
  -- bank stays a plain BRAM.  Slot `phase` is the oldest -- it is the one the
  -- next write will retire -- so tap k is slot (phase+k) mod NTAP.
  rot : process(rq, rq_ph) is
    variable sl : natural;
  begin
    for k in 0 to NTAP-1 loop
      sl := (rq_ph + k) mod NTAP;
      for ln in 0 to CONV_LANES-1 loop
        r_x(k*GW + (ln+1)*16 - 1 downto k*GW + ln*16)
          <= rq(sl*CONV_LANES + ln);
      end loop;
    end loop;
  end process;

  -- The mover's read: the same registered bank outputs, selected by the bank
  -- its address named on the SAME edge.  Registered on the way in, muxed on
  -- the way out, so the two-edge contract holds.
  m_r_data <= rq(mb_q);

  ctl : process(clk) is
  begin
    if rising_edge(clk) then
      -- `rq_ph` is captured WITH the data.
      --
      -- **THIS CAPTURE IS DEFENSIVE AND IT IS UNTESTED, and the first version
      -- of this comment claimed more than that.**  It said the capture "makes
      -- the read correct across the `tok_adv` boundary", implying a reachable
      -- case.  There is none: `tok_adv` fires only after every layer has both
      -- read and written for the token, so no conv read can be in flight on
      -- that edge.  MEASURED -- mutation T4 replaces `rq_ph` with a direct
      -- read of `phase` at the rotate and `sim/tb_gdn_conv_tap_mem.vhd`
      -- PASSES, 107 of 107.  It is 2 FF, it is kept because a caller that
      -- ever did overlap the two would otherwise get a silently rotated
      -- column, and it is recorded here as an untested property rather than
      -- as a justified one.
      rq_ph <= phase;
      mb_q  <= m_bank(m_r_addr);

      if tok_adv = '1' then
        if phase = NTAP-1 then phase <= 0; else phase <= phase + 1; end if;
      end if;
    end if;
  end process;
end architecture;
