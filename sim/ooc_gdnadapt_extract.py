#!/usr/bin/env python3
"""ooc_gdnadapt_extract.py -- subsystem B's data mover, extracted.

Carries `rtl/llama_top.vhd`'s `gb_real` generate block VERBATIM, with the names
it reads from `llama_top`'s enclosing scope turned into ports, generics and
local type declarations.  Same method as `sim/ooc_normadapt_extract.py`, which
did this for the D-vec norm adapter (`gvr`) and whose docstring states the
reasoning this file inherits.

WHY THIS BLOCK.  `docs/PLAN_TO_FIRST_INFERENCE.md` and
`hw/fk33/gen_compose4_top.py:928` both record that the per-unit DATA MOVERS
"do not exist yet".  That is true as a statement about ENTITIES and false as a
statement about LOGIC: `gb_real` is 614 lines of exactly that mover, it
instantiates `gdn_block`, and it has been exercised by every `llama_top` gate
row for weeks.  What does not exist is a way to build it as anything other
than a part of `llama_top`.  Extraction is therefore not new RTL; it is the
cheapest route from "1,600 lines unwritten" to "the lines exist and can be
synthesised, placed and reused".

WHY EXTRACT RATHER THAN REWRITE.  A rewrite is a model, and this project's
standing lesson is that a model written by the author of the thing it checks is
not evidence.  The block text here is taken verbatim from whichever
`llama_top.vhd` this script is pointed at, so the diff between two generated
files IS the diff between two `llama_top.vhd` files restricted to the block.

THE SEAM WAS VERIFIED BY READING, NOT BY REGEX, and that distinction cost five
separate errors on the way.  A first automated pass over the block got all of
these wrong, and every one would have produced a wrong entity:

  1. `uw_data` read as an INPUT.  It is written at block line 584, inside an
     `if ... then` on the same line, so an assignment regex anchored to
     line-start missed it.
  2. `y_valid`, `y_mant`, `y_last` read as seam members.  They are declared
     LOCALLY in the block; `llama_top` also declares signals of those names in
     a DIFFERENT generate block, and the resolver found those instead.
  3. `rdy`, `dn`, `ep`, `yexp` the same: block-local, with same-named signals
     elsewhere in `llama_top`.
  4. `u_start, u_ready, u_done, u_ack, u_err` invisible entirely, because their
     declaration spans two lines.
  5. `u_done_epoch` and `u_y_exp` read as INPUTS.  Both are written at block
     lines 137-138 with a slice expression containing nested parentheses,
     `((U_B+1)*EPOCH_W-1 downto U_B*EPOCH_W)`, which a `\\([^)]*\\)` pattern
     cannot match.

A regex over VHDL is not a parser.  The seam below is therefore a CHECKED
LITERAL rather than something this script derives, and the check that it is
right is that the output analyses: GHDL rejects an `in` port that is assigned,
a name declared twice, and a name with no declaration at all.

NO HARDWARE.  This script reads and writes text files and nothing else.

usage: ooc_gdnadapt_extract.py <path/to/llama_top.vhd> <out.vhd> [ENTITY]
       ooc_gdnadapt_extract.py --check <path/to/llama_top.vhd>
         -- checks BOTH canonical outputs in one process.  It takes no
            `out` argument on purpose: `run_selfcheck` in sim/regress.sh
            runs its command UNQUOTED and NOT through a shell, so a
            chained `a && b` would hand `&&` to argv and this script
            would check only the first file and pass.
"""

import re
import sys

START_RE = re.compile(r"^  gb_real : if not B_BEHAV generate\s*$")
# THE COUNTING MUST BE SYMMETRIC, and it was not.  This used to be
# `^  end generate;\s*$` -- pinned to TWO spaces, i.e. only `gb_real`'s own
# end.  But the opening test increments `depth` for a generate at ANY indent,
# so once `gb_real` gained NESTED generates the count could never return to
# zero and the script died with "no matching `end generate;`".
#
# MEASURED 2026-09-05: it fails on the COMMITTED llama_top.vhd, not merely on
# a working tree, so this is not a local accident.  It broke at `5f1db1a`
# ("B_STATE_AXI: wire the state tier into llama_top"), which added
# `gen_st_flat` and `gen_st_tier` INSIDE `gb_real`.  Nothing caught it because
# this script had no `--check` and no gate row, so `rtl/ooc_gdnadapt*_top.vhd`
# froze at `e9beec9` while `llama_top` moved on FIVE commits -- and B's mover
# timing was measured against that frozen copy.
#
# CORRECTION, same day, and it matters: the breakage was NOT silent.  Run
# against any llama_top from `5f1db1a` onward this script exits 1 saying
# exactly what is wrong.  It failed LOUDLY and was never heard, because
# nothing invoked it.  A comment claiming a feature is absent also becomes a
# lie the moment the feature lands, which is what this paragraph was until it
# was corrected: `--check` exists now, and `sim:gdnstale` is its gate row.
#
# Also accepts the LABELLED form, which this file uses (`end generate
# gen_st_tier;`), because an unlabelled-only pattern is the same bug again.
END_RE   = re.compile(r"^\s*end generate(\s+\w+)?\s*;\s*$")

PROLOGUE = """\
-- {ent}_top.vhd -- GENERATED by sim/ooc_gdnadapt_extract.py.
-- DO NOT EDIT.  The body below is `rtl/llama_top.vhd`'s `gb_real` generate
-- block, subsystem B's data mover, copied verbatim from {src}.
--
-- THE SEAM IS FLATTENED, AND IT HAS TO BE.  `llama_top` declares `nat_u`,
-- `sig_u` and `qexp_t` as ARCHITECTURE-local types whose bounds depend on its
-- own generics (`nat_u` is `array (0 to NPORT-1)` and `NPORT = NUNIT + NVOP`).
-- A type like that cannot appear on an entity's port list: the port list is
-- elaborated before the generics are known.  So the region-file ports below
-- are `std_logic_vector`, the block keeps the exact `nat_u`/`sig_u` signals it
-- was written against as architecture-local declarations, and a conversion
-- block joins the two.  The BLOCK TEXT IS STILL VERBATIM -- the conversion is
-- outside it.
--
-- Everything else the block reads from `llama_top`'s enclosing scope is
-- declared here with the same name and the same type.
--
-- WHAT THIS IS NOT.  It is not a routability result, it is not `llama_top`,
-- and it is NOT a claim that B can run a token.  It is one generate block
-- synthesised alone.
--
-- UPDATED 2026-09-05.  This notice used to say `llama_top` "still refuses
-- B_SRC_REAL past token 0 because the conv tap history is not wired to it".
-- The history IS wired now: `gdn_state_store`'s tap face supplies the KCONV-1
-- older columns and `tok_adv` rotates them, so the refusal was narrowed to
-- B_SRC_REAL WITHOUT B_STATE_AXI, where the history has nowhere to live.
-- That wiring is MEASURED to change the result (hash(R_X) 26934 wired against
-- 10998 zero-filled) and is NOT verified against a value oracle, so it is
-- still not a claim that B can run a token -- just a different reason.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

use work.util_pkg.all;
use work.model_cfg_pkg.all;
use work.llama_map_pkg.all;

entity {ent} is
  generic(
    SHAPE       : shape_t  := mk_shape(QWEN35_9B, 1);
    MANT_W      : positive := 16;
    EXP_W       : positive := 16;
    EPOCH_W     : positive := 4;
    NVOP        : positive := 3;
    C_MAXPOS    : positive := 4;
    STRICT      : boolean  := true;
    B_BEHAV     : boolean  := false;
    B_SRC_REAL  : boolean  := false;
    B_CONV_LANES  : positive := 4;
    B_RECUR_LANES : positive := 4;
    B_RECUR_SLOTS : positive := 16;
    B_L2_LANES    : positive := 4;
    B_SILU_LANES  : positive := 8;
    B_RMS_LANES   : positive := 4;
    -- Flattened-port widths.  Defaults cover the 9B region file
    -- (`region_max` is 12288 today, 17408 at 27B) and NREGION.
    AW          : positive := 16;
    RW          : positive := 8;
    -- A_MAXROWS OVERRIDE, 0 meaning "use region_max(SHAPE)".
    --
    -- It exists because the block declares `zb` and `yb` as process VARIABLES
    -- of `buf_t(0 to A_MAXROWS-1)`, and at the 9B shape that is 12,288 x 16
    -- bits EACH.  Synthesis of the extracted block at the default shape fails:
    --   ERROR: [Synth 8-3391] Unable to infer a block/distributed RAM for
    --   'gb_real.bp.zb_reg' because the memory pattern used is not supported
    -- and Vivado then terminates abnormally (signal 11).  This generic is the
    -- control that separates "the block is unsynthesisable" from "the block is
    -- unsynthesisable AT THIS SIZE", which are different findings.
    MAXROWS_OVR : natural := 0
  );
  port(
    clk : in std_logic;
    rst : in std_logic;
{ssports}
    -- D's job fields, and the unit handshake back to it
    job_issue    : in  std_logic;
    job_unit     : in  unsigned(2 downto 0);
    job_dst      : in  unsigned(7 downto 0);
    job_n_rows   : in  unsigned(31 downto 0);
    job_epoch    : in  unsigned(EPOCH_W-1 downto 0);
    job_ordinal  : in  unsigned(7 downto 0);
    u_ack_b      : in  std_logic;
    u_ready_b    : out std_logic;
    u_done_b     : out std_logic;
    u_err_b      : out std_logic;
    u_done_epoch_b : out std_logic_vector(EPOCH_W-1 downto 0);
    u_y_exp_b      : out std_logic_vector(EXP_W-1 downto 0);

    -- The region file's element ports, subsystem B's slot only.  THIS is the
    -- data movement.  Only slot U_B is brought out: the block drives no other.
    el_rdata  : in  signed(MANT_W-1 downto 0);
    ur_en_b   : out std_logic;
    ur_reg_b  : out std_logic_vector(RW-1 downto 0);
    ur_addr_b : out std_logic_vector(AW-1 downto 0);
    uw_en_b   : out std_logic;
    uw_reg_b  : out std_logic_vector(RW-1 downto 0);
    uw_addr_b : out std_logic_vector(AW-1 downto 0);
    uw_data_b : out std_logic_vector(MANT_W-1 downto 0);

    -- B's own exponent plumbing and the token position
    b_seq_rst    : in  std_logic;
    exp_rd_data  : in  signed(EXP_W-1 downto 0);
    exp_rd_valid : in  std_logic;
    qkv_exp_0    : in  signed(7 downto 0);
    qkv_exp_1    : in  signed(7 downto 0);
    qkv_exp_2    : in  signed(7 downto 0);
    tok_pos      : in  natural range 0 to C_MAXPOS-1;
    b_exp_region : out unsigned(7 downto 0);
    b_exp_seg    : out unsigned(1 downto 0);
    f_lost_b     : out std_logic
  );
end entity;

architecture rtl of {ent} is
  -- Declared with the same names and types `llama_top` gives them, so the
  -- block text below needs no edit.  Line numbers are where each lives in
  -- llama_top.vhd at the time of extraction.
  constant NPORT     : natural  := NUNIT + NVOP;               -- :1092
  -- A conditional expression is not legal in a constant declaration, so the
  -- override goes through a function.
  function pick_maxrows return positive is
  begin
    if MAXROWS_OVR = 0 then return region_max(SHAPE); end if;
    return MAXROWS_OVR;
  end function;
  constant A_MAXROWS : positive := pick_maxrows;               -- :1206
  type qexp_t is array (0 to 2) of signed(7 downto 0);         -- :1029
  type buf_t  is array (natural range <>) of signed(MANT_W-1 downto 0); -- :1083
  type nat_u  is array (0 to NPORT-1) of natural;              -- :1093
  type sig_u  is array (0 to NPORT-1) of signed(MANT_W-1 downto 0); -- :1094

  signal ur_en   : std_logic_vector(NPORT-1 downto 0) := (others => '0');
  signal ur_reg  : nat_u := (others => 0);
  signal ur_addr : nat_u := (others => 0);
  signal uw_en   : std_logic_vector(NPORT-1 downto 0) := (others => '0');
  signal uw_reg  : nat_u := (others => 0);
  signal uw_addr : nat_u := (others => 0);
  signal uw_data : sig_u := (others => (others => '0'));

  signal u_ready      : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal u_done       : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal u_err        : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal u_ack        : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal u_done_epoch : std_logic_vector(NUNIT*EPOCH_W-1 downto 0)
                      := (others => '0');
  signal u_y_exp      : std_logic_vector(NUNIT*EXP_W-1 downto 0)
                      := (others => '0');
  signal qkv_exp      : qexp_t := (others => (others => '0'));
begin
  -- ==== the flattening, OUTSIDE the verbatim block ====================
  -- Only slot U_B crosses the boundary because the block drives no other. A
  -- wider port would be tied to constants at every other index and Vivado
  -- would optimise the whole array away, which is the failure
  -- hw/fk33/gen_compose4_top.py:930 records for the region file.
  u_ack(U_B)   <= u_ack_b;
  u_ready_b    <= u_ready(U_B);
  u_done_b     <= u_done(U_B);
  u_err_b      <= u_err(U_B);
  u_done_epoch_b <= u_done_epoch((U_B+1)*EPOCH_W-1 downto U_B*EPOCH_W);
  u_y_exp_b      <= u_y_exp((U_B+1)*EXP_W-1 downto U_B*EXP_W);

  ur_en_b   <= ur_en(U_B);
  ur_reg_b  <= std_logic_vector(to_unsigned(ur_reg(U_B), RW));
  ur_addr_b <= std_logic_vector(to_unsigned(ur_addr(U_B), AW));
  uw_en_b   <= uw_en(U_B);
  uw_reg_b  <= std_logic_vector(to_unsigned(uw_reg(U_B), RW));
  uw_addr_b <= std_logic_vector(to_unsigned(uw_addr(U_B), AW));
  uw_data_b <= std_logic_vector(uw_data(U_B));

  qkv_exp(0) <= qkv_exp_0;
  qkv_exp(1) <= qkv_exp_1;
  qkv_exp(2) <= qkv_exp_2;

"""

SSPORTS = "\n    -- ---- gdn_state_store's face, brought to the top ----------------------\n    -- These exist ONLY in --state-store mode.  They are real ports rather\n    -- than tied-off signals so that nothing inside the store can be trimmed\n    -- as constant-driven: every store input comes from a port and every\n    -- store output drives one.  A DONT_TOUCH would preserve the instance but\n    -- not, reliably, its internals.\n    ss_load_start : in  std_logic;\n    ss_save_start : in  std_logic;\n    ss_layer      : in  integer range 0 to n_gdn_blocks(SHAPE)-1;\n    ss_state_base : in  std_logic_vector(32 downto 0);\n    ss_busy       : out std_logic;\n    ss_done       : out std_logic;\n    ss_err        : out std_logic;\n    ss_arvalid : out std_logic;\n    ss_arready : in  std_logic;\n    ss_araddr  : out std_logic_vector(32 downto 0);\n    ss_arlen   : out std_logic_vector(7 downto 0);\n    ss_arsize  : out std_logic_vector(2 downto 0);\n    ss_arburst : out std_logic_vector(1 downto 0);\n    ss_rvalid  : in  std_logic;\n    ss_rready  : out std_logic;\n    ss_rdata   : in  std_logic_vector(255 downto 0);\n    ss_rlast   : in  std_logic;\n    ss_rresp   : in  std_logic_vector(1 downto 0);\n    ss_awvalid : out std_logic;\n    ss_awready : in  std_logic;\n    ss_awaddr  : out std_logic_vector(32 downto 0);\n    ss_awlen   : out std_logic_vector(7 downto 0);\n    ss_awsize  : out std_logic_vector(2 downto 0);\n    ss_awburst : out std_logic_vector(1 downto 0);\n    ss_wvalid  : out std_logic;\n    ss_wready  : in  std_logic;\n    ss_wdata   : out std_logic_vector(255 downto 0);\n    ss_wstrb   : out std_logic_vector(31 downto 0);\n    ss_wlast   : out std_logic;\n    ss_bvalid  : in  std_logic;\n    ss_bready  : out std_logic;\n    ss_bresp   : in  std_logic_vector(1 downto 0);\n"

SS_START = '    -- ---- memory 1: the recurrent state.  Registered, one cycle. ---------\n'
SS_END = '    -- ---- memory 3: conv taps and weights.  Registered ADDRESS, ---------\n'
SS_SEMEM = "    signal semem : semem_t := (others => (others => '0'));\n"
SS_REPL = '    -- ---- memories 1 and 2: ONE resident layer in gdn_state_store --------\n    -- SUBSTITUTED by sim/ooc_gdnadapt_extract.py --state-store.  Everything\n    -- between this comment and "memory 3" below is NOT the verbatim block.\n    --\n    -- What it replaces held all NLY layers at once: `stmem_t` is\n    -- `NLY*STLY x B_RECUR_LANES*16`, and Vivado\'s own RAM inference table\n    -- names it as 3072 K x 64 = 24.0 MiB = 5472 RAMB36 on a 672-tile part.\n    -- docs/debugging/2026-09-03_b-mover-does-not-fit.md.\n    --\n    -- `gdn_state_store`\'s st_*/se_* ports are `gdn_block`\'s verbatim, so this\n    -- is a drop-in for BOTH processes.  Its conv-tap face is NOT used: this\n    -- block has its own taps (memory 3 below), so cv_*/cvw_*/tok_adv are tied\n    -- off.  In the real integration those would be the store\'s instead, and\n    -- memory 3 would go too, so this measurement OVERSTATES the final area by\n    -- one tap memory rather than understating it.\n    u_state : entity work.gdn_state_store\n      generic map(VAL_HEADS => VH, DIM => DM, RECUR_LANES => B_RECUR_LANES,\n                  LAYERS => NLY, KEY_HEADS => KH, KCONV => KC,\n                  CONV_LANES => B_CONV_LANES)\n      port map(\n        clk => clk, rst => rst,\n        load_start => ss_load_start, save_start => ss_save_start,\n        layer => ss_layer, state_base => ss_state_base,\n        busy => ss_busy, done => ss_done, err => ss_err,\n        st_ren => st_ren, st_rhead => st_rhead, st_rcol => st_rcol,\n        st_rgrp => st_rgrp, st_rdata => st_rdata,\n        st_wen => st_wen, st_whead => st_whead, st_wcol => st_wcol,\n        st_wgrp => st_wgrp, st_wdata => st_wdata,\n        se_rhead => se_rhead, se_rcol => se_rcol, se_rdata => se_rdata,\n        se_wen => se_wen, se_whead => se_whead, se_wcol => se_wcol,\n        se_wdata => se_wdata,\n        cv_seg => 0, cv_grp => 0, cv_x => open,\n        cvw_en => \'0\', cvw_seg => 0, cvw_grp => 0,\n        cvw_data => (others => \'0\'), tok_adv => \'0\',\n        r_arvalid => ss_arvalid, r_arready => ss_arready,\n        r_araddr => ss_araddr, r_arlen => ss_arlen,\n        r_arsize => ss_arsize, r_arburst => ss_arburst,\n        r_rvalid => ss_rvalid, r_rready => ss_rready,\n        r_rdata => ss_rdata, r_rlast => ss_rlast, r_rresp => ss_rresp,\n        w_awvalid => ss_awvalid, w_awready => ss_awready,\n        w_awaddr => ss_awaddr, w_awlen => ss_awlen,\n        w_awsize => ss_awsize, w_awburst => ss_awburst,\n        w_wvalid => ss_wvalid, w_wready => ss_wready,\n        w_wdata => ss_wdata, w_wstrb => ss_wstrb, w_wlast => ss_wlast,\n        w_bvalid => ss_bvalid, w_bready => ss_bready, w_bresp => ss_bresp);\n\n'


def substitute_state_store(body):
    """Replace gb_real's memory 1 and memory 2 with a gdn_state_store instance.

    EVERY anchor is required to appear EXACTLY ONCE and the function dies
    otherwise.  A substitution that silently matches zero times would emit the
    UNCHANGED block and report a saving of zero, which reads exactly like a
    real negative result -- that is the failure mode this guards.
    """
    for name, anc in (("SS_START", SS_START), ("SS_END", SS_END),
                      ("SS_SEMEM", SS_SEMEM)):
        n = body.count(anc)
        if n != 1:
            sys.exit("ooc_gdnadapt_extract: --state-store anchor %s matched %d "
                     "times, expected exactly 1.  The block changed; fix the "
                     "anchor rather than loosening it." % (name, n))
    i = body.index(SS_START)
    j = body.index(SS_END)
    if j <= i:
        sys.exit("ooc_gdnadapt_extract: --state-store: memory 3 precedes "
                 "memory 1, which means the anchors matched the wrong text.")
    body = body[:i] + SS_REPL + body[j:]
    # `semem` is now neither written nor read.  Left in place it is a 98304 x 8
    # initialised array that synthesis is free to infer as a ROM, so it goes.
    body = body.replace(SS_SEMEM, "")
    return body


EPILOGUE = """
end architecture;
"""


USAGE = "\n".join(l for l in __doc__.strip().splitlines()
                  if l.startswith("usage:") or l.startswith("       ")
                  or l.startswith("         "))


# THE CANONICAL OUTPUTS.  `--check` with no `out` argument checks every row
# here.  Keep this table and `sim/regress.sh`'s `gdnstale` row in step; the
# row is `--check <llama_top>` and nothing else, so adding a row here is the
# whole cost of gating another variant.
CANONICAL = (
    ("rtl/ooc_gdnadapt_top.vhd",    "ooc_gdnadapt",    False),
    ("rtl/ooc_gdnadapt_ss_top.vhd", "ooc_gdnadapt_ss", True),
)


def emit(src, ent, state_store):
    """Return the generated text for one variant.  Raises SystemExit on a
    seam the extractor cannot resolve, which is the LOUD failure that went
    unheard between 5f1db1a and 2026-09-05."""
    lines = open(src).read().split("\n")
    starts = [i for i, l in enumerate(lines) if START_RE.match(l)]
    if len(starts) != 1:
        sys.exit("ooc_gdnadapt_extract: the `gb_real` anchor matched %d times, "
                 "expected exactly 1.  The block moved or was renamed; fix the "
                 "anchor rather than loosening it." % len(starts))
    i = starts[0]
    depth = 0
    end = None
    for j in range(i, len(lines)):
        t = lines[j].strip()
        if re.search(r"\bgenerate\s*$", t) and not t.startswith("end"):
            depth += 1
        elif END_RE.match(lines[j]):
            depth -= 1
            if depth == 0:
                end = j
                break
    if end is None:
        sys.exit("ooc_gdnadapt_extract: no matching `end generate;` for gb_real")
    body = "\n".join(lines[i:end + 1])
    if state_store:
        body = substitute_state_store(body)
    text = (PROLOGUE.format(ent=ent, src=src,
                            ssports=SSPORTS if state_store else "")
            + body + EPILOGUE.format(ent=ent))
    return text, i, end


def check_one(src, out, ent, state_store):
    """0 if `out` is exactly what the generator emits, else 1.  Prints a
    verdict line either way so a gate row's tail is a sentence and not an
    empty log."""
    text, _, _ = emit(src, ent, state_store)
    try:
        have = open(out).read()
    except OSError as e:
        print("GDNADAPT_STALE cannot read %s: %s" % (out, e))
        return 1
    if have == text:
        print("GDNADAPT_CHECK ok %s (%d bytes)" % (out, len(text)))
        return 0
    import difflib
    d = list(difflib.unified_diff(have.splitlines(), text.splitlines(),
                                  "committed", "regenerated", lineterm=""))
    print("GDNADAPT_STALE %s differs from what the generator emits "
          "(%d diff lines)" % (out, len(d)))
    for l in d[:40]:
        print("  " + l)
    return 1


def main(argv):
    argv = list(argv)
    # --check: regenerate in memory and DIFF against the committed file rather
    # than overwriting it.  Nonzero exit if stale.
    #
    # WHY THIS EXISTS.  Without it this script had no way to be wrong out loud.
    # MEASURED 2026-09-05: it had been DEAD since `5f1db1a` (nested generates
    # inside `gb_real` broke the depth count), so `rtl/ooc_gdnadapt*_top.vhd`
    # froze at `e9beec9` while `llama_top` moved on FIVE commits -- and B's
    # mover timing, the project's headline blocker, was measured against that
    # frozen copy.  Nothing caught it because nothing ran it.  Same shape as
    # the `compose4_top` staleness, which was wrong since `11bf64b` and
    # surfaced only by luck.
    #
    # TWO FORMS, and the argument-less one is what the gate uses:
    #
    #   --check <llama_top.vhd>                 both canonical outputs
    #   --check [--state-store] <src> <out> ENT one named output, ad hoc
    #
    # The gate form takes no `out` BECAUSE `run_selfcheck` in sim/regress.sh
    # runs its command unquoted and not through a shell:
    #
    #     timeout -k 5 "$TIMEOUT" ${SELFCHECK_CMD[$tb]}
    #
    # so a chained `a && b` hands `&&` to argv, `ent = argv[3]` ignores the
    # tail, and the row would check ONLY the first file and pass -- a guard
    # passing for the wrong reason, built in at installation rather than in
    # the check.  One process, no shell metacharacters, no way to half-run.
    check = "--check" in argv
    if check:
        argv.remove("--check")
    state_store = "--state-store" in argv
    if state_store:
        argv.remove("--state-store")

    if check and len(argv) == 2:
        # repo root is this file's parent's parent: <repo>/sim/<this>
        import os
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        src = argv[1]
        rc = 0
        for rel, ent, ss in CANONICAL:
            rc |= check_one(src, os.path.join(root, rel), ent, ss)
        print("GDNADAPT_CHECK %s (%d outputs)"
              % ("ok" if rc == 0 else "STALE", len(CANONICAL)))
        return rc

    if len(argv) < 3:
        sys.exit(USAGE)
    src, out = argv[1], argv[2]
    ent = argv[3] if len(argv) > 3 else "ooc_gdnadapt"

    if check:
        return check_one(src, out, ent, state_store)

    text, i, end = emit(src, ent, state_store)
    open(out, "w").write(text)
    sys.stderr.write("ooc_gdnadapt_extract: wrote %s, block lines %d..%d (%d lines)\n"
                     % (out, i + 1, end + 1, end - i + 1))
    return 0


if __name__ == "__main__":
    # PROPAGATE the return value.  `main(sys.argv)` alone discards it, so
    # --check would exit 0 whether the file was stale or not -- a gate row on
    # that is decoration, not a check.
    sys.exit(main(sys.argv))
