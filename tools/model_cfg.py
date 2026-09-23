#!/usr/bin/env python3
"""The ONE reader of rtl/model_cfg_pkg.vhd for the FK33 generators.

WHY THIS FILE EXISTS (2026-09-23, 27B prep).  Every width in the card follows
ONE binding, `constant MODEL : model_cfg_t := <record>;` in
rtl/model_cfg_pkg.vhd (`SHAPE := mk_shape(MODEL, NCARDS)` in rtl/llama_top.vhd),
and the committed package binds QWEN35_9B because every bench, every reference
vector and every gate row is 9B.  A 27B card must be built WITHOUT editing that
line, so the two generators that carry model-dependent literals --
hw/fk33/gen_pcieep.py (the seam's CAPS, REGMAX/HADDR_W, the package the build
compiles) and hw/fk33/gen_fk33_card.py (the norm-gain and QK-norm images, the
REGMAX port-range constant) -- read the record they are building for from
HERE, from the same package text, so the two cannot disagree about what a
record says.

The model NAME comes from the FK33_MODEL environment variable, read by the
generators themselves (each stamps it); this module never reads the
environment, so its selftest is deterministic.

REGMAX IS A MIRROR OF VHDL AND IS PINNED TO MEASUREMENTS.  `regmax()` mirrors
rtl/llama_map_pkg.vhd's `region_max(mk_shape(m, 1))`.  MEASURED 2026-09-23
with ghdl-mcode (a three-line probe calling the VHDL functions directly):
QWEN35_9B 12288, QWEN38_27B 17408, NREGION 14.  `selftest()` refuses if the
mirror disagrees with either, so a drift in the VHDL region list shows up as a
refusal here rather than as a wrong port width discovered by the packager
hours into a build.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, ".."))
PKG_PATH = os.path.join(REPO, "rtl", "model_cfg_pkg.vhd")

# Anchors, MEASURED by GHDL 2026-09-23 (see the docstring).  A record name
# missing from the package makes its anchor a refusal, not a skip: the anchor
# is the only thing that makes the mirror trustworthy.
REGMAX_MEASURED = {"QWEN35_9B": 12288, "QWEN38_27B": 17408}
NREGION_MEASURED = 14

# The image suffix each record's committed norm-gain / QK-norm images carry
# (hw/fk33/gen/norm_w_<sfx>.hex, qkn_<sfx>.hex).  Explicit rather than derived
# from the name, so an unknown record is a refusal and not a guessed path.
IMAGE_SUFFIX = {"QWEN35_9B": "9b", "QWEN38_27B": "27b"}

_REC_RE = re.compile(r"constant\s+(\w+)\s*:\s*model_cfg_t\s*:=\s*\((.*?)\);", re.S)
_BIND_RE = re.compile(r"^(\s*constant\s+MODEL\s*:\s*model_cfg_t\s*:=\s*)(\w+)(\s*;)",
                      re.M)


class ModelPkg(object):
    """The package text, its records and its `MODEL` binding."""

    def __init__(self, path=PKG_PATH):
        self.path = path
        self.text = open(path).read()
        self.records = dict(_REC_RE.findall(self.text))
        b = _BIND_RE.search(self.text)
        if not b:
            raise SystemExit("%s: no `constant MODEL : model_cfg_t := <name>;` "
                             "binding found; the generators cannot tell which "
                             "record the RTL builds." % path)
        if not self.records:
            raise SystemExit("%s: no model_cfg_t records found." % path)
        self.default = b.group(2)
        if self.default not in self.records:
            raise SystemExit("%s: MODEL is bound to %r, which is not a record "
                             "the package declares (%s)."
                             % (path, self.default, ", ".join(sorted(self.records))))

    def resolve(self, name):
        """The record name to build: `name` if given, else the binding.
        Refuses a name the package does not declare."""
        name = name or self.default
        if name not in self.records:
            raise SystemExit("FK33_MODEL=%r is not a record rtl/model_cfg_pkg.vhd "
                             "declares; it has %s.  Refusing rather than building "
                             "the wrong model." % (name, ", ".join(sorted(self.records))))
        return name

    def field(self, name, key):
        m = re.search(r"\b%s\s*=>\s*(\d+)" % key, self.records[name])
        if not m:
            raise SystemExit("rtl/model_cfg_pkg.vhd: record %s has no field %r."
                             % (name, key))
        return int(m.group(1))

    def regmax(self, name):
        """Mirror of rtl/llama_map_pkg.vhd region_sizes/region_max at NCARDS=1.
        See the module docstring for the measured anchors."""
        f = lambda k: self.field(name, k)
        key_dim = f("lin_key_heads") * f("lin_head_dim")
        val_dim = f("lin_val_heads") * f("lin_head_dim")
        att_q = f("attn_q_heads") * f("attn_head_dim")
        att_kv = f("attn_kv_heads") * f("attn_head_dim")
        sizes = [f("hidden"),               # R_X, R_XN, R_ER
                 2 * key_dim + val_dim,     # R_QKV
                 val_dim,                   # R_Z
                 f("lin_val_heads"),        # R_BETA, R_ALPHA
                 2 * att_q,                 # R_QG
                 att_kv,                    # R_KIN, R_VIN
                 max(val_dim, att_q),       # R_Y
                 f("ffn")]                  # R_G, R_U, R_H
        return max(sizes)

    def haddr_w(self, name):
        """clog2(REGMAX), the seam's HADDR_W (rtl/fk33_seam.vhd pins the pair
        two-sided, so a wrong value cannot build)."""
        return (self.regmax(name) - 1).bit_length()

    def caps(self, name):
        return {"CAPS_VOCAB": self.field(name, "vocab"),
                "CAPS_EMBD": self.field(name, "hidden"),
                "CAPS_LAYER": self.field(name, "blocks")}

    def image_suffix(self, name):
        if name not in IMAGE_SUFFIX:
            raise SystemExit("tools/model_cfg.py: no committed norm/QK-norm "
                             "image suffix for %s; add it to IMAGE_SUFFIX once "
                             "hw/fk33/gen/norm_w_<sfx>.hex and qkn_<sfx>.hex "
                             "exist." % name)
        return IMAGE_SUFFIX[name]

    def bound_text(self, name):
        """The package text with ONLY the binding line rewritten to `name`.
        Exactly one line differs from the source; `selftest` measures that."""
        name = self.resolve(name)
        out, n = _BIND_RE.subn(lambda m: m.group(1) + name + m.group(3),
                               self.text, count=1)
        if n != 1:
            raise SystemExit("bound_text: binding line not rewritten")
        return out

    def check_anchors(self):
        for rec, want in REGMAX_MEASURED.items():
            if rec not in self.records:
                raise SystemExit("tools/model_cfg.py: anchor record %s is not "
                                 "in rtl/model_cfg_pkg.vhd; the REGMAX mirror "
                                 "has lost its measurement." % rec)
            got = self.regmax(rec)
            if got != want:
                raise SystemExit("tools/model_cfg.py: REGMAX mirror gives %d for "
                                 "%s, GHDL measured %d (2026-09-23).  The VHDL "
                                 "region list or this mirror changed; re-measure "
                                 "with ghdl and fix whichever moved."
                                 % (got, rec, want))


def load(name=None, path=PKG_PATH):
    """(pkg, resolved name) with the anchors checked.  This is the entry the
    generators use."""
    pkg = ModelPkg(path)
    pkg.check_anchors()
    return pkg, pkg.resolve(name)


def selftest():
    pkg, dflt = load()
    print("MODELCFG package %s binds %s; records %s"
          % (os.path.relpath(pkg.path, REPO), dflt, ", ".join(sorted(pkg.records))))
    for rec in sorted(pkg.records):
        print("MODELCFG %-10s regmax=%d haddr_w=%d caps=%s sfx=%s"
              % (rec, pkg.regmax(rec), pkg.haddr_w(rec), pkg.caps(rec),
                 IMAGE_SUFFIX.get(rec)))
    # bound_text: exactly one line differs, and it is the binding.
    for rec in sorted(pkg.records):
        a = pkg.text.splitlines()
        b = pkg.bound_text(rec).splitlines()
        diff = [(x, y) for x, y in zip(a, b) if x != y]
        if len(a) != len(b):
            sys.exit("SELFTEST FAIL: bound_text(%s) changed the line count" % rec)
        want = 0 if rec == dflt else 1
        if len(diff) != want:
            sys.exit("SELFTEST FAIL: bound_text(%s) changed %d lines, expected %d: %r"
                     % (rec, len(diff), want, diff[:3]))
        if want and not _BIND_RE.match(diff[0][1]):
            sys.exit("SELFTEST FAIL: the changed line is not the binding: %r"
                     % (diff[0][1],))
    # MUTANT FROM THE THING: a package whose binding names a record it does
    # not declare must be refused, and an unknown FK33_MODEL must be refused.
    import tempfile
    d = tempfile.mkdtemp(prefix="modelcfg_")
    mut = os.path.join(d, "model_cfg_pkg.vhd")
    open(mut, "w").write(_BIND_RE.sub(lambda m: m.group(1) + "QWEN_NOPE" + m.group(3),
                                      pkg.text, count=1))
    try:
        ModelPkg(mut)
    except SystemExit as e:
        print("MODELCFG refused bad binding: %s" % str(e)[:60])
    else:
        sys.exit("SELFTEST FAIL: a binding to an undeclared record was accepted")
    try:
        pkg.resolve("QWEN_NOPE")
    except SystemExit as e:
        print("MODELCFG refused unknown name: %s" % str(e)[:60])
    else:
        sys.exit("SELFTEST FAIL: an unknown model name was accepted")
    # The anchor bites: a mirror that returns the wrong number is refused.
    saved = REGMAX_MEASURED["QWEN35_9B"]
    REGMAX_MEASURED["QWEN35_9B"] = saved + 1
    try:
        pkg.check_anchors()
    except SystemExit as e:
        print("MODELCFG anchor bites: %s" % str(e)[:60])
    else:
        sys.exit("SELFTEST FAIL: the REGMAX anchor did not bite")
    finally:
        REGMAX_MEASURED["QWEN35_9B"] = saved
    os.remove(mut)
    os.rmdir(d)
    print("MODELCFG SELFTEST PASS")


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        selftest()
    else:
        pkg, name = load(sys.argv[1] if len(sys.argv) > 1 else None)
        print("%s regmax=%d haddr_w=%d caps=%s image_suffix=%s"
              % (name, pkg.regmax(name), pkg.haddr_w(name), pkg.caps(name),
                 IMAGE_SUFFIX.get(name)))
