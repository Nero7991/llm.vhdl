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

  <kind>   `bfp16`, `s32` or `f32`
  <exp>    for bfp16 and s32, the SHARED exponent, with value = v * 2^-exp.
           Note the NEGATIVE power: tools/pack_int4.py:14 fixes that convention
           for the whole project and getting its sign backwards produces a
           stream that is wrong by 2^(2*exp) and looks structurally perfect.
           Write 0 for f32.
  <layer>  -1 for a whole-model seam.
  values   bfp16: signed decimal int16 mantissas.  s32: signed decimal int32,
           which is what RAW `out_mode` produces and what the LOGITS seam
           carries.  f32: anything float() accepts.

A file containing an s32 record is written at format version 2; see
`seam_stream.h`.

NAMES AND WHY THE CHECK IS NOW ON BY DEFAULT.  Names should be the RTL seam
names in tools/ref9b/seam_map.py (`R_XN-0`, `R_QKV.k-0`, `R_X-31`, ...).  Until
2026-08-29 `seam_bisect.exact()` walked `seam_map.SEAMS` and a name the map did
not know was carried through and NEVER COMPARED, silently -- MEASURED, three
seams per token of the `ATTN_INT = 2` capture.  `exact()` now walks the
intersection of the two streams instead, so an unknown name IS compared; but
`--mode cross` still walks the map and cannot see one.  So an unknown name is a
loud WARNING by default rather than being ignored, and `--check-names` still
refuses outright.

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
VERSION_S32 = 2
KIND_F32, KIND_BFP16, KIND_S32 = 0, 1, 2
_KINDS = {"f32": KIND_F32, "bfp16": KIND_BFP16, "s32": KIND_S32}
_PACK = {KIND_F32: "f", KIND_BFP16: "h", KIND_S32: "i"}
_HDR = struct.Struct("<IIiiii")


def _write_rec(fp, name, tok, layer, kind, exp, values):
    nm = name.encode("utf-8")
    fp.write(_HDR.pack(len(nm), len(values), tok, layer, kind, exp))
    fp.write(nm)
    fp.write(struct.pack("<%d%s" % (len(values), _PACK[kind]), *values))


def text_to_r9bs(src, dst, check_names=False, warn_names=True):
    """Parse the whole file, THEN write it.

    Two-pass rather than streaming, because the format VERSION depends on
    whether any record turns out to be S32 and the version is the first thing
    in the file.  These captures are kilobytes; the alternative is a seek-back
    that silently leaves a wrong version behind on a short write.
    """
    known = None
    if check_names or warn_names:
        from seam_map import SEAMS
        known = {s[0] for s in SEAMS}

    records = []            # (name, tok, layer, kind, exp, values)
    unknown = []
    pending = None          # [name, tok, layer, kind, exp, n, values]

    def _close(lineno):
        if pending is None:
            return
        if len(pending[6]) != pending[5]:
            raise SystemExit("line %s: seam %s declared %d values, got %d"
                             % (lineno, pending[0], pending[5], len(pending[6])))
        records.append(tuple(pending[:5]) + (pending[6],))

    with open(src) as fp:
        for lineno, line in enumerate(fp, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            tok_ = line.split()
            if tok_[0] == "SEAM":
                _close(lineno)
                if len(tok_) != 7:
                    raise SystemExit(
                        "line %d: SEAM takes exactly 6 fields "
                        "(name tok layer kind exp n), got %d"
                        % (lineno, len(tok_) - 1))
                name, kindname = tok_[1], tok_[4]
                t, layer, exp, n = (int(tok_[2]), int(tok_[3]),
                                    int(tok_[5]), int(tok_[6]))
                if kindname not in _KINDS:
                    raise SystemExit("line %d: kind must be one of %s, got %r"
                                     % (lineno, "/".join(sorted(_KINDS)), kindname))
                if known is not None and name not in known:
                    if check_names:
                        raise SystemExit(
                            "line %d: seam name %r is not in seam_map.SEAMS, so "
                            "--mode cross can never compare it" % (lineno, name))
                    if name not in unknown:
                        unknown.append(name)
                pending = [name, t, layer, _KINDS[kindname], exp, n, []]
            else:
                if pending is None:
                    raise SystemExit("line %d: values before any SEAM" % lineno)
                conv = float if pending[3] == KIND_F32 else int
                pending[6].extend(conv(v) for v in tok_)
    _close("EOF")

    ver = VERSION_S32 if any(r[3] == KIND_S32 for r in records) else VERSION
    with open(dst, "wb") as out:
        out.write(MAGIC)
        out.write(struct.pack("<I", ver))
        for rec in records:
            _write_rec(out, *rec)

    if unknown:
        # NOT silent, and NOT fatal.  seam_bisect.exact() compares these; the
        # map-keyed tools cannot.  Stating which is the whole point.
        sys.stderr.write(
            "WARNING: %d seam name(s) are not in seam_map.SEAMS: %s\n"
            "         seam_bisect.py --mode exact DOES compare them (it walks "
            "the streams, not the map),\n"
            "         but --mode cross walks the map and cannot.  Pass "
            "--check-names to refuse instead.\n"
            % (len(unknown), ", ".join(unknown)))
    print("wrote %s: %d records, format version %d" % (dst, len(records), ver))
    return len(records)


def r9bs_to_text(src, dst):
    import r9bs
    n = 0
    with open(dst, "w") as w:
        w.write("# rendered from %s by tools/ref9b/capture_to_r9bs.py\n" % src)
        for r in r9bs.read(src):
            w.write("SEAM %s %d %d %s %d %d\n"
                    % (r.name, r.tok, r.layer, r.kindname, r.exp, r.n))
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
    text_to_r9bs(txt, back, check_names=False, warn_names=False)
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
                    help="REFUSE a seam name seam_map does not know.  Without "
                         "it an unknown name is a loud warning: exact() "
                         "compares it, cross() cannot.")
    ap.add_argument("--quiet-names", action="store_true",
                    help="suppress even the warning.  There is no good reason "
                         "to pass this on a capture you intend to compare.")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest(a.src)
    if not a.out:
        ap.error("-o is required")
    if a.from_r9bs:
        r9bs_to_text(a.src, a.out)
        return 0
    text_to_r9bs(a.src, a.out, a.check_names, not a.quiet_names)
    return 0


if __name__ == "__main__":
    sys.exit(main())
