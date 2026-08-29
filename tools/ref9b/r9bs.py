#!/usr/bin/env python3
"""Reader for the .r9bs seam-stream format defined in tools/ref9b/seam_stream.h.

Kept separate from seam_bisect.py so that a hardware or GHDL capture written by some
other producer can be inspected without the comparison machinery.
"""
import struct
import numpy as np

MAGIC = b"R9BS"
KIND_F32, KIND_BFP16, KIND_S32 = 0, 1, 2
VERSIONS = (1, 2)          # 2 is "this file may contain an S32 record"
_HDR = struct.Struct("<IIiiii")   # name_len, n, tok, layer, kind, exp
_DTYPE = {KIND_F32: np.float32, KIND_BFP16: np.int16, KIND_S32: np.int32}
_KINDNAME = {KIND_F32: "f32", KIND_BFP16: "bfp16", KIND_S32: "s32"}


class Record:
    __slots__ = ("name", "tok", "layer", "kind", "exp", "raw")

    def __init__(self, name, tok, layer, kind, exp, raw):
        self.name, self.tok, self.layer = name, tok, layer
        self.kind, self.exp, self.raw = kind, exp, raw

    @property
    def value(self):
        """The numeric value as float64, whatever the on-disk kind.

        BFP16 is `mant * 2^-exp` -- note the NEGATIVE power, which is the
        convention tools/pack_int4.py:14 fixes for the whole project.  Getting
        the sign of this backwards produces a stream that is wrong by a factor
        of 2^(2*exp) and still looks structurally perfect.
        """
        if self.kind == KIND_F32:
            return self.raw.astype(np.float64)
        return self.raw.astype(np.float64) * (2.0 ** -self.exp)

    @property
    def kindname(self):
        return _KINDNAME.get(self.kind, "kind%d" % self.kind)

    @property
    def n(self):
        return len(self.raw)

    def __repr__(self):
        k = ("f32" if self.kind == KIND_F32
             else "%s(exp=%d)" % (self.kindname, self.exp))
        return "Record(%s tok=%d layer=%d n=%d %s)" % (
            self.name, self.tok, self.layer, self.n, k)


def read(path, want=None):
    """Yield Records in file order.  `want` is an optional set of names."""
    with open(path, "rb") as fp:
        hdr = fp.read(8)
        if len(hdr) != 8 or hdr[:4] != MAGIC:
            raise ValueError("%s: not an r9bs stream" % path)
        ver = struct.unpack("<I", hdr[4:])[0]
        if ver not in VERSIONS:
            raise ValueError("%s: unsupported version %d (this reader knows "
                             "%s)" % (path, ver, ", ".join(map(str, VERSIONS))))
        while True:
            b = fp.read(_HDR.size)
            if not b:
                return
            if len(b) != _HDR.size:
                raise ValueError("%s: truncated record header" % path)
            name_len, n, tok, layer, kind, exp = _HDR.unpack(b)
            name = fp.read(name_len).decode("utf-8")
            if kind not in _DTYPE:
                raise ValueError("%s: record %r has unknown kind %d; the "
                                 "payload width is therefore unknown and every "
                                 "record after it would be mis-framed"
                                 % (path, name, kind))
            if kind == KIND_S32 and ver < 2:
                raise ValueError("%s: an S32 record in a version-%d file.  A "
                                 "file carrying S32 must declare version 2 so "
                                 "an older reader stops here rather than "
                                 "decoding 32-bit values as int16."
                                 % (path, ver))
            dt = _DTYPE[kind]
            nbytes = n * np.dtype(dt).itemsize
            payload = fp.read(nbytes)
            if len(payload) != nbytes:
                raise ValueError("%s: truncated payload for %s" % (path, name))
            if want is not None and name not in want:
                continue
            yield Record(name, tok, layer, kind, exp,
                         np.frombuffer(payload, dtype=dt))


def index(path, want=None):
    """(name, tok) -> Record.  A repeated key is an error, not a silent last-wins."""
    out = {}
    for r in read(path, want):
        k = (r.name, r.tok)
        if k in out:
            raise ValueError("%s: duplicate seam %r" % (path, k))
        out[k] = r
    return out


if __name__ == "__main__":
    import sys
    tot = 0
    for r in read(sys.argv[1]):
        v = r.value
        print("%-28s tok=%d layer=%-3d n=%-7d %-14s min=%+.6g max=%+.6g rms=%.6g"
              % (r.name, r.tok, r.layer, r.n,
                 "f32" if r.kind == KIND_F32
                 else "%s e=%d" % (r.kindname, r.exp),
                 v.min() if r.n else 0, v.max() if r.n else 0,
                 float(np.sqrt((v * v).mean())) if r.n else 0))
        tot += 1
    print("# %d records" % tot)
