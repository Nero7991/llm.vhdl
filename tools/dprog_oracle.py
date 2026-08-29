#!/usr/bin/env python3
"""tools/dprog_oracle.py -- a SEQUENCE-level oracle for subsystem D's
descriptor program.

WHAT THIS IS FOR, AND WHY THE EXISTING CHECKS DO NOT COVER IT
============================================================================
`tools/gen_layer_program.py` emits the program and is already checked four
ways (`docs/debugging/2026-08-29_layer-descriptor-program.md` section 5):

  1. byte-identity against `sim/seq_tbl_pkg.vhd`'s table,
  2. byte-identity against `sim/llama_sched_pkg.vhd`'s table,
  3. every A descriptor ACCEPTED by `rtl/matvec_int4_desc_axi.vhd`,
  4. `rtl/llama_top.vhd` executing the emitted table to a bit-identical R_X.

Every one of those is an AGREEMENT check, and all four agree about the same
thing: THE SCHEDULE. (1) and (2) are two more transcriptions of it. (3) asks
only whether a descriptor is WELL FORMED -- the gateware has no idea which
tensor a job should have used. (4) compares a run driven by this program
against a run driven by (2), which is the same schedule again.

So the whole column is compatible with a program that is internally perfect
and computes the wrong model. The write-up says so itself: "What is verified
here is the PROGRAM, not the computation it drives."

This file is the missing axis. It never looks at `gen_layer_program.py`'s
data structures; it decodes the EMITTED BYTES and checks them against two
artefacts that were produced from a DIFFERENT SOURCE by DIFFERENT TRACKS:

  * `tools/ref9b/seam_map.py`  -- the RTL region -> llama.cpp node
    correspondence, in llama.cpp's own execution order, written by TRACK
    REF9B off the reference graph and not off the schedule. This is what
    supplies the ANSWER for "what should the k-th region write be".
  * `manifest.json` of the packed model -- per-tensor M, K, w_exp,
    out_shift, hbm_offset, written by `tools/pack_model_fk33.py` from the
    GGUF. This supplies the ANSWER for "what numbers should that job carry".

The one thing authored HERE is `NODE_OP`, the node-name -> (operation,
tensor) table below. It is a transcription of llama.cpp's graph, keyed by
the node names `seam_map` already publishes, and it is the weakest link in
the chain; it is called out as such in the write-up rather than presented as
independent evidence. Everything else is a comparison between two files that
were written by different code from different inputs.

NOT A ROUND TRIP. The `m7` mutant recorded in CLAUDE.md is an emitter plus
its own decoder passing a self-test. The decoder here is deliberately not
the emitter's: it reads bytes and the answers come from elsewhere. Where the
decoder itself could be wrong in the same way as the emitter, that is stated
in the write-up as a resolution floor, not hidden.

WHAT IT CANNOT DO
============================================================================
It is a STRUCTURAL and BINDING oracle, not a numeric one. It cannot see a
wrong number that is consistent with the manifest, it cannot see anything
about what the arithmetic units then do with a correctly-bound job, and it
has no opinion at all on fields nothing consumes. Section "COVERAGE" of the
write-up enumerates that.

USAGE
============================================================================
    tools/dprog_oracle.py --d-table OUT/d_table.hex --manifest M.json
    tools/dprog_oracle.py --d-table OUT/d_table.hex --adir OUT --layer 0
    tools/dprog_oracle.py --d-table OUT/t.hex --token -v
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "ref9b"))

import seam_map as SM                       # noqa: E402  TRACK REF9B's artefact

DEF_MANIFEST = ("/mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/"
                "manifest.json")

# --------------------------------------------------------------------------
# Constants, read off rtl/llama_map_pkg.vhd:40-104 and NOT off
# gen_layer_program.py, so that a divergence between the generator's copy and
# the RTL is visible here rather than cancelling out.
# --------------------------------------------------------------------------
OP_A_JOB, OP_B_JOB, OP_C_JOB, OP_E_COLL = 0, 1, 2, 3
OP_VEC_NORM, OP_VEC_RES, OP_VEC_SWG, OP_END_TOKEN = 4, 5, 6, 7
OPNAME = {0: "A_JOB", 1: "B_JOB", 2: "C_JOB", 3: "E_COLL",
          4: "VEC_NORM", 5: "VEC_RES", 6: "VEC_SWG", 7: "END_TOKEN"}

RNAME = ["R_X", "R_XN", "R_QKV", "R_Z", "R_BETA", "R_ALPHA", "R_QG",
         "R_KIN", "R_VIN", "R_Y", "R_G", "R_U", "R_H", "R_ER"]
RID = {n: i for i, n in enumerate(RNAME)}
R_NONE = 255

FLG_TO_SMP = 2

# rtl/matvec_int4_desc_axi.vhd:108 and matvec_core.vhd:57.  Read from the RTL
# at runtime by `rtl_maxrows_bfp()` so this cannot go stale silently.
MAXROWS_BFP_FALLBACK = 17408


class OracleError(Exception):
    pass


# ==========================================================================
# 1.  The decoders.  Bytes in, fields out.  Layout from
#     docs/2026-08-28_matvec-descriptor-format.md section 4, cross-checked
#     against rtl/seq_desc_fetch.vhd's own field slicing.
# ==========================================================================
def load_hex_words(path):
    """One 64-bit word per line, hex, index order -- the form
    `sim/tb_llama_top.vhd`'s URAM model and `sim/tb_mv4i_desc_image.vhd`
    read."""
    words = []
    with open(path) as fh:
        for ln, raw in enumerate(fh, 1):
            s = raw.strip()
            if not s or s.startswith("#") or s.startswith("//"):
                continue
            try:
                words.append(int(s, 16))
            except ValueError:
                raise OracleError("%s:%d: not a hex word: %r" % (path, ln, s))
    return words


def _bits(w, hi, lo):
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


def _i32(v):
    return v - (1 << 32) if v >= (1 << 31) else v


class Desc(object):
    """The 64-byte header, words 0..7, decoded.  Shared by the D table entry
    and the subsystem A descriptor -- they are the same 64 bytes, which is
    the whole point of the format."""

    def __init__(self, w, idx=-1):
        if len(w) < 8:
            raise OracleError("descriptor %d: only %d words" % (idx, len(w)))
        self.idx = idx
        self.raw = list(w[:8])
        self.opcode = _bits(w[0], 7, 0)
        self.flags = _bits(w[0], 15, 8)
        self.src = _bits(w[0], 23, 16)
        self.dst = _bits(w[0], 31, 24)
        self.dst_off = _bits(w[0], 63, 32)
        self.n_rows = _bits(w[1], 31, 0)
        self.n_cols = _bits(w[1], 63, 32)
        self.w_exp = _i32(_bits(w[2], 31, 0))
        self.out_shift = _i32(_bits(w[2], 63, 32))
        self.out_mode = _bits(w[3], 7, 0)
        self.ordinal = _bits(w[3], 15, 8)
        self.nsub_w = _bits(w[3], 31, 16)
        self.nsub_s = _bits(w[3], 47, 32)
        self.src2 = _bits(w[3], 55, 48)
        self.pad3 = _bits(w[3], 63, 56)
        self.const_base = _bits(w[4], 31, 0)
        self.const_exp = _i32(_bits(w[4], 63, 32))
        self.cb = (w[5], w[6])
        self.pad7 = w[7]

    @property
    def opname(self):
        return OPNAME.get(self.opcode, "OP?%d" % self.opcode)

    def rname(self, r):
        return "R_NONE" if r == R_NONE else (
            RNAME[r] if r < len(RNAME) else "R?%d" % r)

    def __str__(self):
        return ("%-9s %-7s -> %-7s off=%-6d rows=%-7d cols=%-6d "
                "w_exp=%-3d osh=%-3d ord=%-3d cb=%d"
                % (self.opname, self.rname(self.src), self.rname(self.dst),
                   self.dst_off, self.n_rows, self.n_cols, self.w_exp,
                   self.out_shift, self.ordinal, self.const_base))


def decode_d_table(words):
    """D's table is DENSE at a 64-byte stride: step i's header is at 64-bit
    word 8i (rtl/seq_desc_fetch.vhd:574).  There is no base array between
    steps and there cannot be one."""
    if len(words) % 8:
        raise OracleError("D table has %d words, not a multiple of 8" %
                          len(words))
    return [Desc(words[8 * i:8 * i + 8], i) for i in range(len(words) // 8)]


class ADesc(object):
    """Subsystem A's descriptor: D's header, then the base array at word 8,
    then the four-word extension at 8 + nsub_w + nsub_s.
    `rtl/matvec_int4_desc_pkg.vhd` is the authority for the offsets."""

    EXT_MAGIC = 0x4D563449                      # "MV4I"

    def __init__(self, words, name=""):
        self.name = name
        self.hdr = Desc(words, -1)
        npw, nps = self.hdr.nsub_w, self.hdr.nsub_s
        need = 8 + npw + nps + 4
        if len(words) < need:
            raise OracleError("%s: %d words, needs %d for nsub_w=%d nsub_s=%d"
                              % (name, len(words), need, npw, nps))
        self.w_base = list(words[8:8 + npw])
        self.s_base = list(words[8 + npw:8 + npw + nps])
        e = 8 + npw + nps
        self.ext_magic = _bits(words[e], 31, 0)
        self.ext_version = _bits(words[e], 47, 32)
        self.ext_flags = _bits(words[e], 63, 48)
        self.w_beats = _bits(words[e + 1], 31, 0)
        self.s_beats = _bits(words[e + 1], 63, 32)
        self.x_exp = _i32(_bits(words[e + 2], 31, 0))
        self.ext_pad2 = _bits(words[e + 2], 63, 32)
        self.ext_pad3 = words[e + 3]


# ==========================================================================
# 2.  The ANSWER side.  Where each expectation comes from is named per row,
#     because that provenance is the only thing that makes this an oracle
#     rather than a second opinion from the same source.
# ==========================================================================
#
# NODE_OP: llama.cpp node base-name -> (opcode, tensor-template).
#
# Keyed by the node names `tools/ref9b/seam_map.py` publishes.  A tensor
# template of None means the step consumes no packed matvec tensor, so there
# is nothing in the manifest to bind it to.  This table is a transcription of
# llama.cpp's graph and is the ONE authored artefact in this file.
NODE_OP = {
    # ---- shared, both block kinds
    "attn_norm":              (OP_VEC_NORM, None),
    "attn_residual":          (OP_VEC_RES,  None),
    "attn_post_norm":         (OP_VEC_NORM, None),
    "ffn_gate":               (OP_A_JOB,    "blk.%d.ffn_gate.weight"),
    "ffn_up":                 (OP_A_JOB,    "blk.%d.ffn_up.weight"),
    "ffn_swiglu":             (OP_VEC_SWG,  None),
    "ffn_out":                (OP_A_JOB,    "blk.%d.ffn_down.weight"),
    "l_out":                  (OP_VEC_RES,  None),
    # ---- gated-attention block
    "Qcur_full":              (OP_A_JOB,    "blk.%d.attn_q.weight"),
    "Kcur":                   (OP_A_JOB,    "blk.%d.attn_k.weight"),
    "Vcur":                   (OP_A_JOB,    "blk.%d.attn_v.weight"),
    "attn_gated":             (OP_C_JOB,    None),
    "attn_output":            (OP_A_JOB,    "blk.%d.attn_output.weight"),
    # ---- Gated DeltaNet block
    "linear_attn_qkv_mixed":  (OP_A_JOB,    "blk.%d.attn_qkv.weight"),
    "z":                      (OP_A_JOB,    "blk.%d.attn_gate.weight"),
    "beta":                   (OP_A_JOB,    "blk.%d.ssm_beta.weight"),
    "alpha":                  (OP_A_JOB,    "blk.%d.ssm_alpha.weight"),
    "final_output":           (OP_B_JOB,    None),
    "linear_attn_out":        (OP_A_JOB,    "blk.%d.ssm_out.weight"),
    # ---- token tail
    "result_norm":            (OP_VEC_NORM, None),
    "result_output":          (OP_A_JOB,    "output.weight"),
}

# The region each seam writes.  `seam_map`'s left-hand names already carry it
# ("R_XN.ffn-7" -> R_XN), so this is a parse, not a second table.
SEAM_RE = re.compile(r"^R_([A-Z]+)(\.[a-z]+)?-?(\d+|final|embed)?$")


def seam_region(rtl_name):
    if rtl_name == "LOGITS":
        return None                      # streamed to the sampler, no region
    base = rtl_name.split(".")[0].split("-")[0]
    if base not in RID:
        raise OracleError("seam_map name %r has no region" % rtl_name)
    return RID[base]


def seam_layer(rtl_name):
    m = re.search(r"-(\d+)$", rtl_name)
    return int(m.group(1)) if m else None


def node_base(anchor):
    """`ffn_gate-7` -> ("ffn_gate", 7);  `result_norm` -> ("result_norm",
    None)."""
    m = re.match(r"^(.*?)-(\d+)$", anchor)
    if m:
        return m.group(1), int(m.group(2))
    return anchor, None


# --------------------------------------------------------------------------
def rtl_maxrows_bfp(repo=None):
    """MEASURED from the RTL rather than quoted, because the whole lm_head
    window count hangs off it."""
    repo = repo or os.path.dirname(HERE)
    p = os.path.join(repo, "rtl", "matvec_int4_desc_axi.vhd")
    try:
        with open(p) as fh:
            for line in fh:
                m = re.search(r"MAXROWS_BFP\s*:\s*positive\s*:=\s*(\d+)", line)
                if m:
                    return int(m.group(1))
    except IOError:
        pass
    return MAXROWS_BFP_FALLBACK


MV4I_HDR_BYTES = 4096                        # ref/matvec_int4.c:42, spec 6.4
MV4I_MAGIC = 0x4D563449


def read_mv4i_header(path):
    """The packed tensor's own 4 KB header.  Field offsets are
    `ref/matvec_int4.c:161-240`, the reference parser, so this reads what the
    reference reads and not what a document says it should.

    Only the first 4 KB of the file is touched, so this is cheap even across
    all 250 tensors of a 5 GB packed set."""
    try:
        with open(path, "rb") as fh:
            p = fh.read(MV4I_HDR_BYTES)
    except IOError:
        return None
    if len(p) < MV4I_HDR_BYTES:
        return None
    u16 = lambda o: int.from_bytes(p[o:o + 2], "little")      # noqa: E731
    u32 = lambda o: int.from_bytes(p[o:o + 4], "little")      # noqa: E731
    u64 = lambda o: int.from_bytes(p[o:o + 8], "little")      # noqa: E731
    if u32(0x00) != MV4I_MAGIC:
        return None
    npw = u16(0x1A)
    nss = u32(0x34)
    h = {
        "version": u16(0x04), "flags": u16(0x06),
        "M": u32(0x08), "K": u32(0x0C),
        "w_exp": _i32(u32(0x10)), "out_shift": _i32(u32(0x14)),
        "rows_if": u16(0x18), "nports_w": npw, "block": u16(0x1C),
        "axi_dw": u16(0x1E) or 128,
        "codebook": p[0x20:0x30],
        "scale_offset": u32(0x30), "n_scale_sub": nss,
    }
    h["w_sub"] = [u64(0x38 + 8 * i) for i in range(npw)]
    h["s_sub"] = ([u64(0x38 + 8 * npw + 8 * i) for i in range(nss)]
                  if nss else [h["scale_offset"]])
    return h


def lm_windows(vocab, rows_if, maxrows):
    """Derived HERE, from the RTL bound and the manifest geometry, NOT by
    calling `tools/gen_lmhead_windows.py` -- that module is what the
    generator uses, so calling it would make this a round trip on exactly
    the arithmetic the brief asked to be verified.

    A window may only START on a tile boundary, so the usable stride is
    floor(maxrows/rows_if)*rows_if, not maxrows."""
    stride = (maxrows // rows_if) * rows_if
    wins, r = [], 0
    while r < vocab:
        wins.append((r, min(stride, vocab - r)))
        r += stride
    return wins, stride


# ==========================================================================
# 3.  The oracle proper.
# ==========================================================================
class Oracle(object):

    def __init__(self, manifest_path, verbose=False):
        with open(manifest_path) as fh:
            self.man = json.load(fh)
        self.pack_dir = os.path.dirname(os.path.abspath(manifest_path))
        self.geom = self.man["geometry"]
        self.rows_if = self.geom["rows_if"]
        self.nports_w = self.geom["nports_w"]
        self.nports_s = self.geom["n_scale_sub"]
        self.qkv_pad = bool(self.geom.get("qkv_segment_pad"))
        self.T = {f["tensor"]: f for f in self.man["files"]
                  if f.get("kind") == "mv4i"}
        self.verbose = verbose
        self.fails = []
        self.checks = 0

        # Dimensions DERIVED from the packed tensors, not from
        # model_cfg_pkg.vhd and not from the generator's Shape class.
        self.hidden = self.T["blk.0.ffn_gate.weight"]["K"]
        self.ffn = self.T["blk.0.ffn_gate.weight"]["M"]
        self.vocab = self.T["output.weight"]["M"]
        self.maxrows = rtl_maxrows_bfp()

    # ---------------------------------------------------------------- utils
    def ck(self, cond, tag, msg):
        self.checks += 1
        if not cond:
            self.fails.append((tag, msg))
        return cond

    def note(self, s):
        if self.verbose:
            print("    " + s)

    # ------------------------------------------------- the expected sequence
    def expected(self, layers=None, expand_lm=True):
        """The seam sequence this program must realise, from
        `tools/ref9b/seam_map.SEAMS`.

        Two edits, both forced and both stated:
          * `R_X.embed` is dropped: it is a HOST write of the embedding, not
            a descriptor step (TRACK TOKIO's finding, and `seq_opdec`'s
            `tok_fsm` exists to publish it).
          * `LOGITS` becomes N row windows, because MAXROWS_BFP bounds
            n_rows in EVERY out_mode (matvec_int4_desc_axi:721-726).  The
            window list is derived here from the RTL bound; that derivation
            is itself one of the things being checked."""
        out = []
        for rtl, anchor, off, ln in SM.SEAMS:
            if rtl == "R_X.embed":
                continue
            if rtl == "LOGITS":
                if layers is not None:
                    continue           # the lm_head is not part of any layer
                if not expand_lm:
                    out.append((rtl, anchor, off, ln))
                    continue
                wins, _ = lm_windows(self.vocab, self.rows_if, self.maxrows)
                for (rs, nr) in wins:
                    out.append(("LOGITS", anchor, rs, nr))
                continue
            L = seam_layer(rtl)
            if layers is not None and L is not None and L not in layers:
                continue
            if layers is not None and L is None:
                continue
            out.append((rtl, anchor, off, ln))
        return out

    # ------------------------------------------------- what a step writes
    def writes(self, d):
        """A step is a seam iff it writes a region or streams the logits."""
        if d.opcode == OP_END_TOKEN:
            return False
        if d.dst != R_NONE:
            return True
        return bool(d.flags & FLG_TO_SMP)

    # ------------------------------------------------------------ CHECK C1
    def check_sequence(self, steps, layers=None):
        """C1: the ORDER and REGION IDENTITY of every write, against
        llama.cpp's execution order.

        This is the check the four existing ones cannot make: it asks what
        the program MEANS, not whether two transcriptions of it agree."""
        exp = self.expected(layers=layers)
        got = [d for d in steps if self.writes(d)]
        self.ck(len(got) == len(exp), "C1-count",
                "program writes %d regions, llama.cpp's graph has %d seams"
                % (len(got), len(exp)))
        pairs = []
        for i, (e, d) in enumerate(zip(exp, got)):
            rtl, anchor, off, ln = e
            want_r = seam_region(rtl)
            if want_r is None:                      # LOGITS
                self.ck(d.dst == R_NONE and (d.flags & FLG_TO_SMP),
                        "C1-logits",
                        "seam %d %s: expected a sampler stream, got dst=%s "
                        "flags=0x%x" % (i, anchor, d.rname(d.dst), d.flags))
            else:
                self.ck(d.dst == want_r, "C1-region",
                        "seam %d (%s <- %s): expected write to %s, program "
                        "writes %s" % (i, rtl, anchor, RNAME[want_r],
                                       d.rname(d.dst)))
            base, L = node_base(anchor)
            want_op, tmpl = NODE_OP.get(base, (None, None))
            self.ck(want_op is not None, "C1-node",
                    "seam %d: node %r is not in NODE_OP" % (i, anchor))
            if want_op is not None:
                self.ck(d.opcode == want_op, "C1-op",
                        "seam %d (%s): llama.cpp node %s is a %s, program "
                        "step %d is a %s" % (i, rtl, anchor,
                                             OPNAME[want_op], d.idx, d.opname))
            pairs.append((e, d, tmpl, L))
        return pairs

    # ------------------------------------------------------------ CHECK C2
    def check_offsets(self, pairs):
        """C2: `dst_offset` against llama.cpp's own segment offsets.

        Only `seam_map` states these, and only for R_QKV, where it carries
        the (offset, length) of each of q / k / v inside the fused node.
        Those numbers are llama.cpp's (0 / 2048 / 4096), and they are NOT the
        packed row starts (0 / 2064 / 4128, tile-padded by TRACK QKV-PAD) --
        a program that confuses the two is exactly the defect this check
        exists for."""
        for (rtl, anchor, off, ln), d, tmpl, L in pairs:
            if not rtl.startswith("R_QKV"):
                continue
            self.ck(d.dst_off == off, "C2-dstoff",
                    "%s: llama.cpp segment starts at element %d, descriptor "
                    "says dst_offset=%d" % (rtl, off, d.dst_off))
            self.ck(d.n_rows == ln, "C2-seglen",
                    "%s: llama.cpp segment is %d elements, descriptor says "
                    "n_rows=%d" % (rtl, ln, d.n_rows))

    # ------------------------------------------------------------ CHECK C3/4
    def check_binding(self, pairs):
        """C3: shape, and C4: exponents -- both against the MANIFEST entry of
        the tensor llama.cpp's graph says this seam uses.

        This is where a step bound to the WRONG TENSOR dies, and it is the
        program-level form of the defect section 6.2 of the layer-program
        write-up records as undetectable by the gateware: two well-formed
        descriptors differing only in which weights they name."""
        for (rtl, anchor, off, ln), d, tmpl, L in pairs:
            if tmpl is None:
                continue
            name = tmpl % L if "%d" in tmpl else tmpl
            f = self.T.get(name)
            if not self.ck(f is not None, "C3-tensor",
                           "%s: manifest has no tensor %s" % (rtl, name)):
                continue
            self.ck(d.n_cols == f["K"], "C3-ncols",
                    "%s (%s): manifest K=%d, descriptor n_cols=%d"
                    % (rtl, name, f["K"], d.n_cols))
            # n_rows is the tensor's M except where the seam is a WINDOW of
            # it: the three qkv segments, and the lm_head's row windows.
            if rtl.startswith("R_QKV"):
                pass                                  # covered by C2
            elif rtl == "LOGITS":
                self.ck(d.n_rows == ln, "C3-lmwin",
                        "lm_head window at row %d: expected %d rows, "
                        "descriptor says %d" % (off, ln, d.n_rows))
                self.ck(d.n_rows <= self.maxrows, "C3-maxrows",
                        "lm_head window has %d rows, MAXROWS_BFP is %d -- "
                        "matvec_int4_desc_axi refuses this in EVERY out_mode"
                        % (d.n_rows, self.maxrows))
            else:
                self.ck(d.n_rows == f["M"], "C3-nrows",
                        "%s (%s): manifest M=%d, descriptor n_rows=%d"
                        % (rtl, name, f["M"], d.n_rows))
            self.ck(d.w_exp == f["w_exp"], "C4-wexp",
                    "%s (%s): manifest w_exp=%d, descriptor w_exp=%d"
                    % (rtl, name, f["w_exp"], d.w_exp))
            self.ck(d.out_shift == f["out_shift"], "C4-outshift",
                    "%s (%s): manifest out_shift=%d, descriptor out_shift=%d"
                    % (rtl, name, f["out_shift"], d.out_shift))

    # ------------------------------------------------------------ CHECK C5
    def check_layer_index(self, pairs):
        """C5: `ordinal` and `const_base` against the LAYER the seam belongs
        to, which comes from `seam_map`'s own `-L` suffix.

        `const_base` is inert in `llama_top` today (mutations 4b and 11 of
        the layer-program write-up pass silently), so nothing else in the
        repository can see it.

        `ordinal` is NOT inert on a B or C job -- it reaches the unit as the
        layer index, and mutation 4 changed the answer.  Until 2026-08-29 it
        reached a consumer that read it as the BLOCK index and re-derived a
        layer (`rtl/llama_top.vhd:2992`, `:3799`), so THIS CHECK WAS THE ONLY
        SITE IN THE TREE THAT AGREED WITH THE SPEC: the RTL and
        `sim/llama_sched_pkg.vhd` agreed with each other on the other
        convention and the disagreement was invisible from either.  Defect
        ORD-1, `docs/debugging/2026-08-29_ordinal-two-meanings.md`; the RTL
        now takes the ordinal and derives nothing."""
        # A B/C job's ordinal is its index among blocks OF THAT KIND, which
        # is a property of the block sequence and not of the step: derived
        # here by counting, from seam_map's layer numbering alone.
        n_b = n_c = 0
        for (rtl, anchor, off, ln), d, tmpl, L in pairs:
            base, _ = node_base(anchor)
            if d.opcode == OP_B_JOB:
                self.ck(d.ordinal == n_b, "C5-ordinal-B",
                        "layer %d B_JOB: it is GDN block %d, descriptor "
                        "ordinal=%d" % (L, n_b, d.ordinal))
                n_b += 1
            elif d.opcode == OP_C_JOB:
                self.ck(d.ordinal == n_c, "C5-ordinal-C",
                        "layer %d C_JOB: it is attention block %d, "
                        "descriptor ordinal=%d" % (L, n_c, d.ordinal))
                n_c += 1
            elif d.opcode == OP_VEC_NORM and L is not None:
                self.ck(d.const_base == L, "C5-constbase",
                        "%s: seam is layer %d, descriptor const_base=%d "
                        "(the norm-weight selector)" % (rtl, L, d.const_base))
                # CONVENTION, not derivation, and labelled as such: `ordinal`
                # is an 8-bit field and every generator in the repository
                # stamps `blk mod 64` on a block norm.  Only the TAIL norm is
                # contested (`seq_tbl_pkg` says 0, `llama_sched_pkg` says
                # blocks mod 64), and the tail has no layer number so it is
                # not reached here.  Weaker evidence than the rest of this
                # file; it is here because the field is otherwise checked by
                # nothing at all.
                self.ck(d.ordinal == L % 64, "C5-ordinal-NORM",
                        "%s: seam is layer %d, so the norm-weight ordinal "
                        "should be %d; descriptor says %d"
                        % (rtl, L, L % 64, d.ordinal))

    # ------------------------------------------------------------ CHECK C6
    def check_static(self, steps):
        """C6: the things the FORMAT fixes, independent of the model."""
        self.ck(bool(steps), "C6-empty", "the table has no steps")
        if not steps:
            return
        last = steps[-1]
        self.ck(last.opcode == OP_END_TOKEN, "C6-end",
                "the table's last step is %s; seq_desc_fetch enforces "
                "END_TOKEN-last in hardware" % last.opname)
        for d in steps[:-1]:
            self.ck(d.opcode != OP_END_TOKEN, "C6-end2",
                    "step %d is an END_TOKEN and is not last" % d.idx)
        for d in steps:
            self.ck(d.pad3 == 0, "C6-pad3",
                    "step %d: word 3 [63:56] is 0x%02x, must be 0 "
                    "(seq_desc_fetch ERR_DESC)" % (d.idx, d.pad3))
            self.ck(d.pad7 == 0, "C6-pad7",
                    "step %d: word 7 is 0x%016x, must be 0" % (d.idx, d.pad7))
            if d.opcode == OP_A_JOB:
                self.ck(d.nsub_w == self.nports_w, "C6-nsubw",
                        "step %d: nsub_w=%d, the manifest geometry packs %d "
                        "weight sub-regions -- the FK33 A wrapper refuses a "
                        "mismatch with ERR_GEOM" % (d.idx, d.nsub_w,
                                                    self.nports_w))
                self.ck(d.nsub_s == self.nports_s, "C6-nsubs",
                        "step %d: nsub_s=%d, manifest packs %d"
                        % (d.idx, d.nsub_s, self.nports_s))

    # ------------------------------------------------------------ CHECK C7
    def check_dataflow(self, pairs):
        """C7: every step's SOURCE region is the region whose most recent
        writer is the llama.cpp node that feeds this one.

        The edges come from llama.cpp's graph as `seam_map` names it, so a
        step reading a live-but-wrong region -- mutation 5, which the layer
        program write-up could only catch with a reference PROGRAM to diff
        against -- is a failure here with no reference run at all."""
        # llama.cpp node -> the node(s) it consumes.  Transcribed from the
        # graph, keyed by seam_map's names.  `None` = a host or unit input
        # that is not a region read.
        FEED = {
            "attn_norm":             ["l_out_prev"],
            "Qcur_full":             ["attn_norm"],
            "Kcur":                  ["attn_norm"],
            "Vcur":                  ["attn_norm"],
            "attn_gated":            ["Qcur_full"],
            "attn_output":           ["attn_gated"],
            "linear_attn_qkv_mixed": ["attn_norm"],
            "z":                     ["attn_norm"],
            "beta":                  ["attn_norm"],
            "alpha":                 ["attn_norm"],
            "final_output":          ["linear_attn_qkv_mixed"],
            "linear_attn_out":       ["final_output"],
            "attn_residual":         ["l_out_prev", "attn_output_or_out"],
            "attn_post_norm":        ["attn_residual"],
            "ffn_gate":              ["attn_post_norm"],
            "ffn_up":                ["attn_post_norm"],
            "ffn_swiglu":            ["ffn_gate", "ffn_up"],
            "ffn_out":               ["ffn_swiglu"],
            "l_out":                 ["attn_residual", "ffn_out"],
            "result_norm":           ["l_out_prev"],
            "result_output":         ["result_norm"],
        }
        # region written by each node base, for resolving a feed to a region
        NODE_R = {}
        for (rtl, anchor, off, ln), d, tmpl, L in pairs:
            base, _ = node_base(anchor)
            NODE_R.setdefault(base, seam_region(rtl))

        def rof(base):
            if base == "l_out_prev":
                return RID["R_X"]
            if base == "attn_output_or_out":
                return RID["R_ER"]
            return NODE_R.get(base)

        for (rtl, anchor, off, ln), d, tmpl, L in pairs:
            base, _ = node_base(anchor)
            feed = FEED.get(base)
            if not feed:
                continue
            want = rof(feed[0])
            if want is None:
                continue
            self.ck(d.src == want, "C7-src",
                    "%s: llama.cpp node %s consumes %s, so the step must "
                    "read %s; descriptor reads %s"
                    % (rtl, base, feed[0], RNAME[want], d.rname(d.src)))
            if len(feed) > 1 and d.opcode in (OP_VEC_RES, OP_VEC_SWG):
                want2 = rof(feed[1])
                if want2 is not None:
                    self.ck(d.src2 == want2, "C7-src2",
                            "%s: second operand should be %s, descriptor "
                            "says %s" % (rtl, RNAME[want2], d.rname(d.src2)))

    # ------------------------------------------------------------ CHECK C8
    def check_a_descriptors(self, pairs, adir):
        """C8: the D step <-> A descriptor BINDING.

        Section 6.2 of the layer-program write-up measured that the gateware
        accepts, silently, an A descriptor whose 27 bases belong to a
        DIFFERENT step: 'nothing binds an A descriptor to the step it belongs
        to'.  Nothing on the card can close that.  This closes it at the
        host, by requiring every A descriptor to agree with its D step on the
        header AND to point at the manifest `hbm_offset` of the tensor
        llama.cpp's graph says that step uses."""
        files = sorted(f for f in os.listdir(adir) if f.startswith("a")
                       and f.endswith(".hex"))
        if not files:
            self.ck(False, "C8-none", "no a*.hex descriptors in %s" % adir)
            return
        byidx = {}
        for fn in files:
            m = re.match(r"^a(\d+)_(.*)\.hex$", fn)
            if not m:
                continue
            byidx[int(m.group(1))] = (fn, m.group(2))
        for (rtl, anchor, off, ln), d, tmpl, L in pairs:
            if d.opcode != OP_A_JOB or tmpl is None:
                continue
            ent = byidx.get(d.idx)
            if not self.ck(ent is not None, "C8-missing",
                           "step %d (%s) is an A_JOB with no a%02d_*.hex"
                           % (d.idx, rtl, d.idx)):
                continue
            fn, fname_tensor = ent
            name = tmpl % L if "%d" in tmpl else tmpl
            # (a) the FILE NAME claims a tensor.  llama.cpp's graph says
            #     which one it must be.  A generator that emitted the right
            #     bytes under the wrong step index dies here.
            self.ck(fname_tensor == name, "C8-name",
                    "step %d (%s): llama.cpp says this seam uses %s, the "
                    "descriptor file is %s" % (d.idx, rtl, name, fn))
            a = ADesc(load_hex_words(os.path.join(adir, fn)), fn)
            # (b) header agreement, field by field
            for fld in ("opcode", "src", "dst", "dst_off", "n_rows",
                        "n_cols", "w_exp", "out_shift", "out_mode",
                        "nsub_w", "nsub_s"):
                self.ck(getattr(a.hdr, fld) == getattr(d, fld),
                        "C8-hdr",
                        "step %d (%s): D table %s=%r, A descriptor %s=%r"
                        % (d.idx, fn, fld, getattr(d, fld), fld,
                           getattr(a.hdr, fld)))
            # (c) the extension
            self.ck(a.ext_magic == ADesc.EXT_MAGIC, "C8-magic",
                    "%s: ext_magic 0x%08x, expected 0x%08x -- the extension "
                    "lands at 0x40+8*(nsub_w+nsub_s), so a wrong magic means "
                    "the generator and the build disagree about the geometry"
                    % (fn, a.ext_magic, ADesc.EXT_MAGIC))
            self.ck(a.ext_version == 1, "C8-ver",
                    "%s: ext_version %d, expected 1" % (fn, a.ext_version))
            self.ck(a.ext_flags == 0 and a.ext_pad2 == 0 and a.ext_pad3 == 0,
                    "C8-extpad", "%s: reserved extension bytes are not 0"
                    % fn)
            # (d) THE BINDING.  Base 0 must be the manifest's own byte
            #     address for this tensor.  This is what makes "the ffn_up
            #     step's bases pasted into the ffn_gate step" a failure.
            f = self.T.get(name)
            if f is None:
                continue
            self.ck(len(a.w_base) == self.nports_w, "C8-nbase",
                    "%s: %d weight bases, geometry packs %d"
                    % (fn, len(a.w_base), self.nports_w))
            for i, b in enumerate(a.w_base + a.s_base):
                self.ck(b % 4096 == 0, "C8-align",
                        "%s: base[%d] = 0x%X is not 4 KB aligned "
                        "(axi_rd_port's contract)" % (fn, i, b))
            hi = f["hbm_offset"] + f["nbytes"]
            for i, b in enumerate(a.w_base + a.s_base):
                self.ck(f["hbm_offset"] <= b < hi, "C8-range",
                        "%s: base[%d] = 0x%X is outside %s's own bytes "
                        "[0x%X, 0x%X)" % (fn, i, b, name,
                                          f["hbm_offset"], hi))
            self.check_against_packed(a, fn, name, f, rtl, off, d)

    # ------------------------------------------------------------ CHECK C9
    def check_against_packed(self, a, fn, name, f, rtl, seg_off, d):
        """C9: the A descriptor against the PACKED FILE'S OWN 4 KB HEADER.

        This is the strongest link in the file, and the only one where both
        sides are bytes written by different programs from different inputs:
        the `.mv4i` header was written by `tools/pack_int4.py` out of the
        GGUF, and it carries `M`, `K`, `w_exp`, `out_shift`, the geometry,
        the CODEBOOK, and -- at 0x38 -- the sub-region offset TABLE that
        every weight base must be derived from.  Layout from
        `ref/matvec_int4.c:161-240`, which is the reference parser.

        `w_base[p] == hbm_offset + w_sub_offset[p] + delta`, where `delta` is
        the row window's byte offset inside a sub-region, DERIVED from the
        window's first row rather than taken from the generator (`row_start`
        is not a descriptor field at all, which is the silent-pass TRACK
        QKV-PAD recorded)."""
        path = os.path.join(self.pack_dir, f["file"])
        h = read_mv4i_header(path)
        if h is None:
            self.ck(False, "C9-open", "%s: cannot read %s" % (fn, path))
            return
        self.ck(h["K"] == a.hdr.n_cols, "C9-K",
                "%s: packed file says K=%d, descriptor n_cols=%d"
                % (fn, h["K"], a.hdr.n_cols))
        self.ck(h["w_exp"] == a.hdr.w_exp, "C9-wexp",
                "%s: packed file header w_exp=%d, descriptor w_exp=%d"
                % (fn, h["w_exp"], a.hdr.w_exp))
        self.ck(h["out_shift"] == a.hdr.out_shift, "C9-outshift",
                "%s: packed file header out_shift=%d, descriptor "
                "out_shift=%d" % (fn, h["out_shift"], a.hdr.out_shift))
        self.ck(h["rows_if"] == self.rows_if, "C9-rowsif",
                "%s: packed file rows_if=%d, manifest geometry %d"
                % (fn, h["rows_if"], self.rows_if))
        self.ck(h["nports_w"] == a.hdr.nsub_w, "C9-nsubw",
                "%s: packed file nports_w=%d, descriptor nsub_w=%d"
                % (fn, h["nports_w"], a.hdr.nsub_w))
        self.ck(h["n_scale_sub"] == a.hdr.nsub_s, "C9-nsubs",
                "%s: packed file n_scale_sub=%d, descriptor nsub_s=%d"
                % (fn, h["n_scale_sub"], a.hdr.nsub_s))
        # THE CODEBOOK TRAVELS IN THE FILE (ref/matvec_int4.c:183).  Nothing
        # else in the repository compares it against the descriptor's copy,
        # and flags bit 2 makes the descriptor's copy the one that is loaded.
        cb = (a.hdr.cb[0] | (a.hdr.cb[1] << 64)).to_bytes(16, "little")
        self.ck(cb == h["codebook"], "C9-codebook",
                "%s: descriptor words 5..6 carry codebook %s, the packed "
                "file carries %s -- with flags bit 2 set this LOADS the "
                "wrong codebook" % (fn, cb.hex(), h["codebook"].hex()))
        # w_beats / s_beats.  DERIVED from the shape exactly as
        # `docs/2026-08-28_matvec-descriptor-format.md` section 2.1 states it:
        # ceil(n_rows/ROWS_IF) * ceil(n_cols/BLK), further divided by GRP for
        # the scales, with GRP = n_scale_sub*AXI_DW/(ROWS_IF*16)
        # (ref/matvec_int4.c:136).  The gateware already refuses a mismatch
        # with ERR_SHAPE, so this is not new coverage -- it moves the refusal
        # to the host, where it costs a second instead of a card round trip.
        blk = self.geom.get("block", 32)
        j_tiles = (a.hdr.n_rows + self.rows_if - 1) // self.rows_if
        j_nblk = (a.hdr.n_cols + blk - 1) // blk
        want_w = j_tiles * j_nblk
        self.ck(a.w_beats == want_w, "C9-wbeats",
                "%s: n_rows=%d n_cols=%d gives ceil(%d/%d)*ceil(%d/%d) = %d "
                "beats, descriptor says w_beats=%d (the gateware refuses this "
                "with ERR_SHAPE)"
                % (fn, a.hdr.n_rows, a.hdr.n_cols, a.hdr.n_rows,
                   self.rows_if, a.hdr.n_cols, blk, want_w, a.w_beats))
        sw = self.rows_if * 16
        grp = (h["n_scale_sub"] * h["axi_dw"] // sw) if sw else 0
        if grp:
            self.ck(a.s_beats == want_w // grp, "C9-sbeats",
                    "%s: GRP = %d*%d/(%d*16) = %d, so s_beats should be %d; "
                    "descriptor says %d"
                    % (fn, h["n_scale_sub"], h["axi_dw"], self.rows_if, grp,
                       want_w // grp, a.s_beats))
        # ---- the bases, exactly, from the file's own offset table
        tiles = (h["M"] + self.rows_if - 1) // self.rows_if
        row_start = self.expected_row_start(rtl, seg_off, d, h)
        if row_start is None or tiles == 0 or len(h["w_sub"]) < 2:
            return
        stride = h["w_sub"][1] - h["w_sub"][0]
        if stride % tiles:
            return                       # not a uniform tile layout; skip
        delta = (row_start // self.rows_if) * (stride // tiles)
        base = f["hbm_offset"]
        for p, off in enumerate(h["w_sub"][:len(a.w_base)]):
            self.ck(a.w_base[p] == base + off + delta, "C9-wbase",
                    "%s: w_base[%d] = 0x%X, the packed file's own offset "
                    "table plus the row-%d window says 0x%X"
                    % (fn, p, a.w_base[p], row_start, base + off + delta))
        s_stride = (h["s_sub"][1] - h["s_sub"][0]) if len(h["s_sub"]) > 1 else 0
        s_delta = ((row_start // self.rows_if) * (s_stride // tiles)
                   if s_stride and s_stride % tiles == 0 else 0)
        for q, off in enumerate(h["s_sub"][:len(a.s_base)]):
            self.ck(a.s_base[q] == base + off + s_delta, "C9-sbase",
                    "%s: s_base[%d] = 0x%X, the packed file's own scale "
                    "offset table says 0x%X"
                    % (fn, q, a.s_base[q], base + off + s_delta))

    def expected_row_start(self, rtl, seg_off, d, h):
        """The PACKED first row of this job's window, DERIVED.

        For a whole-tensor job it is 0.  For a qkv segment it is llama.cpp's
        element offset rounded UP to a tile boundary, which is TRACK
        QKV-PAD's rule; for an lm_head window it is the window start this
        file derived from MAXROWS_BFP.  In no case does it come from the
        generator, and `row_start` is not a descriptor field, so this is the
        only way to check the bases at all."""
        r = self.rows_if
        if rtl.startswith("R_QKV"):
            return ((seg_off + r - 1) // r) * r
        if rtl == "LOGITS":
            return seg_off
        return 0

    # ---------------------------------------------------------------- driver
    def run(self, d_table, adir=None, layers=None):
        steps = decode_d_table(load_hex_words(d_table))
        if self.verbose:
            for d in steps:
                print("  %3d %s" % (d.idx, d))
        self.check_static(steps)
        pairs = self.check_sequence(steps, layers=layers)
        self.check_offsets(pairs)
        self.check_binding(pairs)
        self.check_layer_index(pairs)
        self.check_dataflow(pairs)
        if adir:
            self.check_a_descriptors(pairs, adir)
        return steps, pairs


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="sequence-level oracle for subsystem D's descriptor "
                    "program: the emitted BYTES against llama.cpp's graph "
                    "order and the packed model's manifest")
    ap.add_argument("--d-table", required=True)
    ap.add_argument("--adir", help="directory of a*.hex A descriptors")
    ap.add_argument("--manifest", default=DEF_MANIFEST)
    ap.add_argument("--layer", type=int, action="append",
                    help="restrict to this transformer block (repeatable). "
                         "A layer slice has no END_TOKEN unless the program "
                         "was emitted with --close-token")
    ap.add_argument("--token", action="store_true",
                    help="the whole token (the default)")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--max-report", type=int, default=25)
    a = ap.parse_args(argv)

    layers = set(a.layer) if a.layer else None
    o = Oracle(a.manifest, verbose=a.verbose)
    print("dprog_oracle: MAXROWS_BFP=%d (read from rtl/), ROWS_IF=%d, "
          "hidden=%d ffn=%d vocab=%d" % (o.maxrows, o.rows_if, o.hidden,
                                         o.ffn, o.vocab))
    wins, stride = lm_windows(o.vocab, o.rows_if, o.maxrows)
    print("dprog_oracle: lm_head derives to %d windows at stride %d"
          % (len(wins), stride))
    try:
        steps, pairs = o.run(a.d_table, adir=a.adir, layers=layers)
    except OracleError as e:
        print("ORACLE ERROR: %s" % e)
        return 2

    seen = {}
    for tag, msg in o.fails:
        seen[tag] = seen.get(tag, 0) + 1
    print("dprog_oracle: %d steps, %d checks, %d FAIL"
          % (len(steps), o.checks, len(o.fails)))
    for tag, msg in o.fails[:a.max_report]:
        print("  FAIL %-14s %s" % (tag, msg))
    if len(o.fails) > a.max_report:
        print("  ... %d more" % (len(o.fails) - a.max_report))
    if seen:
        print("  by check: " + ", ".join("%s=%d" % kv
                                         for kv in sorted(seen.items())))
    print("DPROG_ORACLE: %s" % ("PASS" if not o.fails else "FAIL"))
    return 0 if not o.fails else 1


if __name__ == "__main__":
    sys.exit(main())
