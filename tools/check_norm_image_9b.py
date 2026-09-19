#!/usr/bin/env python3
"""check_norm_image_9b.py -- TRACK E, 2026-09-18.

Is `hw/fk33/gen/norm_w_9b.hex` what `sim/ooc_nwrom_gen_image.py` emits today?

The committed file is the elaboration-time `NORM_W_IMAGE` for the card build:
65 norm ops x 4096 elements at `NORM_W_EXP = 12`, one 4-hex-digit two's
complement int16 per line, element 0 first, in `build_plan`'s schedule order.
It is GENERATED, and the generator imports the schedule order, the tensor
names and the quantiser from `tools/gen_llama_top_weights.py`, so any edit to
the schedule, the exponent or the quantiser silently strands the committed
bytes.  Nothing else would notice: the loader in `rtl/llama_top.vhd` accepts
any file that is a whole number of 4096-line groups, and a gain vector that is
merely in the wrong order is a wrong number with no structural symptom.

This is the same shape as `tools/gen_cardtop.py --check` (gate row
`sim:cardtop`): regenerate into scratch, byte-compare against the checked-in
file, print one verdict line, exit non-zero on anything but identity.

Verdicts (last line of stdout, which is what the gate row reports):

  NORM_IMAGE_CHECK: OK <n> lines identical
  NORM_IMAGE_CHECK: STALE ...          exit 1   the committed file differs
  NORM_IMAGE_CHECK: VOID ...           exit 2   the check could not run
                                                (no gguf, generator failed)

VOID is non-zero on purpose: a check that could not open its input must land
RED, not as a silent pass.

Beyond identity the file is also held to the shape the loader and the card
build assume, so a regenerated-and-committed file at the wrong `--ops` or
`--norm-w-exp` cannot pass merely by being reproducible:

  - exactly 65 x 4096 = 266,240 lines (2 * BLOCKS + 1 norm ops at 4096)
  - every line exactly 4 lowercase hex digits
  - no entry beyond +/-32767 (int16 at the fixed exponent)

NO HARDWARE.  Reads a gguf (mmap) and two text files.  MEASURED peak RSS of
the generator at the 9B shape: 587 MB.
"""

import argparse, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
GEN = os.path.join(REPO, "sim", "ooc_nwrom_gen_image.py")
DEFAULT_IMAGE = os.path.join(REPO, "hw", "fk33", "gen", "norm_w_9b.hex")
DEFAULT_GGUF = "/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf"

BLOCKS = 32
HIDDEN = 4096
NORM_W_EXP = 12
N_OPS = 2 * BLOCKS + 1
N_LINES = N_OPS * HIDDEN


def void(msg):
    print("NORM_IMAGE_CHECK: VOID " + msg)
    return 2


def stale(msg):
    print("NORM_IMAGE_CHECK: STALE " + msg)
    return 1


def shape_check(path, lines):
    """The committed file must be the shape the loader and the build assume."""
    if len(lines) != N_LINES:
        return "%s holds %d lines, expected %d (%d norm ops x %d)" % (
            path, len(lines), N_LINES, N_OPS, HIDDEN)
    for i, l in enumerate(lines):
        if len(l) != 4 or any(c not in "0123456789abcdef" for c in l):
            return "%s line %d is %r, not 4 lowercase hex digits" % (
                path, i + 1, l)
        v = int(l, 16)
        if v >= 0x8000:
            v -= 0x10000
        if abs(v) > 32767:
            return "%s line %d = %d exceeds int16" % (path, i + 1, v)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=DEFAULT_IMAGE,
                    help="the checked-in image (default hw/fk33/gen/norm_w_9b.hex)")
    ap.add_argument("--gguf", default=DEFAULT_GGUF)
    ap.add_argument("--scratch", default=None,
                    help="directory for the regenerated file (default: a "
                         "tempdir, or $REGRESS_SCRATCH if set)")
    a = ap.parse_args()

    if not os.path.isfile(a.image):
        return stale("%s does not exist" % a.image)
    if not os.access(a.gguf, os.R_OK):
        return void("gguf not readable: %s" % a.gguf)
    if not os.path.isfile(GEN):
        return void("generator missing: %s" % GEN)

    scratch = a.scratch or os.environ.get("REGRESS_SCRATCH") or None
    with tempfile.TemporaryDirectory(prefix="norm_image_check.",
                                     dir=scratch) as td:
        out = os.path.join(td, "norm_w_9b.hex")
        cmd = [sys.executable, GEN, "--gguf", a.gguf, "--blocks", str(BLOCKS),
               "--hidden", str(HIDDEN), "--norm-w-exp", str(NORM_W_EXP),
               "--out", out]
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True)
        if r.returncode != 0:
            sys.stdout.write(r.stdout[-2000:])
            return void("generator exited %d" % r.returncode)
        gen_lines = open(out).read().split("\n")
        have_lines = open(a.image).read().split("\n")

    # Both end in a newline, so the split leaves one trailing empty string.
    if gen_lines and gen_lines[-1] == "":
        gen_lines.pop()
    if have_lines and have_lines[-1] == "":
        have_lines.pop()

    bad = shape_check("generated", gen_lines)
    if bad:
        # The generator itself no longer emits the shape the build assumes;
        # that is not staleness of the committed file, it is a changed
        # generator, and it must be visible as such.
        return void("generator output is off-shape: " + bad)
    bad = shape_check(a.image, have_lines)
    if bad:
        return stale(bad)

    if have_lines != gen_lines:
        n = 0
        first = None
        for i, (h, g) in enumerate(zip(have_lines, gen_lines)):
            if h != g:
                n += 1
                if first is None:
                    first = (i, h, g)
        i, h, g = first
        op, el = divmod(i, HIDDEN)
        return stale("%d of %d lines differ; first at line %d (norm op %d "
                     "element %d): checked-in %s, generated %s"
                     % (n, N_LINES, i + 1, op, el, h, g))

    print("NORM_IMAGE_CHECK: OK %d lines identical" % len(have_lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
