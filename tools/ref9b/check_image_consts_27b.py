#!/usr/bin/env python3
"""check_image_consts_27b.py -- decode every per-layer constant a 27B card image carries,
the way the RTL consumes it, and compare it with the GGUF tensor.  2026-10-09.

Decoded independently of tools/pack_gdn_consts.py (no import of its layout code), from:
  * gdn_const.bin, per GDN layer L (ordinal, blocks with (b+1) % 4 != 0): 41216 int16 =
    conv word[t*QKVN + ch] (t oldest..newest, ch q|k|v), then dt[48], a[48], norm[128],
    six exponents cw_q cw_k cw_v dt_e a_e w_e; value = mant * 2^-e.
  * the NORM_HBM rows appended at hbm.norm_const_offset: row 2b = blk.b.attn_norm,
    2b+1 = blk.b.post_attention_norm, 128 = output_norm, int16 at NORM_W_EXP = 12
    (rtl/llama_top.vhd NORM_W_EXP; the row is the descriptor's const_base,
    tools/gen_layer_program.py emit_ffn / the block norms).
  * C_QKN_IMAGE hw/fk33/gen/qkn_27b.hex: per attention layer q[256] then k[256], hex
    int16 at C_QKN_EXP = 12.

Prints the worst error per tensor kind.  Verdict line: CONSTS_27B: OK / BAD.
--perturb scales one decoded value set by 1.01 (norm row of blk 5, GDN ssm_norm of GDN
layer 5, q-norm of attention layer 2) and must turn the verdict BAD: the teeth check.

usage: check_image_consts_27b.py IMAGE_DIR [--gguf G] [--qkn HEX] [--perturb]
NO HARDWARE.  Reads the GGUF by mmap (gguf-py)."""
import argparse, json, os, sys
import numpy as np
from gguf import GGUFReader

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
H, Q, VH, D, BLOCKS, AHD = 5120, 10240, 48, 128, 64, 256
SEGS = [(0, 2048), (2048, 2048), (4096, 6144)]
WPL = 4 * Q + 256


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--gguf", default="/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf")
    ap.add_argument("--qkn", default=os.path.join(REPO, "hw/fk33/gen/qkn_27b.hex"))
    ap.add_argument("--perturb", action="store_true")
    a = ap.parse_args()
    T = {t.name: t for t in GGUFReader(a.gguf).tensors}
    g = lambda n: np.array(T[n].data, dtype=np.float64)
    hbm = json.load(open(os.path.join(a.image, "manifest.json")))["hbm"]
    img = np.fromfile(os.path.join(a.image, hbm.get("gdn_const_file", "gdn_const.bin")),
                      dtype="<i2").astype(np.float64)
    worst = {}

    def note(kind, got, ref, where, abs_tol):
        e = float(np.abs(got - ref).max())
        if kind not in worst or e - abs_tol > worst[kind][0] - worst[kind][2]:
            worst[kind] = (e, where, abs_tol)

    # NORM rows
    off = hbm["norm_const_offset"] // 2
    rows = img[off:off + hbm["norm_const_rows"] * H].reshape(-1, H) / 4096.0
    assert rows.shape[0] == 2 * BLOCKS + 1, rows.shape
    if a.perturb:
        rows[10] *= 1.01
    for b in range(BLOCKS):
        for j, nm in enumerate(("attn_norm", "post_attention_norm")):
            note("norm_row", rows[2 * b + j], g("blk.%d.%s.weight" % (b, nm)).reshape(-1),
                 "blk.%d.%s" % (b, nm), 2.0 ** -13 + 1e-9)
    note("norm_row", rows[128], g("output_norm.weight").reshape(-1), "output_norm",
         2.0 ** -13 + 1e-9)

    # GDN constants
    gb = [b for b in range(BLOCKS) if (b + 1) % 4 != 0]
    for L, b in enumerate(gb):
        w = img[L * WPL:(L + 1) * WPL]
        sc = w[4 * Q:]
        ex = sc[2 * VH + D:2 * VH + D + 6].astype(int)
        conv = w[:4 * Q].reshape(4, Q).copy()
        for s, (o, n) in enumerate(SEGS):
            conv[:, o:o + n] *= 2.0 ** -ex[s]
            note("conv", conv[:, o:o + n], g("blk.%d.ssm_conv1d.weight" % b).reshape(Q, 4).T[:, o:o + n],
                 "blk.%d seg %d" % (b, s), 2.0 ** -(ex[s] + 1) + 1e-12)
        nw = sc[2 * VH:2 * VH + D] * 2.0 ** -ex[5]
        if a.perturb and L == 5:
            nw = nw * 1.01
        for kind, got, ref, e in (("ssm_dt.bias", sc[:VH] * 2.0 ** -ex[3], g("blk.%d.ssm_dt.bias" % b), ex[3]),
                                  ("ssm_a", sc[VH:2 * VH] * 2.0 ** -ex[4], g("blk.%d.ssm_a" % b), ex[4]),
                                  ("ssm_norm", nw, g("blk.%d.ssm_norm.weight" % b), ex[5])):
            note(kind, got, ref.reshape(-1), "blk.%d" % b, 2.0 ** -(e + 1) + 1e-12)

    # QK norms
    v = np.array([int(l, 16) for l in open(a.qkn).read().split()], dtype=np.int64)
    v[v >= 0x8000] -= 0x10000
    v = v.reshape(BLOCKS // 4, 2, AHD) / 4096.0
    if a.perturb:
        v[2, 0] *= 1.01
    for k, b in enumerate(b for b in range(BLOCKS) if (b + 1) % 4 == 0):
        note("q_norm", v[k, 0], g("blk.%d.attn_q_norm.weight" % b).reshape(-1), "blk.%d" % b, 2.0 ** -13 + 1e-9)
        note("k_norm", v[k, 1], g("blk.%d.attn_k_norm.weight" % b).reshape(-1), "blk.%d" % b, 2.0 ** -13 + 1e-9)

    bad = 0
    for kind, (e, where, tol) in sorted(worst.items()):
        ok = e <= tol
        bad += not ok
        print("%-12s worst |err| %.3e at %-26s half-quantum %.3e  %s" % (kind, e, where, tol, "ok" if ok else "BAD"))
    print("CONSTS_27B: %s %s" % ("OK" if not bad else "BAD", a.image))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
