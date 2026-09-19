#!/usr/bin/env python3
"""check_const_image_b4.py -- TRACK G (the B constants gate rows), 2026-09-18.

Are `sim/llama_top_const_b4.bin` and `sim/llama_top_const_b4.hex` what
`tools/pack_gdn_consts.py --shape sim --blocks 4 --attn-interval 4` emits
today?

The committed pair is the sim-shape GDN constants image -- the four learned
constants per GDN layer (conv weights, ssm_dt_bias, ssm_a, ssm_norm weight)
sliced from the 9B gguf to `mk_shape_scaled(4, 4)`, one file, two encodings
of the same bytes:

  .bin   what `tools/ref9b/gdn_oracle.py --b-const` reads (the model side)
  .hex   what `sim/tb_llama_top.vhd`'s B_CONST_IMAGE reads (the machine side),
         one 4-hex-digit two's complement int16 word per line, word 0 first

Both are GENERATED, and the packer's layout, exponent rule, slicing rule and
gain reduction all live in code that other tracks edit.  A change to any of
them strands the committed bytes, and nothing else would notice:
`sim/tb_llama_top.vhd` refuses only a file of the wrong LENGTH, and
`gdn_oracle.py` refuses only a wrong number of layers.  A stale image is a
wrong constant with no structural symptom -- and because the bench and the
oracle read the SAME stale bytes, `sim:seamgate_bconst` would still agree
with itself.  Identity to today's packer is the only thing that makes that
agreement a statement about the model.

This is the same shape as `tools/check_norm_image_9b.py` (gate row
`sim:normimage`): regenerate into scratch, byte-compare both files against
the checked-in pair, print one verdict line, exit non-zero on anything but
identity.

Verdicts (last line of stdout, which is what the gate row reports):

  CONST_IMAGE_CHECK: OK <bytes> bytes and <lines> lines identical
  CONST_IMAGE_CHECK: STALE ...          exit 1   a committed file differs
  CONST_IMAGE_CHECK: VOID ...           exit 2   the check could not run
                                                 (no gguf, packer failed)

VOID is non-zero on purpose: a check that could not open its input must land
RED, not as a silent pass.

Beyond identity the pair is also held to the shape the bench and the oracle
assume, so a regenerated-and-committed file at another `--blocks` or
`--attn-interval` cannot pass merely by being reproducible:

  - the .bin is exactly 3 layers x 2,560 B = 7,680 B
    (KCONV 4 x QKVN 256 x 2 B + a 512 B scalar block, per GDN layer)
  - the .hex is exactly 3,840 lines of 4 lowercase hex digits
  - the .hex IS the .bin: line w is the little-endian int16 at byte 2w

NO --manifest.  MEASURED 2026-09-18: `pack_gdn_consts.py --check` with the
9B set's manifest at the sim shape fails on three counts (bytes 1,585,152 vs
7,680, the 9B digest vs the sim digest, the file name), because that manifest
declares the CARD's image and this is not it.  The sim image is declared
nowhere but here.

NO HARDWARE.  Reads a gguf (mmap), two committed files and two scratch files.
MEASURED peak RSS of the packer at the sim shape: 590 MB, 5.6 s wall.
"""

import argparse, hashlib, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
PACKER = os.path.join(REPO, "tools", "pack_gdn_consts.py")
DEFAULT_BIN = os.path.join(REPO, "sim", "llama_top_const_b4.bin")
DEFAULT_HEX = os.path.join(REPO, "sim", "llama_top_const_b4.hex")
DEFAULT_GGUF = "/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf"

BLOCKS = 4
ATTN_INTERVAL = 4
# DERIVED from mk_shape_scaled(4, 4): KCONV 4, QKVN 256 (q 64 | k 64 | v 128),
# scalar block 512 B; 3 of the 4 blocks are GDN layers.
KCONV = 4
QKVN = 256
SCALAR_BYTES = 512
N_LAYERS = 3
BYTES_PER_LAYER = 2 * KCONV * QKVN + SCALAR_BYTES   # 2,560
N_BYTES = N_LAYERS * BYTES_PER_LAYER                # 7,680
N_LINES = N_BYTES // 2                              # 3,840


def void(msg):
    print("CONST_IMAGE_CHECK: VOID " + msg)
    return 2


def stale(msg):
    print("CONST_IMAGE_CHECK: STALE " + msg)
    return 1


def hex_lines(path):
    lines = open(path).read().split("\n")
    # The file ends in a newline, so the split leaves one trailing empty string.
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def shape_check(label, raw, lines):
    """The pair must be the shape the bench and the oracle assume, and the
    .hex must be the .bin."""
    if len(raw) != N_BYTES:
        return "%s .bin holds %d bytes, expected %d (%d layers x %d)" % (
            label, len(raw), N_BYTES, N_LAYERS, BYTES_PER_LAYER)
    if len(lines) != N_LINES:
        return ("%s .hex holds %d lines, expected %d (one int16 word per "
                "line over %d bytes)" % (label, len(lines), N_LINES, N_BYTES))
    for i, l in enumerate(lines):
        if len(l) != 4 or any(c not in "0123456789abcdef" for c in l):
            return "%s .hex line %d is %r, not 4 lowercase hex digits" % (
                label, i + 1, l)
        w = raw[2 * i] | (raw[2 * i + 1] << 8)
        if int(l, 16) != w:
            return ("%s .hex line %d is %s but .bin word %d is %04x: the two "
                    "encodings are not the same image" % (label, i + 1, l, i, w))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=DEFAULT_BIN,
                    help="the checked-in .bin (default sim/llama_top_const_b4.bin)")
    ap.add_argument("--hex", default=DEFAULT_HEX,
                    help="the checked-in .hex (default sim/llama_top_const_b4.hex)")
    ap.add_argument("--gguf", default=DEFAULT_GGUF)
    ap.add_argument("--scratch", default=None,
                    help="directory for the regenerated files (default: a "
                         "tempdir, or $REGRESS_SCRATCH if set)")
    a = ap.parse_args()

    for p in (a.bin, a.hex):
        if not os.path.isfile(p):
            return stale("%s does not exist" % p)
    if not os.access(a.gguf, os.R_OK):
        return void("gguf not readable: %s" % a.gguf)
    if not os.path.isfile(PACKER):
        return void("packer missing: %s" % PACKER)

    scratch = a.scratch or os.environ.get("REGRESS_SCRATCH") or None
    with tempfile.TemporaryDirectory(prefix="const_image_check.",
                                     dir=scratch) as td:
        out_bin = os.path.join(td, "llama_top_const_b4.bin")
        out_hex = os.path.join(td, "llama_top_const_b4.hex")
        cmd = [sys.executable, PACKER, "--gguf", a.gguf, "--shape", "sim",
               "--blocks", str(BLOCKS), "--attn-interval", str(ATTN_INTERVAL),
               "--out", out_bin, "--hex", out_hex]
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True)
        if r.returncode != 0:
            sys.stdout.write(r.stdout[-2000:])
            return void("packer exited %d" % r.returncode)
        gen_raw = open(out_bin, "rb").read()
        gen_lines = hex_lines(out_hex)
    have_raw = open(a.bin, "rb").read()
    have_lines = hex_lines(a.hex)

    bad = shape_check("generated", gen_raw, gen_lines)
    if bad:
        # The packer itself no longer emits the shape the bench and the
        # oracle assume; that is not staleness of the committed files, it is
        # a changed packer, and it must be visible as such.
        return void("packer output is off-shape: " + bad)
    bad = shape_check("checked-in", have_raw, have_lines)
    if bad:
        return stale(bad)

    if have_raw != gen_raw:
        n = sum(1 for x, y in zip(have_raw, gen_raw) if x != y)
        first = next(i for i in range(N_BYTES) if have_raw[i] != gen_raw[i])
        layer, off = divmod(first, BYTES_PER_LAYER)
        return stale("%d of %d bytes differ; first at byte %d (layer %d "
                     "offset 0x%05x): checked-in %02x, generated %02x; "
                     "checked-in blake2b-128 %s, generated %s"
                     % (n, N_BYTES, first, layer, off, have_raw[first],
                        gen_raw[first],
                        hashlib.blake2b(have_raw, digest_size=16).hexdigest(),
                        hashlib.blake2b(gen_raw, digest_size=16).hexdigest()))
    # The shape check above proved each .hex is its own .bin, and the .bins
    # are identical, so the .hex files are identical too; compared anyway so
    # the verdict never rests on an inference.
    if have_lines != gen_lines:
        return stale(".hex differs from the regenerated .hex although the "
                     ".bins agree (this cannot happen if shape_check ran)")

    print("CONST_IMAGE_CHECK: OK %d bytes and %d lines identical, blake2b-128 %s"
          % (len(have_raw), len(have_lines),
             hashlib.blake2b(have_raw, digest_size=16).hexdigest()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
