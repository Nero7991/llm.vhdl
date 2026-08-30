#!/usr/bin/env python3
"""tools/gen_mv4i_desc.py -- emit subsystem A's in-memory descriptor for one
packed tensor, at the geometry that tensor was packed for.

Spec: docs/2026-08-28_matvec-descriptor-format.md
RTL:  rtl/matvec_int4_desc_axi.vhd, layout constants rtl/matvec_int4_desc_pkg.vhd

WHAT THIS CLOSES.  Worklog OI-4: the format is byte-pinned and the control
plane is bit-exact in simulation, and nothing anywhere emits a descriptor for a
real tensor.  This does, for ONE matvec job.  It is deliberately not a
transformer program: a layer-level program needs subsystems B, C and D wired
together and attn_kv_axi does not exist.

WHERE EVERY FIELD COMES FROM.  Three sources, and the split matters more than
the code:

  DERIVED FROM THE .mv4i HEADER (spec 6.4), which travels with the bytes:
      n_cols (= K), w_exp, out_shift, the 16-byte codebook, nsub_w (= nports_w),
      nsub_s (= n_scale_sub), and the sub-region byte offsets WITHIN the file.
  DERIVED FROM THE HEADER PLUS THE JOB'S n_rows:
      w_beats, s_beats.  The identity is written out at wbeats() below.
  DERIVED FROM THE MANIFEST:
      hbm_offset, i.e. where the file image was DMA'd, which is what turns a
      file-relative sub-region offset into the absolute address the RTL reads.
  NOT DERIVABLE FROM EITHER, and therefore ARGUMENTS:
      n_rows      -- how much of M this job computes.  A schedule decision.
      x_exp       -- the activation vector's BFP exponent.  A per-token runtime
                     value produced by the previous stage; the descriptor's copy
                     is stale by construction in the integrated system, which is
                     why matvec_int4_desc_axi also has USE_XEXP_PORT.
      out_mode    -- BFP / RAW / PARTIAL.  A schedule decision.
      cb_load     -- whether to reload the codebook.  A schedule decision, and
                     one with teeth: clearing it before any codebook was ever
                     loaded is EC_DESC.
      desc_addr   -- where the descriptor itself is placed in HBM.  Nothing in
                     the manifest reserves descriptor space; see --desc-addr.
      D's routing fields (src_region, dst_region, dst_offset, ordinal,
      src_region2, const_base, const_exp) -- subsystem A reads none of them and
      the manifest describes none of them.  They are written to the conventional
      values of spec section 7 and are a finding, not a derivation.

THE HIGHEST-RISK FIELD IS A BASE.  A well-formed base aimed at the wrong
sub-region computes wrong data and reports success (worklog OI-3's family,
sim/tb_matvec_fk33_desc case 19).  So the bases are computed TWICE here, by two
rules that share no code, and the two must agree or nothing is emitted:

  rule 1  the offset table the file's own 4 KB header carries at 0x38
  rule 2  the offsets implied by spec 6.5a's layout: a 4 KB header, then
          nsub_w weight sub-regions of
          align4k(ceil(M/ROWS_IF)*ceil(K/BLOCK)*(AXI_DW/8)) bytes each, then
          nsub_s scale sub-regions of align4k(ceil(tiles*nb/GRP)*(AXI_DW/8))

Rule 2 also fixes the ORDER, which is the part rule 1 alone cannot check: a
permuted offset table satisfies every structural property of the file.

CORRECTION, 2026-08-29, TRACK NOGUARD (defect DESC-RULE2).  Rule 2 used to
omit both align4k() calls and to use one stride for both kinds of sub-region.
On the shipping 9B set that is the identity -- see layout_strides() for the
derivation -- so THE TWO RULES AGREED BY COINCIDENCE OF GEOMETRY ON EVERY FILE
THIS TOOL HAD EVER SEEN, and refused correct files of any other shape
(MEASURED at M=96 K=128: rule 1 [4096, 8192], rule 2 [4096, 4352]).  A check
that cannot disagree on the data it is run on is not a check.  Every base for
all 249 shipping tensors is byte-identical across that correction.

Usage:
    tools/gen_mv4i_desc.py --mv4i FILE.mv4i --rows 100 --x-exp 5 \\
        [--manifest PATH] [--desc-addr HEX] [--out-mode 0] [--no-cb-load] \\
        [--bin OUT.bin] [--hex OUT.hex] [--json OUT.json] [--print]

    tools/gen_mv4i_desc.py --audit [--manifest PATH]
        parse every tensor in the manifest and report the fields that would go
        into its descriptor, plus every constraint the RTL would check.
"""

import argparse
import hashlib
import json
import os
import struct
import sys

# ------------------------------------------------------------------ constants
# These mirror rtl/matvec_int4_desc_pkg.vhd.  They are NOT re-derived from the
# document: the package is the source both the gateware and the bench compute
# from, and a generator that agreed with a wrong document would agree just as
# happily.
MV4I_MAGIC = 0x4D563449          # "MV4I"
MV4I_DESC_VER = 1
OP_A_JOB = 0
DESC_HDR_WORDS = 8
DESC_EXT_WORDS = 4
DESC_BASE0 = DESC_HDR_WORDS      # word 8, byte 0x40

MV4I_BLOCK = 32                  # spec 6.1, and ref/matvec_int4.c's MV4I_BLOCK
MV4I_HDR_BYTES = 4096            # spec 6.4

MODE_BFP, MODE_RAW, MODE_PARTIAL = 0, 1, 2

# Defaults of the FK33 build (rtl/matvec_int4_desc_axi.vhd generics).  A build
# reports its own values in CAPS/ADDR_CAP/DESC_WORDS, so a driver on real
# hardware must read them rather than trust these; they are here so that this
# tool can refuse a descriptor the gateware would refuse.
FK33 = dict(rows_if=48, axi_dw=256, nports_w=24, nports_s=3,
            addr_w=40, maxcols=17408, maxrows_bfp=17408,
            desc_maxb=16)

AXI4_WIDTHS = (8, 16, 32, 64, 128, 256, 512, 1024)


class DescError(Exception):
    pass


# ------------------------------------------------------------- .mv4i header
class Mv4iHeader(object):
    """An independent Python parse of spec 6.4's 4 KB header.

    Deliberately NOT a wrapper around ref/matvec_int4.c: that file is the
    oracle this tool is checked against, and a tool that called it would be
    checking the oracle against itself.
    """

    def __init__(self, path):
        self.path = path
        self.size = os.path.getsize(path)
        if self.size < MV4I_HDR_BYTES:
            raise DescError("%s: shorter than the 4 KB header" % path)
        with open(path, "rb") as fp:
            h = fp.read(MV4I_HDR_BYTES)
        (self.magic, self.version, self.flags, self.M, self.K,
         self.w_exp, self.out_shift, self.rows_if, self.nports_w,
         self.block, self.axi_dw) = struct.unpack_from("<IHHIIiiHHHH", h, 0)
        if self.magic != MV4I_MAGIC:
            raise DescError("%s: magic is 0x%08X, not MV4I" % (path, self.magic))
        self.codebook = list(struct.unpack_from("<16b", h, 0x20))
        self.scale_offset, self.n_scale_sub = struct.unpack_from("<II", h, 0x30)
        if self.axi_dw == 0:
            # 0x1E was "reserved (0)" until 2026-08-27.  ref/matvec_int4.c
            # reads a zero there as 128 for exactly one reason: 128 is the only
            # width the layout was ever defined at.  Same rule here.
            self.axi_dw = 128
        if self.block != MV4I_BLOCK:
            raise DescError("%s: block is %d, not %d" % (path, self.block, MV4I_BLOCK))
        if self.rows_if == 0:
            raise DescError("%s: rows_if is 0" % path)
        if self.axi_dw not in AXI4_WIDTHS:
            raise DescError("%s: axi_dw %d is not an AXI4 data width"
                            % (path, self.axi_dw))
        # spec 6.5 invariant, in its general form
        if self.nports_w * self.axi_dw != self.rows_if * self.block * 4:
            raise DescError(
                "%s: NPORTS_W*AXI_DW = %d but ROWS_IF*BLOCK*4 = %d"
                % (path, self.nports_w * self.axi_dw,
                   self.rows_if * self.block * 4))
        if self.n_scale_sub == 0:
            self.n_scale_sub = 1
            self.s_sub_offset = [self.scale_offset]
        else:
            self.s_sub_offset = list(struct.unpack_from(
                "<%dQ" % self.n_scale_sub, h, 0x38 + 8 * self.nports_w))
        if self.n_scale_sub != n_scale_sub_rule(self.rows_if, self.axi_dw):
            raise DescError(
                "%s: n_scale_sub is %d, spec 6.5a says %d"
                % (path, self.n_scale_sub,
                   n_scale_sub_rule(self.rows_if, self.axi_dw)))
        self.w_sub_offset = list(struct.unpack_from(
            "<%dQ" % self.nports_w, h, 0x38))
        if 0x38 + 8 * (self.nports_w + self.n_scale_sub) > MV4I_HDR_BYTES:
            raise DescError("%s: offset table does not fit the 4 KB header" % path)
        for c in self.codebook:
            if c == -128:
                raise DescError("%s: codebook entry -128 is forbidden (7.4)" % path)
        if self.out_shift < 0 or self.out_shift > 40:
            raise DescError("%s: out_shift %d outside 0..40" % (path, self.out_shift))

    # ---- spec 6.5a derived geometry
    @property
    def port_b(self):
        return self.axi_dw // 8

    @property
    def nb(self):
        """Blocks per row, ceil(K/BLOCK).  This is the FILE's, and it is what
        sets the block stride inside a sub-region, which is why n_cols is not
        subsettable (ref/mv_fk33_tr.c's header says the same)."""
        return (self.K + MV4I_BLOCK - 1) // MV4I_BLOCK

    @property
    def grp(self):
        return grp_rule(self.rows_if, self.axi_dw)

    def tiles(self, n_rows):
        return (n_rows + self.rows_if - 1) // self.rows_if

    def sub_bytes(self, n_rows=None):
        """Bytes in one sub-region for a job of n_rows rows (default: all M).

        Weight and scale sub-regions are the SAME size, which is not a
        coincidence: a weight sub-region is one bit slice of tiles*nb tile
        words, and a scale sub-region is one bit slice of ceil(tiles*nb/GRP)
        superwords each n_scale_sub*AXI_DW wide, and GRP is defined so those
        two products match."""
        if n_rows is None:
            n_rows = self.M
        return self.tiles(n_rows) * self.nb * self.port_b


def gcd(a, b):
    while b:
        a, b = b, a % b
    return a


def n_scale_sub_rule(rows_if, axi_dw):
    """spec 6.5a: the smallest n with n*AXI_DW a whole number of SW-bit groups."""
    sw = rows_if * 16
    return sw // gcd(sw, axi_dw)


def grp_rule(rows_if, axi_dw):
    sw = rows_if * 16
    return n_scale_sub_rule(rows_if, axi_dw) * axi_dw // sw


# --------------------------------------------------------------- beat counts
def wbeats(h, n_rows):
    """Beats one WEIGHT sub-region delivers for a job of n_rows rows.

    THE IDENTITY: a weight sub-region carries bit slice p of every tile word,
    one beat per (tile, block), ordered tile-major then block.  A job of n_rows
    rows touches tiles 0 .. ceil(n_rows/ROWS_IF)-1, and every tile has the
    FILE's nb = ceil(K/BLOCK) blocks, so

        w_beats = ceil(n_rows / ROWS_IF) * ceil(K / BLOCK)

    Row subsetting is a contiguous prefix of the sub-region and needs no
    gather.  COLUMN subsetting is not available at all: the block stride is the
    file's nb, so an n_cols < K would change the stride, which is why n_cols is
    always K here and why ref/mv_fk33_tr.c refuses to subset it either."""
    return h.tiles(n_rows) * h.nb


def sbeats(h, n_rows):
    """Beats one SCALE sub-region delivers.

    Groups are the same tile-major-then-block stream, GRP of them per
    superword, and one superword is n_scale_sub beats -- one per sub-region.
    So each sub-region delivers one beat per superword:

        s_beats = ceil(w_beats / GRP)"""
    g = h.grp
    return (wbeats(h, n_rows) + g - 1) // g


# ---------------------------------------------------------------- the bases
def sub_offsets_from_header(h):
    return list(h.w_sub_offset), list(h.s_sub_offset)


def align4k(v):
    """The packers' padding rule, transcribed rather than restated.

    ref/matvec_int4.c:456  `(v + 4095) & ~(size_t)4095`
    tools/pack_int4.py:194 the same value."""
    return (v + 4095) & ~4095


def layout_strides(h):
    """(weight stride, scale stride) in the packed file.

    THE DEFECT THIS FIXES, and it is worth stating in full because the rule it
    corrects had never once discriminated.

    Rule 2 used ONE stride, `h.sub_bytes()` = tiles*nb*port_b, for both kinds
    of sub-region.  That is wrong twice:

      1. It omits the 4 KB padding both packers apply.
         ref/matvec_int4.c:474  `sub_pad = align4k(tiles*NB*port_b)`
         tools/pack_int4.py:477 `sub_sz  = align4k(tiles*NB*port_b)`

      2. The SCALE stride is not the weight stride.  The scale region is
         ceil(tiles*nb/GRP) SUPERWORDS, one beat per sub-region, so
         ref/matvec_int4.c:478 and tools/pack_int4.py:482 both give it its own
         `align4k(nsuper*port_b)`.  That equals the weight stride only when
         GRP == 1.

    WHY IT HAD NEVER BEEN CAUGHT, DERIVED rather than asserted.  On the FK33
    the file geometry is BLOCK = 32 and AXI_DW = 256, so port_b = 32 and
    nb = K/32, giving nb*port_b = K exactly.  Every tensor in the shipping 9B
    set has K in {4096, 12288}, both exact multiples of 4096, so
    tiles*nb*port_b = tiles*K is always 4 KB-aligned and align4k is the
    identity; and GRP = 1 throughout, so the two strides coincide.  MEASURED
    over all 249 mv4i files in qwen35-9b-mv4i-noembd: 8 distinct (M, K), GRP 1
    for all of them, and EVERY base identical before and after this change.

    So rule 2 agreed with rule 1 by coincidence of geometry on every file it
    had ever seen -- and falsely refused anything else.  MEASURED at M=96
    K=128: rule 1 gave [4096, 8192], rule 2 gave [4096, 4352].  A two-rule
    cross-check that cannot disagree on the data it is run on is not a check;
    it is the only guard against the one descriptor corruption the gateware
    cannot see, and it was decoration."""
    w_stride = align4k(h.sub_bytes())
    nsuper = (h.tiles(h.M) * h.nb + h.grp - 1) // h.grp
    s_stride = align4k(nsuper * h.port_b)
    return w_stride, s_stride


def sub_offsets_from_layout(h):
    """Rule 2: the offsets spec 6.5a's layout implies, computed from the shape
    alone.  Independent of the file's own offset table, and in particular it
    fixes the ORDER, which a permuted table would otherwise satisfy."""
    w_stride, s_stride = layout_strides(h)
    off = MV4I_HDR_BYTES
    w = []
    for _ in range(h.nports_w):
        w.append(off)
        off += w_stride
    s = []
    for _ in range(h.n_scale_sub):
        s.append(off)
        off += s_stride
    return w, s


def check_bases(h):
    """Both rules, compared.  Returns (w_off, s_off, notes)."""
    w1, s1 = sub_offsets_from_header(h)
    w2, s2 = sub_offsets_from_layout(h)
    notes = []
    if w1 != w2 or s1 != s2:
        raise DescError(
            "%s: the file's offset table and spec 6.5a's layout DISAGREE.\n"
            "  header w=%r s=%r\n  layout w=%r s=%r\n"
            "Nothing is emitted: a base is the one field whose corruption the "
            "gateware cannot see." % (h.path, w1, s1, w2, s2))
    # The LAST scale sub-region is padded like every other one, so the file
    # ends at its padded end, not at its live end.  Using h.sub_bytes() here
    # was the same defect in its second place: it happened to be right only
    # while align4k was the identity.
    _, s_stride = layout_strides(h)
    end = s1[-1] + s_stride
    if end != h.size:
        raise DescError(
            "%s: sub-regions end at %d but the file is %d bytes"
            % (h.path, end, h.size))
    notes.append("bases agree by two independent rules; regions tile the file "
                 "exactly (%d bytes)" % h.size)
    return w1, s1, notes


def sub_base(kind, idx, off, skip, span, extent, path):
    """Absolute HBM address of ONE sub-region.  The only place a lane-striped
    placement enters the descriptor.

    `extent` is `(hbm_base_of_this_sub_region, bytes_available_there)`.  For a
    v1 flat manifest that is `(hbm_offset + off, stride)`; for a v2
    lane-striped one it is the piece the manifest placed at file offset `off`.

    THE JOIN IS ON THE FILE OFFSET, NEVER ON A LANE LABEL.  `off` comes from
    `check_bases()`, which has already required the file's own 0x38 offset
    table and spec 6.5a's layout to agree by two rules that share no code.  The
    manifest is then asked only where THAT file offset was placed.  Nothing
    here reads a piece's `lane`, `kind` or `segment`, so a manifest whose
    labels are wrong but whose addresses are right still yields the right
    descriptor -- and one whose labels are right and whose addresses are wrong
    is not rescued by them.  TRACK PACKSTRIPE's teeth case T3 is the recorded
    cost of the other choice.

    `check_bases()` IS NOT RELAXED BY STRIPING AND MUST NOT BE.  It compares
    two FILE offsets and striping changes neither (MEASURED by PACKSTRIPE:
    249 of 249 mv4i agree under both layouts).  If a striped layout ever seems
    to need it loosened, the `pieces` model is wrong, not the check.

    The bound is the hazard striping ADDS.  Under the flat layout a job that
    read past its sub-region ran into the next sub-region of the SAME tensor;
    under striping the next bytes belong to a different tensor's lane arena in
    that pseudo-channel, and nothing faults."""
    base, avail = extent
    if base is None:
        raise DescError(
            "%s: %s sub-region %d is at file +%d and the manifest places no "
            "piece there.  A striped manifest that does not cut the file where "
            "the header's own offset table cuts it describes different bytes."
            % (path, kind, idx, off))
    if skip + span > avail:
        raise DescError(
            "%s: %s sub-region %d would read %d bytes from +%d of an extent "
            "that is only %d bytes.  Under a lane-striped layout the bytes "
            "past the end belong to another tensor's arena in the same "
            "pseudo-channel, and the read does not fault."
            % (path, kind, idx, span, skip, avail))
    return base + skip


def piece_extents(entry):
    """`{file_offset: (hbm_offset, nbytes)}` for a manifest object, or None if
    the object is flat.

    ONE PRODUCER: `tools/hbm_map.py::file_pieces()`.  Imported lazily because
    `hbm_map` imports THIS module at load time to size the descriptor stride,
    and a module-level import here would close the cycle."""
    if not entry or not entry.get("pieces"):
        return None
    import hbm_map                                          # noqa: E402
    return {p["file_offset"]: (p["hbm_offset"], p["nbytes"])
            for p in hbm_map.file_pieces(entry)}


# ------------------------------------------------------------ the descriptor
class Descriptor(object):
    def __init__(self, words, ext0, fields):
        self.words = words
        self.ext0 = ext0
        self.fields = fields

    def to_bytes(self):
        return b"".join(struct.pack("<Q", w) for w in self.words)

    def hexlines(self):
        """One 64-bit word per line, MSB nibble first, index first -- the form
        sim/tb_mv4i_desc_image.vhd reads."""
        return ["%016X" % w for w in self.words]


def u32(v):
    """Two's-complement 32-bit field, so a negative w_exp/out_shift/x_exp lands
    the way the RTL's signed read expects."""
    return v & 0xFFFFFFFF


def build_descriptor(h, hbm_base, n_rows, x_exp, out_mode=MODE_BFP,
                     cb_load=True, addr_w=40, row_start=0,
                     src_region=0xFF, dst_region=0x00, dst_offset=0,
                     ordinal=0, src_region2=0xFF,
                     const_base=0, const_exp=0,
                     pieces=None,
                     mutate=None):
    """Build the descriptor image.  `mutate` is a callable(words, ctx) applied
    AFTER the clean image is built, used only by the teeth checks.

    ROW WINDOWS.  n_rows alone selects a PREFIX of the rows.  A window that
    does not start at row 0 is expressed by advancing every base by whole
    tiles, because a sub-region's beats run tile-major: skipping the first
    `row_start/ROWS_IF` tiles is skipping `tiles*nb` beats of every sub-region,
    weight and scale alike (they have the same beat count when GRP = 1, and
    ceil(t*nb/GRP) otherwise -- the scale skip is computed separately below for
    that reason).  This is what makes the two 248320-row tensors describable at
    all: MAXROWS_BFP is 17408, so those need 15 jobs each."""
    npw, nps = h.nports_w, h.n_scale_sub
    ext0 = DESC_BASE0 + npw + nps
    nwords = ext0 + DESC_EXT_WORDS

    if row_start % h.rows_if:
        raise DescError("--row-start %d is not a multiple of ROWS_IF = %d; a "
                        "window can only begin on a tile boundary"
                        % (row_start, h.rows_if))
    skip_tiles = row_start // h.rows_if
    w_skip = skip_tiles * h.nb * h.port_b
    s_skip = ((skip_tiles * h.nb) // h.grp) * h.port_b
    if skip_tiles * h.nb % h.grp:
        raise DescError("row_start %d lands mid-superword (GRP = %d): the "
                        "scale window cannot be expressed as a base offset"
                        % (row_start, h.grp))

    w_off, s_off, notes = check_bases(h)
    wb = wbeats(h, n_rows)
    sb = sbeats(h, n_rows)

    # WHERE EACH SUB-REGION IS.  `pieces` is `{file_offset: (hbm_offset,
    # nbytes)}` from a v2 lane-striped manifest, or None for a v1 flat one, in
    # which case the strides ARE the extents and this reduces exactly to the
    # old `hbm_base + off`.  Same code, same arithmetic, one loop -- so the
    # striped and flat paths cannot drift, and `--stripe-lanes` being inert on
    # a flat model is a comparison of outputs rather than a reading of code.
    w_stride, s_stride = layout_strides(h)
    if pieces is None:
        w_ext = [(hbm_base + o, w_stride) for o in w_off]
        s_ext = [(hbm_base + o, s_stride) for o in s_off]
    else:
        w_ext = [pieces.get(o, (None, 0)) for o in w_off]
        s_ext = [pieces.get(o, (None, 0)) for o in s_off]
    w_base = [sub_base("weight", p, o, w_skip, wb * h.port_b, w_ext[p], h.path)
              for p, o in enumerate(w_off)]
    s_base = [sub_base("scale", q, o, s_skip, sb * h.port_b, s_ext[q], h.path)
              for q, o in enumerate(s_off)]
    if pieces is not None:
        notes.append("bases relocated per sub-region from the manifest's "
                     "`pieces`, joined on file offset (%d pieces)"
                     % len(pieces))
    if row_start:
        notes.append("row window starts at tile %d: +%d bytes on every weight "
                     "base, +%d on every scale base"
                     % (skip_tiles, w_skip, s_skip))

    d = [0] * nwords

    flags = (1 << 2) if cb_load else 0            # D's cb_load
    d[0] = ((OP_A_JOB & 0xFF)
            | ((flags & 0xFF) << 8)
            | ((src_region & 0xFF) << 16)
            | ((dst_region & 0xFF) << 24)
            | ((dst_offset & 0xFFFFFFFF) << 32))
    d[1] = (n_rows & 0xFFFFFFFF) | ((h.K & 0xFFFFFFFF) << 32)
    d[2] = u32(h.w_exp) | (u32(h.out_shift) << 32)
    d[3] = ((out_mode & 0xFF)
            | ((ordinal & 0xFF) << 8)
            | ((npw & 0xFFFF) << 16)
            | ((nps & 0xFFFF) << 32)
            | ((src_region2 & 0xFF) << 48))       # bits 63:56 stay 0: D's pad
    d[4] = (const_base & 0xFFFFFFFF) | (u32(const_exp) << 32)
    cb = h.codebook
    d[5] = sum((cb[j] & 0xFF) << (8 * j) for j in range(8))
    d[6] = sum((cb[j + 8] & 0xFF) << (8 * j) for j in range(8))
    d[7] = 0                                      # D's reserved word

    for p in range(npw):
        d[DESC_BASE0 + p] = w_base[p]
    for q in range(nps):
        d[DESC_BASE0 + npw + q] = s_base[q]

    d[ext0 + 0] = MV4I_MAGIC | (MV4I_DESC_VER << 32)   # ext_flags 63:48 = 0
    d[ext0 + 1] = (wb & 0xFFFFFFFF) | ((sb & 0xFFFFFFFF) << 32)
    d[ext0 + 2] = u32(x_exp)                           # 63:32 pad = 0
    d[ext0 + 3] = 0

    fields = dict(
        tensor=os.path.basename(h.path), n_rows=n_rows, n_cols=h.K,
        M=h.M, K=h.K, w_exp=h.w_exp, out_shift=h.out_shift, x_exp=x_exp,
        out_mode=out_mode, cb_load=cb_load, nsub_w=npw, nsub_s=nps,
        rows_if=h.rows_if, axi_dw=h.axi_dw, block=h.block, grp=h.grp,
        nb=h.nb, tiles=h.tiles(n_rows), w_beats=wb, s_beats=sb,
        codebook=list(cb), hbm_base=hbm_base, row_start=row_start,
        w_sub_offset=w_off, s_sub_offset=s_off,
        w_base=w_base, s_base=s_base,
        striped=pieces is not None,
        w_extent_base=[e[0] for e in w_ext],
        s_extent_base=[e[0] for e in s_ext],
        ext0=ext0, desc_words=nwords, desc_bytes=8 * nwords,
        notes=notes)

    if mutate is not None:
        mutate(d, fields)

    return Descriptor(d, ext0, fields)


# --------------------------------------------------- what the gateware checks
def rtl_would_reject(d, build=FK33, desc_addr=None):
    """Re-state, in the order rtl/matvec_int4_desc_axi.vhd's S_CHECK evaluates
    them, every condition that entity refuses.  Returns a list of (code, name)
    -- empty means the gateware accepts.

    This is a PREDICTION, not the judge.  The judge is the RTL itself, driven
    with these exact bytes by sim/tb_mv4i_desc_image.vhd.  It is here so the
    generator can refuse to emit something the card will reject, and so a
    disagreement between prediction and RTL is itself a finding."""
    out = []
    w = d.words
    e = d.ext0
    npw, nps = build["nports_w"], build["nports_s"]
    addr_w = build["addr_w"]
    align = build["desc_maxb"] * (build["axi_dw"] // 8)

    def lo32(x):
        return x & 0xFFFFFFFF

    def hi32(x):
        return (x >> 32) & 0xFFFFFFFF

    if desc_addr is not None:
        if desc_addr >> addr_w:
            out.append((0xD, "ERR_ADDR: DESC_PTR above ADDR_W"))
        if desc_addr % align:
            out.append((0xC, "ERR_ALIGN: DESC_PTR not %d-byte aligned" % align))
    if len(w) != DESC_BASE0 + npw + nps + DESC_EXT_WORDS:
        out.append((None, "descriptor length %d, build expects %d"
                    % (len(w), DESC_BASE0 + npw + nps + DESC_EXT_WORDS)))
        return out
    if lo32(w[e]) != MV4I_MAGIC:
        out.append((0xA, "ERR_MAGIC"))
    elif ((w[e] >> 32) & 0xFFFF) != MV4I_DESC_VER:
        out.append((0xB, "ERR_VER"))
    elif (w[e] >> 48) & 0xFFFF:
        out.append((0x3, "ERR_DESC: ext_flags nonzero"))
    elif ((w[3] >> 16) & 0xFFFF) != npw or ((w[3] >> 32) & 0xFFFF) != nps:
        out.append((0x9, "ERR_GEOM"))
    elif (w[0] & 0xFF) != OP_A_JOB:
        out.append((0x3, "ERR_DESC: opcode"))
    elif (w[3] >> 56) & 0xFF:
        out.append((0x3, "ERR_DESC: word 3 pad"))
    elif w[7]:
        out.append((0x3, "ERR_DESC: word 7 pad"))
    elif hi32(w[e + 2]) or w[e + 3]:
        out.append((0x3, "ERR_DESC: extension pad"))
    elif (w[3] & 0xFF) > 2:
        out.append((0x3, "ERR_DESC: out_mode"))
    elif (lo32(w[1]) == 0 or lo32(w[1]) > build["maxrows_bfp"]
          or hi32(w[1]) == 0 or hi32(w[1]) > build["maxcols"]):
        out.append((0x3, "ERR_DESC: shape"))
    elif lo32(w[e + 1]) == 0 or hi32(w[e + 1]) == 0:
        out.append((0x3, "ERR_DESC: w_beats / s_beats zero"))
    else:
        for p in range(npw + nps):
            b = w[DESC_BASE0 + p]
            if b >> addr_w:
                out.append((0xD, "ERR_ADDR: base word %d" % (DESC_BASE0 + p)))
                break
            if b & 0xFFF:
                out.append((0xC, "ERR_ALIGN: base word %d" % (DESC_BASE0 + p)))
                break
        else:
            if not (w[0] >> 10) & 1:
                out.append((0x3, "ERR_DESC: cb_load clear (only if no codebook "
                                 "was ever loaded)"))
    return out


# ------------------------------------------------------------------ manifest
def load_manifest(path, allow_striped=False):
    """Parse a load manifest, and REFUSE a lane-striped one to a caller that
    has not said it understands `pieces`.

    THE DEFAULT IS THE POINT.  Under a v2 lane-striped manifest a tensor's
    sub-regions are in up to 28 different HBM pseudo-channels and
    `files[].hbm_offset` names only its 4 KB header, so `hbm_offset + <file
    offset>` names no byte the engine will ever read.  A tool that has not been
    taught this does not fail -- it emits a complete, well-formed, gateware-
    ACCEPTED descriptor aimed at the wrong bytes, and prints success.  MEASURED
    2026-08-30: `tools/gen_layer_program.py --token` over the striped manifest
    emitted `311 of 311 A jobs, 0 refused`, with all 6,723 sub-region bases
    IDENTICAL to the flat program's.

    This is what the `format` bump exists to provoke.  A caller that has been
    taught passes `allow_striped=True`; there is deliberately no way to get a
    flat base out of a striped manifest by accident."""
    with open(path) as fp:
        m = json.load(fp)
    by_file = {}
    for f in m.get("files", []):
        by_file[f.get("file")] = f
    if not allow_striped:
        striped = [f for f in m.get("files", []) if f.get("pieces")]
        if striped:
            raise DescError(
                "%s is %r: %d of its %d objects are LANE-STRIPED, so "
                "`hbm_offset` is a 4 KB header and the sub-regions are in "
                "other HBM pseudo-channels.  This caller reads one contiguous "
                "extent per tensor and would emit descriptors aimed at bytes "
                "that are not there, without failing.  Teach it "
                "`gen_mv4i_desc.piece_extents()` + `build_descriptor(..., "
                "pieces=...)`, then pass allow_striped=True."
                % (path, m.get("format"), len(striped), len(m.get("files", []))))
    return m, by_file


def hbm_base_for(mv4i_path, manifest_path, allow_striped=False):
    m, by_file = load_manifest(manifest_path, allow_striped=allow_striped)
    name = os.path.basename(mv4i_path)
    f = by_file.get(name)
    if f is None:
        raise DescError("%s: not in %s" % (name, manifest_path))
    if f.get("kind") != "mv4i":
        raise DescError("%s: manifest kind is %r, not mv4i" % (name, f.get("kind")))
    return int(f["hbm_offset"]), f, m


def verify_image(mv4i_path, entry):
    """The blake2b-128 the manifest carries for the file image.  This is the
    ONLY thing that can catch a base pointing at the wrong bytes once the image
    is on the card, so the tool checks that the file it is describing is the
    file the manifest says was loaded."""
    hsh = hashlib.blake2b(digest_size=16)
    with open(mv4i_path, "rb") as fp:
        while True:
            chunk = fp.read(1 << 20)
            if not chunk:
                break
            hsh.update(chunk)
    got = hsh.hexdigest()
    want = entry.get("blake2b_128")
    return got, want, (want is None or got == want)


# ---------------------------------------------------------------------- CLI
def parse_int(s):
    return int(s, 0)


# ---------------------------------------------------------------------------
# TEETH FOR THE TWO-RULE BASE CHECK (2026-08-29, TRACK NOGUARD, DESC-RULE2).
#
# The check this exercises had NEVER DISCRIMINATED.  It is the only guard
# against a base aimed at the wrong sub-region, which is the one descriptor
# corruption the gateware cannot see, and on every file it had ever been run
# on its two rules agreed by coincidence of geometry.  So the rows below are
# split three ways and all three are reported:
#
#   * rows where the two rules must AGREE, including the geometry that made
#     the defect invisible (COINCIDE) and the ones that did not (NONALIGN,
#     GRP2).  A false refusal here is what the old rule 2 did to every shape
#     outside the model.
#   * rows where the check must BITE.  A guard nobody has watched refuse is a
#     guard nobody has shown to work.
#   * an attribution control: every row is run again against the OLD rule 2,
#     the tight single-stride one, so each verdict is attributed to the
#     correction rather than to the harness.
#
# Headers are synthesised in Python.  They are deliberately NOT produced by
# ref/matvec_int4.c: that file is the oracle this tool is checked against, and
# a teeth test that called it would be checking the oracle against itself --
# the same reason Mv4iHeader is an independent parse.  The bodies are sparse
# (ftruncate), so a 570 MB geometry costs no disk.

def _synth_mv4i(path, M, K, rows_if, axi_dw, pad=True,
                mutate=None):
    """Write a header-only .mv4i of the right total size.  `mutate(w, s)`
    may return a corrupted offset table."""
    port_b = axi_dw // 8
    nb = (K + MV4I_BLOCK - 1) // MV4I_BLOCK
    tiles = (M + rows_if - 1) // rows_if
    nports_w = rows_if * MV4I_BLOCK * 4 // axi_dw
    nss = n_scale_sub_rule(rows_if, axi_dw)
    grp = grp_rule(rows_if, axi_dw)
    a = align4k if pad else (lambda v: v)
    w_stride = a(tiles * nb * port_b)
    nsuper = (tiles * nb + grp - 1) // grp
    s_stride = a(nsuper * port_b)
    w = [MV4I_HDR_BYTES + w_stride * i for i in range(nports_w)]
    s = [w[-1] + w_stride + s_stride * q for q in range(nss)]
    total = s[-1] + s_stride
    if mutate is not None:
        w, s = mutate(list(w), list(s))
    h = bytearray(MV4I_HDR_BYTES)
    struct.pack_into("<IHHIIiiHHHH", h, 0, MV4I_MAGIC, 1, 1, M, K, 8, 3,
                     rows_if, nports_w, MV4I_BLOCK, axi_dw)
    struct.pack_into("<16b", h, 0x20, *([1] * 16))
    struct.pack_into("<II", h, 0x30, s[0], nss)
    for i, v in enumerate(w):
        struct.pack_into("<Q", h, 0x38 + 8 * i, v)
    for q, v in enumerate(s):
        struct.pack_into("<Q", h, 0x38 + 8 * (nports_w + q), v)
    with open(path, "wb") as fp:
        fp.write(h)
        fp.truncate(total)
    return path


def _tight_layout(h):
    """Rule 2 EXACTLY AS IT WAS before this correction: one stride, no
    align4k.  Kept verbatim as the attribution control -- without it, a row
    that the corrected rule accepts cannot be distinguished from a row the
    harness never really tested."""
    stride = h.sub_bytes()
    off = MV4I_HDR_BYTES
    w = []
    for _ in range(h.nports_w):
        w.append(off)
        off += stride
    s = []
    for _ in range(h.n_scale_sub):
        s.append(off)
        off += stride
    return w, s


def _agrees(h, layout_fn):
    w1, s1 = sub_offsets_from_header(h)
    w2, s2 = layout_fn(h)
    return w1 == w2 and s1 == s2


def selftest():
    import shutil
    import tempfile

    tmp = tempfile.mkdtemp(prefix="mv4idesc.")
    try:
        def mk(name, **kw):
            return _synth_mv4i(os.path.join(tmp, name + ".mv4i"), **kw)

        def swap_two(w, s):
            w[1], w[2] = w[2], w[1]
            return w, s

        def shift_one(w, s):
            w[3] += 32                     # one beat: a plausible off-by-one
            return w, s

        def shift_scale(w, s):
            s[0] += 4096
            return w, s

        # name, path, must-agree
        ROWS = [
            # The FK33/9B geometry.  align4k is the identity here and GRP is
            # 1, which is exactly why the defect was invisible: this row
            # passes with the OLD rule 2 too, and says so.
            ("COINCIDE", mk("coincide", M=4096, K=4096, rows_if=48,
                            axi_dw=256), True),
            # The lm_head shape, same coincidence at 5174 tiles.
            ("COINCIDE_BIG", mk("big", M=248320, K=4096, rows_if=48,
                                axi_dw=256), True),
            # K=12288, the other shipping K.
            ("COINCIDE_K3", mk("k3", M=4096, K=12288, rows_if=48,
                               axi_dw=256), True),
            # The geometry the OLD rule 2 falsely REFUSED.  MEASURED: rule 1
            # [4096, 8192], old rule 2 [4096, 4352].
            ("NONALIGN", mk("nonalign", M=96, K=128, rows_if=48,
                            axi_dw=256), True),
            # GRP != 1, so the scale stride is NOT the weight stride.  The old
            # rule used one stride for both and could not express this file at
            # all.
            ("GRP2", mk("grp2", M=800, K=800, rows_if=8, axi_dw=256), True),
            # --- and now it must BITE ---
            ("SWAP", mk("swap", M=96, K=128, rows_if=48, axi_dw=256,
                        mutate=swap_two), False),
            ("SHIFT_W", mk("shiftw", M=96, K=128, rows_if=48, axi_dw=256,
                           mutate=shift_one), False),
            ("SHIFT_S", mk("shifts", M=96, K=128, rows_if=48, axi_dw=256,
                           mutate=shift_scale), False),
            # A file packed TIGHT, with no padding at all.  Both packers pad,
            # so this is not a file either of them writes -- and the corrected
            # rule must refuse it rather than quietly accept a second layout.
            ("UNPADDED", mk("unpadded", M=96, K=128, rows_if=48, axi_dw=256,
                            pad=False), False),
        ]
        names = [r[0] for r in ROWS]
        if len(set(names)) != len(names):
            sys.exit("SELFTEST ABORT: duplicate row name -- one row would "
                     "never run and another would run twice, and the table "
                     "would look full either way.")
        if len(set(["x", "x"])) == 2:
            sys.exit("SELFTEST ABORT: the duplicate-name gate cannot fire.")

        print("row           expect   corrected  old-rule2  attribution")
        print("-" * 68)
        bad = []
        alone = 0
        for name, path, want_agree in ROWS:
            try:
                h = Mv4iHeader(path)
            except DescError as e:
                print("%-13s %-8s %-10s %-10s %s"
                      % (name, "-", "VOID", "-", e))
                bad.append("%s: header would not parse: %s" % (name, e))
                continue
            new = _agrees(h, sub_offsets_from_layout)
            old = _agrees(h, _tight_layout)
            ok = (new == want_agree)
            if want_agree:
                attr = ("BOTH (this is the coincidence)" if old
                        else "CORRECTED RULE ONLY")
                if new and not old:
                    alone += 1
            else:
                attr = "both refuse" if not old else "CORRECTED RULE ONLY"
            print("%-13s %-8s %-10s %-10s %s%s"
                  % (name, "agree" if want_agree else "REFUSE",
                     "agree" if new else "refuse",
                     "agree" if old else "refuse", attr,
                     "" if ok else "   <== WRONG"))
            if not ok:
                bad.append("%s: wanted %s, corrected rule said %s"
                           % (name, "agree" if want_agree else "refuse",
                              "agree" if new else "refuse"))

        # check_bases must actually RAISE, not merely disagree: the disagreement
        # is only a guard if something stops on it.
        raised = 0
        for name, path, want_agree in ROWS:
            if want_agree:
                continue
            try:
                check_bases(Mv4iHeader(path))
                bad.append("%s: check_bases did NOT raise" % name)
            except DescError:
                raised += 1
        print("%-13s %-8s %-10s %-10s %s"
              % ("RAISES", "4", str(raised), "-",
                 "check_bases stops rather than merely disagreeing"))
        if raised != 4:
            bad.append("check_bases raised on %d of 4 corrupt files" % raised)

        # VOID: a file that is not an .mv4i at all must be VOID, never a pass.
        junk = os.path.join(tmp, "junk.mv4i")
        with open(junk, "wb") as fp:
            fp.write(b"\x00" * MV4I_HDR_BYTES)
        try:
            Mv4iHeader(junk)
            vd = "PASSED"
        except DescError:
            vd = "VOID"
        print("%-13s %-8s %-10s %-10s %s%s"
              % ("VD", "VOID", vd, "-", "not an .mv4i at all",
                 "" if vd == "VOID" else "   <== WRONG"))
        if vd != "VOID":
            bad.append("VD: a non-mv4i file scored %s, not VOID" % vd)

        print("-" * 68)
        print("CORRECTED RULE ALONE=%d  (rows the old tight rule got wrong)"
              % alone)
        if bad:
            for b in bad:
                print("FAIL " + b)
            sys.exit("SELFTEST FAIL")
        if alone == 0:
            sys.exit("SELFTEST FAIL: every row behaves the same under the old "
                     "tight rule, so nothing here measures the correction.")
        print("SELFTEST PASS")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mv4i", help="packed tensor to describe")
    ap.add_argument("--manifest",
                    default="/mnt/storage/llama-models/qwen35-9b-mv4i/manifest.json")
    ap.add_argument("--rows", type=int, default=None,
                    help="n_rows for this job (default: the tensor's M)")
    ap.add_argument("--row-start", type=int, default=0,
                    help="first row of the window; must be a multiple of "
                         "ROWS_IF.  Expressed as a base offset, not a field")
    ap.add_argument("--x-exp", type=int, default=None,
                    help="activation block exponent -- NOT derivable, required")
    ap.add_argument("--out-mode", type=int, default=MODE_BFP)
    ap.add_argument("--no-cb-load", action="store_true")
    ap.add_argument("--desc-addr", type=parse_int, default=None,
                    help="HBM byte address the descriptor is placed at")
    ap.add_argument("--no-hbm-base", action="store_true",
                    help="bases relative to the file image (offset 0), for a "
                         "bench that serves sub-regions rather than HBM")
    ap.add_argument("--bin", help="write the raw 312-byte image")
    ap.add_argument("--hex", help="write one 64-bit word per line, hex")
    ap.add_argument("--json", help="write every derived field, for inspection")
    ap.add_argument("--print", action="store_true")
    ap.add_argument("--selftest", action="store_true",
                    help="teeth for the two-rule base check; no model, "
                         "no card, no Vivado")
    ap.add_argument("--audit", action="store_true",
                    help="parse every tensor in the manifest and report")
    ap.add_argument("--no-hash", action="store_true",
                    help="skip the blake2b image check (it reads the file)")
    a = ap.parse_args(argv)

    if a.selftest:
        selftest()
        return 0

    if a.audit:
        return audit(a)

    if not a.mv4i:
        ap.error("--mv4i is required (or --audit)")
    if a.x_exp is None:
        ap.error("--x-exp is required: it is a per-token runtime value and "
                 "NOTHING in the manifest or the .mv4i header carries it")

    h = Mv4iHeader(a.mv4i)
    if a.no_hbm_base:
        hbm_base, entry = 0, None
        pieces = None
    else:
        # TAUGHT: the pieces are read three lines down.
        hbm_base, entry, _ = hbm_base_for(a.mv4i, a.manifest,
                                          allow_striped=True)
        pieces = piece_extents(entry)
        if not a.no_hash:
            got, want, ok = verify_image(a.mv4i, entry)
            if not ok:
                raise DescError(
                    "%s: blake2b_128 is %s, manifest says %s -- the file on "
                    "disk is NOT the file that was loaded, so its sub-region "
                    "offsets describe different bytes" % (a.mv4i, got, want))

    n_rows = a.rows if a.rows else h.M
    if a.row_start + n_rows > h.M:
        raise DescError("--row-start %d + --rows %d exceeds the tensor's M = %d"
                        % (a.row_start, n_rows, h.M))

    d = build_descriptor(h, hbm_base, n_rows, a.x_exp, row_start=a.row_start,
                         out_mode=a.out_mode, cb_load=not a.no_cb_load,
                         pieces=pieces)

    bad = rtl_would_reject(d, desc_addr=a.desc_addr)
    if bad:
        sys.stderr.write("the FK33 build would REJECT this descriptor:\n")
        for code, why in bad:
            sys.stderr.write("  err_code %s  %s\n"
                             % ("0x%X" % code if code is not None else "--", why))
        if not any(c == 0x3 and "cb_load" in w for c, w in bad):
            return 3

    if a.bin:
        with open(a.bin, "wb") as fp:
            fp.write(d.to_bytes())
    if a.hex:
        with open(a.hex, "w") as fp:
            f = d.fields
            fp.write("# GENERATED by tools/gen_mv4i_desc.py -- DO NOT EDIT\n")
            fp.write("# tensor %s\n" % f["tensor"])
            fp.write("# job    n_rows=%d row_start=%d n_cols=%d out_mode=%d "
                     "x_exp=%d cb_load=%d\n"
                     % (f["n_rows"], f["row_start"], f["n_cols"], f["out_mode"],
                        f["x_exp"], int(f["cb_load"])))
            fp.write("# build  ROWS_IF=%d AXI_DW=%d nsub_w=%d nsub_s=%d "
                     "w_beats=%d s_beats=%d\n"
                     % (f["rows_if"], f["axi_dw"], f["nsub_w"], f["nsub_s"],
                        f["w_beats"], f["s_beats"]))
            fp.write("# image  hbm_base=0x%X  %d words, %d bytes, ext at word "
                     "%d\n" % (f["hbm_base"], f["desc_words"], f["desc_bytes"],
                               f["ext0"]))
            for ln in d.hexlines():
                fp.write(ln + "\n")
    if a.json:
        with open(a.json, "w") as fp:
            json.dump(d.fields, fp, indent=1, sort_keys=True)
            fp.write("\n")
    if a.print or not (a.bin or a.hex or a.json):
        f = d.fields
        print("tensor        %s" % f["tensor"])
        print("shape         M=%d K=%d  job n_rows=%d n_cols=%d"
              % (f["M"], f["K"], f["n_rows"], f["n_cols"]))
        print("geometry      ROWS_IF=%d AXI_DW=%d BLOCK=%d GRP=%d nb=%d tiles=%d"
              % (f["rows_if"], f["axi_dw"], f["block"], f["grp"], f["nb"],
                 f["tiles"]))
        print("sub-regions   nsub_w=%d nsub_s=%d" % (f["nsub_w"], f["nsub_s"]))
        print("beats         w_beats=%d s_beats=%d" % (f["w_beats"], f["s_beats"]))
        print("numeric       w_exp=%d out_shift=%d x_exp=%d out_mode=%d cb_load=%d"
              % (f["w_exp"], f["out_shift"], f["x_exp"], f["out_mode"],
                 int(f["cb_load"])))
        print("hbm_base      0x%X" % f["hbm_base"])
        print("w_base[0..2]  %s" % " ".join("0x%X" % b for b in f["w_base"][:3]))
        print("s_base        %s" % " ".join("0x%X" % b for b in f["s_base"]))
        print("descriptor    %d words, %d bytes, ext at word %d"
              % (f["desc_words"], f["desc_bytes"], f["ext0"]))
        for n in f["notes"]:
            print("note          %s" % n)
    return 0


def audit(a):
    m, by_file = load_manifest(a.manifest, allow_striped=True)
    geo = m.get("geometry", {})
    print("manifest geometry %r" % geo)
    nfiles = nbad = 0
    align_bad = []
    addr_bad = []
    beat_max = 0
    nbase = nstriped = 0
    top = int(m.get("hbm", {}).get("size", 1 << 33))
    for name, f in sorted(by_file.items()):
        if f.get("kind") != "mv4i":
            continue
        path = os.path.join(os.path.dirname(a.manifest), name)
        nfiles += 1
        try:
            h = Mv4iHeader(path)
            w_off, s_off, _ = check_bases(h)
        except DescError as e:
            nbad += 1
            print("REFUSED %s: %s" % (name, e))
            continue
        # THE ADDRESSES AUDITED ARE THE ONES THAT EXIST.  Under a v2
        # lane-striped manifest `hbm_offset + off` names no byte the engine
        # will ever read: the sub-region is in another pseudo-channel
        # entirely.  Auditing it anyway is what `tools/check_hbm_stack.py`
        # does, and it PASSES over 7,154 ranges of which zero are real.
        pieces = piece_extents(f)
        if pieces is not None:
            nstriped += 1
        base = int(f["hbm_offset"])
        for o in w_off + s_off:
            if pieces is None:
                addr, span = base + o, None
            else:
                addr, span = pieces.get(o, (None, 0))
                if addr is None:
                    nbad += 1
                    print("REFUSED %s: no piece at file +%d" % (name, o))
                    break
            nbase += 1
            if addr & 0xFFF:
                align_bad.append((name, o))
            if addr >> FK33["addr_w"]:
                addr_bad.append(name)
            if span is not None and addr + span > top:
                addr_bad.append(name)
        if pieces is None and base + h.size > top:
            addr_bad.append(name)
        beat_max = max(beat_max, wbeats(h, h.M))
    print("tensors parsed        %d (%d refused)" % (nfiles, nbad))
    print("lane-striped tensors  %d of %d" % (nstriped, nfiles))
    print("sub-region bases read %d" % nbase)
    print("bases not 4 KB aligned %d" % len(align_bad))
    for n, o in align_bad[:5]:
        print("   %s +%d" % (n, o))
    print("bases outside ADDR_W=%d  %d" % (FK33["addr_w"], len(set(addr_bad))))
    print("largest full-tensor w_beats  %d" % beat_max)
    return 1 if (nbad or align_bad or addr_bad) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DescError as e:
        sys.stderr.write("gen_mv4i_desc: %s\n" % e)
        sys.exit(2)
