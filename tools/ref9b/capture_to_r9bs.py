#!/usr/bin/env python3
"""Turn a textual seam capture into a .r9bs stream, so `--mode exact` can be
used against a simulation or a card.

WHY THIS EXISTS.  `seam_bisect.py --mode exact` is the sharper of the two
comparison modes -- MEASURED 2026-08-29, it located 8 of 9 mutants against 6 of
9 for the float-anchor mode, and for one of them it named a seam a whole block
earlier.  But it is useless until something OTHER than ref/run9b.c can write the
format, and neither a GHDL testbench nor the FK33 host driver is going to emit
a binary struct.  Both can emit lines of text.  This is that bridge.

WHAT IT IS NOT.  It is a format converter and nothing more.  Checking it by
rendering a stream to text and converting it back is a ROUND TRIP, and a round
trip is not an oracle -- self-consistency passes for a wrong-but-consistent
implementation, which is the `m7` mutant this project has on record.  The round
trip is still worth running (`--selftest`), because it prices the parser at
zero before anything is claimed; it just is not evidence that the CAPTURE is
right.  The only thing that can establish that is a capture whose seam the
hardware and the reference are both known to compute, compared element by
element -- which is what the whole harness is for.

THE TEXT FORMAT.  Line-oriented, `#` comments and blank lines ignored, so a
GHDL `report ... severity note` transcript can be fed in after grepping for the
prefix.  One record is a header line followed by its values, whitespace
separated, any number per line:

    SEAM <name> <tok> <layer> <kind> <exp> <n>
    <v0> <v1> ... <v(n-1)>

  <kind>   `bfp16` or `f32`
  <exp>    for bfp16, the SHARED exponent, with value = mant * 2^-exp.  Note
           the NEGATIVE power: tools/pack_int4.py:14 fixes that convention for
           the whole project and getting its sign backwards produces a stream
           that is wrong by 2^(2*exp) and looks structurally perfect.  Write 0
           for f32.
  <layer>  -1 for a whole-model seam.
  values   bfp16: signed decimal int16 mantissas.  f32: anything float()
           accepts.

Names must be the RTL seam names in tools/ref9b/seam_map.py (`R_XN-0`,
`R_QKV.k-0`, `R_X-31`, ...), because that is what the bisect walks.  A name the
map does not know is carried through and simply never compared, which is
silent, so `--check-names` refuses it instead.

usage:
    capture_to_r9bs.py capture.txt -o capture.r9bs [--check-names]
    capture_to_r9bs.py --from-r9bs ref.r9bs -o ref.txt        # render to text
    capture_to_r9bs.py --selftest ref.r9bs                    # round trip
"""
import argparse
import struct
import sys

MAGIC = b"R9BS"
VERSION = 1
KIND_F32, KIND_BFP16 = 0, 1
_HDR = struct.Struct("<IIiiii")


def _write_rec(fp, name, tok, layer, kind, exp, values):
    nm = name.encode("utf-8")
    fp.write(_HDR.pack(len(nm), len(values), tok, layer, kind, exp))
    fp.write(nm)
    if kind == KIND_F32:
        fp.write(struct.pack("<%df" % len(values), *values))
    else:
        fp.write(struct.pack("<%dh" % len(values), *values))


def text_to_r9bs(src, dst, check_names):
    known = None
    if check_names:
        from seam_map import SEAMS
        known = {s[0] for s in SEAMS}

    out = open(dst, "wb")
    out.write(MAGIC)
    out.write(struct.pack("<I", VERSION))

    pending = None          # (name, tok, layer, kind, exp, n, [values])
    nrec = 0
    with open(src) as fp:
        for lineno, line in enumerate(fp, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            tok_ = line.split()
            if tok_[0] == "SEAM":
                if pending is not None and len(pending[6]) != pending[5]:
                    raise SystemExit(
                        "line %d: previous seam %s declared %d values, got %d"
                        % (lineno, pending[0], pending[5], len(pending[6])))
                if pending is not None:
                    _write_rec(out, *pending[:5], pending[6])
                    nrec += 1
                if len(tok_) != 7:
                    raise SystemExit(
                        "line %d: SEAM takes exactly 6 fields "
                        "(name tok layer kind exp n), got %d"
                        % (lineno, len(tok_) - 1))
                name, kind = tok_[1], tok_[4]
                t, layer, exp, n = (int(tok_[2]), int(tok_[3]),
                                    int(tok_[5]), int(tok_[6]))
                if kind not in ("bfp16", "f32"):
                    raise SystemExit("line %d: kind must be bfp16 or f32" % lineno)
                if known is not None and name not in known:
                    raise SystemExit(
                        "line %d: seam name %r is not in seam_map.SEAMS, so the "
                        "bisect would silently never compare it" % (lineno, name))
                pending = (name, t, layer,
                           KIND_F32 if kind == "f32" else KIND_BFP16,
                           exp, n, [])
            else:
                if pending is None:
                    raise SystemExit("line %d: values before any SEAM" % lineno)
                conv = float if pending[3] == KIND_F32 else int
                pending[6].extend(conv(v) for v in tok_)

    if pending is not None:
        if len(pending[6]) != pending[5]:
            raise SystemExit("seam %s declared %d values, got %d"
                             % (pending[0], pending[5], len(pending[6])))
        _write_rec(out, *pending[:5], pending[6])
        nrec += 1
    out.close()
    print("wrote %s: %d records" % (dst, nrec))
    return nrec


def r9bs_to_text(src, dst):
    import r9bs
    n = 0
    with open(dst, "w") as w:
        w.write("# rendered from %s by tools/ref9b/capture_to_r9bs.py\n" % src)
        for r in r9bs.read(src):
            kind = "f32" if r.kind == r9bs.KIND_F32 else "bfp16"
            w.write("SEAM %s %d %d %s %d %d\n"
                    % (r.name, r.tok, r.layer, kind, r.exp, r.n))
            vals = r.raw
            step = 16
            for i in range(0, len(vals), step):
                chunk = vals[i:i + step]
                if r.kind == r9bs.KIND_F32:
                    w.write(" ".join("%.9g" % v for v in chunk) + "\n")
                else:
                    w.write(" ".join("%d" % v for v in chunk) + "\n")
            n += 1
    print("wrote %s: %d records" % (dst, n))
    return n


def selftest(path):
    """Render to text, parse it back, and compare BIT-FOR-BIT.

    THIS IS A ROUND TRIP AND IT IS LABELLED AS ONE.  It prices the parser, not
    the capture.  f32 is rendered at %.9g, which is exact for binary32, so a
    mismatch here is a real parser defect and not a printing artefact.
    """
    import os
    import tempfile
    import r9bs
    d = tempfile.mkdtemp()
    txt = os.path.join(d, "rt.txt")
    back = os.path.join(d, "rt.r9bs")
    r9bs_to_text(path, txt)
    text_to_r9bs(txt, back, check_names=False)
    a = list(r9bs.read(path))
    b = list(r9bs.read(back))
    if len(a) != len(b):
        print("ROUND TRIP IS WRONG: %d records in, %d out" % (len(a), len(b)))
        return 1
    bad = 0
    for x, y in zip(a, b):
        if (x.name, x.tok, x.layer, x.kind, x.exp) != \
           (y.name, y.tok, y.layer, y.kind, y.exp) or not (x.raw == y.raw).all():
            if bad == 0:
                print("ROUND TRIP IS WRONG at %s tok %d" % (x.name, x.tok))
            bad += 1
    if bad:
        print("%d of %d records differ" % (bad, len(a)))
        return 1
    print("round trip: %d records bit-identical.  This prices the PARSER; it "
          "says nothing about whether a capture is right." % len(a))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("-o", "--out")
    ap.add_argument("--from-r9bs", action="store_true",
                    help="render a .r9bs to the text format instead")
    ap.add_argument("--check-names", action="store_true",
                    help="refuse seam names seam_map does not know")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest(a.src)
    if not a.out:
        ap.error("-o is required")
    if a.from_r9bs:
        r9bs_to_text(a.src, a.out)
        return 0
    text_to_r9bs(a.src, a.out, a.check_names)
    return 0


if __name__ == "__main__":
    sys.exit(main())
