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

    TWO PAIRS ARE INDISTINGUISHABLE BY (err_code, ERR_INFO) AND ARE MARKED SO:
      * R_OPCODE and R_CBNEVER  -- both EC_DESC with ERR_INFO 0
      * R_W3PAD  and R_OUTMODE3 -- both EC_DESC with ERR_INFO 3
    Nothing this bench can read separates them, so a mutation that swaps one
    for the other is invisible here BY CONSTRUCTION.  Recorded rather than
    papered over: it is a resolution floor of the ERROR REPORTING, not of the
    harness.
    """
    C = []

    def add(name, edit, code, info, gen="", note=""):
        C.append((name, edit, code, info, gen, note))

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
        EC_MAGIC, EXT0, "", "extension magic wrong by one bit")
    add("R_VER", lambda w: setfield(w, EXT0, 32, 16, 2),
        EC_VER, EXT0, "", "extension version 2, this build speaks 1")
    add("R_EXTFLAGS", lambda w: setfield(w, EXT0, 48, 16, 1),
        EC_DESC, EXT0, "", "extension ext_flags reserved bits set")
    add("R_MAGIC_AND_OP",
        lambda w: (setfield(w, EXT0, 0, 32, 0x4D563448),
                   setfield(w, 0, 0, 8, 1)),
        EC_MAGIC, EXT0, "",
        "magic AND opcode both wrong: FIRST MATCH WINS, so magic")

    # ------------------------------------------------- REFUSE: D's header
    add("R_GEOM_NPW", lambda w: setfield(w, 3, 16, 16, NPW - 1),
        EC_GEOM, 3, "", "descriptor claims one fewer weight sub-region")
    add("R_GEOM_NPS", lambda w: setfield(w, 3, 32, 16, NPS - 1),
        EC_GEOM, 3, "", "descriptor claims one fewer scale sub-region")
    add("R_OPCODE", lambda w: setfield(w, 0, 0, 8, 1),
        EC_DESC, 0, "", "opcode is not OP_A_JOB (shares (3,0) with R_CBNEVER)")
    add("R_W3PAD", lambda w: setfield(w, 3, 56, 8, 1),
        EC_DESC, 3, "", "word 3's pad set (shares (3,3) with R_OUTMODE3)")
    add("R_W7PAD", lambda w: w.__setitem__(7, 1),
        EC_DESC, 7, "", "word 7, D's reserved word, is nonzero")
    add("R_XEXPPAD", lambda w: setfield(w, EXT0 + 2, 32, 32, 1),
        EC_DESC, EXT0 + 2, "", "the x_exp word's high half is not pad")
    add("R_EXT3PAD", lambda w: w.__setitem__(EXT0 + 3, 1),
        EC_DESC, EXT0 + 2, "",
        "the last extension word is not zero; ERR_INFO names EXT0+2, not +3")
    add("R_OUTMODE3", lambda w: setfield(w, 3, 0, 8, 3),
        EC_DESC, 3, "", "out_mode 3 (shares (3,3) with R_W3PAD)")
    add("R_OUTMODE255", lambda w: setfield(w, 3, 0, 8, 255),
        EC_DESC, 3, "", "out_mode 255, the top of the byte")

    # --------------------------------------------------- REFUSE: the shape
    add("R_ROWS0", lambda w: setfield(w, 1, 0, 32, 0),
        EC_DESC, 1, "", "n_rows = 0")
    add("R_ROWSOVER", lambda w: setfield(w, 1, 0, 32, MAXROWS_BFP + 1),
        EC_DESC, 1, "", "n_rows = MAXROWS_BFP + 1, one past the top")
    add("R_COLS0", lambda w: setfield(w, 1, 32, 32, 0),
        EC_DESC, 1, "", "n_cols = 0")
    add("R_COLSOVER", lambda w: setfield(w, 1, 32, 32, MAXCOLS + 1),
        EC_DESC, 1, "", "n_cols = MAXCOLS + 1, one past the top")
    add("R_ROWSOVER_AND_BASE",
        lambda w: (setfield(w, 1, 0, 32, MAXROWS_BFP + 1),
                   w.__setitem__(W0, w[W0] + 0x100)),
        EC_DESC, 1, "",
        "n_rows out of range AND a misaligned base: the SHAPE check is first")
    add("R_WBEATS0", lambda w: setfield(w, EXT0 + 1, 0, 32, 0),
        EC_DESC, EXT0 + 1, "", "w_beats = 0")
    add("R_SBEATS0", lambda w: setfield(w, EXT0 + 1, 32, 32, 0),
        EC_DESC, EXT0 + 1, "", "s_beats = 0")

    # ------------------------------------------------- REFUSE: the bases
    add("R_BASE_ADDR_W0", lambda w: w.__setitem__(W0, w[W0] | (1 << ADDR_W)),
        EC_ADDR, W0, "", "weight base 0 has a bit AT ADDR_W")
    add("R_BASE_ADDR_HI", lambda w: w.__setitem__(W0, w[W0] | (1 << 63)),
        EC_ADDR, W0, "", "weight base 0 has bit 63 set")
    add("R_BASE_ALIGN_W0", lambda w: w.__setitem__(W0, w[W0] + 0x100),
        EC_ALIGN, W0, "", "weight base 0 off a 4 KB boundary by 256 bytes")
    add("R_BASE_ALIGN_2K", lambda w: w.__setitem__(W0, w[W0] + 0x800),
        EC_ALIGN, W0, "",
        "weight base 0 off by 2 KB: separates a 4 KB check from a 2 KB one")
    add("R_BASE_ALIGN_1", lambda w: w.__setitem__(W0, w[W0] + 1),
        EC_ALIGN, W0, "", "weight base 0 off by ONE byte")
    add("R_BASE_ALIGN_WLAST",
        lambda w: w.__setitem__(WLAST, w[WLAST] + 0x100),
        EC_ALIGN, WLAST, "", "the LAST weight base is misaligned")
    add("R_BASE_ADDR_S0", lambda w: w.__setitem__(S0, w[S0] | (1 << ADDR_W)),
        EC_ADDR, S0, "", "the first SCALE base is out of range")
    add("R_BASE_ALIGN_SLAST",
        lambda w: w.__setitem__(SLAST, w[SLAST] + 0x100),
        EC_ALIGN, SLAST, "",
        "the LAST scale base is misaligned: the loop must reach NP_ALL-1")
    add("R_BASE_BOTH",
        lambda w: w.__setitem__(W0, (w[W0] | (1 << ADDR_W)) + 0x100),
        EC_ADDR, W0, "",
        "one base BOTH out of range and misaligned: ADDR is checked first")
    add("R_BASE_ORDER",
        lambda w: (w.__setitem__(W0 + 1, w[W0 + 1] + 0x100),
                   w.__setitem__(W0 + 2, w[W0 + 2] | (1 << ADDR_W))),
        EC_ALIGN, W0 + 1, "",
        "base 1 misaligned, base 2 out of range: the LOWER index wins")

    # ------------------------------------------------- REFUSE: the codebook
    add("R_CBNEVER", lambda w: setfield(w, 0, 10, 1, 0),
        EC_DESC, 0, "",
        "cb_load clear and no codebook was ever loaded (shares (3,0) with "
        "R_OPCODE)")

    # ------------------------------------------------- REFUSE: S_SHAPE_C
    add("R_WB_LOW", lambda w: setfield(w, EXT0 + 1, 0, 32, 383),
        EC_SHAPE, EXT0 + 1, "", "w_beats one BELOW tiles*nblk: this STARVES")
    add("R_WB_HIGH", lambda w: setfield(w, EXT0 + 1, 0, 32, 385),
        EC_SHAPE, EXT0 + 1, "", "w_beats one ABOVE tiles*nblk")
    add("R_SB_LOW", lambda w: setfield(w, EXT0 + 1, 32, 32, 383),
        EC_SHAPE, EXT0 + 1, "", "s_beats one below ceil(w_beats/GRP)")
    add("R_SB_HIGH", lambda w: setfield(w, EXT0 + 1, 32, 32, 385),
        EC_SHAPE, EXT0 + 1, "", "s_beats one above ceil(w_beats/GRP)")
    add("R_WB_TILEOFF",
        lambda w: setfield(w, EXT0 + 1, 0, 32, shape(100, 4096)[0] + 128),
        EC_SHAPE, EXT0 + 1, "",
        "w_beats for FOUR tiles when the shape says three: a ceil/floor error "
        "in the tile count lands exactly here")
    add("R_SHAPE_TOP",
        lambda w: (with_shape(w, MAXROWS_BFP, 4096),
                   setfield(w, EXT0 + 1, 0, 32, shape(MAXROWS_BFP, 4096)[0] - 128)),
        EC_SHAPE, EXT0 + 1, "",
        "the same off-by-one-tile at the TOP of the row range")

    # ------------------------------------------------ REFUSE: the pointer
    add("P_ALIGN", nop, EC_ALIGN, EI_PTR,
        "-gDESC_ADDR=%d -gEXPECT_EADDR=0" % (0x300000 + 0x100),
        "DESC_PTR not a multiple of DESC_MAXB*AXI_DW/8 = %d" % DESC_ALIGN)
    add("P_ALIGN_HALF", nop, EC_ALIGN, EI_PTR,
        "-gDESC_ADDR=%d -gEXPECT_EADDR=0" % (0x300000 + DESC_ALIGN // 2),
        "DESC_PTR off by HALF the alignment: separates DESC_ALIGN from "
        "DESC_ALIGN/2")
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
        "DESC_PTR_HI bit 62 set, well above ADDR_W")

    # --------------------------------------------------- REFUSE: watchdog
    add("W_DEAD", nop, EC_WDOG, EI_PTR, "-gDSLV_DEAD=true",
        "the descriptor slave never answers AR: only WDOG can end this")

    return C


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    out = sys.argv[1]
    if not os.path.isdir(out):
        os.makedirs(out)
    golden = load_golden()
    rows = []
    for name, edit, code, info, gen, note in cases():
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
    sys.stderr.write("%d cases written to %s\n" % (len(rows), out))


if __name__ == "__main__":
    main()
