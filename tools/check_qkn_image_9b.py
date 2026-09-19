#!/usr/bin/env python3
"""check_qkn_image_9b.py -- TRACK F, 2026-09-18.

Are `hw/fk33/gen/qkn_9b.hex` and `sim/llama_top_qkn_b4.hex` what
`tools/gen_qkn_image.py` emits today?

The committed pair is the elaboration-time `C_QKN_IMAGE` of `rtl/llama_top.vhd`
at its two shapes:

  hw/fk33/gen/qkn_9b.hex     the card: 8 attention layers x 2 ports x 256
                             elements at C_QKN_EXP = 12 (4,096 lines),
                             passed by hw/fk33/gen_fk33_card.py
  sim/llama_top_qkn_b4.hex   the `real` bench configuration
                             (mk_shape_scaled(4, 4, 16)): 1 x 2 x 16 = 32
                             lines, --reduce slice; read by
                             sim/tb_llama_top_qkn.vhd and, on the model
                             side, by tools/ref9b/attn_oracle.py --qkn-image
                             in sim:seamgate_qkn

Both are GENERATED, and the generator takes the layer order from
`tools/gen_llama_top_weights.py`'s schedule and the quantiser from the same
file, so an edit to either silently strands the committed bytes.  Nothing else
would notice: the loader in `rtl/llama_top.vhd` refuses only a file of the
wrong LENGTH, and a gain vector in the wrong layer order is a wrong number
with no structural symptom -- and because the bench and the oracle read the
SAME bytes, `sim:seamgate_qkn` would still agree with itself.

Same shape as `tools/check_norm_image_9b.py` (gate row `sim:normimage`):
regenerate into scratch, byte-compare, one verdict line, non-zero on anything
but identity.

Verdicts (last line of stdout, which is what the gate row reports):

  QKN_IMAGE_CHECK: OK <n> + <m> lines identical
  QKN_IMAGE_CHECK: STALE ...          exit 1   a committed file differs
  QKN_IMAGE_CHECK: VOID ...           exit 2   the check could not run
                                               (no gguf, generator failed)

VOID is non-zero on purpose: a check that could not open its input must land
RED, not as a silent pass.

Beyond identity each file is held to the shape its consumer assumes, so a
regenerated-and-committed file at another `--attn-hd` or `--qkn-exp` cannot
pass merely by being reproducible:

  - exactly 2 * layers * head_dim lines (4,096 and 32)
  - every line exactly 4 lowercase hex digits
  - no entry beyond +/-32767 (int16 at the fixed exponent)

NO HARDWARE.  Reads a gguf (mmap) and text files.  MEASURED 2026-09-18: the
generator at the 9B shape takes 5.9 s, peak RSS 585 MB.
"""

import argparse, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
GEN = os.path.join(HERE, "gen_qkn_image.py")
DEFAULT_GGUF = "/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf"
QKN_EXP = 12

# (committed path, blocks, attn_interval, attn_hd, reduce)
IMAGES = [
    (os.path.join(REPO, "hw", "fk33", "gen", "qkn_9b.hex"), 32, 4, 256, "slice"),
    (os.path.join(REPO, "sim", "llama_top_qkn_b4.hex"), 4, 4, 16, "slice"),
]


def void(msg):
    print("QKN_IMAGE_CHECK: VOID " + msg)
    return 2


def stale(msg):
    print("QKN_IMAGE_CHECK: STALE " + msg)
    return 1


def shape_check(path, lines, n_lines):
    if len(lines) != n_lines:
        return "%s holds %d lines, expected %d" % (path, len(lines), n_lines)
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


def read_lines(path):
    lines = open(path).read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gguf", default=DEFAULT_GGUF)
    ap.add_argument("--scratch", default=None,
                    help="directory for the regenerated files (default: a "
                         "tempdir, or $REGRESS_SCRATCH if set)")
    a = ap.parse_args()

    for (path, _b, _k, _hd, _r) in IMAGES:
        if not os.path.isfile(path):
            return stale("%s does not exist" % path)
    if not os.access(a.gguf, os.R_OK):
        return void("gguf not readable: %s" % a.gguf)
    if not os.path.isfile(GEN):
        return void("generator missing: %s" % GEN)

    scratch = a.scratch or os.environ.get("REGRESS_SCRATCH") or None
    counts = []
    with tempfile.TemporaryDirectory(prefix="qkn_image_check.",
                                     dir=scratch) as td:
        for (path, blocks, attn_int, hd, reduce) in IMAGES:
            out = os.path.join(td, os.path.basename(path))
            cmd = [sys.executable, GEN, "--gguf", a.gguf,
                   "--blocks", str(blocks), "--attn-interval", str(attn_int),
                   "--attn-hd", str(hd), "--reduce", reduce,
                   "--qkn-exp", str(QKN_EXP), "--out", out]
            r = subprocess.run(cmd, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
            if r.returncode != 0:
                sys.stdout.write(r.stdout[-2000:])
                return void("generator exited %d for %s" % (r.returncode, path))
            gen_lines = read_lines(out)
            have_lines = read_lines(path)
            n_lines = 2 * (blocks // attn_int) * hd
            bad = shape_check("generated " + os.path.basename(path),
                              gen_lines, n_lines)
            if bad:
                # The generator no longer emits the shape the consumer
                # assumes; that is a changed generator, not a stale file.
                return void("generator output is off-shape: " + bad)
            bad = shape_check(path, have_lines, n_lines)
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
                vec, el = divmod(i, hd)
                lay, port = divmod(vec, 2)
                return stale("%s: %d of %d lines differ; first at line %d "
                             "(layer ordinal %d port %s element %d): "
                             "checked-in %s, generated %s"
                             % (path, n, n_lines, i + 1, lay, "qk"[port], el,
                                h, g))
            counts.append(len(have_lines))

    print("QKN_IMAGE_CHECK: OK %s lines identical"
          % " + ".join(str(c) for c in counts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
