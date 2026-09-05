#!/usr/bin/env python3
"""check_model_shape.py -- the 9B shape is transcribed at three sites; hold them together.

THE DEFECT THIS EXISTS TO MAKE VISIBLE, and it is latent rather than
hypothetical.  MEASURED 2026-09-04 while answering "is the composed top at the
real 9B shape":

  * rtl/model_cfg_pkg.vhd holds the authority, `MODEL := QWEN35_9B`, and is
    the ONLY site anything derives from -- and the only consumer that actually
    derives is the region file's `RG_SHAPE : shape_t := mk_shape(MODEL, NCARDS)`
    in the --wire top.
  * rtl/attn_block.vhd's generic DEFAULTS are literals.  Its comment at
    199-206 says all four are "DERIVED from QWEN35_9B" -- but that derivation
    lives in the COMMENT.  The VHDL has `HEAD_DIM : positive := 256`.
  * rtl/gdn_block.vhd's defaults are literals too, and that file does not
    mention model_cfg_pkg at all (MEASURED: `grep -c model_cfg_pkg` = 0).
  * hw/fk33/gen_compose4_top.py restates attention's four AGAIN as Python
    strings: {"HEAD_DIM": "256", "N_QH": "16", "N_KVH": "4", "LAYERS": "8"}.

All of them AGREE today, which is exactly why nothing noticed.  They agree by
coincidence of hand-transcription, not by construction, so flipping MODEL to
QWEN38_27B would move the region file and leave A, B and C at 9B numbers with
no error anywhere.  That is this project's recorded "guard that passes by
coincidence of geometry" class, one level up: a CONFIG that agrees by
coincidence.

WHERE THE EXPECTED VALUES COME FROM.  Not from arithmetic in this file.
Re-deriving `blocks / attn_interval` here would make this checker a fourth
transcription that agrees with the others by construction.  sim/shape_probe.vhd
is elaborated by GHDL and prints what model_cfg_pkg's OWN functions compute;
this file only parses and compares.

WHAT THIS DOES NOT COVER, stated rather than implied:
  * It does not check fk33_engine / subsystem A.  A is descriptor-driven and
    takes its shape at run time, not from a generic, so there is no literal
    here to compare.  That is a real gap and not an argument that A is safe.
  * At NCARDS = 1 the per-card head counts equal the totals, so a
    per-card-versus-total confusion is INVISIBLE here.  See shape_probe.vhd.

TEETH: the table at the bottom of this file.  MEASURED 2026-09-04,
four kills and two controls that correctly do not bite.
"""
import os, re, subprocess, sys, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def die(msg):
    print("SHAPE_FAIL " + msg)
    sys.exit(1)

# ---------------------------------------------------------------- oracle ----
def oracle():
    """Run sim/shape_probe.vhd under GHDL and return its reported values."""
    with tempfile.TemporaryDirectory(prefix="shapechk.") as wd:
        for src in ("rtl/model_cfg_pkg.vhd", "sim/shape_probe.vhd"):
            r = subprocess.run(["ghdl", "-a", "--workdir=" + wd,
                                os.path.join(REPO, src)],
                               capture_output=True, text=True)
            if r.returncode != 0:
                die("ghdl -a %s failed:\n%s%s" % (src, r.stdout, r.stderr))
        r = subprocess.run(["ghdl", "-r", "--workdir=" + wd, "shape_probe"],
                           capture_output=True, text=True)
        # GHDL writes `report` to stderr.  Read BOTH: assuming stdout here
        # would silently yield an empty oracle, and an empty oracle compares
        # equal to nothing and would report success.
        text = r.stdout + r.stderr
    if "SHAPE_PROBE_DONE" not in text:
        die("shape_probe did not run to completion; got:\n" + text)
    vals = {}
    for grp, key, num in re.findall(
            r"(SHAPE|ATTN|GDN)\s+([A-Za-z_]+)=(-?\d+)", text):
        vals[(grp, key)] = int(num)
    if not vals:
        die("shape_probe produced no values")
    return vals

# --------------------------------------------------------------- parsers ----
def generic_defaults(path, entity):
    """Literal defaults in `entity <name>`'s generic clause."""
    src = open(os.path.join(REPO, path)).read()
    m = re.search(r"\bentity\s+" + entity + r"\s+is\b(.*?)\bend\b",
                  src, re.S | re.I)
    if not m:
        die("no entity %s in %s" % (entity, path))
    body = m.group(1)
    g = re.search(r"\bgeneric\s*\((.*?)\)\s*;\s*(?:\bport\b|$)",
                  body, re.S | re.I)
    if not g:
        die("no generic clause on entity %s in %s" % (entity, path))
    text = re.sub(r"--[^\n]*", "", g.group(1))     # strip comments first:
    out = {}                                        # a commented-out default
    # The lookahead is load-bearing.  Without it `EPS : real := 1.0e-6`
    # parses as EPS = 1: the pattern matches the leading digit and abandons
    # the rest.  MEASURED 2026-09-04 -- harmless only because no real-typed
    # generic is among the ones compared, which is not a property to rely on.
    # Requiring the integer to be followed by `;` or `)` means a default this
    # parser cannot read is ABSENT rather than WRONG, and an absent generic
    # is a hard error below instead of a silent mismatch.
    for name, val in re.findall(                    # must not be readable
            r"(\w+)\s*:\s*[\w ]+?\s*:=\s*(-?\d+)\s*(?=[;)]|$)",
            text, re.M):
        out[name] = int(val)
    if not out:
        die("no integer generics parsed from %s in %s" % (entity, path))
    return out

def generator_attn_literals():
    src = open(os.path.join(REPO, "hw/fk33/gen_compose4_top.py")).read()
    m = re.search(r'\("c_attn",\s*"attn_block",\s*"RTL",\s*\{(.*?)\}\)',
                  src, re.S)
    if not m:
        die("could not find the c_attn instance tuple in gen_compose4_top.py")
    return {k: int(v) for k, v in
            re.findall(r'"(\w+)"\s*:\s*"(-?\d+)"', m.group(1))}

# ------------------------------------------------------------------ main ----
def main():
    o = oracle()
    bad, checked = [], 0

    def cmp(where, name, got, grp, key):
        nonlocal checked
        want = o.get((grp, key))
        if want is None:
            die("oracle has no %s %s" % (grp, key))
        checked += 1
        if got != want:
            bad.append("%s: %s = %d, but model_cfg_pkg computes %d"
                       % (where, name, got, want))

    a = generic_defaults("rtl/attn_block.vhd", "attn_block")
    for gen, key in (("HEAD_DIM", "HEAD_DIM"), ("N_QH", "N_QH"),
                     ("N_KVH", "N_KVH"), ("LAYERS", "LAYERS")):
        if gen not in a:
            die("attn_block has no generic %s" % gen)
        cmp("rtl/attn_block.vhd default", gen, a[gen], "ATTN", key)

    g = generic_defaults("rtl/gdn_block.vhd", "gdn_block")
    for gen, key in (("KEY_HEADS", "KEY_HEADS"), ("VAL_HEADS", "VAL_HEADS"),
                     ("DIM", "DIM"), ("LAYERS", "LAYERS")):
        if gen not in g:
            die("gdn_block has no generic %s" % gen)
        cmp("rtl/gdn_block.vhd default", gen, g[gen], "GDN", key)
    if "KCONV" in g:
        cmp("rtl/gdn_block.vhd default", "KCONV", g["KCONV"],
            "SHAPE", "conv_kernel")

    c = generator_attn_literals()
    for gen, key in (("HEAD_DIM", "HEAD_DIM"), ("N_QH", "N_QH"),
                     ("N_KVH", "N_KVH"), ("LAYERS", "LAYERS")):
        if gen not in c:
            die("gen_compose4_top.py c_attn has no %s" % gen)
        cmp("gen_compose4_top.py c_attn", gen, c[gen], "ATTN", key)

    if bad:
        print("SHAPE_FAIL %d of %d transcriptions disagree with "
              "rtl/model_cfg_pkg.vhd:" % (len(bad), checked))
        for b in bad:
            print("  " + b)
        print("  Fix the LITERALS to match the package, which is the "
              "authority; do not edit the package to match a literal.")
        return 1

    print("SHAPE_OK %d literals agree with model_cfg_pkg (MODEL at NCARDS=%d): "
          "attn %dx%d hd=%d layers=%d, gdn %d/%d hd=%d layers=%d"
          % (checked, o[("SHAPE", "ncards")],
             o[("ATTN", "N_QH")], o[("ATTN", "N_KVH")], o[("ATTN", "HEAD_DIM")],
             o[("ATTN", "LAYERS")], o[("GDN", "KEY_HEADS")],
             o[("GDN", "VAL_HEADS")], o[("GDN", "DIM")], o[("GDN", "LAYERS")]))
    return 0

if __name__ == "__main__":
    sys.exit(main())

# ---------------------------------------------------------------- TEETH -----
# MEASURED 2026-09-04.  Each mutant was applied to a REAL file and the checker
# run; the tree was restored from pristine copies afterwards and verified
# clean (0 dirty tracked files, generator byte-identical).
#
#   M1  rtl/attn_block.vhd     HEAD_DIM 256 -> 128            KILLED rc=1
#   M2  gen_compose4_top.py    c_attn LAYERS "8" -> "16"      KILLED rc=1
#   M3  rtl/gdn_block.vhd      VAL_HEADS 32 -> 48 (the 27B    KILLED rc=1
#                              value, i.e. a plausible slip)
#   M4  rtl/model_cfg_pkg.vhd  MODEL := QWEN38_27B            KILLED rc=1
#       THE REAL SCENARIO.  Names each disagreement rather than a single
#       failure: "N_QH = 16, but model_cfg_pkg computes 24", "LAYERS = 8 ...
#       computes 16", and gdn_block's VAL_HEADS 32 against 48.  This is the
#       drift the file exists to catch and it is caught.
#
#   M5  CONTROL  gdn_block CONV_LANES 4 -> 8, a generic     does NOT bite
#       OUTSIDE the shape.  Measures SCOPE: the checker is not merely
#       reacting to any edit in a file it parses.
#   M6  CONTROL  comment-only edit inside attn_block's      does NOT bite
#       generic clause.  Comments are stripped before parsing, so this
#       confirms the strip works rather than masking a default.
#
# NOT a mutant and worth stating: subsystem A is never checked, so no mutant
# here can fail on A's account.  A takes its shape from descriptors at run
# time and has no literal to compare.
