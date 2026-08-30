#!/usr/bin/env python3
"""Emit the ACCEPT / REFUSE case suite that sim/mutate_mv4i_desc.sh drives
rtl/matvec_int4_desc_axi.vhd with, through sim/tb_mv4i_desc_image.vhd.

WHY A SEPARATE FILE AND NOT tools/gen_mv4i_desc.py.  That generator builds a
descriptor for a REAL packed tensor and needs the 4.7 GiB model set, which is
not in git; it is also the thing sim/tb_mv4i_desc_image.vhd exists to judge, so
using it to produce the cases that judge the JUDGE would make the two agree by
construction.  This file starts from the COMMITTED image sim/mv4i_desc_image.txt
and edits named 64-bit words of it.  Every case is therefore one edit away from
bytes the gateware is already known to accept, which is what makes the verdict
attributable to that edit.

THE CASE SUITE IS THE MEASURING INSTRUMENT, NOT THE MUTATIONS.  A mutation of
the RTL is only observable through a case whose expected verdict it moves.  So
the suite is built around the accept/refuse BOUNDARY:

  * one ACCEPT case per legal extreme (n_rows = 1, = ROWS_IF, = MAXROWS_BFP,
    n_cols = BLK, = MAXCOLS, a shape that is a multiple of neither), because a
    check made one too tight shows ONLY at the extreme it now excludes, and
  * one REFUSE case per check in S_CHECK / S_SHAPE_C / S_IDLE / bchk, each
    pinned to its err_code AND its ERR_INFO, because "refused" and "refused for
    the right reason" are different claims and several checks in this design
    share an err_code.

ERR_INFO IS PINNED ON EVERY REFUSE CASE.  It is the only thing separating, for
instance, the reserved-word-7 refusal from the out_mode refusal: both are
EC_DESC = 3 and they differ only in ERR_INFO (7 against 3).  Two pairs remain
indistinguishable even so and are named in the docstring of `cases()` below;
that is a property of the design, not of this file.

Usage:  python3 sim/mv4i_desc_cases.py <outdir>
Writes  <outdir>/<name>.hex  and  <outdir>/cases.tsv
        cases.tsv: name <TAB> ghdl generic arguments <TAB> one-line note
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "mv4i_desc_image.txt")

# The FK33 build these cases are written against.  They are RESTATED here
# rather than imported so that a build whose geometry moved makes the cases
# fail loudly at the bench's CAPS assert instead of silently retargeting.
ROWS_IF = 48
BLK = 32
NPW = 24
NPS = 3
AXI_DW = 256
ADDR_W = 40
MAXROWS_BFP = 17408
MAXCOLS = 17408
DESC_BASE0 = 8
EXT0 = DESC_BASE0 + NPW + NPS          # 35
DWORDS = EXT0 + 4                      # 39
W0 = DESC_BASE0                        # first weight base word,  8
WLAST = DESC_BASE0 + NPW - 1           # last  weight base word, 31
S0 = DESC_BASE0 + NPW                  # first scale  base word, 32
SLAST = DWORDS - 4 - 1                 # last  scale  base word, 34
GRP = (NPS * AXI_DW) // (ROWS_IF * 16)  # 1 at the FK33
DESC_ALIGN = 16 * (AXI_DW // 8)        # DESC_MAXB * bytes = 512

# err_code values, restated from rtl/matvec_int4_desc_pkg.vhd.
EC_DESC, EC_WDOG, EC_GEOM = 3, 4, 9
EC_MAGIC, EC_VER, EC_ALIGN, EC_ADDR, EC_SHAPE = 10, 11, 12, 13, 15
EI_PTR = 0xFFFF
ACCEPT = -1

# ERR_INFO's two fields, restated from rtl/matvec_int4_desc_pkg.vhd.  RESTATED
# and not imported for the same reason the geometry above is: a package whose
# split moved would then move this file's expectations with it and the cases
# would agree with the RTL by construction instead of by check.
EI_WORD_W = 11
EI_SUB_NONE = 0
EI_SUB_PTR = 31


def ei(sub, word):
    """The (sub-case, word index) pair as the 16-bit ERR_INFO the gateware
    reports.  Sub-case 0 leaves the value equal to the bare word index, which
    is what every case that names no sub-case still expects."""
    assert 0 <= sub <= 31 and 0 <= word < (1 << EI_WORD_W)
    return (sub << EI_WORD_W) | word


# Sub-cases, namespaced per err_code.  One name per `elsif` arm in
# rtl/matvec_int4_desc_axi.vhd.
ED_EXT_FLAGS, ED_OPCODE, ED_PAD_W3, ED_PAD_W7 = 1, 2, 3, 4
ED_PAD_EXT, ED_OUT_MODE = 5, 6
ED_ROWS_ZERO, ED_ROWS_MAX, ED_COLS_ZERO, ED_COLS_MAX = 7, 8, 9, 10
ED_WBEATS_ZERO, ED_SBEATS_ZERO, ED_CB_UNLOADED = 11, 12, 13
EG_NSUB_W, EG_NSUB_S = 1, 2
ES_WBEATS, ES_SBEATS_LO, ES_SBEATS_HI = 1, 2, 3


def load_golden():
    words = []
    with open(GOLDEN) as fp:
        for ln in fp:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            words.append(int(ln, 16))
    if len(words) != DWORDS:
        raise SystemExit("golden has %d words, expected %d"
                         % (len(words), DWORDS))
    return words


def shape(n_rows, n_cols):
    """(w_beats, s_beats) the design demands for this shape.  The SAME three
    lines rtl/matvec_int4_desc_axi.vhd's S_SHAPE computes by repeated addition
    -- written as a divide here on purpose, so that an error in the RTL's
    longhand multiply is not reproduced by the expectation."""
    tiles = -(-n_rows // ROWS_IF)
    nblk = -(-n_cols // BLK)
    wb = tiles * nblk
    sb = -(-wb // GRP)
    return wb, sb


def setfield(w, idx, lo, width, val):
    mask = ((1 << width) - 1) << lo
    w[idx] = (w[idx] & ~mask & 0xFFFFFFFFFFFFFFFF) | ((val & ((1 << width) - 1)) << lo)


def with_shape(w, n_rows, n_cols):
    """Set n_rows/n_cols AND the w_beats/s_beats they imply, together.  Setting
    one without the other produces an EC_SHAPE refusal that hides whatever the
    case was actually about, which is a trap this file hit twice."""
    wb, sb = shape(n_rows, n_cols)
    setfield(w, 1, 0, 32, n_rows)
    setfield(w, 1, 32, 32, n_cols)
    setfield(w, EXT0 + 1, 0, 32, wb)
    setfield(w, EXT0 + 1, 32, 32, sb)


# ---------------------------------------------------------------- the cases
def cases():
    """(name, edit, expect_code, expect_info, extra_generics, note).

    `edit` is a callable(words) applied to a fresh copy of the golden.
    expect_code ACCEPT (-1) means the design must START the core.

    NO TWO DISTINCT SITES SHARE AN (err_code, ERR_INFO) PAIR ANY MORE.  Until
    2026-08-29 they did, and this docstring named two of the collisions:

      * R_OPCODE and R_CBNEVER  -- both EC_DESC with ERR_INFO 0
      * R_W3PAD  and R_OUTMODE3 -- both EC_DESC with ERR_INFO 3

    MEASURED at 3d5cba9 by the `site` gate in main(), the real count was SIX,
    not two.  The four this file did not name were:

      * R_ROWS0 / R_ROWSOVER / R_COLS0 / R_COLSOVER -- all EC_DESC ERR_INFO 1
      * R_WBEATS0 and R_SBEATS0       -- both EC_DESC with ERR_INFO EXT0+1
      * R_XEXPPAD and R_EXT3PAD       -- both EC_DESC with ERR_INFO EXT0+2,
        which this file had already noticed and written down as a note on the
        case rather than as a defect
      * R_GEOM_NPW and R_GEOM_NPS     -- both EC_GEOM with ERR_INFO 3, the one
        collision that is not in the EC_DESC space at all

    That is the value of making the claim executable: the two that were
    hand-noticed were the two that a reader happened to look for, and the gate
    found three times as many in the same table.  OI-9's ERR_INFO subdivision
    (rtl/matvec_int4_desc_pkg.vhd) separates all six, and the `site` column
    below plus the gate in main() is what keeps them separated.

    Cases that DO share a pair share a SITE and say so explicitly: the same
    check reached by three magnitudes of misalignment, or by two out_mode
    values above the cap, is one diagnosis and must report one thing.
    """
    C = []

    def add(name, edit, code, info, gen="", note="", site=None):
        # `site` names the ONE arm of rtl/matvec_int4_desc_axi.vhd this case
        # must land on.  Several cases may share a site on purpose (three
        # magnitudes of the same misalignment, two out_mode values above the
        # cap); no two DIFFERENT sites may share an (err_code, ERR_INFO) pair.
        # main() enforces both directions, which is the whole acceptance test
        # for OI-9 and is what fires today at HEAD.
        C.append((name, edit, code, info, gen, note, site or name))

    def nop(w):
        pass

    # ------------------------------------------------------------- ACCEPT
    add("A_GOLDEN", nop, ACCEPT, -1, "-gEXPECT_EADDR=0",
        "the committed image, unedited: 100 rows x 4096 cols")
    add("A_ROWS1", lambda w: with_shape(w, 1, 4096), ACCEPT, -1, "",
        "n_rows = 1, the bottom of the legal range (tiles = 1)")
    add("A_ROWSEXACT", lambda w: with_shape(w, ROWS_IF, 4096), ACCEPT, -1, "",
        "n_rows = ROWS_IF exactly: ceil and floor agree here and nowhere else")
    add("A_ROWSMAX", lambda w: with_shape(w, MAXROWS_BFP, 4096), ACCEPT, -1, "",
        "n_rows = MAXROWS_BFP, the TOP of the legal range; a `>` made `>=` "
        "shows only here")
    add("A_ROWSMAXM1", lambda w: with_shape(w, MAXROWS_BFP - 1, 4096),
        ACCEPT, -1, "", "one below the top, so the top case is not alone")
    add("A_COLS1BLK", lambda w: with_shape(w, 100, BLK), ACCEPT, -1, "",
        "n_cols = BLK: nblk = 1, the bottom of the column range")
    add("A_COLSMAX", lambda w: with_shape(w, 100, MAXCOLS), ACCEPT, -1, "",
        "n_cols = MAXCOLS, the top of the column range")
    add("A_RAGGED", lambda w: with_shape(w, 49, 4097), ACCEPT, -1, "",
        "a shape that is a multiple of NEITHER ROWS_IF nor BLK")
    add("A_MODE1", lambda w: setfield(w, 3, 0, 8, 1), ACCEPT, -1, "",
        "out_mode 1 accepted")
    add("A_MODE2", lambda w: setfield(w, 3, 0, 8, 2), ACCEPT, -1, "",
        "out_mode 2 accepted (the top of the legal out_mode range)")
    add("A_DSTOFF", lambda w: setfield(w, 0, 32, 32, 0xDEADBEEF), ACCEPT, -1,
        "", "word 0's dst_offset is D's field and A does NOT check it")
    add("A_SRCREG2", lambda w: setfield(w, 3, 48, 8, 0x00), ACCEPT, -1, "",
        "word 3's src_region2 is D's field and A does NOT check it")
    add("A_ORDINAL", lambda w: setfield(w, 3, 8, 8, 0x7F), ACCEPT, -1, "",
        "word 3's ordinal is D's field and A does NOT check it")
    add("A_STALL", nop, ACCEPT, -1, "-gDSLV_STALL=1000",
        "a slave that answers 1000 cycles late is still inside WDOG_LIMIT")
    add("A_STALL_WDOG", nop, ACCEPT, -1, "-gDSLV_STALL=10000",
        "a slave 10,000 cycles late is STILL inside WDOG_LIMIT = 65,536.  "
        "This is the case that separates a watchdog that has been REMOVED "
        "from one that has been made SMALLER: W_DEAD kills the first and "
        "only a legal stall longer than the shrunken limit kills the second")

    # -------------------------------------------- REFUSE: the extension header
    add("R_MAGIC", lambda w: setfield(w, EXT0, 0, 32, 0x4D563448),
        EC_MAGIC, ei(EI_SUB_NONE, EXT0), "",
        "extension magic wrong by one bit")
    add("R_VER", lambda w: setfield(w, EXT0, 32, 16, 2),
        EC_VER, ei(EI_SUB_NONE, EXT0), "",
        "extension version 2, this build speaks 1")
    add("R_EXTFLAGS", lambda w: setfield(w, EXT0, 48, 16, 1),
        EC_DESC, ei(ED_EXT_FLAGS, EXT0), "",
        "extension ext_flags reserved bits set")
    add("R_MAGIC_AND_OP",
        lambda w: (setfield(w, EXT0, 0, 32, 0x4D563448),
                   setfield(w, 0, 0, 8, 1)),
        EC_MAGIC, ei(EI_SUB_NONE, EXT0), "",
        "magic AND opcode both wrong: FIRST MATCH WINS, so magic",
        site="R_MAGIC")

    # ------------------------------------------------- REFUSE: D's header
    add("R_GEOM_NPW", lambda w: setfield(w, 3, 16, 16, NPW - 1),
        EC_GEOM, ei(EG_NSUB_W, 3), "",
        "descriptor claims one fewer weight sub-region")
    add("R_GEOM_NPS", lambda w: setfield(w, 3, 32, 16, NPS - 1),
        EC_GEOM, ei(EG_NSUB_S, 3), "",
        "descriptor claims one fewer scale sub-region.  Shared (9,3) with "
        "R_GEOM_NPW until 2026-08-29")
    add("R_OPCODE", lambda w: setfield(w, 0, 0, 8, 1),
        EC_DESC, ei(ED_OPCODE, 0), "",
        "opcode is not OP_A_JOB.  Shared (3,0) with R_CBNEVER until 2026-08-29")
    add("R_W3PAD", lambda w: setfield(w, 3, 56, 8, 1),
        EC_DESC, ei(ED_PAD_W3, 3), "",
        "word 3's pad set.  Shared (3,3) with R_OUTMODE3 until 2026-08-29")
    add("R_GEOM_BOTH",
        lambda w: (setfield(w, 3, 16, 16, NPW - 1),
                   setfield(w, 3, 32, 16, NPS - 1)),
        EC_GEOM, ei(EG_NSUB_W, 3), "",
        "BOTH sub-region counts wrong: nsub_w is checked first",
        site="R_GEOM_NPW")
    add("R_W7PAD", lambda w: w.__setitem__(7, 1),
        EC_DESC, ei(ED_PAD_W7, 7), "",
        "word 7, D's reserved word, is nonzero")
    add("R_XEXPPAD", lambda w: setfield(w, EXT0 + 2, 32, 32, 1),
        EC_DESC, ei(ED_PAD_EXT, EXT0 + 2), "",
        "the x_exp word's high half is not pad", site="R_PAD_EXT2")
    add("R_EXT3PAD", lambda w: w.__setitem__(EXT0 + 3, 1),
        EC_DESC, ei(ED_PAD_EXT, EXT0 + 3), "",
        "the last extension word is not zero.  ERR_INFO used to name EXT0+2 "
        "for this, which was the wrong word; it now names EXT0+3",
        site="R_PAD_EXT3")
    add("R_OUTMODE3", lambda w: setfield(w, 3, 0, 8, 3),
        EC_DESC, ei(ED_OUT_MODE, 3), "",
        "out_mode 3.  Shared (3,3) with R_W3PAD until 2026-08-29",
        site="R_OUTMODE")
    add("R_OUTMODE255", lambda w: setfield(w, 3, 0, 8, 255),
        EC_DESC, ei(ED_OUT_MODE, 3), "",
        "out_mode 255, the top of the byte: the SAME site as R_OUTMODE3, so "
        "the same report is correct here", site="R_OUTMODE")

    add("R_PAD_EXT_BOTH",
        lambda w: (setfield(w, EXT0 + 2, 32, 32, 1),
                   w.__setitem__(EXT0 + 3, 1)),
        EC_DESC, ei(ED_PAD_EXT, EXT0 + 2), "",
        "BOTH extension pads nonzero: EXT0+2 is checked first, so ONE "
        "sub-case with TWO word indices still names one word",
        site="R_PAD_EXT2")

    # --------------------------------------------------- REFUSE: the shape
    add("R_ROWS0", lambda w: setfield(w, 1, 0, 32, 0),
        EC_DESC, ei(ED_ROWS_ZERO, 1), "", "n_rows = 0")
    add("R_ROWSOVER", lambda w: setfield(w, 1, 0, 32, MAXROWS_BFP + 1),
        EC_DESC, ei(ED_ROWS_MAX, 1), "",
        "n_rows = MAXROWS_BFP + 1, one past the top")
    add("R_COLS0", lambda w: setfield(w, 1, 32, 32, 0),
        EC_DESC, ei(ED_COLS_ZERO, 1), "", "n_cols = 0")
    add("R_COLSOVER", lambda w: setfield(w, 1, 32, 32, MAXCOLS + 1),
        EC_DESC, ei(ED_COLS_MAX, 1), "",
        "n_cols = MAXCOLS + 1, one past the top")
    add("R_ROWSOVER_AND_BASE",
        lambda w: (setfield(w, 1, 0, 32, MAXROWS_BFP + 1),
                   w.__setitem__(W0, w[W0] + 0x100)),
        EC_DESC, ei(ED_ROWS_MAX, 1), "",
        "n_rows out of range AND a misaligned base: the SHAPE check is first",
        site="R_ROWSOVER")
    add("R_SHAPE_ALLBAD",
        lambda w: (setfield(w, 1, 0, 32, 0), setfield(w, 1, 32, 32, 0)),
        EC_DESC, ei(ED_ROWS_ZERO, 1), "",
        "n_rows AND n_cols both zero: the ROWS arm is first",
        site="R_ROWS0")
    add("R_SHAPE_OVERBOTH",
        lambda w: (setfield(w, 1, 0, 32, MAXROWS_BFP + 1),
                   setfield(w, 1, 32, 32, MAXCOLS + 1)),
        EC_DESC, ei(ED_ROWS_MAX, 1), "",
        "both dimensions one past the top: the ROWS arm is first",
        site="R_ROWSOVER")
    add("R_WBEATS0", lambda w: setfield(w, EXT0 + 1, 0, 32, 0),
        EC_DESC, ei(ED_WBEATS_ZERO, EXT0 + 1), "", "w_beats = 0")
    add("R_SBEATS0", lambda w: setfield(w, EXT0 + 1, 32, 32, 0),
        EC_DESC, ei(ED_SBEATS_ZERO, EXT0 + 1), "",
        "s_beats = 0.  Shared (3,EXT0+1) with R_WBEATS0 until 2026-08-29")

    add("R_BEATS_BOTH0",
        lambda w: setfield(w, EXT0 + 1, 0, 64, 0),
        EC_DESC, ei(ED_WBEATS_ZERO, EXT0 + 1), "",
        "BOTH beat counts zero: the w_beats arm is first",
        site="R_WBEATS0")

    # ------------------------------------------------- REFUSE: the bases
    add("R_BASE_ADDR_W0", lambda w: w.__setitem__(W0, w[W0] | (1 << ADDR_W)),
        EC_ADDR, ei(EI_SUB_NONE, W0), "",
        "weight base 0 has a bit AT ADDR_W", site="R_BASE_ADDR_W0")
    add("R_BASE_ADDR_HI", lambda w: w.__setitem__(W0, w[W0] | (1 << 63)),
        EC_ADDR, ei(EI_SUB_NONE, W0), "",
        "weight base 0 has bit 63 set", site="R_BASE_ADDR_W0")
    add("R_BASE_ALIGN_W0", lambda w: w.__setitem__(W0, w[W0] + 0x100),
        EC_ALIGN, ei(EI_SUB_NONE, W0), "",
        "weight base 0 off a 4 KB boundary by 256 bytes", site="R_BASE_ALIGN_W0")
    add("R_BASE_ALIGN_2K", lambda w: w.__setitem__(W0, w[W0] + 0x800),
        EC_ALIGN, ei(EI_SUB_NONE, W0), "",
        "weight base 0 off by 2 KB: separates a 4 KB check from a 2 KB one",
        site="R_BASE_ALIGN_W0")
    add("R_BASE_ALIGN_1", lambda w: w.__setitem__(W0, w[W0] + 1),
        EC_ALIGN, ei(EI_SUB_NONE, W0), "",
        "weight base 0 off by ONE byte", site="R_BASE_ALIGN_W0")
    add("R_BASE_ALIGN_WLAST",
        lambda w: w.__setitem__(WLAST, w[WLAST] + 0x100),
        EC_ALIGN, ei(EI_SUB_NONE, WLAST), "",
        "the LAST weight base is misaligned")
    add("R_BASE_ADDR_S0", lambda w: w.__setitem__(S0, w[S0] | (1 << ADDR_W)),
        EC_ADDR, ei(EI_SUB_NONE, S0), "",
        "the first SCALE base is out of range")
    add("R_BASE_ALIGN_SLAST",
        lambda w: w.__setitem__(SLAST, w[SLAST] + 0x100),
        EC_ALIGN, ei(EI_SUB_NONE, SLAST), "",
        "the LAST scale base is misaligned: the loop must reach NP_ALL-1")
    add("R_BASE_BOTH",
        lambda w: w.__setitem__(W0, (w[W0] | (1 << ADDR_W)) + 0x100),
        EC_ADDR, ei(EI_SUB_NONE, W0), "",
        "one base BOTH out of range and misaligned: ADDR is checked first",
        site="R_BASE_ADDR_W0")
    add("R_BASE_ORDER",
        lambda w: (w.__setitem__(W0 + 1, w[W0 + 1] + 0x100),
                   w.__setitem__(W0 + 2, w[W0 + 2] | (1 << ADDR_W))),
        EC_ALIGN, ei(EI_SUB_NONE, W0 + 1), "",
        "base 1 misaligned, base 2 out of range: the LOWER index wins")

    # ------------------------------------------------- REFUSE: the codebook
    add("R_CBNEVER", lambda w: setfield(w, 0, 10, 1, 0),
        EC_DESC, ei(ED_CB_UNLOADED, 0), "",
        "cb_load clear and no codebook was ever loaded.  Shared (3,0) with "
        "R_OPCODE until 2026-08-29")

    # ------------------------------------------------- REFUSE: S_SHAPE_C
    add("R_WB_LOW", lambda w: setfield(w, EXT0 + 1, 0, 32, 383),
        EC_SHAPE, ei(ES_WBEATS, EXT0 + 1), "",
        "w_beats one BELOW tiles*nblk: this STARVES", site="R_SHAPE_WB")
    add("R_WB_HIGH", lambda w: setfield(w, EXT0 + 1, 0, 32, 385),
        EC_SHAPE, ei(ES_WBEATS, EXT0 + 1), "",
        "w_beats one ABOVE tiles*nblk", site="R_SHAPE_WB")
    add("R_SB_LOW", lambda w: setfield(w, EXT0 + 1, 32, 32, 383),
        EC_SHAPE, ei(ES_SBEATS_LO, EXT0 + 1), "",
        "s_beats one below ceil(w_beats/GRP)", site="R_SHAPE_SB_LO")
    add("R_SB_HIGH", lambda w: setfield(w, EXT0 + 1, 32, 32, 385),
        EC_SHAPE, ei(ES_SBEATS_HI, EXT0 + 1), "",
        "s_beats one above ceil(w_beats/GRP)", site="R_SHAPE_SB_HI")
    add("R_WB_TILEOFF",
        lambda w: setfield(w, EXT0 + 1, 0, 32, shape(100, 4096)[0] + 128),
        EC_SHAPE, ei(ES_WBEATS, EXT0 + 1), "",
        "w_beats for FOUR tiles when the shape says three: a ceil/floor error "
        "in the tile count lands exactly here", site="R_SHAPE_WB")
    add("R_SHAPE_TOP",
        lambda w: (with_shape(w, MAXROWS_BFP, 4096),
                   setfield(w, EXT0 + 1, 0, 32, shape(MAXROWS_BFP, 4096)[0] - 128)),
        EC_SHAPE, ei(ES_WBEATS, EXT0 + 1), "",
        "the same off-by-one-tile at the TOP of the row range",
        site="R_SHAPE_WB")

    # ------------------------------------------------ REFUSE: the pointer
    add("P_ALIGN", nop, EC_ALIGN, EI_PTR,   # = ei(EI_SUB_PTR, 2047)
        "-gDESC_ADDR=%d -gEXPECT_EADDR=0" % (0x300000 + 0x100),
        "DESC_PTR not a multiple of DESC_MAXB*AXI_DW/8 = %d" % DESC_ALIGN)
    add("P_ALIGN_HALF", nop, EC_ALIGN, EI_PTR,
        "-gDESC_ADDR=%d -gEXPECT_EADDR=0" % (0x300000 + DESC_ALIGN // 2),
        "DESC_PTR off by HALF the alignment: separates DESC_ALIGN from "
        "DESC_ALIGN/2", site="P_ALIGN")
    add("P_ADDR", nop, EC_ADDR, EI_PTR,
        "-gDESC_ADDR_HI=%d -gEXPECT_EADDR=1" % (1 << (ADDR_W - 32)),
        "DESC_PTR_HI has a bit AT ADDR_W: refused in S_IDLE *and* latched "
        "into STATUS bit 4 at write time, which are two different checks")
    # 1 << 30, not 1 << 31: a VHDL `natural` tops out at 2**31-1 and ghdl
    # refuses the generic override with an elaboration error, which the
    # classifier correctly reads as ABORT:ELAB and which looks exactly like a
    # broken design until the log is opened.
    add("P_ADDR_TOP", nop, EC_ADDR, EI_PTR,
        "-gDESC_ADDR_HI=%d -gEXPECT_EADDR=1" % (1 << 30),
        "DESC_PTR_HI bit 62 set, well above ADDR_W", site="P_ADDR")

    # --------------------------------------------------- REFUSE: watchdog
    add("W_DEAD", nop, EC_WDOG, EI_PTR, "-gDSLV_DEAD=true",
        "the descriptor slave never answers AR: only WDOG can end this")

    return C


def check_sites(C):
    """THE ACCEPTANCE TEST FOR OI-9, and the reason the `site` column exists.

    Two claims, and they pull in opposite directions so both have to be made:

      (1) every case tagged with a site expects the SAME (err_code, ERR_INFO)
          as every other case on that site -- one check, one diagnosis; and
      (2) no two DIFFERENT sites expect the SAME (err_code, ERR_INFO) -- a
          refusal names the check that raised it.

    (2) is the one that was false before 2026-08-29, at six pairs.  (1) is what
    stops the fix being "give every case its own number", which would separate
    the reports without separating the checks and would pass (2) vacuously.

    This runs at GENERATION time, on the expectations, so it is a statement
    about the table.  The bench then runs each case against the gateware and
    pins the pair, which is what makes it a statement about the RTL.  Neither
    half is worth anything alone.
    """
    by_site = {}
    by_pair = {}
    bad = []
    for name, _edit, code, info, _gen, _note, site in C:
        if code == ACCEPT:
            continue
        pair = (code, info)
        if site in by_site and by_site[site][0] != pair:
            bad.append("site %s: %s expects (%d,0x%04X) but %s expects "
                       "(%d,0x%04X) -- one check must give one diagnosis"
                       % (site, by_site[site][1], by_site[site][0][0],
                          by_site[site][0][1], name, code, info))
        by_site.setdefault(site, (pair, name))
        if pair in by_pair and by_pair[pair] != site:
            bad.append("(err_code %d, ERR_INFO 0x%04X) is reported by TWO "
                       "different sites, %s and %s -- a refusal there cannot "
                       "be attributed (OI-9)"
                       % (code, info, by_pair[pair], site))
        by_pair.setdefault(pair, site)
    return bad


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    out = sys.argv[1]
    if not os.path.isdir(out):
        os.makedirs(out)
    C = cases()
    bad = check_sites(C)
    if bad:
        for b in bad:
            sys.stderr.write("SITE GATE: %s\n" % b)
        raise SystemExit("%d (err_code, ERR_INFO) collisions -- refusing to "
                         "emit a suite that cannot attribute a refusal" % len(bad))
    golden = load_golden()
    rows = []
    for name, edit, code, info, gen, note, _site in C:
        w = list(golden)
        edit(w)
        if len(w) != DWORDS:
            raise SystemExit("%s changed the word count" % name)
        with open(os.path.join(out, name + ".hex"), "w") as fp:
            fp.write("# case %s: %s\n" % (name, note))
            for v in w:
                fp.write("%016X\n" % (v & 0xFFFFFFFFFFFFFFFF))
        args = "-gDESC=%s.hex -gEXPECT=%d -gEXPECT_INFO=%d" % (name, code, info)
        if gen:
            args += " " + gen
        rows.append("%s\t%s\t%s" % (name, args, note))
    with open(os.path.join(out, "cases.tsv"), "w") as fp:
        fp.write("\n".join(rows) + "\n")
    sys.stderr.write("%d cases written to %s; site gate: %d sites, no "
                     "(err_code, ERR_INFO) shared between two of them\n"
                     % (len(rows), out,
                        len(set(c[6] for c in C if c[2] != ACCEPT))))


if __name__ == "__main__":
    main()
