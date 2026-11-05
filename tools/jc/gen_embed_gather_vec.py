#!/usr/bin/env python3
"""tools/jc/gen_embed_gather_vec.py -- vectors for sim/tb_embed_gather*.vhd (plan 2026-11-04
Task 3): a synthetic .mv4i with the shipped geometry (ROWS_IF 48, AXI_DW 256, BLOCK 32,
NPORTS_W 24, n_scale_sub 3), K 4096 (9B) or 5120 (27B), M 96, and the rows the HOST's
pl_embed_mv4i returns for chosen ids (server/tests/embed_dump.c, built here).

    python3 tools/jc/gen_embed_gather_vec.py --k 4096 [--out PATH] [--mv4i PATH] [--check]

tools/embed_gather.py's PackedTensor (numpy, a different addressing expression) must agree
with the C on every row, or nothing is written (GEN_GATHER_ORACLES_DISAGREE): that is what
shows the synthetic file is well formed. --mv4i also keeps the binary (Task 6 feeds it to
run_prompt). Scratch: ~/regress_scratch. NO HARDWARE.
"""
import argparse, os, random, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools"))
import embed_gather as EG  # noqa: E402

M, ROWS_IF, AXI_DW, BLOCK, NPW, NSS = 96, 48, 256, 32, 24, 3
CODEBOOK = [-120, -96, -72, -56, -40, -28, -16, -6, 6, 16, 28, 40, 56, 72, 85, 120]
W_EXP = -20
EMB_BASE = 0x123400000            # 512 KB aligned: sim/jc_axi3_mem IDX_W 14 indexes bits [18:5]
SEED = 20261104


def geometry(k):
    nb = k // BLOCK
    tiles = (M + ROWS_IF - 1) // ROWS_IF
    sub = tiles * nb * (AXI_DW // 8)
    sub_al = (sub + 4095) // 4096 * 4096
    w_off = [4096 + i * sub_al for i in range(NPW)]
    s_off = [4096 + (NPW + j) * sub_al for j in range(NSS)]
    return nb, sub, w_off, s_off, 4096 + (NPW + NSS) * sub_al


def row_bytes(k, tok):
    """(weight byte offsets per block, scale byte offset per block) of one row, embed_mv4i.c:350-378."""
    nb, _, w_off, s_off, _ = geometry(k)
    t, rr = divmod(tok, ROWS_IF)
    p, half, q, kk = rr // 2, rr % 2, rr // 16, rr % 16
    wb = [w_off[p] + (t * nb + b) * 32 + half * 16 for b in range(nb)]
    sb = [s_off[q] + (t * nb + b) * 32 + 2 * kk for b in range(nb)]
    return wb, sb


def build(k):
    nb, sub, w_off, s_off, size = geometry(k)
    img = bytearray(size)
    img[0x00:0x20] = struct.pack("<IHHIIiiHHHH", 0x4D563449, 1, 0, M, k, W_EXP, 0,
                                 ROWS_IF, NPW, BLOCK, AXI_DW)
    img[0x20:0x30] = bytes(c & 0xFF for c in CODEBOOK)
    img[0x30:0x38] = struct.pack("<II", 0, NSS)
    for i, o in enumerate(w_off + s_off):
        img[0x38 + 8 * i:0x40 + 8 * i] = struct.pack("<Q", o)
    rng = random.Random(SEED + k)
    for o in w_off + s_off:
        img[o:o + sub] = bytes(rng.getrandbits(8) for _ in range(sub))
    # tok 50: block 3 all-negative (nibbles 1 and 3 -> -96, -56)
    wb, sb = row_bytes(k, 50)
    img[wb[3]:wb[3] + 16] = bytes([0x31] * 16)
    # tok 51: every scale 0 -> the all-zero row (exp stays w_exp + 15)
    wb, sb = row_bytes(k, 51)
    for o in sb:
        img[o:o + 2] = b"\x00\x00"
    # tok 61: one element 85 * 771 = 65535 -> msb 15, sh 1, rounds to 32768, saturates to 32767
    wb, sb = row_bytes(k, 61)
    img[wb[0]:wb[0] + 16] = bytes([0x8E] + [0x88] * 15)   # element 0 nibble 14 (85), the rest 8 (6)
    img[sb[0]:sb[0] + 2] = struct.pack("<H", 771)
    for o in sb[1:]:
        img[o:o + 2] = struct.pack("<H", 1)
    return bytes(img)


def toks():
    rng = random.Random(SEED)
    return [0, 1, 2, 47, 48, 49, 50, 51, 61, 95] + sorted(rng.sample(range(3, 95), 6))


def c_rows(path, ids, scratch):
    exe = os.path.join(scratch, "embed_dump")
    r = subprocess.run(["cc", "-O2", "-I", os.path.join(REPO, "server"), "-o", exe,
                        os.path.join(REPO, "server", "tests", "embed_dump.c"),
                        os.path.join(REPO, "server", "embed_mv4i.c")], capture_output=True, text=True)
    if r.returncode:
        sys.exit("GEN_GATHER_FAIL cc\n" + r.stderr)
    r = subprocess.run([exe, "--mv4i", path, "--tokens", ",".join(str(t) for t in ids), "--recipe", "wide"],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit("GEN_GATHER_FAIL embed_dump rc=%d\n%s" % (r.returncode, r.stderr))
    out, cur = {}, None
    for ln in r.stdout.splitlines():
        f = ln.split()
        if f and f[0] == "TOK":
            cur = int(f[1]); out[cur] = [int(f[3]), None]
        elif f and f[0] == "MANT":
            out[cur][1] = [int(x) for x in f[1:]]
    return out


def generate(k, out_path, keep_mv4i):
    scratch = tempfile.mkdtemp(prefix="egv_", dir=os.path.expanduser("~/regress_scratch"))
    img = build(k)
    path = keep_mv4i or os.path.join(scratch, "synth_k%d.mv4i" % k)
    with open(path, "wb") as f:
        f.write(img)
    ids = toks()
    crow = c_rows(path, ids, scratch)
    pt = EG.PackedTensor(path)
    for t in ids:
        mant, xexp = pt.row_bfp(t, recipe=EG.RECIPE_WIDE)
        if [xexp, list(mant)] != crow[t]:
            sys.exit("GEN_GATHER_ORACLES_DISAGREE tok %d" % t)
    assert 32767 in crow[61][1], "tok 61 must hit the saturation"
    assert not any(crow[51][1]), "tok 51 must be the all-zero row"
    lines = ["# sim/embed_gather_k%d_vec.txt -- GENERATED by tools/jc/gen_embed_gather_vec.py --k %d; do not hand-edit." % (k, k),
             "# H emb_base nbeats M / B addr data(32 bytes, byte 31 first) / T tok exp / M mantissas",
             "# rows are server/embed_mv4i.c's pl_embed_mv4i (recipe wide), cross-checked by tools/embed_gather.py",
             "H %09X %d %d" % (EMB_BASE, len(img) // 32, M)]
    for a in range(0, len(img), 32):
        lines.append("B %09X %s" % (EMB_BASE + a, img[a:a + 32][::-1].hex().upper()))
    for t in ids:
        lines.append("T %d %d" % (t, crow[t][0]))
        lines.append("M " + " ".join(str(m) for m in crow[t][1]))
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("GEN_GATHER k=%d ids=%d beats=%d -> %s" % (k, len(ids), len(img) // 32, out_path))


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--k", type=int, choices=(4096, 5120), required=True)
    ap.add_argument("--out")
    ap.add_argument("--mv4i")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    out = a.out or os.path.join(REPO, "sim", "embed_gather_k%d_vec.txt" % a.k)
    if a.check:
        tmp = os.path.join(tempfile.mkdtemp(prefix="egv_chk_", dir=os.path.expanduser("~/regress_scratch")), "v.txt")
        generate(a.k, tmp, None)
        same = open(tmp).read() == open(out).read()
        print("GEN_GATHER_CHECK %s" % ("OK" if same else "STALE"))
        return 0 if same else 1
    generate(a.k, out, a.mv4i)
    return 0


if __name__ == "__main__":
    sys.exit(main())
