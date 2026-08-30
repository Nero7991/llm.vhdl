-- rtl/matvec_int4_desc_pkg.vhd -- the byte-pinned layout of subsystem A's
-- in-memory descriptor, in one place.
--
-- Spec: docs/2026-08-28_matvec-descriptor-format.md
--
-- The layout is subsystem D's (rtl/seq_desc_fetch.vhd): 64-bit little-endian
-- words, a 64-byte header at 0x00, and the base array at 0x40 -- the array D
-- deliberately does not fetch.  Subsystem A adds a four-word EXTENSION
-- immediately AFTER the base array, which is the one region D never reads, so
-- a descriptor written to this package's layout is still a valid D descriptor.
--
-- Everything here is a constant or a pure function of the geometry, so the
-- gateware and the testbench that builds a descriptor image compute the same
-- offsets from the same source.  A testbench that recomputed them from the
-- document would agree with a wrong document just as happily.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package matvec_int4_desc_pkg is

  -- "MV4I", the same code ref/matvec_int4.c uses for the packed file's magic
  -- and the same value the AXI-Lite ID register returns.
  constant MV4I_MAGIC : std_logic_vector(31 downto 0) := x"4D563449";

  -- Version of the A EXTENSION block.  D's own header carries no version
  -- field, so this is the only one, and it covers exactly the words this
  -- package adds.
  constant MV4I_DESC_VER : natural := 1;

  -- D's opcode for a subsystem A job (rtl/seq_desc_fetch.vhd:253).
  constant OP_A_JOB : natural := 0;

  -- Word indices.  Header 0..7; base array from 8; extension after that.
  constant DESC_HDR_WORDS : natural := 8;
  constant DESC_EXT_WORDS : natural := 4;
  constant DESC_BASE0     : natural := DESC_HDR_WORDS;   -- = 8, byte 0x40

  -- Error codes.  D uses 0x1..0x8 (ERR_UNIT, ERR_LOCK, ERR_DESC, ERR_WDOG,
  -- ERR_GRANT, ERR_CTX, ERR_EPOCH, ERR_ABORT).  ERR_DESC and ERR_WDOG mean
  -- the same things here and keep D's values; everything A-specific starts at
  -- 0x9 so the two spaces can be merged later without a renumbering.
  constant EC_NONE  : std_logic_vector(3 downto 0) := x"0";
  constant EC_DESC  : std_logic_vector(3 downto 0) := x"3";
  constant EC_WDOG  : std_logic_vector(3 downto 0) := x"4";
  constant EC_GEOM  : std_logic_vector(3 downto 0) := x"9";
  constant EC_MAGIC : std_logic_vector(3 downto 0) := x"A";
  constant EC_VER   : std_logic_vector(3 downto 0) := x"B";
  constant EC_ALIGN : std_logic_vector(3 downto 0) := x"C";
  constant EC_ADDR  : std_logic_vector(3 downto 0) := x"D";
  constant EC_CORE  : std_logic_vector(3 downto 0) := x"E";
  -- w_beats or s_beats does not match the shape in n_rows/n_cols.  This is
  -- the LAST free value in the 4-bit field: 0x1,0x2,0x5..0x8 are reserved for
  -- D's ERR_UNIT/ERR_LOCK/ERR_GRANT/ERR_CTX/ERR_EPOCH/ERR_ABORT so the two
  -- spaces can still be merged, and 0x0,0x3,0x4,0x9..0xE are taken above.
  --
  -- SUPERSEDED 2026-08-29, and left standing because it was acted on: the line
  -- that stood here said "a further A-specific code needs the field widened,
  -- not another value."  Widening is not the only option and is not the one
  -- taken.  A further A-specific condition takes a SUB-CASE under an existing
  -- code -- see the ERR_INFO block below.  The 4-bit code field is unchanged
  -- and still full; what changed is that it no longer has to carry the whole
  -- diagnosis on its own.
  constant EC_SHAPE : std_logic_vector(3 downto 0) := x"F";

  -- ======================================================================
  -- ERR_INFO: A WORD INDEX *AND* A SUB-CASE, IN THE SAME 16 BITS.
  -- ======================================================================
  -- OI-9.  The 4-bit err_code field above is FULL, and the route Oren chose on
  -- 2026-08-29 is to subdivide through ERR_INFO rather than widen the field or
  -- raid one of D's reserved values.  The binding constraint is that the
  -- DESCRIPTOR's byte layout must not move: it is pinned in
  -- docs/2026-08-28_matvec-descriptor-format.md and read by A, by D and by the
  -- host builder.  ERR_INFO is a REGISTER field, not a descriptor field, so
  -- nothing here touches that layout.
  --
  -- THE PROBLEM THIS SOLVES, MEASURED at 3d5cba9 by reading every raise site in
  -- rtl/matvec_int4_desc_axi.vhd: EC_DESC (0x3) is raised at NINE distinct
  -- checks and they carry only SEVEN distinct ERR_INFO values, so
  --     opcode /= OP_A_JOB      and  cb_load=0 with no codebook  both say (3, 0)
  --     word 3's pad nonzero    and  out_mode > 2                both say (3, 3)
  -- and a refusal cannot be attributed to the check that raised it.  The same
  -- defect exists outside EC_DESC and was not previously written down:
  --     nsub_w mismatch         and  nsub_s mismatch             both say (9, 3)
  --     n_rows=0 / n_rows>max / n_cols=0 / n_cols>max   all four say (3, 1)
  --     w_beats=0               and  s_beats=0                   both say (3, EXT0+1)
  --     ext word 2's pad half   and  ext word 3 nonzero          both say (3, EXT0+2)
  --     all three S_SHAPE_C disjuncts                       all say (15, EXT0+1)
  --
  -- THE SCHEME.  ERR_INFO keeps its word-index meaning in the LOW bits and
  -- gains a sub-case in the HIGH bits:
  --
  --     ERR_INFO[15:11] = sub-case, namespaced PER err_code (0 = none)
  --     ERR_INFO[10:0]  = the failing descriptor WORD index
  --
  -- The two meanings COEXIST rather than one replacing the other: every site
  -- still names its word, and the sub-case says which check on that word fired.
  -- That is load-bearing at the sites where one word carries several checks
  -- (word 3 holds out_mode, nsub_w, nsub_s and a pad; word EXT0+1 holds both
  -- beat counts), and it is what lets ED_PAD_EXT name EXT0+2 or EXT0+3 while
  -- staying one sub-case.
  --
  -- WHAT IT COSTS, stated rather than hidden:
  --   * the word index is capped at EI_WORD_MAX = 2047.  DERIVED: at the FK33
  --     geometry desc_words(24,3) = 39, so the cap is 52x the longest
  --     descriptor this build can produce, and it is 2036 sub-regions before it
  --     binds.  matvec_int4_desc_axi carries an ELABORATION guard on it -- a
  --     natural constant, because Vivado silently ignores
  --     `assert ... severity failure` in synthesis.
  --   * 30 sub-cases per err_code (1..30).  EC_DESC uses 13.
  --   * sub-case 0 leaves ERR_INFO NUMERICALLY UNCHANGED from the old
  --     word-index-only encoding, so every value this design used to report
  --     from a site that is not subdivided still reports the same integer.  A
  --     host that has not been taught the split still reads the right word for
  --     those, and reads a large number for the subdivided ones -- which is
  --     visible, not silently wrong.
  --
  -- 0xFFFF, the "the pointer itself, not a descriptor word" sentinel, is
  -- UNCHANGED and now falls out of the scheme: it is sub-case EI_SUB_PTR (31,
  -- reserved) with word 2047.  Decoding rule for a host: if
  -- ERR_INFO[15:11] = 31 the report is about DESC_PTR and there is no word.
  constant EI_WORD_W   : natural := 11;
  constant EI_SUB_W    : natural := 5;
  constant EI_WORD_MAX : natural := 2**EI_WORD_W - 1;   -- 2047
  constant EI_SUB_MAX  : natural := 2**EI_SUB_W - 1;    -- 31

  constant EI_SUB_NONE : natural := 0;                  -- no sub-case
  constant EI_SUB_PTR  : natural := EI_SUB_MAX;         -- reserved: the pointer

  -- ERR_INFO's "the pointer itself, not a descriptor word" sentinel.
  constant EI_PTR : natural := 16#FFFF#;
  constant EI_PTR_V : std_logic_vector(15 downto 0) := x"FFFF";

  -- ---------------------------------------------------------- sub-cases
  -- NAMESPACED PER err_code.  A host decodes the PAIR (err_code, sub-case);
  -- the same sub-case number under two different codes means two different
  -- things, which is what keeps 30 values enough for a field that had run out
  -- of 16.  Every constant below names ONE `elsif` arm in
  -- rtl/matvec_int4_desc_axi.vhd and nothing else.

  -- EC_DESC (0x3) -- thirteen arms, previously seven reports.
  constant ED_EXT_FLAGS    : natural := 1;   -- ext word 0 [63:48] nonzero
  constant ED_OPCODE       : natural := 2;   -- word 0 opcode /= OP_A_JOB
  constant ED_PAD_W3       : natural := 3;   -- word 3 [63:56] nonzero (D's pad)
  constant ED_PAD_W7       : natural := 4;   -- word 7 nonzero (D's reserved)
  constant ED_PAD_EXT      : natural := 5;   -- ext word 2 hi half, or ext word 3
  constant ED_OUT_MODE     : natural := 6;   -- word 3 out_mode > 2
  constant ED_ROWS_ZERO    : natural := 7;   -- n_rows = 0
  constant ED_ROWS_MAX     : natural := 8;   -- n_rows > MAXROWS_BFP
  constant ED_COLS_ZERO    : natural := 9;   -- n_cols = 0
  constant ED_COLS_MAX     : natural := 10;  -- n_cols > MAXCOLS
  constant ED_WBEATS_ZERO  : natural := 11;  -- w_beats = 0
  constant ED_SBEATS_ZERO  : natural := 12;  -- s_beats = 0
  constant ED_CB_UNLOADED  : natural := 13;  -- cb_load = 0, no codebook loaded

  -- EC_GEOM (0x9) -- two arms, previously one report.
  constant EG_NSUB_W       : natural := 1;   -- word 3 nsub_w /= NPORTS_W
  constant EG_NSUB_S       : natural := 2;   -- word 3 nsub_s /= NPORTS_S

  -- EC_SHAPE (0xF) -- three arms, previously one report.
  constant ES_WBEATS       : natural := 1;   -- w_beats /= tiles*nblk
  constant ES_SBEATS_LO    : natural := 2;   -- s_beats*GRP  <  tiles*nblk
  constant ES_SBEATS_HI    : natural := 3;   -- (s_beats-1)*GRP >= tiles*nblk

  -- Build an ERR_INFO value.  BOTH operands are range-constrained in the
  -- parameter list, so a site that passes an out-of-range sub-case or a word
  -- index a longer descriptor could produce is a BOUND VIOLATION at the call,
  -- not a value that silently aliases onto a neighbouring site's report.
  function ei(sub  : natural range 0 to EI_SUB_MAX;
              word : natural range 0 to EI_WORD_MAX)
    return std_logic_vector;

  -- Word index of the first extension word, i.e. byte 0x40 + 8*(npw+nps).
  function desc_ext0 (npw, nps : positive) return natural;

  -- Total descriptor length in 64-bit words.
  function desc_words(npw, nps : positive) return positive;

  -- Beats the fetch reads at a given AXI data width, rounded up.  Trailing
  -- words in the last beat are ignored.
  function desc_beats(npw, nps : positive; axi_dw : positive) return positive;

end package;

package body matvec_int4_desc_pkg is

  function ei(sub  : natural range 0 to EI_SUB_MAX;
              word : natural range 0 to EI_WORD_MAX)
    return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(sub,  EI_SUB_W)) &
           std_logic_vector(to_unsigned(word, EI_WORD_W));
  end function;

  function desc_ext0 (npw, nps : positive) return natural is
  begin
    return DESC_BASE0 + npw + nps;
  end function;

  function desc_words(npw, nps : positive) return positive is
  begin
    return DESC_BASE0 + npw + nps + DESC_EXT_WORDS;
  end function;

  function desc_beats(npw, nps : positive; axi_dw : positive) return positive is
    constant wpb : positive := axi_dw / 64;
  begin
    return (desc_words(npw, nps) + wpb - 1) / wpb;
  end function;

end package body;
